package scan

// The open-frame stack of the walks: where its cap spills to the heap, the innermost frame, a frame's close,
// and the out-of-line runs of brackets.

import "base:intrinsics"
import "base:runtime"
import "walk"

// The frames past MAX_DEPTH: `limit` of them in `spill`, the fixed array's copied in. Nil when the allocator
// refuses.
@(private, cold)
spill_frames :: proc(spill: ^[]byte, fixed: [^]Open_Frame, limit: u64, alloc: runtime.Allocator) -> [^]Open_Frame {
	buf, err := runtime.mem_alloc_non_zeroed(int(limit) * size_of(Open_Frame), align_of(Open_Frame), alloc)
	if err != nil {
		return nil
	}
	spill^ = buf
	frames := ([^]Open_Frame)(raw_data(buf))
	copy(frames[:MAX_DEPTH], fixed[:MAX_DEPTH])
	return frames
}

// A push with `sp` at the cap `max_depth`: `.Too_Deep`, or under `$deep`, short of `limit`, the frames move off
// the stack into the spill.
@(private)
depth_cap_hit :: #force_inline proc(s: ^Scanner, $deep: bool, spill: ^[]byte, frames: ^$F, max_depth: ^u64, limit: u64) -> Maybe(Error) {
	when deep {
		if max_depth^ == limit {
			return Error{offset = s.pos, kind = .Too_Deep}
		}
		spilled := (^[^]Open_Frame)(frames)
		if spilled^ = spill_frames(spill, spilled^, limit, s.alloc); spilled^ == nil {
			return Error{offset = s.pos, kind = .Out_Of_Memory}
		}
		max_depth^ = limit
		return nil
	} else {
		return Error{offset = s.pos, kind = .Too_Deep}
	}
}

// The innermost open frame. `sp - 1` names a frame a checked push wrote, so it needs no second check.
@(private)
top_frame :: proc {
	top_frame_fixed,
	top_frame_deep,
}

@(private)
top_frame_fixed :: #force_inline proc(frames: ^[MAX_DEPTH]Open_Frame, sp: u64) -> ^Open_Frame {
	#no_bounds_check {
		return &frames[sp - 1]
	}
}

@(private)
top_frame_deep :: #force_inline proc(frames: ^[^]Open_Frame, sp: u64) -> ^Open_Frame {
	return &frames[sp - 1]
}

// A long run of brackets on a walk that writes rows and nothing else (`BRACKET_RUNS`). Out of line, so the run
// keeps its cursor, depth and row count in registers the walk has no room for. It is entered only past eight
// brackets in a row, so its call is paid on deeply nested input alone.
@(private)
BRACKET_RUN_MIN :: 8
@(private)
OPEN_RUN_WORD :: 0x5b5b_5b5b_5b5b_5b5b // eight `[`
@(private)
CLOSE_RUN_WORD :: 0x5d5d_5d5d_5d5d_5d5d // eight `]`

// Whether eight bytes at `s.pos` all equal the bracket in `word`.
@(private)
bracket_run_ahead :: #force_inline proc(s: ^Scanner, word: u64) -> bool {
	#no_bounds_check {
		return s.pos + BRACKET_RUN_MIN <= u64(len(s.src)) && intrinsics.unaligned_load((^u64le)(&s.src[s.pos])) == u64le(word)
	}
}

// The fused `[` loop's levels, while the depth cap and the row capacity leave room: each `[` pushes a frame
// and writes its row as `dom_run_open` does. What is left (a cap reached, a full edge, the run's end) is
// the caller's loop's.
@(private)
open_run :: #force_no_inline proc(
	src: []byte,
	pos: u64,
	frames: [^]Open_Frame,
	sp, max_depth: u64,
	base: [^]walk.Row,
	rows, room: int,
	$dom: bool,
) -> (pos_after, sp_after: u64, rows_after: int) {
	n := u64(len(src))
	pos, depth, at := pos, sp, rows
	flags: walk.Row_Flags
	when dom {
		flags = {.Decoded}
	}
	// The row goes out as four words, two paired stores, where field stores take five: the words of a
	// template whose only per-row fields, `lo` and `subtree_size`, each start a zero word's low half (the
	// layout `walk/tape.odin` asserts).
	tw := transmute([4]u64)walk.Row{key_lo = walk.NO_KEY, key_hi = walk.NO_KEY, kind = .Array, flags = flags}
	// One bound for the loop: the run stops at the depth cap, the end of the row block or the end of input.
	end := pos + min(max_depth - depth, u64(room - at), n - pos)
	#no_bounds_check for pos < end && src[pos] == '[' {
		frames[depth] = Open_Frame{lo = pos, row = u32(at)}
		w := ([^]u64)(&base[at])
		w[0] = u64(u32(pos))
		w[1] = tw[1]
		w[2] = tw[2] | u64(u32(at))
		w[3] = tw[3]
		at += 1
		depth += 1
		pos += 1
	}
	return pos, depth, at
}

// The closes of a run of `]`, the first of which closes `frames[sp - 1]`, an array: each patches its row as
// `close_frame` does and counts itself into its parent, while the parent is an array the next `]` closes.
// Leaves the walk just past a close with that close not yet counted into its parent, as `close_frame` does.
@(private)
close_run :: #force_no_inline proc(src: []byte, pos: u64, frames: [^]Open_Frame, sp: u64, base: [^]walk.Row, rows: int) -> (pos_after, sp_after: u64) {
	n := u64(len(src))
	pos, depth := pos, sp
	// A close inside the run counts into the frame the next close pops, so it rides along to that row
	// instead of being stored into a frame about to die.
	carry: u64
	#no_bounds_check for {
		fr := &frames[depth - 1]
		pos += 1
		if fr.row != walk.NO_ROW {
			r := &base[fr.row]
			r.hi = u32(pos)
			r.subtree_size = u32(rows) - fr.row
			r.cnt = u32(fr.members + carry)
		}
		depth -= 1
		if depth == 0 || pos >= n || src[pos] != ']' {
			break
		}
		parent := &frames[depth - 1]
		if parent.is_obj {
			break
		}
		carry = 1
	}
	return pos, depth
}

// Consume the closing bracket and record the container.
@(private)
close_frame :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	fr: ^Open_Frame,
	idx: u64,
	pend: ^Demand_Pend,
	$may_stop: bool,
	stopped: ^bool,
) {
	s.pos += 1
	// The `.Nodes` row was written at the open, with its key. This patches it.
	dom_container_close(q, Q, fr, s.pos, fr.members)
	when .Path in Q {
		// Two transitions. `frames[idx]` was a member of `frames[idx-1]` at step `idx-1`, so unless it is
		// the root its extent is final here: the answer a terminal step was waiting for. It was also read
		// at step `idx`, so its close settles the miss, resolves a negative `Index` and, at the root,
		// flushes the `.Last` slots.
		//
		// No stop test: callers check `stopped` right after, and a re-entry inside `auto_frame_closed`
		// carries its own halt flag.
		if idx >= 1 {
			auto_member_closed(q, Q, may_stop, stopped, int(idx) - 1, fr.lo, s.pos)
		}
		auto_frame_closed(s, q, Q, may_stop, stopped, int(idx), fr.lo, s.pos)
	}
	when .Demand in Q {
		// The root is nobody's member.
		if idx != 0 {
			walk.demand_value_closed(s, q, Q, idx, pend, may_stop, stopped)
		}
	}
	when .Unique in Q {
		key_set_close(q.keys, u32(idx + 1))
	} else when .Path in Q {
		if q.wild_keys {
			wild_close(q, u32(idx + 1))
		}
	}
}
