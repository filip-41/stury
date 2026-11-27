package yaml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Streaming YAML 1.2 walk driving v2 `hook.Protocol` hooks (`Rooms`, `Levels`, `Skips`, `Keeps`, `Budget.{depth, steps,
// expansion, memory}`) cleanly in a single pass with explicit heap parser stacks.

@(private)
Walk_Hook :: struct($H: typeid, $LAX: bool, $C: hook.Capabilities) {
	hooks:      ^H,
	regs:       hook.Regs,
	rooms:      uintptr,
	open_depth: u64,
	mute:       u64,
	keep_depth: u64,
	steps:      [int(LAX)]u64,
	last_at:    u64,
	skip_value: bool,
	mute_end:   bool,
	keep_stubs: bool,
	failed_mem: bool,
	bad_hook:   bool,
	stopped:    bool,
	out_steps:  bool,
}

@(private)
Walk :: struct($H: typeid, $LAX: bool, $C: hook.Capabilities) {
	p:  Parser,
	wh: Walk_Hook(H, LAX, C),
}

@(private)
walk_hook_init :: #force_inline proc "contextless" (wh: ^Walk_Hook($H, $LAX, $C), h: ^H, regs: ^hook.Regs, steps: u64, at := u64(0)) {
	wh.hooks = h
	wh.regs = regs^ if regs != nil else {}
	wh.last_at = at
	when .Rooms in C { if h != nil { wh.rooms = hook.rooms_end(h) } }
	when LAX { wh.steps[0] = steps }
}

@(private)
reset_document :: proc(p: ^Parser) {
	clear(&p.handles); clear(&p.anchors); clear(&p.names); clear(&p.log); clear(&p.open)
	keys_reset(&p.keys)
	clear(&p.stage); clear(&p.blocks); clear(&p.flows); clear(&p.merge_runs); clear(&p.merges)
	p.indexed, p.holding, p.hold_open_n, p.hold_anch_lo, p.hold_log_lo = 0, false, 0, 0, 0
	p.next, p.staging, p.pend_anch, p.expanded = .After, false, -1, 0
	p.depth, p.tdepth, p.open_roots, p.root_close = 0, 0, 0, 0
	p.saw_node, p.has_yaml, p.directives, p.tag.n = false, false, false, 0
}

// Reads the next YAML document from `p.pos`, returning `found = false` when only comments/blanks/`...` remain.
@(private)
read_document :: proc(p: ^Parser) -> (found: bool, ok: bool) #no_bounds_check {
	for {
		reset_document(p)
		if p.pos + 3 <= u64(len(p.src)) && p.src[p.pos] == 0xef && p.src[p.pos + 1] == 0xbb && p.src[p.pos + 2] == 0xbf {
			p.pos += 3
			p.ls = p.pos
		}
		peek_next(p) or_return
		for p.nl.kind == .Content && p.nl.ind == 0 && at(p, p.pos) == '%' {
			if p.nl.tab { return false, fault(p, p.pos, .Bad_Char, .Tab_Indent) }
			read_directive(p) or_return
			peek_next(p) or_return
		}
		l := p.nl
		switch {
		case l.kind == .Eof:
			if p.directives { return false, fault(p, p.pos, .Truncated, .Expected_Document_Start) }
			clear(&p.pending)
			return false, true
		case l.kind == .Marker && at(p, p.pos) == '.':
			if p.directives { return false, fault(p, p.pos, .Bad_Char, .Expected_Document_Start) }
			p.pos += 3
			finish_line(p, false) or_return
			clear(&p.pending)
			if !at_eof(p) { consume_break(p) }
			continue
		case l.kind == .Marker:
			emit_now(p, tape.Token{p.pos, 3, .Plain, .Directive, 0}) or_return
			p.pos += 3
			parse_node(p, -1, false, false, .Value) or_return
		case p.directives:
			return false, fault(p, p.pos, .Bad_Char, .Expected_Document_Start)
		case:
			parse_block_at(p, l.ind, -1, .Value, &Props{}, false) or_return
		}
		read_blocks(p) or_return
		break
	}
	return true, end_document(p)
}

@(private)
end_document :: proc(p: ^Parser) -> bool {
	peek_next(p) or_return
	l := p.nl
	if l.kind == .Content { return fault(p, p.pos, .Bad_Char, .Unexpected_Content) }
	flush_foot(p, 0) or_return
	if l.kind == .Marker && at(p, p.pos) == '.' {
		emit_raw(p, tape.Token{p.pos, 3, .Plain, .Directive, 0}) or_return
		p.pos += 3
		finish_line(p, false) or_return
		clear(&p.pending)
		if !at_eof(p) { consume_break(p) }
	}
	return true
}

