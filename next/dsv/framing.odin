// dsv's record services (`core/records`). A record is a row, framed by `validate`'s pass, which stops after a batch of
// rows and restarts at the next row's first byte with the width carried in. A row's cells are read from its text when
// asked for.
package dsv

import "base:intrinsics"
import "base:runtime"
import core "../core"
import kernel "../core/kernel"
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

// A row of a batch: its first byte and the byte its line end starts at.
@(private)
Batch_Row :: struct {
	at, hi: u64,
}

// The rows of a reader's last frame, kept in `Reader.format`. The frame is `validate`'s pass, which records each row, and
// the header's line in `head`, and stops once `BATCH` rows are held. `width` is the row width a frame checks rows
// against, 0 for the first frame, which the first record sets, and a stop keeps it for the next. A row's cells are
// split from its text when one is asked for. `cells` holds the `split` cells of row `split_row - 1`, and `keys` the
// header's cells, empty with no header. `done` says the text ended or faulted, with the fault in `fault`, given once
// the batch's rows are. `cols` are the columns a typed read bound, for the plan and read flags beside them.
@(private)
Batch :: struct {
	rows:      [BATCH]Batch_Row,
	head:      Batch_Row,
	cells:     []core.Token,
	keys:      []core.Token,
	n, at:     int,
	split:     int,
	split_row: int,
	width:     int,
	done:      bool,
	fault:     Maybe(core.Fault),
	cols:      []Column,
	cols_plan: ^typed.Plan,
	cols_read: [3]bool,
}

// Records the record from `lo` to `hi`, the header's line when `header`. Returns true once the batch is full.
@(private)
frame_row :: #force_inline proc "contextless" (b: ^Batch, lo, hi: int, header: bool) -> bool #no_bounds_check {
	if header {
		b.head = {u64(lo), u64(hi)}
		return false
	}
	b.rows[b.n] = {u64(lo), u64(hi)}
	b.n += 1
	return b.n == BATCH
}

// Frames the next batch from `it.pos`. Returns false when no row is left, with the fault, if any, in `it.fault`.
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
	b.n, b.at, b.split_row = 0, 0, 0
	if !b.done {
		spec, opts := read_layout(it.as.read)
		switch spec {
		case .Csv:   frame_batch(it, b, .Csv, opts)
		case .Tsv:   frame_batch(it, b, .Tsv, opts)
		case .Plain: frame_batch(it, b, .Plain, opts)
		}
	}
	if b.n == 0 {
		it.fault = b.fault
	}
	return b.n > 0
}

@(private)
frame_batch :: proc(it: ^records.Reader, b: ^Batch, $S: Spec, opts: Options) {
	if f, bad := option_fault(S, opts).?; bad {
		b.done, b.fault = true, f
		return
	}
	first := b.width == 0
	// The frame makes no tokens, a comment line's included.
	on :: proc "contextless" (b: ^Batch, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
		return s, .Next
	}
	regs: core.Hook_Regs
	r := run(it.src, it.pos, S, opts, b, &regs, on, false, nil, b.width)
	r = field_count_fault(src = it.src, lo = it.pos, S = S, opts = opts, r = r, width = 0 if first else b.width)
	if f := core.fault_of(r, &RULES); f != nil {
		b.done, b.fault = true, f
	} else if u8(r >> 8) != core.STOPPED {
		b.done = true
	}
	// A stopped frame returns the byte past the row end it stopped on. A restart reads no header.
	it.pos = r >> 16
	if first && b.head.hi > b.head.at {
		n, ok := split_all(it, b, b.head, S, opts, .Key)
		keys, err := make([]core.Token, n, it.allocator)
		if !ok || err != nil {
			b.done, b.fault = true, core.Fault{rules = &RULES, kind = .No_Memory}
			return
		}
		copy(keys, b.cells[:n])
		b.keys = keys
	}
}

// Splits `row` into `b.cells`, which grows to hold them all. Returns the cell count, or false when they do not fit in
// memory.
@(private)
split_all :: proc(it: ^records.Reader, b: ^Batch, row: Batch_Row, $S: Spec, opts: Options, role: core.Role) -> (int, bool) {
	for {
		sp := Split{out = b.cells}
		if _, a := split_cells(it.src, row, S, opts, role, &sp, {}, on_split); a != .Stop {
			return sp.n, true
		}
		grown, err := make([]core.Token, max(2 * len(b.cells), 64), it.allocator)
		if err != nil {
			return 0, false
		}
		delete(b.cells, it.allocator)
		b.cells = grown
	}
}

// A split's buffer: the first `n` tokens of `out` are the row's cells.
@(private)
Split :: struct {
	out: []core.Token,
	n:   int,
}

// The hook of a split into a buffer, which stops the split at a cell past the buffer's end.
@(private)
on_split :: proc "contextless" (s: ^Split, r: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	if s.n == len(s.out) {
		return r, .Stop
	}
	s.out[s.n] = t
	s.n += 1
	return r, .Next
}

