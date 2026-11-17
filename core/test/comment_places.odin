// The law that a fact keeps its place through a write to another format that holds it: a comment, a number's
// spelling, a collection's layout, and a document's markers in its own format.
package core_test

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import core ".."
import write "../write"
import walktest "../../walktest"
import html "../../html"
import json "../../json"
import toml "../../toml"
import xml "../../xml"
import yaml "../../yaml"

// A text of each format with a comment in each place the format has: the text's head `h`, before the first member `c`,
// after a member on its line `i`, in an empty container `z`, and at the end of a container `f`.
@(private = "file")
Placed :: struct {
	name: string,
	as:   core.As,
	src:  string,
}

// A comment as the law compares it: the path of names to its node, its role and its body without the markers.
@(private = "file")
Place :: struct {
	path: string,
	role: core.Role,
	body: string,
}

@(test)
comments_keep_their_place_in_every_format :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	texts := []Placed {
		{"jsonc", json.as(.Jsonc), "// h\n\n{\"r\": {\n  // c\n  \"a\": 1, // i\n  \"b\": 2\n  // f\n}}\n"},
		{"yaml", yaml.as(.Yaml_1_2), "# h\n\nr:\n  # c\n  a: 1 # i\n  b: 2\n  # f\n"},
		{"toml", toml.as(.Toml_1_0), "# h\n\n[r]\n# c\na = 1 # i\nb = 2\n# f\n"},
		{"xml", xml.as(.Xml), "<!-- h -->\n\n<r>\n<!-- c -->\n<a>1</a> <!-- i -->\n<b>2</b>\n<!-- f -->\n</r>\n"},
		{"html", html.as(.Document), "<!-- h -->\n\n<r>\n<!-- c -->\n<a>1</a> <!-- i -->\n<b>2</b>\n<!-- f -->\n</r>\n"},
	}
	keep_places(t, texts, {{"", .Comment, "h"}, {"r.a", .Comment, "c"}, {"r.a", .Comment_Inline, "i"}, {"r", .Comment_Foot, "f"}})
	// An empty object is an empty element in no markup format, so each family keeps the comment of its own empty value.
	keep_places(t, {{"jsonc", json.as(.Jsonc), "{\"r\": {\"e\": {\n  // z\n}}}\n"}, {"json5", json.as(.Json5), "{r: {e: {\n  // z\n}}}\n"}, {"yaml", yaml.as(.Yaml_1_2), "r:\n  e: {\n    # z\n    }\n"}, {"toml", toml.as(.Toml_1_0), "[r.e]\n# z\n"}}, {{"r.e", .Comment_Foot, "z"}})
	keep_places(t, {{"jsonc", json.as(.Jsonc), "{\"r\": {\"l\": [\n  // z\n]}}\n"}, {"json5", json.as(.Json5), "{r: {l: [\n  // z\n]}}\n"}, {"yaml", yaml.as(.Yaml_1_2), "r:\n  l: [\n    # z\n    ]\n"}, {"toml", toml.as(.Toml_1_0), "[r]\nl = [\n  # z\n]\n"}}, {{"r.l", .Comment_Foot, "z"}})
	// A comment on the line of a collection's key is the collection's inline comment, which YAML writes there.
	keep_places(t, {{"jsonc", json.as(.Jsonc), "{\"r\": {\"l\": [\n  1\n] // k\n}}\n"}, {"yaml", yaml.as(.Yaml_1_2), "r:\n  l: # k\n    - 1\n"}}, {{"r.l", .Comment_Inline, "k"}})
	keep_places(t, {{"xml", xml.as(.Xml), "<r><e><!-- z --></e></r>"}, {"html", html.as(.Document), "<r><e><!-- z --></e></r>"}}, {{"r.e", .Comment_Foot, "z"}})
}

