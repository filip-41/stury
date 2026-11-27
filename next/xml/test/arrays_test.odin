package xml_tests

import "base:runtime"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

@(private = "file")
to_json_str :: proc(t: ^testing.T, doc: ^tape.Document, loc := #caller_location) -> string {
	txt, _, err := json.write(doc, .Json, {}, context.allocator)
	testing.expectf(t, err == nil, "json.write failed: %v", err, loc = loc)
	return string(txt)
}

@(private = "file")
to_xml_str :: proc(t: ^testing.T, doc: ^tape.Document, loc := #caller_location) -> string {
	txt, _, err := xml.write(doc, .Xml, {}, context.allocator)
	testing.expectf(t, err == nil, "xml.write failed: %v", err, loc = loc)
	return string(txt)
}

@(private = "file")
check_doc_invariants :: proc(t: ^testing.T, doc: ^tape.Document, loc := #caller_location) {
	testing.expect(t, len(doc.nodes) > 0, "empty doc", loc = loc)
	testing.expect_value(t, int(doc.nodes[0].n), len(doc.nodes), loc = loc)
	// Verify every container's `.n` and `child_count` matches its subtree, and `counts` is sorted.
	for i := 0; i < len(doc.nodes); i += 1 {
		node := doc.nodes[i]
		if node.kind <= .Plain {
			continue
		}
		end := i + int(node.n)
		testing.expect(t, end <= len(doc.nodes), "container subtree exceeds document", loc = loc)
		children := 0
		for j := i + 1; j < end; {
			ch := doc.nodes[j]
			if ch.kind <= .Plain {
				if ch.role == .Value {
					children += 1
				}
				j += 1
			} else {
				children += 1
				j += int(ch.n)
			}
		}
		testing.expect_value(t, tape.child_count(doc, tape.Node_Index(i), node), children, loc = loc)
	}
	for i in 1 ..< len(doc.counts) {
		testing.expect(t, doc.counts[i - 1].node < doc.counts[i].node, "counts not sorted", loc = loc)
	}
	for i in 1 ..< len(doc.facts) {
		testing.expect(t, doc.facts[i - 1].node <= doc.facts[i].node, "facts not sorted by node", loc = loc)
	}
}

@(test)
xml_arrays_always_shapes_and_roundtrip :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Case :: struct {
		src:       string,
		want_json: string,
		want_xml:  string,
	}
	cases := [?]Case {
		// Empty root stays scalar null; root itself is not wrapped under `.Always`.
		{`<root/>`, `{"root":null}`, `<root/>`},
		// Text-only root stays string.
		{`<root>hello</root>`, `{"root":"hello"}`, `<root>hello</root>`},
		// Single child element wrapped in 1-element array.
		{`<root><item>a</item></root>`, `{"root":{"item":["a"]}}`, `<root><item>a</item></root>`},
		// Empty child element wrapped in 1-element array of null.
		{`<root><item/></root>`, `{"root":{"item":[null]}}`, `<root><item/></root>`},
		// Multiple adjacent siblings collapsed into one array (no double-wrapping).
		{`<root><item>a</item><item>b</item></root>`, `{"root":{"item":["a","b"]}}`, `<root><item>a</item><item>b</item></root>`},
		// Nested child elements each become arrays.
		{`<root><sub><x>1</x></sub></root>`, `{"root":{"sub":[{"x":["1"]}]}}`, `<root><sub><x>1</x></sub></root>`},
		// Non-adjacent repeated siblings grouped under first occurrence in document order.
		{`<r><a/><b>1</b><a/></r>`, `{"r":{"a":[null,null],"b":["1"]}}`, `<r><a/><a/><b>1</b></r>`},
		// Single `#text` is NOT wrapped under `.Always`.
		{`<r>hi<a/></r>`, `{"r":{"#text":"hi","a":[null]}}`, `<r>hi<a/></r>`},
		// 2+ `#text` children grouped into one `#text` array for valid unique JSON keys.
		{`<r>hi<a/>bye</r>`, `{"r":{"#text":["hi","bye"],"a":[null]}}`, `<r>hibye<a/></r>`},
	}

	opts := xml.Options{format = xml.Xml_Options{arrays = .Always}}
	for tc in cases {
		doc, err := xml.build(transmute([]u8)tc.src, .Xml, opts)
		testing.expectf(t, err == nil, "build failed for %s: %v", tc.src, err)
		defer xml.destroy(&doc)
		check_doc_invariants(t, &doc)

		j := to_json_str(t, &doc)
		defer delete(j)
		testing.expect_value(t, j, tc.want_json)

		x := to_xml_str(t, &doc)
		defer delete(x)
		testing.expect_value(t, x, tc.want_xml)
	}
}

