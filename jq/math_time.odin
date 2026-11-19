#+private
package jq

// Numeric builtins (`fn_float_class`, `fn_number_pair`, `fn_bsearch`) and
// dates (`gmtime`, `localtime`, `mktime`, `strftime`, `strflocaltime`, `strptime`).

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import core_pkg "../core"
import "../core/rules"

// ---- Numbers

// The number `v` is, or jq's error for a value that is not one.
number_arg :: #force_inline proc(ip: ^Interp, v: core_pkg.Value) -> (Num, Signal) {
	n, ok := number_of(v)
	if !ok {
		return {}, fail(ip, "%s (%s) number required", type_name(v), brief(ip, v))
	}
	return n, .Go
}

// isinfinite, isnan and isnormal.
fn_float_class :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (core_pkg.Value, Signal) {
	n, ok := number_of(v)
	classes: bit_set[math.Float_Class] = {.Inf, .Neg_Inf} if name == "isinfinite" else ({.NaN} if name == "isnan" else {.Normal})
	return ok && math.classify(n.f) in classes, .Go
}

// frexp, modf and lgamma_r: a number's two parts, as an array.
fn_number_pair :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (result: core_pkg.Value, sig: Signal) {
	n := number_arg(ip, v) or_return
	p, q: f64
	switch name {
	case "frexp":
		e: libc.int
		p = libc.frexp(n.f, &e) // as jq calls it: -0 keeps its sign
		q = f64(e)
	case "modf":
		q, p = math.modf(n.f)
		if math.is_inf(n.f) {
			p, q = math.copy_sign(0, n.f), n.f // C's modf of an infinity: a zero fraction, not inf - inf
		}
	case:
		_, sign := math.lgamma(n.f)
		p, q = libc.lgamma(n.f), f64(sign)
	}
	a := core_pkg.new_array(2)
	append(&a.items, num(p), num(q))
	return a, .Go
}

// The index of `args[0]` in the sorted input, or -1 - where it would go.
fn_bsearch :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (core_pkg.Value, Signal) {
	if kind(v) != .Array {
		return nil, fail(ip, "%s (%s) cannot be searched from", type_name(v), brief(ip, v))
	}
	lo, hi := 0, length_of(v)
	ip.too_deep = false
	for lo < hi {
		mid := (lo + hi) / 2
		switch c := compare(&ip.too_deep, array_at(v, mid), args[0]); {
		case c < 0:
			lo = mid + 1
		case c > 0:
			hi = mid
		case:
			return num(f64(mid)), compare_failed(ip, false)
		}
	}
	return num(f64(-1 - lo)), compare_failed(ip, false)
}

// ---- Dates, as jq's: libc's broken-down time as [year, month 0-11, day, hours, minutes, seconds, weekday,
// yearday], the seconds with the input's fraction. TZ sets the zone `localtime` and `strflocaltime` read.

// jq's f_gmtime and f_localtime.
@(private = "file")
broken_time :: proc(ip: ^Interp, secs: f64, local: bool) -> (core_pkg.Value, Signal) {
	t := libc.time_t(double_to_i64(secs)) // as C converts a double to time_t on this machine
	tm: libc.tm
	if !(local_tm(ip, t, &tm) if local else utc_time(t, &tm)) {
		return nil, fail(ip, "error converting number of seconds since epoch to datetime")
	}
	return tm_value(tm, f64(tm.tm_sec) + (secs - math.floor(secs))), .Go
}

@(private = "file")
tm_value :: proc(tm: libc.tm, sec: f64) -> ^core_pkg.Array {
	a := core_pkg.new_array(8)
	append(&a.items, num(f64(tm.tm_year) + 1900), num(f64(tm.tm_mon)), num(f64(tm.tm_mday)), num(f64(tm.tm_hour)), num(f64(tm.tm_min)), num(sec), num(f64(tm.tm_wday)), num(f64(tm.tm_yday)))
	return a
}

// jq's jv2tm: up to eight numbers, each clamped to a C int, normalized by mktime as local time or by timegm
// as UTC.
@(private = "file")
tm_of :: proc(ip: ^Interp, v: core_pkg.Value, local: bool) -> (tm: libc.tm, z: Zone, ok: bool) {
	fields := [8]^libc.int{&tm.tm_year, &tm.tm_mon, &tm.tm_mday, &tm.tm_hour, &tm.tm_min, &tm.tm_sec, &tm.tm_wday, &tm.tm_yday}
	for x, i in elements(v)[:min(8, length_of(v))] {
		n, is_num := number_of(x)
		if !is_num || math.is_nan(n.f) {
			return {}, {}, false
		}
		d := n.f - 1900 if i == 0 else n.f
		fields[i]^ = libc.int(clamp(d, f64(min(libc.int)), f64(max(libc.int))))
	}
	if local {
		tm.tm_isdst = -1
		if z, ok = local_mktime_in(ip, &tm); !ok {
			return {}, {}, false
		}
	} else {
		timegm(&tm)
	}
	return tm, z, true
}