// Checks that each of `texts` reads its comments at `want`, and that a pretty and a compact write as each text's format reads back
// at the same places, every one unless the write counts it dropped.
@(private = "file")
keep_places :: proc(t: ^testing.T, texts: []Placed, want: []Place) {
	for x in texts {
		doc, err := core.build(transmute([]u8)x.src, x.as, allocator = context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s: %v", x.name, err) {
			continue
		}
		from := places(&doc)
		for p in from {
			testing.expectf(t, slice.contains(want, p), "%s reads %v, which is not where its text puts it", x.name, p)
		}
		for p in want {
			testing.expectf(t, slice.contains(from, p), "%s does not read %v", x.name, p)
		}
		for opts in ([]core.Write_Options{core.PRETTY, {}}) {
			for y in texts {
				text, dropped, werr := core.write(&doc, opts, y.as, allocator = context.temp_allocator)
				if werr != nil {
					// HTML refuses a tree that it would read back as another, and its implied empty head is a null that
					// TOML has no spelling for.
					testing.expectf(t, y.name == "html" || x.name == "html" && y.name == "toml", "%s as %s: %v", x.name, y.name, werr)
					continue
				}
				back, berr := core.build(text, y.as, allocator = context.temp_allocator)
				if !testing.expectf(t, berr == nil, "%s as %s: %v\n%s", x.name, y.name, berr, string(text)) {
					continue
				}
				to := places(&back)
				for p in to {
					testing.expectf(t, slice.contains(from, p), "%s as %s reads %v, which %s does not hold\n%s", x.name, y.name, p, x.name, string(text))
				}
				if dropped == 0 {
					for p in from {
						testing.expectf(t, slice.contains(to, p), "%s as %s loses %v\n%s", x.name, y.name, p, string(text))
					}
				}
			}
		}
	}
}

// The comments of `doc` with the names to their nodes. A markup document's implied `html` and `body` are no names.
@(private = "file")
places :: proc(doc: ^core.Document) -> []Place {
	paths := make([]string, len(doc.nodes), context.temp_allocator)
	name_nodes(doc, core.ROOT, "", paths)
	out: [dynamic]Place
	out.allocator = context.temp_allocator
	for i in 0 ..< len(doc.nodes) {
		for role in ([]core.Role{.Comment, .Comment_Inline, .Comment_Foot}) {
			it := core.facts_of(doc, core.Node_Index(i), role)
			for raw in core.fact_next(&it) {
				body := raw
				for marker in ([]string{"<!--", "-->", "//", "/*", "*/", "#"}) {
					body, _ = strings.replace_all(body, marker, "", context.temp_allocator)
				}
				append(&out, Place{paths[i], role, strings.trim_space(body)})
			}
		}
	}
	return out[:]
}

@(private = "file")
name_nodes :: proc(doc: ^core.Document, node: core.Node_Index, path: string, paths: []string) {
	paths[node] = path
	if doc.nodes[node].kind != .Object {
		return
	}
	buf: [64]u8
	it := core.pairs(doc, node)
	for key, value in core.pair_next(&it) {
		name, _ := core.text(doc, key, buf[:])
		if path == "" && name == "html" || path == "" && name == "body" {
			name_nodes(doc, value, "", paths)
		} else {
			name_nodes(doc, value, fmt.tprintf("%s.%s", path, name) if path != "" else strings.clone(name, context.temp_allocator), paths)
		}
	}
}

// A text with one member `a` whose number spelling each other format of a list holds.
@(private = "file")
Spelled :: struct {
	name: string,
	as:   core.As,
	src:  string,
}

@(test)
number_spellings_keep_their_form_in_every_format :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	keep_spelling(t, {{"toml", toml.as(.Toml_1_0), "a = 0xFF\n"}, {"yaml", yaml.as(.Yaml_1_2), "a: 0xFF\n"}, {"json5", json.as(.Json5), "{a: 0xFF}"}}, "hex", "0xFF")
	keep_spelling(t, {{"toml", toml.as(.Toml_1_0), "a = 0o17\n"}, {"yaml", yaml.as(.Yaml_1_2), "a: 0o17\n"}}, "octal", "0o17")
	keep_spelling(t, {{"toml", toml.as(.Toml_1_0), "a = +1\n"}, {"yaml", yaml.as(.Yaml_1_2), "a: +1\n"}, {"json5", json.as(.Json5), "{a: +1}"}}, "", "+1")
	keep_spelling(t, {{"yaml", yaml.as(.Yaml_1_2), "a: 5.\n"}, {"json5", json.as(.Json5), "{a: 5.}"}}, "", "5.")
	keep_spelling(t, {{"yaml", yaml.as(.Yaml_1_2), "a: .5\n"}, {"json5", json.as(.Json5), "{a: .5}"}}, "", ".5")
}

