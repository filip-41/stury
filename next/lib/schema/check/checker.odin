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

// Maximum simultaneously nested `Held_Capture`s (streaming held containers).
@(private)
MAX_HELD_CAPTURES :: 16

// One open container frame in `Checker`'s explicit stack.
@(private)
Frame :: struct {
	is_object:     bool,
	is_factored:   bool,
	is_choice:     bool,    // container opened for a single live `Factor_Choice` inside a factored object
	owner:         ^Record,
	parent_b:      u64,
	block_start:   ^Record,
	block_end:     ^Record,
	in_seq:        bool,
	seen_mask:     u64,
	seen_wide:     []u64,
	count:         u64,
	open_at:       u64,
	elem_index:    int,
	member_idx:    i32,
	key_name:      string,
	key_owned:     bool,
	key_at:        u64,
	key_known:     bool,    // true when key matched via `.Expects` or named member
	has_tracker:   bool,
	tracker_idx:   int,
	skip_member:   bool,    // true when `.First` duplicate judge skips this member's value
}

// Tracks seen keys in one open object when detecting/judging duplicate keys.
@(private)
Key_Tracker :: struct {
	sp:    int,
	names: [dynamic]string,
	table: map[string]int,
}

// Streaming validation hook implementing v2 `hook.Protocol({.Skips, .Expects}, ...)`.
Checker :: struct {
	expected:       ^hook.Expected_Memo,
	plan:           ^Plan,
	src:            []u8,
	format:         ^tape.Format,
	xml_ext:        ^tape.Doc_Ext, // optional lazy DTD extension for XML entity decoding
	xml_ext_owned:  bool,
	sink:           ^Sink,
	sink_from:      int,
	allocator:      runtime.Allocator,
	scratch:        runtime.Allocator,
	mem_budget:     ^hook.Memory_Budget,
	budget:         tape.Budget,
	steps_used:     u64,
	nodes_seen:     u64,
	dups:           tape.Duplicates,
	judge_dups:     bool,
	no_factor:      bool,
	quiet:          bool,
	failed:         bool,
	fatal:          Error_Kind,
	need_reread:    bool,
	reread_runs:    bool,
	dup_hit:        bool,
	dup_at:         u64,
	first_err:      Check_Error,
	first_arena:    ^mem.Dynamic_Arena,
	first_recorded: bool,
	frames_buf:     [32]Frame,
	frames:         []Frame,
	frames_heap:    bool,
	sp:             int,
	pool:           ^Pool,
	owns_pool:      bool,
	nf:             int,
	captures:       [MAX_HELD_CAPTURES]Held_Capture,
	capture_depth:  int,
	trackers:       [dynamic]Key_Tracker,
	tracked:        int,
	prefix_path:    []tape.Step, // optional outer instance path when running `subcheck_node`
	prefix_words:   []tape.Step, // optional outer keyword path when running `subcheck_node`
	nest_depth:     int,         // subcheck nesting depth
	ctx:            runtime.Context,
	protocol:       hook.Protocol(CHECKER_CAPS, hook.Unused, hook.Unused, hook.Unused),
}

// Duplicate-key tracking hook used under `dups == .Refuse` (no `.Skips`, no `.Expects`).
Refusing_Checker :: struct {
	checker:   Checker,
	open_keys: Open_Keys,
	protocol:  hook.Protocol({}, hook.Unused, hook.Unused, hook.Unused),
}

// Tracks all keys of open objects under `.Refuse`, even inside skipped subtrees.
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
	ctx:       runtime.Context,
}

@(private)
NO_REPEAT :: max(u64)

@(private, rodata)
DEAD_RECORD := Record{word = NO_KEY, kind = .End}

// Initializes `h` for a streaming or document check.
@(private)
checker_start :: proc(h: ^Checker, plan: ^Plan, src: []u8, format: ^tape.Format, opts: Options, sink: ^Sink, expected: ^hook.Expected_Memo, allocator, scratch: runtime.Allocator, mem_budget: ^hook.Memory_Budget) -> hook.Regs {
	h.ctx = context
	h.expected = expected
	h.plan = plan
	h.src = src
	h.format = format
	h.sink = sink
	h.sink_from = len(sink.entries) if sink != nil else 0
	h.allocator = allocator
	h.scratch = scratch
	h.mem_budget = mem_budget
	h.budget = opts.budget
	h.dups = opts.dups if opts.dups != .Default else (format.dups if format != nil else .Last)
	h.frames = h.frames_buf[:]
	h.sp = 0
	h.dup_at = tape.NO_BYTE
	h.trackers.allocator = scratch
	return {b = u64(uintptr(plan.root))}
}

@(private)
checker_cleanup :: proc(h: ^Checker) {
	for h.capture_depth > 0 {
		capture_abort(h)
	}
	for i in 0 ..< h.sp {
		if h.frames[i].key_owned {
			delete(h.frames[i].key_name, h.scratch)
			h.frames[i].key_owned = false
		}
	}
	if h.frames_heap {
		delete(h.frames, h.scratch)
		h.frames_heap = false
	}
	for &tr in h.trackers {
		for nm in tr.names {
			delete(nm, h.scratch)
		}
		delete(tr.names)
		delete(tr.table)
	}
	delete(h.trackers)
	if h.owns_pool && h.pool != nil {
		pool_destroy(h.pool)
		free(h.pool, h.scratch)
		h.pool = nil
		h.owns_pool = false
	}
	if h.xml_ext_owned && h.xml_ext != nil {
		free(h.xml_ext, h.scratch)
		h.xml_ext = nil
		h.xml_ext_owned = false
	}
	if h.first_arena != nil {
		mem.dynamic_arena_destroy(h.first_arena)
		free(h.first_arena, h.allocator)
		h.first_arena = nil
	}
}

@(private)
checker_scratch :: #force_inline proc "contextless" (h: ^Checker) -> runtime.Allocator {
	return h.scratch
}

@(private)
checker_regex_scratch :: proc(h: ^Checker) -> ^regex.Scratch {
	pool := pool_ensure(h)
	if pool == nil {
		return nil
	}
	if !pool.re_ready {
		sc, err := regex.scratch_make(pool.allocator)
		if err.kind != .None {
			h.fatal = .No_Memory
			return nil
		}
		pool.re_scratch = sc
		pool.re_ready = true
	}
	return &pool.re_scratch
}

@(private)
remaining_steps :: #force_inline proc "contextless" (h: ^Checker) -> u64 {
	if h.budget.steps == 0 {
		return 0
	}
	if h.steps_used >= h.budget.steps {
		return 1
	}
	return h.budget.steps - h.steps_used
}

@(private)
charge_steps :: #force_inline proc "contextless" (h: ^Checker, n: u64) {
	if h.budget.steps == 0 {
		return
	}
	h.steps_used += n
	if h.steps_used > h.budget.steps {
		h.fatal = .Exceeded
	}
}

@(private)
charge_step_one :: #force_inline proc "contextless" (h: ^Checker) -> bool {
	if h.budget.steps == 0 {
		return true
	}
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

// Primary streaming hook called by format walks (`json`, `toml`, `xml`, `dsv`, `cbor`).
checker_hook :: #force_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key {
		return s, .Next
	}
	return checker_step(h, s, t)
}

// Streaming hook under `dups == .Refuse`: checks every key in the document for duplicates in addition to schema checking.
refusing_hook :: #force_inline proc "contextless" (h: ^Refusing_Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key {
		return s, .Next
	}
	k := &h.open_keys
	open_keys_token(k, t)
	if k.oom {
		return s, .Stop
	}
	if k.spent || k.repeat != NO_REPEAT {
		if !k.spent {
			k.spent, k.held = true, s
		}
		return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next
	}
	out, act := checker_step(&h.checker, s, t)
	if h.checker.fatal != .None {
		return out, .Stop
	}
	if act == .Stop {
		k.spent, k.held = true, out
		return {out.a, u64(uintptr(&DEAD_RECORD)), out.c}, .Next
	}
	// Under `.Refuse`, never return `.Skip` or `.Rest` (skipped subtrees may contain duplicate keys).
	if act == .Skip || act == .Rest {
		return out, .Next
	}
	return out, act
}

@(private)
checker_step :: proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx
	// Node budget check.
	if h.budget.nodes > 0 {
		h.nodes_seen += 1
		if h.nodes_seen > u64(h.budget.nodes) {
			h.fatal = .Exceeded
			return s, .Stop
		}
	}

	// If we are currently capturing a held container via `build.Builder`, forward tokens directly to it!
	if h.capture_depth > 0 {
		done, ok := capture_feed(h, t)
		if !ok || h.fatal != .None {
			return s, .Stop
		}
		if done {
			passed := capture_finish(h)
			if h.fatal != .None {
				return s, .Stop
			}
			if !passed {
				if h.nf > 0 {
					// Inside a factored object (`h.nf > 0`): `capture_finish` marked `fo.failed` and returned false only if doomed!
					fo := &h.pool.factored[h.nf - 1]
					if !h.need_reread {
						fail_doomed_factored(h, fo)
					}
					return s, .Stop
				}
				h.failed = true
				if (h.sink == nil || h.quiet) && !defer_last_stop(h) {
					return s, .Stop
				}
			}
			return after_value(h, s), .Next
		}
		return s, .Next
	}

	// Key token inside an open object.
	if t.role == .Key {
		return on_key(h, s, t)
	}

	// Container close token.
	if t.kind == .End {
		return on_end(h, s, t)
	}

	// Value token (scalar or container open).
	return on_value(h, s, t)
}

// ============================================================================
// Key handling (`on_key`)
// ============================================================================

