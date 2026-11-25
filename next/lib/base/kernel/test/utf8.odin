package kernel_tests

import "base:intrinsics"
import "core:math/rand"
import "core:simd"
import "core:testing"
import "core:unicode/utf8"
import k "stury:lib/base/kernel"
import "stury:testkit"

// Returns whether the kernel finds `src` valid UTF-8, a 64-byte block at a time, skipping ASCII blocks when
// `skip_ascii` is set.
@(enable_target_feature = FEATURES)
kernel_utf8 :: proc(src: []u8, skip_ascii: bool) -> bool {
	s: k.Utf8_State
	high: bool
	for lo := 0; lo < len(src); lo += 64 {
		b := k.load_block(src, lo)
		k.utf8_next(T, b, skip_ascii && k.is_ascii(b), &s, &high)
	}
	return k.utf8_ok(s)
}

// Checks `kernel_utf8`, with and without skipping ASCII blocks, and `utf8_valid` against the standard library.
check_utf8 :: proc(t: ^testing.T, src: []u8, loc := #caller_location) {
	want := utf8.valid_string(string(src))
	for skip in ([2]bool{false, true}) {
		got := kernel_utf8(src, skip)
		testing.expectf(t, got == want, "% x, skip ascii %v: %v, want %v", src, skip, got, want, loc = loc)
	}
	got := k.utf8_valid(src)
	testing.expectf(t, got == want, "% x, utf8_valid: %v, want %v", src, got, want, loc = loc)
}

// Each pair of bytes followed by two bytes that continue, end or break a sequence, placed where a 16-byte vector
// ends and where the 128-byte text ends.
@(test)
utf8_every_pair :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [128]u8
	for &b in buf {
		b = 'a'
	}
	for at in ([]int{14, 15, 30, 31, 46, 47, 62, 63, 126}) {
		for a in 0 ..< 256 {
			for b in 0 ..< 256 {
				for c in ([]u8{'a', 0x80, 0xbf, 0xc2}) {
					for d in ([]u8{'a', 0x80, 0xbf, 0xc2}) {
						seq := [4]u8{u8(a), u8(b), c, d}
						n := min(4, len(buf) - at)
						copy(buf[at:], seq[:n])
						check_utf8(t, buf[:])
						for &x in buf[at:][:n] {
							x = 'a'
						}
					}
				}
			}
		}
	}
}

// Inputs of 1 to 192 bytes ending in a lead byte with fewer continuation bytes than its size needs, so an open
// sequence ends a full block or a padded tail.
@(test)
utf8_sequence_at_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [192]u8
	for n in 1 ..= len(buf) {
		for lead in ([]u8{0xc2, 0xdf, 0xe0, 0xe1, 0xed, 0xef, 0xf0, 0xf3, 0xf4}) {
			size := lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4
			second := u8(lead == 0xe0 ? 0xa0 : lead == 0xf0 ? 0x90 : 0x80)
			for conts in 0 ..< size {
				if conts + 1 > n {
					break
				}
				for &b in buf[:n] {
					b = 'a'
				}
				at := n - conts - 1
				buf[at] = lead
				for i in 1 ..= conts {
					buf[at + i] = i == 1 ? second : 0x80
				}
				check_utf8(t, buf[:n])
			}
		}
	}
}

// Random text of valid characters of every UTF-8 size, with a random run of ASCII bytes, then 0 to 2 random bytes.
@(test)
utf8_random_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 6)
	chars := []rune{'a', 'a', 'a', 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xfffd, 0xffff, 0x10000, 0x10ffff}
	buf: [64 * 6]u8
	for _ in 0 ..< testkit.rounds(20000) {
		n := 1 + rand.int_max(len(buf))
		ascii_from, ascii_to := rand.int_max(n), rand.int_max(n)
		for i := 0; i < n; {
			bytes, size := utf8.encode_rune(rand.choice(chars))
			if ascii_from <= i && i < ascii_to {
				bytes, size = {'a', 0, 0, 0}, 1
			}
			size = min(size, n - i)
			copy(buf[i:], bytes[:size])
			i += size
		}
		for _ in 0 ..< rand.int_max(3) {
			buf[rand.int_max(n)] = u8(rand.int_max(256))
		}
		check_utf8(t, buf[:n])
	}
}

