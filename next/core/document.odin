package core

import "base:intrinsics"
import "base:runtime"
import "core:slice"

// A document holds a walk's tokens in walk order, 16 bytes per node, plus the facts beside them. The builder is a
// hook here, instantiated per format and spec by the format's `build`, so every format shares the document and
// reader code.

// A document node is the token the walk gave, with a container's `n` and `spelling` patched at its close:
//
//	- a scalar is its token, `n` its byte length,
//	- a container's `n` is its subtree's node count, its own node included, and the document holds no close node,
//	  so its next sibling is `i + n`,
//	- a container's `spelling` is its child count, where a member counts once, not its key and value.
//	  The count saturates at `CHILDREN_MAX`, and `length` counts the members by stepping.
//	- a document holds no `End` node: the walk still emits one, and the builder consumes it.
Node :: Token

// The largest child count a container's `spelling` holds. A container with more children stores this value.
CHILDREN_MAX :: u16(0xFFFF)

// "No such node": answer on a miss. A node index never takes it.
NO_NODE :: u32(max(u32))
// The root value's node is node 0.
ROOT :: u32(0)

// Bit 0 of a string, key or dsv cell's `spelling` is set when its text must be decoded. A reader tests it before
// calling the format's `text`. An unmarked node's span is its text: a JSON string's token leaves its quote pair out,
// an unquoted JSON5 key is bare, and a dsv cell's span is its source bytes.
SPELLING_DECODE :: u16(1)
// Bit 1 of a JSON string or a dsv cell is set when the token is quoted. A JSON string's token span is the bytes
// between its quotes, so `span` adds the pair back. A quoted dsv cell's span already holds them.
SPELLING_QUOTED :: u16(2)
// Bit 2 of a JSON string is set when it holds an ill-formed UTF-8 sequence that `Invalid_Utf8` reads as U+FFFD, so its
// decode may grow past its span.
SPELLING_LAX :: u16(4)

// A `Fact` holds a comment token, the node it belongs to and its role. Facts are sorted by the node they belong to,
// and two facts of one node keep their source order. `lo` is the first byte and `n` the span's length, markers
// included. `spelling`'s low byte is the marker's lead length and the next byte its tail length, so core slices a body
// without knowing a format's markers. A `//` comment leads with two bytes and trails none, a `/* */` comment leads and
// trails with two, and a delimited text's comment line leads with one.
Fact :: struct {
	lo:       u64,
	node:     u32,
	n:        u32,
	role:     Role,
	spelling: u16,
}

// A `Document` holds the walk's tokens over the caller's bytes, the facts beside them, and the format's `Spelling`
// table. `src` is borrowed and must outlive the document. `nodes_alloc` is the allocation behind `nodes`, whose length
// is its capacity, so `destroy` frees it after `nodes` shrank to the node count.
//
// A headed dsv text keeps its header row as the root's first child, an `Array` of role `Key` whose `Plain` cells
// name its columns, so the root's readers step over it as they step over a member's key. `header` is that
// `Array`'s node, and its cells, at `header + 1` on, are the keys of every record: column `i`'s key is the
// header's cell `i`. It is 0 for a document with no header, for every JSON text, and for a dsv text read
// without one.
Document :: struct {
	src:         []u8,
	nodes:       []Node,
	nodes_alloc: []Node,
	facts:       []Fact,
	facts_alloc: []Fact,
	spelling:    ^Spelling,
	allocator:   runtime.Allocator,
	header:      u32,
	// The spec the text was read as, which the edit dispatcher reads. A format may point every spec at one spelling
	// table and dispatch its edit services on this byte.
	spec:        u8,
	// dsv's run-time dialect, which every edit service reads: the byte between two cells and the byte that starts
	// a comment line, 0 for none. `spelling` names the spec, so the spec and these bytes record how the text was
	// read. They fill the padding after `header`: the document stays 112 bytes, and no node or read lane moves.
	delimiter:   u8,
	comment:     u8,
	// dsv's build choice: the first record is data. It is stored beside the dialect so a commit validates an output
	// as the text was read.
	no_header:   bool,
}

// How a reader treats an object's repeated keys. `Refuse` is a build option: the build checks each object as it
// closes and fails at the repeated key's byte. The other values are reader arguments. `.Last` is the default.
Duplicates :: enum u8 {
	First,
	Last,
	All,
	Refuse,
}

// Holds the options `resolve` reads besides the node.
Resolve_Options :: struct {
	// dsv: an unquoted cell that is empty, `true`, `false` or exactly a JSON number reads as Null, True, False or
	// Number. False, the default, makes every value cell a String.
	infer: bool,
}

// A `Spelling` holds a format's read services, in its rodata. `text` decodes a node's text into `buf` when it has
// room, else into `allocator`, which the caller frees. A node whose `SPELLING_DECODE` bit is clear is its span without
// the quotes that surround it. `key_equals` compares a key without allocating. `number` reads a number token.
// `resolve` returns what a `Plain` node is. `close_end` returns the byte just past a container's closing bytes,
// found from its last descendant or its open, over the whitespace and comments the format allows there. `edit`
// points at the format's edit services, nil for a format that accepts no edits.
Spelling :: struct {
	text:       proc(doc: ^Document, i: u32, buf: []u8, allocator: runtime.Allocator) -> (string, bool),
	key_equals: proc(doc: ^Document, i: u32, name: string) -> bool,
	number:     proc(doc: ^Document, i: u32) -> Number,
	resolve:    proc(doc: ^Document, i: u32, opts: Resolve_Options) -> Kind,
	close_end:  proc(doc: ^Document, i: u32) -> u64,
	edit:       ^Edit_Spelling,
}