@(private)
on_key :: proc(h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if h.sp == 0 {
		return s, .Next
	}
	f := &h.frames[h.sp - 1]
	// Free any previously owned decoded key string on this frame.
	if f.key_owned {
		delete(f.key_name, h.scratch)
		f.key_owned = false
	}
	f.skip_member = false
	f.key_at = t.lo

	// Fast path: if this object is an open factored object!
	if f.is_factored {
		key_str, owned, ok := token_key_text(h, t)
		if !ok {
			h.fatal = .No_Memory
			return s, .Stop
		}
		defer if owned {
			delete(key_str, h.scratch)
		}
		fo := &h.pool.factored[h.nf - 1]
		skip, doomed := factored_key(h, fo, key_str, t.lo)
		if h.fatal != .None || doomed {
			if h.fatal == .None && !h.need_reread {
				fail_doomed_factored(h, fo)
			}
			return s, .Stop
		}
		if skip && h.dups != .Refuse {
			return s, .Skip
		}
		if skip {
			// Under `.Refuse`, cannot `.Skip` (walk has no `.Skips`): point at trivial `Plan.nothing` sentinel.
			return {s.a, u64(uintptr(&h.plan.records[h.plan.nothing])), s.c}, .Next
		}
		return s, .Next
	}

	// Normal object frame!
	// If we were in sequential `.Expects` mode, flush the `0 ..< k` members that were matched before this key!
	if f.in_seq {
		flush_sequential(h, f, s.b)
		if h.fatal != .None {
			return s, .Stop
		}
	}

	key_str, owned, ok := token_key_text(h, t)
	if !ok {
		h.fatal = .No_Memory
		return s, .Stop
	}
	f.key_name = key_str
	f.key_owned = owned
	f.key_known = false

	// Duplicate-key tracking for `.Last`/`.First`.
	if f.has_tracker {
		tr := &h.trackers[f.tracker_idx]
		if tracker_has(tr, key_str) {
			if h.judge_dups && h.dups == .First {
				f.skip_member = true
				return s, .Skip if h.dups != .Refuse else .Next
			}
			if h.dups == .First || h.dups == .Last {
				h.need_reread = true
				h.dup_hit = true
				return s, .Stop
			}
		} else {
			if !tracker_add(h, tr, key_str) {
				h.fatal = .No_Memory
				return s, .Stop
			}
		}
	}

	f.count += 1

	owner := f.owner
	m := &h.plan.meta[owner.meta]
	u := &h.plan.uses[owner.meta]

	// `propertyNames` leaf check!
	if u.keys > 0 {
		kl := &h.plan.leaves[u.keys - 1]
		if !string_passes_leaf(h, kl, key_str, t.lo, owner, true) {
			h.failed = true
			if (h.sink == nil || h.quiet) && !defer_last_stop(h) {
				return s, .Stop
			}
		}
		if h.fatal != .None {
			return s, .Stop
		}
	}

	// Look up `key_str` in named member hash table.
	idx := member_find(h.plan, m, key_str)
	f.member_idx = idx
	if idx >= 0 {
		// Mark named member seen (and detect duplicates even without full tracker!).
		was_seen, seen_ok := frame_mark_seen(h, f, idx)
		if !seen_ok {
			return s, .Stop
		}
		if was_seen && !f.has_tracker {
			if h.dups == .First || h.dups == .Last {
				h.need_reread = true
				h.dup_hit = true
				return s, .Stop
			}
		}
		// Point `s.b` at this member's `solo` pair (`&plan.solo[2 * rec_idx + 1]`),
		// so `b[-1]` is the member's record and `b[0]` is `.End{NO_KEY}`!
		rec_idx := int(m.block + idx)
		return {s.a, u64(uintptr(&h.plan.solo[2 * rec_idx + 1])), s.c}, .Next
	}

	// Inline single `patternProperties` check!
	if u.pattern > 0 && u.regex != nil {
		re_scratch := checker_regex_scratch(h)
		if re_scratch == nil {
			return s, .Stop
		}
		steps := remaining_steps(h)
		found, serr := regex.search(u.regex, key_str, 0, nil, re_scratch, steps)
		charge_steps(h, re_scratch.spent)
		if serr.kind != .None {
			h.fatal = .Exceeded if serr.kind == .Steps else .No_Memory
			return s, .Stop
		}
		if found {
			return {s.a, u64(uintptr(&h.plan.records[u.pattern])), s.c}, .Next
		}
	}

	// `additionalProperties` check!
	if u.additional > 0 {
		return {s.a, u64(uintptr(&h.plan.records[u.additional])), s.c}, .Next
	}

	// No schema for this extra member -> skip its value (or use `Plan.nothing` under `.Refuse`).
	nothing_b := u64(uintptr(&h.plan.records[h.plan.nothing]))
	if h.dups != .Refuse {
		return {s.a, nothing_b, s.c}, .Skip
	}
	return {s.a, nothing_b, s.c}, .Next
}

// Flushes sequentially matched `.Expects` members `0 ..< k` into `f.seen_mask`/`f.seen_wide` and `f.count`.
@(private)
flush_sequential :: proc(h: ^Checker, f: ^Frame, cur_b: u64) #no_bounds_check {
	f.in_seq = false
	k := int((uintptr(cur_b) - uintptr(f.block_start)) / size_of(Record))
	if k <= 0 {
		return
	}
	m := &h.plan.meta[f.owner.meta]
	if k > int(m.members) {
		k = int(m.members)
	}
	f.count += u64(k)
	if m.members <= 64 {
		f.seen_mask |= ~u64(0) if k == 64 else (u64(1) << uint(k)) - 1
	} else {
		for i in 0 ..< k {
			_, ok := frame_mark_seen(h, f, i32(i))
			if !ok {
				return
			}
		}
	}
	if f.has_tracker {
		tr := &h.trackers[f.tracker_idx]
		for i in 0 ..< k {
			if !tracker_add(h, tr, h.plan.meta[int(m.block) + i].name) {
				h.fatal = .No_Memory
				return
			}
		}
	}
}

// ============================================================================
// Value handling (`on_value`)
// ============================================================================

@(private)
on_value :: proc(h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	// If inside an open factored object and NOT inside a single choice sub-container:
	if h.sp > 0 && h.frames[h.sp - 1].is_factored {
		fo := &h.pool.factored[h.nf - 1]
		if t.kind != .Object && t.kind != .Array {
			doomed := factored_scalar(h, fo, t)
			if h.fatal != .None {
				return s, .Stop
			}
			if doomed {
				fail_doomed_factored(h, fo)
				return s, .Stop
			}
			return s, .Next
		}
		// Container value on a factored object's active member!
		choice_rec, use_fork, skip, doomed := factored_container(h, fo, t)
		if h.fatal != .None {
			return s, .Stop
		}
		if doomed {
			fail_doomed_factored(h, fo)
			return s, .Stop
		}
		if skip {
			if h.dups != .Refuse {
				return s, .Skip
			}
			// Passive container under `.Refuse`.
			nothing := &h.plan.records[h.plan.nothing - 1]
			return open_container(h, s, t, nothing, is_choice = false)
		}
		if use_fork {
			// Multi-choice container member (Stage 3): capture once and evaluate all live choices!
			if !capture_start(h, fo.owner, t.lo, for_factor = true, fm = fo.active_member) {
				return s, .Stop
			}
			_, ok := capture_feed(h, t)
			if !ok {
				return s, .Stop
			}
			return s, .Next
		}
		// Single live choice (Stage 3/4): open directly as a child container (may itself be a nested factored object!)
		return open_container(h, s, t, choice_rec, is_choice = true)
	}

	// Normal value: `r = b[-1]` is the record judging this value!
	r := (^Record)(uintptr(s.b) - size_of(Record))
	// Track array element count & index on parent array frame, or sequential `.Expects` member name on parent object frame (B-C5).
	if h.sp > 0 {
		pf := &h.frames[h.sp - 1]
		if !pf.is_object {
			pf.elem_index = int(pf.count)
			pf.count += 1
		} else if pf.in_seq {
			if pf.key_owned {
				delete(pf.key_name, h.scratch)
				pf.key_owned = false
			}
			pf.key_name = h.plan.meta[r.meta].name
			pf.key_known = true
		}
	}

	// Held record (has `Use.applies`)?
	if .Held in r.flags {
		u := &h.plan.uses[r.meta]
		// Stage 1-4: factored held object fast path!
		if .Factored in r.flags && t.kind == .Object && !h.no_factor && !h.judge_dups {
			if factored_open(h, r, u.factor, t.lo) {
				if !push_frame(h, Frame{
					is_object = true,
					is_factored = true,
					owner = r,
					parent_b = s.b,
					open_at = t.lo,
				}) {
					h.nf -= 1
					return s, .Stop
				}
				// Point `s.b` at `DEAD_RECORD` so `.Expects` never bypasses `on_key` inside a factored object!
				return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next
			}
			if h.fatal != .None {
				return s, .Stop
			}
		}
		// Non-factored held value:
		if t.kind != .Object && t.kind != .Array {
			// Scalar held value: build a 1-node mini document on stack — zero heap allocs!
			if !eval_held_scalar(h, r, t) {
				h.failed = true
				if (h.sink == nil || h.quiet) && !defer_last_stop(h) {
					return s, .Stop
				}
			}
			if h.fatal != .None {
				return s, .Stop
			}
			return after_value(h, s), .Next
		}
		// Container held value: capture via `build.Builder` and evaluate all `Apply` arms at `.End`!
		if !capture_start(h, r, t.lo) {
			return s, .Stop
		}
		_, ok := capture_feed(h, t)
		if !ok {
			return s, .Stop
		}
		return s, .Next
	}

	// Plain `.Checked` record!
	if t.kind != .Object && t.kind != .Array {
		if r.rule_set > 0 {
			l := &h.plan.leaves[r.rule_set - 1]
			if !judge_scalar_token(h, l, t, r) {
				h.failed = true
				if (h.sink == nil || h.quiet) && !defer_last_stop(h) {
					return s, .Stop
				}
			}
			if h.fatal != .None {
				return s, .Stop
			}
		}
		return after_value(h, s), .Next
	}

	// Plain container open (`.Object` or `.Array`).
	return open_container(h, s, t, r, is_choice = false)
}

