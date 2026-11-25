package query_test

import "core:testing"
import "stury:lib/query"
import "stury:testkit"

// The calendar: Unix seconds to broken-down time and back, strftime and strptime in the C locale, RFC 3339, and the
// zone a caller names. No query language is involved.

@(private = "file")
broken_json :: proc(h: ^query.Heap, secs: f64, zones := query.Zones{}, local := false) -> string {
	v, s := query.break_time(h, query.double_value(secs), zones, local)
	if s != .Ok {
		query.clear_error(h)
		return "<error>"
	}
	defer query.release(h, v)
	return as_json(h, v)
}

@(private = "file")
formatted :: proc(h: ^query.Heap, tm: query.Value, format: string, zones := query.Zones{}, local := false) -> string {
	v, s := query.format_time(h, tm, query.text_borrowed(format), zones, local)
	if s != .Ok {
		e := query.take_error(h)
		defer query.destroy_error(h, &e)
		return e.detail
	}
	defer query.release(h, v)
	return query.text_of(v)
}

@(private = "file")
parsed :: proc(h: ^query.Heap, text, format: string) -> string {
	v, s := query.parse_time(h, query.text_borrowed(text), query.text_borrowed(format), {})
	if s != .Ok {
		e := query.take_error(h)
		defer query.destroy_error(h, &e)
		return e.detail
	}
	defer query.release(h, v)
	return as_json(h, v)
}

@(test)
seconds_break_down_on_the_gregorian_calendar :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	testing.expect_value(t, broken_json(h, 0), "[1970,0,1,0,0,0,4,0]")
	testing.expect_value(t, broken_json(h, 1425599507), "[2015,2,5,23,51,47,4,63]")
	testing.expect_value(t, broken_json(h, 1425599507.25), "[2015,2,5,23,51,47.25,4,63]")
	testing.expect_value(t, broken_json(h, -1.5), "[1969,11,31,23,59,59.5,3,364]")
	testing.expect_value(t, broken_json(h, -62167219200), "[0,0,1,0,0,0,6,0]")
	testing.expect_value(t, broken_json(h, 951782400), "[2000,1,29,0,0,0,2,59]")
	testing.expect_value(t, broken_json(h, 1e12), "[33658,8,27,1,46,40,5,269]")
	testing.expect_value(t, broken_json(h, 1e18), "<error>")
	testing.expect_value(t, broken_json(h, 1e300), "<error>")
}

@(test)
broken_down_time_names_its_instant_again :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	for secs := i64(-3_000_000_000); secs < 5_000_000_000; secs += 86_399 * 97 + 13 {
		if secs == -1 || secs == -2 {
			continue
		}
		tm, s := query.break_time(h, query.int_value(secs), {}, false)
		testing.expect(t, s == .Ok)
		back, s2 := query.make_time(h, tm)
		testing.expect(t, s2 == .Ok)
		testing.expectf(t, query.as_f64(back) == f64(secs), "%d came back as %v", secs, query.as_f64(back))
		query.release(h, tm)
		query.release(h, back)
	}
	// A time past its fields is normalized: the 32nd of month 13.
	doc := read_json(t, h, "[2024,13,32,25,61,61]")
	defer query.release(h, doc)
	secs, s := query.make_time(h, doc)
	testing.expect(t, s == .Ok)
	testing.expect_value(t, query.as_f64(secs), 1741140121)
	testing.expect_value(t, formatted(h, doc, "%Y-%m-%d %H:%M:%S"), "2025-03-05 02:02:01")
}

@(test)
instants_one_and_two_seconds_before_the_epoch_have_no_representation :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	for text, want in ([]string{"[1969,11,31,23,59,59]", "[1969,11,31,23,59,58]", "[1969,11,31,23,59,57]"}) {
		doc := read_json(t, h, text)
		secs, s := query.make_time(h, doc)
		if want < 2 {
			testing.expect_value(t, s, query.Status.Error)
			e := query.take_error(h)
			testing.expect_value(t, e.op, query.Op.Time)
			query.destroy_error(h, &e)
		} else {
			testing.expect_value(t, s, query.Status.Ok)
			testing.expect_value(t, query.as_f64(secs), -3)
		}
		query.release(h, doc)
	}
}

