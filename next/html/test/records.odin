// HTML5 records framing: `.Concatenated` (whole text record) and `.Members` (container members in document order, including path navigation and pieces).
package html_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:html"
import "stury:lib/core/tape"
import "stury:testkit"

@(private = "file")
RECORD_TEXT :: "<!doctype html><!-- lead --><p>1<p>2</p><table><td>x</table>\n<!-- tail -->"

@(test)
every_record_form_reads_a_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string(RECORD_TEXT)
	r := html.records_open(src)
	defer tape.destroy_records(&r)
	out: [2]tape.Record
	testing.expect_value(t, html.records_validate(&r, out[:]), 0)
	testing.expect_value(t, r.index, 1)
	testing.expect_value(t, r.err, nil)

	path := []tape.Step{tape.Name("html"), tape.Name("body"), tape.Name("table"), tape.Name("tbody"), tape.Name("tr"), tape.Name("td")}
	f := html.records_open(src)
	defer tape.destroy_records(&f)
	answers: [2]tape.Span_Answer
	testing.expect_value(t, html.records_find(&f, path, out[:], answers[:]), 1)
	testing.expect_value(t, out[0].err, nil)
	testing.expect_value(t, out[0].lo, 0)
	testing.expect_value(t, out[0].hi, u64(len(src)))
	testing.expect_value(t, string(src[answers[0].lo:answers[0].hi]), "x")
	whole, _ := html.find(src, path)
	testing.expect_value(t, answers[0], whole)

	demand, _ := html.demand_of({path}, allocator = context.temp_allocator)
	s := html.records_open(src)
	defer tape.destroy_records(&s)
	docs: [2]tape.Document
	testing.expect_value(t, html.records_scan(&s, &demand, out[:], docs[:], {}, context.temp_allocator), 1)
	at, p, _ := html.answer({doc = &docs[0]}, 0, 0)
	testing.expect_value(t, p, tape.Presence.Found)
	testing.expect_value(t, text_of(&docs[0], at), "x")
	testing.expect_value(t, s.err, nil)

	chosen, err := html.reads(.Html).records(html.as(.Html), src, .Concatenated, {}, nil, context.allocator)
	testing.expect_value(t, err, nil)
	defer tape.destroy_records(chosen)
	testing.expect_value(t, tape.records_validate(chosen, out[:]), 0)
	testing.expect_value(t, chosen.index, 1)
	testing.expect_value(t, chosen.err, nil)
}

@(test)
a_record_is_the_rest_of_the_input :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	out: [2]tape.Record
	empty := html.records_open(nil)
	defer tape.destroy_records(&empty)
	testing.expect_value(t, html.records_validate(&empty, out[:]), 0)
	testing.expect_value(t, empty.index, 0)
	testing.expect_value(t, empty.err, nil)

	src := transmute([]u8)string("<p>1</p><div>2</div>")
	r := html.records_open(src, .Concatenated, .Fragment)
	defer tape.destroy_records(&r)
	r.pos = 8
	answers: [2]tape.Span_Answer
	testing.expect_value(t, html.records_find(&r, {tape.Name("div")}, out[:], answers[:]), 1)
	testing.expect_value(t, out[0].lo, 8)
	testing.expect_value(t, out[0].hi, u64(len(src)))
	testing.expect_value(t, out[0].err, nil)
	testing.expect_value(t, string(src[answers[0].lo:answers[0].hi]), "2")

	// Encoding fault shows up on validate.
	bad := transmute([]u8)string("<meta charset=latin2><p>caf\xe9")
	b := html.records_open(bad)
	defer tape.destroy_records(&b)
	testing.expect_value(t, html.records_validate(&b, out[:]), 1)
	f, faulted := out[0].err.(tape.Fault)
	testing.expect_value(t, faulted, true)
	testing.expect_value(t, code_of(out[0].err), "encoding")
	testing.expect_value(t, f.at, 14)

	big := strings.builder_make(context.temp_allocator)
	strings.write_string(&big, "<!DOCTYPE html><ul>")
	for i in 0 ..< 10000 {
		fmt.sbprintf(&big, "<li id=%d>t", i)
	}
	strings.write_string(&big, "</ul>")
	whole := transmute([]u8)strings.to_string(big)
	w := html.records_open(whole)
	defer tape.destroy_records(&w)
	testing.expect_value(t, html.records_validate(&w, out[:]), 0)
	testing.expect_value(t, w.index, 1)
	testing.expect_value(t, w.err, nil)
}

