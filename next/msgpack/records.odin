package msgpack

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Record-stream reads over MessagePack sequences (`.Concatenated`), array elements (`.Elements`),
// and map members (`.Members`).

Records :: struct {
	using records: tape.Records,
	spec:          Spec,
	steps:         u64,
	took:          bool,
	frame:         build.Frame(Path_Level),
	next:          Path_Level,
}

@(private)
Path_Level :: struct {
	using level: build.Frame_Level,
	left:        u64,
	head, need:  u64,
}

// Opens a record stream over `src` framed as `.Concatenated`, `.Elements`, or `.Members`.
records_open :: proc(src: []u8, framing := tape.Framing.Concatenated, spec := Spec.Msgpack, opts := Options{}, path: []tape.Step = nil) -> (r: Records) {
	if spec > max(Spec) {
		panic("msgpack: spec out of range")
	}
	r.spec, r.steps = spec, steps_of(opts)
	build.binary_records_init(&r.records, &r.frame, src, framing, &FORMATS[spec], opts, path, records_release)
	return
}

@(private)
records_release :: proc(r: ^tape.Records) {
	build.frame_free(&container_of(r, Records, "records").frame)
}

@(require_results)
records_validate :: proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Msgpack:
		if lax {
			return records_validate_as(r, out, .Msgpack, true, allocator)
		}
		return records_validate_as(r, out, .Msgpack, false, allocator)
	case .Compact:
		if lax {
			return records_validate_as(r, out, .Compact, true, allocator)
		}
		return records_validate_as(r, out, .Compact, false, allocator)
	}
	panic("msgpack: spec out of range")
}

@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Msgpack:
		if lax {
			return records_find_as(r, path, out, answers, .Msgpack, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Msgpack, false, read, allocator)
	case .Compact:
		if lax {
			return records_find_as(r, path, out, answers, .Compact, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Compact, false, read, allocator)
	}
	panic("msgpack: spec out of range")
}

@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Msgpack:
		if lax {
			return records_scan_as(r, demand, out, docs, .Msgpack, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Msgpack, false, read, allocator)
	case .Compact:
		if lax {
			return records_scan_as(r, demand, out, docs, .Compact, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Compact, false, read, allocator)
	}
	panic("msgpack: spec out of range")
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S, a)
	}
	walk_fn :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, lo, h, regs, a, ctx, hook.no_hook)
	}
	return build.records_validate(r, out, &FORMATS[S], &RULES, caller, frame, walk_fn)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
		regs: hook.Regs
		return walk_again((^Walk(S, build.Finder, LAX, build.FINDER_CAPS))(h.walk), h.src, lo, &regs, build.finder_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S, a)
	}
	walk_fn :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, lo, h, regs, a, ctx, build.finder_hook)
	}
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, respell, rewalk, frame, walk_fn)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Scanner, regs: ^hook.Regs, lo: u64) -> hook.Walk_Result {
		return walk_again((^Walk(S, build.Scanner, LAX, build.SCANNER_CAPS))(h.walk), h.b.doc.src, lo, regs, build.scanner_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S, a)
	}
	walk_fn :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, lo, h, regs, a, ctx, build.scanner_hook)
	}
	return build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, rewalk, node_bound, frame, walk_fn)
}

@(private)
record_frame :: #force_inline proc(r: ^Records, $S: Spec, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
	if r.framing == .Concatenated && r.at != .Done {
		n := u64(len(r.src))
		if r.pos >= n {
			if !window_more(r) {
				r.at = .Done
			}
			return
		}
		return r.pos, n, true
	}
	return record_frame_other(r, S, allocator)
}

@(private)
record_frame_other :: #force_inline proc(r: ^Records, $S: Spec, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
	open :: proc(r: ^Records, outer, lv: ^Path_Level, object: bool, depth: u64) -> build.Frame_Step {
		_ = outer
		return frame_open(r, lv, object, depth, S)
	}
	child :: #force_inline proc(r: ^Records, lv: ^Path_Level, object: bool) -> (u64, build.Frame_Step) {
		return frame_child(r, lv, object, S)
	}
	pass :: proc(r: ^Records, outer: ^Path_Level, depth: u64, allocator: runtime.Allocator) -> build.Frame_Step {
		_ = outer
		return frame_pass(r, depth, allocator, S)
	}
	lo, ok = build.frame_path(r, &r.frame, &FORMATS[S], &RULES, allocator, open, child, pass, frame_tail)
	return lo, u64(len(r.src)), ok
}

