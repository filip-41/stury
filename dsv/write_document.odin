package dsv

// The write of a document: a list of records as a delimited text. A dsv document is written in the spec and layout it was
// read in. A document of another format whose root is a list of records is written through its `text` and spans: its
// objects give a header of their keys in first-seen order, its arrays no header. `sort_keys` puts the columns of a
// header in byte order of their names. A cell that is a container is
// `.Unsupported`, null is an empty cell, and a number is its source spelling, or JSON's where JSON does not spell it so.
// With a comment byte in the output's options, which a write without a handle takes from the read, a comment on the list
// is written above the header when a record follows it, one on a record above the record, and the list's foot below the
// last record, each a comment line, as an edit writes them. A comment the output has no place or no comment byte for,
// and one whose body holds a line end, is dropped and counted, as is the earlier value of a key its object repeats.

import "base:runtime"
import "core:io"
import "core:slice"
import "core:strings"
import core "../core"
import typed "../core/typed"
import write "../core/write"

// Writes `value`, a list of rows, as `spec` says, with the delimiter, comment byte, `no_header` and `crlf` of `opts`, and
// as `write` says. The form with no plan builds one for its type, and a plan made by `plan_make`, which holds the spec
// and options, is the form for many writes.
marshal :: proc {marshal_once, write.marshal}

@(private)
marshal_once :: proc(value: any, spec := Spec.Csv, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Typed_Error) {
	if value.id == nil || value.data == nil {
		return nil, {kind = .Plan_Mismatch}
	}
	plan, err := plan_make(value.id, spec, opts)
	if err.kind != .None {
		return nil, err
	}
	defer typed.plan_destroy(&plan)
	return plan.marshal(&plan, value.data, write, {}, allocator)
}

// The handle of a delimited text of `spec` read or written with `opts`, which holds the delimiter `spec` reads when
// `opts` leaves it 0. See the file's header for what a document may hold.
as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	bytes := [10]u8{0 = spec_delimiter(spec, opts.delimiter), 1 = opts.comment, 2 = u8(opts.no_header), 3 = u8(opts.crlf), 4 = u8(opts.infer)}
	return {spelling = &SPELLING, spec = u8(spec), tolerate = opts.tolerate, opts = bytes}
}

// The options a handle `as` made holds. The spec's own delimiter reads as 0, so a default handle's options are `{}`,
// which the walk's passes fold.
@(private)
options_of :: #force_inline proc "contextless" (as: core.As) -> Options {
	return {delimiter = 0 if as.opts[0] == spec_delimiter(Spec(as.spec), 0) else as.opts[0], comment = as.opts[1], no_header = as.opts[2] != 0, crlf = as.opts[3] != 0, infer = as.opts[4] != 0, tolerate = as.tolerate}
}

// The spelling's `write`: `doc` as the handle `as` says.
@(private)
document_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, dropped: int, err: core.Typed_Error) {
	spec, layout := Spec(as.spec), options_of(as)
	if !layout_ok(spec, layout) {
		return nil, 0, {kind = .Bad_Option}
	}
	if doc.partial || doc.nodes[node].kind != .Array {
		return nil, 0, {kind = .Unsupported}
	}
	spill: [write.ROOM_MAX]u8 = ---
	w: Rows
	hint := len(doc.src) + write.ROOM_MAX if doc.spelling == &SPELLING else 0
	rows_start(&w, &spill, layout, spec, opts, stream, allocator, hint)
	written := write_records(&w, doc, node, true) if layout.infer else write_records(&w, doc, node, false)
	text, err = rows_end((^Rows)(rawptr(&w)), written)
	if err.kind != .None {
		return nil, 0, err
	}
	return text, len(core.subtree_facts(doc, node)) - w.kept + w.dropped, err
}

