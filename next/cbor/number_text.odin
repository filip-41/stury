package cbor

import "base:runtime"
import "core:strconv"
import "stury:lib/core/tape"

// The text of a number node, its exact value in decimal: a bignum's digits converted in limbs of nine, a float's
// shortest text, and a decimal fraction or a bigfloat as digits and an exponent.

// The magnitude of a number being spelled, as limbs of nine decimal digits, least significant first, in a scratch that
// holds `len(limbs)` of them.
@(private)
Digits :: struct {
	limbs: []u32,
	n:     int,
}

@(private)
LIMB :: 1_000_000_000

// The limbs that hold the largest magnitude a number spells: a bignum of `BIGNUM_BYTES_MAX` bytes times five to the
// `EXPONENT_MAX`, under 23,300 digits.
@(private)
LIMBS_MAX :: 2600

// Sets `d` to `d * mul + add`, for `mul` of at most 32 bits and `add` below 2^63. Returns false when the limbs fill
// `d.limbs`.
@(private)
mul_add :: proc "contextless" (d: ^Digits, mul: u64, add: u64) -> bool #no_bounds_check {
	carry := add
	for k in 0 ..< d.n {
		v := u64(d.limbs[k]) * mul + carry
		d.limbs[k], carry = u32(v % LIMB), v / LIMB
	}
	for carry > 0 {
		if d.n == len(d.limbs) {
			return false
		}
		d.limbs[d.n] = u32(carry % LIMB)
		d.n += 1
		carry /= LIMB
	}
	return true
}

// Sets `d` to `v`.
@(private)
digits_set :: proc "contextless" (d: ^Digits, v: u64) -> bool {
	d.n = 0
	return mul_add(d, 1, v)
}

// The decimal digits of `d`, most significant first, after the byte of `buf` that holds the sign, which `negative`
// writes. False when `buf` is too short.
@(private)
digits_text :: proc "contextless" (d: ^Digits, buf: []u8, negative: bool) -> (s: string, ok: bool) #no_bounds_check {
	if d.n == 0 {
		if len(buf) < 2 {
			return
		}
		buf[1] = '0'
		return string(buf[1:2]), true
	}
	top := d.limbs[d.n - 1]
	width := 1
	for v := top; v >= 10; v /= 10 {
		width += 1
	}
	if len(buf) < 1 + width + 9 * (d.n - 1) {
		return
	}
	at := 1
	for k := width - 1; k >= 0; k -= 1 {
		buf[at + k] = '0' + u8(top % 10)
		top /= 10
	}
	at += width
	for l := d.n - 2; l >= 0; l -= 1 {
		v := d.limbs[l]
		for k := 8; k >= 0; k -= 1 {
			buf[at + k] = '0' + u8(v % 10)
			v /= 10
		}
		at += 9
	}
	if negative {
		buf[0] = '-'
		return string(buf[:at]), true
	}
	return string(buf[1:at]), true
}

// The decimal digits of the integer or tag whose head `span` starts with, in `buf`, which holds 21 bytes: a sign and
// the 20 digits of the largest magnitude.
@(private)
integer_text :: proc "contextless" (span: []u8, buf: []u8) -> string {
	major, arg, _ := head_of(span)
	at := len(buf)
	if major == 1 && arg == max(u64) {
		// The one value past `u64`.
		at -= len(MAGNITUDE_2_64)
		copy(buf[at:], MAGNITUDE_2_64)
	} else {
		v := arg + u64(major)
		for {
			at -= 1
			buf[at] = '0' + u8(v % 10)
			v /= 10
			if v == 0 {
				break
			}
		}
	}
	if major == 1 {
		at -= 1
		buf[at] = '-'
	}
	return string(buf[at:])
}

// The magnitude of the integer item whose argument is the largest `u64`, as -2^64.
@(private)
MAGNITUDE_2_64 :: "18446744073709551616"

// The magnitude of the integer item at the start of `item`, or of the bignum tag 2 or 3 it starts with, into `d`, and
// whether the value is negative. False when `d` is too short or a bignum's payload passes `BIGNUM_BYTES_MAX`.
@(private)
mantissa_digits :: proc "contextless" (item: []u8, d: ^Digits) -> (negative, ok: bool) {
	if item[0] >> 5 != 6 {
		m, marg, _ := head_of(item)
		digits_set(d, marg) or_return
		negative = m == 1
	} else {
		_, tag, hl := head_of(item)
		payload_digits(item[hl:], d) or_return
		negative = tag == 3
	}
	if negative && !mul_add(d, 1, 1) {
		return
	}
	return negative, true
}

