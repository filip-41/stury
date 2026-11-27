package write

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"

// Output-only GitHub-Flavored Markdown (GFM) pipe table writer (`--to markdown`) for any `tape.Document`.
// Zero `context.temp_allocator`, zero `core:os`, WASM-safe, and OOM-safe.

// Options controlling GitHub-Flavored Markdown table rendering.
Markdown_Options :: struct {
	// Value node to render (`tape.ROOT` by default).
	node:          tape.Node_Index,
	// Layout for a single root object (`.Key_Value` by default).
	object_layout: Object_Layout,
	// Column alignment heuristic (`.Auto` emits `---:` when non-null/non-absent data cells are all numbers, `---` otherwise).
	align:         Column_Align,
	// Sort object keys / column headers lexicographically by byte order.
	sort_keys:     bool,
	// Omit column-width padding spaces (emits compact `| val | 42 |` rows with `| --- | ---: |` dividers).
	compact:       bool,
	// Display text for `null` values (`nil` defaults to `"null"`).
	null_text:     Maybe(string),
	// Column header for scalar roots or arrays of scalars (`""` defaults to `"value"`).
	value_header:  string,
}

// Writes `doc` as a GitHub-Flavored Markdown pipe table into a newly allocated buffer owned by the caller.
@(require_results)
write_markdown :: proc(doc: ^tape.Document, opts := Markdown_Options{}, allocator := context.allocator) -> (text: []u8, err: Error) {
	return render_doc(doc, opts, allocator)
}

// Streams `doc` as a GitHub-Flavored Markdown pipe table into `sink`.
@(require_results)
write_markdown_to :: proc(sink: io.Writer, doc: ^tape.Document, opts := Markdown_Options{}, allocator := context.allocator) -> Error {
	return render_doc_to(sink, doc, opts, allocator)
}

// Writes a batch of record documents as one unified GitHub-Flavored Markdown pipe table into a buffer owned by the caller.
@(require_results)
write_markdown_docs :: proc(docs: []tape.Document, opts := Markdown_Options{}, allocator := context.allocator) -> (text: []u8, err: Error) {
	return render_docs(docs, opts, allocator)
}

// ---------------------------------------------------------------------------
// GFM pipe table emitter
// ---------------------------------------------------------------------------

@(private)
emit_markdown_table :: proc(out: ^Out, grid: ^Render_Grid, opts: Markdown_Options, allocator: runtime.Allocator) -> Error {
	cols := len(grid.headers)
	if cols == 0 {
		return out.err
	}
	widths: []int
	if !opts.compact {
		werr: runtime.Allocator_Error
		widths, werr = make_slice(int, cols, allocator)
		if werr != nil {
			return werr
		}
	}
	defer delete(widths, allocator)

	right: []bool
	if !opts.compact || opts.align == .Auto {
		rerr: runtime.Allocator_Error
		right, rerr = make_slice(bool, cols, allocator)
		if rerr != nil {
			return rerr
		}
		// GFM divider cells use at least 3 dashes (`---`, or `---:` = 4 chars for right-aligned columns).
		compute_column_metrics(grid, opts.align, false, 3, 4, 0, widths, right)
	}
	defer delete(right, allocator)

	// Header row.
	emit_markdown_row(out, grid.text_buf[:], grid.headers[:], widths, right, opts.compact)
	if out.err != nil {
		return out.err
	}

	// Separator row.
	for c in 0 ..< cols {
		if out.err != nil {
			return out.err
		}
		put_str(out, "| ")
		is_right := right[c] if len(right) > 0 else opts.align == .Right
		if opts.compact {
			put_str(out, "---:" if is_right else "---")
		} else if is_right {
			put_repeat_byte(out, '-', max(widths[c] - 1, 3))
			put_byte(out, ':')
		} else {
			put_repeat_byte(out, '-', max(widths[c], 3))
		}
		put_byte(out, ' ')
	}
	put_str(out, "|\n")

	// Data rows.
	for r in 0 ..< grid.rows {
		if out.err != nil {
			return out.err
		}
		row_cells := grid.cells[r * cols:][:cols]
		emit_markdown_row(out, grid.text_buf[:], row_cells, widths, right, opts.compact)
	}
	return out.err
}

@(private = "file")
emit_markdown_row :: proc(out: ^Out, buf: []u8, cells: []Cell_Span, widths: []int, right: []bool, compact: bool) {
	for cell, c in cells {
		put_str(out, "| ")
		s := string(buf[cell.lo:][:cell.n])
		if compact {
			put_str(out, s)
		} else {
			put_padded_cell(out, s, "", max(widths[c] - cell.width, 0), right[c], true)
		}
		put_byte(out, ' ')
	}
	put_str(out, "|\n")
}
