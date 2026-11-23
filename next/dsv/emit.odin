package dsv

import "base:intrinsics"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The tokens a hooked pass gives besides a record's cells: the text's and each record's opening and `End`, and the
// comment lines. Every token reaches the hook through `emit`.

// The spelling of a comment line's token, which holds the length of its markers as JSONC's does: 1 byte opens it and
// none closes it. It is not a decode flag.
@(private)
COMMENT_SPELLING :: u16(1)

// Gives the hook the token of `n` bytes from `lo`, through its `Keeps` inside a record or text it keeps, and otherwise
// after growing the hook's room when it has no place for the node. A walk with `LAX` counts a step of `Budget.steps`
// per container and stops, with no token, at the first container past it. `builder_hook_rows` stores no key, so a key
// needs no room for it, and every other hook gets room for its keys.
@(private)
emit :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), hs: ^hook.Regs, lo: u64, n: u32, kind: tape.Kind, role: tape.Role, spelling: u16, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Action {
	t := tape.Token{lo, n, kind, role, spelling}
	when LAX {
		if kind == .Array || kind == .Object {
			w.steps[0] -= 1
			if w.steps[0] == 0 {
				return .Stop
			}
		}
	}
	when .Keeps in C {
		if w.keep != .None {
			return give_kept(w, hs, t)
		}
	}
	when .Rooms in C {
		if kind != .End && role <= .Key && !(role == .Key && rawptr(on) == rawptr(build.builder_hook_rows)) && uintptr(hs.a) == w.rooms {
			// The growth takes a copy of the registers, so their address reaches no call.
			grown := hs^
			ok := hook.rooms_grow(w.h, &grown, lo)
			hs^ = grown
			if !ok {
				return .Stop
			}
			w.rooms = hook.rooms_end(w.h)
		}
	}
	a: hook.Action
	hs^, a = on(w.h, hs^, t)
	return a
}

// Gives the inner hook of the hook's `Keeps` token `t`, after growing the inner hook's room when it has `.Rooms`.
@(private)
give_kept :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), hs: ^hook.Regs, t: tape.Token) -> hook.Action {
	when .Keeps in C {
		K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
		Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
		IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
		when .Rooms in IC {
			inner := (^Inner)(hook.keeps_inner(w.h))
			if t.kind != .End && t.role <= .Key && uintptr(hs.a) == hook.rooms_end(inner) {
				grown := hs^
				ok := hook.rooms_grow(inner, &grown, t.lo)
				hs^ = grown
				if !ok {
					return .Stop
				}
				when .Rooms in C {
					// The inner hook's room may be the hook's own.
					w.rooms = hook.rooms_end(w.h)
				}
			}
		}
		a: hook.Action
		if w.keep == .Stubs {
			hs^, a = hook.keeps_give(w.h, hs^, t, true)
		} else {
			hs^, a = hook.keeps_give(w.h, hs^, t, false)
		}
		return a
	} else {
		return .Next
	}
}

// Gives the comments before the header, then the text's opening `Array` at `lo`, and acts on the hook's answer. `done`
// is true, with the walk's result in `r`, when the hook stopped the walk or passed over the text or the rest of it,
// which is then judged with no tokens.
@(private)
open_text :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, opts: Pass_Options, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	if w.opened {
		return 0, false
	}
	if opts.comment != 0 && !opts.no_header {
		if r, done = give_head_comments(w, src, opts.comment, hs, on); done {
			return
		}
	}
	if !level_room(w, hs, lo) {
		return hook.walk_result(lo, hook.WALK_NO_MEMORY), true
	}
	a := emit(w, hs, lo, 0, .Array, .Value, 0, on)
	switch a {
	case .Next, .Grow:
	case .Skip, .Rest:
		if piece_rests(w, a == .Skip) {
			return 0, false
		}
		r = judge_from(w, src, lo, opts, 0)
		if u8(r) == 0 && a == .Skip && emit(w, hs, u64(len(src)), 0, .End, .Value, 0, on) == .Stop {
			r = stopped(u64(len(src)), 0)
		}
		return r, true
	case .Keep, .Keep_Stubs:
		w.keep, w.keep_root = Kept.Stubs if a == .Keep_Stubs else .Whole, true
		if give_kept(w, hs, {lo, 0, .Array, .Value, 0}) == .Stop {
			return stopped(lo, 0), true
		}
	case .Stop:
		return stopped(lo, 0), true
	}
	return 0, false
}

// Grows the levels of a hook with `.Levels` to hold the level of a container opened at `at`. False when the growth is
// refused.
@(private)
level_room :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), hs: ^hook.Regs, at: u64) -> bool {
	when .Levels in C {
		if hook.levels_held(w.h) <= int(hs.c) {
			grown := hs^
			ok := hook.levels_grow(w.h, int(hs.c) + 1, &grown, at)
			hs^ = grown
			if !ok {
				return false
			}
			when .Rooms in C {
				// Growing the hook's levels may have grown its room.
				w.rooms = hook.rooms_end(w.h)
			}
		}
	}
	return true
}

