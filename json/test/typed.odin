package json_tests

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import json ".."
import walktest "../../walktest"

// The typed read: each field rule, each refusal, the collecting sink and who owns what a failed read leaves.

// Reads `text` into `target` and, unless the read collects or refuses duplicates, the root of its document into a
// copy of `target`, which must give the same value and refusal.
@(private = "file")
read :: proc(t: ^testing.T, text: string, target: ^$T, opts := typed.Read_Options{}, loc := #caller_location) -> core.Error {
	src := transmute([]u8)text
	by_doc := target^
	e := json.unmarshal(src, json.Spec.Json, target, read = opts, opts = {}, allocator = context.temp_allocator)
	if opts.sink == nil && opts.dups != .Refuse {
		plan, planned := json.plan_make(T, allocator = context.temp_allocator)
		doc, built := json.build(src, json.Spec.Json, allocator = context.temp_allocator)
		if planned == nil && built == nil {
			errors_agree(t, walktest.typed_of(e), walktest.typed_of(typed.unmarshal(&doc, core.ROOT, &by_doc, &plan, opts, context.temp_allocator)), text, loc)
			testing.expectf(t, value_text(target^) == value_text(by_doc), "%s: a document gives %v, a text %v", text, value_text(by_doc), value_text(target^), loc = loc)
		}
	}
	return e
}

@(private = "file")
Point :: struct {
	x, y: i32,
}

@(private = "file")
Color :: enum u8 {
	Red,
	Green,
	Blue = 7,
}

@(test)
absent_member_keeps_the_destination :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	p := Point{1, 2}
	e := read(t, `{"y":5}`, &p)
	walktest.expect_nil(t, e)
	testing.expect_value(t, p, Point{1, 5})
}

@(test)
members_in_any_order_and_repeated :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: Point,
		b: []i32,
		c: string,
	}
	s: S
	e := read(t, `{"c":"x","b":[1],"a":{"x":1},"b":[2,3],"a":{"y":2},"c":"y"}`, &s)
	walktest.expect_nil(t, e)
	// A later occurrence replaces the earlier one whole, so `a.x` does not survive.
	testing.expect_value(t, s.a, Point{0, 2})
	testing.expect_value(t, len(s.b), 2)
	testing.expect_value(t, s.b[1], 3)
	testing.expect_value(t, s.c, "y")
}

@(test)
first_occurrence_is_kept_and_later_ones_judged :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: Point,
		m: map[string]i32,
		n: i32,
	}
	opts := typed.Read_Options {
		dups = core.Duplicates.First,
	}
	s: S
	e := read(t, `{"n":1,"a":{"x":1},"m":{"k":1,"k":2},"a":{"y":2},"n":2}`, &s, opts)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s.a, Point{1, 0})
	testing.expect_value(t, s.n, 1)
	testing.expect_value(t, s.m["k"], 1)
	s = {}
	e = read(t, `{"n":1,"n":"no"}`, &s, opts)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Wrong_Kind)
}

@(test)
refuse_duplicates_reads_the_whole_text_first :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	v: map[string]i32
	e := read(t, `{"a":{"b":1,"b":2}}`, &v, {dups = .Refuse})
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Duplicate_Key)
	testing.expect_value(t, walktest.at_of(e), 12)
	// A collecting read holds what it returns, the text's fault included.
	for text in ([]string{`{"a":{"b":1,"b":2}}`, `{"a":01}`}) {
		sink: typed.Sink
		sink.errors.allocator = context.temp_allocator
		e = read(t, text, &v, {dups = .Refuse, sink = &sink})
		testing.expect_value(t, len(sink.errors), 1)
		testing.expect_value(t, sink.errors[0].kind, walktest.typed_kind(e))
	}
}

@(test)
a_collecting_read_with_no_errors_allocator_uses_the_reads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32,
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	texts := []string{`{"a":"x"}`, `{"a":01}`, `{"a":1,"a":2}`}
	for text in texts {
		s: S
		sink: typed.Sink
		e := json.unmarshal(transmute([]u8)text, json.Spec.Json, &s, read = {dups = .Refuse, sink = &sink}, opts = {}, allocator = mem.tracking_allocator(&track))
		testing.expect(t, e != nil, text)
		testing.expect_value(t, len(sink.errors), 1)
		testing.expect(t, sink.errors.allocator.data == &track, text)
		delete(sink.errors)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
members_past_the_tracked_word :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	W :: struct {
		f0, f1, f2, f3, f4, f5, f6, f7, f8, f9:          i32,
		g0, g1, g2, g3, g4, g5, g6, g7, g8, g9:          i32,
		h0, h1, h2, h3, h4, h5, h6, h7, h8, h9:          i32,
		i0, i1, i2, i3, i4, i5, i6, i7, i8, i9:          i32,
		j0, j1, j2, j3, j4, j5, j6, j7, j8, j9:          i32,
		k0, k1, k2, k3, k4, k5, k6, k7, k8, k9:          i32,
		l0, l1, l2:                                      i32,
		last:                                            Point,
		tail:                                            Point `json:"tail,required"`,
	}
	w: W
	e := read(t, `{"last":{"x":1},"f0":1,"tail":{"x":2},"last":{"y":3}}`, &w)
	walktest.expect_nil(t, e)
	testing.expect_value(t, w.last, Point{0, 3})
	testing.expect_value(t, w.tail.x, 2)
	w = {}
	e = read(t, `{"f0":1,"last":{}}`, &w)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Missing_Field)
	testing.expect_value(t, string(walktest.typed_of(e).steps[walktest.typed_of(e).n_steps - 1].(core.Name)), "tail")
}

@(test)
tags_flatten_and_rename :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Base :: struct {
		base_id: i32,
	}
	S :: struct {
		using base: Base,
		long_name:  i32,
		out:        i32 `json:"-"`,
		shared:     i32 `stury:"common"`,
		own:        i32 `json:"mine"`,
	}
	s: S
	e := read(t, `{"base_id":1,"long_name":2,"out":3,"common":4,"mine":5}`, &s)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s, S{base = {1}, long_name = 2, shared = 4, own = 5})

	plan, err := json.plan_make(S, plan = {rename = .Camel})
	walktest.expect_nil(t, err)
	defer typed.plan_destroy(&plan)
	s = {}
	src := `{"baseId":1,"longName":2,"long_name":9}`
	e = json.unmarshal(transmute([]u8)src, json.Spec.Json, &s, &plan)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s.long_name, 2)
	testing.expect_value(t, s.base_id, 1)
}

@(test)
a_bad_tag_or_a_clash_is_a_plan_error :: proc(t: ^testing.T) {
	Bad :: struct {
		a: i32 `json:"a,nonsense"`,
	}
	Clash :: struct {
		a: i32 `json:"same"`,
		b: i32 `json:"same"`,
	}
	_, e := json.plan_make(Bad)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Bad_Tag)
	_, e = json.plan_make(Clash)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Unsupported)
}

