package build

import "base:runtime"
import spell "../spell"
import core ".."

// The path engine: one step logic that answers a path from any token source, with no format in it, and its `$MANY` form
// in `many.odin` for what this form has no state for. `scan_hook` runs it
// on a walk and writes the partial document, and `query_document` runs it on a built document's tokens. With no `Descend`
// step the depth is the step number: a container open at depth `d` reads `steps[d - 1]`, and a value at depth
// `len(steps)` is an answer, kept whole. Whatever no step needs is skipped, so the logic sees the members of the
// containers on the path and nothing else.

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
// The `u64` sets hold a bit per step. `matched` says a `Name` has met its key in the container open at that step, `maps`
// that the container is a `Map`, `cut` that the limit dropped a member, `alls` that the step is `All`, and `indexed` that
// the step keeps a `Kept_Child` for each child it keeps by position.
Scan :: struct {
	b:          Builder,
	steps:      []core.Step,
	n:          int, // the step count
	keep:       int, // the depth at and past which every token is kept: `n`, or the depth of a value no step can enter
	limit:      int, // the most answers
	multi:      int, // the first step that can answer again, `n` for none
	rollback:   int, // the first step a repeated key can take answers back through, `n` for none
	matched:    u64,
	maps:       u64,
	cut:        u64,
	alls:       u64,
	indexed:    u64,
	want:       bool, // the next value is wanted, as its key was
	last:       bool, // a repeated key replaces the candidate
	stop_early: bool,
	stopped:    bool,
	borrowed:   bool, // the builder's stack is the caller's `frames`
	positional: bool, // a `Map`'s members answer an `Index`, as a dsv record's cells do
	at:         core.Node_Index, // the node `query_document` is giving the logic
	answers:    []core.Answer,
	n_answers:  int,
	kept:       []core.Kept_Child,
	n_kept:     int,
	missing:    []core.Missing_Name,
	n_missing:  int,
	many:       ^Scan_Many, // the `$MANY` form's state, nil in this form
	rewalk:     Rewalk,
	opts:       rawptr, // the format's walk options, which `rewalk` reads
	ends:       []u32, // the container ends a `$MANY` replay holds, a frame per depth
	marks:      [core.MAX_STEPS]Scan_Mark,
	slots:      [core.MAX_STEPS]u32, // the `Child_Count` reserved for the container open at each depth
	first:      [8]core.Answer, // `answers` until they outgrow it, so a read of few allocates no list
}

// Gives one value of a text to the `$MANY` form's hook again from the value's first byte, `at` being its node in a
// built document. A format's `query` sets it, since only a format can walk from a value.
Rewalk :: proc "contextless" (h: ^Scan, s: ^core.Hook_Regs, lo: u64, at: core.Node_Index)

// Reads `path` and `read` into `h`, for a path `many_needed` says this form can read.
@(private)
scan_plan :: proc(h: ^Scan, path: core.Path, read: core.Path_Options) -> core.Path_Error {
	if len(path.steps) > core.MAX_STEPS {
		return {kind = .Over_Capacity}
	}
	dups := read.dups.? or_else (core.Duplicates.First if read.stop_early else core.Duplicates.Last)
	h.steps = path.steps
	h.n = len(path.steps)
	h.keep = h.n
	h.limit = path.limit.? or_else max(int)
	h.multi = h.n
	h.rollback = h.n
	h.last = dups == .Last
	h.stop_early = read.stop_early
	h.want = h.limit > 0
	for step, i in path.steps {
		bit := u64(1) << uint(i)
		switch x in step {
		case core.Name, core.Either:
			if h.last {
				h.multi = min(h.multi, i)
				h.rollback = min(h.rollback, i)
			}
			if _, either := x.(core.Either); either {
				h.indexed |= bit
			}
		case core.Index:
			h.indexed |= bit
		case core.All:
			h.alls |= bit
			h.multi = min(h.multi, i)
			if h.limit != max(int) {
				h.indexed |= bit
			}
		case core.Slice, core.Descend:
		}
	}
	return {}
}

