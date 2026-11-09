package json_tests

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import json ".."

// The typed read of a document: for each shape, a read of the document is the read of its text, in the value stored and
// in the refusal, and the ownership rules of a read from a document.

@(private = "file")
Pt :: struct {
	x, y: i32,
}

@(private = "file")
Hue :: enum u8 {
	Red,
	Green,
	Blue = 7,
}

@(private = "file")
Rich :: struct {
	p:   Pt,
	l:   []i32,
	d:   [dynamic]string,
	f:   [2]i32,
	c:   [dynamic; 3]i32,
	m:   map[string]Pt,
	mi:  map[i16]bool,
	e:   Hue,
	s:   bit_set[Hue; u8],
	may: Maybe(i32),
	str: string,
	cs:  cstring,
	n:   f64,
	k:   f32,
	big: u64,
}

@(private = "file")
Tagged_A :: struct {
	x: i32,
}

@(private = "file")
Tagged_B :: struct {
	y: string,
}

@(private = "file")
Tagged :: union {
	Tagged_A,
	Tagged_B,
}

@(private = "file")
Checked :: struct {
	id:   u64 `json:"item_id,required"`,
	rest: map[string]typed.Raw `json:",unknown"`,
}

@(private = "file")
Whole :: struct {
	a: typed.Raw,
	b: []typed.Raw,
	c: typed.Number_Text,
	d: typed.Scalar,
	e: any,
	f: Pt,
}

// A value as text with every map's entries sorted, since two maps of one content iterate in the order they were filled.
value_text :: proc(v: any) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	#partial switch info in runtime.type_info_base(type_info_of(v.id)).variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(info.field_count) {
			field := any{rawptr(uintptr(v.data) + info.offsets[i]), info.types[i].id}
			append(&parts, fmt.tprintf("%s=%s", info.names[i], value_text(field)))
		}
		return strings.join(parts[:], ",", context.temp_allocator)
	case runtime.Type_Info_Map:
		it := 0
		for key, value in reflect.iterate_map(v, &it) {
			append(&parts, fmt.tprintf("%s:%s", value_text(key), value_text(value)))
		}
		slice.sort(parts[:])
		return strings.join(parts[:], ",", context.temp_allocator)
	case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Array:
		for i in 0 ..< reflect.length(v) {
			append(&parts, value_text(reflect.index(v, i)))
		}
		return strings.join(parts[:], ",", context.temp_allocator)
	case runtime.Type_Info_Any:
		return value_text((^any)(v.data)^)
	case runtime.Type_Info_Pointer:
		if p := (^rawptr)(v.data)^; p != nil {
			return value_text(any{p, info.elem.id})
		}
	}
	return fmt.tprintf("%v", v)
}

errors_agree :: proc(t: ^testing.T, want_in, got_in: core.Typed_Error, text: string, loc: runtime.Source_Code_Location, shift := u64(0)) {
	want, got := want_in, got_in
	testing.expectf(t, want.kind == got.kind, "%s: kind %v, a document gives %v", text, want.kind, got.kind, loc = loc)
	testing.expectf(t, want.at + (shift if want.kind != .None else 0) == got.at, "%s: at %v, a document gives %v", text, want.at, got.at, loc = loc)
	testing.expectf(t, want.truncated == got.truncated && want.n_steps == got.n_steps, "%s: steps differ", text, loc = loc)
	testing.expectf(t, fmt.tprint(want.steps[:want.n_steps]) == fmt.tprint(got.steps[:got.n_steps]), "%s: steps %v, a document gives %v", text, want.steps[:want.n_steps], got.steps[:got.n_steps], loc = loc)
}

