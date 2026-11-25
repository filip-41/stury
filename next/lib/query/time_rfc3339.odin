package query

import "core:math"
import "core:strconv"

// RFC 3339 date-times: `YYYY-MM-DDThh:mm:ss[.fraction](Z|+hh:mm|-hh:mm)` and seconds since the Unix epoch.

// Seconds since the epoch of RFC 3339 date-time `text` with any offset, the fraction kept. The `T` and `Z` may be
// lower case, a space for the `T` is not read, and second 60 is read only as the last second of a UTC day.
rfc3339_seconds :: proc(h: ^Heap, text: Value) -> (res: Value, status: Status) {
	if !is_text(text) {
		return NULL, fail(h, .Types, .Time, text, detail = TIME_STRINGS)
	}
	s := text_of(text)
	secs, fraction, ok := read_rfc3339(s)
	if !ok {
		return NULL, fail(h, .Parse, .Time, text, detail = TIME_RFC3339)
	}
	if fraction == 0 {
		return int_value(secs), .Ok
	}
	return double_value(f64(secs) + fraction), .Ok
}

@(private = "file")
read_rfc3339 :: proc(s: string) -> (secs: i64, fraction: f64, ok: bool) {
	digits :: proc(s: string, at, n: int) -> (v: i64, ok: bool) {
		if at + n > len(s) {
			return 0, false
		}
		for b in transmute([]u8)s[at:at + n] {
			if b < '0' || b > '9' {
				return 0, false
			}
			v = v * 10 + i64(b - '0')
		}
		return v, true
	}
	if len(s) < 20 || s[4] != '-' || s[7] != '-' || s[10] != 'T' && s[10] != 't' || s[13] != ':' || s[16] != ':' {
		return
	}
	year := digits(s, 0, 4) or_return
	month := digits(s, 5, 2) or_return
	day := digits(s, 8, 2) or_return
	hour := digits(s, 11, 2) or_return
	minute := digits(s, 14, 2) or_return
	second := digits(s, 17, 2) or_return
	at := 19
	if s[at] == '.' {
		end := at + 1
		for end < len(s) && '0' <= s[end] && s[end] <= '9' {
			end += 1
		}
		if end == at + 1 {
			return
		}
		fraction, _ = strconv.parse_f64(s[at:end])
		at = end
	}
	offset: i64
	switch {
	case at + 1 == len(s) && (s[at] == 'Z' || s[at] == 'z'):
	case at + 6 == len(s) && (s[at] == '+' || s[at] == '-') && s[at + 3] == ':':
		oh := digits(s, at + 1, 2) or_return
		om := digits(s, at + 4, 2) or_return
		if oh > 23 || om > 59 {
			return
		}
		offset = oh * 60 + om
		if s[at] == '-' {
			offset = -offset
		}
	case:
		return
	}
	days_in_month := [12]i64{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if month < 1 || month > 12 || day < 1 || day > days_in_month[month - 1] + i64(month == 2 && is_leap_year(year)) {
		return
	}
	if hour > 23 || minute > 59 || second > 60 {
		return
	}
	// A leap second is the last of a UTC day.
	if second == 60 && math.floor_mod(hour * 60 + minute - offset, 1440) != 1439 {
		return
	}
	secs = days_from_civil(year, month, day) * DAY + hour * 3600 + minute * 60 + second - offset * 60
	return secs, fraction, true
}

// Number `v`, seconds since the epoch, as an RFC 3339 date-time in UTC, years 0000 to 9999: the fraction is written
// only when there is one, in the digits of the number's shortest spelling.
rfc3339_text :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	f := as_f64(v)
	if !is_number(v) || math.is_nan(f) {
		return NULL, fail(h, .Types, .Time, v, detail = TIME_NUMBER)
	}
	if f < -62167219200 || f >= 253402300800 {
		return NULL, fail(h, .Range, .Time, v, detail = TIME_YEARS)
	}
	spelled: [64]u8
	text := strconv.write_float(spelled[:], abs(f), 'f', -1, 64, {})
	whole, fraction := text, ""
	for b, i in transmute([]u8)text {
		if b == '.' {
			whole, fraction = text[:i], text[i + 1:]
			break
		}
	}
	secs, _ := strconv.parse_i64(whole)
	complement: [64]u8
	if f < 0 {
		// Floor: the fraction is what the negative number lacks to the next whole second.
		secs = -secs
		if fraction != "" {
			secs -= 1
			for c, i in transmute([]u8)fraction {
				complement[i] = '0' + (9 if i < len(fraction) - 1 else 10) - (c - '0')
			}
			fraction = string(complement[:len(fraction)])
		}
	}
	days := math.floor_div(secs, DAY)
	rest := secs - days * DAY
	y, m, d := civil_from_days(days)
	out := make([dynamic]u8, h.allocator)
	defer delete(out)
	put :: proc(out: ^[dynamic]u8, n: i64, width: int) {
		buf: [24]u8
		text := strconv.write_int(buf[:], n, 10)
		for _ in len(text) ..< width {
			append(out, '0')
		}
		append(out, text)
	}
	put(&out, y, 4)
	append(&out, '-')
	put(&out, m, 2)
	append(&out, '-')
	put(&out, d, 2)
	append(&out, 'T')
	put(&out, rest / 3600, 2)
	append(&out, ':')
	put(&out, rest % 3600 / 60, 2)
	append(&out, ':')
	put(&out, rest % 60, 2)
	if fraction != "" {
		append(&out, '.')
		append(&out, fraction)
	}
	append(&out, 'Z')
	return text_value(h, string(out[:]))
}
