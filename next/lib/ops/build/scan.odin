package build

import "base:runtime"
import "core:slice"
import "stury:lib/core/tape"

// The hook of a scan: a `Builder` that keeps only what the paths of a demand reach. Its registers are the builder's.
// A container on the paths is a frame holding the demand nodes live in it. A value a path ends at is kept whole, its
// steps still followed when longer paths go on inside it.
Scanner :: struct {
	b:           Builder,
	demand:      ^tape.Demand,
	key_is:      Key_Is, // the name comparison for a key that needs decoding
	frames:      [dynamic]Scan_Frame, // the containers on the paths, the root's first, one per builder level
	live:        [dynamic]u32, // the demand nodes live in the frames, each frame's from its `live`
	picks:       [dynamic]u32, // the demand nodes that took the coming value
	answers:     [dynamic]Scan_Answer,
	kept:        [dynamic]tape.Kept_Child,
	missing:     [dynamic]Scan_Missing,
	// The true child counts of the partial containers whose `spelling` saturated, in the order they closed. A container
	// closed with every child has its count from the builder.
	counts:      [dynamic]tape.Child_Count,
	ring:        [dynamic]u32, // the count of answers made before each element a negative `Index` can still take
	tokens:      [dynamic]tape.Token, // the token of each element a replaying array's negative `Index` can still take
	rewalk:      Rewalk, // the proc that gives this hook the value at `lo` again
	// For each demand edge whose key met a member of an object, the generation of the object's frame above the answers
	// made before. A mark is valid only for the frame of its generation.
	marks:       []u64,
	opens:       u32, // the frames opened, the last one's generation, which a frame being a node keeps from wrapping
	done:        []bool, // the paths settled under `stop_early`, a bool per path
	pending:     int, // the paths not done
	key:         tape.Token, // with `has_key`, the key of the coming value
	has_key:     bool,
	by_place:    bool, // an `Index` picked the coming value, so it keeps a `Kept_Child`
	forced:      bool, // the coming value is element `forced_at` of its array, read again with its picks made
	forced_at:   u64,
	replaying:   bool, // inside a `rewalk`, where every array keeps the elements its negative indexes may take
	end_of:      Scan_End, // what the next token is, when it is the `End` of a container
	first:       bool, // under `.First` the first member of a repeated key answers
	stop:        bool, // `stop_early`
	stopped:     bool,
	room:        ^Scan_Room,
	skips:       tape.Skips,
	open_levels: tape.Levels(builder_levels_held, builder_levels_grow),
	keeps:       Builder_Keeps(builder_hook_grows),
}

// The container whose `End` is the next token, when this hook passed or kept it as a whole.
Scan_End :: enum u8 {
	None,
	Skipped, // a container this hook skipped
	Picked, // a container picks took, kept whole or stored as one node, its picks still in `picks`
}

// The builder comes first, so the walk can read the scanner as its builder for its open stack and a container kept whole.
#assert(offset_of(Scanner, b) == 0)

// Gives hook `h` the value at `lo` again from registers `s`, and the walk's result.
Rewalk :: #type proc "contextless" (h: ^Scanner, s: ^tape.Hook_Regs, lo: u64) -> tape.Walk_Result

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
	alls:    bool, // an `All` takes any member, or every child is kept
	gen:     u32, // its generation, which the marks of its members carry
	lengths: u64, // a bit per length its `Name` steps have, past 63 counted from 0
	heads:   u64, // a bit per first byte its `Name` steps have, by the byte's low six bits
	// The steps its close still has to check, as no child met them: the `Name` steps no member has met yet of an object,
	// the `Index` steps of an array.
	unmet:   u32,
	// Its positional steps are all negative indexes, so each element is passed, and the ones they take are read again
	// at its close.
	replays: bool,
	// For an array with no positional steps, where each element picks the same demand nodes, the kind of the element
	// whose frame the entry past this one in `Scanner.frames` still holds, as its live demand nodes still hold their
	// entries in `Scanner.live`, else `End`. An element of that kind reopens it.
	element: tape.Kind,
	element_unmet: u32, // the `unmet` that frame opened with
}

