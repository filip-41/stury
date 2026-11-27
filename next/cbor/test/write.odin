package cbor_tests

import "core:bytes"
import encoding_json "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:cbor"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

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

@(test)
cbor_strict_specs_reencode_folded_numbers_and_refuse_dups :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Non-preferred CBOR folded numbers: small bignum, leading-zero bignum, indefinite bignum, indefinite decimal, indefinite bigfloat.
	cases := [?]struct {
		src:  []u8,
		want: []u8,
	}{
		{{0xC2, 0x41, 0x01}, {0x01}},
		{{0xC3, 0x41, 0x00}, {0x20}},
		{{0xC2, 0x4A, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}, {0xC2, 0x49, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}},
		{{0xC2, 0x5F, 0x42, 0x00, 0x01, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF}, {0xC2, 0x49, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}},
		{{0xC4, 0x9F, 0x21, 0x19, 0x6A, 0xB3, 0xFF}, {0xC4, 0x82, 0x21, 0x19, 0x6A, 0xB3}},
		{{0xC5, 0x9F, 0x21, 0x18, 0x03, 0xFF}, {0xC5, 0x82, 0x21, 0x03}},
	}
	for c, k in cases {
		doc, err := cbor.build(c.src, .Cbor)
		defer cbor.destroy(&doc)
		testing.expectf(t, err == nil, "case %d build: %v", k, err)
		for spec in ([?]cbor.Spec{.Preferred, .Deterministic, .Length_First}) {
			out, _, werr := cbor.write(&doc, spec)
			defer delete(out)
			testing.expectf(t, werr == nil && string(out) == string(c.want), "case %d %v: %v % x", k, spec, werr, out)
			testing.expectf(t, cbor.validate(out, spec) == nil, "case %d %v validate: %v", k, spec, cbor.validate(out, spec))
		}
	}

	// Duplicate map keys are refused under `.Deterministic` and `.Length_First`.
	dup_doc, derr := json.build(transmute([]u8)string(`{"a":1,"a":2}`), .Json, {dups = .All})
	defer json.destroy(&dup_doc)
	testing.expect(t, derr == nil)
	for spec in ([?]cbor.Spec{.Deterministic, .Length_First}) {
		_, _, werr := cbor.write(&dup_doc, spec)
		r, ok := werr.(cbor.Refused)
		testing.expectf(t, ok && r.why == .No_Spelling, "dup %v: %v", spec, werr)
	}

	// Oversized integer (> 4096 digits) is refused BEFORE sequence_take, leaving the token writer valid.
	big := make([]u8, 4097)
	defer delete(big)
	for &b in big {
		b = '9'
	}
	w: cbor.Writer
	testing.expect(t, cbor.writer_start(&w) == nil)
	testing.expect(t, cbor.token(&w, .Array) == nil)
	terr := cbor.token(&w, .Number, string(big))
	r, ok := terr.(cbor.Refused)
	testing.expectf(t, ok && r.why == .No_Spelling && r.node == 1, "big int: %v", terr)
	testing.expect(t, cbor.token(&w, .Number, "42") == nil)
	testing.expect(t, cbor.token(&w, .Close) == nil)
	out, eerr := cbor.writer_end(&w)
	defer delete(out)
	want_after := []u8{0x9F, 0x18, 42, 0xFF}
	testing.expectf(t, eerr == nil && string(out) == string(want_after), "after big int: %v % x", eerr, out)

	// `-0.0` preserves its sign bit in CBOR marshal (0xF9 0x80 0x00).
	neg_zero := -0.0
	nz, nzerr := cbor.marshal(&neg_zero, .Preferred)
	defer delete(nz)
	want_nz := []u8{0xF9, 0x80, 0x00}
	testing.expectf(t, nzerr == nil && string(nz) == string(want_nz), "neg zero: %v % x", nzerr, nz)

	// `verbatim_item` allowlist: `.Dropped` forces re-encode rather than raw `doc.src` copy.
	raw_dups := []u8{0xA2, 0x61, 'a', 0x01, 0x61, 'a', 0x02}
	ddoc, dderr := cbor.build(raw_dups, .Cbor, {dups = .Last})
	defer cbor.destroy(&ddoc)
	testing.expect(t, dderr == nil && .Dropped in ddoc.flags)
	dout, _, dwerr := cbor.write(&ddoc, .Cbor)
	defer delete(dout)
	want_dropped := []u8{0xA1, 0x61, 'a', 0x02}
	testing.expectf(t, dwerr == nil && string(dout) == string(want_dropped), "dropped flag: %v % x", dwerr, dout)
}

