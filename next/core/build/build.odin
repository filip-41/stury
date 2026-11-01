package build

import "base:runtime"
import "core:slice"
import core ".."

// The builder every format's `build` gives its walk: the hooks that write a document, the header row a delimited
// text writes before its walk, and the duplicate-key check.

// A `Builder` holds the open-container stack and the growing node and fact buffers of one build. `Hook_Regs` holds
// the state the hook passes between tokens: `a` is the node cursor, the high 32 bits of `b` the innermost open
// container's index and its low 32 bits that container's child count, and `c` the depth.
Builder :: struct {
	doc:     core.Document,
	stack:   []u64,
	n_facts: int,
	pending: int, // the first fact of a run of head comments, or -1
	// The node of the last completed value, `core.NO_NODE` before the first, for an inline comment's node. A JSON
	// build with facts writes it, and a dsv text has no inline comment.
	last: core.Node_Index,
	// The byte just past the root value's authored bytes, which a format's `build` sets from the walk's end before
	// `builder_end` copies it to `Document.root_close`. A format whose walk may end past the root leaves it 0.
	root_close: u64,
	// The first container whose close saturated `core.CHILDREN_MAX`, with its true child count, and whether a second
	// container did. `wide_count` is 0 while none has.
	wide_node:  core.Node_Index,
	wide_count: u32,
	wide_more:  bool,
	// Whether the build refuses a repeated key, which selects the `$REFUSE` hook and its close-time check.
	refuse:     bool,
	err:        core.Document_Error,
}

// Holds the register values a builder's hook starts with: `a` is 0, the open container's index is `core.NO_NODE`, its
// child count 0, and the depth 0.
BUILDER_REGS :: core.Hook_Regs{a = 0, b = u64(core.NO_NODE) << 32, c = 0}

// Returns a builder over `src` with an open stack of `depth` slots, or 1 when `depth` is 0, room for `facts` facts, and
// at least 16 nodes, `nodes` when that is larger. The hook pushes an open container's frame with no capacity test, so
// `depth` must be at least the walk's depth limit. The nodes are allocated last, so an arena gets their unused tail back
// at `builder_end`. A format's `build` passes the builder to its walk with a builder hook and ends it with `builder_end`.
// A refused allocation returns a builder whose `err` is `.No_Memory` and whose node array is nil.
builder_start :: proc(src: []u8, spelling: ^core.Spelling, refuse_duplicates: bool, allocator: runtime.Allocator, nodes, depth: int, facts := 0) -> Builder {
	b := Builder{refuse = refuse_duplicates, pending = -1, last = core.NO_NODE}
	b.doc.src = src
	b.doc.spelling = spelling
	b.doc.allocator = allocator
	stack, serr := make([]u64, max(1, depth), allocator)
	if serr != nil {
		b.err = {kind = .No_Memory}
		return b
	}
	b.stack = stack
	if facts > 0 {
		reserved, ferr := make([]core.Fact, facts, allocator)
		if ferr != nil {
			b.err = {kind = .No_Memory}
			return b
		}
		b.doc.facts_alloc = reserved
	}
	n := max(16, nodes)
	raw, err := runtime.mem_alloc_non_zeroed(n * size_of(core.Node), align_of(core.Node), allocator)
	if err != nil {
		b.err = {kind = .No_Memory}
		return b
	}
	fresh := ([^]core.Node)(raw_data(raw))[:n]
	b.doc.nodes = fresh
	b.doc.nodes_alloc = fresh
	return b
}

