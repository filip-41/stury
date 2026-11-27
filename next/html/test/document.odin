// The document an HTML5 text builds, entry points via `as`/`reads`, inference, attributes, namespaces, and diff parity with XML.
package html_tests

import "core:strings"
import "core:testing"
import "stury:html"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

@(test)
markup_builds_the_shape_xml_builds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	cases := [?]string {
		`<r><a>x</a><b></b><c k="v" j='w'>y</c></r>`,
		"<r>t<c>x</c>u\nv</r>",
		"<r><!--one--><a>1</a> <!--two-->\n<!--three--><b>2</b><!--foot--></r>",
		`<r><e>1<!--c-->2</e><f></f><g><?pi data?><b>1</b></g></r>`,
		`<r> <a>1</a> <a>2</a> </r>`,
		`<r><p>x &amp; y &lt; z</p><q k="&quot;1&quot;">2</q></r>`,
		"<r>\n  <item n=\"1\">one</item>\n  <!-- between -->\n  <item n=\"2\"><b>two</b> and <i>2</i></item>\n</r>",
		`<r><a>1</a><!--x--> <b>2</b> tail <!--y--></r>`,
	}
	for c in cases {
		got := shape(t, c, .Fragment)
		xdoc, xerr := xml.build(transmute([]u8)c, .Xml, {}, context.temp_allocator)
		testing.expectf(t, xerr == nil, "%v", xerr)
		want := markup_shape(&xdoc)
		testing.expectf(t, got == want, "%s\n html %s\n xml  %s", c, got, want)
	}
}

@(test)
a_document_is_its_root_element_with_the_implied_ones :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, shape(t, "<p>x", .Html), `{"html": {"head": null, "body": {"p": "x"}}}`)
	testing.expect_value(t, shape(t, "<!DOCTYPE html><!--pre--><html lang=en><title>T</title><p>x</html><!--post-->", .Html), `{<!<!DOCTYPE html>> "html": {<!--pre--> @lang="en" <!--post-->^ "head": {"title": "T"}, "body": {"p": "x"}}}`)
	testing.expect_value(t, shape(t, "<table><tr><td>1</table>", .Fragment), `{"table": {"tbody": {"tr": {"td": "1"}}}}`)
	testing.expect_value(t, shape(t, "text only", .Fragment), `{"#text": "text only"}`)
	testing.expect_value(t, shape(t, "", .Fragment), `{}`)
	testing.expect_value(t, shape_fragment(t, "<td>1<td>2", {context_name = "tr"}), `{"td": "1", "td": "2"}`)
}

@(test)
names_read_as_the_standard_reads_them :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, shape(t, `<DIV ID=a Data-X="1"><Custom-El>x</CUSTOM-EL></DIV>`), `{"div": {@id="a" @data-x="1" "custom-el": "x"}}`)
	testing.expect_value(t, shape(t, `<svg VIEWBOX="0 0 1 1"><foreignobject><p>x</p></foreignobject><clippath/></svg>`), `{"svg": {@viewBox="0 0 1 1" "foreignObject": {"p": "x"}, "clipPath": null}}`)
	testing.expect_value(t, shape(t, `<math definitionurl=u><mi>x</mi></math>`), `{"math": {@definitionURL="u" "mi": "x"}}`)
	testing.expect_value(t, shape(t, `<svg><a XLINK:HREF=u>1</a></svg>`), `{"svg": {"a": (@xlink:href="u" "1")}}`)
	// `<image>` in HTML renames to `img` and matches `.img`.
	testing.expect_value(t, shape(t, `<IMAGE src=x>`), `{"img": (@src="x" null)}`)
	doc, ok := built(t, `<image src=x>`, .Fragment)
	if ok {
		_, found := testkit.member_at(&doc, {"img"})
		testing.expect(t, found)
	}
	// A name with U+0000 reads it as U+FFFD.
	testing.expect_value(t, shape(t, "<a\x00b>x</a\x00b>"), "{\"a\uFFFDb\": \"x\"}")
}

