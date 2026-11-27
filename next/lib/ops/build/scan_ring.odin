package build

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Negative-index and slice-from-end ring tracking, element dropping, and rewalk replay for `Scanner`.

// Takes the demand nodes that pick element `index`, whose token is `t`, of the array `f` at depth `d`. Returns whether
// the walk goes on, which a refused growth or a stop at a cut ends.
@(private)
scan_element :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, f: ^Scan_Frame, index: u64, t: tape.Token, d: u64) -> (hook.Regs, bool) #no_bounds_check {
	s := s
	dm := h.demand
	h.picks.len = 0
	h.flags -= {.By_Place}
	// A replaying array's steps are all from the end, and pick at its close.
	replays := .Replays in f.flags
	live := h.live.data[f.live:][:f.n_live] if !replays else nil
	for n in live {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			#partial switch step in edge.step {
			case tape.Index:
				// Every element a negative index may take is kept, and the answers of those it does not take go, unless
				// the array replays the ones it takes.
				if step < 0 && !replays || u64(step) == index {
					scan_put(&h.picks, edge.to)
					h.flags += {.By_Place}
				}
			case tape.All:
				if tape.all_takes(step.limit, index, false, h.dups) {
					scan_put(&h.picks, edge.to)
					// A step or path limit leaves the array partial, so each element it keeps holds its place.
					if step.limit > 0 || h.demand.limited {
						h.flags += {.By_Place}
					}
				} else if .Settles in h.flags && index == u64(step.limit) && !scan_cut(h, edge.to, d) {
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
	if f.u.arr.ring_k == 0 {
		return s, true
	}
	// The ring is at the end of its list while the elements arrive, because an inner frame's close cuts the list back,
	// so it grows with the elements up to its size.
	k := u64(f.u.arr.ring_k)
	slot := f.u.arr.ring + u32(index % k)
	if replays {
		if index >= k {
			h.tokens.data[slot] = t
			return s, true
		}
		scan_push(h, &h.tokens, t)
		return s, h.b.err == nil
	}
	// Slices from the end pick here, except in a replaying array, whose slices are all from the end and pick at its
	// close.
	if .Slices in f.flags && !scan_slice_picks(h, f, index, d) {
		return s, false
	}
	if index < k {
		scan_push(h, &h.ring, scan_ring_mark(h, s))
		return s, h.b.err == nil
	}
	// Element `index - k` passes out of the ring, so no negative index takes it.
	next := h.ring.data[f.u.arr.ring + u32((index + 1) % k)]
	hi := int(h.answers.len) if k == 1 else int(next.answers)
	scan_kill_negatives(h, f, int(h.ring.data[slot].answers), hi, max(u64))
	if .Drops in f.flags {
		s = scan_drop(h, s, f, h.ring.data[slot], builder_cursor(&h.b, s) if k == 1 else tape.Node_Index(next.node))
	}
	h.ring.data[slot] = scan_ring_mark(h, s)
	return s, true
}

@(private = "file", require_results)
scan_ring_mark :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs) -> Scan_Ring {
	return {h.answers.len, u32(builder_cursor(&h.b, s)), h.kept.len, h.missing.len, u32(len(h.b.counts)), u32(len(h.b.doc.facts))}
}

// Whether the node `at` names stays when nodes `[lo, hi)` are dropped. Moves it down past the dropped nodes.
@(private = "file", require_results)
scan_node_moved :: #force_inline proc "contextless" (at: ^tape.Node_Index, lo, hi: tape.Node_Index) -> bool {
	if at^ == tape.NO_NODE || at^ < lo {
		return true
	}
	if at^ < hi {
		return false
	}
	at^ -= hi - lo
	return true
}

