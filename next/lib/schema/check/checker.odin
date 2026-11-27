// Streaming schema `Checker` hook (`hook.Protocol({.Skips, .Expects}, ...)`),
// `Refusing_Checker` (`.Refuse` duplicate-key detector), `check_stream`, and explicit-stack `check_document`.
package check

import "base:runtime"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/base/regex"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

@(private)
CHECKER_CAPS :: hook.Capabilities{.Skips, .Expects}

@(private)
MAX_HELD_CAPTURES :: 16

@(private)
Frame :: struct {
	owner:          ^Record,
	parent_b:       u64,
	block_start:    ^Record,
	seen_mask:      u64,
	seen_wide:      []u64,
	count:          u64,
	open_at:        u64,
	key_name:       string,
	run_start:      i32,
	tracker_idx:    i16,
	is_object:      bool,
	is_factored:    bool,
	is_choice:      bool,
	is_group_array: bool,
	in_seq:         bool,
	has_key:        bool,
	key_owned:      bool,
	has_tracker:    bool,
	count_keys:     bool,
	saved_failed:   bool,
}

@(private)
Key_Tracker :: struct {
	small_n: int,
	small:   [16]string,
	names:   [dynamic]string,
	owned:   [dynamic]string,
	table:   map[string]int,
}

Checker :: struct {
	expected:          ^hook.Expected_Memo,
	plan:              ^Plan,
	src:               []u8,
	format:            ^tape.Format,
	xml_ext:           ^tape.Doc_Ext,
	xml_ext_owned:     bool,
	is_binary:         bool,
	has_budget:        bool,
	sink:              ^Sink,
	sink_from:         int,
	allocator:         runtime.Allocator,
	scratch:           runtime.Allocator,
	mem_budget:        ^hook.Memory_Budget,
	budget:            tape.Budget,
	steps_used:        u64,
	nodes_seen:        u64,
	dups:              tape.Duplicates,
	judge_dups:        bool,
	in_doc_group:      bool,
	no_factor:         bool,
	quiet:             bool,
	failed:            bool,
	fatal:             Error_Kind,
	need_reread:       bool,
	reread_runs:       bool,
	buffering_choice:  bool,
	choice_sink_fo:    i16,
	dup_hit:           bool,
	dup_at:            u64,
	first_err:         Check_Error,
	first_arena:       ^mem.Dynamic_Arena,
	first_recorded:    bool,
	frames:            []Frame,
	frames_heap:       bool,
	sp:                int,
	pool:              ^Pool,
	owns_pool:         bool,
	nf:                int,
	choice_depth:      int,
	skip_end:          bool,
	capture_depth:     int,
	trackers:          [dynamic]Key_Tracker,
	tracked:           int,
	tracker0_used:     bool,
	arr_uniq_in_use:   bool,
	arr_uniq_n:        u8,
	arr_uniq_slots:    [64]u8,
	arr_uniq_spells:   [32]u16,
	arr_uniq_strs:     [32]string,
	parent:            ^Checker,
	parent_owner:      ^Record,
	parent_inst_owner: ^Record,
	parent_extra:      []tape.Step,
	nest_depth:        int,
	at_bias:           u64,
	subwalk_fn:        proc(src: []u8, opts: tape.Options, sub: ^Checker, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool),
	ctx:               ^runtime.Context,
	frames_buf:        [16]Frame,
	factored_buf:      [INLINE_FACTORED]Factored_Open,
	tracker0:          Key_Tracker,
	protocol:          hook.Protocol(CHECKER_CAPS, hook.Unused, hook.Unused, hook.Unused),
}

Refusing_Checker :: struct {
	checker:   Checker,
	open_keys: Open_Keys,
	protocol:  hook.Protocol({}, hook.Unused, hook.Unused, hook.Unused),
}

@(private)
Open_Key :: struct {
	key:   tape.Token,
	depth: u32,
	_pad:  u32,
}

@(private)
Open_Keys :: struct {
	room:      []Open_Key,
	heap:      bool,
	n:         int,
	depth:     u32,
	spent:     bool,
	oom:       bool,
	repeat:    u64,
	held:      hook.Regs,
	src:       []u8,
	format:    ^tape.Format,
	xml_ext:   ^tape.Doc_Ext,
	allocator: runtime.Allocator,
	ctx:       ^runtime.Context,
}

@(private)
NO_REPEAT :: max(u64)

@(private, rodata)
DEAD_RECORD := Record{word = NO_KEY, kind = .End}

// Initializes `h` without zeroing `frames_buf`, `factored_buf`, or `first_err`.
@(private)
checker_start :: #force_inline proc(h: ^Checker, plan: ^Plan, src: []u8, format: ^tape.Format, opts: Options, sink: ^Sink, expected: ^hook.Expected_Memo, allocator, scratch: runtime.Allocator, mem_budget: ^hook.Memory_Budget, ctx: ^runtime.Context) -> hook.Regs {
	h.expected, h.plan, h.src, h.format = expected, plan, src, format
	h.xml_ext, h.xml_ext_owned = nil, false
	h.is_binary = format != nil && .Binary in format.caps
	h.has_budget = opts.budget.nodes > 0 || opts.budget.steps > 0 || opts.budget.depth > 0
	h.sink, h.sink_from = sink, len(sink.entries) if sink != nil else 0
	h.allocator, h.scratch, h.mem_budget, h.budget = allocator, scratch, mem_budget, opts.budget
	h.steps_used, h.nodes_seen = 0, 0
	h.dups = opts.dups if opts.dups != .Default else (format.dups if format != nil else .Last)
	h.judge_dups, h.in_doc_group, h.no_factor, h.quiet, h.failed = false, false, false, false, false
	h.fatal, h.need_reread, h.reread_runs = .None, false, false
	h.buffering_choice, h.choice_sink_fo = false, -1
	h.dup_hit, h.dup_at = false, tape.NO_BYTE
	h.first_arena, h.first_recorded = nil, false
	h.frames, h.frames_heap, h.sp = h.frames_buf[:], false, 0
	h.pool, h.owns_pool, h.nf, h.choice_depth, h.skip_end, h.capture_depth = nil, false, 0, 0, false, 0
	h.trackers = {}
	h.trackers.allocator = scratch
	h.tracked, h.tracker0_used, h.arr_uniq_in_use = 0, false, false
	h.parent, h.parent_owner, h.parent_inst_owner, h.parent_extra = nil, nil, nil, nil
	h.nest_depth, h.at_bias, h.subwalk_fn, h.ctx = 0, 0, nil, ctx
	return {b = u64(uintptr(plan.root))}
}

@(private)
checker_cleanup :: #force_inline proc(h: ^Checker) {
	if h.capture_depth == 0 && h.sp == 0 && h.nf == 0 && !h.arr_uniq_in_use && !h.frames_heap && !h.tracker0_used && len(h.trackers) == 0 && !h.owns_pool && !h.xml_ext_owned && h.first_arena == nil {
		return
	}
	checker_cleanup_slow(h)
}

@(private = "file")
destroy_tracker :: proc(tr: ^Key_Tracker, scratch: runtime.Allocator) {
	for nm in tr.owned {
		delete(nm, scratch)
	}
	delete(tr.owned)
	delete(tr.names)
	delete(tr.table)
}

@(private = "file", cold)
checker_cleanup_slow :: #force_no_inline proc(h: ^Checker) {
	for h.capture_depth > 0 {
		capture_abort(h)
	}
	for h.nf > 0 {
		h.nf -= 1
		factored_cleanup(h, factored_at(h, h.nf))
	}
	h.arr_uniq_in_use = false
	for i in 0 ..< h.sp {
		if h.frames[i].key_owned {
			delete(h.frames[i].key_name, h.scratch)
			h.frames[i].key_owned = false
		}
		if len(h.frames[i].seen_wide) > 0 {
			delete(h.frames[i].seen_wide, h.scratch)
			h.frames[i].seen_wide = nil
		}
	}
	if h.frames_heap {
		delete(h.frames, h.scratch)
		h.frames_heap = false
	}
	if h.tracker0_used {
		destroy_tracker(&h.tracker0, h.scratch)
		h.tracker0_used = false
	}
	for &tr in h.trackers {
		destroy_tracker(&tr, h.scratch)
	}
	delete(h.trackers)
	if h.owns_pool && h.pool != nil {
		pool_destroy(h.pool)
		free(h.pool, h.scratch)
		h.pool, h.owns_pool = nil, false
	}
	if h.xml_ext_owned && h.xml_ext != nil {
		free(h.xml_ext, h.scratch)
		h.xml_ext, h.xml_ext_owned = nil, false
	}
	destroy_first_arena(h)
}

@(private = "file")
REGEX_STACK_ROOM :: 2048

@(private = "file")
Spill_Arena :: struct {
	stack:    mem.Arena,
	fallback: runtime.Allocator,
}

@(private = "file")
spill_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	sa := (^Spill_Arena)(data)
	base := uintptr(raw_data(sa.stack.data))
	inside := old != nil && uintptr(old) >= base && uintptr(old) < base + uintptr(len(sa.stack.data))
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if old != nil && !inside { break }
		if got, err := mem.arena_allocator_proc(&sa.stack, mode, size, alignment, old, old_size, loc); err != .Out_Of_Memory {
			return got, err
		}
		got, err := runtime.mem_alloc_bytes(size, alignment, sa.fallback, loc)
		if err == nil && old != nil { copy(got, mem.byte_slice(old, min(old_size, size))) }
		return got, err
	case .Free:
		if inside || old == nil { return nil, nil }
	case .Free_All:
		return nil, .Mode_Not_Implemented
	}
	return sa.fallback.procedure(sa.fallback.data, mode, size, alignment, old, old_size, loc)
}

@(private)
run_regex_search :: proc(h: ^Checker, re: ^regex.Regex, text: string) -> (found: bool, ok: bool) {
	room: [REGEX_STACK_ROOM]u8 = ---
	sa := Spill_Arena{fallback = h.scratch}
	mem.arena_init(&sa.stack, room[:])
	sc, merr := regex.scratch_make({spill_proc, &sa})
	if merr.kind != .None {
		h.fatal = .No_Memory
		return false, false
	}
	defer regex.scratch_destroy(&sc)
	f, serr := regex.search(re, text, 0, nil, &sc, remaining_steps(h))
	charge_steps(h, sc.spent)
	if serr.kind != .None {
		h.fatal = .Exceeded if serr.kind == .Steps else .No_Memory
		return false, false
	}
	return f, true
}

@(private = "file")
run_judge_string :: proc(h: ^Checker, l: ^rules.Leaf, text: string) -> (fails: rules.Failures, ok: bool) {
	sc_ptr: ^regex.Scratch
	room: [REGEX_STACK_ROOM]u8 = ---
	sa: Spill_Arena = ---
	sc: regex.Scratch
	if l.pattern != nil {
		sa = {fallback = h.scratch}
		mem.arena_init(&sa.stack, room[:])
		merr: regex.Error
		sc, merr = regex.scratch_make({spill_proc, &sa})
		if merr.kind != .None {
			h.fatal = .No_Memory
			return {}, false
		}
		sc_ptr = &sc
	}
	defer if sc_ptr != nil {
		regex.scratch_destroy(sc_ptr)
	}
	sf, rerr := rules.judge_string(l, text, sc_ptr, remaining_steps(h), h.scratch)
	if sc_ptr != nil { charge_steps(h, sc.spent) }
	if rerr.kind != .None {
		h.fatal = .Exceeded if rerr.kind == .Steps else .No_Memory
		return {}, false
	}
	return sf, true
}

@(private)
remaining_steps :: #force_inline proc "contextless" (h: ^Checker) -> u64 {
	if h.budget.steps == 0 { return 0 }
	return 1 if h.steps_used >= h.budget.steps else h.budget.steps - h.steps_used
}

@(private)
charge_steps :: #force_inline proc "contextless" (h: ^Checker, n: u64) {
	if h.budget.steps == 0 { return }
	h.steps_used += n
	if h.steps_used > h.budget.steps { h.fatal = .Exceeded }
}

@(private)
charge_step_one :: #force_inline proc "contextless" (h: ^Checker) -> bool {
	if h.budget.steps == 0 { return true }
	h.steps_used += 1
	if h.steps_used > h.budget.steps {
		h.fatal = .Exceeded
		return false
	}
	return true
}

// ============================================================================
// Streaming hook callbacks (`checker_hook` & `refusing_hook`)
// ============================================================================

@(private)
fast_scalar_ok :: #force_inline proc "contextless" (r: ^Record, t: tape.Token, is_binary: bool) -> bool #no_bounds_check {
	#partial switch t.kind {
	case .String:
		return .Pure_String in r.fast_flags && .String in r.leaf_kinds
	case .Number:
		if .Pure_Number not_in r.fast_flags { return false }
		if !is_binary {
			if t.spelling == 0 || (t.spelling & tape.NUMBER_KIND) != 0 { return false }
			return .Number in r.leaf_kinds || (.Integer in r.leaf_kinds && (t.spelling & ~u16(0x1F0)) == 0)
		}
		if t.spelling == 1 { return .Integer in r.leaf_kinds || .Number in r.leaf_kinds }
		return t.spelling == 2 && .Number in r.leaf_kinds
	case .True, .False:
		return .Pure_Scalar in r.fast_flags && .Bool in r.leaf_kinds
	case .Null:
		return .Pure_Scalar in r.fast_flags && .Null in r.leaf_kinds
	}
	return false
}

// Follows up to 4 hops of `verdict_rec` and optional disjoint-kind `obj_arm`/`arr_arm` redirects.
@(private)
redirect_held :: #force_inline proc "contextless" (p: ^Plan, r: ^Record, kind: tape.Kind, allow_arms: bool) -> (out: ^Record, disjoint_miss: bool) #no_bounds_check {
	out = r
	for hops := 0; hops < 4 && (.Held in out.flags); hops += 1 {
		u := &p.uses[out.meta]
		if u.verdict_rec > 0 {
			out = &p.records[u.verdict_rec - 1]
			continue
		}
		if allow_arms {
			arm := u.obj_arm if kind == .Object else u.arr_arm if kind == .Array else 0
			if arm > 0 {
				out = &p.records[arm - 1]
				continue
			}
			if arm < 0 { return out, true }
		}
		break
	}
	return out, false
}

checker_hook :: #force_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if t.role > .Key { return s, .Next }
	if h.capture_depth == 0 && !h.has_budget {
		if t.role == .Key { return on_key(h, s, t) }
		if t.kind == .End {
			if h.skip_end {
				h.skip_end = false
				return s, .Next
			}
			if h.sp > 0 {
				f := &h.frames[h.sp - 1]
				if !f.is_factored && !f.is_group_array && !f.is_choice && !f.key_owned && len(f.seen_wide) == 0 && !f.has_tracker {
					owner := f.owner
					if f.is_object {
						if !h.failed && .Counted not_in owner.flags && .Has_Deps not_in owner.fast_flags {
							if f.in_seq {
								if f.run_start == 0 && owner.req_end_u16 < 0xFFFF && i32((uintptr(s.b) - uintptr(f.block_start)) / size_of(Record)) >= i32(owner.req_end_u16) {
									h.sp -= 1
									return after_value(h, {s.a, f.parent_b, s.c}), .Next
								}
							} else if .Required not_in owner.flags || (owner.members_u16 <= 64 && (f.seen_mask & h.plan.meta[owner.meta].required_mask) == h.plan.meta[owner.meta].required_mask) {
								h.sp -= 1
								return after_value(h, {s.a, f.parent_b, s.c}), .Next
							}
						}
					} else if .Pure_Array in owner.fast_flags {
						h.sp -= 1
						return after_value(h, {s.a, f.parent_b, s.c}), .Next
					}
				}
			}
			return on_end(h, s, t)
		}
		if h.nf == 0 {
			r := (^Record)(uintptr(s.b) - size_of(Record))
			if t.kind <= .Plain {
				if .Held not_in r.flags && fast_scalar_ok(r, t, h.is_binary) {
					if h.sp > 0 && !h.frames[h.sp - 1].is_object { h.frames[h.sp - 1].count += 1 }
					return after_value(h, s), .Next
				}
				return on_value(h, s, t)
			}
			if .Held not_in r.flags && h.sp < len(h.frames) && .Pure_Scalar in r.fast_flags {
				is_obj := t.kind == .Object
				if (is_obj ? .Object : .Array) in r.leaf_kinds {
					if h.sp > 0 && !h.frames[h.sp - 1].is_object { h.frames[h.sp - 1].count += 1 }
					if (is_obj ? (.Trivial_Object in r.fast_flags) : (.Trivial_Array in r.fast_flags)) && h.dups != .Refuse {
						h.skip_end = true
						return after_value(h, s), .Skip
					}
					can_seq := is_obj && .Has_Keys not_in r.flags && !h.judge_dups && r.members_u16 > 0 && h.dups != .Refuse && h.dups != .Group
					f := &h.frames[h.sp]
					h.sp += 1
					f^ = {owner = r, parent_b = s.b, block_start = r.first if is_obj else nil, open_at = t.lo, tracker_idx = -1, is_object = is_obj, in_seq = can_seq}
					next_b := (u64(uintptr(r.first)) if can_seq else u64(uintptr(&DEAD_RECORD))) if is_obj else u64(uintptr(&h.plan.records[h.plan.uses[r.meta].items]))
					return {s.a, next_b, s.c}, .Next
				}
			}
		}
		return on_value(h, s, t)
	}
	return checker_step(h, s, t)
}

