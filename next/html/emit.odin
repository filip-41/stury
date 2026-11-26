package html

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/markup"
import "stury:lib/core/tape"

// Emits an `Html_Tree` into any v2 hook (`Builder`, `Finder`, `Scanner`, `Checker`, `testkit.Probe`, etc.) in
// document preorder, keeping zero native recursion and respecting every hook capability (`.Rooms`, `.Levels`,
// `.Skips`, `.Keeps`, `.Unspelled`, `Budget.steps`, cooperative stop/cancel).

@(private)
CONTAINER_ROOT :: max(u64) - 1

@(private)
Emitter :: struct($H: typeid, $LAX: bool) {
	t:           ^Html_Tree,
	h:           ^H,
	regs:        hook.Regs,
	spec:        Tree_Spec,
	keep_state:  ^Kept,
	run:         [dynamic]Span,
	stopped:     bool,
	no_memory:   bool,
	wide:        bool,
	hi:          u64,
	fault_at:    u64,
	steps:       u64,
	open_depth:  int, // open containers currently held by outer or kept hook
	held_levels: int, // outer or kept hook's levels capacity
	rooms:       uintptr,
	mute:        u64, // > 0 when skipping current container (1-based `open_at`, `max(u64)` for `.Rest`)
	mute_end:    bool,
	skip_value:  bool,
	keep:        u64, // > 0 when delegating container to `.Keeps` inner hook
	keep_stubs:  bool,
	infer:       bool,
}

@(private)
emit_tree_walk :: proc(
	t: ^Html_Tree,
	tree_spec: Tree_Spec,
	opts: Options,
	h: ^$H,
	regs: ^hook.Regs,
	steps: u64,
	keep_state: ^Kept,
	$LAX: bool,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
) -> u64 {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	infer := false
	if xo, is_xml := opts.format.(tape.Xml_Options); is_xml {
		infer = xo.infer
	}
	e := Emitter(H, LAX) {
		t          = t,
		h          = h,
		regs       = regs^,
		spec       = tree_spec,
		keep_state = keep_state,
		steps      = steps,
		infer      = infer,
	}
	e.run.allocator = t.ctx.allocator
	defer delete(e.run)
	when .Levels in C {
		e.held_levels = hook.levels_held(h)
	}
	when .Rooms in C {
		e.rooms = hook.rooms_end(h)
	}
	defer regs^ = e.regs

	emit_tree(&e, on)

	if e.wide {
		return u64(hook.walk_result(e.fault_at, u8(tape.Fault_Kind.Too_Wide)))
	}
	if e.no_memory {
		return u64(hook.walk_result(e.hi, hook.WALK_NO_MEMORY))
	}
	if e.stopped {
		return u64(hook.steps_result(hook.walk_result(e.hi, hook.WALK_STOPPED), e.steps))
	}
	return u64(hook.walk_result(u64(len(t.src)), 0))
}

@(private)
emit_tree :: proc(
	e: ^Emitter($H, $LAX),
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
) {
	t := e.t
	top := DOCUMENT
	if e.spec == .Fragment {
		top = tree_node(t, DOCUMENT).first
	}
	parent := top
	child := tree_node(t, top).first
	prev, opening := false, true
	for !e.stopped {
		next, shut := emit_content(e, on, parent, child, prev, opening, top)
		if e.stopped {
			return
		}
		if next == 0 {
			if !shut {
				lo := u64(len(t.src)) if parent == top else tree_node(t, parent).end
				tag := CONTAINER_ROOT if parent == top else u64(parent)
				_ = emit_close(e, on, tag, lo)
				if e.stopped {
					return
				}
				if e.keep_state != nil && parent != top {
					if ko := &e.keep_state.open; len(ko) > 0 && ko[len(ko) - 1].tag == tag {
						entry := pop(ko)
						if _, err := append(&e.keep_state.ends, End_Entry{node = entry.node, end = lo}); err != nil {
							e.keep_state.oom = true
							e.no_memory = true
							e.stopped = true
							return
						}
					}
				}
			}
			if parent == top {
				return
			}
			child, parent = tree_node(t, parent).next, tree_node(t, parent).parent
			prev, opening = true, false
			continue
		}
		if !emit_element(e, on, next) {
			child, prev, opening = tree_node(t, next).next, true, false
			continue
		}
		parent, child = next, tree_node(t, next).first
		prev, opening = false, true
	}
}