// Validates the entire YAML stream (`0` or more documents).
@(private)
validate_stream :: proc "contextless" (src: []u8, $S: Spec, $LAX: bool, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	return validate_stream_from(src, u64(spell_bom(src)), build.read_steps(opts), S, LAX, opts, h, regs, allocator, ctx)
}

// Validates all remaining YAML documents starting at byte offset `lo` with carried step budget `steps`.
@(private)
validate_stream_from :: proc "contextless" (src: []u8, lo, steps: u64, $S: Spec, $LAX: bool, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	context = ctx^ if ctx != nil else runtime.default_context()
	local: hook.Memory_Budget
	scratch := hook.scratch(opts, allocator, &local)
	w: Walk(hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS)
	walk_hook_init(&w.wh, h, regs, steps)
	sink: Token_Sink = walk_sink(hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS, hook.no_hook) when LAX else nil
	sink_data: rawptr = &w when LAX else nil
	parser_init(&w.p, src, opts.budget.depth, opts.budget.expansion, S == .Yaml_Merge && sink != nil, true, LAX, false, dialect_of(opts), scratch, sink, sink_data)
	defer parser_destroy(&w.p)
	w.p.pos = lo
	w.p.ls, w.p.start = lo, lo
	for w.p.pos < u64(len(src)) {
		found, ok := read_document(&w.p)
		if !ok {
			r := w.p.fail
			when LAX { r = hook.steps_result(r, w.wh.steps[0]) }
			_, err, _ = hook.walk_error(r, &RULES)
			return w.p.pos, hook.memory_budget_error(&local, err), false
		}
		if !found { break }
	}
	if regs != nil { regs^ = w.wh.regs }
	return u64(len(src)), nil, false
}

// Checks whether one YAML document starting at `lo` in `src[:to]` is completely sealed before `to` (ended by an
// explicit `...\n` line or a following `---` + whitespace/break marker strictly inside `< to`).
@(private)
probe_sealed_doc :: proc(
	src: []u8,
	lo: u64,
	$S: Spec,
	$LAX: bool,
	opts: Options,
	steps_in: u64,
	allow_complex: bool,
	allocator: runtime.Allocator,
	ctx: ^runtime.Context,
) -> (sealed, found: bool, end_pos, steps_out: u64) #no_bounds_check {
	context = ctx^ if ctx != nil else runtime.default_context()
	local: hook.Memory_Budget
	scratch := hook.scratch(opts, allocator, &local)
	w: Walk(hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS)
	walk_hook_init(&w.wh, nil, nil, steps_in)
	sink: Token_Sink = walk_sink(hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS, hook.no_hook) when LAX else nil
	sink_data: rawptr = &w when LAX else nil
	parser_init(&w.p, src, opts.budget.depth, opts.budget.expansion, S == .Yaml_Merge && sink != nil, allow_complex, LAX, false, dialect_of(opts), scratch, sink, sink_data)
	defer parser_destroy(&w.p)
	w.p.pos, w.p.ls, w.p.start = lo, lo, lo
	ok: bool
	found, ok = read_document(&w.p)
	if !ok { return false, false, lo, steps_in }
	to := u64(len(src))
	when LAX { steps_out = w.wh.steps[0] } else { steps_out = steps_in }
	if !found {
		// Bare `...` / comments only: sealed if terminated by `\n` (and no pending directives).
		if !w.p.directives && w.p.pos > lo && w.p.pos <= to && src[w.p.pos - 1] == '\n' {
			return true, false, w.p.pos, steps_out
		}
		return false, false, lo, steps_in
	}
	l := w.p.nl
	if l.kind == .Marker {
		b := src[l.pos]
		if b == '.' && w.p.pos > lo && w.p.pos <= to && src[w.p.pos - 1] == '\n' {
			return true, true, w.p.pos, steps_out
		}
		if b == '-' && l.pos + 3 < to {
			return true, true, w.p.pos, steps_out
		}
	}
	return false, true, lo, steps_in
}

// Runs `tail_fault` starting at `lo` on `src` (for single-document piece readers after document 1 has finished).
@(private)
check_tail_from :: proc(src: []u8, lo: u64, $S: Spec, opts: Options, allow_complex: bool, allocator: runtime.Allocator, ctx: ^runtime.Context) -> tape.Error {
	if lo >= u64(len(src)) { return nil }
	context = ctx^ if ctx != nil else runtime.default_context()
	local: hook.Memory_Budget
	scratch := hook.scratch(opts, allocator, &local)
	p: Parser
	parser_init(&p, src, opts.budget.depth, opts.budget.expansion, false, allow_complex, false, false, dialect_of(opts), scratch, nil, nil)
	defer parser_destroy(&p)
	if tf := tail_fault(&p, lo); tf != 0 {
		_, werr, _ := hook.walk_error(tf, &RULES)
		return hook.memory_budget_error(&local, werr)
	}
	return nil
}

