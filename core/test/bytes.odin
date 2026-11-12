// A document of a made-up binary format, built by hand: byte strings, a number whose span is not its digits, and facts of
// both kinds. Every core reader and both text writers read it, which no text format's documents can show yet.
package core_test

import "core:testing"
import core ".."
import write "../write"
import dsv "../../dsv"
import json "../../json"
import walktest "../../walktest"

// The bytes of the made-up format's text, laid out for `bin_document`.
//   0..4    "foob", a byte string
//   4..10   "fo", a separator, "oba": a byte string in two chunks, which `bin_text` joins
//  10..12   258 as two big-endian bytes, a number
//  12..13   the tag number 5, a `Number` fact
//  13..15   "hi", a string
//  15..17   "!t", a tag in text, a `Plain` fact whose lead is one byte
@(rodata)
BIN_SRC := [?]u8{'f', 'o', 'o', 'b', 'f', 'o', 0xff, 'o', 'b', 'a', 1, 2, 5, 'h', 'i', '!', 't'}

@(rodata)
BIN_TEXT := core.Readers {
	text        = bin_text,
	number      = bin_number,
	number_text = bin_number_text,
	binary      = true,
}

// The joined chunks: the span without its separators.
bin_text :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	n := 0
	for b in v.src[t.lo:][:t.n] {
		if b == 0xff {
			continue
		}
		if n == len(buf) {
			return "", false
		}
		buf[n] = b
		n += 1
	}
	return string(buf[:n]), true
}

bin_value :: proc(v: ^core.Token_View, t: core.Token) -> u64 {
	x: u64
	for b in v.src[t.lo:][:t.n] {
		x = x << 8 | u64(b)
	}
	return x
}

bin_number :: proc(v: ^core.Token_View, t: core.Token) -> (core.Number, bool) {
	return {bin_value(v, t), .Uint}, true
}

bin_number_text :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	x := bin_value(v, t)
	digits: [20]u8
	n := 0
	for more := true; more; more = x > 0 {
		digits[n] = '0' + u8(x % 10)
		x /= 10
		n += 1
	}
	if n > len(buf) {
		return "", false
	}
	for i in 0 ..< n {
		buf[i] = digits[n - 1 - i]
	}
	return string(buf[:n]), true
}

// The root array of one record `[bytes, joined bytes, 258, "hi", ""]`, nodes 2 to 6 of it, with the tag number on the first
// byte string and the text tag on the string.
bin_document :: proc() -> core.Document {
	nodes := make([]core.Node, 7)
	nodes[0] = {kind = .Array, n = 7, spelling = 1}
	nodes[1] = {kind = .Array, n = 6, spelling = 5}
	nodes[2] = {lo = 0, n = 4, kind = .Bytes}
	nodes[3] = {lo = 4, n = 6, kind = .Bytes, spelling = core.SPELLING_DECODE}
	nodes[4] = {lo = 10, n = 2, kind = .Number}
	nodes[5] = {lo = 13, n = 2, kind = .String}
	nodes[6] = {lo = 0, n = 0, kind = .Bytes}
	facts := make([]core.Fact, 2)
	facts[0] = {lo = 12, node = 2, n = 1, role = .Tag, kind = .Number}
	facts[1] = {lo = 15, node = 5, n = 2, role = .Tag, kind = .Plain, spelling = 1}
	doc := core.Document {
		nodes       = nodes,
		nodes_alloc = nodes,
		facts       = facts,
		facts_alloc = facts,
		allocator   = context.allocator,
	}
	doc.src = BIN_SRC[:]
	doc.readers = &BIN_TEXT
	return doc
}

// A byte string is its payload, borrowed when the token needs no joining and joined by the format's `text` when it does,
// and `doc_bytes` refuses every other kind. `text` reads a byte string as it reads a string, its payload as a string, since
// a check on the hot path of every text format's reads would cost them.
@(test)
bytes_nodes_read_as_payload :: proc(t: ^testing.T) {
	doc := bin_document()
	defer core.destroy(&doc)
	testing.expect_value(t, core.kind(&doc, 2), core.Kind.Bytes)

	plain, ok := core.doc_bytes(&doc, 2, nil)
	testing.expect(t, ok)
	testing.expect_value(t, string(plain), "foob")
	testing.expect(t, raw_data(plain) == raw_data(doc.src), "an undecoded payload is the span")

	buf: [8]u8
	joined, joined_ok := core.doc_bytes(&doc, 3, buf[:])
	testing.expect(t, joined_ok)
	testing.expect_value(t, string(joined), "fooba")
	_, short := core.doc_bytes(&doc, 3, buf[:2])
	testing.expect(t, !short, "a buffer too short for the joined payload is refused")

	empty, empty_ok := core.doc_bytes(&doc, 6, nil)
	testing.expect(t, empty_ok && len(empty) == 0)

	_, string_ok := core.doc_bytes(&doc, 5, buf[:])
	testing.expect(t, !string_ok)
	_, number_ok := core.doc_bytes(&doc, 4, buf[:])
	testing.expect(t, !number_ok)
	_, past := core.doc_bytes(&doc, 99, buf[:])
	testing.expect(t, !past)

	as_text, text_ok := core.text(&doc, 2, buf[:])
	testing.expect(t, text_ok)
	testing.expect_value(t, as_text, "foob")
	cloned, cloned_ok := core.text_clone(&doc, 3)
	defer delete(cloned)
	testing.expect(t, cloned_ok)
	testing.expect_value(t, cloned, "fooba")
	testing.expect_value(t, core.text_room(&doc, 3), 6)
}

