package query

import "base:intrinsics"
import "core:math"
import "core:math/big"
import "core:strconv"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Numbers: an integer is exact, in an `i64` or past it in a big integer, and any other number is a double. Integers
// and doubles meet by mathematical value: `1 == 1.0`, and `/` gives an integer when the quotient is one.

is_number :: #force_inline proc "contextless" (v: Value) -> bool {
	#partial switch v.kind {
	case .Int, .Double, .Big:
		return true
	case .Node:
		return node_token(v).kind == .Number
	}
	return false
}

// Number `v` as an `.Int`, `.Double` or `.Big`: a document's number read from its node, a big one into a block the
// caller releases. `v` is a number.
@(require_results)
number_of :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	if v.kind != .Node {
		return retain(v), .Ok
	}
	d := (^Doc_Block)(v.p)
	at := tape.Node_Index(v.n)
	n, _ := tape.node_number(&d.doc, at)
	switch n.kind {
	case .Int:
		return int_value(i64(n.bits)), .Ok
	case .Uint:
		return big_from_u64(h, n.bits)
	case .Float, .Wide:
		form, _ := tape.number_form(&d.doc, at)
		if form.frac_digits == 0 && !form.exponent && !form.point && form.kind == 0 {
			return big_from_text(h, string(node_bytes(v)))
		}
		if n.kind == .Wide {
			return double_value(wide_double(node_bytes(v))), .Ok
		}
		return double_value(transmute(f64)n.bits), .Ok
	}
	return NULL, .Ok
}

// A number past binary64's range as the double it rounds to: an infinity or a zero, with its sign.
@(private)
wide_double :: proc "contextless" (text: []u8) -> f64 {
	neg := len(text) > 0 && text[0] == '-'
	big_order := true
	for c, i in text {
		if c | 0x20 == 'e' {
			big_order = i + 1 >= len(text) || text[i + 1] != '-'
			break
		}
	}
	f := math.inf_f64(1) if big_order else 0
	return -f if neg else f
}

// The double nearest number `v`.
as_f64 :: proc(v: Value) -> f64 {
	#partial switch v.kind {
	case .Int:
		return f64(v.i)
	case .Double:
		return v.f
	case .Big:
		f, _ := big.int_get_float(&(^Big_Block)(v.p).value)
		return f
	case .Node:
		d := (^Doc_Block)(v.p)
		n, _ := tape.node_number(&d.doc, tape.Node_Index(v.n))
		switch n.kind {
		case .Int:
			return f64(i64(n.bits))
		case .Uint:
			return f64(n.bits)
		case .Float:
			return transmute(f64)n.bits
		case .Wide:
			return wide_double(node_bytes(v))
		}
	}
	return 0
}

// Number `v` as an `i64` when it is an integer in its range, with no rounding.
as_i64 :: proc(v: Value) -> (i64, bool) {
	#partial switch v.kind {
	case .Int:
		return v.i, true
	case .Double:
		if v.f == math.trunc(v.f) && v.f >= -TWO_63 && v.f < TWO_63 {
			return i64(v.f), true
		}
	case .Node:
		d := (^Doc_Block)(v.p)
		n, _ := tape.node_number(&d.doc, tape.Node_Index(v.n))
		if n.kind == .Int {
			return i64(n.bits), true
		}
		if n.kind == .Float {
			return as_i64(double_value(transmute(f64)n.bits))
		}
	}
	return 0, false
}

// Number `v` truncated toward zero to an `i64`, clamped to its range, and 0 for NaN.
trunc_i64 :: proc(v: Value) -> i64 {
	if i, ok := as_i64(v); ok {
		return i
	}
	if v.kind == .Big {
		return max(i64) if !big_negative(v) else min(i64)
	}
	f := as_f64(v)
	switch {
	case math.is_nan(f):
		return 0
	case f >= TWO_63:
		return max(i64)
	case f <= -TWO_63:
		return min(i64)
	}
	return i64(f)
}

