// Typed XML unmarshal tests: structs, attributes, `$text`/`#text`, repeated elements, maps, Maybe, unions, Raw,
// defaults, refusals, Budget, Options.scratch, OOM safety, deep nesting, and marshal -> unmarshal round-trip parity.
package xml_tests

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

@(private = "file")
Color :: enum u8 {
	Red,
	Green,
	Blue,
}

@(private = "file")
Perm :: enum u8 {
	Read,
	Write,
	Exec,
}

@(private = "file")
Perms :: bit_set[Perm; u8]

@(test)
basic_and_nested_structs_and_primitives :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	Primitives :: struct {
		flag:    bool,
		flag32:  b32,
		i8_v:    i8,
		i16_v:   i16,
		i32_v:   i32,
		i64_v:   i64,
		u8_v:    u8,
		u16_v:   u16,
		u32_v:   u32,
		u64_v:   u64,
		f32_v:   f32,
		f64_v:   f64,
		neg_z:   f64,
		text:    string,
		cdata:   string,
		ent:     string,
		bytes:   []u8,
		color:   Color,
		perms:   Perms,
		stamp:   time.Time,
		aliased: string `xml:"renamed"`,
		shared:  int    `stury:"shared_val"`,
		skipped: string `xml:"-"`,
		nested:  struct {
			k: string,
			n: int,
		},
	}
	Doc :: struct {
		root: Primitives,
	}

	src := `<!DOCTYPE root [<!ENTITY greet "hi &amp; bye">]>
<root>
	<flag>true</flag>
	<flag32>false</flag32>
	<i8_v>-128</i8_v>
	<i16_v>32767</i16_v>
	<i32_v>-2147483648</i32_v>
	<i64_v>-9223372036854775808</i64_v>
	<u8_v>255</u8_v>
	<u16_v>65535</u16_v>
	<u32_v>4294967295</u32_v>
	<u64_v>18446744073709551615</u64_v>
	<f32_v>1.5</f32_v>
	<f64_v>-2.25e2</f64_v>
	<neg_z>-0</neg_z>
	<text>a<!--c-->b &lt; c</text>
	<cdata><![CDATA[<raw>&]]></cdata>
	<ent>&greet;</ent>
	<bytes>1</bytes>
	<bytes>65</bytes>
	<bytes>255</bytes>
	<color>Green</color>
	<perms>Read</perms>
	<perms>Exec</perms>
	<stamp>2024-05-01T12:30:00Z</stamp>
	<renamed>custom</renamed>
	<shared_val>77</shared_val>
	<skipped>ignored</skipped>
	<nested><k>inner</k><n>9</n></nested>
</root>`

	for borrow in ([]bool{false, true}) {
		got: Doc
		err := xml.unmarshal(transmute([]u8)string(src), &got, read = {borrow_strings = borrow}, allocator = context.temp_allocator)
		testing.expect_value(t, err, nil)
		r := got.root
		testing.expect_value(t, r.flag, true)
		testing.expect_value(t, r.flag32, b32(false))
		testing.expect_value(t, r.i8_v, i8(-128))
		testing.expect_value(t, r.i16_v, i16(32767))
		testing.expect_value(t, r.i32_v, min(i32))
		testing.expect_value(t, r.i64_v, min(i64))
		testing.expect_value(t, r.u8_v, u8(255))
		testing.expect_value(t, r.u16_v, max(u16))
		testing.expect_value(t, r.u32_v, max(u32))
		testing.expect_value(t, r.u64_v, max(u64))
		testing.expect_value(t, r.f32_v, f32(1.5))
		testing.expect_value(t, r.f64_v, -225.0)
		testing.expect(t, r.neg_z == 0 && math.sign_bit(r.neg_z))
		testing.expect_value(t, r.text, "ab < c")
		testing.expect_value(t, r.cdata, "<raw>&")
		testing.expect_value(t, r.ent, "hi & bye")
		if testing.expect_value(t, len(r.bytes), 3) {
			testing.expect_value(t, r.bytes[0], u8(1))
			testing.expect_value(t, r.bytes[1], u8(65))
			testing.expect_value(t, r.bytes[2], u8(255))
		}
		testing.expect_value(t, r.color, Color.Green)
		testing.expect_value(t, r.perms, Perms{.Read, .Exec})
		testing.expect_value(t, time.to_unix_nanoseconds(r.stamp), 1_714_566_600_000_000_000)
		testing.expect_value(t, r.aliased, "custom")
		testing.expect_value(t, r.shared, 77)
		testing.expect_value(t, r.skipped, "")
		testing.expect_value(t, r.nested.k, "inner")
		testing.expect_value(t, r.nested.n, 9)
	}

	// Plan validation: matching plan succeeds, wrong type plan returns Bad_Option{"plan"}.
	plan, perr := xml.plan_make(Doc)
	testing.expect_value(t, perr, nil)
	defer xml.plan_destroy(&plan)
	planned: Doc
	testing.expect_value(t, xml.unmarshal(transmute([]u8)string(src), &planned, read = {plan = &plan}, allocator = context.temp_allocator), nil)
	testing.expect_value(t, planned.root.nested.n, 9)

	Other :: struct {
		x: int,
	}
	other: Other
	testing.expect_value(t, xml.unmarshal(transmute([]u8)string(`<x>1</x>`), &other, read = {plan = &plan}), xml.Error(xml.Bad_Option{"plan"}))

	// Copied empty strings are the zero string (no allocation to leak).
	Empty_S :: struct {
		r: struct {
			s: string,
			l: []string,
		},
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	es: Empty_S
	testing.expect_value(t, xml.unmarshal(transmute([]u8)string(`<r><s/><l/><l>a</l></r>`), &es, allocator = alloc), nil)
	testing.expect(t, raw_data(es.r.s) == nil && raw_data(es.r.l[0]) == nil && es.r.l[1] == "a")
	delete(es.r.s, alloc)
	for item in es.r.l {
		delete(item, alloc)
	}
	delete(es.r.l, alloc)
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
repeated_elements_slices_dynamic_and_fixed_arrays :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	Item :: struct {
		id:   int,
		name: string,
	}
	Doc :: struct {
		r: struct {
			item:  []Item,
			tag:   [dynamic]string,
			fixed: [3]int,
			rgb:   [Color]int,
			mid:   string,
		},
	}

	// Non-adjacent repeated elements preserve document order.
	src := `<r><item id="1"><name>a</name></item><tag>t1</tag><mid>center</mid><item id="2"><name>b</name></item><tag>t2</tag><fixed>10</fixed><fixed>20</fixed><fixed>30</fixed><rgb>1</rgb><rgb>2</rgb><rgb>3</rgb></r>`
	for arr_mode in ([]xml.Xml_Arrays{.Auto, .Always}) {
		for infer in ([]bool{false, true}) {
			got: Doc
			err := xml.unmarshal(
				transmute([]u8)string(src),
				&got,
				opts = {format = xml.Xml_Options{infer = infer, arrays = arr_mode}},
				allocator = context.temp_allocator,
			)
			testing.expect_value(t, err, nil)
			testing.expect_value(t, got.r.mid, "center")
			if testing.expect_value(t, len(got.r.item), 2) {
				testing.expect_value(t, got.r.item[0], Item{1, "a"})
				testing.expect_value(t, got.r.item[1], Item{2, "b"})
			}
			if testing.expect_value(t, len(got.r.tag), 2) {
				testing.expect_value(t, got.r.tag[0], "t1")
				testing.expect_value(t, got.r.tag[1], "t2")
			}
			testing.expect_value(t, got.r.fixed, [3]int{10, 20, 30})
			testing.expect_value(t, got.r.rgb, [Color]int{.Red = 1, .Green = 2, .Blue = 3})
		}
	}

	// Duplicate policy: .Default/.First take first scalar, .Last takes last scalar, .Refuse rejects scalar dups but allows slice dups.
	Dup_Doc :: struct {
		r: struct {
			x:    int,
			list: []int,
		},
	}
	dup_src := transmute([]u8)string(`<r><x>1</x><x>2</x><list>10</list><list>20</list></r>`)
	d_def: Dup_Doc
	testing.expect_value(t, xml.unmarshal(dup_src, &d_def, allocator = context.temp_allocator), nil)
	testing.expect_value(t, d_def.r.x, 1)
	testing.expect_value(t, len(d_def.r.list), 2)

	d_last: Dup_Doc
	testing.expect_value(t, xml.unmarshal(dup_src, &d_last, opts = {dups = .Last}, allocator = context.temp_allocator), nil)
	testing.expect_value(t, d_last.r.x, 2)

	d_ref: Dup_Doc
	ref_err := xml.unmarshal(dup_src, &d_ref, opts = {dups = .Refuse}, allocator = context.temp_allocator)
	rf, is_rf := ref_err.(tape.Fault)
	testing.expect(t, is_rf && rf.kind == .Duplicate_Key)

	// Under .Refuse, repeated elements targeting a slice STILL succeed!
	d_ok: Dup_Doc
	testing.expect_value(t, xml.unmarshal(transmute([]u8)string(`<r><x>5</x><list>10</list><list>20</list></r>`), &d_ok, opts = {dups = .Refuse}, allocator = context.temp_allocator), nil)
	testing.expect_value(t, d_ok.r.x, 5)
	testing.expect_value(t, len(d_ok.r.list), 2)

	// Fixed array Too_Few and Too_Many.
	Fixed_Only :: struct {
		r: struct {
			a: [2]int,
		},
	}
	fo: Fixed_Only
	path := make([dynamic]tape.Step, context.temp_allocator)
	testkit.expect_typed_refusal(t, xml.unmarshal(transmute([]u8)string(`<r><a>1</a></r>`), &fo, read = {path = &path}, allocator = context.temp_allocator), .Too_Few, 6)
	testkit.expect_path(t, path[:], {"r", "a"})

	testkit.expect_typed_refusal(t, xml.unmarshal(transmute([]u8)string(`<r><a>1</a><a>2</a><a>3</a></r>`), &fo, read = {path = &path}, allocator = context.temp_allocator), .Too_Many, 22)
	testkit.expect_path(t, path[:], {"r", "a", 2})
}

