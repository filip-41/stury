// Reads of an XML text in pieces, each window starting at the read's `keep`, against reads of the whole text.
package xml_tests

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

@(private = "file")
piece_paths :: proc() -> [][]xml.Step {
	paths := make([dynamic][]xml.Step, context.temp_allocator)
	add :: proc(paths: ^[dynamic][]xml.Step, steps: ..xml.Step) {
		append(paths, slice.clone(steps, context.temp_allocator))
	}
	add(&paths)
	add(&paths, xml.Name("r"))
	add(&paths, xml.Name("r"), xml.Name("a"))
	add(&paths, xml.Name("r"), xml.Name("b"), xml.Index(-1))
	add(&paths, xml.Name("r"), xml.All{}, xml.Name("c"))
	add(&paths, xml.Name("r"), xml.Name("p:d"), xml.Name("#text"))
	add(&paths, xml.Name("r"), xml.All{})
	return paths[:]
}

// Texts of every construct a window may cut: the declaration, the DTD with entities and defaults, comments and
// instructions around and inside elements, CDATA, references, namespaces, attributes with `>` in their values, and
// faults in each.
@(rodata, private = "file")
PIECE_TEXTS := [?]string {
	"",
	"<r/>",
	"<r>t</r>",
	"\xef\xbb\xbf<r a='1'>x</r>",
	`<?xml version="1.0" encoding="UTF-8"?><r><a>1</a><b x=">">2</b><a>3</a></r>`,
	"<!--lead--><?p d?>\n\n<!--own-->\n<r>\n <a>1</a> <!--in-->\n <b/><!--foot-->\n</r><!--tail-->\n<?t?>",
	"<r>x<a/>y<!--c--><?p d?><![CDATA[z]]></r>",
	"<r><![CDATA[a]]b]]><a><![CDATA[]]></a>&amp;&#65;&#x42;</r>",
	`<r xmlns="u" xmlns:p="urn:p"><p:d p:x="1">t</p:d><a xmlns:p="v"><p:d>w</p:d></a></r>`,
	`<!DOCTYPE r [<!ENTITY e "ent&amp;"><!ATTLIST r z CDATA "d"><!ATTLIST a k CDATA "]>">]><r><a>&e;</a></r>`,
	`<!DOCTYPE r [<!-- ] --><?pi ]?><!ENTITY e "<b>in</b>t">]><r>&e;<c>&e;</c></r>`,
	`<!DOCTYPE r SYSTEM "r.dtd"><r/>`,
	"<r><a>1</a><b>2</b><b>3</b><c><d/></c></r>  ",
	"<r>\r\n<a>\r</a></r>",
	"<r><a>1</a>",
	"<r><a>1</b></r>",
	"<r><!-- a -- b --></r>",
	"<r>a]]>b</r>",
	"<r a='1' a='2'/>",
	"<r/><r/>",
	"<!DOCTYPE r [<!ENTITY e 'x'>]><r>&f;</r>",
	"<r>&e;</r>",
	"<?xml version='1.0'?><!DOCTYPE",
	"<?xml version='1.0\" ?>\r\n<r/>\r\n<!-- c -->",
	"<r><a",
	"<r>x</r><!--",
}

// Every text under the defaults, inference and a step budget, read in pieces: the same verdict and fault, the same
// document, answers and scans as the whole text, at every cut and window size.
@(test)
pieces_agree_with_whole_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	options := [?]tape.Options{{}, {format = xml.Xml_Options{infer = true}}, {budget = {steps = 3}}, {budget = {depth = 2}}}
	for text in PIECE_TEXTS {
		for opts in options {
			if !testkit.agree_in_pieces(t, xml.reads(.Xml), xml.as(.Xml), transmute([]u8)text, opts, piece_paths(), text) {
				return
			}
		}
	}
}

// Random documents and their mutations, read in pieces at a sample of cuts and every window size up to a few dozen.
@(test)
pieces_agree_on_generated_documents :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x0a5)
	for _ in 0 ..< testkit.rounds(12) {
		src := random_document()
		defer delete(src)
		texts := [2][]u8{src, mutated(src)}
		defer delete(texts[1])
		for text in texts {
			name := fmt.tprintf("generated %q", text)
			for k in 0 ..< 6 {
				cuts := [1]int{rand.int_max(len(text) + 1)}
				_ = k
				if !testkit.pieces_agree(t, xml.reads(.Xml), xml.as(.Xml), text, {}, cuts[:], piece_paths(), name, framing = .Concatenated) {
					return
				}
			}
			for size in ([]int{1, 2, 3, 7, 16, 61}) {
				if !testkit.pieces_agree(t, xml.reads(.Xml), xml.as(.Xml), text, {}, testkit.cuts_by(len(text), size), piece_paths(), name, framing = .Concatenated) {
					return
				}
			}
		}
	}
}

// A sample of the W3C suite's documents, read in pieces at a few cuts and window sizes. Without the fetched suite the
// test reads nothing and passes.
@(test)
pieces_agree_on_the_conformance_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x0a7)
	rest := CASES
	for line in strings.split_lines_iterator(&rest) {
		if !testkit.sampled(8) {
			continue
		}
		path := strings.split(line, "\t", context.temp_allocator)[1]
		data, err := os.read_entire_file_from_path(strings.concatenate({SUITE_DIR, "files/", path}, context.temp_allocator), context.temp_allocator)
		if err != nil {
			return
		}
		step := max(1, len(data) / 5)
		for at := 0; at <= len(data); at += step {
			cuts := [1]int{at}
			if !testkit.pieces_agree(t, xml.reads(.Xml), xml.as(.Xml), data, {}, cuts[:], piece_paths(), path, framing = .Concatenated) {
				return
			}
		}
		for size in ([]int{1, 5, 29}) {
			if !testkit.pieces_agree(t, xml.reads(.Xml), xml.as(.Xml), data, {}, testkit.cuts_by(len(data), size), piece_paths(), path, framing = .Concatenated) {
				return
			}
		}
	}
}
