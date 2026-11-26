// Streaming `json.load` and direct-buffer `json.dump` / `json.dump_to` parity, edge-case, and memory-safety tests.
package model_test

import "core:bytes"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/model"
import "stury:lib/schema/rules"
import "stury:testkit"

@(private = "file")
Stream_Color :: enum u8 {
	Red   = 1,
	Green = 2,
	Blue  = 3,
}

@(private = "file")
Stream_Code :: enum i32 {
	Ok  = 200,
	Bad = 400,
}

@(private = "file")
Stream_Inner :: struct {
	x: i64 `model:">=0"`,
	y: string `model:"len<=32,optional"`,
}

@(private = "file")
Stream_Rich :: struct {
	_set:     model.Fields_Set,
	flag:     bool,
	wflag:    b32 `model:"optional"`,
	i8v:      i8 `model:">=-10,<=10"`,
	u16v:     u16 `model:"optional"`,
	i64v:     i64 `model:">=1"`,
	u64v:     u64 `model:"optional"`,
	f32v:     f32 `model:"optional"`,
	f64v:     f64 `model:">=0,<=1000"`,
	text:     string `model:"len>=1,len<=256"`,
	pat:      string `model:"pattern=^req-[0-9a-f]{4}$"`,
	mail:     model.Email `model:"optional"`,
	cs:       cstring `model:"optional"`,
	raw_b:    []u8 `model:"optional"`,
	b64:      model.Base64 `model:"optional"`,
	hx:       model.Hex `model:"optional"`,
	dec:      model.Decimal `model:"optional"`,
	num:      model.Number_Text `model:"optional"`,
	when_t:   time.Time `model:"optional"`,
	uid:      uuid.Identifier `model:"optional"`,
	color:    Stream_Color `model:"optional"`,
	code:     Stream_Code `model:"optional"`,
	opt_i:    Maybe(i64) `model:"optional"`,
	ptr_s:    ^Stream_Inner `model:"optional"`,
	nums:     []i64 `model:"len<=5,optional"`,
	dyn_s:    [dynamic]string `model:"optional"`,
	arr:      [3]i32 `model:"optional"`,
	scores:   map[string]i64 `model:"optional"`,
	by_id:    map[i32]string `model:"optional"`,
	nested:   Stream_Inner,
	ro:       i64 `model:"read_only"`,
	wo:       string `model:"write_only,optional"`,
	om_empty: string `json:",omitempty" model:"optional"`,
	om_unset: Maybe(string) `json:",omitunset" model:"optional"`,
	def_str:  string `model:"optional"`,
	def_num:  i64 `model:"optional"`,
}

@(test)
model_streaming_json_load_and_dump_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reg: model.Registry
	defer model.destroy(&reg)
	testing.expect_value(t, model.register(&reg, model.Enum_Rule{type = Stream_Color, by_number = false}), nil)
	testing.expect_value(t, model.register(&reg, model.Enum_Rule{type = Stream_Code, by_number = true}), nil)
	testing.expect_value(t, model.register(&reg, Stream_Rich, "def_str", "local"), nil)
	testing.expect_value(t, model.register(&reg, Stream_Rich, "def_num", i64(42)), nil)

	m, cerr := model.compile(&reg, Stream_Rich)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	src := transmute([]u8)string(`{` +
		`"flag":true,"wflag":true,"i8v":-5,"u16v":600,"i64v":9999999999,"u64v":123456,"f32v":1.5,"f64v":123.45,` +
		`"text":"hello \"world\" \\ \n\t 日本語 🚀 <a href=\"https://example.com\">link</a>",` +
		`"pat":"req-a1b2","mail":"a@b.co","cs":"cstr","raw_b":"YWJj","b64":"ZGVm","hx":"deadbeef",` +
		`"dec":"12.340","num":98765432109876543210,"when_t":"2026-05-01T12:30:00Z",` +
		`"uid":"550e8400-e29b-41d4-a716-446655440000","color":"Green","code":200,` +
		`"opt_i":77,"ptr_s":{"x":5,"y":"ptr"},"nums":[1,2,3],"dyn_s":["a","b"],"arr":[7,8,9],` +
		`"scores":{"b":2,"a":1},"by_id":{"10":"ten","2":"two"},"nested":{"x":3,"y":"in"},` +
		`"ro":999,"wo":"secret","om_empty":"","om_unset":null,"unknown_obj":{"k1":1,"k2":[1,2,3]}}`)

	v_stream: Stream_Rich
	defer model.free_value(&v_stream, type_info_of(Stream_Rich), context.allocator)
	testing.expect_value(t, json.load(&m, src, &v_stream), nil)

	v_doc: Stream_Rich
	defer model.free_value(&v_doc, type_info_of(Stream_Rich), context.allocator)
	testing.expect_value(t, model.load(&m, src, json.as(.Json), json.reads(.Json), &v_doc), nil)

	testing.expect_value(t, v_stream.flag, v_doc.flag)
	testing.expect_value(t, v_stream.i64v, v_doc.i64v)
	testing.expect_value(t, v_stream.text, v_doc.text)
	testing.expect_value(t, v_stream.pat, v_doc.pat)
	testing.expect_value(t, v_stream.ro, i64(0))
	testing.expect_value(t, v_stream.wo, "secret")
	testing.expect_value(t, v_stream.def_str, "local")
	testing.expect_value(t, v_stream.def_num, i64(42))
	testing.expect(t, model.was_set(&m, Stream_Rich, v_stream._set, "text"))
	testing.expect(t, !model.was_set(&m, Stream_Rich, v_stream._set, "def_str"))
	testing.expect(t, !model.was_set(&m, Stream_Rich, v_stream._set, "ro"))

	// Compare direct `json.dump` and `json.dump_to` byte-for-byte against `model.dump` across all option combinations.
	dump_cases := []struct {
		opts:  model.Dump_Opts,
		wopts: json.Write_Options,
	}{
		{{}, {}},
		{{exclude_unset = true}, {}},
		{{exclude_none = true}, {}},
		{{exclude_defaults = true}, {}},
		{{exclude_unset = true, exclude_none = true, exclude_defaults = true, check = true}, {}},
		{{}, {indent = 2}},
		{{}, {tab = true}},
		{{}, {ascii = true}},
		{{}, {indent = 2, ascii = true}},
		{{}, {framing = .Lines}},
		{{}, {framing = .Seq}},
	}
	for tc in dump_cases {
		ref, rerr := model.dump(&m, &v_doc, write_json_default, tc.opts, tc.wopts)
		defer delete(ref)
		testing.expect_value(t, rerr, nil)

		got, gerr := json.dump(&m, &v_stream, tc.opts, tc.wopts)
		defer delete(got)
		testing.expect_value(t, gerr, nil)
		testing.expect_value(t, string(got), string(ref))

		buf: bytes.Buffer
		defer bytes.buffer_destroy(&buf)
		terr := json.dump_to(bytes.buffer_to_stream(&buf), &m, &v_stream, tc.opts, tc.wopts)
		testing.expect_value(t, terr, nil)
		testing.expect_value(t, string(bytes.buffer_to_bytes(&buf)), string(ref))
	}
}