@(private)
open_container :: proc(h: ^Checker, s: hook.Regs, t: tape.Token, r: ^Record, is_choice: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	// Check cumulative depth budget (including `subcheck_node` nesting — B-H3)!
	max_depth := int(h.budget.depth) if h.budget.depth > 0 else int(tape.DEFAULT_DEPTH)
	if h.sp + h.nest_depth >= max_depth {
		h.fatal = .Exceeded
		return s, .Stop
	}

	// If `is_choice` and `r` is itself a factored held object (Stage 4 nested factored object!):
	if is_choice && .Held in r.flags {
		u := &h.plan.uses[r.meta]
		if .Factored in r.flags && t.kind == .Object && !h.no_factor && !h.judge_dups {
			if factored_open(h, r, u.factor, t.lo) {
				if !push_frame(h, Frame{
					is_object = true,
					is_factored = true,
					is_choice = true,
					owner = r,
					parent_b = s.b,
					open_at = t.lo,
				}) {
					h.nf -= 1
					return s, .Stop
				}
				return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next
			}
			if h.fatal != .None {
				return s, .Stop
			}
		}
		// Choice is a non-factored held container -> capture via `build.Builder`!
		if !capture_start(h, r, t.lo, for_factor = true, fm = h.pool.factored[h.nf - 1].active_member) {
			return s, .Stop
		}
		_, ok := capture_feed(h, t)
		if !ok {
			return s, .Stop
		}
		return s, .Next
	}

	// Check container type rule on `r`'s leaf (`.Object` or `.Array`).
	is_obj := t.kind == .Object
	if r.rule_set > 0 {
		l := &h.plan.leaves[r.rule_set - 1]
		want := rules.Kind.Object if is_obj else rules.Kind.Array
		if want not_in l.kinds || l.has_enum {
			kind := Error_Kind.Wrong_Kind if want not_in l.kinds else Error_Kind.Not_A_Member
			kw := keyword_of_kind(kind, l, is_obj)
			exp := rules.operand_text(l, kind, is_obj, h.scratch) if kind == .Wrong_Kind else ""
			defer if len(exp) > 0 {
				delete(exp, h.scratch)
			}
			if !is_choice {
				if h.sink != nil && !h.quiet {
					record_failure(h, kind, t.lo, kw, exp, r)
				} else {
					record_first_failure(h, kind, t.lo, kw, exp, r)
				}
				h.failed = true
			}
			if is_choice {
				// Choice failed immediately on container type!
				fo := &h.pool.factored[h.nf - 1]
				if fo.active_member != nil && fo.active_choice >= 0 {
					fo.failed |= fo.active_member.choices[fo.active_choice].parts
				}
				fo.active_member = nil
				fo.active_choice = -1
				if can_doom_factored(h, fo.factor, fo.failed) {
					fail_doomed_factored(h, fo)
					return s, .Stop
				}
				if h.dups != .Refuse {
					return s, .Skip
				}
				// Under `.Refuse`, push a passive skip frame so inner tokens are consumed cleanly without breaking stack lockstep (B-H5).
				nothing := &h.plan.records[h.plan.nothing - 1]
				return open_container(h, s, t, nothing, is_choice = false)
			} else if (h.sink == nil || h.quiet) && !defer_last_stop(h) {
				return s, .Stop
			}
		}
	}

	m := &h.plan.meta[r.meta]
	u := &h.plan.uses[r.meta]

	if is_obj {
		// Fast `.Skip` if this object has no named members, no additional/pattern, no keys, no counts, no required, and not `.Refuse`!
		if m.members == 0 && u.additional == 0 && u.pattern == 0 && u.keys == 0 && !m.counted && len(u.requires) == 0 && h.dups != .Refuse && !is_choice {
			return after_value(h, s), .Skip
		}
		block_start := &h.plan.records[m.block]
		block_end := &h.plan.records[m.block + m.members]
		// Determine whether we can use `.Expects` sequential mode:
		// Disable `.Expects` when `u.keys > 0` (every key must hit `on_key` for `propertyNames`) or `h.judge_dups`!
		can_seq := u.keys == 0 && !h.judge_dups && m.members > 0 && h.dups != .Refuse
		need_tracker := h.judge_dups || (h.dups != .Group && h.dups != .All && h.dups != .Refuse && (u.additional > 0 || u.pattern > 0 || u.keys > 0 || m.counted))
		tidx := -1
		if need_tracker {
			tidx = open_tracker(h, h.sp)
			if tidx < 0 {
				h.fatal = .No_Memory
				return s, .Stop
			}
		}
		if !push_frame(h, Frame{
			is_object = true,
			is_choice = is_choice,
			owner = r,
			parent_b = s.b,
			block_start = block_start,
			block_end = block_end,
			in_seq = can_seq,
			open_at = t.lo,
			member_idx = -1,
			has_tracker = tidx >= 0,
			tracker_idx = tidx,
		}) {
			return s, .Stop
		}
		next_b := u64(uintptr(block_start)) if can_seq else u64(uintptr(&DEAD_RECORD))
		return {s.a, next_b, s.c}, .Next
	}

	// Array open!
	// Fast `.Skip` if array has no items/prefixItems and no minItems/maxItems and not `.Refuse`!
	has_arr_cnt := false
	if r.rule_set > 0 {
		l := &h.plan.leaves[r.rule_set - 1]
		has_arr_cnt = l.min_items > 0 || l.max_items < max(u64)
	}
	if !u.inside && !has_arr_cnt && h.dups != .Refuse && !is_choice {
		return after_value(h, s), .Skip
	}
	if !push_frame(h, Frame{
		is_object = false,
		is_choice = is_choice,
		owner = r,
		parent_b = s.b,
		open_at = t.lo,
	}) {
		return s, .Stop
	}
	return {s.a, u64(uintptr(&h.plan.records[u.items])), s.c}, .Next
}

// ============================================================================
// Container close (`on_end`)
// ============================================================================

@(private)
on_end :: proc(h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if h.sp == 0 {
		return s, .Next
	}
	h.sp -= 1
	f := &h.frames[h.sp]
	if f.key_owned {
		delete(f.key_name, h.scratch)
		f.key_owned = false
	}
	if f.has_tracker {
		close_tracker(h)
	}

	// Closing a factored object!
	if f.is_factored {
		passed, owner, open_at := factored_close(h)
		if !passed {
			if f.is_choice && h.nf > 0 {
				// Nested factored object inside an outer factored object's choice!
				outer_fo := &h.pool.factored[h.nf - 1]
				if outer_fo.active_member != nil && outer_fo.active_choice >= 0 {
					outer_fo.failed |= outer_fo.active_member.choices[outer_fo.active_choice].parts
				}
				outer_fo.active_member = nil
				outer_fo.active_choice = -1
				if can_doom_factored(h, outer_fo.factor, outer_fo.failed) {
					fail_doomed_factored(h, outer_fo)
					return s, .Stop
				}
				return {s.a, f.parent_b, s.c}, .Next
			}
			// Outer factored object failed!
			if h.sink != nil && !h.quiet {
				// Stage 4 errors-sink factoring (`decisions.md` #2): reread by runs for exact error entries!
				h.need_reread = true
				h.reread_runs = true
				return s, .Stop
			}
			h.failed = true
			record_first_failure(h, .No_Arm, open_at, "anyOf", "", owner)
			if !defer_last_stop(h) {
				return s, .Stop
			}
			return after_value(h, {s.a, f.parent_b, s.c}), .Next
		}
		if f.is_choice && h.nf > 0 {
			outer_fo := &h.pool.factored[h.nf - 1]
			outer_fo.active_member = nil
			outer_fo.active_choice = -1
			return {s.a, f.parent_b, s.c}, .Next
		}
		return after_value(h, {s.a, f.parent_b, s.c}), .Next
	}

	owner := f.owner
	m := &h.plan.meta[owner.meta]
	u := &h.plan.uses[owner.meta]
	choice_failed := false

	if f.is_object {
		if f.in_seq {
			flush_sequential(h, f, s.b)
			if h.fatal != .None {
				return s, .Stop
			}
		}
		// 1. `minProperties` / `maxProperties`.
		if owner.rule_set > 0 {
			l := &h.plan.leaves[owner.rule_set - 1]
			fails := rules.judge_count(f.count, l.min_members, l.max_members)
			if fails != {} {
				choice_failed = true
				if !f.is_choice {
					emit_leaf_failures(h, l, fails, f.open_at, owner, true)
					h.failed = true
					if (h.sink == nil || h.quiet) && !defer_last_stop(h) {
						return s, .Stop
					}
				}
			}
		}
		// 2. `required` members.
		if m.members > 0 {
			end_m := &h.plan.meta[m.block + m.members]
			for req_idx in end_m.required {
				if !frame_is_seen(f, req_idx) {
					choice_failed = true
					if !f.is_choice {
						req_name := h.plan.meta[m.block + req_idx].name
						if h.sink != nil && !h.quiet {
							record_failure(h, .Missing_Field, f.open_at, "required", req_name, owner)
						} else {
							record_first_failure(h, .Missing_Field, f.open_at, "required", req_name, owner)
						}
						h.failed = true
						if (h.sink == nil || h.quiet) && !defer_last_stop(h) {
							return s, .Stop
						}
					}
				}
			}
		}
		// 3. `dependentRequired`.
		for req in u.requires {
			if frame_is_seen(f, req.trigger) {
				for want_idx in req.wants {
					if !frame_is_seen(f, want_idx) {
						choice_failed = true
						if !f.is_choice {
							want_name := h.plan.meta[m.block + want_idx].name
							if h.sink != nil && !h.quiet {
								record_failure(h, .Missing_Field, f.open_at, req.keyword, want_name, owner)
							} else {
								record_first_failure(h, .Missing_Field, f.open_at, req.keyword, want_name, owner)
							}
							h.failed = true
							if (h.sink == nil || h.quiet) && !defer_last_stop(h) {
								return s, .Stop
							}
						}
					}
				}
			}
		}
		// If a member inside this object failed while deferring early stop for `.Last` duplicate detection,
		// and no duplicate key occurred before the object closed, stop now!
		if h.failed && !f.is_choice && (h.sink == nil || h.quiet) && !defer_last_stop(h) {
			return s, .Stop
		}
	} else {
		// Array close: `minItems` / `maxItems`.
		if owner.rule_set > 0 {
			l := &h.plan.leaves[owner.rule_set - 1]
			fails := rules.judge_count(f.count, l.min_items, l.max_items)
			if fails != {} {
				choice_failed = true
				if !f.is_choice {
					emit_leaf_failures(h, l, fails, f.open_at, owner, false)
					h.failed = true
					if (h.sink == nil || h.quiet) && !defer_last_stop(h) {
						return s, .Stop
					}
				}
			}
		}
	}

	if f.is_choice && h.nf > 0 {
		outer_fo := &h.pool.factored[h.nf - 1]
		if (choice_failed || h.failed) && outer_fo.active_member != nil && outer_fo.active_choice >= 0 {
			outer_fo.failed |= outer_fo.active_member.choices[outer_fo.active_choice].parts
		}
		h.failed = false
		outer_fo.active_member = nil
		outer_fo.active_choice = -1
		if can_doom_factored(h, outer_fo.factor, outer_fo.failed) {
			fail_doomed_factored(h, outer_fo)
			return s, .Stop
		}
		return {s.a, f.parent_b, s.c}, .Next
	}

	return after_value(h, {s.a, f.parent_b, s.c}), .Next
}