// Starts a scan of `paths` over `src`. `depth` is as in `builder_start`, `frames` is the caller's room for that stack,
// which `depth` may outgrow, and a format's `query` runs its walk with `scan_hook`, or `many_hook` when `Scan.many` is
// set, and ends it with `scan_end`. `many` asks for the `$MANY` form.
scan_start :: proc(h: ^Scan, src: []u8, spelling: ^core.Spelling, paths: []core.Path, read: core.Path_Options, positional: bool, allocator: runtime.Allocator, depth: int, frames: []u64, many := false, state: rawptr = nil, on: proc(state: rawptr, a: core.Token_Answer) -> bool = nil) -> core.Path_Error {
	e: core.Path_Error
	if many || many_needed(paths, read) {
		e = many_plan(h, paths, read, depth, allocator)
	} else {
		e = scan_plan(h, paths[0], read)
	}
	if e.kind != .None {
		many_free(h, allocator)
		return e
	}
	if h.many != nil {
		h.many.on, h.many.state, h.many.ctx = on, state, context
	}
	h.positional = positional
	h.answers = h.first[:]
	h.borrowed = depth <= len(frames)
	h.b = builder_start(src, spelling, false, allocator, 64, 0 if h.borrowed else depth)
	if h.borrowed {
		h.b.stack = frames[:depth]
	}
	if h.b.err.kind != .None {
		if h.borrowed {
			h.b.stack = nil
		}
		many_free(h, allocator)
		_, be := builder_end(&h.b, BUILDER_REGS, nil)
		return core.path_error(be)
	}
	return {}
}

// Returns the partial document the walk built, its answers in text order, or the error that stopped it. `root_close` is
// the root's end when the walk gives one, else 0. On an error every allocation is freed.
scan_end :: proc(h: ^Scan, regs: core.Hook_Regs, root_close: u64, fault: Maybe(core.Fault)) -> (core.Document, core.Path_Error) {
	regs := regs
	allocator := h.b.doc.allocator
	free_lists :: proc(h: ^Scan, allocator: runtime.Allocator) {
		if raw_data(h.answers) != &h.first[0] {
			delete(h.answers, allocator)
		}
		delete(h.kept, allocator)
		delete(h.missing, allocator)
		many_free(h, allocator)
	}
	if _, bad := fault.?; !bad && h.stopped && h.b.err.kind == .None {
		// The containers the stop left open are on the path. Their counts hold what was read of them.
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
		if h.many.on != nil {
			many_stream_end(h)
		} else {
			many_answers(h)
		}
	}
	h.b.wide_more = h.b.wide_count != 0
	h.b.root_close = 0 if h.stopped else root_close
	if h.borrowed {
		h.b.stack = nil
	}
	doc, e := builder_end(&h.b, regs, fault)
	if e.kind != .None {
		free_lists(h, allocator)
		return {}, core.path_error(e)
	}
	doc.partial = true
	doc.stopped = h.stopped
	ok := attach_reads(&doc, h.answers[:h.n_answers], h.kept[:h.n_kept], h.missing[:h.n_missing])
	free_lists(h, allocator)
	if !ok {
		core.destroy(&doc)
		return {}, {kind = .No_Memory}
	}
	return doc, {}
}

// Copies a read's lists into one block `doc` owns. Returns false when the allocation is refused.
attach_reads :: proc(doc: ^core.Document, answers: []core.Answer, kept: []core.Kept_Child, missing: []core.Missing_Name) -> bool {
	a := len(answers) * size_of(core.Answer)
	k := a + len(kept) * size_of(core.Kept_Child)
	m := (k + 7) &~ 7
	size := m + len(missing) * size_of(core.Missing_Name)
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
	copy(doc.missing, missing)
	return true
}

