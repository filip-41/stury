package jq

// The Windows build's own calendar time (the `_windows` suffix keeps it out of other builds; it is not UI
// windows): gmtime_r, timegm and strptime, which the UCRT lacks (its _gmtime64_s refuses a time before 1970), as
// glibc's behave: the proleptic Gregorian calendar, no leap seconds, and strptime's C-locale conversions.

import "core:c/libc"
import "core:math"

@(private = "file")
DAY :: 86400

// `t` as UTC, false when its year is past a C int, as glibc's EOVERFLOW.
utc_time :: proc(t: libc.time_t, tm: ^libc.tm) -> bool {
	days := math.floor_div(i64(t), DAY)
	secs := i64(t) - days * DAY
	// civil_from_days
	z := days + 719468
	era := math.floor_div(z, 146097)
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	m := mp + 3 if mp < 10 else mp - 9
	y := yoe + era * 400 + (1 if m <= 2 else 0)
	if y - 1900 > i64(max(libc.int)) || y - 1900 < i64(min(libc.int)) {
		return false
	}
	tm^ = {
		tm_year = libc.int(y - 1900),
		tm_mon  = libc.int(m - 1),
		tm_mday = libc.int(doy - (153 * mp + 2) / 5 + 1),
		tm_hour = libc.int(secs / 3600),
		tm_min  = libc.int(secs / 60 % 60),
		tm_sec  = libc.int(secs % 60),
		tm_wday = libc.int(days - math.floor_div(days + 4, 7) * 7 + 4),
		tm_yday = libc.int(days - days_from_civil(y, 1, 1)),
	}
	return true
}

// `tm` read as UTC, its fields normalized as timegm normalizes them, or -1 when the year overflows.
timegm :: proc(tm: ^libc.tm) -> libc.time_t {
	mon := i64(tm.tm_mon)
	y := i64(tm.tm_year) + 1900 + math.floor_div(mon, 12)
	days := days_from_civil(y, mon - math.floor_div(mon, 12) * 12 + 1, 1) + i64(tm.tm_mday) - 1
	t := libc.time_t(days * DAY + i64(tm.tm_hour) * 3600 + i64(tm.tm_min) * 60 + i64(tm.tm_sec))
	return t if utc_time(t, tm) else -1
}

@(private = "file", rodata)
WEEKDAYS := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
@(private = "file", rodata)
MONTHS := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

@(private = "file")
is_space :: proc(c: byte) -> bool {
	return c == ' ' || '\t' <= c && c <= '\r'
}

@(private = "file")
lower :: proc(c: byte) -> byte {
	return c + 32 if 'A' <= c && c <= 'Z' else c
}

// What strptime has read so far, and what it has yet to settle at the end.
@(private = "file")
Parse :: struct {
	s:        []byte,
	at:       int,
	century:  int, // -1 until %C
	year2:    int, // -1 until %y
	pm:       int, // -1 until %p, else 0 or 1
	hour12:   bool,
	have_mon, have_mday, have_yday: bool,
}

// glibc's get_number: spaces, then up to `n` digits, stopping before a digit that would pass `hi`.
@(private = "file")
number :: proc(p: ^Parse, lo, hi, n: int) -> (val: int, ok: bool) {
	for p.at < len(p.s) && is_space(p.s[p.at]) {
		p.at += 1
	}
	if p.at == len(p.s) || p.s[p.at] < '0' || p.s[p.at] > '9' {
		return 0, false
	}
	left := n
	for {
		val = val * 10 + int(p.s[p.at] - '0')
		p.at += 1
		left -= 1
		if left == 0 || val * 10 > hi || p.at == len(p.s) || p.s[p.at] < '0' || p.s[p.at] > '9' {
			break
		}
	}
	return val, lo <= val && val <= hi
}

// One of `names`, whole or its first three letters, in any case.
@(private = "file")
name :: proc(p: ^Parse, names: []string) -> (int, bool) {
	rest := p.s[p.at:]
	for full, i in names {
		for n in ([]int{len(full), 3}) {
			if len(rest) < n {
				continue
			}
			same := true
			for k in 0 ..< n {
				if lower(rest[k]) != lower(full[k]) {
					same = false
					break
				}
			}
			if same {
				p.at += n
				return i, true
			}
		}
	}
	return 0, false
}

// strptime in the C locale: the text after what `format` read, or nil when the input does not match it.
strptime :: proc(input, format: cstring, tm: ^libc.tm) -> cstring {
	p := Parse {
		s       = transmute([]byte)string(input),
		century = -1,
		year2   = -1,
		pm      = -1,
	}
	if !conversions(&p, transmute([]byte)string(format), tm) {
		return nil
	}
	if p.year2 >= 0 {
		year := p.year2 + 1900 if p.year2 >= 69 else p.year2 + 2000
		if p.century >= 0 {
			year = p.century * 100 + p.year2
		}
		tm.tm_year = libc.int(year - 1900)
	} else if p.century >= 0 {
		tm.tm_year = libc.int(p.century * 100 - 1900)
	}
	if p.have_yday && !(p.have_mon && p.have_mday) {
		// As glibc, the month and day a yearday falls on.
		y := int(tm.tm_year) + 1900
		leap := 1 if y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) else 0
		before :: proc(m, leap: int) -> int {
			DAYS := [13]int{0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365}
			return DAYS[m] + (leap if m >= 2 else 0)
		}
		mon := 1
		for mon < 12 && before(mon, leap) <= int(tm.tm_yday) {
			mon += 1
		}
		if !p.have_mon {
			tm.tm_mon = libc.int(mon - 1)
		}
		if !p.have_mday {
			tm.tm_mday = libc.int(int(tm.tm_yday) - before(mon - 1, leap) + 1)
		}
	}
	if p.hour12 && p.pm >= 0 {
		tm.tm_hour = libc.int(int(tm.tm_hour) % 12 + 12 * p.pm)
	}
	return cstring(raw_data(p.s[p.at:]))
}

