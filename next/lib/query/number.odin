package query

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:math/big"
import "core:strconv"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Exact integers (`i64` or `big.Int`) and doubles, meeting by mathematical value.

is_number :: #force_inline proc "contextless" (v: Value) -> bool {
	#partial switch v.kind {
	case .Int, .Double, .Big: return true
	case .Node:               return node_token(v).kind == .Number
	case .Overlay:            return overlay_type(v) == .Number
	}
	return false
}

@(private)
is_integral_f64 :: #force_inline proc "contextless" (f: f64) -> bool {
	return f == math.trunc(f) && !math.is_inf(f)
}

@(private)
spelled_as_f64 :: proc "contextless" (s: string) -> (f64, bool) {
	b := transmute([]u8)s
	sn, valid := spell.number_strict(b, 0, u64(len(b)))
	if !valid {
		return 0, false
	}
	switch sn.kind {
	case .Int:   return f64(i64(sn.bits)), true
	case .Uint:  return f64(sn.bits), true
	case .Float: return transmute(f64)sn.bits, true
	case .Wide:  return spell.wide_double(b), true
	}
	return 0, false
}

@(private)
spelled_as_i64 :: proc(s: string) -> (i64, bool) {
	b := transmute([]u8)s
	if sn, valid := spell.number_strict(b, 0, u64(len(b))); valid {
		if sn.kind == .Int {
			return i64(sn.bits), true
		}
		if sn.kind == .Float {
			return as_i64(double_value(transmute(f64)sn.bits))
		}
	}
	return 0, false
}

@(private)
spelled_is_integer :: proc "contextless" (s: string) -> bool {
	if spell.is_plain_int_dec(s) {
		return true
	}
	b := transmute([]u8)s
	if sn, valid := spell.number_strict(b, 0, u64(len(b))); valid {
		#partial switch sn.kind {
		case .Int, .Uint: return true
		case .Float:      return is_integral_f64(transmute(f64)sn.bits)
		}
	}
	return false
}

@(require_results)
number_of :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	if v.kind == .Overlay {
		return overlay_number_of(h, v)
	}
	if v.kind != .Node {
		return retain(v), .Ok
	}
	d, at := (^Doc_Block)(v.p), tape.Node_Index(v.n)
	n, _ := tape.node_number(&d.doc, at)
	switch n.kind {
	case .Int:  return int_value(i64(n.bits)), .Ok
	case .Uint: return big_from_u64(h, n.bits)
	case .Float, .Wide:
		if d.doc.format != nil && .Binary in d.doc.format.caps {
			buf: [512]u8
			alloc := heap_allocator(h)
			if n.kind == .Float {
				f := transmute(f64)n.bits
				if !math.is_inf(f) && !math.is_nan(f) && abs(f) >= f64(u64(1) << 53) && f == math.trunc(f) {
					s, owned, ok := binary_number_text(&d.doc, at, buf[:], alloc)
					defer delete(owned, alloc)
					if ok && spell.is_plain_int_dec(s) {
						return big_from_text(h, s)
					}
				}
				return double_value(f), .Ok
			}
			s, owned, ok := binary_number_text(&d.doc, at, buf[:], alloc)
			defer delete(owned, alloc)
			if ok {
				if spell.is_plain_int_dec(s) {
					return big_from_text(h, s)
				}
				if sn, valid := spell.number_strict(transmute([]u8)s, 0, u64(len(s))); valid {
					switch sn.kind {
					case .Int:   return int_value(i64(sn.bits)), .Ok
					case .Uint:  return big_from_u64(h, sn.bits)
					case .Float: return double_value(transmute(f64)sn.bits), .Ok
					case .Wide:  return double_value(spell.wide_double(transmute([]u8)s)), .Ok
					}
				}
			}
			return double_value(math.nan_f64()), .Ok
		}
		form, _ := tape.number_form(&d.doc, at)
		if form.frac_digits == 0 && !form.exponent && !form.point && form.kind == 0 {
			return big_from_text(h, string(node_bytes(v)))
		}
		return double_value(spell.wide_double(node_bytes(v)) if n.kind == .Wide else transmute(f64)n.bits), .Ok
	}
	return NULL, .Ok
}

