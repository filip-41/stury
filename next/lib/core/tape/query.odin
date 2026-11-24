package tape

import "base:runtime"
import "core:slice"

// The paths of a demand answered over a document through its readers, as a scan of its text answers them: a built
// document, or a path read's partial one, whose readers tell a value the read did not keep from one the text lacks.

// Answers the paths of `demand` over the document of `r` under `dups`, as `scan` answers them over its text: each path's
// answers in document order, read with `answer`. Over a partial document a path that meets a value the read did not
// keep, or one it kept short of the path's grain, answers `.Not_Loaded` at the deepest node it reached, in place of the
// answers under it. The document returned is `.Borrowed`: it reads the nodes of `r.doc`, which must outlive it, and
// holds only its answers in `allocator`. The index of `r` is filled as the readers fill it. A refused allocation is the
// error, with nothing left allocated. Walks no deeper than the document, with no native recursion.
@(require_results)
query :: proc(r: Reader, demand: ^Demand, dups := Duplicates.Default, allocator := context.allocator) -> (result: Document, err: Error) {
	doc := r.doc
	room: Query_Room = ---
	q := Query{r = r, demand = demand, dups = read_dups(doc.format, dups), allocator = allocator, room = &room}
	query_room_list(&q.answers, room.answers[:], allocator)
	query_room_list(&q.frames, room.frames[:], allocator)
	query_room_list(&q.live, room.live[:], allocator)
	query_room_list(&q.picks, room.picks[:], allocator)
	query_room_list(&q.pairs, room.pairs[:], allocator)
	defer query_free(&q)
	if len(demand.paths) > 0 {
		if at, p := root(r); p != .Found {
			for x in 0 ..< len(demand.paths) {
				query_answer(&q, NO_NODE, u32(x), p, 0) or_return
			}
		} else {
			query_push(&q, &q.picks, 0) or_return
			query_visit(&q, at, 0, NO_NODE) or_return
			for len(q.frames) > 0 {
				query_step(&q) or_return
			}
		}
	}
	return query_document(&q)
}

// The state of a `query`. A frame is a container on the paths, the root's first, and holds its demand nodes in `live`.
@(private)
Query :: struct {
	r:         Reader,
	demand:    ^Demand,
	dups:      Duplicates, // the query's policy, resolved
	answers:   [dynamic]Query_Answer,
	frames:    [dynamic]Query_Frame,
	live:      [dynamic]u32, // each frame's demand nodes, from its `live`
	picks:     [dynamic]u32, // the demand nodes that take the value being visited
	pairs:     [dynamic]Query_Pair, // each frame's children its steps take by a key or a place, from its `pairs`
	allocator: runtime.Allocator,
	room:      ^Query_Room,
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

@(private)
query_room_list :: proc "contextless" (list: ^[dynamic]$T, room: []u8, allocator: runtime.Allocator) {
	(^runtime.Raw_Dynamic_Array)(list)^ = {data = raw_data(room), len = 0, cap = len(room) / size_of(T), allocator = allocator}
}

// Whether `p` is in the room the query's lists start in.
@(private)
query_in_room :: #force_inline proc "contextless" (q: ^Query, p: rawptr) -> bool {
	return uintptr(p) - uintptr(q.room) < size_of(Query_Room)
}

// Appends `v` to `list`, one of the query's lists.
@(private)
query_push :: #force_inline proc(q: ^Query, list: ^[dynamic]$T, v: T) -> runtime.Allocator_Error #no_bounds_check {
	raw := (^runtime.Raw_Dynamic_Array)(list)
	if raw.len == raw.cap {
		query_grow(q, raw, size_of(T), align_of(T), raw.len + 1) or_return
	}
	([^]T)(raw.data)[raw.len] = v
	raw.len += 1
	return nil
}

