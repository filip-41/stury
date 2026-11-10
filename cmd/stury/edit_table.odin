package main

// `stury edit` on a table. The filter runs on each record, or under `-s` once on the array of them, and its outputs are
// the records written back. The edit is two commits. The first edits each kept record's cells and comments, which adds
// and drops columns across the table, and removes the records with no output. The second, when the outputs ask for it,
// puts the header and every row in the outputs' key order and writes the new records in their places, in the final
// columns. A third gives the new records the comments their outputs carry, once they have nodes to hold them.

import "base:runtime"
import "core:slice"
import "core:strings"
import core "../../core"
import "jq"
import "message"

// A record the outputs write: the source record it edits, or -1 for a new one, its value, and the line it is told at.
@(private = "file")
Edit_Placed :: struct {
	rec:   int,
	value: jq.Value,
	line:  int,
}

edit_table :: proc(er: ^Edit_Run, path: string) -> int {
	ins := er.ins
	src := ins.data
	heap := runtime.heap_allocator()
	doc, fault := jq.build_text(src, ins.as, heap)
	if f, bad := fault.?; bad {
		tell_fault(ins, f)
		return EXIT_INPUT
	}
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc, heap)
	defer core.edit_list_destroy(&list)
	w := edit_state(er, &doc, &list)
	n := core.length(&doc, core.ROOT)
	recs := make([]core.Node_Index, n, context.temp_allocator)
	lines_at := make([]int, n, context.temp_allocator)
	lines: core.Lines
	it := core.children(&doc, core.ROOT)
	for i in 0 ..< n {
		recs[i], _ = core.child_next(&it)
		line, _ := core.locate(src, core.node_start(doc.nodes[recs[i]]), &lines)
		lines_at[i] = int(line)
	}
	names, named := edit_header(&w)
	if !named {
		message.write_stderr("stury: error: %s: %s\n", w.name, w.err)
		return EXIT_INPUT
	}
	placed := make([dynamic]Edit_Placed, context.temp_allocator)
	if er.run.opts.slurp {
		sources := make([]jq.Value, n, context.temp_allocator)
		for rec, i in recs {
			sources[i] = jq.Ref{&doc, rec}
		}
		ins.line = 1
		items, outs, ok := edit_slurped(er, &w, jq.scalar(jq.Ref{&doc, core.ROOT}))
		if !ok {
			return EXIT_INPUT
		}
		// The table's own comments are the ones an output array writes, above the header and after the last record.
		for v in outs {
			for role in core.COMMENT_ROLES {
				if bodies, from := jq.comments(v, role); from == .Written && !edit_role(&w, core.ROOT, role, bodies) {
					message.write_stderr("stury: error: %s: %s\n", w.name, w.err)
					return EXIT_INPUT
				}
			}
		}
		claims := make([]int, len(items), context.temp_allocator)
		for v, j in items {
			claims[j] = -1
			if r, is_ref := v.(jq.Ref); is_ref && r.doc == &doc {
				if i, found := slice.binary_search(recs, r.node); found {
					claims[j] = i
				}
			}
		}
		for i, j in match_items(sources, items, claims) {
			append(&placed, Edit_Placed{i, items[j], lines_at[i] if i >= 0 else 0})
		}
	} else {
		r := Edit_Row_Reader{ins, &doc, recs, lines_at, 0}
		er.run.ip.inputs = {data = &r, next = edit_row_input, position = edit_reader_position}
		defer er.run.ip.inputs = {data = ins, next = edit_no_input, position = edit_position}
		for r.next < n {
			i := r.next
			r.next += 1
			ins.line = lines_at[i]
			outs, ok := edit_outputs(er, jq.scalar(jq.Ref{&doc, recs[i]}))
			if !ok {
				return EXIT_INPUT
			}
			for v, k in outs {
				append(&placed, Edit_Placed{i if k == 0 else -1, v, lines_at[i]})
			}
		}
	}
	used := make([]bool, n, context.temp_allocator)
	for &p in placed {
		w.line = p.line
		value, ok := edit_row_value(&w, p.value, names)
		if ok && p.rec >= 0 {
			used[p.rec] = true
			ok = edit_tree(&w, recs[p.rec], value)
		}
		if !ok {
			message.write_stderr("stury: error: %s: %s\n", edit_place(&w), w.err)
			return EXIT_INPUT
		}
		p.value = value
	}
	#reverse for rec, i in recs {
		if !used[i] {
			if e := core.remove(&list, rec); e != nil {
				message.write_stderr("stury: error: %s: %s\n", w.name, edit_error_text(src, e))
				return EXIT_INPUT
			}
		}
	}
	w.line = 0
	text, owned, ok := edit_commit(&w, src, src, 0)
	if !ok {
		return EXIT_INPUT
	}
	defer if owned {
		delete(text, heap)
	}
	if !edit_table_moves(&w, placed[:], names) {
		return edit_publish(er.run, path, src, text)
	}
	out, placed_ok := edit_table_place(er, &w, text, placed[:])
	if !placed_ok {
		return EXIT_INPUT
	}
	defer delete(out, heap)
	if !new_comments(placed[:]) {
		return edit_publish(er.run, path, src, out)
	}
	commented, commented_ok := edit_table_comments(er, out, placed[:])
	if !commented_ok {
		return EXIT_INPUT
	}
	defer delete(commented, heap)
	return edit_publish(er.run, path, src, commented)
}

