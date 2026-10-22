package scan

import c "../../core"
import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:reflect"
import "core:slice"
import lex "lex"
import "core:strconv/decimal"
import number "./number"
import "core:unicode/utf8"

// The shape walk's leaf decoders. Each takes a token the walk has already checked, `src[lo:hi]`, and writes
// it into `dest` as the target type holds it, or only checks it when `dest` is nil. A value of the wrong
// JSON kind is `.Wrong_Kind`. One of the right kind the target cannot hold is `.Out_Of_Range`.
//
// The `#no_bounds_check` leaves read `src[lo]` and slice `src[lo + 1:hi - 1]` unchecked: the token is one
// the walk checked, so `lo < hi <= len(src)` and a string holds both quotes. `dest` is written at the op's
// width, the type's size. A decode fits a buffer as long as the escaped text, since no escape decodes
// longer (json/scan/unescape.odin). `fold_digits`'s `$T` is u64, or u128 for the wide integers. The
// differential tests against a reference decoder check it, and the unmarshal tests pin the range edges.

// `true` or `false` into a `width`-byte boolean.
shape_leaf_bool :: proc(src: []byte, lo: u64, dest: rawptr, width: u8) -> c.Shape_Fault #no_bounds_check {
	v: bool
	switch src[lo] {
	case 't':
		v = true
	case 'f':
		v = false
	case:
		return .Wrong_Kind
	}
	if dest != nil {
		switch width {
		case 1: (^b8)(dest)^ = b8(v)
		case 2: (^b16)(dest)^ = b16(v)
		case 4: (^b32)(dest)^ = b32(v)
		case 8: (^b64)(dest)^ = b64(v)
		}
	}
	return .None
}

// Whether `b` can open a JSON number.
@(private = "file")
number_starts_with :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == '-' || (b >= '0' && b <= '9')
}

// A number written as an integer into a `width`-byte integer. A fraction or an exponent is the wrong kind, not a
// value to truncate. `-0` is 0 for every target.
shape_leaf_int :: proc(src: []byte, lo, hi: u64, dest: rawptr, width: u8, signed: bool) -> c.Shape_Fault #no_bounds_check {
	b := src[lo]
	if !number_starts_with(b) {
		return .Wrong_Kind
	}
	neg := b == '-'
	p := lo + u64(neg)
	mag: u64
	over := false
	if hi - p <= 19 {
		// Nineteen digits always fit a u64. The token is checked, so its digit run reaches `hi` exactly when it
		// has no fraction and no exponent.
		if number.digit_run(src, p, &mag, true) != hi {
			return .Wrong_Kind
		}
	} else {
		digits: bool
		if mag, over, digits = fold_digits(src, p, hi, u64); !digits {
			return .Wrong_Kind
		}
	}
	if over {
		return .Out_Of_Range
	}
	return shape_int_store(mag, neg, dest, width, signed)
}

// The checked number token `src[lo:hi]` into a `width`-byte integer, as `shape_leaf_int` reads it, from the
// digits the walk folded (`r.num`) where they fit a u64.
shape_leaf_number_int :: #force_inline proc(r: ^c.Shape_Run, lo, hi: u64, dest: rawptr, width: u8, signed: bool) -> c.Shape_Fault #no_bounds_check {
	neg := r.src[lo] == '-'
	if lo + u64(neg) + r.num.int_digits != hi {
		// A fraction or an exponent.
		return .Wrong_Kind
	}
	if r.num.int_digits > 19 {
		return shape_leaf_int(r.src, lo, hi, dest, width, signed)
	}
	return shape_int_store(r.num.mant, neg, dest, width, signed)
}

// An integer's magnitude and sign into a `width`-byte integer, or `.Out_Of_Range` when it does not fit.
shape_int_store :: #force_inline proc(mag: u64, neg: bool, dest: rawptr, width: u8, signed: bool) -> c.Shape_Fault {
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

