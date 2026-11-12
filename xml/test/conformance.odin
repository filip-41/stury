// The W3C XML Conformance Test Suite's XML 1.0 cases (`conformance/fetch.py` fetches and selects them): a valid or
// invalid case must be accepted, and its document must hold what its canonical form holds, and a case that is not well
// formed or not namespace conforming must be refused.
package xml_tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import xml ".."
import walktest "../../walktest"

@(private)
SUITE_DIR :: #directory + "conformance/"

@(private)
CASES :: #load("conformance/cases.tsv", string)

@(private)
Ledger_Entry :: struct {
	path:   string,
	reason: string,
}

@(private = "file")
UTF16 :: "a UTF-16 document, read once encodings are"
@(private = "file")
EXTERNAL_FAULT :: "the fault is in an external entity or the external subset, which stury does not read"
@(private = "file")
EXTERNAL_TEXT :: "the canonical form holds text or declarations of an external entity or the external subset, which stury does not read"
@(private = "file")
RESPELLED :: "the replacement text spells markup that its literal does not, which stury refuses as Entity_Respelled"
@(private = "file")
NMTOKENS :: "the suite marks a colon in an NMTOKENS value as not namespace conforming, which Namespaces in XML 1.0 does not say"

// Cases the walk answers differently from the suite, with the reason. A name in this list that passes fails the test.
@(private)
LEDGER := [?]Ledger_Entry {
	{"ibm/invalid/P32/ibm32i01.xml", EXTERNAL_TEXT},
	{"ibm/invalid/P32/ibm32i03.xml", EXTERNAL_TEXT},
	{"ibm/not-wf/P30/ibm30n01.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P31/ibm31n01.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P61/ibm61n01.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P62/ibm62n01.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P62/ibm62n02.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P62/ibm62n03.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P62/ibm62n04.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P62/ibm62n05.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P62/ibm62n06.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P62/ibm62n07.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P62/ibm62n08.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P63/ibm63n01.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P63/ibm63n02.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P63/ibm63n03.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P63/ibm63n04.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P63/ibm63n05.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P63/ibm63n06.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P63/ibm63n07.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P64/ibm64n01.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P64/ibm64n02.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P64/ibm64n03.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P65/ibm65n01.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P65/ibm65n02.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P77/ibm77n01.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P77/ibm77n02.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P77/ibm77n03.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P77/ibm77n04.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P78/ibm78n01.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P78/ibm78n02.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P79/ibm79n01.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/P79/ibm79n02.xml", EXTERNAL_FAULT},
	{"ibm/not-wf/p28a/ibm28an01.xml", EXTERNAL_FAULT},
	{"ibm/valid/P09/ibm09v03.xml", EXTERNAL_TEXT},
	{"ibm/valid/P09/ibm09v05.xml", EXTERNAL_TEXT},
	{"ibm/valid/P32/ibm32v01.xml", EXTERNAL_TEXT},
	{"ibm/valid/P32/ibm32v02.xml", EXTERNAL_TEXT},
	{"ibm/valid/P32/ibm32v03.xml", EXTERNAL_TEXT},
	{"ibm/valid/P32/ibm32v04.xml", EXTERNAL_TEXT},
	{"ibm/valid/P78/ibm78v01.xml", EXTERNAL_TEXT},
	{"japanese/pr-xml-little-endian.xml", UTF16},
	{"japanese/pr-xml-utf-16.xml", UTF16},
	{"japanese/weekly-little-endian.xml", UTF16},
	{"japanese/weekly-utf-16.xml", UTF16},
	{"oasis/p08pass1.xml", NMTOKENS},
	{"oasis/p09fail1.xml", EXTERNAL_FAULT},
	{"oasis/p09fail2.xml", EXTERNAL_FAULT},
	{"oasis/p30fail1.xml", EXTERNAL_FAULT},
	{"oasis/p31fail1.xml", EXTERNAL_FAULT},
	{"oasis/p61fail1.xml", EXTERNAL_FAULT},
	{"oasis/p62fail1.xml", EXTERNAL_FAULT},
	{"oasis/p62fail2.xml", EXTERNAL_FAULT},
	{"oasis/p63fail1.xml", EXTERNAL_FAULT},
	{"oasis/p63fail2.xml", EXTERNAL_FAULT},
	{"oasis/p64fail1.xml", EXTERNAL_FAULT},
	{"oasis/p64fail2.xml", EXTERNAL_FAULT},
	{"sun/invalid/utf16b.xml", UTF16},
	{"sun/invalid/utf16l.xml", UTF16},
	{"sun/not-wf/cond01.xml", EXTERNAL_FAULT},
	{"sun/not-wf/cond02.xml", EXTERNAL_FAULT},
	{"sun/not-wf/decl01.xml", EXTERNAL_FAULT},
	{"sun/not-wf/dtd07.xml", EXTERNAL_FAULT},
	{"sun/not-wf/encoding07.xml", EXTERNAL_FAULT},
	{"sun/valid/ext01.xml", EXTERNAL_TEXT},
	{"sun/valid/ext02.xml", EXTERNAL_TEXT},
	{"sun/valid/not-sa02.xml", EXTERNAL_TEXT},
	{"sun/valid/not-sa03.xml", EXTERNAL_TEXT},
	{"sun/valid/pe00.xml", EXTERNAL_TEXT},
	{"sun/valid/pe03.xml", RESPELLED},
	{"xmltest/invalid/not-sa/022.xml", EXTERNAL_TEXT},
	{"xmltest/not-wf/ext-sa/001.xml", EXTERNAL_FAULT},
	{"xmltest/not-wf/ext-sa/002.xml", EXTERNAL_FAULT},
	{"xmltest/not-wf/ext-sa/003.xml", EXTERNAL_FAULT},
	{"xmltest/not-wf/not-sa/001.xml", EXTERNAL_FAULT},
	{"xmltest/not-wf/not-sa/003.xml", EXTERNAL_FAULT},
	{"xmltest/not-wf/not-sa/004.xml", EXTERNAL_FAULT},
	{"xmltest/not-wf/not-sa/006.xml", EXTERNAL_FAULT},
	{"xmltest/not-wf/not-sa/007.xml", EXTERNAL_FAULT},
	{"xmltest/not-wf/not-sa/008.xml", EXTERNAL_FAULT},
	{"xmltest/not-wf/not-sa/009.xml", EXTERNAL_FAULT},
	{"xmltest/valid/ext-sa/001.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/002.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/003.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/004.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/005.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/006.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/007.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/008.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/009.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/011.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/012.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/013.xml", EXTERNAL_TEXT},
	{"xmltest/valid/ext-sa/014.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/003.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/004.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/005.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/006.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/007.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/008.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/009.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/011.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/012.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/013.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/014.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/015.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/016.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/017.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/018.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/019.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/020.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/021.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/023.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/024.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/025.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/026.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/028.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/029.xml", EXTERNAL_TEXT},
	{"xmltest/valid/not-sa/031.xml", EXTERNAL_TEXT},
	{"xmltest/valid/sa/024.xml", RESPELLED},
	{"xmltest/valid/sa/049.xml", UTF16},
	{"xmltest/valid/sa/050.xml", UTF16},
	{"xmltest/valid/sa/051.xml", UTF16},
	{"xmltest/valid/sa/087.xml", RESPELLED},
}