@(test)
toml_date_times_are_tagged_in_cbor :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "a = 1979-05-27T07:32:00Z\nb = 1979-05-27\nc = 07:32:00\nd = 1979-05-27T07:32:00\n"
	doc, err := toml.build(transmute([]u8)src)
	defer toml.destroy(&doc)
	testing.expect(t, err == nil)
	item, dropped, werr := cbor.write(&doc)
	defer delete(item)
	want := "\xA4\x61a\xC0\x74" + "1979-05-27T07:32:00Z" + "\x61b\xD9\x03\xEC\x6A" + "1979-05-27" + "\x61c\x68" + "07:32:00" + "\x61d\x73" + "1979-05-27T07:32:00"
	testing.expectf(t, werr == nil && string(item) == want, "%v % x", werr, item)
	testing.expect(t, .Tag in dropped)
	// A text that holds only the types CBOR tags drops no tag.
	doc2, _ := toml.build(transmute([]u8)string("a = 1979-05-27T07:32:00Z\nb = 1979-05-27\n"))
	defer toml.destroy(&doc2)
	item2, dropped2, _ := cbor.write(&doc2)
	defer delete(item2)
	testing.expectf(t, .Tag not_in dropped2, "%v", dropped2)
	back, berr := cbor.build(item2)
	defer cbor.destroy(&back)
	testing.expect(t, berr == nil)
}

@(test)
a_tag_given_to_the_token_writer_is_written_with_its_value :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: cbor.Writer
	testing.expect(t, cbor.writer_start(&w) == nil)
	steps := [?]struct {
		has_tag: bool,
		tag:     u64,
		kind:    cbor.Token_Kind,
		text:    string,
	}{
		{false, 0, .Array, ""},
		{true, 0, .String, "2013-03-21T20:04:00Z"},
		{true, 1004, .String, "2013-03-21"},
		{true, 24, .String, "x"},
		{false, 0, .String, "y"},
		{false, 0, .Close, ""},
	}
	for s in steps {
		if s.has_tag {
			testing.expect(t, cbor.tag(&w, s.tag) == nil)
		}
		testing.expect(t, cbor.token(&w, s.kind, s.text) == nil)
	}
	item, err := cbor.writer_end(&w)
	defer delete(item)
	want := "\x9F\xC0\x74" + "2013-03-21T20:04:00Z" + "\xD9\x03\xEC\x6A" + "2013-03-21" + "\xD8\x18\x61x" + "\x61y\xFF"
	testing.expectf(t, err == nil && string(item) == want, "%v % x", err, item)
}

@(private = "file")
Event :: struct {
	at: time.Time,
}

@(test)
a_time_is_marshalled_as_a_tagged_date_time :: proc(t: ^testing.T) {
	testkit.deadline(t)
	event := Event{time.unix(1363896240, 0)}
	item, err := cbor.marshal(&event)
	defer delete(item)
	testing.expectf(t, err == nil && len(item) > 5 && item[0] == 0xBF && item[4] == 0xC0, "%v % x", err, item)
	back: Event
	testing.expect(t, cbor.unmarshal(item, &back) == nil && back.at == event.at)

	// `.Preferred` and `.Deterministic` marshal with definite-length containers and keep tag 0.
	for spec in ([?]cbor.Spec{.Preferred, .Deterministic, .Length_First}) {
		det, derr := cbor.marshal(&event, spec)
		defer delete(det)
		testing.expectf(t, derr == nil && len(det) > 5 && det[0] == 0xA1 && det[4] == 0xC0, "%v: %v % x", spec, derr, det)
		testing.expectf(t, cbor.validate(det, spec) == nil, "%v: %v", spec, cbor.validate(det, spec))
		back2: Event
		testing.expect(t, cbor.unmarshal(det, &back2, spec) == nil && back2.at == event.at)
		buf: bytes.Buffer
		defer bytes.buffer_destroy(&buf)
		serr := cbor.marshal_to(bytes.buffer_to_stream(&buf), &event, spec)
		testing.expectf(t, serr == nil && string(bytes.buffer_to_bytes(&buf)) == string(det), "%v marshal_to: %v", spec, serr)
	}
}

@(test)
appendix_a_items_write_and_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	table, _ := encoding_json.parse(transmute([]u8)APPENDIX_A, allocator = context.temp_allocator)
	written := 0
	for row in table.(encoding_json.Array) {
		text := row.(encoding_json.Object)["hex"].(encoding_json.String)
		if text == SIMPLE_24 {
			continue
		}
		doc, err := cbor.build(testkit.hex(text), .Cbor, allocator = context.temp_allocator)
		if err != nil {
			continue
		}
		for spec in cbor.Spec {
			item, _, werr := cbor.write(&doc, spec, allocator = context.temp_allocator)
			if werr != nil {
				// A simple value or a number with no spelling in the spec's keys is refused.
				continue
			}
			written += 1
			testing.expectf(t, cbor.validate(item, spec) == nil, "%s under %v: % x", text, spec, item)
			back, berr := cbor.build(item, spec, allocator = context.temp_allocator)
			if !testing.expectf(t, berr == nil, "%s under %v: %v", text, spec, berr) {
				continue
			}
			// A deterministic spec writes a map's members in the order of their keys.
			if spec == .Cbor || spec == .Preferred {
				testkit.values_agree(t, &doc, tape.ROOT, &back, tape.ROOT, {number_values = true, facts = {.Tag}}, text)
			}
		}
	}
	testing.expect(t, written > 200)
}