// Returns the document the walk built, or the error that stopped it. A walk fault returns `.Walk` with the fault
// in `inner`, a repeated key under `refuse_duplicates` returns `.Duplicate_Key` at the later key's byte, and a refused
// allocation returns `.No_Memory`. On an error the document is the zero value and every allocation is freed.
builder_end :: proc(b: ^Builder, regs: core.Hook_Regs, fault: Maybe(core.Fault)) -> (core.Document, core.Document_Error) {
	if _, bad := fault.?; bad {
		// The walk stopped before an open object closed, so its close-time duplicate check never ran. A key read
		// before the fault is still a repeat.
		builder_refuse_open(b, regs)
	}
	if b.err.kind != .None {
		e := b.err
		builder_free(b)
		return {}, e
	}
	if f, bad := fault.?; bad {
		builder_free(b)
		return {}, {kind = .Walk, at = f.at, inner = f}
	}
	n := int(regs.a)
	b.doc.nodes = b.doc.nodes_alloc[:n]
	b.doc.facts = b.doc.facts_alloc[:b.n_facts]
	// One wide container was recorded at its close. A build with more counts them from the nodes here.
	if b.wide_more {
		if !builder_counts(b, n) {
			e := b.err
			builder_free(b)
			return {}, e
		}
	} else if b.wide_count != 0 {
		fresh, ok := grow(b.doc.allocator, b.doc.counts_alloc, 1)
		if !ok {
			builder_free(b)
			return {}, {kind = .No_Memory}
		}
		fresh[0] = {node = b.wide_node, count = b.wide_count}
		b.doc.counts_alloc = fresh
		b.doc.counts = fresh[:1]
	}
	// A comment run with no value after it is the root's foot: a delimited text's line after its last record, or
	// the only line of a text that makes no record. Every fact from `pending` on belongs to the root.
	if b.pending >= 0 {
		for i in b.pending ..< b.n_facts {
			b.doc.facts_alloc[i].node = core.ROOT
			b.doc.facts_alloc[i].role = .Comment_Foot
		}
	}
	if len(b.doc.facts) > 1 {
		slice.stable_sort_by(b.doc.facts, proc(a, b: core.Fact) -> bool { return a.node < b.node })
	}
	// The build wrote fewer nodes and facts than it reserved. Return the tail where the allocator can resize. An arena
	// resizes only its last block, which is the nodes in a text with no facts, and the document owns what it keeps.
	if fresh := trim(b.doc.allocator, b.doc.nodes_alloc, n); len(fresh) == n {
		b.doc.nodes_alloc = fresh
		b.doc.nodes = fresh
	}
	if b.n_facts > 0 {
		if fresh := trim(b.doc.allocator, b.doc.facts_alloc, b.n_facts); len(fresh) == b.n_facts {
			b.doc.facts_alloc = fresh
			b.doc.facts = fresh
		}
	}
	if len(b.doc.counts) > 0 {
		if fresh := trim(b.doc.allocator, b.doc.counts_alloc, len(b.doc.counts)); len(fresh) == len(b.doc.counts) {
			b.doc.counts_alloc = fresh
			b.doc.counts = fresh
		}
	}
	b.doc.root_close = b.root_close
	doc := b.doc
	if b.stack != nil {
		delete(b.stack, b.doc.allocator)
	}
	b^ = {}
	return doc, {}
}

// Frees the builder's buffers, last allocated first. An arena ignores a free and takes a last block's tail back at a
// resize, so each buffer shrinks first and a retry after `.No_Memory` finds that room.
@(private)
builder_free :: proc(b: ^Builder) {
	release :: proc(allocator: runtime.Allocator, old: []$T) {
		if old != nil {
			delete(trim(allocator, old, 1), allocator)
		}
	}
	release(b.doc.allocator, b.doc.counts_alloc)
	release(b.doc.allocator, b.doc.facts_alloc)
	release(b.doc.allocator, b.doc.nodes_alloc)
	release(b.doc.allocator, b.stack)
	b^ = {}
}

// A format's `build` gives these hooks to its walk, and they write its document. The full hook stores facts, which are
// comments, and the plain hook is for a spec with no comments, where no fact token arrives. A scalar is written and
// the cursor moves. An open container's frame, its index above its count, is pushed and its children are counted as
// they arrive, so its close touches no child again. A close writes the container's subtree size and child count.
builder_hook :: #force_inline proc "contextless" (h: ^Builder, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return builder_step(true, false, true, false, h, s, t)
}

// Stores tokens without a capacity test, for a build whose reservation covers every node, so the node buffer cannot
// fill.
builder_hook_plain :: #force_inline proc "contextless" (h: ^Builder, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return builder_step(false, false, false, false, h, s, t)
}

// Stores tokens with no facts, with the duplicate-key test compiled in, for a build that refuses repeats.
// `builder_hook_plain` compiles the test out.
builder_hook_plain_refuse :: #force_inline proc "contextless" (h: ^Builder, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return builder_step(false, false, true, false, h, s, t)
}

// Builds a keyless document. It drops every key, stores a `Map` as an `Array`, and steps over a header row written
// before the walk. These are document-model rules, not a grammar's, and `builder_step`'s `$KEYLESS` holds them. The
// key drop covers facts too (`role` past `.Key`): a fact is not a value. A row written before the walk is the root's
// next node, role `Key` where a record is a value, and the root's token moves the cursor past it. A build that refuses
// repeats reads that row after the walk instead of at a close, so no close tests it.
builder_hook_keyless :: #force_inline proc "contextless" (h: ^Builder, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return builder_step(false, true, false, true, h, s, t)
}

