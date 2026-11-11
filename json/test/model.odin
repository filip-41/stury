package json_tests

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import schema "../../core/schema"
import json ".."
import model "../../core/model"
import walktest "../../walktest"

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
	secret: string `model:"write_only"`,
	note:   string `json:"-"`,
	rooms:  []Room `model:"optional"`,
	temps:  map[string]Celsius `model:"optional"`,
}

// The registry the tests compile `Account` with: a bound on every `Celsius` and one more on `Room.name`.
@(private = "file")
account_registry :: proc(reg: ^model.Registry) {
	model.register(reg, model.Type_Rule{Celsius, ">=-273.15"})
	model.register(reg, model.Field_Rule_Of{Room, "name", "len>=2"})
}

// The path of `steps` as `.a[1].b`.
@(private = "file")
steps_text :: proc(steps: []core.Step) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s in steps {
		#partial switch v in s {
		case core.Name:
			fmt.sbprintf(&b, ".%s", string(v))
		case core.Index:
			fmt.sbprintf(&b, "[%d]", int(v))
		}
	}
	return strings.to_string(b)
}

@(test)
a_model_validates_its_rules_with_paths :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	reg: model.Registry
	defer model.destroy(&reg)
	account_registry(&reg)
	m, compiled := model.compile(&reg, Account, json.checks(.Json))
	defer model.destroy(&m)
	walktest.expect_nil(t, compiled)
	good := Account{id = 1, name = "ada", age = 36, score = 0.5, step = 10, tags = {"a"}, mail = "ada@example.org", secret = "s", rooms = {{"lab", 20}}}
	walktest.expect_nil(t, model.validate(&m, &good))
	bad := Account {
		name  = "abcdefghiJ",
		age   = 10,
		score = 1,
		step  = 7,
		tags  = {"a", "b", "c"},
		mail  = "x",
		rooms = {{"lab", 20}, {"b", -300}},
	}
	bad.temps = make(map[string]Celsius, context.temp_allocator)
	bad.temps["out"] = -274
	first := model.validate(&m, &bad)
	f, is_typed := first.(core.Typed_Error)
	testing.expect(t, is_typed)
	testing.expect_value(t, f.kind, core.Typed_Error_Kind.Too_Long)
	testing.expect_value(t, steps_text(f.steps), ".name")
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	testing.expect_value(t, walktest.typed_kind(model.validate(&m, &bad, &sink)), core.Typed_Error_Kind.Too_Long)
	want := [?]struct {
		kind: core.Typed_Error_Kind,
		path: string,
	} {
		{.Too_Long, ".name"},
		{.No_Match, ".name"},
		{.Below_Minimum, ".age"},
		{.Above_Maximum, ".score"},
		{.Not_Multiple, ".step"},
		{.Too_Many, ".tags"},
		{.Bad_Format, ".email"},
		{.Too_Short, ".rooms[1].name"},
		{.Below_Minimum, ".rooms[1].temp"},
		{.Below_Minimum, ".temps.out"},
	}
	testing.expect_value(t, len(sink.entries), len(want))
	for e, i in sink.entries[:min(len(sink.entries), len(want))] {
		testing.expectf(t, e.kind == want[i].kind && steps_text(e.path) == want[i].path, "%d: %v %s", i, e.kind, steps_text(e.path))
	}
	limited := typed.Sink{max_errors = 2}
	defer typed.sink_destroy(&limited)
	model.validate(&m, &bad, &limited)
	testing.expect(t, len(limited.entries) == 2 && limited.truncated)
}

@(test)
a_model_validates_what_a_write_refuses :: proc(t: ^testing.T) {
	Picked :: struct {
		x: f32,
		e: enum u8 {
			A,
			B,
		},
		n: i32 `model:">=0"`,
	}
	reg: model.Registry
	m, _ := model.compile(&reg, Picked, json.checks(.Json))
	defer model.destroy(&m)
	v := Picked{x = math.inf_f32(1), e = transmute(type_of(Picked{}.e))u8(7), n = -1}
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	walktest.expect_kind(t, model.validate(&m, &v, &sink), core.Typed_Error_Kind.Non_Finite)
	kinds: [dynamic]core.Typed_Error_Kind
	defer delete(kinds)
	for e in sink.entries {
		append(&kinds, e.kind)
	}
	testing.expect_value(t, fmt.tprint(kinds[:]), `["Non_Finite", "Not_A_Member", "Below_Minimum"]`)
	free_all(context.temp_allocator)
}

