package msgpack

import "base:intrinsics"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Parallel work-partition planning over MessagePack headers (`plan_parts`) for multi-threaded
// `validate`, `build`, and root-array `unmarshal`.

@(private)
SEAM_LEVELS :: WALK_LEVELS - 1

@(private)
Seam :: build.Binary_Seam

@(private)
Part_Plan :: build.Binary_Plan(Level)

@(private)
Pass_End :: build.Binary_Pass_End

@(private)
Pass :: struct($RELATIVE: bool) {
	i, d, top: u64,
	c:         int,
	stack:     [SEAM_LEVELS]Level,
	counts:    [int(RELATIVE)]build.Part,
	closed:    [int(RELATIVE)]u64, // completed items given back to the virtual parent level
}

#assert(size_of(Pass(false)) <= 32 * 1024)

@(private)
VIRTUAL :: u64(1) << 55

@(private)
WARM_BYTES :: 256
@(private)
WARM_TRIES :: 8
@(private)
GUESS_BYTES :: 4096

@(private)
pass_start :: proc "contextless" (st: ^Pass($RELATIVE), i: u64) {
	st.i, st.d, st.c = i, 0, 0
	when RELATIVE {
		st.top = VIRTUAL
		st.counts[0] = {}
		st.closed[0] = 0
	} else {
		st.top = 0
	}
}

@(private)
seam_cut :: #force_inline proc "contextless" (plan: ^Part_Plan, n: u64) -> u64 {
	return max(u64) if len(plan.parts) == plan.want else n / u64(plan.want) * u64(len(plan.parts))
}

@(private)
plan_run :: proc(src: []u8, $RELATIVE: bool, st: ^Pass(RELATIVE), stop: u64, plan: ^Part_Plan) -> Pass_End #no_bounds_check {
	n := u64(len(src))
	i, d, top, c := st.i, st.d, st.top, st.c
	defer st.i, st.d, st.top, st.c = i, d, top, c
	stack := &st.stack
	part: ^build.Part
	when RELATIVE {
		part = &st.counts[0]
	} else {
		part = &plan.parts[len(plan.parts) - 1]
		cut := seam_cut(plan, n)
	}
	for i < stop {
		when !RELATIVE {
			if i >= cut && d > 0 && top & (FLAG_OBJECT | 1) != FLAG_OBJECT | 1 {
				part.to = int(i)
				if !plan_seam(plan, i, top, c, stack[:d]) {
					return .Failed
				}
				part = &plan.parts[len(plan.parts) - 1]
				cut = seam_cut(plan, n)
			}
		}
		b := src[i]
		key_due := key_is_due(top)
		if b == 0xc1 || key_due && !KEY_ALLOWED[b] {
			return .Ended
		}
		switch Class(u8(CLASS[b]) & 15) {
		case .Fixint, .Nil, .False, .True:
			i += 1
			part.nodes += 1
		case .Uint_N, .Int_N, .Float:
			wlen := ARG_WIDTH[b]
			if u64(wlen) > n - i - 1 {
				return .Ended
			}
			i += 1 + u64(wlen)
			part.nodes += 1
		case .Fixstr:
			arg := u64(b & 0x1f)
			if arg > n - i - 1 {
				return .Ended
			}
			i += 1 + arg
			part.nodes += 1
		case .Str_N, .Bin_N:
			wlen := ARG_WIDTH[b]
			arg, ok := read_arg(src, i, wlen)
			hl := u64(1 + wlen)
			if !ok || arg > n - i - hl {
				return .Ended
			}
			i += hl + arg
			part.nodes += 1
		case .Fixext, .Ext_N:
			arg, hl: u64
			if b >= 0xd4 {
				hl = 2
				arg = u64(1) << (b - 0xd4)
				if hl > n - i || arg > n - i - hl {
					return .Ended
				}
			} else {
				wlen := ARG_WIDTH[b]
				ok: bool
				arg, ok = read_arg(src, i, wlen)
				hl = u64(2 + wlen)
				if !ok || hl > n - i || arg > n - i - hl {
					return .Ended
				}
			}
			i += hl + arg
			part.comments += 1
			part.nodes += 1
		case .Fixarray, .Fixmap, .Container_N:
			if d == SEAM_LEVELS {
				return .Failed
			}
			hl, arg, pair: u64
			if b < 0xa0 {
				hl = 1
				arg = u64(b & 0x0f)
				pair = u64(b < 0x90)
			} else {
				wlen := ARG_WIDTH[b]
				ok: bool
				arg, ok = read_arg(src, i, wlen)
				if !ok {
					return .Ended
				}
				hl = u64(1 + wlen)
				pair = u64(b >= 0xde)
			}
			if arg > (n - i - hl) >> pair {
				return .Ended
			}
			i += hl
			part.nodes += 1
			c += 1
			part.levels = max(part.levels, c)
			stack[d] = {frame = top}
			d += 1
			top = frame_of(arg, pair)
			if arg != 0 {
				continue
			}
		case .Reserved:
			return .Ended
		}
		for d > 0 {
			top -= 1
			if top & COUNT_MASK != 0 {
				break
			}
			c -= 1
			d -= 1
			top = stack[d].frame
		}
		if d == 0 {
			when RELATIVE {
				if top & COUNT_MASK == 0 {
					return .Ended
				}
				top -= 1
				st.closed[0] += 1
			} else {
				return .Ended
			}
		}
	}
	return .Stopped
}

