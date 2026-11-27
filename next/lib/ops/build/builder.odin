package build

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Returns `err`, or `.Out_Of_Memory` when `p` is nil for a request of `n > 0`, which a nil or an empty allocator
// returns without an error.
took :: #force_inline proc "contextless" (err: runtime.Allocator_Error, p: rawptr, n: int) -> runtime.Allocator_Error {
	if err != nil {
		return err
	}
	if n > 0 && p == nil {
		return .Out_Of_Memory
	}
	return nil
}

@(private)
Builder_Flag :: enum u8 {
	Borrowed,        // `stack` is the caller's, which `builder_end` does not free
	Lent,            // the room of `doc.nodes` is the caller's, which `builder_end` keeps whole and does not free
	Keep_Facts,      // a scan keeps the facts of the nodes it keeps, which its inner hooks store
	Counts_Borrowed, // `counts` uses a caller-provided stack buffer, which `builder_end` does not free
}

@(private)
Builder_Flags :: bit_set[Builder_Flag; u8]

@(private)
MAX_FACTS :: max(int) / size_of(tape.Fact)
@(private)
MAX_COUNTS :: max(int) / size_of(tape.Child_Count)
@(private)
MAX_STACK :: max(int) / size_of(u64)

// The hook that stores a walk's tokens as a document's nodes and, through `builder_hook_facts`, its fact tokens as the
// document's facts. Registers: `a` is the address of the next node, `b` holds the open container's node index in its
// high 32 bits and its child count in its low 32 bits, and `c` is the number of open containers.
//
// Hot per-container and per-token fields (`stack`, `end`, `closed`, `err`, `flags`, `doc.nodes`) are packed into Cache
// Line 0 (0..63 on 64-bit) with explicit padding so the struct has no implicit holes.
Builder :: struct {
	stack:    []u64, // the saved `b` of each open container's parent, with the container counted as a child
	end:      u64, // the address one past the room of `doc.nodes`, where a node written grows the room first
	closed:   tape.Node_Index, // the container closed last, `NO_NODE` before one closes. Kept by `builder_hook_facts`
	err:      runtime.Allocator_Error, // a refused allocation, or `Out_Of_Memory` with `full`
	flags:    Builder_Flags,
	_pad:     [2]u8,
	doc:      tape.Document,
	// The full child counts of the containers whose `spelling` saturated, in the order they closed. `builder_end` sorts
	// them by node. A container closed with every child holds a node per child, so a room of `n` nodes closes at most
	// `n / MAX_CHILDREN` of them. `counts` has room for those past the entries of partial containers, reserved as the
	// room grows, or before the nodes when `builder_start` is given the nodes to reserve for.
	counts:   [dynamic]tape.Child_Count,
	facts:    []tape.Fact, // the facts' buffer, of which `doc.facts` is the part in use
	most:     int, // the most nodes the room may grow to
	full:     u64, // one past the offset of the token a room of `most` nodes had no place for, else 0
	// For `builder_hook_stubs`: `stubs` is the open-container count `c` at which a child container is stored as an
	// unread node, and `unstored` counts the container stored so and the containers open inside it.
	stubs:    u64,
	unstored: u64,
	// The budget the builder's allocator counts against, or nil. Under it the room for nodes is never sized past what
	// the budget leaves, so a refusal comes from the nodes the text needs and not from a room sized ahead of them.
	budget:   ^hook.Memory_Budget,
	// Allocator for short-lived `stack` growth freed in `builder_end`; defaults to `doc.allocator`.
	scratch:  runtime.Allocator,
	ctx:      runtime.Context, // the caller's, for the allocations the contextless hook makes
	// The first node the walk stores: 0, or in a segment its first past the nodes of the segments before it.
	first:    tape.Node_Index,
	_pad2:    [4]u8,
	protocol: hook.Protocol(BUILDER_CAPS, Builder_Levels, Builder_Rooms, hook.Unused),
}

#assert(size_of(Builder) % size_of(u64) == 0)

when size_of(rawptr) == 8 {
	#assert(offset_of(Builder, stack) == 0)
	#assert(offset_of(Builder, end) == 16)
	#assert(offset_of(Builder, closed) == 24)
	#assert(offset_of(Builder, err) == 28)
	#assert(offset_of(Builder, flags) == 29)
	#assert(offset_of(Builder, doc) == 32)
	#assert(offset_of(Builder, doc) + offset_of(tape.Document, nodes) + size_of(tape.Document{}.nodes) == 64)
	#assert(size_of(Builder) == 384)
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
	return builder_cursor_addr(b, s.a)
}

// The index of the node at write pointer `a`.
@(private)
builder_cursor_addr :: #force_inline proc "contextless" (b: ^Builder, a: u64) -> tape.Node_Index {
	return tape.Node_Index((uintptr(a) - uintptr(raw_data(b.doc.nodes))) / size_of(tape.Node))
}

// The allocator for `h.stack` growth.
@(private)
builder_scratch :: #force_inline proc "contextless" (h: ^Builder) -> runtime.Allocator {
	return h.scratch if h.scratch.procedure != nil else h.doc.allocator
}

