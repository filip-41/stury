package build

import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The paths of a demand answered over a document through its readers, as a scan of its text answers them: a built
// document, or a path read's partial one, whose readers tell a value the read did not keep from one the text lacks.

// Answers the paths of `demand` over the document of `r`, as `scan` answers them over its text: each path's answers in
// document order, read with `tape.answer`. Over a partial document a path that meets a value the read did not keep, or
// one it kept short of the path's grain, answers `.Not_Loaded` at the deepest node it reached, in place of the answers
// under it. The document returned is `.Borrowed`: it reads the nodes of `r.doc`, which must outlive it, and holds only
// its answers in `allocator`. The index of `r` is filled as the readers fill it. `opts.dups` is taken as a path read
// takes it, `.All` and `.Refuse` refused. The query holds to `opts.budget`: `depth` for the containers it enters,
// `steps` for those it opens and `memory` for what it allocates, and keeps no node for `nodes` to count. A refused
// allocation or a spent budget is the error, with nothing left allocated. Walks no deeper than the document, with no
// native recursion.
@(require_results)
query :: proc(r: tape.Reader, demand: ^tape.Demand, opts := tape.Options{}, allocator := context.allocator) -> (result: tape.Document, err: tape.Error) {
	format := r.doc.format
	path_read_refused(format, opts) or_return
	m: hook.Memory_Budget
	a := read_allocator(&m, opts, allocator)
	room: Query_Room = ---
	dups := tape.read_dups(format, opts.dups) if format != nil else tape.Duplicates.Last
	q := Query{r = r, demand = demand, dups = dups, allocator = a, ctx = context, room = &room, most = read_depth(opts), steps = opts.budget.steps}
	room_list(&q.answers, room.answers[:], a)
	room_list(&q.frames, room.frames[:], a)
	room_list(&q.live, room.live[:], a)
	room_list(&q.picks, room.picks[:], a)
	room_list(&q.pairs, room.pairs[:], a)
	defer query_free(&q)
	e := query_walk(&q)
	if e == nil {
		result, e = query_document(&q)
	}
	if e != nil {
		return {}, q.over if q.over != nil else hook.memory_budget_error(&m, e)
	}
	result.allocator = allocator
	return
}

// The state of a `query`. A frame is a container on the paths, the root's first, and holds its demand nodes in `live`.
@(private)
Query :: struct {
	r:         tape.Reader,
	demand:    ^tape.Demand,
	dups:      tape.Duplicates, // the query's policy, resolved
	answers:   [dynamic]Query_Answer,
	frames:    [dynamic]Query_Frame,
	live:      [dynamic]u32, // each frame's demand nodes, from its `live`
	picks:     [dynamic]u32, // the demand nodes that take the value being visited
	pairs:     [dynamic]Query_Pair, // each frame's children its steps take by a key or a place, from its `pairs`
	allocator: runtime.Allocator,
	ctx:       runtime.Context, // the caller's, which a list grows under
	room:      ^Query_Room,
	most:      u64, // the deepest container the query enters, by `Budget.depth`
	steps:     u64, // the containers it may open, by `Budget.steps`, 0 for any number
	opened:    u64,
	over:      tape.Error, // the `Budget` limit the query ran out of
	unsorted:  bool, // an answer came before one made earlier
}

// The room on the stack that the query's lists start in, as bytes so that it is left unset.
@(private)
Query_Room :: struct #align (16) {
	answers: [32 * size_of(Query_Answer)]u8,
	frames:  [8 * size_of(Query_Frame)]u8,
	live:    [32 * size_of(u32)]u8,
	picks:   [32 * size_of(u32)]u8,
	pairs:   [32 * size_of(Query_Pair)]u8,
}

// Whether `p` is in the room the query's lists start in.
@(private)
query_in_room :: #force_inline proc "contextless" (q: ^Query, p: rawptr) -> bool {
	return uintptr(p) - uintptr(q.room) < size_of(Query_Room)
}

