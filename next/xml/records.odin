package xml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The records of XML. A document's end is found only at the text's end, past its trailing comments and processing
// instructions, so under `.Concatenated` the record is the whole text from the records' position to its end, and a
// text of no bytes there holds none. Under `.Members` each member of the root element, or of the element the `path`
// reaches below it, is a record keyed by its name: each child element, from its start tag through its end tag, and each
// `#text` run between them. One walk of the text reads them in place, pausing before each child and past it, so a
// member reads under the namespaces and the DTD of the text around it, and the comments and instructions between
// members are passed. An element with no child element holds none. In a text in pieces the walk pauses at a window's end
// too, and a member the window's end cuts is read again whole in the next window, from its start tag, which the window
// keeps with what the walk reads in place there.

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
	// The level of the walk between members, as its hook counts them.
	level:         u32,
	// The members the `path` takes by each step, as `Duplicates` says: with `.First` a bit per step, set once its
	// element took one, and with `.Last` whether a record was given, which a later member of the key cannot take back.
	taken:         [dynamic]u64,
	given:         bool,
	dups:          tape.Duplicates,
	// A member of the path's key met after a record was given under `.Last`, at this offset.
	repeat:        u64,
	repeated:      bool,
	// The walk read past the root, with this result.
	over:          bool,
	result:        u64,
	// In a text in pieces, the names of the open elements out of the window, and the start tag of the innermost while
	// it has given no `Object`, which the window keeps, `max(u64)` for none, as `window_hold` gives them.
	tags:          [dynamic]u8,
	inner:         u64,
}

// The member a record under `.Members` gives.
@(private)
Member :: enum u8 {
	Text,
	Element,
}

// Opens the records of `src`, a text of `spec` framed as `framing`, each read under `opts`. Another format's options,
// `.Lines` and `.Elements`, which XML has no reading of, and a `path` under `.Concatenated`, one with a step but a
// `Name` of a plain element name, or one the policy `opts.dups` refuses, end the records with `tape.Bad_Option` before
// any is read. Under `.Members` the path's steps lead from the root element to the element whose children are the
// records, and under it the records of an element repeated in the path follow one another in document order, as
// `tape.Records.path` says of the other formats. Under `.Concatenated` a text in pieces holds one record, the whole text, so no batch gives it before the
// last window, which must hold the text from its first byte. Under `.Members` a text in pieces opens with its first
// window, as `tape.Records` says. The budget's limits hold for
// each record, but `Budget.steps` under `.Members`, which counts the containers of the whole text.
records_open :: proc(src: []u8, framing := tape.Framing.Concatenated, spec := Spec.Xml, opts := Options{}, path: []tape.Step = nil) -> (r: Records) {
	if spec > max(Spec) {
		panic("xml: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts, r.allocator, r.release, r.path = src, framing, spec, opts, context.allocator, records_close, path
	r.tags.allocator, r.inner = context.allocator, max(u64)
	if opts.pieces != nil {
		r.src = tape.piece_src(src, opts.pieces.from)
	}
	if err := tape.options_refused(&FORMATS[spec], opts); err != nil {
		r.err, r.at = err, .Done
	} else if framing == .Lines || framing == .Seq || framing == .Elements {
		r.err, r.at = tape.Bad_Option{"framing"}, .Done
	} else if refused := build.records_path_refused(&FORMATS[spec], framing, path, opts); refused != nil {
		r.err, r.at = refused, .Done
	} else if len(path) > 0 {
		if !members_path_named(path) {
			r.err, r.at = tape.Bad_Option{"path"}, .Done
			return
		}
		r.dups = tape.read_dups(&FORMATS[spec], opts.dups)
		taken, e := make([dynamic]u64, (len(path) + 63) / 64, r.allocator)
		r.taken = taken
		if e != nil {
			r.err, r.at = e, .Done
		}
	}
	return
}

// Whether every step of `path` is a `Name` of an element the walk gives by its text: one the records can follow with no
// namespace scope, and few enough for the walk's frames to hold them.
@(private)
members_path_named :: proc "contextless" (path: []tape.Step) -> bool {
	if len(path) >= WALK_LEVELS - 1 {
		return false
	}
	for step in path {
		name, named := step.(tape.Name)
		if !named || len(name) > 0 && name[0] == '{' {
			return false
		}
	}
	return true
}

// Frees what the walk of the records under `.Members` holds, which their last record frees too.
@(private)
records_close :: proc(records: ^tape.Records) {
	r := (^Records)(records)
	if r.framing == .Members && r.at != .Start {
		ctx := context
		members_end(r, &ctx)
	}
	delete(r.tags)
	delete(r.taken)
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
	if expanded_step(path) {
		r.err, r.at = tape.Bad_Option{"path"}, .Done
		return
	}
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
// same place of `docs`, as `scan` reads its bytes alone. Documents live in `r.block` until the next batch or
// `tape.destroy_records`, as `tape.Record_Block` says.
@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	if expanded_demand(demand) {
		r.err, r.at = tape.Bad_Option{"path"}, .Done
		return
	}
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
	n := build.records_validate(r, out, &FORMATS[S], &RULES, caller, record_frame, walk)
	members_window_end(r)
	return n
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(r, lo, LAX, h, regs, a, ctx, build.finder_hook)
	}
	n := build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, respell, nil, record_frame, walk)
	members_window_end(r)
	return n
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	// In a text in pieces a member's document holds its bytes whole, as a scan in pieces does, from the internal subset
	// on once a reference was walked over its literal there or the subset declares a default, whose fact spans it.
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		h.scattered = r.opts.pieces != nil
		walked := record_walk(r, lo, LAX, h, regs, a, ctx, build.scanner_hook)
		if h.scattered {
			h.hold_from = lo
			if t := (^Records)(r).walk.dtd; t != nil && t.flags & {.In_Place, .Defaults} != {} {
				h.hold_from = min(lo, t.subset_lo)
			}
		}
		return walked
	}
	n := build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, nil, node_bound, record_frame, walk)
	members_window_end(r)
	// A member's facts hold none of the root's declarations.
	whole := demand.facts && r.framing != .Members
	for k in 0 ..< n {
		if out[k].err == nil {
			out[k].err = keep_scopes(&docs[k], whole)
		}
	}
	return n
}

