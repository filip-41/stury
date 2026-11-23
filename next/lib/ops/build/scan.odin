package build

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The hook of a scan: a `Builder` that keeps only what the paths of a demand reach. Its registers are the builder's.
// A container on the paths has a frame, which holds the demand nodes live in it. A value a path ends at is kept as its
// grain says (whole, as its keys and count, or as its node), and its steps are still followed when longer paths go on
// inside it.
Scanner :: struct {
	b:           Builder,
	demand:      ^tape.Demand,
	frames:      [dynamic]Scan_Frame, // the containers on the paths, the root's first, one per builder level
	// By level, the frame an element of the array at the level above opened with. The array's later elements of its
	// kind reopen with it. Valid while the array's `element` is not `End`.
	elements:    [dynamic]Scan_Frame,
	live:        [dynamic]u32, // the demand nodes live in the frames, each frame's from its `live`
	picks:       [dynamic]u32, // the demand nodes that took the coming value
	answers:     [dynamic]Scan_Answer,
	kept:        [dynamic]Scan_Kept,
	missing:     [dynamic]Scan_Missing,
	ring:        [dynamic]Scan_Ring, // what the scan held before each element a step from the end can still take
	tokens:      [dynamic]tape.Token, // the token of each element a replaying array's negative `Index` can still take
	rewalk:      Rewalk, // the proc that gives this hook the value at `lo` again
	walk:        rawptr, // the walk giving this hook its tokens, which `rewalk` reads in
	// For each demand edge whose key met a member of an object: in the high 32 bits the generation of the object's
	// frame, in the low 32 bits the number of answers made before it. A mark is valid only for the frame of its
	// generation.
	marks:       []u64,
	made:        []u32, // with a limited demand, the answers each path holds that no step took back
	// With `facts`, the comments before the next token start at `wait_from` in the builder's facts. They mark the node
	// `wait_at` that the token is stored at, unless the walk passes the token while that node is still the next one
	// written.
	wait_from:   int,
	wait_at:     tape.Node_Index,
	passed:      tape.Node_Index, // with `facts`, the node written next when the walk last passed a value
	facts:       bool, // `Demand.facts`
	opens:       u32, // the frames opened, so the last one's generation. A frame is a node, which keeps this from wrapping
	done:        []bool, // the paths settled, a bool per path, kept while `settles`
	pending:     int, // the paths not done
	key:         tape.Token, // with `has_key`, the key of the coming value
	has_key:     bool,
	by_place:    bool, // an `Index` picked the coming value, so it keeps a `Scan_Kept`
	forced:      bool, // the coming value is element `forced_at` of its array, read again with its picks made
	forced_at:   u64,
	replaying:   bool, // inside a `rewalk`, where every array keeps the elements its negative indexes may take
	end_of:      Scan_End, // what the next token is, when it is the `End` of a container
	dups:        tape.Duplicates, // the read's policy, resolved
	first:       bool, // under `.First` the first member of a repeated key answers
	group:       bool, // under `.Group` every member of a repeated key answers
	rewalks:     bool, // the format has `.Rewalk`, so an array whose elements only steps from the end take replays
	stop:        bool, // `stop_early`
	stopped:     bool,
	// Under `stop_early`, or a limit on a path or a step, the scan tracks its settled paths. Once all are, `stop_early`
	// ends the walk, and otherwise the scan keeps nothing more while the walk judges the rest of the text. A scan of
	// facts takes every token, as the comments past the last settled value may be a kept node's.
	settles:     bool,
	// `holds` is set for a scan of a text in pieces, which copies the bytes it keeps out of each window. `held` is the
	// spans, `bytes` their bytes, and `hold_from` the offset from which the walk's tokens are not held yet.
	holds:       bool,
	held:        [dynamic]tape.Held_Span,
	bytes:       [dynamic]u8,
	hold_from:   u64,
	held_live:   int, // the bytes held once the last `hold_drop` ran
	room:        ^Scan_Room,
	protocol:    hook.Protocol(SCANNER_CAPS, hook.Levels(scanner_levels_held, scanner_levels_grow), hook.Unused, hook.Keeps(Builder, scanner_builder, builder_keep_whole, builder_keep_stubs)),
}

SCANNER_CAPS :: hook.Capabilities{.Skips, .Levels, .Keeps, .Walk, .Credits}

// Which container's `End` is the next token, when this hook skipped it or kept it as a whole.
Scan_End :: enum u8 {
	None,
	Skipped, // a container this hook skipped
	Picked, // a container picks took, kept whole or stored as one node, its picks still in `picks`
	Settled, // every path is settled without `stop_early`, so no token is taken from here on
}

// The open stack of a scanner, which is its builder's, as `hook.Levels` reads it.
@(private)
scanner_levels_held :: #force_inline proc "contextless" (h: rawptr) -> int {
	return len((^Scanner)(h).b.stack)
}

@(private)
scanner_levels_grow :: #force_inline proc "contextless" (h: rawptr, want: int, _: ^hook.Regs, _: u64) -> bool {
	return builder_deepen(&(^Scanner)(h).b, want, nil, 0)
}

// The builder a scanner keeps containers with, as `hook.Keeps` reads it.
@(private)
scanner_builder :: #force_inline proc "contextless" (h: rawptr) -> rawptr {
	return &(^Scanner)(h).b
}

@(private)
builder_keep_whole :: #force_inline proc "contextless" (h: rawptr, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return builder_hook_kept((^Builder)(h), s, t)
}

@(private)
builder_keep_stubs :: #force_inline proc "contextless" (h: rawptr, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return builder_hook_stubs((^Builder)(h), s, t)
}

// Gives hook `h` the value at `lo` again from registers `s`. Returns the walk's result.
Rewalk :: #type proc "contextless" (h: ^Scanner, s: ^hook.Regs, lo: u64) -> hook.Walk_Result

// A container on the paths.
@(private)
Scan_Frame :: struct {
	count:   u64, // the children passed
	live:    u32, // its demand nodes in `Scanner.live`
	n_live:  u32,
	ring:    u32, // its entries in `Scanner.ring`, or in `Scanner.tokens` when it `replays`, `ring_k` of them
	ring_k:  u32,
	whole:   bool, // every child is kept, a path ending at the container or at one holding it
	object:  bool,
	passes:  bool, // an object whose members no step takes are passed
	alls:    bool, // an `All` takes any member, every child is kept, or every key is
	gen:     u32, // its generation, which the marks of its members carry
	lengths: u64, // a bit per length its `Name` steps have, past 63 counted from 0
	heads:   u64, // a bit per first byte its `Name` steps have, by the byte's low six bits
	// The number of steps its close still has to check because no child has met them: the `Name` steps of an object
	// that no member has met yet, or the `Index` steps of an array.
	unmet:   u32,
	// Its positional steps are all negative indexes, so each element is passed and the ones they take are read again at
	// its close.
	replays: bool,
	// Its positional steps are all from the end and the format cannot walk an element again, so each element they may
	// take is kept, and its nodes go once no step can take it.
	drops:   bool,
	// An object a path ends at with grain `.Keys`, so each member no step takes is kept with its value, a container
	// value as one unread node.
	keys:    bool,
	slices:  bool, // it has `Slice` steps, which pick past the ring's check in `scan_element`, so it has a ring
	// For an array with no positional steps, where each element picks the same demand nodes: the kind of the element
	// whose frame `Scanner.elements` holds at the level below, else `End`. An element of that kind reopens it.
	element: tape.Kind,
	// Elements `takes_from` up to `takes_to` are those every positional step of an array takes (a `Slice` from the
	// start or an `All` with a limit), and they pick the same demand nodes.
	takes_from:    u64,
	takes_to:      u64,
}