// The magnitude of the payload of the byte string item that starts `span`, read as a big-endian number, into `d`, four
// bytes to each pass over the limbs. False when `d` is too short or the payload passes `BIGNUM_BYTES_MAX`.
@(private)
payload_digits :: proc "contextless" (span: []u8, d: ^Digits) -> bool {
	r := string_run(span)
	read := 0
	word: u64
	held: u64
	d.n = 0
	for chunk in text_next(&r) {
		read += len(chunk)
		if read > BIGNUM_BYTES_MAX {
			return false
		}
		for b in chunk {
			word = word << 8 | u64(b)
			held += 1
			if held == 4 {
				mul_add(d, 1 << 32, word) or_return
				word, held = 0, 0
			}
		}
	}
	if held > 0 {
		mul_add(d, 1 << (8 * held), word) or_return
	}
	return true
}

// The bytes of the payload of the byte string item that starts `span`, or `BIGNUM_BYTES_MAX + 1` for any more.
@(private)
payload_size :: proc "contextless" (span: []u8) -> int {
	r := string_run(span)
	read := 0
	for chunk in text_next(&r) {
		read += len(chunk)
		if read > BIGNUM_BYTES_MAX {
			return BIGNUM_BYTES_MAX + 1
		}
	}
	return read
}

// The decimal text of number node `t` of `src`, its exact value, into `buf`: an integer's or a bignum's digits with
// their sign, a float's shortest text that reads back as it, and a decimal fraction or a bigfloat as `fraction_text`
// spells it. False when `buf` is shorter than `number_room` gives, which it is for a number past what `number_room`
// spells.
@(private)
number_text :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (s: string, ok: bool) {
	span := src[t.lo:t.lo + u64(t.n)]
	room := number_room(src, t)
	if room == 0 || len(buf) < room {
		return "", false
	}
	switch t.spelling & tape.NUMBER_KIND {
	case NUMBER_FLOAT:
		return float_text(span, buf)
	case NUMBER_BIG, NUMBER_BIG_NEGATIVE:
		limbs: [LIMBS_MAX]u32 = ---
		d := Digits {
			limbs = limbs[:],
		}
		payload_digits(span, &d) or_return
		negative := t.spelling & tape.NUMBER_KIND == NUMBER_BIG_NEGATIVE
		if negative {
			mul_add(&d, 1, 1) or_return
		}
		return digits_text(&d, buf, negative)
	case NUMBER_DECIMAL:
		limbs: [LIMBS_MAX]u32 = ---
		return fraction_text(span, buf, limbs[:], false)
	case NUMBER_BIGFLOAT:
		limbs: [LIMBS_MAX]u32 = ---
		return fraction_text(span, buf, limbs[:], true)
	}
	return integer_text(span, buf), true
}

// The bytes that always hold `number_text` of number node `t` of `src`, and 0 for a number whose text is past what
// `number_text` spells: a bignum, or a decimal fraction's or bigfloat's mantissa, of more than `BIGNUM_BYTES_MAX`
// payload bytes, or a bigfloat's exponent past `EXPONENT_MAX`.
@(private)
number_room :: proc "contextless" (src: []u8, t: tape.Node) -> int {
	span := src[t.lo:t.lo + u64(t.n)]
	switch t.spelling & tape.NUMBER_KIND {
	case NUMBER_FLOAT:
		// The longest text of a binary64, `-0.000123456789012345678` or `-12345678901234567000000.0`, and `.0`.
		return 40
	case NUMBER_BIG, NUMBER_BIG_NEGATIVE:
		bytes := payload_size(span)
		if bytes > BIGNUM_BYTES_MAX {
			return 0
		}
		// A magnitude of `k` bytes has fewer than `k * 2.41 + 1` decimal digits, and a sign.
		return bytes * 5 / 2 + 3
	case NUMBER_DECIMAL, NUMBER_BIGFLOAT:
		pos := array_body(span)
		major, earg, ehl := head_of(span[pos:])
		bytes := 0
		if mantissa := span[pos + ehl:]; mantissa[0] >> 5 == 6 {
			_, _, hl := head_of(mantissa)
			bytes = payload_size(mantissa[hl:])
			if bytes > BIGNUM_BYTES_MAX {
				return 0
			}
		} else {
			bytes = 8
		}
		// The digits of the mantissa and its sign, the `e`, the exponent's sign and its 20 digits at the most.
		room := bytes * 5 / 2 + 3 + 22
		if t.spelling & tape.NUMBER_KIND == NUMBER_DECIMAL {
			return room
		}
		if earg > EXPONENT_MAX {
			return 0
		}
		e := int(earg)
		// Times two to the `e` adds fewer than `e * 0.31` digits, times five to the `e` fewer than `e * 0.7`.
		return room + (e * 7 / 10 + 1 if major == 1 else e * 31 / 100 + 1)
	}
	// A sign and the 20 digits of the largest magnitude.
	return 21
}

