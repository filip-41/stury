#+feature dynamic-literals
package json_tests

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:io"
import "core:math"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import json ".."
import walktest "../../walktest"

Color :: enum u8 {
	Red,
	Green  = 5,
	Blue,
}

Signed :: enum i8 {
	Low  = -3,
	High = 7,
}

Inner :: struct {
	x: i32,
	y: string `json:"why"`,
}

Pet :: union {
	Inner,
	i64,
	string,
}

Tagged_Cat :: struct {
	name: string,
	age:  i64,
}

Tagged_Dog :: struct {
	bark: bool,
}

Tagged :: union {
	Tagged_Cat,
	Tagged_Dog,
}

Link :: struct {
	id:   i64,
	next: ^Link,
}

Stamp :: struct {
	seconds: i64,
}

written :: proc(t: ^testing.T, value: any, want: string, opts := core.Write_Options{}, loc := #caller_location) {
	text, err := json.marshal(value, write = opts, allocator = context.temp_allocator)
	walktest.expect_nil(t, err, loc)
	testing.expect_value(t, string(text), want, loc)
}

refused :: proc(t: ^testing.T, value: any, want: core.Typed_Error_Kind, opts := core.Write_Options{}, loc := #caller_location) -> core.Error {
	text, err := json.marshal(value, write = opts, allocator = context.temp_allocator)
	walktest.expect_kind(t, err, want, loc)
	testing.expect_value(t, len(text), 0, loc)
	return err
}

@(test)
every_scalar_kind :: proc(t: ^testing.T) {
	written(t, true, `true`)
	written(t, i8(-8), `-8`)
	written(t, i16(-300), `-300`)
	written(t, i32(-70000), `-70000`)
	written(t, i64(min(i64)), `-9223372036854775808`)
	written(t, u8(200), `200`)
	written(t, u16(60000), `60000`)
	written(t, u32(4000000000), `4000000000`)
	written(t, u64(max(u64)), `18446744073709551615`)
	written(t, int(7), `7`)
	written(t, f32(1.5), `1.5`)
	written(t, f64(0.1), `0.1`)
	written(t, f64(1e16), `1e+16`)
	written(t, f64(1e-5), `1e-05`)
	written(t, "a\"b\n", `"a\"b\n"`)
	written(t, "a\x7fb", "\"a\x7fb\"")
	written(t, "a\x7fb", "\"a\\u007fb\"", {escape_del = true})
	written(t, cstring("c"), `"c"`)
	written(t, cstring(nil), `null`)
	written(t, typed.Raw(`{"a": [1]}`), `{"a": [1]}`)
	written(t, typed.Raw(""), `null`)
	written(t, typed.Number_Text("1.50"), `1.50`)
	written(t, Color.Green, `"Green"`)
	written(t, Signed.Low, `"Low"`)
	written(t, core.Number{kind = .Int, bits = transmute(u64)i64(-2)}, `-2`)
	written(t, core.Number{kind = .Uint, bits = max(u64)}, `18446744073709551615`)
	written(t, core.Number{kind = .Float, bits = transmute(u64)f64(2.5)}, `2.5`)
	written(t, typed.Scalar(nil), `null`)
	written(t, typed.Scalar(true), `true`)
	written(t, typed.Scalar(i64(3)), `3`)
	written(t, typed.Scalar(string("s")), `"s"`)
	written(t, typed.Scalar(typed.Number_Text("9e9")), `9e9`)
}

@(test)
every_container_kind :: proc(t: ^testing.T) {
	written(t, []i64{}, `[]`)
	written(t, []i64{1, 2}, `[1,2]`)
	written(t, [3]u8{1, 2, 3}, `[1,2,3]`)
	d := [dynamic]string{"a"}
	defer delete(d)
	written(t, d, `["a"]`)
	written(t, Inner{1, "b"}, `{"x":1,"why":"b"}`)
	written(t, []Inner{{1, "a"}, {2, "b"}}, `[{"x":1,"why":"a"},{"x":2,"why":"b"}]`)
	written(t, struct {}{}, `{}`)
	written(t, [][]i64{{}, {1}}, `[[],[1]]`)
	n := i64(4)
	written(t, &n, `4`)
	written(t, (^i64)(nil), `null`)
	written(t, Maybe(i64)(5), `5`)
	written(t, Maybe(i64)(nil), `null`)
	written(t, Maybe(cstring)(nil), `null`)
	written(t, Maybe(^i64)(&n), `4`)
	written(t, Maybe(^i64)(nil), `null`)
	written(t, Pet(i64(9)), `9`)
	written(t, Pet("s"), `"s"`)
	written(t, Pet(Inner{1, ""}), `{"x":1,"why":""}`)
	written(t, Pet(nil), `null`)
	written(t, bit_set[Color]{.Red, .Blue}, `["Red","Blue"]`)
	written(t, bit_set[0 ..= 9]{1, 8}, `[1,8]`)
	written(t, bit_set[Color]{}, `[]`)
}

