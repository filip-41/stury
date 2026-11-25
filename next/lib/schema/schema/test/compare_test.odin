// Tests for schema comparison, breaking-change analysis, subset/equivalence proving,
// and counterexample witness verification against `check`.
package schema_test

import "core:testing"
import "stury:lib/schema/schema"
import "stury:testkit"

@(private = "file")
verify_compare :: proc(
	t: ^testing.T,
	old_s, new_s: string,
	want_old_in_new, want_new_in_old: schema.Verdict,
	opts := schema.Compare_Options{},
	loc := #caller_location,
) -> (c_old, c_new: ^schema.Compiled, cmp: schema.Comparison) {
	c_old = compile_or_fail(t, old_s, {format_assert = opts.format_assert}, loc)
	c_new = compile_or_fail(t, new_s, {format_assert = opts.format_assert}, loc)
	err: any
	cmp, _ = schema.compare(c_old.description, c_new.description, opts)
	_ = err
	testing.expectf(t, cmp.old_in_new.verdict == want_old_in_new, "old_in_new: got %v (reason=%q witness=%q), want %v", cmp.old_in_new.verdict, cmp.old_in_new.reason, cmp.old_in_new.witness, want_old_in_new, loc = loc)
	testing.expectf(t, cmp.new_in_old.verdict == want_new_in_old, "new_in_old: got %v (reason=%q witness=%q), want %v", cmp.new_in_old.verdict, cmp.new_in_old.reason, cmp.new_in_old.witness, want_new_in_old, loc = loc)
	if cmp.old_in_new.verdict == .No {
		testing.expect(t, cmp.old_in_new.witness != "", loc = loc)
		// Witness MUST pass `old` and FAIL `new`!
		expect_json_valid(t, c_old, cmp.old_in_new.witness, true, loc)
		expect_json_valid(t, c_new, cmp.old_in_new.witness, false, loc)
	}
	if cmp.new_in_old.verdict == .No {
		testing.expect(t, cmp.new_in_old.witness != "", loc = loc)
		// Witness MUST pass `new` and FAIL `old`!
		expect_json_valid(t, c_new, cmp.new_in_old.witness, true, loc)
		expect_json_valid(t, c_old, cmp.new_in_old.witness, false, loc)
	}
	return
}

@(test)
compare_equivalent_narrowing_widening_and_both :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// 1. Equivalent schemas
	{
		c1, c2, cmp := verify_compare(t,
			`{"type": "object", "properties": {"a": {"type": "integer", "minimum": 0}}, "required": ["a"]}`,
			`{"type": "object", "properties": {"a": {"type": "integer", "minimum": 0}}, "required": ["a"]}`,
			.Yes, .Yes,
		)
		defer schema.destroy(c1)
		defer schema.destroy(c2)
		defer schema.comparison_destroy(&cmp)
		testing.expect_value(t, len(cmp.changes), 0)
	}

	// 2. Narrowing (breaking change: adding required field / raising minimum)
	{
		c1, c2, cmp := verify_compare(t,
			`{"type": "object", "properties": {"age": {"type": "integer", "minimum": 0}}}`,
			`{"type": "object", "properties": {"age": {"type": "integer", "minimum": 18}}, "required": ["age"]}`,
			.No, .Yes,
		)
		defer schema.destroy(c1)
		defer schema.destroy(c2)
		defer schema.comparison_destroy(&cmp)
		testing.expect(t, len(cmp.changes) >= 2)
		saw_narrow := false
		for ch in cmp.changes {
			if ch.effect == .Narrows {
				saw_narrow = true
			}
		}
		testing.expect(t, saw_narrow)
	}

	// 3. Widening (non-breaking: integer -> number, relaxing maxLength)
	{
		c1, c2, cmp := verify_compare(t,
			`{"type": "object", "properties": {"x": {"type": "integer"}, "s": {"type": "string", "maxLength": 5}}, "required": ["x"]}`,
			`{"type": "object", "properties": {"x": {"type": "number"}, "s": {"type": "string", "maxLength": 10}}}`,
			.Yes, .No,
		)
		defer schema.destroy(c1)
		defer schema.destroy(c2)
		defer schema.comparison_destroy(&cmp)
		saw_widen := false
		for ch in cmp.changes {
			if ch.effect == .Widens {
				saw_widen = true
			}
		}
		testing.expect(t, saw_widen)
	}

	// 4. Incompatible (Both directions No, both witnesses verified!)
	{
		c1, c2, cmp := verify_compare(t,
			`{"type": "integer", "minimum": 0, "maximum": 10}`,
			`{"type": "integer", "minimum": 5, "maximum": 20}`,
			.No, .No,
		)
		defer schema.destroy(c1)
		defer schema.destroy(c2)
		defer schema.comparison_destroy(&cmp)
	}
}