@(test)
strftime_writes_the_c_locale_conversions :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	at := query.int_value(1700000000)
	testing.expect_value(t, formatted(h, at, "%j %a %A %b %B %h %U %W %V %G %g %u %w"), "318 Tue Tuesday Nov November Nov 46 46 46 2023 23 2 2")
	testing.expect_value(t, formatted(h, at, "%e|%k|%l|%I|%p|%P|%y|%C|%m|%d|%H|%M|%S"), "14|22|10|10|PM|pm|23|20|11|14|22|13|20")
	testing.expect_value(t, formatted(h, at, "%D %F %T %R %r %x %X"), "11/14/23 2023-11-14 22:13:20 22:13 10:13:20 PM 11/14/23 22:13:20")
	testing.expect_value(t, formatted(h, at, "%c"), "Tue Nov 14 22:13:20 2023")
	testing.expect_value(t, formatted(h, at, "%Z %z %s %% %n%t|"), "UTC +0000 1700000000 % \n\t|")
	// An ISO week that belongs to the year before, and one that belongs to the year after.
	testing.expect_value(t, formatted(h, query.int_value(1104537600), "%G-W%V-%u"), "2004-W53-6")
	testing.expect_value(t, formatted(h, query.int_value(1230681600), "%G-W%V-%u"), "2009-W01-3")
	// Flags, widths and modifiers.
	date := query.int_value(1425599507)
	testing.expect_value(t, formatted(h, date, "%-d/%-m %_H|%5d|%^b|%#b|%10A|%3H"), "5/3 23|00005|MAR|MAR|  Thursday|023")
	testing.expect_value(t, formatted(h, date, "%Ey %Od %Ex"), "15 05 03/05/15")
	// What no conversion reads is copied.
	testing.expect_value(t, formatted(h, date, "%Q %Ed %"), "%Q %Ed %")
	// Year 0, and a year of five digits.
	testing.expect_value(t, formatted(h, query.int_value(1e12), "%Y %C %y"), "33658 336 58")
	// A result past the format and 100 bytes, and an empty one for a format that is not, fail.
	testing.expect_value(t, formatted(h, query.int_value(0), "%c%c%c%c%c"), query.TIME_FAILURE)
	testing.expect_value(t, formatted(h, query.int_value(0), ""), "")
	testing.expect_value(t, formatted(h, query.int_value(0), "a\x00b"), "a")
}

@(test)
strftime_refuses_what_is_no_time_or_no_format :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	text := query.text_borrowed("x")
	testing.expect_value(t, formatted(h, text, "%Y"), query.TIME_DATETIME)
	bad := read_json(t, h, `[1,2,"a"]`)
	defer query.release(h, bad)
	testing.expect_value(t, formatted(h, bad, "%Y"), query.TIME_DATETIME)
	v, s := query.format_time(h, query.int_value(0), query.int_value(1), {}, false)
	testing.expect_value(t, s, query.Status.Error)
	e := query.take_error(h)
	testing.expect_value(t, e.detail, query.TIME_FORMAT)
	query.destroy_error(h, &e)
	query.release(h, v)
}

@(test)
strptime_reads_the_c_locale_conversions :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	testing.expect_value(t, parsed(h, "2015-03-05T23:51:47Z", "%Y-%m-%dT%H:%M:%SZ"), "[2015,2,5,23,51,47,4,63]")
	testing.expect_value(t, parsed(h, "2015-03-05T23:51:47Z abc", "%Y-%m-%dT%H:%M:%SZ"), `[2015,2,5,23,51,47,4,63," abc"]`)
	testing.expect_value(t, parsed(h, "2015-03-05T23:51:47Zabc", "%Y-%m-%dT%H:%M:%SZ"), query.TIME_MISMATCH)
	testing.expect_value(t, parsed(h, "Thu Nov 14 22:13:20 2023", "%c"), "[2023,10,14,22,13,20,4,317]")
	testing.expect_value(t, parsed(h, "january 5 2024", "%B %e %Y"), "[2024,0,5,0,0,0,5,4]")
	testing.expect_value(t, parsed(h, "2024-01-01 12:00:00 AM", "%F %I:%M:%S %p"), "[2024,0,1,0,0,0,1,0]")
	testing.expect_value(t, parsed(h, "2024-01-01 12:30:00 PM", "%F %I:%M:%S %p"), "[2024,0,1,12,30,0,1,0]")
	testing.expect_value(t, parsed(h, "2015 060", "%Y %j"), "[2015,2,1,0,0,0,0,59]")
	testing.expect_value(t, parsed(h, "12/31/99", "%D"), "[1999,11,31,0,0,0,5,364]")
	testing.expect_value(t, parsed(h, "68", "%y"), "[2068,0,0,0,0,0,6,-1]")
	testing.expect_value(t, parsed(h, "69", "%y"), "[1969,0,0,0,0,0,2,-1]")
	testing.expect_value(t, parsed(h, "20 12", "%C %y"), "[2012,0,0,0,0,0,6,-1]")
	// A day the month lacks is kept, and the weekday is the calendar's for it.
	testing.expect_value(t, parsed(h, "2024-02-30", "%Y-%m-%d"), "[2024,1,30,0,0,0,5,60]")
	// What is not read is a day 0, and a weekday and day of the year the format did not set are the sentinels 8 and 367.
	testing.expect_value(t, parsed(h, "12:30:00", "%T"), "[1900,0,0,12,30,0,8,367]")
	testing.expect_value(t, parsed(h, "+0530", "%z"), "[1900,0,0,0,0,0,8,367]")
	testing.expect_value(t, parsed(h, "x", "%d"), query.TIME_MISMATCH)
	testing.expect_value(t, parsed(h, "32", "%d"), query.TIME_MISMATCH)
	testing.expect_value(t, parsed(h, "1", "%Q"), query.TIME_MISMATCH)
	testing.expect_value(t, parsed(h, "1", "%"), query.TIME_MISMATCH)
	testing.expect_value(t, parsed(h, "060", "%j"), "[1900,0,0,0,0,0,8,59]")
	testing.expect_value(t, parsed(h, "Thu", "%a"), "[1900,0,0,0,0,0,4,367]")
	testing.expect_value(t, parsed(h, "2024 02 Mon", "%Y %U %a"), "[2024,0,15,0,0,0,1,14]")
	// A weekday name is read and kept, whatever the calendar says.
	testing.expect_value(t, parsed(h, "Monday 2024-01-01", "%A %F"), "[2024,0,1,0,0,0,1,0]")
}