// Stores the facts of a delimited text with a comment byte and drops its keys. A fact token is passed to
// `builder_fact` with the pending cursor, and a record's open resolves the comments above it. A text with no comment
// byte uses `builder_hook_keyless`, whose `$FACTS` false compiles the fact branch out.
builder_hook_keyless_facts :: #force_inline proc "contextless" (h: ^Builder, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return builder_step(true, true, false, true, h, s, t)
}

// What a text needs, read by a walk with `builder_hook_count` or `builder_hook_count_keyless`: its nodes, its facts and
// its deepest nesting. `depth` is the nesting at the walk's cursor.
Count :: struct {
	nodes:   int,
	facts:   int,
	depth:   int,
	deepest: int,
}

// Counts a text's tokens and stores nothing, for a build whose reservation was refused.
builder_hook_count :: #force_inline proc "contextless" (h: ^Count, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	count_step(false, h, t)
	return s, .Next
}

// Counts the tokens of a text `builder_hook_keyless` or `builder_hook_keyless_facts` would store: no key makes a node.
builder_hook_count_keyless :: #force_inline proc "contextless" (h: ^Count, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	count_step(true, h, t)
	return s, .Next
}

@(private)
count_step :: #force_inline proc "contextless" ($KEYLESS: bool, h: ^Count, t: core.Token) {
	if t.role > .Key {
		h.facts += 1
		return
	}
	when KEYLESS {
		if t.role == .Key {
			return
		}
	}
	if t.kind == .End {
		h.depth -= 1
		return
	}
	h.nodes += 1
	if t.kind > .Plain {
		h.depth += 1
		h.deepest = max(h.deepest, h.depth)
	}
}

// Every hook runs this body. `$FACTS` false compiles out the fact branch, the pending comments and the write of the
// last completed value, which a spec with no comments does not use. `$CHECK` false compiles out the capacity test,
// needed only when the reservation is an estimate. `$REFUSE` false compiles out the duplicate-key test,
// which a build that did not ask for it does not run. `$KEYLESS` compiles in the keyless document rules above.
@(private)
builder_step :: #force_inline proc "contextless" ($FACTS, $CHECK, $REFUSE, $KEYLESS: bool, h: ^Builder, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	s := s
	when FACTS {
		if t.role > .Key {
			builder_fact(h, s, t)
			if h.err.kind != .None && h.err.kind != .Duplicate_Key {
				return s, .Stop
			}
			return s, .Next
		}
	}
	when KEYLESS {
		if t.role >= .Key {
			return s, .Next
		}
	}
	a := int(s.a)
	when CHECK {
		if a == len(h.doc.nodes) {
			builder_grow(h)
			// A failed growth leaves the buffer at its old length. Stop on that, whatever error is held: a duplicate
			// found earlier is the error the build keeps, and the hook must not write past the buffer.
			if a == len(h.doc.nodes) {
				return s, .Stop
			}
		}
	}
	flat := t
	when KEYLESS {
		if flat.kind == .Map {
			flat.kind = .Array
		}
	}
	if t.kind <= .Plain {
		#no_bounds_check h.doc.nodes[a] = t
		s.a = u64(a + 1)
		when KEYLESS {
			s.b += 1
			when FACTS {
				builder_resolve_pending(h, core.Node_Index(a), builder_header_lo(h))
			}
		} else {
			if t.role == .Value {
				when FACTS {
					h.last = core.Node_Index(a)
					builder_resolve_pending(h, core.Node_Index(a))
				}
				// The open container's child count is `s.b`'s low half, so a value is counted with one add and
				// no node is touched.
				s.b += 1
			}
		}
		return s, .Next
	}
	if t.kind != .End {
		#no_bounds_check h.doc.nodes[a] = flat
		// The parent's frame, its open index above its count, is pushed, and the new container's count starts at
		// zero.
		when KEYLESS {
			s.b += 1
		} else {
			if t.role == .Value {
				s.b += 1
			}
		}
		#no_bounds_check h.stack[s.c] = s.b
		s.c += 1
		s.a = u64(a + 1)
		s.b = u64(a) << 32
		when FACTS {
			when KEYLESS {
				// A record's head comments are its own, except one above the header row's first byte, which belongs
				// to the root since no record precedes it to take it.
				builder_resolve_pending(h, core.Node_Index(a), builder_header_lo(h))
			} else {
				if t.role == .Value {
					builder_resolve_pending(h, core.Node_Index(a))
				}
			}
		}
		when KEYLESS {
			if a == 0 {
				if j := int(s.a); j < len(h.doc.nodes) && h.doc.nodes[j].role == .Key {
					s.a = u64(j + int(h.doc.nodes[j].n))
				}
			}
		}
		return s, .Next
	}
	// The walk emits a close only for a container it opened, so a close's open frame is the top of the register-held
	// stack.
	open := core.Node_Index(s.b >> 32)
	builder_close_node(h, a, open, u32(s.b))
	when FACTS && !KEYLESS {
		if h.doc.nodes[int(open)].role == .Value {
			h.last = open
		}
	}
	// No close node is stored, so the cursor is already where the next token is written.
	s.c -= 1
	#no_bounds_check s.b = h.stack[s.c]
	when REFUSE {
		if h.refuse && h.doc.nodes[int(open)].kind == .Map {
			builder_refuse_result(h, open, core.Node_Index(a))
		}
	}
	return s, .Next
}

