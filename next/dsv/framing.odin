// dsv's record services (`core/records`). A record is a row, framed by a judged walk that stops after a batch of rows
// and restarts at the next row's first byte with the header and the width carried in.
package dsv

import "base:runtime"
import core "../core"
import build "../core/build"
import typed "../core/typed"
import records "../core/records"

@(private, rodata)
RECORDS := records.Services {
	next   = #partial {.Lines = next_row},
	judge  = proc(it: ^records.Reader, rec: records.Record) -> Maybe(core.Fault) { return nil },
	read   = read_row,
	build  = build_row,
	column = column_of,
	cell   = cell_of,
	close  = close_rows,
	// A batch holds rows past the one `next` gave and offsets in the text, so a window cannot move under it.
	ends   = #partial {.Lines = 0xff},
}

// The rows a batch holds at most.
@(private)
BATCH :: 256

// The tokens `Batch.cells` holds at least. A batch also ends at a row end past which the widest row might not fit.
@(private)
BATCH_CELLS :: 1 << 15

// A row of a batch: its first byte, the byte its line end starts at, and the end of its cells in `Batch.cells`.
@(private)
Batch_Row :: struct {
	at, hi: u64,
	end:    int,
}

// The rows of a reader's last walk, kept in `Reader.format`. `cells` holds each row's value tokens and `keys` the
// header's cells, empty with no header. `width` is the row width a walk checks rows against, 0 for the first walk of a
// text with a header, which the header sets. No row makes more cells than the first record has, so a walk that stops
// once more than `last` cells are held never overruns `cells`. `done` says the text ended or faulted, with the fault in
// `fault`, given once the batch's rows are. `cols` are the columns a typed read bound, for the plan and read flags
// beside them.
@(private)
Batch :: struct {
	cells:     []core.Token,
	rows:      [BATCH]Batch_Row,
	keys:      []core.Token,
	n, at:     int,
	open:      u64,
	last:      u64,
	width:     int,
	done:      bool,
	fault:     Maybe(core.Fault),
	cols:      []Column,
	cols_plan: ^typed.Plan,
	cols_read: [3]bool,
}

// The hook of a batch's walk. `Hook_Regs.a` counts the cells held, `b` the rows and `c` the open containers.
@(private)
on_row :: proc "contextless" (b: ^Batch, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	s := s
	#partial switch t.kind {
	case .Plain:
		if t.role == .Value {
			b.cells[s.a] = t
			s.a += 1
		}
	case .End:
		if s.c == 1 {
			b.done = true
			return s, .Next
		}
		s.c = 1
		b.rows[s.b] = {at = b.open, hi = t.lo, end = int(s.a)}
		s.b += 1
		if s.b == BATCH || s.a > b.last {
			return s, .Stop
		}
	case:
		s.c += 1
		b.open = t.lo
	}
	return s, .Next
}

// Walks the next batch from `it.pos`. Returns false when no row is left, with the fault, if any, in `it.fault`.
@(private)
refill :: proc(it: ^records.Reader) -> bool {
	b := (^Batch)(it.format)
	if b == nil {
		fresh, err := new(Batch, it.allocator)
		if err != nil {
			it.fault = core.Fault{rules = &RULES, kind = .No_Memory}
			return false
		}
		b = fresh
		it.format = b
	}
	b.n, b.at = 0, 0
	if !b.done {
		spec, opts := read_layout(it.as.read)
		switch spec {
		case .Csv:   walk_batch(it, b, .Csv, opts)
		case .Tsv:   walk_batch(it, b, .Tsv, opts)
		case .Plain: walk_batch(it, b, .Plain, opts)
		}
	}
	if b.n == 0 {
		it.fault = b.fault
	}
	return b.n > 0
}

@(private)
walk_batch :: proc(it: ^records.Reader, b: ^Batch, $S: Spec, opts: Options) {
	if f, bad := option_fault(S, opts).?; bad {
		b.done, b.fault = true, f
		return
	}
	if b.cells == nil {
		// The first record's cells bound every row's: the header's are the width, and with no header the walk is given
		// the width, so a wider row faults before it makes a cell past it.
		widest := 0
		if record_start(it.src, int(it.pos), opts.comment) < len(it.src) {
			widest = header_cells(it.src, int(it.pos), S, opts)
		}
		keys, kerr := make([]core.Token, 0 if opts.no_header else widest, it.allocator)
		cells, cerr := make([]core.Token, max(BATCH_CELLS, widest), it.allocator)
		if kerr != nil || cerr != nil {
			delete(keys, it.allocator)
			b.done, b.fault = true, core.Fault{rules = &RULES, kind = .No_Memory}
			return
		}
		b.keys, b.cells, b.last = keys, cells, u64(len(cells) - widest)
		b.width = widest if opts.no_header else 0
	}
	regs: core.Hook_Regs
	r := run(it.src, it.pos, S, opts, b, &regs, on_row, true, b.keys, b.width)
	b.n = int(regs.b)
	if f := core.fault_of(r, &RULES); f != nil {
		b.done, b.fault = true, f
	}
	// A stopped walk returns the byte past the row end it stopped on. A restart reads no header.
	it.pos = r >> 16
	b.width = max(b.width, len(b.keys))
}

@(private)
next_row :: proc(it: ^records.Reader) -> (records.Record, bool) {
	b := (^Batch)(it.format)
	if b == nil || b.at == b.n {
		if !refill(it) {
			return {}, false
		}
		b = (^Batch)(it.format)
	}
	row := b.rows[b.at]
	b.at += 1
	return {text = it.src[row.at:row.hi], at = row.at}, true
}