@(private)
frame_open :: proc "contextless" (r: ^Records, lv: ^Path_Level, object: bool, depth: u64, $S: Spec) -> build.Frame_Step {
	n := u64(len(r.src))
	at := r.pos
	if at >= n || depth + 1 > build.read_depth(r.opts) || r.steps <= 1 {
		return .Other
	}
	b := r.src[at]
	is_fix := (b >= 0x80 && b <= 0x8f) if object else (b >= 0x90 && b <= 0x9f)
	is_n := (b == 0xde || b == 0xdf) if object else (b == 0xdc || b == 0xdd)
	if !is_fix && !is_n {
		return .Other
	}
	arg, hl: u64
	if is_fix {
		arg, hl = u64(b & 0x0f), 1
	} else {
		wlen := ARG_WIDTH[b]
		read: bool
		arg, read = read_arg(r.src, at, wlen)
		hl = u64(1 + wlen)
		if !read || (S == .Compact && !compact_container_ok(b, arg)) {
			return .Other
		}
	}
	pair := u64(object)
	if arg > (n - at - hl) >> pair {
		if !lv.passing || !window_more(r) {
			return .Other
		}
		lv.head, lv.need = at, max(u64) if arg > max(u64) >> 2 else at + hl + (arg << pair)
	}
	lv.left = arg
	r.steps -= 1
	r.pos = at + hl
	return .Done
}

@(private)
frame_child :: #force_inline proc(r: ^Records, lv: ^Path_Level, object: bool, $S: Spec) -> (u64, build.Frame_Step) {
	if lv.left == 0 {
		return r.pos, .End
	}
	next := Path_Level{left = lv.left}
	at := r.pos
	if object {
		s: build.Frame_Step
		if at, s = frame_key(r, S); s != .Done {
			return 0, s
		}
	}
	next.left -= 1
	if !lv.passing && lv == build.frame_level(&r.frame, len(r.path)) {
		r.next = next
	} else {
		lv.left = next.left
	}
	return at, .Done
}

@(private)
frame_pass :: proc(r: ^Records, depth: u64, allocator: runtime.Allocator, $S: Spec) -> build.Frame_Step {
	if depth == 0 && len(r.src) == 0 {
		return item_refused(r, fault(0, .Truncated, .No_Item))
	}
	none: hook.No_Hooks
	regs: hook.Regs
	ctx := context
	res: hook.Walk_Result
	left: u64
	limit := build.read_depth(r.opts) - depth
	if build.read_lax(r.opts) {
		res, _, left = walk_item(r.src, r.pos, S, true, r.opts, limit, r.steps, &none, &regs, allocator, &ctx, hook.no_hook)
	} else {
		res, _, left = walk_item(r.src, r.pos, S, false, r.opts, limit, r.steps, &none, &regs, allocator, &ctx, hook.no_hook)
	}
	if u8(res) != 0 {
		return item_refused(r, res)
	}
	r.steps, r.pos = left, u64(res) >> 16
	return .Done
}

@(private)
frame_tail :: proc(r: ^Records) -> build.Frame_Step {
	if r.pos < u64(len(r.src)) {
		return item_refused(r, fault(r.pos, .Bad_Char, .Trailing))
	}
	return .Wait if window_more(r) else .Done
}

@(private, cold)
item_refused :: proc "contextless" (r: ^Records, res: hook.Walk_Result) -> build.Frame_Step {
	return build.binary_item_refused(&r.records, &r.frame, res, &RULES, u8(Detail.Count_Too_Large))
}

@(private)
window_more :: #force_inline proc "contextless" (r: ^Records) -> bool {
	return r.opts.pieces != nil && !r.opts.pieces.last
}

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

@(private)
frame_key :: proc(r: ^Records, $S: Spec) -> (u64, build.Frame_Step) {
	if r.steps == 0 {
		return 0, item_refused(r, hook.walk_result(r.pos, hook.WALK_STEPS))
	}
	h: Member_Key
	regs: hook.Regs
	levels: [2]Level
	w: Walk(S, Member_Key, false, hook.NO_HOOKS_CAPS)
	walk_init(&w, r.src, &h, raw_data(levels[:]), 2, 2, r.opts)
	w.depth = 2
	res := run(&w, r.pos, 1, FLAG_OBJECT | 2, &regs, member_key_hook)
	if u8(res) != hook.WALK_STOPPED {
		return 0, item_refused(r, res if u8(res) != 0 else fault(u64(res) >> 16, .Truncated))
	}
	end := u64(res) >> 16
	r.key, r.took = h.key, w.tolerated
	return end, .Done
}

@(private)
record_walk :: proc(r: ^Records, $S: Spec, $LAX: bool, lo: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	concatenated := r.framing == .Concatenated
	limit := build.read_depth(r.opts)
	if !concatenated {
		limit -= 1 + u64(len(r.path))
	}
	steps := steps_of(r.opts) if concatenated else r.steps
	res, tolerated, left := walk_item(r.src, lo, S, LAX, r.opts, limit, steps, h, regs, allocator, ctx, on)
	walked.res, walked.tolerated = res, tolerated || r.took
	end := res
	if u8(res) == hook.WALK_STOPPED {
		none: hook.No_Hooks
		none_regs: hook.Regs
		end, _, left = walk_item(r.src, lo, S, LAX, r.opts, limit, steps, &none, &none_regs, allocator, ctx, hook.no_hook)
	}
	if u8(end) != 0 {
		_ = item_refused(r, end)
		return
	}
	if !concatenated {
		r.steps = left
		build.frame_level(&r.frame, len(r.path)).left = r.next.left
	}
	r.took = false
	walked.hi, walked.ok = u64(end) >> 16, true
	r.pos, r.at = walked.hi, .After
	return
}
