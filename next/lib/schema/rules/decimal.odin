package rules

// Number literals as exact decimals, for the checks that must not round: JSON Schema's bounds and `multipleOf`,
// an enum's keys, exact numeric equality/hashing, and the numbers a schema writes.

import "base:runtime"
import "core:strconv"
import "core:strings"

// Whether `s` is syntactically a finite decimal number (`[-+]?digits(.digits)?([eE][-+]?digits)?`,
// or JSON5 `.digits` / `digits.`). Rejects empty strings, `NaN`, `Inf`, hex, and garbage.
valid_decimal_text :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	i := 0
	if s[i] == '-' || s[i] == '+' {
		i += 1
		if i >= len(s) {
			return false
		}
	}
	int_digits := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		int_digits += 1
		i += 1
	}
	frac_digits := 0
	if i < len(s) && s[i] == '.' {
		i += 1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			frac_digits += 1
			i += 1
		}
	}
	if int_digits == 0 && frac_digits == 0 {
		return false
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i += 1
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i += 1
		}
		exp_digits := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			exp_digits += 1
			i += 1
		}
		if exp_digits == 0 {
			return false
		}
	}
	return i == len(s)
}

// Normalizes a TOML/JSON5 decimal literal (stripping `_` and leading `+`, normalizing leading/trailing `.`
// like `.5` -> `0.5` and `5.` -> `5`) into `buf` (or `allocator` if longer). False if not a valid decimal.
normalize_decimal_text :: proc(s: string, buf: []u8, allocator: runtime.Allocator) -> (out: string, owned, ok: bool) {
	if len(s) == 0 {
		return "", false, false
	}
	need := len(s) + 2
	dst := buf
	heap := false
	if need > len(buf) {
		raw, err := make([]u8, need, allocator)
		if err != nil {
			return "", false, false
		}
		dst = raw
		heap = true
	}
	n := 0
	i := 0
	if s[i] == '+' {
		i += 1
	} else if s[i] == '-' {
		dst[n] = '-'
		n += 1
		i += 1
	}
	if i < len(s) && s[i] == '.' {
		dst[n] = '0'
		n += 1
	}
	for ; i < len(s); i += 1 {
		c := s[i]
		if c == '_' {
			continue
		}
		dst[n] = c
		n += 1
	}
	if n > 0 && dst[n - 1] == '.' {
		n -= 1
	}
	res := string(dst[:n])
	if !valid_decimal_text(res) {
		if heap {
			delete(dst, allocator)
		}
		return "", false, false
	}
	if heap {
		if n == len(dst) {
			return res, true, true
		}
		cp, cerr := strings.clone(res, allocator)
		delete(dst, allocator)
		if cerr != nil {
			return "", false, false
		}
		return cp, true, true
	}
	return res, false, true
}

// The decimal 0.DIGITS * 10^point, where DIGITS is `head` then `tail`, with no leading or trailing zero. `head` and
// `tail` slice the literal on either side of its point, so nothing is copied. Zero has both "" and no sign.
//
// An exponent of more than `EXPONENT_DIGITS` digits does not fit `point`. `wide` then holds its digits and `wide_neg`
// its sign, and `point` only the place of the literal's own point, so the decimal is 0.DIGITS * 10^(±wide + point).
Decimal :: struct {
	neg:        bool,
	head, tail: string,
	point:      i128,
	wide:       string,
	wide_neg:   bool,
}

// The most digits an exponent `point` holds. Below 10^30 an exponent leaves `point` room in i128 for the place of the
// literal's point and for an offset below 2^64.
@(private = "file")
EXPONENT_DIGITS :: 30

// `sum_order` reads the low `LOW_DIGITS` digits of a wide exponent as an i128. Two of them below 10^36 and an offset
// below 2^64 still sum inside i128.
@(private = "file")
LOW_DIGITS :: 36
@(private = "file")
LOW_SCALE :: i128(1e36)

// `write_decimal` writes plain digits while they need at most this many zeros beside them.
@(private = "file")
PLAIN_ZEROS :: 20

// The most digits a divisor `decimal_multiple_of` judges may have.
@(private = "file")
LONG_DIVISOR_DIGITS :: 200

// A divisor of up to this many digits is judged in u128, which holds the square of anything below it.
@(private = "file")
MULTIPLE_DIGITS :: 19

// A divisor below 10^200 has powers of 2 and of 5 below 665 each, so 10^700 holds every factor of ten it can use.
@(private = "file")
MULTIPLE_SHIFT :: 700

