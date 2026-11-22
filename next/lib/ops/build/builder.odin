package build

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The allocation a caller may take: an error, or a nil block for a non-empty request, which a nil or an empty
// allocator gives with no error.
took :: proc(err: runtime.Allocator_Error, p: rawptr, n: int) -> runtime.Allocator_Error {
	if err != nil {
		return err
	}
	if n > 0 && p == nil {
		return .Out_Of_Memory
	}
	return nil
}

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
	// The true child counts of the containers whose `spelling` saturated, in the order they closed, which `builder_end`
	// sorts by node. A container closed with every child holds a node per child, so a room of `n` nodes closes
	// `n / MAX_CHILDREN` of them at most, and past the entries of partial containers `counts` has room for them, reserved
	// as the room grows.
	counts:        [dynamic]tape.Child_Count,
	ctx:           runtime.Context, // the caller's, for the allocations the contextless hook makes
	// For `builder_hook_stubs`, the open containers' count `c` at which each child container is stored as an unread
	// node, and the containers open inside the one stored so.
	stubs:         u64,
	unstored:      u64,
	keep_facts:    bool, // a scan keeps the facts of the nodes it keeps, which its inner hooks store
	protocol:      hook.Protocol(BUILDER_CAPS, hook.Levels(builder_levels_held, builder_levels_grow), hook.Rooms(builder_rooms_end, builder_rooms_grow), hook.Unused),
}

BUILDER_CAPS :: hook.Capabilities{.Levels, .Rooms, .Number_Blocks}

#assert(size_of(tape.Node) == 16)

// The open stack of a builder to `hook.Levels`.
@(private)
builder_levels_held :: #force_inline proc "contextless" (h: rawptr) -> int {
	return len((^Builder)(h).stack)
}

@(private)
builder_levels_grow :: #force_inline proc "contextless" (h: rawptr, want: int) -> bool {
	return builder_deepen((^Builder)(h), want)
}

// The room of a builder to `hook.Rooms`.
@(private)
builder_rooms_end :: #force_inline proc "contextless" (h: rawptr) -> uintptr {
	return uintptr((^Builder)(h).end)
}

@(private)
builder_rooms_grow :: #force_inline proc "contextless" (h: rawptr, s: ^hook.Regs, at: u64) -> bool {
	ok: bool
	s^, ok = builder_grow((^Builder)(h), s^, at)
	return ok
}


// The node `s` writes next.
@(private)
builder_cursor :: #force_inline proc "contextless" (b: ^Builder, s: hook.Regs) -> tape.Node_Index {
	return tape.Node_Index((uintptr(s.a) - uintptr(raw_data(b.doc.nodes))) / size_of(tape.Node))
}

// Initial hook registers for a walk filling `h`.
builder_regs :: #force_inline proc "contextless" (h: ^Builder) -> hook.Regs {
	return {a = u64(uintptr(raw_data(h.doc.nodes))), b = u64(tape.NO_NODE) << 32, c = 0}
}

// Makes `b` a builder over `src` with room for `nodes` nodes, growing up to `most`, and `frames` for its open stack. A
// refused allocation leaves `err` set.
builder_start :: proc(b: ^Builder, src: []u8, format: ^tape.Format, nodes, most: int, frames: []u64, allocator: runtime.Allocator) {
	b^ = {}
	b.doc = {src = src, format = format, allocator = allocator}
	b.stack, b.borrowed, b.closed, b.ctx, b.most = frames, true, tape.NO_NODE, context, most
	b.counts.allocator = allocator
	room := clamp(nodes, 1, most)
	if b.err = builder_reserve_counts(b, room); b.err != nil {
		return
	}
	raw, err := runtime.mem_alloc_non_zeroed(room * size_of(tape.Node), align_of(tape.Node), allocator)
	if b.err = took(err, raw_data(raw), room); b.err != nil {
		delete(b.counts)
		return
	}
	b.doc.nodes = ([^]tape.Node)(raw_data(raw))[:room]
	b.end = u64(uintptr(raw_data(raw))) + u64(room * size_of(tape.Node))
	return
}

// Reserves the entries of `counts` the containers closed in a room of `room` nodes may need. A room of fewer nodes
// than `MAX_CHILDREN` needs none.
@(private)
builder_reserve_counts :: proc(b: ^Builder, room: int) -> runtime.Allocator_Error {
	wide := len(b.counts) + room / int(tape.MAX_CHILDREN)
	if wide <= cap(b.counts) {
		return nil
	}
	reserve(&b.counts, wide) or_return
	return .Out_Of_Memory if cap(b.counts) < wide else nil
}

