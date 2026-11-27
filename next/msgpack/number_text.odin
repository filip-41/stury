package msgpack

import "base:intrinsics"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Text rendering for MessagePack binary number nodes (`node_text`) and MessagePack Timestamp `ext -1` payloads.

@(private)
TIMESTAMP_TEXT_ROOM :: 48

// The decimal digits of the MessagePack integer whose bytes start `span`, in `buf` (at least 21 bytes).
@(private)
integer_text :: proc "contextless" (span: []u8, buf: []u8) -> string {
	n := integer_value(span)
	neg := n.kind == .Int && i64(n.bits) < 0
	v := u64(~i64(n.bits)) + 1 if neg else n.bits
	at := len(buf)
	for {
		at -= 1
		buf[at] = '0' + u8(v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	if neg {
		at -= 1
		buf[at] = '-'
	}
	return string(buf[at:])
}

// The shortest decimal text of a `float32` or `float64` node, with `.0` for whole numbers and empty text for NaN/Inf.
@(private, cold)
float_text :: proc "contextless" (span: []u8, buf: []u8) -> (string, bool) {
	return spell.float64_text(transmute(f64)float_bits(span), buf)
}

// The decimal text of number node `t` of `src` into `buf`.
@(private)
number_text :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (string, bool) {
	span := src[t.lo:t.lo + u64(t.n)]
	room := number_room(src, t)
	if len(buf) < room {
		return "", false
	}
	if t.spelling & tape.NUMBER_KIND == NUMBER_FLOAT {
		return float_text(span, buf)
	}
	return integer_text(span, buf), true
}

// The bytes required for `number_text` of number node `t`.
@(private)
number_room :: proc "contextless" (src: []u8, t: tape.Node) -> int {
	_ = src
	if t.spelling & tape.NUMBER_KIND == NUMBER_FLOAT {
		return 40
	}
	return 21
}

// Decodes a MessagePack Timestamp payload (4, 8, or 12 bytes) into `(sec, nsec)`, returning false if malformed.
@(private)
timestamp_decode :: #force_inline proc "contextless" (payload: []u8) -> (sec: i64, nsec: u32, ok: bool) #no_bounds_check {
	switch len(payload) {
	case 4:
		s := intrinsics.unaligned_load((^u32be)(raw_data(payload)))
		return i64(u32(s)), 0, true
	case 8:
		data := u64(intrinsics.unaligned_load((^u64be)(raw_data(payload))))
		ns := u32(data >> 34)
		if ns > 999_999_999 {
			return 0, 0, false
		}
		return i64(data & 0x3_FFFF_FFFF), ns, true
	case 12:
		ns := u32(intrinsics.unaligned_load((^u32be)(raw_data(payload))))
		if ns > 999_999_999 {
			return 0, 0, false
		}
		s := i64(intrinsics.unaligned_load((^i64be)(raw_data(payload)[4:])))
		return s, ns, true
	}
	return 0, 0, false
}

// Formats a valid MessagePack Timestamp payload in UTC RFC 3339 (or extended ISO-8601 outside years 0..9999) into `buf`.
@(private)
timestamp_text :: proc "contextless" (payload: []u8, buf: []u8) -> (string, bool) #no_bounds_check {
	if len(buf) < TIMESTAMP_TEXT_ROOM {
		return "", false
	}
	sec, nsec, ok := timestamp_decode(payload)
	if !ok {
		return "", false
	}
	// Euclidean floor division by 86400 in 128-bit arithmetic so extreme `i64` timestamps never overflow.
	s128 := i128(sec)
	days := s128 / 86400
	rem := s128 % 86400
	if rem < 0 {
		days -= 1
		rem += 86400
	}
	sod := int(rem)
	hour := sod / 3600
	minute := (sod % 3600) / 60
	second := sod % 60

	// Howard Hinnant's civil_from_days in `i128`.
	z := days + 719468
	era := (z if z >= 0 else z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	year := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	day := int(doy - (153 * mp + 2) / 5 + 1)
	month := int(mp + (3 if mp < 10 else -9))
	if month <= 2 {
		year += 1
	}

	w := 0
	put2 :: #force_inline proc "contextless" (buf: []u8, w: ^int, v: int) #no_bounds_check {
		buf[w^] = '0' + u8(v / 10)
		buf[w^ + 1] = '0' + u8(v % 10)
		w^ += 2
	}

	if year >= 0 && year <= 9999 {
		y4 := int(year)
		put2(buf, &w, y4 / 100)
		put2(buf, &w, y4 % 100)
	} else {
		buf[w] = '+' if year >= 0 else '-'
		w += 1
		ay := u64(year if year >= 0 else -year)
		ydigits: [20]u8
		k := len(ydigits)
		for ay > 0 || len(ydigits) - k < 4 {
			k -= 1
			ydigits[k] = '0' + u8(ay % 10)
			ay /= 10
		}
		w += copy(buf[w:], ydigits[k:])
	}
	buf[w] = '-'
	w += 1
	put2(buf, &w, month)
	buf[w] = '-'
	w += 1
	put2(buf, &w, day)
	buf[w] = 'T'
	w += 1
	put2(buf, &w, hour)
	buf[w] = ':'
	w += 1
	put2(buf, &w, minute)
	buf[w] = ':'
	w += 1
	put2(buf, &w, second)

	if nsec != 0 {
		buf[w] = '.'
		w += 1
		frac := nsec
		digits := 9
		for frac % 10 == 0 {
			frac /= 10
			digits -= 1
		}
		for k := digits - 1; k >= 0; k -= 1 {
			buf[w + k] = '0' + u8(frac % 10)
			frac /= 10
		}
		w += digits
	}
	buf[w] = 'Z'
	w += 1
	return string(buf[:w]), true
}
