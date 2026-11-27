// HTML5 writer, token writer, marshal, unmarshal, typed checks, and zero `context.temp_allocator` growth verification.
package html_tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:html"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"
import "stury:lib/ops/write"
import "stury:testkit"
import "stury:xml"

@(private = "file")
Write_Case :: struct {
	src:    string,
	xml:    bool,
	at:     []string,
	pretty: bool,
	want:   string,
	kind:   write.Refusal,
}

@(test)
write_reads_back_as_written :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	cases := [?]Write_Case {
		{src = "<!DOCTYPE html><title>T</title><!--c--><p id=a class=\"x y\">hello &amp; <b>bold</b> tail<p>two<br>", want = "<!DOCTYPE html><html><head><title>T</title><!--c--></head><body><p id=a class=\"x y\">hello &amp; <b>bold</b> tail</p><p>two<br></p></body></html>"},
		{src = "<table><td>1<td>2</table><script>if (a<b) x()</script>", want = "<html><head></head><body><table><tbody><tr><td>1</td><td>2</td></tr></tbody></table><script>if (a<b) x()</script></body></html>"},
		{src = "<pre>\n\nx</pre><textarea>a&lt;b</textarea>", at = {"html", "body"}, want = "<pre>\n\nx</pre><textarea>a&lt;b</textarea>"},
		{src = "<ul><li>a<li><b>b</b></ul>", at = {"html", "body"}, pretty = true, want = "<ul>\n  <li>a</li>\n  <li>\n    <b>b</b>\n  </li>\n</ul>"},
		{src = "<r><!--n--><p k='1&amp;\"'>a&lt;b\u00A0c</p><img src='x'/><svg><circle r='1'/></svg></r>", xml = true, at = {"r"}, want = "<!--n--><p k=\"1&amp;&quot;\">a&lt;b&nbsp;c</p><img src=\"x\"><svg><circle r=\"1\"></circle></svg>"},
		{src = "<div><!--c--><p>x</p></div>", at = {"html", "body"}, want = "<div><!--c--><p>x</p></div>"},
		{src = "<r><e><!--z--></e><p>a<!--w--></p><i/></r>", xml = true, at = {"r"}, want = "<e><!--z--></e><p>a<!--w--></p><i></i>"},
		{src = "<r><td>1</td></r>", xml = true, at = {"r"}, kind = .No_Spelling},
		{src = "<r><p><div>x</div></p></r>", xml = true, at = {"r"}, kind = .No_Spelling},
		{src = "<r><br>x</br></r>", xml = true, at = {"r"}, kind = .No_Spelling},
		{src = "<r><script>a&lt;/script&gt;</script></r>", xml = true, at = {"r"}, kind = .No_Spelling},
		{src = "<r><P>x</P></r>", xml = true, at = {"r"}, kind = .No_Spelling},
		{src = "<r><p A='1'>x</p></r>", xml = true, at = {"r"}, kind = .No_Spelling},
		{src = "<r><a>x</a></r>", xml = true, at = {"r", "a"}, kind = .No_Spelling},
		{src = "<a href=1><table><a href=2>x</table>", kind = .No_Spelling},
		{src = "<plaintext>a</p>", kind = .No_Spelling},
		{src = "x<!--", kind = .No_Spelling},
		{src = "<table>text<tr><td>a</table>", want = "<html><head></head><body>text<table><tbody><tr><td>a</td></tr></tbody></table></body></html>"},
	}
	for c in cases {
		doc: tape.Document
		err: tape.Error
		if c.xml {
			doc, err = xml.build(transmute([]u8)c.src, .Xml)
		} else {
			doc, err = html.build(transmute([]u8)c.src, .Html)
		}
		testing.expect_value(t, err, nil)
		defer tape.destroy(&doc)
		node := html.ROOT
		if len(c.at) > 0 {
			found: bool
			node, found = testkit.member_at(&doc, c.at)
			testing.expect(t, found)
		}
		opts := html.Write_Options{node = node}
		if c.pretty {
			opts.indent = 2
		}
		text, dropped, werr := html.write(&doc, .Html, opts)
		defer delete(text)
		refusal, _ := werr.(html.Refused)
		testing.expectf(t, string(text) == c.want && refusal.why == c.kind && dropped == {}, "%q: %q %v %v, want %q %v", c.src, string(text), refusal.why, dropped, c.want, c.kind)
	}
}