@(test)
a_zone_names_local_time :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	// A zone five and a half hours east, named "IST".
	zones := query.Zones {
		at = proc(data: rawptr, secs: i64) -> (query.Zone, bool) {
			return {offset = 5 * 3600 + 1800, name = "IST"}, true
		},
	}
	testing.expect_value(t, broken_json(h, 0, zones, true), "[1970,0,1,5,30,0,4,0]")
	testing.expect_value(t, broken_json(h, 0, zones, false), "[1970,0,1,0,0,0,4,0]")
	at := query.int_value(86400 * 365)
	testing.expect_value(t, formatted(h, at, "%H:%M %Z %z %s", zones, true), "05:30 IST +0530 31536000")
	wall := read_json(t, h, "[1971,0,1,5,30,0]")
	defer query.release(h, wall)
	testing.expect_value(t, formatted(h, wall, "%s %Z", zones, true), "31536000 IST")
	testing.expect_value(t, formatted(h, wall, "%s %Z", {}, true), "31555800 UTC")
}

@(test)
rfc3339_reads_and_writes_date_times :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	seconds :: proc(h: ^query.Heap, text: string) -> string {
		v, s := query.rfc3339_seconds(h, query.text_borrowed(text))
		if s != .Ok {
			query.clear_error(h)
			return "<error>"
		}
		defer query.release(h, v)
		return as_json(h, v)
	}
	text :: proc(h: ^query.Heap, secs: f64) -> string {
		v, s := query.rfc3339_text(h, query.double_value(secs))
		if s != .Ok {
			query.clear_error(h)
			return "<error>"
		}
		defer query.release(h, v)
		return query.text_of(v)
	}
	testing.expect_value(t, seconds(h, "2015-03-05T23:51:47Z"), "1425599507")
	testing.expect_value(t, seconds(h, "2024-06-01T12:34:56.123+02:00"), "1717238096.123")
	testing.expect_value(t, seconds(h, "1969-12-31T23:59:58.5-00:00"), "-1.5")
	testing.expect_value(t, seconds(h, "2016-12-31T23:59:60Z"), "1483228800")
	testing.expect_value(t, seconds(h, "2016-12-31T23:59:60-01:00"), "<error>")
	testing.expect_value(t, seconds(h, "2016-12-31T22:59:60-01:00"), "1483228800")
	testing.expect_value(t, seconds(h, "2015-03-05 23:51:47Z"), "<error>")
	testing.expect_value(t, seconds(h, "2015-02-29T00:00:00Z"), "<error>")
	testing.expect_value(t, seconds(h, "2016-02-29T00:00:00Z"), "1456704000")
	testing.expect_value(t, seconds(h, "2015-03-05T23:51:47"), "<error>")
	testing.expect_value(t, seconds(h, "2015-03-05T24:00:00Z"), "<error>")
	testing.expect_value(t, seconds(h, "2015-03-05T23:51:47.Z"), "<error>")
	testing.expect_value(t, text(h, 1425599507), "2015-03-05T23:51:47Z")
	testing.expect_value(t, text(h, 1717238096.123), "2024-06-01T10:34:56.123Z")
	testing.expect_value(t, text(h, -1.5), "1969-12-31T23:59:58.5Z")
	testing.expect_value(t, text(h, -62167219200), "0000-01-01T00:00:00Z")
	testing.expect_value(t, text(h, 253402300799), "9999-12-31T23:59:59Z")
	testing.expect_value(t, text(h, 253402300800), "<error>")
}

@(test)
a_sorted_array_is_searched_by_halves :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	sorted := read_json(t, h, "[0,0,1,2,2,2,3,4,4,4,6,6,6]")
	defer query.release(h, sorted)
	for target in ([]i64{-1, 0, 1, 5, 7}) {
		at, s := query.search_sorted(h, sorted, query.int_value(target))
		testing.expect(t, s == .Ok)
		switch target {
		case -1:
			testing.expect_value(t, at, -1)
		case 0:
			testing.expect_value(t, at, 1)
		case 1:
			testing.expect_value(t, at, 2)
		case 5:
			testing.expect_value(t, at, -11)
		case 7:
			testing.expect_value(t, at, -14)
		}
	}
	text := query.text_borrowed("aa")
	_, s := query.search_sorted(h, text, query.int_value(0))
	testing.expect_value(t, s, query.Status.Error)
	e := query.take_error(h)
	testing.expect_value(t, e.op, query.Op.Search)
	query.destroy_error(h, &e)
}
