// Regression tests for Phase 2 Polish Bugs #1-#6 (both load and streaming paths).
package model_test

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:testing"
import "core:time"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"
import "stury:lib/schema/check"
import "stury:lib/schema/model"
import "stury:lib/schema/rules"
import "stury:testkit"

// ============================================================================
// Bug #1: `run_judged_on_subdoc` returning `true` in `sink != nil` mode
// ============================================================================

@(test)
bug1_judged_failure_with_sink_stops_post_hooks :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Unique_Box :: struct {
		nums: []i32 `model:"unique"`,
	}
	Schema_Rec :: struct {
		a: int,
		b: int `model:"optional"`,
	}
	Dual :: union {
		Schema_Rec,
		struct { a: int },
	}
	Custom_Target :: struct { sum: int }
	Custom_Wrap :: struct {
		inner: Schema_Rec,
		m:     map[string][]i32 `model:"optional"`,
		u:     Dual `model:"optional"`,
		c:     Custom_Target `model:"optional"`,
	}

	after_unique :: proc(v: []i32, r: ^model.Report) {
		g_bug1_after += 1
		model.fail(r, "after should not run")
	}
	after_union :: proc(v: Dual, r: ^model.Report) {
		g_bug1_after += 1
	}
	val_schema_rec :: proc(v: Schema_Rec, r: ^model.Report) {
		g_bug1_val += 1
	}
	c_from :: proc(c: ^Schema_Rec, out: ^Custom_Target, a: runtime.Allocator) -> model.Error_Kind {
		g_bug1_custom += 1
		out.sum = c.a + c.b
		return .None
	}
	c_to :: proc(v: ^Custom_Target, a: runtime.Allocator) -> (Schema_Rec, model.Error_Kind) {
		return {a = v.sum}, .None
	}

	// Build a schema requiring `"b"` on `Schema_Rec`.
	d: rules.Description
	d.allocator = context.allocator; d.nodes.allocator = context.allocator; d.objects.allocator = context.allocator
	d.names = make(map[rules.Node_Index]string, 4, context.allocator)
	defer rules.description_destroy(&d)
	any_n := rules.Node_Index(len(d.nodes)); append(&d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1})
	obj_i := i32(len(d.objects))
	req_mems := make([]rules.Member, 1, context.allocator)
	req_mems[0] = {name = "b", node = any_n, required = true}
	append(&d.objects, rules.Object{members = req_mems, additional = any_n, keys = rules.NONE})
	d.root = rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = obj_i})

	// Test 1: `unique` slice + `register_after` in `sink != nil`.
	{
		reg: model.Registry; defer model.destroy(&reg)
		_ = model.register(&reg, Unique_Box, "nums", after_unique)
		m, cerr := model.compile(&reg, Unique_Box)
		defer model.destroy(&m)
		testing.expect_value(t, cerr, nil)

		sink: model.Sink; defer model.destroy(&sink)
		out: Unique_Box
		defer model.free_value(&out, type_info_of(Unique_Box), context.allocator)
		g_bug1_after = 0
		err := model.load(&m, transmute([]u8)string(`{"nums":[1,1]}`), json.as(.Json), json.reads(.Json), &out, &sink)
		testing.expect(t, err != nil && len(sink.entries) == 1 && sink.entries[0].kind == .Not_Unique)
		testing.expect_value(t, g_bug1_after, 0)

		bad := Unique_Box{nums = []i32{2, 2}}
		model.sink_clear(&sink)
		g_bug1_after = 0
		verr := model.validate(&m, &bad, &sink)
		testing.expect(t, verr != nil && len(sink.entries) == 1 && sink.entries[0].kind == .Not_Unique)
		testing.expect_value(t, g_bug1_after, 0)
	}

	// Test 2: `register_schema` (`Schema_Rec` missing `"b"`) skips struct validator, `Map_Insert`, `Custom.from`;
	// `.One_Match` matching both arms skips `after` hook in `sink != nil`; nested `Outer_U` leaves union nil when `Schema_Rec` fails.
	{
		Outer_U :: union { Schema_Rec, string }
		W_Outer :: struct {
			inner: Schema_Rec,
			m:     map[string]Unique_Box `model:"optional"`,
			c:     Custom_Target `model:"optional"`,
			ou:    Outer_U `model:"optional"`,
		}
		reg: model.Registry; defer model.destroy(&reg)
		_ = model.register(&reg, Schema_Rec, &d)
		_ = model.register(&reg, Schema_Rec, val_schema_rec)
		_ = model.register(&reg, model.Union_Rule{type = Outer_U, mode = .Tag})
		_ = model.register(&reg, model.Custom(Custom_Target, Schema_Rec){from = c_from, to = c_to})

		m, cerr := model.compile(&reg, W_Outer)
		defer model.destroy(&m)
		testing.expect_value(t, cerr, nil)

		sink: model.Sink; defer model.destroy(&sink)
		out: W_Outer
		defer model.free_value(&out, type_info_of(W_Outer), context.allocator)
		g_bug1_after, g_bug1_val, g_bug1_custom = 0, 0, 0
		src := `{"inner":{"a":1},"m":{"dup":{"nums":[5,5]}},"c":{"a":9},"ou":{"a":11}}`
		err := model.load(&m, transmute([]u8)src, json.as(.Json), json.reads(.Json), &out, &sink)
		testing.expect(t, err != nil && len(sink.entries) >= 4)
		testing.expect_value(t, g_bug1_val, 0)
		testing.expect_value(t, g_bug1_custom, 0)
		testing.expect_value(t, g_bug1_after, 0)
		testing.expect(t, out.ou == nil)
		_, has_dup := out.m["dup"]
		testing.expect(t, !has_dup)

		// Separately verify `.One_Match` matching both arms skips `after` hook in `sink != nil` mode.
		Wrap_U :: struct { u: Dual }
		ru: model.Registry; defer model.destroy(&ru)
		_ = model.register(&ru, model.Union_Rule{type = Dual, mode = .One_Match})
		_ = model.register(&ru, Wrap_U, "u", after_union)
		mu, mue := model.compile(&ru, Wrap_U)
		defer model.destroy(&mu)
		testing.expect_value(t, mue, nil)
		usink: model.Sink; defer model.destroy(&usink)
		uout: Wrap_U
		defer model.free_value(&uout, type_info_of(Wrap_U), context.allocator)
		g_bug1_after = 0
		uerr := model.load(&mu, transmute([]u8)string(`{"u":{"a":7,"b":8}}`), json.as(.Json), json.reads(.Json), &uout, &usink)
		testing.expect(t, uerr != nil && len(usink.entries) == 1 && usink.entries[0].kind == .Many_Arms)
		testing.expect_value(t, g_bug1_after, 0)
		_ = Custom_Wrap{}
	}
}

