package model_test

import "base:runtime"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/model"
import "stury:lib/schema/rules"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

// ============================================================================
// C1: `Model_Error.pointer` UAF regression (both `sink == nil` and `sink != nil`)
// ============================================================================

@(test)
c1_error_pointer_lifetime_with_and_without_sink :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Addr :: struct {
		zip: int `model:">=10000"`,
	}
	Span :: struct {
		low, high: int,
	}
	User :: struct {
		addr:  Addr,
		items: []int `model:"len>=1"`,
		span:  Span,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, Span, proc(v: Span, r: ^model.Report) {
		if v.low > v.high {
			model.fail_at(r, "high", "high below low")
		}
	})

	m, cerr := model.compile(&reg, User)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// (1) Nested error on `/addr/zip` with `sink == nil`: pointer must be valid after load returns!
	u1: User
	err1 := model.load(&m, transmute([]u8)string(`{"addr":{"zip":5},"items":[1],"span":{"low":1,"high":2}}`), json.as(.Json), json.reads(.Json), &u1)
	defer model.error_destroy(err1)
	me1, ok1 := err1.(model.Model_Error)
	testing.expect(t, ok1)
	testing.expect_value(t, me1.kind, model.Error_Kind.Below_Minimum)
	testing.expect_value(t, me1.pointer, "/addr/zip")
	testing.expect(t, me1.owned)

	// (2) Nested error on `/items/0` with `sink == nil`!
	u2: User
	err2 := model.load(&m, transmute([]u8)string(`{"addr":{"zip":12345},"items":["bad"],"span":{"low":1,"high":2}}`), json.as(.Json), json.reads(.Json), &u2)
	defer model.error_destroy(err2)
	me2, ok2 := err2.(model.Model_Error)
	testing.expect(t, ok2)
	testing.expect_value(t, me2.kind, model.Error_Kind.Wrong_Kind)
	testing.expect_value(t, me2.pointer, "/items/0")

	// (3) Nested `fail_at` error on `/span/high` with `sink == nil`!
	u3: User
	err3 := model.load(&m, transmute([]u8)string(`{"addr":{"zip":12345},"items":[1],"span":{"low":9,"high":2}}`), json.as(.Json), json.reads(.Json), &u3)
	defer model.error_destroy(err3)
	me3, ok3 := err3.(model.Model_Error)
	testing.expect(t, ok3)
	testing.expect_value(t, me3.kind, model.Error_Kind.Custom)
	testing.expect_value(t, me3.pointer, "/span/high")
	testing.expect_value(t, me3.want.text, "high below low")

	// (4) Same nested errors with `sink != nil`: returned `Model_Error.pointer` borrows from `sink` arena!
	sink: model.Sink
	defer model.destroy(&sink)
	u4: User
	err4 := model.load(&m, transmute([]u8)string(`{"addr":{"zip":5},"items":[1],"span":{"low":9,"high":2}}`), json.as(.Json), json.reads(.Json), &u4, &sink)
	me4, ok4 := err4.(model.Model_Error)
	testing.expect(t, ok4)
	testing.expect_value(t, me4.pointer, "/addr/zip")
	testing.expect(t, !me4.owned)

	// (5) `validate` and `dump(..., {check = true})` with `sink == nil` return live nested pointer!
	bad_in := User{addr = {zip = 3}, items = {1}, span = {1, 2}}
	verr := model.validate(&m, &bad_in)
	defer model.error_destroy(verr)
	vme, vok := verr.(model.Model_Error)
	testing.expect(t, vok && vme.pointer == "/addr/zip" && vme.kind == .Below_Minimum)

	dumped, derr := model.dump(&m, &bad_in, write_json_default, {check = true})
	defer delete(dumped)
	defer model.error_destroy(derr)
	dme, dok := derr.(model.Model_Error)
	testing.expect(t, dok && dme.kind == .Check_Failed && dme.pointer == "/addr/zip" && dme.want.text == "below_minimum")
}

// ============================================================================
// C2: Multi-field `before`/`after` hooks — zero double-free or leak under ASan
// ============================================================================