// Decodes the decimal text of a `.Binary` format number node into `buf` or an allocated buffer (never temp_allocator).
@(private)
binary_number_text :: proc(doc: ^tape.Document, at: tape.Node_Index, buf: []u8, alloc: runtime.Allocator) -> (s: string, owned: []u8, ok: bool) {
	room := tape.text_room(doc, at)
	if room <= 0 {
		return "", nil, false
	}
	if room <= len(buf) {
		s, ok = tape.node_text(doc, at, buf[:room])
		return s, nil, ok
	}
	if alloc.procedure == nil {
		return "", nil, false
	}
	tmp, aerr := make([]u8, room, alloc)
	if aerr != nil {
		return "", nil, false
	}
	s, ok = tape.node_text(doc, at, tmp)
	if !ok {
		delete(tmp, alloc)
		return "", nil, false
	}
	return s, tmp, true
}

as_f64 :: proc(v: Value) -> f64 {
	#partial switch v.kind {
	case .Int:    return f64(v.i)
	case .Double: return v.f
	case .Big:    f, _ := big.int_get_float(&(^Big_Block)(v.p).value); return f
	case .Overlay: return overlay_as_f64(v)
	case .Node:
		d, at := (^Doc_Block)(v.p), tape.Node_Index(v.n)
		n, _ := tape.node_number(&d.doc, at)
		switch n.kind {
		case .Int:   return f64(i64(n.bits))
		case .Uint:  return f64(n.bits)
		case .Float: return transmute(f64)n.bits
		case .Wide:
			if d.doc.format != nil && .Binary in d.doc.format.caps {
				buf: [512]u8
				s, owned, ok := binary_number_text(&d.doc, at, buf[:], context.allocator)
				defer delete(owned, context.allocator)
				if ok {
					if f, valid := spelled_as_f64(s); valid {
						return f
					}
				}
				return math.nan_f64()
			}
			return spell.wide_double(node_bytes(v))
		}
	}
	return 0
}

as_exact_i64 :: proc(v: Value) -> (i64, bool) {
	if v.kind == .Int {
		return v.i, true
	}
	if v.kind == .Node {
		if n, nok := tape.node_number(&(^Doc_Block)(v.p).doc, tape.Node_Index(v.n)); nok && n.kind == .Int {
			return i64(n.bits), true
		}
	}
	return 0, false
}

as_i64 :: proc(v: Value) -> (i64, bool) {
	#partial switch v.kind {
	case .Int: return v.i, true
	case .Double:
		if v.f == math.trunc(v.f) && v.f >= -TWO_63 && v.f < TWO_63 {
			return i64(v.f), true
		}
	case .Node:
		if n, nok := tape.node_number(&(^Doc_Block)(v.p).doc, tape.Node_Index(v.n)); nok {
			if n.kind == .Int {
				return i64(n.bits), true
			}
			if n.kind == .Float {
				return as_i64(double_value(transmute(f64)n.bits))
			}
		}
	case .Overlay: return overlay_as_i64(v)
	}
	return 0, false
}

trunc_i64 :: proc(v: Value) -> i64 {
	if i, ok := as_i64(v); ok {
		return i
	}
	if v.kind == .Big {
		return min(i64) if big_negative(v) else max(i64)
	}
	if _, is_uint, dec, is_big := node_big_int(v); is_big {
		if is_uint {
			return max(i64)
		}
		neg, _ := spell.decimal_parts(dec)
		return min(i64) if neg else max(i64)
	}
	f := as_f64(v)
	if math.is_nan(f) { return 0 }
	if f >= TWO_63    { return max(i64) }
	if f <= -TWO_63   { return min(i64) }
	return i64(f)
}

