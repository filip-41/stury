package write

import "base:runtime"
import "core:io"
import "core:strconv"
import "stury:lib/core/tape"

// Shared tabular extraction (`Render_Grid`), shared render drivers (`Render_Target`), column-metric computation, and
// output padding helpers shared by `table_render.odin` and `markdown_render.odin`.

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

// ---------------------------------------------------------------------------
// Shared buffer/sink render drivers
// ---------------------------------------------------------------------------

@(private)
Render_Target :: union {
	Table_Render_Options,
	Markdown_Options,
}

@(private = "file", require_results)
render_extract_from_target :: proc "contextless" (target: Render_Target) -> (opts: Render_Extract_Options, err: Error) {
	switch o in target {
	case Table_Render_Options:
		if o.max_col_width < 0 {
			return {}, tape.Bad_Option{"max_col_width"}
		}
		return render_extract_opts(o.node, o.object_layout, o.sort_keys, o.null_text, o.value_header, .Table), nil
	case Markdown_Options:
		return render_extract_opts(o.node, o.object_layout, o.sort_keys, o.null_text, o.value_header, .Markdown), nil
	}
	return {}, nil
}

@(private = "file")
render_grid_empty :: proc "contextless" (grid: ^Render_Grid, target: Render_Target) -> bool {
	if len(grid.headers) == 0 {
		return true
	}
	if o, ok := target.(Table_Render_Options); ok && o.no_header && grid.rows == 0 {
		return true
	}
	return false
}

@(private = "file", require_results)
render_emit :: proc(out: ^Out, grid: ^Render_Grid, target: Render_Target, allocator: runtime.Allocator) -> Error {
	switch o in target {
	case Table_Render_Options:
		return emit_plain_table(out, grid, o, allocator)
	case Markdown_Options:
		return emit_markdown_table(out, grid, o, allocator)
	}
	return nil
}

@(private, require_results)
render_doc :: proc(doc: ^tape.Document, target: Render_Target, allocator: runtime.Allocator) -> (text: []u8, err: Error) {
	ext := render_extract_from_target(target) or_return
	if allocator.procedure == nil {
		return nil, .Out_Of_Memory
	}
	grid: Render_Grid
	defer grid_destroy(&grid)
	grid_build_doc(&grid, doc, ext, allocator) or_return
	if render_grid_empty(&grid, target) {
		return nil, nil
	}
	out: Out
	if e := out_start(&out, allocator, {}, max(len(doc.src), ROOM_MAX)); e != nil {
		return nil, e
	}
	if err = render_emit(&out, &grid, target, allocator); err != nil {
		out_drop(&out)
		return nil, err
	}
	return out_finish(&out)
}

@(private, require_results)
render_doc_to :: proc(sink: io.Writer, doc: ^tape.Document, target: Render_Target, allocator: runtime.Allocator) -> Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	ext := render_extract_from_target(target) or_return
	if allocator.procedure == nil {
		return .Out_Of_Memory
	}
	grid: Render_Grid
	defer grid_destroy(&grid)
	grid_build_doc(&grid, doc, ext, allocator) or_return
	if render_grid_empty(&grid, target) {
		return nil
	}
	out: Out
	if e := out_start(&out, allocator, sink, 0); e != nil {
		return e
	}
	if err := render_emit(&out, &grid, target, allocator); err != nil {
		out_drop(&out)
		return err
	}
	_, err := out_finish(&out)
	return err
}

@(private, require_results)
render_docs :: proc(docs: []tape.Document, target: Render_Target, allocator: runtime.Allocator) -> (text: []u8, err: Error) {
	ext := render_extract_from_target(target) or_return
	if allocator.procedure == nil {
		return nil, .Out_Of_Memory
	}
	grid: Render_Grid
	defer grid_destroy(&grid)
	grid_build_docs(&grid, docs, ext, allocator) or_return
	if render_grid_empty(&grid, target) {
		return nil, nil
	}
	out: Out
	if e := out_start(&out, allocator, {}, max(len(grid.text_buf), ROOM_MAX)); e != nil {
		return nil, e
	}
	if err = render_emit(&out, &grid, target, allocator); err != nil {
		out_drop(&out)
		return nil, err
	}
	return out_finish(&out)
}