@(test)
c2_multi_field_before_and_after_hooks_no_double_free :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Multi :: struct {
		a: string,
		b: string,
		c: string,
		d: string,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	trim_before :: proc(v: rules.Value, r: ^model.Report) -> rules.Value {
		if s, ok := v.(string); ok {
			t2 := strings.trim_space(s)
			if t2 == "BAD" {
				model.fail(r, "bad before")
			}
			return t2
		}
		return v
	}
	check_after :: proc(v: string, r: ^model.Report) {
		if v == "NOPE" {
			model.fail(r, "bad after")
		}
	}
	for name in ([4]string{"a", "b", "c", "d"}) {
		_ = model.register(&reg, Multi, name, trim_before)
		_ = model.register(&reg, Multi, name, check_after)
	}

	m, cerr := model.compile(&reg, Multi)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// Passing case.
	ok_val: Multi
	defer model.free_value(&ok_val, type_info_of(Multi), context.allocator)
	testing.expect_value(t, model.load(&m, transmute([]u8)string(`{"a":" 1 ","b":" 2 ","c":" 3 ","d":" 4 "}`), json.as(.Json), json.reads(.Json), &ok_val), nil)
	testing.expect(t, ok_val.a == "1" && ok_val.b == "2" && ok_val.c == "3" && ok_val.d == "4")
	testing.expect_value(t, model.validate(&m, &ok_val), nil)

	// Multiple failing before & after hooks in one load + validate.
	sink: model.Sink
	defer model.destroy(&sink)
	bad_val: Multi
	err := model.load(&m, transmute([]u8)string(`{"a":"BAD","b":"NOPE","c":"BAD","d":"NOPE"}`), json.as(.Json), json.reads(.Json), &bad_val, &sink)
	testing.expect(t, err != nil)
	testing.expect_value(t, len(sink.entries), 4)

	model.sink_clear(&sink)
	in_bad := Multi{a = "NOPE", b = "ok", c = "NOPE", d = "NOPE"}
	testing.expect(t, model.validate(&m, &in_bad, &sink) != nil)
	testing.expect_value(t, len(sink.entries), 3)
}

// ============================================================================
// C3: Pure `Maybe(^T)` / `Maybe(cstring)` default registration (no OOB tag write)
// ============================================================================

@(test)
c3_pure_maybe_pointer_and_cstring_defaults :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Ptr_Holder :: struct {
		p: Maybe(^int) `model:"optional"`,
		c: Maybe(cstring) `model:"optional"`,
		n: int,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	nil_ptr: ^int = nil
	non_nil_c: cstring = "hello"
	testing.expect_value(t, model.register(&reg, Ptr_Holder, "p", nil_ptr), nil)
	testing.expect_value(t, model.register(&reg, Ptr_Holder, "c", non_nil_c), nil)

	m, cerr := model.compile(&reg, Ptr_Holder)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	v: Ptr_Holder
	defer model.free_value(&v, type_info_of(Ptr_Holder), context.allocator)
	testing.expect_value(t, model.load(&m, transmute([]u8)string(`{"n":7}`), json.as(.Json), json.reads(.Json), &v), nil)
	testing.expect_value(t, v.n, 7)
	testing.expect(t, v.p == nil)
	testing.expect(t, v.c != nil && v.c.? == "hello")
}

// ============================================================================
// C4: Deep iterative recursion (3,000 levels) + `Budget` enforcement
// ============================================================================

