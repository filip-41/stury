package json_tests

import "base:runtime"
import "core:fmt"
import "core:encoding/uuid"
import "core:testing"
import "core:time"
import core "../../core"
import typed "../../core/typed"
import json ".."
import model "../../core/model"
import walktest "../../walktest"

@(private = "file")
Address :: struct {
	city: string,
	zip:  Maybe(int) `model:"optional"`,
	set:  model.Fields_Set,
}

@(private = "file")
Account :: struct {
	id:      i64 `model:"read_only"`,
	name:    string `model:"len>=2"`,
	pass:    string `model:"write_only,optional"`,
	level:   int,
	nick:    Maybe(string),
	tags:    []string `model:"optional"`,
	home:    Address `model:"optional"`,
	extra:   map[string]core.Value `json:",unknown"`,
	set:     model.Fields_Set,
}

@(private = "file")
account_model :: proc(reg: ^model.Registry) -> model.Model(Account) {
	model.register(reg, Account, "level", 7)
	m, err := model.compile(reg, Account, json.checks(.Json))
	assert(err == nil, fmt.tprint(err))
	return m
}

@(private = "file")
dumped :: proc(t: ^testing.T, m: ^model.Model(Account), v: ^Account, opts: model.Dump_Opts) -> string {
	text, err := model.dump(m, v, opts, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	return string(text)
}

@(test)
a_dump_leaves_out_what_each_option_excludes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m := account_model(&reg)
	a: Account
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name": "ada", "pass": "s", "nick": null, "home": {"city": "x"}, "zz": 1, "aa": [2]}`), &a))
	a.id = 9
	testing.expect_value(t, dumped(t, &m, &a, {}), `{"id":9,"name":"ada","level":7,"nick":null,"tags":[],"home":{"city":"x","zip":null},"aa":[2],"zz":1}`)
	testing.expect_value(t, dumped(t, &m, &a, {exclude_none = true}), `{"id":9,"name":"ada","level":7,"tags":[],"home":{"city":"x"},"aa":[2],"zz":1}`)
	// Only a null the load did not read is unset.
	testing.expect_value(t, dumped(t, &m, &a, {exclude_unset = true}), `{"id":9,"name":"ada","level":7,"nick":null,"tags":[],"home":{"city":"x"},"aa":[2],"zz":1}`)
	testing.expect_value(t, dumped(t, &m, &a, {exclude_defaults = true}), `{"id":9,"name":"ada","nick":null,"home":{"city":"x"},"aa":[2],"zz":1}`)
	testing.expect_value(t, dumped(t, &m, &a, {exclude_unset = true, exclude_none = true, exclude_defaults = true}), `{"id":9,"name":"ada","home":{"city":"x"},"aa":[2],"zz":1}`)
	a.level, a.id = 8, 0
	testing.expect_value(t, dumped(t, &m, &a, {exclude_defaults = true}), `{"name":"ada","level":8,"nick":null,"home":{"city":"x"},"aa":[2],"zz":1}`)
	// A plain write by the model's plan leaves out only the write_only member.
	text, _ := json.marshal(a, &m.plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(text), `{"id":0,"name":"ada","level":8,"nick":null,"tags":[],"home":{"city":"x","zip":null},"aa":[2],"zz":1}`)
}

@(test)
a_dump_with_check_refuses_an_invalid_value_and_writes_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m := account_model(&reg)
	a := Account{name = "a"}
	sink: typed.Sink
	text, err := model.dump(&m, &a, {check = true}, sink = &sink)
	testing.expect(t, text == nil)
	f, failed := err.(core.Typed_Error)
	testing.expect(t, failed && f.kind == .Check_Failed && f.want.text == "too_short" && len(f.steps) == 1)
	testing.expect_value(t, len(sink.entries), 1)
	a.name = "ab"
	_, err = model.dump(&m, &a, {check = true})
	walktest.expect_nil(t, err)

	// A captured key that names a member is refused, also where the dump leaves the member out.
	a.extra = make(map[string]core.Value)
	a.extra["nick"] = {}
	_, err = model.dump(&m, &a, {exclude_none = true})
	testing.expect(t, err != nil)
}

@(test)
a_dump_loads_back_to_its_value :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m := account_model(&reg)
	a := Account{name = "ada", level = 3, nick = "n", tags = {"x", "y"}, home = {city = "c", zip = 5}}
	text, err := model.dump(&m, &a)
	walktest.expect_nil(t, err)
	back: Account
	walktest.expect_nil(t, model.load(&m, text, &back))
	again, _ := model.dump(&m, &back)
	testing.expect_value(t, string(again), string(text))
	testing.expect_value(t, back.nick.?, "n")
	testing.expect_value(t, back.home.zip.?, 5)
}