@(test)
a_plan_refusal_names_the_path_to_the_member :: proc(t: ^testing.T) {
	Leaf :: struct {
		f: proc(),
	}
	Mid :: struct {
		leaf: Leaf,
	}
	Arm :: struct {
		u: union {
			proc(),
		},
	}
	Unknown :: struct {
		rest: map[string]typed.Raw `json:",unknown,required"`,
	}
	_, e := json.plan_make(struct {
		top: Mid,
	})
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Unsupported)
	testing.expect_value(t, walktest.typed_of(e).n_steps, 3)
	if walktest.typed_of(e).n_steps == 3 {
		testing.expect_value(t, string(walktest.typed_of(e).steps[0].(core.Name)), "top")
		testing.expect_value(t, string(walktest.typed_of(e).steps[1].(core.Name)), "leaf")
		testing.expect_value(t, string(walktest.typed_of(e).steps[2].(core.Name)), "f")
	}
	_, e = json.plan_make(Arm)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Unsupported)
	testing.expect_value(t, walktest.typed_of(e).n_steps, 1)
	if walktest.typed_of(e).n_steps == 1 {
		testing.expect_value(t, string(walktest.typed_of(e).steps[0].(core.Name)), "u")
	}
	_, e = json.plan_make(Unknown)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Bad_Tag)
}

@(test)
a_plan_for_another_type_is_refused :: proc(t: ^testing.T) {
	plan, err := json.plan_make(Point)
	walktest.expect_nil(t, err)
	defer typed.plan_destroy(&plan)
	src := `{}`
	wrong: Color
	e := json.unmarshal(transmute([]u8)src, json.Spec.Json, &wrong, &plan)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Plan_Mismatch)
	var: ^Point
	e = json.unmarshal(transmute([]u8)src, json.Spec.Json, var, &plan)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Bad_Option)
}

@(test)
refusal_names_the_value :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		l: []Point,
		m: map[string]Point,
	}
	s: S
	e := read(t, `{"l":[{"x":1},{"y":"no"}]}`, &s)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, walktest.at_of(e), 19)
	testing.expect_value(t, walktest.typed_of(e).n_steps, 3)
	testing.expect_value(t, string(walktest.typed_of(e).steps[0].(core.Name)), "l")
	testing.expect_value(t, int(walktest.typed_of(e).steps[1].(core.Index)), 1)
	testing.expect_value(t, string(walktest.typed_of(e).steps[2].(core.Name)), "y")

	src := `{"m":{"key":{"x":300000000000}}}`
	s = {}
	e = read(t, src, &s)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Above_Maximum)
	testing.expect_value(t, string(walktest.typed_of(e).steps[1].(core.Name)), "key")
	b := strings.builder_make(context.temp_allocator)
	testing.expect(t, core.render(strings.to_writer(&b), transmute([]u8)src, e) == nil)
	testing.expect_value(t, strings.to_string(b), "1:18: 300000000000 is out of range for i32 at .m.key.x")
	b2 := strings.builder_make(context.temp_allocator)
	testing.expect(t, core.write_code(strings.to_writer(&b2), e) == nil)
	testing.expect_value(t, strings.to_string(b2), "typed.above_maximum")
}

@(test)
a_deep_path_keeps_its_innermost_steps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	v: [][][][][][][][][][]i32
	e := read(t, `[[[[[[[[[["no"]]]]]]]]]]`, &v)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, walktest.typed_of(e).n_steps, core.MAX_ERROR_STEPS)
	testing.expect(t, walktest.typed_of(e).truncated)
}

@(test)
a_walk_fault_is_kept_whole :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	p: Point
	e := read(t, `{"x":1,}`, &p)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Walk)
	testing.expect_value(t, walktest.at_of(e), (walktest.fault_of(e).? or_else core.Fault{}).at)
	testing.expect(t, walktest.fault_of(e) != nil)
}

@(test)
numbers_at_each_width :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i8,
		b: u8,
		c: i64,
		d: u64,
		e: f32,
		f: f64,
	}
	s: S
	e := read(t, `{"a":-128,"b":255,"c":-9223372036854775808,"d":18446744073709551615,"e":0.1,"f":-0}`, &s)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s.a, -128)
	testing.expect_value(t, s.b, 255)
	testing.expect_value(t, s.c, min(i64))
	testing.expect_value(t, s.d, max(u64))
	testing.expect_value(t, s.e, 0.1)
	testing.expect_value(t, transmute(u64)s.f, u64(1) << 63)
	for text in ([]string{`{"a":128}`, `{"b":-1}`, `{"c":9223372036854775808}`, `{"d":18446744073709551616}`, `{"f":1e400}`, `{"e":1e39}`}) {
		kind := walktest.typed_kind(read(t, text, &s))
		testing.expectf(t, kind == (.Below_Minimum if text == `{"b":-1}` else .Above_Maximum), "%s: %v", text, kind)
	}
	walktest.expect_kind(t, read(t, `{"a":1.0}`, &s), core.Typed_Error_Kind.Wrong_Kind)
	walktest.expect_kind(t, read(t, `{"a":null}`, &s), core.Typed_Error_Kind.Wrong_Kind)
}

@(test)
json5_non_finite_numbers_fill_floats :: proc(t: ^testing.T) {
	S :: struct {
		f: f64,
		g: f32,
	}
	s: S
	src := transmute([]u8)string(`{f: -Infinity, g: Infinity}`)
	walktest.expect_nil(t, json.unmarshal(src, json.Spec.Json5, &s, read = {}, opts = {}, allocator = context.temp_allocator))
	testing.expect_value(t, s.f, math.inf_f64(-1))
	testing.expect_value(t, s.g, math.inf_f32(1))
	src = transmute([]u8)string(`{f: NaN, g: -NaN}`)
	walktest.expect_nil(t, json.unmarshal(src, json.Spec.Json5, &s, read = {}, opts = {}, allocator = context.temp_allocator))
	testing.expect(t, math.is_nan(s.f) && math.is_nan(f64(s.g)))
	src = transmute([]u8)string(`{f: Infinity}`)
	e := json.unmarshal(src, json.Spec.Json5, &s, read = {}, opts = {refuse_non_finite = true}, allocator = context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Walk)
	for text in ([]string{`{f: 1e400}`, `{g: 1e39}`, `{g: 0xffffffffffffffffffffffffffffffffffff}`}) {
		kind := walktest.typed_kind(json.unmarshal(transmute([]u8)text, json.Spec.Json5, &s, read = {}, opts = {}, allocator = context.temp_allocator))
		testing.expectf(t, kind == .Above_Maximum, "%s: %v", text, kind)
	}
}