// An answer as the walk made it, its node as `tape.answer` gives it.
@(private)
Scan_Answer :: struct {
	node:    tape.Node_Index,
	path:    u32,
	pos:     u64, // twice the value's node index, or twice the close's less one for a miss the close found
	leaf:    u32, // the demand node the answer came from
	outcome: tape.Presence,
	dead:    bool, // a repeated key or a negative index took it back
}

// A child kept by its place in its container.
@(private)
Scan_Kept :: struct {
	node:  tape.Node_Index,
	index: u32,
}

@(private)
Scan_Missing :: struct {
	node: tape.Node_Index,
	name: string,
}

// What a scan held, as the lengths of its lists, when an element a ring keeps began. Taking the element back drops
// what the lists gained since.
@(private)
Scan_Ring :: struct {
	answers, node, kept, missing, counts, facts: u32,
}

// The room a scan's lists start in, on the caller's stack, so that a scan of few paths and answers allocates no list.
// A list that outgrows its part moves to the allocator, and a demand with more edges than `marks` holds, or more paths
// than `done` holds, allocates those too.
Scan_Room :: struct {
	frames:  [8]Scan_Frame,
	elements: [8]Scan_Frame,
	live:    [16]u32,
	picks:   [16]u32,
	answers: [16]Scan_Answer,
	kept:    [16]Scan_Kept,
	marks:   [32]u64,
	made:    [32]u32,
	done:    [32]bool,
}

// Sets up `h` as a scanner of `demand` over `src`, with `nodes`, `most` and `frames` as `builder_start` takes them.
// The node room grows as it fills. With no `rewalk` it reads each value once, keeping nodes where a replay would read a
// value again.
@(require_results)
scanner_start :: proc(h: ^Scanner, src: []u8, format: ^tape.Format, demand: ^tape.Demand, read: tape.Read_Options, rewalk: Rewalk, nodes, most: int, frames: []u64, room: ^Scan_Room, allocator: runtime.Allocator) -> (err: runtime.Allocator_Error) {
	h^ = {}
	builder_start(&h.b, src, format, nodes, most, frames, allocator)
	if h.b.err != nil {
		return h.b.err
	}
	defer if err != nil {
		scanner_free(h, allocator)
		delete(h.b.counts)
		tape.destroy(&h.b.doc)
		h^ = {}
	}
	h.demand, h.rewalk, h.rewalks = demand, rewalk, .Rewalk in format.caps && rewalk != nil
	h.dups = tape.read_dups(format, read.dups)
	h.first, h.group, h.stop, h.pending = h.dups == .First, h.dups == .Group, read.stop_early, len(demand.paths)
	h.settles = h.stop || !demand.facts && (demand.limited || scan_cuts(demand))
	h.b.keep_facts, h.facts, h.passed, h.wait_at = demand.facts, demand.facts, tape.NO_NODE, tape.NO_NODE
	h.room = room
	scan_room_list(&h.frames, room.frames[:], allocator)
	scan_room_list(&h.elements, room.elements[:], allocator)
	scan_room_list(&h.live, room.live[:], allocator)
	scan_room_list(&h.picks, room.picks[:], allocator)
	scan_room_list(&h.answers, room.answers[:], allocator)
	scan_room_list(&h.kept, room.kept[:], allocator)
	h.missing.allocator, h.ring.allocator, h.tokens.allocator = allocator, allocator, allocator
	h.held.allocator, h.bytes.allocator = allocator, allocator
	made := len(demand.paths) if demand.limited else 0
	if len(demand.edges) <= len(room.marks) && len(demand.paths) <= len(room.done) {
		h.marks, h.done = room.marks[:len(demand.edges)], room.done[:len(demand.paths)]
		if made > 0 {
			h.made = room.made[:made]
		}
	} else {
		// The marks, the answers made and the settled paths share one block.
		marks, counts := len(demand.edges) * size_of(u64), made * size_of(u32)
		block, merr := runtime.mem_alloc_non_zeroed(marks + counts + len(demand.paths), align_of(u64), allocator)
		if e := took(merr, raw_data(block), marks + counts + len(demand.paths)); e != nil {
			return e
		}
		h.marks = ([^]u64)(raw_data(block))[:len(demand.edges)]
		if made > 0 {
			h.made = ([^]u32)(raw_data(block[marks:]))[:made]
		}
		h.done = ([^]bool)(raw_data(block[marks + counts:]))[:len(demand.paths)]
	}
	// No frame has generation 0, so a zero mark is valid for none.
	runtime.mem_zero(raw_data(h.marks), len(h.marks) * size_of(u64))
	runtime.mem_zero(raw_data(h.made), len(h.made) * size_of(u32))
	runtime.mem_zero(raw_data(h.done), len(h.done))
	// Every pick of a value or key is of a distinct edge, or the root, so `picks` never grows past this.
	if !scan_reserve(h, &h.picks, len(demand.edges) + 1) {
		err = h.b.err
	}
	return
}

// Whether a step of `demand` has a limit, which settles its paths once the step takes no more.
@(private)
scan_cuts :: proc "contextless" (demand: ^tape.Demand) -> bool {
	for e in demand.edges {
		#partial switch step in e.step {
		case tape.All:
			if step.limit > 0 {
				return true
			}
		case tape.Slice:
			if step.limit > 0 {
				return true
			}
		}
	}
	return false
}

@(private)
scan_room_list :: proc(list: ^[dynamic]$T, room: []T, allocator: runtime.Allocator) {
	raw := (^runtime.Raw_Dynamic_Array)(list)
	raw^ = {data = raw_data(room), len = 0, cap = len(room), allocator = allocator}
}

// Whether `p` is in the room the scan's lists start in.
@(private)
scan_in_room :: #force_inline proc "contextless" (h: ^Scanner, p: rawptr) -> bool {
	at := uintptr(p) - uintptr(h.room)
	return at < size_of(Scan_Room)
}

