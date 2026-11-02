package build

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import core ".."

// The engine's `$MANY` form: what a read of one plain path never pays for. Up to 64 paths at once, each with its limit,
// and the steps the plain form has no state for: negative indexes, `Slice`, `Descend`, `?` and `every_key`. A frame per
// depth holds the armed paths as one `u64`, so a path with no `Descend` is at step `d - 1` of a container at depth `d`.
// A `Descend` path can be at several steps of a container at once, so it has a row of step bits per frame.

// Where the engine sends answers. `.Document` writes the partial document, `.Replay` reads a built one and writes
// nothing, `.Stream` writes nothing and calls `each_answer`'s `on`.
Sink :: enum u8 {
	Document,
	Replay,
	Stream,
}

// A tombstone for an answer a repeated key took back. It keeps the list's indexes, which the marks hold.
@(private = "file")
DEAD :: max(u32)

// The end of a found container not closed yet.
@(private = "file")
OPEN :: max(u64)

// What the most ring entries of a container, and the most steps of a `Descend` path, are bounded by.
@(private = "file")
MAX_RING :: 64

// One path of a read. The `u64` sets hold a bit per step. `multi` is the first step that can answer again and `rollback`
// the first step a repeated key can take answers back through, as in `Scan`. `late` says the path's answers can be
// known out of text order, so its limit is applied to the sorted list and its `rollback` is -1.
@(private)
Many_Path :: struct {
	steps:    []core.Step,
	n:        int,
	limit:    int,
	count:    int,
	multi:    int,
	rollback: int,
	optional: u64,
	alls:     u64,
	indexed:  u64,
	negative: u64,
	descend:  int, // the `Descend` step, -1 for none
	deep:     int, // the path's column in `Scan_Many.deep`, -1 with no `Descend`
	marks:    int, // the path's first entry in `Scan_Many.marks`
	late:     bool,
}

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
// `Slice` with a negative end feeds its elements late. `found_lo` to `found_hi` are the list's entries that wait for
// this container's end under `.Stream`.
@(private)
Many_Frame :: struct {
	armed:    u64,
	matched:  u64,
	ends:     u64,
	open_pos: u64,
	found_lo: int,
	found_hi: int,
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

// The state of a `$MANY` read. `next` holds the paths that picked the coming value, and `next_deep` the steps they
// picked it at, by `Many_Path.deep`. `ended` holds the paths whose walk ended at the value, `keep` says it is kept
// whole, and `indexed` that it needs a `Kept_Child`. `feeding` says the coming value's picks are already made.
@(private)
Scan_Many :: struct {
	paths:      []Many_Path,
	frames:     []Many_Frame,
	deep:       []Deep_Row,
	deeps:      int,
	marks:      []int,
	rings:      []Ring_Entry,
	ring_top:   u32,
	ringed:     u64,
	all:        u64,
	done:       u64,
	next:       u64,
	ended:      u64,
	next_deep:  [64]u64,
	placed:     []Placed,
	n_placed:   int,
	flushed:    int,
	flush:      int, // the depth at and above which `.Stream` may give what it holds
	key:        core.Token,
	key_at:     core.Node_Index,
	has_key:    bool,
	keep:       bool,
	indexed:    bool,
	feeding:    bool,
	last:       bool,
	every_key:  bool,
	keep_set:   u64,
	keep_lo:    int,
	keep_hi:    int,
	on:         proc(state: rawptr, a: core.Token_Answer) -> bool,
	state:      rawptr,
	ctx:        runtime.Context,
}

// Whether a read of `paths` needs the `$MANY` form.
@(private)
many_needed :: proc(paths: []core.Path, read: core.Path_Options) -> bool {
	if len(paths) != 1 || read.every_key || paths[0].optional != {} {
		return true
	}
	for step in paths[0].steps {
		switch x in step {
		case core.Index:
			if x < 0 {
				return true
			}
		case core.Slice, core.Descend:
			return true
		case core.Name, core.All, core.Either:
		}
	}
	return false
}

// The ring entries a step needs, 0 for none. `delayed` says the step feeds elements as later ones arrive.
@(private = "file")
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

// Reads `paths` and `read` into a `Scan_Many` for `h`. `depth` bounds the frames a `Descend` path opens.
@(private)
many_plan :: proc(h: ^Scan, paths: []core.Path, read: core.Path_Options, depth: int, allocator: runtime.Allocator) -> core.Path_Error {
	if len(paths) > 64 {
		return {kind = .Over_Capacity}
	}
	m := new(Scan_Many, allocator)
	h.many = m
	dups := read.dups.? or_else (core.Duplicates.First if read.stop_early else core.Duplicates.Last)
	m.last = dups == .Last && !read.every_key
	m.every_key = read.every_key
	m.flush = max(int)
	h.stop_early = read.stop_early
	h.keep = max(int)
	m.paths = make([]Many_Path, len(paths), allocator)
	frames, total := 0, 0
	for path, p in paths {
		x := &m.paths[p]
		if e := many_plan_path(m, x, path); e.kind != .None {
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
			m.next |= 1 << uint(p)
		}
		if x.deep >= 0 {
			m.next_deep[x.deep] = 1
		}
		if x.negative != 0 {
			m.ringed |= 1 << uint(p)
		}
		m.all |= 1 << uint(p)
	}
	if m.deeps > 0 {
		frames = max(frames, depth)
	}
	frames += 2
	m.frames = make([]Many_Frame, frames, allocator)
	m.marks = make([]int, total, allocator)
	if m.deeps > 0 {
		m.deep = make([]Deep_Row, frames * m.deeps, allocator)
	}
	return {}
}

@(private = "file")
many_plan_path :: proc(m: ^Scan_Many, x: ^Many_Path, path: core.Path) -> core.Path_Error {
	if len(path.steps) > core.MAX_STEPS {
		return {kind = .Over_Capacity}
	}
	x.steps = path.steps
	x.n = len(path.steps)
	x.limit = path.limit.? or_else max(int)
	x.multi, x.rollback = x.n, x.n
	x.optional = transmute(u64)path.optional
	x.descend = -1
	for step, i in path.steps {
		bit := u64(1) << uint(i)
		switch s in step {
		case core.Name, core.Either:
			if m.every_key {
				x.multi = min(x.multi, i)
			} else if m.last {
				x.multi = min(x.multi, i)
				x.rollback = min(x.rollback, i)
				// A key past a `Descend` can repeat in any container, so nothing is known before the root closes.
				m.flush = min(m.flush, i) if x.descend < 0 else -1
			}
			if _, either := s.(core.Either); either {
				x.indexed |= bit
			}
		case core.Index:
			x.indexed |= bit
		case core.All:
			x.alls |= bit
			x.multi = min(x.multi, i)
			x.indexed |= bit
		case core.Slice:
			x.indexed |= bit
			x.multi = min(x.multi, i)
		case core.Descend:
			// One `Descend` tells every answer's route by its depth less its step, and a step is a bit of a `u64`.
			if x.descend >= 0 {
				return {kind = .Bad_Path}
			}
			if x.n >= core.MAX_STEPS {
				return {kind = .Over_Capacity}
			}
			x.descend = i
			x.late = true
			x.multi = min(x.multi, i)
		}
		need, _ := step_ring(step)
		if need > MAX_RING {
			return {kind = .Over_Capacity}
		}
		if need > 0 {
			x.negative |= bit
			x.late = true
			x.multi = min(x.multi, i)
		}
	}
	if x.late {
		x.rollback = -1
		if x.limit != max(int) {
			m.flush = -1
		}
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
	h.answers = make([]core.Answer, m.n_placed, h.b.doc.allocator)
	h.n_answers = m.n_placed
	for a, i in m.placed[:m.n_placed] {
		h.answers[i] = a.answer
	}
	slice.stable_sort_by(h.missing[:h.n_missing], proc(a, b: core.Missing_Name) -> bool {
		return a.node < b.node
	})
}

// The hook of a `$MANY` read into a document.
many_hook :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return many_step(.Document, h, s, t)
}

// The hook of `each_answer`.
stream_hook :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return many_step(.Stream, h, s, t)
}