@(test)
lists_arrays_and_their_lengths :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: [2]i32,
		f: [dynamic; 2]i32,
		d: [dynamic]string,
	}
	s: S
	e := read(t, `{"a":[1,2],"f":[3],"d":["x","y"]}`, &s)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s.a, [2]i32{1, 2})
	testing.expect_value(t, len(s.f), 1)
	testing.expect_value(t, s.f[0], 3)
	testing.expect_value(t, s.d[1], "y")
	walktest.expect_kind(t, read(t, `{"a":[1]}`, &s), core.Typed_Error_Kind.Too_Few)
	walktest.expect_kind(t, read(t, `{"a":[1,2,3]}`, &s), core.Typed_Error_Kind.Too_Many)
	walktest.expect_kind(t, read(t, `{"f":[1,2,3]}`, &s), core.Typed_Error_Kind.Too_Many)
	one: [1]string
	testing.expect_value(t, walktest.at_of(read(t, `["a","b"]`, &one)), 5)
}

@(test)
enums_bit_sets_and_map_keys :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		e:  Color,
		s:  bit_set[Color; u8],
		b:  bit_set[0 ..< 10],
		mi: map[i16]bool,
		me: map[Color]bool,
	}
	s: S
	e := read(t, `{"e":"Blue","s":["Red","Blue"],"b":[1,9],"mi":{"-3":true},"me":{"Green":true}}`, &s)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s.e, Color.Blue)
	testing.expect(t, .Blue in s.s && .Green not_in s.s)
	testing.expect(t, 9 in s.b)
	testing.expect(t, s.mi[-3])
	testing.expect(t, s.me[.Green])
	walktest.expect_kind(t, read(t, `{"e":"Pink"}`, &s), core.Typed_Error_Kind.Not_A_Member)
	walktest.expect_kind(t, read(t, `{"b":[10]}`, &s), core.Typed_Error_Kind.Above_Maximum)
	// An integer past `i64` is past the maximum, as it is for an integer field, and a fraction is no integer.
	walktest.expect_kind(t, read(t, `{"b":[99999999999999999999]}`, &s), core.Typed_Error_Kind.Above_Maximum)
	walktest.expect_kind(t, read(t, `{"b":[1.0]}`, &s), core.Typed_Error_Kind.Wrong_Kind)
	walktest.expect_kind(t, read(t, `{"mi":{"x":true}}`, &s), core.Typed_Error_Kind.Out_Of_Range)
	narrow: map[i8]i32
	walktest.expect_kind(t, read(t, `{"300":1}`, &narrow), core.Typed_Error_Kind.Above_Maximum)
	ints, err := json.plan_make(Color, plan = {enums = .Int})
	walktest.expect_nil(t, err)
	defer typed.plan_destroy(&ints)
	src := `7`
	c: Color
	e = json.unmarshal(transmute([]u8)src, json.Spec.Json, &c, &ints)
	walktest.expect_nil(t, e)
	testing.expect_value(t, c, Color.Blue)
}

@(test)
pointers_maybes_cstrings :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		p: ^Point,
		l: ^[]i32,
		m: Maybe(i32),
		c: cstring,
	}
	held := Point{1, 2}
	s := S {
		p = &held,
	}
	e := read(t, `{"p":{"y":9},"l":[1,2],"m":4,"c":"aA"}`, &s)
	walktest.expect_nil(t, e)
	// A pointer the destination holds is read through.
	testing.expect(t, s.p == &held)
	testing.expect_value(t, held, Point{1, 9})
	testing.expect_value(t, len(s.l^), 2)
	testing.expect_value(t, s.m.?, 4)
	testing.expect_value(t, string(s.c), "aA")
	e = read(t, `{"p":null,"m":null,"c":null}`, &s)
	walktest.expect_nil(t, e)
	testing.expect(t, s.p == nil && s.m == nil && s.c == nil)
	walktest.expect_kind(t, read(t, `{"c":"a\u0000"}`, &s), core.Typed_Error_Kind.Out_Of_Range)
}

@(test)
unions_by_class_and_tag :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	U :: union {
		i64,
		string,
		[]i32,
	}
	us: []U
	e := read(t, `[1,"s",[2],null]`, &us)
	walktest.expect_nil(t, e)
	testing.expect_value(t, us[0].(i64), 1)
	testing.expect_value(t, us[1].(string), "s")
	testing.expect_value(t, us[2].([]i32)[0], 2)
	testing.expect(t, us[3] == nil)
	walktest.expect_kind(t, read(t, `[true]`, &us), core.Typed_Error_Kind.Wrong_Kind)

	A :: struct {
		x: i32,
	}
	B :: struct {
		y: string,
	}
	T :: union {
		A,
		B,
	}
	plan, err := json.plan_make(T, plan = {union_tag = "type", tag_names = {{B, "bee"}}})
	walktest.expect_nil(t, err)
	defer typed.plan_destroy(&plan)
	check := proc(t: ^testing.T, plan: ^typed.Plan, text: string, want: core.Typed_Error_Kind) -> (v: T) {
		e := json.unmarshal(transmute([]u8)text, json.Spec.Json, &v, plan, read = {}, opts = {}, allocator = context.temp_allocator)
		walktest.expect_kind(t, e, want)
		return
	}
	v := check(t, plan = &plan, text = `{"y":"s","type":"bee"}`, want = .None)
	testing.expect_value(t, v.(B).y, "s")
	v = check(t, plan = &plan, text = `{"type":"A","x":1}`, want = .None)
	testing.expect_value(t, v.(A).x, 1)
	check(t, plan = &plan, text = `{"x":1}`, want = .Missing_Tag)
	check(t, plan = &plan, text = `{"type":"A","type":"A"}`, want = .Repeated_Tag)
	check(t, plan = &plan, text = `{"type":"C"}`, want = .Not_A_Member)
	// The walk's fault wins over what a broken text makes of the tag.
	check(t, plan = &plan, text = `{"x":1,}`, want = .Walk)
	// A collecting read ends at that fault, which it holds once.
	sink: typed.Sink
	sink.errors.allocator = context.temp_allocator
	broken := `{"x":01,"type":"A"}`
	bv: T
	be := json.unmarshal(transmute([]u8)broken, json.Spec.Json, &bv, &plan, read = {sink = &sink}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_kind(t, be, core.Typed_Error_Kind.Walk)
	testing.expect_value(t, len(sink.errors), 1)
	// Under `.Refuse` the tag's key is known in a tagged arm only.
	H :: struct {
		t: T,
	}
	hp, herr := json.plan_make(H, plan = {union_tag = "type"})
	walktest.expect_nil(t, herr)
	defer typed.plan_destroy(&hp)
	inside := `{"t":{"type":"A","x":1}}`
	outside := `{"type":1}`
	h: H
	he := json.unmarshal(transmute([]u8)inside, json.Spec.Json, &h, &hp, read = {unknown = .Refuse}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, he)
	he = json.unmarshal(transmute([]u8)outside, json.Spec.Json, &h, &hp, read = {unknown = .Refuse}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_kind(t, he, core.Typed_Error_Kind.Unknown_Field)
}

@(test)
a_tagged_arm_may_not_key_a_member_as_the_tag :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	B :: struct {
		y: i32,
	}
	Renamed :: struct {
		kind: string `json:"type"`,
	}
	Inner :: struct {
		type: string,
	}
	Flattened :: struct {
		using inner: Inner,
	}
	Spelled :: struct {
		the_type: string,
	}
	Keyed_Apart :: struct {
		type: string `json:"kind"`,
	}
	Left_Out :: struct {
		type: string `json:"-"`,
	}
	refused := []struct {
		T:      typeid,
		tag:    string,
		rename: typed.Rename,
	} {
		{union {Renamed, B}, "type", .None},
		{union {Flattened, B}, "type", .None},
		{union {Spelled, B}, "theType", .Camel},
	}
	for c in refused {
		_, err := json.plan_make(c.T, plan = {union_tag = c.tag, rename = c.rename}, allocator = context.temp_allocator)
		walktest.expect_kind(t, err, core.Typed_Error_Kind.Bad_Tag)
	}
	for T in ([]typeid{union {Keyed_Apart, B}, union {Left_Out, B}}) {
		_, err := json.plan_make(T, plan = {union_tag = "type"}, allocator = context.temp_allocator)
		walktest.expect_nil(t, err)
	}
}

