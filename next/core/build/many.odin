package build

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import core ".."

// What `$MANY` adds to the step logic of `scan.odin`: what a read of one plain path never pays for. Up to 64 paths at once,
// each with its limit, and the steps one path has no state for: negative indexes, `Slice`, `Descend`, `?` and `every_key`.
// A frame per depth holds the armed paths as one `u64`, so a path with no `Descend` is at step `d - 1` of a container at
// depth `d`. A `Descend` path can be at several steps of a container at once, so it has a row of step bits per frame.

// A tombstone for an answer a repeated key took back. It keeps the list's indexes, which the marks hold.
@(private)
DEAD :: max(u32)

// One `Descend` path's steps in one frame, a bit per step: those live in the container, and the `Name`s among them that
// met their key.
@(private)
Deep_Row :: struct {
	live:    u64,
	matched: u64,
}

// A container the read is inside. `armed` holds a bit per path with a step here, `matched` the paths whose `Name` met its
// key, and `ends` the paths that answered this container itself. `whole` says every member is kept, as a path answered
// it. `ring` is the frame's first entry in `Scan_Many.rings` and `ring_k` its entries, 0 for none. `delay` says a
// `Slice` with a negative end feeds its elements late. `found` holds the paths that found the container under `.Stream`,
// which answer at its close, and `open` is its token.
@(private)
Many_Frame :: struct {
	armed:    u64,
	matched:  u64,
	ends:     u64,
	found:    u64,
	open_pos: u64,
	open:     core.Token,
	ring:     u32,
	ring_k:   u32,
	kept:     u32,
	slot:     u32,
	whole:    bool,
	delay:    bool,
	is_map:   bool,
}

// An element a ring holds: its tokens, and the nodes `.Replay` reads them at.
@(private)
Ring_Entry :: struct {
	key:    core.Token,
	value:  core.Token,
	key_at: core.Node_Index,
	at:     core.Node_Index,
}

// An answer and what places it. `pos` orders answers by text: twice the value's first byte, or one more than twice the
// closing byte for an answer a close gives. A built document has no closing bytes, so there it is a node's index in the
// high half, and a close is its container's last node with the deeper of two closes first. `chain` tells which `Descend` a `Descend` path's answer came through. `token`
// and `hi` are what `.Stream` gives.
@(private)
Placed :: struct {
	pos:    u64,
	answer: core.Answer,
	token:  core.Token,
	hi:     u64,
	chain:  u32,
}

// The state of a `$MANY` read. `next_deep` holds the steps the paths in `Scan.next` picked the coming value at, by
// `Scan_Path.deep`. `ended` holds the paths whose walk ended at the value, `keep` says it is kept whole, and `indexed` that
// it needs a `Kept_Child`. `feeding` says the coming value's picks are already made.
@(private)
Scan_Many :: struct {
	paths:      []Scan_Path,
	frames:     []Many_Frame,
	deep:       []Deep_Row,
	deeps:      int,
	marks:      []int,
	rings:      []Ring_Entry,
	ring_top:   u32,
	ringed:     u64,
	all:        u64,
	done:       u64,
	ended:      u64,
	next_deep:  [64]u64,
	placed:     []Placed,
	n_placed:   int,
	flushed:    int,
	dead:       int,
	late:       bool,
	key:        core.Token,
	key_at:     core.Node_Index,
	has_key:    bool,
	keep:       bool,
	indexed:    bool,
	feeding:    bool,
	found:      u64,
	keep_set:   u64,
	keep_found: u64,
	keep_open:  core.Token,
	on:         proc(state: rawptr, a: core.Token_Answer) -> bool,
	state:      rawptr,
	ctx:        runtime.Context,
}

