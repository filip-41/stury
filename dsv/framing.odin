// dsv's record services (`core/records`). A record is a row, framed by `validate`'s pass, which stops after a batch of
// rows and restarts at the next row's first byte with the width carried in. A row's cells are read from its text when
// asked for.
package dsv

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import core "../core"
import kernel "../core/kernel"
import build "../core/build"
import typed "../core/typed"
import records "../core/records"

@(private, rodata)
RECORDS := records.Services {
	next   = #partial {.Lines = next_row},
	judge  = proc(it: ^records.Reader, rec: records.Record) -> Maybe(core.Fault) { return nil },
	span   = next_span,
	guess  = guess_row,
	exact  = exact_row,
	piece  = piece_rows,
	whole  = proc(src: []u8, as: core.As) -> (core.As, core.Framing, u64) { return as, .Lines, 0 },
	read   = read_row,
	build  = build_row,
	column = column_of,
	cell   = cell_of,
	cells  = cells_texts,
	close  = close_rows,
}

// The rows a batch holds at most.
@(private)
BATCH :: 256

// A row of a batch: its first byte, the byte its line end starts at, and whether it holds an ill-formed sequence
// `.Invalid_Utf8` tolerated, which its split then reads its blocks for.
@(private)
Batch_Row :: struct {
	at, hi: u64,
	lax:    bool,
}

// The rows of a reader's last frame, kept in `Reader.format`. The frame is `validate`'s pass, which records each row, and
// the header's line in `head`, and stops once `BATCH` rows are held. `width` is the row width a frame checks rows
// against, 0 until the first record sets it, and each row framed keeps it for the next frame. A row's cells are
// split from its text when one is asked for. `cells` holds the `split` cells of row `split_row - 1`, its first
// `split_cap` when the split stopped short of the row's end, and `keys` the header's cells, empty with no header, as
// tokens of `key_src`. That is the text itself, and on a stream a copy of the header's line, since the window moves. `comb` joins the header's line and a row for a read or a build on a stream.
// `done` says the text ended or faulted, with the fault in `fault`, given once the batch's rows are. `cols` are the
// columns a typed read bound, for the plan and read flags beside them.
//
// On a stream, `moves` is the reader's `moves` as the last call left it, so a different one says the window moved or
// `pos` came back and the batch is stale. `from` is `pos` where the batch was framed, `past` says a row stood in its
// window, and `head_at` the input offset of the header's line.
@(private)
Batch :: struct {
	rows:      [BATCH]Batch_Row,
	head:      Batch_Row,
	to:        u64,
	cells:     [dynamic]core.Token,
	texts:     [dynamic]Maybe(string),
	keys:      []core.Token,
	key_src:   []u8,
	comb:      [dynamic]u8,
	moves:     u64,
	from:      u64,
	past:      bool,
	head_at:   u64,
	n, at:     int,
	split:     int,
	split_row: int,
	split_cap: int,
	width:     int,
	done:      bool,
	fault:     Maybe(core.Fault),
	cols:      []Column,
	cols_plan: ^typed.Plan,
	cols_read: [3]bool,
}

// Records the record from `lo` to `hi`, the header's line when `header`, and the `width` its check left. The first record
// sets the width and no later one changes it. Returns true once the batch is full or holds a record at or past `b.to`.
@(private)
frame_row :: #force_inline proc "contextless" (b: ^Batch, lo, hi: int, header: bool, width: int, lax: bool) -> bool #no_bounds_check {
	if header {
		b.head, b.width = {u64(lo), u64(hi), lax}, width
		return false
	}
	b.rows[b.n] = {u64(lo), u64(hi), lax}
	b.n += 1
	if b.n == 1 {
		b.width = width
	}
	return b.n == BATCH || u64(lo) >= b.to
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
	b.n, b.at, b.split_row, b.from, b.to = 0, 0, 0, it.pos, max(u64)
	if !b.done {
		frame(it, b)
	}
	if b.n == 0 {
		it.fault = b.fault
	}
	return b.n > 0
}

// Frames rows from `it.pos` into `b` and leaves `it.pos` past them.
@(private)
frame :: proc(it: ^records.Reader, b: ^Batch) {
	switch opts := options_of(it.as); Spec(it.as.spec) {
	case .Csv:   frame_batch(it, b, .Csv, opts)
	case .Tsv:   frame_batch(it, b, .Tsv, opts)
	case .Plain: frame_batch(it, b, .Plain, opts)
	}
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
	hi, fault, stopped := core.result_of(r, &RULES)
	if fault != nil {
		b.done, b.fault = true, fault
	} else if !stopped {
		b.done = true
	}
	// A stopped frame returns the byte past the row end it stopped on. A restart reads no header.
	it.pos = hi
	// A span reads no header's cells.
	if first && b.head.hi > b.head.at && b.to == max(u64) {
		src, head := it.src, b.head
		b.key_src, b.head_at = src, it.base + head.at
		if it.input.procedure != nil {
			text, err := make([]u8, head.hi - head.at, it.allocator)
			if err != nil {
				b.done, b.fault = true, core.Fault{rules = &RULES, kind = .No_Memory}
				return
			}
			copy(text, src[head.at:head.hi])
			src, head, b.key_src = text, {0, u64(len(text)), head.lax}, text
		}
		n, _, ok := split_all(it, b, src, head, S, opts, .Key)
		keys, err := make([]core.Token, n, it.allocator)
		if !ok || err != nil {
			b.done, b.fault = true, core.Fault{rules = &RULES, kind = .No_Memory}
			return
		}
		copy(keys, b.cells[:n])
		b.keys = keys
	}
}

