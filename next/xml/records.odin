package xml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The records of XML. A document's end is found only at the text's end, past its trailing comments and processing
// instructions, so under `.Concatenated` the record is the whole text from the records' position to its end, and a
// text of no bytes there holds none. Under `.Members` each member of the root element is a record keyed by its name:
// each child element, from its start tag through its end tag, and each `#text` run between them. One walk of the text
// reads them in place, pausing before each child and past it, so a member reads under the namespaces and the DTD of
// the text around it, and the comments and instructions between members are passed. A root with no child element
// holds none.

// The records of a text of `spec`.
Records :: struct {
	using records: tape.Records,
	spec:          Spec,
	// Under `.Members`, the walk the records go on in, and what it gave
	// before it paused: a `#text` run (`text`, its key and value) that waits to be framed, and the child at
	// `pause.at` that waits after it.
	walk:          Held_Walk,
	// The walk's frames, the root's first, past which a member's walk grows in the records' allocator.
	frames:        [WALK_LEVELS]Frame,
	ctx:           runtime.Context, // the context of the walk between members
	pause:         Pause,
	text:          [2]tape.Token,
	text_waits:    bool,
	child_waits:   bool,
	giving:        Member, // the member framed last
	// The walk read past the root, with this result.
	over:          bool,
	result:        u64,
	close:         proc(r: ^Records), // frees what the walk holds, as the records' release calls it
}

// The member a record under `.Members` gives.
@(private)
Member :: enum u8 {
	Text,
	Element,
}

// Opens the records of `src`, a text of `spec` framed as `framing`, each read under `opts`. Another format's options,
// `.Lines` and `.Elements`, which XML has no reading of, and a text in pieces under `.Members`, end the records with
// `tape.Bad_Option` before any is read. Under `.Concatenated` a text in pieces holds one record, the whole text, so no
// batch gives it before the last window, which must hold the text from its first byte. The budget's limits hold for
// each record, but `Budget.steps` under `.Members`, which counts the containers of the whole text.
records_open :: proc(src: []u8, framing := tape.Framing.Concatenated, spec := Spec.Xml, opts := Options{}) -> (r: Records) {
	if spec > max(Spec) {
		panic("xml: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts, r.allocator, r.close = src, framing, spec, opts, context.allocator, records_close
	if opts.pieces != nil {
		r.src = tape.piece_src(src, opts.pieces.from)
	}
	if err := tape.options_refused(&FORMATS[spec], opts); err != nil {
		r.err, r.at = err, .Done
	} else if framing == .Lines || framing == .Elements {
		r.err, r.at = tape.Bad_Option{"framing"}, .Done
	} else if opts.pieces != nil && framing != .Concatenated {
		r.err, r.at = tape.Bad_Option{"pieces"}, .Done
	}
	return
}

// Frees what the walk of the records under `.Members` holds, which their last record frees too.
records_close :: proc(r: ^Records) {
	if r.framing == .Members && r.at != .Start {
		ctx := context
		members_end(r, &ctx)
	}
}

// Reads the next records of `r` into `out` and judges each, as `validate` judges its bytes alone, and under `.Members`
// as the member of the text it is. Returns how many it filled, and fewer than `len(out)` once the records have ended,
// when `err` says why, nil at the text's end.
@(require_results)
records_validate :: proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> (n: int) {
	switch r.spec {
	case .Xml:
		if records_lax(r) {
			return records_validate_as(r, out, .Xml, true, allocator)
		}
		return records_validate_as(r, out, .Xml, false, allocator)
	}
	return
}

// Reads the next records of `r` into `out`, and for each the first value `path` reaches in it into the same place of
// `answers`, as `find` reads its bytes alone, with every offset from the text's first byte.
@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	switch r.spec {
	case .Xml:
		if records_lax(r) {
			return records_find_as(r, path, out, answers, .Xml, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Xml, false, read, allocator)
	}
	return
}

// Reads the next records of `r` into `out`, and for each the document of its nodes the paths of `demand` reach into the
// same place of `docs`, as `scan` reads its bytes alone. Each document is the caller's to free.
@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	switch r.spec {
	case .Xml:
		if records_lax(r) {
			return records_scan_as(r, demand, out, docs, .Xml, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Xml, false, read, allocator)
	}
	return
}

// Whether the records' walk is the `LAX` one: it counts `Budget.steps`, or it pauses at each member.
@(private)
records_lax :: #force_inline proc "contextless" (r: ^Records) -> bool {
	return r.opts.budget.steps != 0 || r.framing == .Members
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(r, lo, LAX, h, regs, a, ctx, hook.no_hook)
	}
	return build.records_validate(r, out, &FORMATS[S], &RULES, caller, record_frame, walk)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(r, lo, LAX, h, regs, a, ctx, build.finder_hook)
	}
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, respell, no_rewalk_find, record_frame, walk)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(r, lo, LAX, h, regs, a, ctx, build.scanner_hook)
	}
	return build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, no_rewalk_scan, node_bound, record_frame, walk)
}