// How the walk answers a case: "" when it answers as the suite does, else what differs. A case that refers to external
// entities is read with the `Unread_Entity` tolerance, since a reader that does not read them may not refuse it.
@(private)
answer :: proc(kind, path, entities, canonical: string) -> string {
	src, err := os.read_entire_file_from_path(strings.concatenate({SUITE_DIR, "files/", path}, context.temp_allocator), context.temp_allocator)
	if err != nil {
		return fmt.tprintf("cannot read: %v", err)
	}
	opts: xml.Options
	if entities != "none" {
		opts.tolerate = {.Unread_Entity}
	}
	fault, bad := walktest.fault_in(xml.validate(src, .Xml, opts))
	refused := kind == "not-wf" || kind == "not-ns"
	switch {
	case refused && !bad:
		return "accepted"
	case !refused && bad:
		return fmt.tprintf("refused at %d: %s", fault.at, walktest.rule_code(fault))
	case refused || canonical == "":
		return ""
	}
	want, werr := os.read_entire_file_from_path(strings.concatenate({SUITE_DIR, "files/", canonical}, context.temp_allocator), context.temp_allocator)
	if werr != nil {
		return fmt.tprintf("cannot read %s: %v", canonical, werr)
	}
	got, gok := canonical_text(src, opts)
	expected, eok := canonical_text(want, {})
	switch {
	case !gok:
		return "the document does not build"
	case !eok:
		return "the canonical form does not build"
	case got != expected:
		return fmt.tprintf("canonical form differs:\n  got  %q\n  want %q", got, expected)
	}
	return ""
}

