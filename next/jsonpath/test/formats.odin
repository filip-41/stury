package jsonpath_tests

import "core:testing"
import "stury:json"
import "stury:jsonpath"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

@(private = "file")
eval_doc_expect :: proc(t: ^testing.T, prog: ^jsonpath.Program, doc: tape.Document, want_vals: []string, want_paths: []string = nil, loc := #caller_location) {
	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer {
		testing.expect_value(t, query.heap_live(&h), u64(0), loc = loc)
		query.heap_destroy(&h)
	}
	root, _ := query.document_value(&h, doc, true)
	defer query.release(&h, root)
	col := Collected{h = &h, vals = make([dynamic]string), paths = make([dynamic]string), alloc = context.allocator}
	defer destroy_collected(&col)
	end := jsonpath.eval(prog, &h, root, collect_cb, &col, {want_paths = true})
	testing.expect_value(t, end, jsonpath.Run_End.Done, loc = loc)
	testing.expect_value(t, len(col.vals), len(want_vals), loc = loc)
	for i in 0 ..< min(len(col.vals), len(want_vals)) {
		testing.expect_value(t, col.vals[i], want_vals[i], loc = loc)
	}
	for i in 0 ..< min(len(col.paths), len(want_paths)) {
		testing.expect_value(t, col.paths[i], want_paths[i], loc = loc)
	}
}

// Multi-format independence test: the exact same compiled JSONPath runs over JSON, TOML, and XML documents
// strictly through `stury:lib/query` (zero format imports in `next/jsonpath`).
@(test)
multi_format_json_toml_xml :: proc(t: ^testing.T) {
	testkit.deadline(t)

	prog, cerr := jsonpath.compile(`$.server[?@.port >= 8000].host`)
	testing.expect_value(t, cerr.kind, jsonpath.Error_Kind.None)
	defer jsonpath.destroy_program(prog)

	// 1. JSON
	{
		doc, err := json.build(transmute([]u8)string(`{"server":[{"host":"a.local","port":80},{"host":"b.local","port":8080},{"host":"c.local","port":9000}]}`), .Json)
		testing.expect(t, err == nil)
		eval_doc_expect(t, prog, doc, {`"b.local"`, `"c.local"`}, {`$['server'][1]['host']`})
	}

	// 2. TOML
	{
		toml_src := `
[[server]]
host = "a.local"
port = 80

[[server]]
host = "b.local"
port = 8080

[[server]]
host = "c.local"
port = 9000
`
		doc, err := toml.build(transmute([]u8)toml_src)
		testing.expect(t, err == nil)
		eval_doc_expect(t, prog, doc, {`"b.local"`, `"c.local"`})
	}

	// 3. XML
	{
		xml_src := `<config><server><host>a.local</host><port>80</port></server><server><host>b.local</host><port>8080</port></server></config>`
		xprog, xerr := jsonpath.compile(`$.config.server[?@.host == "b.local"].port`)
		testing.expect_value(t, xerr.kind, jsonpath.Error_Kind.None)
		defer jsonpath.destroy_program(xprog)

		doc, err := xml.build(transmute([]u8)xml_src)
		testing.expect(t, err == nil)
		eval_doc_expect(t, xprog, doc, {`"8080"`})
	}
}

// Reusable `Run` across multiple documents without leaks.
@(test)
reusable_run_across_documents :: proc(t: ^testing.T) {
	testkit.deadline(t)
	prog, cerr := jsonpath.compile(`$.items[?match(@.name, "[a-z]+")].id`)
	testing.expect_value(t, cerr.kind, jsonpath.Error_Kind.None)
	defer jsonpath.destroy_program(prog)

	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer {
		testing.expect_value(t, query.heap_live(&h), u64(0))
		query.heap_destroy(&h)
	}

	run: jsonpath.Run
	jsonpath.run_init(&run, prog, &h, {want_paths = true})
	defer jsonpath.run_destroy(&run)

	docs := [?]string{
		`{"items":[{"id":1,"name":"foo"},{"id":2,"name":"BAR"}]}`,
		`{"items":[{"id":3,"name":"baz"},{"id":4,"name":"qux"}]}`,
	}
	expected := [?][]string{{"1"}, {"3", "4"}}

	for dsrc, di in docs {
		doc, err := json.build(transmute([]u8)dsrc, .Json)
		testing.expect(t, err == nil)
		root, _ := query.document_value(&h, doc, true)
		col := Collected{h = &h, vals = make([dynamic]string), paths = make([dynamic]string), alloc = context.allocator}
		end := jsonpath.run_value(&run, root, collect_cb, &col)
		query.release(&h, root)
		testing.expect_value(t, end, jsonpath.Run_End.Done)
		testing.expect_value(t, len(col.vals), len(expected[di]))
		for want, wi in expected[di] {
			testing.expect_value(t, col.vals[wi], want)
		}
		destroy_collected(&col)
	}
}
