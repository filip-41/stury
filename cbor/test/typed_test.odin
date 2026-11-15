// Typed reads and writes of CBOR items: values read whole, raw items, datetimes, numbers read by value and unions.
package cbor_tests

import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import walktest "../../walktest"
import cbor ".."
import stury_json "../../json"

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

// A `Datetime` is written after the tag of its meaning: 0 on a date-time with an offset, 1004 on a date, and none on a
// local date-time or a time, which CBOR has no tag for. It reads back as the text it was.
@(test)
datetimes_marshal_with_their_tags :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Times :: struct {
		at, day, local, clock: typed.Datetime,
	}
	v := Times{"2013-03-21T20:04:00Z", "2013-03-21", "2013-03-21T20:04:00", "20:04:00"}
	text, err := cbor.marshal(v, .Cbor)
	walktest.expect_nil(t, err)
	testing.expect_value(t, hex_of(text), "a4626174c074323031332d30332d32315432303a30343a30305a63646179d903ec6a323031332d30332d3231656c6f63616c73323031332d30332d32315432303a30343a303065636c6f636b6832303a30343a3030")
	back: Times
	walktest.expect_nil(t, cbor.unmarshal(text, .Cbor, &back))
	testing.expect_value(t, back, v)
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