@(private = "file")
g_bug1_after, g_bug1_val, g_bug1_custom: int

// ============================================================================
// Bug #2: `json.load` (`stream_indirect`) skips `after` on invalid scalars + zero `Number_Text` alloc
// ============================================================================

@(test)
bug2_stream_indirect_skips_after_and_numtext_alloc_on_fail :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Color :: enum u8 { Red = 1, Blue = 2 }
	S2 :: struct {
		cs:    cstring           `model:"len>=5"`,
		nt:    model.Number_Text `model:">=10"`,
		dec:   model.Decimal     `model:">=10"`,
		tm:    time.Time         `model:"optional"`,
		uid:   uuid.Identifier   `model:"optional"`,
		bs:    []u8              `model:"len>=4"`,
		b64:   model.Base64      `model:"optional"`,
		hx:    model.Hex         `model:"optional"`,
		ce:    Color             `model:"optional"`,
		p_str: ^string           `model:"optional"`,
		m_str: Maybe(string)     `model:"optional"`,
	}
	g_bug2_calls = {}
	reg: model.Registry; defer model.destroy(&reg)
	_ = model.register(&reg, model.Enum_Rule{type = Color, by_number = true})
	_ = model.register(&reg, S2, "cs", proc(_: cstring, _r: ^model.Report) { g_bug2_calls[0] += 1 })
	_ = model.register(&reg, S2, "nt", proc(_: model.Number_Text, _r: ^model.Report) { g_bug2_calls[1] += 1 })
	_ = model.register(&reg, S2, "dec", proc(_: model.Decimal, _r: ^model.Report) { g_bug2_calls[2] += 1 })
	_ = model.register(&reg, S2, "tm", proc(_: time.Time, _r: ^model.Report) { g_bug2_calls[3] += 1 })
	_ = model.register(&reg, S2, "uid", proc(_: uuid.Identifier, _r: ^model.Report) { g_bug2_calls[4] += 1 })
	_ = model.register(&reg, S2, "bs", proc(_: []u8, _r: ^model.Report) { g_bug2_calls[5] += 1 })
	_ = model.register(&reg, S2, "b64", proc(_: model.Base64, _r: ^model.Report) { g_bug2_calls[6] += 1 })
	_ = model.register(&reg, S2, "hx", proc(_: model.Hex, _r: ^model.Report) { g_bug2_calls[7] += 1 })
	_ = model.register(&reg, S2, "ce", proc(_: Color, _r: ^model.Report) { g_bug2_calls[8] += 1 })
	_ = model.register(&reg, S2, "m_str", proc(_: Maybe(string), _r: ^model.Report) { g_bug2_calls[9] += 1 })

	m, cerr := model.compile(&reg, S2)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	sink: model.Sink; defer model.destroy(&sink)
	out: S2
	defer model.free_value(&out, type_info_of(S2), context.allocator)
	bad_json := `{"cs":"hi","nt":5,"dec":3,"tm":"not-a-time","uid":"bad-uuid","bs":"AQ","b64":"!!!","hx":"zz","ce":99,"p_str":123,"m_str":null}`
	err := json.load(&m, transmute([]u8)bad_json, &out, .Json, &sink)
	testing.expect(t, err != nil && len(sink.entries) == 10)
	for i in 0 ..< 9 { testing.expect_value(t, g_bug2_calls[i], 0) }
	// Valid `null` on `Maybe(string)` STILL invokes `after` hook (parity with `model.load`).
	testing.expect_value(t, g_bug2_calls[9], 1)

	// Valid `^i32` `after` receives parent struct field pointer cleanly with zero crash.
	Ptr_After :: struct { p: ^i32 }
	g_bug2_ptr = 0
	rp: model.Registry; defer model.destroy(&rp)
	_ = model.register(&rp, Ptr_After, "p", proc(v: ^i32, r: ^model.Report) { if v != nil && v^ == 7 { g_bug2_ptr += 1 } })
	mp, mperr := model.compile(&rp, Ptr_After); defer model.destroy(&mp); testing.expect_value(t, mperr, nil)
	pa: Ptr_After; defer model.free_value(&pa, type_info_of(Ptr_After), context.allocator)
	testing.expect_value(t, json.load(&mp, transmute([]u8)string(`{"p":7}`), &pa), nil)
	testing.expect_value(t, g_bug2_ptr, 1)

	// Verify failing `Number_Text` leaf makes ZERO heap allocations in `out` allocator!
	Nt_Only :: struct { nt: model.Number_Text `model:">=100"` }
	mnt, mnterr := model.compile(nil, Nt_Only)
	defer model.destroy(&mnt)
	testing.expect_value(t, mnterr, nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	nsink: model.Sink
	model.sink_init(&nsink, context.allocator)
	defer model.destroy(&nsink)
	nout: Nt_Only
	nerr := json.load(&mnt, transmute([]u8)string(`{"nt":42}`), &nout, .Json, &nsink, {scratch = context.allocator}, alloc)
	testing.expect(t, nerr != nil && len(nsink.entries) == 1)
	testing.expect_value(t, track.total_memory_allocated, 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(private = "file")
g_bug2_calls: [10]int
@(private = "file")
g_bug2_ptr: int

// ============================================================================
// Bug #3: `[]u8` (`Bytes`) classified as `.Text` in `tags.odin`
// ============================================================================

@(test)
bug3_bytes_slice_classified_as_text_tag_and_unique_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Good_Bytes :: struct {
		payload: []u8 `model:"len>=4,len<=8,pattern=^AQI"`,
	}
	mg, errg := model.compile(nil, Good_Bytes)
	defer model.destroy(&mg)
	testing.expect_value(t, errg, nil)

	out: Good_Bytes
	defer model.free_value(&out, type_info_of(Good_Bytes), context.allocator)
	testing.expect_value(t, json.load(&mg, transmute([]u8)string(`{"payload":"AQID"}`), &out), nil)
	testing.expect(t, len(out.payload) == 3 && out.payload[0] == 1 && out.payload[1] == 2 && out.payload[2] == 3)
	testing.expect_value(t, model.validate(&mg, &out), nil)

	dumped, derr := json.dump(&mg, &out, {check = true})
	defer delete(dumped)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, string(dumped), `{"payload":"AQID"}`)

	// Too short base64 or wrong pattern fails both `json.load` and `validate`.
	out_bad: Good_Bytes
	lerr := json.load(&mg, transmute([]u8)string(`{"payload":"////"}`), &out_bad)
	defer model.error_destroy(lerr)
	testing.expect(t, lerr != nil)

	bad_val := Good_Bytes{payload = []u8{1}} // encodes as "AQ==" (pattern does not match ^AQI? Wait: AQI fails, "AQI" passes!)
	verr := model.validate(&mg, &bad_val)
	defer model.error_destroy(verr)
	testing.expect(t, verr != nil)

	// Validate `[]u8` length, pattern, and format compilation + validation.
	Fmt_Bytes :: struct { u: []u8 `model:"format=uuid"` }
	mfb, efb := model.compile(nil, Fmt_Bytes)
	defer model.destroy(&mfb)
	testing.expect_value(t, efb, nil)

	// `unique` on `[]u8` MUST be refused at compile time as `.Bad_Tag`!
	Bad_Unique_Bytes :: struct {
		payload: []u8 `model:"unique"`,
	}
	mb, errb := model.compile(nil, Bad_Unique_Bytes)
	defer model.destroy(&mb)
	me, is_me := errb.(model.Model_Error)
	testing.expect(t, is_me && me.kind == .Bad_Tag)
}