// The canonical form of what the document `src` builds holds: elements with their attributes sorted by name, and text.
// A document holds neither processing instructions nor white space between elements, so a canonical form written
// from one leaves them out, and both sides of a comparison are written by this.
@(private)
canonical_text :: proc(src: []u8, opts: xml.Options) -> (string, bool) {
	doc, err := xml.build(src, .Xml, opts)
	if err != nil {
		return "", false
	}
	defer core.destroy(&doc)
	b := strings.builder_make(context.temp_allocator)
	canonical_members(&b, &doc, core.ROOT)
	return strings.to_string(b), true
}

// The members of an element with child elements. Text that is only white space is left out, and the text between two
// elements is one run, as a document holds it.
@(private = "file")
canonical_members :: proc(b: ^strings.Builder, doc: ^core.Document, obj: core.Node_Index) {
	run := strings.builder_make(context.temp_allocator)
	flush :: proc(b, run: ^strings.Builder) {
		if strings.trim_left(strings.to_string(run^), " \t\r\n") != "" {
			escaped(b, strings.to_string(run^))
		}
		strings.builder_reset(run)
	}
	it := core.pairs(doc, obj)
	for key, val in core.pair_next(&it) {
		name := node_string(doc, key)
		if name == "#text" {
			strings.write_string(&run, node_string(doc, val))
		} else {
			flush(b, &run)
			canonical_element(b, doc, name, val)
		}
	}
	flush(b, &run)
}

@(private = "file")
canonical_element :: proc(b: ^strings.Builder, doc: ^core.Document, name: string, val: core.Node_Index) {
	Attribute :: struct {
		name, value: string,
	}
	attrs := make([dynamic]Attribute, context.temp_allocator)
	it := core.attributes_of(doc, val)
	for n, v in walktest.attribute_texts(&it) {
		append(&attrs, Attribute{n, v})
	}
	slice.sort_by(attrs[:], proc(x, y: Attribute) -> bool {return x.name < y.name})
	fmt.sbprintf(b, "<%s", name)
	for a in attrs {
		fmt.sbprintf(b, " %s=\"", a.name)
		escaped(b, a.value)
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, '>')
	switch core.kind(doc, val) {
	case .Object:
		canonical_members(b, doc, val)
	case .Null:
	case .False, .True, .Number, .Bytes, .String, .Plain, .Array, .End:
		escaped(b, node_string(doc, val))
	}
	fmt.sbprintf(b, "</%s>", name)
}

@(private = "file")
node_string :: proc(doc: ^core.Document, i: core.Node_Index) -> string {
	buf := make([]u8, max(core.text_room(doc, i), int(doc.nodes[i].n)), context.temp_allocator)
	s, _ := core.text(doc, i, buf)
	return s
}

@(private = "file")
escaped :: proc(b: ^strings.Builder, s: string) {
	for c in transmute([]u8)s {
		switch c {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case '\t':
			strings.write_string(b, "&#9;")
		case '\n':
			strings.write_string(b, "&#10;")
		case '\r':
			strings.write_string(b, "&#13;")
		case:
			strings.write_byte(b, c)
		}
	}
}

@(test)
conformance_cases :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	total, failures := 0, 0
	if !os.exists(strings.concatenate({SUITE_DIR, "files"}, context.temp_allocator)) {
		testing.fail_now(t, "the suite is not fetched: run python3 xml/test/conformance/fetch.py")
	}
	rest := CASES
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.split(line, "\t", context.temp_allocator)
		kind, path, entities, canonical := fields[0], fields[1], fields[2], fields[3]
		total += 1
		listed := false
		for l in LEDGER {
			listed ||= l.path == path
		}
		got := answer(kind, path, entities, canonical)
		if (got != "") != listed {
			failures += 1
			if listed {
				fmt.eprintfln("%s: in the ledger and passes", path)
			} else {
				fmt.eprintfln("%s %s %s: %s", kind, entities, path, got)
			}
		}
	}
	testing.expect(t, total > 1000)
	testing.expectf(t, failures == 0, "%d cases", failures)
}
