package json_tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// `n` levels of arrays, or of objects whose member `a` holds the next, around a 0, inside a root array holding it and
// a 0 after it, so that a negative index of the root reads the nested value again.
nested_in_root :: proc(n: int, objects: bool) -> string {
	open, close := "[", "]"
	if objects {
		open, close = `{"a":`, "}"
	}
	return strings.concatenate({"[", strings.repeat(open, n - 1, context.temp_allocator), "0", strings.repeat(close, n - 1, context.temp_allocator), ",0]"}, context.temp_allocator)
}

// The nodes of `nested_in_root(n, objects)` and of its nested value.
nested_nodes :: proc(n: int, objects: bool) -> (all, value: int) {
	value = (n - 1) * (2 if objects else 1) + 1
	return value + 2, value
}

READS_DEPTHS := [?]int{json.WALK_LEVELS, json.WALK_LEVELS + 1, 2 * json.WALK_LEVELS, 4 * json.WALK_LEVELS, 10_001, 20_001, 40_001, 100_001}

// Every read nests past the levels a walk's frame holds, arrays and objects, a replay of a value nesting as deep
// included, and gives back every byte it took.
@(test)
reads_nest_past_the_frame :: proc(t: ^testing.T) {
	testkit.deadline(t)
	opts := json.Options{budget = {depth = 200_000}}
	for depth in READS_DEPTHS {
		for objects in ([]bool{false, true}) {
			text := transmute([]u8)nested_in_root(depth, objects)
			all, value := nested_nodes(depth, objects)
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, context.allocator)
			defer mem.tracking_allocator_destroy(&track)
			allocator := mem.tracking_allocator(&track)

			testing.expectf(t, json.validate(text, opts = opts, allocator = allocator) == nil, "validate %d %v", depth, objects)
			doc, err := json.build(text, opts = opts, allocator = allocator)
			testing.expectf(t, err == nil && len(doc.nodes) == all, "build %d %v: %v %d", depth, objects, err, len(doc.nodes))
			tape.destroy(&doc)
			answer, ferr := json.find(text, {tape.Index(-2)}, opts = opts, allocator = allocator)
			testing.expectf(t, ferr == nil && answer.outcome == .Found && answer.lo == 1 && answer.hi == u64(len(text) - 3), "find %d %v: %v %v", depth, objects, ferr, answer)
			for step in ([]tape.Step{tape.All{}, tape.Index(-2)}) {
				d, _ := tape.demand_of({{step}}, allocator = allocator)
				r, serr := json.scan(text, &d, opts = opts, allocator = allocator)
				_, all_elements := step.(tape.All)
				kept := value + 1 + int(all_elements)
				testing.expectf(t, serr == nil && answered(&r) > 0 && len(r.nodes) == kept, "scan %v %d %v: %v %d", step, depth, objects, serr, len(r.nodes))
				tape.destroy(&r)
				tape.destroy(&d)
			}
			testing.expectf(t, len(track.allocation_map) == 0 && len(track.bad_free_array) == 0, "%d %v: %d blocks live", depth, objects, len(track.allocation_map))
		}
	}
}

// `validate` allocates nothing within the frame's levels, and past them one block for the levels, doubled with a level
// more at each growth, given back at its end.
@(test)
validate_allocates_only_past_the_frame :: proc(t: ^testing.T) {
	testkit.deadline(t)
	opts := json.Options{budget = {depth = 200_000}}
	cases := [?]struct {
		depth: int,
		bytes: i64, // the levels' block at its largest
	}{{json.WALK_LEVELS, 0}, {json.WALK_LEVELS + 1, (2 * json.WALK_LEVELS + 1) * 4}, {4 * json.WALK_LEVELS + 4, (8 * json.WALK_LEVELS + 7) * 4}}
	for c in cases {
		for objects in ([]bool{false, true}) {
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, context.allocator)
			defer mem.tracking_allocator_destroy(&track)
			// The root array is a level, so the nested value has one level fewer.
			text := transmute([]u8)nested_in_root(c.depth, objects)
			testing.expect_value(t, json.validate(text, opts = opts, allocator = mem.tracking_allocator(&track)), nil)
			testing.expectf(t, track.peak_memory_allocated == c.bytes && len(track.allocation_map) == 0, "%d %v: peak %d, %d live", c.depth, objects, track.peak_memory_allocated, len(track.allocation_map))
		}
	}
}

