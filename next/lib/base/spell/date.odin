package spell

// RFC 3339 dates and times, as a format reads a value it holds as a date-time text, such as CBOR's tag 0.

@(private = "file")
SECOND_NS :: i64(1_000_000_000)
@(private = "file")
MIN_UTC_SEC :: i64(-9_223_372_037) // floor(min(i64) / 1e9), 1677-09-21T00:12:43Z
@(private = "file")
MIN_UTC_FRAC :: i64(145_224_192) // min(i64) - MIN_UTC_SEC * 1e9
@(private = "file")
MAX_UTC_SEC :: i64(9_223_372_036) // floor(max(i64) / 1e9), 2262-04-11T23:47:16Z
@(private = "file")
MAX_UTC_FRAC :: i64(854_775_807) // max(i64) - MAX_UTC_SEC * 1e9

@(private = "file", rodata)
MONTH_DAYS := [12]u8{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

// Parsed components of an RFC 3339 date-time (with optional TOML 1.1 omitted seconds).
@(private = "file")
Date_Time :: struct {
	year, month, day:     int,
	hour, minute, second: int,
	offset:               int, // minutes east of UTC, in [-1439, 1439]
	frac:                 i64, // nanoseconds in [0, 999_999_999]
}

// Whether `s` is an RFC 3339 `date-time`: a `full-date`, `T` or `t`, and a `full-time`. A leap second is the last second
// of a minute that is 23:59 in UTC.
@(require_results)
is_date_time :: proc "contextless" (s: string) -> bool {
	_, ok := parse_date_time(s, false, false, false)
	return ok
}

// Whether `s` is an RFC 3339 `full-date`.
@(require_results)
is_full_date :: proc "contextless" (s: string) -> bool {
	if len(s) != 10 {
		return false
	}
	_, _, _, ok := parse_full_date(s)
	return ok
}

// The nanoseconds since the Unix epoch in UTC of the RFC 3339 date-time `text`, a space also accepted for its `T`, and
// `:SS` optional when `optional_seconds` is true (with no fraction allowed when seconds are omitted). Fractional
// seconds beyond 9 digits are truncated to nanoseconds, and a leap second maps to the next second. `spelled` is false
// for invalid syntax or calendar dates, and `in_range` is false when the UTC instant falls outside `[min(i64), max(i64)]`.
@(require_results)
date_time_nsec :: proc "contextless" (text: string, optional_seconds := false) -> (nsec: i64, spelled, in_range: bool) {
	dt, ok := parse_date_time(text, true, optional_seconds, true)
	if !ok {
		return 0, false, false
	}
	days := days_from_civil(dt.year, dt.month, dt.day)
	utc_sec := days * 86400 + i64(dt.hour * 3600 + dt.minute * 60 + dt.second - dt.offset * 60)
	if utc_sec < MIN_UTC_SEC || utc_sec > MAX_UTC_SEC {
		return 0, true, false
	}
	if utc_sec == MIN_UTC_SEC {
		if dt.frac < MIN_UTC_FRAC {
			return 0, true, false
		}
		return min(i64) + (dt.frac - MIN_UTC_FRAC), true, true
	}
	if utc_sec == MAX_UTC_SEC && dt.frac > MAX_UTC_FRAC {
		return 0, true, false
	}
	return utc_sec * SECOND_NS + dt.frac, true, true
}

// Parses an RFC 3339 `full-date` from `s[:10]`. Caller proves `len(s) >= 10`.
@(private = "file", require_results)
parse_full_date :: #force_inline proc "contextless" (s: string) -> (y, m, d: int, ok: bool) #no_bounds_check {
	if s[4] != '-' || s[7] != '-' {
		return 0, 0, 0, false
	}
	yv, y_ok := digits4(s[0], s[1], s[2], s[3])
	mv, m_ok := digits2(s[5], s[6])
	dv, d_ok := digits2(s[8], s[9])
	if !y_ok || !m_ok || !d_ok || mv < 1 || mv > 12 || dv < 1 || dv > days_in_month(yv, mv) {
		return 0, 0, 0, false
	}
	return yv, mv, dv, true
}