// An `Edit_Spelling` holds a format's edit services. A document's `Spelling` points at one table, and the services
// dispatch on the document's `spec` and run-time dialect. `value` checks a text as exactly one value of the format and
// spec, `key` as exactly one key, and `record` as exactly one record, returning its cell count. `reads` is the
// format's own read of a text with or without its tolerance set, for the check a commit makes, under the output spec
// `spec`. Each service receives the document, so it reads the run-time dialect the document holds. A text that is no
// value or record answers `.Bad_Value`, one that is no key answers `.Bad_Key`, with the walk's fault in `inner` where
// there is one, and `.No_Memory` when the service could not allocate.
//
// `member_sep` is written between two members of an object or two elements of an array, `key_sep` between a
// member's key and its value, and `record_sep` is the line end a record insert writes, read from the document so
// a text keeps the line end it uses. A table's cell separator is the document's `delimiter`. `comment` says how
// the output spells a comment under `spec` and is nil for a format that accepts no comment.
Edit_Spelling :: struct {
	value:      proc(doc: ^Document, src: []u8, allocator: runtime.Allocator) -> Document_Error,
	key:        proc(doc: ^Document, src: []u8, allocator: runtime.Allocator) -> Document_Error,
	record:     proc(doc: ^Document, src: []u8, allocator: runtime.Allocator) -> (cells: int, err: Document_Error),
	reads:      proc(doc: ^Document, src: []u8, tolerate: bool, spec: u8) -> (fault: Fault, faulted: bool),
	comment:    proc(doc: ^Document, spec: u8) -> (style: Comment_Spelling, b: u8),
	member_sep: string,
	key_sep:    string,
	record_sep: proc(doc: ^Document) -> string,
}

// A `Comment_Spelling` names how a format spells a comment in an output: `//` for a JSON spec that has comments, the
// document's comment byte for a delimited text, or none. Under `Line`, a body holding a line end is written in the
// block form `/* */`, so a line comment's body cannot end its line early.
Comment_Spelling :: enum u8 {
	None,
	Line,
	Byte,
}

// A `Builder` holds the open-container stack and the growing node and fact buffers of one build. `Hook_Regs` holds
// the state the hook passes between tokens: `a` is the node cursor, `b` the open container's index, `c` the last
// completed value. The plain hook keeps different state there: `b` holds the innermost open container's index in its
// high 32 bits and its child count in the low 32, and `c` is the depth.
Builder :: struct {
	doc:     Document,
	stack:   []u64,
	depth:   int,
	n_facts: int,
	pending: int, // the first fact of a run of head comments, or -1
	dups:    Duplicates,
	err:     Document_Error,
}

// Holds the register values a builder's hook starts with: `a` is 0, and `b` and `c` are `NO_NODE`.
BUILDER_REGS :: Hook_Regs{a = 0, b = u64(NO_NODE), c = u64(NO_NODE)}

// Returns a builder over `src`, with at least 16 nodes reserved, `len(src) / seed_div` when that is larger, and an
// open stack of `depth` slots, or 1 when `depth` is 0. A JSON build passes `seed_div` 1, since a text makes no more
// tokens than bytes, and the walk's maximum depth, so its hook tests no capacity and grows neither buffer. A format's
// `build` passes the builder to its walk with a builder hook and ends it with `builder_end`. A refused allocation
// returns a builder whose `err` is `.No_Memory`.
builder_start :: proc(src: []u8, spelling: ^Spelling, dups: Duplicates, allocator: runtime.Allocator, seed_div := 8, depth := 16) -> Builder {
	b := Builder{dups = dups, pending = -1}
	b.doc.src = src
	b.doc.spelling = spelling
	b.doc.allocator = allocator
	n := max(16, len(src) / seed_div)
	raw, err := runtime.mem_alloc_non_zeroed(n * size_of(Node), align_of(Node), allocator)
	if err != nil {
		b.err = {kind = .No_Memory}
		return b
	}
	nodes := ([^]Node)(raw_data(raw))[:n]
	b.doc.nodes = nodes
	b.doc.nodes_alloc = nodes
	stack, serr := make([]u64, max(1, depth), allocator)
	if serr != nil {
		delete(nodes, allocator)
		b.doc.nodes = nil
		b.doc.nodes_alloc = nil
		b.err = {kind = .No_Memory}
		return b
	}
	b.stack = stack
	return b
}

// Returns the document the walk built, or the error that stopped it. A walk fault returns `.Walk` with the fault
// in `inner`, a repeated key under `.Refuse` returns `.Duplicate_Key` at the later key's byte, and a refused
// allocation returns `.No_Memory`. On an error the document is the zero value and every allocation is freed.
// `facts` says the walk kept open containers in `Builder.depth` and the stack's slots, not as packed frames.
builder_end :: proc(b: ^Builder, regs: Hook_Regs, fault: Maybe(Fault), facts := false) -> (Document, Document_Error) {
	if _, bad := fault.?; bad {
		// The walk stopped before an open object closed, so its close-time duplicate check never ran. A key read
		// before the fault is still a repeat.
		builder_refuse_open(b, regs, facts)
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
	// A comment run with no value after it is the root's foot: a delimited text's line after its last record, or
	// the only line of a text that makes no record. Every fact from `pending` on belongs to the root.
	if b.pending >= 0 {
		for i in b.pending ..< b.n_facts {
			b.doc.facts_alloc[i].node = ROOT
			b.doc.facts_alloc[i].role = .Comment_Foot
		}
	}
	if len(b.doc.facts) > 1 {
		slice.stable_sort_by(b.doc.facts, proc(a, b: Fact) -> bool { return a.node < b.node })
	}
	doc := b.doc
	if b.stack != nil {
		delete(b.stack, b.doc.allocator)
	}
	b^ = {}
	return doc, {}
}

// Frees `doc`'s node and fact allocations and sets `doc` to the zero value.
destroy :: proc(doc: ^Document) {
	if doc.nodes_alloc != nil {
		delete(doc.nodes_alloc, doc.allocator)
	}
	if doc.facts_alloc != nil {
		delete(doc.facts_alloc, doc.allocator)
	}
	doc^ = {}
}

@(private)
builder_free :: proc(b: ^Builder) {
	if b.doc.nodes_alloc != nil {
		delete(b.doc.nodes_alloc, b.doc.allocator)
	}
	if b.doc.facts_alloc != nil {
		delete(b.doc.facts_alloc, b.doc.allocator)
	}
	if b.stack != nil {
		delete(b.stack, b.doc.allocator)
	}
	b^ = {}
}

// A format's `build` gives these hooks to its walk, and they write its document. The full hook stores facts, which are
// comments, and the plain hook is for a spec with no comments, where no fact token arrives. A scalar is written and
// the cursor moves. An open container is pushed and its children are counted as they arrive, so its close touches no
// child again. A close writes the container's subtree size and child count.
builder_hook :: #force_inline proc "contextless" (h: ^Builder, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	return builder_step(true, false, true, h, s, t)
}

// Stores tokens without a capacity test, for a build whose reservation is the token bound, so the node buffer cannot
// fill.
builder_hook_plain :: #force_inline proc "contextless" (h: ^Builder, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	return builder_step(false, false, false, h, s, t)
}

