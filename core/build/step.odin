#+private
package build

import "base:intrinsics"
import spell "../spell"
import core ".."

// The step logic.
scan_step :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	s := s
	if t.role > .Key {
		return s, .Next
	}
	d := int(s.c)
	when SINK != .Replay {
		if d > h.keep {
			return scan_inside(MANY, SINK, h, s, t)
		}
	}
	if t.kind == .End {
		return scan_close(MANY, SINK, h, s, t)
	}
	when MANY {
		m := h.many
		#no_bounds_check f := &m.frames[d]
	} else {
		f: ^Many_Frame
	}
	if t.role == .Key {
		when MANY {
			if f.delay {
				s = many_delayed(SINK, h, s, f, d)
				if h.stopped {
					return s, .Stop
				}
				#no_bounds_check f = &m.frames[d]
			}
			m.key = t
			m.key_at = h.at
			m.has_key = true
		}
		wanted: bool
		s, wanted = scan_picks(MANY, SINK, h, s, t, f, d, true)
		if scan_skips(MANY, h, f, wanted) {
			return scan_pass(MANY, h, s)
		}
		// With several paths a key waits for its value, which they may yet all refuse.
		when MANY {
			return s, .Next
		} else {
			h.next = 1
			return scan_write(SINK == .Document, h, s, t)
		}
	}
	when MANY {
		if m.feeding {
			m.feeding = false
			return scan_reach(true, SINK, h, s, t, f, d)
		}
		if !m.has_key && f.delay {
			s = many_delayed(SINK, h, s, f, d)
			if h.stopped {
				return s, .Stop
			}
			#no_bounds_check f = &m.frames[d]
		}
		if f.ring_k != 0 {
			i := u32(s.b) % f.ring_k
			#no_bounds_check m.rings[f.ring + i] = {m.key if m.has_key else {}, t, m.key_at, h.at}
		}
		element := d > 0 && !m.has_key
	} else {
		element := d > 0 && h.maps >> uint(d - 1) & 1 == 0
	}
	wanted: bool
	if element {
		s, wanted = scan_picks(MANY, SINK, h, s, t, f, d, false)
	} else {
		wanted = h.next != 0
	}
	if scan_skips(MANY, h, f, wanted) {
		return scan_pass(MANY, h, s)
	}
	return scan_reach(MANY, SINK, h, s, t, f, d)
}

// Whether the coming value goes unread: one path did not want it, or nothing of several picked or holds it.
scan_skips :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, f: ^Many_Frame, wanted: bool) -> bool {
	when MANY {
		return h.next == 0 && !f.whole && f.ring_k == 0
	} else {
		return !wanted
	}
}

scan_pass :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, s: core.Hook_Regs) -> (core.Hook_Regs, core.Action) {
	s := s
	s.b += 1
	when MANY {
		h.many.has_key = false
	}
	return s, .Skip
}

// A token inside a value kept whole, in which no path is armed.
scan_inside :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
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
	// Only a close can bring the depth back.
	if t.kind == .End && int(s.c) == h.keep {
		d := h.keep
		h.keep = h.free
		when MANY {
			m := h.many
			many_found(SINK, h, m.keep_found, m.keep_open, t.lo + u64(t.n), d)
			return scan_left(true, SINK, h, s, m.keep_set, d)
		} else {
			return scan_left(false, SINK, h, s, 0, d)
		}
	}
	return s, action
}

// Whether path `path` is past answering with the logic at depth `d`, so a read that stops early need not wait for it.
scan_known :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, path: ^Scan_Path, d: int) -> bool {
	return h.stop_early && (d <= path.multi || !scan_fits(MANY, h, path) && d <= path.rollback)
}

// A value or container is past for the paths in `set`, with the logic at depth `d`: a path that can answer no more is
// done, and a read that stops early stops when all are.
scan_left :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, set: u64, d: int) -> (core.Hook_Regs, core.Action) {
	when MANY {
		m := h.many
		when SINK == .Stream {
			if d <= h.flush {
				many_flush(h)
			}
		}
		if h.stop_early && !h.stopped {
			for rest := set &~ m.done; rest != 0; rest &= rest - 1 {
				p := intrinsics.count_trailing_zeros(rest)
				#no_bounds_check if scan_known(true, h, &m.paths[p], d) {
					m.done |= 1 << p
				}
			}
			if m.done == m.all {
				h.stopped = true
			}
		}
		return s, .Stop if h.stopped else .Next
	} else {
		if scan_known(false, h, &h.path, d) {
			h.stopped = true
			return s, .Stop
		}
		return s, .Next
	}
}

