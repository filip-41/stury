package kernel_tests

import "core:math/rand"
import "core:testing"
import "core:unicode/utf8"
import k ".."

// Whether `src` is UTF-8 by the kernel, block by block, ASCII blocks taken by `utf8_ascii_block` when `skip_ascii`.
@(enable_target_feature = FEATURES)
kernel_utf8 :: proc(src: []u8, skip_ascii: bool) -> bool {
	s: k.Utf8_State
	for lo := 0; lo < len(src); lo += 64 {
		b := lo + 64 <= len(src) ? k.load(raw_data(src[lo:])) : k.load_padded(T, src, lo)
		if skip_ascii && k.is_ascii(b) {
			k.utf8_ascii_block(&s)
		} else {
			k.utf8_block(b, &s)
		}
	}
	return k.utf8_ok(s)
}

check_utf8 :: proc(t: ^testing.T, src: []u8, loc := #caller_location) {
	want := utf8.valid_string(string(src))
	for skip in ([2]bool{false, true}) {
		got := kernel_utf8(src, skip)
		testing.expectf(t, got == want, "% x, skip ascii %v: %v, want %v", src, skip, got, want, loc = loc)
	}
}

// Every pair of bytes, followed by two bytes that continue, end or break a sequence, where a 16-byte window ends,
// and where a block ends.
@(test)
utf8_every_pair :: proc(t: ^testing.T) {
	buf: [128]u8
	for &b in buf {
		b = 'a'
	}
	for at in ([]int{14, 15, 62, 63, 126}) {
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

// Inputs of every length up to three blocks that end in a lead byte and fewer continuation bytes than it needs, or
// exactly as many: an open sequence at the end of a full block or of a padded tail.
@(test)
utf8_sequence_at_end :: proc(t: ^testing.T) {
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

// Random text of valid characters of every size, now and then broken by a random byte, over runs of ASCII blocks.
@(test)
utf8_random_text :: proc(t: ^testing.T) {
	state := rand.create(6)
	context.random_generator = rand.default_random_generator(&state)
	chars := []rune{'a', 'a', 'a', 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xfffd, 0xffff, 0x10000, 0x10ffff}
	buf: [64 * 6]u8
	for _ in 0 ..< 20000 {
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