refusing_hook :: #force_inline proc "contextless" (h: ^Refusing_Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key { return s, .Next }
	k := &h.open_keys
	open_keys_token(k, t)
	if k.oom { return s, .Stop }
	if k.spent || k.repeat != NO_REPEAT {
		if !k.spent { k.spent, k.held = true, s }
		return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next
	}
	out, act := checker_step(&h.checker, s, t)
	if h.checker.fatal != .None { return out, .Stop }
	if act == .Stop {
		k.spent, k.held = true, out
		return {out.a, u64(uintptr(&DEAD_RECORD)), out.c}, .Next
	}
	if act == .Skip || act == .Rest {
		h.checker.skip_end = false
		return out, .Next
	}
	return out, act
}

@(private)
checker_step :: proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if h.budget.nodes > 0 {
		h.nodes_seen += 1
		if h.nodes_seen > u64(h.budget.nodes) {
			h.fatal = .Exceeded
			return s, .Stop
		}
	}
	if h.capture_depth > 0 { return checker_step_capture(h, s, t) }
	if t.role == .Key { return on_key(h, s, t) }
	if t.kind == .End { return on_end(h, s, t) }
	return on_value(h, s, t)
}

@(private = "file")
checker_step_capture :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	done, ok := capture_feed(h, t)
	if !ok || h.fatal != .None { return s, .Stop }
	if !done { return s, .Next }
	cap_slot := h.pool.captures[h.capture_depth - 1]
	saved_b := cap_slot.saved_b
	in_factored := cap_slot.for_factor || cap_slot.for_arr_elem
	passed := capture_finish(h)
	if h.fatal != .None { return s, .Stop }
	restored := hook.Regs{s.a, saved_b, s.c}
	if !passed {
		if in_factored {
			if !h.need_reread { fail_doomed_factored(h, factored_at(h, h.nf - 1)) }
			return restored, .Stop
		}
		h.failed = true
		if can_stop_early(h) { return restored, .Stop }
	}
	return restored if in_factored else after_value(h, restored), .Next
}

// ============================================================================
// Key handling (`on_key`)
// ============================================================================

@(private = "file")
on_key_named :: #force_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, f: ^Frame, owner: ^Record, m: ^Meta, idx: i32, key_str: string) -> (hook.Regs, hook.Action) #no_bounds_check {
	was_seen, seen_ok := frame_mark_seen(h, f, idx)
	if !seen_ok { return s, .Stop }
	if was_seen {
		if h.judge_dups && h.dups == .First { return s, .Skip if h.dups != .Refuse else .Next }
		if h.dups == .First || h.dups == .Last || (h.dups == .Group && !h.in_doc_group) {
			h.need_reread, h.dup_hit = true, true
			return s, .Stop
		}
	}
	f.count += 1
	if .Has_Keys in owner.flags || h.dups == .Group {
		return on_key_named_cold(h, s, t, owner, m, idx, was_seen, key_str)
	}
	rec_idx := int(m.block + idx)
	if h.dups != .Refuse && !h.judge_dups && m.members <= 64 && idx + 1 < m.members && (f.seen_mask & (~u64(0) << uint(idx + 1))) == 0 {
		f.in_seq, f.run_start = true, idx + 1
		return {s.a, u64(uintptr(&h.plan.records[rec_idx + 1])), s.c}, .Next
	}
	return {s.a, u64(uintptr(&h.plan.solo[2 * rec_idx + 1])), s.c}, .Next
}

@(private)
on_key :: #force_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if h.sp == 0 { return s, .Next }
	f := &h.frames[h.sp - 1]
	if f.is_group_array || f.is_factored || f.key_owned || (t.spelling & tape.SPELLING_DECODE != 0) || (t.kind == .Number && h.is_binary) {
		return on_key_cold(h, s, t)
	}
	if f.in_seq && !flush_sequential(h, f, s.b) { return s, .Stop }
	key_str := string(h.src[t.lo:][:t.n])
	f.key_name, f.has_key = key_str, true
	owner := f.owner
	m := &h.plan.meta[owner.meta]
	if idx := member_find(h.plan, m, key_str); idx >= 0 {
		return on_key_named(h, s, t, f, owner, m, idx, key_str)
	}
	if .Has_Additional not_in owner.flags && .Has_Keys not_in owner.flags && .Counted not_in owner.flags && !f.count_keys && !h.judge_dups && h.dups != .Refuse {
		return {s.a, u64(uintptr(&h.plan.records[h.plan.nothing])), s.c}, .Skip
	}
	return on_key_unnamed_cold(h, s, t, f, owner, m, key_str, false)
}

@(private = "file")
maybe_group_target :: proc(h: ^Checker, next_s: hook.Regs, at: u64, target_r: ^Record, key_name: string, clone_key: bool, was_seen := false) -> (hook.Regs, hook.Action) {
	if h.dups == .Group && !h.in_doc_group {
		if .Held in target_r.flags && record_accepts_kind(h.plan, i32(target_r.meta), .Array, 0) {
			h.need_reread = true
			return next_s, .Stop
		}
		if collects_markup(h, target_r) {
			if was_seen {
				h.need_reread = true
				return next_s, .Stop
			}
			return open_group_array(h, next_s, at, target_r, key_name, clone_key)
		}
	}
	return next_s, .Next
}

@(private = "file")
on_key_named_cold :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, owner: ^Record, m: ^Meta, idx: i32, was_seen: bool, key_str: string) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	if .Has_Keys in owner.flags {
		u := &h.plan.uses[owner.meta]
		if !string_passes_leaf(h, &h.plan.leaves[u.keys - 1], key_str, t.lo, owner, true, u.keys_site) {
			h.failed = true
			if can_stop_early(h) { return s, .Stop }
		}
		if h.fatal != .None { return s, .Stop }
	}
	rec_idx := int(m.block + idx)
	next_s := hook.Regs{s.a, u64(uintptr(&h.plan.solo[2 * rec_idx + 1])), s.c}
	return maybe_group_target(h, next_s, t.lo, &h.plan.records[rec_idx], h.plan.meta[rec_idx].name, false, was_seen)
}

@(private = "file")
on_key_unnamed_cold :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, f: ^Frame, owner: ^Record, m: ^Meta, key_str: string, owned: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	u := &h.plan.uses[owner.meta]
	need_unk_track := (h.judge_dups && !h.in_doc_group) || ((h.dups == .First || h.dups == .Last) && (u.keys > 0 || u.pattern > 0 || m.counted || f.count_keys || (u.additional > 0 && (!u.add_false || h.sink != nil)))) || (h.dups == .Group && !h.in_doc_group && (u.pattern > 0 || u.additional > 0 || m.counted || f.count_keys || u.keys > 0))
	if need_unk_track {
		if !f.has_tracker {
			tidx := open_tracker(h)
			if tidx < 0 {
				h.fatal = .No_Memory
				return s, .Stop
			}
			f.has_tracker, f.tracker_idx = true, i16(tidx)
		}
		tr := tracker_at(h, int(f.tracker_idx))
		if tracker_has(tr, key_str) {
			if h.judge_dups && h.dups == .First { return s, .Skip if h.dups != .Refuse else .Next }
			if h.dups == .First || h.dups == .Last || h.dups == .Group {
				h.need_reread, h.dup_hit = true, true
				return s, .Stop
			}
		} else if !tracker_add(h, tr, key_str, owned) {
			h.fatal = .No_Memory
			return s, .Stop
		}
	}
	f.count += 1
	if u.keys > 0 {
		if !string_passes_leaf(h, &h.plan.leaves[u.keys - 1], key_str, t.lo, owner, true, u.keys_site) {
			h.failed = true
			if can_stop_early(h) { return s, .Stop }
		}
		if h.fatal != .None { return s, .Stop }
	}
	if u.pattern > 0 && u.regex != nil {
		found, rok := run_regex_search(h, u.regex, key_str)
		if !rok { return s, .Stop }
		if found {
			return maybe_group_target(h, {s.a, u64(uintptr(&h.plan.records[u.pattern])), s.c}, t.lo, &h.plan.records[u.pattern - 1], key_str, true)
		}
	}
	if u.additional > 0 {
		return maybe_group_target(h, {s.a, u64(uintptr(&h.plan.records[u.additional])), s.c}, t.lo, &h.plan.records[u.additional - 1], key_str, true)
	}
	nothing_b := u64(uintptr(&h.plan.records[h.plan.nothing]))
	return {s.a, nothing_b, s.c}, .Skip if h.dups != .Refuse else .Next
}

@(private = "file")
on_key_cold :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	s := s
	if h.frames[h.sp - 1].is_group_array {
		key_str, owned, ok := token_key_text(h, t)
		if !ok {
			h.fatal = .No_Memory
			return s, .Stop
		}
		same := key_str == h.frames[h.sp - 1].key_name
		if owned { delete(key_str, h.scratch) }
		if same { return s, .Next }
		act: hook.Action
		s, act = close_group_array(h, s, t.lo)
		if act == .Stop || h.fatal != .None { return s, .Stop }
	}
	f := &h.frames[h.sp - 1]
	if f.key_owned {
		delete(f.key_name, h.scratch)
		f.key_owned = false
	}
	key_str, owned, ok := token_key_text(h, t)
	if !ok {
		h.fatal = .No_Memory
		return s, .Stop
	}
	if f.is_factored {
		fo := factored_at(h, h.nf - 1)
		save_key := fo.collect_errors || (!h.first_recorded && h.sink == nil && !fo.saved_quiet && fo.factor.direct_errors)
		f.has_key = save_key
		if save_key { f.key_name, f.key_owned = key_str, owned }
		defer if !save_key && owned {
			delete(key_str, h.scratch)
		}
		skip, doomed := factored_key(h, fo, key_str, owned, t.lo)
		if h.fatal != .None || doomed {
			if h.fatal == .None && !h.need_reread { fail_doomed_factored(h, fo) }
			return s, .Stop
		}
		if skip {
			if h.dups != .Refuse { return s, .Skip }
			return {s.a, u64(uintptr(&h.plan.records[h.plan.nothing])), s.c}, .Next
		}
		return s, .Next
	}
	if f.in_seq && !flush_sequential(h, f, s.b) {
		if owned { delete(key_str, h.scratch) }
		return s, .Stop
	}
	f.key_name, f.has_key, f.key_owned = key_str, true, owned
	owner := f.owner
	m := &h.plan.meta[owner.meta]
	if idx := member_find(h.plan, m, key_str); idx >= 0 {
		return on_key_named(h, s, t, f, owner, m, idx, key_str)
	}
	return on_key_unnamed_cold(h, s, t, f, owner, m, key_str, owned)
}

@(private)
flush_sequential :: #force_inline proc "contextless" (h: ^Checker, f: ^Frame, cur_b: u64) -> bool #no_bounds_check {
	f.in_seq = false
	cur_idx := int((uintptr(cur_b) - uintptr(f.block_start)) / size_of(Record))
	start := int(f.run_start)
	if cur_idx <= start { return true }
	members := int(f.owner.members_u16)
	if members == 65535 { members = int(h.plan.meta[f.owner.meta].members) }
	cur_idx = min(cur_idx, members)
	if cur_idx <= start { return true }
	f.count += u64(cur_idx - start)
	if members <= 64 {
		hi := ~u64(0) if cur_idx == 64 else (u64(1) << uint(cur_idx)) - 1
		f.seen_mask |= hi & ~((u64(1) << uint(start)) - 1)
		return true
	}
	for i in start ..< cur_idx {
		if _, ok := frame_mark_seen(h, f, i32(i)); !ok { return false }
	}
	return true
}

// ============================================================================
// Value handling (`on_value`)
// ============================================================================

@(private)
on_value :: proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if h.sp > 0 && h.frames[h.sp - 1].is_factored { return on_value_factored(h, s, t) }
	orig_r := (^Record)(uintptr(s.b) - size_of(Record))
	r := orig_r
	if h.sp > 0 && !h.frames[h.sp - 1].is_object { h.frames[h.sp - 1].count += 1 }
	if .Held in r.flags {
		if h.sink == nil || h.quiet {
			disjoint_miss: bool
			r, disjoint_miss = redirect_held(h.plan, r, t.kind, true)
			if disjoint_miss { return fail_disjoint_arm(h, s, t, orig_r, r) }
		}
		if .Held in r.flags {
			if !h.quiet && r != orig_r && !(.Factored in r.flags && factor_for_token(&h.plan.uses[r.meta], t.kind) != nil && !h.no_factor && !h.judge_dups) {
				r = orig_r
			}
			return on_value_held(h, s, t, r)
		}
	}
	if t.kind != .Object && t.kind != .Array {
		if fast_scalar_ok(r, t, h.is_binary) || r.rule_set == 0 { return after_value(h, s), .Next }
		return on_value_scalar_slow(h, s, t, r)
	}
	return open_container(h, s, t, r, is_choice = false)
}

@(private = "file", cold)
fail_disjoint_arm :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, orig_owner, cur_owner: ^Record) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	u := &h.plan.uses[cur_owner.meta]
	aps := u.verdict if len(u.verdict) > 0 else u.applies
	kw := aps[0].keyword if len(aps) > 0 else "anyOf"
	alt_site := u.site if cur_owner.meta != orig_owner.meta else nil
	record_first_failure(h, .No_Arm, t.lo, kw, "", orig_owner, alt_site = alt_site)
	h.failed = true
	if can_stop_early(h) { return s, .Stop }
	if h.dups != .Refuse {
		h.skip_end = true
		return after_value(h, s), .Skip
	}
	return open_container(h, s, t, &h.plan.records[h.plan.nothing - 1], is_choice = false)
}

@(private = "file")
on_value_scalar_slow :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, r: ^Record) -> (hook.Regs, hook.Action) #no_bounds_check {
	l := &h.plan.leaves[r.rule_set - 1]
	if t.kind == .String && (t.spelling & tape.SPELLING_ASCII != 0) && (t.spelling & tape.SPELLING_DECODE == 0) && .String in l.kinds && l.pattern == nil && l.formats == {} && !l.has_enum {
		if u64(t.n) >= l.min_length && u64(t.n) <= l.max_length { return after_value(h, s), .Next }
	}
	if t.kind == .Number && !h.is_binary && l.fast && t.spelling != 0 && (t.spelling & ~u16(0x1F0)) == 0 && (.Number in l.kinds || .Integer in l.kinds) {
		if ((t.spelling >> 4) & 31) <= 18 && t.n > 0 {
			p := h.src[t.lo:][:t.n]
			neg := p[0] == '-'
			v := i64(0)
			for i := 1 if neg else 0; i < len(p); i += 1 {
				v = v * 10 + i64(p[i] - '0')
			}
			if neg { v = -v }
			if (!l.minimum.set || v > l.minimum.int || (v == l.minimum.int && !l.minimum.exclusive)) && (!l.maximum.set || v < l.maximum.int || (v == l.maximum.int && !l.maximum.exclusive)) {
				return after_value(h, s), .Next
			}
		}
	}
	context = h.ctx^
	err_owner, alt_site := resolve_err_owner(h, r, s.b, false)
	if !judge_scalar_token(h, l, t, err_owner, alt_site) {
		h.failed = true
		if can_stop_early(h) { return s, .Stop }
	}
	if h.fatal != .None { return s, .Stop }
	return after_value(h, s), .Next
}