// Grows a list of entries of `size` bytes to twice its capacity, and to at least `least`. A list in the room moves out
// of it.
@(private, cold)
query_grow :: #force_no_inline proc(q: ^Query, list: ^runtime.Raw_Dynamic_Array, size, align, least: int) -> runtime.Allocator_Error {
	want := max(2 * list.cap, 8, least)
	data: []u8
	err: runtime.Allocator_Error
	if query_in_room(q, list.data) {
		if data, err = runtime.mem_alloc_non_zeroed(want * size, align, list.allocator); err == nil {
			runtime.mem_copy_non_overlapping(raw_data(data), list.data, list.len * size)
		}
	} else {
		data, err = runtime.non_zero_mem_resize(list.data, list.cap * size, want * size, align, list.allocator)
	}
	if err == nil && len(data) < want * size {
		err = .Out_Of_Memory
	}
	if err == nil {
		list.data, list.cap = raw_data(data), want
	}
	return err
}

// An answer and its place in document order, as a scan places them: at its node, or for a miss its close settles just
// before the node past the container.
@(private)
Query_Answer :: struct {
	node:    Node_Index,
	path:    u32,
	place:   Node_Index,
	outcome: Presence,
	before:  bool,
}

// A container on the paths. Its children are taken as `children` walks them when a step takes children by their
// place among all of them, an `All` or a `Slice`, and else only those `pairs` lists.
@(private)
Query_Frame :: struct {
	at:            Node_Index,
	depth:         u64, // the steps taken to its children, for a path with no `Descend`
	live, n_live:  u32,
	pairs, n_pairs: u32, // its children taken by a key or a place, each member of a key a `Name` takes, sorted by child
	next:          u32, // the next pair, or in a walk the next child's place
	count:         int, // an array's length, -1 when the document does not know it
	walk:          Children,
	walks:         bool,
	only:          u32, // in a walk, the demand node of the one step that takes every child, `NO_DEMAND` for another walk
}

@(private)
NO_DEMAND :: max(u32)

// A child a step of a frame takes by its key or its place, and the demand node it leads to.
@(private)
Query_Pair :: struct {
	child: Node_Index,
	to:    u32,
}

// Takes the value `at`, which the demand nodes in `q.picks` took, its owner the container holding it: answers the paths
// that end at those nodes, gives the paths whose steps cannot enter it their failure, and opens a frame for it when a
// step goes on into it.
@(private)
query_visit :: proc(q: ^Query, at: Node_Index, depth: u64, owner: Node_Index) -> runtime.Allocator_Error #no_bounds_check {
	dm := q.demand
	// A `Descend` takes the value itself, and each node it leads to takes what its node takes.
	if dm.deep {
		for i := 0; i < len(q.picks); i += 1 {
			if to := dm.nodes[q.picks[i]].descend; to != 0 && !slice.contains(q.picks[:], to) {
				query_push(q, &q.picks, to) or_return
			}
		}
	}
	node := q.r.doc.nodes[at]
	enters := false
	for n in q.picks {
		dn := &dm.nodes[n]
		for p in dm.ends[dn.ends:][:dn.n_ends] {
			outcome := Presence.Found if query_holds(q.r.doc, at, dm.paths[p].grain) else .Not_Loaded
			query_answer(q, at, p, outcome, 2 * u64(at)) or_return
		}
		for &e in dm.edges[dn.edges:][:dn.n_edges] {
			if _, descends := e.step.(Descend); descends {
				continue
			}
			if step_enters(e.step, node.kind) {
				enters = true
			} else {
				query_fail(q, e.to, node.kind == .Null, depth, at, owner, 2 * u64(at)) or_return
			}
		}
	}
	if enters {
		return query_open(q, at, depth + 1)
	}
	return nil
}

