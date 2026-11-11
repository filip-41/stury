package json_tests

import "base:runtime"
import "core:encoding/uuid"
import "core:strings"
import "core:testing"
import "core:time"
import core "../../core"
import rules "../../core/rules"
import typed "../../core/typed"
import write "../../core/write"
import schema "../../core/schema"
import json ".."
import model "../../core/model"
import walktest "../../walktest"

// The description of the JSON Schema `text`, in the context allocator.
@(private = "file")
fragment :: proc(text: string) -> ^rules.Description {
	s, err := json.load_schema(transmute([]u8)text)
	assert(err == nil)
	return s.description
}

@(private = "file")
Stamped :: struct {
	at: time.Time,
}

@(private = "file")
Tagged :: struct {
	id: uuid.Identifier,
}

@(private = "file")
Blob :: struct {
	data: model.Base64,
}

@(private = "file")
Priced :: struct {
	price: model.Decimal,
}

@(private = "file")
Contact :: struct {
	mail: model.Email,
}

// The kind of `err`'s refusal, `.None` for nil.
@(private)
refused_as :: proc(err: core.Error) -> core.Typed_Error_Kind {
	#partial switch e in err {
	case core.Typed_Error:
		return e.kind
	case core.Typed_Error_Kind:
		return e
	case nil:
		return .None
	}
	return .Walk
}

@(private = "file")
load_one :: proc(m: ^model.Model($T), text: string) -> (v: T, kind: core.Typed_Error_Kind) {
	kind = refused_as(model.load(m, transmute([]u8)text, &v))
	return
}

@(test)
a_time_reads_rfc_3339_into_utc :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	m, compiled := model.compile(nil, Stamped, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	Case :: struct {
		text: string,
		want: string,
	}
	cases := [?]Case {
		{`{"at": "1985-04-12T23:20:50.52Z"}`, "1985-04-12T23:20:50.52Z"},
		{`{"at": "1996-12-19T16:39:57-08:00"}`, "1996-12-20T00:39:57Z"},
		{`{"at": "1990-12-31t23:59:60z"}`, "1991-01-01T00:00:00Z"},
		{`{"at": "1990-12-31T15:59:60-08:00"}`, "1991-01-01T00:00:00Z"},
		{`{"at": "2024-02-29T00:00:00+14:00"}`, "2024-02-28T10:00:00Z"},
	}
	for c in cases {
		v, kind := load_one(&m, c.text)
		testing.expectf(t, kind == .None, "%s: %v", c.text, kind)
		text, written := write.marshal(v, &m.plan, allocator = context.temp_allocator)
		walktest.expect_nil(t, written)
		testing.expectf(t, string(text) == strings.concatenate({`{"at":"`, c.want, `"}`}), "%s gives %s", c.text, text)
	}
	refusals := [?]struct {
		text: string,
		kind: core.Typed_Error_Kind,
	} {
		{`{"at": "2023-02-29T00:00:00Z"}`, .Bad_Format},
		{`{"at": "1990-12-31T23:59:60+01:00"}`, .Bad_Format},
		{`{"at": "1985-04-12 23:20:50Z"}`, .Bad_Format},
		{`{"at": "1985-04-12T23:20:50"}`, .Bad_Format},
		{`{"at": 1985}`, .Wrong_Kind},
	}
	for r in refusals {
		_, kind := load_one(&m, r.text)
		testing.expectf(t, kind == r.kind, "%s: %v", r.text, kind)
	}
}

@(test)
a_uuid_reads_either_case_and_writes_lowercase :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	m, compiled := model.compile(nil, Tagged, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	v, kind := load_one(&m, `{"id": "F81D4FAE-7DEC-11D0-A765-00a0c91e6bf6"}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.None)
	text, _ := write.marshal(v, &m.plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(text), `{"id":"f81d4fae-7dec-11d0-a765-00a0c91e6bf6"}`)
	_, kind = load_one(&m, `{"id": "f81d4fae7dec11d0a76500a0c91e6bf6"}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Bad_Format)
}

