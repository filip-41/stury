package json_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import json ".."
import walktest "../../walktest"

// The `Check` read: the typed read that reports every refusal as a `core.Error_Entry` with the full path.

@(private = "file")
SPECS :: [?]json.Spec{.Json, .Jsonc, .Json5}

@(private = "file")
Inner :: struct {
	n: i32,
	s: string,
}

@(private = "file")
Shape :: struct {
	a:     i32,
	name:  string,
	list:  []i32,
	inner: Inner,
	m:     map[string]i32,
	opt:   Maybe(i32),
	p:     ^Inner,
}

// Reads `text` by `plan.check` and by `json.unmarshal` into two values of `T`, which must agree on the value and the
// first refusal. Returns the sink of the check.
@(private = "file")
both :: proc(t: ^testing.T, text: string, $T: typeid, spec: json.Spec, loc := #caller_location) -> (sink: typed.Sink, first: core.Typed_Refusal) {
	plan, planned := json.plan_make(T, spec, allocator = context.temp_allocator)
	walktest.expect_nil(t, planned, loc = loc)
	src := transmute([]u8)text
	mine, theirs := new(T, context.temp_allocator), T{}
	sink.entries.allocator = context.temp_allocator
	sink.errors.allocator = context.temp_allocator
	checked := walktest.typed_of(json.check(src, spec, mine, &plan, {sink = &sink}, context.temp_allocator))
	first.kind, first.at = checked.kind, checked.at
	want := json.unmarshal(src, spec, &theirs, &plan, read = {}, opts = {}, allocator = context.temp_allocator)
	testing.expectf(t, first.kind == walktest.typed_kind(want) && first.at == walktest.at_of(want), "%s: check gave %v at %d, unmarshal %v at %d", text, first.kind, first.at, want, walktest.at_of(want), loc = loc)
	if first.kind == .None {
		testing.expectf(t, fmt.tprint(mine^) == fmt.tprint(theirs), "%s: check read %v, unmarshal %v", text, mine^, theirs, loc = loc)
	}
	return
}

@(private = "file")
pointer_of :: proc(e: core.Error_Entry) -> string {
	b := strings.builder_make(context.temp_allocator)
	core.write_pointer(strings.to_writer(&b), e.path)
	return strings.to_string(b)
}

@(test)
a_check_of_a_good_text_reports_nothing_and_reads_the_value :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for spec in SPECS {
		sink, first := both(t, `{"a":1,"name":"x","list":[1,2],"inner":{"n":3,"s":"y"},"m":{"k":4},"opt":5,"p":{"n":6}}`, Shape, spec)
		testing.expect_value(t, first.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, len(sink.entries), 0)
	}
}

@(test)
a_check_reports_each_refusal_with_its_path_and_bytes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `{"a":"no","list":[1,"x",3],"inner":{"n":true},"m":{"k":"z"},"zz":1}`
	for spec in SPECS {
		sink, first := both(t, text, Shape, spec)
		testing.expect_value(t, first.kind, core.Typed_Error_Kind.Wrong_Kind)
		want := [?]string{"/a", "/list/1", "/inner/n", "/m/k"}
		if !testing.expect_value(t, len(sink.entries), len(want)) {
			continue
		}
		for e, i in sink.entries {
			testing.expect_value(t, pointer_of(e), want[i])
			testing.expect_value(t, e.kind, core.Typed_Error_Kind.Wrong_Kind)
			testing.expect(t, e.end > e.start, text)
			testing.expect_value(t, e.record, 0)
		}
		testing.expect_value(t, sink.entries[0].start, 5)
		testing.expect_value(t, sink.entries[0].end, 9)
		typed.sink_destroy(&sink)
	}
}

