package json_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import schema "../../core/schema"
import dsv "../../dsv"
import json ".."

// Schema comparison: the verdict in each direction, the witness of a No, and the changes that explain the difference.

@(private = "file")
Read_Schema :: struct {
	doc: core.Document,
	c:   schema.Compiled,
}

@(private = "file")
read_schema :: proc(t: ^testing.T, s: ^Read_Schema, text: string) -> bool {
	err: core.Error
	s.doc, err = core.build(transmute([]u8)text, json.as(.Json))
	if !testing.expectf(t, err == nil, "%s: %v", text, err) {
		return false
	}
	s.c, err = schema.compile(&s.doc, core.ROOT, {resolver = {as = json.as(.Json)}})
	return testing.expectf(t, err == nil, "%s: %v", text, err)
}

@(private = "file")
release :: proc(s: ^Read_Schema) {
	schema.destroy(&s.c)
	core.destroy(&s.doc)
}

@(private = "file")
compare_texts :: proc(t: ^testing.T, old, new: string, format_assert := false, as := core.As{}, reads: ^typed.Format_Reads = nil) -> (c: schema.Comparison, ok: bool) {
	as := as if as.readers != nil else json.as(.Json)
	a, b: Read_Schema
	defer release(&a)
	defer release(&b)
	if !read_schema(t, &a, old) || !read_schema(t, &b, new) {
		return
	}
	err: runtime.Allocator_Error
	c, err = schema.compare(a.c.description, b.c.description, {as = as, reads = reads, format_assert = format_assert})
	return c, err == nil
}

// The two verdicts, and for each No a witness that the check confirmed: the old schema takes it and the new one refuses,
// or the reverse.
@(private = "file")
expect_verdicts :: proc(t: ^testing.T, old, new: string, forward, backward: schema.Verdict, witnesses := [2]string{}) -> bool {
	c, ok := compare_texts(t, old, new)
	if !ok {
		return false
	}
	defer schema.comparison_destroy(&c)
	good := testing.expectf(t, c.old_in_new.verdict == forward && c.new_in_old.verdict == backward, "%s against %s: got %v (%s) and %v (%s), want %v and %v", old, new, c.old_in_new.verdict, c.old_in_new.reason, c.new_in_old.verdict, c.new_in_old.reason, forward, backward)
	if witnesses[0] != "" {
		good &&= testing.expectf(t, c.old_in_new.witness == witnesses[0], "old in new witness %q, want %q", c.old_in_new.witness, witnesses[0])
	}
	if witnesses[1] != "" {
		good &&= testing.expectf(t, c.new_in_old.witness == witnesses[1], "new in old witness %q, want %q", c.new_in_old.witness, witnesses[1])
	}
	return good
}

@(test)
compare_equal :: proc(t: ^testing.T) {
	both := `{"type":"object","required":["id"],"properties":{"id":{"type":"integer","minimum":0},"tags":{"type":"array","items":{"type":"string"}}}}`
	expect_verdicts(t, both, both, .Yes, .Yes)
	expect_verdicts(t, `{"oneOf":[{"type":"string"},{"type":"integer"}]}`, `{"oneOf":[{"type":"string"},{"type":"integer"}]}`, .Yes, .Yes)
	tree := `{"$ref":"#/$defs/n","$defs":{"n":{"type":"object","properties":{"kids":{"type":"array","items":{"$ref":"#/$defs/n"}}}}}}`
	expect_verdicts(t, tree, tree, .Yes, .Yes)
}

@(test)
compare_bounds_and_kinds :: proc(t: ^testing.T) {
	expect_verdicts(t, `{"type":"integer","minimum":0}`, `{"type":"integer","minimum":1}`, .No, .Yes, {"0", ""})
	expect_verdicts(t, `{"type":"string"}`, `{"type":["string","null"]}`, .Yes, .No, {"", "null"})
	expect_verdicts(t, `{"type":"integer"}`, `{"type":"number"}`, .Yes, .No)
	expect_verdicts(t, `{"type":"number","maximum":10}`, `{"type":"number","maximum":10,"exclusiveMinimum":0}`, .No, .Yes)
	expect_verdicts(t, `{"type":"integer","multipleOf":4}`, `{"type":"integer","multipleOf":2}`, .Yes, .No)
	expect_verdicts(t, `{"type":"string","minLength":2,"maxLength":5}`, `{"type":"string","maxLength":8}`, .Yes, .No)
	expect_verdicts(t, `{"type":"string","pattern":"^a"}`, `{"type":"string","pattern":"^b"}`, .No, .No)
	expect_verdicts(t, `{"type":"string","pattern":"^a+$"}`, `{"type":"string","pattern":"^a"}`, .Unknown, .No)
}

