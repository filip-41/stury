package dsv

import "base:runtime"
import core "../core"
import typed "../core/typed"

// The typed read of a built delimited document, a plan's `node_read`: the hook of `unmarshal`, `Cells`, fed from
// `doc.nodes`.
// A cell has no kind of its own, so a document is read as its text is, by the column's field, and a value that reads gives
// the same answer through either. The nodes hold a root of records, each of cells, so a loop over them is the whole feed.
//
// The node read is the root, which reads as the list of rows, or a record, which reads as a list of that one row. A
// cell reads in no plan, since `plan_make` refuses a type that is no list of rows.
//
// A full document binds its columns once, from the header row of `Document.tables`. A list of rows reads the header
// row as its first row, as `unmarshal` does. A partial document has no shared keys: a headed record holds a key beside
// each cell it kept, which binds that record's columns, and a record kept by position reads a cell it did not keep as an
// empty unquoted one, which is `null`.

@(private)
Document_Cells :: struct {
	cells:      Cells,
	doc:        ^core.Document,
	kept:       int, // the first of `Document.kept` that may name a node not yet read
	pos:        int, // the position of the next cell of a record read by position
	per_record: bool, // each record binds its own columns from the keys beside its cells
	positional: bool, // the columns are bound by position, in a list row or a text with no header
	fill:       bool, // the record reads cells by their true positions
}

@(private)
document_read :: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	if foreign_plan(plan) {
		return {kind = .Plan_Mismatch}
	}
	root := node == core.ROOT
	if !root && doc.nodes[node].kind <= .Plain {
		return {kind = .Unsupported}
	}
	headless := options_of(doc.as).no_header
	d := Document_Cells{doc = doc}
	h := &d.cells
	frames: [ROW_FRAMES]typed.Frame = ---
	regs, err := typed.read_start(&h.r, doc.src, plan, doc.as, T, target, read, frames[:], allocator, false)
	if err.kind != .None {
		return err
	}
	// A node says less of a quoted cell than the walk's token, so every cell takes the cold read.
	rows_of(h, plan, 0)
	if h.row.kind == .Map && headless {
		return {kind = .Unsupported}
	}
	h.no_header = headless || h.opens == .Array
	d.positional = h.no_header
	// With no header line there is no list of rows to give the target, so it keeps what it held.
	if !h.no_header && core.header_of(doc) == 0 && !doc.partial && core.length(doc, core.ROOT) == 0 {
		return {}
	}
	d.per_record = !h.no_header && core.header_of(doc) == 0
	defer if d.per_record {
		delete(h.keys, context.temp_allocator)
	}
	defer delete(h.cols, context.temp_allocator)
	if !h.no_header && core.header_of(doc) != 0 {
		h.keys = header_keys(doc)
	}
	action: core.Action
	regs, action = row_token(h, regs, {kind = .Array, role = .Value, lo = doc.nodes[0].lo if root else 0})
	if root && h.opens == .Array && core.header_of(doc) != 0 && action == .Next {
		regs, action = header_row(&d, regs)
	}
	to := u32(node) + doc.nodes[node].n
	for i := u32(node) + (1 if root else 0); i < to && action != .Stop; i += doc.nodes[i].n {
		if doc.nodes[i].role != .Key {
			regs, action = record_row(&d, regs, core.Node_Index(i))
		}
	}
	if action != .Stop {
		// A partial document with no record has no columns to bind.
		if d.per_record && h.cols == nil {
			h.no_header = true
		}
		regs, _ = row_token(h, regs, {kind = .End, role = .Value, lo = u64(to) - 1 if root else u64(len(doc.src))})
	}
	return typed.read_end(&h.r, regs, nil)
}

// Reads record `rec` as a row, a record a path left partial as a value.
@(private)
record_row :: proc(d: ^Document_Cells, regs: core.Hook_Regs, rec: core.Node_Index) -> (out: core.Hook_Regs, action: core.Action) {
	h := &d.cells
	t := d.doc.nodes[rec]
	d.pos = 0
	d.fill = t.role == .Partial && d.positional
	if d.per_record {
		bind_record_keys(d, rec)
	}
	t.role = .Value
	out, action = row_token(h, regs, t)
	if action == .Stop || action == .Skip {
		return
	}
	last := u32(rec) + t.n
	for c := u32(rec) + 1; c < last; c += 1 {
		if out, action = document_cell(d, out, d.doc.nodes[c], core.Node_Index(c)); action == .Stop {
			return
		}
	}
	return document_close(d, out, {kind = .End, role = .Value, lo = u64(last) - 1}, rec)
}

// Gives the header row to a list of rows as its first row.
@(private)
header_row :: proc(d: ^Document_Cells, regs: core.Hook_Regs) -> (core.Hook_Regs, core.Action) {
	h := &d.cells
	keys := header_keys(d.doc)
	out, action := row_token(h, regs, {kind = .Array, role = .Value, lo = keys[0].lo})
	if action != .Next {
		return out, action
	}
	last: core.Token
	for key in keys {
		last = key
		key := key
		key.role = .Value
		out, action = on_cell(h, out, key)
		if action != .Next {
			return out, action
		}
	}
	return row_token(h, out, {kind = .End, role = .Value, lo = last.lo + u64(last.n)})
}

// The keys beside the cells record `rec` kept, as the columns the record binds.
@(private)
bind_record_keys :: proc(d: ^Document_Cells, rec: core.Node_Index) {
	h := &d.cells
	delete(h.keys, context.temp_allocator)
	delete(h.cols, context.temp_allocator)
	h.cols, h.keys = nil, nil
	nodes := d.doc.nodes[rec:][:d.doc.nodes[rec].n]
	count := 0
	for n in nodes[1:] {
		count += int(n.role == .Key)
	}
	keys, failed := make([]core.Token, count, context.temp_allocator)
	if failed != nil {
		return
	}
	c := 0
	for n in nodes[1:] {
		if n.role == .Key {
			keys[c] = n
			c += 1
		}
	}
	h.keys = keys
}

@(private)
document_cell :: proc(d: ^Document_Cells, regs: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	h := &d.cells
	if t.role != .Value {
		return regs, .Next
	}
	out, action := regs, core.Action.Next
	if d.fill {
		k := kept_position(d.doc, &d.kept, at)
		for ; d.pos < k; d.pos += 1 {
			out, action = on_cell(h, out, {kind = .Plain, role = .Value, lo = t.lo})
			if action != .Next {
				return out, action
			}
		}
		d.pos += 1
	}
	return on_cell(h, out, t)
}

// The true position `Document.kept` gives the child at `at` of a record, or -1 for a cell kept by name. The nodes of a
// replay come in order, so one cursor serves them all.
@(private)
kept_position :: proc "contextless" (doc: ^core.Document, cursor: ^int, at: core.Node_Index) -> int {
	kept := doc.kept
	for cursor^ < len(kept) && kept[cursor^].node < at {
		cursor^ += 1
	}
	if cursor^ < len(kept) && kept[cursor^].node == at {
		return int(kept[cursor^].index)
	}
	return -1
}

// Closes record `at`. The walk's `End` stands at the line end, which the cell before it does not tell a partial record.
@(private)
document_close :: proc(d: ^Document_Cells, regs: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	t := t
	if (^Column)(uintptr(regs.b)).must {
		end := d.doc.readers.close_end(d.doc, at)
		t.lo = end - u64(len(line_end_before(d.doc.src, end)))
		t.n = u32(end - t.lo)
	}
	return row_token(&d.cells, regs, t)
}
