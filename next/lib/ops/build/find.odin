package build

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/tape"

// The hook of a `find`, which follows one path through a walk's tokens to its first answer and keeps no node. It enters
// only the containers on the path and skips every other container, whose bytes the walk judges with no tokens.
Finder :: struct {
	src:       []u8,
	steps:     []tape.Step,
	key_is:    Key_Is, // for a key that needs decoding
	bounds:    proc "contextless" (src: []u8, t: tape.Token) -> (head, tail: u8), // the format's `Format.bounds`
	answer:    tape.Span_Answer, // `FIND_NONE` while the value taken last has given no answer
	levels:    [^]Find_Level, // the entered containers, the root's first, one per step
	answers:   [^]tape.Span_Answer, // the rings of negative `Index` arrays, of answers or elements' spans
	rewalk:    proc "contextless" (h: ^Finder, lo: u64) -> tape.Walk_Result, // gives this hook the value at `lo` again
	block:     []u8, // what `levels` and `answers` are allocated in when the room has no space for them
	allocator: runtime.Allocator,
	alls_end:  int, // one past the last `All` step, 0 for none
	ring_top:  u32, // where in `answers` the next ring starts
	entered:   int,
	replacers: int, // entered containers whose answer a later member or element can replace
	first:     bool, // under `.First` the first member of a repeated key answers
	stop:      bool, // `stop_early`
	want:      bool, // the next value token is the one the path takes
	skip_end:  bool, // the next token is the `End` of a container this hook skipped
	pending:   bool, // that `End` closes the answer, or with `ringing` an element whose span the ring keeps
	ringing:   bool,
	held:      tape.Span_Answer, // with `ringing`, the span of the element that `End` closes
	replay:    bool, // the next value is an element its array counted, given again by `rewalk`
	replaying: bool, // inside a `rewalk`, where the arrays met follow the path through every element
	settled:   bool, // the answer is final, so the walk needs no more tokens
	refused:   bool, // a walk read again could not grow its stack, so the walk stopped with no answer
	// From `key` to `count_to`, what `finder_hook` reads of every token, which `finder_focus` sets.
	key:       string, // with `named`, the one key the open container takes
	key_head:  u64, // the first eight bytes of `key`
	key_tail:  u64, // the last eight bytes of `key`
	keys:      bool, // a key may be taken
	named:     bool, // only a key spelled `key` is
	quiet:     bool, // no scalar value is
	count_at:  ^u64, // with no `quiet`, the count of the open array whose elements before `count_to` are only counted
	count_to:  u64,
	skips:     tape.Skips,
	unspelled: tape.Unspelled,
	respell:   proc "contextless" (src: []u8, lo, hi: u64) -> u16, // a number answer's spelling
}

#assert(intrinsics.type_has_field(Finder, tape.SKIPS_FIELD) && intrinsics.type_has_field(Finder, tape.UNSPELLED_FIELD))

// Space for a `Finder`'s levels and rings, which a caller can leave unset as each entry is written before it is read.
Find_Room :: struct {
	levels:  [FIND_ROOM]Find_Level,
	answers: [FIND_ROOM]tape.Span_Answer,
}

// The levels, and the ring entries, a `Find_Room` has space for.
FIND_ROOM :: 64

// One container a `Finder` entered, and the children it has passed.
@(private)
Find_Level :: struct {
	lo:      u64, // its open bracket
	count:   u64,
	ring:    u32, // where its ring starts in `answers`, under a negative `Index` that needs one
	size:    u32, // its ring's entries, as `finder_ring_size` gives them
	slot:    u32, // the entry of its ring written next, which holds the oldest answer once the ring is full
	chosen:  bool, // a child was taken
	replays: bool, // its elements are passed whole and the one picked read again, as `finder_replays` judges
}

// The answer while the value taken last has given none, which `[]` of an empty array leaves. A path that ends with it
// answers `.Missing`.
@(private)
FIND_NONE :: tape.Span_Answer{outcome = .Not_Loaded}

