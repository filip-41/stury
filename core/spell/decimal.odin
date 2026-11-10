package spell

import "core:strings"

// A number literal as an exact decimal: 0.(head ++ tail) × 10^point, without leading or trailing zeros. `head` and
// `tail` slice the literal on either side of its `.`, so no buffer is allocated. Both are "" for zero, which has no sign.
// `saturated` marks an exponent past 2^100, which `point` holds as 2^100.
Decimal :: struct {
	neg:        bool,
	saturated:  bool,
	head, tail: string,
	point:      i128,
}

// The decimal that the JSON number `lit` spells. An exponent of more than 30 digits saturates.
decimal_of :: proc(lit: string) -> (d: Decimal) {
	s := lit
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		d.neg, s = s[0] == '-', s[1:]
	}
	exp := i128(0)
	if i := strings.index_any(s, "eE"); i >= 0 {
		exp, d.saturated = exponent_field(s[i + 1:])
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
	d.point = i128(len(int_s) - lead) + exp
	d.neg = d.neg && head != ""
	return
}

@(private)
EXPONENT_MAX :: i128(1) << 100

@(private)
exponent_field :: proc(field: string) -> (e: i128, saturated: bool) {
	i := 0
	neg := len(field) > 0 && field[0] == '-'
	if len(field) > 0 && (field[0] == '-' || field[0] == '+') {
		i = 1
	}
	for ; i < len(field) && '0' <= field[i] && field[i] <= '9'; i += 1 {
		e = e * 10 + i128(field[i] - '0')
		if e >= EXPONENT_MAX {
			e, saturated = EXPONENT_MAX, true
		}
	}
	return (-e if neg else e), saturated
}

// The order of two decimals (-1 to 1): `1.0` equals `1`, and `-1e-400` is below `0`. `exact` is false when an exponent
// saturated, where the order may be wrong.
decimal_compare :: proc(x, y: Decimal) -> (order: int, exact: bool) {
	exact = !x.saturated && !y.saturated
	if x.neg != y.neg {
		return -1 if x.neg else 1, exact
	}
	mag: int
	switch {
	case x.head == "" || y.head == "":
		mag = int(x.head != "") - int(y.head != "")
	case x.point != y.point:
		mag = -1 if x.point < y.point else 1
	case:
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
	return -mag if x.neg else mag, exact
}

// The most digits a divisor may have for the u128 route of `decimal_multiple_of`, whose square a u128 holds.
MULTIPLE_DIGITS :: 19

// Whether `x` is a whole multiple of `y`, for a `y` of at most `MULTIPLE_DIGITS` digits. `exact` is false for a longer
// one, which this does not judge. The digits are taken modulo `y` and the power of ten by squaring, so exponents as far apart as `1e400`
// and `1e-400` cost no more than their width. Zero is a multiple of everything and a multiple of nothing but zero.
decimal_multiple_of :: proc(x, y: Decimal) -> (multiple, exact: bool) {
	ny := len(y.head) + len(y.tail)
	switch {
	case x.saturated || y.saturated:
		return false, false
	case y.head == "":
		return x.head == "", true
	case x.head == "":
		return true, true
	case ny > LONG_DIVISOR_DIGITS:
		return false, false
	}
	// Neither has a trailing zero, so a `y` that ends below `x` leaves a fraction.
	ex, ey := x.point - i128(len(x.head) + len(x.tail)), y.point - i128(ny)
	if ex < ey {
		return false, true
	}
	if ny > MULTIPLE_DIGITS {
		return long_multiple_of(x, y, ex - ey)
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
	for k := ex - ey; k > 0; k >>= 1 {
		if k & 1 != 0 {
			pow = pow * base % m
		}
		base = base * base % m
	}
	return r * pow % m == 0, true
}

// The most digits a divisor that `long_multiple_of` takes may have, and the most zeros it appends to the dividend.
LONG_DIVISOR_DIGITS :: 200
LONG_SHIFT_DIGITS :: 400

// `decimal_multiple_of` for a divisor of more than `MULTIPLE_DIGITS` digits: the remainder of the dividend's digits
// followed by `shift` zeros, by long division in decimal. The remainder never has more digits than the divisor.
@(private = "file")
long_multiple_of :: proc(x, y: Decimal, shift: i128) -> (multiple, exact: bool) {
	if shift > LONG_SHIFT_DIGITS {
		return false, false
	}
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
