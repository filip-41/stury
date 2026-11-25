package query

import "core:strconv"
import "core:strings"

// strftime in the C locale as glibc writes it: the conversions of C99 and POSIX, the flags `_ - 0 ^ #`, a width, and
// the `E` and `O` modifiers, which name the C locale's own conversions. A spelling no conversion reads is copied.

@(private = "file", rodata)
WEEKDAYS := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
@(private = "file", rodata)
MONTHS := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

// What a conversion is written with.
@(private = "file")
Layout :: struct {
	civil: Civil,
	zone:  Zone,
	// The instant the broken-down time names in its zone.
	secs:  i64,
}

// A conversion's flags: the byte it pads a number with (0 for the default, `-` for none), a width, and the case.
@(private = "file")
Spec :: struct {
	pad:   u8,
	width: int,
	upper: bool, // `^`
	flip:  bool, // `#`: the case the conversion's text does not have
}

// What `#` does to a conversion's text.
@(private = "file")
Flip :: enum u8 {
	None,
	Upper,
	Lower,
}

// `tm`, a number of seconds or broken-down time, formatted by `format`, a string, in UTC or the local zone. A number
// is read as `break_time` reads it, and an array is wall-clock time in the zone. The result is a `.Range` error
// when it is empty for a format that is not, or longer than the format and 100 bytes.
format_time :: proc(h: ^Heap, tm: Value, format: Value, zones: Zones, local: bool) -> (res: Value, status: Status) {
	lay := Layout {
		zone = UTC,
	}
	if is_number(tm) {
		at := instant_of(h, tm, zones, local) or_return
		lay = {at.civil, at.zone, at.secs}
	} else if type_of(tm) != .Array {
		return NULL, fail(h, .Types, .Time, tm, detail = TIME_DATETIME)
	}
	if !is_text(format) {
		return NULL, fail(h, .Types, .Time, format, detail = TIME_FORMAT)
	}
	if !is_number(tm) {
		c, ok := civil_of_array(h, tm) or_return
		if !ok {
			return NULL, fail(h, .Types, .Time, tm, detail = TIME_DATETIME)
		}
		if local {
			// The wall-clock time is normalized in the zone, whose offset it takes.
			t, z, found := local_instant(zones, c)
			if !found {
				return NULL, fail(h, .Types, .Time, tm, detail = TIME_DATETIME)
			}
			lay.zone, lay.secs = z, t
			lay.civil, _ = civil_of_seconds(t + z.offset)
		} else {
			lay.civil = c
			if t, normal := civil_normalize(&lay.civil); normal {
				lay.secs = t
			} else {
				lay.civil = c
			}
		}
	}
	f := text_of(format)
	for b, i in transmute([]u8)f {
		if b == 0 {
			f = f[:i] // a C string ends at its NUL
			break
		}
	}
	out := make([dynamic]u8, h.allocator)
	defer delete(out)
	write_conversions(&out, f, &lay)
	if len(out) == 0 && len(f) > 0 || len(out) >= len(f) + 100 {
		return NULL, fail(h, .Range, .Time, format, detail = TIME_FAILURE)
	}
	return text_value(h, string(out[:]))
}

@(private = "file")
write_conversions :: proc(out: ^[dynamic]u8, f: string, lay: ^Layout) {
	for i := 0; i < len(f); {
		if f[i] != '%' {
			append(out, f[i])
			i += 1
			continue
		}
		spec: Spec
		j := i + 1
		flags: for ; j < len(f); j += 1 {
			switch f[j] {
			case '_', '-', '0':
				spec.pad = f[j]
			case '^':
				spec.upper = true
			case '#':
				spec.flip = true
			case:
				break flags
			}
		}
		for ; j < len(f) && '0' <= f[j] && f[j] <= '9'; j += 1 {
			spec.width = min(spec.width * 10 + int(f[j] - '0'), 1 << 20)
		}
		modifier: u8
		if j < len(f) && (f[j] == 'E' || f[j] == 'O') {
			modifier = f[j]
			j += 1
		}
		if j == len(f) || !convert(out, f[j], modifier, spec, lay) {
			// glibc copies what it cannot read, as it was written
			append(out, f[i:min(j + 1, len(f))])
		}
		i = j + 1
	}
}

