package kernel_tests

import "base:intrinsics"
import "core:math/rand"
import "core:mem/virtual"
import "core:testing"
import k "stury:lib/base/kernel"
import "stury:testkit"

// The table sorting bytes into `sets`, and each set's bits.
nibble_table :: proc(sets: []string) -> (t: k.Nibble_Table, bits: [8]u8) {
	assert(len(sets) <= 8, "more than eight sets")
	lo, hi: [16]u8
	next: uint
	for set, s in sets {
		pair: [16]u8
		for c in transmute([]u8)set {
			h := c >> 4
			if pair[h] == 0 {
				assert(next < 8, "more than eight pairs of a set and a high nibble")
				pair[h] = 1 << next
				next += 1
			}
			hi[h] |= pair[h]
			lo[c & 15] |= pair[h]
			bits[s] |= pair[h]
		}
	}
	return {transmute(#simd[16]u8)lo, transmute(#simd[16]u8)hi}, bits
}

// The tier under test, by its index in `k.Tier` (`-define:TIER=1` is V3 on x86-64). Tests run in procedures compiled
// with the tier's features, as a caller's bulk loops are.
T :: k.Tier(#config(TIER, 0))
FEATURES :: k.FEATURES[T]

// Returns a mask with bit `i` set where `src[i] == c`.
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
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 1)
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
		// The near misses of `c`: its neighbours and a byte with its top bit flipped, which catch a compare that tests
		// the top bit alone.
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

// Returns a mask with bit `i` set where `src[i]` is a byte of `set`.
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

// Checks `classes` against every byte value in 4 blocks, then against random blocks of each set's bytes and their
// neighbours, and checks `pack_n` for two, three and four masks and `either` against `pack`.
@(enable_target_feature = FEATURES)
check_sets :: proc(t: ^testing.T, sets: []string) {
	table, bits := nibble_table(sets)
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
		testing.expect_value(t, k.pack_n([3]k.Block{masks[0], masks[1], masks[2]}), [3]u64{joint[0], joint[1], joint[2]})
		testing.expect_value(t, k.pack_n([2]k.Block{masks[0], masks[1]}), [2]u64{joint[0], joint[1]})
		testing.expect_value(t, k.pack(k.either(masks[0], masks[1])), joint[0] | joint[1])
	}
}

@(test)
classes_of_every_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 3)
	check_sets(t, {"\"", "\\", ",:[]{}", " \t\n\r"})
	check_sets(t, {",", "\"", "\n\r"})
	// 500 random families with up to eight pairs of a set and a high nibble, bytes above 0x7f, and bytes in two sets.
	for _ in 0 ..< testkit.rounds(500) {
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

// Checks `classes` and `has` on deterministic boundaries: zero `Nibble_Table{}`, shared-bit high-nibble rows (including
// sign-bit class `0x80` and bytes >= 0x80), `has(c, 0)`, `has(c, 0x80)`, `has(c, 0xff)`, and `any_lane(has(c, bits))`
// in every lane.
@(test, enable_target_feature = FEATURES)
classes_and_has_boundaries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Shared-bit high-nibble table:
	// - bit 0x01: 0x00 and 0xF0 (high nibbles 0x0 and 0xF share low nibble 0x0)
	// - bit 0x02: 0x8F and 0xFF (high nibbles 0x8 and 0xF share low nibble 0xF, bytes >= 0x80)
	// - bit 0x40: 'A'..'F' (0x41..0x46) and 'a'..'f' (0x61..0x66) share one bit across high nibbles 0x4 and 0x6
	// - bit 0x80: 'D' (0x44) and 'd' (0x64) share sign-bit class 0x80 (and also carry bit 0x40)
	table := k.Nibble_Table {
		lo = {0x01, 0x40, 0x40, 0x40, 0xc0, 0x40, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02},
		hi = {0x01, 0x00, 0x00, 0x00, 0xc0, 0x00, 0xc0, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03},
	}
	zero: k.Nibble_Table
	buf: [64]u8
	for block in 0 ..< 4 {
		for &b, i in buf {
			b = u8(64 * block + i)
		}
		bv := k.load(raw_data(buf[:]))
		cz := k.classes(T, bv, zero)
		for bits in ([?]u8{0, 0x01, 0x80, 0xff}) {
			mz := k.has(cz, bits)
			testing.expect_value(t, k.pack(mz), 0)
			testing.expect(t, !k.any_lane(mz))
		}
		c := k.classes(T, bv, table)
		cases := [?]struct {
			bits: u8,
			want: u64,
		}{
			{0x00, 0},
			{0x01, reference_set(buf[:], "\x00\xf0")},
			{0x02, reference_set(buf[:], "\x8f\xff")},
			{0x40, reference_set(buf[:], "ABCDEFabcdef")},
			{0x80, reference_set(buf[:], "Dd")},
			{0xff, reference_set(buf[:], "\x00\xf0\x8f\xffABCDEFabcdef")},
		}
		for tc in cases {
			m := k.has(c, tc.bits)
			testing.expectf(t, k.pack(m) == tc.want, "block %d, bits 0x%02x: %x, want %x", block, tc.bits, k.pack(m), tc.want)
			testing.expectf(t, k.any_lane(m) == (tc.want != 0), "block %d, bits 0x%02x: any_lane mismatch", block, tc.bits)
		}
	}
	// Single-lane sweep across all 64 lanes for `any_lane(has(...))` with sign-bit `0x80` and high byte `0xFF`.
	for &b in buf {
		b = 'z'
	}
	c_none := k.classes(T, k.load(raw_data(buf[:])), table)
	for bits in ([?]u8{0x00, 0x01, 0x02, 0x40, 0x80, 0xff}) {
		testing.expect(t, !k.any_lane(k.has(c_none, bits)))
	}
	for lane in 0 ..< 64 {
		bit := u64(1) << u64(lane)
		buf[lane] = 'D'
		cd := k.classes(T, k.load(raw_data(buf[:])), table)
		testing.expect_value(t, k.pack(k.has(cd, 0x00)), 0)
		testing.expect(t, !k.any_lane(k.has(cd, 0x00)))
		testing.expect_value(t, k.pack(k.has(cd, 0x01)), 0)
		testing.expect(t, !k.any_lane(k.has(cd, 0x01)))
		testing.expect_value(t, k.pack(k.has(cd, 0x40)), bit)
		testing.expect(t, k.any_lane(k.has(cd, 0x40)))
		testing.expect_value(t, k.pack(k.has(cd, 0x80)), bit)
		testing.expect(t, k.any_lane(k.has(cd, 0x80)))
		testing.expect_value(t, k.pack(k.has(cd, 0xff)), bit)
		testing.expect(t, k.any_lane(k.has(cd, 0xff)))

		buf[lane] = 0xff
		cf := k.classes(T, k.load(raw_data(buf[:])), table)
		testing.expect_value(t, k.pack(k.has(cf, 0x02)), bit)
		testing.expect(t, k.any_lane(k.has(cf, 0x02)))
		testing.expect_value(t, k.pack(k.has(cf, 0x80)), 0)
		testing.expect(t, !k.any_lane(k.has(cf, 0x80)))
		testing.expect_value(t, k.pack(k.has(cf, 0xff)), bit)
		testing.expect(t, k.any_lane(k.has(cf, 0xff)))
		buf[lane] = 'z'
	}
}

