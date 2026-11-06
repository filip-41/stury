package build

import "base:intrinsics"
import "base:runtime"
import spell "../spell"
import core ".."

// The path engine: one step logic that answers paths from any token source, with no format in it. `$MANY` true reads up
// to 64 paths with the state of `many.odin`, and false compiles the same logic down to one path at step `d - 1`, where
// the depth is the step number: a container open at depth `d` reads `steps[d - 1]`, and a value at depth `len(steps)` is
// an answer, kept whole. `$SINK` says where answers go. Whatever no step needs is skipped, so the logic sees the members
// of the containers on the path and nothing else.

// Where the engine sends answers. `.Document` writes the partial document, `.Replay` reads a built one and writes
// nothing, `.Stream` writes nothing and calls `each_answer`'s `on`.
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
// key in the container open at that step, `maps` that the container is a `Map`, and `cut` that the limit dropped a member.
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
	positional: bool, // a `Map`'s members answer an `Index`, as a dsv record's cells do
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
	dups := read.dups.? or_else (core.Duplicates.First if read.stop_early else core.Duplicates.Last)
	h.last = dups == .Last && !read.every_key
	h.every_key = read.every_key
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
		return {kind = .Bad_Path}
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
				return {kind = .Bad_Path}
			}
		case core.Index:
			x.indexed |= bit
		case core.All:
			x.alls |= bit
			x.multi = min(x.multi, i)
			x.indexed |= bit
		case core.Slice:
			x.broad = true
			x.indexed |= bit
			x.multi = min(x.multi, i)
		case core.Descend:
			// One `Descend` tells every answer's route by its depth less its step, and a step is a bit of a `u64`.
			if x.descend >= 0 {
				return {kind = .Bad_Path}
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
	h.b = builder_start(src, as, false, allocator, 64, depth, 0, frames)
	if h.b.err.kind != .None {
		many_free(h, allocator)
		_, be := builder_end(&h.b, BUILDER_REGS, nil)
		return core.path_error(be)
	}
	return {}
}

// Starts the next walk over `src` of a one-path read with a borrowed stack that `scan_end` ended with `again`, with its
// plan and lists, the stack `frames`, and the builder's buffers, which the document that walk returned shares until
// the next `scan_end` writes over it.
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
	doc.positional = h.positional
	if h.again {
		doc.answers, doc.kept, doc.missing = h.answers[:h.n_answers], h.kept[:h.n_kept], h.missing[:h.n_missing]
		return {}
	}
	ok := attach_reads(doc, h.answers[:h.n_answers], h.kept[:h.n_kept], h.missing[:h.n_missing])
	scan_free(h, allocator)
	if !ok {
		core.destroy(doc)
		return {kind = .No_Memory}
	}
	return {}
}

// Copies a read's lists, and the names in `missing`, into one block `doc` owns, so only `src` outlives the read. Returns
// false when the allocation is refused.
@(private)
attach_reads :: proc(doc: ^core.Document, answers: []core.Answer, kept: []core.Kept_Child, missing: []core.Missing_Name) -> bool {
	a := len(answers) * size_of(core.Answer)
	k := a + len(kept) * size_of(core.Kept_Child)
	m := (k + 7) &~ 7
	names := m + len(missing) * size_of(core.Missing_Name)
	size := names
	for x in missing {
		size += len(x.name)
	}
	if size == 0 {
		return true
	}
	block, err := runtime.mem_alloc_non_zeroed(size, 8, doc.allocator)
	if err != nil {
		return false
	}
	doc.reads_block = block
	doc.answers = ([^]core.Answer)(raw_data(block))[:len(answers)]
	doc.kept = ([^]core.Kept_Child)(raw_data(block[a:]))[:len(kept)]
	doc.missing = ([^]core.Missing_Name)(raw_data(block[m:]))[:len(missing)]
	copy(doc.answers, answers)
	copy(doc.kept, kept)
	w := names
	for x, i in missing {
		copy(block[w:], x.name)
		doc.missing[i] = {x.node, string(block[w:w + len(x.name)])}
		w += len(x.name)
	}
	return true
}