// Drops the element of the array `f` whose nodes run from `from.node` to `hi`, and what the scan holds of them, from
// the list lengths `from` records. The nodes past them move down, with every entry that names one, and so do the ring
// entries of the array's later elements.
@(private = "file", cold)
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
	for &a in h.answers.data[from.answers:h.answers.len] {
		if a.pos >= 2 * u64(hi) {
			a.pos -= 2 * u64(gone)
		} else if a.pos >= 2 * u64(lo) && !a.dead {
			a.dead = true
			if h.made != nil && h.demand.paths[a.path].limit > 0 {
				h.made[a.path] -= 1
			}
		}
		if a.node >= hi {
			a.node -= gone
		}
	}
	compact_nodes :: #force_inline proc "contextless" (items: []$T, lo, hi: tape.Node_Index) -> int #no_bounds_check {
		w := 0
		for item in items {
			item := item
			if scan_node_moved(&item.node, lo, hi) {
				items[w] = item
				w += 1
			}
		}
		return w
	}
	kept := int(from.kept) + compact_nodes(h.kept.data[from.kept:h.kept.len], lo, hi)
	missing := int(from.missing) + compact_nodes(h.missing.data[from.missing:h.missing.len], lo, hi)
	counts := int(from.counts) + compact_nodes(h.b.counts[from.counts:], lo, hi)
	gone_kept, gone_missing, gone_counts := h.kept.len - u32(kept), h.missing.len - u32(missing), u32(len(h.b.counts) - counts)
	h.kept.len = u32(kept)
	h.missing.len = u32(missing)
	(^runtime.Raw_Dynamic_Array)(&h.b.counts).len = counts
	// Leading facts before element 0 arrive before `scan_ring_mark` records `from.facts`; rewind over them.
	facts_from := int(from.facts)
	for facts_from > 0 && h.b.doc.facts[facts_from - 1].node >= lo {
		facts_from -= 1
	}
	for &fact in h.b.doc.facts[facts_from:] {
		if !scan_node_moved(&fact.node, lo, hi) {
			fact.node = tape.NO_NODE
		}
	}
	if !scan_node_moved(&h.b.closed, lo, hi) {
		h.b.closed = tape.NO_NODE
	}
	if !scan_node_moved(&h.passed, lo, hi) {
		h.passed = tape.NO_NODE
	}
	if !scan_node_moved(&h.wait_at, lo, hi) {
		h.wait_at = tape.NO_NODE
	}
	for &r in h.ring.data[f.u.arr.ring:h.ring.len] {
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
// Runs in O(len(answers) - from + len(ring) + len(marks)).
@(private = "file")
scan_shed :: proc "contextless" (h: ^Scanner, from: int) #no_bounds_check {
	answers := list_slice(h.answers)
	first_dead, last_dead := len(answers), -1
	total_dead := u32(0)
	for i in from ..< len(answers) {
		if answers[i].dead {
			if first_dead == len(answers) {
				first_dead = i
			}
			last_dead = i
			total_dead += 1
		}
	}
	if total_dead == 0 {
		return
	}
	contiguous := total_dead == u32(last_dead - first_dead + 1)
	prefix_buf: [512]u32 = ---
	prefix: []u32
	prefix_alloc := false
	if !contiguous {
		span := last_dead - first_dead + 1
		if span <= len(prefix_buf) {
			prefix = prefix_buf[:span]
		} else if h.scratch.procedure != nil {
			context = h.b.ctx
			if raw, err := runtime.mem_alloc_non_zeroed(span * size_of(u32), align_of(u32), h.scratch); took(err, raw_data(raw), span) == nil {
				prefix = ([^]u32)(raw_data(raw))[:span]
				prefix_alloc = true
			}
		}
		if len(prefix) > 0 {
			acc := u32(0)
			for i in 0 ..< span {
				prefix[i] = acc
				acc += u32(answers[first_dead + i].dead)
			}
		}
	}
	defer if prefix_alloc {
		context = h.b.ctx
		runtime.mem_free_with_size(raw_data(prefix), len(prefix) * size_of(u32), h.scratch)
	}
	dead_before :: #force_inline proc "contextless" (answers: []Scan_Answer, first_dead, last_dead: int, total_dead: u32, contiguous: bool, prefix: []u32, at: int) -> u32 #no_bounds_check {
		if at <= first_dead {
			return 0
		}
		if at > last_dead {
			return total_dead
		}
		if contiguous {
			return u32(at - first_dead)
		}
		if len(prefix) > 0 {
			return prefix[at - first_dead]
		}
		n := u32(0)
		for a in answers[first_dead:at] {
			n += u32(a.dead)
		}
		return n
	}
	for &r in list_slice(h.ring) {
		if int(r.answers) > first_dead {
			r.answers -= dead_before(answers, first_dead, last_dead, total_dead, contiguous, prefix, int(r.answers))
		}
	}
	for &m in h.marks {
		if at := int(u32(m)); at > first_dead {
			m -= u64(dead_before(answers, first_dead, last_dead, total_dead, contiguous, prefix, at))
		}
	}
	n := first_dead
	for a in answers[first_dead:] {
		if !a.dead {
			answers[n] = a
			n += 1
		}
	}
	h.answers.len = u32(n)
}

// Whether a step from the end of the array `f`, which has `f.count` elements, takes element `e`.
@(private = "file", require_results)
scan_ring_takes :: proc "contextless" (h: ^Scanner, f: ^Scan_Frame, e: u64) -> bool #no_bounds_check {
	dm := h.demand
	for n in h.live.data[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			if tape.child_takes(edge.step, e, f.count, false, h.dups) {
				return true
			}
		}
	}
	return false
}

