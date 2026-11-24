// The package's entry points, and the same reads through the handle and the reads a caller that picks the format at run
// time uses.
package xml_tests

import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

// Every read through the format's handle gives what the package's own call gives.
@(test)
every_entry_point_reads_by_a_constant_spec_and_a_chosen_one :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`<?xml version="1.0"?><a x="1"><b>1</b><c>2</c><c>3</c></a>`)
	path := []tape.Step{tape.Name("a"), tape.Name("c")}
	reads, f := xml.reads(.Xml), xml.as(.Xml)
	testing.expect_value(t, xml.validate(src), nil)
	testing.expect_value(t, reads.validate(f, src, {}, context.allocator), nil)
	doc, err := xml.build(src, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	chosen, cerr := reads.build(f, src, {}, context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	testing.expect_value(t, len(chosen.nodes), len(doc.nodes))
	testing.expect_value(t, len(chosen.facts), len(doc.facts))
	for n, i in doc.nodes {
		testing.expectf(t, i < len(chosen.nodes) && chosen.nodes[i] == n, "node %d", i)
	}
	a, ferr := xml.find(src, path)
	testing.expect_value(t, ferr, nil)
	b, gerr := reads.find(f, src, path, {}, {}, context.allocator)
	testing.expect_value(t, gerr, nil)
	testing.expect_value(t, b, a)
	testing.expect_value(t, a.outcome, tape.Presence.Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), "2")
	demand, _ := xml.demand_of([][]tape.Step{path}, allocator = context.temp_allocator)
	sdoc, serr := xml.scan(src, &demand, allocator = context.temp_allocator)
	testing.expect_value(t, serr, nil)
	cdoc, derr := reads.scan(f, src, &demand, {}, {}, context.temp_allocator)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, len(cdoc.nodes), len(sdoc.nodes))
	at, p, _ := xml.answer({doc = &sdoc}, 0, 0)
	testing.expect_value(t, p, tape.Presence.Found)
	testing.expect_value(t, text_of(&sdoc, at), "2")
	at, p, _ = xml.answer({doc = &cdoc}, 0, 0)
	testing.expect_value(t, text_of(&cdoc, at), "2")
}

// A repeated name is a fault only for the build that asks to refuse it, and a path read takes no such option.
@(test)
a_repeated_name_is_refused_only_when_asked :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("<a><b>1</b><b>2</b></a>")
	_, err := xml.build(src, .Xml, {}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	_, err = xml.build(src, .Xml, {dups = .Refuse}, context.temp_allocator)
	f, refused := err.(tape.Fault)
	testing.expect_value(t, refused, true)
	testing.expect_value(t, code_of(err), "duplicate_key")
	testing.expect_value(t, f.at, 12)
	answer, ferr := xml.find(src, {tape.Name("a"), tape.Name("b")})
	testing.expect_value(t, ferr, nil)
	testing.expect_value(t, answer.outcome, tape.Presence.Found)
	demand, _ := xml.demand_of([][]tape.Step{{tape.Name("a"), tape.Name("b")}}, allocator = context.temp_allocator)
	_, serr := xml.scan(src, &demand, .Xml, {}, {dups = .Refuse}, context.temp_allocator)
	testing.expect_value(t, serr, tape.Error(tape.Bad_Option{"dups"}))
}

// The repeat refused is the first one read, which an entity read at each reference puts inside its first expansion.
@(test)
a_refused_repeat_is_the_first_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`<!DOCTYPE a [<!ENTITY e "<b/>,<b/>">]><a>&e;&e;</a>`)
	_, err := xml.build(src, .Xml, {dups = .Refuse}, context.temp_allocator)
	f, _ := err.(tape.Fault)
	testing.expect_value(t, code_of(err), "duplicate_key")
	testing.expect_value(t, f.at, 31)
}

// The options of a read: the format's own take effect, a text in pieces reads as the whole text, and another format's
// are refused.
@(test)
a_read_takes_its_options :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`<!DOCTYPE a [<!ENTITY e 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'>]><a><n>12</n><t>&e;&e;&e;&e;</t></a>`)
	doc, err := xml.build(src, .Xml, {budget = {expansion = 1 << 20}, format = xml.Xml_Options{infer = true}}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	n, _ := member_at(&doc, {"a", "n"})
	testing.expect_value(t, doc.nodes[n].kind, tape.Kind.Number)
	e := xml.validate(src, .Xml, {budget = {expansion = 100}})
	testing.expect_value(t, code_of(e), "exceeded Expansion")
	deep := transmute([]u8)string(`<a><b><c/></b></a>`)
	e = xml.validate(deep, .Xml, {budget = {depth = 2}})
	x, exceeded := e.(tape.Exceeded)
	testing.expect_value(t, exceeded, true)
	testing.expect_value(t, x.kind, tape.Budget_Kind.Depth)
	pieces := tape.Pieces{last = true}
	testing.expect_value(t, xml.validate(deep, .Xml, {pieces = &pieces}), nil)
	testing.expect_value(t, pieces.more, false)
	tape.destroy_pieces(&pieces)
	testing.expect_value(t, xml.validate(deep, .Xml, {format = tape.Cbor_Options{}}), tape.Error(tape.Bad_Option{"format"}))
	// XML reads no ill-formed UTF-8, so every read refuses that rule, and takes the rules of tokens it has none of.
	lax := xml.Options{tolerate = {.Invalid_Utf8}}
	testing.expect_value(t, xml.validate(deep, .Xml, lax), tape.Error(tape.Bad_Option{"tolerate"}))
	_, berr := xml.build(deep, .Xml, lax)
	testing.expect_value(t, berr, tape.Error(tape.Bad_Option{"tolerate"}))
	_, ferr := xml.find(deep, {xml.Name("a")}, .Xml, {}, lax)
	testing.expect_value(t, ferr, tape.Error(tape.Bad_Option{"tolerate"}))
	r := xml.records_open(deep, .Members, .Xml, lax)
	testing.expect_value(t, r.err, tape.Error(tape.Bad_Option{"tolerate"}))
	testing.expect_value(t, xml.validate(deep, .Xml, {tolerate = {.Ragged, .Bare_Quote, .Non_Finite, .Lone_Surrogate}}), nil)
}
