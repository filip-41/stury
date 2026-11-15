package dsv

// The write of a document as a delimited text. A dsv document with a header is written in the spec and layout it was
// read in, its header the shared keys, sorted under `sort_keys`. Any other document is written as the rows of a record
// writer's table, see `records.write_object`: a list's elements, an object as one row and a scalar as one cell, null an
// empty cell and a number its source spelling, or JSON's where JSON does not spell it so. With a comment byte in the
// output's options, which a write without a handle takes from the read, a comment on the list is written above the
// header when a record follows it, one on a record above the record, and the list's foot below the last record, each a
// comment line, as an edit writes them. A comment the output has no place or no comment byte for, and one whose body
// holds a control byte a line cannot hold, is dropped and counted, as is the earlier value of a key its object repeats.

import "base:runtime"
import "core:io"
import "core:slice"
import "core:strings"
import core "../core"
import typed "../core/typed"
import write "../core/write"
import records "../core/records"

// Writes `value`, a list of rows, as `spec` says, with the delimiter, comment byte, `no_header` and `crlf` of `opts`, and
// as `write` says. The form with no plan builds one for its type, and a plan made by `plan_make`, which holds the spec
// and options, is the form for many writes.
marshal :: proc {marshal_once, write.marshal}

@(private)
marshal_once :: proc(value: any, spec := Spec.Csv, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	nothing: any
	v := typed.marshal_target(value, &nothing)
	plan, refusal := plan_make(v.id, spec, opts)
	return typed.marshal_planned(&plan, refusal, v.data, write, allocator)
}

// A cell is written as it stands, so the writer takes no layout or escape option.
CAPABILITIES :: core.Capabilities {
	writes = {.Sort_Keys},
	framings = {.Lines},
	specs = Spec,
}

// The handle of a delimited text of `spec` read or written with `opts`, which holds the delimiter `spec` reads when
// `opts` leaves it 0. See the file's header for what a document may hold.
as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return as_of(&HANDLES[spec] if spec <= max(Spec) else nil, spec, opts)
}

// The handle of `spec` read or written with `opts` over `readers`.
@(private)
as_of :: proc "contextless" (readers: ^core.Readers, spec: Spec, opts: Options) -> core.As {
	bytes := [10]u8{0 = spec_delimiter(spec, opts.delimiter), 1 = opts.comment, 2 = u8(opts.no_header), 3 = u8(opts.crlf), 4 = u8(opts.infer)}
	return {readers = readers, spec = u8(spec), tolerate = opts.tolerate, opts = bytes}
}

// The options a handle `as` made holds. The spec's own delimiter reads as 0, so a default handle's options are `{}`,
// which the walk's passes fold.
@(private)
options_of :: #force_inline proc "contextless" (as: core.As) -> Options {
	return {delimiter = 0 if as.opts[0] == spec_delimiter(Spec(as.spec), 0) else as.opts[0], comment = as.opts[1], no_header = as.opts[2] != 0, crlf = as.opts[3] != 0, infer = as.opts[4] != 0, tolerate = as.tolerate}
}

// The spelling's `write`: `doc` as the handle `as` says.
@(private)
document_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, kept: int, err: core.Typed_Refusal) {
	spec, layout := Spec(as.spec), options_of(as)
	if !layout_ok(spec, layout) {
		return nil, 0, {kind = .Bad_Option}
	}
	if doc.partial || core.header_of(doc) == 0 || doc.nodes[node].kind != .Array {
		return table_write(doc, opts, as, node, stream, allocator)
	}
	spill: [write.ROOM_MAX]u8 = ---
	w: Rows
	hint := len(doc.src) + write.ROOM_MAX if doc.readers.format == rules_of else 0
	rows_start(&w, &spill, layout, spec, opts, stream, allocator, hint)
	written := write_records(&w, doc, node, true) if layout.infer else write_records(&w, doc, node, false)
	text, err = rows_end((^Rows)(rawptr(&w)), written)
	if err.kind != .None {
		return nil, 0, err
	}
	return text, w.kept, err
}

// `doc` written as the rows of a record writer's table, see `records.write_object`.
@(private)
table_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, kept: int, err: core.Typed_Refusal) {
	wr: records.Writer
	if kind := records.writer_init(&wr, stream, as, .Lines, opts, allocator); kind != .None {
		return nil, 0, {kind = kind}
	}
	if records.write_rows(&wr, core.Node_Ref{doc, node}) != .None || records.table_end(&wr) != .None {
		err = wr.err
		records.writer_destroy(&wr)
		return nil, 0, err
	}
	kept = wr.table.kept - wr.table.dropped
	failed: core.Error
	if text, failed = records.writer_end(&wr); failed != nil {
		return nil, 0, {kind = .No_Memory}
	}
	return text, kept, {}
}

