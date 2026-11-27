// Adversarial and polish regression tests: error pointer lifetimes, multi-field hooks, deep recursion/budgets,
// multi-format XML/DSV/CBOR/TOML edges, judged failures, streaming indirect leaves, dump cycles/sinks, and OOM.
package model_test

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"
import "stury:lib/schema/check"
import "stury:lib/schema/model"
import "stury:lib/schema/rules"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

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

	u1: User
	err1 := load_json(&m, `{"addr":{"zip":5},"items":[1],"span":{"low":1,"high":2}}`, &u1)
	defer model.error_destroy(err1)
	me1, ok1 := err1.(model.Model_Error)
	testing.expect(t, ok1)
	testing.expect_value(t, me1.kind, model.Error_Kind.Below_Minimum)
	testing.expect_value(t, me1.pointer, "/addr/zip")
	testing.expect(t, me1.owned)

	u2: User
	err2 := load_json(&m, `{"addr":{"zip":12345},"items":["bad"],"span":{"low":1,"high":2}}`, &u2)
	defer model.error_destroy(err2)
	me2, ok2 := err2.(model.Model_Error)
	testing.expect(t, ok2)
	testing.expect_value(t, me2.kind, model.Error_Kind.Wrong_Kind)
	testing.expect_value(t, me2.pointer, "/items/0")

	u3: User
	err3 := load_json(&m, `{"addr":{"zip":12345},"items":[1],"span":{"low":9,"high":2}}`, &u3)
	defer model.error_destroy(err3)
	me3, ok3 := err3.(model.Model_Error)
	testing.expect(t, ok3)
	testing.expect_value(t, me3.kind, model.Error_Kind.Custom)
	testing.expect_value(t, me3.pointer, "/span/high")
	testing.expect_value(t, me3.want.text, "high below low")

	sink: model.Sink
	defer model.destroy(&sink)
	u4: User
	err4 := load_json(&m, `{"addr":{"zip":5},"items":[1],"span":{"low":9,"high":2}}`, &u4, &sink)
	me4, ok4 := err4.(model.Model_Error)
	testing.expect(t, ok4)
	testing.expect_value(t, me4.pointer, "/addr/zip")
	testing.expect(t, !me4.owned)

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

	ok_val: Multi
	defer model.free_value(&ok_val, type_info_of(Multi), context.allocator)
	testing.expect_value(t, load_json(&m, `{"a":" 1 ","b":" 2 ","c":" 3 ","d":" 4 "}`, &ok_val), nil)
	testing.expect(t, ok_val.a == "1" && ok_val.b == "2" && ok_val.c == "3" && ok_val.d == "4")
	testing.expect_value(t, model.validate(&m, &ok_val), nil)

	sink: model.Sink
	defer model.destroy(&sink)
	bad_val: Multi
	err := load_json(&m, `{"a":"BAD","b":"NOPE","c":"BAD","d":"NOPE"}`, &bad_val, &sink)
	testing.expect(t, err != nil)
	testing.expect_value(t, len(sink.entries), 4)

	model.sink_clear(&sink)
	in_bad := Multi{a = "NOPE", b = "ok", c = "NOPE", d = "NOPE"}
	testing.expect(t, model.validate(&m, &in_bad, &sink) != nil)
	testing.expect_value(t, len(sink.entries), 3)
}

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
	testing.expect_value(t, load_json(&m, `{"n":7}`, &v), nil)
	testing.expect_value(t, v.n, 7)
	testing.expect(t, v.p == nil)
	testing.expect(t, v.c != nil && v.c.? == "hello")
}

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

	root: Node
	defer model.free_value(&root, type_info_of(Node), context.allocator)
	testing.expect_value(t, load_json(&m, deep_json, &root), nil)

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

	small_src := `{"val":1,"next":{"val":2,"next":{"val":3,"next":{"val":4,"next":{"val":5,"next":{"val":6}}}}}}`
	doc, berr := json.build(transmute([]u8)small_src)
	defer tape.destroy(&doc)
	testing.expect_value(t, berr, nil)

	expect_exceeded :: proc(t: ^testing.T, err: model.Error, want: tape.Budget_Kind, label: string, loc := #caller_location) {
		te, ok1 := err.(tape.Error)
		ex, ok2 := te.(tape.Exceeded)
		testing.expectf(t, ok1 && ok2 && ex.kind == want, "%s: want %v exceeded, got %v", label, want, err, loc = loc)
	}

	out_d: Node
	expect_exceeded(t, model.load_document(&m, &doc, &out_d, opts = {budget = {depth = 3}}), .Depth, "load depth")
	expect_exceeded(t, model.validate(&m, &root, opts = {budget = {depth = 10}}), .Depth, "validate depth")

	out_n: Node
	expect_exceeded(t, model.load_document(&m, &doc, &out_n, opts = {budget = {nodes = 4}}), .Nodes, "load nodes")
	expect_exceeded(t, model.validate(&m, &root, opts = {budget = {nodes = 5}}), .Nodes, "validate nodes")

	out_s: Node
	expect_exceeded(t, model.load_document(&m, &doc, &out_s, opts = {budget = {steps = 3}}), .Steps, "load steps")

	dst_p := Node{val = 0}
	expect_exceeded(t, model.patch_document(&m, &dst_p, &doc, opts = {budget = {steps = 2}}), .Steps, "patch steps")

	deep_doc, dberr := json.build(transmute([]u8)deep_json)
	defer tape.destroy(&deep_doc)
	testing.expect_value(t, dberr, nil)
	out_m: Node
	expect_exceeded(t, model.load_document(&m, &deep_doc, &out_m, opts = {budget = {memory = 1024}}), .Memory, "load memory")
}

