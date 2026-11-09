// A text that holds a list of records, read one record at a time for every format: `open`, then `next` until it
// returns false, then `it.fault`. A format gives its services through the `as` value, so the calls name no format.
// See `docs/records.md`.
package records

import "base:runtime"
import "core:io"
import "core:strings"
import core ".."
import "../kernel"
import engine "../build"
import typed "../typed"
import cw "../write"

// One record of the input. `text` is its bytes in the input and `at` the offset of its first byte from the input's
// first byte. `key` is the key of an object member under `.Entries`, as written, and nil otherwise.
Record :: struct {
	text: []u8,
	key:  []u8,
	at:   u64,
}

// Reads the records of `src`, or those of a stream through a window of it in `src`. `open` or `open_stream` makes
// one, and `close` frees what it allocated. A reader is not copied, since a copy and the original would free the same
// memory, and the plans it reads by outlive it.
Reader :: struct {
	// The text, or on a stream a window of `buf` that ends on a whole record.
	src:       []u8,
	// The byte of `src` the next record is looked for from.
	pos:       u64,
	// The byte the records start at.
	from:      u64,
	// The byte at or past which a piece's reader of `each` gives no record, set by the format's `piece` when it keeps
	// the text past it, and 0 for none.
	to:        u64,
	as:        core.As,
	services:  ^Services,
	// The typed reads' open containers, allocated with `allocator` by the first.
	frames:    []typed.Frame,
	// The plan of the last type a read with no plan took, built with `allocator`.
	plan:      ^typed.Plan,
	// The memory a format keeps for its framing.
	format:    rawptr,
	allocator: runtime.Allocator,
	// The fault that ended the records, nil when the input ended.
	fault:     Maybe(core.Fault),
	framing:   core.Framing,
	// Whether the records start where the format's `guess` placed them, so a fault ends them with no search for its place.
	guessed:   bool,
	// The format's own state, which a copy of the reader takes along and a record read again restores with `pos`.
	state:     [8]u8,
	// A stream's input, read into `buf`, whose first of `filled` bytes is the byte before the unread ones, so no
	// window but the input's first starts a record at its offset 0.
	input:     io.Reader,
	buf:       []u8,
	filled:    int,
	max_bytes: int,
	// The input offset of `src[0]`.
	base:      u64,
	// Whether the window holds the input's end.
	last:      bool,
	// Whether `input` ended, and the error it failed with.
	eof:       bool,
	cause:     io.Error,
	// The bytes past the last whole record when the input ended inside a record or failed, and their offset.
	held:      []u8,
	held_at:   u64,
	// The window's moves and the times `pos` came back to a record the window could not tell, so a format that keeps
	// a frame between calls sees it is stale.
	moves:     u64,
	// What `scan` keeps, allocated at its first call.
	scan:      ^Scanned,
	// The temp allocator of the format's `read`, emptied by the next, so what one record's read binds or decodes for
	// itself takes no memory past it.
	scratch:   runtime.Arena,
}

// What `scan` keeps between records: the planned read, the document it returned last, and that document's answers
// when a query gave them.
@(private)
Scanned :: struct {
	h:       engine.Scan,
	last:    core.Document,
	answers: []core.Answer,
}

// `max_bytes` is the most bytes past the last whole record a stream's window holds, 0 for no limit. When they hold no
// whole record, the records end with the fault `.Too_Wide` and code `records.too_long`.
Stream_Options :: struct {
	max_bytes: int,
}

// The `core.Fault.detail` values the records' faults use.
@(private)
Detail :: enum u8 {
	None,
	Too_Long, // `Too_Wide`, a record past `max_bytes`
}

// The records' rules, indexed by `Detail`.
@(rodata)
RULES := core.Rules{"records", {{}, {"too_long", "Record is longer than the limit"}}}