@(private = "file")
on_value_factored :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	fo := factored_at(h, h.nf - 1)
	is_arr := fo.factor.arr != nil
	if is_arr { h.frames[h.sp - 1].count += 1 }
	if t.kind != .Object && t.kind != .Array {
		doomed := factored_arr_scalar(h, fo, t) if is_arr else factored_scalar(h, fo, t)
		if h.fatal != .None { return s, .Stop }
		if doomed {
			fail_doomed_factored(h, fo)
			return s, .Stop
		}
		return s, .Next
	}
	choice_rec: ^Record
	use_fork, for_elem, skip, doomed: bool
	if is_arr {
		choice_rec, use_fork, for_elem, skip, doomed = factored_arr_container(h, fo, t)
	} else {
		choice_rec, use_fork, skip, doomed = factored_container(h, fo, t)
	}
	if h.fatal != .None { return s, .Stop }
	if doomed {
		fail_doomed_factored(h, fo)
		return s, .Stop
	}
	if skip {
		if h.dups != .Refuse {
			h.skip_end = true
			return s, .Skip
		}
		return open_container(h, s, t, &h.plan.records[h.plan.nothing - 1], is_choice = false)
	}
	if for_elem || use_fork {
		if !capture_start(h, fo.owner, t.lo, s.b, for_factor = !for_elem, fm = fo.active_member, for_arr_elem = for_elem) {
			return s, .Stop
		}
		if _, ok := capture_feed(h, t); !ok { return s, .Stop }
		return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next
	}
	count_keys := !is_arr && fm_has_count_leaves(h.plan, fo.active_member, t.kind == .Object)
	if fo.collect_errors { choice_sink_enter_open(h, fo, h.nf - 1) }
	return open_container(h, s, t, choice_rec, is_choice = true, count_keys = count_keys)
}

@(private = "file")
try_open_factored :: proc(h: ^Checker, s: hook.Regs, t: tape.Token, r: ^Record, is_choice: bool) -> (out: hook.Regs, act: hook.Action, opened: bool) {
	u := &h.plan.uses[r.meta]
	if .Factored in r.flags && !h.no_factor && !h.judge_dups {
		if fac := factor_for_token(u, t.kind); fac != nil {
			if factored_open(h, r, fac, t.lo) {
				f := frame_push_slot(h)
				if f == nil {
					h.nf -= 1
					factored_cleanup(h, factored_at(h, h.nf))
					return s, .Stop, true
				}
				f^ = {is_object = (t.kind == .Object), is_factored = true, is_choice = is_choice, owner = r, parent_b = s.b, open_at = t.lo, tracker_idx = -1}
				if is_choice { h.choice_depth += 1 }
				return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next, true
			}
			if h.fatal != .None { return s, .Stop, true }
		}
	}
	return s, .Next, false
}

@(private = "file")
on_value_held :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, r: ^Record) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	if h.dups == .Group && !h.in_doc_group && t.kind == .Object {
		h.need_reread = true
		return s, .Stop
	}
	if out, act, opened := try_open_factored(h, s, t, r, false); opened { return out, act }
	if t.kind != .Object && t.kind != .Array {
		if !eval_held_scalar(h, r, t) {
			h.failed = true
			if can_stop_early(h) { return s, .Stop }
		}
		if h.fatal != .None { return s, .Stop }
		return after_value(h, s), .Next
	}
	if !capture_start(h, r, t.lo, s.b) { return s, .Stop }
	if _, ok := capture_feed(h, t); !ok { return s, .Stop }
	return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next
}

@(private)
open_container :: proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, r: ^Record, is_choice: bool, count_keys := false) -> (hook.Regs, hook.Action) #no_bounds_check {
	max_depth := int(h.budget.depth) if h.budget.depth > 0 else int(tape.DEFAULT_DEPTH)
	if h.sp + h.nest_depth >= max_depth {
		h.fatal = .Exceeded
		return s, .Stop
	}
	r := r
	if is_choice && .Held in r.flags && (h.quiet || h.sink == nil) {
		r, _ = redirect_held(h.plan, r, t.kind, true)
	}
	if is_choice && .Held in r.flags { return open_choice_held_cold(h, s, t, r) }

	is_obj := t.kind == .Object
	want := rules.Kind.Object if is_obj else rules.Kind.Array
	if (want not_in r.leaf_kinds || .Pure_Scalar not_in r.fast_flags) && r.rule_set > 0 {
		l := &h.plan.leaves[r.rule_set - 1]
		if want not_in l.kinds || l.has_enum {
			if out, act, handled := open_container_type_err(h, s, t, r, l, is_obj, is_choice); handled {
				return out, act
			}
		}
	}
	if (is_obj ? (.Trivial_Object in r.fast_flags) : (.Trivial_Array in r.fast_flags)) && h.dups != .Refuse && !is_choice {
		h.skip_end = true
		return after_value(h, s), .Skip
	}
	can_seq := is_obj && .Has_Keys not_in r.flags && !h.judge_dups && r.members_u16 > 0 && h.dups != .Refuse && h.dups != .Group
	saved_failed := h.failed
	f := frame_push_slot(h)
	if f == nil { return s, .Stop }
	if is_choice {
		h.failed = false
		h.choice_depth += 1
	}
	f^ = {
		owner = r, parent_b = s.b, block_start = r.first if is_obj else nil,
		open_at = t.lo, tracker_idx = -1, is_object = is_obj, is_choice = is_choice,
		in_seq = can_seq, count_keys = count_keys && is_obj, saved_failed = saved_failed,
	}
	next_b := (u64(uintptr(r.first)) if can_seq else u64(uintptr(&DEAD_RECORD))) if is_obj else u64(uintptr(&h.plan.records[h.plan.uses[r.meta].items]))
	return {s.a, next_b, s.c}, .Next
}

@(private = "file", cold)
open_choice_held_cold :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, r: ^Record) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	if out, act, opened := try_open_factored(h, s, t, r, true); opened { return out, act }
	outer_fo := factored_at(h, h.nf - 1)
	if outer_fo.collect_errors { choice_sink_restore_fo(h, outer_fo) }
	if !capture_start(h, r, t.lo, s.b, for_factor = true, fm = outer_fo.active_member) { return s, .Stop }
	if _, ok := capture_feed(h, t); !ok { return s, .Stop }
	return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next
}

@(private = "file", cold)
open_container_type_err :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, r: ^Record, l: ^rules.Leaf, is_obj, is_choice: bool) -> (hook.Regs, hook.Action, bool) #no_bounds_check {
	context = h.ctx^
	want := rules.Kind.Object if is_obj else rules.Kind.Array
	kind := Error_Kind.Wrong_Kind if want not_in l.kinds else Error_Kind.Not_A_Member
	kw := keyword_of_kind(kind, l, is_obj)
	exp := rules.operand_text(l, kind, is_obj, h.scratch) if kind == .Wrong_Kind else ""
	defer if len(exp) > 0 {
		delete(exp, h.scratch)
	}
	if !is_choice || (h.sink != nil && !h.quiet) {
		err_owner, alt_site := resolve_err_owner(h, r, s.b, is_choice)
		emit_or_first(h, kind, t.lo, kw, exp, err_owner, alt_site = alt_site)
		if !is_choice { h.failed = true }
	}
	if is_choice {
		fo := factored_at(h, h.nf - 1)
		if fo.collect_errors {
			record_choice_span(h, fo)
			choice_sink_restore_fo(h, fo)
		}
		if fo.active_member != nil && fo.active_choice >= 0 {
			fo.failed |= fo.active_member.choices[fo.active_choice].parts
		}
		fo.active_member, fo.active_choice = nil, -1
		if can_doom_factored(h, fo.factor, fo.failed) {
			fail_doomed_factored(h, fo)
			return s, .Stop, true
		}
		if h.dups != .Refuse {
			h.skip_end = true
			return s, .Skip, true
		}
		out, act := open_container(h, s, t, &h.plan.records[h.plan.nothing - 1], is_choice = false)
		return out, act, true
	} else if can_stop_early(h) {
		return s, .Stop, true
	}
	return s, .Next, false
}

// ============================================================================
// Container close (`on_end`)
// ============================================================================

@(private)
on_end :: proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if h.skip_end {
		h.skip_end = false
		return s, .Next
	}
	if h.sp == 0 { return s, .Next }
	top := &h.frames[h.sp - 1]
	if top.is_group_array || top.is_factored || top.key_owned || len(top.seen_wide) > 0 || top.has_tracker {
		return on_end_cold(h, s, t)
	}
	h.sp -= 1
	f := &h.frames[h.sp]
	owner := f.owner
	done_ok := false
	if f.is_object {
		if f.in_seq && f.run_start == 0 && .Counted not_in owner.flags && .Has_Deps not_in owner.fast_flags && owner.req_end_u16 < 0xFFFF && i32((uintptr(s.b) - uintptr(f.block_start)) / size_of(Record)) >= i32(owner.req_end_u16) {
			done_ok = true
		} else {
			if f.in_seq && !flush_sequential(h, f, s.b) { return s, .Stop }
			if len(f.seen_wide) == 0 && .Counted not_in owner.flags && .Has_Deps not_in owner.fast_flags {
				done_ok = .Required not_in owner.flags || (owner.members_u16 <= 64 && (f.seen_mask & h.plan.meta[owner.meta].required_mask) == h.plan.meta[owner.meta].required_mask)
			}
		}
	} else if .Pure_Array in owner.fast_flags || owner.rule_set == 0 {
		done_ok = true
	} else {
		l := &h.plan.leaves[owner.rule_set - 1]
		done_ok = f.count >= l.min_items && f.count <= l.max_items
	}
	if done_ok {
		if f.is_object && h.failed && !f.is_choice && can_stop_early(h) { return s, .Stop }
		if f.is_choice && h.nf > 0 { return finish_choice_close_ctx(h, f, s, false) }
		return after_value(h, {s.a, f.parent_b, s.c}), .Next
	}
	return on_end_settle_cold(h, f, s, t)
}

@(private = "file")
finish_choice_close_ctx :: #force_no_inline proc "contextless" (h: ^Checker, f: ^Frame, s: hook.Regs, choice_failed: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	return finish_choice_close(h, f, s, choice_failed)
}

@(private = "file", cold)
on_end_cold :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	s := s
	if h.frames[h.sp - 1].is_group_array {
		act: hook.Action
		s, act = close_group_array(h, s, t.lo)
		if act == .Stop || h.fatal != .None { return s, .Stop }
		if h.sp == 0 { return s, .Next }
	}
	h.sp -= 1
	f := &h.frames[h.sp]
	if f.key_owned {
		delete(f.key_name, h.scratch)
		f.key_owned = false
	}
	defer if len(f.seen_wide) > 0 {
		delete(f.seen_wide, h.scratch)
		f.seen_wide = nil
	}
	if f.has_tracker { close_tracker(h) }
	if f.is_factored {
		if f.is_choice { h.choice_depth -= 1 }
		closing_fo := factored_at(h, h.nf - 1)
		closing_factor, closing_failed, inner_cnt := closing_fo.factor, closing_fo.failed, closing_fo.seen_count
		fo_doc, fo_doc_node := closing_fo.doc, closing_fo.doc_node
		passed, owner, open_at, arr_uniq_fail, emitted := factored_close(h)
		if h.fatal != .None { return s, .Stop }
		if !passed && !emitted && !h.quiet && (h.sink != nil || (!h.first_recorded && closing_factor.direct_errors)) {
			inst_owner, _ := resolve_err_owner(h, owner, f.parent_b, f.is_choice)
			orig_owner := inst_owner if inst_owner != owner else nil
			if fo_doc != nil {
				emitted = replay_factored(h, owner, inst_owner, orig_owner, fo_doc, fo_doc_node, 0, 0)
			} else if h.subwalk_fn != nil && t.lo < u64(len(h.src)) && t.lo >= open_at {
				emitted = replay_factored(h, owner, inst_owner, orig_owner, nil, 0, open_at, t.lo + 1)
			}
			if h.fatal != .None { return s, .Stop }
			if !emitted && h.sink != nil {
				if f.is_choice && h.nf > 0 {
					outer_fo := factored_at(h, h.nf - 1)
					choice_sink_restore_fo(h, outer_fo, outer_fo.saved_quiet)
				}
				h.need_reread, h.reread_runs = true, true
				return s, .Stop
			}
		}
		if f.is_choice && h.nf > 0 {
			outer_fo := factored_at(h, h.nf - 1)
			finish_choice_leaf_counts(h, outer_fo, f.is_object, inner_cnt, open_at)
			if !passed && outer_fo.active_member != nil && outer_fo.active_choice >= 0 {
				outer_fo.failed |= outer_fo.active_member.choices[outer_fo.active_choice].parts
			}
			if outer_fo.collect_errors {
				record_choice_span(h, outer_fo)
				choice_sink_restore_fo(h, outer_fo)
			}
			outer_fo.active_member, outer_fo.active_choice = nil, -1
			if can_doom_factored(h, outer_fo.factor, outer_fo.failed) {
				fail_doomed_factored(h, outer_fo)
				return s, .Stop
			}
			return {s.a, f.parent_b, s.c}, .Next
		}
		if !passed {
			h.failed = true
			if !emitted && h.sink != nil && !h.quiet {
				h.need_reread, h.reread_runs = true, true
				return s, .Stop
			}
			if !emitted {
				err_owner, alt_site := resolve_err_owner(h, owner, f.parent_b, f.is_choice)
				if arr_uniq_fail {
					record_first_failure(h, .Not_Unique, open_at, "uniqueItems", "", err_owner, alt_site = alt_site)
				} else {
					kind, kw := factored_circuit_first_err(closing_factor, closing_failed)
					record_first_failure(h, kind, open_at, kw, "", err_owner, alt_site = alt_site)
				}
			}
			if can_stop_early(h) { return s, .Stop }
		}
		return after_value(h, {s.a, f.parent_b, s.c}), .Next
	}
	if f.is_object && f.in_seq && !flush_sequential(h, f, s.b) { return s, .Stop }
	return on_end_settle_cold(h, f, s, t)
}

@(private = "file")
on_end_settle_cold :: #force_no_inline proc "contextless" (h: ^Checker, f: ^Frame, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	defer if len(f.seen_wide) > 0 {
		delete(f.seen_wide, h.scratch)
		f.seen_wide = nil
	}
	owner := f.owner
	err_owner, alt_site := resolve_err_owner(h, owner, f.parent_b, f.is_choice)
	choice_failed := false
	emit_here := !f.is_choice || (h.sink != nil && !h.quiet)

	if f.is_object {
		if .Counted in owner.flags {
			l := &h.plan.leaves[owner.rule_set - 1]
			if fails := rules.judge_count(f.count, l.min_members, l.max_members); fails != {} {
				choice_failed = true
				if emit_here {
					emit_leaf_failures(h, l, fails, f.open_at, err_owner, true, alt_site)
					h.failed = true
					if !f.is_choice && can_stop_early(h) { return s, .Stop }
				}
			}
		}
		if .Required in owner.flags {
			m := &h.plan.meta[owner.meta]
			check_missing :: proc(h: ^Checker, f: ^Frame, m: ^Meta, idx: i32, kw: string, err_owner: ^Record, alt_site: []tape.Step, emit_here: bool, choice_failed: ^bool) -> bool {
				if frame_is_seen(f, idx) { return false }
				choice_failed^ = true
				if emit_here {
					emit_or_first(h, .Missing_Field, f.open_at, kw, h.plan.meta[m.block + idx].name, err_owner, alt_site = alt_site)
					h.failed = true
					return !f.is_choice && can_stop_early(h)
				}
				return false
			}
			if m.members > 0 && (m.members > 64 || (f.seen_mask & m.required_mask) != m.required_mask) {
				for req_idx in h.plan.meta[m.block + m.members].required {
					if check_missing(h, f, m, req_idx, "required", err_owner, alt_site, emit_here, &choice_failed) {
						return s, .Stop
					}
				}
			}
			if .Has_Deps in owner.fast_flags {
				for req in h.plan.uses[owner.meta].requires {
					if frame_is_seen(f, req.trigger) {
						for want_idx in req.wants {
							if check_missing(h, f, m, want_idx, req.keyword, err_owner, alt_site, emit_here, &choice_failed) {
								return s, .Stop
							}
						}
					}
				}
			}
		}
		if h.failed && !f.is_choice && can_stop_early(h) { return s, .Stop }
	} else if .Pure_Array not_in owner.fast_flags && owner.rule_set > 0 {
		l := &h.plan.leaves[owner.rule_set - 1]
		if fails := rules.judge_count(f.count, l.min_items, l.max_items); fails != {} {
			choice_failed = true
			if emit_here {
				emit_leaf_failures(h, l, fails, f.open_at, err_owner, false, alt_site)
				h.failed = true
				if !f.is_choice && can_stop_early(h) { return s, .Stop }
			}
		}
	}
	if f.is_choice && h.nf > 0 { return finish_choice_close(h, f, s, choice_failed) }
	return after_value(h, {s.a, f.parent_b, s.c}), .Next
}