// The next record's first byte and the text's end, false once the records have ended. Under `.Concatenated` the record
// is the text from the records' position, and under `.Members` the next member of the root.
@(private)
record_frame :: proc(r: ^tape.Records, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
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
	walked.res, walked.tolerated = walk_document(r.src, lo, LAX, r.opts, build.read_depth(r.opts), build.read_steps(r.opts), h, regs, allocator, ctx, on)
	walked.hi, walked.ok = u64(len(r.src)), true
	r.pos = walked.hi
	return
}

// The hook of the walk between members: it keeps the `#text` member the walk gives at the level of the element whose
// children are the records, skips each member of the elements before it that the path does not take at its key, and
// passes the rest. The document is its first level and the root's `Object` its second, and the `Object` of the element
// the path reaches its level `len(path) + 2`.
@(private)
Member_Framer :: struct {
	protocol: hook.Protocol(hook.NO_HOOKS_CAPS + {.Skips}, hook.Unused, hook.Unused, hook.Unused),
	r:        ^Records,
	level:    u32,
	key:      tape.Token,
	text:     [2]tape.Token,
	has_text: bool,
}

@(private)
member_framer_hook :: proc "contextless" (h: ^Member_Framer, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	r := h.r
	switch {
	case t.role > .Key:
	case t.kind == .End:
		h.level -= 1
	case t.role == .Key:
		h.key = t
		// A child of the element with `level - 1` open elements is a member of the path's step `level - 2`.
		if step := int(h.level) - 2; step >= 0 && step < len(r.path) {
			if taken, repeats := member_taken(r, step, t); !taken {
				return s, .Skip
			} else if repeats {
				r.repeat, r.repeated = t.lo - 1, true
				return s, .Stop
			}
		}
	case t.kind == .Object:
		h.level += 1
		if step := int(h.level) - 2; step >= 0 && step < len(r.path) {
			r.taken[step / 64] &~= 1 << uint(step % 64)
		}
	case int(h.level) == len(r.path) + 2:
		h.text, h.has_text = {h.key, t}, true
	}
	return s, .Next
}

// Whether the path's step `step` takes the child element with key `key`, a member of its container, as `r.dups` says,
// and whether it takes a member of the key after a record was given under `.Last`, which the records cannot take back.
@(private)
member_taken :: proc "contextless" (r: ^Records, step: int, key: tape.Token) -> (taken, repeats: bool) {
	if !tape.key_names(&FORMATS[r.spec], r.src, key, string(r.path[step].(tape.Name))) {
		return false, false
	}
	bit := u64(1) << uint(step % 64)
	#partial switch r.dups {
	case .First:
		taken = r.taken[step / 64] & bit == 0
		r.taken[step / 64] |= bit
		return
	case .Group:
		return true, false
	}
	return true, r.given
}