// Appends `v` to `list`, one of the query's lists.
@(private)
query_push :: #force_inline proc "contextless" (q: ^Query, list: ^[dynamic]$T, v: T) -> runtime.Allocator_Error #no_bounds_check {
	raw := (^runtime.Raw_Dynamic_Array)(list)
	if raw.len == raw.cap {
		query_grow(q, raw, size_of(T), align_of(T), raw.len + 1) or_return
	}
	([^]T)(raw.data)[raw.len] = v
	raw.len += 1
	return nil
}

// Adds demand node `n` to the picks, unless they hold it.
@(private)
query_pick :: #force_inline proc "contextless" (q: ^Query, n: u32) -> runtime.Allocator_Error #no_bounds_check {
	for p in q.picks {
		if p == n {
			return nil
		}
	}
	return query_push(q, &q.picks, n)
}

@(private, cold)
query_grow :: #force_no_inline proc "contextless" (q: ^Query, list: ^runtime.Raw_Dynamic_Array, size, align, least: int) -> runtime.Allocator_Error {
	return list_grow(&q.ctx, list, size, align, least, query_in_room(q, list.data))
}

// An answer and its place in document order, as a scan places them: at its node, or for a miss its close settles just
// before the node past the container. The place and whether it is just before it keep the answer in 16 bytes, where a
// scan's position takes 24.
@(private)
Query_Answer :: struct {
	node:    tape.Node_Index,
	path:    u32,
	place:   tape.Node_Index,
	outcome: tape.Presence,
	before:  bool,
}

#assert(size_of(Query_Answer) == 16)

// A container on the paths. Its children are taken as `children` walks them when a step takes children by their
// place among all of them, an `All` or a `Slice`, and else only those `pairs` lists.
@(private)
Query_Frame :: struct {
	at:             tape.Node_Index,
	depth:          u64, // the steps taken to its children, for a path with no `Descend`
	live, n_live:   u32,
	pairs, n_pairs: u32, // its children taken by a key or a place, each member of a key a `Name` takes, sorted by child
	next:           u32, // the next pair, or in a walk the next child's place
	count:          int, // an array's length, -1 when the document does not know it
	walk:           tape.Children,
	walks:          bool,
	only:           u32, // in a walk, the demand node of the one step that takes every child, `NO_DEMAND` for another walk
	direct:         bool, // `only` takes each child as `query_direct` reads it, with no frame
}

@(private)
NO_DEMAND :: max(u32)

// A child a step of a frame takes by its key or its place, and the demand node it leads to.
@(private)
Query_Pair :: struct {
	child: tape.Node_Index,
	to:    u32,
}

// Answers the query's paths from the root.
@(private)
query_walk :: proc(q: ^Query) -> runtime.Allocator_Error {
	dm := q.demand
	if len(dm.paths) == 0 {
		return nil
	}
	at, p := tape.root(q.r)
	if p != .Found {
		for x in 0 ..< len(dm.paths) {
			query_answer(q, tape.NO_NODE, u32(x), p, 0, 0) or_return
		}
		return nil
	}
	if name, below := query_named_below(q); below {
		return query_names(q, name)
	}
	query_push(q, &q.picks, 0) or_return
	query_visit(q, at, 0, tape.NO_NODE) or_return
	for len(q.frames) > 0 {
		query_step(q) or_return
	}
	return nil
}

// The name of a demand of the one path `Descend` then `Name` with no grain short of the whole, over a whole document
// whose keys all lie in its nodes, which `query_names` answers. False for any other demand or document.
@(private)
query_named_below :: proc "contextless" (q: ^Query) -> (string, bool) #no_bounds_check {
	dm, doc := q.demand, q.r.doc
	if len(dm.paths) != 1 || dm.paths[0].length != 2 || dm.paths[0].grain != .Whole || doc.partial != nil || doc.ext != nil || .Held in doc.flags {
		return "", false
	}
	if dm.nodes[0].n_edges != 1 || dm.nodes[0].n_ends != 0 {
		return "", false
	}
	if _, descends := dm.edges[dm.nodes[0].edges].step.(tape.Descend); !descends {
		return "", false
	}
	below := dm.nodes[dm.edges[dm.nodes[0].edges].to]
	for e in dm.edges[below.edges:][:below.n_edges] {
		if name, named := e.step.(tape.Name); named && below.n_ends == 0 {
			return string(name), true
		}
	}
	return "", false
}