@(test)
compare_enums_and_composition :: proc(t: ^testing.T) {
	expect_verdicts(t, `{"enum":[1,2]}`, `{"enum":[1,2,3]}`, .Yes, .No, {"", "3"})
	expect_verdicts(t, `{"type":"boolean"}`, `{"enum":[true,false]}`, .Yes, .Yes)
	expect_verdicts(t, `{"const":"a"}`, `{"type":"string"}`, .Yes, .No)
	expect_verdicts(t, `{"allOf":[{"type":"integer","minimum":1},{"maximum":5}]}`, `{"type":"integer","minimum":0,"maximum":10}`, .Yes, .No)
	expect_verdicts(t, `{"anyOf":[{"type":"string"},{"type":"integer"}]}`, `{"type":["string","integer","null"]}`, .Yes, .No)
	expect_verdicts(t, `{"type":"integer"}`, `{"not":{"type":"string"}}`, .Yes, .No)
}

@(test)
compare_arrays_and_objects :: proc(t: ^testing.T) {
	obj :: `{"type":"object","properties":{"a":{"type":"string"}}`
	expect_verdicts(t, obj + `}`, obj + `,"required":["a"]}`, .No, .Yes, {"{}", ""})
	expect_verdicts(t, obj + `}`, obj + `,"additionalProperties":false}`, .No, .Yes)
	expect_verdicts(t, `{"type":"array","items":{"type":"integer"}}`, `{"type":"array","items":{"type":"number"},"maxItems":3}`, .No, .No)
	expect_verdicts(t, `{"type":"array","items":{"type":"integer"},"uniqueItems":true}`, `{"type":"array","items":{"type":"number"}}`, .Yes, .No)
	expect_verdicts(t, `{"type":"array","prefixItems":[{"type":"string"}],"items":false}`, `{"type":"array","items":{"type":"string"}}`, .Yes, .No)
	expect_verdicts(t, `{"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}`, `{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"string"}},"required":["a"]}`, .No, .No)
}

// The changes name the keyword and the place, and the effect each has on the values taken.
@(test)
compare_changes :: proc(t: ^testing.T) {
	old := `{"type":"object","properties":{"id":{"type":"integer","minimum":0},"mail":{"type":"string"}},"required":["id","mail"]}`
	new := `{"type":"object","properties":{"id":{"type":"integer","minimum":1},"mail":{"type":"string"},"tel":{"type":"string"}},"required":["id"]}`
	c, ok := compare_texts(t, old, new)
	if !ok {
		return
	}
	defer schema.comparison_destroy(&c)
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	for ch in c.changes {
		for s in ch.path {
			#partial switch v in s {
			case core.Name:
				fmt.sbprintf(&sb, ".%s", string(v))
			case core.All:
				strings.write_string(&sb, "[]")
			}
		}
		fmt.sbprintf(&sb, " %s %q>%q %v;", ch.keyword, ch.old, ch.new, ch.effect)
	}
	want := `.id minimum "0">"1" Narrows;.mail required "required">"optional" Widens;.tel properties "">"defined" Narrows;`
	testing.expectf(t, strings.to_string(sb) == want, "got %s", strings.to_string(sb))
	free_all(context.temp_allocator)
}

// A recursive schema whose members each nest arrays and objects of the same schema: the search for a witness builds
// values from it, and its work and memory stay under the search's bound however wide and deep the nesting goes.
@(test)
compare_search_is_bounded :: proc(t: ^testing.T) {
	node :: `{"$ref":"#/$defs/n","$defs":{"n":{"type":"object","properties":{"a":{"$ref":"#/$defs/n"},"b":{"type":"array","items":{"$ref":"#/$defs/n"},"minItems":3,"maxItems":6},"c":{"type":"array","items":{"$ref":"#/$defs/n"},"maxItems":5},"d":{"type":"array","items":{"type":"array","items":{"$ref":"#/$defs/n"}}},"e":{"anyOf":[{"$ref":"#/$defs/n"},{"type":"array","items":{"$ref":"#/$defs/n"}}]},"f":{},"g":{},"h":{}}}}}`
	other :: `{"$ref":"#/$defs/n","$defs":{"n":{"type":"object","required":["z"],"properties":{"a":{"$ref":"#/$defs/n"},"b":{"type":"array","items":{"$ref":"#/$defs/n"},"minItems":2},"c":{"type":"array","items":{"$ref":"#/$defs/n"},"maxItems":4},"d":{"type":"array","items":{"type":"array","items":{"$ref":"#/$defs/n"}}},"e":{"anyOf":[{"$ref":"#/$defs/n"},{"type":"array","items":{"$ref":"#/$defs/n"}}]},"z":{"type":"integer","maximum":3}}}}}`
	expect_verdicts(t, node, other, .No, .Unknown)
	expect_verdicts(t, node, node, .Yes, .Yes)
}