fn_gmtime :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (core_pkg.Value, Signal) {
	n, ok := number_of(v)
	if !ok {
		return nil, fail(ip, "%s() requires numeric inputs", name)
	}
	return broken_time(ip, n.f, name == "localtime")
}

fn_mktime :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (core_pkg.Value, Signal) {
	if kind(v) != .Array {
		return nil, fail(ip, "mktime requires array inputs")
	}
	tm, _, ok := tm_of(ip, v, false)
	if !ok {
		return nil, fail(ip, "mktime requires parsed datetime inputs")
	}
	t := timegm(&tm)
	if t == -1 {
		return nil, fail(ip, "invalid gmtime representation")
	}
	return num(f64(t)), .Go
}

// strftime and strflocaltime: a number is read as `gmtime` or `localtime` reads it.
fn_strftime :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (core_pkg.Value, Signal) {
	local := name == "strflocaltime"
	v := v
	if n, is_num := number_of(v); is_num {
		sig: Signal
		if v, sig = broken_time(ip, n.f, local); sig != .Go {
			return nil, sig
		}
	} else if kind(v) != .Array {
		return nil, fail(ip, "%s/1 requires parsed datetime inputs", name)
	}
	f, is_str := string_of(args[0])
	if !is_str {
		return nil, fail(ip, "%s/1 requires a string format", name)
	}
	tm, z, ok := tm_of(ip, v, local)
	if !ok {
		return nil, fail(ip, "%s/1 requires parsed datetime inputs", name)
	}
	// As jq, C's format ends at a NUL, and an output past 100 bytes more than it is a failure.
	format := strings.clone_to_cstring(f, context.temp_allocator)
	buf := make([]byte, len(format) + 100)
	n: uint
	switch {
	case !local:
		n = strftime_in(buf, format, &tm, 0, "UTC", ODIN_OS == .Windows)
	case ip.hooks.zone != nil:
		n = strftime_in(buf, format, &tm, z.offset, z.name, true)
	case:
		n = c_strftime(buf, format, &tm)
	}
	if n == 0 && len(format) > 0 {
		return nil, fail(ip, "%s/1: unknown system failure", name)
	}
	return string(buf[:n]), .Go
}

// libc's strftime with the fields read in the zone `offset` seconds east of UTC, and for UTC on every OS, as with TZ
// set to UTC for the call (jq does that on macOS only and reads them as local time elsewhere). The C library reads the
// process's zone for `%s` and `%z`, and the UCRT for `%Z` too, so each conversion the C library would read as one of
// those is written here, padded as it pads a number, `%Z` as `name` when `named`. Any other conversion, and a spelling
// it reads as none, goes to it as written.
@(private = "file")
strftime_in :: proc(buf: []byte, format: cstring, tm: ^libc.tm, offset: int, name: string, named: bool) -> uint {
	f := string(format)
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(f); {
		if f[i] != '%' {
			strings.write_byte(&b, f[i])
			i += 1
			continue
		}
		letter, pad, width, n := conversion(f[i:])
		switch {
		case letter == 's':
			t := tm^
			put_padded(&b, "", i64(timegm(&t)) - i64(offset), width, pad)
		case letter == 'z':
			hhmm := i64(abs(offset) / 3600 * 100 + abs(offset) % 3600 / 60)
			put_padded(&b, "+", -hhmm if offset < 0 else hhmm, max(width - 1, 4), pad)
		case letter == 'Z' && named:
			strings.write_string(&b, name)
		case:
			strings.write_string(&b, f[i:][:max(n, 1)])
		}
		i += max(n, 1)
	}
	return c_strftime(buf, strings.to_cstring(&b) or_else format, tm)
}

// The conversion `f` opens with its `%`, as the C library reads it: its letter, the byte it pads a number with (0 for
// none), its width, and its length, or 0 for a spelling it reads as no conversion. glibc takes the flags `_-0^#`, a
// width and `E` or `O`. macOS takes any `E` and `O` and one of `_-0`, and no width. The UCRT takes `#`, `E` and `O`.
@(private = "file")
conversion :: proc(f: string) -> (letter, pad: byte, width, n: int) {
	pad = '0'
	i := 1
	when ODIN_OS == .Windows {
		for i < len(f) && strings.index_byte("#EO", f[i]) >= 0 {
			i += 1
		}
	} else when ODIN_OS == .Darwin {
		padded := false
		for ; i < len(f); i += 1 {
			if c := f[i]; !padded && strings.index_byte("_-0", c) >= 0 {
				pad, padded = pad_of(c), true
			} else if c != 'E' && c != 'O' {
				break
			}
		}
	} else {
		for ; i < len(f) && strings.index_byte("_-0^#", f[i]) >= 0; i += 1 {
			pad = pad_of(f[i]) if strings.index_byte("_-0", f[i]) >= 0 else pad
		}
		for ; i < len(f) && '0' <= f[i] && f[i] <= '9'; i += 1 {
			width = 10 * width + int(f[i] - '0')
		}
		if i < len(f) && (f[i] == 'E' || f[i] == 'O') {
			i += 1
		}
	}
	if i == len(f) {
		return 0, 0, 0, len(f)
	}
	return f[i], pad, width, i + 1
}