@(test)
a_path_matches_names_as_they_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	doc, ok := built(t, "<HTML><BODY><DIV><SVG><FOREIGNOBJECT>x</FOREIGNOBJECT></SVG></DIV></BODY></HTML>", .Html)
	if !ok {
		return
	}
	s, k := testkit.text_at(&doc, "html", "body", "div", "svg", "foreignObject")
	testing.expect_value(t, s, "x")
	testing.expect_value(t, k, tape.Kind.Plain)
	_, found := testkit.member_at(&doc, {"html", "body", "DIV"})
	testing.expect(t, !found)
	_, found = testkit.member_at(&doc, {"html", "body", "div", "svg", "foreignobject"})
	testing.expect(t, !found)
}

@(test)
attributes_read_as_facts_whatever_their_quotes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	LONG :: "<p " + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" + " = 'w' b>x</p>"
	doc, ok := built(t, "<p a=1 b='two' c=\"3 &amp; 4\" d e=&lt;x f='café' g=\"\" A=dup>x</p>" + LONG, .Fragment)
	if !ok {
		return
	}
	p, _ := html.member(reader(&doc), html.ROOT, "p", .First)
	got := testkit.attributes_of(&doc, p)
	want := [?]testkit.Attribute{{"a", "1"}, {"b", "two"}, {"c", "3 & 4"}, {"d", ""}, {"e", "<x"}, {"f", "café"}, {"g", ""}}
	testing.expect_value(t, len(got), len(want))
	for w, idx in want {
		testing.expectf(t, idx < len(got) && got[idx] == w, "attr %d: got %v want %v", idx, got, w)
	}
	// Raw attribute value tokens hold source bytes between quotes; valueless attribute has empty value.
	bodies := make([dynamic]string, context.temp_allocator)
	for f in html.facts_of(&doc, p) {
		if f.kind == .Attribute {
			_, vtok := doc.format.attribute(&doc, f)
			append(&bodies, string(doc.src[vtok.lo:vtok.lo + u64(vtok.n)]))
		}
	}
	testing.expect_value(t, len(bodies), len(want))
	if len(bodies) == len(want) {
		testing.expect_value(t, bodies[2], "3 &amp; 4")
		testing.expect_value(t, bodies[3], "")
		testing.expect_value(t, bodies[4], "&lt;x")
	}
	// Long attribute past inline lead finds its value from its name.
	second, _ := html.member(reader(&doc), html.ROOT, "p", .Last)
	attrs2 := testkit.attributes_of(&doc, second)
	testing.expect_value(t, len(attrs2), 2)
	if len(attrs2) == 2 {
		testing.expect_value(t, len(attrs2[0].name), len(LONG) - len("<p  = 'w' b>x</p>"))
		testing.expect_value(t, attrs2[0].value, "w")
		testing.expect_value(t, attrs2[1].name, "b")
		testing.expect_value(t, attrs2[1].value, "")
	}
}

@(test)
text_reads_as_the_tokenizer_read_it :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	doc, ok := built(t, "<p>a\x00b &nGt; &#x41;&amp</p><textarea>\r\nx &lt; y\r</textarea><script>if (a < b && c) {}</script><style>&amp;</style><pre>\nline</pre><p>caf\xe9</p>", .Fragment)
	if !ok {
		return
	}
	first, _ := html.member(reader(&doc), html.ROOT, "p", .First)
	testing.expect_value(t, testkit.scalar_text(&doc, first), "ab \u226b\u20d2 A&")
	s, _ := testkit.text_at(&doc, "textarea")
	testing.expect_value(t, s, "x < y\n")
	s, _ = testkit.text_at(&doc, "script")
	testing.expect_value(t, s, "if (a < b && c) {}")
	s, _ = testkit.text_at(&doc, "style")
	testing.expect_value(t, s, "&amp;")
	s, _ = testkit.text_at(&doc, "pre")
	testing.expect_value(t, s, "line")
	last, _ := html.member(reader(&doc), html.ROOT, "p", .Last)
	testing.expect_value(t, testkit.scalar_text(&doc, last), "caf\uFFFD")
}