@(test)
c4_deep_recursive_struct_and_budget_enforcement :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Node :: struct {
		val:  int `model:">=0"`,
		next: ^Node `model:"optional"`,
		set:  model.Fields_Set,
	}

	m, cerr := model.compile(nil, Node)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// Build a 3,000-level nested JSON chain: `{"val":0,"next":{"val":1,...}}`.
	DEPTH :: 3000
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< DEPTH {
		strings.write_string(&b, `{"val":`)
		strings.write_int(&b, i)
		if i + 1 < DEPTH {
			strings.write_string(&b, `,"next":`)
		}
	}
	for _ in 0 ..< DEPTH {
		strings.write_byte(&b, '}')
	}
	deep_json := strings.to_string(b)

	// Load, validate, dump_document, and free_value must ALL succeed iteratively without stack overflow!
	root: Node
	defer model.free_value(&root, type_info_of(Node), context.allocator)
	testing.expect_value(t, model.load(&m, transmute([]u8)deep_json, json.as(.Json), json.reads(.Json), &root), nil)

	cur := &root
	count := 0
	for cur != nil {
		testing.expect_value(t, cur.val, count)
		count += 1
		cur = cur.next
	}
	testing.expect_value(t, count, DEPTH)
	testing.expect_value(t, model.validate(&m, &root), nil)

	ddoc, derr := model.dump_document(&m, &root)
	defer tape.destroy(&ddoc)
	testing.expect_value(t, derr, nil)

	// Budget exhaustion tests: depth, nodes, steps, memory!
	small_src := `{"val":1,"next":{"val":2,"next":{"val":3,"next":{"val":4,"next":{"val":5,"next":{"val":6}}}}}}`
	doc, berr := json.build(transmute([]u8)small_src)
	defer tape.destroy(&doc)
	testing.expect_value(t, berr, nil)

	expect_exceeded :: proc(t: ^testing.T, err: model.Error, want: tape.Budget_Kind, label: string, loc := #caller_location) {
		te, ok1 := err.(tape.Error)
		ex, ok2 := te.(tape.Exceeded)
		testing.expectf(t, ok1 && ok2 && ex.kind == want, "%s: want %v exceeded, got %v", label, want, err, loc = loc)
	}

	// (1) Depth budget exceeded on load_document and validate.
	out_d: Node
	expect_exceeded(t, model.load_document(&m, &doc, &out_d, opts = {budget = {depth = 3}}), .Depth, "load depth")
	expect_exceeded(t, model.validate(&m, &root, opts = {budget = {depth = 10}}), .Depth, "validate depth")

	// (2) Nodes budget exceeded on load_document and validate.
	out_n: Node
	expect_exceeded(t, model.load_document(&m, &doc, &out_n, opts = {budget = {nodes = 4}}), .Nodes, "load nodes")
	expect_exceeded(t, model.validate(&m, &root, opts = {budget = {nodes = 5}}), .Nodes, "validate nodes")

	// (3) Steps budget exceeded on load_document and patch_document.
	out_s: Node
	expect_exceeded(t, model.load_document(&m, &doc, &out_s, opts = {budget = {steps = 3}}), .Steps, "load steps")

	dst_p := Node{val = 0}
	expect_exceeded(t, model.patch_document(&m, &dst_p, &doc, opts = {budget = {steps = 2}}), .Steps, "patch steps")

	// (4) Memory budget exceeded on deep load_document.
	deep_doc, dberr := json.build(transmute([]u8)deep_json)
	defer tape.destroy(&deep_doc)
	testing.expect_value(t, dberr, nil)
	out_m: Node
	expect_exceeded(t, model.load_document(&m, &deep_doc, &out_m, opts = {budget = {memory = 1024}}), .Memory, "load memory")
}

// ============================================================================
// C6: ARM64 float -> int default exact non-saturating bounds
// ============================================================================

@(test)
c6_float_to_int_default_bounds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Nums :: struct {
		si: i64,
		ui: u64,
	}

	// Valid exact floats: `2^50` on i64 and `2^63` (`9223372036854775808.0`) on u64!
	reg_ok: model.Registry
	defer model.destroy(&reg_ok)
	_ = model.register(&reg_ok, Nums, "si", f64(i64(1) << 50))
	_ = model.register(&reg_ok, Nums, "ui", f64(9223372036854775808.0))
	m_ok, err_ok := model.compile(&reg_ok, Nums)
	defer model.destroy(&m_ok)
	testing.expect_value(t, err_ok, nil)
	v: Nums
	testing.expect_value(t, model.load(&m_ok, transmute([]u8)string(`{}`), json.as(.Json), json.reads(.Json), &v), nil)
	testing.expect_value(t, v.si, i64(1) << 50)
	testing.expect_value(t, v.ui, u64(1) << 63)

	// Rejected boundary cases are refused immediately on `register` as `.Wrong_Kind`.
	bad_si := [?]f64{math.nan_f64(), math.inf_f64(1), math.inf_f64(-1), 1.5, 9223372036854775808.0}
	for x in bad_si {
		reg: model.Registry
		defer model.destroy(&reg)
		re := model.register(&reg, Nums, "si", x)
		me, is_me := re.(model.Model_Error)
		testing.expectf(t, is_me && me.kind == .Wrong_Kind, "i64 default %v should fail, got %v", x, re)
	}
	bad_ui := [?]f64{math.nan_f64(), math.inf_f64(1), -1.0, 2.5, 18446744073709551616.0}
	for x in bad_ui {
		reg: model.Registry
		defer model.destroy(&reg)
		re := model.register(&reg, Nums, "ui", x)
		me, is_me := re.(model.Model_Error)
		testing.expectf(t, is_me && me.kind == .Wrong_Kind, "u64 default %v should fail, got %v", x, re)
	}
}

