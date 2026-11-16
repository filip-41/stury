package spell

// Whether one decimal is a whole multiple of another, exactly and whatever the exponents, for JSON Schema's
// `multipleOf`.
//
// With X and Y the digits of `x` and `y`, x / y = X / Y × 10^shift, where shift = x.point - y.point + len(Y) - len(X).
// Neither X nor Y ends in a zero, so a negative shift leaves a fraction. Past `MULTIPLE_SHIFT` a power of ten adds no
// factor a divisor of at most `LONG_DIVISOR_DIGITS` digits lacks, so the shift is capped there and `1e400`, `1e-400`
// and an exponent of any width cost no more than their digits.

// The most digits a divisor `decimal_multiple_of` judges may have.
@(private)
LONG_DIVISOR_DIGITS :: 200

// A divisor of up to this many digits is judged in u128, which holds the square of anything below it.
@(private)
MULTIPLE_DIGITS :: 19

// A divisor below 10^200 has powers of 2 and of 5 below 665 each, so 10^700 holds every factor of ten it can use.
@(private)
MULTIPLE_SHIFT :: 700

// Whether `x` is a whole multiple of `y`. `exact` is false for a `y` that `divisor_judged` refuses. Zero is a multiple
// of everything and a multiple of nothing but zero.
decimal_multiple_of :: proc(x, y: Decimal) -> (multiple, exact: bool) {
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
		// The shift is below `MULTIPLE_SHIFT`, so a wide exponent of `x` is small enough to read.
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
	// 10^shift modulo the divisor, by squaring.
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

// `decimal_multiple_of` for a divisor of more than `MULTIPLE_DIGITS` digits, by long division in decimal: the remainder
// of X followed by `shift` zeros. Divisor and remainder are digit arrays one wider than the divisor, its first digit 0,
// so the remainder times ten plus a digit always fits.
@(private = "file")
long_multiple_of :: proc(x, y: Decimal, shift: int) -> (multiple, exact: bool) {
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

// Brings `digit` down into `remainder` and subtracts `divisor` while that leaves it nonnegative. Digit arrays of one
// width compare in order as strings.
@(private = "file")
long_step :: proc(remainder, divisor: []u8, digit: u8) {
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