@(test)
a_check_reports_every_missing_member :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32 `json:",required"`,
		b: i32 `json:",required"`,
		c: i32,
		d: i32 `json:",required"`,
	}
	sink, first := both(t, `{"b":1,"c":2}`, S, .Json)
	testing.expect_value(t, first.kind, core.Typed_Error_Kind.Missing_Field)
	if testing.expect_value(t, len(sink.entries), 2) {
		testing.expect_value(t, pointer_of(sink.entries[0]), "/a")
		testing.expect_value(t, pointer_of(sink.entries[1]), "/d")
	}
	// A read that does not check reports the first.
	plan, _ := json.plan_make(S, allocator = context.temp_allocator)
	plain: typed.Sink
	plain.errors.allocator = context.temp_allocator
	v: S
	_ = json.unmarshal(transmute([]u8)string(`{"b":1,"c":2}`), json.Spec.Json, &v, &plan, read = {sink = &plain}, opts = {}, allocator = context.temp_allocator)
	testing.expect_value(t, len(plain.errors), 1)
	typed.sink_destroy(&sink)
}

@(test)
a_check_path_can_pass_eight_steps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Deep :: struct {
		d: []Deep,
		v: i32,
	}
	text := `{"d":[{"d":[{"d":[{"d":[{"d":[{"d":[{"d":[{"d":[{"d":[{"v":"bad"}]}]}]}]}]}]}]}]}]}`
	sink, first := both(t, text, Deep, .Json)
	testing.expect_value(t, first.kind, core.Typed_Error_Kind.Wrong_Kind)
	if testing.expect_value(t, len(sink.entries), 1) {
		testing.expect_value(t, len(sink.entries[0].path), 19)
		testing.expect_value(t, pointer_of(sink.entries[0]), "/d/0/d/0/d/0/d/0/d/0/d/0/d/0/d/0/d/0/v")
	}
	typed.sink_destroy(&sink)
}

@(test)
a_check_entry_keeps_its_names_after_the_source_is_gone :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, _ := json.plan_make(Shape, allocator = context.temp_allocator)
	src := make([]u8, len(`{"m":{"a long key":"z"}}`), context.temp_allocator)
	copy(src, `{"m":{"a long key":"z"}}`)
	sink: typed.Sink
	sink.entries.allocator = context.temp_allocator
	v: Shape
	_ = json.check(src, .Json, &v, &plan, {sink = &sink}, context.temp_allocator)
	for &b in src {
		b = 'x'
	}
	if testing.expect_value(t, len(sink.entries), 1) {
		testing.expect_value(t, pointer_of(sink.entries[0]), "/m/a long key")
	}
	typed.sink_destroy(&sink)
}

@(test)
a_check_stops_adding_at_max_errors :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, _ := json.plan_make([]i32, allocator = context.temp_allocator)
	v: []i32
	sink: typed.Sink
	sink.entries.allocator = context.temp_allocator
	sink.max_errors = 2
	first := json.check(transmute([]u8)string(`[1,"a","b","c"]`), .Json, &v, &plan, {sink = &sink}, context.temp_allocator)
	walktest.expect_kind(t, first, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, len(sink.entries), 2)
	testing.expect(t, sink.truncated)
	typed.sink_destroy(&sink)
}

@(test)
a_check_ends_at_a_walk_fault :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `{"a":1,`
	sink, first := both(t, text, Shape, .Json)
	testing.expect_value(t, first.kind, core.Typed_Error_Kind.Walk)
	if testing.expect_value(t, len(sink.entries), 1) {
		testing.expect_value(t, sink.entries[0].kind, core.Typed_Error_Kind.Walk)
		testing.expect_value(t, sink.entries[0].start, u64(len(text)))
		testing.expect_value(t, sink.entries[0].end, u64(len(text)))
	}
	typed.sink_destroy(&sink)
	// A fault past a refusal keeps the refusal's entry before it.
	sink, first = both(t, `{"a":"x","name":1e}`, Shape, .Json)
	testing.expect_value(t, first.kind, core.Typed_Error_Kind.Wrong_Kind)
	if testing.expect_value(t, len(sink.entries), 2) {
		testing.expect_value(t, sink.entries[0].kind, core.Typed_Error_Kind.Wrong_Kind)
		testing.expect_value(t, sink.entries[1].kind, core.Typed_Error_Kind.Walk)
		testing.expect_value(t, sink.entries[1].start, u64(18))
	}
	typed.sink_destroy(&sink)
}