// A finder for `steps` over `src`, its levels and rings in `room` when they fit, else allocated. `read.dups` is the
// format's resolved policy, never `.Default`.
@(require_results)
finder_start :: proc(src: []u8, format: ^tape.Format, steps: []tape.Step, read: tape.Read_Options, key_is: Key_Is, respell: proc "contextless" (src: []u8, lo, hi: u64) -> u16, rewalk: proc "contextless" (h: ^Finder, lo: u64) -> tape.Walk_Result, room: ^Find_Room, allocator: runtime.Allocator) -> (f: Finder, err: runtime.Allocator_Error) {
	// The most ring entries, as an entry's place is a `u32` and the bytes of the levels and rings fit an `int`.
	MAX_ANSWERS :: int(min(u64(max(u32)), u64(max(int) / (2 * size_of(tape.Span_Answer)))))
	answers := 0
	for step, i in steps {
		#partial switch v in step {
		case tape.Index:
			if size := finder_ring_size(steps, i, len(src)); size > 0 {
				if size > MAX_ANSWERS - answers {
					return {}, .Out_Of_Memory
				}
				answers += size
			}
		case tape.All:
			f.alls_end = i + 1
		}
	}
	f.levels, f.answers = raw_data(room.levels[:]), raw_data(room.answers[:])
	if len(steps) > FIND_ROOM || answers > FIND_ROOM {
		level_bytes := len(steps) * size_of(Find_Level)
		f.block = runtime.mem_alloc_non_zeroed(level_bytes + answers * size_of(tape.Span_Answer), align_of(Find_Level), allocator) or_return
		f.levels, f.answers = ([^]Find_Level)(raw_data(f.block)), ([^]tape.Span_Answer)(raw_data(f.block[level_bytes:]))
	}
	f.src, f.steps, f.key_is, f.respell, f.rewalk, f.answer, f.allocator = src, steps, key_is, respell, rewalk, FIND_NONE, allocator
	f.bounds = format.bounds
	f.first, f.stop, f.want = read.dups == .First, read.stop_early, true
	return f, nil
}

// Frees what `finder_start` allocated.
finder_end :: proc(f: ^Finder) {
	if f.block != nil {
		runtime.mem_free_with_size(raw_data(f.block), len(f.block), f.allocator)
	}
}

// Reads each token at the cost of a compare or two: a key the open container cannot take, or a scalar no step looks at,
// goes on without a call.
finder_hook :: #force_inline proc "contextless" (h: ^Finder, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action) #no_bounds_check {
	if t.role == .Key {
		if !h.keys {
			return s, .Next
		}
		if h.named && t.spelling & tape.SPELLING_DECODE == 0 {
			if int(t.n) != len(h.key) {
				return s, .Next
			}
			if t.n >= 8 {
				at := raw_data(h.src)[t.lo:]
				head := intrinsics.unaligned_load((^u64)(at))
				tail := intrinsics.unaligned_load((^u64)(at[t.n - 8:]))
				if head != h.key_head || tail != h.key_tail {
					return s, .Next
				}
			}
		}
	} else if t.kind <= .Plain && t.role == .Value {
		if h.quiet {
			return s, .Next
		}
		if h.count_at != nil && h.count_at^ != h.count_to {
			h.count_at^ += 1
			return s, .Next
		}
	} else if t.kind == .End && h.skip_end && !h.pending {
		h.skip_end = false
		return s, .Next
	}
	return s, finder_token(h, t)
}

// Sets what `finder_hook` reads for the tokens up to the next one the finder must look at. A container skipped gives
// only its `End` meanwhile, which the hook passes on its own unless it closes the answer.
@(private)
finder_focus :: proc "contextless" (h: ^Finder) #no_bounds_check {
	h.keys, h.named, h.quiet, h.count_at = false, false, false, nil
	if h.settled {
		h.quiet = true
		return
	}
	if h.entered == 0 || h.want {
		return
	}
	lv := &h.levels[h.entered - 1]
	none := h.answer.outcome == .Not_Loaded
	switch step in h.steps[h.entered - 1] {
	case tape.Name:
		h.quiet = true
		if !lv.chosen || !h.first {
			h.keys, h.named, h.key = true, true, string(step)
			if len(step) >= 8 {
				h.key_head = intrinsics.unaligned_load((^u64)(raw_data(step)))
				h.key_tail = intrinsics.unaligned_load((^u64)(raw_data(step)[len(step) - 8:]))
			}
		}
	case tape.All:
		h.keys, h.quiet = none, !none
	case tape.Index:
		h.quiet = step >= 0 && lv.chosen
		if step >= 0 && !lv.chosen {
			h.count_at, h.count_to = &lv.count, u64(step)
		}
	}
}