// The query `Spelling.query` points at, behind `core.query`.
query :: proc(doc: ^core.Document, paths: []core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Path_Error) {
	if doc.partial {
		return nil, {kind = .Unsupported}
	}
	h: Scan
	h.b.doc = doc^
	h.b.doc.allocator = allocator
	h.positional = doc.shared_keys != 0
	depth := core.reserve_depth(doc.as.max_depth, len(doc.nodes))
	if e := scan_plan(&h, paths, {dups = read.dups, every_key = read.every_key}, depth, false, allocator); e.kind != .None {
		many_free(&h, allocator)
		return nil, e
	}
	regs := BUILDER_REGS
	if h.many == nil {
		stack: [core.MAX_STEPS + 2]u64
		ends: [core.MAX_STEPS + 2]u32
		h.b.stack = stack[:]
		replay(false, &h, 0, u32(len(doc.nodes)), &regs, ends[:])
	} else {
		h.rewalk = replay_rewalk
		no_stack, no_ends: runtime.Allocator_Error
		h.b.stack, no_stack = make([]u64, depth + 2, allocator)
		h.ends, no_ends = make([]u32, depth + 2, allocator)
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

// Writes `text` as the value at every answer of `path` over the built `doc`, and returns the new text. A `Name` the path ends
// in that its container lacks is inserted there. Any other answer that is no value, a mismatch or a missing position or
// parent, is `.Bad_Index`.
set_answers :: proc(doc: ^core.Document, path: core.Path, text: string, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Path_Edit_Error) {
	list := core.edit_list_init(doc, allocator)
	defer core.edit_list_destroy(&list)
	// A `Name` at the end is set through its container, so that a missing name is told from a missing parent.
	read_path := path
	name: core.Name
	named, whole := false, false
	if n := len(path.steps); n > 0 && n - 1 not_in path.optional {
		name, named = path.steps[n - 1].(core.Name)
		// A zero `Step` is left for the read to refuse.
		named &&= raw_data(string(name)) != nil
		// A `Descend` answers in the order its containers close, which is not the order it reaches them, so under a limit
		// the answers of the whole path pick the containers.
		whole = named && path.limit != nil && n > 1 && path.steps[n - 2] == core.Descend{}
		if named && !whole {
			read_path.steps = path.steps[:n - 1]
		}
	}
	answers, qerr := query(doc, []core.Path{read_path}, read, allocator)
	defer delete(answers, allocator)
	if qerr.kind != .None {
		return nil, {kind = .Path, path = qerr}
	}
	for a in answers {
		e := core.Document_Error{kind = .Bad_Index}
		if a.outcome == .Found && (!named || whole) {
			e = core.set(&list, a.node, text)
		} else if (a.outcome == .Found || whole && a.outcome == .Missing) && doc.nodes[a.node].kind == .Map {
			e = set_named(&list, a.node, string(name), text, read)
		}
		if e.kind != .None {
			return nil, {kind = .Edit, edit = e}
		}
	}
	committed, _, e := core.commit(&list, allocator)
	if e.kind != .None {
		return nil, {kind = .Edit, edit = e}
	}
	return committed, {}
}

// Sets the member `name` of `obj`: the one `read.dups` picks, or each of its repeats under `read.every_key`.
@(private = "file")
set_named :: proc(list: ^core.Edit_List, obj: core.Node_Index, name, text: string, read: core.Query_Options) -> core.Document_Error {
	if !read.every_key {
		return core.set_member(list, obj, name, text, read.dups.? or_else .Last)
	}
	found := false
	it := core.members_named(list.doc, obj, name)
	for v in core.member_next(&it) {
		found = true
		if e := core.set(list, v, text); e.kind != .None {
			return e
		}
	}
	return {} if found else core.set_member(list, obj, name, text)
}

// A `$MANY` read's re-walk of the value at node `at` of a built document.
@(private)
replay_rewalk :: proc "contextless" (h: ^Scan, s: ^core.Hook_Regs, lo: u64, at: core.Node_Index) {
	replay(true, h, u32(at), u32(at) + h.b.doc.nodes[at].n, s, h.ends[s.c:])
}

// Answers `paths` over the whole document `doc`, which a read with `refuse_duplicates` built with the error `built`, and
// gives it its answers. On an error `doc` is destroyed, or empty when the build failed.
query_built :: proc(doc: ^core.Document, built: core.Document_Error, paths: []core.Path, read: core.Path_Options) -> (core.Document, core.Path_Error) {
	if built.kind != .None {
		return {}, core.path_error(built)
	}
	answers, e := query(doc, paths, {read.dups, read.every_key}, doc.allocator)
	if e.kind == .None {
		defer delete(answers, doc.allocator)
		if attach_reads(doc, answers, nil, nil) {
			return doc^, {}
		}
		e = {kind = .No_Memory}
	}
	core.destroy(doc)
	return {}, e
}

// Reads `path` over `src` as `as` says, into a partial document holding what the path reached and `Document.answers` in
// text order, through the format's `Spelling.scan`. Everything the walk passes is still judged, unless `read.stop_early`
// ends it. `core.destroy` frees the document, which borrows `src`. With `read.refuse_duplicates` the document holds the
// whole text. A handle with no format's scan is `.Unsupported`.
scan_one :: #force_inline proc(src: []u8, as: core.As, path: core.Path, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Path_Error) {
	return scan_many(src, as, []core.Path{path}, read, allocator)
}

// Reads up to 64 `paths` in one read, as `scan_one`. An answer's `path` is its path's number, and the answers of all the
// paths are in one text order.
scan_many :: proc(src: []u8, as: core.As, paths: []core.Path, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Path_Error) {
	if read.refuse_duplicates {
		built, e := core.build(src, as, true, allocator)
		return query_built(&built, e, paths, read)
	}
	if as.spelling == nil || as.spelling.scan == nil {
		return {}, {kind = .Unsupported}
	}
	return as.spelling.scan(src, as, paths, read, nil, nil, allocator)
}

scan :: proc {scan_one, scan_many}

// Calls `on` with each answer of `path` or `paths` as it becomes known, with no document. `on` returns false to stop the
// read. A found container answers at its close. A repeated key can take an answer back under `.Last`, so an answer
// through a `Name` waits for that `Name`'s container to close there, and `.First` gives each as soon as it is read.
// Answers come in the order they are known, and a path with a `Descend` or a negative index that has a limit gives them
// all at the end. `read.refuse_duplicates` reads the whole text first, so a fault there comes before any answer.
each_answer_many :: proc(src: []u8, as: core.As, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, read := core.Path_Options{}, allocator := context.allocator) -> core.Path_Error {
	if read.refuse_duplicates {
		built, e := core.build(src, as, true, allocator)
		core.destroy(&built)
		if e.kind != .None {
			return core.path_error(e)
		}
	}
	if as.spelling == nil || as.spelling.scan == nil {
		return {kind = .Unsupported}
	}
	doc, err := as.spelling.scan(src, as, paths, read, state, on, allocator)
	core.destroy(&doc)
	return err
}

each_answer_one :: #force_inline proc(src: []u8, as: core.As, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, read := core.Path_Options{}, allocator := context.allocator) -> core.Path_Error {
	return each_answer_many(src, as, []core.Path{path}, state, on, read, allocator)
}

