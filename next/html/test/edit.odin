// Byte-preserving HTML5 editing via Overlay + `html.commit` / `html.commit_document`:
// capitalized attribute preservation, void elements, rawtext, read-on whitespace, constructed/split refusals, reorders, and fuzzing.
package html_tests

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:html"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:testkit"

@(private = "file")
Edit_Callback :: #type proc(ov: ^html.Overlay, doc: ^html.Document) -> html.Edit_Error

@(private = "file")
edited :: proc(src: string, fn: Edit_Callback, spec := html.Spec.Fragment, opts := html.Edit_Options{}) -> (out_str: string, err: html.Edit_Error) {
	alloc := runtime.heap_allocator()
	doc, berr := html.build(transmute([]u8)src, spec, {}, alloc)
	if berr != nil {
		switch e in berr {
		case tape.Fault:
			return "", e
		case tape.Exceeded:
			return "", e
		case tape.Bad_Option:
			return "", e
		case tape.Piece_Gap:
			return "", edit.refuse(.No_Document, "piece gap")
		case runtime.Allocator_Error:
			return "", e
		}
		return "", edit.refuse(.No_Document, "build error")
	}
	defer html.destroy(&doc)
	ov: html.Overlay
	if ierr := html.edit_init(&ov, &doc, alloc); ierr != nil {
		return "", ierr
	}
	defer html.edit_destroy(&ov)
	if fn != nil {
		fn(&ov, &doc) or_return
	}
	res := html.commit(&ov, opts, alloc) or_return
	defer edit.destroy_commit_result(&res)
	return strings.clone(string(res.bytes), context.temp_allocator), nil
}

@(private = "file")
at_node :: proc(doc: ^html.Document, path: ..string) -> html.Node_Index {
	node, _ := member_at(doc, path, .First)
	return node
}

@(private = "file")
expect_refusal :: proc(t: ^testing.T, err: html.Edit_Error, kind: edit.Refusal_Kind, loc := #caller_location) {
	r, ok := err.(edit.Refusal)
	testing.expectf(t, ok && r.kind == kind, "got %v, want Refusal.%v", err, kind, loc = loc)
}

@(private = "file")
SRC :: "<div id=a>\n  <p class=x>t</p>\n  <br>\n  <script>run()</script>\n</div>"

@(test)
set_writes_content_and_keeps_tags :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	out, err := edited(SRC, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hp := edit.handle_for_base(ov, at_node(d, "div", "p")) or_return
		edit.set(ov, hp, edit.val_raw("new &amp; <b>more</b>")) or_return
		hs := edit.handle_for_base(ov, at_node(d, "div", "script")) or_return
		return edit.set(ov, hs, edit.val_string("if (a < b && c) go()"))
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<div id=a>\n  <p class=x>new &amp; <b>more</b></p>\n  <br>\n  <script>if (a < b && c) go()</script>\n</div>")
}

