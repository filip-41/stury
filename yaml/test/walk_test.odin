// The tokens a walk passes and the faults it returns, for small texts.
package yaml_tests

import "core:strings"
import "core:testing"
import core "../../core"
import yaml ".."
import walktest "../../walktest"

@(private)
tokens_of :: proc(text: string, opts := yaml.Options{}, skip := "", stop := 0) -> (tokens: string, hi: u64, fault: Maybe(core.Fault)) {
	r := walktest.Token_Log {
		text = transmute([]u8)text,
		skip = skip,
		stop = stop,
	}
	strings.builder_init(&r.out, context.temp_allocator)
	hi, fault = yaml.walk(r.text, 0, .Yaml_1_2, opts, &r, nil, walktest.log_token)
	return walktest.log_line(&r), hi, fault
}

@(test)
tokens_of_a_block_document :: proc(t: ^testing.T) {
	got, hi, fault := tokens_of("a: 1\nb:\n  - x\n  - 'y'\n")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, hi, 22)
	testing.expect_value(t, got, "Object Key:a Plain:1 Key:b Array Plain:x String*:'y' End End")
}

@(test)
comments_take_their_roles :: proc(t: ^testing.T) {
	got, _, fault := tokens_of("# top\n\na: 1 # one\n# above b\nb: 2\n")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, got, "Comment:# top Object Key:a Plain:1 Inline:# one Comment:# above b Key:b Plain:2 End")
	got, _, _ = tokens_of("# top\n\n# above a\na: 1\n")
	testing.expect_value(t, got, "Comment:# top Object Comment:# above a Key:a Plain:1 End")
}

@(test)
properties_come_before_their_node :: proc(t: ^testing.T) {
	got, _, fault := tokens_of("a: &x !!str v\nb: *x\n")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, got, "Object Key:a Anchor:&x Tag:!!str Plain:v Key:b Alias:*x Tag:!!str Plain:v End")
}

@(test)
documents_are_read_one_at_a_time :: proc(t: ^testing.T) {
	src := "a: 1\n---\nb: 2\n...\n"
	r := walktest.Token_Log{text = transmute([]u8)src}
	strings.builder_init(&r.out, context.temp_allocator)
	hi, fault := yaml.walk(r.text, 0, .Yaml_1_2, {}, &r, nil, walktest.log_token)
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, hi, 5)
	hi, fault = yaml.walk(r.text, hi, .Yaml_1_2, {}, &r, nil, walktest.log_token)
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, hi, u64(len(src)))
}

@(test)
skip_and_stop_act_on_tokens :: proc(t: ^testing.T) {
	got, _, fault := tokens_of("a: [1, 2]\nb: 3\n", skip = "a")
	testing.expect_value(t, fault == nil, true)
	testing.expect_value(t, got, "Object Key:a Key:b Plain:3 End")
	stopped, _, _ := tokens_of("a: 1\nb: 2\n", stop = 3)
	testing.expect_value(t, stopped, "Object Key:a Plain:1")
}

@(test)
aliases_replay_their_node_within_the_limit :: proc(t: ^testing.T) {
	text := "a: &a [1, 2, 3]\nb: *a\nc: *a\n"
	_, _, fault := tokens_of(text)
	testing.expect_value(t, fault == nil, true)
	_, _, fault = tokens_of(text, yaml.Options{alias_limit = 12})
	f, bad := fault.?
	testing.expect(t, bad && f.kind == .Too_Wide && f.detail == u8(yaml.Detail.Alias_Limit) && f.at == 25)
	_, _, fault = tokens_of(text, yaml.Options{alias_limit = 24})
	testing.expect_value(t, fault == nil, true)
	_, _, fault = tokens_of("a: *a\n")
	testing.expect(t, fault != nil)
	_, _, fault = tokens_of("a: &a [*a]\n")
	testing.expect(t, fault != nil)
}