// Takes a walk's token into the partial document.
scanner_hook :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	if t.role > .Key {
		if h.facts {
			return s, scan_fact(h, s, t)
		}
		return s, .Next
	}
	if h.end_of != .None {
		end := h.end_of
		if end == .Settled {
			return s, scan_rest(t)
		}
		h.end_of = .None
		if end == .Picked {
			return scan_past(h, s, h.picks[:], s.c)
		}
		return s, .Next
	}
	// A key that no `Name` of the open object can match is passed without further work. So is a member no step took.
	if t.role == .Key {
		f := &h.frames[len(h.frames) - 1]
		clear(&h.picks)
		if !f.alls && scan_key_unmatched(h, f, t) {
			return s, .Next
		}
		h.key, h.has_key, h.by_place = t, true, false
		// The scan's document keeps the key, and a document carries no credit.
		h.key.spelling = tape.without_credit(h.key.spelling)
		// A `Name` takes a key of any scalar kind by its text.
		if t.kind <= .Plain {
			scanner_key(h, t, true)
		} else {
			scanner_key(h, t, false)
		}
		return s, .Next
	}
	if t.kind == .End {
		return scanner_close(h, s, t)
	}
	if s.c > 0 && !h.forced {
		f := &h.frames[s.c - 1]
		if f.passes && len(h.picks) == 0 {
			f.count += 1
			return scan_pass(h, s, t)
		}
		if t.kind == f.element && f.count < f.takes_to {
			return scan_reopen(h, s, t, f)
		}
	}
	if t.kind <= .Plain {
		return scanner_value(h, s, t, true)
	}
	return scanner_value(h, s, t, false)
}

// Whether no `Name` of the object `f` can match key `t`, because none has its length or none has its first byte. A key
// that needs decoding is judged by its decoded length when its spelling holds an exact credit, otherwise never.
@(private)
scan_key_unmatched :: #force_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, t: tape.Token) -> bool #no_bounds_check {
	if t.spelling & tape.SPELLING_DECODE != 0 {
		if t.spelling & tape.SPELLING_CREDIT_EXACT == 0 {
			return false
		}
		d := u64(t.n) - u64(tape.spelling_credit(t.spelling))
		return f.lengths & (1 << (d & 63)) == 0
	}
	return f.lengths & (1 << (t.n & 63)) == 0 || t.n > 0 && f.heads & (1 << (h.b.doc.src[t.lo] & 63)) == 0
}

// Returns the partial document the walk built, or the error that ended it with everything freed. `regs` are the hook's
// registers at the walk's end and `root_close` is the end of the root value.
@(require_results)
scanner_end :: proc(h: ^Scanner, regs: hook.Regs, root_close: u64, err: tape.Error) -> (doc: tape.Document, e: tape.Error) {
	allocator := h.b.doc.allocator
	defer scanner_free(h, allocator)
	regs := regs
	e = err
	if e == nil {
		e = builder_error(&h.b)
	}
	if e == nil && (h.stopped || h.end_of == .Settled) {
		// The containers the stop left open are on the paths, their counts not known, as their ends were not read. A
		// replaying array stops only in its replay, with every element passed, so its count is known.
		for regs.c > 0 {
			f := h.frames[regs.c - 1]
			open := tape.Node_Index(regs.b >> 32)
			if !f.replays {
				f.count = 0
			}
			regs = scan_close_partial(h, regs, f)
			if !f.replays {
				h.b.doc.nodes[open].spelling = tape.CONTAINER_PARTIAL | tape.MAX_CHILDREN
			}
		}
	}
	if e == nil && len(h.b.doc.facts) > 0 {
		scan_check_facts(h, regs)
	}
	doc, e = builder_end(&h.b, regs, 0 if h.stopped else root_close, e)
	if e != nil {
		return
	}
	if h.stopped {
		doc.flags += {.Stopped}
	}
	if refused := scan_lists(h, &doc, h.answers[:], h.missing[:], h.made); refused != nil {
		tape.destroy(&doc)
		return {}, refused
	}
	if h.holds {
		doc.src = h.bytes[:]
		doc.flags += {.Held, .Owns_Src}
		h.bytes = {}
	}
	return
}

@(private)
scanner_key :: proc "contextless" (h: ^Scanner, t: tape.Token, $NAMED: bool) #no_bounds_check {
	f := &h.frames[len(h.frames) - 1]
	dm := h.demand
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for e in node.edges ..< node.edges + node.n_edges {
			edge := &dm.edges[e]
			#partial switch step in edge.step {
			case tape.Name:
				if !NAMED || !tape.key_names(h.b.doc.format, h.b.doc.src, t, string(step)) {
					continue
				}
				mark := h.marks[e]
				if u32(mark >> 32) != f.gen {
					f.unmet -= 1
				} else if h.first {
					continue
				} else if !h.group {
					scan_kill(h, int(u32(mark)), len(h.answers), edge.to)
				}
				h.marks[e] = u64(f.gen) << 32 | u64(len(h.answers))
				scan_put(&h.picks, edge.to)
			case tape.All:
				if tape.all_takes(step.limit, f.count, true, h.dups) {
					scan_put(&h.picks, edge.to)
				}
			}
		}
	}
}

@(private)
scanner_value :: proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, $scalar: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	d := s.c
	index: u64
	whole := false
	if h.forced {
		h.forced = false
		index = h.forced_at
	} else if d == 0 {
		clear(&h.picks)
		h.by_place = false
		if len(h.demand.paths) > 0 {
			scan_put(&h.picks, 0)
		} else if h.stop {
			h.stopped = true
			return s, .Stop
		}
	} else {
		f := &h.frames[d - 1]
		index = f.count
		f.count += 1
		whole = f.whole
		if !f.object {
			ok: bool
			if s, ok = scan_element(h, s, f, index, t, d); !ok {
				return s, scan_halt(h, t)
			}
		} else if f.keys && len(h.picks) == 0 {
			return scan_stub(h, s, t)
		}
	}
	if len(h.picks) == 0 && !whole {
		return scan_pass(h, s, t)
	}
	owner := tape.Node_Index(s.b >> 32)
	if h.has_key {
		s, _ = builder_step(&h.b, s, h.key, false, true)
		h.has_key = false
	}
	at := builder_cursor(&h.b, s)
	if h.by_place {
		scan_push(h, &h.kept, Scan_Kept{at, u32(index)})
	}
	dm := h.demand
	live := u32(len(h.live))
	answered := len(h.answers)
	ends, stubs := false, false
	for n in h.picks {
		node := dm.nodes[n]
		for p in dm.ends[node.ends:][:node.n_ends] {
			scan_answer(h, at, p, .Found, 2 * u64(at), n)
		}
		ends ||= node.whole
		stubs ||= node.keys
		when scalar {
			// No step enters a scalar.
			for edge in dm.edges[node.edges:][:node.n_edges] {
				scan_fail(h, edge.to, t.kind == .Null, d, at, owner, 2 * u64(at))
			}
		} else {
			enters := false
			for edge in dm.edges[node.edges:][:node.n_edges] {
				if tape.step_enters(edge.step, t.kind) {
					enters = true
				} else {
					scan_fail(h, edge.to, false, d, at, owner, 2 * u64(at))
				}
			}
			// An array a `.Keys` grain keeps has a frame that counts its elements.
			if enters || node.keys && t.kind == .Array {
				scan_push(h, &h.live, n)
			}
		}
	}
	when scalar {
		s, _ = builder_step(&h.b, s, t, false, true)
		return scan_past(h, s, h.picks[:], d)
	}
	if u32(len(h.live)) > live {
		s, _ = builder_step(&h.b, s, t, false, true)
		scan_open(h, t, live, whole || ends)
		if d > 0 && h.b.err == nil {
			scan_keep_element(h, d, t.kind, len(h.answers) == answered)
		}
		return s, .Stop if h.b.err != nil else .Next
	}
	if h.b.err != nil {
		return s, .Stop
	}
	// Kept whole: a value a path ends at, and a child of a container kept whole. An object a `.Keys` grain keeps is
	// kept as its members, with each container value as one node. A container no step could enter is stored as one
	// node. The hook is called next at its `End`, so `picks` holds until then.
	h.end_of = .Picked
	if whole || ends {
		return s, .Keep
	}
	if stubs && t.kind == .Object {
		h.b.stubs = d + 1
		return s, .Keep_Stubs
	}
	ok: bool
	if s, ok = builder_unread(&h.b, s, t); !ok {
		return s, .Stop
	}
	return s, .Skip
}

