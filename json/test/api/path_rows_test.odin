package json_tests

// `query`: a path applied to a built document answers what a `.Path` scan of the same source answers, in the same
// order, whether it is given as text or as a parsed `Path`.

import json "../.."
import "core:slice"
import "core:strings"
import "core:testing"

// The text of every value `path_text` finds, joined with `,`. The text and its parsed `Path` give the same
// answers, and each found answer's `node` is the row of its span.
@(private)
path_row_texts :: proc(t: ^testing.T, doc: ^json.Document, path_text: string) -> string {
	steps: [16]json.Step
	path, fault := json.parse_path(path_text, steps[:])
	testing.expectf(t, fault == nil, "%q: %v", path_text, fault)
	answers := make([dynamic]json.Answer, context.temp_allocator)
	testing.expect_value(t, json.query(doc, path, &answers), nil)
	from_text := make([dynamic]json.Answer, context.temp_allocator)
	testing.expect_value(t, json.query(doc, path_text, &from_text), nil)
	testing.expectf(t, slice.equal(answers[:], from_text[:]), "%q: Path %v, text %v", path_text, answers[:], from_text[:])
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	found := 0
	for a in answers {
		if a.outcome != .Found {
			continue
		}
		n := doc.rows[a.node]
		testing.expect(t, u64(n.lo) == a.lo && u64(n.hi) == a.hi && n.kind == a.kind)
		if found > 0 {
			strings.write_byte(&b, ',')
		}
		found += 1
		strings.write_string(&b, string(doc.src[a.lo:a.hi]))
	}
	return strings.to_string(b)
}

@(test)
test_query_answers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := `{"a":{"b":[1,2,{"c":3}]},"logs":[{"id":1},{"x":0},7,{"id":2}],"d":1,"d":2}`
	doc := build_ok(t, src)
	defer json.destroy(&doc)
	Case :: struct {
		path, want: string,
	}
	cases := []Case{
		{`.`, src},
		{`.a.b[0]`, `1`},
		{`.a.b[-1].c`, `3`},
		{`.a.b[3]`, ``},
		{`.a.b[-4]`, ``},
		{`.a[0]`, ``},
		{`.a.b.c`, ``},
		{`.d`, `2`},
		{`.logs[].id`, `1,2`},
		{`.a.b[]`, `1,2,{"c":3}`},
		{`.[]`, `{"b":[1,2,{"c":3}]},[{"id":1},{"x":0},7,{"id":2}],2`},
		{`first(.logs[].id)`, `1`},
		{`limit(3; .a.b[])`, `1,2,{"c":3}`},
		{`.missing`, ``},
	}
	for c in cases {
		got := path_row_texts(t, &doc, c.path)
		testing.expectf(t, got == c.want, "%s: %q, want %q", c.path, got, c.want)
	}

	// A path with no `Any` step that does not land answers one miss, as `find` does; a path through `Any` answers
	// only where it lands.
	rows: [dynamic]json.Answer
	defer delete(rows)
	b := json.pointer(&doc, json.ROOT, "/a/b")
	for path in ([]string{".a.b[3]", ".a.b.c"}) {
		clear(&rows)
		testing.expect_value(t, json.query(&doc, path, &rows), nil)
		found, _ := json.find(raw(src), path)
		testing.expectf(t, len(rows) == 1 && rows[0] == found, "%s: %v, find %v", path, rows[:], found)
	}
	testing.expect_value(t, rows[0].outcome, json.Path_Outcome.Type_Mismatch)
	clear(&rows)
	testing.expect_value(t, json.query(&doc, ".a.b[3]", &rows), nil)
	testing.expect_value(t, rows[0], json.Answer{owner = u64(doc.rows[b].lo), node = json.NO_NODE, outcome = .Missing})
	clear(&rows)
	testing.expect_value(t, json.query(&doc, ".logs[].id", &rows), nil)
	testing.expect_value(t, len(rows), 2)
	clear(&rows)

	// From a node, a path reads that node's value, and an answer is owned by the container it was met in.
	logs := json.pointer(&doc, json.ROOT, "/logs")
	testing.expect_value(t, json.query_in(&doc, logs, ".[].id", &rows), nil)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[0].owner, u64(doc.rows[json.pointer(&doc, logs, "/0")].lo))
	clear(&rows)
	testing.expect_value(t, json.query_in(&doc, logs, ".", &rows), nil)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].node, logs)
	testing.expect_value(t, rows[0].owner, u64(doc.rows[json.ROOT].lo))
	clear(&rows)
	testing.expect_value(t, json.query_in(&doc, json.NO_NODE, ".[]", &rows), nil)
	testing.expect_value(t, len(rows), 0)
	clear(&rows)

	// Text that does not parse is its fault, and reaches nothing.
	fault, faulted := json.query(&doc, ".[", &rows).?
	testing.expectf(t, faulted && fault.kind == .Bad_Path, "query .[: %v", fault)
	testing.expect_value(t, len(rows), 0)
}