@(private)
record_choice_span :: proc(h: ^Checker, outer_fo: ^Factored_Open) {
	if !outer_fo.collect_errors || outer_fo.active_member == nil || outer_fo.active_choice < 0 { return }
	if end := len(outer_fo.choice_sink.entries); end > outer_fo.choice_mark {
		factored_buf_err(h, outer_fo, Factored_Err{
			kind = .Choice_Span, no_emit_mask = outer_fo.factor.no_emit_mask,
			choice_from = outer_fo.choice_mark, choice_to = end, base_kw_len = outer_fo.choice_base_kw,
			sites = outer_fo.active_member.choices[outer_fo.active_choice].sites,
		})
	}
}

@(private = "file")
finish_choice_close :: proc(h: ^Checker, f: ^Frame, s: hook.Regs, choice_failed: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	if f.is_object && f.in_seq { _ = flush_sequential(h, f, s.b) }
	h.choice_depth -= 1
	failed_here := choice_failed || h.failed
	h.failed = f.saved_failed
	outer_fo := factored_at(h, h.nf - 1)
	finish_choice_leaf_counts(h, outer_fo, f.is_object, f.count, f.open_at)
	if failed_here && outer_fo.active_member != nil && outer_fo.active_choice >= 0 {
		outer_fo.failed |= outer_fo.active_member.choices[outer_fo.active_choice].parts
	}
	if outer_fo.collect_errors {
		record_choice_span(h, outer_fo)
		choice_sink_restore_fo(h, outer_fo)
	}
	outer_fo.active_member, outer_fo.active_choice = nil, -1
	if can_doom_factored(h, outer_fo.factor, outer_fo.failed) {
		fail_doomed_factored(h, outer_fo)
		return s, .Stop
	}
	return {s.a, f.parent_b, s.c}, .Next
}

@(private = "file")
can_stop_early :: #force_inline proc "contextless" (h: ^Checker) -> bool {
	return (h.sink == nil || h.quiet) && h.choice_depth == 0 && !((h.dups == .Last || h.dups == .Group) && !h.judge_dups && h.sp > 0 && h.frames[h.sp - 1].is_object && !h.frames[h.sp - 1].is_factored)
}

@(private)
collects_markup :: #force_inline proc "contextless" (h: ^Checker, r: ^Record) -> bool #no_bounds_check {
	if r == nil || .Held in r.flags { return false }
	u := &h.plan.uses[r.meta]
	if r.rule_set == 0 { return u.inside }
	l := &h.plan.leaves[r.rule_set - 1]
	return l.kinds - {.Null} == {.Array} || (l.kinds == rules.EVERY_KIND && (u.inside || l.min_items > 0 || l.max_items < max(u64)))
}

@(private)
collects_markup_any :: proc(h: ^Checker, r: ^Record) -> bool {
	if r == nil { return false }
	if .Held not_in r.flags { return collects_markup(h, r) }
	idx := i32(r.meta)
	if !record_accepts_kind(h.plan, idx, .Array, 0) { return false }
	for k in ([?]rules.Kind{.Object, .String, .Number, .Integer, .Bool}) {
		if record_accepts_kind(h.plan, idx, k, 0) { return false }
	}
	return true
}

@(private)
fm_collects_markup :: proc(h: ^Checker, fm: ^Factor_Member) -> bool {
	if fm == nil || fm.table != nil || (len(fm.leaves) == 0 && len(fm.choices) == 0) { return false }
	for fl in fm.leaves {
		if h.plan.leaves[fl.leaf - 1].kinds - {.Null} != {.Array} { return false }
	}
	for ch in fm.choices {
		if !collects_markup_any(h, &h.plan.records[ch.record]) { return false }
	}
	return true
}

@(private = "file")
open_group_array :: proc(h: ^Checker, s: hook.Regs, at: u64, r: ^Record, key_name: string, clone_key: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	max_depth := int(h.budget.depth) if h.budget.depth > 0 else int(tape.DEFAULT_DEPTH)
	if h.sp + h.nest_depth >= max_depth {
		h.fatal = .Exceeded
		return s, .Stop
	}
	stored_key, owned := key_name, false
	if clone_key {
		cp, cerr := strings.clone(key_name, h.scratch)
		if cerr != nil {
			h.fatal = .No_Memory
			return s, .Stop
		}
		stored_key, owned = cp, true
	}
	f := frame_push_slot(h)
	if f == nil {
		if owned { delete(stored_key, h.scratch) }
		return s, .Stop
	}
	f^ = {is_group_array = true, owner = r, parent_b = s.b, open_at = at, key_name = stored_key, key_owned = owned, tracker_idx = -1}
	return {s.a, u64(uintptr(&h.plan.records[h.plan.uses[r.meta].items])), s.c}, .Next
}

@(private = "file")
close_group_array :: proc(h: ^Checker, s: hook.Regs, at: u64) -> (hook.Regs, hook.Action) #no_bounds_check {
	h.sp -= 1
	f := &h.frames[h.sp]
	if f.key_owned {
		delete(f.key_name, h.scratch)
		f.key_owned = false
	}
	owner := f.owner
	if owner.rule_set > 0 {
		l := &h.plan.leaves[owner.rule_set - 1]
		if fails := rules.judge_count(f.count, l.min_items, l.max_items); fails != {} {
			emit_leaf_failures(h, l, fails, f.open_at, owner, false)
			h.failed = true
			if can_stop_early(h) { return s, .Stop }
		}
	}
	return after_value(h, {s.a, f.parent_b, s.c}), .Next
}

@(private)
after_value :: #force_inline proc "contextless" (h: ^Checker, s: hook.Regs) -> hook.Regs #no_bounds_check {
	if s.b == 0 || s.b == u64(uintptr(&DEAD_RECORD)) { return s }
	r := (^Record)(uintptr(s.b) - size_of(Record))
	return {s.a, s.b + size_of(Record), s.c} if .Step in r.flags else s
}

// ============================================================================
// Scalar leaf evaluation
// ============================================================================

@(private)
token_effective_kind :: proc(h: ^Checker, t: tape.Token) -> tape.Kind {
	return .String if t.kind == .Plain else t.kind
}

@(private)
doc_token_text :: proc(doc: ^tape.Document, t: tape.Token, allocator: runtime.Allocator) -> (text: string, owned: bool, ok: bool) {
	if (t.kind == .Null || t.kind == .True || t.kind == .False) && t.role != .Key { return "", false, true }
	room := tape.text_room(doc, t)
	if room == 0 {
		if s, tok := tape.node_text(doc, t, nil); tok { return s, false, true }
		if t.kind == .Number && doc.format != nil && .Binary in doc.format.caps { return "", false, false }
		return string(doc.src[t.lo:][:t.n]), false, true
	}
	buf, err := make([]u8, max(room, int(t.n)), allocator)
	if err != nil { return "", false, false }
	s, tok := tape.node_text(doc, t, buf)
	if !tok {
		delete(buf, allocator)
		return "", false, false
	}
	if raw_data(s) == raw_data(buf) && len(s) == len(buf) { return s, true, true }
	cloned, cerr := strings.clone(s, allocator)
	delete(buf, allocator)
	if cerr != nil { return "", false, false }
	return cloned, true, true
}

@(private)
token_decoded_scalar :: proc(h: ^Checker, t: tape.Token, buf: []u8) -> (text: string, owned: bool, ok: bool) {
	if t.kind == .Null || t.kind == .True || t.kind == .False { return "", false, true }
	if t.spelling & tape.SPELLING_DECODE == 0 && !(t.kind == .Number && h.is_binary) {
		return string(h.src[t.lo:][:t.n]), false, true
	}
	doc := tape.Document{src = h.src, format = h.format, ext = h.xml_ext}
	if tape.text_room(&doc, t) <= len(buf) {
		if s, tok := tape.node_text(&doc, t, buf); tok { return s, false, true }
	}
	return doc_token_text(&doc, t, h.scratch)
}

@(private)
token_key_text :: proc(h: ^Checker, t: tape.Token) -> (text: string, owned: bool, ok: bool) {
	if t.spelling & tape.SPELLING_DECODE == 0 && !(t.kind == .Number && h.is_binary) {
		return string(h.src[t.lo:][:t.n]), false, true
	}
	doc := tape.Document{src = h.src, format = h.format, ext = h.xml_ext}
	return doc_token_text(&doc, t, h.scratch)
}

@(private)
resolve_plain_token :: proc(h: ^Checker, l: ^rules.Leaf, text: string) -> (kind: tape.Kind, num_val: spell.Number, has_num: bool) {
	for pass in 0 ..< 2 {
		all := pass == 1
		if (all || .Null in l.plain) && (len(text) == 0 || text == "null") {
			return .Null, {}, false
		}
		if all || .Bool in l.plain {
			if text == "true" { return .True, {}, false }
			if text == "false" { return .False, {}, false }
		}
		if (all || .Number in l.plain || .Integer in l.plain) && len(text) > 0 {
			if num, ok := spell.number_strict(transmute([]u8)text, 0, u64(len(text))); ok {
				return .Number, num, true
			}
		}
		if all || .String in l.plain {
			return .String, {}, false
		}
	}
	return .String, {}, false
}

@(private)
eval_scalar_leaf :: proc(h: ^Checker, l: ^rules.Leaf, t: tape.Token) -> rules.Failures {
	buf: [128]u8 = ---
	text, owned, ok := token_decoded_scalar(h, t, buf[:])
	if !ok {
		if t.kind != .Number {
			h.fatal = .No_Memory
			return {}
		}
		text = ""
	}
	defer if owned {
		delete(text, h.scratch)
	}
	kind := t.kind
	plain_num: spell.Number
	has_plain_num := false
	if kind == .Plain { kind, plain_num, has_plain_num = resolve_plain_token(h, l, text) }
	return judge_scalar_core(h, l, kind, text, t, plain_num, has_plain_num)
}

@(private)
judge_scalar_token :: proc(h: ^Checker, l: ^rules.Leaf, t: tape.Token, owner: ^Record, alt_site: []tape.Step = nil) -> bool {
	fails := eval_scalar_leaf(h, l, t)
	if h.fatal != .None { return false }
	if fails == {} { return true }
	emit_leaf_failures(h, l, fails, t.lo, owner, false, alt_site)
	return false
}

@(private)
scalar_passes_leaf :: proc(h: ^Checker, l: ^rules.Leaf, t: tape.Token) -> bool {
	fails := eval_scalar_leaf(h, l, t)
	return h.fatal == .None && fails == {}
}

@(private)
normalize_token_number :: proc(h: ^Checker, t: tape.Token, raw_text: string, buf: []u8) -> (text: string, owned: bool, ok: bool) {
	if (t.spelling != 0 || h.is_binary) && h.format != nil && h.format.number != nil {
		num := h.format.number(h.src, tape.Node(t))
		switch num.kind {
		case .Int:  return strconv.write_int(buf, i64(num.bits), 10), false, true
		case .Uint: return strconv.write_uint(buf, num.bits, 10), false, true
		case .Float:
			f := transmute(f64)num.bits
			if math.is_nan(f) || math.is_inf(f, 0) { return "", false, false }
			if h.is_binary {
				return strconv.write_float(buf, f, 'g', -1, 64, {}), false, true
			}
		case .Wide:
			if len(raw_text) == 0 { return "", false, false }
		}
	}
	return rules.normalize_decimal_text(raw_text, buf, h.scratch)
}

@(private)
scalar_passes_record :: proc(h: ^Checker, rec_idx: i32, t: tape.Token) -> bool {
	r := &h.plan.records[rec_idx]
	if .Held in r.flags {
		saved_q := h.quiet
		h.quiet = true
		ok := eval_held_scalar(h, r, t)
		h.quiet = saved_q
		return ok
	}
	return true if r.rule_set == 0 else scalar_passes_leaf(h, &h.plan.leaves[r.rule_set - 1], t)
}

@(private)
judge_scalar_core :: proc(h: ^Checker, l: ^rules.Leaf, kind: tape.Kind, text: string, t: tape.Token, plain_num: spell.Number, has_plain_num: bool) -> (fails: rules.Failures) {
	#partial switch kind {
	case .Null:
		if .Null not_in l.kinds {
			fails += {.Wrong_Kind}
		}
	case .True, .False:
		if .Bool not_in l.kinds {
			fails += {.Wrong_Kind}
		}
	case .Number:
		want_num, want_int := .Number in l.kinds, .Integer in l.kinds
		if !want_num && !want_int {
			fails += {.Wrong_Kind}
		} else {
			num_buf: [64]u8 = ---
			num_text, num_owned := text, false
			defer if num_owned {
				delete(num_text, h.scratch)
			}
			small: Maybe(i64)
			is_int, non_finite, unspellable := false, false, false
			if has_plain_num {
				switch plain_num.kind {
				case .Int:  small, is_int = i64(plain_num.bits), true
				case .Uint:
					if plain_num.bits <= u64(max(i64)) { small = i64(plain_num.bits) }
					is_int = true
				case .Float, .Wide:
					if !rules.valid_decimal_text(num_text) {
						non_finite = true
					} else {
						is_int = !l.integer_spelled && rules.integral(rules.decimal_of(num_text))
					}
				}
			} else if !h.is_binary && t.spelling != 0 && (t.spelling & ~u16(0x1F0)) == 0 {
				is_int = true
				if !(l.minimum.set || l.maximum.set || l.multiple_of != nil || l.has_enum) { return fails }
				if ((t.spelling >> 4) & 31) <= 18 && len(num_text) > 0 {
					p := raw_data(num_text)
					neg := p[0] == '-'
					v := i64(0)
					for i := 1 if neg else 0; i < len(num_text); i += 1 {
						v = v * 10 + i64(p[i] - '0')
					}
					if neg { v = -v }
					if l.fast {
						if l.minimum.set && (v < l.minimum.int || (v == l.minimum.int && l.minimum.exclusive)) {
							fails += {.Below_Minimum}
						}
						if l.maximum.set && (v > l.maximum.int || (v == l.maximum.int && l.maximum.exclusive)) {
							fails += {.Above_Maximum}
						}
						return fails
					}
					small = v
				}
			} else if (t.spelling != 0 || h.is_binary) && h.format != nil && h.format.number != nil {
				num := h.format.number(h.src, tape.Node(t))
				need_text := l.minimum.set || l.maximum.set || l.multiple_of != nil || l.has_enum
				switch num.kind {
				case .Int:
					small, is_int = i64(num.bits), true
					if need_text && !l.fast { num_text = strconv.write_int(num_buf[:], i64(num.bits), 10) }
				case .Uint:
					if num.bits <= u64(max(i64)) { small = i64(num.bits) }
					is_int = true
					if need_text && !(l.fast && small != nil) {
						num_text = strconv.write_uint(num_buf[:], num.bits, 10)
					}
				case .Float:
					f := transmute(f64)num.bits
					if math.is_nan(f) || math.is_inf(f, 0) {
						non_finite = true
					} else if h.is_binary {
						if !want_num || need_text {
							num_text = strconv.write_float(num_buf[:], f, 'g', -1, 64, {})
							is_int = !l.integer_spelled && rules.integral(rules.decimal_of(num_text))
						}
					} else if nt, nown, nok := rules.normalize_decimal_text(num_text, num_buf[:], h.scratch); !nok {
						non_finite = true
					} else {
						num_text, num_owned = nt, nown
						is_int = !l.integer_spelled && rules.integral(rules.decimal_of(num_text))
					}
				case .Wide:
					if len(num_text) == 0 {
						unspellable = true
					} else if nt, nown, nok := rules.normalize_decimal_text(num_text, num_buf[:], h.scratch); !nok {
						unspellable = true
					} else {
						num_text, num_owned = nt, nown
						is_int = !l.integer_spelled && rules.integral(rules.decimal_of(num_text))
					}
				}
			} else {
				is_plain_digits := len(num_text) > 0
				for c in transmute([]u8)num_text {
					if c == '.' || c == 'e' || c == 'E' {
						is_plain_digits = false
						break
					}
				}
				if is_plain_digits && rules.valid_decimal_text(num_text) {
					is_int = true
					if num, ok := spell.number_strict(transmute([]u8)num_text, 0, u64(len(num_text))); ok {
						if num.kind == .Int {
							small = i64(num.bits)
						} else if num.kind == .Uint && num.bits <= u64(max(i64)) {
							small = i64(num.bits)
						}
					}
				} else if rules.valid_decimal_text(num_text) {
					is_int = !l.integer_spelled && rules.integral(rules.decimal_of(num_text))
				} else {
					non_finite = true
				}
			}
			if non_finite {
				if !want_num { fails += {.Wrong_Kind} }
				num := h.format.number(h.src, tape.Node(t)) if h.format != nil && h.format.number != nil else spell.Number{}
				fv := transmute(f64)num.bits
				if l.minimum.set && !(num.kind == .Float && math.is_inf(fv, 1)) { fails += {.Below_Minimum} }
				if l.maximum.set && !(num.kind == .Float && math.is_inf(fv, -1)) { fails += {.Above_Maximum} }
				if l.multiple_of != nil { fails += {.Not_Multiple} }
				if l.has_enum { fails += {.Not_A_Member} }
				return fails
			}
			if unspellable {
				if !want_num { fails += {.Wrong_Kind} }
				if l.minimum.set || l.maximum.set || l.multiple_of != nil || l.has_enum {
					h.fatal = .Unsupported
				}
				return fails
			}
			if !want_num && !is_int {
				fails += {.Wrong_Kind}
			}
			fails += rules.judge_number(l, num_text, small)
			if l.has_enum {
				if !rules.enum_has(l, kind, num_text, h.scratch) {
					fails += {.Not_A_Member}
				}
				return fails
			}
		}
	case .String:
		if .String not_in l.kinds {
			fails += {.Wrong_Kind}
		} else {
			sf, sok := run_judge_string(h, l, text)
			if !sok { return }
			fails += sf
		}
	}
	if l.has_enum && !rules.enum_has(l, kind, text, h.scratch) {
		fails += {.Not_A_Member}
	}
	return fails
}