@(private)
finder_token :: #force_no_inline proc "contextless" (h: ^Finder, t: tape.Token) -> tape.Action {
	a := finder_step(h, t)
	finder_focus(h)
	return a
}

// The answer of a walk the finder read to its end or stop.
finder_answer :: #force_inline proc "contextless" (f: ^Finder) -> tape.Span_Answer {
	if f.answer.outcome == .Not_Loaded {
		return {outcome = .Missing}
	}
	// A spelled number counts at least one digit, so a spelling of 0 is one the walk left out.
	if f.answer.kind == .Number && f.answer.spelling == 0 {
		f.answer.spelling = f.respell(f.src, f.answer.lo, f.answer.hi)
	}
	return f.answer
}

@(private)
finder_step :: #force_inline proc "contextless" (h: ^Finder, t: tape.Token) -> tape.Action {
	if t.role > .Key {
		return .Next
	}
	if h.skip_end {
		h.skip_end = false
		if h.ringing {
			h.pending, h.ringing = false, false
			h.held.hi = t.lo + u64(t.n)
			finder_ring_put(h, &h.levels[h.entered - 1], h.held)
			return .Next
		}
		if h.pending {
			h.pending = false
			h.answer.hi = t.lo + u64(t.n)
			return finder_settle(h)
		}
		return .Next
	}
	if h.settled {
		return .Rest if t.kind == .Array || t.kind == .Object else .Next
	}
	if t.kind == .End {
		return finder_close(h, t)
	}
	if t.role == .Key {
		return finder_key(h, t)
	}
	return finder_value(h, t)
}

// The answer is final once it is one and no container still open on the path can replace it. Then the walk stops, or
// with no `stop_early` judges the rest of the text with no hooks from the next container on.
@(private)
finder_settle :: #force_inline proc "contextless" (h: ^Finder) -> tape.Action {
	if h.replacers > 0 || h.answer.outcome == .Not_Loaded {
		return .Next
	}
	h.settled = true
	return .Stop if h.stop else .Next
}

// Takes the next value as the one the path goes on through, which has given no answer yet.
@(private)
finder_take :: #force_inline proc "contextless" (h: ^Finder, lv: ^Find_Level) {
	lv.chosen, h.want, h.answer = true, true, FIND_NONE
}