@(test)
map_keys_sort_past_their_first_words :: proc(t: ^testing.T) {
	m: map[string]i64
	defer delete(m)
	for i in 0 ..< 40 {
		m[fmt.tprintf("shared-prefix-of-24-by%d", i * 7919 % 101)] = 1
		m[fmt.tprintf("k%d", i * 31 % 57)] = 2
		m[fmt.tprintf("%08d", i * 13 % 29)] = 3
		m[fmt.tprintf("%0*d", 8 + i % 3, i * 17 % 23)] = 4
	}
	sorted: [dynamic]string
	defer delete(sorted)
	for k in m {
		append(&sorted, k)
	}
	slice.sort(sorted[:])
	want := strings.builder_make()
	defer strings.builder_destroy(&want)
	strings.write_byte(&want, '{')
	for k, i in sorted {
		if i > 0 {
			strings.write_byte(&want, ',')
		}
		fmt.sbprintf(&want, `"%s":%d`, k, m[k])
	}
	strings.write_byte(&want, '}')
	written(t, m, strings.to_string(want))
	n := map[string]i64 {
		"a\x00\x00"   = 1,
		"abcdefgh\x00" = 2,
		"a\x01"        = 3,
		"abcdefgh"     = 4,
		"a"            = 5,
		"a\x00"        = 6,
		"abcdefg"      = 7,
		""             = 8,
	}
	defer delete(n)
	written(t, n, `{"":8,"a":5,"a\u0000":6,"a\u0000\u0000":1,"a\u0001":3,"abcdefg":7,"abcdefgh":4,"abcdefgh\u0000":2}`)
}

@(test)
maps_are_sorted_by_their_keys :: proc(t: ^testing.T) {
	m := map[string]i64 {
		"b" = 2,
		"a" = 1,
		"é" = 3,
	}
	defer delete(m)
	written(t, m, `{"a":1,"b":2,"é":3}`)
	n := map[i64]string {
		10 = "ten",
		9  = "nine",
		-1 = "m",
	}
	defer delete(n)
	written(t, n, `{"-1":"m","10":"ten","9":"nine"}`)
	e := map[Color]bool {
		.Blue = true,
		.Red  = false,
	}
	defer delete(e)
	written(t, e, `{"Blue":true,"Red":false}`)
	c := map[cstring]u8 {
		"k" = 1,
	}
	defer delete(c)
	written(t, c, `{"k":1}`)
	u := map[u16]u8 {
		7 = 1,
	}
	defer delete(u)
	written(t, u, `{"7":1}`)
	written(t, map[string]i64{}, `{}`)
	s := []map[string][]i64{{"z" = {1}, "y" = {}}, {}}
	defer delete(s[0])
	written(t, s, `[{"y":[],"z":[1]},{}]`)
}

