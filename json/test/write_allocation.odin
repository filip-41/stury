package json_tests

import "base:runtime"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import json ".."
import walktest "../../walktest"

// Writing with an allocator that refuses an allocation: every write gives its text or `.Out_Of_Memory`.

Sweep_Inner :: struct {
	a: int,
	b: string,
}

Sweep_Arm :: union {
	int,
	Sweep_Inner,
}

Sweep_Other :: struct {
	x: f64,
}

Sweep_Value :: struct {
	name:   string `json:"long name past the sixteen bytes"`,
	m:      map[string]int,
	list:   []Sweep_Inner,
	first:  any,
	second: any,
	arm:    Sweep_Arm,
	rest:   map[string]typed.Raw `json:",unknown"`,
}

@(private)
sweep_value :: proc() -> (v: Sweep_Value, inner: Sweep_Inner, other: Sweep_Other) {
	inner, other = {1, "b"}, {1.5}
	v.name = "n"
	v.m = make(map[string]int, context.temp_allocator)
	v.m["z"], v.m["<"], v.m["é"] = 1, 2, 3
	v.list = make([]Sweep_Inner, 2, context.temp_allocator)
	v.rest = make(map[string]typed.Raw, context.temp_allocator)
	v.rest["r"] = typed.Raw(`"s"`)
	return
}

@(private)
Marshal_Try :: struct {
	value: any,
	opts:  core.Write_Options,
}

@(private)
marshal_try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind) {
	m := (^Marshal_Try)(data)
	text, err := json.marshal(m.value, m.opts, allocator)
	return text, err.kind
}

@(test)
marshal_under_failing_allocators :: proc(t: ^testing.T) {
	v, inner, other := sweep_value()
	v.first, v.second, v.arm = inner, other, inner
	for opts in ([?]core.Write_Options{{}, {sort_keys = true}, {pretty = true, sort_keys = true, ascii = true}}) {
		try := Marshal_Try{v, opts}
		want, err := json.marshal(v, opts, context.temp_allocator)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		walktest.sweep_write(t, marshal_try, &try, string(want))
	}
}

@(private)
Plan_Try :: struct {
	value: any,
	opts:  core.Write_Options,
	plan:  ^typed.Plan,
}

@(private)
plan_try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind) {
	m := (^Plan_Try)(data)
	text, err := write.marshal(m.value, m.plan, m.opts, allocator)
	return text, err.kind
}

@(test)
planned_marshal_under_failing_allocators :: proc(t: ^testing.T) {
	v, inner, other := sweep_value()
	v.first, v.second, v.arm = inner, other, inner
	plan, perr := json.plan_make(Sweep_Value)
	defer typed.plan_destroy(&plan)
	testing.expect_value(t, perr.kind, core.Typed_Error_Kind.None)
	try := Plan_Try{v, {sort_keys = true}, &plan}
	want, err := write.marshal(v, &plan, {sort_keys = true}, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	walktest.sweep_write(t, plan_try, &try, string(want))
}

@(private)
Doc_Try :: struct {
	doc:  ^core.Document,
	opts: core.Write_Options,
}

@(private)
doc_try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind) {
	d := (^Doc_Try)(data)
	text, _, err := core.write(d.doc, d.opts, allocator = allocator)
	return text, err.kind
}

@(private)
sweep_document :: proc(t: ^testing.T, src: string, $S: json.Spec, read: json.Options, opts: core.Write_Options, loc := #caller_location) {
	doc, derr := json.build(transmute([]u8)src, S, read)
	defer core.destroy(&doc)
	testing.expect_value(t, derr.kind, core.Document_Error_Kind.None, loc = loc)
	try := Doc_Try{&doc, opts}
	want, _, err := core.write(&doc, opts, allocator = context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None, loc = loc)
	walktest.sweep_write(t, doc_try, &try, string(want), loc)
}

@(test)
document_under_failing_allocators :: proc(t: ^testing.T) {
	deep := strings.concatenate({strings.repeat("[", 2000, context.temp_allocator), strings.repeat("]", 2000, context.temp_allocator)}, context.temp_allocator)
	sweep_document(t, `{"b":1,"a":[2,{"d":3,"c":"é"}]}`, .Json, {}, {})
	sweep_document(t, `{"b":1,"a":[2,{"d":3,"c":"é"}]}`, .Json, {}, {sort_keys = true})
	sweep_document(t, `{"b":1,"a":[2,{"d":3,"c":"é"}]}`, .Json, {}, {ascii = true, pretty = true})
	sweep_document(t, "// head\n{\"b\":1, /* in */ \"a\":[2] // tail\n}\n", .Jsonc, {}, {sort_keys = true})
	sweep_document(t, "{a: 0x123456789abcdef0123456789, b: 'x'}", .Json5, {}, {})
	sweep_document(t, deep, .Json, {max_depth = 5000}, {})
}

@(private)
Format_Try :: struct {
	src:  []u8,
	opts: core.Write_Options,
	read: json.Options,
}

@(private)
format_try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind) {
	f := (^Format_Try)(data)
	text, err := json.format(f.src, .Json, f.opts, f.read, allocator)
	return text, err.kind
}

@(test)
format_under_failing_allocators :: proc(t: ^testing.T) {
	deep := strings.concatenate({strings.repeat("[", 2000, context.temp_allocator), strings.repeat("]", 2000, context.temp_allocator)}, context.temp_allocator)
	cases := [?]Format_Try {
		{src = transmute([]u8)string(`{"a": [1, "é"]}`)},
		{src = transmute([]u8)string(`{"a": [1, "é"]}`), opts = {sort_keys = true}},
		{src = transmute([]u8)string(`{"a": [1, "é"]}`), opts = {ascii = true, pretty = true}},
		{src = transmute([]u8)string("[\"a\xff\"]"), opts = {ascii = true}, read = {tolerate = {.Invalid_Utf8}}},
		{src = transmute([]u8)deep, read = {max_depth = 5000}},
	}
	for &c in cases {
		want, err := json.format(c.src, .Json, c.opts, c.read, context.temp_allocator)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		walktest.sweep_write(t, format_try, &c, string(want))
	}
}

// A write that succeeds leaves nothing on the temporary allocator, which a caller may never free.
@(test)
marshal_keeps_off_the_temporary_allocator :: proc(t: ^testing.T) {
	v, inner, other := sweep_value()
	v.first, v.second, v.arm = inner, other, inner
	f := walktest.Failing_Alloc{inner = context.temp_allocator, fail_at = -1}
	context.temp_allocator = walktest.failing_allocator(&f)
	text, err := json.marshal(v, {sort_keys = true})
	defer delete(text)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, f.n, 0)
}