// Answers `..` then `.name` over the whole document as one pass over its nodes in order: each member whose key reads as
// `name`, every member of a repeated key as written, as a `Name` past a `Descend` takes them. A key that is a container
// is no value a `Descend` reaches, so its nodes are passed.
@(private)
query_names :: proc(q: ^Query, name: string) -> runtime.Allocator_Error #no_bounds_check {
	doc := q.r.doc
	nodes := doc.nodes
	limit := q.demand.paths[0].limit
	// The ends of the containers open at the node read, which the depth is the count of.
	ends_room: [64]tape.Node_Index = ---
	ends: [dynamic]tape.Node_Index
	room_list(&ends, ends_room[:], q.allocator)
	defer if raw_data(ends) != raw_data(ends_room[:]) {
		delete(ends)
	}
	end := tape.node_after(doc, tape.ROOT)
	for k := tape.ROOT; k < end; k += 1 {
		for len(ends) > 0 && ends[len(ends) - 1] <= k {
			(^runtime.Raw_Dynamic_Array)(&ends).len -= 1
		}
		t := nodes[k]
		if t.role == .Key {
			if t.kind > .Plain {
				k = tape.node_after(doc, k) - 1
			} else if tape.key_names(doc.format, doc.src, t, name) {
				query_answer(q, k + 1, 0, .Found, 2 * u64(k + 1), 0) or_return
				if limit != 0 && len(q.answers) == int(limit) {
					return nil
				}
			}
		} else if t.kind > .Plain {
			query_enter(q, k, u64(len(ends)) + 1) or_return
			if len(ends) == cap(ends) {
				list_grow(&q.ctx, (^runtime.Raw_Dynamic_Array)(&ends), size_of(tape.Node_Index), align_of(tape.Node_Index), len(ends) + 1, raw_data(ends) == raw_data(ends_room[:])) or_return
			}
			(^runtime.Raw_Dynamic_Array)(&ends).len += 1
			ends[len(ends) - 1] = k + tape.Node_Index(t.n)
		}
	}
	return nil
}

// Counts the container `at`, `depth` levels from the root, against the query's budget.
@(private)
query_enter :: #force_inline proc "contextless" (q: ^Query, at: tape.Node_Index, depth: u64) -> runtime.Allocator_Error {
	if depth > q.most || q.steps != 0 && q.opened >= q.steps {
		return query_spent(q, at, .Depth if depth > q.most else .Steps)
	}
	q.opened += 1
	return nil
}

// Records the `Budget` limit `kind` the query ran out of at the container `at`, and ends the query, which reads the
// returned error as that limit.
@(private, cold)
query_spent :: #force_no_inline proc "contextless" (q: ^Query, at: tape.Node_Index, kind: tape.Budget_Kind) -> runtime.Allocator_Error {
	q.over = tape.Exceeded{at = q.r.doc.nodes[at].lo, kind = kind}
	return .Out_Of_Memory
}

