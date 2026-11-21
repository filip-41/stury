package json_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"

Find_Case :: struct {
	src:     string,
	path:    []tape.Step,
	dups:    tape.Duplicates,
	outcome: tape.Presence,
	text:    string, // the answer's span for `.Found` and `.Wrong_Kind`
}

// What `find` answers with and without `stop_early`, which changes no answer of a text that parses.
expect_find :: proc(t: ^testing.T, c: Find_Case, spec := json.Spec.Json, loc := #caller_location) {
	for stop in ([]bool{false, true}) {
		f, err := json.find(transmute([]u8)c.src, c.path, spec, {dups = c.dups, stop_early = stop})
		text := c.src[f.lo:f.hi] if f.hi <= u64(len(c.src)) else "?"
		testing.expectf(t, err == nil && f.outcome == c.outcome && text == c.text, "%q %v %v stop %v: %v %q, %v", c.src, c.path, c.dups, stop, f.outcome, text, err, loc = loc)
	}
}

// A path takes members by key and elements by position, from the end when negative, and `All` takes the first value
// that gives an answer.
@(test)
find_follows_paths :: proc(t: ^testing.T) {
	A :: tape.All{}
	cases := []Find_Case {
		{`{"a":1}`, {tape.Name("a")}, .Default, .Found, "1"},
		{` [1, 2] `, {}, .Default, .Found, "[1, 2]"},
		{`{"a":{"b":"x"}}`, {tape.Name("a"), tape.Name("b")}, .Default, .Found, `"x"`},
		{`{"a":{"x":[1,2]}}`, {tape.Name("a")}, .Default, .Found, `{"x":[1,2]}`},
		{`{"a":[1,2,3]}`, {tape.Name("a"), tape.Index(1)}, .Default, .Found, "2"},
		{`{"a":[1,2,3]}`, {tape.Name("a"), tape.Index(-1)}, .Default, .Found, "3"},
		{`{"a":[1,2,3]}`, {tape.Name("a"), tape.Index(-3)}, .Default, .Found, "1"},
		{`{"a":[1,2,3]}`, {tape.Name("a"), tape.Index(-4)}, .Default, .Missing, ""},
		{`{"a":[1,2,3]}`, {tape.Name("a"), tape.Index(3)}, .Default, .Missing, ""},
		{`{"a":[1,{"b":2}]}`, {tape.Name("a"), tape.Index(-1), tape.Name("b")}, .Default, .Found, "2"},
		{`[[],[5]]`, {A, A}, .Default, .Found, "5"},
		{`[[5],[]]`, {tape.Index(-1), A}, .Default, .Missing, ""},
		{`[]`, {A}, .Default, .Missing, ""},
		{`{"x":7}`, {A}, .Default, .Found, "7"},
		{`{"":1}`, {tape.Name("")}, .Default, .Found, "1"},
		{`{"b":[1,2],"a":1}`, {tape.Name("a")}, .Default, .Found, "1"},
	}
	for c in cases {
		expect_find(t, c)
	}
}

// A value a step cannot enter answers `.Wrong_Kind`, but a null, or a member missing, reads as null through the steps
// after the last `All`, as in jq.
@(test)
find_answers_why_none_was_found :: proc(t: ^testing.T) {
	A :: tape.All{}
	cases := []Find_Case {
		{`{"a":1}`, {tape.Name("a"), tape.Name("b")}, .Default, .Wrong_Kind, "1"},
		{`[1]`, {tape.Name("a")}, .Default, .Wrong_Kind, "[1]"},
		{`{"a":1}`, {tape.Index(0)}, .Default, .Wrong_Kind, `{"a":1}`},
		{`{"a":null}`, {tape.Name("a"), tape.Name("b")}, .Default, .Missing, ""},
		{`{"a":null}`, {tape.Name("a"), A}, .Default, .Wrong_Kind, "null"},
		{`{}`, {tape.Name("a"), A}, .Default, .Wrong_Kind, "{}"},
		{`{}`, {tape.Name("a")}, .Default, .Missing, ""},
	}
	for c in cases {
		expect_find(t, c)
	}
}

// A repeated key answers through its last member, or with `.First` its first.
@(test)
find_takes_a_repeated_key_by_policy :: proc(t: ^testing.T) {
	cases := []Find_Case {
		{`{"a":1,"a":2}`, {tape.Name("a")}, .Default, .Found, "2"},
		{`{"a":1,"a":2}`, {tape.Name("a")}, .First, .Found, "1"},
		{`{"a":{"b":1},"a":{"c":2}}`, {tape.Name("a"), tape.Name("b")}, .Last, .Missing, ""},
		{`{"a":{"b":1},"a":{"c":2}}`, {tape.Name("a"), tape.Name("b")}, .First, .Found, "1"},
	}
	for c in cases {
		expect_find(t, c)
	}
}

