package core_tests

// A plan is shared by both directions: a type it cannot spell refuses the same way on every call.

import "core:mem"
import "core:testing"
import csv "../../csv"
import json "../../json"

PLAN_A :: struct {
	a: int,
}

PLAN_B :: struct {
	b: int,
}

PLAN_Shapes :: struct {
	u: union {
		PLAN_A,
		PLAN_B,
	},
}

// A JSON key and a CSV column must be UTF-8.
PLAN_Bad_Name :: struct {
	f: int "json:\"\xff\" csv:\"\xff\"",
}

PLAN_Comma :: struct {
	last: string `json:"Last\, First" csv:"Last\, First"`,
	// An escape and a flag in one tag: the name ends at the comma the escape does not quote.
	age: int `json:"Age\, years,required" csv:"Age\, years,required"`,
}

PLAN_Backslash :: struct {
	f: int `json:"a\\b" csv:"a\\b"`,
}

PLAN_Flag :: struct {
	f: int `json:"f,bogus" csv:"f,bogus"`,
}

// A refusal of a typed read: its error and whether it was refused.
plan_err :: proc(err: Maybe(json.Unmarshal_Error)) -> (json.Unmarshal_Error, bool) {
	return err.?
}

@(test)
test_plan_read_refusal_is_stable :: proc(t: ^testing.T) {
	// The tag is not UTF-8, so the plan cannot compile the tagged union: the root type has no read shape, and
	// every call must answer `.Unsupported` at the value, with no path, rather than `.Out_Of_Memory`.
	plan := json.type_plan_init(PLAN_Shapes, {union_tag = "\xff"}, context.temp_allocator)
	src := transmute([]byte)string(`{"u":{"a":1}}`)
	for call in 0 ..< 3 {
		v: PLAN_Shapes
		err, refused := plan_err(json.unmarshal(src, &v, {}, &plan, context.temp_allocator))
		if !testing.expectf(t, refused, "call %d read", call) {
			continue
		}
		testing.expectf(t, err.kind == .Unsupported, "call %d: kind %v, want Unsupported", call, err.kind)
		testing.expectf(t, err.offset == 0, "call %d: offset %d, want 0", call, err.offset)
		testing.expectf(t, err.n_steps == 0, "call %d: %d path steps, want none", call, err.n_steps)
	}

	// The same plan writes: the union tag cannot be spelled either way, and the read refusal did not consume it.
	for call in 0 ..< 3 {
		out, err := json.marshal(PLAN_Shapes{}, {}, &plan, context.temp_allocator)
		testing.expectf(t, err == .Bad_Utf8, "marshal call %d: %v, want Bad_Utf8", call, err)
		testing.expectf(t, out == nil, "marshal call %d wrote %d bytes", call, len(out))
	}
}

@(test)
test_plan_marshal_refusal_is_stable :: proc(t: ^testing.T) {
	// The same compile refusal, from the writer's side: a plan that reported `.Bad_Utf8` must report it again,
	// not fall through to the `.Unsupported` of an op left half-built by the first call.
	plan := json.type_plan_init(PLAN_Bad_Name, {}, context.temp_allocator)
	v := PLAN_Bad_Name{f = 1}
	for call in 0 ..< 3 {
		out, err := json.marshal(v, {}, &plan, context.temp_allocator)
		testing.expectf(t, err == .Bad_Utf8, "call %d: %v, want Bad_Utf8", call, err)
		testing.expectf(t, out == nil, "call %d wrote %d bytes", call, len(out))
	}

	src := transmute([]byte)string(`{"f":1}`)
	for call in 0 ..< 3 {
		back: PLAN_Bad_Name
		err, refused := plan_err(json.unmarshal(src, &back, {}, &plan, context.temp_allocator))
		testing.expectf(t, refused, "read call %d read", call)
		testing.expectf(t, err.kind == .Unsupported, "read call %d: kind %v, want Unsupported", call, err.kind)
	}

	cplan := csv.type_plan_init([]PLAN_Bad_Name)
	defer csv.destroy(&cplan)
	rows := []PLAN_Bad_Name{{f = 1}}
	for call in 0 ..< 3 {
		out, err := csv.marshal(rows, {}, &cplan, context.temp_allocator)
		testing.expectf(t, err == .Bad_Utf8, "csv call %d: %v, want Bad_Utf8", call, err)
		testing.expectf(t, out == nil, "csv call %d wrote %d bytes", call, len(out))
	}

	cread := transmute([]byte)string("f\n1\n")
	for call in 0 ..< 3 {
		back: []PLAN_Bad_Name
		err, refused := plan_err(csv.unmarshal(cread, &back, {}, &cplan, context.temp_allocator))
		testing.expectf(t, refused, "csv read call %d read", call)
		testing.expectf(t, err.kind == .Unsupported, "csv read call %d: kind %v, want Unsupported", call, err.kind)
	}
}

