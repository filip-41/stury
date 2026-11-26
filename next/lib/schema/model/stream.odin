// Streaming walk-driven model loader (`Stream_Loader` with `.Skips` + `.Expects`,
// `Refusing_Loader` for `.Refuse` duplicate-key detection, and `load_stream` generic runner).
// Zero intermediate `tape.Document` and zero per-record `Dynamic_Arena` on the common path.
package model

import "base:intrinsics"
import "base:runtime"
import "core:encoding/uuid"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:time"
import "stury:lib/base/kernel"
import "stury:lib/base/regex"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

@(private)
STREAM_NO_LIMIT :: max(u64)

@(private)
STREAM_INLINE_FRAMES :: 16

@(private)
OPEN_KEYS_INLINE :: 64

@(private)
OPEN_KEYS_PAIRED :: 12

@(private)
NO_REPEAT :: max(u64)

@(private)
F64_EXACT_INT_MAX :: i64(1) << 53

@(private, rodata)
INT_MIN_TABLE := #partial [Type_Kind]i64{
	.I8  = i64(min(i8)),  .I16 = i64(min(i16)), .I32 = i64(min(i32)), .I64 = min(i64),
	.U8  = 0,             .U16 = 0,             .U32 = 0,             .U64 = 0,
}

@(private, rodata)
INT_MAX_TABLE := #partial [Type_Kind]i64{
	.I8  = i64(max(i8)),  .I16 = i64(max(i16)), .I32 = i64(max(i32)), .I64 = max(i64),
	.U8  = i64(max(u8)),  .U16 = i64(max(u16)), .U32 = i64(max(u32)), .U64 = max(i64),
}

@(private)
Stream_Frame_Kind :: enum u8 {
	Root,
	Struct,
	Slice,
	Dynamic,
	Array,
	Fixed_List,
	Map,
	Skipped,
}

// Zero-padding layout so `[STREAM_INLINE_FRAMES]Stream_Frame = ---` is never zeroed by Odin.
@(private)
Stream_Frame :: struct {
	a, b, c:     u64,
	start_fails: u64,
	open_at:     u64,
	seen0:       u64,
	seen1:       u64,
	key_at:      u64,
	si:          ^Struct_Info,
	seen_wide:   []u64,
	cur_key:     string,
	target:      rawptr,
	data:        rawptr,
	val_buf:     rawptr,
	count:       int,
	cap:         int,
	node_idx:    i32,
	rule_idx:    i32,
	stride:      u32,
	parent_fi:   u16,
	kind:        Stream_Frame_Kind,
	fflags:      u8,
}
when size_of(uintptr) == 8 { #assert(size_of(Stream_Frame) == 160) }

@(private)
SF_HAS_AFTER :: u8(1)
@(private)
SF_KEY_VALID :: u8(2)
@(private)
SF_KEY_OWNED :: u8(4)

// Stack-first spill allocator for short-lived regex `Gate` (~48 B) so DFA loads do zero heap allocs.
@(private)
Stack_Spill :: struct {
	buf:      []u8,
	used:     int,
	spilled:  bool,
	fallback: runtime.Allocator,
}

@(private)
stack_spill_allocator :: proc(s: ^Stack_Spill) -> runtime.Allocator {
	return {procedure = stack_spill_proc, data = s}
}

@(private)
stack_spill_proc :: proc(
	data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_ptr: rawptr, old_size: int, loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	s := (^Stack_Spill)(data)
	lo := uintptr(raw_data(s.buf))
	hi := lo + uintptr(len(s.buf))
	inside := old_ptr != nil && uintptr(old_ptr) >= lo && uintptr(old_ptr) < hi
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		aligned := mem.align_forward_uintptr(lo + uintptr(s.used), uintptr(max(alignment, 1)))
		if size >= 0 && aligned + uintptr(size) <= hi {
			s.used = int(aligned + uintptr(size) - lo)
			block := ([^]u8)(aligned)[:size]
			if mode == .Alloc { mem.zero_slice(block) }
			return block, nil
		}
	case .Resize, .Resize_Non_Zeroed:
		if inside {
			s.spilled = true
			got, err := s.fallback.procedure(s.fallback.data, .Alloc if mode == .Resize else .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
			if err == nil && size > 0 { copy(got, mem.byte_slice(old_ptr, min(old_size, size))) }
			return got, err
		}
	case .Free:
		if old_ptr == nil || inside { return nil, nil }
	case .Free_All:
		return nil, .Mode_Not_Implemented
	}
	if mode != .Free { s.spilled = true }
	return s.fallback.procedure(s.fallback.data, mode, size, alignment, nil if inside else old_ptr, old_size, loc)
}

// Streaming walk hook for non-refusing duplicate policies (`.Last`, `.First`) with full `.Skips` + `.Expects`.
Stream_Loader :: struct {
	base:        [^]u8,
	src_len:     u64,
	frames:      [^]Stream_Frame,
	sp:          int,
	room:        int,
	plan:        ^Type_Plan,
	expected:    ^hook.Expected_Memo,
	// Cold fields past Cache Line 0.
	home:        [^]Stream_Frame,
	format:      ^tape.Format,
	sink:        ^Sink,
	first:       Model_Error,
	policy:      tape.Duplicates,
	oom:         bool,
	fallback:    bool,
	wrote_alloc: bool,
	has_val:     bool,
	re_ready:    bool,
	rep_ready:   bool,
	fail_count:  u64,
	budget:      Budget_Tracker,
	re_scratch:  regex.Scratch,
	re_spill:    ^Stack_Spill,
	rep:         Report,
	allocator:   runtime.Allocator,
	scratch:     runtime.Allocator,
	ctx:         runtime.Context,
	protocol:    hook.Protocol({.Skips, .Expects}, hook.Unused, hook.Unused, hook.Unused),
}

// Key token recorded on the stack for `.Refuse` duplicate-key checking across all objects (including skipped subtrees).
@(private)
Open_Key :: struct {
	key:   tape.Token,
	depth: u32,
	_pad:  u32,
}

@(private)
Open_Keys :: struct {
	room:    []Open_Key,
	n:       int,
	depth:   u32,
	repeat:  u64,
	heap:    bool,
	oom:     bool,
	base:    [^]u8,
	src_len: u64,
	format:  ^tape.Format,
	scratch: runtime.Allocator,
}

// Sentinel `Stream_Field` whose `word == NO_KEY` so `.Expects` never matches it; its address also distinguishes
// "no `.Expects` key matched" from a struct's own end-of-fields sentinel in `Refusing_Loader`.
@(private, rodata)
STREAM_SENTINEL := Stream_Field{expected = {word = NO_KEY}, node = -1, struct_idx = -1, kind = .Invalid}

@(private)
Refuse_Mode :: enum u8 {
	Active,
	Skip_Next,
	Passing,
	Done,
}

// Streaming walk hook for `dups == .Refuse`: uses `.Expects` for zero-callback in-order key prediction
// while enforcing exact duplicate-key refusal across the entire text (including skipped subtrees and `first` mode).
Refusing_Loader :: struct {
	expected:     ^hook.Expected_Memo,
	loader:       Stream_Loader,
	open_keys:    Open_Keys,
	saved_b:      u64,
	done_saved_b: u64,
	passing:      int,
	done_sp:      int,
	mode:         Refuse_Mode,
	protocol:     hook.Protocol({.Expects}, hook.Unused, hook.Unused, hook.Unused),
}

// Generic streaming runner called by format packages (`json.load`, etc.).
@(require_results)
load_stream :: proc(
	m: ^Model($T),
	src: []u8,
	format: ^tape.Format,
	out: ^T,
	sink: ^Sink,
	opts: Load_Opts,
	walk_opts: $WOpts,
	allocator: runtime.Allocator,
	$H: typeid,
	$walk: proc "contextless" (src: []u8, opts: WOpts, h: ^H, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool),
	$build_fallback: proc(src: []u8, opts: WOpts, a: runtime.Allocator) -> (tape.Document, tape.Error),
) -> Error {
	if m == nil || format == nil || out == nil || len(m.plan.nodes) == 0 {
		return Model_Error{kind = .Bad_Option, want = {text = "target"}}
	}
	policy, ok := resolve_dups(opts.dups, format)
	if !ok {
		return Model_Error{kind = .Bad_Option, want = {text = "dups"}}
	}
	if !m.plan.can_stream || policy == .Group {
		return load_via_build(m, src, out, sink, opts, walk_opts, policy, allocator, build_fallback)
	}

	mem.zero(out, size_of(T))

	rb: hook.Read_Budget
	mb: hook.Memory_Budget
	out_alloc := allocator
	scr_alloc := opts.scratch if opts.scratch.procedure != nil else allocator
	if opts.budget.memory > 0 {
		t_opts := tape.Options{budget = opts.budget, scratch = opts.scratch}
		out_alloc = hook.read_budget(&rb, t_opts, allocator)
		scr_alloc = hook.scratch(t_opts, out_alloc, &mb)
	}

	frames: [STREAM_INLINE_FRAMES]Stream_Frame = ---
	spill_buf: [256]u8 = ---
	re_spill := Stack_Spill{buf = spill_buf[:], fallback = scr_alloc}

	from := len(sink.entries) if sink != nil else 0
	saved_truncated := sink.truncated if sink != nil else false

	hk_buf: [size_of(H) / size_of(u64)]u64 = ---
	#assert(size_of(hk_buf) == size_of(H))
	#assert(align_of(H) <= align_of(u64))
	hk := (^H)(&hk_buf[0])
	h := &hk.loader when H == Refusing_Loader else hk
	// Initialize live fields directly so `re_scratch` (224 B) and `rep` (~64 B) are not zeroed per record.
	h.base, h.src_len = raw_data(src), u64(len(src))
	h.frames, h.home = raw_data(frames[:]), raw_data(frames[:])
	h.sp, h.room = 1, STREAM_INLINE_FRAMES
	h.plan, h.format, h.sink = &m.plan, format, sink
	h.first.kind = .None
	h.first.owned = false
	h.policy = policy
	h.oom, h.fallback, h.wrote_alloc = false, false, false
	h.has_val = m.plan.has_validators
	h.re_ready, h.rep_ready = false, false
	h.fail_count = 0
	h.budget.limit = opts.budget
	h.budget.max_depth = opts.budget.depth if opts.budget.depth > 0 else tape.DEFAULT_DEPTH
	h.budget.depth, h.budget.nodes, h.budget.steps = 0, 0, 0
	h.budget.exceeded.kind = .None
	h.re_spill = &re_spill
	h.allocator, h.scratch = out_alloc, scr_alloc
	h.ctx = context
	h.ctx.allocator = out_alloc
	frames[0].kind = .Root

	memo: hook.Expected_Memo = ---
	h.expected = &memo
	when H == Refusing_Loader {
		ok_room: [OPEN_KEYS_INLINE]Open_Key = ---
		hk.expected = &memo
		hk.open_keys = {
			room    = ok_room[:],
			repeat  = NO_REPEAT,
			base    = raw_data(src),
			src_len = u64(len(src)),
			format  = format,
			scratch = scr_alloc,
		}
		hk.saved_b = 0
		hk.done_saved_b = 0
		hk.passing = 0
		hk.done_sp = 0
		hk.mode = .Active
	}

	regs := hook.Regs{
		a = STREAM_NO_LIMIT,
		b = u64(uintptr(&m.plan.root_field) + size_of(Stream_Field)),
		c = u64(uintptr(out)),
	}
	_, walk_err, _ := walk(src, walk_opts, hk, &regs, scr_alloc, &h.ctx)

	when H == Refusing_Loader {
		if walk_err != nil {
			open_keys_finish_open(&hk.open_keys)
		}
		dup_at := hk.open_keys.repeat
		dup_oom := hk.open_keys.oom
		if hk.open_keys.heap {
			delete(hk.open_keys.room, scr_alloc)
		}
	}

	if h.sp > 1 || h.frames != h.home || h.rep_ready || (h.re_ready && h.re_spill.spilled) {
		stream_cleanup(h)
	}

	rollback :: #force_no_inline proc(h: ^Stream_Loader, out: ^T, sink: ^Sink, from: int, saved_trunc: bool, out_alloc: runtime.Allocator, trunc_sink: bool) {
		if trunc_sink && sink != nil { sink_truncate(sink, from, saved_trunc) }
		error_destroy(h.first, out_alloc)
		if h.wrote_alloc { free_value(out, type_info_of(T), out_alloc) } else { mem.zero(out, size_of(T)) }
	}

	if h.fallback {
		rollback(h, out, sink, from, saved_truncated, out_alloc, true)
		return load_via_build(m, src, out, sink, opts, walk_opts, policy, allocator, build_fallback)
	}

	// Check `.Refuse` duplicate key & walk faults (walk faults and duplicate keys take precedence over validation errors).
	when H == Refusing_Loader {
		if dup_oom {
			rollback(h, out, sink, from, saved_truncated, out_alloc, true)
			return stream_oom_error(&rb, &mb, opts.budget.memory)
		}
		if dup_at != NO_REPEAT {
			if f, is_f := walk_err.(tape.Fault); walk_err == nil || (is_f && f.at > dup_at) {
				rollback(h, out, sink, from, saved_truncated, out_alloc, true)
				if sink != nil { _ = sink_push(sink, allocator, .Duplicate_Key, dup_at, nil) }
				return Model_Error{kind = .Duplicate_Key, at = dup_at}
			}
		}
	}

	if walk_err != nil {
		rollback(h, out, sink, from, saved_truncated, out_alloc, true)
		if _, is_oom := walk_err.(runtime.Allocator_Error); is_oom && opts.budget.memory > 0 {
			return stream_oom_error(&rb, &mb, opts.budget.memory)
		}
		return walk_err
	}

	if sink != nil && len(sink.entries) - from > 1 { order_sink(sink, from) }

	if h.budget.exceeded.kind != .None {
		rollback(h, out, sink, from, saved_truncated, out_alloc, false)
		return tape.Error(h.budget.exceeded)
	}
	if h.oom {
		rollback(h, out, sink, from, saved_truncated, out_alloc, false)
		return stream_oom_error(&rb, &mb, opts.budget.memory)
	}
	if h.first.kind != .None {
		if h.wrote_alloc {
			if out_alloc.procedure == mem.arena_allocator_proc {
				mem.zero(out, size_of(T))
			} else {
				stream_free_fast(&m.plan, m.plan.root, rawptr(out), out_alloc)
			}
		} else {
			mem.zero(out, size_of(T))
		}
		return h.first
	}
	return nil
}