// Gives the next row and leaves `it.pos` at the byte past it, so a window that moves resumes from there. A batch framed
// in a window that has since moved is dropped. Before any row stands, the header is dropped too and read again, since
// the window may have cut it.
@(private)
next_row :: proc(it: ^records.Reader) -> (records.Record, bool) {
	b := (^Batch)(it.format)
	stream := it.input.procedure != nil
	if stream && b != nil {
		if b.moves == it.moves {
			// The window held after the last row, so that row stands.
			b.past ||= b.at > 0
		} else {
			b.n, b.at, b.split_row, b.done, b.fault = 0, 0, 0, false, nil
			if !b.past {
				b.width, b.head = 0, {}
				delete(b.keys, it.allocator)
				delete(b.key_src, it.allocator)
				b.keys, b.key_src = nil, nil
			}
		}
	}
	if b == nil || b.at == b.n {
		if !refill(it) {
			return {}, false
		}
		b = (^Batch)(it.format)
	}
	row := b.rows[b.at]
	b.at += 1
	if stream {
		it.pos = u64(min(int(row.hi) + 1 + int(int(row.hi) < len(it.src) && it.src[row.hi] == '\r'), len(it.src)))
		b.moves = it.moves
	}
	return {text = it.src[row.at:row.hi], at = row.at}, true
}

// Gives the rows from `it.pos` up to the first that starts at or past `to` as one record, the first row alone when it
// starts there. The frame judged them, and a fault ends the records on the next call. The width the first record sets
// is kept in `it.state[0:4]`, so a piece's reader, a copy of this one past its first record, checks rows against it.
@(private)
next_span :: proc(it: ^records.Reader, to: u64) -> (records.Record, bool) {
	b := Batch{width = int(intrinsics.unaligned_load((^u32)(&it.state[0]))), to = to}
	if to == max(u64) {
		// The rest of the text is one record, judged by the walk with no hook.
		lo := it.pos
		it.pos, it.fault = u64(len(it.src)), validate_from(it.src, it.as, lo, b.width)
		return {text = it.src[lo:], at = lo}, lo < it.pos
	}
	lo := max(u64)
	for {
		b.n = 0
		frame(it, &b)
		if b.n > 0 {
			lo = min(lo, b.rows[0].at)
			if last := b.rows[b.n - 1].at; last >= to {
				// The row the frame stopped on starts the next span, unless it is this span's first.
				it.pos = it.pos if last == lo else last
				break
			}
		}
		if b.done {
			it.fault = b.fault
			break
		}
	}
	intrinsics.unaligned_store((^u32)(&it.state[0]), u32(b.width))
	if lo == max(u64) {
		return {}, false
	}
	return {text = it.src[lo:it.pos], at = lo}, true
}

// Moves a piece's reader past the first LF from the byte before `it.pos` on, which is past the piece's first byte.
// A guess inside a quoted cell's line is never a row the in-order reading meets.
@(private)
guess_row :: proc(it: ^records.Reader, to: u64) -> bool {
	i := kernel.index_byte(it.src[it.pos - 1:to], '\n')
	it.pos = it.pos + u64(i) if i >= 0 else to
	return it.pos < to
}

// The LF outside quoted cells. A comment line or a tolerated bare quote may hold a quote that pairs with none.
@(private)
exact_row :: proc(it: ^records.Reader) -> (kernel.Quotes, bool) {
	opts := options_of(it.as)
	if Spec(it.as.spec) != .Csv {
		return {sep = '\n'}, true
	}
	return {quote = '"', sep = '\n'}, opts.comment == 0 && .Bare_Quote not_in opts.tolerate
}

// A piece past the first keeps the header and width the first record's batch read.
@(private)
piece_rows :: proc(it: ^records.Reader, lo, hi: u64) -> bool {
	it.src = it.src[:hi]
	if lo == 0 {
		return true
	}
	first := (^Batch)(it.format)
	it.pos, it.format = lo, nil
	b, err := new(Batch, it.allocator)
	if err != nil {
		return false
	}
	it.format = b
	b.head, b.width, b.head_at, b.key_src = first.head, first.width, first.head_at, first.key_src
	b.keys, err = slice.clone(first.keys, it.allocator)
	return err == nil
}

