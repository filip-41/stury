// The rules a CBOR walk judges: the malformed items of RFC 8949 Appendix F, the encoding rules of sections 4.1 and 4.2,
// the limits on a hostile item, and the keys a map may have.
package cbor_tests

import "core:strings"
import "core:testing"
import core "../../core"
import "../../core/records"
import walktest "../../walktest"
import cbor ".."
import stury_json "../../json"

@(private)
Case :: struct {
	hex:    string,
	detail: cbor.Detail, // `.None` accepts any fault
}

@(private)
expect_refused :: proc(t: ^testing.T, c: Case, spec := cbor.Spec.Cbor) {
	fault, bad := walktest.fault_of(cbor.validate(hex(c.hex), spec)).?
	if !testing.expectf(t, bad, "%s is read", c.hex) {
		return
	}
	if c.detail != .None {
		testing.expectf(t, cbor.Detail(fault.detail) == c.detail, "%s: want %v, got %v", c.hex, c.detail, cbor.Detail(fault.detail))
	}
}

@(private)
expect_read :: proc(t: ^testing.T, text: string, spec := cbor.Spec.Cbor, opts := cbor.Options{}) {
	fault, bad := walktest.fault_of(cbor.validate(hex(text), spec, opts)).?
	testing.expectf(t, !bad, "%s: %v", text, fault)
}

// Appendix F: items that are not well-formed.
@(private)
MALFORMED := [?]Case {
	// the head or its argument is cut off
	{"18", .None}, {"19", .None}, {"1a", .None}, {"1b", .None}, {"19 01", .None}, {"1a 01 02 03", .None},
	{"38", .None}, {"58", .None}, {"78", .None}, {"98", .None}, {"b8", .None}, {"d8", .None}, {"f8", .None},
	{"f9 00", .None}, {"fa 00 00 00", .None}, {"fb 00 00 00 00 00 00 00", .None},
	// a string shorter than its length
	{"41", .None}, {"61", .None}, {"5a ff ff ff ff 00", .None}, {"7b 00 00 00 00 00 00 00 05 61", .None},
	// containers missing items
	{"81", .None}, {"82 01", .None}, {"a1", .None}, {"a1 01", .None}, {"a2 01 02 03", .None}, {"c0", .None},
	{"9f", .None}, {"9f 01", .None}, {"bf", .None}, {"bf 01 02", .None}, {"5f", .None}, {"5f 41 01", .None},
	{"7f", .None}, {"7f 61 61", .None},
	// reserved additional information
	{"1c", .Reserved_Info}, {"1d", .Reserved_Info}, {"1e", .Reserved_Info}, {"3c", .Reserved_Info},
	{"5c", .Reserved_Info}, {"7d", .Reserved_Info}, {"9e", .Reserved_Info}, {"bc", .Reserved_Info},
	{"dc", .Reserved_Info}, {"fc", .Reserved_Info}, {"fd", .Reserved_Info}, {"fe", .Reserved_Info},
	// an indefinite length where the major type has none
	{"1f", .Reserved_Info}, {"3f", .Reserved_Info}, {"df", .Reserved_Info},
	// the two-byte simple value below 32
	{"f8 00", .Bad_Simple}, {"f8 01", .Bad_Simple}, {"f8 18", .Bad_Simple}, {"f8 1f", .Bad_Simple},
	// a break with nothing to break
	{"ff", .Bad_Break}, {"82 01 ff", .Bad_Break}, {"a1 ff", .None}, {"c0 ff", .None},
	{"bf 01 ff", .Bad_Break}, {"9f ff ff", .None},
	// chunks of the wrong type, nested chunks
	{"5f 61 61 ff", .Bad_Chunk}, {"7f 41 61 ff", .Bad_Chunk}, {"5f 5f 41 01 ff ff", .Bad_Chunk},
	{"7f 7f 61 61 ff ff", .Bad_Chunk}, {"5f 01 ff", .Bad_Chunk}, {"5f 5f ff ff", .Bad_Chunk},
	// bytes after the item
	{"00 00", .Trailing}, {"82 01 02 03", .Trailing}, {"", .No_Item},
}

@(test)
malformed_items_are_refused :: proc(t: ^testing.T) {
	for c in MALFORMED {
		expect_refused(t, c)
	}
}

