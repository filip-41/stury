package build

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Returns `err`, or `.Out_Of_Memory` when `p` is nil for a request of `n > 0`, which a nil or an empty allocator
// returns without an error.
took :: proc(err: runtime.Allocator_Error, p: rawptr, n: int) -> runtime.Allocator_Error {
	if err != nil {
		return err
	}
	if n > 0 && p == nil {
		return .Out_Of_Memory
	}
	return nil
}

// The hook that stores a walk's tokens as a document's nodes and, through `builder_hook_facts`, its fact tokens as the
// document's facts. Registers: `a` is the address of the next node, `b` holds the open container's node index in its
// high 32 bits and its child count in its low 32 bits, and `c` is the number of open containers.
Builder :: struct {
	doc:           tape.Document,
	stack:         []u64, // the saved `b` of each open container's parent, with the container counted as a child
	facts:         []tape.Fact, // the facts' buffer, of which `doc.facts` is the part in use
	end:           u64, // the address one past the room of `doc.nodes`, where a node written grows the room first
	most:          int, // the most nodes the room may grow to
	closed:        tape.Node_Index, // the container closed last, `NO_NODE` before one closes. Kept by `builder_hook_facts`
	err:           runtime.Allocator_Error, // a refused allocation, or `Out_Of_Memory` with `full`
	full:          u64, // one past the offset of the token a room of `most` nodes had no place for, else 0
	borrowed:      bool, // `stack` is the caller's, which `builder_end` does not free
	lent:          bool, // the room of `doc.nodes` is the caller's, which `builder_end` keeps whole and does not free
	// The budget the builder's allocator counts against, or nil. Under it the room for nodes is never sized past what
	// the budget leaves, so a refusal comes from the nodes the text needs and not from a room sized ahead of them.
	budget:        ^hook.Memory_Budget,
	// The full child counts of the containers whose `spelling` saturated, in the order they closed. `builder_end` sorts
	// them by node. A container closed with every child holds a node per child, so a room of `n` nodes closes at most
	// `n / MAX_CHILDREN` of them. `counts` has room for those past the entries of partial containers, reserved as the
	// room grows.
	counts:        [dynamic]tape.Child_Count,
	ctx:           runtime.Context, // the caller's, for the allocations the contextless hook makes
	// For `builder_hook_stubs`: `stubs` is the open-container count `c` at which a child container is stored as an
	// unread node, and `unstored` counts the container stored so and the containers open inside it.
	stubs:         u64,
	unstored:      u64,
	keep_facts:    bool, // a scan keeps the facts of the nodes it keeps, which its inner hooks store
	protocol:      hook.Protocol(BUILDER_CAPS, Builder_Levels, Builder_Rooms, hook.Unused),
}

BUILDER_CAPS :: hook.Capabilities{.Levels, .Rooms, .Number_Blocks}
@(private)
Builder_Levels :: hook.Levels(builder_levels_held, builder_levels_grow)
@(private)
Builder_Rooms :: hook.Rooms(builder_rooms_end, builder_rooms_grow)

// The builder of a table's rows, read through `builder_hook_rows`. It is a `Builder` that a walk knows stores no key,
// so the walk's code for a key has no room to make. It has a `Builder`'s size and address.
Rows_Builder :: struct {
	builder:  Builder,
	protocol: hook.Protocol(BUILDER_CAPS + {.Unkeyed}, Builder_Levels, Builder_Rooms, hook.Unused),
}

#assert(size_of(Rows_Builder) == size_of(Builder))

// The builder `b` as a builder of rows.
rows_of :: #force_inline proc "contextless" (b: ^Builder) -> ^Rows_Builder {
	return (^Rows_Builder)(b)
}

#assert(size_of(tape.Node) == 16)

// The open stack of a builder, as `hook.Levels` reads it.
@(private)
builder_levels_held :: #force_inline proc "contextless" (h: rawptr) -> int {
	return len((^Builder)(h).stack)
}

@(private)
builder_levels_grow :: #force_inline proc "contextless" (h: rawptr, want: int, s: ^hook.Regs, at: u64) -> bool {
	return builder_deepen((^Builder)(h), want, s, at)
}

// The room of a builder, as `hook.Rooms` reads it.
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


// The index of the node `s` writes next.
@(private)
builder_cursor :: #force_inline proc "contextless" (b: ^Builder, s: hook.Regs) -> tape.Node_Index {
	return tape.Node_Index((uintptr(s.a) - uintptr(raw_data(b.doc.nodes))) / size_of(tape.Node))
}

