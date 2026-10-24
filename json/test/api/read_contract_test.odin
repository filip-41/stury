package json_tests

// Where a reading's result has to agree with the others': what Structural and Lazy check in a value they
// read, the unmarshal tag pre-scan, and the small entry points that share a rule with them.

import json "../.."
import "core:strings"
import "core:testing"

@(private = "file")
scan_verdict :: proc(t: ^testing.T, src: string, path: string, strictness: json.Strictness, duplicates := json.Duplicates.First, limits := json.Limits{}) -> (err: Maybe(json.Error), answers: int) {
	steps: [json.MAX_PATH_STEPS]json.Step
	names := make([]u8, len(path), context.temp_allocator)
	p, fault := json.parse_path(path, steps[:], names)
	testing.expect_value(t, fault, nil)
	r := paths_run(raw(src), {p}, strictness, duplicates, limits)
	defer json.destroy(&r.req)
	return r.err, len(r.answers)
}

// A negative index is answered by a re-read of the container's tail. A fault in it is the walk's result, never
// a miss, under every strictness.
@(test)
test_negative_index_reread_reports_its_fault :: proc(t: ^testing.T) {
	for strictness in ([]json.Strictness{.Strict, .Structural, .Lazy}) {
		got, n := scan_verdict(t, `[[0],[1 2]]`, ".[-1]", strictness)
		testing.expectf(t, got == Maybe(json.Error)(json.Error{kind = .Bad_Char, offset = 8}), "%v: %v", strictness, got)
		testing.expect_value(t, n, 0)
	}
}

// An empty key is addressable from path text: `."" ` and `.[""]` name the member whose key is empty.
@(test)
test_path_text_accepts_the_empty_key :: proc(t: ^testing.T) {
	for path in ([]string{`.""`, `.[""]`}) {
		got, n := scan_verdict(t, `{"":3,"a":1}`, path, .Strict)
		testing.expectf(t, got == nil && n == 1, "%s: %v %d", path, got, n)
	}
	steps: [json.MAX_PATH_STEPS]json.Step
	_, fault := json.parse_path(".a.", steps[:], make([]u8, 3, context.temp_allocator))
	testing.expect(t, fault != nil)
}

// `answers` on a path the request does not have is nothing, and `request_init` forgets the last scan's.
@(test)
test_request_answers_out_of_range_and_reinit :: proc(t: ^testing.T) {
	req: json.Request({.Path})
	defer json.destroy(&req)
	paths := []json.Path{{steps = []json.Step{json.Name("a")}}, {steps = []json.Step{json.Name("b")}}}
	req.paths = paths
	testing.expect_value(t, json.scan(raw(`{"a":1,"b":2}`), &req), nil)
	for i in ([]int{-1, 2, 7}) {
		out, err := json.answers(&req, i)
		testing.expectf(t, out == nil && err == nil, "path %d: %v %v", i, out, err)
	}
	out, err := json.answers(&req, 1)
	testing.expect(t, err == nil && len(out) == 1)
	testing.expect(t, json.request_init(&req) == nil)
	testing.expect_value(t, len(req.answers), 0)
	out, err = json.answers(&req, 0)
	testing.expect(t, err == nil && len(out) == 0)
}

@(private = "file")
Tagged_Shape :: union {
	Um_Circle,
	Um_Square,
}

// A tag value the walk checks first: a malformed one is the walk's syntax fault at its byte, and a well-formed
// number or an unknown name stays `Not_A_Member`.
@(test)
test_union_tag_is_judged_before_it_is_refused :: proc(t: ^testing.T) {
	mapping := json.Plan_Opts{union_tag = "type"}
	for strictness in ([]json.Strictness{.Strict, .Lazy}) {
		opts := json.Unmarshal_Opts{strictness = strictness}
		e := um_refused(t, `{"type":tru,"r":1}`, Tagged_Shape, .Syntax, 11, opts, mapping)
		testing.expect_value(t, e.syntax, json.Error_Kind.Bad_Literal)
		e = um_refused(t, `{"type":"Um_Circle\q","r":1}`, Tagged_Shape, .Syntax, 19, opts, mapping)
		testing.expect_value(t, e.syntax, json.Error_Kind.Bad_Escape)
		um_refused(t, `{"type":1,"r":1}`, Tagged_Shape, .Not_A_Member, 0, opts, mapping)
		um_refused(t, `{"type":"Nope","r":1}`, Tagged_Shape, .Not_A_Member, 0, opts, mapping)
		v: Tagged_Shape
		um_ok(t, `{"type":"Um_Circle","r":1}`, &v, opts, mapping)
	}
}

// A repeat in a member the type never reads is still a repeat under `.Duplicates.Refuse`, above the lazy
// shape walk's gate too.
@(test)
test_lazy_refuse_judges_a_duplicate_in_an_unread_member :: proc(t: ^testing.T) {
	Keep :: struct {
		keep: int,
	}
	junk := strings.repeat(`"k":1,`, 5000, context.temp_allocator)
	src := strings.concatenate({`{"junk":{"a":1,"a":2,`, junk, `"z":0},"keep":7}`}, context.temp_allocator)
	for strictness in ([]json.Strictness{.Strict, .Lazy}) {
		um_refused(t, src, Keep, .Duplicate_Key, 15, {strictness = strictness, duplicates = .Refuse})
	}
	v: Keep
	um_ok(t, src, &v, {strictness = .Lazy, duplicates = .First})
	testing.expect_value(t, v.keep, 7)
}
// A max_depth past MAX_DEPTH keeps the chosen strictness: Structural stays structural, Lazy stays lazy.
@(test)
test_deep_cap_keeps_the_strictness :: proc(t: ^testing.T) {
	deep := json.Limits{max_depth = json.MAX_DEPTH + 1}
	testing.expect_value(t, json.validate(raw(`[tru]`), {strictness = .Structural}), nil)
	testing.expect_value(t, json.validate(raw(`[tru]`), {strictness = .Structural, limits = deep}), nil)
	testing.expect_value(t, json.validate(raw(`[tru]`), {strictness = .Strict, limits = deep}), json.Error{kind = .Bad_Literal, offset = 4})
	for lim in ([]json.Limits{{}, deep}) {
		got, n := scan_verdict(t, `{"a":1,"b":tru}`, ".a", .Structural, limits = lim)
		testing.expectf(t, got == nil && n == 1, "structural %v: %v %d", lim.max_depth, got, n)
	}
	// Lazy past the cap has no early stop: it reads the whole item and checks it, which says so in its docs.
	got, n := scan_verdict(t, `{"a":1,"b":tru}`, ".a", .Lazy, limits = deep)
	testing.expectf(t, n == 1, "lazy deep answers %d", n)
	testing.expect_value(t, got, Maybe(json.Error)(json.Error{kind = .Bad_Literal, offset = 14}))
}