// Gives the text's `End` at `n`, after the comment lines past its last record, which are the text's foot. For a text
// the hook keeps, the `End` goes through its `Keeps` first.
@(private)
close_text :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, comment: u8, n: int, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	if w.unclosed {
		return 0, false
	}
	if rested, skip_end := piece_rested(w); rested {
		if skip_end && emit(w, hs, u64(n), 0, .End, .Value, 0, on) == .Stop {
			return stopped(u64(n), 0), true
		}
		return 0, false
	}
	if w.held != 0 {
		if r, done = give_comments(w, src, comment, n, .Comment_Foot, hs, on); done {
			return
		}
	}
	if w.keep != .None {
		if give_kept(w, hs, {u64(n), 0, .End, .Value, 0}) == .Stop {
			return stopped(u64(n), 0), true
		}
		w.keep, w.keep_root = .None, false
	}
	if emit(w, hs, u64(n), 0, .End, .Value, 0, on) == .Stop {
		return stopped(u64(n), 0), true
	}
	return 0, false
}

// Gives each comment line from the first one held up to `upto` as a token of `role`, and holds none after. A record
// that does not open with the comment byte gives no token, and its lines, a quoted cell's among them, are not read as
// comments. A comment's span leaves out the CR of a CR LF, which belongs to the line end.
@(private, cold)
give_comments :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, comment: u8, upto: int, role: tape.Role, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) #no_bounds_check {
	lo := w.held - 1
	w.held = 0
	for lo < upto {
		end := lo
		if src[lo] == comment {
			for end < upto && src[end] != '\n' {
				end += 1
			}
			hi := end
			if end < upto && hi > lo && src[hi - 1] == '\r' {
				hi -= 1
			}
			if emit(w, hs, u64(lo), u32(hi - lo), .Plain, role, COMMENT_SPELLING, on) == .Stop {
				return stopped(u64(lo), u32(hi - lo)), true
			}
		} else {
			end = min(scan_record(src, lo, 0, S, w.delim).line_end, upto)
		}
		lo = end + 1
	}
	return 0, false
}

// Gives the comment lines before the header as comments of the text, before the text's opening token, and marks them
// given so the pass holds none of them. A text with no record after its header holds them as its foot.
@(private, cold)
give_head_comments :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, comment: u8, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	start := int(text_start(src, 0))
	header := record_start(src, start, comment)
	if header == len(src) || record_start(src, scan_record(src, header, 0, S, w.delim).line_end + 1, comment) >= len(src) {
		return 0, false
	}
	w.held, w.given = start + 1, header
	return give_comments(w, src, comment, header, .Comment, hs, on)
}

// Opens a record at `rec_lo` with an `Array` (under `no_header`) or an `Object` token, and acts on the hook's answer.
// `done` is true, with the walk's result in `r`, when the hook stopped the walk or passed over the rest of the text,
// which is then judged with no tokens against `width`, the records' width so far. A record the hook passes over is
// `muted`, and one it keeps is given to the inner hook of its `Keeps`.
@(private)
open_record :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, opts: Pass_Options, hs: ^hook.Regs, rec_lo, width: int, muted: ^bool, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	piece_count_record(w)
	if rested, _ := piece_rested(w); rested {
		muted^, w.held = true, 0
		return 0, false
	}
	if opts.limit < RECORD_DEPTH {
		return hook.walk_result(u64(rec_lo), hook.WALK_TOO_DEEP), true
	}
	when .Levels in C {
		// The first record opens the walk's deepest level.
		if !w.leveled {
			if !level_room(w, hs, u64(rec_lo)) {
				return hook.walk_result(u64(rec_lo), hook.WALK_NO_MEMORY), true
			}
			w.leveled = true
		}
	}
	if w.held != 0 {
		given := hs^
		rr, stop := give_comments(w, src, opts.comment, rec_lo, .Comment, &given, on)
		hs^ = given
		if stop {
			return rr, true
		}
	}
	kind := tape.Kind.Array if opts.no_header else .Object
	a := emit(w, hs, u64(rec_lo), 0, kind, .Value, 0, on)
	switch a {
	case .Next, .Grow:
	case .Skip:
		muted^ = true
	case .Rest:
		if piece_rests(w, false) {
			muted^ = true
			return 0, false
		}
		return judge_from(w, src, u64(rec_lo), opts, width), true
	case .Keep, .Keep_Stubs:
		w.keep = Kept.Stubs if a == .Keep_Stubs else .Whole
		if give_kept(w, hs, {u64(rec_lo), 0, kind, .Value, 0}) == .Stop {
			return stopped(u64(rec_lo), 0), true
		}
	case .Stop:
		return stopped(u64(rec_lo), 0), true
	}
	return 0, false
}

// Gives the `End` of a record over its line end, `n` bytes from `lo`, through the hook's `Keeps` first for a record it
// keeps. False when the hook stops the walk.
@(private)
close_record :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), hs: ^hook.Regs, lo: int, n: u32, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> bool {
	if rested, _ := piece_rested(w); rested {
		return true
	}
	when .Keeps in C {
		if w.keep != .None && !w.keep_root {
			if give_kept(w, hs, {u64(lo), n, .End, .Value, 0}) == .Stop {
				return false
			}
			w.keep = .None
		}
	}
	return emit(w, hs, u64(lo), n, .End, .Value, 0, on) != .Stop
}
