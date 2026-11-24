package build

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The hook of a `find`. It follows one path through a walk's tokens to its first answer and stores no node. It enters
// only the containers on the path and skips every other container, whose bytes the walk judges without giving tokens.
Finder :: struct {
	src:       []u8,
	// What a key token's offsets index: `src`, or the bytes a read of a text in pieces holds the keys in once they lie
	// before its window, as a delimited text's header does.
	key_text:  []u8,
	steps:     []tape.Step,
	format:    ^tape.Format,
	bounds:    proc "contextless" (src: []u8, t: tape.Token) -> (head, tail: u8), // the format's `Format.bounds`
	answer:    tape.Span_Answer, // `FIND_NONE` while the value taken last has given no answer
	levels:    [^]Find_Level, // the entered containers, the root's first, one per step
	answers:   [^]tape.Span_Answer, // the rings of negative `Index` arrays, of answers or elements' spans
	rewalk:    proc "contextless" (h: ^Finder, lo: u64) -> hook.Walk_Result, // gives this hook the value at `lo` again
	walk:      rawptr, // the walk giving this hook its tokens, which `rewalk` reads in
	block:     []u8, // what `levels` and `opens` are allocated in when the room has no space for them
	allocator: runtime.Allocator,
	alls_end:  int, // one past the last `All` step, 0 for none
	ring_top:  u32, // where in `answers` the next ring starts
	entered:   int,
	replacers: int, // entered containers whose answer a later member or element can replace
	dups:      tape.Duplicates, // the read's policy, resolved
	first:     bool, // under `.First` the first member of a repeated key answers
	group:     bool, // under `.Group` each member of a repeated key answers in turn, the first that gives one taken
	rewalks:   bool, // the format has `.Rewalk`
	stop:      bool, // `stop_early`
	want:      bool, // the next value token is the one the path takes
	keyed:     bool, // with `want`, the next token is the value of a key `finder_hook` took itself, of a `Name` step
	skip_end:  bool, // the next token is the `End` of a container this hook skipped
	pending:   bool, // that `End` closes the answer, or with `ringing` an element whose span the ring keeps
	ringing:   bool,
	held:      tape.Span_Answer, // with `ringing`, the span of the element that `End` closes
	replay:    bool, // the next value is an element its array counted, given again by `rewalk`
	replaying: bool, // inside a `rewalk`, where the arrays met follow the path through every element
	settled:   bool, // the answer is final, so the walk needs no more tokens
	refused:   bool, // a walk read again could not grow its stack, so the walk stopped with no answer
	// `key` to `count_to` are the fields `finder_hook` reads for every token. `finder_focus` sets them.
	key:       string, // with `named`, the one key the open container takes
	key_head:  u64, // the first eight bytes of `key`
	key_tail:  u64, // the last eight bytes of `key`
	keys:      bool, // a key may be taken
	named:     bool, // only a key spelled `key` is
	quiet:     bool, // no scalar value is
	count_at:  ^u64, // with no `quiet`, the count of the open array whose elements before `count_to` are only counted
	count_to:  u64,
	protocol:  hook.Protocol(FINDER_CAPS, hook.Unused, hook.Unused, hook.Unused),
	respell:   proc "contextless" (src: []u8, lo, hi: u64) -> u16, // a number answer's spelling
	opens:     [^]u64, // the open bracket of each entered container, as `levels`
	answers_cap: u32, // the entries `answers` has space for
	ring_block: []u8, // what `answers` is allocated in once the rings outgrow the room, which holds them with no gap
	ctx:        runtime.Context, // the caller's, for the allocations the contextless hook makes
}

FINDER_CAPS :: hook.Capabilities{.Skips, .Unspelled, .Walk, .Credits}

// Space for a `Finder`'s levels and the first entries of its rings. A caller can leave it uninitialized, since each
// entry is written before it is read.
Find_Room :: struct {
	levels:  [FIND_ROOM]Find_Level,
	opens:   [FIND_ROOM]u64,
	answers: [FIND_ROOM]tape.Span_Answer,
}

// The number of levels, and of ring entries, a `Find_Room` holds. A ring uses more only as its array has more elements.
FIND_ROOM :: 64