each_answer :: proc {each_answer_one, each_answer_many}

// Reads the first answer of `path`, as `scan` with a limit of one. `answer` is nil when the path gives none, as `.[]` of
// an empty array.
find :: proc(src: []u8, as: core.As, path: core.Path, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: Maybe(core.Answer), err: core.Path_Error) {
	one := path
	one.limit = min(path.limit.? or_else 1, 1)
	doc, err = scan_one(src, as, one, read, allocator)
	if len(doc.answers) > 0 {
		answer = doc.answers[0]
	}
	return
}

// Writes `text` as the value at every answer of `path` over `src`, in one call: a build of the text, one edit per answer
// and a commit. A `Name` the path ends in that its container lacks is inserted after the container's last member. The
// result is the new text, which the caller frees with `allocator`. `refuse_duplicates` is `core.build`'s, and `read`
// picks among a repeated key as `query` does.
set :: proc(src: []u8, as: core.As, path: core.Path, text: string, read := core.Query_Options{}, refuse_duplicates := false, allocator := context.allocator) -> (out: []u8, err: core.Path_Edit_Error) {
	doc, berr := core.build(src, as, refuse_duplicates, allocator)
	defer core.destroy(&doc)
	if berr.kind != .None {
		return nil, {kind = .Edit, edit = berr}
	}
	return set_answers(&doc, path, text, read, allocator)
}

// Feeds the step logic the tokens of nodes `from ..< to` by `feed_nodes`. Only the containers on the path open, so `ends`
// holds a frame per step, or one per depth with a `Descend`.
@(private)
replay :: proc "contextless" ($MANY: bool, h: ^Scan, from, to: u32, out: ^core.Hook_Regs, ends: []u32) {
	when MANY {
		feed_nodes(&h.b.doc, from, to, h, out, ends, replay_step_many, replay_keyed, false)
	} else {
		feed_nodes(&h.b.doc, from, to, h, out, ends, replay_step_one, replay_keyed, false)
	}
}

@(private)
replay_step_one :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	h.at = at
	return scan_step(false, .Replay, h, s, t)
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
	return doc.shared_keys + 1 + core.Node_Index(u32(s.b)), doc.nodes[s.b >> 32].kind == .Map
}

// The hook a format's `scan` gives its walk.
scan_hook :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return scan_step(false, .Document, h, s, t)
}

