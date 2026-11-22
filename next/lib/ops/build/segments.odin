package build

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// A part of one text's build, which a builder of its own makes from a seam: a place past a comma inside containers
// opened before it. Builds of a text's parts run at once into one room for nodes and one for facts, each from the
// place the one build stores its first node and fact at, and join into the document one build makes.
//
// A segment that starts inside containers has a node past every segment's nodes for each, outermost first, where the
// builder writes the subtree size and child count of each that closes in the part, and one node for the value completed
// before the seam, which an inline comment at the part's start belongs to.
Segment :: struct {
	b:          Builder,
	allocator:  runtime.Allocator, // what its counts were allocated with, as its builder's refuses every block
	regs:       hook.Regs, // the builder's registers where its walk ended
	depth:      int, // the containers open at its seam
	first:      int, // the node its walk stores first
	scratch:    int, // the node of the outermost container open at its seam
	containers: int, // its containers of its own, counted for `Budget.steps`
	// Set by the join: its first node and fact in the document, the node of the value before its seam and the nodes
	// of the containers open at its seam, outermost first.
	at, fact:   int,
	before:     tape.Node_Index,
	seam:       []tape.Node_Index,
}

// The node in a segment's room that stands for the value completed before its seam.
@(private)
segment_before :: #force_inline proc "contextless" (s: ^Segment) -> int {
	return s.scratch + s.depth
}

// A segment storing up to `nodes` nodes in `room` from node `first` and its facts in `facts`, with `frames` for its
// open stack, from a seam inside containers of `kinds`, outermost first, whose nodes it keeps from node `scratch` on
// and whose nodes in the document the join gives `seam`. With no kinds it starts at the text's start, as a builder
// does. Its builder is refused any more memory, so that its walk, which may run on another thread, calls no
// allocator. A refused allocation leaves `b.err` set.
segment_start :: proc(src: []u8, format: ^tape.Format, room: []tape.Node, first, nodes, scratch: int, kinds: []tape.Kind, facts: []tape.Fact, frames: []u64, seam: []tape.Node_Index, allocator: runtime.Allocator) -> (s: Segment) {
	s.depth, s.first, s.scratch, s.seam, s.allocator = len(kinds), first, scratch, seam, allocator
	b := &s.b
	b.doc = {src = src, format = format, nodes = room, facts = facts[:0], allocator = {refuse_blocks, nil}}
	b.stack, b.facts, b.borrowed, b.closed, b.ctx, b.most = frames, facts, true, tape.NO_NODE, context, max(int)
	b.end = u64(uintptr(raw_data(room))) + u64((first + nodes) * size_of(tape.Node))
	// A container with `MAX_CHILDREN` children in the part has a node of the part for each.
	b.counts.allocator = allocator
	if wide := nodes / int(tape.MAX_CHILDREN); wide > 0 {
		if b.err = reserve(&b.counts, wide); b.err == nil && cap(b.counts) < wide {
			b.err = .Out_Of_Memory
		}
		if b.err != nil {
			return
		}
	}
	s.regs = {a = u64(uintptr(raw_data(room))) + u64(first * size_of(tape.Node)), b = u64(tape.NO_NODE) << 32}
	if s.depth == 0 {
		return
	}
	for k, i in kinds {
		room[scratch + i] = {kind = k}
	}
	before := segment_before(&s)
	// An inline comment before the part's first node belongs to the value before the seam, as `builder_fact` finds it
	// closed just before node `first`.
	room[before] = {n = u32(first) - u32(before)}
	b.closed = tape.Node_Index(before)
	b.stack[0] = u64(tape.NO_NODE) << 32
	for i in 1 ..< s.depth {
		b.stack[i] = u64(scratch + i - 1) << 32
	}
	s.regs.b, s.regs.c = u64(before - 1) << 32, u64(s.depth)
	return
}

// The nodes a segment's walk stored.
segment_nodes :: proc "contextless" (s: ^Segment) -> []tape.Node {
	return s.b.doc.nodes[s.first:builder_cursor(&s.b, s.regs)]
}

