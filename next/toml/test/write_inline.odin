package toml_tests

import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

// A table a header made under a table of dotted keys is written under its header, and the comments in a table in
// braces are written in a text of TOML 1.1, which gives it a line to a member, and reported dropped in 1.0's.

@(test)
a_header_under_dotted_keys_is_written_as_a_header :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "[fruit]\napple.color = \"red\"\n\n[fruit.apple.texture]\nsmooth = true\n\n[[fruit.apple.seeds]]\nsize = 2\n"
	doc, err := toml.build(transmute([]u8)src, .Toml_1_1)
	defer toml.destroy(&doc)
	testing.expect(t, err == nil)
	text, _, werr := toml.write(&doc, .Toml_1_1)
	defer delete(text)
	testing.expectf(t, werr == nil && string(text) == src, "%v\n%s", werr, text)
}

@(test)
a_table_in_braces_keeps_its_comments_in_toml_1_1 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "a = {# lead\n\tb = 1, # one\n\tc = 2,\n\t# foot\n}\n"
	doc, err := toml.build(transmute([]u8)src, .Toml_1_1)
	defer toml.destroy(&doc)
	testing.expect(t, err == nil)
	text, dropped, werr := toml.write(&doc, .Toml_1_1)
	defer delete(text)
	testing.expectf(t, werr == nil && dropped & tape.COMMENTS == {} && string(text) == "a = {\n# lead\nb = 1, # one\nc = 2,\n# foot\n}\n", "%v %v\n%s", werr, dropped, text)
	// A text of 1.0 cannot break a table in braces, so its comments are reported.
	text10, dropped10, werr10 := toml.write(&doc, .Toml_1_0)
	defer delete(text10)
	testing.expectf(t, werr10 == nil && dropped10 & tape.COMMENTS != {} && string(text10) == "a = {b = 1, c = 2}\n", "%v %v\n%s", werr10, dropped10, text10)
}