// ============================================================================
// Bug #4: `f32` double-rounding & `-0` sign preservation in `stream.odin`
// ============================================================================

@(test)
bug4_f32_single_rounding_and_negative_zero_sign :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Double-rounding edge decimal: `strconv.parse_f32` != `f32(strconv.parse_f64)`.
	edge := "1.0000001788139343261718749"
	exact_f32, _ := strconv.parse_f32(edge)
	f64_approx, _ := strconv.parse_f64(edge)
	testing.expect(t, exact_f32 != f32(f64_approx))

	Rec :: struct {
		f32v: f32,
		f64v: f64,
		nt:   model.Number_Text,
	}
	m, cerr := model.compile(nil, Rec)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// Check `f32` matches `strconv.parse_f32` and `model.load`, and `"-0"` preserves negative sign bit.
	src1 := fmt.aprintf(`{{"f32v":%s,"f64v":-0,"nt":-0}}`, edge)
	defer delete(src1)
	r1, r2: Rec
	defer model.free_value(&r1, type_info_of(Rec), context.allocator)
	defer model.free_value(&r2, type_info_of(Rec), context.allocator)
	testing.expect_value(t, json.load(&m, transmute([]u8)src1, &r1, .Json), nil)
	testing.expect_value(t, model.load(&m, transmute([]u8)src1, json.as(.Json), json.reads(.Json), &r2), nil)
	testing.expect_value(t, r1.f32v, exact_f32)
	testing.expect_value(t, r1.f32v, r2.f32v)
	testing.expect(t, r1.f64v == 0 && math.sign_bit(r1.f64v))
	testing.expect(t, r1.nt.value == 0 && math.sign_bit(r1.nt.value) && r1.nt.text == "-0")

	// Check JSON5 `"-0."` and `"-0x0"` preserve `-` sign across `f32`, `f64`, and `Number_Text`.
	for j5 in ([]string{`{f32v:-0.,f64v:-0.,nt:-0.}`, `{f32v:-0x0,f64v:-0x0,nt:-0x0}`}) {
		v: Rec
		defer model.free_value(&v, type_info_of(Rec), context.allocator)
		testing.expect_value(t, json.load(&m, transmute([]u8)j5, &v, .Json5), nil)
		testing.expect(t, v.f32v == 0 && math.sign_bit(v.f32v))
		testing.expect(t, v.f64v == 0 && math.sign_bit(v.f64v))
		testing.expect(t, v.nt.value == 0 && math.sign_bit(v.nt.value))
	}
}