// The step logic.
@(private)
scan_step :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	s := s
	if t.role > .Key {
		return s, .Next
	}
	d := int(s.c)
	when SINK != .Replay {
		if d > h.keep {
			return scan_inside(MANY, SINK, h, s, t)
		}
	}
	if t.kind == .End {
		return scan_close(MANY, SINK, h, s, t)
	}
	when MANY {
		m := h.many
		#no_bounds_check f := &m.frames[d]
	} else {
		f: ^Many_Frame
	}
	if t.role == .Key {
		when MANY {
			if f.delay {
				s = many_delayed(SINK, h, s, f, d)
				if h.stopped {
					return s, .Stop
				}
			}
			m.key = t
			m.key_at = h.at
			m.has_key = true
		}
		wanted: bool
		s, wanted = scan_picks(MANY, SINK, h, s, t, f, d, true)
		if scan_skips(MANY, h, f, wanted) {
			return scan_pass(MANY, h, s)
		}
		// With several paths a key waits for its value, which they may yet all refuse.
		when MANY {
			return s, .Next
		} else {
			h.next = 1
			return scan_write(SINK == .Document, h, s, t)
		}
	}
	when MANY {
		if m.feeding {
			m.feeding = false
			return scan_reach(true, SINK, h, s, t, f, d)
		}
		if !m.has_key && f.delay {
			s = many_delayed(SINK, h, s, f, d)
			if h.stopped {
				return s, .Stop
			}
		}
		if f.ring_k != 0 {
			i := u32(s.b) % f.ring_k
			#no_bounds_check m.rings[f.ring + i] = {m.key if m.has_key else {}, t, m.key_at, h.at}
		}
		element := d > 0 && !m.has_key
	} else {
		element := d > 0 && h.maps >> uint(d - 1) & 1 == 0
	}
	wanted: bool
	if element {
		s, wanted = scan_picks(MANY, SINK, h, s, t, f, d, false)
	} else {
		wanted = h.next != 0
	}
	if scan_skips(MANY, h, f, wanted) {
		return scan_pass(MANY, h, s)
	}
	return scan_reach(MANY, SINK, h, s, t, f, d)
}

// Whether the coming value goes unread: one path did not want it, or nothing of several picked or holds it.
@(private)
scan_skips :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, f: ^Many_Frame, wanted: bool) -> bool {
	when MANY {
		return h.next == 0 && !f.whole && f.ring_k == 0
	} else {
		return !wanted
	}
}

@(private)
scan_pass :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, s: core.Hook_Regs) -> (core.Hook_Regs, core.Action) {
	s := s
	s.b += 1
	when MANY {
		h.many.has_key = false
	}
	return s, .Skip
}

// A token inside a value kept whole, in which no path is armed.
@(private)
scan_inside :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	s := s
	action := core.Action.Next
	when SINK == .Document {
		s, action = builder_step(false, true, false, false, &h.b, s, t)
	} else {
		if t.kind == .End {
			s.c -= 1
			#no_bounds_check s.b = h.b.stack[s.c]
		} else {
			s, action = scan_write(false, h, s, t)
		}
	}
	// Only a close can bring the depth back.
	if t.kind == .End && int(s.c) == h.keep {
		d := h.keep
		h.keep = h.free
		when MANY {
			m := h.many
			many_found(SINK, h, m.keep_found, m.keep_open, t.lo + u64(t.n), d)
			return scan_left(true, SINK, h, s, m.keep_set, d)
		} else {
			return scan_left(false, SINK, h, s, 0, d)
		}
	}
	return s, action
}

// Whether path `path` is past answering with the logic at depth `d`, so a read that stops early need not wait for it.
@(private)
scan_known :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, path: ^Scan_Path, d: int) -> bool {
	return h.stop_early && (d <= path.multi || !scan_fits(MANY, h, path) && d <= path.rollback)
}

// A value or container is past for the paths in `set`, with the logic at depth `d`: a path that can answer no more is
// done, and a read that stops early stops when all are.
@(private)
scan_left :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, set: u64, d: int) -> (core.Hook_Regs, core.Action) {
	when MANY {
		m := h.many
		when SINK == .Stream {
			if d <= h.flush {
				many_flush(h)
			}
		}
		if h.stop_early && !h.stopped {
			for rest := set &~ m.done; rest != 0; rest &= rest - 1 {
				p := intrinsics.count_trailing_zeros(rest)
				#no_bounds_check if scan_known(true, h, &m.paths[p], d) {
					m.done |= 1 << p
				}
			}
			if m.done == m.all {
				h.stopped = true
			}
		}
		return s, .Stop if h.stopped else .Next
	} else {
		if scan_known(false, h, &h.path, d) {
			h.stopped = true
			return s, .Stop
		}
		return s, .Next
	}
}