// The next record's first byte and the text's end, false once the records have ended. Under `.Concatenated` the record
// is the text from the records' position, and under `.Members` the next member of the root.
@(private)
record_frame :: proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
	if r.at == .Done {
		return
	}
	if r.framing == .Members {
		return member_frame((^Records)(r))
	}
	if p := r.opts.pieces; p != nil && !p.last {
		// The record is the whole text, which the last window ends.
		r.at, r.pos = .Open, 0
		return
	}
	r.at = .Done
	if r.pos >= u64(len(r.src)) {
		return
	}
	return r.pos, u64(len(r.src)), true
}

// Walks the record at `lo` for hook `h` from registers `regs`, to the text's end, as the walk of its bytes alone does,
// or under `.Members` the member `record_frame` framed in its place.
@(private)
record_walk :: proc(r: ^tape.Records, lo: u64, $LAX: bool, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	when LAX {
		if r.framing == .Members {
			return member_walk((^Records)(r), h, regs, ctx, on)
		}
	}
	walked.res, walked.tolerated = walk_document(r.src, lo, LAX, r.opts, build.read_depth(r.opts), steps_of(r.opts), h, regs, allocator, ctx, on)
	walked.hi, walked.ok = u64(len(r.src)), true
	r.pos = walked.hi
	return
}

// The hook of the walk between members: it keeps the `#text` member the walk gives at the root's level and passes the
// rest. The document is its first level and the root's `Object` its second.
@(private)
Member_Framer :: struct {
	protocol: hook.Protocol(hook.NO_HOOKS_CAPS, hook.Unused, hook.Unused, hook.Unused),
	level:    u8,
	key:      tape.Token,
	text:     [2]tape.Token,
	has_text: bool,
}

@(private)
member_framer_hook :: proc "contextless" (h: ^Member_Framer, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	switch {
	case t.role > .Key:
	case t.kind == .End:
		h.level -= 1
	case t.role == .Key:
		h.key = t
	case t.kind == .Object:
		h.level += 1
	case h.level == 2:
		h.text, h.has_text = {h.key, t}, true
	}
	return s, .Next
}

// Frames the next member of the root, walking on from the last one to the next child or past the root when no member
// waits. A fault ends the records with it, after every member before it.
@(private)
member_frame :: proc(r: ^Records) -> (lo, cut: u64, ok: bool) {
	n := u64(len(r.src))
	base := raw_data(r.src)
	for {
		switch {
		case r.text_waits:
			r.text_waits, r.giving, r.key = false, .Text, r.text[0]
			return r.text[1].lo, n, true
		case r.child_waits:
			r.child_waits, r.giving = false, .Element
			at := r.pause.at
			q, _ := name_end(base[at + 1:], base[n:])
			r.key = {lo = at + 1, n = u32(intrinsics.ptr_sub(q, base[at + 1:])), kind = .String, role = .Key}
			return at, n, true
		case r.over:
			r.err = members_result(r)
			members_end(r, nil)
			return
		}
		members_walk(r)
	}
}