// Under `.Last`, when a member inside an open object fails before the object closes, we defer early `.Stop`
// until the object closes so a later duplicate of the same key (e.g. `{"a": "bad", "a": 42}`) can be detected.
@(private = "file")
defer_last_stop :: #force_inline proc "contextless" (h: ^Checker) -> bool {
	return h.dups == .Last && !h.judge_dups && h.sp > 0 && h.frames[h.sp - 1].is_object && !h.frames[h.sp - 1].is_factored
}

// Advances cursor `s.b` after a value finishes if it was a `prefixItems` `.Step` record.
@(private)
after_value :: #force_inline proc "contextless" (h: ^Checker, s: hook.Regs) -> hook.Regs #no_bounds_check {
	if s.b == 0 || s.b == u64(uintptr(&DEAD_RECORD)) {
		return s
	}
	r := (^Record)(uintptr(s.b) - size_of(Record))
	if .Step in r.flags {
		return {s.a, s.b + size_of(Record), s.c}
	}
	return s
}

// ============================================================================
// Scalar leaf evaluation (`judge_scalar_token`, `scalar_passes_leaf`, etc.)
// ============================================================================

@(private)
token_effective_kind :: proc(h: ^Checker, t: tape.Token) -> tape.Kind {
	if t.kind != .Plain {
		return t.kind
	}
	return .String
}

// Decodes token `t` from `doc` into either a slice of `doc.src` (zero copy) or a newly allocated string in `allocator`.
@(private)
doc_token_text :: proc(doc: ^tape.Document, t: tape.Token, allocator: runtime.Allocator) -> (text: string, owned: bool, ok: bool) {
	if t.kind == .Null || t.kind == .True || t.kind == .False {
		if t.role != .Key {
			return "", false, true
		}
	}
	room := tape.text_room(doc, t)
	if room == 0 {
		s, tok := tape.node_text(doc, t, nil)
		if tok {
			return s, false, true
		}
		if t.kind == .Number && doc.format != nil && .Binary in doc.format.caps {
			// Unspellable binary number (e.g. CBOR >8 KiB bignum / NaN / Inf): NEVER return raw binary bytes!
			return "", false, false
		}
		return string(doc.src[t.lo:][:t.n]), false, true
	}
	buf, err := make([]u8, max(room, int(t.n)), allocator)
	if err != nil {
		return "", false, false
	}
	s, tok := tape.node_text(doc, t, buf)
	if !tok {
		delete(buf, allocator)
		return "", false, false
	}
	// If `node_text` returned a slice into `buf`, own `buf` (shrinking slice to decoded length? Copy/return exact slice).
	if raw_data(s) == raw_data(buf) && len(s) == len(buf) {
		return s, true, true
	}
	cloned, cerr := strings.clone(s, allocator)
	delete(buf, allocator)
	if cerr != nil {
		return "", false, false
	}
	return cloned, true, true
}

@(private)
token_decoded_scalar :: proc(h: ^Checker, t: tape.Token, buf: []u8) -> (text: string, owned: bool, ok: bool) {
	if t.kind == .Null || t.kind == .True || t.kind == .False {
		return "", false, true
	}
	if t.spelling & tape.SPELLING_DECODE == 0 && !(t.kind == .Number && h.format != nil && .Binary in h.format.caps) {
		return string(h.src[t.lo:][:t.n]), false, true
	}
	doc := tape.Document{src = h.src, format = h.format, ext = h.xml_ext}
	room := tape.text_room(&doc, t)
	if room <= len(buf) {
		if s, tok := tape.node_text(&doc, t, buf); tok {
			return s, false, true
		}
	}
	return doc_token_text(&doc, t, h.scratch)
}

@(private)
token_key_text :: proc(h: ^Checker, t: tape.Token) -> (text: string, owned: bool, ok: bool) {
	if t.spelling & tape.SPELLING_DECODE == 0 && !(t.kind == .Number && h.format != nil && .Binary in h.format.caps) {
		return string(h.src[t.lo:][:t.n]), false, true
	}
	doc := tape.Document{src = h.src, format = h.format, ext = h.xml_ext}
	return doc_token_text(&doc, t, h.scratch)
}

// Resolves a `.Plain` token (DSV unquoted cell / XML text) against the leaf's allowed `plain` kinds.
@(private)
resolve_plain_token :: proc(h: ^Checker, l: ^rules.Leaf, text: string) -> (kind: tape.Kind, num_val: spell.Number, has_num: bool) {
	if .Null in l.plain && (len(text) == 0 || text == "null") {
		return .Null, {}, false
	}
	if .Bool in l.plain {
		if text == "true" {
			return .True, {}, false
		}
		if text == "false" {
			return .False, {}, false
		}
	}
	if (.Number in l.plain || .Integer in l.plain) && len(text) > 0 {
		if num, ok := spell.number_strict(transmute([]u8)text, 0, u64(len(text))); ok {
			return .Number, num, true
		}
	}
	if .String in l.plain {
		return .String, {}, false
	}
	// Fallback: infer natural kind so error reporting is sensible.
	if len(text) == 0 || text == "null" {
		return .Null, {}, false
	}
	if text == "true" {
		return .True, {}, false
	}
	if text == "false" {
		return .False, {}, false
	}
	if num, ok := spell.number_strict(transmute([]u8)text, 0, u64(len(text))); ok {
		return .Number, num, true
	}
	return .String, {}, false
}

// Judges scalar token `t` against leaf `l`, recording failures on `h` if invalid.
@(private)
judge_scalar_token :: proc(h: ^Checker, l: ^rules.Leaf, t: tape.Token, owner: ^Record) -> bool {
	buf: [128]u8 = ---
	text, owned, ok := token_decoded_scalar(h, t, buf[:])
	if !ok {
		if t.kind != .Number {
			h.fatal = .No_Memory
			return false
		}
		text = ""
	}
	defer if owned {
		delete(text, h.scratch)
	}
	kind := t.kind
	plain_num: spell.Number
	has_plain_num := false
	if kind == .Plain {
		kind, plain_num, has_plain_num = resolve_plain_token(h, l, text)
	}

	fails := judge_scalar_core(h, l, kind, text, t, plain_num, has_plain_num)
	if h.fatal != .None {
		return false
	}
	if fails == {} {
		return true
	}
	emit_leaf_failures(h, l, fails, t.lo, owner, false)
	return false
}

// Pure boolean leaf check (no error emission) used by `Factored_Open`.
@(private)
scalar_passes_leaf :: proc(h: ^Checker, l: ^rules.Leaf, t: tape.Token) -> bool {
	buf: [128]u8 = ---
	text, owned, ok := token_decoded_scalar(h, t, buf[:])
	if !ok {
		if t.kind != .Number {
			h.fatal = .No_Memory
			return false
		}
		text = ""
	}
	defer if owned {
		delete(text, h.scratch)
	}
	kind := t.kind
	plain_num: spell.Number
	has_plain_num := false
	if kind == .Plain {
		kind, plain_num, has_plain_num = resolve_plain_token(h, l, text)
	}
	return judge_scalar_core(h, l, kind, text, t, plain_num, has_plain_num) == {}
}

// Normalizes a `.Number` token's spelling to clean decimal text for exact `decimal_of` / `enum_find`.
// Returns `ok = false` for non-finite floats (`NaN`, `±Inf`) or unspellable CBOR bignums (A-H1, B-C8).
@(private)
normalize_token_number :: proc(h: ^Checker, t: tape.Token, raw_text: string, buf: []u8) -> (text: string, owned: bool, ok: bool) {
	if (t.spelling != 0 || (h.format != nil && .Binary in h.format.caps)) && h.format != nil && h.format.number != nil {
		num := h.format.number(h.src, tape.Node(t))
		switch num.kind {
		case .Int:
			return strconv.write_int(buf, i64(num.bits), 10), false, true
		case .Uint:
			return strconv.write_uint(buf, num.bits, 10), false, true
		case .Float:
			f := transmute(f64)num.bits
			if math.is_nan(f) || math.is_inf(f, 0) {
				return "", false, false
			}
			if .Binary in h.format.caps {
				return strconv.write_float(buf, f, 'g', -1, 64), false, true
			}
			// Text format (TOML/JSON5): strip `_` / leading `+` / leading `.` without lossy `f64` round-trip!
			return rules.normalize_decimal_text(raw_text, buf, h.scratch)
		case .Wide:
			if len(raw_text) == 0 {
				return "", false, false
			}
			return rules.normalize_decimal_text(raw_text, buf, h.scratch)
		}
	}
	return rules.normalize_decimal_text(raw_text, buf, h.scratch)
}