@(test)
xml_arrays_preserves_facts_attributes_dtd_and_namespaces :: proc(t: ^testing.T) {
	testkit.deadline(t)

	src := `<?xml version="1.0"?><!DOCTYPE root [<!ENTITY greet "hi">]><!--top--><root xmlns:p="http://example.com/ns"><!--c1--><p:item id="1">&greet;</p:item><other k="x">v</other><?pi body?><p:item id="2">two</p:item></root>`
	opts := xml.Options{format = xml.Xml_Options{arrays = .Always}}
	doc, err := xml.build(transmute([]u8)src, .Xml, opts)
	testing.expectf(t, err == nil, "build failed: %v", err)
	defer xml.destroy(&doc)
	check_doc_invariants(t, &doc)

	// Verify JSON projection with entity expansion and non-adjacent grouping.
	j := to_json_str(t, &doc)
	defer delete(j)
	testing.expect_value(t, j, `{"root":{"p:item":["hi","two"],"other":["v"]}}`)

	// Verify attributes, comments, PIs stay attached to the exact array elements.
	r := xml.Reader{doc = &doc}
	root_val, p0 := xml.member(r, xml.ROOT, "root")
	testing.expect_value(t, p0, tape.Presence.Found)
	items_arr, p1 := xml.member(r, root_val, "p:item")
	testing.expect_value(t, p1, tape.Presence.Found)
	testing.expect_value(t, doc.nodes[items_arr].kind, tape.Kind.Array)
	items_n, items_p, items_e := xml.length(r, items_arr, allocator = context.allocator)
	testing.expect(t, items_e == nil && items_p == .Found && items_n == 2)

	el0, e0 := xml.element(r, items_arr, 0)
	el1, e1 := xml.element(r, items_arr, 1)
	testing.expect(t, e0 == .Found && e1 == .Found)

	id0, has_id0 := testkit.attribute_value(&doc, el0, "id")
	id1, has_id1 := testkit.attribute_value(&doc, el1, "id")
	testing.expect(t, has_id0 && id0 == "1")
	testing.expect(t, has_id1 && id1 == "2")

	// Verify comment on el0 and PI on el1.
	has_c1 := false
	for f in xml.facts_of(&doc, el0) {
		if f.kind == .Comment {
			has_c1 = true
		}
	}
	has_pi := false
	for f in xml.facts_of(&doc, el1) {
		if f.kind == .Instruction {
			has_pi = true
		}
	}
	testing.expect(t, has_c1, "expected comment fact preserved on array element 0")
	testing.expect(t, has_pi, "expected PI fact preserved on array element 1")

	// Verify `xml.write` preserves attributes, comments, PIs, and DOCTYPE.
	x := to_xml_str(t, &doc)
	defer delete(x)
	testing.expect(t, strings.contains(x, `id="1"`), x)
	testing.expect(t, strings.contains(x, `id="2"`), x)
	testing.expect(t, strings.contains(x, `k="x"`), x)
	testing.expect(t, strings.contains(x, `<!--c1-->`), x)
	testing.expect(t, strings.contains(x, `<?pi body?>`), x)
	testing.expect(t, strings.contains(x, `<!DOCTYPE root`), x)
}

