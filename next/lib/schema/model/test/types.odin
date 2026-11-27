// Carriers, customs, enums, bit_sets, unions (Tag / First_Match / One_Match), before coercions,
// field/struct validators, schema applicators, duplicate key policy, and concurrent shared Model.
package model_test

import "base:runtime"
import "core:encoding/uuid"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/schema/model"
import "stury:lib/schema/rules"
import "stury:testkit"

@(test)
builtin_carriers_time_uuid_email_base64_hex_decimal :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Payload :: struct {
		at:    time.Time,
		id:    uuid.Identifier,
		mail:  model.Email,
		blob:  model.Base64,
		hash:  model.Hex,
		price: model.Decimal,
	}

	m, cerr := model.compile(nil, Payload)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)

	{
		v: Payload
		defer model.free_value(&v, type_info_of(Payload), a)
		src := `{"at":"1996-12-19T16:39:57-08:00","id":"F81D4FAE-7DEC-11D0-A765-00a0c91e6bf6","mail":"ada@example.org","blob":"Zm9vYmFy","hash":"DEADBEEF","price":"123.450"}`
		testing.expect_value(t, load_json(&m, src, &v, allocator = a), nil)
		testing.expect_value(t, string(([]u8)(v.blob)), "foobar")
		testing.expect_value(t, len(v.hash), 4)
		testing.expect(t, v.hash[0] == 0xDE && v.hash[1] == 0xAD && v.hash[2] == 0xBE && v.hash[3] == 0xEF)
		testing.expect_value(t, v.price.text, "123.450")

		// Validate passes on the loaded struct.
		testing.expect_value(t, model.validate(&m, &v), nil)

		// Dump writes UTC time, lowercase uuid, standard base64, lowercase hex, and numeric decimal!
		dumped, derr := model.dump(&m, &v, write_json_default, {check = true}, allocator = a)
		defer delete(dumped, a)
		testing.expect_value(t, derr, nil)
		testing.expect_value(t, string(dumped), `{"at":"1996-12-20T00:39:57Z","id":"f81d4fae-7dec-11d0-a765-00a0c91e6bf6","mail":"ada@example.org","blob":"Zm9vYmFy","hash":"deadbeef","price":123.450}`)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)

	// Invalid carrier formats are refused.
	bad_cases := [?]string{
		`{"at":"2023-02-29T00:00:00Z","id":"f81d4fae-7dec-11d0-a765-00a0c91e6bf6","mail":"a@b.co","blob":"","hash":"","price":1}`,
		`{"at":"2020-01-01T00:00:00Z","id":"not-a-uuid","mail":"a@b.co","blob":"","hash":"","price":1}`,
		`{"at":"2020-01-01T00:00:00Z","id":"f81d4fae-7dec-11d0-a765-00a0c91e6bf6","mail":"not-email","blob":"","hash":"","price":1}`,
		`{"at":"2020-01-01T00:00:00Z","id":"f81d4fae-7dec-11d0-a765-00a0c91e6bf6","mail":"a@b.co","blob":"!!!","hash":"","price":1}`,
		`{"at":"2020-01-01T00:00:00Z","id":"f81d4fae-7dec-11d0-a765-00a0c91e6bf6","mail":"a@b.co","blob":"","hash":"ABC","price":1}`,
		`{"at":"2020-01-01T00:00:00Z","id":"f81d4fae-7dec-11d0-a765-00a0c91e6bf6","mail":"a@b.co","blob":"","hash":"ZZZZ","price":1}`,
	}
	for src in bad_cases {
		v: Payload
		defer model.free_value(&v, type_info_of(Payload), context.allocator)
		berr := load_json(&m, src, &v)
		defer model.error_destroy(berr)
		testing.expectf(t, berr != nil, "should fail: %s", src)
	}
}