// Pure boolean record check on a scalar token (used when a factored choice might accept scalars).
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
	if r.rule_set == 0 {
		return true
	}
	return scalar_passes_leaf(h, &h.plan.leaves[r.rule_set - 1], t)
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
		want_num := .Number in l.kinds
		want_int := .Integer in l.kinds
		if !want_num && !want_int {
			fails += {.Wrong_Kind}
		} else {
			num_buf: [64]u8 = ---
			num_text := text
			num_owned := false
			defer if num_owned {
				delete(num_text, h.scratch)
			}
			small: Maybe(i64)
			is_int := false
			non_finite := false
			unspellable := false
			if has_plain_num {
				switch plain_num.kind {
				case .Int:
					small = i64(plain_num.bits)
					is_int = true
				case .Uint:
					if plain_num.bits <= u64(max(i64)) {
						small = i64(plain_num.bits)
					}
					is_int = true
				case .Float, .Wide:
					if !rules.valid_decimal_text(num_text) {
						non_finite = true
					} else {
						is_int = !l.integer_spelled && rules.integral(rules.decimal_of(num_text))
					}
				}
			} else if (t.spelling != 0 || (h.format != nil && .Binary in h.format.caps)) && h.format != nil && h.format.number != nil {
				// Non-plain number spelling (JSON5 hex/leading-dot/plus/NaN/Inf, TOML hex/oct/bin/underscores/nan/inf, CBOR binary)!
				num := h.format.number(h.src, tape.Node(t))
				switch num.kind {
				case .Int:
					small = i64(num.bits)
					is_int = true
					num_text = strconv.write_int(num_buf[:], i64(num.bits), 10)
				case .Uint:
					if num.bits <= u64(max(i64)) {
						small = i64(num.bits)
					}
					is_int = true
					num_text = strconv.write_uint(num_buf[:], num.bits, 10)
				case .Float:
					f := transmute(f64)num.bits
					if math.is_nan(f) || math.is_inf(f, 0) {
						non_finite = true
					} else if .Binary in h.format.caps {
						num_text = strconv.write_float(num_buf[:], f, 'g', -1, 64)
						is_int = !l.integer_spelled && rules.integral(rules.decimal_of(num_text))
					} else {
						nt, nown, nok := rules.normalize_decimal_text(num_text, num_buf[:], h.scratch)
						if !nok {
							non_finite = true
						} else {
							num_text, num_owned = nt, nown
							is_int = !l.integer_spelled && rules.integral(rules.decimal_of(num_text))
						}
					}
				case .Wide:
					if len(num_text) == 0 {
						unspellable = true
					} else {
						nt, nown, nok := rules.normalize_decimal_text(num_text, num_buf[:], h.scratch)
						if !nok {
							unspellable = true
						} else {
							num_text, num_owned = nt, nown
							is_int = !l.integer_spelled && rules.integral(rules.decimal_of(num_text))
						}
					}
				}
			} else {
				// Fast integer check for plain decimal text!
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
				// Non-finite `NaN`/`±Inf`: never pass to `decimal_of`!
				if !want_num {
					fails += {.Wrong_Kind}
				}
				if l.minimum.set {
					// `-Inf` and `NaN` fail any finite minimum; `+Inf` satisfies finite minimum.
					num := h.format.number(h.src, tape.Node(t)) if h.format != nil && h.format.number != nil else spell.Number{}
					f := transmute(f64)num.bits
					if !(num.kind == .Float && math.is_inf(f, 1)) {
						fails += {.Below_Minimum}
					}
				}
				if l.maximum.set {
					num := h.format.number(h.src, tape.Node(t)) if h.format != nil && h.format.number != nil else spell.Number{}
					f := transmute(f64)num.bits
					if !(num.kind == .Float && math.is_inf(f, -1)) {
						fails += {.Above_Maximum}
					}
				}
				if l.multiple_of != nil {
					fails += {.Not_Multiple}
				}
				if l.has_enum {
					fails += {.Not_A_Member}
				}
				return fails
			}
			if unspellable {
				// Unspellable CBOR >8 KiB bignum / huge exponent: never pass raw binary bytes to `decimal_of`.
				if !want_num {
					fails += {.Wrong_Kind}
				}
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
			re_scratch: ^regex.Scratch
			if l.pattern != nil {
				re_scratch = checker_regex_scratch(h)
				if re_scratch == nil || h.fatal != .None {
					return
				}
			}
			steps := remaining_steps(h)
			sf, rerr := rules.judge_string(l, text, re_scratch, steps, h.scratch)
			if re_scratch != nil {
				charge_steps(h, re_scratch.spent)
			}
			if rerr.kind != .None {
				if rerr.kind == .Steps {
					h.fatal = .Exceeded
				} else if rerr.kind == .Memory {
					h.fatal = .No_Memory
				}
				return
			}
			fails += sf
		}
	}
	if l.has_enum {
		if !rules.enum_has(l, kind, text, h.scratch) {
			fails += {.Not_A_Member}
		}
	}
	return fails
}

@(private)
string_passes_leaf :: proc(h: ^Checker, l: ^rules.Leaf, text: string, at: u64, owner: ^Record, is_key: bool) -> bool {
	fails: rules.Failures
	if .String not_in l.kinds {
		fails += {.Wrong_Kind}
	} else {
		re_scratch: ^regex.Scratch
		if l.pattern != nil {
			re_scratch = checker_regex_scratch(h)
			if re_scratch == nil || h.fatal != .None {
				return false
			}
		}
		steps := remaining_steps(h)
		sf, rerr := rules.judge_string(l, text, re_scratch, steps, h.scratch)
		if re_scratch != nil {
			charge_steps(h, re_scratch.spent)
		}
		if rerr.kind != .None {
			h.fatal = .Exceeded if rerr.kind == .Steps else .No_Memory
			return false
		}
		fails += sf
	}
	if l.has_enum && !rules.enum_has(l, .String, text, h.scratch) {
		fails += {.Not_A_Member}
	}
	if fails == {} {
		return true
	}
	if is_key {
		for k in fails {
			kw := keyword_of_kind(k, l, false)
			exp := rules.operand_text(l, k, false, h.scratch)
			defer if len(exp) > 0 {
				delete(exp, h.scratch)
			}
			if h.sink != nil && !h.quiet {
				record_failure(h, k, at, kw, exp, owner, extra_kw = "propertyNames")
			} else {
				record_first_failure(h, k, at, kw, exp, owner, extra_kw = "propertyNames")
				break
			}
		}
	} else {
		emit_leaf_failures(h, l, fails, at, owner, false)
	}
	return false
}

@(private)
emit_leaf_failures :: proc(h: ^Checker, l: ^rules.Leaf, fails: rules.Failures, at: u64, owner: ^Record, members: bool) {
	for k in fails {
		kw := keyword_of_kind(k, l, members)
		exp := rules.operand_text(l, k, members, h.scratch)
		defer if len(exp) > 0 {
			delete(exp, h.scratch)
		}
		if h.sink != nil && !h.quiet {
			record_failure(h, k, at, kw, exp, owner)
		} else {
			record_first_failure(h, k, at, kw, exp, owner)
			return
		}
	}
}

// Evaluates a held record on a single scalar token (no heap document build needed!).
@(private)
eval_held_scalar :: proc(h: ^Checker, owner: ^Record, t: tape.Token) -> bool {
	nodes := [1]tape.Node{tape.Node(t)}
	doc := tape.Document{
		src = h.src,
		nodes = nodes[:],
		format = h.format,
		ext = h.xml_ext,
	}
	return eval_held_node(h, &doc, 0, owner, t.lo)
}

// ============================================================================
// Subcheck helpers (called from `arms.odin`) & explicit-stack `check_document`
// ============================================================================

// Evaluates `plan.records[rec_idx]` on `doc` at `node`, inheriting `h`'s instance/keyword path prefix.
@(private)
subcheck_node :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, rec_idx: i32, extra_path: []tape.Step, owner: ^Record, quiet: bool) -> bool {
	max_depth := int(h.budget.depth) if h.budget.depth > 0 else int(tape.DEFAULT_DEPTH)
	if h.sp + h.nest_depth >= max_depth {
		h.fatal = .Exceeded
		return false
	}

	// Build combined instance/keyword path prefix only if we might emit errors.
	sub_path: [dynamic]tape.Step
	sub_words: [dynamic]tape.Step
	emit := h.sink != nil && !quiet && !h.quiet
	if emit || !h.first_recorded {
		sub_path = make([dynamic]tape.Step, h.scratch)
		sub_words = make([dynamic]tape.Step, h.scratch)
		append_current_instance_path(h, &sub_path)
		append(&sub_path, ..extra_path)
		append_current_keyword_path(h, &sub_words, owner)
	}
	defer {
		delete(sub_path)
		delete(sub_words)
	}

	sub: Checker
	memo: hook.Expected_Memo = ---
	sub_opts := Options{dups = h.dups, budget = h.budget, scratch = h.scratch}
	_ = checker_start(&sub, h.plan, doc.src, doc.format, sub_opts, h.sink if emit else nil, &memo, h.allocator, h.scratch, h.mem_budget)
	sub.xml_ext = doc.ext
	sub.steps_used = h.steps_used
	sub.nodes_seen = h.nodes_seen
	sub.quiet = quiet || h.quiet
	sub.no_factor = h.no_factor
	sub.pool = h.pool
	sub.owns_pool = false
	sub.prefix_path = sub_path[:]
	sub.prefix_words = sub_words[:]
	sub.nest_depth = h.sp + h.nest_depth + 1
	defer {
		h.steps_used = sub.steps_used
		h.nodes_seen = sub.nodes_seen
		if sub.fatal != .None && h.fatal == .None {
			h.fatal = sub.fatal
		}
		if sub.need_reread {
			h.need_reread = true
		}
		if sub.reread_runs {
			h.reread_runs = true
		}
		if sub.first_recorded && !h.first_recorded && !quiet && !h.quiet {
			copy_first_error(h, &sub)
		}
		destroy_first_arena(&sub)
		checker_cleanup(&sub)
	}

	return walk_document_node(&sub, doc, node, &h.plan.records[rec_idx])
}

// Evaluates `plan.records[rec_idx]` on an object key string (for held `propertyNames` schemas).
@(private)
subcheck_key_string :: proc(h: ^Checker, key_str: string, key_at: u64, doc: ^tape.Document, rec_idx: i32, owner: ^Record, quiet: bool) -> bool {
	key_bytes := transmute([]u8)key_str
	nodes := [1]tape.Node{tape.Node{lo = 0, n = u32(len(key_bytes)), kind = .String, role = .Value}}
	synth := tape.Document{src = key_bytes, nodes = nodes[:], format = doc.format}
	return subcheck_node(h, &synth, 0, rec_idx, nil, owner, quiet)
}