// Fast plan-driven rollback free: skips POD scalar fields and uses zero heap/RTTI overhead for flat structs.
@(private, cold)
stream_free_fast :: #force_no_inline proc(plan: ^Type_Plan, root_idx: i32, ptr: rawptr, allocator: runtime.Allocator) {
	tn := &plan.nodes[root_idx]
	if tn.kind == .Struct {
		si := &plan.structs[tn.struct_idx]
		all_simple := true
		for &sf in si.stream_fields[:len(si.fields)] {
			#partial switch sf.kind {
			case .String, .Email:
				s := (^string)(uintptr(ptr) + uintptr(sf.offset))
				if len(s^) > 0 { delete(s^, allocator); s^ = "" }
			case .Bool, .Bool_Wide, .I8 ..= .F64, .Enum, .Time, .Uuid:
				// POD: zeroed below.
			case:
				all_simple = false
			}
		}
		if all_simple && !si.has_fields_set {
			mem.zero(ptr, tn.size)
			return
		}
	}
	free_value(ptr, tn.ti, allocator)
}

@(private, cold)
load_via_build :: #force_no_inline proc(
	m: ^Model($T), src: []u8, out: ^T, sink: ^Sink, opts: Load_Opts, walk_opts: $WOpts, policy: tape.Duplicates,
	allocator: runtime.Allocator,
	$build_fallback: proc(src: []u8, opts: WOpts, a: runtime.Allocator) -> (tape.Document, tape.Error),
) -> Error {
	sc: Scratch_Scope
	scratch_begin(&sc, opts, allocator)
	defer scratch_end(&sc)
	b_opts := walk_opts
	b_opts.dups = policy
	b_opts.scratch = sc.scratch
	doc, berr := build_fallback(src, b_opts, sc.scratch)
	if berr != nil {
		if f, is_fault := berr.(tape.Fault); is_fault && f.kind == .Duplicate_Key {
			if sink != nil { _ = sink_push(sink, allocator, .Duplicate_Key, f.at, nil) }
			return Model_Error{kind = .Duplicate_Key, at = f.at}
		}
		return berr
	}
	defer tape.destroy(&doc)
	return load_document(m, &doc, out, sink, opts, allocator)
}

@(private)
stream_oom_error :: proc "contextless" (rb: ^hook.Read_Budget, mb: ^hook.Memory_Budget, mem_limit: u64) -> Error {
	if mem_limit > 0 && (rb.main.refused || rb.scratch.refused || mb.refused) {
		return tape.Error(tape.Exceeded{at = tape.NO_BYTE, kind = .Memory})
	}
	return runtime.Allocator_Error.Out_Of_Memory
}

@(private)
sink_truncate :: proc(s: ^Sink, from: int, saved_truncated: bool) {
	if s != nil {
		if len(s.entries) > from { resize(&s.entries, from) }
		s.truncated = saved_truncated
	}
}

@(private)
stream_cleanup :: proc(h: ^Stream_Loader) {
	for i in 1 ..< h.sp {
		f := &h.frames[i]
		if len(f.seen_wide) > 0 { delete(f.seen_wide, h.scratch) }
		if f.fflags & SF_KEY_OWNED != 0 { delete(f.cur_key, h.scratch) }
		if f.kind == .Map {
			if f.fflags & SF_KEY_VALID != 0 {
				tn := &h.plan.nodes[f.node_idx]
				if f.data != nil { free_value(f.data, h.plan.nodes[tn.key_node].ti, h.allocator) }
				if f.val_buf != nil { free_value(f.val_buf, h.plan.nodes[tn.child].ti, h.allocator) }
			}
			if f.data != nil { runtime.mem_free(f.data, h.scratch) }
			if f.val_buf != nil { runtime.mem_free(f.val_buf, h.scratch) }
		} else if (f.kind == .Slice || f.kind == .Dynamic) && f.data != nil {
			// Unclosed list buffer (walk stopped/faulted mid-array) — free elements & buffer.
			ctn := &h.plan.nodes[h.plan.nodes[f.node_idx].child]
			for j in 0 ..< f.count {
				free_value(rawptr(uintptr(f.data) + uintptr(j) * uintptr(f.stride)), ctn.ti, h.allocator)
			}
			runtime.mem_free(f.data, h.allocator)
		}
	}
	if h.frames != h.home {
		runtime.mem_free_with_size(h.frames, h.room * size_of(Stream_Frame), h.scratch)
	}
	if h.re_ready && h.re_spill.spilled { regex.scratch_destroy(&h.re_scratch) }
	if h.rep_ready { report_destroy(&h.rep) }
}

// ============================================================================
// Refusing hook (dups == .Refuse) + Open_Keys duplicate checker
// ============================================================================

@(private)
stream_sentinel_b :: #force_inline proc "contextless" () -> u64 {
	return u64(uintptr(&STREAM_SENTINEL))
}

@(private)
refusing_done_mark :: #force_inline proc "contextless" (h: ^Refusing_Loader, s: hook.Regs, sent: u64) -> hook.Regs #no_bounds_check {
	r := s
	sf := (^Stream_Field)(uintptr(s.b) - size_of(Stream_Field))
	f := &h.loader.frames[h.done_sp]
	if sf.field_idx < 63 {
		bit := u64(1) << uint(sf.field_idx)
		f.seen0 |= bit
		if (f.seen0 & (bit << 1)) != 0 || ((^Stream_Field)(uintptr(r.b))).kind == .Invalid { r.b = sent }
	} else {
		_ = stream_mark_seen_hi(&h.loader, f, int(sf.field_idx))
		if stream_seen_has(f, int(sf.field_idx) + 1) || ((^Stream_Field)(uintptr(r.b))).kind == .Invalid { r.b = sent }
	}
	return r
}

refusing_loader_hook :: #force_inline proc "contextless" (
	h: ^Refusing_Loader,
	s: hook.Regs,
	t: tape.Token,
	$number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number,
) -> (hook.Regs, hook.Action) #no_bounds_check {
	if h.mode == .Active {
		if t.role == .Value {
			if t.kind >= .Array { open_keys_token(&h.open_keys, t) }
			r, act := stream_loader_hook(&h.loader, s, t, number)
			if act == .Next { return r, .Next }
			if act == .Skip {
				if t.kind == .Object || t.kind == .Array {
					h.saved_b, h.passing, h.mode, r.b = r.b, 1, .Passing, stream_sentinel_b()
				}
				return r, .Next
			}
			if h.loader.fallback || h.loader.oom || h.loader.budget.exceeded.kind != .None { return r, .Stop }
			h.mode, h.done_sp = .Done, h.loader.sp - 1
			sent := stream_sentinel_b()
			if t.kind == .Object || t.kind == .Array {
				h.done_saved_b = r.b if (h.done_sp > 0 && h.loader.frames[h.done_sp].kind == .Struct && ((^Stream_Field)(uintptr(r.b))).kind != .Invalid) else sent
				r.b = sent
			} else if t.kind == .End || h.done_sp == 0 || h.loader.frames[h.done_sp].kind != .Struct || ((^Stream_Field)(uintptr(r.b))).kind == .Invalid {
				r.b, h.done_saved_b = sent, sent
			} else {
				h.done_saved_b = r.b
			}
			return r, .Next
		}
		if t.role == .Key {
			sf := (^Stream_Field)(uintptr(s.b))
			if stream_key_hit(&h.loader, sf, t) {
				pf := &h.loader.frames[h.loader.sp - 1]
				if sf.field_idx < 64 && (pf.seen0 & (u64(1) << uint(sf.field_idx))) == 0 {
					r := s; r.b += size_of(Stream_Field); return r, .Next
				}
			}
			return refusing_key_slow(h, s, t)
		}
		return s, .Next
	}
	if h.mode == .Done {
		if t.role == .Value {
			sent := stream_sentinel_b()
			if t.kind < .Array {
				if int(h.open_keys.depth) == h.done_sp && s.b != sent { return refusing_done_mark(h, s, sent), .Next }
				return s, .Next
			}
			if t.kind == .End {
				open_keys_token(&h.open_keys, t)
				if int(h.open_keys.depth) == h.done_sp { return hook.Regs{s.a, h.done_saved_b, s.c}, .Next }
				if int(h.open_keys.depth) < h.done_sp {
					h.done_sp, h.done_saved_b = int(h.open_keys.depth), sent
					return hook.Regs{s.a, sent, s.c}, .Next
				}
				return s, .Next
			}
			r := s
			if int(h.open_keys.depth) == h.done_sp {
				if s.b != sent { r = refusing_done_mark(h, s, sent) }
				h.done_saved_b, r.b = r.b, sent
			}
			open_keys_token(&h.open_keys, t)
			return r, .Next
		}
		if t.role == .Key {
			if int(h.open_keys.depth) <= h.done_sp && h.open_keys.depth > 0 {
				refusing_done_key(h, t)
				sent := stream_sentinel_b()
				h.done_saved_b = sent
				return hook.Regs{s.a, sent, s.c}, .Next
			}
			open_keys_token(&h.open_keys, t)
		}
		return s, .Next
	}
	if h.mode == .Skip_Next {
		if t.role == .Value {
			if t.kind >= .Array { open_keys_token(&h.open_keys, t) }
			if t.kind == .Object || t.kind == .Array { h.passing, h.mode = 1, .Passing; return s, .Next }
			h.mode = .Active
			return hook.Regs{s.a, h.saved_b, s.c}, .Next
		}
		return s, .Next
	}
	if t.role == .Key {
		open_keys_token(&h.open_keys, t)
	} else if t.role == .Value && t.kind >= .Array {
		open_keys_token(&h.open_keys, t)
		if t.kind == .End {
			h.passing -= 1
			if h.passing == 0 {
				h.mode = .Active
				ret := hook.Regs{s.a, h.saved_b, s.c}
				pf := &h.loader.frames[h.loader.sp - 1]
				if pf.kind == .Map && pf.fflags & SF_KEY_VALID != 0 {
					return stream_map_finish_entry(&h.loader, ret)
				}
				return ret, .Next
			}
		} else {
			h.passing += 1
		}
	}
	return s, .Next
}