@(private = "file")
Wide_70 :: struct {
	_set: model.Fields_Set,
	f00, f01, f02, f03, f04, f05, f06, f07, f08, f09: i32 `model:"optional"`,
	f10, f11, f12, f13, f14, f15, f16, f17, f18, f19: i32 `model:"optional"`,
	f20, f21, f22, f23, f24, f25, f26, f27, f28, f29: i32 `model:"optional"`,
	f30, f31, f32, f33, f34, f35, f36, f37, f38, f39: i32 `model:"optional"`,
	f40, f41, f42, f43, f44, f45, f46, f47, f48, f49: i32 `model:"optional"`,
	f50, f51, f52, f53, f54, f55, f56, f57, f58, f59: i32 `model:"optional"`,
	f60, f61, f62: i32 `model:"optional"`,
	f63: i32,
	f64: i32,
	f65, f66, f67, f68: i32 `model:"optional"`,
	f69: string `model:"optional"`,
}

@(private = "file")
Wide_140 :: struct {
	_set: model.Fields_Set,
	using a: Wide_70_A,
	using b: Wide_70_B,
}

@(private = "file")
Wide_70_A :: struct {
	a00, a01, a02, a03, a04, a05, a06, a07, a08, a09: i32 `model:"optional"`,
	a10, a11, a12, a13, a14, a15, a16, a17, a18, a19: i32 `model:"optional"`,
	a20, a21, a22, a23, a24, a25, a26, a27, a28, a29: i32 `model:"optional"`,
	a30, a31, a32, a33, a34, a35, a36, a37, a38, a39: i32 `model:"optional"`,
	a40, a41, a42, a43, a44, a45, a46, a47, a48, a49: i32 `model:"optional"`,
	a50, a51, a52, a53, a54, a55, a56, a57, a58, a59: i32 `model:"optional"`,
	a60, a61, a62, a63, a64, a65, a66, a67, a68, a69: i32 `model:"optional"`,
}

@(private = "file")
Wide_70_B :: struct {
	b00, b01, b02, b03, b04, b05, b06, b07, b08, b09: i32 `model:"optional"`,
	b10, b11, b12, b13, b14, b15, b16, b17, b18, b19: i32 `model:"optional"`,
	b20, b21, b22, b23, b24, b25, b26, b27, b28, b29: i32 `model:"optional"`,
	b30, b31, b32, b33, b34, b35, b36, b37, b38, b39: i32 `model:"optional"`,
	b40, b41, b42, b43, b44, b45, b46, b47, b48, b49: i32 `model:"optional"`,
	b50, b51, b52, b53, b54, b55, b56, b57, b58, b59: i32 `model:"optional"`,
	b60, b61, b62, b63, b64, b65, b66, b67: i32 `model:"optional"`,
	b68: i32,
	b69: string `model:"optional"`,
}

@(test)
model_streaming_wide_structs_and_fields_set :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reg: model.Registry
	defer model.destroy(&reg)
	testing.expect_value(t, model.register(&reg, Wide_70, "f69", "hi"), nil)
	testing.expect_value(t, model.register(&reg, Wide_70_B, "b69", "tail"), nil)

	m70, e70 := model.compile(&reg, Wide_70)
	defer model.destroy(&m70)
	testing.expect_value(t, e70, nil)

	// Boundary test at field indices 62, 63, 64 (crosses `seen0` -> `seen1`) + missing required `f64`.
	w70: Wide_70
	defer model.free_value(&w70, type_info_of(Wide_70), context.allocator)
	testing.expect_value(t, json.load(&m70, transmute([]u8)string(`{"f62":62,"f63":63,"f64":64}`), &w70), nil)
	testing.expect_value(t, w70.f62, i32(62))
	testing.expect_value(t, w70.f63, i32(63))
	testing.expect_value(t, w70.f64, i32(64))
	testing.expect_value(t, w70.f69, "hi")
	testing.expect(t, model.was_set(&m70, Wide_70, w70._set, "f63"))
	testing.expect(t, model.was_set(&m70, Wide_70, w70._set, "f64"))
	testing.expect(t, !model.was_set(&m70, Wide_70, w70._set, "f69"))

	// Duplicate at index 63 & 64 under `.Refuse`.
	dup63: Wide_70
	err_dup := json.load(&m70, transmute([]u8)string(`{"f63":1,"f64":2,"f63":3}`), &dup63)
	defer model.error_destroy(err_dup)
	me_dup, ok_dup := err_dup.(model.Model_Error)
	testing.expect(t, ok_dup && me_dup.kind == .Duplicate_Key)

	// >128 fields (`seen_wide`): tests field 138 (`b68`, required) and default at field 139 (`b69`).
	m140, e140 := model.compile(&reg, Wide_140)
	defer model.destroy(&m140)
	testing.expect_value(t, e140, nil)

	w140: Wide_140
	defer model.free_value(&w140, type_info_of(Wide_140), context.allocator)
	testing.expect_value(t, json.load(&m140, transmute([]u8)string(`{"a00":1,"b68":138}`), &w140), nil)
	testing.expect_value(t, w140.a00, i32(1))
	testing.expect_value(t, w140.b68, i32(138))
	testing.expect_value(t, w140.b69, "tail")
	testing.expect(t, model.was_set(&m140, Wide_140, w140._set, "b68"))
	testing.expect(t, !model.was_set(&m140, Wide_140, w140._set, "b69"))

	dumped, derr := json.dump(&m140, &w140, {exclude_unset = true})
	defer delete(dumped)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, string(dumped), `{"a00":1,"b68":138}`)

	// Missing required field > 128 (`b68`).
	w140_miss: Wide_140
	miss_err := json.load(&m140, transmute([]u8)string(`{"a00":1}`), &w140_miss)
	defer model.error_destroy(miss_err)
	me_miss, ok_miss := miss_err.(model.Model_Error)
	testing.expect(t, ok_miss && me_miss.kind == .Missing_Field && me_miss.pointer == "/b68")
}

