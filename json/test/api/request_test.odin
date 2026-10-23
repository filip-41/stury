package json_tests

// `Request` and `scan`: the one entry for every query kind.

import json "../.."
import "core:mem"
import "core:testing"

// A path's answers name their tape row beside `.Dom`. A miss names none, nor does any answer without node rows.
@(test)
test_request_path_answers_carry_their_node :: proc(t: ^testing.T) {
	names := []string{"a", "b", "zz", "d"}
	paths: [4]json.Path
	steps: [4]json.Step
	for n, i in names {
		steps[i] = json.Name(n)
		paths[i] = json.Path{steps = steps[i:i + 1]}
	}
	req: json.Request({.Path, .Dom})
	defer json.destroy(&req)
	req.paths = paths[:]
	src := raw(`{"a":1,"b":{"c":[true]},"d":"x\ty"}`)
	testing.expect_value(t, json.scan(src, &req), nil)
	testing.expect_value(t, len(req.answers), len(names))

	want_kind := [?]json.Kind{.Number, .Object, .Null, .String}
	d_node := json.NO_NODE
	for a in req.answers {
		if names[a.query] == "zz" {
			testing.expect_value(t, a.outcome, json.Path_Outcome.Missing)
			testing.expect_value(t, a.node, json.NO_NODE)
			continue
		}
		testing.expect_value(t, a.outcome, json.Path_Outcome.Found)
		testing.expect_value(t, a.owner, u64(0))
		testing.expect(t, a.node >= 0 && int(a.node) < len(req.doc.rows))
		row := req.doc.rows[a.node]
		testing.expect_value(t, u64(row.lo), a.lo)
		testing.expect_value(t, u64(row.hi), a.hi)
		testing.expect_value(t, row.kind, want_kind[a.query])
		testing.expect_value(t, a.kind, want_kind[a.query])
		if names[a.query] == "d" {
			d_node = a.node
		}
	}
	got, ok := json.get_string(&req.doc, d_node)
	testing.expect(t, ok)
	testing.expect_value(t, got, "x\ty")

	// With no node rows there is no row to name.
	bare: json.Request({.Path})
	defer json.destroy(&bare)
	bare.paths = paths[:1]
	testing.expect_value(t, json.scan(src, &bare), nil)
	testing.expect_value(t, len(bare.answers), 1)
	testing.expect_value(t, bare.answers[0].outcome, json.Path_Outcome.Found)
	testing.expect_value(t, bare.answers[0].node, json.NO_NODE)
}

@(test)
test_request_lazy_first_stops_and_remainder_is_judged :: proc(t: ^testing.T) {
	req: json.Request({.Path})
	defer json.destroy(&req)
	req.strictness = .Lazy
	req.duplicates = .First
	req.paths = []json.Path{{steps = []json.Step{json.Name("a")}}}

	good := raw(`{"a":1,"b":2,"c":3}`)
	testing.expect_value(t, json.scan(good, &req), nil)
	testing.expect(t, req.stop != nil, "every key answered, so the walk stops")
	testing.expect_value(t, req.coverage, json.Validity.Partial)
	testing.expect_value(t, len(req.answers), 1)
	testing.expect_value(t, req.answers[0].outcome, json.Path_Outcome.Found)
	testing.expect(t, json.validate_remaining(&req) == nil)
	// The result is committed: the request now covers the whole item, and a second call is the no-op.
	testing.expect_value(t, req.coverage, json.Validity.Full)
	testing.expect_value(t, req.stop, nil)

	bad := raw(`{"a":1,"b":}`)
	testing.expect_value(t, json.scan(bad, &req), nil)
	testing.expect(t, req.stop != nil)
	e, has := json.validate_remaining(&req).?
	testing.expect(t, has, "the unvisited remainder is faulty")
	testing.expect_value(t, e.kind, json.Error_Kind.Bad_Char)
	testing.expect_value(t, json.validate_remaining(&req), e)
}

// `request_init` copies and parses each text beside the `Path`s it is handed. `answers` reads each path's
// answers in document order, out of a walk that interleaved them.
@(test)
test_request_init_and_answers_by_path :: proc(t: ^testing.T) {
	src := raw(`[{"x":1,"y":2},{"x":3,"y":4}]`)
	req: json.Request({.Path})
	defer json.destroy(&req)
	// Escaped, so its name decodes into the request's storage. Overwritten after, so a borrow would show.
	buf := [?]u8{'.', '[', ']', '.', '"', '\\', 'u', '0', '0', '7', '9', '"'}
	x := json.Path{steps = []json.Step{json.Any{}, json.Name("x")}}
	testing.expect_value(t, json.request_init(&req, string(buf[:]), x, ".[0].y"), nil)
	buf = {}
	testing.expect_value(t, len(req.paths), 3)
	testing.expect_value(t, json.scan(src, &req), nil)
	testing.expect_value(t, req.answers[0].query, u32(1)) // walk order: x before y
	want := [3][]string{{"2", "4"}, {"1", "3"}, {"2"}}
	for texts, path in want {
		got, err := json.answers(&req, path)
		testing.expect_value(t, err, nil)
		if !testing.expectf(t, len(got) == len(texts), "path %d: %v", path, got) {
			continue
		}
		for a, k in got {
			testing.expect_value(t, a.query, u32(path))
			testing.expect_value(t, string(src[a.lo:a.hi]), texts[k])
		}
	}

	// A rescan regroups, one path is all of `answers`, and no other path has any.
	testing.expect_value(t, json.request_init(&req, ".[].y"), nil)
	testing.expect_value(t, json.scan(src, &req), nil)
	one, _ := json.answers(&req, 0)
	none, _ := json.answers(&req, 1)
	testing.expect_value(t, len(one), 2)
	testing.expect_value(t, raw_data(one), raw_data(req.answers))
	testing.expect_value(t, len(none), 0)
}

