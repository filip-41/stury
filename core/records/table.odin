package records

// The table a writer of a delimited text makes of its rows, across every call until `table_end`. An object row's keys
// make the header, the first object's keys sorted under `sort_keys`, and a key the header lacks is `.Unknown_Field`,
// unless `grow_header` holds every object row and writes them at `table_end` under a header of every key in first-seen
// order. An array row and a scalar, one cell, are rows with no header, and the two shapes do not mix: `.Wrong_Kind`. A
// cell that is an array or an object is `.Unsupported`. A refusal's path is the row's index, then the key or the cell's
// index, and a refusal of the header has none. A refused row leaves no byte of its own, and the first row takes its
// header with it. A comment line is the comment byte and the line's text: a format with no comment byte has no place
// for them, and a body with a control byte a line cannot hold is left out. What the table holds lives in its `store`
// until `table_end`, and a refused allocation is a final `.No_Memory`.

import "base:runtime"
import "core:slice"
import "core:strings"
import core ".."
import cw "../write"

Table_Shape :: enum u8 {
	Unset,
	Objects,
	Rows,
}

Table :: struct {
	shape:   Table_Shape,
	header:  [dynamic]string,
	held:    [dynamic]Held_Row, // `grow_header`: the object rows, written at `table_end`
	rows:    int, // the rows offered, refused ones too
	foot:    [dynamic]string, // comment lines written after the last row
	kept:    int, // the comment bodies written
	dropped: int, // the comment bodies with no place, and the cells a repeated key overwrote
	store:   runtime.Arena, // what the lists above hold
}

Held_Row :: struct {
	row:   int,
	keys:  []string,
	cells: []cw.Scalar,
	notes: []string,
}

// Writes an object's `cells`, under its `keys`, as a row of the table, `notes` as comment lines above it. `ordered`
// says the keys are the header's, in its order.
write_object :: proc(wr: ^Writer, keys: []string, cells: []cw.Scalar, notes: []string = nil, ordered := false) -> core.Typed_Error_Kind {
	if wr.final {
		return wr.err.kind
	}
	t := &wr.table
	t.rows += 1
	if t.shape == .Rows {
		return table_refuse(wr, .Wrong_Kind, .Object)
	}
	grow := wr.tokens.opts.grow_header
	same := ordered || t.shape == .Unset || grow || slice.equal(t.header[:], keys)
	for k, i in keys {
		if !same && !slice.contains(t.header[:], k) {
			return table_refuse(wr, .Unknown_Field, .Null, core.Name(k))
		}
		if found, inner := container(cells[i]); inner {
			return table_refuse(wr, .Unsupported, found, core.Name(k))
		}
	}
	t.shape = .Objects
	if grow {
		return hold_row(wr, keys, cells, notes)
	}
	fresh := len(t.header) == 0
	if fresh {
		for k in keys {
			keep(wr, &t.header, k) or_return
		}
		if wr.tokens.opts.sort_keys {
			slice.sort(t.header[:])
		}
	}
	row := cells
	if !ordered && !slice.equal(t.header[:], keys) {
		row = aligned(wr, t.header[:], keys, cells) or_return
	}
	return put_row(wr, row, notes, fresh)
}

// Writes `cells`, an array's or one scalar's, as a row with no header, `notes` as comment lines above it.
write_row :: proc(wr: ^Writer, cells: []cw.Scalar, notes: []string = nil) -> core.Typed_Error_Kind {
	if wr.final {
		return wr.err.kind
	}
	t := &wr.table
	t.rows += 1
	if t.shape == .Objects {
		return table_refuse(wr, .Wrong_Kind, .Array)
	}
	for c, i in cells {
		if found, inner := container(c); inner {
			return table_refuse(wr, .Unsupported, found, core.Index(i))
		}
	}
	t.shape = .Rows
	return put_row(wr, cells, notes, false)
}

