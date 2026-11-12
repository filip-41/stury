// The writers of CBOR: the document writer under each encoding, the token writer's heads, and the typed write and read.
package cbor_tests

import "core:bytes"
import "core:encoding/json"
import "core:io"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import records "../../core/records"
import walktest "../../walktest"
import cbor ".."
import stury_json "../../json"
import model "../../core/model"

@(private)
written :: proc(t: ^testing.T, doc: ^core.Document, enc: cbor.Spec, loc := #caller_location) -> []u8 {
	text, _, err := core.write(doc, {}, cbor.as(enc), allocator = context.temp_allocator)
	walktest.expect_nil(t, err, loc)
	return text
}

@(private)
dumped :: proc(doc: ^core.Document) -> string {
	sb := strings.builder_make(context.temp_allocator)
	dump(&sb, doc, core.ROOT)
	return strings.to_string(sb)
}

@(private)
hex_of :: proc(b: []u8) -> string {
	sb := strings.builder_make(context.temp_allocator)
	hex_text(&sb, b)
	return strings.to_string(sb)[2:]
}

// Every row of Appendix A writes back as its own bytes from a document read from them, copied under `.Cbor` and
// respelled where needed under `.Preferred`. A row that is not in preferred serialization is written in it, and reads
// back as the same value.
@(test)
appendix_a_rows_write_back :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	table, _ := json.parse(transmute([]u8)APPENDIX_A)
	rows := 0
	for row in table.(json.Array) {
		entry := row.(json.Object)
		if entry["hex"].(json.String) == SIMPLE_24 {
			continue
		}
		input := hex(entry["hex"].(json.String))
		doc, err := cbor.build(input, .Cbor)
		if !testing.expectf(t, err == nil, "%s: %v", entry["hex"], err) {
			continue
		}
		testing.expectf(t, string(written(t, &doc, .Cbor)) == string(input), "%s: .Cbor changed the bytes", entry["hex"])
		preferred := written(t, &doc, .Preferred)
		if entry["roundtrip"].(json.Boolean) {
			testing.expectf(t, string(preferred) == string(input), "%s: .Preferred wrote %s", entry["hex"], hex_of(preferred))
		}
		testing.expectf(t, cbor.validate(preferred, .Preferred) == nil, "%s: %s is not preferred", entry["hex"], hex_of(preferred))
		back, berr := cbor.build(preferred, .Cbor)
		walktest.expect_nil(t, berr)
		// `core.equal` holds no NaN equal to itself, so a NaN row is compared by what it reads as.
		same := core.equal(core.Node_Ref{&doc, core.ROOT}, core.Node_Ref{&back, core.ROOT}) || dumped(&doc) == dumped(&back)
		testing.expectf(t, same, "%s: %s reads as another value", entry["hex"], hex_of(preferred))
		rows += 1
	}
	// Every row but the one that is not well-formed.
	testing.expect_value(t, rows, 81)
}

// An item in another serialization is written again in the target's, and an item already in it is copied.
@(test)
items_are_respelled_for_the_encoding :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Row :: struct {
		src, want: string,
		enc:       cbor.Spec,
	}
	rows := [?]Row {
		{"1817", "17", .Preferred},
		{"1900ff", "18ff", .Preferred},
		{"3b0000000000000000", "20", .Preferred},
		{"fb3ff0000000000000", "f93c00", .Preferred},
		{"fb3ff199999999999a", "fb3ff199999999999a", .Preferred},
		{"fa47c35000", "fa47c35000", .Preferred},
		{"fb8000000000000000", "f98000", .Preferred},
		{"fb7ff8000000000000", "f97e00", .Preferred},
		{"9f0102ff", "820102", .Preferred},
		{"bf616101ff", "a1616101", .Preferred},
		{"7f61616162ff", "626162", .Preferred},
		{"5f41014102ff", "420102", .Preferred},
		{"d9000101", "c101", .Preferred},
		{"c2420100", "190100", .Preferred},
		{"a11817 01", "a11701", .Preferred},
		{"a2 6162 01 6161 02", "a2 6162 01 6161 02", .Preferred},
		{"a2 6162 01 6161 02", "a2 6161 02 6162 01", .Deterministic},
		{"a2 20 02 1864 01", "a2 1864 01 20 02", .Deterministic},
		{"a2 1864 01 20 02", "a2 20 02 1864 01", .Length_First},
		{"a2 6162 a2 6162 01 6161 02 6161 02", "a2 6161 02 6162 a2 6161 02 6162 01", .Deterministic},
		{"9f bf 6162 01 6161 02 ff ff", "81 a2 6161 02 6162 01", .Deterministic},
	}
	for r in rows {
		doc, err := cbor.build(hex(r.src), .Cbor)
		if !testing.expectf(t, err == nil, "%s: %v", r.src, err) {
			continue
		}
		got := written(t, &doc, r.enc)
		testing.expectf(t, string(got) == string(hex(r.want)), "%s under %v: want %s, got %s", r.src, r.enc, r.want, hex_of(got))
		testing.expectf(t, cbor.validate(got, r.enc) == nil, "%s under %v: %s is refused", r.src, r.enc, hex_of(got))
	}
}

