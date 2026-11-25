package query

import "core:math"

// Calendar time on the proleptic Gregorian calendar with no leap seconds, the same on every OS: Unix seconds to
// broken-down time and back, with a zone only where the caller gives one. A broken-down time is an array of eight
// numbers: the year, the month 0 to 11, the day of the month, the hour, the minute, the second (with the fraction
// of the input), the weekday from Sunday as 0, and the day of the year from 0.

// A time zone at one instant.
Zone :: struct {
	offset: i64, // seconds east of UTC
	name:   string, // borrowed from the zone source
}

// Where the local zone comes from: the caller's. Without `at` the zone is UTC.
Zones :: struct {
	data: rawptr,
	// The zone in force at `secs` seconds since the Unix epoch, `ok` false when it cannot be had.
	at:   proc(data: rawptr, secs: i64) -> (zone: Zone, ok: bool),
}

@(private)
UTC :: Zone{name = "UTC"}

// What a time operation's error says in `Error.detail`, with `op` `.Time`.
TIME_NUMBER :: "number" // the input is no number
TIME_ARRAY :: "array" // the input is no array
TIME_DATETIME :: "datetime" // the array is no broken-down time
TIME_FORMAT :: "format" // the format is no string
TIME_STRINGS :: "strings" // the input or the format is no string
TIME_RANGE :: "range" // the instant has no broken-down time
TIME_REPRESENTATION :: "representation" // the broken-down time names no instant
TIME_UNSUPPORTED :: "unsupported" // the instant two seconds before the epoch, which timegm cannot tell from its error value
TIME_MISMATCH :: "mismatch" // text `a` does not read as format `b`
TIME_FAILURE :: "failure" // the formatted text is empty or too long
TIME_RFC3339 :: "rfc3339" // `a` is no RFC 3339 date-time
TIME_YEARS :: "years" // the instant is outside the years 0000 to 9999

@(private)
DAY :: 86400

// A broken-down time with the full year, as the array holds it.
@(private)
Civil :: struct {
	year, mon, mday, hour, min, sec, wday, yday: i64,
}

// Days from 1970-01-01 to year `y`, month `m` 1 to 12, day `d`.
@(private)
days_from_civil :: proc "contextless" (y, m, d: i64) -> i64 {
	y := y - 1 if m <= 2 else y
	era := math.floor_div(y, 400)
	yoe := y - era * 400
	doy := (153 * (m - 3 if m > 2 else m + 9) + 2) / 5 + d - 1
	return era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
}

// The year, month 1 to 12 and day of the month of `days` since 1970-01-01.
@(private)
civil_from_days :: proc "contextless" (days: i64) -> (y, m, d: i64) {
	z := days + 719468
	era := math.floor_div(z, 146097)
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	m = mp + 3 if mp < 10 else mp - 9
	return yoe + era * 400 + (1 if m <= 2 else 0), m, doy - (153 * mp + 2) / 5 + 1
}

@(private)
is_leap_year :: proc "contextless" (y: i64) -> bool {
	return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
}

// Broken-down time of `t` seconds since the epoch, false when the year does not fit a C `int` past 1900.
@(private)
civil_of_seconds :: proc "contextless" (t: i64) -> (c: Civil, ok: bool) {
	if t > 1 << 60 || t < -(1 << 60) {
		return {}, false
	}
	days := math.floor_div(t, DAY)
	rest := t - days * DAY
	y, m, d := civil_from_days(days)
	if y - 1900 > i64(max(i32)) || y - 1900 < i64(min(i32)) {
		return {}, false
	}
	return Civil {
			year = y,
			mon = m - 1,
			mday = d,
			hour = rest / 3600,
			min = rest / 60 % 60,
			sec = rest % 60,
			wday = math.floor_mod(days + 4, 7),
			yday = days - days_from_civil(y, 1, 1),
		},
		true
}

// The seconds since the epoch `c` names, with `c` rewritten as its normal form (month 13 is January of the next
// year), as timegm does. False when the normal form has no year a C `int` holds.
@(private)
civil_normalize :: proc "contextless" (c: ^Civil) -> (t: i64, ok: bool) {
	y := c.year + math.floor_div(c.mon, 12)
	days := days_from_civil(y, math.floor_mod(c.mon, 12) + 1, 1) + c.mday - 1
	t = days * DAY + c.hour * 3600 + c.min * 60 + c.sec
	n := civil_of_seconds(t) or_return
	c^ = n
	return t, true
}

// The zone in force at `secs`, UTC when `zones` has no source.
@(private)
zone_at :: proc(zones: Zones, secs: i64) -> (Zone, bool) {
	if zones.at == nil {
		return UTC, true
	}
	return zones.at(zones.data, secs)
}

