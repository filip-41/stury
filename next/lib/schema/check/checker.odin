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
	owner:          ^Record,
	parent_b:       u64,
	block_start:    ^Record,
	seen_mask:      u64,
	seen_wide:      []u64,
	count:          u64,
	open_at:        u64,
	key_name:       string,
	run_start:      i32,  // start member index of the active `.Expects` sequential run
	tracker_idx:    i16,
	is_object:      bool,
	is_factored:    bool,
	is_choice:      bool, // container opened for a single live `Factor_Choice` inside a factored object
	is_group_array: bool, // synthetic array frame grouping contiguous `.Group` (XML) sibling elements
	in_seq:         bool,
	key_owned:      bool,
	has_tracker:    bool,
	saved_failed:   bool, // saved `h.failed` when `is_choice` isolates a speculative choice
}

// Tracks seen unnamed keys in one open object when detecting/judging duplicate keys.
// Uses an inline 16-entry buffer before touching heap dynamic arrays / hash maps!
@(private)
Key_Tracker :: struct {
	small_n: int,
	small:   [16]string,
	names:   [dynamic]string,
	owned:   [dynamic]string, // only decoded/escaped keys that must be freed
	table:   map[string]int,
}

// Streaming validation hook implementing v2 `hook.Protocol({.Skips, .Expects}, ...)`.
Checker :: struct {
	expected:       ^hook.Expected_Memo,
	plan:           ^Plan,
	src:            []u8,
	format:         ^tape.Format,
	xml_ext:        ^tape.Doc_Ext, // optional lazy DTD extension for XML entity decoding
	xml_ext_owned:  bool,
	is_binary:      bool,
	has_budget:     bool,
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
	in_doc_group:   bool,        // true inside `walk_document_node` when XML `.Group` buckets are already grouped
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
	frames:         []Frame,
	frames_heap:    bool,
	sp:             int,
	pool:           ^Pool,
	owns_pool:      bool,
	nf:             int,
	choice_depth:   int,         // open speculative `is_choice` container frames
	skip_end:       bool,        // next `.End` belongs to a container we answered `.Skip` for
	capture_depth:  int,
	trackers:       [dynamic]Key_Tracker,
	tracked:        int,
	tracker0_used:  bool,
	parent:         ^Checker,    // lazy outer checker chain when running `subcheck_node` (zero path alloc unless error!)
	parent_owner:   ^Record,
	parent_extra:   []tape.Step,
	nest_depth:     int,         // subcheck nesting depth
	ctx:            ^runtime.Context,
	frames_buf:     [16]Frame,
	factored_buf:   [INLINE_FACTORED]Factored_Open,
	tracker0:       Key_Tracker, // inline slot 0 (unzeroed until first unnamed-key tracker opens!)
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
	ctx:       ^runtime.Context,
}

@(private)
NO_REPEAT :: max(u64)

@(private, rodata)
DEAD_RECORD := Record{word = NO_KEY, kind = .End}

// Initializes `h` for a streaming or document check without zeroing `frames_buf`, `factored_buf`, or `first_err`!
@(private)
checker_start :: #force_inline proc(h: ^Checker, plan: ^Plan, src: []u8, format: ^tape.Format, opts: Options, sink: ^Sink, expected: ^hook.Expected_Memo, allocator, scratch: runtime.Allocator, mem_budget: ^hook.Memory_Budget, ctx: ^runtime.Context) -> hook.Regs {
	h.expected = expected
	h.plan = plan
	h.src = src
	h.format = format
	h.xml_ext = nil
	h.xml_ext_owned = false
	h.is_binary = format != nil && .Binary in format.caps
	h.has_budget = opts.budget.nodes > 0 || opts.budget.steps > 0 || opts.budget.depth > 0
	h.sink = sink
	h.sink_from = len(sink.entries) if sink != nil else 0
	h.allocator = allocator
	h.scratch = scratch
	h.mem_budget = mem_budget
	h.budget = opts.budget
	h.steps_used = 0
	h.nodes_seen = 0
	h.dups = opts.dups if opts.dups != .Default else (format.dups if format != nil else .Last)
	h.judge_dups = false
	h.in_doc_group = false
	h.no_factor = false
	h.quiet = false
	h.failed = false
	h.fatal = .None
	h.need_reread = false
	h.reread_runs = false
	h.dup_hit = false
	h.dup_at = tape.NO_BYTE
	h.first_arena = nil
	h.first_recorded = false
	h.frames = h.frames_buf[:]
	h.frames_heap = false
	h.sp = 0
	h.pool = nil
	h.owns_pool = false
	h.nf = 0
	h.choice_depth = 0
	h.skip_end = false
	h.capture_depth = 0
	h.trackers = {}
	h.trackers.allocator = scratch
	h.tracked = 0
	h.tracker0_used = false
	h.parent = nil
	h.parent_owner = nil
	h.parent_extra = nil
	h.nest_depth = 0
	h.ctx = ctx
	return {b = u64(uintptr(plan.root))}
}

@(private)
checker_cleanup :: #force_inline proc(h: ^Checker) {
	// Fast exit on the zero-allocation happy path!
	if h.capture_depth == 0 && h.sp == 0 && !h.frames_heap && !h.tracker0_used && len(h.trackers) == 0 && !h.owns_pool && !h.xml_ext_owned && h.first_arena == nil {
		return
	}
	checker_cleanup_slow(h)
}

@(private = "file", cold)
checker_cleanup_slow :: #force_no_inline proc(h: ^Checker) {
	for h.capture_depth > 0 {
		capture_abort(h)
	}
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
		for nm in h.tracker0.owned {
			delete(nm, h.scratch)
		}
		delete(h.tracker0.owned)
		delete(h.tracker0.names)
		delete(h.tracker0.table)
		h.tracker0_used = false
	}
	for &tr in h.trackers {
		for nm in tr.owned {
			delete(nm, h.scratch)
		}
		delete(tr.owned)
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
		if old != nil && !inside {
			break
		}
		if got, err := mem.arena_allocator_proc(&sa.stack, mode, size, alignment, old, old_size, loc); err != .Out_Of_Memory {
			return got, err
		}
		got, err := runtime.mem_alloc_bytes(size, alignment, sa.fallback, loc)
		if err == nil && old != nil {
			copy(got, mem.byte_slice(old, min(old_size, size)))
		}
		return got, err
	case .Free:
		if inside || old == nil {
			return nil, nil
		}
	case .Free_All:
		return nil, .Mode_Not_Implemented
	}
	return sa.fallback.procedure(sa.fallback.data, mode, size, alignment, old, old_size, loc)
}

// Runs `regex.search` using a 2 KiB stack-backed scratch arena (spilling to `h.scratch` if needed),
// avoiding heap `Pool` / `Dynamic_Arena` allocation on every JSONL line!
@(private)
run_regex_search :: proc(h: ^Checker, re: ^regex.Regex, text: string) -> (found: bool, ok: bool) {
	room: [REGEX_STACK_ROOM]u8 = ---
	sa := Spill_Arena{fallback = h.scratch}
	mem.arena_init(&sa.stack, room[:])
	spill := runtime.Allocator{spill_proc, &sa}
	sc, merr := regex.scratch_make(spill)
	if merr.kind != .None {
		h.fatal = .No_Memory
		return false, false
	}
	defer regex.scratch_destroy(&sc)
	steps := remaining_steps(h)
	f, serr := regex.search(re, text, 0, nil, &sc, steps)
	charge_steps(h, sc.spent)
	if serr.kind != .None {
		h.fatal = .Exceeded if serr.kind == .Steps else .No_Memory
		return false, false
	}
	return f, true
}

// Runs `rules.judge_string` with a stack-backed `regex.Scratch` when `l.pattern != nil`.
@(private = "file")
run_judge_string :: proc(h: ^Checker, l: ^rules.Leaf, text: string) -> (fails: rules.Failures, ok: bool) {
	if l.pattern == nil {
		sf, rerr := rules.judge_string(l, text, nil, remaining_steps(h), h.scratch)
		if rerr.kind != .None {
			h.fatal = .Exceeded if rerr.kind == .Steps else .No_Memory
			return {}, false
		}
		return sf, true
	}
	room: [REGEX_STACK_ROOM]u8 = ---
	sa := Spill_Arena{fallback = h.scratch}
	mem.arena_init(&sa.stack, room[:])
	spill := runtime.Allocator{spill_proc, &sa}
	sc, merr := regex.scratch_make(spill)
	if merr.kind != .None {
		h.fatal = .No_Memory
		return {}, false
	}
	defer regex.scratch_destroy(&sc)
	sf, rerr := rules.judge_string(l, text, &sc, remaining_steps(h), h.scratch)
	charge_steps(h, sc.spent)
	if rerr.kind != .None {
		h.fatal = .Exceeded if rerr.kind == .Steps else .No_Memory
		return {}, false
	}
	return sf, true
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

// Ultra-fast pure-type scalar pass check directly on the hot 48-byte `Record` (zero `Plan.leaves` load, zero `context`!).
@(private)
fast_scalar_ok :: #force_inline proc "contextless" (r: ^Record, t: tape.Token, is_binary: bool) -> bool #no_bounds_check {
	#partial switch t.kind {
	case .String:
		return .Pure_String in r.fast_flags && .String in r.leaf_kinds
	case .Number:
		if .Pure_Number not_in r.fast_flags {
			return false
		}
		if !is_binary {
			if t.spelling == 0 || (t.spelling & tape.NUMBER_KIND) != 0 {
				return false
			}
			if .Number in r.leaf_kinds {
				return true
			}
			return .Integer in r.leaf_kinds && (t.spelling & ~u16(0x1F0)) == 0
		}
		if t.spelling == 1 {
			return (.Integer in r.leaf_kinds) || (.Number in r.leaf_kinds)
		}
		return t.spelling == 2 && .Number in r.leaf_kinds
	case .True, .False:
		return .Pure_Scalar in r.fast_flags && .Bool in r.leaf_kinds
	case .Null:
		return .Pure_Scalar in r.fast_flags && .Null in r.leaf_kinds
	}
	return false
}

