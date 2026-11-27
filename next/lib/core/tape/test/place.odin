package tape_test

import "base:runtime"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

@(private = "file")
brute_place :: proc(src: []u8, offset: u64, base_byte: u64 = 0, base_line: u64 = 1, base_col: u64 = 0) -> tape.Place {
	off := min(offset, u64(len(src)))
	line := base_line
	col := u64(1) + base_col
	for i := u64(0); i < off; i += 1 {
		b := src[i]
		if b == '\n' {
			line += 1
			col = 1
		} else if b & 0xC0 != 0x80 {
			col += 1
		}
	}
	return {byte = base_byte + offset, line = line, col = col, ok = true}
}

@(test)
offset_place_ascii_utf8_crlf_and_empty :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// Empty input.
	{
		lines: tape.Line_Index
		defer tape.destroy_line_index(&lines)
		p := tape.offset_place(nil, &lines, 0, allocator = alloc)
		testing.expect(t, p.ok && p.byte == 0 && p.line == 1 && p.col == 1)
	}

	// Mixed ASCII, 2/3/4-byte UTF-8, LF, and CRLF.
	src := transmute([]u8)string("aé中😀b\r\nnext\n😀\r\nend")
	lines: tape.Line_Index
	defer tape.destroy_line_index(&lines)

	// Sequential forward pass.
	for off in u64(0) ..= u64(len(src)) {
		if off < u64(len(src)) && src[off] & 0xC0 == 0x80 {
			continue
		}
		got := tape.offset_place(src, &lines, off, allocator = alloc)
		want := brute_place(src, off)
		testing.expectf(t, got == want, "seq off %d: got %v, want %v", off, got, want)
	}
	// Sequential backward pass (exercises same-line backward and block lookup).
	for off := i64(len(src)); off >= 0; off -= 1 {
		if off < i64(len(src)) && src[off] & 0xC0 == 0x80 {
			continue
		}
		got := tape.offset_place(src, &lines, u64(off), allocator = alloc)
		want := brute_place(src, u64(off))
		testing.expectf(t, got == want, "rev off %d: got %v, want %v", off, got, want)
	}

	// Stateless (`lines == nil`) with base_byte and base_line.
	got_base := tape.offset_place(src, nil, 13, base_byte = 100, base_line = 10)
	want_base := brute_place(src, 13, base_byte = 100, base_line = 10)
	testing.expect_value(t, got_base, want_base)

	// NO_BYTE returns ok == false without wraparound.
	no_b := tape.offset_place(src, &lines, tape.NO_BYTE, base_byte = 100, base_line = 10, allocator = alloc)
	testing.expect(t, !no_b.ok && no_b == {})
	no_b_stateless := tape.offset_place(src, nil, tape.NO_BYTE, base_byte = 100, base_line = 10)
	testing.expect(t, !no_b_stateless.ok && no_b_stateless == {})
}

@(test)
offset_place_large_random_matches_bruteforce :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// Build a > 40 KiB text with varying line lengths, CRLF/LF, blank runs > 4 KiB (no newlines in a block), and UTF-8.
	sb := strings.builder_make(alloc)
	defer strings.builder_destroy(&sb)
	for i in 0 ..< 600 {
		if i == 150 {
			// A single line spanning > 10 KiB (> 2 full 4 KiB blocks with zero newlines).
			for _ in 0 ..< 1100 {
				strings.write_string(&sb, "ab😀cdé")
			}
			strings.write_byte(&sb, '\n')
			continue
		}
		if i % 3 == 0 {
			strings.write_string(&sb, "héllo, world — 日本語 🎉\r\n")
		} else {
			strings.write_string(&sb, "plain ascii line with some padding 0123456789abcdef\n")
		}
	}
	src := transmute([]u8)strings.to_string(sb)
	testing.expect(t, len(src) > 32 * 1024)

	lines: tape.Line_Index
	defer tape.destroy_line_index(&lines)

	// 1. Sequential lookups should not allocate the block table.
	for off := u64(0); off < u64(len(src)); off += 509 {
		for off < u64(len(src)) && src[off] & 0xC0 == 0x80 {
			off += 1
		}
		got := tape.offset_place(src, &lines, off, allocator = alloc)
		want := brute_place(src, off)
		testing.expectf(t, got == want, "seq off %d: got %v, want %v", off, got, want)
	}
	testing.expect(t, len(lines.blocks) == 0)

	// 2. Random out-of-order lookups trigger lazy block checkpoints and agree 100% with brute-force.
	state := rand.create(0x12345)
	rng := rand.default_random_generator(&state)
	for _ in 0 ..< 500 {
		off := u64(rand.int_max(len(src) + 1, rng))
		for off < u64(len(src)) && src[off] & 0xC0 == 0x80 {
			off += 1
		}
		got := tape.offset_place(src, &lines, off, allocator = alloc)
		want := brute_place(src, off)
		testing.expectf(t, got == want, "rand off %d: got %v, want %v", off, got, want)
	}
	testing.expect(t, len(lines.blocks) > 8)
}

