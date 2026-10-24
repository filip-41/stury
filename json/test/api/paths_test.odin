package json_tests

import json "../.."
import "core:fmt"
import "core:strings"
import "core:testing"

// `Any` in a path: jq's `.[]`.
ANY :: json.Any{}

// Query path resolution. Each test pins answers and the stop byte against a
// hand-computed offset.

// One path query against `src`, at `mode` and `level`. The returned answers are
// the caller's to free. A scan fault is reported so a test cannot read answers
// from a document the walk refused.
@(private)
expect_answers :: proc(
	t: ^testing.T,
	src: string,
	steps: []json.Step,
	mode: json.Duplicates,
	want: []json.Path_Answer,
	loc := #caller_location,
) {
	r := paths_run(raw(src), {{steps = steps}}, .Strict, mode)
	defer json.destroy(&r.req)
	testing.expectf(t, r.err == nil, "%s %v %v: %v", src, steps, mode, r.err, loc = loc)
	if len(r.answers) != len(want) {
		testing.expectf(t, false, "%s %v %v: %v, want %v", src, steps, mode, r.answers, want, loc = loc)
		return
	}
	for a, i in r.answers {
		w := want[i]
		// A found value names its own kind, and has no row without a tape.
		ok := a.outcome == w.outcome && a.query == w.query && a.lo == w.lo && a.hi == w.hi && a.node == json.NO_NODE
		ok &&= a.outcome != .Found || a.kind == span_kind(raw(src)[a.lo])
		ok &&= w.owner == 0 || a.owner == w.owner
		testing.expectf(t, ok, "%s %v %v: answer %d is %v, want %v", src, steps, mode, i, a, w, loc = loc)
	}
}

// The kind a value's first byte shows.
@(private)
span_kind :: proc(first: u8) -> json.Kind {
	switch first {
	case 'n': return .Null
	case 't': return .True
	case 'f': return .False
	case '"': return .String
	case '[': return .Array
	case '{': return .Object
	}
	return .Number
}

