// The document an HTML text builds, in the shape an XML text with the same markup builds, and the reads over it:
// values, text, attributes, facts, implied and moved nodes, and names as the standard reads them.
package html_tests

import "core:testing"
import core "../../core"
import diff "../../core/diff"
import html ".."
import xml "../../xml"
import walktest "../../walktest"

@(private)
built :: proc(t: ^testing.T, text: string, spec := html.Spec.Document, opts := html.Options{}, loc := #caller_location) -> (doc: core.Document, ok: bool) {
	d, err := html.build(transmute([]u8)text, spec, opts)
	testing.expectf(t, err == nil, "%v", err, loc = loc)
	return d, err == nil
}

// The shape of `text` read as `spec`, "" when it does not build.
@(private)
shape :: proc(t: ^testing.T, text: string, spec := html.Spec.Fragment, opts := html.Options{}, loc := #caller_location) -> string {
	doc, ok := built(t, text, spec, opts, loc)
	if !ok {
		return ""
	}
	defer core.destroy(&doc)
	return walktest.markup_shape(&doc)
}

// The shape of `text` read as an XML document.
@(private)
xml_shape :: proc(t: ^testing.T, text: string, loc := #caller_location) -> string {
	doc, err := xml.build(transmute([]u8)text, .Xml)
	testing.expectf(t, err == nil, "%v", err, loc = loc)
	defer core.destroy(&doc)
	return walktest.markup_shape(&doc)
}

// Markup that an HTML fragment and an XML document read alike: names an HTML tree keeps where they stand, every
// element closed by its end tag, and comments and instructions where both read them.
@(test)
markup_builds_the_shape_xml_builds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]string {
		`<r><a>x</a><b></b><c k="v" j='w'>y</c></r>`,
		"<r>t<c>x</c>u\nv</r>",
		"<r><!--one--><a>1</a> <!--two-->\n<!--three--><b>2</b><!--foot--></r>",
		`<r><e>1<!--c-->2</e><f></f><g><?pi data?></g></r>`,
		`<r> <a>1</a> <a>2</a> </r>`,
		`<r><p>x &amp; y &lt; z</p><q k="&quot;1&quot;">2</q></r>`,
		"<r>\n  <item n=\"1\">one</item>\n  <!-- between -->\n  <item n=\"2\"><b>two</b> and <i>2</i></item>\n</r>",
		`<r><a>1</a><!--x--> <b>2</b> tail <!--y--></r>`,
	}
	for c in cases {
		got, want := shape(t, c), xml_shape(t, c)
		testing.expectf(t, got == want, "%s\n html %s\n xml  %s", c, got, want)
	}
}

@(test)
a_document_is_its_root_element_with_the_implied_ones :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, shape(t, "<p>x", .Document), `{"html": {"head": null, "body": {"p": "x"}}}`)
	testing.expect_value(t, shape(t, "<!DOCTYPE html><!--pre--><html lang=en><title>T</title><p>x</html><!--post-->", .Document), `{<!<!DOCTYPE html>> <!--pre--> "html": {@lang="en" <!--post-->^ "head": {"title": "T"}, "body": {"p": "x"}}}`)
	testing.expect_value(t, shape(t, "<table><tr><td>1</table>", .Fragment), `{"table": {"tbody": {"tr": {"td": "1"}}}}`)
	testing.expect_value(t, shape(t, "text only", .Fragment), `{"#text": "text only"}`)
	testing.expect_value(t, shape(t, "", .Fragment), `{}`)
	testing.expect_value(t, shape(t, "<td>1<td>2", .Fragment, {context_name = "tr"}), `{"td": "1", "td": "2"}`)
}

