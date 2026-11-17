// The format package's entry points, and the calls in `core` with a handle.
package html_tests

import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import html ".."
import walktest "../../walktest"

@(private = "file")
entry_points :: proc(src: []u8, c: core.Path, paths: []core.Path, r: ^walktest.Entry_Reads) {
	r.errs[0] = html.validate(src, .Fragment)
	r.doc, r.errs[1] = html.build(src, .Fragment)
	r.sdoc, r.errs[2] = html.scan(src, .Fragment, c)
	r.mdoc, r.errs[3] = html.scan(src, .Fragment, paths)
	r.fdoc, r.answer, r.errs[4] = html.find(src, .Fragment, c)
	r.errs[5] = html.each_answer(src, .Fragment, c, &r.one, walktest.count_found)
	r.errs[6] = html.each_answer(src, .Fragment, paths, &r.many, walktest.count_found)
}

@(test)
every_entry_point_reads_by_a_constant_spec_and_a_chosen_one :: proc(t: ^testing.T) {
	chosen := html.Spec.Fragment
	walktest.expect_entry_points(t, html.as(chosen), entry_points)
}

@(test)
a_repeated_name_is_refused_only_when_asked :: proc(t: ^testing.T) {
	walktest.expect_repeated_name_refused_only_when_asked(t, proc(src: []u8, path: core.Path) -> (built, scanned, answered: core.Error) {
		doc, err := html.build(src, .Fragment, {}, .Refuse)
		defer core.destroy(&doc)
		_, serr := html.scan(src, .Fragment, path, {}, {dups = .Refuse})
		return err, serr, html.each_answer(src, .Fragment, path, nil, proc(state: rawptr, a: core.Token_Answer) -> bool {return true})
	})
}

// A path answers through the build: found containers span their tags, and a stream stops when asked.
@(test)
answers_carry_the_spans_of_their_nodes :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`<ul><li>a</li><li><b>b</b></li></ul>`)
	path, _ := core.parse_path(".ul.li")
	defer core.path_destroy(&path)
	Spans :: struct {
		texts: [dynamic]string,
		src:   []u8,
	}
	got := Spans{src = src}
	defer delete(got.texts)
	err := html.each_answer(src, .Fragment, path, &got, proc(state: rawptr, a: core.Token_Answer) -> bool {
		s := (^Spans)(state)
		append(&s.texts, string(s.src[a.lo:a.hi]))
		return true
	}, {}, {dups = .All})
	walktest.expect_nil(t, err)
	testing.expect_value(t, len(got.texts), 2)
	if len(got.texts) == 2 {
		testing.expect_value(t, got.texts[0], "a")
		testing.expect_value(t, got.texts[1], "<li><b>b</b></li>")
	}
}

// A list over a document a handle built takes HTML's edits from the handle.
@(test)
an_edit_list_takes_the_handles_edits :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`<a><b>1</b></a>`)
	doc, err := core.build(src, html.as(.Fragment))
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	a, _ := core.member(&doc, core.ROOT, "a")
	walktest.expect_nil(t, write.insert(&list, a, 1, "c", typed.Raw("2")))
	out, _, cerr := compose.commit(&list)
	defer delete(out)
	walktest.expect_nil(t, cerr)
	testing.expect_value(t, string(out), "<a><b>1</b><c>2</c></a>")
}

@(test)
a_handle_keeps_its_options :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`<body><noscript><p>12</p></noscript><n>12</n>`)
	doc, err := core.build(src, html.as(.Document, {infer = true}))
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	n, _ := walktest.member_at(t, &doc, ".html.body.n")
	testing.expect_value(t, core.kind(&doc, n), core.Kind.Number)
	_, found := walktest.member_at(t, &doc, ".html.body.noscript.p")
	testing.expect(t, found)
	scripted, serr := core.build(src, html.as(.Document, {scripting = true}))
	walktest.expect_nil(t, serr)
	defer core.destroy(&scripted)
	noscript, _ := walktest.member_at(t, &scripted, ".html.body.noscript")
	testing.expect_value(t, walktest.node_text(t, &scripted, noscript), "<p>12</p>")
	// A fragment's context element is the one the options name.
	cell, cerr := core.build(transmute([]u8)string("<td>1<td>2"), html.as(.Fragment, {context_name = "tr"}))
	walktest.expect_nil(t, cerr)
	defer core.destroy(&cell)
	testing.expect_value(t, core.length(&cell, core.ROOT), 2)
	deep := transmute([]u8)string(`<a><b><c></c></b></a>`)
	f, bad := walktest.fault_in(core.validate(deep, html.as(.Fragment, {max_depth = 2})))
	testing.expect(t, bad)
	testing.expect_value(t, f.kind, core.Fault_Kind.Too_Deep)
}