// Primary streaming hook called by format walks (`json`, `toml`, `xml`, `dsv`, `cbor`).
// Because format walks emit constant `t.role`/`t.kind` at each call site, LLVM constant-folds this `#force_inline`
// hook per token kind, avoiding calls and register spills on pure scalars, container opens, skips, and closes!
checker_hook :: #force_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if t.role > .Key {
		return s, .Next
	}
	if h.capture_depth == 0 && !h.has_budget {
		if t.role == .Key {
			return on_key(h, s, t)
		}
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
								if f.run_start == 0 && owner.req_end_u16 < 0xFFFF {
									cur_idx := i32((uintptr(s.b) - uintptr(f.block_start)) / size_of(Record))
									if cur_idx >= i32(owner.req_end_u16) {
										h.sp -= 1
										return after_value(h, {s.a, f.parent_b, s.c}), .Next
									}
								}
							} else if .Required not_in owner.flags {
								h.sp -= 1
								return after_value(h, {s.a, f.parent_b, s.c}), .Next
							} else if owner.members_u16 <= 64 {
								req_mask := h.plan.meta[owner.meta].required_mask
								if (f.seen_mask & req_mask) == req_mask {
									h.sp -= 1
									return after_value(h, {s.a, f.parent_b, s.c}), .Next
								}
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
					if h.sp > 0 && !h.frames[h.sp - 1].is_object {
						h.frames[h.sp - 1].count += 1
					}
					return after_value(h, s), .Next
				}
				return on_value(h, s, t)
			}
			// Fast inline container open for plain non-held records (zero call/spill on `{`, `[`, and `.Skip`!).
			if .Held not_in r.flags && h.sp < len(h.frames) {
				if t.kind == .Object {
					if .Object in r.leaf_kinds && .Pure_Scalar in r.fast_flags {
						if h.sp > 0 && !h.frames[h.sp - 1].is_object {
							h.frames[h.sp - 1].count += 1
						}
						if .Trivial_Object in r.fast_flags && h.dups != .Refuse {
							h.skip_end = true
							return after_value(h, s), .Skip
						}
						can_seq := .Has_Keys not_in r.flags && !h.judge_dups && r.members_u16 > 0 && h.dups != .Refuse && h.dups != .Group
						f := &h.frames[h.sp]
						h.sp += 1
						f.owner = r
						f.parent_b = s.b
						f.block_start = r.first
						f.seen_mask = 0
						f.seen_wide = nil
						f.count = 0
						f.open_at = t.lo
						f.key_name = ""
						f.run_start = 0
						f.tracker_idx = -1
						f.is_object = true
						f.is_factored = false
						f.is_choice = false
						f.is_group_array = false
						f.in_seq = can_seq
						f.key_owned = false
						f.has_tracker = false
						f.saved_failed = false
						next_b := u64(uintptr(r.first)) if can_seq else u64(uintptr(&DEAD_RECORD))
						return {s.a, next_b, s.c}, .Next
					}
				} else {
					if .Array in r.leaf_kinds && .Pure_Scalar in r.fast_flags {
						if h.sp > 0 && !h.frames[h.sp - 1].is_object {
							h.frames[h.sp - 1].count += 1
						}
						if .Trivial_Array in r.fast_flags && h.dups != .Refuse {
							h.skip_end = true
							return after_value(h, s), .Skip
						}
						f := &h.frames[h.sp]
						h.sp += 1
						f.owner = r
						f.parent_b = s.b
						f.block_start = nil
						f.seen_mask = 0
						f.seen_wide = nil
						f.count = 0
						f.open_at = t.lo
						f.key_name = ""
						f.run_start = 0
						f.tracker_idx = -1
						f.is_object = false
						f.is_factored = false
						f.is_choice = false
						f.is_group_array = false
						f.in_seq = false
						f.key_owned = false
						f.has_tracker = false
						f.saved_failed = false
						u := &h.plan.uses[r.meta]
						return {s.a, u64(uintptr(&h.plan.records[u.items])), s.c}, .Next
					}
				}
			}
		}
		return on_value(h, s, t)
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
		h.checker.skip_end = false
		return out, .Next
	}
	return out, act
}

@(private)
checker_step :: proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
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
		return checker_step_capture(h, s, t)
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

@(private = "file")
checker_step_capture :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	done, ok := capture_feed(h, t)
	if !ok || h.fatal != .None {
		return s, .Stop
	}
	if done {
		cap_slot := h.pool.captures[h.capture_depth - 1]
		saved_b := cap_slot.saved_b
		for_factor := cap_slot.for_factor
		passed := capture_finish(h)
		if h.fatal != .None {
			return s, .Stop
		}
		restored := hook.Regs{s.a, saved_b, s.c}
		if !passed {
			if for_factor {
				// Inside a factored object: `capture_finish` marked `fo.failed` and returned false only if doomed!
				fo := factored_at(h, h.nf - 1)
				if !h.need_reread {
					fail_doomed_factored(h, fo)
				}
				return restored, .Stop
			}
			h.failed = true
			if can_stop_early(h) {
				return restored, .Stop
			}
		}
		if for_factor {
			return restored, .Next
		}
		return after_value(h, restored), .Next
	}
	return s, .Next
}

// ============================================================================
// Key handling (`on_key`) — pure `"contextless"` on the happy path!
// ============================================================================

@(private)
on_key :: #force_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if h.sp == 0 {
		return s, .Next
	}
	f := &h.frames[h.sp - 1]
	// Cold paths: synthetic `.Group` array, factored object, previously owned key, or escaped/binary key!
	if f.is_group_array || f.is_factored || f.key_owned || (t.spelling & tape.SPELLING_DECODE != 0) || (t.kind == .Number && h.is_binary) {
		return on_key_cold(h, s, t)
	}

	// Normal object frame with raw slice key (zero allocation, zero `context`!).
	if f.in_seq {
		if !flush_sequential(h, f, s.b) {
			return s, .Stop
		}
	}

	key_str := string(h.src[t.lo:][:t.n])
	f.key_name = key_str
	owner := f.owner
	m := &h.plan.meta[owner.meta]

	idx := member_find(h.plan, m, key_str)
	if idx >= 0 {
		was_seen, seen_ok := frame_mark_seen(h, f, idx)
		if !seen_ok {
			return s, .Stop
		}
		if was_seen {
			if h.judge_dups && h.dups == .First {
				return s, .Skip if h.dups != .Refuse else .Next
			}
			if h.dups == .First || h.dups == .Last || (h.dups == .Group && !h.in_doc_group) {
				h.need_reread = true
				h.dup_hit = true
				return s, .Stop
			}
		}
		f.count += 1
		if .Has_Keys in owner.flags || h.dups == .Group {
			return on_key_named_cold(h, s, t, owner, m, idx, was_seen, key_str)
		}
		rec_idx := int(m.block + idx)
		// Run-resuming `.Expects`: if keys continue in schema order past `idx`, stay in `.Expects` mode!
		if h.dups != .Refuse && !h.judge_dups && m.members <= 64 && idx + 1 < m.members && (f.seen_mask & (~u64(0) << uint(idx + 1))) == 0 {
			f.in_seq = true
			f.run_start = idx + 1
			return {s.a, u64(uintptr(&h.plan.records[rec_idx + 1])), s.c}, .Next
		}
		return {s.a, u64(uintptr(&h.plan.solo[2 * rec_idx + 1])), s.c}, .Next
	}

	// Ultra-fast unnamed-key `.Skip` (zero `Plan.uses` load, zero `context` — e.g. `code-climate`, `aws-cdk`!):
	if .Has_Additional not_in owner.flags && .Has_Keys not_in owner.flags && .Counted not_in owner.flags && !h.judge_dups && h.dups != .Refuse {
		nothing_b := u64(uintptr(&h.plan.records[h.plan.nothing]))
		return {s.a, nothing_b, s.c}, .Skip
	}
	return on_key_unnamed_cold(h, s, t, f, owner, m, key_str, false)
}

@(private = "file")
on_key_named_cold :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, owner: ^Record, m: ^Meta, idx: i32, was_seen: bool, key_str: string) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	if .Has_Keys in owner.flags {
		u := &h.plan.uses[owner.meta]
		kl := &h.plan.leaves[u.keys - 1]
		if !string_passes_leaf(h, kl, key_str, t.lo, owner, true) {
			h.failed = true
			if can_stop_early(h) {
				return s, .Stop
			}
		}
		if h.fatal != .None {
			return s, .Stop
		}
	}
	rec_idx := int(m.block + idx)
	if h.dups == .Group && !h.in_doc_group {
		next_s := hook.Regs{s.a, u64(uintptr(&h.plan.solo[2 * rec_idx + 1])), s.c}
		target_r := &h.plan.records[rec_idx]
		if .Held in target_r.flags && record_accepts_kind(h.plan, i32(rec_idx), .Array, 0) {
			// `.Held` schema that can accept arrays under XML `.Group`: build doc and evaluate with grouped virtual array!
			h.need_reread = true
			return s, .Stop
		}
		if collects_markup(h, target_r) {
			if was_seen {
				h.need_reread = true
				return s, .Stop
			}
			return open_group_array(h, next_s, t.lo, target_r, h.plan.meta[rec_idx].name, false)
		}
		return next_s, .Next
	}
	return {s.a, u64(uintptr(&h.plan.solo[2 * rec_idx + 1])), s.c}, .Next
}

@(private = "file")
on_key_unnamed_cold :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, f: ^Frame, owner: ^Record, m: ^Meta, key_str: string, owned: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	u := &h.plan.uses[owner.meta]
	// Unnamed key: lazily track duplicates ONLY when a repeat of an unnamed key can affect the result!
	// Inside `walk_document_node` under `.Group` (`h.in_doc_group`), tags are already grouped into unique buckets.
	need_unk_track := (h.judge_dups && !h.in_doc_group) || ((h.dups == .First || h.dups == .Last) && (u.keys > 0 || u.pattern > 0 || m.counted || (u.additional > 0 && (!u.add_false || h.sink != nil)))) || (h.dups == .Group && !h.in_doc_group && (u.pattern > 0 || u.additional > 0 || m.counted || u.keys > 0))
	if need_unk_track {
		if !f.has_tracker {
			tidx := open_tracker(h)
			if tidx < 0 {
				h.fatal = .No_Memory
				return s, .Stop
			}
			f.has_tracker = true
			f.tracker_idx = i16(tidx)
		}
		tr := tracker_at(h, int(f.tracker_idx))
		if tracker_has(tr, key_str) {
			if h.judge_dups && h.dups == .First {
				return s, .Skip if h.dups != .Refuse else .Next
			}
			if h.dups == .First || h.dups == .Last || h.dups == .Group {
				h.need_reread = true
				h.dup_hit = true
				return s, .Stop
			}
		} else {
			if !tracker_add(h, tr, key_str, owned) {
				h.fatal = .No_Memory
				return s, .Stop
			}
		}
	}

	f.count += 1

	// `propertyNames` leaf check on unnamed key!
	if u.keys > 0 {
		kl := &h.plan.leaves[u.keys - 1]
		if !string_passes_leaf(h, kl, key_str, t.lo, owner, true) {
			h.failed = true
			if can_stop_early(h) {
				return s, .Stop
			}
		}
		if h.fatal != .None {
			return s, .Stop
		}
	}

	// Inline single `patternProperties` check!
	if u.pattern > 0 && u.regex != nil {
		found, rok := run_regex_search(h, u.regex, key_str)
		if !rok {
			return s, .Stop
		}
		if found {
			next_s := hook.Regs{s.a, u64(uintptr(&h.plan.records[u.pattern])), s.c}
			if h.dups == .Group && !h.in_doc_group {
				target_r := &h.plan.records[u.pattern - 1]
				if .Held in target_r.flags && record_accepts_kind(h.plan, i32(target_r.meta), .Array, 0) {
					h.need_reread = true
					return s, .Stop
				}
				if collects_markup(h, target_r) {
					return open_group_array(h, next_s, t.lo, target_r, key_str, true)
				}
			}
			return next_s, .Next
		}
	}

	// `additionalProperties` check!
	if u.additional > 0 {
		next_s := hook.Regs{s.a, u64(uintptr(&h.plan.records[u.additional])), s.c}
		if h.dups == .Group && !h.in_doc_group {
			target_r := &h.plan.records[u.additional - 1]
			if .Held in target_r.flags && record_accepts_kind(h.plan, i32(target_r.meta), .Array, 0) {
				h.need_reread = true
				return s, .Stop
			}
			if collects_markup(h, target_r) {
				return open_group_array(h, next_s, t.lo, target_r, key_str, true)
			}
		}
		return next_s, .Next
	}

	// No schema for this extra member -> skip its value (or use `Plan.nothing` under `.Refuse`).
	nothing_b := u64(uintptr(&h.plan.records[h.plan.nothing]))
	if h.dups != .Refuse {
		return {s.a, nothing_b, s.c}, .Skip
	}
	return {s.a, nothing_b, s.c}, .Next
}

