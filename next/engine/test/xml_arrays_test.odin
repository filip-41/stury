package engine_tests

import "core:testing"
import "stury:dsv"
import "stury:engine"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"
import "stury:lib/schema/schema"
import "stury:testkit"
import "stury:xml"

@(private = "file")
compile_test_schema :: proc(t: ^testing.T, src: string, loc := #caller_location) -> ^schema.Compiled {
	sc, err := schema.compile_json(transmute([]u8)src)
	if err.kind != .None {
		testing.expectf(t, false, "schema compile failed: %s", err.message, loc = loc)
		schema.error_destroy(&err)
	}
	return sc
}

@(private = "file")
doc_to_json :: proc(t: ^testing.T, doc: ^tape.Document, loc := #caller_location) -> string {
	txt, _, err := json.write(doc, .Json)
	testing.expectf(t, err == nil, "json.write failed: %v", err, loc = loc)
	return string(txt)
}

@(test)
schema_expects_array_core_types_and_keywords :: proc(t: ^testing.T) {
	testkit.deadline(t)

	sc := compile_test_schema(t, `{
		"type": "object",
		"properties": {
			"root": {
				"type": "object",
				"properties": {
					"arr": { "type": "array", "items": { "type": "string" } },
					"nullable_arr": { "type": ["array", "null"], "items": { "type": "string" } },
					"items_only": { "items": { "type": "string" } },
					"prefix_only": { "prefixItems": [{ "type": "string" }] },
					"min_items": { "minItems": 1 },
					"max_items": { "maxItems": 5 },
					"unique_items": { "uniqueItems": true },
					"contains_only": { "contains": { "type": "string" } },
					"scalar": { "type": "string" },
					"obj": { "type": "object" },
					"any_schema": {},
					"false_schema": false
				}
			}
		}
	}`)
	defer schema.destroy(sc)
	d := sc.description

	testing.expect(t, !engine.schema_expects_array(d, {"root"}))
	testing.expect(t, engine.schema_expects_array(d, {"root", "arr"}))
	testing.expect(t, engine.schema_expects_array(d, {"root", "nullable_arr"}))
	testing.expect(t, engine.schema_expects_array(d, {"root", "items_only"}))
	testing.expect(t, engine.schema_expects_array(d, {"root", "prefix_only"}))
	testing.expect(t, engine.schema_expects_array(d, {"root", "min_items"}))
	testing.expect(t, engine.schema_expects_array(d, {"root", "max_items"}))
	testing.expect(t, engine.schema_expects_array(d, {"root", "unique_items"}))
	testing.expect(t, engine.schema_expects_array(d, {"root", "contains_only"}))
	testing.expect(t, !engine.schema_expects_array(d, {"root", "scalar"}))
	testing.expect(t, !engine.schema_expects_array(d, {"root", "obj"}))
	testing.expect(t, !engine.schema_expects_array(d, {"root", "any_schema"}))
	testing.expect(t, !engine.schema_expects_array(d, {"root", "false_schema"}))
	testing.expect(t, !engine.schema_expects_array(d, {"root", "unknown"}))
}