// The error of the walk's result `r.result`, nil for none.
@(private)
members_result :: proc "contextless" (r: ^Records) -> tape.Error {
	res := r.result
	if u8(res) == hook.WALK_STOPPED && r.walk.steps == 0 {
		res = u64(hook.walk_result(res >> 16, hook.WALK_STEPS))
	}
	_, err, _ := hook.walk_error(hook.Walk_Result(res), &RULES)
	return err
}

// Walks the text between two members with the framing hook, from the text's start or from past the last member, to
// the next child of the root or past the root.
@(private)
members_walk :: proc(r: ^Records) {
	r.ctx = context
	h: Member_Framer
	regs: hook.Regs
	if r.at == .Start {
		r.at = .Open
		x, _ := r.opts.format.(tape.Xml_Options)
		r.walk = {
			limit     = min(build.read_depth(r.opts), MAX_LEVELS),
			steps     = steps_of(r.opts),
			expansion = x.max_expansion,
			tier      = kernel.tier(),
			unread    = .Unread_Entity in r.opts.tolerate,
			infer     = x.infer,
		}
	} else {
		// The walk between members is in the root's `Object`.
		h.level = 2
	}
	r.pause.members, r.pause.floor = true, 0
	res, _ := members_resume(r, (^Walk(Member_Framer, true))(&r.walk), &h, &regs, &r.ctx, member_framer_hook)
	r.text, r.text_waits = h.text, h.has_text
	if u8(res) == hook.WALK_MORE {
		r.child_waits = true
	} else {
		r.over, r.result = true, res
	}
}

// Gives the member `member_frame` framed to hook `h` from registers `regs`: a `#text` run as its one token, or a child
// walked in place to its end tag, where the walk pauses. A fault or a step past the budget ends the records with it. A
// refusal of the hook is the record's, and a walk with no hook finds the child's end.
@(private)
member_walk :: proc(r: ^Records, h: ^$H, regs: ^hook.Regs, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	if r.giving == .Text {
		t := r.text[1]
		walked.hi, walked.ok = t.lo + u64(t.n), true
		walked.res = member_token(r, h, regs, t, on)
		r.pos, r.at = walked.hi, .After
		return
	}
	saved := Member_Saved{root = r.frames[0], ns_len = r.walk.ns_len, steps = r.walk.steps, at = r.pause.at}
	if t := r.walk.dtd; t != nil {
		saved.total, saved.depth, t.took = t.total, t.depth, false
	}
	r.pause.members, r.pause.floor = false, 2
	res, tolerated := members_resume(r, (^Walk(H, true))(&r.walk), h, regs, ctx, on)
	if u8(res) == hook.WALK_STOPPED && r.walk.steps != 0 {
		// The hook refused the member, which leaves the walk inside it, so a walk with no hook reads it again.
		member_restore(r, saved, ctx)
		none: hook.No_Hooks
		none_regs: hook.Regs
		if again, _ := members_resume(r, &r.walk, &none, &none_regs, ctx, hook.no_hook); u8(again) != hook.WALK_MORE {
			res = again
		}
	}
	if u8(res) != hook.WALK_MORE && (u8(res) != hook.WALK_STOPPED || r.walk.steps == 0) {
		r.over, r.result = true, res
		r.err = members_result(r)
		members_end(r, ctx)
		return
	}
	walked.hi, walked.ok, walked.tolerated = r.pause.at, true, tolerated
	walked.res = hook.walk_result(walked.hi, hook.WALK_STOPPED if u8(res) == hook.WALK_STOPPED else 0)
	r.pos, r.at = walked.hi, .After
	return
}

// What the walk of a member the hook refused is read again from: the walk's state at the member's start tag.
@(private)
Member_Saved :: struct {
	root:   Frame,
	ns_len: u32,
	depth:  u32,
	steps:  u64,
	total:  u64,
	at:     u64,
}