// The decimal the number literal `text` spells: an optional sign, digits with an optional point, and an optional
// exponent. The literal is not checked.
decimal_of :: proc "contextless" (text: string) -> (d: Decimal) {
	number := text
	if len(number) > 0 && (number[0] == '-' || number[0] == '+') {
		d.neg, number = number[0] == '-', number[1:]
	}
	exp_neg: bool
	exp_digits: string
	if e := index_exp(number); e >= 0 {
		exp_neg, exp_digits = exponent_of(number[e + 1:])
		number = number[:e]
	}
	whole, fraction := number, ""
	if dot := index_dot(number); dot >= 0 {
		whole, fraction = number[:dot], number[dot + 1:]
	}
	// `skipped` counts the zeros dropped in front of the first significant digit.
	head := trim_left_zero(whole)
	tail := fraction
	skipped := len(whole) - len(head)
	if head == "" {
		significant := trim_left_zero(tail)
		skipped += len(tail) - len(significant)
		head = trim_right_zero(significant)
		tail = ""
	} else {
		tail = trim_right_zero(tail)
		if tail == "" {
			head = trim_right_zero(head)
		}
	}
	d.head, d.tail = head, tail
	d.neg = d.neg && head != ""
	if head != "" {
		point := i128(len(whole) - skipped)
		if len(exp_digits) > EXPONENT_DIGITS {
			d.point, d.wide, d.wide_neg = point, exp_digits, exp_neg
		} else {
			e := digits_value(exp_digits)
			d.point = point - e if exp_neg else point + e
		}
	}
	return
}

@(private = "file")
index_exp :: proc "contextless" (s: string) -> int {
	for i in 0 ..< len(s) {
		if s[i] == 'e' || s[i] == 'E' {
			return i
		}
	}
	return -1
}

@(private = "file")
index_dot :: proc "contextless" (s: string) -> int {
	for i in 0 ..< len(s) {
		if s[i] == '.' {
			return i
		}
	}
	return -1
}

@(private = "file")
trim_left_zero :: proc "contextless" (s: string) -> string {
	i := 0
	for i < len(s) && s[i] == '0' {
		i += 1
	}
	return s[i:]
}

@(private = "file")
trim_right_zero :: proc "contextless" (s: string) -> string {
	n := len(s)
	for n > 0 && s[n - 1] == '0' {
		n -= 1
	}
	return s[:n]
}

// The sign of the exponent at the start of `text`, and its digits without leading zeros.
@(private = "file")
exponent_of :: proc "contextless" (text: string) -> (neg: bool, digits: string) {
	start := 0
	if len(text) > 0 && (text[0] == '-' || text[0] == '+') {
		neg, start = text[0] == '-', 1
	}
	end := start
	for end < len(text) && '0' <= text[end] && text[end] <= '9' {
		end += 1
	}
	return neg, trim_left_zero(text[start:end])
}

// The value of up to 38 digits.
@(private = "file")
digits_value :: proc "contextless" (digits: string) -> (n: i128) {
	for c in transmute([]u8)digits {
		n = n * 10 + i128(c - '0')
	}
	return
}

// The order of `x` and `y` as -1, 0 or 1. `1.0` equals `1`, and `-1e-400` is below `0`.
decimal_compare :: proc "contextless" (x, y: Decimal) -> int {
	if x.neg != y.neg {
		return -1 if x.neg else 1
	}
	// The order of the magnitudes: a zero first, then the point, then the digits.
	order := int(x.head != "") - int(y.head != "")
	if x.head != "" && y.head != "" {
		order = point_order(x, y)
		if order == 0 {
			order = digits_order(x, y)
		}
	}
	return -order if x.neg else order
}

// The i64 an integral decimal holds, false for a fraction and past an i64.
decimal_i64 :: proc "contextless" (d: Decimal) -> (v: i64, ok: bool) {
	digits := len(d.head) + len(d.tail)
	if d.head == "" {
		return 0, true
	}
	if d.wide != "" || d.point < i128(digits) || d.point > 19 {
		return 0, false
	}
	m := u128(0)
	for s in ([2]string{d.head, d.tail}) {
		for c in transmute([]u8)s {
			m = m * 10 + u128(c - '0')
		}
	}
	for _ in digits ..< int(d.point) {
		m *= 10
	}
	if m > u128(max(i64)) + (1 if d.neg else 0) {
		return 0, false
	}
	if d.neg {
		if m == u128(max(i64)) + 1 {
			return min(i64), true
		}
		return -i64(m), true
	}
	return i64(m), true
}