// Byte strings are equal by payload, a joined one to a plain one that holds the same bytes, and their hash follows. A
// byte string is no string, and is ordered after every number and before every string.
@(test)
bytes_equal_by_payload :: proc(t: ^testing.T) {
	doc := bin_document()
	defer core.destroy(&doc)
	other := bin_document()
	defer core.destroy(&other)
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	src := BIN_SRC
	copy(src[:], "fooba")
	other.src = src[:]
	other.nodes[2] = {lo = 0, n = 5, kind = .Bytes}
	other.nodes[5].kind = .Bytes
	at :: proc(doc: ^core.Document, node: core.Node_Index) -> core.Value {
		return core.Node_Ref{doc, node}
	}

	testing.expect(t, !core.equal(at(&doc, 2), at(&doc, 3)), "foob is not fooba")
	testing.expect(t, core.hash(at(&doc, 2)) != core.hash(at(&doc, 3)))
	testing.expect(t, !core.equal(at(&doc, 2), at(&doc, 6)), "foob is not empty")
	testing.expect(t, core.equal(at(&doc, 3), at(&other, 2)), "a joined payload equals a plain one of the same bytes")
	testing.expect_value(t, core.hash(at(&doc, 3)), core.hash(at(&other, 2)))
	testing.expect(t, !core.equal(at(&doc, 5), at(&other, 5)), "a string is no byte string of its bytes")
	testing.expect_value(t, core.compare(at(&doc, 2), at(&doc, 3)), -1)
	testing.expect_value(t, core.compare(at(&doc, 4), at(&doc, 6)), -1)
	testing.expect_value(t, core.compare(at(&doc, 2), at(&doc, 5)), -1)
}

// A number whose span is not its digits is equal to the same number in any format, and hashed as it is, and its built
// value is that number.
@(test)
binary_numbers_equal_by_value :: proc(t: ^testing.T) {
	doc := bin_document()
	defer core.destroy(&doc)
	json_doc, err := json.build(transmute([]u8)string(`[258,259,258.0]`), .Json)
	defer core.destroy(&json_doc)
	walktest.expect_nil(t, err)
	number := core.Value(core.Node_Ref{&doc, 4})
	testing.expect(t, core.equal(number, core.Node_Ref{&json_doc, 1}))
	testing.expect_value(t, core.hash(number), core.hash(core.Node_Ref{&json_doc, 1}))
	testing.expect(t, !core.equal(number, core.Node_Ref{&json_doc, 2}))
	testing.expect(t, core.equal(number, core.Node_Ref{&json_doc, 3}))
	testing.expect_value(t, core.compare(number, core.Node_Ref{&json_doc, 2}), -1)

	room: [core.HEX_ROOM]u8
	f, digits, ok := core.double_of(number, room[:])
	testing.expect(t, ok)
	testing.expect_value(t, f, 258)
	testing.expect_value(t, digits, "258")
	_, none, _ := core.double_of(number)
	testing.expect_value(t, none, "")
	built, is_double := core.built_value(core.Node_Ref{&doc, 4}).(f64)
	testing.expect(t, is_double)
	testing.expect_value(t, built, 258)
	testing.expect(t, core.equal(number, built))
}

// A built value holds a byte string as the base64 text a text format writes, and the value writer writes a byte string
// node as the document writer does.
@(test)
byte_string_builds_and_writes_as_base64 :: proc(t: ^testing.T) {
	doc := bin_document()
	defer core.destroy(&doc)
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator

	plain, plain_is_text := core.built_value(core.Node_Ref{&doc, 2}).(string)
	testing.expect(t, plain_is_text)
	testing.expect_value(t, plain, "Zm9vYg==")
	joined, joined_is_text := core.built_value(core.Node_Ref{&doc, 3}).(string)
	testing.expect(t, joined_is_text)
	testing.expect_value(t, joined, "Zm9vYmE=")
	empty, empty_is_text := core.built_value(core.Node_Ref{&doc, 6}).(string)
	testing.expect(t, empty_is_text)
	testing.expect_value(t, empty, "")

	for want, i in ([?]string{`"Zm9vYg=="`, `"Zm9vYmE="`}) {
		text, err := write.write_value(core.Node_Ref{&doc, core.Node_Index(2 + i)}, json.as(.Json))
		walktest.expect_nil(t, err)
		testing.expect_value(t, string(text), want)
	}
}