// A container a `Finder` entered and the children it has passed.
@(private)
Find_Level :: struct {
	count:   u64,
	ring:    u32, // where its ring starts in `answers`, under a negative `Index` that needs one
	size:    u32, // its ring's entries once full, as `finder_ring_size` gives them
	// Wide, so that a load of it is never part of a pair load that follows its store, which a core cannot forward.
	slot:    u64, // the entry of its ring written next, which holds the oldest answer once the ring is full. Under a
	// `Slice`, the entry of the element about to pass. Always below `have`.
	have:    u32, // the entries of its ring that `answers` holds space for, at most `size`
	chosen:  bool, // a child was taken
	replays: bool, // its elements are passed whole and the one picked read again, as `tape.step_replays` judges
	cut:     bool, // under a `Slice` with an end from the end, its answer is final
	object:  bool,
}

// The steps a find follows of `path`: a `Descend` at its end answers first the value the steps before it reach, so it
// is left out. False for a `Descend` with steps after it, which a find refuses, as its answers lie at any depth, which
// takes a scan's set of steps live in each container where a find holds a level per step.
@(private)
find_steps :: proc "contextless" (path: []tape.Step) -> ([]tape.Step, bool) {
	n := len(path)
	for n > 0 {
		if _, descends := path[n - 1].(tape.Descend); !descends {
			break
		}
		n -= 1
	}
	for s in path[:n] {
		if _, descends := s.(tape.Descend); descends {
			return nil, false
		}
	}
	return path[:n], true
}

// The answer while the value taken last has given none, which `[]` of an empty array leaves. A path that ends with it
// answers `.Missing`.
@(private)
FIND_NONE :: tape.Span_Answer{outcome = .Not_Loaded}

// Starts `f`, which the caller zeroed, as a finder for `steps` over `src`. Its levels are in `room` when they fit,
// else allocated, and its rings are in `room` until their arrays have more elements than `room` has entries for. With
// no `rewalk` it reads each value once and keeps a ring of spans where a replay would read a value again, as for a
// text whose bytes are read once and whose length `src` does not bound.
@(require_results)
finder_start :: proc(f: ^Finder, src: []u8, format: ^tape.Format, steps: []tape.Step, dups: tape.Duplicates, read: tape.Read_Options, respell: proc "contextless" (src: []u8, lo, hi: u64) -> u16, rewalk: proc "contextless" (h: ^Finder, lo: u64) -> hook.Walk_Result, room: ^Find_Room, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	// The most ring entries. An entry's index is a `u32`, and twice the bytes of the entries must fit an `int`.
	MAX_ANSWERS :: int(min(u64(max(u32)), u64(max(int) / (2 * size_of(tape.Span_Answer)))))
	answers := 0
	rewalks := .Rewalk in format.caps && rewalk != nil
	text := len(src) if rewalk != nil else max(int)
	for step, i in steps {
		#partial switch v in step {
		case tape.Index, tape.Slice:
			if size := finder_ring_size(steps, i, text, rewalks); size > 0 {
				if size > MAX_ANSWERS - answers {
					return .Out_Of_Memory
				}
				answers += size
			}
		case tape.All:
			f.alls_end = i + 1
		}
	}
	f.levels, f.opens, f.answers, f.answers_cap = raw_data(room.levels[:]), raw_data(room.opens[:]), raw_data(room.answers[:]), FIND_ROOM
	if len(steps) > FIND_ROOM {
		level_bytes := len(steps) * size_of(Find_Level)
		block, berr := runtime.mem_alloc_non_zeroed(level_bytes + len(steps) * size_of(u64), align_of(Find_Level), allocator)
		if e := took(berr, raw_data(block), level_bytes); e != nil {
			return e
		}
		f.block = block
		f.levels, f.opens = ([^]Find_Level)(raw_data(f.block)), ([^]u64)(raw_data(f.block[level_bytes:]))
	}
	f.src, f.key_text, f.steps, f.format, f.respell, f.rewalk, f.answer, f.allocator = src, src, steps, format, respell, rewalk, FIND_NONE, allocator
	f.bounds, f.rewalks, f.ctx = format.bounds, rewalks, context
	f.dups = tape.read_dups(format, dups)
	f.first, f.group, f.stop, f.want = f.dups == .First, f.dups == .Group, read.stop_early, true
	return nil
}

// Returns the lowest offset of a span the finder holds that may still be its answer, or `max(u64)` for none. The spans
// are the answer whose `End` is to come, the element whose span a ring keeps at its `End`, the spans in its rings and,
// under a ring, the answer of the element last read, which the ring takes at the next element.
finder_holds :: proc "contextless" (f: ^Finder) -> u64 #no_bounds_check {
	lo := max(u64)
	if f.pending {
		lo = f.held.lo if f.ringing else f.answer.lo
	}
	rings := false
	for lv in f.levels[:f.entered] {
		rings ||= lv.size > 0
		for e in f.answers[lv.ring:][:min(lv.count, u64(lv.have))] {
			if e.outcome != .Not_Loaded && e.hi > e.lo {
				lo = min(lo, e.lo)
			}
		}
	}
	if a := f.answer; rings && a.outcome != .Not_Loaded && a.hi > a.lo {
		lo = min(lo, a.lo)
	}
	return lo
}

