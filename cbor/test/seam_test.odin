// What the package gives beside the walk and the writers: values read whole, the checks a model and a schema run, and
// the entry points that bind CBOR's passes.
package cbor_tests

import "core:bytes"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import records "../../core/records"
import schema "../../core/schema"
import walktest "../../walktest"
import cbor ".."
import stury_json "../../json"
import model "../../core/model"

// A value read whole is the bytes of its item: a string with its head, a string in chunks with its break, and a
// tagged item with its tags, a bignum's among them.
@(test)
whole_values_hold_their_items :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Whole :: struct {
		raw:   typed.Raw,
		value: core.Value,
	}
	Row :: struct {
		item: string, // the item's bytes, as hex
		want: string, // the value as JSON
	}
	rows := [?]Row {
		{"63 616263", `"abc"`},
		{"7f 6161 6162 ff", `"ab"`},
		{"1903e8", `1000`},
		{"c1 1a514b67b0", `1363896240`},
		{"d9d9f7 c1 01", `1`},
		{"c2 49 010000000000000000", `18446744073709551616`},
		{"c4 82 21 196ab3", `273.15`},
		{"d9d9f7 82 01 6161", `[1,"a"]`},
		{"f93e00", `1.5`},
		{"f6", `null`},
	}
	for r in rows {
		item := hex(r.item)
		text := make([dynamic]u8, context.temp_allocator)
		append(&text, 0xa2, 0x63, 'r', 'a', 'w')
		append(&text, ..item)
		append(&text, 0x65, 'v', 'a', 'l', 'u', 'e')
		append(&text, ..item)
		got: Whole
		if !walktest.expect_nil(t, cbor.unmarshal(text[:], .Cbor, &got)) {
			continue
		}
		testing.expectf(t, string(got.raw) == string(item), "%s: raw is %s", r.item, hex_of(transmute([]u8)string(got.raw)))
		spelled, err := write.write_value(got.value, stury_json.as(.Json))
		walktest.expect_nil(t, err)
		testing.expectf(t, string(spelled) == r.want, "%s: value is %s", r.item, spelled)
		// The raw item is written back as it was read.
		back, merr := cbor.marshal(got, .Cbor)
		walktest.expect_nil(t, merr)
		again: Whole
		walktest.expect_nil(t, cbor.unmarshal(back, .Cbor, &again))
		testing.expectf(t, string(again.raw) == string(item), "%s: raw is written as %s", r.item, hex_of(transmute([]u8)string(again.raw)))
	}
}

// A model loads a CBOR item, judging its rules, and refuses one that breaks them.
@(test)
models_load_items :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Pet :: struct {
		name: string `model:"len>=2"`,
		age:  int `model:"optional,<=30"`,
		tags: []string `model:"optional"`,
	}
	reg: model.Registry
	defer model.destroy(&reg)
	m, err := model.compile(&reg, Pet, cbor.checks(.Cbor))
	if !walktest.expect_nil(t, err) {
		return
	}
	pet: Pet
	walktest.expect_nil(t, model.load(&m, hex("a3 646e616d65 63726578 63616765 03 6474616773 82 6161 6162"), &pet))
	testing.expect(t, pet.name == "rex" && pet.age == 3 && len(pet.tags) == 2 && pet.tags[1] == "b")
	// An array reads the members by position.
	placed: Pet
	walktest.expect_nil(t, model.load(&m, hex("83 63726578 04 80"), &placed))
	testing.expect(t, placed.name == "rex" && placed.age == 4 && len(placed.tags) == 0)
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	bad: Pet
	testing.expect(t, model.load(&m, hex("a2 646e616d65 6172 63616765 1863"), &bad, &sink) != nil)
	testing.expect_value(t, len(sink.entries), 2)
	missing: Pet
	testing.expect(t, model.load(&m, hex("a1 63616765 03"), &missing) != nil)
}