@(test)
xml_arrays_dups_policies_and_invalid_option :: proc(t: ^testing.T) {
	testkit.deadline(t)

	src := transmute([]u8)string(`<root><a>1</a><a>2</a></root>`)

	// `.First` keeps first `a` and `.Always` wraps it as `["1"]`.
	{
		doc, err := xml.build(src, .Xml, {dups = .First, format = xml.Xml_Options{arrays = .Always}})
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)
		j := to_json_str(t, &doc)
		defer delete(j)
		testing.expect_value(t, j, `{"root":{"a":["1"]}}`)
	}

	// `.Last` keeps last `a` and `.Always` wraps it as `["2"]`.
	{
		doc, err := xml.build(src, .Xml, {dups = .Last, format = xml.Xml_Options{arrays = .Always}})
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)
		j := to_json_str(t, &doc)
		defer delete(j)
		testing.expect_value(t, j, `{"root":{"a":["2"]}}`)
	}

	// `.Refuse` still rejects repeated sibling elements with `.Duplicate_Key`.
	{
		doc, err := xml.build(src, .Xml, {dups = .Refuse, format = xml.Xml_Options{arrays = .Always}})
		defer xml.destroy(&doc)
		f, is_f := err.(tape.Fault)
		testing.expect(t, is_f && f.kind == .Duplicate_Key, "expected Duplicate_Key fault")
	}

	// Invalid enum value `Xml_Arrays(99)` rejected by `options_refused` and `normalize_arrays`.
	{
		doc, err := xml.build(src, .Xml, {format = xml.Xml_Options{arrays = xml.Xml_Arrays(99)}})
		defer xml.destroy(&doc)
		testing.expect_value(t, err, tape.Error(tape.Bad_Option{"format"}))
	}
	{
		doc, err := xml.build(src, .Xml)
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)
		testing.expect_value(t, xml.normalize_arrays(&doc, xml.Xml_Arrays(99)), tape.Error(tape.Bad_Option{"format"}))
	}
}

@(test)
xml_arrays_schema_predicate_and_auto_noop :: proc(t: ^testing.T) {
	testkit.deadline(t)

	src := transmute([]u8)string(`<root><title>hi</title><item>one</item><tag>a</tag><tag>b</tag></root>`)
	doc, err := xml.build(src, .Xml)
	testing.expect_value(t, err, tape.Error(nil))
	defer xml.destroy(&doc)

	// `.Auto` is an immediate no-op.
	before_len := len(doc.nodes)
	testing.expect_value(t, xml.normalize_arrays(&doc, .Auto), tape.Error(nil))
	testing.expect_value(t, len(doc.nodes), before_len)

	// `.Schema` wraps only paths matching predicate, while still grouping 2+ repeated siblings (`tag`).
	pred :: proc(_: rawptr, path: []string) -> bool {
		return len(path) == 2 && path[0] == "root" && path[1] == "item"
	}
	testing.expect_value(t, xml.normalize_arrays(&doc, .Schema, pred), tape.Error(nil))
	check_doc_invariants(t, &doc)

	j := to_json_str(t, &doc)
	defer delete(j)
	testing.expect_value(t, j, `{"root":{"title":"hi","item":["one"],"tag":["a","b"]}}`)
}

@(test)
xml_arrays_oom_leaves_doc_intact_and_leak_free :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Failing_Alloc :: struct {
		backing: runtime.Allocator,
		remain:  int,
	}
	fail_proc :: proc(
		data: rawptr,
		mode: runtime.Allocator_Mode,
		size, alignment: int,
		old_ptr: rawptr,
		old_size: int,
		loc := #caller_location,
	) -> ([]u8, runtime.Allocator_Error) {
		fa := (^Failing_Alloc)(data)
		if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
			if fa.remain <= 0 {
				return nil, .Out_Of_Memory
			}
			fa.remain -= 1
		}
		return fa.backing.procedure(fa.backing.data, mode, size, alignment, old_ptr, old_size, loc)
	}

	src := transmute([]u8)string(`<root xmlns:p="http://example.com"><p:a id="1">x</p:a><b id="2">y</b><p:a id="3">z</p:a></root>`)
	// Exercise OOM at every allocation step `0..12`.
	for budget in 0 ..< 12 {
		doc, err := xml.build(src, .Xml)
		testing.expect_value(t, err, tape.Error(nil))
		orig_nodes := len(doc.nodes)
		orig_facts := len(doc.facts)

		fa := Failing_Alloc{backing = context.allocator, remain = budget}
		falloc := runtime.Allocator{procedure = fail_proc, data = &fa}
		// Use failing allocator as scratch allocator so failures happen mid-normalization.
		nerr := xml.normalize_arrays(&doc, .Always, nil, nil, falloc)
		if nerr != nil {
			testing.expect_value(t, nerr, tape.Error(runtime.Allocator_Error.Out_Of_Memory))
			// Document must remain completely intact!
			testing.expect_value(t, len(doc.nodes), orig_nodes)
			testing.expect_value(t, len(doc.facts), orig_facts)
			check_doc_invariants(t, &doc)
		} else {
			check_doc_invariants(t, &doc)
		}
		xml.destroy(&doc)
	}
}

