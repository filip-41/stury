// The format package's entry points, in the form that binds a constant spec and the form that takes one at run time.
package html_tests

import "core:strings"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import html ".."
import walktest "../../walktest"

@(private = "file")
Seen :: struct {
	found: int,
}

@(private = "file")
count_found :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	if a.outcome == .Found {
		(^Seen)(state).found += 1
	}
	return true
}

// Every entry point with `spec`, a constant in one caller and a value chosen at run time in the other.
@(private = "file")
entry_points :: proc(t: ^testing.T, spec: html.Spec, bound: bool) {
	src := transmute([]u8)string(`<a><b>1</b><c k="v">2</c><b>3</b></a>`)
	b, perr := core.parse_path(".a.b")
	walktest.expect_nil(t, perr)
	defer core.path_destroy(&b)
	c, cerr := core.parse_path(".a.c")
	walktest.expect_nil(t, cerr)
	defer core.path_destroy(&c)
	paths := [?]core.Path{b, c}

	doc, sdoc, mdoc, fdoc: core.Document
	answer: core.Answer
	berr, serr, merr, ferr, one, many, verr: core.Error
	seen_one, seen_many: Seen
	if bound {
		verr = html.validate(src, .Fragment)
		doc, berr = html.build(src, .Fragment)
		sdoc, serr = html.scan(src, .Fragment, c)
		mdoc, merr = html.scan(src, .Fragment, paths[:])
		fdoc, answer, ferr = html.find(src, .Fragment, c)
		one = html.each_answer(src, .Fragment, c, &seen_one, count_found)
		many = html.each_answer(src, .Fragment, paths[:], &seen_many, count_found)
	} else {
		verr = html.validate(src, spec)
		doc, berr = html.build(src, spec)
		sdoc, serr = html.scan(src, spec, c)
		mdoc, merr = html.scan(src, spec, paths[:])
		fdoc, answer, ferr = html.find(src, spec, c)
		one = html.each_answer(src, spec, c, &seen_one, count_found)
		many = html.each_answer(src, spec, paths[:], &seen_many, count_found)
	}
	defer core.destroy(&doc)
	defer core.destroy(&sdoc)
	defer core.destroy(&mdoc)
	defer core.destroy(&fdoc)
	for err in ([?]core.Error{verr, berr, serr, merr, ferr, one, many}) {
		walktest.expect_nil(t, err)
	}
	// A document read as a constant spec holds no services, and one read through the handle holds them.
	testing.expect_value(t, core.services_of(doc.as) == nil, bound)
	testing.expect_value(t, len(sdoc.answers), 1)
	testing.expect_value(t, walktest.node_text(t, &sdoc, sdoc.answers[0].node), "2")
	testing.expect_value(t, len(mdoc.answers), 2)
	testing.expect_value(t, walktest.node_text(t, &mdoc, mdoc.answers[0].node), "2")
	testing.expect_value(t, walktest.node_text(t, &mdoc, mdoc.answers[1].node), "3")
	testing.expect_value(t, answer.outcome, core.Presence.Found)
	testing.expect_value(t, seen_one.found, 1)
	testing.expect_value(t, seen_many.found, 2)

	answers, qerr := html.query(&doc, b, {dups = .All})
	defer delete(answers)
	walktest.expect_nil(t, qerr)
	testing.expect_value(t, len(answers), 2)
	testing.expect_value(t, walktest.node_text(t, &doc, answers[0].node), "1")
	testing.expect_value(t, walktest.node_text(t, &doc, answers[1].node), "3")
}

@(test)
every_entry_point_reads_by_a_constant_spec_and_a_chosen_one :: proc(t: ^testing.T) {
	entry_points(t, .Fragment, true)
	chosen := html.Spec.Fragment
	entry_points(t, chosen, false)
}

@(test)
a_repeated_name_is_refused_only_when_asked :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`<a><b>1</b><b>2</b></a>`)
	doc, err := html.build(src, .Fragment, {}, .Refuse)
	defer core.destroy(&doc)
	f, bad := walktest.fault_in(err)
	testing.expect(t, bad)
	testing.expect_value(t, f.kind, core.Fault_Kind.Duplicate_Key)
	testing.expect_value(t, f.at, u64(strings.index(string(src), "b>2")))
	path, _ := core.parse_path(".a.b")
	defer core.path_destroy(&path)
	_, serr := html.scan(src, .Fragment, path, {}, {dups = .Refuse})
	_, refused := walktest.fault_in(serr)
	testing.expect(t, refused)
	walktest.expect_nil(t, html.each_answer(src, .Fragment, path, nil, proc(state: rawptr, a: core.Token_Answer) -> bool {return true}))
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