@(test)
base64_reads_the_rfc_4648_vectors_and_refuses_other_spellings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	m, compiled := model.compile(nil, Blob, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	vectors := [?][2]string{{"", ""}, {"f", "Zg=="}, {"fo", "Zm8="}, {"foo", "Zm9v"}, {"foob", "Zm9vYg=="}, {"fooba", "Zm9vYmE="}, {"foobar", "Zm9vYmFy"}}
	for x in vectors {
		v, kind := load_one(&m, strings.concatenate({`{"data": "`, x[1], `"}`}))
		testing.expectf(t, kind == .None && string(v.data) == x[0], "%s: %v %s", x[1], kind, string(v.data))
		text, _ := write.marshal(v, &m.plan, allocator = context.temp_allocator)
		testing.expect_value(t, string(text), strings.concatenate({`{"data":"`, x[1], `"}`}))
	}
	for bad in ([?]string{"A", "Zg=", "Zh==", "Zm9=", "Zm9v=", "Zm 9v", "Zm9v\\n", "Zg==Zg==", "Zm9-"}) {
		_, kind := load_one(&m, strings.concatenate({`{"data": "`, bad, `"}`}))
		testing.expectf(t, kind == .No_Match, "%s: %v", bad, kind)
	}
}

@(test)
a_decimal_keeps_every_digit :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	m, compiled := model.compile(nil, Priced, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	digits := strings.concatenate({"-", strings.repeat("9", 300), ".5e-7"})
	v, kind := load_one(&m, strings.concatenate({`{"price": `, digits, `}`}))
	testing.expect_value(t, kind, core.Typed_Error_Kind.None)
	text, _ := write.marshal(v, &m.plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(text), strings.concatenate({`{"price":`, digits, `}`}))
	v, kind = load_one(&m, `{"price": "12.50"}`)
	testing.expect(t, kind == .None && v.price.text == "12.50" && v.price.double == 12.5)
	_, kind = load_one(&m, `{"price": "12.5.0"}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.No_Match)
	_, kind = load_one(&m, `{"price": true}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Wrong_Kind)
	zero, _ := write.marshal(Priced{}, &m.plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(zero), `{"price":0}`)
}

@(test)
an_email_is_judged_by_its_format :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	m, compiled := model.compile(nil, Contact, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	_, kind := load_one(&m, `{"mail": "ada@example.com"}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.None)
	_, kind = load_one(&m, `{"mail": "ada"}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Bad_Format)
	v := Contact{"nobody"}
	testing.expect_value(t, refused_as(model.validate(&m, &v)), core.Typed_Error_Kind.Bad_Format)
}

@(private = "file")
Cents :: distinct i64

@(private = "file")
Code :: distinct string

@(private = "file")
Bill :: struct {
	total: Cents,
	codes: []Code,
}

@(private = "file")
cents_from :: proc(c: ^string, out: ^Cents, allocator: runtime.Allocator) -> core.Typed_Error_Kind {
	whole, _, fraction := strings.partition(c^, ".")
	n: i64
	for d in transmute([]u8)whole {
		n = n * 10 + i64(d - '0')
	}
	for i in 0 ..< 2 {
		n = n * 10 + (i64(fraction[i] - '0') if i < len(fraction) else 0)
	}
	out^ = Cents(n)
	return .None
}

@(private = "file")
cents_to :: proc(v: ^Cents, allocator: runtime.Allocator) -> (string, core.Typed_Error_Kind) {
	b := strings.builder_make(allocator)
	strings.write_i64(&b, i64(v^) / 100)
	strings.write_byte(&b, '.')
	strings.write_byte(&b, u8('0' + i64(v^) / 10 % 10))
	strings.write_byte(&b, u8('0' + i64(v^) % 10))
	return strings.to_string(b), .None
}

@(private = "file")
code_from :: proc(c: ^[2]i32, out: ^Code, allocator: runtime.Allocator) -> core.Typed_Error_Kind {
	if c[0] > c[1] {
		return .Custom
	}
	out^ = Code(strings.concatenate({"A", "B"}, allocator))
	return .None
}

@(private = "file")
code_to :: proc(v: ^Code, allocator: runtime.Allocator) -> ([2]i32, core.Typed_Error_Kind) {
	return {1, i32(len(v^))}, .None if len(v^) > 0 else .Custom
}

