package build

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/tape"

// The hook that stores a walk's tokens as a document's nodes, and with `builder_hook_facts` its fact tokens as the
// document's facts. In its registers `a` is the next node's address, `b` the open container's index above its child
// count and `c` the count of open containers.
Builder :: struct {
	doc:           tape.Document,
	stack:         []u64, // the frames of the open containers' parents, `b` as it was at their open
	facts:         []tape.Fact, // the facts' buffer, of which `doc.facts` is the part in use
	end:           u64, // the address one past the room `doc.nodes`, where a node written grows the room first
	most:          int, // the most nodes the room may grow to
	closed:        tape.Node_Index, // the container closed last, `NO_NODE` before one closes; kept by `builder_hook_facts`
	err:           runtime.Allocator_Error, // a refused allocation, or `Out_Of_Memory` with `full`
	full:          u64, // one past the first byte of the node a room of `most` nodes had no place for, else 0
	borrowed:      bool, // `stack` is the caller's, which `builder_end` does not free
	wide:          tape.Child_Count, // the first container whose `spelling` saturated, count 0 for none
	wide_more:     bool, // a second container saturated, so `builder_end` counts the children of each
	ctx:           runtime.Context, // the caller's, for the allocations the contextless hook makes
	open_levels:   tape.Levels(builder_levels_held, builder_levels_grow),
	number_blocks: tape.Number_Blocks,
	rooms:         tape.Rooms(builder_rooms_end, builder_rooms_grow),
}

#assert(size_of(tape.Node) == 16)

// The type of the `keeps` field of a hook that starts with a `Builder`, with the builder's hook that keeps a container.
Builder_Keeps :: struct($On: proc "contextless" (h: ^Builder, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) {}

// The open stack of a builder, and of a hook that starts with one, to `tape.Levels`.
@(private)
builder_levels_held :: #force_inline proc "contextless" (h: rawptr) -> int {
	return len((^Builder)(h).stack)
}

@(private)
builder_levels_grow :: #force_inline proc "contextless" (h: rawptr, want: int) -> bool {
	return builder_deepen((^Builder)(h), want)
}

// The room of a builder, and of a hook that starts with one, to `tape.Rooms`.
@(private)
builder_rooms_end :: #force_inline proc "contextless" (h: rawptr) -> uintptr {
	return uintptr((^Builder)(h).end)
}

@(private)
builder_rooms_grow :: #force_inline proc "contextless" (h: rawptr, s: ^tape.Hook_Regs, at: u64) -> bool {
	ok: bool
	s^, ok = builder_grow((^Builder)(h), s^, at)
	return ok
}

// Whether key token `t` of `src`, which needs decoding, decodes to `name`.
Key_Is :: #type proc "contextless" (src: []u8, t: tape.Token, name: string) -> bool

// Whether key token `t` of `src` is spelled `name`, read through `key_is` when it needs decoding.
@(private)
key_spelled :: #force_inline proc "contextless" (src: []u8, t: tape.Token, name: string, key_is: Key_Is) -> bool #no_bounds_check {
	if t.spelling & tape.SPELLING_DECODE != 0 {
		return key_is(src, t, name)
	}
	n := len(name)
	if int(t.n) != n {
		return false
	}
	a, b := raw_data(src[t.lo:]), raw_data(name)
	// A name shorter than a word is two loads that may overlap, each within both strings.
	switch {
	case n >= 8:
		return string(a[:n]) == name
	case n >= 4:
		head := intrinsics.unaligned_load((^u32)(a)) == intrinsics.unaligned_load((^u32)(b))
		return head && intrinsics.unaligned_load((^u32)(a[n - 4:])) == intrinsics.unaligned_load((^u32)(b[n - 4:]))
	case n >= 2:
		return intrinsics.unaligned_load((^u16)(a)) == intrinsics.unaligned_load((^u16)(b)) && a[n - 1] == b[n - 1]
	}
	return n == 0 || a[0] == b[0]
}

// The node `s` writes next.
@(private)
builder_cursor :: #force_inline proc "contextless" (b: ^Builder, s: tape.Hook_Regs) -> tape.Node_Index {
	return tape.Node_Index((uintptr(s.a) - uintptr(raw_data(b.doc.nodes))) / size_of(tape.Node))
}

// Initial hook registers for a walk filling `h`.
builder_regs :: #force_inline proc "contextless" (h: ^Builder) -> tape.Hook_Regs {
	return {a = u64(uintptr(raw_data(h.doc.nodes))), b = u64(tape.NO_NODE) << 32, c = 0}
}

// A builder over `src` with room for `nodes` nodes, growing up to `most`, and `frames` for its open stack. A refused
// allocation leaves `err` set.
builder_start :: proc(src: []u8, format: ^tape.Format, nodes, most: int, frames: []u64, allocator: runtime.Allocator) -> (b: Builder) {
	b.doc = {src = src, format = format, allocator = allocator, flags = {.Kinds_Stored, .In_Order}}
	b.stack, b.borrowed, b.closed, b.ctx, b.most = frames, true, tape.NO_NODE, context, most
	room := clamp(nodes, 1, most)
	raw, err := runtime.mem_alloc_non_zeroed(room * size_of(tape.Node), align_of(tape.Node), allocator)
	if err != nil {
		b.err = err
		return
	}
	b.doc.nodes = ([^]tape.Node)(raw_data(raw))[:room]
	b.end = u64(uintptr(raw_data(raw))) + u64(room * size_of(tape.Node))
	return
}

// Stores `t` as a node, or for an end writes its container's subtree size and child count into the container's node.
// The walk ends only containers it opened, and gives a node only while the room has place for it.
builder_hook :: #force_inline proc "contextless" (h: ^Builder, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action) {
	return builder_step(h, s, t, false, false)
}

