// The tokens a walk gives and the faults it returns, for small texts.
package toml_tests

import "core:strings"
import "core:testing"
import "core:time"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

@(test)
tokens_of_a_table_come_in_document_order :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, hi, err := tokens_of("a = 1\n[t]\nb = \"x\"\n[[l]]\nc = true\n[[l]]\nc = false\n")
	expect_nil(t, err)
	testing.expect_value(t, hi, 49)
	testing.expect_value(t, got, `Object Key:a Number:1 Key:t Object Key:b String:x End Key:l Array Object Key:c True:true End Object Key:c False:false End End End`)
}

@(test)
members_stay_in_first_definition_order :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, err := tokens_of("[a.b]\nx = 1\n[a]\ny = 2\n")
	expect_nil(t, err)
	testing.expect_value(t, got, "Object Key:a Object Key:b Object Key:x Number:1 End Key:y Number:2 End End")
	got, _, err = tokens_of("a.b = 1\na.c = 2\nd = 3\n")
	expect_nil(t, err)
	testing.expect_value(t, got, "Object Key:a Object. Key:b Number:1 Key:c Number:2 End Key:d Number:3 End")
	got, _, err = tokens_of("[x]\na = 1\n[y]\nb = 2\n[x.z]\nc = 3\n")
	expect_nil(t, err)
	testing.expect_value(t, got, "Object Key:x Object Key:a Number:1 Key:z Object Key:c Number:3 End End Key:y Object Key:b Number:2 End End")
}

@(test)
scalars_keep_their_spans :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, err := tokens_of("a = 0xff\nb = 1_000\nc = 1979-05-27 07:32:00Z\nd = 'lit'\ne = \"\"\"\nm\"\"\"\nf = inf\n\"q.k\" = [1, 2.5]\n")
	expect_nil(t, err)
	testing.expect_value(t, got, "Object Key:a Number:0xff Key:b Number:1_000 Key:c String:1979-05-27 07:32:00Z Key:d String:lit Key:e String:m Key:f Number:inf Key:q.k Array~ Number:1 Number:2.5 End End")
}

@(test)
containers_keep_their_style :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, err := tokens_of("a = {b = [1]}\nc.d = 1\n[e]\n[[f]]\n")
	expect_nil(t, err)
	testing.expect_value(t, got, "Object Key:a Object~ Key:b Array~ Number:1 End End Key:c Object. Key:d Number:1 End Key:e Object End Key:f Array Object End End End")
}

@(test)
comments_take_their_roles :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, err := tokens_of("# top\na = 1 # one\n\n# above b\nb = [ # open\n  1, # first\n  # before two\n  2,\n  # last\n]\n[t] # header\n# foot\n")
	expect_nil(t, err)
	testing.expect_value(t, got, "Object Comment:# top Key:a Number:1 Inline:# one Comment:# above b Key:b Array~ Comment:# open Number:1 Inline:# first Comment:# before two Number:2 Foot:# last End Key:t Object Foot:# foot End Inline:# header End")
	got, _, _ = tokens_of("# head\n\n# above a\na = 1\n")
	testing.expect_value(t, got, "Comment:# head Object Comment:# above a Key:a Number:1 End")
}

@(test)
skip_and_stop_act_on_tokens :: proc(t: ^testing.T) {
	testkit.deadline(t)
	got, _, err := tokens_of("a = [1, 2]\nb = 3\n", skip = "a")
	expect_nil(t, err)
	testing.expect_value(t, got, "Object Key:a Array~ End Key:b Number:3 End")
	stopped, hi, _ := tokens_of("a = 1\nb = 2\n", stop = 3)
	testing.expect_value(t, stopped, "Object Key:a Number:1")
	testing.expect_value(t, hi, 5)
}