// An answer as the walk made it.
@(private)
Scan_Answer :: struct {
	answer: tape.Answer,
	pos:    u64, // twice the value's first byte, or one past twice a close's byte for a miss the close found
	leaf:   u32, // the demand node the answer came from
	dead:   bool, // a repeated key or a negative index took it back
}

@(private)
Scan_Missing :: struct {
	node: tape.Node_Index,
	name: string,
}

// The room a scan's lists start in, on the caller's stack, so a scan of few paths and answers allocates no list. A
// list that outgrows it moves to the allocator, and a demand past its marks takes them from there too.
Scan_Room :: struct {
	frames:  [8]Scan_Frame,
	live:    [16]u32,
	picks:   [16]u32,
	answers: [16]Scan_Answer,
	kept:    [16]tape.Kept_Child,
	counts:  [8]tape.Child_Count,
	marks:   [32]u64,
	done:    [32]bool,
}

// A scanner of `demand` over `src`, as `builder_start` with `nodes`, `most` and `frames`, its room growing as it fills.
// `read.dups` is the format's resolved policy, never `.Default`.
@(require_results)
scanner_start :: proc(src: []u8, format: ^tape.Format, demand: ^tape.Demand, read: tape.Read_Options, key_is: Key_Is, rewalk: Rewalk, nodes, most: int, frames: []u64, room: ^Scan_Room, allocator: runtime.Allocator) -> (h: Scanner, err: runtime.Allocator_Error) {
	h.b = builder_start(src, format, nodes, most, frames, allocator)
	if h.b.err != nil {
		return {}, h.b.err
	}
	h.demand, h.key_is, h.rewalk = demand, key_is, rewalk
	h.first, h.stop, h.pending = read.dups == .First, read.stop_early, len(demand.paths)
	h.room = room
	scan_room_list(&h.frames, room.frames[:], allocator)
	scan_room_list(&h.live, room.live[:], allocator)
	scan_room_list(&h.picks, room.picks[:], allocator)
	scan_room_list(&h.answers, room.answers[:], allocator)
	scan_room_list(&h.kept, room.kept[:], allocator)
	scan_room_list(&h.counts, room.counts[:], allocator)
	h.missing.allocator, h.ring.allocator, h.tokens.allocator = allocator, allocator, allocator
	if len(demand.edges) <= len(room.marks) && len(demand.paths) <= len(room.done) {
		h.marks, h.done = room.marks[:len(demand.edges)], room.done[:len(demand.paths)]
	} else {
		// The marks and the settled paths share one block.
		marks := len(demand.edges) * size_of(u64)
		block, refused := runtime.mem_alloc_non_zeroed(marks + len(demand.paths), align_of(u64), allocator)
		if refused != nil {
			tape.destroy(&h.b.doc)
			return {}, refused
		}
		h.marks = ([^]u64)(raw_data(block))[:len(demand.edges)]
		h.done = ([^]bool)(raw_data(block[marks:]))[:len(demand.paths)]
	}
	// No frame has generation 0, so a zero mark is valid for none.
	runtime.mem_zero(raw_data(h.marks), len(h.marks) * size_of(u64))
	runtime.mem_zero(raw_data(h.done), len(h.done))
	// Every pick of a value or key is of a distinct edge, or the root, so `picks` never grows past this.
	if !scan_reserve(&h, &h.picks, len(demand.edges) + 1) {
		err = h.b.err
		scanner_free(&h, allocator)
		tape.destroy(&h.b.doc)
		return {}, err
	}
	return
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
scanner_hook :: #force_inline proc "contextless" (h: ^Scanner, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action) #no_bounds_check {
	if t.role > .Key {
		return s, .Next
	}
	if h.end_of != .None {
		end := h.end_of
		h.end_of = .None
		if end == .Picked {
			return scan_past(h, s, h.picks[:], s.c)
		}
		return s, .Next
	}
	// A key no `Name` of the open object can match takes no call.
	// A member no step took takes none either.
	if t.role == .Key {
		f := &h.frames[len(h.frames) - 1]
		clear(&h.picks)
		if !f.alls && scan_key_unmatched(h, f, t) {
			return s, .Next
		}
		h.key, h.has_key, h.by_place = t, true, false
		// A `Name` takes a string key only, as a format whose keys may be numbers holds `1` and `"1"` apart.
		if t.kind == .String {
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
		if f.object && len(h.picks) == 0 && !f.whole {
			f.count += 1
			return scan_pass(h, s, t)
		}
		if t.kind == f.element {
			return scan_reopen(h, s, t, f)
		}
	}
	if t.kind <= .Plain {
		return scanner_value(h, s, t, true)
	}
	return scanner_value(h, s, t, false)
}

// Whether no `Name` of the object `f` can match key `t`, as none has its length, or none has its first byte. A key
// that needs decoding has its length only once decoded.
@(private)
scan_key_unmatched :: #force_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, t: tape.Token) -> bool #no_bounds_check {
	if t.spelling & tape.SPELLING_DECODE != 0 {
		return false
	}
	return f.lengths & (1 << (t.n & 63)) == 0 || t.n > 0 && f.heads & (1 << (h.b.doc.src[t.lo] & 63)) == 0
}

