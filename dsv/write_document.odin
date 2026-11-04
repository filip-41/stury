package dsv

// The write of a document: a list of records as a delimited text. A dsv document is written in the spec and layout it was
// read in. A document of another format whose root is a list of records is written through its `text` and spans: its
// objects give a header of their keys in first-seen order, its arrays no header. A cell that is a container is
// `.Unsupported`, null is an empty cell, and a number is its source spelling. A comment the document holds is dropped and
// counted, as is the earlier value of a key its object repeats.

import "base:runtime"
import "core:io"
import core "../core"
import typed "../core/typed"
import write "../core/write"

// Writes `value`, a list of rows, as `spec` says, with the delimiter, comment byte, `no_header` and `crlf` of `layout`. A
// call with no plan builds one for its type. A plan made by `plan_make` is the form for many writes, and `write.marshal`
// takes it.
marshal :: proc(value: any, spec := Spec.Csv, layout := Options{}, opts := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Typed_Error) {
	if value.id == nil {
		return nil, {kind = .Plan_Mismatch}
	}
	plan, err := plan_make(value.id, spec, layout)
	if err.kind != .None {
		return nil, err
	}
	defer typed.plan_destroy(&plan)
	return write.marshal(value, &plan, opts, allocator)
}

// The handle of a delimited text of `spec` read or written with `layout`, which holds the delimiter `spec` reads when
// `layout` leaves it 0. See the file's header for what a document may hold.
as :: proc "contextless" (spec: Spec, layout := Options{}) -> core.As {
	opts := [10]u8{0 = spec_delimiter(spec, layout.delimiter), 1 = layout.comment, 2 = u8(layout.no_header), 3 = u8(layout.crlf), 4 = u8(layout.infer)}
	return {spelling = &SPELLING, spec = u8(spec), tolerate = transmute(u8)layout.tolerate, opts = opts}
}

// The options a handle `as` made holds. The spec's own delimiter reads as 0, so a default handle's options are `{}`,
// which the walk's passes fold.
@(private)
options_of :: #force_inline proc "contextless" (as: core.As) -> Options {
	return {delimiter = 0 if as.opts[0] == spec_delimiter(Spec(as.spec), 0) else as.opts[0], comment = as.opts[1], no_header = as.opts[2] != 0, crlf = as.opts[3] != 0, infer = as.opts[4] != 0, tolerate = transmute(bit_set[Tolerance; u8])as.tolerate}
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
	text, err = rows_end((^Rows)(rawptr(&w)), write_records(&w, doc, node))
	if err.kind != .None {
		return nil, 0, err
	}
	return text, len(core.subtree_facts(doc, node)) + w.dropped, err
}

// The header, then each record of the array at `list`. The header is the document's shared keys, else the keys of its
// objects, each once.
@(private)
write_records :: proc(w: ^Rows, doc: ^core.Document, list: core.Node_Index) -> core.Typed_Error_Kind {
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
				return .Out_Of_Memory
			}
		}
	}
	maps, arrays := 0, 0
	records := core.children(doc, list)
	for rec, more := core.child_next(&records); more; rec, more = core.child_next(&records) {
		#partial switch core.kind(doc, rec) {
		case .Map:
			maps += 1
			if !keyed {
				pairs := core.pairs(doc, rec)
				for key, _, ok := core.pair_next(&pairs); ok; key, _, ok = core.pair_next(&pairs) {
					name, whole := core.text_clone(doc, key, scratch)
					_, at, fresh, failed := map_entry(&column, name)
					if !whole || failed != nil {
						return .Out_Of_Memory
					}
					if fresh {
						at^ = len(header)
						if _, no_name := append(&header, name); no_name != nil {
							return .Out_Of_Memory
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
	if (maps > 0 || keyed) && !w.opts.no_header {
		put_header(w, header[:]) or_return
	}
	cells, no_cells := make([]core.Node_Index, len(header), scratch)
	if no_cells != nil {
		return .Out_Of_Memory
	}
	records = core.children(doc, list)
	i := 0
	for rec, more := core.child_next(&records); more; rec, more = core.child_next(&records) {
		start := total(w)
		if maps > 0 {
			for &c in cells {
				c = core.NO_NODE
			}
			if keyed {
				values := core.children(doc, rec)
				for &c in cells {
					c, _ = core.child_next(&values)
				}
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
				if k > 0 {
					put_byte(w, w.opts.delimiter)
				}
				if kind := put_node(w, doc, node, buf[:], k == 0); kind != .None {
					return refuse_in(w, kind, i, core.Index(k))
				}
			}
		} else {
			values := core.children(doc, rec)
			k := 0
			for node, more_cells := core.child_next(&values); more_cells; node, more_cells = core.child_next(&values) {
				if k > 0 {
					put_byte(w, w.opts.delimiter)
				}
				if kind := put_node(w, doc, node, buf[:], k == 0); kind != .None {
					return refuse_in(w, kind, i, core.Index(k))
				}
				k += 1
			}
		}
		end_record(w, start, i) or_return
		i += 1
	}
	return .None
}

@(private)
put_node :: proc(w: ^Rows, doc: ^core.Document, node: core.Node_Index, buf: []u8, first: bool) -> core.Typed_Error_Kind {
	if node == core.NO_NODE {
		return .None
	}
	#partial switch core.kind(doc, node) {
	case .Null:
		return .None
	case .True:
		return put_word(w, true, first)
	case .False:
		return put_word(w, false, first)
	case .Number:
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

// The text of a key or a cell: in `buf` when it fits, else in a copy that lasts the call.
@(private)
node_text :: proc(w: ^Rows, doc: ^core.Document, node: core.Node_Index, buf: []u8) -> (string, core.Typed_Error_Kind) {
	if s, ok := core.text(doc, node, buf); ok {
		return s, .None
	}
	s, ok := core.text_clone(doc, node, runtime.arena_allocator(&w.arena))
	return s, .None if ok else .Out_Of_Memory
}