@(test)
xml_arrays_deep_iterative_20000_levels :: proc(t: ^testing.T) {
	testkit.deadline(t)

	DEPTH :: 20_000
	sb := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&sb)
	for _ in 0 ..< DEPTH {
		strings.write_string(&sb, "<a>")
	}
	strings.write_string(&sb, "ok")
	for _ in 0 ..< DEPTH {
		strings.write_string(&sb, "</a>")
	}
	src := transmute([]u8)strings.to_string(sb)

	opts := xml.Options {
		budget = {depth = DEPTH + 16},
		format = xml.Xml_Options{arrays = .Always},
	}
	doc, err := xml.build(src, .Xml, opts)
	testing.expectf(t, err == nil, "deep build failed: %v", err)
	defer xml.destroy(&doc)

	// Walk all 20,000 levels: root `a` is Object, then 19,999 nested `a` arrays each holding 1 element.
	r := xml.Reader{doc = &doc}
	cur, p := xml.member(r, xml.ROOT, "a")
	testing.expect_value(t, p, tape.Presence.Found)
	for _ in 1 ..< DEPTH {
		arr, ap := xml.member(r, cur, "a")
		testing.expect_value(t, ap, tape.Presence.Found)
		testing.expect_value(t, doc.nodes[arr].kind, tape.Kind.Array)
		arr_n, arr_lp, arr_e := xml.length(r, arr, allocator = context.allocator)
		testing.expect(t, arr_e == nil && arr_lp == .Found && arr_n == 1)
		el, ep := xml.element(r, arr, 0)
		testing.expect_value(t, ep, tape.Presence.Found)
		cur = el
	}
	testing.expect_value(t, doc.nodes[cur].kind, tape.Kind.String)
	buf: [8]u8
	s, sok := xml.node_text(&doc, cur, buf[:])
	testing.expect(t, sok && s == "ok")
}

@(test)
xml_arrays_wide_saturated_counts :: proc(t: ^testing.T) {
	testkit.deadline(t)

	N :: int(tape.MAX_CHILDREN) + 25 // 8216 elements -> saturates `spelling` and populates `doc.counts`
	sb := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, "<r>")
	for _ in 0 ..< N {
		strings.write_string(&sb, "<x/>")
	}
	strings.write_string(&sb, "</r>")
	src := transmute([]u8)strings.to_string(sb)

	doc, err := xml.build(src, .Xml, {format = xml.Xml_Options{arrays = .Always}})
	testing.expectf(t, err == nil, "wide build failed: %v", err)
	defer xml.destroy(&doc)
	check_doc_invariants(t, &doc)

	r := xml.Reader{doc = &doc}
	rv, p0 := xml.member(r, xml.ROOT, "r")
	testing.expect_value(t, p0, tape.Presence.Found)
	xv, p1 := xml.member(r, rv, "x")
	testing.expect_value(t, p1, tape.Presence.Found)
	testing.expect_value(t, doc.nodes[xv].kind, tape.Kind.Array)
	xv_n, xv_lp, xv_e := xml.length(r, xv, allocator = context.allocator)
	testing.expect(t, xv_e == nil && xv_lp == .Found && xv_n == N)
	testing.expect(t, len(doc.counts) > 0, "expected saturated count entry in doc.counts")
}