@(private, cold)
refusing_key_slow :: #force_no_inline proc "contextless" (h: ^Refusing_Loader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	f := &h.loader.frames[h.loader.sp - 1]
	sent := stream_sentinel_b()
	if f.kind == .Struct {
		// Delegate to `stream_key_miss` first; known non-Read_Only fields are checked via `seen`, others go to `open_keys`.
		r, act := stream_key_miss(&h.loader, s, t)
		if act == .Next {
			sf := (^Stream_Field)(uintptr(r.b) - size_of(Stream_Field))
			if stream_seen_has(f, int(sf.field_idx)) {
				head, _ := h.open_keys.format.bounds(h.open_keys.base[:h.open_keys.src_len], t)
				h.open_keys.repeat = min(h.open_keys.repeat, t.lo - u64(head))
				h.saved_b = s.b
				h.mode = .Skip_Next
				return hook.Regs{s.a, sent, s.c}, .Next
			}
			return r, .Next
		}
		open_keys_token(&h.open_keys, t)
		if act == .Skip {
			h.saved_b = s.b
			h.mode = .Skip_Next
			return hook.Regs{s.a, sent, s.c}, .Next
		}
		if h.loader.fallback || h.loader.oom || h.loader.budget.exceeded.kind != .None {
			return r, .Stop
		}
		h.mode = .Done
		h.done_sp = h.loader.sp - 1
		h.done_saved_b = sent
		return hook.Regs{r.a, sent, r.c}, .Next
	}
	open_keys_token(&h.open_keys, t)
	r, act := stream_key_miss(&h.loader, s, t)
	if act == .Skip {
		h.saved_b = s.b
		h.mode = .Skip_Next
		return hook.Regs{s.a, sent, s.c}, .Next
	}
	if act == .Stop {
		if h.loader.fallback || h.loader.oom || h.loader.budget.exceeded.kind != .None { return r, .Stop }
		h.mode = .Done
		h.done_sp = h.loader.sp - 1
		h.done_saved_b = sent
		return hook.Regs{r.a, sent, r.c}, .Next
	}
	return r, .Next
}

@(private, cold)
refusing_done_key :: #force_no_inline proc "contextless" (h: ^Refusing_Loader, t: tape.Token) #no_bounds_check {
	f := &h.loader.frames[h.open_keys.depth]
	if f.kind == .Struct {
		if t.spelling & tape.SPELLING_DECODE == 0 {
			key := string(h.open_keys.base[t.lo:][:t.n])
			fi := struct_find_field(f.si, key)
			if fi >= 0 && f.si.fields[fi].access != .Read_Only {
				if stream_seen_has(f, fi) {
					head, _ := h.open_keys.format.bounds(h.open_keys.base[:h.open_keys.src_len], t)
					h.open_keys.repeat = min(h.open_keys.repeat, t.lo - u64(head))
					return
				}
				if fi < 64 { f.seen0 |= u64(1) << uint(fi) } else { _ = stream_mark_seen_hi(&h.loader, f, fi) }
				return
			}
			open_keys_token(&h.open_keys, t)
			return
		}
		context = h.loader.ctx
		buf: [128]u8 = ---
		key, owned, ok := stream_decode_token_text(&h.loader, t, buf[:])
		if ok {
			defer if owned { delete(key, h.loader.scratch) }
			fi := struct_find_field(f.si, key)
			if fi >= 0 && f.si.fields[fi].access != .Read_Only {
				if stream_seen_has(f, fi) {
					head, _ := h.open_keys.format.bounds(h.open_keys.base[:h.open_keys.src_len], t)
					h.open_keys.repeat = min(h.open_keys.repeat, t.lo - u64(head))
					return
				}
				if fi < 64 { f.seen0 |= u64(1) << uint(fi) } else { _ = stream_mark_seen_hi(&h.loader, f, fi) }
				return
			}
		}
	}
	open_keys_token(&h.open_keys, t)
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
	} else {
		if t.kind == .End {
			if k.n > 0 && k.room[k.n - 1].depth == k.depth {
				open_keys_close(k)
			}
			k.depth -= 1
		} else {
			k.depth += 1
		}
	}
}

@(private)
open_keys_finish_open :: proc "contextless" (k: ^Open_Keys) {
	for k.n > 0 {
		k.depth = k.room[k.n - 1].depth
		open_keys_close(k)
	}
}

@(private, cold)
open_keys_grow :: #force_no_inline proc "contextless" (k: ^Open_Keys) -> bool {
	context = runtime.default_context()
	next_cap := max(256, 2 * len(k.room))
	fresh, err := make([]Open_Key, next_cap, k.scratch)
	if err != nil { return false }
	copy(fresh, k.room[:k.n])
	if k.heap { delete(k.room, k.scratch) }
	k.room, k.heap = fresh, true
	return true
}

@(private)
open_keys_close :: #force_no_inline proc "contextless" (k: ^Open_Keys) #no_bounds_check {
	from := k.n - 1
	for from > 0 && k.room[from - 1].depth == k.depth { from -= 1 }
	keys := k.room[from:k.n]
	k.n = from
	if len(keys) < 2 { return }
	decoded := false
	for &e in keys { decoded ||= e.key.spelling & tape.SPELLING_DECODE != 0 }
	if decoded || len(keys) > OPEN_KEYS_PAIRED {
		open_keys_hashed(k, keys, decoded)
		return
	}
	base := k.base
	for i in 1 ..< len(keys) {
		a := keys[i].key
		an := a.n
		ap := base[a.lo:]
		for j in 0 ..< i {
			b := keys[j].key
			if b.n == an && open_bytes_eq(base[b.lo:], ap, int(an)) {
				head, _ := k.format.bounds(base[:k.src_len], a)
				k.repeat = min(k.repeat, a.lo - u64(head))
				return
			}
		}
	}
}

@(private)
open_bytes_eq :: #force_inline proc "contextless" (a, b: [^]u8, n: int) -> bool #no_bounds_check {
	i := 0
	for ; i + 8 <= n; i += 8 {
		if intrinsics.unaligned_load((^u64)(a[i:])) != intrinsics.unaligned_load((^u64)(b[i:])) { return false }
	}
	for ; i < n; i += 1 {
		if a[i] != b[i] { return false }
	}
	return true
}

@(private)
open_key_hash :: #force_inline proc "contextless" (p: [^]u8, n: int) -> u64 #no_bounds_check {
	MUL :: u64(0x9E37_79B9_7F4A_7C15)
	h := u64(n) * MUL
	i := 0
	for ; i + 8 <= n; i += 8 {
		h = (h ~ intrinsics.unaligned_load((^u64)(p[i:]))) * MUL
		h ~= h >> 32
	}
	tail: u64
	for ; i < n; i += 1 { tail = tail << 8 | u64(p[i]) }
	h = (h ~ tail) * MUL
	return h ~ (h >> 29)
}

@(private)
open_keys_hashed :: proc "contextless" (k: ^Open_Keys, keys: []Open_Key, decoded: bool) #no_bounds_check {
	size := 16
	for size < 2 * len(keys) { size <<= 1 }
	small: [128]u32 = ---
	slots: []u32
	heap_slots := false
	if size <= len(small) {
		slots = small[:size]
	} else {
		context = runtime.default_context()
		fresh, err := make([]u32, size, k.scratch)
		if err != nil { k.oom = true; return }
		slots, heap_slots = fresh, true
	}
	defer if heap_slots {
		context = runtime.default_context()
		delete(slots, k.scratch)
	}
	mem.zero(raw_data(slots), size * size_of(u32))
	mask := size - 1
	base := k.base
	src := base[:k.src_len]

	if !decoded {
		for &e, i in keys {
			ek := e.key
			ep := base[ek.lo:]
			en := int(ek.n)
			at := int(open_key_hash(ep, en)) & mask
			for ; slots[at] != 0; at = (at + 1) & mask {
				prev := keys[slots[at] - 1].key
				if int(prev.n) == en && open_bytes_eq(base[prev.lo:], ep, en) {
					head, _ := k.format.bounds(src, ek)
					k.repeat = min(k.repeat, ek.lo - u64(head))
					return
				}
			}
			slots[at] = u32(i + 1)
		}
		return
	}

	context = runtime.default_context()
	for &e, i in keys {
		ek := e.key
		at := int(k.format.key_hash(src, ek)) & mask
		for ; slots[at] != 0; at = (at + 1) & mask {
			if tape.same_keys(k.format, src, keys[slots[at] - 1].key, src, ek) {
				head, _ := k.format.bounds(src, ek)
				k.repeat = min(k.repeat, ek.lo - u64(head))
				return
			}
		}
		slots[at] = u32(i + 1)
	}
}

// ============================================================================
// Hot streaming hook (`Stream_Loader`)
// ============================================================================