// Stores tokens and facts and doubles the node buffer when it is full, for a build whose reservation is an estimate.
// A build whose token-bound reservation the allocator refused retries with this hook.
builder_hook_checked :: #force_inline proc "contextless" (h: ^Builder, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	return builder_step(true, true, true, h, s, t)
}

// Stores tokens with no facts, with the duplicate-key test compiled in, for a build under `.Refuse`.
// `builder_hook_plain` compiles the test out.
builder_hook_plain_refuse :: #force_inline proc "contextless" (h: ^Builder, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	return builder_step(false, false, true, h, s, t)
}

// Stores tokens with no facts and doubles the node buffer when it is full, for a build whose reservation is an
// estimate.
builder_hook_plain_checked :: #force_inline proc "contextless" (h: ^Builder, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	return builder_step(false, true, true, h, s, t)
}

// Builds a keyless document. It drops every key, stores a `Map` as an `Array`, and steps over a header row written
// before the walk. These are document-model rules, not a grammar's. The key drop covers facts too (`role` past
// `.Key`): a fact is not a value. A row written before the walk is the root's next node, role `Key` where a record
// is a value, and the root's token moves the cursor past it. `.Refuse` reads that row after the build instead of at
// a close, so no close tests it.
//
// This repeats `builder_step`'s body to keep its three rules out of the dsv per-token path.
builder_hook_keyless :: #force_inline proc "contextless" (h: ^Builder, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	return builder_keyless_step(false, h, s, t)
}

// Stores the facts of a delimited text with a comment byte and drops its keys. A fact token is passed to
// `builder_fact` with the pending cursor, and a record's open resolves the comments above it. A text with no comment
// byte uses `builder_hook_keyless`, whose `$FACTS` false compiles the fact branch out.
builder_hook_keyless_facts :: #force_inline proc "contextless" (h: ^Builder, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	return builder_keyless_step(true, h, s, t)
}

@(private)
builder_keyless_step :: #force_inline proc "contextless" ($FACTS: bool, h: ^Builder, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	s := s
	when FACTS {
		if t.role > .Key {
			// A fact is passed to `builder_fact` with the pending cursor, as in the full hook. A delimited text's
			// comment line has role `.Comment` and does not read `s.c`, which is the depth here.
			builder_fact(h, s, t)
			if h.err.kind != .None {
				return s, .Stop
			}
			return s, .Next
		}
	}
	if t.role >= .Key {
		return s, .Next
	}
	a := int(s.a)
	if a == len(h.doc.nodes) {
		builder_grow(h)
		if h.err.kind != .None {
			return s, .Stop
		}
	}
	if t.kind == .Plain {
		#no_bounds_check h.doc.nodes[a] = t
		s.a = u64(a + 1)
		s.b += 1
		when FACTS {
			builder_resolve_pending(h, u32(a), builder_header_lo(h))
		}
		return s, .Next
	}
	flat := t
	if flat.kind == .Map {
		flat.kind = .Array
	}
	if flat.kind != .End {
		#no_bounds_check h.doc.nodes[a] = flat
		s.b += 1
		#no_bounds_check h.stack[s.c] = s.b
		s.c += 1
		s.a = u64(a + 1)
		s.b = u64(a) << 32
		when FACTS {
			// A record's comments above it are its own: the line above a header is the first record's, since the
			// header itself makes no token.
			builder_resolve_pending(h, u32(a), builder_header_lo(h))
		}
		if a == 0 {
			if j := int(s.a); j < len(h.doc.nodes) && h.doc.nodes[j].role == .Key {
				s.a = u64(j + int(h.doc.nodes[j].n))
			}
		}
		return s, .Next
	}
	open := u32(s.b >> 32)
	builder_close_node(h, a, open, u32(s.b))
	s.c -= 1
	#no_bounds_check s.b = h.stack[s.c]
	return s, .Next
}

// Every hook runs this body. With `$FACTS` false the fact branch and every use of `s.c` as the pending-comment cursor
// are compiled out, which a spec with no comments does not use. `$CHECK` false compiles out the capacity test, needed
// only when the reservation is short of the token bound. `$REFUSE` false compiles out the duplicate-key test, which a
// build that did not ask for it does not run.
@(private)
builder_step :: #force_inline proc "contextless" ($FACTS, $CHECK, $REFUSE: bool, h: ^Builder, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
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
	a := int(s.a)
	when CHECK {
		if a == len(h.doc.nodes) {
			builder_grow(h)
			if h.err.kind != .None {
				return s, .Stop
			}
		}
	}
	#no_bounds_check h.doc.nodes[a] = t
	if t.kind <= .Plain {
		s.a = u64(a + 1)
		if t.role == .Value {
			when FACTS {
				s.c = u64(a)
				builder_resolve_pending(h, u32(a))
				if u32(s.b) != NO_NODE {
					#no_bounds_check h.doc.nodes[int(s.b)].n += 1
				}
			} else {
				// The open container's child count is `s.b`'s low half, so a value is counted with one add and
				// no node is touched.
				s.b += 1
			}
		}
		return s, .Next
	}
	if t.kind != .End {
		when FACTS {
			// `n` counts the container's children while it is open, and the close reads that count for `spelling`.
			h.doc.nodes[a].n = 0
			if !builder_push(h, u32(a)) {
				h.err = {kind = .No_Memory}
				return s, .Stop
			}
			s.a = u64(a + 1)
			s.b = u64(a)
			if t.role == .Value {
				builder_resolve_pending(h, u32(a))
			}
		} else {
			// The parent's frame, its open index above its count, is pushed, and the new container's count starts
			// at zero.
			if t.role == .Value {
				s.b += 1
			}
			#no_bounds_check h.stack[s.c] = s.b
			s.c += 1
			s.a = u64(a + 1)
			s.b = u64(a) << 32
		}
		return s, .Next
	}
	open: u32
	when FACTS {
		open = u32(s.b)
		if open == NO_NODE || int(open) >= a {
			h.err = {kind = .Walk, at = t.lo, inner = {at = t.lo, kind = .Bad_Structure}}
			return s, .Stop
		}
		count: u32
		is_value: bool
		open_kind: Kind
		#no_bounds_check {
			count = h.doc.nodes[int(open)].n
			is_value = h.doc.nodes[int(open)].role == .Value
			open_kind = h.doc.nodes[int(open)].kind
		}
		builder_close_node(h, a, open, count)
		if h.depth > 0 {
			h.depth -= 1
		}
		s.b = u64(builder_top(h))
		if is_value {
			s.c = u64(open)
			if u32(s.b) != NO_NODE {
				#no_bounds_check h.doc.nodes[int(s.b)].n += 1
			}
		}
		when REFUSE {
			if h.dups == .Refuse && open_kind == .Map {
				builder_refuse_result(h, open, u32(a))
			}
		}
	} else {
		// A JSON text holds no more tokens than bytes and dsv's stack is sized for its records, so a close's open
		// frame is the top of the register-held stack and needs no structure test.
		open = u32(s.b >> 32)
		builder_close_node(h, a, open, u32(s.b))
		// No close node is stored, so the cursor is already where the next token is written.
		s.c -= 1
		#no_bounds_check s.b = h.stack[s.c]
		when REFUSE {
			if h.dups == .Refuse && h.doc.nodes[int(open)].kind == .Map {
				builder_refuse_result(h, open, u32(a))
			}
		}
	}
	return s, .Next
}

