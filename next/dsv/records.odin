package dsv

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Each record past the header is framed to its line end outside a quoted cell, since a quoted cell may hold a line end.
// A record reads as an object of cells keyed by the header, or under `no_header` as an array of cells, checked against
// the header's width or the first record's. A record that faults ends at its line end, and the records go on at the
// next.

// The records of a text of a delimited spec, which `records_open` makes and each call of `records_validate`,
// `records_find` or `records_scan` reads in batches, as `tape.Records` says.
Records :: struct {
	using records: tape.Records,
	spec:          Spec,
	p:             Pass_Options,
	width:         int, // the cells every record has, 0 until the first record of a text with no header
	count:         int, // the header's cells, kept in `keys` when they fit
	refuse:        bool, // the records were opened under `.Refuse`, which their header judges and their reads take as `.Default`
	held:          []tape.Token, // the header's keys the batch being read gives each record's cells
	keys:          [FRAME_KEYS]tape.Token,
	// What the header's keys index: the text, or in a text in pieces a copy of the header's bytes, from `head_lo`.
	head:          []u8,
	head_lo:       u64,
	// In a text in pieces, where the framing stopped at the last window's end: `open` once the record at `pos` has begun,
	// with what `scan` has read of it so far, and `started` once the text's opening is read.
	frame:         Frame_At,
	scan:          Record_Scan,
	open:          bool,
	started:       bool,
}