// Reads `text` as spec `S` into copies of `init`, once as a text and once from the root of its document, and expects
// the same value and the same refusals.
@(private = "file")
agree_as :: proc(t: ^testing.T, text: string, $S: json.Spec, init: $T, read := typed.Read_Options{}, plan_opts := typed.Plan_Options{}, loc := #caller_location) {
	src := transmute([]u8)text
	plan, perr := json.plan_make(T, plan = plan_opts, allocator = context.temp_allocator)
	testing.expect_value(t, perr.kind, core.Typed_Error_Kind.None, loc = loc)
	doc, built := json.build(src, S, {}, .Last, context.temp_allocator)
	testing.expectf(t, built.kind == .None, "%s: build %v", text, built.kind, loc = loc)
	a, b := init, init
	by_text, by_doc := read, read
	sink_a := typed.Sink{errors = make([dynamic]core.Typed_Error, context.temp_allocator)}
	sink_b := typed.Sink{errors = make([dynamic]core.Typed_Error, context.temp_allocator)}
	if read.sink != nil {
		by_text.sink, by_doc.sink = &sink_a, &sink_b
	}
	want := json.unmarshal(src, S, &a, &plan, read = by_text, opts = {}, allocator = context.temp_allocator)
	got := typed.unmarshal(&doc, core.ROOT, &b, &plan, by_doc, context.temp_allocator)
	errors_agree(t, want, got, text, loc)
	testing.expectf(t, value_text(a) == value_text(b), "%s: value %v, a document gives %v", text, value_text(a), value_text(b), loc = loc)
	if read.sink != nil {
		testing.expectf(t, len(sink_a.errors) == len(sink_b.errors) && sink_a.truncated == sink_b.truncated, "%s: %d errors, a document gives %d", text, len(sink_a.errors), len(sink_b.errors), loc = loc)
		for i in 0 ..< min(len(sink_a.errors), len(sink_b.errors)) {
			errors_agree(t, sink_a.errors[i], sink_b.errors[i], text, loc)
		}
	}
}

// `agree_as` for a text all three specs read.
@(private = "file")
agree :: proc(t: ^testing.T, text: string, init: $T, read := typed.Read_Options{}, plan_opts := typed.Plan_Options{}, loc := #caller_location) {
	agree_as(t, text, json.Spec.Json, init, read, plan_opts, loc)
	agree_as(t, text, json.Spec.Jsonc, init, read, plan_opts, loc)
	agree_as(t, text, json.Spec.Json5, init, read, plan_opts, loc)
}

@(test)
numbers_read_alike_at_each_width :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	N :: struct {
		a: i8,
		b: u8,
		c: i64,
		d: u64,
		e: f32,
		f: f64,
		g: typed.Number_Text,
		h: core.Number,
	}
	agree(t, `{"a":-128,"b":255,"c":-9223372036854775808,"d":18446744073709551615,"e":0.1,"f":-0,"g":1e400,"h":12.5}`, N{})
	agree(t, `{"e":3.4028235e38,"f":123456789012345.6,"g":-0.0001,"h":1e-7}`, N{})
	agree(t, `[0,1,-1,10,100,12345678901234567890,0.5,1e2,-1.25e-2]`, []f64{})
	agree(t, `[0,255,-3]`, []i16{})
	agree_as(t, `{a:+5.,b:0x10,c:-0x8000000000000000,d:.5e1,e:Infinity,f:-NaN,g:0xff}`, json.Spec.Json5, N{})
	agree_as(t, `{a:1,zz:-0x10,b:2,zz:1.,c:+3}`, json.Spec.Json5, N{})
}

@(test)
number_field_holds_the_number :: proc(t: ^testing.T) {
	N :: struct {
		h: core.Number,
	}
	n: N
	testing.expect_value(t, json.unmarshal(transmute([]u8)string(`{"h":12.5}`), .Json, &n).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, n.h, core.Number{transmute(u64)f64(12.5), .Float})
	testing.expect_value(t, json.unmarshal(transmute([]u8)string(`{"h":"5"}`), .Json, &n).kind, core.Typed_Error_Kind.Wrong_Kind)
}