@(private = "file")
pad_of :: proc(flag: byte) -> byte {
	return ' ' if flag == '_' else 0 if flag == '-' else '0'
}

// `n` after `sign`, padded with `pad` to `width` digits, a minus before the padding, or unpadded when `pad` is 0.
@(private = "file")
put_padded :: proc(b: ^strings.Builder, sign: string, n: i64, width: int, pad: byte) {
	digits := fmt.tprintf("%d", abs(n))
	strings.write_string(b, "-" if n < 0 else sign)
	for _ in len(digits) ..< (width if pad != 0 else 0) {
		strings.write_byte(b, pad)
	}
	strings.write_string(b, digits)
}

// jq's f_strptime: what the format does not read is kept as a ninth element, if it starts with a space.
fn_strptime :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (core_pkg.Value, Signal) {
	s, sok := string_of(v)
	f, fok := string_of(args[0])
	if !sok || !fok {
		return nil, fail(ip, "strptime/1 requires string inputs and arguments")
	}
	input := strings.clone_to_cstring(s, context.temp_allocator)
	format := strings.clone_to_cstring(f, context.temp_allocator)
	tm: libc.tm
	end := strptime(input, format, &tm, ip)
	rest := string(end)
	if end == nil || len(rest) > 0 && strings.index_byte(" \t\n\v\f\r", rest[0]) < 0 {
		return nil, fail(ip, "date \"%s\" does not match format \"%s\"", input, format)
	}
	// The weekday and yearday are the calendar's for the array's own year, month and day. A day never read is day 0.
	year := i64(tm.tm_year) + 1900
	n := days_from_civil(year, i64(tm.tm_mon) + 1, i64(tm.tm_mday))
	tm.tm_wday = libc.int((n + 4) %% 7) // 1970-01-01 was a Thursday
	tm.tm_yday = libc.int(n - days_from_civil(year, 1, 1))
	r := tm_value(tm, f64(tm.tm_sec))
	if len(rest) > 0 {
		append(&r.items, strings.clone(rest))
	}
	return r, .Go
}

// Days from 1970-01-01 to year y, month m (1-12), day d, by Howard Hinnant's days_from_civil.
days_from_civil :: proc(y, m, d: i64) -> i64 {
	y := y - 1 if m <= 2 else y
	era := math.floor_div(y, 400)
	yoe := y - era * 400
	doy := (153 * (m - 3 if m > 2 else m + 9) + 2) / 5 + d - 1
	return era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
}

// ---- RFC 3339

// fromrfc3339: `YYYY-MM-DDThh:mm:ss[.fraction](Z|+hh:mm|-hh:mm)` as seconds since the epoch, the fraction kept. The
// ABNF's `t` and `z` are read, a space for the `T` is not, and second 60 only at the end of a UTC day.
fn_fromrfc3339 :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (core_pkg.Value, Signal) {
	s, is_str := string_of(v)
	if !is_str {
		return nil, fail(ip, "%s requires string inputs", name)
	}
	seconds, ok := rfc3339_seconds(s)
	if !ok {
		return nil, fail(ip, "date \"%s\" is not an RFC 3339 date-time", s)
	}
	return num(seconds), .Go
}

@(private = "file")
rfc3339_seconds :: proc(s: string) -> (seconds: f64, ok: bool) {
	p := rules.date_time_of(s) or_return
	fraction := 0.0
	if s[19] == '.' {
		end := 20
		for s[end] >= '0' && s[end] <= '9' {
			end += 1
		}
		fraction, _ = strconv.parse_f64(s[19:end])
	}
	utc := days_from_civil(i64(p.year), i64(p.month), i64(p.day)) * 86400 + i64(p.hour * 3600 + p.minute * 60 + p.second - p.offset * 60)
	return f64(utc) + fraction, true
}