// Explicit-stack traversal of `doc` starting at `root_node` judged by `root_rec`.
// Handles all 5 formats including XML, DSV `Tabular_Ext`, and CBOR binary numbers with ZERO unbounded recursion!
@(private)
walk_document_node :: proc(h: ^Checker, doc: ^tape.Document, root_node: tape.Node_Index, root_rec: ^Record) -> bool {
	Doc_Frame :: struct {
		node:          tape.Node_Index,
		is_object:     bool,
		iter:          tape.Children,
		open_factored: bool,
		factored_rec:  ^Record,
	}

	stack := make([dynamic]Doc_Frame, h.scratch)
	defer {
		for &fr in stack {
			tape.destroy_children(&fr.iter)
		}
		delete(stack)
	}

	r := tape.Reader{doc = doc}
	root_idx := int(root_rec.meta)
	regs := hook.Regs{b = u64(uintptr(&h.plan.solo[2 * root_idx + 1]))}

	start_node :: proc(h: ^Checker, r: tape.Reader, doc: ^tape.Document, node: tape.Node_Index, regs: ^hook.Regs, stack: ^[dynamic]Doc_Frame) -> (stopped: bool) {
		n := doc.nodes[node]
		tok := tape.Token{lo = n.lo, n = n.n, kind = n.kind, role = .Value, spelling = n.spelling}
		if n.kind == .Object || n.kind == .Array {
			tok.n = 0
		}
		pre_nf := h.nf
		pre_sp := h.sp
		act: hook.Action
		regs^, act = checker_step(h, regs^, tok)
		if act == .Stop || h.fatal != .None {
			return true
		}
		if act == .Skip || act == .Rest {
			return false
		}
		if n.kind == .Object || n.kind == .Array {
			it, p, cerr := tape.children(r, node, h.scratch)
			if cerr != nil {
				h.fatal = .No_Memory
				return true
			}
			if p != .Found {
				tape.destroy_children(&it)
				h.fatal = .Unsupported
				return true
			}
			opened_fac := n.kind == .Object && h.nf > pre_nf && h.sp > pre_sp && h.frames[h.sp - 1].is_factored
			fac_rec := h.frames[h.sp - 1].owner if opened_fac else nil
			append(stack, Doc_Frame{
				node = node,
				is_object = n.kind == .Object,
				iter = it,
				open_factored = opened_fac,
				factored_rec = fac_rec,
			})
		}
		return false
	}

	if start_node(h, r, doc, root_node, &regs, &stack) {
		return !h.failed && h.fatal == .None && !h.need_reread
	}

	for len(stack) > 0 {
		top := &stack[len(stack) - 1]
		if top.is_object {
			kn, vn, cp := tape.next_child(r, &top.iter, h.dups)
			if cp == .Found {
				kt := tape.cell_key(r, top.iter) if (kn == tape.NO_NODE && top.iter.keys_n != 0) else doc.nodes[kn]
				ktok := tape.Token{lo = kt.lo, n = kt.n, kind = kt.kind, role = .Key, spelling = kt.spelling}
				act: hook.Action
				regs, act = checker_step(h, regs, ktok)
				if act == .Stop || h.fatal != .None {
					return false
				}
				if act == .Skip {
					continue
				}
				if start_node(h, r, doc, vn, &regs, &stack) {
					return false
				}
				continue
			}
		} else {
			_, ch, cp := tape.next_child(r, &top.iter)
			if cp == .Found {
				if start_node(h, r, doc, ch, &regs, &stack) {
					return false
				}
				continue
			}
		}
		closed := pop(&stack)
		tape.destroy_children(&closed.iter)
		// Save `parent_b` BEFORE `checker_step` pops the frame so in-place factored fallback can restore `regs` (B-H1)!
		saved_parent_b := h.frames[h.sp - 1].parent_b if h.sp > 0 else regs.b
		end_tok := tape.Token{lo = doc.nodes[closed.node].lo, kind = .End, role = .Value}
		act: hook.Action
		regs, act = checker_step(h, regs, end_tok)
		if h.reread_runs && closed.open_factored && closed.factored_rec != nil {
			h.reread_runs = false
			h.need_reread = false
			saved_nf := h.no_factor
			h.no_factor = true
			ok := eval_held_node(h, doc, closed.node, closed.factored_rec, doc.nodes[closed.node].lo)
			h.no_factor = saved_nf
			if h.fatal != .None {
				return false
			}
			if !ok {
				h.failed = true
			}
			regs = after_value(h, {regs.a, saved_parent_b, regs.c})
			continue
		}
		if act == .Stop || h.fatal != .None {
			return false
		}
	}

	return !h.failed && h.fatal == .None && !h.need_reread
}

// ============================================================================
// Public `check_document` and generic streaming `check_stream`
// ============================================================================

// Checks an already-built `tape.Document` (JSON, TOML, XML, DSV, or CBOR) against compiled `plan`.
// Uses an explicit heap stack (zero unbounded recursion) and allocates zero `context.temp_allocator` memory.
@(require_results)
check_document :: proc(doc: ^tape.Document, plan: ^Plan, opts := Options{}, sink: ^Sink = nil, allocator := context.allocator) -> Result {
	if doc == nil || plan == nil || len(plan.records) == 0 {
		return {valid = false, err = {kind = .Bad_Option, keyword = "plan"}}
	}
	if doc.partial != nil {
		return {valid = false, err = {kind = .Unsupported, keyword = "partial"}}
	}
	if len(doc.nodes) == 0 {
		return {valid = false, err = {kind = .Walk}}
	}

	// Set up unified memory budget over scratch and output.
	t_opts := tape.Options{budget = opts.budget, scratch = opts.scratch}
	rb: hook.Read_Budget
	out_alloc := hook.read_budget(untracked_ptr(&rb), t_opts, allocator)
	local_mb: hook.Memory_Budget
	scratch := hook.scratch(t_opts, out_alloc, untracked_ptr(&local_mb))
	mem_b: ^hook.Memory_Budget = untracked_ptr(&rb.main) if opts.budget.memory > 0 else nil

	h: Checker
	memo: hook.Expected_Memo = ---
	_ = checker_start(&h, plan, doc.src, doc.format, opts, sink, &memo, allocator, scratch, mem_b)
	h.xml_ext = doc.ext
	from := len(sink.entries) if sink != nil else 0
	defer checker_cleanup(&h)

	ok := walk_document_node(&h, doc, 0, &plan.records[0])
	if !ok && h.need_reread && !h.reread_runs && h.fatal == .None {
		// Rare case: document had duplicate keys under `.First`/`.Last` and wasn't deduplicated during build.
		if sink != nil {
			sink_restore(sink, {count = from})
		}
		checker_cleanup(&h)
		h = {}
		_ = checker_start(&h, plan, doc.src, doc.format, opts, sink, &memo, allocator, scratch, mem_b)
		h.xml_ext = doc.ext
		h.no_factor = true
		h.judge_dups = true
		ok = walk_document_node(&h, doc, 0, &plan.records[0])
	}

	if sink != nil {
		order_entries(sink, from)
	}
	mem_refused := opts.budget.memory > 0 && (rb.main.refused || (rb.main.peer != nil && rb.main.peer.refused))
	return finish_result(&h, nil, mem_refused, allocator)
}