@(test)
node_place_json_cbor_origin_and_held :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// JSON document with UTF-8 prefix and nested nodes.
	src := transmute([]u8)string("{\n  \"é\": \"val\",\n  \"n\": 42\n}\n")
	doc, err := json.build(src, .Json, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	idx := tape.Doc_Index{allocator = alloc}
	defer tape.destroy_index(&idx)
	r := tape.Reader{&doc, &idx}

	root_p := tape.node_place(&doc, &idx, tape.ROOT)
	testing.expect(t, root_p.ok && root_p.byte == 0 && root_p.line == 1 && root_p.col == 1)

	val_node, vp := tape.member(r, tape.ROOT, "é")
	testing.expect(t, vp == .Found)
	val_p := tape.node_place(&doc, &idx, val_node)
	// Line 2: `  "é": "val",` -> bytes: 2 spaces, '"', 2 bytes 'é', '"', ':', ' ', '"' (opening quote is col 8, byte 10).
	testing.expect(t, val_p.ok && val_p.line == 2 && val_p.col == 8 && val_p.byte == 10)

	n_node, np := tape.member(r, tape.ROOT, "n")
	testing.expect(t, np == .Found)
	n_p := tape.node_place(&doc, &idx, n_node)
	testing.expect(t, n_p.ok && n_p.line == 3 && n_p.col == 8)

	// Sub-document Origin propagation + clone_document preservation.
	ext, eerr := tape.ext_make(nil, nil, alloc)
	testing.expect(t, eerr == nil)
	ext.origin = {byte = 500, line = 20, col = 4}
	doc.ext = ext
	cloned, cerr := tape.clone_document(&doc, alloc)
	testing.expect(t, cerr == nil)
	defer tape.destroy_document(&cloned)
	c_root := tape.node_place(&cloned, nil, tape.ROOT)
	testing.expect(t, c_root.ok && c_root.byte == 500 && c_root.line == 21 && c_root.col == 5)
	c_val := tape.node_place(&cloned, nil, val_node)
	testing.expect(t, c_val.ok && c_val.byte == 510 && c_val.line == 22 && c_val.col == 8)

	// CBOR binary format reports byte offset with line = 0, col = 0.
	cbor_bytes := []u8{0xA2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x01, 0x02}
	cdoc, cberr := cbor.build(cbor_bytes, .Cbor, {}, alloc)
	testing.expect(t, cberr == nil)
	defer tape.destroy_document(&cdoc)
	cr := tape.Reader{&cdoc, nil}
	b_arr, _ := tape.member(cr, tape.ROOT, "b")
	e0, _ := tape.element(cr, b_arr, 0)
	e1, _ := tape.element(cr, b_arr, 1)
	p0 := tape.node_place(&cdoc, nil, e0)
	p1 := tape.node_place(&cdoc, nil, e1)
	testing.expect(t, p0.ok && p0.line == 0 && p0.col == 0 && p0.byte == 7)
	testing.expect(t, p1.ok && p1.line == 0 && p1.col == 0 && p1.byte == 8)

	// Held document reports byte offset with line = 0, col = 0.
	held_doc := doc
	held_doc.flags += {.Held}
	hp := tape.node_place(&held_doc, nil, n_node)
	testing.expect(t, hp.ok && hp.line == 0 && hp.col == 0 && hp.byte == 500 + n_p.byte)

	// M1: Synthetic DSV `SPELLING_PLACED` key has no source offset (`ok == false`).
	placed_nodes := [1]tape.Node{{kind = .String, spelling = tape.SPELLING_PLACED, lo = 3, n = 0}}
	placed_doc := tape.Document{src = transmute([]u8)string("a,b,c"), nodes = placed_nodes[:]}
	pp := tape.node_place(&placed_doc, nil, tape.ROOT)
	testing.expect(t, !pp.ok)

	// NO_NODE returns ok == false safely (including on 32-bit targets where int(NO_NODE) == -1).
	no_np := tape.node_place(&doc, &idx, tape.NO_NODE)
	testing.expect(t, !no_np.ok && no_np == {})
	when size_of(uintptr) == 8 {
		testing.expect_value(t, size_of(tape.Line_Index), 64)
	}
}

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

	// 6. Bare `\r` is symmetric whether `at` is before or after `\r`, while CRLF still strips trailing `\r`.
	{
		bare := transmute([]u8)string("foo\rbar")
		s1, ok1 := tape.error_snippet(buf[:], bare, 1)
		testing.expect(t, ok1)
		testing.expect_value(t, s1, "  foo?bar\n   ^\n")
		s2, ok2 := tape.error_snippet(buf[:], bare, 5)
		testing.expect(t, ok2)
		testing.expect_value(t, s2, "  foo?bar\n       ^\n")

		crlf := transmute([]u8)string("abc\r\ndef")
		sc, okc := tape.error_snippet(buf[:], crlf, 3)
		testing.expect(t, okc)
		testing.expect_value(t, sc, "  abc\n     ^\n")
	}
}
