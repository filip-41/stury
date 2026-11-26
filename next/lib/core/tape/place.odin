package tape

import "base:runtime"
import "stury:lib/base/kernel"

// Source positions (`Place`) and a lazy 4 KiB block-checkpoint line table (`Line_Index`) stored on `Doc_Index`.
// Sequential lookups advance a cursor in O(1) amortized time without allocating checkpoints; out-of-order lookups build
// cumulative `\n` checkpoints once and scan at most half a block (2 KiB) from the nearer block end.

// Bytes of source covered by each checkpoint in `Line_Index.blocks`.
LINE_BLOCK :: 4096

// Where a document's `src[0]` stands in a larger source text (for framed records or sub-documents).
// `byte` is the 0-based byte offset of `src[0]`, `line` is the 0-based count of `\n` before `src[0]`
// (`0` means line 1), and `col` is the 0-based UTF-8 codepoint count on that line before `src[0]`.
Origin :: struct {
	byte: u64,
	line: u64,
	col:  u64,
}

// A position in a document's source: 0-based `byte` offset, 1-based `line` and UTF-8 scalar `col`.
// Binary formats (`.Binary`) and `.Held` documents without original inter-token bytes report `line = 0, col = 0`
// with their exact `byte` offset. `ok` is false when no source position exists.
Place :: struct {
	byte, line, col: u64,
	ok:              bool,
}

// Lazy line-checkpoint index and monotonic cursor for a document's source bytes.
// Zero-initialized; `destroy_line_index` frees `blocks`.
Line_Index :: struct {
	blocks:     []u64, // len == n_blocks + 1 when built; `blocks[b]` is `\n` count in `src[:b * LINE_BLOCK]`
	at:         u64,   // cursor byte offset
	line:       u64,   // 0-based `\n` count before `at`
	line_lo:    u64,   // byte offset of start of `at`'s line
	col:        u64,   // 0-based UTF-8 codepoint count in `src[line_lo:at]`
	has_cursor: bool,
	allocator:  runtime.Allocator,
}

// Frees `lines.blocks` and leaves `lines` zero.
destroy_line_index :: proc(lines: ^Line_Index) {
	if lines == nil {
		return
	}
	if lines.blocks != nil {
		delete(lines.blocks, lines.allocator)
	}
	lines^ = {}
}

// Returns the `Place` of byte `offset` in `src`, adding `base_byte` (0-based) and `base_line` (1-based).
// When `lines` is non-nil, uses its cursor for sequential / same-line lookups and lazily builds 4 KiB checkpoints
// on out-of-order jumps (using `lines.allocator` if set, else `allocator`).
@(require_results)
offset_place :: proc(
	src: []u8,
	lines: ^Line_Index,
	offset: u64,
	base_byte: u64 = 0,
	base_line: u64 = 1,
	allocator := context.allocator,
) -> Place {
	return place_at(src, lines, offset, base_byte, base_line, 0, allocator)
}

@(private = "file")
make_place :: #force_inline proc "contextless" (base_byte, offset, base_line, nl, col, base_col: u64) -> Place {
	return {
		byte = base_byte + offset,
		line = base_line + nl,
		col  = 1 + col + (base_col if nl == 0 else 0),
		ok   = true,
	}
}

@(private = "file")
same_line_col :: #force_inline proc "contextless" (src: []u8, line_lo, at, col, off: u64) -> u64 #no_bounds_check {
	if off >= at {
		return col + u64(kernel.count_chars(src[at:off]))
	}
	if at - off < off - line_lo {
		return col - u64(kernel.count_chars(src[off:at]))
	}
	return u64(kernel.count_chars(src[line_lo:off]))
}