@(private)
emit_content :: proc(
	e: ^Emitter($H, $LAX),
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
	parent, from: u32,
	prev, opening: bool,
	top: u32,
) -> (next: u32, shut: bool) {
	t := e.t
	end := from
	last_text := u32(0)
	for end != 0 && tree_node(t, end).kind != .Element {
		if tree_node(t, end).kind == .Text && has_char(t, end) {
			last_text = end
		}
		end = tree_node(t, end).next
	}
	if opening && parent != top && end != 0 && !give_open(e, on, parent, end, top) {
		return 0, true
	}
	lead := head_end(e, from, end) if opening && parent == top else max(u32)
	seen := last_text == 0
	text_seen := false
	next_line := !prev
	for k := from; k != end; k = tree_node(t, k).next {
		if k == lead && !give_open(e, on, parent, end, top) {
			return 0, true
		}
		n := tree_node(t, k)
		switch n.kind {
		case .Text:
			if k == last_text {
				seen = true
			}
			if !text_seen && has_char(t, k) {
				text_seen = true
			}
		case .Comment:
			foot := end == 0 && seen && !opening
			role := tape.Role.Comment_Foot if foot else .Comment
			if prev && !text_seen {
				if !next_line && newline_before(t.src, n.lo) {
					next_line = true
				}
				if !next_line {
					role = .Comment_Inline
				}
			}
			if give_fact(e, on, .Plain, role, n.lo, n.hi - n.lo, markers(n.lo, n.hi, n.name.lo, n.name.lo + u64(n.name.n))) == .Stop {
				return 0, true
			}
			if has_newline(t.src[n.lo:n.hi]) {
				next_line = true
			}
		case .Instruction:
			foot := end == 0 && seen && !opening
			role := tape.Role.Instruction_Foot if foot else .Instruction
			data := t.pieces[n.a].span
			body_end := data.lo + u64(data.n) if data.n > 0 else n.name.lo + u64(n.name.n)
			if give_fact(e, on, .Plain, role, n.lo, n.hi - n.lo, markers(n.lo, n.hi, n.name.lo, body_end)) == .Stop {
				return 0, true
			}
		case .Doctype:
			if give_fact(e, on, .Plain, .Doctype, n.lo, n.hi - n.lo) == .Stop {
				return 0, true
			}
		case .Document, .Element:
		}
	}
	if lead == end && !give_open(e, on, parent, end, top) {
		return 0, true
	}
	if last_text != 0 {
		if give(e, on, .String, .Key, tree_node(t, last_text).lo, 0, tape.SPELLING_DECODE | markup.SPELLING_TEXT_KEY) == .Stop {
			return 0, true
		}
		if !text_value(e, on, from, end, 0, tree_node(t, parent).end if parent != top else max(u64)) {
			return 0, true
		}
	}
	return end, false
}

@(private)
head_end :: proc(e: ^Emitter($H, $LAX), from, end: u32) -> u32 {
	lead := from
	for k := from; k != end; k = tree_node(e.t, k).next {
		next := tree_node(e.t, k).next
		if tree_node(e.t, k).kind == .Doctype {
			lead = next
		} else if next != 0 && tree_node(e.t, next).lo > tree_node(e.t, k).hi && kernel.count_byte(e.t.src[tree_node(e.t, k).hi:tree_node(e.t, next).lo], '\n') > 1 {
			lead = next
		}
	}
	return lead
}

@(private)
give_open :: #force_inline proc(
	e: ^Emitter($H, $LAX),
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
	parent, end, top: u32,
) -> bool {
	lo, n: u64
	if parent == top {
		lo = tree_node(e.t, end).lo if end != 0 && e.spec == .Document else 0
	} else {
		p := tree_node(e.t, parent)
		lo, n = p.lo, p.hi - p.lo
	}
	tag := CONTAINER_ROOT if parent == top else u64(parent)
	prev_c := e.regs.c
	a := give(e, on, .Object, .Value, lo, n, 0, tag)
	if e.stopped {
		return false
	}
	_ = a
	if e.keep_state != nil && parent != top && e.regs.c > prev_c {
		if _, err := append(&e.keep_state.open, Open_Entry{tag = tag, node = u32(e.regs.b >> 32)}); err != nil {
			e.keep_state.oom = true
			e.no_memory = true
			e.stopped = true
			return false
		}
	}
	return true
}