// ============================================================================
// Bug #5: `emit_node` depth/sink parity & `json.dump` nested capture pointer
// ============================================================================

@(test)
bug5_dump_cycle_depth_sink_and_nested_capture_pointer :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Cycle :: struct { next: ^Cycle `model:"optional"` }
	mc, cerr := model.compile(nil, Cycle)
	defer model.destroy(&mc)
	testing.expect_value(t, cerr, nil)
	cyc: Cycle
	cyc.next = &cyc
	_, cderr := model.dump_document(&mc, &cyc)
	te, is_te := cderr.(tape.Error)
	exc, is_exc := te.(tape.Exceeded)
	testing.expect(t, is_te && is_exc && exc.kind == .Depth)

	Child_Cap :: struct {
		k:     i32,
		extra: map[string]i32 `json:",unknown"`,
	}
	Child_Nan :: struct { f: f64 }
	Parent :: struct {
		child: Child_Cap `model:"optional"`,
		items: []Child_Cap `model:"optional"`,
		nan_c: Child_Nan `model:"optional"`,
	}
	mp, mperr := model.compile(nil, Parent)
	defer model.destroy(&mp)
	testing.expect_value(t, mperr, nil)

	ex := make(map[string]i32); defer delete(ex); ex["k"] = 99
	// Nested capture Duplicate_Key under struct field `"/child/k"`:
	p1 := Parent{child = {k = 1, extra = ex}}
	s1, s2: model.Sink; defer model.destroy(&s1); defer model.destroy(&s2)
	doc1, de1 := model.dump_document(&mp, &p1, {}, &s1)
	defer tape.destroy(&doc1)
	testing.expect(t, de1 != nil && len(s1.entries) == 1 && s1.entries[0].kind == .Duplicate_Key && s1.entries[0].pointer == "/child/k")
	j1, je1 := json.dump(&mp, &p1, {}, {}, &s2)
	defer delete(j1)
	me1, _ := de1.(model.Model_Error); me2, _ := je1.(model.Model_Error)
	testing.expect(t, je1 != nil && me1.pointer == "/child/k" && me2.pointer == "/child/k")
	testing.expect(t, len(s2.entries) == 1 && s2.entries[0].pointer == "/child/k")

	// Nested capture Duplicate_Key under slice element `"/items/1/k"`:
	p2 := Parent{items = []Child_Cap{{k = 1}, {k = 2, extra = ex}}}
	s3, s4: model.Sink; defer model.destroy(&s3); defer model.destroy(&s4)
	_, _ = model.dump_document(&mp, &p2, {}, &s3)
	j2, je2 := json.dump(&mp, &p2, {}, {}, &s4)
	defer delete(j2)
	me3, _ := je2.(model.Model_Error)
	testing.expect(t, je2 != nil && me3.pointer == "/items/1/k")
	testing.expect(t, len(s3.entries) == 1 && s3.entries[0].pointer == "/items/1/k")
	testing.expect(t, len(s4.entries) == 1 && s4.entries[0].pointer == "/items/1/k")

	// Nested Non_Finite reported to `sink` in `model.dump_document`:
	p3 := Parent{nan_c = {f = math.nan_f64()}}
	s5: model.Sink; defer model.destroy(&s5)
	_, de5 := model.dump_document(&mp, &p3, {}, &s5)
	testing.expect(t, de5 != nil && len(s5.entries) == 1 && s5.entries[0].kind == .Non_Finite && s5.entries[0].pointer == "/nan_c/f")
}

