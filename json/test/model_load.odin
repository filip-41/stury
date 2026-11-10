package json_tests

import "base:runtime"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import schema "../../core/schema"
import json ".."
import model "../../core/model"
import walktest "../../walktest"

@(private = "file")
Profile :: struct {
	id:     i64 `model:"read_only"`,
	name:   string `model:"len>=2,pattern=^[a-z]+$"`,
	age:    u8 `model:">=18,<130"`,
	nick:   string `model:"len<=3"`,
	secret: string `model:"write_only,optional"`,
	level:  int,
	tags:   []string,
	extra:  map[string]core.Value `model:"extra"`,
	set:    model.Fields_Set,
}

@(private = "file")
profile_registry :: proc(reg: ^model.Registry) {
	model.register(reg, Profile, "level", 7)
	model.register(reg, Profile, "tags", []string{"new"})
	model.register(reg, Profile, "nick", "anon")
}

@(private = "file")
kinds_of :: proc(sink: ^typed.Sink) -> (kinds: [dynamic]core.Typed_Error_Kind) {
	kinds.allocator = context.temp_allocator
	for e in sink.entries {
		append(&kinds, e.kind)
	}
	return
}

@(test)
a_load_reports_every_failing_rule_of_a_member :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	profile_registry(&reg)
	m, compiled := model.compile(&reg, Profile, json.reads(.Json))
	walktest.expect_nil(t, compiled)
	sink: typed.Sink
	p: Profile
	err := model.load(&m, transmute([]u8)string(`{"name": "A", "age": 10, "nick": "toolong"}`), &p, &sink)
	testing.expect(t, err != nil)
	got := kinds_of(&sink)
	want := [?]core.Typed_Error_Kind{.Too_Short, .No_Match, .Below_Minimum, .Too_Long}
	testing.expect_value(t, len(got), len(want))
	for k, i in want {
		testing.expectf(t, i < len(got) && got[i] == k, "%d: want %v", i, k)
	}
}

@(test)
a_load_gives_absent_members_their_defaults_and_records_what_it_read :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	profile_registry(&reg)
	m, _ := model.compile(&reg, Profile, json.reads(.Json))
	first, second: Profile
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name": "ada", "age": 30}`), &first))
	testing.expect_value(t, first.level, 7)
	testing.expect_value(t, first.nick, "anon")
	testing.expect_value(t, len(first.tags), 1)
	testing.expect(t, model.was_set(&m, Profile, first.set, "name") && model.was_set(&m, Profile, first.set, "age"))
	testing.expect(t, !model.was_set(&m, Profile, first.set, "level") && !model.was_set(&m, Profile, first.set, "tags") && !model.was_set(&m, Profile, first.set, "id"))
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name": "bob", "age": 31, "level": 0, "tags": []}`), &second))
	testing.expect_value(t, second.level, 0)
	testing.expect_value(t, len(second.tags), 0)
	testing.expect(t, model.was_set(&m, Profile, second.set, "level") && model.was_set(&m, Profile, second.set, "tags"))
	testing.expect(t, raw_data(first.tags) != raw_data(second.tags))
	first.tags[0] = "changed"
	third: Profile
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name": "cy", "age": 40}`), &third))
	testing.expect_value(t, third.tags[0], "new")
}

@(test)
a_load_refuses_a_repeated_key_where_the_read_does :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	profile_registry(&reg)
	m, _ := model.compile(&reg, Profile, json.reads(.Json))
	repeats := [?]string {
		`{"name": "ada", "age": 30, "name": "bob"}`,
		`{"name": "ada", "age": 30, "age": 31}`,
		`{"age": 30, "name": "ada", "age": 31}`,
		`{"name": "ada", "age": 30, "x": 1, "x": 2}`,
		`{"name": "ada", "age": 30, "level": 1, "tags": [], "level": 2}`,
	}
	for text in repeats {
		p: Profile
		sink: typed.Sink
		err := model.load(&m, transmute([]u8)text, &p, &sink)
		testing.expectf(t, err != nil && len(sink.entries) > 0 && sink.entries[0].kind == .Duplicate_Key, "%s: %v", text, err)
	}
	p: Profile
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name": "ada", "age": 30, "age": 31}`), &p, nil, {dups = .Last}))
	testing.expect_value(t, p.age, 31)
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name": "ada", "age": 30, "age": 31}`), &p, nil, {dups = .First}))
	testing.expect_value(t, p.age, 30)
}