// Well-formed items that look like malformed ones.
@(test)
well_formed_edges_are_read :: proc(t: ^testing.T) {
	for text in ([?]string {
			"80", "a0", "40", "60", "5f ff", "7f ff", "9f ff", "bf ff", "5f 40 ff", "7f 60 ff", "c0 74 323031332d30332d32315432303a30343a30305a",
			"d9 d9f7 01", "d9 d9f7 d9 d9f7 01", "f8 20", "f8 ff", "f4", "f5", "f6", "f7", "f0", "e0",
			"bf 41 01 02 ff", "9f 9f ff 9f 01 ff ff",
		}) {
		expect_read(t, text)
	}
}

// Section 4.1: preferred serialization.
@(test)
preferred_serialization_is_judged :: proc(t: ^testing.T) {
	preferred := cbor.Spec.Preferred
	refused := [?]Case {
		{"18 00", .Not_Preferred}, {"18 17", .Not_Preferred}, {"19 00 ff", .Not_Preferred}, {"1a 00 00 ff ff", .Not_Preferred},
		{"1b 00 00 00 00 ff ff ff ff", .Not_Preferred}, {"38 00", .Not_Preferred}, {"58 01 00", .Not_Preferred},
		{"98 01 00", .Not_Preferred}, {"b8 00", .Not_Preferred}, {"d8 12 01", .Not_Preferred},
		// a float a narrower float holds exactly
		{"fa 3c 00 00 00", .Not_Preferred}, {"fb 3f f0 00 00 00 00 00 00", .Not_Preferred},
		{"fb 3f f8 00 00 00 00 00 00", .Not_Preferred}, {"fa 7f c0 00 00", .None},
		// an indefinite length
		{"9f 01 ff", .Not_Preferred}, {"bf ff", .Not_Preferred}, {"5f 41 01 ff", .Not_Preferred}, {"7f 61 61 ff", .Not_Preferred},
		// a bignum that fits an integer
		{"c2 41 01", .Not_Preferred}, {"c2 40", .Not_Preferred}, {"c3 41 01", .Not_Preferred},
		{"c2 49 00 01 00 00 00 00 00 00 00", .Not_Preferred},
	}
	for c in refused {
		expect_refused(t, c, preferred)
	}
	for text in ([?]string {
			"00", "17", "18 18", "19 01 00", "1a 00 01 00 00", "1b 00 00 00 01 00 00 00 00", "20", "38 18", "f9 3c 00", "fa 47 c3 50 00",
			"fb 3f f1 99 99 99 99 99 9a", "f9 7e 00", "f9 7c 00", "f9 fc 00", "c2 49 01 00 00 00 00 00 00 00 00",
			"c3 49 01 00 00 00 00 00 00 00 00", "82 01 02", "a1 01 02", "40", "d9 d9f7 01",
		}) {
		expect_read(t, text, preferred)
	}
}

// Section 4.2.1 and 4.2.3: map key order, distinct keys and the one NaN.
@(test)
deterministic_encoding_is_judged :: proc(t: ^testing.T) {
	deterministic := cbor.Spec.Deterministic
	length_first := cbor.Spec.Length_First
	refused := [?]Case {
		{"a2 01 02 00 03", .Key_Order}, {"a2 00 01 00 02", .Key_Order}, {"a2 61 62 01 61 61 02", .Key_Order},
		{"a2 61 61 01 61 61 02", .Key_Order}, {"a2 18 18 01 0a 02", .Key_Order},
		{"f9 7e 01", .Bad_Nan}, {"fa 7f c0 00 00", .None}, {"fb 7f f8 00 00 00 00 00 01", .None},
	}
	for c in refused {
		expect_refused(t, c, deterministic)
	}
	for text in ([?]string {
			"a2 00 01 01 02", "a2 0a 01 18 18 02", "a2 61 61 01 61 62 02", "a2 60 01 61 61 02", "a2 20 01 38 63 02", "a2 18 18 00 60 00",
			"f9 7e 00", "a0", "a1 61 61 01",
		}) {
		expect_read(t, text, deterministic)
	}
	// Bytewise order of the encoded keys differs from length-first order.
	expect_read(t, "a2 18 18 00 60 00", deterministic)
	expect_refused(t, {"a2 18 18 00 60 00", .Key_Order}, length_first)
	expect_read(t, "a2 60 00 18 18 00", length_first)
	expect_read(t, "a2 61 61 00 62 61 61 01", length_first)
}

// A count that the bytes left cannot hold is refused at its head, whatever the memory it would ask for.
@(test)
counts_larger_than_the_text_are_refused :: proc(t: ^testing.T) {
	cases := [?]Case {
		{"9b ff ff ff ff ff ff ff ff", .Count_Too_Large}, {"bb 7f ff ff ff ff ff ff ff", .Count_Too_Large},
		{"9a ff ff ff ff", .Count_Too_Large}, {"5b ff ff ff ff ff ff ff ff", .None},
		{"7a 00 10 00 00 61", .None}, {"83 01 02", .Count_Too_Large},
	}
	for c in cases {
		expect_refused(t, c)
		_, err := cbor.build(hex(c.hex), .Cbor)
		testing.expectf(t, err != nil, "%s builds", c.hex)
	}
}