// Whether a new record's output carries a comment.
@(private = "file")
new_comments :: proc(placed: []Edit_Placed) -> bool {
	for p in placed {
		if p.rec >= 0 {
			continue
		}
		for role in core.COMMENT_ROLES {
			if bodies, _ := jq.comments(p.value, role); len(bodies) > 0 {
				return true
			}
		}
	}
	return false
}

// The third commit, over `text`, whose records are the outputs `placed` in order: each new record's comments.
@(private = "file")
edit_table_comments :: proc(er: ^Edit_Run, text: []u8, placed: []Edit_Placed) -> (out: []u8, ok: bool) {
	heap := runtime.heap_allocator()
	doc, fault := jq.build_text(text, er.ins.as, heap)
	if f, bad := fault.?; bad {
		tell_fault(er.ins, f)
		return nil, false
	}
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc, heap)
	defer core.edit_list_destroy(&list)
	w := edit_state(er, &doc, &list)
	it := core.children(&doc, core.ROOT)
	for p in placed {
		rec := core.child_next(&it) or_break
		if p.rec < 0 {
			w.line = p.line
			if !edit_comment_tree(&w, rec, p.value) {
				message.write_stderr("stury: error: %s: %s\n", edit_place(&w), w.err)
				return nil, false
			}
		}
	}
	w.line = 0
	owned: bool
	out, owned = edit_commit(&w, text, text, 0) or_return
	if !owned {
		out = slice.clone(out, heap)
	}
	return out, true
}

// Feeds `input` the table's records after the one being edited. A record it reads is consumed: it writes no record of
// its own.
@(private = "file")
Edit_Row_Reader :: struct {
	ins:      ^Inputs,
	doc:      ^core.Document,
	recs:     []core.Node_Index,
	lines_at: []int,
	next:     int,
}

@(private = "file")
edit_row_input :: proc(data: rawptr) -> (jq.Value, string, jq.Parse_Status) {
	r := (^Edit_Row_Reader)(data)
	if r.next >= len(r.recs) {
		return nil, "", .More
	}
	r.ins.line = r.lines_at[r.next]
	r.next += 1
	return jq.scalar(jq.Ref{r.doc, r.recs[r.next - 1]}), "", .Value
}

// The header's decoded names, or nil for a table without one.
@(private = "file")
edit_header :: proc(w: ^Edit_State) -> (names: []string, ok: bool) {
	keys := core.header_of(w.doc)
	if keys == 0 {
		return nil, true
	}
	names = make([]string, core.length(w.doc, keys), context.temp_allocator)
	it := core.children(w.doc, keys)
	for &name in names {
		cell, _ := core.child_next(&it)
		name = edit_key_text(w, cell) or_return
	}
	return names, true
}

// A record's output as the record's own kind: a headed record is an object, which an array or a scalar fills by
// column, and a headerless one an array, which an object fills with its values in key order. The record keeps the
// comments the filter wrote on the output.
@(private = "file")
edit_row_value :: proc(w: ^Edit_State, v: jq.Value, names: []string) -> (jq.Value, bool) {
	k := jq.kind(v)
	headed := core.header_of(w.doc) != 0
	if headed && k == .Object || !headed && k == .Array {
		return v, true
	}
	cells := make([dynamic]jq.Value, context.temp_allocator)
	switch k {
	case .Object, .Array:
		it := jq.iterate(v)
		for _, m in jq.next_member(&it) {
			append(&cells, m)
		}
	case .Null, .False, .True, .Number, .String:
		append(&cells, v)
	}
	if !headed {
		a := jq.new_array(len(cells))
		append(&a.items, ..cells[:])
		return with_comments(v, a), true
	}
	if len(cells) > len(names) {
		w.err = message.build_temp("the output fills %d cells, and the header names %d columns", len(cells), len(names))
		return nil, false
	}
	obj := jq.new_object()
	for c, i in cells {
		jq.object_put(obj, names[i], c)
	}
	return with_comments(v, obj), true
}