@(test)
a_custom_carrier_reads_its_type_through_another :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, model.Custom(Cents, string){cents_from, cents_to})
	model.register(&reg, model.Custom(Code, [2]i32){code_from, code_to})
	model.register(&reg, model.Type_Rule{Cents, `pattern=^[0-9]+(?:\.[0-9]{1,2})?$`})
	m, compiled := model.compile(&reg, Bill, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	v, kind := load_one(&m, `{"total": "12.5", "codes": [[1, 2]]}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.None)
	testing.expect(t, v.total == 1250 && len(v.codes) == 1 && v.codes[0] == "AB")
	text, _ := write.marshal(v, &m.plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(text), `{"total":"12.50","codes":[[1,2]]}`)
	_, kind = load_one(&m, `{"total": "12.555", "codes": []}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.No_Match)
	_, kind = load_one(&m, `{"total": "1", "codes": [[2, 1]]}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Custom)
	_, kind = load_one(&m, `{"total": "1", "codes": [[1, 2, 3]]}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Wrong_Length)
	bad := Bill{total = 5}
	walktest.expect_nil(t, model.validate(&m, &bad))
	bad.codes = {""}
	testing.expect_value(t, refused_as(model.validate(&m, &bad)), core.Typed_Error_Kind.Custom)
	d, _ := model.schema(&m, .Load)
	described, _ := schema.write(&d, json.as(.Json))
	testing.expect(t, strings.contains(string(described), `"total":{"type":"string","pattern":`), string(described))
	testing.expect(t, strings.contains(string(described), `"items":{"type":"array","minItems":2,"maxItems":2`), string(described))
	model.destroy(&m)
	model.destroy(&reg)
}

@(private = "file")
Event :: struct {
	at:   time.Time,
	blob: model.Base64,
	name: string `model:"format=email,pattern=^a"`,
}

@(test)
a_schema_with_an_asserted_format_names_sturys_dialect :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	m, compiled := model.compile(nil, Event, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	d, described := model.schema(&m, .Load)
	walktest.expect_nil(t, described)
	text, written := schema.write(&d, json.as(.Json))
	walktest.expect_nil(t, written)
	testing.expect_value(t, string(text), `{"$schema":"https://raw.githubusercontent.com/filip-41/stury/main/core/schema/meta/stury/format-assertion.json","type":"object","properties":{"at":{"type":"string","format":"date-time"},"blob":{"type":"string","contentEncoding":"base64","pattern":"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/][AQgw]==|[A-Za-z0-9+/]{2}[AEIMQUYcgkosw048]=)?$"},"name":{"type":"string","pattern":"^a","format":"email"}},"required":["at","blob","name"]}`)
	Dated :: struct {
		day: string `model:"format=date,pattern=^2"`,
	}
	n, _ := model.compile(nil, Dated, json.checks(.Json))
	e, _ := model.schema(&n, .Load)
	text, _ = schema.write(&e, json.as(.Json))
	testing.expect(t, strings.contains(string(text), `"pattern":"^2","format":"date","allOf":[{"pattern":"^(?:\\d{4}-`), string(text))
}

@(private = "file")
Shade :: enum u8 {
	Dark_Red,
	Light_Blue,
	Green,
}

@(private = "file")
Size :: enum i16 {
	Small = -1,
	Large = 7,
}

@(private = "file")
Paint :: struct {
	shade:  Shade,
	size:   Size,
	by:     map[Shade]int,
	shades: bit_set[Shade],
}

@(test)
an_enum_rule_renames_members_or_spells_integers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register_naming(&reg, {enum_members = .Kebab})
	model.register(&reg, model.Enum_Rule{type = Shade, renames = {{"Green", "verde"}}})
	model.register(&reg, model.Enum_Rule{type = Size, by_number = true})
	m, compiled := model.compile(&reg, Paint, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	text := `{"shade":"light-blue","size":-1,"by":{"verde":2},"shades":["dark-red","verde"]}`
	v, kind := load_one(&m, text)
	testing.expect_value(t, kind, core.Typed_Error_Kind.None)
	testing.expect(t, v.shade == .Light_Blue && v.size == .Small && v.by[.Green] == 2 && v.shades == {.Dark_Red, .Green})
	out, _ := write.marshal(v, &m.plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(out), text)
	for bad in ([?]string{`{"shade":"Light_Blue","size":7,"by":{},"shades":[]}`, `{"shade":"green","size":7,"by":{},"shades":[]}`, `{"shade":"verde","size":0,"by":{},"shades":[]}`}) {
		_, kind = load_one(&m, bad)
		testing.expectf(t, kind == .Not_A_Member, "%s: %v", bad, kind)
	}
	_, kind = load_one(&m, `{"shade":"verde","size":"Large","by":{},"shades":[]}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Wrong_Kind)
	v, kind = load_one(&m, `{"shade":"verde","size":7.0,"by":{},"shades":[]}`)
	testing.expect(t, kind == .None && v.size == .Large)
	_, kind = load_one(&m, `{"shade":"verde","size":7.5,"by":{},"shades":[]}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Wrong_Kind)
	d, _ := model.schema(&m, .Load)
	schema_text, _ := schema.write(&d, json.as(.Json))
	testing.expect(t, strings.contains(string(schema_text), `"enum":["dark-red","light-blue","verde"]`), string(schema_text))
	testing.expect(t, strings.contains(string(schema_text), `"enum":[-1,7]`), string(schema_text))
	clash: model.Registry
	model.register(&clash, model.Enum_Rule{type = Shade, renames = {{"Green", "Dark_Red"}}})
	_, refused := model.compile(&clash, Paint, json.checks(.Json))
	testing.expect_value(t, refused_as(refused), core.Typed_Error_Kind.Bad_Tag)
	unknown: model.Registry
	model.register(&unknown, model.Enum_Rule{type = Shade, renames = {{"Purple", "p"}}})
	_, refused = model.compile(&unknown, Paint, json.checks(.Json))
	testing.expect_value(t, refused_as(refused), core.Typed_Error_Kind.Bad_Tag)
	Twin :: enum {
		Ab,
		AB,
	}
	kebab: model.Registry
	model.register_naming(&kebab, {enum_members = .Kebab})
	_, refused = model.compile(&kebab, struct{ twin: Twin }, json.checks(.Json))
	testing.expect_value(t, refused_as(refused), core.Typed_Error_Kind.Bad_Tag)
}