// Every byte is judged, a skipped value's too, unless `stop_early` ends the read at a known answer.
@(test)
find_judges_the_text :: proc(t: ^testing.T) {
	path := []tape.Step{tape.Name("a")}
	f, err := json.find(transmute([]u8)string(`{"a":1,`), path, .Json, {dups = .First, stop_early = true})
	testing.expectf(t, err == nil && f.outcome == .Found, "%v %v", f, err)
	_, err = json.find(transmute([]u8)string(`{"a":1,`), path, .Json, {dups = .First})
	kind, at := fault_of(err)
	testing.expectf(t, kind == .Truncated && at == 7, "%v", err)
	_, err = json.find(transmute([]u8)string(`{"b":[1,2,x],"a":1}`), path)
	kind, at = fault_of(err)
	testing.expectf(t, kind == .Bad_Char && at == 10, "%v", err)
	_, err = json.find(transmute([]u8)string(`[{"id":1},{"id":2},[x]]`), {tape.Index(0), tape.Name("id")})
	kind, at = fault_of(err)
	testing.expectf(t, kind == .Bad_Char && at == 20, "past the answer: %v", err)
}

// A key with escapes is compared as it decodes.
@(test)
find_matches_decoded_keys :: proc(t: ^testing.T) {
	expect_find(t, {`{"a\u0062":1}`, {tape.Name("ab")}, .Default, .Found, "1"})
	expect_find(t, {`{"\u00e9\n":1}`, {tape.Name("\u00e9\n")}, .Default, .Found, "1"})
	expect_find(t, {`{"\ud83d\ude00":1}`, {tape.Name("\U0001F600")}, .Default, .Found, "1"})
	expect_find(t, {`{"ab\u0063":1}`, {tape.Name("ab")}, .Default, .Missing, ""})
	expect_find(t, {`{"a\u0062":1}`, {tape.Name("abc")}, .Default, .Missing, ""})
	expect_find(t, {"{'a\\\nb':1}", {tape.Name("ab")}, .Default, .Found, "1"}, .Json5)
	expect_find(t, {"{'\\x41\\q':1}", {tape.Name("Aq")}, .Default, .Found, "1"}, .Json5)
}

// A path holds any number of steps, and a negative index reaches any distance from the end.
@(test)
find_takes_any_path :: proc(t: ^testing.T) {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_byte(&b, '[')
	for i in 0 ..< 100 {
		fmt.sbprintf(&b, "%s%d", "," if i > 0 else "", i)
	}
	strings.write_byte(&b, ']')
	expect_find(t, {strings.to_string(b), {tape.Index(-70)}, .Default, .Found, "30"})
	expect_find(t, {strings.to_string(b), {tape.Index(-101)}, .Default, .Missing, ""})
	deep := strings.concatenate({strings.repeat("[", 70, context.temp_allocator), "7", strings.repeat("]", 70, context.temp_allocator)}, context.temp_allocator)
	ends := make([]tape.Step, 70, context.temp_allocator)
	starts := make([]tape.Step, 70, context.temp_allocator)
	for i in 0 ..< 70 {
		ends[i], starts[i] = tape.Index(-1), tape.Index(0)
	}
	expect_find(t, {deep, ends, .Default, .Found, "7"})
	expect_find(t, {deep, starts, .Default, .Found, "7"})
	expect_find(t, {deep, ends[:5], .Default, .Found, deep[5:len(deep) - 5]})
	// Each inner array takes the ring its level took before, in the room and in an allocated block.
	strings.builder_reset(&b)
	strings.write_byte(&b, '[')
	for i in 0 ..< 200 {
		fmt.sbprintf(&b, "%s[%d,%d]", "," if i > 0 else "", i, i + 1000)
	}
	strings.write_byte(&b, ']')
	expect_find(t, {strings.to_string(b), {tape.Index(-1), tape.Index(-1)}, .Default, .Found, "1199"})
	expect_find(t, {strings.to_string(b), {tape.Index(-40), tape.Index(-40)}, .Default, .Missing, ""})
	expect_find(t, {strings.to_string(b), {tape.Index(-40), tape.Index(-2)}, .Default, .Found, "160"})
}