@(test)
a_load_follows_the_roles_of_its_members :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	profile_registry(&reg)
	m, _ := model.compile(&reg, Profile, json.reads(.Json))
	p: Profile
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"id": 5, "name": "ada", "age": 30, "secret": "s"}`), &p))
	testing.expect_value(t, p.id, 0)
	testing.expect_value(t, p.secret, "s")
	// The plan that holds every member is not a way to read around them.
	bad: Profile
	testing.expect(t, typed.unmarshal_text(transmute([]u8)string(`{"id": 5}`), &bad, Profile, &m.plan, {}) != nil)
	testing.expect_value(t, bad.id, 0)
}

@(test)
a_load_takes_or_refuses_the_members_a_struct_does_not_name :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	profile_registry(&reg)
	m, _ := model.compile(&reg, Profile, json.reads(.Json))
	p: Profile
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"name": "ada", "age": 30, "zip": 9, "city": "x"}`), &p))
	testing.expect_value(t, len(p.extra), 2)
	Strict :: struct {
		a: int,
	}
	model.register(&reg, Strict, model.Extra.Forbid)
	s, _ := model.compile(&reg, Strict, json.reads(.Json))
	v: Strict
	sink: typed.Sink
	testing.expect(t, model.load(&s, transmute([]u8)string(`{"a": 1, "b": 2}`), &v, &sink) != nil)
	testing.expect_value(t, sink.entries[0].kind, core.Typed_Error_Kind.Unknown_Field)
	walktest.expect_nil(t, model.load(&s, transmute([]u8)string(`{"a": 1}`), &v))
	Loose :: struct {
		a: int,
	}
	l, _ := model.compile(&reg, Loose, json.reads(.Json))
	lv: Loose
	walktest.expect_nil(t, model.load(&l, transmute([]u8)string(`{"a": 1, "b": 2}`), &lv))
	testing.expect(t, model.load(&l, transmute([]u8)string(`{"a": 1, "b": 2, "b": 3}`), &lv, &sink) != nil)
}

@(private = "file")
Counted :: struct {
	list:  []int `model:"len=1..=2,optional"`,
	fixed: [3]int `model:"len>=1,optional"`,
	bag:   map[string]int `model:"len<=1,optional"`,
	name:  cstring `model:"len>=2,optional"`,
}

// `validate(v)`, the load of `marshal(v)`, its Load schema and its Dump schema agree that `v` is `valid`.
@(private = "file")
four_way :: proc(t: ^testing.T, v: $T, valid: bool, loc := #caller_location) {
	reg: model.Registry
	m, _ := model.compile(&reg, T, json.reads(.Json), context.temp_allocator)
	v := v
	validated := model.validate(&m, &v) == nil
	text, _ := write.marshal(v, &m.plan, allocator = context.temp_allocator)
	back: T
	loaded := model.load(&m, text, &back, nil, {dups = .Refuse}, context.temp_allocator) == nil
	checks: [model.Direction]bool
	for direction in model.Direction {
		d, _ := model.schema(&m, direction, context.temp_allocator)
		c := schema.compile_description(&d, allocator = context.temp_allocator)
		b, _ := schema.bind(&c, json.as(.Json), allocator = context.temp_allocator)
		checks[direction] = schema.valid(&b, text)
	}
	testing.expectf(t, validated == valid && loaded == valid && checks[.Load] == valid && checks[.Dump] == valid, "%s: validate %v, load %v, schemas %v", text, validated, loaded, checks, loc = loc)
}

@(private = "file")
bag_of :: proc(n: int) -> (bag: map[string]int) {
	bag = make(map[string]int, context.temp_allocator)
	names := [?]string{"a", "b", "c"}
	for k in names[:n] {
		bag[k] = 1
	}
	return
}

@(test)
a_count_is_judged_the_same_by_validate_load_and_both_schemas :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	four_way(t, Counted{name = "ab"}, false)
	four_way(t, Counted{list = {1}, fixed = {1, 0, 0}, name = "ab"}, true)
	four_way(t, Counted{list = {1, 2, 3}, fixed = {1, 0, 0}, name = "ab"}, false)
	four_way(t, Counted{list = {}, fixed = {1, 0, 0}, name = "ab"}, false)
	four_way(t, Counted{list = {1}, fixed = {1, 0, 0}, bag = bag_of(2), name = "ab"}, false)
	four_way(t, Counted{list = {1}, fixed = {1, 0, 0}, name = "ab"}, true)
	four_way(t, Counted{list = {1}, fixed = {1, 0, 0}, name = "a"}, false)
}

@(private = "file")
Scalars :: struct {
	name: string `model:"len=2..=4,pattern=^[a-z]+$"`,
	age:  u8 `model:">=18,<130"`,
	step: i32 `model:"multiple_of=5"`,
	rate: f64 `model:">0,<=1"`,
	mail: string `model:"format=email"`,
}

