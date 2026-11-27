package cbor

import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Parallel work-partition planning over CBOR headers (`plan_parts`) for multi-threaded `validate`, `build`, and `unmarshal`.

@(private)
SEAM_LEVELS :: WALK_LEVELS - 1

@(private)
Part_Plan :: build.Binary_Plan(Level(.Length_First))

@(private)
Pass_End :: build.Binary_Pass_End

@(private)
Pass :: struct($S: Spec, $RELATIVE: bool) {
	i, d, top: u64,
	c:         int,
	stack:     [SEAM_LEVELS]Level(S),
	counts:    [int(RELATIVE)]build.Part,
	runs:      [int(RELATIVE) * (SEAM_LEVELS + 1)]u64,
	breaks:    [int(RELATIVE)]int,
	// In a spec that orders keys, the spans of the last two items completed in the virtual level since its last break.
	tail:      [int(RELATIVE && S >= .Deterministic)][2][2]u64,
}

#assert(size_of(Pass(.Length_First, false)) <= 32 * 1024)

@(private)
VIRTUAL :: FLAG_INDEF | INDEF_COUNT

@(private)
pass_start :: proc "contextless" (st: ^Pass($S, $RELATIVE), i: u64) {
	st.i, st.d, st.c = i, 0, 0
	when RELATIVE {
		st.top = VIRTUAL
		st.counts[0] = {}
		st.breaks[0] = 0
		when S >= .Deterministic {
			st.tail[0] = {}
		}
	} else {
		st.top = 0
	}
}

@(private)
plan_run :: proc(src: []u8, $S: Spec, $RELATIVE: bool, st: ^Pass(S, RELATIVE), stop: u64, plan: ^Part_Plan) -> Pass_End #no_bounds_check {
	STRICT :: S != .Cbor
	n := u64(len(src))
	i, d, top, c := st.i, st.d, st.top, st.c
	defer st.i, st.d, st.top, st.c = i, d, top, c
	stack := &st.stack
	part: ^build.Part
	when RELATIVE {
		part = &st.counts[0]
	} else {
		part = &plan.parts[len(plan.parts) - 1]
		cut := build.binary_seam_cut(plan, n)
	}
	for i < stop {
		when !RELATIVE {
			if i >= cut && d > 0 && top & FLAG_TAG == 0 && top & (FLAG_OBJECT | 1) != FLAG_OBJECT | 1 && src[i] != 0xff {
				part.to = int(i)
				if !build.binary_plan_seam(plan, i, top, c, stack[:d], FLAG_OBJECT, FLAG_TAG) {
					return .Failed
				}
				part = &plan.parts[len(plan.parts) - 1]
				cut = build.binary_seam_cut(plan, n)
			}
		}
		when S >= .Deterministic {
			start := i
		}
		b := src[i]
		ai := b & 31
		key_due := key_is_due(top)
		if key_due && b - 0x80 < 0x7f {
			return .Ended
		}
		switch CLASS[b] {
		case .Int, .Bytes, .Text:
			arg, hl, read := read_head(src, i, ai)
			if !read || b >> 5 >= 2 && arg > n - i - hl {
				return .Ended
			}
			i += hl + (arg if b >> 5 >= 2 else 0)
			part.nodes += 1
		case .Array, .Map, .Indefinite_Container:
			if d == SEAM_LEVELS {
				return .Failed
			}
			pair := u64(b >> 5) & 1
			frame := indefinite_frame(pair)
			waits := true
			if ai == 31 {
				i += 1
			} else {
				arg, hl, read := read_head(src, i, ai)
				if !read || arg > (n - i - hl) >> pair {
					return .Ended
				}
				i += hl
				frame = frame_of(arg, pair)
				waits = arg != 0
			}
			part.nodes += 1
			c += 1
			part.levels = max(part.levels, c)
			stack[d] = {frame = top}
			d += 1
			top = frame
			if waits {
				continue
			}
		case .False, .True, .Null, .Simple:
			i += 1
			part.nodes += 1
		case .Simple_8:
			if i + 2 > n {
				return .Ended
			}
			i += 2
			part.nodes += 1
		case .Float:
			if i + 1 + u64(1) << (ai - 24) > n {
				return .Ended
			}
			i += 1 + u64(1) << (ai - 24)
			part.nodes += 1
		case .Tag:
			tag, hl, read := read_head(src, i, ai)
			if !read || i + hl >= n {
				return .Ended
			}
			i += hl
			part.comments += 1
			if tag >= 2 && tag <= 5 {
				r := folded(src, i, tag, STRICT)
				if r.fault != 0 {
					return .Ended
				}
				i = r.end
				part.nodes += 1
				break
			}
			if d == SEAM_LEVELS {
				return .Failed
			}
			stack[d] = {frame = top}
			d += 1
			top = FLAG_TAG | 1
			continue
		case .Indefinite_String:
			for i += 1; i >= n || src[i] != 0xff; {
				if i >= n {
					return .Ended
				}
				arg, hl, read := read_head(src, i, src[i] & 31)
				if src[i] >> 5 != b >> 5 || src[i] & 31 > 27 || !read || arg > n - i - hl {
					return .Ended
				}
				i += hl + arg
			}
			i += 1
			part.nodes += 1
		case .Break:
			when RELATIVE {
				if d == 0 {
					k := st.breaks[0]
					if k == len(st.runs) {
						return .Ended
					}
					st.runs[k] = INDEF_COUNT - (top & COUNT_MASK)
					st.breaks[0] += 1
					when S >= .Deterministic {
						st.tail[0] = {}
					}
					top = VIRTUAL
					i += 1
					continue
				}
			}
			if break_refused(top) {
				return .Ended
			}
			i += 1
			top = top & ~COUNT_MASK | 1
		case .Reserved:
			return .Ended
		}
		when S >= .Deterministic {
			if key_due && !keys_ordered(src, &stack[d - 1].prev[0], start, i, S) {
				return .Ended
			}
		}
		when RELATIVE && S >= .Deterministic {
			scalar := d == 0
		}
		for d > 0 {
			top -= 1
			if top & COUNT_MASK != 0 {
				break
			}
			c -= int(top & FLAG_TAG == 0)
			d -= 1
			top = stack[d].frame
		}
		if d == 0 {
			when RELATIVE {
				top -= 1
				when S >= .Deterministic {
					st.tail[0][0] = st.tail[0][1]
					st.tail[0][1] = {start, i} if scalar else {}
				}
			} else {
				return .Ended
			}
		}
	}
	return .Stopped
}

