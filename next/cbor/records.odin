package cbor

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Record-stream reads over CBOR sequences (RFC 8742 `.Concatenated`), array elements (`.Elements`), and map members (`.Members`).

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
	tagged:      u64,
	key:         [2]u64,
	base:        u64,
	head, need:  u64,
}

records_open :: proc(src: []u8, framing := tape.Framing.Concatenated, spec := Spec.Cbor, opts := Options{}, path: []tape.Step = nil) -> (r: Records) {
	if spec > max(Spec) {
		panic("cbor: spec out of range")
	}
	r.spec, r.steps = spec, build.binary_steps_of(opts)
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
	case .Cbor:
		return records_validate_as(r, out, .Cbor, true, allocator) if lax else records_validate_as(r, out, .Cbor, false, allocator)
	case .Preferred:
		return records_validate_as(r, out, .Preferred, true, allocator) if lax else records_validate_as(r, out, .Preferred, false, allocator)
	case .Deterministic:
		return records_validate_as(r, out, .Deterministic, true, allocator) if lax else records_validate_as(r, out, .Deterministic, false, allocator)
	case .Length_First:
		return records_validate_as(r, out, .Length_First, true, allocator) if lax else records_validate_as(r, out, .Length_First, false, allocator)
	}
	panic("cbor: spec out of range")
}

@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Cbor:
		return records_find_as(r, path, out, answers, .Cbor, true, read, allocator) if lax else records_find_as(r, path, out, answers, .Cbor, false, read, allocator)
	case .Preferred:
		return records_find_as(r, path, out, answers, .Preferred, true, read, allocator) if lax else records_find_as(r, path, out, answers, .Preferred, false, read, allocator)
	case .Deterministic:
		return records_find_as(r, path, out, answers, .Deterministic, true, read, allocator) if lax else records_find_as(r, path, out, answers, .Deterministic, false, read, allocator)
	case .Length_First:
		return records_find_as(r, path, out, answers, .Length_First, true, read, allocator) if lax else records_find_as(r, path, out, answers, .Length_First, false, read, allocator)
	}
	panic("cbor: spec out of range")
}

@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Cbor:
		return records_scan_as(r, demand, out, docs, .Cbor, true, read, allocator) if lax else records_scan_as(r, demand, out, docs, .Cbor, false, read, allocator)
	case .Preferred:
		return records_scan_as(r, demand, out, docs, .Preferred, true, read, allocator) if lax else records_scan_as(r, demand, out, docs, .Preferred, false, read, allocator)
	case .Deterministic:
		return records_scan_as(r, demand, out, docs, .Deterministic, true, read, allocator) if lax else records_scan_as(r, demand, out, docs, .Deterministic, false, read, allocator)
	case .Length_First:
		return records_scan_as(r, demand, out, docs, .Length_First, true, read, allocator) if lax else records_scan_as(r, demand, out, docs, .Length_First, false, read, allocator)
	}
	panic("cbor: spec out of range")
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S, a)
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
	frame :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S, a)
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
	frame :: #force_inline proc(r: ^tape.Records, a: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S, a)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, lo, h, regs, a, ctx, build.scanner_hook)
	}
	return build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, rewalk, node_bound, frame, walk)
}