// Internal `offset_place` supporting a 0-based `base_col` on the first line of `src` (for sub-document origins).
@(private, require_results)
place_at :: proc(
	src: []u8,
	lines: ^Line_Index,
	offset: u64,
	base_byte: u64,
	base_line: u64,
	base_col: u64,
	allocator: runtime.Allocator,
) -> Place #no_bounds_check {
	off := min(offset, u64(len(src)))
	if lines == nil {
		return stateless_place(src, off, offset, base_byte, base_line, base_col)
	}
	if !lines.has_cursor {
		lines.at, lines.line, lines.line_lo, lines.col, lines.has_cursor = 0, 0, 0, 0, true
	}

	// Fast path 1: backward or equal lookup on the cursor's current line (zero `\n` scans, no block table needed).
	if off <= lines.at && off >= lines.line_lo {
		lines.col = same_line_col(src, lines.line_lo, lines.at, lines.col, off)
		lines.at = off
		return make_place(base_byte, offset, base_line, lines.line, lines.col, base_col)
	}

	// Fast path 2: forward sequential advance without a large jump across an already-built block table.
	if off > lines.at && (len(lines.blocks) == 0 || off - lines.at <= LINE_BLOCK) {
		span := src[lines.at:off]
		if added := kernel.count_byte(span, '\n'); added == 0 {
			lines.col += u64(kernel.count_chars(span))
		} else {
			lines.line += u64(added)
			lines.line_lo = lines.at + u64(kernel.last_index_byte(span, '\n') + 1)
			lines.col = u64(kernel.count_chars(src[lines.line_lo:off]))
		}
		lines.at = off
		return make_place(base_byte, offset, base_line, lines.line, lines.col, base_col)
	}

	// Out-of-order jump: ensure 4 KiB block checkpoints exist.
	if len(lines.blocks) == 0 && !build_line_blocks(src, lines, allocator) {
		return stateless_place(src, off, offset, base_byte, base_line, base_col)
	}

	b := min(int(off / LINE_BLOCK), len(lines.blocks) - 2)
	blk_lo := u64(b * LINE_BLOCK)
	blk_hi := min(blk_lo + LINE_BLOCK, u64(len(src)))

	nl: u64
	if lines.blocks[b] == lines.blocks[b + 1] {
		nl = lines.blocks[b]
	} else if off - blk_lo <= blk_hi - off {
		nl = lines.blocks[b] + u64(kernel.count_byte(src[blk_lo:off], '\n'))
	} else {
		nl = lines.blocks[b + 1] - u64(kernel.count_byte(src[off:blk_hi], '\n'))
	}

	line_lo: u64
	if nl > lines.blocks[b] {
		line_lo = blk_lo + u64(kernel.last_index_byte(src[blk_lo:off], '\n') + 1)
	} else if nl == 0 {
		line_lo = 0
	} else {
		// Binary search for the first block with cumulative count == nl; the `\n` lies in the block before it.
		lo, hi := 0, b
		for lo < hi {
			mid := (lo + hi) / 2
			if lines.blocks[mid] < nl {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		prev_lo := u64((lo - 1) * LINE_BLOCK)
		line_lo = prev_lo + u64(kernel.last_index_byte(src[prev_lo:u64(lo * LINE_BLOCK)], '\n') + 1)
	}

	// Reuse cursor column if we landed on the same line (avoids rescanning huge single-line inputs).
	col := same_line_col(src, line_lo, lines.at, lines.col, off) if line_lo == lines.line_lo else u64(kernel.count_chars(src[line_lo:off]))
	lines.at, lines.line, lines.line_lo, lines.col = off, nl, line_lo, col
	return make_place(base_byte, offset, base_line, nl, col, base_col)
}

@(private = "file")
stateless_place :: proc "contextless" (src: []u8, off, raw_offset, base_byte, base_line, base_col: u64) -> Place #no_bounds_check {
	head := src[:off]
	nl := u64(kernel.count_byte(head, '\n'))
	line_lo := u64(kernel.last_index_byte(head, '\n') + 1)
	return make_place(base_byte, raw_offset, base_line, nl, u64(kernel.count_chars(src[line_lo:off])), base_col)
}

@(private = "file")
build_line_blocks :: proc(src: []u8, lines: ^Line_Index, fallback: runtime.Allocator) -> bool #no_bounds_check {
	if len(src) == 0 {
		return false
	}
	alloc := lines.allocator if lines.allocator.procedure != nil else fallback
	if alloc.procedure == nil {
		return false
	}
	n_blocks := (len(src) + LINE_BLOCK - 1) / LINE_BLOCK
	blocks, err := make([]u64, n_blocks + 1, alloc)
	if err != nil || raw_data(blocks) == nil {
		return false
	}
	acc: u64
	for b in 0 ..< n_blocks {
		blocks[b] = acc
		lo := b * LINE_BLOCK
		acc += u64(kernel.count_byte(src[lo:min(lo + LINE_BLOCK, len(src))], '\n'))
	}
	blocks[n_blocks] = acc
	lines.blocks, lines.allocator = blocks, alloc
	return true
}