@(test)
a_rule_that_does_not_fit_refuses_the_model :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
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
	Flag_On_Type :: struct {
		c: Celsius,
	}
	cases := [?]struct {
		err:  core.Error,
		item: string,
		type: typeid,
	} {
		{refusal(Text_Bound), ">=1", Text_Bound},
		{refusal(Fraction_Divisor), "multiple_of=1.5", Fraction_Divisor},
		{refusal(Fraction_Bound), ">=1.5", Fraction_Bound},
		{refusal(Both_Roles), "write_only", Both_Roles},
		{refusal(Unknown_Format), "format=nope", Unknown_Format},
		{refusal(Count_On_Number), "len>=1", Count_On_Number},
	}
	for c, i in cases {
		f, _ := c.err.(core.Typed_Error)
		testing.expectf(t, f.kind == .Bad_Tag && f.want.text == c.item && f.want.type == c.type, "%d: %v", i, c.err)
	}
	reg: model.Registry
	defer model.destroy(&reg)
	model.register(&reg, model.Type_Rule{Celsius, "optional"})
	_, flagged := model.compile(&reg, Flag_On_Type, json.checks(.Json), context.temp_allocator)
	testing.expect_value(t, walktest.typed_kind(flagged), core.Typed_Error_Kind.Bad_Tag)
	testing.expect_value(t, model.register(&reg, model.Field_Rule_Of{Room, "nope", ">=1"}), runtime.Allocator_Error.None)
	_, unknown := model.compile(&reg, Room, json.checks(.Json), context.temp_allocator)
	f, _ := unknown.(core.Typed_Error)
	testing.expectf(t, f.kind == .Bad_Tag && f.want.type == Room && steps_text(f.steps) == ".nope", "%v", unknown)
	clash: model.Registry
	defer model.destroy(&clash)
	model.register(&clash, model.Field_Rule_Of{Account, "name", "pattern=^a"})
	_, clashed := model.compile(&clash, Account, json.checks(.Json), context.temp_allocator)
	testing.expect_value(t, walktest.typed_kind(clashed), core.Typed_Error_Kind.Bad_Tag)
}

@(private = "file")
Float_32 :: struct {
	x: f32 `model:"<=0.1"`,
}

@(private = "file")
Float_32_Open :: struct {
	x: f32 `model:"<0.1"`,
}

@(private = "file")
Float_64 :: struct {
	x: f64 `model:"<=0.3"`,
}

@(private = "file")
Float_64_Low :: struct {
	x: f64 `model:">=0.30000000000000004"`,
}

@(private = "file")
Float_Step :: struct {
	x: f64 `model:"multiple_of=0.1"`,
	y: f32 `model:"multiple_of=0.1"`,
}

// `validate(v)`, the load of `marshal(v)` and its schema's check of `marshal(v)` agree that `v` is `valid`.
@(private = "file")
float_law :: proc(t: ^testing.T, v: $T, valid: bool, loc := #caller_location) {
	reg: model.Registry
	m, _ := model.compile(&reg, T, json.checks(.Json), context.temp_allocator)
	v := v
	validated := model.validate(&m, &v) == nil
	text, _ := write.marshal(v, &m.plan, allocator = context.temp_allocator)
	back: T
	loaded := model.load(&m, text, &back, nil, {dups = .Refuse}, context.temp_allocator) == nil
	d, _ := model.schema(&m, .Dump, context.temp_allocator)
	c := schema.compile_description(&d, allocator = context.temp_allocator)
	b, _ := schema.bind(&c, {layout = json.as(.Json)}, allocator = context.temp_allocator)
	checked := schema.valid(&b, text)
	testing.expectf(t, validated == valid && loaded == valid && checked == valid, "%v %s: validate %v, load %v, check %v", typeid_of(T), text, validated, loaded, checked, loc = loc)
}

@(test)
a_float_is_judged_by_the_text_a_write_gives :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	tenth := f32(0.1)
	float_law(t, Float_32{tenth}, true)
	float_law(t, Float_32{math.nextafter_f32(tenth, 1)}, false)
	float_law(t, Float_32{math.nextafter_f32(tenth, 0)}, true)
	float_law(t, Float_32_Open{tenth}, false)
	float_law(t, Float_32_Open{math.nextafter_f32(tenth, 0)}, true)
	sum := 0.1 + f64(0.2)
	float_law(t, Float_64{0.3}, true)
	float_law(t, Float_64{sum}, false)
	float_law(t, Float_64{math.nextafter_f64(sum, 0)}, true)
	float_law(t, Float_64_Low{sum}, true)
	float_law(t, Float_64_Low{0.3}, false)
	float_law(t, Float_Step{0.3, 0.3}, true)
	float_law(t, Float_Step{sum, 0.3}, false)
	float_law(t, Float_Step{0.3, math.nextafter_f32(0.3, 1)}, false)
}