@(test)
tags_rename_skip_and_omit :: proc(t: ^testing.T) {
	Empties :: struct {
		a: i64 `json:",omitempty"`,
		b: bool `json:",omitempty"`,
		c: string `json:",omitempty"`,
		d: []i64 `json:",omitempty"`,
		e: map[string]i64 `json:",omitempty"`,
		f: ^i64 `json:",omitempty"`,
		g: Maybe(i64) `json:",omitempty"`,
		h: Pet `json:",omitempty"`,
		i: f64 `json:",omitempty"`,
		j: any `json:",omitempty"`,
		k: Color `json:",omitempty"`,
		l: Inner `json:",omitempty"`,
		m: [2]i64 `json:",omitempty"`,
		n: bit_set[Color] `json:",omitempty"`,
		s: i64 `json:"-"`,
		z: i64 `json:"last,omitempty"`,
	}
	written(t, Empties{}, `{"k":"Red","l":{"x":0,"why":""},"m":[0,0]}`)
	written(t, Empties{a = 1, z = 2, s = 3}, `{"a":1,"k":"Red","l":{"x":0,"why":""},"m":[0,0],"last":2}`)
	Only :: struct {
		a: i64 `json:",omitempty"`,
	}
	written(t, Only{}, `{}`)
	written(t, Only{}, "{}", {pretty = true, indent = 2})
	Escaped :: struct {
		a: i64 `json:"a<b"`,
		b: i64 `json:"é"`,
		c: i64 `json:"q\"r"`,
	}
	written(t, Escaped{}, `{"a<b":0,"é":0,"q\"r":0}`)
	written(t, Escaped{}, "{\"a\\u003cb\":0,\"\\u00e9\":0,\"q\\\"r\":0}", {ascii = true, escape_html = true})
}

