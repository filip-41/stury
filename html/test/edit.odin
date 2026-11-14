// HTML edits: an element's content set between its tags and escaped as the element reads it, a text run, a rename of
// both tags, members placed and removed with the white space before them, comment and attribute facts, the nodes the
// tree construction made, and a result whose tree is not the edited tree.
package html_tests

import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import html ".."
import walktest "../../walktest"

// The node at `path` of `doc`, each step the first member of its name.
@(private = "file")
at :: proc(doc: ^core.Document, path: ..string) -> core.Node_Index {
	node := core.ROOT
	for name in path {
		node, _ = core.member(doc, node, name, .First)
	}
	return node
}

// The text `src` read as `spec` becomes when `edits` records its edits and the list is committed.
@(private = "file")
edited :: proc(src: string, edits: walktest.Edits, spec := html.Spec.Fragment) -> (string, core.Error) {
	return walktest.markup_edited(src, html.as(spec), edits)
}

// Whether `err` is a refusal of the edit rules for `detail`.
@(private = "file")
expect_frozen :: proc(t: ^testing.T, err: core.Error, detail: html.Detail, loc := #caller_location) {
	e, is_edit := err.(core.Document_Error)
	testing.expectf(t, is_edit && e.kind == .Frozen && e.inner.rules == &html.RULES && html.Detail(e.inner.detail) == detail, "%v", err, loc = loc)
}

// Whether `err` refuses an object whose elements read back otherwise in the element they go in.
@(private = "file")
expect_no_spelling :: proc(t: ^testing.T, err: core.Error, loc := #caller_location) {
	e, is_edit := err.(core.Document_Error)
	testing.expectf(t, is_edit && e.kind == .Bad_Value && e.reason == .No_Spelling, "%v", err, loc = loc)
}

@(private = "file")
SRC :: "<div id=a>\n  <p class=x>t</p>\n  <br>\n  <script>run()</script>\n</div>"

@(test)
set_writes_the_content_and_keeps_the_tags :: proc(t: ^testing.T) {
	out, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, at(d, "div", "p"), typed.Raw("new &amp; <b>more</b>")) or_return
		return write.set(l, at(d, "div", "script"), "if (a < b && c) go()")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div id=a>\n  <p class=x>new &amp; <b>more</b></p>\n  <br>\n  <script>if (a < b && c) go()</script>\n</div>")
}

@(test)
set_escapes_a_string_and_writes_an_object_as_elements :: proc(t: ^testing.T) {
	out, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "p"), "a<b & c")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div id=a>\n  <p class=x>a&lt;b &amp; c</p>\n  <br>\n  <script>run()</script>\n</div>")
	out, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div"), walktest.from_json(`{"i": 1, "q": null, "#text": "t", "s": [true, "u"], "hr": null}`))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div id=a><i>1</i><q></q>t<s>true</s><s>u</s><hr></div>")
	out, err = edited("<pre>\n\nx</pre><textarea></textarea>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, at(d, "pre"), "\ny") or_return
		return write.set(l, at(d, "textarea"), "<b>")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<pre>\n\ny</pre><textarea>&lt;b&gt;</textarea>")
}

// An object's elements are read back in the element they go in, as a fragment whose context is that element, and one
// they do not read back as is refused: a `tr` straight in a `table` reads inside a `tbody`.
@(test)
an_object_reads_back_in_its_element :: proc(t: ^testing.T) {
	TABLE :: "<table><tr><td>1</td></tr></table>"
	cases := [?]struct {
		edits: walktest.Edits,
		want:  string,
	} {
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "table"), walktest.from_json(`{"tbody": {"tr": {"td": 2}}}`))}, "<table><tbody><tr><td>2</td></tr></tbody></table>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "table", "tbody", "tr"), walktest.from_json(`{"td": [3, 4]}`))}, "<table><tr><td>3</td><td>4</td></tr></table>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "table", "tbody"), 1, "tr", walktest.from_json(`{"td": 5}`))}, "<table><tr><td>1</td></tr><tr><td>5</td></tr></table>"},
	}
	for c, i in cases {
		out, err := edited(TABLE, c.edits)
		testing.expectf(t, err == nil && out == c.want, "case %d: %q %v", i, out, err)
	}
	_, err := edited(TABLE, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "table"), walktest.from_json(`{"tr": {"td": 2}}`))
	})
	expect_no_spelling(t, err)
}

