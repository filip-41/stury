package build

import "base:intrinsics"
import "base:runtime"
import core ".."
import compose "../compose"

// The path engine: one step logic that answers paths from any token source, with no format in it. `$MANY` true reads up
// to 64 paths with the state of `many.odin`, and false compiles the same logic down to one path at step `d - 1`, where
// the depth is the step number: a container open at depth `d` reads `steps[d - 1]`, and a value at depth `len(steps)` is
// an answer, kept whole. `$SINK` says where answers go. Whatever no step needs is skipped, so the logic sees the members
// of the containers on the path and nothing else.

// Where the engine sends answers. `.Document` writes the partial document, `.Replay` reads a built one and writes
// nothing, `.Stream` writes nothing and calls `each_answer`'s `on`.
@(private)
Sink :: enum u8 {
	Document,
	Replay,
	Stream,
}

// One path of a read. The `u64` sets hold a bit per step. `multi` is the first step that can answer again, `rollback` the
// first step a repeated key can take answers back through, `alls` the `All` steps, and `indexed` the steps that keep a
// `Kept_Child` for each child they keep by position. `late` says the path's answers can be known out of text order, so
// its limit is applied to the sorted list and its `rollback` is -1.
@(private)
Scan_Path :: struct {
	steps:    []core.Step,
	n:        int,
	limit:    int,
	count:    int, // the answers given, for `$MANY`, which `n_answers` holds with one path
	multi:    int,
	rollback: int,
	optional: u64,
	alls:     u64,
	indexed:  u64,
	negative: u64,
	descend:  int, // the `Descend` step, -1 for none
	deep:     int, // the path's column in `Scan_Many.deep`, -1 with no `Descend`
	marks:    int, // the path's first entry in `Scan_Many.marks`
	late:     bool,
	broad:    bool, // a step or an option the single-path form has no state for
}

// What a matched `Name` left behind when it matched: the lists' lengths and the node cursor, which a repeated key under
// `.Last` restores.
@(private)
Scan_Mark :: struct {
	a:       u64,
	answers: int,
	counts:  int,
	kept:    int,
	missing: int,
}

// A `Scan` holds one read's state beside the walk's registers, which are the builder's: `a` the node cursor, the high
// half of `b` the open container, its low half that container's children so far, kept or not, and `c` the depth.
//
// The `u64` sets hold a bit per step of `path`, the path of a read that is not `$MANY`. `matched` says a `Name` has met its
// key in the container open at that step, `maps` that the container is an `Object`, and `cut` that the limit dropped a member.
// `next` holds a bit per path that picked the coming value.
Scan :: struct {
	b:          Builder,
	path:       Scan_Path,
	keep:       int, // the depth past which every token is kept
	free:       int, // what `keep` is with no value being kept
	next:       u64,
	matched:    u64,
	maps:       u64,
	cut:        u64,
	flush:      int, // the depth at and above which `.Stream` may give what it holds
	last:       bool, // a repeated key replaces the candidate
	every_key:  bool,
	stop_early: bool,
	stopped:    bool,
	paused:     bool, // an `Answer_Iter`'s buffer holds a batch, so its walk stops on the next token it can resume from
	// The walk resumes after any token, so the step stops on the token whose answers filled the batch. A walk that
	// resumes only at some tokens tests `paused` in its own hook.
	pause_on_flush: bool,
	positional: bool, // an `Object`'s members answer an `Index`, as a dsv record's cells do
	again:      bool, // `scan_end` keeps the lists for `scan_again`, and the document's answers borrow them
	at:         core.Node_Index, // the node `query` is giving the logic
	answers:    []core.Answer,
	n_answers:  int,
	kept:       []core.Kept_Child,
	n_kept:     int,
	missing:    []core.Missing_Name,
	n_missing:  int,
	many:       ^Scan_Many, // the `$MANY` state, nil with one path
	rewalk:     Rewalk,
	opts:       rawptr, // the format's walk options, which `rewalk` reads
	ends:       []u32, // the container ends a `$MANY` replay holds, a frame per depth
	marks:      [core.MAX_STEPS]Scan_Mark,
	cut_idx:    u64, // the steps that are a non-negative `Index`, past whose element a replay reads no sibling
	cut_names:  u64, // the steps that are a `Name` of a first-wins read, past whose key a replay reads no member
	cut_end:    [core.MAX_STEPS]u32, // where a replay goes on after a container it cut short, 0 for one not cut
	slots:      [core.MAX_STEPS]u32, // the `Child_Count` reserved for the container open at each depth
	first:      [8]core.Answer, // `answers` until they outgrow it, so a read of few allocates no list
}