@(test)
an_html_document_is_written_as_xml_with_its_doctype :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := html.build(transmute([]u8)string("<!DOCTYPE html><!--h-->\n\n<p>x"))
	defer html.destroy(&doc)
	testing.expect_value(t, err, nil)
	text, dropped, werr := xml.write(&doc, .Xml)
	defer delete(text)
	testing.expect_value(t, werr, nil)
	testing.expect_value(t, dropped, tape.Facts{.Doctype})
	testing.expect_value(t, string(text), "<!--h--><html><head/><body><p>x</p></body></html>")
}

@(test)
html_write_uses_zero_temp_allocator :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := `<!DOCTYPE html><html lang=en><head><title>Title &amp; Co</title></head><body><!--a--><ul><li>1<li><b>two</b><img src="x"></ul><!-- z --></body></html>`
	doc, err := html.build(transmute([]u8)src)
	testing.expect_value(t, err, nil)
	defer html.destroy(&doc)

	Temp_Guard :: struct {
		allocs: int,
	}
	guard: Temp_Guard
	saved := context.temp_allocator
	defer context.temp_allocator = saved
	context.temp_allocator = {
		procedure = proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
			_ = mode
			_ = size
			_ = alignment
			_ = old
			_ = old_size
			_ = loc
			g := (^Temp_Guard)(data)
			g.allocs += 1
			return nil, .Out_Of_Memory
		},
		data = &guard,
	}

	for pretty in ([2]bool{false, true}) {
		opts := html.Write_Options{indent = 2} if pretty else html.Write_Options{}
		text, dropped, werr := html.write(&doc, .Html, opts, context.allocator)
		testing.expect_value(t, werr, nil)
		testing.expect_value(t, dropped, tape.Facts{})
		delete(text)
	}
	testing.expect_value(t, guard.allocs, 0)
}

@(test)
pretty_write_formats_and_round_trips_trailing_newline :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for text in ([]string{"tail\n", "tail", "tail\n\n", "  tail  \n"}) {
		src := strings.concatenate({"<!DOCTYPE html><body><p>a</p>", text, "</body>"}, context.temp_allocator)
		doc, err := html.build(transmute([]u8)src, .Html, {}, context.temp_allocator)
		testing.expect_value(t, err, nil)
		written, _, werr := html.write(&doc, .Html, {indent = 2}, context.temp_allocator)
		testing.expect_value(t, werr, nil)
		back, berr := html.build(written, .Html, {}, context.temp_allocator)
		testing.expect_value(t, berr, nil)
		testing.expectf(t, markup_shape(&doc) == markup_shape(&back), "%q: %q -> %q", text, markup_shape(&doc), markup_shape(&back))
	}

	doc, err := html.build(transmute([]u8)string("<div><p>1</p>\n<!-- n --></div><pre><b>x</b><!-- z --></pre>"), .Html, {}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	written, _, werr := html.write(&doc, .Html, {indent = 2}, context.temp_allocator)
	testing.expect_value(t, werr, nil)
	testing.expect_value(t, string(written), "<html>\n  <head></head>\n  <body>\n    <div>\n      <p>1</p>\n      <!-- n -->\n    </div>\n    <pre><b>x</b><!-- z --></pre>\n  </body>\n</html>")

	// Trailing `\n` after `</html>` preserves via `s.line_end` / `s.glued` and re-formats idempotently.
	lined, lerr := html.build(transmute([]u8)string("<!DOCTYPE html><html><head></head><body><p>a</p>tail</body></html>\n"), .Html, {}, context.temp_allocator)
	testing.expect_value(t, lerr, nil)
	lout, _, lwerr := html.write(&lined, .Html, {indent = 2}, context.temp_allocator)
	testing.expect_value(t, lwerr, nil)
	testing.expect(t, strings.has_suffix(string(lout), "</html>\n"))
}

