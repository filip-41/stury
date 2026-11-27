// Tests for seeded deterministic sample generation (`sample`, `sample_each`) -> `check` roundtrips,
// including complex schemas, formats, patterns, bounded integers, invalid single-rule samples, and `.No_Sample`.
package schema_test

import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/schema"
import "stury:testkit"

@(test)
sample_deterministic_and_complex_roundtrip :: proc(t: ^testing.T) {
	testkit.deadline(t)
	s := `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"$defs": {
			"tag": {"type": "string", "pattern": "^[a-z]{2,5}-[0-9]{2}$"}
		},
		"type": "object",
		"properties": {
			"id": {"type": "string", "format": "uuid"},
			"email": {"type": "string", "format": "email"},
			"created": {"type": "string", "format": "date-time"},
			"count": {"type": "integer", "minimum": 10, "maximum": 50, "multipleOf": 5},
			"ratio": {"type": "number", "exclusiveMinimum": 0, "maximum": 1, "multipleOf": 0.25},
			"tuple": {
				"type": "array",
				"prefixItems": [{"type": "string", "minLength": 2, "maxLength": 4}, {"type": "boolean"}],
				"items": {"type": "integer", "minimum": 0, "maximum": 10},
				"minItems": 2,
				"maxItems": 4
			},
			"tags": {
				"type": "array",
				"items": {"$ref": "#/$defs/tag"},
				"minItems": 1,
				"maxItems": 3,
				"uniqueItems": true
			},
			"choice": {
				"oneOf": [
					{"type": "object", "properties": {"kind": {"const": "a"}, "val": {"type": "integer"}}, "required": ["kind", "val"], "additionalProperties": false},
					{"type": "object", "properties": {"kind": {"const": "b"}, "msg": {"type": "string", "minLength": 1}}, "required": ["kind", "msg"], "additionalProperties": false}
				]
			}
		},
		"required": ["id", "email", "created", "count", "ratio", "tuple", "tags", "choice"],
		"additionalProperties": false
	}`
	c := compile_or_fail(t, s, {format_assert = true})
	defer schema.destroy(c)

	// Deterministic seeded output: two calls with same seed produce identical bytes!
	out1, err1 := schema.sample(c.description, {seed = 42, count = 4, format_assert = true})
	defer schema.error_destroy(&err1)
	testing.expect_value(t, err1.kind, schema.Error_Kind.None)
	defer {
		for b in out1 {
			delete(b)
		}
		delete(out1)
	}

	out2, err2 := schema.sample(c.description, {seed = 42, count = 4, format_assert = true})
	defer schema.error_destroy(&err2)
	testing.expect_value(t, err2.kind, schema.Error_Kind.None)
	defer {
		for b in out2 {
			delete(b)
		}
		delete(out2)
	}

	testing.expect_value(t, len(out1), 4)
	testing.expect_value(t, len(out2), 4)
	for i in 0 ..< len(out1) {
		testing.expect_value(t, string(out1[i]), string(out2[i]))
		expect_json_valid(t, c, string(out1[i]), true)
	}
}

@(test)
sample_allof_anyof_contains_and_invalid :: proc(t: ^testing.T) {
	testkit.deadline(t)
	s := `{
		"allOf": [
			{"type": "object", "properties": {"a": {"type": "integer", "minimum": 5}}, "required": ["a"]},
			{"properties": {"a": {"maximum": 10}, "b": {"anyOf": [{"type": "string", "minLength": 2}, {"type": "boolean"}]}}}
		]
	}`
	c := compile_or_fail(t, s)
	defer schema.destroy(c)

	valid_samples, err := schema.sample(c.description, {seed = 7, count = 5})
	defer schema.error_destroy(&err)
	testing.expect_value(t, err.kind, schema.Error_Kind.None)
	defer {
		for b in valid_samples {
			delete(b)
		}
		delete(valid_samples)
	}
	for b in valid_samples {
		expect_json_valid(t, c, string(b), true)
	}

	// Invalid sample generation: every drawn sample fails with EXACTLY 1 error!
	c_obj := compile_or_fail(t, `{"type": "object", "properties": {"x": {"type": "integer", "minimum": 1, "maximum": 10}}, "required": ["x"], "additionalProperties": false}`)
	defer schema.destroy(c_obj)
	bad_samples, berr := schema.sample(c_obj.description, {seed = 11, count = 3, invalid = true})
	defer schema.error_destroy(&berr)
	testing.expect_value(t, berr.kind, schema.Error_Kind.None)
	defer {
		for b in bad_samples {
			delete(b)
		}
		delete(bad_samples)
	}
	for b in bad_samples {
		sink: check.Sink
		check.sink_init(&sink)
		res := json.check(b, &c_obj.plan, .Json, {}, &sink)
		testing.expectf(t, !res.valid && len(sink.entries) == 1, "expected 1 error on invalid sample %q, got valid=%v count=%d", string(b), res.valid, len(sink.entries))
		check.result_destroy(&res)
		check.sink_destroy(&sink)
	}

	// Unsatisfiable schema returns `.No_Sample`
	c_bad := compile_or_fail(t, `{"type": "integer", "minimum": 10, "maximum": 5}`)
	defer schema.destroy(c_bad)
	_, nerr := schema.sample(c_bad.description, {seed = 0, tries = 8})
	testing.expect_value(t, nerr.kind, schema.Error_Kind.No_Sample)
	schema.error_destroy(&nerr)
}

