package json_tests

// `marshal`: the type table, tags and omitempty, sorted maps (law 8), `Raw`, cycles and depth, unions
// and `any`, refusals (law 5), plans, and `marshal` of a `Document`.

import "base:runtime"
import json "../.."
import core_pkg "../../../core"
import csv "../../../csv"
import "core:fmt"
import "core:strings"
import "core:testing"

// A refusal's kind, `.None` for none.
@(private)
marshal_kind :: proc(err: Maybe(json.Marshal_Error)) -> json.Marshal_Error_Kind {
	if e, bad := err.?; bad {
		return e.kind
	}
	return .None
}

@(private)
marshal_text :: proc(t: ^testing.T, v: any, opts := json.Marshal_Opts{}, plan: ^json.Type_Plan = nil, loc := #caller_location) -> string {
	out, err := json.marshal(v, opts, plan, context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.None, loc = loc)
	return string(out)
}

@(private)
marshal_refused :: proc(t: ^testing.T, v: any, want: json.Marshal_Error_Kind, loc := #caller_location) {
	out, err := json.marshal(v, {}, nil, context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), want, loc = loc)
	testing.expect(t, out == nil, "a refusal returns a nil slice", loc = loc)
}

Tagged :: struct {
	a: int     `json:"alpha"`,
	b: string  `json:"-"`,
	c: ^int    `json:"c,omitempty"`,
	d: []int   `json:",omitempty"`,
	e: f64,
	z: int     `json:"zero,omitempty"`,
}

List_Node :: struct {
	v:    int,
	next: ^List_Node,
}

Color :: enum u8 {Red, Green}

// A `Number` writes its binary64 value, or is refused when it holds none: `1e400` reads as `.None`, which `Digits`
// keeps and `Number` cannot, so a read-then-write round trip never turns it into `0`. `1e-400` is +-0, its rounding.
@(test)
test_marshal_number_round_trips_or_refuses :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Holder :: struct {
		n: json.Number,
	}
	for c in ([]struct {
		src:  string,
		want: string,
		err:  json.Marshal_Error_Kind,
	}{
		{`{"n":1e400}`, "", .Non_Finite},
		{`{"n":-1e400}`, "", .Non_Finite},
		{`{"n":1e-400}`, `{"n":0}`, .None},
		{`{"n":-1e-400}`, `{"n":-0}`, .None},
		{`{"n":-0}`, `{"n":-0}`, .None},
		{`{"n":5e-324}`, `{"n":5e-324}`, .None},
		{`{"n":2.5}`, `{"n":2.5}`, .None},
	}) {
		v: Holder
		um_ok(t, c.src, &v)
		out, err := json.marshal(v, {}, nil, context.temp_allocator)
		testing.expect_value(t, marshal_kind(err), c.err)
		testing.expect_value(t, string(out), c.want)
	}
	// The zero `Number` is the exact value 0; a `Number` with no binary64 value is refused.
	testing.expect_value(t, marshal_text(t, json.Number{}), `0`)
	testing.expect_value(t, marshal_text(t, Holder{}), `{"n":0}`)
	marshal_refused(t, json.Decoded(json.Number{exactness = .None}), .Non_Finite)
	d: struct {
		n: json.Digits,
	}
	um_ok(t, `{"n":1e400}`, &d)
	testing.expect_value(t, marshal_text(t, d), `{"n":1e400}`)
}

