package spell

import "base:intrinsics"
import "base:runtime"

// The byte helpers the readers and decoders share: a two-pass decode into a caller's buffer, and a byte-for-byte
// compare.

// Decodes a node's bytes into `buf` or `allocator`: `d` is the decoder's initial state and `next` returns one
// byte at a time. The decoder makes two passes, one to count the bytes and one to write them. `owned` is the
// allocation when `buf` was too small, nil otherwise, and the caller frees it with `allocator`.
decode_text :: proc(buf: []u8, allocator: runtime.Allocator, d: $D, $next: proc(^D) -> (u8, bool)) -> (s: string, owned: []u8, ok: bool) {
	count := 0
	c := d
	for {
		_, more := next(&c)
		if !more {
			break
		}
		count += 1
	}
	dst := buf
	if len(dst) < count {
		fresh, err := make([]u8, count, allocator)
		if err != nil {
			return "", nil, false
		}
		dst = fresh
		owned = fresh
	}
	c = d
	w := 0
	for {
		b, more := next(&c)
		if !more {
			break
		}
		dst[w] = b
		w += 1
	}
	return string(dst[:w]), owned, true
}

// Whether byte strings `a` and `b` are equal. A length test comes first, then below 8 bytes a byte at a time, at
// most 16 bytes two overlapping 8-byte loads that stay inside both strings, and past that 8-byte words then the
// tail.
bytes_equal :: #force_inline proc(a, b: []u8) -> bool {
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