// Stores `t` as a node, or for an end writes its container's subtree size and child count into the container's node.
// The walk ends only containers it opened, and gives a node only while the room has place for it.
builder_hook :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return builder_step(h, s, t, false, false)
}

// `builder_hook` for a walk that also gives fact tokens, a token whose role is past `Key`, which it stores as facts.
builder_hook_facts :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key {
		return s, builder_fact(h, s, t)
	}
	return builder_step(h, s, t, true, false)
}

// `builder_hook` for the containers a hook holding the builder keeps through its `Keeps`, which stores fact tokens with
// `keep_facts` and drops them without.
builder_hook_kept :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key {
		if h.keep_facts {
			return s, builder_fact(h, s, t)
		}
		return s, .Next
	}
	return builder_step(h, s, t, true, false)
}

// `builder_hook_kept` storing each container opened at level `stubs` as one unread node, with none of its tokens.
builder_hook_stubs :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key {
		if h.keep_facts && h.unstored == 0 {
			return s, builder_fact(h, s, t)
		}
		return s, .Next
	}

	if h.unstored != 0 {
		if t.kind == .End {
			h.unstored -= 1
		} else if t.kind > .Plain {
			h.unstored += 1
		}
		return s, .Next
	}
	if t.kind > .Plain && t.kind != .End && s.c == h.stubs {
		h.unstored = 1
		kept, ok := builder_unread(h, s, t)
		return kept, .Next if ok else .Stop
	}
	return builder_step(h, s, t, true, false)
}

// With `GROWS` a node that finds the room full grows it first, and a walk that ends at a refused growth is stopped.
// Without it the walk grows the room before a node finds it full, as a growth from the inlined hook costs the walk's
// states a stack frame each.
@(private)
builder_step :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token, $FACTS, $GROWS: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	if t.kind <= .Plain {
		if GROWS && s.a == h.end {
			ok: bool
			if s, ok = builder_grow(h, s, t.lo); !ok {
				return s, .Stop
			}
		}
		room_check(h, s)
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
		room_check(h, s)
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
		counts := (^runtime.Raw_Dynamic_Array)(&h.counts)
		([^]tape.Child_Count)(counts.data)[counts.len] = {tape.Node_Index(open), count}
		counts.len += 1
	}
	s.c -= 1
	s.b = h.stack[s.c]
	return s, .Next
}

// Traps in a debug or sanitizer build when the node `s` writes next lies past the room, which every walk keeps from
// happening by its room checks or by a hook that grows the room itself.
@(private)
room_check :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs) {
	when ODIN_DEBUG || ODIN_SANITIZER_FLAGS != {} {
		if s.a >= h.end {
			runtime.panic_contextless("build: a node past the room")
		}
	}
}

// Records the true child count of the partial container at `node`, whose `spelling` saturated, with one more entry of
// room, so the room for the containers closed with every child stays. A refused allocation is held in `err`.
@(cold)
builder_partial_count :: #force_no_inline proc "contextless" (h: ^Builder, node: tape.Node_Index, count: u32) {
	context = h.ctx
	if err := reserve(&h.counts, cap(h.counts) + 1); err != nil {
		if h.err == nil {
			h.err = err
		}
		return
	}
	append(&h.counts, tape.Child_Count{node, count})
}

// Stores container token `t` as one node holding none of its children, partial with its count not known, for a walk
// that passes it. False once the room cannot grow.
@(private)
builder_unread :: proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, bool) #no_bounds_check {
	s := s
	if s.a == h.end {
		ok: bool
		if s, ok = builder_grow(h, s, t.lo); !ok {
			return s, false
		}
	}
	node := tape.Node{lo = t.lo, n = 1, kind = t.kind, role = t.role, spelling = tape.CONTAINER_PARTIAL | tape.MAX_CHILDREN}
	room_check(h, s)
	((^tape.Node)(uintptr(s.a)))^ = node
	s.a += size_of(tape.Node)
	s.b += 1
	return s, true
}

