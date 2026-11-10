package core_test

import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"
import core ".."
import typed "../typed"
import dsv "../../dsv"
import json "../../json"
import model "../model"
import walktest "../../walktest"

@(private = "file")
Person :: struct {
	name: string `model:"len>=1"`,
	age:  int `model:">=0"`,
	tags: []string `model:"optional"`,
}

@(private = "file")
Flat :: struct {
	name: string `model:"len>=1"`,
	age:  int `model:">=0"`,
}

@(private = "file")
trimmed :: proc(v: core.Value, r: ^model.Report) -> core.Value {
	if s, is_text := v.(string); is_text {
		return strings.trim_space(s)
	}
	return v
}

// A number spelled as text becomes a number, which the member's type then reads.
@(private = "file")
counted :: proc(v: core.Value, r: ^model.Report) -> core.Value {
	if s, is_text := v.(string); is_text {
		if n, ok := strconv.parse_f64(s); ok {
			return n
		}
	}
	return v
}

@(private = "file")
no_forbidden :: proc(v: core.Value, r: ^model.Report) -> core.Value {
	if s, is_text := v.(string); is_text && s == "root" {
		model.fail(r, "no root")
	}
	return v
}

@(private = "file")
unchanged :: proc(v: core.Value, r: ^model.Report) -> core.Value {
	return v
}

@(private = "file")
named :: proc(t: ^testing.T, reg: ^model.Registry, reads: ^typed.Format_Reads, $T: typeid, $E: typeid) -> model.Model(T) {
	_ = model.register(reg, E, "name", trimmed)
	_ = model.register(reg, E, "age", counted)
	m, err := model.compile(reg, T, reads)
	walktest.expect_nil(t, err)
	return m
}

@(private = "file")
loaded_person :: proc(m: ^model.Model(Person), text: string) -> (v: Person, found: string) {
	sink: typed.Sink
	_ = model.load(m, transmute([]u8)text, &v, &sink)
	return v, spelled(&sink)
}

@(test)
before_rewrites_a_json_member_before_it_is_read :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	_ = model.register(&reg, Person, "tags", unchanged)
	m := named(t, &reg, json.reads(.Json), Person, Person)
	v, found := loaded_person(&m, `{"name":"  ada ","age":"42","tags":["a","b"]}`)
	testing.expect_value(t, found, "")
	testing.expect_value(t, v.name, "ada")
	testing.expect_value(t, v.age, 42)
	testing.expect_value(t, len(v.tags), 2)
	// The replacement is judged as the text would have been: by the type, and then by the rules.
	_, found = loaded_person(&m, `{"name":"   ","age":1}`)
	testing.expect_value(t, found, "Too_Short/name;")
	_, found = loaded_person(&m, `{"name":"ada","age":"x"}`)
	testing.expect_value(t, found, "Wrong_Kind/age;")
	_, found = loaded_person(&m, `{"name":"ada","age":"-3"}`)
	testing.expect_value(t, found, "Below_Minimum/age;")
	// A container is judged under the member's path.
	_, found = loaded_person(&m, `{"name":"ada","age":1,"tags":["a",1]}`)
	testing.expect_value(t, found, "Wrong_Kind/tags/1;")
}

// A member's built value, the replacement and its text are given back, so a load leaves only what it stores.
@(test)
before_gives_back_what_it_builds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	reg: model.Registry
	_ = model.register(&reg, Person, "tags", unchanged)
	m := named(t, &reg, json.reads(.Json), Person, Person)
	defer model.registry_destroy(&reg)
	defer model.model_destroy(&m)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	text := `{"name":"  ada ","age":"42","tags":["a","b"]}`
	base := len(track.allocation_map)
	grown: [2]int
	for i in 0 ..< 2 {
		v: Person
		testing.expect(t, model.load(&m, transmute([]u8)text, &v) == nil)
		grown[i] = len(track.allocation_map) - base
		for tag in v.tags {
			delete(tag)
		}
		delete(v.tags)
		delete(v.name)
		testing.expect_value(t, len(track.allocation_map), base)
	}
	testing.expect_value(t, grown[0], grown[1])
}

@(test)
before_failures_are_the_members :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	_ = model.register(&reg, Person, "name", no_forbidden)
	m, err := model.compile(&reg, Person, json.reads(.Json))
	walktest.expect_nil(t, err)
	_, found := loaded_person(&m, `{"name":"root","age":1}`)
	testing.expect_value(t, found, "Custom(no root)/name;")
	v: Person
	failure := model.load(&m, transmute([]u8)string(`{"name":"root","age":1}`), &v)
	typed_error, is_typed := failure.(core.Typed_Error)
	testing.expect(t, is_typed && typed_error.kind == .Custom)
}

@(private = "file")
Short :: struct {
	name: string `model:"len<=3"`,
}

@(private = "file")
widened :: proc(v: core.Value, r: ^model.Report) -> core.Value {
	return "abcdef"
}

@(test)
before_refusal_keeps_its_path_with_a_sink :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	_ = model.register(&reg, Short, "name", widened)
	m, err := model.compile(&reg, Short, json.reads(.Json))
	walktest.expect_nil(t, err)
	v: Short
	sink: typed.Sink
	failure := model.load(&m, transmute([]u8)string(`{"name":"a"}`), &v, &sink)
	typed_error, is_typed := failure.(core.Typed_Error)
	testing.expect(t, is_typed && typed_error.kind == .Too_Long)
	testing.expect_value(t, len(typed_error.steps), 1)
}

@(private = "file")
fails_a_part :: proc(v: core.Value, r: ^model.Report) -> core.Value {
	model.fail_at(r, "sub", "nope")
	return v
}

@(test)
before_failure_names_the_part_it_fails :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	_ = model.register(&reg, Person, "name", fails_a_part)
	m, err := model.compile(&reg, Person, json.reads(.Json))
	walktest.expect_nil(t, err)
	_, found := loaded_person(&m, `{"name":"x","age":1}`)
	testing.expect_value(t, found, "Custom(nope)/name/sub;")
}

@(test)
validate_judges_the_value_a_before_would_have_made :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	_ = model.register(&reg, Person, "tags", unchanged)
	m := named(t, &reg, json.reads(.Json), Person, Person)
	// `validate` judges a value already read, so a `before` has nothing to rewrite there.
	sink: typed.Sink
	_ = model.validate(&m, &Person{name = "ada", age = 4}, &sink)
	testing.expect_value(t, spelled(&sink), "")
	_ = model.validate(&m, &Person{name = "", age = -1}, &sink)
	testing.expect_value(t, spelled(&sink), "Too_Short/name;Below_Minimum/age;")
}

@(test)
before_rewrites_a_csv_cell_the_same_way :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m := named(t, &reg, dsv.checks(.Csv), []Flat, Flat)
	rows: []Flat
	sink: typed.Sink
	_ = model.load(&m, transmute([]u8)string("name,age\n  ada ,\"42\"\nbo,7\n"), &rows, &sink)
	testing.expect_value(t, spelled(&sink), "")
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[0].name, "ada")
	testing.expect_value(t, rows[0].age, 42)
	testing.expect_value(t, rows[1].age, 7)
	sink = {}
	_ = model.load(&m, transmute([]u8)string("name,age\nada,x\n   ,-3\n"), &rows, &sink)
	testing.expect_value(t, spelled(&sink), "Wrong_Kind/0/age;Too_Short/1/name;Below_Minimum/1/age;")
	// The entries name the cell's bytes.
	for e in sink.entries {
		testing.expect(t, e.end <= 22 && e.end > e.start)
	}
}