is_integer :: proc(v: Value) -> bool {
	#partial switch v.kind {
	case .Int, .Big: return true
	case .Double:    return is_integral_f64(v.f)
	case .Overlay:   return overlay_is_integer(v)
	case .Node:
		d, at := (^Doc_Block)(v.p), tape.Node_Index(v.n)
		n, _ := tape.node_number(&d.doc, at)
		#partial switch n.kind {
		case .Int, .Uint: return true
		case .Float:      return is_integral_f64(transmute(f64)n.bits)
		}
		if d.doc.format != nil && .Binary in d.doc.format.caps {
			buf: [512]u8
			s, owned, ok := binary_number_text(&d.doc, at, buf[:], context.allocator)
			defer delete(owned, context.allocator)
			return ok && spelled_is_integer(s)
		}
		form, _ := tape.number_form(&d.doc, at)
		return form.frac_digits == 0 && !form.exponent
	}
	return false
}

@(require_results)
num_add :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	if a.kind == .Int && b.kind == .Int {
		if r, ov := intrinsics.overflow_add(a.i, b.i); !ov {
			return int_value(r), .Ok
		}
	}
	return num_slow(h, .Add, a, b)
}

@(require_results)
num_sub :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	if a.kind == .Int && b.kind == .Int {
		if r, ov := intrinsics.overflow_sub(a.i, b.i); !ov {
			return int_value(r), .Ok
		}
	}
	return num_slow(h, .Subtract, a, b)
}

@(require_results)
num_mul :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	if a.kind == .Int && b.kind == .Int {
		if r, ov := intrinsics.overflow_mul(a.i, b.i); !ov {
			return int_value(r), .Ok
		}
	}
	return num_slow(h, .Multiply, a, b)
}

@(require_results)
num_div :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	if a.kind == .Int && b.kind == .Int && b.i != 0 && !(a.i == min(i64) && b.i == -1) {
		return (int_value(a.i / b.i) if a.i % b.i == 0 else double_value(f64(a.i) / f64(b.i))), .Ok
	}
	return num_slow(h, .Divide, a, b)
}

@(require_results)
num_quotient :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	if a.kind == .Int && b.kind == .Int && b.i != 0 && !(a.i == min(i64) && b.i == -1) {
		return int_value(a.i / b.i), .Ok
	}
	x := number_of(h, a) or_return
	defer release(h, x)
	y := number_of(h, b) or_return
	defer release(h, y)
	if x.kind == .Double || y.kind == .Double {
		return num_div(h, x, y)
	}
	if big_is_zero(y) {
		return NULL, fail(h, .Zero_Divisor, .Quotient, a, b)
	}
	return big_op(h, .Quotient, x, y, a, b)
}

@(require_results)
num_rem :: proc(h: ^Heap, a, b: Value, truncate: bool) -> (res: Value, status: Status) {
	if a.kind == .Int && b.kind == .Int {
		if b.i == 0 {
			return NULL, fail(h, .Zero_Divisor, .Remainder, a, b)
		}
		return int_value(0 if b.i == -1 else a.i % b.i), .Ok
	}
	x, y := as_f64(a), as_f64(b)
	if math.is_nan(x) || math.is_nan(y) {
		return double_value(math.nan_f64()), .Ok
	}
	if !truncate && (a.kind == .Double || b.kind == .Double || !is_integer(a) || !is_integer(b)) {
		if y == 0 {
			return NULL, fail(h, .Zero_Divisor, .Remainder, a, b)
		}
		return double_value(math.mod(x, y)), .Ok
	}
	ia := integer_part(h, a) or_return
	defer release(h, ia)
	ib := integer_part(h, b) or_return
	defer release(h, ib)
	if ia.kind == .Int && ib.kind == .Int {
		if ib.i == 0 {
			return NULL, fail(h, .Zero_Divisor, .Remainder, a, b)
		}
		return int_value(0 if ib.i == -1 else ia.i % ib.i), .Ok
	}
	return big_op(h, .Remainder, ia, ib, a, b)
}

@(private, require_results)
integer_part :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	x := number_of(h, v) or_return
	if x.kind != .Double {
		return x, .Ok
	}
	if math.is_nan(x.f) {
		return int_value(0), .Ok
	}
	f := math.trunc(x.f)
	if f >= -TWO_63 && f < TWO_63 {
		return int_value(i64(f)), .Ok
	}
	if math.is_inf(f) {
		return int_value(max(i64) if f > 0 else min(i64)), .Ok
	}
	buf: [400]u8
	return big_from_text(h, strconv.write_float(buf[:], f, 'f', 0, 64, {}))
}