@(test)
set_escapes_string_and_writes_object_as_elements :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	out, err := edited(SRC, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hp := edit.handle_for_base(ov, at_node(d, "div", "p")) or_return
		return edit.set(ov, hp, edit.val_string("a<b & c"))
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<div id=a>\n  <p class=x>a&lt;b &amp; c</p>\n  <br>\n  <script>run()</script>\n</div>")

	out, err = edited(SRC, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hd := edit.handle_for_base(ov, at_node(d, "div")) or_return
		hi := edit.new_node(ov, edit.val_int(1)) or_return
		hq := edit.new_node(ov, edit.val_null()) or_return
		ht := edit.new_node(ov, edit.val_string("t")) or_return
		s0 := edit.new_node(ov, edit.val_bool(true)) or_return
		s1 := edit.new_node(ov, edit.val_string("u")) or_return
		hs := edit.new_node(ov, edit.val_array({s0, s1})) or_return
		hhr := edit.new_node(ov, edit.val_null()) or_return
		entries := [?]edit.Object_Entry {
			{key = "i", value = hi},
			{key = "q", value = hq},
			{key = "#text", value = ht},
			{key = "s", value = hs},
			{key = "hr", value = hhr},
		}
		return edit.set(ov, hd, edit.val_object(entries[:]))
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<div id=a><i>1</i><q></q>t<s>true</s><s>u</s><hr></div>")

	out, err = edited("<pre>\n\nx</pre><textarea></textarea>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hpre := edit.handle_for_base(ov, at_node(d, "pre")) or_return
		edit.set(ov, hpre, edit.val_string("\ny")) or_return
		htxa := edit.handle_for_base(ov, at_node(d, "textarea")) or_return
		return edit.set(ov, htxa, edit.val_string("<b>"))
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<pre>\n\ny</pre><textarea>&lt;b&gt;</textarea>")
}

@(test)
an_object_reads_back_in_its_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	TABLE :: "<table><tr><td>1</td></tr></table>"

	// Valid `<tbody><tr><td>2</td></tr></tbody>` inside `<table>`.
	out, err := edited(TABLE, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		htbl := edit.handle_for_base(ov, at_node(d, "table")) or_return
		htd := edit.new_node(ov, edit.val_int(2)) or_return
		htr := edit.new_node(ov, edit.val_object({{key = "td", value = htd}})) or_return
		htb := edit.new_node(ov, edit.val_object({{key = "tr", value = htr}})) or_return
		return edit.set(ov, htbl, edit.val_object({{key = "tbody", value = htb}}))
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<table><tbody><tr><td>2</td></tr></tbody></table>")

	// Insert sibling `<tr>` inside implied `<tbody>`.
	out, err = edited(TABLE, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		htb := edit.handle_for_base(ov, at_node(d, "table", "tbody")) or_return
		htd := edit.new_node(ov, edit.val_int(5)) or_return
		_, ierr := edit.insert_member(ov, htb, 1, "tr", edit.val_object({{key = "td", value = htd}}))
		return ierr
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<table><tr><td>1</td></tr><tr><td>5</td></tr></table>")

	// Direct `<tr>` in `<table>` fails round-trip because HTML5 infers `<tbody>`.
	_, bad := edited(TABLE, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		htbl := edit.handle_for_base(ov, at_node(d, "table")) or_return
		htd := edit.new_node(ov, edit.val_int(2)) or_return
		htr := edit.new_node(ov, edit.val_object({{key = "td", value = htd}})) or_return
		return edit.set(ov, htbl, edit.val_object({{key = "tr", value = htr}}))
	})
	expect_refusal(t, bad, .Unspellable_Value)
}

@(test)
set_array_text_base_ref_and_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	out, err := edited(SRC, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hp := edit.handle_for_base(ov, at_node(d, "div", "p")) or_return
		e0 := edit.new_node(ov, edit.val_int(1)) or_return
		e1 := edit.new_node(ov, edit.val_null()) or_return
		hi := edit.new_node(ov, edit.val_int(2)) or_return
		e2 := edit.new_node(ov, edit.val_object({{key = "i", value = hi}})) or_return
		return edit.set(ov, hp, edit.val_array({e0, e1, e2}))
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<div id=a>\n  <p class=x>1</p>\n  <p></p>\n  <p><i>2</i></p>\n  <br>\n  <script>run()</script>\n</div>")

	// `#text` replacement + refusal of markup inside `#text`.
	out, err = edited("<div><a></a> hi <b></b></div>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		ht := edit.handle_for_base(ov, at_node(d, "div", "#text")) or_return
		return edit.set(ov, ht, edit.val_string("1 < 2"))
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<div><a></a>1 &lt; 2<b></b></div>")

	_, bad_txt := edited("<div><a></a> hi <b></b></div>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		ht := edit.handle_for_base(ov, at_node(d, "div", "#text")) or_return
		hc := edit.new_node(ov, edit.val_int(1)) or_return
		return edit.set(ov, ht, edit.val_object({{key = "c", value = hc}}))
	})
	expect_refusal(t, bad_txt, .Text_Markup)

	// Move nodes via `val_base_ref`: `<script>` rawtext moved into `<p>` gets escaped cleanly!
	moved, merr := edited("<div><section><p>1</p></section><span>2</span><script>a<b</script></div>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hspan := edit.handle_for_base(ov, at_node(d, "div", "span")) or_return
		edit.set(ov, hspan, edit.val_base_ref(at_node(d, "div", "section"))) or_return
		hp := edit.handle_for_base(ov, at_node(d, "div", "section", "p")) or_return
		return edit.set(ov, hp, edit.val_base_ref(at_node(d, "div", "script")))
	})
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, moved, "<div><section><p>a&lt;b</p></section><span><p>1</p></span><script>a<b</script></div>")

	// Full document preserves DOCTYPE, attributes, and indentation.
	dout, derr := edited("<!DOCTYPE html>\n<html lang=en><head><title>T</title></head>\n<body>\n<p>x</p>\n</body></html>\n", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		ht := edit.handle_for_base(ov, at_node(d, "html", "head", "title")) or_return
		edit.set(ov, ht, edit.val_string("A & B")) or_return
		hb := edit.handle_for_base(ov, at_node(d, "html", "body")) or_return
		_, ierr := edit.insert_member(ov, hb, 1, "p", edit.val_string("y"))
		return ierr
	}, .Html)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, dout, "<!DOCTYPE html>\n<html lang=en><head><title>A &amp; B</title></head>\n<body>\n<p>x</p>\n<p>y</p>\n</body></html>\n")
}

@(test)
read_on_whitespace_past_ignored_tags :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	p := []tape.Step{tape.Name("html"), tape.Name("body"), tape.Name("p")}
	option := []tape.Step{tape.Name("html"), tape.Name("body"), tape.Name("select"), tape.Name("option")}
	ul := []tape.Step{tape.Name("html"), tape.Name("body"), tape.Name("ul")}
	li := []tape.Step{tape.Name("html"), tape.Name("body"), tape.Name("ul"), tape.Name("li")}
	td := []tape.Step{tape.Name("html"), tape.Name("body"), tape.Name("table"), tape.Name("tbody"), tape.Name("tr"), tape.Name("td")}
	cases := [?]struct {
		steps:            []tape.Step,
		src, value, want: string,
	} {
		{p, "<p>a</body></html>\n", "A\n", "<p>A</body></html>\n"},
		{p, "<p>a</body></html>\n", "X", "<p>X</body></html>"},
		{p, "<p>a</body> </html>\n", "X \n", "<p>X</body> </html>\n"},
		{option, "<select><option>ab</body> <!--c-->", "Z", "<select><option>Z</body><!--c-->"},
		{option, "<select><option>ab</body> <!--c-->", "Z ", "<select><option>Z</body> <!--c-->"},
		{ul, "<ul><li><b>ab</li></td>\n", "Z", "<ul>Z</td>"},
		{ul, "<ul><li><b>ab</li></td>\n", "Z\n", "<ul>Z</td>\n"},
		{li, "<ul><li><select><option>b</ul>\n</html>", "Z\n", "<ul><li>Z\n</ul></html>"},
		{td, "<table><tr><td>ba</div>\n</span></td>", "Z", "<table><tr><td>Z</div></span></td>"},
	}
	for c in cases {
		doc, err := html.build(transmute([]u8)c.src, .Html, {}, context.temp_allocator)
		testing.expect_value(t, err, nil)
		ov: html.Overlay
		testing.expect_value(t, html.edit_init(&ov, &doc, context.temp_allocator), nil)
		_, serr := edit.set_path(&ov, c.steps, edit.val_string(c.value))
		testing.expect_value(t, serr, nil)
		res, cerr := html.commit(&ov, {}, context.temp_allocator)
		testing.expect_value(t, cerr, nil)
		testing.expect_value(t, string(res.bytes), c.want)
		ans, ferr := html.find(res.bytes, c.steps)
		testing.expect_value(t, ferr, nil)
		read_doc, rerr := html.build(res.bytes, .Html, {}, context.temp_allocator)
		testing.expect_value(t, rerr, nil)
		testing.expectf(t, ans.outcome == .Found && token_text(&read_doc, html.answer_node(ans)) == c.value, "%q reads back other than %q", string(res.bytes), c.value)
	}
}

