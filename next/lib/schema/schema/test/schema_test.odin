// Comprehensive tests for JSON Schema Draft 4 / 6 / 7 / 2019-09 / 2020-12 reading, compilation,
// format-agnostic schemas (JSON, TOML, CBOR), writing, draft conversion, Basic Output reports, and pieces.
package schema_test

import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/schema"
import "stury:testkit"
import "stury:toml"

@(private)
compile_or_fail :: proc(t: ^testing.T, text: string, opts := schema.Options{}, loc := #caller_location) -> ^schema.Compiled {
	c, err := schema.compile_json(transmute([]u8)text, opts)
	defer schema.error_destroy(&err)
	testing.expectf(t, err.kind == .None, "compile_json failed: kind=%v kw=%q msg=%q", err.kind, err.keyword, err.message, loc = loc)
	return c
}

@(private)
expect_json_valid :: proc(t: ^testing.T, c: ^schema.Compiled, input: string, want: bool, loc := #caller_location) {
	// Verify BOTH streaming `json.check` AND `schema.check_document(json.build)` agree!
	r_stream := json.check(transmute([]u8)input, &c.plan, .Json, {dups = c.opts.dups})
	defer check.result_destroy(&r_stream)
	testing.expectf(t, r_stream.valid == want, "stream mismatch on %q: got valid=%v (err=%v kw=%q), want %v", input, r_stream.valid, r_stream.err.kind, r_stream.err.keyword, want, loc = loc)

	doc, berr := json.build(transmute([]u8)input, .Json)
	testing.expectf(t, berr == nil, "json.build failed on %q: %v", input, berr, loc = loc)
	if berr != nil {
		return
	}
	defer tape.destroy_document(&doc)
	r_doc := schema.check_document(c, &doc)
	defer check.result_destroy(&r_doc)
	testing.expectf(t, r_doc.valid == want, "doc mismatch on %q: got valid=%v (err=%v kw=%q), want %v", input, r_doc.valid, r_doc.err.kind, r_doc.err.keyword, want, loc = loc)
}

@(test)
draft4_keywords_and_rules :: proc(t: ^testing.T) {
	testkit.deadline(t)
	s := `{
		"$schema": "http://json-schema.org/draft-04/schema#",
		"id": "https://example.com/d4.json",
		"type": "object",
		"definitions": {
			"posInt": {
				"type": "integer",
				"minimum": 0,
				"exclusiveMinimum": true,
				"maximum": 10,
				"exclusiveMaximum": true
			}
		},
		"properties": {
			"n": {"$ref": "#/definitions/posInt"},
			"pair": {
				"type": "array",
				"items": [{"type": "string"}, {"type": "integer"}],
				"additionalItems": false
			},
			"a": {"type": "number"},
			"b": {"type": "number"}
		},
		"required": ["n"],
		"dependencies": {
			"a": ["b"]
		},
		"additionalProperties": false
	}`
	c := compile_or_fail(t, s)
	defer schema.destroy(c)

	expect_json_valid(t, c, `{"n": 5, "pair": ["hi", 2]}`, true)
	// Draft 4 exclusiveMinimum/exclusiveMaximum
	expect_json_valid(t, c, `{"n": 0}`, false)
	expect_json_valid(t, c, `{"n": 10}`, false)
	// Draft 4 integer rejects `1.0` (integer_spelled)
	expect_json_valid(t, c, `{"n": 5.0}`, false)
	// Tuple items + additionalItems: false
	expect_json_valid(t, c, `{"n": 1, "pair": ["hi", 2, 3]}`, false)
	// dependencies array form
	expect_json_valid(t, c, `{"n": 1, "a": 1}`, false)
	expect_json_valid(t, c, `{"n": 1, "a": 1, "b": 2}`, true)
	// additionalProperties: false
	expect_json_valid(t, c, `{"n": 1, "extra": 1}`, false)

	// Draft 4 refuses boolean root schema
	_, err := schema.compile_json(transmute([]u8)string(`true`), {draft = .D04})
	testing.expect_value(t, err.kind, schema.Error_Kind.Bad_Schema)
	schema.error_destroy(&err)

	// Draft 4 refuses empty required array and duplicate enum values
	_, err2 := schema.compile_json(transmute([]u8)string(`{"$schema":"http://json-schema.org/draft-04/schema#","required":[]}`))
	testing.expect_value(t, err2.kind, schema.Error_Kind.Bad_Schema)
	schema.error_destroy(&err2)

	_, err3 := schema.compile_json(transmute([]u8)string(`{"$schema":"http://json-schema.org/draft-04/schema#","enum":[1, 1.0]}`))
	testing.expect_value(t, err3.kind, schema.Error_Kind.Bad_Schema)
	schema.error_destroy(&err3)

	// Draft 4 `$ref` overrides sibling keywords
	c_ref := compile_or_fail(t, `{"$schema":"http://json-schema.org/draft-04/schema#","definitions":{"s":{"type":"string"}},"$ref":"#/definitions/s","type":"integer"}`)
	defer schema.destroy(c_ref)
	expect_json_valid(t, c_ref, `"hello"`, true)
	expect_json_valid(t, c_ref, `42`, false)
}

