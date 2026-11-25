package json_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"

Find_Case :: struct {
	src:     string,
	path:    []tape.Step,
	dups:    tape.Duplicates,
	outcome: tape.Presence,
	text:    string, // the answer's span for `.Found` and `.Wrong_Kind`
}

// Checks that `find` gives the case's outcome and span with and without `stop_early`.
expect_find :: proc(t: ^testing.T, c: Find_Case, spec := json.Spec.Json, loc := #caller_location) {
	for stop in ([]bool{false, true}) {
		f, err := json.find(transmute([]u8)c.src, c.path, spec, {stop_early = stop}, {dups = c.dups})
		text := c.src[f.lo:f.hi] if f.hi <= u64(len(c.src)) else "?"
		testing.expectf(t, err == nil && f.outcome == c.outcome && text == c.text, "%q %v %v stop %v: %v %q, %v", c.src, c.path, c.dups, stop, f.outcome, text, err, loc = loc)
	}
}

// A path takes members by key and elements by position, from the end when negative, and `All` takes the first value
// that gives an answer.
@(test)
find_follows_paths :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
	testkit.deadline(t)
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
	testkit.deadline(t)
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

// Every byte is checked for validity, a skipped value's too, unless `stop_early` ends the read at a known answer.
@(test)
find_judges_the_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	path := []tape.Step{tape.Name("a")}
	f, err := json.find(transmute([]u8)string(`{"a":1,`), path, .Json, {stop_early = true}, {dups = .First})
	testing.expectf(t, err == nil && f.outcome == .Found, "%v %v", f, err)
	_, err = json.find(transmute([]u8)string(`{"a":1,`), path, .Json, {}, {dups = .First})
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
	testkit.deadline(t)
	expect_find(t, {`{"a\u0062":1}`, {tape.Name("ab")}, .Default, .Found, "1"})
	expect_find(t, {`{"\u00e9\n":1}`, {tape.Name("\u00e9\n")}, .Default, .Found, "1"})
	expect_find(t, {`{"\ud83d\ude00":1}`, {tape.Name("\U0001F600")}, .Default, .Found, "1"})
	expect_find(t, {`{"ab\u0063":1}`, {tape.Name("ab")}, .Default, .Missing, ""})
	expect_find(t, {`{"a\u0062":1}`, {tape.Name("abc")}, .Default, .Missing, ""})
	expect_find(t, {"{'a\\\nb':1}", {tape.Name("ab")}, .Default, .Found, "1"}, .Json5)
	expect_find(t, {"{'\\x41\\q':1}", {tape.Name("Aq")}, .Default, .Found, "1"}, .Json5)
}