// A deterministic map whose two members write the same key is refused, and a partial document is no item.
@(test)
unwritable_documents_are_refused :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	doc, err := cbor.build(hex("a2 6161 01 6161 02"), .Cbor, dups = .All)
	walktest.expect_nil(t, err)
	_, _, werr := core.write(&doc, {}, cbor.as(.Deterministic))
	walktest.expect_kind(t, werr, core.Typed_Error_Kind.Unwritable)
	_, _, werr = core.write(&doc, {}, cbor.as(.Cbor))
	walktest.expect_nil(t, werr)
}

// A tag is written back before its item, and a fact CBOR has no place for is dropped and counted.
@(test)
tags_are_written_back :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	doc, err := cbor.build(hex("82 c1 1a514b67b0 d9d9f7 c2 41 01"), .Cbor)
	walktest.expect_nil(t, err)
	text, dropped, werr := core.write(&doc, {}, cbor.as(.Preferred))
	walktest.expect_nil(t, werr)
	testing.expect_value(t, dropped, 0)
	testing.expect_value(t, hex_of(text), "82c11a514b67b0d9d9f701")
	commented, cerr := stury_json.build(transmute([]u8)string(`[1, /* one */ 2]`), .Jsonc)
	walktest.expect_nil(t, cerr)
	text, dropped, werr = core.write(&commented, {}, cbor.as(.Cbor))
	walktest.expect_nil(t, werr)
	testing.expect_value(t, dropped, 1)
	testing.expect_value(t, hex_of(text), "820102")
}

// JSON written as CBOR reads back as the same document, and that CBOR written as JSON reads as the JSON again.
@(test)
json_written_as_cbor_reads_back :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	texts := [?]string {
		`{"a":1,"b":[true,false,null],"c":{"d":"eé\n"},"f":-2.5}`,
		`[0,23,24,255,256,65535,65536,4294967295,4294967296,-1,-24,-25,-4294967297]`,
		`[18446744073709551615,18446744073709551616,-18446744073709551616,-18446744073709551617]`,
		`[100000.0,3.4028234663852886e+38,1e+300,5.960464477539063e-08,-0.0,0.1]`,
		`[123456789012345678901234567890,1.5e400,-2.5e-400]`,
		`{"":[],"x":{},"long key past twenty-four bytes":"value"}`,
	}
	for text in texts {
		src, err := stury_json.build(transmute([]u8)text, .Json)
		if !testing.expectf(t, err == nil, "%s: %v", text, err) {
			continue
		}
		for enc in ([?]cbor.Spec{.Cbor, .Preferred, .Deterministic, .Length_First}) {
			bin := written(t, &src, enc)
			testing.expectf(t, cbor.validate(bin, enc) == nil, "%s under %v: %s is refused", text, enc, hex_of(bin))
			back, berr := cbor.build(bin, .Cbor)
			if !testing.expectf(t, berr == nil, "%s: %v", text, berr) {
				continue
			}
			testing.expectf(t, core.equal(core.Node_Ref{&src, core.ROOT}, core.Node_Ref{&back, core.ROOT}), "%s under %v: %s reads as another value", text, enc, hex_of(bin))
			if enc == .Cbor {
				again, _, jerr := core.write(&back, {}, stury_json.as(.Json))
				walktest.expect_nil(t, jerr)
				round, rerr := stury_json.build(again, .Json)
				walktest.expect_nil(t, rerr)
				testing.expectf(t, core.equal(core.Node_Ref{&src, core.ROOT}, core.Node_Ref{&round, core.ROOT}), "%s: written back as %s", text, again)
			}
		}
	}
}