@(test)
marshal_and_unmarshal_round_trip :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Cell :: struct {
		class: string,
		value: f64 `html:"#text"`,
	}
	Row :: struct {
		td: [dynamic]Cell,
	}
	Page :: struct {
		html: struct {
			head: struct {
				title: string,
			},
			body: struct {
				table: struct {
					tbody: struct {
						tr: [dynamic]Row,
					},
				},
			},
		},
	}

	text := `<!doctype html><title>Prices &amp; more</title>
<table><tr><td class=a>1.5<td class=b>2</tr><tr><td class=c>3</table>`
	v: Page
	context.allocator = context.temp_allocator
	testing.expect_value(t, html.unmarshal(transmute([]u8)text, &v, .Html), nil)
	testing.expect_value(t, v.html.head.title, "Prices & more")
	rows := v.html.body.table.tbody.tr
	if testing.expect_value(t, len(rows), 2) && testing.expect_value(t, len(rows[0].td), 2) {
		testing.expect_value(t, rows[0].td[0].class, "a")
		testing.expect_value(t, rows[0].td[0].value, 1.5)
		testing.expect_value(t, rows[0].td[1].value, 2)
		testing.expect_value(t, rows[1].td[0].class, "c")
	}

	plan, perr := html.plan_make(Page)
	testing.expect_value(t, perr, nil)
	defer html.plan_destroy(&plan)
	planned: Page
	testing.expect_value(t, html.unmarshal(transmute([]u8)text, &planned, .Html, {plan = &plan}), nil)
	testing.expect_value(t, len(planned.html.body.table.tbody.tr), 2)

	// Numeric decode via character references.
	Num_Doc :: struct {
		b: struct {
			n:    int,
			text: f64 `html:"#text"`,
		},
		i: int,
	}
	nv: Num_Doc
	testing.expect_value(t, html.unmarshal(transmute([]u8)string(`<b n="&#45;&#55;">&#49;.&#53;</b><i>&#55;</i>`), &nv, .Fragment), nil)
	testing.expect_value(t, nv.b.n, -7)
	testing.expect_value(t, nv.b.text, 1.5)
	testing.expect_value(t, nv.i, 7)

	// `marshal` & `marshal_to` + round-trip via `unmarshal`.
	List :: struct {
		ul: struct {
			li: [dynamic]string,
		},
		p:  int,
	}
	lv: List
	append(&lv.ul.li, "a<b", "c")
	out, merr := html.marshal(&lv, .Fragment)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, string(out), "<ul><li>a&lt;b</li><li>c</li></ul><p>0</p>")

	sink: strings.Builder
	strings.builder_init(&sink, context.temp_allocator)
	testing.expect_value(t, html.marshal_to(strings.to_writer(&sink), &lv, .Fragment, {indent = 2}), nil)
	testing.expect_value(t, strings.to_string(sink), "<ul>\n  <li>a&lt;b</li>\n  <li>c</li>\n</ul>\n<p>0</p>")

	back: List
	testing.expect_value(t, html.unmarshal(out, &back, .Fragment), nil)
	if testing.expect_value(t, len(back.ul.li), 2) {
		testing.expect_value(t, back.ul.li[0], "a<b")
	}

	// `typed` refusal reports path & Expected_Integer / refuse_unknown.
	Err_S :: struct {
		a: struct {
			n, m, k: int,
		},
	}
	ev: Err_S
	upath: [dynamic]tape.Step
	upath.allocator = context.temp_allocator
	uerr := html.unmarshal(transmute([]u8)string(`<a n=x m=2 k=y>t</a>`), &ev, .Fragment, {path = &upath})
	f, is_f := uerr.(tape.Fault)
	testing.expect(t, is_f && typed.Typed_Refusal(f.detail) == .Expected_Integer)
	testing.expect_value(t, len(upath), 2)
	uerr2 := html.unmarshal(transmute([]u8)string(`<a n=1 m=2 k=3 extra=9>t</a>`), &ev, .Fragment, {refuse_unknown = true})
	f2, is_f2 := uerr2.(tape.Fault)
	testing.expect(t, is_f2 && typed.Typed_Refusal(f2.detail) == .Unknown_Field)

	// Unwritable struct (bare `<td>` outside `<table>`).
	bad_td := struct{td: int}{}
	_, refused := html.marshal(&bad_td)
	r_td, is_r := refused.(html.Refused)
	testing.expect(t, is_r && r_td.why == .No_Spelling)
}

