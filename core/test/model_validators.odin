package core_test

import "core:testing"
import core ".."
import typed "../typed"
import dsv "../../dsv"
import json "../../json"
import model "../model"
import walktest "../../walktest"

@(private = "file")
Pair :: struct {
	low, high: int,
}

@(private = "file")
Inner :: struct {
	n: int `model:">=0"`,
}

@(private = "file")
Outer :: struct {
	name:  string,
	pair:  Pair,
	inner: Inner,
}

@(private = "file")
name_not_empty :: proc(v: string, r: ^model.Report) {
	if v == "x" {
		model.fail(r, "no x")
		model.fail(r, "still no x")
	}
}

@(private = "file")
ordered :: proc(v: Pair, r: ^model.Report) {
	if v.low > v.high {
		model.fail_at(r, "high", "high below low")
	}
}

@(private = "file")
outer_named :: proc(v: Outer, r: ^model.Report) {
	if v.name == "bad" {
		model.fail(r, "bad outer")
	}
}

@(private = "file")
compiled :: proc(t: ^testing.T) -> (m: model.Model(Outer), reg: model.Registry) {
	_ = model.register(&reg, Outer, "name", name_not_empty)
	_ = model.register(&reg, Pair, ordered)
	_ = model.register(&reg, Outer, outer_named)
	err: core.Error
	m, err = model.compile(&reg, Outer, json.reads(.Json))
	walktest.expect_nil(t, err)
	return
}

@(private = "file")
both :: proc(t: ^testing.T, m: ^model.Model(Outer), text: string, want: string) {
	sink: typed.Sink
	v: Outer
	_ = model.load(m, transmute([]u8)text, &v, &sink)
	loaded := spelled(&sink)
	testing.expectf(t, loaded == want, "load %s: %q, want %q", text, loaded, want)
	sink2: typed.Sink
	_ = model.validate(m, &v, &sink2)
	// What validate sees is the loaded value, so a value the load refused is not compared.
	if want == "" || loaded == want && !has_kind(&sink, .Wrong_Kind) && !has_kind(&sink, .Below_Minimum) {
		validated := spelled(&sink2)
		testing.expectf(t, validated == want, "validate %s: %q, want %q", text, validated, want)
	}
}

@(private = "file")
has_kind :: proc(s: ^typed.Sink, k: core.Typed_Error_Kind) -> bool {
	for e in s.entries {
		if e.kind == k {
			return true
		}
	}
	return false
}

@(test)
validators_run_after_the_rules :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	m, _ := compiled(t)
	both(t, &m, `{"name":"a","pair":{"low":1,"high":2},"inner":{"n":1}}`, "")
	both(t, &m, `{"name":"x","pair":{"low":1,"high":2},"inner":{"n":1}}`, "Custom(no x)/name;Custom(still no x)/name;")
	both(t, &m, `{"name":"a","pair":{"low":3,"high":2},"inner":{"n":1}}`, "Custom(high below low)/pair/high;")
	both(t, &m, `{"name":"bad","pair":{"low":1,"high":2},"inner":{"n":1}}`, "Custom(bad outer);")
}

@(test)
a_struct_validator_waits_for_its_members :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	m, _ := compiled(t)
	// The nested struct fails a rule, and the member `name` fails its validator: the outer validator is skipped.
	both(t, &m, `{"name":"bad","pair":{"low":1,"high":2},"inner":{"n":-1}}`, "Below_Minimum/inner/n;")
	both(t, &m, `{"name":"x","pair":{"low":1,"high":2},"inner":{"n":1}}`, "Custom(no x)/name;Custom(still no x)/name;")
}

@(test)
a_load_without_a_sink_stops_at_the_first_failure :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	m, _ := compiled(t)
	v: Outer
	err := model.load(&m, transmute([]u8)string(`{"name":"x","pair":{"low":1,"high":2},"inner":{"n":1}}`), &v)
	testing.expect(t, err != nil)
	typed_err, is_typed := err.(core.Typed_Failure)
	testing.expect(t, is_typed && typed_err.kind == .Custom)
}

@(private = "file")
Account :: struct {
	user: string,
	pass: string,
}

@(private = "file")
no_user_name_password :: proc(v: Account, r: ^model.Report) {
	if v.user == v.pass {
		model.fail_at(r, "pass", "password is the user name")
	}
}

@(private = "file")
short_user :: proc(v: string, r: ^model.Report) {
	if len(v) < 3 {
		model.fail(r, "too short")
	}
}

@(test)
csv_rows_run_the_validators_as_json_objects_do :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	_ = model.register(&reg, Account, "user", short_user)
	_ = model.register(&reg, Account, no_user_name_password)
	csv_m, e1 := model.compile(&reg, []Account, dsv.checks(.Csv))
	json_m, e2 := model.compile(&reg, []Account, json.reads(.Json))
	walktest.expect_nil(t, e1)
	walktest.expect_nil(t, e2)
	sink: typed.Sink
	rows: []Account
	_ = model.load(&csv_m, transmute([]u8)string("user,pass\nada,ada\nbo,secret\nzed,hunter\n"), &rows, &sink)
	sink2: typed.Sink
	rows2: []Account
	_ = model.load(&json_m, transmute([]u8)string(`[{"user":"ada","pass":"ada"},{"user":"bo","pass":"secret"},{"user":"zed","pass":"hunter"}]`), &rows2, &sink2)
	testing.expect_value(t, spelled(&sink), "Custom(password is the user name)/0/pass;Custom(too short)/1/user;")
	testing.expect_value(t, spelled(&sink2), spelled(&sink))
	built := []Account{{"ada", "ada"}, {"bo", "secret"}, {"zed", "hunter"}}
	sink3: typed.Sink
	_ = model.validate(&json_m, &built, &sink3)
	testing.expect_value(t, spelled(&sink3), spelled(&sink))
}


@(test)
a_failed_validator_names_its_path_from_the_outermost :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	m, _ := compiled(t)
	v: Outer
	err := model.load(&m, transmute([]u8)string(`{"name":"a","pair":{"low":3,"high":2},"inner":{"n":1}}`), &v)
	failure, is_typed := err.(core.Typed_Failure)
	testing.expect(t, is_typed)
	testing.expect_value(t, len(failure.steps), 2)
	if len(failure.steps) == 2 {
		testing.expect_value(t, failure.steps[0], core.Step(core.Name("pair")))
		testing.expect_value(t, failure.steps[1], core.Step(core.Name("high")))
	}
	valid: typed.Sink
	_ = model.validate(&m, &Outer{name = "a", pair = {3, 2}}, &valid)
	testing.expect_value(t, spelled(&valid), "Custom(high below low)/pair/high;")
}

@(private = "file")
Req :: struct {
	a: int,
	b: string,
}

@(private = "file")
b_not_x :: proc(v: string, r: ^model.Report) {
	if v == "x" {
		model.fail(r, "b is x")
	}
}

@(test)
a_missing_member_does_not_hide_the_validators_of_the_others :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	_ = model.register(&reg, Req, "b", b_not_x)
	m, err := model.compile(&reg, Req, json.reads(.Json))
	walktest.expect_nil(t, err)
	v: Req
	sink: typed.Sink
	_ = model.load(&m, transmute([]u8)string(`{"b":"x"}`), &v, &sink)
	testing.expect_value(t, spelled(&sink), "Missing_Field/a;Custom(b is x)/b;")
	validated: typed.Sink
	_ = model.validate(&m, &v, &validated)
	testing.expect_value(t, spelled(&validated), "Custom(b is x)/b;")
}
