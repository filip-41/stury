// Tests for typed `tape.Html_Ext` (zero raw-blob smuggling, clone/destroy leak-freedom),
// incremental multi-window `pieces` streaming parity, bounded raw-window retention, and early-stop paths.
package html_tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:html"
import "stury:lib/core/tape"
import "stury:testkit"

@(test)
html_ext_is_typed_and_clones_cleanly :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Multi-piece text (foster parenting + comments), container `close_end`, and `infer` live in typed `Html_Ext`.
	src := transmute([]u8)string("<div><table>a<tr><td>1</td></tr>b&amp;c</table><p>one<!--c--> two &amp;<!--d--> three</p><n>42</n></div>")
	doc, err := html.build(src, .Fragment, {format = html.Xml_Options{infer = true}}, context.allocator)
	testing.expect_value(t, err, nil)
	if err != nil {
		return
	}

	testing.expect(t, doc.ext != nil)
	if doc.ext == nil {
		tape.destroy(&doc)
		return
	}
	_, is_markup := doc.ext.format.(tape.Markup_Ext)
	testing.expect(t, !is_markup)
	he, is_html := doc.ext.format.(tape.Html_Ext)
	testing.expect(t, is_html)
	testing.expect(t, len(he.ends) > 0)
	testing.expect(t, len(he.texts) >= 2)
	testing.expect(t, len(he.pieces) >= 4)
	testing.expect(t, he.infer)

	// Clone into a tracked `mem.Tracking_Allocator`, destroy original first, verify all typed state on clone, then destroy clone.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	talloc := mem.tracking_allocator(&track)
	clone, cerr := tape.clone_document(&doc, talloc)
	testing.expect_value(t, cerr, nil)
	tape.destroy(&doc)

	testing.expect(t, clone.ext != nil)
	if clone.ext != nil {
		che, cis_html := clone.ext.format.(tape.Html_Ext)
		testing.expect(t, cis_html)
		testing.expect(t, che.infer)
		testing.expect(t, len(che.ends) > 0 && len(che.texts) >= 2 && len(che.pieces) >= 4)
	}

	div, has_div := testkit.member_at(&clone, {"div"})
	testing.expect(t, has_div)
	div_end, has_end := clone.format.close_end(&clone, div)
	testing.expect(t, has_end && div_end == u64(len(src)))

	foster_txt, has_foster := testkit.member_at(&clone, {"div", "#text"})
	testing.expect(t, has_foster)
	testing.expect_value(t, testkit.scalar_text(&clone, foster_txt), "ab&c")

	p_node, has_p := testkit.member_at(&clone, {"div", "p"})
	testing.expect(t, has_p)
	testing.expect_value(t, testkit.scalar_text(&clone, p_node), "one two & three")

	n_node, has_n := testkit.member_at(&clone, {"div", "n"})
	testing.expect(t, has_n)
	testing.expect_value(t, clone.nodes[n_node].kind, tape.Kind.Number)

	tape.destroy(&clone)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
	free_all(context.temp_allocator)
}

@(test)
pieces_stream_entities_scripts_foster_and_utf8_across_cuts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	cases := [?]string {
		"<!DOCTYPE html><p>a &amp; &notit; &#x1F600; &#65; café 😀</p>",
		"<!DOCTYPE html><pre>\r\nline1\r\n</pre><textarea>x &lt; y</textarea><style>a < b && c</style>",
		"<!DOCTYPE html><script>var s = '<!-- not end </script> -->'; if (a < b) {}</script><p>ok</p>",
		"<!DOCTYPE html><svg><![CDATA[a]b]]c]]]d]]><b>ok</b></svg>",
		"<!DOCTYPE html><table>a<tr><td>1</td></tr>b&amp;c</table><b>1<p>2</b>3</p>",
		"<!DOCTYPE html><my-custom-el attr=\"v&amp;1\">inner</my-custom-el><!-- comment --!><?pi body?>",
		"<!DOCTYPE html><select><selectedcontent></selectedcontent><option disabled>off</option><option selected>on</option></select>",
		"<!DOCTYPE html><html lang=en><body class=a><p>x</p><body class=b id=2></html>",
	}
	paths := [][]html.Step {
		{},
		{html.Name("html"), html.Name("body"), html.Name("p")},
		{html.Name("html"), html.Name("body"), html.Name("table"), html.Name("tbody"), html.Name("tr"), html.Name("td")},
		{html.Name("html"), html.Name("body"), html.Name("script")},
		{html.Name("p")},
	}
	for text in cases {
		if !testkit.agree_in_pieces(t, html.reads(.Html), html.as(.Html), transmute([]u8)text, {}, paths, text) {
			return
		}
		if !testkit.agree_in_pieces(t, html.reads(.Fragment), html.as(.Fragment), transmute([]u8)text, {}, paths, text) {
			return
		}
	}
}

