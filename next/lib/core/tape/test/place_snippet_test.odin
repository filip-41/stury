package tape_test

import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"

@(test)
error_snippet_basic_crlf_tabs_and_utf8 :: proc(t: ^testing.T) {
	testkit.deadline(t)

	buf: [1024]u8

	// 1. Simple single-line JSON fault.
	{
		src := transmute([]u8)string(`{"a": [1, }`)
		snip, ok := tape.error_snippet(buf[:], src, 10)
		testing.expect(t, ok)
		testing.expect_value(t, snip, "  {\"a\": [1, }\n            ^\n")
	}

	// 2. Multi-line CRLF strips `\r` cleanly and points to exact column on line 2.
	{
		src := transmute([]u8)string("{\r\n  \"x\": @\r\n}\r\n")
		// Line 2 starts at byte 3 (`"  \"x\": @"`), `@` is at byte 10 (col 8).
		snip, ok := tape.error_snippet(buf[:], src, 10)
		testing.expect(t, ok)
		testing.expect_value(t, snip, "    \"x\": @\n         ^\n")
	}

	// 3. Tabs expand to 4 spaces so `^` aligns accurately under the exact character.
	{
		src := transmute([]u8)string("{\n\t\"k\": ]\n}")
		// Line 2 starts at byte 2 (`\t` at 2, `"` at 3, `k` at 4, `"` at 5, `:` at 6, ` ` at 7, `]` at 8).
		// Displayed line: `  ` + 4 spaces (for `\t`) + `"k": ]` -> `]` is at column 4+5 = 9 from snippet margin.
		snip, ok := tape.error_snippet(buf[:], src, 8)
		testing.expect(t, ok)
		testing.expect_value(t, snip, "      \"k\": ]\n           ^\n")
	}

	// 4. Multi-byte UTF-8 aligns by scalar display columns, not raw bytes.
	{
		src := transmute([]u8)string(`{"é中😀": ]}`)
		// `]` is right before `}`: byte len = len(src) - 2.
		at := u64(len(src) - 2)
		snip, ok := tape.error_snippet(buf[:], src, at)
		testing.expect(t, ok)
		// Display cols before `]`: `{` `"` `é` `中` `😀` `"` `:` ` ` = 8 cols -> 2 indent + 8 spaces = 10 spaces.
		testing.expect_value(t, snip, "  {\"é中😀\": ]}\n          ^\n")
	}
}

