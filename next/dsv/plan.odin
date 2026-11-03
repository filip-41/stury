package dsv

import "base:runtime"
import "core:slice"
import core "../core"
import compose "../core/compose"

// A commit's column changes. An edit names one cell, and a column is what the whole list does to every line, so this
// pass turns the list into plain cell edits before core composes it. A list with no cell inserted or removed costs one
// pass over its edits.
//
// A cell removed from every record that holds it drops its column with the header cell, and a cell removed from only
// some records is emptied. A header cell removed drops its column. A cell inserted beyond the old columns adds a column,
// one per name in a headed text and one per position in a headerless one, and every other record gets an empty cell. A
// record shorter than the table stays short unless a cell is written past its end.

// A line a column reaches, the header row first. `gone` says the list removes it, and `emptied` that it writes an empty
// cell in it.
@(private = "file")
Line :: struct {
	node:    core.Node_Index,
	n:       int,
	header:  bool,
	gone:    bool,
	emptied: bool,
}

// New column `id`, placed before old column `p`, with `order` ranking the columns placed there. `cell` is its header
// cell.
@(private = "file")
Column :: struct {
	id, p, order: int,
	cell:         []u8,
}

// A cell a list writes. `slot` is an old column, or `-1 - i` for new column `i`, until `plan_write` makes it a place in
// the row of all columns.
@(private = "file")
Fill :: struct {
	line, slot: int,
	text:       []u8,
}

// A column of the table a plan writes: old column `old`, or -1 for a new one with its header cell.
@(private = "file")
Slot :: struct {
	old:  int,
	cell: []u8,
}

// A procedure that returns false leaves its refusal in `err`, `.No_Memory` until one sets it.
@(private = "file")
Plan :: struct {
	doc:       ^core.Document,
	list:      ^core.Edit_List,
	out:       ^[dynamic]core.Edit,
	err:       core.Document_Error,
	lines:     [dynamic]Line,
	added:     [dynamic]Column,
	fills:     [dynamic]Fill,
	sets:      [dynamic]core.Edit, // by node
	dropped:   []bool,
	width:     int, // the longest line's cell count
	allocator: runtime.Allocator,
}

@(private = "file")
refuse :: proc(p: ^Plan, err: core.Document_Error) -> bool {
	p.err = err
	return false
}

// dsv's `Edit_Spelling.plan`.
@(private)
edit_plan :: proc(doc: ^core.Document, list: ^core.Edit_List, out: ^[dynamic]core.Edit, allocator: runtime.Allocator) -> (changed: bool, err: core.Document_Error) {
	cells, records, lone_empty := false, false, false
	for e in list.edits {
		#partial switch e.op {
		case .Insert:
			records = records || e.node == core.ROOT
			cells = cells || e.node != core.ROOT
		case .Remove:
			cells = cells || !is_line(doc, e.node)
		case .Set:
			if positional(doc, e.node) {
				return false, {kind = .Bad_Index}
			}
			lone_empty = lone_empty || len(e.text) == 0 && is_line(doc, e.node - 1) && core.length(doc, e.node - 1) == 1
		}
	}
	if !cells {
		if lone_empty {
			return false, {kind = .Bad_Width}
		}
		return false, record_widths(doc, list, dsv_width(doc), allocator) if records else {}
	}
	p := Plan{doc = doc, list = list, out = out, allocator = allocator, err = {kind = .No_Memory}}
	if !plan_columns(&p) {
		return false, p.err
	}
	return true, record_widths(doc, list, planned_width(&p), allocator)
}

// Whether `node` is a header cell `.Ragged` named by its position, which the header's line does not hold.
@(private = "file")
positional :: #force_inline proc(doc: ^core.Document, node: core.Node_Index) -> bool {
	return doc.nodes[node].spelling & SPELLING_COLUMN != 0
}

@(private = "file")
is_line :: #force_inline proc(doc: ^core.Document, node: core.Node_Index) -> bool {
	return doc.nodes[node].kind == .Array || doc.nodes[node].kind == .Map
}

// Refuses an inserted record that does not hold `width` cells. An empty table has no width, so its records must agree.
@(private = "file")
record_widths :: proc(doc: ^core.Document, list: ^core.Edit_List, width: int, allocator: runtime.Allocator) -> core.Document_Error {
	want := width
	for e in list.edits {
		if e.op != .Insert || e.node != core.ROOT {
			continue
		}
		cells, err := edit_record_at(doc, e.text, allocator)
		if err.kind != .None {
			return err
		}
		if want == 0 {
			want = cells
		}
		if cells != want {
			return {kind = .Bad_Width}
		}
	}
	return {}
}