@(test)
draft6_and_draft7_keywords :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Draft 6: boolean root, numeric exclusiveMinimum, const, contains, propertyNames
	c6 := compile_or_fail(t, `{
		"$schema": "http://json-schema.org/draft-06/schema#",
		"type": "object",
		"propertyNames": {"minLength": 2},
		"properties": {
			"ver": {"const": 6},
			"gt0": {"type": "number", "exclusiveMinimum": 0},
			"arr": {"type": "array", "contains": {"type": "integer", "minimum": 10}}
		}
	}`)
	defer schema.destroy(c6)
	expect_json_valid(t, c6, `{"ver": 6, "gt0": 0.1, "arr": [1, 10]}`, true)
	expect_json_valid(t, c6, `{"ver": 7}`, false)
	expect_json_valid(t, c6, `{"gt0": 0}`, false)
	expect_json_valid(t, c6, `{"arr": [1, 2]}`, false)
	expect_json_valid(t, c6, `{"x": 1}`, false)

	// Draft 7: if / then / else + format assertion
	c7 := compile_or_fail(t, `{
		"$schema": "http://json-schema.org/draft-07/schema#",
		"type": "object",
		"properties": {
			"kind": {"type": "string"},
			"day": {"type": "string", "format": "date"}
		},
		"if": {"properties": {"kind": {"const": "dated"}}, "required": ["kind"]},
		"then": {"required": ["day"]},
		"else": {"not": {"required": ["day"]}}
	}`, {format_assert = true})
	defer schema.destroy(c7)
	expect_json_valid(t, c7, `{"kind": "dated", "day": "2026-11-25"}`, true)
	expect_json_valid(t, c7, `{"kind": "dated", "day": "not-a-date"}`, false)
	expect_json_valid(t, c7, `{"kind": "dated"}`, false)
	expect_json_valid(t, c7, `{"kind": "plain"}`, true)
	expect_json_valid(t, c7, `{"kind": "plain", "day": "2026-11-25"}`, false)
}

@(test)
draft2019_09_and_2020_12_keywords :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Draft 2019-09: $defs, $anchor, $recursiveAnchor/$recursiveRef, dependentRequired/dependentSchemas,
	// minContains/maxContains, unevaluatedProperties
	c19 := compile_or_fail(t, `{
		"$schema": "https://json-schema.org/draft/2019-09/schema",
		"$id": "https://example.com/tree19",
		"$recursiveAnchor": true,
		"type": "object",
		"properties": {
			"val": {"type": "integer"},
			"next": {"$recursiveRef": "#"}
		},
		"required": ["val"],
		"unevaluatedProperties": false
	}`)
	defer schema.destroy(c19)
	expect_json_valid(t, c19, `{"val": 1, "next": {"val": 2}}`, true)
	expect_json_valid(t, c19, `{"val": 1, "next": {"val": "bad"}}`, false)
	expect_json_valid(t, c19, `{"val": 1, "extra": true}`, false)

	// Draft 2020-12: prefixItems + items + contains + minContains/maxContains + uniqueItems + unevaluatedItems
	c20 := compile_or_fail(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "array",
		"prefixItems": [{"type": "string"}],
		"contains": {"type": "integer", "minimum": 10},
		"minContains": 1,
		"maxContains": 2,
		"uniqueItems": true,
		"unevaluatedItems": {"type": "boolean"}
	}`)
	defer schema.destroy(c20)
	// In 2020-12, `contains` evaluates matching elements for `unevaluatedItems`!
	expect_json_valid(t, c20, `["head", 10, true]`, true)
	expect_json_valid(t, c20, `["head", 10, 20, false]`, true)
	expect_json_valid(t, c20, `["head", 10, 10]`, false) // not unique
	expect_json_valid(t, c20, `["head", 10, 20, 30]`, false) // maxContains = 2
	expect_json_valid(t, c20, `["head", 10, "stray"]`, false) // unevaluatedItems rejects string

	// Draft 2020-12: $dynamicAnchor + $dynamicRef across embedded $id resources
	c_dyn := compile_or_fail(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"$id": "https://example.com/outer",
		"$defs": {
			"overrideItem": {
				"$dynamicAnchor": "item",
				"type": "integer"
			},
			"list": {
				"$id": "https://example.com/list",
				"$defs": {
					"defaultItem": {
						"$dynamicAnchor": "item",
						"type": "string"
					}
				},
				"type": "array",
				"items": {"$dynamicRef": "#item"}
			}
		},
		"$ref": "https://example.com/list"
	}`)
	defer schema.destroy(c_dyn)
	// `outer` defines `$dynamicAnchor: "item"` as integer; list's `$dynamicRef: "#item"` resolves to outer's!
	expect_json_valid(t, c_dyn, `[1, 2, 3]`, true)
	expect_json_valid(t, c_dyn, `["a", "b"]`, false)
}