// The partial document the walk built, or the error that ended it with everything freed. `regs` are the hook's
// registers at the walk's end and `root_close` the end of the root value.
@(require_results)
scanner_end :: proc(h: ^Scanner, regs: tape.Hook_Regs, root_close: u64, err: tape.Error) -> (r: tape.Partial_Result, e: tape.Error) {
	allocator := h.b.doc.allocator
	defer scanner_free(h, allocator)
	regs := regs
	e = err
	if e == nil {
		e = builder_error(&h.b)
	}
	if e == nil && h.stopped {
		// The containers the stop left open are on the paths, their counts what was read of them.
		for regs.c > 0 {
			regs = scan_close_partial(h, regs, h.frames[regs.c - 1])
		}
	}
	wide, wide_more := h.b.wide, h.b.wide_more
	h.b.wide = {}
	r.doc, e = builder_end(&h.b, regs, 0 if h.stopped else root_close, e)
	if e != nil {
		return
	}
	r.doc.flags += {.Partial}
	if h.stopped {
		r.doc.flags += {.Stopped}
	}
	if refused := scan_lists(h, &r, wide, wide_more); refused != nil {
		tape.destroy(&r)
		return {}, refused
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
				if !NAMED || !key_spelled(h.b.doc.src, t, string(step), h.key_is) {
					continue
				}
				mark := h.marks[e]
				if u32(mark >> 32) != f.gen {
					f.unmet -= 1
				} else {
					if h.first {
						continue
					}
					scan_kill(h, int(u32(mark)), len(h.answers), edge.to)
				}
				h.marks[e] = u64(f.gen) << 32 | u64(len(h.answers))
				scan_put(&h.picks, edge.to)
			case tape.All:
				scan_put(&h.picks, edge.to)
			}
		}
	}
}