stream_loader_hook :: #force_inline proc "contextless" (
	h: ^Stream_Loader,
	s: hook.Regs,
	t: tape.Token,
	$number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number,
) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	if t.role == .Key {
		if stream_key_hit(h, (^Stream_Field)(uintptr(s.b)), t) {
			s.b += size_of(Stream_Field)
			return s, .Next
		}
		return stream_key_miss(h, s, t)
	}
	if t.role != .Value {
		return s, .Next
	}
	if t.kind == .End {
		h.sp -= 1
		f := &h.frames[h.sp]
		if f.kind == .Struct {
			si := f.si
			if (si.req_mask0 & ~f.seen0) == 0 && (si.def_mask0 & ~f.seen0) == 0 && !si.has_req_hi && !si.has_def_hi && !si.has_fields_set && len(si.validators) == 0 && f.fflags & SF_HAS_AFTER == 0 && len(f.seen_wide) == 0 {
				h.budget.depth -= 1 + u32(f.fflags >> 3)
				ret := hook.Regs{f.a, f.b, f.c}
				if h.frames[h.sp - 1].kind == .Map {
					return stream_map_finish_entry(h, ret)
				}
				return ret, .Next
			}
		}
		return stream_close(h, f, t)
	}
	if h.budget.limit.nodes > 0 {
		h.budget.nodes += 1
		if h.budget.nodes > h.budget.limit.nodes {
			h.budget.exceeded = {at = t.lo, kind = .Nodes}
			return s, .Stop
		}
	}
	sf := (^Stream_Field)(uintptr(s.b) - size_of(Stream_Field))
	dest: uintptr
	if s.c >= s.a {
		// List or Map element: obtain element slot (and skip if invalid map key or fixed array overflow).
		var_dest: uintptr
		ok, act := stream_container_elem(h, s, t, &var_dest)
		if !ok { return s, act }
		dest = var_dest
	} else {
		// Struct field (or root): mark seen bit on struct frame and keep `.Expects` pointing only at unseen fields.
		if .Is_Root not_in sf.flags {
			pf := &h.frames[h.sp - 1]
			fi := sf.field_idx
			if fi < 63 {
				bit := u64(1) << uint(fi)
				if pf.seen0 & bit != 0 {
					return stream_dup_field(h, s, t)
				}
				pf.seen0 |= bit
				if pf.seen0 & (bit << 1) != 0 {
					s.b = stream_sentinel_b()
				}
			} else {
				if !stream_mark_seen_hi(h, pf, int(fi)) {
					return stream_dup_field(h, s, t)
				}
				if stream_seen_has(pf, int(fi) + 1) {
					s.b = stream_sentinel_b()
				}
			}
		}
		dest = uintptr(s.c) + uintptr(sf.offset)
	}

	#partial switch t.kind {
	case .String:
		if sf.kind != .String {
			return stream_indirect(h, s, t, sf, dest)
		}
		if t.spelling & tape.SPELLING_DECODE != 0 {
			return stream_string_decoded(h, s, t, sf, dest)
		}
		if sf.rule_idx > 0 {
			leaf := &h.plan.leaves[sf.rule_idx - 1]
			if leaf.pattern != nil {
				// Combined regex check + string copy in ONE call (single `context = h.ctx`!).
				if !stream_string_regex_and_copy(h, sf, leaf, dest, t) {
					if stream_stopped(h) { return s, .Stop }
					if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
					return s, .Next
				}
			} else {
				str := string(h.base[t.lo:][:t.n])
				fails: rules.Failures
				if leaf.min_length > 0 || leaf.max_length < max(u64) {
					n := u64(t.n) if t.spelling & tape.SPELLING_ASCII != 0 else u64(kernel.count_chars(transmute([]u8)str))
					if n < leaf.min_length { fails += {.Too_Short} }
					if n > leaf.max_length { fails += {.Too_Long} }
				}
				if leaf.formats != {} || fails != {} {
					if !stream_check_string_report(h, sf, leaf, str, fails, t.lo) {
						if stream_stopped(h) { return s, .Stop }
						if s.c >= s.a && h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
						return s, .Next
					}
				}
				if (h.first.kind == .None || h.has_val) && t.n > 0 {
					if !stream_copy_string(h, dest, t.lo, t.n) { return s, .Stop }
				}
			}
		} else if (h.first.kind == .None || h.has_val) && t.n > 0 {
			if !stream_copy_string(h, dest, t.lo, t.n) { return s, .Stop }
		}
	case .Number:
		if sf.kind == .I64 {
			n := number(h.base[:h.src_len], t)
			if n.kind != .Int {
				return stream_number_cold(h, s, t, sf, dest)
			}
			v := i64(n.bits)
			(^i64)(dest)^ = v
			if sf.rule_idx > 0 {
				leaf := &h.plan.leaves[sf.rule_idx - 1]
				if leaf.fast {
					if (leaf.minimum.set && (v < leaf.minimum.int || (v == leaf.minimum.int && leaf.minimum.exclusive))) ||
					   (leaf.maximum.set && (v > leaf.maximum.int || (v == leaf.maximum.int && leaf.maximum.exclusive))) {
						return stream_number_fail(h, s, t, sf, v)
					}
				} else {
					return stream_number_leaf_cold(h, s, t, sf, v)
				}
			}
		} else if sf.kind == .F64 {
			n := number(h.base[:h.src_len], t)
			fv: f64
			if n.kind == .Float {
				fv = transmute(f64)n.bits
				if math.is_nan(fv) || math.is_inf(fv, 0) {
					return stream_number_cold(h, s, t, sf, dest)
				}
			} else if n.kind == .Int && (n.bits != 0 || t.n == 1) {
				fv = f64(i64(n.bits))
			} else {
				return stream_number_cold(h, s, t, sf, dest)
			}
			(^f64)(dest)^ = fv
			if sf.rule_idx > 0 {
				leaf := &h.plan.leaves[sf.rule_idx - 1]
				if leaf.fast && leaf.minimum.int >= -F64_EXACT_INT_MAX && leaf.minimum.int <= F64_EXACT_INT_MAX && leaf.maximum.int >= -F64_EXACT_INT_MAX && leaf.maximum.int <= F64_EXACT_INT_MAX {
					lo_bad := leaf.minimum.set && fv <= f64(leaf.minimum.int)
					hi_bad := leaf.maximum.set && fv >= f64(leaf.maximum.int)
					if lo_bad || hi_bad {
						return stream_f64_leaf_cold(h, s, t, sf, fv)
					}
				} else {
					return stream_f64_leaf_cold(h, s, t, sf, fv)
				}
			}
		} else if sf.kind >= .I8 && sf.kind <= .U64 {
			n := number(h.base[:h.src_len], t)
			v := i64(n.bits)
			if n.kind != .Int || v < INT_MIN_TABLE[sf.kind] || v > INT_MAX_TABLE[sf.kind] {
				return stream_number_cold(h, s, t, sf, dest)
			}
			stream_store_int(dest, n.bits, sf.kind)
			if sf.rule_idx > 0 {
				leaf := &h.plan.leaves[sf.rule_idx - 1]
				if leaf.fast {
					if (leaf.minimum.set && (v < leaf.minimum.int || (v == leaf.minimum.int && leaf.minimum.exclusive))) ||
					   (leaf.maximum.set && (v > leaf.maximum.int || (v == leaf.maximum.int && leaf.maximum.exclusive))) {
						return stream_number_fail(h, s, t, sf, v)
					}
				} else {
					return stream_number_leaf_cold(h, s, t, sf, v)
				}
			}
		} else {
			return stream_indirect(h, s, t, sf, dest)
		}
	case .True, .False:
		if sf.kind != .Bool {
			return stream_indirect(h, s, t, sf, dest)
		}
		(^bool)(dest)^ = t.kind == .True
	case .Object:
		if sf.kind != .Struct {
			return stream_indirect(h, s, t, sf, dest)
		}
		if h.budget.depth + 1 > h.budget.max_depth {
			h.budget.exceeded = {at = t.lo, kind = .Depth}
			return s, .Stop
		}
		if h.sp == h.room && !stream_frames_grow(h) {
			h.oom = true
			return s, .Stop
		}
		h.budget.depth += 1
		si := &h.plan.structs[sf.struct_idx]
		f := &h.frames[h.sp]
		h.sp += 1
		f.a, f.b, f.c = s.a, s.b, s.c
		f.kind = .Struct
		f.node_idx = sf.node
		f.si = si
		f.seen0, f.seen1, f.seen_wide = 0, 0, nil
		f.target = rawptr(dest)
		f.open_at = t.lo
		f.start_fails = h.fail_count
		f.fflags = SF_HAS_AFTER if .Has_After in sf.flags else 0
		f.parent_fi = sf.field_idx
		return {STREAM_NO_LIMIT, u64(uintptr(raw_data(si.stream_fields))), u64(dest)}, .Next
	case:
		return stream_indirect(h, s, t, sf, dest)
	}

	if .Has_After in sf.flags {
		if !stream_run_field_after(h, sf, dest, t.lo) { return s, .Stop }
	}
	if s.c >= s.a && h.frames[h.sp - 1].kind == .Map {
		return stream_map_finish_entry(h, s)
	}
	return s, .Next
}

@(private)
stream_key_hit :: #force_inline proc "contextless" (h: ^Stream_Loader, k: ^Stream_Field, t: tape.Token) -> bool #no_bounds_check {
	when ODIN_ENDIAN != .Little { #panic("stream_key_hit requires little-endian") }
	if (transmute([2]u64)t)[1] & KEY_MASK != k.word { return false }
	p := h.base[t.lo:]
	n := u64(t.n)
	if n <= 8 {
		return t.lo + 8 <= h.src_len && (kernel.load8(p) ~ k.head) & k.tail == 0
	}
	if kernel.load8(p) != k.head || kernel.load8(p[n - 8:]) != k.tail { return false }
	return n <= 16 || stream_key_rest(h, k, p, n)
}

@(private, cold)
stream_key_rest :: #force_no_inline proc "contextless" (h: ^Stream_Loader, k: ^Stream_Field, p: [^]u8, n: u64) -> bool #no_bounds_check {
	f := &h.frames[h.sp - 1]
	return string(p[8:n - 8]) == f.si.fields[k.field_idx].name[8:n - 8]
}

@(private)
stream_stopped :: #force_inline proc "contextless" (h: ^Stream_Loader) -> bool {
	return h.oom || h.budget.exceeded.kind != .None || (h.sink == nil && h.first.kind != .None)
}

@(private)
stream_store_int :: #force_inline proc "contextless" (dest: uintptr, v: u64, kind: Type_Kind) {
	#partial switch kind {
	case .I8, .U8:   (^u8)(dest)^ = u8(v)
	case .I16, .U16: (^u16)(dest)^ = u16(v)
	case .I32, .U32: (^u32)(dest)^ = u32(v)
	case:            (^u64)(dest)^ = v
	}
}

@(private)
stream_copy_short :: #force_inline proc "contextless" (dst, src: [^]u8, n: int) #no_bounds_check {
	switch {
	case n > 32:
		intrinsics.mem_copy_non_overlapping(dst, src, n)
	case n >= 16:
		a := intrinsics.unaligned_load((^[16]u8)(src))
		b := intrinsics.unaligned_load((^[16]u8)(src[n - 16:]))
		intrinsics.unaligned_store((^[16]u8)(dst), a)
		intrinsics.unaligned_store((^[16]u8)(dst[n - 16:]), b)
	case n >= 8:
		a := intrinsics.unaligned_load((^u64)(src))
		b := intrinsics.unaligned_load((^u64)(src[n - 8:]))
		intrinsics.unaligned_store((^u64)(dst), a)
		intrinsics.unaligned_store((^u64)(dst[n - 8:]), b)
	case n >= 4:
		a := intrinsics.unaligned_load((^u32)(src))
		b := intrinsics.unaligned_load((^u32)(src[n - 4:]))
		intrinsics.unaligned_store((^u32)(dst), a)
		intrinsics.unaligned_store((^u32)(dst[n - 4:]), b)
	case:
		for i in 0 ..< n { dst[i] = src[i] }
	}
}

// Fast contextless bump allocation when `h.allocator` is a `mem.Arena`; falls back to generic allocator proc otherwise.
@(private)
stream_alloc_str :: #force_inline proc "contextless" (h: ^Stream_Loader, dest: uintptr, src: [^]u8, n: int) -> bool #no_bounds_check {
	if h.allocator.procedure == mem.arena_allocator_proc {
		ar := (^mem.Arena)(h.allocator.data)
		off := ar.offset
		if off <= len(ar.data) && n <= len(ar.data) - off {
			p := raw_data(ar.data)[off:]
			ar.offset = off + n
			if ar.offset > ar.peak_used { ar.peak_used = ar.offset }
			stream_copy_short(p, src, n)
			(^runtime.Raw_String)(dest)^ = {p, n}
			h.wrote_alloc = true
			return true
		}
	}
	return stream_alloc_str_slow(h, dest, src, n)
}

@(private, cold)
stream_alloc_str_slow :: #force_no_inline proc "contextless" (h: ^Stream_Loader, dest: uintptr, src: [^]u8, n: int) -> bool #no_bounds_check {
	context = h.ctx
	raw, err := h.allocator.procedure(h.allocator.data, .Alloc_Non_Zeroed, n, 1, nil, 0)
	if err != nil || len(raw) < n || raw_data(raw) == nil { h.oom = true; return false }
	stream_copy_short(raw_data(raw), src, n)
	(^runtime.Raw_String)(dest)^ = {raw_data(raw), n}
	h.wrote_alloc = true
	return true
}

// Combined check + copy for regex-constrained strings: one `context = h.ctx` and one call instead of two!
@(private)
stream_string_regex_and_copy :: #force_no_inline proc "contextless" (h: ^Stream_Loader, sf: ^Stream_Field, leaf: ^rules.Leaf, dest: uintptr, t: tape.Token) -> bool #no_bounds_check {
	context = h.ctx
	str := string(h.base[t.lo:][:t.n])
	fails: rules.Failures
	if leaf.min_length > 0 || leaf.max_length < max(u64) {
		n := u64(t.n) if t.spelling & tape.SPELLING_ASCII != 0 else u64(kernel.count_chars(transmute([]u8)str))
		if n < leaf.min_length { fails += {.Too_Short} }
		if n > leaf.max_length { fails += {.Too_Long} }
	}
	if !h.re_ready {
		rerr: regex.Error
		h.re_scratch, rerr = regex.scratch_make(stack_spill_allocator(h.re_spill))
		if rerr.kind != .None { h.oom = true; return false }
		h.re_ready = true
	}
	found, rerr := regex.search(leaf.pattern, str, 0, nil, &h.re_scratch, 0)
	if rerr.kind != .None { fails += {.Pattern_Undecided} } else if !found { fails += {.No_Match} }
	if leaf.formats != {} || fails != {} {
		if !stream_check_string_report(h, sf, leaf, str, fails, t.lo) { return false }
	}
	if (h.first.kind == .None || h.has_val) && t.n > 0 {
		if !stream_alloc_str(h, dest, h.base[t.lo:], int(t.n)) { return false }
	}
	return true
}

@(private)
stream_copy_string :: #force_inline proc "contextless" (h: ^Stream_Loader, dest: uintptr, lo: u64, n: u32) -> bool #no_bounds_check {
	return stream_alloc_str(h, dest, h.base[lo:], int(n))
}

@(private)
stream_check_string :: #force_inline proc "contextless" (h: ^Stream_Loader, sf: ^Stream_Field, s: string, ascii: bool, at: u64) -> bool #no_bounds_check {
	leaf := &h.plan.leaves[sf.rule_idx - 1]
	fails: rules.Failures
	if leaf.min_length > 0 || leaf.max_length < max(u64) {
		n := u64(len(s)) if ascii else u64(kernel.count_chars(transmute([]u8)s))
		if n < leaf.min_length { fails += {.Too_Short} }
		if n > leaf.max_length { fails += {.Too_Long} }
	}
	if leaf.pattern != nil {
		found, undecided := stream_match_regex(h, leaf.pattern, s)
		if undecided { fails += {.Pattern_Undecided} } else if !found { fails += {.No_Match} }
	}
	if leaf.formats != {} || fails != {} {
		return stream_check_string_report(h, sf, leaf, s, fails, at)
	}
	return true
}