// Returns the table's width once the plan's columns are gone and added.
@(private = "file")
planned_width :: proc(p: ^Plan) -> int {
	old := dsv_width(p.doc)
	width := old
	for c in 0 ..< old {
		width -= 1 if p.dropped[c] else 0
	}
	for c in p.added {
		width += 1 if c.p <= old else 0
	}
	return width
}

@(private = "file")
plan_columns :: proc(p: ^Plan) -> bool {
	p.lines, _ = make([dynamic]Line, 0, core.length(p.doc, core.ROOT) + 1, p.allocator)
	p.added, _ = make([dynamic]Column, p.allocator)
	p.fills, _ = make([dynamic]Fill, p.allocator)
	plan_lines(p) or_return
	for e in p.list.edits {
		switch e.op {
		case .Set, .Set_Fact, .Remove_Fact:
			compose.push(p.out, e) or_return
		case .Insert:
			if e.node == core.ROOT {
				compose.push(p.out, e) or_return
			}
		case .Remove:
			if is_line(p.doc, e.node) {
				compose.push(p.out, e) or_return
			}
		}
	}
	plan_cuts(p) or_return
	plan_fills(p) or_return
	plan_write(p) or_return
	return true
}

@(private = "file")
plan_lines :: proc(p: ^Plan) -> bool {
	doc := p.doc
	if doc.shared_keys != 0 {
		p.width = core.length(doc, doc.shared_keys)
		n := p.width
		for n > 0 && positional(doc, doc.shared_keys + core.Node_Index(n)) {
			n -= 1
		}
		compose.push(&p.lines, Line{node = doc.shared_keys, n = n, header = true}) or_return
	}
	it := core.children(doc, core.ROOT)
	for {
		rec, more := core.child_next(&it)
		if !more {
			break
		}
		n := core.length(doc, rec)
		p.width = max(p.width, n)
		compose.push(&p.lines, Line{node = rec, n = n}) or_return
	}
	for e in p.list.edits {
		if e.op == .Remove && is_line(doc, e.node) {
			p.lines[line_at(p.lines[:], e.node)].gone = true
		}
	}
	return true
}

// Returns the line that holds `node`, or is it, from the line `at`, which is that line or one before it.
@(private = "file")
line_from :: #force_inline proc(lines: []Line, at: int, node: core.Node_Index) -> int {
	i := at
	for i + 1 < len(lines) && lines[i + 1].node <= node {
		i += 1
	}
	return i
}

// Returns the line that holds `node`, or is it.
@(private = "file")
line_at :: proc(lines: []Line, node: core.Node_Index) -> int {
	i, found := slice.binary_search_by(lines, node, proc(l: Line, n: core.Node_Index) -> slice.Ordering {
		return slice.cmp(l.node, n)
	})
	return i if found else i - 1
}

// Decides which columns the removed cells drop, and empties the cells of the columns that stay.
@(private = "file")
plan_cuts :: proc(p: ^Plan) -> bool {
	doc, lines := p.doc, p.lines[:]
	cuts, _ := make([dynamic]core.Node_Index, p.allocator)
	for e in p.list.edits {
		if e.op == .Remove && !is_line(doc, e.node) {
			compose.push(&cuts, e.node) or_return
		}
	}
	slice.sort(cuts[:])
	// A cell the list both sets and removes is a conflict, whatever else the list does to its line's width.
	writes, _ := make([dynamic]core.Node_Index, p.allocator)
	for e in p.list.edits {
		if e.op == .Set {
			compose.push(&writes, e.node) or_return
		}
	}
	slice.sort(writes[:])
	dropped, e1 := make([]bool, p.width, p.allocator)
	held, e2 := make([]int, p.width, p.allocator)
	cut, e3 := make([]int, p.width, p.allocator)
	if e1 != nil || e2 != nil || e3 != nil {
		return false
	}
	p.dropped = dropped
	for l in lines {
		if !l.header && !l.gone && l.n > 0 {
			held[l.n - 1] += 1
		}
	}
	// `held[c]` becomes the count of surviving records with a cell in column `c`.
	for c := p.width - 2; c >= 0; c -= 1 {
		held[c] += held[c + 1]
	}
	at := 0
	for node, i in cuts {
		_, written := slice.binary_search(writes[:], node)
		if written || i > 0 && cuts[i - 1] == node {
			return refuse(p, {kind = .Conflicting_Edits, at = core.node_start(doc.nodes[node])})
		}
		at = line_from(lines, at, node)
		l := lines[at]
		col := int(node - l.node) - 1
		switch {
		case l.header:
			dropped[col] = true
		case l.gone:
			compose.push(p.out, core.Edit{node = node, op = .Remove, role = .Value}) or_return
		case:
			cut[col] += 1
		}
	}
	for c in 0 ..< p.width {
		dropped[c] = dropped[c] || cut[c] > 0 && cut[c] == held[c]
	}
	at = 0
	for node in cuts {
		at = line_from(lines, at, node)
		l := lines[at]
		if !l.header && !l.gone && !dropped[int(node - l.node) - 1] {
			compose.push(p.out, core.Edit{node = node, op = .Set, role = .Value}) or_return
		}
	}
	return true
}