// `builder_hook` for a walk that also gives fact tokens, a token whose role is past `Key`, which it stores as facts.
builder_hook_facts :: #force_inline proc "contextless" (h: ^Builder, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action) {
	if t.role > .Key {
		return s, builder_fact(h, s, t)
	}
	return builder_step(h, s, t, true, false)
}

// `builder_hook` growing the room itself, which drops fact tokens, for a walk of a hook that holds the builder.
builder_hook_grows :: #force_inline proc "contextless" (h: ^Builder, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action) {
	if t.role > .Key {
		return s, .Next
	}
	return builder_step(h, s, t, false, true)
}

// With `GROWS` a node that finds the room full grows it first, and a walk that ends at a refused growth is stopped.
// Without it the walk grows the room before a node finds it full, as a growth from the inlined hook costs the walk's
// states a stack frame each.
@(private)
builder_step :: #force_inline proc "contextless" (h: ^Builder, s: tape.Hook_Regs, t: tape.Token, $FACTS, $GROWS: bool) -> (tape.Hook_Regs, tape.Action) #no_bounds_check {
	s := s
	if t.kind <= .Plain {
		if GROWS && s.a == h.end {
			ok: bool
			if s, ok = builder_grow(h, s, t.lo); !ok {
				return s, .Stop
			}
		}
		((^tape.Node)(uintptr(s.a)))^ = t
		s.a += size_of(tape.Node)
		// The open container's child count is `b`'s low half, so a member is counted with one add and no node is
		// touched. A key is not a child.
		s.b += u64(t.role == .Value)
		return s, .Next
	}
	if GROWS && t.kind != .End && s.a == h.end {
		ok: bool
		if s, ok = builder_grow(h, s, t.lo); !ok {
			return s, .Stop
		}
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

// Stores container token `t` as one node holding none of its children, partial with its count not known, for a walk
// that passes it. False once the room cannot grow.
@(private)
builder_unread :: proc "contextless" (h: ^Builder, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, bool) #no_bounds_check {
	s := s
	if s.a == h.end {
		ok: bool
		if s, ok = builder_grow(h, s, t.lo); !ok {
			return s, false
		}
	}
	node := tape.Node{lo = t.lo, n = 1, kind = t.kind, role = t.role, spelling = tape.CONTAINER_PARTIAL | tape.MAX_CHILDREN}
	((^tape.Node)(uintptr(s.a)))^ = node
	s.a += size_of(tape.Node)
	s.b += 1
	return s, true
}

// Doubles the room for nodes, up to `most`, and moves `s.a` with it, for the token at `at` that finds the room full.
// False once a growth is refused or the room holds `most`, with `err` set, which no later growth clears.
@(cold)
builder_grow :: #force_no_inline proc "contextless" (h: ^Builder, s: tape.Hook_Regs, at: u64) -> (tape.Hook_Regs, bool) {
	s := s
	have := len(h.doc.nodes)
	if h.err != nil {
		return s, false
	}
	if have >= h.most {
		h.err, h.full = .Out_Of_Memory, at + 1
		return s, false
	}
	context = h.ctx
	want := min(2 * have, h.most)
	old := u64(uintptr(raw_data(h.doc.nodes)))
	raw, err := runtime.non_zero_mem_resize(raw_data(h.doc.nodes), have * size_of(tape.Node), want * size_of(tape.Node), align_of(tape.Node), h.doc.allocator)
	if err != nil {
		h.err = err
		return s, false
	}
	base := u64(uintptr(raw_data(raw)))
	h.doc.nodes = ([^]tape.Node)(raw_data(raw))[:want]
	h.end = base + u64(want * size_of(tape.Node))
	s.a = base + (s.a - old)
	return s, true
}

// Stores the fact token `t`, a comment, as a fact of the node it describes. A comment before a value waits in
// `builder_end` for the node it marks, an inline comment belongs to the last value completed and a foot to the
// innermost open container, or to the root after it. `Stop` when memory for the facts is refused.
@(private, cold)
builder_fact :: #force_no_inline proc "contextless" (h: ^Builder, s: tape.Hook_Regs, t: tape.Token) -> tape.Action {
	a := builder_cursor(h, s)
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
	context = h.ctx
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
			// A key may be a container, whose subtree comes before its value.
			key := h.doc.nodes[f.node]
			f.node += 1 if key.kind <= .Plain else tape.Node_Index(key.n)
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
	context = h.ctx
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

// The error that stopped the builder, nil for none.
builder_error :: proc "contextless" (h: ^Builder) -> tape.Error {
	if h.full != 0 {
		return tape.Exceeded{at = h.full - 1, kind = .Nodes}
	}
	if h.err != nil {
		return h.err
	}
	return nil
}

// The document the walk built, or the error that ended it, with everything freed. `regs` are the hook's registers at
// the walk's end and `root_close` the end of the root value.
@(require_results)
builder_end :: proc(h: ^Builder, regs: tape.Hook_Regs, root_close: u64, err: tape.Error) -> (doc: tape.Document, e: tape.Error) {
	e = err
	if e == nil {
		e = builder_error(h)
	}
	if !h.borrowed {
		delete(h.stack, h.doc.allocator)
	}
	count := int(builder_cursor(h, regs))
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
	// A grown room holds up to twice the nodes made.
	if raw, err := runtime.non_zero_mem_resize(raw_data(doc.nodes), len(doc.nodes) * size_of(tape.Node), count * size_of(tape.Node), align_of(tape.Node), doc.allocator); err == nil {
		doc.nodes = ([^]tape.Node)(raw_data(raw))[:count]
	} else {
		doc.nodes = doc.nodes[:count]
	}
	doc.root_close = root_close
	return doc, nil
}