// Generic streaming driver called by `next/{json,toml,xml,dsv,cbor}/check.odin`.
// Streams tokens directly from the format's walk into `Checker` (or `Refusing_Checker` under `.Refuse`)
// with ZERO intermediate `tape.Document` allocation on the normal path!
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
	if opts.budget.depth > 0 {
		t_opts.budget.depth = opts.budget.depth
	}
	if opts.budget.nodes > 0 {
		t_opts.budget.nodes = opts.budget.nodes
	}
	if opts.budget.memory > 0 {
		t_opts.budget.memory = opts.budget.memory
	}
	if opts.budget.steps > 0 {
		t_opts.budget.steps = opts.budget.steps
	}
	if opts.scratch.procedure != nil {
		t_opts.scratch = opts.scratch
	}

	rb: hook.Read_Budget
	out_alloc := hook.read_budget(untracked_ptr(&rb), t_opts, allocator)
	local_mb: hook.Memory_Budget
	scratch := hook.scratch(t_opts, out_alloc, untracked_ptr(&local_mb))
	mem_b: ^hook.Memory_Budget = untracked_ptr(&rb.main) if t_opts.budget.memory > 0 else nil

	from := len(sink.entries) if sink != nil else 0

	// First pass: pure zero-Document streaming!
	h: H
	memo: hook.Expected_Memo = ---
	chk := checker_ptr(&h)
	regs := checker_start(chk, plan, src, format, opts, sink, &memo, allocator, scratch, mem_b)
	// Load lazy XML prolog/DTD extension if format provides `text_ext` so streaming XML decodes entities!
	if format != nil && format.text_ext != nil {
		if ext, ok := format.text_ext(src, scratch); ok && ext != nil {
			chk.xml_ext = ext
			chk.xml_ext_owned = true
		}
	}
	when H == Refusing_Checker {
		open_buf: [64]Open_Key = ---
		open_keys_start(&h.open_keys, open_buf[:], src, format, chk.xml_ext, scratch)
		defer open_keys_cleanup(&h.open_keys)
	}
	defer checker_cleanup(chk)

	ctx := context
	_, werr, _ := walk(src, t_opts, &h, &regs, scratch, &ctx)
	when H == Refusing_Checker {
		open_keys_end(&h.open_keys)
		if h.open_keys.oom && chk.fatal == .None {
			chk.fatal = .No_Memory
		}
		if h.open_keys.repeat != NO_REPEAT {
			chk.dup_hit = true
			chk.dup_at = h.open_keys.repeat
		}
	}

	// If walk hit a syntax/budget error (before duplicate/schema refusal), return it directly.
	if werr != nil {
		if _, is_ex := werr.(tape.Exceeded); is_ex {
			chk.fatal = .Exceeded
		}
		mem_refused := t_opts.budget.memory > 0 && (rb.main.refused || (rb.main.peer != nil && rb.main.peer.refused))
		return finish_result(chk, hook.memory_budget_error(&rb.main, werr) if t_opts.budget.memory > 0 else werr, mem_refused, allocator)
	}
	if chk.fatal != .None {
		mem_refused := t_opts.budget.memory > 0 && (rb.main.refused || (rb.main.peer != nil && rb.main.peer.refused))
		return finish_result(chk, nil, mem_refused, allocator)
	}
	if chk.dup_hit && chk.dups == .Refuse {
		if sink != nil {
			record_failure(chk, .Duplicate_Key, chk.dup_at, "duplicateKey", "", &plan.records[0])
		} else {
			record_first_failure(chk, .Duplicate_Key, chk.dup_at, "duplicateKey", "", &plan.records[0])
		}
		chk.failed = true
		if sink != nil {
			order_entries(sink, from)
		}
		mem_refused := t_opts.budget.memory > 0 && (rb.main.refused || (rb.main.peer != nil && rb.main.peer.refused))
		return finish_result(chk, nil, mem_refused, allocator)
	}

	// Stage 4 fallback 1: a factored object failed under `sink != nil` -> single reread with `no_factor = true`!
	if chk.need_reread && chk.reread_runs && chk.fatal == .None {
		if sink != nil {
			sink_restore(sink, {count = from})
		}
		when H == Refusing_Checker {
			open_keys_cleanup(&h.open_keys)
		}
		checker_cleanup(chk)
		h = {}
		regs = checker_start(chk, plan, src, format, opts, sink, &memo, allocator, scratch, mem_b)
		if format != nil && format.text_ext != nil {
			if ext, ok := format.text_ext(src, scratch); ok && ext != nil {
				chk.xml_ext = ext
				chk.xml_ext_owned = true
			}
		}
		when H == Refusing_Checker {
			open_keys_start(&h.open_keys, open_buf[:], src, format, chk.xml_ext, scratch)
		}
		chk.no_factor = true
		_, werr, _ = walk(src, t_opts, &h, &regs, scratch, &ctx)
		when H == Refusing_Checker {
			open_keys_end(&h.open_keys)
			if h.open_keys.oom && chk.fatal == .None {
				chk.fatal = .No_Memory
			}
			if h.open_keys.repeat != NO_REPEAT {
				chk.dup_hit = true
				chk.dup_at = h.open_keys.repeat
			}
		}
		if werr != nil {
			mem_refused := t_opts.budget.memory > 0 && (rb.main.refused || (rb.main.peer != nil && rb.main.peer.refused))
			return finish_result(chk, hook.memory_budget_error(&rb.main, werr) if t_opts.budget.memory > 0 else werr, mem_refused, allocator)
		}
		if chk.fatal != .None {
			mem_refused := t_opts.budget.memory > 0 && (rb.main.refused || (rb.main.peer != nil && rb.main.peer.refused))
			return finish_result(chk, nil, mem_refused, allocator)
		}
		if chk.dup_hit && chk.dups == .Refuse {
			if sink != nil {
				record_failure(chk, .Duplicate_Key, chk.dup_at, "duplicateKey", "", &plan.records[0])
			} else {
				record_first_failure(chk, .Duplicate_Key, chk.dup_at, "duplicateKey", "", &plan.records[0])
			}
			chk.failed = true
			if sink != nil {
				order_entries(sink, from)
			}
			mem_refused := t_opts.budget.memory > 0 && (rb.main.refused || (rb.main.peer != nil && rb.main.peer.refused))
			return finish_result(chk, nil, mem_refused, allocator)
		}
	}

	// Fallback 2: duplicate key encountered under `.First` or `.Last` (can also cascade from Fallback 1 — B-C1)!
	if chk.need_reread && !chk.reread_runs && chk.fatal == .None {
		if sink != nil {
			sink_restore(sink, {count = from})
		}
		if chk.dups == .First {
			// `.First`: streaming reread skipping repeated keys!
			when H == Refusing_Checker {
				open_keys_cleanup(&h.open_keys)
			}
			checker_cleanup(chk)
			h = {}
			regs = checker_start(chk, plan, src, format, opts, sink, &memo, allocator, scratch, mem_b)
			if format != nil && format.text_ext != nil {
				if ext, ok := format.text_ext(src, scratch); ok && ext != nil {
					chk.xml_ext = ext
					chk.xml_ext_owned = true
				}
			}
			when H == Refusing_Checker {
				open_keys_start(&h.open_keys, open_buf[:], src, format, chk.xml_ext, scratch)
			}
			chk.no_factor = true
			chk.judge_dups = true
			_, werr, _ = walk(src, t_opts, &h, &regs, scratch, &ctx)
			if werr != nil {
				mem_refused := t_opts.budget.memory > 0 && (rb.main.refused || (rb.main.peer != nil && rb.main.peer.refused))
				return finish_result(chk, hook.memory_budget_error(&rb.main, werr) if t_opts.budget.memory > 0 else werr, mem_refused, allocator)
			}
		} else if build_last != nil {
			// `.Last`: build deduplicated `tape.Document` and run `check_document` for 100% last-wins parity,
			// preserving effective `dups` and remaining step/memory budgets (A-H5, B-H2)!
			b_opts := t_opts
			b_opts.dups = opts.dups if opts.dups != .Default else (format.dups if format != nil else .Last)
			rem_opts := opts
			if t_opts.budget.steps > 0 {
				if chk.steps_used >= t_opts.budget.steps {
					chk.fatal = .Exceeded
					return finish_result(chk, nil, false, allocator)
				}
				rem := t_opts.budget.steps - chk.steps_used
				b_opts.budget.steps = rem
				rem_opts.budget.steps = rem
			}
			if t_opts.budget.memory > 0 {
				rem_mem := hook.memory_budget_left(&rb.main)
				if rem_mem == 0 {
					chk.fatal = .Exceeded
					return finish_result(chk, nil, true, allocator)
				}
				b_opts.budget.memory = rem_mem
				rem_opts.budget.memory = rem_mem
			}
			doc, berr := build_last(src, b_opts, scratch)
			if berr != nil {
				mem_refused := t_opts.budget.memory > 0 && (rb.main.refused || (rb.main.peer != nil && rb.main.peer.refused))
				return finish_result(chk, hook.memory_budget_error(&rb.main, berr) if t_opts.budget.memory > 0 else berr, mem_refused, allocator)
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

	if sink != nil {
		order_entries(sink, from)
	}
	mem_refused := t_opts.budget.memory > 0 && (rb.main.refused || (rb.main.peer != nil && rb.main.peer.refused))
	return finish_result(chk, nil, mem_refused, allocator)
}

// Hides a stack pointer that does not escape the call from conservative whole-struct escape tainting.
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

@(private = "file")
charge_output_budget :: proc(h: ^Checker, bytes: u64) -> bool {
	if h.mem_budget == nil || bytes == 0 {
		return true
	}
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
		k := Error_Kind.Walk
		if _, is_ex := err.(tape.Exceeded); is_ex {
			k = .Exceeded
		} else if _, is_oom := err.(runtime.Allocator_Error); is_oom {
			k = .No_Memory
		}
		return Result{valid = false, err = {kind = k, walk_err = err}, walk_err = err, allocator = allocator}
	}
	if h.fatal != .None {
		destroy_first_arena(h)
		k := h.fatal
		if k == .No_Memory && mem_refused {
			k = .Exceeded
		}
		return Result{valid = false, err = {kind = k}, allocator = allocator}
	}
	if !h.failed && (h.sink == nil || len(h.sink.entries) == h.sink_from) {
		destroy_first_arena(h)
		return Result{valid = true, allocator = allocator}
	}
	if h.sink != nil {
		destroy_first_arena(h)
		first := h.sink.entries[h.sink_from] if len(h.sink.entries) > h.sink_from else Check_Error{kind = .Not_Allowed}
		return Result{valid = false, err = first, allocator = allocator}
	}
	res := Result{
		valid = false,
		err = h.first_err,
		allocator = allocator,
		arena = h.first_arena,
	}
	h.first_arena = nil // ownership transferred to `Result`
	return res
}

// ============================================================================
// Frame stack, seen bitmasks, trackers, and error recording helpers
// ============================================================================

@(private)
push_frame :: proc(h: ^Checker, fr: Frame) -> bool {
	if h.sp == len(h.frames) {
		new_cap := max(64, len(h.frames) * 2)
		grown, err := make([]Frame, new_cap, h.scratch)
		if err != nil {
			h.fatal = .No_Memory
			return false
		}
		copy(grown, h.frames[:h.sp])
		if h.frames_heap {
			delete(h.frames, h.scratch)
		}
		h.frames = grown
		h.frames_heap = true
	}
	h.frames[h.sp] = fr
	h.sp += 1
	return true
}

@(private)
frame_mark_seen :: proc(h: ^Checker, f: ^Frame, idx: i32) -> (was_seen: bool, ok: bool) {
	m := &h.plan.meta[f.owner.meta]
	if m.members <= 64 {
		bit := u64(1) << uint(idx)
		if (f.seen_mask & bit) != 0 {
			return true, true
		}
		f.seen_mask |= bit
		return false, true
	}
	if len(f.seen_wide) == 0 {
		pool := pool_ensure(h)
		if pool == nil {
			return false, false
		}
		words := (int(m.members) + 63) / 64
		buf, err := make([]u64, words, pool_allocator(pool))
		if err != nil {
			h.fatal = .No_Memory
			return false, false
		}
		f.seen_wide = buf
	}
	w := idx >> 6
	bit := u64(1) << uint(idx & 63)
	if (f.seen_wide[w] & bit) != 0 {
		return true, true
	}
	f.seen_wide[w] |= bit
	return false, true
}

@(private)
frame_is_seen :: #force_inline proc "contextless" (f: ^Frame, idx: i32) -> bool #no_bounds_check {
	if idx < 0 {
		return false
	}
	if len(f.seen_wide) == 0 {
		if idx >= 64 {
			return false
		}
		return (f.seen_mask & (u64(1) << uint(idx))) != 0
	}
	w := int(idx >> 6)
	if w >= len(f.seen_wide) {
		return false
	}
	return (f.seen_wide[w] & (u64(1) << uint(idx & 63))) != 0
}

