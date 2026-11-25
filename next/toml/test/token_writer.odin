package toml_tests

import "core:testing"
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
		kind: toml.Token_Kind,
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
tokens_quote_non_bare_keys_refuse_u64_and_dups :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Non-bare keys ("a b", "", "a.b") must be quoted and validate as TOML.
	w: toml.Writer
	testing.expect(t, toml.writer_start(&w) == nil)
	steps := [?]struct {
		kind: toml.Token_Kind,
		text: string,
	}{{.Object, ""}, {.Key, "a b"}, {.Number, "1"}, {.Key, ""}, {.Number, "2"}, {.Key, "a.b"}, {.Number, "3"}, {.Close, ""}}
	for s in steps {
		testing.expect(t, toml.token(&w, s.kind, s.text) == nil)
	}
	text, err := toml.writer_end(&w)
	defer delete(text)
	want := "\"a b\" = 1\n\"\" = 2\n\"a.b\" = 3\n"
	testing.expectf(t, err == nil && string(text) == want && toml.validate(text) == nil, "%v\n%q", err, text)

	// Integer outside i64 (max(u64)) must be refused.
	testing.expect(t, toml.writer_start(&w) == nil)
	for s in ([?]struct{kind: toml.Token_Kind, text: string}{{.Object, ""}, {.Key, "big"}, {.Number, "18446744073709551615"}, {.Close, ""}}) {
		testing.expect(t, toml.token(&w, s.kind, s.text) == nil)
	}
	_, uerr := toml.writer_end(&w)
	r, ok := uerr.(toml.Refused)
	testing.expectf(t, ok && r.why == .No_Spelling, "max u64: %v", uerr)

	// Duplicate keys in token stream must be refused.
	testing.expect(t, toml.writer_start(&w) == nil)
	for s in ([?]struct{kind: toml.Token_Kind, text: string}{{.Object, ""}, {.Key, "x"}, {.Number, "1"}, {.Key, "x"}, {.Number, "2"}, {.Close, ""}}) {
		testing.expect(t, toml.token(&w, s.kind, s.text) == nil)
	}
	_, derr := toml.writer_end(&w)
	dr, dok := derr.(toml.Refused)
	testing.expectf(t, dok && dr.why == .No_Spelling, "dup key: %v", derr)
}

@(test)
a_root_that_is_no_table_is_refused_at_the_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: toml.Writer
	testing.expect(t, toml.writer_start(&w) == nil)
	testing.expect(t, toml.token(&w, .Number, "1") == nil)
	testing.expect(t, toml.token(&w, .Number, "2") != nil)
	_, err := toml.writer_end(&w)
	refused, ok := err.(toml.Refused)
	testing.expect(t, ok && refused.why == .No_Spelling)
}