// A refusal names the value refused: each field, element and string map key on the way to it, in the flat,
// nested, pretty and streamed writers alike.
@(test)
test_marshal_refusal_path :: proc(t: ^testing.T) {
	Leaf :: struct {
		x: f64,
	}
	Mid :: struct {
		name: string,
		leaf: Leaf,
	}
	Top :: struct {
		items: []Mid `json:"list"`,
		by:    map[string]Leaf,
	}
	nan := transmute(f64)u64(0x7ff8000000000001)
	items := []Mid{{"a", {1}}, {"b", {nan}}}
	by: map[string]Leaf
	defer delete(by)
	by["k"] = {nan}
	for opts in ([]json.Marshal_Opts{{}, {pretty = true}}) {
		_, err := json.marshal(Top{items = items}, opts, nil, context.temp_allocator)
		testing.expect_value(t, json.render_error(nil, err.?, context.temp_allocator), "Number has no finite value at .list[1].leaf.x")
	}
	_, err := json.marshal(Top{by = by}, {}, nil, context.temp_allocator)
	testing.expect_value(t, json.render_error(nil, err.?, context.temp_allocator), "Number has no finite value at .by.k.x")
	b := strings.builder_make(context.temp_allocator)
	werr := json.marshal_to_writer(strings.to_writer(&b), []Leaf{{1}, {nan}}, allocator = context.temp_allocator)
	testing.expect_value(t, json.render_error(nil, werr.?, context.temp_allocator), "Number has no finite value at [1].x")
	_, rerr := json.marshal(nan, {}, nil, context.temp_allocator)
	testing.expect_value(t, json.render_error(nil, rerr.?, context.temp_allocator), "Number has no finite value")
}

@(test)
test_marshal_scalars :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, marshal_text(t, nil), `null`)
	testing.expect_value(t, marshal_text(t, true), `true`)
	testing.expect_value(t, marshal_text(t, b32(false)), `false`)
	testing.expect_value(t, marshal_text(t, i8(-128)), `-128`)
	testing.expect_value(t, marshal_text(t, u16(65535)), `65535`)
	testing.expect_value(t, marshal_text(t, max(i64)), `9223372036854775807`)
	testing.expect_value(t, marshal_text(t, max(u64)), `18446744073709551615`)
	testing.expect_value(t, marshal_text(t, min(i128)), `-170141183460469231731687303715884105728`)
	testing.expect_value(t, marshal_text(t, max(i128)), `170141183460469231731687303715884105727`)
	testing.expect_value(t, marshal_text(t, i128(-1)), `-1`)
	testing.expect_value(t, marshal_text(t, u128(0)), `0`)
	testing.expect_value(t, marshal_text(t, max(u128)), `340282366920938463463374607431768211455`)
	testing.expect_value(t, marshal_text(t, f32(1.5)), `1.5`)
	testing.expect_value(t, marshal_text(t, f16(0.5)), `0.5`)
	testing.expect_value(t, marshal_text(t, "a\"b"), `"a\"b"`)
	testing.expect_value(t, marshal_text(t, cstring("c")), `"c"`)
	testing.expect_value(t, marshal_text(t, cstring(nil)), `null`)
	testing.expect_value(t, marshal_text(t, 'é'), `"é"`)
	testing.expect_value(t, marshal_text(t, Color.Green), `"Green"`)
	testing.expect_value(t, marshal_text(t, json.Null{}), `null`)
	testing.expect_value(t, marshal_text(t, json.Number{value = 2.5, exactness = .Exact}), `2.5`)
	marshal_refused(t, rune(0xD800), .Bad_Utf8)
	marshal_refused(t, "\xff", .Bad_Utf8)
}

@(test)
test_marshal_struct_tags :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// omitempty drops a nil pointer and an empty slice. A zero int stays.
	v := Tagged{a = 1, b = "hidden", e = 2.5}
	testing.expect_value(t, marshal_text(t, v), `{"alpha":1,"e":2.5,"zero":0}`)
	three := 3
	v.c = &three
	v.d = []int{4}
	testing.expect_value(t, marshal_text(t, v), `{"alpha":1,"c":3,"d":[4],"e":2.5,"zero":0}`)
	testing.expect_value(t, marshal_text(t, v, {pretty = true}), "{\n\t\"alpha\": 1,\n\t\"c\": 3,\n\t\"d\": [\n\t\t4\n\t],\n\t\"e\": 2.5,\n\t\"zero\": 0\n}")
	U :: union {
		int,
	}
	O :: struct {
		u: U `json:"u,omitempty"`,
		x: int,
	}
	testing.expect_value(t, marshal_text(t, O{}), `{"x":0}`)
	testing.expect_value(t, marshal_text(t, O{u = 0}), `{"u":0,"x":0}`)
}