// Sorts the list's cell inserts into new columns and the cells each record writes.
@(private = "file")
plan_fills :: proc(p: ^Plan) -> bool {
	doc := p.doc
	if doc.shared_keys != 0 {
		for e in p.list.edits {
			if e.op == .Insert && e.node == doc.shared_keys {
				compose.push(&p.added, Column{id = len(p.added), p = int(e.at), order = len(p.added), cell = e.text}) or_return
			}
		}
		for e in p.list.edits {
			if e.op == .Insert && e.role == .Key {
				plan_named(p, e) or_return
			}
		}
		return true
	}
	inserts, _ := make([dynamic]core.Edit, p.allocator)
	for e in p.list.edits {
		if e.op == .Insert && e.node != core.ROOT {
			compose.push(&inserts, e) or_return
		}
	}
	slice.stable_sort_by(inserts[:], proc(a, b: core.Edit) -> bool {
		return a.node != b.node ? a.node < b.node : a.at < b.at
	})
	nth := 0
	for e, i in inserts {
		nth = nth + 1 if i > 0 && inserts[i - 1].node == e.node && inserts[i - 1].at == e.at else 0
		line := line_at(p.lines[:], e.node)
		at, order := int(e.at), nth
		// A cell written at a short record's end takes the next column it lacks.
		if at == p.lines[line].n {
			if at + nth < p.width {
				plan_fill(p, line, at + nth, e.text) or_return
				continue
			}
			at, order = p.width, at + nth - p.width
		}
		col := -1
		for c, k in p.added {
			if c.p == at && c.order == order {
				col = k
			}
		}
		if col < 0 {
			col = len(p.added)
			compose.push(&p.added, Column{id = col, p = at, order = order}) or_return
		}
		plan_fill(p, line, -1 - col, e.text) or_return
	}
	return true
}

// Places a named insert: in the column that holds its name when its record lacks that cell, else in a new column, which
// every insert of that name must place alike.
@(private = "file")
plan_named :: proc(p: ^Plan, e: core.Edit) -> bool {
	doc := p.doc
	line := line_at(p.lines[:], e.node)
	l := p.lines[line]
	for c in 0 ..< core.length(doc, doc.shared_keys) {
		cell := doc.shared_keys + 1 + core.Node_Index(c)
		if !core.key_equals(doc, cell, string(e.key)) {
			continue
		}
		if c < l.n || p.dropped[c] {
			return refuse(p, {kind = .Duplicate_Key, at = core.node_start(doc.nodes[cell])})
		}
		return plan_fill(p, line, c, e.text)
	}
	spelled, _ := make([dynamic]u8, p.allocator)
	edit_key_text(doc, e.key, &spelled) or_return
	at := int(e.at) if int(e.at) < l.n else p.width
	col := -1
	for c, k in p.added {
		if string(c.cell) == string(spelled[:]) {
			col = k
			break
		}
	}
	if col < 0 {
		if bad := edit_value_at(doc, spelled[:], p.allocator); bad.kind != .None {
			return refuse(p, bad)
		}
		col = len(p.added)
		compose.push(&p.added, Column{id = col, p = at, order = col, cell = spelled[:]}) or_return
	} else if p.added[col].p != at {
		return refuse(p, {kind = .Bad_Position})
	}
	return plan_fill(p, line, -1 - col, e.text)
}

@(private = "file")
plan_fill :: proc(p: ^Plan, line, slot: int, text: []u8) -> bool {
	if slot >= 0 && p.dropped[slot] {
		return refuse(p, {kind = .Conflicting_Edits, at = core.node_start(p.doc.nodes[p.lines[line].node])})
	}
	_, ok := compose.push(&p.fills, Fill{line = line, slot = slot, text = text})
	return ok
}