// Opens a frame for the container `at`, which the demand nodes in `q.picks` go on into, at `depth` steps from the root.
// A step that takes one child by its key or place takes it now, and its miss is answered now, placed at the close.
@(private)
query_open :: proc(q: ^Query, at: Node_Index, depth: u64) -> runtime.Allocator_Error #no_bounds_check {
	dm := q.demand
	r := q.r
	doc := r.doc
	node := doc.nodes[at]
	close := 2 * u64(at + Node_Index(node.n)) - 1
	f := Query_Frame{at = at, depth = depth, live = u32(len(q.live)), pairs = u32(len(q.pairs)), count = -1, only = NO_DEMAND}
	if node.kind == .Array {
		f.count = child_count(doc, at, node)
	}
	for n in q.picks {
		dn := &dm.nodes[n]
		taken := false
		for &e in dm.edges[dn.edges:][:dn.n_edges] {
			if !step_enters(e.step, node.kind) {
				continue
			}
			taken = true
			child, p := NO_NODE, Presence.Found
			#partial switch s in e.step {
			case Name:
				if dn.deep || q.dups == .Group {
					// Each member of the key is taken, and a miss is answered now.
					c: Children
					if c, p = named(r, at, string(s)); p == .Found {
						for {
							_, member, mp := next_child(r, &c, .Group)
							if mp != .Found {
								break
							}
							query_push(q, &q.pairs, Query_Pair{member, e.to}) or_return
						}
						continue
					}
				} else {
					child, p = member(r, at, string(s), q.dups)
				}
			case Index:
				child, p = element(r, at, int(s))
			case All, Slice:
				f.walks = true
				continue
			case Descend:
				continue
			}
			switch p {
			case .Found:
				query_push(q, &q.pairs, Query_Pair{child, e.to}) or_return
			case .Missing:
				query_fail(q, e.to, true, depth, at, at, close) or_return
			case .Wrong_Kind, .Not_Loaded, .Ambiguous:
				query_unread(q, e.to, at, p, 2 * u64(at)) or_return
			}
		}
		if taken {
			query_push(q, &q.live, n) or_return
		}
	}
	f.n_live = u32(len(q.live)) - f.live
	f.n_pairs = u32(len(q.pairs)) - f.pairs
	if f.walks {
		c, p, cerr := children(r, at, q.allocator)
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
					case All, Slice:
						query_unread(q, e.to, at, .Not_Loaded, 2 * u64(at)) or_return
					}
				}
			}
		} else {
			f.walk, f.only = c, query_only(dm, q.live[f.live:])
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
			dn := &dm.nodes[pair.to]
			for p in dm.ends[dn.ends:][:dn.n_ends] {
				outcome := Presence.Found if query_holds(doc, pair.child, dm.paths[p].grain) else .Not_Loaded
				query_answer(q, pair.child, p, outcome, 2 * u64(pair.child)) or_return
			}
		}
		query_cut(&q.live, f.live)
		query_cut(&q.pairs, f.pairs)
		return nil
	}
	err := query_push(q, &q.frames, f)
	if err != nil && f.walks {
		destroy_children(&f.walk)
	}
	return err
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
			case All, Slice:
				to := dm.nodes[e.to]
				each += int(to.n_ends)
				for &g in dm.edges[to.edges:][:to.n_edges] {
					#partial switch _ in g.step {
					case Name, Index:
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
query_only :: proc "contextless" (dm: ^Demand, live: []u32) -> u32 #no_bounds_check {
	only := NO_DEMAND
	for n in live {
		dn := &dm.nodes[n]
		for &e in dm.edges[dn.edges:][:dn.n_edges] {
			#partial switch s in e.step {
			case All:
				if only != NO_DEMAND || s.limit > 0 {
					return NO_DEMAND
				}
				only = e.to
			case Slice:
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
query_leaves :: #force_inline proc "contextless" (dm: ^Demand, pairs: []Query_Pair) -> bool #no_bounds_check {
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
			if !slice.contains(q.picks[:], pairs[f.next].to) {
				query_push(q, &q.picks, pairs[f.next].to) or_return
			}
			f.next += 1
		}
		return query_visit(q, child, depth, at)
	}
	dm := q.demand
	doc := q.r.doc
	_, child, p := next_child(q.r, &f.walk, .Group)
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
	if f.only != NO_DEMAND {
		if p != .Found {
			query_unread(q, f.only, at, .Not_Loaded, 2 * u64(f.walk.next) - 1) or_return
		} else if !slice.contains(q.picks[:], f.only) {
			query_push(q, &q.picks, f.only) or_return
		}
	} else {
		for n in q.live[f.live:][:f.n_live] {
			dn := &dm.nodes[n]
			for &e in dm.edges[dn.edges:][:dn.n_edges] {
				takes := false
				#partial switch s in e.step {
				case All:
					takes = all_takes(s.limit, index, object, q.dups)
				case Slice:
					if !object {
						if f.count < 0 {
							// The count is not known, so no element is known to be taken or not.
							if index == 0 {
								query_unread(q, e.to, at, .Not_Loaded, 2 * u64(at)) or_return
							}
							continue
						}
						takes = slice_takes(s, index, u64(f.count))
					}
				}
				if !takes {
					continue
				}
				if p != .Found {
					// A child not kept lies after the children before it and before the next one kept.
					query_unread(q, e.to, at, .Not_Loaded, 2 * u64(f.walk.next) - 1) or_return
				} else if !slice.contains(q.picks[:], e.to) {
					query_push(q, &q.picks, e.to) or_return
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
	destroy_children(&f.walk)
	f.walks, f.next = false, 0
}

// Closes the frame on top, which has no child left.
@(private)
query_close :: proc(q: ^Query) {
	f := pop(&q.frames)
	if f.walks {
		destroy_children(&f.walk)
	}
	query_cut(&q.live, f.live)
	query_cut(&q.pairs, f.pairs)
}

// Gives each path ending under demand node `to` its failure at the value `at`, which its step at `depth` steps from the
// root cannot enter, or at the container `at` that lacks the child its step takes, as `scan` gives it. With `null` the
// value is null or missing, read as `.Missing` past the path's last `All` and as `.Wrong_Kind` before it. A path past a
// `Descend` gives no answer.
@(private)
query_fail :: proc(q: ^Query, to: u32, null: bool, depth: u64, at, owner: Node_Index, pos: u64) -> runtime.Allocator_Error #no_bounds_check {
	dm := q.demand
	if dm.nodes[to].deep {
		return nil
	}
	for m in to ..= dm.nodes[to].last {
		dn := &dm.nodes[m]
		for p in dm.ends[dn.ends:][:dn.n_ends] {
			missing := null && path_refused(depth, u64(dm.paths[p].alls_end)) == .Missing
			holder := owner if missing && owner != NO_NODE else at
			query_answer(q, holder, p, .Missing if missing else .Wrong_Kind, pos) or_return
		}
	}
	return nil
}

// Gives each path ending under demand node `to` the outcome `p` at the container `at`, whose child the readers could
// not take, placed at `pos`.
@(private)
query_unread :: proc(q: ^Query, to: u32, at: Node_Index, p: Presence, pos: u64) -> runtime.Allocator_Error #no_bounds_check {
	dm := q.demand
	for m in to ..= dm.nodes[to].last {
		dn := &dm.nodes[m]
		for x in dm.ends[dn.ends:][:dn.n_ends] {
			query_answer(q, at, x, p, pos) or_return
		}
	}
	return nil
}

// Answers `path` at `node`, placed at `pos`: twice a node's index, or one less for a place just before that node.
@(private)
query_answer :: #force_inline proc(q: ^Query, node: Node_Index, path: u32, outcome: Presence, pos: u64) -> runtime.Allocator_Error {
	a := Query_Answer{node, path, Node_Index((pos + 1) / 2), outcome, pos & 1 != 0}
	if n := len(q.answers); n > 0 && query_answer_before(a, q.answers[n - 1]) {
		q.unsorted = true
	}
	return query_push(q, &q.answers, a)
}