@(test)
token_writer_and_refusals :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	w: html.Writer
	testing.expect_value(t, html.writer_start(&w, .Html, {indent = 2}), nil)
	steps := [?]struct {
		kind: html.Token_Kind,
		text: string,
	}{{.Object, ""}, {.Key, "ul"}, {.Object, ""}, {.Key, "li"}, {.Array, ""}, {.Number, "1"}, {.String, "a<b"}, {.Null, ""}, {.Close, ""}, {.Close, ""}, {.Close, ""}}
	for s in steps {
		testing.expect_value(t, html.token(&w, s.kind, s.text), nil)
	}
	text, werr := html.writer_end(&w)
	defer delete(text)
	testing.expect_value(t, werr, nil)
	testing.expect_value(t, string(text), "<ul>\n  <li>1</li>\n  <li>a&lt;b</li>\n  <li></li>\n</ul>")

	// Comments on grouped array runs and JSON empty-array refusal matching v2 `next/xml`.
	src := `{"r": {"ul": {"li": /* l */ [1, 2] // t` + "\n}}}"
	jdoc, jerr := json.build(transmute([]u8)src, .Jsonc, {}, context.temp_allocator)
	testing.expect_value(t, jerr, nil)
	rnode, found := testkit.member_at(&jdoc, {"r"})
	testing.expect(t, found)
	jout, _, jwerr := html.write(&jdoc, .Html, {node = rnode}, context.temp_allocator)
	testing.expect_value(t, jwerr, nil)
	testing.expect_value(t, string(jout), "<ul><!-- l --><li>1</li><li>2</li><!-- t --></ul>")

	empty_arr_doc, _ := json.build(transmute([]u8)string(`{"a": []}`), .Json, {}, context.temp_allocator)
	defer json.destroy(&empty_arr_doc)
	_, _, ea_err := html.write(&empty_arr_doc)
	ea_r, is_ea := ea_err.(html.Refused)
	testing.expect(t, is_ea && ea_r.why == .No_Spelling)

	// Invalid writer options and dropped writer cleanup.
	testing.expect_value(t, html.writer_start(&w, html.Spec(99)), html.Write_Error(html.Bad_Option{"spec"}))
	testing.expect_value(t, html.writer_start(&w, .Html, {node = 1}), html.Write_Error(html.Bad_Option{"node"}))
	testing.expect_value(t, html.writer_start(&w, .Html, {}), nil)
	_ = html.token(&w, .Object)
	_ = html.token(&w, .Key, "p")
	html.writer_drop(&w)
}

