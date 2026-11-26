package yaml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Streaming YAML 1.2 walk driving v2 `hook.Protocol` hooks (`Rooms`, `Levels`, `Skips`, `Keeps`, `Budget.{depth, steps,
// expansion, memory}`) cleanly in a single pass with explicit heap parser stacks.

@(private)
Walk :: struct($H: typeid, $LAX: bool, $C: hook.Capabilities) {
	p:          Parser,
	hooks:      ^H,
	regs:       hook.Regs,
	rooms:      uintptr,
	open_depth: u64,
	mute:       u64,
	keep_depth: u64,
	steps:      [int(LAX)]u64,
	skip_value: bool,
	mute_end:   bool,
	keep_stubs: bool,
	failed_mem: bool,
	bad_hook:   bool,
	stopped:    bool,
}

@(private)
reset_document :: proc(p: ^Parser) {
	clear(&p.handles)
	clear(&p.anchors)
	clear(&p.names)
	p.indexed = 0
	clear(&p.log)
	clear(&p.open)
	keys_reset(&p.keys)
	clear(&p.stage)
	clear(&p.blocks)
	clear(&p.flows)
	clear(&p.merge_runs)
	clear(&p.merges)
	p.holding = false
	p.hold_open_n = 0
	p.hold_anch_lo = 0
	p.hold_log_lo = 0
	p.next = .After
	p.staging = false
	p.pend_anch = -1
	p.expanded = 0
	p.depth = 0
	p.tdepth = 0
	p.open_roots = 0
	p.root_close = 0
	p.saw_node = false
	p.has_yaml = false
	p.directives = false
	p.tag.n = 0
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
			if p.nl.tab {
				return false, fault(p, p.pos, .Bad_Char, .Tab_Indent)
			}
			read_directive(p) or_return
			peek_next(p) or_return
		}
		l := p.nl
		switch {
		case l.kind == .Eof:
			if p.directives {
				return false, fault(p, p.pos, .Truncated, .Expected_Document_Start)
			}
			clear(&p.pending)
			return false, true
		case l.kind == .Marker && at(p, p.pos) == '.':
			if p.directives {
				return false, fault(p, p.pos, .Bad_Char, .Expected_Document_Start)
			}
			p.pos += 3
			finish_line(p, false) or_return
			clear(&p.pending)
			if !at_eof(p) {
				consume_break(p)
			}
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
	if l.kind == .Content {
		return fault(p, p.pos, .Bad_Char, .Unexpected_Content)
	}
	flush_foot(p, 0) or_return
	if l.kind == .Marker && at(p, p.pos) == '.' {
		emit_raw(p, tape.Token{p.pos, 3, .Plain, .Directive, 0}) or_return
		p.pos += 3
		finish_line(p, false) or_return
		clear(&p.pending)
		if !at_eof(p) {
			consume_break(p)
		}
	}
	return true
}

// Validates the entire YAML stream (`0` or more documents).
@(private)
validate_stream :: proc "contextless" (src: []u8, $S: Spec, $LAX: bool, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	context = ctx^ if ctx != nil else runtime.default_context()
	local: hook.Memory_Budget
	scratch := hook.scratch(opts, allocator, &local)
	w := Walk(hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS) {
		hooks = h,
		regs  = regs^ if regs != nil else {},
	}
	when LAX {
		w.steps[0] = build.read_steps(opts)
	}
	sink: Token_Sink = walk_sink(hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS, hook.no_hook) when LAX else nil
	sink_data: rawptr = &w when LAX else nil
	parser_init(&w.p, src, opts.budget.depth, opts.budget.expansion, S == .Yaml_Merge && sink != nil, true, LAX, false, scratch, sink, sink_data)
	defer parser_destroy(&w.p)
	w.p.pos = u64(spell_bom(src))
	w.p.ls = w.p.pos
	w.p.start = w.p.pos
	for w.p.pos < u64(len(src)) {
		found, ok := read_document(&w.p)
		if !ok {
			r := w.p.fail
			when LAX {
				r = hook.steps_result(r, w.steps[0])
			}
			_, err, _ = hook.walk_error(r, &RULES)
			return w.p.pos, hook.memory_budget_error(&local, err), false
		}
		if !found {
			break
		}
	}
	if regs != nil {
		regs^ = w.regs
	}
	return u64(len(src)), nil, false
}