// Whether number `v` is an integer, of any size.
is_integer :: proc(v: Value) -> bool {
	#partial switch v.kind {
	case .Int, .Big:
		return true
	case .Double:
		return v.f == math.trunc(v.f) && !math.is_inf(v.f)
	case .Node:
		d := (^Doc_Block)(v.p)
		n, _ := tape.node_number(&d.doc, tape.Node_Index(v.n))
		#partial switch n.kind {
		case .Int, .Uint:
			return true
		case .Float:
			f := transmute(f64)n.bits
			return f == math.trunc(f) && !math.is_inf(f)
		}
		form, _ := tape.number_form(&d.doc, tape.Node_Index(v.n))
		return form.frac_digits == 0 && !form.exponent
	}
	return false
}

// Whether `a` and `b` are both doubles, or one is a double and the other a number, so they meet as doubles.
@(private)
meets_as_double :: #force_inline proc(a, b: Value) -> bool {
	return a.kind == .Double || b.kind == .Double
}

@(require_results)
num_add :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	if a.kind == .Int && b.kind == .Int {
		if r, overflow := intrinsics.overflow_add(a.i, b.i); !overflow {
			return int_value(r), .Ok
		}
	}
	return num_slow(h, .Add, a, b)
}

@(require_results)
num_sub :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	if a.kind == .Int && b.kind == .Int {
		if r, overflow := intrinsics.overflow_sub(a.i, b.i); !overflow {
			return int_value(r), .Ok
		}
	}
	return num_slow(h, .Subtract, a, b)
}

@(require_results)
num_mul :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	if a.kind == .Int && b.kind == .Int {
		if r, overflow := intrinsics.overflow_mul(a.i, b.i); !overflow {
			return int_value(r), .Ok
		}
	}
	return num_slow(h, .Multiply, a, b)
}

// `a / b`: an integer when both are integers and it divides, else a double. A zero divisor is an error.
@(require_results)
num_div :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	if a.kind == .Int && b.kind == .Int && b.i != 0 && !(a.i == min(i64) && b.i == -1) {
		if a.i % b.i == 0 {
			return int_value(a.i / b.i), .Ok
		}
		return double_value(f64(a.i) / f64(b.i)), .Ok
	}
	return num_slow(h, .Divide, a, b)
}

// The quotient of `a / b` truncated toward zero when both are held as integers, else `num_div`'s. A zero divisor is
// an error.
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

// The remainder of `a / b` with the quotient truncated toward zero, its sign the dividend's. With `truncate` both
// are first truncated to integers, as C's `%` on integers. A zero divisor is an error, and NaN gives NaN.
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
	if !truncate && (meets_as_double(a, b) || !is_integer(a) || !is_integer(b)) {
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

// Number `v` truncated toward zero to an integer, exact for any finite double. An infinity clamps to `i64`.
@(require_results)
integer_part :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	x := number_of(h, v) or_return
	if x.kind != .Double {
		return x, .Ok
	}
	f := math.trunc(x.f)
	if f >= -TWO_63 && f < TWO_63 {
		return int_value(i64(f)), .Ok
	}
	if math.is_inf(f) {
		return int_value(max(i64) if f > 0 else min(i64)), .Ok
	}
	return big_from_double(h, f)
}

@(require_results)
num_neg :: proc(h: ^Heap, a: Value) -> (res: Value, status: Status) {
	if a.kind == .Int && a.i != min(i64) {
		return int_value(-a.i), .Ok
	}
	x := number_of(h, a) or_return
	defer release(h, x)
	#partial switch x.kind {
	case .Double:
		return double_value(-x.f), .Ok
	case .Int:
		return big_op(h, .Subtract, int_value(0), x, a, a)
	}
	r := alloc_big(h) or_return
	if big.int_neg(&(^Big_Block)(r.p).value, &(^Big_Block)(x.p).value, h.allocator) != nil {
		release(h, r)
		return NULL, fail_memory(h)
	}
	return normal_big(h, r), .Ok
}

