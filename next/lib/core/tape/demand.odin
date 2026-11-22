package tape

import "base:runtime"

// The paths a read keeps, as a trie of their steps: a node per prefix the paths share, the root first and each node's
// descendants right after it. Its names borrow the paths' strings.
Demand :: struct {
	nodes:     []Demand_Node,
	edges:     []Demand_Edge,
	ends:      []u32, // the paths each node ends, ascending within a node
	paths:     []Demand_Path, // one per path, in the order `demand_of` was given them
	reach:     u64, // the greatest `Demand_Path.repeats`, past which no path settles
	limited:   bool, // some path has a `limit`
	facts:     bool, // the read keeps the facts of the nodes it keeps, as a build does
	allocator: runtime.Allocator,
}

// A prefix of some paths: the steps that go on from it and the paths it ends.
@(private)
Demand_Node :: struct {
	edges, n_edges: u32, // its edges in `Demand.edges`
	ends, n_ends:   u32, // the paths it ends in `Demand.ends`
	last:           u32, // its last descendant, so the nodes under it are those up to `last`
	lengths:        u64, // a bit per length its `Name` steps have, past 63 counted from 0
	heads:          u64, // a bit per first byte its `Name` steps have, by the byte's low six bits
	neg:            u64, // the furthest back a negative `Index` or `Slice` end of it reaches, else 0
	names, indexes: u32, // how many `Name` steps it has, and how many `Index` steps
	// The elements from `takes_from` up to `takes_to` are those all its `Slice` steps from the start and `All` steps with
	// a limit take, every element for none.
	takes_from:     u64,
	takes_to:       u64,
	alls:           bool, // it has an `All` step
	others:         bool, // it has an `All`, a non-negative `Index` step, or a `Slice` from the start
	whole:          bool, // it ends a path whose grain is `.Whole`
	keys:           bool, // it ends a path whose grain is `.Keys`, and none whose grain is `.Whole`
	slices:         bool, // it has a `Slice` step with an end from the end
}

// A step from a node to the node of the longer prefix.
@(private)
Demand_Edge :: struct {
	step: Step,
	to:   u32,
}

// The data a read needs of one path beyond its steps.
@(private)
Demand_Path :: struct {
	alls_end: u32, // one past its last `All` step, 0 for none
	// The index of its first step that can take more than one child, an `All` or a negative `Index`, else its length.
	repeats:  u32,
	named:    u32, // the index of its first `Name` step, else its length
	length:   u32, // its steps
	limit:    u32, // the most answers it keeps, the first in document order, 0 for every one
	// The index of its first step from the end, a negative `Index` or a `Slice` with an end from the end, which takes
	// back the answers of elements it passes, else its length.
	takes_back: u32,
}