@(private = "file")
Disc :: struct {
	r: f64,
}

@(private = "file")
Box :: struct {
	side: f64,
}

@(private = "file")
Figure :: union {
	Disc,
	Box,
}

@(private = "file")
Milli :: distinct i64

@(private = "file")
Stamp :: struct {
	at:    time.Time,
	id:    uuid.Identifier,
	cost:  Milli,
	shape: Figure,
	spare: Figure `model:"optional"`,
}

@(test)
a_dump_writes_carriers_and_tagged_unions_as_a_load_reads_them :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	model.register_naming(&reg, {union_tag = "type"})
	model.register(&reg, model.Union_Rule{type = Figure, tag = "kind"})
	model.register(&reg, model.Custom(Milli, f64){
		proc(c: ^f64, out: ^Milli, allocator: runtime.Allocator) -> core.Typed_Error_Kind {
			out^ = Milli(c^ * 1000)
			return .None
		},
		proc(v: ^Milli, allocator: runtime.Allocator) -> (f64, core.Typed_Error_Kind) {
			return f64(v^) / 1000, .None
		},
	})
	m, compiled := model.compile(&reg, Stamp, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	id, _ := uuid.read("0f8fad5b-d9cb-469f-a165-70867728950e")
	s := Stamp{at = time.unix(1577836800, 0), id = id, cost = 1500, shape = Box{2}}
	text, err := model.dump(&m, &s, {exclude_none = true, check = true})
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), `{"at":"2020-01-01T00:00:00Z","id":"0f8fad5b-d9cb-469f-a165-70867728950e","cost":1.5,"shape":{"kind":"Box","side":2}}`)
	back: Stamp
	walktest.expect_nil(t, model.load(&m, text, &back))
	testing.expect(t, back.at == s.at && back.id == s.id && back.cost == 1500 && back.shape.(Box).side == 2 && back.spare == nil)
	s.spare = Disc{1}
	text, err = model.dump(&m, &s, {exclude_none = true})
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), `{"at":"2020-01-01T00:00:00Z","id":"0f8fad5b-d9cb-469f-a165-70867728950e","cost":1.5,"shape":{"kind":"Box","side":2},"spare":{"kind":"Disc","r":1}}`)
}

@(test)
a_patch_reads_no_default_and_misses_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m := account_model(&reg)
	existing: Account
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name": "ada", "nick": null, "level": 2}`), &existing))
	walktest.expect_nil(t, model.patch(&m, &existing, transmute([]u8)string(`{"home": {"zip": 3}}`)))
	testing.expect_value(t, existing.level, 2)
	testing.expect_value(t, existing.home.zip.?, 3)
	testing.expectf(t, model.was_set(&m, Account, existing.set, "name") && model.was_set(&m, Account, existing.set, "home"), "%v", existing.set)
	sink: typed.Sink
	testing.expect(t, model.patch(&m, &existing, transmute([]u8)string(`{"name": "a"}`), &sink) != nil)
	testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Too_Short)
	testing.expect_value(t, existing.name, "ada")

	// The elements of a list replace the list whole, so a patch reads them in full.
	l, _ := model.compile(&reg, Listed, json.checks(.Json))
	v: Listed
	testing.expect(t, model.patch(&l, &v, transmute([]u8)string(`{"items": [{"x": 1}]}`)) != nil)
	walktest.expect_nil(t, model.patch(&l, &v, transmute([]u8)string(`{}`)))
}

@(private = "file")
Pair :: struct {
	x, y: int,
}

@(private = "file")
Listed :: struct {
	items: []Pair,
	set:   model.Fields_Set,
}

@(private = "file")
Inner8 :: struct {
	a, b, c, d, e, f, g, h: int `stury:",omitempty"`,
}

@(private = "file")
Facts :: struct {
	v:     any `model:"optional"`,
	w:     f64,
	tags:  []string,
	set:   model.Fields_Set,
}

@(private = "file")
made_tags: int