// The arithmetic the `i64` path left: a big integer when both are integers, else doubles.
@(private)
num_slow :: proc(h: ^Heap, op: Op, a, b: Value) -> (res: Value, status: Status) {
	x := number_of(h, a) or_return
	defer release(h, x)
	y := number_of(h, b) or_return
	defer release(h, y)
	if x.kind == .Double || y.kind == .Double {
		p, q := as_f64(x), as_f64(y)
		#partial switch op {
		case .Add:
			return double_value(p + q), .Ok
		case .Subtract:
			return double_value(p - q), .Ok
		case .Multiply:
			return double_value(p * q), .Ok
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

// `x op y` over big integers, either of which may be an `.Int`. A division that leaves a remainder is a double.
@(private)
big_op :: proc(h: ^Heap, op: Op, x, y: Value, a, b: Value) -> (res: Value, status: Status) {
	bx, by: big.Int
	defer big.int_destroy(&bx, &by)
	px := big_operand(h, x, &bx) or_return
	py := big_operand(h, y, &by) or_return
	r := alloc_big(h) or_return
	dst := &(^Big_Block)(r.p).value
	err: big.Error
	#partial switch op {
	case .Add:
		err = big.int_add(dst, px, py, h.allocator)
	case .Subtract:
		err = big.int_sub(dst, px, py, h.allocator)
	case .Multiply:
		err = big.int_mul(dst, px, py, h.allocator)
	case .Divide:
		rem: big.Int
		defer big.int_destroy(&rem)
		err = big.int_divmod(dst, &rem, px, py, h.allocator)
		if zero, _ := big.int_is_zero(&rem); err == nil && !zero {
			release(h, r)
			return double_value(as_f64(a) / as_f64(b)), .Ok
		}
	case .Quotient:
		rem: big.Int
		defer big.int_destroy(&rem)
		err = big.int_divmod(dst, &rem, px, py, h.allocator)
	case .Remainder:
		if zero, _ := big.int_is_zero(py); zero {
			release(h, r)
			return NULL, fail(h, .Zero_Divisor, .Remainder, a, b)
		}
		q: big.Int
		defer big.int_destroy(&q)
		err = big.int_divmod(&q, dst, px, py, h.allocator)
	}
	if err != nil {
		release(h, r)
		return NULL, fail_memory(h)
	}
	return normal_big(h, r), .Ok
}

// The big integer of `v`, an `.Int` set into `room`.
@(private)
big_operand :: proc(h: ^Heap, v: Value, room: ^big.Int) -> (res: ^big.Int, status: Status) {
	if v.kind == .Big {
		return &(^Big_Block)(v.p).value, .Ok
	}
	if big.int_set_from_integer(room, v.i, allocator = h.allocator) != nil {
		return nil, fail_memory(h)
	}
	return room, .Ok
}

@(private)
alloc_big :: proc(h: ^Heap) -> (res: Value, status: Status) {
	b := alloc_block(h, size_of(Big_Block)) or_return
	x := (^Big_Block)(b)
	x.value = {}
	return {p = x, kind = .Big, held = true}, .Ok
}

// `r`, or the `.Int` it holds when it fits `i64`.
@(private)
normal_big :: proc(h: ^Heap, r: Value) -> Value {
	if i, err := big.int_get_i64(&(^Big_Block)(r.p).value); err == nil {
		x := &(^Big_Block)(r.p).value
		if (i < 0) == big_negative(r) && fits_i64(x) {
			release(h, r)
			return int_value(i)
		}
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
	// -2^63 has 64 bits and fits.
	n, _ := big.int_count_lsb(x)
	return n == 63
}

@(private)
big_negative :: proc(v: Value) -> bool {
	return (^Big_Block)(v.p).value.sign == .Negative
}

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
	if big.int_set_from_integer(&(^Big_Block)(r.p).value, u, allocator = h.allocator) != nil {
		release(h, r)
		return NULL, fail_memory(h)
	}
	return r, .Ok
}

// The integer a decimal text of digits with an optional `-` spells.
@(require_results)
big_from_text :: proc(h: ^Heap, text: string) -> (res: Value, status: Status) {
	if i, ok := strconv.parse_i64_of_base(text, 10); ok {
		return int_value(i), .Ok
	}
	r := alloc_big(h) or_return
	if big.int_atoi(&(^Big_Block)(r.p).value, text, 10, allocator = h.allocator) != nil {
		release(h, r)
		return NULL, fail_memory(h)
	}
	return normal_big(h, r), .Ok
}

@(private)
big_from_double :: proc(h: ^Heap, f: f64) -> (res: Value, status: Status) {
	buf: [400]u8
	s := strconv.write_float(buf[:], f, 'f', 0, 64, {})
	return big_from_text(h, s)
}

// The order of numbers `a` and `b` by value: -1, 0 or 1. NaN is below every other number and equal to NaN.
compare_numbers :: proc(a, b: Value) -> int {
	if a.kind == .Int && b.kind == .Int {
		return int(a.i > b.i) - int(a.i < b.i)
	}
	if a.kind == .Big || b.kind == .Big || a.kind == .Node || b.kind == .Node {
		return compare_wide(a, b)
	}
	return compare_mixed(as_scalar_number(a), as_scalar_number(b))
}

@(private)
Scalar_Number :: struct {
	i:      i64,
	f:      f64,
	is_int: bool,
}

@(private)
as_scalar_number :: #force_inline proc(v: Value) -> Scalar_Number {
	if v.kind == .Int {
		return {i = v.i, is_int = true}
	}
	return {f = as_f64(v)}
}

