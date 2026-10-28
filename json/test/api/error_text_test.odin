package json_tests

// `error_position`, `render_error` and `render_error_to_writer`: a scan fault located as `line:col` in the source.

import json "../.."
import core "../../../core"
import "core:io"
import "core:strings"
import "core:testing"

@(test)
error_position_positions :: proc(t: ^testing.T) {
	Case :: struct {
		src:       string,
		offset:    u64,
		line, col: int,
	}
	cases := [?]Case {
		{"abc", 0, 1, 1}, // start
		{"a\nbc", 2, 2, 1}, // just after \n
		{"a\nbc", 3, 2, 2},
		{"a\r\nbc", 3, 2, 1}, // CRLF is one break: after it, line 2 col 1
		{"a\r\nbc", 2, 1, 3}, // on the \n of CRLF: still line 1, col counts the \r
		{"a\rb", 2, 1, 3}, // lone \r is not a break
		{"ab\n", 3, 2, 1}, // == len(src), after a trailing break
		{"abc", 3, 1, 4}, // == len(src)
		{"", 0, 1, 1}, // empty source
		{"é\nx", 3, 2, 1}, // columns count bytes: é is two
		{"éx", 3, 1, 4},
	}
	for c in cases {
		line, col := json.error_position(transmute([]byte)c.src, {offset = c.offset, kind = .Bad_Char})
		testing.expectf(t, line == c.line && col == c.col, "%q @%d: got %d:%d, want %d:%d", c.src, c.offset, line, col, c.line, c.col)
	}
}

@(test)
error_position_refuses_past_end :: proc(t: ^testing.T) {
	line, col := json.error_position(transmute([]byte)string("abc"), {offset = 4, kind = .Truncated})
	testing.expect_value(t, [2]int{line, col}, [2]int{0, 0})
	line, col = json.error_position(nil, {offset = 1, kind = .Truncated})
	testing.expect_value(t, [2]int{line, col}, [2]int{0, 0})
	// A limit and a refused allocation point at no byte, even at an offset inside the source.
	line, col = json.error_position(transmute([]byte)string("abc"), {offset = 1, kind = .Source_Too_Wide})
	testing.expect_value(t, [2]int{line, col}, [2]int{0, 0})
	line, col = json.error_position(transmute([]byte)string("abc"), json.Error{kind = .Out_Of_Memory})
	testing.expect_value(t, [2]int{line, col}, [2]int{0, 0})
}

// Each error type is located where `render_error` writes a `line:col`, and nowhere else.
@(test)
error_position_of_every_error_type :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := transmute([]byte)string("[1,\n2]")
	Case :: struct {
		line, col: int,
		text:      string,
	}
	check :: proc(t: ^testing.T, src: []byte, err: $E, want: Case, loc := #caller_location) {
		line, col := json.error_position(src, err)
		testing.expect_value(t, [2]int{line, col}, [2]int{want.line, want.col}, loc)
		testing.expect_value(t, json.render_error(src, err, context.temp_allocator), want.text, loc)
	}
	check(t, src, json.Unmarshal_Error{kind = .Wrong_Kind, offset = 4}, {2, 1, "2:1: Value of the wrong kind"})
	check(t, src, json.Unmarshal_Error{kind = .Out_Of_Memory}, {0, 0, "offset 0: Out of memory"})
	check(t, src, json.Unmarshal_Error{kind = .Bad_Option}, {0, 0, "Unsupported option"})
	check(t, src, json.Path_Error{kind = .Bad_Source, syntax = .Bad_Number, offset = 4}, {2, 1, "2:1: Invalid numeric literal"})
	check(t, src, json.Path_Error{kind = .Encode, encode = .Non_Finite, offset = 4}, {2, 1, "2:1: Value cannot be written: Number has no finite value"})
	check(t, nil, json.Path_Error{kind = .Encode, encode = .Non_Finite, offset = 4}, {0, 0, "offset 4: Value cannot be written: Number has no finite value"})
	check(t, src, json.Path_Error{kind = .Encode, encode = .Too_Deep}, {0, 0, "Value cannot be written: Exceeds depth limit"})
	check(t, src, json.Path_Error{kind = .Bad_Path, offset = 2}, {0, 0, "offset 2: Invalid path"})
	check(t, src, json.Marshal_Error{kind = .Cycle}, {0, 0, "Pointer reached inside its own value"})
}