// Returns whether `src` holds no error, with a sequence open at its end allowed. It is clean when `src` plus one of
// the shortest completions of a lead byte is valid UTF-8. A last byte that is a lead no byte completes, 0xC0, 0xC1 or
// 0xF5 and up, reads as the lead of its length that some byte does.
reference_clean :: proc(src: []u8) -> bool {
	if utf8.valid_string(string(src)) {
		return true
	}
	buf: [64 * 4 + 3]u8
	copy(buf[:], src)
	if n := len(src); n > 0 {
		switch buf[n - 1] {
		case 0xc0, 0xc1:
			buf[n - 1] = 0xc2
		case 0xf5 ..= 0xff:
			buf[n - 1] = 0xf0
		}
	}
	for second in ([]u8{0x80, 0x90, 0xa0}) {
		for rest in 0 ..< 3 {
			buf[len(src)] = second
			for i in 1 ..= rest {
				buf[len(src) + i] = 0x80
			}
			if utf8.valid_string(string(buf[:len(src) + 1 + rest])) {
				return true
			}
		}
	}
	return false
}

// Random text of 64 to 256 bytes, often cut inside a sequence, then 0 to 2 random bytes. Checks `utf8_clean` after
// the whole blocks against `reference_clean`.
@(test, enable_target_feature = FEATURES)
utf8_clean_at_block_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 9)
	chars := []rune{'a', 0x80, 0x7ff, 0x800, 0xffff, 0x10000, 0x10ffff}
	buf: [64 * 4 + 3]u8
	for _ in 0 ..< testkit.rounds(20000) {
		n := 64 * (1 + rand.int_max(4))
		for i := 0; i < len(buf); {
			bytes, size := utf8.encode_rune(rand.choice(chars))
			size = min(size, len(buf) - i)
			copy(buf[i:], bytes[:size])
			i += size
		}
		for _ in 0 ..< rand.int_max(3) {
			buf[rand.int_max(n)] = u8(rand.int_max(256))
		}
		s: k.Utf8_State
		high: bool
		for lo := 0; lo < n; lo += 64 {
			k.utf8_next(T, k.load(raw_data(buf[lo:])), false, &s, &high)
		}
		want := reference_clean(buf[:n])
		testing.expectf(t, k.utf8_clean(T, s) == want, "% x: %v, want %v", buf[n - 8:n], !want, want)
	}
}

// Whether `utf8_window` finds no fault in `src` read as 16-byte windows after a window of zeros, with ASCII after it so
// a sequence left open shows.
@(enable_target_feature = FEATURES)
window_utf8 :: proc(src: []u8) -> bool {
	buf: [64]u8
	for &b in buf {
		b = 'a'
	}
	copy(buf[:], src)
	prev, err: #simd[16]u8
	for lo := 0; lo < len(buf); lo += 16 {
		v := intrinsics.unaligned_load((^#simd[16]u8)(raw_data(buf[lo:])))
		err = simd.bit_or(err, k.utf8_window(prev, v))
		prev = v
	}
	return simd.reduce_or(err) == 0
}

// Every pair of bytes followed by two others, placed across a 16-byte window edge, against `core:unicode/utf8`.
@(test)
utf8_window_every_pair :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [48]u8
	for &b in buf {
		b = 'a'
	}
	for at in ([]int{14, 15, 30, 44}) {
		n := min(4, len(buf) - at)
		for a in 0 ..< 256 {
			for b in 0 ..< 256 {
				for c in ([]u8{'a', 0x80, 0xbf}) {
					seq := [4]u8{u8(a), u8(b), c, 0x80}
					copy(buf[at:], seq[:n])
					want := utf8.valid_string(string(buf[:]))
					testing.expectf(t, window_utf8(buf[:]) == want, "% x", buf)
					for &x in buf[at:][:n] {
						x = 'a'
					}
				}
			}
		}
	}
}

// Each lead byte at every position of a text of several blocks, followed by none to four continuation bytes, so the
// bytes it makes continuations cross every register and block boundary, and ASCII blocks follow it.
@(test)
utf8_lead_every_position :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [300]u8
	for at in 0 ..< len(buf) {
		for lead in ([]u8{0xc2, 0xe1, 0xed, 0xf0, 0xf4}) {
			for conts in 0 ..= 4 {
				for &b in buf {
					b = 'a'
				}
				buf[at] = lead
				for i in 1 ..= conts {
					if at + i < len(buf) {
						buf[at + i] = 0x90 if lead == 0xf0 && i == 1 else 0x80
					}
				}
				check_utf8(t, buf[:])
			}
		}
	}
}

// Whether `utf8_stop` of the register holding byte `last` finds `buf[:last + 1]` clean, as a text of one block.
@(enable_target_feature = FEATURES)
stop_clean :: proc(buf: ^[64]u8, last: int) -> bool {
	s: k.Utf8_State
	b := k.load(raw_data(buf[:]))
	return k.utf8_stop(T, b, k.is_ascii(b), &s, false, u64(last))
}