// Whether the node `at` of `doc` holds what `grain` keeps of it: every node under it for `.Whole`, and its keys or its
// count for `.Keys`. A document of every value holds all of it.
@(private)
query_holds :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index, grain: Grain) -> bool {
	return doc.partial == nil || query_partial_holds(doc, at, grain)
}

@(private)
query_partial_holds :: proc "contextless" (doc: ^Document, at: Node_Index, grain: Grain) -> bool #no_bounds_check {
	node := doc.nodes[at]
	if node.kind != .Array && node.kind != .Object {
		return true
	}
	switch grain {
	case .Whole:
		for k in at ..< at + Node_Index(node.n) {
			if t := doc.nodes[k]; t.kind > .Plain && t.spelling & CONTAINER_PARTIAL != 0 {
				return false
			}
		}
	case .Keys:
		return node.spelling & CONTAINER_PARTIAL == 0 || node.kind == .Array && child_count(doc, at, node) >= 0
	case .Exists:
	}
	return true
}

// The document of the query's answers: each path's in document order, up to its limit, in one block with the starts,
// over the nodes, kept children and missing names of the document read.
@(private)
query_document :: proc(q: ^Query) -> (Document, Error) {
	dm := q.demand
	doc := q.r.doc
	answers := q.answers[:]
	if q.unsorted {
		slice.stable_sort_by(answers, query_answer_before)
	}
	paths := len(dm.paths)
	x: ^Partial
	starts_at := size_of(Partial)
	answers_at := starts_at + (paths + 1) * size_of(u32)
	answers_at = (answers_at + align_of(Answer) - 1) &~ (align_of(Answer) - 1)
	size := answers_at + len(answers) * size_of(Answer)
	block, berr := runtime.mem_alloc_non_zeroed(size, align_of(Partial), q.allocator)
	if berr == nil && (len(block) < size || raw_data(block) == nil) {
		berr = .Out_Of_Memory
	}
	if berr != nil {
		return {}, berr
	}
	x = (^Partial)(raw_data(block))
	x^ = {dups = q.dups}
	if doc.partial != nil {
		x.kept, x.missing, x.names, x.dups = doc.partial.kept, doc.partial.missing, doc.partial.names, doc.partial.dups
	}
	x.starts = ([^]u32)(raw_data(block[starts_at:]))[:paths + 1]
	all := ([^]Answer)(raw_data(block[answers_at:]))[:len(answers)]
	runtime.mem_zero(raw_data(x.starts), len(x.starts) * size_of(u32))
	if paths == 1 {
		limit := dm.paths[0].limit
		n := len(answers) if limit == 0 else min(len(answers), int(limit))
		for a, i in answers[:n] {
			all[i] = {a.node, a.outcome}
		}
		x.starts[1], x.answers = u32(n), all[:n]
		return query_result(q, x), nil
	}
	// A path keeps its first answers in document order, up to its limit.
	for a in answers {
		limit := dm.paths[a.path].limit
		if limit == 0 || x.starts[a.path + 1] < limit {
			x.starts[a.path + 1] += 1
		}
	}
	for p in 0 ..< paths {
		x.starts[p + 1] += x.starts[p]
	}
	// Where each path's next answer goes, in the list of live nodes the finished walk left empty.
	query_cut(&q.live, 0)
	for p in 0 ..< paths {
		if e := query_push(q, &q.live, x.starts[p]); e != nil {
			free(raw_data(block), q.allocator)
			return {}, e
		}
	}
	placed := q.live[:]
	for a in answers {
		if placed[a.path] < x.starts[a.path + 1] {
			all[placed[a.path]] = {a.node, a.outcome}
			placed[a.path] += 1
		}
	}
	x.answers = all[:x.starts[paths]]
	return query_result(q, x), nil
}

// The document over the nodes of the document read that holds the answers `x`.
@(private)
query_result :: proc(q: ^Query, x: ^Partial) -> Document {
	result := q.r.doc^
	result.partial, result.allocator = x, q.allocator
	result.flags = result.flags - {.Owns_Src} + {.Borrowed}
	return result
}

@(private)
query_answer_before :: proc(a, b: Query_Answer) -> bool {
	if a.place != b.place {
		return a.place < b.place
	}
	return a.before && !b.before || a.before == b.before && a.path < b.path
}

@(private)
query_free :: proc(q: ^Query) {
	for &f in q.frames {
		if f.walks {
			destroy_children(&f.walk)
		}
	}
	for list in ([]^runtime.Raw_Dynamic_Array{(^runtime.Raw_Dynamic_Array)(&q.answers), (^runtime.Raw_Dynamic_Array)(&q.frames), (^runtime.Raw_Dynamic_Array)(&q.live), (^runtime.Raw_Dynamic_Array)(&q.picks), (^runtime.Raw_Dynamic_Array)(&q.pairs)}) {
		if !query_in_room(q, list.data) {
			runtime.mem_free(list.data, list.allocator)
		}
	}
}