// A format's record services, in its rodata, which `core.Spelling.records` points at.
Services :: struct {
	// Frames the next record under each framing the format takes, nil for one it does not, and returns false at the
	// input's end or on a fault, which it stores in `it.fault`.
	next:   [core.Framing]proc(it: ^Reader) -> (Record, bool),
	// The fault of a record `next` gave, or nil, as the format's validate of the record's text at its place says.
	judge:  proc(it: ^Reader, rec: Record) -> Maybe(core.Fault),
	// Moves a copy of a reader to the first place at or past its `pos` and before `to` where a record may start, and
	// marks it as a piece's, whose `next` may end on any fault with no cost to find the one `validate` gives. Returns
	// false when there is none. nil reads a text on the calling thread alone.
	guess:  proc(it: ^Reader, to: u64) -> bool,
	// Frames the records from `it.pos` up to the first that starts at or past `to` as one record, judged as `next`
	// judges them, the first alone when it starts there, and with `to` `max(u64)` the rest of the text. `check` and
	// `validate_parallel` take it in place of `next`. nil frames each record alone.
	span:   proc(it: ^Reader, to: u64) -> (Record, bool),
	// The scan whose cuts, a byte past a separator it finds from the end of an open reader's first record, are each the
	// end of a record and the start of the next, and false when the format has none under the reader's framing or
	// options.
	exact:  proc(it: ^Reader) -> (kernel.Quotes, bool),
	// Makes a copy of a reader past its first record, or a new reader for `lo` 0, read the records from the cut `lo` up
	// to the cut or text end `hi`, and returns false when its memory is refused.
	piece:  proc(it: ^Reader, lo, hi: u64) -> bool,
	// `next` and a read of `path` in the record by one walk, into `last`, a document whose text is the input up to the
	// record's end. It starts `h` at the first call, and then with `engine.scan_again` while `h.again` is set, which
	// writes the buffers `last` shares with the builder. nil reads a record as `next` gives it.
	scan:   proc(it: ^Reader, h: ^engine.Scan, last: ^core.Document, path: core.Path, read: core.Path_Options) -> (Record, core.Path_Error, bool),
	// The format, framing and offset whose records make up the whole of `src`, for `validate_parallel`, nil for a format that
	// does not take it.
	whole:  proc(src: []u8, as: core.As) -> (core.As, core.Framing, u64),
	// `next` and a typed read of the record into `target`, a `T`, whose typed reader takes `it.scratch` as its temp
	// allocator.
	read:   proc(it: ^Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Error) -> bool,
	// Builds a record's document.
	build:  proc(it: ^Reader, rec: Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error),
	// `next`, and the record's nodes written to `b` by the walk that frames it, with the offsets of `it.src`. nil for a
	// format whose whole text `build` reads on one thread.
	build_next: proc(it: ^Reader, b: ^engine.Builder, regs: ^core.Hook_Regs) -> (Record, bool),
	// A format's with named columns, nil for another.
	column: proc(it: ^Reader, name: string) -> int,
	cell:   proc(it: ^Reader, rec: Record, column: int, buf: []u8) -> (string, bool),
	cells:  proc(it: ^Reader, rec: Record, buf: []u8, upto: int) -> ([]cw.Scalar, bool),
	// Frees `it.format`, nil for a format that keeps none.
	close:  proc(it: ^Reader),
	// The byte that ends a record under each framing where a backward scan for it finds the end of a whole record, and 0
	// where only a walk of the records does.
	ends:   [core.Framing]u8,
}

// Opens the records of `src` in format `as` under `framing`, from byte `at` of `src`, with every offset from `src[0]`.
// The reader's own memory comes from `allocator`. A UTF-8 byte order mark at the input's first byte is passed over. A
// format with no record reader, or one that does not take `framing`, ends the records with the fault `.Bad_Option`
// before any is read.
open :: proc(src: []u8, as: core.As, framing := core.Framing.Lines, at: u64 = 0, allocator := context.allocator) -> Reader {
	it := Reader{src = src, pos = core.text_start(src, at), from = at, as = as, framing = framing, allocator = allocator}
	it.services = (^Services)(as.spelling.records) if as.spelling != nil else nil
	if it.services == nil || it.services.next[framing] == nil || at > u64(len(src)) {
		it.fault = core.Fault{kind = .Bad_Option}
	}
	return it
}

// Opens the records `input` gives, as `open` opens them in memory, through a window that grows by doubling up to
// `opts.max_bytes`. `input`'s first byte is the input's byte `at`. A record's text lasts until the next call on the
// reader. Under `.Entries` the whole input is read first.
open_stream :: proc(input: io.Reader, as: core.As, framing := core.Framing.Lines, opts := Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> Reader {
	it := open(nil, as, framing, 0, allocator)
	it.input, it.base = input, at
	it.max_bytes = opts.max_bytes if opts.max_bytes > 0 else max(int) - 1
	return it
}

// Returns the next record, or false at the input's end or on a fault in `it.fault`. Under `.Lines` and `.Seq` in JSON
// it only frames: a record's fault comes from what reads its text.
next :: #force_inline proc(it: ^Reader) -> (Record, bool) {
	if it.fault != nil {
		return {}, false
	}
	if it.input.procedure != nil {
		return stream_next(it)
	}
	if it.services == nil {
		it.fault = core.Fault{kind = .Bad_Option}
		return {}, false
	}
	return it.services.next[it.framing](it)
}