// Keeps a member no path takes of an object a `.Keys` grain keeps: its key, and its value `t`, a container as one
// unread node.
@(private)
scan_stub :: proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.has_key = false
	kept, action := builder_step(&h.b, s, h.key, false, true)
	if action == .Stop {
		return kept, .Stop
	}
	if t.kind <= .Plain {
		return builder_step(&h.b, kept, t, false, true)
	}
	ok: bool
	if kept, ok = builder_unread(&h.b, kept, t); !ok {
		return kept, .Stop
	}
	h.end_of = .Skipped
	return kept, .Skip
}

// Opens again the frame the first element of the array `f` opened with, for element `t` of the same kind. Past the
// elements its positional steps all take, the next element picks again.
@(private)
scan_reopen :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, f: ^Scan_Frame) -> (hook.Regs, hook.Action) #no_bounds_check {
	d := s.c
	f.count += 1
	if f.count >= f.takes_to {
		f.element = .End
	}
	live := f.live + f.n_live
	opened, action := builder_step(&h.b, s, t, false, true)
	if action == .Stop {
		return opened, .Stop
	}
	g := h.elements[d]
	h.opens += 1
	g.gen, g.live = h.opens, live
	scan_push(h, &h.frames, g)
	if h.b.err != nil {
		return opened, .Stop
	}
	// The element's live demand nodes are those it opened with, past the array's. No frame writes over them between one
	// element of the array and the next, since no other frame opens at its level.
	(^runtime.Raw_Dynamic_Array)(&h.live).len = int(live + g.n_live)
	return opened, .Next
}

// Records in the array at depth `d` the frame its element of `kind` just opened, for later elements of that kind to
// reopen with. It does so only when the element made no answer and while the elements are those every positional step
// of the array takes.
@(private)
scan_keep_element :: #force_inline proc "contextless" (h: ^Scanner, d: u64, kind: tape.Kind, reopens: bool) #no_bounds_check {
	f := &h.frames[d - 1]
	// An `Index` picks one element, and a ring keeps an entry per element.
	if f.object || f.unmet != 0 || f.ring_k != 0 {
		return
	}
	in_takes := f.count - 1 >= f.takes_from && f.count < f.takes_to
	f.element = .End
	// A reopened element skips `scanner_value`, which lists the kept elements of a partial array.
	if !reopens || !in_takes || h.by_place {
		return
	}
	elements := (^runtime.Raw_Dynamic_Array)(&h.elements)
	if elements.len <= int(d) {
		if !scan_reserve(h, &h.elements, int(d) + 1 - elements.len) {
			return
		}
		elements.len = int(d) + 1
	}
	h.elements[d] = h.frames[d]
	h.frames[d - 1].element = kind
}

// Passes a value no step took. A container is skipped, giving no more tokens up to its `End`.
@(private)
scan_pass :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.has_key = false
	if h.facts {
		if h.passed = builder_cursor(&h.b, s); h.passed == h.wait_at {
			scan_unwait(h)
		}
	}

	if t.kind > .Plain {
		h.end_of = .Skipped
		return s, .Skip
	}
	return s, .Next
}

// Takes the demand nodes that pick element `index`, whose token is `t`, of the array `f` at depth `d`. Returns whether
// the walk goes on, which a refused growth or a stop at a cut ends.
@(private)
scan_element :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, f: ^Scan_Frame, index: u64, t: tape.Token, d: u64) -> (hook.Regs, bool) #no_bounds_check {
	s := s
	dm := h.demand
	clear(&h.picks)
	h.by_place = false
	// A replaying array's steps are all from the end, and pick at its close.
	live := h.live[f.live:][:f.n_live] if !f.replays else nil
	for n in live {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			#partial switch step in edge.step {
			case tape.Index:
				// Every element a negative index may take is kept, and the answers of those it does not take go, unless
				// the array replays the ones it takes.
				if step < 0 && !f.replays || u64(step) == index {
					scan_put(&h.picks, edge.to)
					h.by_place = true
				}
			case tape.All:
				if step.limit <= 0 || index < u64(step.limit) {
					scan_put(&h.picks, edge.to)
					// A limit leaves the array partial, so each element it keeps holds its place.
					h.by_place ||= step.limit > 0
				} else if h.settles && index == u64(step.limit) && !scan_cut(h, edge.to, d) {
					return s, false
				}
			case tape.Slice:
				// A slice from the end picks past the ring's check.
				if tape.step_reach(step) == 0 && !scan_slice_pick(h, step, index, edge.to, d) {
					return s, false
				}
			}
		}
	}
	if f.ring_k == 0 {
		return s, true
	}
	// The ring is at the end of its list while the elements arrive, because an inner frame's close cuts the list back,
	// so it grows with the elements up to its size.
	k := u64(f.ring_k)
	slot := f.ring + u32(index % k)
	if f.replays {
		if index >= k {
			h.tokens[slot] = t
			return s, true
		}
		scan_push(h, &h.tokens, t)
		return s, h.b.err == nil
	}
	// Slices from the end pick here, except in a replaying array, whose slices are all from the end and pick at its
	// close.
	if f.slices && !scan_slice_picks(h, f, index, d) {
		return s, false
	}
	if index < k {
		scan_push(h, &h.ring, scan_ring_mark(h, s))
		return s, h.b.err == nil
	}
	// Element `index - k` passes out of the ring, so no negative index takes it.
	next := h.ring[f.ring + u32((index + 1) % k)]
	hi := len(h.answers) if k == 1 else int(next.answers)
	scan_kill_negatives(h, f, int(h.ring[slot].answers), hi, max(u64))
	if f.drops {
		s = scan_drop(h, s, f, h.ring[slot], builder_cursor(&h.b, s) if k == 1 else tape.Node_Index(next.node))
	}
	h.ring[slot] = scan_ring_mark(h, s)
	return s, true
}

@(private)
scan_ring_mark :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs) -> Scan_Ring {
	return {u32(len(h.answers)), u32(builder_cursor(&h.b, s)), u32(len(h.kept)), u32(len(h.missing)), u32(len(h.b.counts)), u32(len(h.b.doc.facts))}
}