@(test)
attributes_text_content_and_mixed_content :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Both `$text` and `#text` tags work on leaf elements with attributes, empty elements, and mixed content.
	Price :: struct {
		currency: string,
		amount:   f64 `xml:"$text"`,
	}
	Hash_Node :: struct {
		code: int,
		body: Maybe(string) `xml:"#text"`,
	}
	Mixed :: struct {
		id:   int,
		b:    string,
		runs: []string `xml:"$text"`,
	}
	Empty_Attr :: struct {
		k:   string,
		opt: Maybe(int),
		ptr: ^int,
	}
	Doc :: struct {
		root: struct {
			price: Price,
			hash:  Hash_Node,
			mixed: Mixed,
			empty: Empty_Attr,
		},
	}

	src := `<root xmlns="http://example.com/ns">
		<price currency="USD">19.95</price>
		<hash code="&#45;&#55;">hello &amp; world</hash>
		<mixed id="3">left<b>mid</b>right</mixed>
		<empty k="v" opt="42" ptr="7"/>
	</root>`

	got: Doc
	testing.expect_value(t, xml.unmarshal(transmute([]u8)string(src), &got, read = {refuse_unknown = true}, allocator = context.temp_allocator), nil)
	testing.expect_value(t, got.root.price, Price{"USD", 19.95})
	testing.expect_value(t, got.root.hash.code, -7)
	testing.expect_value(t, got.root.hash.body, Maybe(string)("hello & world"))
	testing.expect_value(t, got.root.mixed.id, 3)
	testing.expect_value(t, got.root.mixed.b, "mid")
	if testing.expect_value(t, len(got.root.mixed.runs), 2) {
		testing.expect_value(t, got.root.mixed.runs[0], "left")
		testing.expect_value(t, got.root.mixed.runs[1], "right")
	}
	testing.expect_value(t, got.root.empty.k, "v")
	testing.expect_value(t, got.root.empty.opt, Maybe(int)(42))
	testing.expect(t, got.root.empty.ptr != nil && got.root.empty.ptr^ == 7)

	// Real unknown attribute fails refuse_unknown while xmlns did not.
	path := make([dynamic]tape.Step, context.temp_allocator)
	err := xml.unmarshal(transmute([]u8)string(`<root><empty k="v" extra="9"/></root>`), &got, read = {refuse_unknown = true, path = &path}, allocator = context.temp_allocator)
	testkit.expect_typed_refusal(t, err, .Unknown_Field, 19)
	testkit.expect_path(t, path[:], {"root", "empty", "extra"})
}

