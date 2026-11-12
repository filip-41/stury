#+private
package toml

import core "../core"

// The four datetime types, in bits 3 to 5 of a datetime token's `spelling`. Bit 0 is clear, which tells a datetime from
// a quoted string.
Datetime :: enum u8 {
	None,
	Offset, // `1979-05-27T07:32:00Z`
	Local, // `1979-05-27T07:32:00`
	Date, // `1979-05-27`
	Time, // `07:32:00`
}

DATETIME_SHIFT :: 3

datetime_spelling :: #force_inline proc "contextless" (d: Datetime) -> u16 {
	return u16(d) << DATETIME_SHIFT
}

// The datetime type of a value token's `spelling`, `.None` for a string.
datetime_of :: #force_inline proc "contextless" (spelling: u16) -> Datetime {
	if spelling & core.SPELLING_DECODE != 0 {
		return .None
	}
	return Datetime(spelling >> DATETIME_SHIFT & 7)
}

digit :: #force_inline proc "contextless" (src: []u8, i: int) -> (v: int, ok: bool) {
	if i < len(src) && src[i] >= '0' && src[i] <= '9' {
		return int(src[i] - '0'), true
	}
	return 0, false
}

// The value of the `count` digits at `i`.
digits :: proc "contextless" (src: []u8, i, count: int) -> (v: int, ok: bool) {
	for k in 0 ..< count {
		d := digit(src, i + k) or_return
		v = v * 10 + d
	}
	return v, true
}

days_in :: proc "contextless" (year, month: int) -> int {
	switch month {
	case 2:
		leap := year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
		return 29 if leap else 28
	case 4, 6, 9, 11:
		return 30
	}
	return 31
}

// Whether a datetime starts at `i`: four digits and a hyphen, or two digits and a colon.
datetime_starts :: proc "contextless" (src: []u8, i: int) -> bool {
	if _, ok := digits(src, i, 4); ok && i + 4 < len(src) && src[i + 4] == '-' {
		return true
	}
	_, ok := digits(src, i, 2)
	return ok && i + 2 < len(src) && src[i + 2] == ':'
}

// Judges the time at `i`. Seconds are optional from TOML 1.1 on. Returns the byte past it.
scan_time :: proc "contextless" (src: []u8, i: int, v11: bool) -> (end: int, v: Verdict) {
	fail :: proc "contextless" (at: int) -> Verdict {
		return bad(at, .Bad_Char, .Bad_Datetime)
	}
	hour, ok := digits(src, i, 2)
	if !ok || hour > 23 {
		return i, fail(i)
	}
	if i + 2 >= len(src) || src[i + 2] != ':' {
		return i + 2, fail(i + 2)
	}
	minute: int
	minute, ok = digits(src, i + 3, 2)
	if !ok || minute > 59 {
		return i + 3, fail(i + 3)
	}
	k := i + 5
	if k < len(src) && src[k] == ':' {
		second: int
		second, ok = digits(src, k + 1, 2)
		if !ok || second > 60 {
			return k + 1, fail(k + 1)
		}
		k += 3
		if k < len(src) && src[k] == '.' {
			k += 1
			if _, has := digit(src, k); !has {
				return k, fail(k)
			}
			for _, has := digit(src, k); has; _, has = digit(src, k) {
				k += 1
			}
		}
	} else if !v11 {
		return k, fail(k)
	}
	return k, 0
}

// Judges the offset at `i`, `Z` or a sign and `hh:mm`. Returns the byte past it.
scan_offset :: proc "contextless" (src: []u8, i: int) -> (end: int, v: Verdict) {
	if src[i] == 'Z' || src[i] == 'z' {
		return i + 1, 0
	}
	hour, ok := digits(src, i + 1, 2)
	if !ok || hour > 23 {
		return i + 1, bad(i + 1, .Bad_Char, .Bad_Datetime)
	}
	if i + 3 >= len(src) || src[i + 3] != ':' {
		return i + 3, bad(i + 3, .Bad_Char, .Bad_Datetime)
	}
	minute: int
	minute, ok = digits(src, i + 4, 2)
	if !ok || minute > 59 {
		return i + 4, bad(i + 4, .Bad_Char, .Bad_Datetime)
	}
	return i + 6, 0
}

// Judges the datetime at `i`, where `datetime_starts` holds. Returns the byte past it and its type.
scan_datetime :: proc "contextless" (src: []u8, i: int, v11: bool) -> (end: int, kind: Datetime, v: Verdict) {
	if src[i + 2] == ':' {
		end, v = scan_time(src, i, v11)
		return end, .Time, v
	}
	year, _ := digits(src, i, 4)
	month, ok := digits(src, i + 5, 2)
	if i + 5 >= len(src) || src[i + 4] != '-' || !ok || month < 1 || month > 12 {
		return i + 5, .None, bad(i + 5, .Bad_Char, .Bad_Datetime)
	}
	if i + 7 >= len(src) || src[i + 7] != '-' {
		return i + 7, .None, bad(i + 7, .Bad_Char, .Bad_Datetime)
	}
	day: int
	day, ok = digits(src, i + 8, 2)
	if !ok || day < 1 || day > days_in(year, month) {
		return i + 8, .None, bad(i + 8, .Bad_Char, .Bad_Datetime)
	}
	k := i + 10
	if k >= len(src) {
		return k, .Date, 0
	}
	sep := src[k]
	_, time_follows := digit(src, k + 1)
	if !(sep == 'T' || sep == 't' || sep == ' ' && time_follows) {
		return k, .Date, 0
	}
	end, v = scan_time(src, k + 1, v11)
	if v != 0 {
		return end, .None, v
	}
	if end < len(src) && (src[end] == 'Z' || src[end] == 'z' || src[end] == '+' || src[end] == '-') {
		end, v = scan_offset(src, end)
		return end, .Offset, v
	}
	return end, .Local, 0
}