// Frees what a segment holds but its rooms.
segment_free :: proc(s: ^Segment) {
	delete(s.b.counts)
	s.b = {}
}

@(private)
refuse_blocks :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	return nil, .Out_Of_Memory if mode != .Free && mode != .Free_All else nil
}

// A container open across a seam: its node in the document and its children counted so far.
@(private)
Open_Across :: struct {
	node:  tape.Node_Index,
	count: u64,
}

// The document of a text whose segments `segs`, in text order, each walked from its seam to the next into `room` and
// `facts`, the last to the root value's end at `root_close`. A segment that stored fewer nodes or facts than the one
// before it planned for moves down to follow it. Then one pass over the containers open at each seam gives those that
// cross it their sizes and counts, and the threads of `runner` give each fact its node. False when a segment does not
// start inside the containers the one before it leaves open, which a read of the text in one walk would have found.
// The document holds the rooms once joined, else they and the segments are left to the caller.
segments_join :: proc(segs: []Segment, room: []tape.Node, facts: []tape.Fact, root_close: u64, runner: ^tape.Runner, allocator: runtime.Allocator) -> (doc: tape.Document, joined: bool, err: runtime.Allocator_Error) {
	at, fact := 0, 0
	for &s in segs {
		own := segment_nodes(&s)
		if at != s.first {
			intrinsics.mem_copy(raw_data(room[at:]), raw_data(own), len(own) * size_of(tape.Node))
		}
		if fact != int(uintptr(raw_data(s.b.facts)) - uintptr(raw_data(facts))) / size_of(tape.Fact) {
			intrinsics.mem_copy(raw_data(facts[fact:]), raw_data(s.b.doc.facts), len(s.b.doc.facts) * size_of(tape.Fact))
		}
		s.at, s.fact = at, fact
		at += len(own)
		fact += len(s.b.doc.facts)
	}
	total := at
	nodes := room
	doc = {src = segs[0].b.doc.src, format = segs[0].b.doc.format, allocator = allocator, root_close = root_close}
	open: [dynamic]Open_Across
	open.allocator = allocator
	defer delete(open)
	counts: [dynamic]tape.Child_Count
	counts.allocator = allocator
	defer if err != nil || !joined {
		delete(counts)
	}
	closed := tape.NO_NODE
	for &s in segs {
		if len(open) != s.depth {
			return {}, false, nil
		}
		for o, i in open[:s.depth] {
			if nodes[o.node].kind != nodes[s.scratch + i].kind {
				return {}, false, nil
			}
			s.seam[i] = o.node
		}
		s.before = tape.Node_Index(s.at - 1)
		if closed != tape.NO_NODE && int(closed) + int(nodes[closed].n) == s.at {
			s.before = closed
		}
		for n in s.b.counts {
			if s.depth == 0 || int(n.node) < s.scratch {
				if _, aerr := append(&counts, tape.Child_Count{segment_place(&s, n.node), n.count}); aerr != nil {
					return {}, false, aerr
				}
			}
		}
		if s.b.closed != tape.NO_NODE && (s.depth == 0 || int(s.b.closed) != segment_before(&s)) {
			closed = segment_place(&s, s.b.closed)
		}
		// The containers the segment closes, innermost first, of which a scratch node holds where each closed, as an
		// offset from the scratch node that wraps below it.
		for i := s.depth - 1; i >= 0 && nodes[s.scratch + i].n != 0; i -= 1 {
			scratch := nodes[s.scratch + i]
			count := u64(scratch.spelling)
			if scratch.spelling == tape.MAX_CHILDREN {
				for n in s.b.counts {
					if int(n.node) == s.scratch + i {
						count = u64(n.count)
					}
				}
			}
			o := open[i]
			total := o.count + count
			node := &nodes[o.node]
			node.n = u32(s.at + int(u32(s.scratch + i) + scratch.n - u32(s.first)) - int(o.node))
			node.spelling = u16(min(total, u64(tape.MAX_CHILDREN)))
			if total >= u64(tape.MAX_CHILDREN) {
				if _, aerr := append(&counts, tape.Child_Count{o.node, u32(total)}); aerr != nil {
					return {}, false, aerr
				}
			}
			pop(&open)
		}
		// The levels open at its end: the outer ones it left open, which gained its children, then its own.
		levels := int(s.regs.c)
		if levels < len(open) {
			return {}, false, nil
		}
		for level in 0 ..< levels {
			frame := s.regs.b if level == levels - 1 else s.b.stack[level + 1]
			node := int(frame >> 32)
			if level < len(open) {
				if node != s.scratch + level {
					return {}, false, nil
				}
				open[level].count += u64(u32(frame))
			} else {
				if node < s.first || s.depth > 0 && node >= s.scratch {
					return {}, false, nil
				}
				if _, aerr := append(&open, Open_Across{segment_place(&s, tape.Node_Index(node)), u64(u32(frame))}); aerr != nil {
					return {}, false, aerr
				}
			}
		}
	}
	if len(open) != 0 {
		return {}, false, nil
	}
	if len(counts) > 0 {
		slice.sort_by(counts[:], proc(a, b: tape.Child_Count) -> bool { return a.node < b.node })
		if _, serr := shrink(&counts); serr != nil {
			return {}, false, serr
		}
		doc.counts = counts[:]
	} else {
		delete(counts)
	}
	// The document keeps the room whole, which `destroy` frees as one block from its start, unless the parts stored
	// far fewer nodes than planned. The room's resize then moves its nodes to an exact block when the allocator cannot
	// shrink one in place, so it fails only when that block is refused too.
	doc.nodes = room[:total]
	if len(room) - total > total / 4 {
		if raw, rerr := runtime.non_zero_mem_resize(raw_data(room), len(room) * size_of(tape.Node), total * size_of(tape.Node), align_of(tape.Node), allocator); rerr == nil {
			doc.nodes = ([^]tape.Node)(raw_data(raw))[:total]
		}
	}
	doc.facts = facts[:fact]
	if fact > 0 {
		c := Segment_Facts{segs = segs, doc = &doc}
		hook.fan(runner, segment_facts, &c)
		for p in c.present {
			doc.present += p
		}
		builder_sort_facts(doc.facts)
	}
	joined = true
	return
}