@(test)
roots_other_than_objects_read_alike :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	agree(t, `[1,2,3]`, []i32{})
	agree(t, `[]`, []i32{7})
	agree(t, `"aé\n"`, "")
	agree(t, `"plain"`, "")
	agree(t, `5`, i32(0))
	agree(t, `true`, false)
	agree(t, `null`, i32(3))
	agree(t, `[1,[2,3],[]]`, [][]i32{})
	agree(t, `{"a":[1],"b":[]}`, map[string][]i32{})
	agree(t, `[{"x":1},{"y":2},3]`, []Pt{})
	agree(t, ` {"a" : 1 } `, map[string]i32{})
	agree(t, `{"a":{"b":{"c":[{"d":[1,2,{"e":"x"}]}]}}}`, any(nil))
	agree(t, `{"x":{"y":1}}`, typed.Raw(""))
	agree(t, `[1, {"k": 2}]`, typed.Raw(""))
	agree(t, `"s"`, typed.Raw(""))
	agree(t, `{"a":1}`, typed.Scalar{})
	agree(t, `-1.5`, typed.Scalar{})
	agree(t, `"x"`, typed.Scalar{})
	agree(t, `[1,2]`, [2]i32{})
	agree(t, `[1,2,3]`, [2]i32{})
}

@(test)
whole_values_read_alike :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	agree_as(t, `{a:{k:'v',},b:[1,],c:+1,d:0x1,e:{'x':'y'},}`, json.Spec.Json5, Whole{})
	agree_as(t, `{"a":/*c*/[1, // c
	2],"b":[ /*c*/ ],"c":1}`, json.Spec.Jsonc, Whole{})
}

@(test)
unions_hooks_and_fields_read_alike :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tagged := typed.Plan_Options {
		union_tag = "type",
		tag_names = {{Tagged_B, "bee"}},
	}
	agree(t, `{"type":"bee","y":"s"}`, Tagged{}, plan_opts = tagged)
	agree(t, `{"y":"s","type":"bee"}`, Tagged{}, plan_opts = tagged)
	agree(t, `{"x":{"deep":[1]},"type":"Tagged_A","x":2}`, Tagged{}, plan_opts = tagged)
	agree(t, `{"x":1}`, Tagged{}, plan_opts = tagged)
	agree(t, `{"type":"A","type":"A"}`, Tagged{}, plan_opts = tagged)
	agree(t, `{"type":"C"}`, Tagged{}, plan_opts = tagged)
	agree(t, `{"type":1}`, Tagged{}, plan_opts = tagged)
	agree(t, `[{"type":"bee","y":"1"},{"type":"Tagged_A","x":1}]`, []Tagged{}, plan_opts = tagged)
	agree(t, `{"type":"Tagged_A","x":1,"extra":2}`, Tagged{}, {unknown = .Refuse}, tagged)

	Hex :: struct {
		n: int,
	}
	Hooked :: struct {
		v, w: Hex,
		l:    []Hex,
	}
	hook := proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
		if v.decoded == "bad" {
			return .Out_Of_Range
		}
		(^Hex)(dest).n = len(v.text) * 10 + len(v.decoded)
		return nil
	}
	hooks := typed.Plan_Options {
		hooks = {{type = Hex, read = hook}},
	}
	agree(t, `{"v":"a\n","w":{"k":[1]},"l":[12,[3],{}]}`, Hooked{}, plan_opts = hooks)
	agree(t, `{"v":"bad"}`, Hooked{}, plan_opts = hooks)
}