// Initial hook registers for a walk filling `h`.
builder_regs :: #force_inline proc "contextless" (h: ^Builder) -> hook.Regs {
	return {a = u64(uintptr(raw_data(h.doc.nodes))), b = u64(tape.NO_NODE) << 32, c = 0}
}

// Makes `b` a builder over `src` with room for `nodes` nodes, growing up to `most`, and `frames` for its open stack. A
// refused allocation leaves `err` set. `budget` is the one `allocator` counts against, if any. A `lent` room, from
// `allocator`, is built in instead of a room of `nodes`, and it grows as such a room does.
builder_start :: proc(b: ^Builder, src: []u8, format: ^tape.Format, nodes, most: int, frames: []u64, allocator: runtime.Allocator, budget: ^hook.Memory_Budget = nil, lent: []tape.Node = nil) {
	b^ = {}
	b.doc = {src = src, format = format, allocator = allocator}
	b.stack, b.borrowed, b.closed, b.ctx, b.most, b.budget = frames, true, tape.NO_NODE, context, most, budget
	b.counts.allocator = allocator
	if len(lent) > 0 {
		b.lent, b.doc.nodes = true, lent[:min(len(lent), most)]
		b.end = u64(uintptr(raw_data(b.doc.nodes))) + u64(len(b.doc.nodes) * size_of(tape.Node))
		b.err = builder_reserve_counts(b, len(b.doc.nodes))
		return
	}
	room := clamp(nodes, 1, most)
	if budget != nil {
		// The first room takes at most half of what the budget leaves, so the read's other blocks fit beside it, and it
		// grows within the budget as the nodes need.
		room = min(room, max(builder_fit(b, 0) / 2, 1))
	}
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

// Starts `b`, which `builder_start` started with the same allocator and `builder_end` ended, as `builder_start` would
// with a `lent` room and no budget. The context `b` keeps is the one it started with.
builder_again :: proc(b: ^Builder, src: []u8, format: ^tape.Format, most: int, frames: []u64, lent: []tape.Node) {
	b.doc = {src = src, format = format, allocator = b.doc.allocator}
	b.stack, b.facts, b.most, b.closed, b.err, b.full = frames, nil, most, tape.NO_NODE, nil, 0
	b.borrowed, b.lent, b.budget, b.stubs, b.unstored, b.keep_facts = true, true, nil, 0, 0, false
	b.counts = nil
	b.counts.allocator = b.doc.allocator
	b.doc.nodes = lent[:min(len(lent), most)]
	b.end = u64(uintptr(raw_data(b.doc.nodes))) + u64(len(b.doc.nodes) * size_of(tape.Node))
	b.err = builder_reserve_counts(b, len(b.doc.nodes))
}

// Reserves the entries of `counts` the containers closed in a room of `room` nodes may need.
@(private)
builder_reserve_counts :: proc(b: ^Builder, room: int) -> runtime.Allocator_Error {
	wide := len(b.counts) + wide_room(room)
	if wide <= cap(b.counts) {
		return nil
	}
	reserve(&b.counts, wide) or_return
	return .Out_Of_Memory if cap(b.counts) < wide else nil
}

// The entries of `counts` a room of `room` nodes may need, one per `MAX_CHILDREN` nodes, rounded up so that a room
// that doubles needs at most twice as many. A room of fewer nodes than `MAX_CHILDREN` needs none.
@(private)
wide_room :: #force_inline proc "contextless" (room: int) -> int {
	return (room + int(tape.MAX_CHILDREN) - 1) / int(tape.MAX_CHILDREN) if room >= int(tape.MAX_CHILDREN) else 0
}

// Whether the budget of `b` lets a room of `have` nodes grow to `room` nodes, counting the entries of `counts` they
// need. True when `b` has no budget.
@(private)
builder_affords :: proc "contextless" (b: ^Builder, have, room: int) -> bool {
	if b.budget == nil {
		return true
	}
	counts := max(len(b.counts) + wide_room(room) - cap(b.counts), 0)
	return u64((room - have) * size_of(tape.Node) + counts * size_of(tape.Child_Count)) <= hook.memory_budget_left(b.budget)
}