@(test)
c6_float_to_int_default_bounds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Nums :: struct {
		si: i64,
		ui: u64,
	}

	reg_ok: model.Registry
	defer model.destroy(&reg_ok)
	_ = model.register(&reg_ok, Nums, "si", f64(i64(1) << 50))
	_ = model.register(&reg_ok, Nums, "ui", f64(9223372036854775808.0))
	m_ok, err_ok := model.compile(&reg_ok, Nums)
	defer model.destroy(&m_ok)
	testing.expect_value(t, err_ok, nil)
	v: Nums
	testing.expect_value(t, load_json(&m_ok, `{}`, &v), nil)
	testing.expect_value(t, v.si, i64(1) << 50)
	testing.expect_value(t, v.ui, u64(1) << 63)

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

	r: Rich
	err := load_json(&m, `{"name":"ada","tags":["x","y","z"],"meta":{"k1":"v1","k2":"v2"},"child":{"label":"sub"},"score":5}`, &r, allocator = a)
	testing.expect(t, err != nil)
	model.error_destroy(err, a)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect(t, r.name == "" && r.tags == nil && r.meta == nil && r.child == nil && r.score == 0)
}

@(test)
h1_xml_attributes_text_and_grouped_repeated_elements :: proc(t: ^testing.T) {
	testkit.deadline(t)
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

	d3: Root_Doc
	defer model.free_value(&d3, type_info_of(Root_Doc), context.allocator)
	testing.expect_value(t, model.load(&m2, transmute([]u8)string(`<r id="1"><name>one</name><tag>only</tag></r>`), xml.as(.Xml), xml.reads(.Xml), &d3), nil)
	testing.expect(t, len(d3.r.tag) == 1 && d3.r.tag[0] == "only")
}

@(test)
h2_dsv_infer_false_infer_true_string_and_no_header :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Person :: struct {
		name:   string `model:"len>=2"`,
		age:    int `model:">=0"`,
		active: bool,
	}
	m, cerr := model.compile(nil, []Person)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// (1) Default `Dsv_Options{}` (`infer = false`): string cells parsed into `int` and `bool`.
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

	// Invalid CSV row caught with accurate row/field pointer under `infer = true`.
	bad_csv := "name,age,active\nada,-5,true\n"
	bdoc, berr2 := dsv.build(transmute([]u8)bad_csv, .Csv, {format = tape.Dsv_Options{infer = true}})
	defer tape.destroy(&bdoc)
	testing.expect_value(t, berr2, nil)
	sink: model.Sink
	defer model.destroy(&sink)
	bad_rows: []Person
	defer model.free_value(&bad_rows, type_info_of([]Person), context.allocator)
	testing.expect(t, model.load_document(&m, &bdoc, &bad_rows, &sink) != nil)
	testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Below_Minimum && sink.entries[0].pointer == "/0/age")

	// (2) `infer = true`: numeric cell `12345` decoded into `code: string`.
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

	// (3) `no_header = true`: array rows decoded positionally into struct fields.
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