// Writes `notes`, each the text after the comment byte, as comment lines now. A format with no place for them drops them.
write_notes :: proc(wr: ^Writer, notes: []string) -> core.Typed_Error_Kind {
	if wr.final {
		return wr.err.kind
	}
	t := &wr.tokens
	t.mark = t.out.flushed + t.out.cursor
	for n in notes {
		if t.spell.comment == nil || t.spell.comment(t, .Comment, n) != .None {
			break
		}
	}
	return t.out.err
}

// The lines of `bodies` a table writes as comment lines, appended to `into` in its allocator, each that is not empty
// after a space when `padded`. Returns the bodies kept, and `.No_Memory` when an allocation failed.
comment_lines :: proc(bodies: []string, into: ^[dynamic]string, padded := true) -> (kept: int, kind: core.Typed_Error_Kind) {
	for b in bodies {
		if !cw.comment_lines_ok(b) {
			continue
		}
		kept += 1
		// An empty body is one empty line.
		rest := b if len(b) > 0 else "\n"
		for line in strings.split_lines_iterator(&rest) {
			text, err := line, runtime.Allocator_Error.None
			if padded && len(line) > 0 {
				text, err = strings.concatenate({" ", line}, into.allocator)
			}
			if _, failed := append(into, text); err != nil || failed != nil {
				return kept, .No_Memory
			}
		}
	}
	return kept, .None
}

// Holds copies of `lines`, each the text after the comment byte, to write after the table's last row.
hold_notes :: proc(wr: ^Writer, lines: []string) -> core.Typed_Error_Kind {
	for n in lines {
		keep(wr, &wr.table.foot, n) or_return
	}
	return .None
}

// Ends the table: the rows `grow_header` held under the header of every key, then the foot. The next row starts a new
// table. A refusal of a held row is final.
table_end :: proc(wr: ^Writer) -> core.Typed_Error_Kind {
	if wr.final {
		return wr.err.kind
	}
	t := &wr.table
	kind := core.Typed_Error_Kind.None
	if len(t.held) > 0 {
		if wr.tokens.opts.sort_keys {
			slice.sort(t.header[:])
		}
		for r, i in t.held {
			t.rows = r.row
			row: []cw.Scalar
			if row, kind = aligned(wr, t.header[:], r.keys, r.cells); kind == .None {
				kind = put_row(wr, row, r.notes, i == 0)
			}
			if kind != .None {
				// The rows held are written in part: the refusal ends the writer.
				wr.final = true
				return kind
			}
		}
	}
	if len(t.foot) > 0 {
		kind = write_notes(wr, t.foot[:])
	}
	table_reset(wr)
	return kind
}

@(private)
table_reset :: proc(wr: ^Writer) {
	t := &wr.table
	runtime.arena_free_all(&t.store)
	clear(&t.header)
	clear(&t.held)
	clear(&t.foot)
	t.shape, t.rows = .Unset, 0
}

@(private)
table_free :: proc(wr: ^Writer) {
	t := &wr.table
	runtime.arena_destroy(&t.store)
	delete(t.header)
	delete(t.held)
	delete(t.foot)
	delete(wr.row)
}

// Appends a copy of `s` in the table's store to `list`.
@(private)
keep :: proc(wr: ^Writer, list: ^[dynamic]string, s: string) -> core.Typed_Error_Kind {
	c, err := strings.clone(s, runtime.arena_allocator(&wr.table.store))
	if _, failed := append(list, c); err != nil || failed != nil {
		return out_of_memory(wr)
	}
	return .None
}

@(cold, private)
out_of_memory :: proc(wr: ^Writer) -> core.Typed_Error_Kind {
	wr.err, wr.final = {kind = .No_Memory}, true
	return .No_Memory
}

// The kind of an array or object cell, which `cw.Tree_Part`'s opens stand for.
@(private)
container :: #force_inline proc(c: cw.Scalar) -> (core.Kind, bool) {
	part, is_part := c.(cw.Tree_Part)
	if !is_part || part != .Open_Array && part != .Open_Object {
		return .Null, false
	}
	return .Object if part == .Open_Object else .Array, true
}