// A schema bound to CBOR judges an item. The numbers of a binary text are equal by value, not by the bytes that encode
// them: 1 as a one-byte integer, a two-byte integer and a half float, and a bignum as a bignum or as the integer it
// equals.
@(test)
schemas_check_items :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	bound :: proc(t: ^testing.T, text: string) -> (b: cbor.Bound_Schema, ok: bool) {
		s, err := stury_json.load_schema(transmute([]u8)text)
		if !walktest.expect_nil(t, err) {
			return
		}
		berr: core.Error
		b, berr = cbor.bind_schema(s, .Cbor)
		return b, walktest.expect_nil(t, berr)
	}
	unique, made := bound(t, `{"uniqueItems": true}`)
	if !made {
		return
	}
	same := [?]string {
		"82 01 1801",
		"82 01 f93c00",
		"82 01 fa3f800000",
		"82 00 f98000",
		"83 05 06 c2 41 05",
		"82 c2 49 010000000000000000 c2 4a 00010000000000000000",
	}
	for text in same {
		testing.expectf(t, schema.check(&unique, hex(text)) != nil, "%s is unique", text)
	}
	different := [?]string {
		"82 01 02",
		"82 01 f94000",
		"82 c2 49 010000000000000000 c2 49 010000000000000001",
		"82 6161 4161",
	}
	for text in different {
		testing.expectf(t, schema.check(&unique, hex(text)) == nil, "%s is not unique", text)
	}
	shaped, shaped_made := bound(t, `{"type": "object", "required": ["id"], "properties": {"id": {"type": "integer", "minimum": 1}, "name": {"type": "string", "maxLength": 3}}, "additionalProperties": false}`)
	if !shaped_made {
		return
	}
	walktest.expect_nil(t, schema.check(&shaped, hex("a2 626964 07 646e616d65 63616263")))
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	testing.expect(t, schema.check(&shaped, hex("a3 626964 00 646e616d65 6461626364 6178 f5"), &sink) != nil)
	testing.expect_value(t, len(sink.entries), 3)
	testing.expect(t, schema.check(&shaped, hex("a1 646e616d65 f6")) != nil)
	// An item that is not well-formed is the walk's fault.
	testing.expect(t, walktest.fault_of(schema.check(&shaped, hex("a2 626964 07"))) != nil)
}

// The record entry points bind CBOR's framing: a reader frames and judges each item, builds one once it holds the
// record reads, and a writer puts nothing between the items.
@(test)
record_entry_points_bind_the_framing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	src := hex("a1 6161 01 82 02 03 6161")
	it := cbor.records_open(src, .Cbor)
	defer records.close(&it)
	it.docs = cbor.record_docs(.Cbor)
	count := 0
	for rec in records.next(&it) {
		doc, err := records.build(&it, rec)
		walktest.expect_nil(t, err)
		testing.expect_value(t, core.span(&doc, core.ROOT)[0], rec.text[0])
		count += 1
	}
	testing.expect_value(t, count, 3)
	testing.expect(t, it.fault == nil)
	faults, failed := cbor.records_check(hex("01 82 02"), .Cbor)
	testing.expect(t, failed == nil)
	testing.expect_value(t, len(faults), 1)
	other := cbor.records_open(src, .Cbor, framing = .Lines)
	defer records.close(&other)
	_, any := records.next(&other)
	testing.expect(t, !any && other.fault != nil)

	// A stream gives its items through a window that grows to hold a whole one.
	long := make([dynamic]u8, context.temp_allocator)
	for i in 0 ..< 30000 {
		append(&long, 0x83, 0x19, u8(i >> 8), u8(i), 0x63, 'a', 'b', 'c', 0xf5)
	}
	input: bytes.Reader
	stream := cbor.records_open_stream(bytes.reader_init(&input, long[:]), .Cbor)
	defer records.close(&stream)
	streamed := 0
	for rec in records.next(&stream) {
		testing.expect(t, len(rec.text) == 9 && rec.text[1] == 0x19 && int(rec.text[2]) << 8 | int(rec.text[3]) == streamed)
		streamed += 1
	}
	testing.expect_value(t, streamed, 30000)
	testing.expect(t, stream.fault == nil)

	Row :: struct {
		id: int,
	}
	plan, perr := cbor.plan_make(Row)
	walktest.expect_nil(t, perr)
	wr: records.Writer
	testing.expect_value(t, cbor.writer_init(&wr, {}, cbor.as(.Cbor), .Concatenated), core.Typed_Error_Kind.None)
	testing.expect_value(t, records.write(&wr, Row{1}, &plan), core.Typed_Error_Kind.None)
	testing.expect_value(t, records.write(&wr, Row{300}, &plan), core.Typed_Error_Kind.None)
	text, werr := records.writer_end(&wr)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, hex_of(text), "a162696401a162696419012c")
}