// Writes each line's edits, walking the row of all columns.
@(private = "file")
plan_write :: proc(p: ^Plan) -> bool {
	p.sets, _ = make([dynamic]core.Edit, p.allocator)
	for e in p.out {
		if e.op == .Set {
			compose.push(&p.sets, e) or_return
		}
	}
	slice.sort_by(p.sets[:], proc(a, b: core.Edit) -> bool { return a.node < b.node })
	line := 0
	for e in p.sets {
		line = line_from(p.lines[:], line, e.node)
		p.lines[line].emptied ||= len(e.text) == 0
	}
	// With no column added or dropped, only a line the list wrote can change.
	columns := len(p.added) > 0 || slice.contains(p.dropped, true)
	if columns && reserve(p.out, len(p.out) + len(p.lines)) != nil {
		return false
	}
	order, e1 := slice.clone(p.added[:], p.allocator)
	old_slot, e2 := make([]int, p.width, p.allocator)
	new_slot, e3 := make([]int, len(p.added), p.allocator)
	slots, _ := make([dynamic]Slot, p.allocator)
	if e1 != nil || e2 != nil || e3 != nil {
		return false
	}
	slice.sort_by(order, proc(a, b: Column) -> bool {
		return a.p != b.p ? a.p < b.p : a.order < b.order
	})
	next := 0
	for at in 0 ..= p.width {
		for next < len(order) && order[next].p == at {
			new_slot[order[next].id] = len(slots)
			compose.push(&slots, Slot{old = -1, cell = order[next].cell}) or_return
			next += 1
		}
		if at < p.width {
			old_slot[at] = len(slots)
			compose.push(&slots, Slot{old = at}) or_return
		}
	}
	for &f in p.fills {
		f.slot = old_slot[f.slot] if f.slot >= 0 else new_slot[-1 - f.slot]
	}
	slice.sort_by(p.fills[:], proc(a, b: Fill) -> bool {
		return a.line != b.line ? a.line < b.line : a.slot < b.slot
	})
	for f, i in p.fills {
		if i > 0 && p.fills[i - 1].line == f.line && p.fills[i - 1].slot == f.slot {
			return refuse(p, {kind = .Conflicting_Edits, at = core.node_start(p.doc.nodes[p.lines[f.line].node])})
		}
	}
	lo := 0
	for l, i in p.lines {
		hi := lo
		for hi < len(p.fills) && p.fills[hi].line == i {
			hi += 1
		}
		if columns || hi > lo || l.emptied {
			plan_line(p, l, slots[:], p.fills[lo:hi]) or_return
		}
		lo = hi
	}
	return true
}

// Writes one line's edits. A cell before one of the line's own always goes in, and one past its end goes in when a
// later cell needs it or the line holds every old column. A removed line keeps only the cells the list wrote, which the
// commit refuses as a conflict.
@(private = "file")
plan_line :: proc(p: ^Plan, l: Line, slots: []Slot, fills: []Fill) -> bool {
	if l.header && l.n < p.width {
		// The header's line names the table's last columns by position, which a column added or dropped before them
		// would change.
		for slot in slots {
			if slot.old < 0 || slot.old < l.n && p.dropped[slot.old] {
				return refuse(p, {kind = .Bad_Width})
			}
		}
	}
	last := fills[len(fills) - 1].slot if len(fills) > 0 else -1
	if l.n >= p.width {
		last = len(slots)
	}
	at, f, kept := 0, 0, 0
	first: []u8 // the bytes the line will start with
	moved := false // an old cell that was not first is first now
	for slot, s in slots {
		if slot.old >= 0 && slot.old < l.n {
			if p.dropped[slot.old] {
				if !l.gone {
					compose.push(p.out, core.Edit{node = l.node + 1 + core.Node_Index(slot.old), op = .Remove, role = .Value}) or_return
				}
			} else {
				if kept == 0 {
					node := l.node + 1 + core.Node_Index(slot.old)
					i, found := slice.binary_search_by(p.sets[:], node, proc(e: core.Edit, n: core.Node_Index) -> slice.Ordering {
						return slice.cmp(e.node, n)
					})
					first, moved = p.sets[i].text if found else core.span(p.doc, node), slot.old > 0
				}
				kept += 1
			}
			at = slot.old + 1
			continue
		}
		if slot.old >= 0 && p.dropped[slot.old] {
			continue
		}
		text := slot.cell if l.header else nil
		filled := f < len(fills) && fills[f].slot == s
		if filled {
			text = fills[f].text
			f += 1
		}
		if filled || !l.gone && (at < l.n || s <= last) {
			compose.push(p.out, core.Edit{node = l.node, op = .Insert, role = .Value, at = u32(at), text = text}) or_return
			if kept == 0 {
				first = text
			}
			kept += 1
		}
	}
	if !l.gone && !line_reads(p.doc, l, kept, first, moved) {
		return refuse(p, {kind = .Bad_Width})
	}
	return true
}

// Whether a line still reads as its record. An empty line is no record, so it keeps a cell and its one cell is not empty,
// and an old cell that becomes the first must not read as a comment or, on the text's first line, as a byte order mark.
@(private = "file")
line_reads :: proc(doc: ^core.Document, l: Line, kept: int, first: []u8, moved: bool) -> bool {
	if kept == 0 || kept == 1 && len(first) == 0 {
		return false
	}
	if !moved || len(first) == 0 {
		return true
	}
	if comment := doc.as.opts[1]; comment != 0 && first[0] == comment {
		return false
	}
	return doc.nodes[l.node].lo != 0 || len(first) < 3 || string(first[:3]) != "\xEF\xBB\xBF"
}