// ---------------------------------------------------------------------------
// Shared output padding helpers
// ---------------------------------------------------------------------------

@(private)
put_str :: #force_inline proc(out: ^Out, s: string) {
	put(out, transmute([]u8)s)
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
	for left > 0 && out.err == nil {
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
// Shared tabular extraction (`Render_Grid`)
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

@(private = "file")
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
Cell_Flag :: enum u8 {
	Numeric,
	Absent,
	Null,
}

@(private)
Cell_Flags :: bit_set[Cell_Flag; u8]

@(private)
Cell_Span :: struct {
	lo:    int,
	n:     int,
	width: int,
	flags: Cell_Flags,
}

@(private = "file")
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

@(private = "file")
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
	want_widths := len(widths) > 0
	for c in 0 ..< cols {
		num_count := 0
		other_count := 0
		max_w := 0 if no_header else grid.headers[c].width
		for r in 0 ..< grid.rows {
			cell := grid.cells[r * cols + c]
			if want_widths && cell.width > max_w {
				max_w = cell.width
			}
			if .Numeric in cell.flags {
				num_count += 1
			} else if .Absent not_in cell.flags && .Null not_in cell.flags {
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
		if want_widths {
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
}

@(private)
Grid_Builder :: struct {
	grid:               ^Render_Grid,
	opts:               Render_Extract_Options,
	scratch:            [dynamic]u8,
	key_buf:            [dynamic]u8,
	keys:               [dynamic]Key_Span,
	alloc:              runtime.Allocator,
	has_container_keys: bool,
}

@(private = "file")
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

@(private = "file")
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

@(private = "file")
grid_build_doc :: proc(grid: ^Render_Grid, doc: ^tape.Document, opts: Render_Extract_Options, allocator: runtime.Allocator) -> Error {
	b: Grid_Builder
	grid_builder_init(&b, grid, opts, allocator)
	defer grid_builder_drop(&b)

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

@(private = "file")
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
		tree_check_root(&d, opts.node) or_return
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
			sort_spans(b.keys[:], b.key_buf[:])
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

	append_escaped_span(&b, &b.grid.headers, opts.value_header) or_return
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

@(private = "file")
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
		sort_spans(ordered, b.key_buf[:])
	}

	for item in ordered {
		s := string(b.key_buf[item.span.lo:][:item.span.n])
		append_escaped_span(b, &b.grid.headers, s) or_return
	}

	dups_last := false
	if doc.ext != nil {
		if ext, ok := doc.ext.format.(tape.Tabular_Ext); ok && ext.dups == .Last {
			dups_last = len(kept_cols) < len(keys)
		}
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
			} else if dups_last {
				// Under `.Last`, a short ragged row resolves a duplicate header to its rightmost present column.
				name := string(b.key_buf[item.span.lo:][:item.span.n])
				if val, p := tape.member(w.reader, at, name); p == .Found {
					append_value_cell(b, w, val) or_return
				} else {
					append_absent_cell(b) or_return
				}
			} else {
				append_absent_cell(b) or_return
			}
		}
		b.grid.rows += 1
	}
	return nil
}

@(private = "file")
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
			sort_spans(b.keys[:], b.key_buf[:])
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

	append_escaped_span(b, &b.grid.headers, b.opts.value_header) or_return
	for at := root + 1; at < end; at = tape.node_after(doc, at) {
		append_value_cell(b, w, at) or_return
		b.grid.rows += 1
	}
	return nil
}

@(private = "file")
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
			sort_spans(b.keys[:], b.key_buf[:])
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
		sort_spans(members[:], b.key_buf[:])
	}

	append_escaped_span(b, &b.grid.headers, "key") or_return
	append_escaped_span(b, &b.grid.headers, "value") or_return
	for m in members {
		key_text := string(b.key_buf[m.span.lo:][:m.span.n])
		append_escaped_span(b, &b.grid.cells, key_text) or_return
		append_value_cell(b, w, m.val_node) or_return
		b.grid.rows += 1
	}
	return nil
}