// Whether `a` and `c` (typically `doc.allocator` and `counts.allocator`) draw from the same underlying allocator,
// including when wrapped in paired `Memory_Budget` peers.
@(private)
same_backing :: proc "contextless" (b: ^Builder, a, c: runtime.Allocator) -> bool {
	if a == c {
		return true
	}
	if b.budget != nil && b.budget.peer != nil {
		main := hook.memory_budget(b.budget)
		peer := hook.memory_budget(b.budget.peer)
		if a == main && c == peer || a == peer && c == main {
			return b.budget.backing == b.budget.peer.backing
		}
	}
	return false
}

// Whether `a` supports freeing individual blocks, so allocations after `doc.nodes` do not prevent it from growing.
@(private)
allocator_has_free :: proc(a: runtime.Allocator) -> bool {
	if a.procedure == runtime.default_allocator_proc {
		return true
	}
	if a.procedure == nil {
		return false
	}
	set: runtime.Allocator_Mode_Set
	_, err := a.procedure(a.data, .Query_Features, 0, 0, &set, 0)
	return err == nil && .Free in set
}

// Initial hook registers for a walk filling `h`.
builder_regs :: #force_inline proc "contextless" (h: ^Builder) -> hook.Regs {
	return {a = u64(uintptr(raw_data(h.doc.nodes))), b = u64(tape.NO_NODE) << 32, c = 0}
}

// Makes `b` a builder over `src` with room for `nodes` nodes, growing up to `most`, and `frames` for its open stack. A
// refused allocation leaves `err` set. `budget` is the one `allocator` counts against, if any. A `lent` room, from
// `allocator`, is built in instead of a room of `nodes`, and it grows as such a room does. The child counts are
// reserved for the first room, or with `counts` set for that many nodes ahead of the room on a non-freeing unbudgeted
// allocator so it can grow the room in place. `counts_buf`, when given, backs `counts` until it overflows or
// `builder_end` copies non-empty counts out. `scratch`, when set, backs `stack` growth past `frames`.
builder_start :: proc(b: ^Builder, src: []u8, format: ^tape.Format, nodes, most: int, frames: []u64, allocator: runtime.Allocator, budget: ^hook.Memory_Budget = nil, lent: []tape.Node = nil, counts := 0, counts_buf: []tape.Child_Count = nil, scratch: runtime.Allocator = {}) {
	b.ctx = context
	b.doc.allocator = allocator
	b.scratch = scratch if scratch.procedure != nil else allocator
	b.first = 0
	builder_again(b, src, format, nodes, most, frames, budget, lent, counts, counts_buf)
}

// Starts `b`, which `builder_start` started and `builder_end` ended, reusing `b.doc.allocator`, `b.scratch`, `b.ctx`,
// and `b.first` (which it does not reset). Resets all other fields, including `b.end` (set to 0 on early failure).
@(private)
builder_again :: proc(b: ^Builder, src: []u8, format: ^tape.Format, nodes, most: int, frames: []u64, budget: ^hook.Memory_Budget = nil, lent: []tape.Node = nil, counts := 0, counts_buf: []tape.Child_Count = nil) {
	b.doc = {src = src, format = format, allocator = b.doc.allocator}
	b.stack, b.end, b.closed, b.err = frames, 0, tape.NO_NODE, nil
	b.flags = {.Borrowed} | ({.Lent} if len(lent) > 0 else {})
	b.facts, b.most, b.full, b.stubs, b.unstored, b.budget = nil, most, 0, 0, 0, budget
	b.counts = {}
	b.counts.allocator = builder_scratch(b)
	if len(counts_buf) > 0 {
		rc := (^runtime.Raw_Dynamic_Array)(&b.counts)
		rc.data = raw_data(counts_buf)
		rc.cap = len(counts_buf)
		b.flags += {.Counts_Borrowed}
	}
	if .Lent in b.flags {
		b.doc.nodes = lent[:min(len(lent), most)]
		b.end = u64(uintptr(raw_data(b.doc.nodes))) + u64(len(b.doc.nodes) * size_of(tape.Node))
		b.err = builder_reserve_counts(b, max(counts, len(b.doc.nodes)))
		return
	}
	if b.doc.allocator.procedure == nil {
		b.err = .Out_Of_Memory
		return
	}
	// When `counts` shares a non-freeing allocator (such as a bump arena) with `doc.nodes`, pre-reserve the worst-case
	// counts ahead of `doc.nodes` so `doc.nodes` remains the last block and can grow in place. Under a budget, cap by
	// the most nodes that fit in the budget so tiny budgets on huge single-node texts reserve nothing extra.
	if same_backing(b, b.counts.allocator, b.doc.allocator) && !allocator_has_free(b.doc.allocator) {
		counts_cap := counts
		if counts_cap == 0 && (budget != nil || most <= len(src) + 2) {
			counts_cap = most
		}
		if budget != nil {
			counts_cap = min(counts_cap, builder_fit(b, 0))
		}
		if wide_room(counts_cap) > cap(b.counts) {
			if b.err = builder_reserve_counts(b, counts_cap); b.err != nil {
				return
			}
		}
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
	raw, err := runtime.mem_alloc_non_zeroed(room * size_of(tape.Node), align_of(tape.Node), b.doc.allocator)
	if b.err = took(err, raw_data(raw), room); b.err != nil {
		if .Counts_Borrowed not_in b.flags && cap(b.counts) > 0 {
			delete(b.counts)
			b.counts = {}
		}
		return
	}
	b.doc.nodes = ([^]tape.Node)(raw_data(raw))[:room]
	b.end = u64(uintptr(raw_data(raw))) + u64(room * size_of(tape.Node))
}

// Reserves the entries of `counts` the containers closed in a room of `room` nodes may need.
@(private)
builder_reserve_counts :: proc(b: ^Builder, room: int) -> runtime.Allocator_Error {
	wide := len(b.counts) + wide_room(room)
	return nil if wide <= cap(b.counts) else builder_counts_grow(b, wide, wide)
}

// Grows `b.counts` to `want` (backing off down to `need` on OOM), migrating out of a borrowed stack buffer if needed.
@(private = "file", cold)
builder_counts_grow :: proc(b: ^Builder, want, need: int) -> runtime.Allocator_Error {
	if need > MAX_COUNTS || b.counts.allocator.procedure == nil {
		return .Out_Of_Memory
	}
	want := want
	if .Counts_Borrowed in b.flags {
		raw, err := runtime.mem_alloc_non_zeroed(want * size_of(tape.Child_Count), align_of(tape.Child_Count), b.counts.allocator)
		for err == .Out_Of_Memory && want > need {
			want = need + (want - need) / 2
			raw, err = runtime.mem_alloc_non_zeroed(want * size_of(tape.Child_Count), align_of(tape.Child_Count), b.counts.allocator)
		}
		took(err, raw_data(raw), want) or_return
		if len(b.counts) > 0 {
			copy(([^]tape.Child_Count)(raw_data(raw))[:want], b.counts[:])
		}
		rc := (^runtime.Raw_Dynamic_Array)(&b.counts)
		rc.data, rc.cap = raw_data(raw), want
		b.flags -= {.Counts_Borrowed}
		return nil
	}
	err := non_zero_reserve(&b.counts, want)
	for err == .Out_Of_Memory && want > need {
		want = need + (want - need) / 2
		err = non_zero_reserve(&b.counts, want)
	}
	return .Out_Of_Memory if err == nil && cap(b.counts) < need else err
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
	held_cap := 0 if .Counts_Borrowed in b.flags else cap(b.counts)
	counts := max(len(b.counts) + wide_room(room) - held_cap, 0)
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
		return s, builder_fact(h, s.a, s.b, t)
	}
	return builder_step(h, s, t, true, false)
}