// Whether a path has room for another answer. The limit counts answers, which only a repeated key can take back.
scan_fits :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, path: ^Scan_Path) -> bool {
	when MANY {
		return path.late || path.count < path.limit
	} else {
		return h.n_answers < path.limit
	}
}

// Writes a key, a scalar or an open token. With `$WRITE` false only the open's frame is kept.
scan_write :: #force_inline proc "contextless" ($WRITE: bool, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	when WRITE {
		return builder_step(false, true, false, false, &h.b, s, t)
	} else {
		s := s
		if t.role == .Value {
			s.b += 1
			if t.kind > .Plain {
				#no_bounds_check h.b.stack[s.c] = s.b
				s.c += 1
				s.b = u64(h.at) << 32
			}
		}
		return s, .Next
	}
}

// Runs the step of every armed path over a key or an element. `wanted` is one path's answer, which `Scan.next` holds for
// several.
scan_picks :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, d: int, keyed: bool) -> (regs: core.Hook_Regs, wanted: bool) {
	s := s
	when MANY {
		m := h.many
		for set := f.armed; set != 0; set &= set - 1 {
			p := uint(intrinsics.count_trailing_zeros(set))
			#no_bounds_check path := &m.paths[p]
			if path.deep < 0 {
				s, _ = scan_pick(true, SINK, h, s, t, f, path, p, d - 1, d, keyed)
			} else {
				#no_bounds_check row := &m.deep[d * m.deeps + path.deep]
				for bits := row.live; bits != 0; bits &= bits - 1 {
					s, _ = scan_pick(true, SINK, h, s, t, f, path, p, int(intrinsics.count_trailing_zeros(bits)), d, keyed)
				}
			}
		}
		return s, false
	} else {
		return scan_pick(false, SINK, h, s, t, f, &h.path, 0, d - 1, d, keyed)
	}
}

// Runs step `k` of path `p`, live in the container at depth `d`, over a key or an element.
scan_pick :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, path: ^Scan_Path, p: uint, k, d: int, keyed: bool) -> (core.Hook_Regs, bool) {
	#no_bounds_check switch x in path.steps[k] {
	case core.Name:
		if keyed {
			return scan_name(MANY, SINK, h, s, t, f, path, p, k, d, string(x))
		}
	case core.Index_Or_Name:
		if keyed {
			return scan_name(MANY, SINK, h, s, t, f, path, p, k, d, x.name)
		}
		if int(u32(s.b)) == x.index {
			scan_picked(MANY, h, path, p, k, true)
			return s, true
		}
	case core.Index:
		if int(u32(s.b)) == int(x) {
			scan_picked(MANY, h, path, p, k, true)
			return s, true
		}
	case core.All:
		if scan_fits(MANY, h, path) {
			scan_picked(MANY, h, path, p, k, true)
			return s, true
		}
		h.cut |= 1 << uint(k)
	case core.Slice:
		when MANY {
			count := int(u32(s.b))
			if path.negative >> uint(k) & 1 == 0 && count >= x.lo && count < (x.hi.? or_else max(int)) {
				scan_picked(MANY, h, path, p, k, true)
			}
		}
	case core.Descend:
		when MANY {
			h.next |= 1 << p
			#no_bounds_check h.many.next_deep[path.deep] |= 1 << uint(k)
		}
	}
	return s, false
}

// Marks that path `p` picked the coming value at step `k`. `by_place` says it was by position, and such a child keeps a
// `Kept_Child`, where one matched by name has none.
scan_picked :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, path: ^Scan_Path, p: uint, k: int, by_place: bool) {
	when MANY {
		h.next |= 1 << p
		m := h.many
		if path.deep >= 0 {
			#no_bounds_check m.next_deep[path.deep] |= 2 << uint(k)
		}
		if by_place && path.indexed >> uint(k) & 1 != 0 {
			m.indexed = true
		}
	}
}