// Frames the next member of the root, walking on from the last one to the next child or past the root when no member
// waits. A fault ends the records with it, after every member before it. False too in a text in pieces once the window
// holds no more.
@(private)
member_frame :: proc(r: ^Records) -> (lo, cut: u64, ok: bool) {
	n := u64(len(r.src))
	base := raw_data(r.src)
	for {
		switch {
		case r.text_waits:
			r.text_waits, r.giving, r.given, r.key = false, .Text, true, r.text[0]
			return r.text[1].lo, n, true
		case r.child_waits:
			r.child_waits, r.giving, r.given = false, .Element, true
			at := r.pause.at
			q, _ := name_end(base[at + 1:], base[n:])
			r.key = {lo = at + 1, n = u32(intrinsics.ptr_sub(q, base[at + 1:])), kind = .String, role = .Key}
			return at, n, true
		case r.over:
			r.err = members_result(r)
			if r.repeated {
				r.err = tape.Fault{at = r.repeat, rules = &RULES, kind = .Duplicate_Key}
			}
			members_end(r, nil)
			return
		}
		if !members_walk(r) && !r.text_waits {
			return
		}
	}
}

// The error of the walk's result `r.result`, nil for none.
@(private)
members_result :: proc "contextless" (r: ^Records) -> tape.Error {
	_, err, _ := hook.walk_error(hook.steps_result(hook.Walk_Result(r.result), r.walk.steps), &RULES)
	return err
}

// Walks the text between two members with the framing hook, from the text's start or from past the last member, to
// the next child of the root or past the root. False in a text in pieces when the window ends first, and while its
// prolog is not whole.
@(private)
members_walk :: proc(r: ^Records) -> bool {
	r.ctx = context
	h := Member_Framer{r = r, level = r.level}
	regs: hook.Regs
	if r.at == .Start {
		if p := r.opts.pieces; p != nil && !p.last {
			units_frame(&r.pause.units, raw_data(r.src), u64(len(r.src)), true)
			if !r.pause.units.rooted {
				return false
			}
		}
		r.at = .Open
		walk_init(&r.walk, r.opts, build.read_depth(r.opts), build.read_steps(r.opts))
	}
	r.pause.members, r.pause.floor = u64(len(r.path)) + 1, 0
	res, _ := members_resume(r, (^Walk(Member_Framer, true))(&r.walk), &h, &regs, &r.ctx, member_framer_hook)
	r.text, r.text_waits, r.level = h.text, h.has_text, h.level
	if u8(res) != hook.WALK_MORE {
		r.over, r.result = true, res
	} else if r.pause.place == .Member {
		r.child_waits = true
	} else {
		return false
	}
	return true
}