@(test)
a_dump_judges_only_its_models_members_and_makes_each_default_once :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	model.register(&reg, Facts, "w", -0.0)
	model.register(&reg, Facts, "tags", proc(allocator: runtime.Allocator) -> []string {
		made_tags += 1
		return {}
	})
	m, err := model.compile(&reg, []Facts, json.checks(.Json))
	walktest.expect_nil(t, err)
	// An `any`'s members are a side plan's, which the model's facts do not describe.
	all := model.Fields_Set{bits = {7, 0}}
	fs := []Facts{{v = Inner8{1, 2, 3, 4, 5, 6, 7, 8}, w = 0.0, set = all}, {w = -0.0, tags = {"t"}, set = all}, {w = 1, set = all}}
	text: []u8
	text, err = model.dump(&m, &fs, {exclude_unset = true, exclude_defaults = true})
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), `[{"v":{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6,"g":7,"h":8},"w":0},{"tags":["t"]},{"w":1}]`)
	testing.expect_value(t, made_tags, 1)
}

@(test)
a_patch_takes_the_members_it_holds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m := account_model(&reg)
	existing: Account
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name": "ada", "nick": "a", "tags": ["x"], "home": {"city": "c", "zip": 1}, "aa": 1, "zz": 2}`), &existing))
	before := existing
	walktest.expect_nil(t, model.patch(&m, &existing, transmute([]u8)string(`{"nick": null, "tags": ["p", "q"], "home": {"zip": 2}, "level": 4, "zz": "patched"}`)))
	testing.expect_value(t, existing.name, "ada")
	_, has_nick := existing.nick.?
	testing.expect(t, !has_nick)
	testing.expect(t, len(existing.tags) == 2 && existing.tags[1] == "q")
	testing.expect_value(t, existing.home.city, "c")
	testing.expect_value(t, existing.home.zip.?, 2)
	testing.expect_value(t, existing.level, 4)
	testing.expect(t, model.was_set(&m, Account, existing.set, "level") && model.was_set(&m, Account, existing.set, "name"))
	testing.expect_value(t, len(existing.extra), 2)
	text, _ := model.dump(&m, &existing, {exclude_none = true})
	testing.expect_value(t, string(text), `{"id":0,"name":"ada","level":4,"tags":["p","q"],"home":{"city":"c","zip":2},"aa":1,"zz":"patched"}`)
	// The value the patch replaced keeps its own memory, its captured map among it.
	testing.expect(t, len(before.tags) == 1 && len(before.extra) == 2 && before.nick.? == "a")
	_, kept := before.extra["zz"]
	testing.expect(t, kept)

	other, _ := model.compile(nil, []int, json.checks(.Json))
	xs: []int
	testing.expect(t, model.patch(&other, &xs, transmute([]u8)string(`[1]`)) != nil)
}

@(private = "file")
Range :: struct {
	lo, hi: i64,
	name:   string `model:"len>=2"`,
	set:    model.Fields_Set,
}

@(private = "file")
ordered :: proc(v: Range, r: ^model.Report) {
	if v.lo > v.hi {
		model.fail(r, "lo > hi")
	}
}

// A struct's validators judge the merged value, never the patch alone, and a refused patch leaves the value as it was.
@(test)
a_patch_judges_the_struct_it_makes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	model.register(&reg, Range, ordered)
	m, err := model.compile(&reg, Range, json.checks(.Json))
	walktest.expect_nil(t, err)
	r: Range
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"lo": 1, "hi": 9, "name": "ab"}`), &r))
	walktest.expect_nil(t, model.patch(&m, &r, transmute([]u8)string(`{"lo": 5}`)))
	testing.expect(t, r.lo == 5 && r.hi == 9)
	sink: typed.Sink
	err = model.patch(&m, &r, transmute([]u8)string(`{"lo": 20}`), &sink)
	f, failed := err.(core.Typed_Error)
	testing.expect(t, failed && f.kind == .Custom && f.want.text == "lo > hi")
	testing.expect(t, len(sink.entries) == 1 && len(sink.entries[0].path) == 0)
	testing.expect(t, r.lo == 5 && r.hi == 9)
	walktest.expect_nil(t, model.validate(&m, &r))
}

@(test)
a_problem_document_is_written_by_marshal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m := account_model(&reg)
	sink: typed.Sink
	a: Account
	_ = model.load(&m, transmute([]u8)string(`{"name": "a", "level": "x"}`), &a, &sink)
	p, err := model.problem(sink.entries[:], "Invalid body", 422)
	testing.expect(t, err == nil)
	text, _ := json.marshal(p, allocator = context.temp_allocator)
	testing.expect_value(t, string(text), `{"title":"Invalid body","status":422,"errors":[{"pointer":"/name","code":"too_short","message":"String is too short"},{"pointer":"/level","code":"wrong_kind","message":"Value does not fit the field's type"},{"pointer":"/nick","code":"missing_field","message":"Required field is missing"}]}`)
}