// Drops the element of the array `f` whose nodes run from `from.node` to `hi`, and what the scan holds of them, from
// the list lengths `from` records. The nodes past them move down, with every entry that names one, and so do the ring
// entries of the array's later elements.
@(private, cold)
scan_drop :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, f: ^Scan_Frame, from: Scan_Ring, hi: tape.Node_Index) -> hook.Regs #no_bounds_check {
	s := s
	lo := tape.Node_Index(from.node)
	gone := hi - lo
	// An element no step picked was not stored.
	if gone == 0 {
		return s
	}
	end := builder_cursor(&h.b, s)
	copy(h.b.doc.nodes[lo:], h.b.doc.nodes[hi:end])
	s.a -= u64(gone) * size_of(tape.Node)
	s.b -= 1
	// Whether the node `at` names stays. Moves it down past the nodes that go.
	moved :: #force_inline proc "contextless" (at: ^tape.Node_Index, lo, hi: tape.Node_Index) -> bool {
		if at^ == tape.NO_NODE || at^ < lo {
			return true
		}
		if at^ < hi {
			return false
		}
		at^ -= hi - lo
		return true
	}

	for &a in h.answers[from.answers:] {
		if a.pos >= 2 * u64(hi) {
			a.pos -= 2 * u64(gone)
		} else if a.pos >= 2 * u64(lo) && !a.dead {
			a.dead = true
			if h.made != nil {
				h.made[a.path] -= 1
			}
		}
		if a.node >= hi {
			a.node -= gone
		}
	}
	kept, missing, counts := int(from.kept), int(from.missing), int(from.counts)
	for k in h.kept[from.kept:] {
		k := k
		if moved(&k.node, lo, hi) {
			h.kept[kept] = k
			kept += 1
		}
	}
	for m in h.missing[from.missing:] {
		m := m
		if moved(&m.node, lo, hi) {
			h.missing[missing] = m
			missing += 1
		}
	}
	for c in h.b.counts[from.counts:] {
		c := c
		if moved(&c.node, lo, hi) {
			h.b.counts[counts] = c
			counts += 1
		}
	}
	gone_kept, gone_missing, gone_counts := u32(len(h.kept) - kept), u32(len(h.missing) - missing), u32(len(h.b.counts) - counts)
	(^runtime.Raw_Dynamic_Array)(&h.kept).len = kept
	(^runtime.Raw_Dynamic_Array)(&h.missing).len = missing
	(^runtime.Raw_Dynamic_Array)(&h.b.counts).len = counts
	for &fact in h.b.doc.facts[from.facts:] {
		if !moved(&fact.node, lo, hi) {
			fact.node = tape.NO_NODE
		}
	}
	if !moved(&h.b.closed, lo, hi) {
		h.b.closed = tape.NO_NODE
	}
	if !moved(&h.passed, lo, hi) {
		h.passed = tape.NO_NODE
	}
	if !moved(&h.wait_at, lo, hi) {
		h.wait_at = tape.NO_NODE
	}
	for &r in h.ring[f.ring:] {
		if r.node >= u32(hi) {
			r.node -= u32(gone)
			r.kept -= gone_kept
			r.missing -= gone_missing
			r.counts -= gone_counts
		}
	}
	scan_shed(h, int(from.answers))
	return s
}

// Removes the answers taken back from the list from `from` on, so an array whose elements go as its ring passes them
// holds only the answers of the elements its ring keeps. A ring entry or mark past a removed answer stops counting it.
@(private)
scan_shed :: proc "contextless" (h: ^Scanner, from: int) #no_bounds_check {
	answers := h.answers[:]
	dead_before :: proc "contextless" (answers: []Scan_Answer, from, at: int) -> (n: u32) #no_bounds_check {
		for a in answers[from:at] {
			n += u32(a.dead)
		}
		return
	}
	if dead_before(answers, from, len(answers)) == 0 {
		return
	}
	for &r in h.ring {
		if int(r.answers) > from {
			r.answers -= dead_before(answers, from, int(r.answers))
		}
	}
	for &m in h.marks {
		if at := int(u32(m)); at > from {
			m -= u64(dead_before(answers, from, at))
		}
	}
	n := from
	for a in answers[from:] {
		if !a.dead {
			answers[n] = a
			n += 1
		}
	}
	(^runtime.Raw_Dynamic_Array)(&h.answers).len = n
}

// Whether a step from the end of the array `f`, which has `f.count` elements, takes element `e`.
@(private)
scan_ring_takes :: proc "contextless" (h: ^Scanner, f: ^Scan_Frame, e: u64) -> bool #no_bounds_check {
	dm := h.demand
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			#partial switch step in edge.step {
			case tape.Index:
				if at, in_array := tape.index_in(i64(step), f.count); in_array && at == e {
					return true
				}
			case tape.Slice:
				if tape.slice_takes(step, e, f.count) {
					return true
				}
			}
		}
	}
	return false
}

// Takes the demand nodes the `Slice` steps from the end of the array `f` at depth `d` pick for element `index`.
@(private)
scan_slice_picks :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, index: u64, d: u64) -> bool #no_bounds_check {
	dm := h.demand
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			if step, ok := edge.step.(tape.Slice); ok && tape.step_reach(step) > 0 && !scan_slice_pick(h, step, index, edge.to, d) {
				return false
			}
		}
	}
	return true
}

// Takes the demand node `to` for element `index` when `step` may take it, before its array's count is known. Past
// the last element it can take, under `settles`, the paths through it that settle there are done. Returns whether the
// walk goes on.
@(private)
scan_slice_pick :: #force_inline proc "contextless" (h: ^Scanner, step: tape.Slice, index: u64, to: u32, d: u64) -> bool {
	if tape.slice_takes(step, index, 0) {
		scan_put(&h.picks, to)
		h.by_place = true
		return true
	}
	return !h.settles || index != tape.slice_cut(step) || scan_cut(h, to, d)
}

// Settles, under `settles`, the paths through demand node `to` that a positional step at depth `d` takes no more
// elements for. Returns whether the scan takes more tokens.
@(private, cold)
scan_cut :: #force_no_inline proc "contextless" (h: ^Scanner, to: u32, d: u64) -> bool {
	if d - 1 <= h.demand.reach {
		scan_settle(h, to, d - 1)
		if h.pending == 0 {
			scan_settled(h)
			return false
		}
	}
	return true
}

// Gives each path ending under demand node `to` its failure at the value at `at`, which its step at depth `d` cannot
// enter. With `null` the value is `null` or missing, read as `Missing` past the path's last `All` and as `Wrong_Kind`
// before it. Every other value is `Wrong_Kind`.
@(private)
scan_fail :: proc "contextless" (h: ^Scanner, to: u32, null: bool, d: u64, at, owner: tape.Node_Index, pos: u64) #no_bounds_check {
	dm := h.demand
	for m in to ..= dm.nodes[to].last {
		node := dm.nodes[m]
		for p in dm.ends[node.ends:][:node.n_ends] {
			missing := null && tape.path_refused(d, u64(dm.paths[p].alls_end)) == .Missing
			holder := owner if missing && owner != tape.NO_NODE else at
			scan_answer(h, holder, p, .Missing if missing else .Wrong_Kind, pos, m)
		}
	}
}

// Makes an answer of `path` at `node`. `pos` orders the answers: twice a node index, or one less for a miss a close
// found.
@(private)
scan_answer :: #force_inline proc "contextless" (h: ^Scanner, node: tape.Node_Index, path: u32, outcome: tape.Presence, pos: u64, leaf: u32) {
	if h.made != nil && !scan_limit(h, path) {
		return
	}
	scan_push(h, &h.answers, Scan_Answer{node, path, pos, leaf, outcome, false})
}

