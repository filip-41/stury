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
	// Column alignment heuristic (`.Auto` emits `---:` for purely numeric columns, `---` otherwise).
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

// Streaming token writer that collects tokens (single value or framed record sequence) and renders a GFM table
// on `markdown_writer_end`. Not copied once started.
Markdown_Writer :: struct {
	tokens:    Token_Tape,
	opts:      Markdown_Options,
	sink:      io.Writer,
	allocator: runtime.Allocator,
}

// Writes `doc` as a GitHub-Flavored Markdown pipe table into an already-started `Out`.
@(require_results)
write_markdown_out :: proc(out: ^Out, doc: ^tape.Document, opts := Markdown_Options{}, allocator := context.allocator) -> Error {
	if allocator.procedure == nil {
		return .Out_Of_Memory
	}
	grid: Render_Grid
	defer grid_destroy(&grid)
	grid_build_doc(&grid, doc, render_extract_opts(opts.node, opts.object_layout, opts.sort_keys, opts.null_text, opts.value_header, .Markdown), allocator) or_return
	return emit_markdown_table(out, &grid, opts, allocator)
}

// Writes `doc` as a GitHub-Flavored Markdown pipe table into a newly allocated buffer owned by the caller.
@(require_results)
write_markdown :: proc(doc: ^tape.Document, opts := Markdown_Options{}, allocator := context.allocator) -> (text: []u8, err: Error) {
	if allocator.procedure == nil {
		return nil, .Out_Of_Memory
	}
	out: Out
	if e := out_start(&out, allocator, {}, max(len(doc.src), ROOM_MAX)); e != nil {
		return nil, e
	}
	if err = write_markdown_out(&out, doc, opts, allocator); err != nil {
		out_drop(&out)
		return nil, err
	}
	return out_finish(&out)
}

// Streams `doc` as a GitHub-Flavored Markdown pipe table into `sink`.
@(require_results)
write_markdown_to :: proc(sink: io.Writer, doc: ^tape.Document, opts := Markdown_Options{}, allocator := context.allocator) -> Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	if allocator.procedure == nil {
		return .Out_Of_Memory
	}
	out: Out
	if e := out_start(&out, allocator, sink, 0); e != nil {
		return e
	}
	if err := write_markdown_out(&out, doc, opts, allocator); err != nil {
		out_drop(&out)
		return err
	}
	_, err := out_finish(&out)
	return err
}

// Writes a batch of record documents as one unified GitHub-Flavored Markdown pipe table into `out`.
@(require_results)
write_markdown_docs_out :: proc(out: ^Out, docs: []tape.Document, opts := Markdown_Options{}, allocator := context.allocator) -> Error {
	if allocator.procedure == nil {
		return .Out_Of_Memory
	}
	grid: Render_Grid
	defer grid_destroy(&grid)
	grid_build_docs(&grid, docs, render_extract_opts(opts.node, opts.object_layout, opts.sort_keys, opts.null_text, opts.value_header, .Markdown), allocator) or_return
	return emit_markdown_table(out, &grid, opts, allocator)
}

// Writes a batch of record documents as one unified GitHub-Flavored Markdown pipe table into a buffer owned by the caller.
@(require_results)
write_markdown_docs :: proc(docs: []tape.Document, opts := Markdown_Options{}, allocator := context.allocator) -> (text: []u8, err: Error) {
	if allocator.procedure == nil {
		return nil, .Out_Of_Memory
	}
	out: Out
	if e := out_start(&out, allocator, {}, ROOM_MAX); e != nil {
		return nil, e
	}
	if err = write_markdown_docs_out(&out, docs, opts, allocator); err != nil {
		out_drop(&out)
		return nil, err
	}
	return out_finish(&out)
}

