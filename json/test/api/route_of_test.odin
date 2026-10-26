package json_tests

// `route_of`: the engine that answers one path of a request, and why not the matcher. The suite is built with and
// without `FORCE_AUTOMATON` (`make test-modes`), which sends every path to the automaton for that one reason.

import json "../.."
import "core:testing"

ROUTE_FORCE_AUTOMATON :: #config(FORCE_AUTOMATON, false)

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
	matcher := json.Path_Route{.Matcher, .None}
	cases := []Case{
		// Plain names over a root object, past a byte order mark and whitespace.
		{`{"a":1}`, {{steps = {A}}}, 0, {}, matcher},
		{"\xEF\xBB\xBF \n{\"a\":1}", {{steps = {A}}}, 0, {}, matcher},
		{`{"a":1}`, {{steps = {A}}, {steps = {B}}}, 1, {}, matcher},
		{`{"a":1}`, {{steps = {A}}}, 0, {duplicates = .All}, matcher},
		{`{"a":1}`, {{steps = {A}}}, 0, {duplicates = .First}, matcher},
		{`[{"a":1}]`, {{steps = {A}}}, 0, {}, {.Automaton, .Root_Not_Object}},
		{`5`, {{steps = {A}}}, 0, {}, {.Automaton, .Root_Not_Object}},
		{``, {{steps = {A}}}, 0, {}, {.Automaton, .Root_Not_Object}},
		// Columns: one wildcard depth, the first column's.
		{`[{"a":1}]`, {{steps = {ANY, A}}}, 0, {}, matcher},
		{`{"x":{"a":1}}`, {{steps = {ANY, A}}, {steps = {ANY, B}}}, 1, {}, matcher},
		{`[[{"a":1}]]`, {{steps = {ANY, ANY, A}}}, 0, {}, matcher},
		{`[[{"a":1}]]`, {{steps = {ANY, A}}, {steps = {ANY, ANY, B}}}, 0, {}, matcher},
		{`[[{"a":1}]]`, {{steps = {ANY, A}}, {steps = {ANY, ANY, B}}}, 1, {}, {.Automaton, .Other_Shape}},
		// A column serves the request, so plain names beside it go to the automaton.
		{`{"a":1}`, {{steps = {ANY, A}}, {steps = {B}}}, 1, {}, {.Automaton, .Other_Shape}},
		// Gated columns share one gate, or none is served.
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}, {steps = {A, ANY, C}}}, 1, {}, matcher},
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}, {steps = {C, ANY, D}}}, 1, {}, {.Automaton, .Other_Gate}},
		{`{"a":[{"b":1}]}`, {{steps = {A, ANY, B}}, {steps = {C}}}, 0, {}, {.Automaton, .Other_Shape}},
		// The steps that only the automaton walks.
		{`{"a":{"b":1}}`, {{steps = {A, B}}}, 0, {}, {.Automaton, .Deep_Name}},
		{`{"a":[1]}`, {{steps = {A, json.Index(0)}}}, 0, {}, {.Automaton, .Index}},
		{`[{"a":1}]`, {{steps = {json.Index(0), A}}}, 0, {}, {.Automaton, .Index}},
		{`[{"a":1}]`, {{steps = {ANY, json.Index(0), A}}}, 0, {}, {.Automaton, .Index}},
		{`{"a":[1]}`, {{steps = {A, ANY}}}, 0, {}, {.Automaton, .Ends_Any}},
		{`[1]`, {{steps = {ANY}}}, 0, {}, {.Automaton, .Ends_Any}},
		{`[{"a":1}]`, {{steps = {ANY, A}, per_element = true}}, 0, {}, {.Automaton, .Per_Element}},
		{`{"a":1}`, {{steps = {}}}, 0, {}, {.Automaton, .Other_Shape}},
		// The walks that carry the automaton alone.
		{`{"a":1}`, {{steps = {A}}}, 0, {dialect = .Jsonc}, {.Automaton, .Forced}},
		{`{"a":1}`, {{steps = {A}}}, 0, {duplicates = .Refuse}, {.Automaton, .Forced}},
		{`[{"a":1}]`, {{steps = {ANY, A}}}, 0, {dialect = .Jsonc}, {.Automaton, .Forced}},
		{`{"a":[1]}`, {{steps = {A, ANY}}}, 0, {duplicates = .Refuse}, {.Automaton, .Forced}},
	}
	for c in cases {
		want := c.want
		if ROUTE_FORCE_AUTOMATON {
			want = {.Automaton, .Forced}
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
	for i in 0 ..< len(names) {
		names[i] = {steps = {json.Name("k")}}
	}
	for which in ([]int{0, 17, 39}) {
		got, err := json.route_of(raw(`{"k":1}`), names[:], which)
		testing.expectf(t, err == nil, "path %d: %v", which, err)
		want := json.Path_Route{.Matcher, .None}
		if ROUTE_FORCE_AUTOMATON {
			want = {.Automaton, .Forced}
		}
		testing.expectf(t, got == want, "path %d: got %v, want %v", which, got, want)
	}
}

@(test)
test_route_of_refusals :: proc(t: ^testing.T) {
	paths := []json.Path{{steps = {json.Name("a")}}}
	for which in ([]int{-1, 1, 7}) {
		got, err := json.route_of(raw(`{"a":1}`), paths, which)
		e, bad := err.?
		testing.expectf(t, bad && e.kind == .Bad_Option && got.engine == .Unknown, "which %d: %v %v", which, got, err)
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
	testing.expectf(t, bad && e.kind == .Over_Capacity && got.engine == .Unknown, "long path: %v %v", got, err)
	// The longest path a scan takes.
	got, err = json.route_of(raw(`{"a":1}`), {{steps = long[:json.MAX_PATH_STEPS]}}, 0)
	testing.expectf(t, err == nil && got.engine == .Automaton, "longest path: %v %v", got, err)
}