// The ring entries a step needs, 0 for none. `delayed` says the step feeds elements as later ones arrive.
@(private)
step_ring :: proc "contextless" (step: core.Step) -> (need: int, delayed: bool) {
	#partial switch x in step {
	case core.Index:
		return max(-int(x), 0), false
	case core.Slice:
		hi := x.hi.? or_else 0
		if x.lo < 0 {
			return -x.lo, false
		}
		return max(-hi, 0), hi < 0
	}
	return 0, false
}

// Reads `paths` into a `Scan_Many` for `h`. `depth` bounds the frames a `Descend` path opens.
@(private)
many_plan :: proc(h: ^Scan, paths: []core.Path, depth: int, allocator: runtime.Allocator) -> core.Path_Error {
	if len(paths) > core.MAX_PATHS {
		return {kind = .Over_Capacity}
	}
	m, no_state := new(Scan_Many, allocator)
	if no_state != nil {
		return {kind = .No_Memory}
	}
	h.many = m
	h.free = max(int)
	h.keep = h.free
	no_paths: runtime.Allocator_Error
	m.paths, no_paths = make([]Scan_Path, len(paths), allocator)
	if no_paths != nil {
		return {kind = .No_Memory}
	}
	frames, total := 0, 0
	for path, p in paths {
		x := &m.paths[p]
		if e := scan_plan_path(h, x, path); e.kind != .None {
			e := e
			e.path = u32(p)
			return e
		}
		x.marks = total
		total += x.n
		frames = max(frames, x.n)
		x.deep = -1
		if x.descend >= 0 {
			x.deep = m.deeps
			m.deeps += 1
		}
		if x.limit > 0 {
			h.next |= 1 << uint(p)
		}
		if x.deep >= 0 {
			m.next_deep[x.deep] = 1
		}
		if x.negative != 0 {
			m.ringed |= 1 << uint(p)
		}
		m.late = m.late || x.late
		m.all |= 1 << uint(p)
	}
	if m.deeps > 0 {
		frames = max(frames, depth)
	}
	frames += 2
	no_frames, no_marks, no_deep: runtime.Allocator_Error
	m.frames, no_frames = make([]Many_Frame, frames, allocator)
	m.marks, no_marks = make([]int, total, allocator)
	if m.deeps > 0 {
		m.deep, no_deep = make([]Deep_Row, frames * m.deeps, allocator)
	}
	if no_frames != nil || no_marks != nil || no_deep != nil {
		return {kind = .No_Memory}
	}
	return {}
}

// Frees a `$MANY` read's state.
@(private)
many_free :: proc(h: ^Scan, allocator: runtime.Allocator) {
	m := h.many
	if m == nil {
		return
	}
	delete(m.paths, allocator)
	delete(m.frames, allocator)
	delete(m.deep, allocator)
	delete(m.marks, allocator)
	delete(m.rings, allocator)
	delete(m.placed, allocator)
	free(m, allocator)
	h.many = nil
}

@(private = "file")
placed_less :: proc(a, b: Placed) -> bool {
	if a.pos != b.pos {
		return a.pos < b.pos
	}
	if a.answer.path != b.answer.path {
		return a.answer.path < b.answer.path
	}
	return a.answer.outcome < b.answer.outcome
}

// Puts what the read placed in text order, drops what a repeated key took back and what a late path's limit cuts.
@(private)
many_settle :: proc(h: ^Scan) {
	m := h.many
	// With no late path and nothing taken back, the answers were placed in order and each path stopped at its limit.
	if !m.late && m.dead == 0 {
		return
	}
	w := m.flushed
	for i in m.flushed ..< m.n_placed {
		if m.placed[i].answer.path != DEAD {
			m.placed[w] = m.placed[i]
			w += 1
		}
	}
	m.n_placed = w
	list := m.placed[m.flushed:w]
	if !slice.is_sorted_by(list, placed_less) {
		slice.sort_by(list, placed_less)
	}
	seen: [64]int
	w = m.flushed
	for a in list {
		seen[a.answer.path] += 1
		if seen[a.answer.path] <= m.paths[a.answer.path].limit {
			m.placed[w] = a
			w += 1
		}
	}
	m.n_placed = w
}

