package html

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import ops_build "stury:lib/ops/build"

// The records of an HTML5 text.
// Under `.Concatenated`, the single record is the whole text from the records' position to its end.
// Under `.Members`, each member of the container `path` reaches (the document's root object when `path` is nil)
// is a record in document order, keyed by its name (`Record.key`), as `next/toml` frames whole-text members.

Records :: struct {
	using records:  tape.Records,
	spec:           Spec,
	held:           tape.Document,
	has_held:       bool,
	tree_budget:    hook.Read_Budget,
	member_key:     tape.Node_Index,
	member_end:     tape.Node_Index,
	member_cur:     tape.Node_Index,
	member_scan:    tape.Node_Index,
	member_solo:    tape.Node_Index,
	member_solo_val: tape.Node_Index,
	members_remain: u32,
	dups:           tape.Duplicates,
	given:          bool,
}

records_open :: proc(src: []u8, framing := tape.Framing.Concatenated, spec := Spec.Html, opts := Options{}, path: []tape.Step = nil) -> (r: Records) {
	if spec > max(Spec) {
		panic("html: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts, r.release, r.allocator, r.path = src, framing, spec, opts, records_close, context.allocator, path
	r.member_cur, r.member_solo, r.member_solo_val = tape.NO_NODE, tape.NO_NODE, tape.NO_NODE
	if opts.pieces != nil {
		r.src = tape.piece_src(src, opts.pieces.from)
	}
	if err := tape.options_refused(&FORMATS[spec], opts); err != nil {
		r.err, r.at = err, .Done
	} else if framing == .Lines || framing == .Seq || framing == .Elements {
		r.err, r.at = tape.Bad_Option{"framing"}, .Done
	} else if refused := ops_build.records_path_refused(&FORMATS[spec], framing, path, opts); refused != nil {
		r.err, r.at = refused, .Done
	} else if opts.pieces != nil && framing != .Concatenated {
		r.err, r.at = tape.Bad_Option{"pieces"}, .Done
	}
	return
}

@(private)
records_close :: proc(records: ^tape.Records) {
	r := (^Records)(records)
	if r.has_held {
		tape.destroy(&r.held)
		r.has_held = false
	}
}

@(require_results)
records_validate :: proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> (n: int) {
	lax := ops_build.read_lax(r.opts)
	switch r.spec {
	case .Html:
		return records_validate_as(r, out, .Html, true, allocator) if lax else records_validate_as(r, out, .Html, false, allocator)
	case .Fragment:
		return records_validate_as(r, out, .Fragment, true, allocator) if lax else records_validate_as(r, out, .Fragment, false, allocator)
	}
	return
}

@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	lax := ops_build.read_lax(r.opts)
	switch r.spec {
	case .Html:
		return records_find_as(r, path, out, answers, .Html, true, read, allocator) if lax else records_find_as(r, path, out, answers, .Html, false, read, allocator)
	case .Fragment:
		return records_find_as(r, path, out, answers, .Fragment, true, read, allocator) if lax else records_find_as(r, path, out, answers, .Fragment, false, read, allocator)
	}
	return
}

@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	lax := ops_build.read_lax(r.opts)
	switch r.spec {
	case .Html:
		return records_scan_as(r, demand, out, docs, .Html, true, read, allocator) if lax else records_scan_as(r, demand, out, docs, .Html, false, read, allocator)
	case .Fragment:
		return records_scan_as(r, demand, out, docs, .Fragment, true, read, allocator) if lax else records_scan_as(r, demand, out, docs, .Fragment, false, read, allocator)
	}
	return
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return html_record_frame(container_of(r, Records, "records"), S, allocator)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> ops_build.Record_Walk {
		return html_record_walk(container_of(r, Records, "records"), lo, cut, S, LAX, h, regs, a, ctx, hook.no_hook)
	}
	return ops_build.records_validate(r, out, &FORMATS[S], &RULES, caller, frame, walk)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return html_record_frame(container_of(r, Records, "records"), S, allocator)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^ops_build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> ops_build.Record_Walk {
		return html_record_walk(container_of(r, Records, "records"), lo, cut, S, LAX, h, regs, a, ctx, ops_build.finder_key_skip_hook)
	}
	return ops_build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, respell, nil, frame, walk)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
		return html_record_frame(container_of(r, Records, "records"), S, allocator)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^ops_build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> ops_build.Record_Walk {
		h.scattered = r.opts.pieces != nil
		if h.scattered {
			h.hold_from = lo
		}
		return html_record_walk(container_of(r, Records, "records"), lo, cut, S, LAX, h, regs, a, ctx, ops_build.scanner_key_skip_hook)
	}
	n := ops_build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, nil, node_bound, frame, walk)
	if r.framing == .Members && r.has_held && r.held.ext != nil {
		for k in 0 ..< n {
			v_idx := find_member_val(r, out[k])
			if out[k].err == nil && v_idx != tape.NO_NODE {
				if serr := subdoc_state(&r.held, &docs[k], v_idx, tape.node_after(&r.held, v_idx) - v_idx, docs[k].allocator); serr != nil && r.err == nil {
					r.err = serr
				}
			}
		}
	}
	return n
}

