package json_tests

// `find`: one path, one scan, the first answer, and nothing kept.

import json "../.."
import "core:testing"

@(test)
test_find_answers_text_and_built_paths_alike :: proc(t: ^testing.T) {
	src := raw(`{"name": "ada", "tags": ["math", "engines"]}`)
	a, err := json.find(src, ".tags[1]")
	testing.expect_value(t, err, nil)
	testing.expectf(t, a.outcome == .Found && string(src[a.lo:a.hi]) == `"engines"`, "%v", a)
	b, berr := json.find(src, json.Path{steps = {json.Name("tags"), json.Index(1)}})
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, b, a)
}

@(test)
test_find_reports_a_miss_and_a_mismatch :: proc(t: ^testing.T) {
	src := raw(`{"a": [1, 2]}`)
	m, err := json.find(src, ".b")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.outcome, json.Answer_Outcome.Missing)
	testing.expect_value(t, m.owner, u64(0)) // the object lacking `b` starts the source
	root, rerr := json.find(src, ".")
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, root.owner, json.NO_OWNER)
	x, xerr := json.find(src, ".a.b")
	testing.expect_value(t, xerr, nil)
	testing.expect_value(t, x.outcome, json.Answer_Outcome.Type_Mismatch)
}

// An `Any` path gives its first landing; with `per_element` the first element decides, as jq's `first(.[].x)`.
@(test)
test_find_takes_the_first_answer_of_an_any_path :: proc(t: ^testing.T) {
	src := raw(`{"logs":[{"id":7},{"id":8}]}`)
	a, err := json.find(src, ".logs[].id")
	testing.expect_value(t, err, nil)
	testing.expectf(t, a.outcome == .Found && string(src[a.lo:a.hi]) == "7", "%v", a)
	p, perr := json.find(raw(`[{},{"x":1}]`), json.Path{steps = {json.Any{}, json.Name("x")}, per_element = true})
	testing.expect_value(t, perr, nil)
	testing.expect_value(t, p.outcome, json.Answer_Outcome.Missing)
}

@(test)
test_find_returns_the_scan_result_and_an_empty_answer :: proc(t: ^testing.T) {
	bad, err := json.find(raw(`{"a": 01}`), ".a")
	e, is_fault := err.?
	is_fault = is_fault && e.kind == .Bad_Source && e.syntax == .Bad_Number
	testing.expectf(t, is_fault && bad.outcome == .Missing, "%v %v", err, bad)
	testing.expect_value(t, bad.owner, json.NO_OWNER)
	_, perr := json.find(raw(`{}`), ".a-b")
	r, refused := perr.?
	testing.expectf(t, refused && r.kind == .Bad_Path, "%v", perr)
	src := raw(`{"a":1,"b":[1,2,3]}`)
	a, lerr := json.find(src, ".a", {strictness = .Lazy, duplicates = .First})
	testing.expect_value(t, lerr, nil)
	testing.expectf(t, a.outcome == .Found && string(src[a.lo:a.hi]) == "1", "%v", a)
	// `.Lazy` under `.Default`, `.Last` and `.All` reads as `.Strict`: the last repeat (the first answer of
	// `.All`), and a fault after the answer is still the text's.
	dup := raw(`{"a":1,"b":[1],"a":2}`)
	for mode in ([?]json.Duplicates{.Default, .Last, .All}) {
		d, derr := json.find(dup, ".a", {strictness = .Lazy, duplicates = mode})
		want := "1" if mode == .All else "2"
		testing.expectf(t, derr == nil && d.outcome == .Found && string(dup[d.lo:d.hi]) == want, "%v: %v %v", mode, d, derr)
		_, ferr := json.find(raw(`{"a":1,"b":[01]}`), ".a", {strictness = .Lazy, duplicates = mode})
		f, faulted := ferr.?
		testing.expectf(t, faulted && f.kind == .Bad_Source && f.syntax == .Bad_Number, "%v: %v", mode, ferr)
	}
}

// `answer_text` reads a found scalar: a string decoded by the dialect's escapes, any other scalar as written. A
// container or a miss has no text.
@(test)
test_answer_text :: proc(t: ^testing.T) {
	Text_Case :: struct {
		src, path, want: string,
		dialect:         json.Dialect,
		escaped, ok:     bool,
	}
	cases := []Text_Case{
		{`{"a":"x\ty"}`, ".a", "x\ty", .Json, true, true},
		{`{"a":"plain"}`, ".a", "plain", .Json, false, true},
		{`{"a":-1.5e3}`, ".a", "-1.5e3", .Json, false, true},
		{`{"a":true}`, ".a", "true", .Json, false, true},
		{`{"a":[1]}`, ".a", "", .Json, false, false},
		{`{"a":1}`, ".b", "", .Json, false, false},
		{`{a:'it\'s'}`, ".a", "it's", .Json5, true, true},
		{`{a:'plain'}`, ".a", "plain", .Json5, false, true},
	}
	for c in cases {
		src := raw(c.src)
		a, err := json.find(src, c.path, {dialect = c.dialect})
		testing.expectf(t, err == nil, "%s: %v", c.src, err)
		text, escaped, ok := json.answer_text(src, a, {dialect = c.dialect}, context.temp_allocator)
		testing.expectf(t, text == c.want && escaped == c.escaped && ok == c.ok, "%s: %q %v %v", c.src, text, escaped, ok)
	}
}