// A deterministic text written again is the same bytes, whatever order its source had.
@(test)
deterministic_output_stays_deterministic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	src, _ := stury_json.build(transmute([]u8)string(`{"zz":{"b":1,"a":[{"y":2,"x":3}]},"a":0,"m":"n","10":1,"9":2}`), .Json)
	for enc in ([?]cbor.Spec{.Deterministic, .Length_First}) {
		first := written(t, &src, enc)
		testing.expect(t, cbor.validate(first, enc) == nil)
		doc, _ := cbor.build(first, .Cbor)
		testing.expect_value(t, hex_of(written(t, &doc, enc)), hex_of(first))
		testing.expect_value(t, hex_of(written(t, &doc, .Cbor)), hex_of(first))
		tokens := token_text(t, enc, proc(w: ^write.Tokens) {
			write.open_object(w)
			write.key(w, "zz")
			write.value_int(w, 1)
			write.key(w, "a")
			write.open_object(w)
			write.key(w, "b")
			write.value_null(w)
			write.key(w, "a")
			write.value_bool(w, true)
			write.close(w)
			write.key(w, "m")
			write.value_string(w, "n")
			write.close(w)
		})
		testing.expect(t, cbor.validate(tokens, enc) == nil)
		Shuffled :: struct {
			zz:    int,
			a:     map[string]int,
			m:     string,
			ninth: int `cbor:"9"`,
			tenth: int `cbor:"10"`,
		}
		v := Shuffled{zz = 1, a = make(map[string]int), m = "n"}
		v.a["q"], v.a["p"] = 1, 2
		typed_text, err := cbor.marshal(v, enc)
		walktest.expect_nil(t, err)
		testing.expectf(t, cbor.validate(typed_text, enc) == nil, "%v: %s", enc, hex_of(typed_text))
	}
}

// The bench fixtures, when they are generated: each reads back from what it writes, under `.Cbor` as its own bytes,
// and each JSON fixture written as CBOR reads back as the same document.
@(test)
fixtures_write_back :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for name in ([?]string{"logs", "wide", "nested", "documents"}) {
		path := strings.concatenate({"bench/fixtures/", name, ".cbor"})
		src, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			log.infof("%s: not generated", path)
			continue
		}
		doc, err := cbor.build(src, .Cbor)
		walktest.expect_nil(t, err)
		testing.expectf(t, string(written(t, &doc, .Cbor)) == string(src), "%s: .Cbor changed the bytes", name)
		for enc in ([?]cbor.Spec{.Preferred, .Deterministic}) {
			bin := written(t, &doc, enc)
			testing.expectf(t, cbor.validate(bin, enc) == nil, "%s: not %v", name, enc)
			back, _ := cbor.build(bin, .Cbor)
			testing.expectf(t, same_document(&doc, &back), "%s under %v: another value", name, enc)
		}
		json_src, json_err := os.read_entire_file(strings.concatenate({"bench/fixtures/", name, ".json"}), context.temp_allocator)
		if json_err != nil {
			continue
		}
		jdoc, _ := stury_json.build(json_src, .Json)
		bin := written(t, &jdoc, .Preferred)
		back, _ := cbor.build(bin, .Cbor)
		testing.expectf(t, same_document(&jdoc, &back), "%s.json: another value", name)
	}
}

// Whether two large documents hold the same value, which `core.equal` judges too slowly for them: a deterministic text
// spells each value one way.
@(private)
same_document :: proc(a, b: ^core.Document) -> bool {
	x, _, xerr := core.write(a, {}, cbor.as(.Deterministic), allocator = context.temp_allocator)
	y, _, yerr := core.write(b, {}, cbor.as(.Deterministic), allocator = context.temp_allocator)
	return xerr == nil && yerr == nil && string(x) == string(y)
}