// Brings the records' walk back to the start of the member it read, freeing the namespace declarations it made.
@(private)
member_restore :: proc(r: ^Records, saved: Member_Saved, ctx: ^runtime.Context) {
	w := &r.walk
	w.ctx, w.allocator = ctx, r.allocator
	ns_release(w, w.ns[saved.ns_len:w.ns_len])
	w.ctx = nil
	w.ns_len, w.steps, r.frames[0] = saved.ns_len, saved.steps, saved.root
	if t := w.dtd; t != nil {
		t.depth, t.total = saved.depth, saved.total
	}
	r.pause.place, r.pause.at, r.pause.depth = .Member, saved.at, 1
}

// Gives the `#text` token `t` to hook `h` from registers `regs`, and the walk result past it.
@(private)
member_token :: proc(r: ^Records, h: ^$H, regs: ^hook.Regs, t: tape.Token, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	w := (^Walk(H, true))(&r.walk)
	w.hooks, w.regs = h, regs
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	hs := regs^
	e := emit(w, on, &hs, t.kind, .Value, t.lo, int(t.n), t.spelling)
	regs^ = hs
	w.hooks, w.regs = nil, nil
	return hook.walk_result(t.lo + u64(t.n), 0 if e == .Next else hook.WALK_STOPPED)
}

// Goes on with the records' walk for hook `h` from registers `regs`, in a frame of this call's that holds the root's,
// and returns its result and whether it tolerated a reference to an entity whose text is not read. A walk inside a
// replacement text goes on to its literal's end.
@(private)
members_resume :: proc(r: ^Records, w: ^Walk($H, true), h: ^H, regs: ^hook.Regs, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (u64, bool) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	walk_bind(w, raw_data(r.src), raw_data(r.frames[:]), h, regs, ctx)
	w.room, w.owned, w.allocator, w.pause, w.opened = WALK_LEVELS, false, r.allocator, &r.pause, regs.c
	w.mute, w.skip_value, w.mute_end, w.keep = 0, false, false, 0
	// A member's levels are those of a text of its bytes alone, under the root's.
	member := r.pause.place == .Member && !r.pause.members
	w.limit = min(build.read_depth(r.opts) + (1 if member else 0), MAX_LEVELS)
	w.depth = min(w.limit, WALK_LEVELS)
	when .Levels in C {
		if !member && hook.levels_held(h) <= int(regs.c) && !hook.levels_grow(h, int(regs.c) + 1, regs, 0) {
			return u64(hook.walk_result(0, hook.WALK_NO_MEMORY)), false
		}
		w.depth = min(w.depth, u64(hook.levels_held(h)) - regs.c + (1 if member else 0))
	}
	w.depth = max(w.depth, r.pause.depth)
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	end := raw_data(r.src)[len(r.src):]
	if t := w.dtd; t != nil {
		t.grab.ctx = ctx
		if t.depth > 0 {
			e := t.entities[t.stack[t.depth - 1].entity]
			end = w.base[e.lit_lo + u64(e.lit_n):]
		}
	}
	res := resume(w, r.src, end, regs^, on)
	tolerated := w.dtd != nil && w.dtd.took
	if w.owned {
		r.frames[0] = w.frames[0]
		frames_free(w)
	}
	w.hooks, w.regs, w.ctx, w.frames, w.owned = nil, nil, nil, nil, false
	if w.dtd != nil {
		w.dtd.grab.ctx = nil
	}
	return res, tolerated
}

// Frees what the records' walk holds, once.
@(private)
members_end :: proc(r: ^Records, ctx: ^runtime.Context) {
	w := &r.walk
	if w.dtd != nil {
		w.dtd.grab.ctx = nil
	}
	local := context
	w.ctx = ctx if ctx != nil else &local
	w.allocator = r.allocator
	walk_end(w, 0)
	w.ctx, w.ns, w.ns_len, w.ns_cap = nil, nil, 0, 0
	r.at = .Done
}