// The header, the document's shared keys, then each record of the array at `list`. `INFER` is the output's `infer`, a
// constant so the cell loops test it once. Inlined into `document_write`, so the output's cursor and buffer stay in
// registers across the cell loop.
@(private)
write_records :: #force_inline proc(w: ^Rows, doc: ^core.Document, list: core.Node_Index, $INFER: bool) -> core.Typed_Error_Kind {
	scratch := runtime.arena_allocator(&w.arena)
	header := make([dynamic]string, scratch)
	buf: [512]u8
	it := core.children(doc, core.header_of(doc))
	for key, more := core.child_next(&it); more; key, more = core.child_next(&it) {
		name, whole := core.text_clone(doc, key, scratch)
		if _, failed := append(&header, name); !whole || failed != nil {
			return .No_Memory
		}
	}
	// The column each of the shared keys moves to under `sort_keys`.
	slot: []int
	moved: []core.Node_Index
	if w.sort {
		slot, moved = sort_header(header[:], scratch) or_return
	}
	// Comments are written only when the output has a comment byte and the list holds one.
	commented := w.opts.comment != 0 && len(core.subtree_facts(doc, list)) > 0
	if !w.opts.no_header {
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
	records := core.children(doc, list)
	i := 0
	for rec, more := core.child_next(&records); more; rec, more = core.child_next(&records) {
		if commented {
			put_comments(w, doc, rec, .Comment) or_return
		}
		start := total(w)
		if !w.sort {
			// A record's values are in its header's order, and a column past its last is an empty cell.
			values := core.children(doc, rec)
			for k in 0 ..< len(header) {
				node, _ := core.child_next(&values)
				put_sep(w, k > 0)
				if kind := put_cell(w, doc, node, buf[:], k == 0, INFER); kind != .None {
					return refuse_in(w, kind, i, core.Index(k))
				}
			}
		} else {
			values := core.children(doc, rec)
			for &c in cells {
				c, _ = core.child_next(&values)
			}
			sort_cells(cells, moved, slot)
			for node, k in cells {
				put_sep(w, k > 0)
				if kind := put_cell(w, doc, node, buf[:], k == 0, INFER); kind != .None {
					return refuse_in(w, kind, i, core.Index(k))
				}
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

// Writes each of node `node`'s comments of `role` as comment lines, one for each line of its body, and counts it
// written. A body with a control byte a line cannot hold is left out.
@(private)
put_comments :: proc(w: ^Rows, doc: ^core.Document, node: core.Node_Index, role: core.Role) -> core.Typed_Error_Kind {
	it := core.facts_of(doc, node, role)
	for text, padded in core.comment_next(&it) {
		if !write.comment_lines_ok(text) {
			continue
		}
		w.kept += 1
		// An empty body is one empty line.
		rest := text if len(text) > 0 else "\n"
		for line in strings.split_lines_iterator(&rest) {
			write.put_byte(&w.out, w.opts.comment)
			write.put_text(&w.out, " " if padded && len(line) > 0 else "")
			write.put_text(&w.out, line)
			end_line(w) or_return
		}
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
	case .Bytes:
		stack: [512]u8
		text, ok := write.node_bytes_text(doc, node, stack[:])
		return put_string(w, text, first, false) if ok else .No_Memory
	case .Number:
		if doc.readers.number_text == nil && doc.nodes[node].spelling & core.NUMBER_KIND_MASK == 0 {
			return put_string(w, string(core.span(doc, node)), first, false)
		}
		return put_respelled(w, doc, node, first)
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

// A number its format spells in a way JSON does not, as JSON spells it, so a read that infers numbers reads it back. An
// infinity or a NaN that a format resolves from a word is an empty cell.
@(cold, private)
put_respelled :: proc(w: ^Rows, doc: ^core.Document, node: core.Node_Index, first: bool) -> core.Typed_Error_Kind {
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, runtime.arena_allocator(&w.arena))
	kind := write.put_number_node(&out, doc, node, write.MARKUP_TREE)
	text, err := write.finish(&out, {kind = .None if kind == .Non_Finite && doc.readers.number_text != nil else kind})
	if err.kind != .None {
		return err.kind
	}
	return put_string(w, string(text), first, false)
}

// The text of a key or a cell: in `buf` when it fits, else in a copy that lasts the call.
@(private)
node_text :: proc(w: ^Rows, doc: ^core.Document, node: core.Node_Index, buf: []u8) -> (string, core.Typed_Error_Kind) {
	return write.node_text(doc, node, buf, runtime.arena_allocator(&w.arena))
}