@(private = "file")
Strict_Rec :: struct {
	a:     string `model:"len<=5,pattern=^[a-z]{3}$"`,
	b:     i64 `model:">0,<=100"`,
	c:     f64 `model:">=0,<10"`,
	inner: Stream_Inner,
	extra: string `model:"optional"`,
}

@(test)
model_streaming_errors_sink_vs_first_and_rollback :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reg: model.Registry
	defer model.destroy(&reg)
	testing.expect_value(t, model.register(&reg, Strict_Rec, model.Extra.Forbid), nil)
	testing.expect_value(t, model.register_after(&reg, Strict_Rec, "b", proc(v: i64, rep: ^model.Report) {
		if v == 50 { model.fail(rep, "no fifty") }
	}), nil)
	testing.expect_value(t, model.register_validator(&reg, Strict_Rec, proc(v: Strict_Rec, rep: ^model.Report) {
		if v.a == "bad" { model.fail_at(rep, "a", "struct rejected") }
	}), nil)

	m, cerr := model.compile(&reg, Strict_Rec)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	bad_cases := []string{
		`{"a":"123456","b":0,"c":10,"inner":{"x":-1},"rogue":1}`,
		`{"a":"abc","b":50,"c":5.0,"inner":{"x":1}}`,
		`{"a":"bad","b":10,"c":0.0,"inner":{"x":1}}`,
		`{"a":"abc","b":10,"c":1.5}`,
	}
	for raw in bad_cases {
		src := transmute([]u8)raw
		s_stream, s_doc: model.Sink
		defer model.destroy(&s_stream)
		defer model.destroy(&s_doc)

		v1, v2: Strict_Rec
		e1 := json.load(&m, src, &v1, .Json, &s_stream)
		e2 := model.load(&m, src, json.as(.Json), json.reads(.Json), &v2, &s_doc)
		testing.expect(t, e1 != nil && e2 != nil)
		testing.expect_value(t, len(s_stream.entries), len(s_doc.entries))
		for i in 0 ..< min(len(s_stream.entries), len(s_doc.entries)) {
			testing.expect_value(t, s_stream.entries[i].kind, s_doc.entries[i].kind)
			testing.expect_value(t, s_stream.entries[i].pointer, s_doc.entries[i].pointer)
			testing.expect_value(t, s_stream.entries[i].operand, s_doc.entries[i].operand)
		}

		// `first` mode (`sink == nil`): must stop at first error and free partial allocations cleanly.
		v3, v4: Strict_Rec
		f1 := json.load(&m, src, &v3)
		defer model.error_destroy(f1)
		f2 := model.load(&m, src, json.as(.Json), json.reads(.Json), &v4)
		defer model.error_destroy(f2)
		me1, ok1 := f1.(model.Model_Error)
		me2, ok2 := f2.(model.Model_Error)
		testing.expect(t, ok1 && ok2)
		testing.expect_value(t, me1.kind, me2.kind)
		testing.expect_value(t, me1.pointer, me2.pointer)
		testing.expect_value(t, v3.a, "")
	}

	// `max_errors` truncation parity.
	trunc_sink := model.Sink{max_errors = 2}
	defer model.destroy(&trunc_sink)
	vt: Strict_Rec
	testing.expect(t, json.load(&m, transmute([]u8)string(`{"a":"123456","b":0,"c":10,"inner":{"x":-1}}`), &vt, .Json, &trunc_sink) != nil)
	testing.expect_value(t, len(trunc_sink.entries), 2)
	testing.expect(t, trunc_sink.truncated)
}

@(private = "file")
Dup_Rec :: struct {
	a:      string `model:"pattern=^[a-z]+$"`,
	b:      i64 `model:">=0"`,
	nested: Stream_Inner `model:"optional"`,
	c:      string `model:"optional"`,
}