// Law 8: the same contents inserted in two orders, into maps of different capacity, give equal bytes,
// keys sort by their text between the quotes, integer keys as their digits.
@(test)
test_marshal_maps_sorted :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m1 := make(map[string]int)
	defer delete(m1)
	m2 := make(map[string]int, 4096)
	defer delete(m2)
	for k in 0 ..< 200 {
		m1[fmt.tprintf("k%d", k)] = k
	}
	for k := 199; k >= 0; k -= 1 {
		m2[fmt.tprintf("k%d", k)] = k
	}
	testing.expect_value(t, marshal_text(t, m1), marshal_text(t, m2))
	small := make(map[string]int)
	defer delete(small)
	small["a!"], small["a"], small["b"] = 3, 1, 2
	testing.expect_value(t, marshal_text(t, small), `{"a":1,"a!":3,"b":2}`)
	mi := make(map[int]string)
	defer delete(mi)
	mi[9], mi[10] = "x", "y"
	testing.expect_value(t, marshal_text(t, mi), `{"10":"y","9":"x"}`)
	nil_map: map[string]int
	testing.expect_value(t, marshal_text(t, nil_map), `{}`)
	mf := make(map[f64]int)
	defer delete(mf)
	mf[1.5] = 1
	marshal_refused(t, mf, .Unsupported)
}

@(test)
test_marshal_pointers_cycles_depth :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	x := 7
	px := &x
	testing.expect_value(t, marshal_text(t, px), `7`)
	nil_ptr: ^int
	testing.expect_value(t, marshal_text(t, nil_ptr), `null`)

	// A diamond is written twice and a cycle is refused.
	Pair :: struct {
		a, b: ^int,
	}
	testing.expect_value(t, marshal_text(t, Pair{px, px}), `{"a":7,"b":7}`)
	loop := List_Node{v = 1}
	loop.next = &loop
	marshal_refused(t, loop, .Cycle)

	two := List_Node{v = 0, next = &List_Node{v = 1}}
	testing.expect_value(t, marshal_text(t, two), `{"v":0,"next":{"v":1,"next":null}}`)

	// A struct and its first field share an address without forming a cycle.
	Inner :: struct {
		v: int,
		p: ^int,
	}
	inner := Inner{v = 1}
	inner.p = &inner.v
	testing.expect_value(t, marshal_text(t, &inner), `{"v":1,"p":1}`)

	// An `any` that holds itself is a cycle too.
	a: any
	a = any{&a, typeid_of(any)}
	marshal_refused(t, a, .Cycle)

	// Depth counts containers and pointers: a root pointer, 512 structs and the 511 pointers between them
	// nest exactly MAX_DEPTH, the 513-struct list from a value nests one past it.
	nodes := make([]List_Node, 513, context.temp_allocator)
	for k in 0 ..< 512 {
		nodes[k].next = &nodes[k + 1]
	}
	head := &nodes[1]
	out, err := json.marshal(head, {}, nil, context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.None)
	_, invalid := json.validate(out).?
	testing.expect(t, !invalid)
	marshal_refused(t, nodes[0], .Too_Deep)
}