// Walks a single YAML document starting at `lo` (with `tail_fault` check for trailing documents unless `single_doc == false`
// or the hook stopped). Used by `build`, `find`, `scan`, `check`, `unmarshal`, and `yaml.walk`.
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
) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	context = ctx^ if ctx != nil else runtime.default_context()
	local: hook.Memory_Budget
	scratch := hook.scratch(opts, allocator, &local)
	w := Walk(H, LAX, C) {
		hooks = h,
		regs  = regs^ if regs != nil else {},
	}
	when .Rooms in C {
		if h != nil {
			w.rooms = hook.rooms_end(h)
		}
	}
	when LAX {
		w.steps[0] = build.read_steps(opts)
	}
	sink: Token_Sink = walk_sink(H, LAX, C, on) if H != hook.No_Hooks else (walk_sink(H, LAX, C, on) when LAX else nil)
	sink_data: rawptr = &w if sink != nil else nil
	parser_init(&w.p, src, opts.budget.depth, opts.budget.expansion, S == .Yaml_Merge && sink != nil, allow_complex, H != hook.No_Hooks || LAX, H != hook.No_Hooks, scratch, sink, sink_data)
	defer parser_destroy(&w.p)
	w.p.pos = lo
	if lo == 0 {
		w.p.pos = u64(spell_bom(src))
	}
	w.p.ls = w.p.pos
	w.p.start = w.p.pos
	found, ok := read_document(&w.p)
	if end_pos != nil {
		end_pos^ = w.p.pos
	}
	if found_out != nil {
		found_out^ = found
	}
	if regs != nil {
		regs^ = w.regs
	}
	if !ok {
		r := w.p.fail
		when LAX {
			r = hook.steps_result(r, w.steps[0])
		}
		if u8(r) == hook.WALK_STOPPED {
			if w.failed_mem {
				return w.p.pos, hook.memory_budget_error(&local, runtime.Allocator_Error.Out_Of_Memory), false
			}
			if w.bad_hook {
				return w.p.pos, tape.Bad_Option{"action"}, false
			}
			return w.p.root_close, nil, false
		}
		at, werr, _ := hook.walk_error(r, &RULES)
		return at, hook.memory_budget_error(&local, werr), false
	}
	if !found {
		if allow_empty {
			return u64(len(src)), nil, false
		}
		return u64(len(src)), tape.Fault{at = u64(len(src)), rules = &RULES, kind = .Truncated, detail = u8(Detail.No_Document)}, false
	}
	if !w.p.saw_node && !allow_empty {
		return u64(len(src)), tape.Fault{at = u64(len(src)), rules = &RULES, kind = .Truncated, detail = u8(Detail.No_Document)}, false
	}
	if check_tail && w.p.pos < u64(len(src)) {
		if tf := tail_fault(&w.p, src, w.p.pos, opts, S); tf != 0 {
			at, werr, _ := hook.walk_error(tf, &RULES)
			return at, hook.memory_budget_error(&local, werr), false
		}
	}
	return w.p.root_close, nil, false
}

@(private)
tail_fault :: proc(p: ^Parser, src: []u8, lo: u64, opts: Options, $S: Spec) -> hook.Walk_Result {
	reset_document(p)
	clear(&p.pending)
	p.sink, p.sink_data, p.needs_log = nil, nil, false
	p.pos, p.ls = lo, lo
	p.nl_valid = false
	if !peek_next(p) {
		return p.fail
	}
	start := p.nl.pos
	found, ok := read_document(p)
	if !ok {
		return p.fail
	}
	if found {
		return hook.walk_result(start, u8(tape.Fault_Kind.Bad_Char), u8(Detail.Extra_Document))
	}
	return 0
}

@(private = "file")
spell_bom :: #force_inline proc "contextless" (src: []u8) -> int #no_bounds_check {
	return 3 if len(src) >= 3 && src[0] == 0xef && src[1] == 0xbb && src[2] == 0xbf else 0
}