@(test)
set_writes_an_array_as_elements_of_the_name :: proc(t: ^testing.T) {
	out, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "p"), walktest.from_json(`[1, null, {"i": 2}]`))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div id=a>\n  <p class=x>1</p>\n  <p></p>\n  <p><i>2</i></p>\n  <br>\n  <script>run()</script>\n</div>")
}

@(test)
set_of_text_writes_the_run :: proc(t: ^testing.T) {
	src := "<div><a></a> hi <b></b></div>"
	out, err := edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "#text"), "1 < 2")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div><a></a>1 &lt; 2<b></b></div>")
	_, err = edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "#text"), walktest.from_json(`{"c": 1}`))
	})
	expect_frozen(t, err, .Text_Markup)
}

@(test)
set_through_a_path_and_from_the_document :: proc(t: ^testing.T) {
	src := "<div><section><p>1</p></section><span>2</span><script>a<b</script></div>"
	out, err := html.set(transmute([]u8)src, .Fragment, core.Path{steps = {core.Name("div"), core.Name("span")}}, typed.Raw("<i>q</i>"), allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), "<div><section><p>1</p></section><span><i>q</i></span><script>a<b</script></div>")
	moved, merr := edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, at(d, "div", "span"), core.Node_Ref{d, at(d, "div", "section")}) or_return
		return write.set(l, at(d, "div", "section", "p"), core.Node_Ref{d, at(d, "div", "script")})
	})
	walktest.expect_nil(t, merr)
	testing.expect_value(t, moved, "<div><section><p>a&lt;b</p></section><span><p>1</p></span><script>a<b</script></div>")
}

@(test)
a_document_keeps_its_doctype_and_tags :: proc(t: ^testing.T) {
	src := "<!DOCTYPE html>\n<html lang=en><head><title>T</title></head>\n<body>\n<p>x</p>\n</body></html>\n"
	out, err := edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, at(d, "html", "head", "title"), "A & B") or_return
		return write.insert(l, at(d, "html", "body"), 1, "p", "y")
	}, .Document)
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<!DOCTYPE html>\n<html lang=en><head><title>A &amp; B</title></head>\n<body>\n<p>x</p>\n<p>y</p>\n</body></html>\n")
}

// An element open where the tree starts to ignore tokens, `</body>` or another end tag in any insertion mode, ends
// there, so an edit of it keeps those tags. The white space after them is the element's text, which a value that does
// not end with it cuts.
@(test)
an_element_open_past_ignored_tags_keeps_them :: proc(t: ^testing.T) {
	cases := [?]struct {
		src, want: string,
		steps:     []core.Step,
	} {
		{"<html><body><p>one<p>two</body></html>\n", "<html><body><p>one<p>X</body></html>", {core.Name("html"), core.Name("body"), core.Name("p")}},
		{"<html><body><p>one<p>two</body>\n</html>\n", "<html><body><p>one<p>X</body></html>", {core.Name("html"), core.Name("body"), core.Name("p")}},
		{"<html><body><ul><li>a<li>b</body></html>\n", "<html><body><ul><li>a<li>X</body></html>", {core.Name("html"), core.Name("body"), core.Name("ul"), core.Name("li")}},
		{"<html><body>hi</body></html>\n", "<html><body>X</body></html>", {core.Name("html"), core.Name("body")}},
		{"<html><body><select><option>a<option>b</body></html>\n", "<html><body><select><option>a<option>X</body></html>", {core.Name("html"), core.Name("body"), core.Name("select"), core.Name("option")}},
		{"<html><body><table><tr><td>a<td>b</body></html>\n", "<html><body><table><tr><td>a<td>X</body></html>", {core.Name("html"), core.Name("body"), core.Name("table"), core.Name("tbody"), core.Name("tr"), core.Name("td")}},
		{"<html><body><table><caption>a</body></html>\n", "<html><body><table><caption>X</body></html>", {core.Name("html"), core.Name("body"), core.Name("table"), core.Name("caption")}},
		{"<html><body><template>a</body></html>\n", "<html><body><template>X</body></html>", {core.Name("html"), core.Name("body"), core.Name("template")}},
		{"<html><head><template>a</head></html>\n", "<html><head><template>X</head></html>", {core.Name("html"), core.Name("head"), core.Name("template")}},
		{"<html><body><svg><g>a</body></html>\n", "<html><body><svg><g>X</body></html>", {core.Name("html"), core.Name("body"), core.Name("svg"), core.Name("g")}},
		{"<html><body><math><mi>a</body></html>\n", "<html><body><math><mi>X</body></html>", {core.Name("html"), core.Name("body"), core.Name("math"), core.Name("mi")}},
		{"<html><body><p>a</div></span>\n", "<html><body><p>X</div></span>", {core.Name("html"), core.Name("body"), core.Name("p")}},
		{"<html><body><ul><li>a</div></ul></body></html>\n", "<html><body><ul><li>X</div></ul></body></html>\n", {core.Name("html"), core.Name("body"), core.Name("ul"), core.Name("li")}},
	}
	for c in cases {
		out, err := html.set(transmute([]u8)c.src, .Document, core.Path{steps = c.steps}, "X", allocator = context.temp_allocator)
		walktest.expect_nil(t, err)
		testing.expect_value(t, string(out), c.want)
	}
}

