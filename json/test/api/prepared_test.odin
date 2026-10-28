package json_tests

// A request rescanned plans its routing at its second scan: its scans answer as a fresh request's do, record after
// record.

import json "../.."
import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
PREPARED_INPUTS := [?]string{
	`{"v":1}`,
	`{"v":1,"v":2}`,
	`{"a":{"b":1},"a":{"b":2},"v":3}`,
	`{"a":{"b":[1,2,3],"c":"x"},"v":"y"}`,
	`  {"a":{"b":{"c":{"d":1}}}} `,
	`[{"id":1},{"id":2,"id":3}]`,
	`{"a":[{"b":1},{"b":2}],"b":[0]}`,
	`[1,2]`,
	`"s"`,
	`{}`,
	``,
	`   `,
	`{"v":`,
	`{"v":1}x`,
	`{"x":[1,2,tru],"v":1}`,
	`{"v":"\ud800"}`,
	`{"v":1,}`,
	"// c\n{\"v\":1 /* d */}",
	`{"k3":1,"k19":2,"k3":3}`,
	`{"v":12345678901234567890123}`,
}

// Each scan of `src` through `req`, planned, against the scan of a fresh request of the same inputs.
@(private = "file")
expect_same_scan :: proc(t: ^testing.T, req: ^json.Request($Q), src: []byte, label: string) {
	fresh: json.Request(Q)
	defer json.destroy(&fresh)
	plain := &fresh
	_ = request_of(plain, req.inputs.paths, req.inputs.read)
	want_scan := json.scan(src, plain)
	want := fmt.tprint(want_scan)
	got := fmt.tprint(json.scan(src, req))
	testing.expectf(t, got == want, "%s %q: scan %s, want %s", label, src, got, want)
	// A refusal writes nothing: the outputs are the last scan's, which a fresh request has none of.
	if e, failed := want_scan.?; failed && e.kind != .Bad_Source {
		return
	}
	testing.expectf(t, req.state.coverage == plain.state.coverage && req.state.stop == plain.state.stop,
		"%s %q: coverage %v %v, want %v %v", label, src, req.state.coverage, req.state.stop, plain.state.coverage, plain.state.stop)
	testing.expectf(t, fmt.tprint(req.answers[:]) == fmt.tprint(plain.answers[:]), "%s %q: answers %v, want %v", label, src, req.answers[:], plain.answers[:])
	when .Nodes in Q {
		testing.expectf(t, fmt.tprint(req.doc.rows[:]) == fmt.tprint(plain.doc.rows[:]), "%s %q: rows differ", label, src)
	}
	for i in 0 ..< len(plain.inputs.paths) {
		got_i, got_err := json.answers(req, i)
		want_i, want_err := json.answers(plain, i)
		testing.expectf(t, fmt.tprint(got_i, got_err) == fmt.tprint(want_i, want_err), "%s %q: path %d answers %v, want %v", label, src, i, got_i, want_i)
	}
}

// Every input three times over through one request of `paths` under the options, against fresh requests.
@(private = "file")
expect_prepared_as_plain :: proc(
	t: ^testing.T,
	$Q: bit_set[json.Query],
	paths: []string,
	strictness: json.Strictness,
	dialect: json.Dialect,
	duplicates: json.Duplicates,
	limits: json.Limits,
	limit := 0,
) {
	specs := make([]json.Path_Spec, len(paths), context.temp_allocator)
	steps := make([]json.Step, json.MAX_PATH_STEPS * len(paths), context.temp_allocator)
	for s, i in paths {
		p, perr := json.parse_path(s, steps[i * json.MAX_PATH_STEPS:][:json.MAX_PATH_STEPS], transmute([]u8)strings.clone(s, context.temp_allocator))
		testing.expect_value(t, perr, nil)
		p.limit = limit
		specs[i] = p
	}
	req: json.Request(Q)
	defer json.destroy(&req)
	testing.expect_value(t, json.request_init(&req, ..specs, opts = {dialect = dialect, strictness = strictness, duplicates = duplicates, limits = limits}), nil)
	label := fmt.tprint(paths, strictness, dialect, duplicates, limits.max_depth, limit)
	for _ in 0 ..< 3 {
		for src in PREPARED_INPUTS {
			expect_same_scan(t, &req, raw(src), label)
		}
	}
}

@(test)
test_prepared_scans_answer_as_scan :: proc(t: ^testing.T) {
	// Past the plan's inline keys, and past the automaton's runs.
	names: [20]string
	runs: [17]string
	for &n, i in names {
		n = fmt.aprintf(".k%d", i)
	}
	for &r, i in runs {
		r = fmt.aprintf(".a[%d]", i)
	}
	defer {
		for n in names { delete(n) }
		for r in runs { delete(r) }
	}
	path_sets := [?][]string{
		{".v"},
		{".v", ".a", ".missing"},
		{".a.b"},
		{".a.b", ".a.c"},
		{".[].id"},
		{".a[].b"},
		{"."},
		{".a.b[-1]"},
		{".v", ".a.b"},
		{".v", ".[]"},
		names[:],
		runs[:],
	}
	limits := [?]json.Limits{{}, {max_depth = 3}, {max_depth = json.MAX_DEPTH + 8}, {max_scalar_digits = 8}}
	for paths in path_sets {
		for duplicates in json.Duplicates {
			for strictness in json.Strictness {
				for dialect in json.Dialect {
					for l in limits {
						expect_prepared_as_plain(t, {.Path}, paths, strictness, dialect, duplicates, l)
					}
				}
			}
			expect_prepared_as_plain(t, {.Path}, paths, .Strict, .Json, duplicates, {}, limit = 1)
			expect_prepared_as_plain(t, {.Path, .Dom}, paths, .Strict, .Json, duplicates, {})
			expect_prepared_as_plain(t, {.Path, .Nodes}, paths, .Strict, .Jsonc, duplicates, {})
		}
		free_all(context.temp_allocator)
	}
	// No paths: refused under `.Path`, a plain walk without.
	expect_prepared_as_plain(t, {.Path}, nil, .Strict, .Json, .Last, {})
	expect_prepared_as_plain(t, {}, nil, .Strict, .Json, .Last, {})
	expect_prepared_as_plain(t, {.Nodes}, nil, .Strict, .Json, .Refuse, {})
}
