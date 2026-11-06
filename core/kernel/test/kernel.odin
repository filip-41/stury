package kernel_tests

import "core:math/rand"
import "core:testing"
import k ".."

// Returns the table sorting bytes into `sets`, and each set's bits. The bench uses it too.
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

// The tier under test, by its index in `k.Tier`: `-define:TIER=2` is v4 on x86-64. The kernels run in procedures
// compiled with the tier's features, as a caller's hot loops are.
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
// neighbours, and checks `pack_n` against `pack` for the four masks.
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
	}
}

@(test)
classes_of_every_byte :: proc(t: ^testing.T) {
	state := rand.create(3)
	context.random_generator = rand.default_random_generator(&state)
	check_sets(t, {"\"", "\\", ",:[]{}", " \t\n\r"})
	check_sets(t, {",", "\"", "\n\r"})
	// 500 random families with up to eight pairs of a set and a high nibble, bytes above 0x7f, and bytes in two sets.
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

// Sets bit `i % 64` of `quotes[i / 64]` for each quote in `src` that no backslash escapes. A backslash escapes the
// next byte unless it is escaped itself.
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
	// A run of 1 to 128 backslashes ending at each byte of the third block, then a quote.
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
	// Random blocks from four alphabets: a quote and a backslash in every 3 bytes, then 1 quote and 3 backslashes in 8,
	// 1 quote in 28, and 1 quote and 1 backslash in 50.
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

// Checks `first_lane` on the empty mask (16), on each lane alone, and on each lane under random lanes above it.
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

// Checks `any_lane16` on the empty mask and on each lane alone.
@(test, enable_target_feature = FEATURES)
any_lane16_every_lane :: proc(t: ^testing.T) {
	testing.expect(t, !k.any_lane16(#simd[16]u8{}))
	for lane in 0 ..< 16 {
		m: [16]u8
		m[lane] = 0xff
		testing.expectf(t, k.any_lane16(transmute(#simd[16]u8)m), "lane %d", lane)
	}
}

// Checks `compress` against a loop on random and structured keep masks: it stores the kept lanes in order, returns their
// count, and stores nothing past 64 bytes from its start.
@(test, enable_target_feature = FEATURES)
compress_keeps_lanes_in_order :: proc(t: ^testing.T) {
	state := rand.create(9)
	context.random_generator = rand.default_random_generator(&state)
	src: [64]u8
	for lane in 0 ..< 64 {
		src[lane] = u8(lane + 1)
	}
	masks: [dynamic]u64
	defer delete(masks)
	append(&masks, 0, ~u64(0), 0xAAAA_AAAA_AAAA_AAAA, 0x5555_5555_5555_5555, 1, 1 << 63, 0xFF, 0xFF00_0000_0000_0000)
	for _ in 0 ..< 4096 {
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

// Checks `index_byte` and `last_index_byte` against a scalar scan on every prefix of random texts that hold the searched
// byte, its neighbours and a byte with its top bit flipped, for the bytes a record ends on and the quote.
@(test)
index_byte_every_cut :: proc(t: ^testing.T) {
	state := rand.create(7)
	context.random_generator = rand.default_random_generator(&state)
	buf: [200]u8
	for c in ([3]u8{'\n', 0x1E, '"'}) {
		near := [3]u8{c + 1, c - 1, c ~ 0x80}
		for round in 0 ..< 40 {
			// Early rounds are dense and later ones sparse, so the first hit falls in every block or in none.
			for &b in buf {
				b = c if rand.int_max(2 + round * 4) == 0 else near[rand.int_max(3)]
			}
			for cut in 0 ..= len(buf) {
				for start in ([2]int{0, min(cut, 1)}) {
					text := buf[start:cut]
					first, last := -1, -1
					for b, i in text {
						if b == c {
							first = first if first >= 0 else i
							last = i
						}
					}
					testing.expect_value(t, k.index_byte(text, c), first)
					testing.expect_value(t, k.last_index_byte(text, c), last)
				}
			}
		}
	}
}

// Checks `quote_run` and `quote_cut` against a scan a byte at a time, on every stretch of random texts of quotes,
// escapes, brackets and separators, from both starts and both escape carries.
@(test)
quote_scan_every_stretch :: proc(t: ^testing.T) {
	state := rand.create(9)
	context.random_generator = rand.default_random_generator(&state)
	alphabet := "\"\\[]{},\nab"
	buf: [160]u8
	for round in 0 ..< 24 {
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