@(test)
an_any_is_written_and_refused_as_a_read_target :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for text in ([?]string{`{"a":[1,"s"]}`, `null`, `1`}) {
		v: any
		walktest.expect_kind(t, read(t, text, &v), core.Typed_Error_Kind.Unsupported)
	}
	S :: struct {
		a: any,
	}
	n := 7
	out, written := json.marshal(S{n}, .Json, allocator = context.temp_allocator)
	walktest.expect_nil(t, written)
	testing.expect_value(t, string(out), `{"a":7}`)
}

@(test)
raw_holds_the_span :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: typed.Raw,
		b: []typed.Raw,
		c: Point,
	}
	s: S
	text := `{"a":{"k": [1, {}]},"b":["s\n",2,[3],null],"c":{"x":1}}`
	e := read(t, text, &s)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s.a, typed.Raw(`{"k": [1, {}]}`))
	testing.expect_value(t, s.b[0], typed.Raw(`"s\n"`))
	testing.expect_value(t, s.b[2], typed.Raw(`[3]`))
	testing.expect_value(t, s.b[3], typed.Raw(`null`))
	testing.expect_value(t, s.c.x, 1)
	// A malformed value inside is the walk's to refuse.
	walktest.expect_kind(t, read(t, `{"a":{"k":01}}`, &s), core.Typed_Error_Kind.Walk)
	s = {}
	e = read(t, text, &s, {borrow_strings = true})
	walktest.expect_nil(t, e)
	testing.expect(t, raw_data(string(s.a)) == raw_data(text)[5:])
}

@(test)
unknown_members_capture_or_refuse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a:    i32,
		rest: map[string]typed.Raw `json:"rest,unknown"`,
		b:    i32,
	}
	s: S
	e := read(t, `{"x":[1,2],"a":1,"y":{"k":"v"},"b":2,"z":3}`, &s)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s.a, 1)
	testing.expect_value(t, s.b, 2)
	testing.expect_value(t, len(s.rest), 3)
	testing.expect_value(t, s.rest["y"], typed.Raw(`{"k":"v"}`))
	testing.expect_value(t, s.rest["z"], typed.Raw(`3`))

	p: Point
	e = read(t, `{"x":1,"nope":2}`, &p, {unknown = .Refuse})
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Unknown_Field)
	testing.expect_value(t, string(walktest.typed_of(e).steps[walktest.typed_of(e).n_steps - 1].(core.Name)), "nope")
	walktest.expect_kind(t, read(t, `{"":1}`, &p, {unknown = .Refuse}), core.Typed_Error_Kind.Unknown_Field)
}

@(test)
wide_bit_sets_round_trip_and_required_omitempty_is_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Wide :: struct {
		b: bit_set[0 ..= 127; u128],
	}
	w: Wide
	e := read(t, `{"b":[0,127]}`, &w)
	walktest.expect_nil(t, e)
	testing.expect_value(t, w.b, bit_set[0 ..= 127; u128]{0, 127})

	Bad :: struct {
		a: i32 `json:"a,required,omitempty"`,
	}
	b: Bad
	walktest.expect_kind(t, read(t, `{"a":1}`, &b), core.Typed_Error_Kind.Unsupported)
}

@(test)
type_hooks_read_whole_values :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Hex :: struct {
		n: int,
	}
	S :: struct {
		v, w: Hex,
		l:    []Hex,
	}
	hook := proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
		if v.decoded == "bad" {
			return .Out_Of_Range
		}
		(^Hex)(dest).n = len(v.text)
		return nil
	}
	plan, err := json.plan_make(S, plan = {hooks = {{type = Hex, read = hook}}})
	walktest.expect_nil(t, err)
	defer typed.plan_destroy(&plan)
	s: S
	src := `{"v":"a\n","w":{"k":[1]},"l":[12,[3]]}`
	e := json.unmarshal(transmute([]u8)src, json.Spec.Json, &s, &plan, read = {}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s.v.n, 5)
	testing.expect_value(t, s.w.n, 9)
	testing.expect_value(t, s.l[0].n, 2)
	testing.expect_value(t, s.l[1].n, 3)
	src = `{"v":"bad"}`
	e = json.unmarshal(transmute([]u8)src, json.Spec.Json, &s, &plan, read = {}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Out_Of_Range)
}

@(test)
strings_are_copied_unless_borrowed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `["plain","a\nb"]`
	src := transmute([]u8)text
	v: []string
	walktest.expect_nil(t, read(t, text, &v))
	testing.expect(t, raw_data(v[0]) != raw_data(src[2:]))
	w: []string
	walktest.expect_nil(t, read(t, text, &w, {borrow_strings = true}))
	testing.expect(t, raw_data(w[0]) == raw_data(src[2:]))
	testing.expect_value(t, w[1], "a\nb")
}

@(test)
collecting_reads_past_each_refusal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32,
		l: []i32,
		p: Point,
		n: string `json:"n,required"`,
	}
	sink := typed.Sink {
		errors = make([dynamic]core.Typed_Refusal, context.temp_allocator),
	}
	s := S {
		a = 7,
	}
	e := read(t, `{"a":"no","l":[1,"x",3],"p":{"x":"y","y":2},"q":1}`, &s, {sink = &sink})
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, len(sink.errors), 4)
	testing.expect_value(t, sink.errors[0].at, 5)
	testing.expect_value(t, int(sink.errors[1].steps[1].(core.Index)), 1)
	testing.expect_value(t, string(sink.errors[2].steps[1].(core.Name)), "x")
	testing.expect_value(t, sink.errors[3].kind, core.Typed_Error_Kind.Missing_Field)
	// What was refused is left, and the rest is read: the refused element is zero and holds its place.
	testing.expect_value(t, s.a, 7)
	testing.expect_value(t, len(s.l), 3)
	testing.expect_value(t, s.l[1], 0)
	testing.expect_value(t, s.l[2], 3)
	testing.expect_value(t, s.p.y, 2)

	few := typed.Sink {
		errors     = make([dynamic]core.Typed_Refusal, context.temp_allocator),
		max_errors = 2,
	}
	l: []i32
	read(t, `["a","b","c","d"]`, &l, {sink = &few})
	testing.expect_value(t, len(few.errors), 2)
	testing.expect(t, few.truncated)
	testing.expect_value(t, len(l), 4)

	// The walk still judges a passed-over value.
	sink.errors = make([dynamic]core.Typed_Refusal, context.temp_allocator)
	e = read(t, `{"a":[01]}`, &s, {sink = &sink})
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, sink.errors[len(sink.errors) - 1].kind, core.Typed_Error_Kind.Walk)
}