// Answers `path` over a document built whole, in the order a scan of its text answers, and allocates nothing but the
// list, which the caller frees with `delete(answers, allocator)`. A partial document cannot say what it does not hold,
// so it is `.Unsupported`. An `Answer`'s nodes are `doc`'s.
query_document_one :: proc(doc: ^core.Document, path: core.Path, read := core.Path_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Path_Error) {
	paths := [1]core.Path{path}
	return query_document_many(doc, paths[:], read, allocator)
}

// Answers `paths` over a document built whole, as `query_document_one`, each answer tagged with its path's number.
query_document_many :: proc(doc: ^core.Document, paths: []core.Path, read := core.Path_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Path_Error) {
	if doc.partial {
		return nil, {kind = .Unsupported}
	}
	h: Scan
	h.b.doc = doc^
	h.b.doc.allocator = allocator
	h.positional = doc.shared_keys != 0
	regs := BUILDER_REGS
	if !many_needed(paths, read) {
		if e := scan_plan(&h, paths[0], read); e.kind != .None {
			return nil, e
		}
		stack: [core.MAX_STEPS + 2]u64
		ends: [core.MAX_STEPS + 2]u32
		h.b.stack = stack[:]
		replay(false, &h, 0, u32(len(doc.nodes)), &regs, ends[:])
	} else {
		depth := max(core.MAX_DEPTH, int(doc.read.max_depth))
		if e := many_plan(&h, paths, read, depth, allocator); e.kind != .None {
			many_free(&h, allocator)
			return nil, e
		}
		h.rewalk = replay_rewalk
		h.b.stack = make([]u64, depth + 2, allocator)
		h.ends = make([]u32, depth + 2, allocator)
		replay(true, &h, 0, u32(len(doc.nodes)), &regs, h.ends)
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

query_document :: proc {query_document_one, query_document_many}

// Writes `text` as the value at every answer of `doc`, a read of `path`, and returns the new text. A `Name` the path ends
// in that its container lacks is inserted there. Any other answer that is no value, a mismatch or a missing position or
// parent, is `.Bad_Index`.
set_answers :: proc(doc: ^core.Document, path: core.Path, text: string, allocator := context.allocator) -> (out: []u8, err: core.Path_Edit_Error) {
	list := core.edit_list_init(doc, allocator)
	defer core.edit_list_destroy(&list)
	name: core.Name
	named := false
	if len(path.steps) > 0 {
		name, named = path.steps[len(path.steps) - 1].(core.Name)
	}
	for a in doc.answers {
		e := core.Document_Error{kind = .Bad_Index}
		if a.outcome == .Found {
			e = core.set(&list, a.node, text)
		} else if a.outcome == .Missing && named {
			e = core.set_member(&list, a.owner, string(name), text)
		}
		if e.kind != .None {
			return nil, e
		}
	}
	committed, _, e := core.commit(&list, allocator)
	if e.kind != .None {
		return nil, e
	}
	return committed, nil
}

// A `$MANY` read's re-walk of the value at node `at` of a built document.
@(private)
replay_rewalk :: proc "contextless" (h: ^Scan, s: ^core.Hook_Regs, lo: u64, at: core.Node_Index) {
	replay(true, h, u32(at), u32(at) + h.b.doc.nodes[at].n, s, h.ends[s.c:])
}

// Answers `paths` over the whole document `doc`, which a read with `refuse_duplicates` built, and gives it its answers. On
// an error `doc` is destroyed.
query_built :: proc(doc: ^core.Document, paths: []core.Path, read: core.Path_Options) -> (core.Document, core.Path_Error) {
	answers, e := query_document_many(doc, paths, read, doc.allocator)
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

// Feeds the step logic the tokens of nodes `from ..< to` as the walk gave them: each close comes back from a stack of
// container ends, and each key of a headed record from `doc.shared_keys`, and a `Skip` steps over the value's subtree.
// Only the containers on the path open, so `ends` holds a frame per step, or one per depth with a `Descend`.
@(private)
replay :: proc "contextless" ($MANY: bool, h: ^Scan, from, to: u32, out: ^core.Hook_Regs, ends: []u32) {
	doc := &h.b.doc
	regs := out^
	defer out^ = regs
	depth := 0
	i := from
	action: core.Action
	for {
		for depth > 0 && i >= ends[depth - 1] {
			depth -= 1
			when MANY {
				regs, action = many_step(.Replay, h, regs, core.Token{kind = .End, lo = u64(ends[depth]) - 1})
			} else {
				regs, action = scan_step(false, h, regs, core.Token{kind = .End})
			}
			if action == .Stop {
				return
			}
		}
		if i >= to {
			return
		}
		t := doc.nodes[i]
		// The header row is the root's first child, and the walk gives its cells as each record's keys.
		if t.role == .Key && t.kind == .Array {
			i += t.n
			continue
		}
		if doc.shared_keys != 0 && depth > 0 && doc.nodes[regs.b >> 32].kind == .Map {
			h.at = doc.shared_keys + 1 + core.Node_Index(u32(regs.b))
			when MANY {
				regs, action = many_step(.Replay, h, regs, doc.nodes[h.at])
			} else {
				regs, action = scan_step(false, h, regs, doc.nodes[h.at])
			}
			if action == .Skip {
				i += t.n if t.kind > .Plain else 1
				continue
			}
		}
		h.at = core.Node_Index(i)
		when MANY {
			regs, action = many_step(.Replay, h, regs, t)
		} else {
			regs, action = scan_step(false, h, regs, t)
		}
		switch action {
		case .Stop:
			return
		case .Skip:
			// A key passed over takes its value with it.
			if t.role == .Key {
				i += 1
				t = doc.nodes[i]
			}
			i += t.n if t.kind > .Plain else 1
		case .Next, .Keep:
			if t.kind > .Plain {
				ends[depth] = i + t.n
				depth += 1
			}
			i += 1
		}
	}
}

// The hook a format's `query` gives its walk.
scan_hook :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return scan_step(true, h, s, t)
}

// The step logic. `$WRITE` writes the kept tokens to the builder, and false writes nothing, for `query_document`, whose
// answers name the nodes it reads.
@(private)
scan_step :: #force_inline proc "contextless" ($WRITE: bool, h: ^Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	s := s
	if t.role > .Key {
		return s, .Next
	}
	d := int(s.c)
	when WRITE {
		if d > h.keep {
			action: core.Action
			s, action = builder_step(false, true, false, false, &h.b, s, t)
			// Only a close can bring the depth back.
			if t.kind == .End && int(s.c) == h.keep {
				h.keep = h.n
				if scan_known(h, int(s.c)) {
					return scan_stop(h, s)
				}
			}
			return s, action
		}
	}
	if t.kind == .End {
		return scan_close(WRITE, h, s)
	}
	if t.role == .Key {
		wanted := false
		#no_bounds_check #partial switch x in h.steps[d - 1] {
		case core.Name:
			s, wanted = scan_name(WRITE, h, s, t, d, string(x))
		case core.Either:
			s, wanted = scan_name(WRITE, h, s, t, d, x.name)
		case core.Index:
			wanted = int(u32(s.b)) == int(x)
		case core.All:
			wanted = scan_room(h, d)
		}
		if !wanted {
			s.b += 1
			return s, .Skip
		}
		h.want = true
		return scan_write(WRITE, h, s, t)
	}
	want := h.want
	h.want = false
	if d > 0 && h.maps >> uint(d - 1) & 1 == 0 {
		#no_bounds_check #partial switch x in h.steps[d - 1] {
		case core.Index:
			want = int(u32(s.b)) == int(x)
		case core.Either:
			want = int(u32(s.b)) == x.index
		case core.All:
			want = scan_room(h, d)
		}
	}
	if !want {
		s.b += 1
		return s, .Skip
	}
	return scan_reach(WRITE, h, s, t, d)
}