// The step logic of the `$MANY` form.
@(private)
many_step :: proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	s := s
	if t.role > .Key {
		return s, .Next
	}
	d := int(s.c)
	m := h.many
	when SINK != .Replay {
		if d > h.keep {
			return many_kept(SINK, h, s, t)
		}
	}
	if t.kind == .End {
		return many_close(SINK, h, s, t)
	}
	#no_bounds_check f := &m.frames[d]
	if t.role == .Key {
		if f.delay {
			s = many_delayed(SINK, h, s, f, d)
			if h.stopped {
				return s, .Stop
			}
		}
		m.key = t
		m.key_at = h.at
		m.has_key = true
		many_picks(SINK, h, s, t, f, d, true)
		if m.next == 0 && !f.whole && f.ring_k == 0 {
			s.b += 1
			m.has_key = false
			return s, .Skip
		}
		return s, .Next
	}
	if m.feeding {
		m.feeding = false
		return many_reach(SINK, h, s, t, f, d)
	}
	if !m.has_key && f.delay {
		s = many_delayed(SINK, h, s, f, d)
		if h.stopped {
			return s, .Stop
		}
	}
	if f.ring_k != 0 {
		i := u32(s.b) % f.ring_k
		#no_bounds_check m.rings[f.ring + i] = {m.key if m.has_key else {}, t, m.key_at, h.at}
	}
	if !m.has_key && d > 0 {
		many_picks(SINK, h, s, t, f, d, false)
	}
	return many_reach(SINK, h, s, t, f, d)
}

