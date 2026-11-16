package spell

// Number literals as exact decimals, for the checks that must not round: JSON Schema's bounds and `multipleOf`
// (`multiple.odin`), an enum's keys, and the numbers a schema writes.

import "core:strconv"
import "core:strings"

// The decimal 0.DIGITS × 10^point, where DIGITS is `head` then `tail`, with no leading or trailing zero. `head` and
// `tail` slice the literal on either side of its point, so nothing is copied. Zero has both "" and no sign.
//
// An exponent of more than `EXPONENT_DIGITS` digits does not fit `point`. `wide` then holds its digits and `wide_neg`
// its sign, and `point` only the place of the literal's own point, so the decimal is 0.DIGITS × 10^(±wide + point).
Decimal :: struct {
	neg:        bool,
	head, tail: string,
	point:      i128,
	wide:       string,
	wide_neg:   bool,
}

// The most digits an exponent `point` holds. Below 10^30 an exponent leaves `point` room in i128 for the place of the
// literal's point and for an offset below 2^64.
@(private)
EXPONENT_DIGITS :: 30

// `sum_order` reads the low `LOW_DIGITS` digits of a wide exponent as an i128. Two of them below 10^36 and an offset
// below 2^64 still sum inside i128.
@(private)
LOW_DIGITS :: 36
@(private)
LOW_SCALE :: i128(1e36)

// `write_decimal` writes plain digits while they need at most this many zeros beside them. The bound is a layout
// choice, not a limit.
@(private)
PLAIN_ZEROS :: 20

// The decimal the number literal `text` spells: an optional sign, digits with an optional point, and an optional
// exponent. The literal is not checked.
decimal_of :: proc(text: string) -> (d: Decimal) {
	number := text
	if len(number) > 0 && (number[0] == '-' || number[0] == '+') {
		d.neg, number = number[0] == '-', number[1:]
	}
	exp_neg: bool
	exp_digits: string
	if e := strings.index_any(number, "eE"); e >= 0 {
		exp_neg, exp_digits = exponent_of(number[e + 1:])
		number = number[:e]
	}
	whole, fraction := number, ""
	if dot := strings.index_byte(number, '.'); dot >= 0 {
		whole, fraction = number[:dot], number[dot + 1:]
	}
	// `skipped` counts the zeros dropped in front of the first significant digit.
	head := strings.trim_left(whole, "0")
	tail := fraction
	skipped := len(whole) - len(head)
	if head == "" {
		significant := strings.trim_left(tail, "0")
		skipped += len(tail) - len(significant)
		head = strings.trim_right(significant, "0")
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

// The sign of the exponent at the start of `text`, and its digits without leading zeros.
@(private)
exponent_of :: proc(text: string) -> (neg: bool, digits: string) {
	start := 0
	if len(text) > 0 && (text[0] == '-' || text[0] == '+') {
		neg, start = text[0] == '-', 1
	}
	end := start
	for end < len(text) && '0' <= text[end] && text[end] <= '9' {
		end += 1
	}
	return neg, strings.trim_left(text[start:end], "0")
}

// The value of up to 38 digits.
@(private)
digits_value :: proc "contextless" (digits: string) -> (n: i128) {
	for c in transmute([]u8)digits {
		n = n * 10 + i128(c - '0')
	}
	return
}

// The order of `x` and `y` as -1, 0 or 1. `1.0` equals `1`, and `-1e-400` is below `0`.
decimal_compare :: proc(x, y: Decimal) -> int {
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

// The order of the digits of two decimals, read from the first.
@(private)
digits_order :: proc(x, y: Decimal) -> int {
	nx, ny := len(x.head) + len(x.tail), len(y.head) + len(y.tail)
	for i in 0 ..< min(nx, ny) {
		if cx, cy := digit_at(x, i), digit_at(y, i); cx != cy {
			return -1 if cx < cy else 1
		}
	}
	return sign_of(i128(nx - ny))
}

// Digit `i` of `head` then `tail`, as its ASCII byte.
@(private)
digit_at :: proc "contextless" (d: Decimal, i: int) -> u8 {
	return d.head[i] if i < len(d.head) else d.tail[i - len(d.head)]
}

// The order of `x.point + k` and `y.point`, for a `k` below 2^64 in magnitude.
@(private)
point_order :: proc(x, y: Decimal, k: i128 = 0) -> int {
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
@(private)
sum_order :: proc(a: string, ta: i128, b: string, tb: i128) -> int {
	high_a, low_a := split_low(a)
	high_b, low_b := split_low(b)
	k := tb - ta
	// a - b - k = (high_a - high_b) × 10^36 + low_a - low_b - k, and low_a - low_b - k is below 2 × 10^36 in magnitude.
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
	// a + 1 adds one to the last digit below 9 and turns the 9s after it into 0s.
	i := len(a) - 1
	for i >= 0 && a[i] == '9' {
		i -= 1
	}
	if i < 0 {
		return len(b) == len(a) + 1 && b[0] == '1' && strings.trim_left(b[1:], "0") == ""
	}
	return len(b) == len(a) && a[:i] == b[:i] && b[i] == a[i] + 1 && strings.trim_left(b[i + 1:], "0") == ""
}

@(private)
sign_of :: proc "contextless" (n: i128) -> int {
	return -1 if n < 0 else (1 if n > 0 else 0)
}

// Writes `d` as a JSON number: in plain digits when that takes at most `PLAIN_ZEROS` zeros beside them, else as one
// digit, the rest after a point, and an exponent.
write_decimal :: proc(b: ^strings.Builder, d: Decimal) {
	if d.head == "" {
		strings.write_byte(b, '0')
		return
	}
	if d.neg {
		strings.write_byte(b, '-')
	}
	digits := strings.concatenate({d.head, d.tail}, context.temp_allocator)
	n := i128(len(digits))
	if d.wide == "" && -PLAIN_ZEROS <= d.point && d.point <= n + PLAIN_ZEROS {
		switch {
		case d.point <= 0:
			strings.write_string(b, "0.")
			strings.write_string(b, strings.repeat("0", int(-d.point), context.temp_allocator))
			strings.write_string(b, digits)
		case d.point >= n:
			strings.write_string(b, digits)
			strings.write_string(b, strings.repeat("0", int(d.point - n), context.temp_allocator))
		case:
			strings.write_string(b, digits[:d.point])
			strings.write_byte(b, '.')
			strings.write_string(b, digits[d.point:])
		}
		return
	}
	strings.write_byte(b, digits[0])
	if n > 1 {
		strings.write_byte(b, '.')
		strings.write_string(b, digits[1:])
	}
	strings.write_byte(b, 'e')
	write_point(b, d, -1)
}

// Writes `d.point + offset` as a signed integer, whether `point` or `wide` holds the exponent. `offset` is below 2^63
// in magnitude.
write_point :: proc(b: ^strings.Builder, d: Decimal, offset: i128 = 0) {
	if d.wide == "" {
		buf: [41]u8
		point := u128(d.point + offset)
		strings.write_string(b, strconv.write_bits_128(buf[:], point, 10, true, 128, strconv.digits, {}))
		return
	}
	// The wide exponent outweighs the rest, so the sign is its own, and its digits are moved by the rest in place.
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
	for b.buf[start] == '0' {
		ordered_remove(&b.buf, start)
	}
}