// Reads the next record into `target` by `plan`, as the format's `unmarshal` of the record's text reads it, with every
// offset from the input's first byte, so `for err in read(&it, &v, &plan)` reads every record. A nil `plan` is one
// `typed.plan_make` builds from `it.as`, which the reader keeps for the next read of the same type. Returns false at
// the input's end and after a fault in `it.fault`. A refused record returns its error and true, and the next read goes
// on after it. An error that ends the records also returns true, and sets `it.fault` when no fault of the text did:
// `.Plan_Mismatch` when `plan` is no plan of `T` by the format, the plan's own error when it failed, `.No_Memory` when
// the reader's memory is refused. When a refused record's value runs past its end, `target` may hold values read past
// it. A name the read decoded for `err`, and a stream's source text in it, lasts until the next call on `it`, and one
// in a collected error as long as the caller's temp allocator.
read :: proc(it: ^Reader, target: ^$T, plan: ^typed.Plan, opts := typed.Read_Options{}, allocator := context.allocator) -> (err: core.Error, more: bool) {
	refusal: core.Typed_Error
	more, refusal = read_record(it, target, plan, opts, allocator)
	if !more && refusal.kind != .None {
		if it.fault == nil {
			it.fault = core.Fault{kind = .No_Memory if refusal.kind == .No_Memory else .Bad_Option}
		}
		more = true
	}
	return core.error_of(refusal), more
}

@(private)
read_record :: proc(it: ^Reader, target: ^$T, plan: ^typed.Plan, opts: typed.Read_Options, allocator: runtime.Allocator) -> (more: bool, err: core.Typed_Error) {
	if it.fault != nil {
		return false, {}
	}
	plan := plan
	if plan == nil {
		if it.plan == nil || it.plan.type != T {
			if refusal := reader_plan(it, T); refusal != nil {
				// A plan is refused as a `Typed_Error`, or for memory.
				err = {kind = .No_Memory}
				if typed_refusal, is_typed := refusal.(core.Typed_Error); is_typed {
					err = typed_refusal
				}
				return false, err
			}
		}
		plan = it.plan
	}
	if plan.spelling != it.as.spelling || plan.type != T {
		return false, typed.plan_mismatch(plan, it.as.spelling, T)
	}
	if it.frames == nil {
		// A stream's window moves, so a record may be as long as the stream's bound. A record that nests deeper under a
		// raised `max_depth` grows its own frames on the heap.
		bound := len(it.src) if it.input.procedure == nil else it.max_bytes
		frames, failed := make([]typed.Frame, min(core.reserve_depth(it.as.max_depth, bound), core.MAX_DEPTH) + 2, it.allocator)
		if failed != nil {
			return false, {kind = .No_Memory}
		}
		it.frames = frames
		it.scratch = {backing_allocator = it.allocator, minimum_block_size = 4096}
	}
	if it.scratch.total_used != 0 {
		runtime.arena_free_all(&it.scratch)
	}
	kept := typed.sink_mark(opts.sink)
	if it.input.procedure == nil {
		more = it.services.read(it, target, T, plan, opts, allocator, &err)
	} else {
		// A record the window cannot tell yet is read again after a refill, so what its first read collected and wrote
		// goes. The restore is shallow, so what a first read allocated for `target` stays allocated.
		before := target^
		for {
			if it.src == nil && (it.eof || !window_move(it)) {
				return false, {}
			}
			pos, state := it.pos, it.state
			err = {}
			more = it.services.read(it, target, T, plan, opts, allocator, &err)
			if settle_window(it, more, pos, state) {
				break
			}
			typed.sink_restore(opts.sink, kept)
			target^ = before
			if !window_move(it) {
				return false, {}
			}
		}
		core.move_typed_error(&err, it.base)
	}
	if opts.sink != nil {
		keep_collected(it, opts.sink, kept.errors)
	}
	return
}