// Whether a path has room for another answer. The limit counts answers, which only a repeated key can take back.
@(private)
scan_fits :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, path: ^Scan_Path) -> bool {
	when MANY {
		return path.late || path.count < path.limit
	} else {
		return h.n_answers < path.limit
	}
}

// Writes a key, a scalar or an open token. With `$WRITE` false only the open's frame is kept.
@(private)
scan_write :: #force_inline proc "contextless" ($WRITE: bool, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	when WRITE {
		return builder_step(false, true, false, false, &h.b, s, t)
	} else {
		s := s
		if t.role == .Value {
			s.b += 1
			if t.kind > .Plain {
				#no_bounds_check h.b.stack[s.c] = s.b
				s.c += 1
				s.b = u64(h.at) << 32
			}
		}
		return s, .Next
	}
}

// Runs the step of every armed path over a key or an element. `wanted` is one path's answer, which `Scan.next` holds for
// several.
@(private)
scan_picks :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, d: int, keyed: bool) -> (regs: core.Hook_Regs, wanted: bool) {
	s := s
	when MANY {
		m := h.many
		for set := f.armed; set != 0; set &= set - 1 {
			p := uint(intrinsics.count_trailing_zeros(set))
			#no_bounds_check path := &m.paths[p]
			if path.deep < 0 {
				s, _ = scan_pick(true, SINK, h, s, t, f, path, p, d - 1, d, keyed)
			} else {
				#no_bounds_check row := &m.deep[d * m.deeps + path.deep]
				for bits := row.live; bits != 0; bits &= bits - 1 {
					s, _ = scan_pick(true, SINK, h, s, t, f, path, p, int(intrinsics.count_trailing_zeros(bits)), d, keyed)
				}
			}
		}
		return s, false
	} else {
		return scan_pick(false, SINK, h, s, t, f, &h.path, 0, d - 1, d, keyed)
	}
}

// Runs step `k` of path `p`, live in the container at depth `d`, over a key or an element.
@(private)
scan_pick :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, path: ^Scan_Path, p: uint, k, d: int, keyed: bool) -> (core.Hook_Regs, bool) {
	#no_bounds_check switch x in path.steps[k] {
	case core.Name:
		if keyed {
			return scan_name(MANY, SINK, h, s, t, f, path, p, k, d, string(x))
		}
	case core.Index_Or_Name:
		if keyed {
			return scan_name(MANY, SINK, h, s, t, f, path, p, k, d, x.name)
		}
		if int(u32(s.b)) == x.index {
			scan_picked(MANY, h, path, p, k, true)
			return s, true
		}
	case core.Index:
		if int(u32(s.b)) == int(x) {
			scan_picked(MANY, h, path, p, k, true)
			return s, true
		}
	case core.All:
		if scan_fits(MANY, h, path) {
			scan_picked(MANY, h, path, p, k, true)
			return s, true
		}
		h.cut |= 1 << uint(k)
	case core.Slice:
		when MANY {
			count := int(u32(s.b))
			if path.negative >> uint(k) & 1 == 0 && count >= x.lo && count < (x.hi.? or_else max(int)) {
				scan_picked(MANY, h, path, p, k, true)
			}
		}
	case core.Descend:
		when MANY {
			h.next |= 1 << p
			#no_bounds_check h.many.next_deep[path.deep] |= 1 << uint(k)
		}
	}
	return s, false
}

// Marks that path `p` picked the coming value at step `k`. `by_place` says it was by position, and such a child keeps a
// `Kept_Child`, where one matched by name has none.
@(private)
scan_picked :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, path: ^Scan_Path, p: uint, k: int, by_place: bool) {
	when MANY {
		h.next |= 1 << p
		m := h.many
		if path.deep >= 0 {
			#no_bounds_check m.next_deep[path.deep] |= 2 << uint(k)
		}
		if by_place && path.indexed >> uint(k) & 1 != 0 {
			m.indexed = true
		}
	}
}