// A key whose escapes leave its last byte out of it is ruled out by that byte, without a decode, and a key whose
// escapes reach its last byte is still decoded and compared. Covers `\uXXXX`, a surrogate pair, `\\`, `\n`, `\"` and a
// multi-byte text, at the end of a key and before other bytes.
@(test)
find_rules_out_escaped_keys_by_their_tail :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// `\u0061` ends the key: the last byte of the text is the escape's, so the key is decoded.
	expect_find(t, {`{"a\u0061":1}`, {tape.Name("aa")}, .Default, .Found, "1"})
	expect_find(t, {`{"a\u0061":1}`, {tape.Name("ab")}, .Default, .Missing, ""})
	// The escape ends before the last byte, which is the key's own: `b` rules `aax` out with no decode.
	expect_find(t, {`{"a\u0061b":1}`, {tape.Name("aab")}, .Default, .Found, "1"})
	expect_find(t, {`{"a\u0061b":1}`, {tape.Name("aax")}, .Default, .Missing, ""})
	// A surrogate pair's second half ends the key, and one followed by a byte leaves that byte the key's.
	expect_find(t, {`{"\ud83d\ude00x":1}`, {tape.Name("\U0001F600x")}, .Default, .Found, "1"})
	expect_find(t, {`{"\ud83d\ude00x":1}`, {tape.Name("\U0001F600y")}, .Default, .Missing, ""})
	expect_find(t, {`{"\ud83d\ude00":1}`, {tape.Name("\U0001F600a")}, .Default, .Missing, ""})
	// `\\`, `\n` and `\"` end the key, and each decodes to a byte that no raw byte of the key gives.
	expect_find(t, {`{"a\\":1}`, {tape.Name(`a\`)}, .Default, .Found, "1"})
	expect_find(t, {`{"a\\":1}`, {tape.Name("ab")}, .Default, .Missing, ""})
	expect_find(t, {`{"a\n":1}`, {tape.Name("a\n")}, .Default, .Found, "1"})
	expect_find(t, {`{"a\n":1}`, {tape.Name("an")}, .Default, .Missing, ""})
	expect_find(t, {`{"a\"":1}`, {tape.Name(`a"`)}, .Default, .Found, "1"})
	expect_find(t, {`{"a\"":1}`, {tape.Name("a?")}, .Default, .Missing, ""})
	// A `\uXXXX` that decodes to two bytes, at the end and before the key's last byte.
	expect_find(t, {`{"a\u00e9":1}`, {tape.Name("a\u00e9")}, .Default, .Found, "1"})
	expect_find(t, {`{"a\u00e9x":1}`, {tape.Name("a\u00e9y")}, .Default, .Missing, ""})
	// The escapes the tail check reads past: a `\u` six bytes before a last byte that is not `u`, and a `\` two
	// bytes before a last byte that is not escaped.
	expect_find(t, {`{"\u0061\u0062c":1}`, {tape.Name("abc")}, .Default, .Found, "1"})
	expect_find(t, {`{"\u0061\u0062c":1}`, {tape.Name("abd")}, .Default, .Missing, ""})
	// A repeated key still answers by policy, decoded or not.
	expect_find(t, {`{"k\u0061100000":1,"ka199999":2}`, {tape.Name("ka199999")}, .Default, .Found, "2"})
	expect_find(t, {`{"k\u0061100000":1,"ka199999":2}`, {tape.Name("ka199999")}, .Last, .Found, "2"})
	expect_find(t, {`{"ka199999":2,"k\u0061100000":1}`, {tape.Name("ka199999")}, .First, .Found, "2"})
}

// A key longer than the two words a compare loads is read whole, so the bytes between the words still keep a key
// that is not the step's from being taken.
@(test)
find_reads_long_keys_whole :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Twenty bytes: the first and last eight match the step's, the four between do not.
	expect_find(t, {`{"0123456789abcdefghij":1}`, {tape.Name("01234567XXabcdefghij")}, .Default, .Missing, ""})
	expect_find(t, {`{"01234567XXabcdefghij":1}`, {tape.Name("01234567XXabcdefghij")}, .Default, .Found, "1"})
	expect_find(t, {`{"0123456789abcdefghij":1}`, {tape.Name("0123456789abcdefghij")}, .Default, .Found, "1"})
	// An escaped key longer than the words is decoded as it is compared, at any length.
	expect_find(t, {`{"\u00610123456789abcdefghij":1}`, {tape.Name("a0123456789abcdefghij")}, .Default, .Found, "1"})
	expect_find(t, {`{"\u00610123456789abcdefghij":1}`, {tape.Name("a0123456789abcdefghik")}, .Default, .Missing, ""})
}

// A path holds any number of steps, and a negative index reaches any distance from the end.
@(test)
find_takes_any_path :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
	testkit.deadline(t)
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

// Every element counted from the end is found in arrays of every length around the elements a find reads as they pass.
@(test)
find_takes_every_element_from_the_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for length in 0 ..= 3 * 8 {
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		strings.write_byte(&sb, '[')
		for i in 0 ..< length {
			if i > 0 {
				strings.write_byte(&sb, ',')
			}
			fmt.sbprintf(&sb, `{{"a":%d}}`, i)
		}
		strings.write_byte(&sb, ']')
		src := strings.to_string(sb)
		for back in 1 ..= length + 1 {
			path := []tape.Step{tape.Index(-back), tape.Name("a")}
			if back > length {
				expect_find(t, {src, path, .Default, .Missing, ""})
			} else {
				expect_find(t, {src, path, .Default, .Found, fmt.tprint(length - back)})
			}
			nested := fmt.tprintf("[0,%s]", src)
			if back <= length {
				expect_find(t, {nested, {tape.Index(-1), tape.Index(-back), tape.Name("a")}, .Default, .Found, fmt.tprint(length - back)})
			}
		}
	}
}

// A skipped container may nest past the levels a walk's frame holds, inside or below a path that does too.
@(test)
find_passes_deep_containers :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
	testkit.deadline(t)
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
	testkit.deadline(t)
	expect_find(t, {"{/*c*/\"a\"://x\n 1}", {tape.Name("a")}, .Default, .Found, "1"}, .Jsonc)
	expect_find(t, {"{a:'s', b: [1,],}", {tape.Name("a")}, .Default, .Found, "'s'"}, .Json5)
	expect_find(t, {"{a:'s', b: [1,],}", {tape.Name("b"), tape.Index(-1)}, .Default, .Found, "1"}, .Json5)
}