// Gives one value of a text to the `$MANY` form's hook again from the value's first byte, `at` being its node in a
// built document. A format's `scan` sets it, since only a format can walk from a value.
@(private)
Rewalk :: proc "contextless" (h: ^Scan, s: ^core.Hook_Regs, lo: u64, at: core.Node_Index)

// Reads `paths` and `read` into `h`. `many` asks for `$MANY`, and `depth` bounds the frames a `Descend` path opens.
@(private)
scan_plan :: proc(h: ^Scan, paths: []core.Path, read: core.Path_Options, depth: int, many: bool, allocator: runtime.Allocator) -> core.Path_Error {
	h.last = read.dups != .First && read.dups != .All
	h.every_key = read.dups == .All
	h.stop_early = read.stop_early
	h.flush = max(int)
	if many || len(paths) != 1 {
		return many_plan(h, paths, depth, allocator)
	}
	if e := scan_plan_path(h, &h.path, paths[0]); e.kind != .None {
		return e
	}
	if h.path.broad {
		h.path = {}
		return many_plan(h, paths, depth, allocator)
	}
	h.free = h.path.n
	h.keep = h.free
	for step, k in h.path.steps {
		switch x in step {
		case core.Index:
			h.cut_idx |= u64(x >= 0) << uint(k)
		case core.Name:
			h.cut_names |= u64(!h.last && !h.every_key) << uint(k)
		case core.Index_Or_Name, core.All, core.Slice, core.Descend:
		}
	}
	h.next = 1 if h.path.limit > 0 else 0
	// With one path an `All` drops a member only for the limit, and `cut` tells that.
	if h.path.limit == max(int) {
		h.path.indexed &~= h.path.alls
	}
	return {}
}

@(private)
scan_plan_path :: proc(h: ^Scan, x: ^Scan_Path, path: core.Path) -> core.Path_Error {
	if len(path.steps) > core.MAX_STEPS {
		return {kind = .Over_Capacity}
	}
	if limit, limited := path.limit.?; limited && limit < 0 {
		return {kind = .Bad_Path, reason = .Bad_Limit}
	}
	x.steps = path.steps
	x.n = len(path.steps)
	x.limit = path.limit.? or_else max(int)
	x.multi, x.rollback = x.n, x.n
	x.optional = transmute(u64)path.optional
	x.descend = -1
	x.broad = h.every_key || path.optional != {}
	for step, i in path.steps {
		bit := u64(1) << uint(i)
		switch s in step {
		case core.Name, core.Index_Or_Name:
			if h.every_key {
				x.multi = min(x.multi, i)
			} else if h.last {
				x.multi = min(x.multi, i)
				x.rollback = min(x.rollback, i)
				// A key past a `Descend` can repeat in any container, so nothing is known before the root closes.
				h.flush = min(h.flush, i) if x.descend < 0 else -1
			}
			if _, either := s.(core.Index_Or_Name); either {
				x.indexed |= bit
			} else if name := s.(core.Name); raw_data(string(name)) == nil {
				return {kind = .Bad_Path, reason = .Unset_Step}
			}
		case core.Index:
			x.indexed |= bit
		case core.All:
			x.alls |= bit
			x.multi = min(x.multi, i)
			x.indexed |= bit
		case core.Slice:
			x.indexed |= bit
			x.multi = min(x.multi, i)
		case core.Descend:
			// One `Descend` tells every answer's route by its depth less its step, and a step is a bit of a `u64`.
			if x.descend >= 0 {
				return {kind = .Bad_Path, reason = .Two_Descends}
			}
			if x.n >= core.MAX_STEPS {
				return {kind = .Over_Capacity}
			}
			x.broad = true
			x.descend = i
			x.late = true
			x.multi = min(x.multi, i)
		}
		if need, _ := step_ring(step); need > 0 {
			x.broad = true
			x.negative |= bit
			x.late = true
			x.multi = min(x.multi, i)
		}
	}
	if x.late {
		x.rollback = -1
		if x.limit != max(int) {
			h.flush = -1
		}
	}
	return {}
}

