package scan

import "core:bytes"
import "core:slice"
import "walk"
import lex "lex"

// Attach each comment of `facts`, in source order and attached to nothing, to a row of `nodes`, the whole
// document's rows in preorder, then sort them by node, place, then source order.
//
// A comment inside a member, between its key and its value, is that member's `.Inline`. One on the line an
// entry ends on, after it, its comma or another such comment, is its `.Trail`, and so is one before the
// entry's comma on a later line, so an entry's comments never reach past its comma. Otherwise it is the
// `.Lead` of the next entry of its container, or, past the last, the container's `.Foot`. Outside the root a
// comment leads the root before it and trails it after.
//
// The containers open past MAX_DEPTH, under a raised `max_depth`, spill to `context.allocator`. False when
// it refuses, the facts then part attached.
jsonc_attach :: proc(nodes: []Row, src: []byte, facts: []Fact) -> bool {
	fixed: [MAX_DEPTH]Attach_Open = ---
	stack := ([^]Attach_Open)(&fixed)
	room := MAX_DEPTH
	spill: []Attach_Open
	defer if spill != nil {
		delete(spill)
	}
	depth := 0
	root_last := NO_NODE
	r := Node(0)
	n_rows := Node(len(nodes))
	for &cm, k in facts {
		// Every entry starting before the comment is placed under the container holding it.
		for r < n_rows && u64(entry_lo(nodes[r])) < cm.lo {
			at := entry_lo(nodes[r])
			for depth > 0 && nodes[stack[depth - 1].row].hi <= at {
				depth -= 1
			}
			if depth > 0 {
				stack[depth - 1].last = r
			} else {
				root_last = r
			}
			if nodes[r].kind == .Array || nodes[r].kind == .Object {
				if depth == room {
					if stack = attach_grow(&spill, stack, &room); stack == nil {
						return false
					}
				}
				stack[depth] = {row = r, last = NO_NODE}
				depth += 1
			}
			r += 1
		}
		for depth > 0 && u64(nodes[stack[depth - 1].row].hi) <= cm.lo {
			depth -= 1
		}
		parent := stack[depth - 1].row if depth > 0 else NO_NODE
		last := stack[depth - 1].last if depth > 0 else root_last
		cm.node, cm.place = 0, .Trail
		switch {
		case depth > 0 && cm.lo < u64(nodes[stack[depth - 1].row].lo):
			// The container's key came before the comment and its open bracket comes after.
			cm.node, cm.place = stack[depth - 1].row, .Inline
		case last >= 0 && nodes[last].key_lo != walk.NO_KEY && cm.lo < u64(nodes[last].lo):
			cm.node, cm.place = last, .Inline
		case last >= 0 && (!bytes.contains_any(src[nodes[last].hi:cm.lo], {'\r', '\n'}) || comma_follows(src, facts, k)):
			cm.node, cm.place = last, .Trail
		case r < n_rows && (parent < 0 || entry_lo(nodes[r]) < nodes[parent].hi):
			cm.node, cm.place = r, .Lead
		case parent >= 0:
			cm.node, cm.place = parent, .Foot
		}
	}
	// Comments that only lead entries come out in order: one pass checks, where a sort moved every fact.
	if !slice.is_sorted_by(facts, fact_before) {
		slice.sort_by(facts, fact_before)
	}
	return true
}

@(private = "file")
Attach_Open :: struct {
	row, last: Node,
}

// `jsonc_attach`'s stack doubled onto `context.allocator`. Nil when it refuses, the old stack then kept.
@(private = "file", cold)
attach_grow :: proc(spill: ^[]Attach_Open, stack: [^]Attach_Open, room: ^int) -> [^]Attach_Open {
	grown, err := make([]Attach_Open, 2 * room^)
	if err != nil {
		return nil
	}
	copy(grown, stack[:room^])
	delete(spill^)
	spill^, room^ = grown, len(grown)
	return raw_data(grown)
}

// A document's order of facts: by node, then place, then source order.
@(private = "file")
fact_before :: proc(a, b: Fact) -> bool {
	if a.node != b.node {
		return a.node < b.node
	}
	if a.place != b.place {
		return a.place < b.place
	}
	return a.lo < b.lo
}

// Whether the byte after comment `k`, past blanks and the comments that follow it, is a comma. Reads only
// the spans, which attaching leaves as they are.
@(private = "file")
comma_follows :: proc(src: []byte, facts: []Fact, k: int) -> bool {
	s := Scanner{src = src, pos = facts[k].hi}
	for j := k + 1; ; j += 1 {
		lex.skip_ws(&s)
		if j == len(facts) || facts[j].lo != s.pos {
			return lex.peek(&s) == ','
		}
		s.pos = facts[j].hi
	}
}

// Where row `n`'s entry starts in its container: its key, or its value when it has none.
entry_lo :: #force_inline proc(n: Row) -> u32 {
	return n.lo if n.key_lo == walk.NO_KEY else n.key_lo
}