@(test)
fixture_items_write_and_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for name in ([?]string{"citm.cbor", "logs.cbor", "twitter.cbor"}) {
		src, err := os.read_entire_file_from_path(strings.concatenate({FIXTURES, name}, context.temp_allocator), context.temp_allocator)
		if err != nil {
			continue
		}
		doc, derr := cbor.build(src, .Cbor, allocator = context.temp_allocator)
		if !testing.expectf(t, derr == nil, "%s: %v", name, derr) {
			continue
		}
		item, _, werr := cbor.write(&doc, .Preferred, allocator = context.temp_allocator)
		if !testing.expectf(t, werr == nil, "%s: %v", name, werr) {
			continue
		}
		back, berr := cbor.build(item, .Preferred, allocator = context.temp_allocator)
		testing.expectf(t, berr == nil, "%s: %v", name, berr)
		testkit.values_agree(t, &doc, tape.ROOT, &back, tape.ROOT, {number_values = true, facts = {.Tag}}, name)
	}
}

// The fixtures the benches read, where a checkout holds them.
@(private = "file")
FIXTURES :: #directory + "../../../bench/fixtures/"

// The items v1 writes of `{"a":[1,-1,24,256,65536,4294967296,1.5,1e300],"b":"é","c":[true,false,null]}` and of an array
// of three objects, which `stury --to cbor .` of v1 gives.
@(test)
the_items_are_v1s :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := [?]struct {
		json, hex: string,
	}{
		{`{"a":[1,-1,24,256,65536,4294967296,1.5,1e300],"b":"é","c":[true,false,null]}`, "a3 6161 88 01 20 1818 190100 1a00010000 1b0000000100000000 f93e00 fb7e37e43c8800759c 6162 62c3a9 6163 83f5f4f6"},
		{`[{"a":1,"b":"x,y"},{"a":2.5,"b":"q\"r"},{"a":true,"b":null}]`, "83 a2 6161 01 6162 63782c79 a2 6161 f94100 6162 63712272 a2 6161 f5 6162 f6"},
	}
	for c, k in cases {
		doc, err := json.build(transmute([]u8)c.json)
		defer json.destroy(&doc)
		testing.expect(t, err == nil)
		item, _, werr := cbor.write(&doc)
		defer delete(item)
		testing.expectf(t, werr == nil && string(item) == string(testkit.hex(c.hex)), "%d: %v % x", k, werr, item)
	}
}

// A write into a sink that takes a few bytes at a time is the item a buffer holds, for any size of piece.
@(test)
a_write_in_pieces_is_the_same_item :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	table, _ := encoding_json.parse(transmute([]u8)APPENDIX_A, allocator = context.temp_allocator)
	for row in table.(encoding_json.Array) {
		text := row.(encoding_json.Object)["hex"].(encoding_json.String)
		if text == SIMPLE_24 {
			continue
		}
		doc, err := cbor.build(testkit.hex(text), .Cbor, allocator = context.temp_allocator)
		if err != nil {
			continue
		}
		want, _, werr := cbor.write(&doc, .Cbor, allocator = context.temp_allocator)
		if werr != nil {
			continue
		}
		for limit in ([?]int{1, 3, 7}) {
			c: testkit.Chunked
			defer testkit.chunked_destroy(&c)
			_, serr := cbor.write_to(testkit.chunked_sink(&c, limit), &doc)
			testing.expectf(t, serr == nil && string(c.taken[:]) == string(want), "%s in pieces of %d: %v % x", text, limit, serr, c.taken)
			// The tokens of the same document, written into a sink in pieces, are an item that reads as the values.
			w: cbor.Writer
			c2: testkit.Chunked
			defer testkit.chunked_destroy(&c2)
			testing.expect(t, cbor.writer_start(&w, {}, testkit.chunked_sink(&c2, limit), context.temp_allocator) == nil)
			// A float that is no number has no token.
			if cbor.put(&w, &doc) != nil {
				_, _ = cbor.writer_end(&w)
				continue
			}
			_, eerr := cbor.writer_end(&w)
			testing.expectf(t, eerr == nil, "%s: %v", text, eerr)
			_, berr := cbor.build(c2.taken[:], .Cbor, allocator = context.temp_allocator)
			testing.expectf(t, berr == nil, "%s: %v % x", text, berr, c2.taken)
		}
	}
}
