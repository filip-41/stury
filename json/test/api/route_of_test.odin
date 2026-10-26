package json_tests

// `route_of`: the engine that answers one path of a request, or why the automaton does. The suite is built with and
// without `FORCE_AUTOMATON` (`make test-modes`), which sends every path to the automaton for that one reason.

import json "../.."
import "core:fmt"
import "core:testing"

ROUTE_FORCE_AUTOMATON :: #config(FORCE_AUTOMATON, false)

// The paths the automaton binds.
AUTOMATON_PATHS :: 16

@(test)
test_route_of_reasons :: proc(t: ^testing.T) {
	A, B, C, D := json.Name("a"), json.Name("b"), json.Name("c"), json.Name("d")
	Case :: struct {
		src:   string,
		paths: []json.Path,
		which: int,
		opts:  json.Read_Opts,
		want:  json.Path_Route,
	}
	cases := []Case{
		// Plain names over a root object, past a byte order mark and whitespace.
		{`{"a":1}`, {{steps = {A}}}, 0, {}, .Matcher},
		{"\xEF\xBB\xBF \n{\"a\":1}", {{steps = {A}}}, 0, {}, .Matcher},
		{`{"a":1}`, {{steps = {A}}, {steps = {B}}}, 1, {}, .Matcher},
		{`{"a":1}`, {{steps = {A}}}, 0, {duplicates = .All}, .Matcher},
		{`{"a":1}`, {{steps = {A}}}, 0, {duplicates = .First}, .Matcher},
		{`[{"a":1}]`, {{steps = {A}}}, 0, {}, .Root_Not_Object},
		{`5`, {{steps = {A}}}, 0, {}, .Root_Not_Object},
		{``, {{steps = {A}}}, 0, {}, .Root_Not_Object},
		// Columns: one wildcard depth, the first column's.
		{`[{"a":1}]`, {{steps = {ANY, A}}}, 0, {}, .Matcher},
		{`{"x":{"a":1}}`, {{steps = {ANY, A}}, {steps = {ANY, B}}}, 1, {}, .Matcher},
		{`[[{"a":1}]]`, {{steps = {ANY, ANY, A}}}, 0, {}, .Matcher},
		{`[[{"a":1}]]`, {{steps = {ANY, A}}, {steps = {ANY, ANY, B}}}, 0, {}, .Matcher},
		{`[[{"a":1}]]`, {{steps = {ANY, A}}, {steps = {ANY, ANY, B}}}, 1, {}, .Other_Shape},
		// A column serves the request, so plain names beside it go to the automaton.
		{`{"a":1}`, {{steps = {ANY, A}}, {steps = {B}}}, 1, {}, .Other_Shape},
		// Gated columns share one gate, or none is served. Two or more of them on `.Strict` JSON are the tape's.
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}}, 0, {}, .Matcher},
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}, {steps = {A, ANY, C}}}, 1, {}, .Tape},
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}, {steps = {A, ANY, C}}}, 1, {strictness = .Lazy, duplicates = .First}, .Matcher},
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}, {steps = {A, ANY, C}}}, 1, {strictness = .Structural}, .Matcher},
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}, {steps = {A, ANY, C}}}, 1, {limits = {max_depth = json.MAX_DEPTH + 1}}, .Matcher},
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}, {steps = {A, ANY, C}}}, 1, {dialect = .Jsonc}, .Forced},
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}, {steps = {C, ANY, D}}}, 1, {}, .Other_Gate},
		// Gated columns beside a plain name: the gate fails whatever the root, and the name is the matcher's over
		// an object root only.
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}, {steps = {C}}}, 0, {}, .Other_Gate},
		{`[1]`, {{steps = {A, ANY, B}}, {steps = {C}}}, 0, {}, .Other_Gate},
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}, {steps = {C}}}, 1, {}, .Matcher},
		{`[1]`, {{steps = {A, ANY, B}}, {steps = {C}}}, 1, {}, .Root_Not_Object},
		{`[{"a":1}]`, {{steps = {A, ANY, B}}, {steps = {ANY, C}}}, 0, {}, .Other_Shape},
		// The steps that only the automaton walks.
		{`{"a":{"b":1}}`, {{steps = {A, B}}}, 0, {}, .Deep_Name},
		{`{"a":[1]}`, {{steps = {A, json.Index(0)}}}, 0, {}, .Index},
		{`[{"a":1}]`, {{steps = {json.Index(0), A}}}, 0, {}, .Index},
		{`[{"a":1}]`, {{steps = {ANY, json.Index(0), A}}}, 0, {}, .Index},
		{`{"a":[1]}`, {{steps = {A, ANY}}}, 0, {}, .Ends_Any},
		{`[1]`, {{steps = {ANY}}}, 0, {}, .Ends_Any},
		{`[{"a":1}]`, {{steps = {ANY, A}, per_element = true}}, 0, {}, .Per_Element},
		{`{"a":1}`, {{steps = {}}}, 0, {}, .Other_Shape},
		// The walks that carry the automaton alone.
		{`{"a":1}`, {{steps = {A}}}, 0, {dialect = .Jsonc}, .Forced},
		{`{"a":1}`, {{steps = {A}}}, 0, {duplicates = .Refuse}, .Forced},
		{`[{"a":1}]`, {{steps = {ANY, A}}}, 0, {dialect = .Jsonc}, .Forced},
		{`{"a":[1]}`, {{steps = {A, ANY}}}, 0, {duplicates = .Refuse}, .Forced},
	}
	for c in cases {
		want := c.want
		if ROUTE_FORCE_AUTOMATON {
			want = .Forced
		}
		got, err := json.route_of(raw(c.src), c.paths, c.which, c.opts)
		testing.expectf(t, err == nil, "%q %v: %v", c.src, c.paths, err)
		testing.expectf(t, got == want, "%q %v path %d: got %v, want %v", c.src, c.paths, c.which, got, want)
	}
}