// Moves the settled answers to the read's list, and sorts the names by node since an outer close follows an inner one.
@(private)
many_answers :: proc(h: ^Scan) {
	m := h.many
	many_settle(h)
	answers, refused := make([]core.Answer, m.n_placed, h.b.doc.allocator)
	if refused != nil {
		h.b.err = {kind = .No_Memory}
		return
	}
	h.answers, h.n_answers = answers, m.n_placed
	for a, i in m.placed[:m.n_placed] {
		h.answers[i] = a.answer
	}
	slice.stable_sort_by(h.missing[:h.n_missing], proc(a, b: core.Missing_Name) -> bool {
		return a.node < b.node
	})
}

// The hook of a `$MANY` read into a document.
scan_hook_many :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return scan_step(true, .Document, h, s, t)
}

// The hook of `each_answer`.
scan_hook_stream :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return many_step(.Stream, h, s, t)
}

// The step logic, out of line for a walk's many hook sites.
@(private = "file")
many_step :: proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return scan_step(true, SINK, h, s, t)
}

// The paths in `set` answer the container at depth `d` that closed at `end`, which `open` opened.
@(private)
many_found :: #force_inline proc "contextless" ($SINK: Sink, h: ^Scan, set: u64, open: core.Token, end: u64, d: int) {
	when SINK == .Stream {
		for rest := set; rest != 0; rest &= rest - 1 {
			p := uint(intrinsics.count_trailing_zeros(rest))
			#no_bounds_check path := &h.many.paths[p]
			scan_answer(true, h, path, p, core.Answer{}, 2 * open.lo, open, end, d - path.n)
		}
	}
}

// Gives `on` what is known.
@(private)
many_flush :: proc "contextless" (h: ^Scan) {
	m := h.many
	context = m.ctx
	for m.flushed < m.n_placed {
		a := &m.placed[m.flushed]
		if a.answer.path != DEAD {
			if !many_give(h, a^) {
				return
			}
		}
		m.flushed += 1
	}
	m.flushed = 0
	m.n_placed = 0
}

// Calls `on` for one answer. Returning false stops the read.
@(private = "file")
many_give :: proc(h: ^Scan, a: Placed) -> bool {
	m := h.many
	lo, hi: u64
	if a.answer.outcome == .Found {
		lo, hi = core.scalar_ends(a.token)
		if a.token.kind == .Array || a.token.kind == .Map {
			hi = a.hi
		}
	}
	if m.on(m.state, core.Token_Answer{a.token, lo, hi, a.answer.path, a.answer.outcome}) {
		return true
	}
	h.stopped = true
	m.flushed = m.n_placed
	return false
}

// Gives `on` what a read held to its end. Under a limit on a late path that is everything.
@(private)
many_stream_end :: proc(h: ^Scan) {
	many_settle(h)
	many_flush(h)
}

// Takes back path `p`'s answers through the earlier match of step `k`. A step past a `Descend` is live in many
// containers at once, so its answers are told by their chain back to the container's open, and a mark per step would
// not do. That walk is quadratic in a container's repeats of a key beside other paths' answers.
@(private, cold)
many_take_back :: proc "contextless" (m: ^Scan_Many, f: ^Many_Frame, path: ^Scan_Path, p: uint, k, d: int) {
	if path.descend < 0 || k < path.descend {
		#no_bounds_check for i in m.marks[path.marks + k] ..< m.n_placed {
			if a := &m.placed[i]; a.answer.path == u32(p) {
				a.answer.path = DEAD
				path.count -= 1
				m.dead += 1
			}
		}
		return
	}
	chain := u32(d - 1 - k)
	#no_bounds_check for i := m.n_placed - 1; i >= 0 && m.placed[i].pos > f.open_pos; i -= 1 {
		if a := &m.placed[i]; a.answer.path == u32(p) && a.chain == chain {
			a.answer.path = DEAD
			path.count -= 1
			m.dead += 1
		}
	}
}