// A number written as an integer into a 128-bit integer, checked as `shape_leaf_int` checks one into 64 bits.
shape_leaf_wide :: proc(src: []byte, lo, hi: u64, dest: rawptr, signed: bool) -> c.Shape_Fault {
	b := src[lo]
	if !number_starts_with(b) {
		return .Wrong_Kind
	}
	neg := b == '-'
	mag, over, digits := fold_digits(src, lo + u64(neg), hi, u128)
	if !digits {
		return .Wrong_Kind
	}
	limit := u128(1) << 127
	if over || (signed && (mag > limit || (!neg && mag == limit))) || (!signed && neg && mag != 0) {
		return .Out_Of_Range
	}
	if dest != nil {
		(^u128)(dest)^ = 0 - mag if neg else mag
	}
	return .None
}

// The decimal digits of `src[p:hi]` folded into a `T`, `over` once the value passed it. The run is read to
// `hi` past an overflow, so a fraction or exponent after one is still the wrong kind: `digits = false` at the
// first non-digit. Sign and range are the caller's.
@(private)
fold_digits :: #force_inline proc(src: []byte, p, hi: u64, $T: typeid) -> (mag: T, over, digits: bool) {
	for i in p ..< hi {
		d := src[i] - '0'
		if d > 9 {
			return mag, over, false
		}
		m, o1 := intrinsics.overflow_mul(mag, 10)
		a, o2 := intrinsics.overflow_add(m, T(d))
		over ||= o1 || o2
		mag = a
	}
	return mag, over, true
}

// A number written as an integer into an enum: its backing integer, which must be one of the declared values.
shape_leaf_enum :: proc(src: []byte, lo, hi: u64, dest: rawptr, op: ^c.Shape_Op) -> c.Shape_Fault {
	v: u64
	if fault := shape_leaf_int(src, lo, hi, &v, op.width, op.kind == .Enum_Int); fault != .None {
		return fault
	}
	// Declared values are i64: a signed backing integer is sign-extended from its width to compare.
	x := i64(v)
	if op.kind == .Enum_Int {
		shift := 64 - u64(op.width) * 8
		x = i64(v << shift) >> shift
	}
	// A linear scan of the members.
	if !slice.contains(op.enum_info.values, runtime.Type_Info_Enum_Value(x)) {
		return .Not_A_Member
	}
	if dest != nil {
		runtime.mem_copy_non_overlapping(dest, &v, int(op.width))
	}
	return .None
}

// A string token `src[lo:hi]`, quotes included, into an enum: the value of the member it names, compared by
// decoded text.
shape_leaf_enum_name :: proc(src: []byte, lo, hi: u64, dest: rawptr, op: ^c.Shape_Op) -> c.Shape_Fault {
	if src[lo] != '"' {
		return .Wrong_Kind
	}
	e := op.enum_info
	// A linear scan of the names.
	for name, i in e.names {
		if name_equals(src, lo, hi, name) {
			if dest != nil {
				v := e.values[i]
				runtime.mem_copy_non_overlapping(dest, &v, int(op.width))
			}
			return .None
		}
	}
	return .Not_A_Member
}

// The checked number token `src[lo:hi]` into a `width`-byte float, correctly rounded. A finite value that
// rounds to infinity in the target width, or has no binary64 value at all (`1e400`), is out of range. An
// underflow rounds to zero.
shape_leaf_float :: proc(r: ^c.Shape_Run, lo, hi: u64, dest: rawptr, width: u8) -> c.Shape_Fault #no_bounds_check {
	src := r.src
	b := src[lo]
	if !number_starts_with(b) {
		return .Wrong_Kind
	}
	if width == 8 {
		v, ok := number.f64_number_value(src, lo, hi, shape_number_lexed(r, lo, hi, false))
		if !ok {
			return .Out_Of_Range
		}
		if dest != nil {
			(^f64)(dest)^ = v
		}
		return .None
	}
	n := shape_number_judged(r, lo, hi)
	if n.exactness == .None {
		return .Out_Of_Range
	}
	switch width {
	case 4:
		v := f32(shape_off_halfway(src[lo:hi], n, 24, -126))
		if abs(v) > max(f32) {
			return .Out_Of_Range
		}
		if dest != nil {
			(^f32)(dest)^ = v
		}
	case 2:
		v := f64_to_f16(shape_off_halfway(src[lo:hi], n, 11, -14))
		if abs(v) > max(f16) {
			return .Out_Of_Range
		}
		if dest != nil {
			(^f16)(dest)^ = v
		}
	}
	return .None
}