@(private)
scanner_value :: proc "contextless" (h: ^Scanner, s: tape.Hook_Regs, t: tape.Token, $scalar: bool) -> (tape.Hook_Regs, tape.Action) #no_bounds_check {
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
		if !f.object && !scan_element(h, f, index, t) {
			return s, .Stop
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
		scan_push(h, &h.kept, tape.Kept_Child{at, u32(index)})
	}
	dm := h.demand
	live := u32(len(h.live))
	answered := len(h.answers)
	ends := false
	for n in h.picks {
		node := dm.nodes[n]
		for p in dm.ends[node.ends:][:node.n_ends] {
			scan_answer(h, {node = at, owner = owner, path = p, outcome = .Found}, 2 * t.lo, n)
		}
		ends ||= node.n_ends > 0
		when scalar {
			// No step enters a scalar.
			for edge in dm.edges[node.edges:][:node.n_edges] {
				scan_fail(h, edge.to, t.kind == .Null, d, at, owner, 2 * t.lo)
			}
		} else {
			enters := false
			for edge in dm.edges[node.edges:][:node.n_edges] {
				if step_enters(edge.step, t.kind) {
					enters = true
				} else {
					scan_fail(h, edge.to, false, d, at, owner, 2 * t.lo)
				}
			}
			if enters {
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
	// A value a path ends at and a child of a container kept whole are kept whole, and a container no step could enter
	// is stored as one node. The hook is called next at its `End`, so `picks` holds until then.
	h.end_of = .Picked
	if whole || ends {
		return s, .Keep
	}
	ok: bool
	if s, ok = builder_unread(&h.b, s, t); !ok {
		return s, .Stop
	}
	return s, .Skip
}

// Opens again the frame the last element of the array `f` left, for element `t` of the same kind.
@(private)
scan_reopen :: #force_inline proc "contextless" (h: ^Scanner, s: tape.Hook_Regs, t: tape.Token, f: ^Scan_Frame) -> (tape.Hook_Regs, tape.Action) #no_bounds_check {
	f.count += 1
	unmet := f.element_unmet
	opened, action := builder_step(&h.b, s, t, false, true)
	if action == .Stop {
		return opened, .Stop
	}
	frames := (^runtime.Raw_Dynamic_Array)(&h.frames)
	g := &([^]Scan_Frame)(frames.data)[frames.len]
	frames.len += 1
	h.opens += 1
	g.count, g.gen, g.unmet = 0, h.opens, unmet
	(^runtime.Raw_Dynamic_Array)(&h.live).len = int(g.live + g.n_live)
	return opened, .Next
}

// Records in the array at depth `d` the frame its element of `kind` just opened, for the elements of that kind to reopen
// when the element made no answer.
@(private)
scan_keep_element :: #force_inline proc "contextless" (h: ^Scanner, d: u64, kind: tape.Kind, reopens: bool) #no_bounds_check {
	f := &h.frames[d - 1]
	if f.object || f.unmet != 0 {
		return
	}
	f.element = kind if reopens else .End
	f.element_unmet = h.frames[d].unmet
}

// Passes a value no step took, a container with no more tokens up to its `End`.
@(private)
scan_pass :: #force_inline proc "contextless" (h: ^Scanner, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action) {
	h.has_key = false
	if t.kind > .Plain {
		h.end_of = .Skipped
		return s, .Skip
	}
	return s, .Next
}

// Takes the demand nodes that pick element `index` of the array `f`, whose token is `t`, and whether its ring took the
// element, which a refused growth stops.
@(private)
scan_element :: #force_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, index: u64, t: tape.Token) -> bool #no_bounds_check {
	dm := h.demand
	clear(&h.picks)
	h.by_place = false
	for n in h.live[f.live:][:f.n_live] {
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
				scan_put(&h.picks, edge.to)
			}
		}
	}
	if f.ring_k == 0 {
		return true
	}
	// The ring is the end of its list while the elements arrive, as an inner frame's close cuts the list back, so it
	// grows with the elements up to its size.
	k := u64(f.ring_k)
	slot := f.ring + u32(index % k)
	if f.replays {
		if index >= k {
			h.tokens[slot] = t
			return true
		}
		scan_push(h, &h.tokens, t)
		return h.b.err == nil
	}
	if index < k {
		scan_push(h, &h.ring, u32(len(h.answers)))
		return h.b.err == nil
	}
	// Element `index - k` passes out of the ring, so no negative index takes it.
	hi := len(h.answers) if k == 1 else int(h.ring[f.ring + u32((index + 1) % k)])
	scan_kill_negatives(h, f, int(h.ring[slot]), hi, max(u64))
	h.ring[slot] = u32(len(h.answers))
	return true
}