// Streams a batch of record documents as one unified GitHub-Flavored Markdown pipe table into `sink`.
@(require_results)
write_markdown_docs_to :: proc(sink: io.Writer, docs: []tape.Document, opts := Markdown_Options{}, allocator := context.allocator) -> Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	if allocator.procedure == nil {
		return .Out_Of_Memory
	}
	out: Out
	if e := out_start(&out, allocator, sink, 0); e != nil {
		return e
	}
	if err := write_markdown_docs_out(&out, docs, opts, allocator); err != nil {
		out_drop(&out)
		return err
	}
	_, err := out_finish(&out)
	return err
}

// Starts a streaming Markdown table token writer. Set `framed = true` to push multiple root records.
@(require_results)
markdown_writer_start :: proc(w: ^Markdown_Writer, opts := Markdown_Options{}, sink := io.Writer{}, framed := false, allocator := context.allocator) -> Error {
	if opts.node != tape.ROOT {
		return tape.Bad_Option{"node"}
	}
	if allocator.procedure == nil {
		return .Out_Of_Memory
	}
	w^ = {opts = opts, sink = sink, allocator = allocator}
	if err := token_tape_start(&w.tokens, framed, 0, allocator); err != nil {
		token_tape_drop(&w.tokens)
		w^ = {}
		return err
	}
	return nil
}

// Feeds one token into `w`.
@(require_results)
markdown_writer_token :: proc(w: ^Markdown_Writer, kind: Token_Kind, text := "") -> Error {
	return token_tape_take(&w.tokens, kind, text)
}

// Finishes `w`, rendering its collected value(s) into a buffer (when `sink` was nil) or flushing to `sink`.
@(require_results)
markdown_writer_end :: proc(w: ^Markdown_Writer) -> (text: []u8, err: Error) {
	defer markdown_writer_drop(w)
	if !token_tape_done(&w.tokens) {
		return nil, Refused{tape.Node_Index(w.tokens.seq.taken), .Malformed}
	}
	doc := token_tape_document(&w.tokens) or_return
	if w.sink.procedure != nil {
		return nil, write_markdown_to(w.sink, &doc, w.opts, w.allocator)
	}
	return write_markdown(&doc, w.opts, w.allocator)
}

// Frees all buffers held by `w` without writing output.
markdown_writer_drop :: proc(w: ^Markdown_Writer) {
	token_tape_drop(&w.tokens)
	w^ = {}
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

	// GFM divider cells use at least 3 dashes (`---`, or `---:` = 4 chars for right-aligned columns).
	compute_column_metrics(grid, opts.align, false, 3, 4, 0, widths, right)

	// Header row.
	emit_markdown_row(out, grid.text_buf[:], grid.headers[:], widths, right, opts.compact)

	// Separator row.
	for c in 0 ..< cols {
		put(out, transmute([]u8)string("| "))
		if opts.compact {
			if right[c] {
				put(out, transmute([]u8)string("---:"))
			} else {
				put(out, transmute([]u8)string("---"))
			}
		} else {
			if right[c] {
				put_repeat_byte(out, '-', max(widths[c] - 1, 3))
				put_byte(out, ':')
			} else {
				put_repeat_byte(out, '-', max(widths[c], 3))
			}
		}
		put_byte(out, ' ')
	}
	put(out, transmute([]u8)string("|\n"))

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

@(private)
emit_markdown_row :: proc(out: ^Out, buf: []u8, cells: []Cell_Span, widths: []int, right: []bool, compact: bool) {
	for cell, c in cells {
		put(out, transmute([]u8)string("| "))
		s := string(buf[cell.lo:][:cell.n])
		if compact {
			put(out, transmute([]u8)s)
		} else {
			pad := max(widths[c] - cell.width, 0)
			if right[c] {
				put_spaces(out, pad)
				put(out, transmute([]u8)s)
			} else {
				put(out, transmute([]u8)s)
				put_spaces(out, pad)
			}
		}
		put_byte(out, ' ')
	}
	put(out, transmute([]u8)string("|\n"))
}
