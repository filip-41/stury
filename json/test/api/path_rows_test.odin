package json_tests

// `query`: a path applied to a built document's row answers the rows a `.Path` scan of the same
// source finds, in the same order, whether it is given as text or as a parsed `Path`.

import json "../.."
import "core:slice"
import "core:strings"
import "core:testing"

// The text of every row `path_text` reaches from `row`, joined with `,`. The text and its parsed `Path`
// reach the same rows.
@(private)
path_row_texts :: proc(t: ^testing.T, doc: ^json.Document, row: json.Node, path_text: string) -> string {
	steps: [16]json.Step
	path, fault := json.parse_path(path_text, steps[:])
	testing.expectf(t, fault == nil, "%q: %v", path_text, fault)
	rows := make([dynamic]json.Node, context.temp_allocator)
	testing.expect_value(t, json.query(doc, row, path, &rows), nil)
	from_text := make([dynamic]json.Node, context.temp_allocator)
	testing.expect_value(t, json.query(doc, row, path_text, &from_text), nil)
	testing.expectf(t, slice.equal(rows[:], from_text[:]), "%q: Path %v, text %v", path_text, rows[:], from_text[:])
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for r, i in rows {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		n := doc.rows[r]
		strings.write_string(&b, string(doc.src[n.lo:n.hi]))
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
		got := path_row_texts(t, &doc, 0, c.path)
		testing.expectf(t, got == c.want, "%s: %q, want %q", c.path, got, c.want)
	}

	// From an inner row, the same path reads relative to it.
	logs := json.child(&doc, 0, "logs")
	testing.expect_value(t, path_row_texts(t, &doc, logs, `.[3].id`), `2`)

	// Text that does not parse is its fault, and reaches nothing.
	rows: [dynamic]json.Node
	defer delete(rows)
	fault, faulted := json.query(&doc, json.ROOT, ".[", &rows).?
	testing.expectf(t, faulted && fault.error == .Unclosed_Bracket, "query .[: %v", fault)
	testing.expect_value(t, len(rows), 0)
}
