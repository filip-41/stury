// The records of XML and the answers iterator: a text is one record, from the reader's position to the input's end, and
// the iterator gives the answers `each_answer` gives.
package xml_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import records "../../core/records"
import xml ".."
import walktest "../../walktest"

@(private = "file")
RECORD_TEXT :: "<?xml version=\"1.0\"?>\n<!-- lead -->\n<a><b>1</b><b>2</b><c x=\"y\"/></a>\n<?pi tail?>\n"

// The record entry points of a constant spec and of a spec chosen at run time frame and judge the text as one record,
// and a reader that gets `record_docs` builds and scans it.
@(test)
every_record_form_reads_a_text :: proc(t: ^testing.T) {
	src := transmute([]u8)string(RECORD_TEXT)
	faults, err := xml.records_check(src, .Xml)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(faults), 0)
	delete(faults)
	it := xml.records_open(src, .Xml)
	defer xml.records_close(&it)
	it.docs = xml.record_docs(.Xml)
	n := 0
	for rec in xml.records_next(&it) {
		testing.expect_value(t, string(rec.text), RECORD_TEXT)
		doc, derr := xml.records_build(&it, rec)
		walktest.expect_nil(t, derr)
		testing.expect_value(t, core.length(core.Value(core.Node_Ref{&doc, core.ROOT})), 1)
		xml.destroy(&doc)
		n += 1
	}
	testing.expect_value(t, n, 1)

	path, perr := xml.parse_path(".a.b")
	walktest.expect_nil(t, perr)
	defer xml.destroy(&path)
	spec := xml.Spec.Xml
	scanned := records.open(src, xml.as(spec), .Concatenated)
	defer xml.records_close(&scanned)
	found := 0
	for {
		_, got, serr, more := xml.records_scan(&scanned, path)
		if !more {
			break
		}
		walktest.expect_nil(t, serr)
		found += len(got.answers)
	}
	testing.expect_value(t, found, 1)

	Counted :: struct {
		records: int,
	}
	counted: Counted
	walktest.expect_nil(t, xml.records_each(src, .Xml, .Concatenated, proc(c: ^Counted, piece: ^xml.Record_Reader, k: int) -> bool {
		for _ in xml.records_next(piece) {
			c.records += 1
		}
		return true
	}, &counted))
	testing.expect_value(t, counted.records, 1)
}

// An input of no bytes holds no record, a record read from a byte past the first starts there, a refused text is the
// reader's fault at its byte in the input, and a stream is one record once its input has ended.
@(test)
a_record_is_the_rest_of_the_input :: proc(t: ^testing.T) {
	empty := xml.records_open(nil, .Xml)
	defer xml.records_close(&empty)
	_, more := xml.records_next(&empty)
	testing.expect(t, !more && empty.fault == nil)
	src := transmute([]u8)string("<a/><b>1</b>")
	from := xml.records_open(src, .Xml, at = 4)
	defer xml.records_close(&from)
	rec, ok := xml.records_next(&from)
	testing.expect(t, ok && rec.at == 4 && string(rec.text) == "<b>1</b>")
	bad := transmute([]u8)string("<a><b></c></a>")
	faults, err := xml.records_check(bad, .Xml)
	defer delete(faults)
	testing.expectf(t, err == nil && len(faults) == 1 && faults[0].detail == u8(xml.Detail.Mismatched_Tag) && faults[0].at == 8, "%v", faults)
	defer free_all(context.temp_allocator)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "<r>")
	for i in 0 ..< 20000 {
		fmt.sbprintf(&b, "<e n=\"%d\">t</e>", i)
	}
	strings.write_string(&b, "</r>")
	whole := strings.to_string(b)
	r: strings.Reader
	stream := xml.records_open_stream(strings.to_reader(&r, whole), xml.Spec.Xml, stream = {max_bytes = 1 << 22})
	defer xml.records_close(&stream)
	n := 0
	for got in xml.records_next(&stream) {
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

// The iterator gives the answers `each_answer` gives and ends with its error, whatever its largest batch, and a loop
// that ends after the first answer frees the read with `destroy`.
@(test)
answers_agree_with_each_answer :: proc(t: ^testing.T) {
	texts := [?]string{".a.b", ".a[]", "..", ".a.c", ".a[\"#text\"]", ".z"}
	srcs := [?]string{RECORD_TEXT, "<a>x<b>1</b>y<b>2</b></a>", "<a><b>1</b><b>2</b></a", "<a><b>1</b></a><a/>"}
	want, got: [dynamic]core.Token_Answer
	defer delete(want)
	defer delete(got)
	for text in texts {
		path, perr := xml.parse_path(text)
		walktest.expect_nil(t, perr)
		defer xml.destroy(&path)
		for s in srcs {
			src := transmute([]u8)s
			for dups in ([]core.Duplicates{.Last, .Refuse}) {
				read := core.Path_Options{dups = dups}
				clear(&want)
				err := xml.each_answer(src, .Xml, path, &want, collect_answer, {}, read)
				for batch in ([]int{1, 3, 64}) {
					it := xml.answers(src, .Xml, path, {}, read)
					it.max_batch = batch
					clear(&got)
					for a in xml.next(&it) {
						append(&got, a)
					}
					ok := testing.expectf(t, slice.equal(got[:], want[:]), "%q %s batch %d: %d answers, want %d", s, text, batch, len(got), len(want))
					ok &&= testing.expectf(t, fmt.tprint(it.err) == fmt.tprint(err), "%q %s batch %d: %v, want %v", s, text, batch, it.err, err)
					if !ok {
						return
					}
				}
			}
		}
	}
	path, _ := xml.parse_path(".a[]")
	defer xml.destroy(&path)
	src := transmute([]u8)string("<a><b>1</b><c>2</c></a>")
	spec := xml.Spec.Xml
	it := xml.answers(src, spec, path)
	first: core.Token_Answer
	for a in xml.next(&it) {
		first = a
		break
	}
	testing.expectf(t, it.err == nil && first.outcome == .Found && string(src[first.lo:first.hi]) == "1", "%v %v", first, it.err)
	xml.destroy(&it)
}