// The demand of `paths`, whose answers are path `i`'s for `paths[i]`, keeping `grains[i]` of its values, every
// value whole past the end of `grains`, and the first `limits[i]` of its answers in document order, every one for 0
// or past the end of `limits`, as jq's `first(f)` and `limit(n; f)` read. With `facts` a read keeps the facts of the
// nodes it keeps. Two paths with a common prefix share its nodes, and the same path twice ends at one node twice.
@(require_results)
demand_of :: proc(paths: [][]Step, grains: []Grain = nil, limits: []int = nil, facts := false, allocator := context.allocator) -> (d: Demand, err: runtime.Allocator_Error) {
	Grown :: struct {
		edges: [dynamic]Demand_Edge,
		ends:  [dynamic]u32,
	}
	grown, gerr := make([dynamic]Grown, 1, allocator)
	if e := block(grown[:], gerr, 1); e != nil {
		return {}, e
	}
	grown[0] = {make([dynamic]Demand_Edge, allocator), make([dynamic]u32, allocator)}
	defer {
		for &g in grown {
			delete(g.edges)
			delete(g.ends)
		}
		delete(grown)
	}
	n_edges, n_ends := 0, 0
	for path, p in paths {
		at := 0
		next: for step in path {
			for e in grown[at].edges {
				if e.step == step {
					at = int(e.to)
					continue next
				}
			}
			append(&grown, Grown{make([dynamic]Demand_Edge, allocator), make([dynamic]u32, allocator)}) or_return
			append(&grown[at].edges, Demand_Edge{step, u32(len(grown) - 1)}) or_return
			n_edges += 1
			at = len(grown) - 1
		}
		append(&grown[at].ends, u32(p)) or_return
		n_ends += 1
	}
	// Preorder numbers, so the nodes under a node follow it.
	order := make([dynamic]u32, 0, len(grown), allocator) or_return
	defer delete(order)
	renumber, rerr := make([]u32, len(grown), allocator)
	if e := block(renumber, rerr, len(grown)); e != nil {
		return {}, e
	}
	defer delete(renumber, allocator)
	stack := make([dynamic]u32, allocator) or_return
	defer delete(stack)
	append(&stack, 0) or_return
	for len(stack) > 0 {
		n := pop(&stack)
		renumber[n] = u32(len(order))
		append(&order, n) or_return
		#reverse for e in grown[n].edges {
			append(&stack, e.to) or_return
		}
	}
	d.allocator, d.facts = allocator, facts
	// On an error, frees what is held so far and returns an empty demand. A defer would free blocks that the
	// result value, already copied, points at.
	free :: proc(d: ^Demand, e: runtime.Allocator_Error) -> (Demand, runtime.Allocator_Error) {
		destroy_demand(d)
		return {}, e
	}
	block :: proc(s: []$T, e: runtime.Allocator_Error, want: int) -> runtime.Allocator_Error {
		// An empty allocator gives no block and no error, or a shorter one, either read as a refusal.
		if e != nil || len(s) < want || (want > 0 && raw_data(s) == nil) {
			return e if e != nil else .Out_Of_Memory
		}
		return nil
	}
	if d.nodes, err = make([]Demand_Node, len(grown), allocator); block(d.nodes, err, len(grown)) != nil {
		return free(&d, block(d.nodes, err, len(grown)))
	}
	if d.edges, err = make([]Demand_Edge, n_edges, allocator); block(d.edges, err, n_edges) != nil {
		return free(&d, block(d.edges, err, n_edges))
	}
	if d.ends, err = make([]u32, n_ends, allocator); block(d.ends, err, n_ends) != nil {
		return free(&d, block(d.ends, err, n_ends))
	}
	if d.paths, err = make([]Demand_Path, len(paths), allocator); block(d.paths, err, len(paths)) != nil {
		return free(&d, block(d.paths, err, len(paths)))
	}
	ne, nd := 0, 0
	for old, i in order {
		g := grown[old]
		d.nodes[i] = {edges = u32(ne), n_edges = u32(len(g.edges)), ends = u32(nd), n_ends = u32(len(g.ends)), last = u32(i), takes_to = max(u64)}
		for e in g.edges {
			d.edges[ne] = {e.step, renumber[e.to]}
			ne += 1
		}
		copy(d.ends[nd:], g.ends[:])
		nd += len(g.ends)
		n := &d.nodes[i]
		for p in g.ends {
			grain := grains[p] if int(p) < len(grains) else .Whole
			n.whole ||= grain == .Whole
			n.keys ||= grain == .Keys
		}
		n.keys &&= !n.whole
	}
	for &n in d.nodes {
		for e in d.edges[n.edges:][:n.n_edges] {
			#partial switch step in e.step {
			case Index:
				n.indexes += 1
				n.others ||= step >= 0
				n.neg = max(n.neg, step_reach(step))
			case All:
				n.others, n.alls = true, true
				if step.limit > 0 {
					n.takes_to = min(n.takes_to, u64(step.limit))
				}
			case Slice:
				// A slice from the end takes only elements a ring holds, as a negative `Index` does.
				n.others ||= step.lo >= 0
				n.neg = max(n.neg, step_reach(step))
				if step_reach(step) > 0 {
					n.slices = true
				} else {
					n.takes_from = max(n.takes_from, u64(step.lo))
					n.takes_to = min(n.takes_to, slice_cut(step))
				}
			case Name:
				n.names += 1
				n.lengths |= 1 << (uint(len(step)) & 63)
				if len(step) > 0 {
					n.heads |= 1 << (string(step)[0] & 63)
				}
			}
		}
	}
	#reverse for &n in d.nodes {
		for e in d.edges[n.edges:][:n.n_edges] {
			n.last = max(n.last, d.nodes[e.to].last)
		}
	}
	for path, p in paths {
		x := Demand_Path{alls_end = 0, repeats = u32(len(path)), named = u32(len(path)), length = u32(len(path)), takes_back = u32(len(path))}

		for step, i in path {
			switch s in step {
			case All:
				x.alls_end = u32(i + 1)
				x.repeats = min(x.repeats, u32(i))
			case Index:
				if s < 0 {
					x.repeats = min(x.repeats, u32(i))
					x.takes_back = min(x.takes_back, u32(i))
				}
			case Slice:
				x.repeats = min(x.repeats, u32(i))
				if step_reach(s) > 0 {
					x.takes_back = min(x.takes_back, u32(i))
				}
			case Name:
				x.named = min(x.named, u32(i))
			}
		}
		d.reach = max(d.reach, u64(x.repeats))
		if p < len(limits) && limits[p] > 0 {
			// A path's limit settles it at any depth its answers are final at.
			x.limit = u32(min(u64(limits[p]), u64(max(u32))))
			d.limited = true
			d.reach = max(d.reach, u64(len(path)))
		}
		d.paths[p] = x
	}
	return
}

// Frees what `demand_of` allocated and leaves `d` zero.
destroy_demand :: proc(d: ^Demand) {
	delete(d.nodes, d.allocator)
	delete(d.edges, d.allocator)
	delete(d.ends, d.allocator)
	delete(d.paths, d.allocator)
	d^ = {}
}