// A Yes in either direction is never refuted by a value: every value in the pool that one schema takes, the other takes
// when the verdict says it must.
@(test)
compare_yes_is_never_refuted :: proc(t: ^testing.T) {
	schemas := [?]string {
		`{}`,
		`{"type":"integer"}`,
		`{"type":"number","minimum":0}`,
		`{"type":"integer","minimum":1,"maximum":5}`,
		`{"type":"string","minLength":1}`,
		`{"enum":[1,"a",null]}`,
		`{"type":["string","null"]}`,
		`{"anyOf":[{"type":"integer"},{"type":"string","maxLength":2}]}`,
		`{"type":"array","items":{"type":"integer"}}`,
		`{"type":"array","items":{"type":"integer","minimum":0},"maxItems":2}`,
		`{"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}`,
		`{"type":"object","properties":{"a":{"type":"number"}}}`,
		`{"type":"object","required":["a"],"additionalProperties":false,"properties":{"a":{"type":"integer"}}}`,
		`{"allOf":[{"type":"integer"},{"minimum":2}]}`,
		`{"not":{"type":"null"}}`,
	}
	pool := [?]string {
		`null`, `true`, `0`, `1`, `3`, `7`, `-1`, `1.5`, `""`, `"a"`, `"abc"`, `[]`, `[1]`, `[0,1]`, `[1,2,3]`, `["a"]`, `{}`, `{"a":1}`, `{"a":1.5}`, `{"a":"x"}`, `{"b":1}`, `{"a":1,"b":2}`,
	}
	for old in schemas {
		for new in schemas {
			c, ok := compare_texts(t, old, new)
			if !ok {
				return
			}
			defer schema.comparison_destroy(&c)
			for direction in 0 ..< 2 {
				from, to := old, new
				if direction == 1 {
					from, to = new, old
				}
				if (c.old_in_new if direction == 0 else c.new_in_old).verdict != .Yes {
					continue
				}
				a, b: Read_Schema
				defer release(&a)
				defer release(&b)
				if !read_schema(t, &a, from) || !read_schema(t, &b, to) {
					return
				}
				ba, ea := schema.bind(&a.c, json.checks(.Json))
				bb, eb := schema.bind(&b.c, json.checks(.Json))
				defer schema.unbind(&ba)
				defer schema.unbind(&bb)
				if !testing.expect(t, ea == nil && eb == nil) {
					return
				}
				for v in pool {
					bytes := transmute([]u8)v
					if schema.valid(&ba, bytes) {
						testing.expectf(t, schema.valid(&bb, bytes), "%s is said to be within %s, which refuses %s", from, to, v)
					}
				}
				// The values of the description itself, which the fixed pool only approaches.
				samples, serr := schema.sample(a.c.description, json.as(.Json), {seed = u64(len(from)), count = 24})
				defer delete(samples)
				if serr == nil {
					for text in samples {
						testing.expectf(t, schema.valid(&bb, text), "%s is said to be within %s, which refuses its sample %s", from, to, string(text))
						delete(text)
					}
				}
			}
		}
	}
}

// A proof that runs past its step budget is no proof: the answer is Unknown with the budget as the reason, and
// the comparison says it is truncated.
@(test)
compare_budget_gives_unknown :: proc(t: ^testing.T) {
	fan :: proc(b: ^strings.Builder, target: string) {
		strings.write_string(b, `{"type":"object","properties":{`)
		for i in 0 ..< 30 {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, `"p%d":%s`, i, target)
		}
		strings.write_string(b, `}}`)
	}
	tree :: proc(maximum: int) -> string {
		b := strings.builder_make(context.temp_allocator)
		fan(&b, `{"$ref":"#/$defs/l1"}`)
		root := strings.clone(strings.to_string(b), context.temp_allocator)
		strings.builder_reset(&b)
		strings.write_string(&b, root[:len(root) - 1])
		strings.write_string(&b, `,"$defs":{"l1":`)
		fan(&b, `{"$ref":"#/$defs/l2"}`)
		strings.write_string(&b, `,"l2":`)
		fan(&b, fmt.tprintf(`{{"type":"integer","maximum":%d}}`, maximum))
		strings.write_string(&b, `}}`)
		return strings.to_string(b)
	}
	c, ok := compare_texts(t, tree(5), tree(6))
	if !ok {
		return
	}
	defer schema.comparison_destroy(&c)
	testing.expectf(t, c.old_in_new.verdict == .Unknown && c.old_in_new.reason == "budget", "got %v (%s)", c.old_in_new.verdict, c.old_in_new.reason)
	testing.expect(t, c.truncated)
	testing.expectf(t, c.new_in_old.verdict != .Yes, "the reverse is no proof either: %v", c.new_in_old.verdict)
}