// Replaces the reader's plan with one of `T`.
@(private)
reader_plan :: proc(it: ^Reader, T: typeid) -> core.Error {
	drop_plan(it)
	made, err := typed.plan_make(T, it.as, allocator = it.allocator)
	if err != nil {
		return err
	}
	p, failed := new(typed.Plan, it.allocator)
	if failed != nil {
		typed.plan_destroy(&made)
		return failed
	}
	p^ = made
	it.plan = p
	return nil
}

@(private)
drop_plan :: proc(it: ^Reader) {
	if it.plan != nil {
		typed.plan_destroy(it.plan)
		free(it.plan, it.allocator)
		it.plan = nil
	}
}

// Moves the offsets of the errors `c` collected past `from` by the window's base, and copies their names that lie in
// the reader's scratch, and a stream's source text, to the temp allocator, where a collected error's decoded names live.
@(private)
keep_collected :: proc(it: ^Reader, c: ^typed.Sink, from: int) {
	for &e in c.errors[from:] {
		core.move_typed_error(&e, it.base)
		if it.input.procedure != nil && (e.kind == .Wrong_Kind || e.kind == .Out_Of_Range || e.kind == .Not_A_Member) {
			e.want.text = strings.clone(e.want.text, context.temp_allocator) or_else ""
		}
		for &s in e.steps[:e.n_steps] {
			name, named := s.(core.Name)
			for b := it.scratch.curr_block; named && b != nil; b = b.prev {
				if uintptr(raw_data(name)) - uintptr(b.base) < uintptr(b.used) {
					s = core.Name(strings.clone(string(name), context.temp_allocator) or_else "")
					break
				}
			}
		}
	}
}

// Reads the next record and the answers of `path` in it, as `scan` of `core/build` reads the record's text, into a
// document that lives until the next call on `it`, with every offset in an error from the input's first byte. The path
// is planned at the first call, and every call passes the same `path` and `read`. Returns false at the input's end, on
// a fault in `it.fault`, or when the reader's memory is refused. A record whose text does not read returns true and its
// error, and the next read goes on after it. A stream, and a format with no `scan` service, build the record and
// query it, where `read.stop_early` and `.Refuse` do not apply.
scan :: proc(it: ^Reader, path: core.Path, read := core.Path_Options{}) -> (rec: Record, doc: core.Document, err: core.Error, more: bool) {
	if it.fault != nil {
		return
	}
	if it.scan == nil {
		failed: runtime.Allocator_Error
		if it.scan, failed = new(Scanned, it.allocator); failed != nil {
			return {}, {}, failed, false
		}
	}
	s := it.scan
	if it.services != nil && it.services.scan != nil && it.input.procedure == nil {
		walked, refusal, ok := it.services.scan(it, &s.h, &s.last, path, read)
		// A record that fails before its walk leaves `last` and its buffers for the next.
		return walked, s.last if refusal.kind == .None else {}, core.error_of(refusal), ok
	}
	core.destroy(&s.last)
	delete(s.answers, it.allocator)
	s.answers = nil
	if rec, more = next(it); more {
		if s.last, err = build(it, rec, it.allocator); err == nil {
			s.answers, err = core.query(&s.last, path, {dups = read.dups}, it.allocator)
			s.last.answers = s.answers
		}
	}
	return rec, s.last, err, more
}

// Builds the document of `rec`, a record `next` gave, as the format's `build` of its text does, with every offset in
// an error from the input's first byte. The nodes' offsets index the document's `src`, which is JSON's record text and
// dsv's input. A streamed record's document lives until the next call on `it`.
@(private)
build_record :: proc(it: ^Reader, rec: Record, allocator := context.allocator) -> (core.Document, core.Error) {
	if it.services == nil || it.services.build == nil {
		return {}, core.error_of(core.Document_Error{kind = .Bad_Index})
	}
	doc, err := it.services.build(it, rec, allocator)
	return doc, core.error_of(err)
}

// Returns the index of the first column `name` names, or -1 when none does or the format has no named columns. It may
// read the first records, which `next` then gives.
column :: proc(it: ^Reader, name: string) -> int {
	if it.fault != nil || it.services == nil || it.services.column == nil {
		return -1
	}
	return it.services.column(it, name)
}

// Returns the text of cell `column` of `rec`, the record `next` gave last, decoded into `buf` when it must be, and false
// when the record has no such cell, `buf` is too short, or the format has no cells, and on an allocation failure, as
// `cells`.
cell :: proc(it: ^Reader, rec: Record, column: int, buf: []u8) -> (string, bool) {
	if it.services == nil || it.services.cell == nil {
		return "", false
	}
	return it.services.cell(it, rec, column, buf)
}