// Readies `f`, which read a value, to read another with the same path and options, keeping its levels and room. The
// rings go back to the room, and the block they grew into is freed. Not for a finder whose levels are allocated, which
// is started again, so that each value pays for them as a read of it alone does.
finder_reset :: proc(f: ^Finder, room: ^Find_Room) {
	if f.ring_block != nil {
		runtime.mem_free_with_size(raw_data(f.ring_block), len(f.ring_block), f.allocator)
		f.ring_block, f.answers, f.answers_cap = nil, raw_data(room.answers[:]), FIND_ROOM
	}
	f.answer, f.want, f.keyed = FIND_NONE, true, false
	f.entered, f.replacers, f.ring_top = 0, 0, 0
	f.pending, f.ringing, f.skip_end, f.replay, f.replaying, f.settled, f.refused = false, false, false, false, false, false, false
	f.keys, f.named, f.quiet, f.count_at = false, false, false, nil
}

// Frees what `finder_start` and the growth of its rings allocated.
finder_end :: proc(f: ^Finder) {
	if f.block != nil {
		runtime.mem_free_with_size(raw_data(f.block), len(f.block), f.allocator)
	}
	if f.ring_block != nil {
		runtime.mem_free_with_size(raw_data(f.ring_block), len(f.ring_block), f.allocator)
	}
}

// Passes a fact, a key the open container cannot take, or a scalar no step looks at, with a compare or two and no
// call. Any other token goes to `finder_token`.
finder_hook :: #force_inline proc "contextless" (h: ^Finder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return finder_hook_as(h, s, t, false)
}

// `finder_hook`, which with `NAMES` also takes a raw key of at most sixteen bytes that the open container's `Name` step
// names, and the value after it, as `finder_keyed` and the close of a `Name` level do, with no call.
@(private)
finder_hook_as :: #force_inline proc "contextless" (h: ^Finder, s: hook.Regs, t: tape.Token, $NAMES: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	// A fact moves no step.
	if t.role > .Key {
		return s, .Next
	}
	if t.role == .Key {
		if !h.keys {
			return s, .Next
		}
		if h.named && t.kind != .Number {
			if t.spelling & tape.SPELLING_DECODE == 0 {
				if int(t.n) != len(h.key) {
					return s, .Next
				}
				// Reject a raw key whose bytes differ here, so a key shorter than a word needs no call into `finder_key`.
				// These are the word loads `tape.key_names` would do. A key that matches, and is longer than the two words,
				// still falls through, where `finder_key` checks it whole. Escaped keys keep that path.
				n := int(t.n)
				exact := false
				if n >= 8 {
					at := raw_data(h.key_text)[t.lo:]
					head := intrinsics.unaligned_load((^u64)(at))
					tail := intrinsics.unaligned_load((^u64)(at[n - 8:]))
					if head != h.key_head || tail != h.key_tail {
						return s, .Next
					}
					exact = n <= 2 * size_of(u64) // the two words cover every byte of such a key
				} else {
					a, b := raw_data(h.key_text[t.lo:]), raw_data(h.key)
					same := false
					switch {
					case n >= 4:
						same = intrinsics.unaligned_load((^u32)(a)) == intrinsics.unaligned_load((^u32)(b)) && intrinsics.unaligned_load((^u32)(a[n - 4:])) == intrinsics.unaligned_load((^u32)(b[n - 4:]))
					case n >= 2:
						same = intrinsics.unaligned_load((^u16)(a)) == intrinsics.unaligned_load((^u16)(b)) && a[n - 1] == b[n - 1]
					case:
						same = n == 0 || a[0] == b[0]
					}
					if !same {
						return s, .Next
					}
					exact = true
				}
				when NAMES {
					if exact {
						// The member is taken here, as `finder_key` would take it, and the value after it is `finder_keyed`'s.
						h.levels[h.entered - 1].chosen, h.want, h.answer, h.keyed = true, true, FIND_NONE, true
						h.keys, h.named, h.quiet, h.count_at = false, false, false, nil
						return s, .Next
					}
				}
			} else if t.spelling & tape.SPELLING_CREDIT_EXACT != 0 {
				// An escaped key's source span is longer than its text. One subtract turns it into the decoded
				// length, so a key of a different length needs no decode.
				if int(t.n) - int(tape.spelling_credit(t.spelling)) != len(h.key) {
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
	} else if t.role == .Value && t.kind != .End && h.count_at != nil && h.count_at^ != h.count_to && !h.quiet && !h.replay {
		// A container before the index the path takes is counted and skipped as a scalar there is counted.
		h.count_at^ += 1
		h.skip_end = true
		return s, .Skip
	}
	return s, finder_token(h, t, NAMES)
}

// `finder_hook` for a walk that passes the value of a member at its key when the hook answers `Skip` there, so a member
// the path does not take gives neither its tokens nor its `End`. A level that counts its members, as the elements of an
// `All` or the members of an object under an `All`, still has them given, for the count.
finder_key_skip_hook :: #force_inline proc "contextless" (h: ^Finder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role != .Key {
		return finder_hook_as(h, s, t, true)
	}
	// A level the finder takes no key at, or whose step is a `Name`, counts none of its members.
	passes := !h.keys || h.named
	r, a := finder_hook_as(h, s, t, true)
	return r, .Skip if a == .Next && passes && !h.want else a
}

