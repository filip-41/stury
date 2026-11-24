package cbor

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Walks a text in pieces. A window's walk reads the items the window holds whole and stops before the first it does
// not: an item whose head, string payload, float, or tag 0 date text runs past the window's end. The next window's walk
// goes on at that item with the levels the last one left, so every token and fault is the whole walk's, and no byte of
// an item is read in two windows but the head of the item a window cut. A container the hook answered `Skip`, `Keep`,
// `Keep_Stubs` or `Rest` for, or the value of a key it skipped, goes on in the next window inside its own walk, with
// the walk around it waiting past its head.
//
// A head whose count the window's bytes cannot hold is judged once the text holds them or ends, as the whole walk
// judges it against the bytes left. Until then the walk goes on, and a fault or a stop past such a head waits for the
// verdict on the head, which comes first in the text.

// Where a walk of a text in pieces goes on: at the item at `i`, in the levels `d` deep whose innermost frame is `top`,
// and with `passing` the value of a key the hook skipped.
@(private)
Cut :: struct {
	i, d, top: u64,
	passing:   bool,
}

// What a CBOR walk keeps from one piece to the next.
@(private)
Piece :: struct {
	using state:  hook.Piece_State,
	cut:          Cut,
	frames:       [dynamic]u8, // the bytes of the `cut.d` frames of `Level(S)`, copied by `piece_levels`
	// Where the chunks of the indefinite string at `chunks.at` were read to, so that the next window goes on there: the
	// head of the chunk the last window cut, and whether the chunks before it took a tolerance.
	chunks:       struct {
		at, read: u64,
		lax:      bool,
	},
	// With `nest`, the walk around the container the hook answered for, or the value of the key it skipped, which goes
	// on past it once the inner walk at `cut` ends it. `indefinite` says that container ends at a break.
	outer:        Cut,
	outer_frames: [dynamic]u8,
	indefinite:   bool,
	// The heads whose count needs bytes past the windows read so far: each head's offset and the offset the text must
	// reach for it.
	claims:       [dynamic][2]u64,
	held:         u64, // with `holding`, the walk's end, a `hook.Walk_Result`, which waits for `claims` to settle
	holding:      bool,
	ended:        bool, // the root item ended at `cut.i`, and the next window says whether bytes follow it
	more:         bool, // bytes may follow the window being walked
	refused:      bool, // memory for the open path was refused
}

@(private)
piece_free :: proc(p: ^tape.Pieces) {
	s := (^Piece)(p.state)
	delete(s.frames)
	delete(s.outer_frames)
	delete(s.claims)
	hook.piece_release(p)
}

// The truncation at the item at `at`, in the levels `d` deep whose innermost frame is `top`: in a window that more
// bytes follow, the walk ends before the item, which the next window's walk reads.
@(private)
short :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), at, d, top: u64, passing: bool) -> hook.Walk_Result {
	when .Windows in C {
		if w.piece[0] != nil && w.piece[0].more {
			return piece_cut(w, at, d, top, passing)
		}
	}
	return fault(u64(len(w.src)), .Truncated)
}

// `short` for fault `f` of a reader of the item at `at`, which truncates at the window's end.
@(private)
short_fault :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), f: hook.Walk_Result, at, d, top: u64, passing: bool) -> hook.Walk_Result {
	when .Windows in C {
		if u8(f) == u8(tape.Fault_Kind.Truncated) && u64(f) >> 16 == u64(len(w.src)) {
			return short(w, at, d, top, passing)
		}
	}
	return f
}

// The verdict on the head at `i` of `hl` bytes whose count `arg`, of pairs with `pair`, the bytes left cannot hold: a
// fault, or in a window that more bytes follow, 0 with the head's claim kept for a later window, or in a part of a text
// whose bytes hold the count, 0.
@(private, cold)
count_short :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), i, hl, arg, pair: u64) -> hook.Walk_Result {
	when .Windows in C {
		if s := w.piece[0]; s != nil && s.more {
			need := max(u64) if arg > max(u64) >> 2 else i + hl + arg << pair
			// A contextless proc needs a context for `append`, whose allocator is the array's own.
			context = runtime.default_context()
			if _, e := append(&s.claims, [2]u64{i, need}); e != nil {
				return hook.walk_result(i, hook.WALK_NO_MEMORY)
			}
			return 0
		}
	}
	if w.whole > i + hl && arg <= (w.whole - i - hl) >> pair {
		return 0
	}
	return fault(i, .Truncated, .Count_Too_Large)
}

