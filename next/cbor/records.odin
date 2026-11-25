package cbor

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The records of a CBOR text: the items of a sequence (RFC 8742) under `.Concatenated`, and the elements of an array
// or the members of a map under `.Elements` and `.Members`. Each record is judged as a read of its bytes alone judges
// them, in place in the text.

// The records of a text of a CBOR spec, which `records_open` makes and each call of `records_validate`, `records_find`
// or `records_scan` reads in batches, as `tape.Records` says.
Records :: struct {
	using records: tape.Records,
	spec:          Spec,
	// Under `.Elements` and `.Members`, the walk's count of `Budget.steps`, which counts the containers of the whole
	// text.
	steps:         u64,
	took:          bool, // under `.Members`, the key read for the next record took a tolerance, which that record reports
	frame:         build.Frame(Path_Level),
	// The records' container once the record `record_frame` gave is read, which its walk keeps.
	next:          Path_Level,
}

// A container the framing is in: the children it has left, `INDEF_COUNT` for an indefinite one, the tags that mark it
// and the containers around it, and in a spec that orders keys the span of the last key read in it. In a text in
// pieces that span is in `held_bytes`, past `base`, where the keys of the containers around it end, and a container
// passed whose count the windows read so far cannot hold claims the text up to `need`, as its head at `head` faults
// unless the text reaches it.
@(private)
Path_Level :: struct {
	using level: build.Frame_Level,
	left:        u64,
	tagged:      u64,
	key:         [2]u64,
	base:        u64,
	head, need:  u64,
}

// Opens the records of `src`, a text of `spec` framed as `framing`, each read under `opts`. The budget's limits hold
// for each record, but `Budget.steps` under `.Elements` and `.Members`, which counts the containers of the whole text.
// Another format's options, `.Lines`, which CBOR has no reading of, and a `path` the framing or the policy for repeated
// keys does not take end the records with `tape.Bad_Option` before any is read. A path of more than seven steps, and in a
// text in pieces a value off the path that a window cuts more than seven levels deep, take memory from the context's
// allocator, which `tape.destroy_records` frees. In a text in pieces under `.Elements` and
// `.Members` the framing holds the last key read in each map it is in, in a spec that orders keys. `opts.runner` has no
// effect on records. A text in pieces opens with its first window, as `tape.Records` says.
records_open :: proc(src: []u8, framing := tape.Framing.Concatenated, spec := Spec.Cbor, opts := Options{}, path: []tape.Step = nil) -> (r: Records) {
	if spec > max(Spec) {
		panic("cbor: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts, r.steps = src, framing, spec, opts, steps_of(opts)
	if opts.pieces != nil {
		r.src = tape.piece_src(src, opts.pieces.from)
	}
	r.path = path
	if err := tape.options_refused(&FORMATS[spec], opts); err != nil {
		r.err, r.at = err, .Done
	} else if err = build.records_path_refused(&FORMATS[spec], framing, path, opts); err != nil {
		r.err, r.at = err, .Done
	} else if framing == .Lines || framing == .Seq {
		r.err, r.at = tape.Bad_Option{"framing"}, .Done
	} else if e := build.frame_init(&r.frame, path); e != nil {
		r.err, r.at = e, .Done
	}
	r.release = records_release
	return
}

// Frees the levels of the records `r` at a long path.
@(private)
records_release :: proc(r: ^tape.Records) {
	build.frame_free(&container_of(r, Records, "records").frame)
}

// Reads the next records of `r` and judges each, as `validate` judges its bytes alone, keeping in `out` those that do
// not read. Returns how many it filled, and fewer than `len(out)` once the records have ended, when `err` says why, nil
// at the text's end. Needs
// `READ_STACK` bytes of stack and faults on a thread with less.
@(require_results)
records_validate :: proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	// A record's walk reads a whole item, in a text in pieces too, so the count of steps alone makes it lax.
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
	// A record's walk reads a whole item, in a text in pieces too, so the count of steps alone makes it lax.
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
// same place of `docs`, as `scan` reads its bytes alone. The documents are in the records' block, valid until the next
// call or `tape.destroy_records`, as `tape.Record_Block` says. Needs `READ_STACK` bytes of stack and faults on a thread
// with less.
@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	// A record's walk reads a whole item, in a text in pieces too, so the count of steps alone makes it lax.
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

// The next record's first byte and the text's end, which its walk may read to. Under `.Members` the key is read into
// `r.key` and the first byte is the value's. False once the records have ended, and in a text in pieces once the
// window holds no more. The items of a sequence take no call.
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

// `record_frame` under `.Elements` and `.Members`: the shared framing over CBOR's grammar.
@(private)
record_frame_other :: #force_inline proc(r: ^Records, $S: Spec, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
	open :: proc(r: ^Records, outer, lv: ^Path_Level, object: bool, depth: u64) -> build.Frame_Step {
		return frame_open(r, outer, lv, object, depth, S)
	}
	child :: #force_inline proc(r: ^Records, lv: ^Path_Level, object: bool) -> (u64, build.Frame_Step) {
		return frame_child(r, lv, object, S)
	}
	pass :: proc(r: ^Records, outer: ^Path_Level, depth: u64, allocator: runtime.Allocator) -> build.Frame_Step {
		return frame_pass(r, outer, depth, allocator, S)
	}
	lo, ok = build.frame_path(r, &r.frame, &FORMATS[S], &RULES, allocator, open, child, pass, frame_tail)
	return lo, u64(len(r.src)), ok
}

