// The tokens a walk passes and the faults it returns, for small texts.
package toml_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import toml ".."
import walktest "../../walktest"

@(private)
Recorder :: struct {
	text:   []u8,
	out:    strings.Builder,
	skip:   string, // the text of the key whose value the hook skips
	stop:   int, // the number of tokens after which the hook stops, 0 for never
	tokens: int,
}

@(private)
record :: proc "contextless" (r: ^Recorder, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = runtime.default_context()
	text := string(r.text[t.lo:t.lo + u64(t.n)])
	name: string
	switch t.role {
	case .Value:
		name = fmt.tprint(t.kind)
	case .Key:
		name = "Key"
	case .Comment:
		name = "Comment"
	case .Comment_Inline:
		name = "Inline"
	case .Comment_Foot:
		name = "Foot"
	case .Tag, .Anchor, .Alias, .Instruction, .Doctype, .Attribute, .Partial:
		name = "Fact"
	}
	if text != "" {
		fmt.sbprintf(&r.out, "%s:%s ", name, text)
	} else {
		fmt.sbprintf(&r.out, "%s ", name)
	}
	r.tokens += 1
	if r.stop != 0 && r.tokens >= r.stop {
		return s, .Stop
	}
	if t.role == .Key && text == r.skip {
		return s, .Skip
	}
	return s, .Next
}

@(private)
tokens_of :: proc(text: string, spec := toml.Spec.Toml_1_1, skip := "", stop := 0) -> (tokens: string, hi: u64, fault: Maybe(core.Fault)) {
	r := Recorder {
		text = transmute([]u8)text,
		skip = skip,
		stop = stop,
	}
	strings.builder_init(&r.out, context.temp_allocator)
	switch spec {
	case .Toml_1_0:
		hi, fault = toml.walk(r.text, 0, .Toml_1_0, toml.Options{}, &r, nil, record)
	case .Toml_1_1:
		hi, fault = toml.walk(r.text, 0, .Toml_1_1, toml.Options{}, &r, nil, record)
	}
	return strings.trim_space(strings.to_string(r.out)), hi, fault
}

@(test)
tokens_of_a_table_in_document_order :: proc(t: ^testing.T) {
	got, hi, fault := tokens_of("a = 1\n[t]\nb = \"x\"\n[[l]]\nc = true\n[[l]]\nc = false\n")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, hi, 49)
	testing.expect_value(t, got, `Object Key:a Number:1 Key:t Object Key:b String:"x" End Key:l Array Object Key:c True:true End Object Key:c False:false End End End`)
}

@(test)
members_stay_in_first_definition_order :: proc(t: ^testing.T) {
	got, _, fault := tokens_of("[a.b]\nx = 1\n[a]\ny = 2\n")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, got, "Object Key:a Object Key:b Object Key:x Number:1 End Key:y Number:2 End End")
	got, _, fault = tokens_of("a.b = 1\na.c = 2\nd = 3\n")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, got, "Object Key:a Object Key:b Number:1 Key:c Number:2 End Key:d Number:3 End")
}

@(test)
scalars_keep_their_spans :: proc(t: ^testing.T) {
	got, _, fault := tokens_of("a = 0xff\nb = 1_000\nc = 1979-05-27 07:32:00Z\nd = 'lit'\ne = \"\"\"\nm\"\"\"\nf = inf\n\"q.k\" = [1, 2.5]\n")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, got, "Object Key:a Number:0xff Key:b Number:1_000 Key:c String:1979-05-27 07:32:00Z Key:d String:'lit' Key:e String:\"\"\"\nm\"\"\" Key:f Number:inf Key:\"q.k\" Array Number:1 Number:2.5 End End")
}

@(test)
comments_take_their_roles :: proc(t: ^testing.T) {
	got, _, fault := tokens_of("# top\na = 1 # one\n\n# above b\nb = [ # open\n  1, # first\n  # before two\n  2,\n  # last\n]\n[t] # header\n# foot\n")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, got, "Object Comment:# top Key:a Number:1 Inline:# one Comment:# above b Key:b Array Comment:# open Number:1 Inline:# first Comment:# before two Number:2 Foot:# last End Key:t Object End Inline:# header Foot:# foot End")
}

@(test)
skip_and_stop_act_on_tokens :: proc(t: ^testing.T) {
	got, _, fault := tokens_of("a = [1, 2]\nb = 3\n", skip = "a")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, got, "Object Key:a Key:b Number:3 End")
	stopped, hi, _ := tokens_of("a = 1\nb = 2\n", stop = 3)
	testing.expect_value(t, stopped, "Object Key:a Number:1")
	testing.expect_value(t, hi, 5)
}

