package json_tests

// `unmarshal` (docs/codec.md §7): flat structs, required and optional fields, unknown keys and `null`, and the
// types and helpers the other typed tests share. The rest of the type table is the private suite's.

import json "../.."
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

Um_Flat :: struct {
	name:  string `json:",required"`,
	count: i32    `json:",required"`,
	ratio: f64,
	ok:    bool,
	small: u8,
	half:  f32    `json:",required"`,
}

Um_Tagged :: struct {
	a: int    `json:"alpha,required"`,
	b: string `json:"-"`,
	c: int    `json:"c,omitempty"`,
	e: f64,
}

Um_Outer :: struct {
	id:    i64,
	inner: Um_Flat,
	tail:  string,
}

Um_Ints :: struct {
	a: u8,
	b: i8,
	c: i32,
	d: u64,
	e: i64,
}

Um_Floats :: struct {
	x: f64,
	y: f32,
	z: f16,
}

// Two arms that both take a number.
Um_Union :: struct {
	u: union {
		int,
		f64,
	},
}

// A rune range: neither an enum nor integers.
Um_Bits :: struct {
	b: bit_set['a' ..= 'z'],
}

Um_Clash :: struct {
	a: int,
	b: int `json:"a"`,
}

// A flag no format knows.
Um_Bad_Tag :: struct {
	a: int `json:"a,bogus"`,
}

Um_Base :: struct {
	id:   i64 `json:",required"`,
	note: string,
}

UM_FLAT_TEXT :: `{"name":"a\"b","count":-7,"ratio":2.5,"ok":true,"small":255,"half":0.5}`

// A plan mapping `T` by `mapping`, in the temp allocator (nil for the default mapping), so a call takes the
// thread's cached plan.
@(private)
um_plan :: proc($T: typeid, mapping: json.Plan_Opts) -> ^json.Type_Plan {
	if mapping.enums == .Name && mapping.union_tag == "" && mapping.tag_names == nil && mapping.hooks == nil {
		return nil
	}
	p := new(json.Type_Plan, context.temp_allocator)
	p^ = json.type_plan_init(T, mapping, context.temp_allocator)
	return p
}

// The refusal of a typed read, or the zero `Unmarshal_Error` when it read.
@(private)
um_err :: proc(err: Maybe(json.Unmarshal_Error)) -> json.Unmarshal_Error {
	e, _ := err.?
	return e
}

// The kind of a typed read's refusal, nil when it read.
@(private)
um_kind :: proc(err: Maybe(json.Unmarshal_Error)) -> Maybe(json.Unmarshal_Error_Kind) {
	if e, refused := err.?; refused {
		return e.kind
	}
	return nil
}

@(private)
um_ok :: proc(t: ^testing.T, src: string, ptr: ^$T, opts := json.Unmarshal_Opts{}, mapping := json.Plan_Opts{}, loc := #caller_location) {
	err, refused := json.unmarshal(transmute([]byte)src, ptr, opts, um_plan(T, mapping), context.temp_allocator).?
	testing.expectf(t, !refused, "unmarshal %s: %v at %d", src, err.kind, err.offset, loc = loc)
}

@(private)
um_refused :: proc(
	t: ^testing.T,
	src: string,
	$T: typeid,
	kind: json.Unmarshal_Error_Kind,
	offset: u64,
	opts := json.Unmarshal_Opts{},
	mapping := json.Plan_Opts{},
	loc := #caller_location,
) -> json.Unmarshal_Error {
	v: T
	err := um_err(json.unmarshal(transmute([]byte)src, &v, opts, um_plan(T, mapping), context.temp_allocator))
	testing.expectf(t, err.kind == kind, "%s: kind %v, want %v", src, err.kind, kind, loc = loc)
	testing.expectf(t, err.offset == offset, "%s: offset %d, want %d", src, err.offset, offset, loc = loc)
	return err
}

// Marshal `v`, read the text back into a fresh `T`, marshal that: the two texts are equal.
@(private)
um_round_trip :: proc(t: ^testing.T, v: $T, opts := json.Unmarshal_Opts{}, mapping := json.Plan_Opts{}, loc := #caller_location) {
	plan := um_plan(T, mapping)
	text, merr := json.marshal(v, {}, plan, context.temp_allocator)
	testing.expect_value(t, marshal_kind(merr), json.Marshal_Error_Kind.None, loc = loc)
	back: T
	err, refused := json.unmarshal(text, &back, opts, plan, context.temp_allocator).?
	testing.expectf(t, !refused, "%s: %v at %d", string(text), err.kind, err.offset, loc = loc)
	again, _ := json.marshal(back, {}, plan, context.temp_allocator)
	testing.expect_value(t, string(again), string(text), loc = loc)
}