// Grows the room for nodes, up to `most`, and moves `s.a` with it, for the token at `at` that finds the room full. It
// grows to what the rest of the text makes at the rate of nodes per byte so far, with a quarter more, so a read that
// keeps nodes evenly grows once, or doubles when that is more or is refused. False once a growth is refused or the
// room holds `most`, with `err` set, which no later growth clears.
@(cold)
builder_grow :: #force_no_inline proc "contextless" (h: ^Builder, s: hook.Regs, at: u64) -> (hook.Regs, bool) {
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
	double := min(2 * have, h.most)
	want := double
	if at > 0 && at < u64(len(h.doc.src)) {
		rest := f64(u64(len(h.doc.src)) - at)
		want = max(want, int(min(f64(h.most), f64(have) * (1 + 1.25 * rest / f64(at)))))
	}
	old := u64(uintptr(raw_data(h.doc.nodes)))
	raw, err := runtime.non_zero_mem_resize(raw_data(h.doc.nodes), have * size_of(tape.Node), want * size_of(tape.Node), align_of(tape.Node), h.doc.allocator)
	if err != nil && want > double {
		want = double
		raw, err = runtime.non_zero_mem_resize(raw_data(h.doc.nodes), have * size_of(tape.Node), want * size_of(tape.Node), align_of(tape.Node), h.doc.allocator)
	}
	if h.err = took(err, raw_data(raw), int(want)); h.err != nil {
		return s, false
	}
	base := u64(uintptr(raw_data(raw)))
	h.doc.nodes = ([^]tape.Node)(raw_data(raw))[:want]
	h.end = base + u64(want * size_of(tape.Node))
	s.a = base + (s.a - old)
	if h.err = builder_reserve_counts(h, want); h.err != nil {
		return s, false
	}
	return s, true
}

// Stores the fact token `t`, a comment, as a fact of the node it describes. A comment before a value waits in
// `builder_end` for the node it marks, an inline comment belongs to the last value completed and a foot to the
// innermost open container, or to the root after it. `Stop` when memory for the facts is refused.
@(private, cold)
builder_fact :: #force_no_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> hook.Action {
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
	if h.err = took(err, raw_data(raw), int(want)); h.err != nil {
		return false
	}
	h.facts = ([^]tape.Fact)(raw_data(raw))[:want]
	h.doc.facts = h.facts[:len(h.doc.facts)]
	return true
}

// Gives each comment that waits for the value it marks that value's node: the node after it, or after a key the key's
// value. A comment no node follows, past a stop, belongs to the root as its foot. Then sorts the facts by node.
@(private, cold)
builder_place_facts :: proc(doc: ^tape.Document, count: int) {
	doc.present += builder_place_comments(doc, doc.facts, count)
	builder_sort_facts(doc.facts)
}

// `builder_place_facts` for the comments among `facts`, some of `doc`'s, giving the kinds they come to.
@(private)
builder_place_comments :: proc "contextless" (doc: ^tape.Document, facts: []tape.Fact, count: int) -> (present: tape.Facts) {
	for &f in facts {
		if f.kind != .Comment {
			continue
		}
		if int(f.node) < count && doc.nodes[f.node].role == .Key {
			// A key may be a container, whose subtree comes before its value.
			key := doc.nodes[f.node]
			f.node += 1 if key.kind <= .Plain else tape.Node_Index(key.n)
		}
		if int(f.node) >= count {
			f.node, f.kind = tape.ROOT, .Comment_Foot
			present += {.Comment_Foot}
		} else {
			present += {.Comment}
		}
	}
	return
}

// Sorts `facts` by node. Facts arrive mostly in node order, and a stable sort of an ordered list changes nothing.
@(private)
builder_sort_facts :: proc(facts: []tape.Fact) {
	for i in 1 ..< len(facts) {
		if facts[i].node < facts[i - 1].node {
			slice.stable_sort_by(facts, proc(a, b: tape.Fact) -> bool { return a.node < b.node })
			break
		}
	}
}