// `builder_hook` for the containers that a hook holding the builder keeps through its `Keeps`. Fact tokens are stored
// when `.Keep_Facts` is set and dropped otherwise.
builder_hook_kept :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key {
		if .Keep_Facts in h.flags {
			return s, builder_fact(h, s.a, s.b, t)
		}
		return s, .Next
	}
	return builder_step(h, s, t, true, false)
}

// `builder_hook_facts` for a table, whose walk gives each cell its column's key: it stores no key, as a table's rows
// name their cells by place through a header the format keeps in its `Tabular_Ext`.
builder_hook_rows :: #force_inline proc "contextless" (h: ^Rows_Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key {
		return s, builder_fact(&h.builder, s.a, s.b, t)
	}
	if t.role == .Key {
		return s, .Next
	}
	return builder_step(&h.builder, s, t, true, false)
}

// `builder_hook_kept` that stores each container opened at level `stubs` as a single unread node, without its tokens.
@(private)
builder_hook_stubs :: #force_inline proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role > .Key {
		if .Keep_Facts in h.flags && h.unstored == 0 {
			return s, builder_fact(h, s.a, s.b, t)
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
		kept, ok := builder_unread(h, s, t, false)
		return kept, .Next if ok else .Stop
	}
	return builder_step(h, s, t, true, false)
}