// A `$dynamicRef` reaches the anchor of the outermost resource that has one, so two schemas that bind it differently
// are never proven to take the same values.
@(test)
compare_dynamic_ref_is_not_proven :: proc(t: ^testing.T) {
	old :: `{"$id":"https://ex.test/root","$ref":"list","$defs":{"T":{"$dynamicAnchor":"T","type":"integer"},"list":{"$id":"list","type":"array","items":{"$dynamicRef":"#T"},"$defs":{"T":{"$dynamicAnchor":"T"}}}}}`
	new :: `{"$id":"https://ex.test/root","$ref":"list","$defs":{"T":{"$dynamicAnchor":"T","type":"string"},"list":{"$id":"list","type":"array","items":{"$dynamicRef":"#T"},"$defs":{"T":{"$dynamicAnchor":"T"}}}}}`
	narrowed :: `{"$id":"https://ex.test/root","minItems":1,"$ref":"list","$defs":{"T":{"$dynamicAnchor":"T","type":"string"},"list":{"$id":"list","type":"array","items":{"$dynamicRef":"#T"},"$defs":{"T":{"$dynamicAnchor":"T"}}}}}`
	for pair in ([?][2]string{{old, new}, {old, narrowed}, {narrowed, new}}) {
		c, ok := compare_texts(t, pair[0], pair[1])
		if !ok {
			return
		}
		defer schema.comparison_destroy(&c)
		testing.expectf(t, c.old_in_new.verdict != .Yes && c.new_in_old.verdict != .Yes, "a dynamic scope that differs is proven the same: %v %v", c.old_in_new.verdict, c.new_in_old.verdict)
	}
}

// A search through an object of thousands of members stays within the process's memory and its work budget.
@(test)
compare_witness_search_is_memory_bounded :: proc(t: ^testing.T) {
	members := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 4000 {
		if i > 0 {
			strings.write_byte(&members, ',')
		}
		fmt.sbprintf(&members, `"m%d":{{"type":"integer","minimum":%d}}`, i, i % 7)
	}
	old := strings.concatenate({`{"type":"object","properties":{`, strings.to_string(members), `}}`}, context.temp_allocator)
	new := strings.concatenate({`{"type":"object","required":["m3999"],"properties":{`, strings.to_string(members), `}}`}, context.temp_allocator)
	c, ok := compare_texts(t, old, new)
	if !ok {
		return
	}
	defer schema.comparison_destroy(&c)
	// The search ends at a witness or at its work budget, which it answers as `Unknown` with the facet it could not decide.
	in_new := c.old_in_new
	testing.expectf(t, in_new.verdict == .No && in_new.witness != "" || in_new.verdict == .Unknown && in_new.reason != "", "the search answered %v", in_new)
	free_all(context.temp_allocator)
}

// A chain of thousands of references is compared without running the stack out.
@(test)
compare_long_reference_chain :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"$ref":"#/$defs/d0","$defs":{`)
	for i in 0 ..< 3000 {
		fmt.sbprintf(&sb, `"d%d":{{"$ref":"#/$defs/d%d"}},`, i, i + 1)
	}
	strings.write_string(&sb, `"d3000":{"type":"integer"}}}`)
	c, ok := compare_texts(t, strings.to_string(sb), strings.to_string(sb))
	if ok {
		schema.comparison_destroy(&c)
	}
	free_all(context.temp_allocator)
}

// A flat format writes the witness as the rows of a table.
@(test)
compare_witness_under_csv_is_a_table :: proc(t: ^testing.T) {
	old := `{"type":"array","items":{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"string"}},"required":["a","b"]}}`
	new := `{"type":"array","items":{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"string"},"c":{"type":"string"}},"required":["a","b","c"]}}`
	c, ok := compare_texts(t, old, new, as = dsv.as(.Csv), reads = dsv.checks(.Csv).reads)
	if !ok {
		return
	}
	defer schema.comparison_destroy(&c)
	testing.expectf(t, c.old_in_new.verdict == .No && c.old_in_new.witness != "", "got %v (%s)", c.old_in_new.verdict, c.old_in_new.reason)
	testing.expect(t, c.new_in_old.verdict == .Yes)
	free_all(context.temp_allocator)
}

// A text of each format's grammar is a witness against the other format.
@(test)
compare_witness_from_format_grammar :: proc(t: ^testing.T) {
	c, ok := compare_texts(t, `{"type":"string","format":"email"}`, `{"type":"string","format":"date"}`, true)
	if !ok {
		return
	}
	defer schema.comparison_destroy(&c)
	testing.expectf(t, c.old_in_new.verdict == .No && c.new_in_old.verdict == .No, "got %v and %v", c.old_in_new.verdict, c.new_in_old.verdict)
	free_all(context.temp_allocator)
}