@(test)
test_plan_tag_comma_round_trip :: proc(t: ^testing.T) {
	row := PLAN_Comma{"Ann", 41}

	jtext, jerr := json.marshal(row, {}, nil, context.temp_allocator)
	testing.expect_value(t, jerr, json.Marshal_Error.None)
	testing.expect_value(t, string(jtext), `{"Last, First":"Ann","Age, years":41}`)
	jback: PLAN_Comma
	jrf, jrefused := plan_err(json.unmarshal(jtext, &jback, {}, nil, context.temp_allocator))
	testing.expectf(t, !jrefused, "json read back: %v at %d", jrf.kind, jrf.offset)
	testing.expect_value(t, jback, row)

	slash := PLAN_Backslash{1}
	stext, serr := json.marshal(slash, {}, nil, context.temp_allocator)
	testing.expect_value(t, serr, json.Marshal_Error.None)
	testing.expect_value(t, string(stext), `{"a\\b":1}`)
	sback: PLAN_Backslash
	srf, srefused := plan_err(json.unmarshal(stext, &sback, {}, nil, context.temp_allocator))
	testing.expectf(t, !srefused, "json backslash read back: %v at %d", srf.kind, srf.offset)
	testing.expect_value(t, sback, slash)

	shcsv, sherr := csv.marshal([]PLAN_Backslash{slash}, {}, nil, context.temp_allocator)
	testing.expect_value(t, sherr, csv.Marshal_Error.None)
	testing.expect_value(t, string(shcsv), "a\\b\n1\n")
	shback: []PLAN_Backslash
	shrf, shrefused := plan_err(csv.unmarshal(shcsv, &shback, {}, nil, context.temp_allocator))
	testing.expectf(t, !shrefused, "csv backslash read back: %v at %d", shrf.kind, shrf.offset)
	if testing.expect_value(t, len(shback), 1) {
		testing.expect_value(t, shback[0], slash)
	}

	ctext, cerr := csv.marshal([]PLAN_Comma{row}, {}, nil, context.temp_allocator)
	testing.expect_value(t, cerr, csv.Marshal_Error.None)
	testing.expect_value(t, string(ctext), "\"Last, First\",\"Age, years\"\nAnn,41\n")
	cback: []PLAN_Comma
	crf, crefused := plan_err(csv.unmarshal(ctext, &cback, {}, nil, context.temp_allocator))
	testing.expectf(t, !crefused, "csv read back: %v at %d", crf.kind, crf.offset)
	if testing.expect_value(t, len(cback), 1) {
		testing.expect_value(t, cback[0], row)
	}
}