// ============================================================================
// Bug #6: All 5 medium parity fixes
// ============================================================================

@(test)
bug6_edge_parity_dsv_map_empty_enum_oom :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// (6a) DSV `no_header` skips `Read_Only` fields and routes excess cells to `capture_idx` or refuses under `Extra.Forbid`.
	Dsv_Cap :: struct {
		ro:    i32 `model:"read_only"`,
		name:  string,
		age:   i32,
		extra: map[string]string `json:",unknown"`,
	}
	mc, emc := model.compile(nil, []Dsv_Cap)
	defer model.destroy(&mc)
	testing.expect_value(t, emc, nil)
	d1, db1 := dsv.build(transmute([]u8)string("ada,36,bonus1,bonus2\n"), .Csv, {format = tape.Dsv_Options{no_header = true}})
	defer tape.destroy(&d1)
	testing.expect_value(t, db1, nil)
	rows: []Dsv_Cap
	defer model.free_value(&rows, type_info_of([]Dsv_Cap), context.allocator)
	testing.expect_value(t, model.load_document(&mc, &d1, &rows), nil)
	testing.expect(t, len(rows) == 1 && rows[0].ro == 0 && rows[0].name == "ada" && rows[0].age == 36)
	testing.expect(t, rows[0].extra["3"] == "bonus1" && rows[0].extra["4"] == "bonus2")

	Dsv_Forbid :: struct { ro: i32 `model:"read_only"`, name: string, age: i32 }
	reg: model.Registry; defer model.destroy(&reg)
	_ = model.register(&reg, Dsv_Forbid, model.Extra.Forbid)
	mf, emf := model.compile(&reg, []Dsv_Forbid)
	defer model.destroy(&mf)
	testing.expect_value(t, emf, nil)
	d2, _ := dsv.build(transmute([]u8)string("ada,36\n"), .Csv, {format = tape.Dsv_Options{no_header = true}})
	defer tape.destroy(&d2)
	ok_rows: []Dsv_Forbid; defer model.free_value(&ok_rows, type_info_of([]Dsv_Forbid), context.allocator)
	testing.expect_value(t, model.load_document(&mf, &d2, &ok_rows), nil)
	testing.expect(t, len(ok_rows) == 1 && ok_rows[0].ro == 0 && ok_rows[0].name == "ada" && ok_rows[0].age == 36)
	d3, _ := dsv.build(transmute([]u8)string("ada,36,too_many\n"), .Csv, {format = tape.Dsv_Options{no_header = true}})
	defer tape.destroy(&d3)
	bad_rows: []Dsv_Forbid; defer model.free_value(&bad_rows, type_info_of([]Dsv_Forbid), context.allocator)
	ferr := model.load_document(&mf, &d3, &bad_rows)
	defer model.error_destroy(ferr)
	fme, is_fme := ferr.(model.Model_Error)
	testing.expect(t, is_fme && fme.kind == .Not_Allowed)

	// (6b) Map `min_members`/`max_members` with invalid keys (`sink != nil`) parity across `json.load` and `model.load_document`.
	Map_Hold :: struct { m: map[i32]i32 `model:"len>=2,len<=2"` }
	mm, emm := model.compile(nil, Map_Hold)
	defer model.destroy(&mm)
	testing.expect_value(t, emm, nil)
	for raw in ([]string{`{"m":{"bad":1,"1":2}}`, `{"m":{"1":2,"bad":3}}`, `{"m":{"bad":1,"1":2,"3":4}}`}) {
		s1, s2: model.Sink; defer model.destroy(&s1); defer model.destroy(&s2)
		v1, v2: Map_Hold
		e1 := json.load(&mm, transmute([]u8)raw, &v1, .Json, &s1)
		e2 := model.load(&mm, transmute([]u8)raw, json.as(.Json), json.reads(.Json), &v2, &s2)
		testing.expect(t, e1 != nil && e2 != nil)
		testing.expect_value(t, len(s1.entries), len(s2.entries))
		for i in 0 ..< min(len(s1.entries), len(s2.entries)) {
			testing.expect_value(t, s1.entries[i].kind, s2.entries[i].kind)
			testing.expect_value(t, s1.entries[i].pointer, s2.entries[i].pointer)
		}
	}

	// (6c) `omitempty` omits empty `Bit_Set`, zero `Decimal` (`Decimal{}`, `"0"`, `"-0.00"`), and zero `[3]i32`.
	Flag :: enum u8 { A, B }
	Omit_Val :: struct {
		bs:  bit_set[Flag] `json:",omitempty"`,
		dec: model.Decimal `json:",omitempty"`,
		arr: [3]i32        `json:",omitempty"`,
		k:   i32,
	}
	mo, emo := model.compile(nil, Omit_Val)
	defer model.destroy(&mo)
	testing.expect_value(t, emo, nil)
	for zdec in ([]model.Decimal{{}, {text = "0"}, {text = "-0.00"}}) {
		val := Omit_Val{dec = zdec, k = 7}
		jout, jerr := json.dump(&mo, &val); defer delete(jout)
		mout, merr := model.dump(&mo, &val, write_json_default); defer delete(mout)
		testing.expect_value(t, jerr, nil)
		testing.expect_value(t, merr, nil)
		testing.expect_value(t, string(jout), `{"k":7}`)
		testing.expect_value(t, string(mout), `{"k":7}`)
	}
	non_empty := Omit_Val{bs = {.A}, dec = {text = "1.5"}, arr = {0, 2, 0}, k = 7}
	jne, _ := json.dump(&mo, &non_empty); defer delete(jne)
	testing.expect_value(t, string(jne), `{"bs":["A"],"dec":1.5,"arr":[0,2,0],"k":7}`)

	// (6d) Large non-contiguous `Enum` map key uses exact enumeration instead of `[lo, hi]` range.
	Big_Enum :: enum u64 { HighA = u64(1) << 60, HighB = (u64(1) << 60) + 100 }
	reg_e: model.Registry; defer model.destroy(&reg_e)
	_ = model.register(&reg_e, model.Enum_Rule{type = Big_Enum, by_number = true})
	mbig, embig := model.compile(&reg_e, map[Big_Enum]i32)
	defer model.destroy(&mbig)
	testing.expect_value(t, embig, nil)
	desc, derr := model.schema(&mbig, .Load); defer rules.description_destroy(&desc)
	testing.expect_value(t, derr, nil)
	cp, cperr := check.compile(&desc)
	defer check.plan_destroy(&cp)
	testing.expect_value(t, cperr.kind, rules.Error_Kind.None)
	between := `{"1152921504606846977":1}`
	r_bad := json.check(transmute([]u8)between, &cp)
	defer check.result_destroy(&r_bad)
	testing.expect(t, !r_bad.valid)
	valid_e := `{"1152921504606846976":1,"1152921504606847076":2}`
	r_ok := json.check(transmute([]u8)valid_e, &cp)
	defer check.result_destroy(&r_ok)
	testing.expect(t, r_ok.valid)

	// (6e) OOM during `problem()` `entry_message` frees `pointer` with 0 leaks.
	Fail_On_Third :: struct { track: mem.Tracking_Allocator, count: int }
	f_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, align: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
		s := (^Fail_On_Third)(data)
		if mode == .Alloc || mode == .Alloc_Non_Zeroed {
			s.count += 1
			if s.count >= 3 { return nil, .Out_Of_Memory }
		}
		if s.track.backing.procedure == nil { return nil, nil }
		return mem.tracking_allocator_proc(&s.track, mode, size, align, old_ptr, old_size, loc)
	}
	state: Fail_On_Third
	mem.tracking_allocator_init(&state.track, context.allocator)
	defer mem.tracking_allocator_destroy(&state.track)
	fail_alloc := runtime.Allocator{procedure = f_proc, data = &state}
	entries := []model.Error_Entry{{kind = .Wrong_Kind, pointer = "/field"}}
	_, perr := model.problem(entries, "Bad", 400, allocator = fail_alloc)
	testing.expect_value(t, perr, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, len(state.track.allocation_map), 0)
}