// The entry points that bind their passes answer as the handle's do: a document `build` read is written and queried
// with no services.
@(test)
bound_entry_points_answer_as_the_handle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	src := hex("a2 6161 9f 01 02 ff 6162 c1 03")
	doc, err := cbor.build(src, .Cbor)
	walktest.expect_nil(t, err)
	testing.expect(t, core.services_of(doc.as) == nil)
	text, dropped, werr := cbor.write(&doc, .Preferred)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, dropped, 0)
	testing.expect_value(t, hex_of(text), "a26161820102" + "6162c103")
	by_handle, _, herr := core.write(&doc, {}, cbor.as(.Preferred))
	walktest.expect_nil(t, herr)
	testing.expect_value(t, hex_of(by_handle), hex_of(text))
	_, _, key_err := cbor.write(&doc, .Cbor, node = 1)
	testing.expect(t, key_err != nil)
	answers, qerr := cbor.query(&doc, core.Path{steps = {core.Name("a"), core.Index(1)}})
	walktest.expect_nil(t, qerr)
	testing.expect_value(t, len(answers), 1)
	n, _ := core.number(&doc, answers[0].node)
	testing.expect_value(t, n.bits, 2)
	chosen, cerr := core.build(src, cbor.as(.Cbor))
	walktest.expect_nil(t, cerr)
	testing.expect(t, core.equal(core.Node_Ref{&doc, core.ROOT}, core.Node_Ref{&chosen, core.ROOT}))
	// A plan the handle makes reads and writes through the plan's own reads.
	Pair :: struct {
		a: int,
		b: string,
	}
	plan, perr := typed.plan_make(Pair, cbor.as(.Cbor, {structs = .Array}))
	walktest.expect_nil(t, perr)
	placed, merr := write.marshal(Pair{1, "x"}, &plan)
	walktest.expect_nil(t, merr)
	testing.expect_value(t, hex_of(placed), "82016178")
	pair: Pair
	walktest.expect_nil(t, typed.unmarshal_text(placed, &pair, Pair, &plan, {}))
	testing.expect_value(t, pair, Pair{1, "x"})
	w: write.Tokens
	testing.expect_value(t, cbor.tokens_init(&w, .Cbor), core.Typed_Error_Kind.None)
	write.open_array(&w)
	write.value_int(&w, -1)
	write.close(&w)
	tokens, terr := write.tokens_finish(&w)
	testing.expect_value(t, terr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, hex_of(tokens), "8120")
}