@(test)
an_edit_replaces_bytes_of_its_element_alone :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Shape :: struct {
		open, close: string,
		inner:       int,
	}
	SHAPES :: [?]Shape{{"<p>", "</p>", -1}, {"<div>", "</div>", 0}, {"<ul>", "</ul>", 3}, {"<li>", "</li>", 0}, {"<table>", "</table>", 5}, {"<tr>", "</tr>", 6}, {"<td>", "</td>", 0}, {"<select>", "</select>", 8}, {"<option>", "</option>", -1}, {"<b>", "</b>", -1}, {"<svg>", "</svg>", 11}, {"<g>", "</g>", -1}}
	OPENERS :: [?]int{0, 1, 2, 4, 7, 9, 10}
	EDITED :: [?]string{"p", "div", "ul", "li", "td", "select", "option", "b", "svg", "g"}
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
	grow :: proc(g: ^Gen, shp, depth: int) {
		shapes := SHAPES
		s := shapes[shp]
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
	names :: proc(doc: ^html.Document, v: html.Node_Index, into: ^[dynamic]string) {
		if doc.nodes[v].kind != .Object {
			return
		}
		r := reader(doc)
		c, _, _ := html.children(r, v, context.temp_allocator)
		for {
			kn, child_v, p := html.next_child(r, &c, .Group)
			if p != .Found {
				break
			}
			append(into, text_of(doc, kn))
			names(doc, child_v, into)
		}
	}
	members :: proc(doc: ^html.Document, v: html.Node_Index, into: ^[dynamic]html.Node_Index) {
		if doc.nodes[v].kind != .Object {
			return
		}
		r := reader(doc)
		c, _, _ := html.children(r, v, context.temp_allocator)
		for {
			kn, child_v, p := html.next_child(r, &c, .Group)
			if p != .Found {
				break
			}
			if text_of(doc, kn) != html.TEXT_KEY {
				append(into, child_v)
			}
			members(doc, child_v, into)
		}
	}
	index_path :: proc(doc: ^html.Document, from, target: html.Node_Index, into: ^[dynamic]int) -> bool {
		if from == target {
			return true
		}
		if doc.nodes[from].kind != .Object {
			return false
		}
		r := reader(doc)
		c, _, _ := html.children(r, from, context.temp_allocator)
		idx := 0
		for {
			_, child_v, p := html.next_child(r, &c, .Group)
			if p != .Found {
				break
			}
			append(into, idx)
			if index_path(doc, child_v, target, into) {
				return true
			}
			pop(into)
			idx += 1
		}
		return false
	}
	follow :: proc(doc: ^html.Document, idxs: []int) -> html.Node_Index {
		n := html.ROOT
		r := reader(doc)
		for idx in idxs {
			c, _, _ := html.children(r, n, context.temp_allocator)
			for _ in 0 ..< idx {
				_, _, _ = html.next_child(r, &c, .Group)
			}
			_, n, _ = html.next_child(r, &c, .Group)
		}
		return n
	}

	g := Gen{state = 0x9e3779b97f4a7c15}
	edits: [len(EDITED)][2]int
	for _ in 0 ..< 60 {
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
		doc, err := html.build(transmute([]u8)src, .Html, {}, context.temp_allocator)
		testing.expect_value(t, err, nil)
		elements := make([dynamic]html.Node_Index, context.temp_allocator)
		members(&doc, html.ROOT, &elements)
		for v in elements {
			key := text_of(&doc, v - 1)
			if key == "html" || key == "body" || key == "head" {
				continue
			}
			idxs := make([dynamic]int, context.temp_allocator)
			index_path(&doc, html.ROOT, v, &idxs)
			for value in ([?]string{"Z\n", "Z"}) {
				ov: html.Overlay
				testing.expect_value(t, html.edit_init(&ov, &doc, context.temp_allocator), nil)
				hv, herr := edit.handle_for_base(&ov, v)
				if herr != nil || edit.set(&ov, hv, edit.val_string(value)) != nil {
					html.edit_destroy(&ov)
					continue
				}
				res, cerr := html.commit(&ov, {}, context.temp_allocator)
				html.edit_destroy(&ov)
				if cerr != nil {
					continue
				}
				out := res.bytes
				for nm, n_idx in EDITED {
					if key == nm {
						edits[n_idx][0 if value == "Z" else 1] += 1
					}
				}
				read_doc, rerr := html.build(out, .Html, {}, context.temp_allocator)
				testing.expect_value(t, rerr, nil)
				testing.expectf(t, text_of(&read_doc, follow(&read_doc, idxs[:])) == value, "%q: setting %s to %q reads back other in %q", src, key, value, string(out))
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
				if rest := src[len(src) - q:]; strings.has_prefix(rest, "</") && strings.has_prefix(rest[2:], key) {
					continue
				}
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
				nm := region[last + 2:len(region) - 1]
				testing.expectf(t, slice.contains(inside[:], nm), "%q: setting %s replaced </%s> in %q", src, key, nm, src[p:i])
			}
		}
	}
	for nm, n_idx in EDITED {
		testing.expectf(t, edits[n_idx][0] > 0 && edits[n_idx][1] > 0, "no set of %s committed with both values: %v", nm, edits[n_idx])
	}
}

