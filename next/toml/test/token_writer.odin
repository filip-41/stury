package toml_tests

import "core:testing"
import "stury:lib/ops/write"
import "stury:testkit"
import "stury:toml"

// The token writer: the tokens of a table are the text `write` gives of its document, a table's own keys before its
// tables, and a sequence no table can follow is refused.

@(test)
tokens_write_a_table :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: toml.Writer
	testing.expect(t, toml.writer_start(&w) == nil)
	steps := [?]struct {
		kind: write.Token_Kind,
		text: string,
	}{{.Object, ""}, {.Key, "t"}, {.Object, ""}, {.Key, "x"}, {.Number, "1"}, {.Close, ""}, {.Key, "a"}, {.String, "s"}, {.Close, ""}}
	for step in steps {
		testing.expect(t, toml.token(&w, step.kind, step.text) == nil)
	}
	text, err := toml.writer_end(&w)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "a = \"s\"\n\n[t]\nx = 1\n", "%v\n%s", err, text)
}

@(test)
a_root_that_is_no_table_is_refused_at_the_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: toml.Writer
	testing.expect(t, toml.writer_start(&w) == nil)
	testing.expect(t, toml.token(&w, .Number, "1") == nil)
	testing.expect(t, toml.token(&w, .Number, "2") != nil)
	_, err := toml.writer_end(&w)
	refused, ok := err.(write.Refused)
	testing.expect(t, ok && refused.why == .No_Spelling)
}
