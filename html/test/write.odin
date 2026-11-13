// The write of a document as HTML: the standard's serialization over a markup document's shape, read back.
package html_tests

import "core:testing"
import core "../../core"
import write "../../core/write"
import html ".."
import xml "../../xml"
import walktest "../../walktest"

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
		{src = "<r><td>1</td></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><p><div>x</div></p></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><br>x</br></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><script>a&lt;/script&gt;</script></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><P>x</P></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><p A='1'>x</p></r>", xml = true, at = ".r", kind = .Unwritable},
		{src = "<r><a>x</a></r>", xml = true, at = ".r.a", kind = .Unsupported},
	}
	for c in cases {
		doc: core.Document
		err: core.Error
		if c.xml {
			doc, err = xml.build(transmute([]u8)c.src, .Xml)
		} else {
			doc, err = html.build(transmute([]u8)c.src, .Document)
		}
		walktest.expect_nil(t, err)
		defer core.destroy(&doc)
		node := core.ROOT
		if c.at != "" {
			found: bool
			node, found = walktest.member_at(t, &doc, c.at)
			testing.expect(t, found)
		}
		opts := core.PRETTY if c.pretty else core.Write_Options{}
		text, dropped, werr := html.write(&doc, .Document, opts, node)
		defer delete(text)
		refusal, _ := werr.(core.Typed_Error)
		testing.expectf(t, string(text) == c.want && refusal.kind == c.kind && dropped == 0, "%q: %q %v %d, want %q %v", c.src, string(text), refusal.kind, dropped, c.want, c.kind)
	}
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
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), "<ul><li>a&lt;b</li><li>c</li></ul><p>0</p>")
	laid, lerr := html.marshal(v, write = core.PRETTY)
	walktest.expect_nil(t, lerr)
	testing.expect_value(t, string(laid), "<ul>\n  <li>a&lt;b</li>\n  <li>c</li>\n</ul>\n<p>0</p>")
	back: List
	walktest.expect_nil(t, html.unmarshal(text, .Fragment, &back))
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
		testing.expect_value(t, html.tokens_init(&w, .Document, core.PRETTY if pretty else {}, context.temp_allocator), core.Typed_Error_Kind.None)
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
		{proc(w: ^write.Tokens) {write.value_int(w, 1)}, .Unsupported},
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