@(private)
record_frame :: #force_inline proc(r: ^Records, $S: Spec, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
	if r.framing == .Concatenated && r.at != .Done {
		return build.binary_record_frame_concat(&r.records)
	}
	open :: proc(r: ^Records, outer, lv: ^Path_Level, object: bool, depth: u64) -> build.Frame_Step {
		return frame_open(r, outer, lv, object, depth, S)
	}
	child :: #force_inline proc(r: ^Records, lv: ^Path_Level, object: bool) -> (u64, build.Frame_Step) {
		return frame_child(r, lv, object, S)
	}
	pass :: proc(r: ^Records, outer: ^Path_Level, depth: u64, allocator: runtime.Allocator) -> build.Frame_Step {
		walk_fn :: proc(src: []u8, lo: u64, lax: bool, opts: Options, limit, steps: u64, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (hook.Walk_Result, bool, u64) {
			if lax { return walk_item(src, lo, S, true, opts, limit, steps, h, regs, a, ctx, hook.no_hook) }
			return walk_item(src, lo, S, false, opts, limit, steps, h, regs, a, ctx, hook.no_hook)
		}
		return build.binary_frame_pass(&r.records, &r.frame, &r.steps, depth, outer.tagged, allocator, &RULES, u8(Detail.No_Item), u8(Detail.Count_Too_Large), walk_fn)
	}
	tail :: proc(r: ^Records) -> build.Frame_Step {
		return build.binary_frame_tail(&r.records, &r.frame, &RULES, u8(Detail.Trailing), u8(Detail.Count_Too_Large))
	}
	lo, ok = build.frame_path(r, &r.frame, &FORMATS[S], &RULES, allocator, open, child, pass, tail)
	return lo, u64(len(r.src)), ok
}

@(private)
frame_open :: proc "contextless" (r: ^Records, outer, lv: ^Path_Level, object: bool, depth: u64, $S: Spec) -> build.Frame_Step {
	n := u64(len(r.src))
	at := r.pos
	tags: u64
	for at < n && r.src[at] >> 5 == 6 {
		tags += 1
		if r.src[at] & 31 > 27 {
			return .Other
		}
		tag, hl, read := read_head(r.src, at, r.src[at] & 31)
		if !read || tag >= 2 && tag <= 5 || S != .Cbor && !shortest(r.src[at] & 31, tag) || at + hl < n && tag_content_fault(r.src, at + hl, tag) != NO_FAULT {
			return .Other
		}
		at += hl
	}
	if at >= n || depth + 1 + outer.tagged + tags > build.read_depth(r.opts) || r.steps <= 1 {
		return .Other
	}
	b := r.src[at]
	major := u8(5 if object else 4)
	if b >> 5 != major || b & 31 > 27 && (b & 31 != 31 || S != .Cbor) {
		return .Other
	}
	if b & 31 == 31 {
		lv.left, at = INDEF_COUNT, at + 1
	} else {
		arg, hl, read := read_head(r.src, at, b & 31)
		if !read || S != .Cbor && !shortest(b & 31, arg) {
			return .Other
		}
		if arg > (n - at - hl) >> (major - 4) {
			if !lv.passing || !build.binary_window_more(&r.records) {
				return .Other
			}
			lv.head, lv.need = at, max(u64) if arg > max(u64) >> 2 else at + hl + arg << (major - 4)
		}
		lv.left, at = arg, at + hl
	}
	lv.tagged, lv.base = outer.tagged + tags, outer.key[1] if r.opts.pieces != nil else 0
	lv.key = {lv.base, lv.base}
	r.steps -= 1
	r.pos = at
	return .Done
}

@(private)
frame_child :: #force_inline proc(r: ^Records, lv: ^Path_Level, object: bool, $S: Spec) -> (u64, build.Frame_Step) {
	n := u64(len(r.src))
	if lv.left == 0 {
		return r.pos, .End
	}
	if lv.left == INDEF_COUNT {
		if r.pos >= n {
			return 0, item_refused(r, fault(n, .Truncated))
		}
		if r.src[r.pos] == 0xff {
			return r.pos + 1, .End
		}
	}
	next := Path_Level{left = lv.left, key = lv.key}
	at := r.pos
	if object {
		s: build.Frame_Step
		if at, s = frame_key(r, &next, S); s != .Done {
			return 0, s
		}
	}
	if next.left != INDEF_COUNT {
		next.left -= 1
	}
	if !lv.passing && lv == build.frame_level(&r.frame, len(r.path)) {
		r.next = next
	} else {
		level_take(r, lv, &next, S)
	}
	return at, .Done
}

@(private)
level_take :: #force_inline proc(r: ^Records, lv: ^Path_Level, next: ^Path_Level, $S: Spec) {
	lv.left, lv.key = next.left, next.key
	when S >= .Deterministic {
		if held := held_bytes(r) if r.opts.pieces != nil else nil; held != nil && lv.key[0] != lv.base {
			copy(held[lv.base:], held[lv.key[0]:lv.key[1]])
			lv.key = {lv.base, lv.base + lv.key[1] - lv.key[0]}
		}
	}
}