// Starts a scan of `paths` over `src`, read as `as`. `depth` is as in `builder_start`, `frames` is the caller's room for that stack,
// which `depth` may outgrow, and a format's `scan` runs its walk with `scan_hook`, or `scan_hook_many` when `Scan.many` is
// set, and ends it with `scan_end`. `many` asks for `$MANY`. `h` may hold anything: the lists from `marks` on are written
// before they are read.
scan_start :: proc(h: ^Scan, src: []u8, as: core.As, paths: []core.Path, read: core.Path_Options, positional: bool, allocator: runtime.Allocator, depth: int, frames: []u64, many := false, state: rawptr = nil, on: proc(state: rawptr, a: core.Token_Answer) -> bool = nil) -> core.Path_Error {
	intrinsics.mem_zero(h, offset_of(Scan, marks))
	e := scan_plan(h, paths, read, depth, many, allocator)
	if e.kind != .None {
		many_free(h, allocator)
		return e
	}
	if h.many != nil {
		h.many.on, h.many.state, h.many.ctx = on, state, context
	}
	h.positional = positional
	h.answers = h.first[:]
	// A stream's walk writes no node, and a key to decode or a kept value takes its room when it arrives.
	h.b = builder_start(src, as, false, allocator, -1 if on != nil else 64, depth, 0, frames)
	if h.b.err.kind != .None {
		many_free(h, allocator)
		_, be := builder_end(&h.b, BUILDER_REGS, nil)
		return core.path_error(be)
	}
	return {}
}

// Starts the next walk over `src` of a one-path read that `scan_end` ended with `again`, with its plan and lists, the
// stack `frames` in place of one the last walk grew, and the builder's buffers, which the document that walk returned
// shares until the next `scan_end` writes over it.
scan_again :: proc(h: ^Scan, src: []u8, as: core.As, allocator: runtime.Allocator, frames: []u64) -> core.Path_Error {
	if h.b.doc.nodes_alloc == nil {
		// The last walk failed, and freed its buffers.
		if h.b = builder_start(src, as, false, allocator, 64, 0); h.b.err.kind != .None {
			return {kind = .No_Memory}
		}
	} else {
		h.b.doc.src, h.b.doc.as, h.b.doc.nodes = src, as, h.b.doc.nodes_alloc
		h.b.n_facts, h.b.pending, h.b.last, h.b.root_close, h.b.n_counts = 0, -1, core.NO_NODE, 0, 0
		h.b.wide_count, h.b.wide_more = 0, false
	}
	if !h.b.borrowed {
		delete(h.b.stack, allocator)
	}
	h.b.stack, h.b.borrowed = frames, true
	h.keep, h.next = h.free, 1 if h.path.limit > 0 else 0
	h.matched, h.maps, h.cut, h.stopped, h.path.count = 0, 0, 0, false, 0
	h.n_answers, h.n_kept, h.n_missing = 0, 0, 0
	return {}
}

// Frees what a read ended with `again` holds past its documents.
scan_free :: proc(h: ^Scan, allocator: runtime.Allocator) {
	if raw_data(h.answers) != &h.first[0] {
		delete(h.answers, allocator)
	}
	delete(h.kept, allocator)
	delete(h.missing, allocator)
	many_free(h, allocator)
	if !h.b.borrowed {
		delete(h.b.stack, allocator)
		h.b.stack = nil
	}
}