// Takes the value `at`, which the demand nodes in `q.picks` took, its owner the container holding it: answers the paths
// that end at those nodes, gives the paths whose steps cannot enter it their failure, and opens a frame for it when a
// step goes on into it.
@(private)
query_visit :: proc(q: ^Query, at: tape.Node_Index, depth: u64, owner: tape.Node_Index) -> runtime.Allocator_Error #no_bounds_check {
	dm := q.demand
	// A `Descend` takes the value itself, and each node it leads to takes what its node takes.
	if dm.deep {
		for i := 0; i < len(q.picks); i += 1 {
			if to := dm.nodes[q.picks[i]].descend; to != 0 {
				query_pick(q, to) or_return
			}
		}
	}
	node := q.r.doc.nodes[at]
	if len(q.picks) == 1 && query_direct(dm, q.picks[0], q.dups) {
		return query_visit_direct(q, at, q.picks[0], depth, owner)
	}
	enters := false
	for n in q.picks {
		dn := &dm.nodes[n]
		query_ends(q, at, n) or_return
		for &e in dm.edges[dn.edges:][:dn.n_edges] {
			if _, descends := e.step.(tape.Descend); descends {
				continue
			}
			if tape.step_enters(e.step, node.kind) {
				enters = true
			} else {
				paths_fail(q, dm, e.to, tape.step_refused(node.kind), depth, at, owner, 2 * u64(at), query_answer) or_return
			}
		}
	}
	if enters {
		return query_open(q, at, depth + 1)
	}
	return nil
}

// Takes the value `at`, which demand node `n` alone took, where `query_direct` holds: one step takes one child that ends
// its paths, so the container is entered with no frame.
@(private)
query_visit_direct :: #force_inline proc(q: ^Query, at: tape.Node_Index, n: u32, depth: u64, owner: tape.Node_Index) -> runtime.Allocator_Error #no_bounds_check {
	dm := q.demand
	node := q.r.doc.nodes[at]
	query_ends(q, at, n) or_return
	e := dm.edges[dm.nodes[n].edges]
	if !tape.step_enters(e.step, node.kind) {
		return paths_fail(q, dm, e.to, tape.step_refused(node.kind), depth, at, owner, 2 * u64(at), query_answer)
	}
	query_enter(q, at, depth + 1) or_return
	return query_take(q, at, e.step, e.to, depth + 1, true)
}

// Opens a frame for the container `at`, which the demand nodes in `q.picks` go on into, at `depth` steps from the root.
// A step that takes one child by its key or place takes it now, and its miss is answered now, placed at the close.
@(private)
query_open :: proc(q: ^Query, at: tape.Node_Index, depth: u64) -> runtime.Allocator_Error #no_bounds_check {
	query_enter(q, at, depth) or_return
	dm := q.demand
	r := q.r
	doc := r.doc
	node := doc.nodes[at]
	live, first_pair := u32(len(q.live)), u32(len(q.pairs))
	walks := false
	for n in q.picks {
		dn := &dm.nodes[n]
		taken := false
		for &e in dm.edges[dn.edges:][:dn.n_edges] {
			if !tape.step_enters(e.step, node.kind) {
				continue
			}
			taken = true
			#partial switch s in e.step {
			case tape.Name:
				if !dn.deep && q.dups != .Group {
					query_take(q, at, e.step, e.to, depth, false) or_return
					continue
				}
				// Each member of the key is taken, and a miss is answered now.
				c, p := tape.named(r, at, string(s))
				for p == .Found {
					_, member, mp := tape.next_child(r, &c, .Group)
					if mp != .Found {
						break
					}
					query_push(q, &q.pairs, Query_Pair{member, e.to}) or_return
				}
				if p != .Found {
					query_missed(q, at, e.to, p, depth) or_return
				}
			case tape.Index:
				query_take(q, at, e.step, e.to, depth, false) or_return
			case tape.All, tape.Slice:
				walks = true
			}
		}
		if taken {
			query_push(q, &q.live, n) or_return
		}
	}
	f := Query_Frame{at = at, depth = depth, live = live, n_live = u32(len(q.live)) - live, pairs = first_pair, n_pairs = u32(len(q.pairs)) - first_pair, count = -1, walks = walks, only = NO_DEMAND}
	if node.kind == .Array {
		f.count = tape.child_count(doc, at, node)
	}
	if f.walks {
		c, p, cerr := tape.children(r, at, q.allocator)
		if cerr != nil {
			return cerr
		}
		if p != .Found {
			// A partial object does not keep its members' places, so the steps that take children by them cannot read it.
			f.walks = false
			for n in q.live[f.live:] {
				dn := &dm.nodes[n]
				for &e in dm.edges[dn.edges:][:dn.n_edges] {
					#partial switch _ in e.step {
					case tape.All, tape.Slice:
						paths_fail(q, dm, e.to, .Not_Loaded, 0, at, at, 2 * u64(at), query_answer) or_return
					}
				}
			}
		} else {
			f.walk, f.only = c, query_only(dm, q.live[f.live:])
			f.direct = f.only != NO_DEMAND && query_direct(dm, f.only, q.dups) && dm.nodes[f.only].descend == 0
			if f.count > 0 {
				query_reserve(q, &f, f.count) or_return
			}
		}
	}
	pairs := q.pairs[f.pairs:]
	if len(pairs) > 1 && !slice.is_sorted_by(pairs, query_pair_before) {
		slice.stable_sort_by(pairs, query_pair_before)
	}
	if !f.walks && query_leaves(dm, pairs) {
		// Children whose demand nodes go no further are answered now, with no frame to take them.
		for pair in pairs {
			query_ends(q, pair.child, pair.to) or_return
		}
		query_cut(&q.live, f.live)
		query_cut(&q.pairs, f.pairs)
		return nil
	}
	err := query_push(q, &q.frames, f)
	if err != nil && f.walks {
		tape.destroy_children(&f.walk)
	}
	return err
}