// Walks a single YAML document starting at `lo`. Used by `build`, `find`, `scan`, `check`, `unmarshal`, and `yaml.walk`.
@(private)
walk_text :: proc "contextless" (
	src: []u8,
	$S: Spec,
	$LAX: bool,
	opts: Options,
	h: ^$H,
	regs: ^hook.Regs,
	allocator: runtime.Allocator,
	ctx: ^runtime.Context,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
	lo := u64(0),
	allow_empty := false,
	check_tail := true,
	allow_complex := false,
	end_pos: ^u64 = nil,
	found_out: ^bool = nil,
	stopped_out: ^bool = nil,
) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	context = ctx^ if ctx != nil else runtime.default_context()
	local: hook.Memory_Budget
	scratch := hook.scratch(opts, allocator, &local)
	w: Walk(H, LAX, C)
	walk_hook_init(&w.wh, h, regs, build.read_steps(opts))
	sink: Token_Sink = walk_sink(H, LAX, C, on) if H != hook.No_Hooks else (walk_sink(H, LAX, C, on) when LAX else nil)
	sink_data: rawptr = &w if sink != nil else nil
	parser_init(&w.p, src, opts.budget.depth, opts.budget.expansion, S == .Yaml_Merge && sink != nil, allow_complex, H != hook.No_Hooks || LAX, H != hook.No_Hooks, dialect_of(opts), scratch, sink, sink_data)
	defer parser_destroy(&w.p)
	w.p.pos = u64(spell_bom(src)) if lo == 0 else lo
	w.p.ls, w.p.start = w.p.pos, w.p.pos
	found, ok := read_document(&w.p)
	if end_pos != nil { end_pos^ = w.p.pos }
	if found_out != nil { found_out^ = found }
	if stopped_out != nil { stopped_out^ = w.wh.stopped }
	if regs != nil { regs^ = w.wh.regs }
	if !ok {
		r := w.p.fail
		when LAX { r = hook.steps_result(r, w.wh.steps[0]) }
		if u8(r) == hook.WALK_STOPPED {
			if w.wh.failed_mem { return w.p.pos, hook.memory_budget_error(&local, runtime.Allocator_Error.Out_Of_Memory), false }
			if w.wh.bad_hook { return w.p.pos, tape.Bad_Option{"action"}, false }
			return w.p.root_close, nil, false
		}
		at, werr, _ := hook.walk_error(r, &RULES)
		return at, hook.memory_budget_error(&local, werr), false
	}
	if !found || !w.p.saw_node {
		if allow_empty && !found { return u64(len(src)), nil, false }
		if !allow_empty { return u64(len(src)), tape.Fault{at = u64(len(src)), rules = &RULES, kind = .Truncated, detail = u8(Detail.No_Document)}, false }
	}
	rc := w.p.root_close
	if check_tail && w.p.pos < u64(len(src)) {
		if tf := tail_fault(&w.p, w.p.pos); tf != 0 {
			at, werr, _ := hook.walk_error(tf, &RULES)
			return at, hook.memory_budget_error(&local, werr), false
		}
	}
	return rc, nil, false
}

@(private)
tail_fault :: proc(p: ^Parser, lo: u64) -> hook.Walk_Result {
	reset_document(p)
	clear(&p.pending)
	p.sink, p.sink_data, p.needs_log = nil, nil, false
	p.pos, p.ls, p.nl_valid = lo, lo, false
	if !peek_next(p) { return p.fail }
	start := p.nl.pos
	found, ok := read_document(p)
	if !ok { return p.fail }
	return hook.walk_result(start, u8(tape.Fault_Kind.Bad_Char), u8(Detail.Extra_Document)) if found else 0
}

@(private = "file")
spell_bom :: #force_inline proc "contextless" (src: []u8) -> int #no_bounds_check {
	return 3 if len(src) >= 3 && src[0] == 0xef && src[1] == 0xbb && src[2] == 0xbf else 0
}

@(private)
walk_sink :: proc "contextless" ($H: typeid, $LAX: bool, $C: hook.Capabilities, $ON: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> Token_Sink {
	return proc "contextless" (data: rawptr, t: tape.Token) -> bool {
		w := (^Walk(H, LAX, C))(data)
		if walk_hook_deliver(&w.wh, t, ON) { return true }
		when LAX {
			if w.wh.out_steps { w.p.fail = hook.walk_result(t.lo, hook.WALK_STEPS) }
		}
		return false
	}
}

@(private = "file")
step_budget :: #force_inline proc "contextless" (wh: ^Walk_Hook($H, $LAX, $C), container: bool) -> bool {
	when LAX {
		if container {
			wh.steps[0] -= 1
			if wh.steps[0] == 0 { wh.out_steps = true; return false }
		}
	}
	return true
}

