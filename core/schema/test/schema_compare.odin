package schema_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import core "../.."
import typed "../../typed"
import write "../../write"
import schema ".."
import dsv "../../../dsv"
import json "../../../json"

// Schema comparison: the verdict in each direction, the witness of a No, and the changes that explain the difference.

@(private = "file")
Read_Schema :: struct {
	c: ^schema.Compiled,
}

@(private = "file")
read_schema :: proc(t: ^testing.T, s: ^Read_Schema, text: string) -> bool {
	err: core.Error
	s.c, err = schema.compile(transmute([]u8)text, json.as(.Json))
	return testing.expectf(t, err == nil, "%s: %v", text, err)
}

@(private = "file")
release :: proc(s: ^Read_Schema) {
	schema.destroy(s.c)
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

// A `oneOf` takes a value when one arm takes all of it and no other arm shares a value with that arm: their kinds
// differ, or a member both require holds constants that differ. Arms that may share a value prove nothing.
@(test)
compare_one_of :: proc(t: ^testing.T) {
	defs :: `"$defs":{"cat":{"type":"object","properties":{"kind":{"const":"cat"}},"required":["kind"]},"dog":{"type":"object","properties":{"kind":{"const":"dog"}},"required":["kind"]},"bird":{"type":"object","properties":{"kind":{"enum":["bird"]}},"required":["kind"]}}`
	two :: `{"oneOf":[{"$ref":"#/$defs/cat"},{"$ref":"#/$defs/dog"}],` + defs + `}`
	three :: `{"oneOf":[{"$ref":"#/$defs/cat"},{"$ref":"#/$defs/dog"},{"$ref":"#/$defs/bird"}],` + defs + `}`
	expect_verdicts(t, two, three, .Yes, .No, {"", `{"kind":"bird"}`})
	expect_verdicts(t, two, `{"anyOf":[{"$ref":"#/$defs/cat"},{"$ref":"#/$defs/dog"}],` + defs + `}`, .Yes, .Yes)
	expect_verdicts(t, `{"type":"object","properties":{"a":{"type":"string"}}}`, `{"type":"object","properties":{"a":{"oneOf":[{"type":"string"},{"type":"null"}]}}}`, .Yes, .No, {"", `{"a":null}`})
	expect_verdicts(t, `{"oneOf":[{"type":"string"},{"type":"integer"}]}`, `{"anyOf":[{"type":"string"},{"type":"integer"}]}`, .Yes, .Yes)
	expect_verdicts(t, `{"type":"integer"}`, `{"oneOf":[{"type":"integer"},{"type":"number","minimum":0}]}`, .No, .No, {"0", "0.5"})
	untyped :: `{"oneOf":[{"properties":{"k":{"const":"a"}},"required":["k"]},{"properties":{"k":{"const":"b"}},"required":["k"]}]}`
	expect_verdicts(t, `{}`, untyped, .No, .Yes, {"{}", ""})
}

// An `if` holds where its `then` and its `else` both hold, or where the `if` and the `then` do.
@(test)
compare_conditionals :: proc(t: ^testing.T) {
	zip :: `{"type":"object","properties":{"zip":{"type":"string"}},"required":["zip"]`
	cond :: `"if":{"properties":{"country":{"const":"US"}},"required":["country"]},"then":{"required":["zip"]}`
	expect_verdicts(t, zip + `}`, zip + `,` + cond + `}`, .Yes, .Yes)
	us :: `{"type":"object","properties":{"country":{"const":"US"},"zip":{}},"required":["country","zip"]}`
	expect_verdicts(t, us, `{` + cond + `,"else":{"type":"string"}}`, .Yes, .No)
	expect_verdicts(t, `{"type":"object","properties":{"country":{"type":"string"}}}`, `{"type":"object","properties":{"country":{"type":"string"}},` + cond + `}`, .No, .Yes, {`{"country":"US"}`, ""})
}

// A member is judged by its own node and by each pattern its name matches, and a name no schema names by the pattern
// spelled the same in both, or by the other members' node.
@(test)
compare_pattern_properties :: proc(t: ^testing.T) {
	ext :: `{"type":"object","patternProperties":{"^x-":{"type":"string"}}}`
	expect_verdicts(t, ext, `{"type":"object","patternProperties":{"^x-":{"type":["string","number"]}}}`, .Yes, .No)
	expect_verdicts(t, ext, `{"type":"object"}`, .Yes, .No)
	named :: `{"type":"object","properties":{"x-a":{"type":"integer"}},"patternProperties":{"^x-":{"type":"number"}}}`
	expect_verdicts(t, named, `{"type":"object","patternProperties":{"^x-":{"type":"number"}}}`, .Yes, .No, {"", `{"x-a":0.5}`})
	closed :: `{"type":"object","properties":{"a":{"type":"string"}},"patternProperties":{"^x-":{"type":"string"}},"additionalProperties":false}`
	expect_verdicts(t, closed, `{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"integer"}},"patternProperties":{"^x-":{"type":"string"}},"additionalProperties":false}`, .Yes, .No, {"", `{"b":0}`})
}

// `unevaluatedProperties` takes the members of what the node reaches through `$ref` and `allOf` as evaluated. An
// `additionalProperties` reached evaluates every member, so a closed rule beside it closes nothing.
@(test)
compare_unevaluated_properties :: proc(t: ^testing.T) {
	defs :: `"$defs":{"base":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}}`
	old :: `{"allOf":[{"$ref":"#/$defs/base"}],"properties":{"name":{"type":"string"}},"unevaluatedProperties":false,` + defs + `}`
	new :: `{"allOf":[{"$ref":"#/$defs/base"}],"properties":{"name":{"type":"string"},"tag":{"type":"string"}},"unevaluatedProperties":false,` + defs + `}`
	expect_verdicts(t, old, new, .Yes, .No)
	open :: `{"type":"object","additionalProperties":true,"unevaluatedProperties":false}`
	expect_verdicts(t, open, `{"type":"object","properties":{"a":{}},"unevaluatedProperties":false}`, .No, .Yes, {`{"zz":null}`, ""})
}

// A witness is looked for first at the place the proof stopped at, set into a value of the whole.
@(test)
compare_witness_at_the_place :: proc(t: ^testing.T) {
	address :: `{"type":"object","properties":{"street":{"type":"string"},"city":{"type":"string"},"zip":{"type":"string"}},"required":["street","city"]}`
	wider :: `{"type":"object","properties":{"street":{"type":"string"},"city":{"type":"string"},"zip":{"type":"string"},"country":{"type":"string"}},"required":["street","city"]}`
	holder :: proc(target: string) -> string {
		return fmt.tprintf(`{{"type":"object","properties":{{"home":{{"$ref":"#/$defs/a"}}}},"$defs":{{"a":%s}}}}`, target)
	}
	expect_verdicts(t, holder(address), holder(wider), .No, .Yes)
	expect_verdicts(t, `{"type":"array","prefixItems":[{"type":"number"},{"type":"number"}]}`, `{"type":"array","prefixItems":[{"type":"number"},{"type":"number"},{"type":"number"}]}`, .No, .Yes)
}

// One side of a change as JSON, or `none` when the change has no such side.
side_json :: proc(side: Maybe(core.Value)) -> string {
	v, present := side.?
	if !present {
		return "none"
	}
	tokens: write.Tokens
	write.tokens_init(&tokens, json.as(.Json), {}, context.temp_allocator)
	write.value_of(&tokens, v)
	text, _ := write.tokens_finish(&tokens)
	return string(text)
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
		fmt.sbprintf(&sb, " %s %s>%s %v;", ch.keyword, side_json(ch.old), side_json(ch.new), ch.effect)
	}
	want := `.id minimum 0>1 Narrows;.mail required "required">"optional" Widens;.tel properties none>"defined" Narrows;`
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
		`{"oneOf":[{"type":"string"},{"type":"integer","minimum":0}]}`,
		`{"oneOf":[{"type":"integer"},{"type":"number","minimum":0}]}`,
		`{"type":"object","patternProperties":{"^a":{"type":"integer"}}}`,
		`{"type":"object","properties":{"a":{"type":"integer"}},"unevaluatedProperties":false}`,
		`{"if":{"type":"integer"},"then":{"minimum":2},"else":{"type":"string"}}`,
		`{"type":"object","properties":{"a":{"const":1}},"required":["a"]}`,
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
				ba, ea := schema.bind(a.c, json.checks(.Json))
				bb, eb := schema.bind(b.c, json.checks(.Json))
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
	expect_verdicts(t, strings.to_string(sb), strings.to_string(sb), .Yes, .Yes)
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

// A count too large for an int is one the witness search skips, and the comparison answers.
@(test)
compare_counts_past_the_integers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for keyword in ([?]string{"minItems", "maxItems", "minLength", "minProperties"}) {
		_, ok := compare_texts(t, fmt.tprintf(`{{"type": "array", "%s": 1000000000000000000000000000000}}`, keyword), `{"type": "array"}`)
		testing.expect(t, ok)
	}
}