@(test)
format_agnostic_toml_and_cbor_schemas :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Write a JSON Schema in TOML and compile it directly via `schema.compile_document`!
	toml_schema := `
type = "object"
required = ["name", "port"]
additionalProperties = false

[properties.name]
type = "string"
minLength = 1

[properties.port]
type = "integer"
minimum = 1
maximum = 65535
`
	sdoc, serr := toml.build(transmute([]u8)toml_schema, .Toml_1_0)
	testing.expect(t, serr == nil)
	defer tape.destroy_document(&sdoc)

	c, cerr := schema.compile_document(&sdoc)
	defer schema.error_destroy(&cerr)
	testing.expect_value(t, cerr.kind, schema.Error_Kind.None)
	defer schema.destroy(c)

	expect_json_valid(t, c, `{"name": "api", "port": 8080}`, true)
	expect_json_valid(t, c, `{"name": "", "port": 8080}`, false)
	expect_json_valid(t, c, `{"name": "api", "port": 70000}`, false)

	// Validate a TOML instance against the same schema!
	t_inst, terr := toml.build(transmute([]u8)string("name = \"api\"\nport = 443\n"), .Toml_1_0)
	testing.expect(t, terr == nil)
	defer tape.destroy_document(&t_inst)
	testing.expect(t, schema.valid_document(c, &t_inst))

	// Encode a simple schema in CBOR (`{"type": "integer", "minimum": 5}`) and compile it!
	// CBOR map(2): "type" -> "integer", "minimum" -> 5
	cbor_schema := []u8{
		0xa2,
		0x64, 't', 'y', 'p', 'e',
		0x67, 'i', 'n', 't', 'e', 'g', 'e', 'r',
		0x67, 'm', 'i', 'n', 'i', 'm', 'u', 'm',
		0x05,
	}
	cdoc, cb_err := cbor.build(cbor_schema, .Cbor)
	testing.expect(t, cb_err == nil)
	defer tape.destroy_document(&cdoc)

	cc, cc_err := schema.compile_document(&cdoc)
	defer schema.error_destroy(&cc_err)
	testing.expect_value(t, cc_err.kind, schema.Error_Kind.None)
	defer schema.destroy(cc)

	expect_json_valid(t, cc, `5`, true)
	expect_json_valid(t, cc, `4`, false)
}

