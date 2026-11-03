// A text that holds a list of records, read one record at a time for every format: `open`, then `next` until it
// returns false, then `it.fault`. A format gives its services through the `as` value, so the calls name no format.
// See `docs/records.md`.
package records

import "base:runtime"
import "core:bytes"
import "core:io"
import core ".."
import typed "../typed"

// One record of the input. `text` is its bytes in the input and `at` the offset of its first byte from the input's
// first byte. `key` is the key of an object member under `.Entries`, as written, and nil otherwise.
Record :: struct {
	text: []u8,
	key:  []u8,
	at:   u64,
}

// Reads the records of `src`, or those of a stream through a window of it in `src`. `open` or `open_stream` makes
// one, and `close` frees what it allocated. `fault` is the fault that ended the records, nil when the input ended.
// `pos` is the byte of `src` the next record is looked for from, and `from` the byte the records start at. `state` is
// the format's own framing state, and `format` the memory a format keeps for it. `frames` are the typed reads' open
// containers, allocated with `allocator` by the first.
//
// A stream's: `input` is read into `buf`, whose first of `filled` bytes is the byte before the unread ones, so no
// window but the input's first starts a record at its offset 0. `src` is a window of `buf` that ends on a whole
// record, and `base` the input offset of `src[0]`. `last` says the window holds the input's end, `eof` that `input`
// ended, and `cause` is the error it failed with. `held` holds the bytes past the last whole record when the input
// ended inside a record or failed, and `held_at` their offset.
Reader :: struct {
	src:       []u8,
	pos:       u64,
	from:      u64,
	as:        core.As,
	services:  ^Services,
	frames:    []typed.Frame,
	format:    rawptr,
	allocator: runtime.Allocator,
	fault:     Maybe(core.Fault),
	framing:   core.Framing,
	state:     [2]u8,
	input:     io.Reader,
	buf:       []u8,
	filled:    int,
	max_bytes: int,
	base:      u64,
	last:      bool,
	eof:       bool,
	cause:     io.Error,
	held:      []u8,
	held_at:   u64,
}

// `max_bytes` is the most bytes past the last whole record a stream's window holds, 0 for no limit. When they hold no
// whole record, the records end with the fault `.Too_Long`.
Stream_Options :: struct {
	max_bytes: int,
}

// A format's record services, in its rodata, which `core.Spelling.records` points at. `next` frames the next record
// under each framing the format takes, nil for one it does not, and returns false at the input's end or on a fault,
// which it stores in `it.fault`. `judge` returns the fault of a record `next` gave, or nil, as the format's validate of
// the record's text at its place in the input says. `read` is `next` and a typed read of the record into `target`, a
// `T`. `build` builds a record's document. `column` and `cell` are a format's with named columns, nil for another, and
// `close` frees `it.format`, nil for a format that keeps none. `ends` is the byte that ends a record under each framing
// where a backward scan for it finds the end of a whole record, 0 where only a walk of the records does, and 0xff where
// the format reads no stream.
Services :: struct {
	next:   [core.Framing]proc(it: ^Reader) -> (Record, bool),
	judge:  proc(it: ^Reader, rec: Record) -> Maybe(core.Fault),
	read:   proc(it: ^Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Error) -> bool,
	build:  proc(it: ^Reader, rec: Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error),
	column: proc(it: ^Reader, name: string) -> int,
	cell:   proc(it: ^Reader, rec: Record, column: int, buf: []u8) -> (string, bool),
	close:  proc(it: ^Reader),
	ends:   [core.Framing]u8,
}

// Opens the records of `src` in format `as` under `framing`, from byte `at` of `src`, with every offset from `src[0]`.
// The reader's own memory comes from `allocator`. A UTF-8 byte order mark at the input's first byte is passed over. A
// format with no record reader, or one that does not take `framing`, ends the records with the fault `.Bad_Option`
// before any is read.
open :: proc(src: []u8, as: core.As, framing := core.Framing.Lines, at: u64 = 0, allocator := context.allocator) -> Reader {
	it := Reader{src = src, pos = core.text_start(src, at), from = at, as = as, framing = framing, allocator = allocator}
	it.services = (^Services)(as.spelling.records) if as.spelling != nil else nil
	if it.services == nil || it.services.next[framing] == nil {
		it.fault = core.Fault{kind = .Bad_Option}
	}
	return it
}