@(test)
edits_repeated_names_attrs_renames_and_reorders :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Reach 2nd `<b>`, 2nd `#text`, and insert `<b>` at index 4.
	out, err := edited("<div>hello <b k=1>bold</b> tail<b>x</b><i>y</i></div>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		div := at_node(d, "div")
		b1, _ := nth_member(d, div, "b", 1)
		hb1 := edit.handle_for_base(ov, b1) or_return
		return edit.set(ov, hb1, edit.val_string("y"))
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<div>hello <b k=1>bold</b> tail<b>y</b><i>y</i></div>")

	out, err = edited("<div>hello <b k=1>bold</b> tail<b>x</b><i>y</i></div>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		div := at_node(d, "div")
		t1, _ := nth_member(d, div, "#text", 1)
		ht1 := edit.handle_for_base(ov, t1) or_return
		return edit.set(ov, ht1, edit.val_string(" T"))
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<div>hello <b k=1>bold</b> T<b>x</b><i>y</i></div>")

	out, err = edited("<div>hello <b k=1>bold</b> tail<b>x</b><i>y</i></div>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hdiv := edit.handle_for_base(ov, at_node(d, "div")) or_return
		_, ierr := edit.insert_member(ov, hdiv, 4, "b", edit.val_string("n"))
		return ierr
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<div>hello <b k=1>bold</b> tail<b>x</b><b>n</b><i>y</i></div>")

	// Rename respells tags & refuses non-lowercase HTML name.
	out, err = edited("<DIV><P>1</P><li>2</div>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hdiv := edit.handle_for_base(ov, at_node(d, "div")) or_return
		edit.rename_member(ov, hdiv, "p", "h1") or_return
		edit.rename_member(ov, hdiv, "li", "dd") or_return
		hroot := edit.ensure_root(ov) or_return
		return edit.rename_member(ov, hroot, "div", "section")
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<section><h1>1</h1><dd>2</section>")

	_, bad_name := edited("<div></div>", proc(ov: ^html.Overlay, _: ^html.Document) -> html.Edit_Error {
		hroot := edit.ensure_root(ov) or_return
		return edit.rename_member(ov, hroot, "div", "Section")
	})
	expect_refusal(t, bad_name, .Bad_Name)

	// Capitalized existing attribute `<div K=1>` keeps its capital `K=2`, while NEW uppercase attr `M=1` is refused!
	out, err = edited("<div K=1></div>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hdiv := edit.handle_for_base(ov, at_node(d, "div")) or_return
		return edit.set_fact(ov, hdiv, .Attribute, {"2"}, "K")
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<div K=2></div>")

	_, bad_cap := edited("<div K=1></div>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hdiv := edit.handle_for_base(ov, at_node(d, "div")) or_return
		return edit.set_fact(ov, hdiv, .Attribute, {"2"}, "NEWCAP")
	})
	expect_refusal(t, bad_cap, .Bad_Name)

	// Fact edits: inline comment, update/add/delete attributes, bad comment refusal.
	out, err = edited("<div x=0 y='1'><a>1</a><b>2</b></div>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		ha := edit.handle_for_base(ov, at_node(d, "div", "a")) or_return
		edit.set_fact(ov, ha, .Comment_Inline, {"after a"}) or_return
		hdiv := edit.handle_for_base(ov, at_node(d, "div")) or_return
		edit.del_fact(ov, hdiv, .Attribute, "x") or_return
		edit.set_fact(ov, hdiv, .Attribute, {"9"}, "y") or_return
		return edit.set_fact(ov, hdiv, .Attribute, {"2"}, "z")
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<div y='9' z=\"2\"><a>1</a><!-- after a --><b>2</b></div>")

	_, bad_cmt := edited("<div></div>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hdiv := edit.handle_for_base(ov, at_node(d, "div")) or_return
		return edit.set_fact(ov, hdiv, .Comment, {"a --> b"})
	})
	expect_refusal(t, bad_cmt, .Fact_No_Place)

	// Reorder child elements & refuse reorder on `#text`-holding element.
	out, err = edited(SRC, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hdiv := edit.handle_for_base(ov, at_node(d, "div")) or_return
		return edit.reorder(ov, hdiv, {1, 0, 2})
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, out, "<div id=a>\n  <br>\n  <p class=x>t</p>\n  <script>run()</script>\n</div>")

	_, bad_reord := edited("<p>a<b>x</b>c<i>y</i></p>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hp := edit.handle_for_base(ov, at_node(d, "p")) or_return
		return edit.reorder(ov, hp, {0, 3, 2, 1})
	})
	expect_refusal(t, bad_reord, .Layout_Reflow_Needed)
}

@(test)
constructed_nodes_void_rawtext_and_reread_refusals :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	constructed := [?]struct {
		src:  string,
		spec: html.Spec,
		fn:   Edit_Callback,
	} {
		{"<p>x", .Html, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
			h := edit.handle_for_base(ov, at_node(d, "html", "body")) or_return
			return edit.set(ov, h, edit.val_int(1))
		}},
		{"<p>x", .Html, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
			h := edit.handle_for_base(ov, at_node(d, "html")) or_return
			return edit.del_member(ov, h, "head")
		}},
		{"<table><tr><td>1</table>", .Fragment, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
			h := edit.handle_for_base(ov, at_node(d, "table", "tbody")) or_return
			return edit.set(ov, h, edit.val_int(1))
		}},
		{"<table>a<tr><td>1</td></tr></table>", .Fragment, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
			h := edit.handle_for_base(ov, at_node(d, "#text")) or_return
			return edit.set(ov, h, edit.val_string("b"))
		}},
		{"<b>1<p>2</b>3</p>", .Fragment, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
			h := edit.handle_for_base(ov, at_node(d, "p", "b")) or_return
			return edit.set(ov, h, edit.val_int(4))
		}},
		{"<p>a<html lang=x>b</p>", .Html, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
			h := edit.handle_for_base(ov, at_node(d, "html", "body", "p")) or_return
			return edit.set(ov, h, edit.val_string("c"))
		}},
	}
	for c in constructed {
		_, err := edited(c.src, c.fn, c.spec)
		expect_refusal(t, err, .Invalid_Result)
	}

	// Void element cannot take content.
	_, err_void := edited(SRC, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		h := edit.handle_for_base(ov, at_node(d, "div", "br")) or_return
		return edit.set(ov, h, edit.val_string("x"))
	})
	expect_refusal(t, err_void, .Void_Content)

	// Rawtext `<script>` refuses `.Raw` markup.
	_, err_raw := edited(SRC, proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		h := edit.handle_for_base(ov, at_node(d, "div", "script")) or_return
		return edit.set(ov, h, edit.val_raw("<b>x</b>"))
	})
	expect_refusal(t, err_raw, .Text_Markup)

	// Reread structure mismatch refusals: `<p><p>x</p></p>`, `{"div": 1}` inside `<p>`, `<td>` inside `<p>`, rename `<p>` to `<table>`.
	rereads := [?]Edit_Callback {
		proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
			h := edit.handle_for_base(ov, at_node(d, "div", "p")) or_return
			return edit.set(ov, h, edit.val_raw("<p>x</p>"))
		},
		proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
			h := edit.handle_for_base(ov, at_node(d, "div", "p")) or_return
			hd := edit.new_node(ov, edit.val_int(1)) or_return
			return edit.set(ov, h, edit.val_object({{key = "div", value = hd}}))
		},
		proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
			h := edit.handle_for_base(ov, at_node(d, "div", "p")) or_return
			_, ierr := edit.insert_member(ov, h, 0, "td", edit.val_int(1))
			return ierr
		},
		proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
			hdiv := edit.handle_for_base(ov, at_node(d, "div")) or_return
			return edit.rename_member(ov, hdiv, "p", "table")
		},
	}
	for cb in rereads {
		_, rerr := edited("<div><p><i>1</i> t</p></div>", cb)
		testing.expect(t, rerr != nil)
	}

	// Valid edits around constructed nodes succeed.
	out, ok_err := edited("<table><tr><td>1</td></tr></table>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		htd := edit.handle_for_base(ov, at_node(d, "table", "tbody", "tr", "td")) or_return
		return edit.set(ov, htd, edit.val_int(3))
	})
	testing.expect_value(t, ok_err, nil)
	testing.expect_value(t, out, "<table><tr><td>3</td></tr></table>")
}