// Opens the records of `src`, a text of `spec`, each record read under `opts`. Only `.Lines` frames a delimited text,
// a record per line outside a quoted cell. The budget's limits hold for each record. A refused option, or a header that
// faults, ends the records before any is read. A text in pieces opens with its first window, as `tape.Records` says,
// and its header is read once a window holds its line: at open, as for a whole text, when the first window does.
records_open :: proc(src: []u8, framing := tape.Framing.Lines, spec := Spec.Csv, opts := Options{}) -> (r: Records) {
	if spec > max(Spec) {
		panic("dsv: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts = src, framing, spec, opts
	if r.opts.dups == .Refuse {
		r.refuse, r.opts.dups = true, .Default
	}
	err: tape.Error
	switch spec {
	case .Csv:
		err = records_start(&r, .Csv)
	case .Tsv:
		err = records_start(&r, .Tsv)
	case .Plain:
		err = records_start(&r, .Plain)
	}
	if err == nil && framing != .Lines {
		err = tape.Bad_Option{"framing"}
	}
	if err != nil {
		r.err, r.at = err, .Done
	}
	return
}

// Reads the options and the header of `r`, and places it at its first record.
@(private)
records_start :: proc(r: ^Records, $S: Spec) -> tape.Error {
	r.p = pass_options(S, r.opts) or_return
	if r.opts.pieces != nil {
		r.src = tape.piece_src(r.src, r.opts.pieces.from)
		return records_header_window(r, S)
	}
	r.head = r.src
	r.pos = text_start(r.src, 0)
	if r.p.no_header {
		return nil
	}
	r.count = header_cells(r.src, S, r.p.delim, r.p.comment)
	if r.count == 0 {
		r.at = .Done
		return nil
	}
	ctx := context
	keys := header_keys(r.count, r.keys[:], context.allocator, &ctx) or_return
	defer if len(keys) > FRAME_KEYS {
		delete(keys)
	}
	err: tape.Error
	r.pos, r.width, err = read_header(r.src, S, r.p, keys)
	if err == nil && r.refuse {
		err = records_names(r, S, r.src, keys, context.allocator)
	}
	return err
}

// The fault of a repeated name among the header's `keys`, cells of `src`, of records opened under `.Refuse`.
@(private, cold)
records_names :: proc(r: ^Records, $S: Spec, src: []u8, keys: []tape.Token, allocator: runtime.Allocator) -> tape.Error {
	at, found, oom := header_repeat(src, S, keys, allocator)
	if oom != nil {
		return oom
	}
	return tape.Fault{at = at, rules = &RULES, kind = .Duplicate_Key} if found else nil
}

// Reads the header of the records `r` of a text in pieces once a window holds its line, its keys into `keys`, or past
// `FRAME_KEYS` into the list `Pieces.state` holds, and its bytes into a copy there, and places the records at their
// first. While the window holds too little, fewer than a byte order mark's bytes or not the header's line end, the
// records stay at their start, and the next window goes on framing the header where this one stopped. The window
// starts the text, since records at their start keep its first byte.
@(private, cold)
records_header_window :: proc(r: ^Records, $S: Spec) -> tape.Error {
	p := r.opts.pieces
	more := !p.last
	if more && len(r.src) < 3 {
		return nil
	}
	if !r.started {
		r.frame.i, r.started = int(text_start(r.src, 0)), true
		r.pos = u64(r.frame.i)
	}
	if r.p.no_header {
		r.at = .Open
		return nil
	}
	lo, _, ok := frame_window(r, S, more)
	if !ok {
		return nil
	}
	r.at = .Open
	hi := min(r.scan.line_end + 1, len(r.src))
	r.count, r.width = r.scan.cells, r.scan.cells
	s, lists := piece_open_state(p) or_return
	keys := r.keys[:min(r.count, FRAME_KEYS)]
	if r.count > FRAME_KEYS {
		resize(&s.keys, r.count) or_return
		keys = s.keys[:]
	}
	err := walk_header(r.src[:hi], S, r.p, keys)
	append(&s.head, ..r.src[lo:hi]) or_return
	r.head, r.head_lo = tape.piece_src(s.head[:], lo), lo
	if err == nil && r.refuse {
		err = records_names(r, S, r.head, keys, lists)
	}
	return err
}

// Frames the next record of the records `r` of a text in pieces, going on where the last window's framing stopped, so
// no byte is framed twice. While `more` bytes follow the window, a record whose line end the window does not hold is
// left open, at `pos`, for the next window. False with no record, the records ended when the text has.
@(private, cold)
frame_window :: proc(r: ^Records, $S: Spec, more: bool) -> (lo, cut: u64, ok: bool) {
	f := &r.frame
	n := len(r.src)
	if !r.open {
		from := f.i
		found: bool
		if more {
			found = record_start_on(r.src, f, r.p.comment, true)
		} else {
			found = record_start_on(r.src, f, r.p.comment, false)
		}
		if r.p.comment != 0 && !skipped_judged(r, from - f.pending, more) {
			return
		}
		r.pos = u64(f.i - f.pending)
		if !found {
			if !more {
				r.at = .Done
			}
			return
		}
		r.open, r.scan, f.quoted, f.first = true, {cells = 1, wide_at = -1}, false, true
	}
	ended: bool
	if more {
		ended = scan_record_on(r.src, int(r.pos), 0, S, r.p.delim, &r.scan, f, true, true)
	} else {
		ended = scan_record_on(r.src, int(r.pos), 0, S, r.p.delim, &r.scan, f, false, true)
	}
	if !ended {
		return
	}
	lo = r.pos
	f.i = min(r.scan.line_end + 1, n)
	r.open, r.pos = false, u64(f.i)
	return lo, u64(r.scan.line_end_lo), true
}

// A hook that stops at the first token past the text's opening, once the walk has read the header's keys.
@(private)
Header_Stop :: struct {
	seen:     bool,
	protocol: hook.Protocol({}, hook.Unused, hook.Unused, hook.Unused),
}

@(private)
header_stop :: proc "contextless" (h: ^Header_Stop, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if h.seen {
		return s, .Stop
	}
	h.seen = true
	return s, .Next
}

// Reads the header of `src` into `keys`, which hold its cells, and returns the byte past it, where the first record may
// start, and its width, or the fault in it.
@(private)
read_header :: proc(src: []u8, $S: Spec, p: Pass_Options, keys: []tape.Token) -> (hi: u64, width: int, err: tape.Error) {
	at := record_start(src, int(text_start(src, 0)), p.comment)
	s := scan_record(src, at, 0, S, p.delim)
	hi = u64(min(s.line_end + 1, len(src)))
	return hi, s.cells, walk_header(src[:hi], S, p, keys)
}

// Walks `src`, a text up to its header's end, for the header's keys into `keys`, which hold its cells, and returns the
// fault in it.
@(private)
walk_header :: proc(src: []u8, $S: Spec, p: Pass_Options, keys: []tape.Token) -> tape.Error {
	h: Header_Stop
	regs: hook.Regs
	head := Head{keys = keys}
	ctx := context
	// The depth budget is judged by the records' walks, not by the header's.
	hp := p
	hp.limit = max(u64)
	_, err, _ := walk_text(src, S, false, hp, &h, &regs, context.allocator, &ctx, header_stop, &head)
	return err
}

// Holds the header's keys for a batch of `r` in `held`: its own, or for a header past `FRAME_KEYS` cells a block of
// `allocator` read again from the text, which `records_release` frees, or the keys of the text's pieces, which it does
// not. In pieces it first reads the header from the first window. False, with the records ended, when the block is
// refused or the header is.
@(private)
records_hold :: proc(r: ^Records, $S: Spec, allocator: runtime.Allocator) -> bool {
	if r.err != nil {
		build.records_window_end(r)
		return false
	}
	if r.at == .Start && r.opts.pieces != nil {
		if err := records_header_window(r, S); err != nil {
			r.err, r.at = err, .Done
			build.records_window_end(r)
			return false
		}
	}
	if p := r.opts.pieces; p != nil && r.count > FRAME_KEYS {
		r.held = (^Piece)(p.state).keys[:]
		return true
	}
	ctx := context
	keys, err := header_keys(r.count, r.keys[:], allocator, &ctx)
	if err == nil && len(keys) > FRAME_KEYS {
		if _, _, err = read_header(r.head, S, r.p, keys); err != nil {
			delete(keys, allocator)
		}
	}
	if err != nil {
		r.err, r.at = err, .Done
		build.records_window_end(r)
		return false
	}
	r.held = keys
	return true
}

@(private)
records_release :: proc(r: ^Records, allocator: runtime.Allocator) {
	if r.count > FRAME_KEYS && r.opts.pieces == nil {
		delete(r.held, allocator)
	}
	r.held = nil
}

// Reads the next records of `r` into `out` and judges each. Returns how many it filled. Fewer than `len(out)` means
// the records have ended, and `err` says why, nil at the text's end.
@(require_results)
records_validate :: proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> (n: int) {
	switch r.spec {
	case .Csv:
		return records_validate_as(r, out, .Csv, allocator)
	case .Tsv:
		return records_validate_as(r, out, .Tsv, allocator)
	case .Plain:
		return records_validate_as(r, out, .Plain, allocator)
	}
	return
}

// Reads the next records of `r` into `out`, and for each the first value `path` reaches in it into the same place of
// `answers`. Returns how many it filled, as `records_validate` does.
@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	switch r.spec {
	case .Csv:
		return records_find_as(r, path, out, answers, .Csv, read, allocator)
	case .Tsv:
		return records_find_as(r, path, out, answers, .Tsv, read, allocator)
	case .Plain:
		return records_find_as(r, path, out, answers, .Plain, read, allocator)
	}
	return
}

// Reads the next records of `r` into `out`, and for each the document of its nodes the paths of `demand` reach into the
// same place of `docs`. Returns how many it filled, as `records_validate` does.
@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	switch r.spec {
	case .Csv:
		return records_scan_as(r, demand, out, docs, .Csv, read, allocator)
	case .Tsv:
		return records_scan_as(r, demand, out, docs, .Tsv, read, allocator)
	case .Plain:
		return records_scan_as(r, demand, out, docs, .Plain, read, allocator)
	}
	return
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		if r.opts.budget.steps != 0 {
			return record_walked(container_of(r, Records, "records"), S, true, lo, cut, h, regs, a, ctx, hook.no_hook)
		}
		return record_walked(container_of(r, Records, "records"), S, false, lo, cut, h, regs, a, ctx, hook.no_hook)
	}
	if !records_hold(r, S, caller) {
		return 0
	}
	defer records_release(r, caller)
	return build.records_validate(r, out, &RULES, caller, frame, walk)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		if r.opts.budget.steps != 0 {
			return record_walked(container_of(r, Records, "records"), S, true, lo, cut, h, regs, a, ctx, build.finder_hook)
		}
		return record_walked(container_of(r, Records, "records"), S, false, lo, cut, h, regs, a, ctx, build.finder_hook)
	}
	if !records_hold(r, S, caller) {
		return 0
	}
	defer records_release(r, caller)
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, tape.number_respell, nil, frame, walk)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		if r.opts.budget.steps != 0 {
			return record_walked(container_of(r, Records, "records"), S, true, lo, cut, h, regs, a, ctx, build.scanner_hook)
		}
		return record_walked(container_of(r, Records, "records"), S, false, lo, cut, h, regs, a, ctx, build.scanner_hook)
	}
	if !records_hold(r, S, caller) {
		return 0
	}
	defer records_release(r, caller)
	return build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, nil, node_bound, frame, walk)
}