@(test)
names_read_as_the_standard_reads_them :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, shape(t, `<DIV ID=a Data-X="1"><Custom-El>x</CUSTOM-EL></DIV>`), `{"div": {@id="a" @data-x="1" "custom-el": "x"}}`)
	testing.expect_value(t, shape(t, `<svg VIEWBOX="0 0 1 1"><foreignobject><p>x</p></foreignobject><clippath/></svg>`), `{"svg": {@viewBox="0 0 1 1" "foreignObject": {"p": "x"}, "clipPath": null}}`)
	testing.expect_value(t, shape(t, `<math definitionurl=u><mi>x</mi></math>`), `{"math": {@definitionURL="u" "mi": "x"}}`)
	testing.expect_value(t, shape(t, `<svg><a XLINK:HREF=u>1</a></svg>`), `{"svg": {"a": (@xlink:href="u" "1")}}`)
	// A start tag the tree renames reads as the element it makes, and matches a path by that name.
	testing.expect_value(t, shape(t, `<IMAGE src=x>`), `{"img": (@src="x" null)}`)
	doc, ok := built(t, `<image src=x>`, .Fragment)
	if ok {
		_, found := walktest.member_at(t, &doc, ".img")
		testing.expect(t, found)
		core.destroy(&doc)
	}
	// A name with U+0000 reads it as U+FFFD.
	testing.expect_value(t, shape(t, "<a\x00b>x</a\x00b>"), "{\"a�b\": \"x\"}")
}

@(test)
a_path_matches_names_as_they_read :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, ok := built(t, "<HTML><BODY><DIV><SVG><FOREIGNOBJECT>x</FOREIGNOBJECT></SVG></DIV></BODY></HTML>")
	if !ok {
		return
	}
	defer core.destroy(&doc)
	s, k := walktest.text_at(t, &doc, ".html.body.div.svg.foreignObject")
	testing.expect_value(t, s, "x")
	testing.expect_value(t, k, core.Kind.String)
	_, found := walktest.member_at(t, &doc, ".html.body.DIV")
	testing.expect(t, !found)
	_, found = walktest.member_at(t, &doc, ".html.body.div.svg.foreignobject")
	testing.expect(t, !found)
}

@(test)
attributes_read_as_facts_whatever_their_quotes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	LONG :: "<p " + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" + " = 'w' b>x</p>"
	doc, ok := built(t, "<p a=1 b='two' c=\"3 &amp; 4\" d e=&lt;x f='café' g=\"\" A=dup>x</p>" + LONG, .Fragment)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	p, _ := core.member(&doc, core.ROOT, "p", .First)
	it := core.attributes_of(&doc, p)
	want := [?][2]string{{"a", "1"}, {"b", "two"}, {"c", "3 & 4"}, {"d", ""}, {"e", "<x"}, {"f", "café"}, {"g", ""}}
	k := 0
	for name, value in walktest.attribute_texts(&it) {
		if k < len(want) {
			testing.expect_value(t, name, want[k][0])
			testing.expect_value(t, value, want[k][1])
		}
		k += 1
	}
	testing.expect_value(t, k, len(want))
	// Core reads the value as written between its quotes, and the valueless attribute's body is empty.
	bodies: [dynamic]string
	defer delete(bodies)
	facts := core.facts_of(&doc, p, .Attribute)
	for body in core.fact_next(&facts) {
		append(&bodies, body)
	}
	testing.expect_value(t, len(bodies), len(want))
	if len(bodies) == len(want) {
		testing.expect_value(t, bodies[2], "3 &amp; 4")
		testing.expect_value(t, bodies[3], "")
		testing.expect_value(t, bodies[4], "&lt;x")
	}
	// A value that stands past the longest lead is found from its name.
	second, _ := core.member(&doc, core.ROOT, "p", .Last)
	it = core.attributes_of(&doc, second)
	name, value, found := walktest.attribute_texts(&it)
	testing.expect(t, found)
	testing.expect_value(t, len(name), len(LONG) - len("<p  = 'w' b>x</p>"))
	testing.expect_value(t, value, "w")
	name, value, found = walktest.attribute_texts(&it)
	testing.expect_value(t, name, "b")
	testing.expect_value(t, value, "")
}