// A token inside a value kept whole, in which no path is armed.
@(private = "file")
many_kept :: #force_inline proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	s := s
	action := core.Action.Next
	when SINK == .Document {
		s, action = builder_step(false, true, false, false, &h.b, s, t)
	} else {
		if t.kind == .End {
			s.c -= 1
			#no_bounds_check s.b = h.b.stack[s.c]
		} else {
			s, action = scan_write(false, h, s, t)
		}
	}
	if int(s.c) == h.keep {
		d := h.keep
		m := h.many
		h.keep = max(int)
		many_found_end(SINK, m, m.keep_lo, m.keep_hi, t.lo + u64(t.n))
		return many_left(SINK, h, s, m.keep_set, d)
	}
	return s, action
}

// Gives the answers in `lo ..< hi` the end of the container they found.
@(private = "file")
many_found_end :: #force_inline proc "contextless" ($SINK: Sink, m: ^Scan_Many, lo, hi: int, end: u64) {
	when SINK == .Stream {
		for i in lo ..< hi {
			if a := &m.placed[i]; a.hi == OPEN {
				a.hi = end
			}
		}
	}
}

// A value or container is past for the paths in `set`, with the logic at depth `d`: a path that can answer no more is
// done, and a read that stops early stops when all are.
@(private = "file")
many_left :: proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, set: u64, d: int) -> (core.Hook_Regs, core.Action) {
	m := h.many
	when SINK == .Stream {
		if d <= m.flush {
			many_flush(h)
		}
	}
	if h.stop_early && !h.stopped {
		for rest := set &~ m.done; rest != 0; rest &= rest - 1 {
			p := intrinsics.count_trailing_zeros(rest)
			#no_bounds_check path := &m.paths[p]
			if d <= path.multi || path.count >= path.limit && d <= path.rollback {
				m.done |= 1 << p
			}
		}
		if m.done == m.all {
			h.stopped = true
		}
	}
	return s, .Stop if h.stopped else .Next
}