// Whether a step goes on into a value of `kind`.
@(private)
step_enters :: #force_inline proc "contextless" (step: tape.Step, kind: tape.Kind) -> bool {
	switch _ in step {
	case tape.Name:
		return kind == .Object
	case tape.Index:
		return kind == .Array
	case tape.All:
		return kind == .Array || kind == .Object
	}
	return false
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
			missing := null && d >= u64(dm.paths[p].alls_end)
			holder := owner if missing && owner != tape.NO_NODE else at
			scan_answer(h, {node = tape.NO_NODE, owner = holder, path = p, outcome = .Missing if missing else .Wrong_Kind}, pos, m)
		}
	}
}

@(private)
scan_answer :: #force_inline proc "contextless" (h: ^Scanner, a: tape.Answer, pos: u64, leaf: u32) {
	scan_push(h, &h.answers, Scan_Answer{a, pos, leaf, false})
}

// Takes back the answers from `lo` to `hi` that came through demand node `to`.
@(private)
scan_kill :: #force_no_inline proc "contextless" (h: ^Scanner, lo, hi: int, to: u32) #no_bounds_check {
	last := h.demand.nodes[to].last
	for &a in h.answers[lo:hi] {
		if a.leaf >= to && a.leaf <= last {
			a.dead = true
		}
	}
}