// Runs `scan_arrive` for every path that picked the coming value, a `Descend` path at each step it picked it. Returns the
// paths that go on inside it.
@(private)
many_arrivals :: #force_inline proc "contextless" ($SINK: Sink, h: ^Scan, t: core.Token, d: int, at, owner: core.Node_Index, pos: u64) -> (child: u64) {
	m := h.many
	m.keep = false
	m.ended = 0
	for set := h.next; set != 0; set &= set - 1 {
		p := uint(intrinsics.count_trailing_zeros(set))
		#no_bounds_check path := &m.paths[p]
		if path.deep < 0 {
			if scan_arrive(true, SINK, h, path, p, d, d, t, at, owner, pos) {
				child |= 1 << p
			}
			continue
		}
		#no_bounds_check bits := m.next_deep[path.deep]
		#no_bounds_check m.next_deep[path.deep] = 0
		live: u64
		if bits >> uint(path.descend) & 1 != 0 {
			bits |= 2 << uint(path.descend)
			bits &~= 1 << uint(path.descend)
			if t.kind > .Plain {
				live = 1 << uint(path.descend)
			}
		}
		for rest := bits; rest != 0; rest &= rest - 1 {
			k := int(intrinsics.count_trailing_zeros(rest))
			if scan_arrive(true, SINK, h, path, p, k, d, t, at, owner, pos) {
				live |= 1 << uint(k)
			}
		}
		if live != 0 {
			#no_bounds_check m.deep[(d + 1) * m.deeps + path.deep] = {live, 0}
			child |= 1 << p
		}
	}
	h.next = 0
	return child
}

// The negative steps of `path` live in the container at depth `d`.
@(private = "file")
ring_steps :: #force_inline proc "contextless" (h: ^Scan, path: ^Scan_Path, d: int) -> u64 {
	m := h.many
	bits := path.negative
	if path.deep >= 0 {
		#no_bounds_check bits &= m.deep[d * m.deeps + path.deep].live
	} else {
		bits &= u64(1) << uint(d - 1)
	}
	return bits
}

// Gives frame `g` the ring its armed paths' negative steps need, sized by the largest.
@(private)
many_ring_open :: #force_inline proc "contextless" (h: ^Scan, g: ^Many_Frame, d: int) {
	m := h.many
	rest := g.armed & m.ringed
	if rest == 0 {
		return
	}
	k := 0
	for ; rest != 0; rest &= rest - 1 {
		#no_bounds_check path := &m.paths[intrinsics.count_trailing_zeros(rest)]
		bits := ring_steps(h, path, d)
		for ; bits != 0; bits &= bits - 1 {
			need, delayed := step_ring(path.steps[intrinsics.count_trailing_zeros(bits)])
			k = max(k, need)
			g.delay ||= delayed
		}
	}
	if k == 0 {
		return
	}
	// An array of n elements takes 2n - 1 bytes at least, so a ring past that holds nothing more.
	k = min(k, len(h.b.doc.src) / 2 + 1)
	for int(m.ring_top) + k > len(m.rings) {
		fresh, ok := grow(h.b.doc.allocator, m.rings, int(m.ring_top) + k)
		if !ok {
			h.b.err = {kind = .No_Memory}
			return
		}
		m.rings = fresh
	}
	g.ring_k = u32(k)
	m.ring_top += u32(k)
}