// A limit cuts the children an `All` takes, an object's under `.First` only, and a slice takes elements by place from
// either end: the first one in it that gives an answer.
@(test)
find_takes_limits_and_slices :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	S :: proc(lo: i32, hi: Maybe(i32), limit: i32 = 0) -> tape.Step {return tape.Slice{lo, hi, limit}}
	nums := `[0,1,2,3,4]`
	cases := []Find_Case {
		{nums, {S(1, 3)}, .Default, .Found, "1"},
		{nums, {S(-2, nil)}, .Default, .Found, "3"},
		{nums, {S(-3, -1)}, .Default, .Found, "2"},
		{nums, {S(3, -1)}, .Default, .Found, "3"},
		{nums, {S(4, -1)}, .Default, .Missing, ""},
		{nums, {S(3, 1)}, .Default, .Missing, ""},
		{nums, {S(-9, 1)}, .Default, .Found, "0"},
		{nums, {S(9, nil)}, .Default, .Missing, ""},
		{`[[],[],[5],[6]]`, {S(1, nil), tape.All{}}, .Default, .Found, "5"},
		{`[[],[],[5],[6]]`, {S(-3, nil), tape.All{}}, .Default, .Found, "5"},
		{`[[],[],[5],[6]]`, {S(0, -1), tape.All{}}, .Default, .Found, "5"},
		{`[[],[],[5],[6]]`, {S(0, -2), tape.All{}}, .Default, .Missing, ""},
		{`[[],[],[5],[6]]`, {S(1, nil, 1), tape.All{}}, .Default, .Missing, ""},
		{`[[],[],[5],[6]]`, {S(-4, nil, 2), tape.All{}}, .Default, .Missing, ""},
		{`[[],[],[5],[6]]`, {tape.All{2}, tape.All{}}, .Default, .Missing, ""},
		{`[[],[],[5],[6]]`, {tape.All{3}, tape.All{}}, .Default, .Found, "5"},
		{`[{"b":1},{"a":2}]`, {S(-1, nil), N("a")}, .Default, .Found, "2"},
		{`{"x":[],"y":[1]}`, {tape.All{1}, tape.All{}}, .First, .Missing, ""},
		{`{"x":[],"y":[1]}`, {tape.All{1}, tape.All{}}, .Default, .Found, "1"},
		{`{"a":[1]}`, {S(0, nil)}, .Default, .Wrong_Kind, `{"a":[1]}`},
		{`{"a":null}`, {N("a"), S(0, nil)}, .Default, .Missing, ""},
		{`{"a":1}`, {N("b"), S(-1, nil)}, .Default, .Missing, ""},
	}
	for c in cases {
		expect_find(t, c)
	}
	expect_find(t, {"[1, /* x */ 2, 3,]", {S(-2, nil)}, .Default, .Found, "2"}, .Jsonc)
	expect_find(t, {"[1, 2, 3,]", {S(1, -1)}, .Default, .Found, "2"}, .Json5)
}