@(test)
a_plans_read_slot_is_unmarshal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, _ := json.plan_make(Shape, reads = json.reads(.Json), allocator = context.temp_allocator)
	testing.expect(t, plan.read != nil && plan.check != nil)
	a, b: Shape
	text := `{"a":1,"name":"x","list":[1,2],"inner":{"n":3}}`
	e1 := typed.unmarshal_text(transmute([]u8)text, &a, Shape, &plan, {}, context.temp_allocator)
	e2 := json.unmarshal(transmute([]u8)text, json.Spec.Json, &b, &plan, read = {}, opts = {}, allocator = context.temp_allocator)
	testing.expect_value(t, walktest.typed_kind(e1), walktest.typed_kind(e2))
	testing.expect_value(t, fmt.tprint(a), fmt.tprint(b))
	none: typed.Plan
	e3 := typed.unmarshal_text(nil, &a, Shape, &none, {})
	walktest.expect_kind(t, e3, core.Typed_Error_Kind.Plan_Mismatch)
}

@(test)
a_check_under_refuse_reports_a_duplicate_key_as_an_entry :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, _ := json.plan_make(Shape, allocator = context.temp_allocator)
	sink: typed.Sink
	sink.entries.allocator = context.temp_allocator
	v: Shape
	first := json.check(transmute([]u8)string(`{"a":1,"a":2}`), .Json, &v, &plan, {dups = .Refuse, sink = &sink}, context.temp_allocator)
	walktest.expect_kind(t, first, core.Typed_Error_Kind.Duplicate_Key)
	testing.expect_value(t, len(sink.entries), 1)
	testing.expect_value(t, len(sink.errors), 0)
}

@(test)
a_check_entry_of_an_unknown_field_ends_past_its_value :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, _ := json.plan_make(Inner, allocator = context.temp_allocator)
	sink: typed.Sink
	sink.entries.allocator = context.temp_allocator
	v: Inner
	text := `{"n":1,"zz":2}`
	_ = json.check(transmute([]u8)string(text), .Json, &v, &plan, {unknown = .Refuse, sink = &sink}, context.temp_allocator)
	if testing.expect_value(t, len(sink.entries), 1) {
		testing.expect(t, sink.entries[0].end > sink.entries[0].start)
	}
}

// Reads `text` as `T` by `both` under every spec and checks the entries it gives: each one's kind and path, in order.
@(private = "file")
refuses :: proc(t: ^testing.T, text: string, $T: typeid, kind: core.Typed_Error_Kind, paths: []string, loc := #caller_location) {
	for spec in SPECS {
		sink, first := both(t, text, T, spec, loc)
		testing.expect_value(t, first.kind, kind, loc = loc)
		if testing.expect_value(t, len(sink.entries), len(paths), loc = loc) {
			for e, i in sink.entries {
				testing.expect_value(t, e.kind, kind, loc = loc)
				testing.expect_value(t, pointer_of(e), paths[i], loc = loc)
			}
		}
		typed.sink_destroy(&sink)
	}
}

@(private = "file")
Arm_A :: struct {
	x: i32,
}

@(private = "file")
Arm_B :: struct {
	y: string,
}

@(private = "file")
Tagged :: union {
	Arm_A,
	Arm_B,
}

@(private = "file")
Classed :: union {
	i64,
	string,
	[]i32,
}

@(private = "file")
Hue :: enum u8 {
	Red,
	Green,
}

