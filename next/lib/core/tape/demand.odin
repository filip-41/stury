package tape

import "base:runtime"

// The paths a read keeps, as a trie of their steps: a node per prefix the paths share, the root first and each node's
// descendants right after it. Its names borrow the paths' strings.
Demand :: struct {
	nodes:     []Demand_Node,
	edges:     []Demand_Edge,
	ends:      []u32, // the paths each node ends, ascending within a node
	paths:     []Demand_Path, // one per path, in the order `demand_of` was given them
	reach:     u64, // the greatest depth a path can settle at (`repeats`, or `length` when limited)
	limited:   bool, // some path has a `limit`
	deep:      bool, // some path has a `Descend` step
	facts:     bool, // the read keeps the facts of the nodes it keeps, as a build does
	allocator: runtime.Allocator,
}

@(private = "file")
Demand_Node_Flag :: enum u8 { Alls, Others, Whole, Keys, Slices, Sliced, Deep, Bounded }

@(private = "file")
Demand_Node_Flags :: bit_set[Demand_Node_Flag; u8]

// A prefix of some paths: the steps that go on from it and the paths it ends. Common and object fields fit in the first
// 64-byte cache line; array-only fields (`neg`, `fills`, `places`) sit in the second.
// `flags`: `.Alls` has `All`; `.Others` has `All`, non-negative `Index`, or from-start `Slice`; `.Whole`/`.Keys` grain
// of ended paths (`.Whole` wins); `.Slices`/`.Sliced` has from-end/any `Slice`; `.Deep` reached via `Descend`;
// `.Bounded` has limited `All` or non-universal from-start `Slice`.
@(private = "file")
Demand_Node :: struct {
	edges, n_edges: u32, // its edges in `Demand.edges`
	ends, n_ends:   u32, // the paths it ends in `Demand.ends`
	descend, last:  u32, // `descend`: node its `Descend` leads to (0 for none); `last`: its last descendant
	names, indexes: u32, // how many `Name` steps it has, and how many `Index` steps
	lengths:        u64, // a bit per length its `Name` steps have, past 63 counted from 0
	heads:          u64, // a bit per first byte its `Name` steps have, by the byte's low six bits
	tails:          u64, // a bit per last byte its `Name` steps have, by the byte's low six bits
	flags:          Demand_Node_Flags,
	neg:            u64, // the furthest back a negative `Index` or `Slice` end of it reaches, else 0
	fills:          u64, // the fewest elements an array has for each of its `Index` steps to take one
	places:         u64, // a bit per element below 64 one of its `Index` steps takes
}

#assert(size_of(Demand_Node) == 88 && offset_of(Demand_Node, flags) < 64 && offset_of(Demand_Node, neg) == 64)

// A step from a node to the node of the longer prefix.
@(private = "file")
Demand_Edge :: struct {
	step: Step,
	to:   u32,
}

// The data a read needs of one path beyond its steps.
@(private)
Demand_Path :: struct {
	alls_end:   u32, // one past its last `All` step, 0 for none
	// The index of its first step that can take more than one child (`All`, negative `Index`, `Slice`, or `Descend`), else its length.
	repeats:    u32,
	named:      u32, // the index of its first `Name` step, else its length
	length:     u32, // its steps
	limit:      u32, // the most answers it keeps, the first in document order, 0 for every one
	// The index of its first step from the end, a negative `Index` or a `Slice` with an end from the end, which takes
	// back the answers of elements it passes, or of a `Descend`, else its length.
	takes_back: u32,
	grain:      Grain, // what it keeps of each value it ends at
}

// Whether every step of `d` from the root is an `All` with no limit, so the root's children are all reached by the same
// steps. False for a demand with no path.
@(require_results)
demand_children_alike :: proc "contextless" (d: ^Demand) -> bool {
	if len(d.nodes) == 0 || d.nodes[0].n_edges == 0 {
		return false
	}
	root := d.nodes[0]
	for e in d.edges[root.edges:][:root.n_edges] {
		if all, ok := e.step.(All); !ok || all.limit > 0 {
			return false
		}
	}
	return true
}