// Nesting is capped, and a tag counts as a level.
@(test)
nesting_is_limited :: proc(t: ^testing.T) {
	nest :: proc(prefix: byte, depth: int) -> []u8 {
		b := make([]u8, depth + 1, context.temp_allocator)
		for i in 0 ..< depth {
			b[i] = prefix
		}
		b[depth] = 0
		return b
	}
	_, bad := walktest.fault_of(cbor.validate(nest(0x81, 1000), .Cbor)).?
	testing.expect(t, !bad)
	fault, deep := walktest.fault_of(cbor.validate(nest(0x81, 5000), .Cbor)).?
	testing.expect(t, deep)
	testing.expect_value(t, fault.kind, core.Fault_Kind.Too_Deep)
	fault, deep = walktest.fault_of(cbor.validate(nest(0x81, 20), .Cbor, {max_depth = 10})).?
	testing.expect(t, deep)
	testing.expect_value(t, fault.kind, core.Fault_Kind.Too_Deep)
	_, bad = walktest.fault_of(cbor.validate(nest(0x81, 9), .Cbor, {max_depth = 10})).?
	testing.expect(t, !bad)

	chain := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< 2000 {
		append(&chain, 0xd9, 0xd9, 0xf7)
	}
	append(&chain, 0)
	fault, deep = walktest.fault_of(cbor.validate(chain[:], .Cbor)).?
	testing.expect(t, deep)
	testing.expect_value(t, fault.kind, core.Fault_Kind.Too_Deep)

	maps := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< 3000 {
		append(&maps, 0xa1, 0x00)
	}
	append(&maps, 0)
	fault, deep = walktest.fault_of(cbor.validate(maps[:], .Cbor)).?
	testing.expect_value(t, fault.kind, core.Fault_Kind.Too_Deep)
}

// A map key is an integer, a text string or a byte string. Any other key has no spelling a path or JSON can use.
@(test)
keys_are_scalars :: proc(t: ^testing.T) {
	cases := [?]Case {
		{"a1 80 01", .Bad_Key}, {"a1 a0 01", .Bad_Key}, {"a1 f5 01", .Bad_Key}, {"a1 f6 01", .Bad_Key},
		{"a1 f9 3c 00 01", .Bad_Key}, {"a1 c1 01 02", .Bad_Key}, {"a1 d9 d9f7 01 02", .Bad_Key},
	}
	for c in cases {
		expect_refused(t, c)
	}
	for text in ([?]string {"a1 01 02", "a1 20 02", "a1 41 01 02", "a1 61 61 02", "a1 5f 41 01 ff 02"}) {
		expect_read(t, text)
	}
}

// Section 3.2.2 and RFC 3629: text is UTF-8, unless the caller tolerates it.
@(test)
text_must_be_utf8 :: proc(t: ^testing.T) {
	for c in ([?]Case {{"62 c3 28", .Invalid_Utf8}, {"61 80", .Invalid_Utf8}, {"63 ed a0 80", .Invalid_Utf8}, {"62 c0 80", .Invalid_Utf8}, {"7f 61 c3 61 a9 ff", .Invalid_Utf8}}) {
		expect_refused(t, c)
	}
	expect_read(t, "62 c3 28", opts = {tolerate = {.Invalid_Utf8}})
	doc, err := cbor.build(hex("62 c3 28"), .Cbor, {tolerate = {.Invalid_Utf8}})
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	buf: [16]u8
	s, _ := core.text(&doc, core.ROOT, buf[:])
	testing.expect_value(t, s, "�(")
	// A byte string holds any bytes.
	expect_read(t, "42 c3 28")
}

// The chunks of an indefinite string join in order.
@(test)
chunks_join :: proc(t: ^testing.T) {
	doc, err := cbor.build(hex("7f 62 68 69 63 e2 82 ac ff"), .Cbor)
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	buf: [16]u8
	s, _ := core.text(&doc, core.ROOT, buf[:])
	testing.expect_value(t, s, "hi€")
	doc2, _ := cbor.build(hex("5f 42 01 02 40 43 03 04 05 ff"), .Cbor)
	defer core.destroy(&doc2)
	p, ok := core.doc_bytes(&doc2, core.ROOT, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(p), 5)
	testing.expect_value(t, p[4], 5)
}