// Sets the fields `finder_hook` reads, for the tokens up to the next one the finder must look at. A container the
// finder skipped gives only its `End` meanwhile, which the hook passes without a call unless it closes the answer.
@(private)
finder_focus :: #force_inline proc "contextless" (h: ^Finder) #no_bounds_check {
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
		if finder_names(h, lv, none) {
			h.keys, h.named, h.key = true, true, string(step)
			if len(step) >= 8 {
				h.key_head = intrinsics.unaligned_load((^u64)(raw_data(step)))
				h.key_tail = intrinsics.unaligned_load((^u64)(raw_data(step)[len(step) - 8:]))
			}
		}
	case tape.All:
		h.keys, h.quiet = none, !none
		if !tape.all_takes(step.limit, lv.count, lv.object, h.dups) {
			h.keys, h.quiet = false, true
		}
	case tape.Index:
		h.quiet = step >= 0 && lv.chosen
		if step >= 0 && !lv.chosen {
			h.count_at, h.count_to = &lv.count, u64(step)
		}
	case tape.Slice:
		if lv.size > 0 {
			h.quiet = lv.cut
		} else if h.quiet = !none || lv.count >= tape.slice_cut(step); !h.quiet && step.lo > 0 && lv.count < u64(step.lo) {
			h.count_at, h.count_to = &lv.count, u64(step.lo)
		}
	case tape.Descend:
	}
}

// Whether the `Name` of level `lv` may take a member. `none` is true while the value taken last has given no answer.
// Under `.Last` it takes every member of the key, under `.First` the first, and under `.Group` each until one gives
// an answer.
@(private)
finder_names :: #force_inline proc "contextless" (h: ^Finder, lv: ^Find_Level, none: bool) -> bool {
	return none if h.group else !lv.chosen || !h.first
}

@(private)
finder_token :: #force_inline proc "contextless" (h: ^Finder, t: tape.Token, $NAMES: bool) -> hook.Action {
	a: hook.Action
	when NAMES {
		a = finder_keyed(h, t) if h.keyed else finder_step(h, t, true)
	} else {
		a = finder_step(h, t, false)
	}
	finder_focus(h)
	return a
}

// The value of a key `finder_hook` took by a `Name` step. One that opens the object the next `Name` step goes through, or
// reaches the end of the path, is passed here with no call, and any other goes to `finder_value`.
@(private)
finder_keyed :: #force_inline proc "contextless" (h: ^Finder, t: tape.Token) -> hook.Action #no_bounds_check {
	h.keyed = false
	at := h.entered
	if at == len(h.steps) {
		h.want = false
		return finder_reach(h, t, .Found)
	} else if _, name := h.steps[at].(tape.Name); name && t.kind == .Object {
		h.want = false
		h.opens[at] = t.lo
		h.levels[at] = {ring = h.ring_top, object = true}
		h.replacers += int(h.dups == .Last)
		h.entered += 1
		return .Next
	}
	return finder_step(h, t, true)
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
finder_step :: #force_inline proc "contextless" (h: ^Finder, t: tape.Token, $NAMES: bool) -> hook.Action #no_bounds_check {
	if t.role > .Key {
		return .Next
	}
	if h.skip_end {
		h.skip_end = false
		if h.ringing {
			h.pending, h.ringing = false, false
			h.held.hi = t.lo + u64(t.n)
			return .Next if finder_ring_put(h, &h.levels[h.entered - 1], h.held) else .Stop
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
		when NAMES {
			// The close of an object a `Name` step went through, one of whose members was taken, as `finder_close` sets it.
			if lv := &h.levels[h.entered - 1]; lv.chosen {
				if _, name := h.steps[h.entered - 1].(tape.Name); name {
					h.entered -= 1
					h.ring_top = lv.ring
					h.replacers -= int(h.dups == .Last)
					if h.answer.outcome == .Not_Loaded && finder_spent(h) {
						h.answer = {outcome = .Missing}
					}
					return finder_settle(h)
				}
			}
		}
		return finder_close(h, t)
	}
	if t.role == .Key {
		return finder_key(h, t)
	}
	return finder_value(h, t)
}