// The memory a ring takes is bounded by the number of elements its array has, whatever the text's length or the
// index's reach, and a find frees each block at the size it allocated.
@(test)
find_rings_take_memory_by_elements :: proc(t: ^testing.T) {
	testkit.deadline(t)
	PAD :: 1 << 20
	array :: proc(count: int, element: proc(i: int) -> string) -> string {
		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator)
		strings.write_byte(&b, '[')
		for i in 0 ..< count {
			strings.write_string(&b, "," if i > 0 else "")
			strings.write_string(&b, element(i))
		}
		strings.write_string(&b, strings.repeat(" ", PAD, context.temp_allocator))
		strings.write_byte(&b, ']')
		return strings.to_string(b)
	}
	record :: proc(i: int) -> string {return fmt.tprintf(`{{"x":%d}}`, i)}
	inner :: proc(i: int) -> string {return "[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29]"}
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	deep := strings.concatenate({strings.repeat(`{"a":`, 70, context.temp_allocator), "1", strings.repeat("}", 70, context.temp_allocator)}, context.temp_allocator)
	deep_path := make([]tape.Step, 70, context.temp_allocator)
	for &step in deep_path {
		step = N("a")
	}
	ENTRY :: size_of(tape.Span_Answer)
	Case :: struct {
		src:      string,
		path:     []tape.Step,
		outcome:  tape.Presence,
		text:     string,
		most:     int, // the bytes the find may hold at once
	}
	cases := []Case {
		// Fewer elements than the room's entries, so nothing is allocated.
		{array(3, record), {tape.Index(-100000), N("x")}, .Missing, "", 0},
		{array(3, record), {tape.Slice{lo = -100000}, N("x")}, .Found, "0", 0},
		// More elements than the room's entries: the ring has as many as the elements, doubled at most.
		{array(200, record), {tape.Index(-100000), N("x")}, .Missing, "", 2 * 200 * ENTRY},
		{array(200, record), {tape.Index(-150), N("x")}, .Found, "50", 2 * 200 * ENTRY},
		{array(200, record), {tape.Slice{lo = -100000}, N("x")}, .Found, "0", 2 * 200 * ENTRY},
		{array(200, record), {tape.Slice{lo = -150}, N("x")}, .Found, "50", 2 * 200 * ENTRY},
		{array(200, record), {tape.Slice{lo = 0, hi = -100000}, N("x")}, .Missing, "", 2 * 200 * ENTRY},
		// Two rings open at once, the inner growing above the outer.
		{array(100, inner), {tape.Index(-100), tape.Index(-30)}, .Found, "0", 2 * 2 * 100 * ENTRY},
		{array(100, inner), {tape.Index(-90), tape.Index(-20)}, .Found, "10", 2 * 2 * 100 * ENTRY},
		// A path past the room's levels.
		{deep, deep_path, .Found, "1", 70 * (size_of(u64) + 40)},
	}
	for c, i in cases {
		s: Sized
		sized_init(&s)
		allocator := sized_allocator(&s)
		for stop in ([]bool{false, true}) {
			f, err := json.find(transmute([]u8)c.src, c.path, .Json, {stop_early = stop}, allocator = allocator)
			text := c.src[f.lo:f.hi] if f.hi <= u64(len(c.src)) else "?"
			testing.expectf(t, err == nil && f.outcome == c.outcome && (c.text == "" || text == c.text), "case %d stop %v: %v %q, %v", i, stop, f.outcome, text, err)
			testing.expectf(t, s.live == 0 && s.mismatch == 0, "case %d: %d bytes live, %d sizes mismatched", i, s.live, s.mismatch)
			testing.expectf(t, s.peak <= c.most + 64, "case %d: %d bytes held at once, at most %d", i, s.peak, c.most)
		}
		sized_destroy(&s)
	}
}

@(test)
path_reads_refuse_a_build_only_dups_policy :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`{"a":1,"a":2}`)
	for dups in ([]tape.Duplicates{.Refuse, .All}) {
		_, ferr := json.find(src, []tape.Step{tape.Name("a")}, .Json, {}, {dups = dups})
		if !testing.expect_value(t, ferr, tape.Error(tape.Bad_Option{"dups"})) {
			return
		}
		demand, _ := tape.demand_of([][]tape.Step{{tape.Name("a")}}, allocator = context.temp_allocator)
		_, serr := json.scan(src, &demand, .Json, {}, {dups = dups})
		if !testing.expect_value(t, serr, tape.Error(tape.Bad_Option{"dups"})) {
			return
		}
		doc, _ := json.build(src, allocator = context.temp_allocator)
		_, qerr := json.query({doc = &doc}, &demand, {dups = dups})
		if !testing.expect_value(t, qerr, tape.Error(tape.Bad_Option{"dups"})) {
			return
		}
	}
}