@(private = "file")
Circle :: struct {
	r: f64,
}

@(private = "file")
Square :: struct {
	side: f64,
}

@(private = "file")
Shape :: union {
	Circle,
	Square,
}

@(private = "file")
Drawing :: struct {
	shapes: []Shape,
	main:   Shape,
}

@(test)
a_union_rule_names_the_member_that_tags_its_arm :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register_naming(&reg, {union_tag = "type"})
	model.register(&reg, model.Union_Rule{type = Shape, tag = "kind"})
	m, compiled := model.compile(&reg, Drawing, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	text := `{"shapes":[{"kind":"Circle","r":1},{"side":2,"kind":"Square"}],"main":{"kind":"Square","side":3}}`
	v, kind := load_one(&m, text)
	testing.expect_value(t, kind, core.Typed_Error_Kind.None)
	testing.expect(t, len(v.shapes) == 2 && v.shapes[0].(Circle).r == 1 && v.shapes[1].(Square).side == 2 && v.main.(Square).side == 3)
	out, _ := write.marshal(v, &m.plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(out), `{"shapes":[{"kind":"Circle","r":1},{"kind":"Square","side":2}],"main":{"kind":"Square","side":3}}`)
	refusals := [?]struct {
		text: string,
		kind: core.Typed_Error_Kind,
	} {
		{`{"shapes":[{"type":"Circle","r":1}],"main":{"kind":"Square","side":3}}`, .Missing_Tag},
		{`{"shapes":[],"main":{"kind":"Triangle"}}`, .Not_A_Member},
	}
	for r in refusals {
		_, kind = load_one(&m, r.text)
		testing.expectf(t, kind == r.kind, "%s: %v", r.text, kind)
	}
	Loose :: union {
		Circle,
		Square,
		f64,
	}
	model.register(&reg, model.Union_Rule{type = Loose, tag = "kind"})
	loose, _ := model.compile(&reg, struct{ s: Loose }, json.checks(.Json))
	_, kind = load_one(&loose, `{"s":{"kind":"","r":1}}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Not_A_Member)
	Kind_Member :: struct {
		kind: int,
	}
	Clash :: union {
		Circle,
		Square,
		Kind_Member,
	}
	model.register(&reg, model.Union_Rule{type = Clash, tag = "kind"})
	_, refused := model.compile(&reg, struct{ c: Clash }, json.checks(.Json))
	testing.expect_value(t, refused_as(refused), core.Typed_Error_Kind.Unsupported)
}

@(private = "file")
Port :: union {
	u16,
	string,
	[2]u16,
}

@(private = "file")
Endpoint :: struct {
	port: Port `model:"optional"`,
	any:  Shape,
}

@(test)
a_first_match_union_reads_the_first_arm_that_reads_its_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register_naming(&reg, {union_tag = "kind"})
	model.register(&reg, model.Union_Rule{type = Port, mode = .First_Match})
	model.register(&reg, model.Type_Rule{u16, ">=1"})
	m, compiled := model.compile(&reg, Endpoint, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	Case :: struct {
		text: string,
		want: Port,
	}
	cases := [?]Case{{`{"port": 80, "any": {"kind": "Circle", "r": 1}}`, u16(80)}, {`{"port": "http", "any": {"kind": "Circle", "r": 1}}`, "http"}, {`{"port": [1, 2], "any": {"kind": "Circle", "r": 1}}`, [2]u16{1, 2}}}
	for c in cases {
		v, kind := load_one(&m, c.text)
		testing.expectf(t, kind == .None && v.port == c.want, "%s: %v %v", c.text, kind, v.port)
	}
	sink := typed.Sink{max_errors = 10}
	v: Endpoint
	err := model.load(&m, transmute([]u8)string(`{"port": 0, "any": {"kind": "Circle", "r": 1}}`), &v, &sink)
	testing.expect_value(t, refused_as(err), core.Typed_Error_Kind.No_Arm)
	kinds: [dynamic]core.Typed_Error_Kind
	for e in sink.entries {
		append(&kinds, e.kind)
	}
	testing.expectf(t, len(kinds) == 4 && kinds[0] == .No_Arm && kinds[1] == .Below_Minimum && kinds[2] == .Wrong_Kind && kinds[3] == .Wrong_Kind, "%v", kinds)
}

@(private = "file")
Reading :: union {
	u8,
	i64,
}

@(private = "file")
Readings :: struct {
	list:  []Reading,
	maybe: Maybe(Reading),
	by:    map[string]Reading,
	none:  Reading,
}

@(test)
a_first_match_union_reads_alike_wherever_it_is :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, model.Union_Rule{type = Reading, mode = .First_Match})
	model.register(&reg, model.Type_Rule{u8, ">=10"})
	m, compiled := model.compile(&reg, Readings, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	v, kind := load_one(&m, `{"list": [5, 20, 300], "maybe": 5, "by": {"a": 20, "b": 5}, "none": null}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.None)
	testing.expectf(t, len(v.list) == 3 && v.list[0] == i64(5) && v.list[1] == u8(20) && v.list[2] == i64(300), "%v", v.list)
	testing.expectf(t, v.maybe.? == i64(5) && v.by["a"] == u8(20) && v.by["b"] == i64(5) && v.none == nil, "%v %v %v", v.maybe, v.by, v.none)
	root, rooted := model.compile(&reg, Reading, json.checks(.Json))
	walktest.expect_nil(t, rooted)
	r, read := load_one(&root, `5`)
	testing.expect(t, read == .None && r == i64(5))
	d, _ := model.schema(&m, .Load)
	text, _ := schema.write(&d, json.as(.Json))
	testing.expect(t, strings.contains(string(text), `{"type":"integer","minimum":10,"maximum":255}`), string(text))
	plain: model.Registry
	_, refused := model.compile(&plain, Readings, json.checks(.Json))
	testing.expect_value(t, refused_as(refused), core.Typed_Error_Kind.Ambiguous_Union)
}