// Each level's aliases read the bytes the level below read again, so a short text of nested aliases passes the
// default limit, which validation applies as a build does.
@(test)
nested_aliases_count_what_they_read_again :: proc(t: ^testing.T) {
	text := "a: &a [x, x, x, x, x, x, x, x, x, x]\nb: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a, *a]\nc: &c [*b, *b, *b, *b, *b, *b, *b, *b, *b, *b]\nd: &d [*c, *c, *c, *c, *c, *c, *c, *c, *c, *c]\ne: &e [*d, *d, *d, *d, *d, *d, *d, *d, *d, *d]\nf: &f [*e, *e, *e, *e, *e, *e, *e, *e, *e, *e]\n"
	f, bad := yaml.validate(transmute([]u8)text, .Yaml_1_2).(core.Fault)
	testing.expect(t, bad && f.kind == .Too_Wide && f.detail == u8(yaml.Detail.Alias_Limit))
	testing.expect(t, yaml.validate(transmute([]u8)text, .Yaml_1_2, {alias_limit = 1 << 30}) == nil)
}

@(test)
a_flow_node_cut_by_the_end_faults_its_collection :: proc(t: ^testing.T) {
	for text in ([]string{"{a", "[a", "{a:", "{a: ", "[a:", "[? ", "{? a:", "[&x", "[!t ", "{a: &x", "[a: &x "}) {
		f, bad := yaml.validate(transmute([]u8)text, .Yaml_1_2).(core.Fault)
		testing.expectf(t, bad && f.kind == .Truncated && f.detail == u8(yaml.Detail.Open_Collection), "%q: %v %v", text, f.kind, f.detail)
	}
}

@(test)
nesting_past_the_depth_limit_is_refused :: proc(t: ^testing.T) {
	_, _, fault := tokens_of("[[[[1]]]]", yaml.Options{max_depth = 3})
	testing.expect(t, fault != nil)
	_, _, fault = tokens_of("[[[1]]]", yaml.Options{max_depth = 3})
	testing.expect_value(t, fault == nil, true)
}

@(test)
validate_judges_the_whole_stream :: proc(t: ^testing.T) {
	good := []string{"", "# only a comment\n", "a: 1\n---\nb: 2\n", "\xef\xbb\xbfa: 1\n", "--- >\n x\n\n y\n", "%YAML 1.1\n---\na\n", "? a\n: b\n"}
	for text in good {
		testing.expectf(t, yaml.validate(transmute([]u8)text, .Yaml_1_2) == nil, "%q is a stream", text)
	}
	bad := []string{"a: 1\n b: 2\n", "a: \"x\n", "a: 'x\n", "- a\nb: 1\n", "%YAML 2.0\n---\na\n", "a: \xff\n", "a: \"\\ud800\"\n", "[a, b\n", "a: b: c\n", "a: *x\n", "&a &b c\n", "!<x\n"}
	for text in bad {
		testing.expectf(t, yaml.validate(transmute([]u8)text, .Yaml_1_2) != nil, "%q is refused", text)
	}
}

@(test)
decoded_text_follows_the_quoting :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"plain  words", "plain  words"},
		{"'it''s'", "it's"},
		{"\"a\\tb\\u00e9\\n\"", "a\tb\u00e9\n"},
		{"\"a\\\n   b\"", "ab"},
		{"'a\n\n  b'", "a\nb"},
		{"|\n a\n  b\n", "a\n b\n"},
		{">\n a\n b\n\n c\n", "a b\nc\n"},
		{"|-\n a\n", "a"},
		{"|+\n a\n\n", "a\n\n"},
	}
	for c in cases {
		src := c[0]
		tok: core.Token
		found := false
		r := walktest.Token_Log{text = transmute([]u8)src}
		strings.builder_init(&r.out, context.temp_allocator)
		Probe :: struct {
			tok:   ^core.Token,
			found: ^bool,
		}
		probe := Probe{&tok, &found}
		yaml.walk(r.text, 0, .Yaml_1_2, {}, &probe, nil, proc "contextless" (p: ^Probe, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
			if t.role <= .Key && !p.found^ {
				p.tok^, p.found^ = t, true
			}
			return s, .Next
		})
		buf: [64]u8
		view := core.Token_View{src = r.text}
		got, ok := yaml.token_text(&view, tok, buf[:])
		testing.expectf(t, found && ok && got == c[1], "%q reads as %q, got %q", c[0], c[1], got)
	}
}