// The binary64 value of the checked number token `src[lo:hi]`, by the `.Dom` row's decoder over the digits the
// walk folded as it checked the token (`r.num`). Its exactness may under-claim where `number_span` proves
// `.Exact`, but the value is the same correctly rounded one.
shape_number_judged :: #force_inline proc(r: ^c.Shape_Run, lo, hi: u64) -> c.Number #no_bounds_check {
	v, flags := number.dom_number_value(r.src, lo, hi, shape_number_lexed(r, lo, hi, false))
	return {v, number.dom_flag_state(flags)}
}

// The checked number token `src[lo:hi]` as `lex_number_value` lexes it, from the digits the walk folded
// (`r.num`). Its `spelling` is the sign's alone unless `$spelled`.
shape_number_lexed :: #force_inline proc(r: ^c.Shape_Run, lo, hi: u64, $spelled: bool) -> number.Number_Lex #no_bounds_check {
	n := &r.num
	neg := r.src[lo] == '-'
	int_at := lo + u64(neg)
	frac_at := int_at + n.int_digits + u64(n.frac_digits > 0)
	lexed := number.Number_Lex{
		int_at      = int_at,
		int_digits  = n.int_digits,
		frac_at     = frac_at,
		frac_digits = n.frac_digits,
		exp         = n.exp,
		mant        = n.mant,
		spelling    = {.Negative} if neg else {},
		ok          = true,
		whole       = true,
	}
	when spelled {
		if n.frac_digits > 0 {
			lexed.spelling += {.Has_Fraction}
		}
		if frac_at + n.frac_digits < hi {
			lexed.spelling += {.Has_Exponent}
		}
	}
	return lexed
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

// The binary64 value `n` of the number token `t`, made safe to narrow to a float of `sig` significant bits and
// least normal exponent `min_exp` with one more rounding. Narrowing rounds twice, and only a binary64 value
// exactly halfway between two such floats can come out wrong: the decimal may lie off the halfway point on
// either side. Such a value is replaced by the neighbour the decimal rounds to, checked on its digits. A
// decimal on the point itself is replaced by the even neighbour: the runtime narrowing cast does not tie to
// even on x86.
shape_off_halfway :: #force_inline proc(t: []byte, n: c.Number, sig: u64, min_exp: i64) -> f64 {
	bits := transmute(u64)n.value & (1 << 63 - 1)
	e := i64(bits >> 52) - 1023
	// The binary64 significand bits below the target's last one, and more below its normal range.
	drop := 53 - sig + u64(max(0, min_exp - e))
	if drop > 53 {
		return n.value
	}
	m := (bits & (1 << 52 - 1)) | 1 << 52
	// Low `drop` bits exactly the halfway bit: `n` is a target midpoint.
	if m & (1 << drop - 1) != 1 << (drop - 1) {
		return n.value
	}
	// An exact decimal is this midpoint, so the tie is to even. No cast sees the midpoint.
	if n.exactness == .Exact {
		return shape_tie_even(n.value, e, drop)
	}
	return shape_halfway_resolve(t, n.value, e, drop)
}

