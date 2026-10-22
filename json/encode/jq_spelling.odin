package encode

// jq's number notation, shared by the command line and `Encode_Opts.jq_spelling`: a literal as decNumber's
// scientific string (`1e2` is `1E+2`), a computed number as jq's dtoa lays it out.

import "core:math"
import "core:strconv"
import "core:strings"
import number "../scan/number"

// A number literal as a decimal: 0.(head ++ tail) × 10^point, without leading or trailing zeros.
// `head` and `tail` slice the literal on either side of its `.`, so no buffer is allocated.
Decimal :: struct {
	neg:        bool,
	head, tail: string, // both "" for zero
	point:      int,
}

decimal_of :: proc(lit: string) -> Decimal {
	d: Decimal
	s := lit
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		d.neg, s = s[0] == '-', s[1:]
	}
	exp := 0
	if i := strings.index_any(s, "eE"); i >= 0 {
		exp = literal_exponent(s[i + 1:])
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
	d.point = len(int_s) + exp - lead
	d.neg = d.neg && head != ""
	return d
}

// The exponent field of a literal, the text after its `e`, as the library's lexer reads it: it saturates at
// 2^31 however many digits it has, where a plain parse would wrap.
literal_exponent :: proc(field: string) -> int {
	i := 0
	neg := len(field) > 0 && field[0] == '-'
	if len(field) > 0 && (field[0] == '-' || field[0] == '+') {
		i = 1
	}
	e := 0
	for ; i < len(field) && '0' <= field[i] && field[i] <= '9'; i += 1 {
		e = min(e * 10 + int(field[i] - '0'), int(number.EXP_SATURATED))
	}
	return -e if neg else e
}

// decNumber's range for a nonzero literal, which jv_number_with_literal keeps a number's text inside: past
// an adjusted exponent of 999999999 the number is an overflow and keeps no literal (it prints as a double).
// Below -1147483646 it is a zero of that exponent.
bounded_literal :: proc(lit: string) -> string {
	if strings.index_any(lit, "eE") < 0 {
		return lit
	}
	d := decimal_of(lit)
	switch {
	case d.head == "":
	case d.point - 1 > 999999999:
		return ""
	case d.point - 1 < -1147483646:
		return "-0E-1147483646" if d.neg else "0E-1147483646"
	}
	return lit
}

// A literal in decNumber's scientific string, which jq 1.8 prints an unchanged number as: its digits
// with leading zeros dropped, in plain notation unless the exponent is positive or the number is below
// 1e-6 (`1e2` is `1E+2`, `0.1e1` is `1`, `1.000` stays `1.000`).
put_jq_literal :: proc(out: ^[dynamic]byte, lit: string) {
	if plain_literal(lit) {
		append(out, lit)
		return
	}
	// Only an exponent can take a literal past decNumber's range, and jq prints an overflow as its double.
	if bounded := bounded_literal(lit); bounded != lit {
		if bounded == "" {
			f, _ := strconv.parse_f64(lit)
			put_jq_double(out, f)
		} else {
			append(out, bounded)
		}
		return
	}
	s := lit
	neg := false
	if len(s) > 0 && s[0] == '-' {
		neg = true
		s = s[1:]
	}
	exp := 0
	if e := strings.index_any(s, "eE"); e >= 0 {
		exp = literal_exponent(s[e + 1:])
		s = s[:e]
	}
	int_s, frac_s := s, ""
	if dot := strings.index_byte(s, '.'); dot >= 0 {
		int_s, frac_s = s[:dot], s[dot + 1:]
		exp -= len(frac_s)
	}
	head := strings.trim_left(int_s, "0")
	tail := frac_s
	if head == "" {
		head = strings.trim_left(tail, "0")
		tail = ""
	}
	if head == "" {
		head = "0"
	}
	nd := len(head) + len(tail)
	if neg {
		append(out, '-')
	}
	adjusted := exp + nd - 1
	if exp <= 0 && adjusted >= -6 {
		place_point_parts(out, head, tail, nd + exp)
		return
	}
	append(out, head[0])
	if nd > 1 {
		append(out, '.')
		append(out, head[1:])
		append(out, tail)
	}
	append(out, 'E', '+' if adjusted >= 0 else '-')
	buf: [24]byte
	append(out, strconv.write_int(buf[:], i64(abs(adjusted)), 10))
}

// Whether `lit` prints as itself: no exponent, not so small that it would take one, and no point or
// zero that decNumber drops (`.5`, `1.`, `012`).
plain_literal :: proc(lit: string) -> bool {
	t := lit[1:] if len(lit) > 0 && lit[0] == '-' else lit
	switch {
	case len(t) > 7 && t[:7] == "0.00000", t[0] == '.', t[len(t) - 1] == '.', len(t) > 1 && t[0] == '0' && '0' <= t[1] && t[1] <= '9':
		return false
	}
	return strings.index_any(t, "eE") < 0
}

// `digits` (`head ++ tail`) with a decimal point after `point` of them: none at or past the end, leading zeros before.
place_point :: proc(out: ^[dynamic]byte, digits: string, point: int) {
	place_point_parts(out, digits, "", point)
}

@(private = "file")
place_point_parts :: proc(out: ^[dynamic]byte, head, tail: string, point: int) {
	nd := len(head) + len(tail)
	switch {
	case point >= nd:
		append(out, head)
		append(out, tail)
		for _ in nd ..< point {
			append(out, '0')
		}
	case point <= 0:
		append(out, "0.")
		for _ in 0 ..< -point {
			append(out, '0')
		}
		append(out, head)
		append(out, tail)
	case point <= len(head):
		append(out, head[:point])
		append(out, '.')
		append(out, head[point:])
		append(out, tail)
	case:
		split := point - len(head)
		append(out, head)
		append(out, tail[:split])
		append(out, '.')
		append(out, tail[split:])
	}
}

// A computed number as jq's dtoa writes it: the library's shortest digits, then jq's
// plain-or-exponent layout: plain notation unless the point falls before the fourth leading zero or more
// than fifteen places past the digits. An infinity is the largest finite number of its sign.
put_jq_double :: proc(out: ^[dynamic]byte, f: f64) {
	if math.is_nan(f) {
		append(out, "null")
		return
	}
	if f == 0 {
		append(out, "-0" if math.sign_bit(f) else "0")
		return
	}
	g := math.copy_sign(math.F64_MAX, f) if math.is_inf(f) else f
	if g < 0 {
		append(out, '-')
	}
	buf: [F64_ROOM]byte
	nd, decpt := shortest_digits(&buf[0], g)
	d := string(buf[1:1 + nd])
	if decpt <= -4 || decpt > len(d) + 15 {
		append(out, d[0])
		if len(d) > 1 {
			append(out, '.')
			append(out, d[1:])
		}
		e := decpt - 1
		append(out, 'e', '+' if e >= 0 else '-')
		e = abs(e)
		if e < 10 {
			append(out, '0')
		}
		ebuf: [8]byte
		append(out, strconv.write_int(ebuf[:], i64(e), 10))
		return
	}
	place_point(out, d, decpt)
}