// Tests a `Name` step against a key. Under `.Last` a later match takes back what the earlier one answered: one path
// rewinds the lists and the nodes, and with several the nodes stay in the document with no answer naming them.
@(private)
scan_name :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, path: ^Scan_Path, p: uint, k, d: int, name: string) -> (core.Hook_Regs, bool) {
	s := s
	when MANY {
		m := h.many
		matched := &f.matched
		bit := u64(1) << p
		if path.deep >= 0 {
			#no_bounds_check matched = &m.deep[d * m.deeps + path.deep].matched
			bit = 1 << uint(k)
		}
	} else {
		matched := &h.matched
		bit := u64(1) << uint(k)
	}
	seen := matched^ & bit != 0
	if seen && !h.last && !h.every_key || !scan_key_is(SINK != .Replay, h, s, t, name) {
		return s, false
	}
	when MANY {
		if seen && h.last {
			many_take_back(m, f, path, p, k, d)
		}
		#no_bounds_check m.marks[path.marks + k] = m.n_placed
	} else {
		#no_bounds_check mark := &h.marks[k]
		if seen {
			h.n_answers = mark.answers
			when SINK == .Document {
				s.a = mark.a
				h.b.n_counts = mark.counts
				h.n_kept = mark.kept
				h.n_missing = mark.missing
			}
		} else {
			mark^ = {s.a, h.n_answers, h.b.n_counts, h.n_kept, h.n_missing}
		}
	}
	matched^ |= bit
	scan_picked(MANY, h, path, p, k, false)
	return s, true
}

// Whether key token `t` reads as `name`: its bytes, unless it holds something to decode.
@(private)
scan_key_is :: #force_inline proc "contextless" ($WRITE: bool, h: ^Scan, s: core.Hook_Regs, t: core.Token, name: string) -> bool {
	if t.spelling & core.SPELLING_DECODE == 0 {
		#no_bounds_check return int(t.n) == len(name) && spell.bytes_equal(h.b.doc.src[t.lo:t.lo + u64(t.n)], transmute([]u8)name)
	}
	when WRITE {
		return scan_key_decoded(h, int(s.a), t, name)
	} else {
		return core.key_equals(&h.b.doc, h.at, name)
	}
}

// Reads a key through the format's `key_equals`, which reads a node, so the token goes in the next node's slot.
@(private, cold)
scan_key_decoded :: #force_no_inline proc "contextless" (h: ^Scan, a: int, t: core.Token, name: string) -> bool {
	if a == len(h.b.doc.nodes) {
		builder_grow(&h.b)
		if a == len(h.b.doc.nodes) {
			return false
		}
	}
	h.b.doc.nodes[a] = t
	return core.key_equals(&h.b.doc, core.Node_Index(a), name)
}

// Gives an answer to the read's list. With several paths it waits among the placed ones for its place in the text. One
// path's steps stop picking at the limit, so only its close has to ask.
@(private)
scan_answer :: #force_inline proc "contextless" ($MANY: bool, h: ^Scan, path: ^Scan_Path, p: uint, a: core.Answer, pos: u64, t: core.Token, hi: u64, chain: int) {
	when MANY {
		if !scan_fits(MANY, h, path) {
			return
		}
		path.count += 1
		a := a
		a.path = u32(p)
		m := h.many
		scan_push(h, &m.placed, &m.n_placed, Placed{pos, a, t, hi, u32(chain)})
	} else {
		scan_push(h, &h.answers, &h.n_answers, a)
	}
}

// A step the value cannot take, or a member the close found missing, with `later` the steps past it. `?` drops a
// mismatch, and on a null or a missing member the mismatch belongs to the first `All` to come, as jq's `null[]`.
@(private)
scan_miss :: #force_inline proc "contextless" (path: ^Scan_Path, k: int, later: u64, is_null: bool) -> (outcome: core.Answer_Outcome, dropped: bool) {
	if is_null && later == 0 {
		return .Missing, false
	}
	at := k + int(intrinsics.count_trailing_zeros(later)) if is_null else k
	return .Type_Mismatch, path.optional >> uint(at) & 1 != 0
}

// Path `p` reached a value at step `k`: the path's end, a container the next step enters, or a value it cannot. Returns
// whether the path goes on inside it.
@(private)
scan_arrive :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, path: ^Scan_Path, p: uint, k, d: int, t: core.Token, at, owner: core.Node_Index, pos: u64) -> bool {
	if k == path.n {
		when MANY {
			m := h.many
			m.keep = true
			m.ended |= 1 << p
			when SINK == .Stream {
				if t.kind > .Plain {
					m.found |= 1 << p
					return false
				}
			}
		}
		scan_answer(MANY, h, path, p, core.Answer{node = at, owner = owner}, pos, t, t.lo + u64(t.n), d - k)
		return false
	}
	if scan_enters(h, path, k, t.kind) {
		return true
	}
	outcome, dropped := scan_miss(path, k, path.alls >> uint(k), t.kind == .Null)
	when MANY {
		h.many.ended |= 1 << p
	}
	if dropped {
		return false
	}
	// jq reads every step but `[]` of a null as null.
	holder := at if outcome == .Type_Mismatch || owner == core.NO_NODE else owner
	scan_answer(MANY, h, path, p, core.Answer{node = core.NO_NODE, owner = holder, outcome = outcome}, pos, t, t.lo + u64(t.n), d - k)
	when MANY {
		h.many.keep = true
	}
	return false
}