@(private = "file")
validate_in_sliding_windows :: proc(src: []u8, spec: html.Spec, chunk_size: int, opts := html.Options{}) -> (err: tape.Error, advances: int, max_retained: u64) {
	p: tape.Pieces
	defer tape.destroy(&p)
	o := opts
	o.pieces = &p

	to := u64(0)
	prev_keep := u64(0)
	for {
		next_to := min(to + u64(chunk_size), u64(len(src)))
		p.from = p.keep
		p.last = next_to == u64(len(src))
		// Copy only `[p.from : next_to)` into a fresh heap slice that is freed immediately after this call,
		// ensuring consumed bytes before `p.from` are genuinely unreferenced.
		win_len := int(next_to - p.from)
		win := make([]u8, win_len, context.allocator)
		copy(win, src[p.from:next_to])
		err = html.validate(win, spec, o)
		delete(win, context.allocator)
		to = next_to
		if err != nil || !p.more {
			break
		}
		if p.keep > prev_keep {
			advances += 1
			prev_keep = p.keep
		}
		retained := to - p.keep
		if retained > max_retained {
			max_retained = retained
		}
	}
	return
}

@(test)
pieces_validate_bounds_raw_window_retention :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// 1. Large valid HTML5 document (> 64 KiB) with attributes on `html`/`body`, open custom element,
	// active formatting element, scripts, entities, UTF-8, and tables.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `<!DOCTYPE html><html lang="en"><head><title>Stream</title></head><body class="main"><custom-shell><b>`)
	for i in 0 ..< 1200 {
		fmt.sbprintf(&b, `<p data-i="%d">Item %d &amp; café 😀</p><script>var v%d = 1 < 2;</script>`, i, i, i)
	}
	strings.write_string(&b, `</b></custom-shell></body></html>`)
	valid_src := transmute([]u8)strings.to_string(b)
	testing.expect(t, len(valid_src) > 64 * 1024)

	whole_valid := html.validate(valid_src, .Html)
	testing.expect_value(t, whole_valid, nil)

	err, advances, max_retained := validate_in_sliding_windows(valid_src, .Html, 512)
	testing.expect_value(t, err, nil)
	testing.expectf(t, advances > 50, "expected p.keep to advance across windows, got %d advances", advances)
	testing.expectf(t, max_retained < 2048, "expected bounded raw window retention (< 2048 B), got %d B", max_retained)

	// 2. Late `<meta charset=latin2>` past prescan (1024 B) detecting an earlier released high byte (`café`).
	m1 := strings.builder_make(context.temp_allocator)
	strings.write_string(&m1, "<!DOCTYPE html><html><head><title>café</title>")
	for _ in 0 ..< 120 {
		strings.write_string(&m1, "<!-- padding -->")
	}
	strings.write_string(&m1, `<meta charset="latin2"></head><body><p>ascii</p></body></html>`)
	late_meta_before := transmute([]u8)strings.to_string(m1)
	want_m1 := html.validate(late_meta_before, .Html)
	got_m1, _, _ := validate_in_sliding_windows(late_meta_before, .Html, 256)
	testing.expect_value(t, got_m1, want_m1)
	testing.expect_value(t, testkit.code_of(got_m1), "encoding")

	// 3. Late `<meta charset=latin2>` past prescan detecting a high byte in a subsequent window.
	m2 := strings.builder_make(context.temp_allocator)
	strings.write_string(&m2, "<!DOCTYPE html><html><head>")
	for _ in 0 ..< 120 {
		strings.write_string(&m2, "<!-- padding -->")
	}
	strings.write_string(&m2, `<meta charset="latin2"></head><body>`)
	for _ in 0 ..< 40 {
		strings.write_string(&m2, "<p>ascii only</p>")
	}
	strings.write_string(&m2, "<p>café</p></body></html>")
	late_meta_after := transmute([]u8)strings.to_string(m2)
	want_m2 := html.validate(late_meta_after, .Html)
	got_m2, _, _ := validate_in_sliding_windows(late_meta_after, .Html, 256)
	testing.expect_value(t, got_m2, want_m2)
	testing.expect_value(t, testkit.code_of(got_m2), "encoding")

	// 4. Streaming validate with `Budget.steps` matches whole-text validate with bounded retention.
	step_opts := html.Options{budget = {steps = 5}}
	want_steps := html.validate(valid_src, .Html, step_opts)
	got_steps, s_adv, s_ret := validate_in_sliding_windows(valid_src, .Html, 512, step_opts)
	testing.expect_value(t, got_steps, want_steps)
	testing.expect(t, s_adv > 50 && s_ret < 2048)
}