// The answer is final once there is one and no open container on the path can replace it. Then the walk stops, or,
// without `stop_early`, judges the rest of the text from the next container on without calling the hook.
@(private)
finder_settle :: #force_inline proc "contextless" (h: ^Finder) -> hook.Action {
	if h.replacers > 0 || h.answer.outcome == .Not_Loaded {
		return .Next
	}
	h.settled = true
	return .Stop if h.stop else .Next
}

// Takes the next value as the one the path continues through. It has given no answer yet.
@(private)
finder_take :: #force_inline proc "contextless" (h: ^Finder, lv: ^Find_Level) {
	lv.chosen, h.want, h.answer = true, true, FIND_NONE
}

@(private)
finder_value :: proc "contextless" (h: ^Finder, t: tape.Token) -> hook.Action #no_bounds_check {
	if h.entered > 0 {
		lv := &h.levels[h.entered - 1]
		#partial switch step in h.steps[h.entered - 1] {
		case tape.Index:
			if h.replay {
				h.replay = false
				break
			}
			lv.count += 1
			// The first `FIND_WALK_IN` elements of an array are read as they pass, whose answer a replay would read
			// again. Past those, an element is passed whole and the one picked is read again at the close.
			if lv.replays && !h.replaying && lv.count > FIND_WALK_IN {
				// The last element read as it passed keeps its answer in the ring, as each one after it keeps its span.
				if step < -1 && lv.count == FIND_WALK_IN + 1 && !finder_ring_put(h, lv, h.answer) {
					return .Stop
				}
				return finder_pass(h, lv, t)
			}
			if step < 0 {
				if step < -1 && lv.count > 1 && !finder_ring_put(h, lv, h.answer) {
					return .Stop
				}
				finder_take(h, lv)
			} else if !lv.chosen && lv.count - 1 == u64(step) {
				finder_take(h, lv)
			}
		case tape.All:
			// An element is taken while those before it gave no answer, so `[]` of an empty array gives none.
			lv.count += 1
			if h.answer.outcome == .Not_Loaded && tape.all_takes(step.limit, lv.count - 1, lv.object, h.dups) {
				finder_take(h, lv)
			}
		case tape.Slice:
			if h.replay {
				h.replay = false
				break
			}
			lv.count += 1
			if lv.replays && !h.replaying {
				return finder_pass(h, lv, t)
			}
			if lv.size > 0 {
				if a := finder_slice_element(h, lv, step, lv.count - 1); a != .Next {
					return a
				}
			} else if h.answer.outcome == .Not_Loaded && tape.slice_takes(step, lv.count - 1, 0) {
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
	if step := h.steps[at]; tape.step_enters(step, t.kind) {
		ring := u32(finder_ring_size(h.steps, at, len(h.src) if h.rewalk != nil else max(int), h.rewalks))
		return finder_enter(h, tape.step_replaces(step, h.dups), t, ring, tape.step_replays(h.steps, at, h.rewalks))
	}
	if t.kind == .Null && tape.path_refused(u64(at), u64(h.alls_end)) == .Missing {
		h.answer = {outcome = .Missing}
		return finder_settle(h)
	}
	return finder_reach(h, t, .Wrong_Kind)
}

// Passes element `t` of the replaying array `lv` whole, kept as a span in its ring. The path goes on through only the
// elements the array picks at its close, which are read again.
@(private)
finder_pass :: #force_inline proc "contextless" (h: ^Finder, lv: ^Find_Level, t: tape.Token) -> hook.Action {
	head, tail: u8
	if t.kind <= .Plain {
		head, tail = h.bounds(h.src, t)
	}
	span := tape.Span_Answer{lo = t.lo - u64(head), hi = t.lo + u64(t.n) + u64(tail), kind = t.kind, head = head, tail = tail}
	if t.kind == .Array || t.kind == .Object {
		h.held, h.skip_end, h.pending, h.ringing = span, true, true, true
		return .Skip
	}
	return .Next if finder_ring_put(h, lv, span) else .Stop
}

