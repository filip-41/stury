package build

import "base:runtime"
import "core:slice"
import "stury:lib/core/tape"

// The hook that stores a walk's tokens as a document's nodes, and with `builder_hook_facts` its fact tokens as the
// document's facts. In its registers `a` is the next node's address, `b` the open container's index above its child
// count and `c` the count of open containers.
Builder :: struct {
	doc:       tape.Document,
	stack:     []u64, // the frames of the open containers' parents, `b` as it was at their open
	facts:     []tape.Fact, // the facts' buffer, of which `doc.facts` is the part in use
	closed:    tape.Node_Index, // the container closed last, `NO_NODE` before one closes; kept by `builder_hook_facts`
	err:       runtime.Allocator_Error,
	borrowed:  bool, // `stack` is the caller's, which `builder_end` does not free
	wide:      tape.Child_Count, // the first container whose `spelling` saturated, count 0 for none
	wide_more: bool, // a second container saturated, so `builder_end` counts the children of each
}

#assert(size_of(tape.Node) == 16)

// Initial hook registers for a walk filling `h`.
builder_regs :: #force_inline proc "contextless" (h: ^Builder) -> tape.Hook_Regs {
	return {a = u64(uintptr(raw_data(h.doc.nodes))), b = u64(tape.NO_NODE) << 32, c = 0}
}

// A builder over `src` with room for `nodes` nodes, which must cover every node the walk can make, and `frames` for its
// open stack. A refused allocation leaves `err` set.
builder_start :: proc(src: []u8, format: ^tape.Format, nodes: int, frames: []u64, allocator: runtime.Allocator) -> (b: Builder) {
	b.doc = {src = src, format = format, allocator = allocator, flags = {.Kinds_Stored, .In_Order}}
	b.stack, b.borrowed, b.closed = frames, true, tape.NO_NODE
	raw, err := runtime.mem_alloc_non_zeroed(max(nodes, 16) * size_of(tape.Node), align_of(tape.Node), allocator)
	if err != nil {
		b.err = err
		return
	}
	b.doc.nodes = ([^]tape.Node)(raw_data(raw))[:max(nodes, 16)]
	return
}

// Stores `t` as a node, or for an end writes its container's subtree size and child count into the container's node.
// The walk ends only containers it opened.
builder_hook :: #force_inline proc "contextless" (h: ^Builder, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action) {
	return builder_step(h, s, t, false)
}

// `builder_hook` for a walk that also gives fact tokens, a token whose role is past `Key`, which it stores as facts.
builder_hook_facts :: #force_inline proc "contextless" (h: ^Builder, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action) {
	if t.role > .Key {
		return s, builder_fact(h, s, t)
	}
	return builder_step(h, s, t, true)
}

@(private)
builder_step :: #force_inline proc "contextless" (h: ^Builder, s: tape.Hook_Regs, t: tape.Token, $FACTS: bool) -> (tape.Hook_Regs, tape.Action) #no_bounds_check {
	s := s
	if t.kind <= .Plain {
		((^tape.Node)(uintptr(s.a)))^ = t
		s.a += size_of(tape.Node)
		// The open container's child count is `b`'s low half, so a member is counted with one add and no node is
		// touched. A key is not a child.
		s.b += u64(t.role == .Value)
		return s, .Next
	}
	a := int((uintptr(s.a) - uintptr(raw_data(h.doc.nodes))) / size_of(tape.Node))
	if t.kind != .End {
		((^tape.Node)(uintptr(s.a)))^ = t
		h.stack[s.c] = s.b + 1
		s.c += 1
		s.a += size_of(tape.Node)
		s.b = u64(a) << 32
		return s, .Next
	}
	open := int(s.b >> 32)
	count := u32(s.b)
	when FACTS {
		h.closed = tape.Node_Index(open)
	}
	n := &h.doc.nodes[open]
	n.n = u32(a - open)
	n.spelling = u16(min(count, u32(tape.MAX_CHILDREN)))
	if count >= u32(tape.MAX_CHILDREN) {
		if h.wide.count == 0 {
			h.wide = {tape.Node_Index(open), count}
		} else {
			h.wide_more = true
		}
	}
	s.c -= 1
	s.b = h.stack[s.c]
	return s, .Next
}

// Stores the fact token `t`, a comment, as a fact of the node it describes. A comment before a value waits in
// `builder_end` for the node it marks, an inline comment belongs to the last value completed and a foot to the
// innermost open container, or to the root after it. `Stop` when memory for the facts is refused.
@(private, cold)
builder_fact :: #force_no_inline proc "contextless" (h: ^Builder, s: tape.Hook_Regs, t: tape.Token) -> tape.Action {
	a := tape.Node_Index((uintptr(s.a) - uintptr(raw_data(h.doc.nodes))) / size_of(tape.Node))
	node := a
	kind := tape.fact_kind(t.role)
	#partial switch kind {
	case .Comment:
	case .Comment_Inline:
		// The container closed last is the last value completed when no node was stored after its subtree.
		node = a - 1
		if h.closed != tape.NO_NODE && h.closed + tape.Node_Index(h.doc.nodes[h.closed].n) == a {
			node = h.closed
		}
	case .Comment_Foot:
		node = tape.Node_Index(s.b >> 32)
		if node == tape.NO_NODE {
			node = tape.ROOT
		}
	case:
		return .Next
	}
	n := len(h.doc.facts)
	if n == len(h.facts) && !builder_grow_facts(h) {
		return .Stop
	}
	h.facts[n] = tape.Fact{lo = t.lo, node = node, n = t.n, kind = kind, spelling = t.spelling}
	h.doc.facts = h.facts[:n + 1]
	if kind != .Comment {
		h.doc.present += {kind}
	}
	return .Next
}