@(test)
text_reads_as_the_tokenizer_read_it :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, ok := built(t, "<p>a\x00b &nGt; &#x41;&amp</p><textarea>\r\nx &lt; y\r</textarea><script>if (a < b && c) {}</script><style>&amp;</style><pre>\nline</pre><p>caf\xe9</p>", .Fragment)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	first, _ := core.member(&doc, core.ROOT, "p", .First)
	testing.expect_value(t, walktest.node_text(t, &doc, first), "ab \u226b\u20d2 A&")
	s: string
	s, _ = walktest.text_at(t, &doc, ".textarea")
	testing.expect_value(t, s, "x < y\n")
	s, _ = walktest.text_at(t, &doc, ".script")
	testing.expect_value(t, s, "if (a < b && c) {}")
	s, _ = walktest.text_at(t, &doc, ".style")
	testing.expect_value(t, s, "&amp;")
	s, _ = walktest.text_at(t, &doc, ".pre")
	testing.expect_value(t, s, "line")
	last, _ := core.member(&doc, core.ROOT, "p", .Last)
	testing.expect_value(t, walktest.node_text(t, &doc, last), "caf�")
}

// Text the tree construction moves or merges is one value whose pieces lie apart in the source.
@(test)
moved_and_merged_text_reads_whole :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, shape(t, "<table>a<tr><td>1</td></tr>b&amp;c</table>"), `{"#text": "ab&c", "table": {"tbody": {"tr": {"td": "1"}}}}`)
	testing.expect_value(t, shape(t, "<p>one<!--x--> two &amp;<!--y--> three</p>"), `{"p": (<!--x--> <!--y--> "one two & three")}`)
	testing.expect_value(t, shape(t, "<b>1<p>2</b>3</p>"), `{"b": "1", "p": {"b": "2", "#text": "3"}}`)
	doc, ok := built(t, "<table>a<tr><td>1</td></tr>b</table>", .Fragment)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	clone, cerr := core.clone(&doc)
	testing.expect_value(t, cerr, nil)
	defer core.destroy(&clone)
	text, found := core.member(&clone, core.ROOT, "#text")
	testing.expect(t, found)
	testing.expect_value(t, walktest.node_text(t, &clone, text), "ab")
}

@(test)
inference_types_a_text_value_only_when_asked :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `<a><n>12</n><t>true</t><s> 1</s><e><!--x--></e><d>&#49;&#50;</d></a>`
	plain, _ := built(t, text, .Fragment)
	defer core.destroy(&plain)
	_, k := walktest.text_at(t, &plain, ".a.n")
	testing.expect_value(t, k, core.Kind.String)
	_, k = walktest.text_at(t, &plain, ".a.e")
	testing.expect_value(t, k, core.Kind.Null)
	inferred, _ := built(t, text, .Fragment, {infer = true})
	defer core.destroy(&inferred)
	_, k = walktest.text_at(t, &inferred, ".a.n")
	testing.expect_value(t, k, core.Kind.Number)
	_, k = walktest.text_at(t, &inferred, ".a.t")
	testing.expect_value(t, k, core.Kind.True)
	_, k = walktest.text_at(t, &inferred, ".a.s")
	testing.expect_value(t, k, core.Kind.String)
	_, k = walktest.text_at(t, &inferred, ".a.d")
	testing.expect_value(t, k, core.Kind.Number)
	n, _ := walktest.member_at(t, &inferred, ".a.n")
	v, num := core.int_value(&inferred, n)
	testing.expect_value(t, num, true)
	testing.expect_value(t, v, 12)
	d, _ := walktest.member_at(t, &inferred, ".a.d")
	v, num = core.int_value(&inferred, d)
	testing.expect_value(t, num, true)
	testing.expect_value(t, v, 12)
	buf: [core.HEX_ROOM]u8
	_, digits, read := core.double_of(core.Node_Ref{&inferred, d}, buf[:])
	testing.expect(t, read)
	testing.expect_value(t, digits, "12")
}