// Gives `on` what is known, up to the first found container still open.
@(private = "file")
many_flush :: proc "contextless" (h: ^Scan) {
	m := h.many
	context = m.ctx
	for m.flushed < m.n_placed {
		a := &m.placed[m.flushed]
		if a.answer.path != DEAD {
			if a.hi == OPEN {
				return
			}
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
	if m.on(m.state, core.Token_Answer{a.token, a.hi, a.answer.path, a.answer.outcome}) {
		return true
	}
	h.stopped = true
	m.flushed = m.n_placed
	return false
}

// Gives `on` what a read held to its end. Under a limit on a late path that is everything.
@(private)
many_stream_end :: proc(h: ^Scan) {
	m := h.many
	many_settle(h)
	for ; m.flushed < m.n_placed; m.flushed += 1 {
		if !many_give(h, m.placed[m.flushed]) {
			return
		}
	}
}

// Whether a path has room for another answer.
@(private = "file")
many_room :: #force_inline proc "contextless" (path: ^Many_Path) -> bool {
	return path.late || path.count < path.limit
}

// Marks that path `p` picked the coming value at step `k`.
@(private = "file")
many_pick :: #force_inline proc "contextless" (m: ^Scan_Many, path: ^Many_Path, p: uint, k: int) {
	m.next |= 1 << p
	if path.deep >= 0 {
		#no_bounds_check m.next_deep[path.deep] |= 2 << uint(k)
	}
	if path.indexed >> uint(k) & 1 != 0 {
		m.indexed = true
	}
}

// Runs every armed path's step over a key or an element.
@(private = "file")
many_picks :: #force_inline proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, d: int, keyed: bool) {
	m := h.many
	for set := f.armed; set != 0; set &= set - 1 {
		p := uint(intrinsics.count_trailing_zeros(set))
		#no_bounds_check path := &m.paths[p]
		if path.deep < 0 {
			many_step_at(SINK, h, s, t, f, path, p, d - 1, d, keyed)
		} else {
			#no_bounds_check row := &m.deep[d * m.deeps + path.deep]
			for bits := row.live; bits != 0; bits &= bits - 1 {
				many_step_at(SINK, h, s, t, f, path, p, int(intrinsics.count_trailing_zeros(bits)), d, keyed)
			}
		}
	}
}

// Runs step `k` of path `p`, which is live in the container at depth `d`, over a key or an element.
@(private = "file")
many_step_at :: proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, path: ^Many_Path, p: uint, k, d: int, keyed: bool) {
	m := h.many
	count := int(u32(s.b))
	#no_bounds_check switch x in path.steps[k] {
	case core.Name:
		if keyed {
			many_name(SINK, h, s, t, f, path, p, k, d, string(x))
		}
	case core.Either:
		if keyed {
			many_name(SINK, h, s, t, f, path, p, k, d, x.name)
		} else if count == x.index {
			many_pick(m, path, p, k)
		}
	case core.Index:
		if count == int(x) {
			many_pick(m, path, p, k)
		}
	case core.All:
		if many_room(path) {
			many_pick(m, path, p, k)
		}
	case core.Slice:
		if path.negative >> uint(k) & 1 == 0 && count >= x.lo && count < (x.hi.? or_else max(int)) {
			many_pick(m, path, p, k)
		}
	case core.Descend:
		m.next |= 1 << p
		#no_bounds_check m.next_deep[path.deep] |= 1 << uint(k)
	}
}

// Tests a `Name` step against a key. Under `.Last` a later match takes back what the earlier one answered. Its nodes
// stay in the document with no answer naming them.
@(private = "file")
many_name :: #force_inline proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, path: ^Many_Path, p: uint, k, d: int, name: string) {
	m := h.many
	matched := &f.matched
	bit := u64(1) << p
	if path.deep >= 0 {
		#no_bounds_check matched = &m.deep[d * m.deeps + path.deep].matched
		bit = 1 << uint(k)
	}
	seen := matched^ & bit != 0
	if seen && !m.last && !m.every_key || !scan_key_is(SINK != .Replay, h, s, t, name) {
		return
	}
	if seen && m.last {
		many_take_back(m, f, path, p, k, d)
	}
	matched^ |= bit
	#no_bounds_check m.marks[path.marks + k] = m.n_placed
	many_pick(m, path, p, k)
}

// Takes back path `p`'s answers through the earlier match of step `k`. A step past a `Descend` is live in many
// containers at once, so its answers are told by their chain back to the container's open, and a mark per step would
// not do. That walk is quadratic in a container's repeats of a key beside other paths' answers.
@(private = "file", cold)
many_take_back :: proc "contextless" (m: ^Scan_Many, f: ^Many_Frame, path: ^Many_Path, p: uint, k, d: int) {
	if path.descend < 0 || k < path.descend {
		#no_bounds_check for i in m.marks[path.marks + k] ..< m.n_placed {
			if a := &m.placed[i]; a.answer.path == u32(p) {
				a.answer.path = DEAD
				path.count -= 1
			}
		}
		return
	}
	chain := u32(d - 1 - k)
	#no_bounds_check for i := m.n_placed - 1; i >= 0 && m.placed[i].pos > f.open_pos; i -= 1 {
		if a := &m.placed[i]; a.answer.path == u32(p) && a.chain == chain {
			a.answer.path = DEAD
			path.count -= 1
		}
	}
}