@(private)
find_member_val :: proc "contextless" (r: ^Records, rec: tape.Record) -> tape.Node_Index {
	if r.member_solo_val != tape.NO_NODE {
		vn := r.member_solo_val
		if r.held.nodes[vn].lo == rec.lo {
			r.member_solo_val = tape.NO_NODE
			return vn
		}
		return tape.NO_NODE
	}
	kn := r.member_scan
	for kn < r.member_end {
		vn := tape.node_after(&r.held, kn)
		after := tape.node_after(&r.held, vn)
		if r.held.nodes[kn] == rec.key && r.held.nodes[vn].lo == rec.lo {
			r.member_scan = after
			return vn
		}
		kn = after
	}
	return tape.NO_NODE
}

@(private)
html_record_frame :: proc(r: ^Records, $S: Spec, allocator: runtime.Allocator) -> (lo, cut: u64, ok: bool) {
	if r.at == .Done {
		return
	}
	if r.framing == .Concatenated {
		if p := r.opts.pieces; p != nil && !p.last {
			r.at, r.pos = .Open, 0
			return
		}
		r.at = .Done
		if r.pos >= u64(len(r.src)) {
			return
		}
		return r.pos, u64(len(r.src)), true
	}
	if r.at == .Start {
		_ = allocator
		if !open_members(r, S) {
			return
		}
	}
	if r.member_solo != tape.NO_NODE {
		vn := r.member_solo
		r.member_solo = tape.NO_NODE
		r.member_cur = vn
		val := r.held.nodes[vn]
		r.key = tape.Token{
			lo       = val.lo,
			n        = 0,
			kind     = .String,
			role     = .Key,
			spelling = tape.SPELLING_DECODE | tape.SPELLING_TEXT_KEY,
		}
		return val.lo, val.lo + u64(val.n), true
	}
	for r.member_key < r.member_end {
		kn := r.member_key
		vn := tape.node_after(&r.held, kn)
		after := tape.node_after(&r.held, vn)
		r.member_key = after
		r.member_cur = vn
		r.key = r.held.nodes[kn]
		val := r.held.nodes[vn]
		hi, has := close_end(&r.held, vn)
		if !has || val.kind <= .Plain {
			hi = val.lo + u64(val.n)
		}
		return val.lo, max(val.lo, hi), true
	}
	r.member_cur = tape.NO_NODE
	r.at = .Done
	return
}

