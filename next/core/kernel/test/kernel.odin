package kernel_tests

import "core:math/rand"
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

// Per block of `src`, the quotes no backslash escapes, byte by byte: a backslash escapes the next byte unless it is
// escaped itself.
reference_quotes :: proc(src: []u8, quotes: []u64) {
	escaped := false
	for b, i in src {
		bit := u64(1) << u64(i % 64)
		switch {
		case escaped:
			escaped = false
		case b == '\\':
			escaped = true
		case b == '"':
			quotes[i / 64] |= bit
		}
	}
}

@(enable_target_feature = FEATURES)
check_strings :: proc(t: ^testing.T, src: []u8) {
	assert(len(src) % 64 == 0 && len(src) <= 64 * 8)
	want: [8]u64
	reference_quotes(src, want[:])
	odd: u64
	for i in 0 ..< len(src) / 64 {
		b := k.load(raw_data(src[64 * i:]))
		m := k.pack_n([2]k.Block{k.eq(b, '"'), k.eq(b, '\\')})
		quotes := m[0] &~ k.escaped(m[1], &odd)
		testing.expectf(t, quotes == want[i], "%q block %d: quotes %x, want %x", string(src), i, quotes, want[i])
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

@(test, enable_target_feature = FEATURES)
below_every_byte_and_lane :: proc(t: ^testing.T) {
	buf: [64]u8
	for v in 0 ..< 256 {
		c := u8(v)
		for &b in buf {
			b = c
		}
		testing.expect_value(t, k.pack(k.below(k.load(raw_data(buf[:])), c)), 0)
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
				buf[lane] = c
			}
		}
	}
}

// Every lane alone, then every lane under random lanes above it, and the empty mask.
@(test, enable_target_feature = FEATURES)
first_lane_every_lane :: proc(t: ^testing.T) {
	state := rand.create(8)
	context.random_generator = rand.default_random_generator(&state)
	testing.expect_value(t, k.first_lane(#simd[16]u8{}), 16)
	for lane in 0 ..< 16 {
		for round in 0 ..< 64 {
			m: [16]u8
			m[lane] = 0xff
			for above in lane + 1 ..< 16 {
				if round > 0 && rand.int_max(2) == 0 {
					m[above] = 0xff
				}
			}
			got := k.first_lane(transmute(#simd[16]u8)m)
			testing.expectf(t, got == u64(lane), "% x: %d, want %d", m, got, lane)
		}
	}
}