@(test)
test_plan_tag_unknown_flag_refuses :: proc(t: ^testing.T) {
	_, jmerr := json.marshal(PLAN_Flag{1}, {}, nil, context.temp_allocator)
	testing.expect_value(t, jmerr, json.Marshal_Error.Bad_Tag)

	jv: PLAN_Flag
	jrf, jrefused := plan_err(json.unmarshal(transmute([]byte)string(`{"f":1}`), &jv, {}, nil, context.temp_allocator))
	testing.expectf(t, jrefused, "json read")
	testing.expect_value(t, jrf.kind, json.Unmarshal_Error_Kind.Bad_Tag)

	_, cmerr := csv.marshal([]PLAN_Flag{{1}}, {}, nil, context.temp_allocator)
	testing.expect_value(t, cmerr, csv.Marshal_Error.Bad_Tag)

	cback: []PLAN_Flag
	crf, crefused := plan_err(csv.unmarshal(transmute([]byte)string("f\n1\n"), &cback, {}, nil, context.temp_allocator))
	testing.expectf(t, crefused, "csv read")
	testing.expect_value(t, crf.kind, json.Unmarshal_Error_Kind.Bad_Tag)
}

// Several types behind one root, so a compile has nested ops, fields, member names and index entries to roll back.
PLAN_Leaf :: struct {
	id:   int,
	mode: enum {
		Idle,
		Busy,
	},
}

PLAN_Tree :: struct {
	name: string,
	kids: []PLAN_Leaf,
	one:  PLAN_Leaf,
	any:  union {
		PLAN_A,
		string,
	},
}

HEALED :: 1 << 40

// An allocator that refuses `width` allocations from the `skip`-th on, then grants every one again.
Flaky :: struct {
	backing:     mem.Allocator,
	calls, skip: int,
	width:       int,
}

flaky_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	f := (^Flaky)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		n := f.calls
		f.calls += 1
		if n >= f.skip && n < f.skip + f.width {
			return nil, .Out_Of_Memory
		}
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// A plan that ran out of memory while compiling answers the same as a fresh one once the allocator grants again:
// the refusal may land anywhere in the compile, including in the rollback that follows it.
@(test)
test_plan_recovers_after_allocator_refusals :: proc(t: ^testing.T) {
	v := PLAN_Tree{name = "x", kids = []PLAN_Leaf{{1, .Busy}}, one = {2, .Idle}, any = PLAN_A{3}}
	want := `{"name":"x","kids":[{"id":1,"mode":"Busy"}],"one":{"id":2,"mode":"Idle"},"any":{"a":3}}`
	text := transmute([]byte)string(`{"name":"y","kids":[{"id":5,"mode":"Busy"}],"one":{"id":6,"mode":"Idle"}}`)
	for width in ([?]int{1, 3, 12}) {
		for skip in 0 ..< 80 {
			// Armed after `type_plan_init`, whose copy of the options is a refusal no retry repairs.
			fl := Flaky{backing = context.allocator, skip = HEALED, width = width}
			plan := json.type_plan_init(PLAN_Tree, {}, mem.Allocator{flaky_proc, &fl})
			defer json.destroy(&plan)
			fl.calls, fl.skip = 0, skip
			_, first := json.marshal(v, {}, &plan, context.temp_allocator)
			testing.expectf(t, first == .None || first == .Out_Of_Memory, "skip %d width %d: first marshal %v", skip, width, first)
			fl.skip = HEALED
			out, err := json.marshal(v, {}, &plan, context.temp_allocator)
			testing.expectf(t, err == .None, "skip %d width %d: marshal after refusals %v", skip, width, err)
			testing.expectf(t, string(out) == want, "skip %d width %d: wrote %s", skip, width, out)

			rplan := json.type_plan_init(PLAN_Tree, {}, mem.Allocator{flaky_proc, &fl})
			defer json.destroy(&rplan)
			fl.calls, fl.skip = 0, skip
			back: PLAN_Tree
			_, rfirst := plan_err(json.unmarshal(text, &back, {}, &rplan, context.temp_allocator))
			fl.skip = HEALED
			rerr, refused := plan_err(json.unmarshal(text, &back, {}, &rplan, context.temp_allocator))
			testing.expectf(t, !refused && back.name == "y" && back.kids[0].id == 5, "skip %d width %d: read after refusals %v %v (first refused %v)", skip, width, rerr, back, rfirst)
		}
	}
}