// Grows the open stack to `want` frames, for a walk about to nest past it.
@(cold)
builder_deepen :: #force_no_inline proc "contextless" (h: ^Builder, want: int) -> bool {
	context = h.ctx
	stack, err := make([]u64, want, h.doc.allocator)
	if took(err, raw_data(stack), want) != nil {
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
builder_end :: proc(h: ^Builder, regs: hook.Regs, root_close: u64, err: tape.Error) -> (doc: tape.Document, e: tape.Error) {
	e = err
	if e == nil {
		e = builder_error(h)
	}
	if !h.borrowed {
		delete(h.stack, h.doc.allocator)
	}
	count := int(builder_cursor(h, regs))
	if e == nil && len(h.doc.facts) > 0 {
		builder_place_facts(&h.doc, count)
	}
	if e != nil {
		h.doc.facts = h.facts
		delete(h.counts)
		tape.destroy(&h.doc)
		return {}, e
	}
	doc = h.doc
	if len(h.counts) > 0 {
		// An inner container closes before the one holding it.
		slice.sort_by(h.counts[:], proc(a, b: tape.Child_Count) -> bool { return a.node < b.node })
		shrink(&h.counts)
		doc.counts = h.counts[:]
	} else {
		delete(h.counts)
	}
	// A room the nodes fill past half, or with at most `ROOM_SLACK` unused bytes, is kept whole, its tail memory no node
	// wrote, so that the allocator can give its block to the next read of its size. A room less than half full moves its
	// nodes to an exact block when the allocator cannot shrink it in place, so the resize fails only when that block is
	// refused too, and the document then keeps the whole room. `destroy` frees the room as one block from its start.
	doc.nodes = doc.nodes[:count]
	if 2 * count < len(h.doc.nodes) && (len(h.doc.nodes) - count) * size_of(tape.Node) > ROOM_SLACK {
		if raw, err := runtime.non_zero_mem_resize(raw_data(doc.nodes), len(h.doc.nodes) * size_of(tape.Node), count * size_of(tape.Node), align_of(tape.Node), doc.allocator); took(err, raw_data(raw), count) == nil {
			doc.nodes = ([^]tape.Node)(raw_data(raw))[:count]
		}
	}
	doc.root_close = root_close
	return doc, nil
}

// The unused bytes of a room a document keeps rather than move its nodes to an exact block.
@(private)
ROOM_SLACK :: 1024

// A copy of the document the walk has built so far, for a text that ended inside its root value: the containers still
// open are closed at the cut, and a key whose value had not started is left out, so that the copy is a document of
// the values given. `regs` are the hook's registers at the cut and `cut` where more bytes are needed. With `read`, the
// children read so far of each open container by level, one that stored fewer is `CONTAINER_PARTIAL`. The builder
// goes on as it was.
@(require_results)
builder_so_far :: proc(h: ^Builder, regs: hook.Regs, cut: u64, allocator: runtime.Allocator, read: []u64 = nil) -> (doc: tape.Document, err: tape.Error) {
	if e := builder_error(h); e != nil {
		return {}, e
	}
	count := int(builder_cursor(h, regs))
	inner := int(regs.b >> 32) if regs.c > 0 else -1
	if count > 0 && count - 1 > inner && h.doc.nodes[count - 1].role == .Key {
		count -= 1
	}
	nodes, nerr := make([]tape.Node, count, allocator)
	if e := took(nerr, raw_data(nodes), count); e != nil {
		return {}, e
	}
	defer if err != nil {
		delete(nodes, allocator)
	}
	copy(nodes, h.doc.nodes[:count])
	counts, cerr := make([dynamic]tape.Child_Count, 0, len(h.counts), allocator)
	if e := took(cerr, raw_data(counts), len(h.counts) * size_of(tape.Child_Count)); e != nil {
		return {}, e
	}
	defer if err != nil {
		delete(counts)
	}
	append(&counts, ..h.counts[:]) or_return
	b := regs.b
	for c := regs.c; c > 0; c -= 1 {
		open, children := int(b >> 32), u64(u32(b))
		partial := read != nil && read[c - 1] != children
		if partial {
			children = read[c - 1]
		}
		nodes[open].n = u32(count - open)
		nodes[open].spelling = u16(min(children, u64(tape.MAX_CHILDREN))) | (tape.CONTAINER_PARTIAL if partial else 0)
		if children >= u64(tape.MAX_CHILDREN) {
			append(&counts, tape.Child_Count{tape.Node_Index(open), u32(children)}) or_return
		}
		b = h.stack[c - 1]
	}
	slice.sort_by(counts[:], proc(a, b: tape.Child_Count) -> bool { return a.node < b.node })
	facts, ferr := make([]tape.Fact, len(h.doc.facts), allocator)
	if e := took(ferr, raw_data(facts), len(h.doc.facts)); e != nil {
		return {}, e
	}
	copy(facts, h.doc.facts)
	doc = h.doc
	// The copy owns nothing the builder keeps: its format extension and the scan's partial block stay the
	// builder's, or the two would free them once each.
	doc.ext, doc.partial = nil, nil
	doc.nodes, doc.facts, doc.allocator, doc.root_close = nodes, facts, allocator, cut
	doc.counts = counts[:] if len(counts) > 0 else nil
	if len(counts) == 0 {
		delete(counts)
	}
	doc.flags += {.Cut}
	if len(doc.facts) > 0 {
		builder_place_facts(&doc, count)
	}
	return doc, nil
}