// The largest room, at most `most`, that a room of `have` nodes may grow to within the budget of `b`, and at least one
// node more than `have`, which the budget refuses when it has no place for it.
@(private)
builder_fit :: proc "contextless" (b: ^Builder, have: int) -> int {
	lo, hi := have, b.most
	for lo < hi {
		mid := lo + (hi - lo + 1) / 2
		if builder_affords(b, have, mid) {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return max(lo, have + 1)
}

// Stores `t` as a node. For an end token it writes the container's subtree size and child count into the container's
// node. The walk ends only containers it opened, and gives a node only while the room has place for it.
builder_hook :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return builder_step(h, s, t, false, false)
}

// `builder_hook` for a walk that also gives fact tokens (role past `Key`), which it stores as facts.
builder_hook_facts :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key {
		// A copy, as the call takes its argument by reference and would keep `s` in memory for every token.
		copy := s
		return s, builder_fact(h, copy, t)
	}
	return builder_step(h, s, t, true, false)
}

// `builder_hook` for the containers that a hook holding the builder keeps through its `Keeps`. Fact tokens are stored
// when `keep_facts` is set and dropped otherwise.
builder_hook_kept :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key {
		if h.keep_facts {
			return s, builder_fact(h, s, t)
		}
		return s, .Next
	}
	return builder_step(h, s, t, true, false)
}

// `builder_hook_facts` for a table, whose walk gives each cell its column's key: it stores no key, as a table's rows
// name their cells by place through a header the format stores with `builder_append`.
builder_hook_rows :: #force_inline proc "contextless" (h: ^Rows_Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key {
		return s, builder_fact(&h.builder, s, t)
	}
	if t.role == .Key {
		return s, .Next
	}
	return builder_step(&h.builder, s, t, true, false)
}

// Stores the container `t` holding `count` scalars past the nodes the walk stored, in no container, for a format whose
// document keeps a list of nodes beside its root value, as a table's header. Child `c` is `child(of, c)`. It grows the
// room for them and returns false once the room cannot grow.
@(cold)
builder_append :: proc "contextless" (h: ^Builder, s: ^hook.Regs, t: tape.Token, of: []tape.Token, count: int, $child: proc "contextless" (of: []tape.Token, c: int) -> tape.Token) -> bool #no_bounds_check {
	for k in 0 ..= count {
		if s.a == h.end {
			ok: bool
			if s^, ok = builder_grow(h, s^, t.lo); !ok {
				return false
			}
		}
		node := t if k == 0 else child(of, k - 1)
		if k == 0 {
			count := u32(count)
			node.n = count + 1
			node.spelling = t.spelling & tape.CONTAINER_STYLE | u16(min(count, u32(tape.MAX_CHILDREN)))
			if count >= u32(tape.MAX_CHILDREN) {
				builder_partial_count(h, builder_cursor(h, s^), count)
			}
		}
		((^tape.Node)(uintptr(s.a)))^ = node
		s.a += size_of(tape.Node)
	}
	return h.err == nil
}

// `builder_hook_kept` that stores each container opened at level `stubs` as a single unread node, without its tokens.
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

// With `GROWS`, a node that finds the room full grows it first, and a refused growth stops the walk. Without it the
// walk grows the room before a node finds it full, because growing from the inlined hook would cost each of the walk's
// states a stack frame.
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
		// Two 8-byte stores, as the token's fields are packed in registers.
		((^[2]u64)(uintptr(s.a)))^ = transmute([2]u64)t
		s.a += size_of(tape.Node)
		// The open container's child count is the low half of `b`, so a member is counted with an add and no node is
		// read or written. A key is not a child.
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
	n.spelling = t.spelling & tape.CONTAINER_STYLE | u16(min(count, u32(tape.MAX_CHILDREN)))
	if count >= u32(tape.MAX_CHILDREN) {
		counts := (^runtime.Raw_Dynamic_Array)(&h.counts)
		([^]tape.Child_Count)(counts.data)[counts.len] = {tape.Node_Index(open), count}
		counts.len += 1
	}
	s.c -= 1
	s.b = h.stack[s.c]
	return s, .Next
}

// Panics in a debug or sanitizer build when the node `s` writes next lies past the room. Every walk prevents that
// through its room checks or through a hook that grows the room itself.
@(private)
room_check :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs) {
	when ODIN_DEBUG || ODIN_SANITIZER_FLAGS != {} {
		if s.a >= h.end {
			runtime.panic_contextless("build: a node past the room")
		}
	}
}

// Records the full child count of the partial container at `node`, whose `spelling` saturated. It reserves one entry
// beyond the current capacity, so the room for the containers closed with every child remains. A refused allocation is
// kept in `err`.
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