// `record`, with the comments the filter wrote on `v`.
@(private = "file")
with_comments :: proc(v, record: jq.Value) -> jq.Value {
	if c, is_commented := v.(^jq.Commented); is_commented {
		return jq.rewrap(c, record)
	}
	return record
}

// Whether the outputs need the second commit: a new record, records out of their order, or a headed table's columns
// in another order, which a key the header lacks before a key it has, a member order unlike the header's, or `-S`
// over an unsorted header asks for.
@(private = "file")
edit_table_moves :: proc(w: ^Edit_State, placed: []Edit_Placed, names: []string) -> bool {
	last := -1
	for p in placed {
		if p.rec < last {
			return true
		}
		last = p.rec if p.rec >= 0 else last
		if p.rec < 0 {
			return true
		}
	}
	if names == nil {
		return false
	}
	if w.sorted && !slice.is_sorted(names) {
		return true
	}
	for p in placed {
		at, fresh := -1, false
		for key in edit_keys(p.value) {
			i := -1
			#reverse for name, k in names {
				if name == key {
					i = k
					break
				}
			}
			switch {
			case i < 0:
				fresh = true
			case fresh, i < at:
				return true
			case:
				at = i
			}
		}
		if w.sorted && fresh {
			return true
		}
	}
	return false
}

// The second commit, over `text`: the columns in the outputs' key order and the records in the outputs' order, a new
// one written in the final columns.
@(private = "file")
edit_table_place :: proc(er: ^Edit_Run, w0: ^Edit_State, text: []u8, placed: []Edit_Placed) -> (out: []u8, ok: bool) {
	heap := runtime.heap_allocator()
	doc, fault := jq.build_text(text, er.ins.as, heap)
	if f, bad := fault.?; bad {
		tell_fault(er.ins, f)
		return nil, false
	}
	defer core.destroy(&doc)
	names: []string
	perm: []u32
	padded: []u8
	defer delete(padded, heap)
	for {
		probe := edit_state(er, &doc, nil)
		names = edit_header(&probe) or_return
		perm = edit_column_order(w0, placed, names)
		if perm == nil || padded != nil {
			break
		}
		// A row shorter than the header moves with every column, so it gets its missing cells, empty, first.
		short := core.edit_list_init(&doc, heap)
		defer core.edit_list_destroy(&short)
		it := core.children(&doc, core.ROOT)
		for row in core.child_next(&it) {
			for k := core.length(&doc, row); k < len(names); k += 1 {
				core.insert(&short, row, core.length(&doc, row), "")
			}
		}
		if len(short.edits) == 0 {
			break
		}
		pw := edit_state(er, &doc, &short)
		padded, _ = edit_commit(&pw, text, text, 0) or_return
		core.destroy(&doc)
		doc, fault = jq.build_text(padded, er.ins.as, heap)
		if f, bad := fault.?; bad {
			tell_fault(er.ins, f)
			return nil, false
		}
	}
	list := core.edit_list_init(&doc, heap)
	defer core.edit_list_destroy(&list)
	w := edit_state(er, &doc, &list)
	final := names
	if perm != nil {
		final = make([]string, len(names), context.temp_allocator)
		for p, i in perm {
			final[i] = names[p]
		}
		edit_reorder(&w, core.header_of(&doc), perm) or_return
		it := core.children(&doc, core.ROOT)
		for row in core.child_next(&it) {
			edit_reorder(&w, row, perm) or_return
		}
	}
	return edit_table_records(w0, &w, placed, final)
}