@(private = "file")
Moment :: union {
	time.Time,
	i64,
}

@(test)
a_carrier_arm_reads_by_its_carriers_kind :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	m, compiled := model.compile(nil, struct{ at: Moment }, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	v, kind := load_one(&m, `{"at": "2020-01-01T00:00:00Z"}`)
	testing.expect(t, kind == .None && v.at.(time.Time) == time.unix(1577836800, 0))
	v, kind = load_one(&m, `{"at": 3}`)
	testing.expect(t, kind == .None && v.at == i64(3))
	_, kind = load_one(&m, `{"at": "x"}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Bad_Format)
	d, _ := model.schema(&m, .Load)
	text, _ := schema.write(&d, json.as(.Json))
	testing.expect(t, strings.contains(string(text), `"anyOf":[{"type":"string","format":"date-time"},{"type":"integer"`), string(text))
}

@(private = "file")
Tags :: distinct []string

@(private = "file")
Shipping :: struct {
	kind:    string,
	card:    Maybe(string) `model:"optional"`,
	billing: Maybe(string) `model:"optional"`,
	tags:    Tags,
	codes:   []i64 `model:"unique"`,
	extra:   map[string]core.Value `json:",unknown"`,
}

@(test)
fragments_judge_a_load_and_describe_as_their_keywords :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, Tags, fragment(`{"contains": {"minLength": 3}, "maxContains": 1}`))
	model.register(&reg, Shipping, fragment(`{"dependentRequired": {"card": ["billing"]}, "patternProperties": {"^x-": {"type": "integer"}}}`))
	model.register(&reg, Shipping, fragment(`{"propertyNames": {"minLength": 3}}`))
	model.register(&reg, Shipping, fragment(`{"if": {"properties": {"kind": {"const": "post"}}, "required": ["kind"]}, "then": {"required": ["zip"]}}`))
	m, compiled := model.compile(&reg, Shipping, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	Case :: struct {
		text: string,
		want: core.Typed_Error_Kind,
	}
	cases := [?]Case {
		{`{"kind": "air", "tags": ["ab", "abc"], "codes": [1, 2]}`, .None},
		{`{"kind": "air", "tags": ["ab"], "codes": []}`, .Too_Few},
		{`{"kind": "air", "tags": ["abc", "abcd"], "codes": []}`, .Too_Many},
		{`{"kind": "air", "tags": ["abc"], "codes": [1, 1]}`, .Not_Unique},
		{`{"kind": "air", "card": "1", "tags": ["abc"], "codes": []}`, .Missing_Field},
		{`{"kind": "air", "tags": ["abc"], "codes": [], "x-a": "s"}`, .Wrong_Kind},
		{`{"kind": "air", "tags": ["abc"], "codes": [], "x-a": 1}`, .None},
		{`{"kind": "post", "tags": ["abc"], "codes": []}`, .Missing_Field},
		{`{"kind": "post", "tags": ["abc"], "codes": [], "zip": "1"}`, .None},
	}
	for c in cases {
		_, kind := load_one(&m, c.text)
		testing.expectf(t, kind == c.want, "%s: %v", c.text, kind)
	}
	d, _ := model.schema(&m, .Load)
	text, _ := schema.write(&d, json.as(.Json))
	for word in ([?]string{`"contains":`, `"maxContains":1`, `"uniqueItems":true`, `"dependentRequired":{"card":["billing"]}`, `"patternProperties":{"^x-":`, `"propertyNames":`, `"if":`, `"then":`}) {
		testing.expectf(t, strings.contains(string(text), word), "%s in %s", word, text)
	}
}

@(private = "file")
Unique_Inside :: struct {
	tags: Maybe([]string) `model:"optional,unique"`,
}

@(private = "file")
Unique_Then :: struct {
	inside: Unique_Inside,
	names:  []string `model:"optional"`,
	flag:   bool `model:"optional"`,
}

@(test)
a_unique_list_held_by_a_maybe_is_judged_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	m, compiled := model.compile(&reg, Unique_Then, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	_, kind := load_one(&m, `{"inside": {"tags": ["a"]}, "names": ["b"], "flag": 1}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Wrong_Kind)
	_, kind = load_one(&m, `{"inside": {"tags": ["a", "a"]}, "names": ["b"]}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Not_Unique)
	_, kind = load_one(&m, `{"inside": {"tags": ["a"]}, "names": ["b"], "flag": true}`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.None)
}

@(private = "file")
Either :: union {
	i64,
	f64,
}

@(test)
a_one_match_union_refuses_a_value_two_arms_read :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, model.Union_Rule{type = Either, mode = .One_Match})
	m, compiled := model.compile(&reg, Either, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	v, kind := load_one(&m, `1.5`)
	testing.expectf(t, kind == .None && v == f64(1.5), "%v %v", kind, v)
	_, kind = load_one(&m, `1`)
	testing.expect(t, kind != .None)
	d, _ := model.schema(&m, .Load)
	text, _ := schema.write(&d, json.as(.Json))
	testing.expect(t, strings.contains(string(text), `"oneOf"`), string(text))
}

@(private = "file")
Boxes :: distinct [][]string

@(test)
a_judged_value_inside_a_judged_value_is_judged_by_each_fragment :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, Tags, fragment(`{"contains": {"minLength": 3}}`))
	model.register(&reg, Boxes, fragment(`{"contains": {"contains": {"minLength": 3}}, "minContains": 2}`))
	m, compiled := model.compile(&reg, Boxes, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	_, kind := load_one(&m, `[["abc"], ["a", "abcd"]]`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.None)
	_, kind = load_one(&m, `[["abc"], ["a"]]`)
	testing.expect_value(t, kind, core.Typed_Error_Kind.Too_Few)
}

@(test)
validate_and_a_checked_dump_judge_applicators_as_a_load_does :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, Tags, fragment(`{"contains": {"minLength": 3}, "maxContains": 1}`))
	model.register(&reg, Shipping, fragment(`{"dependentRequired": {"card": ["billing"]}, "patternProperties": {"^x-": {"type": "integer"}}}`))
	model.register(&reg, Shipping, fragment(`{"if": {"properties": {"kind": {"const": "post"}}, "required": ["kind"]}, "then": {"required": ["zip"]}}`))
	m, compiled := model.compile(&reg, Shipping, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	pattern_failed := make(map[string]core.Value)
	pattern_failed["x-a"] = "s"
	Case :: struct {
		v:    Shipping,
		want: core.Typed_Error_Kind,
	}
	cases := [?]Case {
		{{kind = "air", tags = {"ab", "abc"}, codes = {1, 2}}, .None},
		{{kind = "air", tags = {"ab"}}, .Too_Few},
		{{kind = "air", tags = {"abc", "abcd"}}, .Too_Many},
		{{kind = "air", tags = {"abc"}, codes = {1, 1}}, .Not_Unique},
		// A nil member is written as null, which names it for the dependent.
		{{kind = "air", card = "1", tags = {"abc"}}, .None},
		{{kind = "air", tags = {"abc"}, extra = pattern_failed}, .Wrong_Kind},
		{{kind = "post", tags = {"abc"}}, .Missing_Field},
	}
	for &c in cases {
		testing.expectf(t, refused_as(model.validate(&m, &c.v)) == c.want, "%v: %v", c.v, model.validate(&m, &c.v))
		text, dumped := model.dump(&m, &c.v, {check = true})
		testing.expectf(t, refused_as(dumped) == (.None if c.want == .None else .Check_Failed), "%v: %v", c.v, dumped)
		if c.want == .None {
			_, kind := load_one(&m, string(text))
			testing.expectf(t, kind == .None, "%s: %v", text, kind)
		}
	}
	one: model.Registry
	model.register(&one, model.Union_Rule{type = Either, mode = .One_Match})
	e, either := model.compile(&one, Either, json.checks(.Json))
	walktest.expect_nil(t, either)
	read_twice, read_once := Either(i64(1)), Either(f64(1.5))
	testing.expect_value(t, refused_as(model.validate(&e, &read_twice)), core.Typed_Error_Kind.Many_Arms)
	walktest.expect_nil(t, model.validate(&e, &read_once))
}

// A load and a validate of what it read list the same failures in one order: a value's before those inside it, its
// applicator's among them, whatever failed beneath it.
@(test)
a_load_and_validate_list_failures_in_one_order :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, Tags, fragment(`{"contains": {"minLength": 3}, "maxContains": 1}`))
	model.register(&reg, Shipping, fragment(`{"if": {"properties": {"kind": {"const": "post"}}, "required": ["kind"]}, "then": {"required": ["zip"]}}`))
	m, compiled := model.compile(&reg, Shipping, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	listed :: proc(sink: ^typed.Sink) -> string {
		b := strings.builder_make()
		for e in sink.entries {
			strings.write_string(&b, core.entry_code({kind = e.kind}))
			for s in e.path {
				name, _ := s.(core.Name)
				strings.write_byte(&b, '.')
				strings.write_string(&b, string(name))
			}
			strings.write_byte(&b, ' ')
		}
		return strings.to_string(b)
	}
	v: Shipping
	loaded, validated: typed.Sink
	testing.expect(t, model.load(&m, transmute([]u8)string(`{"kind": "post", "card": null, "billing": null, "tags": ["ab"], "codes": [1, 1]}`), &v, &loaded) != nil)
	testing.expect(t, model.validate(&m, &v, &validated) != nil)
	testing.expect_value(t, listed(&loaded), listed(&validated))
	testing.expect_value(t, len(loaded.entries), 3)
	testing.expect(t, len(loaded.entries[0].path) == 0 && loaded.entries[0].kind == .Missing_Field)
}

@(private = "file")
Packed :: struct {
	xs: []Tags,
}

@(test)
a_judged_failure_names_the_path_of_the_value_judged :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, Tags, fragment(`{"contains": {"minLength": 3}}`))
	m, compiled := model.compile(&reg, Packed, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	at_xs_1 :: proc(t: ^testing.T, err: core.Error, loc := #caller_location) {
		e, typed_error := err.(core.Typed_Error)
		testing.expectf(t, typed_error && e.kind == .Too_Few, "%v", err, loc = loc)
		testing.expectf(t, len(e.steps) == 2 && e.steps[0] == core.Name("xs") && e.steps[1] == core.Index(1), "%v", e.steps, loc = loc)
	}
	v: Packed
	at_xs_1(t, model.load(&m, transmute([]u8)string(`{"xs": [["abc"], ["a"]]}`), &v))
	v = {xs = {{"abc"}, {"a"}}}
	at_xs_1(t, model.validate(&m, &v))
}

@(test)
a_keyword_registered_twice_judges_both :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, Tags, fragment(`{"contains": {"minLength": 3}}`))
	model.register(&reg, Tags, fragment(`{"contains": {"enum": ["a", "b"]}, "minContains": 0, "maxContains": 0}`))
	m, compiled := model.compile(&reg, Tags, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	for c in ([?]struct {
			text: string,
			want: core.Typed_Error_Kind,
		}{{`["abc"]`, .None}, {`[]`, .Too_Few}, {`["ab"]`, .Too_Few}, {`["abc", "a"]`, .Too_Many}}) {
		_, kind := load_one(&m, c.text)
		testing.expectf(t, kind == c.want, "%s: %v", c.text, kind)
	}
	d, _ := model.schema(&m, .Load)
	text, _ := schema.write(&d, json.as(.Json))
	testing.expectf(t, strings.count(string(text), `"contains":`) == 2, "%s", text)
}

@(private = "file")
Tree :: struct {
	k: [dynamic]Tree `model:"optional"`,
}

@(test)
a_judged_type_that_holds_itself_judges_each_value_once_at_any_depth :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, Tree, fragment(`{"propertyNames": {"maxLength": 1}}`))
	m, compiled := model.compile(&reg, Tree, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	DEPTH :: 200
	b := strings.builder_make()
	for _ in 0 ..< DEPTH {
		strings.write_string(&b, `{"k": [`)
	}
	strings.write_string(&b, `{"kk": []}`)
	for _ in 0 ..< DEPTH {
		strings.write_string(&b, `]}`)
	}
	_, kind := load_one(&m, strings.to_string(b))
	testing.expect_value(t, kind, core.Typed_Error_Kind.Too_Long)
	_, kind = load_one(&m, strings.to_string(b)[:len(b.buf) - DEPTH * 2 - len(`{"kk": []}`)])
	testing.expect_value(t, kind, core.Typed_Error_Kind.Walk)
	text, _ := strings.replace_all(strings.to_string(b), `"kk"`, `"k"`)
	v, passed := load_one(&m, text)
	testing.expect_value(t, passed, core.Typed_Error_Kind.None)
	walktest.expect_nil(t, model.validate(&m, &v))
}

@(private = "file")
Codes :: struct {
	extra: map[string]string `json:",unknown"`,
}

@(private = "file")
Open_Codes :: struct {
	extra: map[string]core.Value `json:",unknown"`,
}

@(test)
a_pattern_beside_an_extra_map_of_a_type_is_refused :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, Codes, fragment(`{"patternProperties": {"^x-": {"type": "integer"}}}`))
	_, refused := model.compile(&reg, Codes, json.checks(.Json))
	testing.expect_value(t, refused_as(refused), core.Typed_Error_Kind.Unsupported)
	kept: model.Registry
	model.register(&kept, Open_Codes, fragment(`{"patternProperties": {"^x-": {"type": "integer"}}}`))
	_, compiled := model.compile(&kept, Open_Codes, json.checks(.Json))
	walktest.expect_nil(t, compiled)
}

@(private = "file")
Parcel :: struct {
	kind: string,
	zip:  Maybe(string) `json:",omitempty" model:"optional,not_null"`,
	set:  model.Fields_Set,
}

// An applicator judges the value a patch makes, not the patch alone.
@(test)
a_patch_is_judged_by_its_applicators_once_merged :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, Parcel, fragment(`{"if": {"properties": {"kind": {"const": "post"}}, "required": ["kind"]}, "then": {"required": ["zip"]}}`))
	m, compiled := model.compile(&reg, Parcel, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	p: Parcel
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"kind": "air"}`), &p))
	testing.expect_value(t, refused_as(model.patch(&m, &p, transmute([]u8)string(`{"kind": "post"}`))), core.Typed_Error_Kind.Missing_Field)
	testing.expect_value(t, p.kind, "air")
	walktest.expect_nil(t, model.patch(&m, &p, transmute([]u8)string(`{"zip": "1"}`)))
	walktest.expect_nil(t, model.patch(&m, &p, transmute([]u8)string(`{"kind": "post"}`)))
	testing.expect(t, p.kind == "post" && p.zip.? == "1")
}

// A later enum rule of a type replaces the earlier one, which no longer judges.
@(test)
a_later_enum_rule_replaces_the_earlier :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	model.register(&reg, model.Enum_Rule{type = Shade, renames = {{"Purple", "p"}}})
	model.register(&reg, model.Enum_Rule{type = Shade, renames = {{"Green", "verde"}}})
	testing.expect_value(t, len(reg.enums), 1)
	_, compiled := model.compile(&reg, Paint, json.checks(.Json))
	walktest.expect_nil(t, compiled)
}