// Takes back the answers from `lo` to `hi`, those of element `element` of the array `f`, that came through a negative
// `Index` not taking it. `count` is the array's length, 0 while unknown, when every negative `Index` takes them back.
@(private)
scan_kill_negatives :: proc "contextless" (h: ^Scanner, f: ^Scan_Frame, lo, hi: int, element: u64, count: u64 = 0) #no_bounds_check {
	dm := h.demand
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			if step, ok := edge.step.(tape.Index); ok && step < 0 && (count < u64(-step) || element != count - u64(-step)) {
				scan_kill(h, lo, hi, edge.to)
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
				if !f.object && (step >= 0 && u64(step) >= f.count || step < 0 && u64(-step) > f.count) {
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
	f.element = .End
	k: u64
	others := false
	for n in h.live[live:] {
		node := &dm.nodes[n]
		k = max(k, node.neg)
		f.unmet += node.names if f.object else node.indexes
		others ||= node.others
		f.alls ||= node.alls
		f.lengths |= node.lengths
		f.heads |= node.heads
	}
	if t.kind != .Array {
		k = 0
	}
	// An element spends a byte at least, so a ring past the text's length holds nothing more.
	k = min(k, u64(len(h.b.doc.src)))
	// One array at a time is read again, so a replay holds one more walk at most and reads each element once more.
	f.replays = k > 0 && !others && !whole && !h.replaying
	f.ring_k = u32(k)
	if f.replays {
		f.ring = u32(len(h.tokens))
	}
	scan_push(h, &h.frames, f)
}

@(private)
scanner_close :: proc "contextless" (h: ^Scanner, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action) #no_bounds_check {
	s := s
	d := s.c
	f := &h.frames[d - 1]
	dm := h.demand
	open := tape.Node_Index(s.b >> 32)
	pos := 2 * t.lo + 1
	if f.replays {
		k := u64(f.ring_k)
		for e in max(f.count, k) - k ..< f.count {
			s = scan_replay(h, s, f, e)
			f = &h.frames[d - 1]
			if h.stopped || h.b.err != nil {
				// The array stays open, and the end closes it partial with its true count.
				return s, .Stop
			}
		}
	} else if f.ring_k > 0 {
		k := u64(f.ring_k)
		for e in max(f.count, k) - k ..< f.count {
			hi := len(h.answers) if e + 1 == f.count else int(h.ring[f.ring + u32((e + 1) % k)])
			scan_kill_negatives(h, f, int(h.ring[f.ring + u32(e % k)]), hi, e, f.count)
		}
	}
	if f.unmet != 0 {
		scan_close_misses(h, f, d, open, pos)
	}
	if u64(u32(s.b)) == f.count {
		s, _ = builder_step(&h.b, s, t, false, true)
	} else {
		s = scan_close_partial(h, s, f^)
	}
	if h.stop && d - 1 <= dm.reach {
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
scan_replay :: proc "contextless" (h: ^Scanner, s: tape.Hook_Regs, f: ^Scan_Frame, e: u64) -> tape.Hook_Regs #no_bounds_check {
	s := s
	dm := h.demand
	clear(&h.picks)
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			if step, ok := edge.step.(tape.Index); ok && step < 0 && f.count >= u64(-step) && e == f.count - u64(-step) {
				scan_put(&h.picks, edge.to)
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
	if r := h.rewalk(h, &s, t.lo); u8(r) == tape.WALK_NO_MEMORY && h.b.err == nil {
		h.b.err = .Out_Of_Memory
	}
	h.replaying, h.forced = false, false
	return s
}

// Closes the open container of `s`, frame `f`, as partial.
@(private)
scan_close_partial :: proc "contextless" (h: ^Scanner, s: tape.Hook_Regs, f: Scan_Frame) -> tape.Hook_Regs #no_bounds_check {
	s := s
	open := tape.Node_Index(s.b >> 32)
	node := &h.b.doc.nodes[open]
	node.n = u32(builder_cursor(&h.b, s) - open)
	node.spelling = tape.CONTAINER_PARTIAL | u16(min(f.count, u64(tape.MAX_CHILDREN)))
	if f.count >= u64(tape.MAX_CHILDREN) {
		scan_push(h, &h.counts, tape.Child_Count{open, u32(f.count)})
	}
	s.c -= 1
	s.b = h.b.stack[s.c]
	return s
}

// Goes on past a value the demand nodes `picks` took at depth `d`.
@(private)
scan_past :: #force_inline proc "contextless" (h: ^Scanner, s: tape.Hook_Regs, picks: []u32, d: u64) -> (tape.Hook_Regs, tape.Action) {
	if h.stop && d <= h.demand.reach {
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
scan_left :: #force_inline proc "contextless" (h: ^Scanner, s: tape.Hook_Regs) -> (tape.Hook_Regs, tape.Action) {
	if h.b.err != nil {
		return s, .Stop
	}
	if h.stop && h.pending == 0 {
		h.stopped = true
		return s, .Stop
	}
	return s, .Next
}

// Marks done each path under demand node `n` whose answers are all made once the walk is back at depth `d`.
@(private)
scan_settle :: proc "contextless" (h: ^Scanner, n: u32, d: u64) #no_bounds_check {
	dm := h.demand
	for m in n ..= dm.nodes[n].last {
		node := dm.nodes[m]
		for p in dm.ends[node.ends:][:node.n_ends] {
			x := dm.paths[p]
			repeats := x.repeats if h.first else min(x.repeats, x.named)
			if !h.done[p] && d <= u64(repeats) {
				h.done[p] = true
				h.pending -= 1
			}
		}
	}
}

// Makes room in `list` for `n` more entries. False once a growth is refused, held in the builder's error.
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

// Doubles the capacity of a list of entries of `size` bytes, to `least` at least, a list in the room moving out of it.
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
	if err == nil {
		list.data, list.cap = raw_data(data), want
	} else {
		if h.b.err == nil {
			h.b.err = err
		}
		return false
	}
	return true
}