@(test)
model_streaming_duplicate_keys_and_policies :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reg: model.Registry
	defer model.destroy(&reg)
	m, cerr := model.compile(&reg, Dup_Rec)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// Every one of these MUST be refused with `.Duplicate_Key` in BOTH `sink` and `first` modes.
	refuse_cases := []string{
		`{"a":"ok","a":"dup","b":1}`,
		`{"b":1,"a":"ok","b":2}`,
		`{"b":1,"nested":{"x":2},"a":"ok","b":3}`,
		`{"a":"BAD","b":1,"b":2}`,
		`{"a":"BAD","nested":{"x":1,"x":2},"b":1}`,
		`{"a":"ok","b":1,"skip":{"k":1,"k":2}}`,
		`{"a":"ok","b":1,"\u0061":"esc"}`,
		`{"a":"ok","b":1,"c":"x","c":"y"}`,
	}
	for raw in refuse_cases {
		src := transmute([]u8)raw
		v1: Dup_Rec
		e1 := json.load(&m, src, &v1)
		defer model.error_destroy(e1)
		me1, ok1 := e1.(model.Model_Error)
		testing.expectf(t, ok1 && me1.kind == .Duplicate_Key, "first mode expected Duplicate_Key for %s, got %v", raw, e1)

		sink: model.Sink
		defer model.destroy(&sink)
		v2: Dup_Rec
		e2 := json.load(&m, src, &v2, .Json, &sink)
		me2, ok2 := e2.(model.Model_Error)
		testing.expectf(t, ok2 && me2.kind == .Duplicate_Key, "sink mode expected Duplicate_Key for %s, got %v", raw, e2)
		testing.expect_value(t, len(sink.entries), 1)
	}

	// Syntax fault AFTER duplicate key: duplicate key wins (`dup_at < fault.at`); BEFORE: syntax fault wins.
	{
		v: Dup_Rec
		e := json.load(&m, transmute([]u8)string(`{"a":"ok","a":"dup",!}`), &v)
		defer model.error_destroy(e)
		me, ok := e.(model.Model_Error)
		testing.expect(t, ok && me.kind == .Duplicate_Key)
	}

	// `.First` keeps first value, skips second (including nested container).
	{
		v: Dup_Rec
		defer model.free_value(&v, type_info_of(Dup_Rec), context.allocator)
		testing.expect_value(t, json.load(&m, transmute([]u8)string(`{"a":"first","nested":{"x":1},"nested":{"x":99},"a":"second","b":5}`), &v, .Json, nil, {dups = .First}), nil)
		testing.expect_value(t, v.a, "first")
		testing.expect_value(t, v.nested.x, i64(1))
	}

	// `.Last` falls back cleanly and keeps last value.
	{
		v: Dup_Rec
		defer model.free_value(&v, type_info_of(Dup_Rec), context.allocator)
		testing.expect_value(t, json.load(&m, transmute([]u8)string(`{"a":"first","b":1,"a":"last","b":2}`), &v, .Json, nil, {dups = .Last}), nil)
		testing.expect_value(t, v.a, "last")
		testing.expect_value(t, v.b, i64(2))
	}
}

@(private = "file")
Fb_A :: struct { x: i64 }
@(private = "file")
Fb_B :: struct { y: string }
@(private = "file")
Fb_Union :: union { Fb_A, Fb_B }

@(private = "file")
Fb_Bit :: enum u8 { Read, Write, Exec }

@(private = "file")
Fallback_Rec :: struct {
	u:     Fb_Union,
	bits:  bit_set[Fb_Bit],
	val:   rules.Value `model:"optional"`,
	extra: map[string]i64 `json:",unknown"`,
}

@(test)
model_streaming_fallbacks_and_specs :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reg: model.Registry
	defer model.destroy(&reg)
	testing.expect_value(t, model.register(&reg, model.Union_Rule{type = Fb_Union, mode = .Tag, tag = "kind"}), nil)
	testing.expect_value(t, model.register(&reg, model.Enum_Rule{type = Fb_Bit, by_number = false}), nil)

	m, cerr := model.compile(&reg, Fallback_Rec)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	src := transmute([]u8)string(`{"u":{"kind":"Fb_B","y":"hi"},"bits":["Read","Exec"],"val":{"k":[1,true,"s",null]},"z":9,"a":1}`)
	v: Fallback_Rec
	defer model.free_value(&v, type_info_of(Fallback_Rec), context.allocator)
	testing.expect_value(t, json.load(&m, src, &v), nil)
	b_arm, is_b := v.u.(Fb_B)
	testing.expect(t, is_b && b_arm.y == "hi")
	testing.expect_value(t, v.bits, bit_set[Fb_Bit]{.Read, .Exec})
	testing.expect_value(t, v.extra["a"], i64(1))
	testing.expect_value(t, v.extra["z"], i64(9))

	ref, rerr := model.dump(&m, &v, write_json_default)
	defer delete(ref)
	testing.expect_value(t, rerr, nil)
	got, gerr := json.dump(&m, &v)
	defer delete(got)
	testing.expect_value(t, gerr, nil)
	testing.expect_value(t, string(got), string(ref))

	// JSONC comments + JSON5 single quotes / unquoted keys / non-finite refusal.
	mr: model.Model(Stream_Inner)
	mr, cerr = model.compile(&reg, Stream_Inner)
	defer model.destroy(&mr)
	testing.expect_value(t, cerr, nil)

	si1: Stream_Inner
	defer model.free_value(&si1, type_info_of(Stream_Inner), context.allocator)
	testing.expect_value(t, json.load(&mr, transmute([]u8)string(`/* comment */ {"x": 7, "y": "ok"} // tail`), &si1, .Jsonc), nil)
	testing.expect_value(t, si1.x, i64(7))
	testing.expect_value(t, si1.y, "ok")

	si2: Stream_Inner
	defer model.free_value(&si2, type_info_of(Stream_Inner), context.allocator)
	testing.expect_value(t, json.load(&mr, transmute([]u8)string(`{x: 9, y: 'json5',}`), &si2, .Json5), nil)
	testing.expect_value(t, si2.x, i64(9))
	testing.expect_value(t, si2.y, "json5")

	// JSON5 NaN rejected as `.Non_Finite`.
	Float_Box :: struct { f: f64 }
	mf, ef := model.compile(&reg, Float_Box)
	defer model.destroy(&mf)
	testing.expect_value(t, ef, nil)
	fb: Float_Box
	nfe := json.load(&mf, transmute([]u8)string(`{f: NaN}`), &fb, .Json5)
	defer model.error_destroy(nfe)
	nme, is_nme := nfe.(model.Model_Error)
	testing.expect(t, is_nme && nme.kind == .Non_Finite)

	// `json.dump` refuses NaN/Inf and fails `check = true`.
	nan_box := Float_Box{f = math.nan_f64()}
	_, dn_err := json.dump(&mf, &nan_box)
	dn_me, is_dn := dn_err.(model.Model_Error)
	testing.expect(t, is_dn && dn_me.kind == .Non_Finite)

	bad_inner := Stream_Inner{x = -5}
	chk_sink: model.Sink
	defer model.destroy(&chk_sink)
	_, chk_err := json.dump(&mr, &bad_inner, {check = true}, {}, &chk_sink)
	chk_me, is_chk := chk_err.(model.Model_Error)
	testing.expect(t, is_chk && chk_me.kind == .Check_Failed && len(chk_sink.entries) == 1)
}