// Stores container token `t` as a single node with none of its children, marked partial with an unknown child count,
// for a walk that passes over the container. False once the room cannot grow.
@(private)
builder_unread :: proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, bool) #no_bounds_check {
	s := s
	if s.a == h.end {
		ok: bool
		if s, ok = builder_grow(h, s, t.lo); !ok {
			return s, false
		}
	}
	node := tape.Node{lo = t.lo, n = 1, kind = t.kind, role = t.role, spelling = t.spelling & tape.CONTAINER_STYLE | tape.CONTAINER_PARTIAL | tape.MAX_CHILDREN}
	room_check(h, s)
	((^tape.Node)(uintptr(s.a)))^ = node
	s.a += size_of(tape.Node)
	s.b += 1
	return s, true
}

// Grows the room for nodes, up to `most`, and moves `s.a` with it, for the token at offset `at` that finds the room
// full. The new size is the larger of twice the room and `have * (1 + 1.25 * rest / at)`, where `rest` is the text past
// `at`: the nodes the rest should make at the rate per byte so far, with a quarter more. A read that keeps nodes evenly
// therefore grows once. A refused size is retried with twice the room, then with half the growth, down to one node, so
// the room grows as far as its allocator gives. False, with `err` set, once a growth of one node is refused or the room holds `most`. No later
// growth clears `err`.
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
	if !builder_affords(h, have, want) {
		want = double if builder_affords(h, have, double) else builder_fit(h, have)
	}
	old := u64(uintptr(raw_data(h.doc.nodes)))
	raw, err := runtime.non_zero_mem_resize(raw_data(h.doc.nodes), have * size_of(tape.Node), want * size_of(tape.Node), align_of(tape.Node), h.doc.allocator)
	for err == .Out_Of_Memory && want > have + 1 {
		want = double if want > double else have + (want - have) / 2
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

// Sizes the room of `h` for `nodes` nodes, at most `most`, for a walk that knows how many nodes it gives before it
// gives the first, which `s` is to write. Keeps the room when it holds them, when the budget refuses the size or when
// memory is refused, and the walk grows it as it fills.
builder_room :: proc "contextless" (h: ^Builder, s: hook.Regs, nodes: int) -> hook.Regs {
	have := len(h.doc.nodes)
	want := min(nodes, h.most)
	if want <= have || h.err != nil || !builder_affords(h, have, want) {
		return s
	}
	context = h.ctx
	if builder_reserve_counts(h, want) != nil {
		return s
	}
	old := u64(uintptr(raw_data(h.doc.nodes)))
	raw, err := runtime.non_zero_mem_resize(raw_data(h.doc.nodes), have * size_of(tape.Node), want * size_of(tape.Node), align_of(tape.Node), h.doc.allocator)
	if took(err, raw_data(raw), want) != nil {
		return s
	}
	base := u64(uintptr(raw_data(raw)))
	h.doc.nodes = ([^]tape.Node)(raw_data(raw))[:want]
	h.end = base + u64(want * size_of(tape.Node))
	s := s
	s.a = base + (s.a - old)
	return s
}

// Stores fact token `t`, a comment or a tag, as a fact of the node it describes. A comment before a value is placed on
// the node it marks when `builder_end` runs `builder_place_facts`, and a tag is the next node's. An inline comment
// belongs to the last value completed, and a foot to the innermost open container, or to the root past the last one.
// `.Stop` when memory for the facts is refused.
@(private, cold)
builder_fact :: #force_no_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> hook.Action {
	a := builder_cursor(h, s)
	node := a
	kind := tape.fact_kind(t.role)
	#partial switch kind {
	case .Comment, .Tag:
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

// Gives each comment that waits for the value it marks that value's node: the node after the comment, or for a comment
// before a key, the key's value. A comment no node follows, past a stop, becomes the root's foot. Then sorts the facts
// by node.
@(private, cold)
builder_place_facts :: proc(doc: ^tape.Document, count: int) {
	doc.present += builder_place_comments(doc, doc.facts, count)
	builder_sort_facts(doc.facts)
}

// `builder_place_facts` for the comments among `facts`, which may be part of `doc`'s facts. Returns the fact kinds the
// comments end as.
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

// Sorts `facts` by node, only when one is out of order. Facts arrive mostly in node order.
@(private)
builder_sort_facts :: proc(facts: []tape.Fact) {
	for i in 1 ..< len(facts) {
		if facts[i].node < facts[i - 1].node {
			slice.stable_sort_by(facts, proc(a, b: tape.Fact) -> bool { return a.node < b.node })
			break
		}
	}
}

// Grows the open stack to `want` frames, for a walk about to nest past it. The first growth moves the stack out of the
// caller's frame into the allocator, where it would sit right after the node room and keep the room from growing in
// place. So the room grows first, as `s` and `at` give, which a walk that has no room of the builder's passes nil for.
@(cold)
builder_deepen :: #force_no_inline proc "contextless" (h: ^Builder, want: int, s: ^hook.Regs, at: u64) -> bool {
	if h.borrowed && s != nil && len(h.doc.nodes) < h.most {
		ok: bool
		if s^, ok = builder_grow(h, s^, at); !ok {
			return false
		}
	}
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

// Returns the document the walk built, or the error that ended it with everything freed. `err` is the walk's own error
// and takes precedence over the builder's. `regs` are the hook's registers at the walk's end and `root_close` is the
// end of the root value.
@(require_results)
builder_end :: proc(h: ^Builder, regs: hook.Regs, root_close: u64, err: tape.Error, refuse := false, rules: ^tape.Rules = nil) -> (doc: tape.Document, e: tape.Error) {
	e = err
	if e == nil {
		e = builder_error(h)
	}
	if fault, is_fault := e.(tape.Fault); is_fault && refuse {
		e = partial_repeat(h, regs, fault, rules)
	}
	if !h.borrowed {
		delete(h.stack, h.doc.allocator)
	}
	count := int(builder_cursor(h, regs))
	if e == nil && len(h.doc.facts) > 0 {
		// A comment past the root value's last node is the root's foot, whatever `builder_append` stored after it.
		builder_place_facts(&h.doc, int(tape.node_after(&h.doc, tape.ROOT)) if count > 0 else 0)
	}
	if e != nil {
		h.doc.facts = h.facts
		delete(h.counts)
		if h.lent {
			lent := h.doc.nodes
			h.doc.nodes = nil
			tape.destroy(&h.doc)
			h.doc.nodes = lent
		} else {
			tape.destroy(&h.doc)
		}
		return {}, e
	}
	doc = h.doc
	if len(h.counts) > 0 {
		// Counts are in closing order, an inner container before the one holding it, so they need sorting by node.
		slice.sort_by(h.counts[:], proc(a, b: tape.Child_Count) -> bool { return a.node < b.node })
		shrink(&h.counts)
		doc.counts = h.counts[:]
	} else {
		delete(h.counts)
	}
	// The room is resized to `count` nodes under a memory budget, so the document is charged for the nodes it holds.
	// Otherwise it is resized when more than half of it and more than `ROOM_SLACK` bytes are unused, unless it is on a
	// default heap that keeps a freed block's pages (`HEAP_KEEPS_PAGES`), where a resize frees none. A room kept whole
	// lets the allocator give its block to the next read of its size. A failed resize keeps the whole room. `destroy`
	// frees the room as one block from its start.
	doc.nodes = doc.nodes[:count]
	unused := len(h.doc.nodes) - count
	keeps_pages := HEAP_KEEPS_PAGES && doc.allocator.procedure == runtime.default_allocator_proc
	if !h.lent && (h.budget != nil && unused > 0 || !keeps_pages && unused > count && unused * size_of(tape.Node) > ROOM_SLACK) {
		if raw, err := runtime.non_zero_mem_resize(raw_data(doc.nodes), len(h.doc.nodes) * size_of(tape.Node), count * size_of(tape.Node), align_of(tape.Node), doc.allocator); took(err, raw_data(raw), count) == nil {
			doc.nodes = ([^]tape.Node)(raw_data(raw))[:count]
		}
	}
	doc.root_close = root_close
	return doc, nil
}

// The unused bytes up to which a document keeps its room whole rather than move its nodes to an exact block.
@(private)
ROOM_SLACK :: 1024

// Whether the default heap keeps a freed or shrunk large block's pages resident and gives the block to the next
// allocation of its size, as macOS's does.
@(private)
HEAP_KEEPS_PAGES :: ODIN_OS == .Darwin

// Returns a copy of the document the walk has built so far, for a text that ended inside its root value. The
// containers still open are closed at the cut, and a key whose value had not started is left out, so that the copy is
// a document of the values given. `regs` are the hook's registers at the cut and `cut` is the offset where more bytes
// are needed. `read`, when given, holds the children read so far of each open container by level, and a container that
// stored fewer is `CONTAINER_PARTIAL`. The builder is unchanged and goes on.
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
		nodes[open].spelling = nodes[open].spelling & tape.CONTAINER_STYLE | u16(min(children, u64(tape.MAX_CHILDREN))) | (tape.CONTAINER_PARTIAL if partial else 0)
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
	// The copy owns nothing the builder keeps. Its format extension and the scan's partial block stay the builder's,
	// since otherwise both would free them.
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