@(private)
plan_carry :: proc(plan: ^Part_Plan, $S: Spec, st: ^Pass(S, false), sm: ^Pass(S, true)) -> (ok, ended: bool) {
	build.binary_plan_add_counts(plan, st.c, sm.counts[0])
	virtual := sm.top if sm.d == 0 else sm.stack[0].frame
	breaks := sm.breaks[0]
	for k in 0 ..= breaks {
		got := build.binary_pass_complete(st, sm.runs[k] if k < breaks else INDEF_COUNT - (virtual & COUNT_MASK), COUNT_MASK, FLAG_TAG)
		if got.closed {
			return true, true
		}
		if k < breaks {
			if break_refused(st.top) {
				return true, true
			}
			st.top = st.top & ~COUNT_MASK | 1
			if build.binary_pass_complete(st, 1, COUNT_MASK, FLAG_TAG).closed {
				return true, true
			}
		} else {
			when S >= .Deterministic {
				if st.d > 0 && st.top & FLAG_OBJECT != 0 {
					for j := got.items; j > 0 && j + 2 > got.items; j -= 1 {
						at := j + u64(got.child)
						span := sm.tail[0][1 - (got.items - j)]
						if (got.wait0 - (at - 1)) & 1 == 0 {
							if span != {} {
								st.stack[st.d - 1].prev[0] = span
							}
							break
						}
					}
				}
			}
		}
	}
	return build.binary_plan_carry_open(st, sm, SEAM_LEVELS, FLAG_TAG), false
}

@(private)
plan_parts :: proc(src: []u8, $S: Spec, want: int, plan: ^Part_Plan, runner: ^tape.Runner) -> bool {
	chunks :: proc(src: []u8, want: int, plan: ^Part_Plan, runner: ^tape.Runner) -> bool {
		start_rel :: proc "contextless" (st: ^Pass(S, true), i: u64) { pass_start(st, i) }
		start_abs :: proc "contextless" (st: ^Pass(S, false), i: u64) { pass_start(st, i) }
		run_rel :: proc(src: []u8, st: ^Pass(S, true), stop: u64) -> Pass_End { return plan_run(src, S, true, st, stop, nil) }
		run_abs :: proc(src: []u8, st: ^Pass(S, false), stop: u64, plan: ^Part_Plan) -> Pass_End { return plan_run(src, S, false, st, stop, plan) }
		is_container :: proc "contextless" (b: u8) -> bool { return b >> 5 | 1 == 5 }
		guess :: proc(src: []u8, st: ^Pass(S, true), cut, stop: u64) -> u64 {
			return build.binary_guess_start(src, st, cut, stop, is_container, start_rel, run_rel)
		}
		carry :: proc(plan: ^Part_Plan, st: ^Pass(S, false), sm: ^Pass(S, true)) -> (bool, bool) { return plan_carry(plan, S, st, sm) }
		return build.binary_plan_chunks(src, want, plan, runner, Pass(S, true), Pass(S, false), start_rel, start_abs, guess, run_rel, run_abs, carry)
	}
	return build.binary_plan_parts(src, want, plan, runner, chunks)
}