// The shortest text of the float whose item is `span` that reads back as its value as binary64, whatever its width, in
// jq's layout: plain for a decimal point of 0.0001 to 10^15 past the digits and an exponent of two digits at least
// otherwise, with `.0` on a value that is a whole number. A NaN and an infinity have no text, which is empty.
@(private, cold)
float_text :: proc "contextless" (span: []u8, buf: []u8) -> (string, bool) {
	f := transmute(f64)float_bits(span)
	if f - f != 0 {
		return "", true
	}
	// A contextless proc needs a context for `strconv`, whose allocator it does not use.
	context = runtime.default_context()
	scratch: [32]u8
	shortest := strconv.write_float(scratch[:], f, 'e', -1, 64, {})
	// `d.ddde+xx` or `de+xx`, with a sign: the digits, and the place of the point past the first.
	at := 0
	negative := shortest[0] == '-'
	if negative {
		at = 1
	}
	digits: [20]u8
	k := 0
	for ; at < len(shortest) && shortest[at] != 'e'; at += 1 {
		if shortest[at] != '.' {
			digits[k] = shortest[at]
			k += 1
		}
	}
	e := 0
	for c in shortest[at + 2:] {
		e = e * 10 + int(c - '0')
	}
	if shortest[at + 1] == '-' {
		e = -e
	}
	for k > 0 && digits[k - 1] == '0' {
		k -= 1
	}
	// The value is 0.d1..dk * 10^n.
	n := e + 1
	w := 0
	put :: proc "contextless" (buf: []u8, w: ^int, c: u8) {
		buf[w^] = c
		w^ += 1
	}
	if negative {
		put(buf, &w, '-')
	}
	switch {
	case k == 0:
		put(buf, &w, '0')
	case n + 3 >= 0 && n <= k + 15:
		if n <= 0 {
			put(buf, &w, '0')
			put(buf, &w, '.')
			for _ in 0 ..< -n {
				put(buf, &w, '0')
			}
		}
		for c, j in digits[:k] {
			if j == n && n > 0 {
				put(buf, &w, '.')
			}
			put(buf, &w, c)
		}
		for _ in k ..< n {
			put(buf, &w, '0')
		}
	case:
		put(buf, &w, digits[0])
		if k > 1 {
			put(buf, &w, '.')
			for c in digits[1:k] {
				put(buf, &w, c)
			}
		}
		put(buf, &w, 'e')
		put(buf, &w, '+' if n - 1 >= 0 else '-')
		x := abs(n - 1)
		if x >= 100 {
			put(buf, &w, u8('0' + x / 100))
		}
		put(buf, &w, u8('0' + x / 10 % 10))
		put(buf, &w, u8('0' + x % 10))
		return string(buf[:w]), true
	}
	// A whole number keeps a point, so that a format that tells floats from integers reads its text as a float.
	if k <= n || k == 0 {
		put(buf, &w, '.')
		put(buf, &w, '0')
	}
	return string(buf[:w]), true
}

// The text `<digits>e<exponent>` of the decimal fraction whose array is `span`, or with `binary` of the bigfloat, whose
// value `m * 2^e` is spelled `m * 5^-e` times ten to the `e` for a negative `e` and as the integer `m * 2^e` for
// another, into `buf`, with `limbs` for its magnitude. False when `buf` or `limbs` is too short, the mantissa is a
// bignum past `BIGNUM_BYTES_MAX` bytes, or a bigfloat's exponent passes `EXPONENT_MAX`.
@(private)
fraction_text :: proc "contextless" (span: []u8, buf: []u8, limbs: []u32, binary: bool) -> (s: string, ok: bool) {
	pos := array_body(span)
	major, earg, ehl := head_of(span[pos:])
	exp := i64(min(earg, u64(max(i64)) >> 1))
	if major == 1 {
		exp = -1 - exp
	}
	d := Digits {
		limbs = limbs,
	}
	negative := mantissa_digits(span[pos + ehl:], &d) or_return
	if binary {
		if earg > EXPONENT_MAX {
			return
		}
		// The largest powers of two and five below 2^32.
		mul, step := u64(1 << 31), i64(31)
		if exp < 0 {
			mul, step = 1220703125, 13
		}
		k := exp if exp >= 0 else -exp
		for ; k >= step; k -= step {
			mul_add(&d, mul, 0) or_return
		}
		last := u64(1)
		for _ in 0 ..< k {
			last *= 2 if exp >= 0 else 5
		}
		mul_add(&d, last, 0) or_return
		if exp >= 0 {
			return digits_text(&d, buf, negative)
		}
	}
	text := digits_text(&d, buf, negative) or_return
	from := int(uintptr(raw_data(text)) - uintptr(raw_data(buf)))
	used := from + len(text)
	suffix: [24]u8
	suffix[0] = 'e'
	w := 1
	e := exp
	if e < 0 {
		suffix[w] = '-'
		w += 1
		e = -e
	}
	digits: [20]u8
	k := len(digits)
	for {
		k -= 1
		digits[k] = '0' + u8(e % 10)
		e /= 10
		if e == 0 {
			break
		}
	}
	w += copy(suffix[w:], digits[k:])
	if used + w > len(buf) {
		return "", false
	}
	copy(buf[used:], suffix[:w])
	return string(buf[from:used + w]), true
}
