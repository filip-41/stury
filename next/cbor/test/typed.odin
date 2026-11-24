package cbor_tests

import "base:runtime"
import "core:math/rand"
import "core:testing"
import "core:time"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// Typed reads of CBOR items: values read whole, raw items, date-times, numbers read by value and unions.

// The map `{"v": <item>}` whose item is the bytes of hex text `item`.
holding :: proc(item: string) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, 0xa1, 0x61, 'v')
	append(&out, ..hex(item))
	return out[:]
}

// Expects `e` to be a refusal `want`.
expect_refusal_of :: proc(t: ^testing.T, e: tape.Error, want: cbor.Refusal, what: string, loc := #caller_location) {
	f, is_fault := e.(tape.Fault)
	if !testing.expectf(t, is_fault && f.kind == .Refused, "%s: got %v, wanted %v", what, e, want, loc = loc) {
		return
	}
	testing.expectf(t, cbor.Refusal(f.detail) == want, "%s: got %v, wanted %v", what, cbor.Refusal(f.detail), want, loc = loc)
}

// A value read whole is the bytes of its item: a string with its head, and a string in chunks with its break. The tags
// before an item are not part of it, so a bignum is its byte string and a tagged item the item.
@(test)
raw_values_hold_their_items :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Whole :: struct {
		raw: cbor.Raw,
	}
	items := [?]struct {
		item, raw: string,
	} {
		{"63 616263", "63 616263"},
		{"7f 6161 6162 ff", "7f 6161 6162 ff"},
		{"1903e8", "1903e8"},
		{"c1 1a514b67b0", "1a514b67b0"},
		{"d9d9f7 c1 01", "01"},
		{"c2 49 010000000000000000", "49 010000000000000000"},
		{"c4 82 21 196ab3", "82 21 196ab3"},
		{"d9d9f7 82 01 6161", "82 01 6161"},
		{"f93e00", "f93e00"},
		{"f6", "f6"},
		{"9f 01 ff", "9f 01 ff"},
		{"bf 6161 01 ff", "bf 6161 01 ff"},
		{"a1 6161 82 01 02", "a1 6161 82 01 02"},
	}
	for r in items {
		want := hex(r.raw)
		src := make([dynamic]u8, context.temp_allocator)
		append(&src, 0xa1, 0x63, 'r', 'a', 'w')
		append(&src, ..hex(r.item))
		for borrow in ([]bool{true, false}) {
			got: Whole
			e := cbor.unmarshal(src[:], &got, .Cbor, {borrow_strings = borrow}, allocator = context.temp_allocator)
			if !testing.expectf(t, e == nil, "%s: %v", r.item, e) {
				continue
			}
			testing.expectf(t, string(got.raw) == string(want), "%s: raw is %x", r.item, transmute([]u8)string(got.raw))
		}
	}
}

// A `Raw` that is the whole text, and one in a list, hold the item as it spells, the indefinite ones with their breaks.
@(test)
raw_items_nest_in_lists_and_roots :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	whole: cbor.Raw
	src := hex("9f 01 82 02 03 ff")
	testing.expect_value(t, cbor.unmarshal(src, &whole, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect_value(t, string(whole), string(src))
	list: []cbor.Raw
	src = hex("83 01 9f ff 61 61")
	testing.expect_value(t, cbor.unmarshal(src, &list, .Cbor, allocator = context.temp_allocator), nil)
	if testing.expect_value(t, len(list), 3) {
		testing.expect_value(t, string(list[0]), string(hex("01")))
		testing.expect_value(t, string(list[1]), string(hex("9fff")))
		testing.expect_value(t, string(list[2]), string(hex("6161")))
	}
}

// A `Raw` is one item whole, so a text that fails as `validate` fails inside it is that error.
@(test)
a_raw_item_is_judged :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Holder :: struct {
		raw: cbor.Raw,
	}
	// A text string that is not UTF-8, a reserved head and a cut item.
	for bad in ([]string{"a1 63 726177 62 c328", "a1 63 726177 1c", "a1 63 726177 82 01", "a1 63 726177 7f 61 61"}) {
		src := hex(bad)
		got: Holder
		e := cbor.unmarshal(src, &got, .Cbor, allocator = context.temp_allocator)
		testing.expectf(t, e != nil && e == cbor.validate(src, .Cbor), "%s: %v, validate %v", bad, e, cbor.validate(src, .Cbor))
	}
}

