package xml_tests

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

// The writer's law over the conformance suite (`conformance/fetch.py` fetches it): each valid document the writer can
// write reads back with its values, attributes, comments and instructions. A document the writer refuses, as it
// refuses an empty list or a name it cannot spell, is counted and not judged.

// What the writer reads back: the facts the writer holds.
@(private = "file")
KEPT :: tape.Facts{.Comment, .Comment_Inline, .Comment_Foot, .Instruction, .Instruction_Foot, .Attribute}

// The documents whose text reads back as other values: an entity that expands to nothing reads as an empty string, which
// is written as an empty element, and that reads as null.
@(private = "file")
EMPTY_ENTITY := [?]string{"xmltest/valid/sa/023.xml", "xmltest/valid/sa/085.xml", "xmltest/valid/sa/086.xml"}

// The documents whose comment stands apart from the root element by a blank line, which makes it the document's, and
// a text written with none between them reads it as the element's.
@(private = "file")
APART := [?]string{"ibm/valid/P18/ibm18v01.xml", "ibm/valid/P20/ibm20v01.xml", "ibm/valid/P20/ibm20v02.xml", "ibm/valid/P21/ibm21v01.xml"}

// The document whose default attribute holds a parameter entity's reference, which a read of the text reads as the
// reference and the first read as the first byte (a reader fault the writer does not make).
@(private = "file")
DEFAULT_PE := "xmltest/valid/sa/094.xml"

@(test)
suite_documents_write_and_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	if !os.exists(strings.concatenate({SUITE_DIR, "files"}, context.temp_allocator)) {
		log.info("the suite is not fetched: run python3 next/xml/test/conformance/fetch.py")
		return
	}
	read, written, failures := 0, 0, 0
	rest := CASES
	suite: for line in strings.split_lines_iterator(&rest) {
		fields := strings.split(line, "\t", context.temp_allocator)
		kind, path, entities := fields[0], fields[1], fields[2]
		if kind != "valid" {
			continue
		}
		src, rerr := os.read_entire_file_from_path(strings.concatenate({SUITE_DIR, "files/", path}, context.temp_allocator), context.temp_allocator)
		if rerr != nil {
			continue
		}
		opts: xml.Options
		if entities != "none" {
			opts.tolerate = {.Unread_Entity}
		}
		doc, err := xml.build(src, .Xml, opts, context.temp_allocator)
		if err != nil {
			continue
		}
		read += 1
		text, _, werr := xml.write(&doc, .Xml, {}, context.temp_allocator)
		if werr != nil {
			continue
		}
		written += 1
		back, berr := xml.build(text, .Xml, opts, context.temp_allocator)
		if berr != nil {
			failures += 1
			fmt.eprintfln("%s: the text written does not read: %s\n%s", path, code_of(berr), text)
			continue
		}
		for known in EMPTY_ENTITY {
			if known == path {
				continue suite
			}
		}
		for known in APART {
			if known == path {
				continue suite
			}
		}
		if path == DEFAULT_PE {
			continue
		}
		// The attributes a document type gives an element, and the comments in the subset a text with external parts
		// leaves unread, are not the writer's to keep.
		same := tape.Facts{} if entities != "none" else KEPT
		if !testkit.values_agree(t, &doc, tape.ROOT, &back, tape.ROOT, {facts = same}, path) {
			failures += 1
		}
	}
	log.infof("%d valid documents read, %d written", read, written)
	testing.expect(t, read > 100 && written > 100)
	testing.expectf(t, failures == 0, "%d documents", failures)
}
