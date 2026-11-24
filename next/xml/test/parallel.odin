// Builds of XML texts on the threads of a runner against the build on one thread.
package xml_tests

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:host"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

// Content whose bytes a cut may fall in so that the guessed seam after it is wrong: end tags inside comments, CDATA
// sections, instructions and attribute values that hold `>` and `/>`.
@(rodata, private = "file")
SEAM_MISC := [?]string {
	"<!-- </a> -->",
	"<![CDATA[</b> ]]]>",
	"<?pi </c>?>",
	" t&amp;&lt;/q>",
	"\n  ",
	"x",
}

// An element under `depth` levels at most: attributes with `>` in their values, a namespace declared and used below,
// a foot comment in an element with no child, and the content of `SEAM_MISC`.
@(private = "file")
seam_element :: proc(b: ^strings.Builder, depth: int) {
	names := [?]string{"a", "b", "p:c", "d"}
	name := names[rand.int_max(len(names))]
	fmt.sbprintf(b, "<%s", name)
	switch rand.int_max(5) {
	case 0:
		strings.write_string(b, ` k="a>b" j='/>'`)
	case 1:
		strings.write_string(b, ` xmlns:p="urn:q" p:k="1"`)
	case 2:
		strings.write_string(b, ` xmlns="urn:d"`)
	}
	switch rand.int_max(6) {
	case 0:
		strings.write_string(b, "/>")
		return
	case 1:
		fmt.sbprintf(b, "><!--foot--></%s>", name)
		return
	}
	strings.write_byte(b, '>')
	for _ in 0 ..< rand.int_max(4 if depth > 0 else 2) {
		if depth > 0 && rand.int_max(2) == 0 {
			seam_element(b, depth - 1)
		} else {
			strings.write_string(b, SEAM_MISC[rand.int_max(len(SEAM_MISC))])
		}
	}
	fmt.sbprintf(b, "</%s>", name)
}

// A document of `records` elements under a root that binds the prefix `p`, after a prolog of a declaration, comments
// and an instruction.
@(private = "file")
seam_document :: proc(records: int) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	if rand.int_max(2) == 0 {
		strings.write_string(&b, "\xef\xbb\xbf<?xml version='1.0'?>")
	}
	strings.write_string(&b, "<!-- </r> --><?go </r>?>\n<r xmlns:p='urn:p'>")
	for _ in 0 ..< records {
		seam_element(&b, 4)
		strings.write_string(&b, SEAM_MISC[rand.int_max(len(SEAM_MISC))])
	}
	strings.write_string(&b, "</r><!--tail-->\n")
	return b.buf[:]
}

// The threads of serial runners that cut a text of `n` bytes into chunks of many sizes, down to a byte.
@(private = "file")
thread_counts :: proc(n: int) -> []int {
	counts := make([dynamic]int, context.temp_allocator)
	for k := 1; 4 * (k + 1) <= n && k < 512; k += 1 + k / 8 {
		append(&counts, k)
	}
	return counts[:]
}

// Random documents, their mutations and the texts of the other XML tests, built in parts at many chunk sizes under the
// policies for repeated names, a depth budget and inference.
@(test)
parts_build_what_one_thread_builds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x8a7)
	builds, valid := 0, 0
	for round in 0 ..< testkit.rounds(24) {
		src := seam_document(2 + rand.int_max(12)) if round % 3 != 2 else random_document()
		texts := [2][]u8{src, mutated(src)}
		defer if round % 3 == 2 {
			delete(src)
		}
		defer delete(texts[1])
		for text, i in texts {
			opts: tape.Options
			switch rand.int_max(5) {
			case 0:
				policies := [?]tape.Duplicates{.Refuse, .First, .Last, .All}
				opts.dups = policies[rand.int_max(len(policies))]
			case 1:
				opts.budget.depth = u32(1 + rand.int_max(5))
			case 2:
				opts.format = xml.Xml_Options{infer = true}
			case 3:
				opts.budget.nodes = u32(rand.int_max(200))
			}
			for threads in thread_counts(len(text)) {
				r := testkit.serial_runner(threads)
				builds += 1
				ok, built := testkit.threads_agree(t, xml.reads(.Xml), xml.as(.Xml), text, opts, &r, fmt.tprintf("round %d text %d", round, i))
				valid += int(built)
				if !ok {
					log.infof("%q", string(text))
					return
				}
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, builds > 1000 && valid > builds / 4, "%d builds, %d of a valid text", builds, valid)
}

// The texts read in pieces, which hold every construct and fault of a whole text, at every chunk size.
@(test)
parts_build_the_piece_texts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	texts := [?]string {
		"<r><a>1</a><b x='>'>2</b><a>3</a></r>",
		"<r>\n <a>1</a> <!--in-->\n <b/><!--foot-->\n</r><!--tail-->",
		"<r><k><!--c--></k><k>t</k></r>",
		`<r xmlns="u" xmlns:p="urn:p"><p:d p:x="1">t</p:d><a xmlns:p="v"><p:d>w</p:d></a></r>`,
		"<r><a>1</a><b>2</b></c></r>",
		"<r><a>1</a><b>2</b>",
		"<r><a>1</a><b>&e;</b></r>",
		"<r><a>1</a></r><r/>",
		"<!DOCTYPE r [<!ENTITY e 'x'>]><r><a>&e;</a><b/></r>",
	}
	for text in texts {
		src := transmute([]u8)text
		for threads in thread_counts(len(src)) {
			r := testkit.serial_runner(threads)
			if ok, _ := testkit.threads_agree(t, xml.reads(.Xml), xml.as(.Xml), src, {}, &r, text); !ok {
				return
			}
		}
	}
}

// A build on a pool's threads agrees with the build on one thread and calls the read's allocator on the calling thread
// only, under memory budgets from far below what the text needs to far above it.
@(test)
parts_allocate_on_the_calling_thread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xa11d)
	pool: host.Pool
	host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)
	c: testkit.Caller_Only
	only := testkit.caller_only(&c, context.allocator)
	src := seam_document(400)
	if ok, _ := testkit.threads_agree(t, xml.reads(.Xml), xml.as(.Xml), src, {}, &pool.runner, "pool"); !ok {
		return
	}
	doc, err := xml.build(src, .Xml, {runner = &pool.runner}, only)
	testing.expectf(t, err == nil && len(doc.nodes) > 400, "%v %d", err, len(doc.nodes))
	tape.destroy(&doc)
	for memory in ([]u64{1, 4096, u64(len(src)), u64(len(src)) * 4, u64(len(src)) * 64}) {
		if !testkit.threads_fit(t, xml.reads(.Xml), xml.as(.Xml), src, {budget = {memory = memory}}, &pool.runner, "memory") {
			return
		}
	}
	testing.expect_value(t, c.strays, 0)
	free_all(context.temp_allocator)
}