// ============================================================================
// C7: Automatic rollback on failed load — zero leaks WITHOUT caller `free_value`
// ============================================================================

@(test)
c7_failed_load_auto_rollback_zero_leaks :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Child :: struct {
		label: string,
	}
	Rich :: struct {
		name:  string,
		tags:  []string,
		meta:  map[string]string,
		child: ^Child,
		score: int `model:">=100"`,
	}

	m, cerr := model.compile(nil, Rich)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)

	// Late field `score` fails validation AFTER `name`, `tags`, `meta`, and `child` have already allocated!
	// Caller does NOT call `model.free_value(&r, ...)` — `load` itself must roll back cleanly!
	r: Rich
	err := model.load(&m, transmute([]u8)string(`{"name":"ada","tags":["x","y","z"],"meta":{"k1":"v1","k2":"v2"},"child":{"label":"sub"},"score":5}`), json.as(.Json), json.reads(.Json), &r, allocator = a)
	testing.expect(t, err != nil)
	model.error_destroy(err, a)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect(t, r.name == "" && r.tags == nil && r.meta == nil && r.child == nil && r.score == 0)
}

// ============================================================================
// H1: XML attributes, `#text`, and `.Group` repeated elements
// ============================================================================

@(test)
h1_xml_attributes_text_and_grouped_repeated_elements :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// (1) Element with attribute + text content -> `#text`.
	Item :: struct {
		id:   string,
		text: string `xml:"#text"`,
	}
	Item_Doc :: struct {
		item: Item,
	}
	m1, c1 := model.compile(nil, Item_Doc, "xml")
	defer model.destroy(&m1)
	testing.expect_value(t, c1, nil)

	d1: Item_Doc
	defer model.free_value(&d1, type_info_of(Item_Doc), context.allocator)
	testing.expect_value(t, model.load(&m1, transmute([]u8)string(`<item id="7">hello</item>`), xml.as(.Xml), xml.reads(.Xml), &d1), nil)
	testing.expect_value(t, d1.item.id, "7")
	testing.expect_value(t, d1.item.text, "hello")

	// (2) Repeated child elements grouped into slice under XML's `.Group` default duplicate policy!
	Root :: struct {
		id:   string,
		name: string,
		tag:  []string,
	}
	Root_Doc :: struct {
		r: Root,
	}
	m2, c2 := model.compile(nil, Root_Doc)
	defer model.destroy(&m2)
	testing.expect_value(t, c2, nil)

	d2: Root_Doc
	defer model.free_value(&d2, type_info_of(Root_Doc), context.allocator)
	testing.expect_value(t, model.load(&m2, transmute([]u8)string(`<r id="42"><name>stury</name><tag>a</tag><tag>b</tag></r>`), xml.as(.Xml), xml.reads(.Xml), &d2), nil)
	testing.expect_value(t, d2.r.id, "42")
	testing.expect_value(t, d2.r.name, "stury")
	testing.expect(t, len(d2.r.tag) == 2 && d2.r.tag[0] == "a" && d2.r.tag[1] == "b")

	// (3) Single occurrence of repeated-element field also decodes cleanly into a 1-element slice!
	d3: Root_Doc
	defer model.free_value(&d3, type_info_of(Root_Doc), context.allocator)
	testing.expect_value(t, model.load(&m2, transmute([]u8)string(`<r id="1"><name>one</name><tag>only</tag></r>`), xml.as(.Xml), xml.reads(.Xml), &d3), nil)
	testing.expect(t, len(d3.r.tag) == 1 && d3.r.tag[0] == "only")
}

// ============================================================================
// H2: DSV (`infer = false`, `infer = true` -> string, `no_header = true`)
// ============================================================================