@(test)
h3_carriers_distinct_alias_time_cbor_toml_f32_decimal_bytes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Bounded_Num :: distinct model.Number_Text
	Num_Wrap :: struct {
		n: Bounded_Num `model:">=0"`,
	}
	mn, cmn := model.compile(nil, Num_Wrap)
	defer model.destroy(&mn)
	testing.expect_value(t, cmn, nil)
	nw: Num_Wrap
	defer model.free_value(&nw, type_info_of(Num_Wrap), context.allocator)
	testing.expect_value(t, load_json(&mn, `{"n":123.45}`, &nw), nil)
	testing.expect_value(t, nw.n.text, "123.45")
	testing.expect_value(t, model.validate(&mn, &nw), nil)

	Ts_Wrap :: struct {
		ts: time.Time,
	}
	mt, cmt := model.compile(nil, Ts_Wrap)
	defer model.destroy(&mt)
	testing.expect_value(t, cmt, nil)

	t_space: Ts_Wrap
	testing.expect_value(t, load_json(&mt, `{"ts":"1985-04-12 23:20:50Z"}`, &t_space), nil)
	testing.expect(t, t_space.ts._nsec > 0)

	t_toml: Ts_Wrap
	tdoc, tberr := toml.build(transmute([]u8)string("ts = 1985-04-12T23:20Z\n"), .Toml_1_1)
	defer tape.destroy(&tdoc)
	testing.expect_value(t, tberr, nil)
	testing.expect_value(t, model.load_document(&mt, &tdoc, &t_toml), nil)
	testing.expect_value(t, t_toml.ts._nsec, t_space.ts._nsec - 50 * i64(time.Second))

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

	Dec_Wrap :: struct {
		d: model.Decimal,
	}
	md, cmd := model.compile(nil, Dec_Wrap)
	defer model.destroy(&md)
	testing.expect_value(t, cmd, nil)
	dw: Dec_Wrap
	derr := load_json(&md, `{"d":"not-a-number"}`, &dw)
	defer model.error_destroy(derr)
	dme, dok := derr.(model.Model_Error)
	testing.expectf(t, dok && (dme.kind == .No_Match || dme.kind == .Bad_Format), "want .No_Match/.Bad_Format, got %v", derr)

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

@(test)
h4_schema_applicators_on_non_struct_kind :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Even_Port :: distinct int
	Svc :: struct {
		port: Even_Port,
	}

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
	testing.expect_value(t, load_json(&m, `{"port":8080}`, &s_ok), nil)
	testing.expect_value(t, model.validate(&m, &s_ok), nil)

	s_bad: Svc
	lerr := load_json(&m, `{"port":8081}`, &s_bad)
	defer model.error_destroy(lerr)
	testing.expect(t, lerr != nil)

	s_in := Svc{port = 8081}
	verr := model.validate(&m, &s_in)
	defer model.error_destroy(verr)
	testing.expect(t, verr != nil)
}

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

	d: Derived
	defer model.free_value(&d, type_info_of(Derived), context.allocator)
	testing.expect_value(t, load_json(&m, `{"id":7,"name":"ada","opt":42}`, &d), nil)
	testing.expect(t, d.id == 7 && d.name == "ada" && d.opt != nil && d.opt.? == 42)
	testing.expect_value(t, model.validate(&m, &d), nil)

	out, derr := model.dump(&m, &d, write_json_default, {check = true})
	defer delete(out)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, string(out), `{"id":7,"name":"ada","opt":42}`)

	d2: Derived
	lerr := load_json(&m, `{"id":7,"name":"ada"}`, &d2)
	defer model.error_destroy(lerr)
	me, ok := lerr.(model.Model_Error)
	testing.expectf(t, ok && me.kind == .Missing_Field && me.pointer == "/opt", "want missing /opt, got %v", lerr)
}

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
	testing.expect_value(t, load_json(&m, `{"addr":{"city":"Paris","zip":75001}}`, &p), nil)

	testing.expect_value(t, model.patch(&m, &p, transmute([]u8)string(`{"addr":{"zip":75002}}`), json.as(.Json), json.reads(.Json)), nil)
	testing.expect(t, p.addr != nil && p.addr.?.city == "Paris" && p.addr.?.zip == 75002)

	perr := model.patch(&m, &p, transmute([]u8)string(`{"addr":{"zip":99}}`), json.as(.Json), json.reads(.Json))
	defer model.error_destroy(perr)
	testing.expect(t, perr != nil)
	testing.expect_value(t, p.addr.?.zip, 75002)
}

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

	wt: Wrap_Tagged
	err1 := load_json(&m1, `{"u":{"x":1}}`, &wt)
	defer model.error_destroy(err1)
	me1, ok1 := err1.(model.Model_Error)
	testing.expectf(t, ok1 && me1.kind == .No_Arm, "want .No_Arm, got %v", err1)

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
	testing.expect_value(t, load_json(&m2, `{"v":42}`, &ws1), nil)
	testing.expect_value(t, ws1.v.(i64), i64(42))

	ws2: Wrap_Scalar
	testing.expect_value(t, load_json(&m2, `{"v":1.5}`, &ws2), nil)
	testing.expect_value(t, ws2.v.(f64), f64(1.5))
}