// The refusal `kind` of the open row, found as `found`, at `step` in it when it has one.
@(cold, private)
table_refuse :: proc(wr: ^Writer, kind: core.Typed_Error_Kind, found: core.Kind, at: Maybe(core.Step) = nil) -> core.Typed_Error_Kind {
	wr.err = {kind = kind, found = found, n_steps = 1}
	wr.err.steps[0] = core.Index(wr.table.rows - 1)
	if step, stepped := at.?; stepped {
		if name, named := step.(core.Name); named {
			wr.err.steps[1] = core.Name(strings.clone(string(name), context.temp_allocator))
		} else {
			wr.err.steps[1] = step
		}
		wr.err.n_steps = 2
	}
	return kind
}

// Writes the open row: the header when it is the first, `notes`, then `cells`. A refusal leaves
// none of it when none was flushed.
@(private)
put_row :: proc(wr: ^Writer, cells: []cw.Scalar, notes: []string, headed: bool) -> core.Typed_Error_Kind {
	t := &wr.tokens
	start := t.out.flushed + t.out.cursor
	t.mark = start
	wr.cells = nil
	kind := core.Typed_Error_Kind.None
	if headed {
		t.mark = t.out.flushed + t.out.cursor
		if kind = t.spell.names(t, wr.table.header[:]); kind != .None {
			wr.err = {kind = kind}
			wr.cells = make([]cw.Scalar, len(wr.table.header), context.temp_allocator)
			for name, i in wr.table.header {
				wr.cells[i] = name
			}
		}
	}
	if kind == .None {
		kind = write_notes(wr, notes)
	}
	if kind == .None {
		t.mark = t.out.flushed + t.out.cursor
		kind = .Unwritable if len(cells) == 1 && cells[0] == nil else put_cells(t, cells)
		if kind != .None {
			table_refuse(wr, kind, .Null)
		}
	}
	if kind == .None && t.out.err == .None {
		return .None
	}
	t.mark = start
	if wr.cells == nil {
		wr.cells = slice.clone(cells, context.temp_allocator)
	}
	return refused(wr, kind, true)
}

// The cells of an object row under `header`: each key's cell in the header's order, empty for a key the row lacks.
@(private)
aligned :: proc(wr: ^Writer, header, keys: []string, cells: []cw.Scalar) -> ([]cw.Scalar, core.Typed_Error_Kind) {
	if resize(&wr.row, len(header)) != nil {
		return nil, out_of_memory(wr)
	}
	slice.zero(wr.row[:])
	for k, i in keys {
		if at, found := slice.linear_search(header, k); found {
			wr.row[at] = cells[i]
		}
	}
	return wr.row[:], .None
}

// Holds copies of an object row for `table_end`, and adds the keys the header lacks.
@(private)
hold_row :: proc(wr: ^Writer, keys: []string, cells: []cw.Scalar, notes: []string) -> core.Typed_Error_Kind {
	a := runtime.arena_allocator(&wr.table.store)
	k, n := make([dynamic]string, a), make([dynamic]string, a)
	row, err := make([]cw.Scalar, len(cells), a)
	if err != nil {
		return out_of_memory(wr)
	}
	for note in notes {
		keep(wr, &n, note) or_return
	}
	for key, i in keys {
		keep(wr, &k, key) or_return
		if row[i] = cell_clone(cells[i], a); row[i] == nil && cells[i] != nil {
			return out_of_memory(wr)
		}
		if !slice.contains(wr.table.header[:], key) {
			keep(wr, &wr.table.header, key) or_return
		}
	}
	if _, failed := append(&wr.table.held, Held_Row{wr.table.rows, k[:], row, n[:]}); failed != nil {
		return out_of_memory(wr)
	}
	return .None
}