// `x`, exactly halfway between two floats `2 * half` apart, moved to the one the decimal `t` rounds to. A
// decimal on the halfway point itself goes to the even neighbour. The upper neighbour of the widest finite
// float is infinity's place, 2^128 or 2^16, which narrowing then refuses as out of range.
shape_halfway_resolve :: proc(t: []byte, x: f64, e: i64, drop: u64) -> f64 {
	ax := abs(x)
	half := transmute(f64)(u64(e + i64(drop) - 53 + 1023) << 52)
	// The exact decimal of `x`: its 53-bit significand, scaled by its binary exponent.
	d: decimal.Decimal
	decimal.assign(&d, (transmute(u64)ax & (1 << 52 - 1)) | 1 << 52)
	decimal.shift(&d, int(e - 52))
	switch shape_decimal_cmp(t, d.digits[:d.count], i64(d.decimal_point)) {
	case 1:
		ax += half
	case -1:
		ax -= half
	case:
		return shape_tie_even(x, e, drop)
	}
	return -ax if x < 0 else ax
}

// The even neighbour of midpoint `x`, an exact target float. Bit `drop` of the 53-bit significand is the
// target's least bit. Clear means the lower neighbour is even.
shape_tie_even :: proc(x: f64, e: i64, drop: u64) -> f64 {
	ax := abs(x)
	half := transmute(f64)(u64(e + i64(drop) - 53 + 1023) << 52)
	m := (transmute(u64)ax & (1 << 52 - 1)) | 1 << 52
	if m & (1 << drop) == 0 {
		ax -= half
	} else {
		ax += half
	}
	return -ax if x < 0 else ax
}

// The sign of |`t`| - 0.`digits` * 10^`point`, for a number token `t` and decimal digits with no leading
// zero. Exact at any length: the token's digits are compared once its decimal point is placed.
shape_decimal_cmp :: proc(t: []byte, digits: []byte, point: i64) -> int {
	i := int(t[0] == '-')
	// The token is 0.d1d2... * 10^at, d1 its first nonzero digit.
	at: i64
	// The sign of the first digit that differs from `digits`, padded with zeros.
	cmp := 0
	k := 0
	frac := false
	for ; i < len(t) && t[i] != 'e' && t[i] != 'E'; i += 1 {
		d := t[i]
		if d == '.' {
			frac = true
			continue
		}
		if !frac {
			at += 1
		}
		if k == 0 && d == '0' {
			at -= 1
			continue
		}
		if cmp == 0 {
			cmp = int(d) - int(digits[k] if k < len(digits) else '0')
		}
		k += 1
	}
	if i < len(t) {
		i += 1
		neg := t[i] == '-'
		if t[i] == '-' || t[i] == '+' {
			i += 1
		}
		// Saturated: past the bound, only gigabytes of digits could bring the token back onto `digits`.
		e: i64
		for ; i < len(t); i += 1 {
			e = min(e * 10 + i64(t[i] - '0'), 1 << 32)
		}
		at += -e if neg else e
	}
	for j := k; cmp == 0 && j < len(digits); j += 1 {
		if digits[j] != '0' {
			cmp = -1
		}
	}
	if at != point {
		return 1 if at > point else -1
	}
	return 1 if cmp > 0 else (-1 if cmp < 0 else 0)
}

// A string token into a `string`. An escape-free one is borrowed from `src` when the run allows it and
// copied otherwise. An escaped one is decoded into the run's allocator. `first_esc` is as in
// `dom_unescape_copy`.
shape_leaf_string :: proc(r: ^c.Shape_Run, src: []byte, lo, hi: u64, dest: rawptr, escaped: bool, first_esc: u64) -> c.Shape_Fault #no_bounds_check {
	if src[lo] != '"' {
		return .Wrong_Kind
	}
	if dest == nil {
		return .None
	}
	inner := src[lo + 1:hi - 1]
	if !escaped && r.borrow {
		(^string)(dest)^ = string(inner)
		return .None
	}
	if len(inner) == 0 {
		(^string)(dest)^ = ""
		return .None
	}
	buf, err := shape_alloc(len(inner), 1, r.allocator)
	if err != nil || buf == nil {
		return .Out_Of_Memory
	}
	n := len(inner)
	if escaped {
		n = dom_unescape_into(buf, src, lo, hi, first_esc)
	} else {
		copy(buf, inner)
	}
	(^string)(dest)^ = string(buf[:n])
	return .None
}

