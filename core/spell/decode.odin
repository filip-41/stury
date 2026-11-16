package spell

// A node's text as a format decodes it: written into a buffer, or compared with a key without one. A format gives
// either a decoder `next` that returns one decoded byte at a time (json, dsv) or a `decode` that writes the whole text
// into a buffer (cbor, toml, yaml).

import "base:intrinsics"
import "base:runtime"

// Writes the bytes `next` returns from decoder state `d` into `buf`. Returns false as soon as `buf` is full while the
// decoder has more, and `buf`'s content is then unspecified.
decode_text :: proc "contextless" (buf: []u8, d: $D, $next: proc "contextless" (^D) -> (u8, bool)) -> (s: string, ok: bool) {
	d := d
	at := 0
	for {
		b, more := next(&d)
		if !more {
			return string(buf[:at]), true
		}
		if at == len(buf) {
			return "", false
		}
		buf[at] = b
		at += 1
	}
}

// Whether the bytes `next` returns from decoder state `d` are `name`.
decoded_equals :: proc "contextless" (d: $D, $next: proc "contextless" (^D) -> (u8, bool), name: string) -> bool {
	d := d
	at := 0
	for {
		b, more := next(&d)
		if !more {
			return at == len(name)
		}
		if at >= len(name) || name[at] != b {
			return false
		}
		at += 1
	}
}

// Whether the text `decode` writes for `c` into a buffer of `room` bytes is `name`. Up to 256 bytes the buffer is on the
// stack. A larger one is allocated with the default heap allocator, since a key compare has no context, and an
// allocation that fails is false.
buffered_equals :: proc "contextless" (room: int, name: string, c: rawptr, decode: proc "contextless" (rawptr, []u8) -> (string, bool)) -> bool {
	stack: [256]u8 = ---
	buf := stack[:]
	heap: []u8
	if room > len(stack) {
		context = runtime.default_context()
		heap = make([]u8, room)
		if heap == nil {
			return false
		}
		buf = heap
	}
	s, ok := decode(c, buf)
	equal := ok && s == name
	if heap != nil {
		context = runtime.default_context()
		delete(heap)
	}
	return equal
}

// The bytes of a decoded character after the first, which a decoder returns before it reads on. `buf[at:end]` remain.
Pending :: struct {
	buf:     [4]u8,
	at, end: u8,
}

// Returns the next byte `pending_give` left in `p`, or false when none remain.
pending_next :: #force_inline proc "contextless" (p: ^Pending) -> (b: u8, ok: bool) {
	if p.at == p.end {
		return 0, false
	}
	b = p.buf[p.at]
	p.at += 1
	return b, true
}

// Leaves the bytes of `spelled` after the first of `size` in `p`, and returns the first, which the decoder returns now.
pending_give :: #force_inline proc "contextless" (p: ^Pending, spelled: [4]u8, size: int) -> u8 {
	p.buf = spelled
	p.at = 1
	p.end = u8(size)
	return spelled[0]
}

// Whether byte strings `a` and `b` are equal. Below 8 bytes it compares a byte at a time, up to 16 bytes with two
// overlapping 8-byte loads that stay inside both strings, and past that by 8-byte words and then the tail.
bytes_equal :: #force_inline proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	n := len(a)
	#no_bounds_check {
		if n < 8 {
			for i in 0 ..< n {
				if a[i] != b[i] {
					return false
				}
			}
			return true
		}
		if n <= 16 {
			return intrinsics.unaligned_load((^u64)(raw_data(a))) == intrinsics.unaligned_load((^u64)(raw_data(b))) &&
				intrinsics.unaligned_load((^u64)(raw_data(a)[n - 8:])) == intrinsics.unaligned_load((^u64)(raw_data(b)[n - 8:]))
		}
		i := 0
		for i + 8 <= n {
			if intrinsics.unaligned_load((^u64)(raw_data(a)[i:])) != intrinsics.unaligned_load((^u64)(raw_data(b)[i:])) {
				return false
			}
			i += 8
		}
		for i < n {
			if a[i] != b[i] {
				return false
			}
			i += 1
		}
		return true
	}
}

// Whether `a` and `b` are equal with their ASCII letters compared case-insensitively.
ascii_fold_equal :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if (x | 0x20 if x - 'A' < 26 else x) != (y | 0x20 if y - 'A' < 26 else y) {
			return false
		}
	}
	return true
}
