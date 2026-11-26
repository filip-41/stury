// Comprehensive Wave B3 unit and regression tests for `stury:lib/schema/check`:
// 1. `$dynamicRef` members & OpenAPI `components`-style factored objects (`keys_site` + scope safety)
// 2. `dependentRequired` & Draft 4/7 array `dependencies` in factored objects
// 3. Factored held arrays (`Factor_Array`: `uniqueItems`, `contains`, `unevaluatedItems`, combinators, per-part counts)
// 4. Per-part `minProperties`/`maxProperties`/`minItems`/`maxItems` and `const`/`enum` on containers
// 5. Single-pass factored error parity, localized JSON replay, repeated-key branch accuracy (`decisions.md` #3), and budgets.
package check_test

import "core:slice"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/schema"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

@(private = "file")
expect_b3_json :: proc(t: ^testing.T, plan: ^check.Plan, input: string, want_valid: bool, opts := check.Options{}, check_doc := true, loc := #caller_location) {
	src := transmute([]u8)input

	r_verdict := json.check(src, plan, .Json, opts)
	defer check.result_destroy(&r_verdict)
	testing.expectf(t, r_verdict.valid == want_valid, "verdict mismatch on %s: got=%v err=%v want=%v", input, r_verdict.valid, r_verdict.err, want_valid, loc = loc)

	sink_stream: check.Sink
	check.sink_init(&sink_stream)
	defer check.sink_destroy(&sink_stream)
	r_sink := json.check(src, plan, .Json, opts, &sink_stream)
	defer check.result_destroy(&r_sink)
	testing.expectf(t, r_sink.valid == want_valid, "sink mismatch on %s: got=%v want=%v", input, r_sink.valid, want_valid, loc = loc)
	if want_valid {
		testing.expect_value(t, len(sink_stream.entries), 0, loc = loc)
	} else if r_sink.walk_err == nil && r_sink.err.kind != .Exceeded {
		testing.expectf(t, len(sink_stream.entries) > 0, "expected sink entries on invalid %s", input, loc = loc)
	}

	if check_doc && opts.dups != .Refuse && opts.budget == {} {
		bopts := tape.Options{dups = opts.dups}
		doc, berr := json.build(src, .Json, bopts)
		testing.expect_value(t, berr, nil, loc = loc)
		defer tape.destroy(&doc)

		r_doc := check.check_document(&doc, plan, opts)
		defer check.result_destroy(&r_doc)
		testing.expect_value(t, r_doc.valid, want_valid, loc = loc)

		sink_doc: check.Sink
		check.sink_init(&sink_doc)
		defer check.sink_destroy(&sink_doc)
		r_ds := check.check_document(&doc, plan, opts, &sink_doc)
		defer check.result_destroy(&r_ds)
		testing.expect_value(t, r_ds.valid, want_valid, loc = loc)
		expect_sink_entries_equal(t, sink_stream.entries[:], sink_doc.entries[:], input, loc = loc)
	}
}

@(private = "file")
expect_sink_entries_equal :: proc(t: ^testing.T, a, b: []check.Check_Error, label: string, compare_at := false, loc := #caller_location) {
	testing.expectf(t, len(a) == len(b), "%s: sink len mismatch stream=%d doc=%d", label, len(a), len(b), loc = loc)
	if len(a) != len(b) {
		return
	}
	for i in 0 ..< len(a) {
		ea, eb := a[i], b[i]
		testing.expectf(t, ea.kind == eb.kind && ea.keyword == eb.keyword && ea.expected == eb.expected && ea.instance_location == eb.instance_location && ea.keyword_location == eb.keyword_location,
			"%s[%d] mismatch:\n  a=%v kw=%q exp=%q inst=%q kwloc=%q at=%d\n  b=%v kw=%q exp=%q inst=%q kwloc=%q at=%d",
			label, i, ea.kind, ea.keyword, ea.expected, ea.instance_location, ea.keyword_location, ea.at,
			eb.kind, eb.keyword, eb.expected, eb.instance_location, eb.keyword_location, eb.at, loc = loc)
		if compare_at {
			testing.expectf(t, ea.at == eb.at, "%s[%d] byte offset mismatch: a=%d b=%d", label, i, ea.at, eb.at, loc = loc)
		}
	}
}

@(private = "file")
compile_b3_json :: proc(t: ^testing.T, schema_text: string, opts := schema.Options{}, loc := #caller_location) -> ^schema.Compiled {
	c, cerr := schema.compile_json(transmute([]u8)schema_text, opts)
	testing.expectf(t, cerr.kind == .None, "schema compile failed: %v", cerr, loc = loc)
	return c
}

// Clones a `check.Plan` with `.Factored` cleared from all records (rebasing `.first` pointers)
// so tests can directly assert 100% entry-by-entry parity between factored runs and unfactored runs.
@(private = "file")
clone_unfactored_plan :: proc(src: ^check.Plan, allocator := context.allocator) -> check.Plan {
	out := src^
	out.records = slice.clone(src.records, allocator)
	out.solo = slice.clone(src.solo, allocator)
	base := uintptr(raw_data(src.records))
	for &r in out.records {
		r.flags -= {.Factored}
		if r.first != nil {
			idx := int(uintptr(r.first) - base) / size_of(check.Record)
			r.first = &out.records[idx]
		}
	}
	for &s in out.solo {
		s.flags -= {.Factored}
		if s.first != nil {
			idx := int(uintptr(s.first) - base) / size_of(check.Record)
			s.first = &out.records[idx]
		}
	}
	if len(out.records) > 1 {
		out.root = &out.records[1]
	}
	return out
}

@(private = "file")
destroy_cloned_plan :: proc(p: ^check.Plan, allocator := context.allocator) {
	delete(p.records, allocator)
	delete(p.solo, allocator)
}

