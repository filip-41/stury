package main

// The column route: a filter that reads a --from csv or --from tsv record only by its columns, answered from the
// record's cells without the interpreter. The filters are `.a`, `.a, .b`, `[.a, .b]`, `{a, b: .c}` and `.`, and
// `select(F)` where F reads the record only as `.name`: F runs on an object of those columns, and each of its outputs
// is the whole record. A column the header lacks is null, as `.name` is on an object without it.

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "core:strings"
import core "../../core"
import "../../core/write"
import records "../../core/records"
import json "../../json"
import "../../jq"

Columns :: struct {
	// What the filter reads. Under `every` the names and keys are the open file's header.
	using read: jq.Columns_Read,
	// The open file's index of each name, -1 for one its header lacks, the cells up to the last of them, and an object's
	// members in the order compact JSON prints them: sorted under -S, each led by `{"key":` or `,"key":`.
	at:      []int,
	upto:    int,
	members: []Column_Member,
	heads:   []string, // the members' keys, a table row's
	ordered: bool, // the table's header is `heads`, or the next row makes it
	files:   int,
	ragged:  bool, // --ragged: a record's object holds the columns it has, which the header does not fix
	// The open file's records are built and the filter runs on each: a ragged record's columns that the header does
	// not name are found by a build.
	whole:   bool,
}

Column_Member :: struct {
	key, lead: string,
	at:        int,
}

// Sets `run.route.columns` when the filter reads each delimited record only by its columns, else adds why not.
choose_columns :: proc(run: ^Run) {
	o := &run.opts
	r := &run.route
	if o.null_input {r.whys += {.Null_Input}}
	if o.slurp {r.whys += {.Slurp}}
	if o.stream {r.whys += {.Stream}}
	if o.cells_in.no_header {r.whys += {.No_Header}}
	if o.cells_in.infer {r.whys += {.Infer}}
	if r.whys != {} && !r.on {
		return
	}
	// The columns live for the run, and a file's header names are set when it opens.
	cols := new(Columns)
	cols.ragged = .Ragged in o.cells_in.tolerate
	faults: bit_set[jq.Shape_Fault]
	cols.read, faults = run.shape.columns, run.shape.column_faults
	cols.names.allocator, cols.keys.allocator = context.allocator, context.allocator
	r.whys += whys_of(faults)
	// The record passes through, and with it the comment lines above it, to an output that writes them.
	writes_notes := o.cells_out.comment != 0 if writes_cells(o) else .Comment in holds_out(o)
	if r.whys == {} && o.cells_in.comment != 0 && writes_notes && (cols.every || cols.shape == .Select) {
		r.whys += {.Comments_In}
	}
	if r.whys == {} {
		r.columns = cols
	}
}

// Finds the open file's index of each column the filter reads, once its first record `header`, keyed by the header,
// is built.
place_columns :: proc(run: ^Run, cols: ^Columns, texts: ^records.Reader, header: ^core.Document) {
	heap := runtime.heap_allocator()
	cols.files += 1
	if cols.every {
		clear(&cols.names)
		clear(&cols.keys)
		it := core.pairs(header, core.ROOT)
		for k in core.pair_next(&it) {
			name := strings.clone(core.node_string(header, k), heap)
			append(&cols.names, name)
			append(&cols.keys, name)
		}
	}
	delete(cols.at, heap)
	cols.at = make([]int, len(cols.names), heap)
	cols.upto = 0
	cols.whole = cols.ragged && cols.every
	for name, i in cols.names {
		cols.at[i] = records.column(texts, name)
		cols.upto = max(cols.upto, cols.at[i] + 1)
		// A ragged record's cells past the header are columns named by their position.
		cols.whole ||= cols.ragged && (cols.at[i] < 0 || strings.trim_left(name, "0123456789") == "")
	}
	if cols.shape != .Object {
		return
	}
	delete(cols.members, heap)
	delete(cols.heads, heap)
	cols.members = make([]Column_Member, len(cols.keys), heap)
	cols.heads = make([]string, len(cols.keys), heap)
	for k, i in cols.keys {
		cols.members[i] = {key = k, at = cols.at[i]}
	}
	if run.opts.sort_keys {
		slice.stable_sort_by(cols.members, proc(a, b: Column_Member) -> bool {return a.key < b.key})
	}
	for &m, i in cols.members {
		cols.heads[i] = m.key
		lead := strings.concatenate({"{" if i == 0 else ",", jq.to_json(m.key, allocator = heap), ":", LEAD_PAD}, heap)
		m.lead = lead[:len(lead) - len(LEAD_PAD)]
	}
	if t := run.output.table; t != nil {
		cols.ordered = len(t.wr.table.header) == 0 || slice.equal(t.wr.table.header[:], cols.heads)
	}
}

// The bytes past a member's lead, so that `put_lead` reads 32 bytes of it.
@(private = "file")
LEAD_PAD :: "                                "