@(private)
key_fails_leaf :: proc(h: ^Checker, l: ^rules.Leaf, text: string) -> rules.Failures {
	fails: rules.Failures
	if .String not_in l.kinds {
		fails += {.Wrong_Kind}
	} else {
		sf, sok := run_judge_string(h, l, text)
		if !sok {
			return {}
		}
		fails += sf
	}
	if l.has_enum && !rules.enum_has(l, .String, text, h.scratch) {
		fails += {.Not_A_Member}
	}
	return fails
}

@(private)
string_passes_leaf :: proc(h: ^Checker, l: ^rules.Leaf, text: string, at: u64, owner: ^Record, is_key: bool, keys_site: []tape.Step = nil) -> bool {
	fails := key_fails_leaf(h, l, text)
	if h.fatal != .None { return false }
	if fails == {} { return true }
	if is_key {
		has_ks := len(keys_site) > 0
		emit_leaf_failures(h, l, fails, at, owner, false, keys_site, "" if has_ks else "propertyNames", has_ks)
	} else {
		emit_leaf_failures(h, l, fails, at, owner, false)
	}
	return false
}

@(private)
emit_leaf_failures :: proc(h: ^Checker, l: ^rules.Leaf, fails: rules.Failures, at: u64, owner: ^Record, members: bool, alt_site: []tape.Step = nil, extra_kw := "", replace_top := false) {
	for k in fails {
		kw := keyword_of_kind(k, l, members)
		exp := rules.operand_text(l, k, members, h.scratch)
		emit_or_first(h, k, at, kw, exp, owner, extra_kw, alt_site, replace_top)
		if len(exp) > 0 { delete(exp, h.scratch) }
		if h.sink == nil || h.quiet { return }
	}
}

@(private)
eval_held_scalar :: proc(h: ^Checker, owner: ^Record, t: tape.Token) -> bool {
	nodes := [1]tape.Node{tape.Node(t)}
	doc := tape.Document{src = h.src, nodes = nodes[:], format = h.format, ext = h.xml_ext}
	return eval_held_node(h, &doc, 0, owner, t.lo)
}

// ============================================================================
// Subcheck helpers & explicit-stack `walk_document_node`
// ============================================================================

@(private = "file")
sub_checker_begin :: proc(
	h, sub: ^Checker,
	src: []u8,
	format: ^tape.Format,
	xml_ext: ^tape.Doc_Ext,
	sink: ^Sink,
	memo: ^hook.Expected_Memo,
	ctx: ^runtime.Context,
	quiet, no_factor: bool,
	owner, inst_owner: ^Record,
	extra_path: []tape.Step,
	nest_depth: int,
	at_bias: u64,
) {
	_ = checker_start(sub, h.plan, src, format, {dups = h.dups, budget = h.budget, scratch = h.scratch}, sink, memo, h.allocator, h.scratch, h.mem_budget, ctx)
	sub.xml_ext, sub.judge_dups, sub.in_doc_group = xml_ext, h.judge_dups, h.in_doc_group
	sub.steps_used, sub.nodes_seen = h.steps_used, h.nodes_seen
	sub.quiet, sub.no_factor = quiet, no_factor
	sub.buffering_choice, sub.choice_sink_fo = h.buffering_choice, -1
	sub.parent, sub.parent_owner, sub.parent_inst_owner, sub.parent_extra = h, owner, inst_owner, extra_path
	sub.nest_depth, sub.at_bias, sub.subwalk_fn = nest_depth, at_bias, h.subwalk_fn
}

@(private = "file")
sub_checker_end :: proc(h, sub: ^Checker, copy_first: bool, propagate_reread: bool) {
	h.steps_used, h.nodes_seen = sub.steps_used, sub.nodes_seen
	if sub.fatal != .None && h.fatal == .None { h.fatal = sub.fatal }
	if propagate_reread {
		h.need_reread ||= sub.need_reread
		h.reread_runs ||= sub.reread_runs
	}
	if copy_first && sub.first_recorded && !h.first_recorded { copy_first_error(h, sub) }
	destroy_first_arena(sub)
	checker_cleanup(sub)
}

@(private)
subcheck_node :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, rec_idx: i32, extra_path: []tape.Step, owner: ^Record, quiet: bool) -> bool #no_bounds_check {
	tok := doc.nodes[node]
	if tok.kind <= .Plain && h.budget.nodes == 0 {
		rec := &h.plan.records[rec_idx]
		if .Held in rec.flags && (quiet || h.quiet || h.sink == nil) {
			rec, _ = redirect_held(h.plan, rec, tok.kind, false)
		}
		if .Held not_in rec.flags {
			if rec.rule_set == 0 { return true }
			is_bin := doc.format != nil && .Binary in doc.format.caps
			if fast_scalar_ok(rec, tok, is_bin) { return true }
			same_src := doc.src == nil || (raw_data(doc.src) == raw_data(h.src) && len(doc.src) == len(h.src))
			if quiet || h.quiet {
				#partial switch tok.kind {
				case .String:      if .String not_in rec.leaf_kinds { return false }
				case .Number:      if .Number not_in rec.leaf_kinds && .Integer not_in rec.leaf_kinds { return false }
				case .True, .False: if .Bool not_in rec.leaf_kinds { return false }
				case .Null:        if .Null not_in rec.leaf_kinds { return false }
				}
				if same_src { return scalar_passes_leaf(h, &h.plan.leaves[rec.rule_set - 1], tok) }
			} else if same_src {
				if scalar_passes_leaf(h, &h.plan.leaves[rec.rule_set - 1], tok) { return true }
				if h.fatal != .None { return false }
			}
		}
	}

	max_depth := int(h.budget.depth) if h.budget.depth > 0 else int(tape.DEFAULT_DEPTH)
	if h.sp + h.nest_depth >= max_depth {
		h.fatal = .Exceeded
		return false
	}

	sub: Checker = ---
	memo: hook.Expected_Memo = ---
	ctx := context
	sub_quiet := quiet || h.quiet
	sub_checker_begin(h, &sub, doc.src, doc.format, doc.ext, h.sink if (h.sink != nil && !sub_quiet) else nil, &memo, &ctx, sub_quiet, h.no_factor, owner, nil, extra_path, h.sp + h.nest_depth + 1, h.at_bias)
	defer sub_checker_end(h, &sub, !sub_quiet, true)
	return walk_document_node(&sub, doc, node, &h.plan.records[rec_idx])
}

@(private)
subcheck_key_string :: proc(h: ^Checker, key_str: string, doc: ^tape.Document, rec_idx: i32, owner: ^Record, quiet: bool) -> bool {
	key_bytes := transmute([]u8)key_str
	nodes := [1]tape.Node{{lo = 0, n = u32(len(key_bytes)), kind = .String, role = .Value}}
	synth := tape.Document{src = key_bytes, nodes = nodes[:], format = doc.format}
	return subcheck_node(h, &synth, 0, rec_idx, nil, owner, quiet)
}