// Whether step `k` of a path can enter a value of `kind`.
@(private = "file")
many_enters :: #force_inline proc "contextless" (h: ^Scan, path: ^Many_Path, k: int, kind: core.Kind) -> bool {
	#no_bounds_check switch _ in path.steps[k] {
	case core.Name:
		return kind == .Map
	case core.Index, core.Slice:
		return kind == .Array || kind == .Map && h.positional
	case core.All, core.Either, core.Descend:
		return kind == .Array || kind == .Map
	}
	return false
}

@(private = "file")
many_emit :: #force_inline proc "contextless" (h: ^Scan, path: ^Many_Path, p: uint, a: core.Answer, pos: u64, t: core.Token, chain: int) {
	if !many_room(path) {
		return
	}
	path.count += 1
	a := a
	a.path = u32(p)
	m := h.many
	hi := t.lo + u64(t.n) if t.kind <= .Plain || t.kind == .End else OPEN
	scan_push(h, &m.placed, &m.n_placed, Placed{pos, a, t, hi, u32(chain)})
}

// A step the value cannot take, or a member the close found missing, with `later` the steps past it. `?` drops a
// mismatch, and on a null or a missing member the mismatch belongs to the first `All` to come.
@(private = "file")
many_miss :: #force_inline proc "contextless" (path: ^Many_Path, k: int, later: u64, is_null: bool) -> (outcome: core.Answer_Outcome, dropped: bool) {
	if is_null && later == 0 {
		return .Missing, false
	}
	at := k + int(intrinsics.count_trailing_zeros(later)) if is_null else k
	return .Type_Mismatch, path.optional >> uint(at) & 1 != 0
}

// Path `p` reached a value at step `k`. Returns whether the path goes on inside it.
@(private = "file")
many_arrive :: #force_inline proc "contextless" (h: ^Scan, path: ^Many_Path, p: uint, k, d: int, t: core.Token, at, owner: core.Node_Index, pos: u64) -> bool {
	m := h.many
	if k == path.n {
		many_emit(h, path, p, core.Answer{node = at, owner = owner}, pos, t, d - k)
		m.keep = true
		m.ended |= 1 << p
		return false
	}
	if many_enters(h, path, k, t.kind) {
		return true
	}
	later := path.alls >> uint(k)
	outcome, dropped := many_miss(path, k, later, t.kind == .Null)
	m.ended |= 1 << p
	if dropped {
		return false
	}
	if outcome == .Missing {
		many_emit(h, path, p, core.Answer{node = core.NO_NODE, owner = at if owner == core.NO_NODE else owner, outcome = .Missing}, pos, t, d - k)
	} else {
		many_emit(h, path, p, core.Answer{node = core.NO_NODE, owner = at, outcome = .Type_Mismatch}, pos, t, d - k)
	}
	m.keep = true
	return false
}