@(private = "file")
on_key_cold :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	s := s
	// If the top frame is a synthetic `.Group` (XML) array grouping contiguous siblings of the same tag:
	if h.frames[h.sp - 1].is_group_array {
		key_str, owned, ok := token_key_text(h, t)
		if !ok {
			h.fatal = .No_Memory
			return s, .Stop
		}
		same := key_str == h.frames[h.sp - 1].key_name
		if owned {
			delete(key_str, h.scratch)
		}
		if same {
			return s, .Next
		}
		act: hook.Action
		s, act = close_group_array(h, s, t.lo)
		if act == .Stop || h.fatal != .None {
			return s, .Stop
		}
	}
	f := &h.frames[h.sp - 1]
	if f.key_owned {
		delete(f.key_name, h.scratch)
		f.key_owned = false
	}

	if f.is_factored {
		key_str, owned, ok := token_key_text(h, t)
		if !ok {
			h.fatal = .No_Memory
			return s, .Stop
		}
		defer if owned {
			delete(key_str, h.scratch)
		}
		fo := factored_at(h, h.nf - 1)
		skip, doomed := factored_key(h, fo, key_str, owned, t.lo)
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
			return {s.a, u64(uintptr(&h.plan.records[h.plan.nothing])), s.c}, .Next
		}
		return s, .Next
	}

	if f.in_seq {
		if !flush_sequential(h, f, s.b) {
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

	owner := f.owner
	m := &h.plan.meta[owner.meta]

	idx := member_find(h.plan, m, key_str)
	if idx >= 0 {
		was_seen, seen_ok := frame_mark_seen(h, f, idx)
		if !seen_ok {
			return s, .Stop
		}
		if was_seen {
			if h.judge_dups && h.dups == .First {
				return s, .Skip if h.dups != .Refuse else .Next
			}
			if h.dups == .First || h.dups == .Last || (h.dups == .Group && !h.in_doc_group) {
				h.need_reread = true
				h.dup_hit = true
				return s, .Stop
			}
		}
		f.count += 1
		if .Has_Keys in owner.flags || h.dups == .Group {
			return on_key_named_cold(h, s, t, owner, m, idx, was_seen, key_str)
		}
		rec_idx := int(m.block + idx)
		if h.dups != .Refuse && !h.judge_dups && m.members <= 64 && idx + 1 < m.members && (f.seen_mask & (~u64(0) << uint(idx + 1))) == 0 {
			f.in_seq = true
			f.run_start = idx + 1
			return {s.a, u64(uintptr(&h.plan.records[rec_idx + 1])), s.c}, .Next
		}
		return {s.a, u64(uintptr(&h.plan.solo[2 * rec_idx + 1])), s.c}, .Next
	}
	return on_key_unnamed_cold(h, s, t, f, owner, m, key_str, owned)
}

// Flushes sequentially matched `.Expects` members `run_start ..< cur_idx` into `f.seen_mask`/`f.seen_wide` and `f.count`.
@(private)
flush_sequential :: #force_inline proc "contextless" (h: ^Checker, f: ^Frame, cur_b: u64) -> bool #no_bounds_check {
	f.in_seq = false
	cur_idx := int((uintptr(cur_b) - uintptr(f.block_start)) / size_of(Record))
	start := int(f.run_start)
	if cur_idx <= start {
		return true
	}
	members := int(f.owner.members_u16)
	if members == 65535 {
		members = int(h.plan.meta[f.owner.meta].members)
	}
	if cur_idx > members {
		cur_idx = members
	}
	if cur_idx <= start {
		return true
	}
	f.count += u64(cur_idx - start)
	if members <= 64 {
		hi := ~u64(0) if cur_idx == 64 else (u64(1) << uint(cur_idx)) - 1
		lo := (u64(1) << uint(start)) - 1
		f.seen_mask |= hi & ~lo
		return true
	}
	for i in start ..< cur_idx {
		_, ok := frame_mark_seen(h, f, i32(i))
		if !ok {
			return false
		}
	}
	return true
}

// ============================================================================
// Value handling (`on_value`) — pure `"contextless"` on the happy path!
// ============================================================================

@(private)
on_value :: proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if h.sp > 0 && h.frames[h.sp - 1].is_factored {
		return on_value_factored(h, s, t)
	}

	orig_r := (^Record)(uintptr(s.b) - size_of(Record))
	r := orig_r
	if h.sp > 0 && !h.frames[h.sp - 1].is_object {
		h.frames[h.sp - 1].count += 1
	}

	// Held record (has `Use.applies`)?
	if .Held in r.flags {
		if h.sink == nil || h.quiet {
			for hops := 0; hops < 4 && (.Held in r.flags); hops += 1 {
				u := &h.plan.uses[r.meta]
				if u.verdict_rec > 0 {
					r = &h.plan.records[u.verdict_rec - 1]
					continue
				}
				// Disjoint-kind single-arm streaming redirect for `oneOf`/`anyOf` containers (e.g. `pulumi` `runtime`/`config`)!
				if t.kind == .Object {
					if u.obj_arm > 0 {
						r = &h.plan.records[u.obj_arm - 1]
						continue
					}
					if u.obj_arm < 0 {
						return fail_disjoint_arm(h, s, t, orig_r, r)
					}
				} else if t.kind == .Array {
					if u.arr_arm > 0 {
						r = &h.plan.records[u.arr_arm - 1]
						continue
					}
					if u.arr_arm < 0 {
						return fail_disjoint_arm(h, s, t, orig_r, r)
					}
				}
				break
			}
		}
		if .Held in r.flags {
			// In non-quiet mode, if a redirect landed on a non-factored still-`.Held` arm (e.g. `not`/`if`),
			// revert to `orig_r` so `on_value_held` preserves exact `instance_location` & `keyword_location`.
			// (Redirected `.Factored` objects keep `orig_r` via `f.parent_b = s.b`.)
			if !h.quiet && r != orig_r && !(.Factored in r.flags && t.kind == .Object && !h.no_factor && !h.judge_dups) {
				r = orig_r
			}
			return on_value_held(h, s, t, r)
		}
	}

	// Plain `.Checked` record!
	if t.kind != .Object && t.kind != .Array {
		if fast_scalar_ok(r, t, h.is_binary) {
			return after_value(h, s), .Next
		}
		if r.rule_set > 0 {
			return on_value_scalar_slow(h, s, t, r)
		}
		return after_value(h, s), .Next
	}

	return open_container(h, s, t, r, is_choice = false)
}

@(private = "file", cold)
fail_disjoint_arm :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, orig_owner: ^Record, cur_owner: ^Record) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	u := &h.plan.uses[cur_owner.meta]
	aps := u.verdict if len(u.verdict) > 0 else u.applies
	kw := aps[0].keyword if len(aps) > 0 else "anyOf"
	alt_site := h.plan.uses[cur_owner.meta].site if cur_owner.meta != orig_owner.meta else nil
	record_first_failure(h, .No_Arm, t.lo, kw, "", orig_owner, alt_site = alt_site)
	h.failed = true
	if can_stop_early(h) {
		return s, .Stop
	}
	if h.dups != .Refuse {
		h.skip_end = true
		return after_value(h, s), .Skip
	}
	nothing := &h.plan.records[h.plan.nothing - 1]
	return open_container(h, s, t, nothing, is_choice = false)
}

@(private = "file")
on_value_scalar_slow :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, r: ^Record) -> (hook.Regs, hook.Action) #no_bounds_check {
	l := &h.plan.leaves[r.rule_set - 1]
	// Fast `"contextless"` ASCII string length check (no pattern, no format, no enum — e.g. `minLength: 1` in `aws-cdk`, `pulumi`!):
	if t.kind == .String && (t.spelling & tape.SPELLING_ASCII != 0) && (t.spelling & tape.SPELLING_DECODE == 0) && .String in l.kinds && l.pattern == nil && l.formats == {} && !l.has_enum {
		if u64(t.n) >= l.min_length && u64(t.n) <= l.max_length {
			return after_value(h, s), .Next
		}
	}
	// Fast `"contextless"` plain decimal integer bounds check (no multipleOf, no enum — e.g. `geojson`, `citm`, `draft-04`!):
	if t.kind == .Number && !h.is_binary && l.fast && t.spelling != 0 && (t.spelling & ~u16(0x1F0)) == 0 && (.Number in l.kinds || .Integer in l.kinds) {
		int_digits := (t.spelling >> 4) & 31
		if int_digits <= 18 && t.n > 0 {
			p := h.src[t.lo:][:t.n]
			neg := p[0] == '-'
			v := i64(0)
			for i := 1 if neg else 0; i < len(p); i += 1 {
				v = v * 10 + i64(p[i] - '0')
			}
			if neg {
				v = -v
			}
			ok := true
			if l.minimum.set && (v < l.minimum.int || (v == l.minimum.int && l.minimum.exclusive)) {
				ok = false
			}
			if l.maximum.set && (v > l.maximum.int || (v == l.maximum.int && l.maximum.exclusive)) {
				ok = false
			}
			if ok {
				return after_value(h, s), .Next
			}
		}
	}
	context = h.ctx^
	orig_r := (^Record)(uintptr(s.b) - size_of(Record))
	err_owner := orig_r if r.meta != orig_r.meta else r
	alt_site := h.plan.uses[r.meta].site if r.meta != orig_r.meta else nil
	if !judge_scalar_token(h, l, t, err_owner, alt_site) {
		h.failed = true
		if can_stop_early(h) {
			return s, .Stop
		}
	}
	if h.fatal != .None {
		return s, .Stop
	}
	return after_value(h, s), .Next
}

@(private = "file")
on_value_factored :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	fo := factored_at(h, h.nf - 1)
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
			h.skip_end = true
			return s, .Skip
		}
		nothing := &h.plan.records[h.plan.nothing - 1]
		return open_container(h, s, t, nothing, is_choice = false)
	}
	if use_fork {
		if !capture_start(h, fo.owner, t.lo, s.b, for_factor = true, fm = fo.active_member) {
			return s, .Stop
		}
		_, ok := capture_feed(h, t)
		if !ok {
			return s, .Stop
		}
		return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next
	}
	return open_container(h, s, t, choice_rec, is_choice = true)
}

@(private = "file")
on_value_held :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, r: ^Record) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	u := &h.plan.uses[r.meta]
	// Under streaming XML `.Group`, fall back to built-document grouping for `.Factored` / `.Held` objects
	// so repeated siblings and virtual array members are grouped cleanly!
	if h.dups == .Group && !h.in_doc_group && t.kind == .Object {
		h.need_reread = true
		return s, .Stop
	}
	// Stage 1-4: factored held object fast path!
	if .Factored in r.flags && t.kind == .Object && !h.no_factor && !h.judge_dups {
		if factored_open(h, r, u.factor, t.lo) {
			f := frame_push_slot(h)
			if f == nil {
				h.nf -= 1
				return s, .Stop
			}
			f^ = Frame{
				is_object = true,
				is_factored = true,
				owner = r,
				parent_b = s.b,
				open_at = t.lo,
				tracker_idx = -1,
			}
			return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next
		}
		if h.fatal != .None {
			return s, .Stop
		}
	}
	if t.kind != .Object && t.kind != .Array {
		if !eval_held_scalar(h, r, t) {
			h.failed = true
			if can_stop_early(h) {
				return s, .Stop
			}
		}
		if h.fatal != .None {
			return s, .Stop
		}
		return after_value(h, s), .Next
	}
	if !capture_start(h, r, t.lo, s.b) {
		return s, .Stop
	}
	_, ok := capture_feed(h, t)
	if !ok {
		return s, .Stop
	}
	return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next
}