@(test)
maps_maybe_pointers_unions_and_raw :: proc(t: ^testing.T) {
	testkit.deadline(t)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	Val_U :: union {
		int,
		bool,
		string,
	}
	Pair_A :: struct {
		items: [dynamic]int,
		label: string,
		count: int,
	}
	Pair_B :: struct {
		items: [dynamic]int,
		label: string,
	}
	Box_U :: union {
		Pair_A,
		Pair_B,
	}
	Item :: struct {
		id: int,
	}
	Doc :: struct {
		r: struct {
			scores:  map[string]int,
			grouped: map[string][]int,
			opt_hit: Maybe(int),
			opt_nil: Maybe(int),
			opt_att: Maybe(Item),
			ptr_hit: ^int,
			ptr_nil: ^int,
			scalar:  Val_U,
			box:     Box_U,
			raw_el:  xml.Raw,
			raw_txt: xml.Raw,
		},
	}

	src := `<r>
		<scores><alice>10</alice><bob>20</bob></scores>
		<grouped><a>1</a><a>2</a><b>3</b></grouped>
		<opt_hit>99</opt_hit>
		<opt_nil/>
		<opt_att id="5"/>
		<ptr_hit>123</ptr_hit>
		<ptr_nil/>
		<scalar>hello</scalar>
		<box><items>10</items><items>20</items><label>win</label><count>not_int</count></box>
		<raw_el k="1"><b>x</b></raw_el>
		<raw_txt>a &amp; b</raw_txt>
	</r>`

	got: Doc
	path := make([dynamic]tape.Step, alloc)
	defer delete(path)
	testing.expect_value(t, xml.unmarshal(transmute([]u8)string(src), &got, read = {path = &path}, allocator = alloc), nil)
	// Path must remain empty even though Pair_A failed inside Box_U before Pair_B succeeded!
	testing.expect_value(t, len(path), 0)

	testing.expect_value(t, got.r.scores["alice"], 10)
	testing.expect_value(t, got.r.scores["bob"], 20)
	if testing.expect_value(t, len(got.r.grouped["a"]), 2) {
		testing.expect_value(t, got.r.grouped["a"][0], 1)
		testing.expect_value(t, got.r.grouped["a"][1], 2)
	}
	testing.expect_value(t, len(got.r.grouped["b"]), 1)
	testing.expect_value(t, got.r.grouped["b"][0], 3)
	testing.expect_value(t, got.r.opt_hit, Maybe(int)(99))
	testing.expect_value(t, got.r.opt_nil, Maybe(int)(nil))
	testing.expect_value(t, got.r.opt_att, Maybe(Item)(Item{id = 5}))
	testing.expect(t, got.r.ptr_hit != nil && got.r.ptr_hit^ == 123)
	testing.expect(t, got.r.ptr_nil == nil)
	testing.expect_value(t, got.r.scalar, Val_U("hello"))
	pb, is_pb := got.r.box.(Pair_B)
	if testing.expect(t, is_pb) {
		testing.expect_value(t, pb.label, "win")
		if testing.expect_value(t, len(pb.items), 2) {
			testing.expect_value(t, pb.items[0], 10)
			testing.expect_value(t, pb.items[1], 20)
		}
		// Returned container allocator works for caller mutations!
		append(&pb.items, 30)
		testing.expect_value(t, len(pb.items), 3)
		delete(pb.items)
		delete(pb.label, alloc)
	}
	testing.expect_value(t, string(got.r.raw_el), `<raw_el k="1"><b>x</b></raw_el>`)
	testing.expect_value(t, string(got.r.raw_txt), `a &amp; b`)

	// Free all caller-owned allocations and verify zero leaks!
	for k in got.r.scores {
		delete(k, alloc)
	}
	delete(got.r.scores)
	for k, v in got.r.grouped {
		delete(k, alloc)
		delete(v, alloc)
	}
	delete(got.r.grouped)
	free(got.r.ptr_hit, alloc)
	if sv, is_s := got.r.scalar.(string); is_s {
		delete(sv, alloc)
	}
	delete(string(got.r.raw_el), alloc)
	delete(string(got.r.raw_txt), alloc)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
absent_fields_keep_defaults_and_required_fields :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	Row :: struct {
		a:   i64,
		b:   string,
		opt: Maybe(int),
		c:   i64 `xml:"c,required"`,
	}
	Doc :: struct {
		r: Row,
	}

	got := Doc{r = {a = 7, b = "kept", opt = 55, c = 0}}
	err := xml.unmarshal(transmute([]u8)string(`<r><c>3</c><extra>ignored</extra></r>`), &got, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, got.r, Row{a = 7, b = "kept", opt = 55, c = 3})

	// Missing required field returns .Missing_Field with exact path and restores target!
	path := make([dynamic]tape.Step, context.temp_allocator)
	before := Doc{r = {a = 7, b = "kept", opt = 55, c = 9}}
	cur := before
	err = xml.unmarshal(transmute([]u8)string(`<r><a>1</a></r>`), &cur, read = {path = &path}, allocator = context.temp_allocator)
	f, is_f := err.(tape.Fault)
	testing.expect(t, is_f && f.kind == .Refused && xml.Typed_Refusal(f.detail) == .Missing_Field)
	testkit.expect_path(t, path[:], {"r", "c"})
	testing.expect_value(t, cur, before)

	// Missing required field on empty element `<r/>` is also caught.
	err = xml.unmarshal(transmute([]u8)string(`<r/>`), &cur, read = {path = &path}, allocator = context.temp_allocator)
	f2, is_f2 := err.(tape.Fault)
	testing.expect(t, is_f2 && f2.kind == .Refused && xml.Typed_Refusal(f2.detail) == .Missing_Field)
	testkit.expect_path(t, path[:], {"r", "c"})

	// Required field satisfied via attribute succeeds.
	testing.expect_value(t, xml.unmarshal(transmute([]u8)string(`<r c="42"/>`), &cur, allocator = context.temp_allocator), nil)
	testing.expect_value(t, cur.r.c, i64(42))
	testing.expect_value(t, cur.r.a, i64(7))
}