// Writes to `doc` the partial document the walk built, its answers in text order, or returns the error that stopped it
// with `doc` zero. `root_close` is the root's end when the walk gives one, else 0. On an error every
// allocation is freed, but for the lists of a read with `again`.
scan_end :: proc(h: ^Scan, regs: core.Hook_Regs, root_close: u64, fault: Maybe(core.Fault), doc: ^core.Document) -> core.Path_Error {
	regs := regs
	allocator := h.b.doc.allocator
	streamed := h.many != nil && h.many.on != nil
	if _, bad := fault.?; !bad && h.stopped && !streamed && h.b.err.kind == .None {
		// The containers the stop left open are on the path. Their counts hold what was read of them. A stream keeps no counts.
		for regs.c > 0 {
			scan_partial(h, regs, h.many.frames[regs.c].slot if h.many != nil else h.slots[regs.c - 1])
			regs.c -= 1
			regs.b = h.b.stack[regs.c]
		}
	}
	// A slot of a container that turned out whole goes. What stays is in node order, since a slot is taken at an open.
	w := 0
	for c in h.b.doc.counts_alloc[:h.b.n_counts] {
		if c.node != core.NO_NODE {
			h.b.doc.counts_alloc[w] = c
			w += 1
		}
	}
	h.b.n_counts = w
	if _, bad := fault.?; !bad && h.many != nil {
		if streamed {
			// Under a limit on a late path everything was held to the end.
			many_settle(h)
			many_flush(h)
		} else {
			many_answers(h)
		}
	}
	h.b.wide_more = h.b.wide_count != 0
	h.b.root_close = 0 if h.stopped else root_close
	e: core.Document_Error
	if h.again {
		// The builder keeps its buffers for `scan_again`, and is zero when `builder_finish` freed them.
		e = builder_finish(&h.b, regs, fault)
		// `doc` is the last record's, whose buffers are the builder's, but a child index built on it is its own.
		stale := core.Document{indexed = doc.indexed, allocator = doc.allocator}
		core.destroy(&stale)
		doc^ = h.b.doc
	} else {
		doc^, e = builder_end(&h.b, regs, fault)
	}
	if e.kind != .None {
		if !h.again {
			scan_free(h, allocator)
		}
		return core.path_error(e)
	}
	doc.partial = true
	doc.stopped = h.stopped
	if h.positional {
		core.set_tables(doc, core.POSITIONAL_TABLES[:])
	}
	if h.again {
		doc.answers, doc.kept, doc.missing = h.answers[:h.n_answers], h.kept[:h.n_kept], h.missing[:h.n_missing]
		return {}
	}
	doc.answers, doc.kept, doc.missing = h.answers[:h.n_answers], h.kept[:h.n_kept], h.missing[:h.n_missing]
	failed := core.own_reads(doc)
	scan_free(h, allocator)
	if failed != nil {
		core.destroy(doc)
		return {kind = .No_Memory}
	}
	return {}
}

// Answers `paths` over a document built whole, in the order a scan of its text answers.
query :: proc(doc: ^core.Document, paths: []core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Path_Error) {
	if doc.partial {
		return nil, {kind = .Unsupported}
	}
	if doc.clash != 0 && read.dups != .First && read.dups != .All {
		return nil, {kind = .Duplicate_Key, at = doc.clash}
	}
	h: Scan
	h.b.doc = doc^
	h.b.doc.allocator = allocator
	h.positional = core.header_of(doc) != 0
	depth := min(core.reserve_depth(doc.as.max_depth, len(doc.nodes)), core.MAX_DEPTH)
	if e := scan_plan(&h, paths, {dups = read.dups}, depth, false, allocator); e.kind != .None {
		many_free(&h, allocator)
		return nil, e
	}
	regs := BUILDER_REGS
	if h.many == nil {
		stack: [core.MAX_STEPS + 2]u64
		ends: [core.MAX_STEPS + 2]u32
		h.b.stack, h.b.borrowed = stack[:], true
		replay(false, &h, 0, u32(len(doc.nodes)), &regs, ends[:])
	} else {
		h.rewalk = replay_rewalk
		no_stack, no_ends: runtime.Allocator_Error
		h.b.stack, no_stack = make([]u64, depth + 2, allocator)
		h.ends, no_ends = make([]u32, depth, allocator)
		if no_stack != nil || no_ends != nil {
			h.b.err = {kind = .No_Memory}
		} else {
			replay(true, &h, 0, u32(len(doc.nodes)), &regs, h.ends)
		}
		if h.b.err.kind == .None {
			many_answers(&h)
		}
		many_free(&h, allocator)
		delete(h.b.stack, allocator)
		delete(h.ends, allocator)
	}
	if h.b.err.kind != .None {
		delete(h.answers, allocator)
		return nil, {kind = .No_Memory}
	}
	return h.answers[:h.n_answers], {}
}