@(private)
open_container :: proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, r: ^Record, is_choice: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	max_depth := int(h.budget.depth) if h.budget.depth > 0 else int(tape.DEFAULT_DEPTH)
	if h.sp + h.nest_depth >= max_depth {
		h.fatal = .Exceeded
		return s, .Stop
	}

	r := r
	if is_choice && .Held in r.flags {
		for hops := 0; hops < 4 && (.Held in r.flags); hops += 1 {
			u := &h.plan.uses[r.meta]
			if u.verdict_rec > 0 {
				r = &h.plan.records[u.verdict_rec - 1]
				continue
			}
			if t.kind == .Object && u.obj_arm > 0 {
				r = &h.plan.records[u.obj_arm - 1]
				continue
			}
			if t.kind == .Array && u.arr_arm > 0 {
				r = &h.plan.records[u.arr_arm - 1]
				continue
			}
			break
		}
	}
	if is_choice && .Held in r.flags {
		return open_choice_held_cold(h, s, t, r)
	}

	is_obj := t.kind == .Object
	want := rules.Kind.Object if is_obj else rules.Kind.Array
	if want not_in r.leaf_kinds || (r.rule_set > 0 && .Pure_Scalar not_in r.fast_flags) {
		if r.rule_set > 0 {
			l := &h.plan.leaves[r.rule_set - 1]
			if want not_in l.kinds || l.has_enum {
				out, act, handled := open_container_type_err(h, s, t, r, l, is_obj, is_choice)
				if handled {
					return out, act
				}
			}
		}
	}

	if is_obj {
		if .Trivial_Object in r.fast_flags && h.dups != .Refuse && !is_choice {
			h.skip_end = true
			return after_value(h, s), .Skip
		}
		block_start := r.first
		can_seq := .Has_Keys not_in r.flags && !h.judge_dups && r.members_u16 > 0 && h.dups != .Refuse && h.dups != .Group
		saved_failed := h.failed
		f := frame_push_slot(h)
		if f == nil {
			return s, .Stop
		}
		if is_choice {
			h.failed = false
			h.choice_depth += 1
		}
		f.owner = r
		f.parent_b = s.b
		f.block_start = block_start
		f.seen_mask = 0
		f.seen_wide = nil
		f.count = 0
		f.open_at = t.lo
		f.key_name = ""
		f.run_start = 0
		f.tracker_idx = -1
		f.is_object = true
		f.is_factored = false
		f.is_choice = is_choice
		f.is_group_array = false
		f.in_seq = can_seq
		f.key_owned = false
		f.has_tracker = false
		f.saved_failed = saved_failed
		next_b := u64(uintptr(block_start)) if can_seq else u64(uintptr(&DEAD_RECORD))
		return {s.a, next_b, s.c}, .Next
	}

	// Array open!
	if .Trivial_Array in r.fast_flags && h.dups != .Refuse && !is_choice {
		h.skip_end = true
		return after_value(h, s), .Skip
	}
	u := &h.plan.uses[r.meta]
	saved_failed := h.failed
	f := frame_push_slot(h)
	if f == nil {
		return s, .Stop
	}
	if is_choice {
		h.failed = false
		h.choice_depth += 1
	}
	f.owner = r
	f.parent_b = s.b
	f.block_start = nil
	f.seen_mask = 0
	f.seen_wide = nil
	f.count = 0
	f.open_at = t.lo
	f.key_name = ""
	f.run_start = 0
	f.tracker_idx = -1
	f.is_object = false
	f.is_factored = false
	f.is_choice = is_choice
	f.is_group_array = false
	f.in_seq = false
	f.key_owned = false
	f.has_tracker = false
	f.saved_failed = saved_failed
	return {s.a, u64(uintptr(&h.plan.records[u.items])), s.c}, .Next
}

@(private = "file", cold)
open_choice_held_cold :: #force_no_inline proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token, r: ^Record) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx^
	u := &h.plan.uses[r.meta]
	if .Factored in r.flags && t.kind == .Object && !h.no_factor && !h.judge_dups {
		if factored_open(h, r, u.factor, t.lo) {
			f := frame_push_slot(h)
			if f == nil {
				h.nf -= 1
				return s, .Stop
			}
			f^ = Frame{
				is_object = true,
				is_factored = true,
				is_choice = true,
				owner = r,
				parent_b = s.b,
				open_at = t.lo,
				tracker_idx = -1,
			}
			h.choice_depth += 1
			return {s.a, u64(uintptr(&DEAD_RECORD)), s.c}, .Next
		}
		if h.fatal != .None {
			return s, .Stop
		}
	}
	if !capture_start(h, r, t.lo, s.b, for_factor = true, fm = factored_at(h, h.nf - 1).active_member) {
		return s, .Stop
	}
	_, ok := capture_feed(h, t)
	if !ok {
		return s, .Stop
	}
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
	if !is_choice {
		orig_r := (^Record)(uintptr(s.b) - size_of(Record)) if (s.b != 0 && s.b != u64(uintptr(&DEAD_RECORD))) else r
		err_owner := orig_r if r.meta != orig_r.meta else r
		alt_site := h.plan.uses[r.meta].site if r.meta != orig_r.meta else nil
		if h.sink != nil && !h.quiet {
			record_failure(h, kind, t.lo, kw, exp, err_owner, alt_site = alt_site)
		} else {
			record_first_failure(h, kind, t.lo, kw, exp, err_owner, alt_site = alt_site)
		}
		h.failed = true
	}
	if is_choice {
		fo := factored_at(h, h.nf - 1)
		if fo.active_member != nil && fo.active_choice >= 0 {
			fo.failed |= fo.active_member.choices[fo.active_choice].parts
		}
		fo.active_member = nil
		fo.active_choice = -1
		if can_doom_factored(h, fo.factor, fo.failed) {
			fail_doomed_factored(h, fo)
			return s, .Stop, true
		}
		if h.dups != .Refuse {
			h.skip_end = true
			return s, .Skip, true
		}
		nothing := &h.plan.records[h.plan.nothing - 1]
		out, act := open_container(h, s, t, nothing, is_choice = false)
		return out, act, true
	} else if can_stop_early(h) {
		return s, .Stop, true
	}
	return s, .Next, false
}

// ============================================================================
// Container close (`on_end`) — pure `"contextless"` on the happy path!
// ============================================================================

