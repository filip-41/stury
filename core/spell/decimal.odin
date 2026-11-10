package spell

import "core:strings"

// A number literal as an exact decimal: 0.(head ++ tail) × 10^point, without leading or trailing zeros. `head` and
// `tail` slice the literal on either side of its `.`, and no buffer is allocated. Both are "" for zero, which has no
// sign. An exponent of more than `EXPONENT_DIGITS` digits does not fit `point`: `wide` then slices its digits, `wide_neg`
// is its sign, and `point` holds only the shift of the mantissa, so the decimal's point is `±wide + point`.
Decimal :: struct {
	neg:        bool,
	head, tail: string,
	point:      i128,
	wide:       string,
	wide_neg:   bool,
}

// The most digits an exponent may have to be summed into `Decimal.point`.
@(private)
EXPONENT_DIGITS :: 30

// The decimal that the JSON number `lit` spells, whatever the size of its exponent.
decimal_of :: proc(lit: string) -> (d: Decimal) {
	s := lit
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		d.neg, s = s[0] == '-', s[1:]
	}
	exp_neg: bool
	exp_digits: string
	if i := strings.index_any(s, "eE"); i >= 0 {
		exp_neg, exp_digits = exponent_field(s[i + 1:])
		s = s[:i]
	}
	int_s, frac_s := s, ""
	if dot := strings.index_byte(s, '.'); dot >= 0 {
		int_s, frac_s = s[:dot], s[dot + 1:]
	}
	head := strings.trim_left(int_s, "0")
	tail := frac_s
	lead := len(int_s) - len(head)
	if head == "" {
		trimmed := strings.trim_left(tail, "0")
		lead += len(tail) - len(trimmed)
		head = strings.trim_right(trimmed, "0")
		tail = ""
	} else {
		tail = strings.trim_right(tail, "0")
		if tail == "" {
			head = strings.trim_right(head, "0")
		}
	}
	d.head, d.tail = head, tail
	d.neg = d.neg && head != ""
	if head != "" {
		shift := i128(len(int_s) - lead)
		if len(exp_digits) > EXPONENT_DIGITS {
			d.point, d.wide, d.wide_neg = shift, exp_digits, exp_neg
		} else {
			e := digits_value(exp_digits)
			d.point = shift - e if exp_neg else shift + e
		}
	}
	return
}

// An exponent's sign and its digits without leading zeros, at the start of `field`: an optional sign, then digits.
@(private)
exponent_field :: proc(field: string) -> (neg: bool, digits: string) {
	i := 0
	if len(field) > 0 && (field[0] == '-' || field[0] == '+') {
		neg, i = field[0] == '-', 1
	}
	end := i
	for end < len(field) && '0' <= field[end] && field[end] <= '9' {
		end += 1
	}
	return neg, strings.trim_left(field[i:end], "0")
}

// The value of up to 38 digits.
@(private)
digits_value :: proc "contextless" (digits: string) -> (n: i128) {
	for c in transmute([]u8)digits {
		n = n * 10 + i128(c - '0')
	}
	return
}

// Writes to `b` the signed decimal text of the point of `d` plus `offset`, which is below 2^63 in magnitude, so a point
// that `wide` holds and one that `point` holds are written alike.
write_point :: proc(b: ^strings.Builder, d: Decimal, offset: i128 = 0) {
	if d.wide == "" {
		write_i128(b, d.point + offset)
		return
	}
	// The exponent dominates both the shift and the offset, so the magnitude is the exponent moved by them.
	if d.wide_neg {
		strings.write_byte(b, '-')
	}
	start := len(b.buf)
	strings.write_string(b, d.wide)
	delta := d.point + offset
	if d.wide_neg {
		delta = -delta
	}
	digits := b.buf[start:]
	rest, add, carry := u128(abs(delta)), delta >= 0, 0
	for i := len(digits) - 1; i >= 0 && (rest > 0 || carry != 0); i -= 1 {
		v, step := int(digits[i] - '0'), int(rest % 10)
		rest /= 10
		if add {
			v += step + carry
			carry = v / 10
			v %= 10
		} else {
			v -= step + carry
			carry = 0
			if v < 0 {
				v, carry = v + 10, 1
			}
		}
		digits[i] = u8('0' + v)
	}
	if add && carry != 0 {
		inject_at(&b.buf, start, u8('1'))
	}
	for b.buf[start] == '0' {
		ordered_remove(&b.buf, start)
	}
}