// Takes the value of `t` as the answer, for a container at its `End`.
@(private)
finder_reach :: #force_inline proc "contextless" (h: ^Finder, t: tape.Token, outcome: tape.Presence) -> hook.Action {
	if t.kind == .Array || t.kind == .Object {
		h.answer = {lo = t.lo, kind = t.kind, outcome = outcome, spelling = t.spelling}
		h.pending, h.skip_end = true, true
		return .Skip
	}
	head, tail := h.bounds(h.src, t)
	h.answer = {lo = t.lo - u64(head), hi = t.lo + u64(t.n) + u64(tail), kind = t.kind, outcome = outcome, spelling = t.spelling, head = head, tail = tail}
	return finder_settle(h)
}

// Enters the container `t` opens, with a ring of `ring` entries.
@(private)
finder_enter :: #force_inline proc "contextless" (h: ^Finder, replaces: bool, t: tape.Token, ring: u32, replays: bool) -> hook.Action {
	// A ring that does not fit what is left of `answers` starts with at most `FIND_RING_START` entries and grows as its
	// array passes elements.
	have := ring
	if u64(h.ring_top) + u64(ring) > u64(h.answers_cap) {
		have = min(ring, FIND_RING_START)
		if !finder_answers_reserve(h, h.ring_top + have) {
			return .Stop
		}
	}
	h.opens[h.entered] = t.lo
	h.levels[h.entered] = {ring = h.ring_top, size = ring, have = have, replays = replays, object = t.kind == .Object}
	h.ring_top += have
	h.replacers += int(replaces)
	h.entered += 1
	return .Next
}

@(private)
finder_key :: proc "contextless" (h: ^Finder, t: tape.Token) -> hook.Action #no_bounds_check {
	lv := &h.levels[h.entered - 1]
	#partial switch step in h.steps[h.entered - 1] {
	case tape.Name:
		if finder_names(h, lv, h.answer.outcome == .Not_Loaded) && tape.key_names(h.format, h.key_text, t, string(step)) {
			finder_take(h, lv)
		}
	case tape.All:
		if h.answer.outcome == .Not_Loaded && tape.all_takes(step.limit, lv.count, true, h.dups) {
			finder_take(h, lv)
		}
	}
	// A member not taken has its value skipped when it is a container and ignored when it is a scalar.
	return .Next
}

// The entries a ring starts with when it does not fit in `answers`.
@(private)
FIND_RING_START :: 8

// The first elements of an array that a find reads as they pass. Only an element picked at index `FIND_WALK_IN` or
// later is read again by a replay.
@(private)
FIND_WALK_IN :: 8

// Sets the answer of the container on the path at its `End` `t`: the one its taken child gave, or why none was taken.
@(private)
finder_close :: proc "contextless" (h: ^Finder, t: tape.Token) -> hook.Action #no_bounds_check {
	// Only one array is read again at a time, so a replay holds at most one more walk and reads each element once more.
	if picked := &h.levels[h.entered - 1]; picked.replays && !h.replaying {
		#partial switch step in h.steps[h.entered - 1] {
		case tape.Index:
			if picked.count >= u64(-step) {
				picked.chosen = true
				e := picked.count - u64(-step)
				if e < FIND_WALK_IN {
					// The picked element was read as it passed. The last element's answer is in hand, an earlier
					// one's is in the ring.
					if e + 1 < picked.count {
						h.answer = h.answers[picked.ring + u32(e % u64(picked.size))]
					}
				} else if !finder_replay(h, picked.slot) {
					return .Stop
				}
			}
		case tape.Slice:
			// The first of the elements the slice takes that gives an answer is the slice's.
			k, count := u64(picked.size), picked.count
			for e in max(count, k) - k ..< count {
				if tape.slice_takes(step, e, count) {
					if !finder_replay(h, e % k) {
						return .Stop
					}
					if h.answer.outcome != .Not_Loaded {
						break
					}
				}
			}
		}
	}
	h.entered -= 1
	lv := &h.levels[h.entered]
	h.ring_top = lv.ring
	switch step in h.steps[h.entered] {
	case tape.Name:
		h.replacers -= int(tape.step_replaces(step, h.dups))
		if !lv.chosen {
			finder_miss(h, t, .Object)
		}
	case tape.Slice:
		if lv.replays {
			h.replacers -= 1
		} else if lv.size > 0 && !lv.cut {
			finder_slice_close(h, lv, step)
		}
	case tape.All, tape.Descend:
	case tape.Index:
		if step >= 0 {
			if !lv.chosen {
				finder_miss(h, t, .Array)
			}
		} else {
			h.replacers -= 1
			from_end := tape.step_reach(step)
			// The ring holds answers unless the element picked was read again.
			answers := h.replaying || !lv.replays
			if answers && from_end > 1 && lv.count > 0 && !finder_ring_put(h, lv, h.answer) {
				return .Stop
			}
			if _, in_array := tape.index_in(i64(step), lv.count); !in_array {
				finder_miss(h, t, .Array)
			} else if answers && from_end > 1 {
				h.answer = h.answers[lv.ring + u32(lv.slot)]
			}
		}
	}
	if h.answer.outcome == .Not_Loaded && finder_spent(h) {
		h.answer = {outcome = .Missing}
	}
	return finder_settle(h)
}