@(test)
collection_layouts_keep_their_style_in_every_format :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	keep_spelling(t, {{"toml", toml.as(.Toml_1_0), "a = { b = 1 }\n"}, {"yaml", yaml.as(.Yaml_1_2), "a: {b: 1}\n"}}, "flow", "")
	keep_spelling(t, {{"toml", toml.as(.Toml_1_0), "a = [1, 2]\n"}, {"yaml", yaml.as(.Yaml_1_2), "a: [1, 2]\n"}}, "flow", "")
	keep_spelling(t, {{"toml", toml.as(.Toml_1_0), "[a]\nb = 1\n"}, {"yaml", yaml.as(.Yaml_1_2), "a:\n  b: 1\n"}}, "block", "")
	keep_spelling(t, {{"toml", toml.as(.Toml_1_0), "[[a]]\nb = 1\n"}, {"yaml", yaml.as(.Yaml_1_2), "a:\n  - b: 1\n"}}, "block", "")
}

@(test)
markers_stay_in_their_own_format :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	texts := [?]Spelled{{"%YAML 1.2", yaml.as(.Yaml_1_2), "%YAML 1.2\n---\na: 1\n...\n"}, {"---", yaml.as(.Yaml_1_2), "---\na: 1\n"}, {`<?xml version="1.0" encoding="UTF-8"?>`, xml.as(.Xml), "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a>1</a>\n"}}
	for x in texts {
		doc, err := core.build(transmute([]u8)x.src, x.as, allocator = context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s: %v", x.name, err) {
			continue
		}
		out, _, werr := core.write(&doc, core.PRETTY, x.as, allocator = context.temp_allocator)
		back, berr := core.build(out, x.as, allocator = context.temp_allocator)
		if !testing.expectf(t, werr == nil && berr == nil, "%s: %v %v", x.name, werr, berr) {
			continue
		}
		it := core.facts_of(&back, core.ROOT, .Directive)
		first, _ := core.fact_next(&it)
		testing.expectf(t, first == x.name, "%s is written back as %q", x.name, string(out))
	}
}

// Checks that member `a` of each of `texts` is spelled `text` with the `style`, each unless it is empty, after a write
// as each other text's format.
@(private = "file")
keep_spelling :: proc(t: ^testing.T, texts: []Spelled, style, text: string) {
	for x in texts {
		doc, err := core.build(transmute([]u8)x.src, x.as, allocator = context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s: %v", x.name, err) {
			continue
		}
		for y in texts {
			out, _, werr := core.write(&doc, core.PRETTY, y.as, allocator = context.temp_allocator)
			if !testing.expectf(t, werr == nil, "%s as %s: %v", x.name, y.name, werr) {
				continue
			}
			back, berr := core.build(out, y.as, allocator = context.temp_allocator)
			if !testing.expectf(t, berr == nil, "%s as %s: %v\n%s", x.name, y.name, berr, string(out)) {
				continue
			}
			a, found := core.member(&back, core.ROOT, "a")
			testing.expectf(t, found && (text == "" || string(core.span(&back, a)) == text), "%s as %s spells a otherwise\n%s", x.name, y.name, string(out))
			if style != "" {
				got, _ := core.fact_value(&back, a, .Style)
				testing.expectf(t, got.text == style, "%s as %s: the style of a is %q", x.name, y.name, got.text)
			}
		}
	}
}