// Records the error a closed object's duplicate check returns in the build's error. An inner object closes before
// an outer one, so the walk continues and the earliest repeat in document order is kept. A repeat names its byte
// and a refused allocation names none, so a `No_Memory` replaces no earlier error.
@(private)
builder_refuse_result :: #force_inline proc "contextless" (h: ^Builder, open, end: u32) {
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

// Checks every object the walk left open and whose close-time check never ran, innermost first. With `facts` the
// builder kept the open containers in `h.stack` from `h.depth`, else as the packed frames `h.stack[0 ..< regs.c]`
// under the current frame `regs.b`. An open object's keys are the nodes before the next open container, or before the
// node cursor `regs.a` for the innermost, so no node field is marked. A repeat found here is before the fault's byte,
// and `builder_refuse_result` keeps the earliest.
@(private)
builder_refuse_open :: proc "contextless" (h: ^Builder, regs: Hook_Regs, facts: bool) {
	if h.dups != .Refuse {
		return
	}
	depth := h.depth if facts else int(regs.c)
	if depth == 0 || !facts && u32(regs.b >> 32) == NO_NODE {
		return
	}
	open := u32(h.stack[depth - 1]) if facts else u32(regs.b >> 32)
	stop := u32(regs.a)
	for open != NO_NODE {
		if h.doc.nodes[open].kind == .Map {
			builder_refuse_result(h, open, stop)
		}
		stop = open
		if facts {
			// `h.stack[k]` is the container open at depth `k + 1`.
			depth -= 1
			open = u32(h.stack[depth - 1]) if depth > 0 else NO_NODE
		} else {
			// `h.stack[k]` is the frame of the container below depth `k + 1`, so a frame's high half is its
			// parent's index.
			open = u32(h.stack[depth - 1] >> 32) if depth > 1 else NO_NODE
			depth -= 1
		}
	}
}

// Writes the subtree size of the container at `open` into its `n` and its child count into `spelling` at its
// close. No close node is stored, and the count saturates at `CHILDREN_MAX`: a wider container's `length` counts
// its members by stepping.
@(private)
builder_close_node :: #force_inline proc "contextless" (h: ^Builder, a: int, open, count: u32) {
	#no_bounds_check {
		n := &h.doc.nodes[int(open)]
		n.n = u32(a - int(open))
		n.spelling = u16(min(count, u32(CHILDREN_MAX)))
	}
}

// Returns a slice of `$T` in `allocator`, twice `old`'s length, at least 8 and at least `min` long, with `old`
// copied into it and freed. The new memory is not zeroed: the caller writes every slot before a reader reads it,
// and a doubling copies the old ones. A caller reaches this only when its buffer is full.
@(private, cold)
grow :: #force_no_inline proc "contextless" (allocator: runtime.Allocator, old: []$T, min: int) -> ([]T, bool) {
	context = runtime.default_context()
	n := max(min, max(8, len(old) * 2))
	raw, err := runtime.mem_alloc_non_zeroed(n * size_of(T), align_of(T), allocator)
	if err != nil {
		return nil, false
	}
	fresh := ([^]T)(raw_data(raw))[:n]
	copy(fresh, old)
	if old != nil {
		delete(old, allocator)
	}
	return fresh, true
}

// Doubles the node buffer. A text that fits its reservation does not call this. A refused allocation sets `err`
// to `.No_Memory`.
@(private, cold)
builder_grow :: #force_no_inline proc "contextless" (h: ^Builder) {
	fresh, ok := grow(h.doc.allocator, h.doc.nodes_alloc, 16)
	if !ok {
		h.err = {kind = .No_Memory}
		return
	}
	h.doc.nodes = fresh
	h.doc.nodes_alloc = fresh
}

// Makes room for `n` nodes, for a format that writes its header row before its walk. Returns `.No_Memory` when a
// growth is refused.
builder_reserve :: #force_no_inline proc "contextless" (b: ^Builder, n: int) -> Document_Error {
	for len(b.doc.nodes) < n {
		builder_grow(b)
		if b.err.kind != .None {
			return b.err
		}
	}
	return {}
}

// Doubles the open-container stack. A text whose nesting fits the stack's initial `depth` slots does not call
// this. Returns false when a growth is refused.
@(private, cold)
builder_stack_grow :: #force_no_inline proc "contextless" (h: ^Builder) -> bool {
	fresh, ok := grow(h.doc.allocator, h.stack, 16)
	if !ok {
		return false
	}
	h.stack = fresh
	return true
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

// Pushes an open container's node onto the stack, growing it when full. Returns false when a growth is refused.
@(private)
builder_push :: #force_inline proc "contextless" (h: ^Builder, open: u32) -> bool {
	if h.depth == len(h.stack) && !builder_stack_grow(h) {
		return false
	}
	#no_bounds_check h.stack[h.depth] = u64(open)
	h.depth += 1
	return true
}

// Returns the innermost open container's node, or `NO_NODE` when no container is open.
@(private)
builder_top :: #force_inline proc "contextless" (h: ^Builder) -> u32 {
	if h.depth == 0 {
		return NO_NODE
	}
	top: u32
	#no_bounds_check top = u32(h.stack[h.depth - 1])
	return top
}