@(test)
custom_carrier_and_discriminated_and_oneof_unions :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Milli :: distinct i64
	Disc :: struct {
		r: f64 `model:">0"`,
	}
	Box :: struct {
		side: f64 `model:">0"`,
	}
	Figure :: union {
		Disc,
		Box,
	}
	Overlap_A :: struct {
		x: int,
	}
	Overlap_B :: struct {
		x: int,
		y: int `model:"optional"`,
	}
	Ambiguous :: union {
		Overlap_A,
		Overlap_B,
	}
	Holder :: struct {
		cost:  Milli,
		shape: Figure,
		spare: Figure `model:"optional"`,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, model.Custom(Milli, f64){
		from = proc(c: ^f64, out: ^Milli, allocator: runtime.Allocator) -> model.Error_Kind {
			out^ = Milli(c^ * 1000)
			return .None
		},
		to = proc(v: ^Milli, allocator: runtime.Allocator) -> (f64, model.Error_Kind) {
			return f64(v^) / 1000, .None
		},
	})
	_ = model.register(&reg, model.Union_Rule{type = Figure, mode = .Tag, tag = "kind"})
	_ = model.register(&reg, model.Union_Rule{type = Ambiguous, mode = .One_Match})

	m, cerr := model.compile(&reg, Holder)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	h: Holder
	testing.expect_value(t, load_json(&m, `{"cost":1.5,"shape":{"kind":"Box","side":2}}`, &h), nil)
	testing.expect_value(t, h.cost, Milli(1500))
	testing.expect_value(t, h.shape.(Box).side, f64(2))
	testing.expect(t, h.spare == nil)

	dumped, derr := model.dump(&m, &h, write_json_default, {exclude_none = true, check = true})
	defer delete(dumped)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, string(dumped), `{"cost":1.5,"shape":{"kind":"Box","side":2}}`)

	// `.One_Match` refuses value matching >1 arm as `.Many_Arms`, accepts unique match!
	Wrap :: struct {
		a: Ambiguous,
	}
	am, aerr := model.compile(&reg, Wrap)
	defer model.destroy(&am)
	testing.expect_value(t, aerr, nil)

	w: Wrap
	both_err := load_json(&am, `{"a":{"x":1}}`, &w)
	defer model.error_destroy(both_err)
	me, ok := both_err.(model.Model_Error)
	testing.expect(t, ok && me.kind == .Many_Arms)

	// Adding `Extra.Forbid` on Overlap_A makes `{"x":1,"y":2}` match ONLY Overlap_B!
	_ = model.register(&reg, Overlap_A, model.Extra.Forbid)
	am2, aerr2 := model.compile(&reg, Wrap)
	defer model.destroy(&am2)
	testing.expect_value(t, aerr2, nil)
	w2: Wrap
	testing.expect_value(t, load_json(&am2, `{"a":{"x":1,"y":2}}`, &w2), nil)
	testing.expect_value(t, w2.a.(Overlap_B).y, 2)
}

@(test)
before_coercions_and_after_and_struct_validators :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Pair :: struct {
		low, high: int,
	}
	Order :: struct {
		code: string `model:"len>=2"`,
		qty:  int `model:">=1"`,
		span: Pair,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	// Before coercions operating natively on `rules.Value`.
	_ = model.register(&reg, Order, "code", proc(v: rules.Value, r: ^model.Report) -> rules.Value {
		if s, ok := v.(string); ok {
			trimmed := strings.trim_space(s)
			if trimmed == "ROOT" {
				model.fail(r, "forbidden code")
			}
			return trimmed
		}
		return v
	})
	_ = model.register(&reg, Order, "qty", proc(v: rules.Value, r: ^model.Report) -> rules.Value {
		if s, ok := v.(string); ok {
			if n, nok := strconv.parse_i64(s); nok {
				return n
			}
		}
		return v
	})
	// After field validator.
	_ = model.register(&reg, Order, "code", proc(v: string, r: ^model.Report) {
		if v == "XX" {
			model.fail(r, "no XX")
		}
	})
	// Whole-struct validator using `fail_at`.
	_ = model.register(&reg, Pair, proc(v: Pair, r: ^model.Report) {
		if v.low > v.high {
			model.fail_at(r, "high", "high below low")
		}
	})
	_ = model.register(&reg, Order, proc(v: Order, r: ^model.Report) {
		if v.code == "BAD" {
			model.fail(r, "bad order")
		}
	})

	m, cerr := model.compile(&reg, Order)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// Coercions succeed: trims spaces and parses string "5" as int 5!
	o: Order
	defer model.free_value(&o, type_info_of(Order), context.allocator)
	testing.expect_value(t, load_json(&m, `{"code":"  AB ","qty":"5","span":{"low":1,"high":3}}`, &o), nil)
	testing.expect(t, o.code == "AB" && o.qty == 5 && o.span.low == 1 && o.span.high == 3)

	// Before failure reports on `/code`.
	sink: model.Sink
	defer model.destroy(&sink)
	o2: Order
	defer model.free_value(&o2, type_info_of(Order), context.allocator)
	testing.expect(t, load_json(&m, `{"code":" ROOT ","qty":1,"span":{"low":1,"high":2}}`, &o2, &sink) != nil)
	testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Custom && sink.entries[0].pointer == "/code" && sink.entries[0].want.text == "forbidden code")

	// Struct validator `fail_at` reports on `/span/high`, and suppresses outer validator when inner fails.
	model.sink_clear(&sink)
	o3: Order
	defer model.free_value(&o3, type_info_of(Order), context.allocator)
	testing.expect(t, load_json(&m, `{"code":"BAD","qty":1,"span":{"low":9,"high":2}}`, &o3, &sink) != nil)
	testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Custom && sink.entries[0].pointer == "/span/high")
	// Failed load rolls back and zeroes `o3`.
	testing.expect(t, o3 == {})

	// Same behavior in `validate` on an in-memory value.
	model.sink_clear(&sink)
	o3_in := Order{code = "BAD", qty = 1, span = {low = 9, high = 2}}
	testing.expect(t, model.validate(&m, &o3_in, &sink) != nil)
	testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Custom && sink.entries[0].pointer == "/span/high")
}