@(private)
stream_match_regex :: #force_no_inline proc "contextless" (h: ^Stream_Loader, re: ^regex.Regex, s: string) -> (found, undecided: bool) {
	context = h.ctx
	if !h.re_ready {
		rs, rerr := regex.scratch_make(stack_spill_allocator(h.re_spill))
		if rerr.kind != .None { h.oom = true; return false, false }
		h.re_scratch = rs
		h.re_ready = true
	}
	f, rerr := regex.search(re, s, 0, nil, &h.re_scratch, 0)
	return f, rerr.kind != .None
}

// ============================================================================
// Cold paths: key miss, container open/close, rare scalars, errors, validators
// ============================================================================

@(private, cold)
stream_decode_token_text :: proc(h: ^Stream_Loader, t: tape.Token, buf: []u8) -> (s: string, owned, ok: bool) {
	if t.spelling & tape.SPELLING_DECODE == 0 {
		return string(h.base[t.lo:][:t.n]), false, true
	}
	src := h.base[:h.src_len]
	if out, dok := h.format.decode(src, t, buf, nil); dok {
		return out, false, true
	}
	room := h.format.room(src, t, nil) if h.format.room != nil else int(t.n)
	if room <= 0 { return "", false, false }
	heap, err := make([]u8, room, h.scratch)
	if err != nil { h.oom = true; return "", false, false }
	out, dok := h.format.decode(src, t, heap, nil)
	if !dok { delete(heap, h.scratch); return "", false, false }
	return out, true, true
}

@(private, cold)
stream_key_miss :: #force_no_inline proc "contextless" (h: ^Stream_Loader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx
	f := &h.frames[h.sp - 1]
	buf: [128]u8 = ---
	key, owned, ok := stream_decode_token_text(h, t, buf[:])
	if !ok { return s, .Stop }

	if f.kind == .Map {
		if f.fflags & SF_KEY_OWNED != 0 { delete(f.cur_key, h.scratch); f.fflags &~= SF_KEY_OWNED }
		f.cur_key = key
		if owned { f.fflags |= SF_KEY_OWNED }
		f.key_at = t.lo
		f.start_fails = h.fail_count
		f.fflags &~= SF_KEY_VALID
		tn := &h.plan.nodes[f.node_idx]
		ktn := &h.plan.nodes[tn.key_node]
		vtn := &h.plan.nodes[tn.child]
		mem.zero(f.data, max(ktn.size, 1))
		mem.zero(f.val_buf, max(vtn.size, 1))
		if !stream_decode_map_key(h, ktn, key, f.data, t.lo) {
			if stream_stopped(h) { return s, .Stop }
			return s, .Skip
		}
		f.fflags |= SF_KEY_VALID
		f.count += 1
		return s, .Next
	}
	defer if owned { delete(key, h.scratch) }

	si := f.si
	fi := struct_find_field(si, key)
	if fi < 0 {
		if si.forbid_extra {
			if h.policy != .Refuse { h.fallback = true; return s, .Stop }
			if !stream_fail(h, .Not_Allowed, t.lo, "", {}, extra_step = tape.Step(tape.Name(key))) {
				return s, .Stop
			}
		}
		return s, .Skip
	}
	fld := &si.fields[fi]
	if fld.access == .Read_Only {
		if si.forbid_extra {
			if h.policy != .Refuse { h.fallback = true; return s, .Stop }
			if !stream_fail(h, .Not_Allowed, t.lo, "", {}, extra_step = tape.Step(tape.Name(key))) {
				return s, .Stop
			}
		}
		return s, .Skip
	}
	r := s
	r.b = u64(uintptr(&si.stream_fields[fi]) + size_of(Stream_Field))
	return r, .Next
}

// Pushes a `.Skipped` frame when `Stream_Loader` (which has `.Skips`) returns `.Skip` on `.Object`/`.Array`,
// because `walk_text` `st_skip_open` still delivers the matching `.End` token after skipping the container.
@(private, cold)
stream_skip_container :: proc "contextless" (h: ^Stream_Loader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.kind != .Object && t.kind != .Array {
		return s, .Next
	}
	if h.policy != .Refuse {
		if h.sp == h.room && !stream_frames_grow(h) { h.oom = true; return s, .Stop }
		f := &h.frames[h.sp]; h.sp += 1
		f.a, f.b, f.c = s.a, s.b, s.c
		f.kind, f.fflags, f.seen_wide = .Skipped, 0, nil
	}
	return s, .Skip
}

@(private, cold)
stream_dup_field :: #force_no_inline proc "contextless" (h: ^Stream_Loader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if h.policy == .Last {
		h.fallback = true
		return s, .Stop
	}
	return stream_skip_container(h, s, t)
}

@(private, cold)
stream_mark_seen_hi :: #force_no_inline proc "contextless" (h: ^Stream_Loader, f: ^Stream_Frame, fi: int) -> bool {
	if fi < 64 {
		bit := u64(1) << uint(fi)
		if f.seen0 & bit != 0 { return false }
		f.seen0 |= bit
		return true
	}
	if fi < 128 {
		bit := u64(1) << uint(fi - 64)
		if f.seen1 & bit != 0 { return false }
		f.seen1 |= bit
		return true
	}
	w := (fi - 128) / 64
	if w >= len(f.seen_wide) {
		context = h.ctx
		fresh, err := make([]u64, max(w + 1, (len(f.si.fields) - 128 + 63) / 64), h.scratch)
		if err != nil { h.oom = true; return false }
		if len(f.seen_wide) > 0 { copy(fresh, f.seen_wide); delete(f.seen_wide, h.scratch) }
		f.seen_wide = fresh
	}
	bit := u64(1) << uint((fi - 128) % 64)
	if f.seen_wide[w] & bit != 0 { return false }
	f.seen_wide[w] |= bit
	return true
}

@(private)
stream_seen_has :: #force_inline proc "contextless" (f: ^Stream_Frame, fi: int) -> bool {
	if fi < 64 { return (f.seen0 >> uint(fi)) & 1 != 0 }
	if fi < 128 { return (f.seen1 >> uint(fi - 64)) & 1 != 0 }
	w := (fi - 128) / 64
	return w < len(f.seen_wide) && (f.seen_wide[w] >> uint((fi - 128) % 64)) & 1 != 0
}

@(private, cold)
stream_frames_grow :: #force_no_inline proc "contextless" (h: ^Stream_Loader) -> bool {
	context = h.ctx
	next_cap := h.room * 2
	raw, err := runtime.mem_alloc_non_zeroed(next_cap * size_of(Stream_Frame), align_of(Stream_Frame), h.scratch)
	if err != nil || raw_data(raw) == nil { return false }
	grown := ([^]Stream_Frame)(raw_data(raw))
	intrinsics.mem_copy_non_overlapping(grown, h.frames, h.room * size_of(Stream_Frame))
	if h.frames != h.home {
		runtime.mem_free_with_size(h.frames, h.room * size_of(Stream_Frame), h.scratch)
	}
	h.frames, h.room = grown, next_cap
	return true
}

@(private, cold)
stream_container_elem :: #force_no_inline proc "contextless" (h: ^Stream_Loader, s: hook.Regs, t: tape.Token, out_dest: ^uintptr) -> (bool, hook.Action) {
	context = h.ctx
	f := &h.frames[h.sp - 1]
	#partial switch f.kind {
	case .Map:
		if f.fflags & SF_KEY_VALID == 0 {
			_, act := stream_skip_container(h, s, t)
			return false, act
		}
		out_dest^ = uintptr(f.val_buf)
		return true, .Next
	case .Slice, .Dynamic:
		if f.count == f.cap {
			next_cap := max(4, f.cap * 2)
			ctn := &h.plan.nodes[h.plan.nodes[f.node_idx].child]
			sz := next_cap * max(int(f.stride), 1)
			raw, err := runtime.mem_alloc(sz, ctn.align, h.allocator)
			if err != nil { h.oom = true; return false, .Stop }
			if f.data != nil {
				if f.count > 0 && f.stride > 0 {
					intrinsics.mem_copy_non_overlapping(raw_data(raw), f.data, f.count * int(f.stride))
				}
				runtime.mem_free(f.data, h.allocator)
			}
			f.data, f.cap = raw_data(raw), next_cap
			h.wrote_alloc = true
		}
		out_dest^ = uintptr(f.data) + uintptr(f.count) * uintptr(f.stride)
		f.count += 1
		return true, .Next
	case .Array, .Fixed_List:
		idx := f.count
		f.count += 1
		if idx >= f.cap {
			_, act := stream_skip_container(h, s, t)
			return false, act
		}
		out_dest^ = uintptr(f.data) + uintptr(idx) * uintptr(f.stride)
		return true, .Next
	}
	return false, .Stop
}

@(private, cold)
stream_map_finish_entry :: #force_no_inline proc "contextless" (h: ^Stream_Loader, s: hook.Regs) -> (hook.Regs, hook.Action) {
	context = h.ctx
	f := &h.frames[h.sp - 1]
	if f.fflags & SF_KEY_VALID == 0 { return s, .Next }
	f.fflags &~= SF_KEY_VALID
	tn := &h.plan.nodes[f.node_idx]
	ktn := &h.plan.nodes[tn.key_node]
	vtn := &h.plan.nodes[tn.child]
	if h.fail_count != f.start_fails || (h.first.kind != .None && !h.has_val) {
		free_value(f.data, ktn.ti, h.allocator)
		free_value(f.val_buf, vtn.ti, h.allocator)
		return s, .Next
	}
	m_info := runtime.type_info_base(tn.ti).variant.(^runtime.Type_Info_Map)
	rm := (^runtime.Raw_Map)(f.target)
	if rm.allocator.procedure == nil { rm.allocator = h.allocator }
	// Free any overwritten entry (e.g. duplicate string key before `.Refuse` finishes, or colliding numeric keys like `"1"` and `"01"`).
	if rm.len > 0 {
		if existing := map_entry(rm, m_info^, f.data); existing != nil {
			free_value(f.data, ktn.ti, h.allocator)
			free_value(existing, vtn.ti, h.allocator)
			if vtn.size > 0 { mem.copy(existing, f.val_buf, vtn.size) }
			mem.zero(f.val_buf, max(vtn.size, 1))
			h.wrote_alloc = true
			return s, .Next
		}
	}
	if _, merr := runtime.__dynamic_map_set_without_hash(rm, m_info.map_info, f.data, f.val_buf); merr != nil {
		free_value(f.data, ktn.ti, h.allocator)
		free_value(f.val_buf, vtn.ti, h.allocator)
		h.oom = true
		return s, .Stop
	}
	mem.zero(f.data, max(ktn.size, 1))
	mem.zero(f.val_buf, max(vtn.size, 1))
	h.wrote_alloc = true
	return s, .Next
}