// The demand of `paths`, whose answers are path `i`'s for `paths[i]`, keeping `grains[i]` of its values, every
// value whole past the end of `grains`, and the first `limits[i]` of its answers in document order, every one for <= 0
// or past the end of `limits`, as jq's `first(f)` and `limit(n; f)` read. With `facts` a read keeps the facts of the
// nodes it keeps. Two paths with a common prefix share its nodes, and the same path twice ends at one node twice.
@(require_results)
demand_of :: proc(paths: [][]Step, grains: []Grain = nil, limits: []int = nil, facts := false, allocator := context.allocator) -> (d: Demand, err: runtime.Allocator_Error) {
	Grown :: struct {
		edges: [dynamic]Demand_Edge,
		ends:  [dynamic]u32,
	}
	push :: proc(s: ^[dynamic]$T, v: T) -> runtime.Allocator_Error {
		n, perr := append(s, v)
		return perr if perr != nil else nil if n > 0 else .Out_Of_Memory
	}
	grown := make([dynamic]Grown, allocator)
	defer {
		for &g in grown {
			delete(g.edges)
			delete(g.ends)
		}
		delete(grown)
	}
	push(&grown, Grown{make([dynamic]Demand_Edge, allocator), make([dynamic]u32, allocator)}) or_return
	n_edges := 0
	for path, p in paths {
		at := 0
		next: for step in path {
			for e in grown[at].edges {
				if e.step == step {
					at = int(e.to)
					continue next
				}
			}
			push(&grown, Grown{make([dynamic]Demand_Edge, allocator), make([dynamic]u32, allocator)}) or_return
			push(&grown[at].edges, Demand_Edge{step, u32(len(grown) - 1)}) or_return
			// Each node a `Descend` leads to also gets an `All` edge to itself.
			_, descends := step.(Descend)
			n_edges += 1 + int(descends)
			at = len(grown) - 1
		}
		push(&grown[at].ends, u32(p)) or_return
	}
	// Preorder numbers, so the nodes under a node follow it.
	n_nodes := len(grown)
	scratch, serr := make([]u32, 3 * n_nodes, allocator)
	if serr != nil || len(scratch) < 3 * n_nodes || raw_data(scratch) == nil {
		delete(scratch, allocator)
		return {}, serr if serr != nil else .Out_Of_Memory
	}
	defer delete(scratch, allocator)
	order, renumber, stack := scratch[:n_nodes], scratch[n_nodes:2 * n_nodes], scratch[2 * n_nodes:]
	top, ord := 1, 0
	stack[0] = 0
	for top > 0 {
		top -= 1
		n := stack[top]
		renumber[n], order[ord] = u32(ord), n
		ord += 1
		#reverse for e in grown[n].edges {
			stack[top] = e.to
			top += 1
		}
	}
	// One block holds nodes, edges, paths and ends in descending alignment order (8, 8, 4, 4), freed whole by `destroy_demand`.
	nb, eb, pb := n_nodes * size_of(Demand_Node), n_edges * size_of(Demand_Edge), len(paths) * size_of(Demand_Path)
	total := nb + eb + pb + len(paths) * size_of(u32)
	raw, rerr := runtime.mem_alloc(total, align_of(Demand_Node), allocator)
	if rerr != nil || len(raw) < total || raw_data(raw) == nil {
		runtime.mem_free_bytes(raw, allocator)
		return {}, rerr if rerr != nil else .Out_Of_Memory
	}
	base := raw_data(raw)
	d = {
		nodes = ([^]Demand_Node)(base)[:n_nodes], edges = ([^]Demand_Edge)(base[nb:])[:n_edges],
		paths = ([^]Demand_Path)(base[nb + eb:])[:len(paths)], ends = ([^]u32)(base[nb + eb + pb:])[:len(paths)],
		facts = facts, allocator = allocator,
	}
	ne, nd := 0, 0
	for old, i in order {
		g := grown[old]
		// A node's parent, which comes first, marks it `.Deep`, and a `Descend` it leads to with a `descend` of `max(u32)`.
		deep, target := .Deep in d.nodes[i].flags, d.nodes[i].descend == max(u32)
		n := &d.nodes[i]
		n^ = {edges = u32(ne), n_edges = u32(len(g.edges)) + u32(target), ends = u32(nd), n_ends = u32(len(g.ends)), last = u32(i), flags = {.Deep} if deep else {}}
		for e in g.edges {
			to := renumber[e.to]
			d.edges[ne] = {e.step, to}
			ne += 1
			_, descends := e.step.(Descend)
			d.nodes[to].flags += {.Deep} if deep || descends else {}
			if descends {
				n.descend, d.nodes[to].descend = to, max(u32)
			}
		}
		if target {
			d.edges[ne] = {All{}, u32(i)}
			ne += 1
		}
		copy(d.ends[nd:], g.ends[:])
		nd += len(g.ends)
		for p in g.ends {
			grain := grains[p] if int(p) < len(grains) else .Whole
			n.flags += {.Whole} if grain == .Whole else {.Keys} if grain == .Keys else {}
		}
		n.flags -= {.Keys} if .Whole in n.flags else {}
		fill_node_masks(n, d.edges[n.edges:][:n.n_edges])
	}
	#reverse for &n in d.nodes {
		for e in d.edges[n.edges:][:n.n_edges] {
			n.last = max(n.last, d.nodes[e.to].last)
		}
	}
	fill_path_meta(&d, paths, grains, limits)
	return
}

