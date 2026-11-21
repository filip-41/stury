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
	allocator: runtime.Allocator,
}

// A prefix of some paths: the steps that go on from it and the paths it ends.
Demand_Node :: struct {
	edges, n_edges: u32, // its edges in `Demand.edges`
	ends, n_ends:   u32, // the paths it ends in `Demand.ends`
	last:           u32, // its last descendant, so the nodes under it are those up to `last`
	depth:          u32, // the steps from the root
	lengths:        u64, // a bit per length its `Name` steps have, past 63 counted from 0
	heads:          u64, // a bit per first byte its `Name` steps have, by the byte's low six bits
	neg:            u64, // the furthest back a negative `Index` step of it reaches, else 0
	names, indexes: u32, // how many `Name` and `Index` steps it has
	alls:           bool, // it has an `All` step
	others:         bool, // it has an `All` or a non-negative `Index` step
}

// A step from a node to the node of the longer prefix.
Demand_Edge :: struct {
	step: Step,
	to:   u32,
}

// What a read needs of one path past its steps.
Demand_Path :: struct {
	alls_end: u32, // one past its last `All` step, 0 for none
	// The index of its first step that can take more than one child, an `All` or a negative `Index`, else its length.
	repeats:  u32,
	named:    u32, // the index of its first `Name` step, else its length
}

// The demand of `paths`, whose answers name path `i` as `Answer.path` `i`. Two paths with a common prefix share its
// nodes, and the same path twice ends at one node twice.
@(require_results)
demand_of :: proc(paths: [][]Step, allocator := context.allocator) -> (d: Demand, err: runtime.Allocator_Error) {
	Grown :: struct {
		edges: [dynamic]Demand_Edge,
		ends:  [dynamic]u32,
		depth: u32,
	}
	grown := make([dynamic]Grown, 1, allocator) or_return
	grown[0] = {make([dynamic]Demand_Edge, allocator), make([dynamic]u32, allocator), 0}
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
			append(&grown, Grown{make([dynamic]Demand_Edge, allocator), make([dynamic]u32, allocator), grown[at].depth + 1}) or_return
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
	renumber := make([]u32, len(grown), allocator) or_return
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
	d.allocator = allocator
	defer if err != nil {
		destroy_demand(&d)
	}
	d.nodes = make([]Demand_Node, len(grown), allocator) or_return
	d.edges = make([]Demand_Edge, n_edges, allocator) or_return
	d.ends = make([]u32, n_ends, allocator) or_return
	d.paths = make([]Demand_Path, len(paths), allocator) or_return
	ne, nd := 0, 0
	for old, i in order {
		g := grown[old]
		d.nodes[i] = {edges = u32(ne), n_edges = u32(len(g.edges)), ends = u32(nd), n_ends = u32(len(g.ends)), last = u32(i), depth = g.depth}
		for e in g.edges {
			d.edges[ne] = {e.step, renumber[e.to]}
			ne += 1
		}
		copy(d.ends[nd:], g.ends[:])
		nd += len(g.ends)
	}
	for &n in d.nodes {
		for e in d.edges[n.edges:][:n.n_edges] {
			#partial switch step in e.step {
			case Index:
				n.indexes += 1
				if step < 0 {
					n.neg = max(n.neg, u64(-step))
				} else {
					n.others = true
				}
			case All:
				n.others, n.alls = true, true
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
		x := Demand_Path{0, u32(len(path)), u32(len(path))}
		for step, i in path {
			switch s in step {
			case All:
				x.alls_end = u32(i + 1)
				x.repeats = min(x.repeats, u32(i))
			case Index:
				if s < 0 {
					x.repeats = min(x.repeats, u32(i))
				}
			case Name:
				x.named = min(x.named, u32(i))
			}
		}
		d.paths[p] = x
		d.reach = max(d.reach, u64(x.repeats))
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