// Whether every answer is known with the logic at depth `d`, so a read that stops early may stop.
@(private)
scan_known :: #force_inline proc "contextless" (h: ^Scan, d: int) -> bool {
	return h.stop_early && (d <= h.multi || h.n_answers >= h.limit && d <= h.rollback)
}

@(private)
scan_stop :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs) -> (core.Hook_Regs, core.Action) {
	h.stopped = true
	return s, .Stop
}

// Whether an `All` step may keep another member. The limit counts answers, which only a repeated key can take back.
@(private)
scan_room :: #force_inline proc "contextless" (h: ^Scan, d: int) -> bool {
	if h.n_answers < h.limit {
		return true
	}
	h.cut |= 1 << uint(d - 1)
	return false
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

// Tests a `Name` step against a key. Under `.Last` a later match takes back what the earlier one kept and answered.
@(private)
scan_name :: #force_inline proc "contextless" ($WRITE: bool, h: ^Scan, s: core.Hook_Regs, t: core.Token, d: int, name: string) -> (core.Hook_Regs, bool) {
	s := s
	bit := u64(1) << uint(d - 1)
	seen := h.matched & bit != 0
	if seen && !h.last || !scan_key_is(WRITE, h, s, t, name) {
		return s, false
	}
	#no_bounds_check m := &h.marks[d - 1]
	if seen {
		h.n_answers = m.answers
		when WRITE {
			s.a = m.a
			h.b.n_counts = m.counts
			h.n_kept = m.kept
			h.n_missing = m.missing
		}
	} else {
		h.matched |= bit
		m^ = {s.a, h.n_answers, h.b.n_counts, h.n_kept, h.n_missing}
	}
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

