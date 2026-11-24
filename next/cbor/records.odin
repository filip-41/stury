package cbor

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The records of a CBOR text: the items of a sequence (RFC 8742) under `.Concatenated`, and the elements of the root
// array or the members of the root map under `.Elements` and `.Members`. Each record is judged as a read of its bytes
// alone judges them, in place in the text.

// The records of a text of a CBOR spec, which `records_open` makes and each call of `records_validate`, `records_find`
// or `records_scan` reads in batches, as `tape.Records` says.
Records :: struct {
	using records: tape.Records,
	spec:          Spec,
	// Under `.Elements` and `.Members`, the root's elements or members left, `INDEF_COUNT` for an indefinite root.
	left:          u64,
	// Under `.Elements` and `.Members`, the walk's count of `Budget.steps`, which counts the containers of the whole
	// text.
	steps:         u64,
	prev:          [2]u64, // under `.Members` in a spec that orders keys, the span of the last key
	took:          bool, // under `.Members`, the key read for the next record took a tolerance, which that record reports
	item:          Item_Frame, // in a text in pieces, the framing of the item at `pos` across windows
}

// Opens the records of `src`, a text of `spec` framed as `framing`, each read under `opts`. The budget's limits hold
// for each record, but `Budget.steps` under `.Elements` and `.Members`, which counts the containers of the whole text.
// Another format's options, `.Lines`, which CBOR has no reading of, and a text in pieces under `.Elements` or
// `.Members`, end the records with `tape.Bad_Option` before any is read. A fault in a root's elements or members ends
// them with the fault `validate` gives for the whole text, which no window holds. A root of another kind than the
// framing takes holds no records, and ends them with the verdict `validate` gives for the text, nil for a valid one.
// `opts.runner` has no effect on records. A text in pieces opens with its first window, as `tape.Records` says.
records_open :: proc(src: []u8, framing := tape.Framing.Concatenated, spec := Spec.Cbor, opts := Options{}) -> (r: Records) {
	if spec > max(Spec) {
		panic("cbor: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts, r.steps = src, framing, spec, opts, steps_of(opts)
	if opts.pieces != nil {
		r.src = tape.piece_src(src, opts.pieces.from)
	}
	if err := tape.options_refused(&FORMATS[spec], opts); err != nil {
		r.err, r.at = err, .Done
	} else if framing == .Lines {
		r.err, r.at = tape.Bad_Option{"framing"}, .Done
	} else if opts.pieces != nil && framing != .Concatenated {
		r.err, r.at = tape.Bad_Option{"pieces"}, .Done
	}
	return
}

// Reads the next records of `r` into `out` and judges each, as `validate` judges its bytes alone. Returns how many it
// filled, and fewer than `len(out)` once the records have ended, when `err` says why, nil at the text's end. Needs
// `READ_STACK` bytes of stack and faults on a thread with less.
@(require_results)
records_validate :: proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	// Records read no text in pieces, so the count of steps alone makes a walk lax.
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Cbor:
		if lax {
			return records_validate_as(r, out, .Cbor, true, allocator)
		}
		return records_validate_as(r, out, .Cbor, false, allocator)
	case .Preferred:
		if lax {
			return records_validate_as(r, out, .Preferred, true, allocator)
		}
		return records_validate_as(r, out, .Preferred, false, allocator)
	case .Deterministic:
		if lax {
			return records_validate_as(r, out, .Deterministic, true, allocator)
		}
		return records_validate_as(r, out, .Deterministic, false, allocator)
	case .Length_First:
		if lax {
			return records_validate_as(r, out, .Length_First, true, allocator)
		}
		return records_validate_as(r, out, .Length_First, false, allocator)
	}
	panic("cbor: spec out of range")
}