// One policy for repeated keys reaches every read, and a read refuses the one it cannot honour: a validate compares no
// keys, so it refuses `.Refuse` and reads under the rest as under none. Records refuse it as their reads do.
@(test)
validate_refuses_a_dups_policy_it_cannot_honour :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`{"a":1,"a":2}`)
	for dups in tape.Duplicates {
		err := json.validate(src, .Json, {dups = dups})
		r := json.records_open(src, .Lines, .Json, {dups = dups})
		out: [1]tape.Record
		n := json.records_validate(&r, out[:])
		if dups == .Refuse {
			testing.expectf(t, err == tape.Error(tape.Bad_Option{"dups"}), "%v: %v", dups, err)
			testing.expectf(t, n == 0 && r.err == tape.Error(tape.Bad_Option{"dups"}), "%v records: %d %v", dups, n, r.err)
		} else {
			testing.expectf(t, err == nil, "%v: %v", dups, err)
			testing.expectf(t, n == 0 && r.err == nil && r.index == 1, "%v records: %d %v %v", dups, n, out[0], r.err)
		}
	}
}

// Options another format family has are refused by every JSON read, before the text is read.
@(test)
reads_refuse_options_of_another_format :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`{"a":1}`)
	opts := json.Options{format = tape.Dsv_Options{delimiter = ';'}}
	want := tape.Error(tape.Bad_Option{"format"})
	testing.expect_value(t, json.validate(src, .Json, opts), want)
	_, berr := json.build(src, .Json, opts)
	testing.expect_value(t, berr, want)
	_, ferr := json.find(src, []tape.Step{tape.Name("a")}, .Json, {}, opts)
	testing.expect_value(t, ferr, want)
	demand, _ := tape.demand_of([][]tape.Step{{tape.Name("a")}}, allocator = context.temp_allocator)
	_, serr := json.scan(src, &demand, .Json, {}, opts)
	testing.expect_value(t, serr, want)
	r := json.records_open(src, .Lines, .Json, opts)
	out: [1]tape.Record
	n := json.records_validate(&r, out[:])
	testing.expectf(t, n == 0 && r.err == want, "records: %d %v", n, r.err)
	testing.expect_value(t, json.validate(src, .Json, {format = tape.Dsv_Options{}}), want)
}

// The walk, a text in pieces and a build on a runner's threads refuse them too.
@(test)
walks_refuse_options_of_another_format :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`{"a":1}`)
	want := tape.Error(tape.Bad_Option{"format"})
	other := tape.Format_Options(tape.Dsv_Options{})
	regs: hook.Regs
	h: hook.No_Hooks
	_, werr, _ := json.walk(src, .Json, {format = other}, &h, &regs, hook.no_hook)
	testing.expect_value(t, werr, want)
	pieces := tape.Pieces{allocator = context.allocator}
	testing.expect_value(t, json.validate(src, .Json, {format = other, pieces = &pieces}), want)
	runner: tape.Runner
	_, berr := json.build(src, .Json, {format = other, runner = &runner})
	testing.expect_value(t, berr, want)
}

// A key that matches the path's name at its first and last words but not between them is not the member the path takes,
// at every key length where the words do not cover the key, and a key that matches is taken under each policy of
// repeated keys.
@(test)
find_takes_a_key_by_every_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for width in ([]int{1, 2, 3, 4, 7, 8, 9, 15, 16, 17, 24, 40}) {
		name := strings.repeat("k", width, context.temp_allocator)
		near := make([]u8, width, context.temp_allocator)
		copy(near, name)
		near[width / 2] = 'j'
		for dups in ([]tape.Duplicates{.First, .Last, .Group}) {
			src := strings.concatenate({`{"`, string(near), `":1,"`, name, `":2,"`, string(near), `":3,"`, name, `":4}`}, context.temp_allocator)
			text := "4" if dups == .Last else "2"
			expect_find(t, {src, {tape.Name(name)}, dups, .Found, text})
			nested := strings.concatenate({`{"`, name, `":{"`, string(near), `":5,"`, name, `":6}}`}, context.temp_allocator)
			expect_find(t, {nested, {tape.Name(name), tape.Name(name)}, dups, .Found, "6"})
		}
	}
}