@(test)
test_marshal_unions_and_any :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	U :: union {
		int,
		string,
	}
	testing.expect_value(t, marshal_text(t, U("x")), `"x"`)
	testing.expect_value(t, marshal_text(t, U(nil)), `null`)
	testing.expect_value(t, marshal_text(t, json.Decoded(json.Null{})), `null`)
	testing.expect_value(t, marshal_text(t, json.Decoded(i64(5))), `5`)
	testing.expect_value(t, marshal_text(t, json.Decoded(json.Number{value = -0.5})), `-0.5`)
	text := "s"
	testing.expect_value(t, marshal_text(t, json.Decoded(text)), `"s"`)
	testing.expect_value(t, marshal_text(t, json.Decoded(true)), `true`)
	testing.expect_value(t, marshal_text(t, json.Decoded(u64(9223372036854775808))), "9223372036854775808")
	testing.expect_value(t, marshal_text(t, json.Decoded(u64(max(u64)))), "18446744073709551615")
	testing.expect_value(t, marshal_text(t, json.Decoded(json.Digits("1e400"))), "1e400")
	// `Digits` is one number token, checked as a `Raw` is.
	for bad in ([]json.Digits{"abc", `"1"`, "1 ", "1,2", "01", "-", "[1]"}) {
		marshal_refused(t, json.Decoded(bad), .Bad_Raw)
		marshal_refused(t, bad, .Bad_Raw)
	}
	// An empty `Digits` is `null`, as an empty `Raw` is, wherever it is written.
	Empty :: struct {
		d:  json.Digits,
		ds: []json.Digits,
		m:  map[string]json.Digits,
		a:  any,
	}
	elems := [2]json.Digits{"", "1e400"}
	empty := Empty{ds = elems[:], a = json.Digits("")}
	empty.m = make(map[string]json.Digits, context.temp_allocator)
	empty.m["k"] = ""
	testing.expect_value(t, marshal_text(t, empty), `{"d":null,"ds":[null,1e400],"m":{"k":null},"a":null}`)
	testing.expect_value(t, marshal_text(t, json.Digits("")), `null`)
	Holder :: struct {
		x: any,
	}
	testing.expect_value(t, marshal_text(t, Holder{x = 3}), `{"x":3}`)
	testing.expect_value(t, marshal_text(t, Holder{}), `{"x":null}`)
}

@(test)
test_marshal_raw :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	R :: struct {
		r: json.Raw,
	}
	testing.expect_value(t, marshal_text(t, R{r = `[1, 2]`}), `{"r":[1, 2]}`)
	testing.expect_value(t, marshal_text(t, json.Raw(`"x"`)), `"x"`)
	testing.expect_value(t, marshal_text(t, R{r = `[1, 2]`}, {pretty = true}), "{\n\t\"r\": [1, 2]\n}")
	for bad in ([]json.Raw{`[1,`, ` 1`, `1 `, "\xef\xbb\xbf1", `1 2`}) {
		marshal_refused(t, R{r = bad}, .Bad_Raw)
	}
	// An empty `Raw` is `null`; `omitempty` still omits it.
	testing.expect_value(t, marshal_text(t, R{}), `{"r":null}`)
	testing.expect_value(t, marshal_text(t, json.Raw("")), `null`)
	Omit :: struct {
		r: json.Raw `json:",omitempty"`,
	}
	testing.expect_value(t, marshal_text(t, Omit{}), `{}`)
	// An absent member leaves the `Raw` empty, which marshals as `null`.
	Round :: struct {
		a: int,
		r: json.Raw,
	}
	for src in ([]string{`{"a":1}`, `{"a":1,"r":null}`}) {
		v: Round
		_, bad := json.unmarshal(transmute([]byte)src, &v, allocator = context.temp_allocator).?
		testing.expect(t, !bad)
		testing.expect_value(t, marshal_text(t, v), `{"a":1,"r":null}`)
	}
	// A `Raw` nests inside the object that holds it, all within MAX_DEPTH.
	deep := json.MAX_DEPTH - 1
	fits := nested_arrays(deep)
	out, err := json.marshal(R{r = json.Raw(fits)}, {}, nil, context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.None)
	_, invalid := json.validate(out).?
	testing.expect(t, !invalid)
	marshal_refused(t, R{r = json.Raw(strings.concatenate({"[", fits, "]"}, context.temp_allocator))}, .Too_Deep)
	// `marshal` has no dialect: a `Raw` holding a comment or a trailing comma is not JSON.
	for jsonc in ([]json.Raw{`[1,]`, `[1 /* c */]`, "1 // c"}) {
		marshal_refused(t, R{r = jsonc}, .Bad_Raw)
	}
}

