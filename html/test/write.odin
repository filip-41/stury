// The write of a document as HTML: the standard's serialization over a markup document's shape, read back.
package html_tests

import "base:runtime"
import "core:testing"
import core "../../core"
import write "../../core/write"
import html ".."
import json "../../json"
import xml "../../xml"
import testkit "../../testkit"

@(private = "file")
Write_Case :: struct {
	src:    string,
	xml:    bool, // `src` is read as XML, and node `at` of it is written
	at:     string,
	pretty: bool,
	want:   string,
	kind:   core.Typed_Error_Kind,
}

// An HTML document is written as the tree holds it, its implied elements with tags, its doctype, comments and attributes
// as they stand, and any other document's elements, attributes and texts escaped, a void element with no end tag and a
// raw text as it stands. A tree that reads back otherwise is `.Unwritable`.
@(test)
write_reads_back_as_written :: proc(t: ^testing.T) {
	cases := [?]Write_Case {
		{src = "<!DOCTYPE html><title>T</title><!--c--><p id=a class=\"x y\">hello &amp; <b>bold</b> tail<p>two<br>", want = "<!DOCTYPE html><html><head><title>T</title><!--c--></head><body><p id=a class=\"x y\">hello &amp; <b>bold</b> tail</p><p>two<br></p></body></html>"},
		{src = "<table><td>1<td>2</table><script>if (a<b) x()</script>", want = "<html><head></head><body><table><tbody><tr><td>1</td><td>2</td></tr></tbody></table><script>if (a<b) x()</script></body></html>"},
		{src = "<pre>\n\nx</pre><textarea>a&lt;b</textarea>", at = ".html.body", want = "<pre>\n\nx</pre><textarea>a&lt;b</textarea>"},
		{src = "<ul><li>a<li><b>b</b></ul>", at = ".html.body", pretty = true, want = "<ul>\n  <li>a</li>\n  <li>\n    <b>b</b>\n  </li>\n</ul>"},
		{src = "<r><!--n--><p k='1&amp;\"'>a&lt;b c</p><img src='x'/><svg><circle r='1'/></svg></r>", xml = true, at = ".r", want = "<!--n--><p k=\"1&amp;&quot;\">a&lt;b&nbsp;c</p><img src=\"x\"><svg><circle r=\"1\"></circle></svg>"},
		{src = "<div><!--c--><p>x</p></div>", at = ".html.body", want = "<div><!--c--><p>x</p></div>"},
		{src = "<r><e><!--z--></e><p>a<!--w--></p><i/></r>", xml = true, at = ".r", want = "<e><!--z--></e><p>a<!--w--></p><i></i>"},
		{src = "<r><td>1</td></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><p><div>x</div></p></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><br>x</br></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><script>a&lt;/script&gt;</script></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><P>x</P></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><p A='1'>x</p></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><a>x</a></r>", xml = true, at = ".r.a", kind = .Unwritable},
	}
	for c in cases {
		doc: core.Document
		err: core.Error
		if c.xml {
			doc, err = xml.build(transmute([]u8)c.src, .Xml)
		} else {
			doc, err = html.build(transmute([]u8)c.src, .Document)
		}
		testkit.expect_nil(t, err)
		defer core.destroy(&doc)
		node := core.ROOT
		if c.at != "" {
			found: bool
			node, found = testkit.member_at(t, &doc, c.at)
			testing.expect(t, found)
		}
		opts := core.PRETTY if c.pretty else core.Write_Options{}
		text, dropped, werr := html.write(&doc, .Document, opts, node)
		defer delete(text)
		refusal, _ := werr.(core.Typed_Error)
		testing.expectf(t, string(text) == c.want && refusal.kind == c.kind && dropped == 0, "%q: %q %v %d, want %q %v", c.src, string(text), refusal.kind, dropped, c.want, c.kind)
	}
}

// A document's doctype and the comments of its head are written as XML, the doctype with no external identifier.
@(test)
an_html_document_is_written_as_xml_with_its_doctype :: proc(t: ^testing.T) {
	doc, err := html.build(transmute([]u8)string("<!DOCTYPE html><!--h-->\n\n<p>x"), .Document)
	defer core.destroy(&doc)
	testkit.expect_nil(t, err)
	text, dropped, werr := xml.write(&doc, .Xml)
	defer delete(text)
	testkit.expect_nil(t, werr)
	testing.expect_value(t, dropped, 0)
	testing.expect_value(t, string(text), "<!DOCTYPE html>\n<!--h-->\n\n<html><head/><body><p>x</p></body></html>")
}