@(private)
token_text :: proc(t: ^testing.T, enc: cbor.Spec, calls: proc(w: ^write.Tokens), stream := io.Stream{}, loc := #caller_location) -> []u8 {
	w: write.Tokens
	testing.expect_value(t, write.tokens_init(&w, cbor.as(enc), {}, context.temp_allocator, stream), core.Typed_Error_Kind.None, loc)
	calls(&w)
	text, err := write.tokens_finish(&w)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None, loc)
	return text
}

// A container's head holds its count once it closes: one byte below 24 items and wider from 24, nested or not.
@(test)
token_heads_are_patched :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for n in ([?]int{0, 23, 24, 255, 256, 70000}) {
		w: write.Tokens
		write.tokens_init(&w, cbor.as(.Preferred), {}, context.temp_allocator)
		write.open_array(&w)
		write.open_object(&w)
		for i in 0 ..< n {
			write.key(&w, string([]u8{'a' + u8(i % 26), 'a' + u8(i / 26 % 26), 'a' + u8(i / 676 % 26), 'a' + u8(i / 17576 % 26)}))
			write.value_int(&w, i64(i))
		}
		write.close(&w)
		for i in 0 ..< n {
			write.value_uint(&w, u64(i))
		}
		write.close(&w)
		text, err := write.tokens_finish(&w)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		testing.expectf(t, cbor.validate(text, .Preferred) == nil, "%d items", n)
		doc, _ := cbor.build(text, .Cbor)
		testing.expect_value(t, core.length(&doc, core.ROOT), n + 1)
		testing.expect_value(t, core.length(&doc, core.Node_Index(1)), n)
	}
	text := token_text(t, .Preferred, proc(w: ^write.Tokens) {
		write.open_object(w)
		write.key(w, "b")
		write.value_bytes(w, {1, 2})
		write.key(w, "n")
		write.value_of(w, core.number_text("18446744073709551616", context.temp_allocator))
		write.key(w, "f")
		write.value_float(w, 1.5)
		write.key(w, "t")
		write.value_tagged(w, "1979-05-27", "date")
		write.close(w)
	})
	testing.expect_value(t, hex_of(text), "a46162420102616ec2490100000000000000006166f93e0061746a313937392d30352d3237")
}

// A stream write that must flush with a container open writes the open containers indefinite under `.Cbor`, and refuses
// under an encoding that has no indefinite length. One that fits the buffer keeps its counts.
@(test)
token_streams_fall_back_to_indefinite :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Case :: struct {
		n:    int,
		enc:  cbor.Spec,
		want: core.Typed_Error_Kind,
		lead: u8,
	}
	for c in ([?]Case{{100, .Cbor, .None, 0x81}, {100000, .Cbor, .None, 0x9f}, {100000, .Preferred, .Unsupported, 0}}) {
		buf: bytes.Buffer
		bytes.buffer_init_allocator(&buf, 0, 0, context.temp_allocator)
		w: write.Tokens
		write.tokens_init(&w, cbor.as(c.enc), {}, context.temp_allocator, bytes.buffer_to_stream(&buf))
		write.open_array(&w)
		write.open_array(&w)
		for i in 0 ..< c.n {
			write.value_int(&w, i64(i))
		}
		write.close(&w)
		write.close(&w)
		_, err := write.tokens_finish(&w)
		testing.expect_value(t, err.kind, c.want)
		if c.want != .None {
			continue
		}
		text := bytes.buffer_to_bytes(&buf)
		testing.expect_value(t, text[0], c.lead)
		testing.expect(t, cbor.validate(text, .Cbor) == nil)
		doc, _ := cbor.build(text, .Cbor)
		testing.expect_value(t, core.length(&doc, core.Node_Index(1)), c.n)
	}
}

@(private)
Colour :: enum {
	Red,
	Green,
	Blue,
}

@(private)
Shape :: union {
	int,
	string,
}

@(private)
Point :: struct {
	x: int,
	y: string,
}