// Handles a fact token out of line. A head comment is held until the value it marks arrives, an inline comment
// belongs to the last value completed, and a foot belongs to the innermost open container, or to the root at depth 0.
@(private, cold)
builder_fact :: #force_no_inline proc "contextless" (h: ^Builder, s: Hook_Regs, t: Token) {
	node := u32(0)
	pending := false
	#partial switch t.role {
	case .Comment:
		pending = true
	case .Comment_Inline:
		if s.c == u64(NO_NODE) {
			pending = true
		} else {
			node = u32(s.c)
		}
	case .Comment_Foot:
		if h.depth > 0 {
			node = u32(h.stack[h.depth - 1])
		}
	case:
		pending = true
	}
	if h.n_facts == len(h.doc.facts_alloc) {
		if !builder_facts_grow(h) {
			h.err = {kind = .No_Memory}
			return
		}
	}
	h.doc.facts_alloc[h.n_facts] = Fact{lo = t.lo, node = node, n = t.n, role = t.role, spelling = t.spelling}
	h.n_facts += 1
	if pending && h.pending < 0 {
		h.pending = h.n_facts - 1
	}
}

// Gives the head comments held since the last value to the value node `node`. A pending fact before the header row's
// first byte belongs to the root, since no record precedes it to take it.
@(private)
builder_resolve_pending :: #force_inline proc "contextless" (h: ^Builder, node: u32, root_before := u64(0)) {
	if h.pending < 0 {
		return
	}
	for i in h.pending ..< h.n_facts {
		f := &h.doc.facts_alloc[i]
		f.node = ROOT if root_before != 0 && f.lo < root_before else node
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

// Returns whether `text` allocated `s`: it is neither `buf` nor a slice of the document's source.
@(private)
allocated :: proc(doc: ^Document, s: string, buf: []u8) -> bool {
	p := uintptr(raw_data(s))
	if p == uintptr(raw_data(buf)) {
		return false
	}
	lo := uintptr(raw_data(doc.src))
	return p < lo || p + uintptr(len(s)) > lo + uintptr(len(doc.src))
}

// Returns the kind of node `i`, or `.Null` when `i` is past the last node.
kind :: #force_inline proc(doc: ^Document, i: u32) -> Kind {
	if int(i) >= len(doc.nodes) {
		return .Null
	}
	return doc.nodes[i].kind
}

// Returns the byte span of node `i`: a scalar's token, or a container's opening through its closing bytes. The
// close is not a node, so it comes from the format's `close_end`, which skips the whitespace and comments after
// the container's last descendant. A node past the last returns nil.
span :: #force_inline proc(doc: ^Document, i: u32) -> []u8 {
	if int(i) >= len(doc.nodes) {
		return nil
	}
	n := doc.nodes[i]
	#partial switch n.kind {
	case .Array, .Map:
		return doc.src[n.lo:doc.spelling.close_end(doc, i)]
	case .String:
		// A quoted string's token leaves its quote pair out, and splicing needs the bytes as authored.
		if n.spelling & SPELLING_QUOTED != 0 {
			return doc.src[n.lo - 1:n.lo + u64(n.n) + 1]
		}
		return doc.src[n.lo:n.lo + u64(n.n)]
	case:
		return doc.src[n.lo:n.lo + u64(n.n)]
	}
}

// Returns `all` when `tolerate` is set, else the empty set.
tolerances :: #force_inline proc(tolerate: bool, all: $T) -> T {
	if tolerate {
		return all
	}
	return {}
}

// Returns one past the line end at `pos`: LF, CR, or under `json5` U+2028 or U+2029. Returns `pos` when no line end
// starts there. `json5` accepts U+2028 and U+2029, which end a line in that spec and in no other. The edit list uses
// this rule.
line_end_len :: proc(src: []u8, pos: u64, json5: bool) -> u64 {
	if pos >= u64(len(src)) {
		return pos
	}
	switch src[pos] {
	case '\n':
		return pos + 1
	case '\r':
		return pos + 2 if pos + 1 < u64(len(src)) && src[pos+1] == '\n' else pos + 1
	}
	if json5 && pos + 2 < u64(len(src)) && src[pos] == 0xE2 && src[pos+1] == 0x80 && src[pos+2] | 1 == 0xA9 {
		return pos + 3
	}
	return pos
}

// Returns the number of members in container `i`, from its `spelling`, or 0 for a scalar or a node past the last.
// A saturated count counts the members by stepping them.
length :: #force_inline proc(doc: ^Document, i: u32) -> int {
	if int(i) >= len(doc.nodes) {
		return 0
	}
	n := doc.nodes[i]
	if n.kind != .Array && n.kind != .Map {
		return 0
	}
	if n.spelling != CHILDREN_MAX {
		return int(n.spelling)
	}
	return count_members(doc, i)
}

@(private, cold)
count_members :: #force_no_inline proc(doc: ^Document, i: u32) -> int {
	count := 0
	it := children(doc, i)
	for {
		_, ok := child_next(&it)
		if !ok {
			return count
		}
		count += 1
	}
}

// Returns the distance from node `i` to the next node in preorder: its subtree size for a container, 1 for a
// scalar.
@(private)
skip :: #force_inline proc(doc: ^Document, i: u32) -> int {
	n := doc.nodes[i]
	return int(n.n) if n.kind == .Array || n.kind == .Map else 1
}

// Returns node `n`'s span without a surrounding quote pair, if it has one. A quoted string, a JSON5 single-quoted
// key and a dsv quoted cell share that shape.
inner_span :: #force_inline proc(src: []u8, n: Node) -> (lo, hi: u64) {
	lo, hi = n.lo, n.lo + u64(n.n)
	if hi >= lo + 2 {
		a, b := src[lo], src[hi - 1]
		if (a == '"' || a == '\'') && a == b {
			lo += 1
			hi -= 1
		}
	}
	return
}

// Returns the bytes of node `n`'s text, for a node that needs no decoding. A string token leaves its quote pair
// out, an unquoted key is bare, and a dsv cell's span is its text: a quote in a TSV cell is a byte of the cell.
// `text_view`, `key_equals` and the duplicate rule read a node's text through this function, and none reads
// `src` to find a quote.
@(private)
node_text :: #force_inline proc(src: []u8, n: Node) -> []u8 {
	return src[n.lo:n.lo + u64(n.n)]
}