@(test)
version_1_1_adds_forms :: proc(t: ^testing.T) {
	for text in ([]string{"a = \"\\e\"", "a = \"\\x41\"", "a = 07:32", "a = {b = 1,\n c = 2,\n}", "a = {\n}"}) {
		_, _, fault := tokens_of(text, .Toml_1_1)
		testing.expectf(t, fault == nil, "%q under 1.1: %v", text, fault)
		_, _, fault = tokens_of(text, .Toml_1_0)
		testing.expectf(t, fault != nil, "%q under 1.0", text)
	}
}

@(test)
faults_name_their_byte_and_rule :: proc(t: ^testing.T) {
	Case :: struct {
		text:   string,
		at:     u64,
		kind:   core.Fault_Kind,
		detail: toml.Detail,
	}
	for c in ([]Case {
		{"a = 1\na = 2\n", 6, .Bad_Char, .Duplicate_Key},
		{"[a]\n[a]\n", 5, .Bad_Char, .Redefined_Table},
		{"a = {b = 1}\n[a.c]\n", 13, .Bad_Char, .Extends_Inline},
		{"a = [1]\n[[a]]\n", 10, .Bad_Char, .Extends_Array},
		{"a = 01\n", 5, .Bad_Number, .Leading_Zero},
		{"a = 1__0\n", 5, .Bad_Number, .Bad_Underscore},
		{"a = 9223372036854775808\n", 4, .Bad_Number, .Out_Of_Range},
		{"a = 1979-02-30\n", 12, .Bad_Char, .Bad_Datetime},
		{"a = \"x\n", 6, .Bad_Char, .Line_End_In_String},
		{"a = \"\\q\"\n", 6, .Bad_Escape, .None},
		{"a = \"\\ud800\"\n", 6, .Bad_Escape, .Bad_Codepoint},
		{"a = \"\"\"x", 8, .Truncated, .Open_String},
		{"a = 1\r", 5, .Bad_Char, .Lone_Cr},
		{"a = 1 b\n", 6, .Bad_Char, .Expected_Line_End},
		{"a\n", 1, .Bad_Char, .Expected_Equals},
		{"a = \n", 4, .Bad_Char, .Expected_Value},
		{"a = [1 2]\n", 7, .Bad_Char, .Expected_Comma},
		{"# \xff\n", 2, .Bad_Char, .Invalid_Utf8},
		{"a = {b = 1,}\n", 11, .Bad_Char, .Trailing_Comma},
	}) {
		_, _, fault := tokens_of(c.text, .Toml_1_0)
		f, refused := fault.?
		if testing.expectf(t, refused, "%q", c.text) {
			testing.expectf(t, f.at == c.at && f.kind == c.kind && toml.Detail(f.detail) == c.detail, "%q: got %d %v %v, want %d %v %v", c.text, f.at, f.kind, toml.Detail(f.detail), c.at, c.kind, c.detail)
		}
	}
}

@(test)
nesting_past_the_limit_is_refused :: proc(t: ^testing.T) {
	deep := strings.repeat("[", 3000, context.temp_allocator)
	text := strings.concatenate({"a = ", deep}, context.temp_allocator)
	fault, refused := walktest.fault_of(toml.validate(transmute([]u8)text, .Toml_1_1)).?
	testing.expect(t, refused && fault.kind == .Too_Deep)
	shallow := strings.concatenate({"a = ", strings.repeat("[", 5, context.temp_allocator), strings.repeat("]", 5, context.temp_allocator)}, context.temp_allocator)
	_, refused = walktest.fault_of(toml.validate(transmute([]u8)shallow, .Toml_1_1, toml.Options{max_depth = 4})).?
	testing.expect(t, refused)
	_, refused = walktest.fault_of(toml.validate(transmute([]u8)shallow, .Toml_1_1, toml.Options{max_depth = 6})).?
	testing.expect(t, !refused)
}

@(test)
a_bom_is_skipped_once :: proc(t: ^testing.T) {
	_, hi, fault := tokens_of("\xef\xbb\xbfa = 1\n")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, hi, 9)
	_, _, fault = tokens_of("a = 1\n\xef\xbb\xbfb = 2\n")
	testing.expect(t, fault != nil)
}
