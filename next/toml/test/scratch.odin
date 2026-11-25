// Tests of `Options.scratch` on TOML build, typed reads and records: default caller allocator, arena peak reduction
// with a heap scratch, and shared `Budget.memory` enforcement in both modes.
package toml_tests

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

@(private = "file")
Scratch_Row :: struct {
	name:  string,
	value: i64,
	tag:   string,
}

@(private = "file")
Scratch_Doc :: struct {
	rows: []Scratch_Row,
}

@(private = "file")
scratch_sample :: proc(count: int, allocator: runtime.Allocator) -> []u8 {
	b: strings.Builder
	strings.builder_init(&b, allocator)
	for i in 0 ..< count {
		fmt.sbprintf(&b, "[[rows]]\nname = \"row-%04d-payload\"\nvalue = %d\ntag = \"tag-%04d\"\n", i, i * 17, i)
	}
	return transmute([]u8)strings.to_string(b)
}

// With no `Options.scratch` set, the TOML table tree comes from the caller's allocator (seen by a tracking allocator
// and kept in an arena). With a heap scratch, the arena keeps only the result and the scratch allocator frees every
// block before the read returns.
@(test)
scratch_moves_toml_tree_out_of_arena :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := scratch_sample(400, context.allocator)
	defer delete(src)

	// 1. Default (no scratch): tracking allocator sees tree allocations (peak > final live) and zero leaks.
	{
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		alloc := mem.tracking_allocator(&track)

		doc, err := toml.build(src, allocator = alloc)
		expect_nil(t, err)
		testing.expect(t, track.peak_memory_allocated > track.current_memory_allocated)
		toml.destroy(&doc)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}

	// 2. Arena build: heap scratch sharply lowers arena peak vs no scratch, and frees all scratch blocks.
	arena_no_scratch: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena_no_scratch), nil)
	defer virtual.arena_destroy(&arena_no_scratch)
	doc_plain, err_plain := toml.build(src, allocator = virtual.arena_allocator(&arena_no_scratch))
	expect_nil(t, err_plain)
	peak_plain := arena_no_scratch.total_used

	arena_with_scratch: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena_with_scratch), nil)
	defer virtual.arena_destroy(&arena_with_scratch)
	scratch_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&scratch_track, context.allocator)
	defer mem.tracking_allocator_destroy(&scratch_track)
	scratch_alloc := mem.tracking_allocator(&scratch_track)

	doc_scratch, err_scratch := toml.build(src, opts = {scratch = scratch_alloc}, allocator = virtual.arena_allocator(&arena_with_scratch))
	expect_nil(t, err_scratch)
	peak_scratch := arena_with_scratch.total_used
	testing.expect_value(t, len(doc_scratch.nodes), len(doc_plain.nodes))
	testing.expectf(t, peak_scratch * 2 < peak_plain, "expected arena peak with scratch (%d) < half of plain (%d)", peak_scratch, peak_plain)
	testing.expect(t, scratch_track.peak_memory_allocated > 0)
	testing.expect_value(t, len(scratch_track.allocation_map), 0)
	testing.expect_value(t, len(scratch_track.bad_free_array), 0)

	// 3. Typed unmarshal into an arena: heap scratch lowers arena peak (borrowed & copied) with zero scratch leaks.
	for borrow in ([]bool{true, false}) {
		a_plain: virtual.Arena
		testing.expect_value(t, virtual.arena_init_growing(&a_plain), nil)
		defer virtual.arena_destroy(&a_plain)
		out_plain: Scratch_Doc
		expect_nil(t, toml.unmarshal(src, &out_plain, read = {borrow_strings = borrow}, allocator = virtual.arena_allocator(&a_plain)))

		a_sc: virtual.Arena
		testing.expect_value(t, virtual.arena_init_growing(&a_sc), nil)
		defer virtual.arena_destroy(&a_sc)
		st: mem.Tracking_Allocator
		mem.tracking_allocator_init(&st, context.allocator)
		defer mem.tracking_allocator_destroy(&st)
		out_sc: Scratch_Doc
		expect_nil(t, toml.unmarshal(src, &out_sc, read = {borrow_strings = borrow}, opts = {scratch = mem.tracking_allocator(&st)}, allocator = virtual.arena_allocator(&a_sc)))
		testing.expect_value(t, len(out_sc.rows), len(out_plain.rows))
		testing.expect_value(t, out_sc.rows[399].value, i64(399 * 17))
		testing.expectf(t, a_sc.total_used < a_plain.total_used, "typed borrow=%v: scratch arena %d should be < plain %d", borrow, a_sc.total_used, a_plain.total_used)
		testing.expect(t, st.peak_memory_allocated > 0)
		testing.expect_value(t, len(st.allocation_map), 0)
		testing.expect_value(t, len(st.bad_free_array), 0)
	}

	// 4. Records (.Members) take their held tree from `Options.scratch` and free it on destroy.
	{
		st: mem.Tracking_Allocator
		mem.tracking_allocator_init(&st, context.allocator)
		defer mem.tracking_allocator_destroy(&st)
		r := toml.records_open(src, .Members, opts = {scratch = mem.tracking_allocator(&st)})
		out: [4]tape.Record
		testing.expect_value(t, toml.records_validate(&r, out[:]), 0)
		testing.expect_value(t, r.err, nil)
		testing.expect(t, st.current_memory_allocated > 0)
		toml.destroy(&r)
		testing.expect_value(t, len(st.allocation_map), 0)
		testing.expect_value(t, len(st.bad_free_array), 0)
	}
}