// The value tokens of `rec`, the row `next` gave last, or false for another.
@(private)
cells_of :: proc(it: ^records.Reader, rec: records.Record) -> ([]core.Token, bool) {
	b := (^Batch)(it.format)
	if b == nil || b.at == 0 || b.rows[b.at - 1].at != rec.at {
		return nil, false
	}
	lo := b.rows[b.at - 2].end if b.at > 1 else 0
	return b.cells[lo:b.rows[b.at - 1].end], true
}

@(private)
column_of :: proc(it: ^records.Reader, name: string) -> int {
	if it.format == nil {
		refill(it)
	}
	b := (^Batch)(it.format)
	if b == nil {
		return -1
	}
	for &key, c in b.keys {
		doc := core.Document{src = it.src, nodes = ([^]core.Node)(&key)[:1], read = it.as.read}
		if spelling_key_equals(&doc, 0, name) {
			return c
		}
	}
	return -1
}

@(private)
cell_of :: proc(it: ^records.Reader, rec: records.Record, column: int, buf: []u8) -> (string, bool) {
	cells, ok := cells_of(it, rec)
	if !ok || column < 0 || column >= len(cells) {
		return "", false
	}
	return cell_text(it.src, cells[column], Spec(it.as.read.spec), buf)
}

// Builds `rec`, the row `next` gave last, as a document over the whole input: a `Map` keyed by the header's cells, or an
// `Array` with no header.
@(private)
build_row :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	cells, ok := cells_of(it, rec)
	if !ok {
		return {}, {kind = .Bad_Index, at = rec.at}
	}
	keys := (^Batch)(it.format).keys
	b := build.builder_start(it.src, &SPELLING, false, allocator, 1 + len(cells) + len(keys), 2)
	if len(b.doc.nodes) == 0 {
		return build.builder_end(&b, build.BUILDER_REGS, nil)
	}
	b.doc.read = it.as.read
	hi := rec.at + u64(len(rec.text))
	b.root_close = hi
	regs := build.BUILDER_REGS
	regs, _ = build.builder_hook_plain(&b, regs, {kind = .Map if len(keys) > 0 else .Array, role = .Value, lo = rec.at})
	for t, c in cells {
		if len(keys) > 0 {
			regs, _ = build.builder_hook_plain(&b, regs, keys[c])
		}
		cell := t
		cell.spelling &~= SPELLING_DOUBLED
		regs, _ = build.builder_hook_plain(&b, regs, cell)
	}
	regs, _ = build.builder_hook_plain(&b, regs, {kind = .End, lo = hi})
	return build.builder_end(&b, regs, nil)
}

// Reads the next row into `target`, a row type, by replaying its cells through `on_cell` as `unmarshal` reads the text
// of the header and that row. A list row reads the row alone, as it reads a header as data.
@(private)
read_row :: proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Error) -> bool {
	spec, opts := read_layout(it.as.read)
	h := Cells{refuse_repeats = read.refuse_duplicates}
	regs, started := typed.read_start(&h.r, it.src, plan, &SPELLING, T, target, read, it.frames, allocator)
	if started.kind == .None && plan.marshal == nil {
		started.kind = .Plan_Mismatch
	}
	if started.kind == .None {
		rows_of(&h, plan, len(it.src))
		if !h.single {
			started.kind = .Plan_Mismatch
		} else if h.row.kind == .Map && opts.no_header {
			started.kind = .Unsupported
		}
	}
	if started.kind != .None {
		err^ = started
		return false
	}
	rec, ok := next_row(it)
	if !ok {
		return false
	}
	b := (^Batch)(it.format)
	cells, _ := cells_of(it, rec)
	h.r.token_doc.read.spec = u8(spec)
	h.no_header = opts.no_header || h.opens == .Array
	if !h.no_header {
		h.keys = b.keys
	}
	flags := [3]bool{h.r.refuse_unknown, h.r.first_key, h.refuse_repeats}
	if b.cols_plan == plan && b.cols_read == flags {
		h.cols = b.cols
	}
	// The text's open is read.
	h.met = 1
	action: core.Action
	regs, action = row_token(&h, regs, {kind = .Array, role = .Value, lo = rec.at})
	fresh := h.cols != nil && raw_data(h.cols) != raw_data(b.cols)
	if fresh {
		// Columns bound with no refusal and no map row's names are the same for every row.
		if h.r.first.kind == .None && h.row.kind != .Map {
			delete(b.cols, it.allocator)
			b.cols, _ = make([]Column, len(h.cols), it.allocator)
			copy(b.cols, h.cols)
			b.cols_plan, b.cols_read = plan, flags
		}
	}
	if action == .Next {
		for t in cells {
			if regs, action = on_cell(&h, regs, t); action == .Stop {
				break
			}
		}
		if action != .Stop {
			regs, _ = row_token(&h, regs, {kind = .End, role = .Value, lo = rec.at + u64(len(rec.text))})
		}
	}
	err^ = typed.read_end(&h.r, regs, nil)
	if fresh {
		delete(h.cols, context.temp_allocator)
	}
	return true
}

@(private)
close_rows :: proc(it: ^records.Reader) {
	if b := (^Batch)(it.format); b != nil {
		delete(b.cells, it.allocator)
		delete(b.keys, it.allocator)
		delete(b.cols, it.allocator)
		free(b, it.allocator)
	}
}