// Records the error a closed object's duplicate check returns in the build's error. An inner object closes before
// an outer one, so the walk continues and the earliest repeat in document order is kept. A repeat names its byte
// and a refused allocation names none, so a `No_Memory` replaces no earlier error. A format's `build` calls this for
// a container it checks itself, such as a dsv header row checked after the walk.
builder_refuse_result :: #force_inline proc "contextless" (h: ^Builder, open, end: core.Node_Index) {
	if e := duplicate_key(&h.doc, open, end, h.doc.allocator); e.kind != .None {
		if e.kind == .Duplicate_Key {
			if h.err.kind != .Duplicate_Key || e.at < h.err.at {
				h.err = e
			}
		} else if h.err.kind == .None {
			h.err = e
		}
	}
}

// Checks every object the walk left open and whose close-time check never ran, innermost first. The open containers
// are the packed frames `h.stack[0 ..< regs.c]` under the current frame `regs.b`. An open object's keys are the nodes
// before the next open container, or before the node cursor `regs.a` for the innermost, so no node field is marked. A
// repeat found here is before the fault's byte, and `builder_refuse_result` keeps the earliest.
@(private)
builder_refuse_open :: proc "contextless" (h: ^Builder, regs: core.Hook_Regs) {
	if !h.refuse {
		return
	}
	depth := int(regs.c)
	if depth == 0 || core.Node_Index(regs.b >> 32) == core.NO_NODE {
		return
	}
	open := core.Node_Index(regs.b >> 32)
	stop := core.Node_Index(regs.a)
	for open != core.NO_NODE {
		if h.doc.nodes[open].kind == .Map {
			builder_refuse_result(h, open, stop)
		}
		stop = open
		// `h.stack[k]` is the frame of the container below depth `k + 1`, so a frame's high half is its parent's
		// index.
		open = core.Node_Index(h.stack[depth - 1] >> 32) if depth > 1 else core.NO_NODE
		depth -= 1
	}
}

// Writes the subtree size of the container at `open` into its `n` and its child count into `spelling` at its close.
// No close node is stored. A count at or past `CHILDREN_MAX` saturates `spelling` and keeps the true count in
// `Builder.wide_node` and `Builder.wide_count`, or marks a second such container in `Builder.wide_more`.
builder_close_node :: #force_inline proc "contextless" (h: ^Builder, a: int, open: core.Node_Index, count: u32) {
	#no_bounds_check {
		n := &h.doc.nodes[int(open)]
		n.n = u32(a - int(open))
		if count < u32(core.CHILDREN_MAX) {
			n.spelling = u16(count)
		} else {
			n.spelling = core.CHILDREN_MAX
			if h.wide_count == 0 {
				h.wide_node = open
				h.wide_count = count
			} else {
				h.wide_more = true
			}
		}
	}
}