// The starting byte offset of node `at` in `doc`'s source text (before any opening quote or CBOR item header,
// and at a CBOR tag or YAML alias when present). Returns `ok = false` for `SPELLING_PLACED` synthetic keys.
@(require_results)
node_offset :: proc "contextless" (doc: ^Document, at: Node_Index) -> (off: u64, ok: bool) #no_bounds_check {
	if doc == nil || int(at) >= len(doc.nodes) {
		return 0, false
	}
	t := doc.nodes[at]
	if t.kind == .String && t.spelling & SPELLING_PLACED != 0 {
		return 0, false
	}
	off = t.lo
	if t.kind < .Array && doc.format != nil && doc.format.bounds != nil {
		src, tok := node_src(doc, t)
		head, _ := doc.format.bounds(src, tok)
		if u64(head) <= off {
			off -= u64(head)
		}
	}
	if .Alias in doc.present {
		for f in facts_of(doc, at) {
			if f.kind == .Alias {
				off = f.lo
				break
			}
		}
	}
	if doc.format != nil && .Binary in doc.format.caps && .Tag in doc.present {
		for f in facts_of(doc, at) {
			if f.kind == .Tag && f.lo < off {
				off = f.lo
			}
		}
	}
	return off, true
}

// The `Origin` of `doc` (zero when `doc.ext == nil`).
doc_origin :: #force_inline proc "contextless" (doc: ^Document) -> Origin {
	return doc.ext.origin if doc != nil && doc.ext != nil else {}
}

// Sets `doc`'s `Origin`, allocating `doc.ext` when nil.
set_doc_origin :: proc(doc: ^Document, origin: Origin, allocator := context.allocator) -> runtime.Allocator_Error {
	if doc == nil {
		return nil
	}
	if doc.ext == nil {
		alloc := doc.allocator if doc.allocator.procedure != nil else allocator
		doc.ext = ext_make(nil, nil, alloc) or_return
		if doc.allocator.procedure == nil {
			doc.allocator = alloc
		}
	}
	doc.ext.origin = origin
	return nil
}

// Returns the `Place` of node `at` in `doc`, using `idx.lines` when `idx` is non-nil.
// Binary formats (`.Binary` in `doc.format.caps`) and `.Held` documents return `line = 0, col = 0` with `byte`.
@(require_results)
node_place :: proc(doc: ^Document, idx: ^Doc_Index, at: Node_Index, allocator := context.allocator) -> Place {
	off, ok := node_offset(doc, at)
	if !ok {
		return {}
	}
	origin := doc_origin(doc)
	if (doc.format != nil && .Binary in doc.format.caps) || .Held in doc.flags || (len(doc.src) == 0 && off > 0) {
		return {byte = origin.byte + off, line = 0, col = 0, ok = true}
	}
	lines: ^Line_Index
	alloc := allocator
	if idx != nil {
		lines = &idx.lines
		if idx.allocator.procedure != nil {
			alloc = idx.allocator
			if lines.allocator.procedure == nil {
				lines.allocator = idx.allocator
			}
		}
	}
	return place_at(doc.src, lines, off, origin.byte, origin.line + 1, origin.col, alloc)
}

// Default maximum display width (in columns) for `error_snippet`.
SNIPPET_DEFAULT_COLS :: 120

@(private = "file")
SNIPPET_TAB_WIDTH :: 4