// With `GROWS`, a node that finds the room full grows it first, and a refused growth stops the walk. Without it the
// walk grows the room before a node finds it full, because growing from the inlined hook would cost each of the walk's
// states a stack frame.
//
// `#no_bounds_check` invariants guaranteed by the walk's `Levels`/`Rooms` protocol and `builder_reserve_counts`:
// - `s.a < h.end` whenever writing a node (or grown first when `GROWS`);
// - `s.c < len(h.stack)` on container open and `s.c > 0` on `.End`;
// - `open < len(h.doc.nodes)` on `.End` (saved from an earlier container open in this room);
// - `cap(h.counts) > len(h.counts)` whenever `count >= MAX_CHILDREN` (reserved for `wide_room(len(doc.nodes))`).
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
		((^[2]u64)(uintptr(s.a)))^ = transmute([2]u64)t
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
	if intrinsics.expect(count >= u32(tape.MAX_CHILDREN), false) {
		counts := (^runtime.Raw_Dynamic_Array)(&h.counts)
		cn := counts.len
		([^]tape.Child_Count)(counts.data)[cn] = {tape.Node_Index(open), count}
		counts.len = cn + 1
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

// Records the full child count of the partial container at `node`, whose `spelling` saturated. Reserves geometrically
// so the room for containers closed with every child (`wide_room(len(doc.nodes))`) remains past the partial entries,
// clamped by `h.budget` with OOM backoff down to `need`. A refused allocation is kept in `err`.
@(private, cold)
builder_partial_count :: #force_no_inline proc "contextless" (h: ^Builder, node: tape.Node_Index, count: u32) {
	if h.err != nil {
		return
	}
	need := len(h.counts) + 1 + wide_room(len(h.doc.nodes))
	if need > cap(h.counts) {
		context = h.ctx
		have := cap(h.counts)
		want := max(MAX_COUNTS if have > MAX_COUNTS / 2 else max(2 * have, 8), need)
		if h.budget != nil {
			held_cap := 0 if .Counts_Borrowed in h.flags else have
			fit := held_cap + int(min(hook.memory_budget_left(h.budget) / size_of(tape.Child_Count), u64(MAX_COUNTS - held_cap)))
			want = min(want, max(held_cap + max((fit - held_cap) / 2, 1), need))
		}
		if err := builder_counts_grow(h, want, need); err != nil {
			h.err = err
			return
		}
	}
	// `cap(h.counts) >= need > len(h.counts)` is guaranteed above.
	#no_bounds_check {
		rc := (^runtime.Raw_Dynamic_Array)(&h.counts)
		cn := rc.len
		([^]tape.Child_Count)(rc.data)[cn] = {node, count}
		rc.len = cn + 1
	}
}

// Stores container token `t` as a single node with none of its children, marked partial with an unknown child count,
// for a walk that passes over the container. False once the room cannot grow.
//
// `#no_bounds_check` invariant: when `GROWS` is false, the walk's `Rooms` check guarantees `s.a < h.end`; when true,
// `builder_grow` runs first when `s.a == h.end`.
@(private)
builder_unread :: proc "contextless" (h: ^Builder, s: hook.Regs, t: tape.Token, $GROWS: bool) -> (hook.Regs, bool) #no_bounds_check {
	s := s
	when GROWS {
		if s.a == h.end {
			ok: bool
			if s, ok = builder_grow(h, s, t.lo); !ok {
				return s, false
			}
		}
	}
	node := tape.Node{lo = t.lo, n = 1, kind = t.kind, role = t.role, spelling = t.spelling & tape.CONTAINER_STYLE | tape.CONTAINER_PARTIAL | tape.MAX_CHILDREN}
	room_check(h, s)
	((^[2]u64)(uintptr(s.a)))^ = transmute([2]u64)node
	s.a += size_of(tape.Node)
	s.b += 1
	return s, true
}

// Grows the room for nodes, up to `most`, and moves `s.a` with it, for the token at offset `at` that finds the room
// full. The new size is the larger of twice the room and `have * (1 + 1.25 * rest / at)`, where `rest` is the text past
// `at`: the nodes the rest should make at the rate per byte so far, with a quarter more. A read that keeps nodes evenly
// therefore grows once. Under a budget a growth takes at most half of what the budget leaves. A refused size is retried
// with twice the room, then with half the growth, down to one node, so the room grows as far as its allocator gives.
// False, with `err` set, once a growth of one node is refused or the room holds `most`. No later growth clears `err`.
@(private = "file", cold)
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
	double := h.most if have > h.most / 2 else min(max(2 * have, 1), h.most)
	want := double
	if at > 0 && at < u64(len(h.doc.src)) {
		rest := f64(u64(len(h.doc.src)) - at)
		want = max(want, int(min(f64(h.most), f64(have) * (1 + 1.25 * rest / f64(at)))))
	}
	if h.budget != nil {
		// Under a budget a growth takes at most half of what the budget leaves, as the first room does, so that the
		// blocks the read allocates after the nodes find room, whatever the budget is.
		fit := builder_fit(h, have)
		want = min(want, have + max((fit - have) / 2, 1))
	}
	old := u64(uintptr(raw_data(h.doc.nodes)))
	raw, err := runtime.non_zero_mem_resize(raw_data(h.doc.nodes), have * size_of(tape.Node), want * size_of(tape.Node), align_of(tape.Node), h.doc.allocator)
	for err == .Out_Of_Memory && want > have + 1 {
		want = double if want > double else have + (want - have) / 2
		raw, err = runtime.non_zero_mem_resize(raw_data(h.doc.nodes), have * size_of(tape.Node), want * size_of(tape.Node), align_of(tape.Node), h.doc.allocator)
	}
	if h.err = took(err, raw_data(raw), want); h.err != nil {
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
	// Resize `nodes` before reserving `counts` so a bump arena can grow the node room in place.
	old := u64(uintptr(raw_data(h.doc.nodes)))
	raw, err := runtime.non_zero_mem_resize(raw_data(h.doc.nodes), have * size_of(tape.Node), want * size_of(tape.Node), align_of(tape.Node), h.doc.allocator)
	if took(err, raw_data(raw), want) != nil {
		return s
	}
	base := u64(uintptr(raw_data(raw)))
	h.doc.nodes = ([^]tape.Node)(raw_data(raw))[:want]
	s := s
	s.a = base + (s.a - old)
	if cerr := builder_reserve_counts(h, want); cerr != nil {
		// Keep `h.doc.nodes` at the allocated `want` length so teardown frees the right size, and stop the walk at the
		// next room check via `h.err` / `h.end = s.a` so no saturated container writes past `counts`.
		h.err = cerr
		h.end = s.a
		return s
	}
	h.end = base + u64(want * size_of(tape.Node))
	return s
}

