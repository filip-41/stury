package spell_tests

import "core:testing"
import "core:time"
import "stury:lib/base/spell"
import "stury:testkit"

// RFC 3339 date-times read, and a text that breaks the grammar or names no day or time is refused.
@(test)
date_times_follow_rfc_3339 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	good := []string{
		"2013-03-21T20:04:00Z",
		"2013-03-21t20:04:00z",
		"2013-03-21T20:04:00-00:00",
		"2013-03-21T20:04:00+23:59",
		"2013-03-21T20:04:00-23:59",
		"2024-02-29t23:59:60.5+00:00",
		"1990-12-31T15:59:60-08:00",
		"1991-01-01T00:00:60+00:01",
		"2024-01-01T23:58:60+23:59",
		"2024-01-01T00:00:60-23:59",
		"2000-01-01T00:00:00.123456789123+01:30",
		"0000-02-29T00:00:00Z",
		"9999-12-31T23:59:59Z",
	}
	bad := []string{
		"",
		"2013-03-21",
		"2013-03-21T20:04:00",
		"2013-03-21T20:04Z",
		"2013-02-29T00:00:00Z",
		"1900-02-29T00:00:00Z",
		"2013-13-01T00:00:00Z",
		"2013-03-21T24:00:00Z",
		"2013-03-21T20:60:00Z",
		"2013-03-21T20:04:61Z",
		"2013-03-21T20:04:00.",
		"2013-03-21T20:04:00.Z",
		"2013-03-21T20:04:00.5",
		"2013-03-21T20:04:60Z",
		"2024-01-01T23:59:60+00:01",
		"2024-01-01T23:59:60-23:59",
		"2013-03-21 20:04:00Z",
		"2013-03-21T20:04:00+0100",
		"2013-03-21T20:04:00+24:00",
		"2013-03-21T20:04:00-24:00",
		"2013-03-21T20:04:00+00:60",
		"2013-03-21T20:04:00Z ",
		"2013-03-21T20:04:00+01:000",
	}
	for s in good {
		ok := spell.is_date_time(s)
		testing.expectf(t, ok, "%q", s)
	}
	for s in bad {
		ok := spell.is_date_time(s)
		testing.expectf(t, !ok, "%q", s)
	}
}

// RFC 3339 full-dates enforce proleptic Gregorian leap years and month lengths across 0000..9999.
@(test)
full_dates_follow_rfc_3339 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	good := []string{
		"0000-01-01",
		"0000-02-29",
		"1900-02-28",
		"2000-02-29",
		"2024-02-29",
		"2100-02-28",
		"2400-02-29",
		"2024-04-30",
		"2024-07-31",
		"2024-08-31",
		"9999-12-31",
	}
	bad := []string{
		"",
		"2024-01-1",
		"2024-01-01 ",
		"2024/01/01",
		"2024-00-01",
		"2024-13-01",
		"2024-01-00",
		"2024-01-32",
		"1900-02-29",
		"2100-02-29",
		"2023-02-29",
		"2024-04-31",
		"2024-06-31",
		"2024-09-31",
		"2024-11-31",
		"202a-01-01",
		"2024-0a-01",
		"2024-01-0a",
	}
	for s in good {
		ok := spell.is_full_date(s)
		testing.expectf(t, ok, "%q", s)
	}
	for s in bad {
		ok := spell.is_full_date(s)
		testing.expectf(t, !ok, "%q", s)
	}
}

// `date_time_nsec` converts UTC offsets, sub-nanosecond truncation, leap seconds, and >64-byte space-separated inputs.
@(test)
date_time_nsec_converts_valid_instants :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		text: string,
		want: i64,
	}
	cases := []Case{
		{"1970-01-01T00:00:00Z", 0},
		{"1970-01-01t00:00:00z", 0},
		{"1970-01-01T00:00:00-00:00", 0},
		{"1970-01-01 00:00:00+00:00", 0},
		{"1969-12-31T23:59:59Z", -1_000_000_000},
		{"1970-01-01T00:00:00.5Z", 500_000_000},
		{"1970-01-01T00:00:00.05Z", 50_000_000},
		{"1970-01-01T00:00:00.000000001Z", 1},
		{"1970-01-01T00:00:00.0000000009Z", 0},
		{"1970-01-01T00:00:00.1234567899Z", 123_456_789},
		{"1970-01-01T23:59:00+23:59", 0},
		{"1969-12-31T00:01:00-23:59", 0},
		{"1979-05-27T07:32:00-08:00", 296_667_120_000_000_000},
		{"1979-05-27 00:32:00.5+07:00", 296_587_920_500_000_000},
		// Leap seconds map to 00:00:00[.frac] of the next day in UTC.
		{"1990-12-31T23:59:60Z", 662_688_000_000_000_000},
		{"1990-12-31T15:59:60-08:00", 662_688_000_000_000_000},
		{"1991-01-01T00:00:60+00:01", 662_688_000_000_000_000},
		{"2024-02-29T23:59:60.5+00:00", 1_709_251_200_500_000_000},
		// Space-separated timestamps longer than 64 bytes.
		{"2024-01-01 00:00:00.0000000000000000000000000000000000000000000001Z", 1_704_067_200_000_000_000},
		{"2024-01-01 00:00:00.123456789999999999999999999999999999999999999+00:00", 1_704_067_200_123_456_789},
	}
	for c in cases {
		nsec, spelled, in_range := spell.date_time_nsec(c.text)
		testing.expectf(t, spelled && in_range && nsec == c.want, "%q: got (%d, %v, %v), want %d", c.text, nsec, spelled, in_range, c.want)
	}
	// Invalid spellings return (0, false, false).
	for bad in ([]string{"", "2024-01-01", "2024-01-01T00:00:00.", "2024-01-01T00:00:60Z", "1979-05-27T07:32Z"}) {
		nsec, spelled, in_range := spell.date_time_nsec(bad)
		testing.expectf(t, nsec == 0 && !spelled && !in_range, "%q: got (%d, %v, %v)", bad, nsec, spelled, in_range)
	}
	// Cross-check calendar math against `core:time.components_to_time` across leap and century boundaries.
	check_dates := []struct {
		text: string,
		y, m, d: int,
	}{
		{"1678-01-01T00:00:00Z", 1678, 1, 1},
		{"1700-03-01T00:00:00Z", 1700, 3, 1},
		{"1800-02-28T00:00:00Z", 1800, 2, 28},
		{"1900-03-01T00:00:00Z", 1900, 3, 1},
		{"1969-12-31T00:00:00Z", 1969, 12, 31},
		{"1970-01-01T00:00:00Z", 1970, 1, 1},
		{"2000-02-29T00:00:00Z", 2000, 2, 29},
		{"2000-03-01T00:00:00Z", 2000, 3, 1},
		{"2100-03-01T00:00:00Z", 2100, 3, 1},
		{"2200-02-28T00:00:00Z", 2200, 2, 28},
		{"2261-12-31T00:00:00Z", 2261, 12, 31},
	}
	for c in check_dates {
		want_t, ok := time.components_to_time(c.y, c.m, c.d, 0, 0, 0, 0)
		testing.expectf(t, ok, "%q", c.text)
		got, spelled, in_range := spell.date_time_nsec(c.text)
		testing.expectf(t, spelled && in_range && got == want_t._nsec, "%q: got %d, want %d", c.text, got, want_t._nsec)
	}
}