@(test)
a_long_name_writes_whole :: proc(t: ^testing.T) {
	Long :: struct {
		a: i64 `json:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`,
		b: i64,
	}
	text, err := json.marshal(Long{1, 2}, write = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	back: Long
	walktest.expect_nil(t, json.unmarshal(text, .Json, &back))
	testing.expect_value(t, back, Long{1, 2})
}

@(test)
pretty_text :: proc(t: ^testing.T) {
	p := core.Write_Options{pretty = true, indent = 2}
	written(t, Inner{1, "b"}, "{\n  \"x\": 1,\n  \"why\": \"b\"\n}", p)
	written(t, []i64{}, "[]", p)
	written(t, []i64{1, 2}, "[\n  1,\n  2\n]", p)
	written(t, [][]i64{{}, {1}}, "[\n  [],\n  [\n    1\n  ]\n]", p)
	m := map[string][]Inner {
		"k" = {{1, "a"}},
	}
	defer delete(m)
	written(t, m, "{\n  \"k\": [\n    {\n      \"x\": 1,\n      \"why\": \"a\"\n    }\n  ]\n}", p)
	written(t, map[string]i64{}, "{}", p)
	written(t, bit_set[Color]{.Red, .Blue}, "[\n  \"Red\",\n  \"Blue\"\n]", p)
	written(t, bit_set[Color]{}, "[]", p)
	written(t, []i64{1}, "[\n\t1\n]", {pretty = true, tab = true})
	written(t, []i64{1}, "[\n1\n]", {pretty = true})
}

@(test)
a_list_of_structs_shares_one_frame :: proc(t: ^testing.T) {
	Empty :: struct {
		n: i64 `json:",omitempty"`,
	}
	Row :: struct {
		a: i64,
		b: []Empty,
		c: f64,
	}
	p := core.Write_Options{pretty = true, indent = 2}
	written(t, []Empty{{}, {}, {}}, `[{},{},{}]`)
	written(t, []Empty{{}, {}}, "[\n  {},\n  {}\n]", p)
	rows := []Row{{1, {}, 0.5}, {2, {{}}, 1.5}}
	written(t, rows, `[{"a":1,"b":[],"c":0.5},{"a":2,"b":[{}],"c":1.5}]`)
	written(t, rows, "[\n  {\n    \"a\": 1,\n    \"b\": [],\n    \"c\": 0.5\n  },\n  {\n    \"a\": 2,\n    \"b\": [\n      {}\n    ],\n    \"c\": 1.5\n  }\n]", p)
	rows[1].c = math.inf_f64(1)
	e := refused(t, rows, .Non_Finite)
	testing.expect_value(t, walktest.typed_of(e).n_steps, 2)
	testing.expect_value(t, walktest.typed_of(e).steps[0].(core.Index), core.Index(1))
	testing.expect_value(t, string(walktest.typed_of(e).steps[1].(core.Name)), "c")
}

@(test)
sort_keys_sorts_members_and_the_tag :: proc(t: ^testing.T) {
	Mixed :: struct {
		zed:   i64,
		alpha: i64,
		mid:   Inner,
	}
	written(t, Mixed{1, 2, {3, "y"}}, `{"alpha":2,"mid":{"why":"y","x":3},"zed":1}`, {sort_keys = true})
	written(t, Mixed{1, 2, {3, "y"}}, "{\n \"alpha\": 2,\n \"mid\": {\n  \"why\": \"y\",\n  \"x\": 3\n },\n \"zed\": 1\n}", {sort_keys = true, pretty = true, indent = 1})
	plan, err := json.plan_make(Tagged, plan = {union_tag = "kind"}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	v := Tagged(Tagged_Cat{"t", 2})
	text, e := write.marshal(v, &plan, {}, context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, string(text), `{"kind":"Tagged_Cat","name":"t","age":2}`)
	text, e = write.marshal(v, &plan, {sort_keys = true}, context.temp_allocator)
	testing.expect_value(t, string(text), `{"age":2,"kind":"Tagged_Cat","name":"t"}`)
	back: Tagged
	walktest.expect_nil(t, json.unmarshal(text, .Json, &back, &plan, allocator = context.temp_allocator))
	testing.expect_value(t, back.(Tagged_Cat).age, 2)
}

@(test)
captured_members_follow_the_declared_ones :: proc(t: ^testing.T) {
	Open :: struct {
		a:    i64,
		rest: map[string]typed.Raw `json:",unknown"`,
	}
	v := Open {
		a = 1,
		rest = {"z" = `[1]`, "b" = `2`},
	}
	defer delete(v.rest)
	written(t, v, `{"a":1,"b":2,"z":[1]}`)
	back: Open
	walktest.expect_nil(t, json.unmarshal(transmute([]u8)string(`{"z":[1],"a":1,"b":2}`), .Json, &back, allocator = context.temp_allocator))
	written(t, back, `{"a":1,"b":2,"z":[1]}`)
}

@(test)
an_any_writes_its_value :: proc(t: ^testing.T) {
	n, s, b, f, u := i64(1), "s", true, f64(2.5), u64(3)
	written(t, []any{n, s, b, f, u, nil}, `[1,"s",true,2.5,3,null]`)
	written(t, any(nil), `null`)
	i := Inner{1, "b"}
	written(t, []any{i, []Inner{i}}, `[{"x":1,"why":"b"},[{"x":1,"why":"b"}]]`)
	Box :: struct {
		v: any,
		w: i64,
	}
	written(t, Box{Box{nil, 1}, 2}, `{"v":{"v":null,"w":1},"w":2}`)
	written(t, []any{i32(1), Color.Blue}, `[1,"Blue"]`)
}

hook_stamp :: proc(v: rawptr, allocator: runtime.Allocator) -> (any, core.Typed_Error_Kind) {
	s := (^Stamp)(v)
	if s.seconds < 0 {
		return nil, .Bad_Raw
	}
	text := new(string, allocator)
	text^ = fmt.aprintf("t%d", s.seconds, allocator = allocator)
	return text^, .None
}

hook_self :: proc(v: rawptr, allocator: runtime.Allocator) -> (any, core.Typed_Error_Kind) {
	return (^Stamp)(v)^, .None
}

@(test)
a_hook_returns_a_stand_in :: proc(t: ^testing.T) {
	Row :: struct {
		at: Stamp,
		n:  i64,
	}
	plan, err := json.plan_make([]Row, plan = {hooks = {{type = Stamp, write = hook_stamp}}}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	rows := []Row{{{5}, 1}, {{6}, 2}}
	text, e := write.marshal(rows, &plan, {}, context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, string(text), `[{"at":"t5","n":1},{"at":"t6","n":2}]`)
	rows[1].at.seconds = -1
	_, e = write.marshal(rows, &plan, {}, context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Bad_Raw)
	testing.expect_value(t, walktest.typed_of(e).n_steps, 2)
	testing.expect_value(t, walktest.typed_of(e).steps[0].(core.Index), core.Index(1))
	testing.expect_value(t, string(walktest.typed_of(e).steps[1].(core.Name)), "at")
	self, _ := json.plan_make(Stamp, plan = {hooks = {{type = Stamp, write = hook_self}}}, allocator = context.temp_allocator)
	_, e = write.marshal(Stamp{1}, &self, {}, context.temp_allocator)
	testing.expect(t, walktest.typed_kind(e) == .Too_Deep || walktest.typed_kind(e) == .Cycle)
	only_read, _ := json.plan_make(Stamp, plan = {hooks = {{type = Stamp, read = proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {return nil}}}}, allocator = context.temp_allocator)
	_, e = write.marshal(Stamp{1}, &only_read, {}, context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Unsupported)
}

@(test)
what_a_write_refuses :: proc(t: ^testing.T) {
	inf := math.inf_f64(1)
	refused(t, inf, .Non_Finite)
	refused(t, f32(inf), .Non_Finite)
	refused(t, typed.Scalar(inf), .Non_Finite)
	refused(t, core.Number{kind = .Wide}, .Non_Finite)
	refused(t, "\xff", .Invalid_Utf8)
	refused(t, transmute(Color)u8(2), .Not_A_Member)
	refused(t, transmute(bit_set[Color])u8(4), .Not_A_Member)
	refused(t, typed.Raw(`{`), .Bad_Raw)
	refused(t, typed.Raw(` 1`), .Bad_Raw)
	refused(t, typed.Raw(`1 `), .Bad_Raw)
	refused(t, typed.Raw(`1 2`), .Bad_Raw)
	refused(t, typed.Number_Text(`"s"`), .Bad_Raw)
	refused(t, typed.Number_Text(`01`), .Bad_Raw)
	bad_key := map[Color]i64 {
		transmute(Color)u8(2) = 1,
	}
	defer delete(bad_key)
	refused(t, bad_key, .Not_A_Member)
}

@(test)
cycles_and_depth :: proc(t: ^testing.T) {
	a := Link{id = 1}
	b := Link{2, &a}
	a.next = &b
	refused(t, a, .Cycle)
	shared := Link{id = 3}
	Pair :: struct {
		l, r: ^Link,
	}
	written(t, Pair{&shared, &shared}, `{"l":{"id":3,"next":null},"r":{"id":3,"next":null}}`)
	chain := make([]Link, core.MAX_DEPTH + 2, context.temp_allocator)
	for i in 0 ..< len(chain) - 1 {
		chain[i].next = &chain[i + 1]
	}
	refused(t, chain[0], .Too_Deep)
	short := make([]Link, core.MAX_DEPTH / 3, context.temp_allocator)
	for i in 0 ..< len(short) - 1 {
		short[i].next = &short[i + 1]
	}
	_, err := json.marshal(short[0], write = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
}

@(test)
a_refusal_names_its_path :: proc(t: ^testing.T) {
	Row :: struct {
		name: string,
		vals: []f64,
	}
	Doc :: struct {
		rows:  []Row,
		table: map[string]Row,
	}
	inf := math.inf_f64(1)
	d := Doc{rows = {{"a", {1}}, {"b", {2, 3, inf}}}}
	err := refused(t, d, .Non_Finite)
	testing.expect_value(t, walktest.typed_of(err).n_steps, 4)
	testing.expect_value(t, string(walktest.typed_of(err).steps[0].(core.Name)), "rows")
	testing.expect_value(t, walktest.typed_of(err).steps[1].(core.Index), core.Index(1))
	testing.expect_value(t, string(walktest.typed_of(err).steps[2].(core.Name)), "vals")
	testing.expect_value(t, walktest.typed_of(err).steps[3].(core.Index), core.Index(2))
	d.rows = nil
	d.table = {"k" = {"c", {inf}}}
	defer delete(d.table)
	err = refused(t, d, .Non_Finite)
	testing.expect_value(t, walktest.typed_of(err).n_steps, 4)
	testing.expect_value(t, string(walktest.typed_of(err).steps[0].(core.Name)), "table")
	testing.expect_value(t, string(walktest.typed_of(err).steps[1].(core.Name)), "k")
	testing.expect_value(t, string(walktest.typed_of(err).steps[2].(core.Name)), "vals")
	testing.expect_value(t, walktest.typed_of(err).steps[3].(core.Index), core.Index(0))
	// A listed key is named as the value holds it, not as it is written.
	escaped := map[string]f64 {
		"a\"bé" = inf,
	}
	defer delete(escaped)
	err = refused(t, escaped, .Non_Finite, {ascii = true})
	testing.expect_value(t, walktest.typed_of(err).n_steps, 1)
	testing.expect_value(t, string(walktest.typed_of(err).steps[0].(core.Name)), "a\"bé")
}

@(test)
a_deep_refusal_keeps_the_innermost_steps :: proc(t: ^testing.T) {
	Deep :: struct {
		n: ^Deep,
		x: f64,
	}
	chain := make([]Deep, 20, context.temp_allocator)
	for i in 0 ..< len(chain) - 1 {
		chain[i].n = &chain[i + 1]
	}
	chain[19].x = math.inf_f64(1)
	err := refused(t, chain[0], .Non_Finite)
	testing.expect(t, walktest.typed_of(err).truncated)
	testing.expect_value(t, int(walktest.typed_of(err).n_steps), core.MAX_ERROR_STEPS)
	testing.expect_value(t, string(walktest.typed_of(err).steps[core.MAX_ERROR_STEPS - 1].(core.Name)), "x")
}

Byte_Sink :: struct {
	text:     [dynamic]u8,
	fail_at:  int,
}

byte_sink_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	sink := (^Byte_Sink)(data)
	#partial switch mode {
	case .Write:
		if sink.fail_at > 0 && len(sink.text) + len(p) > sink.fail_at {
			return 0, .Unknown
		}
		append(&sink.text, ..p)
		return i64(len(p)), nil
	case .Query:
		return transmute(i64)io.Stream_Mode_Set{.Write, .Query}, nil
	}
	return 0, .Unsupported
}

@(test)
a_stream_takes_the_same_text :: proc(t: ^testing.T) {
	rows := make([]Inner, 20000, context.temp_allocator)
	for &r, i in rows {
		r = {i32(i), "some text"}
	}
	want, err := json.marshal(rows, write = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	plan, perr := json.plan_make([]Inner, plan = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, perr)
	sink := Byte_Sink{text = make([dynamic]u8, context.temp_allocator)}
	walktest.expect_nil(t, write.marshal_stream({byte_sink_proc, &sink}, rows, &plan, {}, context.temp_allocator))
	testing.expect(t, bytes.equal(sink.text[:], want))
	failing := Byte_Sink{text = make([dynamic]u8, context.temp_allocator), fail_at = 100000}
	e := write.marshal_stream({byte_sink_proc, &failing}, rows, &plan, {}, context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Write_Failed)
	testing.expect_value(t, walktest.typed_of(e).cause, io.Error.Unknown)
}

@(test)
a_plan_writes_only_its_type :: proc(t: ^testing.T) {
	plan, err := json.plan_make(i64, plan = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	_, e := write.marshal("s", &plan, {}, context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Plan_Mismatch)
}

@(test)
a_small_value_leaves_nothing_behind :: proc(t: ^testing.T) {
	m := map[string][]Inner {
		"a" = {{1, "x"}},
	}
	defer delete(m)
	v := []any{i64(1), Inner{2, "y"}, m}
	text, err := json.marshal(v)
	defer delete(text)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), `[1,{"x":2,"why":"y"},{"a":[{"x":1,"why":"x"}]}]`)
}

Close_Node :: struct {
	p: string,
	k: []Close_Node,
}

// Closing a struct of a list and opening the next write two lines under one reservation, each as long as the depth makes
// it, wherever the reservation falls in the buffer. The address sanitizer sees a store past it, and the text is the model.
@(test)
marshal_two_lines_at_a_struct_close :: proc(t: ^testing.T) {
	make_tree :: proc(depth, width: int) -> Close_Node {
		n := Close_Node{k = make([]Close_Node, width, context.temp_allocator)}
		if depth > 0 {
			n.k[0] = make_tree(depth - 1, width)
		}
		return n
	}
	for depth in ([]int{170, 260}) {
		for pad in 0 ..< 12 {
			v := make_tree(depth, 200)
			v.p = strings.repeat("x", pad * 37 + 1, context.temp_allocator)
			text, err := json.marshal(v, write = core.PRETTY)
			walktest.expect_nil(t, err)
			doc, derr := json.build(text, .Json, {max_depth = 4 * 1024})
			walktest.expect_nil(t, derr)
			again, _, werr := core.write(&doc, core.PRETTY)
			walktest.expect_nil(t, werr)
			testing.expect(t, string(again) == string(text))
			delete(again)
			core.destroy(&doc)
			delete(text)
		}
	}
}

// Map keys sort by their own bytes, so an option that spells a key again moves no key.
@(test)
sorted_keys_ignore_their_spelling :: proc(t: ^testing.T) {
	m := make(map[string]int, context.temp_allocator)
	m["é"], m["z"], m["<"] = 1, 2, 3
	cases := [?]struct {
		opts: core.Write_Options,
		want: string,
	} {
		{{}, `{"<":3,"z":2,"é":1}`},
		{{ascii = true}, `{"<":3,"z":2,"\u00e9":1}`},
		{{escape_html = true}, `{"\u003c":3,"z":2,"é":1}`},
		{{sort_keys = true, ascii = true, escape_html = true}, `{"\u003c":3,"z":2,"\u00e9":1}`},
	}
	for c in cases {
		text, err := json.marshal(m, write = c.opts, allocator = context.temp_allocator)
		walktest.expect_nil(t, err)
		testing.expect_value(t, string(text), c.want)
	}
}

Capture_Doubled :: struct {
	a:     int,
	b:     int `json:",omitempty"`,
	notes: map[string]typed.Raw `json:",unknown"`,
}

// A capture holds what the type does not name, so a key a written member also has is refused, not written twice, and an
// omitted member leaves its name to the capture.
@(test)
capture_of_a_declared_name :: proc(t: ^testing.T) {
	v := Capture_Doubled{a = 1, notes = make(map[string]typed.Raw, context.temp_allocator)}
	v.notes["a"] = typed.Raw("2")
	_, err := json.marshal(v, write = {}, allocator = context.temp_allocator)
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Unwritable)
	_, err = json.marshal(v, write = {sort_keys = true}, allocator = context.temp_allocator)
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Unwritable)
	delete_key(&v.notes, "a")
	v.notes["b"] = typed.Raw("2")
	text, oerr := json.marshal(v, write = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, oerr)
	testing.expect_value(t, string(text), `{"a":1,"b":2}`)
}