@(test)
records_refuse_options_they_cannot_take :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("<a/>")
	out: [1]tape.Record
	for framing in ([]tape.Framing{.Lines, .Seq, .Elements}) {
		r := html.records_open(src, framing)
		testing.expect(t, html.records_validate(&r, out[:]) == 0 && r.err == tape.Error(tape.Bad_Option{"framing"}))
	}
	for path in ([][]tape.Step{{tape.Name("a"), tape.All{}}}) {
		at := html.records_open(src, .Members, .Fragment, {}, path)
		testing.expect(t, html.records_validate(&at, out[:]) == 0 && at.err == tape.Error(tape.Bad_Option{"path"}))
	}
	whole := html.records_open(src, .Concatenated, .Fragment, {}, {tape.Name("a")})
	testing.expect(t, html.records_validate(&whole, out[:]) == 0 && whole.err == tape.Error(tape.Bad_Option{"path"}))
	p := tape.Pieces{last = true}
	pieces_members := html.records_open(src, .Members, .Fragment, {pieces = &p})
	testing.expect(t, html.records_validate(&pieces_members, out[:]) == 0 && pieces_members.err == tape.Error(tape.Bad_Option{"pieces"}))
}

@(private = "file")
member_lines :: proc(src: string, spec := html.Spec.Fragment, opts := html.Options{}, path: []tape.Step = nil) -> string {
	b := strings.builder_make(context.temp_allocator)
	whole, _ := html.demand_of({{}}, nil, nil, true, context.temp_allocator)
	r := html.records_open(transmute([]u8)src, .Members, spec, opts, path)
	defer tape.destroy_records(&r)
	out: [2]tape.Record
	docs: [2]tape.Document
	for {
		n := html.records_scan(&r, &whole, out[:], docs[:], {}, context.temp_allocator)
		for rec, k in out[:n] {
			key := "#text" if rec.key.n == 0 else src[rec.key.lo:][:rec.key.n]
			fmt.sbprintf(&b, "%d-%d %s %s%s\n", rec.lo, rec.hi, key, testkit.render_doc(&docs[k]), code_of(rec.err))
		}
		if n < len(out) {
			break
		}
	}
	fmt.sbprintf(&b, "end %s", code_of(r.err))
	return strings.to_string(b)
}

@(test)
members_are_container_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := "<ul><li>a<li>b <i>c</i><li><p>d</ul>"
	testing.expect_value(
		t,
		member_lines(src, .Fragment, {}, {tape.Name("ul")}),
		"8-9 li a\n9-23 li {:b ,i:c}\n23-31 li {p:d}\nend ",
	)
	testing.expect_value(
		t,
		member_lines("<div><a>1</a>tail<b>2</b></div>", .Fragment, {}, {tape.Name("div")}),
		"8-9 a 1\n13-17 #text tail\n20-21 b 2\nend ",
	)
	testing.expect_value(t, member_lines("<div>only text</div>", .Fragment, {}, {tape.Name("div")}), "5-14 #text only text\nend ")
	testing.expect_value(t, member_lines("<div></div>", .Fragment, {}, {tape.Name("div")}), "end ")
	testing.expect_value(t, member_lines("<div></div>", .Fragment, {}, {tape.Name("none")}), "end ")
	// Whole document records yield `html`, or navigate down `.html.body.ul`.
	testing.expect_value(
		t,
		member_lines("<!doctype html><ul><li>a<li>b</ul>", .Html, {}, {tape.Name("html"), tape.Name("body"), tape.Name("ul")}),
		"23-24 li a\n28-29 li b\nend ",
	)
}

@(test)
members_budget_memory_lives_across_batches :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string("<ul><li>one</li><li>two</li><li>three</li><li>four</li><li>five</li></ul>")
	demand, derr := html.demand_of({{}}, nil, nil, false, context.temp_allocator)
	testing.expect_value(t, derr, nil)

	// Open `.Members` with explicit `budget.memory` and read in multiple batches so `r.held.allocator` outlives batch calls.
	r := html.records_open(src, .Members, .Fragment, {budget = {memory = 1 << 20}}, {tape.Name("ul")})
	defer tape.destroy_records(&r)

	total := 0
	for {
		out: [2]tape.Record
		docs: [2]tape.Document
		n := html.records_scan(&r, &demand, out[:], docs[:], {}, context.temp_allocator)
		for k in 0 ..< n {
			testing.expect_value(t, out[k].err, nil)
			total += 1
		}
		if n < len(out) {
			break
		}
	}
	testing.expect_value(t, r.err, nil)
	testing.expect_value(t, total, 5)

	// Tight memory budget in `.Members` returns `Exceeded{.Memory}` cleanly without panicking.
	tight := html.records_open(src, .Members, .Fragment, {budget = {memory = 128}}, {tape.Name("ul")})
	defer tape.destroy_records(&tight)
	tout: [2]tape.Record
	testing.expect_value(t, html.records_validate(&tight, tout[:]), 0)
	te, is_ex := tight.err.(tape.Exceeded)
	testing.expect(t, is_ex && te.kind == .Memory)
}