// Whether the date text at `q`, the content of a tag 0, runs past a window that more bytes follow, so that the tag is
// read in the next window with its content whole.
@(private)
date_short :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), q: u64) -> bool {
	when .Windows in C {
		if w.piece[0] != nil && w.piece[0].more {
			src := w.src
			b := src[q]
			if b >> 5 != 3 || b & 31 > 27 && b & 31 != 31 {
				return false
			}
			if b & 31 == 31 {
				return date_chunks_open(src, q)
			}
			arg, hl, ok := read_head(src, q, b & 31)
			return !ok || arg > u64(len(src)) - q - hl
		}
	}
	return false
}

// Ends the walk of a window before the item at `i`, in the levels `d` deep whose innermost frame is `top`, which the
// next window's walk reads.
@(private, cold)
piece_cut :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), i, d, top: u64, passing: bool) -> hook.Walk_Result {
	when .Windows in C {
		s := w.piece[0]
		s.cut = {i, d, top, passing}
		if !piece_levels(&s.frames, w.stack, d) {
			return hook.walk_result(i, hook.WALK_NO_MEMORY)
		}
	}
	return hook.walk_result(i, hook.WALK_MORE)
}

// Copies the `d` levels of `stack` into `frames`.
@(private)
piece_levels :: proc "contextless" (frames: ^[dynamic]u8, stack: [^]Level($S), d: u64) -> bool {
	context = runtime.default_context()
	size := int(d) * size_of(Level(S))
	if resize(frames, size) != nil {
		return false
	}
	intrinsics.mem_copy_non_overlapping(raw_data(frames^), stack, size)
	return true
}

// How a walk in pieces goes on inside a container the hook answered `a` for.
@(private)
nest_of :: #force_inline proc "contextless" (a: hook.Action) -> hook.Nest {
	#partial switch a {
	case .Skip:
		return .Skip
	case .Keep:
		return .Keep
	case .Keep_Stubs:
		return .Keep_Stubs
	case .Rest:
		return .Rest
	}
	return .None
}

// The result `r` of the inner walk of the container at `start` that the hook answered for with `nest`, or of the value
// a key skip passes, in the levels `d` deep whose innermost frame is `top`. When the window ended it, the walk around
// it is kept to go on past it, but under `.Rest`, whose walk reads the rest of the text in the same levels.
@(private)
nested :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), r: hook.Walk_Result, nest: hook.Nest, start, d, top: u64) -> hook.Walk_Result {
	when .Windows in C {
		if u8(r) == hook.WALK_MORE && w.piece[0] != nil {
			return piece_nest(w, r, nest, start, d, top)
		}
	}
	return r
}

@(private, cold)
piece_nest :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), r: hook.Walk_Result, nest: hook.Nest, start, d, top: u64) -> hook.Walk_Result {
	when .Windows in C {
		s := w.piece[0]
		s.nest = nest
		if nest == .Rest {
			return r
		}
		s.outer, s.indefinite = {start, d, top, false}, nest != .Pass && w.src[start] & 31 == 31
		if !piece_levels(&s.outer_frames, w.stack, d) {
			return hook.walk_result(start, hook.WALK_NO_MEMORY)
		}
	}
	return r
}

// Records token `t` in the open containers of a walk in pieces, for `Pieces.open`. The scalar a container holds, the
// most tokens, takes no call. False when memory for one more is refused.
@(private)
piece_track :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), s: ^Piece, t: tape.Token) -> bool #no_bounds_check {
	if t.role > .Key {
		return true
	}
	if t.kind > .Plain || t.kind == .End {
		return piece_track_container(w.ctx, s, t)
	}
	n := len(s.opened)
	if t.role == .Key {
		s.opened[n - 1].key, s.opened[n - 1].name = t, -1
		return true
	}
	if n > 0 {
		s.opened[n - 1].count += 1
		s.opened[n - 1].key.kind = .End
	}
	return true
}

