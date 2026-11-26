package write

import "base:runtime"
import "core:io"
import "core:math"
import "core:strconv"
import "core:unicode/utf8"
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

// How a single root object is projected into rows and columns.
Object_Layout :: enum u8 {
	// Two-column table (`key`, `value`), one row per object member.
	Key_Value,
	// Single-row table with each distinct member key as a column header.
	Row,
}

// Column alignment policy.
Column_Align :: enum u8 {
	// Right-align columns whose non-empty/non-null data cells are all numbers; left-align everything else.
	Auto,
	// Left-align all columns.
	Left,
	// Right-align all columns.
	Right,
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

// Streaming token writer that collects tokens (single value or framed record sequence) and renders a plain-text table
// on `table_render_writer_end`. Not copied once started.
Table_Render_Writer :: struct {
	tokens:    Token_Tape,
	opts:      Table_Render_Options,
	sink:      io.Writer,
	allocator: runtime.Allocator,
}

// Writes `doc` as an aligned plain-text table into an already-started `Out`.
@(require_results)
write_table_out :: proc(out: ^Out, doc: ^tape.Document, opts := Table_Render_Options{}, allocator := context.allocator) -> Error {
	if opts.max_col_width < 0 {
		return tape.Bad_Option{"max_col_width"}
	}
	if allocator.procedure == nil {
		return .Out_Of_Memory
	}
	grid: Render_Grid
	defer grid_destroy(&grid)
	grid_build_doc(&grid, doc, render_extract_opts(opts.node, opts.object_layout, opts.sort_keys, opts.null_text, opts.value_header, .Table), allocator) or_return
	return emit_plain_table(out, &grid, opts, allocator)
}

// Writes `doc` as an aligned plain-text table into a newly allocated buffer owned by the caller.
@(require_results)
write_table :: proc(doc: ^tape.Document, opts := Table_Render_Options{}, allocator := context.allocator) -> (text: []u8, err: Error) {
	if opts.max_col_width < 0 {
		return nil, tape.Bad_Option{"max_col_width"}
	}
	if allocator.procedure == nil {
		return nil, .Out_Of_Memory
	}
	out: Out
	if e := out_start(&out, allocator, {}, max(len(doc.src), ROOM_MAX)); e != nil {
		return nil, e
	}
	if err = write_table_out(&out, doc, opts, allocator); err != nil {
		out_drop(&out)
		return nil, err
	}
	return out_finish(&out)
}

// Streams `doc` as an aligned plain-text table into `sink`.
@(require_results)
write_table_to :: proc(sink: io.Writer, doc: ^tape.Document, opts := Table_Render_Options{}, allocator := context.allocator) -> Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	if opts.max_col_width < 0 {
		return tape.Bad_Option{"max_col_width"}
	}
	if allocator.procedure == nil {
		return .Out_Of_Memory
	}
	out: Out
	if e := out_start(&out, allocator, sink, 0); e != nil {
		return e
	}
	if err := write_table_out(&out, doc, opts, allocator); err != nil {
		out_drop(&out)
		return err
	}
	_, err := out_finish(&out)
	return err
}

// Writes a batch of record documents as one unified aligned plain-text table into `out`.
@(require_results)
write_table_docs_out :: proc(out: ^Out, docs: []tape.Document, opts := Table_Render_Options{}, allocator := context.allocator) -> Error {
	if opts.max_col_width < 0 {
		return tape.Bad_Option{"max_col_width"}
	}
	if allocator.procedure == nil {
		return .Out_Of_Memory
	}
	grid: Render_Grid
	defer grid_destroy(&grid)
	grid_build_docs(&grid, docs, render_extract_opts(opts.node, opts.object_layout, opts.sort_keys, opts.null_text, opts.value_header, .Table), allocator) or_return
	return emit_plain_table(out, &grid, opts, allocator)
}

// Writes a batch of record documents as one unified aligned plain-text table into a buffer owned by the caller.
@(require_results)
write_table_docs :: proc(docs: []tape.Document, opts := Table_Render_Options{}, allocator := context.allocator) -> (text: []u8, err: Error) {
	if opts.max_col_width < 0 {
		return nil, tape.Bad_Option{"max_col_width"}
	}
	if allocator.procedure == nil {
		return nil, .Out_Of_Memory
	}
	out: Out
	if e := out_start(&out, allocator, {}, ROOM_MAX); e != nil {
		return nil, e
	}
	if err = write_table_docs_out(&out, docs, opts, allocator); err != nil {
		out_drop(&out)
		return nil, err
	}
	return out_finish(&out)
}

// Streams a batch of record documents as one unified aligned plain-text table into `sink`.
@(require_results)
write_table_docs_to :: proc(sink: io.Writer, docs: []tape.Document, opts := Table_Render_Options{}, allocator := context.allocator) -> Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	if opts.max_col_width < 0 {
		return tape.Bad_Option{"max_col_width"}
	}
	if allocator.procedure == nil {
		return .Out_Of_Memory
	}
	out: Out
	if e := out_start(&out, allocator, sink, 0); e != nil {
		return e
	}
	if err := write_table_docs_out(&out, docs, opts, allocator); err != nil {
		out_drop(&out)
		return err
	}
	_, err := out_finish(&out)
	return err
}

