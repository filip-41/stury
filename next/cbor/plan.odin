package cbor

import "base:intrinsics"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The plan of a build on threads: the parts a text is cut into and the frames each starts with, read as the heads of
// the text by relative passes on the runner's threads and one absolute pass over the heads between them. `parallel.odin`
// builds the parts.
// The levels the pass and a part's walk hold in their frames, so a part's walk allocates nothing, one fewer than the
// walk's frame, whose last level a part's walk opens in. A text that nests deeper is built on one thread.
@(private)
SEAM_LEVELS :: WALK_LEVELS - 1

// Where a part starts: the walk's `d` levels there, from `Part_Plan.levels[at:]`, and its innermost frame `top`.
@(private)
Seam :: struct {
	d, top: u64,
	at:     int,
}

// The parts of a text, where each starts, and the kinds of the containers open at each seam.
@(private)
Part_Plan :: struct {
	want:   int, // the parts the text is cut into, at most
	parts:  [dynamic]build.Part,
	seams:  [dynamic]Seam,
	levels: [dynamic]Level(.Length_First), // sized for the widest `Level`, read back as the spec's own
	kinds:  [dynamic]tape.Kind,
}

// What a pass over the heads ended at: its stop, a head the walk refuses or the end of the item, or memory or a nest
// the plan is refused.
@(private)
Pass_End :: enum u8 {
	Stopped,
	Ended,
	Failed,
}

// A pass over the heads of a text, its state between calls of `plan_run`: the position, the open levels as the walk
// holds them, and the count of open containers. A pass of the text from its start is absolute and is the plan's. A
// relative pass starts anywhere a head may start, inside a virtual indefinite array that stands for the levels open
// before it, and keeps what it reads of them: the items it completes in the virtual level in `runs`, one for each break
// that ends it, and the counts of the part it would make. The levels it holds past the virtual one are the containers
// it leaves open.
@(private)
Pass :: struct($S: Spec, $RELATIVE: bool) {
	i, d, top: u64,
	c:         int,
	stack:     [SEAM_LEVELS]Level(S),
	counts:    [int(RELATIVE)]build.Part,
	runs:      [int(RELATIVE) * (SEAM_LEVELS + 1)]u64,
	breaks:    [int(RELATIVE)]int,
	// In a spec that orders keys, the spans of the last two items completed in the virtual level since its last break,
	// the older first, a span of 0 for an item that is no scalar. The last key of the level that takes them is one of
	// them.
	tail:      [int(RELATIVE && S >= .Deterministic)][2][2]u64,
}

// The absolute pass is a local of the read that plans, which takes the place of a walk's frame and so stays within its
// bound.
#assert(size_of(Pass(.Length_First, false)) <= 32 * 1024)

// The frame that stands for the levels open before a relative pass.
@(private)
VIRTUAL :: FLAG_INDEF | INDEF_COUNT

// Bytes a relative pass reads before the items it keeps, for its heads to meet the text's own.
@(private)
WARM_BYTES :: 256
// The starts a guess tries when a head the walk refuses ends the warm-up.
@(private)
WARM_TRIES :: 8
// The bytes from a chunk's cut a guess looks through for a byte that opens an array or a map.
@(private)
GUESS_BYTES :: 4096

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

// The next cut of an absolute pass: where the next seam may be, past which the plan has its parts.
@(private)
seam_cut :: #force_inline proc "contextless" (plan: ^Part_Plan, n: u64) -> u64 {
	return max(u64) if len(plan.parts) == plan.want else n / u64(plan.want) * u64(len(plan.parts))
}