// torfc3339: seconds since the epoch as an RFC 3339 date-time in UTC, years 0000 to 9999. The fraction is written
// only when there is one, with the digits of the number's shortest spelling.
fn_torfc3339 :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (core_pkg.Value, Signal) {
	n, ok := number_of(v)
	if !ok || math.is_nan(n.f) {
		return nil, fail(ip, "%s() requires numeric inputs", name)
	}
	if n.f < -62167219200 || n.f >= 253402300800 {
		return nil, fail(ip, "%s() input is outside the years 0000 to 9999", name)
	}
	spelled: [64]byte
	text := strconv.write_float(spelled[:], math.abs(n.f), 'f', -1, 64)
	text = text[1:] // past the sign
	whole, _, fraction := strings.partition(text, ".")
	secs, _ := strconv.parse_i64(whole)
	if n.f < 0 {
		// Floor: the fraction is what the negative number lacks to the next whole second.
		secs = -secs
		if fraction != "" {
			secs -= 1
			complement := make([]byte, len(fraction), context.temp_allocator)
			for c, i in transmute([]byte)fraction {
				complement[i] = '0' + (9 if i < len(fraction) - 1 else 10) - (c - '0')
			}
			fraction = string(complement)
		}
	}
	days := math.floor_div(secs, 86400)
	rest := secs - days * 86400
	tm: libc.tm
	utc_time(libc.time_t(secs), &tm)
	b := strings.builder_make()
	fmt.sbprintf(&b, "%04d-%02d-%02dT%02d:%02d:%02d", int(tm.tm_year) + 1900, int(tm.tm_mon) + 1, int(tm.tm_mday), rest / 3600, rest % 3600 / 60, rest % 60)
	if fraction != "" {
		strings.write_byte(&b, '.')
		strings.write_string(&b, fraction)
	}
	strings.write_byte(&b, 'Z')
	return strings.to_string(b), .Go
}

// ---- Number format

// numfmt(spec): a number as text by a printf-like spec, `%[flags][width][.precision]conversion` between literal text
// (`%%` is a percent sign). The conversions are `d` (the number cut toward zero), `f` and `e`; the flags are `,`
// (thousands separators), `0` (pad with zeros) and `-` (pad on the right).
fn_numfmt :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (result: core_pkg.Value, sig: Signal) {
	n := number_arg(ip, v) or_return
	spec, is_str := string_of(args[0])
	if !is_str {
		return nil, fail(ip, "numfmt format must be a string")
	}
	if math.is_nan(n.f) || math.is_inf(n.f) {
		return nil, fail(ip, "numfmt requires a finite number")
	}
	b := strings.builder_make()
	converted := false
	for i := 0; i < len(spec); i += 1 {
		if spec[i] != '%' {
			strings.write_byte(&b, spec[i])
			continue
		}
		if i + 1 < len(spec) && spec[i + 1] == '%' {
			strings.write_byte(&b, '%')
			i += 1
			continue
		}
		used, valid := write_number_conversion(&b, spec[i + 1:], n.f)
		if !valid || converted {
			return nil, fail(ip, "numfmt: invalid format \"%s\"", spec)
		}
		converted = true
		i += used
	}
	if !converted {
		return nil, fail(ip, "numfmt: invalid format \"%s\"", spec)
	}
	return strings.to_string(b), .Go
}

// The conversion `spec` starts with, after its `%`, written for `x` onto `b`, and the bytes it took.
@(private = "file")
write_number_conversion :: proc(b: ^strings.Builder, spec: string, x: f64) -> (used: int, ok: bool) {
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
	}
	if used < len(spec) && spec[used] == '.' {
		used += 1
		precision = 0
		for ; used < len(spec) && spec[used] >= '0' && spec[used] <= '9'; used += 1 {
			precision = precision * 10 + int(spec[used] - '0')
		}
	}
	if used >= len(spec) || width > 1000 || precision > 100 {
		return 0, false
	}
	conversion := spec[used]
	used += 1
	spelled: [512]byte
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
	sign := "-" if text[0] == '-' else ""
	text = text[1:]
	if conversion == 'd' && text == "0" {
		sign = "" // a truncated -0.5 is 0
	}
	if thousands && conversion != 'e' {
		whole := text[:strings.index_byte(text, '.')] if strings.contains_rune(text, '.') else text
		grouped := strings.builder_make(context.temp_allocator)
		for c, k in transmute([]byte)whole {
			if k > 0 && (len(whole) - k) % 3 == 0 {
				strings.write_byte(&grouped, ',')
			}
			strings.write_byte(&grouped, c)
		}
		text = strings.concatenate({strings.to_string(grouped), text[len(whole):]}, context.temp_allocator)
	}
	pad := max(0, width - len(sign) - len(text))
	switch {
	case left:
		strings.write_string(b, sign)
		strings.write_string(b, text)
		strings.write_string(b, strings.repeat(" ", pad, context.temp_allocator))
	case zero_pad:
		strings.write_string(b, sign)
		strings.write_string(b, strings.repeat("0", pad, context.temp_allocator))
		strings.write_string(b, text)
	case:
		strings.write_string(b, strings.repeat(" ", pad, context.temp_allocator))
		strings.write_string(b, sign)
		strings.write_string(b, text)
	}
	return used, true
}