// Reads again the element of the open array whose span its ring holds at `slot`, as the one the path goes on through.
// False, with `h.refused` set, when the walk read again could not grow its stack.
@(private)
finder_replay :: proc "contextless" (h: ^Finder, slot: u64) -> bool #no_bounds_check {
	lv := &h.levels[h.entered - 1]
	h.want, h.replay, h.replaying, h.answer = true, true, true, FIND_NONE
	r := h.rewalk(h, h.answers[lv.ring + u32(slot)].lo)
	h.replaying = false
	if u8(r) == hook.WALK_NO_MEMORY {
		h.refused = true
		return false
	}
	return true
}

// Whether every container open on the path has taken the only child it can, by a key under `.First` or a position from
// the start, so that a path that has given no answer gives none.
@(private)
finder_spent :: proc "contextless" (h: ^Finder) -> bool #no_bounds_check {
	for i in 0 ..< h.entered {
		if !h.levels[i].chosen || !tape.step_takes_one(h.steps[i], h.dups) {
			return false
		}
	}

	return true
}

// Takes element `e` of level `lv`, a `Slice` with an end from the end. Its ring holds the answers of the last elements
// it may take, element `e` at entry `e % size`. `lv.slot` is that entry from element 1 on, and before the advance the
// entry of element `e - 1`. Under a `lo` from the start, an element whose answer is in the ring is in the slice once
// `size` more elements follow it, so the first such answer is final.
@(private)
finder_slice_element :: proc "contextless" (h: ^Finder, lv: ^Find_Level, step: tape.Slice, e: u64) -> hook.Action #no_bounds_check {
	if e > 0 {
		if tape.slice_takes(step, e - 1, 0) {
			h.answers[lv.ring + u32(lv.slot)] = h.answer
		}
		if !finder_ring_next(h, lv) {
			return .Stop
		}
	}
	k := u64(lv.size)
	if lv.cut {
		return .Next
	}
	if step.lo >= 0 && e >= k && tape.slice_takes(step, e - k, 0) {
		if a := h.answers[lv.ring + u32(lv.slot)]; a.outcome != .Not_Loaded {
			h.answer, lv.cut = a, true
			h.replacers -= 1
			return finder_settle(h)
		}
	}
	if tape.slice_takes(step, e, 0) {
		finder_take(h, lv)
	} else {
		h.answer = FIND_NONE
	}
	return .Next
}

// Sets the answer of level `lv`, a `Slice` with an end from the end, at its close: the answer of the first element the
// slice takes, now that its count is known, that gave one. An element the slice may take was kept when the next one
// arrived, as no count is known then, so the ring holds its entry.
@(private)
finder_slice_close :: proc "contextless" (h: ^Finder, lv: ^Find_Level, step: tape.Slice) #no_bounds_check {
	h.replacers -= 1
	k, count := u64(lv.size), lv.count
	if count > 0 && tape.slice_takes(step, count - 1, 0) {
		h.answers[lv.ring + u32(lv.slot)] = h.answer
	}
	h.answer = FIND_NONE
	for e in max(count, k) - k ..< count {
		if tape.slice_takes(step, e, count) {
			if a := h.answers[lv.ring + u32(e % k)]; a.outcome != .Not_Loaded {
				h.answer = a
				return
			}
		}
	}
}