@(test)
schema_expects_array_nested_arrays_refs_combinators_and_patterns :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Nested arrays of objects (`root.orders[].order[]`), `$ref`, and recursive schema!
	{
		sc := compile_test_schema(t, `{
			"$defs": {
				"Order": {
					"type": "object",
					"properties": {
						"id": { "type": "string" },
						"line": { "type": "array", "items": { "type": "string" } }
					}
				},
				"Node": {
					"type": "object",
					"properties": {
						"name": { "type": "string" },
						"child": {
							"type": "array",
							"items": { "$ref": "#/$defs/Node" }
						}
					}
				}
			},
			"type": "object",
			"properties": {
				"root": {
					"type": "object",
					"properties": {
						"orders": {
							"type": "array",
							"items": {
								"type": "object",
								"properties": {
									"order": {
										"type": "array",
										"items": { "$ref": "#/$defs/Order" }
									}
								}
							}
						},
						"tree": { "$ref": "#/$defs/Node" }
					}
				}
			}
		}`)
		defer schema.destroy(sc)
		d := sc.description

		testing.expect(t, engine.schema_expects_array(d, {"root", "orders"}))
		testing.expect(t, engine.schema_expects_array(d, {"root", "orders", "order"}))
		testing.expect(t, !engine.schema_expects_array(d, {"root", "orders", "order", "id"}))
		testing.expect(t, engine.schema_expects_array(d, {"root", "orders", "order", "line"}))

		// Recursive `$ref`: arbitrarily deep `child` expects array, `name` stays scalar.
		testing.expect(t, !engine.schema_expects_array(d, {"root", "tree"}))
		testing.expect(t, engine.schema_expects_array(d, {"root", "tree", "child"}))
		testing.expect(t, !engine.schema_expects_array(d, {"root", "tree", "child", "name"}))
		testing.expect(t, engine.schema_expects_array(d, {"root", "tree", "child", "child"}))
		testing.expect(t, !engine.schema_expects_array(d, {"root", "tree", "child", "child", "name"}))

		// Direct synthetic `$ref` cycle terminates cleanly and returns `false`.
		cyc := rules.Description{root = 0, allocator = context.allocator}
		defer rules.description_destroy(&cyc)
		append(&cyc.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, ref = rules.Node_Index(0)})
		testing.expect(t, !engine.schema_expects_array(&cyc, {}))
		testing.expect(t, !engine.schema_expects_array(&cyc, {"root"}))
	}

	// 2. `allOf`, `anyOf`, `oneOf`, `additionalProperties`, `patternProperties`.
	{
		sc := compile_test_schema(t, `{
			"type": "object",
			"properties": {
				"root": {
					"type": "object",
					"allOf": [
						{
							"properties": {
								"via_allof": { "type": "array", "items": { "type": "string" } },
								"conflict": {
									"allOf": [
										{ "type": "string" },
										{ "minItems": 1 }
									]
								}
							}
						}
					],
					"properties": {
						"via_anyof": { "anyOf": [{ "type": "array" }, { "type": "null" }] },
						"via_oneof": { "oneOf": [{ "type": "array", "items": { "type": "string" } }, { "type": "object" }] },
						"plain": { "type": "string" }
					},
					"patternProperties": {
						"^list_": { "type": "array", "items": { "type": "string" } }
					},
					"additionalProperties": { "type": "array" }
				}
			}
		}`)
		defer schema.destroy(sc)
		d := sc.description

		testing.expect(t, engine.schema_expects_array(d, {"root", "via_allof"}))
		testing.expect(t, !engine.schema_expects_array(d, {"root", "conflict"}))
		testing.expect(t, engine.schema_expects_array(d, {"root", "via_anyof"}))
		testing.expect(t, engine.schema_expects_array(d, {"root", "via_oneof"}))
		testing.expect(t, !engine.schema_expects_array(d, {"root", "plain"}))
		testing.expect(t, engine.schema_expects_array(d, {"root", "list_items"}))
		testing.expect(t, engine.schema_expects_array(d, {"root", "extra_field"}))
	}
}