// Records the true child count of every container whose `spelling` saturated `CHILDREN_MAX`, by walking its members
// in node order. Returns false when an allocation is refused.
@(private, cold)
builder_counts :: #force_no_inline proc(h: ^Builder, n: int) -> bool {
	fresh := h.doc.counts_alloc
	k := 0
	for i in 0 ..< n {
		node := h.doc.nodes[i]
		if node.spelling != core.CHILDREN_MAX || (node.kind != .Array && node.kind != .Map) {
			continue
		}
		count := 0
		it := core.children(&h.doc, core.Node_Index(i))
		for {
			if _, more := core.child_next(&it); !more {
				break
			}
			count += 1
		}
		if k == len(fresh) {
			grown, ok := grow(h.doc.allocator, fresh, 8)
			if !ok {
				if h.err.kind == .None {
					h.err = {kind = .No_Memory}
				}
				return false
			}
			fresh = grown
			h.doc.counts_alloc = grown
		}
		fresh[k] = {node = core.Node_Index(i), count = u32(count)}
		k += 1
	}
	h.doc.counts = fresh[:k]
	return true
}

// Returns a slice of `$T` in `allocator`, twice `old`'s length, at least 8 and at least `min` long, holding `old`'s
// values, which `old` no longer does. The new memory is not zeroed: the caller writes every slot before a reader reads
// it. A resize lets an arena extend its last block and leave none behind. A caller reaches this only when its buffer
// is full.
@(private, cold)
grow :: #force_no_inline proc "contextless" (allocator: runtime.Allocator, old: []$T, min: int) -> ([]T, bool) {
	context = runtime.default_context()
	n := max(min, max(8, len(old) * 2))
	raw, err := runtime.non_zero_mem_resize(raw_data(old), len(old) * size_of(T), n * size_of(T), align_of(T), allocator)
	if err != nil {
		return nil, false
	}
	return ([^]T)(raw_data(raw))[:n], true
}

// Returns `old` shortened to `n` where the allocator can resize it, and `old` unchanged where it cannot. The caller
// sets both the array and the allocation behind it to the result. An arena returns the tail of its last block and keeps
// any other block's, so this is not a promise about every allocator.
@(private, cold)
trim :: #force_no_inline proc (allocator: runtime.Allocator, old: []$T, n: int) -> []T {
	if n <= 0 || n >= len(old) {
		return old
	}
	raw, err := runtime.non_zero_mem_resize(raw_data(old), len(old) * size_of(T), n * size_of(T), align_of(T), allocator)
	if err != nil {
		return old
	}
	return ([^]T)(raw_data(raw))[:n]
}

// Doubles the node buffer. A text that fits its reservation does not call this. A refused allocation sets `err`
// to `.No_Memory`.
@(private, cold)
builder_grow :: #force_no_inline proc "contextless" (h: ^Builder) {
	fresh, ok := grow(h.doc.allocator, h.doc.nodes_alloc, 16)
	if !ok {
		// A repeat found before the growth remains the error, a failure with no earlier error is `No_Memory`.
		if h.err.kind == .None {
			h.err = {kind = .No_Memory}
		}
		return
	}
	h.doc.nodes = fresh
	h.doc.nodes_alloc = fresh
}

// Doubles the fact buffer. A text with no facts does not call this. Returns false when a growth is refused.
@(private, cold)
builder_facts_grow :: #force_no_inline proc "contextless" (h: ^Builder) -> bool {
	fresh, ok := grow(h.doc.allocator, h.doc.facts_alloc, 8)
	if !ok {
		return false
	}
	h.doc.facts_alloc = fresh
	return true
}

// Handles a fact token out of line. A head comment is held until the value it marks arrives, an inline comment
// belongs to the last value completed, and a foot belongs to the innermost open container, or to the root at depth 0.
@(private, cold)
builder_fact :: #force_no_inline proc "contextless" (h: ^Builder, s: core.Hook_Regs, t: core.Token) {
	node := core.Node_Index(0)
	pending := false
	#partial switch t.role {
	case .Comment:
		pending = true
	case .Comment_Inline:
		if h.last == core.NO_NODE {
			pending = true
		} else {
			node = h.last
		}
	case .Comment_Foot:
		open := core.Node_Index(s.b >> 32)
		if open != core.NO_NODE {
			node = open
		}
	case:
		pending = true
	}
	if h.n_facts == len(h.doc.facts_alloc) {
		if !builder_facts_grow(h) {
			if h.err.kind == .None {
				h.err = {kind = .No_Memory}
			}
			return
		}
	}
	h.doc.facts_alloc[h.n_facts] = core.Fact{lo = t.lo, node = node, n = t.n, role = t.role, spelling = t.spelling}
	h.n_facts += 1
	if pending && h.pending < 0 {
		h.pending = h.n_facts - 1
	}
}