// The white space the tree reads on into an element past the tokens it ignored is the element's text: a value that ends
// with it keeps those bytes, and any other value removes them, so the element reads back as the value.
@(test)
an_element_open_past_ignored_tags_reads_back_as_its_value :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p := []core.Step{core.Name("html"), core.Name("body"), core.Name("p")}
	option := []core.Step{core.Name("html"), core.Name("body"), core.Name("select"), core.Name("option")}
	ul := []core.Step{core.Name("html"), core.Name("body"), core.Name("ul")}
	li := []core.Step{core.Name("html"), core.Name("body"), core.Name("ul"), core.Name("li")}
	td := []core.Step{core.Name("html"), core.Name("body"), core.Name("table"), core.Name("tbody"), core.Name("tr"), core.Name("td")}
	cases := [?]struct {
		steps:            []core.Step,
		src, value, want: string,
	} {
		{p, "<p>a</body></html>\n", "A\n", "<p>A</body></html>\n"},
		{p, "<p>a</body></html>\n", "X", "<p>X</body></html>"},
		{p, "<p>a</body> </html>\n", "X \n", "<p>X</body> </html>\n"},
		// A comment the element takes past the ignored tags is its foot, and the tags stay before it.
		{option, "<select><option>ab</body> <!--c-->", "Z", "<select><option>Z</body><!--c-->"},
		{option, "<select><option>ab</body> <!--c-->", "Z ", "<select><option>Z</body> <!--c-->"},
		// White space that reopens a formatting element past the ignored tags reads into the element once the edit
		// takes the formatting element away.
		{ul, "<ul><li><b>ab</li></td>\n", "Z", "<ul>Z</td>"},
		{ul, "<ul><li><b>ab</li></td>\n", "Z\n", "<ul>Z</td>\n"},
		// The select the ignored tags stood in goes with the edit, so they close elements and the value is written whole.
		{li, "<ul><li><select><option>b</ul>\n</html>", "Z\n", "<ul><li>Z\n</ul></html>"},
		// The white space a cell reads on past an ignored end tag is text past its span, before the cell's end tag.
		{td, "<table><tr><td>ba</div>\n</span></td>", "Z", "<table><tr><td>Z</div></span></td>"},
	}
	for c in cases {
		path := core.Path{steps = c.steps}
		out, err := html.set(transmute([]u8)c.src, .Document, path, c.value, allocator = context.temp_allocator)
		walktest.expect_nil(t, err)
		testing.expect_value(t, string(out), c.want)
		read, answer, ferr := html.find(out, .Document, path, allocator = context.temp_allocator)
		walktest.expect_nil(t, ferr)
		testing.expectf(t, core.equal(c.value, core.Node_Ref{&read, answer.node}, read_plain = true), "%q reads back as another value than %q", out, c.value)
	}
}