@(require_results)
num_neg :: proc(h: ^Heap, a: Value) -> (res: Value, status: Status) {
	if a.kind == .Int && a.i != min(i64) {
		return int_value(-a.i), .Ok
	}
	x := number_of(h, a) or_return
	defer release(h, x)
	if x.kind == .Double {
		return double_value(-x.f), .Ok
	}
	if x.kind == .Int {
		return big_op(h, .Subtract, int_value(0), x, a, a)
	}
	r := alloc_big(h) or_return
	if big.int_neg(&(^Big_Block)(r.p).value, &(^Big_Block)(x.p).value, heap_allocator(h)) != nil {
		release(h, r)
		return NULL, fail_memory(h)
	}
	return normal_big(h, r), .Ok
}

@(private)
num_slow :: proc(h: ^Heap, op: Op, a, b: Value) -> (res: Value, status: Status) {
	x := number_of(h, a) or_return
	defer release(h, x)
	y := number_of(h, b) or_return
	defer release(h, y)
	if x.kind == .Double || y.kind == .Double {
		p, q := as_f64(x), as_f64(y)
		#partial switch op {
		case .Add:      return double_value(p + q), .Ok
		case .Subtract: return double_value(p - q), .Ok
		case .Multiply: return double_value(p * q), .Ok
		case .Divide:
			if q == 0 {
				return NULL, fail(h, .Zero_Divisor, .Divide, a, b)
			}
			return double_value(p / q), .Ok
		}
		return NULL, .Ok
	}
	if op == .Divide {
		if big_is_zero(y) {
			return NULL, fail(h, .Zero_Divisor, .Divide, a, b)
		}
		if x.kind == .Int && y.kind == .Int && !(x.i == min(i64) && y.i == -1) {
			return num_div(h, x, y)
		}
	}
	return big_op(h, op, x, y, a, b)
}

@(private)
big_op :: proc(h: ^Heap, op: Op, x, y: Value, a, b: Value) -> (res: Value, status: Status) {
	bx, by: big.Int
	defer big.int_destroy(&bx, &by)
	px := big_operand(h, x, &bx) or_return
	py := big_operand(h, y, &by) or_return
	r := alloc_big(h) or_return
	dst, alloc := &(^Big_Block)(r.p).value, heap_allocator(h)
	err: big.Error
	#partial switch op {
	case .Add:      err = big.int_add(dst, px, py, alloc)
	case .Subtract: err = big.int_sub(dst, px, py, alloc)
	case .Multiply: err = big.int_mul(dst, px, py, alloc)
	case .Divide, .Quotient:
		rem: big.Int
		defer big.int_destroy(&rem)
		err = big.int_divmod(dst, &rem, px, py, alloc)
		if op == .Divide && err == nil {
			if zero, _ := big.int_is_zero(&rem); !zero {
				release(h, r)
				return double_value(big_div_f64(px, py)), .Ok
			}
		}
	case .Remainder:
		if zero, _ := big.int_is_zero(py); zero {
			release(h, r)
			return NULL, fail(h, .Zero_Divisor, .Remainder, a, b)
		}
		q: big.Int
		defer big.int_destroy(&q)
		err = big.int_divmod(&q, dst, px, py, alloc)
	}
	if err != nil {
		release(h, r)
		return NULL, fail_memory(h)
	}
	return normal_big(h, r), .Ok
}

@(private)
big_div_f64 :: proc(px, py: ^big.Int) -> f64 {
	bx, _ := big.count_bits(px)
	by, _ := big.count_bits(py)
	neg := (px.sign == .Negative) != (py.sign == .Negative)
	if bx == 0 || by - bx > 1080 {
		return -0.0 if neg else 0.0
	}
	if bx - by > 1025 {
		return math.inf_f64(-1 if neg else 1)
	}
	if bx <= 1020 && by <= 1020 {
		fx, _ := big.int_get_float(px)
		fy, _ := big.int_get_float(py)
		return fx / fy
	}
	cx, cy := min(bx, 60), min(by, 60)
	tx, _ := big_extract_top(px, bx, cx)
	ty, _ := big_extract_top(py, by, cy)
	r := math.ldexp(f64(tx) / f64(ty), (bx - cx) - (by - cy))
	return -r if neg else r
}

