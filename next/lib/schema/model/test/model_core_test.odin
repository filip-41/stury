// Core model tests: tags, validation rules, paths, defaults, floats, Problem documents, and schema generation.
package model_test

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/check"
import "stury:lib/schema/model"
import "stury:lib/schema/rules"
import "stury:testkit"

@(private = "file")
Celsius :: distinct f64

@(private = "file")
Room :: struct {
	name: string,
	temp: Celsius,
}

@(private = "file")
Account :: struct {
	id:     i64 `model:"read_only"`,
	name:   string `model:"len=1..=8,pattern=^[a-z]+$"`,
	age:    u8 `model:">=18,<130"`,
	score:  f64 `model:"0..<1,optional"`,
	step:   i32 `model:"multiple_of=5,optional"`,
	tags:   []string `model:"len<=2,optional"`,
	mail:   string `json:"email" model:"format=email"`,
	secret: string `model:"write_only,optional"`,
	note:   string `json:"-"`,
	rooms:  []Room `model:"optional"`,
	temps:  map[string]Celsius `model:"optional"`,
}

@(private = "file")
account_registry :: proc(reg: ^model.Registry) {
	_ = model.register(reg, model.Type_Rule{Celsius, ">=-273.15"})
	_ = model.register(reg, model.Field_Rule_Of{Room, "name", "len>=2"})
}

@(private)
write_json_default :: proc(doc: ^tape.Document, opts: write.Options, allocator: runtime.Allocator) -> ([]u8, tape.Facts, write.Error) {
	return json.write(doc, .Json, opts, allocator)
}

@(test)
model_validates_rules_with_paths_and_sink_limits :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reg: model.Registry
	defer model.destroy(&reg)
	account_registry(&reg)

	m, cerr := model.compile(&reg, Account)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	good := Account{
		id     = 1,
		name   = "ada",
		age    = 36,
		score  = 0.5,
		step   = 10,
		tags   = {"a"},
		mail   = "ada@example.org",
		secret = "s",
		rooms  = {{"lab", 20}},
	}
	testing.expect_value(t, model.validate(&m, &good), nil)

	temps := make(map[string]Celsius)
	defer delete(temps)
	temps["out"] = -274
	bad := Account{
		name  = "abcdefghiJ",
		age   = 10,
		score = 1,
		step  = 7,
		tags  = {"a", "b", "c"},
		mail  = "x",
		rooms = {{"lab", 20}, {"b", -300}},
		temps = temps,
	}

	first := model.validate(&m, &bad)
	defer model.error_destroy(first)
	me, is_me := first.(model.Model_Error)
	testing.expect(t, is_me)
	testing.expect_value(t, me.kind, model.Error_Kind.Too_Long)

	sink: model.Sink
	defer model.destroy(&sink)
	testing.expect(t, model.validate(&m, &bad, &sink) != nil)

	want := [?]struct {
		kind:    model.Error_Kind,
		pointer: string,
	}{
		{.Too_Long, "/name"},
		{.No_Match, "/name"},
		{.Below_Minimum, "/age"},
		{.Above_Maximum, "/score"},
		{.Not_Multiple, "/step"},
		{.Too_Many, "/tags"},
		{.Bad_Format, "/email"},
		{.Too_Short, "/rooms/1/name"},
		{.Below_Minimum, "/rooms/1/temp"},
		{.Below_Minimum, "/temps/out"},
	}
	testing.expect_value(t, len(sink.entries), len(want))
	for w in want {
		found := false
		for e in sink.entries {
			if e.kind == w.kind && e.pointer == w.pointer {
				found = true
				break
			}
		}
		testing.expectf(t, found, "missing expected error %v at %s", w.kind, w.pointer)
	}

	limited: model.Sink
	model.sink_init(&limited, context.allocator, max_errors = 2)
	defer model.destroy(&limited)
	_ = model.validate(&m, &bad, &limited)
	testing.expect(t, len(limited.entries) == 2 && limited.truncated)
}

