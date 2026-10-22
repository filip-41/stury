package json_tests

import json "../.."
import "core:slice"
import "core:testing"

// The build define that sends every path to the automaton: the tape route is then off too.
TAPE_FORCE_AUTOMATON :: #config(FORCE_AUTOMATON, false)

// Two or more gated columns under `.Strict` are answered from the built rows (the tape route), a
// `max_depth` past `MAX_DEPTH` sends the same request to the scan route. The two give the same result,
// answers, order and coverage, on every document and resolution, malformed or not.
@(test)
test_tape_route_agrees_with_scan_route :: proc(t: ^testing.T) {
	logs_status := []json.Step{json.Name("logs"), ANY, json.Name("status")}
	logs_id := []json.Step{json.Name("logs"), ANY, json.Name("id")}
	deep_c := []json.Step{json.Name("a"), json.Name("b"), ANY, json.Name("c")}
	deep_d := []json.Step{json.Name("a"), json.Name("b"), ANY, json.Name("d")}
	two_any_x := []json.Step{json.Name("a"), ANY, ANY, json.Name("x")}
	two_any_y := []json.Step{json.Name("a"), ANY, ANY, json.Name("y")}
	sets := [][]json.Path{
		{{steps = logs_status}, {steps = logs_id}},
		{{steps = logs_id}, {steps = logs_status}, {steps = logs_id}},
		{{steps = logs_id, limit = 1}, {steps = logs_status}},
		{{steps = deep_c}, {steps = deep_d}},
		{{steps = two_any_x}, {steps = two_any_y}},
	}
	docs := []string{
		`{"logs":[{"id":1,"status":200},{"id":2,"status":404}]}`,
		`{"logs":[{"id":1,"id":2,"status":3,"status":4,"id":5}]}`,
		`{"logs":[{"id":1}],"logs":[{"id":2,"status":5}]}`,
		`{"logs":[{"id":1,"status":2}],"logs":3}`,
		`{"logs":3,"logs":[{"id":1,"status":2}],"x":0}`,
		`{"logs":[{"id":1},{"status":2},{}]}`,
		`{"logs":[1,"x",null,[{"id":9}],{"id":2,"status":1}]}`,
		`{"logs":[]}`, `{"logs":{}}`, `{}`, `[]`, `3`, `{"logs":3}`, `{"logs":null}`,
		`{"logs":{"a":{"id":1,"status":2},"b":{"id":3}}}`,
		`{"logs":[{"id":{"a":[1]},"status":[2,3],"id":"s"}]}`,
		`{"logs":[{"id":1,"status":2}]}`, `{"logs":[{"id":1}]}`, `{"logs":[{"id":1,"status":2}]}`,
		" \n{\"logs\" : [ {\"id\" : 1 , \"status\":2} ] } \n", "\xEF\xBB\xBF{\"logs\":[{\"id\":1,\"status\":2}]}",
		`{"a":{"b":[{"c":1,"d":2},{"c":3},5],"b":[{"d":4}]},"b":{"b":[{"c":9}]}}`,
		`{"a":{"b":[{"c":1,"d":2}]},"a":{"b":[{"c":3}]}}`,
		`{"a":[[{"x":1,"y":2},{"y":3}],{"x":4},[]],"a":[{"x":5,"x":6}]}`,
		`{"a":{"p":{"x":1},"q":[{"x":2,"y":3}]}}`,
		// Malformed before, inside and after the answers.
		`{"x":@,"logs":[{"id":1,"status":2}]}`, `{"logs":[{"id":1,"status":2},{"id":}]}`,
		`{"logs":[{"id":1,"status":2}]} x`, `{"logs":[{"id":1,"status":2}]`, `{"logs":[{"id":1,"status":2}],}`,
		`{"logs":[{"id":01,"status":2}]}`, ``, ` `, `{"logs":[{"id":1,"status":2}]}{}`,
	}
	for set, si in sets {
		for src, di in docs {
			for mode in ([?]json.Duplicates{.First, .Last, .All}) {
				tape := paths_run(raw(src), set, .Strict, mode)
				scan := paths_run(raw(src), set, .Strict, mode, json.Limits{max_depth = json.MAX_DEPTH + 1})
				defer json.destroy(&tape.req)
				defer json.destroy(&scan.req)
				testing.expectf(t, tape.err == scan.err, "set %d doc %d %v: %v, scan %v", si, di, mode, tape.err, scan.err)
				testing.expectf(t, slice.equal(tape.answers, scan.answers), "set %d doc %q %v: %v, scan %v", si, src, mode, tape.answers, scan.answers)
				testing.expectf(t, tape.req.coverage == scan.req.coverage && tape.req.stop == scan.req.stop,
					"set %d doc %d %v: coverage %v/%v, scan %v/%v", si, di, mode, tape.req.coverage, tape.req.stop,
					scan.req.coverage, scan.req.stop)
				for i in 0 ..< len(set) {
					a, a_err := json.answers(&tape.req, i)
					b, b_err := json.answers(&scan.req, i)
					testing.expectf(t, a_err == b_err && slice.equal(a, b), "set %d doc %d %v: path %d grouped %v, scan %v", si, di, mode, i, a, b)
				}
			}
		}
	}
}

// The route fires only for what it wins. The built rows are its sign. One gated column, a `.Lazy` request,
// or paths that are not all gated columns scan.
@(test)
test_tape_route_is_gated :: proc(t: ^testing.T) {
	src := raw(`{"logs":[{"id":1,"status":2}],"n":1}`)
	two := []json.Path{
		{steps = []json.Step{json.Name("logs"), ANY, json.Name("id")}},
		{steps = []json.Step{json.Name("logs"), ANY, json.Name("status")}},
	}
	mixed := []json.Path{two[0], two[1], {steps = []json.Step{json.Name("n")}}}
	Case :: struct {
		paths:      []json.Path,
		strictness: json.Strictness,
		dups:       json.Duplicates,
		routed:     bool,
	}
	cases := []Case{
		{two, .Strict, .Last, !TAPE_FORCE_AUTOMATON},
		{two, .Strict, .First, !TAPE_FORCE_AUTOMATON},
		{two, .Strict, .All, !TAPE_FORCE_AUTOMATON},
		{two[:1], .Strict, .Last, false},
		{two, .Lazy, .First, false},
		{two, .Structural, .Last, false},
		{mixed, .Strict, .Last, false},
		{two, .Strict, .Refuse, false},
	}
	for c, i in cases {
		r := paths_run(src, c.paths, c.strictness, c.dups)
		defer json.destroy(&r.req)
		testing.expectf(t, r.err == nil, "row %d: %v", i, r.err)
		testing.expectf(t, (len(r.req.doc.rows) > 0) == c.routed, "row %d: routed %v, want %v", i, len(r.req.doc.rows) > 0, c.routed)
	}
}
