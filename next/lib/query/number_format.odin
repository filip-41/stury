package query

import "core:math"
import "core:strconv"
import "core:strings"

// A number written by a printf-like format text.

@(private)
MOST_WIDTH :: 1000
@(private)
MOST_PRECISION :: 100

// Number `x` as text by the format text `spec`, `%[flags][width][.precision]conversion` between literal text (`%%` is a
// percent sign). The conversions are `d` (the number cut toward zero), `f` and `e`, the flags `,` (thousands
// separators), `0` (pad with zeros) and `-` (pad on the right). One conversion is in `spec`. `.Types` for a `spec` that
// is no string, `.Range` for a number that is not finite, and `.Parse` for a `spec` that does not read as above.
@(require_results)
number_format :: proc(h: ^Heap, x, spec: Value) -> (res: Value, status: Status) {
	if !is_text(spec) {
		return NULL, fail(h, .Types, .Number_Format, spec)
	}
	n := as_f64(x)
	if math.is_nan(n) || math.is_inf(n) {
		return NULL, fail(h, .Range, .Number_Format, x)
	}
	text := text_of(spec)
	out := make([dynamic]u8, 0, len(text) + 16, h.allocator)
	defer delete(out)
	converted := false
	for i := 0; i < len(text); i += 1 {
		if text[i] != '%' {
			append(&out, text[i])
			continue
		}
		if i + 1 < len(text) && text[i + 1] == '%' {
			append(&out, '%')
			i += 1
			continue
		}
		used, valid := write_conversion(&out, text[i + 1:], n)
		if !valid || converted {
			return NULL, fail(h, .Parse, .Number_Format, spec)
		}
		converted = true
		i += used
	}
	if !converted {
		return NULL, fail(h, .Parse, .Number_Format, spec)
	}
	return text_value(h, string(out[:]))
}

// The conversion `spec` starts with, after its `%`, written for `x` onto `out`, and the bytes it took.
@(private)
write_conversion :: proc(out: ^[dynamic]u8, spec: string, x: f64) -> (used: int, ok: bool) {
	thousands, zero_pad, left := false, false, false
	flags: for ; used < len(spec); used += 1 {
		switch spec[used] {
		case ',':
			thousands = true
		case '0':
			zero_pad = true
		case '-':
			left = true
		case:
			break flags
		}
	}
	width, precision := 0, 6
	for ; used < len(spec) && spec[used] >= '0' && spec[used] <= '9'; used += 1 {
		width = width * 10 + int(spec[used] - '0')
		if width > MOST_WIDTH {
			return 0, false
		}
	}
	if used < len(spec) && spec[used] == '.' {
		used += 1
		precision = 0
		for ; used < len(spec) && spec[used] >= '0' && spec[used] <= '9'; used += 1 {
			precision = precision * 10 + int(spec[used] - '0')
			if precision > MOST_PRECISION {
				return 0, false
			}
		}
	}
	if used >= len(spec) {
		return 0, false
	}
	conversion := spec[used]
	used += 1
	spelled: [512]u8
	text: string
	switch conversion {
	case 'd':
		text = strconv.write_float(spelled[:], math.trunc(x), 'f', 0, 64)
	case 'f':
		text = strconv.write_float(spelled[:], x, 'f', precision, 64)
	case 'e':
		text = strconv.write_float(spelled[:], x, 'e', precision, 64)
	case:
		return 0, false
	}
	// `write_float` leads with the sign.
	negative := text[0] == '-'
	text = text[1:]
	if conversion == 'd' && text == "0" {
		negative = false
	}
	sign := "-" if negative else ""
	grouped: [dynamic]u8
	defer delete(grouped)
	if thousands && conversion != 'e' {
		whole := text[:strings.index_byte(text, '.')] if strings.contains_rune(text, '.') else text
		for c, k in transmute([]u8)whole {
			if k > 0 && (len(whole) - k) % 3 == 0 {
				append(&grouped, ',')
			}
			append(&grouped, c)
		}
		append(&grouped, text[len(whole):])
		text = string(grouped[:])
	}
	pad := max(0, width - len(sign) - len(text))
	switch {
	case left:
		append(out, sign)
		append(out, text)
		for _ in 0 ..< pad {
			append(out, ' ')
		}
	case zero_pad:
		append(out, sign)
		for _ in 0 ..< pad {
			append(out, '0')
		}
		append(out, text)
	case:
		for _ in 0 ..< pad {
			append(out, ' ')
		}
		append(out, sign)
		append(out, text)
	}
	return used, true
}