@(test)
render_error_text :: proc(t: ^testing.T) {
	text :: proc(t: ^testing.T, src: string, err: json.Error, loc := #caller_location) -> string {
		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator)
		werr := core.render_error_to_writer(strings.to_writer(&b), transmute([]byte)src, err, json.fault_name)
		testing.expectf(t, werr == .None, "render_error_to_writer: %v", werr, loc = loc)
		rendered := json.render_error(transmute([]byte)src, err, context.temp_allocator)
		testing.expect_value(t, rendered, strings.to_string(b), loc = loc)
		return rendered
	}
	defer free_all(context.temp_allocator)

	// A real fault: the comma at 2:6 cannot start a value.
	src := "{\"a\":1,\n \"b\":,}"
	err, _ := json.validate(transmute([]byte)src).?
	testing.expect_value(t, text(t, src, err), "2:6: Unexpected character")

	testing.expect_value(t, text(t, "ab", {offset = 2, kind = .Truncated}), "1:3: Unfinished JSON term")
	// An offset that is not a position in the source prints as an offset.
	testing.expect_value(t, text(t, "ab", {offset = 99, kind = .Source_Too_Wide}), "offset 99: Input is too large to read")
	testing.expect_value(t, text(t, "ab", {offset = 99, kind = .Truncated}), "offset 99: Unfinished JSON term")
	// A limit or a refused allocation has no position, even at an offset inside the source.
	testing.expect_value(t, text(t, "abc", {offset = 1, kind = .Source_Too_Wide}), "offset 1: Input is too large to read")
	testing.expect_value(t, text(t, "abc", {kind = .Out_Of_Memory}), "offset 0: Out of memory")
}

// The refusals of unmarshal, the edits, a request and a path parse read as `render_error` reads a scan fault.
@(test)
render_error_other_refusals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	same :: proc(t: ^testing.T, src: string, err: $E, want: string, loc := #caller_location) {
		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator)
		testing.expect_value(t, core.render_error_to_writer(strings.to_writer(&b), transmute([]byte)src, err, json.fault_name), io.Error.None, loc = loc)
		testing.expect_value(t, strings.to_string(b), want, loc = loc)
		testing.expect_value(t, json.render_error(transmute([]byte)src, err, context.temp_allocator), want, loc = loc)
	}

	V :: struct {
		a: int,
	}
	v: V
	src := "{\n \"a\": \"x\"}"
	uerr, _ := json.unmarshal(transmute([]byte)src, &v, allocator = context.temp_allocator).?
	same(t, src, uerr, "2:7: Value of the wrong kind at .a")
	bad := "{\"a\":,}"
	uerr, _ = json.unmarshal(transmute([]byte)bad, &v, allocator = context.temp_allocator).?
	same(t, bad, uerr, "1:6: Unexpected character at .a")
	// The path reads as jq spells one: names, indexes, a quoted name, and `…` where outer steps were dropped.
	Deep :: struct {
		a: struct {
			b: int,
		},
	}
	deep: Deep
	nested := `{"a":{"b":"x"}}`
	uerr, _ = json.unmarshal(transmute([]byte)nested, &deep, allocator = context.temp_allocator).?
	same(t, nested, uerr, "1:11: Value of the wrong kind at .a.b")
	Keyed :: struct {
		m: map[string][]int,
	}
	keyed: Keyed
	odd := `{"m":{"a b":[1,"x"]}}`
	uerr, _ = json.unmarshal(transmute([]byte)odd, &keyed, allocator = context.temp_allocator).?
	same(t, odd, uerr, `1:16: Value of the wrong kind at .m."a b"[1]`)
	uerr.truncated = true
	same(t, odd, uerr, `1:16: Value of the wrong kind at ….m."a b"[1]`)
	Quoted :: struct {
		n: i64 `json:"n,string"`,
	}
	quoted: Quoted
	uerr, _ = json.unmarshal(transmute([]byte)string("{}"), &quoted, allocator = context.temp_allocator).?
	same(t, "{}", uerr, "Unsupported type at .n")
	uerr, _ = json.unmarshal(transmute([]byte)src, (^V)(nil), allocator = context.temp_allocator).?
	same(t, src, uerr, "Unsupported option")

	_, eerr := json.set(transmute([]byte)bad, ".a", 1, allocator = context.temp_allocator)
	same(t, bad, eerr.?, "1:6: Unexpected character")
	_, eerr = json.set(transmute([]byte)string("{}"), ".a[", 1, allocator = context.temp_allocator)
	same(t, "{}", eerr.?, "offset 2: Invalid path")
	_, eerr = json.set(transmute([]byte)string("{}"), ".a", 1, allocator = context.temp_allocator)
	same(t, "{}", eerr.?, "Path matched nothing")

	req: json.Request(bit_set[json.Query]{.Path})
	rerr, _ := json.request_init(&req, ".a[", allocator = context.temp_allocator).?
	same(t, "", rerr, "offset 2: Invalid path")
	same(t, "", json.Path_Error{kind = .Over_Capacity}, "Exceeds a fixed limit of the path scan")

	steps: [4]json.Step
	_, perr := json.parse_path(".a[", steps[:])
	same(t, ".a[", perr.?, "offset 2: Invalid path")
}