@(test)
m1_schema_edge_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
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

	Empty_Enum :: enum u8 {}
	m_empty, ce := model.compile(nil, Empty_Enum)
	defer model.destroy(&m_empty)
	testing.expect_value(t, ce, nil)
	desc_e, de_err := model.schema(&m_empty, .Load)
	defer rules.description_destroy(&desc_e)
	testing.expect_value(t, de_err, nil)
	testing.expect_value(t, desc_e.nodes[0].kinds, rules.Kinds{})

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

// ============================================================================
// Polish Bug Regressions (#1-#8)
// ============================================================================

@(private = "file")
g_bug1_after, g_bug1_val, g_bug1_custom: int

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
		err := load_json(&m, `{"nums":[1,1]}`, &out, &sink)
		testing.expect(t, err != nil && len(sink.entries) == 1 && sink.entries[0].kind == .Not_Unique)
		testing.expect_value(t, g_bug1_after, 0)

		bad := Unique_Box{nums = []i32{2, 2}}
		model.sink_clear(&sink)
		g_bug1_after = 0
		verr := model.validate(&m, &bad, &sink)
		testing.expect(t, verr != nil && len(sink.entries) == 1 && sink.entries[0].kind == .Not_Unique)
		testing.expect_value(t, g_bug1_after, 0)
	}

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
		err := load_json(&m, src, &out, &sink)
		testing.expect(t, err != nil && len(sink.entries) >= 4)
		testing.expect_value(t, g_bug1_val, 0)
		testing.expect_value(t, g_bug1_custom, 0)
		testing.expect_value(t, g_bug1_after, 0)
		testing.expect(t, out.ou == nil)
		_, has_dup := out.m["dup"]
		testing.expect(t, !has_dup)

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
		uerr := load_json(&mu, `{"u":{"a":7,"b":8}}`, &uout, &usink)
		testing.expect(t, uerr != nil && len(usink.entries) == 1 && usink.entries[0].kind == .Many_Arms)
		testing.expect_value(t, g_bug1_after, 0)
	}
}

@(private = "file")
g_bug2_calls: [10]int
@(private = "file")
g_bug2_ptr: int

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
	testing.expect_value(t, g_bug2_calls[9], 1)

	Ptr_After :: struct { p: ^i32 }
	g_bug2_ptr = 0
	rp: model.Registry; defer model.destroy(&rp)
	_ = model.register(&rp, Ptr_After, "p", proc(v: ^i32, r: ^model.Report) { if v != nil && v^ == 7 { g_bug2_ptr += 1 } })
	mp, mperr := model.compile(&rp, Ptr_After); defer model.destroy(&mp); testing.expect_value(t, mperr, nil)
	pa: Ptr_After; defer model.free_value(&pa, type_info_of(Ptr_After), context.allocator)
	testing.expect_value(t, json.load(&mp, transmute([]u8)string(`{"p":7}`), &pa), nil)
	testing.expect_value(t, g_bug2_ptr, 1)

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

	out_bad: Good_Bytes
	lerr := json.load(&mg, transmute([]u8)string(`{"payload":"////"}`), &out_bad)
	defer model.error_destroy(lerr)
	testing.expect(t, lerr != nil)

	bad_val := Good_Bytes{payload = []u8{1}}
	verr := model.validate(&mg, &bad_val)
	defer model.error_destroy(verr)
	testing.expect(t, verr != nil)

	Fmt_Bytes :: struct { u: []u8 `model:"format=uuid"` }
	mfb, efb := model.compile(nil, Fmt_Bytes)
	defer model.destroy(&mfb)
	testing.expect_value(t, efb, nil)

	Bad_Unique_Bytes :: struct {
		payload: []u8 `model:"unique"`,
	}
	mb, errb := model.compile(nil, Bad_Unique_Bytes)
	defer model.destroy(&mb)
	me, is_me := errb.(model.Model_Error)
	testing.expect(t, is_me && me.kind == .Bad_Tag)
}

