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
import "jq"

Column_Shape :: enum u8 {
	Column, // `.a, .b`: each cell is an output
	Array, // `[.a, .b]`
	Object, // `{a, b: .c}`, and `.` with `every`
	Select, // `select(F)`
}

Columns :: struct {
	shape:   Column_Shape,
	every:   bool, // `.`: an object of every column, its names the open file's header
	// The columns read in output order, or those `select`'s F reads, and an object's key for each.
	names:   [dynamic]string,
	keys:    [dynamic]string,
	// The open file's index of each name, -1 for one its header lacks, and an object's members in the order compact
	// JSON prints them: sorted under -S, each led by `{"key":` or `,"key":`.
	at:      []int,
	members: []Column_Member,
	files:   int,
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
	if r.whys != {} && !r.on {
		return
	}
	// The columns live for the run, and a file's header names are set when it opens.
	cols := new(Columns)
	cols.names.allocator, cols.keys.allocator = context.allocator, context.allocator
	r.whys += columns_of(run.prog, cols)
	if r.whys == {} {
		r.columns = cols
	}
}

@(private = "file")
columns_of :: proc(n: ^jq.Node, cols: ^Columns) -> bit_set[Route_Why] {
	#partial switch n.kind {
	case .Identity:
		cols.shape, cols.every = .Object, true
	case .Call:
		if n.name != "select" || len(n.args) != 1 {
			return {.Not_Columns}
		}
		// Bound to the builtin, it is no `select` that `~/.jq` or a module defines.
		if b, bound := n.native.?; !bound || b.native != jq.native_select {
			return {.Select_Redefined}
		}
		cols.shape = .Select
		if !only_columns(n.args[0], &cols.names) {
			return {.Select_Columns}
		}
	case .Object:
		cols.shape = .Object
		whys: bit_set[Route_Why]
		for i := 0; i < len(n.args); i += 2 {
			key, value := n.args[i], n.args[i + 1]
			k, is_text := key.value.(string)
			if key.kind != .Literal || !is_text {
				whys += {.Object_Key}
			}
			if value != nil && !is_column(value) {
				whys += {.Object_Member}
			}
			name := k if value == nil else value.name
			// A repeated key keeps its place and takes the later value, as in jq.
			if at, repeated := slice.linear_search(cols.keys[:], k); repeated {
				cols.names[at] = name
				continue
			}
			append(&cols.keys, k)
			append(&cols.names, name)
		}
		return whys
	case:
		cols.shape = .Array if n.kind == .Array else .Column
		if !add_columns(&cols.names, n.a if n.kind == .Array else n) {
			return {.Not_Columns}
		}
	}
	return {}
}

// Whether `n` is `.name`.
@(private = "file")
is_column :: proc(n: ^jq.Node) -> bool {
	return n.kind == .Field && !n.opt && n.a.kind == .Identity
}

// Appends the columns of `n`, `.a` or `.a, .b`, to `names` in order. Returns false for any other `n`.
@(private = "file")
add_columns :: proc(names: ^[dynamic]string, n: ^jq.Node) -> bool {
	switch {
	case n == nil:
	case n.kind == .Comma:
		return add_columns(names, n.a) && add_columns(names, n.b)
	case is_column(n):
		append(names, n.name)
		return true
	}
	return false
}