// Whether key node `i` decodes to `name`. A node whose `SPELLING_DECODE` bit is clear is compared with
// `bytes_equal`, else through the format's `key_equals`. A headed dsv text's header row is its root's key, and
// that row's cells name its columns, so a header cell is a key node too.
key_equals :: #force_inline proc(doc: ^Document, i: u32, name: string) -> bool {
	if int(i) >= len(doc.nodes) {
		return false
	}
	n := doc.nodes[i]
	if n.role != .Key {
		// A key is a scalar, so a container is no key. A header cell is a key node without the role.
		if n.kind > .Plain || doc.header == 0 || i <= doc.header || i >= doc.header + doc.nodes[doc.header].n {
			return false
		}
	}
	if n.spelling & SPELLING_DECODE == 0 {
		// A key node is a scalar, so its span lies inside the source. A header row's `n` is a node count, but
		// `key_equals` rejects that container above.
		#no_bounds_check {
			return bytes_equal(doc.src[n.lo:n.lo + u64(n.n)], transmute([]u8)name)
		}
	}
	return doc.spelling.key_equals(doc, i, name)
}

// Returns the first source byte of node `n`: a quoted string's token starts one byte past its opening quote, so
// its first source byte is `lo - 1`.
@(private)
key_start :: #force_inline proc(n: Node) -> u64 {
	if n.kind == .String && n.spelling & SPELLING_QUOTED != 0 {
		return n.lo - 1
	}
	return n.lo
}

// Whether byte strings `a` and `b` are equal. A length test comes first, then below 8 bytes a byte at a time, at
// most 16 bytes two overlapping 8-byte loads that stay inside both strings, and past that 8-byte words then the
// tail.
bytes_equal :: #force_inline proc(a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	n := len(a)
	#no_bounds_check {
		if n < 8 {
			for i in 0 ..< n {
				if a[i] != b[i] {
					return false
				}
			}
			return true
		}
		if n <= 16 {
			return intrinsics.unaligned_load((^u64)(raw_data(a))) == intrinsics.unaligned_load((^u64)(raw_data(b))) &&
				intrinsics.unaligned_load((^u64)(raw_data(a)[n - 8:])) == intrinsics.unaligned_load((^u64)(raw_data(b)[n - 8:]))
		}
		i := 0
		for i + 8 <= n {
			if intrinsics.unaligned_load((^u64)(raw_data(a)[i:])) != intrinsics.unaligned_load((^u64)(raw_data(b)[i:])) {
				return false
			}
			i += 8
		}
		for i < n {
			if a[i] != b[i] {
				return false
			}
			i += 1
		}
		return true
	}
}

// Returns the member value after `child` in `parent`, or false past the last or when `parent` is no container.
next_child :: #force_inline proc(doc: ^Document, parent, child: u32) -> (u32, bool) {
	if int(parent) >= len(doc.nodes) {
		return NO_NODE, false
	}
	n := doc.nodes[parent]
	if n.kind != .Array && n.kind != .Map {
		return NO_NODE, false
	}
	end := int(parent) + int(n.n)
	j := int(child) + skip(doc, child)
	// A `Map`'s member key is skipped, and so is the dsv header row a root holds first. The key-role `Array` is the
	// header row itself, and it holds key cells, not key/value members, so it skips none.
	if (n.kind == .Map || n.role != .Key) && j < end && doc.nodes[j].role == .Key {
		j += skip(doc, u32(j))
	}
	if j >= end {
		return NO_NODE, false
	}
	return u32(j), true
}

// Returns the first member value of container `i`: its first child, or for a `Map` the value after the first key.
first_child :: #force_inline proc(doc: ^Document, i: u32) -> (u32, bool) {
	it := children(doc, i)
	return child_next(&it)
}

// Returns container `i`'s `k`th member value, counted from 0: for a `Map`, the value after its `k`th key, which is
// the node after the key. A `k` past the last member, a negative `k`, and a node that holds no members return no
// node. A container whose members are one node each is indexed, since its subtree size gives the stride: an
// `Array`'s is its member count plus one and a `Map`'s twice its count plus one. Any other container is walked,
// stepping one subtree size per member.
child_at :: #force_inline proc(doc: ^Document, i: u32, k: int) -> (u32, bool) {
	if int(i) >= len(doc.nodes) || k < 0 {
		return NO_NODE, false
	}
	n := doc.nodes[i]
	count := int(n.spelling)
	// A saturated count says the container holds at least `CHILDREN_MAX` members, so a `k` at or past it may
	// still be within: the walk decides that, and the indexed paths handle only `k` below the count.
	if k >= count {
		if n.spelling != CHILDREN_MAX {
			return NO_NODE, false
		}
		return child_at_walk(doc, i, k)
	}
	#partial switch n.kind {
	case .Map:
		if int(n.n) == 2 * count + 1 {
			return i + 2 + u32(2 * k), true
		}
	case .Array:
		// The dsv header row is a child of the root that names no member, so a root with one is walked.
		if int(n.n) == count + 1 {
			return i + 1 + u32(k), true
		}
	case:
		return NO_NODE, false
	}
	return child_at_walk(doc, i, k)
}

// Walks a container whose members are not all one node, and the `k` a saturated count leaves open. `child_at` calls it
// only in those two cases.
@(private, cold)
child_at_walk :: #force_no_inline proc(doc: ^Document, i: u32, k: int) -> (u32, bool) {
	it := children(doc, i)
	for _ in 0 ..< k {
		if _, ok := child_next(&it); !ok {
			return NO_NODE, false
		}
	}
	v, ok := child_next(&it)
	return v, ok
}

// A `Child_Iter` walks one container's member values. `children` starts it and `child_next` returns the next value.
// For a `Map`, a value's key is the node before it.
Child_Iter :: struct {
	doc:    ^Document,
	parent: u32,
	at:     u32,
	end:    int,
	// The container is a `Map`, whose children are key/value pairs with a key of one node. A step skips the
	// value's span and then one node for the next key, with no role test: only a pair's first node is a key.
	pairs:  bool,
	done:   bool,
}

children :: proc(doc: ^Document, i: u32) -> Child_Iter {
	if int(i) >= len(doc.nodes) {
		return {doc = doc, parent = i, done = true}
	}
	n := doc.nodes[i]
	if n.kind != .Array && n.kind != .Map {
		return {doc = doc, parent = i, done = true}
	}
	it := Child_Iter{doc = doc, parent = i, end = int(i) + int(n.n), pairs = n.kind == .Map}
	j := int(i) + 1
	if n.kind == .Map {
		// The first member's key is one node.
		j += 1
	} else if n.role != .Key && j < it.end && doc.nodes[j].role == .Key {
		// The dsv header row a root holds first. The key-role `Array` is that row, and it holds key cells, not
		// members.
		j += skip(doc, u32(j))
	}
	if j >= it.end {
		it.done = true
	} else {
		it.at = u32(j)
	}
	return it
}

