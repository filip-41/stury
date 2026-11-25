// Tests for explicit-stack schema inference (`infer_document`, `infer_value`, `infer_merge`, `inferred`),
// including 10,000-level deep nesting, map collapse, ranges, XML markup, and infer -> compile -> check roundtrips.
package schema_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"
import "stury:lib/schema/schema"
import "stury:testkit"
import "stury:xml"

@(test)
infer_roundtrip_required_optional_and_ranges :: proc(t: ^testing.T) {
	testkit.deadline(t)
	inf := schema.Inferred{ranges = true}
	defer schema.inferred_destroy(&inf)

	samples := [?]string{
		`{"id": 1, "name": "alice", "score": 9.5, "tags": ["a", "b"]}`,
		`{"id": 2, "name": "bob", "score": 10, "tags": ["c"], "note": "hi"}`,
		`{"id": 3, "name": "charlie", "score": 7.25, "tags": ["d", "e", "f"]}`,
	}
	for s in samples {
		doc, berr := json.build(transmute([]u8)s, .Json)
		testing.expect(t, berr == nil)
		defer tape.destroy_document(&doc)
		testing.expect_value(t, schema.infer_document(&inf, &doc), nil)
	}

	desc, ierr := schema.inferred(&inf)
	testing.expect_value(t, ierr, nil)
	defer rules.description_destroy(&desc)

	c, cerr := schema.compile_description(&desc)
	defer schema.error_destroy(&cerr)
	testing.expect_value(t, cerr.kind, schema.Error_Kind.None)
	defer schema.destroy(c)

	// All training samples MUST pass!
	for s in samples {
		expect_json_valid(t, c, s, true)
	}
	// Missing required `id` fails, out-of-range `id` fails, optional `note` may be omitted
	expect_json_valid(t, c, `{"name": "alice", "score": 8, "tags": ["a"]}`, false)
	expect_json_valid(t, c, `{"id": 99, "name": "alice", "score": 8, "tags": ["a"]}`, false)
	expect_json_valid(t, c, `{"id": 2, "name": "al", "score": 8, "tags": ["a"]}`, false) // minLength=3 ("bob")
	expect_json_valid(t, c, `{"id": 2, "name": "dan", "score": 8, "tags": []}`, false) // minItems=1
}

@(test)
infer_map_collapse_and_merge :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// 1. Integer keys collapse to open map (`additionalProperties`)
	inf_int := schema.Inferred{}
	defer schema.inferred_destroy(&inf_int)
	d1, _ := json.build(transmute([]u8)string(`{"10": "a", "20": "b"}`), .Json)
	defer tape.destroy_document(&d1)
	testing.expect_value(t, schema.infer_document(&inf_int, &d1), nil)
	desc1, _ := schema.inferred(&inf_int)
	defer rules.description_destroy(&desc1)
	testing.expect(t, len(desc1.objects) == 1)
	testing.expect(t, len(desc1.objects[0].members) == 0)
	testing.expect(t, desc1.objects[0].additional != rules.NONE)

	// 2. >64 distinct member names collapse to open map
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_byte(&b, '{')
	for i in 0 ..< 70 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, `"k%d": %d`, i, i)
	}
	strings.write_byte(&b, '}')
	d_wide, _ := json.build(transmute([]u8)strings.to_string(b), .Json)
	defer tape.destroy_document(&d_wide)
	inf_wide := schema.Inferred{}
	defer schema.inferred_destroy(&inf_wide)
	testing.expect_value(t, schema.infer_document(&inf_wide, &d_wide), nil)
	desc_wide, _ := schema.inferred(&inf_wide)
	defer rules.description_destroy(&desc_wide)
	testing.expect(t, len(desc_wide.objects[0].members) == 0)
	testing.expect(t, desc_wide.objects[0].additional != rules.NONE)

	// 3. `infer_merge` merges two independent summaries accurately
	a, b_inf: schema.Inferred
	defer schema.inferred_destroy(&a)
	defer schema.inferred_destroy(&b_inf)
	da, _ := json.build(transmute([]u8)string(`{"x": 1, "y": "hi"}`), .Json)
	db, _ := json.build(transmute([]u8)string(`{"x": 2, "z": true}`), .Json)
	defer tape.destroy_document(&da)
	defer tape.destroy_document(&db)
	testing.expect_value(t, schema.infer_document(&a, &da), nil)
	testing.expect_value(t, schema.infer_document(&b_inf, &db), nil)
	testing.expect_value(t, schema.infer_merge(&a, &b_inf), nil)
	dm, _ := schema.inferred(&a)
	defer rules.description_destroy(&dm)
	cm, cerr := schema.compile_description(&dm)
	defer schema.error_destroy(&cerr)
	testing.expect_value(t, cerr.kind, schema.Error_Kind.None)
	defer schema.destroy(cm)
	expect_json_valid(t, cm, `{"x": 1, "y": "hi"}`, true)
	expect_json_valid(t, cm, `{"x": 2, "z": true}`, true)
	expect_json_valid(t, cm, `{"x": 3}`, true) // y and z are optional, x is required
	expect_json_valid(t, cm, `{"y": "hi"}`, false) // missing required x
}