// Writes conversion `letter`, false when no such conversion exists.
@(private = "file")
convert :: proc(out: ^[dynamic]u8, letter, modifier: u8, spec: Spec, lay: ^Layout) -> bool {
	c := lay.civil
	hour12 := c.hour % 12 if c.hour % 12 != 0 else 12
	switch modifier {
	case 'E':
		if strings.index_byte("cCxXyY", letter) < 0 {
			return false
		}
	case 'O':
		if strings.index_byte("deHImMSuUVwWy", letter) < 0 {
			return false
		}
	}
	switch letter {
	case '%':
		put_text(out, "%", spec)
	case 'a':
		put_text(out, WEEKDAYS[c.wday][:3] if 0 <= c.wday && c.wday < 7 else "?", spec, .Upper)
	case 'A':
		put_text(out, WEEKDAYS[c.wday] if 0 <= c.wday && c.wday < 7 else "?", spec, .Upper)
	case 'b', 'h':
		put_text(out, MONTHS[c.mon][:3] if 0 <= c.mon && c.mon < 12 else "?", spec, .Upper)
	case 'B':
		put_text(out, MONTHS[c.mon] if 0 <= c.mon && c.mon < 12 else "?", spec, .Upper)
	case 'c':
		put_composite(out, "%a %b %e %H:%M:%S %Y", spec, lay)
	case 'C':
		put_number(out, 2, c.year / 100 - i64(c.year % 100 < 0), spec, '0')
	case 'd':
		put_number(out, 2, c.mday, spec, '0')
	case 'D', 'x':
		put_composite(out, "%m/%d/%y", spec, lay)
	case 'e':
		put_number(out, 2, c.mday, spec, '_')
	case 'F':
		put_composite(out, "%Y-%m-%d", spec, lay)
	case 'g':
		year, _ := iso_week(c)
		put_number(out, 2, (year % 100 + 100) % 100, spec, '0')
	case 'G':
		year, _ := iso_week(c)
		put_number(out, 1, year, spec, '0')
	case 'H':
		put_number(out, 2, c.hour, spec, '0')
	case 'I':
		put_number(out, 2, hour12, spec, '0')
	case 'j':
		put_number(out, 3, c.yday + 1, spec, '0')
	case 'k':
		put_number(out, 2, c.hour, spec, '_')
	case 'l':
		put_number(out, 2, hour12, spec, '_')
	case 'm':
		put_number(out, 2, c.mon + 1, spec, '0')
	case 'M':
		put_number(out, 2, c.min, spec, '0')
	case 'n':
		put_text(out, "\n", spec)
	case 'p':
		put_text(out, "PM" if c.hour >= 12 else "AM", spec, .Lower)
	case 'P':
		put_text(out, "pm" if c.hour >= 12 else "am", spec)
	case 'r':
		put_composite(out, "%I:%M:%S %p", spec, lay)
	case 'R':
		put_composite(out, "%H:%M", spec, lay)
	case 's':
		put_number(out, 1, lay.secs, spec, '0')
	case 'S':
		put_number(out, 2, c.sec, spec, '0')
	case 't':
		put_text(out, "\t", spec)
	case 'T', 'X':
		put_composite(out, "%H:%M:%S", spec, lay)
	case 'u':
		put_number(out, 1, c.wday if c.wday != 0 else 7, spec, '0')
	case 'U':
		put_number(out, 2, (c.yday - c.wday + 7) / 7, spec, '0')
	case 'V':
		_, week := iso_week(c)
		put_number(out, 2, week, spec, '0')
	case 'w':
		put_number(out, 1, c.wday, spec, '0')
	case 'W':
		put_number(out, 2, (c.yday - (c.wday - 1 + 7) % 7 + 7) / 7, spec, '0')
	case 'y':
		put_number(out, 2, (c.year % 100 + 100) % 100, spec, '0')
	case 'Y':
		put_number(out, 1, c.year, spec, '0')
	case 'z':
		off := lay.zone.offset
		hhmm := abs(off) / 3600 * 100 + abs(off) % 3600 / 60
		put_text(out, "-" if off < 0 else "+", {})
		put_number(out, 4, hhmm, Spec{pad = spec.pad, width = max(spec.width - 1, 0)}, '0')
	case 'Z':
		put_text(out, lay.zone.name, spec, .Lower)
	case:
		return false
	}
	return true
}

// A conversion that stands for a format of its own, padded as one text.
@(private = "file")
put_composite :: proc(out: ^[dynamic]u8, format: string, spec: Spec, lay: ^Layout) {
	inner := make([dynamic]u8, out.allocator)
	defer delete(inner)
	write_conversions(&inner, format, lay)
	put_text(out, string(inner[:]), spec)
}

// `s` padded to the width with spaces, or zeros for the flag `0`, in upper case for `^`, and in the case `flip` names
// for `#`.
@(private = "file")
put_text :: proc(out: ^[dynamic]u8, s: string, spec: Spec, flip := Flip.None) {
	if spec.pad != '-' && spec.width > len(s) {
		for _ in len(s) ..< spec.width {
			append(out, '0' if spec.pad == '0' else ' ')
		}
	}
	up := spec.upper || spec.flip && flip == .Upper
	down := spec.flip && flip == .Lower
	for b in transmute([]u8)s {
		switch {
		case up && 'a' <= b && b <= 'z':
			append(out, b - 32)
		case down && 'A' <= b && b <= 'Z':
			append(out, b + 32)
		case:
			append(out, b)
		}
	}
}

// Number `n` in at least `digits` digits, padded as `spec` says: zeros by default, spaces for `_` and for a
// conversion whose own padding is `fill == '_'`, none for `-`, and a width past the digits filled the same way.
@(private = "file")
put_number :: proc(out: ^[dynamic]u8, digits: int, n: i64, spec: Spec, fill: u8) {
	buf: [24]u8
	text := strconv.write_uint(buf[:], u64(abs(n)), 10)
	pad := spec.pad if spec.pad != 0 else fill
	total := max(digits, spec.width) if pad != '-' else 0
	zeros := pad != '_' && pad != '-'
	room := total - len(text) - (1 if n < 0 else 0)
	if zeros && n < 0 {
		append(out, '-')
	}
	for _ in 0 ..< max(room, 0) {
		append(out, '0' if zeros else ' ')
	}
	if !zeros && n < 0 {
		append(out, '-')
	}
	append(out, text)
}

// The ISO 8601 year and week number of `c`.
@(private = "file")
iso_week :: proc(c: Civil) -> (year, week: i64) {
	// Days of the year before the week that holds its first Thursday.
	weeks_days :: proc(yday, wday: i64) -> i64 {
		return yday - (yday - wday + 4 + 378) % 7 + 4 - 1
	}
	year = c.year
	days := weeks_days(c.yday, c.wday)
	if days < 0 {
		year -= 1
		days = weeks_days(c.yday + 365 + i64(is_leap_year(year)), c.wday)
	} else if d := weeks_days(c.yday - (365 + i64(is_leap_year(year))), c.wday); d >= 0 {
		year += 1
		days = d
	}
	return year, days / 7 + 1
}