// The order of an integer or double against another, exact: an integer is never rounded to a double.
@(private)
compare_mixed :: proc(a, b: Scalar_Number) -> int {
	if a.is_int && b.is_int {
		return int(a.i > b.i) - int(a.i < b.i)
	}
	if !a.is_int && !b.is_int {
		an, bn := math.is_nan(a.f), math.is_nan(b.f)
		if an || bn {
			return int(bn) - int(an)
		}
		return int(a.f > b.f) - int(a.f < b.f)
	}
	if a.is_int {
		return -int_against_double(b.f, a.i)
	}
	return int_against_double(a.f, b.i)
}

// The order of double `f` against integer `i`.
@(private)
int_against_double :: proc(f: f64, i: i64) -> int {
	if math.is_nan(f) {
		return -1
	}
	if f >= TWO_63 {
		return 1
	}
	if f < -TWO_63 {
		return -1
	}
	t := math.trunc(f)
	ti := i64(t)
	if ti != i {
		return 1 if ti > i else -1
	}
	return int(f > t) - int(f < t)
}

// The order of numbers one of which is big or a document's.
@(private)
compare_wide :: proc(a, b: Value) -> int {
	x, y := settle(a), settle(b)
	if x.kind != .Big && y.kind != .Big {
		return compare_numbers(x, y)
	}
	if x.kind == .Big && y.kind == .Big {
		c, _ := big.int_compare(&(^Big_Block)(x.p).value, &(^Big_Block)(y.p).value)
		return c
	}
	if x.kind == .Big {
		return -compare_wide(y, x)
	}
	// `y` is big, past `i64` either way.
	neg := big_negative(y)
	if x.kind == .Int {
		return 1 if neg else -1
	}
	f := x.f
	if math.is_nan(f) {
		return -1
	}
	g := as_f64(y)
	if f != g {
		return int(f > g) - int(f < g)
	}
	// Equal as doubles: the double, an integer here, compared exactly.
	room: big.Int
	defer big.int_destroy(&room)
	buf: [400]u8
	s := strconv.write_float(buf[:], f, 'f', 0, 64, {})
	if big.int_atoi(&room, s, 10) != nil {
		return 0
	}
	c, _ := big.int_compare(&room, &(^Big_Block)(y.p).value)
	return c
}

// A document's number as a value with no block of its own where it fits one, for an order: an integer past `i64` stays
// its node, compared through its double, which only an exact peer could tell apart.
@(private)
settle :: proc(v: Value) -> Value {
	if v.kind != .Node {
		return v
	}
	if i, ok := as_i64(v); ok {
		return int_value(i)
	}
	return double_value(as_f64(v))
}

