package msgpack

import "base:intrinsics"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Parallel work-partition planning over MessagePack headers (`plan_parts`) for multi-threaded
// `validate`, `build`, and root-array `unmarshal`.

@(private)
SEAM_LEVELS :: WALK_LEVELS - 1

@(private)
Seam :: struct {
	d, top: u64,
	at:     int,
}

@(private)
Part_Plan :: struct {
	want:   int,
	parts:  [dynamic]build.Part,
	seams:  [dynamic]Seam,
	levels: [dynamic]Level,
	kinds:  [dynamic]tape.Kind,
}

@(private)
Pass_End :: enum u8 {
	Stopped,
	Ended,
	Failed,
}

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
	Job :: struct {
		src:    []u8,
		want:   int,
		sums:   []Pass(true),
		starts: []u64,
		ends:   []Pass_End,
	}
	n := len(src)
	allocator := plan.parts.allocator
	sums, serr := make([]Pass(true), want, allocator)
	starts, terr := make([]u64, want, allocator)
	ends, eerr := make([]Pass_End, want, allocator)
	defer {
		delete(sums, allocator)
		delete(starts, allocator)
		delete(ends, allocator)
	}
	if serr != nil || terr != nil || eerr != nil {
		return false
	}
	job := Job{src = src, want = want, sums = sums, starts = starts, ends = ends}
	read_chunk :: proc(arg: rawptr, k: int) {
		j := (^Job)(arg)
		cut := u64(len(j.src) / j.want * k)
		stop := u64(len(j.src) / j.want * (k + 1)) if k + 1 < j.want else u64(len(j.src))
		sm := &j.sums[k]
		if k > 0 {
			j.starts[k] = guess_start(j.src, sm, cut, stop)
			if j.starts[k] == 0 {
				return
			}
		}
		pass_start(sm, j.starts[k])
		j.ends[k] = plan_run(j.src, true, sm, stop, nil)
	}
	hook.fan_each(runner, want, read_chunk, &job)
	st: Pass(false) = ---
	pass_start(&st, 0)
	chunks: for k := 0; k < want; k += 1 {
		if k == 0 || starts[k] != 0 {
			if st.i < starts[k] {
				switch plan_run(src, false, &st, starts[k], plan) {
				case .Failed:
					return false
				case .Ended:
					break chunks
				case .Stopped:
				}
			}
			if st.i == starts[k] {
				if ends[k] == .Failed {
					return false
				}
				ok, ended := plan_carry(plan, &st, &sums[k])
				if !ok {
					return false
				}
				if ended || ends[k] == .Ended {
					break chunks
				}
				continue
			}
		}
		stop := u64(n / want * (k + 1)) if k + 1 < want else u64(n)
		if st.i < stop {
			switch plan_run(src, false, &st, stop, plan) {
			case .Failed:
				return false
			case .Ended:
				break chunks
			case .Stopped:
			}
		}
	}
	return true
}

@(private)
plan_parts :: proc(src: []u8, want: int, plan: ^Part_Plan, runner: ^tape.Runner) -> bool {
	plan.want = want
	if _, e := append(&plan.parts, build.Part{}); e != nil {
		return false
	}
	if _, e := append(&plan.seams, Seam{}); e != nil {
		return false
	}
	if !plan_chunks(src, want, plan, runner) {
		return false
	}
	plan.parts[len(plan.parts) - 1].to = len(src)
	build.parts_opens(plan.parts[:], plan.kinds[:])
	return true
}

@(private)
plan_seam :: proc(plan: ^Part_Plan, i, top: u64, c: int, stack: []Level) -> bool {
	at := len(plan.levels)
	if resize(&plan.levels, at + len(stack)) != nil {
		return false
	}
	intrinsics.mem_copy_non_overlapping(&plan.levels[at], raw_data(stack), len(stack) * size_of(Level))
	kinds := len(plan.kinds)
	for m in 1 ..= len(stack) {
		frame := stack[m].frame if m < len(stack) else top
		if _, e := append(&plan.kinds, tape.Kind.Object if frame & FLAG_OBJECT != 0 else .Array); e != nil {
			return false
		}
	}
	if _, e := append(&plan.seams, Seam{d = u64(len(stack)), top = top, at = at}); e != nil {
		return false
	}
	_, e := append(&plan.parts, build.Part{from = int(i), opens_at = kinds, opens_n = len(plan.kinds) - kinds, levels = c})
	return e == nil
}