Any_Fields :: struct {
	a, b, c: any,
}

// Each `any` field holds its own side plan for the call: a second type, a first one again, and one nested in another.
@(test)
several_any_fields :: proc(t: ^testing.T) {
	inner := Any_Fields{a = 1, b = "s", c = true}
	v := Any_Fields{a = Color.Red, b = inner, c = Color.Red}
	for opts in ([?]core.Write_Options{{}, {sort_keys = true}}) {
		text, err := json.marshal(v, write = opts, allocator = context.temp_allocator)
		walktest.expect_nil(t, err)
		testing.expect_value(t, string(text), `{"a":"Red","b":{"a":1,"b":"s","c":true},"c":"Red"}`)
	}
}

Deep_Link :: struct {
	next: ^Deep_Link,
}

// Pretty text past the depth whose indent a line's reservation holds, under the widest indents.
@(test)
deep_pretty_indent :: proc(t: ^testing.T) {
	DEPTH :: 300
	links := make([]Deep_Link, DEPTH, context.temp_allocator)
	for i in 0 ..< DEPTH - 1 {
		links[i].next = &links[i + 1]
	}
	for indent in ([?]u8{8, 64, 255}) {
		b := strings.builder_make(context.temp_allocator)
		pad :: proc(b: ^strings.Builder, n: int) {
			strings.write_byte(b, '\n')
			for _ in 0 ..< n {
				strings.write_byte(b, ' ')
			}
		}
		for i in 0 ..< DEPTH {
			strings.write_byte(&b, '{')
			pad(&b, (i + 1) * int(indent))
			strings.write_string(&b, `"next": `)
		}
		strings.write_string(&b, "null")
		#reverse for _, i in links {
			pad(&b, i * int(indent))
			strings.write_byte(&b, '}')
		}
		text, err := json.marshal(links[0], write = {pretty = true, indent = indent}, allocator = context.temp_allocator)
		walktest.expect_nil(t, err)
		testing.expect(t, string(text) == strings.to_string(b))
		doc, derr := json.build(text, .Json)
		walktest.expect_nil(t, derr)
		again, _, werr := core.write(&doc, {pretty = true, indent = indent}, allocator = context.temp_allocator)
		walktest.expect_nil(t, werr)
		testing.expect(t, string(again) == string(text))
		core.destroy(&doc)
		formatted, ferr := core.format(text, json.as(.Json), {pretty = true, indent = indent}, context.temp_allocator)
		walktest.expect_nil(t, ferr)
		testing.expect(t, string(formatted) == string(text))
	}
}
