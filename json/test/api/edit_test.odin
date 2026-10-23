package json_tests

// `splice` (§6.1, law 7), `set` (§6.2, law 6), `insert` and `remove` (§6.3).

import json "../.."
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_splice :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := raw(`{"a":1,"b":[2,3]}`)
	edits := []json.Edit{{lo = 5, hi = 6, bytes = raw(`"x"`)}, {lo = 14, hi = 15, bytes = raw(`[]`)}}
	out, err := json.splice(src, edits, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), `{"a":"x","b":[2,[]]}`)

	unsorted := []json.Edit{edits[1], edits[0]}
	_, e1 := json.splice(src, unsorted)
	edit_err(t, e1, .Bad_Edit)
	overlap := []json.Edit{{lo = 5, hi = 7, bytes = raw(`1`)}, {lo = 6, hi = 8, bytes = raw(`2`)}}
	_, e2 := json.splice(src, overlap)
	edit_err(t, e2, .Bad_Edit)
	past := []json.Edit{{lo = 5, hi = 99, bytes = raw(`1`)}}
	_, e3 := json.splice(src, past)
	edit_err(t, e3, .Bad_Edit)
	backwards := []json.Edit{{lo = 7, hi = 5, bytes = raw(`1`)}}
	// A refused edit list allocates nothing: the panic allocator would abort the test.
	_, e5 := json.splice(src, backwards, mem.panic_allocator())
	edit_err(t, e5, .Bad_Edit)

	// Adjacent edits are disjoint.
	adjacent := []json.Edit{{lo = 12, hi = 13, bytes = raw(`[]`)}, {lo = 13, hi = 14, bytes = raw(`,`)}}
	joined, e6 := json.splice(src, adjacent, context.temp_allocator)
	testing.expect_value(t, e6, nil)
	testing.expect_value(t, string(joined), `{"a":1,"b":[[],3]}`)

	// A broken result names its fault with an offset into `out`.
	broken := []json.Edit{{lo = 5, hi = 6, bytes = raw(`1,`)}}
	_, e4 := json.splice(src, broken)
	testing.expect_value(t, edit_err(t, e4, .Bad_Result).offset, u64(7))
}

@(private)
set_text :: proc(t: ^testing.T, src, path: string, value: any, loc := #caller_location) -> string {
	out, err := json.set(raw(src), path, value, context.temp_allocator)
	testing.expect_value(t, err, nil, loc = loc)
	return string(out)
}

@(test)
test_set :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, set_text(t, `{"a":1,"b":{"c":2}}`, ".b.c", "x"), `{"a":1,"b":{"c":"x"}}`)
	testing.expect_value(t, set_text(t, `{ "a" : 1 }`, ".a", 2), `{ "a" : 2 }`)
	testing.expect_value(t, set_text(t, `{"a":1}`, ".a", json.Raw("")), `{"a":null}`)
	testing.expect_value(t, set_text(t, `[1, 2, 3]`, ".[]", 0), `[0, 0, 0]`)
	testing.expect_value(t, set_text(t, `{"a":1,"a":2}`, ".a", 9), `{"a":1,"a":9}`)
	testing.expect_value(t, set_text(t, ` 1 `, ".", []int{1}), ` [1] `)

	_, nf := json.set(raw(`{"a":1}`), ".zz", 1)
	edit_err(t, nf, .Not_Found)
	_, bp := json.set(raw(`{"a":1}`), ".[", 1)
	edit_err(t, bp, .Bad_Path)
	_, bs := json.set(raw(`{"a":1`), ".a", 1)
	testing.expect_value(t, edit_err(t, bs, .Bad_Source).syntax, json.Error_Kind.Truncated)
	p: rawptr
	_, en := json.set(raw(`{"a":1}`), ".a", p)
	testing.expect_value(t, edit_err(t, en, .Encode).encode, json.Encode_Error.Unsupported)
	_, mid := json.set(raw(`{"a":1}`), ".a", []f64{1, math.inf_f64(1)})
	testing.expect_value(t, edit_err(t, mid, .Encode).encode, json.Encode_Error.Non_Finite)
	_, long := json.set(raw(`{"a":1}`), strings.repeat(".a", 33, context.temp_allocator), 1)
	edit_err(t, long, .Over_Capacity)
}