// Takes the child of the container `at`, `depth` levels from the root, that `step`, a `Name` that takes one member or an
// `Index`, leads demand node `to` to: answered now with `leaf`, else listed as a pair of the container's frame.
@(private)
query_take :: #force_inline proc(q: ^Query, at: tape.Node_Index, step: tape.Step, to: u32, depth: u64, leaf: bool) -> runtime.Allocator_Error #no_bounds_check {
	child, p := tape.NO_NODE, tape.Presence.Missing
	#partial switch s in step {
	case tape.Name:
		child, p = tape.member(q.r, at, string(s), q.dups)
	case tape.Index:
		child, p = tape.element(q.r, at, int(s))
	}
	if p != .Found {
		return query_missed(q, at, to, p, depth)
	}
	if leaf {
		return query_ends(q, child, to)
	}
	return query_push(q, &q.pairs, Query_Pair{child, to})
}

// Answers the paths through demand node `to` that a step of the container `at`, `depth` levels from the root, read as
// `p`: a missing child placed at the container's close, any other just after the container's node.
@(private)
query_missed :: proc(q: ^Query, at: tape.Node_Index, to: u32, p: tape.Presence, depth: u64) -> runtime.Allocator_Error {
	if p == .Missing {
		return paths_fail(q, q.demand, to, .Missing, depth, at, at, 2 * u64(at + tape.Node_Index(q.r.doc.nodes[at].n)) - 1, query_answer)
	}
	return paths_fail(q, q.demand, to, p, 0, at, at, 2 * u64(at), query_answer)
}

// Whether demand node `n`, the one that took a container, has one step, a `Name` that takes one member under `dups` or
// an `Index`, to a node with no step and no `Descend` past it, so the child it takes is answered with no frame.
@(private)
query_direct :: #force_inline proc "contextless" (dm: ^tape.Demand, n: u32, dups: tape.Duplicates) -> bool #no_bounds_check {
	if dups == .Group {
		return false
	}
	dn := dm.nodes[n]
	if dn.n_edges != 1 || dn.deep {
		return false
	}
	e := dm.edges[dn.edges]
	#partial switch _ in e.step {
	case tape.Name, tape.Index:
		to := dm.nodes[e.to]
		return to.n_edges == 0 && to.descend == 0
	}
	return false
}