@(test)
bug4_f32_single_rounding_and_negative_zero_sign :: proc(t: ^testing.T) {
	testkit.deadline(t)

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

	src1 := fmt.aprintf(`{{"f32v":%s,"f64v":-0,"nt":-0}}`, edge)
	defer delete(src1)
	r1, r2: Rec
	defer model.free_value(&r1, type_info_of(Rec), context.allocator)
	defer model.free_value(&r2, type_info_of(Rec), context.allocator)
	testing.expect_value(t, json.load(&m, transmute([]u8)src1, &r1, .Json), nil)
	testing.expect_value(t, load_json(&m, src1, &r2), nil)
	testing.expect_value(t, r1.f32v, exact_f32)
	testing.expect_value(t, r1.f32v, r2.f32v)
	testing.expect(t, r1.f64v == 0 && math.sign_bit(r1.f64v))
	testing.expect(t, r1.nt.value == 0 && math.sign_bit(r1.nt.value) && r1.nt.text == "-0")

	for j5 in ([]string{`{f32v:-0.,f64v:-0.,nt:-0.}`, `{f32v:-0x0,f64v:-0x0,nt:-0x0}`}) {
		v: Rec
		defer model.free_value(&v, type_info_of(Rec), context.allocator)
		testing.expect_value(t, json.load(&m, transmute([]u8)j5, &v, .Json5), nil)
		testing.expect(t, v.f32v == 0 && math.sign_bit(v.f32v))
		testing.expect(t, v.f64v == 0 && math.sign_bit(v.f64v))
		testing.expect(t, v.nt.value == 0 && math.sign_bit(v.nt.value))
	}
}

@(test)
bug5_dump_cycle_depth_sink_and_nested_capture_pointer :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Cyclic pointer stops cleanly at `tape.DEFAULT_DEPTH` (`Exceeded{kind = .Depth}`) in both `model.dump_document` and `json.dump`.
	Cycle :: struct { next: ^Cycle `model:"optional"` }
	mc, cerr := model.compile(nil, Cycle)
	defer model.destroy(&mc)
	testing.expect_value(t, cerr, nil)
	cyc: Cycle
	cyc.next = &cyc
	_, cderr := model.dump_document(&mc, &cyc)
	te1, is_te1 := cderr.(tape.Error)
	exc1, is_exc1 := te1.(tape.Exceeded)
	testing.expect(t, is_te1 && is_exc1 && exc1.kind == .Depth)
	_, jderr := json.dump(&mc, &cyc)
	te2, is_te2 := jderr.(tape.Error)
	exc2, is_exc2 := te2.(tape.Exceeded)
	testing.expect(t, is_te2 && is_exc2 && exc2.kind == .Depth)

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

	// Nested Non_Finite reported to `sink` in both `model.dump_document` and `json.dump`:
	p3 := Parent{nan_c = {f = math.nan_f64()}}
	s5, s6: model.Sink; defer model.destroy(&s5); defer model.destroy(&s6)
	_, de5 := model.dump_document(&mp, &p3, {}, &s5)
	testing.expect(t, de5 != nil && len(s5.entries) == 1 && s5.entries[0].kind == .Non_Finite && s5.entries[0].pointer == "/nan_c/f")
	p4 := Parent{nan_c = {f = math.inf_f64(1)}}
	_, je6 := json.dump(&mp, &p4, {}, {}, &s6)
	me6, is_me6 := je6.(model.Model_Error)
	testing.expect(t, is_me6 && me6.kind == .Non_Finite)
	testing.expect(t, len(s6.entries) == 1 && s6.entries[0].kind == .Non_Finite && s6.entries[0].pointer == "/nan_c/f")
}

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
		e2 := load_json(&mm, raw, &v2, &s2)
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
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	fail := testkit.Failing{backing = mem.tracking_allocator(&track), fail_at = 2, sticky = true}
	entries := []model.Error_Entry{{kind = .Wrong_Kind, pointer = "/field"}}
	_, perr := model.problem(entries, "Bad", 400, allocator = testkit.failing_allocator(&fail))
	testing.expect_value(t, perr, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, len(track.allocation_map), 0)
}

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

	reg1: model.Registry; defer model.destroy(&reg1)
	testing.expect_value(t, model.register(&reg1, Raw_Wrap, &d), runtime.Allocator_Error.None)
	mr, mrc := model.compile(&reg1, Raw_Wrap); defer model.destroy(&mr)
	testing.expect_value(t, mrc, nil)
	rsink: model.Sink; defer model.destroy(&rsink)
	rv := Raw_Wrap{items = []typed.Raw{typed.Raw("1"), typed.Raw("2")}}
	testing.expect_value(t, model.validate(&mr, &rv, &rsink), nil)
	testing.expect_value(t, len(rsink.entries), 0)

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