@(test)
xml_arrays_refuses_partial_and_non_xml_docs :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Partial `xml.scan` document must be refused cleanly.
	{
		xml_src := transmute([]u8)string(`<root><item>a</item></root>`)
		steps := [?]tape.Step{tape.Name("root"), tape.Name("item")}
		paths := [?][]tape.Step{steps[:]}
		dem, derr := tape.demand_of(paths[:])
		testing.expect_value(t, derr, nil)
		defer tape.destroy_demand(&dem)

		sdoc, serr := xml.scan(xml_src, &dem, .Xml)
		testing.expect_value(t, serr, tape.Error(nil))
		defer xml.destroy(&sdoc)
		testing.expect(t, sdoc.partial != nil)

		testing.expect_value(t, xml.normalize_arrays(&sdoc, .Always), tape.Error(tape.Bad_Option{"document"}))
	}

	// Non-XML (`json.build`) document must be refused cleanly without dereferencing wrong format.
	{
		jdoc, jerr := json.build(transmute([]u8)string(`{"root":{"item":"a"}}`), .Json)
		testing.expect_value(t, jerr, tape.Error(nil))
		defer tape.destroy(&jdoc)
		testing.expect_value(t, xml.normalize_arrays(&jdoc, .Always), tape.Error(tape.Bad_Option{"format"}))
	}

	// Nil-format document must be refused cleanly.
	{
		ndoc := tape.Document{nodes = make([]tape.Node, 1)}
		defer delete(ndoc.nodes)
		ndoc.nodes[0] = {n = 1, kind = .Object, role = .Value}
		testing.expect_value(t, xml.normalize_arrays(&ndoc, .Always), tape.Error(tape.Bad_Option{"format"}))
	}
}

@(test)
xml_arrays_namespace_expanded_and_close_end_on_wrapped_elements :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. `xml.namespace` on elements wrapped in `.Array` (including non-adjacent repeated siblings).
	{
		src := transmute([]u8)string(`<root xmlns:p="http://example.com/ns"><p:item id="1">a</p:item><other/><p:item id="2">b</p:item></root>`)
		doc, err := xml.build(src, .Xml, {format = xml.Xml_Options{arrays = .Always}})
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)

		r := xml.Reader{doc = &doc}
		root_val, p0 := xml.member(r, xml.ROOT, "root")
		testing.expect_value(t, p0, tape.Presence.Found)
		items_arr, p1 := xml.member(r, root_val, "p:item")
		testing.expect_value(t, p1, tape.Presence.Found)
		testing.expect_value(t, doc.nodes[items_arr].kind, tape.Kind.Array)

		// The `.Array` wrapper itself is not an element.
		_, arr_ns_p := xml.namespace(&doc, items_arr)
		testing.expect_value(t, arr_ns_p, tape.Presence.Missing)

		el0, e0 := xml.element(r, items_arr, 0)
		el1, e1 := xml.element(r, items_arr, 1)
		testing.expect(t, e0 == .Found && e1 == .Found)

		ns0, pns0 := xml.namespace(&doc, el0)
		ns1, pns1 := xml.namespace(&doc, el1)
		testing.expect(t, pns0 == .Found && ns0 == "http://example.com/ns")
		testing.expect(t, pns1 == .Found && ns1 == "http://example.com/ns")
	}

	// 2. `xml.expanded` (`{urn:x}item`) on element-local `xmlns:p="urn:x"` inside a wrapped `.Array`.
	{
		src := transmute([]u8)string(`<root><p:item xmlns:p="urn:x">v</p:item></root>`)
		doc, err := xml.build(src, .Xml, {format = xml.Xml_Options{arrays = .Always}})
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)

		r := xml.Reader{doc = &doc}
		root_val, p0 := xml.member(r, xml.ROOT, "root")
		testing.expect_value(t, p0, tape.Presence.Found)

		arr, p1 := xml.member(r, root_val, "{urn:x}item")
		testing.expect_value(t, p1, tape.Presence.Found)
		testing.expect_value(t, doc.nodes[arr].kind, tape.Kind.Array)
		el0, e0 := xml.element(r, arr, 0)
		testing.expect_value(t, e0, tape.Presence.Found)
		ns, pns := xml.namespace(&doc, el0)
		testing.expect(t, pns == .Found && ns == "urn:x")
	}

	// 3. `xml.close_end` on non-adjacent grouped siblings `<r><a>1</a><b>2</b><a>3</a></r>` under `.Always` and `.Schema`.
	{
		src := transmute([]u8)string(`<r><a>1</a><b>2</b><a>3</a></r>`)
		doc, err := xml.build(src, .Xml, {format = xml.Xml_Options{arrays = .Always}})
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)

		r := xml.Reader{doc = &doc}
		rv, p0 := xml.member(r, xml.ROOT, "r")
		testing.expect_value(t, p0, tape.Presence.Found)
		end_r, ok_r := doc.format.close_end(&doc, rv)
		testing.expect(t, ok_r)
		testing.expect_value(t, end_r, u64(len(src)))

		a_arr, p1 := xml.member(r, rv, "a")
		testing.expect_value(t, p1, tape.Presence.Found)
		end_a, ok_a := doc.format.close_end(&doc, a_arr)
		testing.expect(t, ok_a)
		// `<a>3</a>` ends right before `</r>` (length - 4).
		testing.expect_value(t, end_a, u64(len(src) - 4))
	}
	{
		// Under `.Schema` with false predicate: `a` becomes `.Array` while `b` stays scalar at the tail of preorder!
		src := transmute([]u8)string(`<r><a>1</a><b>2</b><a>3</a></r>`)
		doc, err := xml.build(src, .Xml)
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)
		testing.expect_value(t, xml.normalize_arrays(&doc, .Schema), tape.Error(nil))

		r := xml.Reader{doc = &doc}
		rv, p0 := xml.member(r, xml.ROOT, "r")
		testing.expect_value(t, p0, tape.Presence.Found)
		end_r, ok_r := doc.format.close_end(&doc, rv)
		testing.expect(t, ok_r)
		testing.expect_value(t, end_r, u64(len(src)))
	}
}