@(private)
emit_element :: proc(
	e: ^Emitter($H, $LAX),
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
	n: u32,
) -> bool {
	t := e.t
	node := tree_node(t, n)
	key := key_of(t, node)
	key_action := give(e, on, key.kind, key.role, key.lo, u64(key.n), key.spelling)
	if e.stopped {
		return false
	}
	_ = key_action
	for a in t.attrs[node.a:][:node.b] {
		lo, hi, spelling := attribute_fact(t.src, a)
		if give_fact(e, on, .Plain, .Attribute, lo, hi - lo, spelling) == .Stop {
			return false
		}
	}
	has_elem := false
	for c := node.first; c != 0; c = tree_node(t, c).next {
		if tree_node(t, c).kind == .Element {
			has_elem = true
			break
		}
	}
	if has_elem {
		// If `skip_value` skipped this `.Object` at its key, either count its steps (when `LAX`) and jump over its
		// subtree without emitting its tokens or closing `.End`, or traverse when `mute == 0`.
		if e.skip_value || e.mute != 0 {
			when LAX {
				if e.skip_value {
					e.skip_value = false
					count_skipped_objects(e, n)
					return false
				}
			}
			if e.skip_value {
				e.skip_value = false
				return false
			}
		}
		return true
	}
	for c := node.first; c != 0; c = tree_node(t, c).next {
		child := tree_node(t, c)
		#partial switch child.kind {
		case .Comment:
			if give_fact(e, on, .Plain, .Comment_Foot, child.lo, child.hi - child.lo, markers(child.lo, child.hi, child.name.lo, child.name.lo + u64(child.name.n))) == .Stop {
				return false
			}
		case .Instruction:
			data := t.pieces[child.a].span
			body_end := data.lo + u64(data.n) if data.n > 0 else child.name.lo + u64(child.name.n)
			if give_fact(e, on, .Plain, .Instruction_Foot, child.lo, child.hi - child.lo, markers(child.lo, child.hi, child.name.lo, body_end)) == .Stop {
				return false
			}
		}
	}
	empty_at := node.lo if .Implied in node.flags else node.hi
	_ = text_value(e, on, node.first, 0, empty_at, node.end)
	return false
}

// Counts skipped nested `.Object` containers under element `n` (inclusive) against `e.steps` when `$LAX`.
@(private, cold)
count_skipped_objects :: proc(e: ^Emitter($H, $LAX), root: u32) {
	t := e.t
	cur := root
	for cur != 0 {
		has_child_elem := false
		for c := tree_node(t, cur).first; c != 0; c = tree_node(t, c).next {
			if tree_node(t, c).kind == .Element {
				has_child_elem = true
				break
			}
		}
		if has_child_elem {
			e.steps -= 1
			if e.steps == 0 {
				e.hi = tree_node(t, cur).lo
				e.stopped = true
				return
			}
			first_elem := tree_node(t, cur).first
			for first_elem != 0 && tree_node(t, first_elem).kind != .Element {
				first_elem = tree_node(t, first_elem).next
			}
			cur = first_elem
			continue
		}
		if cur == root {
			return
		}
		for {
			nxt := tree_node(t, cur).next
			for nxt != 0 && tree_node(t, nxt).kind != .Element {
				nxt = tree_node(t, nxt).next
			}
			if nxt != 0 {
				cur = nxt
				break
			}
			cur = tree_node(t, cur).parent
			if cur == root || cur == 0 {
				return
			}
		}
	}
}