// Whether the expression `n`, run on a record, reads it only as `.name`, whose names it appends to `watch`. The right
// side of a `|` does not run on the record. Any other use of `.`, a call that reads `.`, a binding, or an `if` without
// `else` reads more. A nested `select` runs its argument on the same input as `n`.
@(private = "file")
only_columns :: proc(n: ^jq.Node, watch: ^[dynamic]string) -> bool {
	if n == nil {
		return true
	}
	#partial switch n.kind {
	case .Field:
		if n.a.kind != .Identity {
			return only_columns(n.a, watch)
		}
		if !slice.contains(watch[:], n.name) {
			append(watch, n.name)
		}
		return true
	case .Literal, .Var:
		return true
	case .Pipe, .Try:
		return only_columns(n.a, watch)
	case .Index, .Slice, .Iterate, .Array, .Neg, .Comma, .Binary, .And, .Or, .Alt:
		return only_columns(n.a, watch) && only_columns(n.b, watch) && only_columns(n.c, watch)
	case .If:
		return n.c != nil && only_columns(n.a, watch) && only_columns(n.b, watch) && only_columns(n.c, watch)
	case .Call:
		return n.name == "select" && len(n.args) == 1 && only_columns(n.args[0], watch)
	}
	return false
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
			name := strings.clone(jq.node_string(header, k), heap)
			append(&cols.names, name)
			append(&cols.keys, name)
		}
	}
	delete(cols.at, heap)
	cols.at = make([]int, len(cols.names), heap)
	for name, i in cols.names {
		cols.at[i] = records.column(texts, name)
	}
	if cols.shape != .Object {
		return
	}
	delete(cols.members, heap)
	cols.members = make([]Column_Member, len(cols.keys), heap)
	for k, i in cols.keys {
		cols.members[i] = {key = k, at = cols.at[i]}
	}
	if run.opts.sort_keys {
		slice.stable_sort_by(cols.members, proc(a, b: Column_Member) -> bool {return a.key < b.key})
	}
	for &m, i in cols.members {
		lead := strings.concatenate({"{" if i == 0 else ",", jq.to_json(m.key, allocator = heap), ":", LEAD_PAD}, heap)
		m.lead = lead[:len(lead) - len(LEAD_PAD)]
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
	short: [256]u8 = ---
	buf := short[:len(rec.text)] if len(rec.text) <= len(short) else make([]u8, len(rec.text))
	// One column is read alone, which splits the record only up to it.
	row: []Maybe(string)
	if len(cols.at) > 1 {
		row, _ = records.cells(it, rec, buf)
	}
	switch cols.shape {
	case .Column:
		for at in cols.at {
			emit(o, value_of(column_cell(it, rec, row, at, buf)))
		}
	case .Array:
		a := jq.new_array(len(cols.at))
		for at in cols.at {
			append(&a.items, value_of(column_cell(it, rec, row, at, buf)))
		}
		emit(o, a)
	case .Object:
		l := o.layout
		switch {
		case !l.opts.pretty && l.colors == nil && !l.opts.ascii && !l.comments && o.table == nil:
			// Compact JSON, written as the printer writes the object.
			for m in cols.members {
				put_lead(&o.buf, m.lead)
				if s, text := column_cell(it, rec, row, m.at, buf).?; text {
					jq.put_string(&o.buf, s, {})
				} else {
					intrinsics.unaligned_store((^u32)(write.room(&o.buf, 4)), 0x6c6c756e) // "null"
					o.buf.cursor += 4
				}
			}
			if len(cols.members) == 0 {
				jq.put_byte(&o.buf, '{')
			}
			jq.put_byte(&o.buf, '}')
			o.result = JQ_OK
			end_output(o)
		case o.table != nil && !o.opts.grow_header:
			keys := make([]string, len(cols.members))
			cells := make([]Maybe(string), len(cols.members))
			for m, i in cols.members {
				keys[i] = m.key
				cells[i] = column_cell(it, rec, row, m.at, buf)
			}
			table_object(o, keys, cells)
		case cols.every:
			built, _ := records.build(it, rec, context.allocator)
			emit(o, jq.document_value(built))
		case:
			obj := jq.new_object()
			for at, i in cols.at {
				jq.object_put(obj, cols.keys[i], value_of(column_cell(it, rec, row, at, buf)))
			}
			emit(o, obj)
		}
	case .Select:
		watched := jq.new_object()
		for name, i in cols.names {
			jq.object_put(watched, name, value_of(column_cell(it, rec, row, cols.at[i], buf)))
		}
		o.whole = {it, rec}
		run_once(run, watched)
		o.whole = {}
		return
	}
	finish_input(o)
}

// The cell at column `at` of `rec` as the record's object holds it: its text, or nil for an empty unquoted cell and for
// a column the header lacks. `row` holds the record's cells, or is nil when the one column read is read alone, into
// `buf`.
@(private = "file")
column_cell :: #force_inline proc(it: ^records.Reader, rec: records.Record, row: []Maybe(string), at: int, buf: []u8) -> Maybe(string) {
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
value_of :: #force_inline proc(cell: Maybe(string)) -> jq.Value {
	if s, text := cell.?; text {
		return s
	}
	return nil
}