// A number whose span is not its digits is read by the format's `number` and spelled by its `number_text`, which a format
// whose span is the text leaves nil.
@(test)
number_text_spells_a_binary_number :: proc(t: ^testing.T) {
	doc := bin_document()
	defer core.destroy(&doc)
	buf: [8]u8
	s, ok := core.doc_number_text(&doc, 4, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "258")
	_, short := core.doc_number_text(&doc, 4, buf[:2])
	testing.expect(t, !short)
	_, not_number := core.doc_number_text(&doc, 2, buf[:])
	testing.expect(t, !not_number)

	n, number_ok := core.number(&doc, 4)
	testing.expect(t, number_ok)
	testing.expect_value(t, n.bits, 258)

	json_doc, err := json.build(transmute([]u8)string(`[12.50]`), .Json)
	defer core.destroy(&json_doc)
	walktest.expect_nil(t, err)
	span, span_ok := core.doc_number_text(&json_doc, 1, buf[:])
	testing.expect(t, span_ok)
	testing.expect_value(t, span, "12.50")
}

// A fact keeps the kind of the token it came from, so a tag number is a number to read and a tag text is a body to slice.
@(test)
facts_keep_their_token_kind :: proc(t: ^testing.T) {
	doc := bin_document()
	defer core.destroy(&doc)

	tag, ok := core.fact_value(&doc, 2, .Tag)
	testing.expect(t, ok)
	testing.expect(t, tag.numeric)
	testing.expect_value(t, len(tag.text), 1)
	number, number_ok := core.fact_number(&doc, core.all_facts(&doc, 2)[0])
	testing.expect(t, number_ok)
	testing.expect_value(t, number.bits, 5)

	text, text_ok := core.fact_value(&doc, 5, .Tag)
	testing.expect(t, text_ok)
	testing.expect(t, !text.numeric)
	testing.expect_value(t, text.text, "t")
	_, text_is_number := core.fact_number(&doc, core.all_facts(&doc, 5)[0])
	testing.expect(t, !text_is_number)
}

// A number of a binary format whose spelling names a number kind is still spelled by the format's `number_text`, not
// by respelling its span as decimal text, and the value writer spells it so too.
@(test)
json_writes_a_binary_number_with_a_kind :: proc(t: ^testing.T) {
	doc := bin_document()
	defer core.destroy(&doc)
	defer free_all(context.temp_allocator)
	doc.nodes[4].spelling = core.NUMBER_DECIMAL

	text, _, err := core.write(&doc, {}, json.as(.Json))
	defer delete(text)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), `[["Zm9vYg==","Zm9vYmE=",258,"hi",""]]`)

	value, value_err := write.write_value(core.Node_Ref{&doc, core.ROOT}, json.as(.Json), {}, context.temp_allocator)
	walktest.expect_nil(t, value_err)
	testing.expect_value(t, string(value), string(text))
}

// A `Plain` node its format resolves to a number is spelled by `number_text` as a number node is, and a number with no
// digits, an infinity or a NaN, is refused by the JSON writer as non-finite.
@(test)
resolved_numbers_read_through_number_text :: proc(t: ^testing.T) {
	doc := bin_document()
	defer core.destroy(&doc)
	doc.nodes[4].kind = .Plain
	readers := BIN_TEXT
	readers.resolve = proc(doc: ^core.Document, i: core.Node_Index) -> core.Kind {
		return .Number
	}
	readers.resolves = proc "contextless" (as: core.As) -> bool {
		return true
	}
	doc.readers = &readers

	buf: [8]u8
	digits, ok := core.doc_number_text(&doc, 4, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, digits, "258")
	text, _, err := core.write(&doc, {}, json.as(.Json))
	defer delete(text)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), `[["Zm9vYg==","Zm9vYmE=",258,"hi",""]]`)

	readers.number_text = proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (string, bool) {
		return "", true
	}
	none, _, refusal := core.write(&doc, {}, json.as(.Json))
	defer delete(none)
	walktest.expect_kind(t, refusal, core.Typed_Error_Kind.Non_Finite)
}

// JSON and CSV spell a byte string as RFC 4648 base64, a binary number as its digits, and count the tags they drop.
@(test)
text_formats_write_bytes_as_base64 :: proc(t: ^testing.T) {
	doc := bin_document()
	defer core.destroy(&doc)

	text, dropped, err := core.write(&doc, {}, json.as(.Json))
	defer delete(text)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), `[["Zm9vYg==","Zm9vYmE=",258,"hi",""]]`)
	testing.expect_value(t, dropped, 2)

	table, table_dropped, table_err := core.write(&doc, {}, dsv.as(.Csv))
	defer delete(table)
	walktest.expect_nil(t, table_err)
	testing.expect_value(t, string(table), "Zm9vYg==,Zm9vYmE=,258,hi,\"\"\n")
	testing.expect_value(t, table_dropped, 2)

	// The text a write made reads back as the strings and the number it spells.
	back, back_err := json.build(text, .Json)
	defer core.destroy(&back)
	walktest.expect_nil(t, back_err)
	s, ok := core.text(&back, 2, nil)
	testing.expect(t, ok)
	testing.expect_value(t, s, "Zm9vYg==")
}