// Gives the head comments held since the last value to the value node `node`. A pending fact before the header row's
// first byte belongs to the root, since no record precedes it to take it.
@(private)
builder_resolve_pending :: #force_inline proc "contextless" (h: ^Builder, node: core.Node_Index, root_before := u64(0)) {
	if h.pending < 0 {
		return
	}
	for i in h.pending ..< h.n_facts {
		f := &h.doc.facts_alloc[i]
		f.node = core.ROOT if root_before != 0 && f.lo < root_before else node
	}
	h.pending = -1
}

// Returns the first byte of the header row a keyless document wrote before its walk, or 0 when it has none.
@(private)
builder_header_lo :: #force_inline proc "contextless" (h: ^Builder) -> u64 {
	if len(h.doc.nodes) > 1 && h.doc.nodes[1].role == .Key {
		return h.doc.nodes[1].lo
	}
	return 0
}

// Checks that the object from `open` through its last node at `end` has no two keys whose decoded text is equal.
// A repeated key returns `.Duplicate_Key` at the later key's first byte. The table is a 64-entry
// array on the stack and spills to `allocator` past 32 keys. A refused allocation returns `.No_Memory`.
@(private)
duplicate_key :: #force_no_inline proc "contextless" (doc: ^core.Document, open, end: core.Node_Index, allocator: runtime.Allocator) -> core.Document_Error {
	context = runtime.default_context()
	keys := 0
	for i := int(open) + 1; i < int(end); {
		n := doc.nodes[i]
		if n.role == .Key {
			keys += 1
		}
		i += int(n.n) if n.kind == .Array || n.kind == .Map else 1
	}
	size := 8
	for size < 2 * keys {
		size <<= 1
	}
	small: [64]Key_Entry
	table := small[:]
	heap: []Key_Entry
	if size > len(small) {
		fresh, err := make([]Key_Entry, size, allocator)
		if err != nil {
			return {kind = .No_Memory}
		}
		heap = fresh
		table = fresh
	}
	defer if heap != nil {
		delete(heap, allocator)
	}
	mask := u64(size - 1)
	for i := int(open) + 1; i < int(end); {
		n := doc.nodes[i]
		if n.role != .Key {
			i += int(n.n) if n.kind == .Array || n.kind == .Map else 1
			continue
		}
		key := core.Node_Index(i)
		buf: [256]u8
		s, ok := core.text(doc, key, buf[:])
		cloned := false
		if !ok {
			s, ok = core.text_clone(doc, key, allocator)
			if !ok {
				return {kind = .No_Memory}
			}
			cloned = true
		}
		hash := hash_bytes(transmute([]u8)s)
		at := hash & mask
		for {
			e := &table[at]
			if !e.used {
				e^ = {hash = hash, node = key, used = true}
				break
			}
			if e.hash == hash {
				same: bool
				same, ok = text_equals(doc, e.node, s, allocator)
				if !ok {
					if cloned {
						delete(s, allocator)
					}
					return {kind = .No_Memory}
				}
				if same {
					if cloned {
						delete(s, allocator)
					}
					return {kind = .Duplicate_Key, at = core.key_start(n)}
				}
			}
			at = (at + 1) & mask
		}
		if cloned {
			delete(s, allocator)
		}
		i += int(n.n) if n.kind == .Array || n.kind == .Map else 1
	}
	return {}
}

// Returns whether key node `i`'s text equals `s`, both read through `text`: a CSV quoted cell's quotes are
// markers, and a TSV cell's quote is a byte of its text.
@(private)
text_equals :: proc(doc: ^core.Document, i: core.Node_Index, s: string, allocator: runtime.Allocator) -> (bool, bool) {
	buf: [256]u8
	t, ok := core.text(doc, i, buf[:])
	if !ok {
		t, ok = core.text_clone(doc, i, allocator)
		if !ok {
			return false, false
		}
		same := t == s
		delete(t, allocator)
		return same, true
	}
	return t == s, true
}

@(private)
Key_Entry :: struct {
	hash: u64,
	node: core.Node_Index,
	used: bool,
}

@(private)
hash_bytes :: proc(s: []u8) -> u64 {
	h := u64(0xcbf2_9ce4_8422_2325)
	for b in s {
		h = (h ~ u64(b)) * 0x100_0000_01b3
	}
	return h
}