// Tests a `Name` step against a key. Under `.Last` a later match takes back what the earlier one answered: one path
// rewinds the lists and the nodes, and with several the nodes stay in the document with no answer naming them.
scan_name :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, path: ^Scan_Path, p: uint, k, d: int, name: string) -> (core.Hook_Regs, bool) {
	s := s
	if !scan_key_is(SINK != .Replay, h, s, t, name) {
		return s, false
	}
	when MANY {
		m := h.many
		matched := &f.matched
		bit := u64(1) << p
		if path.deep >= 0 {
			#no_bounds_check matched = &m.deep[d * m.deeps + path.deep].matched
			bit = 1 << uint(k)
		}
	} else {
		matched := &h.matched
		bit := u64(1) << uint(k)
	}
	seen := matched^ & bit != 0
	if seen && !h.last && !h.every_key {
		return s, false
	}
	when MANY {
		if seen && h.last {
			many_take_back(m, f, path, p, k, d)
		}
		#no_bounds_check m.marks[path.marks + k] = m.n_placed
	} else {
		#no_bounds_check mark := &h.marks[k]
		if seen {
			h.n_answers = mark.answers
			when SINK == .Document {
				s.a = mark.a
				h.b.n_counts = mark.counts
				h.n_kept = mark.kept
				h.n_missing = mark.missing
			}
		} else {
			mark^ = {s.a, h.n_answers, h.b.n_counts, h.n_kept, h.n_missing}
		}
	}
	matched^ |= bit
	scan_picked(MANY, h, path, p, k, false)
	return s, true
}

// Whether key token `t` reads as `name`: its bytes, unless it holds something to decode.
scan_key_is :: #force_inline proc "contextless" ($WRITE: bool, h: ^Scan, s: core.Hook_Regs, t: core.Token, name: string) -> bool {
	if t.spelling & core.SPELLING_DECODE == 0 {
		#no_bounds_check return int(t.n) == len(name) && spell.bytes_equal(h.b.doc.src[t.lo:t.lo + u64(t.n)], transmute([]u8)name)
	}
	when WRITE {
		return scan_key_decoded(h, int(s.a), t, name)
	} else {
		return core.key_equals(&h.b.doc, h.at, name)
	}
}

// Reads a key through the format's `key_equals`, which reads a node, so the token goes in the next node's slot.
@(cold)
scan_key_decoded :: #force_no_inline proc "contextless" (h: ^Scan, a: int, t: core.Token, name: string) -> bool {
	if a == len(h.b.doc.nodes) {
		builder_grow(&h.b)
		if a == len(h.b.doc.nodes) {
			return false
		}
	}
	h.b.doc.nodes[a] = t
	return core.key_equals(&h.b.doc, core.Node_Index(a), name)
}

// Gives an answer to the read's list. With several paths it waits among the placed ones for its place in the text. One
// path's steps stop picking at the limit, so only its close has to ask.
scan_answer :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, path: ^Scan_Path, p: uint, a: core.Answer, pos: u64, t: core.Token, hi: u64, chain: int) {
	when MANY {
		if !scan_fits(MANY, h, path) {
			return
		}
		path.count += 1
		a := a
		a.path = u32(p)
		m := h.many
		scan_push(h, &m.placed, &m.n_placed, Placed{pos, a, t, hi, u32(chain)})
	} else {
		scan_push(h, &h.answers, &h.n_answers, a)
	}
}

// A step the value cannot take, or a member the close found missing, with `later` the steps past it. `?` drops a
// mismatch, and on a null or a missing member the mismatch belongs to the first `All` to come, as jq's `null[]`.
scan_miss :: #force_inline proc "contextless" (path: ^Scan_Path, k: int, later: u64, is_null: bool) -> (outcome: core.Presence, dropped: bool) {
	if is_null && later == 0 {
		return .Missing, false
	}
	at := k + int(intrinsics.count_trailing_zeros(later)) if is_null else k
	return .Wrong_Kind, path.optional >> uint(at) & 1 != 0
}

// Path `p` reached a value at step `k`: the path's end, a container the next step enters, or a value it cannot. Returns
// whether the path goes on inside it.
scan_arrive :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, path: ^Scan_Path, p: uint, k, d: int, t: core.Token, at, owner: core.Node_Index, pos: u64) -> bool {
	if k == path.n {
		when MANY {
			m := h.many
			m.keep = true
			m.ended |= 1 << p
			when SINK == .Stream {
				if t.kind > .Plain {
					m.found |= 1 << p
					return false
				}
			}
		}
		scan_answer(MANY, h, path, p, core.Answer{node = at, owner = owner}, pos, t, t.lo + u64(t.n), d - k)
		return false
	}
	if scan_enters(h, path, k, t.kind) {
		return true
	}
	outcome, dropped := scan_miss(path, k, path.alls >> uint(k), t.kind == .Null)
	when MANY {
		h.many.ended |= 1 << p
	}
	if dropped {
		return false
	}
	// jq reads every step but `[]` of a null as null.
	holder := at if outcome == .Wrong_Kind || owner == core.NO_NODE else owner
	scan_answer(MANY, h, path, p, core.Answer{node = core.NO_NODE, owner = holder, outcome = outcome}, pos, t, t.lo + u64(t.n), d - k)
	when MANY {
		h.many.keep = true
	}
	return false
}