// `marshal` writes a value as `write` writes a built one, and `unmarshal` reads back what it writes.
@(test)
unmarshal_reads_what_marshal_writes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	List :: struct {
		ul: struct {
			li: [dynamic]string,
		},
		p:  int,
	}
	v: List
	append(&v.ul.li, "a<b", "c")
	text, err := html.marshal(v)
	testkit.expect_nil(t, err)
	testing.expect_value(t, string(text), "<ul><li>a&lt;b</li><li>c</li></ul><p>0</p>")
	laid, lerr := html.marshal(v, write = core.PRETTY)
	testkit.expect_nil(t, lerr)
	testing.expect_value(t, string(laid), "<ul>\n  <li>a&lt;b</li>\n  <li>c</li>\n</ul>\n<p>0</p>")
	back: List
	testkit.expect_nil(t, html.unmarshal(text, .Fragment, &back))
	testing.expect_value(t, len(back.ul.li), 2)
	testing.expect_value(t, back.ul.li[0], "a<b")
	_, refused := html.marshal(struct {td: int}{})
	testing.expect_value(t, refused.(core.Typed_Error).kind, core.Typed_Error_Kind.Unwritable)
}

// The token write writes the value its calls make as `write` writes a built one, and refuses what it refuses.
@(test)
token_write_writes_elements :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for pretty in ([]bool{false, true}) {
		w: write.Tokens
		testing.expect_value(t, html.tokens_init(&w, .Document, write = core.PRETTY if pretty else {}, allocator = context.temp_allocator), core.Typed_Error_Kind.None)
		write.open_object(&w)
		write.key(&w, "ul")
		write.open_object(&w)
		write.key(&w, "li")
		write.open_array(&w)
		write.value_int(&w, 1)
		write.value_string(&w, "a<b")
		write.value_null(&w)
		write.close(&w)
		write.close(&w)
		write.close(&w)
		bytes, err := write.tokens_finish(&w)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		want := "<ul>\n  <li>1</li>\n  <li>a&lt;b</li>\n  <li></li>\n</ul>" if pretty else "<ul><li>1</li><li>a&lt;b</li><li></li></ul>"
		testing.expect_value(t, string(bytes), want)
	}
	refused := [?]struct {
		calls: proc(w: ^write.Tokens),
		kind:  core.Typed_Error_Kind,
	} {
		{proc(w: ^write.Tokens) {write.value_int(w, 1)}, .Unwritable},
		{proc(w: ^write.Tokens) {write.open_object(w); write.key(w, "td"); write.value_int(w, 1); write.close(w)}, .Unwritable},
		{proc(w: ^write.Tokens) {write.open_object(w); write.key(w, "p"); write.value_string(w, "\x00"); write.close(w)}, .Unwritable},
	}
	for c in refused {
		w: write.Tokens
		html.tokens_init(&w, .Document, allocator = context.temp_allocator)
		c.calls(&w)
		_, err := write.tokens_finish(&w)
		testing.expect_value(t, err.kind, c.kind)
	}
}

// The token write writes a comment before, after or at the end of the element it stands by, which reads it back so.
@(test)
token_write_writes_comments :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: write.Tokens
	html.tokens_init(&w, .Document, write = core.PRETTY, allocator = context.temp_allocator)
	write.open_object(&w)
	write.key(&w, "ul")
	write.open_object(&w)
	write.key(&w, "li")
	write.open_array(&w)
	write.value_int(&w, 1)
	write.comment(&w, "on 1", .Comment_Inline)
	write.comment(&w, "before 2")
	write.value_int(&w, 2)
	write.close(&w)
	write.comment(&w, "end", .Comment_Foot)
	write.close(&w)
	write.close(&w)
	bytes, err := write.tokens_finish(&w)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(bytes), "<ul>\n  <li>1</li><!-- on 1 -->\n  <!-- before 2 --><li>2</li>\n  <!-- end -->\n</ul>")
	empty: write.Tokens
	html.tokens_init(&empty, .Document, write = core.PRETTY, allocator = context.temp_allocator)
	write.open_object(&empty)
	write.key(&empty, "ul")
	write.open_object(&empty)
	write.comment(&empty, "none")
	write.close(&empty)
	write.close(&empty)
	alone, aerr := write.tokens_finish(&empty)
	testing.expect_value(t, aerr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(alone), "<ul><!-- none --></ul>")
}