@(test)
commit_document_splices_accurately :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("<!DOCTYPE html><html lang=en><body><div K=1><p>old</p><span>keep</span></div></body></html>\n")
	base, berr := html.build(src, .Html, {}, alloc)
	testing.expect_value(t, berr, nil)
	defer html.destroy(&base)

	ov: html.Overlay
	testing.expect_value(t, html.edit_init(&ov, &base, alloc), nil)
	defer html.edit_destroy(&ov)

	_, e1 := edit.set_path(&ov, {tape.Name("html"), tape.Name("body"), tape.Name("div"), tape.Name("p")}, edit.val_string("updated & clean"))
	testing.expect_value(t, e1, nil)
	hdiv, _ := edit.handle_for_base(&ov, at_node(&base, "html", "body", "div"))
	testing.expect_value(t, edit.set_fact(&ov, hdiv, .Attribute, {"9"}, "K"), nil)

	new_doc, res, cerr := html.commit_document(&ov, {own_src = false}, alloc)
	testing.expect_value(t, cerr, nil)
	defer edit.destroy_commit_result(&res)
	defer html.destroy(&new_doc)

	p_txt, p_kind := text_at(&new_doc, "html", "body", "div", "p")
	testing.expect_value(t, p_kind, tape.Kind.Plain)
	testing.expect_value(t, p_txt, "updated & clean")
	s_txt, _ := text_at(&new_doc, "html", "body", "div", "span")
	testing.expect_value(t, s_txt, "keep")
	div_node, _ := member_at(&new_doc, {"html", "body", "div"})
	kv, has_k := attribute_value(&new_doc, div_node, "k")
	testing.expect(t, has_k && kv == "9")
}