// ============================================================================
// Neon Follow-ups: silent `walk_fail` abort & `stream_build_steps` out-of-order OOB
// ============================================================================

@(test)
bug7_walk_fail_silent_aborts_emit_without_phantom_too_few :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Raw_Wrap :: struct { items: []typed.Raw }
	Nan_Wrap :: struct { items: []f64 }

	make_min2_desc :: proc(alloc: runtime.Allocator) -> rules.Description {
		d: rules.Description
		d.allocator, d.nodes.allocator, d.objects.allocator = alloc, alloc, alloc
		d.names = make(map[rules.Node_Index]string, 4, alloc)
		any_n := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1})
		arr_i := rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.Array}, rules = {min_items = 2}, array = -1, object = -1})
		mems := make([]rules.Member, 1, alloc)
		mems[0] = {name = "items", node = arr_i}
		append(&d.objects, rules.Object{members = mems, additional = any_n, keys = rules.NONE})
		d.root = rules.Node_Index(len(d.nodes))
		append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})
		return d
	}

	d := make_min2_desc(context.allocator)
	defer rules.description_destroy(&d)

	// (1) `[]typed.Raw` with 2 elements under `register_schema(..., minItems: 2)` must NOT emit phantom `.Too_Few`.
	reg1: model.Registry; defer model.destroy(&reg1)
	testing.expect_value(t, model.register(&reg1, Raw_Wrap, &d), runtime.Allocator_Error.None)
	mr, mrc := model.compile(&reg1, Raw_Wrap); defer model.destroy(&mr)
	testing.expect_value(t, mrc, nil)
	rsink: model.Sink; defer model.destroy(&rsink)
	rv := Raw_Wrap{items = []typed.Raw{typed.Raw("1"), typed.Raw("2")}}
	testing.expect_value(t, model.validate(&mr, &rv, &rsink), nil)
	testing.expect_value(t, len(rsink.entries), 0)

	// (2) `[]f64{NaN, 1.0}` under `register_schema(..., minItems: 2)` must report ONLY `.Non_Finite`, never phantom `.Too_Few`.
	reg2: model.Registry; defer model.destroy(&reg2)
	testing.expect_value(t, model.register(&reg2, Nan_Wrap, &d), runtime.Allocator_Error.None)
	mn, mnc := model.compile(&reg2, Nan_Wrap); defer model.destroy(&mn)
	testing.expect_value(t, mnc, nil)
	nsink: model.Sink; defer model.destroy(&nsink)
	nv := Nan_Wrap{items = []f64{math.nan_f64(), 1.0}}
	verr := model.validate(&mn, &nv, &nsink)
	defer model.error_destroy(verr)
	testing.expect(t, verr != nil && len(nsink.entries) == 1 && nsink.entries[0].kind == .Non_Finite && nsink.entries[0].pointer == "/items/0")
}