// Whether a number is an integer: zero, or a decimal with no digit past its point.
integral :: proc "contextless" (d: Decimal) -> bool {
	if d.wide != "" {
		return !d.wide_neg
	}
	return d.head == "" || d.point >= i128(len(d.head) + len(d.tail))
}

// The order of the digits of two decimals, read from the first.
@(private = "file")
digits_order :: proc "contextless" (x, y: Decimal) -> int {
	nx, ny := len(x.head) + len(x.tail), len(y.head) + len(y.tail)
	for i in 0 ..< min(nx, ny) {
		if cx, cy := digit_at(x, i), digit_at(y, i); cx != cy {
			return -1 if cx < cy else 1
		}
	}
	return sign_of(i128(nx - ny))
}

// Digit `i` of `head` then `tail`, as its ASCII byte.
@(private = "file")
digit_at :: proc "contextless" (d: Decimal, i: int) -> u8 {
	return d.head[i] if i < len(d.head) else d.tail[i - len(d.head)]
}

// The order of `x.point + k` and `y.point`, for a `k` below 2^64 in magnitude.
@(private = "file")
point_order :: proc "contextless" (x, y: Decimal, k: i128 = 0) -> int {
	switch {
	case x.wide == "" && y.wide == "":
		return sign_of(x.point + k - y.point)
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
@(private = "file")
sum_order :: proc "contextless" (a: string, ta: i128, b: string, tb: i128) -> int {
	high_a, low_a := split_low(a)
	high_b, low_b := split_low(b)
	k := tb - ta
	switch high := compare_digits(high_a, high_b); {
	case high == 0:
		return sign_of(low_a - low_b - k)
	case high < 0:
		return sign_of(low_a - low_b - k - LOW_SCALE) if next_digits(high_a, high_b) else -1
	case:
		return sign_of(low_a - low_b - k + LOW_SCALE) if next_digits(high_b, high_a) else 1
	}
}

// `digits` split before its low `LOW_DIGITS` digits, and the value of those.
@(private = "file")
split_low :: proc "contextless" (digits: string) -> (high: string, low: i128) {
	cut := max(len(digits) - LOW_DIGITS, 0)
	return digits[:cut], digits_value(digits[cut:])
}

// The order of two digit strings without leading zeros.
@(private = "file")
compare_digits :: proc "contextless" (a, b: string) -> int {
	if len(a) != len(b) {
		return -1 if len(a) < len(b) else 1
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return -1 if a[i] < b[i] else 1
		}
	}
	return 0
}

// Whether `b` is `a + 1`, for digit strings without leading zeros, "" being zero.
@(private = "file")
next_digits :: proc "contextless" (a, b: string) -> bool {
	i := len(a) - 1
	for i >= 0 && a[i] == '9' {
		i -= 1
	}
	if i < 0 {
		return len(b) == len(a) + 1 && b[0] == '1' && trim_left_zero(b[1:]) == ""
	}
	return len(b) == len(a) && a[:i] == b[:i] && b[i] == a[i] + 1 && trim_left_zero(b[i + 1:]) == ""
}

@(private = "file")
sign_of :: proc "contextless" (n: i128) -> int {
	return -1 if n < 0 else (1 if n > 0 else 0)
}

// Writes `d` as a JSON number directly into `b` without temporary allocations.
write_decimal :: proc(b: ^strings.Builder, d: Decimal) {
	if d.head == "" {
		strings.write_byte(b, '0')
		return
	}
	if d.neg {
		strings.write_byte(b, '-')
	}
	n := i128(len(d.head) + len(d.tail))
	if d.wide == "" && -PLAIN_ZEROS <= d.point && d.point <= n + PLAIN_ZEROS {
		switch {
		case d.point <= 0:
			strings.write_string(b, "0.")
			for _ in 0 ..< int(-d.point) {
				strings.write_byte(b, '0')
			}
			strings.write_string(b, d.head)
			strings.write_string(b, d.tail)
		case d.point >= n:
			strings.write_string(b, d.head)
			strings.write_string(b, d.tail)
			for _ in 0 ..< int(d.point - n) {
				strings.write_byte(b, '0')
			}
		case:
			p := int(d.point)
			if p <= len(d.head) {
				strings.write_string(b, d.head[:p])
				strings.write_byte(b, '.')
				strings.write_string(b, d.head[p:])
				strings.write_string(b, d.tail)
			} else {
				tail_split := p - len(d.head)
				strings.write_string(b, d.head)
				strings.write_string(b, d.tail[:tail_split])
				strings.write_byte(b, '.')
				strings.write_string(b, d.tail[tail_split:])
			}
		}
		return
	}
	strings.write_byte(b, d.head[0])
	if n > 1 {
		strings.write_byte(b, '.')
		strings.write_string(b, d.head[1:])
		strings.write_string(b, d.tail)
	}
	strings.write_byte(b, 'e')
	write_point(b, d, -1)
}

// Writes `d.point + offset` as a signed integer, whether `point` or `wide` holds the exponent.
write_point :: proc(b: ^strings.Builder, d: Decimal, offset: i128 = 0) {
	if d.wide == "" {
		buf: [41]u8
		point := u128(d.point + offset)
		strings.write_string(b, strconv.write_bits_128(buf[:], point, 10, true, 128, strconv.digits, {}))
		return
	}
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
	left, add, carry := u128(abs(delta)), delta >= 0, 0
	for i := len(digits) - 1; i >= 0 && (left > 0 || carry != 0); i -= 1 {
		digit, step := int(digits[i] - '0'), int(left % 10)
		left /= 10
		if add {
			digit += step + carry
			carry = digit / 10
			digit %= 10
		} else {
			digit -= step + carry
			carry = 0
			if digit < 0 {
				digit, carry = digit + 10, 1
			}
		}
		digits[i] = u8('0' + digit)
	}
	if add && carry != 0 {
		inject_at(&b.buf, start, u8('1'))
	}
	for start < len(b.buf) && b.buf[start] == '0' {
		ordered_remove(&b.buf, start)
	}
}

// Whether `x` is a whole multiple of `y`. `exact` is false for a `y` that `divisor_judged` refuses. Zero is a multiple
// of everything and a multiple of nothing but zero.
decimal_multiple_of :: proc "contextless" (x, y: Decimal) -> (multiple, exact: bool) {
	nx, ny := len(x.head) + len(x.tail), len(y.head) + len(y.tail)
	switch {
	case y.head == "":
		return x.head == "", true
	case x.head == "":
		return true, true
	case !divisor_judged(y):
		return false, false
	}
	gap := i128(ny - nx)
	if point_order(x, y, gap) < 0 {
		return false, true
	}
	shift := MULTIPLE_SHIFT
	if point_order(x, y, gap - MULTIPLE_SHIFT) < 0 {
		e := digits_value(x.wide)
		shift = int(x.point + gap - y.point + (-e if x.wide_neg else e))
	}
	if ny > MULTIPLE_DIGITS {
		return long_multiple_of(x, y, shift)
	}
	divisor, remainder := u128(0), u128(0)
	for i in 0 ..< ny {
		divisor = divisor * 10 + u128(digit_at(y, i) - '0')
	}
	for i in 0 ..< nx {
		remainder = (remainder * 10 + u128(digit_at(x, i) - '0')) % divisor
	}
	power, square := u128(1) % divisor, u128(10) % divisor
	for k := shift; k > 0; k >>= 1 {
		if k & 1 != 0 {
			power = power * square % divisor
		}
		square = square * square % divisor
	}
	return remainder * power % divisor == 0, true
}

// Whether `decimal_multiple_of` judges the divisor `y`: one of at most `LONG_DIVISOR_DIGITS` digits without a wide
// exponent.
divisor_judged :: proc "contextless" (y: Decimal) -> bool {
	return y.wide == "" && len(y.head) + len(y.tail) <= LONG_DIVISOR_DIGITS
}

@(private = "file")
long_multiple_of :: proc "contextless" (x, y: Decimal, shift: int) -> (multiple, exact: bool) {
	width := len(y.head) + len(y.tail) + 1
	divisor, remainder: [LONG_DIVISOR_DIGITS + 1]u8
	for i in 1 ..< width {
		divisor[i] = digit_at(y, i - 1) - '0'
	}
	for i in 0 ..< len(x.head) + len(x.tail) {
		long_step(remainder[:width], divisor[:width], digit_at(x, i) - '0')
	}
	for _ in 0 ..< shift {
		long_step(remainder[:width], divisor[:width], 0)
	}
	for digit in remainder[:width] {
		if digit != 0 {
			return false, true
		}
	}
	return true, true
}

@(private = "file")
long_step :: proc "contextless" (remainder, divisor: []u8, digit: u8) {
	copy(remainder, remainder[1:])
	remainder[len(remainder) - 1] = digit
	for string(remainder) >= string(divisor) {
		borrow: i8
		for i := len(remainder) - 1; i >= 0; i -= 1 {
			d := i8(remainder[i]) - i8(divisor[i]) - borrow
			borrow = 0
			if d < 0 {
				d += 10
				borrow = 1
			}
			remainder[i] = u8(d)
		}
	}
}