// Answers `path` or `paths` over a document built whole, in the order a scan of its text answers. A partial document
// is `.Unsupported`.
query_doc :: proc {query_doc_one, query_doc_many}

@(private)
query_doc_one :: proc(doc: ^core.Document, path: core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Error) {
	return query_doc_many(doc, []core.Path{path}, read, allocator)
}

@(private)
query_doc_many :: proc(doc: ^core.Document, paths: []core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Error) {
	if doc == nil || doc.readers == nil {
		return nil, core.error_of(core.Path_Error{kind = .Unsupported})
	}
	found, refusal := query(doc, paths, read, allocator)
	return found, core.error_of(refusal)
}

// Writes `in_` as the value at every answer of `path` over the built `doc`, and returns the new text. A `Name` the path ends
// in that its container lacks is inserted there, an `Index` the path ends in that is its array's length appends, and a
// `?` on either passes a container that is not of its kind. A missing parent is `.Bad_Index`, and an index past the
// length `.Bad_Position`.
set_answers :: proc(list: ^core.Edit_List, path: core.Path, in_: core.Edit_Input, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	doc := list.doc
	// A `Name` or an `Index` at the end is set through its container, so that a missing name or element is told from a
	// missing parent.
	read_path := path
	name: core.Name
	index: core.Index
	named, indexed, whole, optional := false, false, false, false
	if n := len(path.steps); n > 0 {
		name, named = path.steps[n - 1].(core.Name)
		index, indexed = path.steps[n - 1].(core.Index)
		// A zero `Step` is left for the read to refuse.
		named &&= raw_data(string(name)) != nil
		optional = (named || indexed) && n - 1 in path.optional
		// A `Descend` answers in the order its containers close, which is not the order it reaches them, so under a limit
		// the answers of the whole path pick the containers.
		whole = (named || indexed) && path.limit != nil && n > 1 && path.steps[n - 2] == core.Descend{}
		if (named || indexed) && !whole {
			read_path.steps = path.steps[:n - 1]
			read_path.optional -= {n - 1}
		}
	}
	answers, qerr := query(doc, []core.Path{read_path}, read, allocator)
	defer delete(answers, allocator)
	if qerr.kind != .None {
		return nil, core.error_of(qerr)
	}
	for a in answers {
		e := core.error_of(core.Document_Error{kind = .Bad_Index, reason = .No_Parent})
		switch {
		case a.outcome == .Found && (!(named || indexed) || whole):
			e = core.set_input(list, a.node, in_)
		case a.outcome == .Found && named && doc.nodes[a.node].kind == .Object:
			e = core.set_member_input(list, a.node, string(name), in_, read.dups)
		case a.outcome == .Found && indexed:
			e = set_element(list, a.node, int(index), in_)
		// A missing member names the container that lacks it.
		case named && whole && a.outcome == .Missing && doc.nodes[a.owner].kind == .Object:
			e = core.set_member_input(list, a.owner, string(name), in_, read.dups)
		case a.outcome == .Found && doc.nodes[a.node].kind != .Null:
			e = core.error_of(core.Document_Error{kind = .Bad_Index, reason = .Not_Object})
		}
		// `?` drops the step a container not of its kind cannot take, as a read of the whole path does.
		if refusal, refused := e.(core.Document_Error); refused && optional && (refusal.reason == .Not_Object || refusal.reason == .Not_Array) {
			continue
		}
		if e != nil {
			return nil, e
		}
	}
	committed, _, e := compose.commit(list, allocator = allocator)
	if e != nil {
		return nil, e
	}
	return committed, nil
}

// Sets element `k` of `arr`, counted from the end when negative, or appends at its length.
@(private = "file")
set_element :: proc(list: ^core.Edit_List, arr: core.Node_Index, k: int, in_: core.Edit_Input) -> core.Error {
	n := core.length(list.doc, arr)
	k := k + n if k < 0 else k
	v, presence := core.element_of(list.doc, arr, k)
	switch presence {
	case .Found:
		return core.set_input(list, v, in_)
	case .Wrong_Kind:
		return core.error_of(core.Document_Error{kind = .Bad_Index, reason = .Not_Array})
	case .Not_Loaded:
		return core.error_of(core.Document_Error{kind = .Bad_Index, reason = .Not_Loaded})
	case .Missing:
	}
	if k != n {
		return core.error_of(core.Document_Error{kind = .Bad_Position})
	}
	return core.insert_input(list, arr, k, "", false, in_)
}

