package json_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// Every read through a format handle alone gives what the spec's own call gives.
@(test)
format_reads_through_its_handle :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in json.Spec {
		f := json.as(spec)
		text := transmute([]u8)string(`{"a": [1, {"b": 2}], /* c */ "d": 3}` if spec != .Json else `{"a": [1, {"b": 2}], "d": 3}`)
		testing.expect_value(t, f.validate(f, text, {}, context.allocator), nil)
		doc, err := f.build(f, text, {}, context.allocator)
		defer tape.destroy(&doc)
		testing.expect(t, err == nil && len(doc.nodes) == 9 && doc.format == f)
		found, ferr := f.find(f, text, {tape.Name("a"), tape.Index(1), tape.Name("b")}, {}, {}, context.allocator)
		testing.expect(t, ferr == nil && found.outcome == .Found && text[found.lo] == '2')
		d, _ := tape.demand_of([][]tape.Step{{tape.Name("d")}})
		defer tape.destroy(&d)
		part, serr := f.scan(f, text, &d, {}, {}, context.allocator)
		defer tape.destroy(&part)
		at, p, ok := tape.answer(tape.Reader{&part, nil}, 0, 0)
		testing.expect(t, serr == nil && ok && p == .Found && part.src[part.nodes[at].lo] == '3')
		_, bad := f.build(f, transmute([]u8)string("[1,"), {}, context.allocator)
		testing.expect(t, bad != nil)
	}
}

// A container's close end is the byte past its bracket, past the closes of the containers it ends with and the white
// space, commas and comments before them.
@(test)
format_finds_a_close_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		spec:   json.Spec,
		src:    string,
		steps:  []tape.Step,
		closed: string, // the text up to the close end
	}
	cases := []Case{
		{.Json, `[[1], 2]`, {tape.Index(0)}, `[[1]`},
		{.Json, `{"a": [[[]] ] , "b": 1}`, {tape.Name("a")}, `{"a": [[[]] ]`},
		{.Json, `[{"a": "x"} ]`, {tape.Index(0)}, `[{"a": "x"}`},
		{.Json, `[[{}]]`, {tape.Index(0)}, `[[{}]`},
		{.Jsonc, `[[1, /* ] */ // ]
 ], 2]`, {tape.Index(0)}, "[[1, /* ] */ // ]\n ]"},
		{.Json5, `[{a: 'x',}, 1]`, {tape.Index(0)}, `[{a: 'x',}`},
		{.Json, ` [1] `, {}, ` [1]`},
	}
	for c in cases {
		doc, err := json.build(transmute([]u8)c.src, c.spec)
		defer tape.destroy(&doc)
		r := tape.Reader{&doc, nil}
		at, p := tape.root(r)
		for step in c.steps {
			#partial switch s in step {
			case tape.Name:
				at, p = tape.member(r, at, string(s))
			case tape.Index:
				at, p = tape.element(r, at, int(s))
			}
		}
		testing.expectf(t, err == nil && p == .Found, "%q: %v %v", c.src, err, p)
		end, ok := doc.format.close_end(&doc, at)
		testing.expectf(t, ok && c.src[:end] == c.closed, "%q: %q", c.src, c.src[:end])
	}
}

// The node readers a binding takes: a key's span and escape, a number's form and exact value, and whether a text is
// ASCII.
@(test)
format_node_readers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := transmute([]u8)string(`{"k\u00e9": -12.50e3, "plain": 18446744073709551615, "x": -9223372036854775808, "y": "\u0041b", "z": 1.5}`)
	doc, err := json.build(text)
	defer tape.destroy(&doc)
	testing.expect(t, err == nil)
	r := tape.Reader{&doc, nil}
	span, escaped := tape.key_raw(doc.src, doc.nodes[1])
	testing.expect(t, string(span) == `k\u00e9` && escaped)
	span, escaped = tape.key_raw(doc.src, doc.nodes[3])
	testing.expect(t, string(span) == "plain" && !escaped)
	form, ok := tape.number_form(doc.nodes[2])
	testing.expect(t, ok && form.int_digits == 2 && form.frac_digits == 2 && form.exponent && !form.point && form.kind == 0)
	_, ok = tape.number_form(doc.nodes[1])
	testing.expect(t, !ok)
	big, _ := tape.member(r, tape.ROOT, "plain")
	_, u, unsigned, exact := tape.number_exact(doc.format, doc.src, doc.nodes[big])
	testing.expect(t, exact && unsigned && u == max(u64))
	low, _ := tape.member(r, tape.ROOT, "x")
	i, _, signed_unsigned, low_exact := tape.number_exact(doc.format, doc.src, doc.nodes[low])
	testing.expect(t, low_exact && !signed_unsigned && i == min(i64))
	half, _ := tape.member(r, tape.ROOT, "z")
	_, _, _, half_exact := tape.number_exact(doc.format, doc.src, doc.nodes[half])
	testing.expect(t, !half_exact)
	buf: [16]u8
	ascii, fits := tape.text_is_ascii(doc.format, doc.src, doc.nodes[1], buf[:])
	testing.expect(t, fits && !ascii)
	y, _ := tape.member(r, tape.ROOT, "y")
	ascii, fits = tape.text_is_ascii(doc.format, doc.src, doc.nodes[y], buf[:])
	testing.expect(t, fits && ascii)
	ascii, fits = tape.text_is_ascii(doc.format, doc.src, doc.nodes[3], buf[:])
	testing.expect(t, fits && ascii)
}