@(test)
find_and_scan_early_stop_and_skip_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `<div><section id="first"><p>hit</p><n>123</n></section>`)
	for i in 0 ..< 100 {
		fmt.sbprintf(&b, `<section id="s%d"><ul><li><a href="x">v%d</a></li></ul></section>`, i, i)
	}
	strings.write_string(&b, `</div>`)
	src := transmute([]u8)strings.to_string(b)

	path := []html.Step{html.Name("div"), html.Name("section"), html.Name("p")}
	for opts in ([]html.Options{{}, {format = html.Xml_Options{infer = true}}, {budget = {steps = 50}}}) {
		a_full, e_full := html.find(src, path, .Fragment, {stop_early = false}, opts)
		a_stop, e_stop := html.find(src, path, .Fragment, {stop_early = true}, opts)
		if opts.budget.steps == 0 {
			testing.expect_value(t, e_full, nil)
			testing.expect_value(t, e_stop, nil)
			testing.expect_value(t, a_stop, a_full)
			testing.expect_value(t, string(src[a_stop.lo:a_stop.hi]), "hit")
		} else {
			// With `steps = 50`, `stop_early = true` stops after finding `<p>` before exceeding 50 containers,
			// whereas `stop_early = false` continues counting skipped containers and hits `Exceeded{.Steps}`.
			testing.expect_value(t, e_stop, nil)
			testing.expect_value(t, a_stop.outcome, tape.Presence.Found)
			ex, is_ex := e_full.(tape.Exceeded)
			testing.expect(t, is_ex && ex.kind == .Steps)
		}
	}

	demand, derr := html.demand_of({{html.Name("div"), html.Name("section"), html.Name("n")}}, allocator = context.temp_allocator)
	testing.expect_value(t, derr, nil)
	s_full, se_full := html.scan(src, &demand, .Fragment, {stop_early = false}, {format = html.Xml_Options{infer = true}}, context.temp_allocator)
	s_stop, se_stop := html.scan(src, &demand, .Fragment, {stop_early = true}, {format = html.Xml_Options{infer = true}}, context.temp_allocator)
	testing.expect_value(t, se_full, nil)
	testing.expect_value(t, se_stop, nil)
	n1, ok1 := testkit.member_at(&s_full, {"div", "section", "n"})
	n2, ok2 := testkit.member_at(&s_stop, {"div", "section", "n"})
	testing.expect(t, ok1 && ok2)
	testing.expect_value(t, s_full.nodes[n1].kind, tape.Kind.Number)
	testing.expect_value(t, s_stop.nodes[n2].kind, tape.Kind.Number)
	div1, d1_ok := testkit.member_at(&s_full, {"div"})
	div2, d2_ok := testkit.member_at(&s_stop, {"div"})
	testing.expect(t, d1_ok && d2_ok)
	end1, has_end1 := s_full.format.close_end(&s_full, div1)
	end2, has_end2 := s_stop.format.close_end(&s_stop, div2)
	testing.expect(t, has_end1 && has_end2 && end1 == end2 && end1 == u64(len(src)))
}