// The element `index` of `count` a negative step picks, for each path armed in `f`. `offset` above 0 asks only for the
// `Slice`s with that negative end, as elements arrive, and 0 for the steps that wait for the close.
@(private = "file")
many_ring_picks :: proc "contextless" (h: ^Scan, f: ^Many_Frame, d, index, count, offset: int) {
	m := h.many
	for rest := f.armed & m.ringed; rest != 0; rest &= rest - 1 {
		p := uint(intrinsics.count_trailing_zeros(rest))
		#no_bounds_check path := &m.paths[p]
		bits := ring_steps(h, path, d)
		for ; bits != 0; bits &= bits - 1 {
			k := int(intrinsics.count_trailing_zeros(bits))
			#partial switch x in path.steps[k] {
			case core.Index:
				if offset == 0 && index == count + int(x) {
					scan_picked(true, h, path, p, k, true)
				}
			case core.Slice:
				hi := x.hi.? or_else count
				if x.lo >= 0 {
					if offset > 0 && hi == -offset && index >= x.lo {
						scan_picked(true, h, path, p, k, true)
					}
				} else if offset == 0 && index >= count + x.lo && index < (hi if hi >= 0 else count + hi) {
					scan_picked(true, h, path, p, k, true)
				}
			}
		}
	}
}

// Feeds the elements a `Slice` with a negative end has learned are in it, now that element `i` has arrived.
@(private)
many_delayed :: proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, f: ^Many_Frame, d: int) -> core.Hook_Regs {
	s := s
	i := int(u32(s.b))
	for offset in 1 ..= min(int(f.ring_k), i) {
		many_ring_picks(h, f, d, i - offset, 0, offset)
		if h.next != 0 {
			s = many_feed(SINK, h, s, f, d, i - offset)
			if h.stopped {
				break
			}
		}
	}
	return s
}

// Gives the logic ring element `index` again, its picks made. A container is read again from its first byte, and only
// a value that reaches the end of a path is read twice for no step.
@(private = "file")
many_feed :: proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, f: ^Many_Frame, d, index: int) -> core.Hook_Regs {
	m := h.many
	s := s
	#no_bounds_check e := m.rings[f.ring + u32(index) % f.ring_k]
	saved := s.b
	s.b = s.b >> 32 << 32 | u64(index)
	if e.key.role == .Key {
		m.key, m.key_at, m.has_key = e.key, e.key_at, true
	}
	at := h.at
	h.at = e.at
	if e.value.kind <= .Plain {
		s, _ = scan_reach(true, SINK, h, s, e.value, f, d)
	} else {
		m.feeding = true
		h.rewalk(h, &s, e.value.lo, e.at)
	}
	h.at = at
	if !h.stopped {
		s.b = saved
	}
	return s
}

// The elements a ring's close resolves, oldest first, then the steps past the end.
@(private)
many_close_ring :: #force_inline proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, f: ^Many_Frame, d, count: int) -> core.Hook_Regs {
	s := s
	if f.ring_k != 0 {
		for i in max(count - int(f.ring_k), 0) ..< count {
			many_ring_picks(h, f, d, i, count, 0)
			if h.next != 0 {
				s = many_feed(SINK, h, s, f, d, i)
				if h.stopped {
					break
				}
			}
		}
	}
	return s
}

// Runs `scan_missed` for every step live in the container closing at depth `d`.
@(private)
many_misses :: #force_inline proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, d, count: int) {
	m := h.many
	open := core.Node_Index(s.b >> 32)
	pos := t.lo << 32 | u64(1 << 31 - d) when SINK == .Replay else 2 * t.lo + 1
	for set := f.armed; set != 0; set &= set - 1 {
		p := uint(intrinsics.count_trailing_zeros(set))
		#no_bounds_check path := &m.paths[p]
		if path.deep < 0 {
			scan_missed(true, SINK, h, f, path, p, d - 1, f.matched >> p & 1 != 0, count, open, pos, t, d)
		} else {
			#no_bounds_check row := m.deep[d * m.deeps + path.deep]
			for bits := row.live; bits != 0; bits &= bits - 1 {
				k := int(intrinsics.count_trailing_zeros(bits))
				scan_missed(true, SINK, h, f, path, p, k, row.matched >> uint(k) & 1 != 0, count, open, pos, t, d)
			}
		}
	}
}