@(test)
malformed_xml_and_type_mismatch_errors :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	Doc :: struct {
		r: struct {
			n:    i8,
			u:    u8,
			f:    f32,
			b:    bool,
			c:    Color,
			t:    time.Time,
			sub:  struct {
				x: int,
			},
			arm:  union {
				int,
				bool,
			},
		},
	}

	// Malformed XML matches xml.validate.
	bad_xmls := [?]string{"", "<r>", "<r><a></b></r>", "<r>&undeclared;</r>", "<r a='1' a='2'/>"}
	for text in bad_xmls {
		src := transmute([]u8)text
		v: Doc
		got_err := xml.unmarshal(src, &v, allocator = context.temp_allocator)
		want_err := xml.validate(src)
		testing.expectf(t, got_err != nil && got_err == want_err, "%q: got %v, want %v", text, got_err, want_err)
	}

	// Bad options.
	testing.expect_value(t, xml.unmarshal(transmute([]u8)string(`<r/>`), (^Doc)(nil)), xml.Error(xml.Bad_Option{"target"}))
	dummy: Doc
	testing.expect_value(t, xml.unmarshal(transmute([]u8)string(`<r/>`), &dummy, xml.Spec(99)), xml.Error(xml.Bad_Option{"spec"}))
	testing.expect_value(t, xml.unmarshal(transmute([]u8)string(`<r/>`), &dummy, opts = {format = xml.Xml_Options{arrays = .Schema}}), xml.Error(xml.Bad_Option{"format"}))

	// Type mismatch refusals and paths.
	Case :: struct {
		src:  string,
		want: xml.Typed_Refusal,
		step: string,
	}
	cases := [?]Case {
		{"<r><n>abc</n></r>", .Expected_Integer, "n"},
		{"<r><n>1.5</n></r>", .Expected_Integer, "n"},
		{"<r><n>128</n></r>", .Above_Maximum, "n"},
		{"<r><n>-129</n></r>", .Below_Minimum, "n"},
		{"<r><u>-1</u></r>", .Below_Minimum, "u"},
		{"<r><u>256</u></r>", .Above_Maximum, "u"},
		{"<r><f>nope</f></r>", .Expected_Number, "f"},
		{"<r><f>1e300</f></r>", .Above_Maximum, "f"},
		{"<r><b>yes</b></r>", .Expected_Bool, "b"},
		{"<r><c>Purple</c></r>", .Not_A_Member, "c"},
		{"<r><t>not-a-date</t></r>", .Bad_Date_Time, "t"},
		{"<r><sub>plain</sub></r>", .Expected_Object, "sub"},
		{"<r><arm>neither</arm></r>", .No_Arm, "arm"},
	}
	path := make([dynamic]tape.Step, context.temp_allocator)
	for c in cases {
		v: Doc
		e := xml.unmarshal(transmute([]u8)c.src, &v, read = {path = &path}, allocator = context.temp_allocator)
		f, is_f := e.(tape.Fault)
		testing.expectf(t, is_f && f.kind == .Refused && xml.Typed_Refusal(f.detail) == c.want, "%s: got %v, want %v", c.src, e, c.want)
		testkit.expect_path(t, path[:], {"r", c.step})
	}
}