// Stores fact token `t` as a fact of the node it describes. A comment, an instruction or a document type before a value
// is placed on the node it marks when `builder_end` runs `builder_place_facts`, a tag or an attribute is the next
// node's, and a directive the root's. An inline comment belongs to the last value completed, and a foot to the
// innermost open container, or to the root past the last one, except a foot right after a key, which a markup element
// with no child element holds, and which is its value's. An instruction's foot is placed as a comment's. `.Stop` when memory for the facts is refused.
//
// `#no_bounds_check` invariants: `h.closed` is `NO_NODE` or a valid node index in `h.doc.nodes` (including a segment's
// scratch `before` node); `a` is `<= len(h.doc.nodes)` and `a > h.first` guarantees `a - 1 < len(h.doc.nodes)`;
// `builder_grow_facts` guarantees `n < len(h.facts)` and `n + 1 <= len(h.facts)`.
@(private, cold)
builder_fact :: #force_no_inline proc "contextless" (h: ^Builder, a_addr, b: u64, t: tape.Token) -> hook.Action #no_bounds_check {
	a := builder_cursor_addr(h, a_addr)
	node := a
	kind := tape.fact_kind(t.role)
	#partial switch kind {
	case .Comment, .Tag, .Anchor, .Alias, .Attribute, .Instruction, .Doctype:
	case .Directive:
		node = tape.ROOT
	case .Comment_Inline:
		// The container closed last is the last value completed when no node was stored after its subtree.
		// `h.closed + Node_Index(nodes[h.closed].n)` intentionally uses wrapping `u32` arithmetic: `segment_start`
		// stores `room[before].n = u32(first) - u32(before)` so `before + n == first` modulo 2^32.
		node = a - 1 if a > 0 else tape.ROOT
		if h.closed != tape.NO_NODE && h.closed + tape.Node_Index(h.doc.nodes[h.closed].n) == a {
			node = h.closed
		}
	case .Comment_Foot, .Instruction_Foot:
		node = tape.Node_Index(b >> 32)
		// A key before the cursor with no value stored is a member of the innermost open container, when this walk
		// stored it after the container's node. That node lies before its members, or in a segment that opened inside
		// it is a scratch node past every segment's nodes, and the node before the segment's first is another's.
		if a > h.first && node != a - 1 && node != tape.NO_NODE && h.doc.nodes[a - 1].role == .Key && h.doc.nodes[a - 1].kind <= .Plain {
			node = a
			break
		}
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

// Doubles the room for facts (clamped by `h.budget` and `MAX_FACTS`, with OOM backoff down to +1 fact), or sets `err`
// when memory is refused.
@(private, cold)
builder_grow_facts :: proc "contextless" (h: ^Builder) -> bool {
	have := len(h.facts)
	if h.err != nil {
		return false
	}
	if have >= MAX_FACTS {
		h.err = .Out_Of_Memory
		return false
	}
	context = h.ctx
	want := MAX_FACTS if have > MAX_FACTS / 2 else max(2 * have, min(16, MAX_FACTS))
	if h.budget != nil {
		fit := have + int(min(hook.memory_budget_left(h.budget) / size_of(tape.Fact), u64(MAX_FACTS - have)))
		want = min(want, have + max((fit - have) / 2, 1))
	}
	raw, err := runtime.non_zero_mem_resize(raw_data(h.facts), have * size_of(tape.Fact), want * size_of(tape.Fact), align_of(tape.Fact), h.doc.allocator)
	for err == .Out_Of_Memory && want > have + 1 {
		want = have + (want - have) / 2
		raw, err = runtime.non_zero_mem_resize(raw_data(h.facts), have * size_of(tape.Fact), want * size_of(tape.Fact), align_of(tape.Fact), h.doc.allocator)
	}
	if h.err = took(err, raw_data(raw), want); h.err != nil {
		return false
	}
	h.facts = ([^]tape.Fact)(raw_data(raw))[:want]
	h.doc.facts = h.facts[:len(h.doc.facts)]
	return true
}

// Gives each comment, instruction or document type that waits for the value it marks that value's node: the node after
// it, or for one before a key, the key's value. One no node follows, past a stop, is the root's, and a comment or an
// instruction is its foot. Then sorts the facts by node.
@(private, cold)
builder_place_facts :: proc(doc: ^tape.Document, count: int) {
	doc.present += builder_place_comments(doc, doc.facts, count)
	builder_sort_facts(doc.facts)
}