@(private)
finder_value :: proc "contextless" (h: ^Finder, t: tape.Token) -> tape.Action #no_bounds_check {
	if h.entered > 0 {
		lv := &h.levels[h.entered - 1]
		#partial switch step in h.steps[h.entered - 1] {
		case tape.Index:
			if h.replay {
				h.replay = false
				break
			}
			lv.count += 1
			if lv.replays && !h.replaying {
				// The path goes on through only the element its array picks at the close, so each element is passed
				// whole and kept as a span, and the one picked is read again.
				head, tail: u8
				if t.kind <= .Plain {
					head, tail = h.bounds(h.src, t)
				}
				span := tape.Span_Answer{lo = t.lo - u64(head), hi = t.lo + u64(t.n) + u64(tail), kind = t.kind, head = head, tail = tail}
				if t.kind == .Array || t.kind == .Object {
					h.held, h.skip_end, h.pending, h.ringing = span, true, true, true
					return .Skip
				}
				finder_ring_put(h, lv, span)
				return .Next
			}
			if step < 0 {
				if step < -1 && lv.count > 1 {
					finder_ring_put(h, lv, h.answer)
				}
				finder_take(h, lv)
			} else if !lv.chosen && lv.count - 1 == u64(step) {
				finder_take(h, lv)
			}
		case tape.All:
			// An element is taken while those before it gave no answer, so `[]` of an empty array gives none.
			if h.answer.outcome == .Not_Loaded {
				finder_take(h, lv)
			}
		}
	}
	container := t.kind == .Array || t.kind == .Object
	if !h.want {
		if container {
			h.skip_end = true
			return .Skip
		}
		return .Next
	}
	h.want = false
	at := h.entered
	if at == len(h.steps) {
		return finder_reach(h, t, .Found)
	}
	switch step in h.steps[at] {
	case tape.Name:
		if t.kind == .Object {
			return finder_enter(h, !h.first, t.lo, 0, false)
		}
	case tape.Index:
		if t.kind == .Array {
			return finder_enter(h, step < 0, t.lo, u32(finder_ring_size(h.steps, at, len(h.src))), finder_replays(h.steps, at))
		}
	case tape.All:
		if container {
			return finder_enter(h, false, t.lo, 0, false)
		}
	}
	// A null reads as null through the steps after the last `All`, as in jq.
	if t.kind == .Null && at >= h.alls_end {
		h.answer = {outcome = .Missing}
		return finder_settle(h)
	}
	return finder_reach(h, t, .Wrong_Kind)
}

// Takes the value of `t` as the answer, a container's at its `End`.
@(private)
finder_reach :: #force_inline proc "contextless" (h: ^Finder, t: tape.Token, outcome: tape.Presence) -> tape.Action {
	if t.kind == .Array || t.kind == .Object {
		h.answer = {lo = t.lo, kind = t.kind, outcome = outcome, spelling = t.spelling}
		h.pending, h.skip_end = true, true
		return .Skip
	}
	head, tail := h.bounds(h.src, t)
	h.answer = {lo = t.lo - u64(head), hi = t.lo + u64(t.n) + u64(tail), kind = t.kind, outcome = outcome, spelling = t.spelling, head = head, tail = tail}
	return finder_settle(h)
}

// Enters the container opened at `lo`, with a ring of `ring` entries.
@(private)
finder_enter :: #force_inline proc "contextless" (h: ^Finder, replaces: bool, lo: u64, ring: u32, replays: bool) -> tape.Action {
	h.levels[h.entered] = {lo = lo, ring = h.ring_top, size = ring, replays = replays}
	h.ring_top += ring
	h.replacers += int(replaces)
	h.entered += 1
	return .Next
}

@(private)
finder_key :: proc "contextless" (h: ^Finder, t: tape.Token) -> tape.Action #no_bounds_check {
	lv := &h.levels[h.entered - 1]
	#partial switch step in h.steps[h.entered - 1] {
	case tape.Name:
		if (!lv.chosen || !h.first) && finder_key_is(h, t, string(step)) {
			finder_take(h, lv)
		}
	case tape.All:
		if h.answer.outcome == .Not_Loaded {
			finder_take(h, lv)
		}
	}
	// A member not taken has its value skipped when it is a container and ignored when it is a scalar.
	return .Next
}

@(private)
finder_key_is :: #force_inline proc "contextless" (h: ^Finder, t: tape.Token, name: string) -> bool {
	// A `Name` takes a string key only, as a format whose keys may be numbers holds `1` and `"1"` apart.
	return t.kind == .String && key_spelled(h.src, t, name, h.key_is)
}