// Path answers against hand-computed offsets, under the resolutions each row names.
@(test)
test_path_answers :: proc(t: ^testing.T) {
	Case :: struct {
		src:   string,
		steps: []json.Step,
		modes: bit_set[json.Duplicates],
		want:  []json.Path_Answer,
	}
	EVERY :: bit_set[json.Duplicates]{.All, .First, .Last}
	hit :: proc(lo, hi: u64) -> json.Path_Answer {
		return {outcome = .Found, lo = lo, hi = hi}
	}
	MISS :: json.Path_Answer{outcome = .Missing}
	MISMATCH :: json.Path_Answer{outcome = .Type_Mismatch}
	a, b, x, y := json.Name("a"), json.Name("b"), json.Name("x"), json.Name("y")
	i0, i1, i2 := json.Index(0), json.Index(1), json.Index(2)
	m1, m2 := json.Index(-1), json.Index(-2)
	port_type := []json.Step{json.Name("port"), json.Name("type")}
	results_1 := []json.Step{json.Name("results"), i1}
	abz := []json.Step{a, b, json.Name("z")}
	cases := []Case{
		// The three readings. {"a":1,"a":2}: values at [5,6) and [11,12), `.All` answers every occurrence.
		{`{"a":1,"a":2}`, {a}, {.All}, {hit(5, 6), hit(11, 12)}},
		{`{"a":1,"a":2}`, {a}, {.First}, {hit(5, 6)}},
		{`{"a":1,"a":2}`, {a}, {.Last}, {hit(11, 12)}},
		{`{"a":1,"a":2}`, {json.Name("nope")}, {.All}, {MISS}},
		// `.All` reports a miss once the walk has ended: the document owes it, no container owns it.
		{`{}`, {a}, {.All}, {{outcome = .Missing, owner = max(u64)}}},
		{`  {"b":1}`, {a}, {.All}, {{outcome = .Missing, owner = max(u64)}}},
		// A later duplicate cannot change a first-wins answer.
		{`{"a":1,"a":2,"a":3}`, {a}, {.First}, {hit(5, 6)}},
		{`{"a":1,"a":2,"a":3}`, {a}, {.Last}, {hit(17, 18)}},
		// Resolution is final at every step, so `.First` and `.Last` answer different things and neither falls
		// back: the last port is `{}`, which has no `type`, and the first port is NOT tried.
		{`{"port":{"type":"a"},"port":{}}`, port_type, {.First, .All}, {hit(16, 19)}},
		{`{"port":{"type":"a"},"port":{}}`, port_type, {.Last}, {MISS}},
		// `.All` answers every occurrence of the FULL path.
		{`{"port":{"type":"a"},"port":{"type":"b"}}`, port_type, {.All}, {hit(16, 19), hit(36, 39)}},
		{`{"port":{"type":"a"},"port":{"type":"b"}}`, port_type, {.First}, {hit(16, 19)}},
		{`{"port":{"type":"a"},"port":{"type":"b"}}`, port_type, {.Last}, {hit(36, 39)}},
		// `.Last` answers exactly once: under the last `a`, `a.x` is absent, with no fall back to the first.
		{`{"a":{"x":1},"a":{"y":2}}`, {a, y}, {.Last, .All}, {hit(22, 23)}},
		{`{"a":{"x":1},"a":{"y":2}}`, {a, x}, {.Last}, {MISS}},
		// The miss is owned by the last `a`, the container that settled it.
		{`{"a":{"b":1},"a":{"c":2}}`, {a, b}, {.Last}, {{outcome = .Missing, owner = 17}}},
		// An escaped key decodes to the name, so it supersedes the plain one before it.
		{`{"a":1,"\u0061":2}`, {a}, {.Last}, {hit(16, 17)}},
		// Keys ending in an escaped backslash and an escaped quote, and strings full of structure bytes.
		{`{"a\\":"}],:\"","a\"":{"x":"{[\\"},"b":2}`, {json.Name(`a\`)}, {.Last}, {hit(7, 15)}},
		// A negative index waits out the repeats of the name before it, though its array closed first.
		{`{"b":[1,2],"b":[3]}`, {b, m1}, {.Last}, {hit(16, 17)}},
		{`{"a":{"x":1},"a":{"y":2}}`, {a, x}, {.First, .All}, {hit(10, 11)}},
		// Three levels deep, so the `.Last` slot is overwritten at two different levels.
		{`{"a":{"b":{"z":1},"b":{"z":2}},"a":{"b":{"z":3}}}`, abz, {.Last}, {hit(45, 46)}},
		{`{"a":{"b":{"z":1},"b":{"z":2}},"a":{"b":{"z":3}}}`, abz, {.First}, {hit(15, 16)}},
		{`{"a":{"b":{"z":1},"b":{"z":2}},"a":{"b":{"z":3}}}`, abz, {.All}, {hit(15, 16), hit(27, 28), hit(45, 46)}},
		// Last-wins includes a step that met the wrong kind: the second `results` is an OBJECT, so `results[1]`
		// against it mismatches, and that is the query's one answer, not the first occurrence's `20`.
		{`{"results":[10,20,30],"results":{"results":[1]}}`, results_1, {.First}, {hit(15, 17)}},
		{`{"results":[10,20,30],"results":{"results":[1]}}`, results_1, {.Last}, {MISMATCH}},
		{`{"results":[10,20,30],"results":{"results":[1]}}`, results_1, {.All}, {hit(15, 17), MISMATCH}},
		{`{"results":[10,20,30],"results":{"results":[1]}}`, {json.Name("results"), json.Name("results")}, {.Last}, {hit(43, 46)}},
		// An empty path is the node itself.
		{`{"a":1}`, {}, {.All}, {hit(0, 7)}},
		{`  42  `, {}, {.All}, {hit(2, 4)}},
		// [10,20,30]: elements at [1,3), [4,6), [7,9). Index is signed, and an out-of-range index is a miss,
		// never a clamp.
		{`[10,20,30]`, {i0}, {.First}, {hit(1, 3)}},
		{`[10,20,30]`, {i2}, {.First}, {hit(7, 9)}},
		{`[10,20,30]`, {json.Index(3)}, {.First}, {MISS}},
		{`[10,20,30]`, {m1}, {.First}, {hit(7, 9)}},
		{`[10,20,30]`, {json.Index(-3)}, {.First}, {hit(1, 3)}},
		{`[10,20,30]`, {json.Index(-4)}, {.First}, {MISS}},
		// A positional step after a name step.
		{`{"a":[1,2]}`, {a, i1}, {.First}, {hit(8, 9)}},
		{`{"a":[1,2]}`, {a, m2}, {.First}, {hit(6, 7)}},
		// A step applied to the wrong container kind is an answered miss, settled at the container, so `.All`
		// answers it too, a later step against a bound scalar or array is the wrong kind, not a miss.
		{`[1,2]`, {a}, {.First, .All}, {MISMATCH}},
		{`{"a":1}`, {i0}, {.First}, {MISMATCH}},
		{`7`, {a}, {.First, .All}, {MISMATCH}},
		{`{"a":1}`, {a, b}, {.First}, {MISMATCH}},
		{`{"a":[1]}`, {a, b}, {.First}, {MISMATCH}},
		// `Name` compares by decoded text, so an escaped form matches: {"a\u0062":1} holds `ab` at [11,12).
		{`{"a\u0062":1}`, {json.Name("ab")}, {.First}, {hit(11, 12)}},
		{`{"a\u0062":1}`, {json.Name("abc")}, {.First}, {MISS}},
		{`{"ab":2}`, {json.Name("ab")}, {.First}, {hit(6, 7)}},
		// An empty container is a value like any other: the answer is its own extent. An empty root misses.
		{`{"a":{}}`, {a}, {.First}, {hit(5, 7)}},
		{`{"a":[]}`, {a}, {.All}, {hit(5, 7)}},
		{`{}`, {a}, {.First}, {MISS}},
		{`[[]]`, {i0}, {.First}, {hit(1, 3)}},
		// An `Index` step is defined against the container it lands IN, and the walk counts each container's own
		// members (`Auto_Level.idx`), bumped at every value's start, fusion loop included. A per-scan
		// count would resolve an `Index` through another array against the root's count, and a count that skips the
		// fused `[` bracket would miss the root's first element on `[[..],[..]]`.
		//
		// Byte offsets in `[[1,2,3],[4,5,6]]`:
		//   0 '['   1 '['   2 '1'   3 ','   4 '2'   5 ','   6 '3'   7 ']'
		//   8 ','   9 '['  10 '4'  11 ','  12 '5'  13 ','  14 '6'  15 ']'  16 ']'
		{`[1,2,3]`, {i1}, {.First}, {hit(3, 4)}},
		{`[[1,2,3],[4,5,6]]`, {i0, i1}, {.First}, {hit(4, 5)}},
		{`[[1,2,3],[4,5,6]]`, {i0, m1}, {.First}, {hit(6, 7)}},
		{`[[1,2,3],[4,5,6]]`, {i1, i2}, {.First}, {hit(14, 15)}},
		{`[[1,2,3],[4,5,6]]`, {i0, json.Index(3)}, {.First}, {MISS}},
		{`[[1,2,3],[4,5,6]]`, {i2, i0}, {.First}, {MISS}},
		// A SPACE takes the descend loop instead of the fusion loop: the count is the count, not the route.
		{`[[1, 2, 3], [4, 5, 6]]`, {i0, i2}, {.First}, {hit(8, 9)}},
		// An array whose first element immediately opens another array: the fusion loop pushes BOTH, and the
		// inner one's element 0 is `[10]` at [2,6), its own element 0 is the `10`.
		{`[[[10]],[20]]`, {i0, i0}, {.First}, {hit(2, 6)}},
		{`[[[10]],[20]]`, {i0, i0, i0}, {.First}, {hit(3, 5)}},
		{`[[[10]],[20]]`, {i1, i0}, {.First}, {hit(9, 11)}},
		{`[[[10]],[20]]`, {i0, a}, {.First}, {MISMATCH}},
		// Object-nested indexing binds by name and never touched the positional counter: the ordinal differs.
		{`[{"a":[10,20]},{"a":[30]}]`, {i1, a, i0}, {.First}, {hit(21, 23)}},
		{`[{"a":[10,20]},{"a":[30]}]`, {i0, a, i0}, {.First}, {hit(7, 9)}},
		// Both mechanisms: an element that is a number, then an array of arrays, then a number. `[1]` is the
		// inner `[[7],8]` and `[1][0]` is the `[7]` at [4,7), not the `8` beside it.
		{`[0,[[7],8],9]`, {i1}, {.First}, {hit(3, 10)}},
		{`[0,[[7],8],9]`, {i1, i0}, {.First}, {hit(4, 7)}},
		{`[0,[[7],8],9]`, {i1, i1}, {.First}, {hit(8, 9)}},
		{`[0,[[7],8],9]`, {m2, i0}, {.First}, {hit(4, 7)}},
		{`[0,[[7],8],9]`, {i0, i0}, {.First}, {MISMATCH}},
		// A WIDE root array of one-element arrays: every element is a fused `[`, so every ordinal is counted by
		// the fusion loop. Out of range past either end is a miss, against the ROOT's length.
		{`[[1],[2],[3],[4],[5]]`, {i0}, {.First}, {hit(1, 4)}},
		{`[[1],[2],[3],[4],[5]]`, {i1}, {.First}, {hit(5, 8)}},
		{`[[1],[2],[3],[4],[5]]`, {json.Index(3)}, {.First}, {hit(13, 16)}},
		{`[[1],[2],[3],[4],[5]]`, {m1}, {.First, .Last}, {hit(17, 20)}},
		{`[[1],[2],[3],[4],[5]]`, {json.Index(-5)}, {.First}, {hit(1, 4)}},
		{`[[1],[2],[3],[4],[5]]`, {json.Index(5)}, {.First, .All}, {MISS}},
		{`[[1],[2],[3],[4],[5]]`, {json.Index(-6)}, {.First}, {MISS}},
		{`[[1],[2],[3],[4],[5]]`, {i2, i0}, {.First}, {hit(10, 11)}},
		{`{"a":[{"b":1}]}`, {a, i0, b}, {.First}, {hit(11, 12)}},
		// A chain of negative `Index` steps. A negative position depends on its container's length, so it
		// resolves on that container's close via one bounded re-read (`path_reenter_from_end`), two negative
		// steps re-enter twice, each counting its OWN container. The re-read must not carry the
		// already-resolved position (`Path_Run.head_pos`) down, or every negative step below it answers `Missing`.
		{`[[1,2,3],[4,5,6]]`, {m1, m1}, EVERY, {hit(14, 15)}},
		{`[[1,2,3],[4,5,6]]`, {m2, m1}, EVERY, {hit(6, 7)}},
		// Controls: a non-negative step under a negative one, and a negative one out of range.
		{`[[1,2,3],[4,5,6]]`, {m1, i0}, EVERY, {hit(10, 11)}},
		{`[[1,2,3],[4,5,6]]`, {json.Index(-3)}, EVERY, {MISS}},
		// A miss one level down is decided by THAT array's length: `[-2]` names past the one-member `[3]`.
		{`[[1,2],[3]]`, {m1, m2}, EVERY, {MISS}},
		{`[[1,2],[3]]`, {m1, m1}, EVERY, {hit(8, 9)}},
		// Three negative steps nest the re-read twice.
		{`[[[1,2],[3,4]],[[5,6]]]`, {m1, m1, m1}, EVERY, {hit(19, 20)}},
		{`[[[1,2],[3,4]],[[5,6]]]`, {m1, m1, m2}, EVERY, {hit(17, 18)}},
		// A third step onto a SCALAR is the wrong kind. Under `.All` the mismatch does not discharge the query,
		// which still owes its one miss (`finish_paths`).
		{`[[1,2,3],[4,5,6]]`, {m1, m1, m1}, {.First, .Last}, {MISMATCH}},
		{`[[1,2,3],[4,5,6]]`, {m1, m1, m1}, {.All}, {MISMATCH, MISS}},
		// A NAME above or between the negative steps, the second negative step still re-reads.
		{`{"a":[[1,2],[3,4]],"z":9}`, {a, m1, m1}, EVERY, {hit(15, 16)}},
		{`{"a":[[1,2],[3,4]],"z":9}`, {a, i0, m1}, EVERY, {hit(9, 10)}},
		{`[{"a":[10,20]},{"a":[30]}]`, {m1, a, m1}, EVERY, {hit(21, 23)}},
		{`{"a":[{"b":[1,2]},{"b":[3,4]}]}`, {a, m1, b, m1}, EVERY, {hit(26, 27)}},
		// A negative last step over a FUSED bracket.
		{`[0,[[7],8],9]`, {m2, i0, m1}, EVERY, {hit(5, 6)}},
	}
	for c in cases {
		for mode in c.modes {
			expect_answers(t, c.src, c.steps, mode, c.want)
		}
	}
	// A limit counts `Found` answers: the first `a`'s mismatch does not use it up.
	r := paths_run(raw(`{"a":1,"a":{"b":2}}`), {{steps = {a, b}, limit = 1}}, .Strict, .All)
	defer json.destroy(&r.req)
	testing.expect_value(t, len(r.answers), 2)
	testing.expect_value(t, r.answers[len(r.answers) - 1].lo, 16)
}

// The ways a path is read that a negative index must agree with its forward twin under.
@(private)
Reading :: struct {
	strictness: json.Strictness,
	mode:       json.Duplicates,
}

@(private)
READINGS := [?]Reading{{.Lazy, .First}, {.Strict, .First}, {.Strict, .Last}, {.Strict, .All}, {.Structural, .First}}

// A negative `Index` is answered by a re-read at its array's close, but its answer is read all the same, so
// it is checked as the forward index naming the same member checks it: `.[k]` and `.[k-len]` give the same
// result and the same answer. Under `.Lazy` the owning walk skipped the member, and a re-read that drops
// its faults would answer `tru` with no error.
@(test)
test_path_negative_index_judges_its_answer :: proc(t: ^testing.T) {
	Case :: struct {
		src:    string,
		n:      int, // the root array's length
		limits: json.Limits,
		bad:    int, // the member malformed under `limits`
	}
	cases := []Case {
		{src = `[1,2,tru]`, n = 3, bad = 2},
		{src = "[1,\"a\x01\"]", n = 2, bad = 1},
		{src = `[1,123456789012345678901234567890]`, n = 2, limits = {max_scalar_digits = 5}, bad = 1},
		{src = `[0,{"a":[1,nul]},2]`, n = 3, bad = 1},
		{src = `[{"a":tru},1,2]`, n = 3, bad = 0},
		// Under a raised cap, the deep walk.
		{src = `[1,2,tru]`, n = 3, limits = {max_depth = 2 * json.MAX_DEPTH}, bad = 2},
	}
	for c in cases {
		for rd in READINGS {
			for k in 0 ..< c.n {
				err := expect_twins(t, c.src, {{steps = {json.Index(k)}}}, {{steps = {json.Index(k - c.n)}}}, rd.strictness, rd.mode, c.limits)
				if k == c.bad && rd.strictness != .Structural {
					testing.expectf(t, scan_fault(err) != nil, "%q .[%d] %v: the answer is malformed", c.src, k, rd)
				}
			}
		}
	}

	// Several runs re-read in one sub-walk: each answer is checked.
	for src in ([]string{`[tru,2,3]`, `[1,2,tru]`}) {
		err := expect_twins(t, src, {{steps = {json.Index(2)}}, {steps = {json.Index(0)}}}, {{steps = {json.Index(-1)}}, {steps = {json.Index(-3)}}}, .Lazy, .First)
		testing.expectf(t, scan_fault(err) != nil, "%q: one answer is malformed", src)
	}

	// Under a wildcard no run settles early, so the walk cannot stop at the re-read's fault: it runs on, and
	// the fault is its result at the end.
	werr := expect_twins(t, `[[1,tru],[2,3]]`, {{steps = {ANY, json.Index(1)}}}, {{steps = {ANY, json.Index(-1)}}}, .Lazy, .First)
	testing.expectf(t, scan_fault(werr) != nil, "%v", werr)

	// Below a `Name`, and a chain of two negative steps: each re-read checks the answer it returns.
	a := json.Name("a")
	cerr := expect_twins(t, `{"a":[1,[2,tru]]}`, {{steps = {a, json.Index(1), json.Index(1)}}}, {{steps = {a, json.Index(-1), json.Index(-1)}}}, .Lazy, .First)
	testing.expectf(t, scan_fault(cerr) != nil, "%v", cerr)
}

// A negative `Index` deeper than the member-start ring holds resumes from a recorded start, or the `[`, and
// passes the members before its answer unread, its re-read stops once that member has closed. Each request
// answers as its forward twin does, path by path, with the same result, over a well-formed array and one
// with a malformed member before the answers: under `.Lazy` that member is skipped unchecked by both, and under
// `.Strict` it is both walks' fault.
@(test)
test_path_negative_index_far_from_the_end :: proc(t: ^testing.T) {
	for bad in ([]int{-1, 5}) {
		far_from_the_end(t, bad)
	}
}

@(private)
far_from_the_end :: proc(t: ^testing.T, BAD: int) {
	N :: 40
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for i in 0 ..< N {
		if i > 0 {
			strings.write_string(&b, ", " if i % 3 == 0 else ",")
		}
		switch {
		case i == BAD:   strings.write_string(&b, "tru")
		case i % 4 == 0: fmt.sbprintf(&b, "%d", i)
		case i % 4 == 1: fmt.sbprintf(&b, `{{"x":%d,"x":[%d]}}`, i, i)
		case i % 4 == 2: fmt.sbprintf(&b, "[%d,[%d]]", i, i)
		case:            strings.write_string(&b, `"s"`)
		}
	}
	strings.write_byte(&b, ']')
	arr := strings.to_string(b)
	docs := []string{arr, fmt.tprintf(`{{"a":%s,"z":1}}`, arr), fmt.tprintf("[%s,%s]", arr, arr)}
	a := json.Name("a")
	x := json.Name("x")
	for rd in READINGS {
		for k in 0 ..= N {
			// `k == N` pairs the two misses past either end.
			neg := json.Index(k - N) if k < N else json.Index(-N - 1)
			fwd := json.Index(k)
			// Alone, with a name or an index read inside the answer, and under a name, an index or a wildcard.
			expect_twins(t, docs[0], {{steps = {fwd}}}, {{steps = {neg}}}, rd.strictness, rd.mode)
			expect_twins(t, docs[0], {{steps = {fwd, x}}}, {{steps = {neg, x}}}, rd.strictness, rd.mode)
			expect_twins(t, docs[0], {{steps = {fwd, json.Index(1)}}}, {{steps = {neg, json.Index(-1)}}}, rd.strictness, rd.mode)
			expect_twins(t, docs[1], {{steps = {a, fwd, x}}}, {{steps = {a, neg, x}}}, rd.strictness, rd.mode)
			expect_twins(t, docs[2], {{steps = {json.Index(1), fwd}}}, {{steps = {json.Index(-1), neg}}}, rd.strictness, rd.mode)
			expect_twins(t, docs[2], {{steps = {ANY, fwd}}}, {{steps = {ANY, neg}}}, rd.strictness, rd.mode)
		}
		// Several runs in one request, negative and forward, the negative ones re-read in one sub-walk.
		expect_twins(
			t,
			docs[0],
			{{steps = {json.Index(N - 1)}}, {steps = {json.Index(3)}}, {steps = {json.Index(N - 30)}}, {steps = {json.Index(0)}}, {steps = {json.Index(N)}}, {steps = {json.Index(N - 9), x}}},
			{{steps = {json.Index(-1)}}, {steps = {json.Index(3)}}, {steps = {json.Index(-30)}}, {steps = {json.Index(-N)}}, {steps = {json.Index(-N - 1)}}, {steps = {json.Index(-9), x}}},
			rd.strictness,
			rd.mode,
		)
	}
}

// `fwd` and `neg` ask the same questions of `src`: the same result and, path by path, the same answers.
// The result is returned.
@(private)
expect_twins :: proc(
	t: ^testing.T,
	src: string,
	fwd, neg: []json.Path,
	strictness: json.Strictness,
	mode: json.Duplicates,
	limits := json.Limits{},
	loc := #caller_location,
) -> json.Scan_Error {
	f := paths_run(raw(src), fwd, strictness, mode, limits)
	n := paths_run(raw(src), neg, strictness, mode, limits)
	defer json.destroy(&f.req)
	defer json.destroy(&n.req)
	testing.expectf(t, f.err == n.err, "%v %v %v: %v, %v", neg[0].steps, strictness, mode, f.err, n.err, loc = loc)
	if f.err != nil || n.err != nil {
		return f.err
	}
	for i in 0 ..< len(fwd) {
		fa, _ := json.answers(&f.req, i)
		na, _ := json.answers(&n.req, i)
		same := len(fa) == len(na)
		for w, j in fa {
			if !same {
				break
			}
			g := na[j]
			same = w.outcome == g.outcome && w.lo == g.lo && w.hi == g.hi && w.kind == g.kind && w.owner == g.owner
		}
		testing.expectf(t, same, "%v %v %v: %v, %v", neg[i].steps, strictness, mode, fa, na, loc = loc)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

// An empty path's answer is the whole root, so under `.Lazy` it is checked whole, as under `.Strict`, and alone
// or beside another path.
@(test)
test_path_empty_judges_the_root :: proc(t: ^testing.T) {
	for src in ([]string{`[1,"\udc00"]`, `{"a":[1,tru]}`, `[1,2,nul]`}) {
		want := json.validate(raw(src))
		testing.expectf(t, want != nil, "%q is malformed", src)
		for other in ([]json.Path{{}, {steps = {json.Index(0)}}}) {
			r := paths_run(raw(src), {{}, other}, .Lazy, .First)
			defer json.destroy(&r.req)
			testing.expectf(t, scan_fault(r.err) == want, "%q .Lazy: %v, validate %v", src, r.err, want)
		}
	}
}

// A path past `MAX_PATH_STEPS` is refused by every entry point that takes one, text or built, whichever
// engine would serve it: `query` as `Out_Of_Room`, the scan and the edits as `Over_Capacity` (their structs
// have no `Out_Of_Room`). The bound itself still answers. A name chain goes to the automaton, a column
// (`[]` then a name) would go to the row matcher, which has no bound of its own.
// `n` steps of `.a` (all but the last `.[]` when `column`), as path text, as steps, and a document they reach,
// whose innermost value is `leaf`.
@(private)
step_chain :: proc(n: int, leaf: string, column := false) -> (text, doc: string, steps: []json.Step) {
	t, d: strings.Builder
	strings.builder_init(&t, context.temp_allocator)
	strings.builder_init(&d, context.temp_allocator)
	steps = make([]json.Step, n, context.temp_allocator)
	for i in 0 ..< n {
		as_any := column && i < n - 1
		strings.write_string(&t, ".[]" if as_any else ".a")
		strings.write_string(&d, "[" if as_any else `{"a":`)
		steps[i] = ANY if as_any else json.Name("a")
	}
	strings.write_string(&d, leaf)
	for i := n - 1; i >= 0; i -= 1 {
		strings.write_string(&d, "]" if column && i < n - 1 else "}")
	}
	return strings.to_string(t), strings.to_string(d), steps
}

@(test)
test_path_step_bound_is_one_refusal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for column in ([]bool{false, true}) {
		for n in ([]int{json.MAX_PATH_STEPS, json.MAX_PATH_STEPS + 1}) {
			over := n > json.MAX_PATH_STEPS
			text, doc, steps := step_chain(n, "1", column)
			src := raw(doc)
			for spec in ([]json.Path_Spec{text, json.Path{steps = steps}}) {
				label := fmt.tprintf("column=%v n=%d %v", column, n, spec)

				d := build_ok(t, doc)
				found: [dynamic]json.Node
				defer delete(found)
				qerr := json.query(&d, json.ROOT, spec, &found)
				json.destroy(&d)
				if over {
					fault, _ := qerr.?
					testing.expectf(t, fault.error == .Out_Of_Room, "%s: query %v", label, qerr)
					testing.expectf(t, len(found) == 0, "%s: query appended %d", label, len(found))
				} else {
					testing.expectf(t, qerr == nil && len(found) == 1, "%s: query %v, %d found", label, qerr, len(found))
				}

				req: json.Request({.Path})
				defer json.destroy(&req)
				testing.expectf(t, json.request_init(&req, spec) == nil, "%s: request_init", label)
				serr := json.scan(src, &req)
				if over {
					refusal, _ := serr.(json.Request_Error)
					testing.expectf(t, refusal.kind == .Over_Capacity && refusal.capacity == .Path_Steps, "%s: scan %v", label, serr)
				} else {
					testing.expectf(t, serr == nil && len(req.answers) == 1, "%s: scan %v", label, serr)
				}

				_, set_err := json.set(src, spec, 2, context.temp_allocator)
				_, remove_err := json.remove(src, spec, context.temp_allocator)
				for edit_result, op in ([]Maybe(json.Path_Error){set_err, remove_err}) {
					if over {
						edit_err(t, edit_result, .Over_Capacity)
					} else {
						testing.expectf(t, edit_result == nil, "%s: edit %d %v", label, op, edit_result)
					}
				}
			}
		}
	}

	// `insert` names a container and adds one step for the member, so its last working container is one
	// step short of the bound.
	for n in ([]int{json.MAX_PATH_STEPS - 1, json.MAX_PATH_STEPS + 1}) {
		text, doc, steps := step_chain(n, "{}")
		for spec in ([]json.Path_Spec{text, json.Path{steps = steps}}) {
			_, err := json.insert(raw(doc), spec, "x", 2, context.temp_allocator)
			if n > json.MAX_PATH_STEPS {
				edit_err(t, err, .Over_Capacity)
			} else {
				testing.expectf(t, err == nil, "insert at %d steps: %v", n, err)
			}
		}
	}
}

// The runs and each path's steps bound the automaton's state, so a request past either bound is refused
// before the walk as `Over_Capacity` naming the bound, with nothing appended, never truncated (a truncated
// request would answer a question the caller did not ask). Each document is wide or deep enough that the
// refused request would otherwise be answered, so what refuses is the cap and not the walk.
@(test)
test_path_capacity :: proc(t: ^testing.T) {
	// {"k00":0,...,"k16":0} and one name path per key.
	keys: [17][3]byte
	object: [dynamic]byte
	defer delete(object)
	named: [17]json.Path
	steps: [17]json.Step
	append(&object, "{")
	for i in 0 ..< 17 {
		keys[i] = {'k', byte('0' + i / 10), byte('0' + i % 10)}
		if i > 0 {
			append(&object, ",")
		}
		append(&object, `"`)
		append(&object, string(keys[i][:]))
		append(&object, `":0`)
		steps[i] = json.Name(string(keys[i][:]))
		named[i] = {steps = steps[i:i + 1]}
	}
	append(&object, "}")
	// 33 nested arrays around a `0`: 32 steps land on the innermost array, 33 on the `0`.
	deep: [dynamic]byte
	defer delete(deep)
	for _ in 0 ..< 33 {
		append(&deep, "[")
	}
	append(&deep, "0")
	for _ in 0 ..< 33 {
		append(&deep, "]")
	}
	indexes, anys: [33]json.Step
	for i in 0 ..< 33 {
		indexes[i], anys[i] = json.Index(0), ANY
	}
	wild_pairs: [17]json.Path
	for &p in wild_pairs {
		p = {steps = {ANY, ANY}}
	}
	Case :: struct {
		src:     []byte,
		paths:   []json.Path,
		refused: Maybe(json.Capacity),
	}
	cases := []Case{
		{object[:], named[:16], nil},
		// Over a root object the matcher would serve them all, so the automaton's cap is pinned over an array.
		{raw(`[0]`), named[:], .Path_Runs},
		{raw(`[[1]]`), wild_pairs[:16], nil},
		{raw(`[[1]]`), wild_pairs[:], .Path_Runs},
		{deep[:], {{steps = indexes[:32]}}, nil},
		{deep[:], {{steps = indexes[:]}}, .Path_Steps},
		{deep[:], {{steps = anys[:32]}}, nil},
		{deep[:], {{steps = anys[:]}}, .Path_Steps},
	}
	for c, i in cases {
		r := paths_run(c.src, c.paths, duplicates = .All)
		defer json.destroy(&r.req)
		if bound, refused := c.refused.?; refused {
			refusal, _ := r.err.(json.Request_Error)
			testing.expectf(t, refusal.kind == .Over_Capacity && refusal.capacity == bound,
				"row %d: %v, want Over_Capacity{%v}", i, r.err, bound)
			testing.expect_value(t, refusal.query_kind, Maybe(json.Query)(.Path))
			// The culprit: the one long path, or the first path past the run bound.
			testing.expect_value(t, refusal.path, len(c.paths) - 1)
			testing.expect_value(t, len(r.answers), 0)
			continue
		}
		testing.expectf(t, r.err == nil, "row %d: %v", i, r.err)
		testing.expectf(t, len(r.answers) == len(c.paths), "row %d: %d answers, want %d", i, len(r.answers), len(c.paths))
		for a in r.answers {
			testing.expectf(t, a.outcome == .Found, "row %d: %v", i, a)
		}
	}
}