@(private)
walk_hook_deliver :: proc "contextless" (wh: ^Walk_Hook($H, $LAX, $C), t: tape.Token, $ON: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> bool {
	wh.last_at = t.lo
	container := t.kind > .Plain && t.kind != .End
	if container { wh.open_depth += 1 }
	when .Skips in C {
		if wh.mute != 0 {
			step_budget(wh, container) or_return
			if t.kind == .End {
				wh.open_depth -= 1
				if wh.mute != max(u64) && wh.open_depth + 1 == wh.mute {
					send_end := !wh.mute_end
					wh.mute, wh.mute_end = 0, false
					if send_end { return walk_hook_outer(wh, t, false, ON) }
				}
			}
			return true
		} else if wh.skip_value && t.role <= .Key {
			wh.skip_value = false
			if container {
				step_budget(wh, true) or_return
				wh.mute, wh.mute_end = wh.open_depth, true
			}
			return true
		}
	}
	if t.kind == .End {
		wh.open_depth -= 1
		when .Keeps in C {
			if wh.keep_depth != 0 && wh.open_depth + 1 == wh.keep_depth {
				walk_hook_inner(wh, t) or_return
				wh.keep_depth = 0
				when .Rooms in C { wh.rooms = hook.rooms_end(wh.hooks) }
			}
		}
	}
	when .Keeps in C {
		if wh.keep_depth != 0 {
			step_budget(wh, container) or_return
			return walk_hook_inner(wh, t)
		}
	}
	return walk_hook_outer(wh, t, container, ON)
}

@(private = "file")
walk_hook_outer :: #force_inline proc "contextless" (wh: ^Walk_Hook($H, $LAX, $C), t: tape.Token, container: bool, $ON: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> bool {
	when .Rooms in C {
		if t.kind != .End && t.role <= .Key && uintptr(wh.regs.a) >= wh.rooms {
			if !hook.rooms_grow(wh.hooks, &wh.regs, t.lo) { wh.failed_mem = true; return false }
			wh.rooms = hook.rooms_end(wh.hooks)
		}
	}
	if container {
		when .Levels in C {
			held := hook.levels_held(wh.hooks)
			if held <= int(wh.regs.c) {
				if !hook.levels_grow(wh.hooks, max(2 * held, int(wh.regs.c) + 1), &wh.regs, t.lo) { wh.failed_mem = true; return false }
				when .Rooms in C { wh.rooms = hook.rooms_end(wh.hooks) }
			}
		}
		step_budget(wh, true) or_return
	}
	when H == hook.No_Hooks {
		return true
	} else {
		act: hook.Action
		wh.regs, act = ON(wh.hooks, wh.regs, t)
		when .Skips not_in C && .Keeps not_in C {
			if act == .Next { return true }
			if act == .Stop { wh.stopped = true; return false }
			wh.bad_hook = true
			return false
		} else {
			#partial switch act {
			case .Next: return true
			case .Stop: wh.stopped = true; return false
			case .Skip:
				when .Skips in C {
					if t.role == .Key { wh.skip_value = true } else if container { wh.mute, wh.mute_end = wh.open_depth, false }
					return true
				}
			case .Rest:
				when .Skips in C { wh.mute = max(u64); return true }
			case .Keep, .Keep_Stubs:
				when .Keeps in C {
					if !container { wh.bad_hook = true; return false }
					wh.keep_depth, wh.keep_stubs = wh.open_depth, act == .Keep_Stubs
					return walk_hook_inner(wh, t)
				}
			}
			wh.bad_hook = true
			return false
		}
	}
}

@(private = "file")
walk_hook_inner :: proc "contextless" (wh: ^Walk_Hook($H, $LAX, $C), t: tape.Token) -> bool {
	when .Keeps in C {
		K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
		Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
		IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
		inner := (^Inner)(hook.keeps_inner(wh.hooks))
		container := t.kind > .Plain && t.kind != .End
		when .Rooms in IC {
			if t.kind != .End && t.role <= .Key && uintptr(wh.regs.a) >= hook.rooms_end(inner) {
				if !hook.rooms_grow(inner, &wh.regs, t.lo) { wh.failed_mem = true; return false }
			}
		}
		if container {
			when .Levels in IC {
				held := hook.levels_held(inner)
				if held <= int(wh.regs.c) {
					if !hook.levels_grow(inner, max(2 * held, int(wh.regs.c) + 1), &wh.regs, t.lo) { wh.failed_mem = true; return false }
				}
			}
		}
		act: hook.Action
		if wh.keep_stubs {
			wh.regs, act = hook.keeps_give(wh.hooks, wh.regs, t, true)
		} else {
			wh.regs, act = hook.keeps_give(wh.hooks, wh.regs, t, false)
		}
		if act == .Stop { wh.stopped = true; return false }
		return true
	} else {
		return false
	}
}