@(test)
h2_dsv_infer_false_infer_true_string_and_no_header :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Person :: struct {
		name:   string,
		age:    int `model:">=0"`,
		active: bool,
	}
	m, cerr := model.compile(nil, []Person)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// (1) Default `Dsv_Options{}` (`infer = false`): string cells parsed into `int` and `bool`!
	csv1 := "name,age,active\nada,36,true\nbob,25,false\n"
	doc1, b1 := dsv.build(transmute([]u8)csv1, .Csv)
	defer tape.destroy(&doc1)
	testing.expect_value(t, b1, nil)
	rows1: []Person
	defer model.free_value(&rows1, type_info_of([]Person), context.allocator)
	testing.expect_value(t, model.load_document(&m, &doc1, &rows1), nil)
	testing.expect_value(t, len(rows1), 2)
	testing.expect(t, rows1[0].name == "ada" && rows1[0].age == 36 && rows1[0].active)
	testing.expect(t, rows1[1].name == "bob" && rows1[1].age == 25 && !rows1[1].active)

	// (2) `infer = true`: numeric cell `12345` decoded into `code: string`!
	Code_Row :: struct {
		name: string,
		code: string,
	}
	mc, cmc := model.compile(nil, []Code_Row)
	defer model.destroy(&mc)
	testing.expect_value(t, cmc, nil)
	csv2 := "name,code\nada,12345\n"
	doc2, b2 := dsv.build(transmute([]u8)csv2, .Csv, {format = tape.Dsv_Options{infer = true}})
	defer tape.destroy(&doc2)
	testing.expect_value(t, b2, nil)
	rows2: []Code_Row
	defer model.free_value(&rows2, type_info_of([]Code_Row), context.allocator)
	testing.expect_value(t, model.load_document(&mc, &doc2, &rows2), nil)
	testing.expect(t, len(rows2) == 1 && rows2[0].name == "ada" && rows2[0].code == "12345")

	// (3) `no_header = true`: array rows decoded positionally into struct fields!
	csv3 := "ada,36,true\nbob,25,false\n"
	doc3, b3 := dsv.build(transmute([]u8)csv3, .Csv, {format = tape.Dsv_Options{no_header = true}})
	defer tape.destroy(&doc3)
	testing.expect_value(t, b3, nil)
	rows3: []Person
	defer model.free_value(&rows3, type_info_of([]Person), context.allocator)
	testing.expect_value(t, model.load_document(&m, &doc3, &rows3), nil)
	testing.expect_value(t, len(rows3), 2)
	testing.expect(t, rows3[0].name == "ada" && rows3[0].age == 36 && rows3[0].active)
	testing.expect(t, rows3[1].name == "bob" && rows3[1].age == 25 && !rows3[1].active)
}

// ============================================================================
// H3: Distinct aliases, CBOR Tag 1, space RFC 3339 / TOML 1.1, f32, Decimal, Bytes
// ============================================================================