// A field of every kind the typed read and write take.
@(private)
Every :: struct {
	text:                             string,
	flag:                             bool,
	wide:                             b32,
	tiny:                             i8,
	short:                            i16,
	mid:                              i32,
	long:                             i64,
	utiny:                            u8,
	ushort:                           u16,
	umid:                             u32,
	ulong:                            u64,
	single:                           f32,
	double:                           f64,
	colour:                           Colour,
	colours:                          bit_set[Colour],
	ptr:                              ^int,
	maybe:                            Maybe(int),
	none:                             Maybe(string),
	shape:                            Shape,
	other:                            Shape,
	point:                            Point,
	list:                             []int,
	grow:                             [dynamic]string,
	fixed:                            [3]u16,
	capped:                           [dynamic; 4]int,
	table:                            map[string]int,
	keyed:                            map[int]string,
	value:                            core.Value,
	scalar:                           typed.Scalar,
	number:                           core.Number,
	digits:                           core.Number_Text,
	raw:                              typed.Raw,
	blob:                             typed.Bytes,
	c:                                cstring,
	a_member_name_of_thirty_bytes__: int,
}

@(private)
every :: proc() -> Every {
	seven := new_clone(7, context.temp_allocator)
	capped: [dynamic; 4]int
	append(&capped, 1, 2)
	grow := make([dynamic]string, context.temp_allocator)
	append(&grow, "g", "rows")
	// A built value holds no byte string, so the object's members are a number and digits past 64 bits.
	members := core.new_object()
	core.object_put(members, "k", -3)
	core.object_put(members, "wide", core.number_text("123456789012345678901234567890"))
	items := core.new_array(3)
	core.array_append(items, "s")
	core.array_append(items, members)
	core.array_append(items, 2.5)
	list := make([]int, 3, context.temp_allocator)
	list[0], list[1], list[2] = 1, 24, 1000
	table := make(map[string]int, context.temp_allocator)
	table["a"], table["bb"] = 1, 2
	keyed := make(map[int]string, context.temp_allocator)
	keyed[-1], keyed[100] = "minus", "hundred"
	blob := make(typed.Bytes, 3, context.temp_allocator)
	blob[0], blob[1], blob[2] = 0, 1, 255
	return Every {
		text = "héllo, a text past the short case",
		flag = true,
		wide = true,
		tiny = -100,
		short = -30000,
		mid = 2000000000,
		long = min(i64),
		utiny = 255,
		ushort = 65535,
		umid = max(u32),
		ulong = max(u64),
		single = 0.1,
		double = -1e300,
		colour = .Blue,
		colours = {.Red, .Blue},
		ptr = seven,
		maybe = 3,
		shape = "arm",
		other = 12,
		point = {-4, "y"},
		list = list,
		grow = grow,
		fixed = {1, 2, 3},
		capped = capped,
		table = table,
		keyed = keyed,
		value = items,
		scalar = u64(max(u64)),
		number = core.Number{u64(1 << 40), .Int},
		digits = core.number_text("123456789012345678901234567890")^,
		raw = typed.Raw(string(hex("a1 6161 82 01 02"))),
		blob = blob,
		c = "c string",
		a_member_name_of_thirty_bytes__ = 30,
	}
}

