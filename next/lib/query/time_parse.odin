package query

import "core:math"
import "core:strings"

// strptime in the C locale as glibc reads it. What the format does not read stays as a C `tm` of zeros has it: year
// 1900, month January, day 0. The weekday and the day of the year are the calendar's when the format read a year, month
// or day and not the field itself, and otherwise stay the sentinels 8 and 367 jq presets, as glibc leaves them.

@(private = "file", rodata)
WEEKDAYS := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
@(private = "file", rodata)
MONTHS := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

// What the format has read so far, and what it has yet to settle at the end.
@(private = "file")
Reading :: struct {
	zones:                          Zones, // whose zone `%s` reads the instant in
	text:                           string,
	at:                             int,
	civil:                          Civil,
	century:                        i64, // -1 until %C
	year2:                          i64, // -1 until %y
	pm:                             i64, // -1 until %p, else 0 or 1
	hour12:                         bool,
	have_mon, have_mday, have_yday: bool,
	have_wday, want_xday:           bool, // a weekday was read, a year, month or day was
	week_no:                        i64, // a week number read by %U or %W, -1 until then
	week_monday:                    bool, // it counts weeks from Monday
}

@(private = "file")
is_blank :: proc(b: u8) -> bool {
	return b == ' ' || '\t' <= b && b <= '\r'
}

// glibc's get_number: spaces, then up to `n` digits, stopping before a digit that would pass `hi`.
@(private = "file")
number :: proc(r: ^Reading, lo, hi: i64, n: int) -> (val: i64, ok: bool) {
	for r.at < len(r.text) && r.text[r.at] == ' ' {
		r.at += 1
	}
	if r.at == len(r.text) || r.text[r.at] < '0' || r.text[r.at] > '9' {
		return 0, false
	}
	left := n
	for {
		val = val * 10 + i64(r.text[r.at] - '0')
		r.at += 1
		left -= 1
		if left == 0 || val * 10 > hi || r.at == len(r.text) || r.text[r.at] < '0' || r.text[r.at] > '9' {
			break
		}
	}
	return val, lo <= val && val <= hi
}

// Whether the text at `at` starts with `word`, in any case.
@(private = "file")
starts_fold :: proc(r: ^Reading, word: string) -> bool {
	if len(r.text) - r.at < len(word) {
		return false
	}
	for i in 0 ..< len(word) {
		a, b := r.text[r.at + i], word[i]
		if a != b && !(a | 32 == b | 32 && 'a' <= b | 32 && b | 32 <= 'z') {
			return false
		}
	}
	return true
}

// The index of the one of `names` the text starts with, whole or its first three letters.
@(private = "file")
name :: proc(r: ^Reading, names: []string) -> (int, bool) {
	for full, i in names {
		for n in ([]int{len(full), 3}) {
			if starts_fold(r, full[:n]) {
				r.at += n
				return i, true
			}
		}
	}
	return 0, false
}

// `text` read by `format`, as broken-down time, the text left over after a space appended as a ninth element; a
// `.Parse` error when it does not match. A `%s` is read as local time in the zone of `zones`.
parse_time :: proc(h: ^Heap, text, format: Value, zones: Zones) -> (res: Value, status: Status) {
	if !is_text(text) || !is_text(format) {
		return NULL, fail(h, .Types, .Time, text, format, TIME_STRINGS)
	}
	// C strings end at a NUL.
	text_c, format_c := text_of(text), text_of(format)
	for b, i in transmute([]u8)text_c {
		if b == 0 {
			text_c = text_c[:i]
			break
		}
	}
	for b, i in transmute([]u8)format_c {
		if b == 0 {
			format_c = format_c[:i]
			break
		}
	}
	r := Reading {
		zones   = zones,
		text    = text_c,
		civil   = {year = 1900, wday = 8, yday = 367},
		week_no = -1,
		century = -1,
		year2   = -1,
		pm      = -1,
	}
	if !conversions(&r, format_c) || r.at < len(r.text) && !is_blank(r.text[r.at]) {
		return NULL, fail(h, .Parse, .Time, text, format, TIME_MISMATCH)
	}
	finish(&r)
	out := civil_value(h, r.civil, 0) or_return
	defer if status != .Ok {
		release(h, out)
	}
	if rest := r.text[r.at:]; rest != "" {
		t := text_value(h, rest) or_return
		append_owned(h, &out, t) or_return
	}
	return out, .Ok
}