@(private = "file")
fill_node_masks :: proc "contextless" (n: ^Demand_Node, edges: []Demand_Edge) {
	for e in edges {
		#partial switch step in e.step {
		case Index:
			n.indexes += 1
			reach := step_reach(step)
			n.flags += {.Others} if step >= 0 else {}
			n.fills = max(n.fills, u64(step) + 1 if step >= 0 else reach)
			if step >= 0 && step < 64 {
				n.places |= 1 << uint(step)
			}
			n.neg = max(n.neg, reach)
		case All:
			n.flags += {.Others, .Alls} + ({.Bounded} if step.limit > 0 else {})
		case Slice:
			// A slice from the end takes only elements a ring holds, as a negative `Index` does.
			reach := step_reach(step)
			n.neg = max(n.neg, reach)
			n.flags += {.Sliced} + ({.Others} if step.lo >= 0 else {}) + ({.Slices} if reach > 0 else {.Bounded} if step.lo > 0 || slice_cut(step) < max(u64) else {})
		case Name:
			n.names += 1
			n.lengths |= 1 << (uint(len(step)) & 63)
			if len(step) > 0 {
				n.heads |= 1 << (string(step)[0] & 63)
				n.tails |= 1 << (string(step)[len(step) - 1] & 63)
			}
		}
	}
}

@(private = "file")
fill_path_meta :: proc "contextless" (d: ^Demand, paths: [][]Step, grains: []Grain, limits: []int) {
	for path, p in paths {
		x := Demand_Path{repeats = u32(len(path)), named = u32(len(path)), length = u32(len(path)), takes_back = u32(len(path)), grain = grains[p] if p < len(grains) else .Whole}
		for step, i in path {
			// `repeats` and `takes_back` read a `Name` as `.First` does, which takes one member and none back.
			// `path_settles` and `path_final` add the policy's own reading.
			if !step_takes_one(step, .First) {
				x.repeats = min(x.repeats, u32(i))
			}
			_, descends := step.(Descend)
			// An answer under a `Descend` is final once the walk leaves the value the `Descend` starts at, as a value
			// inside it may come after the answers a limit holds.
			if step_replaces(step, .First) || descends {
				x.takes_back = min(x.takes_back, u32(i))
			}
			d.deep ||= descends
			#partial switch _ in step {
			case All:
				x.alls_end = u32(i + 1)
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
}

// Frees what `demand_of` allocated and leaves `d` zero.
destroy_demand :: proc(d: ^Demand) {
	free(raw_data(d.nodes), d.allocator)
	d^ = {}
}
