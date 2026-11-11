package json_tests

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:encoding/uuid"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
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
	// A required member is written though it holds null, so the text loads back.
	testing.expect_value(t, dumped(t, &m, &a, {exclude_none = true}), `{"id":9,"name":"ada","level":7,"nick":null,"tags":[],"home":{"city":"x"},"aa":[2],"zz":1}`)
	// What the load took from a default or never read is unset, and the read_only member is kept.
	testing.expect_value(t, dumped(t, &m, &a, {exclude_unset = true}), `{"id":9,"name":"ada","nick":null,"home":{"city":"x"},"aa":[2],"zz":1}`)
	testing.expect_value(t, dumped(t, &m, &a, {exclude_defaults = true}), `{"id":9,"name":"ada","nick":null,"home":{"city":"x"},"aa":[2],"zz":1}`)
	testing.expect_value(t, dumped(t, &m, &a, {exclude_unset = true, exclude_none = true, exclude_defaults = true}), `{"id":9,"name":"ada","nick":null,"home":{"city":"x"},"aa":[2],"zz":1}`)
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
Stock :: struct {
	name:  string `model:"len>=2"`,
	qty:   int `model:">=0"`,
	note:  string `model:"optional"`,
	tags:  [dynamic]string `model:"optional"`,
	extra: map[string]string `json:",unknown"`,
	set:   model.Fields_Set,
}

// A patch frees what it read when it fails, and what it replaced when it succeeds, so a value it patched holds all the
// memory it was given.
@(test)
a_patch_frees_what_it_read_or_replaced :: proc(t: ^testing.T) {
	reg: model.Registry
	defer model.registry_destroy(&reg)
	m, compiled := model.compile(&reg, Stock, json.checks(.Json))
	walktest.expect_nil(t, compiled)
	defer model.model_destroy(&m)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)
	v: Stock
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name":"widget","qty":3,"tags":["x"],"a":"b","c":"d"}`), &v, allocator = a))
	held := len(track.allocation_map)
	failing := [?]string {
		`{"name":"longername","qty":-1,"tags":["y","z"],"e":"f"}`,
		`{"name":"longername","qty":`,
		`{"name":"x","a":"q"}`,
	}
	for body in failing {
		testing.expectf(t, model.patch(&m, &v, transmute([]u8)body, allocator = a) != nil, "%s", body)
		testing.expectf(t, len(track.allocation_map) == held, "%s: %d live, %d before", body, len(track.allocation_map), held)
	}
	testing.expect(t, v.name == "widget" && v.qty == 3 && len(v.tags) == 1 && v.extra["a"] == "b")
	walktest.expect_nil(t, model.patch(&m, &v, transmute([]u8)string(`{"name":"gadget","tags":["p","q"],"a":"z","e":"f"}`), allocator = a))
	testing.expect(t, v.name == "gadget" && v.qty == 3 && len(v.tags) == 2 && len(v.extra) == 3 && v.extra["a"] == "z" && v.extra["c"] == "d")
	delete(v.name, a)
	delete(v.note, a)
	for x in v.tags {
		delete(x, a)
	}
	delete(v.tags)
	for k, x in v.extra {
		delete(k, a)
		delete(x, a)
	}
	delete(v.extra)
	testing.expectf(t, len(track.allocation_map) == 0 && len(track.bad_free_array) == 0, "%d live, %d bad frees", len(track.allocation_map), len(track.bad_free_array))
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
	testing.expect_value(t, string(text), `{"id":0,"name":"ada","level":4,"nick":null,"tags":["p","q"],"home":{"city":"c","zip":2},"aa":1,"zz":"patched"}`)
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
	testing.expect_value(t, string(text), `{"title":"Invalid body","status":422,"errors":[{"pointer":"/name","code":"too_short","message":"String is too short, at least 2 characters"},{"pointer":"/level","code":"wrong_kind","message":"Value does not fit the field's type, expected int"},{"pointer":"/nick","code":"missing_field","message":"Required field is missing"}]}`)
}

@(private = "file")
Sized :: struct {
	x:   int,
	y:   int `model:"optional"`,
	set: model.Fields_Set,
}

@(private = "file")
Held :: struct {
	by_ptr:   ^Sized `model:"optional"`,
	by_maybe: Maybe(Sized) `model:"optional"`,
	set:      model.Fields_Set,
}