// A `$MANY` read's re-walk of the value at node `at` of a built document.
@(private)
replay_rewalk :: proc "contextless" (h: ^Scan, s: ^core.Hook_Regs, lo: u64, at: core.Node_Index) {
	// The replay that holds this one may have grown its stacks past `ends`.
	replay(true, h, u32(at), u32(at) + h.b.doc.nodes[at].n, s, h.ends[min(int(s.c), len(h.ends)):])
}

// A format's `Services.scan` for a text it reads by building it whole: answers `paths` over `doc`, which the build gave
// with the error `built`, gives the document its answers as a read by paths does, and gives each answer to `on` when it
// is set, until `on` returns false. On an error `doc` is destroyed.
scan_built :: proc(doc: ^core.Document, built: core.Document_Error, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
	if built.kind != .None {
		return {}, core.path_error(built)
	}
	answers, err := query(doc, paths, {read.dups}, allocator)
	if err.kind == .None {
		doc.answers, doc.kept, doc.missing = answers, nil, nil
		if core.own_reads(doc) != nil {
			err = {kind = .No_Memory}
		}
		delete(answers, allocator)
	}
	if err.kind != .None {
		core.destroy(doc)
		return {}, err
	}
	if on != nil {
		for a in doc.answers {
			if !on(state, built_answer(doc, a)) {
				break
			}
		}
	}
	return doc^, {}
}

// Answer `a` of a built document as a token: a found scalar's bytes, a found container from its open through its
// close, or for a missing member the close of the container that lacks it.
@(private)
built_answer :: proc(doc: ^core.Document, a: core.Answer) -> core.Token_Answer {
	t := core.Token{kind = .Null}
	lo, hi: u64
	if a.node != core.NO_NODE && (a.outcome == .Found || a.outcome == .Wrong_Kind) {
		t = doc.nodes[a.node]
		if a.outcome == .Found {
			lo, hi = core.scalar_ends(t)
			if t.kind > .Plain {
				lo, hi = t.lo, doc.readers.close_end(doc, a.node)
			}
		}
	} else if a.owner != core.NO_NODE {
		t = core.Token{lo = doc.readers.close_end(doc, a.owner), kind = .End}
	}
	return {t, lo, hi, a.path, a.outcome}
}

// Reads `path` over `src` as `as` says, into a partial document holding what the path reached and `Document.answers` in
// text order, through the format's `Services.scan`. Everything the walk passes is still judged, unless `read.stop_early`
// ends it. `core.destroy` frees the document, which borrows `src`. Under `.Refuse` the document holds the
// whole text. A handle with no format's scan is `.Unsupported`.
@(private)
scan_one :: #force_inline proc(src: []u8, as: core.As, path: core.Path, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return scan_many(src, as, []core.Path{path}, read, allocator)
}

// Reads up to 64 `paths` in one read, as `scan_one`. An answer's `path` is its path's number, and the answers of all the
// paths are in one text order.
@(private)
scan_many :: proc(src: []u8, as: core.As, paths: []core.Path, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	s := core.services_of(as)
	if s == nil || s.scan == nil {
		return {}, core.error_of(core.Path_Error{kind = .Unsupported})
	}
	return scan_with(src, as, paths, read, allocator, services_build, services_scan)
}

scan :: proc {scan_one, scan_many}

// Calls `on` with each answer of `path` or `paths` as it becomes known, with no document. `on` returns false to stop the
// read. A found container answers at its close. A repeated key can take an answer back under `.Last`, so an answer
// through a `Name` waits for that `Name`'s container to close there, and `.First` gives each as soon as it is read.
// Answers come in the order they are known, and a path with a `Descend` or a negative index that has a limit gives them
// all at the end. `.Refuse` reads the whole text first, so a fault there comes before any answer.
@(private)
each_answer_many :: proc(src: []u8, as: core.As, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	s := core.services_of(as)
	if s == nil || s.scan == nil {
		return core.error_of(core.Path_Error{kind = .Unsupported})
	}
	return each_answer_with(src, as, paths, state, on, read, allocator, services_build, services_scan)
}