@(test)
a_scalar_rule_is_judged_the_same_by_validate_load_and_both_schemas :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	good := Scalars{"abc", 30, 10, 0.5, "a@b.org"}
	four_way(t, good, true)
	for i in 0 ..< 5 {
		bad := good
		switch i {
		case 0:
			bad.name = "Abc"
		case 1:
			bad.age = 17
		case 2:
			bad.step = 7
		case 3:
			bad.rate = 0
		case 4:
			bad.mail = "nope"
		}
		four_way(t, bad, false)
	}
	short := good
	short.name = "a"
	four_way(t, short, false)
	four_way(t, Scalars{"abc", 129, -5, 1, "a@b.org"}, true)
}

@(private = "file")
Price :: struct {
	currency: string `model:"pattern=^[a-z]+$"`,
	amount:   string `model:"alias=#text,len<=0,optional"`,
}

@(private = "file")
Item :: struct {
	id:   string `model:"pattern=^[a-z]+$"`,
	name: string `model:"len>=3"`,
	note: string `model:"optional"`,
}

// The load of a markup element gives the errors of the load of its JSON form: attributes and the element's text as
// members of its struct.
@(test)
a_load_reads_markup_as_it_reads_its_json_form :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	readers := json.as(.Json).readers^
	readers.attribute = markup_attribute
	reg: model.Registry
	prices, _ := model.compile(&reg, struct{ price: Price }, json.reads(.Json))
	items, _ := model.compile(&reg, struct{ a: Item }, json.reads(.Json))
	cases := [?]struct {
		is_price:   bool,
		model, form: string,
		attributes: []Markup_Attribute,
		errors:     int,
	} {
		// <price currency="EUR">5</price>
		{true, `{"price": "5"}`, `{"price": {"currency": "EUR", "#text": "5"}}`, {{2, `currency="EUR"`}}, 2},
		// <price currency="eur"/>
		{true, `{"price": ""}`, `{"price": {"currency": "eur"}}`, {{2, `currency="eur"`}}, 0},
		// <a id="x7" name="ab"/>
		{false, `{"a": ""}`, `{"a": {"id": "x7", "name": "ab"}}`, {{2, `id="x7"`}, {2, `name="ab"`}}, 2},
		// <a id="x"><name>abc</name></a>
		{false, `{"a": {"name": "abc"}}`, `{"a": {"id": "x", "name": "abc"}}`, {{2, `id="x"`}}, 0},
		// <a><name>ab</name><note>n</note></a>, no id
		{false, `{"a": {"name": "ab", "note": "n"}}`, `{"a": {"name": "ab", "note": "n"}}`, nil, 2},
	}
	for c in cases {
		doc := markup_doc(c.model, c.attributes, &readers)
		defer core.destroy(&doc)
		from_doc, from_form: typed.Sink
		defer typed.sink_destroy(&from_doc)
		defer typed.sink_destroy(&from_form)
		if c.is_price {
			v: struct{ price: Price }
			typed.check_document(&doc, core.ROOT, &v, type_of(v), &prices.load_plan, {dups = .Last, sink = &from_doc})
			w: struct{ price: Price }
			model.load(&prices, transmute([]u8)c.form, &w, &from_form)
		} else {
			v: struct{ a: Item }
			typed.check_document(&doc, core.ROOT, &v, type_of(v), &items.load_plan, {dups = .Last, sink = &from_doc})
			w: struct{ a: Item }
			model.load(&items, transmute([]u8)c.form, &w, &from_form)
		}
		testing.expectf(t, len(from_form.entries) == c.errors && len(from_doc.entries) == c.errors, "%s: markup %d, json %d, want %d", c.model, len(from_doc.entries), len(from_form.entries), c.errors)
		for e, i in from_doc.entries[:min(len(from_doc.entries), len(from_form.entries))] {
			testing.expectf(t, e.kind == from_form.entries[i].kind, "%s %d: %v against %v", c.model, i, e.kind, from_form.entries[i].kind)
		}
	}
}

@(private = "file")
Roles :: struct {
	id:    i64 `model:"read_only"`,
	name:  string,
	extra: map[string]core.Value `model:"extra"`,
}

@(private = "file")
Fenced :: struct {
	id:   i64 `model:"read_only"`,
	name: string,
}

@(private = "file")
mismatch :: proc(err: core.Error) -> bool {
	f, ok := err.(core.Typed_Error)
	return ok && f.kind == .Plan_Mismatch
}