// A step by name reaches an integer key by its decimal digits.
@(test)
paths_reach_integer_keys :: proc(t: ^testing.T) {
	src := hex("a2 01 61 78 02 61 79")
	doc, answer, err := cbor.find(src, .Cbor, core.Path{steps = {core.Name("1")}})
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	testing.expect_value(t, answer.outcome, core.Presence.Found)
	buf: [8]u8
	s, _ := core.text(&doc, answer.node, buf[:])
	testing.expect_value(t, s, "x")
	doc2, answer2, _ := cbor.find(src, .Cbor, core.Path{steps = {core.Name("3")}})
	defer core.destroy(&doc2)
	testing.expect_value(t, answer2.outcome, core.Presence.Missing)
	// A text key that spells the same digits is the same key.
	doc3, answer3, _ := cbor.find(hex("a1 61 31 05"), .Cbor, core.Path{steps = {core.Name("1")}})
	defer core.destroy(&doc3)
	testing.expect_value(t, answer3.outcome, core.Presence.Found)
}

// The text of a number that no 64-bit value holds.
@(test)
wide_numbers_have_text :: proc(t: ^testing.T) {
	Row :: struct {
		hex:  string,
		want: string,
	}
	rows := [?]Row {
		{"c2 49 01 00 00 00 00 00 00 00 00", "18446744073709551616"},
		{"c3 49 01 00 00 00 00 00 00 00 00", "-18446744073709551617"},
		{"3b ff ff ff ff ff ff ff ff", "-18446744073709551616"},
		{"1b ff ff ff ff ff ff ff ff", "18446744073709551615"},
		{"c4 82 21 19 6a b3", "27315e-2"},
		{"c5 82 20 03", "15e-1"},
		{"f9 3c 00", "1"},
		{"f9 c4 00", "-4"},
		{"fa 47 c3 50 00", "100000"},
		{"fb 3f f1 99 99 99 99 99 9a", "1.1"},
	}
	for r in rows {
		doc, err := cbor.build(hex(r.hex), .Cbor)
		if !testing.expectf(t, err == nil, "%s: %v", r.hex, err) {
			continue
		}
		defer core.destroy(&doc)
		buf: [128]u8
		s, ok := core.doc_number_text(&doc, core.ROOT, buf[:])
		testing.expectf(t, ok && s == r.want, "%s: want %s, got %s", r.hex, r.want, s)
	}
}

// A walk sends a tag as a fact before its content, a bignum as one number, a simple value as null, and obeys Skip.
@(test)
walk_tokens :: proc(t: ^testing.T) {
	Row :: struct {
		hex:  string,
		want: string,
	}
	rows := [?]Row {
		{"c1 1a 51 4b 67 b0", "Tag Number "},
		{"c2 41 01", "Tag Number "},
		{"a1 01 02", "Object Key Number End "},
		{"82 f7 f5", "Array Null True End "},
		{"9f 01 ff", "Array Number End "},
		{"5f 41 01 ff", "Bytes "},
		{"f9 3c 00", "Number "},
	}
	for r in rows {
		rec := Recorder {
			out  = strings.builder_make(context.temp_allocator),
			skip = .End,
		}
		src := hex(r.hex)
		hi, fault := cbor.walk(src, 0, .Cbor, {}, &rec, nil, record)
		testing.expectf(t, fault == nil && hi == u64(len(src)), "%s: %v %d", r.hex, fault, hi)
		testing.expectf(t, strings.to_string(rec.out) == r.want, "%s: want %s, got %s", r.hex, r.want, strings.to_string(rec.out))
	}
	// Skip a container: its content is judged but sends nothing.
	rec := Recorder {
		out  = strings.builder_make(context.temp_allocator),
		skip = .Array,
	}
	_, fault := cbor.walk(hex("82 81 01 02"), 0, .Cbor, {}, &rec, nil, record)
	testing.expect(t, fault == nil)
	testing.expect_value(t, strings.to_string(rec.out), "Array ")
	// A skipped value is still judged.
	rec = Recorder {
		out  = strings.builder_make(context.temp_allocator),
		skip = .Array,
	}
	_, fault = cbor.walk(hex("82 81 62 c3 28 01"), 0, .Cbor, {}, &rec, nil, record)
	testing.expect(t, fault != nil)
	// Stop ends the read with no fault.
	rec = Recorder {
		out  = strings.builder_make(context.temp_allocator),
		skip = .End,
		stop = 2,
	}
	_, fault = cbor.walk(hex("83 01 02 ff"), 0, .Cbor, {}, &rec, nil, record)
	testing.expect(t, fault == nil)
	testing.expect_value(t, strings.to_string(rec.out), "Array Number ")
}