// A `Digits` is a number wherever it is held: typed, in a `Decoded`, or in an `any`, so a number no binary64
// holds survives `unmarshal` into `any` and `marshal` back.
@(test)
test_marshal_digits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, marshal_text(t, json.Digits("1e400")), `1e400`)
	negative := json.Digits("-1e400")
	testing.expect_value(t, marshal_text(t, negative), `-1e400`)
	D :: struct {
		d: json.Digits,
	}
	testing.expect_value(t, marshal_text(t, D{d = "1e400"}), `{"d":1e400}`)
	for src in ([]string{`[1e400]`, `{"a":-1e400,"b":[1E+999]}`, `123456789012345678901234567890e999`}) {
		v: any
		uerr := json.unmarshal(raw(src), &v, {}, nil, context.temp_allocator)
		testing.expectf(t, uerr == nil, "%s: %v", src, uerr)
		testing.expect_value(t, marshal_text(t, v), src)
	}
	// As an `unmarshal` target it takes any number's text, and marshals it back as it was written.
	d: D
	testing.expect_value(t, json.unmarshal(raw(`{"d":1.50}`), &d, {}, nil, context.temp_allocator), nil)
	testing.expect_value(t, marshal_text(t, d), `{"d":1.50}`)
}

@(test)
test_marshal_unsupported :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	p: rawptr
	marshal_refused(t, p, .Unsupported)
	marshal_refused(t, bit_set['a' ..= 'z']{'b'}, .Unsupported)
	marshal_refused(t, complex64(1), .Unsupported)
	marshal_refused(t, typeid_of(int), .Unsupported)
	S :: struct {
		ok: int,
		no: rawptr,
	}
	marshal_refused(t, S{}, .Unsupported)
	// A bit_set whose backing is not native-endian: its bits are not where the type's elements say.
	marshal_refused(t, bit_set[0 ..< 16; u16be]{1, 8}, .Unsupported)
	// Two fields naming one key: no object holds both.
	marshal_refused(t, Um_Clash{}, .Unsupported)
}

@(private)
encode_text :: proc(t: ^testing.T, text: string, opts := json.Document_Opts{}, loc := #caller_location) -> string {
	doc := build_ok(t, text, loc)
	defer json.destroy(&doc)
	out, err := json.marshal(&doc, opts, context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.None, loc = loc)
	return string(out)
}

// `marshal` of a `Document` (§4, law 1).
@(test)
test_marshal_document_pretty :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got := encode_text(t, `{"a":[1,{"b":null}],"c":[],"d":"x"}`, {pretty = true})
	want := "{\n\t\"a\": [\n\t\t1,\n\t\t{\n\t\t\t\"b\": null\n\t\t}\n\t],\n\t\"c\": [],\n\t\"d\": \"x\"\n}"
	testing.expect_value(t, got, want)
	testing.expect_value(t, encode_text(t, `7`, {pretty = true}), `7`)
	testing.expect_value(t, encode_text(t, `[[],{}]`, {pretty = true}), "[\n\t[],\n\t{}\n]")
	testing.expect_value(t, encode_text(t, `{"a\"b":[]}`, {pretty = true}), "{\n\t\"a\\\"b\": []\n}")
}

// A `Document` passed by value is written as the document, not reflected over as a struct.
@(test)
test_marshal_document_by_value :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc := build_ok(t, `{"a": [1, 2.50]}`)
	defer json.destroy(&doc)
	want, _ := json.marshal(&doc, {pretty = true}, context.temp_allocator)
	got, err := json.marshal(doc, {pretty = true}, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.None)
	testing.expect_value(t, string(got), string(want))
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	err = json.marshal_to_writer(strings.to_writer(&sb), doc, {pretty = true}, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.None)
	testing.expect_value(t, strings.to_string(sb), string(want))
}