@(test)
what_a_refused_read_allocated_stays_reachable :: proc(t: ^testing.T) {
	Row :: struct {
		s: string,
		l: []string,
		m: map[string]string,
		p: ^Point,
	}
	free_row :: proc(r: Row) {
		delete(r.s)
		for s in r.l {
			delete(s)
		}
		delete(r.l)
		for k, v in r.m {
			delete(k)
			delete(v)
		}
		delete(r.m)
		free(r.p)
	}
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	alloc := mem.tracking_allocator(&tracking)
	plan, _ := json.plan_make([]Row, allocator = context.temp_allocator)
	defer free_all(context.temp_allocator)
	texts := []string {
		`[{"s":"a","l":["b","c"],"m":{"k":"v"},"p":{"x":1}},{"s":"d","l":["e",1]}]`,
		`[{"s":"a","l":["b","c","d","e","f","g","h","i","j"]`,
		`[{"m":{"k":"v","j":2}}]`,
		`[{"p":{"x":"no"}}]`,
		`[{"s":"a"},7]`,
	}
	for text in texts {
		for from_document in ([]bool{false, true}) {
			rows: []Row
			e: core.Error
			if from_document {
				doc, _ := json.build(transmute([]u8)text, json.Spec.Json, allocator = context.temp_allocator)
				e = typed.unmarshal(&doc, core.ROOT, &rows, &plan, {}, alloc)
			} else {
				e = json.unmarshal(transmute([]u8)text, json.Spec.Json, &rows, &plan, read = {}, opts = {}, allocator = alloc)
			}
			testing.expect(t, e != nil)
			for r in rows {
				context.allocator = alloc
				free_row(r)
			}
			delete(rows, alloc)
			testing.expect_value(t, len(tracking.allocation_map), 0)
			testing.expect_value(t, len(tracking.bad_free_array), 0)
		}
	}
}

@(test)
json5_and_jsonc_read_alike :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32,
		b: f64,
		c: string,
	}
	want := S{5, 16, "x"}
	s: S
	src5 := `{a:+5.,'b':0x10,c:'x',/*c*/}`
	e := json.unmarshal(transmute([]u8)src5, json.Spec.Json5, &s, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s, want)
	s = {}
	srcc := `{"a":5,"b":16,/*c*/"c":"x",}`
	e = json.unmarshal(transmute([]u8)srcc, json.Spec.Jsonc, &s, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s, want)
	// A skipped member takes a spelling of its own and leaves the cursor where it stood.
	s = {}
	src5 = `{a:1,zz:-0x10,b:2,zz:1.,c:'y'}`
	e = json.unmarshal(transmute([]u8)src5, json.Spec.Json5, &s, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s, S{1, 2, "y"})
	// A fraction or an exponent is no integer in any spelling, however far out of range.
	for text in ([]string{`{a:1e9999}`, `{a:+1e9999}`, `{a:.5e9999}`}) {
		kind := walktest.typed_kind(json.unmarshal(transmute([]u8)text, json.Spec.Json5, &s, allocator = context.temp_allocator))
		testing.expectf(t, kind == .Wrong_Kind, "%s: %v", text, kind)
	}
	// A bit_set reads an integer in any spelling a plain field does.
	B :: struct {
		b: bit_set[0 ..< 10],
	}
	bits: B
	src5 = `{b:[0,5.,+7]}`
	e = json.unmarshal(transmute([]u8)src5, json.Spec.Json5, &bits, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, bits.b, bit_set[0 ..< 10]{0, 5, 7})
}

@(test)
max_depth_past_the_stack_form :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Deep :: struct {
		d: ^Deep,
	}
	depth := core.MAX_DEPTH + 100
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, `{"d":`)
	}
	strings.write_string(&b, "null")
	for _ in 0 ..< depth {
		strings.write_byte(&b, '}')
	}
	d: Deep
	src := transmute([]u8)strings.to_string(b)
	e := json.unmarshal(src, json.Spec.Json, &d, opts = json.Options{max_depth = u32(depth)}, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	e = json.unmarshal(src, json.Spec.Json, &d, allocator = context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Walk)
}

@(private = "file")
Wide :: struct {
	a0, a1, a2, a3, a4, a5, a6, a7, a8, a9: i32,
	b0, b1, b2, b3, b4, b5, b6, b7, b8, b9: i32,
	c0, c1, c2, c3, c4, c5, c6, c7, c8, c9: i32,
	d0, d1, d2, d3, d4, d5, d6, d7, d8, d9: i32,
	e0, e1, e2, e3, e4, e5, e6, e7, e8, e9: i32,
	f0, f1, f2, f3, f4, f5, f6, f7, f8, f9: i32,
	g0, g1, g2, g3, g4:                     i32,
}

@(test)
a_struct_past_the_tracked_word_starts_with_no_repeats :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: []Wide
	e := read(t, `[{"g4":1,"g4":2},{"g4":3}]`, &w, {dups = core.Duplicates.First})
	walktest.expect_nil(t, e)
	testing.expect_value(t, w[0].g4, 1)
	testing.expect_value(t, w[1].g4, 3)
}

@(private = "file")
Hooked :: distinct i32

@(private = "file")
read_hooked :: proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
	(^Hooked)(dest)^ = Hooked(len(v.text))
	return nil
}

@(test)
a_repeat_under_first_leaves_the_next_elements_hook :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		h: Hooked,
	}
	plan, err := json.plan_make([]S, plan = {hooks = {{type = Hooked, read = read_hooked}}}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	s: []S
	src := `[{"h":1,"h":22},{"h":333}]                `
	e := json.unmarshal(transmute([]u8)src, json.Spec.Json, &s, &plan, read = {dups = core.Duplicates.First}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s[1].h, Hooked(3))
}

@(private = "file")
read_onto_held :: proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
	(^Hooked)(dest)^ = (^Hooked)(dest)^ * 10 + Hooked(len(v.text))
	return nil
}