@(test)
budget_and_scratch_allocator :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Row :: struct {
		name:  string,
		value: i64,
		tag:   string,
	}
	Doc :: struct {
		root: struct {
			row: []Row,
		},
	}

	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "<root>")
	for i in 0 ..< 200 {
		fmt.sbprintf(&b, "<row><name>row-%04d-payload</name><value>%d</value><tag>tag-%04d</tag></row>", i, i * 17, i)
	}
	strings.write_string(&b, "</root>")
	src := transmute([]u8)strings.to_string(b)

	// 1. Depth, nodes, steps, and expansion budgets.
	{
		v: Doc
		e_depth := xml.unmarshal(transmute([]u8)string(`<root><row><name>a</name></row></root>`), &v, opts = {budget = {depth = 2}})
		testing.expect_value(t, e_depth, xml.Error(tape.Exceeded{at = 11, kind = .Depth}))

		e_nodes := xml.unmarshal(src, &v, opts = {budget = {nodes = 10}})
		ex_n, is_ex_n := e_nodes.(tape.Exceeded)
		testing.expect(t, is_ex_n && ex_n.kind == .Nodes)

		e_steps := xml.unmarshal(src, &v, opts = {budget = {steps = 5}})
		ex_s, is_ex_s := e_steps.(tape.Exceeded)
		testing.expect(t, is_ex_s && ex_s.kind == .Steps)

		dtd_src := transmute([]u8)string(`<!DOCTYPE root [<!ENTITY a "xxxxxxxxxx"><!ENTITY b "&a;&a;&a;&a;&a;">]><root><row><name>&b;</name></row></root>`)
		e_exp := xml.unmarshal(dtd_src, &v, opts = {budget = {expansion = 16}})
		ex_e, is_ex_e := e_exp.(tape.Exceeded)
		testing.expect(t, is_ex_e && ex_e.kind == .Expansion)
	}

	// 2. Options.scratch: separates temporary document + walker scratch from persistent arena output with zero scratch leaks!
	for borrow in ([]bool{true, false}) {
		a_plain: virtual.Arena
		testing.expect_value(t, virtual.arena_init_growing(&a_plain), nil)
		defer virtual.arena_destroy(&a_plain)
		out_plain: Doc
		testing.expect_value(
			t,
			xml.unmarshal(src, &out_plain, read = {borrow_strings = borrow}, opts = {scratch = virtual.arena_allocator(&a_plain)}, allocator = virtual.arena_allocator(&a_plain)),
			nil,
		)

		a_sc: virtual.Arena
		testing.expect_value(t, virtual.arena_init_growing(&a_sc), nil)
		defer virtual.arena_destroy(&a_sc)
		st: mem.Tracking_Allocator
		mem.tracking_allocator_init(&st, context.allocator)
		defer mem.tracking_allocator_destroy(&st)
		out_sc: Doc
		testing.expect_value(
			t,
			xml.unmarshal(src, &out_sc, read = {borrow_strings = borrow}, opts = {scratch = mem.tracking_allocator(&st)}, allocator = virtual.arena_allocator(&a_sc)),
			nil,
		)
		testing.expect_value(t, len(out_sc.root.row), 200)
		testing.expect_value(t, out_sc.root.row[199].value, i64(199 * 17))
		testing.expectf(t, a_sc.total_used < a_plain.total_used, "borrow=%v: arena with scratch (%d) should be < plain (%d)", borrow, a_sc.total_used, a_plain.total_used)
		testing.expect(t, st.peak_memory_allocated > 0)
		testing.expect_value(t, len(st.allocation_map), 0)
		testing.expect_value(t, len(st.bad_free_array), 0)
	}

	// 3. Budget.memory enforces tight limit with and without explicit scratch, with zero leaks.
	exceeded := xml.Error(tape.Exceeded{at = tape.NO_BYTE, kind = .Memory})
	for use_scratch in ([]bool{false, true}) {
		st: mem.Tracking_Allocator
		mem.tracking_allocator_init(&st, context.allocator)
		defer mem.tracking_allocator_destroy(&st)
		sc := mem.tracking_allocator(&st) if use_scratch else runtime.Allocator{}
		out: Doc
		testing.expect_value(t, xml.unmarshal(src, &out, opts = {budget = {memory = 4096}, scratch = sc}), exceeded)
		testing.expect_value(t, len(st.allocation_map), 0)
		testing.expect_value(t, len(st.bad_free_array), 0)
	}

	// 4. Caller-owned Memory_Budget passed as allocator is never mutated.
	caller_m := hook.Memory_Budget{backing = context.allocator, limit = 4 << 20}
	out_b: Doc
	testing.expect_value(t, xml.unmarshal(src, &out_b, opts = {scratch = context.allocator}, allocator = hook.memory_budget(&caller_m)), nil)
	testing.expect(t, caller_m.peer == nil && !caller_m.refused)
	for row in out_b.root.row {
		delete(row.name, hook.memory_budget(&caller_m))
		delete(row.tag, hook.memory_budget(&caller_m))
	}
	delete(out_b.root.row, hook.memory_budget(&caller_m))
}