// The text and row a read or a build of `row` uses: in memory the input and `row`, on a stream the header's line then the
// row's, since the window no longer holds the header. Returns false when the join does not fit in memory.
@(private)
joined :: proc(it: ^records.Reader, b: ^Batch, row: Batch_Row) -> (src: []u8, at: Batch_Row, ok: bool) {
	if it.input.procedure == nil {
		return it.src, row, true
	}
	n, size := len(b.key_src), len(b.key_src) + int(row.hi - row.at)
	b.comb.allocator = it.allocator
	if resize(&b.comb, size) != nil {
		return nil, {}, false
	}
	copy(b.comb[:], b.key_src)
	copy(b.comb[n:], it.src[row.at:row.hi])
	return b.comb[:], {u64(n), u64(size), row.lax}, true
}

// Builds `rec`, the row `next` gave last, as a document over the whole input: a `Map` keyed by the header's cells, or an
// `Array` with no header. On a stream the document is over the header's line and the row's, which lasts until the next
// call on the reader, and its offsets count from that text.
@(private)
build_row :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	cells, ok := cells_of(it, rec)
	if !ok {
		return {}, {kind = .Bad_Index, at = rec.at}
	}
	batch := (^Batch)(it.format)
	keys := batch.keys
	row, _ := held_row(it, rec)
	src, at, joinable := joined(it, batch, row)
	if !joinable {
		return {}, {kind = .No_Memory}
	}
	b := build.builder_start(src, it.as, false, allocator, 1 + len(cells) + len(keys), 2)
	if len(b.doc.nodes) == 0 {
		return build.builder_end(&b, build.BUILDER_REGS, nil)
	}
	b.root_close = at.hi
	regs := build.BUILDER_REGS
	regs, _ = build.builder_hook_plain(&b, regs, {kind = .Map if len(keys) > 0 else .Array, role = .Value, lo = at.at})
	for t, c in cells {
		if len(keys) > 0 {
			regs, _ = build.builder_hook_plain(&b, regs, column_key(keys, c))
		}
		cell := t
		cell.spelling &~= SPELLING_DOUBLED
		cell.lo += at.at - row.at
		regs, _ = build.builder_hook_plain(&b, regs, cell)
	}
	regs, _ = build.builder_hook_plain(&b, regs, {kind = .End, lo = at.hi})
	return build.builder_end(&b, regs, nil)
}

// Reads the next row into `target`, a row type, by replaying its cells through `on_cell` as `unmarshal` reads the text
// of the header and that row. A list row reads the row alone, as it reads a header as data.
@(private)
read_row :: proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Error) -> bool {
	spec, opts := Spec(it.as.spec), options_of(it.as)
	h := Cells{refuse_repeats = read.refuse_duplicates}
	regs, started := typed.read_start(&h.r, it.src, plan, &SPELLING, T, target, read, it.frames, allocator)
	h.r.ctx.temp_allocator = runtime.arena_allocator(&it.scratch)
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
	_, ok := next_row(it)
	if !ok {
		return false
	}
	b := (^Batch)(it.format)
	row := b.rows[b.at - 1]
	src, at, joinable := joined(it, b, row)
	if !joinable {
		err^ = {kind = .Out_Of_Memory}
		return false
	}
	stream := it.input.procedure != nil
	kept := typed.collected_mark(read.collect)
	if stream {
		h.r.src, h.r.base, h.hot_end = src, raw_data(src), u64(max(len(src) - HOT_REACH, 0))
	}
	h.r.as.spec = u8(spec)
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
	regs, action = row_token(&h, regs, {kind = .Array, role = .Value, lo = at.at})
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
		regs, action = split_any(src, at, spec, opts, .Value, &h, regs, on_cell)
		if action != .Stop {
			regs, _ = row_token(&h, regs, {kind = .End, role = .Value, lo = at.hi})
		}
	}
	// A read with no refusal leaves `err` as the caller zeroed it.
	if h.r.first.kind != .None {
		err^ = typed.read_end(&h.r, regs, nil)
	}
	if stream {
		// The errors name bytes of the joined text, which the window's own bytes replace.
		place_error(it, b, row, err)
		if read.collect != nil {
			for &e in read.collect.errors[kept.errors:] {
				place_error(it, b, row, &e)
			}
		}
	}
	return true
}

// Moves the offsets of `e`, which name bytes of `joined`'s text, to the window's: the header's line is at `head_at` of
// the input, and the row's bytes are `row`'s.
@(private)
place_error :: proc(it: ^records.Reader, b: ^Batch, row: Batch_Row, e: ^core.Typed_Error) {
	place :: proc(it: ^records.Reader, b: ^Batch, row: Batch_Row, at: u64) -> u64 {
		n := u64(len(b.key_src))
		return b.head_at + at - it.base if at < n else at - n + row.at
	}
	if e.kind not_in core.TYPED_AT_NO_BYTE {
		e.at = place(it, b, row, e.at)
		if e.kind == .Walk {
			e.inner.at = place(it, b, row, e.inner.at)
		}
	}
}

@(private)
close_rows :: proc(it: ^records.Reader) {
	if b := (^Batch)(it.format); b != nil {
		delete(b.cells)
		delete(b.texts)
		delete(b.keys, it.allocator)
		if it.input.procedure != nil {
			delete(b.key_src, it.allocator)
		}
		delete(b.comb)
		delete(b.cols, it.allocator)
		free(b, it.allocator)
	}
}
