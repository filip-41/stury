package spell_tests

import "core:testing"
import "stury:lib/base/spell"
import "stury:testkit"

// RFC 3339 date-times read, and a text that breaks the grammar or names no day or time is refused.
@(test)
date_times_follow_rfc_3339 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	good := []string{"2013-03-21T20:04:00Z", "2024-02-29t23:59:60.5+00:00", "1990-12-31T15:59:60-08:00", "2000-01-01T00:00:00.123456789123+01:30"}
	bad := []string{"2013-03-21", "2013-02-29T00:00:00Z", "2013-13-01T00:00:00Z", "2013-03-21T24:00:00Z", "2013-03-21T20:04:00", "2013-03-21T20:04:00.Z", "2013-03-21T20:04:60Z", "2013-03-21 20:04:00Z", "2013-03-21T20:04:00+0100"}
	for s in good {
		ok := spell.is_date_time(s)
		testing.expectf(t, ok, "%q", s)
	}
	for s in bad {
		ok := spell.is_date_time(s)
		testing.expectf(t, !ok, "%q", s)
	}
}
