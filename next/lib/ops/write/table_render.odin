package write

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"

// Output-only plain-text aligned table writer (`--to table`) for any `tape.Document`.
// Zero `context.temp_allocator`, zero `core:os`, WASM-safe, and OOM-safe.

// Visual border style for plain-text rendered tables.
Table_Style :: enum u8 {
	// Aligned columns separated by spaces with a `-` header underline and no outer border.
	Plain,
	// Aligned columns separated by spaces with no horizontal separator rule.
	Compact,
	// Unicode box-drawing borders (`┌ ┬ ┐`, `│`, `├ ┼ ┤`, `└ ┴ ┘`, `─`).
	Box,
	// Pure ASCII box borders (`+`, `-`, `|`).
	Ascii,
}

// Options controlling plain-text table rendering.
Table_Render_Options :: struct {
	// Value node to render (`tape.ROOT` by default).
	node:          tape.Node_Index,
	// Border style (`.Plain` by default).
	style:         Table_Style,
	// Layout for a single root object (`.Key_Value` by default).
	object_layout: Object_Layout,
	// Column alignment heuristic (`.Auto` by default).
	align:         Column_Align,
	// Sort object keys / column headers lexicographically by byte order.
	sort_keys:     bool,
	// Omit the header row (and its separator rule).
	no_header:     bool,
	// Spaces between columns in `.Plain` / `.Compact` styles (0 defaults to 2).
	column_gap:    u8,
	// Maximum display width per cell (0 = unlimited). Truncates overflowing cells cleanly by display width.
	max_col_width: int,
	// Display text for `null` values (`nil` defaults to `"null"`).
	null_text:     Maybe(string),
	// Column header for scalar roots or arrays of scalars (`""` defaults to `"value"`).
	value_header:  string,
}

// Writes `doc` as an aligned plain-text table into a newly allocated buffer owned by the caller.
@(require_results)
write_table :: proc(doc: ^tape.Document, opts := Table_Render_Options{}, allocator := context.allocator) -> (text: []u8, err: Error) {
	return render_doc(doc, opts, allocator)
}

// Streams `doc` as an aligned plain-text table into `sink`.
@(require_results)
write_table_to :: proc(sink: io.Writer, doc: ^tape.Document, opts := Table_Render_Options{}, allocator := context.allocator) -> Error {
	return render_doc_to(sink, doc, opts, allocator)
}

// Writes a batch of record documents as one unified aligned plain-text table into a buffer owned by the caller.
@(require_results)
write_table_docs :: proc(docs: []tape.Document, opts := Table_Render_Options{}, allocator := context.allocator) -> (text: []u8, err: Error) {
	return render_docs(docs, opts, allocator)
}

// ---------------------------------------------------------------------------
// Plain-text table emitter
// ---------------------------------------------------------------------------

@(private)
emit_plain_table :: proc(out: ^Out, grid: ^Render_Grid, opts: Table_Render_Options, allocator: runtime.Allocator) -> Error {
	cols := len(grid.headers)
	rows := grid.rows
	if cols == 0 || (opts.no_header && rows == 0) {
		return out.err
	}
	widths, werr := make_slice(int, cols, allocator)
	if werr != nil {
		return werr
	}
	defer delete(widths, allocator)
	right, rerr := make_slice(bool, cols, allocator)
	if rerr != nil {
		return rerr
	}
	defer delete(right, allocator)

	min_w := 1 if (opts.style == .Plain && !opts.no_header) else 0
	compute_column_metrics(grid, opts.align, opts.no_header, min_w, min_w, opts.max_col_width, widths, right)

	gap := int(opts.column_gap) if opts.column_gap > 0 else 2
	switch opts.style {
	case .Plain, .Compact:
		if !opts.no_header {
			emit_plain_row(out, grid.text_buf[:], grid.headers[:], widths, right, opts, gap, true)
			if opts.style == .Plain {
				for c in 0 ..< cols {
					if out.err != nil {
						return out.err
					}
					if c > 0 {
						put_spaces(out, gap)
					}
					put_repeat_byte(out, '-', max(widths[c], 1))
				}
				put_byte(out, '\n')
			}
		}
		for r in 0 ..< rows {
			if out.err != nil {
				return out.err
			}
			emit_plain_row(out, grid.text_buf[:], grid.cells[r * cols:][:cols], widths, right, opts, gap, false)
		}
	case .Box, .Ascii:
		Box_Chars :: struct {
			tl, tm, tr, ml, mm, mr, bl, bm, br, h, v: string,
		}
		ch := Box_Chars{"┌", "┬", "┐", "├", "┼", "┤", "└", "┴", "┘", "─", "│"} if opts.style == .Box else Box_Chars{"+", "+", "+", "+", "+", "+", "+", "+", "+", "-", "|"}
		emit_box_rule(out, widths, ch.tl, ch.tm, ch.tr, ch.h)
		if !opts.no_header {
			emit_bordered_row(out, grid.text_buf[:], grid.headers[:], widths, right, opts, ch.v, true)
			if rows > 0 {
				emit_box_rule(out, widths, ch.ml, ch.mm, ch.mr, ch.h)
			}
		}
		for r in 0 ..< rows {
			if out.err != nil {
				return out.err
			}
			emit_bordered_row(out, grid.text_buf[:], grid.cells[r * cols:][:cols], widths, right, opts, ch.v, false)
		}
		emit_box_rule(out, widths, ch.bl, ch.bm, ch.br, ch.h)
	}
	return out.err
}

