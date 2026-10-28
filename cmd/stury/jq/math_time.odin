package jq

// Numeric builtins (`fn_abs`, `fn_isinfinite`, `fn_isnan`, `fn_isnormal`, `fn_number_pair`, `fn_bsearch`) and
// dates (`gmtime`, `localtime`, `mktime`, `strftime`, `strflocaltime`, `strptime`).

import "core:c/libc"
import "core:math"
import "core:strings"
import "core:sync"

// ---- Numbers

// jq's `if . < 0 then - . else . end`: null and the booleans sort below 0, and cannot be negated.
fn_abs :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	switch kind(v) {
	case .Number:
		// `. < 0` compares a literal as a decimal, so -1e-400 is below 0 though it is -0.0.
		if n, _ := number_of(v); n.f < 0 || n.f == 0 && n.lit != "" && compare_decimals(n.lit, "0") < 0 {
			return negate(n), .Go
		}
	case .Null, .False, .True:
		return nil, fail(ip, "%s (%s) cannot be negated", type_name(v), brief(v))
	case .String, .Array, .Object:
	}
	return v, .Go
}

fn_isinfinite :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	n, ok := number_of(v)
	return ok && math.is_inf(n.f), .Go
}

fn_isnan :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	n, ok := number_of(v)
	return ok && math.is_nan(n.f), .Go
}

fn_isnormal :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	n, ok := number_of(v)
	return ok && math.classify(n.f) == .Normal, .Go
}

// frexp, modf and lgamma_r: a number's two parts, as an array.
fn_number_pair :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	n, ok := number_of(v)
	if !ok {
		return nil, fail(ip, "%s (%s) number required", type_name(v), brief(v))
	}
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
	a := new_array(2)
	append(&a.items, num(p), num(q))
	return a, .Go
}

// The index of `args[0]` in the sorted input, or -1 - where it would go.
fn_bsearch :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	if kind(v) != .Array {
		return nil, fail(ip, "%s (%s) cannot be searched from", type_name(v), brief(v))
	}
	lo, hi := 0, length_of(v)
	too_deep = false
	for lo < hi {
		mid := (lo + hi) / 2
		switch c := compare(array_at(v, mid), args[0]); {
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

// `secs` as C converts a double to time_t on this machine: truncated toward zero, saturated, NaN as 0.
@(private = "file")
time_of :: proc(secs: f64) -> libc.time_t {
	return libc.time_t(double_to_i64(secs))
}

// jq's f_gmtime and f_localtime.
@(private = "file")
broken_time :: proc(ip: ^Interp, secs: f64, local: bool) -> (Value, Signal) {
	t := time_of(secs)
	tm: libc.tm
	if !(local_time(t, &tm) if local else utc_time(t, &tm)) {
		return nil, fail(ip, "error converting number of seconds since epoch to datetime")
	}
	return tm_value(tm, f64(tm.tm_sec) + (secs - math.floor(secs))), .Go
}

@(private = "file")
tm_value :: proc(tm: libc.tm, sec: f64) -> ^Array {
	a := new_array(8)
	append(&a.items, num(f64(tm.tm_year) + 1900), num(f64(tm.tm_mon)), num(f64(tm.tm_mday)), num(f64(tm.tm_hour)), num(f64(tm.tm_min)), num(sec), num(f64(tm.tm_wday)), num(f64(tm.tm_yday)))
	return a
}

// jq's jv2tm: up to eight numbers, each clamped to a C int, normalized by mktime as local time or by timegm
// as UTC.
@(private = "file")
tm_of :: proc(v: Value, local: bool) -> (tm: libc.tm, ok: bool) {
	fields := [8]^libc.int{&tm.tm_year, &tm.tm_mon, &tm.tm_mday, &tm.tm_hour, &tm.tm_min, &tm.tm_sec, &tm.tm_wday, &tm.tm_yday}
	for x, i in elements(v)[:min(8, length_of(v))] {
		n, is_num := number_of(x)
		if !is_num || math.is_nan(n.f) {
			return {}, false
		}
		d := n.f - 1900 if i == 0 else n.f
		fields[i]^ = libc.int(clamp(d, f64(min(libc.int)), f64(max(libc.int))))
	}
	if local {
		tm.tm_isdst = -1
		local_mktime(&tm)
	} else {
		timegm(&tm)
	}
	return tm, true
}

fn_gmtime :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	n, ok := number_of(v)
	if !ok {
		return nil, fail(ip, "%s() requires numeric inputs", name)
	}
	return broken_time(ip, n.f, name == "localtime")
}

fn_mktime :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	if kind(v) != .Array {
		return nil, fail(ip, "mktime requires array inputs")
	}
	tm, ok := tm_of(v, false)
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
fn_strftime :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
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
	tm, ok := tm_of(v, local)
	if !ok {
		return nil, fail(ip, "%s/1 requires parsed datetime inputs", name)
	}
	// As jq, C's format ends at a NUL, and an output past 100 bytes more than it is a failure.
	format := strings.clone_to_cstring(f, context.temp_allocator)
	buf := make([]byte, len(format) + 100)
	n := c_strftime(buf, format, &tm) if local else strftime_utc(buf, format, &tm)
	if n == 0 && len(format) > 0 {
		return nil, fail(ip, "%s/1: unknown system failure", name)
	}
	return string(buf[:n]), .Go
}

@(private = "file")
tz_lock: sync.Mutex

// libc's strftime with TZ set to UTC for the call, so `%z` and `%s` read the fields as UTC on every OS (jq
// does that on macOS only; elsewhere it reads them as local time).
@(private = "file")
strftime_utc :: proc(buf: []byte, format: cstring, tm: ^libc.tm) -> uint {
	sync.guard(&tz_lock)
	tz := libc.getenv("TZ")
	if tz != nil {
		tz = strings.clone_to_cstring(string(tz), context.temp_allocator)
	}
	set_tz("UTC")
	n := c_strftime(buf, format, tm)
	set_tz(tz)
	return n
}

// jq's f_strptime: what the format does not read is kept as a ninth element, if it starts with a space.
fn_strptime :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	s, sok := string_of(v)
	f, fok := string_of(args[0])
	if !sok || !fok {
		return nil, fail(ip, "strptime/1 requires string inputs and arguments")
	}
	input := strings.clone_to_cstring(s, context.temp_allocator)
	format := strings.clone_to_cstring(f, context.temp_allocator)
	tm: libc.tm
	end := strptime(input, format, &tm)
	rest := string(end)
	if end == nil || len(rest) > 0 && strings.index_byte(" \t\n\v\f\r", rest[0]) < 0 {
		return nil, fail(ip, "date \"%s\" does not match format \"%s\"", input, format)
	}
	// The weekday and yearday are the calendar's for the array's own year, month and day. A day never read is day 0.
	tm.tm_wday, tm.tm_yday = civil_wday_yday(tm)
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

// The weekday (Sunday is 0) and the zero-based day of the year of a date, by integer day counting.
@(private = "file")
civil_wday_yday :: proc(tm: libc.tm) -> (wday, yday: libc.int) {
	year := i64(tm.tm_year) + 1900
	n := days_from_civil(year, i64(tm.tm_mon) + 1, i64(tm.tm_mday))
	wday = libc.int((n + 4) %% 7) // 1970-01-01 was a Thursday
	yday = libc.int(n - days_from_civil(year, 1, 1))
	return
}
