// What every probe shares. The sampling rule: WARMUP untimed calls, then TIMED timed ones, and the mean of the two
// middle samples as the median. The check is FNV-1a over what a probe read or wrote, so that the arms of a lane can be
// compared. The C++, C and Rust probes follow the same rule and hash (timing.h, rust/src/lib.rs).
package timing

import "core:slice"

WARMUP :: 2
TIMED :: 10

CHECK_OFFSET :: u64(14695981039346656037)
CHECK_PRIME :: u64(1099511628211)

// Sorts `samples`, fastest first, and returns the median.
median :: proc(samples: ^[TIMED]i64) -> i64 {
	slice.sort(samples[:])
	return (samples[(TIMED - 1) / 2] + samples[TIMED / 2]) / 2
}

fnv :: #force_inline proc(h: u64, b: u8) -> u64 {
	return (h ~ u64(b)) * CHECK_PRIME
}

fnv_bytes :: proc(h0: u64, bytes: []u8) -> u64 {
	h := h0
	for b in bytes {
		h = fnv(h, b)
	}
	return h
}

fnv_u64 :: proc(h0: u64, v: u64) -> u64 {
	h := h0
	for i in 0 ..< 8 {
		h = fnv(h, u8(v >> uint(8 * i)))
	}
	return h
}