@(private, cold)
item_refused :: proc "contextless" (r: ^Records, res: hook.Walk_Result) -> build.Frame_Step {
	return build.binary_item_refused(&r.records, &r.frame, res, &RULES, u8(Detail.Count_Too_Large))
}

@(private)
held_bytes :: proc(r: ^Records) -> ^[dynamic]u8 {
	p := r.opts.pieces
	s, err := hook.piece_state(p, hook.Piece_State)
	if err != nil {
		return nil
	}
	if s.names.allocator.procedure == nil {
		s.names.allocator = p.allocator
	}
	return &s.names
}

@(private)
key_hold :: proc(r: ^Records, lv: ^Path_Level, lo, hi: u64, $S: Spec) -> hook.Walk_Result {
	held := held_bytes(r)
	if held == nil || resize(held, int(lv.key[1])) != nil {
		return hook.walk_result(lo, hook.WALK_NO_MEMORY)
	}
	if _, err := append(held, ..r.src[lo:hi]); err != nil {
		return hook.walk_result(lo, hook.WALK_NO_MEMORY)
	}
	key := [2]u64{lv.key[1], lv.key[1] + hi - lo}
	if lv.key[1] > lv.key[0] && !key_before(held[:], lv.key, key, S) {
		return hook.Walk_Result(lo << 16 | u64(key_fault(held[:], lv.key, key[0], key[1], r.opts.dups == .Refuse)) & 0xffff)
	}
	lv.key = key
	return 0
}

@(private)
frame_key :: proc(r: ^Records, lv: ^Path_Level, $S: Spec) -> (u64, build.Frame_Step) {
	h: build.Binary_Member_Key
	regs: hook.Regs
	levels: [2]Level(S)
	w: Walk(S, build.Binary_Member_Key, false, hook.NO_HOOKS_CAPS)
	walk_init(&w, r.src, &h, raw_data(levels[:]), 2, 2, r.opts)
	w.depth = 2
	res := run(&w, r.pos, 1, FLAG_OBJECT | 2, &regs, build.binary_member_key_hook)
	if u8(res) != hook.WALK_STOPPED {
		return 0, item_refused(r, res if u8(res) != 0 else fault(u64(res) >> 16, .Truncated))
	}
	end := u64(res) >> 16
	when S >= .Deterministic {
		if r.opts.pieces != nil {
			if e := key_hold(r, lv, r.pos, end, S); e != 0 {
				return 0, item_refused(r, e)
			}
		} else if !keys_ordered(r.src, &lv.key, r.pos, end, S) {
			return 0, item_refused(r, key_fault(r.src, lv.key, r.pos, end, r.opts.dups == .Refuse))
		}
	}
	r.key, r.took = h.key, w.tolerated
	return end, .Done
}

@(private)
record_walk :: proc(r: ^Records, $S: Spec, $LAX: bool, lo: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> build.Record_Walk {
	tagged := u64(0) if r.framing == .Concatenated else build.frame_level(&r.frame, len(r.path)).tagged
	walk_h :: proc "contextless" (src: []u8, lo: u64, opts: Options, limit, steps: u64, h: ^H, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (hook.Walk_Result, bool, u64) {
		return walk_item(src, lo, S, LAX, opts, limit, steps, h, regs, a, ctx, on)
	}
	walk_none :: proc "contextless" (src: []u8, lo: u64, opts: Options, limit, steps: u64, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (hook.Walk_Result, bool, u64) {
		return walk_item(src, lo, S, LAX, opts, limit, steps, h, regs, a, ctx, hook.no_hook)
	}
	take :: proc(r: ^Records) {
		level_take(r, build.frame_level(&r.frame, len(r.path)), &r.next, S)
	}
	return build.binary_record_walk(r, lo, tagged, h, regs, allocator, ctx, &RULES, u8(Detail.Count_Too_Large), walk_h, walk_none, take)
}