// Whether `s` is a slice of `src`'s bytes rather than a copy.
@(private)
in_source :: proc(s, src: string) -> bool {
	p, lo := uintptr(raw_data(s)), uintptr(raw_data(src))
	return p >= lo && p < lo + uintptr(len(src))
}

// The offset of the first byte of `needle` in `src`.
@(private)
at :: proc(src, needle: string) -> u64 {
	i := strings.index(src, needle)
	assert(i >= 0, needle)
	return u64(i)
}

@(test)
test_unmarshal_flat_struct :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	v: Um_Flat
	um_ok(t, UM_FLAT_TEXT, &v)
	testing.expect_value(t, v.name, `a"b`)
	testing.expect_value(t, v.count, -7)
	testing.expect_value(t, v.ratio, 2.5)
	testing.expect_value(t, v.ok, true)
	testing.expect_value(t, v.small, 255)
	testing.expect_value(t, v.half, 0.5)
	// Member order, whitespace and an escaped key form do not matter.
	w: Um_Flat
	um_ok(t, " { \"half\" : 0.5 ,\"small\":255,\"ok\":true,\"ratio\":2.5,\"count\":-7,\"n\\u0061me\":\"a\\\"b\" } ", &w)
	testing.expect(t, w == v)
}

@(test)
test_unmarshal_required_and_optional_fields :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := `{"name":"x","ratio":1,"ok":true,"small":1,"half":1}`
	um_refused(t, src, Um_Flat, .Missing_Field, u64(len(src) - 1))
	// A field not tagged `required` is optional, `omitempty` or not, a pointer or not: an absent one keeps
	// what the target held, as Go's and core's unmarshal do.
	v := Um_Tagged{c = 9, e = 4, b = "not a member"}
	um_ok(t, `{"alpha":1}`, &v)
	testing.expect_value(t, v.a, 1)
	testing.expect_value(t, v.c, 9)
	testing.expect_value(t, v.e, 4)
	testing.expect_value(t, v.b, "not a member")
	f := Um_Flat{ratio = 2, ok = true, small = 3}
	um_ok(t, `{"name":"n","count":1,"half":0.5}`, &f)
	testing.expect(t, f.name == "n" && f.count == 1 && f.half == 0.5 && f.ratio == 2 && f.ok && f.small == 3)
	// `required` is read-side only: marshal writes the field as before.
	testing.expect_value(t, marshal_text(t, Um_Tagged{a = 2}), `{"alpha":2,"c":0,"e":0}`)
	// In a list of records each record is checked at its own `}`, the walk's record chaining included.
	mid := `[{"id":1},{"note":"x"},{"id":3}]`
	um_refused(t, mid, []Um_Base, .Missing_Field, at(mid, `"x"}`) + 3)
	last := `[{"id":1},{"id":2,"note":"y"},{"note":"z"}]`
	um_refused(t, last, []Um_Base, .Missing_Field, u64(len(last) - 2))
}

@(test)
test_unmarshal_unknown_fields :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// `json:"-"` is not a member, so a "b" key is unknown like any other.
	src := `{"alpha":1,"b":"x","e":2,"extra":[1,{"x":null}]}`
	v: Um_Tagged
	um_ok(t, src, &v)
	testing.expect_value(t, v.a, 1)
	testing.expect_value(t, v.b, "")
	testing.expect_value(t, v.e, 2.0)
}

Um_Seq :: struct {
	ints:  []i32,
	names: [dynamic]string,
	trio:  [3]u8,
	by:    [Color]int,
	few:   [dynamic; 4]i16,
	grid:  [][]int,
}

Um_Logs :: struct {
	logs: []Um_Flat,
}

// `null` is not an empty string or list, as Go would take it: it is the wrong kind for both.
@(test)
test_unmarshal_null_into_string_or_list :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	um_refused(t, `null`, string, .Wrong_Kind, 0)
	um_refused(t, `null`, []i32, .Wrong_Kind, 0)
	um_refused(t, `null`, [dynamic]string, .Wrong_Kind, 0)
	um_refused(t, `null`, map[string]int, .Wrong_Kind, 0)
	um_refused(t, `null`, bool, .Wrong_Kind, 0)
	um_refused(t, `null`, Um_Flat, .Wrong_Kind, 0)
	d: json.Decoded
	um_ok(t, `null`, &d)
	r: json.Raw
	um_ok(t, `null`, &r)
	src := `{"ints":[],"names":null,"trio":[1,2,3],"by":[5,6],"few":[],"grid":[]}`
	um_refused(t, src, Um_Seq, .Wrong_Kind, at(src, `null`))
}