// `marshal_append` writes after the bytes already in the buffer what `marshal` writes, a value's and a
// document's, and leaves the buffer as it was on a refusal.
@(test)
test_marshal_append :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, "prefix:")
	m: map[string]int
	defer delete(m)
	m["b"], m["a"] = 2, 1
	testing.expect_value(t, marshal_kind(json.marshal_append(&out, m, {trailing_newline = true})), json.Marshal_Error_Kind.None)
	testing.expect_value(t, string(out[:]), "prefix:{\"a\":1,\"b\":2}\n")

	doc := build_ok(t, `{"n": 1e2, "n": 1.50}`)
	defer json.destroy(&doc)
	testing.expect_value(t, marshal_kind(json.marshal_append(&out, &doc, {jq_spelling = true})), json.Marshal_Error_Kind.None)
	testing.expect_value(t, string(out[:]), "prefix:{\"a\":1,\"b\":2}\n{\"n\":1.50}")

	before := strings.clone(string(out[:]), context.temp_allocator)
	testing.expect_value(t, marshal_kind(json.marshal_append(&out, []f64{1, 0h7FF0000000000000})), json.Marshal_Error_Kind.Non_Finite)
	testing.expect_value(t, string(out[:]), before)
}

Sorted_Inner :: struct {
	y: int,
	b: int,
}

Sorted_Outer :: struct {
	zed:   Sorted_Inner,
	gone:  []int `json:",omitempty"`,
	alpha: map[string]int,
	mid:   string,
}

Sorted_Arm :: struct {
	zeta:  int,
	alpha: int,
}

Sorted_Union :: union {
	Sorted_Inner,
	Sorted_Arm,
}

// `sort_keys` writes a struct's fields in byte order of their keys, a nested struct's and a union arm's with its tag
// among them, compact and pretty; an omitted field stays omitted. A map's keys are sorted without it.
@(test)
test_marshal_sort_keys_typed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m: map[string]int
	m["b"], m["a"] = 2, 1
	defer delete(m)
	v := Sorted_Outer{zed = {y = 1, b = 2}, alpha = m, mid = "x"}
	testing.expect_value(t, marshal_text(t, v), `{"zed":{"y":1,"b":2},"alpha":{"a":1,"b":2},"mid":"x"}`)
	testing.expect_value(t, marshal_text(t, v, {sort_keys = true}), `{"alpha":{"a":1,"b":2},"mid":"x","zed":{"b":2,"y":1}}`)
	testing.expect_value(t, marshal_text(t, any(v), {sort_keys = true}), `{"alpha":{"a":1,"b":2},"mid":"x","zed":{"b":2,"y":1}}`)
	pretty := marshal_text(t, v.zed, {sort_keys = true, pretty = true, indent = 2})
	testing.expect_value(t, pretty, "{\n  \"b\": 2,\n  \"y\": 1\n}")
	testing.expect_value(t, marshal_text(t, []Sorted_Inner{{y = 1, b = 2}, {y = 3, b = 4}}, {sort_keys = true}), `[{"b":2,"y":1},{"b":4,"y":3}]`)
	streamed: strings.Builder
	strings.builder_init(&streamed, context.temp_allocator)
	testing.expect_value(t, marshal_kind(json.marshal_to_writer(strings.to_writer(&streamed), v, {sort_keys = true})), json.Marshal_Error_Kind.None)
	testing.expect_value(t, strings.to_string(streamed), `{"alpha":{"a":1,"b":2},"mid":"x","zed":{"b":2,"y":1}}`)
	plan := json.type_plan_init(Sorted_Union, {union_tag = "m"}, context.temp_allocator)
	u := Sorted_Union(Sorted_Arm{zeta = 1, alpha = 2})
	testing.expect_value(t, marshal_text(t, u, {}, &plan), `{"m":"Sorted_Arm","zeta":1,"alpha":2}`)
	testing.expect_value(t, marshal_text(t, u, {sort_keys = true}, &plan), `{"alpha":2,"m":"Sorted_Arm","zeta":1}`)
}