@(test)
wave_b3_dynamic_ref_and_components_test :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Recursive `$dynamicRef` inside sequential `.Expects` chain (`bar` -> `baz` -> `$dynamicRef: extended#meta`).
	// Verifies both verdict AND streaming vs doc entry parity (`instance_location = "/bar/baz/foo"`, NOT "/bar/foo").
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"$id": "https://example.test/dyn/root",
			"$dynamicAnchor": "meta",
			"type": "object",
			"properties": { "foo": { "const": "pass" } },
			"$ref": "extended",
			"$defs": {
				"extended": {
					"$id": "extended",
					"$dynamicAnchor": "meta",
					"type": "object",
					"properties": { "bar": { "$ref": "bar" } }
				},
				"bar": {
					"$id": "bar",
					"type": "object",
					"properties": { "baz": { "$dynamicRef": "extended#meta" } }
				}
			}
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		testing.expect(t, .Factored in c.plan.records[0].flags)

		expect_b3_json(t, &c.plan, `{"foo":"pass","bar":{"baz":{"foo":"pass"}}}`, true)
		expect_b3_json(t, &c.plan, `{"foo":"pass","bar":{"baz":{"foo":"fail"}}}`, false)

		sink: check.Sink
		check.sink_init(&sink)
		defer check.sink_destroy(&sink)
		r := json.check(transmute([]u8)string(`{"foo":"pass","bar":{"baz":{"foo":"fail"}}}`), &c.plan, .Json, {}, &sink)
		defer check.result_destroy(&r)
		testing.expect(t, !r.valid)
		testing.expect_value(t, len(sink.entries), 1)
		if len(sink.entries) == 1 {
			testing.expect_value(t, sink.entries[0].instance_location, "/bar/baz/foo")
			testing.expect_value(t, sink.entries[0].keyword_location, "/$ref/properties/bar/$ref/properties/baz/$dynamicRef/properties/foo/const")
		}
	}

	// 2. OpenAPI `components`-style patternProperties + `$dynamicRef` + merged `keys_site` (`patternProperties["^x-"]` + `propertyNames`).
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"$id": "https://example.test/openapi/root",
			"$dynamicAnchor": "ext",
			"type": "object",
			"$defs": {
				"specExt": {
					"patternProperties": {
						"^x-": { "type": "string" }
					}
				},
				"schemasContainer": {
					"type": "object",
					"additionalProperties": { "$dynamicRef": "#schema" }
				},
				"defaultSchema": {
					"$dynamicAnchor": "schema",
					"type": "object",
					"properties": {
						"type": { "enum": ["string", "integer", "object"] }
					}
				}
			},
			"properties": {
				"components": {
					"type": "object",
					"properties": {
						"schemas": {
							"allOf": [
								{ "$ref": "#/$defs/schemasContainer" },
								{
									"type": "object",
									"propertyNames": { "pattern": "^[A-Za-z_][A-Za-z0-9_]*$" }
								}
							]
						}
					},
					"$ref": "#/$defs/specExt",
					"unevaluatedProperties": false
				}
			}
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)

		// Compare factored plan against unfactored clone entry-for-entry.
		unfac := clone_unfactored_plan(&c.plan)
		defer destroy_cloned_plan(&unfac)

		expect_b3_json(t, &c.plan, `{"components":{"schemas":{"User":{"type":"object"}},"x-vendor":"ok"}}`, true)
		expect_b3_json(t, &c.plan, `{"components":{"schemas":{"Bad-Name":{"type":"object"}}}}`, false)
		expect_b3_json(t, &c.plan, `{"components":{"schemas":{"User":{"type":"bogus"}}}}`, false)
		expect_b3_json(t, &c.plan, `{"components":{"x-vendor":123}}`, false)
		expect_b3_json(t, &c.plan, `{"components":{"unknown":true}}`, false)

		bad := `{"components":{"schemas":{"1bad":{"type":"nope"}},"x-v":9,"extra":1}}`
		s_fac, s_unfac: check.Sink
		check.sink_init(&s_fac)
		check.sink_init(&s_unfac)
		defer check.sink_destroy(&s_fac)
		defer check.sink_destroy(&s_unfac)
		rf := json.check(transmute([]u8)bad, &c.plan, .Json, {}, &s_fac)
		ru := json.check(transmute([]u8)bad, &unfac, .Json, {}, &s_unfac)
		defer check.result_destroy(&rf)
		defer check.result_destroy(&ru)
		testing.expect(t, !rf.valid && !ru.valid)
		expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], "openapi components parity", compare_at = true)
	}

	// 3. Multi-choice `components`-style merged `keys_site` (`oneOf` arm with `propertyNames` inside factored member).
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"allOf": [
				{
					"properties": {
						"meta": {
							"type": "object",
							"properties": { "v": { "type": "integer" } }
						}
					}
				},
				{
					"properties": {
						"meta": {
							"type": "object",
							"propertyNames": { "pattern": "^[a-z]+$" }
						}
					}
				}
			]
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		unfac := clone_unfactored_plan(&c.plan)
		defer destroy_cloned_plan(&unfac)

		expect_b3_json(t, &c.plan, `{"meta":{"v":1,"ok":2}}`, true)
		bad := `{"meta":{"BAD":1,"v":"nope"}}`
		expect_b3_json(t, &c.plan, bad, false)

		s_fac, s_unfac: check.Sink
		check.sink_init(&s_fac)
		check.sink_init(&s_unfac)
		defer check.sink_destroy(&s_fac)
		defer check.sink_destroy(&s_unfac)
		rf := json.check(transmute([]u8)bad, &c.plan, .Json, {}, &s_fac)
		ru := json.check(transmute([]u8)bad, &unfac, .Json, {}, &s_unfac)
		defer check.result_destroy(&rf)
		defer check.result_destroy(&ru)
		expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], "multi-choice keys_site", compare_at = true)
	}

	// 4. Dynamic scope safety: outer `$dynamicAnchor` overrides inner `$dynamicAnchor` when entered via outer resource,
	// while referencing inner resource standalone preserves inner binding (`#/$defs/inner`).
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"$id": "https://example.test/dynscope/outer",
			"$dynamicAnchor": "node",
			"type": "object",
			"properties": { "tag": { "const": "outer" } },
			"allOf": [{ "$ref": "inner" }],
			"$defs": {
				"inner": {
					"$id": "inner",
					"$dynamicAnchor": "node",
					"type": "object",
					"properties": {
						"child": { "$dynamicRef": "#node" }
					}
				}
			}
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		testing.expect(t, .Factored in c.plan.records[0].flags)
		expect_b3_json(t, &c.plan, `{"tag":"outer","child":{"tag":"outer","child":{"tag":"outer"}}}`, true)
		expect_b3_json(t, &c.plan, `{"tag":"outer","child":{"tag":"wrong"}}`, false)
	}
}

