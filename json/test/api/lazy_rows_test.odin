package json_tests

import json "../.."
import "core:testing"

// A `.Lazy` reading that builds rows settles nowhere before the walk ends: a name-first path on an array
// root still builds the document, and the text a stopping demand would never reach is judged.
@(test)
test_lazy_rows_built_under_name_first_path_on_array_root :: proc(t: ^testing.T) {
	steps := []json.Step{json.Name("a"), ANY, json.Name("b")}
	paths := []json.Path{{steps = steps}}
	good :: `[{"a":1},{"a":2}]`
	cases := [?]struct {
		src:  string,
		rows: int, // 0: the document faults
	}{{good, 5}, {good + " 7", 0}, {`[{"a":1},{"a":tru}]`, 0}}
	for c in cases {
		{
			req: json.Request({.Path, .Nodes})
			defer json.destroy(&req)
			_ = request_of(&req, paths, {strictness = .Lazy, duplicates = .First})
			err := json.scan(raw(c.src), &req)
			testing.expectf(t, (err == nil) == (c.rows > 0), "nodes %q: %v", c.src, err)
			testing.expectf(t, len(req.doc.rows) >= c.rows, "nodes %q: %d rows, want %d", c.src, len(req.doc.rows), c.rows)
		}
		req: json.Request({.Path, .Dom})
		defer json.destroy(&req)
		_ = request_of(&req, paths, {strictness = .Lazy, duplicates = .First})
		err := json.scan(raw(c.src), &req)
		testing.expectf(t, (err == nil) == (c.rows > 0), "dom %q: %v", c.src, err)
		testing.expectf(t, len(req.doc.rows) >= c.rows, "dom %q: %d rows, want %d", c.src, len(req.doc.rows), c.rows)
	}
}
