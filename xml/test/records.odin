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
	faults, err := xml.records_validate(src, .Xml)
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
	scanned := records.open(src, xml.as(.Xml), .Concatenated)
	defer xml.records_close(&scanned)
	walktest.expect_records_scanned(t, &scanned, path, 1)
	each := 0
	walktest.expect_nil(t, xml.records_each(src, .Xml, .Concatenated, walktest.count_records, &each))
	testing.expect_value(t, each, 1)
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
	faults, err := xml.records_validate(bad, .Xml)
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
	it := xml.answers(src, .Xml, path)
	first: core.Token_Answer
	for a in xml.next(&it) {
		first = a
		break
	}
	testing.expectf(t, it.err == nil && first.outcome == .Found && string(src[first.lo:first.hi]) == "1", "%v %v", first, it.err)
	xml.destroy(&it)
}

// `.Entries` gives the members of the element a path of names reaches as the walk reads them, each with its
// attributes, and a fault ends the records at the byte `validate` gives, after the members before it.
@(test)
entries_are_the_members_of_a_container :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "<r a=\"1\"><b x=\"1\">t</b><b/><c><d>2</d></c></r>"
	walktest.expect_entries(t, src, xml.as(.Xml), {"r"}, "18 b \"t\"\n25 b null\n27 c {\"d\":\"2\"}\nend")
	walktest.expect_entries(t, src, xml.as(.Xml), nil, "0 r {\"b\":[\"t\",null],\"c\":{\"d\":\"2\"}}\nend")
	walktest.expect_framings(t, xml.CAPABILITIES, xml.as(.Xml))
	bad := "<r><b>1</b><b>2</c></r>"
	fault, _ := walktest.fault_in(xml.validate(transmute([]u8)string(bad), .Xml))
	walktest.expect_entries(t, bad, xml.as(.Xml), {"r"}, fmt.tprintf("6 b \"1\"\nfault %d", fault.at))
	it := xml.records_open(transmute([]u8)src, .Xml, framing = .Entries, entries = {"r"})
	testing.expect_value(t, walktest.entries_lines(&it), "18 b \"t\"\n25 b null\n27 c {\"d\":\"2\"}\nend")
}

// A member under `.Entries` reads in its place, as the build of the whole text reads it: under the namespaces its
// ancestors declare and the DTD's entities and attribute defaults, by a build and by a typed read.
@(test)
entries_read_in_their_place :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ns := "<r xmlns:n=\"u\"><n:a>1</n:a><n:b k=\"2\"/></r>"
	walktest.expect_entries(t, ns, xml.as(.Xml), {"r"}, "20 n:a \"1\"\n37 n:b null\nend")
	dtd := "<!DOCTYPE r [<!ENTITY e \"x\"><!ATTLIST b d CDATA \"v\">]><r><b>&e;</b><b/></r>"
	walktest.expect_entries(t, dtd, xml.as(.Xml), {"r"}, "60 b \"x\"\n69 b null\nend")
	numbers := "<!DOCTYPE r [<!ENTITY e \"7\">]><r xmlns:n=\"u\"><n:b>&e;</n:b><n:b>8</n:b></r>"
	testing.expect_value(t, walktest.entries_read(numbers, xml.as(.Xml), {"r"}, int), "7\n8\nend")
}

// Reading the records of an element with ten times as many children under `.Entries` holds no more of the reader's
// memory at its peak: the walk pauses at each child's end and holds no tokens past it. From a stream too, under
// namespaces an ancestor declares, and under a DTD that declares entities and attribute defaults: the window follows
// the members and keeps no more than one past the last record, and the DTD.
@(test)
entries_hold_one_member :: proc(t: ^testing.T) {
	walktest.expect_entries_bounded(t, xml.as(.Xml), {"r"}, "<r>", "<l id=\"7\"><t>a</t><t>b</t></l>\n", "</r>", false)
	member := strings.concatenate({"<n:l id=\"7\"><t>", strings.repeat("0123456789", 70, context.temp_allocator), "</t></n:l>\n"}, context.temp_allocator)
	walktest.expect_entries_bounded(t, xml.as(.Xml), {"r", "s"}, "<r xmlns:n=\"u\"><s xmlns=\"d\">", member, "</s></r>", true)
	dtd := "<!DOCTYPE r [<!ENTITY e \"<t>x</t>\"><!ATTLIST l d CDATA \"v\">]><r><s>"
	member = strings.concatenate({"<l>&e;<t>", strings.repeat("0123456789", 70, context.temp_allocator), "</t></l>\n"}, context.temp_allocator)
	walktest.expect_entries_bounded(t, xml.as(.Xml), {"r", "s"}, dtd, member, "</s></r>", true)
}

// A member read from a stream whose window has moved past its ancestors' start tags, and past the members before it,
// reads as it does in memory: under the namespaces the ancestors declare, and with the DTD's entities and attribute
// defaults.
@(test)
entries_follow_the_window :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]string {
		strings.concatenate({"<r xmlns:n=\"u\" xmlns:m=\"v\"><s xmlns=\"d\">", strings.repeat("<n:a m:k=\"1\">x</n:a><b><n:c/></b>", 12, context.temp_allocator), "</s></r>"}, context.temp_allocator),
		strings.concatenate({"<!DOCTYPE r [<!ENTITY e \"x<i>y</i>\"><!ATTLIST b d CDATA \"v\">]><r><s>", strings.repeat("<b>&e;</b><b d=\"w\"/><c>&e;&e;</c>", 12, context.temp_allocator), "</s></r>"}, context.temp_allocator),
		strings.concatenate({"<?xml version=\"1.0\"?><!DOCTYPE r [<!ELEMENT r ANY><!-- c -->]><r xmlns:n=\"u\"><s>", strings.repeat("<n:b>1</n:b><c/>", 12, context.temp_allocator), "</s></r>"}, context.temp_allocator),
	}
	for src in cases {
		it := records.open(transmute([]u8)src, xml.as(.Xml), .Entries, entries = {"r", "s"})
		want := walktest.entries_lines(&it)
		testing.expect(t, strings.has_suffix(want, "end"))
		walktest.expect_entries(t, src, xml.as(.Xml), {"r", "s"}, want)
	}
}

// A member given before the last builds once later members are read, in memory and while a stream's window holds it,
// and is `.Bad_Index` once the window has moved past it.
@(test)
entries_build_after_later_members :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	walktest.expect_entries_built_later(t, "<r xmlns:n=\"u\"><n:a>1</n:a><b k=\"2\"/><c><d>3</d></c></r>", xml.as(.Xml), {"r"})
	walktest.expect_entries_built_later(t, "<!DOCTYPE r [<!ENTITY e \"x\"><!ATTLIST b d CDATA \"v\">]><r><b>&e;</b><b/><c>&e;</c></r>", xml.as(.Xml), {"r"})
	src := strings.concatenate({"<r>", strings.repeat("<b>0123456789</b>", 2000, context.temp_allocator), "</r>"}, context.temp_allocator)
	trickle := walktest.Trickle{src = transmute([]u8)src, size = 1000}
	it := records.open_stream(walktest.trickle_reader(&trickle), xml.as(.Xml), .Entries, {entries = {"r"}})
	defer records.close(&it)
	first, given := records.next(&it)
	testing.expect(t, given)
	for _ in records.next(&it) {
	}
	_, err := records.build(&it, first, context.temp_allocator)
	walktest.expect_kind(t, err, core.Document_Error_Kind.Bad_Index)
}