@(private)
each_answer_one :: #force_inline proc(src: []u8, as: core.As, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return each_answer_many(src, as, []core.Path{path}, state, on, read, allocator)
}

each_answer :: proc {each_answer_one, each_answer_many}

// The build and scan of the services of the handle `as`, which `scan_many` and `each_answer_many` read by.
@(private = "file")
services_build :: proc(src: []u8, as: core.As, refuse: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	return core.services_of(as).build(src, as, refuse, allocator)
}

@(private = "file")
services_scan :: proc(src: []u8, as: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
	return core.services_of(as).scan(src, as, paths, read, state, on, allocator)
}

// `scan_many` through the build and scan of the handle `as` given here, which a format of a constant spec passes in place
// of the handle's services, so that the call links the walk of that spec alone.
scan_with :: proc(src: []u8, as: core.As, paths: []core.Path, read: core.Path_Options, allocator: runtime.Allocator, $build_doc: type_of(core.Services{}.build), $scan_doc: type_of(core.Services{}.scan)) -> (core.Document, core.Error) {
	if read.dups == .Refuse {
		built, e := build_doc(src, as, true, allocator)
		doc, err := scan_built(&built, e, paths, read, nil, nil, allocator)
		return doc, core.error_of(err)
	}
	doc, err := scan_doc(src, as, paths, read, nil, nil, allocator)
	return doc, core.error_of(err)
}

// `each_answer_many` through a format's own build and scan, as `scan_with`.
each_answer_with :: proc(src: []u8, as: core.As, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, read: core.Path_Options, allocator: runtime.Allocator, $build_doc: type_of(core.Services{}.build), $scan_doc: type_of(core.Services{}.scan)) -> core.Error {
	if read.dups == .Refuse {
		built, e := build_doc(src, as, true, allocator)
		core.destroy(&built)
		if e.kind != .None {
			return core.error_of(e)
		}
	}
	doc, err := scan_doc(src, as, paths, read, state, on, allocator)
	core.destroy(&doc)
	return core.error_of(err)
}

// Reads the first answer of `path`, as `scan` with a limit of one. A path that gives none, as `.[]` of an empty array,
// answers `.Missing` with `owner` `NO_NODE`.
find :: proc(src: []u8, as: core.As, path: core.Path, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error) {
	doc, err = scan_one(src, as, first_path(path), read, allocator)
	return doc, first_answer(&doc), err
}

// The path a format's `find` reads: `path` with a limit of one.
first_path :: proc(path: core.Path) -> core.Path {
	one := path
	one.limit = min(path.limit.? or_else 1, 1)
	return one
}

// The answer a format's `find` gives from the document its read of `first_path` built.
first_answer :: proc(doc: ^core.Document) -> core.Answer {
	return doc.answers[0] if len(doc.answers) > 0 else {core.NO_NODE, core.NO_NODE, 0, .Missing}
}

// Feeds the step logic the tokens of nodes `from ..< to` by `feed_nodes`. Only the containers on the path open, so `ends`
// holds a frame per step, or one per depth with a `Descend`.
@(private)
replay :: proc "contextless" ($MANY: bool, h: ^Scan, from, to: u32, out: ^core.Hook_Regs, ends: []u32) {
	fed: bool
	when MANY {
		fed = feed_nodes(&h.b.doc, from, to, h, out, ends, replay_step_many, replay_keyed, scan_deepen, false, no_cut, no_resume)
	} else {
		fed = feed_nodes(&h.b.doc, from, to, h, out, ends, replay_step_one, replay_keyed, scan_deepen, false, replay_cut, replay_resume)
	}
	if !fed {
		h.b.err = {kind = .No_Memory}
	}
}

@(private)
replay_step_one :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	h.at = at
	return scan_step(false, .Replay, h, s, t)
}