@(test)
moved_and_merged_text_reads_whole :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, shape(t, "<table>a<tr><td>1</td></tr>b&amp;c</table>"), `{"#text": "ab&c", "table": {"tbody": {"tr": {"td": "1"}}}}`)
	testing.expect_value(t, shape(t, "<p>one<!--x--> two &amp;<!--y--> three</p>"), `{"p": (<!--x-->$ <!--y-->$ "one two & three")}`)
	testing.expect_value(t, shape(t, "<b>1<p>2</b>3</p>"), `{"b": "1", "p": {"b": "2", "#text": "3"}}`)
	doc, ok := built(t, "<table>a<tr><td>1</td></tr>b</table>", .Fragment)
	if !ok {
		return
	}
	clone, cerr := tape.clone_document(&doc, context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	txt, found := html.member(reader(&clone), html.ROOT, "#text")
	testing.expect_value(t, found, tape.Presence.Found)
	testing.expect_value(t, testkit.scalar_text(&clone, txt), "ab")
}

@(test)
inference_types_a_text_value_only_when_asked :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := `<a><n>12</n><t>true</t><s> 1</s><e><!--x--></e><d>&#49;&#50;</d></a>`
	plain, _ := built(t, text, .Fragment)
	_, k := testkit.text_at(&plain, "a", "n")
	testing.expect_value(t, k, tape.Kind.Plain)
	_, k = testkit.text_at(&plain, "a", "e")
	testing.expect_value(t, k, tape.Kind.Null)

	inferred, _ := built(t, text, .Fragment, {format = html.Xml_Options{infer = true}})
	_, k = testkit.text_at(&inferred, "a", "n")
	testing.expect_value(t, k, tape.Kind.Number)
	_, k = testkit.text_at(&inferred, "a", "t")
	testing.expect_value(t, k, tape.Kind.True)
	_, k = testkit.text_at(&inferred, "a", "s")
	testing.expect_value(t, k, tape.Kind.Plain)
	s_d, k_d := testkit.text_at(&inferred, "a", "d")
	testing.expect_value(t, s_d, "12")
	testing.expect_value(t, k_d, tape.Kind.Plain)
	n, _ := testkit.member_at(&inferred, {"a", "n"})
	v, num := html.node_number(&inferred, n)
	testing.expect_value(t, num, true)
	testing.expect_value(t, v, html.Number{12, .Int})
}

@(test)
an_element_names_its_namespace_and_content :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	doc, ok := built(t, "<P>a<b>b<!--c-->c</b>d</P><svg><foreignobject>e</foreignobject></svg><math><mi>f</mi></math>", .Fragment)
	if !ok {
		return
	}
	p, _ := testkit.member_at(&doc, {"p"})
	testing.expect_value(t, testkit.scalar_text(&doc, p - 1), "p")
	content_str, has_content := html.content(&doc, p, context.temp_allocator)
	testing.expect(t, has_content)
	testing.expect_value(t, content_str, "abcd")
	ns, has_ns := doc.format.namespace(&doc, p)
	testing.expect_value(t, has_ns, tape.Presence.Found)
	testing.expect_value(t, ns, "http://www.w3.org/1999/xhtml")

	fo, _ := testkit.member_at(&doc, {"svg", "foreignObject"})
	testing.expect_value(t, testkit.scalar_text(&doc, fo - 1), "foreignObject")
	ns, has_ns = doc.format.namespace(&doc, fo)
	testing.expect_value(t, has_ns, tape.Presence.Found)
	testing.expect_value(t, ns, "http://www.w3.org/2000/svg")

	mi, _ := testkit.member_at(&doc, {"math", "mi"})
	ns, has_ns = doc.format.namespace(&doc, mi)
	testing.expect_value(t, has_ns, tape.Presence.Found)
	testing.expect_value(t, ns, "http://www.w3.org/1998/Math/MathML")

	_, root_has_ns := doc.format.namespace(&doc, html.ROOT)
	testing.expect_value(t, root_has_ns, tape.Presence.Missing)
}

@(test)
a_template_and_element_spans :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, shape(t, "<template><li>1</li><li>2</li></template>"), `{"template": {"li": "1", "li": "2"}}`)

	text := "<div id=a><p>x</p><p>y</div><span>z</span>"
	doc, ok := built(t, text, .Fragment)
	if !ok {
		return
	}
	div, _ := testkit.member_at(&doc, {"div"})
	end, has_end := doc.format.close_end(&doc, div)
	testing.expect(t, has_end)
	testing.expect_value(t, string(doc.src[doc.nodes[div].lo:end]), "<div id=a><p>x</p><p>y</div>")
	p, _ := testkit.member_at(&doc, {"div", "p"})
	testing.expect_value(t, string(html.span_bytes(&doc, doc.nodes[p].lo, doc.nodes[p].n)), "x")
}