@(private)
walk_document_node :: proc(h: ^Checker, doc: ^tape.Document, root_node: tape.Node_Index, root_rec: ^Record) -> bool {
	Group_Bucket :: struct {
		kt:   tape.Token,
		vals: []tape.Node_Index,
	}
	Doc_Frame :: struct {
		doc:           ^tape.Document,
		owns_doc:      bool,
		node:          tape.Node_Index,
		is_object:     bool,
		iter:          tape.Children,
		open_factored: bool,
		factored_rec:  ^Record,
		grouped:       []Group_Bucket,
		grouped_pos:   int,
	}

	free_grouped :: proc(h: ^Checker, buckets: []Group_Bucket) {
		for gb in buckets {
			delete(gb.vals, h.scratch)
		}
		delete(buckets, h.scratch)
	}
	free_synthetic_doc :: proc(h: ^Checker, sdoc: ^tape.Document) {
		if sdoc == nil { return }
		delete(sdoc.nodes, h.scratch)
		delete(sdoc.facts, h.scratch)
		delete(sdoc.counts, h.scratch)
		free(sdoc, h.scratch)
	}
	build_synthetic_array_doc :: proc(h: ^Checker, src_doc: ^tape.Document, vals: []tape.Node_Index) -> (res: ^tape.Document, ok: bool) {
		total := 1
		for v in vals {
			vn := src_doc.nodes[v]
			total += int(vn.n) if (vn.kind == .Object || vn.kind == .Array) else 1
		}
		nodes, nerr := make([]tape.Node, total, h.scratch)
		sdoc, derr := new(tape.Document, h.scratch)
		counts := make([dynamic]tape.Child_Count, h.scratch)
		facts := make([dynamic]tape.Fact, h.scratch)
		defer if !ok {
			delete(facts)
			delete(counts)
			delete(nodes, h.scratch)
			free(sdoc, h.scratch)
		}
		if nerr != nil || derr != nil {
			h.fatal = .No_Memory
			return nil, false
		}
		sp := u16(len(vals))
		if len(vals) >= int(tape.MAX_CHILDREN) {
			sp = tape.MAX_CHILDREN
			if _, cerr := append(&counts, tape.Child_Count{node = 0, count = u32(len(vals))}); cerr != nil {
				h.fatal = .No_Memory
				return nil, false
			}
		}
		nodes[0] = {lo = src_doc.nodes[vals[0]].lo if len(vals) > 0 else 0, n = u32(total), kind = .Array, role = .Value, spelling = sp}
		present: tape.Facts
		pos := 1
		for v in vals {
			vn := src_doc.nodes[v]
			sz := int(vn.n) if (vn.kind == .Object || vn.kind == .Array) else 1
			copy(nodes[pos:][:sz], src_doc.nodes[v:][:sz])
			v_end := v + tape.Node_Index(sz)
			if len(src_doc.facts) > 0 {
				lo, hi := 0, len(src_doc.facts)
				for lo < hi {
					mid := (lo + hi) / 2
					if src_doc.facts[mid].node < v { lo = mid + 1 } else { hi = mid }
				}
				for fi := lo; fi < len(src_doc.facts) && src_doc.facts[fi].node < v_end; fi += 1 {
					f := src_doc.facts[fi]
					f.node = tape.Node_Index(pos) + (f.node - v)
					present += {f.kind}
					if _, ferr := append(&facts, f); ferr != nil {
						h.fatal = .No_Memory
						return nil, false
					}
				}
			}
			for cc in src_doc.counts {
				if cc.node >= v && cc.node < v_end {
					if _, cerr := append(&counts, tape.Child_Count{node = tape.Node_Index(pos) + (cc.node - v), count = cc.count}); cerr != nil {
						h.fatal = .No_Memory
						return nil, false
					}
				}
			}
			pos += sz
		}
		sdoc^ = {src = src_doc.src, nodes = nodes, facts = facts[:], counts = counts[:], format = src_doc.format, ext = src_doc.ext, present = present}
		return sdoc, true
	}

	build_group_buckets :: proc(h: ^Checker, r: tape.Reader, cur_doc: ^tape.Document, it: ^tape.Children) -> (out: []Group_Bucket, ok: bool) {
		Slot :: struct {
			kt:   tape.Token,
			vals: [dynamic]tape.Node_Index,
		}
		slots := make([dynamic]Slot, h.scratch)
		owned_names := make([dynamic]string, h.scratch)
		index := make(map[string]int, 8, h.scratch)
		defer {
			if !ok {
				for &sl in slots {
					delete(sl.vals)
				}
			}
			for nm in owned_names {
				delete(nm, h.scratch)
			}
			delete(owned_names)
			delete(index)
			delete(slots)
		}
		for {
			kn, vn, cp := tape.next_child(r, it, .Group)
			if cp != .Found { break }
			kt := tape.cell_key(r, it^) if (kn == tape.NO_NODE && it.keys_n != 0) else cur_doc.nodes[kn]
			ks, kown, kok := doc_token_text(cur_doc, kt, h.scratch)
			if !kok {
				h.fatal = .No_Memory
				return nil, false
			}
			if kown { append(&owned_names, ks) }
			if si, exists := index[ks]; exists {
				if _, aerr := append(&slots[si].vals, vn); aerr != nil {
					h.fatal = .No_Memory
					return nil, false
				}
			} else {
				vl, verr := make([dynamic]tape.Node_Index, 0, 1, h.scratch)
				_, a1 := append(&vl, vn)
				_, a2 := append(&slots, Slot{kt = kt, vals = vl})
				if verr != nil || a1 != nil || a2 != nil {
					delete(vl)
					h.fatal = .No_Memory
					return nil, false
				}
				index[ks] = len(slots) - 1
			}
		}
		oerr: runtime.Allocator_Error
		out, oerr = make([]Group_Bucket, len(slots), h.scratch)
		if oerr != nil {
			h.fatal = .No_Memory
			return nil, false
		}
		for sl, i in slots {
			out[i] = {kt = sl.kt, vals = sl.vals[:]}
		}
		return out, true
	}

	saved_in_doc_group := h.in_doc_group
	if h.dups == .Group { h.in_doc_group = true }
	defer h.in_doc_group = saved_in_doc_group

	stack_buf: [16]Doc_Frame = ---
	stack_slice := stack_buf[:]
	stack_heap := false
	stack_n := 0
	defer {
		for i in 0 ..< stack_n {
			if len(stack_slice[i].grouped) > 0 { free_grouped(h, stack_slice[i].grouped) }
			tape.destroy_children(&stack_slice[i].iter)
			if stack_slice[i].owns_doc { free_synthetic_doc(h, stack_slice[i].doc) }
		}
		if stack_heap { delete(stack_slice, h.scratch) }
	}

	open_doc_container :: proc(h: ^Checker, r: tape.Reader, cur_doc: ^tape.Document, node: tape.Node_Index, is_object: bool, pre_nf, pre_sp: int, sl: ^[]Doc_Frame, is_heap: ^bool, sn: ^int, owns_doc: bool) -> (stopped: bool, adopted: bool) {
		it, p, cerr := tape.children(r, node, h.scratch)
		if cerr != nil {
			h.fatal = .No_Memory
			return true, false
		}
		if p != .Found {
			tape.destroy_children(&it)
			h.fatal = .Unsupported
			return true, false
		}
		opened_fac := h.nf > pre_nf && h.sp > pre_sp && h.frames[h.sp - 1].is_factored
		fac_rec := h.frames[h.sp - 1].owner if opened_fac else nil
		if opened_fac {
			opened_fo := factored_at(h, h.nf - 1)
			opened_fo.doc, opened_fo.doc_node = cur_doc, node
		}
		grouped: []Group_Bucket
		if is_object && h.dups == .Group {
			gok: bool
			grouped, gok = build_group_buckets(h, r, cur_doc, &it)
			if !gok {
				tape.destroy_children(&it)
				return true, false
			}
		}
		if sn^ == len(sl^) {
			grown, err := make([]Doc_Frame, max(32, len(sl^) * 2), h.scratch)
			if err != nil {
				if len(grouped) > 0 { free_grouped(h, grouped) }
				tape.destroy_children(&it)
				h.fatal = .No_Memory
				return true, false
			}
			copy(grown, sl^[:sn^])
			if is_heap^ { delete(sl^, h.scratch) }
			sl^, is_heap^ = grown, true
		}
		sl^[sn^] = {doc = cur_doc, owns_doc = owns_doc, node = node, is_object = is_object, iter = it, open_factored = opened_fac, factored_rec = fac_rec, grouped = grouped}
		sn^ += 1
		return false, owns_doc
	}

	r := tape.Reader{doc = doc}
	regs := hook.Regs{b = u64(uintptr(&h.plan.solo[2 * int(root_rec.meta) + 1]))}

	start_node :: proc(h: ^Checker, r: tape.Reader, cur_doc: ^tape.Document, node: tape.Node_Index, regs: ^hook.Regs, sl: ^[]Doc_Frame, is_heap: ^bool, sn: ^int, owns_doc := false) -> (stopped: bool, adopted: bool) #no_bounds_check {
		n := cur_doc.nodes[node]
		tok := tape.Token{lo = n.lo, n = n.n, kind = n.kind, role = .Value, spelling = n.spelling}
		if n.kind == .Object || n.kind == .Array {
			tok.n = 0
			if h.capture_depth == 0 {
				if h.sp > 0 && h.frames[h.sp - 1].is_factored {
					fo_idx := h.nf - 1
					fo := factored_at(h, fo_idx)
					choice_rec: ^Record
					use_fork, for_elem, skip, doomed: bool
					if fo.factor.arr != nil {
						h.frames[h.sp - 1].count += 1
						choice_rec, use_fork, for_elem, skip, doomed = factored_arr_container(h, fo, tok)
					} else {
						choice_rec, use_fork, skip, doomed = factored_container(h, fo, tok)
					}
					if h.fatal != .None { return true, false }
					if doomed {
						fail_doomed_factored(h, fo)
						return true, false
					}
					if skip { return false, false }
					if for_elem {
						ok_el, _ := factored_arr_eval_elem_node(h, {}, cur_doc, node, fo_idx, fo.active_member, fo.seen_count - 1, adopt_doc = false)
						if h.fatal != .None { return true, false }
						if !ok_el {
							fail_doomed_factored(h, factored_at(h, fo_idx))
							return true, false
						}
						return false, false
					}
					if use_fork {
						if eval_factored_fork_node(h, cur_doc, node, fo_idx, fo.active_member) {
							if h.fatal == .None { fail_doomed_factored(h, factored_at(h, fo_idx)) }
							return true, false
						}
						return false, false
					}
					cr := choice_rec
					if .Held in cr.flags && !fo.collect_errors {
						cr, _ = redirect_held(h.plan, cr, n.kind, false)
					}
					if .Held in cr.flags && !(factor_for_token(&h.plan.uses[cr.meta], n.kind) != nil && !h.no_factor && !h.judge_dups) {
						guard := Choice_Sink_Guard{h.sink, h.quiet, h.buffering_choice, h.choice_sink_fo}
						if fo.collect_errors {
							choice_sink_enter_open(h, fo, fo_idx)
						} else {
							h.quiet = true
						}
						passed := eval_held_node(h, cur_doc, node, cr, n.lo)
						choice_sink_leave(h, guard)
						if h.fatal != .None { return true, false }
						fo = factored_at(h, fo_idx)
						if fo.active_member != nil && len(fo.active_member.leaves) > 0 {
							cnt_i, _, _ := tape.length(r, node, h.scratch)
							finish_choice_leaf_counts(h, fo, n.kind == .Object, u64(max(cnt_i, 0)), n.lo)
						}
						if !passed && fo.active_member != nil && fo.active_choice >= 0 {
							fo.failed |= fo.active_member.choices[fo.active_choice].parts
						}
						if fo.collect_errors { record_choice_span(h, fo) }
						fo.active_member, fo.active_choice = nil, -1
						if can_doom_factored(h, fo.factor, fo.failed) {
							fail_doomed_factored(h, fo)
							return true, false
						}
						return false, false
					}
					count_keys := fm_has_count_leaves(h.plan, fo.active_member, n.kind == .Object)
					if fo.collect_errors { choice_sink_enter_open(h, fo, fo_idx) }
					pre_nf, pre_sp := h.nf, h.sp
					act: hook.Action
					regs^, act = open_container(h, regs^, tok, cr, is_choice = true, count_keys = count_keys)
					if act == .Stop || h.fatal != .None { return true, false }
					if act == .Skip || act == .Rest {
						if act == .Skip { h.skip_end = false }
						return false, false
					}
					return open_doc_container(h, r, cur_doc, node, n.kind == .Object, pre_nf, pre_sp, sl, is_heap, sn, owns_doc)
				}

				rec := (^Record)(uintptr(regs.b) - size_of(Record))
				eff := rec
				if .Held in eff.flags && (h.sink == nil || h.quiet) {
					eff, _ = redirect_held(h.plan, eff, n.kind, true)
				}
				if .Held in eff.flags && !(factor_for_token(&h.plan.uses[eff.meta], n.kind) != nil && !h.no_factor && !h.judge_dups) {
					if h.budget.nodes > 0 {
						h.nodes_seen += 1
						if h.nodes_seen > u64(h.budget.nodes) {
							h.fatal = .Exceeded
							return true, false
						}
					}
					if h.sp > 0 && !h.frames[h.sp - 1].is_object { h.frames[h.sp - 1].count += 1 }
					if !eval_held_node(h, cur_doc, node, rec, n.lo) {
						h.failed = true
						if can_stop_early(h) { return true, false }
					}
					if h.fatal != .None { return true, false }
					regs^ = after_value(h, regs^)
					return false, false
				}
			}
		} else if h.capture_depth == 0 && h.nf == 0 && !h.has_budget {
			rec := (^Record)(uintptr(regs.b) - size_of(Record))
			if .Held not_in rec.flags && fast_scalar_ok(rec, tok, h.is_binary) {
				if h.sp > 0 && !h.frames[h.sp - 1].is_object { h.frames[h.sp - 1].count += 1 }
				regs^ = after_value(h, regs^)
				return false, false
			}
		}
		pre_nf, pre_sp := h.nf, h.sp
		act: hook.Action
		regs^, act = checker_step(h, regs^, tok)
		if act == .Stop || h.fatal != .None { return true, false }
		if act == .Skip || act == .Rest {
			if act == .Skip && (n.kind == .Object || n.kind == .Array) {
				regs^, _ = checker_step(h, regs^, {lo = n.lo, kind = .End, role = .Value})
			}
			return false, false
		}
		if n.kind == .Object || n.kind == .Array {
			return open_doc_container(h, r, cur_doc, node, n.kind == .Object, pre_nf, pre_sp, sl, is_heap, sn, owns_doc)
		}
		return false, false
	}

	if stopped, _ := start_node(h, r, doc, root_node, &regs, &stack_slice, &stack_heap, &stack_n); stopped {
		return !h.failed && h.fatal == .None && !h.need_reread
	}

	for stack_n > 0 {
		top := &stack_slice[stack_n - 1]
		cur_doc := top.doc
		cur_r := tape.Reader{doc = cur_doc}
		if top.is_object {
			if len(top.grouped) > 0 || h.dups == .Group {
				if top.grouped_pos < len(top.grouped) {
					gb := top.grouped[top.grouped_pos]
					top.grouped_pos += 1
					act: hook.Action
					regs, act = checker_step(h, regs, {lo = gb.kt.lo, n = gb.kt.n, kind = gb.kt.kind, role = .Key, spelling = gb.kt.spelling})
					if act == .Stop || h.fatal != .None { return false }
					if act == .Skip { continue }
					as_array := len(gb.vals) >= 2
					if !as_array && len(gb.vals) == 1 {
						if h.sp > 0 && h.frames[h.sp - 1].is_factored {
							as_array = fm_collects_markup(h, factored_at(h, h.nf - 1).active_member)
						} else if regs.b != 0 && regs.b != u64(uintptr(&DEAD_RECORD)) {
							as_array = collects_markup_any(h, (^Record)(uintptr(regs.b) - size_of(Record)))
						}
					}
					if as_array {
						synth, sok := build_synthetic_array_doc(h, cur_doc, gb.vals)
						if !sok { return false }
						stopped, adopted := start_node(h, tape.Reader{doc = synth}, synth, 0, &regs, &stack_slice, &stack_heap, &stack_n, owns_doc = true)
						if !adopted { free_synthetic_doc(h, synth) }
						if stopped { return false }
					} else if len(gb.vals) == 1 {
						if stopped, _ := start_node(h, cur_r, cur_doc, gb.vals[0], &regs, &stack_slice, &stack_heap, &stack_n); stopped {
							return false
						}
					}
					continue
				}
			} else if kn, vn, cp := tape.next_child(cur_r, &top.iter, h.dups); cp == .Found {
				kt := tape.cell_key(cur_r, top.iter) if (kn == tape.NO_NODE && top.iter.keys_n != 0) else cur_doc.nodes[kn]
				act: hook.Action
				regs, act = checker_step(h, regs, {lo = kt.lo, n = kt.n, kind = kt.kind, role = .Key, spelling = kt.spelling})
				if act == .Stop || h.fatal != .None { return false }
				if act == .Skip { continue }
				if stopped, _ := start_node(h, cur_r, cur_doc, vn, &regs, &stack_slice, &stack_heap, &stack_n); stopped {
					return false
				}
				continue
			}
		} else if _, ch, cp := tape.next_child(cur_r, &top.iter); cp == .Found {
			if stopped, _ := start_node(h, cur_r, cur_doc, ch, &regs, &stack_slice, &stack_heap, &stack_n); stopped {
				return false
			}
			continue
		}
		stack_n -= 1
		closed := stack_slice[stack_n]
		if len(closed.grouped) > 0 { free_grouped(h, closed.grouped) }
		tape.destroy_children(&closed.iter)
		saved_parent_b := h.frames[h.sp - 1].parent_b if h.sp > 0 else regs.b
		act: hook.Action
		regs, act = checker_step(h, regs, {lo = closed.doc.nodes[closed.node].lo, kind = .End, role = .Value})
		if h.reread_runs && closed.open_factored && closed.factored_rec != nil {
			h.reread_runs, h.need_reread = false, false
			saved_nf := h.no_factor
			h.no_factor = true
			ok := eval_held_node(h, closed.doc, closed.node, closed.factored_rec, closed.doc.nodes[closed.node].lo)
			h.no_factor = saved_nf
			if closed.owns_doc { free_synthetic_doc(h, closed.doc) }
			if h.fatal != .None { return false }
			if !ok { h.failed = true }
			regs = after_value(h, {regs.a, saved_parent_b, regs.c})
			continue
		}
		if closed.owns_doc { free_synthetic_doc(h, closed.doc) }
		if act == .Stop || h.fatal != .None { return false }
	}
	return !h.failed && h.fatal == .None && !h.need_reread
}

// ============================================================================
// Public `check_document`, `check_document_node`, and `check_stream`
// ============================================================================

@(require_results)
check_document :: proc(doc: ^tape.Document, plan: ^Plan, opts := Options{}, sink: ^Sink = nil, allocator := context.allocator) -> Result {
	return check_document_node(doc, tape.ROOT, plan, opts, sink, allocator)
}

@(require_results)
check_document_node :: proc(doc: ^tape.Document, node: tape.Node_Index, plan: ^Plan, opts := Options{}, sink: ^Sink = nil, allocator := context.allocator) -> Result {
	if doc == nil || plan == nil || len(plan.records) == 0 {
		return {valid = false, err = {kind = .Bad_Option, keyword = "plan"}}
	}
	if doc.partial != nil {
		return {valid = false, err = {kind = .Unsupported, keyword = "partial"}}
	}
	if len(doc.nodes) == 0 || node == tape.NO_NODE || int(node) >= len(doc.nodes) {
		return {valid = false, err = {kind = .Walk}}
	}

	t_opts := tape.Options{budget = opts.budget, scratch = opts.scratch}
	rb: hook.Read_Budget
	local_mb: hook.Memory_Budget
	scratch: runtime.Allocator
	mem_b: ^hook.Memory_Budget
	if opts.budget.memory > 0 {
		out_alloc := hook.read_budget(untracked_ptr(&rb), t_opts, allocator)
		scratch = hook.scratch(t_opts, out_alloc, untracked_ptr(&local_mb))
		mem_b = untracked_ptr(&rb.main)
	} else {
		scratch = opts.scratch if opts.scratch.procedure != nil else allocator
	}

	h: Checker = ---
	memo: hook.Expected_Memo = ---
	ctx := context
	_ = checker_start(&h, plan, doc.src, doc.format, opts, sink, &memo, allocator, scratch, mem_b, &ctx)
	h.xml_ext = doc.ext
	from := len(sink.entries) if sink != nil else 0
	defer checker_cleanup(&h)

	ok := walk_document_node(&h, doc, node, &plan.records[0])
	if !ok && h.need_reread && !h.reread_runs && h.fatal == .None {
		sink_restore(sink, {count = from})
		checker_cleanup(&h)
		_ = checker_start(&h, plan, doc.src, doc.format, opts, sink, &memo, allocator, scratch, mem_b, &ctx)
		h.xml_ext, h.no_factor, h.judge_dups = doc.ext, true, true
		ok = walk_document_node(&h, doc, node, &plan.records[0])
	}
	if sink != nil { order_entries(sink, from) }
	return finish_result(&h, nil, is_mem_refused(opts.budget.memory, &rb), allocator)
}

