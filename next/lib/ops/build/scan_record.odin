package build

import "stury:lib/core/hook"
import "stury:lib/core/tape"

// `.Columns` fixed-record replay for `Scanner`: learns the first record of a `fixed` walk and replays later records
// without frames or per-cell tokens.

@(private)
Scan_Record_Flag :: enum u8 {
	Ready, // the later records are replayed
	Tried, // the first record closed
	On,    // the open record replays it, with its cells in `Scanner.replay.cells` while `replays`, else as tokens
}

@(private)
Scan_Record_Flags :: bit_set[Scan_Record_Flag; u8]

// The first record of the root array of a `fixed` walk, closed, when each later record makes what it made: a node for
// the record, the key and value of each column it took, and the answers and missing names it made, at nodes `size`
// on from the record before. Those answers and names are all the scan's lists hold, and the later records' are made
// from them in `scan_lists`. A replayed record pushes no frame, and the walk gives its cells with no token, which its
// `End` makes.
@(private)
Scan_Record :: struct {
	lo:       u64, // while `replays`, the open record's first byte
	open:     tape.Node_Index, // the first record's node
	size:     u32, // its nodes
	answers:  u32, // the answers it made
	missing:  u32, // the missing names it recorded
	replayed: u32, // the records after it, each replaying it
	spelling: u16, // its node's spelling once closed
	flags:    Scan_Record_Flags,
	_pad:     u8,
}

#assert(size_of(Scan_Record) == 32)

// Opens a record that replays the first record, which the root counts, with no frame. When its nodes fit the room,
// none of them grows it, so its cells come with no token and its nodes are stored at its `End`. Otherwise its node is
// stored now and its cells come as tokens, so the room grows at the token whose node finds it full, as it does for a
// record read whole.
@(private)
scan_record_open :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	h.frames.data[0].count += 1
	h.record.flags += {.On}
	if s.a + u64(h.record.size) * size_of(tape.Node) <= h.b.end {
		h.replay.replays, h.replay.given, h.record.lo = true, 0, t.lo
		return s, .Next
	}
	return scan_record_grows(h, s, t)
}

@(private = "file", cold)
scan_record_grows :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	opened, action := builder_step(&h.b, s, t, false, true)
	return opened, .Stop if action == .Stop else .Next
}

// Takes key or value `t` of a replayed record whose cells come as tokens: a value stores its key's node and its own.
@(private, cold)
scan_record_token :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role == .Key {
		h.key = t
		h.key.spelling = tape.without_credit(h.key.spelling)
		h.has_key = true
		return s, .Next
	}
	s := s
	s, _ = builder_step(&h.b, s, h.key, false, true)
	h.has_key = false
	s, _ = builder_step(&h.b, s, t, false, true)
	return s, .Stop if h.b.err != nil else .Next
}

// Closes a replayed record as the first record's close made it: the record's node closed, after the key's and the
// value's node of each column, which are stored here when the walk gave the cells in `Scanner.replay.cells`.
@(private)
scan_record_close :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	r := &h.record
	h.dropped = 0
	r.flags -= {.On}
	r.replayed += 1
	if h.replay.replays {
		h.replay.replays = false
		h.b.closed = builder_cursor(&h.b, s)
		nodes := ([^]tape.Node)(uintptr(s.a))
		nodes[0] = {r.lo, r.size, .Object, .Value, r.spelling}
		first := h.b.doc.nodes[r.open:]
		for c in 0 ..< r.size / 2 {
			nodes[1 + 2 * c] = first[1 + 2 * c]
			nodes[2 + 2 * c] = h.replay.cells[c]
		}
		s.a += u64(r.size) * size_of(tape.Node)
		s.b += 1
		return s, .Next
	}
	open := tape.Node_Index(s.b >> 32)
	node := &h.b.doc.nodes[open]
	node.n = r.size
	node.spelling = r.spelling
	h.b.closed = open
	s.c -= 1
	s.b = h.b.stack[s.c]
	return s, .Next
}

// Keeps the first record of the root array, frame `f`, closed at node `open` with its nodes up to `end`, for the later
// records to replay, when each makes what it made: the walk is `fixed`, the root opens their frames again, and no
// answer depends on a cell's kind or on what the records before it settled.
@(private, cold)
scan_learn_record :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, open, end: tape.Node_Index) #no_bounds_check {
	h.record.flags += {.Tried}
	// Without limits a path settles by its depth only, so a record that settled none leaves the later ones none to
	// settle.
	if !h.replay.fixed || h.facts || h.made != nil || h.pending != len(h.demand.paths) || .Stopped in h.flags || h.end_of != .None || h.b.err != nil {
		return
	}
	// The columns from `hook.COLUMN_BITS` on share a bit, so a record wider than that may be given the keys of columns
	// it did not take, and a record the walk replays gives at most that many cells.
	if .Passes not_in f.flags || f.count > hook.COLUMN_BITS || h.frames.len != 2 || h.kept.len != 0 {
		return
	}
	// The root opens every later record's frame again, and its close makes no answer, so the later records' answers
	// follow the first's in the scan's lists.
	root := h.frames.data[0]
	if .Object in root.flags || root.element != .Object || .Uniform not_in root.flags || root.unmet != 0 {
		return
	}
	dm := h.demand
	for n in h.live.data[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			#partial switch _ in edge.step {
			case tape.Name, tape.All:
				// A step into a cell answers by the cell's kind.
				if dm.nodes[edge.to].n_edges != 0 {
					return
				}
			}
		}
	}
	// Every answer and missing name so far is the record's, made in the order of its nodes.
	pos := u64(0)
	for a in list_slice(h.answers) {
		if a.node < open || a.node >= end || a.pos < pos {
			return
		}
		pos = a.pos
	}
	for m in list_slice(h.missing) {
		if m.node != open {
			return
		}
	}
	// Its nodes are the key and value of each column it took.
	if (end - open) % 2 != 1 || int(end - open) / 2 > len(h.replay.cells) {
		return
	}
	for k := open + 1; k < end; k += 2 {
		if h.b.doc.nodes[k].role != .Key || h.b.doc.nodes[k + 1].kind > .Plain {
			return
		}
	}
	h.record = {
		open = open,
		size = u32(end - open),
		spelling = h.b.doc.nodes[open].spelling,
		answers = h.answers.len,
		missing = h.missing.len,
		flags = {.Ready, .Tried},
	}
}