// A value the paths have reached: each answers, fails or goes on inside it.
scan_reach :: proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, d: int) -> (core.Hook_Regs, core.Action) {
	WRITE :: SINK == .Document
	s := s
	at := h.at
	when WRITE {
		at = core.Node_Index(s.a)
	}
	owner := core.Node_Index(s.b >> 32)
	when MANY {
		m := h.many
		when WRITE {
			if m.has_key {
				at += 1
			}
		}
		pos := u64(at) << 32 when SINK == .Replay else text_pos(t.lo, d, false)
		child := many_arrivals(SINK, h, t, d, at, owner, pos)
		enter := child != 0
		ended := m.ended
		has_key, keeps_place := m.has_key, m.indexed
		m.indexed = false
		m.has_key = false
		whole := f.whole || m.keep && WRITE
		if !enter && !m.keep && !whole {
			s.b += 1
			return s, .Skip
		}
		if WRITE && has_key {
			s, _ = scan_write(WRITE, h, s, m.key)
		}
		if WRITE {
			f.kept += 1
		}
	} else {
		h.next = 0
		keeps_place := false
		if WRITE && d > 0 && (h.path.indexed &~ h.matched) >> uint(d - 1) & 1 != 0 {
			scan_push(h, &h.kept, &h.n_kept, core.Kept_Child{at, u32(s.b)})
		}
		enter := scan_arrive(false, SINK, h, &h.path, 0, d, d, t, at, owner, 0)
		ended := u64(0)
	}
	if WRITE && keeps_place {
		scan_push(h, &h.kept, &h.n_kept, core.Kept_Child{at, u32(s.b)})
	}
	if !enter {
		return scan_past(MANY, SINK, h, s, t, ended, d)
	}
	s, _ = scan_write(WRITE, h, s, t)
	when MANY {
		g := &m.frames[d + 1]
		g^ = {armed = child, ends = ended, found = m.found, open = t, open_pos = pos, whole = whole, is_map = t.kind == .Object, ring = m.ring_top}
		m.found = 0
		many_ring_open(h, g, d + 1)
	} else {
		bit := u64(1) << uint(d)
		h.matched &~= bit
		h.cut &~= bit
		h.maps = h.maps | bit if t.kind == .Object else h.maps &~ bit
	}
	when WRITE {
		when MANY {
			g.slot = u32(h.b.n_counts)
		} else {
			#no_bounds_check h.slots[d] = u32(h.b.n_counts)
		}
		scan_push(h, &h.b.doc.counts_alloc, &h.b.n_counts, core.Child_Count{node = at})
	}
	return s, .Next
}

// Goes on past a value kept whole, the paths in `set` done with it. With `.Replay` it is stepped over, since its nodes are
// already held.
scan_past :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, set: u64, d: int) -> (core.Hook_Regs, core.Action) {
	s := s
	when SINK == .Replay {
		s.b += 1
		left, action := scan_left(MANY, SINK, h, s, set, d)
		return left, .Stop if action == .Stop else .Skip
	} else {
		when SINK == .Stream {
			if t.kind > .Plain && !h.many.keep {
				s.b += 1
				return s, .Skip
			}
		}
		action: core.Action
		s, action = scan_write(SINK == .Document, h, s, t)
		if action != .Next {
			return s, action
		}
		if t.kind <= .Plain {
			return scan_left(MANY, SINK, h, s, set, d)
		}
		h.keep = d
		when MANY {
			m := h.many
			m.keep_set = set
			m.keep_found, m.keep_open = m.found, t
			m.found = 0
			return s, .Next
		} else {
			return s, .Keep
		}
	}
}

// Whether step `k` of a path can enter a value of `kind`.
scan_enters :: #force_inline proc "contextless" (h: ^Scan, path: ^Scan_Path, k: int, kind: core.Kind) -> bool {
	#no_bounds_check switch _ in path.steps[k] {
	case core.Name:
		return kind == .Object
	case core.Index, core.Slice:
		return kind == .Array || kind == .Object && h.positional
	case core.All, core.Index_Or_Name, core.Descend:
		return kind == .Array || kind == .Object
	}
	return false
}