// Opens the records `input` gives, as `open` opens them in memory, through a window that grows by doubling up to
// `opts.max_bytes`. `input`'s first byte is the input's byte `at`. A record's text lasts until the next call on the
// reader. Under `.Entries` the whole input is read first. A format that reads no stream under `framing` ends the records
// with the fault `.Bad_Option`.
open_stream :: proc(input: io.Reader, as: core.As, framing := core.Framing.Lines, opts := Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> Reader {
	it := open(nil, as, framing, 0, allocator)
	it.input, it.base = input, at
	if it.fault == nil && it.services.ends[framing] == 0xff {
		it.fault = core.Fault{kind = .Bad_Option}
	}
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
	return it.services.next[it.framing](it)
}

// Reads the next record into `target` by `plan`, as the format's `unmarshal` of the record's text reads it, with every
// offset from the input's first byte. Returns false at the input's end, on a fault in `it.fault`, with `.Plan_Mismatch`
// when `plan` is no plan of `T` by the format, or with `.Out_Of_Memory` when the reader's memory is refused. A refused
// record returns true and its error, and the next read goes on after it. When a refused record's value runs past its
// end, `target` may hold values read past it.
read :: proc(it: ^Reader, target: ^$T, plan: ^typed.Plan, opts := typed.Read_Options{}, allocator := context.allocator) -> (more: bool, err: core.Typed_Error) {
	if it.fault != nil {
		return false, {}
	}
	if plan == nil || plan.spelling != it.as.spelling || plan.type != T {
		return false, {kind = .Plan_Mismatch}
	}
	if it.frames == nil {
		frames, failed := make([]typed.Frame, max(core.MAX_DEPTH, int(it.as.read.max_depth)) + 2, it.allocator)
		if failed != nil {
			return false, {kind = .Out_Of_Memory}
		}
		it.frames = frames
	}
	if it.input.procedure == nil {
		more = it.services.read(it, target, T, plan, opts, allocator, &err)
		return
	}
	// A record the window cannot tell yet is read again after a refill, so what its first read collected goes.
	kept: typed.Collected
	if opts.collect != nil {
		kept = opts.collect^
	}
	for {
		if it.src == nil && (it.eof || !window_move(it)) {
			return false, {}
		}
		pos, state := it.pos, it.state
		err = {}
		more = it.services.read(it, target, T, plan, opts, allocator, &err)
		if window_settled(it, more, pos, state) {
			break
		}
		if opts.collect != nil {
			resize(&opts.collect.errors, len(kept.errors))
			opts.collect.truncated = kept.truncated
		}
		if !window_move(it) {
			return false, {}
		}
	}
	if opts.collect != nil {
		for &e in opts.collect.errors[len(kept.errors):] {
			shift_error(&e, it.base)
		}
	}
	shift_error(&err, it.base)
	return
}

// Builds the document of `rec`, a record `next` gave, as the format's `build` of its text does, with every offset in
// an error from the input's first byte.
build :: proc(it: ^Reader, rec: Record, allocator := context.allocator) -> (core.Document, core.Document_Error) {
	return it.services.build(it, rec, allocator)
}

// Returns the index of the first column `name` names, or -1 when none does or the format has no named columns. It may
// read the first records, which `next` then gives.
column :: proc(it: ^Reader, name: string) -> int {
	if it.fault != nil || it.services.column == nil {
		return -1
	}
	return it.services.column(it, name)
}

// Returns the text of cell `column` of `rec`, the record `next` gave last, decoded into `buf` when it must be, and false
// when the record has no such cell, `buf` is too short, or the format has no cells.
cell :: proc(it: ^Reader, rec: Record, column: int, buf: []u8) -> (string, bool) {
	if it.services == nil || it.services.cell == nil {
		return "", false
	}
	return it.services.cell(it, rec, column, buf)
}

// Frees what the reads of `it` allocated.
close :: proc(it: ^Reader) {
	if it.services != nil && it.services.close != nil {
		it.services.close(it)
	}
	delete(it.frames, it.allocator)
	delete(it.buf, it.allocator)
	it^ = {}
}

// Returns the next window of whole records, with the gaps between them, and the input offset of its first byte, or
// false when the records end. A reader on text in memory gives the text past `pos` as one window. Under `.Entries` the
// window is the whole input.
next_window :: proc(it: ^Reader) -> (window: []u8, base: u64, ok: bool) {
	stream := it.input.procedure != nil
	for it.fault == nil {
		if it.src == nil && (!stream || it.eof || !window_move(it)) {
			return
		}
		lo := it.pos
		if !stream || it.services.ends[it.framing] != 0 || it.framing == .Entries {
			it.pos = u64(len(it.src))
		} else {
			for {
				pos, state := it.pos, it.state
				_, more := it.services.next[it.framing](it)
				if !window_settled(it, more, pos, state) || !more {
					break
				}
			}
		}
		if it.pos > lo {
			return it.src[lo:it.pos], it.base + lo, true
		}
		if !stream || !window_move(it) {
			return
		}
	}
	return
}

// The bytes a stream asks its input for at a time.
@(private)
CHUNK :: 64 * 1024

// The bytes past a fault's byte that its judgement may depend on: an escaped surrogate pair is 12.
@(private)
REACH :: 12

@(private)
stream_next :: proc(it: ^Reader) -> (rec: Record, ok: bool) {
	for {
		if it.src == nil && (it.eof || !window_move(it)) {
			return {}, false
		}
		pos, state := it.pos, it.state
		rec, ok = it.services.next[it.framing](it)
		if ok && it.services.ends[it.framing] != 0 || window_settled(it, ok, pos, state) {
			rec.at += it.base
			return
		}
		if !window_move(it) {
			return {}, false
		}
	}
}

// Whether what a service answered for the record looked for from `pos` stands. While more input may come, a walked
// framing cannot tell a fault within `REACH` bytes of the window's end, or a record that ends there, and no framing can
// tell the window's end from the input's. Then `pos` and `state` come back and it returns false. A `Truncated` at the
// input's end holds the bytes past the last whole record, but under `.Entries`, which reads as text in memory does.
@(private)
window_settled :: proc(it: ^Reader, ok: bool, pos: u64, state: [2]u8) -> bool {
	n := u64(len(it.src))
	walked := it.services.ends[it.framing] == 0
	if f, bad := it.fault.?; bad {
		if it.last && f.kind == .Truncated && f.at == n && it.framing != .Entries {
			it.held, it.held_at = it.src[pos:], it.base + pos
			it.fault, it.src, it.eof = nil, nil, true
			return true
		}
		if it.last || !walked || f.at + REACH <= n {
			if f.kind not_in core.AT_NO_BYTE {
				f.at += it.base
				it.fault = f
			}
			return true
		}
	} else if it.last || ok && (!walked || it.pos + REACH <= n) {
		return true
	}
	// A window cut at an end byte has no record left to look for.
	if walked {
		it.pos, it.state, it.fault = pos, state, nil
	}
	return false
}

// Moves a stream's window past the bytes read, keeping the byte before them, and reads until a window of whole records
// is found. Returns false when the records end: past the input's end, on the input's failure or a last record cut off,
// with the unread bytes in `held`, or on a fault.
@(private)
window_move :: proc(it: ^Reader) -> bool {
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
				it.fault = core.Fault{at = at, kind = .Too_Long}
			}
			return false
		}
		cut := it.filled
		if stop != 0 {
			if i := bytes.last_index_byte(it.buf[1:it.filled], stop); i >= 0 {
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
		if it.last && stop != 0 {
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
		return true
	}
}

// Reads into a stream's buffer until it gains as many bytes as it held, or under `.Entries` the whole input, or the
// input ends or fails, or the buffer holds `max_bytes` unread bytes. The buffer doubles as it fills. Returns the bytes
// gained, or false with the fault `.No_Memory` when the buffer cannot grow.
@(private)
fill :: proc(it: ^Reader) -> (gained: int, ok: bool) {
	want := it.filled + max(it.filled - 1, 1) if it.framing != .Entries else max(int)
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
		it.filled += n
		gained += n
		if err == .EOF {
			it.eof = true
		} else if err != nil || n == 0 {
			it.cause = err if err != nil else .No_Progress
		}
	}
	return gained, true
}

// Moves a typed error's offsets by `base`, for a kind that names a byte.
@(private)
shift_error :: proc(e: ^core.Typed_Error, base: u64) {
	if e.kind not_in core.TYPED_AT_NO_BYTE {
		e.at += base
		if e.kind == .Walk {
			e.inner.at += base
		}
	}
}

// Returns the fault of each refused record of `src`, in source order, and last the fault that ended the records, if
// any. The slice is allocated with `allocator`. An allocation that fails returns its error and no faults.
check :: proc(src: []u8, as: core.As, framing := core.Framing.Lines, allocator := context.allocator) -> (faults: []core.Fault, err: runtime.Allocator_Error) {
	it := open(src, as, framing)
	defer close(&it)
	out := make([dynamic]core.Fault, allocator)
	for {
		rec, more := next(&it)
		fault := it.services.judge(&it, rec) if more else it.fault
		if f, bad := fault.?; bad {
			if _, e := append(&out, f); e != nil {
				delete(out)
				return nil, e
			}
		}
		if !more {
			return out[:], nil
		}
	}
}