@(test)
write_dsv_cells_and_dropped_facts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// 1. DSV table row written as HTML fragment via `step.cell`.
	ddoc, derr := dsv.build(transmute([]u8)string("p,span\nhello,world\n"), .Csv, {}, context.temp_allocator)
	testing.expect_value(t, derr, nil)
	row0, rp := dsv.element(dsv.Reader{doc = &ddoc}, dsv.ROOT, 0)
	testing.expect_value(t, rp, tape.Presence.Found)
	dout, ddrop, dwerr := html.write(&ddoc, .Fragment, {node = row0}, context.temp_allocator)
	testing.expect_value(t, dwerr, nil)
	testing.expect_value(t, ddrop, tape.Facts{})
	testing.expect_value(t, string(dout), "<p>hello</p><span>world</span>")

	// 2. Dropped facts: `#text` comments (`jsonc`), void element foot comment (`xml`), `.Array` `.Attribute`/`.Doctype`.
	jdoc, jerr := json.build(transmute([]u8)string(`{"div":{"#text":1 /* dropped */}}`), .Jsonc, {}, context.temp_allocator)
	testing.expect_value(t, jerr, nil)
	jout, jdrop, jwerr := html.write(&jdoc, .Fragment, {}, context.temp_allocator)
	testing.expect_value(t, jwerr, nil)
	testing.expect_value(t, string(jout), "<div>1</div>")
	testing.expect(t, .Comment_Inline in jdrop)

	xdoc, xerr := xml.build(transmute([]u8)string(`<r><br><!--foot--></br></r>`), .Xml, {}, context.temp_allocator)
	testing.expect_value(t, xerr, nil)
	rnode, rfound := testkit.member_at(&xdoc, {"r"})
	testing.expect(t, rfound)
	xout, xdrop, xwerr := html.write(&xdoc, .Fragment, {node = rnode}, context.temp_allocator)
	testing.expect_value(t, xwerr, nil)
	testing.expect_value(t, string(xout), "<br>")
	testing.expect(t, .Comment_Foot in xdrop)

	// `.Array` holding `.Attribute` and `.Doctype` facts drops them cleanly.
	arr_src := transmute([]u8)string(`<r><a x='1'>1</a><a>2</a></r>`)
	ax, axerr := xml.build(arr_src, .Xml, {}, context.temp_allocator)
	testing.expect_value(t, axerr, nil)
	axout, axdrop, axwerr := html.write(&ax, .Fragment, {}, context.temp_allocator)
	testing.expect_value(t, axwerr, nil)
	testing.expect_value(t, string(axout), "<r><a x=\"1\">1</a><a>2</a></r>")
	_ = axdrop
	// Synthetic array with `.Attribute` and `.Doctype` facts reports both dropped.
	syn_src := transmute([]u8)string(`p a k="1"<!DOCTYPE html>`)
	syn_nodes := [?]tape.Node {
		{kind = .Object, role = .Value, n = 4, spelling = 1},
		{lo = 0, n = 1, kind = .String, role = .Key},
		{kind = .Array, role = .Value, n = 2, spelling = 1},
		{lo = 2, n = 1, kind = .String, role = .Value},
	}
	syn_facts := [?]tape.Fact {
		{node = 2, lo = 4, n = 5, kind = .Attribute},
		{node = 2, lo = 9, n = 15, kind = .Doctype},
	}
	syn_doc := tape.Document {
		src     = syn_src,
		nodes   = syn_nodes[:],
		facts   = syn_facts[:],
		present = {.Attribute, .Doctype},
		format  = html.as(.Fragment),
	}
	_, sdrop, swerr := html.write(&syn_doc, .Fragment, {}, context.temp_allocator)
	testing.expect_value(t, swerr, nil)
	testing.expect(t, .Attribute in sdrop && .Doctype in sdrop)
}