@(private)
text_value :: proc(
	e: ^Emitter($H, $LAX),
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
	from, end: u32,
	empty_at, limit: u64,
) -> bool {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	t := e.t
	clear(&e.run)
	lo, hi := empty_at, empty_at
	decoded_any := false
	has_misc := false
	frozen := false
	for k := from; k != end; k = tree_node(t, k).next {
		n := tree_node(t, k)
		if n.kind != .Text {
			has_misc = true
			continue
		}
		frozen ||= .Moved in n.flags
		for p := n.a;; p = t.pieces[p].next {
			s := t.pieces[p].span
			if len(e.run) == 0 {
				lo, hi = s.lo, s.lo
			}
			lo, hi = min(lo, s.lo), max(hi, s.lo + u64(s.n))
			decoded_any ||= s.flags & DECODED != {}
			if _, err := append(&e.run, s); err != nil {
				e.no_memory = true
				e.stopped = true
				return false
			}
			if p == n.b {
				break
			}
		}
	}
	if len(e.run) == 0 {
		// Empty leaf HTML element (no text runs, no child elements) emits `.Null` matching v2 markup shape.
		return give(e, on, .Null, .Value, empty_at, 0, 0) != .Stop
	}
	if lo < limit && hi > limit {
		hi = 0
		for s in e.run {
			if s.lo < limit {
				hi = max(hi, s.lo + u64(s.n))
			}
		}
	}
	if e.infer && len(e.run) == 1 && !decoded_any && !has_misc && hi > lo {
		tok := tape.infer_token(raw_data(t.src), lo, u32(hi - lo))
		if tok.kind == .True || tok.kind == .False {
			return give(e, on, tok.kind, .Value, lo, hi - lo, 0) != .Stop
		}
		if tok.kind == .Number {
			sp := u16(0) if .Unspelled in C else tok.spelling
			return give(e, on, .Number, .Value, lo, hi - lo, sp) != .Stop
		}
	}
	spelling := u16(0)
	if len(e.run) > 1 {
		spelling = tape.SPELLING_DECODE | tape.SPELLING_LAX | TEXT_PIECES
		if k := e.keep_state; k != nil && e.mute == 0 {
			_, err := append(&k.texts, Text_Entry{lo = lo, first = u32(len(k.pieces)), count = u32(len(e.run))})
			_, perr := append(&k.pieces, ..e.run[:])
			k.oom ||= err != nil || perr != nil
			if k.oom {
				e.no_memory = true
				e.stopped = true
				return false
			}
		}
	} else if decoded_any {
		spelling = tape.SPELLING_DECODE | tape.SPELLING_LAX
	}
	if spelling != 0 {
		spelling |= u16(e.run[0].mode) << TEXT_MODE_SHIFT
	}
	if frozen {
		spelling |= TEXT_FROZEN
	}
	return give(e, on, .Plain, .Value, lo, hi - lo, spelling) != .Stop
}

@(private)
emit_levels_check :: #force_inline proc(
	e: ^Emitter($H, $LAX),
	lo: u64,
) -> bool {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	when .Levels in C {
		if e.open_depth >= e.held_levels {
			return emit_levels_grow(e, lo)
		}
	}
	return true
}

@(private, cold)
emit_levels_grow :: #force_no_inline proc(
	e: ^Emitter($H, $LAX),
	lo: u64,
) -> bool {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	want := max(e.held_levels * 2, e.open_depth + 1)
	when .Levels in C {
		when .Keeps in C {
			if e.keep != 0 {
				K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
				Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
				IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
				when .Levels in IC {
					inner := (^Inner)(hook.keeps_inner(e.h))
					if !hook.levels_grow(inner, want, &e.regs, lo) {
						return false
					}
					e.held_levels = hook.levels_held(inner)
					when .Rooms in IC {
						e.rooms = hook.rooms_end(inner)
					}
					return true
				}
			}
		}
		if !hook.levels_grow(e.h, want, &e.regs, lo) {
			return false
		}
		e.held_levels = hook.levels_held(e.h)
		when .Rooms in C {
			e.rooms = hook.rooms_end(e.h)
		}
	}
	return true
}

@(private)
give_fact :: #force_inline proc(
	e: ^Emitter($H, $LAX),
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
	kind: tape.Kind,
	role: tape.Role,
	lo, n: u64,
	spelling: u16 = 0,
) -> hook.Action {
	return give(e, on, kind, role, lo, n, spelling, 0)
}