@(private = "file")
conversions :: proc(p: ^Parse, format: []byte, tm: ^libc.tm) -> bool {
	set :: proc(field: ^libc.int, v: int) {
		field^ = libc.int(v)
	}
	for i := 0; i < len(format); i += 1 {
		c := format[i]
		if is_space(c) {
			for p.at < len(p.s) && is_space(p.s[p.at]) {
				p.at += 1
			}
			continue
		}
		if c != '%' || i + 1 == len(format) {
			if p.at == len(p.s) || p.s[p.at] != c {
				return false
			}
			p.at += 1
			continue
		}
		i += 1
		// The E and O modifiers name the C locale's own conversions.
		if (format[i] == 'E' || format[i] == 'O') && i + 1 < len(format) {
			i += 1
		}
		v, ok := 0, true
		switch format[i] {
		case '%':
			ok = p.at < len(p.s) && p.s[p.at] == '%'
			p.at += 1
		case 'n', 't':
			for p.at < len(p.s) && is_space(p.s[p.at]) {
				p.at += 1
			}
		case 'a', 'A':
			v, ok = name(p, WEEKDAYS[:])
			set(&tm.tm_wday, v)
		case 'b', 'B', 'h':
			v, ok = name(p, MONTHS[:])
			set(&tm.tm_mon, v)
			p.have_mon = true
		case 'c':
			ok = conversions(p, transmute([]byte)string("%a %b %e %H:%M:%S %Y"), tm)
		case 'C':
			p.century, ok = number(p, 0, 99, 2)
		case 'd', 'e':
			v, ok = number(p, 1, 31, 2)
			set(&tm.tm_mday, v)
			p.have_mday = true
		case 'D', 'x':
			ok = conversions(p, transmute([]byte)string("%m/%d/%y"), tm)
		case 'F':
			ok = conversions(p, transmute([]byte)string("%Y-%m-%d"), tm)
		case 'H', 'k':
			v, ok = number(p, 0, 23, 2)
			set(&tm.tm_hour, v)
			p.hour12 = false
		case 'I', 'l':
			v, ok = number(p, 1, 12, 2)
			set(&tm.tm_hour, v % 12)
			p.hour12 = true
		case 'j':
			v, ok = number(p, 1, 366, 3)
			set(&tm.tm_yday, v - 1)
			p.have_yday = true
		case 'm':
			v, ok = number(p, 1, 12, 2)
			set(&tm.tm_mon, v - 1)
			p.have_mon = true
		case 'M':
			v, ok = number(p, 0, 59, 2)
			set(&tm.tm_min, v)
		case 'p':
			if p.at + 2 <= len(p.s) && lower(p.s[p.at + 1]) == 'm' && (lower(p.s[p.at]) == 'a' || lower(p.s[p.at]) == 'p') {
				p.pm = 1 if lower(p.s[p.at]) == 'p' else 0
				p.at += 2
			} else {
				ok = false
			}
		case 'r':
			ok = conversions(p, transmute([]byte)string("%I:%M:%S %p"), tm)
		case 'R':
			ok = conversions(p, transmute([]byte)string("%H:%M"), tm)
		case 's':
			// Seconds since the epoch, as local time.
			neg := p.at < len(p.s) && p.s[p.at] == '-'
			if neg {
				p.at += 1
			}
			secs: i64
			start := p.at
			for p.at < len(p.s) && '0' <= p.s[p.at] && p.s[p.at] <= '9' {
				secs = secs * 10 + i64(p.s[p.at] - '0')
				p.at += 1
			}
			ok = p.at > start && local_time(libc.time_t(-secs if neg else secs), tm)
		case 'S':
			v, ok = number(p, 0, 61, 2)
			set(&tm.tm_sec, v)
		case 'T', 'X':
			ok = conversions(p, transmute([]byte)string("%H:%M:%S"), tm)
		case 'u':
			v, ok = number(p, 1, 7, 1)
			set(&tm.tm_wday, v % 7)
		case 'w':
			v, ok = number(p, 0, 6, 1)
			set(&tm.tm_wday, v)
		case 'U', 'W', 'V':
			// Week numbers settle nothing without a weekday and a year, and jq reads none of them.
			_, ok = number(p, 0, 53, 2)
		case 'g':
			_, ok = number(p, 0, 99, 2)
		case 'G':
			_, ok = number(p, 0, 9999, 4)
		case 'y':
			p.year2, ok = number(p, 0, 99, 2)
		case 'Y':
			v, ok = number(p, 0, 9999, 4)
			set(&tm.tm_year, v - 1900)
			p.century, p.year2 = -1, -1
		case 'z':
			// An offset, +hh, +hhmm or +hh:mm, read and not applied: libc.tm has no tm_gmtoff here.
			if p.at < len(p.s) && (p.s[p.at] == '+' || p.s[p.at] == '-') {
				p.at += 1
				digits := 0
				for p.at < len(p.s) && digits < 4 && ('0' <= p.s[p.at] && p.s[p.at] <= '9' || digits == 2 && p.s[p.at] == ':') {
					if p.s[p.at] != ':' {
						digits += 1
					}
					p.at += 1
				}
				ok = digits == 2 || digits == 4
			} else if p.at < len(p.s) && p.s[p.at] == 'Z' {
				p.at += 1
			} else {
				ok = false
			}
		case 'Z':
			// A zone's name, read and not applied, as glibc does.
			for p.at < len(p.s) && !is_space(p.s[p.at]) {
				p.at += 1
			}
		case:
			ok = false
		}
		if !ok {
			return false
		}
	}
	return true
}