@(require_results)
check_stream :: proc(
	src: []u8,
	plan: ^Plan,
	format: ^tape.Format,
	opts: Options,
	walk_opts: tape.Options,
	sink: ^Sink,
	allocator: runtime.Allocator,
	$H: typeid,
	$walk: proc "contextless" (src: []u8, opts: tape.Options, h: ^H, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool),
	build_last: proc(src: []u8, opts: tape.Options, allocator: runtime.Allocator) -> (tape.Document, tape.Error) = nil,
) -> Result {
	if plan == nil || len(plan.records) == 0 {
		return {valid = false, err = {kind = .Bad_Option, keyword = "plan"}}
	}

	t_opts := walk_opts
	if opts.budget.depth > 0 { t_opts.budget.depth = opts.budget.depth }
	if opts.budget.nodes > 0 { t_opts.budget.nodes = opts.budget.nodes }
	if opts.budget.memory > 0 { t_opts.budget.memory = opts.budget.memory }
	if opts.budget.steps > 0 { t_opts.budget.steps = opts.budget.steps }
	if opts.scratch.procedure != nil { t_opts.scratch = opts.scratch }

	rb: hook.Read_Budget = ---
	local_mb: hook.Memory_Budget = ---
	scratch: runtime.Allocator
	mem_b: ^hook.Memory_Budget
	if t_opts.budget.memory > 0 {
		rb, local_mb = {}, {}
		out_alloc := hook.read_budget(untracked_ptr(&rb), t_opts, allocator)
		scratch = hook.scratch(t_opts, out_alloc, untracked_ptr(&local_mb))
		mem_b = untracked_ptr(&rb.main)
	} else {
		scratch = t_opts.scratch if t_opts.scratch.procedure != nil else allocator
	}

	from := len(sink.entries) if sink != nil else 0
	h: H = ---
	memo: hook.Expected_Memo = ---
	ctx := context
	chk := checker_ptr(&h)
	when H == Refusing_Checker {
		open_buf: [64]Open_Key = ---
		h.open_keys = {}
		defer open_keys_cleanup(&h.open_keys)
	}
	defer checker_cleanup(chk)

	Pass_Mode :: enum u8 { Factored, Runs, First_Dups }
	mode := Pass_Mode.Factored
	for {
		if mode != .Factored {
			sink_restore(sink, {count = from})
			when H == Refusing_Checker {
				open_keys_cleanup(&h.open_keys)
			}
			checker_cleanup(chk)
		}
		regs := checker_start(chk, plan, src, format, opts, sink, &memo, allocator, scratch, mem_b, &ctx)
		switch mode {
		case .Factored:   install_subwalk(chk, format, t_opts.pieces == nil, H, walk)
		case .Runs:       chk.no_factor = true
		case .First_Dups: chk.no_factor, chk.judge_dups = true, true
		}
		load_xml_ext(chk, src, format, scratch)
		when H == Refusing_Checker {
			open_keys_start(&h.open_keys, open_buf[:], src, format, chk.xml_ext, scratch, &ctx)
		}
		_, werr, _ := walk(src, t_opts, &h, &regs, scratch, &ctx)
		when H == Refusing_Checker {
			settle_refusing_keys(&h, chk)
		}
		if mode == .Factored && werr == nil && chk.fatal == .None && !chk.need_reread && !chk.dup_hit && !chk.failed && (sink == nil || len(sink.entries) == from) {
			return {valid = true, allocator = allocator}
		}
		if werr != nil {
			if mode == .Factored {
				if _, is_ex := werr.(tape.Exceeded); is_ex { chk.fatal = .Exceeded }
			}
			return finish_result(chk, hook.memory_budget_error(&rb.main, werr) if t_opts.budget.memory > 0 else werr, is_mem_refused(t_opts.budget.memory, &rb), allocator)
		}
		if chk.fatal != .None {
			return finish_result(chk, nil, is_mem_refused(t_opts.budget.memory, &rb), allocator)
		}
		if mode != .First_Dups && chk.dup_hit && chk.dups == .Refuse {
			return fail_refuse_dup(chk, plan, sink, from, is_mem_refused(t_opts.budget.memory, &rb), allocator)
		}
		if !chk.need_reread { break }
		if mode == .Factored && chk.reread_runs {
			mode = .Runs
			continue
		}
		if !chk.reread_runs {
			if chk.dups == .First && mode != .First_Dups {
				mode = .First_Dups
				continue
			}
			if chk.dups != .First && build_last != nil {
				sink_restore(sink, {count = from})
				b_opts := t_opts
				b_opts.dups = opts.dups if opts.dups != .Default else (format.dups if format != nil else .Last)
				rem_opts := opts
				if t_opts.budget.steps > 0 {
					if chk.steps_used >= t_opts.budget.steps {
						chk.fatal = .Exceeded
						return finish_result(chk, nil, false, allocator)
					}
					rem := t_opts.budget.steps - chk.steps_used
					b_opts.budget.steps, rem_opts.budget.steps = rem, rem
				}
				if t_opts.budget.memory > 0 {
					rem_mem := hook.memory_budget_left(&rb.main)
					if rem_mem == 0 {
						chk.fatal = .Exceeded
						return finish_result(chk, nil, true, allocator)
					}
					b_opts.budget.memory, rem_opts.budget.memory = rem_mem, rem_mem
				}
				doc, berr := build_last(src, b_opts, scratch)
				if berr != nil {
					return finish_result(chk, hook.memory_budget_error(&rb.main, berr) if t_opts.budget.memory > 0 else berr, is_mem_refused(t_opts.budget.memory, &rb), allocator)
				}
				defer tape.destroy(&doc)
				if t_opts.budget.memory > 0 {
					rem_opts.budget.memory = hook.memory_budget_left(&rb.main)
					if rem_opts.budget.memory == 0 {
						chk.fatal = .Exceeded
						return finish_result(chk, nil, true, allocator)
					}
				}
				return check_document(&doc, plan, rem_opts, sink, allocator)
			}
		}
		break
	}
	if sink != nil { order_entries(sink, from) }
	return finish_result(chk, nil, is_mem_refused(t_opts.budget.memory, &rb), allocator)
}

@(private = "file")
install_subwalk :: #force_inline proc(
	chk: ^Checker,
	format: ^tape.Format,
	allow_rewalk: bool,
	$H: typeid,
	$walk: proc "contextless" (src: []u8, opts: tape.Options, h: ^H, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool),
) {
	if format == nil || !allow_rewalk || .Rewalk not_in format.caps || format.id < tape.FORMAT_ID_JSON || format.id >= tape.FORMAT_ID_JSON + 3 {
		return
	}
	when H == Checker {
		chk.subwalk_fn = proc(sub_src: []u8, w_opts: tape.Options, sub: ^Checker, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			return walk(sub_src, w_opts, sub, regs, a, ctx)
		}
	} else {
		chk.subwalk_fn = proc(sub_src: []u8, w_opts: tape.Options, sub: ^Checker, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			rc: Refusing_Checker = ---
			rc.checker = sub^
			if !sub.frames_heap { rc.checker.frames = rc.checker.frames_buf[:] }
			rc.checker.trackers.allocator, rc.checker.ctx = sub.scratch, ctx
			open_buf: [64]Open_Key = ---
			rc.open_keys = {}
			open_keys_start(&rc.open_keys, open_buf[:], sub_src, rc.checker.format, rc.checker.xml_ext, sub.scratch, ctx)
			defer open_keys_cleanup(&rc.open_keys)
			n, werr, tol := walk(sub_src, w_opts, &rc, regs, a, ctx)
			settle_refusing_keys(&rc, &rc.checker)
			sub^ = rc.checker
			sub.ctx = ctx
			if !rc.checker.frames_heap { sub.frames = sub.frames_buf[:] }
			return n, werr, tol
		}
	}
}

// Unified local replay of a failed factored container from either an in-memory `doc` (`doc != nil`) or a JSON stream slice.
@(private = "file")
replay_factored :: #force_no_inline proc(h: ^Checker, owner, inst_owner, orig_owner: ^Record, doc: ^tape.Document, node: tape.Node_Index, open_at, close_end: u64) -> bool {
	is_doc := doc != nil
	if is_doc {
		max_depth := int(h.budget.depth) if h.budget.depth > 0 else int(tape.DEFAULT_DEPTH)
		if h.sp + h.nest_depth >= max_depth {
			h.fatal = .Exceeded
			return false
		}
	} else if close_end > u64(len(h.src)) || close_end <= open_at || h.subwalk_fn == nil {
		return false
	}
	mark := sink_mark(h.sink)
	sub_src := doc.src if is_doc else h.src[open_at:close_end]
	sub_fmt := doc.format if is_doc else h.format
	sub_ext := (doc.ext if doc.ext != nil else h.xml_ext) if is_doc else h.xml_ext

	sub: Checker = ---
	memo: hook.Expected_Memo = ---
	ctx := h.ctx^
	sub_checker_begin(h, &sub, sub_src, sub_fmt, sub_ext, h.sink, &memo, &ctx, false, true, orig_owner, inst_owner, nil, h.sp + h.nest_depth, h.at_bias + (0 if is_doc else open_at))
	defer sub_checker_end(h, &sub, false, false)

	if is_doc {
		_ = walk_document_node(&sub, doc, node, owner)
	} else {
		t_opts := tape.Options{dups = h.dups, scratch = h.scratch}
		if h.budget.depth > 0 {
			if used := h.sp + h.nest_depth; used >= int(h.budget.depth) {
				h.fatal = .Exceeded
				sink_restore(h.sink, mark)
				return false
			} else {
				t_opts.budget.depth = u32(int(h.budget.depth) - used)
			}
		}
		if h.budget.steps > 0 {
			if h.steps_used >= h.budget.steps {
				h.fatal = .Exceeded
				sink_restore(h.sink, mark)
				return false
			}
			t_opts.budget.steps = h.budget.steps - h.steps_used
		}
		sub_regs := hook.Regs{b = u64(uintptr(&h.plan.solo[2 * int(owner.meta) + 1]))}
		_, werr, _ := h.subwalk_fn(sub_src, t_opts, &sub, &sub_regs, h.scratch, &ctx)
		if werr != nil {
			if h.fatal == .None {
				_, is_ex := werr.(tape.Exceeded)
				h.fatal = .Exceeded if is_ex else .Walk
			}
			sink_restore(h.sink, mark)
			return false
		}
	}
	if sub.fatal != .None {
		h.fatal = sub.fatal
		sink_restore(h.sink, mark)
		return false
	}
	if sub.need_reread {
		sink_restore(h.sink, mark)
		h.need_reread, h.reread_runs = true, false
		return false
	}
	if sub.first_recorded && !h.first_recorded && !h.quiet { copy_first_error(h, &sub) }
	return h.sink != nil || h.first_recorded
}

@(private = "file")
load_xml_ext :: proc(chk: ^Checker, src: []u8, format: ^tape.Format, scratch: runtime.Allocator) {
	if format != nil && format.text_ext != nil {
		if ext, ok := format.text_ext(src, scratch); ok && ext != nil {
			chk.xml_ext, chk.xml_ext_owned = ext, true
		}
	}
}

@(private = "file")
settle_refusing_keys :: proc(h: ^Refusing_Checker, chk: ^Checker) {
	open_keys_end(&h.open_keys)
	if h.open_keys.oom && chk.fatal == .None { chk.fatal = .No_Memory }
	if h.open_keys.repeat != NO_REPEAT { chk.dup_hit, chk.dup_at = true, h.open_keys.repeat }
}

@(private = "file")
is_mem_refused :: proc "contextless" (limit: u64, rb: ^hook.Read_Budget) -> bool {
	return limit > 0 && (rb.main.refused || (rb.main.peer != nil && rb.main.peer.refused))
}

@(private = "file")
fail_refuse_dup :: proc(chk: ^Checker, plan: ^Plan, sink: ^Sink, from: int, mem_refused: bool, allocator: runtime.Allocator) -> Result {
	chk.quiet = false
	emit_or_first(chk, .Duplicate_Key, chk.dup_at, "duplicateKey", "", &plan.records[0])
	if sink != nil { order_entries(sink, from) }
	chk.failed = true
	return finish_result(chk, nil, mem_refused, allocator)
}

@(private = "file")
untracked_ptr :: #force_inline proc "contextless" (p: ^$T) -> ^T {
	return (^T)(uintptr(p))
}

@(private = "file")
checker_ptr :: #force_inline proc "contextless" (h: ^$H) -> ^Checker {
	when H == Checker {
		return h
	} else {
		return &h.checker
	}
}

@(private = "file")
destroy_first_arena :: proc(h: ^Checker) {
	if h.first_arena != nil {
		mem.dynamic_arena_destroy(h.first_arena)
		free(h.first_arena, h.allocator)
		h.first_arena = nil
	}
}

@(private)
charge_output_budget :: proc(h: ^Checker, bytes: u64) -> bool {
	if h.mem_budget == nil || bytes == 0 { return true }
	if bytes > hook.memory_budget_left(h.mem_budget) {
		h.mem_budget.refused = true
		h.fatal = .Exceeded
		return false
	}
	h.mem_budget.held += bytes
	return true
}

@(private = "file")
finish_result :: proc(h: ^Checker, err: tape.Error, mem_refused: bool, allocator: runtime.Allocator) -> Result {
	if err != nil {
		destroy_first_arena(h)
		_, is_ex := err.(tape.Exceeded)
		_, is_oom := err.(runtime.Allocator_Error)
		k := Error_Kind.Exceeded if is_ex else Error_Kind.No_Memory if is_oom else Error_Kind.Walk
		return {valid = false, err = {kind = k, walk_err = err}, walk_err = err, allocator = allocator}
	}
	if h.fatal != .None {
		destroy_first_arena(h)
		k := Error_Kind.Exceeded if (h.fatal == .No_Memory && mem_refused) else h.fatal
		return {valid = false, err = {kind = k}, allocator = allocator}
	}
	if !h.failed && !h.need_reread && (h.sink == nil || len(h.sink.entries) == h.sink_from) {
		destroy_first_arena(h)
		return {valid = true, allocator = allocator}
	}
	if h.sink != nil {
		destroy_first_arena(h)
		first := h.sink.entries[h.sink_from] if len(h.sink.entries) > h.sink_from else Check_Error{kind = .Unsupported if h.need_reread else .Not_Allowed}
		return {valid = false, err = first, allocator = allocator}
	}
	res := Result{
		valid = false,
		err = h.first_err if h.first_recorded else Check_Error{kind = .Unsupported if h.need_reread else .Not_Allowed},
		allocator = allocator,
		arena = h.first_arena,
	}
	h.first_arena = nil
	return res
}

// ============================================================================
// Frame stack, seen bitmasks, trackers, and unified error recording
// ============================================================================

@(private)
frame_push_slot :: #force_inline proc "contextless" (h: ^Checker) -> ^Frame #no_bounds_check {
	if h.sp == len(h.frames) && !frame_grow(h) { return nil }
	f := &h.frames[h.sp]
	h.sp += 1
	return f
}

@(private = "file", cold)
frame_grow :: #force_no_inline proc "contextless" (h: ^Checker) -> bool {
	context = h.ctx^
	grown, err := make([]Frame, max(64, len(h.frames) * 2), h.scratch)
	if err != nil {
		h.fatal = .No_Memory
		return false
	}
	copy(grown, h.frames[:h.sp])
	if h.frames_heap { delete(h.frames, h.scratch) }
	h.frames, h.frames_heap = grown, true
	return true
}

@(private)
frame_mark_seen :: #force_inline proc "contextless" (h: ^Checker, f: ^Frame, idx: i32) -> (was_seen: bool, ok: bool) #no_bounds_check {
	if f.owner.members_u16 <= 64 {
		bit := u64(1) << uint(idx)
		if (f.seen_mask & bit) != 0 { return true, true }
		f.seen_mask |= bit
		return false, true
	}
	return frame_mark_seen_wide(h, f, idx)
}

@(private = "file", cold)
frame_mark_seen_wide :: #force_no_inline proc "contextless" (h: ^Checker, f: ^Frame, idx: i32) -> (was_seen: bool, ok: bool) #no_bounds_check {
	context = h.ctx^
	if len(f.seen_wide) == 0 {
		buf, err := make([]u64, (int(h.plan.meta[f.owner.meta].members) + 63) / 64, h.scratch)
		if err != nil {
			h.fatal = .No_Memory
			return false, false
		}
		f.seen_wide = buf
	}
	w, bit := idx >> 6, u64(1) << uint(idx & 63)
	if (f.seen_wide[w] & bit) != 0 { return true, true }
	f.seen_wide[w] |= bit
	return false, true
}

@(private)
frame_is_seen :: #force_inline proc "contextless" (f: ^Frame, idx: i32) -> bool #no_bounds_check {
	if idx < 0 { return false }
	if len(f.seen_wide) == 0 { return idx < 64 && (f.seen_mask & (u64(1) << uint(idx))) != 0 }
	w := int(idx >> 6)
	return w < len(f.seen_wide) && (f.seen_wide[w] & (u64(1) << uint(idx & 63))) != 0
}

@(private)
tracker_at :: #force_inline proc "contextless" (h: ^Checker, idx: int) -> ^Key_Tracker #no_bounds_check {
	return &h.tracker0 if idx == 0 else &h.trackers[idx - 1]
}

@(private = "file")
reset_tracker :: proc(tr: ^Key_Tracker, scratch: runtime.Allocator) {
	tr.small_n = 0
	for nm in tr.owned {
		delete(nm, scratch)
	}
	clear(&tr.owned)
	clear(&tr.names)
	clear(&tr.table)
}