@(test)
a_repeat_reads_alike_whichever_way_its_key_came :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		id: u64,
		x:  i32,
		s:  string,
		h:  Hooked,
	}
	plan, err := json.plan_make(S, plan = {hooks = {{type = Hooked, read = read_onto_held}}}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	PAD :: `,"pad":"................................"}`
	// A key in a text's last 16 bytes reaches the reader, and one before them the walk matches to the cursor.
	refused := []string{`{"x":3,"id":1,"x":"s"}`, `{"x":3,"id":1,"x":"s"` + PAD}
	hooked := []string{`{"h":1,"s":"a","h":22}`, `{"h":1,"s":"a","h":22` + PAD}
	for text in refused {
		by_text, by_doc: S
		walktest.expect_kind(t, json.unmarshal(transmute([]u8)text, json.Spec.Json, &by_text, &plan, read = {}, opts = {}, allocator = context.temp_allocator), core.Typed_Error_Kind.Wrong_Kind)
		doc, _ := json.build(transmute([]u8)text, json.Spec.Json, allocator = context.temp_allocator)
		walktest.expect_kind(t, typed.unmarshal(&doc, core.ROOT, &by_doc, &plan, {}, context.temp_allocator), core.Typed_Error_Kind.Wrong_Kind)
		testing.expect_value(t, by_text.x, 3)
		testing.expect_value(t, by_doc.x, 3)
	}
	for text in hooked {
		by_text, by_doc: S
		walktest.expect_nil(t, json.unmarshal(transmute([]u8)text, json.Spec.Json, &by_text, &plan, read = {}, opts = {}, allocator = context.temp_allocator))
		doc, _ := json.build(transmute([]u8)text, json.Spec.Json, allocator = context.temp_allocator)
		walktest.expect_nil(t, typed.unmarshal(&doc, core.ROOT, &by_doc, &plan, {}, context.temp_allocator))
		testing.expect_value(t, by_text.h, Hooked(12))
		testing.expect_value(t, by_doc.h, Hooked(12))
	}
}

@(test)
a_hooked_list_element_starts_zero :: proc(t: ^testing.T) {
	// An arena over bytes that are not zero, so an element left unwritten shows.
	buf := make([]u8, 1 << 12, context.temp_allocator)
	defer free_all(context.temp_allocator)
	for &b in buf {
		b = 0xab
	}
	arena: mem.Arena
	mem.arena_init(&arena, buf)
	plan, err := json.plan_make([]Hooked, plan = {hooks = {{type = Hooked, read = read_onto_held}}}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	l: []Hooked
	e := json.unmarshal(transmute([]u8)string(`[1,22,333]`), json.Spec.Json, &l, &plan, read = {}, opts = {}, allocator = mem.arena_allocator(&arena))
	walktest.expect_nil(t, e)
	if testing.expect_value(t, len(l), 3) {
		testing.expect_value(t, [3]Hooked{l[0], l[1], l[2]}, [3]Hooked{1, 2, 3})
	}
}

@(private = "file")
Hooked_Struct :: struct {
	n: int,
}

@(private = "file")
read_hooked_struct :: proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
	(^Hooked_Struct)(dest).n = len(v.text)
	return nil
}

@(test)
a_hook_with_no_data_keeps_the_callers_user_ptr :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	read :: proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
		(^Hooked_Struct)(dest).n = (^int)(context.user_ptr)^
		return nil
	}
	hooks := []typed.Type_Hook{{type = Hooked_Struct, read = read}}
	plan, err := json.plan_make(Hooked_Struct, plan = {hooks = hooks}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	seven := 7
	context.user_ptr = &seven
	h: Hooked_Struct
	walktest.expect_nil(t, json.unmarshal(transmute([]u8)string(`1`), json.Spec.Json, &h, &plan, read = {}, opts = {}, allocator = context.temp_allocator))
	testing.expect_value(t, h.n, 7)
}

@(test)
a_hooked_arm_takes_every_class :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	U :: union {
		Hooked_Struct,
	}
	hooks := []typed.Type_Hook{{type = Hooked_Struct, read = read_hooked_struct}}
	plan, err := json.plan_make(U, plan = {hooks = hooks}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	sources := []string{`"abc"`, `[1,2]`, `{"a":1}`, `true`, `12`}
	for src in sources {
		u: U
		e := json.unmarshal(transmute([]u8)src, json.Spec.Json, &u, &plan, read = {}, opts = {}, allocator = context.temp_allocator)
		walktest.expect_nil(t, e)
		testing.expect_value(t, u.(Hooked_Struct).n, len(src))
	}

	Beside :: union {
		Hooked_Struct,
		bool,
	}
	_, beside := json.plan_make(Beside, plan = {hooks = hooks}, allocator = context.temp_allocator)
	walktest.expect_kind(t, beside, core.Typed_Error_Kind.Ambiguous_Union)
}

@(test)
a_value_a_wrapper_refuses_has_the_wrappers_path :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		m: Maybe(i32),
		p: ^i32,
		u: union {
			i32,
			string,
		},
		w: Maybe(^Maybe(i32)),
	}
	sink: typed.Sink
	sink.errors.allocator = context.temp_allocator
	s: S
	read(t, `{"m":1.5,"p":1.5,"u":1.5,"w":1.5}`, &s, {sink = &sink})
	names := []string{"m", "p", "u", "w"}
	testing.expect_value(t, len(sink.errors), len(names))
	for &e, i in sink.errors {
		testing.expect_value(t, e.n_steps, 1)
		testing.expect_value(t, string(e.steps[0].(core.Name)), names[i])
	}
	l: []^i32
	e := read(t, `[1,2,1.5]`, &l)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, walktest.typed_of(e).n_steps, 1)
	testing.expect_value(t, int(walktest.typed_of(e).steps[0].(core.Index)), 2)
}

@(test)
a_collecting_read_leaves_a_wrapper_whose_element_it_refuses :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	S :: struct {
		m: Maybe(i32),
		p: ^Point,
		w: Maybe(^i32),
		u: union {
			i32,
			string,
		},
		l: []Maybe(i32),
		q: []^i32,
	}
	kept := i32(3)
	s := S {
		m = 5,
		w = &kept,
		u = "keep",
	}
	sink: typed.Sink
	sink.errors.allocator = context.temp_allocator
	src := `{"m":1.5,"p":[1],"w":"x","u":2.5,"l":[1,2.5],"q":[1,"x"]}`
	e := json.unmarshal(transmute([]u8)src, json.Spec.Json, &s, read = {sink = &sink}, opts = {}, allocator = alloc)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, len(sink.errors), 6)
	testing.expect_value(t, s.m, 5)
	testing.expect(t, s.p == nil)
	testing.expect(t, s.w == &kept)
	testing.expect_value(t, s.u.(string), "keep")
	testing.expect_value(t, len(s.l), 2)
	testing.expect(t, s.l[1] == nil)
	testing.expect_value(t, len(s.q), 2)
	testing.expect(t, s.q[1] == nil)
	free(s.q[0], alloc)
	delete(s.q, alloc)
	delete(s.l, alloc)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
a_missing_member_keeps_the_path_to_its_struct :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	In :: struct {
		b: i32 `json:",required"`,
	}
	S :: struct {
		a: In,
	}
	s: S
	e := read(t, `{"a":{}}`, &s)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Missing_Field)
	testing.expect_value(t, walktest.typed_of(e).n_steps, 2)
	testing.expect_value(t, string(walktest.typed_of(e).steps[0].(core.Name)), "a")
	testing.expect_value(t, string(walktest.typed_of(e).steps[1].(core.Name)), "b")
}