// Formats a bounded two-line source snippet with a column-aligned `^` caret pointing at byte offset `at` in `src`:
//   <source line>
//   <spaces>^
// Expands tabs to 4 spaces, strips `\r\n`/`\n`, windows long lines around `at` with `...`, handles EOF
// (`at == u64(len(src))`), and returns `ok = false` for empty, binary, or non-UTF8 inputs (or if `buf` is too small).
@(require_results)
error_snippet :: proc "contextless" (buf: []u8, src: []u8, at: u64, max_cols := SNIPPET_DEFAULT_COLS) -> (snippet: string, ok: bool) #no_bounds_check {
	if len(src) == 0 || at == NO_BYTE || len(buf) < 6 {
		return "", false
	}
	cap_cols := clamp(max_cols, 16, 4096) if max_cols > 0 else SNIPPET_DEFAULT_COLS
	scan_limit := cap_cols * 4 + 32

	pos := int(min(at, u64(len(src))))
	if pos == len(src) && pos > 0 && src[pos - 1] == '\n' {
		pos -= 1
		if pos > 0 && src[pos - 1] == '\r' {
			pos -= 1
		}
	}

	scan_lo := pos
	for scan_lo > 0 && src[scan_lo - 1] != '\n' && pos - scan_lo < scan_limit {
		scan_lo -= 1
	}
	left_cut := scan_lo > 0 && src[scan_lo - 1] != '\n'
	if left_cut {
		for scan_lo < pos && (src[scan_lo] & 0xC0) == 0x80 {
			scan_lo += 1
		}
	}

	scan_hi := pos
	for scan_hi < len(src) && src[scan_hi] != '\n' && src[scan_hi] != '\r' && scan_hi - pos < scan_limit {
		scan_hi += 1
	}
	right_cut := scan_hi < len(src) && src[scan_hi] != '\n' && src[scan_hi] != '\r'
	if right_cut {
		scan_hi = trim_trailing_partial_utf8(src, scan_lo, scan_hi, pos)
	}
	for scan_hi > scan_lo && src[scan_hi - 1] == '\r' {
		scan_hi -= 1
	}
	if pos > scan_hi {
		pos = scan_hi
	}
	// Snap `pos` onto a UTF-8 codepoint boundary when it falls inside a multi-byte sequence.
	for pos > scan_lo && pos < scan_hi && (src[pos] & 0xC0) == 0x80 {
		pos -= 1
	}

	line := src[scan_lo:scan_hi]
	if !snippet_line_is_text(line) {
		return "", false
	}

	rel_pos := pos - scan_lo
	pre_cols, total_cols := 0, 0
	for i := 0; i < len(line); {
		step := utf8_char_len(line[i])
		if step <= 0 || i + step > len(line) {
			return "", false
		}
		w := SNIPPET_TAB_WIDTH if line[i] == '\t' else 1
		if i < rel_pos {
			pre_cols += w
		}
		total_cols += w
		i += step
	}

	has_left := left_cut
	has_right := right_cut
	win_lo := 0
	win_hi := total_cols
	if !left_cut && !right_cut && total_cols <= cap_cols {
		// Entire line fits cleanly within `cap_cols`.
	} else if !left_cut && pre_cols <= cap_cols - 4 {
		has_left = false
		has_right = true
		win_lo = 0
		win_hi = min(total_cols, cap_cols - 3)
	} else if !right_cut && total_cols - pre_cols <= cap_cols - 4 {
		has_left = true
		has_right = false
		win_hi = total_cols
		win_lo = max(0, total_cols - (cap_cols - 3))
	} else {
		has_left = true
		has_right = true
		avail := max(cap_cols - 6, 4)
		win_lo = max(0, pre_cols - avail / 2)
		win_hi = min(total_cols, win_lo + avail)
		if win_hi - win_lo < avail && win_lo > 0 {
			win_lo = max(0, win_hi - avail)
		}
	}

	caret_col := (3 if has_left else 0) + clamp(pre_cols - win_lo, 0, win_hi - win_lo)

	n := 0
	if !buf_write_str(buf, &n, "  ") {
		return "", false
	}
	if has_left && !buf_write_str(buf, &n, "...") {
		return "", false
	}

	col := 0
	for i := 0; i < len(line); {
		step := utf8_char_len(line[i])
		if line[i] == '\t' {
			for k in 0 ..< SNIPPET_TAB_WIDTH {
				if col + k >= win_lo && col + k < win_hi {
					if !buf_write_byte(buf, &n, ' ') {
						return "", false
					}
				}
			}
			col += SNIPPET_TAB_WIDTH
		} else {
			if col >= win_lo && col < win_hi {
				b := line[i]
				if step == 1 && (b < 0x20 || b == 0x7f) {
					if !buf_write_byte(buf, &n, '?') {
						return "", false
					}
				} else if !buf_write_bytes(buf, &n, line[i:i + step]) {
					return "", false
				}
			}
			col += 1
		}
		i += step
	}

	if has_right && !buf_write_str(buf, &n, "...") {
		return "", false
	}
	if !buf_write_str(buf, &n, "\n  ") {
		return "", false
	}
	for _ in 0 ..< caret_col {
		if !buf_write_byte(buf, &n, ' ') {
			return "", false
		}
	}
	if !buf_write_str(buf, &n, "^\n") {
		return "", false
	}
	return string(buf[:n]), true
}