Um_Tree :: struct {
	kids: []Um_Tree,
}

Um_Maps :: struct {
	by_name: map[string]int,
	by_id:   map[int]string,
	small:   map[u8]bool,
	nested:  map[string]Um_Tagged,
}

Um_Circle :: struct {
	r: f64,
}

Um_Square :: struct {
	side:  f64,
	marks: []i64 `json:",omitempty"`,
}

Um_Shape :: union {
	Um_Circle,
	Um_Square,
	i64,
}

Um_Drawing :: struct {
	shapes: []Um_Shape,
	// One struct arm: no tag is written or read, an object picks it by shape.
	one:    union {
		Um_Circle,
		string,
	},
}

Um_Key_Kinds :: struct {
	by_color: map[Color]int,
	by_wide:  map[i128]int,
}

Um_Leaves :: struct {
	n:   json.Null,
	raw: json.Raw,
	dec: json.Decoded,
	num: json.Number,
	cs:  cstring,
	r:   rune,
	col: Color,
	wi:  i128,
	wu:  u128,
}

// An `any` tree holds every allocation it was built from: each map and list header, its storage, every key
// and boxed scalar is reachable from the result, so freeing what is reachable leaves nothing.
@(test)
test_unmarshal_any_tree_holds_its_allocations :: proc(t: ^testing.T) {
	free_any :: proc(v: any) {
		if v.data == nil {
			return
		}
		switch v.id {
		case map[string]any:
			m := (^map[string]any)(v.data)
			for key, child in m {
				delete(key)
				free_any(child)
			}
			delete(m^)
		case [dynamic]any:
			list := (^[dynamic]any)(v.data)
			for child in list {
				free_any(child)
			}
			delete(list^)
		case string:
			delete((^string)(v.data)^)
		}
		free(v.data)
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	v: any
	err := json.unmarshal(raw(`{"a":[1,{"b":"x"},[]],"c":null,"d":{}}`), &v, allocator = mem.tracking_allocator(&track))
	testing.expect_value(t, err, nil)
	context.allocator = mem.tracking_allocator(&track)
	free_any(v)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// An escaped integer key past the 256-byte stack buffer is decoded on the heap and checked like a short one: a
// run of escaped digits is out of range, any other run is the wrong kind, and a short one still reads.
@(test)
test_unmarshal_overlong_escaped_int_key :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	read :: proc(escape: string, count: int, alloc: mem.Allocator) -> bool {
		m: map[int]bool
		src := fmt.tprintf(`{{"%s":true}}`, strings.repeat(escape, count, context.temp_allocator))
		return json.unmarshal(raw(src), &m, allocator = alloc) != nil
	}
	testing.expect(t, read(`\u0031`, 60, alloc))
	testing.expect(t, read(`\u0061`, 60, alloc))
	testing.expect_value(t, len(track.allocation_map), 0)
	ok: map[int]bool
	testing.expect_value(t, json.unmarshal(raw(`{"\u0031\u0032":true}`), &ok, allocator = alloc), nil)
	testing.expect_value(t, ok[12], true)
	context.allocator = alloc
	delete(ok)
	testing.expect_value(t, len(track.allocation_map), 0)
}

// Under `.First`, a map that holds entries reads the object into a map aside and merges it in at the close:
// that aside map is the walk's own, given back, so freeing the target leaves nothing.
@(test)
test_unmarshal_first_map_aside_is_given_back :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	m := make(map[string]int, alloc)
	m["k"] = 0
	err := json.unmarshal(raw(`{"a":1,"b":2,"a":3}`), &m, {duplicates = .First}, allocator = alloc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(m), 3)
	testing.expect_value(t, m["a"], 1)
	for key in m {
		if key != "k" {
			delete(key, alloc)
		}
	}
	delete(m)
	testing.expect_value(t, len(track.allocation_map), 0)
}