// A value the paths have reached: each answers, fails or goes on inside it.
@(private)
scan_reach :: proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, f: ^Many_Frame, d: int) -> (core.Hook_Regs, core.Action) {
	WRITE :: SINK == .Document
	s := s
	at := h.at
	when WRITE {
		at = core.Node_Index(s.a)
	}
	owner := core.Node_Index(s.b >> 32)
	when MANY {
		m := h.many
		when WRITE {
			if m.has_key {
				at += 1
			}
		}
		pos := u64(at) << 32 when SINK == .Replay else 2 * t.lo
		child := many_arrivals(SINK, h, t, d, at, owner, pos)
		enter := child != 0
		ended := m.ended
		has_key, keeps_place := m.has_key, m.indexed
		m.indexed = false
		m.has_key = false
		whole := f.whole || m.keep && WRITE
		if !enter && !m.keep && !whole {
			s.b += 1
			return s, .Skip
		}
		if WRITE && has_key {
			s, _ = scan_write(WRITE, h, s, m.key)
		}
		if WRITE {
			f.kept += 1
		}
	} else {
		h.next = 0
		keeps_place := false
		if WRITE && d > 0 && (h.path.indexed &~ h.matched) >> uint(d - 1) & 1 != 0 {
			scan_push(h, &h.kept, &h.n_kept, core.Kept_Child{at, u32(s.b)})
		}
		enter := scan_arrive(false, SINK, h, &h.path, 0, d, d, t, at, owner, 0)
		ended := u64(0)
	}
	if WRITE && keeps_place {
		scan_push(h, &h.kept, &h.n_kept, core.Kept_Child{at, u32(s.b)})
	}
	if !enter {
		return scan_past(MANY, SINK, h, s, t, ended, d)
	}
	s, _ = scan_write(WRITE, h, s, t)
	when MANY {
		g := &m.frames[d + 1]
		g^ = {armed = child, ends = ended, found = m.found, open = t, open_pos = pos, whole = whole, is_map = t.kind == .Map, ring = m.ring_top}
		m.found = 0
		many_ring_open(h, g, d + 1)
	} else {
		bit := u64(1) << uint(d)
		h.matched &~= bit
		h.cut &~= bit
		h.maps = h.maps | bit if t.kind == .Map else h.maps &~ bit
	}
	when WRITE {
		when MANY {
			g.slot = u32(h.b.n_counts)
		} else {
			#no_bounds_check h.slots[d] = u32(h.b.n_counts)
		}
		scan_push(h, &h.b.doc.counts_alloc, &h.b.n_counts, core.Child_Count{node = at})
	}
	return s, .Next
}

// Goes on past a value kept whole, the paths in `set` done with it. With `.Replay` it is stepped over, since its nodes are
// already held.
@(private)
scan_past :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token, set: u64, d: int) -> (core.Hook_Regs, core.Action) {
	s := s
	when SINK == .Replay {
		s.b += 1
		left, action := scan_left(MANY, SINK, h, s, set, d)
		return left, .Stop if action == .Stop else .Skip
	} else {
		when SINK == .Stream {
			if t.kind > .Plain && !h.many.keep {
				s.b += 1
				return s, .Skip
			}
		}
		action: core.Action
		s, action = scan_write(SINK == .Document, h, s, t)
		if action != .Next {
			return s, action
		}
		if t.kind <= .Plain {
			return scan_left(MANY, SINK, h, s, set, d)
		}
		h.keep = d
		when MANY {
			m := h.many
			m.keep_set = set
			m.keep_found, m.keep_open = m.found, t
			m.found = 0
			return s, .Next
		} else {
			return s, .Keep
		}
	}
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

// Whether step `k` of a path can enter a value of `kind`.
@(private)
scan_enters :: #force_inline proc "contextless" (h: ^Scan, path: ^Scan_Path, k: int, kind: core.Kind) -> bool {
	#no_bounds_check switch _ in path.steps[k] {
	case core.Name:
		return kind == .Map
	case core.Index, core.Slice:
		return kind == .Array || kind == .Map && h.positional
	case core.All, core.Index_Or_Name, core.Descend:
		return kind == .Array || kind == .Map
	}
	return false
}