// A set of one element's content replaces bytes of that element alone, in documents of nested elements whose end tags
// are left out at random and that end in tokens the tree ignores: the bytes it replaces end in no end tag of an element
// outside it, where its own end tag does not follow them.
@(test)
an_edit_replaces_bytes_of_its_element_alone :: proc(t: ^testing.T) {
	Shape :: struct {
		open, close: string,
		inner:       int, // the shape of its children, -1 for text
	}
	// A shape whose children are 0 takes any shape OPENERS names.
	SHAPES :: [?]Shape{{"<p>", "</p>", -1}, {"<div>", "</div>", 0}, {"<ul>", "</ul>", 3}, {"<li>", "</li>", 0}, {"<table>", "</table>", 5}, {"<tr>", "</tr>", 6}, {"<td>", "</td>", 0}, {"<select>", "</select>", 8}, {"<option>", "</option>", -1}, {"<b>", "</b>", -1}, {"<svg>", "</svg>", 11}, {"<g>", "</g>", -1}}
	OPENERS :: [?]int{0, 1, 2, 4, 7, 9, 10}
	TAILS :: [?]string{"</body>", "</html>", "</div>", "</span>", "</td>", "\n", " ", "<!--c-->"}
	Gen :: struct {
		b:     strings.Builder,
		state: u64,
	}
	pick :: proc(g: ^Gen, n: int) -> int {
		g.state ~= g.state << 13
		g.state ~= g.state >> 7
		g.state ~= g.state << 17
		return int(g.state % u64(n))
	}
	grow :: proc(g: ^Gen, shape, depth: int) {
		shapes := SHAPES
		s := shapes[shape]
		strings.write_string(&g.b, s.open)
		for _ in 0 ..< 1 + pick(g, 2) {
			if s.inner < 0 || depth >= 3 {
				strings.write_string(&g.b, "a" if pick(g, 2) == 0 else "b")
				continue
			}
			openers := OPENERS
			grow(g, openers[pick(g, len(openers))] if s.inner == 0 else s.inner, depth + 1)
		}
		if pick(g, 2) == 0 {
			strings.write_string(&g.b, s.close)
		}
	}
	names :: proc(doc: ^core.Document, v: core.Node_Index, into: ^[dynamic]string) {
		if core.kind(doc, v) != .Object {
			return
		}
		it := core.pairs(doc, v)
		for k, c in core.pair_next(&it) {
			append(into, core.node_string(doc, k))
			names(doc, c, into)
		}
	}
	members :: proc(doc: ^core.Document, v: core.Node_Index, into: ^[dynamic]core.Node_Index) {
		if core.kind(doc, v) != .Object {
			return
		}
		it := core.pairs(doc, v)
		for k, c in core.pair_next(&it) {
			if !core.key_equals(doc, k, core.MARKUP_TEXT) {
				append(into, c)
			}
			members(doc, c, into)
		}
	}
	// The member indexes from `from` down to `target`.
	index_path :: proc(doc: ^core.Document, from, target: core.Node_Index, into: ^[dynamic]int) -> bool {
		if from == target {
			return true
		}
		if core.kind(doc, from) != .Object {
			return false
		}
		it := core.pairs(doc, from)
		i := 0
		for _, c in core.pair_next(&it) {
			append(into, i)
			if index_path(doc, c, target, into) {
				return true
			}
			pop(into)
			i += 1
		}
		return false
	}
	follow :: proc(doc: ^core.Document, at: []int) -> core.Node_Index {
		n := core.ROOT
		for i in at {
			it := core.pairs(doc, n)
			for _ in 0 ..< i {
				core.pair_next(&it)
			}
			_, n, _ = core.pair_next(&it)
		}
		return n
	}
	context.allocator = context.temp_allocator
	g := Gen{state = 0x9e3779b97f4a7c15}
	edits := 0
	for _ in 0 ..< 400 {
		free_all(context.temp_allocator)
		g.b = strings.builder_make(context.temp_allocator)
		strings.write_string(&g.b, "<html><body>")
		openers := OPENERS
		grow(&g, openers[pick(&g, len(openers))], 0)
		for _ in 0 ..< pick(&g, 5) {
			tails := TAILS
			strings.write_string(&g.b, tails[pick(&g, len(tails))])
		}
		src := strings.to_string(g.b)
		doc, err := html.build(transmute([]u8)src, .Document, allocator = context.temp_allocator)
		walktest.expect_nil(t, err)
		elements := make([dynamic]core.Node_Index, context.temp_allocator)
		members(&doc, core.ROOT, &elements)
		for v in elements {
			key := core.node_string(&doc, v - 1)
			if key == "html" || key == "body" || key == "head" {
				continue
			}
			at := make([dynamic]int, context.temp_allocator)
			index_path(&doc, core.ROOT, v, &at)
			// "Z" cuts the white space that reads into the element past its span, and "Z\n" keeps a line end there.
			for value in ([?]string{"Z\n", "Z"}) {
				list := html.edit_list_init(&doc, .Document, context.temp_allocator)
				if write.set(&list, v, value) != nil {
					continue
				}
				out, _, cerr := compose.commit(&list, allocator = context.temp_allocator)
				if refused, is_doc := cerr.(core.Document_Error); is_doc {
					testing.expectf(t, refused.reason != .Reads_Back_Other, "%q: setting %s to %q reads back as another value", src, key, value)
				}
				if cerr != nil {
					continue
				}
				edits += 1
				read, rerr := html.build(out, .Document, allocator = context.temp_allocator)
				walktest.expect_nil(t, rerr)
				testing.expectf(t, core.equal(value, core.Node_Ref{&read, follow(&read, at[:])}, read_plain = true), "%q: setting %s to %q reads back other in %q", src, key, value, out)
				if value != "Z" {
					continue
				}
				p, q := 0, 0
				for p < len(src) && p < len(out) && src[p] == out[p] {
					p += 1
				}
				for q < len(src) - p && q < len(out) - p && src[len(src) - 1 - q] == out[len(out) - 1 - q] {
					q += 1
				}
				// Its own end tag after the bytes it replaced bounds them: an end tag the tree ignored there is content.
				if rest := src[len(src) - q:]; strings.has_prefix(rest, "</") && strings.has_prefix(rest[2:], key) {
					continue
				}
				// The white space a set cuts past its element's span is the element's text.
				i, j := len(src), len(out)
				for i > p && j > p {
					if src[i - 1] == out[j - 1] {
						i, j = i - 1, j - 1
					} else if src[i - 1] == ' ' || src[i - 1] == '\n' {
						i -= 1
					} else {
						break
					}
				}
				inside := make([dynamic]string, context.temp_allocator)
				append(&inside, key)
				names(&doc, v, &inside)
				region := strings.trim_right(src[p:i], " \n")
				last := strings.last_index(region, "</")
				if last < 0 || !strings.has_suffix(region, ">") || strings.contains(region[last:len(region) - 1], ">") {
					continue
				}
				name := region[last + 2:len(region) - 1]
				testing.expectf(t, slice.contains(inside[:], name), "%q: setting %s replaced the end tag </%s> after its content in %q", src, key, name, src[p:i])
			}
		}
	}
	testing.expect(t, edits > 800)
}

