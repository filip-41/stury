package json_tests

// `Path.per_element`: a path with an `Any` step answers once per element, as jq outputs `A[] B`: the value,
// `.Missing` where jq gives null, `.Type_Mismatch` where jq errors.

import json "../.."
import "core:strings"
import "core:testing"

// Path 0's answers in `src` joined with `,`: a `Found` as its text, `.Missing` as `null`, `.Type_Mismatch` as `!`.
@(private = "file")
each_texts :: proc(t: ^testing.T, src: string, path: json.Path, level: json.Strictness, mode := json.Duplicates.Last, loc := #caller_location) -> string {
	paths := []json.Path{path}
	r := paths_run(raw(src), paths, level, mode)
	defer json.destroy(&r.req)
	testing.expectf(t, r.err == nil, "%s %v: %v", src, level, r.err, loc = loc)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for a, i in r.answers {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		switch a.outcome {
		case .Found:         strings.write_string(&b, src[a.lo:a.hi])
		case .Missing:       strings.write_string(&b, "null")
		case .Type_Mismatch: strings.write_byte(&b, '!')
		}
	}
	return strings.to_string(b)
}

@(test)
test_per_element_answers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	X, Z, A :: json.Name("x"), json.Name("z"), json.Name("a")
	Case :: struct {
		src:   string,
		steps: []json.Step,
		limit: int,
		want:  string,
	}
	cases := []Case{
		// A member found, missing, null, and a step on a scalar or an array.
		{`[{"x":1},{"y":2},{"x":null},null,5,[1],{"x":{"z":1}}]`, {ANY, X}, 0, `1,null,null,null,!,!,{"z":1}`},
		// Null carries through the steps after the `[]`. A scalar does not.
		{`[{"x":{"z":1}},{"x":{}},{"x":null},{"x":3},{}]`, {ANY, X, Z}, 0, `1,null,null,!,null`},
		{`[[7],[],{"a":1},null,"s"]`, {ANY, json.Index(0)}, 0, `7,null,!,null,!`},
		{`[[1,2],[],[3]]`, {ANY, json.Index(-1)}, 0, `2,null,3`},
		// An empty container has no element. A holder that is none is an error.
		{`[]`, {ANY}, 0, ``},
		{`{}`, {ANY, X}, 0, ``},
		{`5`, {ANY}, 0, `!`},
		{`null`, {ANY, X}, 0, `!`},
		{`{"b":1}`, {A, ANY}, 0, `!`},
		{`{"a":null}`, {A, ANY}, 0, `!`},
		{`{"a":[1,2]}`, {A, ANY}, 0, `1,2`},
		// Nested `[]`: a miss or null before the last one is an error.
		{`[[1],[],5,{"a":2}]`, {ANY, ANY}, 0, `1,!,2`},
		{`[{"a":[1]},{},{"a":null}]`, {ANY, A, ANY}, 0, `1,!,!`},
		// The limit counts every answer.
		{`[{"y":1},{"x":2},{"x":3}]`, {ANY, X}, 2, `null,2`},
		{`[5,{"x":2},{"x":3}]`, {ANY, X}, 1, `!`},
		// A repeated key in an element: its last occurrence answers.
		{`[{"x":1,"x":2},{"x":{},"x":3}]`, {ANY, X}, 0, `2,3`},
		{`[{"x":5,"x":{"z":1}},{"x":{"z":1},"x":5},{"x":{},"x":{"z":2}}]`, {ANY, X, Z}, 0, `1,!,2`},
		// A repeated key of the object `[]` reads: one element, at its first place, with its last value.
		{`{"a":{"x":1},"b":{},"a":{"y":2}}`, {ANY, X}, 0, `null,null`},
		{`{"a":{"x":1},"b":5,"a":{"x":3}}`, {ANY, X}, 0, `3,!`},
	}
	for c in cases {
		for level in ([]json.Strictness{.Strict, .Structural}) {
			got := each_texts(t, c.src, {steps = c.steps, limit = c.limit, per_element = true}, level)
			testing.expectf(t, got == c.want, "%s %v %v: %s, want %s", c.src, c.steps, level, got, c.want)
		}
	}
}

// A path without `per_element` keeps its answers beside one with it: only where it lands.
@(test)
test_per_element_beside_plain :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := `{"logs":[{"id":1},{"x":0},{"id":3}]}`
	steps := []json.Step{json.Name("logs"), ANY, json.Name("id")}
	paths := []json.Path{{steps = steps}, {steps = steps, per_element = true}}
	r := paths_run(raw(src), paths)
	defer json.destroy(&r.req)
	testing.expect(t, r.err == nil)
	testing.expect_value(t, answer_texts(r.answers, src, 0), `1,3`)
	n := 0
	for a in r.answers {
		if a.query == 1 {
			n += 1
		}
	}
	testing.expect_value(t, n, 3)
}
