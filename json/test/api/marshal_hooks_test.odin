package json_tests

// `Plan_Opts`: hooks that convert a type both ways (a time, base64 bytes, a number in a string, an enumerated
// array as an object), `,string` refused, union tag names, and what a hook may not do.

import json "../.."
import "base:runtime"
import "core:encoding/base64"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

// A string's decoded text (not ok for any other value).
@(private = "file")
hook_unquote :: proc(v: json.Hook_Value) -> (s: string, ok: bool) {
	return v.decoded, v.kind == .String
}

@(private = "file")
write_time :: proc(out: json.Marshal_Out, v: rawptr) -> json.Marshal_Error_Kind {
	text, ok := time.time_to_rfc3339((^time.Time)(v)^, include_nanos = false, allocator = context.temp_allocator)
	if !ok {
		return .Unsupported
	}
	return json.marshal_into(out, text)
}

@(private = "file")
read_time :: proc(v: json.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(json.Unmarshal_Error_Kind) {
	s, ok := hook_unquote(v)
	if !ok {
		return .Wrong_Kind
	}
	at, n := time.rfc3339_to_time_utc(s)
	if n == 0 || n != len(s) {
		return .Wrong_Kind
	}
	(^time.Time)(dest)^ = at
	return nil
}

@(private = "file")
write_base64 :: proc(out: json.Marshal_Out, v: rawptr) -> json.Marshal_Error_Kind {
	text, err := base64.encode((^[]u8)(v)^, allocator = context.temp_allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	return json.marshal_into(out, text)
}

@(private = "file")
read_base64 :: proc(v: json.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(json.Unmarshal_Error_Kind) {
	s, ok := hook_unquote(v)
	if !ok {
		return .Wrong_Kind
	}
	bytes, err := base64.decode(s, allocator = allocator)
	if _, oom := err.(runtime.Allocator_Error); oom {
		return .Out_Of_Memory
	}
	if err != nil {
		return .Wrong_Kind
	}
	(^[]u8)(dest)^ = bytes
	return nil
}

Hook_Quoted :: distinct i64

@(private = "file")
write_quoted :: proc(out: json.Marshal_Out, v: rawptr) -> json.Marshal_Error_Kind {
	digits: [24]u8
	return json.marshal_into(out, strconv.write_int(digits[:], i64((^Hook_Quoted)(v)^), 10))
}

@(private = "file")
read_quoted :: proc(v: json.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(json.Unmarshal_Error_Kind) {
	s, ok := hook_unquote(v)
	if !ok {
		return .Wrong_Kind
	}
	// Only an i64's canonical form reads. Past the range, `parse_i64` saturates and writes back otherwise.
	n, parsed := strconv.parse_i64_of_base(s, 10)
	digits: [24]u8
	if !parsed || strconv.write_int(digits[:], n, 10) != s {
		return .Out_Of_Range
	}
	(^Hook_Quoted)(dest)^ = Hook_Quoted(n)
	return nil
}

@(private = "file")
TIME_HOOK :: json.Type_Hook{time.Time, write_time, read_time}
@(private = "file")
BASE64_HOOK :: json.Type_Hook{[]u8, write_base64, read_base64}
@(private = "file")
QUOTED_HOOK :: json.Type_Hook{Hook_Quoted, write_quoted, read_quoted}

Hook_When :: struct {
	at:    time.Time,
	maybe: Maybe(time.Time),
	all:   []time.Time,
}

@(test)
test_marshal_hooks_time :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	mapping := json.Plan_Opts{hooks = {TIME_HOOK}}
	leap := time.unix(1709209800, 0)
	v := Hook_When{at = leap, maybe = time.unix(0, 0), all = {leap, time.unix(86400, 0)}}
	plan := json.type_plan_init(Hook_When, mapping, context.temp_allocator)
	want := `{"at":"2024-02-29T12:30:00Z","maybe":"1970-01-01T00:00:00Z","all":["2024-02-29T12:30:00Z","1970-01-02T00:00:00Z"]}`
	testing.expect_value(t, marshal_text(t, v, {}, &plan), want)
	um_round_trip(t, v, mapping = mapping)
	back: Hook_When
	um_ok(t, `{"at":"2024-02-29T13:30:00+01:00","maybe":null,"all":[]}`, &back, mapping = mapping)
	testing.expect(t, time.diff(back.at, leap) == 0 && back.maybe == nil && len(back.all) == 0)
	// The hook's refusal is the value's: its kind, at the value, on the value's path.
	bad := `{"at":"2024-02-29","maybe":null,"all":[]}`
	err_at := um_refused(t, bad, Hook_When, .Wrong_Kind, at(bad, `"2024`), mapping = mapping)
	testing.expect(t, err_at.n_steps == 1 && err_at.steps[0] == json.Name("at"))
	bad = `{"at":"2024-02-29T12:30:00Z","maybe":null,"all":["x"]}`
	um_refused(t, bad, Hook_When, .Wrong_Kind, at(bad, `"x"`), mapping = mapping)
	bad = `{"at":1,"maybe":null,"all":[]}`
	um_refused(t, bad, Hook_When, .Wrong_Kind, at(bad, `1,`), mapping = mapping)
	// The text is validated as JSON before the hook sees it.
	bad = `{"at":"2024-02-29T12:30:00Z\x","maybe":null,"all":[]}`
	um_refused(t, bad, Hook_When, .Syntax, at(bad, `x",`), mapping = mapping)
	// A value read without a target runs no hook: a skipped duplicate, and every value `check` validates.
	dup := `{"at":"2024-02-29T12:30:00Z","at":"later"}`
	um_ok(t, dup, &back, {duplicates = .First}, mapping)
	testing.expect(t, time.diff(back.at, leap) == 0)
	testing.expect(t, json.unmarshal_check(transmute([]byte)dup, Hook_When, {}, &plan) == nil)
	// Without the hook, `time.Time` is the struct it is.
	plain, _ := json.marshal(Hook_When{}, {}, nil, context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(plain), `{"at":{"_nsec":0}`))
}

@(test)
test_marshal_hooks_base64 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Blob :: struct {
		data:  []u8,
		empty: []u8 `json:",omitempty"`,
		nums:  []i32,
	}
	mapping := json.Plan_Opts{hooks = {BASE64_HOOK}}
	plan := json.type_plan_init(Blob, mapping, context.temp_allocator)
	v := Blob{data = {0, 1, 2, 250, 255}, nums = {1}}
	testing.expect_value(t, marshal_text(t, v, {}, &plan), `{"data":"AAEC+v8=","nums":[1]}`)
	um_round_trip(t, v, mapping = mapping)
	back: Blob
	um_ok(t, `{"data":"aGk=","empty":"","nums":[]}`, &back, mapping = mapping)
	testing.expect_value(t, string(back.data), "hi")
	bad := `{"data":"a*","nums":[]}`
	um_refused(t, bad, Blob, .Wrong_Kind, at(bad, `"a*"`), mapping = mapping)
	// The hook allocates from the call's allocator.
	backing: [256]u8
	arena: mem.Arena
	mem.arena_init(&arena, backing[:])
	in_arena := json.unmarshal(transmute([]byte)string(`{"data":"aGk=","nums":[]}`), &back, {}, &plan, mem.arena_allocator(&arena))
	testing.expect(t, in_arena == nil)
	testing.expect(t, uintptr(raw_data(back.data)) >= uintptr(&backing[0]) && uintptr(raw_data(back.data)) < uintptr(&backing[0]) + 256)
}

@(test)
test_marshal_hooks_quoted_numbers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Quoted :: struct {
		n:     Hook_Quoted,
		plain: i64,
	}
	mapping := json.Plan_Opts{hooks = {QUOTED_HOOK}}
	plan := json.type_plan_init(Quoted, mapping, context.temp_allocator)
	testing.expect_value(t, marshal_text(t, Quoted{n = -42, plain = 7}, {}, &plan), `{"n":"-42","plain":7}`)
	um_round_trip(t, Quoted{n = min(Hook_Quoted), plain = 1}, mapping = mapping)
	bad := `{"n":"99999999999999999999","plain":0}`
	um_refused(t, bad, Quoted, .Out_Of_Range, at(bad, `"9`), mapping = mapping)
	bad = `{"n":5,"plain":0}`
	um_refused(t, bad, Quoted, .Wrong_Kind, at(bad, `5`), mapping = mapping)
	// Go's `,string` flag is refused both ways. A hook on a distinct type handles it.
	Go_Quoted :: struct {
		n: i64 `json:"n,string"`,
	}
	marshal_refused(t, Go_Quoted{n = 1}, .Unsupported)
	err := um_refused(t, `{"n":"1"}`, Go_Quoted, .Unsupported, 0)
	testing.expect_value(t, json.render_error(nil, err, context.temp_allocator), "Unsupported type at .n")
}