// A refused growth of the levels is `Out_Of_Memory` for every read, with nothing left allocated, and a nil allocator
// refuses every growth.
@(test)
refused_levels_are_out_of_memory :: proc(t: ^testing.T) {
	testkit.deadline(t)
	opts := json.Options{budget = {depth = 200_000}}
	text := transmute([]u8)nested_in_root(4 * json.WALK_LEVELS, false)
	testing.expect_value(t, json.validate(text, opts = opts, allocator = {}), runtime.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, json.validate(transmute([]u8)nested_in_root(json.WALK_LEVELS, false), allocator = {}), nil)
	for read in 0 ..< 4 {
		for left := 0; ; left += 1 {
			f := Failing{backing = context.allocator, left = left}
			allocator := failing_allocator(&f)
			err: tape.Error
			switch read {
			case 0:
				err = json.validate(text, opts = opts, allocator = allocator)
			case 1:
				doc: tape.Document
				doc, err = json.build(text, opts = opts, allocator = allocator)
				tape.destroy(&doc)
			case 2:
				_, err = json.find(text, {tape.Index(-2), tape.Index(0)}, opts = opts, allocator = allocator)
			case 3:
				d, _ := tape.demand_of({{tape.Index(-2), tape.Index(0)}})
				r: tape.Document
				r, err = json.scan(text, &d, opts = opts, allocator = allocator)
				tape.destroy(&r)
				tape.destroy(&d)
			}
			testing.expectf(t, f.live == 0, "read %d: %d blocks live after %d allocations", read, f.live, left)
			if err == nil {
				testing.expectf(t, left > 0, "read %d allocated nothing", read)
				break
			}
			testing.expectf(t, err == runtime.Allocator_Error.Out_Of_Memory, "read %d, %d allocations: %v", read, left, err)
			if left > 100 || f.live != 0 {
				break
			}
		}
	}
}

// A replay below a path as deep as the builder's frame grows the builder's levels from those it has left, and keeps
// the replayed value whole. A path into a replayed value nests past the replay's own levels.
@(test)
replay_below_a_deep_path :: proc(t: ^testing.T) {
	testkit.deadline(t)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	below := make([]tape.Step, 1001, context.temp_allocator)
	into := make([]tape.Step, 151, context.temp_allocator)
	for &s in below {
		s = tape.Index(0)
	}
	for &s in into {
		s = tape.Index(0)
	}
	below[1000], into[0] = tape.Index(-2), tape.Index(-2)
	inner := nested_in_root(200, false)
	text := strings.concatenate({strings.repeat("[", 1000, context.temp_allocator), inner, strings.repeat("]", 1000, context.temp_allocator)}, context.temp_allocator)
	_, value := nested_nodes(200, false)
	d, _ := tape.demand_of({below}, allocator = allocator)
	r, err := json.scan(transmute([]u8)text, &d, allocator = allocator)
	_, found, _ := tape.answer({doc = &r}, 0, 0)
	testing.expectf(t, err == nil && answered(&r) == 1 && found == .Found && len(r.nodes) == 1001 + value, "%v %d", err, len(r.nodes))
	tape.destroy(&r)
	tape.destroy(&d)
	d, _ = tape.demand_of({into}, allocator = allocator)
	r, err = json.scan(transmute([]u8)inner, &d, allocator = allocator)
	node, deep, _ := tape.answer({doc = &r}, 0, 0)
	testing.expectf(t, err == nil && answered(&r) == 1 && deep == .Found && node == 151, "%v %v %v", err, node, deep)
	tape.destroy(&r)
	tape.destroy(&d)
	answer, ferr := json.find(transmute([]u8)text, below, allocator = allocator)
	testing.expectf(t, ferr == nil && answer.outcome == .Found && answer.lo == 1001, "%v %v", ferr, answer)
	answer, ferr = json.find(transmute([]u8)inner, into, allocator = allocator)
	testing.expectf(t, ferr == nil && answer.outcome == .Found && answer.lo == 151, "%v %v", ferr, answer)
	testing.expectf(t, len(track.allocation_map) == 0 && len(track.bad_free_array) == 0, "%d blocks live", len(track.allocation_map))
}

// A container kept whole that holds arrays of numbers grows the scan's room for nodes as the blocks of numbers fill it.
@(test)
kept_number_blocks_grow_the_room :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[[")
	for i in 0 ..< 100 {
		strings.write_string(&b, ",[" if i > 0 else "[")
		for k in 0 ..< 50 {
			strings.write_string(&b, ",1234" if k > 0 else "1234")
		}
		strings.write_byte(&b, ']')
	}
	strings.write_string(&b, "]]")
	d, _ := tape.demand_of({{tape.All{}}})
	defer tape.destroy(&d)
	r, err := json.scan(transmute([]u8)strings.to_string(b), &d)
	defer tape.destroy(&r)
	testing.expectf(t, err == nil && len(r.nodes) == 2 + 100 + 100 * 50, "%v %d", err, len(r.nodes))
}

// The answers a scan's document holds over all its paths.
answered :: proc(r: ^tape.Document) -> int {
	return len(r.partial.answers) if r.partial != nil else 0
}