// A struct behind a pointer or a `Maybe` is read in full by a patch, so its required members are enforced.
@(test)
a_patch_reads_a_struct_behind_a_pointer_or_maybe_in_full :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, err := model.compile(&reg, Held, json.checks(.Json))
	walktest.expect_nil(t, err)
	v: Held
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"by_ptr": {"x": 1, "y": 2}, "by_maybe": {"x": 3, "y": 4}}`), &v))
	for body in ([]string{`{"by_ptr": {"y": 5}}`, `{"by_maybe": {"y": 5}}`}) {
		testing.expect_value(t, refused_as(model.patch(&m, &v, transmute([]u8)body)), core.Typed_Error_Kind.Missing_Field)
		testing.expect(t, v.by_ptr.x == 1 && v.by_ptr.y == 2 && v.by_maybe.?.x == 3 && v.by_maybe.?.y == 4)
	}
	walktest.expect_nil(t, model.patch(&m, &v, transmute([]u8)string(`{"by_ptr": {"x": 7}}`)))
	testing.expect(t, v.by_ptr.x == 7 && v.by_ptr.y == 0)
}

@(private = "file")
Tagged :: struct {
	tags: []string `model:"len>=1,unique"`,
}

// An error `validate` returns holds the names of its path, which a later allocation must not overwrite.
@(test)
validate_returns_a_path_that_outlives_the_applicator_judge :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// The region the judge opens in the temp allocator is given back unless the caller's allocator is that one.
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), runtime.Allocator_Error.None)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	reg: model.Registry
	m, err := model.compile(&reg, Tagged, json.checks(.Json))
	walktest.expect_nil(t, err)
	v := Tagged{[]string{"a", "a"}}
	failed := model.validate(&m, &v)
	e, typed_error := failed.(core.Typed_Error)
	testing.expect(t, typed_error && e.kind == .Not_Unique)
	junk := make([]u8, 4096, context.temp_allocator)
	for &b in junk {
		b = 0xAA
	}
	name, named := e.steps[0].(core.Name)
	testing.expect(t, named && string(name) == "tags")
}

@(private = "file")
Nullable :: struct {
	a: Maybe(string) `model:"not_null"`,
	p: int,
}

// `not_null` on a `Maybe` is judged by `validate` and by a dump's `check`, as a load of the dumped text judges it.
@(test)
not_null_on_a_maybe_is_judged_by_validate_and_dump :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, err := model.compile(&reg, Nullable, json.checks(.Json))
	walktest.expect_nil(t, err)
	v := Nullable{p = 1}
	testing.expect_value(t, refused_as(model.validate(&m, &v)), core.Typed_Error_Kind.Wrong_Kind)
	_, dumped := model.dump(&m, &v, {check = true})
	testing.expect_value(t, refused_as(dumped), core.Typed_Error_Kind.Check_Failed)
	v.a = "x"
	walktest.expect_nil(t, model.validate(&m, &v))
}

// `dump_stream` writes the text `dump` returns, and refuses what `check` refuses.
@(test)
dump_stream_writes_what_dump_returns :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m := account_model(&reg)
	a: Account
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name": "ada", "nick": null, "level": 2}`), &a))
	b := strings.builder_make()
	walktest.expect_nil(t, model.dump_stream(strings.to_stream(&b), &m, &a, {exclude_none = true}))
	text, _ := model.dump(&m, &a, {exclude_none = true})
	testing.expect_value(t, strings.to_string(b), string(text))
	testing.expect(t, len(text) > 0)
	bad := Account{name = "a"}
	b2 := strings.builder_make()
	testing.expect_value(t, refused_as(model.dump_stream(strings.to_stream(&b2), &m, &bad, {check = true})), core.Typed_Error_Kind.Check_Failed)
}

@(private = "file")
Counter :: struct {
	count: i32,
	ratio: f64,
	nick:  Maybe(string),
	name:  string,
	small: u8,
}

// A default may be a literal the member's number type holds exactly, or the type a `Maybe` member holds.
@(test)
a_default_converts_a_number_or_a_maybe_element :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	walktest.expect_nil(t, model.register(&reg, Counter, "count", 5))
	walktest.expect_nil(t, model.register(&reg, Counter, "ratio", 1))
	walktest.expect_nil(t, model.register(&reg, Counter, "nick", "x"))
	walktest.expect_nil(t, model.register(&reg, Counter, "small", 200))
	m, err := model.compile(&reg, Counter, json.checks(.Json))
	walktest.expect_nil(t, err)
	v: Counter
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name": "n"}`), &v))
	testing.expect(t, v.count == 5 && v.ratio == 1 && v.nick.? == "x" && v.small == 200)
	for refusal in ([]core.Error{
		model.register(&reg, Counter, "small", 300),
		model.register(&reg, Counter, "count", 1.5),
		model.register(&reg, Counter, "name", 5),
	}) {
		e, typed_error := refusal.(core.Typed_Error)
		testing.expect(t, typed_error && e.kind == .Wrong_Kind)
	}
	e := model.register(&reg, Counter, "name", 5).(core.Typed_Error)
	b := strings.builder_make()
	core.render(strings.to_writer(&b), nil, e)
	testing.expect(t, strings.contains(strings.to_string(b), "Expected string, found number"), strings.to_string(b))
}

// A failed rule's message says what the value should have been.
@(test)
a_message_says_what_to_fix :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m := account_model(&reg)
	sink: typed.Sink
	a: Account
	_ = model.load(&m, transmute([]u8)string(`{"name": "a", "level": "x"}`), &a, &sink)
	messages := make([dynamic]string)
	for e in sink.entries {
		append(&messages, write.report_message(e))
	}
	testing.expect_value(t, messages[0], "String is too short, at least 2 characters")
	testing.expect_value(t, messages[1], "Value does not fit the field's type, expected int")
	bad := Account{name = "a"}
	sink2: typed.Sink
	_ = model.validate(&m, &bad, &sink2)
	testing.expect_value(t, write.report_message(sink2.entries[0]), "String is too short, at least 2 characters")
}