// A member key `src[lo:hi]` into a map's key type: a string as the string or cstring leaf reads one, or an
// integer written inside the quotes in JSON's integer grammar. An escaped key is decoded first.
shape_leaf_map_key :: proc(r: ^c.Shape_Run, escaped: bool, lo, hi: u64, kop: ^c.Shape_Op, dest: rawptr) -> c.Shape_Fault {
	// A key's escape offset is not latched, so the decode finds it.
	#partial switch kop.kind {
	case .String:
		return shape_leaf_string(r, r.src, lo, hi, dest, escaped, 0)
	case .Cstring:
		return shape_leaf_cstring(r, r.src, lo, hi, dest, escaped, 0)
	case .Enum_Int, .Enum_Uint:
		if !r.enum_ints {
			return shape_leaf_enum_name(r.src, lo, hi, dest, kop)
		}
	}
	text := r.src[lo + 1:hi - 1]
	// An in-range integer takes at most 40 bytes (a 128-bit one), each at most a 6-byte `\uXXXX`. A longer
	// escaped key is decoded on the heap and faults below.
	buf: [256]u8 = ---
	heap: []byte
	defer if heap != nil {
		runtime.mem_free(raw_data(heap), r.allocator)
	}
	if escaped {
		dst := buf[:]
		if len(text) > len(buf) {
			err: runtime.Allocator_Error
			heap, err = shape_alloc(len(text), 1, r.allocator)
			if err != nil || heap == nil {
				return .Out_Of_Memory
			}
			dst = heap
		}
		text = dst[:dom_unescape_into(dst, r.src, lo, hi)]
	}
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

// A string token into a `cstring`, always copied with a NUL after it, so a `\u0000` inside is out of range.
// `null` is nil.
shape_leaf_cstring :: proc(r: ^c.Shape_Run, src: []byte, lo, hi: u64, dest: rawptr, escaped: bool, first_esc: u64) -> c.Shape_Fault {
	if src[lo] == 'n' {
		if dest != nil {
			(^cstring)(dest)^ = nil
		}
		return .None
	}
	if src[lo] != '"' {
		return .Wrong_Kind
	}
	if escaped {
		// The walk checked every escape: a `\uXXXX` is six bytes, any other two.
		for p := lo + 1; p < hi - 1; p += 1 {
			if src[p] != '\\' {
				continue
			}
			if src[p + 1] == 'u' {
				if string(src[p + 2:p + 6]) == "0000" {
					return .Out_Of_Range
				}
				p += 4
			}
			p += 1
		}
	}
	if dest == nil {
		return .None
	}
	n := int(hi - lo - 2)
	buf, err := shape_alloc(n + 1, 1, r.allocator)
	if err != nil || buf == nil {
		return .Out_Of_Memory
	}
	if escaped {
		n = dom_unescape_into(buf, src, lo, hi, first_esc)
	} else {
		copy(buf, src[lo + 1:hi - 1])
	}
	buf[n] = 0
	(^cstring)(dest)^ = cstring(raw_data(buf))
	return .None
}

// A string token holding exactly one code point into a `rune`.
shape_leaf_rune :: proc(src: []byte, lo, hi: u64, dest: rawptr, escaped: bool) -> c.Shape_Fault {
	if src[lo] != '"' {
		return .Wrong_Kind
	}
	text := src[lo + 1:hi - 1]
	// One code point takes at most twelve bytes: a surrogate pair, both halves escaped.
	if len(text) > 12 {
		return .Out_Of_Range
	}
	buf: [16]u8 = ---
	if escaped {
		text = buf[:dom_unescape_into(buf[:], src, lo, hi)]
	}
	ch, w := utf8.decode_rune(text)
	if w == 0 || w != len(text) {
		return .Out_Of_Range
	}
	if dest != nil {
		(^rune)(dest)^ = ch
	}
	return .None
}