// Reads the next records of `r` into `out`, and for each the first value `path` reaches in it into the same place of
// `answers`, as `find` reads its bytes alone, with every offset from the text's first byte. The walk reads each record
// to its end whatever `read.stop_early` says, as the next starts there. Needs `READ_STACK` bytes of stack and faults on
// a thread with less.
@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	// Records read no text in pieces, so the count of steps alone makes a walk lax.
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Cbor:
		if lax {
			return records_find_as(r, path, out, answers, .Cbor, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Cbor, false, read, allocator)
	case .Preferred:
		if lax {
			return records_find_as(r, path, out, answers, .Preferred, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Preferred, false, read, allocator)
	case .Deterministic:
		if lax {
			return records_find_as(r, path, out, answers, .Deterministic, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Deterministic, false, read, allocator)
	case .Length_First:
		if lax {
			return records_find_as(r, path, out, answers, .Length_First, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Length_First, false, read, allocator)
	}
	panic("cbor: spec out of range")
}

// Reads the next records of `r` into `out`, and for each the document of its nodes the paths of `demand` reach into the
// same place of `docs`, as `scan` reads its bytes alone. Each document is the caller's to free. Needs `READ_STACK`
// bytes of stack and faults on a thread with less.
@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	// Records read no text in pieces, so the count of steps alone makes a walk lax.
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Cbor:
		if lax {
			return records_scan_as(r, demand, out, docs, .Cbor, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Cbor, false, read, allocator)
	case .Preferred:
		if lax {
			return records_scan_as(r, demand, out, docs, .Preferred, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Preferred, false, read, allocator)
	case .Deterministic:
		if lax {
			return records_scan_as(r, demand, out, docs, .Deterministic, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Deterministic, false, read, allocator)
	case .Length_First:
		if lax {
			return records_scan_as(r, demand, out, docs, .Length_First, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Length_First, false, read, allocator)
	}
	panic("cbor: spec out of range")
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, lo, h, regs, a, ctx, hook.no_hook)
	}
	return build.records_validate(r, out, &FORMATS[S], &RULES, caller, frame, walk)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
		regs: hook.Regs
		return walk_again((^Walk(S, build.Finder, LAX, build.FINDER_CAPS))(h.walk), h.src, lo, &regs, build.finder_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, lo, h, regs, a, ctx, build.finder_hook)
	}
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, respell, rewalk, frame, walk)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Scanner, regs: ^hook.Regs, lo: u64) -> hook.Walk_Result {
		return walk_again((^Walk(S, build.Scanner, LAX, build.SCANNER_CAPS))(h.walk), h.b.doc.src, lo, regs, build.scanner_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, lo, h, regs, a, ctx, build.scanner_hook)
	}
	return build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, rewalk, node_bound, frame, walk)
}

// The next record's first byte and the text's end, which its walk may read to. Under `.Members` the key is read into
// `r.key` and the first byte is the value's. False once the records have ended. A fault in the root's head, a key, or
// what follows the root ends them with the fault `validate` gives for the text. The items of a whole sequence, the
// common case, take no call.
@(private)
record_frame :: #force_inline proc(r: ^Records, $S: Spec) -> (lo, cut: u64, ok: bool) {
	if r.framing == .Concatenated && r.opts.pieces == nil && r.at != .Done {
		n := u64(len(r.src))
		if r.pos >= n {
			r.at = .Done
			return
		}
		return r.pos, n, true
	}
	return record_frame_other(r, S)
}

// `record_frame` for the elements and members of a root, and for a sequence in pieces.
@(private)
record_frame_other :: proc(r: ^Records, $S: Spec) -> (lo, cut: u64, ok: bool) {
	if r.at == .Done {
		return
	}
	n := u64(len(r.src))
	if r.framing == .Concatenated {
		if r.opts.pieces != nil {
			return record_frame_window(r)
		}
		if r.pos >= n {
			r.at = .Done
			return
		}
		return r.pos, n, true
	}
	if r.at == .Start && !root_open(r, S) {
		records_refuse(r, nil)
		return
	}
	if r.left == 0 || r.left == INDEF_COUNT && r.pos < n && r.src[r.pos] == 0xff {
		r.pos += u64(r.left != 0)
		r.at = .Done
		if r.pos != n {
			records_refuse(r, nil)
		}
		return
	}
	if r.left != INDEF_COUNT {
		r.left -= 1
	}
	if r.framing == .Members {
		if !record_key(r, S) {
			records_refuse(r, nil)
			return
		}
	}
	return r.pos, n, true
}