@(test)
a_collecting_read_reads_past_each_refusal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32,
		l: []i32,
		p: Pt,
		n: string `json:"n,required"`,
	}
	collect := typed.Read_Options {
		sink = &typed.Sink{},
	}
	agree(t, `{"a":"no","l":[1,"x",3],"p":{"x":"y","y":2},"q":1}`, S{a = 7}, collect)
	agree(t, `["a","b","c","d"]`, []i32{}, {sink = &typed.Sink{max_errors = 2}})
	agree(t, `{"a":1,"l":[1,2],"n":"x"}`, S{}, collect)
	agree(t, `[{"x":"a"},{"y":"b"},{"x":1}]`, []Pt{}, collect)

	// The sink's errors are the read's, in order, and the read's own result is the first.
	doc, built := json.build(transmute([]u8)string(`{"a":"no","l":[1,"x"]}`), json.Spec.Json, allocator = context.temp_allocator)
	testing.expect_value(t, built.kind, core.Document_Error_Kind.None)
	plan, _ := json.plan_make(S, allocator = context.temp_allocator)
	sink := typed.Sink {
		errors = make([dynamic]core.Typed_Error, context.temp_allocator),
	}
	s: S
	e := typed.unmarshal(&doc, core.ROOT, &s, &plan, {sink = &sink}, context.temp_allocator)
	testing.expect_value(t, e.kind, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, len(sink.errors), 3)
	testing.expect_value(t, sink.errors[0].at, 5)
	testing.expect_value(t, sink.errors[2].kind, core.Typed_Error_Kind.Missing_Field)
	testing.expect_value(t, len(s.l), 2)
	testing.expect_value(t, s.l[0], 1)
}

@(test)
a_node_inside_a_document_reads_as_its_span :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `{"a":[{"x":1,"y":2},{"x":3},"no"],"b":{"k":{"x":4,"y":5}},"c":"s\n","d":7.5}`
	src := transmute([]u8)text
	doc, built := json.build(src, json.Spec.Json, allocator = context.temp_allocator)
	testing.expect_value(t, built.kind, core.Document_Error_Kind.None)
	plan, _ := json.plan_make(Pt, allocator = context.temp_allocator)
	for node in 0 ..< core.Node_Index(len(doc.nodes)) {
		a, b: Pt
		if doc.nodes[node].role == .Key {
			testing.expect_value(t, typed.unmarshal(&doc, node, &b, &plan, {}, context.temp_allocator).kind, core.Typed_Error_Kind.Bad_Option)
			continue
		}
		span := core.span(&doc, node)
		want := json.unmarshal(span, json.Spec.Json, &a, &plan, read = {}, opts = {}, allocator = context.temp_allocator)
		got := typed.unmarshal(&doc, node, &b, &plan, {}, context.temp_allocator)
		// A refusal's byte is the document's, whichever node was read.
		errors_agree(t, want, got, string(span), #location(), u64(uintptr(raw_data(span)) - uintptr(raw_data(src))))
		testing.expect_value(t, a, b)
	}
}

@(test)
an_answer_reads_as_its_value :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `{"skip":[1,[2]],"items":[{"item_id":1,"x":{"k":[1,2]}},{"item_id":"no"},{"x":null,"item_id":3}],"tail":{"a":1}}`
	src := transmute([]u8)text
	plan, _ := json.plan_make(Checked, allocator = context.temp_allocator)
	path := core.Path{steps = []core.Step{core.Name("items"), core.All{}}}
	doc, err := json.scan(src, json.Spec.Json, path, allocator = context.temp_allocator)
	testing.expect_value(t, err.kind, core.Path_Error_Kind.None)
	testing.expect(t, doc.partial)
	testing.expect_value(t, len(doc.answers), 3)
	for a in doc.answers {
		want_v, got_v: Checked
		span := core.span(&doc, a.node)
		want := json.unmarshal(span, json.Spec.Json, &want_v, &plan, read = {}, opts = {}, allocator = context.temp_allocator)
		got := typed.unmarshal(&doc, a, &got_v, &plan, {}, context.temp_allocator)
		errors_agree(t, want, got, string(span), #location(), u64(uintptr(raw_data(span)) - uintptr(raw_data(src))))
		testing.expect_value(t, want_v.id, got_v.id)
		testing.expect_value(t, len(want_v.rest), len(got_v.rest))
	}

	// The root of a partial document reads the containers a path kept, without the ones it left out.
	Root :: struct {
		items: []Checked,
	}
	good := `{"skip":[1,[2]],"items":[{"item_id":1,"x":{"k":[1,2]}},{"item_id":2},{"x":null,"item_id":3}],"tail":{"a":1}}`
	kept, kerr := json.scan(transmute([]u8)good, json.Spec.Json, path, allocator = context.temp_allocator)
	testing.expect_value(t, kerr.kind, core.Path_Error_Kind.None)
	root_plan, _ := json.plan_make(Root, allocator = context.temp_allocator)
	whole: Root
	testing.expect_value(t, typed.unmarshal(&kept, core.ROOT, &whole, &root_plan, {}, context.temp_allocator).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, len(whole.items), 3)
	testing.expect_value(t, whole.items[0].id, 1)
	testing.expect_value(t, whole.items[2].id, 3)

	// A path that found nothing holds no value.
	miss, merr := json.scan(src, json.Spec.Json, core.Path{steps = []core.Step{core.Name("absent")}}, allocator = context.temp_allocator)
	testing.expect_value(t, merr.kind, core.Path_Error_Kind.None)
	v: Checked
	testing.expect_value(t, len(miss.answers), 1)
	testing.expect_value(t, typed.unmarshal(&miss, miss.answers[0], &v, &plan, {}, context.temp_allocator).kind, core.Typed_Error_Kind.Bad_Option)
}