@(private)
give :: proc(
	e: ^Emitter($H, $LAX),
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
	kind: tape.Kind,
	role: tape.Role,
	lo, n: u64,
	spelling: u16 = 0,
	open_tag: u64 = 0,
) -> hook.Action {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	if e.stopped {
		return .Stop
	}
	when LAX {
		if kind == .Object {
			e.steps -= 1
			if e.steps == 0 {
				e.hi = lo
				e.stopped = true
				return .Stop
			}
		}
	}
	when .Skips in C {
		if e.mute != 0 {
			return .Next
		}
		if e.skip_value && role == .Value && kind != .End {
			e.skip_value = false
			if kind == .Object {
				e.mute = open_tag
				e.mute_end = true
			}
			return .Next
		}
	}
	if n > u64(max(u32)) {
		e.fault_at = lo
		e.wide = true
		e.stopped = true
		return .Stop
	}
	tok := tape.Token{lo = lo, n = u32(n), kind = kind, role = role, spelling = spelling}
	when .Keeps in C {
		if e.keep != 0 {
			if kind == .Object {
				if !emit_levels_check(e, lo) {
					e.hi = lo
					e.no_memory = true
					e.stopped = true
					return .Stop
				}
				e.open_depth += 1
			}
			K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
			Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
			IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
			when .Rooms in IC {
				if kind != .End && role <= .Key {
					inner := (^Inner)(hook.keeps_inner(e.h))
					if uintptr(e.regs.a) == hook.rooms_end(inner) && !hook.rooms_grow(inner, &e.regs, lo) {
						e.hi = lo
						e.stopped = true
						return .Stop
					}
				}
			}
			a: hook.Action
			if e.keep_stubs {
				e.regs, a = hook.keeps_give(e.h, e.regs, tok, true)
			} else {
				e.regs, a = hook.keeps_give(e.h, e.regs, tok, false)
			}
			if a == .Stop {
				e.stopped = true
				e.hi = lo + n
				return .Stop
			}
			return a
		}
	}
	if kind == .Object {
		if !emit_levels_check(e, lo) {
			e.hi = lo
			e.no_memory = true
			e.stopped = true
			return .Stop
		}
		e.open_depth += 1
	}
	when .Rooms in C {
		if kind != .End && role <= .Key && uintptr(e.regs.a) == e.rooms {
			if !hook.rooms_grow(e.h, &e.regs, lo) {
				e.hi = lo
				e.stopped = true
				return .Stop
			}
			e.rooms = hook.rooms_end(e.h)
		}
	}
	a: hook.Action
	e.regs, a = on(e.h, e.regs, tok)
	if a == .Next {
		return .Next
	}
	if a == .Stop {
		e.stopped = true
		e.hi = lo + n
		return .Stop
	}
	when .Skips in C {
		if role == .Key && a == .Skip {
			e.skip_value = true
			return .Next
		}
		if open_tag != 0 {
			#partial switch a {
			case .Skip:
				e.mute = open_tag
				return .Next
			case .Rest:
				e.mute = max(u64)
				return .Next
			case .Keep, .Keep_Stubs:
				when .Keeps in C {
					e.keep = open_tag
					e.keep_stubs = a == .Keep_Stubs
					// `open_depth` already accounted for the outer `.Object`; inner hook also receives this `.Object` as its root.
					K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
					Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
					IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
					when .Rooms in IC {
						inner := (^Inner)(hook.keeps_inner(e.h))
						if uintptr(e.regs.a) == hook.rooms_end(inner) && !hook.rooms_grow(inner, &e.regs, lo) {
							e.hi = lo
							e.no_memory = true
							e.stopped = true
							return .Stop
						}
					}
					ia: hook.Action
					if e.keep_stubs {
						e.regs, ia = hook.keeps_give(e.h, e.regs, tok, true)
					} else {
						e.regs, ia = hook.keeps_give(e.h, e.regs, tok, false)
					}
					if ia == .Stop {
						e.stopped = true
						e.hi = lo + n
						return .Stop
					}
					return .Next
				}
			}
		}
	}
	return a
}