// A lead comment that a token writer meets in an empty container is that container's foot.
@(test)
a_token_comment_in_an_empty_container_is_its_foot :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Writer :: struct {
		name: string,
		as:   core.As,
		init: proc(w: ^write.Tokens),
	}
	writers := []Writer {
		{"jsonc", json.as(.Jsonc), proc(w: ^write.Tokens) {json.tokens_init(w, .Jsonc, write = core.PRETTY, allocator = context.temp_allocator)}},
		{"json5", json.as(.Json5), proc(w: ^write.Tokens) {json.tokens_init(w, .Json5, write = core.PRETTY, allocator = context.temp_allocator)}},
		{"yaml", yaml.as(.Yaml_1_2), proc(w: ^write.Tokens) {yaml.tokens_init(w, .Yaml_1_2, write = core.PRETTY, allocator = context.temp_allocator)}},
		{"toml", toml.as(.Toml_1_0), proc(w: ^write.Tokens) {toml.tokens_init(w, .Toml_1_0, write = core.PRETTY, allocator = context.temp_allocator)}},
	}
	for x in writers {
		for object in ([]bool{true, false}) {
			w: write.Tokens
			x.init(&w)
			write.open_object(&w)
			write.key(&w, "r")
			write.open_object(&w)
			write.key(&w, "e")
			if object {
				write.open_object(&w)
			} else {
				write.open_array(&w)
			}
			testing.expect_value(t, write.comment(&w, "z"), core.Typed_Error_Kind.None)
			write.close(&w)
			write.close(&w)
			write.close(&w)
			text, err := write.tokens_finish(&w)
			if !testing.expectf(t, err.kind == .None, "%s: %v", x.name, err) {
				continue
			}
			doc, berr := core.build(text, x.as, allocator = context.temp_allocator)
			if !testing.expectf(t, berr == nil, "%s: %v\n%s", x.name, berr, string(text)) {
				continue
			}
			got := places(&doc)
			testing.expectf(t, len(got) == 1 && got[0] == Place{"r.e", .Comment_Foot, "z"}, "%s reads %v\n%s", x.name, got, string(text))
		}
	}
}

// A value an update made of a markup document keeps the comments of each element it leaves alone and of one it puts a
// value in place of, and a comment written on a value stands for its node's, in a write as each markup format.
@(test)
updated_values_keep_their_comments_in_markup :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	src := "<r>\n<!-- c -->\n<a>1</a> <!-- i -->\n<b>2</b>\n<d><x>1</x>\n<!-- f -->\n</d>\n</r>\n"
	want := []Place{{"r.a", .Comment, "c"}, {"r.a", .Comment_Inline, "i"}, {"r.b", .Comment, "n"}, {"r.d", .Comment_Foot, "f"}}
	for from in ([]Placed{{"xml", xml.as(.Xml), src}, {"html", html.as(.Fragment), src}}) {
		doc, err := core.build(transmute([]u8)from.src, from.as, allocator = context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s: %v", from.name, err) {
			continue
		}
		r := walktest.member(&doc, core.ROOT, "r")
		d := walktest.member(&doc, r, "d")
		updated_d := core.new_object()
		core.object_put(updated_d, "y", "2")
		updated := core.new_object()
		core.object_put(updated, "a", core.in_place_of("9", {&doc, walktest.member(&doc, r, "a")}))
		core.object_put(updated, "b", core.noted(core.Node_Ref{&doc, walktest.member(&doc, r, "b")}, .Comment, {"n"}))
		core.object_put(updated, "d", core.in_place_of(updated_d, {&doc, d}))
		root := core.new_object()
		core.object_put(root, "r", core.in_place_of(updated, {&doc, r}))
		for to in ([]Placed{{"xml", xml.as(.Xml), ""}, {"html", html.as(.Fragment), ""}}) {
			text, werr := write.write_value(root, to.as, core.PRETTY)
			if !testing.expectf(t, werr == nil, "%s as %s: %v", from.name, to.name, werr) {
				continue
			}
			back, berr := core.build(text, to.as, allocator = context.temp_allocator)
			if !testing.expectf(t, berr == nil, "%s as %s: %v\n%s", from.name, to.name, berr, string(text)) {
				continue
			}
			got := places(&back)
			for p in want {
				testing.expectf(t, slice.contains(got, p), "%s as %s loses %v\n%s", from.name, to.name, p, string(text))
			}
			testing.expectf(t, len(got) == len(want), "%s as %s reads %v\n%s", from.name, to.name, got, string(text))
		}
	}
}