@(test)
xml_arrays_budget_enforcement_and_unsupported_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)

	src := transmute([]u8)string(`<root><a>1</a><b>2</b></root>`)

	// Raw build produces 7 nodes; `.Always` adds 2 `.Array` nodes (9 total).
	// `Budget{nodes = 8}` passes raw walk but MUST return `Exceeded{.Nodes}` during `.Always` normalization!
	{
		doc, err := xml.build(src, .Xml, {budget = {nodes = 8}, format = xml.Xml_Options{arrays = .Always}})
		defer xml.destroy(&doc)
		ex, is_ex := err.(tape.Exceeded)
		testing.expectf(t, is_ex && ex.kind == .Nodes, "expected Exceeded{.Nodes}, got %v", err)
	}
	// `Budget{nodes = 9}` succeeds cleanly!
	{
		doc, err := xml.build(src, .Xml, {budget = {nodes = 9}, format = xml.Xml_Options{arrays = .Always}})
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)
		testing.expect_value(t, len(doc.nodes), 9)
	}
	// Tight `Budget{memory}` fails cleanly with `Exceeded{.Memory}` during normalization.
	{
		doc, err := xml.build(src, .Xml)
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)
		nerr := xml.normalize_arrays(&doc, .Always, nil, nil, context.allocator, {memory = 64})
		ex, is_ex := nerr.(tape.Exceeded)
		testing.expectf(t, is_ex && ex.kind == .Memory, "expected Exceeded{.Memory}, got %v", nerr)
		check_doc_invariants(t, &doc)
	}

	// `build` refuses `.Schema`; `find`, `scan`, and `records_open` refuse `arrays != .Auto`.
	{
		doc, err := xml.build(src, .Xml, {format = xml.Xml_Options{arrays = .Schema}})
		defer xml.destroy(&doc)
		testing.expect_value(t, err, tape.Error(tape.Bad_Option{"format"}))
	}
	{
		steps := [?]tape.Step{tape.Name("root"), tape.Name("a")}
		_, ferr := xml.find(src, steps[:], .Xml, opts = {format = xml.Xml_Options{arrays = .Always}})
		testing.expect_value(t, ferr, tape.Error(tape.Bad_Option{"format"}))
	}
	{
		steps := [?]tape.Step{tape.Name("root"), tape.Name("a")}
		paths := [?][]tape.Step{steps[:]}
		dem, derr := tape.demand_of(paths[:])
		testing.expect_value(t, derr, nil)
		defer tape.destroy_demand(&dem)
		sdoc, serr := xml.scan(src, &dem, .Xml, opts = {format = xml.Xml_Options{arrays = .Always}})
		defer xml.destroy(&sdoc)
		testing.expect_value(t, serr, tape.Error(tape.Bad_Option{"format"}))
	}
	{
		recs := xml.records_open(src, .Concatenated, .Xml, {format = xml.Xml_Options{arrays = .Always}})
		defer tape.destroy_records(&recs)
		testing.expect_value(t, recs.err, tape.Error(tape.Bad_Option{"format"}))
	}
}