// Whether numbers `a` and `b` are equal by value. NaN equals nothing.
numbers_equal :: proc(a, b: Value) -> bool {
	if a.kind == .Int && b.kind == .Int {
		return a.i == b.i
	}
	if math.is_nan(as_f64(a)) || math.is_nan(as_f64(b)) {
		return false
	}
	return compare_numbers(a, b) == 0
}

// A hash of number `v` by value, so numbers `numbers_equal` holds for hash alike.
hash_number :: proc(v: Value) -> u64 {
	if i, ok := as_i64(v); ok {
		return mix64(u64(i))
	}
	if v.kind == .Big {
		x := &(^Big_Block)(v.p).value
		hash := u64(x.sign) + 1
		for d in x.digit[:x.used] {
			hash = mix64(hash ~ u64(d))
		}
		return hash
	}
	f := as_f64(v)
	if f == 0 {
		return mix64(0)
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

// The shortest decimal digits of finite double `f` that read back as it, and where the point goes: the value is
// `0.digits * 10^point`. `digits` is at most 17 bytes. `f` is not negative.
double_digits :: proc(f: f64, digits: ^[17]u8) -> (n: int, point: int) {
	buf: [32]u8
	s := strconv.write_float(buf[:], f, 'e', -1, 64, {})
	// `d.ddde±xx`
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

// Writes integer `v`, an `.Int` or `.Big`, in decimal to `out`.
write_integer :: proc(h: ^Heap, out: ^[dynamic]u8, v: Value) -> Status {
	if v.kind == .Int {
		buf: [24]u8
		s := strconv.write_int(buf[:], v.i, 10)
		if _, err := append(out, s); err != nil {
			return fail_memory(h)
		}
		return .Ok
	}
	s, err := big.int_itoa_string(&(^Big_Block)(v.p).value, 10, false, h.allocator)
	if err != nil {
		return fail_memory(h)
	}
	defer delete(s, h.allocator)
	if _, e := append(out, s); e != nil {
		return fail_memory(h)
	}
	return .Ok
}

// The number a decimal text spells, `.Int` or `.Big` for an integer and `.Double` for the rest, and whether the whole
// text is one: RFC 8259's grammar, or with `loose` a leading `+`, a point with no digit on one side, and `nan`,
// `infinity` and `inf` in any case.
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
		return number_of_spelled(h, n, text)
	}
	f, nr, good := strconv.parse_f64_prefix(text)
	if nr != len(text) {
		return NULL, false, .Ok
	}
	if !good {
		// An exponent past a double's range reads as infinity or zero.
		f = wide_double(b)
	}
	if integer_text(text) {
		x, s := big_from_text(h, text[1:] if text[0] == '+' else text)
		return x, s == .Ok, s
	}
	return double_value(f), true, .Ok
}

@(private)
number_of_spelled :: proc(h: ^Heap, n: spell.Number, text: string) -> (Value, bool, Status) {
	switch n.kind {
	case .Int:
		if integer_text(text) {
			return int_value(i64(n.bits)), true, .Ok
		}
		return double_value(f64(i64(n.bits))), true, .Ok
	case .Uint, .Float, .Wide:
		if integer_text(text) {
			x, s := big_from_text(h, text)
			return x, s == .Ok, s
		}
		if n.kind == .Wide {
			return double_value(wide_double(transmute([]u8)text)), true, .Ok
		}
		if n.kind == .Uint {
			return double_value(f64(n.bits)), true, .Ok
		}
		return double_value(transmute(f64)n.bits), true, .Ok
	}
	return NULL, false, .Ok
}

// Whether `s` is an optional sign and digits only.
@(private)
integer_text :: proc(s: string) -> bool {
	i := 0
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		i = 1
	}
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

// 2^63, the first double past `i64`.
@(private)
TWO_63 :: f64(9223372036854775808)