@(private)
complete :: proc "contextless" (st: ^Pass(false), m: u64) -> bool {
	rem := m
	for rem > 0 {
		if st.d == 0 {
			return true
		}
		waits := st.top & COUNT_MASK
		if rem < waits {
			st.top -= rem
			return false
		}
		rem -= waits
		st.c -= 1
		st.d -= 1
		st.top = st.stack[st.d].frame
		rem += 1
	}
	return false
}

@(private)
plan_carry :: proc(plan: ^Part_Plan, st: ^Pass(false), sm: ^Pass(true)) -> (ok, ended: bool) {
	part := &plan.parts[len(plan.parts) - 1]
	part.nodes += sm.counts[0].nodes
	part.comments += sm.counts[0].comments
	part.levels = max(part.levels, st.c + sm.counts[0].levels)
	if complete(st, sm.closed[0]) {
		return true, true
	}
	for j in 0 ..< sm.d {
		if st.d == SEAM_LEVELS {
			return false, false
		}
		frame := sm.stack[j + 1].frame if j + 1 < sm.d else sm.top
		st.stack[st.d] = {frame = st.top}
		st.d += 1
		st.top = frame
		st.c += 1
	}
	st.i = sm.i
	return true, false
}

@(private)
guess_start :: proc(src: []u8, sm: ^Pass(true), cut, stop: u64) -> u64 {
	end := min(cut + GUESS_BYTES, stop)
	tries := 0
	for at in cut ..< end {
		b := src[at]
		if (b >= 0x80 && b <= 0x9f) || (b >= 0xdc && b <= 0xdf) {
			pass_start(sm, at)
			if plan_run(src, true, sm, min(at + WARM_BYTES, u64(len(src))), nil) == .Stopped {
				return sm.i
			}
			tries += 1
			if tries == WARM_TRIES {
				break
			}
		}
	}
	tries_left := min(u64(WARM_TRIES), stop - cut) if stop > cut else u64(0)
	for t in 0 ..< tries_left {
		pass_start(sm, cut + t)
		if plan_run(src, true, sm, min(cut + t + WARM_BYTES, u64(len(src))), nil) == .Stopped {
			return sm.i
		}
	}
	return 0
}

@(private)
plan_chunks :: proc(src: []u8, want: int, plan: ^Part_Plan, runner: ^tape.Runner) -> bool {
	start_rel :: proc "contextless" (st: ^Pass(true), i: u64) { pass_start(st, i) }
	start_abs :: proc "contextless" (st: ^Pass(false), i: u64) { pass_start(st, i) }
	run_rel :: proc(src: []u8, st: ^Pass(true), stop: u64) -> Pass_End { return plan_run(src, true, st, stop, nil) }
	run_abs :: proc(src: []u8, st: ^Pass(false), stop: u64, plan: ^Part_Plan) -> Pass_End { return plan_run(src, false, st, stop, plan) }
	return build.binary_plan_chunks(src, want, plan, runner, Pass(true), Pass(false), start_rel, start_abs, guess_start, run_rel, run_abs, plan_carry)
}

@(private)
plan_parts :: proc(src: []u8, want: int, plan: ^Part_Plan, runner: ^tape.Runner) -> bool {
	return build.binary_plan_parts(src, want, plan, runner, plan_chunks)
}

@(private)
plan_seam :: proc(plan: ^Part_Plan, i, top: u64, c: int, stack: []Level) -> bool {
	return build.binary_plan_seam(plan, i, top, c, stack, FLAG_OBJECT, 0)
}