@(private)
stream_close :: #force_no_inline proc "contextless" (h: ^Stream_Loader, f: ^Stream_Frame, t: tape.Token) -> (hook.Regs, hook.Action) {
	context = h.ctx
	ret := hook.Regs{f.a, f.b, f.c}
	if f.kind != .Skipped { h.budget.depth -= 1 + u32(f.fflags >> 3) }
	#partial switch f.kind {
	case .Struct:
		defer if len(f.seen_wide) > 0 { delete(f.seen_wide, h.scratch); f.seen_wide = nil }
		si := f.si
		if si.has_fields_set && (h.first.kind == .None || h.has_val) {
			fs := (^Fields_Set)(uintptr(f.target) + si.fields_set_offset)
			fs.bits = {f.seen0, f.seen1}
			if len(f.seen_wide) > 0 {
				wcopy, werr := make([]u64, len(f.seen_wide), h.allocator)
				if werr != nil { h.oom = true; return ret, .Stop }
				copy(wcopy, f.seen_wide)
				fs.wide = wcopy
				h.wrote_alloc = true
			}
		}

		close_at := t.lo + 1
		// Fast bitmask loop for fields 0..63 when missing defaults or required fields exist.
		miss_def := si.def_mask0 & ~f.seen0
		for miss_def != 0 {
			fi := int(intrinsics.count_trailing_zeros(miss_def))
			miss_def &= miss_def - 1
			if h.first.kind == .None || h.has_val {
				fld := &si.fields[fi]
				if fld.make_default(rawptr(uintptr(f.target) + fld.offset), fld.default_data, h.allocator) != nil {
					h.oom = true; return ret, .Stop
				}
				h.wrote_alloc = true
			}
		}
		miss_req := si.req_mask0 & ~f.seen0
		for miss_req != 0 {
			fi := int(intrinsics.count_trailing_zeros(miss_req))
			miss_req &= miss_req - 1
			fld := &si.fields[fi]
			if !stream_fail_at_depth(h, h.sp + 1, .Missing_Field, close_at, "", {}, extra_step = tape.Step(tape.Name(fld.name))) {
				return ret, .Stop
			}
		}
		if si.has_req_hi || si.has_def_hi {
			for fi in 64 ..< len(si.fields) {
				if stream_seen_has(f, fi) { continue }
				fld := &si.fields[fi]
				if fld.access == .Read_Only { continue }
				if fld.has_default {
					if h.first.kind == .None || h.has_val {
						if fld.make_default(rawptr(uintptr(f.target) + fld.offset), fld.default_data, h.allocator) != nil {
							h.oom = true; return ret, .Stop
						}
						h.wrote_alloc = true
					}
				} else if fld.required {
					if !stream_fail_at_depth(h, h.sp + 1, .Missing_Field, close_at, "", {}, extra_step = tape.Step(tape.Name(fld.name))) {
						return ret, .Stop
					}
				}
			}
		}
		if len(si.validators) > 0 && h.fail_count == f.start_fails {
			if !stream_ensure_report(h) { return ret, .Stop }
			for sv in si.validators { sv.call(f.target, sv.fn, &h.rep) }
			if !stream_emit_report(h, h.sp + 1, f.open_at, si) { return ret, .Stop }
		}
	case .Slice, .Dynamic, .Array, .Fixed_List:
		tn := &h.plan.nodes[f.node_idx]
		#partial switch f.kind {
		case .Slice:
			if f.count > 0 && f.count < f.cap && f.stride > 0 {
				ctn := &h.plan.nodes[tn.child]
				exact, err := runtime.mem_alloc_non_zeroed(f.count * int(f.stride), ctn.align, h.allocator)
				if err == nil {
					intrinsics.mem_copy_non_overlapping(raw_data(exact), f.data, f.count * int(f.stride))
					runtime.mem_free(f.data, h.allocator)
					f.data = raw_data(exact)
				}
			}
			rs := (^runtime.Raw_Slice)(f.target)
			rs.data, rs.len = f.data, f.count
			f.data = nil
		case .Dynamic:
			rd := (^runtime.Raw_Dynamic_Array)(f.target)
			rd.data, rd.len, rd.cap, rd.allocator = f.data, f.count, f.cap, h.allocator
			f.data = nil
		case .Fixed_List:
			(^int)(uintptr(f.target) + tn.len_offset)^ = min(f.count, tn.count)
		}
		cap_bad := (tn.kind == .Array && f.count < tn.count) || ((tn.kind == .Array || tn.kind == .Fixed_List) && f.count > tn.count)
		if cap_bad {
			if !stream_fail_at_depth(h, h.sp + 1, .Too_Few if f.count < tn.count else .Too_Many, f.open_at) { return ret, .Stop }
		} else if f.rule_idx > 0 {
			steps_buf: [32]tape.Step = ---
			steps, owned := stream_build_steps(h, h.sp + 1, steps_buf[:])
			defer if owned { delete(steps, h.scratch) }
			if !check_count_leaf(h.plan, f.rule_idx, u64(f.count), false, f.open_at, steps, h.sink, &h.first, &h.oom, h.allocator, h.scratch, false) {
				h.fail_count += 1
				if stream_stopped(h) { return ret, .Stop }
			}
		}
	case .Map:
		if f.fflags & SF_KEY_OWNED != 0 { delete(f.cur_key, h.scratch); f.fflags &~= SF_KEY_OWNED }
		if f.data != nil { runtime.mem_free(f.data, h.scratch); f.data = nil }
		if f.val_buf != nil { runtime.mem_free(f.val_buf, h.scratch); f.val_buf = nil }
		if f.rule_idx > 0 {
			steps_buf: [32]tape.Step = ---
			steps, owned := stream_build_steps(h, h.sp + 1, steps_buf[:])
			defer if owned { delete(steps, h.scratch) }
			if !check_count_leaf(h.plan, f.rule_idx, u64(f.count), true, f.open_at, steps, h.sink, &h.first, &h.oom, h.allocator, h.scratch, false) {
				h.fail_count += 1
				if stream_stopped(h) { return ret, .Stop }
			}
		}
	}

	if f.fflags & SF_HAS_AFTER != 0 && h.fail_count == f.start_fails {
		pf := &h.frames[h.sp - 1]
		if pf.kind == .Struct {
			if !stream_ensure_report(h) { return ret, .Stop }
			for av in pf.si.fields[f.parent_fi].afters { av.call(f.target, av.fn, &h.rep) }
			if !stream_emit_report(h, h.sp + 1, f.open_at, nil) { return ret, .Stop }
		}
	}
	if h.frames[h.sp - 1].kind == .Map {
		return stream_map_finish_entry(h, ret)
	}
	return ret, .Next
}

@(private, cold)
stream_ensure_report :: proc(h: ^Stream_Loader) -> bool {
	if !h.rep_ready {
		report_init(&h.rep, h.scratch)
		h.rep_ready = true
	} else {
		report_reset(&h.rep)
	}
	return true
}

@(private, cold)
stream_emit_report :: proc(h: ^Stream_Loader, sp: int, at: u64, si: ^Struct_Info, sf: ^Stream_Field = nil) -> bool {
	if !h.rep.failed && !h.rep.oom { return true }
	h.fail_count += 1
	steps_buf: [32]tape.Step = ---
	steps, owned := stream_build_steps(h, sp, steps_buf[:], sf)
	defer if owned { delete(steps, h.scratch) }
	_ = emit_report(&h.rep, steps, at, si, h.sink, &h.first, &h.oom, h.allocator, h.scratch, false)
	return !stream_stopped(h)
}

@(private, cold)
stream_check_num_leaf :: proc(h: ^Stream_Loader, rule_idx: i32, text: string, small: Maybe(i64), at: u64, sf: ^Stream_Field) -> bool {
	if rule_idx <= 0 { return true }
	steps_buf: [32]tape.Step = ---
	steps, owned := stream_build_steps(h, h.sp, steps_buf[:], sf)
	defer if owned { delete(steps, h.scratch) }
	if !check_number_leaf(h.plan, rule_idx, text, small, at, steps, h.sink, &h.first, &h.oom, h.allocator, h.scratch, false) {
		h.fail_count += 1
		return false
	}
	return true
}

@(private, cold)
stream_run_field_after :: #force_no_inline proc "contextless" (h: ^Stream_Loader, sf: ^Stream_Field, dest: uintptr, at: u64) -> bool {
	context = h.ctx
	pf := &h.frames[h.sp - 1]
	if pf.kind != .Struct { return true }
	if !stream_ensure_report(h) { return false }
	for av in pf.si.fields[sf.field_idx].afters { av.call(rawptr(dest), av.fn, &h.rep) }
	return stream_emit_report(h, h.sp, at, nil, sf)
}

@(private, cold)
stream_build_steps :: proc(h: ^Stream_Loader, sp: int, buf: []tape.Step, leaf_sf: ^Stream_Field = nil, extra_step: Maybe(tape.Step) = nil) -> (steps: []tape.Step, owned: bool) {
	// Count needed steps: frames[1 ..< sp] each contribute 1 step from their parent, plus optional leaf_sf/extra_step.
	n := 0
	// Walk frames 1 ..< sp: frame i's position inside frame i-1.
	dyn: [dynamic]tape.Step
	push :: proc(h: ^Stream_Loader, buf: []tape.Step, n: ^int, dyn: ^[dynamic]tape.Step, owned: ^bool, st: tape.Step) {
		if !owned^ {
			if n^ < len(buf) {
				buf[n^] = st
				n^ += 1
				return
			}
			dyn^ = make([dynamic]tape.Step, 0, len(buf) * 2, h.scratch)
			append(dyn, ..buf[:n^])
			owned^ = true
		}
		_, _ = append(dyn, st)
	}

	for i in 1 ..< sp {
		parent := &h.frames[i - 1]
		child := &h.frames[i]
		#partial switch parent.kind {
		case .Struct:
			sf := (^Stream_Field)(uintptr(child.b) - size_of(Stream_Field))
			push(h, buf, &n, &dyn, &owned, tape.Step(tape.Name(parent.si.fields[sf.field_idx].name)))
		case .Slice, .Dynamic, .Array, .Fixed_List:
			push(h, buf, &n, &dyn, &owned, tape.Step(tape.Index(parent.count - 1)))
		case .Map:
			push(h, buf, &n, &dyn, &owned, tape.Step(tape.Name(parent.cur_key)))
		}
	}
	if sp > 0 {
		top := &h.frames[sp - 1]
		if leaf_sf != nil && top.kind == .Struct && .Is_Root not_in leaf_sf.flags {
			push(h, buf, &n, &dyn, &owned, tape.Step(tape.Name(top.si.fields[leaf_sf.field_idx].name)))
		} else if leaf_sf != nil && (top.kind == .Slice || top.kind == .Dynamic || top.kind == .Array || top.kind == .Fixed_List) {
			push(h, buf, &n, &dyn, &owned, tape.Step(tape.Index(top.count - 1)))
		} else if leaf_sf != nil && top.kind == .Map {
			push(h, buf, &n, &dyn, &owned, tape.Step(tape.Name(top.cur_key)))
		}
	}
	if ex, has_ex := extra_step.?; has_ex {
		push(h, buf, &n, &dyn, &owned, ex)
	}
	return dyn[:] if owned else buf[:n], owned
}

@(private, cold)
stream_fail :: #force_no_inline proc(h: ^Stream_Loader, kind: Error_Kind, at: u64, operand := "", want := Want{}, sf: ^Stream_Field = nil, extra_step: Maybe(tape.Step) = nil) -> bool {
	return stream_fail_at_depth(h, h.sp, kind, at, operand, want, sf, extra_step)
}

@(private, cold)
stream_fail_at_depth :: proc(h: ^Stream_Loader, sp: int, kind: Error_Kind, at: u64, operand := "", want := Want{}, sf: ^Stream_Field = nil, extra_step: Maybe(tape.Step) = nil) -> bool {
	h.fail_count += 1
	buf: [32]tape.Step = ---
	steps, owned := stream_build_steps(h, sp, buf[:], sf, extra_step)
	defer if owned { delete(steps, h.scratch) }
	return record_failure(h.sink, &h.first, &h.oom, h.allocator, kind, at, steps, operand, want, false)
}

@(private, cold)
stream_check_string_report :: #force_no_inline proc "contextless" (h: ^Stream_Loader, sf: ^Stream_Field, leaf: ^rules.Leaf, s: string, init_fails: rules.Failures, at: u64) -> bool {
	context = h.ctx
	fails := init_fails
	for fmt_kind in leaf.formats {
		if !rules.format_valid(fmt_kind, s, h.scratch) {
			fails += {.Bad_Format}
		}
	}
	if fails == {} { return true }
	h.fail_count += 1
	steps_buf: [32]tape.Step = ---
	steps, owned := stream_build_steps(h, h.sp, steps_buf[:], sf)
	defer if owned { delete(steps, h.scratch) }
	_ = emit_leaf_fails(leaf, fails, false, at, steps, h.sink, &h.first, &h.oom, h.allocator, h.scratch, false)
	return false
}

@(private, cold)
stream_string_decoded :: #force_no_inline proc "contextless" (h: ^Stream_Loader, s: hook.Regs, t: tape.Token, sf: ^Stream_Field, dest: uintptr) -> (hook.Regs, hook.Action) {
	context = h.ctx
	buf: [256]u8 = ---
	text, owned, ok := stream_decode_token_text(h, t, buf[:])
	if !ok { return s, .Stop }
	defer if owned { delete(text, h.scratch) }
	if sf.rule_idx > 0 {
		if !stream_check_string(h, sf, text, false, t.lo) {
			if stream_stopped(h) { return s, .Stop }
			if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
			return s, .Next
		}
	}
	if (h.first.kind == .None || h.has_val) && len(text) > 0 {
		cl, cerr := strings.clone(text, h.allocator)
		if cerr != nil { h.oom = true; return s, .Stop }
		(^string)(dest)^ = cl
		h.wrote_alloc = true
	}
	if .Has_After in sf.flags {
		if !stream_run_field_after(h, sf, dest, t.lo) { return s, .Stop }
	}
	if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
	return s, .Next
}