@(test)
h3_carriers_distinct_alias_time_cbor_toml_f32_decimal_bytes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// (1) Distinct alias over `model.Number_Text` compiles and works as `.Number_Text`!
	Bounded_Num :: distinct model.Number_Text
	Num_Wrap :: struct {
		n: Bounded_Num `model:">=0"`,
	}
	mn, cmn := model.compile(nil, Num_Wrap)
	defer model.destroy(&mn)
	testing.expect_value(t, cmn, nil)
	nw: Num_Wrap
	defer model.free_value(&nw, type_info_of(Num_Wrap), context.allocator)
	testing.expect_value(t, model.load(&mn, transmute([]u8)string(`{"n":123.45}`), json.as(.Json), json.reads(.Json), &nw), nil)
	testing.expect_value(t, nw.n.text, "123.45")
	testing.expect_value(t, model.validate(&mn, &nw), nil)

	// (2) Space-separated RFC 3339, TOML 1.1 omitted seconds, and CBOR Tag 1 epoch -> `time.Time`!
	Ts_Wrap :: struct {
		ts: time.Time,
	}
	mt, cmt := model.compile(nil, Ts_Wrap)
	defer model.destroy(&mt)
	testing.expect_value(t, cmt, nil)

	t_space: Ts_Wrap
	testing.expect_value(t, model.load(&mt, transmute([]u8)string(`{"ts":"1985-04-12 23:20:50Z"}`), json.as(.Json), json.reads(.Json), &t_space), nil)
	testing.expect(t, t_space.ts._nsec > 0)

	t_toml: Ts_Wrap
	tdoc, tberr := toml.build(transmute([]u8)string("ts = 1985-04-12T23:20Z\n"), .Toml_1_1)
	defer tape.destroy(&tdoc)
	testing.expect_value(t, tberr, nil)
	testing.expect_value(t, model.load_document(&mt, &tdoc, &t_toml), nil)
	testing.expect_value(t, t_toml.ts._nsec, t_space.ts._nsec - 50 * i64(time.Second))

	// CBOR Tag 1 epoch: `c1 1a 514b67b0` = 1363896240
	mt_bare, cmtb := model.compile(nil, time.Time)
	defer model.destroy(&mt_bare)
	testing.expect_value(t, cmtb, nil)
	cbor_epoch := [?]u8{0xc1, 0x1a, 0x51, 0x4b, 0x67, 0xb0}
	cdoc, cberr := cbor.build(cbor_epoch[:], .Cbor)
	defer tape.destroy(&cdoc)
	testing.expect_value(t, cberr, nil)
	t_cbor: time.Time
	testing.expect_value(t, model.load_document(&mt_bare, &cdoc, &t_cbor), nil)
	testing.expect_value(t, t_cbor._nsec, i64(1363896240) * i64(time.Second))

	// (3) `.F32` rejects non-finite `rules.Value(math.nan_f64())` as `.Non_Finite`!
	F32_Wrap :: struct {
		x: f32,
	}
	mf, cmf := model.compile(nil, F32_Wrap)
	defer model.destroy(&mf)
	testing.expect_value(t, cmf, nil)
	fw: F32_Wrap
	fmembers := [1]rules.Member_Value{{key = "x", value = rules.Value(math.nan_f64())}}
	ferr := model.load_value(&mf, rules.Value(fmembers[:]), &fw)
	defer model.error_destroy(ferr)
	fme, fok := ferr.(model.Model_Error)
	testing.expectf(t, fok && fme.kind == .Non_Finite, "want .Non_Finite, got %v", ferr)

	// (4) Unbounded `model.Decimal` still rejects malformed text `"not-a-number"` (pattern/format check)!
	Dec_Wrap :: struct {
		d: model.Decimal,
	}
	md, cmd := model.compile(nil, Dec_Wrap)
	defer model.destroy(&md)
	testing.expect_value(t, cmd, nil)
	dw: Dec_Wrap
	derr := model.load(&md, transmute([]u8)string(`{"d":"not-a-number"}`), json.as(.Json), json.reads(.Json), &dw)
	defer model.error_destroy(derr)
	dme, dok := derr.(model.Model_Error)
	testing.expectf(t, dok && (dme.kind == .No_Match || dme.kind == .Bad_Format), "want .No_Match/.Bad_Format, got %v", derr)

	// (5) Non-UTF-8 `[]u8` (`.Bytes`) round-trips via base64 through `dump` -> JSON -> `load` & `validate`!
	Blob_Wrap :: struct {
		raw: []u8,
	}
	mb, cmb := model.compile(nil, Blob_Wrap)
	defer model.destroy(&mb)
	testing.expect_value(t, cmb, nil)
	orig := Blob_Wrap{raw = {0xFF, 0x00, 0xFE, 0x80, 0x7F}}
	testing.expect_value(t, model.validate(&mb, &orig), nil)
	jbytes, jderr := model.dump(&mb, &orig, write_json_default, {check = true})
	defer delete(jbytes)
	testing.expect_value(t, jderr, nil)
	back: Blob_Wrap
	defer model.free_value(&back, type_info_of(Blob_Wrap), context.allocator)
	testing.expect_value(t, model.load(&mb, jbytes, json.as(.Json), json.reads(.Json), &back), nil)
	testing.expect_value(t, len(back.raw), len(orig.raw))
	for b, i in orig.raw {
		testing.expect_value(t, back.raw[i], b)
	}
}

// ============================================================================
// H4: Schema applicators on non-struct kinds (`distinct int`)
// ============================================================================

@(test)
h4_schema_applicators_on_non_struct_kind :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Even_Port :: distinct int
	Svc :: struct {
		port: Even_Port,
	}

	// Fragment requiring multiple of 2 on `Even_Port`.
	frag: rules.Description
	frag.allocator = context.allocator
	frag.nodes.allocator = context.allocator
	frag.names = make(map[rules.Node_Index]string)
	defer rules.description_destroy(&frag)
	append(&frag.nodes, rules.Node{
		kinds  = {.Integer},
		rules  = {multiple_of = "2"},
		array  = -1,
		object = -1,
	})

	reg: model.Registry
	defer model.destroy(&reg)
	testing.expect_value(t, model.register(&reg, Even_Port, &frag), runtime.Allocator_Error.None)

	m, cerr := model.compile(&reg, Svc)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	s_ok: Svc
	testing.expect_value(t, model.load(&m, transmute([]u8)string(`{"port":8080}`), json.as(.Json), json.reads(.Json), &s_ok), nil)
	testing.expect_value(t, model.validate(&m, &s_ok), nil)

	s_bad: Svc
	lerr := model.load(&m, transmute([]u8)string(`{"port":8081}`), json.as(.Json), json.reads(.Json), &s_bad)
	defer model.error_destroy(lerr)
	testing.expect(t, lerr != nil)

	s_in := Svc{port = 8081}
	verr := model.validate(&m, &s_in)
	defer model.error_destroy(verr)
	testing.expect(t, verr != nil)
}