@(test)
model_validates_write_refusals_non_finite_and_bad_enum :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Kind_Enum :: enum u8 {
		A,
		B,
	}
	Picked :: struct {
		x: f32,
		e: Kind_Enum,
		n: i32 `model:">=0"`,
	}
	m, cerr := model.compile(nil, Picked)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	v := Picked{x = math.inf_f32(1), e = transmute(Kind_Enum)u8(7), n = -1}
	sink: model.Sink
	defer model.destroy(&sink)
	err := model.validate(&m, &v, &sink)
	me, is_me := err.(model.Model_Error)
	testing.expect(t, is_me && me.kind == .Non_Finite)
	testing.expect_value(t, len(sink.entries), 3)
	if len(sink.entries) == 3 {
		testing.expect_value(t, sink.entries[0].kind, model.Error_Kind.Not_A_Member)
		testing.expect_value(t, sink.entries[1].kind, model.Error_Kind.Below_Minimum)
		testing.expect_value(t, sink.entries[2].kind, model.Error_Kind.Non_Finite)
	}
}

@(test)
bad_tags_and_unsatisfiable_rules_refuse_compile :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Text_Bound :: struct {
		s: string `model:">=1"`,
	}
	Fraction_Divisor :: struct {
		n: i32 `model:"multiple_of=1.5"`,
	}
	Fraction_Bound :: struct {
		n: i32 `model:">=1.5"`,
	}
	Both_Roles :: struct {
		n: i32 `model:"read_only,write_only"`,
	}
	Unknown_Format :: struct {
		s: string `model:"format=nope"`,
	}
	Count_On_Number :: struct {
		n: i32 `model:"len>=1"`,
	}
	Swallowed_Pattern :: struct {
		s: string `model:"pattern=^a,len>=1"`,
	}
	Unsat_Range :: struct {
		n: u8 `model:">=300"`,
	}
	Unsat_Fixed :: struct {
		xs: [3]int `model:"len>=4"`,
	}
	Not_Null_Int :: struct {
		n: int `model:"not_null"`,
	}

	check_bad :: proc(t: ^testing.T, $T: typeid, want_item: string, loc := #caller_location) {
		m, err := model.compile(nil, T)
		defer model.destroy(&m)
		me, ok := err.(model.Model_Error)
		testing.expectf(t, ok && me.kind == .Bad_Tag && me.want.text == want_item, "got %v, want Bad_Tag(%s)", err, want_item, loc = loc)
	}

	check_bad(t, Text_Bound, ">=1")
	check_bad(t, Fraction_Divisor, "multiple_of=1.5")
	check_bad(t, Fraction_Bound, ">=1.5")
	check_bad(t, Both_Roles, "write_only")
	check_bad(t, Unknown_Format, "format=nope")
	check_bad(t, Count_On_Number, "len>=1")
	check_bad(t, Swallowed_Pattern, "pattern=^a,len>=1")
	check_bad(t, Unsat_Range, ">=300")
	check_bad(t, Unsat_Fixed, "len>=4")
	check_bad(t, Not_Null_Int, "not_null")

	// Unknown registered field refused by compile.
	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, model.Field_Rule_Of{Room, "nope", ">=1"})
	m, uerr := model.compile(&reg, Room)
	defer model.destroy(&m)
	me, ok := uerr.(model.Model_Error)
	testing.expect(t, ok && me.kind == .Bad_Tag && me.want.type == Room && me.pointer == "nope")
}