// A `Raw` is one item in the plan's encoding, and its containers count toward the depth with the structs that hold it.
@(test)
raw_items_are_judged :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Holder :: struct {
		raw: typed.Raw,
	}
	text, err := cbor.marshal(Holder{typed.Raw(string(hex("9f 01 ff")))}, .Cbor)
	walktest.expect_nil(t, err)
	testing.expect_value(t, hex_of(text), "a1637261779f01ff")
	_, strict := cbor.marshal(Holder{typed.Raw(string(hex("9f 01 ff")))}, .Preferred)
	walktest.expect_kind(t, strict, core.Typed_Error_Kind.Bad_Raw)
	_, two := cbor.marshal(Holder{typed.Raw(string(hex("01 02")))}, .Cbor)
	walktest.expect_kind(t, two, core.Typed_Error_Kind.Bad_Raw)
	empty, eerr := cbor.marshal(Holder{}, .Cbor)
	walktest.expect_nil(t, eerr)
	testing.expect_value(t, hex_of(empty), "a163726177f6")

	Link :: struct {
		next: ^Link `cbor:",omitempty"`,
		raw:  typed.Raw `cbor:",omitempty"`,
	}
	links := make([]Link, core.MAX_DEPTH)
	for i in 0 ..< len(links) - 1 {
		links[i].next = &links[i + 1]
	}
	last := &links[len(links) - 1]
	last.raw = typed.Raw(string(hex("6161")))
	deep, derr := cbor.marshal(links[0], .Cbor)
	walktest.expect_nil(t, derr)
	walktest.expect_nil(t, cbor.validate(deep, .Cbor))
	// No level is left for a container.
	last.raw = typed.Raw(string(hex("80")))
	_, past := cbor.marshal(links[0], .Cbor)
	walktest.expect_kind(t, past, core.Typed_Error_Kind.Too_Deep)
}

// A number reads into a member by its value, whatever item spells it: a bignum that fits is an integer, one past 64 bits
// reads into a float or is refused on the side of its sign, and a number with a fraction is no integer.
@(test)
numbers_read_by_value :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Int :: struct {
		v: i64,
	}
	Uint :: struct {
		v: u64,
	}
	Float :: struct {
		v: f64,
	}
	Digits :: struct {
		v: core.Number_Text,
	}
	item :: proc(text: string) -> []u8 {
		out := make([dynamic]u8, context.temp_allocator)
		append(&out, 0xa1, 0x61, 'v')
		append(&out, ..hex(text))
		return out[:]
	}
	ints := [?]struct {
		hex:  string,
		want: i64,
	}{{"c3 41 01", -2}, {"c2 41 05", 5}, {"c2 40", 0}, {"3903e7", -1000}, {"3b 7fffffffffffffff", min(i64)}}
	for r in ints {
		got: Int
		testing.expectf(t, cbor.unmarshal(item(r.hex), .Cbor, &got) == nil && got.v == r.want, "%s: %d", r.hex, got.v)
	}
	refused := [?]struct {
		hex:  string,
		want: core.Typed_Error_Kind,
	} {
		{"c2 49 010000000000000000", .Above_Maximum},
		{"c3 49 010000000000000000", .Below_Minimum},
		{"3b ffffffffffffffff", .Below_Minimum},
		{"1b ffffffffffffffff", .Above_Maximum},
		{"c4 82 21 196ab3", .Wrong_Kind},
		{"c4 82 02 05", .Wrong_Kind},
		{"c5 82 01 03", .Wrong_Kind},
		{"f93c00", .Wrong_Kind},
	}
	for r in refused {
		got: Int
		walktest.expect_kind(t, cbor.unmarshal(item(r.hex), .Cbor, &got), r.want)
	}
	most: Uint
	walktest.expect_nil(t, cbor.unmarshal(item("1b ffffffffffffffff"), .Cbor, &most))
	testing.expect_value(t, most.v, max(u64))
	below: Uint
	walktest.expect_kind(t, cbor.unmarshal(item("20"), .Cbor, &below), core.Typed_Error_Kind.Below_Minimum)
	floats := [?]struct {
		hex:  string,
		want: f64,
	} {
		{"c2 49 010000000000000000", 18446744073709551616},
		{"c3 49 010000000000000000", -18446744073709551617},
		{"3b ffffffffffffffff", -18446744073709551616},
		{"c4 82 21 196ab3", 273.15},
		{"c4 82 02 05", 500},
		{"c5 82 20 03", 1.5},
		{"f93c00", 1},
		{"fa47c35000", 100000},
		{"18ff", 255},
		{"f97c00", max(f64) * 2},
	}
	for r in floats {
		got: Float
		testing.expectf(t, cbor.unmarshal(item(r.hex), .Cbor, &got) == nil && got.v == r.want, "%s: %v", r.hex, got.v)
	}
	// A bignum past binary64's range is no infinity.
	huge := make([dynamic]u8, context.temp_allocator)
	append(&huge, 0xa1, 0x61, 'v', 0xc2, 0x58, 200)
	for _ in 0 ..< 200 {
		append(&huge, 0xff)
	}
	past: Float
	walktest.expect_kind(t, cbor.unmarshal(huge[:], .Cbor, &past), core.Typed_Error_Kind.Above_Maximum)
	digits := [?]struct {
		hex, want: string,
	}{{"c3 49 010000000000000000", "-18446744073709551617"}, {"0a", "10"}, {"f93e00", "1.5"}, {"c4 82 21 196ab3", "27315e-2"}}
	for r in digits {
		got: Digits
		testing.expectf(t, cbor.unmarshal(item(r.hex), .Cbor, &got) == nil && got.v.text == r.want, "%s: %s", r.hex, got.v.text)
	}
	nan: Digits
	walktest.expect_kind(t, cbor.unmarshal(item("f97e00"), .Cbor, &nan), core.Typed_Error_Kind.Non_Finite)
}

