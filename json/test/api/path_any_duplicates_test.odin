package json_tests

// `Any` over an object that repeats a key: jq's `.[]` outputs the key once, at its first occurrence's place, with
// its last value. `.Last` reads it so, `.First` keeps the first value in that place, `.All` answers every
// occurrence in source order, and `.Refuse` faults at the repeat.

import json "../.."
import "core:testing"

// The text of `path`'s answers in `src` under `mode` and `level`, joined with `,`. `query` picks the path of
// a request that names several.
@(private = "file")
any_texts :: proc(
	t: ^testing.T,
	src: string,
	paths: []json.Path,
	mode: json.Duplicates,
	level: json.Strictness,
	query: u32 = 0,
	loc := #caller_location,
) -> string {
	r := paths_run(raw(src), paths, level, mode)
	defer json.destroy(&r.req)
	testing.expectf(t, r.err == nil, "%s %v %v: %v", src, mode, level, r.err, loc = loc)
	return answer_texts(r.answers, src, query)
}

@(test)
test_any_repeated_key :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		src:                 string,
		steps:               []json.Step,
		last, first, all:    string,
	}
	cases := []Case{
		// The brief's object: the repeat sits in the first `a`'s place.
		{`{"a":1,"b":0,"a":2}`, {ANY}, `2,0`, `1,0`, `1,0,2`},
		// The repeat is nested under the second `Any`, and the outer key repeats too.
		{`{"x":{"a":1,"b":0,"a":2},"y":[5]}`, {ANY, ANY}, `2,0,5`, `1,0,5`, `1,0,2,5`},
		{`{"x":[1],"y":[2],"x":[3,4]}`, {ANY, ANY}, `3,4,2`, `1,2`, `1,2,3,4`},
		// Records of an array, one of which repeats a key.
		{`{"logs":[{"a":1,"b":0,"a":2},{"c":3}]}`, {json.Name("logs"), ANY, ANY}, `2,0,3`, `1,0,3`, `1,0,2,3`},
		// A column under an object `Any`.
		{`{"p":{"id":1},"q":{"id":2},"p":{"id":3}}`, {ANY, json.Name("id")}, `3,2`, `1,2`, `1,2,3`},
		// A key written with an escape repeats its literal text.
		{`{"a":1,"a":2,"b":0}`, {ANY}, `2,0`, `1,0`, `1,2,0`},
		// No repeat: every mode reads the object alike.
		{`{"a":1,"b":0,"c":2}`, {ANY}, `1,0,2`, `1,0,2`, `1,0,2`},
	}
	for c in cases {
		for level in ([]json.Strictness{.Strict, .Structural}) {
			p := []json.Path{{steps = c.steps}}
			testing.expectf(t, any_texts(t, c.src, p, .Last, level) == c.last, "%s %v last: %s", c.src, level, any_texts(t, c.src, p, .Last, level))
			testing.expectf(t, any_texts(t, c.src, p, .First, level) == c.first, "%s %v first: %s", c.src, level, any_texts(t, c.src, p, .First, level))
			testing.expectf(t, any_texts(t, c.src, p, .All, level) == c.all, "%s %v all: %s", c.src, level, any_texts(t, c.src, p, .All, level))
		}
	}
}

// Two gated columns under one `Any` take the tape route. A repeated object key must resolve there too, and a
// path of the same request that has no `Any` keeps its answers.
@(test)
test_any_repeated_key_columns :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := `{"n":7,"p":{"id":1,"k":9},"q":{"id":2,"k":8},"p":{"id":3,"k":7}}`
	paths := []json.Path{{steps = {ANY, json.Name("id")}}, {steps = {ANY, json.Name("k")}}, {steps = {json.Name("n")}}}
	for level in ([]json.Strictness{.Strict, .Structural}) {
		testing.expect_value(t, any_texts(t, src, paths, .Last, level, 0), `3,2`)
		testing.expect_value(t, any_texts(t, src, paths, .Last, level, 1), `7,8`)
		testing.expect_value(t, any_texts(t, src, paths, .Last, level, 2), `7`)
		testing.expect_value(t, any_texts(t, src, paths, .First, level, 0), `1,2`)
		testing.expect_value(t, any_texts(t, src, paths, .First, level, 1), `9,8`)
		testing.expect_value(t, any_texts(t, src, paths, .All, level, 0), `1,2,3`)
	}
}

// A path's limit counts the outputs jq makes, so the repeat is one of them.
@(test)
test_any_repeated_key_limit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	paths := []json.Path{{steps = {ANY}, limit = 1}}
	testing.expect_value(t, any_texts(t, `{"a":1,"b":0,"a":2}`, paths, .Last, .Strict), `2`)
	testing.expect_value(t, any_texts(t, `{"a":1,"b":0,"a":2}`, paths, .First, .Strict), `1`)
}

// A text another follows is `.Trailing`, and its first text is answered whole, a repeat settled too.
@(test)
test_any_repeated_key_trailing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := `{"a":1,"b":0,"a":2} 7`
	r := paths_run(raw(src), {{steps = {ANY}}}, .Strict, .Last)
	defer json.destroy(&r.req)
	e, is_error := r.err.(json.Error)
	testing.expectf(t, is_error && e.kind == .Trailing, "%v, want Trailing", r.err)
	testing.expect_value(t, len(r.answers), 2)
	if len(r.answers) == 2 {
		testing.expect_value(t, src[r.answers[0].lo:r.answers[0].hi], `2`)
		testing.expect_value(t, src[r.answers[1].lo:r.answers[1].hi], `0`)
	}
}

// `.Refuse` faults at the repeat, wherever the `Any` meets it.
@(test)
test_any_repeated_key_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		src:    string,
		steps:  []json.Step,
		offset: u64,
	}
	cases := []Case{
		{`{"a":1,"b":0,"a":2}`, {ANY}, 13},
		{`{"x":{"a":1,"a":2}}`, {ANY, ANY}, 12},
	}
	for c in cases {
		r := paths_run(raw(c.src), {{steps = c.steps}}, .Strict, .Refuse)
		defer json.destroy(&r.req)
		e, is_error := r.err.(json.Error)
		testing.expectf(t, is_error && e.kind == .Duplicate_Key && e.offset == c.offset, "%s: %v, want a Duplicate_Key at %d", c.src, r.err, c.offset)
	}
}
