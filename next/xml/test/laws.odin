// The read laws of `testkit` over random documents and their mutations: the readers answer a scan's partial document
// as the build, every read refuses a text the build refuses, a build on threads is the build on one, and every walk
// keeps the hook protocol.
package xml_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

// Names from few enough that an element's children often repeat one, a prefixed one among them.
@(rodata, private = "file")
NAMES := [?]string{"a", "b", "c", "p:d", "e"}

@(private = "file")
put_text :: proc(b: ^strings.Builder) {
	switch rand.int_max(9) {
	case 0:
		strings.write_string(b, "x&amp;y")
	case 1:
		strings.write_string(b, "&#65;&#x42;")
	case 2:
		strings.write_string(b, "<![CDATA[<z>]]>")
	case 3:
		strings.write_string(b, "\n  ")
	case 4:
		strings.write_int(b, rand.int_max(1000))
	case 5:
		strings.write_string(b, "true")
	case 6:
		strings.write_string(b, "&e;")
	case:
		strings.write_string(b, "txét")
	}
}

@(private = "file")
put_misc :: proc(b: ^strings.Builder) {
	switch rand.int_max(3) {
	case 0:
		strings.write_string(b, "<!--c-->")
	case 1:
		strings.write_string(b, "<?pi data?>")
	case:
		strings.write_string(b, " ")
	}
}

// Appends a random element of at most `depth` levels: attributes, text, mixed content, CDATA, references, comments
// and instructions, and children that repeat names.
@(private = "file")
put_element :: proc(b: ^strings.Builder, depth: int) {
	name := NAMES[rand.int_max(len(NAMES))]
	strings.write_byte(b, '<')
	strings.write_string(b, name)
	for i in 0 ..< rand.int_max(3) {
		strings.write_string(b, ` x` if i == 0 else ` y`)
		strings.write_string(b, `="v&lt;1"` if rand.int_max(4) == 0 else `='2'`)
	}
	if rand.int_max(6) == 0 {
		strings.write_string(b, "/>")
		return
	}
	strings.write_byte(b, '>')
	for _ in 0 ..< rand.int_max(5 if depth > 0 else 2) {
		switch rand.int_max(5) {
		case 0, 1:
			put_text(b)
		case 2:
			put_misc(b)
		case:
			if depth > 0 {
				put_element(b, depth - 1)
			}
		}
	}
	strings.write_string(b, "</")
	strings.write_string(b, name)
	strings.write_byte(b, '>')
}

// A random document in the context's allocator, with a prolog, a DTD declaring `e` some of the time, and a root that
// binds the prefix `p`.
random_document :: proc() -> []u8 {
	b := strings.builder_make()
	if rand.int_max(2) == 0 {
		strings.write_string(&b, `<?xml version="1.0"?>`)
	}
	put_misc(&b)
	if rand.int_max(3) == 0 {
		strings.write_string(&b, `<!DOCTYPE r [<!ENTITY e "ent&amp;"><!ATTLIST r z CDATA "d">]>`)
	} else {
		strings.write_string(&b, `<!DOCTYPE r [<!ENTITY e "<b>in</b>">]>` if rand.int_max(3) == 0 else "")
	}
	strings.write_string(&b, `<r xmlns:p="urn:p">`)
	for _ in 0 ..< 1 + rand.int_max(4) {
		put_element(&b, 4)
	}
	strings.write_string(&b, "</r>")
	put_misc(&b)
	return b.buf[:]
}

@(private)
XML_MUTATE_ALPHABET :: "<>&;/=\"' !?-]ax"

// The readers law and the refusal law over random documents, and their mutations.
@(test)
reads_agree_on_generated_documents :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a: testkit.Agreement
	defer delete(a.shapes)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x0a1)
	infer := xml.Options{format = xml.Xml_Options{infer = true}}
	for _ in 0 ..< testkit.rounds(40) {
		src := random_document()
		defer delete(src)
		testkit.readers_agree(t, xml.reads(.Xml), xml.as(.Xml), src, {}, "generated", &a)
		testkit.readers_agree(t, xml.reads(.Xml), xml.as(.Xml), src, infer, "inferred", &a)
		for _ in 0 ..< 4 {
			bad := testkit.mutate(src, XML_MUTATE_ALPHABET)
			testkit.readers_agree(t, xml.reads(.Xml), xml.as(.Xml), bad, {}, "mutated", &a)
		}
		free_all(context.temp_allocator)
	}
	testkit.expect_agreement(t, &a, {texts = 60, refused = 60, scans = 20_000, on_path = 20_000, shapes = 30})
}

@(private = "file")
probe_walk :: proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
	at, err, _ := xml.walk(src, .Xml, opts, h, regs, testkit.probe_hook)
	return at, err
}

@(private = "file")
bare_walk :: proc(src: []u8, opts: tape.Options, h: ^testkit.Probe_Bare, regs: ^hook.Regs) -> (u64, tape.Error) {
	at, err, _ := xml.walk(src, .Xml, opts, h, regs, testkit.bare_hook)
	return at, err
}

// Texts of every kind of content: text, attributes, mixed content, CDATA, references, entities whose text holds
// markup, comments and instructions in and around the root.
@(rodata, private = "file")
PROTOCOL_TEXTS := [?]string {
	"<a/>",
	"<a>hi</a>",
	`<a x="1" y='2'>t</a>`,
	"<r><a>1</a><b/><a>2</a></r>",
	"<r>x<a/>y<!--c--><?p d?><![CDATA[z]]></r>",
	`<?xml version="1.0"?><!--c--><r xmlns:p="u"><p:a p:x="1"><b><c>deep</c></b></p:a></r><?e?>`,
	`<!DOCTYPE r [<!ENTITY e "<b>q</b>t"><!ATTLIST r z CDATA "d">]><r>&e;<c>&e;</c></r>`,
}

// Every XML walk, of a whole text and in pieces, keeps the hook protocol: actions at every token, room and level
// growth, and `Budget.steps`.
@(test)
xml_walks_keep_the_hook_protocol :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.hook_protocol(t, probe_walk, PROTOCOL_TEXTS[:])
	testkit.hook_inner_rooms(t, bare_walk, PROTOCOL_TEXTS[:])
	testkit.hook_protocol_in_pieces(t, probe_walk, PROTOCOL_TEXTS[:])
	testkit.hook_inner_rooms_in_pieces(t, bare_walk, PROTOCOL_TEXTS[:])
}

// A hook stops a walk from another thread through a flag.
@(test)
xml_walk_cancels_through_a_flag :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<r>")
	for _ in 0 ..< 200 {
		strings.write_string(&b, "<a><b>1</b><c>2</c></a>")
	}
	strings.write_string(&b, "</r>")
	testkit.hook_cancel(t, probe_walk, strings.to_string(b), 300)
}