@(test)
wave_b3_dependent_required_test :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. `dependentRequired` across `allOf` + `anyOf` + `oneOf` + quoted/special keys.
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"allOf": [
				{
					"properties": {
						"card": { "type": "string" },
						"billing": { "type": "string" },
						"cvv": { "type": "integer" }
					},
					"dependentRequired": {
						"card": ["billing", "cvv"]
					}
				},
				{
					"anyOf": [
						{
							"properties": { "a\"b": { "type": "integer" } },
							"dependentRequired": { "a\"b": ["c\nd"] }
						},
						{
							"properties": { "token": { "type": "string" } },
							"required": ["token"]
						}
					]
				}
			]
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		testing.expect(t, .Factored in c.plan.records[0].flags)
		unfac := clone_unfactored_plan(&c.plan)
		defer destroy_cloned_plan(&unfac)

		expect_b3_json(t, &c.plan, `{"card":"4111","billing":"1 St","cvv":123,"a\"b":1,"c\nd":2}`, true)
		expect_b3_json(t, &c.plan, `{"card":"4111","billing":"1 St","cvv":123,"a\"b":1,"token":"ok"}`, true)
		expect_b3_json(t, &c.plan, `{"card":"4111","billing":"1 St"}`, false)
		expect_b3_json(t, &c.plan, `{"a\"b":1}`, false)

		for bad in ([?]string{`{"card":"4111"}`, `{"a\"b":1}`}) {
			s_fac, s_unfac: check.Sink
			check.sink_init(&s_fac)
			check.sink_init(&s_unfac)
			rf := json.check(transmute([]u8)bad, &c.plan, .Json, {}, &s_fac)
			ru := json.check(transmute([]u8)bad, &unfac, .Json, {}, &s_unfac)
			expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], bad, compare_at = true)
			check.result_destroy(&rf)
			check.result_destroy(&ru)
			check.sink_destroy(&s_fac)
			check.sink_destroy(&s_unfac)
		}
	}

	// 2. Draft-07 array `dependencies` inside factored object preserves `"dependencies"` keyword name.
	{
		sch := `{
			"$schema": "http://json-schema.org/draft-07/schema#",
			"type": "object",
			"allOf": [
				{
					"properties": { "bar": { "type": "integer" } },
					"dependencies": { "bar": ["foo"] }
				},
				{
					"properties": { "foo": { "type": "integer" } }
				}
			]
		}`
		c := compile_b3_json(t, sch, {draft = .D07})
		defer schema.destroy(c)
		testing.expect(t, .Factored in c.plan.records[0].flags)
		unfac := clone_unfactored_plan(&c.plan)
		defer destroy_cloned_plan(&unfac)

		expect_b3_json(t, &c.plan, `{"foo":1,"bar":2}`, true)
		expect_b3_json(t, &c.plan, `{"foo":1}`, true)
		expect_b3_json(t, &c.plan, `{"bar":2}`, false)

		s_fac, s_unfac: check.Sink
		check.sink_init(&s_fac)
		check.sink_init(&s_unfac)
		defer check.sink_destroy(&s_fac)
		defer check.sink_destroy(&s_unfac)
		rf := json.check(transmute([]u8)string(`{"bar":2}`), &c.plan, .Json, {}, &s_fac)
		ru := json.check(transmute([]u8)string(`{"bar":2}`), &unfac, .Json, {}, &s_unfac)
		defer check.result_destroy(&rf)
		defer check.result_destroy(&ru)
		expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], "draft07 dependencies", compare_at = true)
		if len(s_fac.entries) == 1 {
			testing.expect_value(t, s_fac.entries[0].keyword, "dependencies")
			testing.expect_value(t, s_fac.entries[0].expected, "foo")
		}
	}
}