@(private)
piece_track_container :: #force_no_inline proc "contextless" (ctx: ^runtime.Context, s: ^Piece, t: tape.Token) -> bool #no_bounds_check {
	n := len(s.opened)
	if t.kind == .End {
		pop_safe(&s.opened)
		if n > 1 {
			s.opened[n - 2].key.kind = .End
		}
		return true
	}
	if n > 0 && t.role == .Value {
		s.opened[n - 1].count += 1
	}
	level := hook.Open_Level{key = {kind = .End}, object = t.kind == .Object, name = -1}
	if n < cap(s.opened) {
		raw := (^runtime.Raw_Dynamic_Array)(&s.opened)
		([^]hook.Open_Level)(raw.data)[n] = level
		raw.len = n + 1
		return true
	}
	return piece_open_grow(ctx, s, level)
}

@(private, cold)
piece_open_grow :: #force_no_inline proc "contextless" (ctx: ^runtime.Context, s: ^Piece, level: hook.Open_Level) -> bool {
	context = ctx^
	if _, e := append(&s.opened, level); e != nil {
		s.refused = true
		return false
	}
	return true
}

// Walks the window `src` of the text in pieces `opts.pieces` for hook `h` from its registers `regs`, and updates
// `opts.pieces` (`more`, `at`, `keep`, `open`) for the next window. A window must start at or before `keep` and end at
// or after `at`, and the first window must start the text.
@(private)
piece_read :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	context = ctx^
	p := opts.pieces
	s, text, to, berr := hook.piece_begin(p, Piece, piece_free, src)
	if berr != nil {
		return 0, berr, false
	}
	s.more = !p.last
	if !s.started {
		s.started, s.steps = true, steps_of(opts)
		lists := hook.piece_lists(p)
		s.frames.allocator, s.outer_frames.allocator, s.claims.allocator = lists, lists, lists
		s.opened.allocator, s.names.allocator, s.steps_buf.allocator = lists, lists, lists
	}
	r: hook.Walk_Result
	switch {
	case s.holding:
		r = hook.Walk_Result(s.held)
	case s.ended:
		r = hook.walk_result(s.cut.i, 0)
	case to == 0 && !s.more:
		p.more, p.open = false, nil
		return 0, tape.Fault{rules = &RULES, kind = .Truncated, detail = u8(Detail.No_Item)}, false
	case:
		r = piece_walk(text, S, opts, h, regs, allocator, ctx, on, s)
	}
	if s.refused {
		r = hook.walk_result(to, hook.WALK_NO_MEMORY)
	}
	for k := 0; k < len(s.claims); {
		if s.claims[k][1] <= to {
			ordered_remove(&s.claims, k)
		} else {
			k += 1
		}
	}
	if len(s.claims) > 0 {
		if !s.more {
			r = fault(s.claims[0][0], .Truncated, .Count_Too_Large)
		} else if u8(r) != hook.WALK_MORE {
			s.holding, s.held, r = true, u64(r), hook.walk_result(to, hook.WALK_MORE)
		}
	} else if s.holding {
		s.holding = false
	}
	if u8(r) == 0 && !s.holding {
		if end := u64(r) >> 16; end < to {
			r = fault(end, .Bad_Char, .Trailing)
		} else if s.more {
			s.ended, s.cut.i, r = true, end, hook.walk_result(to, hook.WALK_MORE)
		}
	}
	tolerated = s.tolerated
	if u8(r) == hook.WALK_MORE {
		s.regs = regs^
		p.more, p.at, p.keep = true, to, piece_keep(s, S, to)
		if e := hook.piece_path(p, text, &FORMATS[S]); e != nil {
			return 0, e, tolerated
		}
		return 0, nil, tolerated
	}
	p.more, p.open = false, nil
	root_close, err, _ = hook.walk_error(r, &RULES)
	return root_close, err, tolerated
}