@(test)
write_schema_convert_report_and_pieces :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Convert a Draft 4 schema to normalized Draft 2020-12 JSON and verify roundtrip behavior!
	d4 := `{
		"$schema": "http://json-schema.org/draft-04/schema#",
		"definitions": {
			"item": {"type": "string", "minLength": 2}
		},
		"type": "array",
		"items": [{"$ref": "#/definitions/item"}],
		"additionalItems": {"type": "number", "minimum": 0, "exclusiveMinimum": true},
		"minItems": 1
	}`
	d4_doc, berr := json.build(transmute([]u8)d4, .Json)
	testing.expect(t, berr == nil)
	defer tape.destroy_document(&d4_doc)

	d20_bytes, werr := schema.convert_to_2020_12(&d4_doc, {}, {indent = 2})
	defer schema.error_destroy(&werr)
	testing.expect_value(t, werr.kind, schema.Error_Kind.None)
	defer delete(d20_bytes)

	d20_str := string(d20_bytes)
	testing.expect(t, strings.contains(d20_str, `"https://json-schema.org/draft/2020-12/schema"`))
	testing.expect(t, strings.contains(d20_str, `"prefixItems"`))
	testing.expect(t, strings.contains(d20_str, `"exclusiveMinimum"`))
	testing.expect(t, strings.contains(d20_str, `"$defs"`))

	c20 := compile_or_fail(t, d20_str)
	defer schema.destroy(c20)
	expect_json_valid(t, c20, `["ab", 0.5]`, true)
	expect_json_valid(t, c20, `["a", 0.5]`, false)
	expect_json_valid(t, c20, `["ab", 0]`, false)

	// Structured Basic Output report with embedded `$id` base
	rep_schema := `{
		"$id": "https://example.com/root.json",
		"type": "object",
		"properties": {
			"sub": {
				"$id": "https://example.com/sub.json",
				"type": "object",
				"properties": {"age": {"type": "integer", "minimum": 18}}
			}
		}
	}`
	cr := compile_or_fail(t, rep_schema)
	defer schema.destroy(cr)

	bad_doc, _ := json.build(transmute([]u8)string(`{"sub": {"age": 12}}`), .Json)
	defer tape.destroy_document(&bad_doc)
	sink: check.Sink
	check.sink_init(&sink)
	defer check.sink_destroy(&sink)
	res := schema.check_document(cr, &bad_doc, &sink)
	defer check.result_destroy(&res)
	testing.expect(t, !res.valid)
	testing.expect(t, len(sink.entries) == 1)

	rep_bytes, rerr := schema.write_basic_report(sink.entries[:], cr.description.uri, cr.description.bases[:], {file = "data.json"})
	defer schema.error_destroy(&rerr)
	testing.expect_value(t, rerr.kind, schema.Error_Kind.None)
	defer delete(rep_bytes)
	rep_str := string(rep_bytes)
	testing.expect(t, strings.contains(rep_str, `"valid":false`))
	testing.expect(t, strings.contains(rep_str, `"file":"data.json"`))
	testing.expect(t, strings.contains(rep_str, `"instanceLocation":"/sub/age"`))
	testing.expect(t, strings.contains(rep_str, `"absoluteKeywordLocation":"https://example.com/sub.json#/properties/age/minimum"`))

	// `elements_of` splits a root-array schema cleanly
	arr_c := compile_or_fail(t, `{"type": "array", "items": {"type": "integer", "minimum": 1}, "minItems": 2}`)
	defer schema.destroy(arr_c)
	elems := schema.elements_of(arr_c.description)
	testing.expect(t, elems != nil)
	if elems != nil {
		defer schema.elements_destroy(elems)
		testing.expect_value(t, elems.min_items, u64(2))
		testing.expect(t, elems.has_counts)
		item_ok := json.check(transmute([]u8)string(`5`), &elems.item_plan, .Json)
		defer check.result_destroy(&item_ok)
		testing.expect(t, item_ok.valid)
		item_bad := json.check(transmute([]u8)string(`0`), &elems.item_plan, .Json)
		defer check.result_destroy(&item_bad)
		testing.expect(t, !item_bad.valid)
	}

	// `check_written` with `rows = true`
	row_c := compile_or_fail(t, `{"type": "object", "required": ["id"]}`)
	defer schema.destroy(row_c)
	rows_doc, _ := json.build(transmute([]u8)string(`[{"id":1},{"id":2}]`), .Json)
	defer tape.destroy_document(&rows_doc)
	rr := schema.check_written(row_c, &rows_doc, true)
	defer check.result_destroy(&rr)
	testing.expect(t, rr.valid)
}