// A text that does not parse names its path and the byte it stopped on, and leaves no paths.
@(test)
test_request_init_bad_path :: proc(t: ^testing.T) {
	req: json.Request({.Path})
	defer json.destroy(&req)
	steps: [4]json.Step
	_, fault := json.parse_path(".b[", steps[:])
	f, faulted := fault.?
	testing.expect(t, faulted)
	err, refused := json.request_init(&req, ".a", ".b[").?
	testing.expect(t, refused)
	testing.expect_value(t, err.kind, json.Request_Error_Kind.Bad_Path)
	testing.expect_value(t, err.path, 1)
	testing.expect_value(t, err.offset, u64(f.offset))
	testing.expect_value(t, len(req.paths), 0)
}

// Paths the caller assigns are the caller's: `destroy` leaves them set.
@(test)
test_request_assigned_paths_stay :: proc(t: ^testing.T) {
	paths := []json.Path{{steps = []json.Step{json.Name("a")}}}
	req: json.Request({.Path})
	req.paths = paths
	testing.expect_value(t, json.scan(raw(`{"a":1}`), &req), nil)
	json.destroy(&req)
	testing.expect_value(t, len(req.paths), 1)
}

// A refused rescan leaves the last scan's outputs and its source, result and coverage as they were.
@(test)
test_request_refused_rescan_keeps_state :: proc(t: ^testing.T) {
	req: json.Request({.Path})
	defer json.destroy(&req)
	req.paths = []json.Path{{steps = []json.Step{json.Name("a")}}}
	src := raw(`{"a":1}`)
	testing.expect_value(t, json.scan(src, &req), nil)
	req.strictness = .Lazy
	request_refused(t, json.scan(raw(`{"a":`), &req), .Lazy_Needs_First)
	testing.expect_value(t, string(req.src), string(src))
	testing.expect_value(t, req.coverage, json.Validity.Full)
	testing.expect_value(t, len(req.answers), 1)
	testing.expect_value(t, json.validate_remaining(&req), nil)
}

// A refused allocation: of the request's own storage it is a refusal, of an output an `Error` after the
// walk, behind the document's own fault.
@(test)
test_request_out_of_memory :: proc(t: ^testing.T) {
	refuse := mem.Allocator{refuse_all, nil}
	req: json.Request({.Path, .Nodes})
	err, refused := json.request_init(&req, ".a", allocator = refuse).?
	testing.expect(t, refused)
	testing.expect_value(t, err.kind, json.Request_Error_Kind.Out_Of_Memory)

	req.paths = []json.Path{{steps = []json.Step{json.Name("a")}}}
	testing.expect_value(t, json.scan(raw(`{"a":[1,2]}`), &req), json.Scan_Error(json.Error{kind = .Out_Of_Memory}))
	fault, is_fault := json.scan(raw(`{"a":[1,2]`), &req).(json.Error)
	testing.expect(t, is_fault && fault.kind != .Out_Of_Memory, "the document's fault comes first")
	json.destroy(&req)

	// The miss `.All` owes at the document's end is an output too.
	miss := json.Request({.Path}){duplicates = .All, allocator = refuse}
	miss.paths = []json.Path{{steps = []json.Step{json.Index(-2)}}}
	testing.expect_value(t, json.scan(raw(`[1]`), &miss), json.Scan_Error(json.Error{kind = .Out_Of_Memory}))
	json.destroy(&miss)
}

// Grouping several paths' answers allocates. A refusal is `.Out_Of_Memory`, and a later call groups them.
@(test)
test_answers_grouping_out_of_memory :: proc(t: ^testing.T) {
	refusing := false
	gate := mem.Allocator{refuse_when_set, &refusing}
	req := json.Request({.Path}){allocator = gate}
	defer json.destroy(&req)
	req.paths = []json.Path{{steps = []json.Step{json.Any{}, json.Name("y")}}, {steps = []json.Step{json.Any{}, json.Name("x")}}}
	testing.expect_value(t, json.scan(raw(`[{"x":1,"y":2},{"x":3,"y":4}]`), &req), nil)
	refusing = true
	got, err := json.answers(&req, 0)
	testing.expect_value(t, err, json.Error{kind = .Out_Of_Memory})
	testing.expect_value(t, len(got), 0)
	testing.expect_value(t, len(req.answers), 4)
	refusing = false
	got, err = json.answers(&req, 1)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(got), 2)
}

