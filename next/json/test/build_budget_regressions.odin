package json_tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// Both builds and scans that grow past `tape.MAX_CHILDREN` succeed on a tight bump arena: `counts` does not land after
// `doc.nodes` and block in-place node room growth, whether using default scratch or sharing the arena as scratch, and
// whether budgeted or unbudgeted.
@(test)
arena_build_and_scan_grow_past_max_children :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	n_elems := int(tape.MAX_CHILDREN) + 5000
	src := transmute([]u8)strings.concatenate({"[", strings.repeat("1,", n_elems - 1, context.temp_allocator), "1]"}, context.temp_allocator)
	ref, rerr := json.build(src)
	defer tape.destroy(&ref)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, len(ref.nodes), n_elems + 1)
	testing.expect_value(t, len(ref.counts), 1)
	testing.expect_value(t, ref.counts[0].count, u32(n_elems))

	need := len(ref.nodes) * size_of(tape.Node) + 1024
	backing := make([]u8, need)
	defer delete(backing)

	// Budgeted build on a tight bump arena (default scratch and shared arena scratch).
	for share_scratch in ([2]bool{false, true}) {
		arena: mem.Arena
		mem.arena_init(&arena, backing)
		a := mem.arena_allocator(&arena)
		opts := json.Options{budget = {memory = u64(need)}}
		if share_scratch {
			opts.scratch = a
		}
		doc, err := json.build(src, .Json, opts, a)
		testing.expectf(t, err == nil, "budgeted build (share=%v): %v (offset=%d/%d)", share_scratch, err, arena.offset, need)
		testing.expect_value(t, len(doc.nodes), n_elems + 1)
		testing.expect_value(t, len(doc.counts), 1)
		if len(doc.counts) == 1 {
			testing.expect_value(t, doc.counts[0].count, u32(n_elems))
		}
	}

	// Unbudgeted and budgeted scans keeping > MAX_CHILDREN nodes on a tight bump arena.
	d, derr := tape.demand_of({{}})
	defer tape.destroy(&d)
	testing.expect_value(t, derr, nil)
	for share_scratch in ([2]bool{false, true}) {
		for budget in ([2]u64{0, u64(need)}) {
			arena: mem.Arena
			mem.arena_init(&arena, backing)
			a := mem.arena_allocator(&arena)
			opts := json.Options{budget = {memory = budget}}
			if share_scratch {
				opts.scratch = a
			}
			doc, err := json.scan(src, &d, .Json, opts = opts, allocator = a)
			testing.expectf(t, err == nil, "scan (share=%v, budget=%d): %v (offset=%d/%d)", share_scratch, budget, err, arena.offset, need)
			testing.expect_value(t, len(doc.nodes), n_elems + 1)
			testing.expect_value(t, len(doc.counts), 1)
			if len(doc.counts) == 1 {
				testing.expect_value(t, doc.counts[0].count, u32(n_elems))
			}
		}
	}

	// Budgeted scan sharing `context.allocator` as scratch verifies `counts` handoff has zero leaks or mismatched frees.
	{
		doc, err := json.scan(src, &d, .Json, opts = {budget = {memory = u64(need)}, scratch = context.allocator}, allocator = context.allocator)
		defer tape.destroy(&doc)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(doc.nodes), n_elems + 1)
		testing.expect_value(t, len(doc.counts), 1)
		if len(doc.counts) == 1 {
			testing.expect_value(t, doc.counts[0].count, u32(n_elems))
		}
	}
}

// A scan of 70 elements that passes at a memory budget must pass at every larger memory budget (including 1400, 1600,
// and 2100 bytes), and list growth backs off under tight budgets instead of refusing above what the scan needs.
@(test)
scan_memory_budgets_are_monotonic_across_demands :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for i in 0 ..< 70 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, "%d", i)
	}
	strings.write_byte(&b, ']')
	src := transmute([]u8)strings.to_string(b)

	cases := [?]struct {
		steps:  []tape.Step,
		max_ok: u64,
	}{
		{{}, 1400},
		{{tape.All{}}, 4000},
		{{tape.Index(-3)}, 1400},
		{{tape.Slice{-5, nil, 0}}, 1400},
		{{tape.Slice{0, nil, 0}}, 5400},
		{{tape.Descend{}, tape.Name("a")}, 1400},
	}

	for c in cases {
		d, derr := tape.demand_of({c.steps})
		defer tape.destroy(&d)
		testing.expect_value(t, derr, nil)

		first_ok := u64(0)
		// Sweep coarsely across 100..6000 plus every 1-byte step across 1200..2200 (covering 1400, 1600, 2100).
		for memory := u64(100); memory <= 6000; {
			r, err := json.scan(src, &d, opts = {budget = {memory = memory}})
			tape.destroy(&r)
			if err == nil {
				if first_ok == 0 {
					first_ok = memory
				}
			} else if first_ok != 0 {
				testing.expectf(t, false, "%v: fit %d bytes but refused at %d bytes (%v)", c.steps, first_ok, memory, err)
				break
			}
			if memory >= 1200 && memory < 2200 {
				memory += 1
			} else {
				memory += 20
			}
		}
		testing.expectf(t, first_ok > 0 && first_ok <= c.max_ok, "%v: first_ok=%d exceeds %d", c.steps, first_ok, c.max_ok)
	}
}
