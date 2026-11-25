package cbor_tests

import "core:testing"
import "stury:cbor"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// The CBOR writer: a document of any format is written as an item that reads back as the same values, in preferred
// form, and in the order of section 4.2.1 under the deterministic specs.

@(private = "file")
TEXTS := [?]string{
	`{"a":1,"bb":[true,false,null,-1,24,256,65536,4294967296,18446744073709551615,-9223372036854775808],"c":{"d":"é\n"},"e":[]}`,
	`[0.5,1.0,1e300,-0.0,100000.0,3.4028234663852886e38,1.1,5.960464477539063e-8]`,
	`[123456789012345678901234567890,-123456789012345678901234567890,18446744073709551616,-18446744073709551617]`,
	`"text"`,
	`{}`,
}

@(test)
json_documents_write_as_cbor_that_reads_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src, k in TEXTS {
		doc, err := json.build(transmute([]u8)src)
		defer json.destroy(&doc)
		testing.expectf(t, err == nil, "%s: %v", src, err)
		for spec in cbor.Spec {
			item, _, werr := cbor.write(&doc, spec)
			defer delete(item)
			testing.expectf(t, werr == nil, "%d under %v: %v", k, spec, werr)
			testing.expectf(t, cbor.validate(item, spec) == nil, "%d under %v: %v: % x", k, spec, cbor.validate(item, spec), item)
			back, berr := cbor.build(item, spec)
			defer cbor.destroy(&back)
			testing.expectf(t, berr == nil, "%d: %v", k, berr)
			if spec == .Cbor || spec == .Preferred {
				testkit.values_agree(t, &doc, tape.ROOT, &back, tape.ROOT, {number_values = k != 2}, "cbor")
			}
		}
	}
}

@(test)
known_items_are_written_as_the_standard_spells_them :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		json: string,
		hex:  []u8,
	}
	cases := [?]Case{
		{`0`, {0x00}},
		{`[1,-1,23,24,255,256,65535,65536]`, {0x88, 0x01, 0x20, 0x17, 0x18, 0x18, 0x18, 0xFF, 0x19, 0x01, 0x00, 0x19, 0xFF, 0xFF, 0x1A, 0x00, 0x01, 0x00, 0x00}},
		{`[1.5,1.1,100000.0,0.0]`, {0x84, 0xF9, 0x3E, 0x00, 0xFB, 0x3F, 0xF1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A, 0xFA, 0x47, 0xC3, 0x50, 0x00, 0xF9, 0x00, 0x00}},
		{`{"b":1,"aa":2,"a":3}`, {0xA3, 0x61, 'a', 0x03, 0x61, 'b', 0x01, 0x62, 'a', 'a', 0x02}},
		{`123456789012345678901234567890`, {0xC2, 0x4D, 0x01, 0x8E, 0xE9, 0x0F, 0xF6, 0xC3, 0x73, 0xE0, 0xEE, 0x4E, 0x3F, 0x0A, 0xD2}},
		{`-18446744073709551617`, {0xC3, 0x49, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}},
	}
	for c, k in cases {
		doc, _ := json.build(transmute([]u8)c.json)
		defer json.destroy(&doc)
		item, _, err := cbor.write(&doc, .Deterministic)
		defer delete(item)
		testing.expectf(t, err == nil && string(item) == string(c.hex), "case %d: %v % x", k, err, item)
	}
}

@(test)
cbor_documents_keep_their_tags_and_bytes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// A tagged date-time, a tagged byte string and a 24-bit key map.
	items := [?][]u8{
		{0xC1, 0x1A, 0x51, 0x4B, 0x67, 0xB0},
		{0x82, 0xD8, 0x18, 0x43, 0x01, 0x02, 0x03, 0xC0, 0x74, '2', '0', '1', '3', '-', '0', '3', '-', '2', '1', 'T', '2', '0', ':', '0', '4', ':', '0', '0', 'Z'},
		{0xA1, 0x01, 0xF5},
		{0xC2, 0x49, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
	}
	for item, k in items {
		doc, err := cbor.build(item)
		defer cbor.destroy(&doc)
		testing.expectf(t, err == nil, "%d: %v", k, err)
		out, dropped, werr := cbor.write(&doc)
		defer delete(out)
		testing.expectf(t, werr == nil && string(out) == string(item) && dropped == {}, "%d: %v % x, want % x", k, werr, out, item)
	}
}

@(test)
a_number_with_no_cbor_spelling_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, _ := json.build(transmute([]u8)string(`[1.5e400]`))
	defer json.destroy(&doc)
	_, _, err := cbor.write(&doc)
	testing.expect(t, err != nil)
	doc2, _ := json.build(transmute([]u8)string(`{"a":1}`))
	defer json.destroy(&doc2)
	_, _, err = cbor.write(&doc2, .Cbor, {indent = 2})
	testing.expect(t, err != nil)
}

@(private = "file")
Mode :: enum u8 {
	Off,
	On,
}

@(private = "file")
Item :: struct {
	name:  string,
	n:     i64,
	big:   u64,
	f:     f64,
	ok:    bool,
	mode:  Mode,
	list:  []int,
	inner: struct {
		a: string `cbor:"b"`,
	},
	table: map[string]int,
	maybe: Maybe(int),
}

@(test)
a_marshalled_value_reads_back_as_cbor :: proc(t: ^testing.T) {
	testkit.deadline(t)
	context.allocator = context.temp_allocator
	v := Item{name = "x", n = -70000, big = max(u64), f = 0.1, ok = true, mode = .On, list = []int{1, 2, 3}, maybe = 5}
	v.inner.a = "in"
	v.table["k"] = 9
	item, err := cbor.marshal(&v)
	testing.expectf(t, err == nil, "%v", err)
	testing.expectf(t, cbor.validate(item) == nil, "% x", item)
	back: Item
	uerr := cbor.unmarshal(item, &back)
	testing.expectf(t, uerr == nil, "%v", uerr)
	testing.expectf(t, back.name == "x" && back.n == -70000 && back.big == max(u64) && back.f == 0.1 && back.ok && back.mode == .On, "%v", back)
	testing.expectf(t, len(back.list) == 3 && back.inner.a == "in" && back.table["k"] == 9 && back.maybe == 5, "%v", back)
}

@(test)
tokens_write_an_indefinite_item_and_refuse_a_malformed_one :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: cbor.Writer
	testing.expect(t, cbor.writer_start(&w) == nil)
	for step in ([?]struct{kind: tape.Token_Kind, text: string}{{.Object, ""}, {.Key, "a"}, {.Array, ""}, {.Number, "1"}, {.Number, "1.5"}, {.Close, ""}, {.Close, ""}}) {
		testing.expect(t, cbor.token(&w, step.kind, step.text) == nil)
	}
	testing.expect(t, cbor.token(&w, .Null) != nil)
	item, err := cbor.writer_end(&w)
	defer delete(item)
	want := []u8{0xBF, 0x61, 'a', 0x9F, 0x01, 0xF9, 0x3E, 0x00, 0xFF, 0xFF}
	testing.expectf(t, err == nil && string(item) == string(want), "% x %v", item, err)
}