@(test)
schema_applicators_and_unique_items :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Payment :: struct {
		kind: string,
		card: Maybe(string) `model:"optional"`,
		tags: []string `model:"unique,optional"`,
	}

	// Build a `rules.Description` fragment: if `kind == "card"` then `card` is required!
	frag: rules.Description
	frag.allocator = context.allocator
	frag.nodes.allocator = context.allocator
	frag.objects.allocator = context.allocator
	frag.names = make(map[rules.Node_Index]string)
	defer rules.description_destroy(&frag)

	append(&frag.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, cond = {test = 1, then = 2}})
	append(&frag.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})
	append(&frag.nodes, rules.Node{kinds = {.Object}, array = -1, object = 1})
	append(&frag.nodes, rules.Node{kinds = rules.EVERY_KIND, const_of = rules.Value("card"), array = -1, object = -1})
	append(&frag.nodes, rules.Node{kinds = {.String}, array = -1, object = -1})

	m0 := make([]rules.Member, 1)
	m0[0] = {name = "kind", node = 3, required = true}
	append(&frag.objects, rules.Object{members = m0, additional = rules.NONE, keys = rules.NONE})

	m1 := make([]rules.Member, 1)
	m1[0] = {name = "card", node = 4, required = true}
	append(&frag.objects, rules.Object{members = m1, additional = rules.NONE, keys = rules.NONE})

	reg: model.Registry
	defer model.destroy(&reg)
	testing.expect_value(t, model.register(&reg, Payment, &frag), runtime.Allocator_Error.None)

	m, cerr := model.compile(&reg, Payment)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	p1: Payment
	defer model.free_value(&p1, type_info_of(Payment), context.allocator)
	testing.expect_value(t, load_json(&m, `{"kind":"cash","tags":["a","b"]}`, &p1), nil)
	testing.expect_value(t, model.validate(&m, &p1), nil)

	p2: Payment
	defer model.free_value(&p2, type_info_of(Payment), context.allocator)
	p2_lerr := load_json(&m, `{"kind":"card"}`, &p2)
	defer model.error_destroy(p2_lerr)
	testing.expect(t, p2_lerr != nil)
	p2_in := Payment{kind = "card"}
	p2_verr := model.validate(&m, &p2_in)
	defer model.error_destroy(p2_verr)
	testing.expect(t, p2_verr != nil)

	p3: Payment
	defer model.free_value(&p3, type_info_of(Payment), context.allocator)
	sink: model.Sink
	defer model.destroy(&sink)
	testing.expect(t, load_json(&m, `{"kind":"cash","tags":["x","x"]}`, &p3, &sink) != nil)
	testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Not_Unique && sink.entries[0].pointer == "/tags")

	model.sink_clear(&sink)
	p3_in := Payment{kind = "cash", tags = {"x", "x"}}
	testing.expect(t, model.validate(&m, &p3_in, &sink) != nil)
	testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Not_Unique && sink.entries[0].pointer == "/tags")
}