// A number reads into a member by its value, whatever item spells it: a bignum that fits is an integer, one past 64 bits
// reads into a float or is refused on the side of its sign, and a number with a fraction is no integer.
@(test)
numbers_read_by_value :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Int :: struct {
		v: i64,
	}
	Uint :: struct {
		v: u64,
	}
	Float :: struct {
		v: f64,
	}
	ints := [?]struct {
		hex:  string,
		want: i64,
	}{{"c3 41 01", -2}, {"c2 41 05", 5}, {"c2 40", 0}, {"3903e7", -1000}, {"3b 7fffffffffffffff", min(i64)}, {"1b 7fffffffffffffff", max(i64)}, {"00", 0}, {"17", 23}, {"1818", 24}, {"190100", 256}, {"1a00010000", 65536}}
	for r in ints {
		got: Int
		e := cbor.unmarshal(holding(r.hex), &got, .Cbor, allocator = context.temp_allocator)
		testing.expectf(t, e == nil && got.v == r.want, "%s: %v, %d", r.hex, e, got.v)
	}
	refused := [?]struct {
		hex:  string,
		want: cbor.Refusal,
	} {
		{"c2 49 010000000000000000", .Above_Maximum},
		{"c3 49 010000000000000000", .Below_Minimum},
		{"3b ffffffffffffffff", .Below_Minimum},
		{"1b ffffffffffffffff", .Above_Maximum},
		{"c4 82 21 196ab3", .Expected_Integer},
		{"c4 82 02 05", .Expected_Integer},
		{"c5 82 01 03", .Expected_Integer},
		{"f93c00", .Expected_Integer},
		{"fa47c35000", .Expected_Integer},
		{"f5", .Expected_Integer},
		{"61 31", .Expected_Integer},
	}
	for r in refused {
		got: Int
		expect_refusal_of(t, cbor.unmarshal(holding(r.hex), &got, .Cbor, allocator = context.temp_allocator), r.want, r.hex)
	}
	most: Uint
	testing.expect_value(t, cbor.unmarshal(holding("1b ffffffffffffffff"), &most, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect_value(t, most.v, max(u64))
	below: Uint
	expect_refusal_of(t, cbor.unmarshal(holding("20"), &below, .Cbor, allocator = context.temp_allocator), .Below_Minimum, "20")
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
		{"f93e00", 1.5},
		{"f9c400", -4},
		{"fa47c35000", 100000},
		{"fb3ff8000000000000", 1.5},
		{"18ff", 255},
		{"00", 0},
		{"f97c00", max(f64) * 2},
		{"f9fc00", -max(f64) * 2},
	}
	for r in floats {
		got: Float
		e := cbor.unmarshal(holding(r.hex), &got, .Cbor, allocator = context.temp_allocator)
		testing.expectf(t, e == nil && got.v == r.want, "%s: %v, %v", r.hex, e, got.v)
	}
	// A bignum past binary64's range is no infinity.
	huge := make([dynamic]u8, context.temp_allocator)
	append(&huge, 0xa1, 0x61, 'v', 0xc2, 0x58, 200)
	for _ in 0 ..< 200 {
		append(&huge, 0xff)
	}
	past: Float
	expect_refusal_of(t, cbor.unmarshal(huge[:], &past, .Cbor, allocator = context.temp_allocator), .Above_Maximum, "bignum of 200 bytes")
	huge[3] = 0xc3
	expect_refusal_of(t, cbor.unmarshal(huge[:], &past, .Cbor, allocator = context.temp_allocator), .Below_Minimum, "negative bignum of 200 bytes")
	nan: Float
	testing.expect_value(t, cbor.unmarshal(holding("f97e00"), &nan, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect(t, nan.v != nan.v)
}

// Each integer width holds its range, a half float reads as itself, and a float32 member takes the nearest value.
@(test)
every_width_reads_its_range :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	I8 :: struct {
		v: i8,
	}
	U8 :: struct {
		v: u8,
	}
	I16 :: struct {
		v: i16,
	}
	U32 :: struct {
		v: u32,
	}
	F32 :: struct {
		v: f32,
	}
	a: I8
	testing.expect_value(t, cbor.unmarshal(holding("387f"), &a, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect_value(t, a.v, -128)
	expect_refusal_of(t, cbor.unmarshal(holding("3880"), &a, .Cbor, allocator = context.temp_allocator), .Below_Minimum, "-129")
	expect_refusal_of(t, cbor.unmarshal(holding("1880"), &a, .Cbor, allocator = context.temp_allocator), .Above_Maximum, "128")
	b: U8
	testing.expect_value(t, cbor.unmarshal(holding("18ff"), &b, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect_value(t, b.v, 255)
	expect_refusal_of(t, cbor.unmarshal(holding("190100"), &b, .Cbor, allocator = context.temp_allocator), .Above_Maximum, "256")
	c: I16
	testing.expect_value(t, cbor.unmarshal(holding("397fff"), &c, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect_value(t, c.v, -32768)
	d: U32
	testing.expect_value(t, cbor.unmarshal(holding("1affffffff"), &d, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect_value(t, d.v, max(u32))
	expect_refusal_of(t, cbor.unmarshal(holding("1b0000000100000000"), &d, .Cbor, allocator = context.temp_allocator), .Above_Maximum, "2^32")
	f: F32
	testing.expect_value(t, cbor.unmarshal(holding("f93555"), &f, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect_value(t, f.v, 0.333251953125)
	testing.expect_value(t, cbor.unmarshal(holding("fb3ff199999999999a"), &f, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect_value(t, f.v, f32(1.1))
	expect_refusal_of(t, cbor.unmarshal(holding("fb7e37e43c8800759c"), &f, .Cbor, allocator = context.temp_allocator), .Above_Maximum, "1e300")
}

// Tag 0 reads a date-time text with an offset and tag 1 a number of seconds into a `time.Time`, and any other tag
// passes to the item it holds.
@(test)
tags_read_as_the_item_they_hold :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Stamp :: struct {
		v: time.Time,
	}
	stamps := [?]struct {
		hex:  string,
		want: i64, // nanoseconds since the epoch
	} {
		{"c0 74 323031332d30332d32315432303a30343a30305a", 1363896240e9},
		{"c0 78 19 323031332d30332d32315432303a30343a30302b30313a3030", 1363892640e9},
		{"c1 1a514b67b0", 1363896240e9},
		{"c1 fb41d452d9ec200000", 1363896240_500_000_000},
		{"c1 3a0000ffff", -65536e9},
		{"d9d9f7 c1 1a514b67b0", 1363896240e9},
		{"74 323031332d30332d32315432303a30343a30305a", 1363896240e9},
		{"1a514b67b0", 1363896240e9},
	}
	for r in stamps {
		got: Stamp
		e := cbor.unmarshal(holding(r.hex), &got, .Cbor, allocator = context.temp_allocator)
		testing.expectf(t, e == nil && time.to_unix_nanoseconds(got.v) == r.want, "%s: %v, %v", r.hex, e, time.to_unix_nanoseconds(got.v))
	}
	refused := [?]struct {
		hex:  string,
		want: cbor.Refusal,
	}{{"6a 323031332d30332d3231", .Bad_Date_Time}, {"f5", .Expected_Date_Time}, {"80", .Expected_Date_Time}}
	for r in refused {
		got: Stamp
		expect_refusal_of(t, cbor.unmarshal(holding(r.hex), &got, .Cbor, allocator = context.temp_allocator), r.want, r.hex)
	}
	// Other tags pass to their content, which a member of the content's type takes.
	Plain :: struct {
		n: i64,
		s: string,
		l: []u8,
	}
	// tag 100 on a number, tag 37 on a text, tag 55799 on a list.
	got: Plain
	e := cbor.unmarshal(hex("a3 616e d864 07 6173 d825 62 6869 616c d9d9f7 83 01 02 03"), &got, .Cbor, allocator = context.temp_allocator)
	testing.expect_value(t, e, nil)
	testing.expect_value(t, got.n, 7)
	testing.expect_value(t, got.s, "hi")
	testing.expect_value(t, len(got.l), 3)
}

// A definite text string is a span of the item under `borrow_strings`, and a copy otherwise.
@(test)
a_definite_text_is_borrowed_on_request :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Text :: struct {
		v: string,
	}
	src := holding("65 68656c6c6f")
	borrowed, copied: Text
	testing.expect_value(t, cbor.unmarshal(src, &borrowed, .Cbor, {borrow_strings = true}, allocator = context.temp_allocator), nil)
	testing.expect_value(t, cbor.unmarshal(src, &copied, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect_value(t, borrowed.v, "hello")
	testing.expect_value(t, copied.v, "hello")
	whole := uintptr(raw_data(src))
	here := uintptr(raw_data(borrowed.v))
	testing.expect(t, here >= whole && here < whole + uintptr(len(src)), "the borrowed string lies in the item")
	there := uintptr(raw_data(copied.v))
	testing.expect(t, there < whole || there >= whole + uintptr(len(src)), "the copied string lies outside it")
	// A text string in chunks has no span to give, so it is copied under either option.
	chunked: Text
	chunks := holding("7f 6268 65 63 6c6c6f ff")
	testing.expect_value(t, cbor.unmarshal(chunks, &chunked, .Cbor, {borrow_strings = true}, allocator = context.temp_allocator), nil)
	testing.expect_value(t, chunked.v, "hello")
	at := uintptr(raw_data(chunked.v))
	start := uintptr(raw_data(chunks))
	testing.expect(t, at < start || at >= start + uintptr(len(chunks)), "a text in chunks is copied")
}

Circle :: struct {
	r: f64,
}

Square :: struct {
	side: i64,
}

// A union takes the arm of the value's class: a number, a string, a boolean, a map or a list, and a null for a union
// that holds nil.
@(test)
unions_pick_their_arm_by_class :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Scalar :: union {
		i64,
		string,
		bool,
	}
	Shape :: union {
		Circle,
		[]i64,
	}
	Holder :: struct {
		scalar: Scalar,
		shape:  Shape,
	}
	got: Holder
	e := cbor.unmarshal(hex("a2 66 7363616c6172 187b 65 7368617065 a1 61 72 f93e00"), &got, .Cbor, allocator = context.temp_allocator)
	testing.expect_value(t, e, nil)
	testing.expect_value(t, got.scalar.(i64), 123)
	testing.expect_value(t, got.shape.(Circle).r, 1.5)
	got = {}
	e = cbor.unmarshal(hex("a2 66 7363616c6172 62 6869 65 7368617065 82 01 02"), &got, .Cbor, allocator = context.temp_allocator)
	testing.expect_value(t, e, nil)
	testing.expect_value(t, got.scalar.(string), "hi")
	testing.expect_value(t, len(got.shape.([]i64)), 2)
	got = {}
	testing.expect_value(t, cbor.unmarshal(hex("a1 66 7363616c6172 f5"), &got, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect_value(t, got.scalar.(bool), true)
	// A value of a class no arm takes is refused.
	expect_refusal_of(t, cbor.unmarshal(hex("a1 65 7368617065 f5"), &got, .Cbor, allocator = context.temp_allocator), .No_Arm, "bool for a shape")
	// A union with nil takes a null, and an absent member leaves the union as it was.
	Optional :: union {
		Square,
		i64,
	}
	Nilable :: struct {
		o: Optional,
	}
	n := Nilable{Square{4}}
	testing.expect_value(t, cbor.unmarshal(hex("a1 616f f6"), &n, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect(t, n.o == nil, "null reads as nil")
	n = {Square{4}}
	testing.expect_value(t, cbor.unmarshal(hex("a0"), &n, .Cbor, allocator = context.temp_allocator), nil)
	testing.expect_value(t, n.o.(Square).side, 4)
}

// A list of unions of named struct arms, a pointer and a `Maybe` read through the same heads.
@(test)
unions_in_lists_and_pointers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Shape :: union {
		Circle,
		f64,
	}
	Drawing :: struct {
		shapes: []Shape,
		best:   ^Square,
		note:   Maybe(string),
	}
	got: Drawing
	src := hex("a3 66 736861706573 83 a1 6172 f93e00 f93c00 a1 6172 01 6462657374 a1 6473696465 09 646e6f7465 f6")
	e := cbor.unmarshal(src, &got, .Cbor, allocator = context.temp_allocator)
	testing.expect_value(t, e, nil)
	if testing.expect_value(t, len(got.shapes), 3) {
		testing.expect_value(t, got.shapes[0].(Circle).r, 1.5)
		testing.expect_value(t, got.shapes[1].(f64), 1)
		testing.expect_value(t, got.shapes[2].(Circle).r, 1)
	}
	if testing.expect(t, got.best != nil) {
		testing.expect_value(t, got.best.side, 9)
	}
	_, has_note := got.note.?
	testing.expect(t, !has_note)
	// Two arms of one class cannot be told apart, so the plan refuses the union.
	Ambiguous :: union {
		i64,
		f64,
	}
	_, perr := cbor.plan_make(Ambiguous, allocator = context.temp_allocator)
	_, bad := perr.(tape.Bad_Option)
	testing.expectf(t, bad, "got %v", perr)
	_, perr = cbor.plan_make(Drawing, allocator = context.temp_allocator)
	testing.expect_value(t, perr, nil)
}

// A refused value names its place in the item.
@(test)
a_refusal_names_its_path_and_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		id: i64,
	}
	Table :: struct {
		rows: []Row,
	}
	src := hex("a1 64 726f7773 83 a1 6269 64 01 a1 6269 64 02 a1 6269 64 61 78")
	path := make([dynamic]tape.Step, context.temp_allocator)
	got: Table
	e := cbor.unmarshal(src, &got, .Cbor, {path = &path}, allocator = context.temp_allocator)
	expect_refusal_of(t, e, .Expected_Integer, "text for an integer")
	f, _ := e.(tape.Fault)
	testing.expect_value(t, f.at, u64(len(src) - 2))
	if testing.expect_value(t, len(path), 3) {
		testing.expect_value(t, path[0], tape.Step(tape.Name("rows")))
		testing.expect_value(t, path[1], tape.Step(tape.Index(2)))
		testing.expect_value(t, path[2], tape.Step(tape.Name("id")))
	}
}

// The typed read law over random items in every spec and their mutations, and the rows of Appendix A: a read into a
// `testkit.Value` is what the build converts to, and an item the build refuses is refused alike.
@(test)
unmarshal_agrees_with_the_build :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x7ed)
	read_value :: proc(f: ^tape.Format, src: []u8, v: ^testkit.Value, opts: tape.Options, allocator: runtime.Allocator) -> tape.Error {
		spec: cbor.Spec
		for s in cbor.Spec {
			if cbor.as(s) == f {
				spec = s
			}
		}
		return cbor.unmarshal(src, v, spec, opts = opts, allocator = allocator)
	}
	a: testkit.Typed_Agreement
	for _ in 0 ..< testkit.rounds(200) {
		src := random_item()
		defer delete(src)
		for spec in cbor.Spec {
			testkit.unmarshal_agrees(t, cbor.reads(spec), cbor.as(spec), read_value, src, {}, "generated", &a)
		}
		bad := mutated(src)
		defer delete(bad)
		testkit.unmarshal_agrees(t, cbor.reads(.Cbor), cbor.as(.Cbor), read_value, bad, {}, "mutated", &a)
	}
	rows := [?]string {
		"a201020304", "a26161016162820203", "826161a161626163", "a56161614161626142616361436164614461656145",
		"5f42010243030405ff", "7f657374726561646d696e67ff", "9fff", "9f018202039f0405ffff", "9f01820203820405ff",
		"83018202039f0405ff", "83019f0203ff820405", "bf61610161629f0203ffff", "826161bf61626163ff", "bf6346756ef563416d7421ff",
	}
	for r in rows {
		testkit.unmarshal_agrees(t, cbor.reads(.Cbor), cbor.as(.Cbor), read_value, hex(r), {}, r, &a)
	}
	testing.expectf(t, a.read > 50 && a.refused > 50, "%v", a)
}

// A byte string reads into a slice or dynamic array of `u8` as its bytes, a span of the item under `borrow_strings`
// for a slice, else a copy, chunks joined, and a union's arm of `u8`s takes it. Any other value refuses it.
@(test)
byte_strings_read_into_lists_of_bytes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := holding("43010203")
	b: struct {
		v: []u8,
	}
	testing.expect_value(t, cbor.unmarshal(src, &b, allocator = context.temp_allocator), nil)
	testing.expect(t, len(b.v) == 3 && b.v[2] == 3 && raw_data(b.v) != raw_data(src[4:]))
	testing.expect_value(t, cbor.unmarshal(src, &b, read = {borrow_strings = true}, allocator = context.temp_allocator), nil)
	testing.expect(t, len(b.v) == 3 && raw_data(b.v) == raw_data(src[4:]))
	chunks := holding("5f4201024103ff")
	testing.expect_value(t, cbor.unmarshal(chunks, &b, read = {borrow_strings = true}, allocator = context.temp_allocator), nil)
	testing.expect(t, len(b.v) == 3 && b.v[2] == 3 && raw_data(b.v) != raw_data(chunks[5:]))
	d: struct {
		v: [dynamic]u8,
	}
	testing.expect_value(t, cbor.unmarshal(src, &d, read = {borrow_strings = true}, allocator = context.temp_allocator), nil)
	testing.expect(t, len(d.v) == 3 && raw_data(d.v) != raw_data(src[4:]))
	// A list of numbers reads into the same field.
	testing.expect_value(t, cbor.unmarshal(holding("820102"), &b, allocator = context.temp_allocator), nil)
	testing.expect(t, len(b.v) == 2 && b.v[1] == 2)
	u: struct {
		v: union {
			[]u8,
			string,
		},
	}
	testing.expect_value(t, cbor.unmarshal(src, &u, allocator = context.temp_allocator), nil)
	bytes, is_bytes := u.v.([]u8)
	testing.expect(t, is_bytes && len(bytes) == 3)
	s: struct {
		v: string,
	}
	expect_refusal_of(t, cbor.unmarshal(src, &s, allocator = context.temp_allocator), .Expected_String, "a string")
	n: struct {
		v: union {
			string,
			i64,
		},
	}
	expect_refusal_of(t, cbor.unmarshal(src, &n, allocator = context.temp_allocator), .No_Arm, "no arm")
}