Hook_Circle :: struct {
	r: f64,
}

Hook_Square :: struct {
	side: f64,
}

Hook_Typed :: struct {
	type: string,
}

Hook_Shape :: union {
	Hook_Circle,
	Hook_Square,
}

// `tag_names` names an arm in place of its type name, both ways. And a tag an arm's own field would repeat
// is refused.
@(test)
test_marshal_union_tag_names :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	mapping := json.Plan_Opts{union_tag = "kind", tag_names = {{Hook_Circle, "circle"}, {Hook_Square, "sq"}}}
	plan := json.type_plan_init([]Hook_Shape, mapping, context.temp_allocator)
	v := []Hook_Shape{Hook_Circle{r = 1}, Hook_Square{side = 2}, nil}
	testing.expect_value(t, marshal_text(t, v, {}, &plan), `[{"kind":"circle","r":1},{"kind":"sq","side":2},null]`)
	um_round_trip(t, v, mapping = mapping)
	bad := `[{"kind":"Hook_Circle","r":1}]`
	um_refused(t, bad, []Hook_Shape, .Not_A_Member, 1, mapping = mapping)
	// One arm named, the other by its type name.
	half := json.Plan_Opts{union_tag = "kind", tag_names = {{Hook_Square, "sq"}}}
	half_plan := json.type_plan_init(Hook_Shape, half, context.temp_allocator)
	testing.expect_value(t, marshal_text(t, Hook_Shape(Hook_Circle{r = 1}), {}, &half_plan), `{"kind":"Hook_Circle","r":1}`)
	Clash :: union {
		Hook_Typed,
		Hook_Circle,
	}
	clash_plan := json.type_plan_init(Clash, {union_tag = "type"}, context.temp_allocator)
	_, err := json.marshal(Clash(Hook_Circle{}), {}, &clash_plan, context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.Unsupported)
	um_refused(t, `{"r":1}`, Clash, .Unsupported, 0, mapping = {union_tag = "type"})
	// Under another tag the field is the arm's own.
	um_round_trip(t, Clash(Hook_Typed{type = "x"}), mapping = {union_tag = "kind"})
}