@(private)
big_extract_top :: proc(x: ^big.Int, total_bits, count: int) -> (top: u64, tail_nonzero: bool) {
	B :: big._DIGIT_BITS
	lo := total_bits - count
	lo_limb, lo_bit := lo / B, uint(lo % B)
	for k in 0 ..< lo_limb {
		if x.digit[k] != 0 {
			tail_nonzero = true
			break
		}
	}
	tail_nonzero ||= lo_bit > 0 && u64(x.digit[lo_limb]) & ((u64(1) << lo_bit) - 1) != 0
	shift := 0
	for k := lo_limb; k < x.used; k += 1 {
		d := u64(x.digit[k])
		if k == lo_limb {
			top, shift = d >> lo_bit, B - int(lo_bit)
		} else {
			if shift < 64 {
				top |= d << uint(shift)
			}
			shift += B
		}
	}
	return
}

@(private)
big_operand :: proc(h: ^Heap, v: Value, room: ^big.Int) -> (res: ^big.Int, status: Status) {
	if v.kind == .Big {
		return &(^Big_Block)(v.p).value, .Ok
	}
	if big.int_set_from_integer(room, v.i, allocator = heap_allocator(h)) != nil {
		return nil, fail_memory(h)
	}
	return room, .Ok
}

@(private)
alloc_big :: proc(h: ^Heap) -> (res: Value, status: Status) {
	b := alloc_block(h, size_of(Big_Block)) or_return
	(^Big_Block)(b).value = {}
	return {p = b, kind = .Big, held = true}, .Ok
}

@(private)
big_clone :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	r := alloc_big(h) or_return
	if big.int_copy(&(^Big_Block)(r.p).value, &(^Big_Block)(v.p).value, allocator = heap_allocator(h)) != nil {
		release(h, r)
		return NULL, fail_memory(h)
	}
	return r, .Ok
}

@(private)
normal_big :: proc(h: ^Heap, r: Value) -> Value {
	x := &(^Big_Block)(r.p).value
	if i, err := big.int_get_i64(x); err == nil && (i < 0) == (x.sign == .Negative) && fits_i64(x) {
		release(h, r)
		return int_value(i)
	}
	return r
}

@(private)
fits_i64 :: proc(x: ^big.Int) -> bool {
	bits, _ := big.count_bits(x)
	if bits < 64 {
		return true
	}
	if bits > 64 || x.sign != .Negative {
		return false
	}
	n, _ := big.int_count_lsb(x)
	return n == 63
}

@(private)
big_negative :: #force_inline proc(v: Value) -> bool { return (^Big_Block)(v.p).value.sign == .Negative }

@(private)
big_is_zero :: proc(v: Value) -> bool {
	if v.kind == .Int {
		return v.i == 0
	}
	z, _ := big.int_is_zero(&(^Big_Block)(v.p).value)
	return z
}

@(private)
big_from_u64 :: proc(h: ^Heap, u: u64) -> (res: Value, status: Status) {
	r := alloc_big(h) or_return
	if big.int_set_from_integer(&(^Big_Block)(r.p).value, u, allocator = heap_allocator(h)) != nil {
		release(h, r)
		return NULL, fail_memory(h)
	}
	return r, .Ok
}

@(private, require_results)
big_from_text :: proc(h: ^Heap, text: string) -> (res: Value, status: Status) {
	if i, ok := strconv.parse_i64_of_base(text, 10); ok {
		return int_value(i), .Ok
	}
	r := alloc_big(h) or_return
	if big.int_atoi(&(^Big_Block)(r.p).value, text, 10, allocator = heap_allocator(h)) != nil {
		release(h, r)
		return NULL, fail_memory(h)
	}
	return normal_big(h, r), .Ok
}