@(test)
apply_xml_arrays_end_to_end_modes_and_errors :: proc(t: ^testing.T) {
	testkit.deadline(t)

	sc := compile_test_schema(t, `{
		"type": "object",
		"properties": {
			"root": {
				"type": "object",
				"properties": {
					"title": { "type": "string" },
					"orders": {
						"type": "array",
						"items": {
							"type": "object",
							"properties": {
								"order": {
									"type": "array",
									"items": {
										"type": "object",
										"properties": {
											"id": { "type": "string" }
										}
									}
								}
							}
						}
					},
					"any_field": {}
				}
			}
		}
	}`)
	defer schema.destroy(sc)

	src := transmute([]u8)string(`<root><title>shop</title><orders><order><id>42</id></order></orders><any_field>keep</any_field><rep>1</rep><rep>2</rep></root>`)

	// `.Schema` wraps `orders` and `order`, keeps `title`, `id`, and catch-all `any_field` scalar, and collapses repeated `rep`.
	{
		doc, err := xml.build(src, .Xml)
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)

		testing.expect_value(t, engine.apply_xml_arrays(&doc, .Schema, sc.description), tape.Error(nil))
		j := doc_to_json(t, &doc)
		defer delete(j)
		testing.expect_value(t, j, `{"root":{"title":"shop","orders":[{"order":[{"id":"42"}]}],"any_field":"keep","rep":["1","2"]}}`)
	}

	// `.Schema` with `desc == nil` returns `Bad_Option{"schema"}`.
	{
		doc, err := xml.build(src, .Xml)
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)
		testing.expect_value(t, engine.apply_xml_arrays(&doc, .Schema, nil), tape.Error(tape.Bad_Option{"schema"}))
	}

	// `.Auto` is a no-op and `.Always` wraps all child elements.
	{
		doc, err := xml.build(transmute([]u8)string(`<root><a>1</a></root>`), .Xml)
		testing.expect_value(t, err, tape.Error(nil))
		defer xml.destroy(&doc)
		testing.expect_value(t, engine.apply_xml_arrays(&doc, .Auto), tape.Error(nil))
		j1 := doc_to_json(t, &doc)
		defer delete(j1)
		testing.expect_value(t, j1, `{"root":{"a":"1"}}`)

		testing.expect_value(t, engine.apply_xml_arrays(&doc, .Always), tape.Error(nil))
		j2 := doc_to_json(t, &doc)
		defer delete(j2)
		testing.expect_value(t, j2, `{"root":{"a":["1"]}}`)
	}

	// B1: `apply_xml_arrays` refuses partial `xml.scan` docs and non-XML (`json`/`dsv`) docs cleanly.
	{
		steps := [?]tape.Step{tape.Name("root"), tape.Name("title")}
		paths := [?][]tape.Step{steps[:]}
		dem, derr := tape.demand_of(paths[:])
		testing.expect_value(t, derr, nil)
		defer tape.destroy_demand(&dem)
		sdoc, serr := xml.scan(src, &dem, .Xml)
		testing.expect_value(t, serr, tape.Error(nil))
		defer xml.destroy(&sdoc)
		testing.expect_value(t, engine.apply_xml_arrays(&sdoc, .Always), tape.Error(tape.Bad_Option{"document"}))
		testing.expect_value(t, engine.apply_xml_arrays(&sdoc, .Schema, sc.description), tape.Error(tape.Bad_Option{"document"}))
	}
	{
		jdoc, jerr := json.build(transmute([]u8)string(`{"root":{"item":"a"}}`), .Json)
		testing.expect_value(t, jerr, tape.Error(nil))
		defer tape.destroy(&jdoc)
		testing.expect_value(t, engine.apply_xml_arrays(&jdoc, .Always), tape.Error(tape.Bad_Option{"format"}))
		testing.expect_value(t, engine.apply_xml_arrays(&jdoc, .Schema, sc.description), tape.Error(tape.Bad_Option{"format"}))
	}
	{
		cdoc, cerr := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv)
		testing.expect_value(t, cerr, tape.Error(nil))
		defer tape.destroy(&cdoc)
		testing.expect_value(t, engine.apply_xml_arrays(&cdoc, .Always), tape.Error(tape.Bad_Option{"format"}))
		testing.expect_value(t, engine.apply_xml_arrays(&cdoc, .Schema, sc.description), tape.Error(tape.Bad_Option{"format"}))
	}
}

@(test)
schema_expects_array_disjunctions_and_unevaluated_properties :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Repro 1: parent `oneOf` where arm 0 has `item: {type: "array"}, additionalProperties: false`
	// and arm 1 has `other: {type: "string"}, additionalProperties: false`.
	// Arm 1's `additionalProperties: false` must NOT poison arm 0's `item`!
	{
		sc := compile_test_schema(t, `{
			"type": "object",
			"properties": {
				"root": {
					"oneOf": [
						{
							"type": "object",
							"properties": { "item": { "type": "array", "items": { "type": "string" } } },
							"additionalProperties": false
						},
						{
							"type": "object",
							"properties": { "other": { "type": "string" } },
							"additionalProperties": false
						}
					]
				}
			}
		}`)
		defer schema.destroy(sc)
		d := sc.description

		testing.expect(t, engine.schema_expects_array(d, {"root", "item"}))
		testing.expect(t, !engine.schema_expects_array(d, {"root", "other"}))
		testing.expect(t, !engine.schema_expects_array(d, {"root", "unknown"}))
	}

	// Repro 2: root has `n.object == -1`, `allOf` defines `id`, and `unevaluatedProperties` expects array.
	{
		sc := compile_test_schema(t, `{
			"allOf": [
				{ "properties": { "id": { "type": "string" } } }
			],
			"unevaluatedProperties": { "type": "array" }
		}`)
		defer schema.destroy(sc)
		d := sc.description

		testing.expect(t, engine.schema_expects_array(d, {"anything"}))
		testing.expect(t, !engine.schema_expects_array(d, {"id"}))
	}

	// Repro 3: `properties` + `allOf` (`item: {type: "array"}`) + `unevaluatedProperties: false`.
	// Because `allOf` evaluates `item`, `unevaluatedProperties: false` must NOT suppress `item`!
	{
		sc := compile_test_schema(t, `{
			"type": "object",
			"properties": { "id": { "type": "string" } },
			"allOf": [
				{ "properties": { "item": { "type": "array" } } }
			],
			"unevaluatedProperties": false
		}`)
		defer schema.destroy(sc)
		d := sc.description

		testing.expect(t, engine.schema_expects_array(d, {"item"}))
		testing.expect(t, !engine.schema_expects_array(d, {"id"}))
		testing.expect(t, !engine.schema_expects_array(d, {"unknown"}))
	}
}