// The node a container closes at once the element or key its step picks is read: after an `Index` element, and after the
// value of the first key of a `Name` read first-wins. No later sibling can be picked, so none is read.
@(private)
replay_cut :: #force_inline proc "contextless" (h: ^Scan, _: core.Hook_Regs, depth: int, i: u32, t: core.Token, container_end: u32) -> u32 {
	// A depth past the path's steps has no bit set.
	bit := u64(1) << uint(depth - 1)
	if (h.cut_idx | h.cut_names) & bit == 0 {
		return max(u32)
	}
	doc := &h.b.doc
	end := i
	switch {
	case h.cut_idx & bit != 0 && t.role != .Key:
		end += t.n if t.kind > .Plain else 1
	case h.cut_names & bit != 0 && t.role == .Key && h.matched & bit != 0:
		v := doc.nodes[i + 1]
		end += 1 + (v.n if v.kind > .Plain else 1)
	case:
		return max(u32)
	}
	if core.header_of(doc) != 0 || h.cut_end[depth - 1] != 0 || end >= container_end {
		return max(u32)
	}
	h.cut_end[depth - 1] = container_end
	return end
}

// After the container at 0-based depth `k` closes, the node past it when its replay cut it short.
@(private)
replay_resume :: #force_inline proc "contextless" (h: ^Scan, k: int) -> u32 {
	if k >= h.path.n {
		return 0
	}
	#no_bounds_check at := h.cut_end[k]
	h.cut_end[k] = 0
	return at
}

@(private)
replay_step_many :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	h.at = at
	return scan_step(true, .Replay, h, s, t)
}

// The key of the value the registers stand at, when the open container is a headed record: its children so far name it.
@(private)
replay_keyed :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, _, _: core.Node_Index) -> (core.Node_Index, bool) {
	doc := &h.b.doc
	return core.header_of(doc) + 1 + core.Node_Index(u32(s.b)), doc.nodes[s.b >> 32].kind == .Object
}

// The hook a format's `scan` gives its walk.
scan_hook :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return scan_step(false, .Document, h, s, t)
}

// The hook of a `$MANY` read into a document.
scan_hook_many :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return scan_step(true, .Document, h, s, t)
}

// The hook of `each_answer`.
scan_hook_stream :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return many_step(.Stream, h, s, t)
}

// The depths the read's stacks hold: the builder's, and the frames of a `Descend` path, which open at every depth.
scan_room :: #force_inline proc "contextless" (h: ^Scan) -> int {
	if m := h.many; m != nil && m.deeps > 0 {
		return min(len(h.b.stack), len(m.frames) - 2)
	}
	return len(h.b.stack)
}

// Grows the read's stacks by `extra` depths, for a walk about to nest past them. Returns false when the allocator refuses.
scan_deepen :: #force_no_inline proc "contextless" (h: ^Scan, extra: int) -> bool {
	if !builder_deepen(&h.b, extra) {
		return false
	}
	m := h.many
	if m == nil || m.deeps == 0 {
		return true
	}
	context = runtime.default_context()
	allocator := h.b.doc.allocator
	frames, no_frames := make([]Many_Frame, len(m.frames) + extra, allocator)
	deep, no_deep := make([]Deep_Row, len(frames) * m.deeps, allocator)
	if no_frames != nil || no_deep != nil {
		delete(frames, allocator)
		delete(deep, allocator)
		return false
	}
	copy(frames, m.frames)
	copy(deep, m.deep)
	delete(m.frames, allocator)
	delete(m.deep, allocator)
	m.frames, m.deep = frames, deep
	return true
}

// Makes room for `nodes` nodes, for a kept value's walk that tests no capacity. Returns false when the allocator refuses,
// and the value's tokens then come through `scan_hook`.
scan_reserve :: proc "contextless" (h: ^Scan, nodes: int) -> bool {
	if nodes <= len(h.b.doc.nodes) {
		return true
	}
	context = runtime.default_context()
	raw, err := runtime.non_zero_mem_resize(raw_data(h.b.doc.nodes_alloc), len(h.b.doc.nodes_alloc) * size_of(core.Node), nodes * size_of(core.Node), align_of(core.Node), h.b.doc.allocator)
	if err != nil {
		return false
	}
	fresh := ([^]core.Node)(raw_data(raw))[:nodes]
	h.b.doc.nodes = fresh
	h.b.doc.nodes_alloc = fresh
	return true
}

// A kept value's close has passed at depth `d`. Returns whether the walk stops there.
scan_kept :: proc "contextless" (h: ^Scan, d: int) -> bool {
	h.keep = h.free
	h.stopped = scan_known(false, h, &h.path, d)
	return h.stopped
}