// Answers the paths that demand node `n` ends at the value `at`.
@(private)
query_ends :: #force_inline proc "contextless" (q: ^Query, at: tape.Node_Index, n: u32) -> runtime.Allocator_Error #no_bounds_check {
	dm := q.demand
	dn := &dm.nodes[n]
	for p in dm.ends[dn.ends:][:dn.n_ends] {
		outcome := tape.Presence.Found if query_holds(q.r.doc, at, dm.paths[p].grain) else .Not_Loaded
		query_answer(q, at, p, outcome, 2 * u64(at), 0) or_return
	}
	return nil
}

// Reserves room for the answers the walk of the array of frame `f`, with `count` elements, gives: those of each
// element its walk takes and of each child an element's steps take by a key or a place.
@(private)
query_reserve :: proc(q: ^Query, f: ^Query_Frame, count: int) -> runtime.Allocator_Error #no_bounds_check {
	dm := q.demand
	each := 0
	for n in q.live[f.live:][:f.n_live] {
		dn := &dm.nodes[n]
		for &e in dm.edges[dn.edges:][:dn.n_edges] {
			#partial switch _ in e.step {
			case tape.All, tape.Slice:
				to := dm.nodes[e.to]
				each += int(to.n_ends)
				for &g in dm.edges[to.edges:][:to.n_edges] {
					#partial switch _ in g.step {
					case tape.Name, tape.Index:
						each += int(dm.nodes[g.to].n_ends)
					}
				}
			}
		}
	}
	raw := (^runtime.Raw_Dynamic_Array)(&q.answers)
	if want := raw.len + each * count; want > raw.cap {
		return query_grow(q, raw, size_of(Query_Answer), align_of(Query_Answer), want)
	}
	return nil
}

// The demand node of the one step of the demand nodes `live` that takes children by their place, when that step is an
// `All` with no limit, which takes every child. `NO_DEMAND` for any other steps.
@(private)
query_only :: proc "contextless" (dm: ^tape.Demand, live: []u32) -> u32 #no_bounds_check {
	only := NO_DEMAND
	for n in live {
		dn := &dm.nodes[n]
		for &e in dm.edges[dn.edges:][:dn.n_edges] {
			#partial switch s in e.step {
			case tape.All:
				if only != NO_DEMAND || s.limit > 0 {
					return NO_DEMAND
				}
				only = e.to
			case tape.Slice:
				return NO_DEMAND
			}
		}
	}
	return only
}

// Shortens `list` to its first `n` items.
@(private)
query_cut :: #force_inline proc "contextless" (list: ^[dynamic]$T, n: u32) {
	(^runtime.Raw_Dynamic_Array)(list).len = int(n)
}

// Whether each pair leads to a demand node with no step and no `Descend` past it.
@(private)
query_leaves :: #force_inline proc "contextless" (dm: ^tape.Demand, pairs: []Query_Pair) -> bool #no_bounds_check {
	for pair in pairs {
		if dn := dm.nodes[pair.to]; dn.n_edges != 0 || dn.descend != 0 {
			return false
		}
	}
	return true
}

@(private)
query_pair_before :: proc(a, b: Query_Pair) -> bool {
	return a.child < b.child
}