// Settles what the format read in parts: the year, the month and day of a day of the year, the hour of a twelve-hour
// clock, and the weekday and day of the year.
@(private = "file")
finish :: proc(r: ^Reading) {
	c := &r.civil
	if r.year2 >= 0 {
		c.year = r.year2 + 1900 if r.year2 >= 69 else r.year2 + 2000
		if r.century >= 0 {
			c.year = r.century * 100 + r.year2
		}
	} else if r.century >= 0 {
		c.year = r.century * 100
	}
	if r.hour12 && r.pm >= 0 {
		c.hour = c.hour % 12 + 12 * r.pm
	}
	if r.want_xday && !r.have_wday {
		if r.have_yday && !(r.have_mon && r.have_mday) {
			month_day_of_year(c, r.have_mon, r.have_mday)
			r.have_mon, r.have_mday = true, true
		}
		c.wday = math.floor_mod(days_from_civil(c.year, c.mon + 1, c.mday) + 4, 7)
	}
	if r.want_xday && !r.have_yday {
		c.yday = days_from_civil(c.year, c.mon + 1, c.mday) - days_from_civil(c.year, 1, 1)
	}
	if r.week_no >= 0 && r.have_wday {
		week_of_year(r)
	}
}

// The month and day the day of the year `c.yday` falls on, in glibc's table, where the format did not read them.
@(private = "file")
month_day_of_year :: proc(c: ^Civil, have_mon, have_mday: bool) {
	leap := i64(is_leap_year(c.year))
	before :: proc(m, leap: i64) -> i64 {
		DAYS := [13]i64{0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365}
		return DAYS[m] + (leap if m >= 2 else 0)
	}
	mon := i64(1)
	for mon < 12 && before(mon, leap) <= c.yday {
		mon += 1
	}
	if !have_mon {
		c.mon = mon - 1
	}
	if !have_mday {
		c.mday = c.yday - before(mon - 1, leap) + 1
	}
}

// The day of the year, month and day a week number and a weekday name, as glibc settles them: weeks count from the
// first Sunday (%U) or Monday (%W) of the year, and the weekday read stays.
@(private = "file")
week_of_year :: proc(r: ^Reading) {
	c := &r.civil
	offset := i64(1 if r.week_monday else 0)
	jan1 := math.floor_mod(days_from_civil(c.year, 1, 1) + 4, 7)
	if !r.have_yday {
		c.yday = (7 - (jan1 - offset)) % 7 + (r.week_no - 1) * 7 + (c.wday - offset + 7) % 7
	}
	if !r.have_mon || !r.have_mday {
		month_day_of_year(c, r.have_mon, r.have_mday)
	}
}

