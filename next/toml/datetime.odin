package toml

import "stury:lib/core/tape"

// The date-times of a TOML text. A date-time is a `String` token whose span is its text and whose spelling names its
// type in bits 13 to 15, with neither `SPELLING_QUOTED` nor `SPELLING_DECODE`. The scanner finds where a date-time ends
// in running text and judges each field, in TOML's forms: a space may part the date from the time, a date or a time may
// stand alone, and TOML 1.1 leaves out the seconds.

// The type of a date-time, `.None` for a value that is none.
@(private)
Date_Kind :: enum u8 {
	None,
	Datetime, // a date, a time and an offset
	Local_Datetime,
	Local_Date,
	Local_Time,
}

// The type of the date-time that scalar node `n` is, `.None` for any other node.
@(private)
date_kind :: #force_inline proc "contextless" (n: tape.Node) -> Date_Kind {
	if n.kind != .String || n.role != .Value {
		return .None
	}
	return date_of(n.spelling)
}

@(private)
DATE_SHIFT :: 13

#assert(u32(max(Date_Kind)) << DATE_SHIFT <= u32(max(u16)))

@(private)
date_spelling :: #force_inline proc "contextless" (d: Date_Kind) -> u16 {
	return u16(d) << DATE_SHIFT
}

// The date-time type of a string token's spelling, `.None` for a quoted string or a key.
@(private)
date_of :: #force_inline proc "contextless" (spelling: u16) -> Date_Kind {
	if spelling & tape.SPELLING_QUOTED != 0 {
		return .None
	}
	return Date_Kind(spelling >> DATE_SHIFT & 7)
}

@(private)
digit :: #force_inline proc "contextless" (src: []u8, i: int) -> (v: int, ok: bool) #no_bounds_check {
	if i < len(src) && src[i] >= '0' && src[i] <= '9' {
		return int(src[i] - '0'), true
	}
	return 0, false
}

// The value of the `count` digits at `i`.
@(private)
digits :: proc "contextless" (src: []u8, i, count: int) -> (v: int, ok: bool) #no_bounds_check {
	for k in 0 ..< count {
		d := digit(src, i + k) or_return
		v = v * 10 + d
	}
	return v, true
}

@(private)
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

// Whether a date-time starts at `i`: four digits and a hyphen, or two digits and a colon.
@(private)
datetime_starts :: proc "contextless" (src: []u8, i: int) -> bool #no_bounds_check {
	if _, ok := digits(src, i, 4); ok && i + 4 < len(src) && src[i + 4] == '-' {
		return true
	}
	_, ok := digits(src, i, 2)
	return ok && i + 2 < len(src) && src[i + 2] == ':'
}

// Judges `hh:mm` at `i`. Returns `i + 5` or the fault.
@(private)
scan_hhmm :: proc "contextless" (src: []u8, i: int) -> (end: int, v: Verdict) #no_bounds_check {
	hour, ok := digits(src, i, 2)
	if !ok || hour > 23 {
		return i, bad(i, .Bad_Char, .Bad_Datetime)
	}
	if i + 2 >= len(src) || src[i + 2] != ':' {
		return i + 2, bad(i + 2, .Bad_Char, .Bad_Datetime)
	}
	minute: int
	if minute, ok = digits(src, i + 3, 2); !ok || minute > 59 {
		return i + 3, bad(i + 3, .Bad_Char, .Bad_Datetime)
	}
	return i + 5, 0
}

// Judges the time at `i`. Seconds are optional from TOML 1.1 on. Returns the byte past it.
@(private)
scan_time :: proc "contextless" (src: []u8, i: int, v11: bool) -> (end: int, v: Verdict) #no_bounds_check {
	k: int
	if k, v = scan_hhmm(src, i); v != 0 {
		return k, v
	}
	if k < len(src) && src[k] == ':' {
		if second, ok := digits(src, k + 1, 2); !ok || second > 60 {
			return k + 1, bad(k + 1, .Bad_Char, .Bad_Datetime)
		}
		k += 3
		if k < len(src) && src[k] == '.' {
			k += 1
			if _, has := digit(src, k); !has {
				return k, bad(k, .Bad_Char, .Bad_Datetime)
			}
			for _, has := digit(src, k); has; _, has = digit(src, k) {
				k += 1
			}
		}
	} else if !v11 {
		return k, bad(k, .Bad_Char, .Bad_Datetime)
	}
	return k, 0
}

// Judges the offset at `i`, `Z` or a sign and `hh:mm`. Returns the byte past it.
@(private)
scan_offset :: proc "contextless" (src: []u8, i: int) -> (end: int, v: Verdict) #no_bounds_check {
	if src[i] == 'Z' || src[i] == 'z' {
		return i + 1, 0
	}
	return scan_hhmm(src, i + 1)
}

// Judges the date-time at `i`, where `datetime_starts` holds. Returns the byte past it and its type.
@(private)
scan_datetime :: proc "contextless" (src: []u8, i: int, v11: bool) -> (end: int, kind: Date_Kind, v: Verdict) #no_bounds_check {
	if src[i + 2] == ':' {
		end, v = scan_time(src, i, v11)
		return end, .Local_Time, v
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
		return k, .Local_Date, 0
	}
	sep := src[k]
	_, time_follows := digit(src, k + 1)
	if !(sep == 'T' || sep == 't' || sep == ' ' && time_follows) {
		return k, .Local_Date, 0
	}
	end, v = scan_time(src, k + 1, v11)
	if v != 0 {
		return end, .None, v
	}
	if end < len(src) && (src[end] == 'Z' || src[end] == 'z' || src[end] == '+' || src[end] == '-') {
		end, v = scan_offset(src, end)
		return end, .Datetime, v
	}
	return end, .Local_Datetime, 0
}