// Returns the step from `v` over a container's subtree, to the node after it. The call makes the kind test a
// `b.eq` with the load of `n` in the taken block: inlined, LLVM computes the stride with `csinc` from a load of
// `n` that the next member's address waits for.
@(private)
subtree_step :: #force_no_inline proc(v: int, n: u32) -> int {
	return v + int(n)
}

// Returns the next value of a container and is inlined at every call, so a call does not spill the iterator and
// re-read it per member.
child_next :: #force_inline proc(it: ^Child_Iter) -> (u32, bool) {
	if it.done {
		return NO_NODE, false
	}
	v := it.at
	doc := it.doc
	n := doc.nodes[v]
	j := int(v) + 1
	if n.kind == .Array || n.kind == .Map {
		j = subtree_step(int(v), n.n)
	}
	if it.pairs {
		j += 1
	}
	if j >= it.end {
		it.done = true
	} else {
		it.at = u32(j)
	}
	return v, true
}

// Returns the value of the member of `obj` whose key decodes to `name`, under `.First` or `.Last`. `.Refuse`
// reads as `.Last`, since the build refused repeats, and `.All` reads as `.First`, while `member_all` yields every
// match. A headed dsv record's members are its cells, named by the header's cells.
member :: #force_inline proc(doc: ^Document, obj: u32, name: string, dups := Duplicates.Last) -> (u32, bool) {
	// A single loop handles both shapes: `member_next` is inlined, so an object's step uses this frame's registers.
	it := member_all(doc, obj, name)
	found := NO_NODE
	for {
		v, ok := member_next(&it)
		if !ok {
			return found, found != NO_NODE
		}
		if dups == .First || dups == .All {
			return v, true
		}
		found = v
	}
}

// A `Member_Iter` walks every member of `obj` whose key decodes to `name`, in source order. A headed dsv record is an
// `Array`, and its members are its cells: column `i`'s key is header cell `i`, and a cell past the header's last
// matches no key. A cell's node is its record's node plus one plus its column.
Member_Iter :: struct {
	doc:  ^Document,
	at:   int,
	end:  int,
	name: string,
	rec:  u32, // the headed record whose cells are read, NO_NODE for a JSON object
	done: bool,
}

member_all :: proc(doc: ^Document, obj: u32, name: string) -> Member_Iter {
	if int(obj) >= len(doc.nodes) {
		return {doc = doc, rec = NO_NODE, done = true}
	}
	n := doc.nodes[obj]
	if doc.header != 0 && n.kind == .Array && n.role == .Value && obj != ROOT && obj != doc.header {
		h := doc.nodes[doc.header]
		return {doc = doc, at = int(doc.header) + 1, end = int(doc.header) + int(h.n), name = name, rec = obj}
	}
	if n.kind != .Map {
		return {doc = doc, rec = NO_NODE, done = true}
	}
	return {doc = doc, at = int(obj) + 1, end = int(obj) + int(n.n), name = name, rec = NO_NODE}
}

// Returns the next member and is inlined at `member`, so the object step needs no iterator load or store between
// members. A headed record is passed to `member_next_cell`.
member_next :: #force_inline proc(it: ^Member_Iter) -> (u32, bool) {
	if it.rec != NO_NODE {
		return member_next_cell(it)
	}
	for !it.done {
		j := it.at
		if j >= it.end {
			it.done = true
			break
		}
		// An object's children alternate key and value, and a key is one node, so the value follows the key
		// directly and the next member's key follows the value's own span.
		v := j + 1
		it.at = v + skip(it.doc, u32(v))
		if key_equals(it.doc, u32(j), it.name) {
			return u32(v), true
		}
	}
	return NO_NODE, false
}

// Returns the next of a headed record's cells whose header cell decodes to `it.name`. The walk runs over the
// header's cells. A column past the record's last cell matches nothing, so a ragged record's missing columns are
// absent.
@(private)
member_next_cell :: #force_inline proc(it: ^Member_Iter) -> (u32, bool) {
	cells := int(it.doc.nodes[it.rec].n) - 1
	for !it.done {
		j := it.at
		if j >= it.end {
			it.done = true
			break
		}
		it.at = j + 1
		col := j - int(it.doc.header) - 1
		if col < cells && key_equals(it.doc, u32(j), it.name) {
			return it.rec + 1 + u32(col), true
		}
	}
	return NO_NODE, false
}

// Returns the decoded text of string or plain node `i`. A node whose `SPELLING_DECODE` bit is clear is its span
// without its quotes. A node that needs decoding is written into `buf` when it has room, else into `allocator`, and
// `text` returns it without saying which, so a caller that frees uses `text_view`. Returns false for a container
// or a node past the last.
text :: #force_inline proc(doc: ^Document, i: u32, buf: []u8, allocator := context.allocator) -> (string, bool) {
	s, _, ok := text_view(doc, i, buf, allocator)
	return s, ok
}

// Returns `text`, plus the allocation behind the text when it came from `allocator` rather than `src` or `buf`. A
// caller frees `owned` with the same allocator. `owned` is nil for a borrowed text.
text_view :: #force_inline proc(doc: ^Document, i: u32, buf: []u8, allocator := context.allocator) -> (s: string, owned: []u8, ok: bool) {
	if int(i) >= len(doc.nodes) {
		return "", nil, false
	}
	n := doc.nodes[i]
	// Only a scalar carries text: a container's `n` is a node count, not a byte length.
	if n.kind > .Plain {
		return "", nil, false
	}
	if n.spelling & SPELLING_DECODE == 0 {
		return string(node_text(doc.src, n)), nil, true
	}
	s, ok = doc.spelling.text(doc, i, buf, allocator)
	if !ok {
		return "", nil, false
	}
	if allocated(doc, s, buf) {
		owned = transmute([]u8)s
	}
	return
}