// The instant of wall-clock time `c` in the zone of `zones`, with the zone in force then, as mktime finds it: the
// offset at the wall time read as UTC, unless the zone changes between the two.
@(private)
local_instant :: proc(zones: Zones, c: Civil) -> (t: i64, z: Zone, ok: bool) {
	wall := c
	t0 := civil_normalize(&wall) or_return
	z = zone_at(zones, t0) or_return
	t = t0 - z.offset
	if again, found := zone_at(zones, t); found && again.offset != z.offset {
		z = again
		t = t0 - z.offset
	}
	return t, z, true
}

// Broken-down time as its array value: the second carries `frac`, the fraction of the input.
@(private)
civil_value :: proc(h: ^Heap, c: Civil, frac: f64) -> (res: Value, status: Status) {
	out := make_array(h, 8) or_return
	fields := [8]i64{c.year, c.mon, c.mday, c.hour, c.min, c.sec, c.wday, c.yday}
	for n, i in fields {
		x := int_value(n)
		if i == 5 && frac != 0 {
			x = double_value(f64(n) + frac)
		}
		append_owned(h, &out, x) or_return
	}
	return out, .Ok
}

// An instant seen in a zone.
@(private)
Instant :: struct {
	civil: Civil,
	frac:  f64, // the fraction of a second the input had
	zone:  Zone,
	secs:  i64, // whole seconds since the epoch
}

// Number `v`, seconds since the epoch cut toward zero, as an instant in UTC or in the local zone. A number past what
// a year can hold is a `.Range` error.
@(private)
instant_of :: proc(h: ^Heap, v: Value, zones: Zones, local: bool) -> (at: Instant, status: Status) {
	if !is_number(v) {
		return {}, fail(h, .Types, .Time, v, detail = TIME_NUMBER)
	}
	f := as_f64(v)
	at.secs = trunc_i64(v)
	at.frac = f - math.floor(f)
	at.zone = UTC
	ok := true
	if local {
		at.zone, ok = zone_at(zones, at.secs)
	}
	// A second this far out has no year, and its sum with an offset must not wrap.
	if ok && -(1 << 60) <= at.secs && at.secs <= 1 << 60 {
		at.civil, ok = civil_of_seconds(at.secs + at.zone.offset)
	} else {
		ok = false
	}
	if !ok {
		return {}, fail(h, .Range, .Time, v, detail = TIME_RANGE)
	}
	return at, .Ok
}

// The broken-down time of number `v`, seconds since the epoch, in UTC or in the local zone, the fraction kept in
// the seconds.
break_time :: proc(h: ^Heap, v: Value, zones: Zones, local: bool) -> (res: Value, status: Status) {
	at := instant_of(h, v, zones, local) or_return
	return civil_value(h, at.civil, at.frac)
}

// The broken-down time in array `v`, each field a number cut toward zero into a C `int`, a missing one 0 (the year
// 1900) and one past the eighth ignored; false when an element is not a number.
@(private)
civil_of_array :: proc(h: ^Heap, v: Value) -> (c: Civil, ok: bool, status: Status) {
	fields: [8]i64
	for i in 0 ..< min(8, length_of(h, v)) {
		x := element(h, v, i) or_return
		defer release(h, x)
		if !is_number(x) || math.is_nan(as_f64(x)) {
			return {}, false, .Ok
		}
		// The year is the C `int` that counts from 1900.
		d := as_f64(x) - 1900 if i == 0 else as_f64(x)
		fields[i] = i64(clamp(d, f64(min(i32)), f64(max(i32))))
	}
	fields[0] += 1900
	return Civil{fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7]}, true, .Ok
}

// The seconds since the epoch of broken-down time `v`, in UTC, as an integer. A time past a C `int` of years, and
// the instants one and two seconds before the epoch, which timegm cannot tell from its error values, name no instant.
make_time :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	if type_of(v) != .Array {
		return NULL, fail(h, .Types, .Time, v, detail = TIME_ARRAY)
	}
	c, ok := civil_of_array(h, v) or_return
	if !ok {
		return NULL, fail(h, .Types, .Time, v, detail = TIME_DATETIME)
	}
	t, fits := civil_normalize(&c)
	if !fits || t == -1 {
		return NULL, fail(h, .Range, .Time, v, detail = TIME_REPRESENTATION)
	}
	if t == -2 {
		return NULL, fail(h, .Range, .Time, v, detail = TIME_UNSUPPORTED)
	}
	return int_value(t) if abs(t) <= 1 << 53 else double_value(f64(t)), .Ok
}