// Takes the next child of the frame on top, or closes the frame once it has none left.
@(private)
query_step :: proc(q: ^Query) -> runtime.Allocator_Error #no_bounds_check {
	f := &q.frames[len(q.frames) - 1]
	at, depth := f.at, f.depth
	if !f.walks {
		if f.next == f.n_pairs {
			query_close(q)
			return nil
		}
		pairs := q.pairs[f.pairs:][:f.n_pairs]
		child := pairs[f.next].child
		clear(&q.picks)
		for f.next < f.n_pairs && pairs[f.next].child == child {
			query_pick(q, pairs[f.next].to) or_return
			f.next += 1
		}
		return query_visit(q, child, depth, at)
	}
	dm := q.demand
	doc := q.r.doc
	_, child, p := tape.next_child(q.r, &f.walk, .Group)
	// A partial array whose count is not known holds children no read places, so from the first child the readers
	// cannot take the paths through the walk answer once, as not loaded.
	past := f.count < 0 && p == .Not_Loaded
	if p == .Missing {
		query_walked(f)
		return nil
	}
	index := u64(f.next)
	f.next += 1
	object := doc.nodes[at].kind == .Object
	clear(&q.picks)
	// A child taken by its key or place is a pair, and the pairs come in document order, as the walk does.
	pairs := q.pairs[f.pairs:][:f.n_pairs]
	for p == .Found && len(pairs) > 0 && pairs[0].child == child {
		query_push(q, &q.picks, pairs[0].to) or_return
		pairs = pairs[1:]
		f.pairs += 1
		f.n_pairs -= 1
	}
	if f.direct && p == .Found && len(q.picks) == 0 {
		return query_visit_direct(q, child, f.only, depth, at)
	}
	if f.only != NO_DEMAND {
		if p != .Found {
			paths_fail(q, dm, f.only, .Not_Loaded, 0, at, at, 2 * u64(f.walk.next) - 1, query_answer) or_return
		} else {
			query_pick(q, f.only) or_return
		}
	} else {
		for n in q.live[f.live:][:f.n_live] {
			dn := &dm.nodes[n]
			for &e in dm.edges[dn.edges:][:dn.n_edges] {
				// The pairs hold the children a `Name` or an `Index` takes.
				#partial switch _ in e.step {
				case tape.Name, tape.Index, tape.Descend:
					continue
				case tape.Slice:
					if !object && f.count < 0 {
						// The count is not known, so no element is known to be taken or not.
						if index == 0 {
							paths_fail(q, dm, e.to, .Not_Loaded, 0, at, at, 2 * u64(at), query_answer) or_return
						}
						continue
					}
				}
				if !tape.child_takes(e.step, index, u64(f.count), object, q.dups) {
					continue
				}
				if p != .Found {
					// A child not kept lies after the children before it and before the next one kept.
					paths_fail(q, dm, e.to, .Not_Loaded, 0, at, at, 2 * u64(f.walk.next) - 1, query_answer) or_return
				} else {
					query_pick(q, e.to) or_return
				}
			}
		}
	}
	if past {
		query_walked(f)
		return nil
	}
	if p != .Found || len(q.picks) == 0 {
		return nil
	}
	return query_visit(q, child, depth, at)
}

// Ends the walk of frame `f`, whose pairs the walk has not passed are then taken as a frame with no walk takes them.
@(private)
query_walked :: proc(f: ^Query_Frame) {
	tape.destroy_children(&f.walk)
	f.walks, f.next = false, 0
}

// Closes the frame on top, which has no child left.
@(private)
query_close :: proc(q: ^Query) {
	f := pop(&q.frames)
	if f.walks {
		tape.destroy_children(&f.walk)
	}
	query_cut(&q.live, f.live)
	query_cut(&q.pairs, f.pairs)
}

// Answers `path` at `node`, placed at `pos`: twice a node's index, or one less for a place just before that node. The
// demand node the answer came through is a scan's, which a query keeps no answer back by.
@(private)
query_answer :: #force_inline proc "contextless" (q: ^Query, node: tape.Node_Index, path: u32, outcome: tape.Presence, pos: u64, _: u32) -> runtime.Allocator_Error {
	a := Query_Answer{node, path, tape.Node_Index((pos + 1) / 2), outcome, pos & 1 != 0}
	if n := len(q.answers); n > 0 && query_answer_before(a, q.answers[n - 1]) {
		q.unsorted = true
	}
	return query_push(q, &q.answers, a)
}

// Whether the node `at` of `doc` holds what `grain` keeps of it: every node under it for `.Whole`, and its keys or its
// count for `.Keys`. A document of every value holds all of it.
@(private)
query_holds :: #force_inline proc "contextless" (doc: ^tape.Document, at: tape.Node_Index, grain: tape.Grain) -> bool {
	return doc.partial == nil || query_partial_holds(doc, at, grain)
}