// The header, then each record of the array at `list`. The header is the document's shared keys, else the keys of its
// objects, each once. `INFER` is the output's `infer`, a constant so the cell loops test it once. Inlined into
// `document_write`, so the output's cursor and buffer stay in registers across the cell loop.
@(private)
write_records :: #force_inline proc(w: ^Rows, doc: ^core.Document, list: core.Node_Index, $INFER: bool) -> core.Typed_Error_Kind {
	scratch := runtime.arena_allocator(&w.arena)
	header := make([dynamic]string, scratch)
	column := make(map[string]int, scratch)
	buf: [512]u8
	keyed := doc.shared_keys != 0
	if keyed {
		it := core.children(doc, doc.shared_keys)
		for key, more := core.child_next(&it); more; key, more = core.child_next(&it) {
			name, whole := core.text_clone(doc, key, scratch)
			if _, failed := append(&header, name); !whole || failed != nil {
				return .No_Memory
			}
		}
	}
	maps, arrays := 0, 0
	records := core.children(doc, list)
	for rec, more := core.child_next(&records); more; rec, more = core.child_next(&records) {
		#partial switch doc.nodes[rec].kind {
		case .Object:
			maps += 1
			if !keyed {
				pairs := core.pairs(doc, rec)
				for key, _, ok := core.pair_next(&pairs); ok; key, _, ok = core.pair_next(&pairs) {
					name, whole := core.text_clone(doc, key, scratch)
					_, at, fresh, failed := map_entry(&column, name)
					if !whole || failed != nil {
						return .No_Memory
					}
					if fresh {
						at^ = len(header)
						if _, no_name := append(&header, name); no_name != nil {
							return .No_Memory
						}
					}
				}
			}
		case .Array:
			arrays += 1
		case:
			return .Unsupported
		}
	}
	if maps > 0 && arrays > 0 {
		return .Unsupported
	}
	// The column each of the shared keys moves to under `sort_keys`. An object's keys find theirs by name.
	slot: []int
	moved: []core.Node_Index
	if w.sort {
		slot, moved = sort_header(header[:], scratch) or_return
		for name, k in header {
			column[name] = k
		}
	}
	// Comments are written only when the output has a comment byte and the list holds one.
	commented := w.opts.comment != 0 && len(core.subtree_facts(doc, list)) > 0
	if (maps > 0 || keyed) && !w.opts.no_header {
		// Above a header, a comment reads as the list's only when a record follows the header.
		if commented && core.length(doc, list) > 0 {
			put_comments(w, doc, list, .Comment) or_return
		}
		put_header(w, header[:]) or_return
	}
	cells, no_cells := make([]core.Node_Index, len(header), scratch)
	if no_cells != nil {
		return .No_Memory
	}
	records = core.children(doc, list)
	i := 0
	for rec, more := core.child_next(&records); more; rec, more = core.child_next(&records) {
		if commented {
			put_comments(w, doc, rec, .Comment) or_return
		}
		start := total(w)
		if keyed && !w.sort {
			// A record's values are in its header's order, and a column past its last is an empty cell.
			values := core.children(doc, rec)
			for k in 0 ..< len(header) {
				node, _ := core.child_next(&values)
				put_sep(w, k > 0)
				if kind := put_cell(w, doc, node, buf[:], k == 0, INFER); kind != .None {
					return refuse_in(w, kind, i, core.Index(k))
				}
			}
		} else if maps > 0 {
			for &c in cells {
				c = core.NO_NODE
			}
			if keyed {
				values := core.children(doc, rec)
				for &c in cells {
					c, _ = core.child_next(&values)
				}
				sort_cells(cells, moved, slot)
			} else {
				pairs := core.pairs(doc, rec)
				for key, value, ok := core.pair_next(&pairs); ok; key, value, ok = core.pair_next(&pairs) {
					at := column[node_text(w, doc, key, buf[:]) or_return]
					if cells[at] != core.NO_NODE {
						w.dropped += 1
					}
					cells[at] = value
				}
			}
			for node, k in cells {
				put_sep(w, k > 0)
				if kind := put_cell(w, doc, node, buf[:], k == 0, INFER); kind != .None {
					return refuse_in(w, kind, i, core.Index(k))
				}
			}
		} else {
			values := core.children(doc, rec)
			k := 0
			for node, more_cells := core.child_next(&values); more_cells; node, more_cells = core.child_next(&values) {
				put_sep(w, k > 0)
				if kind := put_cell(w, doc, node, buf[:], k == 0, INFER); kind != .None {
					return refuse_in(w, kind, i, core.Index(k))
				}
				k += 1
			}
		}
		end_record(w, start, i) or_return
		i += 1
	}
	if commented {
		put_comments(w, doc, list, .Comment_Foot) or_return
	}
	return .None
}

// Writes each of node `node`'s comments of `role` whose body holds no line end as a comment line, and counts it written.
@(private)
put_comments :: proc(w: ^Rows, doc: ^core.Document, node: core.Node_Index, role: core.Role) -> core.Typed_Error_Kind {
	it := core.facts_of(doc, node, role)
	for body in core.fact_next(&it) {
		if strings.index_any(body, "\r\n") >= 0 {
			continue
		}
		w.kept += 1
		write.put_byte(&w.out, w.opts.comment)
		write.put_text(&w.out, body)
		end_line(w) or_return
	}
	return .None
}