@(test)
deep_tree_and_long_tag_edits :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	defer free_all(context.temp_allocator)

	// 1. Deep 50,000-level nested `<div>` edit + `val_base_ref` with zero stack overflow (iterative tree checks & element lookup).
	DEPTH :: 50_000
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< DEPTH {
		strings.write_string(&b, "<div>")
	}
	strings.write_string(&b, "<p>leaf</p><section>")
	for _ in 0 ..< 5000 {
		strings.write_string(&b, "<b>")
	}
	strings.write_string(&b, "ref")
	for _ in 0 ..< 5000 {
		strings.write_string(&b, "</b>")
	}
	strings.write_string(&b, "</section>")
	for _ in 0 ..< DEPTH {
		strings.write_string(&b, "</div>")
	}
	deep_src := strings.to_string(b)
	doc, berr := html.build(transmute([]u8)deep_src, .Fragment, {budget = {depth = DEPTH + 5100}}, alloc)
	testing.expect_value(t, berr, nil)
	defer html.destroy(&doc)

	// Walk down to the innermost `<div>` without building a 50,000-element path slice.
	cur := html.ROOT
	r := tape.Reader{doc = &doc}
	for {
		next_div, p := tape.member(r, cur, "div", .First)
		if p != .Found {
			break
		}
		cur = next_div
	}
	p_node, pp := tape.member(r, cur, "p", .First)
	sec_node, sp := tape.member(r, cur, "section", .First)
	testing.expect(t, pp == .Found && sp == .Found)

	ov: html.Overlay
	testing.expect_value(t, html.edit_init(&ov, &doc, alloc), nil)
	defer html.edit_destroy(&ov)
	hp, hperr := edit.handle_for_base(&ov, p_node)
	testing.expect_value(t, hperr, nil)
	testing.expect_value(t, edit.set(&ov, hp, edit.val_base_ref(sec_node)), nil)

	res, cerr := html.commit(&ov, {}, alloc)
	testing.expect_value(t, cerr, nil)
	edit.destroy_commit_result(&res)

	// 2. >64-byte and >256-byte lowercase and uppercase tag names edit cleanly without truncation or duplicate closing tags.
	long_low := strings.repeat("x", 100, context.temp_allocator)
	long_up := strings.repeat("Z", 270, context.temp_allocator)
	long_src := strings.concatenate({"<", long_low, ">old</", long_low, "><", long_up, "><p>inner</p></", long_up, ">"}, context.temp_allocator)
	ldoc, lerr := html.build(transmute([]u8)long_src, .Fragment, {}, alloc)
	testing.expect_value(t, lerr, nil)
	defer html.destroy(&ldoc)

	lov: html.Overlay
	testing.expect_value(t, html.edit_init(&lov, &ldoc, alloc), nil)
	defer html.edit_destroy(&lov)
	_, lse1 := edit.set_path(&lov, {tape.Name(long_low)}, edit.val_string("new"))
	_, lse2 := edit.set_path(&lov, {tape.Name(strings.repeat("z", 270, context.temp_allocator)), tape.Name("p")}, edit.val_string("ok"))
	testing.expect(t, lse1 == nil && lse2 == nil)

	lnew, lres, lcerr := html.commit_document(&lov, {}, alloc)
	testing.expect_value(t, lcerr, nil)
	defer edit.destroy_commit_result(&lres)
	defer html.destroy(&lnew)
	want_long := strings.concatenate({"<", long_low, ">new</", long_low, "><", long_up, "><p>ok</p></", long_up, ">"}, context.temp_allocator)
	testing.expect_value(t, string(lres.bytes), want_long)
}

@(test)
uppercase_tags_rawtext_whitespace_and_void :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	out_sc, err_sc := edited("<SCRIPT>a</SCRIPT>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		h := edit.handle_for_base(ov, at_node(d, "script")) or_return
		return edit.set(ov, h, edit.val_string("a<b"))
	})
	testing.expect_value(t, err_sc, nil)
	testing.expect_value(t, out_sc, "<SCRIPT>a<b</SCRIPT>")

	out_ta, err_ta := edited("<TEXTAREA>a</TEXTAREA>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		h := edit.handle_for_base(ov, at_node(d, "textarea")) or_return
		return edit.set(ov, h, edit.val_string("\nb"))
	})
	testing.expect_value(t, err_ta, nil)
	testing.expect_value(t, out_ta, "<TEXTAREA>\n\nb</TEXTAREA>")

	out_st, err_st := edited("<STYLE>a</STYLE><PRE>\n\nx</PRE>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		hs := edit.handle_for_base(ov, at_node(d, "style")) or_return
		edit.set(ov, hs, edit.val_string("a>b")) or_return
		hp := edit.handle_for_base(ov, at_node(d, "pre")) or_return
		return edit.set(ov, hp, edit.val_string("\ny"))
	})
	testing.expect_value(t, err_st, nil)
	testing.expect_value(t, out_st, "<STYLE>a>b</STYLE><PRE>\n\ny</PRE>")

	_, err_img := edited("<IMG src=a>", proc(ov: ^html.Overlay, d: ^html.Document) -> html.Edit_Error {
		h := edit.handle_for_base(ov, at_node(d, "img")) or_return
		return edit.set_fact(ov, h, .Comment_Foot, {"bad"})
	})
	expect_refusal(t, err_img, .Fact_No_Place)
}