// `core.plan_cache_clear` frees the thread's default plans, every format's. The next call makes them again.
@(test)
test_marshal_after_plan_cache_clear_remakes_the_default_plans :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Pair :: struct {
		a: int,
		b: string,
	}
	core_pkg.plan_cache_clear() // nothing cached yet: no harm
	for _ in 0 ..< 2 {
		testing.expect_value(t, marshal_text(t, Pair{1, "x"}), `{"a":1,"b":"x"}`)
		text, err := csv.marshal([]Pair{{1, "x"}}, allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, string(text), "a,b\n1,x\n")
		core_pkg.plan_cache_clear()
	}
}

// One plan serves every format, each spelling names its own way, and a shared tag names a field in both.
@(test)
test_plan_serves_every_format :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Pair :: struct {
		a: int `stury:"first"`,
		b: string `stury:"second" json:"b"`,
	}
	plan := json.type_plan_init([]Pair)
	defer json.destroy(&plan)
	for _ in 0 ..< 2 {
		text, err := csv.marshal([]Pair{{1, "x"}}, plan = &plan, allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, string(text), "first,second\n1,x\n")
		out, jerr := json.marshal([]Pair{{1, "x"}}, plan = &plan, allocator = context.temp_allocator)
		testing.expect(t, jerr == nil)
		testing.expect_value(t, string(out), `[{"first":1,"b":"x"}]`)
	}
	back: []Pair
	testing.expect(t, csv.unmarshal(transmute([]byte)string("first,second\n2,y\n"), &back, plan = &plan, allocator = context.temp_allocator) == nil)
	testing.expect(t, len(back) == 1 && back[0] == Pair{2, "y"})
	_, err := csv.marshal([]int{1}, plan = &plan, allocator = context.temp_allocator)
	e, refused := err.?
	testing.expect(t, refused && e.kind == .Plan_Mismatch, "a plan for another type")
}

// One read hook serves both formats through `Hook_Value`: a string's decoded text, its authored text beside it.
@(test)
test_read_hook_is_format_neutral :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Stamp :: distinct string
	Row :: struct {
		s: Stamp,
	}
	@(static) seen: [4]core_pkg.Hook_Value
	@(static) n: int
	n = 0
	read_stamp :: proc(v: core_pkg.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core_pkg.Unmarshal_Error_Kind) {
		if v.kind != .String {
			return .Wrong_Kind
		}
		seen[n] = v
		n += 1
		(^Stamp)(dest)^ = Stamp(strings.clone(v.decoded, allocator))
		return nil
	}
	hooks := []core_pkg.Type_Hook{{type = Stamp, read = read_stamp}}

	jp := json.type_plan_init([]Row, {hooks = hooks})
	defer json.destroy(&jp)
	rows: []Row
	testing.expect_value(t, json.unmarshal(raw(`[{"s":"a,b"},{"s":"c"}]`), &rows, {}, &jp, context.temp_allocator), nil)
	testing.expect(t, len(rows) == 2 && rows[0].s == "a,b" && rows[1].s == "c", "json rows")
	testing.expect(t, n == 2 && seen[0].text == `"a,b"` && seen[1].text == `"c"`, "json text")
	num := json.unmarshal(raw(`[{"s":1}]`), &rows, {}, &jp, context.temp_allocator)
	testing.expect(t, num != nil && num.?.kind == .Wrong_Kind, "a number is no stamp")

	n = 0
	cp := csv.type_plan_init([]Row, {hooks = hooks})
	defer csv.destroy(&cp)
	testing.expect_value(t, csv.unmarshal(raw("s\n\"a,b\"\nc\n"), &rows, plan = &cp, allocator = context.temp_allocator), nil)
	testing.expect(t, len(rows) == 2 && rows[0].s == "a,b" && rows[1].s == "c", "csv rows")
	testing.expect(t, n == 2 && seen[0].text == `"a,b"` && seen[1].text == "c", "csv text")
}