@(private)
expect_every :: proc(t: ^testing.T, got, want: ^Every, form: cbor.Struct_Form, loc := #caller_location) {
	testing.expect_value(t, got.text, want.text, loc)
	testing.expect_value(t, got.flag, want.flag, loc)
	testing.expect_value(t, got.wide, want.wide, loc)
	testing.expect_value(t, got.tiny, want.tiny, loc)
	testing.expect_value(t, got.short, want.short, loc)
	testing.expect_value(t, got.mid, want.mid, loc)
	testing.expect_value(t, got.long, want.long, loc)
	testing.expect_value(t, got.utiny, want.utiny, loc)
	testing.expect_value(t, got.ushort, want.ushort, loc)
	testing.expect_value(t, got.umid, want.umid, loc)
	testing.expect_value(t, got.ulong, want.ulong, loc)
	testing.expect_value(t, got.single, want.single, loc)
	testing.expect_value(t, got.double, want.double, loc)
	testing.expect_value(t, got.colour, want.colour, loc)
	testing.expect_value(t, got.colours, want.colours, loc)
	testing.expect(t, got.ptr != nil && got.ptr^ == want.ptr^, loc = loc)
	testing.expect_value(t, got.maybe, want.maybe, loc)
	testing.expect_value(t, got.none, want.none, loc)
	testing.expect_value(t, got.shape, want.shape, loc)
	testing.expect_value(t, got.other, want.other, loc)
	testing.expect_value(t, got.point, want.point, loc)
	testing.expect_value(t, len(got.list), len(want.list), loc)
	for x, i in want.list {
		testing.expect_value(t, got.list[i], x, loc)
	}
	testing.expect_value(t, len(got.grow), len(want.grow), loc)
	for x, i in want.grow {
		testing.expect_value(t, got.grow[i], x, loc)
	}
	testing.expect_value(t, got.fixed, want.fixed, loc)
	testing.expect_value(t, len(got.capped), len(want.capped), loc)
	testing.expect_value(t, len(got.table), len(want.table), loc)
	for k, v in want.table {
		testing.expect_value(t, got.table[k], v, loc)
	}
	testing.expect_value(t, len(got.keyed), len(want.keyed), loc)
	for k, v in want.keyed {
		testing.expect_value(t, got.keyed[k], v, loc)
	}
	testing.expectf(t, core.equal(got.value, want.value), "%v: value %v", form, got.value, loc = loc)
	testing.expect_value(t, got.scalar, want.scalar, loc)
	testing.expect_value(t, got.number, want.number, loc)
	testing.expect_value(t, got.digits.text, want.digits.text, loc)
	testing.expect_value(t, hex_of(transmute([]u8)string(got.raw)), hex_of(transmute([]u8)string(want.raw)), loc)
	testing.expect_value(t, hex_of(cast([]u8)got.blob), hex_of(cast([]u8)want.blob), loc)
	testing.expect_value(t, string(got.c), string(want.c), loc)
	testing.expect_value(t, got.a_member_name_of_thirty_bytes__, want.a_member_name_of_thirty_bytes__, loc)
}

// A value of every kind written in either struct form reads back as itself, through a plan or through none.
@(test)
typed_values_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	want := every()
	for form in cbor.Struct_Form {
		for enc in ([?]cbor.Spec{.Cbor, .Deterministic}) {
			opts := cbor.Options{structs = form}
			text, err := cbor.marshal(want, enc, opts)
			if !testing.expectf(t, err == nil, "%v %v: %v", form, enc, err) {
				continue
			}
			testing.expectf(t, cbor.validate(text, .Preferred if enc == .Cbor else enc) == nil, "%v %v: %s", form, enc, hex_of(text))
			got: Every
			rerr := cbor.unmarshal(text, enc, &got, opts)
			testing.expectf(t, rerr == nil, "%v %v: %v", form, enc, rerr)
			expect_every(t, &got, &want, form)
			plan, perr := cbor.plan_make(Every, enc, opts, reads = cbor.reads(.Cbor))
			walktest.expect_nil(t, perr)
			again: Every
			walktest.expect_nil(t, cbor.unmarshal(text, enc, &again, &plan))
			expect_every(t, &again, &want, form)
			planned, merr := cbor.marshal(want, &plan)
			walktest.expect_nil(t, merr)
			testing.expect_value(t, hex_of(planned), hex_of(text))
		}
	}
}

// A struct is a map by name or an array by position, and either reads into it whatever the plan's form.
@(test)
struct_forms_read_either_way :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Pair :: struct {
		a: int,
		b: string `cbor:",omitempty"`,
	}
	by_name, _ := cbor.marshal(Pair{1, "x"}, .Cbor)
	testing.expect_value(t, hex_of(by_name), "a261610161626178")
	by_place, _ := cbor.marshal(Pair{1, "x"}, .Cbor, {structs = .Array})
	testing.expect_value(t, hex_of(by_place), "82016178")
	omitted, _ := cbor.marshal(Pair{a = 1}, .Cbor)
	testing.expect_value(t, hex_of(omitted), "a1616101")
	kept, _ := cbor.marshal(Pair{a = 1}, .Cbor, {structs = .Array})
	testing.expect_value(t, hex_of(kept), "820160")
	for text in ([?][]u8{by_name, by_place}) {
		for form in cbor.Struct_Form {
			got: Pair
			walktest.expect_nil(t, cbor.unmarshal(text, .Cbor, &got, {structs = form}))
			testing.expect_value(t, got, Pair{1, "x"})
		}
	}
	longer: Pair
	walktest.expect_nil(t, cbor.unmarshal(hex("83 02 6179 f6"), .Cbor, &longer))
	testing.expect_value(t, longer, Pair{2, "y"})
}