// `Budget.memory` refuses past its limit both without and with `Options.scratch`, counts tree + result together, and
// never mutates a caller-owned `Memory_Budget`.
@(test)
scratch_respects_memory_budget_and_leaves_caller_budget_alone :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := scratch_sample(200, context.allocator)
	defer delete(src)
	exceeded := tape.Error(tape.Exceeded{at = tape.NO_BYTE, kind = .Memory})

	// Build, typed read and records (.Members & .Concatenated) refuse under tight budget in both modes.
	for use_scratch in ([]bool{false, true}) {
		st: mem.Tracking_Allocator
		mem.tracking_allocator_init(&st, context.allocator)
		defer mem.tracking_allocator_destroy(&st)
		sc := mem.tracking_allocator(&st) if use_scratch else runtime.Allocator{}

		doc, berr := toml.build(src, opts = {budget = {memory = 4096}, scratch = sc})
		testing.expect_value(t, berr, exceeded)
		testing.expect_value(t, len(doc.nodes), 0)

		out: Scratch_Doc
		uerr := toml.unmarshal(src, &out, opts = {budget = {memory = 4096}, scratch = sc})
		testing.expect_value(t, uerr, exceeded)

		for framing in ([]tape.Framing{.Concatenated, .Members}) {
			r := toml.records_open(src, framing, opts = {budget = {memory = 4096}, scratch = sc})
			recs: [4]tape.Record
			n := toml.records_validate(&r, recs[:])
			testing.expect_value(t, n, 0)
			testing.expect_value(t, r.err, exceeded)
			toml.destroy(&r)
		}
		testing.expect_value(t, len(st.allocation_map), 0)
		testing.expect_value(t, len(st.bad_free_array), 0)
	}

	// Combined limit: measure tree peak alone and copied-strings output alone, then verify a budget that fits each
	// alone but not both together refuses `toml.unmarshal` with `.Memory`.
	tree_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tree_track, context.allocator)
	defer mem.tracking_allocator_destroy(&tree_track)
	out_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&out_track, context.allocator)
	defer mem.tracking_allocator_destroy(&out_track)
	sample_out: Scratch_Doc
	expect_nil(t, toml.unmarshal(src, &sample_out, opts = {scratch = mem.tracking_allocator(&tree_track)}, allocator = mem.tracking_allocator(&out_track)))
	tree_peak := u64(tree_track.peak_memory_allocated)
	out_peak := u64(out_track.peak_memory_allocated)
	for row in sample_out.rows {
		delete(row.name, mem.tracking_allocator(&out_track))
		delete(row.tag, mem.tracking_allocator(&out_track))
	}
	delete(sample_out.rows, mem.tracking_allocator(&out_track))
	testing.expect(t, tree_peak > 0 && out_peak > 0)
	between := max(tree_peak, out_peak) + min(tree_peak, out_peak) / 2
	if between < tree_peak + out_peak {
		a_comb: virtual.Arena
		testing.expect_value(t, virtual.arena_init_growing(&a_comb), nil)
		defer virtual.arena_destroy(&a_comb)
		combined_out: Scratch_Doc
		cerr := toml.unmarshal(src, &combined_out, opts = {budget = {memory = between}, scratch = context.allocator}, allocator = virtual.arena_allocator(&a_comb))
		testing.expect_value(t, cerr, exceeded)
	}

	// Passing a caller-owned `Memory_Budget` as `allocator` never mutates its `peer` or `refused`.
	caller_m := hook.Memory_Budget{backing = context.allocator, limit = 1 << 20}
	doc2, err2 := toml.build(src, opts = {scratch = context.allocator}, allocator = hook.memory_budget(&caller_m))
	expect_nil(t, err2)
	testing.expect(t, caller_m.peer == nil && !caller_m.refused)
	toml.destroy(&doc2)
}