// A duplicate key is a policy.
@(test)
duplicate_keys_follow_the_policy :: proc(t: ^testing.T) {
	src := hex("a2 61 61 01 61 61 02")
	_, err := cbor.build(src, .Cbor, {}, .Refuse)
	testing.expect(t, err != nil)
	doc, err2 := cbor.build(src, .Cbor, {}, .Last)
	walktest.expect_nil(t, err2)
	defer core.destroy(&doc)
	field, _ := core.member(&doc, core.ROOT, "a")
	n, _ := core.number(&doc, field)
	testing.expect_value(t, n.bits, 2)
}

// An integer key reads as its decimal digits, so `1` and `"1"` in one map are one key repeated.
@(test)
integer_and_text_keys_repeat :: proc(t: ^testing.T) {
	src := hex("a2 01 61 78 61 31 61 79")
	_, refused := cbor.build(src, .Cbor, {}, .Refuse)
	// The fault is at the second key's token, the text past its head.
	testing.expectf(t, walktest.fault_is(refused, .Duplicate_Key, 5), "%v", refused)
	doc, err := cbor.build(src, .Cbor)
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	last, found := core.member(&doc, core.ROOT, "1")
	testing.expect(t, found)
	buf: [8]u8
	s, _ := core.text(&doc, last, buf[:])
	testing.expect_value(t, s, "y")
	first, _ := core.member(&doc, core.ROOT, "1", .First)
	s, _ = core.text(&doc, first, buf[:])
	testing.expect_value(t, s, "x")
}

// A node's tag fact reads as a number, the tag nearest the item when several are stacked, and the outer tags stay in
// the document.
@(test)
the_nearest_tag_is_the_tag_fact :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	doc, err := cbor.build(hex("82 d9 d9f7 c1 1a 51 4b 67 b0 02"), .Cbor)
	walktest.expect_nil(t, err)
	tag, held := core.fact_value(&doc, 1, .Tag)
	testing.expect(t, held)
	testing.expect(t, tag.numeric)
	testing.expect_value(t, tag.text, "1")
	testing.expect_value(t, len(core.all_facts(&doc, 1)), 2)
	_, untagged := core.fact_value(&doc, 2, .Tag)
	testing.expect(t, !untagged)
	wide, werr := cbor.build(hex("db ff ff ff ff ff ff ff ff 00"), .Cbor)
	walktest.expect_nil(t, werr)
	tag, held = core.fact_value(&wide, core.ROOT, .Tag)
	testing.expect(t, held)
	testing.expect_value(t, tag.text, "18446744073709551615")
}

// Written as JSON, a byte string is base64 text, a tag is dropped and counted, and an integer key is its digits.
@(test)
documents_write_as_json :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	doc, err := cbor.build(hex("a2 01 c1 01 61 62 f7"), .Cbor)
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	text, dropped, werr := core.write(&doc, {}, stury_json.as(.Json))
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(text), `{"1":1,"b":null}`)
	testing.expect_value(t, dropped, 1)
	bytes, err2 := cbor.build(hex("a1 61 62 43 01 02 03"), .Cbor)
	walktest.expect_nil(t, err2)
	defer core.destroy(&bytes)
	text, _, werr = core.write(&bytes, {}, stury_json.as(.Json))
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(text), `{"b":"AQID"}`)
}

// A sequence of items reads as records, and a binary text has no byte order mark to skip.
@(test)
sequences_read_as_records :: proc(t: ^testing.T) {
	src := hex("01 82 02 03 61 61")
	it := records.open(src, cbor.as(.Cbor), .Concatenated)
	defer records.close(&it)
	count := 0
	for rec in records.next(&it) {
		count += 1
		testing.expect(t, 0 < len(rec.text))
	}
	testing.expect_value(t, count, 3)
	testing.expect(t, it.fault == nil)
	testing.expect(t, records.validate_parallel(src, cbor.as(.Cbor)) == nil)
	bad, is_bad := records.validate_parallel(hex("01 82 02 61 ff"), cbor.as(.Cbor)).?
	testing.expect(t, is_bad && bad.at == 4)

	bom := hex("ef bb bf 01")
	it2 := records.open(bom, cbor.as(.Cbor), .Concatenated)
	defer records.close(&it2)
	rec, ok := records.next(&it2)
	testing.expect(t, ok)
	testing.expect_value(t, len(rec.text), 1)
	testing.expect_value(t, rec.text[0], 0xef)
}