// Under a negative index followed by a name, the element picked at the close is read again for the rest of the path.
@(test)
find_reads_a_picked_element_again :: proc(t: ^testing.T) {
	recs := `[{"a":1},{"a":2},{"b":3}]`
	expect_find(t, {recs, {tape.Index(-2), tape.Name("a")}, .Default, .Found, "2"})
	expect_find(t, {recs, {tape.Index(-3), tape.Name("a")}, .Default, .Found, "1"})
	expect_find(t, {recs, {tape.Index(-1), tape.Name("a")}, .Default, .Missing, ""})
	expect_find(t, {recs, {tape.Index(-4), tape.Name("a")}, .Default, .Missing, ""})
	expect_find(t, {`[1,{"a":5},2]`, {tape.Index(-2), tape.Name("a")}, .Default, .Found, "5"})
	expect_find(t, {`["x",{"a":1}]`, {tape.Index(-2), tape.Name("a")}, .Default, .Wrong_Kind, `"x"`})
	expect_find(t, {`[[1,2],[3,4]]`, {tape.Index(-1), tape.Index(-2)}, .Default, .Found, "3"})
	expect_find(t, {`[[[1,2]],[[3,4],[5]]]`, {tape.Index(-1), tape.Index(-2), tape.Index(-1)}, .Default, .Found, "4"})
	expect_find(t, {`{"a":[{"b":1}],"a":[{"b":2},{"c":0}]}`, {tape.Name("a"), tape.Index(-2), tape.Name("b")}, .Default, .Found, "2"})
	expect_find(t, {"[/*c*/{\"a\":1},//x\n{\"a\":2}]", {tape.Index(-2), tape.Name("a")}, .Default, .Found, "1"}, .Jsonc)
}

// A skipped container may nest past the levels a walk's frame holds, inside or below a path that does too.
@(test)
find_passes_deep_containers :: proc(t: ^testing.T) {
	deep := strings.concatenate({strings.repeat("[", 1500, context.temp_allocator), strings.repeat("]", 1500, context.temp_allocator)}, context.temp_allocator)
	src := strings.concatenate({`{"a":`, deep, `,"b":7}`}, context.temp_allocator)
	expect_find(t, {src, {tape.Name("b")}, .Default, .Found, "7"})
	steps := make([]tape.Step, 1200, context.temp_allocator)
	for i in 0 ..< 1200 {
		steps[i] = tape.Index(-1)
	}
	inner := strings.concatenate({strings.repeat("[", 1200, context.temp_allocator), "[", deep, "],7", strings.repeat("]", 1200, context.temp_allocator)}, context.temp_allocator)
	expect_find(t, {inner, steps[:1200], .Default, .Found, "7"})
	bad := strings.concatenate({`{"a":`, deep[:2000], "x", deep[2000:], `,"b":7}`}, context.temp_allocator)
	_, err := json.find(transmute([]u8)bad, {tape.Name("b")})
	kind, at := fault_of(err)
	testing.expectf(t, kind == .Bad_Char && at == 2005, "%v", err)
}

// A scalar answer's node is read by the format's readers.
@(test)
find_answers_read_as_nodes :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"s":"x\u0041","n":-2.5}`)
	f, _ := json.find(src, {tape.Name("s")})
	buf: [8]u8
	s, ok := tape.node_text(json.as(.Json), src, tape.answer_node(f), buf[:])
	testing.expectf(t, ok && s == "xA", "%q %v", s, ok)
	f, _ = json.find(src, {tape.Name("n")})
	num, is_number := tape.node_number(json.as(.Json), src, tape.answer_node(f))
	testing.expectf(t, is_number && transmute(f64)num.bits == -2.5, "%v", num)
	src = transmute([]u8)string(`[7,{"a":[1,25e-1]}]`)
	f, _ = json.find(src, {tape.Index(-1), tape.Name("a"), tape.Index(-1)})
	num, is_number = tape.node_number(json.as(.Json), src, tape.answer_node(f))
	testing.expectf(t, is_number && transmute(f64)num.bits == 2.5, "%v", num)
	src = transmute([]u8)string(`{a: [.5, 5.]}`)
	for want, i in ([]f64{0.5, 5}) {
		f, _ = json.find(src, {tape.Name("a"), tape.Index(i)}, .Json5)
		num, is_number = tape.node_number(json.as(.Json5), src, tape.answer_node(f))
		testing.expectf(t, is_number && transmute(f64)num.bits == want, "json5 %v: %v", want, num)
	}
}

// JSONC and JSON5 texts are read by the same paths.
@(test)
find_reads_every_spec :: proc(t: ^testing.T) {
	expect_find(t, {"{/*c*/\"a\"://x\n 1}", {tape.Name("a")}, .Default, .Found, "1"}, .Jsonc)
	expect_find(t, {"{a:'s', b: [1,],}", {tape.Name("a")}, .Default, .Found, "'s'"}, .Json5)
	expect_find(t, {"{a:'s', b: [1,],}", {tape.Name("b"), tape.Index(-1)}, .Default, .Found, "1"}, .Json5)
}