// A `Path_Error` reports the offset into the text it names, and the walk's result or marshal's error that
// caused it.
@(test)
test_edit_error_locates_the_refusal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := []struct {
		src, path: string,
		value:     any,
		want:      json.Path_Error,
	} {
		{"{\n\"a\":1", ".a", 1, {kind = .Bad_Source, syntax = .Truncated, offset = 7}},
		{`{"a":1}`, ".[", 1, {kind = .Bad_Path, offset = 1}},
		{`{"a":1}`, ".zz", 1, {kind = .Not_Found}},
		{`{"a":1}`, ".a", math.inf_f64(1), {kind = .Encode, encode = .Non_Finite}},
	}
	for c in cases {
		_, err := json.set(raw(c.src), c.path, c.value, context.temp_allocator)
		testing.expectf(t, err == c.want, "set %q %s: %v, want %v", c.src, c.path, err, c.want)
	}
	// The offset of a refused result is into the edited text, which `splice` never returns.
	_, err := json.splice(raw(`{"a":1}`), []json.Edit{{lo = 5, hi = 6, bytes = raw(`1,`)}})
	testing.expect_value(t, err, json.Path_Error{kind = .Bad_Result, syntax = .Bad_Char, offset = 7})
}

@(private)
edit_err :: proc(t: ^testing.T, got: Maybe(json.Path_Error), want: json.Path_Error_Kind, loc := #caller_location) -> json.Path_Error {
	e, refused := got.?
	testing.expectf(t, refused && e.kind == want, "%v, want %v", got, want, loc = loc)
	return e
}

@(private)
remove_text :: proc(t: ^testing.T, src, path: string, loc := #caller_location) -> string {
	out, err := json.remove(raw(src), path, context.temp_allocator)
	testing.expect_value(t, err, nil, loc = loc)
	return string(out)
}

@(test)
test_remove :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	obj := `{"a":1,"b":2,"c":3}`
	testing.expect_value(t, remove_text(t, obj, ".a"), `{"b":2,"c":3}`)
	testing.expect_value(t, remove_text(t, obj, ".b"), `{"a":1,"c":3}`)
	testing.expect_value(t, remove_text(t, obj, ".c"), `{"a":1,"b":2}`)
	testing.expect_value(t, remove_text(t, `{"a":1}`, ".a"), `{}`)
	pretty := "{\n  \"a\": 1,\n  \"b\": [\n    1,\n    2\n  ],\n  \"c\": 3\n}"
	testing.expect_value(t, remove_text(t, pretty, ".a"), "{\n  \"b\": [\n    1,\n    2\n  ],\n  \"c\": 3\n}")
	testing.expect_value(t, remove_text(t, pretty, ".b"), "{\n  \"a\": 1,\n  \"c\": 3\n}")
	testing.expect_value(t, remove_text(t, pretty, ".c"), "{\n  \"a\": 1,\n  \"b\": [\n    1,\n    2\n  ]\n}")
	testing.expect_value(t, remove_text(t, pretty, ".b[0]"), "{\n  \"a\": 1,\n  \"b\": [\n    2\n  ],\n  \"c\": 3\n}")
	testing.expect_value(t, remove_text(t, "{\n  \"a\": 1\n}", ".a"), "{}")
	testing.expect_value(t, remove_text(t, `[1, 2, 3]`, ".[1]"), `[1, 3]`)
	testing.expect_value(t, remove_text(t, `[1, 2, 3]`, ".[-1]"), `[1, 2]`)
	testing.expect_value(t, remove_text(t, `[ 1, 2 ]`, ".[]"), `[]`)
	// An `Any` path removes from every holder, a lone member and a middle one alike.
	testing.expect_value(t, remove_text(t, `[{"a":1,"b":2},{"b":3},{"a":4}]`, ".[].a"), `[{"b":2},{"b":3},{}]`)
	// Every occurrence of a repeated key goes: a run before a survivor and a run at the end.
	testing.expect_value(t, remove_text(t, `{"a":1, "b":2, "a":3}`, ".a"), `{"b":2}`)
	testing.expect_value(t, remove_text(t, `{"o":{"a":1},"o":{"a":2,"b":3}}`, ".o.a"), `{"o":{},"o":{"b":3}}`)

	_, root := json.remove(raw(`{"a":1}`), ".")
	edit_err(t, root, .Unplaceable)
	_, nf := json.remove(raw(`{"a":1}`), ".b")
	edit_err(t, nf, .Not_Found)
	_, bs := json.remove(raw(`{"a":1,}`), ".a")
	edit_err(t, bs, .Bad_Source)
	_, bp := json.remove(raw(`{"a":1}`), ".[")
	edit_err(t, bp, .Bad_Path)
}

@(private)
insert_text :: proc(t: ^testing.T, src, path: string, at: json.Insert_At, value: any, loc := #caller_location) -> string {
	out, err := json.insert(raw(src), path, at, value, context.temp_allocator)
	testing.expect_value(t, err, nil, loc = loc)
	return string(out)
}