compare_numbers :: proc(a, b: Value, allocator := context.allocator) -> int {
	if a.kind == .Int && b.kind == .Int {
		return int(a.i > b.i) - int(a.i < b.i)
	}
	if a.kind == .Double && b.kind == .Double {
		an, bn := math.is_nan(a.f), math.is_nan(b.f)
		return (int(bn) - int(an)) if (an || bn) else (int(a.f > b.f) - int(a.f < b.f))
	}
	if a.kind == .Int && b.kind == .Double { return -int_against_double(b.f, a.i) }
	if a.kind == .Double && b.kind == .Int { return int_against_double(a.f, b.i) }
	return compare_wide(a, b, allocator)
}

@(private)
int_against_double :: proc(f: f64, i: i64) -> int {
	if math.is_nan(f) || f < -TWO_63 { return -1 }
	if f >= TWO_63                   { return 1 }
	t := math.trunc(f)
	if ti := i64(t); ti != i {
		return int(ti > i) - int(ti < i)
	}
	return int(f > t) - int(f < t)
}

@(private)
compare_double_big :: proc(f: f64, y: ^big.Int) -> int {
	if math.is_nan(f) { return -1 }
	if math.is_inf(f) { return 1 if f > 0 else -1 }
	y_neg := y.sign == .Negative
	if f == 0 { return 1 if y_neg else -1 }
	f_neg := f < 0
	if f_neg != y_neg { return -1 if f_neg else 1 }
	bits := transmute(u64)abs(f)
	exp := int((bits >> 52) & 0x7FF) - 1023
	cmp := 0
	if exp < 63 {
		cmp = -1
	} else {
		y_bits, _ := big.count_bits(y)
		if exp + 1 != y_bits {
			cmp = int(exp + 1 > y_bits) - int(exp + 1 < y_bits)
		} else {
			m := (u64(1) << 52) | (bits & ((u64(1) << 52) - 1))
			y_top, y_tail := big_extract_top(y, y_bits, 53)
			cmp = (int(m > y_top) - int(m < y_top)) if m != y_top else (-1 if y_tail else 0)
		}
	}
	return -cmp if f_neg else cmp
}

@(private)
node_big_int :: proc(v: Value) -> (u: u64, is_uint: bool, dec: string, ok: bool) {
	if v.kind == .Overlay {
		return overlay_big_int(v)
	}
	if v.kind != .Node {
		return
	}
	d, at := (^Doc_Block)(v.p), tape.Node_Index(v.n)
	n, _ := tape.node_number(&d.doc, at)
	if n.kind == .Uint {
		return n.bits, true, "", true
	}
	if (n.kind == .Float || n.kind == .Wide) && (d.doc.format == nil || .Binary not_in d.doc.format.caps) {
		form, _ := tape.number_form(&d.doc, at)
		if form.frac_digits == 0 && !form.exponent && !form.point && form.kind == 0 {
			return 0, false, string(node_bytes(v)), true
		}
	}
	return
}

@(private)
compare_decimal :: proc "contextless" (a, b: string) -> int {
	an, ad := spell.decimal_parts(a)
	bn, bd := spell.decimal_parts(b)
	if an != bn {
		return -1 if an else 1
	}
	cmp := int(len(ad) > len(bd)) - int(len(ad) < len(bd))
	if cmp == 0 {
		cmp = int(ad > bd) - int(ad < bd)
	}
	return -cmp if an else cmp
}

@(private)
node_big_decimal :: proc(v: Value, buf: ^[24]u8) -> string {
	u, is_uint, dec, _ := node_big_int(v)
	return strconv.write_uint(buf[:], u, 10) if is_uint else dec
}

@(private)
compare_node_big_double :: proc(a: Value, f: f64) -> int {
	if math.is_nan(f) { return 1 }
	if math.is_inf(f) { return -1 if f > 0 else 1 }
	abuf: [24]u8
	ad := node_big_decimal(a, &abuf)
	aneg, _ := spell.decimal_parts(ad)
	if f == 0 || aneg != (f < 0) || abs(f) < TWO_63 {
		return -1 if aneg else 1
	}
	fbuf: [320]u8
	return compare_decimal(ad, strconv.write_float(fbuf[:], f, 'f', 0, 64, {}))
}

