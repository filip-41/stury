package cbor

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The rules of preferred serialization and deterministic encoding, RFC 8949 sections 4.1 and 4.2: the shortest head,
// the shortest float, and the order of the keys of a map.

// The least argument each additional information can carry in preferred serialization.
@(private, rodata)
SHORTEST_FROM := [32]u64{24 = 24, 25 = 0x100, 26 = 0x1_0000, 27 = 0x1_0000_0000}

// Whether `arg` is the shortest argument additional information `ai` can carry.
@(private)
shortest :: #force_inline proc "contextless" (ai: u8, arg: u64) -> bool {
	return arg >= SHORTEST_FROM[ai & 31]
}

// The fault of preferred serialization, if any, for the float `payload` of 2, 4 or 8 bytes in spec `S`: a NaN other
// than `f97e00` when keys are sorted, and a float a narrower one holds exactly.
@(private)
float_fault :: proc "contextless" (payload: []u8, S: Spec) -> Detail {
	bits: u64
	switch len(payload) {
	case 2:
		bits = u64(payload[0]) << 8 | u64(payload[1])
	case 4:
		bits = u64(intrinsics.byte_swap(intrinsics.unaligned_load((^u32)(raw_data(payload)))))
	case:
		bits = intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(raw_data(payload))))
	}
	switch len(payload) {
	case 2:
		if S >= .Deterministic && bits & 0x7c00 == 0x7c00 && bits & 0x3ff != 0 && bits != 0x7e00 {
			return .Bad_Nan
		}
	case 4:
		if S >= .Deterministic && bits & 0x7f80_0000 == 0x7f80_0000 && bits & 0x7f_ffff != 0 {
			return .Bad_Nan
		}
		if single_fits_half(u32(bits)) {
			return .Not_Preferred
		}
	case:
		if S >= .Deterministic && bits & 0x7ff0_0000_0000_0000 == 0x7ff0_0000_0000_0000 && bits & 0xf_ffff_ffff_ffff != 0 {
			return .Bad_Nan
		}
		if double_fits_single(bits) {
			return .Not_Preferred
		}
	}
	return .None
}

// A NaN or infinity fits when the bits its narrower float lacks are zero, which is the rule of RFC 8949 section 4.1 for
// NaN payloads.
@(private)
single_fits_half :: proc "contextless" (bits: u32) -> bool {
	if bits >> 23 & 0xff == 0xff {
		return bits & 0x7f_ffff == 0 || bits & 0x1fff == 0
	}
	return transmute(u32)f32(f16(transmute(f32)bits)) == bits
}

@(private)
double_fits_single :: proc "contextless" (bits: u64) -> bool {
	if bits >> 52 & 0x7ff == 0x7ff {
		return bits & 0xf_ffff_ffff_ffff == 0 || bits & 0x1fff_ffff == 0
	}
	return transmute(u64)f64(f32(transmute(f64)bits)) == bits
}

// Whether the key at `src[start:i]` may follow `prev`, the last key of its map, which it then becomes.
@(private)
keys_ordered :: #force_inline proc "contextless" (src: []u8, prev: ^[2]u64, start, i: u64, S: Spec) -> bool {
	if prev[1] != 0 && !key_before(src, prev^, {start, i}, S) {
		return false
	}
	prev^ = {start, i}
	return true
}

// The fault of the key at `src[start:i]` that does not follow the key `prev` spans: an earlier key, or under `refuse`
// a repeat of it, which is a repeated key as `Duplicate_Key` says.
@(private, cold)
key_fault :: proc "contextless" (src: []u8, prev: [2]u64, start, i: u64, refuse: bool) -> hook.Walk_Result {
	if refuse && string(src[prev[0]:prev[1]]) == string(src[start:i]) {
		return hook.walk_result(start, u8(tape.Fault_Kind.Duplicate_Key))
	}
	return fault(start, .Bad_Char, .Key_Order)
}

// Whether the encoded key `before` sorts before the encoded key `key` in a map of spec `S`. Keys of at most 8 bytes are
// compared as big-endian words, which needs 8 bytes of `src` at each.
@(private)
key_before :: #force_inline proc "contextless" (src: []u8, before, key: [2]u64, S: Spec) -> bool #no_bounds_check {
	la, lb := before[1] - before[0], key[1] - key[0]
	if S == .Length_First && la != lb {
		return la < lb
	}
	m := min(la, lb)
	if m <= 8 && before[0] + 8 <= u64(len(src)) && key[0] + 8 <= u64(len(src)) {
		x := intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(raw_data(src)[before[0]:])))
		y := intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(raw_data(src)[key[0]:])))
		drop := (8 - m) * 8
		x, y = x >> drop, y >> drop
		return x < y || x == y && la < lb
	}
	return key_before_bytes(src, before, key)
}

@(private)
key_before_bytes :: #force_no_inline proc "contextless" (src: []u8, before, key: [2]u64) -> bool #no_bounds_check {
	la, lb := before[1] - before[0], key[1] - key[0]
	c := runtime.memory_compare(raw_data(src)[before[0]:], raw_data(src)[key[0]:], int(min(la, lb)))
	return c < 0 || c == 0 && la < lb
}