// Many plain names are still the matcher's, past what the inline plan holds.
@(test)
test_route_of_many_names :: proc(t: ^testing.T) {
	names: [40]json.Path
	steps: [len(names)]json.Step
	for i in 0 ..< len(names) {
		steps[i] = json.Name(fmt.tprintf("k%d", i))
		names[i] = {steps = steps[i:][:1]}
	}
	defer free_all(context.temp_allocator)
	for which in ([]int{0, 17, 39}) {
		got, err := json.route_of(raw(`{"k0":1}`), names[:], which)
		if ROUTE_FORCE_AUTOMATON {
			// Forty paths for the automaton, which binds sixteen.
			e, bad := err.?
			testing.expectf(t, bad && e.kind == .Over_Capacity, "path %d: %v %v", which, got, err)
			continue
		}
		testing.expectf(t, err == nil && got == .Matcher, "path %d: got %v, %v", which, got, err)
	}
}

@(test)
test_route_of_refusals :: proc(t: ^testing.T) {
	paths := []json.Path{{steps = {json.Name("a")}}}
	for which in ([]int{-1, 1, 7}) {
		got, err := json.route_of(raw(`{"a":1}`), paths, which)
		e, bad := err.?
		testing.expectf(t, bad && e.kind == .Bad_Option, "which %d: %v %v", which, got, err)
	}
	_, none := json.route_of(raw(`{"a":1}`), nil, 0)
	testing.expect(t, none != nil, "no paths: want Bad_Option")

	long := make([]json.Step, json.MAX_PATH_STEPS + 1, context.temp_allocator)
	for &s in long {
		s = json.Name("a")
	}
	defer free_all(context.temp_allocator)
	got, err := json.route_of(raw(`{"a":1}`), {{steps = long}}, 0)
	e, bad := err.?
	testing.expectf(t, bad && e.kind == .Over_Capacity, "long path: %v %v", got, err)
	// The longest path a scan takes.
	got, err = json.route_of(raw(`{"a":1}`), {{steps = long[:json.MAX_PATH_STEPS]}}, 0)
	want := json.Path_Route.Forced if ROUTE_FORCE_AUTOMATON else .Deep_Name
	testing.expectf(t, err == nil && got == want, "longest path: %v %v", got, err)
}

// The refusals `scan` gives a request that does not fit the router's bounds.
@(test)
test_route_of_scan_bounds :: proc(t: ^testing.T) {
	deep: [AUTOMATON_PATHS + 1]json.Path
	same: [AUTOMATON_PATHS + 1]json.Path
	for i in 0 ..< len(deep) {
		deep[i] = {steps = {json.Name("a"), json.Name("b")}}
		same[i] = {steps = {json.Name("a")}}
	}
	for paths in ([][]json.Path{deep[:], same[:]}) {
		_, err := json.route_of(raw(`{"a":{"b":1}}`), paths, 0)
		e, bad := err.?
		testing.expectf(t, bad && e.kind == .Over_Capacity, "%d paths: %v", len(paths), err)
		// The request fills the automaton's bound exactly.
		_, err = json.route_of(raw(`{"a":{"b":1}}`), paths[:AUTOMATON_PATHS], 0)
		e, bad = err.?
		testing.expectf(t, !bad || e.kind != .Over_Capacity, "%d paths: %v", AUTOMATON_PATHS, err)
	}
}
