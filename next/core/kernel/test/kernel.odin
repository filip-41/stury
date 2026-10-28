package kernel_tests

import "base:sanitizer"
import "core:math/rand"
import "core:mem/virtual"
import "core:testing"
import k ".."

// The tier under test, by its place in `k.Tier`: `-define:TIER=2` is v4 on x86-64. The kernels run in procedures
// compiled with the tier's features, as a caller's hot loops are.
T :: k.Tier(#config(TIER, 0))
FEATURES :: k.FEATURES[T]

// Bit i set where `src[i] == c`.
reference :: proc(src: []u8, c: u8) -> (m: u64) {
	for b, i in src {
		if b == c {
			m |= u64(1) << u64(i)
		}
	}
	return
}

@(test, enable_target_feature = FEATURES)
pack_every_byte_and_lane :: proc(t: ^testing.T) {
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	buf: [64]u8
	for v in 0 ..< 256 {
		c := u8(v)
		for &b in buf {
			b = c + 1
		}
		testing.expect_value(t, k.pack(k.eq(k.load(raw_data(buf[:])), c)), 0)
		testing.expect(t, !k.any_lane(k.eq(k.load(raw_data(buf[:])), c)))
		for lane in 0 ..< 64 {
			buf[lane] = c
			m := k.eq(k.load(raw_data(buf[:])), c)
			testing.expect_value(t, k.pack(m), u64(1) << u64(lane))
			testing.expect(t, k.any_lane(m))
			buf[lane] = c + 1
		}
		// The near misses of `c`: its neighbours and its top bit flipped, which a compare of the top bit alone takes.
		alphabet := [4]u8{c, c + 1, c - 1, c ~ 0x80}
		for _ in 0 ..< 64 {
			for &b in buf {
				b = alphabet[rand.int_max(4)]
			}
			m := k.eq(k.load(raw_data(buf[:])), c)
			want := reference(buf[:], c)
			testing.expect_value(t, k.pack(m), want)
			testing.expect_value(t, k.any_lane(m), want != 0)
		}
	}
}

// Bit i set where `src[i]` is a byte of `set`.
reference_set :: proc(src: []u8, set: string) -> (m: u64) {
	for b, i in src {
		for c in transmute([]u8)set {
			if b == c {
				m |= u64(1) << u64(i)
			}
		}
	}
	return
}

// Every byte value against the sets, then random blocks of their bytes and their neighbours.
@(enable_target_feature = FEATURES)
check_sets :: proc(t: ^testing.T, sets: []string) {
	table, bits := k.nibble_table(sets)
	near: [dynamic]u8
	defer delete(near)
	for set in sets {
		for c in transmute([]u8)set {
			append(&near, c, c + 1, c - 1, c ~ 0x10)
		}
	}
	buf: [64]u8
	for block in 0 ..< 4 + 64 {
		for &b, i in buf {
			b = block < 4 ? u8(64 * block + i) : rand.choice(near[:])
		}
		c := k.classes(T, k.load(raw_data(buf[:])), table)
		masks: [4]k.Block
		for set, s in sets {
			m := k.has(c, bits[s])
			want := reference_set(buf[:], set)
			testing.expectf(t, k.pack(m) == want, "sets %q, set %d: %x, want %x", sets, s, k.pack(m), want)
			if s < 4 {
				masks[s] = m
			}
		}
		joint := k.pack_n(masks)
		for m, s in masks {
			testing.expect_value(t, joint[s], k.pack(m))
		}
	}
}

@(test)
classes_of_every_byte :: proc(t: ^testing.T) {
	state := rand.create(3)
	context.random_generator = rand.default_random_generator(&state)
	check_sets(t, {"\"", "\\", ",:[]{}", " \t\n\r"})
	check_sets(t, {",", "\"", "\n\r"})
	// Random families with up to eight pairs of a set and a high nibble, bytes above 0x7f, and bytes in two sets.
	for _ in 0 ..< 500 {
		bytes: [8][16]u8
		lens: [8]int
		nsets := 1 + rand.int_max(8)
		for _ in 0 ..< 8 {
			s, h := rand.int_max(nsets), u8(rand.int_max(16))
			for _ in 0 ..< 1 + rand.int_max(4) {
				if lens[s] < 16 {
					bytes[s][lens[s]] = h << 4 | u8(rand.int_max(16))
					lens[s] += 1
				}
			}
		}
		sets: [8]string
		for s in 0 ..< nsets {
			sets[s] = string(bytes[s][:lens[s]])
		}
		check_sets(t, sets[:nsets])
	}
}

@(test, enable_target_feature = FEATURES)
either_and_pack_n :: proc(t: ^testing.T) {
	state := rand.create(4)
	context.random_generator = rand.default_random_generator(&state)
	buf: [64]u8
	for _ in 0 ..< 1000 {
		for &b in buf {
			b = rand.choice([]u8{'a', ',', '"', '\n', '\r'})
		}
		b := k.load(raw_data(buf[:]))
		lines := k.either(k.eq(b, '\n'), k.eq(b, '\r'))
		testing.expect_value(t, k.pack(lines), reference_set(buf[:], "\n\r"))
		r3 := k.pack_n([3]k.Block{k.eq(b, ','), k.eq(b, '"'), lines})
		testing.expect_value(t, r3, [3]u64{reference(buf[:], ','), reference(buf[:], '"'), reference_set(buf[:], "\n\r")})
		r2 := k.pack_n([2]k.Block{k.eq(b, ','), k.eq(b, '"')})
		testing.expect_value(t, r2, [2]u64{reference(buf[:], ','), reference(buf[:], '"')})
	}
}

// Per block of `src`, the unescaped quotes and the bytes inside a string, byte by byte: a backslash escapes the next
// byte unless it is escaped itself, and a byte is inside from an opening quote up to its closing quote.
reference_strings :: proc(src: []u8, quotes, inside: []u64) {
	escaped, in_string := false, false
	for b, i in src {
		bit := u64(1) << u64(i % 64)
		switch {
		case escaped:
			escaped = false
		case b == '\\':
			escaped = true
		case b == '"':
			quotes[i / 64] |= bit
			in_string = !in_string
		}
		if in_string {
			inside[i / 64] |= bit
		}
	}
}

@(enable_target_feature = FEATURES)
check_strings :: proc(t: ^testing.T, src: []u8) {
	assert(len(src) % 64 == 0 && len(src) <= 64 * 8)
	want_quotes, want_inside: [8]u64
	reference_strings(src, want_quotes[:], want_inside[:])
	s: k.String_State
	for i in 0 ..< len(src) / 64 {
		b := k.load(raw_data(src[64 * i:]))
		m := k.pack_n([2]k.Block{k.eq(b, '"'), k.eq(b, '\\')})
		quotes, inside := k.string_region(T, m[0], m[1], &s)
		testing.expectf(t, quotes == want_quotes[i] && inside == want_inside[i], "%q block %d: quotes %x inside %x, want %x %x", string(src), i, quotes, inside, want_quotes[i], want_inside[i])
	}
}

@(test)
strings_across_blocks :: proc(t: ^testing.T) {
	state := rand.create(5)
	context.random_generator = rand.default_random_generator(&state)
	buf: [64 * 8]u8
	// Backslash runs of every length up to two blocks, ending at every byte of a block, then a quote.
	for run in 1 ..= 128 {
		for end in 0 ..< 64 {
			for &b in buf {
				b = 'a'
			}
			at := 128 + end
			for i in at - run ..< at {
				buf[i] = '\\'
			}
			buf[at] = '"'
			check_strings(t, buf[:256])
		}
	}
	// Random blocks, dense in quotes and backslashes or with a few of them.
	for alphabet in ([]string{"\"\\a", "\"\\\\\\aaaa", "\"aaaaaaaaaaaaaaaaaaaaaaaaaaa", "\\\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}) {
		for _ in 0 ..< 2000 {
			for &b in buf {
				b = alphabet[rand.int_max(len(alphabet))]
			}
			check_strings(t, buf[:])
		}
	}
}

// Every tail of `src` lies just before or just after a page that faults on any access, so a load that leaves the
// input's pages crashes the test. The memory around each input is full of the byte compared, so a lane outside the
// input that `align` keeps shows up as a wrong bit.
@(test)
tail_beside_guard_page :: proc(t: ^testing.T) {
	// 64 KiB is a whole number of pages on every target (4, 16 and 64 KiB pages).
	GUARD :: 64 * 1024
	region, err := virtual.reserve_and_commit(4 * GUARD)
	testing.expect_value(t, err, virtual.Allocator_Error.None)
	defer virtual.release(raw_data(region), uint(len(region)))
	state := rand.create(2)
	context.random_generator = rand.default_random_generator(&state)
	for &b in region {
		b = rand.int_max(4) == 0 ? 'x' : '"'
	}
	base := uintptr(raw_data(region))
	guard := (base + GUARD - 1) &~ (GUARD - 1) + GUARD
	testing.expect(t, virtual.protect(rawptr(guard), GUARD, virtual.Protect_No_Access))
	before := ([^]u8)(guard - 256)

	@(enable_target_feature = FEATURES)
	check :: proc(t: ^testing.T, src: []u8, lo: int) {
		tail := k.load_tail(T, src, lo)
		for c in ([2]u8{'"', 'x'}) {
			got := k.align(k.pack(k.eq(tail.block, c)), tail)
			testing.expectf(t, got == reference(src[lo:], c), "len %d lo %d byte %q: %x", len(src), lo, c, got)
		}
	}
	// Inputs that end up to 128 bytes before the guard: the load from `lo` is taken where it ends before the page
	// boundary, the load ending at the input's end otherwise.
	for gap in 0 ..< 128 {
		for rem in 1 ..< 64 {
			end := 256 - gap
			check(t, before[end - 64 - rem:end], 64)
			check(t, before[end - rem:end], 0)
		}
	}
	// Inputs that start where the guard ends, with `lo` across the first two 4 KiB pages, so every offset of `lo` in
	// a page is met, the last 63 of each included.
	after := ([^]u8)(guard + GUARD)
	for lo in 0 ..< 8192 {
		for rem in 1 ..< 64 {
			check(t, after[:lo + rem], lo)
		}
	}
}

// The tail of an input smaller than a block whose allocation the compiler sees. Read by a load inlined here, an
// optimizing build finds stale bytes.
@(test)
tail_of_small_local :: proc(t: ^testing.T) {
	@(enable_target_feature = FEATURES)
	quotes :: proc() -> u64 {
		buf: [10]u8
		for &b, i in buf {
			b = i % 2 == 0 ? '"' : 'a'
		}
		tail := k.load_tail(T, buf[:], 0)
		return k.align(k.pack(k.eq(tail.block, '"')), tail)
	}
	testing.expect_value(t, quotes(), 0x155)
}

// Tails of inputs whose surroundings an ASan build has poisoned: `load_tail` reads there and must not be reported.
// Odin's heap does not poison past an allocation, so the test poisons the buffer around each input itself.
@(test, enable_target_feature = FEATURES)
tail_in_poisoned_memory :: proc(t: ^testing.T) {
	buf := make([]u8, 256)
	defer delete(buf)
	for &b, i in buf {
		b = i % 3 == 0 ? '"' : 'a'
	}
	for n in 1 ..< 128 {
		if n % 64 == 0 {
			continue
		}
		// Either load from a tail of `src` stays inside `buf`.
		src := buf[64:][:n]
		lo := n &~ 63
		sanitizer.address_poison_slice(buf)
		sanitizer.address_unpoison_slice(src)
		tail := k.load_tail(T, src, lo)
		sanitizer.address_unpoison_slice(buf)
		testing.expect_value(t, k.align(k.pack(k.eq(tail.block, '"')), tail), reference(src[lo:], '"'))
	}
}

@(test, enable_target_feature = FEATURES)
below_every_byte_and_lane :: proc(t: ^testing.T) {
	buf: [64]u8
	for v in 0 ..< 256 {
		c := u8(v)
		for &b in buf {
			b = c
		}
		testing.expect_value(t, k.pack(k.below(k.load(raw_data(buf[:])), c)), 0)
		testing.expect(t, !k.any_below(k.load(raw_data(buf[:])), c))
		if c == 0 {
			continue
		}
		// Every lane, holding the largest byte below `c` and a byte with its top bit flipped.
		for low in ([2]u8{c - 1, (c - 1) ~ 0x80}) {
			for lane in 0 ..< 64 {
				buf[lane] = low
				want := low < c ? u64(1) << u64(lane) : 0
				b := k.load(raw_data(buf[:]))
				testing.expect_value(t, k.pack(k.below(b, c)), want)
				testing.expect_value(t, k.any_below(b, c), want != 0)
				buf[lane] = c
			}
		}
	}
}

// The positions of `m`, plus `base`, from `out[n]` on, and no slot written before `n` or past `FLATTEN_STEP` slots
// after the last position.
check_flatten :: proc(t: ^testing.T, m: u64, n: int, base: u16, loc := #caller_location) {
	SENTINEL :: 0xffff
	out: [32 + 64 + k.FLATTEN_STEP + 1]u16
	for &o in out {
		o = SENTINEL
	}
	end := k.flatten(raw_data(out[:]), n, m, base)
	testing.expect_value(t, end, n + int(count_ones(m)), loc = loc)
	i := n
	for bit in 0 ..< 64 {
		if m >> u64(bit) & 1 != 0 {
			testing.expectf(t, out[i] == base + u16(bit), "mask %x slot %d: %d, want %d", m, i, out[i], base + u16(bit), loc = loc)
			i += 1
		}
	}
	for j in 0 ..< n {
		testing.expectf(t, out[j] == SENTINEL, "mask %x wrote slot %d before %d", m, j, n, loc = loc)
	}
	for j in end + k.FLATTEN_STEP ..< len(out) {
		testing.expectf(t, out[j] == SENTINEL, "mask %x wrote slot %d past the slack", m, j, loc = loc)
	}
}

count_ones :: proc(m: u64) -> (c: int) {
	for x := m; x != 0; x &= x - 1 {
		c += 1
	}
	return
}

@(test, enable_target_feature = FEATURES)
flatten_every_count :: proc(t: ^testing.T) {
	state := rand.create(6)
	context.random_generator = rand.default_random_generator(&state)
	check_flatten(t, 0, 0, 0)
	check_flatten(t, ~u64(0), 3, 100)
	check_flatten(t, u64(1) << 63, 0, 65535 - 63)
	// Every count, around the step boundaries above all, at random positions.
	for count in 0 ..= 64 {
		for _ in 0 ..< 50 {
			m: u64
			for count_ones(m) < count {
				m |= u64(1) << u64(rand.int_max(64))
			}
			check_flatten(t, m, rand.int_max(32), u16(rand.int_max(1 << 15)))
		}
	}
}

// Per block, the bytes of the runs of `runs` that start at a byte of `starts`, a run going on across block edges.
reference_runs :: proc(runs, starts: []u64, out: []u64) {
	inside := false
	for i in 0 ..< 64 * len(runs) {
		bit := u64(1) << u64(i % 64)
		in_run := runs[i / 64] & bit != 0
		if !in_run {
			inside = false
		} else if starts[i / 64] & bit != 0 {
			inside = true
		}
		if in_run && inside {
			out[i / 64] |= bit
		}
	}
}

@(test)
run_bytes_across_blocks :: proc(t: ^testing.T) {
	state := rand.create(7)
	context.random_generator = rand.default_random_generator(&state)
	BLOCKS :: 4
	for _ in 0 ..< 5000 {
		// Runs of random lengths, the long ones crossing blocks, some of them started.
		runs, starts, want: [BLOCKS]u64
		for i := 0; i < 64 * BLOCKS; {
			length := rand.int_max(4) == 0 ? rand.int_max(100) : rand.int_max(6)
			started := rand.int_max(2) == 0
			for j in i ..< min(i + length, 64 * BLOCKS) {
				runs[j / 64] |= u64(1) << u64(j % 64)
				if j == i && started {
					starts[j / 64] |= u64(1) << u64(j % 64)
				}
			}
			i += length + 1
		}
		reference_runs(runs[:], starts[:], want[:])
		carry: u64
		for b in 0 ..< BLOCKS {
			got := k.run_bytes(runs[b], starts[b], &carry)
			testing.expectf(t, got == want[b], "runs %x starts %x block %d: %x, want %x", runs, starts, b, got, want[b])
		}
	}
}
