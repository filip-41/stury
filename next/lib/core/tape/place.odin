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