@(test)
unmarshal_empty_attrs_multi_unions_and_oom :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// 1. Empty void/null elements with attributes (`<img>`, `<input>`, empty `<div></div>`).
	Img :: struct {
		src, alt: string,
	}
	Input :: struct {
		name:   string,
		kind_v: string `html:"type"`,
	}
	Empty_Box :: struct {
		img:   Img,
		input: Input,
		div:   struct {
			id: int,
		},
	}
	ev: Empty_Box
	testing.expect_value(
		t,
		html.unmarshal(transmute([]u8)string(`<img src="x.png" alt="pic"><input name="u" type="email"><div id="7"></div>`), &ev, .Fragment, {}, {}, context.temp_allocator),
		nil,
	)
	testing.expect_value(t, ev.img.src, "x.png")
	testing.expect_value(t, ev.img.alt, "pic")
	testing.expect_value(t, ev.input.name, "u")
	testing.expect_value(t, ev.input.kind_v, "email")
	testing.expect_value(t, ev.div.id, 7)

	// 2. Multi-variant union tries all variants cleanly and rolls back partial heap allocations on failed variant (zero leaks!).
	Val_U :: union {
		int,
		bool,
		string,
	}
	Pair_A :: struct {
		items: [dynamic]int,
		label: string,
		count: int,
	}
	Pair_B :: struct {
		items: [dynamic]int,
		label: string,
	}
	Box_U :: union {
		Pair_A,
		Pair_B,
	}
	Maybe_Box :: struct {
		scalar: Val_U,
		box:    Box_U,
		opt:    Maybe(^int),
	}
	alloc := runtime.heap_allocator()
	mb: Maybe_Box
	u_src := `<scalar>hello</scalar><box><items>10</items><items>20</items><label>win</label><count>not_int</count></box><opt>99</opt>`
	testing.expect_value(t, html.unmarshal(transmute([]u8)u_src, &mb, .Fragment, {}, {}, alloc), nil)
	defer {
		if sv, is_s := mb.scalar.(string); is_s {
			delete(sv, alloc)
		}
		if pb, is_b := mb.box.(Pair_B); is_b {
			delete(pb.items)
			delete(pb.label, alloc)
		}
		if p, has_p := mb.opt.?; has_p {
			free(p, alloc)
		}
	}
	testing.expect_value(t, mb.scalar, Val_U("hello"))
	pb, is_pb := mb.box.(Pair_B)
	testing.expect(t, is_pb)
	if is_pb {
		testing.expect_value(t, pb.label, "win")
		if testing.expect_value(t, len(pb.items), 2) {
			testing.expect_value(t, pb.items[0], 10)
			testing.expect_value(t, pb.items[1], 20)
		}
	}
	p_opt, has_opt := mb.opt.?
	testing.expect(t, has_opt && p_opt^ == 99)

	// 3. Systematic OOM test during `unmarshal` must fail with `Out_Of_Memory` cleanly without leaks.
	Oom_S :: struct {
		ul: struct {
			li: [dynamic]string,
		},
		v:  Box_U,
	}
	oom_src := transmute([]u8)string(`<ul><li>one</li><li>two</li></ul><v><items>1</items><label>hi</label><count>bad</count></v>`)
	for k in 0 ..< 80 {
		fail := testkit.Failing{backing = alloc, fail_at = k}
		ov: Oom_S
		err := html.unmarshal(oom_src, &ov, .Fragment, {}, {}, testkit.failing_allocator(&fail))
		if !fail.failed {
			testing.expect_value(t, err, nil)
			for s in ov.ul.li {
				delete(s, alloc)
			}
			delete(ov.ul.li)
			if pb2, is_b2 := ov.v.(Pair_B); is_b2 {
				delete(pb2.items)
				delete(pb2.label, alloc)
			}
			break
		}
		testing.expect_value(t, err, html.Error(runtime.Allocator_Error.Out_Of_Memory))
	}
}