// Each element of a repeated name and each run of `#text` is a member of its own, which a set, an insert, a removal and
// a rename reach without moving the members around it.
@(test)
edits_reach_each_element_of_a_repeated_name :: proc(t: ^testing.T) {
	SRC :: "<div>hello <b k=1>bold</b> tail<b>x</b><i>y</i></div>"
	cases := [?]struct {
		edits: walktest.Edits,
		want:  string,
	} {
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, walktest.nth(d, at(d, "div"), "b", 1), "y")}, "<div>hello <b k=1>bold</b> tail<b>y</b><i>y</i></div>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, walktest.nth(d, at(d, "div"), "#text", 1), " T")}, "<div>hello <b k=1>bold</b> T<b>x</b><i>y</i></div>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "div"), 4, "b", "n")}, "<div>hello <b k=1>bold</b> tail<b>x</b><b>n</b><i>y</i></div>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.remove(l, walktest.nth(d, at(d, "div"), "b", 0))}, "<div>hello  tail<b>x</b><i>y</i></div>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, walktest.nth(d, at(d, "div"), "b", 1) - 1, "em")}, "<div>hello <b k=1>bold</b> tail<em>x</em><i>y</i></div>"},
	}
	for c in cases {
		out, err := edited(SRC, c.edits)
		walktest.expect_nil(t, err)
		testing.expect_value(t, out, c.want)
	}
}