// The value `src[lo:hi]`, verbatim, into a `Raw` or `Digits`: borrowed from `src` when the run allows it, else copied.
shape_leaf_raw :: proc(r: ^c.Shape_Run, lo, hi: u64, dest: rawptr) -> c.Shape_Fault {
	if dest == nil {
		return .None
	}
	text := r.src[lo:hi]
	if !r.borrow {
		buf, err := shape_alloc(len(text), 1, r.allocator)
		if err != nil || buf == nil {
			return .Out_Of_Memory
		}
		copy(buf, text)
		text = buf
	}
	(^string)(dest)^ = string(text)
	return .None
}

// The value `src[lo:hi]`, checked, handed to the caller's hook for the type at `dest`. Checked only, it is not.
// Forced inline: unwrapping the hook's `Maybe` tipped LLVM into an outlined call per hooked value.
shape_leaf_hook :: #force_inline proc(r: ^c.Shape_Run, lo, hi: u64, dest: rawptr, op: ^c.Shape_Op) -> c.Shape_Fault {
	if dest == nil {
		return .None
	}
	return r.shape.hooks[op.elem](r.src[lo:hi], dest, r.allocator).? or_else .None
}

// Any scalar into a `Decoded`, in the arm `decode_span` gives it. A string is borrowed or copied as the string
// leaf does. A number with no binary64 value is the `Digits` arm, not a refusal. `judged`: a number is one the
// walk just checked, so `r.num` holds its digits.
shape_leaf_decoded :: proc(r: ^c.Shape_Run, src: []byte, lo, hi: u64, dest: rawptr, escaped: bool, first_esc: u64, judged: bool) -> c.Shape_Fault {
	kind := c.kind_at(src, lo)
	if kind == .String {
		// Not through `decode_span`, so a checked-only string decodes nothing.
		str: string
		fault := shape_leaf_string(r, src, lo, hi, rawptr(&str) if dest != nil else nil, escaped, first_esc)
		if fault == .None && dest != nil {
			(^Decoded)(dest)^ = str
		}
		return fault
	}
	d: Decoded
	ok: bool
	if judged && kind == .Number {
		d, ok = decode_number_lexed(src, lo, hi, shape_number_lexed(r, lo, hi, true))
	} else {
		d, _, ok = decode_span(src, lo, hi, kind)
	}
	if !ok {
		return .Out_Of_Range
	}
	if dest != nil {
		(^Decoded)(dest)^ = d
	}
	return .None
}

// The container `src[lo:hi]` read whole, into the `Raw`, bit_set or hooked value at `r.cur_dest`, or into the
// tree boxed for the `any` there. The bit_set and `any` readers re-read the span the walk checked, and read
// no byte past `hi`: a span that ends early is `.Wrong_Kind`.
shape_leaf_container :: proc(r: ^c.Shape_Run, lo, hi: u64) -> c.Shape_Fault {
	dest := r.cur_dest
	op := &r.ops[r.cur_op]
	if op.kind == .Bit_Set {
		return shape_leaf_bit_set(r, r.src[:hi], int(lo), dest, op)
	}
	if op.kind == .Hook {
		return shape_leaf_hook(r, lo, hi, dest, op)
	}
	if op.kind == .Any && dest != nil {
		// `shape_any_tree` allocates through the context. The request's allocator is the caller's again after.
		prev := context.allocator
		context.allocator = r.allocator
		tree, _, fault := shape_any_tree(r, r.src[:hi], int(lo))
		context.allocator = prev
		(^any)(dest)^ = tree
		return fault
	}
	return shape_leaf_raw(r, lo, hi, dest)
}