@(test)
a_capture_counts_the_members_read_since_the_last_key_found :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a:    i32 `json:",required"`,
		b:    i32 `json:",required"`,
		more: map[string]typed.Raw `json:",unknown"`,
	}
	s: S
	e := read(t, `{"z":1,"a":1,"b":2,"y":3}                `, &s)
	walktest.expect_nil(t, e)
}

@(test)
a_tolerated_string_may_decode_longer_than_it_is :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s: string
	src := "\"\xff\xff\""
	e := json.unmarshal(transmute([]u8)src, json.Spec.Json, &s, read = {}, opts = {tolerate = {.Invalid_Utf8}}, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, s, "��")
}

@(test)
a_refused_plan_leaves_nothing_allocated :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	U :: union {
		i32,
		string,
	}
	S :: struct {
		u:    U,
		bad:  i128,
		need: i32 `json:",required"`,
	}
	_, err := json.plan_make(S, plan = {}, allocator = mem.tracking_allocator(&track))
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Unsupported)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
a_plan_holds_no_string_of_its_options :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	A :: struct {
		x: i32,
	}
	B :: struct {
		y: i32,
	}
	U :: union {
		A,
		B,
	}
	tag := strings.clone("kind")
	name := strings.clone("first")
	plan, err := json.plan_make(U, plan = {union_tag = tag, tag_names = {{A, name}}})
	defer typed.plan_destroy(&plan)
	walktest.expect_nil(t, err)
	mem.zero(raw_data(tag), len(tag))
	mem.zero(raw_data(name), len(name))
	delete(tag)
	delete(name)
	u: U
	src := `{"kind":"first","x":1}`
	e := json.unmarshal(transmute([]u8)src, json.Spec.Json, &u, &plan, read = {}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
}

@(test)
an_enum_map_key_past_i64_is_no_member :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	E :: enum i64 {
		A = -1,
	}
	plan, err := json.plan_make(map[E]i32, plan = {enums = .Int}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	m: map[E]i32
	src := `{"18446744073709551615":1}`
	e := json.unmarshal(transmute([]u8)src, json.Spec.Json, &m, &plan, read = {}, opts = {}, allocator = context.temp_allocator)
	testing.expect(t, e != nil)
}

@(test)
a_plan_error_names_its_field_after_the_plan_is_gone :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	inner := Poison_Free_Alloc{inner = context.allocator}
	poisoned := runtime.Allocator{poison_free_alloc_proc, &inner}
	_, e := json.plan_make(struct {
			a: f16 `json:"alpha"`,
		}, plan = {}, allocator = poisoned)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Unsupported)
	testing.expect_value(t, walktest.typed_of(e).n_steps, 1)
	testing.expect_value(t, string(walktest.typed_of(e).steps[0].(core.Name)), "alpha")
}

@(test)
a_one_shot_read_error_names_its_field_after_the_plan_is_gone :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32 `json:"alpha"`,
		b: i32 `json:"beta"`,
	}
	inner := Poison_Free_Alloc{inner = context.temp_allocator}
	kept: typed.Sink
	kept.errors.allocator = context.temp_allocator
	{
		context.temp_allocator = runtime.Allocator{poison_free_alloc_proc, &inner}
		s: S
		src := `{"alpha":"x","beta":"y"}`
		e := json.unmarshal(transmute([]u8)src, json.Spec.Json, &s, read = {sink = &kept}, opts = {}, allocator = inner.inner)
		testing.expect_value(t, string(walktest.typed_of(e).steps[0].(core.Name)), "alpha")
	}
	testing.expect_value(t, len(kept.errors), 2)
	testing.expect_value(t, string(kept.errors[1].steps[0].(core.Name)), "beta")
}

// Numbers read into f32 with one rounding, streamed and from a document. The cases sit on or next to an f32 midpoint
// where the binary64 lands on the midpoint.
@(test)
f32_rounds_once :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	OUT :: 0x7f800000 // infinity, which a read refuses as out of range
	cases := []struct {
		text: string,
		want: u32,
	} {
		{"1.000000059604644775390625", 0x3f800000},
		{"1000000059604644775390625000001000000059e-39", 0x3f800001},
		{"1000000059604644775390624999998999999940e-39", 0x3f800000},
		{"1.000000178813934326171875", 0x3f800002},
		{"1000000178813934326171875000001000000178e-39", 0x3f800002},
		{"1000000178813934326171874999998999999821e-39", 0x3f800001},
		{"2101947696487225606385594374934874196920392912814773657635602425834686624028790902229957282543182373046875e-150", 0x00000002},
		{"2101947696487225606385594374936976144616e-84", 0x00000002},
		{"2101947696487225606385594374932772249223e-84", 0x00000001},
		{"700649232162408535461864791644958065640130970938257885878534141944895541342930300743319094181060791015625e-150", 0x00000000},
		{"7006492321624085354618647916456587148722e-85", 0x00000001},
		{"7006492321624085354618647916442574164079e-85", 0x00000000},
		{"340282356779733661637539395458142568448", OUT},
		{"3402823567797336616375393954578022860912e-1", 0x7f7fffff},
		{"0xe5c9908000000001", 0x5f65c991},
		{"0x2633b3dffffffff", 0x5c18cecf},
		{"0x100000100000000000000001", 0x6d800001},
		{"-0x100000100000000000000001", 0xed800001},
		{"0x1000000fffffffffffffffff", 0x6d800000},
		{"0x1000000000000000000000000000000000", OUT},
	}
	plan, _ := json.plan_make([]f32, allocator = context.temp_allocator)
	for c in cases {
		src := transmute([]u8)strings.concatenate({"[", c.text, "]"}, context.temp_allocator)
		streamed: []f32
		e := json.unmarshal(src, .Json5, &streamed, allocator = context.temp_allocator)
		doc, _ := json.build(src, .Json5, allocator = context.temp_allocator)
		built: []f32
		e2 := typed.unmarshal(&doc, core.ROOT, &built, &plan, allocator = context.temp_allocator)
		for got in ([]struct {v: []f32, e: core.Error} {{streamed, e}, {built, e2}}) {
			if c.want == OUT {
				testing.expectf(t, walktest.typed_kind(got.e) == .Above_Maximum, "%s: %v, want Above_Maximum", c.text, got.e)
			} else {
				ok := got.e == nil && len(got.v) == 1 && transmute(u32)got.v[0] == c.want
				testing.expectf(t, ok, "%s: %v %v, want %08x", c.text, got.v, got.e, c.want)
			}
		}
	}
}