@(private = "file")
Deep_Node :: struct {
	v:    i32,
	next: ^Deep_Node `model:"optional"`,
}

@(test)
model_streaming_budget_deep_nesting_and_long_strings :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reg: model.Registry
	defer model.destroy(&reg)
	m, cerr := model.compile(&reg, Deep_Node)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// Build 40-level nested JSON (> STREAM_INLINE_FRAMES=16 and > DUMP_INLINE_FRAMES=32).
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for i in 0 ..< 40 {
		fmt.sbprintf(&sb, `{{"v":%d,"next":`, i)
	}
	strings.write_string(&sb, `{"v":40}`)
	for _ in 0 ..< 40 {
		strings.write_byte(&sb, '}')
	}
	deep_src := transmute([]u8)strings.to_string(sb)

	// Depth budget refuses 40-level nesting cleanly without leaking.
	limited: Deep_Node
	dep_err := json.load(&m, deep_src, &limited, .Json, nil, {budget = {depth = 10}})
	_, is_tape_err := dep_err.(tape.Error)
	testing.expect(t, is_tape_err)

	// Node budget refuses cleanly.
	node_err := json.load(&m, deep_src, &limited, .Json, nil, {budget = {nodes = 5}})
	_, is_node_err := node_err.(tape.Error)
	testing.expect(t, is_node_err)

	// Unbounded load + dump roundtrip grows both inline frame stacks cleanly.
	deep: Deep_Node
	defer model.free_value(&deep, type_info_of(Deep_Node), context.allocator)
	testing.expect_value(t, json.load(&m, deep_src, &deep), nil)
	dumped, derr := json.dump(&m, &deep, {exclude_none = true})
	defer delete(dumped)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, string(dumped), string(deep_src))

	// Long strings (> 4096 B): clean ASCII, escaped ASCII, UTF-8, and invalid UTF-8 refusal in `json.dump`.
	Str_Box :: struct { s: string }
	ms, es := model.compile(&reg, Str_Box)
	defer model.destroy(&ms)
	testing.expect_value(t, es, nil)

	long_sb := strings.builder_make()
	defer strings.builder_destroy(&long_sb)
	for _ in 0 ..< 300 {
		strings.write_string(&long_sb, `hello "escaped" 日本語 0123456789 `)
	}
	long_box := Str_Box{s = strings.to_string(long_sb)}
	long_json, lerr := json.dump(&ms, &long_box)
	defer delete(long_json)
	testing.expect_value(t, lerr, nil)

	long_ref, lrerr := model.dump(&ms, &long_box, write_json_default)
	defer delete(long_ref)
	testing.expect_value(t, lrerr, nil)
	testing.expect_value(t, string(long_json), string(long_ref))

	reloaded: Str_Box
	defer model.free_value(&reloaded, type_info_of(Str_Box), context.allocator)
	testing.expect_value(t, json.load(&ms, long_json, &reloaded), nil)
	testing.expect_value(t, reloaded.s, long_box.s)

	bad_bytes := [3]u8{0xff, 0xfe, 'a'}
	bad_utf8 := Str_Box{s = string(bad_bytes[:])}
	_, uerr := json.dump(&ms, &bad_utf8)
	_, is_werr := uerr.(write.Error)
	testing.expect(t, is_werr)
}

// ============================================================================
// Audit regression tests (memory safety, leaks, budgets, JSON5, edge parity)
// ============================================================================

@(private = "file")
Long_Tag_Arm :: struct {
	v: i32,
}

@(private = "file")
Long_Tag_Union :: union {
	Long_Tag_Arm,
}

@(private = "file")
Dump_Key_Bounds_Rec :: struct {
	pad:    string,
	cafe:   i32 `json:"café_123456789012345678"`,
	scores: map[string]i32,
	u:      Long_Tag_Union,
	val:    rules.Value `model:"optional"`,
	extra:  map[string]i32 `json:",unknown"`,
}

// Regression #1: `dump_json` key emissions (non-ASCII struct key, map key, capture key, union `tag_key`,
// and `rules.Value` object key) with 16..32 B keys across tight `write.Out` buffer boundaries (ASan).
@(test)
model_streaming_dump_key_buffer_boundaries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reg: model.Registry
	defer model.destroy(&reg)
	testing.expect_value(t, model.register(&reg, model.Union_Rule{
		type = Long_Tag_Union,
		mode = .Tag,
		tag  = "long_union_tag_key_24chr",
	}), nil)

	m, cerr := model.compile(&reg, Dump_Key_Bounds_Rec)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// Sweep prefix padding across the 4 KiB write.Out flush boundary so every key emission site
	// lands with 0..64 B remaining in the buffer before `put_string` reserves `JSON_LEAF_ROOM`.
	base_pad := strings.repeat("a", 4096)
	defer delete(base_pad)

	scores := make(map[string]i32)
	defer delete(scores)
	scores["k16_123456789012"] = 1
	scores["k24_12345678901234567890"] = 2
	scores["k32_1234567890123456789012345678"] = 3

	extra := make(map[string]i32)
	defer delete(extra)
	extra["cap_key_20_123456789"] = 10
	extra["cap_key_32_123456789012345678901"] = 20

	val_members := []rules.Member_Value{
		{key = "val_key_16_12345", value = i64(1)},
		{key = "val_key_28_12345678901234567", value = i64(2)},
		{key = "val_key_32_123456789012345678901", value = i64(3)},
	}

	for pad_len in 3980 ..< 4080 {
		rec := Dump_Key_Bounds_Rec{
			pad    = base_pad[:pad_len],
			cafe   = 7,
			scores = scores,
			u      = Long_Tag_Arm{v = 9},
			val    = rules.Value(val_members),
			extra  = extra,
		}
		got, gerr := json.dump(&m, &rec)
		testing.expect_value(t, gerr, nil)
		if pad_len == 3980 || pad_len == 4050 {
			ref, rerr := model.dump(&m, &rec, write_json_default)
			testing.expect_value(t, rerr, nil)
			testing.expect_value(t, string(got), string(ref))
			delete(ref)
		}
		delete(got)

		got_p, gperr := json.dump(&m, &rec, {}, {indent = 2})
		testing.expect_value(t, gperr, nil)
		delete(got_p)
	}
}