// Gives `r` its answers, kept children and missing names in one block, and the document its true child counts.
@(private)
scan_lists :: proc(h: ^Scanner, r: ^tape.Partial_Result, wide: tape.Child_Count, wide_more: bool) -> runtime.Allocator_Error {
	allocator := r.doc.allocator
	live := 0
	for a in h.answers {
		live += int(!a.dead)
	}
	names := 0
	for m in h.missing {
		names += len(m.name)
	}
	answers_at := 0
	kept_at := answers_at + live * size_of(tape.Answer)
	missing_at := kept_at + len(h.kept) * size_of(tape.Kept_Child)
	names_at := missing_at + len(h.missing) * size_of(tape.Missing_Name)
	r.block = runtime.mem_alloc_non_zeroed(names_at + names, align_of(tape.Answer), allocator) or_return
	answers := ([^]tape.Answer)(raw_data(r.block[answers_at:]))[:live]
	sorted := slice.is_sorted_by(h.answers[:], scan_answer_before)
	if !sorted {
		slice.stable_sort_by(h.answers[:], scan_answer_before)
	}
	i := 0
	for a in h.answers {
		if !a.dead {
			answers[i] = a.answer
			i += 1
		}
	}
	r.answers = answers
	r.kept = ([^]tape.Kept_Child)(raw_data(r.block[kept_at:]))[:len(h.kept)]
	copy(r.kept, h.kept[:])
	slice.stable_sort_by(h.missing[:], proc(a, b: Scan_Missing) -> bool { return a.node < b.node })
	r.missing = ([^]tape.Missing_Name)(raw_data(r.block[missing_at:]))[:len(h.missing)]
	at := names_at
	for m, j in h.missing {
		r.missing[j] = {m.node, u32(at), u32(len(m.name))}
		copy(r.block[at:], m.name)
		at += len(m.name)
	}
	// An inner container closes before the one holding it.
	frames := h.counts[:]
	slice.sort_by(frames, proc(a, b: tape.Child_Count) -> bool { return a.node < b.node })
	n := len(frames)
	if wide.count == 0 {
		if n > 0 {
			r.doc.counts = slice.clone(frames, allocator) or_return
		}
		return nil
	}
	// The builder's saturated containers, those closed with every child, merged in node order with the partial ones.
	one := [1]tape.Child_Count{wide}
	built := one[:]
	all: [dynamic]tape.Child_Count
	defer delete(all)
	if wide_more {
		err: runtime.Allocator_Error
		all, err = builder_counts(r.doc.nodes, allocator)
		if err != nil {
			return err
		}
		built = all[:]
	}
	counts := make([]tape.Child_Count, len(built) + n, allocator) or_return
	b, f, c := 0, 0, 0
	for b < len(built) || f < n {
		if f < n && (b == len(built) || frames[f].node < built[b].node) {
			counts[c] = frames[f]
			f += 1
		} else {
			counts[c] = built[b]
			b += 1
		}
		c += 1
	}
	r.doc.counts = counts
	return nil
}

@(private)
scan_answer_before :: proc(a, b: Scan_Answer) -> bool {
	return a.pos < b.pos || a.pos == b.pos && a.answer.path < b.answer.path
}

@(private)
scanner_free :: proc(h: ^Scanner, allocator: runtime.Allocator) {
	free_list :: proc(h: ^Scanner, list: ^[dynamic]$T) {
		if !scan_in_room(h, raw_data(list^)) {
			delete(list^)
		}
	}
	free_list(h, &h.frames)
	free_list(h, &h.live)
	free_list(h, &h.picks)
	free_list(h, &h.answers)
	free_list(h, &h.kept)
	free_list(h, &h.missing)
	free_list(h, &h.counts)
	free_list(h, &h.ring)
	free_list(h, &h.tokens)
	if !scan_in_room(h, raw_data(h.marks)) {
		runtime.mem_free_with_size(raw_data(h.marks), len(h.marks) * size_of(u32) + len(h.done), allocator)
	}
}
