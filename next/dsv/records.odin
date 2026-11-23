package dsv

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The records of a delimited text: each record past the header is one, framed to its line end outside a quoted cell,
// as a quoted cell may hold a line end. A record reads as its object of cells keyed by the header, or its array of
// cells under `no_header`, checked against the header's width or the first record's. A record that faults ends at its
// line end, and the records go on at the next.

// The records of a text of a delimited spec, which `records_open` makes and each call of `records_validate`,
// `records_find` or `records_scan` reads in batches, as `tape.Records` says.
Records :: struct {
	using records: tape.Records,
	spec:          Spec,
	p:             Pass_Options,
	width:         int, // the cells every record has, 0 until the first record of a text with no header
	count:         int, // the header's cells, kept in `keys` when they fit
	held:          []tape.Token, // the header's keys the batch being read gives each record's cells
	keys:          [FRAME_KEYS]tape.Token,
}

// Opens the records of `src`, a text of `spec`, each record read under `opts`. Only `.Lines` frames a delimited text,
// a record per line outside a quoted cell. The budget's limits hold for each record. A refused option, or a header that
// faults, ends the records before any is read.
records_open :: proc(src: []u8, framing := tape.Framing.Lines, spec := Spec.Csv, opts := Options{}) -> (r: Records) {
	if spec > max(Spec) {
		panic("dsv: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts = src, framing, spec, opts
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
	r.pos = text_start(r.src, 0)
	if r.p.no_header {
		return nil
	}
	r.count = header_cells(r.src, int(r.pos), S, r.p.delim, r.p.comment)
	if r.count == 0 {
		r.at = .Done
		return nil
	}
	if r.count > FRAME_KEYS {
		hi, width, err := read_header(r.src, S, r.p, nil, context.allocator)
		r.pos, r.width = hi, width
		return err
	}
	hi, width, err := read_header(r.src, S, r.p, r.keys[:r.count], context.allocator)
	r.pos, r.width = hi, width
	return err
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

// Reads the header of `src` into `keys`, or into a block of `allocator` it frees for nil `keys`, and returns the byte
// past it, where the first record may start, and its width, or the fault in it.
@(private)
read_header :: proc(src: []u8, $S: Spec, p: Pass_Options, keys: []tape.Token, allocator: runtime.Allocator) -> (hi: u64, width: int, err: tape.Error) {
	at := record_start(src, int(text_start(src, 0)), p.comment)
	s := scan_record(src, at, 0, S, p.delim)
	h: Header_Stop
	regs: hook.Regs
	head := Head{keys = keys}
	owned: []tape.Token
	if keys == nil {
		e: runtime.Allocator_Error
		if owned, e = make([]tape.Token, s.cells, allocator); e != nil {
			return 0, 0, e
		}
		head.keys = owned
	}
	defer delete(owned, allocator)
	ctx := context
	hp := p
	hp.limit = max(u64)
	_, err, _ = walk_text(src[:min(s.line_end + 1, len(src))], S, false, hp, &h, &regs, allocator, &ctx, header_stop, &head)
	return u64(min(s.line_end + 1, len(src))), s.cells, err
}

// Holds the header's keys for a batch of `r` in `held`: its own, or for a header past `FRAME_KEYS` cells a block of
// `allocator` read again from the text, which `records_release` frees. False, with the records ended, when the block is
// refused.
@(private)
records_hold :: proc(r: ^Records, $S: Spec, allocator: runtime.Allocator) -> bool {
	if r.count <= FRAME_KEYS {
		r.held = r.keys[:r.count]
		return true
	}
	keys, e := make([]tape.Token, r.count, allocator)
	if e != nil {
		r.err, r.at = e, .Done
		return false
	}
	r.held = keys
	if _, _, err := read_header(r.src, S, r.p, keys, allocator); err != nil {
		r.err, r.at = err, .Done
		return false
	}
	return true
}

@(private)
records_release :: proc(r: ^Records, allocator: runtime.Allocator) {
	if r.count > FRAME_KEYS {
		delete(r.held, allocator)
	}
	r.held = nil
}

// Reads the next records of `r` into `out` and judges each. Returns how many it filled, and fewer than `len(out)` once
// the records have ended, when `err` says why, nil at the text's end.
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
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, respell, nil, frame, walk)
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
	lo = u64(record_start(r.src, int(r.pos), r.p.comment))
	if lo >= u64(len(r.src)) {
		r.at = .Done
		return
	}
	s := scan_record(r.src, int(lo), 0, S, r.p.delim)
	r.pos = u64(min(s.line_end + 1, len(r.src)))
	return lo, u64(s.line_end_lo), true
}

// Walks the record from `lo` to `cut` as the root of a text of its bytes, its cells keyed by the header's, and keeps the
// width the first record sets.
@(private)
record_walked :: #force_inline proc(r: ^Records, $S: Spec, $LAX: bool, lo, cut: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	w: Pass(S, H, LAX, C)
	w.n, w.h, w.delim, w.tolerate, w.start, w.line, w.width, w.record = int(cut), h, r.p.delim, r.p.tolerate, 1, 1, r.width, true
	w.keys = r.held
	when LAX {
		w.steps[0] = r.opts.budget.steps + 1 if r.opts.budget.steps < max(u64) else max(u64)
	}
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	// The record is the root, one level above where a text holds it.
	p := r.p
	p.limit += 1
	res := run(&w, r.src[:cut], lo, p, regs, on)
	when LAX {
		if u8(res) == hook.WALK_STOPPED && w.steps[0] == 0 {
			res = hook.walk_result(u64(res) >> 16, hook.WALK_STEPS)
		}
	}
	if r.width == 0 && u8(res) == 0 {
		r.width = w.width
	}
	return {res = res, hi = cut, tolerated = w.tolerated, ok = true}
}