@(private = "file")
Wide_140_Plain :: struct {
	using a: Wide_70_A,
	using b: Wide_70_B_Opt,
}

@(private = "file")
Wide_70_B_Opt :: struct {
	b00, b01, b02, b03, b04, b05, b06, b07, b08, b09: i32 `model:"optional"`,
	b10, b11, b12, b13, b14, b15, b16, b17, b18, b19: i32 `model:"optional"`,
	b20, b21, b22, b23, b24, b25, b26, b27, b28, b29: i32 `model:"optional"`,
	b30, b31, b32, b33, b34, b35, b36, b37, b38, b39: i32 `model:"optional"`,
	b40, b41, b42, b43, b44, b45, b46, b47, b48, b49: i32 `model:"optional"`,
	b50, b51, b52, b53, b54, b55, b56, b57, b58, b59: i32 `model:"optional"`,
	b60, b61, b62, b63, b64, b65, b66, b67, b68, b69: i32 `model:"optional"`,
}

@(private = "file")
Map_Leaks_Rec :: struct {
	ms:  map[string]string `model:"optional"`,
	mi:  map[i64]string `model:"optional"`,
	mn:  map[string]i64 `model:"optional"`,
	mobj: map[string]Stream_Inner `model:"optional"`,
}

// Regressions #2a, #2b, #2c, #4: leak-checked map duplicate/collision overwrites, `.Refuse` Wrong_Kind container skip,
// fast-close >128-field struct `seen_wide` cleanup, and mid-map-entry syntax fault cleanup.
@(test)
model_streaming_leak_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reg: model.Registry
	defer model.destroy(&reg)

	mm, em := model.compile(&reg, Map_Leaks_Rec)
	defer model.destroy(&mm)
	testing.expect_value(t, em, nil)

	// #2a-1: duplicate string map key under `.Refuse` (both first and sink modes) — zero leak.
	{
		v: Map_Leaks_Rec
		e := json.load(&mm, transmute([]u8)string(`{"ms":{"a":"v1","a":"v2"}}`), &v)
		defer model.error_destroy(e)
		me, ok := e.(model.Model_Error)
		testing.expect(t, ok && me.kind == .Duplicate_Key)
	}
	{
		sink: model.Sink
		defer model.destroy(&sink)
		v: Map_Leaks_Rec
		e := json.load(&mm, transmute([]u8)string(`{"ms":{"a":"v1","a":"v2"}}`), &v, .Json, &sink)
		me, ok := e.(model.Model_Error)
		testing.expect(t, ok && me.kind == .Duplicate_Key)
	}

	// #2a-2: distinct JSON keys colliding as `i64` (`"1"` and `"01"`) — valid JSON, overwrites without leaking `"v1"`.
	{
		v: Map_Leaks_Rec
		defer model.free_value(&v, type_info_of(Map_Leaks_Rec), context.allocator)
		testing.expect_value(t, json.load(&mm, transmute([]u8)string(`{"mi":{"1":"v1","01":"v2"}}`), &v), nil)
		testing.expect_value(t, v.mi[1], "v2")
	}

	// #2b: `.Refuse` + `sink != nil`, map value fails `Wrong_Kind` with `.Object`/`.Array` — key must not leak.
	for bad_val in ([]string{`{"mn":{"k_obj":{"nested":1}}}`, `{"mn":{"k_arr":[1,2,3],"ok":5}}`}) {
		sink: model.Sink
		defer model.destroy(&sink)
		v: Map_Leaks_Rec
		e := json.load(&mm, transmute([]u8)bad_val, &v, .Json, &sink)
		testing.expect(t, e != nil)
		testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Wrong_Kind)
	}

	// #2c: >128-field struct with NO Fields_Set / defaults / required / validators hits fast struct-close — `seen_wide` must not leak.
	{
		mp, ep := model.compile(&reg, Wide_140_Plain)
		defer model.destroy(&mp)
		testing.expect_value(t, ep, nil)
		vp: Wide_140_Plain
		testing.expect_value(t, json.load(&mp, transmute([]u8)string(`{"a00":1,"b69":139}`), &vp), nil)
		testing.expect_value(t, vp.a00, i32(1))
		testing.expect_value(t, vp.b69, i32(139))
	}

	// #4: mid-map-entry syntax fault (both leaf and nested struct value) — decoded key + partial value must not leak.
	for truncated in ([]string{
		`{"ms":{"allocated_key":"val`,
		`{"mobj":{"allocated_key":{"x":5,"y":"partial_str`,
	}) {
		v: Map_Leaks_Rec
		e := json.load(&mm, transmute([]u8)truncated, &v)
		_, is_tape := e.(tape.Error)
		testing.expect(t, is_tape)
	}
}

@(private = "file")
Fixed_Len_Rec :: struct {
	arr: [2]i32 `model:"len>=2,len<=2"`,
}

@(private = "file")
Forbid_Extra_Rec :: struct {
	a:  i32 `model:"optional"`,
	ro: i32 `model:"read_only"`,
}