// `date_time_nsec` covers the full `[min(i64), max(i64)]` UTC range, including offset-shifted instants.
@(test)
date_time_nsec_bounds_exact_i64_range :: proc(t: ^testing.T) {
	testkit.deadline(t)
	in_cases := []struct {
		text: string,
		want: i64,
	}{
		{"1677-09-21T00:12:43.145224192Z", min(i64)},
		{"1677-09-21T00:12:43.999999999Z", -9_223_372_036_000_000_001},
		{"1677-09-21T00:12:44Z", -9_223_372_036_000_000_000},
		{"2262-04-11T23:47:16.854775807Z", max(i64)},
		// Local time outside i64 bounds, but UTC instant inside bounds.
		{"2262-04-12T00:00:00+01:00", 9_223_369_200_000_000_000},
		{"2262-04-12T23:46:16.854775807+23:59", max(i64)},
		{"1677-09-20T23:00:00-02:00", -9_223_369_200_000_000_000},
		{"1677-09-20T00:13:43.145224192-23:59", min(i64)},
		{"1677-09-20T00:13:44-23:59", -9_223_372_036_000_000_000},
	}
	for c in in_cases {
		nsec, spelled, in_range := spell.date_time_nsec(c.text)
		testing.expectf(t, spelled && in_range && nsec == c.want, "%q: got (%d, %v, %v), want %d", c.text, nsec, spelled, in_range, c.want)
	}
	out_cases := []string{
		"1677-09-21T00:12:43.145224191Z",
		"1677-09-21T00:12:43Z",
		"1677-09-20T00:13:43.145224191-23:59",
		"2262-04-11T23:47:16.854775808Z",
		"2262-04-12T23:46:16.854775808+23:59",
		"0000-01-01T00:00:00Z",
		"9999-12-31T23:59:59Z",
	}
	for s in out_cases {
		nsec, spelled, in_range := spell.date_time_nsec(s)
		testing.expectf(t, nsec == 0 && spelled && !in_range, "%q: got (%d, %v, %v)", s, nsec, spelled, in_range)
	}
}

// Optional seconds (TOML 1.1) are opt-in on `date_time_nsec` and never accepted by strict `is_date_time`.
@(test)
date_time_nsec_optional_seconds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	want_z, _, _ := spell.date_time_nsec("1979-05-27T07:32:00Z")
	want_off, _, _ := spell.date_time_nsec("1979-05-27T07:32:00+01:00")
	want_frac, _, _ := spell.date_time_nsec("1979-05-27T07:32:15.5Z")

	testing.expect(t, !spell.is_date_time("1979-05-27T07:32Z"))

	nsec, spelled, in_range := spell.date_time_nsec("1979-05-27T07:32Z", optional_seconds = true)
	testing.expectf(t, spelled && in_range && nsec == want_z, "got (%d, %v, %v)", nsec, spelled, in_range)

	nsec, spelled, in_range = spell.date_time_nsec("1979-05-27 07:32+01:00", optional_seconds = true)
	testing.expectf(t, spelled && in_range && nsec == want_off, "got (%d, %v, %v)", nsec, spelled, in_range)

	nsec, spelled, in_range = spell.date_time_nsec("1979-05-27T07:32:15.5Z", optional_seconds = true)
	testing.expectf(t, spelled && in_range && nsec == want_frac, "got (%d, %v, %v)", nsec, spelled, in_range)

	// Fraction without seconds, missing offset, and bad offset still fail when `optional_seconds` is true.
	for bad in ([]string{"1979-05-27T07:32", "1979-05-27T07:32.5Z", "1979-05-27T07:32.1234Z", "1979-05-27T07:32+24:00"}) {
		nsec, spelled, in_range = spell.date_time_nsec(bad, optional_seconds = true)
		testing.expectf(t, nsec == 0 && !spelled && !in_range, "%q: got (%d, %v, %v)", bad, nsec, spelled, in_range)
	}
}