@(test)
a_model_has_a_load_schema_and_a_dump_schema :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	Login :: struct {
		id:       i64 `model:"read_only,>=1"`,
		user:     string `model:"len>=1"`,
		password: string `model:"write_only"`,
		hint:     string `json:",omitempty" model:"optional"`,
	}
	reg: model.Registry
	m, compiled := model.compile(&reg, Login, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	texts: [model.Direction]string
	for direction in model.Direction {
		d, described := model.schema(&m, direction)
		walktest.expect_nil(t, described)
		text, written := schema.write(&d, json.as(.Json))
		walktest.expect_nil(t, written)
		texts[direction] = string(text)
	}
	testing.expect_value(t, texts[.Load], `{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"id":{"readOnly":true},"user":{"$ref":"#/$defs/n2","minLength":1},"password":{"$ref":"#/$defs/n2","writeOnly":true},"hint":{"$ref":"#/$defs/n2"}},"required":["user","password"],"$defs":{"n2":{"type":"string"}}}`)
	testing.expect_value(t, texts[.Dump], `{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"id":{"type":"integer","minimum":1,"maximum":9223372036854775807,"readOnly":true},"user":{"$ref":"#/$defs/n2","minLength":1},"hint":{"$ref":"#/$defs/n2"}},"required":["id","user"],"$defs":{"n2":{"type":"string"}}}`)
	load, _ := model.schema(&m, .Load)
	doc, built := core.build(transmute([]u8)texts[.Load], json.as(.Json))
	walktest.expect_nil(t, built)
	read, read_err := schema.compile(core.span(&doc, core.ROOT), json.as(.Json), {})
	walktest.expect_nil(t, read_err)
	for member in read.description.objects[0].members {
		node := read.description.nodes[member.node].rules
		testing.expectf(t, node.read_only == (member.name == "id") && node.write_only == (member.name == "password"), "%s", member.name)
	}
	c := schema.compile_description(&load)
	b, _ := schema.bind(&c, json.checks(.Json))
	testing.expect(t, schema.valid(&b, transmute([]u8)string(`{"id": "any", "user": "a", "password": "p"}`)))
	testing.expect(t, !schema.valid(&b, transmute([]u8)string(`{"id": 1, "user": "a"}`)))
}

@(test)
a_nil_registry_compiles_a_plain_type :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m, compiled := model.compile(nil, Room, json.checks(.Json), context.temp_allocator)
	walktest.expect_nil(t, compiled)
	v := Room{"lab", 20}
	walktest.expect_nil(t, model.validate(&m, &v))
}

@(private = "file")
Empty_Bounds :: struct {
	x: i32 `model:">=5,<=3"`,
}

@(private = "file")
Empty_Open_Range :: struct {
	x: f64 `model:"0..<0"`,
}

@(private = "file")
Empty_Range :: struct {
	x: int `model:"5..=1"`,
}

@(private = "file")
Empty_Length :: struct {
	s: string `model:"len=3..=1"`,
}

@(private = "file")
Short_Array :: struct {
	a: [4]int `model:"len<=2"`,
}

@(private = "file")
Past_Type :: struct {
	x: i32 `model:">=1e999"`,
}

@(private = "file")
Below_Type :: struct {
	x: u8 `model:"<0"`,
}

@(private = "file")
Registry_Clash :: struct {
	x: int `model:">=5"`,
}

@(private = "file")
Bad_Pattern :: struct {
	name: string `model:"pattern=(("`,
}

@(private = "file")
Required_And_Optional :: struct {
	x: int `json:",required" model:"optional"`,
}

@(private = "file")
Skipped_With_Rules :: struct {
	x: int `json:"-" model:">=5"`,
}

@(private = "file")
Spaced :: struct {
	x: int `json:"ex" model:" >= 3 , <= 9"`,
	s: string `model:"len >= 2"`,
	r: int `model:"1 ..= 4"`,
}

@(test)
a_rule_no_value_can_satisfy_refuses_the_model :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		err:  core.Error,
		item: string,
		type: typeid,
		path: string,
	} {
		{refusal(Empty_Bounds), "<=3", Empty_Bounds, ".x"},
		{refusal(Empty_Open_Range), "0..<0", Empty_Open_Range, ".x"},
		{refusal(Empty_Range), "5..=1", Empty_Range, ".x"},
		{refusal(Empty_Length), "len=3..=1", Empty_Length, ".s"},
		{refusal(Short_Array), "len<=2", Short_Array, ".a"},
		{refusal(Past_Type), ">=1e999", Past_Type, ".x"},
		{refusal(Below_Type), "<0", Below_Type, ".x"},
		{refusal(Bad_Pattern), "pattern=((", Bad_Pattern, ".name"},
		{refusal(Required_And_Optional), "required", Required_And_Optional, ".x"},
		{refusal(Skipped_With_Rules), "-", Skipped_With_Rules, ".x"},
	}
	for c, i in cases {
		f, _ := c.err.(core.Typed_Error)
		testing.expectf(t, f.kind == .Bad_Tag && f.want.text == c.item && f.want.type == c.type && steps_text(f.steps) == c.path, "%d: %v", i, c.err)
	}
	reg: model.Registry
	defer model.destroy(&reg)
	model.register(&reg, model.Field_Rule_Of{Registry_Clash, "x", "<=3"})
	_, clashed := model.compile(&reg, Registry_Clash, json.checks(.Json), context.temp_allocator)
	f, _ := clashed.(core.Typed_Error)
	testing.expectf(t, f.kind == .Bad_Tag && f.want.text == ">=5" && f.want.type == Registry_Clash, "%v", clashed)
	message := fmt.tprint(refusal(Past_Type))
	testing.expectf(t, strings.contains(message, "Past_Type"), "%s", message)
}

