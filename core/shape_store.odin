package core

// The judge-and-store halves of the shape walk's scalar leaves. Each takes a value its format's leaf already
// decoded, checks that the target can hold it, and writes it into `dest` at the op's width, the target type's
// size, or only checks it when `dest` is nil. A value the target cannot hold is `.Out_Of_Range`, an enum value
// none of its members has `.Not_A_Member`. The leaves call them per value, so each is forced inline.

import "base:runtime"
import "core:slice"

// A boolean into a `width`-byte boolean.
shape_bool_store :: #force_inline proc(v: bool, dest: rawptr, width: u8) {
	if dest != nil {
		switch width {
		case 1: (^b8)(dest)^ = b8(v)
		case 2: (^b16)(dest)^ = b16(v)
		case 4: (^b32)(dest)^ = b32(v)
		case 8: (^b64)(dest)^ = b64(v)
		}
	}
}

// An integer's magnitude and sign into a `width`-byte integer, or `.Out_Of_Range` when it does not fit.
shape_int_store :: #force_inline proc(mag: u64, neg: bool, dest: rawptr, width: u8, signed: bool) -> Shape_Fault {
	bits := u32(width) * 8
	if signed {
		// The magnitude of the most negative value. The most positive is one less.
		limit := u64(1) << (bits - 1)
		if mag > limit || (!neg && mag == limit) {
			return .Out_Of_Range
		}
	} else if neg {
		if mag != 0 {
			return .Out_Of_Range
		}
	} else if bits < 64 && mag >> bits != 0 {
		return .Out_Of_Range
	}
	if dest != nil {
		// Two's complement: the low `width` bytes of the negated magnitude are the signed value.
		v := 0 - mag if neg else mag
		switch width {
		case 1: (^u8)(dest)^ = u8(v)
		case 2: (^u16)(dest)^ = u16(v)
		case 4: (^u32)(dest)^ = u32(v)
		case 8: (^u64)(dest)^ = v
		}
	}
	return .None
}

// An integer's magnitude and sign into a 128-bit integer. `over`: the magnitude passed 128 bits as it was
// folded.
shape_wide_store :: #force_inline proc(mag: u128, over, neg: bool, dest: rawptr, signed: bool) -> Shape_Fault {
	limit := u128(1) << 127
	if over || (signed && (mag > limit || (!neg && mag == limit))) || (!signed && neg && mag != 0) {
		return .Out_Of_Range
	}
	if dest != nil {
		(^u128)(dest)^ = 0 - mag if neg else mag
	}
	return .None
}

// An enum's backing integer `v`, stored at `op.width` bytes, into the enum op `op`: it must be one of the
// declared values.
shape_enum_store :: #force_inline proc(v: u64, dest: rawptr, op: ^Shape_Op) -> Shape_Fault {
	v := v
	// Declared values are i64: a signed backing integer is sign-extended from its width to compare.
	x := i64(v)
	if op.kind == .Enum_Int {
		shift := 64 - u64(op.width) * 8
		x = i64(v << shift) >> shift
	}
	if !slice.contains(op.enum_info.values, runtime.Type_Info_Enum_Value(x)) {
		return .Not_A_Member
	}
	if dest != nil {
		runtime.mem_copy_non_overlapping(dest, &v, int(op.width))
	}
	return .None
}

// Member `k` of the enum op `op`, the one a name named, into the enum at `dest`.
shape_enum_member_store :: #force_inline proc(op: ^Shape_Op, k: int, dest: rawptr) {
	if dest != nil {
		v := op.enum_info.values[k]
		runtime.mem_copy_non_overlapping(dest, &v, int(op.width))
	}
}

// Sets the tag of the union at `dest` to `tag`. A pure maybe has no tag; a non-nil pointer marks the variant.
shape_union_tag :: proc(dest: rawptr, op: ^Shape_Op, tag: u32) {
	at := rawptr(uintptr(dest) + uintptr(op.tag_offset))
	switch op.tag_size {
	case 1: (^u8)(at)^ = u8(tag)
	case 2: (^u16)(at)^ = u16(tag)
	case 4: (^u32)(at)^ = tag
	case 8: (^u64)(at)^ = u64(tag)
	}
}

// A binary64 value, made safe to narrow with one more rounding, into an f32. A finite value that rounds to
// infinity is out of range.
shape_f32_store :: #force_inline proc(x: f64, dest: rawptr) -> Shape_Fault {
	v := f32(x)
	if abs(v) > max(f32) {
		return .Out_Of_Range
	}
	if dest != nil {
		(^f32)(dest)^ = v
	}
	return .None
}

// A binary64 value, made safe to narrow with one more rounding, into an f16, rounded by `f64_to_f16`. A
// finite value that rounds to infinity is out of range.
shape_f16_store :: #force_inline proc(x: f64, dest: rawptr) -> Shape_Fault {
	v := f64_to_f16(x)
	if abs(v) > max(f16) {
		return .Out_Of_Range
	}
	if dest != nil {
		(^f16)(dest)^ = v
	}
	return .None
}

// `x` rounded once to the nearest f16, ties to even. A value that rounds past the widest finite f16 is
// infinity. Not the cast `f16(x)`: on x86-64 that is the runtime's software conversion, which rounds through
// f32 and then ties up, so a value at or near an f16 halfway point comes out one unit high. `x` is finite.
f64_to_f16 :: proc(x: f64) -> f16 {
	bits := transmute(u64)x
	sign := u16(bits >> 48) & 0x8000
	e := i64((bits >> 52) & 0x7ff) - 1023
	if e >= 16 {
		return transmute(f16)(sign | 0x7c00)
	}
	// Below 2^-25, half the least subnormal, everything rounds to zero.
	if e < -25 {
		return transmute(f16)sign
	}
	m := (bits & (1 << 52 - 1)) | 1 << 52
	// The significand bits below the f16's last one: 42 for a normal, more below 2^-14.
	drop := u64(42 + max(0, -14 - e))
	q := m >> drop
	rest := m & (1 << drop - 1)
	half := u64(1) << (drop - 1)
	if rest > half || (rest == half && q & 1 == 1) {
		q += 1
	}
	// `q` carries its leading bit into the exponent field, so a carry out of the significand bumps the
	// exponent, and one out of the widest finite f16 makes infinity.
	return transmute(f16)(sign | (u16(max(e, -14) + 14) << 10 + u16(q)))
}