@(test)
draft2019_09_contains_conversion_json5_and_rows_edge_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// 1. Draft 2019-09 `contains` does NOT evaluate items for `unevaluatedItems: false`,
	//    and `convert_to_2020_12` preserves that exact semantics in Draft 2020-12!
	d19_src := `{
		"$schema": "https://json-schema.org/draft/2019-09/schema",
		"type": "array",
		"contains": {"type": "integer"},
		"unevaluatedItems": false
	}`
	c19 := compile_or_fail(t, d19_src)
	defer schema.destroy(c19)
	expect_json_valid(t, c19, `[1]`, false)

	d19_doc, _ := json.build(transmute([]u8)d19_src, .Json)
	defer tape.destroy_document(&d19_doc)
	conv, cerr := schema.convert_to_2020_12(&d19_doc)
	defer schema.error_destroy(&cerr)
	testing.expect_value(t, cerr.kind, schema.Error_Kind.None)
	defer delete(conv)
	c20 := compile_or_fail(t, string(conv))
	defer schema.destroy(c20)
	expect_json_valid(t, c20, `[1]`, false)

	// 2. Scientific integer counts (`minLength: 1.5e1` == 15)
	c_sci := compile_or_fail(t, `{"type": "string", "minLength": 1.5e1}`)
	defer schema.destroy(c_sci)
	expect_json_valid(t, c_sci, `"123456789012345"`, true)
	expect_json_valid(t, c_sci, `"12345678901234"`, false)

	// 3. Draft 2020-12 forbids empty `#` fragment in `$id`
	_, id_err := schema.compile_json(transmute([]u8)string(`{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://example.com/a#"}`))
	testing.expect_value(t, id_err.kind, schema.Error_Kind.Bad_Schema)
	schema.error_destroy(&id_err)

	// 4. JSON5 `.5` and `5.` `Node_Ref` literals normalize to strict RFC 8259 JSON in `write_schema`
	j5_doc, j5err := json.build(transmute([]u8)string(`{enum: [.5, 5.]}`), .Json5)
	testing.expect(t, j5err == nil)
	defer tape.destroy_document(&j5_doc)
	j5_out, j5werr := schema.convert_to_2020_12(&j5_doc)
	defer schema.error_destroy(&j5werr)
	testing.expect_value(t, j5werr.kind, schema.Error_Kind.None)
	defer delete(j5_out)
	// Output must parse as strict RFC 8259 JSON and validate `0.5` and `5`.
	c_j5 := compile_or_fail(t, string(j5_out))
	defer schema.destroy(c_j5)
	expect_json_valid(t, c_j5, `0.5`, true)
	expect_json_valid(t, c_j5, `5`, true)
	expect_json_valid(t, c_j5, `2`, false)

	// 5. `elements_of` refuses a root node that also carries object constraints (`n.object >= 0`)
	c_both := compile_or_fail(t, `{"type": ["array", "object"], "items": {"type": "integer"}, "properties": {"a": {"type": "string"}}}`)
	defer schema.destroy(c_both)
	testing.expect(t, schema.elements_of(c_both.description) == nil)

	// 6. `check_written(..., rows = true)` with failing rows + sink AND row with >= 8191 keys (child-count table!)
	row_c := compile_or_fail(t, `{"type": "object", "required": ["k0"]}`)
	defer schema.destroy(row_c)
	bad_rows, _ := json.build(transmute([]u8)string(`[{"k0":1},{"x":2},{"y":3}]`), .Json)
	defer tape.destroy_document(&bad_rows)
	rsink: check.Sink
	check.sink_init(&rsink)
	defer check.sink_destroy(&rsink)
	rfail := schema.check_written(row_c, &bad_rows, true, &rsink)
	defer check.result_destroy(&rfail)
	testing.expect(t, !rfail.valid)
	testing.expect_value(t, len(rsink.entries), 2)

	// Row with 8200 keys exercises `doc.counts` overflow without slicing `doc.nodes`!
	wide_b := strings.builder_make(0, 8200 * 10 + 16)
	defer strings.builder_destroy(&wide_b)
	strings.write_string(&wide_b, `[{`)
	for i in 0 ..< 8200 {
		if i > 0 {
			strings.write_byte(&wide_b, ',')
		}
		strings.write_string(&wide_b, `"k`)
		strings.write_int(&wide_b, i)
		strings.write_string(&wide_b, `":1`)
	}
	strings.write_string(&wide_b, `}]`)
	wide_doc, werr := json.build(transmute([]u8)strings.to_string(wide_b), .Json)
	testing.expect(t, werr == nil)
	defer tape.destroy_document(&wide_doc)
	wres := schema.check_written(row_c, &wide_doc, true)
	defer check.result_destroy(&wres)
	testing.expect(t, wres.valid)
}

@(test)
duplicate_key_policies_first_last_refuse :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dup_json := `{"a": "bad", "a": 42}`
	doc, berr := json.build(transmute([]u8)dup_json, .Json)
	testing.expect(t, berr == nil)
	defer tape.destroy_document(&doc)

	s := `{"type": "object", "properties": {"a": {"type": "integer"}}, "required": ["a"]}`
	c_last := compile_or_fail(t, s, {dups = .Last})
	defer schema.destroy(c_last)
	testing.expect(t, schema.valid_document(c_last, &doc))

	c_first := compile_or_fail(t, s, {dups = .First})
	defer schema.destroy(c_first)
	testing.expect(t, !schema.valid_document(c_first, &doc))

	c_refuse := compile_or_fail(t, s, {dups = .Refuse})
	defer schema.destroy(c_refuse)
	r_ref := json.check(transmute([]u8)dup_json, &c_refuse.plan, .Json, {dups = .Refuse})
	defer check.result_destroy(&r_ref)
	testing.expect(t, !r_ref.valid)
}
