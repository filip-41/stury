package jq_tests

import "core:mem/virtual"
import "core:strings"
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

@(private = "file")
Texts :: struct {
	h:    ^query.Heap,
	vals: [dynamic]string,
}

@(private = "file")
collect_text :: proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool {
	o := (^Texts)(data)
	out := make([dynamic]u8)
	_ = query.write_json(h, &out, v)
	append(&o.vals, string(out[:]))
	query.release(h, v)
	return true
}

@(private = "file")
failed :: proc(why: string) -> []string {
	out := make([]string, 1)
	out[0] = strings.concatenate({"<", why, ">"})
	return out
}

// The outputs of `program` on `input`, as compact JSON, in the zone of `test_zone` when `zoned`.
@(private = "file")
run_in_zone :: proc(program, input: string, zoned: bool) -> []string {
	prog, errors := jq.compile(program)
	defer jq.destroy_program(prog)
	if len(errors) > 0 {
		return failed("compile error")
	}
	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)
	x, ok := read_value(&h, input)
	if !ok {
		return failed("bad input")
	}
	hooks := jq.Hooks {
		zone = test_zone if zoned else nil,
	}
	run: jq.Run
	jq.run_init(&run, prog, &h, nil, &hooks)
	outs := Texts {
		h = &h,
	}
	end := jq.run_value(&run, x, collect_text, &outs)
	if end == .Failed {
		e := query.take_error(&h)
		append(&outs.vals, strings.concatenate({"error: ", jq.error_message(&h, &e)}))
		query.destroy_error(&h, &e)
	}
	jq.run_destroy(&run)
	return outs.vals[:]
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
		got := strings.join(run_in_zone(c[0], c[1], true), "\n")
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
	got := strings.join(run_in_zone(`localtime, strflocaltime("%H %Z %z")`, "1700000000", false), "\n")
	testing.expect_value(t, got, "[2023,10,14,22,13,20,2,317]\n\"22 UTC +0000\"")
}