@(private)
open_members :: proc(r: ^Records, $S: Spec) -> bool {
	doc, err := build_as_inner(r.src, S, r.opts, {}, r.allocator, &r.tree_budget)
	if err != nil {
		r.err, r.at = err, .Done
		return false
	}
	r.held = doc
	r.has_held = true
	if len(doc.nodes) == 0 {
		r.at = .Done
		return false
	}
	// Resolve `r.path` inside `doc` iteratively.
	cur := tape.ROOT
	dups := tape.read_dups(&FORMATS[S], r.opts.dups)
	rd := tape.Reader{doc = &r.held}
	for step in r.path {
		if doc.nodes[cur].kind == .Null {
			r.at = .Done
			return false
		}
		switch s in step {
		case tape.Name:
			next, p := tape.member(rd, cur, string(s), dups)
			if p != .Found {
				if p == .Wrong_Kind {
					r.err = ops_build.records_kind_refusal()
				}
				r.at = .Done
				return false
			}
			cur = next
		case tape.Index:
			next, p := tape.element(rd, cur, int(s))
			if p != .Found {
				if p == .Wrong_Kind {
					r.err = ops_build.records_kind_refusal()
				}
				r.at = .Done
				return false
			}
			cur = next
		case tape.All, tape.Slice, tape.Descend:
			r.err = tape.Bad_Option{"path"}
			r.at = .Done
			return false
		}
	}
	if doc.nodes[cur].kind != .Object {
		if len(r.path) > 0 && doc.nodes[cur].kind <= .Plain && doc.nodes[cur].kind != .Null {
			r.at = .Open
			r.member_solo = cur
			r.member_solo_val = cur
			return true
		}
		if doc.nodes[cur].kind != .Null {
			r.err = tape.Bad_Option{"framing"}
		}
		r.at = .Done
		return false
	}
	r.at = .Open
	r.member_key = cur + 1
	r.member_scan = cur + 1
	r.member_end = tape.node_after(&r.held, cur)
	return true
}

@(private)
html_record_walk :: proc(
	r: ^Records,
	lo, cut: u64,
	$S: Spec,
	$LAX: bool,
	h: ^$H,
	regs: ^hook.Regs,
	allocator: runtime.Allocator,
	ctx: ^runtime.Context,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
) -> (walked: ops_build.Record_Walk) {
	if r.framing == .Concatenated {
		tree_spec := Tree_Spec.Fragment if S == .Fragment else .Document
		// `.Concatenated` record validation judges recoverability like `build`/`find`/`scan` (see `html/records.odin:24` and `testkit/laws.odin:validate_keeps_faults`).
		res, tolerated := walk_tree_res(r.src, tree_spec, r.opts, {}, lo, LAX, h, regs, allocator, ctx, on, nil)
		r.pos = u64(len(r.src))
		return {res = res, hi = r.pos, tolerated = tolerated, ok = true}
	}
	// `.Members`: replay the pre-built node subtree for the framed member into hook `h`.
	v := r.member_cur
	if v == tape.NO_NODE || int(v) >= len(r.held.nodes) {
		return {res = hook.walk_result(lo, 0), hi = cut, ok = true}
	}
	res := emit_held_member(&r.held, v, h, regs, allocator, on)
	return {res = res, hi = cut, ok = true}
}

@(private = "file")
Held_Open :: struct {
	node:   tape.Node_Index,
	end:    tape.Node_Index,
	tag:    u64,
	end_lo: u64,
}

@(private = "file")
Held_Replay :: struct($H: typeid) {
	doc:         ^tape.Document,
	h:           ^H,
	regs:        ^hook.Regs,
	mute:        u64,
	mute_end:    bool,
	skip_value:  bool,
	keep:        u64,
	keep_stubs:  bool,
	open_depth:  int,
	held_levels: int,
	rooms:       uintptr,
}

@(private = "file")
held_give_token :: #force_inline proc(
	st: ^Held_Replay($H),
	tok: tape.Token,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
) -> (action: hook.Action, ok: bool) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	when .Keeps in C {
		if st.keep != 0 {
			K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
			Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
			IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
			when .Rooms in IC {
				if tok.kind != .End && tok.role <= .Key {
					inner := (^Inner)(hook.keeps_inner(st.h))
					if uintptr(st.regs.a) == hook.rooms_end(inner) && !hook.rooms_grow(inner, st.regs, tok.lo) {
						return .Stop, false
					}
				}
			}
			ia: hook.Action
			if st.keep_stubs {
				st.regs^, ia = hook.keeps_give(st.h, st.regs^, tok, true)
			} else {
				st.regs^, ia = hook.keeps_give(st.h, st.regs^, tok, false)
			}
			return ia, true
		}
	}
	when .Rooms in C {
		if tok.kind != .End && tok.role <= .Key && uintptr(st.regs.a) == st.rooms {
			if !hook.rooms_grow(st.h, st.regs, tok.lo) {
				return .Stop, false
			}
			st.rooms = hook.rooms_end(st.h)
		}
	}
	a: hook.Action
	st.regs^, a = on(st.h, st.regs^, tok)
	return a, true
}