@(test)
float_validate_load_and_schema_agree :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Float_32 :: struct {
		x: f32 `model:"<=0.1"`,
	}
	Float_32_Open :: struct {
		x: f32 `model:"<0.1"`,
	}
	Float_64 :: struct {
		x: f64 `model:"<=0.3"`,
	}

	float_law :: proc(t: ^testing.T, val: $T, want_valid: bool, loc := #caller_location) {
		m, cerr := model.compile(nil, T)
		defer model.destroy(&m)
		testing.expect_value(t, cerr, nil, loc = loc)

		v := val
		verr := model.validate(&m, &v)
		defer model.error_destroy(verr)
		validated := verr == nil
		text, derr := model.dump(&m, &v, write_json_default)
		defer delete(text)
		testing.expect_value(t, derr, nil, loc = loc)

		back: T
		lerr := model.load(&m, text, json.as(.Json), json.reads(.Json), &back)
		defer model.error_destroy(lerr)
		loaded := lerr == nil

		desc, serr := model.schema(&m, .Dump)
		defer rules.description_destroy(&desc)
		testing.expect_value(t, serr, nil, loc = loc)

		cp, cperr := check.compile(&desc)
		defer check.plan_destroy(&cp)
		testing.expect_value(t, cperr.kind, rules.Error_Kind.None, loc = loc)

		res := json.check(text, &cp)
		defer check.result_destroy(&res)

		testing.expectf(t, validated == want_valid && loaded == want_valid && res.valid == want_valid,
			"%s: validate=%v load=%v check=%v want=%v", text, validated, loaded, res.valid, want_valid, loc = loc)
	}

	tenth := f32(0.1)
	float_law(t, Float_32{tenth}, true)
	float_law(t, Float_32{math.nextafter_f32(tenth, 1)}, false)
	float_law(t, Float_32{math.nextafter_f32(tenth, 0)}, true)
	float_law(t, Float_32_Open{tenth}, false)
	float_law(t, Float_32_Open{math.nextafter_f32(tenth, 0)}, true)
	float_law(t, Float_64{0.3}, true)
	float_law(t, Float_64{math.nextafter_f64(0.3, 1)}, false)
}

@(test)
defaults_constants_conversions_factories_and_isolation :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Counter :: struct {
		count: i32,
		ratio: f64,
		nick:  Maybe(string),
		name:  string,
		small: u8,
		tags:  []string,
		id:    int,
		set:   model.Fields_Set,
	}
	next_id := 100
	_ = next_id

	reg: model.Registry
	defer model.destroy(&reg)
	testing.expect_value(t, model.register(&reg, Counter, "count", 5), nil)
	testing.expect_value(t, model.register(&reg, Counter, "ratio", 1), nil)
	testing.expect_value(t, model.register(&reg, Counter, "nick", "x"), nil)
	testing.expect_value(t, model.register(&reg, Counter, "small", 200), nil)
	testing.expect_value(t, model.register(&reg, Counter, "tags", []string{"new"}), nil)
	testing.expect_value(t, model.register(&reg, Counter, "id", proc(allocator: runtime.Allocator) -> int {
		return 42
	}), runtime.Allocator_Error.None)

	// Invalid defaults refused at registration.
	for bad_err in ([?]model.Error{
		model.register(&reg, Counter, "small", 300),
		model.register(&reg, Counter, "count", 1.5),
		model.register(&reg, Counter, "name", 5),
	}) {
		me, ok := bad_err.(model.Model_Error)
		testing.expect(t, ok && me.kind == .Wrong_Kind)
	}

	m, cerr := model.compile(&reg, Counter)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)

	c1, c2: Counter
	defer model.free_value(&c1, type_info_of(Counter), a)
	defer model.free_value(&c2, type_info_of(Counter), a)

	testing.expect_value(t, model.load(&m, transmute([]u8)string(`{"name": "ada"}`), json.as(.Json), json.reads(.Json), &c1, allocator = a), nil)
	testing.expect(t, c1.count == 5 && c1.ratio == 1 && c1.nick.? == "x" && c1.small == 200 && c1.id == 42)
	testing.expect(t, len(c1.tags) == 1 && c1.tags[0] == "new")
	testing.expect(t, model.was_set(&m, Counter, c1.set, "name") && !model.was_set(&m, Counter, c1.set, "count"))

	testing.expect_value(t, model.load(&m, transmute([]u8)string(`{"name": "bob"}`), json.as(.Json), json.reads(.Json), &c2, allocator = a), nil)
	testing.expect(t, raw_data(c1.tags) != raw_data(c2.tags))
	testing.expect_value(t, c2.tags[0], "new")
}