// The walk of a window from where the last one stopped, which leaves in `s` where the next goes on.
@(private)
piece_walk :: proc "contextless" (src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), s: ^Piece) -> (r: hook.Walk_Result) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	stack: [WALK_LEVELS]Level(S) = ---
	w: Walk(S, H, true, C | WINDOWS)
	walk_init(&w, src, h, raw_data(stack[:]), min(build.read_depth(opts), MAX_LEVELS), WALK_LEVELS, opts)
	w.allocator, w.ctx, w.steps, w.piece = allocator, ctx, {s.steps}, {s}
	inner := s.nest != .None && s.nest != .Rest
	base := s.outer.d if inner else 0
	held := base + s.cut.d
	if held > w.room && !hook.levels_room(&w, held) {
		return hook.walk_result(s.cut.i, hook.WALK_NO_MEMORY)
	}
	if inner {
		intrinsics.mem_copy_non_overlapping(w.stack, raw_data(s.outer_frames), len(s.outer_frames))
	}
	intrinsics.mem_copy_non_overlapping(w.stack[base:], raw_data(s.frames), len(s.frames))
	// `w.depth` is the levels held, so the next container opened past them calls `deepen`, which grows the hook's levels
	// with the walk's.
	w.depth = held
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	when .Walk in C {
		h.walk = &w
	}
	cut, outer := s.cut, s.outer
	switch s.nest {
	case .None:
		r = run(&w, cut.i, cut.d, cut.top, regs, on, cut.passing)
	case .Rest:
		none: hook.Regs
		r = run((^Walk(S, hook.No_Hooks, true, hook.NO_HOOKS_CAPS | WINDOWS))(&w), cut.i, cut.d, cut.top, &none, hook.no_hook)
	case .Skip, .Pass:
		r = judge_item(&w, cut.i, outer.d, cut.d, cut.top, regs^)
	case .Keep, .Keep_Stubs:
		when .Keeps in C {
			if s.nest == .Keep {
				r = keep_over(&w, cut.i, outer.d, regs, false, cut.d, cut.top, false)
			} else {
				r = keep_over(&w, cut.i, outer.d, regs, true, cut.d, cut.top, false)
			}
		}
	}
	if inner && u8(r) == 0 {
		r = piece_past(&w, regs, u64(r) >> 16, on)
	}
	when .Walk in C {
		h.walk = nil
	}
	if u8(r) == hook.WALK_STOPPED && w.steps[0] == 0 {
		r = hook.walk_result(u64(r) >> 16, hook.WALK_STEPS)
	}
	s.steps = w.steps[0]
	s.tolerated ||= w.tolerated
	if w.owned {
		hook.levels_free(&w)
	}
	return
}

// Goes on past the container or the skipped value that the inner walk of a window ended at `end`: gives the container's
// `End`, counts down the frames it completes, and walks on.
@(private)
piece_past :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), regs: ^hook.Regs, end: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	s := w.piece[0]
	nest := s.nest
	s.nest = .None
	d, top := s.outer.d, s.outer.top
	if nest != .Pass {
		if give(w, regs, end_token(end, s.indefinite), on) == .Stop {
			return hook.walk_result(end, hook.WALK_STOPPED)
		}
	}
	if r := count_down(w, regs, end, &d, &top, on); r != 0 {
		return r
	}
	return run(w, end, d, top, regs, on)
}

// The lowest offset the next window's walk reads: the item it goes on at, and in a spec that orders keys, the last key
// of each open map, which the next key is compared with.
@(private)
piece_keep :: proc "contextless" (s: ^Piece, $S: Spec, to: u64) -> u64 {
	if s.holding || s.ended {
		return to
	}
	keep := s.cut.i
	when S >= .Deterministic {
		for frames in ([2][]u8{s.frames[:], s.outer_frames[:] if s.nest != .None && s.nest != .Rest else nil}) {
			levels := ([^]Level(S))(raw_data(frames))[:len(frames) / size_of(Level(S))]
			for lv in levels {
				if lv.prev[0][1] > 0 {
					keep = min(keep, lv.prev[0][0])
				}
			}
		}
	}
	return keep
}