@(private)
compare_node_big_against_big :: proc(a: Value, y: ^big.Int, allocator: runtime.Allocator) -> int {
	u, is_uint, dec, _ := node_big_int(a)
	if is_uint {
		if y.sign == .Negative { return 1 }
		if y_bits, _ := big.count_bits(y); y_bits > 64 { return -1 }
		yv, _ := big.int_get_u64(y)
		return int(u > yv) - int(u < yv)
	}
	aneg, ad := spell.decimal_parts(dec)
	if aneg != (y.sign == .Negative) {
		return -1 if aneg else 1
	}
	y_bits, _ := big.count_bits(y)
	d := len(ad)
	if (d - 1) * 33219 > y_bits * 10000 { return -1 if aneg else 1 }
	if d * 33220 < (y_bits - 1) * 10000 { return 1 if aneg else -1 }
	tmp: big.Int
	defer big.int_destroy(&tmp)
	if big.int_atoi(&tmp, dec, 10, allocator = allocator) != nil {
		return 0
	}
	c, _ := big.int_compare(&tmp, y)
	return c
}

@(private)
compare_wide :: proc(a, b: Value, allocator: runtime.Allocator) -> int {
	x, y := settle(a), settle(b)
	xw, yw := x.kind == .Node || x.kind == .Overlay, y.kind == .Node || y.kind == .Overlay
	if x.kind != .Big && y.kind != .Big && !xw && !yw { return compare_numbers(x, y, allocator) }
	if x.kind == .Big && y.kind == .Big {
		c, _ := big.int_compare(&(^Big_Block)(x.p).value, &(^Big_Block)(y.p).value)
		return c
	}
	if xw && yw {
		abuf, bbuf: [24]u8
		return compare_decimal(node_big_decimal(x, &abuf), node_big_decimal(y, &bbuf))
	}
	if xw && y.kind == .Big { return compare_node_big_against_big(x, &(^Big_Block)(y.p).value, allocator) }
	if x.kind == .Big && yw { return -compare_node_big_against_big(y, &(^Big_Block)(x.p).value, allocator) }
	if x.kind == .Big || xw { return -compare_wide(y, x, allocator) }
	if y.kind == .Big {
		return (1 if big_negative(y) else -1) if x.kind == .Int else compare_double_big(x.f, &(^Big_Block)(y.p).value)
	}
	if x.kind == .Int {
		ybuf: [24]u8
		yneg, _ := spell.decimal_parts(node_big_decimal(y, &ybuf))
		return 1 if yneg else -1
	}
	return -compare_node_big_double(y, x.f)
}

@(private)
settle :: proc(v: Value) -> Value {
	if v.kind != .Node && v.kind != .Overlay { return v }
	if i, ok := as_i64(v); ok { return int_value(i) }
	if _, _, _, is_big := node_big_int(v); is_big { return v }
	return double_value(as_f64(v))
}

numbers_equal :: proc(a, b: Value, allocator := context.allocator) -> bool {
	if a.kind == .Int && b.kind == .Int {
		return a.i == b.i
	}
	if (a.kind != .Int && a.kind != .Big && math.is_nan(as_f64(a))) || (b.kind != .Int && b.kind != .Big && math.is_nan(as_f64(b))) {
		return false
	}
	return compare_numbers(a, b, allocator) == 0
}

@(private) HASH_MOD :: u64((1 << 61) - 1)

@(private)
mod_hash_p :: #force_inline proc "contextless" (v: u128) -> u64 {
	r := (v & u128(HASH_MOD)) + (v >> 61)
	r = (r & u128(HASH_MOD)) + (r >> 61)
	return 0 if u64(r) == HASH_MOD else u64(r)
}

@(private)
hash_wide_int :: #force_inline proc "contextless" (neg: bool, rem: u64) -> u64 {
	return mix64(rem ~ (0x5555555555555555 if neg else 0xAAAAAAAAAAAAAAAA))
}