@(test)
wave_b3_factored_arrays_test :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. `applicator`'s `tags`-style held array: `uniqueItems`, `contains`, `minContains`, `maxContains`, `items`, `unevaluatedItems: false`.
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"properties": {
				"tags": {
					"type": "array",
					"uniqueItems": true,
					"prefixItems": [{ "type": "string" }],
					"contains": { "const": "urgent" },
					"minContains": 1,
					"maxContains": 1,
					"minItems": 2,
					"maxItems": 4,
					"unevaluatedItems": false
				}
			}
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		unfac := clone_unfactored_plan(&c.plan)
		defer destroy_cloned_plan(&unfac)

		// Verify `tags` member record has `.Factored` set!
		found_fac := false
		for &r in c.plan.records {
			if c.plan.meta[r.meta].name == "tags" && .Factored in r.flags {
				found_fac = true
			}
		}
		testing.expect(t, found_fac)

		expect_b3_json(t, &c.plan, `{"tags":["alpha","urgent"]}`, true)
		expect_b3_json(t, &c.plan, `{"tags":["urgent","beta"]}`, false) // index 1 `"beta"` unevaluated -> invalid
		expect_b3_json(t, &c.plan, `{"tags":["urgent","urgent"]}`, false) // duplicate + 2 urgent
		expect_b3_json(t, &c.plan, `{"tags":["urgent"]}`, false) // minItems 2
		expect_b3_json(t, &c.plan, `{"tags":["alpha","beta"]}`, false) // contains missing + idx 1 unevaluated

		for bad in ([?]string{`{"tags":["urgent","beta"]}`, `{"tags":["urgent","urgent"]}`, `{"tags":["urgent"]}`, `{"tags":["alpha","beta"]}`}) {
			s_fac, s_unfac: check.Sink
			check.sink_init(&s_fac)
			check.sink_init(&s_unfac)
			rf := json.check(transmute([]u8)bad, &c.plan, .Json, {}, &s_fac)
			ru := json.check(transmute([]u8)bad, &unfac, .Json, {}, &s_unfac)
			expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], bad, compare_at = true)
			check.result_destroy(&rf)
			check.result_destroy(&ru)
			check.sink_destroy(&s_fac)
			check.sink_destroy(&s_unfac)
		}
	}

	// 2. `uniqueItems` spill (>32 items), escapes, canonical numbers (`1` == `1.0` == `1e0`), containers, AND nested factored arrays.
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "array",
			"uniqueItems": true,
			"items": {
				"anyOf": [
					{ "type": "string" },
					{ "type": "number" },
					{ "type": "array", "uniqueItems": true }
				]
			}
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		testing.expect(t, .Factored in c.plan.records[0].flags)

		// Build a 40-element array (>32 inline string spill!) ending with an escaped duplicate `"\u006b0"`.
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		strings.write_byte(&sb, '[')
		for i in 0 ..< 40 {
			if i > 0 { strings.write_byte(&sb, ',') }
			strings.write_string(&sb, `"k`)
			strings.write_int(&sb, i)
			strings.write_byte(&sb, '"')
		}
		strings.write_byte(&sb, ']')
		expect_b3_json(t, &c.plan, strings.to_string(sb), true)

		strings.builder_reset(&sb)
		strings.write_byte(&sb, '[')
		for i in 0 ..< 39 {
			if i > 0 { strings.write_byte(&sb, ',') }
			strings.write_string(&sb, `"k`)
			strings.write_int(&sb, i)
			strings.write_byte(&sb, '"')
		}
		strings.write_string(&sb, `,"\u006b0"]`)
		expect_b3_json(t, &c.plan, strings.to_string(sb), false)

		// Canonical number equality + nested unique array conflict (`[1, 2]` vs `[1.0, 2]`).
		expect_b3_json(t, &c.plan, `[1, 2, "1"]`, true)
		expect_b3_json(t, &c.plan, `[1, 1.0]`, false)
		expect_b3_json(t, &c.plan, `[[1, 2], [2, 1]]`, true)
		expect_b3_json(t, &c.plan, `[[1, 1.0]]`, false) // inner array fails uniqueItems
		expect_b3_json(t, &c.plan, `[[1, 2], [1.0, 2]]`, false) // outer array fails uniqueItems on containers
	}

	// 3. Array `anyOf`/`oneOf`/`not`/`if` + `minItems`/`maxItems` + `const`/`enum` + contradictory `minContains`/`maxContains`.
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"oneOf": [
				{ "type": "array", "const": [1, 2] },
				{ "type": "array", "minItems": 3, "maxItems": 4, "items": { "type": "string" } },
				{ "type": "array", "enum": [[true, false], ["x"]] }
			]
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		unfac := clone_unfactored_plan(&c.plan)
		defer destroy_cloned_plan(&unfac)

		expect_b3_json(t, &c.plan, `[1, 2]`, true)
		expect_b3_json(t, &c.plan, `["a", "b", "c"]`, true)
		expect_b3_json(t, &c.plan, `[true, false]`, true)
		expect_b3_json(t, &c.plan, `[1, 3]`, false)
		expect_b3_json(t, &c.plan, `["a", "b"]`, false)
		expect_b3_json(t, &c.plan, `["a", "b", 3]`, false)

		for bad in ([?]string{`[1, 3]`, `["a", "b"]`, `["a", "b", 3]`}) {
			s_fac, s_unfac: check.Sink
			check.sink_init(&s_fac)
			check.sink_init(&s_unfac)
			rf := json.check(transmute([]u8)bad, &c.plan, .Json, {}, &s_fac)
			ru := json.check(transmute([]u8)bad, &unfac, .Json, {}, &s_unfac)
			expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], bad, compare_at = true)
			check.result_destroy(&rf)
			check.result_destroy(&ru)
			check.sink_destroy(&s_fac)
			check.sink_destroy(&s_unfac)
		}
	}

	// 4. Multi-format (TOML + XML `.Group`) array parity.
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"properties": {
				"v": {
					"type": "array",
					"uniqueItems": true,
					"contains": { "const": "ok" },
					"items": { "type": "string" }
				}
			},
			"required": ["v"]
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)

		rt_ok := toml.check(transmute([]u8)string("v = [\"ok\", \"extra\"]\n"), &c.plan, .Toml_1_0)
		defer check.result_destroy(&rt_ok)
		testing.expect(t, rt_ok.valid)

		rt_bad := toml.check(transmute([]u8)string("v = [\"ok\", \"ok\"]\n"), &c.plan, .Toml_1_0)
		defer check.result_destroy(&rt_bad)
		testing.expect(t, !rt_bad.valid)

		xml_sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"properties": {
				"r": {
					"type": "object",
					"properties": {
						"v": {
							"type": "array",
							"uniqueItems": true,
							"contains": { "const": "ok" },
							"items": { "type": "string" }
						}
					},
					"required": ["v"]
				}
			},
			"required": ["r"]
		}`
		cx := compile_b3_json(t, xml_sch)
		defer schema.destroy(cx)

		rx_one := xml.check(transmute([]u8)string(`<r><v>ok</v></r>`), &cx.plan, .Xml)
		defer check.result_destroy(&rx_one)
		testing.expect(t, rx_one.valid)

		rx_ok := xml.check(transmute([]u8)string(`<r><v>ok</v><v>extra</v></r>`), &cx.plan, .Xml)
		defer check.result_destroy(&rx_ok)
		testing.expect(t, rx_ok.valid)

		rx_bad := xml.check(transmute([]u8)string(`<r><v>ok</v><v>ok</v></r>`), &cx.plan, .Xml)
		defer check.result_destroy(&rx_bad)
		testing.expect(t, !rx_bad.valid)
	}
}

@(test)
wave_b3_part_counts_and_const_enum_test :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Per-part `minProperties` / `maxProperties`, container `const` / `enum`, and single-candidate `enum` keyword fidelity.
	sch := `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"maxProperties": 4,
		"allOf": [
			{
				"anyOf": [
					{ "type": "object", "const": { "kind": "empty" } },
					{ "type": "object", "enum": [{ "kind": "single" }] },
					{
						"type": "object",
						"minProperties": 2,
						"maxProperties": 3,
						"properties": {
							"kind": { "const": "pair" },
							"v": { "type": "integer" }
						},
						"required": ["kind", "v"]
					}
				]
			}
		]
	}`
	c := compile_b3_json(t, sch)
	defer schema.destroy(c)
	testing.expect(t, .Factored in c.plan.records[0].flags)
	unfac := clone_unfactored_plan(&c.plan)
	defer destroy_cloned_plan(&unfac)

	expect_b3_json(t, &c.plan, `{"kind":"empty"}`, true)
	expect_b3_json(t, &c.plan, `{"kind":"single"}`, true)
	expect_b3_json(t, &c.plan, `{"kind":"pair","v":7}`, true)
	expect_b3_json(t, &c.plan, `{"kind":"pair","v":7,"extra":1}`, true)
	expect_b3_json(t, &c.plan, `{"kind":"pair","v":7,"e1":1,"e2":2}`, false) // inner maxProperties 3 fails (outer maxProperties 4 passes!)
	expect_b3_json(t, &c.plan, `{"kind":"pair","v":7,"e1":1,"e2":2,"e3":3}`, false) // outer maxProperties 4 + inner maxProperties 3 fail
	expect_b3_json(t, &c.plan, `{}`, false) // all 3 branches fail

	for bad in ([?]string{`{"kind":"pair","v":7,"e1":1,"e2":2}`, `{"kind":"pair","v":7,"e1":1,"e2":2,"e3":3}`, `{}`}) {
		s_fac, s_unfac: check.Sink
		check.sink_init(&s_fac)
		check.sink_init(&s_unfac)
		rf := json.check(transmute([]u8)bad, &c.plan, .Json, {}, &s_fac)
		ru := json.check(transmute([]u8)bad, &unfac, .Json, {}, &s_unfac)
		expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], bad, compare_at = true)
		check.result_destroy(&rf)
		check.result_destroy(&ru)
		check.sink_destroy(&s_fac)
		check.sink_destroy(&s_unfac)
	}

	// Direct-error conjunctive `allOf` (non-conjoined via `patternProperties`) + per-part `minProperties` / `maxProperties`:
	// verifies verdict vs sink `rv.err == rs.err` parity including exact `keyword_location`!
	{
		dir_sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"allOf": [
				{ "minProperties": 2, "properties": { "a": { "type": "integer" } }, "patternProperties": { "^x_": { "type": "integer" } } },
				{ "maxProperties": 3, "properties": { "b": { "type": "string" } } }
			]
		}`
		cd := compile_b3_json(t, dir_sch)
		defer schema.destroy(cd)
		testing.expect(t, .Factored in cd.plan.records[0].flags)
		testing.expect_value(t, cd.plan.uses[0].verdict_rec, i32(0))

		for bad in ([?]string{`{"a":1}`, `{"a":1,"b":"ok","c":2,"d":3}`, `{"a":"nope","b":"ok"}`, `{"a":1,"x_1":"bad"}`}) {
			rv := json.check(transmute([]u8)bad, &cd.plan, .Json)
			defer check.result_destroy(&rv)
			s: check.Sink
			check.sink_init(&s)
			defer check.sink_destroy(&s)
			rs := json.check(transmute([]u8)bad, &cd.plan, .Json, {}, &s)
			defer check.result_destroy(&rs)
			testing.expect(t, !rv.valid && !rs.valid && len(s.entries) > 0)
			if len(s.entries) > 0 {
				testing.expect_value(t, rv.err.kind, rs.err.kind)
				testing.expect_value(t, rv.err.keyword, rs.err.keyword)
				testing.expect_value(t, rv.err.instance_location, rs.err.instance_location)
				testing.expect_value(t, rv.err.keyword_location, rs.err.keyword_location)
			}
		}
	}
}