@(test)
bug8_stream_out_of_order_nested_struct_step_pointer :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Inner :: struct {
		x:   i32 `model:">=0,<=10"`,
		req: i32,
	}
	Outer :: struct {
		a: Inner `model:"optional"`,
		b: i32   `model:"optional"`,
		s: []i32 `model:"optional"`,
	}
	m, cerr := model.compile(nil, Outer); defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// Out-of-order `"b"` before `"a"` sets `s.b = stream_sentinel_b()` before opening `"a"` (`s`/`a`).
	for policy in ([]tape.Duplicates{.Refuse, .Last}) {
		sink: model.Sink; defer model.destroy(&sink)
		out: Outer; defer model.free_value(&out, type_info_of(Outer), context.allocator)
		src := `{"b":1,"a":{"x":999}}`
		err := json.load(&m, transmute([]u8)src, &out, .Json, &sink, {dups = policy})
		testing.expect(t, err != nil && len(sink.entries) == 2)
		if len(sink.entries) == 2 {
			testing.expect_value(t, sink.entries[0].kind, model.Error_Kind.Above_Maximum)
			testing.expect_value(t, sink.entries[0].pointer, "/a/x")
			testing.expect_value(t, sink.entries[1].kind, model.Error_Kind.Missing_Field)
			testing.expect_value(t, sink.entries[1].pointer, "/a/req")
		}

		// Also verify out-of-order slice under parent struct after `"b"` was already seen.
		model.sink_clear(&sink)
		out2: Outer; defer model.free_value(&out2, type_info_of(Outer), context.allocator)
		src2 := `{"b":1,"a":{"x":5,"req":2},"s":["bad"]}`
		err2 := json.load(&m, transmute([]u8)src2, &out2, .Json, &sink, {dups = policy})
		testing.expect(t, err2 != nil && len(sink.entries) == 1)
		if len(sink.entries) == 1 {
			testing.expect_value(t, sink.entries[0].kind, model.Error_Kind.Wrong_Kind)
			testing.expect_value(t, sink.entries[0].pointer, "/s/0")
		}
	}
}