@(test)
an_element_names_its_name_namespace_and_content :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, ok := built(t, "<P>a<b>b<!--c-->c</b>d</P><svg><foreignobject>e</foreignobject></svg><math><mi>f</mi></math>", .Fragment)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	p, _ := walktest.member_at(t, &doc, ".p")
	name, has_name := core.fact_value(&doc, p, .Name)
	testing.expect(t, has_name)
	testing.expect_value(t, name.text, "p")
	content, _ := core.fact_value(&doc, p, .Content)
	testing.expect_value(t, content.text, "abcd")
	ns, has_ns := core.fact_value(&doc, p, .Namespace)
	testing.expect(t, has_ns)
	testing.expect_value(t, ns.text, "http://www.w3.org/1999/xhtml")
	fo, _ := walktest.member_at(t, &doc, ".svg.foreignObject")
	name, _ = core.fact_value(&doc, fo, .Name)
	testing.expect_value(t, name.text, "foreignObject")
	ns, _ = core.fact_value(&doc, fo, .Namespace)
	testing.expect_value(t, ns.text, "http://www.w3.org/2000/svg")
	mi, _ := walktest.member_at(t, &doc, ".math.mi")
	ns, _ = core.fact_value(&doc, mi, .Namespace)
	testing.expect_value(t, ns.text, "http://www.w3.org/1998/Math/MathML")
	_, has_ns = core.fact_value(&doc, core.ROOT, .Namespace)
	testing.expect(t, !has_ns)
	_, tagged := core.fact_value(&doc, p, .Tag)
	testing.expect(t, !tagged)
}

@(test)
a_template_holds_its_contents_as_members :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, shape(t, "<template><li>1</li><li>2</li></template>"), `{"template": {"li": "1", "li": "2"}}`)
}

@(test)
an_element_spans_its_tags :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := "<div id=a><p>x</p><p>y</div><span>z</span>"
	doc, ok := built(t, text, .Fragment)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	div, _ := walktest.member_at(t, &doc, ".div")
	testing.expect_value(t, string(core.span(&doc, div)), "<div id=a><p>x</p><p>y</div>")
	p, _ := walktest.member_at(t, &doc, ".div.p")
	testing.expect_value(t, string(core.span(&doc, p)), "y")
	testing.expect_value(t, string(core.span(&doc, core.ROOT)), text)
}

// The consumers written for any document read an HTML text and an XML text with the same markup as one value: equal,
// and with no change between them, facts included, while an attribute's change is a fact change.
@(test)
an_html_document_and_an_xml_one_compare_as_one_value :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := "<r><item n=\"1\">one</item><!--c--><item n=\"2\"><b>two</b> and <i>2</i></item></r>"
	doc, ok := built(t, text, .Fragment)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	same, err := xml.build(transmute([]u8)text, .Xml)
	walktest.expect_nil(t, err)
	defer core.destroy(&same)
	a, b := core.Node_Ref{&doc, core.ROOT}, core.Node_Ref{&same, core.ROOT}
	testing.expect(t, core.equal(a, b))
	r, derr := diff.values(a, b, {facts = true})
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, len(r.changes), 0)
	diff.result_destroy(&r)
	other, oerr := xml.build(transmute([]u8)string("<r><item n=\"1\">one</item><!--c--><item n=\"3\"><b>two</b> and <i>2</i></item></r>"), .Xml)
	walktest.expect_nil(t, oerr)
	defer core.destroy(&other)
	r, derr = diff.values(a, core.Node_Ref{&other, core.ROOT}, {facts = true})
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, len(r.changes), 1)
	if len(r.changes) == 1 {
		testing.expect_value(t, r.changes[0].op, diff.Op.Fact)
		testing.expect_value(t, r.changes[0].role, core.Role.Attribute)
	}
	diff.result_destroy(&r)
}