@(test)
oom_safety_zero_leaks :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Inner :: union {
		int,
		string,
	}
	Pair_A :: struct {
		items: [dynamic]int,
		label: string,
		count: int,
	}
	Pair_B :: struct {
		items: [dynamic]int,
		label: string,
	}
	Box_U :: union {
		Pair_A,
		Pair_B,
	}
	Oom_Doc :: struct {
		r: struct {
			title: string,
			tags:  []string,
			nums:  [dynamic]int,
			kv:    map[string]int,
			ptr:   ^string,
			in_u:  Inner,
			box:   Box_U,
		},
	}

	src := transmute([]u8)string(`<r><title>stury</title><tags>a</tags><tags>b</tags><nums>1</nums><nums>2</nums><kv><k1>10</k1><k2>20</k2></kv><ptr>hello</ptr><in_u>world</in_u><box><items>7</items><items>8</items><label>ok</label><count>bad</count></box></r>`)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	t_alloc := mem.tracking_allocator(&track)

	// Sweep OOM across BOTH allocator and scratch simultaneously: every OOM failure must return Out_Of_Memory,
	// leave destination untouched, and leak ZERO blocks! (Note: `xml.build` may recover gracefully from optional
	// non-fatal scratch allocations like `counts` and succeed with `err == nil`, in which case we still verify
	// the decoded result and zero leaks.)
	oom_hits := 0
	for k in 0 ..< 200 {
		fail := testkit.Failing{backing = t_alloc, fail_at = k}
		fa := testkit.failing_allocator(&fail)
		v := Oom_Doc{r = {title = "keep"}}
		err := xml.unmarshal(src, &v, opts = {scratch = fa}, allocator = fa)
		if err == nil {
			testing.expect_value(t, v.r.title, "stury")
			delete(v.r.title, t_alloc)
			for s in v.r.tags {
				delete(s, t_alloc)
			}
			delete(v.r.tags, t_alloc)
			delete(v.r.nums)
			for mk in v.r.kv {
				delete(mk, t_alloc)
			}
			delete(v.r.kv)
			if v.r.ptr != nil {
				delete(v.r.ptr^, t_alloc)
				free(v.r.ptr, t_alloc)
			}
			if sv, is_s := v.r.in_u.(string); is_s {
				delete(sv, t_alloc)
			}
			if pb, is_b := v.r.box.(Pair_B); is_b {
				delete(pb.items)
				delete(pb.label, t_alloc)
			}
			testing.expect_value(t, len(track.allocation_map), 0)
			testing.expect_value(t, len(track.bad_free_array), 0)
			if !fail.failed {
				break
			}
			continue
		}
		oom_hits += 1
		testing.expect_value(t, err, xml.Error(runtime.Allocator_Error.Out_Of_Memory))
		testing.expect_value(t, v.r.title, "keep")
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}
	testing.expect(t, oom_hits >= 20)
}