// A union of named struct arms is a map with the arm's name under the plan's tag member, found wherever it stands, and
// a map with a captured member, a pointer and an `any` write through the same heads.
@(test)
unions_and_captures_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Circle :: struct {
		r: f64,
	}
	Square :: struct {
		side: int,
	}
	Shape :: union {
		Circle,
		Square,
	}
	Drawing :: struct {
		shapes: []Shape,
		best:   ^Square,
		extra:  map[string]int `cbor:",unknown"`,
		note:   any `cbor:",omitempty"`,
	}
	plan, perr := cbor.plan_make(Drawing, plan = {union_tag = "type"}, reads = cbor.reads(.Cbor))
	if !walktest.expect_nil(t, perr) {
		return
	}
	extra := make(map[string]int)
	extra["zz"], extra["a"] = 1, 2
	shapes := make([]Shape, 2)
	shapes[0], shapes[1] = Circle{1.5}, Square{2}
	best := Square{9}
	want := Drawing{shapes = shapes, best = &best, extra = extra, note = "n"}
	text, err := cbor.marshal(want, &plan)
	if !walktest.expect_nil(t, err) {
		return
	}
	walktest.expect_nil(t, cbor.validate(text, .Preferred))
	testing.expect_value(t, hex_of(text), "a5" + "66736861706573" + "82" + "a2" + "6474797065" + "66436972636c65" + "6172" + "f93e00" + "a2" + "6474797065" + "66537175617265" + "6473696465" + "02" + "6462657374" + "a1" + "6473696465" + "09" + "646e6f7465" + "616e" + "6161" + "02" + "627a7a" + "01")
	got: Drawing
	// An `any` is written and never read.
	got_text := hex("a4 6462657374 a1 6473696465 09 627a7a 01 66736861706573 82 a2 6172 f93e00 6474797065 66436972636c65 a2 6474797065 66537175617265 6473696465 02 6161 02")
	if !walktest.expect_nil(t, cbor.unmarshal(got_text, .Cbor, &got, &plan)) {
		return
	}
	testing.expect(t, len(got.shapes) == 2 && got.shapes[0].(Circle).r == 1.5 && got.shapes[1].(Square).side == 2)
	testing.expect(t, got.best != nil && got.best.side == 9)
	testing.expect(t, len(got.extra) == 2 && got.extra["zz"] == 1 && got.extra["a"] == 2)
	missing: Drawing
	walktest.expect_kind(t, cbor.unmarshal(hex("a1 66736861706573 81 a1 6172 01"), .Cbor, &missing, &plan), core.Typed_Error_Kind.Missing_Tag)
}