// A number into a `Decoded` leaf takes the arm `decode_span` gives the same token.
@(test)
test_unmarshal_decoded_number_is_decode_spans :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for tok in ([]string{
		"0", "-0", "7", "-7", "1e0", "1E2", "-1e-2", "1.0", "0.5", "-0.25e+3", "9223372036854775807",
		"-9223372036854775808", "9223372036854775808", "18446744073709551615", "18446744073709551616",
		"123456789012345678901234567890", "1.7976931348623157e308", "1e400", "-1e400", "4.9e-324", "1e-400",
	}) {
		want, _, ok := json.decode_span(transmute([]byte)tok, 0, u64(len(tok)), .Number)
		testing.expectf(t, ok, "decode_span %s", tok)
		d: json.Decoded
		um_ok(t, tok, &d)
		testing.expectf(t, d == want, "%s: Decoded %v, decode_span %v", tok, d, want)
		in_list: [1]json.Decoded
		um_ok(t, fmt.tprintf("[%s]", tok), &in_list)
		testing.expectf(t, in_list[0] == want, "[%s]: Decoded %v, decode_span %v", tok, in_list[0], want)
	}
}

// An out-of-range number reads into a `json.Number` as exactness `None`, `.Strict` and `.Lazy` agree.
@(test)
test_unmarshal_number_accepts_an_out_of_range_value :: proc(t: ^testing.T) {
	for strictness in ([]json.Strictness{.Strict, .Lazy}) {
		n: json.Number
		um_ok(t, `1e400`, &n, {strictness = strictness})
		testing.expect_value(t, n.exactness, json.Exactness.None)
	}
}

// `.Structural` reads a JSONC document as it reads JSON: comments and trailing commas pass, and the dialect
// is not refused as a bad option.
@(test)
test_unmarshal_structural_reads_jsonc :: proc(t: ^testing.T) {
	v: struct {
		a: int,
	}
	um_ok(t, "{/* c */\"a\":7,}", &v, {dialect = .Jsonc, strictness = .Structural})
	testing.expect_value(t, v.a, 7)
	um_refused(t, `{"a":7}`, struct{ a: int }, .Bad_Option, 0, {strictness = .Structural})
}

// A `max_depth` past MAX_DEPTH is held to MAX_DEPTH by a typed read, whose walk does not spill: an array nest of
// 1025 is `.Too_Deep` at its 1025th bracket, where `validate` under the same limit reads it.
@(test)
test_unmarshal_holds_max_depth_to_max_depth :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	limits := json.Limits{max_depth = 5000}
	past := strings.concatenate({strings.repeat("[", json.MAX_DEPTH + 1, context.temp_allocator), strings.repeat("]", json.MAX_DEPTH + 1, context.temp_allocator)}, context.temp_allocator)
	testing.expect(t, json.validate(transmute([]byte)past, {limits = limits}) == nil)
	v: any
	e, bad := json.unmarshal(transmute([]byte)past, &v, {limits = limits}, allocator = context.temp_allocator).?
	testing.expectf(t, bad && e.kind == .Syntax && e.syntax == .Too_Deep && e.offset == json.MAX_DEPTH, "%v", e)
}

// A refused read leaves its partial value in the allocator the caller gave, and keeps none of its own scratch:
// an arena freed whole after the refusal leaves nothing allocated, under every strictness.
@(test)
test_unmarshal_refused_leaks_nothing :: proc(t: ^testing.T) {
	Item :: struct {
		name: string,
		tags: [dynamic]string,
		by:   map[string]int,
		n:    int,
	}
	src := transmute([]byte)string(`[{"name":"a\nb","tags":["x","yé"],"by":{"k":1},"n":1},{"name":"c","tags":["z"],"by":{"q":2},"n":"bad"}]`)
	for strictness in ([]json.Strictness{.Strict, .Lazy}) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		{
			context.allocator = mem.tracking_allocator(&track)
			plan := json.type_plan_init([]Item)
			arena: mem.Dynamic_Arena
			mem.dynamic_arena_init(&arena)
			items: []Item
			err := json.unmarshal(src, &items, {strictness = strictness}, &plan, mem.dynamic_arena_allocator(&arena))
			testing.expectf(t, err != nil && err.?.kind == .Wrong_Kind, "%v: %v", strictness, err)
			mem.dynamic_arena_destroy(&arena)
			json.destroy(&plan)
		}
		testing.expectf(t, len(track.allocation_map) == 0, "%v: %d allocations left", strictness, len(track.allocation_map))
		testing.expect_value(t, len(track.bad_free_array), 0)
	}
}