// Sets bit `i % 64` of `quotes[i / 64]` for each quote in `src` that no backslash escapes. A backslash escapes the
// next byte unless it is escaped itself.
reference_escaped :: proc(src: []u8, quotes: []u64) {
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

// Checks `escaped` on a run of 1 to 128 backslashes ending at each byte of the third block, then a quote.
@(test, enable_target_feature = FEATURES)
escaped_across_blocks :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [64 * 4]u8
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
			want: [4]u64
			reference_escaped(buf[:], want[:])
			odd: u64
			for i in 0 ..< 4 {
				b := k.load(raw_data(buf[64 * i:]))
				m := k.pack_n([2]k.Block{k.eq(b, '"'), k.eq(b, '\\')})
				quotes := m[0] &~ k.escaped(m[1], &odd)
				testing.expectf(t, quotes == want[i], "run %d to %d, block %d: quotes %x, want %x", run, at, i, quotes, want[i])
			}
		}
	}
}

@(test, enable_target_feature = FEATURES)
below_every_byte_and_lane :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
		// Each lane in turn holds `c - 1`, the largest byte below `c`, or that byte with its top bit flipped.
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

// Checks `first_lane16` and `any_lane16` on the empty mask and on each lane alone, `is_ascii16` on 0x7F and 0x80 in
// each lane, and `first_lane16` on each lane under random lanes above it.
@(test, enable_target_feature = FEATURES)
first_lane16_every_lane :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 8)
	testing.expect_value(t, k.first_lane16(#simd[16]u8{}), 16)
	testing.expect(t, !k.any_lane16(#simd[16]u8{}))
	for lane in 0 ..< 16 {
		single: [16]u8
		single[lane] = 0xff
		testing.expectf(t, k.any_lane16(transmute(#simd[16]u8)single), "lane %d", lane)
		single[lane] = 0x80
		testing.expectf(t, !k.is_ascii16(transmute(#simd[16]u8)single), "lane %d", lane)
		single[lane] = 0x7f
		testing.expectf(t, k.is_ascii16(transmute(#simd[16]u8)single), "lane %d", lane)
		for round in 0 ..< testkit.rounds(64) {
			m: [16]u8
			m[lane] = 0xff
			for above in lane + 1 ..< 16 {
				if round > 0 && rand.int_max(2) == 0 {
					m[above] = 0xff
				}
			}
			got := k.first_lane16(transmute(#simd[16]u8)m)
			testing.expectf(t, got == u64(lane), "% x: %d, want %d", m, got, lane)
		}
	}
}

// Checks `last_lane16` on each lane alone and under random lanes below it.
@(test, enable_target_feature = FEATURES)
last_lane16_every_lane :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 14)
	for lane in 0 ..< 16 {
		for round in 0 ..< testkit.rounds(64) {
			m: [16]u8
			m[lane] = 0xff
			for below in 0 ..< lane {
				if round > 0 && rand.int_max(2) == 0 {
					m[below] = 0xff
				}
			}
			got := k.last_lane16(transmute(#simd[16]u8)m)
			testing.expectf(t, got == u64(lane), "% x: %d, want %d", m, got, lane)
		}
	}
}

// Checks `is_ascii` across all 64 lanes (0x7f vs 0x80) and `all_zero` across 16-lane and 64-lane vectors.
@(test, enable_target_feature = FEATURES)
is_ascii_and_all_zero_every_lane :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [64]u8
	testing.expect(t, k.is_ascii(k.load(raw_data(buf[:]))))
	testing.expect(t, k.all_zero(#simd[16]u8{}))
	testing.expect(t, k.all_zero(#simd[64]u8{}))
	for lane in 0 ..< 64 {
		buf[lane] = 0x7f
		testing.expectf(t, k.is_ascii(k.load(raw_data(buf[:]))), "0x7f at lane %d", lane)
		for v in ([3]u8{0x01, 0x80, 0xff}) {
			buf[lane] = v
			testing.expectf(t, !k.all_zero(transmute(#simd[64]u8)buf), "all_zero64 0x%02x at lane %d", v, lane)
			if v >= 0x80 {
				testing.expectf(t, !k.is_ascii(k.load(raw_data(buf[:]))), "0x%02x at lane %d", v, lane)
			}
		}
		buf[lane] = 0
	}
	v16: [16]u8
	for lane in 0 ..< 16 {
		for v in ([3]u8{0x01, 0x80, 0xff}) {
			v16[lane] = v
			testing.expectf(t, !k.all_zero(transmute(#simd[16]u8)v16), "all_zero16 0x%02x at lane %d", v, lane)
		}
		v16[lane] = 0
	}
}

// Checks `compress` against a loop on random and structured keep masks: it stores the kept lanes in order, returns
// their count, and stores nothing past 64 bytes from its start.
@(test, enable_target_feature = FEATURES)
compress_keeps_lanes_in_order :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 9)
	src: [64]u8
	for lane in 0 ..< 64 {
		src[lane] = u8(lane + 1)
	}
	masks: [dynamic]u64
	defer delete(masks)
	append(&masks, 0, ~u64(0), 0xAAAA_AAAA_AAAA_AAAA, 0x5555_5555_5555_5555, 1, 1 << 63, 0xFF, 0xFF00_0000_0000_0000, 0x00FF_FFFF_FFFF_FFFF, 0x01FF_FFFF_FFFF_FFFF)
	for lane in 0 ..< 64 {
		append(&masks, u64(1) << uint(lane))
	}
	for _ in 0 ..< testkit.rounds(4096) {
		append(&masks, rand.uint64())
	}
	for keep in masks {
		out: [64 + 8]u8
		for &b in out {
			b = 0xEE
		}
		got := k.compress(k.load(raw_data(src[:])), keep, raw_data(out[:]))
		n := 0
		for lane in 0 ..< 64 {
			if keep >> u64(lane) & 1 != 0 {
				if !testing.expectf(t, out[n] == src[lane], "keep %x: byte %d is %d, want %d", keep, n, out[n], src[lane]) {
					return
				}
				n += 1
			}
		}
		testing.expectf(t, got == n, "keep %x: count %d, want %d", keep, got, n)
		for b in out[64:] {
			testing.expectf(t, b == 0xEE, "keep %x: stored past 64 bytes", keep)
		}
	}
}

// Checks `index_byte`, `last_index_byte` and `count_byte` against a scalar scan on every prefix of random texts that
// hold the searched byte, its neighbours and a byte with its top bit flipped, for the bytes a record ends on and the
// quote.
@(test)
index_byte_every_cut :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 7)
	buf: [200]u8
	for c in ([3]u8{'\n', 0x1E, '"'}) {
		near := [3]u8{c + 1, c - 1, c ~ 0x80}
		for round in 0 ..< testkit.rounds(40) {
			// Early rounds are dense and later ones sparse, so the first hit falls in every block or in none.
			for &b in buf {
				b = c if rand.int_max(2 + round * 4) == 0 else near[rand.int_max(3)]
			}
			for cut in 0 ..= len(buf) {
				for start in ([2]int{0, min(cut, 1)}) {
					text := buf[start:cut]
					first, last, count := -1, -1, 0
					for b, i in text {
						if b == c {
							first = first if first >= 0 else i
							last = i
							count += 1
						}
					}
					testing.expect_value(t, k.index_byte(text, c), first)
					testing.expect_value(t, k.last_index_byte(text, c), last)
					testing.expect_value(t, k.count_byte(text, c), count)
				}
			}
		}
	}
}

// The bit set of the bytes `of`: bit `b % 64` of word `b / 64` for byte `b`.
member_bits :: proc(of: []u8) -> (bits: [4]u64) {
	for b in of {
		bits[b >> 6] |= u64(1) << (b & 63)
	}
	return
}

// Checks `index_set` against a scan a byte at a time on every cut of random texts, for sets of one byte, a few bytes
// across the nibble rows, bytes above 0x7f, a zero byte (which a padded block holds), every byte but a few, a set of
// 16 distinct nibble rows (which has no bucket form), and one of 8 (which has).
@(test)
index_set_every_cut :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 11)
	buf: [200]u8
	for round in 0 ..< testkit.rounds(80) {
		of: [dynamic]u8
		defer delete(of)
		switch round % 8 {
		case 0:
			append(&of, u8(rand.int_max(256)))
		case 1:
			append(&of, 0)
		case 2:
			for _ in 0 ..< 1 + rand.int_max(6) {
				append(&of, u8(rand.int_max(256)))
			}
		case 3:
			for b in 0x80 ..= 0xFF {
				append(&of, u8(b))
			}
		case 4:
			for b in 0 ..< 256 {
				append(&of, u8(b))
			}
			for _ in 0 ..< 1 + rand.int_max(4) {
				unordered_remove(&of, rand.int_max(len(of)))
			}
		case 5:
			for _ in 0 ..< 1 + rand.int_max(40) {
				append(&of, u8(rand.int_max(128)))
			}
		case 6:
			for h in 0 ..< 16 {
				append(&of, u8(h << 4 | (h + round) % 16))
			}
		case:
			for h in 0 ..< 16 {
				append(&of, u8(h << 4 | (h % 8 + round) % 16))
			}
		}
		members := member_bits(of[:])
		set := k.byte_set(members)
		near: [dynamic]u8
		defer delete(near)
		for c in of {
			append(&near, c + 1, c - 1, c ~ 0x80, c ~ 0x10)
		}
		others: [dynamic]u8
		defer delete(others)
		for b in 0 ..< 256 {
			if members[b >> 6] >> uint(b & 63) & 1 == 0 {
				append(&others, u8(b))
			}
		}
		if len(others) == 0 {
			continue
		}
		for &b in buf {
			b = near[rand.int_max(len(near))]
			if members[b >> 6] >> (b & 63) & 1 == 1 {
				b = rand.choice(others[:])
			}
		}
		for cut in 0 ..= len(buf) {
			testing.expect_value(t, k.index_set(buf[:cut], set), -1)
			if cut == 0 {
				continue
			}
			for at in ([?]int{0, cut / 2, cut - 1}) {
				saved := buf[at]
				buf[at] = of[rand.int_max(len(of))]
				first := -1
				for b, i in buf[:cut] {
					if members[b >> 6] >> (b & 63) & 1 == 1 {
						first = i
						break
					}
				}
				testing.expect_value(t, k.index_set(buf[:cut], set), first)
				testing.expect_value(t, k.index_set(buf[1:cut], set), first - 1 if first > 0 else -1)
				buf[at] = saved
			}
		}
	}
}

// Checks `byte_set` and `index_set` on boundary sets: empty (constructed and zero-value), full 256-byte, and the exact
// 8-vs-9 distinct non-empty row threshold (with empty rows present).
@(test)
byte_set_boundaries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	all: [256]u8
	for i in 0 ..< 256 {
		all[i] = u8(i)
	}
	empty := k.byte_set({})
	zero: k.Byte_Set
	testing.expect(t, empty.buckets)
	testing.expect(t, !zero.buckets)
	testing.expect_value(t, k.index_set(nil, empty), -1)
	testing.expect_value(t, k.index_set(nil, zero), -1)
	for cut in ([?]int{0, 1, 15, 16, 63, 64, 65, 130, 256}) {
		testing.expect_value(t, k.index_set(all[:cut], empty), -1)
		testing.expect_value(t, k.index_set(all[:cut], zero), -1)
	}

	full := k.byte_set({max(u64), max(u64), max(u64), max(u64)})
	testing.expect(t, full.buckets)
	testing.expect_value(t, k.index_set(nil, full), -1)
	testing.expect_value(t, k.index_set(all[:0], full), -1)
	for i in 0 ..< 256 {
		testing.expect_value(t, k.index_set(all[i:], full), 0)
		testing.expect_value(t, k.index_set(all[i:i + 1], full), 0)
	}

	// 8 distinct non-empty rows plus 8 empty rows still fits in the bucket form; a 9th distinct non-empty row drops to
	// the general form.
	eight_bytes := [?]u8{0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77}
	nine_bytes := [?]u8{0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}
	eight := k.byte_set(member_bits(eight_bytes[:]))
	nine := k.byte_set(member_bits(nine_bytes[:]))
	testing.expect(t, eight.buckets)
	testing.expect(t, !nine.buckets)
	for b in 0 ..< 256 {
		want8 := 0 if b < 0x80 && (b >> 4) == (b & 0x0f) else -1
		want9 := 0 if b < 0x90 && (b >> 4) == (b & 0x0f) else -1
		testing.expect_value(t, k.index_set(all[b:b + 1], eight), want8)
		testing.expect_value(t, k.index_set(all[b:b + 1], nine), want9)
	}
}

// Checks `quote_run` and `quote_cut` against a scan a byte at a time, on every stretch of random texts of quotes,
// escapes, brackets and separators, from both starts and both escape carries.
@(test)
quote_scan_every_stretch :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 9)
	alphabet := "\"\\[]{},\nab"
	buf: [160]u8
	for round in 0 ..< testkit.rounds(24) {
		for &b in buf {
			b = alphabet[rand.int_max(len(alphabet) if round % 2 == 0 else 4)]
		}
		for lo := 0; lo < len(buf); lo += 1 + rand.int_max(9) {
			for hi := lo; hi <= len(buf); hi += 1 + rand.int_max(9) {
				text := buf[lo:hi]
				for odd in u64(0) ..= 1 {
					s := k.Quotes{quote = '"', escape = '\\', sep = ',', nest = true, odd = odd}
					k.quote_run(text, &s)
					for g in 0 ..< 2 {
						quoted, want := g == 1, rand.int_max(3)
						esc, depth, low, cut := odd == 1, 0, 0, -1
						// An escape hides only a quote.
						for c, i in text {
							was := esc
							esc = !esc && c == '\\'
							switch {
							case c == '"' && !was: quoted = !quoted
							case quoted:
							case c == '[' || c == '{': depth += 1
							case c == ']' || c == '}':
								depth -= 1
								low = min(low, depth)
								cut = -2 if cut == -1 && depth < 0 else cut
							case c == ',' && cut == -1 && depth == 0: cut = i
							}
						}
						testing.expectf(t, s.depth[g] == depth && s.low[g] == low && s.quoted == (quoted != (g == 1)) && s.odd == u64(esc), "%q from %d: %v", text, g, s)
						from := k.Quotes{quote = '"', escape = '\\', sep = ',', nest = true, odd = odd, quoted = g == 1, want = want}
						from.depth[0] = want
						testing.expectf(t, k.quote_cut(text, from) == max(cut, -1), "%q from %d: cut %d, want %d", text, g, k.quote_cut(text, from), cut)
						from.depth[0] = min(int) / 2
						testing.expectf(t, k.quote_cut(text, from) == -1, "%q from %d below `want`: cut %d", text, g, k.quote_cut(text, from))
					}
				}
			}
		}
	}
}

// Checks `count_byte` and `count_chars` on texts past the 255 blocks a counter holds: all hits, all misses, and random
// bytes, at lengths around the block and round sizes.
@(test)
count_across_counter_rounds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 10)
	buf := make([]u8, 64 * 255 * 2 + 70)
	defer delete(buf)
	for fill in ([3]u8{'\n', 0x80, 'a'}) {
		for &b in buf {
			b = fill
		}
		for n in ([]int{0, 63, 64, 65, 64 * 255 - 1, 64 * 255, 64 * 255 + 1, len(buf)}) {
			testing.expect_value(t, k.count_byte(buf[:n], '\n'), n if fill == '\n' else 0)
			testing.expect_value(t, k.count_chars(buf[:n]), 0 if fill == 0x80 else n)
		}
	}
	for _ in 0 ..< 20 {
		for &b in buf {
			b = u8(rand.int_max(256))
		}
		n := rand.int_max(len(buf) + 1)
		newlines, chars := 0, 0
		for b in buf[:n] {
			newlines += int(b == '\n')
			chars += int(b & 0xC0 != 0x80)
		}
		testing.expect_value(t, k.count_byte(buf[:n], '\n'), newlines)
		testing.expect_value(t, k.count_chars(buf[:n]), chars)
	}
}

// Checks `skip_ws` against a scalar scan from every start in a text of whitespace with one other byte, which moves
// through it, at lengths that end in each part of the loop.
@(test)
skip_ws_stops_at_other_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	ws := [4]u8{' ', '\n', '\t', '\r'}
	buf: [200]u8
	for n in ([]int{0, 3, 4, 5, 64, 67, 68, 69, 131, 132, 200}) {
		for other in 0 ..= n {
			for &b, i in buf[:n] {
				b = ws[i % 4]
			}
			if other < n {
				buf[other] = 'x'
			}
			for from in 0 ..= min(n, other + 1) {
				p := raw_data(buf[:])
				want := other if from <= other else n
				testing.expectf(t, intrinsics.ptr_sub(k.skip_ws(p[from:], p[n:]), p) == want, "length %d, other %d, from %d", n, other, from)
			}
		}
	}
}

// Checks `skip_ws` with every byte value stopping a run of white space, in and past the first block.
@(test)
skip_ws_stops_at_every_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	ws := [4]u8{' ', '\n', '\t', '\r'}
	buf: [140]u8
	for other in 0 ..< 256 {
		is := k.is_ws(u8(other))
		for n in ([]int{64, 70, 135}) {
			for at in ([]int{4, 5, 30, 63, 64, 66, 69, 100, 134}) {
				if at >= n {
					continue
				}
				for &b, i in buf[:n] {
					b = ws[i % 4]
				}
				buf[at] = u8(other)
				p := raw_data(buf[:])
				want := n if is else at
				testing.expectf(t, intrinsics.ptr_sub(k.skip_ws(p, p[n:]), p) == want, "other %d at %d of %d", other, at, n)
			}
		}
	}
}

// Checks `quote_cut` without `nest` against a scan a byte at a time, from inside and outside a quoted run and after an
// odd run of escapes.
@(test)
quote_cut_flat_matches_bytewise :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 11)
	alphabet := "\"\\[]{},\nab"
	buf: [200]u8
	for round in 0 ..< testkit.rounds(40) {
		for &b in buf {
			b = alphabet[rand.int_max(len(alphabet) if round % 2 == 0 else 7)]
		}
		for lo := 0; lo < len(buf); lo += 1 + rand.int_max(7) {
			for hi := lo; hi <= len(buf); hi += 1 + rand.int_max(11) {
				text := buf[lo:hi]
				for odd in u64(0) ..= 1 {
					for g in 0 ..< 2 {
						quoted, esc, cut := g == 1, odd == 1, -1
						for c, i in text {
							was := esc
							esc = !esc && c == '\\'
							if c == '"' && !was {
								quoted = !quoted
							} else if !quoted && c == ',' {
								cut = i
								break
							}
						}
						from := k.Quotes{quote = '"', escape = '\\', sep = ',', odd = odd, quoted = g == 1}
						testing.expectf(t, k.quote_cut(text, from) == cut, "%q from %d", text, g)
					}
				}
			}
		}
	}
}

// Checks `quote_cut` with `nest` from a level at or above `want` against a scan a byte at a time.
@(test)
quote_cut_from_above_want :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 13)
	alphabet := "\"\\[]{},\nab[[{"
	buf: [260]u8
	for _ in 0 ..< testkit.rounds(60) {
		for &b in buf {
			b = alphabet[rand.int_max(len(alphabet))]
		}
		for lo := 0; lo < len(buf); lo += 1 + rand.int_max(13) {
			for hi := lo; hi <= len(buf); hi += 1 + rand.int_max(17) {
				text := buf[lo:hi]
				for g in 0 ..< 2 {
					want := rand.int_max(3) - 1
					start := want + rand.int_max(6)
					quoted, esc, depth, cut := g == 1, false, start, -1
					scan: for c, i in text {
						was := esc
						esc = !esc && c == '\\'
						switch {
						case c == '"' && !was:
							quoted = !quoted
						case quoted:
						case c == '[' || c == '{':
							depth += 1
						case c == ']' || c == '}':
							if depth <= want {
								break scan
							}
							depth -= 1
						case c == ',' && depth == want:
							cut = i
							break scan
						}
					}
					from := k.Quotes{quote = '"', escape = '\\', sep = ',', nest = true, quoted = g == 1, want = want}
					from.depth[0] = start
					testing.expectf(t, k.quote_cut(text, from) == cut, "%q from %d at %d want %d", text, g, start, want)
				}
			}
		}
	}
}

// Checks the searches and counts on texts in memory filled with the byte they look for, so a lane read past either
// end shows.
@(test)
scans_ignore_bytes_around :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [160]u8
	for c in ([2]u8{0, 0x80}) {
		for n in 0 ..< 140 {
			for at in -1 ..< n {
				for &b in buf {
					b = c
				}
				text := buf[8:8 + n]
				for &b in text {
					b = 'a' if c == 0 else 0xC3
				}
				first := -1
				if at >= 0 {
					text[at] = c
					first = at
				}
				testing.expectf(t, k.index_byte(text, c) == first, "index n %d at %d", n, at)
				testing.expectf(t, k.last_index_byte(text, c) == first, "last n %d at %d", n, at)
				testing.expectf(t, k.count_byte(text, c) == int(at >= 0), "count n %d at %d", n, at)
				want := n - (int(at >= 0) if c == 0x80 else 0)
				testing.expectf(t, k.count_chars(text) == want, "chars n %d at %d", n, at)
			}
		}
	}
}

// Checks every scan on texts that end where readable memory ends, so a read past them faults, against copies far from
// a page end, where the tail loads read past the text. Every other text is whole UTF-8 sequences.
@(test)
scans_stop_at_unmapped_memory :: proc(t: ^testing.T) {
	testkit.deadline(t)
	SIZE :: 64 * 1024
	region, err := virtual.reserve(2 * SIZE)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer virtual.release(raw_data(region), 2 * SIZE)
	if !testing.expect_value(t, virtual.commit(raw_data(region), SIZE), nil) {
		return
	}
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 17)
	pieces := [?]string{"\"", "\\", "[", "]", "{", "}", ",", " ", "\xc3\xa9", "\xe2\x82\xac", "a", "b"}
	for n in 0 ..< 280 {
		edge := region[SIZE - n:SIZE]
		for i := 0; i < n; {
			piece := pieces[rand.int_max(len(pieces))]
			if n % 2 == 1 || len(piece) > n - i {
				piece = piece[:1] if n % 2 == 1 else "a"
			}
			i += copy(edge[i:], piece)
		}
		mid := region[1024:1024 + n]
		copy(mid, edge)
		testing.expectf(t, k.index_byte(edge, ',') == k.index_byte(mid, ','), "index_byte %d", n)
		testing.expectf(t, k.last_index_byte(edge, ',') == k.last_index_byte(mid, ','), "last_index_byte %d", n)
		testing.expectf(t, k.count_byte(edge, '"') == k.count_byte(mid, '"'), "count_byte %d", n)
		testing.expectf(t, k.count_chars(edge) == k.count_chars(mid), "count_chars %d", n)
		set := k.byte_set(member_bits({',', 0, 0xC3}))
		testing.expectf(t, k.index_set(edge, set) == k.index_set(mid, set), "index_set %d", n)
		general := k.byte_set(member_bits({',', 0, 0xC3, 0x11, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}))
		testing.expect(t, !general.buckets)
		testing.expectf(t, k.index_set(edge, general) == k.index_set(mid, general), "index_set general %d", n)
		testing.expectf(t, k.utf8_valid(edge) == k.utf8_valid(mid), "utf8_valid %d", n)
		for nest in ([2]bool{false, true}) {
			cut := k.Quotes{quote = '"', escape = '\\', sep = ',', nest = nest}
			testing.expectf(t, k.quote_cut(edge, cut) == k.quote_cut(mid, cut), "quote_cut %d nest %v", n, nest)
			a, b := k.Quotes{quote = '"', escape = '\\', nest = nest}, k.Quotes{quote = '"', escape = '\\', nest = nest}
			k.quote_run(edge, &a)
			k.quote_run(mid, &b)
			testing.expectf(t, a == b, "quote_run %d nest %v", n, nest)
		}
		p, q := raw_data(edge), raw_data(mid)
		testing.expectf(t, intrinsics.ptr_sub(k.skip_ws(p, p[n:]), p) == intrinsics.ptr_sub(k.skip_ws(q, q[n:]), q), "skip_ws %d", n)
	}
}

// `head16` and `load_padded` read past a text's end wherever the load stays in its page, which includes a text that
// starts at the page's first byte, and wherever it does not they copy.
@(test)
reads_past_the_end_stay_in_the_page :: proc(t: ^testing.T) {
	testkit.deadline(t)
	PAGE :: 4096
	region, err := virtual.reserve(2 * PAGE)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer virtual.release(raw_data(region), 2 * PAGE)
	if !testing.expect_value(t, virtual.commit(raw_data(region), 2 * PAGE), nil) {
		return
	}
	for &b, i in region {
		b = u8(i % 251 + 1)
	}
	sanitized := ODIN_SANITIZER_FLAGS != {}
	// A load of 16 bytes at `at` may read past the text where it ends in the page.
	for at in ([]int{0, 1, 2, PAGE - 17, PAGE - 16, PAGE - 15, PAGE - 1, PAGE, PAGE + 1}) {
		v, live, ok := k.head16(raw_data(region)[at:], 5)
		want := !sanitized && at % PAGE <= PAGE - 16
		testing.expectf(t, ok == want, "head16 at page offset %d: %v, want %v", at % PAGE, ok, want)
		if ok {
			got_v := transmute([16]u8)v
			got_live := transmute([16]u8)live
			for i in 0 ..< 16 {
				if i < 5 {
					testing.expectf(t, got_v[i] == region[at + i], "head16 v[%d] at %d", i, at)
				}
				testing.expectf(t, got_live[i] == (0xFF if i < 5 else 0), "head16 live[%d] at %d", i, at)
			}
		}
	}
	// Check every live length `n` in `1..15` returns exact prefix bytes and mask.
	for n in 1 ..< 16 {
		at := 37
		v, live, ok := k.head16(raw_data(region)[at:], n)
		testing.expect_value(t, ok, !sanitized)
		if ok {
			got_v := transmute([16]u8)v
			got_live := transmute([16]u8)live
			for i in 0 ..< 16 {
				if i < n {
					testing.expectf(t, got_v[i] == region[at + i], "head16 n=%d v[%d]", n, i)
				}
				testing.expectf(t, got_live[i] == (0xFF if i < n else 0), "head16 n=%d live[%d]", n, i)
			}
		}
	}
	_, _, ok := k.head16(nil, 5)
	testing.expect(t, !ok, "head16 of nil")
	// The block is the text's bytes then zeros, wherever the text lies against the page, for `lo == 0` and `lo > 0`.
	for at in ([]int{0, 1, PAGE - 64, PAGE - 63, PAGE - 40, PAGE, PAGE + 1}) {
		for n in 1 ..< 64 {
			text := region[at:at + n]
			b := k.load_padded(text, 0)
			got := transmute([64]u8)b
			for i in 0 ..< 64 {
				want := text[i] if i < n else 0
				if got[i] != want {
					testing.expectf(t, false, "load_padded of %d bytes at %d: byte %d is %d, want %d", n, at, i, got[i], want)
					break
				}
			}
		}
	}
	// `load_padded` with `lo > 0` and `load_block` across `1..=65` remaining bytes, including page-crossing starts.
	for lo in ([]int{0, 1, 7, 17, 64, PAGE - 64, PAGE - 63, PAGE - 31, PAGE}) {
		for rem in 1 ..= 65 {
			src := region[:lo + rem]
			if rem < 64 {
				got_pad := transmute([64]u8)k.load_padded(src, lo)
				for i in 0 ..< 64 {
					want := src[lo + i] if i < rem else 0
					if got_pad[i] != want {
						testing.expectf(t, false, "load_padded lo=%d rem=%d byte %d: %d, want %d", lo, rem, i, got_pad[i], want)
						break
					}
				}
			}
			got_blk := transmute([64]u8)k.load_block(src, lo)
			for i in 0 ..< 64 {
				want := src[lo + i] if i < rem else 0
				if got_blk[i] != want {
					testing.expectf(t, false, "load_block lo=%d rem=%d byte %d: %d, want %d", lo, rem, i, got_blk[i], want)
					break
				}
			}
		}
	}
}

@(test, enable_target_feature = FEATURES)
control_or_high16_every_byte_and_lane :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Every byte value in every lane, surrounded by printable ASCII, for both `del = false` and `del = true`.
	for byte_val in 0 ..< 256 {
		c := u8(byte_val)
		want_no_del: u8 = 0xFF if (c < 0x20 || c >= 0x80) else 0
		want_del: u8 = 0xFF if (c < 0x20 || c == 0x7f || c >= 0x80) else 0
		for lane in 0 ..< 16 {
			in_bytes: [16]u8 = 'a'
			in_bytes[lane] = c
			v := transmute(#simd[16]u8)in_bytes
			got_no_del := transmute([16]u8)k.control_or_high16(v, false)
			got_del := transmute([16]u8)k.control_or_high16(v, true)
			for i in 0 ..< 16 {
				w0 := want_no_del if i == lane else 0
				w1 := want_del if i == lane else 0
				if got_no_del[i] != w0 {
					testing.expectf(t, false, "control_or_high16(0x%02x, false) lane %d at %d: 0x%02x, want 0x%02x", c, lane, i, got_no_del[i], w0)
					return
				}
				if got_del[i] != w1 {
					testing.expectf(t, false, "control_or_high16(0x%02x, true) lane %d at %d: 0x%02x, want 0x%02x", c, lane, i, got_del[i], w1)
					return
				}
			}
		}
	}
	// Full 16-lane sweep across all 256 bytes in consecutive chunks of 16.
	for base := 0; base < 256; base += 16 {
		in_bytes: [16]u8
		for i in 0 ..< 16 {
			in_bytes[i] = u8(base + i)
		}
		v := transmute(#simd[16]u8)in_bytes
		got_no_del := transmute([16]u8)k.control_or_high16(v, false)
		got_del := transmute([16]u8)k.control_or_high16(v, true)
		for i in 0 ..< 16 {
			c := in_bytes[i]
			testing.expect_value(t, got_no_del[i], u8(0xFF if (c < 0x20 || c >= 0x80) else 0))
			testing.expect_value(t, got_del[i], u8(0xFF if (c < 0x20 || c == 0x7f || c >= 0x80) else 0))
		}
	}
}

@(test)
live16_every_length :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for n in 0 ..= 16 {
		got := transmute([16]u8)k.live16(n)
		for i in 0 ..< 16 {
			want: u8 = 0xFF if i < n else 0
			testing.expectf(t, got[i] == want, "live16(%d)[%d]: 0x%02x, want 0x%02x", n, i, got[i], want)
		}
	}
}

@(test)
load8_and_store16_unaligned :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src: [32]u8
	for &b, i in src {
		b = u8(0x11 + i * 7)
	}
	for off in 0 ..< 8 {
		got := k.load8(raw_data(src[off:]))
		want: u64
		for j in 0 ..< 8 {
			want |= u64(src[off + j]) << uint(j * 8)
		}
		testing.expectf(t, got == want, "load8 off=%d: 0x%016x, want 0x%016x", off, got, want)
	}
	payload: [16]u8
	for &b, i in payload {
		b = u8(0xA0 + i)
	}
	vec := transmute(#simd[16]u8)payload
	for off in 0 ..< 16 {
		dst: [48]u8 = 0x55
		k.store16(raw_data(dst[off:]), vec)
		for i in 0 ..< len(dst) {
			want: u8 = payload[i - off] if (i >= off && i < off + 16) else 0x55
			testing.expectf(t, dst[i] == want, "store16 off=%d byte %d: 0x%02x, want 0x%02x", off, i, dst[i], want)
		}
	}
}