// A walk that may stop reads the statements its tokens need, so a stop before a fault gives no error.
@(test)
a_stop_reads_only_the_statements_before_it :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := "[[l]]\na = 1\n[[l]]\na = 2\n[[l]]\na = =\n"
	got, _, err := tokens_of(text, stop = 7)
	expect_nil(t, err)
	testing.expect_value(t, got, "Object Key:l Array Object Key:a Number:1 End")
	_, _, err = tokens_of(text)
	testing.expect_value(t, testkit.code_of(err), "expected_value")
}

@(test)
version_1_1_adds_forms :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for text in ([]string{"a = \"\\e\"", "a = \"\\x41\"", "a = 07:32", "a = {b = 1,\n c = 2,\n}", "a = {\n}"}) {
		_, _, err := tokens_of(text, .Toml_1_1)
		testing.expectf(t, err == nil, "%q under 1.1: %v", text, err)
		_, _, err = tokens_of(text, .Toml_1_0)
		testing.expectf(t, err != nil, "%q under 1.0", text)
	}
}

@(test)
faults_name_their_byte_and_rule :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		text: string,
		at:   u64,
		kind: tape.Fault_Kind,
		code: string,
	}
	for c in ([]Case {
		{"a = 1\na = 2\n", 6, .Bad_Char, "duplicate_key"},
		{"'a' = 1\n\"a\" = 2\n", 8, .Bad_Char, "duplicate_key"},
		{"[a]\n[a]\n", 5, .Bad_Char, "redefined_table"},
		{"a.b = 1\n[a]\n", 9, .Bad_Char, "redefined_table"},
		{"a = {b = 1}\n[a.c]\n", 13, .Bad_Char, "extends_inline"},
		{"a = {b = 1}\na.c = 2\n", 12, .Bad_Char, "extends_inline"},
		{"a = [1]\n[[a]]\n", 10, .Bad_Char, "extends_array"},
		{"a = 1\n[a.b]\n", 7, .Bad_Char, "not_table"},
		{"a = 01\n", 5, .Bad_Number, "leading_zero"},
		{"a = 1__0\n", 5, .Bad_Number, "bad_underscore"},
		{"a = 9223372036854775808\n", 4, .Bad_Number, "out_of_range"},
		{"a = 1979-02-30\n", 12, .Bad_Char, "bad_datetime"},
		{"a = \"x\n", 6, .Bad_Char, "line_end_in_string"},
		{"a = \"\\q\"\n", 6, .Bad_Escape, "bad_escape"},
		{"a = \"\\ud800\"\n", 6, .Bad_Escape, "bad_codepoint"},
		{"a = \"\"\"x", 8, .Truncated, "open_string"},
		{"a = '''x''''''\n", 13, .Bad_Char, "bad_quotes"},
		{"a = 1\r", 5, .Bad_Char, "lone_cr"},
		{"a = 1 b\n", 6, .Bad_Char, "expected_line_end"},
		{"a = 1b\n", 5, .Bad_Number, "bad_number"},
		{"a = trueb\n", 8, .Bad_Char, "after_value"},
		{"a\n", 1, .Bad_Char, "expected_equals"},
		{"= 1\n", 0, .Bad_Char, "expected_key"},
		{"a = \n", 4, .Bad_Char, "expected_value"},
		{"a = [1 2]\n", 7, .Bad_Char, "expected_comma"},
		{"[a\n", 2, .Bad_Char, "expected_close"},
		{"# \xff\n", 2, .Bad_Char, "invalid_utf8"},
		{"# \x01\n", 2, .Bad_Char, "control_char"},
		{"a = \"\xe2\x82", 7, .Truncated, "cut_utf8"},
		{"a = {b = 1,}\n", 11, .Bad_Char, "trailing_comma"},
	}) {
		_, _, err := tokens_of(c.text, .Toml_1_0)
		f, refused := err.(tape.Fault)
		if testing.expectf(t, refused, "%q: %v", c.text, err) {
			testing.expectf(t, f.at == c.at && f.kind == c.kind && testkit.code_of(err) == c.code, "%q: got %d %v %q, want %d %v %q", c.text, f.at, f.kind, testkit.code_of(err), c.at, c.kind, c.code)
		}
		testing.expectf(t, testkit.same_refusal(toml.validate(transmute([]u8)c.text), err), "%q: validate gives %v", c.text, toml.validate(transmute([]u8)c.text))
	}
}