// A copy of `c` in `a`, or nil when an allocation failed.
@(private)
cell_clone :: proc(c: cw.Scalar, a: runtime.Allocator) -> cw.Scalar {
	#partial switch x in c {
	case string:
		text, err := strings.clone(x, a)
		return text if err == nil else nil
	case cw.Number_Literal:
		text, err := strings.clone(x.text, a)
		return cw.Number_Literal{text} if err == nil else nil
	case cw.Tagged_Text:
		text, err := strings.clone(x.text, a)
		tag, terr := strings.clone(x.tag, a)
		return cw.Tagged_Text{text, tag, x.meaning} if err == nil && terr == nil else nil
	}
	return c
}

// Writes `v` as the table's rows: a list's elements, an object as one row, or a scalar as one cell. The list's comments
// are written now and its foot is held for `table_end`, and an element's comments go above its row.
write_rows :: proc(wr: ^Writer, v: core.Value) -> core.Typed_Error_Kind {
	// A row's cells, and the list's comment lines before the first row, live in `row` until the next row.
	row := runtime.Arena{backing_allocator = wr.allocator}
	defer runtime.arena_destroy(&row)
	if core.value_kind(v) != .Array {
		return value_row(wr, v, &row)
	}
	context.allocator = runtime.arena_allocator(&row)
	head, foot := make([dynamic]string), make([dynamic]string)
	value_notes(wr, v, .Comment, &head) or_return
	value_notes(wr, v, .Comment_Foot, &foot) or_return
	write_notes(wr, head[:]) or_return
	hold_notes(wr, foot[:]) or_return
	it := core.value_children(v)
	for rec in core.value_child_next(&it) {
		value_row(wr, rec, &row) or_return
		if wr.taken != nil {
			wr.taken(wr.taker, writer_take(wr))
		}
	}
	return .None
}

@(private)
value_row :: proc(wr: ^Writer, v: core.Value, scratch: ^runtime.Arena) -> core.Typed_Error_Kind {
	defer runtime.arena_free_all(scratch)
	context.allocator = runtime.arena_allocator(scratch)
	lines, keys, cells := make([dynamic]string), make([dynamic]string), make([dynamic]cw.Scalar)
	value_notes(wr, v, .Comment, &lines) or_return
	#partial switch core.value_kind(v) {
	case .Object:
		it := core.value_pairs(v)
		for name, member in core.value_pair_next(&it) {
			cell, kind := value_cell(member)
			if kind != .None {
				return cell_fault(wr, kind, core.Name(name))
			}
			// A repeated key keeps its first place and takes its last value.
			if at, repeated := slice.linear_search(keys[:], name); repeated {
				cells[at] = cell
				wr.table.dropped += 1
				continue
			}
			_, failed := append(&keys, name)
			if _, missed := append(&cells, cell); failed != nil || missed != nil {
				return out_of_memory(wr)
			}
		}
		return write_object(wr, keys[:], cells[:], lines[:])
	case .Array:
		it := core.value_children(v)
		for member in core.value_child_next(&it) {
			put_cell(wr, &cells, member, core.Index(len(cells))) or_return
		}
	case:
		put_cell(wr, &cells, v, core.Index(0)) or_return
	}
	return write_row(wr, cells[:], lines[:])
}

// Appends the cell `v` writes as to `cells`, or refuses the next row at `at`.
@(private)
put_cell :: proc(wr: ^Writer, cells: ^[dynamic]cw.Scalar, v: core.Value, at: core.Step) -> core.Typed_Error_Kind {
	cell, kind := value_cell(v)
	if kind != .None {
		return cell_fault(wr, kind, at)
	}
	if _, failed := append(cells, cell); failed != nil {
		return out_of_memory(wr)
	}
	return .None
}

// The refusal `kind` of the next row's cell at `at`, which a failed allocation makes final.
@(cold, private)
cell_fault :: proc(wr: ^Writer, kind: core.Typed_Error_Kind, at: core.Step) -> core.Typed_Error_Kind {
	if kind == .No_Memory {
		return out_of_memory(wr)
	}
	wr.table.rows += 1
	return table_refuse(wr, kind, .Null, at)
}

