package core_test

import "base:runtime"
import "core:strings"
import "core:testing"
import core ".."

// Every arm of `Error` renders and codes through the two procedures that take the union.
@(test)
every_error_arm_renders :: proc(t: ^testing.T) {
	Case :: struct {
		err:  core.Error,
		line: string,
		code: string,
	}
	src := transmute([]u8)string("[1,\n tru]")
	for c in ([?]Case {
			{core.Fault{at = 6, kind = .Duplicate_Key}, "2:3: Duplicate key", "duplicate_key"},
			{runtime.Allocator_Error.Out_Of_Memory, "Out of memory", "no_memory"},
			{core.Document_Error{kind = .Bad_Index}, "The node takes no such edit", "document.bad_index"},
			{core.Path_Error{kind = .Bad_Path, text = ".[", at = 1}, "1:2: Invalid path \".[\"", "path.bad_path"},
			{core.Typed_Error{kind = .Wrong_Kind}, "1:1: Value does not fit the field's type", "typed.wrong_kind"},
			{core.Typed_Error_Kind.Non_Finite, "Number is not finite", "typed.non_finite"},
			{nil, "", ""},
		}) {
		text: strings.Builder
		defer strings.builder_destroy(&text)
		testing.expect_value(t, core.render(strings.to_writer(&text), src, c.err), nil)
		code: strings.Builder
		defer strings.builder_destroy(&code)
		testing.expect_value(t, core.write_code(strings.to_writer(&code), c.err), nil)
		testing.expect_value(t, strings.to_string(text), c.line)
		testing.expect_value(t, strings.to_string(code), c.code)
	}
}

// A `Lines` carried between calls in any byte order locates as a fresh count from byte 0 does, on a text of lines
// longer and shorter than a 64-byte block.
@(test)
locate_out_of_order :: proc(t: ^testing.T) {
	src := transmute([]u8)strings.concatenate({"ab\n\ncd\r\n", strings.repeat("x", 150, context.temp_allocator), "\ne\n", strings.repeat("y\n", 40, context.temp_allocator)}, context.temp_allocator)
	lines: core.Lines
	for at in ([?]u64{0, 3, 200, 5, 160, 159, 900, 1, 161, 9, 4, 245}) {
		want_line, want_col := core.locate(src, at)
		line, col := core.locate(src, at, &lines)
		testing.expectf(t, line == want_line && col == want_col, "byte %d: %d:%d, want %d:%d", at, line, col, want_line, want_col)
	}
}
