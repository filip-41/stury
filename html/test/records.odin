// The records of HTML and the answers iterator: a text is one record, from the reader's position to the input's end,
// and the iterator gives the answers `each_answer` gives.
package html_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import html ".."
import walktest "../../walktest"

@(private = "file")
RECORD_TEXT :: "<!doctype html><!-- lead --><p>1<p>2</p><table><td>x</table>\n<!-- tail -->"

// Every record form frames and judges the text as one record, a reader that gets `record_docs` builds and scans it,
// a record read from a byte past the first starts there, and a stream is one record once its input has ended.
@(test)
a_record_is_the_rest_of_the_input :: proc(t: ^testing.T) {
	src := transmute([]u8)string(RECORD_TEXT)
	faults, err := html.records_validate(src, .Document)
	testing.expect(t, err == nil && len(faults) == 0)
	delete(faults)
	it := html.records_open(src, .Document)
	defer html.records_close(&it)
	it.docs = html.record_docs(.Document)
	n := 0
	for rec in html.records_next(&it) {
		testing.expect_value(t, string(rec.text), RECORD_TEXT)
		doc, derr := html.records_build(&it, rec)
		walktest.expect_nil(t, derr)
		_, found := walktest.member_at(t, &doc, ".html.body.table.tbody.tr.td")
		testing.expect(t, found)
		html.destroy(&doc)
		n += 1
	}
	testing.expect_value(t, n, 1)

	each := 0
	walktest.expect_nil(t, html.records_each(src, .Document, .Concatenated, walktest.count_records, &each))
	testing.expect_value(t, each, 1)

	walktest.expect_record_is_the_rest(t, RECORD_TEXT, 28, html.as(.Fragment))

	defer free_all(context.temp_allocator)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for i in 0 ..< 20000 {
		fmt.sbprintf(&b, "<li id=%d>t", i)
	}
	whole := strings.to_string(b)
	walktest.expect_stream_is_one_record(t, whole, html.as(.Fragment))
}

// The iterator gives the answers `each_answer` gives and ends with its error, whatever its largest batch, for each
// duplicate policy.
@(test)
answers_agree_with_each_answer :: proc(t: ^testing.T) {
	run := walktest.Answer_Run {
		each = proc(src: []u8, paths: []core.Path, variant: int, early: bool, out: ^[dynamic]core.Token_Answer) -> core.Error {
			return html.each_answer(src, .Document, paths, out, walktest.collect_answer, {}, {dups = .Refuse if variant == 1 else .Last, stop_early = early})
		},
		iter = proc(src: []u8, paths: []core.Path, variant: int, early: bool, batch: int, out: ^[dynamic]core.Token_Answer) -> core.Error {
			it := html.answers(src, .Document, paths, {}, {dups = .Refuse if variant == 1 else .Last, stop_early = early})
			it.max_batch = batch
			for a in html.next(&it) {
				append(out, a)
			}
			return it.err
		},
	}
	walktest.expect_answers_agree(t, {RECORD_TEXT}, {".html.body.p", ".html.body[]", "..", ".html.body.table.tbody.tr.td", ".z"}, 2, run)
}

// `.Entries` gives the members of the element a path of names reaches, each read from the whole tree, with the ends
// of its elements, and a fault ends the records at the byte `validate` gives.
@(test)
entries_are_the_members_of_a_container :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "<ul><li>a<li>b <i>c</i><li><p>d</ul>"
	LI :: "8 li \"a\"\n9 li {\"#text\":\"b \",\"i\":\"c\"}\n23 li {\"p\":\"d\"}\nend"
	walktest.expect_entries(t, src, html.as(.Fragment), {"ul"}, LI)
	walktest.expect_framings(t, html.CAPABILITIES, html.as(.Fragment))
	it := html.records_open(transmute([]u8)src, .Fragment, framing = .Entries, entries = {"ul"})
	testing.expect_value(t, walktest.entries_lines(&it), LI)
	numbers := "<ul><li>&#55;<li>&#45;8<li>9</ul>"
	testing.expect_value(t, walktest.entries_read(numbers, html.as(.Fragment), {"ul"}, int), "7\n-8\n9\nend")
}