@(test)
rename_respells_both_tags :: proc(t: ^testing.T) {
	out, err := edited("<DIV><P>1</P><li>2</div>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, at(d, "div", "p") - 1, "h1") or_return
		write.set(l, at(d, "div", "li") - 1, "dd") or_return
		return write.set(l, at(d, "div") - 1, "section")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<section><h1>1</h1><dd>2</section>")
	_, err = edited("<div></div>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div") - 1, "Section")
	})
	expect_frozen(t, err, .Not_Name)
}

@(test)
insert_and_remove_lay_out_a_member_as_its_neighbour :: proc(t: ^testing.T) {
	src := "<ul>\n  <li>1</li>\n  <li>2</li><!-- note -->\n</ul>"
	out, err := edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.insert(l, at(d, "ul"), 0, "li", 0) or_return
		return write.insert(l, at(d, "ul"), 2, "li", walktest.from_json(`{"#text": "t", "b": "e"}`))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<ul>\n  <li>0</li>\n  <li>1</li>\n  <li>2</li><!-- note -->\n  <li>t<b>e</b></li>\n</ul>")
	out, err = edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.remove(l, at(d, "ul", "li"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<ul>\n  <li>2</li><!-- note -->\n</ul>")
}

@(test)
facts_stand_where_html_reads_them :: proc(t: ^testing.T) {
	out, err := edited("<div x=0 y='1'><a>1</a><b>2</b></div>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.set_fact(l, at(d, "div", "a"), .Comment_Inline, " after a ") or_return
		core.set_facts(l, at(d, "div", "b"), .Attribute, {`k="1"`, `m='&amp;'`}) or_return
		return core.set_fact(l, at(d, "div"), .Attribute, `z=2`)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div z=2><a>1</a><!-- after a --><b k=\"1\" m='&amp;'>2</b></div>")
	_, err = edited("<div></div>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_fact(l, at(d, "div"), .Comment, "a --> b")
	})
	expect_frozen(t, err, .Comment_Body)
}

@(test)
attribute_names_keep_their_capitals :: proc(t: ^testing.T) {
	out, err := edited("<div K=1></div>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_fact(l, at(d, "div"), .Attribute, `K=2`)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div K=2></div>")
}

@(test)
attribute_bodies_html_cannot_read_as_written_are_refused :: proc(t: ^testing.T) {
	cases := [?]walktest.Edits {
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.set_fact(l, at(d, "div"), .Attribute, `a=1 b=2`)},
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.set_fact(l, at(d, "div"), .Attribute, `a="1`)},
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.set_fact(l, at(d, "div"), .Attribute, `a=1>`)},
	}
	for c in cases {
		_, err := edited("<div></div>", c)
		expect_frozen(t, err, .Attribute_Body)
	}
}