@(private)
open_tracker :: proc(h: ^Checker) -> int {
	idx := h.tracked
	if idx == 0 {
		if !h.tracker0_used {
			h.tracker0 = {}
			h.tracker0.names.allocator, h.tracker0.owned.allocator, h.tracker0.table.allocator = h.scratch, h.scratch, h.scratch
			h.tracker0_used = true
		} else {
			reset_tracker(&h.tracker0, h.scratch)
		}
		h.tracked = 1
		return 0
	}
	if heap_idx := idx - 1; heap_idx == len(h.trackers) {
		tr: Key_Tracker
		tr.names.allocator, tr.owned.allocator, tr.table.allocator = h.scratch, h.scratch, h.scratch
		if _, err := append(&h.trackers, tr); err != nil { return -1 }
	} else {
		reset_tracker(&h.trackers[heap_idx], h.scratch)
	}
	h.tracked += 1
	return idx
}

@(private)
close_tracker :: proc(h: ^Checker) {
	if h.tracked > 0 { h.tracked -= 1 }
}

@(private)
tracker_has :: proc(tr: ^Key_Tracker, name: string) -> bool #no_bounds_check {
	if len(tr.names) == 0 {
		for i in 0 ..< tr.small_n {
			if tr.small[i] == name { return true }
		}
		return false
	}
	_, ok := tr.table[name]
	return ok
}

@(private)
tracker_add :: proc(h: ^Checker, tr: ^Key_Tracker, name: string, need_clone: bool) -> bool #no_bounds_check {
	stored := name
	if need_clone {
		cp, err := strings.clone(name, h.scratch)
		if err != nil { return false }
		if _, oerr := append(&tr.owned, cp); oerr != nil {
			delete(cp, h.scratch)
			return false
		}
		stored = cp
	}
	if len(tr.names) == 0 && tr.small_n < len(tr.small) {
		tr.small[tr.small_n] = stored
		tr.small_n += 1
		return true
	}
	if len(tr.names) == 0 {
		if _, rerr := append(&tr.names, ..tr.small[:tr.small_n]); rerr != nil { return false }
		for nm, i in tr.names {
			tr.table[nm] = i
		}
	}
	if _, aerr := append(&tr.names, stored); aerr != nil { return false }
	tr.table[stored] = len(tr.names) - 1
	return true
}

@(private)
resolve_err_owner :: #force_inline proc "contextless" (h: ^Checker, owner: ^Record, parent_b: u64, is_choice: bool) -> (err_owner: ^Record, alt_site: []tape.Step) #no_bounds_check {
	err_owner = owner
	if !is_choice && parent_b != 0 && parent_b != u64(uintptr(&DEAD_RECORD)) {
		orig := (^Record)(uintptr(parent_b) - size_of(Record))
		if orig.meta != owner.meta { return orig, h.plan.uses[owner.meta].site }
	}
	return err_owner, nil
}

@(private)
append_current_instance_path :: proc(h: ^Checker, out: ^[dynamic]tape.Step, cur_owner: ^Record = nil) {
	if h.parent != nil {
		append_current_instance_path(h.parent, out, h.parent_inst_owner if h.parent_inst_owner != nil else h.parent_owner)
		if len(h.parent_extra) > 0 { append(out, ..h.parent_extra) }
	}
	for i in 0 ..< h.sp {
		fr := &h.frames[i]
		if fr.is_object {
			if fr.in_seq {
				rec := cur_owner
				if i + 1 < h.sp {
					pb := h.frames[i + 1].parent_b
					rec = (^Record)(uintptr(pb) - size_of(Record)) if (pb != 0 && pb != u64(uintptr(&DEAD_RECORD))) else nil
				}
				if rec != nil {
					nm := h.plan.meta[rec.meta].name
					is_member := len(nm) > 0
					if !is_member && fr.owner != nil {
						om := &h.plan.meta[fr.owner.meta]
						rec_idx := i32((uintptr(rec) - uintptr(raw_data(h.plan.records))) / size_of(Record))
						is_member = om.members > 0 && rec_idx >= om.block && rec_idx < om.block + om.members
					}
					if is_member { append(out, tape.Name(nm)) }
				}
			} else if fr.has_key {
				append(out, tape.Name(fr.key_name))
			}
		} else {
			append(out, tape.Index(int(fr.count) - 1 if fr.count > 0 else 0))
		}
	}
}

@(private)
append_current_keyword_path :: proc(h: ^Checker, out: ^[dynamic]tape.Step, owner: ^Record, alt_site: []tape.Step = nil, replace_top := false) {
	if h.parent != nil { append_current_keyword_path(h.parent, out, h.parent_owner) }
	limit := h.sp - 1 if (replace_top && h.sp > 0) else h.sp
	for i in 0 ..< limit {
		fr := &h.frames[i]
		if fr.owner != nil {
			if !fr.is_choice && !fr.is_group_array && fr.parent_b != 0 && fr.parent_b != u64(uintptr(&DEAD_RECORD)) {
				if orig := (^Record)(uintptr(fr.parent_b) - size_of(Record)); orig.meta != fr.owner.meta {
					append(out, ..h.plan.uses[orig.meta].site)
				}
			}
			append(out, ..h.plan.uses[fr.owner.meta].site)
		}
	}
	if owner != nil && !replace_top && (h.sp == 0 || h.frames[h.sp - 1].owner != owner) {
		append(out, ..h.plan.uses[owner.meta].site)
	}
	if len(alt_site) > 0 { append(out, ..alt_site) }
}

// Unified error-entry emitter shared by both `Checker` and `Factor` error paths.
@(private)
emit_check_error_steps :: proc(
	h: ^Checker,
	target: ^Sink,
	kind: Error_Kind,
	at: u64,
	keyword, expected: string,
	inst_steps, kw_steps: []tape.Step,
	buffering: bool,
	replace_top := false,
) {
	if target == nil && h.first_recorded { return }
	if !buffering {
		est := u64(size_of(Check_Error)) + u64(len(expected) + len(keyword)) + u64(len(inst_steps) + len(kw_steps)) * u64(size_of(tape.Step) + 16)
		if !charge_output_budget(h, est) {
			if target != nil { target.oom = true }
			return
		}
	}
	arena: runtime.Allocator
	if target == nil {
		a, aok := checker_first_arena_ensure(h, charge_budget = !buffering)
		if !aok { return }
		arena = a
	} else {
		arena = sink_ensure(target, h.scratch if buffering else h.allocator)
	}
	inst_ptr, ierr := format_pointer(inst_steps, arena)
	kw_ptr, kerr := format_pointer(kw_steps, arena)
	path_cp, perr := clone_steps(inst_steps, arena)
	kw_cp, kperr := clone_steps(kw_steps, arena)
	exp_cp, kw_str: string
	eerr, kserr: runtime.Allocator_Error
	if len(expected) > 0 { exp_cp, eerr = strings.clone(expected, arena) }
	if len(keyword) > 0 { kw_str, kserr = strings.clone(keyword, arena) }
	if ierr != nil || kerr != nil || perr != nil || kperr != nil || eerr != nil || kserr != nil {
		if target != nil { target.oom = true }
		h.fatal = .No_Memory
		return
	}
	entry := Check_Error{
		kind = kind, at = at + h.at_bias,
		instance_location = inst_ptr, keyword_location = kw_ptr,
		keyword = kw_str, expected = exp_cp, path = path_cp, keyword_path = kw_cp,
	}
	if target == nil {
		h.first_err, h.first_recorded = entry, true
		return
	}
	if _, err := append(&target.entries, entry); err != nil {
		target.oom = true
		h.fatal = .No_Memory
		return
	}
	if buffering {
		cfo_h := h
		for cfo_h != nil && cfo_h.choice_sink_fo < 0 {
			cfo_h = cfo_h.parent
		}
		if cfo_h != nil && int(cfo_h.choice_sink_fo) < cfo_h.nf {
			cfo := factored_at(cfo_h, int(cfo_h.choice_sink_fo))
			for len(cfo.choice_no_member) < len(cfo.choice_sink.entries) - 1 {
				append(&cfo.choice_no_member, false)
			}
			no_mem := replace_top && ((cfo_h == h && h.sp == cfo.parent_sp + 2) || (cfo_h != h && h.parent == cfo_h && h.sp == 1 && h.parent_owner != nil))
			append(&cfo.choice_no_member, no_mem)
		}
	}
}

@(private = "file")
record_error_to :: proc(h: ^Checker, target: ^Sink, kind: Error_Kind, at: u64, keyword, expected: string, owner: ^Record, extra_kw := "", alt_site: []tape.Step = nil, replace_top := false) {
	inst_steps := make([dynamic]tape.Step, h.scratch)
	kw_steps := make([dynamic]tape.Step, h.scratch)
	defer {
		delete(inst_steps)
		delete(kw_steps)
	}
	append_current_instance_path(h, &inst_steps, owner)
	append_current_keyword_path(h, &kw_steps, owner, alt_site, replace_top)
	if len(extra_kw) > 0 {
		if _, err := append(&kw_steps, tape.Name(extra_kw)); err != nil {
			h.fatal = .No_Memory
			if target != nil { target.oom = true }
			return
		}
	}
	if len(keyword) > 0 {
		if _, err := append(&kw_steps, tape.Name(keyword)); err != nil {
			h.fatal = .No_Memory
			if target != nil { target.oom = true }
			return
		}
	}
	emit_check_error_steps(h, target, kind, at, keyword, expected, inst_steps[:], kw_steps[:], h.buffering_choice, replace_top)
}

@(private)
emit_or_first :: proc(h: ^Checker, kind: Error_Kind, at: u64, keyword, expected: string, owner: ^Record, extra_kw := "", alt_site: []tape.Step = nil, replace_top := false) {
	if h.sink != nil && !h.quiet {
		record_failure(h, kind, at, keyword, expected, owner, extra_kw, alt_site, replace_top)
	} else {
		record_first_failure(h, kind, at, keyword, expected, owner, extra_kw, alt_site, replace_top)
	}
}

@(private)
record_failure :: proc(h: ^Checker, kind: Error_Kind, at: u64, keyword, expected: string, owner: ^Record, extra_kw := "", alt_site: []tape.Step = nil, replace_top := false) {
	if h.sink == nil {
		record_first_failure(h, kind, at, keyword, expected, owner, extra_kw, alt_site, replace_top)
		return
	}
	record_error_to(h, h.sink, kind, at, keyword, expected, owner, extra_kw, alt_site, replace_top)
}

@(private)
checker_first_arena_ensure :: proc(h: ^Checker, charge_budget := true) -> (runtime.Allocator, bool) {
	if h.first_arena == nil {
		if charge_budget && !charge_output_budget(h, u64(size_of(mem.Dynamic_Arena))) {
			return {}, false
		}
		a, err := new(mem.Dynamic_Arena, h.allocator)
		if err != nil {
			h.fatal = .No_Memory
			return {}, false
		}
		mem.dynamic_arena_init(a, h.allocator, h.allocator, block_size = 512)
		h.first_arena = a
	}
	return mem.dynamic_arena_allocator(h.first_arena), true
}

@(private)
record_first_failure :: proc(h: ^Checker, kind: Error_Kind, at: u64, keyword, expected: string, owner: ^Record, extra_kw := "", alt_site: []tape.Step = nil, replace_top := false) {
	if h.first_recorded || h.quiet { return }
	record_error_to(h, nil, kind, at, keyword, expected, owner, extra_kw, alt_site, replace_top)
}

@(private = "file")
copy_first_error :: proc(dst, src: ^Checker) {
	if dst.first_recorded || !src.first_recorded { return }
	dst.first_err, dst.first_arena, dst.first_recorded = src.first_err, src.first_arena, true
	src.first_arena = nil
}

// ============================================================================
// `Open_Keys` for `.Refuse` duplicate-key detection
// ============================================================================

@(private)
open_keys_start :: proc(k: ^Open_Keys, room: []Open_Key, src: []u8, format: ^tape.Format, xml_ext: ^tape.Doc_Ext, allocator: runtime.Allocator, ctx: ^runtime.Context) {
	k^ = {room = room, repeat = NO_REPEAT, src = src, format = format, xml_ext = xml_ext, allocator = allocator, ctx = ctx}
}

@(private)
open_keys_cleanup :: proc(k: ^Open_Keys) {
	if k.heap {
		delete(k.room, k.allocator)
		k.heap = false
	}
}

@(private)
open_keys_token :: #force_inline proc "contextless" (k: ^Open_Keys, t: tape.Token) #no_bounds_check {
	if t.role == .Key {
		if k.n == len(k.room) && !open_keys_grow(k) {
			k.oom = true
			return
		}
		k.room[k.n] = {key = t, depth = k.depth}
		k.n += 1
	} else if t.role == .Value {
		#partial switch t.kind {
		case .Object, .Array:
			k.depth += 1
		case .End:
			if k.n > 0 && k.room[k.n - 1].depth == k.depth { open_keys_close(k) }
			k.depth -= 1
		}
	}
}

@(private)
open_keys_end :: proc "contextless" (k: ^Open_Keys) {
	for k.n > 0 {
		k.depth = k.room[k.n - 1].depth
		open_keys_close(k)
	}
}

@(cold, private)
open_keys_grow :: #force_no_inline proc "contextless" (k: ^Open_Keys) -> bool {
	context = k.ctx^
	wide, err := make([]Open_Key, max(64, 2 * len(k.room)), k.allocator)
	if err != nil { return false }
	copy(wide, k.room[:k.n])
	if k.heap { delete(k.room, k.allocator) }
	k.room, k.heap = wide, true
	return true
}

@(private)
open_keys_close :: #force_no_inline proc "contextless" (k: ^Open_Keys) #no_bounds_check {
	from := k.n - 1
	for from > 0 && k.room[from - 1].depth == k.depth {
		from -= 1
	}
	keys := k.room[from:k.n]
	k.n = from
	is_binary := k.format != nil && .Binary in k.format.caps
	decoded := false
	for &e in keys {
		decoded ||= e.key.spelling & tape.SPELLING_DECODE != 0 || (is_binary && e.key.kind == .Number)
	}
	if decoded || len(keys) > 12 {
		open_keys_hashed(k, keys, is_binary)
		return
	}
	src := raw_data(k.src)
	for i in 1 ..< len(keys) {
		a := keys[i]
		for j in 0 ..< i {
			if (!is_binary || keys[j].key.kind == a.key.kind) && keys[j].key.n == a.key.n && slice.equal(src[keys[j].key.lo:][:a.key.n], src[a.key.lo:][:a.key.n]) {
				k.repeat = min(k.repeat, a.key.lo)
				return
			}
		}
	}
}

@(private)
open_keys_hashed :: proc "contextless" (k: ^Open_Keys, keys: []Open_Key, is_binary: bool) #no_bounds_check {
	context = k.ctx^
	size := 16
	for size < 2 * len(keys) {
		size <<= 1
	}
	small: [128]u32 = ---
	slots: []u32
	slots_heap := false
	if size <= len(small) {
		slots = small[:size]
	} else {
		fresh, err := make([]u32, size, k.allocator)
		if err != nil {
			k.oom = true
			return
		}
		slots, slots_heap = fresh, true
	}
	defer if slots_heap {
		delete(slots, k.allocator)
	}
	slice.zero(slots)
	mask := u32(size - 1)
	doc := tape.Document{src = k.src, format = k.format, ext = k.xml_ext}
	for &e, i in keys {
		s, s_owned, ok := open_key_text(k, &doc, e.key)
		if !ok {
			k.oom = true
			return
		}
		h_val := tape.text_hash(transmute([]u8)s)
		if is_binary { h_val ~= u32(e.key.kind) * 2654435761 }
		at := h_val & mask
		dup := false
		for ; slots[at] != 0; at = (at + 1) & mask {
			other := keys[slots[at] - 1].key
			if is_binary && other.kind != e.key.kind { continue }
			t, t_owned, tok := open_key_text(k, &doc, other)
			if !tok {
				if s_owned { delete(s, k.allocator) }
				k.oom = true
				return
			}
			same := t == s
			if t_owned { delete(t, k.allocator) }
			if same {
				dup = true
				break
			}
		}
		if s_owned { delete(s, k.allocator) }
		if dup {
			k.repeat = min(k.repeat, e.key.lo)
			return
		}
		slots[at] = u32(i + 1)
	}
}

@(private = "file")
open_key_text :: proc(k: ^Open_Keys, doc: ^tape.Document, t: tape.Token) -> (string, bool, bool) {
	if t.spelling & tape.SPELLING_DECODE == 0 && !(t.kind == .Number && k.format != nil && .Binary in k.format.caps) {
		return string(k.src[t.lo:][:t.n]), false, true
	}
	return doc_token_text(doc, t, k.allocator)
}