@(private)
open_tracker :: proc(h: ^Checker, sp: int) -> int {
	if h.tracked == len(h.trackers) {
		tr := Key_Tracker{sp = sp}
		tr.names.allocator = h.scratch
		tr.table.allocator = h.scratch
		if _, err := append(&h.trackers, tr); err != nil {
			return -1
		}
	}
	idx := h.tracked
	h.tracked += 1
	tr := &h.trackers[idx]
	tr.sp = sp
	for nm in tr.names {
		delete(nm, h.scratch)
	}
	clear(&tr.names)
	clear(&tr.table)
	return idx
}

@(private)
close_tracker :: proc(h: ^Checker) {
	if h.tracked > 0 {
		h.tracked -= 1
	}
}

@(private)
tracker_has :: proc(tr: ^Key_Tracker, name: string) -> bool {
	if len(tr.names) <= 12 {
		for nm in tr.names {
			if nm == name {
				return true
			}
		}
		return false
	}
	_, ok := tr.table[name]
	return ok
}

@(private)
tracker_add :: proc(h: ^Checker, tr: ^Key_Tracker, name: string) -> bool {
	cp, err := strings.clone(name, h.scratch)
	if err != nil {
		return false
	}
	if _, aerr := append(&tr.names, cp); aerr != nil {
		delete(cp, h.scratch)
		return false
	}
	if len(tr.names) == 13 {
		for nm, i in tr.names {
			tr.table[nm] = i
		}
	} else if len(tr.names) > 13 {
		tr.table[cp] = len(tr.names) - 1
	}
	return true
}

// Appends the current instance path (from `prefix_path` + open container `frames`) into `out`.
@(private)
append_current_instance_path :: proc(h: ^Checker, out: ^[dynamic]tape.Step) {
	append(out, ..h.prefix_path)
	for i in 0 ..< h.sp {
		fr := &h.frames[i]
		if fr.is_object {
			if fr.in_seq {
				// Current member was matched sequentially via `.Expects`: its name is in `Plan.meta`!
				// Wait: during a value, `s.b` has already advanced past it; we use `fr.key_name` if set!
				if len(fr.key_name) > 0 {
					append(out, tape.Name(fr.key_name))
				}
			} else if len(fr.key_name) > 0 {
				append(out, tape.Name(fr.key_name))
			}
		} else {
			append(out, tape.Index(fr.elem_index))
		}
	}
}

// Appends the current keyword path (from `prefix_words` + open container `Use.site`s + `owner`'s site) into `out`.
@(private)
append_current_keyword_path :: proc(h: ^Checker, out: ^[dynamic]tape.Step, owner: ^Record) {
	append(out, ..h.prefix_words)
	for i in 0 ..< h.sp {
		fr := &h.frames[i]
		if fr.owner != nil {
			append(out, ..h.plan.uses[fr.owner.meta].site)
		}
	}
	if owner != nil {
		// Avoid duplicating if `owner` is already the top frame's owner.
		if h.sp == 0 || h.frames[h.sp - 1].owner != owner {
			append(out, ..h.plan.uses[owner.meta].site)
		}
	}
}

@(private)
build_check_error :: proc(h: ^Checker, arena: runtime.Allocator, kind: Error_Kind, at: u64, keyword: string, expected: string, owner: ^Record, extra_kw := "") -> (Check_Error, bool) {
	inst_steps := make([dynamic]tape.Step, h.scratch)
	kw_steps := make([dynamic]tape.Step, h.scratch)
	defer {
		delete(inst_steps)
		delete(kw_steps)
	}
	append_current_instance_path(h, &inst_steps)
	append_current_keyword_path(h, &kw_steps, owner)
	if len(extra_kw) > 0 {
		if _, err := append(&kw_steps, tape.Name(extra_kw)); err != nil {
			h.fatal = .No_Memory
			return {}, false
		}
	}
	if len(keyword) > 0 {
		if _, err := append(&kw_steps, tape.Name(keyword)); err != nil {
			h.fatal = .No_Memory
			return {}, false
		}
	}

	// Account output memory against `Budget.memory` BEFORE allocating into caller-owned `Sink` / `first_arena` (B-C9)!
	est_bytes := u64(size_of(Check_Error)) + u64(len(expected) + len(keyword)) + u64(len(inst_steps) + len(kw_steps)) * u64(size_of(tape.Step) + 16)
	if !charge_output_budget(h, est_bytes) {
		return {}, false
	}

	inst_ptr, ierr := format_pointer(inst_steps[:], arena)
	if ierr != nil {
		h.fatal = .No_Memory
		return {}, false
	}
	kw_ptr, kerr := format_pointer(kw_steps[:], arena)
	if kerr != nil {
		h.fatal = .No_Memory
		return {}, false
	}
	path_cp, perr := clone_steps(inst_steps[:], arena)
	if perr != nil {
		h.fatal = .No_Memory
		return {}, false
	}
	kw_cp, kperr := clone_steps(kw_steps[:], arena)
	if kperr != nil {
		h.fatal = .No_Memory
		return {}, false
	}
	exp_cp := ""
	if len(expected) > 0 {
		ec, eerr := strings.clone(expected, arena)
		if eerr != nil {
			h.fatal = .No_Memory
			return {}, false
		}
		exp_cp = ec
	}
	kw_str := ""
	if len(keyword) > 0 {
		kc, kserr := strings.clone(keyword, arena)
		if kserr != nil {
			h.fatal = .No_Memory
			return {}, false
		}
		kw_str = kc
	}
	return Check_Error{
		kind = kind,
		at = at,
		instance_location = inst_ptr,
		keyword_location = kw_ptr,
		keyword = kw_str,
		expected = exp_cp,
		path = path_cp,
		keyword_path = kw_cp,
	}, true
}

@(private)
record_failure :: proc(h: ^Checker, kind: Error_Kind, at: u64, keyword: string, expected: string, owner: ^Record, extra_kw := "") {
	if h.sink == nil {
		record_first_failure(h, kind, at, keyword, expected, owner, extra_kw)
		return
	}
	arena := sink_ensure(h.sink, h.allocator)
	entry, ok := build_check_error(h, arena, kind, at, keyword, expected, owner, extra_kw)
	if !ok {
		h.sink.oom = true
		return
	}
	if _, err := append(&h.sink.entries, entry); err != nil {
		h.sink.oom = true
		h.fatal = .No_Memory
	}
}

@(private)
record_first_failure :: proc(h: ^Checker, kind: Error_Kind, at: u64, keyword: string, expected: string, owner: ^Record, extra_kw := "") {
	if h.first_recorded || h.quiet {
		return
	}
	if h.first_arena == nil {
		if !charge_output_budget(h, u64(size_of(mem.Dynamic_Arena))) {
			return
		}
		a, err := new(mem.Dynamic_Arena, h.allocator)
		if err != nil {
			h.fatal = .No_Memory
			return
		}
		mem.dynamic_arena_init(a, h.allocator, h.allocator)
		h.first_arena = a
	}
	arena := mem.dynamic_arena_allocator(h.first_arena)
	if entry, ok := build_check_error(h, arena, kind, at, keyword, expected, owner, extra_kw); ok {
		h.first_err = entry
		h.first_recorded = true
	}
}

@(private = "file")
copy_first_error :: proc(dst, src: ^Checker) {
	if dst.first_recorded || !src.first_recorded {
		return
	}
	dst.first_err = src.first_err
	dst.first_arena = src.first_arena
	src.first_arena = nil // transfer ownership
	dst.first_recorded = true
}

// ============================================================================
// `Open_Keys` for `.Refuse` duplicate-key detection (zero temp_allocator leaks)
// ============================================================================

@(private)
open_keys_start :: proc(k: ^Open_Keys, room: []Open_Key, src: []u8, format: ^tape.Format, xml_ext: ^tape.Doc_Ext, allocator: runtime.Allocator) {
	k^ = {
		room = room,
		repeat = NO_REPEAT,
		src = src,
		format = format,
		xml_ext = xml_ext,
		allocator = allocator,
		ctx = context,
	}
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
			if k.n > 0 && k.room[k.n - 1].depth == k.depth {
				open_keys_close(k)
			}
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
	context = k.ctx
	wide, err := make([]Open_Key, max(64, 2 * len(k.room)), k.allocator)
	if err != nil {
		return false
	}
	copy(wide, k.room[:k.n])
	if k.heap {
		delete(k.room, k.allocator)
	}
	k.room = wide
	k.heap = true
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
			if is_binary && keys[j].key.kind != a.key.kind {
				continue
			}
			if keys[j].key.n == a.key.n && slice.equal(src[keys[j].key.lo:][:a.key.n], src[a.key.lo:][:a.key.n]) {
				k.repeat = min(k.repeat, a.key.lo)
				return
			}
		}
	}
}

@(private)
open_keys_hashed :: proc "contextless" (k: ^Open_Keys, keys: []Open_Key, is_binary: bool) #no_bounds_check {
	context = k.ctx
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
		slots = fresh
		slots_heap = true
	}
	defer if slots_heap {
		delete(slots, k.allocator)
	}
	for i in 0 ..< size {
		slots[i] = 0
	}
	mask := u32(size - 1)
	doc := tape.Document{src = k.src, format = k.format, ext = k.xml_ext}
	for &e, i in keys {
		s, s_owned, ok := open_key_text(k, &doc, e.key)
		if !ok {
			k.oom = true
			return
		}
		h_val := tape.text_hash(transmute([]u8)s)
		if is_binary {
			h_val ~= u32(e.key.kind) * 2654435761
		}
		at := h_val & mask
		dup := false
		for ; slots[at] != 0; at = (at + 1) & mask {
			other := keys[slots[at] - 1].key
			if is_binary && other.kind != e.key.kind {
				continue
			}
			t, t_owned, tok := open_key_text(k, &doc, other)
			if !tok {
				if s_owned {
					delete(s, k.allocator)
				}
				k.oom = true
				return
			}
			same := t == s
			if t_owned {
				delete(t, k.allocator)
			}
			if same {
				dup = true
				break
			}
		}
		if s_owned {
			delete(s, k.allocator)
		}
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