@(private)
on_end :: proc "contextless" (h: ^Checker, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if h.skip_end {
		h.skip_end = false
		return s, .Next
	}
	if h.sp == 0 {
		return s, .Next
	}
	top := &h.frames[h.sp - 1]
	if top.is_group_array || top.is_factored || top.key_owned || len(top.seen_wide) > 0 || top.has_tracker {
		return on_end_cold(h, s, t)
	}
	h.sp -= 1
	f := &h.frames[h.sp]
	owner := f.owner

	if f.is_object {
		if f.in_seq && f.run_start == 0 && .Counted not_in owner.flags && .Has_Deps not_in owner.fast_flags && owner.req_end_u16 < 0xFFFF {
			cur_idx := i32((uintptr(s.b) - uintptr(f.block_start)) / size_of(Record))
			if cur_idx >= i32(owner.req_end_u16) {
				if h.failed && !f.is_choice && can_stop_early(h) {
					return s, .Stop
				}
				if f.is_choice && h.nf > 0 {
					return finish_choice_close_ctx(h, f, s, false)
				}
				return after_value(h, {s.a, f.parent_b, s.c}), .Next
			}
		}
		if f.in_seq {
			if !flush_sequential(h, f, s.b) {
				return s, .Stop
			}
		}
		// Fast happy-path object close (no counts, required satisfied via bitmask, no deps, no seen_wide)!
		if len(f.seen_wide) == 0 && .Counted not_in owner.flags && .Has_Deps not_in owner.fast_flags {
			req_ok := .Required not_in owner.flags
			if !req_ok && owner.members_u16 <= 64 {
				req_mask := h.plan.meta[owner.meta].required_mask
				req_ok = (f.seen_mask & req_mask) == req_mask
			}
			if req_ok {
				if h.failed && !f.is_choice && can_stop_early(h) {
					return s, .Stop
				}
				if f.is_choice && h.nf > 0 {
					return finish_choice_close_ctx(h, f, s, false)
				}
				return after_value(h, {s.a, f.parent_b, s.c}), .Next
			}
		}
		return on_end_settle_cold(h, f, s, t)
	}

	// Array close!
	if .Pure_Array in owner.fast_flags || owner.rule_set == 0 {
		if f.is_choice && h.nf > 0 {
			return finish_choice_close_ctx(h, f, s, false)
		}
		return after_value(h, {s.a, f.parent_b, s.c}), .Next
	}
	l := &h.plan.leaves[owner.rule_set - 1]
	if f.count >= l.min_items && f.count <= l.max_items {
		if f.is_choice && h.nf > 0 {
			return finish_choice_close_ctx(h, f, s, false)
		}
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
		if act == .Stop || h.fatal != .None {
			return s, .Stop
		}
		if h.sp == 0 {
			return s, .Next
		}
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
	if f.has_tracker {
		close_tracker(h)
	}
	if f.is_factored {
		if f.is_choice {
			h.choice_depth -= 1
		}
		passed, owner, open_at := factored_close(h)
		if !passed {
			if f.is_choice && h.nf > 0 {
				outer_fo := factored_at(h, h.nf - 1)
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
			if h.sink != nil && !h.quiet {
				h.need_reread = true
				h.reread_runs = true
				return s, .Stop
			}
			h.failed = true
			err_owner := owner
			alt_site: []tape.Step
			if !f.is_choice && f.parent_b != 0 && f.parent_b != u64(uintptr(&DEAD_RECORD)) {
				orig := (^Record)(uintptr(f.parent_b) - size_of(Record))
				if orig.meta != owner.meta {
					err_owner = orig
					alt_site = h.plan.uses[owner.meta].site
				}
			}
			record_first_failure(h, .No_Arm, open_at, "anyOf", "", err_owner, alt_site = alt_site)
			if can_stop_early(h) {
				return s, .Stop
			}
			return after_value(h, {s.a, f.parent_b, s.c}), .Next
		}
		if f.is_choice && h.nf > 0 {
			outer_fo := factored_at(h, h.nf - 1)
			outer_fo.active_member = nil
			outer_fo.active_choice = -1
			return {s.a, f.parent_b, s.c}, .Next
		}
		return after_value(h, {s.a, f.parent_b, s.c}), .Next
	}
	if f.is_object && f.in_seq {
		if !flush_sequential(h, f, s.b) {
			return s, .Stop
		}
	}
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
	err_owner := owner
	alt_site: []tape.Step
	if !f.is_choice && f.parent_b != 0 && f.parent_b != u64(uintptr(&DEAD_RECORD)) {
		orig := (^Record)(uintptr(f.parent_b) - size_of(Record))
		if orig.meta != owner.meta {
			err_owner = orig
			alt_site = h.plan.uses[owner.meta].site
		}
	}
	choice_failed := false

	if f.is_object {
		if .Counted in owner.flags {
			l := &h.plan.leaves[owner.rule_set - 1]
			fails := rules.judge_count(f.count, l.min_members, l.max_members)
			if fails != {} {
				choice_failed = true
				if !f.is_choice {
					emit_leaf_failures(h, l, fails, f.open_at, err_owner, true, alt_site)
					h.failed = true
					if can_stop_early(h) {
						return s, .Stop
					}
				}
			}
		}
		if .Required in owner.flags {
			m := &h.plan.meta[owner.meta]
			if m.members > 0 {
				if m.members > 64 || (f.seen_mask & m.required_mask) != m.required_mask {
					end_m := &h.plan.meta[m.block + m.members]
					for req_idx in end_m.required {
						if !frame_is_seen(f, req_idx) {
							choice_failed = true
							if !f.is_choice {
								req_name := h.plan.meta[m.block + req_idx].name
								if h.sink != nil && !h.quiet {
									record_failure(h, .Missing_Field, f.open_at, "required", req_name, err_owner, alt_site = alt_site)
								} else {
									record_first_failure(h, .Missing_Field, f.open_at, "required", req_name, err_owner, alt_site = alt_site)
								}
								h.failed = true
								if can_stop_early(h) {
									return s, .Stop
								}
							}
						}
					}
				}
			}
			if .Has_Deps in owner.fast_flags {
				u := &h.plan.uses[owner.meta]
				for req in u.requires {
					if frame_is_seen(f, req.trigger) {
						for want_idx in req.wants {
							if !frame_is_seen(f, want_idx) {
								choice_failed = true
								if !f.is_choice {
									want_name := h.plan.meta[m.block + want_idx].name
									if h.sink != nil && !h.quiet {
										record_failure(h, .Missing_Field, f.open_at, req.keyword, want_name, err_owner, alt_site = alt_site)
									} else {
										record_first_failure(h, .Missing_Field, f.open_at, req.keyword, want_name, err_owner, alt_site = alt_site)
									}
									h.failed = true
									if can_stop_early(h) {
										return s, .Stop
									}
								}
							}
						}
					}
				}
			}
		}
		if h.failed && !f.is_choice && can_stop_early(h) {
			return s, .Stop
		}
	} else {
		if .Pure_Array not_in owner.fast_flags && owner.rule_set > 0 {
			l := &h.plan.leaves[owner.rule_set - 1]
			fails := rules.judge_count(f.count, l.min_items, l.max_items)
			if fails != {} {
				choice_failed = true
				if !f.is_choice {
					emit_leaf_failures(h, l, fails, f.open_at, err_owner, false, alt_site)
					h.failed = true
					if can_stop_early(h) {
						return s, .Stop
					}
				}
			}
		}
	}

	if f.is_choice && h.nf > 0 {
		return finish_choice_close(h, f, s, choice_failed)
	}

	return after_value(h, {s.a, f.parent_b, s.c}), .Next
}

@(private = "file")
finish_choice_close :: proc(h: ^Checker, f: ^Frame, s: hook.Regs, choice_failed: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	h.choice_depth -= 1
	failed_here := choice_failed || h.failed
	h.failed = f.saved_failed
	outer_fo := factored_at(h, h.nf - 1)
	if failed_here && outer_fo.active_member != nil && outer_fo.active_choice >= 0 {
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

@(private = "file")
can_stop_early :: #force_inline proc "contextless" (h: ^Checker) -> bool {
	return (h.sink == nil || h.quiet) && h.choice_depth == 0 && !defer_last_stop(h)
}

// Whether `r` collects sibling elements of the same name into an array under `.Group` (XML),
// matching v1 `core/typed/markup.odin:collects`.
@(private)
collects_markup :: #force_inline proc "contextless" (h: ^Checker, r: ^Record) -> bool #no_bounds_check {
	if r == nil || .Held in r.flags {
		return false
	}
	u := &h.plan.uses[r.meta]
	if r.rule_set == 0 {
		return u.inside
	}
	l := &h.plan.leaves[r.rule_set - 1]
	if l.kinds - {.Null} == {.Array} {
		return true
	}
	return l.kinds == rules.EVERY_KIND && (u.inside || l.min_items > 0 || l.max_items < max(u64))
}

// Whether `r` (plain OR `.Held`) collects a lone sibling element of the same name into a 1-element array under XML `.Group`.
@(private)
collects_markup_any :: proc(h: ^Checker, r: ^Record) -> bool {
	if r == nil {
		return false
	}
	if .Held not_in r.flags {
		return collects_markup(h, r)
	}
	idx := i32(r.meta)
	if !record_accepts_kind(h.plan, idx, .Array, 0) {
		return false
	}
	for k in ([?]rules.Kind{.Object, .String, .Number, .Integer, .Bool}) {
		if record_accepts_kind(h.plan, idx, k, 0) {
			return false
		}
	}
	return true
}

// Whether a factored object's member `fm` collects a lone XML sibling into a 1-element array under `.Group`.
@(private)
fm_collects_markup :: proc(h: ^Checker, fm: ^Factor_Member) -> bool {
	if fm == nil || fm.table != nil || (len(fm.leaves) == 0 && len(fm.choices) == 0) {
		return false
	}
	for fl in fm.leaves {
		l := &h.plan.leaves[fl.leaf - 1]
		if l.kinds - {.Null} != {.Array} {
			return false
		}
	}
	for ch in fm.choices {
		if !collects_markup_any(h, &h.plan.records[ch.record]) {
			return false
		}
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
	stored_key := key_name
	owned := false
	if clone_key {
		cp, cerr := strings.clone(key_name, h.scratch)
		if cerr != nil {
			h.fatal = .No_Memory
			return s, .Stop
		}
		stored_key = cp
		owned = true
	}
	if !push_frame(h, Frame{
		is_object = false,
		is_group_array = true,
		owner = r,
		parent_b = s.b,
		open_at = at,
		key_name = stored_key,
		key_owned = owned,
	}) {
		if owned {
			delete(stored_key, h.scratch)
		}
		return s, .Stop
	}
	u := &h.plan.uses[r.meta]
	return {s.a, u64(uintptr(&h.plan.records[u.items])), s.c}, .Next
}

// Closes the top synthetic `.Group` (XML) array frame, checking `minItems`/`maxItems`.
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
		fails := rules.judge_count(f.count, l.min_items, l.max_items)
		if fails != {} {
			emit_leaf_failures(h, l, fails, f.open_at, owner, false)
			h.failed = true
			if can_stop_early(h) {
				return s, .Stop
			}
		}
	}
	return after_value(h, {s.a, f.parent_b, s.c}), .Next
}

// Under `.Last` (or `.Group`), when a member inside an open object fails before the object closes, we defer early `.Stop`
// until the object closes so a later duplicate/grouped sibling of the same key can be detected.
@(private = "file")
defer_last_stop :: #force_inline proc "contextless" (h: ^Checker) -> bool {
	return (h.dups == .Last || h.dups == .Group) && !h.judge_dups && h.sp > 0 && h.frames[h.sp - 1].is_object && !h.frames[h.sp - 1].is_factored
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
judge_scalar_token :: proc(h: ^Checker, l: ^rules.Leaf, t: tape.Token, owner: ^Record, alt_site: []tape.Step = nil) -> bool {
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
	emit_leaf_failures(h, l, fails, t.lo, owner, false, alt_site)
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
	fails := judge_scalar_core(h, l, kind, text, t, plain_num, has_plain_num)
	return h.fatal == .None && fails == {}
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
				return strconv.write_float(buf, f, 'g', -1, 64, {}), false, true
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
			} else if !h.is_binary && t.spelling != 0 && (t.spelling & ~u16(0x1F0)) == 0 {
				// Fast plain decimal integer path (JSON/JSONC/JSON5 integer with 0 frac digits, no exp, no point)!
				is_int = true
				if l.minimum.set || l.maximum.set || l.multiple_of != nil || l.has_enum {
					int_digits := (t.spelling >> 4) & 31
					if int_digits <= 18 && len(num_text) > 0 {
						p := raw_data(num_text)
						neg := p[0] == '-'
						v := i64(0)
						for i := 1 if neg else 0; i < len(num_text); i += 1 {
							v = v * 10 + i64(p[i] - '0')
						}
						if neg {
							v = -v
						}
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
				} else {
					return fails
				}
			} else if (t.spelling != 0 || h.is_binary) && h.format != nil && h.format.number != nil {
				// Non-plain number spelling (JSON5 hex/leading-dot/plus/NaN/Inf, TOML hex/oct/bin/underscores/nan/inf, CBOR binary)!
				num := h.format.number(h.src, tape.Node(t))
				need_text := l.minimum.set || l.maximum.set || l.multiple_of != nil || l.has_enum
				switch num.kind {
				case .Int:
					small = i64(num.bits)
					is_int = true
					if need_text && !l.fast {
						num_text = strconv.write_int(num_buf[:], i64(num.bits), 10)
					}
				case .Uint:
					if num.bits <= u64(max(i64)) {
						small = i64(num.bits)
					}
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
			sf, sok := run_judge_string(h, l, text)
			if !sok {
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
		sf, sok := run_judge_string(h, l, text)
		if !sok {
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
emit_leaf_failures :: proc(h: ^Checker, l: ^rules.Leaf, fails: rules.Failures, at: u64, owner: ^Record, members: bool, alt_site: []tape.Step = nil) {
	for k in fails {
		kw := keyword_of_kind(k, l, members)
		exp := rules.operand_text(l, k, members, h.scratch)
		defer if len(exp) > 0 {
			delete(exp, h.scratch)
		}
		if h.sink != nil && !h.quiet {
			record_failure(h, k, at, kw, exp, owner, alt_site = alt_site)
		} else {
			record_first_failure(h, k, at, kw, exp, owner, alt_site = alt_site)
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
subcheck_node :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, rec_idx: i32, extra_path: []tape.Step, owner: ^Record, quiet: bool) -> bool #no_bounds_check {
	// Ultra-fast direct scalar path: avoids 4 KiB `Checker` + `walk_document_node` per `oneOf`/`anyOf` arm (e.g. `pulumi`)!
	tok := doc.nodes[node]
	if tok.kind <= .Plain && h.budget.nodes == 0 {
		rec := &h.plan.records[rec_idx]
		if .Held in rec.flags && (quiet || h.quiet || h.sink == nil) {
			for hops := 0; hops < 4 && (.Held in rec.flags); hops += 1 {
				vr := h.plan.uses[rec.meta].verdict_rec
				if vr <= 0 {
					break
				}
				rec = &h.plan.records[vr - 1]
			}
		}
		if .Held not_in rec.flags {
			if rec.rule_set == 0 {
				return true
			}
			is_bin := doc.format != nil && .Binary in doc.format.caps
			if fast_scalar_ok(rec, tok, is_bin) {
				return true
			}
			if quiet || h.quiet {
				// Fast kind rejection before loading full leaf!
				if tok.kind != .Plain {
					#partial switch tok.kind {
					case .String:
						if .String not_in rec.leaf_kinds {
							return false
						}
					case .Number:
						if (.Number not_in rec.leaf_kinds) && (.Integer not_in rec.leaf_kinds) {
							return false
						}
					case .True, .False:
						if .Bool not_in rec.leaf_kinds {
							return false
						}
					case .Null:
						if .Null not_in rec.leaf_kinds {
							return false
						}
					}
				}
				if doc.src == nil || raw_data(doc.src) == raw_data(h.src) {
					return scalar_passes_leaf(h, &h.plan.leaves[rec.rule_set - 1], tok)
				}
			}
		}
	}

	max_depth := int(h.budget.depth) if h.budget.depth > 0 else int(tape.DEFAULT_DEPTH)
	if h.sp + h.nest_depth >= max_depth {
		h.fatal = .Exceeded
		return false
	}

	emit := h.sink != nil && !quiet && !h.quiet

	sub: Checker = ---
	memo: hook.Expected_Memo = ---
	ctx := context
	sub_opts := Options{dups = h.dups, budget = h.budget, scratch = h.scratch}
	_ = checker_start(&sub, h.plan, doc.src, doc.format, sub_opts, h.sink if emit else nil, &memo, h.allocator, h.scratch, h.mem_budget, &ctx)
	sub.xml_ext = doc.ext
	sub.steps_used = h.steps_used
	sub.nodes_seen = h.nodes_seen
	sub.quiet = quiet || h.quiet
	sub.no_factor = h.no_factor
	sub.pool = h.pool
	sub.owns_pool = false
	sub.nf = h.nf
	sub.parent = h
	sub.parent_owner = owner
	sub.parent_extra = extra_path
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
subcheck_key_string :: proc(h: ^Checker, key_str: string, doc: ^tape.Document, rec_idx: i32, owner: ^Record, quiet: bool) -> bool {
	key_bytes := transmute([]u8)key_str
	nodes := [1]tape.Node{tape.Node{lo = 0, n = u32(len(key_bytes)), kind = .String, role = .Value}}
	synth := tape.Document{src = key_bytes, nodes = nodes[:], format = doc.format}
	return subcheck_node(h, &synth, 0, rec_idx, nil, owner, quiet)
}

// Explicit-stack traversal of `doc` starting at `root_node` judged by `root_rec`.
// Handles all 5 formats including XML `.Group` (contiguous & non-contiguous, plain / `.Held` / `.Factored`),
// DSV `Tabular_Ext`, and CBOR binary numbers with ZERO unbounded recursion and ZERO redundant `build.Builder` re-captures!
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
		grouped:       []Group_Bucket, // for XML `.Group` objects: one bucket per distinct tag name!
		grouped_pos:   int,
	}

	free_grouped :: proc(h: ^Checker, buckets: []Group_Bucket) {
		for gb in buckets {
			delete(gb.vals, h.scratch)
		}
		delete(buckets, h.scratch)
	}

	free_synthetic_doc :: proc(h: ^Checker, sdoc: ^tape.Document) {
		if sdoc == nil {
			return
		}
		delete(sdoc.nodes, h.scratch)
		delete(sdoc.counts, h.scratch)
		free(sdoc, h.scratch)
	}

	build_synthetic_array_doc :: proc(h: ^Checker, src_doc: ^tape.Document, vals: []tape.Node_Index) -> (^tape.Document, bool) {
		total := 1
		for v in vals {
			vn := src_doc.nodes[v]
			sz := int(vn.n) if (vn.kind == .Object || vn.kind == .Array) else 1
			total += sz
		}
		nodes, nerr := make([]tape.Node, total, h.scratch)
		if nerr != nil {
			h.fatal = .No_Memory
			return nil, false
		}
		sdoc, derr := new(tape.Document, h.scratch)
		if derr != nil {
			delete(nodes, h.scratch)
			h.fatal = .No_Memory
			return nil, false
		}
		counts := make([dynamic]tape.Child_Count, h.scratch)
		sp: u16
		if len(vals) >= int(tape.MAX_CHILDREN) {
			sp = tape.MAX_CHILDREN
			if _, cerr := append(&counts, tape.Child_Count{node = 0, count = u32(len(vals))}); cerr != nil {
				delete(counts)
				delete(nodes, h.scratch)
				free(sdoc, h.scratch)
				h.fatal = .No_Memory
				return nil, false
			}
		} else {
			sp = u16(len(vals))
		}
		first_lo := src_doc.nodes[vals[0]].lo if len(vals) > 0 else 0
		nodes[0] = tape.Node{lo = first_lo, n = u32(total), kind = .Array, role = .Value, spelling = sp}
		pos := 1
		for v in vals {
			vn := src_doc.nodes[v]
			sz := int(vn.n) if (vn.kind == .Object || vn.kind == .Array) else 1
			copy(nodes[pos:][:sz], src_doc.nodes[v:][:sz])
			if len(src_doc.counts) > 0 {
				v_end := v + tape.Node_Index(sz)
				for cc in src_doc.counts {
					if cc.node >= v && cc.node < v_end {
						if _, cerr := append(&counts, tape.Child_Count{node = tape.Node_Index(pos) + (cc.node - v), count = cc.count}); cerr != nil {
							delete(counts)
							delete(nodes, h.scratch)
							free(sdoc, h.scratch)
							h.fatal = .No_Memory
							return nil, false
						}
					}
				}
			}
			pos += sz
		}
		sdoc^ = tape.Document{
			src = src_doc.src,
			nodes = nodes,
			counts = counts[:],
			format = src_doc.format,
			ext = src_doc.ext,
		}
		return sdoc, true
	}

	build_group_buckets :: proc(h: ^Checker, r: tape.Reader, cur_doc: ^tape.Document, it: ^tape.Children) -> ([]Group_Bucket, bool) {
		Slot :: struct {
			kt:   tape.Token,
			vals: [dynamic]tape.Node_Index,
		}
		slots := make([dynamic]Slot, h.scratch)
		names := make([dynamic]string, h.scratch)
		owned := make([dynamic]bool, h.scratch)
		index := make(map[string]int, 8, h.scratch)
		defer {
			for nm, i in names {
				if owned[i] {
					delete(nm, h.scratch)
				}
			}
			delete(names)
			delete(owned)
			delete(index)
			delete(slots)
		}
		for {
			kn, vn, cp := tape.next_child(r, it, .Group)
			if cp != .Found {
				break
			}
			kt := tape.cell_key(r, it^) if (kn == tape.NO_NODE && it.keys_n != 0) else cur_doc.nodes[kn]
			ks, kown, kok := doc_token_text(cur_doc, kt, h.scratch)
			if !kok {
				for &sl in slots {
					delete(sl.vals)
				}
				h.fatal = .No_Memory
				return nil, false
			}
			append(&names, ks)
			append(&owned, kown)
			if si, exists := index[ks]; exists {
				if _, aerr := append(&slots[si].vals, vn); aerr != nil {
					for &sl in slots {
						delete(sl.vals)
					}
					h.fatal = .No_Memory
					return nil, false
				}
			} else {
				vl, verr := make([dynamic]tape.Node_Index, 0, 1, h.scratch)
				if verr != nil {
					for &sl in slots {
						delete(sl.vals)
					}
					h.fatal = .No_Memory
					return nil, false
				}
				if _, aerr := append(&vl, vn); aerr != nil {
					delete(vl)
					for &sl in slots {
						delete(sl.vals)
					}
					h.fatal = .No_Memory
					return nil, false
				}
				index[ks] = len(slots)
				if _, serr := append(&slots, Slot{kt = kt, vals = vl}); serr != nil {
					delete(vl)
					for &sl in slots {
						delete(sl.vals)
					}
					h.fatal = .No_Memory
					return nil, false
				}
			}
		}
		out, oerr := make([]Group_Bucket, len(slots), h.scratch)
		if oerr != nil {
			for &sl in slots {
				delete(sl.vals)
			}
			h.fatal = .No_Memory
			return nil, false
		}
		for sl, i in slots {
			out[i] = Group_Bucket{kt = sl.kt, vals = sl.vals[:]}
		}
		return out, true
	}

	saved_in_doc_group := h.in_doc_group
	if h.dups == .Group {
		h.in_doc_group = true
	}
	defer {
		h.in_doc_group = saved_in_doc_group
	}

	stack_buf: [16]Doc_Frame = ---
	stack_slice := stack_buf[:]
	stack_heap := false
	stack_n := 0
	defer {
		for i in 0 ..< stack_n {
			if len(stack_slice[i].grouped) > 0 {
				free_grouped(h, stack_slice[i].grouped)
			}
			tape.destroy_children(&stack_slice[i].iter)
			if stack_slice[i].owns_doc {
				free_synthetic_doc(h, stack_slice[i].doc)
			}
		}
		if stack_heap {
			delete(stack_slice, h.scratch)
		}
	}

	push_doc :: proc(h: ^Checker, sl: ^[]Doc_Frame, is_heap: ^bool, n: ^int, fr: Doc_Frame) -> bool {
		if n^ == len(sl^) {
			new_cap := max(32, len(sl^) * 2)
			grown, err := make([]Doc_Frame, new_cap, h.scratch)
			if err != nil {
				h.fatal = .No_Memory
				return false
			}
			copy(grown, sl^[:n^])
			if is_heap^ {
				delete(sl^, h.scratch)
			}
			sl^ = grown
			is_heap^ = true
		}
		sl^[n^] = fr
		n^ += 1
		return true
	}

	r := tape.Reader{doc = doc}
	root_idx := int(root_rec.meta)
	regs := hook.Regs{b = u64(uintptr(&h.plan.solo[2 * root_idx + 1]))}

	start_node :: proc(h: ^Checker, r: tape.Reader, cur_doc: ^tape.Document, node: tape.Node_Index, regs: ^hook.Regs, sl: ^[]Doc_Frame, is_heap: ^bool, sn: ^int, owns_doc := false) -> (stopped: bool, adopted: bool) #no_bounds_check {
		n := cur_doc.nodes[node]
		tok := tape.Token{lo = n.lo, n = n.n, kind = n.kind, role = .Value, spelling = n.spelling}
		if n.kind == .Object || n.kind == .Array {
			tok.n = 0
			// Direct zero-copy evaluation when `node` is already in `cur_doc` and hits a non-factored `.Held` container
			// (avoids re-capturing the subtree via `build.Builder`!).
			if h.capture_depth == 0 {
				if h.sp > 0 && h.frames[h.sp - 1].is_factored {
					// Save index `fo_idx` and re-fetch `fo` after `subcheck_node`/`eval_held_node` (which can grow `pool.factored`)!
					fo_idx := h.nf - 1
					fo := factored_at(h, fo_idx)
					choice_rec, use_fork, skip, doomed := factored_container(h, fo, tok)
					if h.fatal != .None {
						return true, false
					}
					if doomed {
						fail_doomed_factored(h, fo)
						return true, false
					}
					if skip {
						return false, false
					}
					if use_fork {
						fm := fo.active_member
						fo.active_member = nil
						fo.active_choice = -1
						if fm != nil {
							cnt_i, _, _ := tape.length(r, node, h.scratch)
							cnt := u64(max(cnt_i, 0))
							for fl in fm.leaves {
								l := &h.plan.leaves[fl.leaf - 1]
								if n.kind == .Object {
									if .Object not_in l.kinds || cnt < l.min_members || cnt > l.max_members {
										fo.failed |= fl.parts
									}
								} else if n.kind == .Array {
									if .Array not_in l.kinds || cnt < l.min_items || cnt > l.max_items {
										fo.failed |= fl.parts
									}
								}
							}
							for ch in fm.choices {
								fo = factored_at(h, fo_idx)
								if fo.factor.monotone && (ch.parts & ~fo.failed) == 0 {
									continue
								}
								passed := subcheck_node(h, cur_doc, node, ch.record, nil, nil, quiet = true)
								fo = factored_at(h, fo_idx)
								if !passed {
									fo.failed |= ch.parts
								}
								if h.fatal != .None {
									return true, false
								}
							}
						}
						fo = factored_at(h, fo_idx)
						if can_doom_factored(h, fo.factor, fo.failed) {
							fail_doomed_factored(h, fo)
							return true, false
						}
						return false, false
					}
					// Single choice container: if it's a non-factored held container, evaluate directly on `cur_doc`!
					cr := choice_rec
					if .Held in cr.flags {
						for hops := 0; hops < 4 && (.Held in cr.flags); hops += 1 {
							vr := h.plan.uses[cr.meta].verdict_rec
							if vr <= 0 {
								break
							}
							cr = &h.plan.records[vr - 1]
						}
					}
					if .Held in cr.flags && !(.Factored in cr.flags && n.kind == .Object && !h.no_factor && !h.judge_dups) {
						saved_q := h.quiet
						h.quiet = true
						passed := eval_held_node(h, cur_doc, node, cr, n.lo)
						h.quiet = saved_q
						if h.fatal != .None {
							return true, false
						}
						fo = factored_at(h, fo_idx)
						if !passed && fo.active_member != nil && fo.active_choice >= 0 {
							fo.failed |= fo.active_member.choices[fo.active_choice].parts
						}
						fo.active_member = nil
						fo.active_choice = -1
						if can_doom_factored(h, fo.factor, fo.failed) {
							fail_doomed_factored(h, fo)
							return true, false
						}
						return false, false
					}
					// Otherwise fall through to normal `open_container`!
					pre_nf := h.nf
					pre_sp := h.sp
					act: hook.Action
					regs^, act = open_container(h, regs^, tok, cr, is_choice = true)
					if act == .Stop || h.fatal != .None {
						return true, false
					}
					if act == .Skip || act == .Rest {
						if act == .Skip {
							h.skip_end = false
						}
						return false, false
					}
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
					opened_fac := n.kind == .Object && h.nf > pre_nf && h.sp > pre_sp && h.frames[h.sp - 1].is_factored
					fac_rec := h.frames[h.sp - 1].owner if opened_fac else nil
					grouped: []Group_Bucket
					if n.kind == .Object && h.dups == .Group {
						g, gok := build_group_buckets(h, r, cur_doc, &it)
						if !gok {
							tape.destroy_children(&it)
							return true, false
						}
						grouped = g
					}
					if !push_doc(h, sl, is_heap, sn, Doc_Frame{
						doc = cur_doc,
						owns_doc = owns_doc,
						node = node,
						is_object = n.kind == .Object,
						iter = it,
						open_factored = opened_fac,
						factored_rec = fac_rec,
						grouped = grouped,
					}) {
						if len(grouped) > 0 {
							free_grouped(h, grouped)
						}
						tape.destroy_children(&it)
						return true, false
					}
					return false, owns_doc
				}

				rec := (^Record)(uintptr(regs.b) - size_of(Record))
				eff := rec
				if .Held in eff.flags && (h.sink == nil || h.quiet) {
					for hops := 0; hops < 4 && (.Held in eff.flags); hops += 1 {
						u := &h.plan.uses[eff.meta]
						if u.verdict_rec > 0 {
							eff = &h.plan.records[u.verdict_rec - 1]
							continue
						}
						if n.kind == .Object && u.obj_arm > 0 {
							eff = &h.plan.records[u.obj_arm - 1]
							continue
						}
						if n.kind == .Array && u.arr_arm > 0 {
							eff = &h.plan.records[u.arr_arm - 1]
							continue
						}
						break
					}
				}
				// If still `.Held` (non-factored), evaluate directly on `cur_doc` using original `rec` so error locations stay intact!
				if .Held in eff.flags && !(.Factored in eff.flags && n.kind == .Object && !h.no_factor && !h.judge_dups) {
					if h.budget.nodes > 0 {
						h.nodes_seen += 1
						if h.nodes_seen > u64(h.budget.nodes) {
							h.fatal = .Exceeded
							return true, false
						}
					}
					if h.sp > 0 && !h.frames[h.sp - 1].is_object {
						h.frames[h.sp - 1].count += 1
					}
					if !eval_held_node(h, cur_doc, node, rec, n.lo) {
						h.failed = true
						if can_stop_early(h) {
							return true, false
						}
					}
					if h.fatal != .None {
						return true, false
					}
					regs^ = after_value(h, regs^)
					return false, false
				}
			}
		} else if h.capture_depth == 0 && h.nf == 0 && !h.has_budget {
			rec := (^Record)(uintptr(regs.b) - size_of(Record))
			if .Held not_in rec.flags && fast_scalar_ok(rec, tok, h.is_binary) {
				if h.sp > 0 && !h.frames[h.sp - 1].is_object {
					h.frames[h.sp - 1].count += 1
				}
				regs^ = after_value(h, regs^)
				return false, false
			}
		}
		pre_nf := h.nf
		pre_sp := h.sp
		act: hook.Action
		regs^, act = checker_step(h, regs^, tok)
		if act == .Stop || h.fatal != .None {
			return true, false
		}
		if act == .Skip || act == .Rest {
			if act == .Skip && (n.kind == .Object || n.kind == .Array) {
				end_tok := tape.Token{lo = n.lo, kind = .End, role = .Value}
				regs^, _ = checker_step(h, regs^, end_tok)
			}
			return false, false
		}
		if n.kind == .Object || n.kind == .Array {
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
			opened_fac := n.kind == .Object && h.nf > pre_nf && h.sp > pre_sp && h.frames[h.sp - 1].is_factored
			fac_rec := h.frames[h.sp - 1].owner if opened_fac else nil
			grouped: []Group_Bucket
			if n.kind == .Object && h.dups == .Group {
				g, gok := build_group_buckets(h, r, cur_doc, &it)
				if !gok {
					tape.destroy_children(&it)
					return true, false
				}
				grouped = g
			}
			if !push_doc(h, sl, is_heap, sn, Doc_Frame{
				doc = cur_doc,
				owns_doc = owns_doc,
				node = node,
				is_object = n.kind == .Object,
				iter = it,
				open_factored = opened_fac,
				factored_rec = fac_rec,
				grouped = grouped,
			}) {
				if len(grouped) > 0 {
					free_grouped(h, grouped)
				}
				tape.destroy_children(&it)
				return true, false
			}
			return false, owns_doc
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
					ktok := tape.Token{lo = gb.kt.lo, n = gb.kt.n, kind = gb.kt.kind, role = .Key, spelling = gb.kt.spelling}
					act: hook.Action
					regs, act = checker_step(h, regs, ktok)
					if act == .Stop || h.fatal != .None {
						return false
					}
					if act == .Skip {
						continue
					}
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
						if !sok {
							return false
						}
						stopped, adopted := start_node(h, tape.Reader{doc = synth}, synth, 0, &regs, &stack_slice, &stack_heap, &stack_n, owns_doc = true)
						if !adopted {
							free_synthetic_doc(h, synth)
						}
						if stopped {
							return false
						}
					} else if len(gb.vals) == 1 {
						if stopped, _ := start_node(h, cur_r, cur_doc, gb.vals[0], &regs, &stack_slice, &stack_heap, &stack_n); stopped {
							return false
						}
					}
					continue
				}
			} else {
				kn, vn, cp := tape.next_child(cur_r, &top.iter, h.dups)
				if cp == .Found {
					kt := tape.cell_key(cur_r, top.iter) if (kn == tape.NO_NODE && top.iter.keys_n != 0) else cur_doc.nodes[kn]
					ktok := tape.Token{lo = kt.lo, n = kt.n, kind = kt.kind, role = .Key, spelling = kt.spelling}
					act: hook.Action
					regs, act = checker_step(h, regs, ktok)
					if act == .Stop || h.fatal != .None {
						return false
					}
					if act == .Skip {
						continue
					}
					if stopped, _ := start_node(h, cur_r, cur_doc, vn, &regs, &stack_slice, &stack_heap, &stack_n); stopped {
						return false
					}
					continue
				}
			}
		} else {
			_, ch, cp := tape.next_child(cur_r, &top.iter)
			if cp == .Found {
				if stopped, _ := start_node(h, cur_r, cur_doc, ch, &regs, &stack_slice, &stack_heap, &stack_n); stopped {
					return false
				}
				continue
			}
		}
		stack_n -= 1
		closed := stack_slice[stack_n]
		if len(closed.grouped) > 0 {
			free_grouped(h, closed.grouped)
		}
		tape.destroy_children(&closed.iter)
		// Save `parent_b` BEFORE `checker_step` pops the frame so in-place factored fallback can restore `regs` (B-H1)!
		saved_parent_b := h.frames[h.sp - 1].parent_b if h.sp > 0 else regs.b
		end_tok := tape.Token{lo = closed.doc.nodes[closed.node].lo, kind = .End, role = .Value}
		act: hook.Action
		regs, act = checker_step(h, regs, end_tok)
		if h.reread_runs && closed.open_factored && closed.factored_rec != nil {
			h.reread_runs = false
			h.need_reread = false
			saved_nf := h.no_factor
			h.no_factor = true
			ok := eval_held_node(h, closed.doc, closed.node, closed.factored_rec, closed.doc.nodes[closed.node].lo)
			h.no_factor = saved_nf
			if closed.owns_doc {
				free_synthetic_doc(h, closed.doc)
			}
			if h.fatal != .None {
				return false
			}
			if !ok {
				h.failed = true
			}
			regs = after_value(h, {regs.a, saved_parent_b, regs.c})
			continue
		}
		if closed.owns_doc {
			free_synthetic_doc(h, closed.doc)
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
	return check_document_node(doc, tape.ROOT, plan, opts, sink, allocator)
}

// Checks a subtree of an already-built `tape.Document` starting at `node` against compiled `plan`.
// Uses an explicit heap stack (zero unbounded recursion) and allocates zero `context.temp_allocator` memory.
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

	// Set up unified memory budget over scratch and output.
	t_opts := tape.Options{budget = opts.budget, scratch = opts.scratch}
	rb: hook.Read_Budget
	scratch: runtime.Allocator
	mem_b: ^hook.Memory_Budget
	local_mb: hook.Memory_Budget
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
		// Rare case: document had duplicate keys under `.First`/`.Last` and wasn't deduplicated during build.
		if sink != nil {
			sink_restore(sink, {count = from})
		}
		checker_cleanup(&h)
		_ = checker_start(&h, plan, doc.src, doc.format, opts, sink, &memo, allocator, scratch, mem_b, &ctx)
		h.xml_ext = doc.ext
		h.no_factor = true
		h.judge_dups = true
		ok = walk_document_node(&h, doc, node, &plan.records[0])
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

	rb: hook.Read_Budget = ---
	local_mb: hook.Memory_Budget = ---
	scratch: runtime.Allocator
	mem_b: ^hook.Memory_Budget
	if t_opts.budget.memory > 0 {
		rb = {}
		local_mb = {}
		out_alloc := hook.read_budget(untracked_ptr(&rb), t_opts, allocator)
		scratch = hook.scratch(t_opts, out_alloc, untracked_ptr(&local_mb))
		mem_b = untracked_ptr(&rb.main)
	} else {
		scratch = t_opts.scratch if t_opts.scratch.procedure != nil else allocator
	}

	from := len(sink.entries) if sink != nil else 0

	// First pass: pure zero-Document streaming (`h` unzeroed; `checker_start` initializes scalar header only)!
	h: H = ---
	memo: hook.Expected_Memo = ---
	ctx := context
	chk := checker_ptr(&h)
	regs := checker_start(chk, plan, src, format, opts, sink, &memo, allocator, scratch, mem_b, &ctx)
	// Load lazy XML prolog/DTD extension if format provides `text_ext` so streaming XML decodes entities!
	if format != nil && format.text_ext != nil {
		if ext, ok := format.text_ext(src, scratch); ok && ext != nil {
			chk.xml_ext = ext
			chk.xml_ext_owned = true
		}
	}
	when H == Refusing_Checker {
		open_buf: [64]Open_Key = ---
		h.open_keys = {}
		open_keys_start(&h.open_keys, open_buf[:], src, format, chk.xml_ext, scratch, &ctx)
		defer open_keys_cleanup(&h.open_keys)
	}
	defer checker_cleanup(chk)

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

	// Fast exit on the common zero-error valid happy path!
	if werr == nil && chk.fatal == .None && !chk.need_reread && !chk.dup_hit && !chk.failed && (sink == nil || len(sink.entries) == from) {
		return Result{valid = true, allocator = allocator}
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
		regs = checker_start(chk, plan, src, format, opts, sink, &memo, allocator, scratch, mem_b, &ctx)
		if format != nil && format.text_ext != nil {
			if ext, ok := format.text_ext(src, scratch); ok && ext != nil {
				chk.xml_ext = ext
				chk.xml_ext_owned = true
			}
		}
		when H == Refusing_Checker {
			open_keys_start(&h.open_keys, open_buf[:], src, format, chk.xml_ext, scratch, &ctx)
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
			regs = checker_start(chk, plan, src, format, opts, sink, &memo, allocator, scratch, mem_b, &ctx)
			if format != nil && format.text_ext != nil {
				if ext, ok := format.text_ext(src, scratch); ok && ext != nil {
					chk.xml_ext = ext
					chk.xml_ext_owned = true
				}
			}
			when H == Refusing_Checker {
				open_keys_start(&h.open_keys, open_buf[:], src, format, chk.xml_ext, scratch, &ctx)
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
	if !h.failed && !h.need_reread && (h.sink == nil || len(h.sink.entries) == h.sink_from) {
		destroy_first_arena(h)
		return Result{valid = true, allocator = allocator}
	}
	if h.sink != nil {
		destroy_first_arena(h)
		first := h.sink.entries[h.sink_from] if len(h.sink.entries) > h.sink_from else Check_Error{kind = .Unsupported if h.need_reread else .Not_Allowed}
		return Result{valid = false, err = first, allocator = allocator}
	}
	res := Result{
		valid = false,
		err = h.first_err if h.first_recorded else Check_Error{kind = .Unsupported if h.need_reread else .Not_Allowed},
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
frame_push_slot :: #force_inline proc "contextless" (h: ^Checker) -> ^Frame #no_bounds_check {
	if h.sp == len(h.frames) {
		if !frame_grow(h) {
			return nil
		}
	}
	f := &h.frames[h.sp]
	h.sp += 1
	return f
}

@(private = "file", cold)
frame_grow :: #force_no_inline proc "contextless" (h: ^Checker) -> bool {
	context = h.ctx^
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
	return true
}

@(private)
push_frame :: proc(h: ^Checker, fr: Frame) -> bool {
	f := frame_push_slot(h)
	if f == nil {
		return false
	}
	f^ = fr
	return true
}

@(private)
frame_mark_seen :: #force_inline proc "contextless" (h: ^Checker, f: ^Frame, idx: i32) -> (was_seen: bool, ok: bool) #no_bounds_check {
	if f.owner.members_u16 <= 64 {
		bit := u64(1) << uint(idx)
		if (f.seen_mask & bit) != 0 {
			return true, true
		}
		f.seen_mask |= bit
		return false, true
	}
	return frame_mark_seen_wide(h, f, idx)
}

@(private = "file", cold)
frame_mark_seen_wide :: #force_no_inline proc "contextless" (h: ^Checker, f: ^Frame, idx: i32) -> (was_seen: bool, ok: bool) #no_bounds_check {
	context = h.ctx^
	if len(f.seen_wide) == 0 {
		m := &h.plan.meta[f.owner.meta]
		words := (int(m.members) + 63) / 64
		buf, err := make([]u64, words, h.scratch)
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
tracker_at :: #force_inline proc "contextless" (h: ^Checker, idx: int) -> ^Key_Tracker #no_bounds_check {
	if idx == 0 {
		return &h.tracker0
	}
	return &h.trackers[idx - 1]
}

@(private)
open_tracker :: proc(h: ^Checker) -> int {
	idx := h.tracked
	if idx == 0 {
		if !h.tracker0_used {
			h.tracker0 = {}
			h.tracker0.names.allocator = h.scratch
			h.tracker0.owned.allocator = h.scratch
			h.tracker0.table.allocator = h.scratch
			h.tracker0_used = true
		} else {
			h.tracker0.small_n = 0
			for nm in h.tracker0.owned {
				delete(nm, h.scratch)
			}
			clear(&h.tracker0.owned)
			clear(&h.tracker0.names)
			clear(&h.tracker0.table)
		}
		h.tracked = 1
		return 0
	}
	heap_idx := idx - 1
	if heap_idx == len(h.trackers) {
		tr := Key_Tracker{}
		tr.names.allocator = h.scratch
		tr.owned.allocator = h.scratch
		tr.table.allocator = h.scratch
		if _, err := append(&h.trackers, tr); err != nil {
			return -1
		}
	} else {
		tr := &h.trackers[heap_idx]
		tr.small_n = 0
		for nm in tr.owned {
			delete(nm, h.scratch)
		}
		clear(&tr.owned)
		clear(&tr.names)
		clear(&tr.table)
	}
	h.tracked += 1
	return idx
}

@(private)
close_tracker :: proc(h: ^Checker) {
	if h.tracked > 0 {
		h.tracked -= 1
	}
}

@(private)
tracker_has :: proc(tr: ^Key_Tracker, name: string) -> bool #no_bounds_check {
	if len(tr.names) == 0 {
		for i in 0 ..< tr.small_n {
			if tr.small[i] == name {
				return true
			}
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
		if err != nil {
			return false
		}
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
		// Spill inline 16 entries into `tr.names` + `tr.table`.
		if _, rerr := append(&tr.names, ..tr.small[:tr.small_n]); rerr != nil {
			return false
		}
		for nm, i in tr.names {
			tr.table[nm] = i
		}
	}
	if _, aerr := append(&tr.names, stored); aerr != nil {
		return false
	}
	tr.table[stored] = len(tr.names) - 1
	return true
}

// Appends the current instance path (from lazy `parent` chain + open container `frames`) into `out`.
@(private)
append_current_instance_path :: proc(h: ^Checker, out: ^[dynamic]tape.Step, cur_owner: ^Record = nil) {
	if h.parent != nil {
		append_current_instance_path(h.parent, out, h.parent_owner)
		if len(h.parent_extra) > 0 {
			append(out, ..h.parent_extra)
		}
	}
	for i in 0 ..< h.sp {
		fr := &h.frames[i]
		if fr.is_object {
			if fr.in_seq {
				// Sequential `.Expects` member: derive name lazily from child frame's `parent_b` (or `cur_owner` at top)!
				rec: ^Record
				if i + 1 < h.sp {
					pb := h.frames[i + 1].parent_b
					if pb != 0 && pb != u64(uintptr(&DEAD_RECORD)) {
						rec = (^Record)(uintptr(pb) - size_of(Record))
					}
				} else {
					rec = cur_owner
				}
				if rec != nil {
					if nm := h.plan.meta[rec.meta].name; len(nm) > 0 {
						append(out, tape.Name(nm))
					}
				}
			} else if len(fr.key_name) > 0 {
				append(out, tape.Name(fr.key_name))
			}
		} else {
			idx := int(fr.count) - 1 if fr.count > 0 else 0
			append(out, tape.Index(idx))
		}
	}
}

// Appends the current keyword path (from lazy `parent` chain + open container `Use.site`s + `owner`'s site) into `out`.
// Preserves original `parent_b` sites when `verdict_rec` or `obj_arm`/`arr_arm` redirected a container!
@(private)
append_current_keyword_path :: proc(h: ^Checker, out: ^[dynamic]tape.Step, owner: ^Record, alt_site: []tape.Step = nil) {
	if h.parent != nil {
		append_current_keyword_path(h.parent, out, h.parent_owner)
	}
	for i in 0 ..< h.sp {
		fr := &h.frames[i]
		if fr.owner != nil {
			if !fr.is_choice && !fr.is_group_array && fr.parent_b != 0 && fr.parent_b != u64(uintptr(&DEAD_RECORD)) {
				orig := (^Record)(uintptr(fr.parent_b) - size_of(Record))
				if orig.meta != fr.owner.meta {
					append(out, ..h.plan.uses[orig.meta].site)
				}
			}
			append(out, ..h.plan.uses[fr.owner.meta].site)
		}
	}
	if owner != nil {
		// Avoid duplicating if `owner` is already the top frame's owner.
		if h.sp == 0 || h.frames[h.sp - 1].owner != owner {
			append(out, ..h.plan.uses[owner.meta].site)
		}
	}
	if len(alt_site) > 0 {
		append(out, ..alt_site)
	}
}

@(private)
build_check_error :: proc(h: ^Checker, arena: runtime.Allocator, kind: Error_Kind, at: u64, keyword: string, expected: string, owner: ^Record, extra_kw := "", alt_site: []tape.Step = nil) -> (Check_Error, bool) {
	inst_steps := make([dynamic]tape.Step, h.scratch)
	kw_steps := make([dynamic]tape.Step, h.scratch)
	defer {
		delete(inst_steps)
		delete(kw_steps)
	}
	append_current_instance_path(h, &inst_steps, owner)
	append_current_keyword_path(h, &kw_steps, owner, alt_site)
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
record_failure :: proc(h: ^Checker, kind: Error_Kind, at: u64, keyword: string, expected: string, owner: ^Record, extra_kw := "", alt_site: []tape.Step = nil) {
	if h.sink == nil {
		record_first_failure(h, kind, at, keyword, expected, owner, extra_kw, alt_site)
		return
	}
	arena := sink_ensure(h.sink, h.allocator)
	entry, ok := build_check_error(h, arena, kind, at, keyword, expected, owner, extra_kw, alt_site)
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
record_first_failure :: proc(h: ^Checker, kind: Error_Kind, at: u64, keyword: string, expected: string, owner: ^Record, extra_kw := "", alt_site: []tape.Step = nil) {
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
		mem.dynamic_arena_init(a, h.allocator, h.allocator, block_size = 512)
		h.first_arena = a
	}
	arena := mem.dynamic_arena_allocator(h.first_arena)
	if entry, ok := build_check_error(h, arena, kind, at, keyword, expected, owner, extra_kw, alt_site); ok {
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
open_keys_start :: proc(k: ^Open_Keys, room: []Open_Key, src: []u8, format: ^tape.Format, xml_ext: ^tape.Doc_Ext, allocator: runtime.Allocator, ctx: ^runtime.Context) {
	k^ = {
		room = room,
		repeat = NO_REPEAT,
		src = src,
		format = format,
		xml_ext = xml_ext,
		allocator = allocator,
		ctx = ctx,
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
	context = k.ctx^
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