// Reads the head of the root container, an array under `.Elements` and a map under `.Members`, past the tags that mark
// it, false when the text holds no such head of spec `S` or its count is more than the bytes left hold. A tag that
// folds the number it marks (2 to 5) leaves no container. The root takes a step, as each container does.
@(private)
root_open :: proc "contextless" (r: ^Records, $S: Spec) -> bool {
	n := u64(len(r.src))
	at := u64(0)
	for at < n && r.src[at] >> 5 == 6 {
		// A head of additional information 28 to 31 is no tag head, and has no length to step by.
		if r.src[at] & 31 > 27 {
			return false
		}
		tag, hl, ok := read_head(r.src, at, r.src[at] & 31)
		if !ok || tag >= 2 && tag <= 5 || S != .Cbor && !shortest(r.src[at] & 31, tag) {
			return false
		}
		at += hl
	}
	if at >= n {
		return false
	}
	b := r.src[at]
	major := u8(4 if r.framing == .Elements else 5)
	if b >> 5 != major || b & 31 > 27 && b & 31 != 31 {
		return false
	}
	r.steps -= 1
	if r.steps == 0 {
		return false
	}
	r.at = .Open
	if b & 31 == 31 {
		r.left, r.pos = INDEF_COUNT, at + 1
		return S == .Cbor
	}
	arg, hl, ok := read_head(r.src, at, b & 31)
	if !ok || S != .Cbor && !shortest(b & 31, arg) || arg > (n - at - hl) >> (major - 4) {
		return false
	}
	r.left, r.pos = arg, at + hl
	return true
}

// The hook of the walk that reads a member's key, which keeps the key and stops the walk.
@(private)
Member_Key :: struct {
	protocol: hook.Protocol(hook.NO_HOOKS_CAPS, hook.Unused, hook.Unused, hook.Unused),
	key:      tape.Token,
}

@(private)
member_key_hook :: proc "contextless" (h: ^Member_Key, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.key = t
	return s, .Stop
}

// Reads the key of the member at `r.pos` into `r.key`, as the walk reads a key in a map, and moves `r.pos` to its
// value, false when the key fails or, in a spec that orders keys, does not follow the last.
@(private)
record_key :: proc "contextless" (r: ^Records, $S: Spec) -> bool {
	h: Member_Key
	regs: hook.Regs
	levels: [2]Level(S)
	w: Walk(S, Member_Key, false, hook.NO_HOOKS_CAPS)
	walk_init(&w, r.src, &h, raw_data(levels[:]), 2, 2, r.opts)
	w.depth = 2
	res := run(&w, r.pos, 1, FLAG_OBJECT | 2, &regs, member_key_hook)
	if u8(res) != hook.WALK_STOPPED {
		return false
	}
	end := u64(res) >> 16
	when S >= .Deterministic {
		if !keys_ordered(r.src, &r.prev, r.pos, end, S) {
			return false
		}
	}
	r.key, r.pos, r.took = h.key, end, w.tolerated
	return true
}

// Ends the records with the error `validate` gives for the text, or `err` when it gives none.
@(private, cold)
records_refuse :: proc(r: ^Records, err: tape.Error) {
	r.err = validate(r.src, r.spec, r.opts)
	if r.err == nil {
		r.err = err
	}
	r.at = .Done
}

// Walks the record at `lo` for hook `h` from registers `regs`. Returns the walk's result `res` and whether it took a
// tolerance, the record's end as `hi`, and `ok` false once the records have ended, as a fault in a record ends them:
// under `.Concatenated` with the record's fault, as no next item can be found past it, and under the other framings
// with the fault `validate` gives for the text.
@(private)
record_walk :: proc(r: ^Records, $S: Spec, $LAX: bool, lo: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	concatenated := r.framing == .Concatenated
	limit := build.read_depth(r.opts) - (0 if concatenated else 1)
	steps := steps_of(r.opts) if concatenated else r.steps
	res, tolerated, left := walk_item(r.src, lo, S, LAX, r.opts, limit, steps, h, regs, allocator, ctx, on)
	walked.res, walked.tolerated = res, tolerated || r.took
	r.took = false
	end := res
	if u8(res) == hook.WALK_STOPPED {
		// The hook stopped the walk before the record's end. A walk with no hook finds the end, and `res` keeps the
		// stop for the caller.
		none: hook.No_Hooks
		none_regs: hook.Regs
		end, _, left = walk_item(r.src, lo, S, LAX, r.opts, limit, steps, &none, &none_regs, allocator, ctx, hook.no_hook)
	}
	if u8(end) != 0 {
		_, err, _ := hook.walk_error(end, &RULES)
		if concatenated {
			r.err, r.at = err, .Done
		} else {
			records_refuse(r, err)
		}
		return
	}
	if !concatenated {
		r.steps = left
	}
	walked.hi, walked.ok = u64(end) >> 16, true
	r.pos, r.at = walked.hi, .After
	return
}