@(test)
sample_uri_template_prefix_contains_multipleof_minprops :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// 1. `uri-template` format with format assertion enabled (single braces `{var}`)
	{
		c := compile_or_fail(t, `{"type": "string", "format": "uri-template"}`, {format_assert = true})
		defer schema.destroy(c)
		out, err := schema.sample(c.description, {seed = 1, count = 3, format_assert = true})
		defer schema.error_destroy(&err)
		testing.expect_value(t, err.kind, schema.Error_Kind.None)
		defer {
			for b in out {
				delete(b)
			}
			delete(out)
		}
		for b in out {
			expect_json_valid(t, c, string(b), true)
		}
	}

	// 2. Incompatible `prefixItems` + `contains` schedules `contains` after prefix
	{
		c := compile_or_fail(t, `{"type": "array", "prefixItems": [{"type": "string"}], "contains": {"type": "integer"}}`)
		defer schema.destroy(c)
		out, err := schema.sample(c.description, {seed = 2, count = 4})
		defer schema.error_destroy(&err)
		testing.expect_value(t, err.kind, schema.Error_Kind.None)
		defer {
			for b in out {
				delete(b)
			}
			delete(out)
		}
		for b in out {
			expect_json_valid(t, c, string(b), true)
		}
	}

	// 3. Multiple `multipleOf` divisors combined via exact LCM (2 and 3 -> 6) with exclusive bounds
	{
		c := compile_or_fail(t, `{"allOf": [{"type": "integer", "multipleOf": 2, "exclusiveMinimum": 0}, {"multipleOf": 3, "exclusiveMaximum": 30}]}`)
		defer schema.destroy(c)
		out, err := schema.sample(c.description, {seed = 3, count = 5})
		defer schema.error_destroy(&err)
		testing.expect_value(t, err.kind, schema.Error_Kind.None)
		defer {
			for b in out {
				delete(b)
			}
			delete(out)
		}
		for b in out {
			expect_json_valid(t, c, string(b), true)
		}
	}

	// 4. `minProperties` + `additionalProperties: false` includes listed properties instead of inventing disallowed ones
	{
		c := compile_or_fail(t, `{
			"type": "object",
			"properties": {"a": {"type": "integer"}, "b": {"type": "integer"}, "c": {"type": "integer"}},
			"minProperties": 3,
			"additionalProperties": false
		}`)
		defer schema.destroy(c)
		out, err := schema.sample(c.description, {seed = 99, count = 5})
		defer schema.error_destroy(&err)
		testing.expect_value(t, err.kind, schema.Error_Kind.None)
		defer {
			for b in out {
				delete(b)
			}
			delete(out)
		}
		for b in out {
			expect_json_valid(t, c, string(b), true)
		}
	}

	// 5. Polish B6: `reaches_node` traverses `dependentSchemas` so `no_sample_error` keeps `Error.path`.
	{
		c := compile_or_fail(t, `{
			"type": "object",
			"properties": {"a": {"type": "integer"}},
			"required": ["a"],
			"dependentSchemas": {
				"a": {
					"properties": {"b": {"type": "integer", "minimum": 10, "maximum": 5}},
					"required": ["b"]
				}
			}
		}`)
		defer schema.destroy(c)
		_, nerr := schema.sample(c.description, {seed = 1, tries = 8})
		defer schema.error_destroy(&nerr)
		testing.expect_value(t, nerr.kind, schema.Error_Kind.No_Sample)
		saw_dep := false
		for step in nerr.path {
			if nm, ok := step.(tape.Name); ok && string(nm) == "dependentSchemas" {
				saw_dep = true
			}
		}
		testing.expectf(t, saw_dep, "expected Error.path to traverse dependentSchemas, got %v", nerr.path)
	}
}