@(private, cold)
stream_number_fail :: #force_no_inline proc "contextless" (h: ^Stream_Loader, s: hook.Regs, t: tape.Token, sf: ^Stream_Field, v: i64) -> (hook.Regs, hook.Action) {
	context = h.ctx
	leaf := &h.plan.leaves[sf.rule_idx - 1]
	fails: rules.Failures
	if leaf.minimum.set && (v < leaf.minimum.int || (v == leaf.minimum.int && leaf.minimum.exclusive)) { fails += {.Below_Minimum} }
	if leaf.maximum.set && (v > leaf.maximum.int || (v == leaf.maximum.int && leaf.maximum.exclusive)) { fails += {.Above_Maximum} }
	h.fail_count += 1
	steps_buf: [32]tape.Step = ---
	steps, owned := stream_build_steps(h, h.sp, steps_buf[:], sf)
	defer if owned { delete(steps, h.scratch) }
	_ = emit_leaf_fails(leaf, fails, false, t.lo, steps, h.sink, &h.first, &h.oom, h.allocator, h.scratch, false)
	if stream_stopped(h) { return s, .Stop }
	if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
	return s, .Next
}

@(private, cold)
stream_number_text :: proc(h: ^Stream_Loader, t: tape.Token, buf: []u8) -> (s: string, owned, ok, non_finite: bool) {
	raw := string(h.base[t.lo:][:t.n])
	if t.spelling == 0 && rules.valid_decimal_text(raw) {
		return raw, false, true, false
	}
	if h.format.number != nil {
		num := h.format.number(h.base[:h.src_len], t)
		switch num.kind {
		case .Int:   return strconv.write_int(buf, i64(num.bits), 10), false, true, false
		case .Uint:  return strconv.write_uint(buf, num.bits, 10), false, true, false
		case .Float:
			f := transmute(f64)num.bits
			if math.is_nan(f) || math.is_inf(f, 0) { return "", false, false, true }
		case .Wide:
		}
	}
	if rules.valid_decimal_text(raw) { return raw, false, true, false }
	ns, nown, nok := rules.normalize_decimal_text(raw, buf, h.scratch)
	if !nok { return "", false, false, false }
	return ns, nown, true, false
}

@(private, cold)
stream_number_leaf_cold :: #force_no_inline proc "contextless" (h: ^Stream_Loader, s: hook.Regs, t: tape.Token, sf: ^Stream_Field, v: i64) -> (hook.Regs, hook.Action) {
	context = h.ctx
	nbuf: [64]u8 = ---
	ns, nown, nok, nf := stream_number_text(h, t, nbuf[:])
	defer if nown { delete(ns, h.scratch) }
	if nf {
		_ = stream_fail(h, .Non_Finite, t.lo, sf = sf)
		if stream_stopped(h) { return s, .Stop }
	} else if !nok || !stream_check_num_leaf(h, sf.rule_idx, ns, v, t.lo, sf) {
		if stream_stopped(h) { return s, .Stop }
	} else if .Has_After in sf.flags {
		if !stream_run_field_after(h, sf, uintptr(s.c) + uintptr(sf.offset), t.lo) { return s, .Stop }
	}
	if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
	return s, .Next
}

@(private, cold)
stream_f64_leaf_cold :: #force_no_inline proc "contextless" (h: ^Stream_Loader, s: hook.Regs, t: tape.Token, sf: ^Stream_Field, fv: f64) -> (hook.Regs, hook.Action) {
	context = h.ctx
	leaf := &h.plan.leaves[sf.rule_idx - 1]
	// Fast strict-inequality failure check before falling back to exact decimal compare at boundary equality.
	if leaf.fast && leaf.minimum.int >= -F64_EXACT_INT_MAX && leaf.minimum.int <= F64_EXACT_INT_MAX && leaf.maximum.int >= -F64_EXACT_INT_MAX && leaf.maximum.int <= F64_EXACT_INT_MAX {
		if !(leaf.minimum.set && fv == f64(leaf.minimum.int)) && !(leaf.maximum.set && fv == f64(leaf.maximum.int)) {
			fails: rules.Failures
			if leaf.minimum.set && fv < f64(leaf.minimum.int) { fails += {.Below_Minimum} }
			if leaf.maximum.set && fv > f64(leaf.maximum.int) { fails += {.Above_Maximum} }
			if fails != {} {
				h.fail_count += 1
				steps_buf: [32]tape.Step = ---
				steps, owned := stream_build_steps(h, h.sp, steps_buf[:], sf)
				defer if owned { delete(steps, h.scratch) }
				_ = emit_leaf_fails(leaf, fails, false, t.lo, steps, h.sink, &h.first, &h.oom, h.allocator, h.scratch, false)
				if stream_stopped(h) { return s, .Stop }
				if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
				return s, .Next
			}
		}
	}
	nbuf: [64]u8 = ---
	ns, nown, nok, nf := stream_number_text(h, t, nbuf[:])
	defer if nown { delete(ns, h.scratch) }
	if nf {
		_ = stream_fail(h, .Non_Finite, t.lo, sf = sf)
		if stream_stopped(h) { return s, .Stop }
	} else if !nok || !stream_check_num_leaf(h, sf.rule_idx, ns, nil, t.lo, sf) {
		if stream_stopped(h) { return s, .Stop }
	} else if .Has_After in sf.flags {
		if !stream_run_field_after(h, sf, uintptr(s.c) + uintptr(sf.offset), t.lo) { return s, .Stop }
	}
	if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
	return s, .Next
}

@(private, cold)
stream_number_cold :: #force_no_inline proc "contextless" (h: ^Stream_Loader, s: hook.Regs, t: tape.Token, sf: ^Stream_Field, dest: uintptr) -> (hook.Regs, hook.Action) {
	context = h.ctx
	tn := &h.plan.nodes[sf.node]
	nbuf: [64]u8 = ---
	ns, nown, nok, nf := stream_number_text(h, t, nbuf[:])
	defer if nown { delete(ns, h.scratch) }
	if nf {
		if !stream_fail(h, .Non_Finite, t.lo, sf = sf) { return s, .Stop }
		if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
		return s, .Next
	}
	if !nok {
		if !stream_fail(h, .Wrong_Kind, t.lo, "", {type = tn.type, text = type_name_short(tn.ti)}, sf = sf) { return s, .Stop }
		if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
		return s, .Next
	}
	ok := true
	if tn.kind >= .I8 && tn.kind <= .U64 {
		ok = stream_decode_int_text(h, tn, ns, rawptr(dest), sf.rule_idx, t.lo, sf)
	} else if tn.kind == .F32 || tn.kind == .F64 {
		f64_v, fok := strconv.parse_f64(ns)
		f32_v := f32(f64_v)
		bad := !fok || (math.is_nan(f32_v) || math.is_inf(f32_v, 0) if tn.kind == .F32 else math.is_nan(f64_v) || math.is_inf(f64_v, 0))
		if bad {
			ok = false
			_ = stream_fail(h, .Below_Minimum if strings.has_prefix(ns, "-") else .Above_Maximum, t.lo, sf = sf)
		} else {
			if tn.kind == .F32 { (^f32)(dest)^ = f32_v } else { (^f64)(dest)^ = f64_v }
			ok = stream_check_num_leaf(h, sf.rule_idx, ns, nil, t.lo, sf)
		}
	}
	if stream_stopped(h) { return s, .Stop }
	if ok && .Has_After in sf.flags {
		if !stream_run_field_after(h, sf, dest, t.lo) { return s, .Stop }
	}
	if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
	return s, .Next
}

@(private, cold)
stream_decode_int_text :: proc(h: ^Stream_Loader, tn: ^Type_Node, text: string, dest: rawptr, rule_idx: i32, at: u64, sf: ^Stream_Field) -> bool {
	small, k := parse_int_decimal(tn, text, dest)
	if k != .None {
		want := Want{type = tn.type, text = type_name_short(tn.ti)} if k == .Wrong_Kind else Want{}
		return stream_fail(h, k, at, "", want, sf = sf)
	}
	return stream_check_num_leaf(h, rule_idx, text, small, at, sf)
}

@(private, cold)
stream_decode_map_key :: proc(h: ^Stream_Loader, ktn: ^Type_Node, text: string, dest: rawptr, at: u64) -> bool {
	k := parse_map_key_text(h.plan, ktn, text, dest, h.allocator)
	if k == .None { return true }
	if k == .No_Memory { h.oom = true; return false }
	want := Want{type = ktn.type, text = type_name_short(ktn.ti)} if (k == .Wrong_Kind && ktn.kind >= .I8 && ktn.kind <= .U64) else Want{}
	return stream_fail(h, k, at, "", want, extra_step = tape.Step(tape.Name(text)))
}