// Doubles the room for facts, or sets `err` when memory is refused.
@(private, cold)
builder_grow_facts :: proc "contextless" (h: ^Builder) -> bool {
	context = runtime.default_context()
	want := max(2 * len(h.facts), 16)
	raw, err := runtime.non_zero_mem_resize(raw_data(h.facts), len(h.facts) * size_of(tape.Fact), want * size_of(tape.Fact), align_of(tape.Fact), h.doc.allocator)
	if err != nil {
		h.err = err
		return false
	}
	h.facts = ([^]tape.Fact)(raw_data(raw))[:want]
	h.doc.facts = h.facts[:len(h.doc.facts)]
	return true
}

// Gives each comment that waits for the value it marks that value's node: the node after it, or after a key the key's
// value. A comment no node follows, past a stop, belongs to the root as its foot. Then sorts the facts by node.
@(private, cold)
builder_place_facts :: proc(h: ^Builder, count: int) {
	facts := h.doc.facts
	for &f in facts {
		if f.kind != .Comment {
			continue
		}
		if int(f.node) < count && h.doc.nodes[f.node].role == .Key {
			f.node += 1
		}
		if int(f.node) >= count {
			f.node, f.kind = tape.ROOT, .Comment_Foot
			h.doc.present += {.Comment_Foot}
		} else {
			h.doc.present += {.Comment}
		}
	}
	// Facts arrive mostly in node order, and a stable sort of an ordered list changes nothing.
	for i in 1 ..< len(facts) {
		if facts[i].node < facts[i - 1].node {
			slice.stable_sort_by(facts, proc(a, b: tape.Fact) -> bool { return a.node < b.node })
			break
		}
	}
}

// Gives the document the true child counts of its containers in `nodes` whose `spelling` saturated.
@(private, cold)
builder_wide :: proc(h: ^Builder, nodes: []tape.Node) -> runtime.Allocator_Error {
	if !h.wide_more {
		counts := make([]tape.Child_Count, 1, h.doc.allocator) or_return
		counts[0] = h.wide
		h.doc.counts = counts
		return nil
	}
	counts, err := builder_counts(nodes, h.doc.allocator)
	h.doc.counts = counts[:]
	return err
}

// The true child counts of the containers in `nodes` whose `spelling` saturated, in node order.
@(private, cold)
builder_counts :: proc(nodes: []tape.Node, allocator: runtime.Allocator) -> (counts: [dynamic]tape.Child_Count, err: runtime.Allocator_Error) #no_bounds_check {
	counts.allocator = allocator
	for i := 0; i < len(nodes); {
		node := nodes[i]
		if node.kind <= .Plain {
			i += 1
			continue
		}
		// A subtree of fewer nodes than `MAX_CHILDREN` holds no saturated container.
		if node.n < u32(tape.MAX_CHILDREN) {
			i += max(int(node.n), 1)
			continue
		}
		if node.spelling == tape.MAX_CHILDREN {
			append(&counts, tape.Child_Count{tape.Node_Index(i), child_count(nodes[i + 1:i + int(node.n)])}) or_return
		}
		i += 1
	}
	return
}

// The children among `nodes`, a container's descendants. A key is not a child.
@(private)
child_count :: proc(nodes: []tape.Node) -> (count: u32) #no_bounds_check {
	for j := 0; j < len(nodes); {
		child := nodes[j]
		if child.kind <= .Plain {
			count += u32(child.role == .Value)
			j += 1
		} else {
			count += 1
			j += int(child.n)
		}
	}
	return
}

// Grows the open stack to `want` frames, for a walk about to nest past it.
@(cold)
builder_deepen :: #force_no_inline proc "contextless" (h: ^Builder, want: int) -> bool {
	context = runtime.default_context()
	stack, err := make([]u64, want, h.doc.allocator)
	if err != nil {
		return false
	}
	copy(stack, h.stack)
	if !h.borrowed {
		delete(h.stack, h.doc.allocator)
	}
	h.stack, h.borrowed = stack, false
	return true
}

// The document the walk built, or the error that ended it, with everything freed. `regs` are the hook's registers at
// the walk's end and `root_close` the end of the root value.
builder_end :: proc(h: ^Builder, regs: tape.Hook_Regs, root_close: u64, err: tape.Error) -> (doc: tape.Document, e: tape.Error) {
	e = err
	if e == nil && h.err != nil {
		e = h.err
	}
	if !h.borrowed {
		delete(h.stack, h.doc.allocator)
	}
	count := int((uintptr(regs.a) - uintptr(raw_data(h.doc.nodes))) / size_of(tape.Node))
	if e == nil && h.wide.count != 0 {
		if refused := builder_wide(h, h.doc.nodes[:count]); refused != nil {
			e = refused
		}
	}
	if e == nil && len(h.doc.facts) > 0 {
		builder_place_facts(h, count)
	}
	if e != nil {
		h.doc.facts = h.facts
		tape.destroy(&h.doc)
		return {}, e
	}
	doc = h.doc
	doc.nodes = doc.nodes[:count]
	doc.root_close = root_close
	return doc, nil
}
