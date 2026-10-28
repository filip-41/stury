package core

import "base:runtime"
import "core:unicode/utf8"

// The shape walk's leaves that every format shares: a number written as JSON's decimal text into an integer,
// enum or float target, and a decoded string into a string, cstring, rune, enum name or map key. A format's
// walk calls them with text it has already checked, `src[lo:hi]`, or decoded. Each writes `dest` at the op's
// width, or only checks the value when `dest` is nil. A value of the wrong kind is `.Wrong_Kind`; one of the
// right kind the target cannot hold is `.Out_Of_Range`.

number_starts_with :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == '-' || (b >= '0' && b <= '9')
}

// A number written as an integer into a `width`-byte integer. A fraction or an exponent is the wrong kind, not a
// value to truncate. `-0` is 0 for every target.
shape_leaf_int :: proc(src: []byte, lo, hi: u64, dest: rawptr, width: u8, signed: bool) -> Shape_Fault #no_bounds_check {
	b := src[lo]
	if !number_starts_with(b) {
		return .Wrong_Kind
	}
	neg := b == '-'
	// The token is checked, so its digits reach `hi` exactly when it has no fraction and no exponent.
	mag, over, digits := fold_int(src, lo + u64(neg), hi)
	if !digits {
		return .Wrong_Kind
	}
	if over || mag > u128(max(u64)) {
		return .Out_Of_Range
	}
	return shape_int_store(u64(mag), neg, dest, width, signed)
}

// A number written as an integer into a 128-bit integer, checked as `shape_leaf_int` checks one into 64 bits.
shape_leaf_wide :: proc(src: []byte, lo, hi: u64, dest: rawptr, signed: bool) -> Shape_Fault {
	b := src[lo]
	if !number_starts_with(b) {
		return .Wrong_Kind
	}
	neg := b == '-'
	mag, over, digits := fold_int(src, lo + u64(neg), hi)
	if !digits {
		return .Wrong_Kind
	}
	return shape_wide_store(mag, over, neg, dest, signed)
}

// A number written as an integer into an enum: its backing integer, which must be one of the declared values.
shape_leaf_enum :: proc(src: []byte, lo, hi: u64, dest: rawptr, op: ^Shape_Op) -> Shape_Fault {
	v: u64
	if fault := shape_leaf_int(src, lo, hi, &v, op.width, op.kind == .Enum_Int); fault != .None {
		return fault
	}
	return shape_enum_store(v, dest, op)
}

// The checked number `src[lo:hi]`, lexed as `lexed`, into a `width`-byte float, correctly rounded. A finite value
// that rounds to infinity in the target width, or has no binary64 value at all (`1e400`), is out of range. An
// underflow rounds to zero.
shape_leaf_float_lexed :: #force_inline proc(src: []byte, lo, hi: u64, lexed: Number_Lex, dest: rawptr, width: u8) -> Shape_Fault #no_bounds_check {
	if width == 8 {
		v, ok := f64_number_value(src, lo, hi, lexed)
		if !ok {
			return .Out_Of_Range
		}
		if dest != nil {
			(^f64)(dest)^ = v
		}
		return .None
	}
	n := dom_number_value(src, lo, hi, lexed)
	if n.exactness == .None {
		return .Out_Of_Range
	}
	switch width {
	case 4:
		return shape_f32_store(shape_off_halfway(src[lo:hi], n, 24, -126), dest)
	case 2:
		return shape_f16_store(shape_off_halfway(src[lo:hi], n, 11, -14), dest)
	}
	return .None
}

// The decoded text of a map key into an integer, wide integer or enum key, written in JSON's integer grammar.
shape_leaf_key_int :: proc(text: []byte, kop: ^Shape_Op, dest: rawptr) -> Shape_Fault {
	digits := text[1:] if len(text) > 0 && text[0] == '-' else text
	if len(digits) == 0 || (digits[0] == '0' && len(digits) > 1) {
		return .Wrong_Kind
	}
	n := u64(len(text))
	#partial switch kop.kind {
	case .Enum_Int, .Enum_Uint:
		return shape_leaf_enum(text, 0, n, dest, kop)
	case .Wide_Int, .Wide_Uint:
		return shape_leaf_wide(text, 0, n, dest, kop.kind == .Wide_Int)
	}
	return shape_leaf_int(text, 0, n, dest, kop.width, kop.kind == .Int)
}

// The decoded string `s` into the string, cstring, rune or enum-name op `op`, or, for a map key, an integer one
// (`shape_leaf_key_int`). A string is borrowed when `borrow` (`s` outlives the read), else copied into the run's
// allocator. A cstring is always copied with a NUL after it, so a NUL inside is out of range.
shape_leaf_text :: proc(r: ^Shape_Run, s: string, op: ^Shape_Op, dest: rawptr, borrow: bool) -> Shape_Fault {
	#partial switch op.kind {
	case .String:
		if dest == nil {
			return .None
		}
		if borrow || len(s) == 0 {
			(^string)(dest)^ = s
			return .None
		}
		buf, err := shape_alloc(len(s), 1, r.allocator)
		if err != nil || buf == nil {
			return .Out_Of_Memory
		}
		copy(buf, s)
		(^string)(dest)^ = string(buf)
		return .None
	case .Cstring:
		for i in 0 ..< len(s) {
			if s[i] == 0 {
				return .Out_Of_Range
			}
		}
		if dest == nil {
			return .None
		}
		buf, err := shape_alloc(len(s) + 1, 1, r.allocator)
		if err != nil || buf == nil {
			return .Out_Of_Memory
		}
		copy(buf, s)
		buf[len(s)] = 0
		(^cstring)(dest)^ = cstring(raw_data(buf))
		return .None
	case .Rune:
		ch, w := utf8.decode_rune(s)
		if w == 0 || w != len(s) {
			return .Out_Of_Range
		}
		if dest != nil {
			(^rune)(dest)^ = ch
		}
		return .None
	case .Enum_Int, .Enum_Uint:
		if r.enum_ints {
			return shape_leaf_key_int(transmute([]byte)s, op, dest)
		}
		for name, i in op.enum_info.names {
			if name == s {
				shape_enum_member_store(op, i, dest)
				return .None
			}
		}
		return .Not_A_Member
	}
	return shape_leaf_key_int(transmute([]byte)s, op, dest)
}

// `null` into a pointer or union op `op`: nil, or a union's `Null` arm. Refused by a `#no_nil` union with no
// such arm. A `.Last` repeat may have filled the target before.
shape_leaf_null :: proc(r: ^Shape_Run, op: ^Shape_Op, dest: rawptr) -> Shape_Fault {
	if op.kind == .Union && op.arm_of[0] != 0 {
		if op.arm_of[0] == UNION_NO_NIL {
			return .Wrong_Kind
		}
		if dest != nil {
			shape_union_tag(dest, op, r.fields[op.elem + u32(op.arm_of[0]) - 1].offset)
		}
		return .None
	}
	if dest != nil {
		runtime.mem_zero(dest, int(op.size))
	}
	return .None
}