// Decodes a node's bytes into `buf` or `allocator`: `d` is the decoder's initial state and `next` returns one
// byte at a time. The decoder makes two passes, one to count the bytes and one to write them.
decode_text :: proc(buf: []u8, allocator: runtime.Allocator, d: $D, $next: proc(^D) -> (u8, bool)) -> (string, bool) {
	count := 0
	c := d
	for {
		_, ok := next(&c)
		if !ok {
			break
		}
		count += 1
	}
	dst := buf
	if len(dst) < count {
		fresh, err := make([]u8, count, allocator)
		if err != nil {
			return "", false
		}
		dst = fresh
	}
	c = d
	w := 0
	for {
		b, ok := next(&c)
		if !ok {
			break
		}
		dst[w] = b
		w += 1
	}
	return string(dst[:w]), true
}

// Returns the number node `i` writes, decoded from its span. A container, an `End` node and an index past the last
// node return `.Wide`. The format's reader refuses a key or a string of its own.
number :: #force_inline proc(doc: ^Document, i: u32) -> Number {
	if int(i) < len(doc.nodes) && doc.nodes[i].kind <= .Plain {
		return doc.spelling.number(doc, i)
	}
	return {0, .Wide}
}

// Returns what `Plain` node `i` is, through the format's `resolve`. A node of another kind returns its own kind,
// and an index past the last returns `.Null`.
resolve :: #force_inline proc(doc: ^Document, i: u32, opts := Resolve_Options{}) -> Kind {
	if int(i) >= len(doc.nodes) {
		return .Null
	}
	return doc.spelling.resolve(doc, i, opts)
}

// Returns the `i64` an `Int` node writes, or a `Uint` node's value when it fits `i64`. Returns false for any
// other number.
int_value :: #force_inline proc(doc: ^Document, i: u32) -> (i64, bool) {
	n := number(doc, i)
	switch n.kind {
	case .Int:
		return i64(n.bits), true
	case .Uint:
		if n.bits <= u64(max(i64)) {
			return i64(n.bits), true
		}
	case .Float, .Wide:
	}
	return 0, false
}

// Returns the `u64` a `Uint` node or a nonnegative `Int` node writes. Unmarshal reads unsigned targets with it.
uint_value :: #force_inline proc(doc: ^Document, i: u32) -> (u64, bool) {
	n := number(doc, i)
	switch n.kind {
	case .Int:
		if i64(n.bits) >= 0 {
			return n.bits, true
		}
	case .Uint:
		return n.bits, true
	case .Float, .Wide:
	}
	return 0, false
}

// Returns a walk over the bodies of node `i`'s facts of `role`, in source order, with `fact_next` giving one at a
// time. `NO_NODE` returns an empty walk. This is the public fact reader. A fact body is a slice of the source, so
// a read allocates nothing.
facts_of :: proc(doc: ^Document, i: u32, role: Role) -> Facts {
	if i == NO_NODE {
		return {doc = doc, role = role}
	}
	return {doc = doc, at = lower_fact(doc.facts, i), end = lower_fact(doc.facts, i + 1), role = role}
}

// Returns node `i`'s facts of every role, sorted by node and then source order. Core's edit and span code walk
// them, and a caller reads one role at a time through `facts_of`.
@(private)
all_facts :: #force_inline proc(doc: ^Document, i: u32) -> []Fact {
	if i == NO_NODE {
		return nil
	}
	lo := lower_fact(doc.facts, i)
	hi := lower_fact(doc.facts, i + 1)
	return doc.facts[lo:hi]
}

// A `Facts` walk reads the bodies of one node's facts of one role, in source order. `fact_next` returns one at a time.
Facts :: struct {
	doc:  ^Document,
	at:   int,
	end:  int,
	role: Role,
}

// Returns the next body without the markers its format writes: the fact's `spelling` gives the lead and tail
// lengths, and core reads the bytes between them without knowing any format's marker.
fact_next :: proc(it: ^Facts) -> (body: []u8, ok: bool) {
	for it.at < it.end {
		f := it.doc.facts[it.at]
		it.at += 1
		if f.role == it.role {
			return fact_body(it.doc, f), true
		}
	}
	return nil, false
}

@(private)
fact_body :: #force_inline proc(doc: ^Document, f: Fact) -> []u8 {
	lead := u64(f.spelling & 0xFF)
	tail := u64(f.spelling >> 8)
	return doc.src[f.lo + lead : f.lo + u64(f.n) - tail]
}

@(private)
lower_fact :: proc(facts: []Fact, node: u32) -> int {
	lo, hi := 0, len(facts)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if facts[mid].node < node {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}


// Checks that the object from `open` through its last node at `end` has no two keys whose decoded text is equal,
// under `.Refuse`. A repeated key returns `.Duplicate_Key` at the later key's first byte. The table is a 64-entry
// array on the stack and spills to `allocator` past 32 keys. The builder and a dsv header both use this check:
// with `cell_keys` set, every scalar of the range is read as a key, since a dsv header's cells name its columns. A
// refused allocation returns `.No_Memory`.
duplicate_key :: #force_no_inline proc "contextless" (doc: ^Document, open, end: u32, allocator: runtime.Allocator, cell_keys := false) -> Document_Error {
	context = runtime.default_context()
	keys := 0
	for i := int(open) + 1; i < int(end); {
		n := doc.nodes[i]
		if n.role == .Key || cell_keys && n.kind <= .Plain {
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
		if n.role != .Key && !(cell_keys && n.kind <= .Plain) {
			i += int(n.n) if n.kind == .Array || n.kind == .Map else 1
			continue
		}
		key := u32(i)
		buf: [256]u8
		s, owned, ok := text_view(doc, key, buf[:], allocator)
		if !ok {
			return {kind = .No_Memory}
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
					if owned != nil {
						delete(owned, allocator)
					}
					return {kind = .No_Memory}
				}
				if same {
					if owned != nil {
						delete(owned, allocator)
					}
					return {kind = .Duplicate_Key, at = key_start(n)}
				}
			}
			at = (at + 1) & mask
		}
		if owned != nil {
			delete(owned, allocator)
		}
		i += int(n.n) if n.kind == .Array || n.kind == .Map else 1
	}
	return {}
}

// Returns whether key node `i`'s text equals `s`, both read through `text_view`: a CSV quoted cell's quotes are
// markers, and a TSV cell's quote is a byte of its text.
@(private)
text_equals :: proc(doc: ^Document, i: u32, s: string, allocator: runtime.Allocator) -> (bool, bool) {
	buf: [256]u8
	t, owned, ok := text_view(doc, i, buf[:], allocator)
	if !ok {
		return false, false
	}
	if owned != nil {
		defer delete(owned, allocator)
	}
	return t == s, true
}

@(private)
Key_Entry :: struct {
	hash: u64,
	node: u32,
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