@(test)
a_message_gives_the_line_and_column :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a = 1\nb = [1 2]\n")
	buf: [128]u8
	testing.expect_value(t, tape.error_message(buf[:], toml.validate(src), src), "2:8: Expected a comma or a close")
	open := transmute([]u8)string("[t]\nk = 'v'\nj = \"\"\"\nopen")
	testing.expect_value(t, tape.error_message(buf[:], toml.validate(open), open), "4:5: Unfinished string")
}

@(test)
nesting_past_the_limit_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	deep := strings.concatenate({"a = ", strings.repeat("[", 20_000, context.temp_allocator)}, context.temp_allocator)
	x, over := toml.validate(transmute([]u8)deep, .Toml_1_1).(tape.Exceeded)
	testing.expect(t, over && x.kind == .Depth)
	shallow := transmute([]u8)strings.concatenate({"a = ", strings.repeat("[", 5, context.temp_allocator), strings.repeat("]", 5, context.temp_allocator)}, context.temp_allocator)
	x, over = toml.validate(shallow, .Toml_1_1, {budget = {depth = 5}}).(tape.Exceeded)
	testing.expect(t, over && x.kind == .Depth && x.at == 8)
	expect_nil(t, toml.validate(shallow, .Toml_1_1, {budget = {depth = 6}}))
	headers := transmute([]u8)string("[a.b.c]\n")
	_, over = toml.validate(headers, .Toml_1_0, {budget = {depth = 3}}).(tape.Exceeded)
	testing.expect(t, over)
	expect_nil(t, toml.validate(headers, .Toml_1_0, {budget = {depth = 4}}))
}

// A table `depth` levels deep, then `elements` elements of an array of tables, each of which may seal what the walk
// holds open.
@(private = "file")
chain_then_elements :: proc(depth, elements: int) -> []u8 {
	return transmute([]u8)strings.concatenate({"[a", strings.repeat(".a", depth - 1, context.temp_allocator), "]\n", strings.repeat("[[b]]\n", elements, context.temp_allocator)}, context.temp_allocator)
}

// The least time over three runs of a find of the deep table's absent member and a scan of a path into the chain.
@(private = "file")
time_chain_reads :: proc(t: ^testing.T, depth: int, text: []u8) -> time.Duration {
	path := make([]tape.Step, depth + 1, context.temp_allocator)
	for &s in path {
		s = tape.Name("a")
	}
	path[depth] = tape.Name("z")
	d, _ := tape.demand_of({{tape.Name("a"), tape.Name("a")}})
	defer tape.destroy(&d)
	least := max(time.Duration)
	for _ in 0 ..< 3 {
		start := time.tick_now()
		answer, err := toml.find(text, path)
		doc, serr := toml.scan(text, &d)
		least = min(least, time.tick_since(start))
		tape.destroy(&doc)
		testing.expect(t, err == nil && serr == nil && answer.outcome == .Missing)
	}
	return least
}

// The walk keeps whether each open container is sealed, so a new element of an array of tables costs the same however
// deep the walk is.
@(test)
elements_seal_open_tables_at_any_depth :: proc(t: ^testing.T) {
	testkit.deadline(t)
	ELEMENTS :: 50_000
	deep := time_chain_reads(t, 4_000, chain_then_elements(4_000, ELEMENTS))
	shallow := time_chain_reads(t, 1, chain_then_elements(1, ELEMENTS))
	testing.expectf(t, deep < 4 * shallow, "%v deep against %v shallow", deep, shallow)
}

@(test)
a_bom_is_skipped_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	_, hi, err := tokens_of("\xef\xbb\xbfa = 1\n")
	expect_nil(t, err)
	testing.expect_value(t, hi, 9)
	_, _, err = tokens_of("a = 1\n\xef\xbb\xbfb = 2\n")
	testing.expect(t, err != nil)
}