@(private)
query_partial_holds :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index, grain: tape.Grain) -> bool #no_bounds_check {
	node := doc.nodes[at]
	if node.kind != .Array && node.kind != .Object {
		return true
	}
	switch grain {
	case .Whole:
		for k in at ..< at + tape.Node_Index(node.n) {
			if t := doc.nodes[k]; t.kind > .Plain && t.spelling & tape.CONTAINER_PARTIAL != 0 {
				return false
			}
		}
	case .Keys:
		return node.spelling & tape.CONTAINER_PARTIAL == 0 || node.kind == .Array && tape.child_count(doc, at, node) >= 0
	case .Exists:
	}
	return true
}

// The document of the query's answers: each path's in document order, up to its limit, in one block with the starts,
// over the nodes, kept children and missing names of the document read.
@(private)
query_document :: proc(q: ^Query) -> (result: tape.Document, err: runtime.Allocator_Error) {
	dm := q.demand
	doc := q.r.doc
	answers := q.answers[:]
	if q.unsorted {
		slice.stable_sort_by(answers, proc(a, b: Query_Answer) -> bool { return query_answer_before(a, b) })
	}
	paths := len(dm.paths)
	if paths == 1 {
		limit := dm.paths[0].limit
		n := len(answers) if limit == 0 else min(len(answers), int(limit))
		x := tape.partial_block(1, n, 0, 0, 0, q.dups, q.allocator) or_return
		for a, i in answers[:n] {
			x.answers[i] = {a.node, a.outcome}
		}
		x.starts[1] = u32(n)
		return query_result(doc, x), nil
	}
	// A path keeps its first answers in document order, up to its limit, which the live list the finished walk left
	// empty counts.
	query_cut(&q.live, 0)
	for _ in 0 ..< paths {
		query_push(q, &q.live, 0) or_return
	}
	kept := q.live[:]
	live := 0
	for a in answers {
		if limit := dm.paths[a.path].limit; limit == 0 || kept[a.path] < limit {
			kept[a.path] += 1
			live += 1
		}
	}
	x := tape.partial_block(paths, live, 0, 0, 0, q.dups, q.allocator) or_return
	for p in 0 ..< paths {
		x.starts[p + 1] = x.starts[p] + kept[p]
	}
	// Where each path's next answer goes.
	copy(kept, x.starts[:paths])
	for a in answers {
		if kept[a.path] < x.starts[a.path + 1] {
			x.answers[kept[a.path]] = {a.node, a.outcome}
			kept[a.path] += 1
		}
	}
	return query_result(doc, x), nil
}

// The document over the nodes of `doc`, and the kept children and missing names of a partial one, that holds the
// answers `x`.
@(private)
query_result :: proc "contextless" (doc: ^tape.Document, x: ^tape.Partial) -> tape.Document {
	if src := doc.partial; src != nil {
		x.kept, x.missing, x.names, x.dups, x.facts = src.kept, src.missing, src.names, src.dups, src.facts
	} else {
		x.facts = true
	}
	result := doc^
	result.partial = x
	result.flags = result.flags - {.Owns_Src} + {.Borrowed}
	return result
}

@(private)
query_answer_before :: proc "contextless" (a, b: Query_Answer) -> bool {
	if a.place != b.place {
		return a.place < b.place
	}
	return a.before && !b.before || a.before == b.before && a.path < b.path
}

@(private)
query_free :: proc(q: ^Query) {
	for &f in q.frames {
		if f.walks {
			tape.destroy_children(&f.walk)
		}
	}
	for list in ([]^runtime.Raw_Dynamic_Array{(^runtime.Raw_Dynamic_Array)(&q.answers), (^runtime.Raw_Dynamic_Array)(&q.frames), (^runtime.Raw_Dynamic_Array)(&q.live), (^runtime.Raw_Dynamic_Array)(&q.picks), (^runtime.Raw_Dynamic_Array)(&q.pairs)}) {
		if !query_in_room(q, list.data) {
			runtime.mem_free(list.data, list.allocator)
		}
	}
}