@(test)
a_models_plans_read_only_as_its_load :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, _ := model.compile(&reg, Fenced, json.reads(.Json))
	text := transmute([]u8)string(`{"id": 5, "name": "a"}`)
	for plan in ([?]^typed.Plan{&m.plan, &m.load_plan}) {
		v: Fenced
		testing.expect(t, mismatch(json.unmarshal(text, .Json, &v, plan)))
		testing.expect_value(t, v.id, 0)
	}
	v := Fenced{id = 3}
	testing.expect(t, mismatch(json.check(text, .Json, &v, &m.plan)))
	walktest.expect_nil(t, json.check(text, .Json, &v, &m.load_plan))
	testing.expect_value(t, v.id, 0)
	testing.expect_value(t, v.name, "a")
}

@(test)
a_default_names_a_member_of_its_type :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	Two :: struct {
		a: int,
		b: int `model:"optional"`,
		c: []int `model:"optional"`,
	}
	reg: model.Registry
	defer model.destroy(&reg)
	testing.expect_value(t, model.register(&reg, Two, "nope", 1), runtime.Allocator_Error.Invalid_Argument)
	testing.expect_value(t, model.register(&reg, Two, "b", "s"), runtime.Allocator_Error.Invalid_Argument)
	testing.expect_value(t, model.register(&reg, Two, "nope", proc(allocator: runtime.Allocator) -> int {return 1}), runtime.Allocator_Error.Invalid_Argument)
	made := model.register(&reg, Two, "c", proc(allocator: runtime.Allocator) -> []int {
		return make([]int, 2, allocator)
	})
	testing.expect_value(t, made, runtime.Allocator_Error.None)
	m, _ := model.compile(&reg, Two, json.reads(.Json))
	v: Two
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"a": 1}`), &v))
	testing.expect_value(t, len(v.c), 2)
}

@(test)
a_load_captures_into_a_map_of_values_by_the_repeat_policy :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, _ := model.compile(&reg, Roles, json.reads(.Json))
	text := transmute([]u8)string(`{"name": "a", "z": 1, "z": [2]}`)
	first, last: Roles
	walktest.expect_nil(t, model.load(&m, text, &first, nil, {dups = .First}))
	walktest.expect_nil(t, model.load(&m, text, &last, nil, {dups = .Last}))
	z, z_last := first.extra["z"], last.extra["z"]
	testing.expect(t, len(first.extra) == 1 && core.value_kind(z) == .Number, "first keeps the first")
	testing.expect(t, len(last.extra) == 1 && core.value_kind(z_last) == .Array, "last keeps the last")
	testing.expect(t, model.load(&m, text, &first) != nil)
}

@(test)
a_load_refuses_a_repeat_inside_a_value_it_does_not_type :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	Held :: struct {
		v: core.Value,
		n: int,
	}
	reg: model.Registry
	m, _ := model.compile(&reg, Held, json.reads(.Json))
	for text in ([?]string{`{"v": {"a": 1, "a": 2}, "n": 0}`, `{"n": 0, "q": {"a": 1, "a": 2}}`}) {
		h: Held
		f, ok := model.load(&m, transmute([]u8)text, &h).(core.Fault)
		testing.expectf(t, ok && f.kind == .Duplicate_Key, "%s", text)
	}
}

@(test)
a_null_cstring_is_judged_the_same_by_validate_load_and_both_schemas :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	four_way(t, Counted{list = {1}, fixed = {1, 0, 0}}, true)
}

@(test)
a_read_only_key_never_lands_in_the_members_a_struct_does_not_name :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, _ := model.compile(&reg, Roles, json.reads(.Json))
	text := transmute([]u8)string(`{"id": 5, "name": "a", "q": 1}`)
	r: Roles
	walktest.expect_nil(t, model.load(&m, text, &r))
	_, held := r.extra["id"]
	testing.expect(t, r.id == 0 && len(r.extra) == 1 && !held)
	model.register(&reg, Fenced, model.Extra.Forbid)
	f, _ := model.compile(&reg, Fenced, json.reads(.Json))
	sink: typed.Sink
	v: Fenced
	testing.expect(t, model.load(&f, transmute([]u8)string(`{"id": 5, "name": "a"}`), &v, &sink) != nil)
	testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Read_Only)
	d, _ := model.schema(&f, .Load)
	c := schema.compile_description(&d)
	b, _ := schema.bind(&c, json.as(.Json))
	testing.expect(t, !schema.valid(&b, transmute([]u8)string(`{"id": 5, "name": "a"}`)))
	testing.expect(t, schema.valid(&b, transmute([]u8)string(`{"name": "a"}`)))
	model.register(&reg, Fenced, model.Extra.Ignore)
	l, _ := model.compile(&reg, Fenced, json.reads(.Json))
	walktest.expect_nil(t, model.load(&l, transmute([]u8)string(`{"id": 5, "name": "a", "q": 1}`), &v))
}

@(test)
a_model_refuses_what_it_cannot_load_at_compile :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	model.register(&reg, Roles, model.Extra.Forbid)
	_, forbidden := model.compile(&reg, Roles, json.reads(.Json))
	f, ok := forbidden.(core.Typed_Error)
	testing.expect(t, ok && f.kind == .Bad_Tag)
	_, wide := model.compile(&reg, Wide, json.reads(.Json))
	w, wide_ok := wide.(core.Typed_Error)
	testing.expect(t, wide_ok && w.kind == .Bad_Tag)
}

@(private = "file")
Inner :: struct {
	x:   int,
	y:   int,
	set: model.Fields_Set,
}

@(private = "file")
Outer :: struct {
	inner: Inner,
	set:   model.Fields_Set,
}

@(test)
was_set_asks_the_struct_that_holds_the_set :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, _ := model.compile(&reg, Outer, json.reads(.Json))
	o: Outer
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"inner": {"y": 2, "x": 1}}`), &o))
	testing.expect(t, model.was_set(&m, Inner, o.inner.set, "x") && model.was_set(&m, Outer, o.set, "inner"))
	testing.expect(t, !model.was_set(&m, Inner, o.inner.set, "nope"))
}

