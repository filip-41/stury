package toml_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

// The facts a TOML text holds are written: a text written from a TOML document reads back with the same values,
// comments and styles.

@(private = "file")
FACT_TEXTS := [?]string{
	"# head\n\na = 1 # one\nb = 0xFF\nc = 1.0\nd = 'lit'\ne = \"\"\"\nml\nx\"\"\"\nf = '''\nmlit\n'''\ng = 1979-05-27T07:32:00Z\n# lead t\n[t] # on t\nx = [1, 2] # xs\n# foot t\n\n[t.u]\ny = {p = 1, q = 2}\n\n[[arr]]\nk = 1\n\n# second\n[[arr]]\nk = 2\n",
	"a.b = 1\na.c = 2\n\"quoted key\" = 3\n'lit key' = 4\n[x.y.z]\nv = true\n",
	"[t]\nx = 1\n# end of t\n\n[u]\ny = 1\n# file end\n",
	"i = inf\nn = nan\nm = -inf\no = 0o17\nb = 0b101\n",
}

// A description of the facts of `doc`: each node's style and tag names and each fact's kind and text.
describe :: proc(doc: ^tape.Document, unordered := false) -> string {
	b: strings.Builder
	lines := make([dynamic]string, context.temp_allocator)
	for _, i in doc.nodes {
		at := tape.Node_Index(i)
		style, _ := tape.fact_name(doc, at, .Style)
		tag, _ := tape.fact_name(doc, at, .Tag)
		line: strings.Builder
		strings.builder_init(&line, context.temp_allocator)
		fmt.sbprintf(&line, "%d %q %q", 0 if unordered else i, style, tag)
		for f in tape.facts_of(doc, at) {
			fmt.sbprintf(&line, " %v:%q", f.kind, string(tape.span_bytes(doc, f.lo, f.n)))
		}
		append(&lines, strings.to_string(line))
	}
	if unordered {
		slice.sort(lines[:])
	}
	for line in lines {
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(test)
toml_facts_are_written_and_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src, k in FACT_TEXTS {
		doc, err := toml.build(transmute([]u8)src)
		defer toml.destroy(&doc)
		testing.expectf(t, err == nil, "%d: %v", k, err)
		text, dropped, werr := toml.write(&doc)
		defer delete(text)
		testing.expectf(t, werr == nil && dropped == {}, "%d: %v %v\n%s", k, werr, dropped, text)
		back, berr := toml.build(text)
		defer toml.destroy(&back)
		testing.expectf(t, berr == nil, "%d: %v\n%s", k, berr, text)
		want, got := describe(&doc), describe(&back)
		defer delete(want)
		defer delete(got)
		testing.expectf(t, want == got, "%d: facts differ\n%s\nwant\n%s\ngot\n%s", k, text, want, got)
	}
}

@(test)
comments_of_other_formats_are_written :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := json.build(transmute([]u8)string("// head\n{\n// lead a\n\"a\": 1, // tail a\n\"b\": {\"c\": 2}\n}\n"), .Jsonc)
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	text, dropped, werr := toml.write(&doc)
	defer delete(text)
	want := "# head\n\n# lead a\na = 1 # tail a\n\n[b]\nc = 2\n"
	testing.expectf(t, werr == nil && dropped == {} && string(text) == want, "%v %v\n%s", werr, dropped, text)
}

@(test)
indent_and_sorted_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, _ := json.build(transmute([]u8)string(`{"b":1,"a":{"z":1,"y":{"q":[{"k":1}]}},"c":{"w":2,"v":3}}`))
	defer json.destroy(&doc)
	text, _, err := toml.write(&doc, .Toml_1_0, {indent = 2, sort_keys = true})
	defer delete(text)
	want := "b = 1\n\n[a]\n  z = 1\n\n  [a.y]\n\n    [[a.y.q]]\n      k = 1\n\n[c]\n  v = 3\n  w = 2\n"
	testing.expectf(t, err == nil && string(text) == want, "%v\n%s", err, text)
	back, berr := toml.build(text)
	defer toml.destroy(&back)
	testing.expect(t, berr == nil)
}