// Sets the answer when the container `t` closes, the one `h.entered` indexes, without the member or element the step
// wants. The absent value reads as null, so when an `All` step comes later on the path the container is the value that
// cannot take the path (`.Wrong_Kind`), else the answer is `.Missing`.
@(private)
finder_miss :: #force_inline proc "contextless" (h: ^Finder, t: tape.Token, kind: tape.Kind) {
	if tape.path_refused(u64(h.entered + 1), u64(h.alls_end)) == .Wrong_Kind {

		h.answer = {lo = h.opens[h.entered], hi = t.lo + u64(t.n), kind = kind, outcome = .Wrong_Kind}
	} else {
		h.answer = {outcome = .Missing}
	}
}

// Keeps `entry`, the answer or the span of the element just passed, in the ring of `lv`, which holds the entries of the
// last `-step` elements. Returns whether the ring has room for the next, which it lacks only when growing it failed.
@(private)
finder_ring_put :: #force_inline proc "contextless" (h: ^Finder, lv: ^Find_Level, entry: tape.Span_Answer) -> bool #no_bounds_check {
	h.answers[lv.ring + u32(lv.slot)] = entry
	return finder_ring_next(h, lv)
}

// Advances `lv.slot`, the entry of the ring written next, by one. After the last entry of a full ring it goes to the
// first, otherwise into the space the ring grows into. Every entry below `slot` has space, so a write at `slot` or
// before needs no check. Returns whether the ring has the space, which it lacks only when growing it failed.
@(private)
finder_ring_next :: #force_inline proc "contextless" (h: ^Finder, lv: ^Find_Level) -> bool {
	next := lv.slot + 1
	next = 0 if next == u64(lv.size) else next
	if next == u64(lv.have) {
		return finder_ring_grow(h, lv)
	}
	lv.slot = next
	return true
}

// Doubles the entries of the ring of `lv`, at most to its `size`, and moves `slot` into the new entries. The level is
// the innermost with a ring, since every level inside it is closed when an element of its array passes, so its ring
// ends where the rings in use do and extends in place. Returns whether the space was obtained, else sets `h.refused`.
@(private, cold)
finder_ring_grow :: #force_no_inline proc "contextless" (h: ^Finder, lv: ^Find_Level) -> bool {
	have := u32(min(u64(lv.size), 2 * u64(lv.have)))
	if !finder_answers_reserve(h, lv.ring + have) {
		return false
	}
	lv.slot, lv.have, h.ring_top = u64(lv.have), have, lv.ring + have
	return true
}

// Gives `answers` space for `entries`: twice its current entries or more, by moving it to a larger block. Returns
// whether it has the space, else sets `h.refused`.
@(private, cold)
finder_answers_reserve :: #force_no_inline proc "contextless" (h: ^Finder, entries: u32) -> bool {
	if entries <= h.answers_cap {
		return true
	}
	context = h.ctx
	cap := min(max(2 * u64(h.answers_cap), u64(entries)), u64(max(u32)))
	bytes := int(cap) * size_of(tape.Span_Answer)
	block: []u8
	err: runtime.Allocator_Error
	if h.ring_block == nil {
		if block, err = runtime.mem_alloc_non_zeroed(bytes, align_of(tape.Span_Answer), h.allocator); err == nil {
			runtime.mem_copy_non_overlapping(raw_data(block), h.answers, int(h.ring_top) * size_of(tape.Span_Answer))
		}
	} else {
		block, err = runtime.non_zero_mem_resize(raw_data(h.ring_block), len(h.ring_block), bytes, align_of(tape.Span_Answer), h.allocator)
	}
	if err = took(err, raw_data(block), bytes); err != nil {
		h.refused = true
		return false
	}
	h.ring_block, h.answers, h.answers_cap = block, ([^]tape.Span_Answer)(raw_data(block)), u32(cap)
	return true
}

// Returns the ring entries the negative `Index` or `Slice` end of step `at` needs over a text of `n` bytes: one per
// element it reaches back to, but none for an `Index` of `-1` when it keeps answers, since the last element's is in
// hand at the close. An element takes at least one byte, so a ring of more than `n` entries holds nothing more.
@(private)
finder_ring_size :: #force_inline proc "contextless" (steps: []tape.Step, at: int, n: int, rewalks: bool) -> int {
	reach := tape.step_reach(steps[at])
	if _, index := steps[at].(tape.Index); index && reach == 1 && !tape.step_replays(steps, at, rewalks) {
		return 0
	}
	return int(min(reach, u64(n)))
}