// Returns the cells of `rec`, the record `next` gave last, or its first `upto`, as `write_cells` takes them: nil for an
// empty unquoted cell, a string for a text, and under the handle's `infer` an unquoted number, `true` or `false` as
// that kind. They last until the next call on `it`. A text that must be decoded takes the
// front of `buf`, which holds what the record's decoded cells need. Returns false for another record, a `buf` too
// short, or a format with no cells, and on an allocation failure, which ends the records with `.No_Memory` in
// `it.fault`.
cells :: proc(it: ^Reader, rec: Record, buf: []u8, upto := max(int)) -> ([]cw.Scalar, bool) {
	if it.services == nil || it.services.cells == nil {
		return nil, false
	}
	return it.services.cells(it, rec, buf, upto)
}

// Frees what the reads of `it` allocated.
close :: proc(it: ^Reader) {
	if it.services != nil && it.services.close != nil {
		it.services.close(it)
	}
	if it.scan != nil {
		core.destroy(&it.scan.last)
		delete(it.scan.answers, it.allocator)
		if it.scan.h.again {
			engine.scan_free(&it.scan.h, it.allocator)
		}
		free(it.scan, it.allocator)
	}
	drop_plan(it)
	delete(it.frames, it.allocator)
	delete(it.buf, it.allocator)
	runtime.arena_destroy(&it.scratch)
	it^ = {}
}

// Returns the next window of whole records, with the gaps between them, and the input offset of its first byte, or
// false when the records end. A reader on text in memory gives the text past `pos` as one window. Under `.Entries` the
// window is the whole input. Under a framing with an end byte, the last window holds the bytes past the last end byte,
// whole or not, as the window's reader judges them.
next_window :: proc(it: ^Reader) -> (window: []u8, base: u64, ok: bool) {
	stream := it.input.procedure != nil
	for it.fault == nil {
		if it.src == nil && (!stream || it.eof || !window_move(it, hold_cut = false)) {
			return
		}
		lo := it.pos
		if !stream || it.services.ends[it.framing] != 0 || it.framing == .Entries {
			it.pos = u64(len(it.src))
		} else {
			for {
				pos, state := it.pos, it.state
				_, more := it.services.next[it.framing](it)
				if !settle_window(it, more, pos, state) || !more {
					break
				}
			}
		}
		if it.pos > lo {
			return it.src[lo:it.pos], it.base + lo, true
		}
		if !stream || !window_move(it, hold_cut = false) {
			return
		}
	}
	return
}

// The bytes a stream asks its input for at a time.
@(private)
CHUNK :: 64 * 1024

@(private)
stream_next :: proc(it: ^Reader) -> (rec: Record, ok: bool) {
	for {
		if it.src == nil && (it.eof || !window_move(it)) {
			return {}, false
		}
		pos, state := it.pos, it.state
		rec, ok = it.services.next[it.framing](it)
		// A framing with an end byte gives only whole records, so a record it gives stands.
		if ok && it.services.ends[it.framing] != 0 || settle_window(it, ok, pos, state) {
			rec.at += it.base
			return
		}
		if !window_move(it) {
			return {}, false
		}
	}
}

// Settles what a service answered for the record looked for from `pos`, and returns true when it stands. While more
// input may come, a walked framing cannot tell a fault within `core.FAULT_REACH` bytes of the window's end, or a record
// whose framing read no byte past it, and no framing can tell the window's end from the input's. Then `pos` and `state`
// come back and it returns false. A `Truncated` at the input's end holds the bytes past the last whole record, but under
// `.Entries`, which reads as text in memory does.
@(private)
settle_window :: proc(it: ^Reader, ok: bool, pos: u64, state: [8]u8) -> bool {
	n := u64(len(it.src))
	walked := it.services.ends[it.framing] == 0
	if f, bad := it.fault.?; bad {
		if it.last && f.kind == .Truncated && f.at == n && it.framing != .Entries {
			it.held, it.held_at = it.src[pos:], it.base + pos
			it.fault, it.src, it.eof = nil, nil, true
			return true
		}
		// A `Truncated` may name a byte far back, such as an opening quote, and the next bytes may close it.
		if it.last || !walked || f.kind != .Truncated && f.at + core.FAULT_REACH <= n {
			if f.kind not_in core.AT_NO_BYTE {
				f.at += it.base
				it.fault = f
			}
			return true
		}
	} else if it.last || ok && (!walked || it.pos < n) {
		return true
	}
	// A window cut at an end byte has no record left to look for.
	if walked {
		it.pos, it.state, it.fault = pos, state, nil
		it.moves += 1
	}
	return false
}