// A type the plan first meets inside a hook: compiling it then appends enough ops, fields and keys to move every
// plan array the writer is walking. The plans are made in the heap allocator, whose frees the address sanitizer
// sees: the test runner's allocator frees nothing.
@(private = "file")
Hook_Part :: struct {
	f00, f01, f02, f03, f04, f05, f06, f07, f08, f09, f10, f11, f12, f13, f14, f15: int,
}
@(private = "file")
Hook_Big :: struct {
	a:          [1]int,
	b:          [2]int,
	c:          [3]int,
	d:          [4]int,
	e:          [5]int,
	f:          [6]int,
	g:          [7]int,
	h:          [8]int,
	p, q, r, s: Hook_Part,
}
@(private = "file")
Hook_Grows :: distinct int

@(private = "file")
write_grows :: proc(out: json.Marshal_Out, v: rawptr) -> json.Marshal_Error_Kind {
	return json.marshal_into(out, Hook_Big{})
}

// A hook that compiles a new type moves the plan's arrays under the struct writers, which still write the rest of
// the struct and every element after it: compact, pretty, sorted and streamed. Each matches the same struct with
// the hook's value in place of the hooked field.
@(test)
test_marshal_hook_compile_moves_plan :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Row :: struct {
		z: int,
		w: Hook_Grows,
		b: string,
		l: []int,
	}
	Twin :: struct {
		z: int,
		w: Hook_Big,
		b: string,
		l: []int,
	}
	// A struct of scalars is flat, and a flat struct is written without a hook. A hooked scalar field leaves the
	// struct not flat: the hook writes its value.
	Scalars :: struct {
		z: int,
		w: Hook_Grows,
		b: int,
	}
	Scalars_Twin :: struct {
		z: int,
		w: Hook_Big,
		b: int,
	}
	rows := []Row{{1, 2, "x", {3}}, {4, 5, "y", nil}}
	twins := []Twin{{z = 1, b = "x", l = {3}}, {z = 4, b = "y"}}
	scalars := []Scalars{{1, 2, 3}, {4, 5, 6}}
	scalar_twins := []Scalars_Twin{{z = 1, b = 3}, {z = 4, b = 6}}
	hooks := []json.Type_Hook{{type = Hook_Grows, write = write_grows}}
	opts_set := []json.Marshal_Opts{{}, {pretty = true}, {sort_keys = true}, {pretty = true, sort_keys = true}}
	for opts in opts_set {
		for streamed in ([]bool{false, true}) {
			plan := json.type_plan_init([]Row, {hooks = hooks}, runtime.heap_allocator())
			testing.expect_value(t, marshal_hooked(t, rows, opts, &plan, streamed), marshal_text(t, twins, opts))
			json.destroy(&plan)
			scalar_plan := json.type_plan_init([]Scalars, {hooks = hooks}, runtime.heap_allocator())
			testing.expect_value(t, marshal_hooked(t, scalars, opts, &scalar_plan, streamed), marshal_text(t, scalar_twins, opts))
			json.destroy(&scalar_plan)
		}
	}
}

// `v` written by `plan` into a string, or with `streamed` through a writer.
@(private = "file")
marshal_hooked :: proc(t: ^testing.T, v: any, opts: json.Marshal_Opts, plan: ^json.Type_Plan, streamed: bool, loc := #caller_location) -> string {
	if !streamed {
		return marshal_text(t, v, opts, plan, loc)
	}
	sb := strings.builder_make(context.temp_allocator)
	err := json.marshal_to_writer(strings.to_writer(&sb), v, opts, plan, context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.None, loc = loc)
	return strings.to_string(sb)
}