@(private = "file")
emit_plain_row :: proc(out: ^Out, buf: []u8, cells: []Cell_Span, widths: []int, right: []bool, opts: Table_Render_Options, gap: int, is_header: bool) {
	// Find the last cell that carries visible output so left-aligned trailing columns avoid trailing spaces.
	last_visible := -1
	for c := len(cells) - 1; c >= 0; c -= 1 {
		if cells[c].n > 0 {
			last_visible = c
			break
		}
	}
	if last_visible < 0 {
		put_byte(out, '\n')
		return
	}
	for c in 0 ..= last_visible {
		if c > 0 {
			put_spaces(out, gap)
		}
		cell := cells[c]
		s := string(buf[cell.lo:][:cell.n])
		align_right := cell_align_right(cell, right[c], opts.align, is_header)
		put_aligned_cell(out, s, cell.width, widths[c], align_right, c < last_visible, opts.max_col_width, opts.style == .Ascii)
	}
	put_byte(out, '\n')
}

@(private = "file")
emit_bordered_row :: proc(out: ^Out, buf: []u8, cells: []Cell_Span, widths: []int, right: []bool, opts: Table_Render_Options, bar: string, is_header: bool) {
	bar_bytes := transmute([]u8)bar
	for cell, c in cells {
		put(out, bar_bytes)
		put_byte(out, ' ')
		s := string(buf[cell.lo:][:cell.n])
		align_right := cell_align_right(cell, right[c], opts.align, is_header)
		put_aligned_cell(out, s, cell.width, widths[c], align_right, true, opts.max_col_width, opts.style == .Ascii)
		put_byte(out, ' ')
	}
	put(out, bar_bytes)
	put_byte(out, '\n')
}

@(private = "file")
emit_box_rule :: proc(out: ^Out, widths: []int, left, mid, right_edge, fill: string) {
	put_str(out, left)
	fill_bytes := transmute([]u8)fill
	mid_bytes := transmute([]u8)mid
	for w, c in widths {
		if out.err != nil {
			return
		}
		if c > 0 {
			put(out, mid_bytes)
		}
		if len(fill_bytes) == 1 {
			put_repeat_byte(out, fill_bytes[0], w + 2)
		} else {
			for _ in 0 ..< w + 2 {
				put(out, fill_bytes)
			}
		}
	}
	put_str(out, right_edge)
	put_byte(out, '\n')
}

@(private = "file")
cell_align_right :: #force_inline proc "contextless" (cell: Cell_Span, col_is_right: bool, align: Column_Align, is_header: bool) -> bool {
	return align == .Right || (align == .Auto && col_is_right && (is_header || .Numeric in cell.flags))
}

@(private = "file")
put_aligned_cell :: #force_inline proc(out: ^Out, s: string, width, col_width: int, align_right, pad_trailing: bool, max_width: int, ascii_ellipsis: bool) {
	prefix, suffix, used := s, "", width
	if max_width > 0 && width > max_width {
		prefix, used, suffix = truncate_display(s, max_width, ascii_ellipsis)
	}
	put_padded_cell(out, prefix, suffix, max(col_width - used, 0), align_right, pad_trailing)
}