// A wanted value: the path's end, a container the next step enters, or a value it cannot.
@(private)
scan_reach :: proc "contextless" ($WRITE: bool, h: ^Scan, s: core.Hook_Regs, t: core.Token, d: int) -> (core.Hook_Regs, core.Action) {
	s := s
	at := h.at
	owner := core.Node_Index(s.b >> 32)
	when WRITE {
		at = core.Node_Index(s.a)
		if d > 0 && (h.indexed &~ h.matched) >> uint(d - 1) & 1 != 0 {
			scan_push(h, &h.kept, &h.n_kept, core.Kept_Child{at, u32(s.b)})
		}
	}
	if d == h.n {
		scan_push(h, &h.answers, &h.n_answers, core.Answer{node = at, owner = owner})
		return scan_keep(WRITE, h, s, t, d)
	}
	if scan_enters(h, d, t.kind) {
		s, _ = scan_write(WRITE, h, s, t)
		bit := u64(1) << uint(d)
		h.matched &~= bit
		h.cut &~= bit
		h.maps = h.maps | bit if t.kind == .Map else h.maps &~ bit
		when WRITE {
			#no_bounds_check h.slots[d] = u32(h.b.n_counts)
			scan_push(h, &h.b.doc.counts_alloc, &h.b.n_counts, core.Child_Count{node = at})
		}
		return s, .Next
	}
	if t.kind == .Null && h.alls >> uint(d) == 0 {
		// jq reads every step but `[]` of a null as null.
		scan_push(h, &h.answers, &h.n_answers, core.Answer{node = core.NO_NODE, owner = at if owner == core.NO_NODE else owner, outcome = .Missing})
	} else {
		scan_push(h, &h.answers, &h.n_answers, core.Answer{node = core.NO_NODE, owner = at, outcome = .Type_Mismatch})
		when WRITE {
			if t.kind > .Plain {
				h.keep = d
			}
		}
	}
	return scan_keep(WRITE, h, s, t, d)
}