@(private)
emit_close :: proc(
	e: ^Emitter($H, $LAX),
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
	open_tag: u64,
	lo: u64,
) -> hook.Action {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	when .Skips in C {
		if e.mute == open_tag {
			e.mute = 0
			if e.mute_end {
				e.mute_end = false
				return .Next
			}
		}
	}
	when .Keeps in C {
		if e.keep == open_tag {
			if give(e, on, .End, .Value, lo, 0, 0, open_tag) == .Stop {
				return .Stop
			}
			e.keep = 0
			e.keep_stubs = false
			// Refresh outer rooms/levels after finishing inner keep.
			when .Rooms in C {
				e.rooms = hook.rooms_end(e.h)
			}
			when .Levels in C {
				e.held_levels = hook.levels_held(e.h)
			}
			// Outer hook closes its container frame too (`e.open_depth` popped once here).
			e.open_depth -= 1
			if e.mute == max(u64) {
				return .Next
			}
			act: hook.Action
			e.regs, act = on(e.h, e.regs, tape.Token{lo = lo, kind = .End, role = .Value})
			return act
		}
	}
	if e.mute == 0 {
		e.open_depth -= 1
	}
	return give(e, on, .End, .Value, lo, 0, 0, open_tag)
}

@(private)
key_of :: proc(t: ^Html_Tree, n: ^Tree_Node) -> tape.Token {
	if n.name.n == 0 {
		imp, _ := implied_of(n.tag)
		return {
			lo       = n.lo,
			n        = 0,
			kind     = .String,
			role     = .Key,
			spelling = tape.SPELLING_DECODE | KEY_TABLE | u16(imp) << KEY_IMPLIED_SHIFT,
		}
	}
	spelling := u16(n.ns) << KEY_NS_SHIFT
	if n.flags & {.Implied, .Cloned, .Moved} != {} {
		spelling |= KEY_FROZEN
	}
	key := tape.Token{lo = n.name.lo, n = n.name.n, kind = .String, role = .Key}
	if n.ns == .Svg {
		i := foreign_of(raw_data(t.src)[n.name.lo:], n.name.n)
		if n.name.flags & {.Nul, .Invalid} == {} && .Svg_Element in FOREIGN_NAMES[i].kinds {
			key.spelling = spelling | tape.SPELLING_DECODE | KEY_TABLE
			return key
		}
	}
	if n.tag != .Other && int(n.name.n) != len(TAG_NAMES[n.tag]) {
		key.spelling = spelling | tape.SPELLING_DECODE | KEY_TABLE
		return key
	}
	key.spelling = spelling | name_spelling(n.name.flags)
	return key
}

@(private)
attribute_fact :: proc "contextless" (src: []u8, a: Attribute) -> (lo, hi: u64, spelling: u16) {
	lo = a.name.lo
	if a.value.lo == 0 {
		hi = lo + u64(a.name.n)
		return lo, hi, markup.attribute_spelling(int(hi - lo), false)
	}
	quoted := src[a.value.lo - 1] == '"' || src[a.value.lo - 1] == '\''
	hi = a.value.lo + u64(a.value.n) + (1 if quoted else 0)
	return lo, hi, markup.attribute_spelling(int(a.value.lo - lo), quoted)
}

@(private)
markers :: proc "contextless" (lo, hi, body_lo, body_hi: u64) -> u16 {
	if body_lo < lo || body_hi > hi || body_lo > body_hi {
		return 0
	}
	return tape.fact_spelling(u8(min(body_lo - lo, 255)), u8(min(hi - body_hi, 255)))
}

@(private)
has_char :: proc(t: ^Html_Tree, n: u32) -> bool {
	node := tree_node(t, n)
	for p := node.a;; p = t.pieces[p].next {
		s := t.pieces[p].span
		text := t.src[s.lo:s.lo + u64(s.n)] if s.flags & DECODED == {} else transmute([]u8)decoded(t, s, 0)
		for c in text {
			if !is_space(c) {
				return true
			}
		}
		if p == node.b {
			break
		}
	}
	return false
}

@(private)
newline_before :: proc "contextless" (src: []u8, at: u64) -> bool {
	lo := at
	for lo > 0 && is_space(src[lo - 1]) {
		lo -= 1
		if src[lo] == '\n' {
			return true
		}
	}
	return false
}

@(private)
has_newline :: proc "contextless" (b: []u8) -> bool {
	for c in b {
		if c == '\n' {
			return true
		}
	}
	return false
}