@(test)
marshal_unmarshal_round_trip_and_deep_nesting :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	Entry :: struct {
		name:  string,
		score: f64,
		ok:    bool,
	}
	Payload :: struct {
		title:  string,
		count:  i64,
		color:  Color,
		perms:  Perms,
		bytes:  []u8,
		fixed:  [3]int,
		list:   []Entry,
		tags:   [dynamic]string,
		opt_on: Maybe(int),
		opt_no: Maybe(int),
		stamp:  time.Time,
		meta:   map[string]int,
	}
	Doc :: struct {
		doc: Payload,
	}

	tags := make([dynamic]string, context.temp_allocator)
	append(&tags, "x<y", "a&b")
	meta := make(map[string]int, 4, context.temp_allocator)
	meta["alpha"] = 1
	meta["beta"] = 2

	ts, _ := time.datetime_to_time({year = 2026, month = 11, day = 27, hour = 13, minute = 0, second = 31})
	orig := Doc {
		doc = {
			title  = "hello <world> & \"friends\"",
			count  = -42,
			color  = .Blue,
			perms  = {.Read, .Write},
			bytes  = []u8{0, 65, 255},
			fixed  = {7, 8, 9},
			list   = []Entry{{"first", 1.25, true}, {"second", -0.5, false}},
			tags   = tags,
			opt_on = 123,
			opt_no = nil,
			stamp  = ts,
			meta   = meta,
		},
	}

	text, merr := xml.marshal(&orig, .Xml, {indent = 2}, allocator = context.temp_allocator)
	testing.expect_value(t, merr, nil)

	back: Doc
	uerr := xml.unmarshal(text, &back, allocator = context.temp_allocator)
	testing.expect_value(t, uerr, nil)

	testing.expect_value(t, back.doc.title, orig.doc.title)
	testing.expect_value(t, back.doc.count, orig.doc.count)
	testing.expect_value(t, back.doc.color, orig.doc.color)
	testing.expect_value(t, back.doc.perms, orig.doc.perms)
	testing.expect_value(t, len(back.doc.bytes), len(orig.doc.bytes))
	for bv, i in orig.doc.bytes {
		testing.expect_value(t, back.doc.bytes[i], bv)
	}
	testing.expect_value(t, back.doc.fixed, orig.doc.fixed)
	if testing.expect_value(t, len(back.doc.list), len(orig.doc.list)) {
		testing.expect_value(t, back.doc.list[0], orig.doc.list[0])
		testing.expect_value(t, back.doc.list[1], orig.doc.list[1])
	}
	if testing.expect_value(t, len(back.doc.tags), len(orig.doc.tags)) {
		testing.expect_value(t, back.doc.tags[0], orig.doc.tags[0])
		testing.expect_value(t, back.doc.tags[1], orig.doc.tags[1])
	}
	testing.expect_value(t, back.doc.opt_on, orig.doc.opt_on)
	testing.expect_value(t, back.doc.opt_no, orig.doc.opt_no)
	testing.expect_value(t, time.to_unix_nanoseconds(back.doc.stamp), time.to_unix_nanoseconds(orig.doc.stamp))
	testing.expect_value(t, back.doc.meta["alpha"], 1)
	testing.expect_value(t, back.doc.meta["beta"], 2)

	// Deep nesting (500 levels) unmarshals iteratively with no unbounded recursion.
	Chain :: struct {
		n: ^Chain,
		v: int,
	}
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	DEPTH :: 500
	for _ in 0 ..< DEPTH {
		strings.write_string(&sb, "<n>")
	}
	strings.write_string(&sb, "<v>777</v>")
	for _ in 0 ..< DEPTH {
		strings.write_string(&sb, "</n>")
	}
	deep: Chain
	testing.expect_value(t, xml.unmarshal(transmute([]u8)strings.to_string(sb), &deep, allocator = context.temp_allocator), nil)
	cur := &deep
	for _ in 0 ..< DEPTH {
		testing.expect(t, cur.n != nil)
		cur = cur.n
	}
	testing.expect_value(t, cur.v, 777)
}