@(test)
infer_xml_markup_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	xdoc, xerr := xml.build(transmute([]u8)string(`<book id="1"><tag>a</tag><tag>b</tag></book>`))
	testing.expect(t, xerr == nil)
	defer tape.destroy_document(&xdoc)

	inf := schema.Inferred{}
	defer schema.inferred_destroy(&inf)
	testing.expect_value(t, schema.infer_document(&inf, &xdoc), nil)
	desc, ierr := schema.inferred(&inf)
	testing.expect_value(t, ierr, nil)
	defer rules.description_destroy(&desc)

	// Verify inferred XML structure: root object has `book`, whose members include
	// `id` marked as `.Attribute` and `tag` collected as an array of strings.
	root := desc.nodes[desc.root]
	testing.expect(t, root.object >= 0)
	book_node: rules.Node_Index = rules.NONE
	for m in desc.objects[root.object].members {
		if m.name == "book" {
			book_node = m.node
		}
	}
	testing.expect(t, book_node != rules.NONE)
	book := desc.nodes[book_node]
	testing.expect(t, book.object >= 0)
	saw_attr := false
	saw_tag_arr := false
	for m in desc.objects[book.object].members {
		if m.name == "id" {
			saw_attr = desc.nodes[m.node].rules.markup == .Attribute
		}
		if m.name == "tag" {
			saw_tag_arr = .Array in desc.nodes[m.node].kinds
		}
	}
	testing.expect(t, saw_attr)
	testing.expect(t, saw_tag_arr)

	// Element-only XML document round-trips directly through `compile_description` -> `valid_document`.
	edoc, eerr := xml.build(transmute([]u8)string(`<book><title>Dune</title><year>1965</year></book>`))
	testing.expect(t, eerr == nil)
	defer tape.destroy_document(&edoc)
	einf := schema.Inferred{}
	defer schema.inferred_destroy(&einf)
	testing.expect_value(t, schema.infer_document(&einf, &edoc), nil)
	edesc, eierr := schema.inferred(&einf)
	testing.expect_value(t, eierr, nil)
	defer rules.description_destroy(&edesc)
	c, cerr := schema.compile_description(&edesc)
	defer schema.error_destroy(&cerr)
	testing.expect_value(t, cerr.kind, schema.Error_Kind.None)
	defer schema.destroy(c)
	testing.expect(t, schema.valid_document(c, &edoc))
}

@(test)
infer_deep_10000_levels_explicit_stack :: proc(t: ^testing.T) {
	testkit.deadline(t)
	DEPTH :: 10_000
	b := strings.builder_make(0, DEPTH * 6 + 8)
	defer strings.builder_destroy(&b)
	for _ in 0 ..< DEPTH {
		strings.write_string(&b, `{"a":`)
	}
	strings.write_string(&b, `42`)
	for _ in 0 ..< DEPTH {
		strings.write_byte(&b, '}')
	}
	src := transmute([]u8)strings.to_string(b)
	doc, berr := json.build(src, .Json, {budget = {depth = DEPTH + 16}})
	testing.expectf(t, berr == nil, "json.build 10k deep failed: %v", berr)
	if berr != nil {
		return
	}
	defer tape.destroy_document(&doc)

	inf := schema.Inferred{ranges = true}
	defer schema.inferred_destroy(&inf)
	testing.expect_value(t, schema.infer_document(&inf, &doc), nil)

	// Also merge into a second `Inferred` to verify `join_iterative` handles 10,000 levels!
	inf2 := schema.Inferred{ranges = true}
	defer schema.inferred_destroy(&inf2)
	testing.expect_value(t, schema.infer_merge(&inf2, &inf), nil)

	desc, ierr := schema.inferred(&inf2)
	testing.expect_value(t, ierr, nil)
	defer rules.description_destroy(&desc)
	testing.expect_value(t, len(desc.nodes), DEPTH + 1)
}

@(test)
infer_dsv_tabular_column_names :: proc(t: ^testing.T) {
	testkit.deadline(t)
	csv := "name,age\nAda,36\nGrace,85\n"
	doc, berr := dsv.build(transmute([]u8)csv, .Csv)
	testing.expect(t, berr == nil)
	defer tape.destroy_document(&doc)

	inf := schema.Inferred{}
	defer schema.inferred_destroy(&inf)
	testing.expect_value(t, schema.infer_document(&inf, &doc), nil)

	desc, ierr := schema.inferred(&inf)
	testing.expect_value(t, ierr, nil)
	defer rules.description_destroy(&desc)

	root := desc.nodes[desc.root]
	testing.expect(t, .Array in root.kinds && root.array >= 0)
	item_idx := desc.arrays[root.array].items
	testing.expect(t, item_idx != rules.NONE)
	item := desc.nodes[item_idx]
	testing.expect(t, .Object in item.kinds && item.object >= 0)
	saw_name, saw_age := false, false
	for m in desc.objects[item.object].members {
		if m.name == "name" {
			saw_name = true
		}
		if m.name == "age" {
			saw_age = true
		}
	}
	testing.expect(t, saw_name)
	testing.expect(t, saw_age)

	c, cerr := schema.compile_description(&desc)
	defer schema.error_destroy(&cerr)
	testing.expect_value(t, cerr.kind, schema.Error_Kind.None)
	defer schema.destroy(c)
	testing.expect(t, schema.valid_document(c, &doc))
}