@(test)
error_snippet_eof_windowing_and_binary_guards :: proc(t: ^testing.T) {
	testkit.deadline(t)

	buf: [1024]u8

	// 1. EOF (`at == u64(len(src))`) without trailing newline points just past the last byte.
	{
		src := transmute([]u8)string(`{"a": 1`)
		snip, ok := tape.error_snippet(buf[:], src, u64(len(src)))
		testing.expect(t, ok)
		testing.expect_value(t, snip, "  {\"a\": 1\n         ^\n")
	}

	// 2. EOF after trailing `\n` or `\r\n` points just past the last character of the last line.
	{
		src := transmute([]u8)string("{\"a\": 1\r\n")
		snip, ok := tape.error_snippet(buf[:], src, u64(len(src)))
		testing.expect(t, ok)
		testing.expect_value(t, snip, "  {\"a\": 1\n         ^\n")
	}

	// 3. Long minified line windows cleanly around `at` with `...` ellipsis (start, middle, end, EOF).
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		for i in 0 ..< 200 {
			strings.write_byte(&sb, 'a' + u8(i % 26))
		}
		long_line := transmute([]u8)strings.to_string(sb)

		// Near start: right ellipsis only, caret aligned under offset 5.
		s_start, ok1 := tape.error_snippet(buf[:], long_line, 5, 40)
		testing.expect(t, ok1)
		lines1 := strings.split_lines(strings.trim_right(s_start, "\n"))
		defer delete(lines1)
		testing.expect_value(t, len(lines1), 2)
		testing.expect(t, !strings.has_prefix(lines1[0], "  ..."), s_start)
		testing.expect(t, strings.has_suffix(lines1[0], "..."), s_start)
		testing.expect_value(t, len(lines1[0]), 2 + 40)
		testing.expect_value(t, strings.index_byte(lines1[1], '^'), 2 + 5)

		// Middle: both left and right ellipsis, caret under exact target byte (`long_line[100]`).
		s_mid, ok2 := tape.error_snippet(buf[:], long_line, 100, 40)
		testing.expect(t, ok2)
		lines2 := strings.split_lines(strings.trim_right(s_mid, "\n"))
		defer delete(lines2)
		testing.expect_value(t, len(lines2), 2)
		testing.expect(t, strings.has_prefix(lines2[0], "  ..."), s_mid)
		testing.expect(t, strings.has_suffix(lines2[0], "..."), s_mid)
		testing.expect_value(t, len(lines2[0]), 2 + 40)
		caret2 := strings.index_byte(lines2[1], '^')
		testing.expect(t, caret2 >= 5 && caret2 < len(lines2[0]), s_mid)
		testing.expect_value(t, lines2[0][caret2], long_line[100])

		// Near end: left ellipsis only, caret under `long_line[198]`.
		s_end, ok3 := tape.error_snippet(buf[:], long_line, 198, 40)
		testing.expect(t, ok3)
		lines3 := strings.split_lines(strings.trim_right(s_end, "\n"))
		defer delete(lines3)
		testing.expect_value(t, len(lines3), 2)
		testing.expect(t, strings.has_prefix(lines3[0], "  ..."), s_end)
		testing.expect(t, !strings.has_suffix(lines3[0], "..."), s_end)
		caret3 := strings.index_byte(lines3[1], '^')
		testing.expect_value(t, lines3[0][caret3], long_line[198])

		// EOF of long minified line: left ellipsis only, caret one past last char.
		s_eof, ok4 := tape.error_snippet(buf[:], long_line, 200, 40)
		testing.expect(t, ok4)
		lines4 := strings.split_lines(strings.trim_right(s_eof, "\n"))
		defer delete(lines4)
		testing.expect_value(t, len(lines4), 2)
		testing.expect_value(t, strings.index_byte(lines4[1], '^'), len(lines4[0]))
	}

	// 4. Binary / CBOR / invalid UTF-8 / NUL / empty / NO_BYTE / tiny buffer safely skipped (`ok == false`).
	{
		cbor_bytes := []u8{0xA2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x01, 0x02}
		_, ok_cbor := tape.error_snippet(buf[:], cbor_bytes, 3)
		testing.expect(t, !ok_cbor)

		nul_bytes := []u8{'{', '"', 'a', 0x00, '"', '}'}
		_, ok_nul := tape.error_snippet(buf[:], nul_bytes, 3)
		testing.expect(t, !ok_nul)

		bad_utf8 := []u8{'a', 0xFF, 0xFE, 'b'}
		_, ok_u8 := tape.error_snippet(buf[:], bad_utf8, 1)
		testing.expect(t, !ok_u8)

		ctrl_soup := []u8{0x01, 0x02, 0x03, 0x04}
		_, ok_ctrl := tape.error_snippet(buf[:], ctrl_soup, 1)
		testing.expect(t, !ok_ctrl)

		_, ok_empty := tape.error_snippet(buf[:], nil, 0)
		testing.expect(t, !ok_empty)

		_, ok_nob := tape.error_snippet(buf[:], transmute([]u8)string("{}"), tape.NO_BYTE)
		testing.expect(t, !ok_nob)

		tiny: [4]u8
		_, ok_tiny := tape.error_snippet(tiny[:], transmute([]u8)string(`{"a":1}`), 2)
		testing.expect(t, !ok_tiny)
	}

	// 5. Extreme `at == max(u64) - 1` and `max_cols == max(int)` clamp cleanly without signed overflow.
	{
		src := transmute([]u8)string(`{"a": 1`)
		s_hi_at, ok_at := tape.error_snippet(buf[:], src, max(u64) - 1)
		testing.expect(t, ok_at)
		testing.expect_value(t, s_hi_at, "  {\"a\": 1\n         ^\n")

		s_hi_cols, ok_cols := tape.error_snippet(buf[:], src, 2, max(int))
		testing.expect(t, ok_cols)
		testing.expect_value(t, s_hi_cols, "  {\"a\": 1\n    ^\n")
	}

	// 6. `format_fault_with_snippet` formats header + snippet for text and omits snippet for binary.
	{
		src := transmute([]u8)string("{\n  \"a\": ?\n}\n")
		out := tape.format_fault_with_snippet(buf[:], "in.json", src, 9, "Unexpected character")
		testing.expect_value(t, out, "in.json:2:8: Unexpected character\n    \"a\": ?\n         ^\n")

		bin_out := tape.format_fault_with_snippet(buf[:], "in.cbor", []u8{0xA2, 0xFF}, 1, "Invalid CBOR", binary = true)
		testing.expect_value(t, bin_out, "in.cbor:byte 1: Invalid CBOR\n")
	}
}