// Formats `<file>:<line>:<col>: <msg>\n` (or `<file>:byte <at>: <msg>\n` for binary inputs) followed by the
// bounded `error_snippet` into `buf` when the input is non-binary text and space permits.
@(require_results)
format_fault_with_snippet :: proc "contextless" (
	buf: []u8,
	file: string,
	src: []u8,
	at: u64,
	msg: string,
	binary := false,
	max_cols := SNIPPET_DEFAULT_COLS,
) -> string {
	m := Message{buf = buf}
	if file != "" {
		message_text(&m, file)
		message_text(&m, ":")
	}
	if at != NO_BYTE {
		if binary {
			message_text(&m, "byte ")
			message_number(&m, min(at, u64(len(src))))
			message_text(&m, ": ")
		} else {
			off := min(at, u64(len(src)))
			pl := stateless_place(src, off, at, 0, 1, 0)
			message_number(&m, pl.line)
			message_text(&m, ":")
			message_number(&m, pl.col)
			message_text(&m, ": ")
		}
	}
	message_text(&m, msg if msg != "" else "parse error")
	message_text(&m, "\n")
	if !binary && at != NO_BYTE && len(src) > 0 && m.n < len(buf) {
		if snip, ok := error_snippet(buf[m.n:], src, at, max_cols); ok {
			m.n += len(snip)
		}
	}
	return string(m.buf[:m.n])
}

@(private = "file")
buf_write_byte :: #force_inline proc "contextless" (buf: []u8, n: ^int, b: u8) -> bool #no_bounds_check {
	if n^ >= len(buf) {
		return false
	}
	buf[n^] = b
	n^ += 1
	return true
}

@(private = "file")
buf_write_bytes :: #force_inline proc "contextless" (buf: []u8, n: ^int, s: []u8) -> bool #no_bounds_check {
	if n^ + len(s) > len(buf) {
		return false
	}
	copy(buf[n^:], s)
	n^ += len(s)
	return true
}

@(private = "file")
buf_write_str :: #force_inline proc "contextless" (buf: []u8, n: ^int, s: string) -> bool #no_bounds_check {
	return buf_write_bytes(buf, n, transmute([]u8)s)
}

@(private = "file")
utf8_char_len :: #force_inline proc "contextless" (b: u8) -> int {
	if b < 0x80 {
		return 1
	}
	if b >= 0xC2 && b <= 0xDF {
		return 2
	}
	if b >= 0xE0 && b <= 0xEF {
		return 3
	}
	if b >= 0xF0 && b <= 0xF4 {
		return 4
	}
	return 0
}

@(private = "file")
trim_trailing_partial_utf8 :: proc "contextless" (src: []u8, lo, hi, min_hi: int) -> int #no_bounds_check {
	// Walk back at most 3 bytes from `hi` to find any multi-byte leader cut short by the scan cap.
	k := hi
	back := 0
	for k > lo && back < 4 {
		k -= 1
		back += 1
		b := src[k]
		if (b & 0xC0) != 0x80 {
			need := utf8_char_len(b)
			if need > 0 && k + need > hi && k >= min_hi {
				return k
			}
			break
		}
	}
	return hi
}

// Rejects NUL bytes, invalid UTF-8 sequences, and binary control-byte streams.
@(private = "file")
snippet_line_is_text :: proc "contextless" (line: []u8) -> bool #no_bounds_check {
	ctrl_cnt := 0
	char_cnt := 0
	for i := 0; i < len(line); {
		b0 := line[i]
		if b0 == 0 {
			return false
		}
		if b0 < 0x80 {
			if (b0 < 0x20 && b0 != '\t') || b0 == 0x7f {
				ctrl_cnt += 1
			}
			char_cnt += 1
			i += 1
			continue
		}
		step := utf8_char_len(b0)
		if step < 2 || i + step > len(line) {
			return false
		}
		switch step {
		case 2:
			if (line[i + 1] & 0xC0) != 0x80 {
				return false
			}
		case 3:
			b1, b2 := line[i + 1], line[i + 2]
			if (b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 {
				return false
			}
			if (b0 == 0xE0 && b1 < 0xA0) || (b0 == 0xED && b1 >= 0xA0) {
				return false
			}
		case 4:
			b1, b2, b3 := line[i + 1], line[i + 2], line[i + 3]
			if (b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80 {
				return false
			}
			if (b0 == 0xF0 && b1 < 0x90) || (b0 == 0xF4 && b1 >= 0x90) {
				return false
			}
		}
		char_cnt += 1
		i += step
	}
	if ctrl_cnt >= 2 && ctrl_cnt * 4 >= char_cnt {
		return false
	}
	return true
}