@(private, cold)
stream_indirect :: #force_no_inline proc "contextless" (
	h: ^Stream_Loader, s: hook.Regs, t: tape.Token, orig_sf: ^Stream_Field, orig_dest: uintptr,
) -> (hook.Regs, hook.Action) #no_bounds_check {
	context = h.ctx
	cur_node := orig_sf.node
	cur_rule := orig_sf.rule_idx
	not_null := .Not_Null in orig_sf.flags
	dest := orig_dest
	ptr_depth := u32(0)
	opened := false
	defer if !opened { h.budget.depth -= ptr_depth }

	// Unwrap `.Maybe` and `.Ptr` wrappers.
	for {
		tn := &h.plan.nodes[cur_node]
		if tn.kind == .Maybe {
			if t.kind == .Null {
				if not_null {
					_ = stream_fail(h, .Wrong_Kind, t.lo, "", {type = tn.type, text = "non-null"}, sf = orig_sf)
					if stream_stopped(h) { return s, .Stop }
				}
				if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
				return s, .Next
			}
			if !tn.pure_maybe && tn.tag_size > 0 {
				one := u64(1)
				mem.copy(rawptr(dest + tn.tag_offset), &one, tn.tag_size)
			}
			cur_node = tn.child
			if cur_rule <= 0 { cur_rule = h.plan.nodes[cur_node].rule_idx }
			not_null = false
			continue
		}
		if tn.kind == .Ptr {
			if t.kind == .Null {
				if not_null {
					_ = stream_fail(h, .Wrong_Kind, t.lo, "", {type = tn.type, text = "non-null"}, sf = orig_sf)
					if stream_stopped(h) { return s, .Stop }
				}
				if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
				return s, .Next
			}
			if ptr_depth >= 31 { h.fallback = true; return s, .Stop }
			if h.budget.depth + 1 > h.budget.max_depth {
				h.budget.exceeded = {at = t.lo, kind = .Depth}
				return s, .Stop
			}
			h.budget.depth += 1
			ptr_depth += 1
			ctn := &h.plan.nodes[tn.child]
			raw, aerr := runtime.mem_alloc(max(ctn.size, 1), ctn.align, h.allocator)
			if aerr != nil { h.oom = true; return s, .Stop }
			(^rawptr)(dest)^ = raw_data(raw)
			h.wrote_alloc = true
			dest = uintptr(raw_data(raw))
			cur_node = tn.child
			if cur_rule <= 0 { cur_rule = ctn.rule_idx }
			not_null = false
			continue
		}
		break
	}

	tn := &h.plan.nodes[cur_node]
	eff_sf := orig_sf^
	eff_sf.node = cur_node
	eff_sf.kind = tn.kind
	eff_sf.rule_idx = cur_rule
	eff_sf.struct_idx = tn.struct_idx
	open_flags := (u8(SF_HAS_AFTER) if .Has_After in orig_sf.flags else u8(0)) | u8(ptr_depth << 3)

	skip_wrong :: proc(h: ^Stream_Loader, s: hook.Regs, t: tape.Token, sf: ^Stream_Field, want: Want) -> (hook.Regs, hook.Action) {
		_ = stream_fail(h, .Wrong_Kind, t.lo, "", want, sf = sf)
		if stream_stopped(h) { return s, .Stop }
		if t.kind == .Object || t.kind == .Array { return stream_skip_container(h, s, t) }
		if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
		return s, .Next
	}

	#partial switch tn.kind {
	case .Struct:
		if t.kind != .Object { return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = "object"}) }
		if h.budget.depth + 1 > h.budget.max_depth { h.budget.exceeded = {at = t.lo, kind = .Depth}; return s, .Stop }
		if h.sp == h.room && !stream_frames_grow(h) { h.oom = true; return s, .Stop }
		h.budget.depth += 1; opened = true
		si := &h.plan.structs[tn.struct_idx]
		f := &h.frames[h.sp]; h.sp += 1
		f.a, f.b, f.c = s.a, s.b, s.c
		f.kind, f.node_idx, f.si = .Struct, cur_node, si
		f.seen0, f.seen1, f.seen_wide = 0, 0, nil
		f.target, f.open_at, f.start_fails = rawptr(dest), t.lo, h.fail_count
		f.fflags, f.parent_fi = open_flags, orig_sf.field_idx
		return {STREAM_NO_LIMIT, u64(uintptr(raw_data(si.stream_fields))), u64(dest)}, .Next

	case .Slice, .Dynamic, .Array, .Fixed_List:
		if t.kind != .Array { return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = "array"}) }
		if h.budget.depth + 1 > h.budget.max_depth { h.budget.exceeded = {at = t.lo, kind = .Depth}; return s, .Stop }
		if h.sp == h.room && !stream_frames_grow(h) { h.oom = true; return s, .Stop }
		h.budget.depth += 1; opened = true
		ctn := &h.plan.nodes[tn.child]
		f := &h.frames[h.sp]; h.sp += 1
		f.a, f.b, f.c = s.a, s.b, s.c
		f.node_idx, f.rule_idx, f.target = cur_node, cur_rule, rawptr(dest)
		f.open_at, f.start_fails = t.lo, h.fail_count
		f.fflags, f.parent_fi = open_flags, orig_sf.field_idx
		f.count, f.stride, f.seen_wide = 0, u32(ctn.size), nil
		#partial switch tn.kind {
		case .Slice:      f.kind, f.data, f.cap = .Slice, nil, 0
		case .Dynamic:    f.kind, f.data, f.cap = .Dynamic, nil, 0
		case .Array:      f.kind, f.data, f.cap = .Array, rawptr(dest), tn.count
		case .Fixed_List: f.kind, f.data, f.cap = .Fixed_List, rawptr(dest), tn.count
		}
		return {0, u64(uintptr(&h.plan.elem_fields[tn.elem_field_idx]) + size_of(Stream_Field)), 0}, .Next

	case .Map:
		if t.kind != .Object { return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = "object"}) }
		if h.policy != .Refuse { h.fallback = true; return s, .Stop }
		if h.budget.depth + 1 > h.budget.max_depth { h.budget.exceeded = {at = t.lo, kind = .Depth}; return s, .Stop }
		if h.sp == h.room && !stream_frames_grow(h) { h.oom = true; return s, .Stop }
		ktn := &h.plan.nodes[tn.key_node]
		vtn := &h.plan.nodes[tn.child]
		kbuf, kerr := runtime.mem_alloc(max(ktn.size, 1), ktn.align, h.scratch)
		vbuf, verr := runtime.mem_alloc(max(vtn.size, 1), vtn.align, h.scratch)
		if kerr != nil || verr != nil {
			if raw_data(kbuf) != nil { runtime.mem_free(raw_data(kbuf), h.scratch) }
			if raw_data(vbuf) != nil { runtime.mem_free(raw_data(vbuf), h.scratch) }
			h.oom = true; return s, .Stop
		}
		h.budget.depth += 1; opened = true
		(^runtime.Raw_Map)(dest).allocator = h.allocator
		f := &h.frames[h.sp]; h.sp += 1
		f.a, f.b, f.c = s.a, s.b, s.c
		f.kind, f.node_idx, f.rule_idx, f.target = .Map, cur_node, cur_rule, rawptr(dest)
		f.data, f.val_buf, f.count = raw_data(kbuf), raw_data(vbuf), 0
		f.open_at, f.start_fails = t.lo, h.fail_count
		f.fflags, f.parent_fi, f.seen_wide = open_flags, orig_sf.field_idx, nil
		return {0, u64(uintptr(&h.plan.elem_fields[tn.elem_field_idx]) + size_of(Stream_Field)), 0}, .Next

	case .String, .Email:
		if t.kind != .String { return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = "string"}) }
		return stream_string_decoded(h, s, t, &eff_sf, dest)

	case .Cstring:
		if t.kind == .Null {
			if not_null { _ = stream_fail(h, .Wrong_Kind, t.lo, "", {type = tn.type, text = "string"}, sf = orig_sf) }
		} else if t.kind != .String {
			return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = "string"})
		} else {
			buf: [256]u8 = ---
			text, owned, ok := stream_decode_token_text(h, t, buf[:])
			if !ok { return s, .Stop }
			defer if owned { delete(text, h.scratch) }
			rule_ok := cur_rule <= 0 || stream_check_string(h, &eff_sf, text, t.spelling & tape.SPELLING_ASCII != 0 && !owned, t.lo)
			if rule_ok && (h.first.kind == .None || h.has_val) {
				cs, cerr := strings.clone_to_cstring(text, h.allocator)
				if cerr != nil { h.oom = true; return s, .Stop }
				(^cstring)(dest)^ = cs
				h.wrote_alloc = true
			}
		}

	case .Bool, .Bool_Wide:
		if t.kind != .True && t.kind != .False { return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = "bool"}) }
		bv := t.kind == .True
		if tn.kind == .Bool { (^bool)(dest)^ = bv } else {
			switch tn.size {
			case 2: (^b16)(dest)^ = b16(bv)
			case 4: (^b32)(dest)^ = b32(bv)
			case 8: (^b64)(dest)^ = b64(bv)
			}
		}

	case .I8 ..= .F64:
		if t.kind != .Number { return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = type_name_short(tn.ti)}) }
		return stream_number_cold(h, s, t, &eff_sf, dest)

	case .Number_Text:
		if t.kind == .Null {
			if not_null { _ = stream_fail(h, .Wrong_Kind, t.lo, "", {type = tn.type, text = "number"}, sf = orig_sf) }
		} else if t.kind != .Number {
			return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = "number"})
		} else {
			nbuf: [64]u8 = ---
			ns, nown, nok, nf := stream_number_text(h, t, nbuf[:])
			defer if nown { delete(ns, h.scratch) }
			if nf {
				_ = stream_fail(h, .Non_Finite, t.lo, sf = orig_sf)
			} else if !nok {
				_ = stream_fail(h, .Wrong_Kind, t.lo, "", {type = tn.type, text = "number"}, sf = orig_sf)
			} else {
				_ = stream_check_num_leaf(h, cur_rule, ns, nil, t.lo, orig_sf)
				if h.first.kind == .None || h.has_val {
					cl, cerr := strings.clone(ns, h.allocator)
					if cerr != nil { h.oom = true; return s, .Stop }
					(^Number_Text)(dest)^ = {text = cl, value = parse_f64_approx(cl)}
					h.wrote_alloc = true
				}
			}
		}

	case .Decimal:
		if t.kind != .Number && t.kind != .String { return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = "decimal"}) }
		buf: [256]u8 = ---
		text: string
		owned, valid := false, true
		if t.kind == .String {
			ok: bool
			text, owned, ok = stream_decode_token_text(h, t, buf[:])
			if !ok { return s, .Stop }
			if !rules.valid_decimal_text(text) { _ = stream_fail(h, .No_Match, t.lo, sf = orig_sf); valid = false }
			if valid && cur_rule > 0 && !stream_check_string(h, &eff_sf, text, false, t.lo) { valid = false }
		} else {
			nok, nf: bool
			text, owned, nok, nf = stream_number_text(h, t, buf[:])
			if nf { _ = stream_fail(h, .Non_Finite, t.lo, sf = orig_sf); valid = false } else if !nok {
				_ = stream_fail(h, .Wrong_Kind, t.lo, "", {type = tn.type, text = "decimal"}, sf = orig_sf); valid = false
			}
		}
		defer if owned { delete(text, h.scratch) }
		if valid { _ = stream_check_num_leaf(h, cur_rule, text, nil, t.lo, orig_sf) }
		if valid && (h.first.kind == .None || h.has_val) {
			cl, cerr := strings.clone(text, h.allocator)
			if cerr != nil { h.oom = true; return s, .Stop }
			(^Decimal)(dest)^ = Decimal{text = cl, value = parse_f64_approx(cl)}
			h.wrote_alloc = true
		}

	case .Time:
		if t.kind != .String { return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = "date-time"}) }
		buf: [128]u8 = ---
		text, owned, ok := stream_decode_token_text(h, t, buf[:])
		if !ok { return s, .Stop }
		defer if owned { delete(text, h.scratch) }
		tm, tk := decode_time(text, false)
		if tk != .None {
			_ = stream_fail(h, tk, t.lo, sf = orig_sf)
		} else {
			(^time.Time)(dest)^ = tm
			if cur_rule > 0 {
				fbuf: [40]u8 = ---
				if canon, cok := format_rfc3339_utc(tm, &fbuf); cok {
					_ = stream_check_string(h, &eff_sf, canon, true, t.lo)
				}
			}
		}

	case .Uuid, .Bytes, .Base64, .Hex:
		want := "uuid" if tn.kind == .Uuid else ("base64" if tn.kind == .Base64 else ("hex" if tn.kind == .Hex else "string"))
		if t.kind != .String { return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = want}) }
		buf: [256]u8 = ---
		text, owned, ok := stream_decode_token_text(h, t, buf[:])
		if !ok { return s, .Stop }
		defer if owned { delete(text, h.scratch) }
		rule_ok := cur_rule <= 0 || stream_check_string(h, &eff_sf, text, false, t.lo)
		ck := Error_Kind.None
		if tn.kind == .Uuid {
			id: uuid.Identifier; id, ck = decode_uuid(text); if ck == .None { (^uuid.Identifier)(dest)^ = id }
		} else if tn.kind == .Hex {
			hx: Hex; hx, ck = decode_hex(text, h.allocator)
			if ck == .None { (^Hex)(dest)^ = hx; if len(hx) > 0 { h.wrote_alloc = true } }
		} else {
			b64: Base64; b64, ck = decode_base64(text, h.allocator)
			if ck == .None {
				if tn.kind == .Bytes { (^[]u8)(dest)^ = ([]u8)(b64) } else { (^Base64)(dest)^ = b64 }
				if len(b64) > 0 { h.wrote_alloc = true }
			}
		}
		if ck == .No_Memory { h.oom = true; return s, .Stop }
		if ck != .None && rule_ok { _ = stream_fail(h, ck, t.lo, sf = orig_sf) }

	case .Enum:
		ei := &h.plan.enums[tn.enum_idx]
		if ei.by_name {
			if t.kind != .String { return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = "string"}) }
			buf: [128]u8 = ---
			text, owned, ok := stream_decode_token_text(h, t, buf[:])
			if !ok { return s, .Stop }
			defer if owned { delete(text, h.scratch) }
			found := false
			for name, i in ei.names { if name == text { store_enum_value(rawptr(dest), tn.size, ei.values[i]); found = true; break } }
			if !found { _ = stream_fail(h, .Not_A_Member, t.lo, sf = orig_sf) }
		} else {
			if t.kind != .Number { return skip_wrong(h, s, t, orig_sf, {type = tn.type, text = "integer"}) }
			nbuf: [64]u8 = ---
			ns, nown, nok, nf := stream_number_text(h, t, nbuf[:])
			defer if nown { delete(ns, h.scratch) }
			if nf {
				_ = stream_fail(h, .Non_Finite, t.lo, sf = orig_sf)
			} else if !nok {
				_ = stream_fail(h, .Wrong_Kind, t.lo, "", {type = tn.type, text = "integer"}, sf = orig_sf)
			} else {
				d := rules.decimal_of(ns)
				if !rules.integral(d) {
					_ = stream_fail(h, .Wrong_Kind, t.lo, "", {type = tn.type, text = "integer"}, sf = orig_sf)
				} else {
					found := false
					if ei.is_unsigned {
						if !d.neg && rules.decimal_compare(d, rules.decimal_of("18446744073709551615")) <= 0 {
							uv := decimal_u64(d)
							for ev in ei.values { if u64(ev) == uv { store_enum_value(rawptr(dest), tn.size, i64(uv)); found = true; break } }
						}
					} else if iv, fits := rules.decimal_i64(d); fits {
						for ev in ei.values { if ev == iv { store_enum_value(rawptr(dest), tn.size, iv); found = true; break } }
					}
					if !found { _ = stream_fail(h, .Not_A_Member, t.lo, sf = orig_sf) }
				}
			}
		}
	}

	if stream_stopped(h) { return s, .Stop }
	if .Has_After in orig_sf.flags {
		if !stream_run_field_after(h, orig_sf, orig_dest, t.lo) { return s, .Stop }
	}
	if h.frames[h.sp - 1].kind == .Map { return stream_map_finish_entry(h, s) }
	return s, .Next
}