// `builder_place_facts` for the comments among `facts`, which may be part of `doc`'s facts. Returns the fact kinds the
// comments end as.
//
// `#no_bounds_check` invariant: caller guarantees `0 <= count <= len(doc.nodes)`, so `uint(f.node) < uint(count)`
// dominates `doc.nodes[f.node]` on both 64-bit and 32-bit targets.
@(private)
builder_place_comments :: proc "contextless" (doc: ^tape.Document, facts: []tape.Fact, count: int) -> (present: tape.Facts) #no_bounds_check {
	for &f in facts {
		if f.kind != .Comment && f.kind != .Instruction && f.kind != .Doctype {
			continue
		}
		if uint(f.node) < uint(count) && doc.nodes[f.node].role == .Key {
			// A key may be a container, whose subtree comes before its value.
			key := doc.nodes[f.node]
			f.node += 1 if key.kind <= .Plain else tape.Node_Index(key.n)
		}
		if uint(f.node) >= uint(count) {
			f.node = tape.ROOT
			#partial switch f.kind {
			case .Comment:
				f.kind = .Comment_Foot
			case .Instruction:
				f.kind = .Instruction_Foot
			}
			present += {f.kind}
		} else if f.kind == .Comment {
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

// Grows the open stack to `want` frames, for a walk about to nest past it. When the first growth moves the stack out
// of the caller's frame into the same non-freeing unbudgeted allocator as the node room, the room grows first (as `s`
// and `at` give, which a walk with no room passes nil for) so the stack does not block in-place room growth.
@(private, cold)
builder_deepen :: #force_no_inline proc "contextless" (h: ^Builder, want: int, s: ^hook.Regs, at: u64) -> bool {
	if want > MAX_STACK {
		if h.err == nil {
			h.err = .Out_Of_Memory
		}
		return false
	}
	context = h.ctx
	scratch := builder_scratch(h)
	if .Borrowed in h.flags && len(h.stack) > 0 && s != nil && h.budget == nil && scratch == h.doc.allocator && !allocator_has_free(h.doc.allocator) && len(h.doc.nodes) < h.most {
		ok: bool
		if s^, ok = builder_grow(h, s^, at); !ok {
			return false
		}
	}
	raw: []u8
	err: runtime.Allocator_Error
	if .Borrowed not_in h.flags {
		raw, err = runtime.non_zero_mem_resize(raw_data(h.stack), len(h.stack) * size_of(u64), want * size_of(u64), align_of(u64), scratch)
	} else {
		raw, err = runtime.mem_alloc_non_zeroed(want * size_of(u64), align_of(u64), scratch)
	}
	if e := took(err, raw_data(raw), want); e != nil {
		if h.err == nil {
			h.err = e
		}
		return false
	}
	stack := ([^]u64)(raw_data(raw))[:want]
	if .Borrowed in h.flags && len(h.stack) > 0 {
		copy(stack, h.stack)
	}
	h.stack = stack
	h.flags -= {.Borrowed}
	return true
}

// The error that stopped the builder, nil for none.
@(private)
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
	if intrinsics.expect(err != nil || h.full != 0 || h.err != nil, false) {
		return {}, builder_end_error(h, regs, err, refuse, rules)
	}
	if intrinsics.expect(.Borrowed not_in h.flags, false) {
		builder_free_stack(h)
	}
	count := int(builder_cursor(h, regs))
	if intrinsics.expect(len(h.doc.facts) > 0, false) {
		// A comment past the root value's last node is the root's foot.
		builder_place_facts(&h.doc, int(tape.node_after(&h.doc, tape.ROOT)) if count > 0 else 0)
	}
	// A lent room is the caller's, kept whole. Trim nodes before copying borrowed counts so a tight budget reclaims
	// excess node room first.
	h.doc.nodes = h.doc.nodes[:count] if .Lent in h.flags else builder_trim(h, h.doc.nodes, count)
	if intrinsics.expect(len(h.doc.facts) > 0 && raw_data(h.doc.facts) == raw_data(h.facts), false) {
		h.doc.facts = builder_trim(h, h.facts, len(h.doc.facts))
	}
	if intrinsics.expect(len(h.counts) > 0, false) {
		cerr: runtime.Allocator_Error
		h.doc.counts, cerr = builder_finish_counts(h)
		if cerr != nil {
			return {}, builder_end_fail(h, cerr)
		}
	} else if intrinsics.expect(.Counts_Borrowed not_in h.flags && cap(h.counts) > 0, false) {
		builder_free_counts(h)
	}
	h.doc.root_close = root_close
	return h.doc, nil
}

@(private = "file", cold)
builder_free_stack :: #force_no_inline proc(h: ^Builder) {
	delete(h.stack, builder_scratch(h))
}

@(private = "file", cold)
builder_free_counts :: #force_no_inline proc(h: ^Builder) {
	delete(h.counts)
}

// Cold error teardown for `builder_end`, keeping the 40-byte `Error` union and `partial_repeat`/`tape.destroy` out of
// the clean success path.
@(private = "file", cold)
builder_end_error :: #force_no_inline proc(h: ^Builder, regs: hook.Regs, err: tape.Error, refuse: bool, rules: ^tape.Rules) -> tape.Error {
	e := err
	if e == nil {
		e = builder_error(h)
	}
	if fault, is_fault := e.(tape.Fault); is_fault && refuse {
		e = partial_repeat(h, regs, fault, rules)
	}
	if .Borrowed not_in h.flags {
		delete(h.stack, builder_scratch(h))
	}
	h.doc.facts = h.facts
	if .Counts_Borrowed not_in h.flags && cap(h.counts) > 0 {
		delete(h.counts)
	}
	return builder_end_fail(h, e)
}