@(private)
walk_sink :: proc "contextless" ($H: typeid, $LAX: bool, $C: hook.Capabilities, $ON: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> Token_Sink {
	return proc "contextless" (data: rawptr, t: tape.Token) -> bool {
		return walk_deliver((^Walk(H, LAX, C))(data), t, ON)
	}
}

@(private)
walk_deliver :: proc "contextless" (w: ^Walk($H, $LAX, $C), t: tape.Token, $ON: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> bool {
	container := t.kind > .Plain && t.kind != .End
	if container {
		w.open_depth += 1
	}
	when .Skips in C {
		if w.mute != 0 {
			when LAX {
				if container {
					w.steps[0] -= 1
					if w.steps[0] == 0 {
						w.p.fail = hook.walk_result(t.lo, hook.WALK_STEPS)
						return false
					}
				}
			}
			if t.kind == .End {
				w.open_depth -= 1
				if w.mute != max(u64) && w.open_depth + 1 == w.mute {
					send_end := !w.mute_end
					w.mute, w.mute_end = 0, false
					if send_end {
						return deliver_outer(w, t, false, ON)
					}
				}
			}
			return true
		} else if w.skip_value {
			if t.role > .Key {
				// Facts between the skipped key and its value are still delivered to the hook.
			} else {
				w.skip_value = false
				if container {
					when LAX {
						w.steps[0] -= 1
						if w.steps[0] == 0 {
							w.p.fail = hook.walk_result(t.lo, hook.WALK_STEPS)
							return false
						}
					}
					w.mute = w.open_depth
					w.mute_end = true
				}
				return true
			}
		}
	}

	if t.kind == .End {
		w.open_depth -= 1
		when .Keeps in C {
			if w.keep_depth != 0 && w.open_depth + 1 == w.keep_depth {
				// Close inner kept container first, then restore outer hook and also deliver `.End` to it.
				if !deliver_inner(w, t) {
					return false
				}
				w.keep_depth = 0
				when .Rooms in C {
					w.rooms = hook.rooms_end(w.hooks)
				}
			}
		}
	}

	when .Keeps in C {
		if w.keep_depth != 0 {
			when LAX {
				if container {
					w.steps[0] -= 1
					if w.steps[0] == 0 {
						w.p.fail = hook.walk_result(t.lo, hook.WALK_STEPS)
						return false
					}
				}
			}
			return deliver_inner(w, t)
		}
	}

	return deliver_outer(w, t, container, ON)
}

@(private = "file")
deliver_outer :: #force_inline proc "contextless" (w: ^Walk($H, $LAX, $C), t: tape.Token, container: bool, $ON: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> bool {
	when .Rooms in C {
		if t.kind != .End && t.role <= .Key && uintptr(w.regs.a) >= w.rooms {
			if !hook.rooms_grow(w.hooks, &w.regs, t.lo) {
				w.failed_mem = true
				return false
			}
			w.rooms = hook.rooms_end(w.hooks)
		}
	}
	if container {
		when .Levels in C {
			held := hook.levels_held(w.hooks)
			if held <= int(w.regs.c) {
				want := max(2 * held, int(w.regs.c) + 1)
				if !hook.levels_grow(w.hooks, want, &w.regs, t.lo) {
					w.failed_mem = true
					return false
				}
				when .Rooms in C {
					w.rooms = hook.rooms_end(w.hooks)
				}
			}
		}
		when LAX {
			w.steps[0] -= 1
			if w.steps[0] == 0 {
				w.p.fail = hook.walk_result(t.lo, hook.WALK_STEPS)
				return false
			}
		}
	}
	when H == hook.No_Hooks {
		return true
	} else {
		act: hook.Action
		w.regs, act = ON(w.hooks, w.regs, t)
		when .Skips not_in C && .Keeps not_in C {
			if act == .Next {
				return true
			}
			if act == .Stop {
				w.stopped = true
				return false
			}
			w.bad_hook = true
			return false
		} else {
			#partial switch act {
			case .Next:
				return true
			case .Stop:
				w.stopped = true
				return false
			case .Skip:
				when .Skips in C {
					if t.role == .Key {
						w.skip_value = true
					} else if container {
						w.mute = w.open_depth
						w.mute_end = false
					}
					return true
				}
				w.bad_hook = true
				return false
			case .Rest:
				when .Skips in C {
					w.mute = max(u64)
					return true
				}
				w.bad_hook = true
				return false
			case .Keep, .Keep_Stubs:
				when .Keeps in C {
					if !container {
						w.bad_hook = true
						return false
					}
					w.keep_depth = w.open_depth
					w.keep_stubs = (act == .Keep_Stubs)
					return deliver_inner(w, t)
				}
				w.bad_hook = true
				return false
			}
			w.bad_hook = true
			return false
		}
	}
}

@(private = "file")
deliver_inner :: proc "contextless" (w: ^Walk($H, $LAX, $C), t: tape.Token) -> bool {
	when .Keeps in C {
		K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
		Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
		IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
		inner := (^Inner)(hook.keeps_inner(w.hooks))
		container := t.kind > .Plain && t.kind != .End
		when .Rooms in IC {
			if t.kind != .End && t.role <= .Key && uintptr(w.regs.a) >= hook.rooms_end(inner) {
				if !hook.rooms_grow(inner, &w.regs, t.lo) {
					w.failed_mem = true
					return false
				}
			}
		}
		if container {
			when .Levels in IC {
				held := hook.levels_held(inner)
				if held <= int(w.regs.c) {
					want := max(2 * held, int(w.regs.c) + 1)
					if !hook.levels_grow(inner, want, &w.regs, t.lo) {
						w.failed_mem = true
						return false
					}
				}
			}
		}
		act: hook.Action
		if w.keep_stubs {
			w.regs, act = hook.keeps_give(w.hooks, w.regs, t, true)
		} else {
			w.regs, act = hook.keeps_give(w.hooks, w.regs, t, false)
		}
		if act == .Stop {
			w.stopped = true
			return false
		}
		return true
	} else {
		return false
	}
}