// CBOR's `open` of the framing: the head of a map for `object`, else of an array, at `pos` past the tags that mark it,
// which takes a step of `Budget.steps` and with its tags levels of the depth the read takes, and whose count the bytes
// left hold. Any other head, a tag that folds the number it marks (2 to 5) and one whose content may not be the
// container are `pass`'s to judge.
@(private)
frame_open :: proc "contextless" (r: ^Records, outer, lv: ^Path_Level, object: bool, depth: u64, $S: Spec) -> build.Frame_Step {
	n := u64(len(r.src))
	at := r.pos
	tags: u64
	for at < n && r.src[at] >> 5 == 6 {
		tags += 1
		// A head of additional information 28 to 31 is no tag head, and has no length to step by.
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
			// A record cannot be taken back once given, so only a passed container goes on before its count is held.
			if !lv.passing || !window_more(r) {
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

// CBOR's `child` of the framing: the next item of container `lv`, past its key in a map, or the container's end, past
// the break of an indefinite one. The records' container is left as it is until the record is read, in `r.next`.
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

// Takes `next` as the container `lv` once its child is read, with the key read last at the container's base in a text
// in pieces.
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

// CBOR's `pass` of the framing: judges the item at `pos` in container `outer`, `depth` containers deep, as the walk
// of the whole text judges it, and moves `pos` past it.
@(private)
frame_pass :: proc(r: ^Records, outer: ^Path_Level, depth: u64, allocator: runtime.Allocator, $S: Spec) -> build.Frame_Step {
	if depth == 0 && len(r.src) == 0 {
		// An empty text holds no item, which `validate` says before it walks one.
		return item_refused(r, fault(0, .Truncated, .No_Item))
	}
	none: hook.No_Hooks
	regs: hook.Regs
	ctx := context
	res: hook.Walk_Result
	left: u64
	limit := build.read_depth(r.opts) - depth - outer.tagged
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

// CBOR's `tail` of the framing: no byte follows the root.
@(private)
frame_tail :: proc(r: ^Records) -> build.Frame_Step {
	if r.pos < u64(len(r.src)) {
		return item_refused(r, fault(r.pos, .Bad_Char, .Trailing))
	}
	return .Wait if window_more(r) else .Done
}

// The verdict on a step whose walk gave the fault `res`: `.Wait` in a window that more bytes follow for a `.Truncated`,
// which they may lift, or while a container passed claims bytes past the window, else `.Fault` with the records ended
// at it, or at the head of the outermost container whose claim the text does not reach, which comes first.
@(private, cold)
item_refused :: proc "contextless" (r: ^Records, res: hook.Walk_Result) -> build.Frame_Step {
	if window_more(r) && u8(res) == u8(tape.Fault_Kind.Truncated) {
		return .Wait
	}
	res := res
	for k in 0 ..< r.frame.depth {
		if lv := build.frame_level(&r.frame, k); lv.need > u64(len(r.src)) {
			if window_more(r) {
				return .Wait
			}
			res = fault(lv.head, .Truncated, .Count_Too_Large)
			break
		}
	}
	_, r.err, _ = hook.walk_error(res, &RULES)
	r.at = .Done
	return .Fault
}

// Whether more bytes follow the window of a text in pieces.
@(private)
window_more :: #force_inline proc "contextless" (r: ^Records) -> bool {
	return r.opts.pieces != nil && !r.opts.pieces.last
}

// The bytes the framing of a text in pieces holds, in the pieces' state: the last key read in each map it is in. Nil
// when memory for them is refused.
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

// Holds the key `src[lo:hi]` read in container `lv` of a text in pieces as its last key, past the one before it, which
// a key that does not follow it is the fault the walk gives for, and returns that fault, 0 for none. `level_take`
// moves it to the container's base.
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

// Reads the key of the member at `pos` of map `lv` into `r.key`, as the walk reads a key in a map, and returns where
// its value starts. In a spec that orders keys a key that does not follow the last one read in `lv` is the fault the
// walk gives for it.
@(private)
frame_key :: proc(r: ^Records, lv: ^Path_Level, $S: Spec) -> (u64, build.Frame_Step) {
	h: Member_Key
	regs: hook.Regs
	levels: [2]Level(S)
	w: Walk(S, Member_Key, false, hook.NO_HOOKS_CAPS)
	walk_init(&w, r.src, &h, raw_data(levels[:]), 2, 2, r.opts)
	w.depth = 2
	res := run(&w, r.pos, 1, FLAG_OBJECT | 2, &regs, member_key_hook)
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

// Walks the record at `lo` for hook `h` from registers `regs`. Returns the walk's result `res` and whether it took a
// tolerance, the record's end as `hi`, and `ok` false once the records have ended, as a fault in a record ends them,
// or in a text in pieces when the window ends inside the record.
@(private)
record_walk :: proc(r: ^Records, $S: Spec, $LAX: bool, lo: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	concatenated := r.framing == .Concatenated
	limit := build.read_depth(r.opts)
	if !concatenated {
		limit -= 1 + u64(len(r.path)) + build.frame_level(&r.frame, len(r.path)).tagged
	}
	steps := steps_of(r.opts) if concatenated else r.steps
	res, tolerated, left := walk_item(r.src, lo, S, LAX, r.opts, limit, steps, h, regs, allocator, ctx, on)
	walked.res, walked.tolerated = res, tolerated || r.took
	end := res
	if u8(res) == hook.WALK_STOPPED {
		// The hook stopped the walk before the record's end. A walk with no hook finds the end, and `res` keeps the
		// stop for the caller.
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
		level_take(r, build.frame_level(&r.frame, len(r.path)), &r.next, S)
	}
	r.took = false
	walked.hi, walked.ok = u64(end) >> 16, true
	r.pos, r.at = walked.hi, .After
	return
}