// Destroys `h.doc` (preserving a lent node room) and returns `e`.
@(private = "file", cold)
builder_end_fail :: #force_no_inline proc(h: ^Builder, e: tape.Error) -> tape.Error {
	if .Lent in h.flags {
		lent := h.doc.nodes
		h.doc.nodes = nil
		tape.destroy(&h.doc)
		h.doc.nodes = lent
	} else {
		tape.destroy(&h.doc)
	}
	return e
}

// Sorts and finalizes non-empty `h.counts` into an owned slice for `doc.counts`.
@(private = "file", cold)
builder_finish_counts :: #force_no_inline proc(h: ^Builder) -> (res: []tape.Child_Count, rerr: runtime.Allocator_Error) {
	// Counts are in closing order, an inner container before the one holding it, so they need sorting by node.
	slice.sort_by(h.counts[:], proc(a, b: tape.Child_Count) -> bool { return a.node < b.node })
	if .Counts_Borrowed in h.flags || !same_backing(h, h.counts.allocator, h.doc.allocator) {
		n := len(h.counts)
		tmp: [64]tape.Child_Count = ---
		src := h.counts[:]
		if .Counts_Borrowed not_in h.flags {
			if n <= len(tmp) {
				copy(tmp[:n], src)
				delete(h.counts)
				h.counts = {}
				src = tmp[:n]
			} else if h.counts.allocator.procedure != nil {
				shrink(&h.counts)
				src = h.counts[:]
			}
		}
		defer if .Counts_Borrowed not_in h.flags && len(h.counts) > 0 {
			delete(h.counts)
			h.counts = {}
		}
		raw, err := runtime.mem_alloc_non_zeroed(n * size_of(tape.Child_Count), align_of(tape.Child_Count), h.doc.allocator)
		took(err, raw_data(raw), n) or_return
		out := ([^]tape.Child_Count)(raw_data(raw))[:n]
		copy(out, src)
		return out, nil
	}
	if h.counts.allocator.procedure != nil {
		shrink(&h.counts)
	}
	if h.counts.allocator != h.doc.allocator && h.budget != nil && h.budget.peer != nil {
		bytes := u64(cap(h.counts) * size_of(tape.Child_Count))
		h.budget.peer.held -= min(h.budget.peer.held, bytes)
		h.budget.held += bytes
	}
	return h.counts[:], nil
}

// The first `count` entries of `room`, a room of the builder's nodes or facts, resized to them under a memory budget,
// so the document is charged for what it holds. Otherwise it is resized when more than half of it and more than
// `ROOM_SLACK` bytes are unused, unless it is on a default heap that keeps a freed block's pages (`HEAP_KEEPS_PAGES`),
// where a resize frees none. A room kept whole lets the allocator give its block to the next read of its size. A
// failed resize keeps the whole room. `destroy` frees the room as one block from its start.
@(private)
builder_trim :: #force_inline proc(h: ^Builder, room: []$T, count: int) -> []T {
	unused := len(room) - count
	keeps_pages := HEAP_KEEPS_PAGES && h.doc.allocator.procedure == runtime.default_allocator_proc
	if intrinsics.expect(h.budget != nil && unused > 0 || !keeps_pages && unused > count && unused * size_of(T) > ROOM_SLACK, false) {
		return builder_trim_resize(h, room, count)
	}
	return room[:count]
}

@(private = "file", cold)
builder_trim_resize :: #force_no_inline proc(h: ^Builder, room: []$T, count: int) -> []T {
	if raw, err := runtime.non_zero_mem_resize(raw_data(room), len(room) * size_of(T), count * size_of(T), align_of(T), h.doc.allocator); took(err, raw_data(raw), count) == nil {
		return ([^]T)(raw_data(raw))[:count]
	}
	return room[:count]
}

// The unused bytes up to which a document keeps its room whole rather than move its nodes to an exact block.
@(private)
ROOM_SLACK :: 1024

// Whether the default heap keeps a freed or shrunk large block's pages resident and gives the block to the next
// allocation of its size, as macOS's does.
@(private)
HEAP_KEEPS_PAGES :: ODIN_OS == .Darwin

