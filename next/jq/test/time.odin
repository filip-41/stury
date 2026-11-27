package jq_tests

import "core:mem/virtual"
import "core:testing"
import "stury:jq"
import "stury:lib/query"
import "stury:testkit"

// The local-time builtins under a zone the caller names through `Hooks.zone`: a zone with one daylight-time window.

// Standard time is UTC-5 ("EST"), and daylight time UTC-4 ("EDT") from 1_700_000_000 up to 1_710_000_000.
@(private = "file")
DST_FROM :: 1_700_000_000
@(private = "file")
DST_TO :: 1_710_000_000

@(private = "file")
test_zone :: proc(data: rawptr, secs: i64) -> (zone: query.Zone, ok: bool) {
	if DST_FROM <= secs && secs < DST_TO {
		return {offset = -4 * 3600, name = "EDT"}, true
	}
	return {offset = -5 * 3600, name = "EST"}, true
}

// The outputs of `program` on `input`, as compact JSON joined by newlines, in the zone of `test_zone` when `zoned`.
@(private = "file")
run_in_zone :: proc(t: ^testing.T, program, input: string, zoned: bool, loc := #caller_location) -> string {
	hooks := jq.Hooks{zone = test_zone if zoned else nil}
	return eval_jq(t, program, {input_json = input, hooks = &hooks, append_err = true}, loc = loc).out
}

@(private = "file", rodata)
ZONE_CASES := [?][3]string {
	// program, input, outputs joined by a newline
	{"localtime", "1700000000", "[2023,10,14,18,13,20,2,317]"},
	{"localtime", "1690000000", "[2023,6,21,23,26,40,5,201]"},
	{"gmtime", "1700000000", "[2023,10,14,22,13,20,2,317]"},
	{`strflocaltime("%H:%M %Z %z")`, "1700000000", `"18:13 EDT -0400"`},
	{`strflocaltime("%H:%M %Z %z")`, "1690000000", `"23:26 EST -0500"`},
	{`strflocaltime("%s")`, "1700000000", `"1700000000"`},
	{`strflocaltime("%H %Z")`, "[2023,10,14,18,13,20,2,317]", `"18 EDT"`},
	{`strflocaltime("%H %Z")`, "[2023,0,1,12,0,0]", `"12 EST"`},
	{`strflocaltime("%H %Z %z")`, "[2023,10,14,18,13,20,2,317]", `"18 EDT -0400"`},
	{`strflocaltime("%H %Z %z")`, "[2023,0,1,12,0,0]", `"12 EST -0500"`},
	{`strftime("%H %Z")`, "1700000000", `"22 UTC"`},
	{`localtime | mktime`, "1700000000", "1699985600"},
	{`"1700000000" | strptime("%s")`, "null", "[2023,10,14,18,13,20,2,317]"},
}

@(test)
local_time_follows_the_zone_the_caller_names :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	for c in ZONE_CASES {
		got := run_in_zone(t, c[0], c[1], true)
		testing.expectf(t, got == c[2], "%s on %s: got %s, want %s", c[0], c[1], got, c[2])
	}
}

@(test)
local_time_is_utc_without_a_zone :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	got := run_in_zone(t, `localtime, strflocaltime("%H %Z %z")`, "1700000000", false)
	testing.expect_value(t, got, "[2023,10,14,22,13,20,2,317]\n\"22 UTC +0000\"")
}