@(test)
nested_multi_variant_unions_rollback_and_rebase :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	Inner :: union {
		int,
		string,
	}
	Inner_Dyn :: union {
		[dynamic]int,
		bool,
	}
	Inner_Map :: union {
		map[string]int,
		bool,
	}
	Outer_A :: struct {
		a: Inner,
		b: int,
	}
	Outer :: union {
		Outer_A,
		bool,
	}
	Rich_A :: struct {
		a: Inner,
		d: Inner_Dyn,
		m: Inner_Map,
		b: int,
	}
	Rich_Fallback :: struct {
		a: string,
		d: bool,
		b: string,
	}
	Rich_Outer :: union {
		Rich_A,
		Rich_Fallback,
	}
	Rich_Fail :: union {
		Rich_A,
		bool,
	}

	// Verify under both `mem.Tracking_Allocator` and `t` (`ODIN_TEST_FAIL_ON_BAD_MEMORY` / ASan).
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	t_alloc := mem.tracking_allocator(&track)

	// 1a. Outer_A commits Inner("hello"), then fails `b` -> outer retries `bool` -> `.No_Arm`, ZERO leaks.
	{
		v: Outer
		err := html.unmarshal(transmute([]u8)string(`<a>hello</a><b>bad</b>`), &v, .Fragment, {}, {}, t_alloc)
		f, is_f := err.(tape.Fault)
		testing.expect(t, is_f && f.kind == .Refused && html.Typed_Refusal(f.detail) == .No_Arm)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}

	// 1b & 1c. Succeeding outer bool (on element scalar `<v>false</v>`) and succeeding Outer_A.
	{
		Scalar_Wrap :: struct {
			v: Outer,
		}
		v1: Scalar_Wrap
		testing.expect_value(t, html.unmarshal(transmute([]u8)string(`<v>false</v>`), &v1, .Fragment, {}, {}, t_alloc), nil)
		testing.expect_value(t, v1.v, Outer(false))

		v2: Outer
		testing.expect_value(t, html.unmarshal(transmute([]u8)string(`<a>hello</a><b>42</b>`), &v2, .Fragment, {}, {}, t_alloc), nil)
		oa, is_oa := v2.(Outer_A)
		testing.expect(t, is_oa && oa.a == Inner("hello") && oa.b == 42)
		if is_oa {
			if s, is_s := oa.a.(string); is_s {
				delete(s, t_alloc)
			}
		}
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}

	// 2a. Rich_Outer: Inner + Inner_Dyn(bool) + Inner_Map(map) commit in Rich_A, `b` fails -> fallback succeeds, ZERO leaked blocks from Rich_A!
	{
		rf: Rich_Outer
		src := `<a>hello</a><d>true</d><m><k1>1</k1><k2>2</k2></m><b>bad</b>`
		testing.expect_value(t, html.unmarshal(transmute([]u8)src, &rf, .Fragment, {}, {}, t_alloc), nil)
		fb, is_fb := rf.(Rich_Fallback)
		testing.expect(t, is_fb && fb.a == "hello" && fb.d && fb.b == "bad")
		if is_fb {
			delete(fb.a, t_alloc)
			delete(fb.b, t_alloc)
		}
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}

	// 2b. Rich_Fail: Inner("hello") + Inner_Dyn([10, 20]) + Inner_Map(map) commit in Rich_A, `b` fails -> ALL rollback cleanly!
	{
		rf: Rich_Fail
		src := `<a>hello</a><d>10</d><d>20</d><m><k1>1</k1><k2>2</k2></m><b>bad</b>`
		err := html.unmarshal(transmute([]u8)src, &rf, .Fragment, {}, {}, t_alloc)
		f, is_f := err.(tape.Fault)
		testing.expect(t, is_f && f.kind == .Refused && html.Typed_Refusal(f.detail) == .No_Arm)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}

	// 2c. Rich_Outer succeeds with Rich_A: caller can append to Inner_Dyn and insert into Inner_Map (tests container `.allocator` & `tc.raw` rebasing!).
	{
		ro: Rich_Outer
		src := `<a>hello</a><d>10</d><d>20</d><m><k1>1</k1><k2>2</k2></m><b>42</b>`
		testing.expect_value(t, html.unmarshal(transmute([]u8)src, &ro, .Fragment, {}, {}, t_alloc), nil)
		ra, is_ra := ro.(Rich_A)
		testing.expect(t, is_ra && ra.b == 42 && ra.a == Inner("hello"))
		if is_ra {
			if s, is_s := ra.a.(string); is_s {
				delete(s, t_alloc)
			}
			if da, is_da := ra.d.([dynamic]int); testing.expect(t, is_da && len(da) == 2 && da[0] == 10 && da[1] == 20) {
				append(&da, 30)
				testing.expect_value(t, len(da), 3)
				delete(da)
			}
			if mp, is_mp := ra.m.(map[string]int); testing.expect(t, is_mp && mp["k1"] == 1 && mp["k2"] == 2) {
				k3, _ := strings.clone("k3", t_alloc)
				mp[k3] = 3
				testing.expect_value(t, mp["k3"], 3)
				for mk in mp {
					delete(mk, t_alloc)
				}
				delete(mp)
			}
		}
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}

	// 3. 10-deep nested multi-variant unions forcing `cx.trials` dynamic reallocation (>8) + inner container rebasing & rollback!
	L1 :: union {
		Inner_Dyn,
		bool,
	}
	L2 :: union {
		struct {
			n: L1,
			t: int,
		},
		bool,
	}
	L3 :: union {
		struct {
			n: L2,
		},
		bool,
	}
	L4 :: union {
		struct {
			n: L3,
		},
		bool,
	}
	L5 :: union {
		struct {
			n: L4,
		},
		bool,
	}
	L6 :: union {
		struct {
			n: L5,
		},
		bool,
	}
	L7 :: union {
		struct {
			n: L6,
		},
		bool,
	}
	L8 :: union {
		struct {
			n: L7,
		},
		bool,
	}
	L9 :: union {
		struct {
			n: L8,
		},
		bool,
	}
	L10 :: union {
		struct {
			n: L9,
			w: int,
		},
		bool,
	}
	{
		// Deep fail after innermost [dynamic]int committed, failing at outermost `w`.
		fail_deep := `<n><n><n><n><n><n><n><n><n>1</n><n>2</n></n></n></n></n></n></n></n><t>7</t></n><w>bad</w>`
		v10: L10
		err := html.unmarshal(transmute([]u8)fail_deep, &v10, .Fragment, {}, {}, t_alloc)
		f, is_f := err.(tape.Fault)
		testing.expect(t, is_f && f.kind == .Refused && html.Typed_Refusal(f.detail) == .No_Arm)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)

		// Deep succeed -> mutate & free innermost [dynamic]int cleanly.
		ok_deep := `<n><n><n><n><n><n><n><n><n>1</n><n>2</n></n></n></n></n></n></n></n><t>7</t></n><w>99</w>`
		v10_ok: L10
		testing.expect_value(t, html.unmarshal(transmute([]u8)ok_deep, &v10_ok, .Fragment, {}, {}, t_alloc), nil)
		outer_s, is_os := v10_ok.(struct {
			n: L9,
			w: int,
		})
		testing.expect(t, is_os && outer_s.w == 99)
		if is_os {
			s9 := outer_s.n.(struct{n: L8})
			s8 := s9.n.(struct{n: L7})
			s7 := s8.n.(struct{n: L6})
			s6 := s7.n.(struct{n: L5})
			s5 := s6.n.(struct{n: L4})
			s4 := s5.n.(struct{n: L3})
			s3 := s4.n.(struct{n: L2})
			s2 := s3.n.(struct {
				n: L1,
				t: int,
			})
			da := s2.n.(Inner_Dyn).([dynamic]int)
			append(&da, 3)
			testing.expect_value(t, len(da), 3)
			testing.expect_value(t, da[2], 3)
			delete(da)
		}
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}

	// 4. Rehash-safe `map[string]Big_Dyn` inside union with 20 keys (exceeds initial map cap 8 -> forces rehash!) + rehash-safe inner `[dynamic]int` mutation.
	{
		Big_Item :: struct {
			item: [dynamic]int,
		}
		Big_Dyn :: union {
			Big_Item,
			bool,
		}
		Big_Map :: map[string]Big_Dyn
		Big_U :: union {
			Big_Map,
			bool,
		}
		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator)
		for i in 0 ..< 20 {
			strings.write_string(&b, "<k")
			strings.write_int(&b, i)
			strings.write_string(&b, "><item>")
			strings.write_int(&b, i * 10)
			strings.write_string(&b, "</item><item>")
			strings.write_int(&b, i * 10 + 1)
			strings.write_string(&b, "</item></k")
			strings.write_int(&b, i)
			strings.write_string(&b, ">")
		}
		bu: Big_U
		testing.expect_value(t, html.unmarshal(transmute([]u8)strings.to_string(b), &bu, .Fragment, {}, {}, t_alloc), nil)
		bm, is_bm := bu.(Big_Map)
		if testing.expect(t, is_bm && len(bm) == 20) {
			it5, has5 := bm["k5"].(Big_Item)
			if testing.expect(t, has5 && len(it5.item) == 2) {
				testing.expect_value(t, it5.item[0], 50)
				testing.expect_value(t, it5.item[1], 51)
				append(&it5.item, 52)
				testing.expect_value(t, len(it5.item), 3)
				bm["k5"] = it5
			}
			for mk, mv in bm {
				delete(mk, t_alloc)
				if bi, ok := mv.(Big_Item); ok {
					delete(bi.item)
				}
			}
			delete(bm)
		}
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}

	// 5. OOM sweep on Rich_Fail verifying zero leaked blocks on any `fail_at`.
	oom_rich := transmute([]u8)string(`<a>hello</a><d>10</d><d>20</d><m><k1>1</k1><k2>2</k2></m><b>bad</b>`)
	for k in 0 ..< 120 {
		fail := testkit.Failing{backing = t_alloc, fail_at = k}
		rf: Rich_Fail
		err := html.unmarshal(oom_rich, &rf, .Fragment, {}, {}, testkit.failing_allocator(&fail))
		if !fail.failed {
			break
		}
		testing.expect_value(t, err, html.Error(runtime.Allocator_Error.Out_Of_Memory))
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}
}