// Appends the comment lines of `v`'s comments of `role` to `lines`, a node's each after a space where its source had
// one, and counts the bodies kept.
@(private)
value_notes :: proc(wr: ^Writer, v: core.Value, role: core.Role, lines: ^[dynamic]string) -> core.Typed_Error_Kind {
	if !wr.tokens.notes {
		return .None
	}
	kept, kind := 0, core.Typed_Error_Kind.None
	if r, is_ref := v.(core.Node_Ref); is_ref {
		if len(r.doc.facts) == 0 {
			return .None
		}
		it := core.facts_of(r.doc, r.node, role)
		for text, padded in core.comment_next(&it) {
			n, failed := comment_lines({text}, lines, padded)
			kept, kind = kept + n, failed if failed != .None else kind
		}
	} else {
		bodies, _ := core.comments(v, role)
		kept, kind = comment_lines(bodies, lines)
	}
	wr.table.kept += kept
	return out_of_memory(wr) if kind != .None else .None
}

// The cell `v` writes as, see `node_cell`.
@(private)
value_cell :: proc(v: core.Value) -> (cw.Scalar, core.Typed_Error_Kind) {
	#partial switch x in core.plain(v) {
	case core.Node_Ref:
		return node_cell(x.doc, x.node)
	case bool:
		return cw.Tree_Part.True if x else cw.Tree_Part.False, .None
	case f64:
		n, _ := core.number(v)
		return n, .None
	case core.Number_View:
		return cw.Number_Literal{core.view_text(x)}, .None
	case string:
		return x, .None
	case ^core.Array, core.Trail:
		return cw.Tree_Part.Open_Array, .None
	case ^core.Object:
		return cw.Tree_Part.Open_Object, .None
	}
	return nil, .None
}

// The cell node `node` writes as: its text, a number as JSON spells it, true, false, or empty for null and a delimited
// text's absent cell. An array or an object is the open of its kind.
@(private)
node_cell :: proc(doc: ^core.Document, node: core.Node_Index) -> (cw.Scalar, core.Typed_Error_Kind) {
	buf: [512]u8
	// The stored kind, not `core.kind`'s: a cell is written as its text, which spells the kind it reads as.
	#partial switch doc.nodes[node].kind {
	case .Null:
		return nil, .None
	case .True:
		return cw.Tree_Part.True, .None
	case .False:
		return cw.Tree_Part.False, .None
	case .Array:
		return cw.Tree_Part.Open_Array, .None
	case .Object:
		return cw.Tree_Part.Open_Object, .None
	case .Bytes:
		text, ok := cw.node_bytes_text(doc, node, buf[:])
		owned, err := strings.clone(text)
		return owned, .None if ok && err == nil else .No_Memory
	case .Number:
		if doc.readers.number_text == nil && doc.nodes[node].spelling & core.NUMBER_KIND_MASK == 0 {
			return cw.Number_Literal{string(core.span(doc, node))}, .None
		}
		spill: [cw.ROOM_MAX]u8 = ---
		out: cw.Out
		cw.init(&out, &spill, context.allocator)
		kind := cw.put_number_node(&out, doc, node, cw.MARKUP_TREE)
		text, err := cw.finish(&out, {kind = kind})
		return cw.Number_Literal{string(text)}, err.kind
	}
	// A delimited text's cell with no bytes at all is absent, where a quoted empty one is an empty string.
	if len(core.span(doc, node)) == 0 {
		return nil, .None
	}
	text, kind := cw.node_text(doc, node, buf[:], context.allocator)
	if kind == .None && raw_data(text) == raw_data(buf[:]) {
		err: runtime.Allocator_Error
		if text, err = strings.clone(text); err != nil {
			kind = .No_Memory
		}
	}
	return text, kind
}