// The next record's first byte and its end, its line end less a CR, past which the walk does not read. False once the
// records have ended.
@(private)
record_frame :: proc(r: ^Records, $S: Spec) -> (lo, cut: u64, ok: bool) {
	if r.at == .Done {
		return
	}
	if p := r.opts.pieces; p != nil {
		return record_frame_window(r, S, p)
	}
	lo = u64(record_start(r.src, int(r.pos), r.p.comment))
	if lo != r.pos && r.p.comment != 0 && !skipped_judged(r, int(r.pos), false, int(lo)) {
		return
	}
	if lo >= u64(len(r.src)) {
		r.at = .Done
		return
	}
	end, end_lo := frame_line(r.src, int(lo), S, r.p.delim)
	r.pos = u64(min(end + 1, len(r.src)))
	return lo, u64(end_lo), true
}

// Judges the UTF-8 of the lines `record_frame` skipped from `from`, as a walk of the whole text judges a comment line's
// bytes. False, with the records ended by the fault, when one is ill-formed. In a window whose text goes on, a sequence
// the window cuts is judged by the next window, which holds its first bytes since `Frame_At.pending` counts them.
@(private, cold)
skipped_judged :: proc(r: ^Records, from: int, more: bool, to := -1) -> bool {
	f := &r.frame
	to := to if to >= 0 else f.i
	f.pending = 0
	at, k := first_ill_formed(raw_data(r.src), from, to, len(r.src))
	switch {
	case k == .None:
		return true
	case k == .Truncated && more && to == len(r.src):
		f.pending = to - at
		return true
	case k == .Truncated:
		at = len(r.src)
	}
	detail := Detail.Cut_Utf8 if k == .Truncated else .Invalid_Utf8
	r.err, r.at = tape.Fault{at = u64(at), rules = &RULES, kind = .Truncated if k == .Truncated else .Bad_Char, detail = u8(detail)}, .Done
	return false
}