// Whether a limited demand keeps an answer of `path` as it is made. It keeps one past the path's limit only while a
// step may still take back an earlier one. A path whose answers no step takes back is settled at its limit.
@(private, cold)
scan_limit :: #force_no_inline proc "contextless" (h: ^Scanner, path: u32) -> bool #no_bounds_check {
	x := h.demand.paths[path]
	if x.limit == 0 {
		return true
	}
	final := tape.path_final(x, h.dups) >= x.length
	if final && h.made[path] >= x.limit {
		return false
	}
	h.made[path] += 1
	if final && h.made[path] == x.limit && !h.done[path] {
		h.done[path] = true
		h.pending -= 1
	}
	return true
}

// Takes back the answers from `lo` to `hi` that came through demand node `to`.
@(private)
scan_kill :: #force_no_inline proc "contextless" (h: ^Scanner, lo, hi: int, to: u32) #no_bounds_check {
	last := h.demand.nodes[to].last
	for &a in h.answers[lo:hi] {
		if a.leaf >= to && a.leaf <= last && !a.dead {
			a.dead = true
			if h.made != nil {
				h.made[a.path] -= 1
			}
		}
	}
}

// Takes back the answers from `lo` to `hi`, those of element `element` of the array `f`, that came through a step
// from the end that does not take it. `count` is the array's length, 0 while unknown. An element that has passed out of
// every reach from the end (`element` is `max(u64)`) is kept only by a `Slice` that starts from the start.
@(private)
scan_kill_negatives :: proc "contextless" (h: ^Scanner, f: ^Scan_Frame, lo, hi: int, element: u64, count: u64 = 0) #no_bounds_check {
	dm := h.demand
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			#partial switch step in edge.step {
			case tape.Index:
				if at, in_array := tape.index_in(i64(step), count); step < 0 && (!in_array || element != at) {
					scan_kill(h, lo, hi, edge.to)
				}
			case tape.Slice:
				if count == 0 && step.lo < 0 || count > 0 && !tape.slice_takes(step, element, count) {
					scan_kill(h, lo, hi, edge.to)
				}
			}
		}
	}
}

// Answers the paths whose `Name` or `Index` steps at the closing container `f` at depth `d`, node `open`, met no child,
// and records each missing name once, though several demand nodes may look for it.
@(private, cold)
scan_close_misses :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, d: u64, open: tape.Node_Index, pos: u64) #no_bounds_check {
	dm := h.demand
	missed := len(h.missing)
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for e in node.edges ..< node.edges + node.n_edges {
			edge := dm.edges[e]
			#partial switch step in edge.step {
			case tape.Name:
				if f.object && u32(h.marks[e] >> 32) != f.gen {
					if !scan_missed(h, missed, string(step)) {
						scan_push(h, &h.missing, Scan_Missing{open, string(step)})
					}
					scan_fail(h, edge.to, true, d, open, open, pos)
				}
			case tape.Index:
				if _, in_array := tape.index_in(i64(step), f.count); !f.object && !in_array {
					scan_fail(h, edge.to, true, d, open, open, pos)
				}

			}
		}
	}
}

// Whether the close that records missing names from `from` in `Scanner.missing` has recorded `name`.
@(private)
scan_missed :: proc "contextless" (h: ^Scanner, from: int, name: string) -> bool {
	for m in h.missing[from:] {
		if m.name == name {
			return true
		}
	}
	return false
}

// Opens a frame for the container just stored, its live demand nodes those from `live` in `Scanner.live`.
@(private)
scan_open :: proc "contextless" (h: ^Scanner, t: tape.Token, live: u32, whole: bool) #no_bounds_check {
	dm := h.demand
	h.opens += 1
	f := Scan_Frame{live = live, n_live = u32(len(h.live)) - live, whole = whole, alls = whole, object = t.kind == .Object, ring = u32(len(h.ring)), gen = h.opens}
	f.element, f.takes_to = .End, max(u64)
	k: u64
	others := false
	for n in h.live[live:] {
		node := &dm.nodes[n]
		k = max(k, node.neg)
		f.takes_from = max(f.takes_from, node.takes_from)
		f.takes_to = min(f.takes_to, node.takes_to)
		f.unmet += node.names if f.object else node.indexes
		others ||= node.others
		f.alls ||= node.alls
		f.keys ||= node.keys
		f.slices ||= node.slices
		f.lengths |= node.lengths
		f.heads |= node.heads
	}
	// An array's count is kept by every frame.
	f.keys &&= !whole && f.object
	f.alls ||= f.keys
	f.passes = f.object && !whole && !f.keys
	if t.kind != .Array {
		k = 0
	}
	// An element takes at least one byte, so a ring of more entries than the text has bytes holds nothing more. A scan
	// with no `rewalk` may read a text whose length its source does not bound.
	if h.rewalk != nil {
		k = min(k, u64(len(h.b.doc.src)))
	}
	// Only one array is read again at a time, so a replay holds at most one more walk and reads each element once
	// more. A format that cannot walk an element alone keeps every element a step from the end may take, and takes back
	// what the elements it does not take answered.
	f.replays = k > 0 && !others && !whole && !h.replaying && h.rewalks
	f.drops = k > 0 && !others && !whole && !h.rewalks
	f.ring_k = u32(k)
	if f.replays {
		f.ring = u32(len(h.tokens))
	}
	scan_push(h, &h.frames, f)
}

@(private)
scanner_close :: proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	d := s.c
	f := &h.frames[d - 1]
	dm := h.demand
	open := tape.Node_Index(s.b >> 32)
	if f.replays {
		k := u64(f.ring_k)
		for e in max(f.count, k) - k ..< f.count {
			s = scan_replay(h, s, f, e)
			f = &h.frames[d - 1]
			if h.stopped || h.end_of == .Settled || h.b.err != nil {
				// The array stays open, and the end closes it partial with its full count.
				return s, scan_halt(h, t)
			}
		}
	} else if f.ring_k > 0 {
		k := u64(f.ring_k)
		for e in max(f.count, k) - k ..< f.count {
			hi := len(h.answers) if e + 1 == f.count else int(h.ring[f.ring + u32((e + 1) % k)].answers)
			scan_kill_negatives(h, f, int(h.ring[f.ring + u32(e % k)].answers), hi, e, f.count)
		}
		if f.drops {
			// Backwards, so the nodes of an element are where its ring entry says.
			for e := f.count; e > max(f.count, k) - k; {
				e -= 1
				if !scan_ring_takes(h, f, e) {
					hi := builder_cursor(&h.b, s) if e + 1 == f.count else tape.Node_Index(h.ring[f.ring + u32((e + 1) % k)].node)
					s = scan_drop(h, s, f, h.ring[f.ring + u32(e % k)], hi)
				}
			}
		}
	}

	if f.unmet != 0 {
		scan_close_misses(h, f, d, open, 2 * u64(builder_cursor(&h.b, s)) - 1)
	}
	if u64(u32(s.b)) == f.count {
		s, _ = builder_step(&h.b, s, t, false, true)
		h.b.closed = open
	} else {
		s = scan_close_partial(h, s, f^)
	}
	if h.settles && d - 1 <= dm.reach {
		for n in h.live[f.live:][:f.n_live] {
			scan_settle(h, n, d - 1)
		}
	}
	(^runtime.Raw_Dynamic_Array)(&h.live).len = int(f.live)
	if f.replays {
		(^runtime.Raw_Dynamic_Array)(&h.tokens).len = int(f.ring)
	} else {
		(^runtime.Raw_Dynamic_Array)(&h.ring).len = int(f.ring)
	}
	(^runtime.Raw_Dynamic_Array)(&h.frames).len -= 1
	return scan_left(h, s)
}