@(test)
a_document_read_refuses_what_a_text_read_refuses :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `{"x":1,"y":2}`
	doc, _ := json.build(transmute([]u8)text, json.Spec.Json, allocator = context.temp_allocator)
	plan, _ := json.plan_make(Pt, allocator = context.temp_allocator)
	other, _ := json.plan_make(Rich, allocator = context.temp_allocator)
	p: Pt
	testing.expect_value(t, typed.unmarshal(&doc, core.ROOT, &p, &other, {}, context.temp_allocator).kind, core.Typed_Error_Kind.Plan_Mismatch)
	r: Rich
	testing.expect_value(t, typed.unmarshal(&doc, core.ROOT, &r, &plan, {}, context.temp_allocator).kind, core.Typed_Error_Kind.Plan_Mismatch)
	other_format := core.Spelling{}
	elsewhere, _ := typed.plan_build(Pt, {spelling = &other_format}, allocator = context.temp_allocator)
	testing.expect_value(t, typed.unmarshal(&doc, core.ROOT, &p, &elsewhere, {}, context.temp_allocator).kind, core.Typed_Error_Kind.Plan_Mismatch)
	testing.expect_value(t, typed.unmarshal(&doc, core.ROOT, (^Pt)(nil), &plan, {}, context.temp_allocator).kind, core.Typed_Error_Kind.Bad_Option)
	testing.expect_value(t, typed.unmarshal(&doc, core.ROOT, &p, nil, {}, context.temp_allocator).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, p, Pt{1, 2})
	p = {}
	testing.expect_value(t, typed.unmarshal(&doc, core.Node_Index(len(doc.nodes)), &p, &plan, {}, context.temp_allocator).kind, core.Typed_Error_Kind.Bad_Option)
	testing.expect_value(t, typed.unmarshal(&doc, core.NO_NODE, &p, &plan, {}, context.temp_allocator).kind, core.Typed_Error_Kind.Bad_Option)
	testing.expect_value(t, typed.unmarshal(&doc, core.ROOT, &p, &plan, {dups = .Refuse}, context.temp_allocator).kind, core.Typed_Error_Kind.Bad_Option)
	testing.expect_value(t, typed.unmarshal(nil, core.ROOT, &p, &plan, {}, context.temp_allocator).kind, core.Typed_Error_Kind.Bad_Option)
	empty: core.Document
	testing.expect_value(t, typed.unmarshal(&empty, core.ROOT, &p, &plan, {}, context.temp_allocator).kind, core.Typed_Error_Kind.Bad_Option)
	// Nothing was stored by a refusal at the start.
	testing.expect_value(t, p, Pt{})
	testing.expect_value(t, typed.unmarshal(&doc, core.ROOT, &p, &plan, {}, context.temp_allocator).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, p, Pt{1, 2})
}