// `record_frame` in a text in pieces: a record whose line end the window does not hold ends the batch, and its framing
// goes on in the next window.
@(private, cold)
record_frame_window :: proc(r: ^Records, $S: Spec, p: ^tape.Pieces) -> (lo, cut: u64, ok: bool) {
	if r.at == .Start {
		// The header is not read yet, which `records_hold` reads once a window holds it.
		return
	}
	return frame_window(r, S, !p.last)
}

// A record walk's fault `res` that ends in a cut UTF-8 sequence becomes an ill-formed one when the text goes on past the
// record, as the walk of the whole text finds the sequence's lead out of place.
@(private, cold)
cut_sequence_judged :: #force_no_inline proc(r: ^Records, res: hook.Walk_Result, lo, cut: u64) -> hook.Walk_Result {
	if Detail(u64(res) >> 8) == .Cut_Utf8 && cut < u64(len(r.src)) {
		return fault_at(u64(sequence_lead(raw_data(r.src), int(lo), int(cut))), .Bad_Char, .Invalid_Utf8)
	}
	return res
}

// Walks the record from `lo` to `cut` as the root of a text of its bytes, its cells keyed by the header's, and keeps
// the width the first record sets.
@(private)
record_walked :: #force_inline proc(r: ^Records, $S: Spec, $LAX: bool, lo, cut: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	w: Pass(S, H, LAX, C)
	pass_start(&w, int(cut), h, r.p, r.opts.budget.steps)
	w.width, w.opened, w.unclosed, w.keys = r.width, true, true, r.held
	if r.opts.pieces != nil {
		when H == build.Finder {
			h.key_text = r.head
		} else when H == build.Scanner {
			h.key_text, h.head = r.head, {r.head_lo, u64(len(r.head))}
		}
	}
	// The record is the root, one level above where it lies in a text.
	p := r.p
	p.limit += 1
	res := steps_ended(&w, run(&w, r.src[:cut], lo, p, regs, on))
	if u8(res) == u8(tape.Fault_Kind.Truncated) {
		res = cut_sequence_judged(r, res, lo, cut)
	}
	if r.width == 0 {
		if u8(res) == 0 {
			r.width = w.width
		} else if u8(res) == hook.WALK_STOPPED {
			// A walk stopped at its answer did not count the record's cells.
			r.width = scan_record_clipped(r.src, int(lo), 0, S, r.p.delim).cells
		}
	}
	return {res = res, hi = cut, tolerated = w.tolerated, ok = true}
}