@(test)
compare_multipleof_enum_oneof_recursive_and_format :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// multipleOf divisibility: multipleOf 6 implies multipleOf 3
	{
		c1, c2, cmp := verify_compare(t,
			`{"type": "integer", "multipleOf": 6}`,
			`{"type": "integer", "multipleOf": 3}`,
			.Yes, .No,
		)
		defer schema.destroy(c1)
		defer schema.destroy(c2)
		defer schema.comparison_destroy(&cmp)
	}

	// enum subset
	{
		c1, c2, cmp := verify_compare(t,
			`{"enum": ["a", "b"]}`,
			`{"enum": ["a", "b", "c"]}`,
			.Yes, .No,
		)
		defer schema.destroy(c1)
		defer schema.destroy(c2)
		defer schema.comparison_destroy(&cmp)
	}

	// oneOf disjoint arms: `{"const": "a"}` <= `oneOf [{"const":"a"},{"const":"b"}]`
	{
		c1, c2, cmp := verify_compare(t,
			`{"type": "object", "properties": {"t": {"const": "a"}}, "required": ["t"]}`,
			`{"oneOf": [
				{"type": "object", "properties": {"t": {"const": "a"}}, "required": ["t"]},
				{"type": "object", "properties": {"t": {"const": "b"}}, "required": ["t"]}
			]}`,
			.Yes, .No,
		)
		defer schema.destroy(c1)
		defer schema.destroy(c2)
		defer schema.comparison_destroy(&cmp)
	}

	// Recursive schemas: stricter leaf implies looser leaf
	{
		c1, c2, cmp := verify_compare(t,
			`{"$defs":{"n":{"type":"object","properties":{"v":{"type":"integer","minimum":1},"next":{"$ref":"#/$defs/n"}},"required":["v"]}},"$ref":"#/$defs/n"}`,
			`{"$defs":{"n":{"type":"object","properties":{"v":{"type":"integer","minimum":0},"next":{"$ref":"#/$defs/n"}},"required":["v"]}},"$ref":"#/$defs/n"}`,
			.Yes, .No,
		)
		defer schema.destroy(c1)
		defer schema.destroy(c2)
		defer schema.comparison_destroy(&cmp)
	}

	// format assertion comparison
	{
		c1, c2, cmp := verify_compare(t,
			`{"type": "string", "format": "email"}`,
			`{"type": "string", "format": "uuid"}`,
			.No, .No,
			{format_assert = true},
		)
		defer schema.destroy(c1)
		defer schema.destroy(c2)
		defer schema.comparison_destroy(&cmp)
	}
}

@(test)
compare_evaluates_contains_and_numeric_equality :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// 1. Draft 2020-12 vs Draft 2019-09 `contains` + `unevaluatedItems: false`:
	//    2020-12 accepts `[1]` (contains evaluates it); 2019-09 rejects `[1]` (contains does not).
	//    Prover MUST NOT falsely conclude `Verdict.Yes` via `same_array`!
	{
		c20, c19, cmp := verify_compare(t,
			`{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"array","contains":{"type":"integer"},"unevaluatedItems":false}`,
			`{"$schema":"https://json-schema.org/draft/2019-09/schema","type":"array","contains":{"type":"integer"},"unevaluatedItems":false}`,
			.No, .Unknown,
		)
		defer schema.destroy(c20)
		defer schema.destroy(c19)
		defer schema.comparison_destroy(&cmp)
	}

	// 2. Numerically equal bounds (`0` vs `0.0`, `multipleOf: 2` vs `2.0`) produce zero changes
	{
		c1, c2, cmp := verify_compare(t,
			`{"type": "number", "minimum": 0, "maximum": 10, "multipleOf": 2}`,
			`{"type": "number", "minimum": 0.0, "maximum": 10.0, "multipleOf": 2.0}`,
			.Yes, .Yes,
		)
		defer schema.destroy(c1)
		defer schema.destroy(c2)
		defer schema.comparison_destroy(&cmp)
		testing.expect_value(t, len(cmp.changes), 0)
	}

	// 3. `dependentSchemas` change is reported under `"dependentSchemas"` (not `"dependentRequired"`)
	{
		c1, c2, cmp := verify_compare(t,
			`{"type": "object", "properties": {"a": {"type": "integer"}}}`,
			`{"type": "object", "properties": {"a": {"type": "integer"}}, "dependentSchemas": {"a": {"required": ["b"]}}}`,
			.No, .Yes,
		)
		defer schema.destroy(c1)
		defer schema.destroy(c2)
		defer schema.comparison_destroy(&cmp)
		saw_dep_schema := false
		for ch in cmp.changes {
			if ch.keyword == "dependentSchemas" {
				saw_dep_schema = true
			}
		}
		testing.expect(t, saw_dep_schema)
	}
}