// A `Name` that met no key and an `Index` past either end answer at the close, since only the close knows. Returns whether
// the step missed.
@(private)
scan_missed :: #force_inline proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, f: ^Many_Frame, path: ^Scan_Path, p: uint, k: int, seen: bool, count: int, open: core.Node_Index, pos: u64, t: core.Token, d: int) -> bool {
	miss, named := false, false
	name: string
	#no_bounds_check #partial switch x in path.steps[k] {
	case core.Name:
		miss, named, name = !seen, true, string(x)
	case core.Index:
		miss = int(x) >= count || count + int(x) < 0
	case core.Index_Or_Name:
		when MANY {
			named = f.is_map
		} else {
			named = h.maps >> uint(k) & 1 != 0
		}
		name = x.name
		miss = !seen if named else x.index >= count
	}
	if !miss {
		return false
	}
	outcome, dropped := scan_miss(path, k + 1, path.alls >> uint(k + 1), true)
	if !dropped && scan_fits(MANY, h, path) {
		scan_answer(MANY, h, path, p, core.Answer{node = core.NO_NODE, owner = open, outcome = outcome}, pos, t, t.lo + u64(t.n), d - k - 1)
	}
	when SINK == .Document {
		if named {
			scan_push(h, &h.missing, &h.n_missing, core.Missing_Name{open, name})
		}
	}
	return true
}

// A path container closes, and its true count is known.
@(private)
scan_close :: proc "contextless" ($MANY: bool, $SINK: Sink, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	s := s
	d := int(s.c)
	count := int(u32(s.b))
	when MANY {
		m := h.many
		#no_bounds_check f := &m.frames[d]
		s = many_close_ring(SINK, h, s, f, d, count)
		if h.stopped {
			return s, .Stop
		}
		many_misses(SINK, h, s, t, f, d, count)
		whole := int(f.kept) == count
		slot := f.slot
	} else {
		bit := u64(1) << uint(d - 1)
		miss := scan_missed(false, SINK, h, nil, &h.path, 0, d - 1, h.matched & bit != 0, count, core.Node_Index(s.b >> 32), 0, t, d)
		kept := count if h.path.alls & bit != 0 else (0 if miss else 1)
		whole := h.cut & bit == 0 && kept == count
		#no_bounds_check slot := h.slots[d - 1]
	}
	if SINK == .Document && h.b.err.kind == .None {
		if whole {
			builder_close_node(&h.b, int(s.a), core.Node_Index(s.b >> 32), u32(count))
			h.b.doc.counts_alloc[slot].node = core.NO_NODE
		} else {
			scan_partial(h, s, slot)
		}
	}
	s.c -= 1
	#no_bounds_check s.b = h.b.stack[s.c]
	when MANY {
		m.ring_top = f.ring
		many_found(SINK, h, f.found, f.open, t.lo + u64(t.n), d - 1)
		return scan_left(true, SINK, h, s, f.armed | f.ends, d - 1)
	} else {
		return scan_left(false, SINK, h, s, 0, d - 1)
	}
}

// Closes the open container of `s` as `Partial`, its true count in its slot.
@(private)
scan_partial :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, slot: u32) {
	open := core.Node_Index(s.b >> 32)
	#no_bounds_check {
		n := &h.b.doc.nodes[open]
		n.n = u32(int(s.a) - int(open))
		n.spelling = core.MAX_CHILDREN
		n.role = .Partial
		h.b.doc.counts_alloc[slot].count = u32(s.b)
	}
}

// Doubles a list of a read. Answers leave `first` for the allocator, and `first` stays with the `Scan`.
@(private, cold)
scan_grow :: #force_no_inline proc "contextless" (h: ^Scan, list: []$T) -> ([]T, bool) {
	when T == core.Answer {
		if raw_data(list) == &h.first[0] {
			fresh, ok := grow(h.b.doc.allocator, ([]T)(nil), 2 * len(list))
			if ok {
				copy(fresh, list)
			}
			return fresh, ok
		}
	}
	return grow(h.b.doc.allocator, list, 8)
}

// Appends `v` to a list of a read. A refused growth is held in the builder's error, which ends the read, and drops `v`.
@(private)
scan_push :: #force_inline proc "contextless" (h: ^Scan, list: ^[]$T, n: ^int, v: T) {
	if n^ == len(list^) {
		fresh, ok := scan_grow(h, list^)
		if !ok {
			if h.b.err.kind == .None {
				h.b.err = {kind = .No_Memory}
			}
			return
		}
		list^ = fresh
	}
	#no_bounds_check list[n^] = v
	n^ += 1
}