@(test)
every_entry_point_and_fragment_options :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string("<!doctype html><ul><li>1<li><b>2</b></ul>")
	path := []html.Step{html.Name("html"), html.Name("body"), html.Name("ul"), html.Name("li")}
	reads, f := html.reads(.Html), html.as(.Html)

	testing.expect_value(t, html.validate(src), nil)
	testing.expect_value(t, reads.validate(f, src, {}, context.allocator), nil)

	doc, derr := html.build(src, .Html, {}, context.temp_allocator)
	testing.expect_value(t, derr, nil)
	chosen, cerr := reads.build(f, src, {}, context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	testing.expect_value(t, len(chosen.nodes), len(doc.nodes))
	testing.expect_value(t, len(chosen.facts), len(doc.facts))

	a, ferr := html.find(src, path)
	testing.expect_value(t, ferr, nil)
	b, gerr := reads.find(f, src, path, {}, {}, context.allocator)
	testing.expect_value(t, gerr, nil)
	testing.expect_value(t, b, a)
	testing.expect_value(t, a.outcome, tape.Presence.Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), "1")

	demand, _ := html.demand_of({path}, allocator = context.temp_allocator)
	sdoc, serr := html.scan(src, &demand, .Html, {}, {}, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	cdoc, hderr := reads.scan(f, src, &demand, {}, {}, context.temp_allocator)
	testing.expect_value(t, hderr, nil)
	testing.expect_value(t, len(cdoc.nodes), len(sdoc.nodes))

	// `noscript` changes tokenization rules depending on `scripting`.
	no_src := transmute([]u8)string("<body><noscript><p>12</p></noscript><n>12</n>")
	d_plain, err1 := html.build(no_src, .Html, {format = html.Xml_Options{infer = true}}, context.temp_allocator)
	testing.expect_value(t, err1, nil)
	n_node, _ := testkit.member_at(&d_plain, {"html", "body", "n"})
	testing.expect_value(t, d_plain.nodes[n_node].kind, tape.Kind.Number)
	_, has_np := testkit.member_at(&d_plain, {"html", "body", "noscript", "p"})
	testing.expect(t, has_np)

	d_frag, err2 := html.build_fragment(transmute([]u8)string("<p>12</p>"), {context_name = "noscript", scripting = true}, {}, context.temp_allocator)
	testing.expect_value(t, err2, nil)
	txt, has_t := testkit.member_at(&d_frag, {"#text"})
	testing.expect(t, has_t)
	testing.expect_value(t, testkit.scalar_text(&d_frag, txt), "<p>12</p>")

	// `dups = .Refuse` on repeated siblings.
	rep := transmute([]u8)string("<a>1</a><a>2</a>")
	_, dup_err := html.build(rep, .Fragment, {dups = .Refuse}, context.temp_allocator)
	f_dup, is_fault := dup_err.(tape.Fault)
	testing.expect(t, is_fault && testkit.code_of(dup_err) == "duplicate_key" && f_dup.at > 0)

	// Invalid options are refused consistently.
	testing.expect_value(t, html.validate(rep, .Fragment, {format = tape.Dsv_Options{}}), html.Error(html.Bad_Option{"format"}))
	testing.expect_value(t, html.validate(rep, .Fragment, {tolerate = {.Invalid_Utf8}}), html.Error(html.Bad_Option{"tolerate"}))
	deep := strings.repeat("<div>", 4, context.temp_allocator)
	derr_depth := html.validate(transmute([]u8)deep, .Fragment, {budget = {depth = 2}})
	ex, is_ex := derr_depth.(html.Exceeded)
	testing.expect(t, is_ex && ex.kind == .Depth)
}

@(test)
an_html_document_and_xml_compare_equal :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := `<r><item n="1">one</item><!--c--><item n="2"><b>two</b> and <i>2</i></item></r>`
	doc, ok := built(t, text, .Fragment)
	if !ok {
		return
	}
	xdoc, xerr := xml.build(transmute([]u8)text, .Xml, {}, context.temp_allocator)
	testing.expect_value(t, xerr, nil)
	testkit.values_agree(t, &doc, html.ROOT, &xdoc, xml.ROOT, {facts = {.Attribute, .Comment}}, "html vs xml")
}