@(test)
test_insert :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, insert_text(t, `{"a":1}`, ".", "b", 2), `{"a":1,"b":2}`)
	testing.expect_value(t, insert_text(t, `{}`, ".", "b", "x"), `{"b":"x"}`)
	testing.expect_value(t, insert_text(t, `{ "a" : 1 }`, ".", "b", 2), `{ "a" : 1, "b" : 2 }`)
	testing.expect_value(t, insert_text(t, "{\n  \"a\": 1\n}", ".", "b", 2), "{\n  \"a\": 1,\n  \"b\": 2\n}")
	testing.expect_value(t, insert_text(t, "{\n  \"a\": 1,\n  \"b\": 2\n}", ".", "c", []int{3}),
		"{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": [3]\n}")
	testing.expect_value(t, insert_text(t, `{"a":1}`, ".", "q\"", 2), `{"a":1,"q\"":2}`)
	testing.expect_value(t, insert_text(t, `[1, 2]`, ".", 0, 0), `[0, 1, 2]`)
	testing.expect_value(t, insert_text(t, `[1, 2]`, ".", 1, 0), `[1, 0, 2]`)
	testing.expect_value(t, insert_text(t, `[1, 2]`, ".", 2, 0), `[1, 2, 0]`)
	testing.expect_value(t, insert_text(t, `[1, 2]`, ".", json.APPEND, 0), `[1, 2, 0]`)
	testing.expect_value(t, insert_text(t, `[]`, ".", 0, 0), `[0]`)
	testing.expect_value(t, insert_text(t, "[\n  1\n]", ".", 0, 0), "[\n  0,\n  1\n]")
	testing.expect_value(t, insert_text(t, "[\n  1\n]", ".", json.APPEND, 2), "[\n  1,\n  2\n]")
	testing.expect_value(t, insert_text(t, `{"x":[1],"y":[]}`, ".[]", json.APPEND, 9), `{"x":[1,9],"y":[9]}`)
	// Under `.Last` the later of two repeated keys is the one the path names.
	testing.expect_value(t, insert_text(t, `{"o":{"a":1},"o":{"b":2}}`, ".o", "c", 3), `{"o":{"a":1},"o":{"b":2,"c":3}}`)

	testing.expect_value(t, insert_text(t, `{"a":1, "a":2}`, ".", "b", 3), `{"a":1, "a":2, "b":3}`)

	_, ex := json.insert(raw(`{"a":1,"a":2}`), ".", "a", 3)
	edit_err(t, ex, .Exists)
	_, kind := json.insert(raw(`[1]`), ".", "a", 3)
	edit_err(t, kind, .Unplaceable)
	_, past := json.insert(raw(`[1]`), ".", 2, 3)
	edit_err(t, past, .Unplaceable)
	// A negative index counts from the end: -1 goes before the last member.
	testing.expect_value(t, insert_text(t, `[1, 2]`, ".", -1, 0), `[1, 0, 2]`)
	testing.expect_value(t, insert_text(t, `[1, 2]`, ".", -2, 0), `[0, 1, 2]`)
	_, neg := json.insert(raw(`[1]`), ".", -2, 3)
	edit_err(t, neg, .Unplaceable)
	_, scalar := json.insert(raw(`{"a":1}`), ".a", 0, 3)
	edit_err(t, scalar, .Unplaceable)
	_, nf := json.insert(raw(`{"a":1}`), ".b", "c", 3)
	edit_err(t, nf, .Not_Found)
	_, deep := json.insert(raw(`[]`), ".", 0, json.Raw(strings.repeat("[", json.MAX_DEPTH, context.temp_allocator)))
	testing.expect(t, deep != nil)
}

@(test)
test_set_upsert :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	upsert :: proc(t: ^testing.T, src, path: string, value: any, loc := #caller_location) -> string {
		out, err := json.set(raw(src), path, value, context.temp_allocator, upsert = true)
		testing.expect_value(t, err, nil, loc = loc)
		return string(out)
	}
	testing.expect_value(t, upsert(t, `{"a":1}`, ".b", 2), `{"a":1,"b":2}`)
	testing.expect_value(t, upsert(t, `{"a":1}`, ".a", 5), `{"a":5}`)
	testing.expect_value(t, upsert(t, `{"a":1,"a":2}`, ".a", 9), `{"a":1,"a":9}`)
	testing.expect_value(t, upsert(t, `[{"a":1}, {}]`, ".[].a", 0), `[{"a":0}, {"a":0}]`)
	_, idx := json.set(raw(`[1]`), ".[0]", 0, upsert = true)
	edit_err(t, idx, .Unplaceable)
	_, arr := json.set(raw(`[1]`), ".[].a", 0, upsert = true)
	edit_err(t, arr, .Unplaceable)
	_, nf := json.set(raw(`{}`), ".x.a", 0, upsert = true)
	edit_err(t, nf, .Not_Found)
	// Off, a miss is still a miss.
	_, off := json.set(raw(`{"a":1}`), ".b", 2)
	edit_err(t, off, .Not_Found)
}