@(private = "file")
Arm_A :: struct {
	a: int,
}

@(private = "file")
Arm_B :: struct {
	b: string,
}

@(test)
a_model_loads_a_union_of_structs_by_its_naming_tag :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	Holds :: struct {
		u: union {
			Arm_A,
			Arm_B,
		},
	}
	reg := model.Registry {
		naming = {union_tag = "type"},
	}
	m, compiled := model.compile(&reg, Holds, json.reads(.Json))
	walktest.expect_nil(t, compiled)
	h: Holds
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string(`{"u": {"type": "Arm_B", "b": "x"}}`), &h))
	b, ok := h.u.(Arm_B)
	testing.expect(t, ok && b.b == "x")
}

@(private = "file")
Wide :: struct {
	m0: int,
	m1: int,
	m2: int,
	m3: int,
	m4: int,
	m5: int,
	m6: int,
	m7: int,
	m8: int,
	m9: int,
	m10: int,
	m11: int,
	m12: int,
	m13: int,
	m14: int,
	m15: int,
	m16: int,
	m17: int,
	m18: int,
	m19: int,
	m20: int,
	m21: int,
	m22: int,
	m23: int,
	m24: int,
	m25: int,
	m26: int,
	m27: int,
	m28: int,
	m29: int,
	m30: int,
	m31: int,
	m32: int,
	m33: int,
	m34: int,
	m35: int,
	m36: int,
	m37: int,
	m38: int,
	m39: int,
	m40: int,
	m41: int,
	m42: int,
	m43: int,
	m44: int,
	m45: int,
	m46: int,
	m47: int,
	m48: int,
	m49: int,
	m50: int,
	m51: int,
	m52: int,
	m53: int,
	m54: int,
	m55: int,
	m56: int,
	m57: int,
	m58: int,
	m59: int,
	m60: int,
	m61: int,
	m62: int,
	m63: int,
	m64: int,
	m65: int,
	m66: int,
	m67: int,
	m68: int,
	m69: int,
	m70: int,
	m71: int,
	m72: int,
	m73: int,
	m74: int,
	m75: int,
	m76: int,
	m77: int,
	m78: int,
	m79: int,
	m80: int,
	m81: int,
	m82: int,
	m83: int,
	m84: int,
	m85: int,
	m86: int,
	m87: int,
	m88: int,
	m89: int,
	m90: int,
	m91: int,
	m92: int,
	m93: int,
	m94: int,
	m95: int,
	m96: int,
	m97: int,
	m98: int,
	m99: int,
	m100: int,
	m101: int,
	m102: int,
	m103: int,
	m104: int,
	m105: int,
	m106: int,
	m107: int,
	m108: int,
	m109: int,
	m110: int,
	m111: int,
	m112: int,
	m113: int,
	m114: int,
	m115: int,
	m116: int,
	m117: int,
	m118: int,
	m119: int,
	m120: int,
	m121: int,
	m122: int,
	m123: int,
	m124: int,
	m125: int,
	m126: int,
	m127: int,
	m128: int,
	set: model.Fields_Set,
}