// `set` and `insert` write a `Document` value as its text, by value as by pointer.
@(test)
test_set_and_insert_document_value :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc := build_ok(t, `{"k": [1, 2.50]}`)
	defer json.destroy(&doc)
	src := transmute([]byte)string(`{"a":0,"b":[]}`)
	by_ptr, e1 := json.set(src, ".a", &doc, allocator = context.temp_allocator)
	by_val, e2 := json.set(src, ".a", doc, allocator = context.temp_allocator)
	testing.expect(t, e1 == nil && e2 == nil)
	testing.expect_value(t, string(by_val), string(by_ptr))
	testing.expect_value(t, string(by_val), `{"a":{"k":[1,2.50]},"b":[]}`)
	by_ptr, e1 = json.insert(src, ".b", json.APPEND, &doc, allocator = context.temp_allocator)
	by_val, e2 = json.insert(src, ".b", json.APPEND, doc, allocator = context.temp_allocator)
	testing.expect(t, e1 == nil && e2 == nil)
	testing.expect_value(t, string(by_val), string(by_ptr))
	testing.expect_value(t, string(by_val), `{"a":0,"b":[{"k":[1,2.50]}]}`)
}

@(test)
test_marshal_document_refuses_non_trees :: proc(t: ^testing.T) {
	doc: json.Document
	out, err := json.marshal(&doc)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.Bad_State)
	testing.expect(t, out == nil)

	// Rows that are not one tree, as a scoped request's document can be: the two elements of `[1,2]`.
	whole := build_ok(t, `[1,2]`)
	defer json.destroy(&whole)
	part := json.Document{src = whole.src}
	part.rows = make([dynamic]type_of(whole.rows[0]), 0, 2, context.temp_allocator)
	append(&part.rows, whole.rows[1], whole.rows[2])
	defer free_all(context.temp_allocator)
	out, err = json.marshal(&part)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.Bad_State)
	testing.expect(t, out == nil)
}

@(test)
test_marshal_map_uses_only_passed_allocator :: proc(t: ^testing.T) {
	m: map[string]int
	defer delete(m)
	m["b"] = 2
	m["a"] = 1
	ir: map[int]int
	defer delete(ir)
	ir[10] = 1
	ir[2] = 2

	alloc := context.allocator
	saved_alloc := context.allocator
	saved_temp := context.temp_allocator
	context.allocator = runtime.panic_allocator()
	context.temp_allocator = runtime.panic_allocator()
	out_m, err_m := json.marshal(m, {}, nil, alloc)
	out_ir, err_ir := json.marshal(ir, {}, nil, alloc)
	context.allocator = saved_alloc
	context.temp_allocator = saved_temp
	defer delete(out_m, alloc)
	defer delete(out_ir, alloc)

	testing.expect_value(t, marshal_kind(err_m), json.Marshal_Error_Kind.None)
	testing.expect_value(t, string(out_m), `{"a":1,"b":2}`)
	testing.expect_value(t, marshal_kind(err_ir), json.Marshal_Error_Kind.None)
	testing.expect_value(t, string(out_ir), `{"10":1,"2":2}`)
}

// A JSON document of records writes as CSV: a number as its text, null an empty cell, a nested value refused at
// its path.
@(test)
test_marshal_csv_of_json_document :: proc(t: ^testing.T) {
	doc, err := json.build(transmute([]byte)string(`[{"a":1.50,"b":null},{"b":true,"a":"x"}]`), allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	out, merr := csv.marshal(&doc, allocator = context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, string(out), "a,b\n1.50,\nx,true\n")

	nested, _ := json.build(transmute([]byte)string(`[[1,2],[3,{"c":4}]]`), allocator = context.temp_allocator)
	_, merr = csv.marshal(&nested, allocator = context.temp_allocator)
	e, refused := merr.?
	testing.expect(t, refused && e.kind == .Unsupported && e.n_steps == 2)
	testing.expect(t, e.steps[0] == core_pkg.Step(core_pkg.Index(1)) && e.steps[1] == core_pkg.Step(core_pkg.Index(1)))
	mixed, _ := json.build(transmute([]byte)string(`[{"a":1},[2]]`), allocator = context.temp_allocator)
	_, merr = csv.marshal(&mixed, allocator = context.temp_allocator)
	testing.expect(t, merr != nil && merr.?.kind == .Unsupported)
}
