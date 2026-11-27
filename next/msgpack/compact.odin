package msgpack

// Shortest-encoding (`.Compact`) validation rules for MessagePack items and Timestamps.

// Returns true if unsigned integer head `b` (`0xcc..0xcf`) encodes `arg` in its shortest form.
@(private)
compact_uint_ok :: #force_inline proc "contextless" (b: u8, arg: u64) -> bool {
	switch b {
	case 0xcc:
		return arg >= 0x80
	case 0xcd:
		return arg >= 0x100
	case 0xce:
		return arg >= 0x1_0000
	case 0xcf:
		return arg >= 0x1_0000_0000
	}
	return true
}

// Returns true if signed integer head `b` (`0xd0..0xd3`) encodes signed `v` in its canonical shortest form.
// Non-negative values must use positive fixint / uint*; negative values use neg fixint (-32..-1) or narrowest int*.
@(private)
compact_int_ok :: #force_inline proc "contextless" (b: u8, v: i64) -> bool {
	switch b {
	case 0xd0:
		return v < -32
	case 0xd1:
		return v < -128
	case 0xd2:
		return v < -32768
	case 0xd3:
		return v < -2_147_483_648
	}
	return true
}

// Returns true if string head `b` (`0xd9..0xdb`) uses the shortest encoding for byte length `n`.
@(private)
compact_str_ok :: #force_inline proc "contextless" (b: u8, n: u64) -> bool {
	switch b {
	case 0xd9:
		return n >= 32
	case 0xda:
		return n >= 256
	case 0xdb:
		return n >= 65536
	}
	return true
}

// Returns true if binary head `b` (`0xc4..0xc6`) uses the shortest encoding for byte length `n`.
@(private)
compact_bin_ok :: #force_inline proc "contextless" (b: u8, n: u64) -> bool {
	switch b {
	case 0xc5:
		return n >= 256
	case 0xc6:
		return n >= 65536
	}
	return true
}

// Returns true if array/map head `b` (`0xdc..0xdf`) uses the shortest encoding for item/pair count `count`.
@(private)
compact_container_ok :: #force_inline proc "contextless" (b: u8, count: u64) -> bool {
	switch b {
	case 0xdc, 0xde:
		return count >= 16
	case 0xdd, 0xdf:
		return count >= 65536
	}
	return true
}

// Returns true if ext head `b` (`0xc7..0xc9`) uses the shortest encoding for payload length `n`.
@(private)
compact_ext_ok :: #force_inline proc "contextless" (b: u8, n: u64) -> bool {
	if b >= 0xd4 && b <= 0xd8 {
		return true
	}
	if n == 1 || n == 2 || n == 4 || n == 8 || n == 16 {
		return false
	}
	switch b {
	case 0xc8:
		return n >= 256
	case 0xc9:
		return n >= 65536
	}
	return true
}

// Returns true if binary64 `bits` fits without loss in binary32 (including Inf, -0.0, and canonical qNaN bits).
@(private)
double_fits_single :: proc "contextless" (bits: u64) -> bool {
	if bits >> 52 & 0x7ff == 0x7ff {
		return bits & 0xf_ffff_ffff_ffff == 0 || bits & 0x1fff_ffff == 0
	}
	return transmute(u64)f64(f32(transmute(f64)bits)) == bits
}

// Returns true if a Timestamp (`ext -1`) payload uses its canonical shortest 32/64/96-bit encoding.
@(private)
timestamp_preferred :: #force_inline proc "contextless" (payload_len: u64, sec: i64, nsec: u32) -> bool {
	switch payload_len {
	case 4:
		return true
	case 8:
		return !(nsec == 0 && sec >= 0 && sec <= 0xFFFF_FFFF)
	case 12:
		return !(sec >= 0 && sec <= 0x3_FFFF_FFFF)
	}
	return false
}