@(private)
write_i128 :: proc(b: ^strings.Builder, n: i128) {
	buf: [41]u8
	i := len(buf)
	for m := abs(n); m > 0 || i == len(buf); m /= 10 {
		i -= 1
		buf[i] = u8('0' + m % 10)
	}
	if n < 0 {
		i -= 1
		buf[i] = '-'
	}
	strings.write_string(b, string(buf[i:]))
}

// The digits of an exponent that `sum_order` splits off at the low end, and the scale they stand for.
@(private)
LOW_DIGITS :: 36
@(private)
LOW_SCALE :: i128(1e36)

// The order of `x.point + k` and `y.point`, for a `k` of magnitude below 2^64.
@(private)
point_order :: proc(x, y: Decimal, k: i128 = 0) -> int {
	switch {
	case x.wide == "" && y.wide == "":
		a, b := x.point + k, y.point
		return -1 if a < b else (1 if a > b else 0)
	case x.wide == "":
		return -point_order(y, x, -k)
	case y.wide != "" && x.wide_neg != y.wide_neg:
		return -1 if x.wide_neg else 1
	}
	t := x.point + k - y.point
	if x.wide_neg {
		return -sum_order(x.wide, -t, y.wide, 0)
	}
	return sum_order(x.wide, t, y.wide, 0)
}

// The order of the integers `a + ta` and `b + tb`, for the digits `a` and `b` without leading zeros.
@(private)
sum_order :: proc(a: string, ta: i128, b: string, tb: i128) -> int {
	ua, la := split_low(a)
	ub, lb := split_low(b)
	k := tb - ta
	// a - b - k = (ua - ub) * 10^36 + la - lb - k, and la - lb - k is below 2 * 10^36 in magnitude.
	switch c := compare_digits(ua, ub); {
	case c == 0:
		return sign_of(la - lb - k)
	case c < 0:
		return sign_of(la - lb - k - LOW_SCALE) if next_digits(ua, ub) else -1
	case:
		return sign_of(la - lb - k + LOW_SCALE) if next_digits(ub, ua) else 1
	}
}

@(private)
sign_of :: proc "contextless" (n: i128) -> int {
	return -1 if n < 0 else (1 if n > 0 else 0)
}

@(private)
split_low :: proc "contextless" (digits: string) -> (high: string, low: i128) {
	cut := max(len(digits) - LOW_DIGITS, 0)
	return digits[:cut], digits_value(digits[cut:])
}

// The order of two digit strings without leading zeros.
@(private)
compare_digits :: proc(a, b: string) -> int {
	if len(a) != len(b) {
		return -1 if len(a) < len(b) else 1
	}
	return strings.compare(a, b)
}

// Whether `b` is `a + 1`, for digit strings without leading zeros, "" being zero.
@(private)
next_digits :: proc(a, b: string) -> bool {
	i := len(a) - 1
	for i >= 0 && a[i] == '9' {
		i -= 1
	}
	zeros :: proc(s: string) -> bool {
		for c in transmute([]u8)s {
			if c != '0' {
				return false
			}
		}
		return true
	}
	if i < 0 {
		return len(b) == len(a) + 1 && b[0] == '1' && zeros(b[1:])
	}
	return len(b) == len(a) && a[:i] == b[:i] && b[i] == a[i] + 1 && zeros(b[i + 1:])
}

// The order of two decimals (-1 to 1): `1.0` equals `1`, and `-1e-400` is below `0`.
decimal_compare :: proc(x, y: Decimal) -> int {
	if x.neg != y.neg {
		return -1 if x.neg else 1
	}
	mag: int
	switch {
	case x.head == "" || y.head == "":
		mag = int(x.head != "") - int(y.head != "")
	case:
		mag = point_order(x, y)
		if mag != 0 {
			break
		}
		nx, ny := len(x.head) + len(x.tail), len(y.head) + len(y.tail)
		for i in 0 ..< min(nx, ny) {
			cx := x.head[i] if i < len(x.head) else x.tail[i - len(x.head)]
			cy := y.head[i] if i < len(y.head) else y.tail[i - len(y.head)]
			if cx != cy {
				mag = -1 if cx < cy else 1
				break
			}
		}
		if mag == 0 {
			mag = -1 if nx < ny else (1 if nx > ny else 0)
		}
	}
	return -mag if x.neg else mag
}