// A model's dump writes CBOR through the same walk, leaving a member out of a map and writing null in its place in an
// array.
@(test)
dumps_reach_cbor :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Pet :: struct {
		name: string,
		kin:  Maybe(string) `model:"optional"`,
		age:  int `model:"optional"`,
	}
	reg: model.Registry
	defer model.destroy(&reg)
	m, err := model.compile(&reg, Pet, cbor.checks(.Cbor))
	walktest.expect_nil(t, err)
	p := Pet{name = "rex", age = 3}
	text, derr := model.dump(&m, &p, {exclude_none = true})
	walktest.expect_nil(t, derr)
	testing.expect_value(t, hex_of(text), "a2646e616d65637265786361676503")
	by_place, perr := model.compile(&reg, Pet, cbor.checks(.Cbor, {structs = .Array}))
	walktest.expect_nil(t, perr)
	text, derr = model.dump(&by_place, &p, {exclude_none = true})
	walktest.expect_nil(t, derr)
	testing.expect_value(t, hex_of(text), "8363726578f603")
}

// Records written by a CBOR plan are a sequence of items with nothing between them.
@(test)
records_write_a_sequence :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Row :: struct {
		id:   int,
		name: string,
	}
	plan, _ := cbor.plan_make(Row)
	rows := []Row{{1, "a"}, {2, "b"}}
	text, err := records.marshal(rows, &plan, cbor.as(.Cbor), .Concatenated)
	walktest.expect_nil(t, err)
	testing.expect_value(t, hex_of(text), "a262696401646e616d656161a262696402646e616d656162")
}

// A typed read takes a key whose bytes the plan holds without a lookup, and every other key, out of order, unknown, with
// a longer head than the shortest or not valid UTF-8, through the lookup, which reads and judges it alike.
@(test)
keys_read_by_their_bytes_or_by_lookup :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Keys :: struct {
		a:                         int,
		a_name_past_sixteen_bytes: int,
		b:                         string,
	}
	LONG :: "7819 615f6e616d655f706173745f7369787465656e5f6279746573"
	X15 :: "6f 787878787878787878787878787878"
	want := Keys{1, 2, "x"}
	in_order, _ := cbor.marshal(want, .Cbor)
	testing.expect_value(t, hex_of(in_order), hex_of(hex("a3 6161 01 " + LONG + " 02 6162 6178")))
	for text in ([?]string{"a3 6161 01 " + LONG + " 02 6162 6178", "a4 6162 6178 617a 05 " + LONG + " 02 6161 01", "a3 6161 01 6162 6178 " + LONG + " 02"}) {
		got: Keys
		testing.expectf(t, cbor.unmarshal(hex(text), .Cbor, &got) == nil && got == want, "%s: %v", text, got)
	}
	longer: Keys
	walktest.expect_nil(t, cbor.unmarshal(hex("a2 780161 07 6162 " + X15), .Cbor, &longer))
	testing.expect_value(t, longer, Keys{a = 7, b = "xxxxxxxxxxxxxxx"})
	strict: Keys
	testing.expect(t, cbor.unmarshal(hex("a2 780161 07 6162 " + X15), .Preferred, &strict) != nil)
	// A member whose name is no UTF-8 has no key bytes in the plan, so the walk reads the key and refuses it.
	Pair :: struct {
		a: int "cbor:\"\xff\"",
		b: string,
	}
	plan, perr := cbor.plan_make(Pair)
	walktest.expect_nil(t, perr)
	pair: Pair
	testing.expect(t, cbor.unmarshal(hex("a2 61ff 01 6162 " + X15), .Cbor, &pair, &plan) != nil)
}