// Moves each of `cells`, in the order of the source's columns, to the column `slot` names, through `moved`.
@(private)
sort_cells :: #force_no_inline proc(cells, moved: []core.Node_Index, slot: []int) {
	for c, k in cells {
		moved[slot[k]] = c
	}
	copy(cells, moved)
}

// Sorts `header` by name, stable, so a repeated name keeps its order. Returns the place each name moved to, and the
// cells `sort_cells` moves a record's through.
@(private)
sort_header :: proc(header: []string, allocator: runtime.Allocator) -> ([]int, []core.Node_Index, core.Typed_Error_Kind) {
	Column :: struct {
		name: string,
		at:   int,
	}
	cols, no_cols := make([]Column, len(header), allocator)
	slot, no_slot := make([]int, len(header), allocator)
	moved, no_moved := make([]core.Node_Index, len(header), allocator)
	if no_cols != nil || no_slot != nil || no_moved != nil {
		return nil, nil, .No_Memory
	}
	for name, k in header {
		cols[k] = {name, k}
	}
	slice.stable_sort_by(cols, proc(a, b: Column) -> bool {return a.name < b.name})
	for c, k in cols {
		header[k], slot[c.at] = c.name, k
	}
	return slot, moved, .None
}

@(private)
put_node :: proc(w: ^Rows, doc: ^core.Document, node: core.Node_Index, buf: []u8, first: bool) -> core.Typed_Error_Kind {
	// The stored kind, not `core.kind`'s: a cell is written as its text, which spells the kind it reads as. `NO_NODE`,
	// past the last node, is an absent cell.
	k := doc.nodes[node].kind if int(node) < len(doc.nodes) else core.Kind.Null
	#partial switch k {
	case .Null:
		return .None
	case .True:
		return put_word(w, true, first)
	case .False:
		return put_word(w, false, first)
	case .Number:
		if t := doc.nodes[node]; t.kind == .Number && t.spelling & core.NUMBER_KIND_MASK != 0 {
			return put_respelled(w, string(core.span(doc, node)), t.spelling, first)
		}
		return put_string(w, string(core.span(doc, node)), first, false)
	case .String, .Plain:
		// A dsv cell with no bytes at all is absent, where a quoted empty one is an empty string.
		if len(core.span(doc, node)) == 0 {
			return .None
		}
		text := node_text(w, doc, node, buf) or_return
		return put_string(w, text, first, false)
	}
	return .Unsupported
}

// Writes the cell `node`, guarded when the output infers.
@(private = "file")
put_cell :: #force_inline proc(w: ^Rows, doc: ^core.Document, node: core.Node_Index, buf: []u8, first: bool, $INFER: bool) -> core.Typed_Error_Kind {
	when INFER {
		return put_inferred_node(w, doc, node, buf, first)
	} else {
		return put_node(w, doc, node, buf, first)
	}
}

// A cell of a text read back with `infer`. One the document reads as a string is guarded, and one it infers is written
// as its text.
@(cold, private = "file")
put_inferred_node :: proc(w: ^Rows, doc: ^core.Document, node: core.Node_Index, buf: []u8, first: bool) -> core.Typed_Error_Kind {
	if int(node) >= len(doc.nodes) || core.kind(doc, node) != .String || len(core.span(doc, node)) == 0 {
		return put_node(w, doc, node, buf, first)
	}
	text := node_text(w, doc, node, buf) or_return
	return put_inferred_string(w, text, first)
}

// A number its format spells in a way JSON does not, as JSON spells it, so a read that infers numbers reads it back.
@(cold, private)
put_respelled :: proc(w: ^Rows, lit: string, spelling: u16, first: bool) -> core.Typed_Error_Kind {
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, runtime.arena_allocator(&w.arena))
	text, err := write.finish(&out, {kind = write.put_decimal(&out, lit, spelling)})
	if err.kind != .None {
		return err.kind
	}
	return put_string(w, string(text), first, false)
}

// The text of a key or a cell: in `buf` when it fits, else in a copy that lasts the call.
@(private)
node_text :: proc(w: ^Rows, doc: ^core.Document, node: core.Node_Index, buf: []u8) -> (string, core.Typed_Error_Kind) {
	if s, ok := core.text(doc, node, buf); ok {
		return s, .None
	}
	s, ok := core.text_clone(doc, node, runtime.arena_allocator(&w.arena))
	return s, .None if ok else .No_Memory
}