@(test)
wave_b3_single_pass_errors_and_repeated_keys_test :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Single-pass direct error emission + localized JSON replay on an object with prefix & suffix siblings:
	// preserves exact file byte offsets (`at`), instance locations, keyword locations, and continues validating siblings!
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"properties": {
				"ok_head": { "type": "integer" },
				"spec_obj": {
					"type": "object",
					"oneOf": [
						{ "properties": { "a": { "type": "integer" } }, "required": ["a"] },
						{ "properties": { "b": { "type": "integer" } }, "required": ["b"] }
					]
				},
				"conj_obj": {
					"type": "object",
					"allOf": [
						{ "properties": { "x": { "type": "integer" } }, "required": ["x"] },
						{ "properties": { "y": { "type": "string" } } }
					],
					"unevaluatedProperties": false
				},
				"tail": { "type": "integer" }
			}
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		unfac := clone_unfactored_plan(&c.plan)
		defer destroy_cloned_plan(&unfac)

		input := `{"ok_head":"bad_head","spec_obj":{"a":"nope"},"conj_obj":{"y":99,"z":true},"tail":"bad_tail"}`
		expect_b3_json(t, &c.plan, input, false)

		s_fac, s_unfac: check.Sink
		check.sink_init(&s_fac)
		check.sink_init(&s_unfac)
		defer check.sink_destroy(&s_fac)
		defer check.sink_destroy(&s_unfac)
		rf := json.check(transmute([]u8)input, &c.plan, .Json, {}, &s_fac)
		ru := json.check(transmute([]u8)input, &unfac, .Json, {}, &s_unfac)
		defer check.result_destroy(&rf)
		defer check.result_destroy(&ru)
		expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], "prefix/suffix offset & continuation", compare_at = true)
	}

	// 2. `decisions.md` #3: repeated keys inside a shared subschema (`then/if/$ref` & `then/else/$ref`).
	// Verifies `.First`, `.Last`, `.Refuse`, escaped keys, and factored vs unfactored exact branch path match!
	{
		sch2 := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"$defs": {
				"shared": {
					"type": "object",
					"properties": {
						"val": { "type": "integer" }
					},
					"required": ["val"]
				}
			},
			"type": "object",
			"properties": { "go": { "type": "boolean" } },
			"if": { "properties": { "go": { "const": true } }, "required": ["go"] },
			"then": {
				"if": { "properties": { "mode": { "const": 1 } }, "required": ["mode"] },
				"then": { "$ref": "#/$defs/shared" },
				"else": { "$ref": "#/$defs/shared" }
			},
			"else": { "$ref": "#/$defs/shared" }
		}`
		c := compile_b3_json(t, sch2)
		defer schema.destroy(c)
		testing.expect(t, .Factored in c.plan.records[0].flags)
		unfac := clone_unfactored_plan(&c.plan)
		defer destroy_cloned_plan(&unfac)

		dup_mode_1_then_2 := `{"go":true,"mode":1,"mo\u0064e":2,"val":"bad"}`
		dup_mode_2_then_1 := `{"go":true,"mo\u0064e":2,"mode":1,"val":"bad"}`
		dup_go := `{"go":false,"go":true,"mode":1,"val":"bad"}`

		// Under `.First`: `"mode": 1` wins -> `/then/then/$ref/properties/val/type`.
		{
			s1, s2: check.Sink
			check.sink_init(&s1)
			check.sink_init(&s2)
			defer check.sink_destroy(&s1)
			defer check.sink_destroy(&s2)
			r1 := json.check(transmute([]u8)dup_mode_1_then_2, &c.plan, .Json, {dups = .First}, &s1)
			r2 := json.check(transmute([]u8)dup_mode_1_then_2, &unfac, .Json, {dups = .First}, &s2)
			defer check.result_destroy(&r1)
			defer check.result_destroy(&r2)
			testing.expect(t, !r1.valid && len(s1.entries) == 1)
			if len(s1.entries) == 1 {
				testing.expect_value(t, s1.entries[0].keyword_location, "/then/then/$ref/properties/val/type")
			}
			expect_sink_entries_equal(t, s1.entries[:], s2.entries[:], "dup First -> then/then", compare_at = true)
		}

		// Under `.Last`: `"mode": 1` wins on `dup_mode_2_then_1` -> `/then/then/$ref/properties/val/type`;
		// `"go": true` wins on `dup_go` -> `/then/then/$ref/properties/val/type`.
		{
			s1, s2: check.Sink
			check.sink_init(&s1)
			check.sink_init(&s2)
			defer check.sink_destroy(&s1)
			defer check.sink_destroy(&s2)
			r1 := json.check(transmute([]u8)dup_mode_2_then_1, &c.plan, .Json, {dups = .Last}, &s1)
			r2 := json.check(transmute([]u8)dup_mode_2_then_1, &unfac, .Json, {dups = .Last}, &s2)
			defer check.result_destroy(&r1)
			defer check.result_destroy(&r2)
			testing.expect(t, !r1.valid && len(s1.entries) == 1)
			if len(s1.entries) == 1 {
				testing.expect_value(t, s1.entries[0].keyword_location, "/then/then/$ref/properties/val/type")
			}
			expect_sink_entries_equal(t, s1.entries[:], s2.entries[:], "dup Last -> then/then", compare_at = true)

			check.sink_clear(&s1)
			check.sink_clear(&s2)
			r3 := json.check(transmute([]u8)dup_go, &c.plan, .Json, {dups = .First}, &s1)
			r4 := json.check(transmute([]u8)dup_go, &unfac, .Json, {dups = .First}, &s2)
			defer check.result_destroy(&r3)
			defer check.result_destroy(&r4)
			testing.expect(t, !r3.valid && len(s1.entries) == 1)
			if len(s1.entries) == 1 {
				testing.expect_value(t, s1.entries[0].keyword_location, "/else/$ref/properties/val/type")
			}
			expect_sink_entries_equal(t, s1.entries[:], s2.entries[:], "dup First -> else", compare_at = true)
		}

		// Under `.Refuse`: duplicate key refuses with `.Duplicate_Key`.
		expect_b3_json(t, &c.plan, dup_mode_1_then_2, false, opts = {dups = .Refuse}, check_doc = false)
		expect_b3_json(t, &c.plan, dup_go, false, opts = {dups = .Refuse}, check_doc = false)
	}

	// 3. Lone-`if` annotation regression (`collect_evaluates` stack overflow fix) + `Budget` guards.
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"if": { "properties": { "foo": true } },
			"unevaluatedProperties": false
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		expect_b3_json(t, &c.plan, `{"foo":1}`, true)
		expect_b3_json(t, &c.plan, `{"bar":1}`, false)
	}

	// 4. `dsv` and `cbor` parity on factored array (`uniqueItems` + `items`).
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "array",
			"uniqueItems": true,
			"minItems": 2,
			"items": {
				"type": "object",
				"properties": { "k": { "type": "string" } },
				"required": ["k"]
			}
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		// CBOR: `[{"k":"a"},{"k":"b"}]` vs duplicate `[{"k":"a"},{"k":"a"}]`
		j_ok, _ := json.build(transmute([]u8)string(`[{"k":"a"},{"k":"b"}]`))
		defer tape.destroy(&j_ok)
		cbor_ok, _, _ := cbor.write(&j_ok, .Cbor)
		defer delete(cbor_ok)
		rc_ok := cbor.check(cbor_ok, &c.plan, .Cbor)
		defer check.result_destroy(&rc_ok)
		testing.expect(t, rc_ok.valid)

		j_dup, _ := json.build(transmute([]u8)string(`[{"k":"a"},{"k":"a"}]`))
		defer tape.destroy(&j_dup)
		cbor_dup, _, _ := cbor.write(&j_dup, .Cbor)
		defer delete(cbor_dup)
		rc_dup := cbor.check(cbor_dup, &c.plan, .Cbor)
		defer check.result_destroy(&rc_dup)
		testing.expect(t, !rc_dup.valid)

		// DSV CSV table check with factored array items (`no_header` array mode or header object mode).
		csv_ok := dsv.check(transmute([]u8)string("k\na\nb\n"), &c.plan, .Csv)
		defer check.result_destroy(&csv_ok)
		testing.expect(t, csv_ok.valid)
		csv_dup := dsv.check(transmute([]u8)string("k\na\na\n"), &c.plan, .Csv)
		defer check.result_destroy(&csv_dup)
		testing.expect(t, !csv_dup.valid)
	}

	// 5. Tight `Budget` (`memory`, `steps`, `nodes`, `depth`) cleanly returns `.Exceeded` in replay & factored arrays without leaks.
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"oneOf": [
				{ "properties": { "a": { "type": "integer" } }, "required": ["a"] },
				{ "properties": { "b": { "type": "integer" } }, "required": ["b"] }
			]
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		sink: check.Sink
		check.sink_init(&sink)
		defer check.sink_destroy(&sink)

		r_nodes := json.check(transmute([]u8)string(`{"a":"bad"}`), &c.plan, .Json, {budget = {nodes = 1}}, &sink)
		defer check.result_destroy(&r_nodes)
		testing.expect(t, !r_nodes.valid)
		testing.expect_value(t, r_nodes.err.kind, check.Error_Kind.Exceeded)

		// Tiny memory budget on invalid replay returns `.Exceeded`, never hangs or panics!
		check.sink_clear(&sink)
		r_mem := json.check(transmute([]u8)string(`{"a":"bad"}`), &c.plan, .Json, {budget = {memory = 64}}, &sink)
		defer check.result_destroy(&r_mem)
		testing.expect(t, !r_mem.valid)
		testing.expect_value(t, r_mem.err.kind, check.Error_Kind.Exceeded)
	}

	// 6. Zero whole-file reread proof: a 24 KiB skipped prefix sibling + invalid factored sub-object passes under `budget.memory = 4096`
	// in BOTH Tier 1 (`direct_errors` single-pass) AND Tier 2 (`oneOf` localized byte-slice replay) without building a 24 KiB Document!
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"properties": {
				"conj": {
					"type": "object",
					"allOf": [
						{ "properties": { "n": { "type": "integer" } }, "required": ["n"] },
						{ "properties": { "s": { "type": "string" } } }
					]
				},
				"disj": {
					"type": "object",
					"oneOf": [
						{ "properties": { "a": { "type": "integer" } }, "required": ["a"] },
						{ "properties": { "b": { "type": "integer" } }, "required": ["b"] }
					]
				}
			}
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)

		big_prefix := strings.builder_make()
		defer strings.builder_destroy(&big_prefix)
		strings.write_string(&big_prefix, `{"unused_huge":[`)
		for i in 0 ..< 2500 {
			if i > 0 { strings.write_byte(&big_prefix, ',') }
			strings.write_int(&big_prefix, i)
		}
		strings.write_string(&big_prefix, `],"conj":{"n":"bad","s":123},"disj":{"a":"bad"}}`)

		sink: check.Sink
		check.sink_init(&sink)
		defer check.sink_destroy(&sink)
		r := json.check(transmute([]u8)strings.to_string(big_prefix), &c.plan, .Json, {budget = {memory = 4096}}, &sink)
		defer check.result_destroy(&r)
		testing.expect(t, !r.valid)
		testing.expect(t, r.err.kind != .Exceeded)
		testing.expect_value(t, len(sink.entries), 5)
	}
}

@(test)
wave_b3_neon_regressions_test :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// B1: Empty-string key `""` in Tier 1 `unevaluatedProperties: false`, nested `""` property paths, and `in_seq`.
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"allOf": [{ "properties": { "a": { "type": "integer" } } }],
			"unevaluatedProperties": false
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		testing.expect(t, .Factored in c.plan.records[0].flags)
		unfac := clone_unfactored_plan(&c.plan)
		defer destroy_cloned_plan(&unfac)

		expect_b3_json(t, &c.plan, `{"": 1}`, false)
		expect_b3_json(t, &c.plan, `{"a": 1, "": {"nested": true}}`, false)

		for bad in ([?]string{`{"": 1}`, `{"a": 1, "": {"nested": true}}`}) {
			s_fac, s_unfac: check.Sink
			check.sink_init(&s_fac)
			check.sink_init(&s_unfac)
			rf := json.check(transmute([]u8)bad, &c.plan, .Json, {}, &s_fac)
			ru := json.check(transmute([]u8)bad, &unfac, .Json, {}, &s_unfac)
			expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], bad, compare_at = true)
			testing.expect_value(t, len(s_fac.entries), 1)
			if len(s_fac.entries) == 1 {
				testing.expect_value(t, s_fac.entries[0].instance_location, "/")
			}
			check.result_destroy(&rf)
			check.result_destroy(&ru)
			check.sink_destroy(&s_fac)
			check.sink_destroy(&s_unfac)
		}

		// Nested empty-string property key `{"": {"nested": "bad"}}` preserves `"//nested"` JSON Pointer cleanly!
		sch_empty_prop := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"properties": {
				"": {
					"type": "object",
					"properties": { "nested": { "type": "integer" } }
				}
			}
		}`
		ce := compile_b3_json(t, sch_empty_prop)
		defer schema.destroy(ce)
		expect_b3_json(t, &ce.plan, `{"":{"nested":"bad"}}`, false)
		r_emp := json.check(transmute([]u8)string(`{"":{"nested":"bad"}}`), &ce.plan, .Json)
		defer check.result_destroy(&r_emp)
		testing.expect_value(t, r_emp.err.instance_location, "//nested")
	}

	// B2: Do NOT merge `propertyNames` onto non-object / constrained value schemas (`can_merge` guard).
	{
		for sch in ([?]string{
			`{"type": "object", "properties": {"a": {"type": "array"}}, "patternProperties": {"^a$": {"propertyNames": {"pattern": "^[a-z]+$"}}}}`,
			`{"type": "object", "properties": {"a": {"type": "array", "items": {"type": "integer"}}}, "patternProperties": {"^a$": {"propertyNames": {"pattern": "^[a-z]+$"}}}}`,
			`{"type": "object", "properties": {"a": {"const": {"BAD": 1}}}, "patternProperties": {"^a$": {"propertyNames": {"pattern": "^[a-z]+$"}}}}`,
		}) {
			c := compile_b3_json(t, sch)
			defer schema.destroy(c)
			unfac := clone_unfactored_plan(&c.plan)
			defer destroy_cloned_plan(&unfac)

			bad := `{"a": {"BAD": 1}}`
			expect_b3_json(t, &c.plan, bad, false)

			s_fac, s_unfac: check.Sink
			check.sink_init(&s_fac)
			check.sink_init(&s_unfac)
			rf := json.check(transmute([]u8)bad, &c.plan, .Json, {}, &s_fac)
			ru := json.check(transmute([]u8)bad, &unfac, .Json, {}, &s_unfac)
			expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], sch, compare_at = true)
			check.result_destroy(&rf)
			check.result_destroy(&ru)
			check.sink_destroy(&s_fac)
			check.sink_destroy(&s_unfac)
		}

		// Explicitly check both `type` at `/a` and `propertyNames` at `/a/BAD` are emitted when both fail!
		c_both := compile_b3_json(t, `{"type": "object", "properties": {"a": {"type": "array", "items": {"type": "integer"}}}, "patternProperties": {"^a$": {"propertyNames": {"pattern": "^[a-z]+$"}}}}`)
		defer schema.destroy(c_both)
		s_both: check.Sink
		check.sink_init(&s_both)
		defer check.sink_destroy(&s_both)
		r_both := json.check(transmute([]u8)string(`{"a":{"BAD":1}}`), &c_both.plan, .Json, {}, &s_both)
		defer check.result_destroy(&r_both)
		testing.expect(t, !r_both.valid)
		saw_type, saw_pn := false, false
		for &e in s_both.entries {
			if e.instance_location == "/a" && e.keyword == "type" {
				saw_type = true
			}
			if e.instance_location == "/a/BAD" && strings.contains(e.keyword_location, "propertyNames") {
				saw_pn = true
			}
		}
		testing.expect(t, saw_type && saw_pn)
	}

	// B3: `finish_choice_leaf_counts` counts unnamed keys (stream + doc, with & without Sink, plus repeated unnamed keys under `.Last`).
	{
		sch_min := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"allOf": [
				{ "properties": { "obj": { "minProperties": 2 } } },
				{ "properties": { "obj": { "type": "object", "properties": { "x": { "type": "integer" } } } } }
			]
		}`
		c_min := compile_b3_json(t, sch_min)
		defer schema.destroy(c_min)
		testing.expect(t, .Factored in c_min.plan.records[0].flags)
		unfac_min := clone_unfactored_plan(&c_min.plan)
		defer destroy_cloned_plan(&unfac_min)

		expect_b3_json(t, &c_min.plan, `{"obj": {"a": 1, "b": 2}}`, true)
		expect_b3_json(t, &c_min.plan, `{"obj": {"a": 1}}`, false)
		// Repeated unnamed key `"a"` collapses to 1 member under JSON `.Last`, failing `minProperties: 2`!
		expect_b3_json(t, &c_min.plan, `{"obj": {"a": 1, "a": 2}}`, false, opts = {dups = .Last})

		for bad in ([?]string{`{"obj": {"a": 1}}`, `{"obj": {"a": 1, "a": 2}}`}) {
			s_fac, s_unfac: check.Sink
			check.sink_init(&s_fac)
			check.sink_init(&s_unfac)
			rf := json.check(transmute([]u8)bad, &c_min.plan, .Json, {dups = .Last}, &s_fac)
			ru := json.check(transmute([]u8)bad, &unfac_min, .Json, {dups = .Last}, &s_unfac)
			expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], bad, compare_at = true)
			check.result_destroy(&rf)
			check.result_destroy(&ru)
			check.sink_destroy(&s_fac)
			check.sink_destroy(&s_unfac)
		}

		sch_max := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"allOf": [
				{ "properties": { "obj": { "maxProperties": 1 } } },
				{ "properties": { "obj": { "type": "object", "properties": { "x": { "type": "integer" } } } } }
			]
		}`
		c_max := compile_b3_json(t, sch_max)
		defer schema.destroy(c_max)
		unfac_max := clone_unfactored_plan(&c_max.plan)
		defer destroy_cloned_plan(&unfac_max)

		expect_b3_json(t, &c_max.plan, `{"obj": {"a": 1}}`, true)
		expect_b3_json(t, &c_max.plan, `{"obj": {"a": 1, "b": 2}}`, false)

		rv_max := json.check(transmute([]u8)string(`{"obj": {"a": 1, "b": 2}}`), &c_max.plan, .Json)
		defer check.result_destroy(&rv_max)
		testing.expect(t, !rv_max.valid)
		testing.expect_value(t, rv_max.err.kind, check.Error_Kind.Too_Many)
		testing.expect_value(t, rv_max.err.instance_location, "/obj")

		s_fac, s_unfac: check.Sink
		check.sink_init(&s_fac)
		check.sink_init(&s_unfac)
		defer check.sink_destroy(&s_fac)
		defer check.sink_destroy(&s_unfac)
		rf := json.check(transmute([]u8)string(`{"obj": {"a": 1, "b": 2}}`), &c_max.plan, .Json, {}, &s_fac)
		ru := json.check(transmute([]u8)string(`{"obj": {"a": 1, "b": 2}}`), &unfac_max, .Json, {}, &s_unfac)
		defer check.result_destroy(&rf)
		defer check.result_destroy(&ru)
		expect_sink_entries_equal(t, s_fac.entries[:], s_unfac.entries[:], "maxProperties choice_rec", compare_at = true)
	}

	// B4: Document-backed `on_end_cold` preserves redirected `inst_owner` (`replay_doc_factored`), matching streaming verdict!
	{
		// Case 1: Redirected conjoinable `obj_arm` schema from review report (`sink = nil` in both doc and streaming modes).
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"properties": {
				"head": { "type": "integer" },
				"x": {
					"oneOf": [
						{
							"type": "object",
							"allOf": [
								{
									"properties": {
										"a": {
											"type": "object",
											"allOf": [{ "required": ["b"] }]
										}
									}
								}
							]
						},
						{ "type": "string" }
					]
				}
			}
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)

		for input in ([?]string{`{"x": {"a": {}}}`, `{"head": 1, "x": {"a": {}}}`}) {
			src := transmute([]u8)input
			doc, berr := json.build(src, .Json)
			testing.expect_value(t, berr, nil)
			defer tape.destroy(&doc)

			r_doc := check.check_document(&doc, &c.plan)
			defer check.result_destroy(&r_doc)
			r_stream := json.check(src, &c.plan, .Json)
			defer check.result_destroy(&r_stream)

			testing.expect(t, !r_doc.valid && !r_stream.valid)
			testing.expect_value(t, r_doc.err.kind, check.Error_Kind.Missing_Field)
			testing.expect_value(t, r_doc.err.keyword, "required")
			testing.expect_value(t, r_doc.err.expected, "b")
			testing.expect_value(t, r_doc.err.instance_location, "/x/a")
			testing.expect(t, strings.has_prefix(r_doc.err.keyword_location, "/properties/x/"))
			testing.expect_value(t, r_doc.err.instance_location, r_stream.err.instance_location)
			testing.expect_value(t, r_doc.err.keyword_location, r_stream.err.keyword_location)
		}

		// Case 2: Redirected `obj_arm` landing directly on a non-conjoinable non-direct `.Factored` arm (`dependentSchemas`),
		// forcing `on_end_cold` with `fo_doc != nil && inst_owner != owner` (`replay_doc_factored`) under `sink != nil`.
		sch2 := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"properties": {
				"head": { "type": "integer" },
				"x": {
					"oneOf": [
						{
							"type": "object",
							"allOf": [
								{
									"properties": {
										"a": {
											"type": "object",
											"allOf": [{ "required": ["b"] }]
										}
									}
								}
							],
							"dependentSchemas": {
								"a": { "properties": { "a": true } }
							}
						},
						{ "type": "string" }
					]
				}
			}
		}`
		c2 := compile_b3_json(t, sch2)
		defer schema.destroy(c2)

		for input in ([?]string{`{"x": {"a": {}}}`, `{"head": 1, "x": {"a": {}}}`}) {
			src := transmute([]u8)input
			doc, berr := json.build(src, .Json)
			testing.expect_value(t, berr, nil)
			defer tape.destroy(&doc)

			sd, ss: check.Sink
			check.sink_init(&sd)
			check.sink_init(&ss)
			defer check.sink_destroy(&sd)
			defer check.sink_destroy(&ss)

			r_doc := check.check_document(&doc, &c2.plan, {}, &sd)
			defer check.result_destroy(&r_doc)
			r_stream := json.check(src, &c2.plan, .Json, {}, &ss)
			defer check.result_destroy(&r_stream)

			testing.expect(t, !r_doc.valid && !r_stream.valid)
			expect_sink_entries_equal(t, sd.entries[:], ss.entries[:], input)
			saw_req := false
			for &e in sd.entries {
				if e.kind == .Missing_Field && e.keyword == "required" && e.expected == "b" && e.instance_location == "/x/a" && strings.has_prefix(e.keyword_location, "/properties/x/oneOf/0/") {
					saw_req = true
				}
			}
			testing.expect(t, saw_req)
		}

		// Case 3: Redirected `obj_arm` landing directly on a `closing_direct == true` `.Factored` arm
		// (`patternProperties` colliding with `"a"` disables conjoining while keeping `direct_errors == true`),
		// forcing `on_end_cold` with `fo_doc != nil && inst_owner != owner` (`replay_doc_factored`) even with `sink == nil`!
		sch3 := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"properties": {
				"head": { "type": "integer" },
				"x": {
					"oneOf": [
						{
							"type": "object",
							"patternProperties": {
								"^a$": { "type": "object" }
							},
							"allOf": [
								{
									"properties": {
										"a": {
											"type": "object",
											"allOf": [{ "required": ["b"] }]
										}
									}
								}
							]
						},
						{ "type": "string" }
					]
				}
			}
		}`
		c3 := compile_b3_json(t, sch3)
		defer schema.destroy(c3)

		for input in ([?]string{`{"x": {"a": {}}}`, `{"head": 1, "x": {"a": {}}}`}) {
			src := transmute([]u8)input
			doc, berr := json.build(src, .Json)
			testing.expect_value(t, berr, nil)
			defer tape.destroy(&doc)

			r_doc := check.check_document(&doc, &c3.plan)
			defer check.result_destroy(&r_doc)
			r_stream := json.check(src, &c3.plan, .Json)
			defer check.result_destroy(&r_stream)

			testing.expect(t, !r_doc.valid && !r_stream.valid)
			testing.expect_value(t, r_doc.err.kind, check.Error_Kind.Missing_Field)
			testing.expect_value(t, r_doc.err.keyword, "required")
			testing.expect_value(t, r_doc.err.expected, "b")
			testing.expect_value(t, r_doc.err.instance_location, "/x/a")
			testing.expect(t, strings.has_prefix(r_doc.err.keyword_location, "/properties/x/oneOf/0/"))
			testing.expect_value(t, r_doc.err.instance_location, r_stream.err.instance_location)
			testing.expect_value(t, r_doc.err.keyword_location, r_stream.err.keyword_location)
		}
	}

	// H3: Nested replay (`replay_stream_factored`) preserves `budget.nodes` and subtracts `h.sp + h.nest_depth` from `depth`.
	{
		sch := `{
			"$schema": "https://json-schema.org/draft/2020-12/schema",
			"type": "object",
			"properties": {
				"wrap": {
					"type": "object",
					"oneOf": [
						{ "properties": { "a": { "type": "object" }, "ok": { "type": "integer" } }, "required": ["ok"] },
						{ "properties": { "other": { "type": "string" } }, "required": ["other"] }
					]
				}
			}
		}`
		c := compile_b3_json(t, sch)
		defer schema.destroy(c)
		sink: check.Sink
		check.sink_init(&sink)
		defer check.sink_destroy(&sink)

		// JSON depth 3 (`{` 1 -> `wrap: {` 2 -> `a: {` 3) plus `oneOf` arm subcheck (`nest_depth = 2`):
		// `depth = 4` allows `replay_stream_factored` (`used_depth = 1`, `t_opts.budget.depth = 3`) to report `.No_Arm` cleanly!
		r_ok_depth := json.check(transmute([]u8)string(`{"wrap": {"a": {"x": 1}}}`), &c.plan, .Json, {budget = {depth = 4}}, &sink)
		defer check.result_destroy(&r_ok_depth)
		testing.expect(t, !r_ok_depth.valid)
		testing.expect_value(t, r_ok_depth.err.kind, check.Error_Kind.No_Arm)

		// JSON depth 4 (`{` 1 -> `wrap: {` 2 -> `a: {` 3 -> `x: {` 4) with `depth = 3` exceeds cleanly.
		check.sink_clear(&sink)
		r_over_depth := json.check(transmute([]u8)string(`{"wrap": {"a": {"x": {"y": 1}}}}`), &c.plan, .Json, {budget = {depth = 3}}, &sink)
		defer check.result_destroy(&r_over_depth)
		testing.expect(t, !r_over_depth.valid)
		testing.expect_value(t, r_over_depth.err.kind, check.Error_Kind.Exceeded)

		// Node budget: `{"wrap": {"bad": 1}}` takes 6 tokens before `replay_stream_factored`; `nodes = 8` allows Pass 1 through `}` of `wrap`
		// and then exceeds `nodes = 8` inside `replay_stream_factored` (would silently pass budget if `sub.budget.nodes = 0`)!
		check.sink_clear(&sink)
		r_over_nodes := json.check(transmute([]u8)string(`{"wrap": {"bad": 1}}`), &c.plan, .Json, {budget = {nodes = 8}}, &sink)
		defer check.result_destroy(&r_over_nodes)
		testing.expect(t, !r_over_nodes.valid)
		testing.expect_value(t, r_over_nodes.err.kind, check.Error_Kind.Exceeded)
	}
}