// The answer of a container on the path at its `End` `t`, the one its taken child gave or why none was taken.
@(private)
finder_close :: proc "contextless" (h: ^Finder, t: tape.Token) -> tape.Action #no_bounds_check {
	// One array at a time is read again, so a replay holds one more walk at most and reads each element once more.
	if picked := &h.levels[h.entered - 1]; picked.replays && !h.replaying {
		if picked.count >= u64(-h.steps[h.entered - 1].(tape.Index)) {
			h.want, h.replay, h.replaying, h.answer, picked.chosen = true, true, true, FIND_NONE, true
			r := h.rewalk(h, h.answers[picked.ring + picked.slot].lo)
			h.replaying = false
			if u8(r) == tape.WALK_NO_MEMORY {
				h.refused = true
				return .Stop
			}
		}
	}
	h.entered -= 1
	lv := &h.levels[h.entered]
	h.ring_top = lv.ring
	switch step in h.steps[h.entered] {
	case tape.Name:
		h.replacers -= int(!h.first)
		if !lv.chosen {
			finder_miss(h, lv, t, .Object)
		}
	case tape.All:
	case tape.Index:
		if step >= 0 {
			if !lv.chosen {
				finder_miss(h, lv, t, .Array)
			}
		} else {
			h.replacers -= 1
			from_end := u64(-step)
			// The ring holds answers unless the element picked was read again.
			answers := h.replaying || !lv.replays
			if answers && from_end > 1 && lv.count > 0 {
				finder_ring_put(h, lv, h.answer)
			}
			if lv.count < from_end {
				finder_miss(h, lv, t, .Array)
			} else if answers && from_end > 1 {
				h.answer = h.answers[lv.ring + lv.slot]
			}
		}
	}
	if h.answer.outcome == .Not_Loaded && finder_spent(h) {
		h.answer = {outcome = .Missing}
	}
	return finder_settle(h)
}

// Whether every container open on the path has taken the one child it can, by a key under `.First` or a position from
// the start, so that a path that has given no answer gives none.
@(private)
finder_spent :: proc "contextless" (h: ^Finder) -> bool #no_bounds_check {
	for i in 0 ..< h.entered {
		if !h.levels[i].chosen {
			return false
		}
		switch step in h.steps[i] {
		case tape.Name:
			if !h.first {
				return false
			}
		case tape.Index:
			if step < 0 {
				return false
			}
		case tape.All:
			return false
		}
	}
	return true
}

// A member or element the container of `lv`, closed by `t`, lacks. jq reads it as a null, so with an `All` to come the
// container is the value that cannot take the path.
@(private)
finder_miss :: #force_inline proc "contextless" (h: ^Finder, lv: ^Find_Level, t: tape.Token, kind: tape.Kind) {
	if h.entered + 1 < h.alls_end {
		h.answer = {lo = lv.lo, hi = t.lo + u64(t.n), kind = kind, outcome = .Wrong_Kind}
	} else {
		h.answer = {outcome = .Missing}
	}
}

// Keeps `entry`, the answer or the span of the element just passed, in the ring of `lv`, which holds the last
// `-step` elements' entries.
@(private)
finder_ring_put :: #force_inline proc "contextless" (h: ^Finder, lv: ^Find_Level, entry: tape.Span_Answer) #no_bounds_check {
	h.answers[lv.ring + lv.slot] = entry
	lv.slot = 0 if lv.slot + 1 == lv.size else lv.slot + 1
}

// Whether the elements of the array at negative `Index` step `at` are passed whole and the one picked read again: when
// a `Name` follows, as a key compared in each element costs more than passing it. Elements before an `Index` or `All`
// are cheaper to walk into, and a last step's answer is the element itself.
@(private)
finder_replays :: #force_inline proc "contextless" (steps: []tape.Step, at: int) -> bool {
	step, negative := steps[at].(tape.Index)
	if !negative || step >= 0 || at + 1 == len(steps) {
		return false
	}
	_, named := steps[at + 1].(tape.Name)
	return named
}

// The ring entries the negative `Index` step `at` needs over a text of `n` bytes: one per element it reaches back to,
// but none for `-1` when it keeps answers, as the last element's is in hand at the close. An element spends a byte at
// least, so a ring past `n` entries holds nothing more.
@(private)
finder_ring_size :: #force_inline proc "contextless" (steps: []tape.Step, at: int, n: int) -> int {
	step, ok := steps[at].(tape.Index)
	if !ok || step >= 0 || step == -1 && !finder_replays(steps, at) {
		return 0
	}
	return int(min(0 - u64(int(step)), u64(n)))
}