// The most digits a divisor may have for the u128 route of `decimal_multiple_of`, whose square a u128 holds.
MULTIPLE_DIGITS :: 19

// The most digits a divisor that `long_multiple_of` takes may have.
LONG_DIVISOR_DIGITS :: 200

// The shift past which a power of ten adds no factor to a divisor of at most `LONG_DIVISOR_DIGITS` digits, whose powers
// of 2 and of 5 are each below 665.
@(private)
MULTIPLE_SHIFT :: 700

// Whether `x` is a whole multiple of `y`, for a `y` of at most `LONG_DIVISOR_DIGITS` digits and an exponent that `point`
// holds. `exact` is false for any other `y`, which this does not judge. The digits are taken modulo `y` and the power of
// ten by squaring, and a power past `MULTIPLE_SHIFT` is that power, so `1e400` and `1e-400` and exponents of any width
// cost no more than their digits. Zero is a multiple of everything and a multiple of nothing but zero.
decimal_multiple_of :: proc(x, y: Decimal) -> (multiple, exact: bool) {
	nx, ny := len(x.head) + len(x.tail), len(y.head) + len(y.tail)
	switch {
	case y.head == "":
		return x.head == "", true
	case x.head == "":
		return true, true
	case y.wide != "" || ny > LONG_DIVISOR_DIGITS:
		return false, false
	}
	// Neither has a trailing zero, so a `y` that ends below `x` leaves a fraction.
	toward := i128(ny - nx)
	if point_order(x, y, toward) < 0 {
		return false, true
	}
	shift := MULTIPLE_SHIFT
	if point_order(x, y, toward - MULTIPLE_SHIFT) < 0 {
		// Between 0 and `MULTIPLE_SHIFT`, so an exponent that is wide is within reach of a held one.
		e := digits_value(x.wide)
		shift = int(x.point + toward - y.point + (-e if x.wide_neg else e))
	}
	if ny > MULTIPLE_DIGITS {
		return long_multiple_of(x, y, shift)
	}
	m, r := u128(0), u128(0)
	for s in ([2]string{y.head, y.tail}) {
		for c in transmute([]u8)s {
			m = m * 10 + u128(c - '0')
		}
	}
	for s in ([2]string{x.head, x.tail}) {
		for c in transmute([]u8)s {
			r = (r * 10 + u128(c - '0')) % m
		}
	}
	pow, base := u128(1) % m, u128(10) % m
	for k := shift; k > 0; k >>= 1 {
		if k & 1 != 0 {
			pow = pow * base % m
		}
		base = base * base % m
	}
	return r * pow % m == 0, true
}

// `decimal_multiple_of` for a divisor of more than `MULTIPLE_DIGITS` digits: the remainder of the dividend's digits
// followed by `shift` zeros, by long division in decimal. The remainder never has more digits than the divisor.
@(private = "file")
long_multiple_of :: proc(x, y: Decimal, shift: int) -> (multiple, exact: bool) {
	width := len(y.head) + len(y.tail) + 1
	m: [LONG_DIVISOR_DIGITS + 1]u8
	r: [LONG_DIVISOR_DIGITS + 1]u8
	at := 1
	for s in ([2]string{y.head, y.tail}) {
		for c in transmute([]u8)s {
			m[at] = c - '0'
			at += 1
		}
	}
	below :: proc(r, m: []u8) -> bool {
		for i in 0 ..< len(r) {
			if r[i] != m[i] {
				return r[i] < m[i]
			}
		}
		return false
	}
	step :: proc(r, m: []u8, digit: u8) {
		copy(r, r[1:])
		r[len(r) - 1] = digit
		for !below(r, m) {
			borrow: i8
			for i := len(r) - 1; i >= 0; i -= 1 {
				d := i8(r[i]) - i8(m[i]) - borrow
				borrow = 0
				if d < 0 {
					d += 10
					borrow = 1
				}
				r[i] = u8(d)
			}
		}
	}
	for s in ([2]string{x.head, x.tail}) {
		for c in transmute([]u8)s {
			step(r[:width], m[:width], c - '0')
		}
	}
	for _ in 0 ..< shift {
		step(r[:width], m[:width], 0)
	}
	for d in r[:width] {
		if d != 0 {
			return false, true
		}
	}
	return true, true
}