// Records the second commit's records and commits it: each kept record in its output place, and each new one written
// in the `final` columns.
@(private = "file")
edit_table_records :: proc(w0, w: ^Edit_State, placed: []Edit_Placed, final: []string) -> (out: []u8, ok: bool) {
	// The first commit left the kept records in their source order.
	kept := make([dynamic]int, 0, len(placed), context.temp_allocator)
	for p in placed {
		if p.rec >= 0 {
			append(&kept, p.rec)
		}
	}
	slice.sort(kept[:])
	entries := make([]int, len(placed), context.temp_allocator)
	news := make([dynamic]string, context.temp_allocator)
	monotone := true
	last := -1
	for p, j in placed {
		if p.rec >= 0 {
			entries[j], _ = slice.binary_search(kept[:], p.rec)
			monotone = monotone && entries[j] > last
			last = entries[j]
			continue
		}
		w0.line = p.line
		text, written := edit_row_text(w0, p.value, final)
		if !written {
			message.write_stderr("stury: error: %s: %s\n", edit_place(w0), w0.err)
			return nil, false
		}
		append(&news, text)
		entries[j] = -1 - (len(news) - 1)
	}
	length := len(kept)
	if monotone {
		last = -1
		for e in entries {
			if e >= 0 {
				last = e
			} else if !edit_record_insert(w, last + 1, news[-1 - e]) {
				return nil, false
			}
		}
	} else {
		order := make([]u32, len(entries), context.temp_allocator)
		for e, i in entries {
			order[i] = u32(e) if e >= 0 else u32(length + (-1 - e))
		}
		for t in news {
			edit_record_insert(w, length, t) or_return
		}
		edit_reorder(w, core.ROOT, order) or_return
	}
	owned: bool
	out, owned = edit_commit(w, w.doc.src, w.doc.src, 0) or_return
	if !owned {
		out = slice.clone(out, runtime.heap_allocator())
	}
	return out, true
}

@(private = "file")
edit_record_insert :: proc(w: ^Edit_State, at: int, text: string) -> bool {
	if e := core.insert(w.list, core.ROOT, at, text); e != nil {
		message.write_stderr("stury: error: %s: %s\n", w.name, edit_error_text(w.doc.src, e))
		return false
	}
	return true
}

// A new record's line: its cells in the `final` columns, or in its own order for a table without a header, each
// spelled as an edit spells a cell, a cell taken from the table keeping its bytes.
@(private = "file")
edit_row_text :: proc(w: ^Edit_State, v: jq.Value, final: []string) -> (text: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	delimiter := w.doc.as.opts[0]
	at := u64(len(w.doc.src))
	if jq.kind(v) == .Object && final != nil {
		for name, i in final {
			if i > 0 {
				strings.write_byte(&b, delimiter)
			}
			cell, _ := jq.object_get(v, name)
			strings.write_string(&b, edit_text_of(w, cell, at) or_return)
		}
		return strings.to_string(b), true
	}
	it := jq.iterate(v)
	i := 0
	for _, cell in jq.next_member(&it) {
		if i > 0 {
			strings.write_byte(&b, delimiter)
		}
		strings.write_string(&b, edit_text_of(w, cell, at) or_return)
		i += 1
	}
	return strings.to_string(b), true
}

// An object output's keys in its order, none for another value.
@(private = "file")
edit_keys :: proc(v: jq.Value) -> []string {
	if jq.kind(v) != .Object {
		return nil
	}
	keys := make([dynamic]string, context.temp_allocator)
	it := jq.iterate(v)
	for key in jq.next_member(&it) {
		append(&keys, key)
	}
	return keys[:]
}

@(private = "file")
edit_reorder :: proc(w: ^Edit_State, node: core.Node_Index, perm: []u32) -> bool {
	if e := core.reorder(w.list, node, perm); e != nil {
		message.write_stderr("stury: error: %s: %s\n", w.name, edit_error_text(w.doc.src, e))
		return false
	}
	return true
}

// The header's columns in the outputs' key order: the order of the first output to name each key, sorted under `-S`,
// and the columns no output names after them. Nil when that is the header's own order.
@(private = "file")
edit_column_order :: proc(w: ^Edit_State, placed: []Edit_Placed, names: []string) -> []u32 {
	if names == nil {
		return nil
	}
	keys := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, len(names), context.temp_allocator)
	for p in placed {
		for key in edit_keys(p.value) {
			if key not_in seen {
				seen[key] = true
				append(&keys, key)
			}
		}
	}
	if w.sorted {
		slice.sort(keys[:])
	}
	perm := make([dynamic]u32, 0, len(names), context.temp_allocator)
	taken := make([]bool, len(names), context.temp_allocator)
	for key in keys {
		for name, i in names {
			if name == key && !taken[i] {
				taken[i] = true
				append(&perm, u32(i))
			}
		}
	}
	for t, i in taken {
		if !t {
			append(&perm, u32(i))
		}
	}
	for p, i in perm {
		if int(p) != i {
			return perm[:]
		}
	}
	return nil
}