// A refused allocation anywhere in an edit is `.Out_Of_Memory`, never a result missing an edit, and leaks
// nothing: each edit runs with the k-th allocation and every later one refused, k counting up until none is.
@(test)
test_edit_out_of_memory :: proc(t: ^testing.T) {
	Edit_Op :: enum {
		Set,
		Upsert,
		Insert,
		Remove,
		Comment,
	}
	Case :: struct {
		op:      Edit_Op,
		dialect: json.Dialect,
		src:     string,
		path:    string,
	}
	cases := []Case {
		{.Set, .Json, `[1,2,3,4,5,6,7,8,9]`, ".[]"},
		{.Upsert, .Json, `[{"a":1},{},{"b":2}]`, ".[].a"},
		{.Insert, .Json, `{"a":[1,2],"b":[3]}`, ".[]"},
		{.Insert, .Jsonc, "{\"a\":[1, // one\n2],\"b\":[3]}", ".[]"},
		{.Remove, .Json, `[[1,2,3],[4,5,6],[7,8,9]]`, ".[][1]"},
		{.Remove, .Jsonc, "[[1, /* x */ 2,3],[4,5,6]]", ".[][1]"},
		{.Comment, .Jsonc, `{"a":1,"b":2}`, ".[]"},
	}
	run :: proc(c: Case, allocator: mem.Allocator) -> ([]byte, Maybe(json.Path_Error)) {
		switch c.op {
		case .Set:
			return json.set(raw(c.src), c.path, 0, allocator, dialect = c.dialect)
		case .Upsert:
			return json.set(raw(c.src), c.path, 0, allocator, upsert = true, dialect = c.dialect)
		case .Insert:
			return json.insert(raw(c.src), c.path, 0, "x", allocator, c.dialect)
		case .Remove:
			return json.remove(raw(c.src), c.path, allocator, c.dialect)
		case .Comment:
			return json.edit_comment(raw(c.src), c.path, .Lead, "// x", .Insert, allocator)
		}
		return nil, nil
	}
	for c in cases {
		want, werr := run(c, context.allocator)
		defer delete(want)
		testing.expect_value(t, werr, nil)
		sweep := Budget_Sweep{limit = 1000}
		for b, k in next_budget(&sweep) {
			out, err := run(c, budget_allocator(b))
			if !b.refused {
				testing.expect_value(t, string(out), string(want))
				delete(out)
				continue
			}
			e, ok := err.?
			testing.expectf(t, ok && e.kind == .Out_Of_Memory && out == nil, "%v at allocation %d: %v, %q", c.op, k, err, string(out))
			delete(out)
		}
		expect_swept(t, &sweep)
	}
}

// `set` of a path every scan answered with a `Type_Mismatch` (a step the value cannot take) is
// `.Type_Mismatch`, a path that simply is not there stays `.Not_Found`.
@(test)
test_set_names_a_type_mismatch :: proc(t: ^testing.T) {
	for c in ([][2]string{{`[1,2]`, ".a"}, {`{"a":1}`, ".[0]"}, {`{"a":1}`, ".a.b"}, {`{"a":1}`, ".a[0]"}}) {
		_, err := json.set(raw(c[0]), c[1], 0)
		edit_err(t, err, .Type_Mismatch)
	}
	_, miss := json.set(raw(`{"a":1}`), ".z", 0)
	edit_err(t, miss, .Not_Found)
}

// A comment an edit opens must not swallow source values after it: `splice` refuses the result.
@(test)
test_splice_refuses_a_comment_that_swallows_values :: proc(t: ^testing.T) {
	src := raw("[1, 2\n]")
	_, err := json.splice(src, []json.Edit{{lo = 2, hi = 3, bytes = raw(" //")}}, dialect = .Jsonc)
	edit_err(t, err, .Bad_Result)
	// A comment that ends inside the edit is fine.
	out, ok := json.splice(src, []json.Edit{{lo = 2, hi = 3, bytes = raw(", /* c */")}}, dialect = .Jsonc)
	testing.expect_value(t, ok, nil)
	testing.expect_value(t, string(out), "[1, /* c */ 2\n]")
	delete(out)
}