// Gives the member `member_frame` framed to hook `h` from registers `regs`: a `#text` run as its one token, or a child
// walked in place to its end tag, where the walk pauses. A fault or a step past the budget ends the records with it. A
// refusal of the hook is the record's, and a walk with no hook finds the child's end. A child the window's end cuts
// leaves the walk at its start tag, for the next window, and gives no record.
@(private)
member_walk :: proc(r: ^Records, h: ^$H, regs: ^hook.Regs, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	if r.giving == .Text {
		t := r.text[1]
		walked.hi, walked.ok = t.lo + u64(t.n), true
		walked.res = member_token(r, h, regs, t, on)
		r.pos, r.at = walked.hi, .After
		member_dtd(r, h, &walked, ctx)
		return
	}
	depth := u64(len(r.path)) + 1
	saved := Member_Saved{root = r.frames[depth - 1], ns_len = r.walk.ns_len, steps = r.walk.steps, at = r.pause.at}
	if t := r.walk.dtd; t != nil {
		saved.total, saved.depth, t.took = t.total, t.depth, false
	}
	r.pause.members, r.pause.floor = 0, depth + 1
	res, tolerated := members_resume(r, (^Walk(H, true))(&r.walk), h, regs, ctx, on)
	if u8(res) == hook.WALK_STOPPED && r.walk.steps != 0 {
		// The hook refused the member, which leaves the walk inside it, so a walk with no hook reads it again.
		member_restore(r, saved, ctx)
		none: hook.No_Hooks
		none_regs: hook.Regs
		if again, _ := members_resume(r, &r.walk, &none, &none_regs, ctx, hook.no_hook); u8(again) != hook.WALK_MORE || member_cut(r) {
			res = again
		}
	}
	if u8(res) == hook.WALK_MORE && member_cut(r) {
		member_restore(r, saved, ctx)
		r.child_waits = true
		return
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
	member_dtd(r, h, &walked, ctx)
	return
}

// Gives the document hook `h` made of a member the DTD's tables, as a document of the whole text holds them, or makes
// the member's walk refused memory.
@(private)
member_dtd :: proc(r: ^Records, h: ^$H, walked: ^build.Record_Walk, ctx: ^runtime.Context) {
	if d := r.walk.dtd; d != nil && !dtd_give(d, raw_data(r.src), h, ctx) {
		walked.res = hook.walk_result(walked.hi, hook.WALK_NO_MEMORY)
	}
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

// Whether the records' walk paused inside the member it reads, at the window's end.
@(private)
member_cut :: #force_inline proc "contextless" (r: ^Records) -> bool {
	return r.pause.place == .Content && r.pause.depth > u64(len(r.path)) + 1
}

// Sets the keep of records of a text in pieces under `.Members` once a batch ends, past the pieces `build` set: the
// window keeps what `window_hold` says for the walk where it paused, and a `#text` member that waits. A refusal of
// memory ends the records with it.
@(private)
members_window_end :: proc(r: ^Records) {
	p := r.opts.pieces
	if p == nil || r.framing != .Members || r.at == .Start || r.at == .Done {
		return
	}
	w := &r.walk
	ctx := context
	w.stack, w.ctx, w.allocator = raw_data(r.frames[:]), &ctx, r.allocator
	keep, err := window_hold(w, r.pause.at, r.pause.depth, &r.tags, &r.inner)
	w.stack, w.ctx = nil, nil
	if err != nil {
		r.err = err
		members_end(r, &ctx)
		p.more = false
		return
	}
	if r.text_waits {
		keep = min(keep, r.text[1].lo)
	}
	p.keep = keep
}

// Brings the records' walk back to the start of the member it read, freeing the namespace declarations it made.
@(private)
member_restore :: proc(r: ^Records, saved: Member_Saved, ctx: ^runtime.Context) {
	w := &r.walk
	w.ctx, w.allocator = ctx, r.allocator
	ns_release(w, w.ns[saved.ns_len:w.ns_len])
	w.ctx = nil
	depth := u64(len(r.path)) + 1
	w.ns_len, w.steps, r.frames[depth - 1] = saved.ns_len, saved.steps, saved.root
	if t := w.dtd; t != nil {
		t.depth, t.total = saved.depth, saved.total
	}
	r.pause.place, r.pause.at, r.pause.depth = .Member, saved.at, depth
}

// Gives the `#text` token `t` to hook `h` from registers `regs`, and the walk result past it.
@(private)
member_token :: proc(r: ^Records, h: ^$H, regs: ^hook.Regs, t: tape.Token, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	w := (^Walk(H, true))(&r.walk)
	walk_bind(w, w.base, h, regs, w.ctx)
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
	// A member's levels are those of a text of its bytes alone, under the root's.
	m := u64(len(r.path)) + 1 if r.pause.place == .Member && r.pause.members == 0 else 0
	when .Levels in C {
		if m == 0 && hook.levels_held(h) <= int(regs.c) && !hook.levels_grow(h, int(regs.c) + 1, regs, 0) {
			return u64(hook.walk_result(0, hook.WALK_NO_MEMORY)), false
		}
	}
	walk_bind(w, raw_data(r.src), h, regs, ctx)
	w.stack, w.room, w.owned, w.allocator, w.pause, w.opened = raw_data(r.frames[:]), WALK_LEVELS, false, r.allocator, &r.pause, regs.c
	r.pause.end, r.pause.more = raw_data(r.src)[len(r.src):], r.opts.pieces != nil && !r.opts.pieces.last
	if d := r.pause.depth; r.inner != max(u64) && d > 0 {
		// The innermost open element's start tag is in the window, which may be another than the one it was read in.
		r.frames[d - 1].tag = raw_data(r.src)[r.inner:]
	}
	// The walk between members goes on skipping the element it skipped at its key, as it goes on from window to window.
	if r.pause.members == 0 {
		w.mute, w.skip_value, w.mute_end = 0, false, false
	}
	w.keep = 0
	w.limit = min(build.read_depth(r.opts) + m, MAX_LEVELS)
	w.depth = max(hook.held_depth(h, regs, min(w.limit, WALK_LEVELS) - m) + m, r.pause.depth)
	end := raw_data(r.src)[len(r.src):]
	if t := w.dtd; t != nil {
		t.src, t.grab.ctx = r.src, ctx
		if t.depth > 0 {
			e := t.entities[t.stack[t.depth - 1].entity]
			end = w.base[e.lit_lo + u64(e.lit_n):]
		}
	}
	res := resume(w, r.src, end, regs^, on)
	tolerated := w.dtd != nil && w.dtd.took
	if w.owned {
		copy(r.frames[:len(r.path) + 1], w.stack[:len(r.path) + 1])
		hook.levels_free(w)
	}
	w.hooks, w.regs, w.ctx, w.stack, w.owned = nil, nil, nil, nil, false
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