// Reads element `e` of the replaying array `f` again when a negative index takes it, now that its count is known.
@(private)
scan_replay :: proc "contextless" (h: ^Scanner, s: hook.Regs, f: ^Scan_Frame, e: u64) -> hook.Regs #no_bounds_check {
	s := s
	dm := h.demand
	clear(&h.picks)
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			#partial switch step in edge.step {
			case tape.Index:
				if at, in_array := tape.index_in(i64(step), f.count); step < 0 && in_array && e == at {
					scan_put(&h.picks, edge.to)
				}
			case tape.Slice:
				if tape.slice_takes(step, e, f.count) {
					scan_put(&h.picks, edge.to)
				}
			}
		}
	}
	if len(h.picks) == 0 {
		return s
	}
	h.by_place, h.forced, h.forced_at = true, true, e
	t := h.tokens[f.ring + u32(e % u64(f.ring_k))]
	if t.kind <= .Plain {
		s, _ = scanner_value(h, s, t, true)
		return s
	}
	h.replaying = true
	// The first walk judged the element, so the walk read again fails only for want of memory.
	if r := h.rewalk(h, &s, t.lo); u8(r) == hook.WALK_NO_MEMORY && h.b.err == nil {
		h.b.err = .Out_Of_Memory
	}
	h.replaying, h.forced = false, false
	return s
}

// Closes the open container of `s`, frame `f`, as partial.
@(private)
scan_close_partial :: proc "contextless" (h: ^Scanner, s: hook.Regs, f: Scan_Frame) -> hook.Regs #no_bounds_check {
	s := s
	open := tape.Node_Index(s.b >> 32)
	node := &h.b.doc.nodes[open]
	node.n = u32(builder_cursor(&h.b, s) - open)
	node.spelling = tape.CONTAINER_PARTIAL | u16(min(f.count, u64(tape.MAX_CHILDREN)))
	if f.count >= u64(tape.MAX_CHILDREN) {
		builder_partial_count(&h.b, open, u32(f.count))
	}
	h.b.closed = open
	s.c -= 1
	s.b = h.b.stack[s.c]
	return s
}

// Goes on past a value the demand nodes `picks` took at depth `d`.
@(private)
scan_past :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, picks: []u32, d: u64) -> (hook.Regs, hook.Action) {
	if h.settles && d <= h.demand.reach {
		scan_settle_picks(h, picks, d)
	}
	return scan_left(h, s)
}

@(private)
scan_settle_picks :: #force_no_inline proc "contextless" (h: ^Scanner, picks: []u32, d: u64) {
	for n in picks {
		scan_settle(h, n, d)
	}
}

@(private)
scan_left :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs) -> (hook.Regs, hook.Action) {
	if h.b.err != nil {
		return s, .Stop
	}
	if h.settles && h.pending == 0 {
		scan_settled(h)
		return s, .Stop if h.stop else .Next
	}
	return s, .Next
}

// Ends the scan's keeping once every path is settled: `stop_early` stops the walk, and otherwise the hook takes no
// more tokens while the walk judges the rest of the text.
@(private, cold)
scan_settled :: #force_no_inline proc "contextless" (h: ^Scanner) {
	if h.stop {
		h.stopped = true
	} else {
		h.end_of = .Settled
	}
}

// The answer to token `t` of a scan that took its last token, by a stop, a refused growth or every path settled.
@(private)
scan_halt :: #force_inline proc "contextless" (h: ^Scanner, t: tape.Token) -> hook.Action {
	if h.end_of != .Settled || h.b.err != nil {
		return .Stop
	}
	return scan_rest(t)
}

// The answer to token `t` once every path is settled: a container is judged with the rest of the text and no more
// tokens, and any other token passes.
@(private)
scan_rest :: #force_inline proc "contextless" (t: tape.Token) -> hook.Action {
	return .Rest if t.role == .Value && (t.kind == .Array || t.kind == .Object) else .Next
}

// Marks done each path under demand node `n` whose answers are all made once the walk is back at depth `d`.
@(private)
scan_settle :: proc "contextless" (h: ^Scanner, n: u32, d: u64) #no_bounds_check {
	dm := h.demand
	for m in n ..= dm.nodes[n].last {
		node := dm.nodes[m]
		for p in dm.ends[node.ends:][:node.n_ends] {
			x := dm.paths[p]
			settled := d <= u64(tape.path_settles(x, h.dups))
			// A path holding its limit of answers is settled once no step can take one back.
			settled ||= x.limit > 0 && h.made[p] >= x.limit && d <= u64(tape.path_final(x, h.dups))
			if !h.done[p] && settled {

				h.done[p] = true
				h.pending -= 1
			}
		}
	}
}

// With `facts`, keeps comment `t` as a fact of a node the scan keeps. A comment before a token goes to the node that
// token is stored at, an inline comment to the value before it unless the walk passed that value unstored, and a foot
// to the open container. `.Stop` when memory for the facts is refused.
@(private, cold)
scan_fact :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> hook.Action {
	#partial switch tape.fact_kind(t.role) {
	case .Comment:
		// After a key, the token is its value, stored past the key's node.
		at := builder_cursor(&h.b, s)
		if h.wait_at != at {
			h.wait_at, h.wait_from = at, len(h.b.doc.facts)
		}
		a := builder_fact(&h.b, s, t)
		if a == .Next && h.has_key {
			h.b.doc.facts[len(h.b.doc.facts) - 1].node += 1
		}
		return a
	case .Comment_Inline:
		if h.passed == builder_cursor(&h.b, s) {
			return .Next
		}
	case .Comment_Foot:
	case:
		return .Next
	}
	return builder_fact(&h.b, s, t)
}

// Drops the comments before a token the walk passed unstored.
@(private, cold)
scan_unwait :: #force_no_inline proc "contextless" (h: ^Scanner) {
	for &f in h.b.doc.facts[h.wait_from:] {
		if f.kind == .Comment {
			f.node = tape.NO_NODE
		}
	}
	h.wait_at = tape.NO_NODE
}

// Drops the comments whose node the scan did not keep, such as one before a token never read or a foot of a root not
// kept.
@(private, cold)
scan_check_facts :: proc "contextless" (h: ^Scanner, regs: hook.Regs) #no_bounds_check {
	nodes := h.b.doc.nodes[:builder_cursor(&h.b, regs)]
	facts := h.b.doc.facts
	kept := 0
	h.b.doc.present = {}
	for f in facts {
		if int(f.node) < len(nodes) {
			facts[kept] = f
			kept += 1
			if f.kind != .Comment {
				h.b.doc.present += {f.kind}
			}
		}
	}
	h.b.doc.facts = facts[:kept]
}