@(test)
inferred_budget_cuts_splices_and_base_ref_deltas :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	defer free_all(context.temp_allocator)

	// 1. Inferred doc (`Xml_Options{infer = true}`) preserves inferred types across edits & container deltas.
	{
		doc, err := html.build(transmute([]u8)string("<p><a>1</a><b>true</b></p>"), .Html, {format = html.Xml_Options{infer = true}}, alloc)
		testing.expect_value(t, err, nil)
		defer html.destroy(&doc)

		ov: html.Overlay
		testing.expect_value(t, html.edit_init(&ov, &doc, alloc), nil)
		defer html.edit_destroy(&ov)
		hp, _ := edit.handle_for_base(&ov, at_node(&doc, "html", "body", "p"))
		_, serr := edit.set_member(&ov, hp, "a", edit.val_int(42))
		_, ierr := edit.insert_member(&ov, hp, -1, "c", edit.val_bool(false))
		testing.expect(t, serr == nil && ierr == nil)

		new_doc, res, cerr := html.commit_document(&ov, {}, alloc)
		testing.expect_value(t, cerr, nil)
		defer edit.destroy_commit_result(&res)
		defer html.destroy(&new_doc)
		testing.expect_value(t, string(res.bytes), "<p><a>42</a><b>true</b><c>false</c></p>")
		a_n, a_ok := member_at(&new_doc, {"html", "body", "p", "a"})
		b_n, b_ok := member_at(&new_doc, {"html", "body", "p", "b"})
		c_n, c_ok := member_at(&new_doc, {"html", "body", "p", "c"})
		testing.expect(t, a_ok && b_ok && c_ok)
		testing.expect_value(t, new_doc.nodes[a_n].kind, tape.Kind.Number)
		testing.expect_value(t, new_doc.nodes[b_n].kind, tape.Kind.True)
		testing.expect_value(t, new_doc.nodes[c_n].kind, tape.Kind.False)
	}

	// 2. Document nested >1024 levels propagates `Budget.depth` across commit and `commit_document`.
	{
		D :: 1200
		sb := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< D {
			strings.write_string(&sb, "<div>")
		}
		strings.write_string(&sb, "<p>before</p>")
		for _ in 0 ..< D {
			strings.write_string(&sb, "</div>")
		}
		src := strings.to_string(sb)
		doc, err := html.build(transmute([]u8)src, .Fragment, {budget = {depth = D + 64}}, alloc)
		testing.expect_value(t, err, nil)
		defer html.destroy(&doc)

		cur := html.ROOT
		r := tape.Reader{doc = &doc}
		for {
			next_div, p := tape.member(r, cur, "div", .First)
			if p != .Found {
				break
			}
			cur = next_div
		}
		p_n, _ := tape.member(r, cur, "p", .First)
		ov: html.Overlay
		testing.expect_value(t, html.edit_init(&ov, &doc, alloc), nil)
		defer html.edit_destroy(&ov)
		hp, _ := edit.handle_for_base(&ov, p_n)
		testing.expect_value(t, edit.set(&ov, hp, edit.val_string("after")), nil)

		new_doc, res, cerr := html.commit_document(&ov, {}, alloc)
		testing.expect_value(t, cerr, nil)
		defer edit.destroy_commit_result(&res)
		defer html.destroy(&new_doc)
		cur2 := html.ROOT
		r2 := tape.Reader{doc = &new_doc}
		for {
			next_div, p := tape.member(r2, cur2, "div", .First)
			if p != .Found {
				break
			}
			cur2 = next_div
		}
		p2, _ := tape.member(r2, cur2, "p", .First)
		testing.expect_value(t, text_of(&new_doc, p2), "after")
	}

	// 3. `apply_read_on_cuts` preserves splice alignment, updates `res.splices`, and `commit_document` succeeds + preserves context.
	{
		src := transmute([]u8)string("<p>a</body></html>\n")
		doc, err := html.build(src, .Html, {}, alloc)
		testing.expect_value(t, err, nil)
		defer html.destroy(&doc)

		ov: html.Overlay
		testing.expect_value(t, html.edit_init(&ov, &doc, alloc), nil)
		defer html.edit_destroy(&ov)
		_, serr := edit.set_path(&ov, {tape.Name("html"), tape.Name("body"), tape.Name("p")}, edit.val_string("X"))
		testing.expect_value(t, serr, nil)

		// Verify `text_past` inherits caller `context` cleanly when `temp_allocator` rejects.
		new_doc, res, cerr := html.commit_document(&ov, {}, alloc)
		testing.expect_value(t, cerr, nil)
		defer edit.destroy_commit_result(&res)
		defer html.destroy(&new_doc)
		testing.expect_value(t, string(res.bytes), "<p>X</body></html>")
		testing.expect(t, len(res.splices) >= 2)
		for sr in res.splices {
			testing.expect(t, sr.dst_lo <= sr.dst_hi && sr.dst_hi <= u64(len(res.bytes)))
			testing.expect(t, sr.src_lo <= sr.src_hi && sr.src_hi <= u64(len(src)))
		}
		// Check cut BEFORE a second edited element (`<td>c</td>`) shifts subsequent `dst_lo`/`dst_hi`.
		src2 := transmute([]u8)string("<table><tr><td>ba</div>\n</span></td><td>c</td></table>")
		doc2, err2 := html.build(src2, .Html, {}, alloc)
		testing.expect_value(t, err2, nil)
		defer html.destroy(&doc2)
		ov2: html.Overlay
		testing.expect_value(t, html.edit_init(&ov2, &doc2, alloc), nil)
		defer html.edit_destroy(&ov2)
		tr2 := at_node(&doc2, "html", "body", "table", "tbody", "tr")
		td0, _ := nth_member(&doc2, tr2, "td", 0)
		td1, _ := nth_member(&doc2, tr2, "td", 1)
		h0, _ := edit.handle_for_base(&ov2, td0)
		h1, _ := edit.handle_for_base(&ov2, td1)
		s2a := edit.set(&ov2, h0, edit.val_string("X"))
		s2b := edit.set(&ov2, h1, edit.val_string("ZZZ"))
		testing.expect(t, s2a == nil && s2b == nil)
		nd2, res2, c2 := html.commit_document(&ov2, {}, alloc)
		testing.expect_value(t, c2, nil)
		defer edit.destroy_commit_result(&res2)
		defer html.destroy(&nd2)
		testing.expect_value(t, string(res2.bytes), "<table><tr><td>X</div></span></td><td>ZZZ</td></table>")
		// Verify applying `res2.splices` from `src2` reproduces `res2.bytes` byte-for-byte.
		rebuilt := strings.builder_make(context.temp_allocator)
		src_pos := u64(0)
		for sr in res2.splices {
			strings.write_bytes(&rebuilt, src2[src_pos:sr.src_lo])
			strings.write_bytes(&rebuilt, res2.bytes[sr.dst_lo:sr.dst_hi])
			src_pos = sr.src_hi
		}
		strings.write_bytes(&rebuilt, src2[src_pos:])
		testing.expect_value(t, strings.to_string(rebuilt), string(res2.bytes))
		tr_nd := at_node(&nd2, "html", "body", "table", "tbody", "tr")
		nd_td0, _ := nth_member(&nd2, tr_nd, "td", 0)
		nd_td1, _ := nth_member(&nd2, tr_nd, "td", 1)
		testing.expect_value(t, text_of(&nd2, nd_td0), "X")
		testing.expect_value(t, text_of(&nd2, nd_td1), "ZZZ")
	}

	// 4. `.Base_Ref` container deltas & fact checks via `edit.node_base_container(n)`.
	{
		src := `<div K=1><p>hello</p><span>stay</span></div>`
		doc, err := html.build(transmute([]u8)src, .Fragment, {}, alloc)
		testing.expect_value(t, err, nil)
		defer html.destroy(&doc)

		ov: html.Overlay
		testing.expect_value(t, html.edit_init(&ov, &doc, alloc), nil)
		defer html.edit_destroy(&ov)
		hroot, _ := edit.ensure_root(&ov)
		div_b := at_node(&doc, "div")
		hdiv, _ := edit.handle_for_base(&ov, div_b)
		_, orig_perr := edit.set_path(&ov, {tape.Name("div"), tape.Name("p")}, edit.val_string("orig"))
		testing.expect_value(t, orig_perr, nil)

		copy_h, cerr0 := edit.insert_member(&ov, hroot, -1, "section", edit.val_base_ref(div_b))
		testing.expect_value(t, cerr0, nil)
		_, sm_err := edit.set_member(&ov, copy_h, "p", edit.val_string("copied"))
		testing.expect_value(t, sm_err, nil)
		testing.expect_value(t, edit.set_fact(&ov, copy_h, .Attribute, {"9"}, "k"), nil)
		_ = hdiv

		nd, res, cerr := html.commit_document(&ov, {}, alloc)
		testing.expect_value(t, cerr, nil)
		defer edit.destroy_commit_result(&res)
		defer html.destroy(&nd)
		testing.expect_value(t, string(res.bytes), `<div K=1><p>orig</p><span>stay</span></div><section K="9"><p>copied</p><span>stay</span></section>`)
		op, _ := text_at(&nd, "div", "p")
		cp, _ := text_at(&nd, "section", "p")
		testing.expect_value(t, op, "orig")
		testing.expect_value(t, cp, "copied")

		// `.Base_Ref` on void `<img>` with `.Comment_Foot` must be refused via `node_base_container`.
		vdoc, verr := html.build(transmute([]u8)string(`<div><IMG src=a></div>`), .Fragment, {}, alloc)
		testing.expect_value(t, verr, nil)
		defer html.destroy(&vdoc)
		vov: html.Overlay
		testing.expect_value(t, html.edit_init(&vov, &vdoc, alloc), nil)
		defer html.edit_destroy(&vov)
		vr, _ := edit.ensure_root(&vov)
		ih, _ := edit.insert_member(&vov, vr, -1, "img", edit.val_base_ref(at_node(&vdoc, "div", "img")))
		testing.expect_value(t, edit.set_fact(&vov, ih, .Comment_Foot, {"bad"}), nil)
		_, bad_void_ref := html.commit(&vov, {}, alloc)
		expect_refusal(t, bad_void_ref, .Fact_No_Place)

		// `.Base_Ref` on `<svg>` allows SVG mixed-case attribute `viewBox` via `node_base_container`.
		sdoc, serr := html.build(transmute([]u8)string(`<svg viewBox="0 0 1 1"><circle r="1"/></svg>`), .Fragment, {}, alloc)
		testing.expect_value(t, serr, nil)
		defer html.destroy(&sdoc)
		sov: html.Overlay
		testing.expect_value(t, html.edit_init(&sov, &sdoc, alloc), nil)
		defer html.edit_destroy(&sov)
		sr, _ := edit.ensure_root(&sov)
		svgh, _ := edit.insert_member(&sov, sr, -1, "svg", edit.val_base_ref(at_node(&sdoc, "svg")))
		testing.expect_value(t, edit.set_fact(&sov, svgh, .Attribute, {"0 0 2 2"}, "viewBox"), nil)
		sres, scerr := html.commit(&sov, {}, alloc)
		testing.expect_value(t, scerr, nil)
		edit.destroy_commit_result(&sres)
	}
}