// Passes the cells of the judged row `row` to the hook `on` as `Plain` tokens of `role`, spelled as the hooked pass
// spells them, and returns the hook's last action. The row starts outside a quoted field, so its quotes pair up from
// its first byte.
@(private)
split_cells :: proc "contextless" (src: []u8, row: Batch_Row, $S: Spec, opts: Options, role: core.Role, h: ^$H, regs: core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	T :: kernel.Tier(0)
	base := raw_data(src)
	lo, hi := int(row.at), int(row.hi)
	delim := delimiter_of(S, opts)
	lax := .Invalid_Utf8 in opts.tolerate
	field_lo := lo
	carry := false
	regs := regs
	a: core.Action
	when S == .Csv {
		in_quote, close, start: u64 = 0, 0, 1
	}
	for pos := lo; ; pos += 64 {
		blk := kernel.load(base[pos:]) if len(src) - pos >= 64 else kernel.load_padded(T, src, pos)
		live := bits_between(0, min(hi - pos, 64))
		d := kernel.pack(kernel.eq(blk, delim)) & live
		bs: u64
		when S == .Csv {
			// With no branch on the row's quotes, since a text's quoted cells fall in no pattern.
			q := kernel.pack(kernel.eq(blk, '"')) & live
			instr := kernel.prefix_xor(T, q) ~ in_quote
			if .Bare_Quote in opts.tolerate {
				// A quote the pass read as a tolerated bare quote is text, so the quotes pair up without it.
				for {
					bare := q & instr & ~((d & ~instr) << 1 | start | (q & ~instr) << 1 | close)
					if bare == 0 {
						break
					}
					q &~= bare & -bare
					instr = kernel.prefix_xor(T, q) ~ in_quote
				}
			}
			closing := q & ~instr
			d &= ~instr
			bs = (closing << 1 | close) & q
			in_quote, close, start = u64(0) - (instr >> 63), closing >> 63, d >> 63
		} else when S == .Tsv {
			bs = kernel.pack(kernel.eq(blk, '\\')) & live
		}
		plain := bs == 0 && !carry
		for d != 0 {
			at := pos + int(intrinsics.count_trailing_zeros(d))
			d &= d - 1
			esc := !plain && span_esc(bs, pos, field_lo, at, carry)
			if regs, a = on(h, regs, {u64(field_lo), u32(at - field_lo), .Plain, role, spelling(base, field_lo, at, esc, lax, S)}); a == .Stop {
				return regs, a
			}
			field_lo = at + 1
		}
		if hi - pos <= 64 {
			esc := !plain && span_esc(bs, pos, field_lo, hi, carry)
			return on(h, regs, {u64(field_lo), u32(hi - field_lo), .Plain, role, spelling(base, field_lo, hi, esc, lax, S)})
		}
		carry = !plain && span_esc(bs, pos, field_lo, pos + 64, carry)
	}
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

// The value tokens of `rec`, the row `next` gave last, or false for another or when they do not fit in memory.
@(private)
cells_of :: proc(it: ^records.Reader, rec: records.Record) -> ([]core.Token, bool) {
	b := (^Batch)(it.format)
	if b == nil || b.at == 0 || b.rows[b.at - 1].at != rec.at {
		return nil, false
	}
	if b.split_row != b.at {
		spec, opts := read_layout(it.as.read)
		ok: bool
		switch spec {
		case .Csv:   b.split, ok = split_all(it, b, b.rows[b.at - 1], .Csv, opts, .Value)
		case .Tsv:   b.split, ok = split_all(it, b, b.rows[b.at - 1], .Tsv, opts, .Value)
		case .Plain: b.split, ok = split_all(it, b, b.rows[b.at - 1], .Plain, opts, .Value)
		}
		if !ok {
			return nil, false
		}
		b.split_row = b.at
	}
	return b.cells[:b.split], true
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

// A cell below the split buffer's length splits the row only up to it.
@(private)
cell_of :: proc(it: ^records.Reader, rec: records.Record, column: int, buf: []u8) -> (string, bool) {
	b := (^Batch)(it.format)
	spec := Spec(it.as.read.spec)
	if b != nil && b.split_row != b.at && b.at > 0 && b.rows[b.at - 1].at == rec.at && 0 <= column && column < len(b.cells) {
		_, opts := read_layout(it.as.read)
		sp := Split{out = b.cells[:column + 1]}
		switch spec {
		case .Csv:   split_cells(it.src, b.rows[b.at - 1], .Csv, opts, .Value, &sp, {}, on_split)
		case .Tsv:   split_cells(it.src, b.rows[b.at - 1], .Tsv, opts, .Value, &sp, {}, on_split)
		case .Plain: split_cells(it.src, b.rows[b.at - 1], .Plain, opts, .Value, &sp, {}, on_split)
		}
		if sp.n <= column {
			return "", false
		}
		return cell_text(it.src, sp.out[column], spec, buf)
	}
	cells, ok := cells_of(it, rec)
	if !ok || column < 0 || column >= len(cells) {
		return "", false
	}
	return cell_text(it.src, cells[column], spec, buf)
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
		row := b.rows[b.at - 1]
		switch spec {
		case .Csv:   regs, action = split_cells(it.src, row, .Csv, opts, .Value, &h, regs, on_cell)
		case .Tsv:   regs, action = split_cells(it.src, row, .Tsv, opts, .Value, &h, regs, on_cell)
		case .Plain: regs, action = split_cells(it.src, row, .Plain, opts, .Value, &h, regs, on_cell)
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