@(test)
problem_document_and_json_serialization :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Simple :: struct {
		name:  string `model:"len>=2"`,
		level: int,
		nick:  string,
	}
	m, cerr := model.compile(nil, Simple)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	sink: model.Sink
	defer model.destroy(&sink)
	v: Simple
	defer model.free_value(&v, type_info_of(Simple), context.allocator)

	err := model.load(&m, transmute([]u8)string(`{"name": "a", "level": "x"}`), json.as(.Json), json.reads(.Json), &v, &sink)
	testing.expect(t, err != nil)
	testing.expect_value(t, len(sink.entries), 3)

	p, perr := model.problem(sink.entries[:], "Invalid body", 422)
	defer model.problem_destroy(p)
	testing.expect_value(t, perr, runtime.Allocator_Error.None)
	testing.expect_value(t, len(p.errors), 3)
	testing.expect_value(t, p.errors[0].pointer, "/name")
	testing.expect_value(t, p.errors[0].code, "too_short")
	testing.expect_value(t, p.errors[1].pointer, "/level")
	testing.expect_value(t, p.errors[1].code, "wrong_kind")
	testing.expect_value(t, p.errors[2].pointer, "/nick")
	testing.expect_value(t, p.errors[2].code, "missing_field")

	// Also test `write_problem_tokens` -> `tape.Document` -> `json.write`.
	tt: write.Token_Tape
	testing.expect_value(t, write.token_tape_start(&tt, false, 0, context.allocator), runtime.Allocator_Error.None)
	defer write.token_tape_drop(&tt)
	testing.expect_value(t, model.write_problem_tokens(&tt, sink.entries[:], p), nil)
	doc, derr := write.token_tape_document(&tt)
	testing.expect_value(t, derr, runtime.Allocator_Error.None)
	bytes, _, werr := json.write(&doc)
	defer delete(bytes)
	testing.expect_value(t, werr, nil)
	text := string(bytes)
	testing.expect(t, strings.contains(text, `"title":"Invalid body"`) && strings.contains(text, `"status":422`) && strings.contains(text, `"code":"too_short"`))
}

@(test)
naming_renames_and_forbid_extra_and_roles :: proc(t: ^testing.T) {
	testkit.deadline(t)
	User :: struct {
		user_id:    i64 `model:"read_only"`,
		first_name: string `model:"len>=2"`,
		secret_key: string `model:"write_only"`,
	}
	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, model.Naming{fields = .Camel})
	_ = model.register(&reg, User, model.Extra.Forbid)

	m, cerr := model.compile(&reg, User)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	u: User
	defer model.free_value(&u, type_info_of(User), context.allocator)
	testing.expect_value(t, model.load(&m, transmute([]u8)string(`{"firstName":"ada","secretKey":"pw"}`), json.as(.Json), json.reads(.Json), &u), nil)
	testing.expect(t, u.first_name == "ada" && u.secret_key == "pw" && u.user_id == 0)

	// Unknown field refused under Extra.Forbid.
	u2: User
	defer model.free_value(&u2, type_info_of(User), context.allocator)
	sink: model.Sink
	defer model.destroy(&sink)
	testing.expect(t, model.load(&m, transmute([]u8)string(`{"firstName":"ada","secretKey":"pw","extra":1}`), json.as(.Json), json.reads(.Json), &u2, &sink) != nil)
	testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Not_Allowed && sink.entries[0].pointer == "/extra")

	// Dump omits write_only and includes read_only.
	u.user_id = 99
	dumped, derr := model.dump(&m, &u, write_json_default)
	defer delete(dumped)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, string(dumped), `{"userId":99,"firstName":"ada"}`)

	// Describe Load vs Dump schema and verify via `check.compile` + `json.check`.
	load_desc, lerr := model.schema(&m, .Load)
	defer rules.description_destroy(&load_desc)
	testing.expect_value(t, lerr, nil)
	lplan, lperr := check.compile(&load_desc)
	defer check.plan_destroy(&lplan)
	testing.expect_value(t, lperr.kind, rules.Error_Kind.None)

	ok_res := json.check(transmute([]u8)string(`{"firstName":"ada","secretKey":"pw"}`), &lplan)
	defer check.result_destroy(&ok_res)
	testing.expect(t, ok_res.valid)

	bad_res := json.check(transmute([]u8)string(`{"firstName":"ada","secretKey":"pw","extra":1}`), &lplan)
	defer check.result_destroy(&bad_res)
	testing.expect(t, !bad_res.valid)
	_ = fmt.tprint
}
