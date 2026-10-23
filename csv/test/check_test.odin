package csv_tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import csv "../"

// What `unmarshal` refuses, `unmarshal_check` refuses alike: `read` compares them on every case of the other
// suites. These cases are the ones only a check can get wrong.

// A check keeps no record: its memory does not grow with the input.
@(test)
test_check_bounded_memory :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "id,name,score\n")
	for _ in 0 ..< 200_000 {
		strings.write_string(&b, "12345,\"quoted \"\"name\"\", with comma\",1.25\n")
	}
	src := b.buf[:]
	Scored :: struct {
		id:    int,
		name:  cstring,
		score: f64,
	}
	plan := csv.type_plan_init([]Scored)
	defer csv.type_plan_destroy(&plan)
	// The plan lowers on first use, in its own allocator.
	testing.expect_value(t, csv.unmarshal_check(src, []Scored, plan = &plan), nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		testing.expect_value(t, csv.unmarshal_check(src, []Scored, plan = &plan), nil)
	}
	testing.expectf(t, track.peak_memory_allocated < 16 * 1024, "a check of %d bytes held %d at its peak", len(src), track.peak_memory_allocated)
	testing.expect_value(t, track.current_memory_allocated, 0)

	// A refusal at the end is found as `unmarshal` finds it.
	strings.write_string(&b, "x,y,z\n")
	err := csv.unmarshal_check(b.buf[:], []Scored, plan = &plan)
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Wrong_Kind)
	testing.expect_value(t, err.?.steps[0], csv.Step(csv.Index(200_000)))
}

// A hook is not run by a check, but the bytes of its cell are still judged.
@(test)
test_check_runs_no_hooks :: proc(t: ^testing.T) {
	plan := csv.type_plan_init(
		[]Event,
		{
			hooks = {
				{
					type = Date,
					read = proc(text: []byte, dest: rawptr, allocator: runtime.Allocator) -> Maybe(csv.Unmarshal_Error_Kind) {
						return .Wrong_Kind
					},
				},
			},
		},
	)
	defer csv.type_plan_destroy(&plan)
	src := "when,name\nanything,x\n"
	events: []Event
	err := csv.unmarshal(transmute([]byte)src, &events, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Wrong_Kind)
	testing.expect_value(t, csv.unmarshal_check(transmute([]byte)src, []Event, plan = &plan), nil)
	bad := "when,name\n\xff,x\n"
	err = csv.unmarshal_check(transmute([]byte)bad, []Event, plan = &plan)
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Syntax)
	testing.expect_value(t, err.?.syntax, csv.Error_Kind.Bad_Char)
}

@(test)
test_check_refusals_before_the_read :: proc(t: ^testing.T) {
	testing.expect_value(t, csv.unmarshal_check(nil, []Row, {dialect = {delimiter = '"'}}).?.kind, csv.Unmarshal_Error_Kind.Bad_Option)
	testing.expect_value(t, csv.unmarshal_check(nil, []int).?.kind, csv.Unmarshal_Error_Kind.Unsupported)
	plan := csv.type_plan_init([]Strict)
	defer csv.type_plan_destroy(&plan)
	testing.expect_value(t, csv.unmarshal_check(nil, []Row, plan = &plan).?.kind, csv.Unmarshal_Error_Kind.Plan_Mismatch)
	// An empty text has no records.
	testing.expect_value(t, csv.unmarshal_check(nil, []Strict), nil)
	testing.expect_value(t, csv.unmarshal_check(nil, []Strict, {no_header = true}), nil)
}