@(test)
a_check_refuses_a_union_as_unmarshal_does :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// By class, the refused arm is the list's second element.
	refuses(t, `{"u":[1,true,"s"]}`, struct{ u: []Classed }, .Wrong_Kind, {"/u/1"})
	refuses(t, `{"u":[[1,"x"]]}`, struct{ u: []Classed }, .Wrong_Kind, {"/u/0/1"})
	// By tag, through a plan that names the tag's key.
	for spec in SPECS {
		plan, planned := json.plan_make(struct{ u: Tagged }, spec, plan = {union_tag = "type"}, allocator = context.temp_allocator)
		walktest.expect_nil(t, planned)
		cases := [?]struct{ text: string, kind: core.Typed_Error_Kind, path: string }{
			{`{"u":{"x":1}}`, .Missing_Tag, "/u"},
			{`{"u":{"type":"C"}}`, .Not_A_Member, "/u"},
			{`{"u":{"type":"Arm_A","x":"no"}}`, .Wrong_Kind, "/u/x"},
		}
		for c in cases {
			v: struct{ u: Tagged }
			sink: typed.Sink
			sink.entries.allocator = context.temp_allocator
			want := json.unmarshal(transmute([]u8)c.text, spec, &v, &plan, read = {}, opts = {}, allocator = context.temp_allocator)
			first := json.check(transmute([]u8)c.text, spec, &v, &plan, {sink = &sink}, context.temp_allocator)
			testing.expectf(t, walktest.typed_kind(first) == c.kind && walktest.typed_kind(want) == c.kind && walktest.at_of(first) == walktest.at_of(want), "%s: check %v at %d, unmarshal %v at %d", c.text, first, walktest.at_of(first), want, walktest.at_of(want))
			if testing.expect(t, len(sink.entries) >= 1, c.text) {
				testing.expect_value(t, sink.entries[0].kind, c.kind)
				testing.expect_value(t, pointer_of(sink.entries[0]), c.path)
			}
			typed.sink_destroy(&sink)
		}
	}
}

@(test)
a_check_refuses_an_enum_a_bit_set_a_maybe_and_a_pointer_as_unmarshal_does :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	refuses(t, `{"e":"Pink","f":[{"e":"Red"},{"e":"Blue"}]}`, struct{ e: Hue, f: []struct{ e: Hue } }, .Not_A_Member, {"/e", "/f/1/e"})
	refuses(t, `{"b":["Red",3,"Green"]}`, struct{ b: bit_set[Hue; u8] }, .Wrong_Kind, {"/b"})
	refuses(t, `{"b":[10,1]}`, struct{ b: bit_set[0 ..< 10] }, .Out_Of_Range, {"/b"})
	refuses(t, `{"m":"x","n":{"x":"y"}}`, struct{ m: Maybe(i32), n: Maybe(Arm_A) }, .Wrong_Kind, {"/m", "/n/x"})
	refuses(t, `{"p":{"x":"x"},"q":[1,"z"]}`, struct{ p: ^Arm_A, q: ^[]i32 }, .Wrong_Kind, {"/p/x", "/q/1"})
}

@(test)
a_check_reads_a_raw_and_reports_around_it :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	refuses(t, `{"v":{"a":[1,{"k":2.5}]},"n":"x"}`, struct{ v: typed.Raw, n: i32 }, .Wrong_Kind, {"/n"})
	refuses(t, `{"v":[1],"n":"x"}`, struct{ v: typed.Raw, n: i32 }, .Wrong_Kind, {"/n"})
	refuses(t, `{"v":[1],"n":2}`, struct{ v: any, n: i32 }, .Unsupported, {"/v"})
}

@(test)
a_check_entry_of_a_skipped_container_ends_at_its_open_token :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sink, _ := both(t, `{"a":{"x":1}}`, Shape, .Json)
	if testing.expect_value(t, len(sink.entries), 1) {
		testing.expect_value(t, sink.entries[0].start, u64(5))
		testing.expect_value(t, sink.entries[0].end, u64(6))
	}
	typed.sink_destroy(&sink)
}