// A `Name` that met no key and an `Index` past either end answer at the close, since only the close knows. Returns whether
// the step missed.
scan_missed :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, f: ^Many_Frame, path: ^Scan_Path, p: uint, k: int, seen: bool, count: int, open: core.Node_Index, pos: u64, t: core.Token, d: int) -> bool {
	miss, named := false, false
	name: string
	#no_bounds_check #partial switch x in path.steps[k] {
	case core.Name:
		miss, named, name = !seen, true, string(x)
	case core.Index:
		miss = int(x) >= count || count + int(x) < 0
	case core.Index_Or_Name:
		when MANY {
			named = f.is_map
		} else {
			named = h.maps >> uint(k) & 1 != 0
		}
		name = x.name
		miss = !seen if named else x.index >= count
	}
	if !miss {
		return false
	}
	outcome, dropped := scan_miss(path, k + 1, path.alls >> uint(k + 1), true)
	if !dropped && scan_fits(MANY, h, path) {
		scan_answer(MANY, h, path, p, core.Answer{node = core.NO_NODE, owner = open, outcome = outcome}, pos, t, t.lo + u64(t.n), d - k - 1)
	}
	when SINK == .Document {
		if named {
			scan_push(h, &h.missing, &h.n_missing, core.Missing_Name{open, name})
		}
	}
	return true
}

// A path container closes, and its true count is known.
scan_close :: proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	s := s
	d := int(s.c)
	count := int(u32(s.b))
	when MANY {
		m := h.many
		#no_bounds_check f := &m.frames[d]
		s = many_close_ring(SINK, h, s, f, d, count)
		if h.stopped {
			return s, .Stop
		}
		#no_bounds_check f = &m.frames[d]
		many_misses(SINK, h, s, t, f, d, count)
		whole := int(f.kept) == count
		slot := f.slot
	} else {
		bit := u64(1) << uint(d - 1)
		miss := scan_missed(false, SINK, h, nil, &h.path, 0, d - 1, h.matched & bit != 0, count, core.Node_Index(s.b >> 32), 0, t, d)
		kept := count if h.path.alls & bit != 0 else (0 if miss else 1)
		whole := h.cut & bit == 0 && kept == count
		#no_bounds_check slot := h.slots[d - 1]
	}
	if SINK == .Document && h.b.err.kind == .None {
		if whole {
			builder_close_node(&h.b, int(s.a), core.Node_Index(s.b >> 32), u32(count))
			h.b.doc.counts_alloc[slot].node = core.NO_NODE
		} else {
			scan_partial(h, s, slot)
		}
	}
	s.c -= 1
	#no_bounds_check s.b = h.b.stack[s.c]
	when MANY {
		m.ring_top = f.ring
		many_found(SINK, h, f.found, f.open, t.lo + u64(t.n), d - 1)
		return scan_left(true, SINK, h, s, f.armed | f.ends, d - 1)
	} else {
		return scan_left(false, SINK, h, s, 0, d - 1)
	}
}

// Closes the open container of `s` as `Partial`, its true count in its slot.
scan_partial :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, slot: u32) {
	open := core.Node_Index(s.b >> 32)
	#no_bounds_check {
		n := &h.b.doc.nodes[open]
		n.n = u32(int(s.a) - int(open))
		n.spelling = core.MAX_CHILDREN
		n.role = .Partial
		h.b.doc.counts_alloc[slot].count = u32(s.b)
	}
}

// Doubles a list of a read. Answers leave `first` for the allocator, and `first` stays with the `Scan`.
@(cold)
scan_grow :: #force_no_inline proc "contextless" (h: ^Scan, list: []$T) -> ([]T, bool) {
	when T == core.Answer {
		if raw_data(list) == &h.first[0] {
			fresh, ok := grow(h.b.doc.allocator, ([]T)(nil), 2 * len(list))
			if ok {
				copy(fresh, list)
			}
			return fresh, ok
		}
	}
	return grow(h.b.doc.allocator, list, 8)
}

// Appends `v` to a list of a read. A refused growth is held in the builder's error, which ends the read, and drops `v`.
scan_push :: #force_inline proc "contextless" (h: ^Scan, list: ^[]$T, n: ^int, v: T) {
	if n^ == len(list^) {
		fresh, ok := scan_grow(h, list^)
		if !ok {
			if h.b.err.kind == .None {
				h.b.err = {kind = .No_Memory}
			}
			return
		}
		list^ = fresh
	}
	#no_bounds_check list[n^] = v
	n^ += 1
}