// A picked value, or one nothing picked: each path that picked it answers, fails or goes on inside it.
@(private = "file")
many_reach :: proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, d: int) -> (core.Hook_Regs, core.Action) {
	WRITE :: SINK == .Document
	s := s
	m := h.many
	at := h.at
	when WRITE {
		at = core.Node_Index(s.a + (1 if m.has_key else 0))
	}
	owner := core.Node_Index(s.b >> 32)
	pos := u64(at) << 32 when SINK == .Replay else 2 * t.lo
	found_lo := m.n_placed
	child: u64
	m.keep = false
	m.ended = 0
	for set := m.next; set != 0; set &= set - 1 {
		p := uint(intrinsics.count_trailing_zeros(set))
		#no_bounds_check path := &m.paths[p]
		if path.deep < 0 {
			if many_arrive(h, path, p, d, d, t, at, owner, pos) {
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
			if many_arrive(h, path, p, k, d, t, at, owner, pos) {
				live |= 1 << uint(k)
			}
		}
		if live != 0 {
			#no_bounds_check m.deep[(d + 1) * m.deeps + path.deep] = {live, 0}
			child |= 1 << p
		}
	}
	m.next = 0
	when WRITE {
		has_key, indexed := m.has_key, m.indexed
	}
	m.indexed = false
	m.has_key = false
	whole := f.whole || m.keep && WRITE
	if child == 0 && !m.keep && !whole {
		s.b += 1
		return s, .Skip
	}
	when WRITE {
		if has_key {
			s, _ = builder_step(false, true, false, false, &h.b, s, m.key)
		}
		if indexed {
			scan_push(h, &h.kept, &h.n_kept, core.Kept_Child{at, u32(s.b)})
		}
		f.kept += 1
	}
	if child != 0 {
		s, _ = scan_write(WRITE, h, s, t)
		g := &m.frames[d + 1]
		g^ = {armed = child, ends = m.ended, open_pos = pos, whole = whole, is_map = t.kind == .Map, found_lo = found_lo, found_hi = m.n_placed, ring = m.ring_top}
		many_ring_open(h, g, d + 1)
		when WRITE {
			g.slot = u32(h.b.n_counts)
			scan_push(h, &h.b.doc.counts_alloc, &h.b.n_counts, core.Child_Count{node = at})
		}
		return s, .Next
	}
	if t.kind <= .Plain {
		s, _ = scan_write(WRITE, h, s, t)
		return many_left(SINK, h, s, m.ended, d)
	}
	when SINK == .Replay {
		s.b += 1
		left, action := many_left(SINK, h, s, m.ended, d)
		return left, .Stop if action == .Stop else .Skip
	} else {
		when SINK == .Stream {
			if !m.keep {
				s.b += 1
				return s, .Skip
			}
		}
		s, _ = scan_write(WRITE, h, s, t)
		h.keep = d
		m.keep_set = m.ended
		m.keep_lo, m.keep_hi = found_lo, m.n_placed
		return s, .Next
	}
}

// Gives frame `g` the ring its armed paths' negative steps need, sized by the largest.
@(private = "file")
many_ring_open :: #force_inline proc "contextless" (h: ^Scan, g: ^Many_Frame, d: int) {
	m := h.many
	rest := g.armed & m.ringed
	if rest == 0 {
		return
	}
	k := 0
	for ; rest != 0; rest &= rest - 1 {
		#no_bounds_check path := &m.paths[intrinsics.count_trailing_zeros(rest)]
		bits := path.negative
		if path.deep >= 0 {
			#no_bounds_check bits &= m.deep[d * m.deeps + path.deep].live
		} else {
			bits &= u64(1) << uint(d - 1)
		}
		for ; bits != 0; bits &= bits - 1 {
			need, delayed := step_ring(path.steps[intrinsics.count_trailing_zeros(bits)])
			k = max(k, need)
			g.delay ||= delayed
		}
	}
	if k == 0 {
		return
	}
	for int(m.ring_top) + k > len(m.rings) {
		fresh, ok := grow(h.b.doc.allocator, m.rings, MAX_RING)
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
many_ring_picks :: proc "contextless" (m: ^Scan_Many, f: ^Many_Frame, d, index, count, offset: int) {
	for rest := f.armed & m.ringed; rest != 0; rest &= rest - 1 {
		p := uint(intrinsics.count_trailing_zeros(rest))
		#no_bounds_check path := &m.paths[p]
		bits := path.negative
		if path.deep >= 0 {
			#no_bounds_check bits &= m.deep[d * m.deeps + path.deep].live
		} else {
			bits &= u64(1) << uint(d - 1)
		}
		for ; bits != 0; bits &= bits - 1 {
			k := int(intrinsics.count_trailing_zeros(bits))
			switch x in path.steps[k] {
			case core.Index:
				if offset == 0 && index == count + int(x) {
					many_pick(m, path, p, k)
				}
			case core.Slice:
				hi := x.hi.? or_else count
				if x.lo >= 0 {
					if offset > 0 && hi == -offset && index >= x.lo {
						many_pick(m, path, p, k)
					}
				} else if offset == 0 && index >= count + x.lo && index < (hi if hi >= 0 else count + hi) {
					many_pick(m, path, p, k)
				}
			case core.Name, core.All, core.Descend, core.Either:
			}
		}
	}
}

// Feeds the elements a `Slice` with a negative end has learned are in it, now that element `i` has arrived.
@(private = "file")
many_delayed :: proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, f: ^Many_Frame, d: int) -> core.Hook_Regs {
	m := h.many
	s := s
	i := int(u32(s.b))
	for offset in 1 ..= min(int(f.ring_k), i) {
		many_ring_picks(m, f, d, i - offset, 0, offset)
		if m.next != 0 {
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
		s, _ = many_reach(SINK, h, s, e.value, f, d)
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

// The element a ring's close resolves, oldest first, then the steps past the end, then the container's own close.
@(private = "file")
many_close :: proc "contextless" ($SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	WRITE :: SINK == .Document
	s := s
	m := h.many
	d := int(s.c)
	#no_bounds_check f := &m.frames[d]
	count := int(u32(s.b))
	if f.ring_k != 0 {
		for i in max(count - int(f.ring_k), 0) ..< count {
			many_ring_picks(m, f, d, i, count, 0)
			if m.next != 0 {
				s = many_feed(SINK, h, s, f, d, i)
				if h.stopped {
					return s, .Stop
				}
			}
		}
	}
	open := core.Node_Index(s.b >> 32)
	pos := t.lo << 32 | u64(1 << 31 - d) when SINK == .Replay else 2 * t.lo + 1
	for set := f.armed; set != 0; set &= set - 1 {
		p := uint(intrinsics.count_trailing_zeros(set))
		#no_bounds_check path := &m.paths[p]
		if path.deep < 0 {
			many_missed(SINK, h, f, path, p, d - 1, f.matched >> p & 1 != 0, count, open, pos, t, d)
		} else {
			#no_bounds_check row := m.deep[d * m.deeps + path.deep]
			for bits := row.live; bits != 0; bits &= bits - 1 {
				k := int(intrinsics.count_trailing_zeros(bits))
				many_missed(SINK, h, f, path, p, k, row.matched >> uint(k) & 1 != 0, count, open, pos, t, d)
			}
		}
	}
	when WRITE {
		if h.b.err.kind == .None {
			if int(f.kept) == count {
				builder_close_node(&h.b, int(s.a), open, u32(count))
				h.b.doc.counts_alloc[f.slot].node = core.NO_NODE
			} else {
				scan_partial(h, s, f.slot)
			}
		}
	}
	m.ring_top = f.ring
	s.c -= 1
	#no_bounds_check s.b = h.b.stack[s.c]
	many_found_end(SINK, m, f.found_lo, f.found_hi, t.lo + u64(t.n))
	return many_left(SINK, h, s, f.armed | f.ends, d - 1)
}

// A `Name` that met no key and an `Index` past either end answer at the close, since only the close knows.
@(private = "file")
many_missed :: #force_inline proc "contextless" ($SINK: Sink, h: ^Scan, f: ^Many_Frame, path: ^Many_Path, p: uint, k: int, seen: bool, count: int, open: core.Node_Index, pos: u64, t: core.Token, d: int) {
	miss, named := false, false
	name: string
	#no_bounds_check #partial switch x in path.steps[k] {
	case core.Name:
		miss, named, name = !seen, true, string(x)
	case core.Index:
		miss = int(x) >= count || count + int(x) < 0
	case core.Either:
		named, name = f.is_map, x.name
		miss = !seen if named else x.index >= count
	}
	if !miss {
		return
	}
	later := path.alls >> uint(k + 1)
	outcome, dropped := many_miss(path, k + 1, later, true)
	if !dropped {
		many_emit(h, path, p, core.Answer{node = core.NO_NODE, owner = open, outcome = outcome}, pos, t, d - k - 1)
	}
	when SINK == .Document {
		if named {
			scan_push(h, &h.missing, &h.n_missing, core.Missing_Name{open, name})
		}
	}
}