// Any scalar into the `any` at `dest`: `null` as nil, any other as its `Decoded` arm, boxed in `r.allocator`.
shape_leaf_any :: proc(r: ^c.Shape_Run, src: []byte, lo, hi: u64, dest: rawptr, escaped: bool, first_esc: u64, judged: bool) -> c.Shape_Fault {
	if src[lo] == 'n' {
		if dest != nil {
			(^any)(dest)^ = nil
		}
		return .None
	}
	d: Decoded
	fault := shape_leaf_decoded(r, src, lo, hi, &d if dest != nil else nil, escaped, first_esc, judged)
	if fault != .None || dest == nil {
		return fault
	}
	// The arm lives at the union's offset 0.
	arm := type_info_of(reflect.union_variant_typeid(d))
	buf, aerr := shape_alloc(arm.size, arm.align, r.allocator)
	if aerr != nil || raw_data(buf) == nil {
		return .Out_Of_Memory
	}
	runtime.mem_copy_non_overlapping(raw_data(buf), &d, arm.size)
	(^any)(dest)^ = any{raw_data(buf), arm.id}
	return .None
}

// The checked array at `src[lo]` into the bit_set op `op` at `dest`: each element one of its enum's member names
// (under `enums = .Int`, a member's integer), or an integer of its range. A repeat sets its bit again.
shape_leaf_bit_set :: proc(r: ^c.Shape_Run, src: []byte, lo: int, dest: rawptr, op: ^c.Shape_Op) -> c.Shape_Fault {
	names := op.enum_info != nil && !r.enum_ints
	bits: u128
	p := shape_skip_space(src, lo + 1)
	for p < len(src) && src[p] != ']' {
		if src[p] == ',' {
			p = shape_skip_space(src, p + 1)
			continue
		}
		v: i64
		end: int
		fault: c.Shape_Fault
		switch {
		case src[p] == '"' && names:
			end = shape_string_end(src, p) or_return
			// `op.width` is 8: the member's value as an i64.
			fault = shape_leaf_enum_name(src, u64(p), u64(end), &v, op)
		case (src[p] == '-' || (src[p] >= '0' && src[p] <= '9')) && !names:
			end = shape_scalar_end(src, p)
			fault = shape_leaf_int(src, u64(p), u64(end), &v, 8, true)
			if fault == .None && op.enum_info != nil && !slice.contains(op.enum_info.values, runtime.Type_Info_Enum_Value(v)) {
				fault = .Not_A_Member
			}
		case:
			fault = .Wrong_Kind
		}
		if fault != .None {
			return fault
		}
		bit := v - i64(op.required)
		if bit < 0 || bit >= i64(op.count) {
			return .Out_Of_Range
		}
		bits |= u128(1) << u128(bit)
		p = shape_skip_space(src, end)
	}
	if p >= len(src) {
		return .Wrong_Kind
	}
	if dest != nil {
		runtime.mem_copy_non_overlapping(dest, &bits, int(op.size))
	}
	return .None
}