@(private)
hash_number :: proc(v: Value) -> u64 {
	if i, ok := as_i64(v); ok {
		return mix64(u64(i))
	}
	if v.kind == .Big {
		x := &(^Big_Block)(v.p).value
		acc: u64
		#reverse for d in x.digit[:x.used] {
			acc = mod_hash_p((u128(acc) << big._DIGIT_BITS) + u128(d))
		}
		return hash_wide_int(x.sign == .Negative, acc)
	}
	if u, is_uint, dec, is_big := node_big_int(v); is_big {
		if is_uint {
			return hash_wide_int(false, mod_hash_p(u128(u)))
		}
		neg, digits := spell.decimal_parts(dec)
		acc: u64
		for c in transmute([]u8)digits {
			acc = mod_hash_p(u128(acc) * 10 + u128(c - '0'))
		}
		return hash_wide_int(neg, acc)
	}
	f := as_f64(v)
	if f == 0 {
		return mix64(0)
	}
	if is_integral_f64(f) {
		bits := transmute(u64)abs(f)
		m := (u64(1) << 52) | (bits & ((u64(1) << 52) - 1))
		e := int((bits >> 52) & 0x7FF) - 1023 - 52
		return hash_wide_int(f < 0, mod_hash_p(u128(m) * (u128(1) << uint(e % 61))))
	}
	return mix64(transmute(u64)f ~ 0x9E3779B97F4A7C15)
}

@(private)
mix64 :: #force_inline proc "contextless" (x: u64) -> u64 {
	x := x
	x ~= x >> 30
	x *= 0xBF58476D1CE4E5B9
	x ~= x >> 27
	x *= 0x94D049BB133111EB
	x ~= x >> 31
	return x
}

double_digits :: proc(f: f64, digits: ^[17]u8) -> (n: int, point: int) {
	buf: [32]u8
	s := strconv.write_float(buf[:], f, 'e', -1, 64, {})
	e := 0
	for c, i in transmute([]u8)s {
		if c == 'e' {
			e = i
			break
		}
		if c != '.' && n < len(digits) {
			digits[n] = c
			n += 1
		}
	}
	exp, _ := strconv.parse_int(s[e + 1:], 10)
	for n > 1 && digits[n - 1] == '0' {
		n -= 1
	}
	return n, exp + 1
}

@(private)
write_integer :: proc(h: ^Heap, out: ^[dynamic]u8, v: Value) -> Status {
	if v.kind == .Int {
		buf: [24]u8
		return put_bytes(h, out, strconv.write_int(buf[:], v.i, 10))
	}
	alloc := heap_allocator(h)
	s, err := big.int_itoa_string(&(^Big_Block)(v.p).value, 10, false, alloc)
	if err != nil {
		return fail_memory(h)
	}
	defer delete(s, alloc)
	return put_bytes(h, out, s)
}

@(require_results)
parse_number :: proc(h: ^Heap, text: string, loose := false) -> (v: Value, ok: bool, status: Status) {
	b := transmute([]u8)text
	if len(b) == 0 {
		return NULL, false, .Ok
	}
	if !loose {
		n, good := spell.number_strict(b, 0, u64(len(b)))
		if !good {
			return NULL, false, .Ok
		}
		if integer_text(text) {
			if n.kind == .Int {
				return int_value(i64(n.bits)), true, .Ok
			}
			x, s := big_from_text(h, text)
			return x, s == .Ok, s
		}
		f, _ := spelled_as_f64(text)
		return double_value(f), true, .Ok
	}
	f, nr, good := strconv.parse_f64_prefix(text)
	if nr != len(text) {
		return NULL, false, .Ok
	}
	if !good {
		f = spell.wide_double(b)
	}
	if integer_text(text) {
		x, s := big_from_text(h, text[1:] if text[0] == '+' else text)
		return x, s == .Ok, s
	}
	return double_value(f), true, .Ok
}

@(private)
integer_text :: proc(s: string) -> bool {
	i := int(len(s) > 0 && (s[0] == '-' || s[0] == '+'))
	if i == len(s) {
		return false
	}
	for c in transmute([]u8)s[i:] {
		if c - '0' >= 10 {
			return false
		}
	}
	return true
}

@(private) TWO_63 :: f64(9223372036854775808)
