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
	testing.expect_value(t, m.outcome, json.Path_Outcome.Missing)
	x, xerr := json.find(src, ".a.b")
	testing.expect_value(t, xerr, nil)
	testing.expect_value(t, x.outcome, json.Path_Outcome.Type_Mismatch)
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
	testing.expect_value(t, p.outcome, json.Path_Outcome.Missing)
}

@(test)
test_find_returns_the_scan_result_and_an_empty_answer :: proc(t: ^testing.T) {
	bad, err := json.find(raw(`{"a": 01}`), ".a")
	_, is_fault := err.(json.Error)
	testing.expectf(t, is_fault && bad.outcome == .Missing, "%v %v", err, bad)
	_, perr := json.find(raw(`{}`), ".a-b")
	r, refused := perr.(json.Request_Error)
	testing.expectf(t, refused && r.kind == .Bad_Path, "%v", perr)
	src := raw(`{"a":1,"b":[1,2,3]}`)
	a, lerr := json.find(src, ".a", strictness = .Lazy, duplicates = .First)
	testing.expect_value(t, lerr, nil)
	testing.expectf(t, a.outcome == .Found && string(src[a.lo:a.hi]) == "1", "%v", a)
}