// `context.allocator`, refusing every allocation while `data^` (a `bool`) is set.
@(private = "file")
refuse_when_set :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	if (^bool)(data)^ && mode != .Free && mode != .Free_All {
		return nil, .Out_Of_Memory
	}
	return context.allocator.procedure(context.allocator.data, mode, size, alignment, old_memory, old_size, loc)
}

@(private = "file")
refuse_all :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	#partial switch mode {
	case .Free, .Free_All:
		return nil, nil
	}
	return nil, .Out_Of_Memory
}

// `.Lazy` stops once every answer is final, which needs `.First`: under `.Last` or `.All` no run settles before
// the item ends, so the request is refused before the walk.
@(test)
test_lazy_without_first_is_refused :: proc(t: ^testing.T) {
	for mode in ([]json.Duplicates{.Default, .Last, .All}) {
		got := paths_run(raw(`{"t":[7],"z":1,"z":2,"z":3}`), []json.Path{{steps = []json.Step{json.Name("z")}}}, .Lazy, mode)
		defer json.destroy(&got.req)
		request_refused(t, got.err, .Lazy_Needs_First)
		testing.expect_value(t, len(got.answers), 0)
	}
}

// The zero value means `.Last` on every route, for a named path and for one through `Any`.
@(test)
test_default_duplicates_is_last :: proc(t: ^testing.T) {
	src := `{"z":1,"z":2,"z":3}`
	for path in ([]json.Path{{steps = []json.Step{json.Name("z")}}, {steps = []json.Step{json.Any{}}}}) {
		got := paths_run(raw(src), []json.Path{path}, duplicates = .Default)
		defer json.destroy(&got.req)
		testing.expect_value(t, got.err, nil)
		testing.expect_value(t, answer_texts(got.answers, src), `3`)
	}
}

@(test)
test_fault_building_needs_strict :: proc(t: ^testing.T) {
	{
		req: json.Request({.Dom})
		defer json.destroy(&req)
		req.strictness = .Structural
		err := json.scan(raw(`[1]`), &req)
		request_refused(t, err, .Nodes_Need_Strict)
		testing.expect_value(t, len(req.doc.rows), 0)
	}
	{
		req: json.Request({.Nodes})
		defer json.destroy(&req)
		req.strictness = .Structural
		err := json.scan(raw(`[1]`), &req)
		request_refused(t, err, .Nodes_Need_Strict)
	}
	{
		// A path answer carries no value, so it is fine at the lower level.
		req: json.Request({.Path})
		defer json.destroy(&req)
		req.strictness = .Structural
		req.paths = []json.Path{{steps = {json.Name("a")}}}
		err := json.scan(raw(`{"a":1}`), &req)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(req.answers), 1)
	}
	{
		// `.Lazy` checks everything it visits, so it can build.
		req: json.Request({.Dom})
		defer json.destroy(&req)
		req.strictness = .Lazy
		req.duplicates = .First
		err := json.scan(raw(`["a\nb"]`), &req)
		testing.expect_value(t, err, nil)
		got, ok := json.get_string(&req.doc, 1)
		testing.expect(t, ok)
		testing.expect_value(t, got, "a\nb")
	}
}

// A refusal is found before anything is touched: the output of an earlier scan is still there, not cleared,
// and no array was bound to an allocator.
@(test)
test_fault_a_refusal_writes_nothing :: proc(t: ^testing.T) {
	req: json.Request({.Path, .Nodes})
	defer json.destroy(&req)
	req.paths = []json.Path{{steps = []json.Step{json.Index(1)}}}
	err := json.scan(raw(`[1,"s"]`), &req)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(req.doc.rows), 3)
	testing.expect_value(t, len(req.answers), 1)

	// A path past the step cap, refused while the node rows were acceptable.
	steps: [33]json.Step // one past the step cap
	for &s in steps {
		s = json.Index(0)
	}
	req.paths = []json.Path{{steps = steps[:]}}
	err = json.scan(raw(`[1,2,3]`), &req)
	testing.expect_value(t, request_refused(t, err, .Over_Capacity).query_kind, Maybe(json.Query)(.Path))
	testing.expect_value(t, len(req.doc.rows), 3)
	testing.expect_value(t, len(req.answers), 1)
	req.paths = []json.Path{{steps = []json.Step{json.Index(1)}}}

	// An allocator mismatch on the answers, after the node rows agreed.
	req.answers.allocator = context.temp_allocator
	err = json.scan(raw(`[1,2,3]`), &req)
	testing.expect_value(t, request_refused(t, err, .Allocator_Mismatch).query_kind, Maybe(json.Query)(.Path))
	testing.expect_value(t, len(req.doc.rows), 3)
	req.answers.allocator = context.allocator

	// The documented misuse: `allocator` changed after a scan, while the outputs are bound to the old one.
	req.allocator = context.temp_allocator
	err = json.scan(raw(`[1,2,3]`), &req)
	request_refused(t, err, .Allocator_Mismatch)
	testing.expect_value(t, len(req.doc.rows), 3)
	req.allocator = context.allocator
}