@(private = "file")
build_single_scalar :: proc(b: ^Grid_Builder, w: ^Tree, root: tape.Node_Index) -> Error {
	append_escaped_span(b, &b.grid.headers, b.opts.value_header) or_return
	append_value_cell(b, w, root) or_return
	b.grid.rows = 1
	return nil
}

@(private = "file")
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

@(private = "file")
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
		if doc.nodes[k].kind >= .Array {
			b.has_container_keys = true
		}
		clear(&b.scratch)
		format_key_raw(b, w, k) or_return
		if err := record_distinct_key(b, b.scratch[:], j); err != nil {
			return err
		}
		k = tape.node_after(doc, val)
	}
	return nil
}

@(private = "file")
finalize_headers_from_keys :: proc(b: ^Grid_Builder) -> Error {
	for ks in b.keys {
		append_escaped_span(b, &b.grid.headers, string(b.key_buf[ks.lo:][:ks.n])) or_return
	}
	return nil
}

@(private = "file")
append_object_row :: proc(b: ^Grid_Builder, w: ^Tree, obj_at: tape.Node_Index) -> Error {
	for ks in b.keys {
		name := string(b.key_buf[ks.lo:][:ks.n])
		val, p := tape.member(w.reader, obj_at, name)
		switch p {
		case .Found:
			append_value_cell(b, w, val) or_return
		case .Missing:
			if b.has_container_keys {
				// Fallback for container keys (which `tape.member` does not index by JSON text).
				fallback, found := find_container_key_member(b, w, obj_at, name) or_return
				if found {
					append_value_cell(b, w, fallback) or_return
					continue
				}
			}
			append_absent_cell(b) or_return
		case .Not_Loaded:
			return Refused{obj_at, .Partial}
		case .Wrong_Kind:
			append_absent_cell(b) or_return
		}
	}
	b.grid.rows += 1
	return nil
}

@(private = "file")
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

@(private = "file")
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

@(private = "file")
add_index_headers :: proc(b: ^Grid_Builder, count: int) -> Error {
	buf: [24]u8
	for i in 0 ..< count {
		s := strconv.write_int(buf[:], i64(i), 10)
		append_escaped_span(b, &b.grid.headers, s) or_return
	}
	return nil
}

@(private)
append_escaped_span :: proc(b: ^Grid_Builder, dst: ^[dynamic]Cell_Span, raw: string, flags: Cell_Flags = {}) -> Error {
	lo := len(b.grid.text_buf)
	width := append_escaped(&b.grid.text_buf, transmute([]u8)raw, b.opts.escape_mode) or_return
	n := len(b.grid.text_buf) - lo
	if _, err := append(dst, Cell_Span{lo = lo, n = n, width = width, flags = flags}); err != nil {
		return err
	}
	return nil
}

@(private)
append_absent_cell :: proc(b: ^Grid_Builder) -> Error {
	if _, err := append(&b.grid.cells, Cell_Span{lo = len(b.grid.text_buf), n = 0, width = 0, flags = {.Absent}}); err != nil {
		return err
	}
	return nil
}

// Stable zero-allocation binary insertion sort over `Key_Span` or structs carrying `.span: Key_Span`.
@(private = "file")
sort_spans :: proc(items: []$T, buf: []u8) {
	span_of :: #force_inline proc "contextless" (item: T) -> Key_Span {
		when T == Key_Span {
			return item
		} else {
			return item.span
		}
	}
	for i in 1 ..< len(items) {
		cur := items[i]
		cs := span_of(cur)
		cur_s := string(buf[cs.lo:][:cs.n])
		lo, hi := 0, i
		for lo < hi {
			mid := lo + (hi - lo) >> 1
			ms := span_of(items[mid])
			if cur_s < string(buf[ms.lo:][:ms.n]) {
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