// The byte past the bracket that closes the container opened at `lo`, found by reading the text as its grammar does:
// strings and comments hold brackets that do not count, and a `//` comment ends at LF or CR, and in JSON5 at U+2028 or
// U+2029.
matching_close :: proc(src: []u8, lo: u64, json5: bool) -> u64 {
	depth := 0
	for i := int(lo); i < len(src); i += 1 {
		switch src[i] {
		case '"', '\'':
			quote := src[i]
			for i += 1; i < len(src) && src[i] != quote; i += 1 {
				i += int(src[i] == '\\')
			}
		case '/':
			if i + 1 < len(src) && src[i + 1] == '*' {
				for i += 2; i + 1 < len(src) && !(src[i] == '*' && src[i + 1] == '/'); i += 1 {
				}
				i += 1
			} else if i + 1 < len(src) && src[i + 1] == '/' {
				for i += 2; i < len(src) && src[i] != '\n' && src[i] != '\r' && !(json5 && i + 2 < len(src) && src[i] == 0xe2 && src[i + 1] == 0x80 && src[i + 2] & 0xfe == 0xa8); i += 1 {
				}
				i -= 1
			}
		case '[', '{':
			depth += 1
		case ']', '}':
			depth -= 1
			if depth == 0 {
				return u64(i + 1)
			}
		}
	}
	return u64(len(src))
}

// The close end of every container of a text, the root included, is the byte past its matching bracket, in texts with
// comments that hold brackets, quotes, stars and every line end.
@(test)
format_close_ends_match_brackets :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xc105e)
	check :: proc(t: ^testing.T, src: []u8, spec: json.Spec, name: string, checked: ^int) {
		doc, err := json.build(src, spec)
		defer tape.destroy(&doc)
		if err != nil {
			return
		}
		for node, i in doc.nodes {
			if node.kind < .Array || node.role != .Value {
				continue
			}
			checked^ += 1
			got, ok := doc.format.close_end(&doc, tape.Node_Index(i))
			want := matching_close(src, node.lo, spec == .Json5)
			testing.expectf(t, ok && got == want, "%s %v: container at %d closes at %d, want %d", name, spec, node.lo, got, want)
		}
	}
	checked := 0
	files := corpus_files()
	defer delete(files)
	for file in files {
		check(t, file.data, file.spec, file.name, &checked)
	}
	for f in FLAVORS {
		if f.spec == .Json {
			continue
		}
		for _ in 0 ..< testkit.rounds(150) {
			src := random_text(f)
			check(t, src, f.spec, "generated", &checked)
		}
	}
	testing.expectf(t, checked > 2000, "%d containers", checked)
}

// A container's close end is past its bracket when a `//` comment before it ends at CR, and in JSON5 at U+2028 or
// U+2029, as the walk reads the comment. In JSONC U+2028 ends no comment.
@(test)
format_close_ends_follow_line_comments :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := [?]struct {
		spec: json.Spec,
		src:  string,
	}{{.Jsonc, "[[1 // a\r], 2]"}, {.Json5, "[[1 // a\r], 2]"}, {.Json5, "[[1 // a\u2028], 2]"}, {.Json5, "[[1 // a\u2029], 2]"}, {.Jsonc, "[[1 // a\u2028]\n], 2]"}}
	for c in cases {
		doc, err := json.build(transmute([]u8)c.src, c.spec)
		defer tape.destroy(&doc)
		testing.expectf(t, err == nil, "%q: %v", c.src, err)
		end, ok := doc.format.close_end(&doc, 1)
		testing.expect(t, ok && end == u64(strings.index(c.src, "], 2]") + 1))
	}
}