// ============================================================================
// H5: `using` embedded struct flattening, `_` padding skip, `json:",required"`
// ============================================================================

@(test)
h5_using_embedded_struct_padding_skip_and_required_tag :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Base :: struct {
		id:   int `model:">=1"`,
		name: string `model:"len>=2"`,
	}
	Derived :: struct {
		using base: Base,
		_:          [4]u8,
		opt:        Maybe(int) `json:",required"`,
	}

	m, cerr := model.compile(nil, Derived)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// Load flattened `id` and `name`, plus required `opt` (even though it's `Maybe(int)`!).
	d: Derived
	defer model.free_value(&d, type_info_of(Derived), context.allocator)
	testing.expect_value(t, model.load(&m, transmute([]u8)string(`{"id":7,"name":"ada","opt":42}`), json.as(.Json), json.reads(.Json), &d), nil)
	testing.expect(t, d.id == 7 && d.name == "ada" && d.opt != nil && d.opt.? == 42)
	testing.expect_value(t, model.validate(&m, &d), nil)

	// Dump emits flattened `id`, `name`, `opt` and NEVER emits `_`!
	out, derr := model.dump(&m, &d, write_json_default, {check = true})
	defer delete(out)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, string(out), `{"id":7,"name":"ada","opt":42}`)

	// Missing `opt` is rejected because `json:",required"` overrides `Maybe`'s default optionality!
	d2: Derived
	lerr := model.load(&m, transmute([]u8)string(`{"id":7,"name":"ada"}`), json.as(.Json), json.reads(.Json), &d2)
	defer model.error_destroy(lerr)
	me, ok := lerr.(model.Model_Error)
	testing.expectf(t, ok && me.kind == .Missing_Field && me.pointer == "/opt", "want missing /opt, got %v", lerr)
}

// ============================================================================
// H6: Partial `patch` defers field `after` validator until post-merge
// ============================================================================

@(test)
h6_partial_patch_runs_after_hook_post_merge :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Address :: struct {
		city: string `model:"len>=2"`,
		zip:  int `model:">=1"`,
		set:  model.Fields_Set,
	}
	Profile :: struct {
		addr: Maybe(Address) `model:"optional"`,
		set:  model.Fields_Set,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, Profile, "addr", proc(v: Maybe(Address), r: ^model.Report) {
		if a, ok := v.?; ok {
			if a.city == "" || a.zip < 10000 {
				model.fail(r, "need city and 5-digit zip")
			}
		}
	})

	m, cerr := model.compile(&reg, Profile)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	p: Profile
	defer model.free_value(&p, type_info_of(Profile), context.allocator)
	testing.expect_value(t, model.load(&m, transmute([]u8)string(`{"addr":{"city":"Paris","zip":75001}}`), json.as(.Json), json.reads(.Json), &p), nil)

	// Partial patch updates ONLY `zip` -> `after` validator MUST see merged `city == "Paris"` AND `zip == 75002`!
	testing.expect_value(t, model.patch(&m, &p, transmute([]u8)string(`{"addr":{"zip":75002}}`), json.as(.Json), json.reads(.Json)), nil)
	testing.expect(t, p.addr != nil && p.addr.?.city == "Paris" && p.addr.?.zip == 75002)

	// Partial patch setting invalid `zip = 99` fails post-merge and rolls back cleanly!
	perr := model.patch(&m, &p, transmute([]u8)string(`{"addr":{"zip":99}}`), json.as(.Json), json.reads(.Json))
	defer model.error_destroy(perr)
	testing.expect(t, perr != nil)
	testing.expect_value(t, p.addr.?.zip, 75002)
}

// ============================================================================
// H7: Union `.Tag` missing discriminator -> `.No_Arm`, non-object fallback
// ============================================================================