// Takes the demand nodes the `Slice` steps from the end of the array `f` at depth `d` pick for element `index`.
@(private = "file")
scan_slice_picks :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, index: u64, d: u64) -> bool #no_bounds_check {
	dm := h.demand
	for n in h.live.data[f.live:][:f.n_live] {
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
// the last element it can take, under `.Settles`, the paths through it that settle there are done. Returns whether the
// walk goes on.
@(private = "file")
scan_slice_pick :: #force_inline proc "contextless" (h: ^Scanner, step: tape.Slice, index: u64, to: u32, d: u64) -> bool {
	if tape.slice_takes(step, index, 0) {
		scan_put(&h.picks, to)
		h.flags += {.By_Place}
		return true
	}
	return .Settles not_in h.flags || index != tape.slice_cut(step) || scan_cut(h, to, d)
}

// Settles, under `.Settles`, the paths through demand node `to` that a positional step at depth `d` takes no more
// elements for. Returns whether the scan takes more tokens.
@(private = "file", cold)
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

// Takes back the answers from `lo` to `hi`, those of element `element` of the array `f`, that came through a step
// from the end that does not take it. `count` is the array's length, 0 while unknown. An element that has passed out of
// every reach from the end (`element` is `max(u64)`) is kept only by a `Slice` that starts from the start.
@(private = "file")
scan_kill_negatives :: proc "contextless" (h: ^Scanner, f: ^Scan_Frame, lo, hi: int, element: u64, count: u64 = 0) #no_bounds_check {
	dm := h.demand
	for n in h.live.data[f.live:][:f.n_live] {
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

// Settles the elements the ring of the closing array at depth `d` holds, now that its count is known: reads again those
// a negative index of a replaying array takes, and else takes back the answers of those no step from the end takes, and
// drops their nodes when the array `.Drops`. True when a read again ended the scan's keeping.
@(private, cold)
scan_close_ring :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, d: u64) -> (hook.Regs, bool) #no_bounds_check {
	s := s
	f := &h.frames.data[d - 1]
	k := u64(f.u.arr.ring_k)
	if .Replays in f.flags {
		for e in max(f.count, k) - k ..< f.count {
			s = scan_replay(h, s, f, e)
			f = &h.frames.data[d - 1]
			if .Stopped in h.flags || h.end_of == .Settled || h.b.err != nil {
				return s, true
			}
		}
		return s, false
	}
	for e in max(f.count, k) - k ..< f.count {
		hi := int(h.answers.len) if e + 1 == f.count else int(h.ring.data[f.u.arr.ring + u32((e + 1) % k)].answers)
		scan_kill_negatives(h, f, int(h.ring.data[f.u.arr.ring + u32(e % k)].answers), hi, e, f.count)
	}
	if .Drops in f.flags {
		// Backwards, so the nodes of an element are where its ring entry says.
		for e := f.count; e > max(f.count, k) - k; {
			e -= 1
			if !scan_ring_takes(h, f, e) {
				hi := builder_cursor(&h.b, s) if e + 1 == f.count else tape.Node_Index(h.ring.data[f.u.arr.ring + u32((e + 1) % k)].node)
				s = scan_drop(h, s, f, h.ring.data[f.u.arr.ring + u32(e % k)], hi)
			}
		}
	}
	return s, false
}

// Reads element `e` of the replaying array `f` again when a negative index takes it, now that its count is known.
@(private = "file")
scan_replay :: proc "contextless" (h: ^Scanner, s: hook.Regs, f: ^Scan_Frame, e: u64) -> hook.Regs #no_bounds_check {
	s := s
	dm := h.demand
	h.picks.len = 0
	// Its positional steps are all from the end, as it replays.
	for n in h.live.data[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			if tape.child_takes(edge.step, e, f.count, false, h.dups) {
				scan_put(&h.picks, edge.to)
			}
		}
	}
	if h.picks.len == 0 {
		return s
	}
	h.flags += {.By_Place, .Forced}
	h.forced_at = e
	t := h.tokens.data[f.u.arr.ring + u32(e % u64(f.u.arr.ring_k))]
	if t.kind <= .Plain {
		s, _ = scanner_value(h, s, t, true)
		return s
	}
	h.flags += {.Replaying}
	// The first walk judged the element, so the walk read again fails only for want of memory.
	if r := h.rewalk(h, &s, t.lo); u8(r) == hook.WALK_NO_MEMORY && h.b.err == nil {
		h.b.err = .Out_Of_Memory
	}
	h.flags -= {.Replaying, .Forced, .By_Place}
	return s
}