@(private = "file")
held_emit_fact :: #force_inline proc(
	st: ^Held_Replay($H),
	f: tape.Fact,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
) -> (res: hook.Walk_Result, stop: bool) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	when .Skips in C {
		if st.mute != 0 {
			return 0, false
		}
	}
	role := tape.Role(u8(f.kind) + u8(tape.Role.Comment))
	ft := tape.Token{lo = f.lo, n = f.n, kind = .Plain, role = role, spelling = f.spelling}
	a, ok := held_give_token(st, ft, on)
	if !ok {
		return hook.walk_result(f.lo, hook.WALK_NO_MEMORY), true
	}
	if a == .Stop {
		return hook.walk_result(f.lo, hook.WALK_STOPPED), true
	}
	return 0, false
}

@(private = "file")
held_close_container :: proc(
	st: ^Held_Replay($H),
	op: Held_Open,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
) -> (res: hook.Walk_Result, stop: bool) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	for f in tape.facts_of(st.doc, op.node) {
		if f.kind == .Comment_Foot || f.kind == .Instruction_Foot {
			if r, s := held_emit_fact(st, f, on); s {
				return r, true
			}
		}
	}
	end_tok := tape.Token{lo = op.end_lo, kind = .End, role = .Value}
	when .Skips in C {
		if st.mute == op.tag {
			st.mute = 0
			if st.mute_end {
				st.mute_end = false
				return 0, false
			}
		} else if st.mute != 0 {
			return 0, false
		}
	}
	when .Keeps in C {
		if st.keep == op.tag {
			ia, ok := held_give_token(st, end_tok, on)
			if !ok {
				return hook.walk_result(op.end_lo, hook.WALK_NO_MEMORY), true
			}
			st.keep = 0
			st.keep_stubs = false
			st.open_depth -= 1
			when .Rooms in C {
				st.rooms = hook.rooms_end(st.h)
			}
			when .Levels in C {
				st.held_levels = hook.levels_held(st.h)
			}
			if ia == .Stop {
				return hook.walk_result(op.end_lo, hook.WALK_STOPPED), true
			}
			a, ok2 := held_give_token(st, end_tok, on)
			if !ok2 {
				return hook.walk_result(op.end_lo, hook.WALK_NO_MEMORY), true
			}
			if a == .Stop {
				return hook.walk_result(op.end_lo, hook.WALK_STOPPED), true
			}
			return 0, false
		}
	}
	st.open_depth -= 1
	a, ok := held_give_token(st, end_tok, on)
	if !ok {
		return hook.walk_result(op.end_lo, hook.WALK_NO_MEMORY), true
	}
	if a == .Stop {
		return hook.walk_result(op.end_lo, hook.WALK_STOPPED), true
	}
	return 0, false
}