// Starts a streaming plain-text table token writer. Set `framed = true` to push multiple root records (e.g. NDJSON rows).
@(require_results)
table_render_writer_start :: proc(w: ^Table_Render_Writer, opts := Table_Render_Options{}, sink := io.Writer{}, framed := false, allocator := context.allocator) -> Error {
	if opts.node != tape.ROOT {
		return tape.Bad_Option{"node"}
	}
	if opts.max_col_width < 0 {
		return tape.Bad_Option{"max_col_width"}
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
table_render_writer_token :: proc(w: ^Table_Render_Writer, kind: Token_Kind, text := "") -> Error {
	return token_tape_take(&w.tokens, kind, text)
}

// Finishes `w`, rendering its collected value(s) into a buffer (when `sink` was nil) or flushing to `sink`.
@(require_results)
table_render_writer_end :: proc(w: ^Table_Render_Writer) -> (text: []u8, err: Error) {
	defer table_render_writer_drop(w)
	if !token_tape_done(&w.tokens) {
		return nil, Refused{tape.Node_Index(w.tokens.seq.taken), .Malformed}
	}
	doc := token_tape_document(&w.tokens) or_return
	if w.sink.procedure != nil {
		return nil, write_table_to(w.sink, &doc, w.opts, w.allocator)
	}
	return write_table(&doc, w.opts, w.allocator)
}

// Frees all buffers held by `w` without writing output.
table_render_writer_drop :: proc(w: ^Table_Render_Writer) {
	token_tape_drop(&w.tokens)
	w^ = {}
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

@(private)
emit_plain_row :: proc(out: ^Out, buf: []u8, cells: []Cell_Span, widths: []int, right: []bool, opts: Table_Render_Options, gap: int, is_header: bool) {
	cols := len(cells)
	// Find the last cell that carries visible output so left-aligned trailing columns avoid trailing spaces.
	last_visible := -1
	for c := cols - 1; c >= 0; c -= 1 {
		if cells[c].n > 0 {
			last_visible = c
			break
		}
	}
	for c in 0 ..< cols {
		if c > last_visible && last_visible >= 0 {
			break
		}
		if last_visible < 0 {
			break
		}
		if c > 0 {
			put_spaces(out, gap)
		}
		cell := cells[c]
		s := string(buf[cell.lo:][:cell.n])
		align_right := cell_align_right(cell, right[c], opts.align, is_header)
		pad_trailing := c < last_visible
		put_aligned_cell(out, s, cell.width, widths[c], align_right, pad_trailing, opts.max_col_width, opts.style == .Ascii)
	}
	put_byte(out, '\n')
}

@(private)
emit_bordered_row :: proc(out: ^Out, buf: []u8, cells: []Cell_Span, widths: []int, right: []bool, opts: Table_Render_Options, bar: string, is_header: bool) {
	bar_bytes := transmute([]u8)bar
	for c in 0 ..< len(cells) {
		put(out, bar_bytes)
		put_byte(out, ' ')
		cell := cells[c]
		s := string(buf[cell.lo:][:cell.n])
		align_right := cell_align_right(cell, right[c], opts.align, is_header)
		put_aligned_cell(out, s, cell.width, widths[c], align_right, true, opts.max_col_width, opts.style == .Ascii)
		put_byte(out, ' ')
	}
	put(out, bar_bytes)
	put_byte(out, '\n')
}

@(private)
emit_box_rule :: proc(out: ^Out, widths: []int, left, mid, right_edge, fill: string) {
	put(out, transmute([]u8)left)
	fill_bytes := transmute([]u8)fill
	mid_bytes := transmute([]u8)mid
	for w, c in widths {
		if c > 0 {
			put(out, mid_bytes)
		}
		for _ in 0 ..< w + 2 {
			put(out, fill_bytes)
		}
	}
	put(out, transmute([]u8)right_edge)
	put_byte(out, '\n')
}

@(private)
cell_align_right :: #force_inline proc "contextless" (cell: Cell_Span, col_is_right: bool, align: Column_Align, is_header: bool) -> bool {
	switch align {
	case .Left:
		return false
	case .Right:
		return true
	case .Auto:
		if !col_is_right {
			return false
		}
		return is_header || cell.numeric
	}
	return false
}

@(private)
put_aligned_cell :: proc(out: ^Out, s: string, width, col_width: int, align_right, pad_trailing: bool, max_width: int, ascii_ellipsis: bool) {
	if max_width > 0 && width > max_width {
		prefix, used, suffix := truncate_display(s, max_width, ascii_ellipsis)
		pad := max(col_width - used, 0)
		if align_right {
			put_spaces(out, pad)
			put(out, transmute([]u8)prefix)
			put(out, transmute([]u8)suffix)
		} else {
			put(out, transmute([]u8)prefix)
			put(out, transmute([]u8)suffix)
			if pad_trailing {
				put_spaces(out, pad)
			}
		}
		return
	}
	pad := max(col_width - width, 0)
	if align_right {
		put_spaces(out, pad)
		put(out, transmute([]u8)s)
	} else {
		put(out, transmute([]u8)s)
		if pad_trailing {
			put_spaces(out, pad)
		}
	}
}

@(private)
put_spaces :: proc(out: ^Out, n: int) {
	put_repeat_byte(out, ' ', n)
}

@(private)
put_repeat_byte :: proc(out: ^Out, ch: u8, n: int) {
	if n <= 0 {
		return
	}
	left := n
	for left > 0 {
		k := min(left, ROOM_MAX)
		p := room(out, k)
		for i in 0 ..< k {
			p[i] = ch
		}
		out.cursor += k
		left -= k
	}
}

// ---------------------------------------------------------------------------
// Shared tabular extraction (`Render_Grid`), shared with `markdown_render.odin`
// ---------------------------------------------------------------------------

@(private)
Escape_Mode :: enum u8 {
	Table,
	Markdown,
}

@(private)
Render_Extract_Options :: struct {
	node:          tape.Node_Index,
	object_layout: Object_Layout,
	sort_keys:     bool,
	null_text:     string,
	value_header:  string,
	escape_mode:   Escape_Mode,
}

@(private)
render_extract_opts :: #force_inline proc "contextless" (
	node: tape.Node_Index,
	object_layout: Object_Layout,
	sort_keys: bool,
	null_text: Maybe(string),
	value_header: string,
	escape_mode: Escape_Mode,
) -> Render_Extract_Options {
	nt := "null"
	if v, ok := null_text.?; ok {
		nt = v
	}
	vh := value_header if len(value_header) > 0 else "value"
	return {
		node          = node,
		object_layout = object_layout,
		sort_keys     = sort_keys,
		null_text     = nt,
		value_header  = vh,
		escape_mode   = escape_mode,
	}
}

@(private)
Cell_Span :: struct {
	lo:      int,
	n:       int,
	width:   int,
	numeric: bool,
	absent:  bool,
	is_null: bool,
}

@(private)
Key_Span :: struct {
	lo: int,
	n:  int,
}

@(private)
Render_Grid :: struct {
	text_buf:  [dynamic]u8,
	headers:   [dynamic]Cell_Span,
	cells:     [dynamic]Cell_Span,
	rows:      int,
	allocator: runtime.Allocator,
}

@(private)
grid_destroy :: proc(g: ^Render_Grid) {
	delete(g.text_buf)
	delete(g.headers)
	delete(g.cells)
	g^ = {}
}

@(private)
compute_column_metrics :: proc(
	grid: ^Render_Grid,
	align: Column_Align,
	no_header: bool,
	min_left: int,
	min_right: int,
	max_col_width: int,
	widths: []int,
	right: []bool,
) {
	cols := len(grid.headers)
	for c in 0 ..< cols {
		num_count := 0
		other_count := 0
		max_w := 0 if no_header else grid.headers[c].width
		for r in 0 ..< grid.rows {
			cell := grid.cells[r * cols + c]
			if cell.width > max_w {
				max_w = cell.width
			}
			if cell.numeric {
				num_count += 1
			} else if !cell.absent && !cell.is_null {
				other_count += 1
			}
		}
		is_right := false
		switch align {
		case .Left:
			is_right = false
		case .Right:
			is_right = true
		case .Auto:
			is_right = num_count > 0 && other_count == 0
		}
		right[c] = is_right
		min_w := min_right if is_right else min_left
		if max_w < min_w {
			max_w = min_w
		}
		if max_col_width > 0 && max_w > max_col_width {
			max_w = max_col_width
		}
		widths[c] = max_w
	}
}

@(private)
Grid_Builder :: struct {
	grid:    ^Render_Grid,
	opts:    Render_Extract_Options,
	scratch: [dynamic]u8,
	key_buf: [dynamic]u8,
	keys:    [dynamic]Key_Span,
	alloc:   runtime.Allocator,
}

@(private)
grid_builder_init :: proc(b: ^Grid_Builder, grid: ^Render_Grid, opts: Render_Extract_Options, allocator: runtime.Allocator) {
	grid^ = {allocator = allocator}
	grid.text_buf.allocator = allocator
	grid.headers.allocator = allocator
	grid.cells.allocator = allocator
	b^ = {grid = grid, opts = opts, alloc = allocator}
	b.scratch.allocator = allocator
	b.key_buf.allocator = allocator
	b.keys.allocator = allocator
}

@(private)
grid_builder_drop :: proc(b: ^Grid_Builder) {
	delete(b.scratch)
	delete(b.key_buf)
	delete(b.keys)
}

// Allocates a slice of `n` elements of `T`, returning `.Out_Of_Memory` for a nil allocator or an allocator (such as
// `mem.nil_allocator()`) that returns nil/short memory without an error.
@(private)
make_slice :: proc($T: typeid, n: int, allocator: runtime.Allocator) -> ([]T, runtime.Allocator_Error) {
	if allocator.procedure == nil {
		return nil, .Out_Of_Memory
	}
	if n <= 0 {
		return nil, nil
	}
	s, err := make([]T, n, allocator)
	if err == nil && (raw_data(s) == nil || len(s) < n) {
		return nil, .Out_Of_Memory
	}
	return s, err
}

// Guards `node` using unsigned 64-bit bounds so `tape.NO_NODE` (`max(u32)`) never wraps to `-1` on 32-bit `wasm32`.
@(private)
validate_root_node :: proc(doc: ^tape.Document, node: tape.Node_Index) -> Error {
	if .Cut in doc.flags && (len(doc.nodes) == 0 || u64(node) < u64(len(doc.nodes)) && doc.nodes[node].kind > .Plain && tape.node_after(doc, node) == tape.node_after(doc, tape.ROOT)) {
		return Refused{node, .Partial}
	}
	if u64(node) >= u64(len(doc.nodes)) || doc.nodes[node].role != .Value {
		return tape.Bad_Option{"node"}
	}
	return nil
}

@(private)
grid_build_doc :: proc(grid: ^Render_Grid, doc: ^tape.Document, opts: Render_Extract_Options, allocator: runtime.Allocator) -> Error {
	b: Grid_Builder
	grid_builder_init(&b, grid, opts, allocator)
	defer grid_builder_drop(&b)

	validate_root_node(doc, opts.node) or_return
	w: Tree
	tree_start(&w, doc, {node = opts.node}, {}, allocator) or_return
	defer tree_end(&w)
	index := tape.Doc_Index{allocator = allocator}
	defer tape.destroy(&index)
	w.reader.index = &index

	root := opts.node
	node := doc.nodes[root]
	if node.kind >= .Array && node.spelling & tape.CONTAINER_PARTIAL != 0 {
		return Refused{root, .Partial}
	}

	switch node.kind {
	case .Array:
		if keys, is_table := tape.table_keys(doc, root); is_table && len(keys) > 0 {
			return build_delimited_table(&b, &w, root, keys)
		}
		return build_array(&b, &w, root)
	case .Object:
		return build_single_object(&b, &w, root)
	case .Null, .False, .True, .Number, .Bytes, .String, .Plain, .End:
		return build_single_scalar(&b, &w, root)
	}
	return nil
}

@(private)
grid_build_docs :: proc(grid: ^Render_Grid, docs: []tape.Document, opts: Render_Extract_Options, allocator: runtime.Allocator) -> Error {
	b: Grid_Builder
	grid_builder_init(&b, grid, opts, allocator)
	defer grid_builder_drop(&b)
	if len(docs) == 0 {
		return nil
	}

	all_objects := true
	all_arrays := true
	max_arr_len := 0
	for &d in docs {
		validate_root_node(&d, opts.node) or_return
		w: Tree
		tree_start(&w, &d, {node = opts.node}, {}, allocator) or_return
		tree_end(&w)
		n := d.nodes[opts.node]
		if n.kind >= .Array && n.spelling & tape.CONTAINER_PARTIAL != 0 {
			return Refused{opts.node, .Partial}
		}
		if n.kind != .Object {
			all_objects = false
		}
		if n.kind != .Array {
			all_arrays = false
		} else {
			cnt := tape.child_count(&d, opts.node, n)
			if cnt > max_arr_len {
				max_arr_len = cnt
			}
		}
	}

	if all_objects {
		for &d in docs {
			w: Tree
			tree_start(&w, &d, {node = opts.node}, {}, allocator) or_return
			err := collect_object_keys(&b, &w, opts.node)
			tree_end(&w)
			if err != nil {
				return err
			}
		}
		if len(b.keys) == 0 {
			return nil
		}
		if opts.sort_keys {
			sort_builder_keys(&b)
		}
		finalize_headers_from_keys(&b) or_return
		for &d in docs {
			w: Tree
			tree_start(&w, &d, {node = opts.node}, {}, allocator) or_return
			index := tape.Doc_Index{allocator = allocator}
			w.reader.index = &index
			err := append_object_row(&b, &w, opts.node)
			tape.destroy(&index)
			tree_end(&w)
			if err != nil {
				return err
			}
		}
		return nil
	}

	if all_arrays {
		if max_arr_len == 0 {
			return nil
		}
		add_index_headers(&b, max_arr_len) or_return
		for &d in docs {
			w: Tree
			tree_start(&w, &d, {node = opts.node}, {}, allocator) or_return
			err := append_array_row(&b, &w, opts.node, max_arr_len)
			tree_end(&w)
			if err != nil {
				return err
			}
		}
		return nil
	}

	add_escaped_header(&b, opts.value_header) or_return
	for &d in docs {
		w: Tree
		tree_start(&w, &d, {node = opts.node}, {}, allocator) or_return
		err := append_value_cell(&b, &w, opts.node)
		tree_end(&w)
		if err != nil {
			return err
		}
		grid.rows += 1
	}
	return nil
}

@(private)
build_delimited_table :: proc(b: ^Grid_Builder, w: ^Tree, root: tape.Node_Index, keys: []tape.Node) -> Error {
	doc := w.doc
	kept_cols := make([dynamic]int, b.alloc)
	defer delete(kept_cols)

	for j in 0 ..< len(keys) {
		if tape.column_dropped(doc, keys, j, len(keys)) {
			continue
		}
		if _, err := append(&kept_cols, j); err != nil {
			return err
		}
	}
	if len(kept_cols) == 0 {
		return nil
	}

	// Build raw key list for optional sorting and header display.
	Col_Order :: struct {
		span: Key_Span,
		col:  int,
	}
	ordered, oerr := make_slice(Col_Order, len(kept_cols), b.alloc)
	if oerr != nil {
		return oerr
	}
	defer delete(ordered, b.alloc)

	for col, idx in kept_cols {
		s, ok := text_of_token(w, keys[col])
		if !ok {
			return w.err
		}
		lo := len(b.key_buf)
		if _, err := append(&b.key_buf, s); err != nil {
			return err
		}
		ordered[idx] = {span = {lo = lo, n = len(s)}, col = col}
	}

	if b.opts.sort_keys {
		sort_by_span(ordered, b.key_buf[:])
	}

	for item in ordered {
		s := string(b.key_buf[item.span.lo:][:item.span.n])
		add_escaped_header(b, s) or_return
	}

	end := tape.node_after(doc, root)
	for at := root + 1; at < end; at = tape.node_after(doc, at) {
		row := doc.nodes[at]
		if row.kind >= .Array && row.spelling & tape.CONTAINER_PARTIAL != 0 {
			return Refused{at, .Partial}
		}
		cell_count := int(row.n) - 1
		for item in ordered {
			if item.col < cell_count {
				append_value_cell(b, w, at + 1 + tape.Node_Index(item.col)) or_return
			} else {
				append_absent_cell(b) or_return
			}
		}
		b.grid.rows += 1
	}
	return nil
}

@(private)
build_array :: proc(b: ^Grid_Builder, w: ^Tree, root: tape.Node_Index) -> Error {
	doc := w.doc
	end := tape.node_after(doc, root)
	if root + 1 >= end {
		return nil
	}

	all_objects := true
	all_arrays := true
	max_arr_len := 0
	for at := root + 1; at < end; at = tape.node_after(doc, at) {
		n := doc.nodes[at]
		if n.kind >= .Array && n.spelling & tape.CONTAINER_PARTIAL != 0 {
			return Refused{at, .Partial}
		}
		if n.kind != .Object {
			all_objects = false
		}
		if n.kind != .Array {
			all_arrays = false
		} else {
			cnt := tape.child_count(doc, at, n)
			if cnt > max_arr_len {
				max_arr_len = cnt
			}
		}
	}

	if all_objects {
		for at := root + 1; at < end; at = tape.node_after(doc, at) {
			collect_object_keys(b, w, at) or_return
		}
		if len(b.keys) == 0 {
			return nil
		}
		if b.opts.sort_keys {
			sort_builder_keys(b)
		}
		finalize_headers_from_keys(b) or_return
		for at := root + 1; at < end; at = tape.node_after(doc, at) {
			append_object_row(b, w, at) or_return
		}
		return nil
	}

	if all_arrays {
		if max_arr_len == 0 {
			return nil
		}
		add_index_headers(b, max_arr_len) or_return
		for at := root + 1; at < end; at = tape.node_after(doc, at) {
			append_array_row(b, w, at, max_arr_len) or_return
		}
		return nil
	}

	add_escaped_header(b, b.opts.value_header) or_return
	for at := root + 1; at < end; at = tape.node_after(doc, at) {
		append_value_cell(b, w, at) or_return
		b.grid.rows += 1
	}
	return nil
}

@(private)
build_single_object :: proc(b: ^Grid_Builder, w: ^Tree, root: tape.Node_Index) -> Error {
	doc := w.doc
	end := tape.node_after(doc, root)
	if root + 1 >= end {
		return nil
	}

	if b.opts.object_layout == .Row {
		collect_object_keys(b, w, root) or_return
		if len(b.keys) == 0 {
			return nil
		}
		if b.opts.sort_keys {
			sort_builder_keys(b)
		}
		finalize_headers_from_keys(b) or_return
		return append_object_row(b, w, root)
	}

	// `.Key_Value`: 2-column table ("key", "value"), one row per member.
	// Use `tape.children` so DSV row `.Object` nodes (whose keys live in `Tabular_Ext.keys`) work identically to
	// regular objects, while keeping `.Group` for regular objects so XML repeated tags render every member.
	Member_Entry :: struct {
		span:     Key_Span,
		val_node: tape.Node_Index,
	}
	members := make([dynamic]Member_Entry, b.alloc)
	defer delete(members)

	c, cp, cerr := tape.children(w.reader, root, b.alloc)
	if cerr != nil {
		return cerr
	}
	defer tape.destroy_children(&c)
	if cp == .Not_Loaded {
		return Refused{root, .Partial}
	}
	if cp == .Found {
		dups := tape.Duplicates.Default if c.keys_n != 0 else tape.Duplicates.Group
		for {
			key_node, val_node, next_p := tape.next_child(w.reader, &c, dups)
			if next_p != .Found {
				break
			}
			clear(&b.scratch)
			if key_node == tape.NO_NODE {
				ks, ok := text_of_token(w, tape.cell_key(w.reader, c))
				if !ok {
					return w.err
				}
				if _, err := append(&b.scratch, ks); err != nil {
					return err
				}
			} else {
				format_key_raw(b, w, key_node) or_return
			}
			lo := len(b.key_buf)
			if _, err := append(&b.key_buf, ..b.scratch[:]); err != nil {
				return err
			}
			if _, err := append(&members, Member_Entry{span = {lo = lo, n = len(b.scratch)}, val_node = val_node}); err != nil {
				return err
			}
		}
	}
	if len(members) == 0 {
		return nil
	}

	if b.opts.sort_keys {
		sort_by_span(members[:], b.key_buf[:])
	}

	add_escaped_header(b, "key") or_return
	add_escaped_header(b, "value") or_return
	for m in members {
		key_text := string(b.key_buf[m.span.lo:][:m.span.n])
		append_escaped_cell(b, transmute([]u8)key_text, false, false, false) or_return
		append_value_cell(b, w, m.val_node) or_return
		b.grid.rows += 1
	}
	return nil
}

@(private)
build_single_scalar :: proc(b: ^Grid_Builder, w: ^Tree, root: tape.Node_Index) -> Error {
	add_escaped_header(b, b.opts.value_header) or_return
	append_value_cell(b, w, root) or_return
	b.grid.rows = 1
	return nil
}

@(private)
record_distinct_key :: proc(b: ^Grid_Builder, raw: []u8, hint: int) -> runtime.Allocator_Error {
	raw_s := string(raw)
	if hint < len(b.keys) && string(b.key_buf[b.keys[hint].lo:][:b.keys[hint].n]) == raw_s {
		return nil
	}
	for existing in b.keys {
		if string(b.key_buf[existing.lo:][:existing.n]) == raw_s {
			return nil
		}
	}
	lo := len(b.key_buf)
	append(&b.key_buf, ..raw) or_return
	append(&b.keys, Key_Span{lo = lo, n = len(raw)}) or_return
	return nil
}

@(private)
collect_object_keys :: proc(b: ^Grid_Builder, w: ^Tree, obj_at: tape.Node_Index) -> Error {
	doc := w.doc
	end := tape.node_after(doc, obj_at)
	if obj_at + 1 >= end {
		return nil
	}
	// A DSV table row `.Object` stores value cells with no key nodes; read its keys via `tape.children` / `cell_key`.
	if tree_tables(w) && doc.nodes[obj_at + 1].role != .Key {
		c, cp, cerr := tape.children(w.reader, obj_at, b.alloc)
		if cerr != nil {
			return cerr
		}
		defer tape.destroy_children(&c)
		if cp == .Not_Loaded {
			return Refused{obj_at, .Partial}
		}
		if cp == .Found && c.keys_n != 0 {
			j := 0
			for {
				_, _, next_p := tape.next_child(w.reader, &c, .Default)
				if next_p != .Found {
					break
				}
				ks, ok := text_of_token(w, tape.cell_key(w.reader, c))
				if !ok {
					return w.err
				}
				if err := record_distinct_key(b, transmute([]u8)ks, j); err != nil {
					return err
				}
				j += 1
			}
			return nil
		}
	}
	j := 0
	for k := obj_at + 1; k < end; j += 1 {
		val := tape.node_after(doc, k)
		clear(&b.scratch)
		format_key_raw(b, w, k) or_return
		if err := record_distinct_key(b, b.scratch[:], j); err != nil {
			return err
		}
		k = tape.node_after(doc, val)
	}
	return nil
}

@(private)
finalize_headers_from_keys :: proc(b: ^Grid_Builder) -> Error {
	for ks in b.keys {
		add_escaped_header(b, string(b.key_buf[ks.lo:][:ks.n])) or_return
	}
	return nil
}

@(private)
append_object_row :: proc(b: ^Grid_Builder, w: ^Tree, obj_at: tape.Node_Index) -> Error {
	for ks in b.keys {
		name := string(b.key_buf[ks.lo:][:ks.n])
		val, p := tape.member(w.reader, obj_at, name)
		switch p {
		case .Found:
			append_value_cell(b, w, val) or_return
		case .Missing:
			// Fallback for container keys (which `tape.member` does not index by JSON text).
			fallback, found := find_container_key_member(b, w, obj_at, name) or_return
			if found {
				append_value_cell(b, w, fallback) or_return
			} else {
				append_absent_cell(b) or_return
			}
		case .Not_Loaded:
			return Refused{obj_at, .Partial}
		case .Wrong_Kind:
			append_absent_cell(b) or_return
		}
	}
	b.grid.rows += 1
	return nil
}

@(private)
find_container_key_member :: proc(b: ^Grid_Builder, w: ^Tree, obj_at: tape.Node_Index, name: string) -> (val_out: tape.Node_Index, found: bool, err: Error) {
	doc := w.doc
	end := tape.node_after(doc, obj_at)
	if obj_at + 1 >= end || doc.nodes[obj_at + 1].role != .Key {
		return tape.NO_NODE, false, nil
	}
	take_first := doc.format != nil && doc.format.dups == .First
	val_out = tape.NO_NODE
	for k := obj_at + 1; k < end; {
		val := tape.node_after(doc, k)
		if doc.nodes[k].kind >= .Array {
			clear(&b.scratch)
			format_key_raw(b, w, k) or_return
			if string(b.scratch[:]) == name {
				val_out = val
				found = true
				if take_first {
					return val_out, true, nil
				}
			}
		}
		k = tape.node_after(doc, val)
	}
	return val_out, found, nil
}

@(private)
append_array_row :: proc(b: ^Grid_Builder, w: ^Tree, arr_at: tape.Node_Index, width: int) -> Error {
	doc := w.doc
	end := tape.node_after(doc, arr_at)
	col := 0
	for at := arr_at + 1; at < end && col < width; at = tape.node_after(doc, at) {
		append_value_cell(b, w, at) or_return
		col += 1
	}
	for ; col < width; col += 1 {
		append_absent_cell(b) or_return
	}
	b.grid.rows += 1
	return nil
}

@(private)
add_index_headers :: proc(b: ^Grid_Builder, count: int) -> Error {
	buf: [24]u8
	for i in 0 ..< count {
		s := strconv.write_int(buf[:], i64(i), 10)
		add_escaped_header(b, s) or_return
	}
	return nil
}

@(private)
add_escaped_header :: proc(b: ^Grid_Builder, raw: string) -> Error {
	lo := len(b.grid.text_buf)
	width := append_escaped(&b.grid.text_buf, transmute([]u8)raw, b.opts.escape_mode) or_return
	n := len(b.grid.text_buf) - lo
	if _, err := append(&b.grid.headers, Cell_Span{lo = lo, n = n, width = width}); err != nil {
		return err
	}
	return nil
}

@(private)
append_absent_cell :: proc(b: ^Grid_Builder) -> Error {
	if _, err := append(&b.grid.cells, Cell_Span{lo = len(b.grid.text_buf), n = 0, width = 0, absent = true}); err != nil {
		return err
	}
	return nil
}

@(private)
append_escaped_cell :: proc(b: ^Grid_Builder, raw: []u8, numeric, is_null, absent: bool) -> Error {
	lo := len(b.grid.text_buf)
	width := append_escaped(&b.grid.text_buf, raw, b.opts.escape_mode) or_return
	n := len(b.grid.text_buf) - lo
	if _, err := append(&b.grid.cells, Cell_Span{lo = lo, n = n, width = width, numeric = numeric, is_null = is_null, absent = absent}); err != nil {
		return err
	}
	return nil
}

@(private)
append_value_cell :: proc(b: ^Grid_Builder, w: ^Tree, at: tape.Node_Index) -> Error {
	node := w.doc.nodes[at]
	clear(&b.scratch)
	switch node.kind {
	case .Null:
		return append_escaped_cell(b, transmute([]u8)b.opts.null_text, false, true, false)
	case .True:
		return append_escaped_cell(b, transmute([]u8)string("true"), false, false, false)
	case .False:
		return append_escaped_cell(b, transmute([]u8)string("false"), false, false, false)
	case .Number:
		format_number_into(&b.scratch, w, at) or_return
		return append_escaped_cell(b, b.scratch[:], true, false, false)
	case .String, .Plain:
		s, ok := text_of(w, at)
		if !ok {
			return w.err
		}
		return append_escaped_cell(b, transmute([]u8)s, false, false, false)
	case .Bytes:
		encoded, ok := bytes_base64(w, at)
		if !ok {
			return w.err
		}
		defer delete(encoded, w.allocator)
		return append_escaped_cell(b, transmute([]u8)encoded, false, false, false)
	case .Array, .Object:
		if node.spelling & tape.CONTAINER_PARTIAL != 0 {
			return Refused{at, .Partial}
		}
		append_compact_json(&b.scratch, w.doc, at, b.opts.sort_keys, b.alloc) or_return
		return append_escaped_cell(b, b.scratch[:], false, false, false)
	case .End:
		return append_absent_cell(b)
	}
	return nil
}

@(private)
format_key_raw :: proc(b: ^Grid_Builder, w: ^Tree, at: tape.Node_Index) -> Error {
	node := w.doc.nodes[at]
	switch node.kind {
	case .Null:
		if _, err := append(&b.scratch, "null"); err != nil {
			return err
		}
	case .True:
		if _, err := append(&b.scratch, "true"); err != nil {
			return err
		}
	case .False:
		if _, err := append(&b.scratch, "false"); err != nil {
			return err
		}
	case .Number:
		// Use the format's canonical key spelling via `text_of` first (so YAML `1e0`/`.inf`/`.nan` and CBOR int keys
		// match `tape.member` identically), falling back to `format_number_into` for unspelled binary floats.
		if s, ok := text_of(w, at); ok && len(s) > 0 {
			if _, err := append(&b.scratch, s); err != nil {
				return err
			}
			return nil
		}
		if w.err != nil {
			return w.err
		}
		return format_number_into(&b.scratch, w, at)
	case .String, .Plain:
		s, ok := text_of(w, at)
		if !ok {
			return w.err
		}
		if _, err := append(&b.scratch, s); err != nil {
			return err
		}
	case .Bytes:
		// Formats with `.Bytes` keys (CBOR, YAML `!!binary`) already return base64 from `text_of` when `role == .Key`.
		if node.role == .Key {
			if s, ok := text_of(w, at); ok {
				if _, err := append(&b.scratch, s); err != nil {
					return err
				}
				return nil
			}
			if w.err != nil {
				return w.err
			}
		}
		encoded, ok := bytes_base64(w, at)
		if !ok {
			return w.err
		}
		defer delete(encoded, w.allocator)
		if _, err := append(&b.scratch, encoded); err != nil {
			return err
		}
	case .Array, .Object:
		return append_compact_json(&b.scratch, w.doc, at, b.opts.sort_keys, b.alloc)
	case .End:
	}
	return nil
}

@(private)
format_number_into :: proc(dst: ^[dynamic]u8, w: ^Tree, at: tape.Node_Index) -> Error {
	buf: [NUMBER_ROOM]u8
	if s, ok := number_text(w, at, &buf); ok {
		if _, err := append(dst, s); err != nil {
			return err
		}
		return nil
	}
	if w.err != nil {
		return w.err
	}
	if n, ok := tape.node_number(w.doc, at); ok && n.kind == .Float {
		f := transmute(f64)n.bits
		switch {
		case math.is_nan(f):
			if _, err := append(dst, "NaN"); err != nil {
				return err
			}
			return nil
		case math.is_inf(f, 1):
			if _, err := append(dst, "Infinity"); err != nil {
				return err
			}
			return nil
		case math.is_inf(f, -1):
			if _, err := append(dst, "-Infinity"); err != nil {
				return err
			}
			return nil
		}
	}
	// Fallback for wide non-binary numbers or raw spans.
	node := w.doc.nodes[at]
	if .Binary not_in w.doc.format.caps {
		if _, err := append(dst, ..tape.span_bytes(w.doc, node.lo, node.n)); err != nil {
			return err
		}
		return nil
	}
	return Refused{at, .No_Spelling}
}

// ---------------------------------------------------------------------------
// Iterative compact JSON serializer for nested containers inside table cells
// ---------------------------------------------------------------------------

// Initializes a `Tree` walk starting at `root` whether `root` has `.Value` or `.Key` role (for container keys).
@(private)
tree_start_any :: proc(w: ^Tree, doc: ^tape.Document, root: tape.Node_Index, sort_keys: bool, allocator: runtime.Allocator) -> Error {
	if .Cut in doc.flags && (len(doc.nodes) == 0 || u64(root) < u64(len(doc.nodes)) && doc.nodes[root].kind > .Plain && tape.node_after(doc, root) == tape.node_after(doc, tape.ROOT)) {
		return Refused{root, .Partial}
	}
	if u64(root) >= u64(len(doc.nodes)) || (doc.nodes[root].role != .Value && doc.nodes[root].role != .Key) {
		return tape.Bad_Option{"node"}
	}
	w.doc, w.nodes, w.allocator = doc, raw_data(doc.nodes), allocator
	w.i, w.end, w.depth = root, tape.node_after(doc, root), 0
	w.frames, w.held = &w.room[0], FRAME_ROOM
	w.facts, w.fact, w.holds = doc.facts, 0, {}
	w.dropped = doc.present
	w.reader = {doc, nil}
	w.in_row, w.scratch, w.err = false, nil, nil
	w.sort_keys, w.pairs = sort_keys, make([dynamic]Pair, allocator)
	return nil
}

@(private)
append_compact_json :: proc(dst: ^[dynamic]u8, doc: ^tape.Document, root: tape.Node_Index, sort_keys: bool, allocator: runtime.Allocator) -> Error {
	w: Tree
	tree_start_any(&w, doc, root, sort_keys, allocator) or_return
	defer tree_end(&w)
	tables := tree_tables(&w)
	for w.err == nil {
		s := tree_next(&w, false, true) if tables else tree_next(&w, false, false)
		if s.kind == .Done {
			break
		}
		if s.kind == .Close {
			ch: u8 = '}' if doc.nodes[s.node].kind == .Object else ']'
			if _, err := append(dst, ch); err != nil {
				return err
			}
			continue
		}
		if !s.first {
			if _, err := append(dst, ','); err != nil {
				return err
			}
		}
		if s.key != tape.NO_NODE {
			append_json_key_node(dst, &w, s.key) or_return
			if _, err := append(dst, ':'); err != nil {
				return err
			}
		} else if s.cell {
			ks, ok := text_of_token(&w, w.cell)
			if !ok {
				return w.err
			}
			append_json_quoted(dst, ks) or_return
			if _, err := append(dst, ':'); err != nil {
				return err
			}
		}
		n := doc.nodes[s.node]
		switch n.kind {
		case .Object:
			if _, err := append(dst, '{'); err != nil {
				return err
			}
		case .Array:
			if _, err := append(dst, '['); err != nil {
				return err
			}
		case .Null:
			if _, err := append(dst, "null"); err != nil {
				return err
			}
		case .True:
			if _, err := append(dst, "true"); err != nil {
				return err
			}
		case .False:
			if _, err := append(dst, "false"); err != nil {
				return err
			}
		case .Number:
			format_number_into(dst, &w, s.node) or_return
		case .String, .Plain:
			str, ok := text_of(&w, s.node)
			if !ok {
				return w.err
			}
			append_json_quoted(dst, str) or_return
		case .Bytes:
			encoded, ok := bytes_base64(&w, s.node)
			if !ok {
				return w.err
			}
			err := append_json_quoted(dst, encoded)
			delete(encoded, w.allocator)
			if err != nil {
				return err
			}
		case .End:
		}
	}
	return w.err
}

@(private)
append_json_key_node :: proc(dst: ^[dynamic]u8, w: ^Tree, key_at: tape.Node_Index) -> Error {
	node := w.doc.nodes[key_at]
	switch node.kind {
	case .String, .Plain:
		s, ok := text_of(w, key_at)
		if !ok {
			return w.err
		}
		append_json_quoted(dst, s) or_return
	case .Null:
		append_json_quoted(dst, "null") or_return
	case .True:
		append_json_quoted(dst, "true") or_return
	case .False:
		append_json_quoted(dst, "false") or_return
	case .Number:
		if s, ok := text_of(w, key_at); ok && len(s) > 0 {
			append_json_quoted(dst, s) or_return
			return nil
		}
		if w.err != nil {
			return w.err
		}
		buf: [NUMBER_ROOM]u8
		if s, ok := number_text(w, key_at, &buf); ok {
			append_json_quoted(dst, s) or_return
			return nil
		}
		if w.err != nil {
			return w.err
		}
		if n, ok := tape.node_number(w.doc, key_at); ok && n.kind == .Float {
			f := transmute(f64)n.bits
			switch {
			case math.is_nan(f):
				append_json_quoted(dst, "NaN") or_return
				return nil
			case math.is_inf(f, 1):
				append_json_quoted(dst, "Infinity") or_return
				return nil
			case math.is_inf(f, -1):
				append_json_quoted(dst, "-Infinity") or_return
				return nil
			}
		}
		if .Binary not_in w.doc.format.caps {
			append_json_quoted(dst, string(tape.span_bytes(w.doc, node.lo, node.n))) or_return
			return nil
		}
		return Refused{key_at, .No_Spelling}
	case .Bytes:
		if node.role == .Key {
			if s, ok := text_of(w, key_at); ok {
				append_json_quoted(dst, s) or_return
				return nil
			}
			if w.err != nil {
				return w.err
			}
		}
		encoded, ok := bytes_base64(w, key_at)
		if !ok {
			return w.err
		}
		err := append_json_quoted(dst, encoded)
		delete(encoded, w.allocator)
		if err != nil {
			return err
		}
	case .Array:
		append_json_quoted(dst, "[...]") or_return
	case .Object:
		append_json_quoted(dst, "{...}") or_return
	case .End:
		append_json_quoted(dst, "") or_return
	}
	return nil
}

@(private)
append_json_quoted :: proc(dst: ^[dynamic]u8, s: string) -> runtime.Allocator_Error {
	hex := "0123456789abcdef"
	append(dst, '"') or_return
	run := 0
	b := transmute([]u8)s
	for c, i in b {
		if c >= 0x20 && c != '"' && c != '\\' {
			continue
		}
		if i > run {
			append(dst, ..b[run:i]) or_return
		}
		switch c {
		case '"':
			append(dst, `\"`) or_return
		case '\\':
			append(dst, `\\`) or_return
		case '\b':
			append(dst, `\b`) or_return
		case '\f':
			append(dst, `\f`) or_return
		case '\n':
			append(dst, `\n`) or_return
		case '\r':
			append(dst, `\r`) or_return
		case '\t':
			append(dst, `\t`) or_return
		case:
			esc := [6]u8{'\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xF]}
			append(dst, ..esc[:]) or_return
		}
		run = i + 1
	}
	if run < len(b) {
		append(dst, ..b[run:]) or_return
	}
	append(dst, '"') or_return
	return nil
}

// ---------------------------------------------------------------------------
// Stable zero-allocation sorting helpers
// ---------------------------------------------------------------------------

@(private)
sort_builder_keys :: proc(b: ^Grid_Builder) {
	keys := b.keys[:]
	buf := b.key_buf[:]
	for i in 1 ..< len(keys) {
		cur := keys[i]
		cur_s := string(buf[cur.lo:][:cur.n])
		lo, hi := 0, i
		for lo < hi {
			mid := (lo + hi) / 2
			if cur_s < string(buf[keys[mid].lo:][:keys[mid].n]) {
				hi = mid
			} else {
				lo = mid + 1
			}
		}
		for j := i; j > lo; j -= 1 {
			keys[j] = keys[j - 1]
		}
		keys[lo] = cur
	}
}

@(private)
sort_by_span :: proc(items: []$T, buf: []u8) {
	for i in 1 ..< len(items) {
		cur := items[i]
		cur_s := string(buf[cur.span.lo:][:cur.span.n])
		lo, hi := 0, i
		for lo < hi {
			mid := (lo + hi) / 2
			if cur_s < string(buf[items[mid].span.lo:][:items[mid].span.n]) {
				hi = mid
			} else {
				lo = mid + 1
			}
		}
		for j := i; j > lo; j -= 1 {
			items[j] = items[j - 1]
		}
		items[lo] = cur
	}
}

// ---------------------------------------------------------------------------
// Cell escaping + UTF-8 display width & truncation
// ---------------------------------------------------------------------------

// Appends `raw` escaped according to `mode` into `dst` and returns its terminal display width.
@(private)
append_escaped :: proc(dst: ^[dynamic]u8, raw: []u8, mode: Escape_Mode) -> (width: int, err: runtime.Allocator_Error) {
	if len(raw) == 0 {
		return 0, nil
	}
	// ASCII fast path: printable ASCII without mode-special bytes copies straight through.
	clean := true
	switch mode {
	case .Table:
		for c in raw {
			if c < 0x20 || c >= 0x7F {
				clean = false
				break
			}
		}
	case .Markdown:
		for c in raw {
			if c < 0x20 || c >= 0x7F || c == '|' || c == '\\' {
				clean = false
				break
			}
		}
	}
	if clean {
		append(dst, ..raw) or_return
		return len(raw), nil
	}

	hex := "0123456789abcdef"
	s := string(raw)
	i := 0
	for i < len(raw) {
		c := raw[i]
		if c < 0x80 {
			switch mode {
			case .Table:
				switch c {
				case '\n':
					append(dst, `\n`) or_return
					width += 2
				case '\r':
					append(dst, `\r`) or_return
					width += 2
				case '\t':
					append(dst, `\t`) or_return
					width += 2
				case 0x00 ..< 0x09, 0x0B ..< 0x0D, 0x0E ..< 0x20, 0x7F:
					esc := [4]u8{'\\', 'x', hex[c >> 4], hex[c & 0xF]}
					append(dst, ..esc[:]) or_return
					width += 4
				case:
					append(dst, c) or_return
					width += 1
				}
			case .Markdown:
				switch c {
				case '|':
					append(dst, `\|`) or_return
					width += 2
				case '\\':
					append(dst, `\\`) or_return
					width += 2
				case '\r':
					if i + 1 < len(raw) && raw[i + 1] == '\n' {
						i += 1
					}
					append(dst, "<br>") or_return
					width += 4
				case '\n':
					append(dst, "<br>") or_return
					width += 4
				case '\t':
					append(dst, ' ') or_return
					width += 1
				case 0x00 ..< 0x09, 0x0B ..< 0x0D, 0x0E ..< 0x20, 0x7F:
					esc := [4]u8{'\\', 'x', hex[c >> 4], hex[c & 0xF]}
					append(dst, ..esc[:]) or_return
					width += 4
				case:
					append(dst, c) or_return
					width += 1
				}
			}
			i += 1
			continue
		}
		r, sz := utf8.decode_rune_in_string(s[i:])
		if sz <= 0 {
			sz = 1
		}
		// Escape C1 control characters (U+0080..U+009F) so terminal sequences cannot leak through.
		if r >= 0x80 && r <= 0x9F {
			esc := [6]u8{'\\', 'u', '0', '0', hex[(r >> 4) & 0xF], hex[r & 0xF]}
			append(dst, ..esc[:]) or_return
			width += 6
			i += sz
			continue
		}
		append(dst, ..raw[i:i + sz]) or_return
		width += rune_display_width(r)
		i += sz
	}
	return width, nil
}

// Truncates UTF-8 string `s` so its rendered width plus ellipsis fits within `max_width`.
@(private)
truncate_display :: proc "contextless" (s: string, max_width: int, ascii_ellipsis: bool) -> (prefix: string, used: int, suffix: string) {
	if max_width <= 0 {
		return "", 0, ""
	}
	if ascii_ellipsis {
		if max_width >= 3 {
			suffix = "..."
		} else if max_width == 2 {
			suffix = ".."
		} else {
			suffix = "."
		}
	} else {
		suffix = "…"
	}
	suffix_w := len(suffix) if ascii_ellipsis else 1
	budget := max_width - suffix_w
	if budget <= 0 {
		return "", suffix_w, suffix
	}
	i := 0
	w := 0
	for i < len(s) {
		r, sz := utf8.decode_rune_in_string(s[i:])
		if sz <= 0 {
			sz = 1
		}
		rw := rune_display_width(r)
		if rw > 0 && w + rw > budget {
			break
		}
		w += rw
		i += sz
	}
	return s[:i], w + suffix_w, suffix
}

// Display width of UTF-8 string `s` in terminal columns (ASCII fast path + Unicode combining/wide ranges).
display_width :: proc "contextless" (s: string) -> int {
	b := transmute([]u8)s
	all_ascii := true
	for c in b {
		if c < 0x20 || c >= 0x7F {
			all_ascii = false
			break
		}
	}
	if all_ascii {
		return len(b)
	}
	total := 0
	for i := 0; i < len(s); {
		r, sz := utf8.decode_rune_in_string(s[i:])
		if sz <= 0 {
			sz = 1
		}
		total += rune_display_width(r)
		i += sz
	}
	return total
}

@(private)
Rune_Range :: struct {
	lo, hi: rune,
}

@(private, rodata)
ZERO_WIDTH_RANGES := [?]Rune_Range{
	{0x0300, 0x036F}, {0x0483, 0x0489}, {0x0591, 0x05BD}, {0x05BF, 0x05BF},
	{0x05C1, 0x05C2}, {0x05C4, 0x05C5}, {0x05C7, 0x05C7}, {0x0610, 0x061A},
	{0x064B, 0x065F}, {0x0670, 0x0670}, {0x06D6, 0x06DC}, {0x06DF, 0x06E4},
	{0x06E7, 0x06E8}, {0x06EA, 0x06ED}, {0x0711, 0x0711}, {0x0730, 0x074A},
	{0x0901, 0x0902}, {0x093C, 0x093C}, {0x0941, 0x0948}, {0x094D, 0x094D},
	{0x0951, 0x0957}, {0x0962, 0x0963}, {0x0E31, 0x0E31}, {0x0E34, 0x0E3A},
	{0x0E47, 0x0E4E}, {0x1160, 0x11FF}, {0x1AB0, 0x1AFF}, {0x1DC0, 0x1DFF},
	{0x200B, 0x200F}, {0x202A, 0x202E}, {0x2060, 0x206F}, {0x20D0, 0x20FF},
	{0xFE00, 0xFE0F}, {0xFE20, 0xFE2F}, {0xFEFF, 0xFEFF}, {0xE0100, 0xE01EF},
}

@(private, rodata)
WIDE_RANGES := [?]Rune_Range{
	{0x1100, 0x115F}, {0x231A, 0x231B}, {0x2329, 0x232A}, {0x23E9, 0x23EC},
	{0x23F0, 0x23F0}, {0x23F3, 0x23F3}, {0x25FD, 0x25FE}, {0x2614, 0x2615},
	{0x2648, 0x2653}, {0x267F, 0x267F}, {0x2693, 0x2693}, {0x26A1, 0x26A1},
	{0x26AA, 0x26AB}, {0x26BD, 0x26BE}, {0x26C4, 0x26C5}, {0x26CE, 0x26CE},
	{0x26D4, 0x26D4}, {0x26EA, 0x26EA}, {0x26F2, 0x26F3}, {0x26F5, 0x26F5},
	{0x26FA, 0x26FA}, {0x26FD, 0x26FD}, {0x2705, 0x2705}, {0x270A, 0x270B},
	{0x2728, 0x2728}, {0x274C, 0x274C}, {0x274E, 0x274E}, {0x2753, 0x2755},
	{0x2757, 0x2757}, {0x2795, 0x2797}, {0x27B0, 0x27B0}, {0x27BF, 0x27BF},
	{0x2B1B, 0x2B1C}, {0x2B50, 0x2B50}, {0x2B55, 0x2B55}, {0x2E80, 0x303E},
	{0x3041, 0x33FF}, {0x3400, 0x4DBF}, {0x4E00, 0xA4CF}, {0xA960, 0xA97C},
	{0xAC00, 0xD7A3}, {0xF900, 0xFAFF}, {0xFE10, 0xFE19}, {0xFE30, 0xFE6B},
	{0xFF01, 0xFF60}, {0xFFE0, 0xFFE6}, {0x1F004, 0x1F004}, {0x1F0CF, 0x1F0CF},
	{0x1F18E, 0x1F18E}, {0x1F191, 0x1F19A}, {0x1F200, 0x1F251}, {0x1F300, 0x1F64F},
	{0x1F680, 0x1F6FF}, {0x1F900, 0x1F9FF}, {0x1FA00, 0x1FAFF}, {0x20000, 0x2FFFD},
	{0x30000, 0x3FFFD},
}

@(private)
in_rune_ranges :: proc "contextless" (ranges: []Rune_Range, r: rune) -> bool #no_bounds_check {
	lo, hi := 0, len(ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		rng := ranges[mid]
		if r < rng.lo {
			hi = mid
		} else if r > rng.hi {
			lo = mid + 1
		} else {
			return true
		}
	}
	return false
}

// Terminal display width of Unicode code point `r` (0, 1, or 2).
@(private)
rune_display_width :: proc "contextless" (r: rune) -> int {
	if r < 0x20 || (r >= 0x7F && r < 0xA0) {
		return 0
	}
	if r < 0x0300 {
		return 1
	}
	if in_rune_ranges(ZERO_WIDTH_RANGES[:], r) {
		return 0
	}
	if in_rune_ranges(WIDE_RANGES[:], r) {
		return 2
	}
	return 1
}