@(test)
consistent_default_duplicate_policy_across_all_entrypoints :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Item :: struct {
		n:   int `model:">=0"`,
		set: model.Fields_Set,
	}
	m, cerr := model.compile(nil, Item)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	dup_json := transmute([]u8)string(`{"n":1,"n":2}`)
	v: Item
	sink: model.Sink
	defer model.destroy(&sink)

	err := model.load(&m, dup_json, json.as(.Json), json.reads(.Json), &v, &sink)
	testing.expect(t, err != nil && len(sink.entries) == 1 && sink.entries[0].kind == .Duplicate_Key)

	doc, berr := json.build(dup_json, .Json, {dups = .All})
	defer tape.destroy(&doc)
	testing.expect_value(t, berr, nil)
	model.sink_clear(&sink)
	err = model.load_document(&m, &doc, &v, &sink)
	testing.expect(t, err != nil && len(sink.entries) == 1 && sink.entries[0].kind == .Duplicate_Key)

	mv := []rules.Member_Value{{"n", i64(1)}, {"n", i64(2)}}
	model.sink_clear(&sink)
	err = model.load_value(&m, mv, &v, &sink)
	testing.expect(t, err != nil && len(sink.entries) == 1 && sink.entries[0].kind == .Duplicate_Key)

	existing := Item{n = 10}
	model.sink_clear(&sink)
	err = model.patch(&m, &existing, dup_json, json.as(.Json), json.reads(.Json), &sink)
	testing.expect(t, err != nil && len(sink.entries) == 1 && sink.entries[0].kind == .Duplicate_Key)
	testing.expect_value(t, existing.n, 10)

	v = {}
	testing.expect_value(t, load_json(&m, `{"n":-5,"n":7}`, &v, opts = {dups = .Last}), nil)
	testing.expect_value(t, v.n, 7)

	v = {}
	testing.expect_value(t, load_json(&m, `{"n":7,"n":-5}`, &v, opts = {dups = .First}), nil)
	testing.expect_value(t, v.n, 7)

	bad := model.load(&m, dup_json, json.as(.Json), json.reads(.Json), &v, nil, {dups = .All})
	me, ok := bad.(model.Model_Error)
	testing.expect(t, ok && me.kind == .Bad_Option)
}

@(test)
shared_model_is_thread_safe :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Msg :: struct {
		user: string `model:"len>=2,pattern=^[a-z]+$"`,
		seq:  i64 `model:">=0"`,
	}
	m, cerr := model.compile(nil, Msg)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	Worker :: struct {
		m:  ^model.Model(Msg),
		ok: bool,
	}
	workers: [4]Worker
	threads: [4]^thread.Thread
	for i in 0 ..< 4 {
		workers[i] = {m = &m, ok = true}
		threads[i] = thread.create_and_start_with_data(&workers[i], proc(data: rawptr) {
			w := (^Worker)(data)
			for iter in 0 ..< 50 {
				v: Msg
				err := load_json(w.m, `{"user":"ada","seq":42}`, &v)
				if err != nil || v.user != "ada" || v.seq != 42 {
					w.ok = false
				}
				if model.validate(w.m, &v) != nil {
					w.ok = false
				}
				model.free_value(&v, type_info_of(Msg), context.allocator)
				_ = iter
			}
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for w in workers {
		testing.expect(t, w.ok)
	}
}

@(test)
enum_rules_bit_sets_and_extra_collision :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Color :: enum u8 {
		Red,
		Dark_Green,
		Blue,
	}
	Status :: enum i16 {
		Ok  = 200,
		Bad = 400,
	}
	Flags :: bit_set[Color]
	Item :: struct {
		color:  Color,
		status: Status,
		flags:  Flags `model:"len>=1,optional"`,
		extra:  map[string]int `json:",unknown"`,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, model.Naming{enum_members = .Kebab})
	_ = model.register(&reg, model.Enum_Rule{type = Color, renames = {{member = "Red", name = "crimson"}}})
	_ = model.register(&reg, model.Enum_Rule{type = Status, by_number = true})

	m, cerr := model.compile(&reg, Item)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	v: Item
	defer model.free_value(&v, type_info_of(Item), context.allocator)
	src := `{"color":"crimson","status":200,"flags":["dark-green","blue"],"bonus":9}`
	testing.expect_value(t, load_json(&m, src, &v), nil)
	testing.expect(t, v.color == .Red && v.status == .Ok && v.flags == {.Dark_Green, .Blue} && v.extra["bonus"] == 9)

	dumped, derr := model.dump(&m, &v, write_json_default, {check = true})
	defer delete(dumped)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, string(dumped), src)

	// Colliding extra key is refused on both `validate` and `dump`.
	v.extra["color"] = 1
	defer delete_key(&v.extra, "color")
	verr := model.validate(&m, &v)
	defer model.error_destroy(verr)
	testing.expect(t, verr != nil)
	d2, derr2 := model.dump(&m, &v, write_json_default)
	defer delete(d2)
	defer model.error_destroy(derr2)
	testing.expect(t, derr2 != nil)
}