@(test)
h7_union_tag_missing_key_and_scalar_fallback :: proc(t: ^testing.T) {
	testkit.deadline(t)
	A :: struct {
		x: int,
	}
	B :: struct {
		y: string,
	}
	Tagged :: union {
		A,
		B,
	}
	Wrap_Tagged :: struct {
		u: Tagged,
	}
	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, model.Union_Rule{type = Tagged, mode = .Tag, tag = "kind"})
	m1, c1 := model.compile(&reg, Wrap_Tagged)
	defer model.destroy(&m1)
	testing.expect_value(t, c1, nil)

	// Object missing `"kind"` discriminator returns `.No_Arm` (not `.Missing_Field`)!
	wt: Wrap_Tagged
	err1 := model.load(&m1, transmute([]u8)string(`{"u":{"x":1}}`), json.as(.Json), json.reads(.Json), &wt)
	defer model.error_destroy(err1)
	me1, ok1 := err1.(model.Model_Error)
	testing.expectf(t, ok1 && me1.kind == .No_Arm, "want .No_Arm, got %v", err1)

	// Non-object multi-arm union in `.Tag` mode probes scalar arms (`union { i64, f64 }`)!
	Scalar_U :: union {
		i64,
		f64,
	}
	Wrap_Scalar :: struct {
		v: Scalar_U,
	}
	m2, c2 := model.compile(nil, Wrap_Scalar)
	defer model.destroy(&m2)
	testing.expect_value(t, c2, nil)

	ws1: Wrap_Scalar
	testing.expect_value(t, model.load(&m2, transmute([]u8)string(`{"v":42}`), json.as(.Json), json.reads(.Json), &ws1), nil)
	testing.expect_value(t, ws1.v.(i64), i64(42))

	ws2: Wrap_Scalar
	testing.expect_value(t, model.load(&m2, transmute([]u8)string(`{"v":1.5}`), json.as(.Json), json.reads(.Json), &ws2), nil)
	testing.expect_value(t, ws2.v.(f64), f64(1.5))
}

// ============================================================================
// M1: Unsigned map key pattern rejects `"-0"`, empty enum, `omitunset` `.Dump`
// ============================================================================

@(test)
m1_schema_edge_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// (1) `map[u32]string` schema compiled with `check.compile` rejects `{"-0":"x"}` and accepts `{"0":"x"}`!
	m_map, cm := model.compile(nil, map[u32]string)
	defer model.destroy(&m_map)
	testing.expect_value(t, cm, nil)
	desc_m, dm_err := model.schema(&m_map, .Load)
	defer rules.description_destroy(&desc_m)
	testing.expect_value(t, dm_err, nil)
	plan_m, pm_err := check.compile(&desc_m)
	defer check.plan_destroy(&plan_m)
	testing.expect_value(t, pm_err.kind, rules.Error_Kind.None)

	r_ok := json.check(transmute([]u8)string(`{"0":"x","42":"y"}`), &plan_m)
	defer check.result_destroy(&r_ok)
	testing.expect(t, r_ok.valid)

	r_neg0 := json.check(transmute([]u8)string(`{"-0":"x"}`), &plan_m)
	defer check.result_destroy(&r_neg0)
	testing.expect(t, !r_neg0.valid)

	// (2) Empty `enum {}` compiles and produces unsatisfiable schema cleanly.
	Empty_Enum :: enum u8 {}
	m_empty, ce := model.compile(nil, Empty_Enum)
	defer model.destroy(&m_empty)
	testing.expect_value(t, ce, nil)
	desc_e, de_err := model.schema(&m_empty, .Load)
	defer rules.description_destroy(&desc_e)
	testing.expect_value(t, de_err, nil)
	testing.expect_value(t, desc_e.nodes[0].kinds, rules.Kinds{})

	// (3) `omitunset` field is NOT required in `.Dump` schema!
	Omit_Struct :: struct {
		req: int,
		opt: int `json:",omitunset"`,
		set: model.Fields_Set,
	}
	m_omit, co := model.compile(nil, Omit_Struct)
	defer model.destroy(&m_omit)
	testing.expect_value(t, co, nil)
	desc_d, dd_err := model.schema(&m_omit, .Dump)
	defer rules.description_destroy(&desc_d)
	testing.expect_value(t, dd_err, nil)
	obj := desc_d.objects[desc_d.nodes[0].object]
	for mem_entry in obj.members {
		if mem_entry.name == "req" {
			testing.expect(t, mem_entry.required)
		} else if mem_entry.name == "opt" {
			testing.expect(t, !mem_entry.required)
		}
	}
}