// Empty and nil slices are valid UTF-8.
@(test)
utf8_valid_empty :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect(t, k.utf8_valid(nil), "nil slice read as invalid UTF-8")
	empty: []u8
	testing.expect(t, k.utf8_valid(empty), "empty slice read as invalid UTF-8")
	buf: [1]u8
	testing.expect(t, k.utf8_valid(buf[:0]), "zero-length subslice read as invalid UTF-8")
}

// Runs `prev` through `utf8_next` and then stops on `next` at `last` with `high == true`.
@(enable_target_feature = FEATURES)
stop_after_block :: proc(prev, next: ^[64]u8, last: int) -> bool {
	s: k.Utf8_State
	high: bool
	pb := k.load(raw_data(prev[:]))
	k.utf8_next(T, pb, k.is_ascii(pb), &s, &high)
	nb := k.load(raw_data(next[:]))
	return k.utf8_stop(T, nb, k.is_ascii(nb), &s, high, u64(last))
}

// `utf8_stop` with `high == true` at `last == 0`: catches an open 2-, 3-, or 4-byte sequence from the prior block,
// and accepts a completed sequence, for both all-ASCII `next` and non-ASCII junk past `last`.
@(test)
utf8_stop_with_high_at_zero :: proc(t: ^testing.T) {
	testkit.deadline(t)
	open_tails := [][]u8{
		{0xc2},
		{0xe2},
		{0xe2, 0x82},
		{0xf0},
		{0xf0, 0x9f},
		{0xf0, 0x9f, 0x9a},
	}
	for tail in open_tails {
		prev: [64]u8
		for &b in prev {
			b = 'a'
		}
		copy(prev[64 - len(tail):], tail)
		for ascii in ([2]bool{true, false}) {
			next: [64]u8
			for &b in next {
				b = 'a'
			}
			next[0] = '"'
			if !ascii {
				next[1] = 0xff
				next[2] = 0x80
			}
			testing.expectf(t, !stop_after_block(&prev, &next, 0), "open tail % x, ascii %v: passed", tail, ascii)
		}
	}
	closed_tails := [][]u8{
		{0xc3, 0xa9},
		{0xe2, 0x82, 0xac},
		{0xf0, 0x9f, 0x9a, 0x80},
	}
	for tail in closed_tails {
		prev: [64]u8
		for &b in prev {
			b = 'a'
		}
		copy(prev[64 - len(tail):], tail)
		for ascii in ([2]bool{true, false}) {
			next: [64]u8
			for &b in next {
				b = 'a'
			}
			next[0] = '"'
			if !ascii {
				next[1] = 0xff
				next[2] = 0xc0
			}
			testing.expectf(t, stop_after_block(&prev, &next, 0), "closed tail % x, ascii %v: failed", tail, ascii)
		}
	}
}

// `utf8_stop` checks the bytes up to its stop and none past it, though they share the register: random text with a
// stop at each place, then bytes that are no UTF-8, or begin or continue a sequence, right after it.
@(test)
utf8_stop_ignores_bytes_past_the_stop :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 23)
	chars := []rune{'a', 0x80, 0x7ff, 0x800, 0xffff, 0x10000, 0x10ffff}
	junk := []u8{0xff, 0x80, 0xc0, 0xc3, 0xe2, 0xf5, 0xed, 0xa0, 0xf4}
	buf: [64]u8
	for _ in 0 ..< testkit.rounds(4000) {
		for i := 0; i < len(buf); {
			bytes, size := utf8.encode_rune(rand.choice(chars))
			size = min(size, len(buf) - i)
			copy(buf[i:], bytes[:size])
			i += size
		}
		last := rand.int_max(len(buf))
		for &b in buf[last + 1:] {
			b = rand.choice(junk)
		}
		// A fault in the stop byte itself shows only once a byte follows it, so the damage lies before it.
		for _ in 0 ..< rand.int_max(2) {
			if last > 0 {
				buf[rand.int_max(last)] = u8(rand.int_max(256))
			}
		}
		want := reference_clean(buf[:last + 1])
		testing.expectf(t, stop_clean(&buf, last) == want, "last %d: % x, want %v", last, buf, want)
	}
}

// A valid string followed in its register by bytes that are no UTF-8, as in a JSONC comment after a string.
@(test)
utf8_stop_after_a_quote :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for last in 0 ..< 63 {
		for tail in ([]string{"\xff", "\xc3", "\x80\x80", "\xe2\x82", "\xed\xa0\x80", "\xc3\xa9\xff"}) {
			buf: [64]u8
			for &b in buf {
				b = 'a'
			}
			copy(buf[last + 1:], transmute([]u8)tail)
			testing.expectf(t, stop_clean(&buf, last), "last %d, tail % x", last, transmute([]u8)tail)
		}
	}
}