@(private = "file")
conversions :: proc(r: ^Reading, format: string) -> bool {
	c := &r.civil
	for i := 0; i < len(format); i += 1 {
		ch := format[i]
		if is_blank(ch) {
			for r.at < len(r.text) && is_blank(r.text[r.at]) {
				r.at += 1
			}
			continue
		}
		if ch != '%' {
			if r.at == len(r.text) || r.text[r.at] != ch {
				return false
			}
			r.at += 1
			continue
		}
		// Flags and a width mean nothing to a reader, and the modifiers name the C locale's own conversions.
		i += 1
		for i < len(format) && (format[i] == '-' || format[i] == '+' || format[i] == '_' || format[i] == '0' || format[i] == '^' || format[i] == '#') {
			i += 1
		}
		for i < len(format) && '0' <= format[i] && format[i] <= '9' {
			i += 1
		}
		if i >= len(format) {
			return false
		}
		modifier: u8
		if format[i] == 'E' || format[i] == 'O' {
			modifier = format[i]
			i += 1
			if i >= len(format) {
				return false
			}
		}
		switch modifier {
		case 'E':
			if strings.index_byte("cCxXyY", format[i]) < 0 {
				return false
			}
		case 'O':
			if strings.index_byte("deHImMSuUVwWy", format[i]) < 0 {
				return false
			}
		}
		v: i64
		ok := true
		switch format[i] {
		case '%':
			ok = r.at < len(r.text) && r.text[r.at] == '%'
			r.at += 1
		case 'n', 't':
			for r.at < len(r.text) && is_blank(r.text[r.at]) {
				r.at += 1
			}
		case 'a', 'A':
			day: int
			day, ok = name(r, WEEKDAYS[:])
			c.wday = i64(day)
			r.have_wday = true
		case 'b', 'B', 'h':
			month: int
			month, ok = name(r, MONTHS[:])
			c.mon = i64(month)
			r.have_mon, r.want_xday = true, true
		case 'c':
			ok = conversions(r, "%a %b %e %H:%M:%S %Y")
		case 'C':
			r.century, ok = number(r, 0, 99, 2)
			r.want_xday = true
		case 'd', 'e':
			c.mday, ok = number(r, 1, 31, 2)
			r.have_mday, r.want_xday = true, true
		case 'D', 'x':
			ok = conversions(r, "%m/%d/%y")
		case 'F':
			ok = conversions(r, "%Y-%m-%d")
		case 'H', 'k':
			c.hour, ok = number(r, 0, 23, 2)
			r.hour12 = false
		case 'I', 'l':
			v, ok = number(r, 1, 12, 2)
			c.hour = v % 12
			r.hour12 = true
		case 'j':
			v, ok = number(r, 1, 366, 3)
			c.yday = v - 1
			r.have_yday = true
		case 'm':
			v, ok = number(r, 1, 12, 2)
			c.mon = v - 1
			r.have_mon, r.want_xday = true, true
		case 'M':
			c.min, ok = number(r, 0, 59, 2)
		case 'p':
			if starts_fold(r, "am") || starts_fold(r, "pm") {
				r.pm = 1 if r.text[r.at] | 32 == 'p' else 0
				r.at += 2
			} else {
				ok = false
			}
		case 'r':
			ok = conversions(r, "%I:%M:%S %p")
		case 'R':
			ok = conversions(r, "%H:%M")
		case 's':
			// Seconds since the epoch, read as local time.
			start := r.at
			secs: i64
			for r.at < len(r.text) && '0' <= r.text[r.at] && r.text[r.at] <= '9' {
				secs = secs * 10 + i64(r.text[r.at] - '0')
				if secs > 1 << 60 {
					return false
				}
				r.at += 1
			}
			z, found := zone_at(r.zones, secs)
			ok = r.at > start && found
			if ok {
				c^, ok = civil_of_seconds(secs + z.offset)
			}
		case 'S':
			c.sec, ok = number(r, 0, 61, 2)
		case 'T', 'X':
			ok = conversions(r, "%H:%M:%S")
		case 'u':
			v, ok = number(r, 1, 7, 1)
			c.wday = v % 7
			r.have_wday = true
		case 'w':
			c.wday, ok = number(r, 0, 6, 1)
			r.have_wday = true
		case 'U', 'W':
			r.week_no, ok = number(r, 0, 53, 2)
			r.week_monday = format[i] == 'W'
		case 'V':
			_, ok = number(r, 0, 53, 2)
		case 'g':
			_, ok = number(r, 0, 99, 2)
		case 'G':
			start := r.at
			for r.at < len(r.text) && '0' <= r.text[r.at] && r.text[r.at] <= '9' {
				r.at += 1
			}
			ok = r.at > start
		case 'y':
			r.year2, ok = number(r, 0, 99, 2)
			r.want_xday = true
		case 'Y':
			c.year, ok = number(r, 0, 9999, 4)
			r.century, r.year2 = -1, -1
			r.want_xday = true
		case 'z':
			ok = read_offset(r)
		case 'Z':
			// A zone's name, read and not applied.
			for r.at < len(r.text) && is_blank(r.text[r.at]) {
				r.at += 1
			}
			for r.at < len(r.text) && !is_blank(r.text[r.at]) {
				r.at += 1
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

// An offset as glibc reads it, `Z`, `+hh`, `+hhmm` or `+hh:mm`, read and not applied.
@(private = "file")
read_offset :: proc(r: ^Reading) -> bool {
	for r.at < len(r.text) && is_blank(r.text[r.at]) {
		r.at += 1
	}
	if r.at < len(r.text) && r.text[r.at] == 'Z' {
		r.at += 1
		return true
	}
	if r.at == len(r.text) || r.text[r.at] != '+' && r.text[r.at] != '-' {
		return false
	}
	r.at += 1
	val, digits := 0, 0
	for digits < 4 && r.at < len(r.text) && '0' <= r.text[r.at] && r.text[r.at] <= '9' {
		val = val * 10 + int(r.text[r.at] - '0')
		digits += 1
		r.at += 1
		if digits == 2 && r.at + 1 < len(r.text) && r.text[r.at] == ':' && '0' <= r.text[r.at + 1] && r.text[r.at + 1] <= '9' {
			r.at += 1
		}
	}
	switch digits {
	case 2:
		return val <= 99
	case 4:
		return val % 100 < 60 && val / 100 <= 99
	}
	return false
}