// Keeps a value whole and goes on past it. With `$WRITE` false it is stepped over, since its nodes are already held.
@(private)
scan_keep :: #force_inline proc "contextless" ($WRITE: bool, h: ^Scan, s: core.Hook_Regs, t: core.Token, d: int) -> (core.Hook_Regs, core.Action) {
	s := s
	when WRITE {
		action: core.Action
		s, action = builder_step(false, true, false, false, &h.b, s, t)
		if action != .Next {
			return s, action
		}
		if t.kind > .Plain {
			return s, .Keep
		}
		if scan_known(h, d) {
			return scan_stop(h, s)
		}
		return s, .Next
	} else {
		s.b += 1
		if scan_known(h, d) {
			return scan_stop(h, s)
		}
		return s, .Skip
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
	h.keep = h.n
	h.stopped = scan_known(h, d)
	return h.stopped
}

// Whether `steps[d]` can enter a value of `kind`.
@(private)
scan_enters :: #force_inline proc "contextless" (h: ^Scan, d: int, kind: core.Kind) -> bool {
	#no_bounds_check switch _ in h.steps[d] {
	case core.Name:
		return kind == .Map
	case core.Index:
		return kind == .Array || kind == .Map && h.positional
	case core.All, core.Either:
		return kind == .Array || kind == .Map
	case core.Slice, core.Descend:
	}
	return false
}

// A path container closes. A `Name` that met no key and an `Index` past the last element answer here, since only the
// close knows, and the container's true count is known.
@(private)
scan_close :: proc "contextless" ($WRITE: bool, h: ^Scan, s: core.Hook_Regs) -> (core.Hook_Regs, core.Action) {
	s := s
	d := int(s.c)
	bit := u64(1) << uint(d - 1)
	open := core.Node_Index(s.b >> 32)
	count := u32(s.b)
	miss, named, all := false, false, false
	name: string
	#no_bounds_check switch x in h.steps[d - 1] {
	case core.Name:
		miss = h.matched & bit == 0
		named = true
		name = string(x)
	case core.Index:
		miss = int(count) <= int(x)
	case core.Either:
		named = h.maps & bit != 0
		name = x.name
		miss = h.matched & bit == 0 if named else int(count) <= x.index
	case core.All:
		all = true
	case core.Slice, core.Descend:
	}
	if miss && h.n_answers < h.limit {
		// A `[]` still to come has nothing to enter, as jq's `null[]`.
		outcome := core.Answer_Outcome.Missing if h.alls >> uint(d) == 0 else core.Answer_Outcome.Type_Mismatch
		scan_push(h, &h.answers, &h.n_answers, core.Answer{node = core.NO_NODE, owner = open, outcome = outcome})
		when WRITE {
			if named {
				scan_push(h, &h.missing, &h.n_missing, core.Missing_Name{open, name})
			}
		}
	}
	when WRITE {
		if h.b.err.kind == .None {
			#no_bounds_check slot := h.slots[d - 1]
			kept := count if all else (0 if miss else 1)
			if h.cut & bit == 0 && kept == count {
				builder_close_node(&h.b, int(s.a), open, count)
				h.b.doc.counts_alloc[slot].node = core.NO_NODE
			} else {
				scan_partial(h, s, slot)
			}
		}
	}
	s.c -= 1
	#no_bounds_check s.b = h.b.stack[s.c]
	if scan_known(h, d - 1) {
		return scan_stop(h, s)
	}
	return s, .Next
}

// Closes the open container of `s` as `Partial`, its true count in its slot.
@(private)
scan_partial :: #force_inline proc "contextless" (h: ^Scan, s: core.Hook_Regs, slot: u32) {
	open := core.Node_Index(s.b >> 32)
	#no_bounds_check {
		n := &h.b.doc.nodes[open]
		n.n = u32(int(s.a) - int(open))
		n.spelling = core.CHILDREN_MAX
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