// The checked value at `src[p]` as an `any` tree: an object as a `map[string]any`, an array as a `[dynamic]any`,
// a scalar as `shape_leaf_any` boxes it, all of it in `context.allocator`. A repeated key keeps the occurrence
// `r.keep_first` says. `src` ends where the value's container does, and a value running into its end is
// `.Wrong_Kind`.
shape_any_tree :: proc(r: ^c.Shape_Run, src: []byte, p: int) -> (v: any, end: int, fault: c.Shape_Fault) {
	p := p
	if p >= len(src) {
		return nil, p, .Wrong_Kind
	}
	switch src[p] {
	case '{':
		m, aerr := new(map[string]any)
		if aerr != nil {
			return nil, p, .Out_Of_Memory
		}
		for p = shape_skip_space(src, p + 1); p < len(src) && src[p] != '}'; p = shape_skip_space(src, p) {
			if src[p] == ',' {
				p = shape_skip_space(src, p + 1)
				continue
			}
			key_end := shape_string_end(src, p) or_return
			key: string
			shape_leaf_string(r, src, u64(p), u64(key_end), &key, shape_has_escape(src, p, key_end), 0) or_return
			child: any
			child, p = shape_any_tree(r, src, shape_skip_space(src, shape_skip_space(src, key_end) + 1)) or_return
			if r.keep_first && key in m^ {
				continue
			}
			if map_insert(m, key, child) == nil {
				return nil, p, .Out_Of_Memory
			}
		}
		if p >= len(src) {
			return nil, p, .Wrong_Kind
		}
		return m^, p + 1, .None
	case '[':
		list, aerr := new([dynamic]any)
		if aerr != nil {
			return nil, p, .Out_Of_Memory
		}
		for p = shape_skip_space(src, p + 1); p < len(src) && src[p] != ']'; p = shape_skip_space(src, p) {
			if src[p] == ',' {
				p = shape_skip_space(src, p + 1)
				continue
			}
			child: any
			child, p = shape_any_tree(r, src, p) or_return
			if _, err := append(list, child); err != nil {
				return nil, p, .Out_Of_Memory
			}
		}
		if p >= len(src) {
			return nil, p, .Wrong_Kind
		}
		return list^, p + 1, .None
	case '"':
		end = shape_string_end(src, p) or_return
		fault = shape_leaf_any(r, src, u64(p), u64(end), &v, shape_has_escape(src, p, end), 0, false)
		return
	}
	end = shape_scalar_end(src, p)
	if end == p {
		return nil, p, .Wrong_Kind
	}
	fault = shape_leaf_any(r, src, u64(p), u64(end), &v, false, 0, false)
	return
}

// Where the string token at `src[p]` ends, past its closing quote. One `src` cuts short is `.Wrong_Kind`.
@(private = "file")
shape_string_end :: proc(src: []byte, p: int) -> (end: int, fault: c.Shape_Fault) {
	end = lex.value_end(src, p, VC_STRING, 0)
	if end < p + 2 || end > len(src) || src[end - 1] != '"' {
		return end, .Wrong_Kind
	}
	return end, .None
}

// Whether the string token `src[lo:hi]` holds an escape.
@(private = "file")
shape_has_escape :: proc(src: []byte, lo, hi: int) -> bool {
	return bytes.index_byte(src[lo + 1:hi - 1], '\\') >= 0
}

// Where the checked number or literal at `src[p]` ends.
shape_scalar_end :: proc(src: []byte, p: int) -> int {
	p := p
	for p < len(src) {
		switch src[p] {
		case '0' ..= '9', 'a' ..= 'z', 'A' ..= 'Z', '+', '-', '.':
			p += 1
		case:
			return p
		}
	}
	return p
}

// Past the whitespace, and the JSONC comments, at `src[p]`: where `jsonc_skip` stops, on a `/` that opens no
// comment, or at the end. The cursor's fault is dropped: every caller reads a value the walk already checked,
// or pre-scans one the walk checks next.
shape_skip_space :: proc(src: []byte, p: int) -> int {
	s := Scanner{src = src, pos = u64(p)}
	jsonc_skip(&s, &Jsonc_Cursor{})
	return int(s.pos)
}

// A checked number token into a `Number`: the binary64 value and exactness `number_span` gives it, from the
// digits the walk folded (`r.num`) rather than a second lex.
shape_leaf_number :: proc(r: ^c.Shape_Run, lo, hi: u64, dest: rawptr) -> c.Shape_Fault {
	b := r.src[lo]
	if !number_starts_with(b) {
		return .Wrong_Kind
	}
	n := number.number_lexed(r.src, lo, hi, shape_number_lexed(r, lo, hi, false))
	if dest != nil {
		(^Number)(dest)^ = n
	}
	return .None
}