// Parses an RFC 3339 `date-time`: `full-date`, `T`/`t` (or `' '` when `ALLOW_SPACE`), `HH:MM:SS` (or `HH:MM` when
// `optional_seconds`), an optional fraction of one or more digits (only when seconds are present), and a `Z`/`z` or
// `±HH:MM` offset. A leap second `60` is accepted only at UTC 23:59.
@(private = "file", require_results)
parse_date_time :: #force_inline proc "contextless" (s: string, $ALLOW_SPACE: bool, optional_seconds: bool, $COMPUTE_FRAC: bool) -> (dt: Date_Time, ok: bool) #no_bounds_check {
	min_len := 17 if optional_seconds else 20
	if len(s) < min_len {
		return {}, false
	}
	// `len(s) >= 17` proves all indices up to `s[16]` are in bounds.
	sep := s[10]
	when ALLOW_SPACE {
		if sep != 'T' && sep != 't' && sep != ' ' {
			return {}, false
		}
	} else {
		if sep != 'T' && sep != 't' {
			return {}, false
		}
	}
	y, mo, d, date_ok := parse_full_date(s)
	if !date_ok || s[13] != ':' {
		return {}, false
	}
	h, h_ok := digits2(s[11], s[12])
	mi, mi_ok := digits2(s[14], s[15])
	if !h_ok || !mi_ok || h > 23 || mi > 59 {
		return {}, false
	}
	sec := 0
	frac: i64
	pos := 16
	if s[16] == ':' {
		// `:SS` plus at least a 1-byte offset requires `len(s) >= 20`, proving `s[17..19]` are in bounds.
		if len(s) < 20 {
			return {}, false
		}
		sv, s_ok := digits2(s[17], s[18])
		if !s_ok || sv > 60 {
			return {}, false
		}
		sec = sv
		pos = 19
		if s[pos] == '.' {
			pos += 1
			start := pos
			for pos < len(s) && u32(s[pos]) - '0' < 10 {
				when COMPUTE_FRAC {
					if pos - start < 9 {
						frac = frac * 10 + i64(s[pos] - '0')
					}
				}
				pos += 1
			}
			ndigits := pos - start
			if ndigits == 0 {
				return {}, false
			}
			when COMPUTE_FRAC {
				if ndigits < 9 {
					// `ndigits` is in `1..=8`, so `9 - ndigits` is in `1..=8 < len(POW10_U64)`.
					frac *= i64(POW10_U64[9 - ndigits])
				}
			}
		}
	} else if !optional_seconds {
		return {}, false
	}
	rem := len(s) - pos
	offset := 0
	switch {
	case rem == 1 && (s[pos] == 'Z' || s[pos] == 'z'):
	case rem == 6 && (s[pos] == '+' || s[pos] == '-') && s[pos + 3] == ':':
		oh, oh_ok := digits2(s[pos + 1], s[pos + 2])
		om, om_ok := digits2(s[pos + 4], s[pos + 5])
		if !oh_ok || !om_ok || oh > 23 || om > 59 {
			return {}, false
		}
		offset = oh * 60 + om
		if s[pos] == '-' {
			offset = -offset
		}
	case:
		return {}, false
	}
	if sec == 60 {
		// `h*60 + mi` is in `[0, 1439]` and `offset` in `[-1439, 1439]`, so `utc` is in `[-1439, 2878]`;
		// the only values congruent to `1439 (mod 1440)` in that interval are `1439` and `-1`.
		utc := h * 60 + mi - offset
		if utc != 1439 && utc != -1 {
			return {}, false
		}
	}
	return {year = y, month = mo, day = d, hour = h, minute = mi, second = sec, offset = offset, frac = frac}, true
}

// Days in proleptic Gregorian month `m` of `y`. Caller proves `m` is in `1..=12`.
@(private = "file", require_results)
days_in_month :: #force_inline proc "contextless" (y, m: int) -> int #no_bounds_check {
	if m == 2 {
		return 29 if y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) else 28
	}
	return int(MONTH_DAYS[m - 1])
}

// Two ASCII digits as `0..=99`, false if either byte is not a digit.
@(private = "file", require_results)
digits2 :: #force_inline proc "contextless" (a, b: u8) -> (int, bool) {
	da := u32(a) - '0'
	db := u32(b) - '0'
	return int(da * 10 + db), da < 10 && db < 10
}

// Four ASCII digits as `0..=9999`, false if any byte is not a digit.
@(private = "file", require_results)
digits4 :: #force_inline proc "contextless" (a, b, c, d: u8) -> (int, bool) {
	hi, hi_ok := digits2(a, b)
	lo, lo_ok := digits2(c, d)
	return hi * 100 + lo, hi_ok && lo_ok
}

// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's `days_from_civil`), shifted by +400
// years so `year` in `0..=9999` stays strictly positive for unsigned division.
@(private = "file", require_results)
days_from_civil :: #force_inline proc "contextless" (year, month, day: int) -> i64 {
	y := u32(year) + (399 if month <= 2 else 400)
	era := y / 400
	yoe := y - era * 400
	mp := u32(month - 3) if month > 2 else u32(month + 9)
	doy := (153 * mp + 2) / 5 + u32(day) - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return i64(era * 146097 + doe) - 865565
}