// Makes room in `list` for `n` more entries. False once a growth is refused, which sets the builder's error.
@(private)
scan_reserve :: #force_inline proc "contextless" (h: ^Scanner, list: ^[dynamic]$T, n: int) -> bool {
	raw := (^runtime.Raw_Dynamic_Array)(list)
	if raw.cap - raw.len >= n {
		return true
	}
	return scan_grow_to(h, raw, size_of(T), align_of(T), raw.len + n)
}

// Appends `v` to a list `scan_reserve` made room in.
@(private)
scan_put :: #force_inline proc "contextless" (list: ^[dynamic]$T, v: T) #no_bounds_check {
	raw := (^runtime.Raw_Dynamic_Array)(list)
	([^]T)(raw.data)[raw.len] = v
	raw.len += 1
}

// Appends `v` to a list of the scan. A refused growth is held in the builder's error, which ends the walk.
@(private)
scan_push :: #force_inline proc "contextless" (h: ^Scanner, list: ^[dynamic]$T, v: T) #no_bounds_check {
	raw := (^runtime.Raw_Dynamic_Array)(list)
	if raw.len == raw.cap && !scan_grow_to(h, raw, size_of(T), align_of(T), raw.len + 1) {
		return
	}
	([^]T)(raw.data)[raw.len] = v
	raw.len += 1
}

// Grows a list of entries of `size` bytes to twice its capacity, at least 8 entries and at least `least`. A list in the
// room moves out of it.
@(private, cold)
scan_grow_to :: #force_no_inline proc "contextless" (h: ^Scanner, list: ^runtime.Raw_Dynamic_Array, size, align, least: int) -> bool {
	context = h.b.ctx
	want := max(2 * list.cap, 8, least)
	data: []u8
	err: runtime.Allocator_Error
	if scan_in_room(h, list.data) {
		if data, err = runtime.mem_alloc_non_zeroed(want * size, align, list.allocator); err == nil {
			runtime.mem_copy_non_overlapping(raw_data(data), list.data, list.len * size)
		}
	} else {
		data, err = runtime.non_zero_mem_resize(list.data, list.cap * size, want * size, align, list.allocator)
	}
	if err = took(err, raw_data(data), want * size); err == nil {
		list.data, list.cap = raw_data(data), want
	} else {
		if h.b.err == nil {
			h.b.err = err
		}
		return false
	}
	return true
}

// Gives `doc` its answers by path, kept children, missing names and held spans in one block, from `answers` and
// `missing`, which it sorts, and `made`, which it overwrites.
@(private)
scan_lists :: proc(h: ^Scanner, doc: ^tape.Document, answers: []Scan_Answer, missing: []Scan_Missing, made: []u32) -> runtime.Allocator_Error {
	allocator := doc.allocator
	paths := len(h.demand.paths)
	if !slice.is_sorted_by(answers, scan_answer_before) {
		slice.stable_sort_by(answers, scan_answer_before)
	}
	if h.demand.limited {
		// A path keeps its first answers in document order, up to its limit.
		runtime.mem_zero(raw_data(made), len(made) * size_of(u32))
		for &a in answers {
			if limit := h.demand.paths[a.path].limit; !a.dead && limit > 0 {
				a.dead = made[a.path] == limit
				made[a.path] += u32(!a.dead)
			}
		}
	}
	live, names := 0, 0
	for a in answers {
		live += int(!a.dead)
	}
	for m in missing {
		names += len(m.name)
	}
	x: ^tape.Partial
	held_at := size_of(tape.Partial)
	answers_at := held_at + len(h.held) * size_of(tape.Held_Span)
	starts_at := answers_at + live * size_of(x.answers[0])
	kept_at := starts_at + (paths + 1) * size_of(u32)
	missing_at := kept_at + len(h.kept) * size_of(x.kept[0])
	names_at := missing_at + len(missing) * size_of(x.missing[0])
	block, perr := runtime.mem_alloc_non_zeroed(names_at + names, align_of(tape.Partial), allocator)
	if e := took(perr, raw_data(block), names_at + names); e != nil {
		return e
	}
	x = (^tape.Partial)(raw_data(block))
	x^ = {dups = h.dups}
	doc.partial = x
	x.answers = ([^]type_of(x.answers[0]))(raw_data(block[answers_at:]))[:live]
	x.starts = ([^]u32)(raw_data(block[starts_at:]))[:paths + 1]
	x.kept = ([^]type_of(x.kept[0]))(raw_data(block[kept_at:]))[:len(h.kept)]
	x.missing = ([^]type_of(x.missing[0]))(raw_data(block[missing_at:]))[:len(missing)]
	x.names = block[names_at:]
	x.held = ([^]tape.Held_Span)(raw_data(block[held_at:]))[:len(h.held)]
	copy(x.held, h.held[:])
	// Each path's answers in document order, in three steps: count them, turn the counts into starts, place the
	// answers.

	runtime.mem_zero(raw_data(x.starts), len(x.starts) * size_of(u32))
	if paths > 1 {
		for a in answers {
			x.starts[a.path + 1] += u32(!a.dead)
		}
		for p in 0 ..< paths {
			x.starts[p + 1] += x.starts[p]
		}
	}
	for a in answers {
		if !a.dead {
			x.answers[x.starts[a.path]] = {a.node, a.outcome}
			x.starts[a.path] += 1
		}
	}
	if paths > 0 {
		copy(x.starts[1:], x.starts[:paths])
		x.starts[0] = 0
	}
	for k, i in h.kept {
		x.kept[i] = {k.node, k.index}
	}
	slice.stable_sort_by(missing, proc(a, b: Scan_Missing) -> bool { return a.node < b.node })
	at := 0
	for m, i in missing {
		x.missing[i] = {m.node, u32(at), u32(len(m.name))}
		copy(x.names[at:], m.name)
		at += len(m.name)
	}
	return nil
}

@(private)
scan_answer_before :: proc(a, b: Scan_Answer) -> bool {
	return a.pos < b.pos || a.pos == b.pos && a.path < b.path
}

@(private)
scanner_free :: proc(h: ^Scanner, allocator: runtime.Allocator) {
	free_list :: proc(h: ^Scanner, list: ^[dynamic]$T) {
		if !scan_in_room(h, raw_data(list^)) {
			delete(list^)
		}
	}
	free_list(h, &h.frames)
	free_list(h, &h.elements)
	free_list(h, &h.live)
	free_list(h, &h.picks)
	free_list(h, &h.answers)
	free_list(h, &h.kept)
	free_list(h, &h.missing)
	free_list(h, &h.ring)
	free_list(h, &h.tokens)
	delete(h.held)
	delete(h.bytes)

	if !scan_in_room(h, raw_data(h.marks)) {
		runtime.mem_free_with_size(raw_data(h.marks), len(h.marks) * size_of(u64) + len(h.made) * size_of(u32) + len(h.done), allocator)
	}
}