@(test)
types_the_plan_refuses :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Empty :: struct {}
	Bits :: bit_field u8 {
		a: u8 | 8,
	}
	Huge :: struct {
		big: [1 << 29]u64,
		x:   i32,
	}
	Past_4_Gib :: [1 << 32 + 8]u8
	refused := []typeid {
		[]Empty, [dynamic]Empty, [2]Empty, rawptr, Maybe(rawptr), []Maybe(rawptr), [^]i32, proc(), typeid, Bits, #simd[4]f32,
		matrix[2, 2]f32, complex64, quaternion256, rune, string16, #soa[]Point, Huge, []Past_4_Gib, ^Huge, map[string]Past_4_Gib,
	}
	for T in refused {
		_, err := json.plan_make(T, plan = {}, allocator = context.temp_allocator)
		walktest.expect_kind(t, err, core.Typed_Error_Kind.Unsupported)
	}
	for T in ([]typeid{map[string]Empty, [1 << 32 - 1]u8}) {
		_, err := json.plan_make(T, plan = {}, allocator = context.temp_allocator)
		walktest.expect_nil(t, err)
	}
}

@(test)
required_members_read_in_any_order_past_the_63rd_bit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Many :: struct {
		m0, m1, m2, m3, m4, m5, m6, m7, m8, m9: i32 `json:",required"`,
		m10, m11, m12, m13, m14, m15, m16, m17, m18, m19: i32 `json:",required"`,
		m20, m21, m22, m23, m24, m25, m26, m27, m28, m29: i32 `json:",required"`,
		m30, m31, m32, m33, m34, m35, m36, m37, m38, m39: i32 `json:",required"`,
		m40, m41, m42, m43, m44, m45, m46, m47, m48, m49: i32 `json:",required"`,
		m50, m51, m52, m53, m54, m55, m56, m57, m58, m59: i32 `json:",required"`,
		m60, m61, m62, m63, m64, m65, m66, m67, m68, m69: i32 `json:",required"`,
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	for i := 69; i >= 0; i -= 1 {
		fmt.sbprintf(&b, `"m%d":%d`, i, i)
		if i != 0 {
			strings.write_byte(&b, ',')
		}
	}
	strings.write_byte(&b, '}')
	v: Many
	e := read(t, strings.to_string(b), &v)
	walktest.expect_nil(t, e)
	testing.expect_value(t, v.m0, 0)
	testing.expect_value(t, v.m69, 69)
	// The 70th member absent is the one reported.
	text := strings.to_string(b)
	cut := strings.index(text, `"m69":69,`)
	missing := strings.concatenate({text[:cut], text[cut + len(`"m69":69,`):]}, context.temp_allocator)
	w: Many
	e = read(t, missing, &w)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Missing_Field)
	testing.expect_value(t, string(walktest.typed_of(e).steps[walktest.typed_of(e).n_steps - 1].(core.Name)), "m69")
}

@(test)
a_required_struct_inside_a_list_inside_a_required_struct :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Leaf :: struct {
		x: i32 `json:",required"`,
	}
	Mid :: struct {
		leaves: []Leaf `json:",required"`,
		tag:    string,
	}
	Top :: struct {
		mids: []Mid `json:",required"`,
	}
	v: Top
	e := read(t, `{"mids":[{"leaves":[{"x":1},{"x":2}],"tag":"a"},{"leaves":[],"tag":"b"}]}`, &v)
	walktest.expect_nil(t, e)
	testing.expect_value(t, len(v.mids), 2)
	testing.expect_value(t, v.mids[0].leaves[1].x, 2)
	w: Top
	e = read(t, `{"mids":[{"leaves":[{"x":1},{}]}]}`, &w)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Missing_Field)
	testing.expect_value(t, walktest.typed_of(e).n_steps, 5)
}

@(test)
a_repeated_key_is_refused_inside_a_skipped_value_and_a_list :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	S :: struct {
		a: i32,
		l: []Point,
	}
	s: S
	e := read(t, `{"a":1,"skipped":{"k":1,"k":2},"l":[]}`, &s, {dups = .Refuse})
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Duplicate_Key)
	testing.expect_value(t, walktest.at_of(e), 24)
	l: S
	e = read(t, `{"l":[{"x":1,"y":2},{"x":1,"x":3}]}`, &l, {dups = .Refuse})
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Duplicate_Key)
	testing.expect_value(t, walktest.at_of(e), 27)
	ok: S
	e = read(t, `{"l":[{"x":1,"y":2}]}`, &ok, {dups = .Refuse})
	walktest.expect_nil(t, e)
	testing.expect_value(t, len(ok.l), 1)
}

// A `core.Value` member takes whatever its text holds, a number past a double keeping its digits, and writes it back.
@(test)
value_member_takes_any_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	S :: struct {
		a: core.Value,
		b: []core.Value,
	}
	src := `{"a": {"k": [1, "x", 1e400]}, "b": [null, 2.5, true]}`
	plan, perr := json.plan_make(S, reads = json.reads(.Json))
	walktest.expect_nil(t, perr)
	var: S
	walktest.expect_nil(t, json.unmarshal(transmute([]u8)string(src), json.Spec.Json, &var, &plan))
	k, _ := core.member(var.a, "k")
	big, _ := core.child_at(k, 2)
	testing.expect_value(t, big.(^core.Number_Text).text, "1e400")
	testing.expect_value(t, core.length(k), 3)
	testing.expect_value(t, len(var.b), 3)
	out, merr := json.marshal(var, &plan)
	walktest.expect_nil(t, merr)
	testing.expect_value(t, string(out), `{"a":{"k":[1,"x",1e400]},"b":[null,2.5,true]}`)
}

// The forms of `unmarshal` with no plan read `.Value` members, and a plan made with no reads is refused when made.
@(test)
value_member_reads_through_every_entry_point :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	S :: struct {
		a: core.Value,
	}
	x: S
	walktest.expect_nil(t, json.unmarshal(transmute([]u8)string(`{"a": [1]}`), json.Spec.Json, &x))
	testing.expect_value(t, core.length(x.a), 1)
	y: S
	walktest.expect_nil(t, json.unmarshal(transmute([]u8)string(`{"a": [1, 2]}`), json.Spec.Jsonc, &y))
	testing.expect_value(t, core.length(y.a), 2)
	_, refusal := json.plan_make(S)
	testing.expect(t, refusal != nil)
}

// A string of a `.Value` member borrows the text under `borrow_strings`, and a depth fault of its text is the walk's.
@(test)
value_member_borrows_strings_and_reports_its_fault :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	S :: struct {
		a: core.Value,
	}
	src := transmute([]u8)string(`{"a": {"key": ["text"]}}`)
	x: S
	walktest.expect_nil(t, json.unmarshal(src, json.Spec.Json, &x, read = typed.Read_Options{borrow_strings = true}))
	k, _ := core.member(x.a, "key")
	s, _ := core.child_at(k, 0)
	at := uintptr(raw_data(s.(string)))
	testing.expect(t, at >= uintptr(raw_data(src)) && at < uintptr(raw_data(src)) + uintptr(len(src)))
	z: S
	err := json.unmarshal(transmute([]u8)string(`{"a": [[[[1]]]]}`), json.Spec.Json, &z, json.Options{max_depth = 3})
	testing.expect(t, err != nil)
}