// The comments on a repeated element as a whole are written on its first and last elements, where they read back.
@(test)
a_run_writes_its_comments_on_its_ends :: proc(t: ^testing.T) {
	src := "{\"r\": {\"ul\": {\"li\": /* l */ [1, 2] // t\n}}}"
	doc, err := json.build(transmute([]u8)src, .Jsonc)
	testkit.expect_nil(t, err)
	defer json.destroy(&doc)
	node, found := testkit.member_at(t, &doc, ".r")
	testing.expect(t, found)
	text, dropped, werr := html.write(&doc, .Document, {}, node)
	defer delete(text)
	testkit.expect_nil(t, werr)
	testing.expect_value(t, dropped, 0)
	testing.expect_value(t, string(text), "<ul><!-- l --><li>1</li><li>2</li><!-- t --></ul>")
}

// Pretty output puts a foot comment on a line of its own at the indent of the element's members, and the end tag on a
// line of its own after it. White space in `pre` is text, so a `pre` is written as it stands.
@(test)
a_pretty_foot_comment_has_its_own_line_before_the_end_tag :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, err := html.build(transmute([]u8)string("<div><p>1</p>\n<!-- n --></div><pre><b>x</b><!-- z --></pre>"), .Document, allocator = context.temp_allocator)
	testkit.expect_nil(t, err)
	text, _, werr := html.write(&doc, .Document, core.PRETTY, allocator = context.temp_allocator)
	testkit.expect_nil(t, werr)
	testing.expect_value(t, string(text), "<html>\n  <head></head>\n  <body>\n    <div>\n      <p>1</p>\n      <!-- n -->\n    </div>\n    <pre><b>x</b><!-- z --></pre>\n  </body>\n</html>")
}

// An empty array is no element, so its comments are written as the foot of the element that holds it.
@(test)
an_empty_run_writes_its_comments_as_the_foot :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "{\"r\": {\"ul\": {\"li\": [\n  // z\n], \"p\": 1}}}"
	doc, err := json.build(transmute([]u8)src, .Jsonc, allocator = context.temp_allocator)
	testkit.expect_nil(t, err)
	node, found := testkit.member_at(t, &doc, ".r")
	testing.expect(t, found)
	text, dropped, werr := html.write(&doc, .Document, {}, node, allocator = context.temp_allocator)
	testkit.expect_nil(t, werr)
	testing.expect_value(t, dropped, 0)
	testing.expect_value(t, string(text), "<ul><p>1</p>\n<!-- z --></ul>")
	w: write.Tokens
	html.tokens_init(&w, .Document, allocator = context.temp_allocator)
	write.open_object(&w)
	write.key(&w, "ul")
	write.open_object(&w)
	write.key(&w, "li")
	write.open_array(&w)
	write.comment(&w, "z")
	write.close(&w)
	write.close(&w)
	write.close(&w)
	tokens, terr := write.tokens_finish(&w)
	testing.expect_value(t, terr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(tokens), "<ul><!-- z --></ul>")
}

@(private)
Sweep_Value :: struct {
	ul: struct {
		li: []string,
	},
	p:  int,
}

@(private)
Sweep_Try :: struct {
	value: Sweep_Value,
	opts:  core.Write_Options,
}

@(private)
sweep_try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind) {
	m := (^Sweep_Try)(data)
	text, err := html.marshal(m.value, write = m.opts, allocator = allocator)
	return text, testkit.typed_kind(err)
}

@(test)
marshal_under_failing_allocators :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for opts in ([?]core.Write_Options{{}, {pretty = true, indent = 2}}) {
		try := Sweep_Try{Sweep_Value{ul = {li = {"a<b", "c"}}, p = 2}, opts}
		want, err := html.marshal(try.value, write = opts, allocator = context.temp_allocator)
		testkit.expect_nil(t, err)
		testkit.sweep_write(t, sweep_try, &try, string(want))
	}
}
