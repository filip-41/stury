// The records of HTML and the answers iterator: a text is one record, from the reader's position to the input's end,
// and the iterator gives the answers `each_answer` gives.
package html_tests

import "core:fmt"
import "core:slice"
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
	faults, err := html.records_check(src, .Document)
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

	Counted :: struct {
		records: int,
	}
	counted: Counted
	walktest.expect_nil(t, html.records_each(src, .Document, .Concatenated, proc(c: ^Counted, piece: ^html.Record_Reader, k: int) -> bool {
		for _ in html.records_next(piece) {
			c.records += 1
		}
		return true
	}, &counted))
	testing.expect_value(t, counted.records, 1)

	empty := html.records_open(nil, .Document)
	defer html.records_close(&empty)
	_, more := html.records_next(&empty)
	testing.expect(t, !more && empty.fault == nil)
	from := html.records_open(src, html.Spec.Fragment, at = 28)
	defer html.records_close(&from)
	rec, ok := html.records_next(&from)
	testing.expect(t, ok && rec.at == 28 && strings.has_prefix(string(rec.text), "<p>1"))

	defer free_all(context.temp_allocator)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for i in 0 ..< 20000 {
		fmt.sbprintf(&b, "<li id=%d>t", i)
	}
	whole := strings.to_string(b)
	r: strings.Reader
	stream := html.records_open_stream(strings.to_reader(&r, whole), html.Spec.Fragment, stream = {max_bytes = 1 << 22})
	defer html.records_close(&stream)
	n = 0
	for got in html.records_next(&stream) {
		testing.expect(t, string(got.text) == whole && got.at == 0)
		n += 1
	}
	testing.expect(t, n == 1 && stream.fault == nil)
}

@(private = "file")
collect_answer :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	append((^[dynamic]core.Token_Answer)(state), a)
	return true
}

// The iterator gives the answers `each_answer` gives and ends with its error, whatever its largest batch.
@(test)
answers_agree_with_each_answer :: proc(t: ^testing.T) {
	texts := [?]string{".html.body.p", ".html.body[]", "..", ".html.body.table.tbody.tr.td", ".z"}
	want, got: [dynamic]core.Token_Answer
	defer delete(want)
	defer delete(got)
	src := transmute([]u8)string(RECORD_TEXT)
	for text in texts {
		path, perr := html.parse_path(text)
		walktest.expect_nil(t, perr)
		defer html.destroy(&path)
		for dups in ([]core.Duplicates{.Last, .Refuse}) {
			read := core.Path_Options{dups = dups}
			clear(&want)
			err := html.each_answer(src, .Document, path, &want, collect_answer, {}, read)
			for batch in ([]int{1, 64}) {
				spec := html.Spec.Document
				it := html.answers(src, spec, path, {}, read) if batch == 1 else html.answers(src, .Document, path, {}, read)
				it.max_batch = batch
				clear(&got)
				for a in html.next(&it) {
					append(&got, a)
				}
				ok := testing.expectf(t, slice.equal(got[:], want[:]), "%s batch %d: %d answers, want %d", text, batch, len(got), len(want))
				ok &&= testing.expectf(t, fmt.tprint(it.err) == fmt.tprint(err), "%s batch %d: %v, want %v", text, batch, it.err, err)
				if !ok {
					return
				}
			}
		}
	}
}