// A node the tree construction implied, moved or copied stands nowhere in the source, so an edit of it, or an insert
// next to it, is refused, and a text read across a start tag the tree dropped holds the tag's effect.
@(test)
nodes_the_tree_made_are_refused :: proc(t: ^testing.T) {
	cases := [?]struct {
		src:   string,
		spec:  html.Spec,
		edits: walktest.Edits,
	} {
		{"<p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "html", "body"), 1)}},
		{"<p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.remove(l, at(d, "html", "head"))}},
		{"<p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "html"), 2, "q", 1)}},
		{"<p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.set_fact(l, at(d, "html", "body"), .Attribute, "a=1")}},
		{"<table><tr><td>1</table>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "table", "tbody"), 1)}},
		{"<table><tr><td>1</table>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "table"), 0, "caption", 1)}},
		{"<table>a<tr><td>1</td></tr></table>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "#text"), "b")}},
		{"<b>1<p>2</b>3</p>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "p", "b"), 4)}},
		{"<b>1<p>2</b>3</p>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "p", "b") - 1, "i")}},
	}
	for c, i in cases {
		_, err := edited(c.src, c.edits, c.spec)
		e, is_edit := err.(core.Document_Error)
		testing.expectf(t, is_edit && e.kind == .Frozen && html.Detail(e.inner.detail) == .Constructed, "case %d: %v", i, err)
	}
	_, err := edited("<p>a<html lang=x>b</p>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "html", "body", "p"), "c")
	}, .Document)
	expect_frozen(t, err, .Split)
}

// An edit that writes only at the bytes the source spells keeps the nodes the tree construction made around them: a
// member of an implied element, an insert between its members, and a set of an element whose implied descendants it
// replaces.
@(test)
edits_around_the_nodes_the_tree_made_keep_them :: proc(t: ^testing.T) {
	cases := [?]struct {
		src:   string,
		spec:  html.Spec,
		edits: walktest.Edits,
		want:  string,
	} {
		{"<p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "html", "body", "p"), "y")}, "<p>y"},
		{"<p>a</p><p>b</p>", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "html", "body"), 1, "q", 1)}, "<p>a</p><q>1</q><p>b</p>"},
		{"<p>a</p><p>b</p>", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.remove(l, at(d, "html", "body", "p"))}, "<p>b</p>"},
		{"<table><tr><td>1</td></tr></table>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "table"), typed.Raw("<tr><td>2</td></tr>"))}, "<table><tr><td>2</td></tr></table>"},
		{"<table><tr><td>1</td></tr></table>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "table", "tbody", "tr", "td"), 3)}, "<table><tr><td>3</td></tr></table>"},
	}
	for c, i in cases {
		out, err := edited(c.src, c.edits, c.spec)
		testing.expectf(t, err == nil && out == c.want, "case %d: %q %v", i, out, err)
	}
}

// An edit of the document is read again as every other edit is: the root element it writes reads as it reads alone, and
// an insert or a removal at the top changes the count of elements there by its own.
@(test)
edits_of_the_document_are_read_again :: proc(t: ^testing.T) {
	out, err := edited("<!-- c --><p>x</p>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, core.ROOT, typed.Raw("<html><body><i>1</i></body></html>"))
	}, .Document)
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<!-- c --><html><body><i>1</i></body></html>")
	out, err = edited("<p>x</p>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.insert(l, core.ROOT, 1, "i", 1)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<p>x</p><i>1</i>")
	cases := [?]struct {
		src:   string,
		spec:  html.Spec,
		edits: walktest.Edits,
	} {
		{"<html><body></body></html>", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, core.ROOT, 1, "p", 1)}},
		{"<p>x", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, core.ROOT, 1, "td", 1)}},
		{"<!DOCTYPE html><p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, core.ROOT, typed.Raw("<p><table></table>"))}},
	}
	for c, i in cases {
		_, refused := edited(c.src, c.edits, c.spec)
		e, is_edit := refused.(core.Document_Error)
		testing.expectf(t, is_edit && e.kind == .Bad_Result && html.Detail(e.inner.detail) == .Reread, "case %d: %v", i, refused)
	}
}

@(test)
content_an_element_cannot_hold_is_refused :: proc(t: ^testing.T) {
	_, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "br"), "x")
	})
	expect_frozen(t, err, .Void)
	_, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "script"), typed.Raw("<b>x</b>"))
	})
	expect_frozen(t, err, .Text_Markup)
	_, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "p"), walktest.from_json(`{"B": 1}`))
	})
	expect_no_spelling(t, err)
	_, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.reorder(l, at(d, "div"), {1, 0, 2})
	})
	expect_frozen(t, err, .Reordered)
}

// The edited text is read again, and a tree other than the edited one is refused: a `p` the tree construction closes
// where the edit put it inside another, or a cell outside a table.
@(test)
a_result_that_reads_as_another_tree_is_refused :: proc(t: ^testing.T) {
	cases := [?]walktest.Edits {
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "div", "p"), typed.Raw("<p>x</p>"))},
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "div", "p"), walktest.from_json(`{"div": 1}`))},
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "div", "p"), 0, "td", 1)},
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "div", "p") - 1, "table")},
	}
	for c, i in cases {
		_, err := edited("<div><p><i>1</i> t</p></div>", c)
		e, is_edit := err.(core.Document_Error)
		testing.expectf(t, is_edit && e.kind == .Bad_Result && html.Detail(e.inner.detail) == .Reread, "case %d: %v", i, err)
	}
}