// Reads the heads of `src` from the pass's position until a head starts at `stop` or past it, as the walk of `S`
// reads them, counting the nodes, facts and levels the walk stores into the pass's counts or, for an absolute pass,
// into the last part of `plan`, which it cuts into parts at its seams. The pass has read a head the walk refuses,
// or the end of the item, when it ends.
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
		cut := seam_cut(plan, n)
	}
	for i < stop {
		when !RELATIVE {
			if i >= cut && d > 0 && top & FLAG_TAG == 0 && top & (FLAG_OBJECT | 1) != FLAG_OBJECT | 1 && src[i] != 0xff {
				part.to = int(i)
				if !plan_seam(plan, i, top, c, stack[:d]) {
					return .Failed
				}
				part = &plan.parts[len(plan.parts) - 1]
				cut = seam_cut(plan, n)
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

// What the innermost level of a pass took of the items given to it: how many it waited for before the first it took,
// how many of the items given it took, and whether the first it took was the level that closed in it.
@(private)
Receipt :: struct {
	closed: bool, // the item closed
	wait0:  u64,
	items:  u64,
	child:  bool,
}

// Gives `m` completed items to the innermost level of `st`, which closes each level that waited for no more.
@(private)
complete :: proc "contextless" ($S: Spec, st: ^Pass(S, false), m: u64) -> (r: Receipt) {
	m := m
	for m > 0 {
		if st.d == 0 {
			r.closed = true
			return
		}
		waits := st.top & COUNT_MASK
		if m < waits {
			st.top -= m
			r.wait0, r.items = waits, m - u64(r.child)
			return
		}
		m -= waits
		st.c -= int(st.top & FLAG_TAG == 0)
		st.d -= 1
		st.top = st.stack[st.d].frame
		m += 1
		r.child = true
	}
	return
}

// Carries the absolute pass `st` over what the relative pass `sm` read, which starts at its position, as a pass of the
// same heads would: the items it completed in the levels before it, one run between breaks at a time, then the
// containers it left open. The counts of `sm` go to the last part of `plan`. Returns false for a text that nests past
// `SEAM_LEVELS`, and `ended` for one whose item closed or whose break no level may take.
@(private)
plan_carry :: proc(plan: ^Part_Plan, $S: Spec, st: ^Pass(S, false), sm: ^Pass(S, true)) -> (ok, ended: bool) {
	part := &plan.parts[len(plan.parts) - 1]
	part.nodes += sm.counts[0].nodes
	part.comments += sm.counts[0].comments
	part.levels = max(part.levels, st.c + sm.counts[0].levels)
	virtual := sm.top if sm.d == 0 else sm.stack[0].frame
	breaks := sm.breaks[0]
	for k in 0 ..= breaks {
		got := complete(S, st, sm.runs[k] if k < breaks else INDEF_COUNT - (virtual & COUNT_MASK))
		if got.closed {
			return true, true
		}
		if k < breaks {
			if break_refused(st.top) {
				return true, true
			}
			st.top = st.top & ~COUNT_MASK | 1
			if complete(S, st, 1).closed {
				return true, true
			}
		} else {
			when S >= .Deterministic {
				// The last key the level that took the last items has is one of the last two of them, the later when
				// its place among what the level took is a key's.
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
	for j in 0 ..< sm.d {
		if st.d == SEAM_LEVELS {
			return false, false
		}
		frame := sm.stack[j + 1].frame if j + 1 < sm.d else sm.top
		st.stack[st.d] = {frame = st.top, prev = sm.stack[j].prev}
		st.d += 1
		st.top = frame
		st.c += int(frame & FLAG_TAG == 0)
	}
	st.i = sm.i
	return true, false
}

// A start for the relative pass `sm` of the chunk of `src` from `cut` to `stop`, or 0 for none: the first byte within
// `GUESS_BYTES` of `cut` that opens an array or a map and from which the heads read on without a refusal for
// `WARM_BYTES`, at most `WARM_TRIES` such bytes tried, as a byte inside a string may open one by chance and the
// warm-up weeds that start out. Else the first of the `WARM_TRIES` bytes from `cut` from which the heads read on so.
@(private)
guess_start :: proc(src: []u8, $S: Spec, sm: ^Pass(S, true), cut, stop: u64) -> u64 {
	end := min(cut + GUESS_BYTES, stop)
	tries := 0
	for at in cut ..< end {
		if src[at] >> 5 | 1 == 5 {
			pass_start(sm, at)
			if plan_run(src, S, true, sm, min(at + WARM_BYTES, u64(len(src))), nil) == .Stopped {
				return sm.i
			}
			tries += 1
			if tries == WARM_TRIES {
				break
			}
		}
	}
	for t in 0 ..< u64(WARM_TRIES) {
		pass_start(sm, cut + t)
		if plan_run(src, S, true, sm, min(cut + t + WARM_BYTES, u64(len(src))), nil) == .Stopped {
			return sm.i
		}
	}
	return 0
}

// Reads the heads of `src` for parts of `plan`. The text is cut into `want` chunks. A relative pass reads each chunk
// but the first from a start `guess_start` gives, until the next chunk's cut, on the threads of `runner`. One absolute
// pass then reads from the text's start the heads between a chunk's end and the next chunk's guessed start, cutting
// parts at its seams, and carries its state over the relative pass of each chunk whose guess it reaches exactly, which
// reads the same heads from there, as the heads in a text do not depend on the items that hold them. A guess it does
// not reach, in a text where its heads do not meet the text's own, has the chunk read by the absolute pass. False when
// memory is refused or the text nests past `SEAM_LEVELS`.
@(private)
plan_chunks :: proc(src: []u8, $S: Spec, want: int, plan: ^Part_Plan, runner: ^tape.Runner) -> bool {
	Job :: struct {
		src:    []u8,
		want:   int,
		sums:   []Pass(S, true),
		starts: []u64,
		ends:   []Pass_End,
	}
	n := len(src)
	allocator := plan.parts.allocator
	sums, serr := make([]Pass(S, true), want, allocator)
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
	job := Job {
		src    = src,
		want   = want,
		sums   = sums,
		starts = starts,
		ends   = ends,
	}
	read_chunk :: proc(arg: rawptr, k: int) {
		j := (^Job)(arg)
		cut := u64(len(j.src) / j.want * k)
		stop := u64(len(j.src) / j.want * (k + 1)) if k + 1 < j.want else u64(len(j.src))
		sm := &j.sums[k]
		if k > 0 {
			j.starts[k] = guess_start(j.src, S, sm, cut, stop)
			if j.starts[k] == 0 {
				return
			}
		}
		pass_start(sm, j.starts[k])
		j.ends[k] = plan_run(j.src, S, true, sm, stop, nil)
	}
	tape.fan_each(runner, want, read_chunk, &job)
	st: Pass(S, false) = ---
	pass_start(&st, 0)
	chunks: for k := 0; k < want; k += 1 {
		if k == 0 || starts[k] != 0 {
			if st.i < starts[k] {
				switch plan_run(src, S, false, &st, starts[k], plan) {
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
				ok, ended := plan_carry(plan, S, &st, &sums[k])
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
			switch plan_run(src, S, false, &st, stop, plan) {
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

// Plans up to `want` parts of `src` into `plan`, each counted for the nodes, facts and levels its walk stores. False
// when memory is refused or the text nests past `SEAM_LEVELS`.
@(private)
plan_parts :: proc(src: []u8, $S: Spec, want: int, plan: ^Part_Plan, runner: ^tape.Runner) -> bool {
	plan.want = want
	if _, e := append(&plan.parts, build.Part{}); e != nil {
		return false
	}
	if _, e := append(&plan.seams, Seam{}); e != nil {
		return false
	}
	if !plan_chunks(src, S, want, plan, runner) {
		return false
	}
	plan.parts[len(plan.parts) - 1].to = len(src)
	build.parts_opens(plan.parts[:], plan.kinds[:])
	return true
}

// Ends the last part of `plan` at `i` and starts the next one there, in the walk's levels `stack` whose innermost frame
// is `top` and in which `c` containers are open.
@(private)
plan_seam :: proc(plan: ^Part_Plan, i, top: u64, c: int, stack: []Level($S)) -> bool {
	at := len(plan.levels)
	if resize(&plan.levels, at + len(stack)) != nil {
		return false
	}
	intrinsics.mem_copy_non_overlapping(&plan.levels[at], raw_data(stack), len(stack) * size_of(Level(S)))
	kinds := len(plan.kinds)
	for m in 1 ..= len(stack) {
		frame := stack[m].frame if m < len(stack) else top
		if frame & FLAG_TAG == 0 {
			if _, e := append(&plan.kinds, tape.Kind.Object if frame & FLAG_OBJECT != 0 else .Array); e != nil {
				return false
			}
		}
	}
	if _, e := append(&plan.seams, Seam{d = u64(len(stack)), top = top, at = at}); e != nil {
		return false
	}
	_, e := append(&plan.parts, build.Part{from = int(i), opens_at = kinds, opens_n = len(plan.kinds) - kinds, levels = c})
	return e == nil
}