// Moves a stream's window past the bytes read, keeping the byte before them, and reads until a window of whole records
// is found. Returns false when the records end: past the input's end, on the input's failure or, with `hold_cut`, a
// last record cut off, with the unread bytes in `held`, or on a fault.
@(private)
window_move :: proc(it: ^Reader, hold_cut := true) -> bool {
	at := it.base + it.pos
	if it.buf == nil {
		buf, failed := make([]u8, min(CHUNK, it.max_bytes) + 1, it.allocator)
		if failed != nil {
			it.fault = core.Fault{kind = .No_Memory}
			return false
		}
		it.buf, buf[0], it.filled = buf, '\n', 1
	} else {
		lo := int(uintptr(raw_data(it.src)) - uintptr(raw_data(it.buf)))
		it.filled = copy(it.buf, it.buf[lo + int(it.pos) - 1:it.filled])
	}
	it.src, it.last = nil, false
	if it.eof && it.filled == 1 {
		return false
	}
	stop := it.services.ends[it.framing]
	for {
		gained := fill(it) or_return
		if !it.eof && (gained == 0 || it.framing == .Entries) {
			if it.cause != nil {
				it.held, it.held_at, it.eof = it.buf[1:it.filled], at, true
			} else {
				it.fault = core.Fault{at = at, rules = &RULES, kind = .Too_Wide, detail = u8(Detail.Too_Long)}
			}
			return false
		}
		cut := it.filled
		if stop != 0 {
			if i := kernel.last_index_byte(it.buf[1:it.filled], stop); i >= 0 {
				cut = i + 2
			} else if !it.eof {
				continue
			}
		}
		// The input's first window has no byte before it.
		lo := 1 if at == 0 else 0
		it.src, it.base = it.buf[lo:cut], at - 1 + u64(lo)
		it.pos = core.text_start(it.src, 0) if lo == 1 else 1
		it.last = it.eof && cut == it.filled
		if it.last && stop != 0 && hold_cut {
			// The input's last record has no end byte, so it is held unless its judgement says it is whole.
			pos, state := it.pos, it.state
			rec, more := it.services.next[it.framing](it)
			fault := it.services.judge(it, rec) if more else nil
			it.pos, it.state, it.fault = pos, state, nil
			if f, bad := fault.?; bad && f.kind == .Truncated && f.at == u64(len(it.src)) {
				it.held, it.held_at = it.src[pos:], it.base + pos
				it.src, it.eof = nil, true
				return false
			}
		}
		it.moves += 1
		return true
	}
}

// Reads into a stream's buffer until it gains as many bytes as it held, or a read gains the framing's end byte, so a
// record a slow input ends is given once its end comes, or under `.Entries` the whole input, or the input ends or
// fails, or the buffer holds `max_bytes` unread bytes. The buffer doubles as it fills. Returns the bytes gained, or
// false with the fault `.No_Memory` when the buffer cannot grow.
@(private)
fill :: proc(it: ^Reader) -> (gained: int, ok: bool) {
	want := it.filled + max(it.filled - 1, 1) if it.framing != .Entries else max(int)
	stop := it.services.ends[it.framing]
	for !it.eof && it.cause == nil && it.filled < want {
		if it.filled == len(it.buf) {
			size := min(2 * len(it.buf), it.max_bytes + 1)
			if size == len(it.buf) {
				break
			}
			buf, failed := runtime.non_zero_mem_resize(raw_data(it.buf), len(it.buf), size, 1, it.allocator)
			if failed != nil {
				it.fault = core.Fault{kind = .No_Memory}
				return
			}
			it.buf = buf
		}
		n, err := io.read(it.input, it.buf[it.filled:min(len(it.buf), it.filled + CHUNK)])
		ended := stop != 0 && kernel.index_byte(it.buf[it.filled:][:n], stop) >= 0
		it.filled += n
		gained += n
		if err == .EOF {
			it.eof = true
		} else if err != nil || n == 0 {
			it.cause = err if err != nil else .No_Progress
		}
		if ended {
			break
		}
	}
	return gained, true
}