// The node in the document of node `i` of segment `s`'s walk.
@(private)
segment_place :: #force_inline proc "contextless" (s: ^Segment, i: tape.Node_Index) -> tape.Node_Index {
	switch {
	case s.depth > 0 && i == tape.ROOT:
		// A foot past the root's close names the root, which no segment from a seam holds.
		return tape.ROOT
	case s.depth == 0 || int(i) < s.scratch:
		return tape.Node_Index(s.at + int(i) - s.first)
	case int(i) < s.scratch + s.depth:
		return s.seam[int(i) - s.scratch]
	}
	return s.before
}

@(private)
Segment_Facts :: struct {
	segs:    []Segment,
	doc:     ^tape.Document,
	present: [64]tape.Facts,
	next:    int,
}

// Gives each segment's facts their nodes in the document and places its comments.
@(private)
segment_facts :: proc(arg: rawptr) {
	c := (^Segment_Facts)(arg)
	for {
		k := intrinsics.atomic_add(&c.next, 1)
		if k >= len(c.segs) {
			return
		}
		s := &c.segs[k]
		facts := c.doc.facts[s.fact:][:len(s.b.doc.facts)]
		present: tape.Facts
		for &f in facts {
			f.node = segment_place(s, f.node)
			if f.kind != .Comment {
				present += {f.kind}
			}
		}
		present += builder_place_comments(c.doc, facts, len(c.doc.nodes))
		intrinsics.atomic_or((^u16)(&c.present[k % len(c.present)]), transmute(u16)present)
	}
}