@(test)
a_deep_document_uses_the_wide_stacks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Deep :: struct {
		d: ^Deep,
	}
	depth := core.MAX_DEPTH + 100
	text := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< depth {
		append(&text, `{"d":`)
	}
	append(&text, `null`)
	for _ in 0 ..< depth {
		append(&text, '}')
	}
	doc, built := json.build(text[:], json.Spec.Json, json.Options{max_depth = u32(depth)}, allocator = context.temp_allocator)
	testing.expect_value(t, built.kind, core.Document_Error_Kind.None)
	plan, _ := json.plan_make(Deep, allocator = context.temp_allocator)
	d: Deep
	e := typed.unmarshal(&doc, core.ROOT, &d, &plan, {}, context.temp_allocator)
	testing.expect_value(t, e.kind, core.Typed_Error_Kind.None)
	n := 0
	for p := &d; p != nil; p = p.d {
		n += 1
	}
	testing.expect_value(t, n, depth)
}

@(private = "file")
inside :: proc(p: rawptr, bytes: []u8) -> bool {
	return uintptr(p) >= uintptr(raw_data(bytes)) && uintptr(p) < uintptr(raw_data(bytes)) + uintptr(len(bytes))
}

@(test)
a_read_borrows_the_source_and_not_the_document :: proc(t: ^testing.T) {
	text := `{"keys":["plain","esc\n"],"s":"also plain","m":{"k":"v","e\t":"w"},"r":{"a":1},"n":12345678901234567890123}`
	src := transmute([]u8)text
	Holder :: struct {
		keys: []string,
		s:    string,
		m:    map[string]string,
		r:    typed.Raw,
		n:    typed.Number_Text,
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	scratch := mem.dynamic_arena_allocator(&arena)
	plan, _ := json.plan_make(Holder, allocator = context.temp_allocator)
	defer free_all(context.temp_allocator)

	// Without `borrow_strings` nothing the target holds is the source's or the document's.
	doc, _ := json.build(src, json.Spec.Json, allocator = context.temp_allocator)
	copied: Holder
	testing.expect_value(t, typed.unmarshal(&doc, core.ROOT, &copied, &plan, {}, scratch).kind, core.Typed_Error_Kind.None)
	testing.expect(t, !inside(raw_data(copied.keys[0]), src) && !inside(raw_data(copied.s), src) && !inside(raw_data(string(copied.r)), src) && !inside(raw_data(string(copied.n)), src))

	// With it, a string with nothing to decode is a slice of the source, and a decoded one is the read's.
	borrowed: Holder
	testing.expect_value(t, typed.unmarshal(&doc, core.ROOT, &borrowed, &plan, {borrow_strings = true}, scratch).kind, core.Typed_Error_Kind.None)
	testing.expect(t, inside(raw_data(borrowed.keys[0]), src) && inside(raw_data(borrowed.s), src) && inside(raw_data(string(borrowed.r)), src) && inside(raw_data(string(borrowed.n)), src))
	testing.expect(t, !inside(raw_data(borrowed.keys[1]), src))
	for k, v in borrowed.m {
		testing.expect(t, inside(raw_data(v), src))
		if len(k) != 1 {
			testing.expect(t, !inside(raw_data(k), src))
		}
	}

	// Destroying the document leaves the target whole, since it never pointed into the document's nodes.
	core.destroy(&doc)
	testing.expect_value(t, borrowed.keys[0], "plain")
	testing.expect_value(t, borrowed.keys[1], "esc\n")
	testing.expect_value(t, borrowed.s, "also plain")
	testing.expect_value(t, borrowed.m["e\t"], "w")
	testing.expect_value(t, borrowed.r, typed.Raw(`{"a":1}`))
	testing.expect_value(t, string(borrowed.n), "12345678901234567890123")
	testing.expect_value(t, copied.keys[1], "esc\n")
}