@(private = "file")
Pattern_First :: struct {
	s: string `model:"pattern=^a+$,len<=3"`,
}

@(private = "file")
Pattern_Last :: struct {
	s: string `model:"len<=3,pattern=^a{1,3}$|^b,c$"`,
}

// `pattern=` takes the rest of the tag, so a struct tag refuses one that would take an item after it, and a pattern
// registered with `register_field` takes the same text whole.
@(test)
a_pattern_before_another_tag_item_refuses_the_model :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, first := model.compile(nil, Pattern_First, json.checks(.Json), context.temp_allocator)
	f, _ := first.(core.Typed_Error)
	testing.expectf(t, f.kind == .Bad_Tag && f.want.text == "pattern=^a+$,len<=3" && steps_text(f.steps) == ".s", "%v", first)
	b := strings.builder_make(context.temp_allocator)
	core.render(strings.to_writer(&b), nil, first)
	message := strings.to_string(b)
	testing.expectf(t, strings.contains(message, "put it last") && strings.contains(message, "register_field"), "%s", message)
	last, compiled := model.compile(nil, Pattern_Last, json.checks(.Json), context.temp_allocator)
	walktest.expect_nil(t, compiled)
	for c in ([?]struct {
			s:  string,
			ok: bool,
		}{{"aaa", true}, {"b,c", true}, {"aaaa", false}, {"b", false}}) {
		v := Pattern_Last{c.s}
		testing.expectf(t, (model.validate(&last, &v) == nil) == c.ok, "%q", c.s)
	}
	reg: model.Registry
	defer model.destroy(&reg)
	model.register(&reg, model.Field_Rule_Of{Pattern_Plain, "s", "pattern=^a+,len<=3$"})
	registered, err := model.compile(&reg, Pattern_Plain, json.checks(.Json), context.temp_allocator)
	walktest.expect_nil(t, err)
	v := Pattern_Plain{"aa,len<=3"}
	walktest.expect_nil(t, model.validate(&registered, &v))
	v.s = "aa"
	testing.expect(t, model.validate(&registered, &v) != nil)
}

@(private = "file")
Pattern_Plain :: struct {
	s: string,
}

@(test)
a_tag_item_may_hold_spaces :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m, compiled := model.compile(nil, Spaced, json.checks(.Json), context.temp_allocator)
	walktest.expect_nil(t, compiled)
	v := Spaced{4, "ab", 2}
	walktest.expect_nil(t, model.validate(&m, &v))
	v = {2, "a", 5}
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	model.validate(&m, &v, &sink)
	testing.expect_value(t, len(sink.entries), 3)
}

@(private = "file")
Secret :: struct {
	name: string,
	key:  string `model:"write_only"`,
	pin:  int `model:"write_only,optional" json:",omitempty"`,
	rest: int `model:"optional" json:",omitempty"`,
}

@(test)
a_write_leaves_out_write_only_members :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m, compiled := model.compile(nil, Secret, json.checks(.Json), context.temp_allocator)
	walktest.expect_nil(t, compiled)
	v := Secret{"a", "k", 7, 0}
	text, written := write.marshal(v, &m.plan, allocator = context.temp_allocator)
	walktest.expect_nil(t, written)
	testing.expect_value(t, string(text), `{"name":"a"}`)
	v.rest = 1
	text, _ = write.marshal(v, &m.plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(text), `{"name":"a","rest":1}`)
	back: Secret
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name":"b","key":"s"}`), &back, nil, {dups = .Refuse}, context.temp_allocator))
	testing.expect_value(t, back.key, "s")
}

@(private = "file")
Stamped :: struct {
	a: int,
	b: int,
}

@(test)
a_plan_stamp_tells_required_members_apart :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	required, _ := model.compile(nil, Stamped, json.checks(.Json), context.temp_allocator)
	reg: model.Registry
	defer model.destroy(&reg)
	model.register(&reg, model.Field_Rule_Of{Stamped, "b", "optional"})
	optional, _ := model.compile(&reg, Stamped, json.checks(.Json), context.temp_allocator)
	testing.expect(t, required.plan.stamp != optional.plan.stamp)
}
