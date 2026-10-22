package json_tests

// `error_position`, `render_error` and `render_error_to_writer`: a scan fault located as `line:col` in the source.

import json "../.."
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
	line, col = json.error_position(transmute([]byte)string("abc"), {kind = .Out_Of_Memory})
	testing.expect_value(t, [2]int{line, col}, [2]int{0, 0})
}

@(test)
render_error_text :: proc(t: ^testing.T) {
	text :: proc(t: ^testing.T, src: string, err: json.Error, loc := #caller_location) -> string {
		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator)
		werr := json.render_error_to_writer(strings.to_writer(&b), transmute([]byte)src, err)
		testing.expectf(t, werr == .None, "render_error_to_writer: %v", werr, loc = loc)
		rendered := json.render_error(transmute([]byte)src, err, context.temp_allocator)
		testing.expect_value(t, rendered, strings.to_string(b), loc = loc)
		return rendered
	}
	defer free_all(context.temp_allocator)

	// A real fault: the comma at 2:6 cannot start a value.
	src := "{\"a\":1,\n \"b\":,}"
	err, _ := json.validate(transmute([]byte)src).?
	testing.expect_value(t, text(t, src, err), "2:6: Bad_Char")

	testing.expect_value(t, text(t, "ab", {offset = 2, kind = .Truncated}), "1:3: Truncated")
	// An offset that is not a position in the source prints as an offset.
	testing.expect_value(t, text(t, "ab", {offset = 99, kind = .Source_Too_Wide}), "offset 99: Source_Too_Wide")
	testing.expect_value(t, text(t, "ab", {offset = 99, kind = .Truncated}), "offset 99: Truncated")
	// A limit or a refused allocation has no position, even at an offset inside the source.
	testing.expect_value(t, text(t, "abc", {offset = 1, kind = .Source_Too_Wide}), "offset 1: Source_Too_Wide")
	testing.expect_value(t, text(t, "abc", {kind = .Out_Of_Memory}), "offset 0: Out_Of_Memory")
}

// The refusals of unmarshal, the edits, a request and a path parse read as `render_error` reads a scan fault.
@(test)
render_error_other_refusals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	same :: proc(t: ^testing.T, src: string, err: $E, want: string, loc := #caller_location) {
		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator)
		testing.expect_value(t, json.render_error_to_writer(strings.to_writer(&b), transmute([]byte)src, err), io.Error.None, loc = loc)
		testing.expect_value(t, strings.to_string(b), want, loc = loc)
		testing.expect_value(t, json.render_error(transmute([]byte)src, err, context.temp_allocator), want, loc = loc)
	}

	V :: struct {
		a: int,
	}
	v: V
	src := "{\n \"a\": \"x\"}"
	uerr, _ := json.unmarshal(transmute([]byte)src, &v, allocator = context.temp_allocator).?
	same(t, src, uerr, "2:7: Wrong_Kind")
	bad := "{\"a\":,}"
	uerr, _ = json.unmarshal(transmute([]byte)bad, &v, allocator = context.temp_allocator).?
	same(t, bad, uerr, "1:6: Syntax: Bad_Char")
	uerr, _ = json.unmarshal(transmute([]byte)src, (^V)(nil), allocator = context.temp_allocator).?
	same(t, src, uerr, "Bad_Option")

	_, eerr := json.set(transmute([]byte)bad, ".a", 1, context.temp_allocator)
	same(t, bad, eerr.?, "1:6: Bad_Source: Bad_Char")
	_, eerr = json.set(transmute([]byte)string("{}"), ".a[", 1, context.temp_allocator)
	same(t, "{}", eerr.?, "offset 2: Bad_Path")
	_, eerr = json.set(transmute([]byte)string("{}"), ".a", 1, context.temp_allocator)
	same(t, "{}", eerr.?, "Not_Found")

	req: json.Request(bit_set[json.Query]{.Path})
	rerr, _ := json.request_init(&req, ".a[", allocator = context.temp_allocator).?
	same(t, "", rerr, "offset 2: Bad_Path (path 0)")
	same(t, "", json.Request_Error{kind = .Over_Capacity, capacity = .Path_Steps}, "Over_Capacity: Path_Steps")

	steps: [4]json.Step
	_, perr := json.parse_path(".a[", steps[:])
	same(t, ".a[", perr.?, "1:3: Unclosed_Bracket")
}