@(private = "file")
Json5_Num_Rec :: struct {
	mul:  i64 `model:"multiple_of=4,optional"`,
	flt:  f64 `model:"multiple_of=0.5,optional"`,
	code: Stream_Code `model:"optional"`,
	num:  model.Number_Text `model:"optional"`,
	dec:  model.Decimal `model:"optional"`,
}

@(private = "file")
Min_I64_Bound_Rec :: struct {
	x: f64 `model:">=-9223372036854775808"`,
}

@(private = "file")
Cycle_Node :: struct {
	next: ^Cycle_Node `model:"optional"`,
}

@(private = "file")
Cap_Collision_Rec :: struct {
	a:     i32,
	extra: map[string]i32 `json:",unknown"`,
}

// Regressions #3, #5, #6, #7, #8, #9, #10, #11, #12c/d.
@(test)
model_streaming_audit_parity_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reg: model.Registry
	defer model.destroy(&reg)
	testing.expect_value(t, model.register(&reg, model.Enum_Rule{type = Stream_Code, by_number = true}), nil)
	testing.expect_value(t, model.register(&reg, Forbid_Extra_Rec, model.Extra.Forbid), nil)

	// #3: `opts.budget.memory > 0` returns `Exceeded{kind = .Memory}` cleanly with zero uninitialized reads (ASan).
	{
		Str_Box :: struct { s: string }
		ms, es := model.compile(&reg, Str_Box)
		defer model.destroy(&ms)
		testing.expect_value(t, es, nil)
		big := strings.repeat("x", 512)
		defer delete(big)
		payload := fmt.aprintf(`{{"s":"%s"}}`, big)
		defer delete(payload)
		v: Str_Box
		err := json.load(&ms, transmute([]u8)payload, &v, .Json, nil, {budget = {memory = 64}})
		te, is_te := err.(tape.Error)
		exc, is_exc := te.(tape.Exceeded)
		testing.expect(t, is_te && is_exc && exc.kind == .Memory)
	}

	// #5: `sink.truncated` restored across fallback `load_via_build`.
	{
		md, ed := model.compile(&reg, Dup_Rec)
		defer model.destroy(&md)
		testing.expect_value(t, ed, nil)
		sink := model.Sink{max_errors = 1}
		defer model.destroy(&sink)
		// First error triggers `a` pattern fail + `b` bound fail -> `truncated = true`, then `.Last` duplicate `b` triggers fallback!
		// Because the last `a` and `b` are BOTH valid, fallback succeeds and `sink.truncated` MUST be false!
		v: Dup_Rec
		defer model.free_value(&v, type_info_of(Dup_Rec), context.allocator)
		err := json.load(&md, transmute([]u8)string(`{"a":"BAD","b":-1,"a":"good","b":5}`), &v, .Json, &sink, {dups = .Last})
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(sink.entries), 0)
		testing.expect(t, !sink.truncated)
	}

	// #6: `.First` duplicate map entry where 1st occurrence has invalid value, 2nd has valid value -> parity with `model.load`.
	{
		mm, em := model.compile(&reg, Map_Leaks_Rec)
		defer model.destroy(&mm)
		testing.expect_value(t, em, nil)
		src := transmute([]u8)string(`{"mn":{"k":"bad","k":42}}`)
		s1, s2: model.Sink
		defer model.destroy(&s1)
		defer model.destroy(&s2)
		v1, v2: Map_Leaks_Rec
		e1 := json.load(&mm, src, &v1, .Json, &s1, {dups = .First})
		e2 := model.load(&mm, src, json.as(.Json), json.reads(.Json), &v2, &s2, {dups = .First})
		testing.expect(t, e1 != nil && e2 != nil)
		testing.expect_value(t, len(s1.entries), len(s2.entries))
		if len(s1.entries) > 0 && len(s2.entries) > 0 {
			testing.expect_value(t, s1.entries[0].kind, s2.entries[0].kind)
			testing.expect_value(t, s1.entries[0].pointer, s2.entries[0].pointer)
		}
	}

	// #7: Fixed `[2]i32` with `len>=2,len<=2` emits single `Too_Few`/`Too_Many` (no double emission).
	{
		mf, ef := model.compile(&reg, Fixed_Len_Rec)
		defer model.destroy(&mf)
		testing.expect_value(t, ef, nil)
		for raw in ([]string{`{"arr":[1]}`, `{"arr":[1,2,3]}`}) {
			s1, s2: model.Sink
			defer model.destroy(&s1)
			defer model.destroy(&s2)
			v1, v2: Fixed_Len_Rec
			_ = json.load(&mf, transmute([]u8)raw, &v1, .Json, &s1)
			_ = model.load(&mf, transmute([]u8)raw, json.as(.Json), json.reads(.Json), &v2, &s2)
			testing.expect_value(t, len(s1.entries), 1)
			testing.expect_value(t, len(s1.entries), len(s2.entries))
			testing.expect_value(t, s1.entries[0].kind, s2.entries[0].kind)
		}
	}

	// #8: `Budget.depth` parity on root `^i64`, `^Stream_Inner`, `^^Stream_Inner`.
	{
		mp1, _ := model.compile(&reg, ^i64)
		defer model.destroy(&mp1)
		p1a, p1b: ^i64
		defer model.free_value(&p1a, type_info_of(^i64), context.allocator)
		defer model.free_value(&p1b, type_info_of(^i64), context.allocator)
		e1a := json.load(&mp1, transmute([]u8)string(`42`), &p1a, .Json, nil, {budget = {depth = 1}})
		e1b := model.load(&mp1, transmute([]u8)string(`42`), json.as(.Json), json.reads(.Json), &p1b, nil, {budget = {depth = 1}})
		testing.expect_value(t, e1a, nil)
		testing.expect_value(t, e1b, nil)
		testing.expect(t, p1a != nil && p1a^ == 42)

		mp2, _ := model.compile(&reg, ^Stream_Inner)
		defer model.destroy(&mp2)
		p2a, p2b: ^Stream_Inner
		e2a := json.load(&mp2, transmute([]u8)string(`{"x":1}`), &p2a, .Json, nil, {budget = {depth = 1}})
		e2b := model.load(&mp2, transmute([]u8)string(`{"x":1}`), json.as(.Json), json.reads(.Json), &p2b, nil, {budget = {depth = 1}})
		_, t2a := e2a.(tape.Error)
		_, t2b := e2b.(tape.Error)
		testing.expect(t, t2a && t2b)

		mp3, _ := model.compile(&reg, ^^Stream_Inner)
		defer model.destroy(&mp3)
		p3a, p3b: ^^Stream_Inner
		e3a := json.load(&mp3, transmute([]u8)string(`{"x":1}`), &p3a, .Json, nil, {budget = {depth = 2}})
		e3b := model.load(&mp3, transmute([]u8)string(`{"x":1}`), json.as(.Json), json.reads(.Json), &p3b, nil, {budget = {depth = 2}})
		_, t3a := e3a.(tape.Error)
		_, t3b := e3b.(tape.Error)
		testing.expect(t, t3a && t3b)
	}

	// #9: JSON5 numbers (`0x10`, `.5`, `5.`, `+200`) parity across `multiple_of`, integer `Enum`, `Number_Text`, `Decimal`.
	{
		mj, ej := model.compile(&reg, Json5_Num_Rec)
		defer model.destroy(&mj)
		testing.expect_value(t, ej, nil)
		src := transmute([]u8)string(`{mul: 0x10, flt: .5, code: +200, num: 5., dec: 0x20}`)
		v1, v2: Json5_Num_Rec
		defer model.free_value(&v1, type_info_of(Json5_Num_Rec), context.allocator)
		defer model.free_value(&v2, type_info_of(Json5_Num_Rec), context.allocator)
		testing.expect_value(t, json.load(&mj, src, &v1, .Json5), nil)
		testing.expect_value(t, model.load(&mj, src, json.as(.Json5), json.reads(.Json5), &v2), nil)
		testing.expect_value(t, v1.mul, v2.mul)
		testing.expect_value(t, v1.flt, v2.flt)
		testing.expect_value(t, v1.code, v2.code)
		testing.expect_value(t, v1.num.text, v2.num.text)
		testing.expect_value(t, v1.dec.text, v2.dec.text)
	}

	// #10: `Extra.Forbid` repeated unknown / `Read_Only` keys under `.First` & `.Last` -> exact parity with `model.load`.
	{
		mfe, efe := model.compile(&reg, Forbid_Extra_Rec)
		defer model.destroy(&mfe)
		testing.expect_value(t, efe, nil)
		src := transmute([]u8)string(`{"x":1,"ro":2,"x":3,"ro":4}`)
		for pol in ([]tape.Duplicates{.First, .Last}) {
			s1, s2: model.Sink
			defer model.destroy(&s1)
			defer model.destroy(&s2)
			v1, v2: Forbid_Extra_Rec
			_ = json.load(&mfe, src, &v1, .Json, &s1, {dups = pol})
			_ = model.load(&mfe, src, json.as(.Json), json.reads(.Json), &v2, &s2, {dups = pol})
			testing.expect_value(t, len(s1.entries), len(s2.entries))
			for i in 0 ..< min(len(s1.entries), len(s2.entries)) {
				testing.expect_value(t, s1.entries[i].kind, s2.entries[i].kind)
				testing.expect_value(t, s1.entries[i].pointer, s2.entries[i].pointer)
				testing.expect_value(t, s1.entries[i].at, s2.entries[i].at)
			}
		}
	}

	// #11: `min(i64)` bound on `f64` does not overflow `abs(min(i64))`.
	{
		mmn, emn := model.compile(&reg, Min_I64_Bound_Rec)
		defer model.destroy(&mmn)
		testing.expect_value(t, emn, nil)
		v: Min_I64_Bound_Rec
		testing.expect_value(t, json.load(&mmn, transmute([]u8)string(`{"x":0.0}`), &v), nil)
		testing.expect_value(t, v.x, 0.0)
	}

	// #12c: cyclic pointer in `json.dump` stops cleanly at `tape.DEFAULT_DEPTH` (`Exceeded{kind = .Depth}`).
	{
		mc, ec := model.compile(&reg, Cycle_Node)
		defer model.destroy(&mc)
		testing.expect_value(t, ec, nil)
		cyc: Cycle_Node
		cyc.next = &cyc
		_, derr := json.dump(&mc, &cyc)
		te, is_te := derr.(tape.Error)
		exc, is_exc := te.(tape.Exceeded)
		testing.expect(t, is_te && is_exc && exc.kind == .Depth)
	}

	// #12d: capture key collision and `.Non_Finite` record to `sink` in `json.dump`.
	{
		mcc, ecc := model.compile(&reg, Cap_Collision_Rec)
		defer model.destroy(&mcc)
		testing.expect_value(t, ecc, nil)
		ex := make(map[string]i32)
		defer delete(ex)
		ex["a"] = 99
		rec := Cap_Collision_Rec{a = 1, extra = ex}
		sink: model.Sink
		defer model.destroy(&sink)
		_, derr := json.dump(&mcc, &rec, {}, {}, &sink)
		me, is_me := derr.(model.Model_Error)
		testing.expect(t, is_me && me.kind == .Duplicate_Key)
		testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Duplicate_Key)

		Float_Box :: struct { f: f64 }
		mf, _ := model.compile(&reg, Float_Box)
		defer model.destroy(&mf)
		nb := Float_Box{f = math.inf_f64(1)}
		fsink: model.Sink
		defer model.destroy(&fsink)
		_, ferr := json.dump(&mf, &nb, {}, {}, &fsink)
		fme, is_fme := ferr.(model.Model_Error)
		testing.expect(t, is_fme && fme.kind == .Non_Finite)
		testing.expect(t, len(fsink.entries) == 1 && fsink.entries[0].kind == .Non_Finite)
	}
}