// Returns a copy of the document the walk has built so far, for a text that ended inside its root value. The
// containers still open are closed at the cut, and a key (scalar or container, complete or still open) whose value had
// not started is left out, so that the copy is a document of the values given. `regs` are the hook's registers at the
// cut and `cut` is the offset where more bytes are needed. `read`, when given, holds the children read so far of each
// open container by level, and a container that stored fewer is `CONTAINER_PARTIAL`. The builder is unchanged and goes
// on.
@(private, require_results)
builder_so_far :: proc(h: ^Builder, regs: hook.Regs, cut: u64, allocator: runtime.Allocator, read: []u64 = nil) -> (doc: tape.Document, err: tape.Error) {
	if e := builder_error(h); e != nil {
		return {}, e
	}
	count := int(builder_cursor(h, regs))
	open_c := regs.c
	top_b := regs.b
	// If any open container on the stack is itself a key (container key whose value has not started), unwind past it.
	if open_c > 0 {
		b_scan := top_b
		key_c := u64(0)
		key_open := 0
		for c := open_c; c > 0; c -= 1 {
			open := int(b_scan >> 32)
			if h.doc.nodes[open].role == .Key {
				key_c, key_open = c, open
			}
			b_scan = h.stack[c - 1]
		}
		if key_c > 0 {
			count = key_open
			open_c = key_c - 1
			top_b = h.stack[key_c - 1]
			if u32(top_b) > 0 {
				top_b -= 1
			}
		}
	}
	// Drop a completed trailing scalar or container key in the innermost open container whose value has not started.
	inner := int(top_b >> 32) if open_c > 0 else -1
	if count > 0 && count - 1 > inner {
		if h.doc.nodes[count - 1].role == .Key {
			count -= 1
		} else if h.closed != tape.NO_NODE && int(h.closed) > inner && int(h.closed) + int(h.doc.nodes[h.closed].n) == count && h.doc.nodes[h.closed].role == .Key {
			count = int(h.closed)
			if u32(top_b) > 0 {
				top_b -= 1
			}
		}
	}
	nodes, nerr := make([]tape.Node, count, allocator)
	if e := took(nerr, raw_data(nodes), count); e != nil {
		return {}, e
	}
	defer if err != nil {
		delete(nodes, allocator)
	}
	copy(nodes, h.doc.nodes[:count])

	// Count exact `Child_Count` entries needed (closed containers kept before `count` + open containers whose count
	// saturates and fits in `u32`). This avoids dynamic-array growth fallback to `context.allocator` or silent drops
	// under `nil_allocator()`.
	total_counts := 0
	for cc in h.counts {
		if uint(cc.node) < uint(count) {
			total_counts += 1
		}
	}
	b := top_b
	for c := open_c; c > 0; c -= 1 {
		children := u64(u32(b))
		if read != nil && read[c - 1] != children {
			children = read[c - 1]
		}
		if children >= u64(tape.MAX_CHILDREN) && children <= u64(max(u32)) {
			total_counts += 1
		}
		b = h.stack[c - 1]
	}
	counts, cerr := make([]tape.Child_Count, total_counts, allocator)
	if e := took(cerr, raw_data(counts), total_counts); e != nil {
		return {}, e
	}
	defer if err != nil {
		delete(counts, allocator)
	}
	ci := 0
	for cc in h.counts {
		if uint(cc.node) < uint(count) {
			counts[ci] = cc
			ci += 1
		}
	}
	b = top_b
	for c := open_c; c > 0; c -= 1 {
		open, children := int(b >> 32), u64(u32(b))
		partial := read != nil && read[c - 1] != children
		if partial {
			children = read[c - 1]
		}
		nodes[open].n = u32(count - open)
		nodes[open].spelling = nodes[open].spelling & tape.CONTAINER_STYLE | u16(min(children, u64(tape.MAX_CHILDREN))) | (tape.CONTAINER_PARTIAL if partial else 0)
		// If `children > max(u32)` on a partial streaming scan, omit the `counts` entry rather than truncating to u32:
		// a saturated `CONTAINER_PARTIAL` node with no `counts` entry represents an unknown child count.
		if children >= u64(tape.MAX_CHILDREN) && children <= u64(max(u32)) {
			counts[ci] = {tape.Node_Index(open), u32(children)}
			ci += 1
		}
		b = h.stack[c - 1]
	}
	if len(counts) > 1 {
		slice.sort_by(counts, proc(a, b: tape.Child_Count) -> bool { return a.node < b.node })
	}

	// Copy only facts belonging to kept nodes, plus leading comments/instructions/doctypes directly at `count`
	// (which `builder_place_facts` turns into root feet). Non-comment facts on a dropped key or at `count` are dropped.
	keep_fact :: #force_inline proc "contextless" (f: tape.Fact, count: int) -> bool {
		return uint(f.node) < uint(count) || uint(f.node) == uint(count) && (f.kind == .Comment || f.kind == .Instruction || f.kind == .Doctype)
	}
	kept_facts := 0
	for f in h.doc.facts {
		kept_facts += int(keep_fact(f, count))
	}
	facts, ferr := make([]tape.Fact, kept_facts, allocator)
	if e := took(ferr, raw_data(facts), kept_facts); e != nil {
		return {}, e
	}
	present: tape.Facts
	fi := 0
	for f in h.doc.facts {
		if keep_fact(f, count) {
			facts[fi] = f
			fi += 1
			if f.kind != .Comment {
				present += {f.kind}
			}
		}
	}
	doc = h.doc
	// The copy owns nothing the builder keeps. Its format extension and the scan's partial block stay the builder's,
	// since otherwise both would free them.
	doc.ext, doc.partial = nil, nil
	doc.nodes, doc.facts, doc.counts, doc.allocator, doc.root_close = nodes, facts, counts, allocator, cut
	doc.present = present
	doc.flags += {.Cut}
	if len(doc.facts) > 0 {
		builder_place_facts(&doc, count)
	}
	return doc, nil
}