// Replays pre-built subtree `root_val` of `doc` (facts + nodes + Ends) into hook `h`.
@(private)
emit_held_member :: proc(
	doc: ^tape.Document,
	root_val: tape.Node_Index,
	h: ^$H,
	regs: ^hook.Regs,
	allocator: runtime.Allocator,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
) -> hook.Walk_Result {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	end := tape.node_after(doc, root_val)
	open_ends: [dynamic]Held_Open
	open_ends.allocator = allocator
	defer delete(open_ends)

	st := Held_Replay(H){doc = doc, h = h, regs = regs}
	when .Rooms in C {
		st.rooms = hook.rooms_end(h)
	}
	when .Levels in C {
		st.held_levels = hook.levels_held(h)
	}

	fi := 0
	for fi < len(doc.facts) && doc.facts[fi].node < root_val {
		fi += 1
	}

	for i := root_val; i < end; i += 1 {
		for len(open_ends) > 0 && open_ends[len(open_ends) - 1].end == i {
			op := pop(&open_ends)
			if r, stop := held_close_container(&st, op, on); stop {
				return r
			}
		}
		nd := doc.nodes[i]
		is_container := nd.kind > .Plain
		for fi < len(doc.facts) && doc.facts[fi].node == i {
			f := doc.facts[fi]
			fi += 1
			if is_container && (f.kind == .Comment_Foot || f.kind == .Instruction_Foot) {
				continue
			}
			if r, stop := held_emit_fact(&st, f, on); stop {
				return r
			}
		}
		tok := nd
		end_idx := tape.NO_NODE
		end_lo := nd.lo
		if is_container {
			tok.n = 0
			tok.spelling = 0
			end_idx = i + tape.Node_Index(nd.n)
			ce, has_ce := close_end(doc, i)
			end_lo = ce if has_ce else nd.lo
		}
		open_tag := u64(i) + 1
		when .Skips in C {
			if st.mute != 0 {
				if is_container {
					if _, err := append(&open_ends, Held_Open{node = i, end = end_idx, tag = open_tag, end_lo = end_lo}); err != nil {
						return hook.walk_result(nd.lo, hook.WALK_NO_MEMORY)
					}
				}
				continue
			}
			if st.skip_value && tok.role == .Value {
				st.skip_value = false
				if is_container {
					if _, err := append(&open_ends, Held_Open{node = i, end = end_idx, tag = open_tag, end_lo = end_lo}); err != nil {
						return hook.walk_result(nd.lo, hook.WALK_NO_MEMORY)
					}
					st.mute = open_tag
					st.mute_end = true
				}
				continue
			}
		}
		if is_container {
			when .Levels in C {
				if st.keep == 0 && st.open_depth >= st.held_levels {
					want := max(st.held_levels * 2, st.open_depth + 1)
					if !hook.levels_grow(h, want, regs, nd.lo) {
						return hook.walk_result(nd.lo, hook.WALK_NO_MEMORY)
					}
					st.held_levels = hook.levels_held(h)
					when .Rooms in C {
						st.rooms = hook.rooms_end(h)
					}
				}
			}
		}
		a, ok := held_give_token(&st, tok, on)
		if !ok {
			return hook.walk_result(nd.lo, hook.WALK_NO_MEMORY)
		}
		if a == .Stop {
			return hook.walk_result(nd.lo, hook.WALK_STOPPED)
		}
		if is_container {
			if _, err := append(&open_ends, Held_Open{node = i, end = end_idx, tag = open_tag, end_lo = end_lo}); err != nil {
				return hook.walk_result(nd.lo, hook.WALK_NO_MEMORY)
			}
			st.open_depth += 1
			when .Skips in C {
				if st.keep == 0 {
					#partial switch a {
					case .Skip:
						st.mute = open_tag
					case .Rest:
						st.mute = max(u64)
					case .Keep, .Keep_Stubs:
						when .Keeps in C {
							st.keep = open_tag
							st.keep_stubs = a == .Keep_Stubs
							ia, ok2 := held_give_token(&st, tok, on)
							if !ok2 {
								return hook.walk_result(nd.lo, hook.WALK_NO_MEMORY)
							}
							if ia == .Stop {
								return hook.walk_result(nd.lo, hook.WALK_STOPPED)
							}
						}
					}
				}
			}
		} else {
			when .Skips in C {
				if st.keep == 0 && tok.role == .Key && a == .Skip {
					st.skip_value = true
				}
			}
		}
	}
	for len(open_ends) > 0 {
		op := pop(&open_ends)
		if r, stop := held_close_container(&st, op, on); stop {
			return r
		}
	}
	return hook.walk_result(doc.nodes[root_val].lo, 0)
}