// Writes the member's `lead` in two 16-byte stores when it is no longer than 32 bytes, reading 32 bytes of it, which its
// padding holds.
@(private = "file")
put_lead :: #force_inline proc(out: ^write.Out, lead: string) #no_bounds_check {
	if len(lead) > len(LEAD_PAD) {
		write.put_text(out, lead)
		return
	}
	p, src := write.room(out, len(LEAD_PAD)), raw_data(lead)
	intrinsics.unaligned_store((^[16]u8)(p), intrinsics.unaligned_load((^[16]u8)(src)))
	intrinsics.unaligned_store((^[16]u8)(p[16:]), intrinsics.unaligned_load((^[16]u8)(src[16:])))
	out.cursor += len(lead)
}

// Answers the filter on the record `rec` that `it` read and prints its outputs, as `run_once` would. What it allocates
// is the caller's to free.
answer_columns :: proc(run: ^Run, it: ^records.Reader, rec: records.Record) {
	cols := run.route.columns
	o := &run.output
	if cols.whole {
		built, _ := records.build(it, rec, context.allocator)
		run_once(run, core.document_value(built))
		return
	}
	short: [256]u8 = ---
	buf := short[:len(rec.text)] if len(rec.text) <= len(short) else make([]u8, len(rec.text))
	// One column is read alone, which splits the record only up to it.
	row: []write.Scalar
	if len(cols.at) > 1 {
		row, _ = records.cells(it, rec, buf, cols.upto)
	}
	switch cols.shape {
	case .Column:
		for at in cols.at {
			if !emit(o, value_of(column_cell(it, rec, row, at, buf))) {
				refuse_record(run)
				return
			}
		}
	case .Array:
		a := core.new_array(len(cols.at))
		for at in cols.at {
			append(&a.items, value_of(column_cell(it, rec, row, at, buf)))
		}
		if !emit(o, a) {
			refuse_record(run)
			return
		}
	case .Object:
		l := o.layout
		switch {
		case !l.opts.pretty && l.colors == nil && !l.opts.ascii && !l.comments && o.table == nil && !writes_texts(o.opts):
			// Compact JSON, written as the printer writes the object. A cell the walk judged is UTF-8.
			for m in cols.members {
				put_lead(&o.buf, m.lead)
				if s, text := column_cell(it, rec, row, m.at, buf).(string); text {
					json.put_string(&o.buf, s, {escape_del = true})
				} else {
					intrinsics.unaligned_store((^u32)(write.room(&o.buf, 4)), 0x6c6c756e) // "null"
					o.buf.cursor += 4
				}
			}
			if len(cols.members) == 0 {
				write.put_byte(&o.buf, '{')
			}
			write.put_byte(&o.buf, '}')
			o.result = JQ_OK
			end_output(o)
		case o.table != nil && !o.opts.grow_header:
			few: [32]write.Scalar = ---
			cells := few[:len(cols.members)] if len(cols.members) <= len(few) else make([]write.Scalar, len(cols.members))
			if cols.ordered {
				for m, i in cols.members {
					cells[i] = column_cell(it, rec, row, m.at, buf)
				}
				table_object(o, cols.heads, cells, true)
			} else {
				// A row the header does not order is refused at the first key it lacks in the object's own order, which -S
				// does not sort, as the interpreter's row is.
				for at, i in cols.at {
					cells[i] = column_cell(it, rec, row, at, buf)
				}
				table_object(o, cols.keys[:], cells, false)
			}
		case cols.every:
			built, _ := records.build(it, rec, context.allocator)
			if !emit(o, core.document_value(built)) {
				refuse_record(run)
				return
			}
		case:
			obj := core.new_object()
			for at, i in cols.at {
				core.object_put(obj, cols.keys[i], value_of(column_cell(it, rec, row, at, buf)))
			}
			if !emit(o, obj) {
				refuse_record(run)
				return
			}
		}
	case .Select:
		watched := core.new_object()
		for name, i in cols.names {
			core.object_put(watched, name, value_of(column_cell(it, rec, row, cols.at[i], buf)))
		}
		o.whole = {it, rec}
		run_once(run, watched)
		o.whole = {}
		return
	}
	finish_input(o)
}

// Ends the record whose output the writer refused, as `run_once` ends an input whose filter fails.
@(private = "file")
refuse_record :: proc(run: ^Run) {
	flush_some(&run.output, force = true)
	tell_filter_error(&run.ip, (^Inputs)(jq.inputs(&run.ip).data))
	finish_input(&run.output, EXIT_INPUT)
}

// The cell at column `at` of `rec` as the record's object holds it: its text, or nil for an empty unquoted cell and for
// a column the header lacks. `row` holds the record's cells, or is nil when the one column read is read alone, into
// `buf`.
@(private = "file")
column_cell :: #force_inline proc(it: ^records.Reader, rec: records.Record, row: []write.Scalar, at: int, buf: []u8) -> write.Scalar {
	if row != nil {
		return row[at] if uint(at) < uint(len(row)) else nil
	}
	s, ok := records.cell(it, rec, at, buf)
	if !ok {
		return nil
	}
	if len(s) == 0 {
		// A quoted empty cell's text is the empty span after its opening quote.
		p := int(uintptr(raw_data(s)) - uintptr(raw_data(it.src)))
		return "" if 0 < p && p < len(it.src) && it.src[p] == '"' else nil
	}
	return s
}

@(private = "file")
value_of :: #force_inline proc(cell: write.Scalar) -> core.Value {
	if s, text := cell.(string); text {
		return s
	}
	return nil
}
