package write

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"

// The walk over a document's values that a tree format's writer spells: `tree_next` gives each value, container open
// and container close in text order, with its key, its depth and the facts on it, and the writer lays them out. It is
// compiled per document shape, `FACTS` for one whose facts the target holds, `TABLES` for one with tables, whose rows
// name their cells by the header's keys, so a plain document's walk tests neither.

// What a step of the walk is.
@(private)
Step_Kind :: enum u8 {
	Scalar,
	Open,
	Close,
	Done, // the value is written, or `Tree.err` says why the walk stopped
}

// One step of the walk.
Step :: struct {
	facts: []tape.Fact, // with `FACTS`, the facts on the node, for a close those of the container
	node:  tape.Node_Index, // the value, or the container that opens or closes
	key:   tape.Node_Index, // the member's key, `NO_NODE` for an element and the root
	depth: int, // the containers around the value: 0 for the written value itself
	kind:  Step_Kind,
	// For a value, the first child of its container. For a close, the container had no child.
	first: bool,
	// The value is a cell of a table's row, which has no key node: its key is `Tree.cell`.
	cell:  bool,
}

// The levels a walk keeps in itself. Past them its stack comes from the write's allocator.
@(private)
FRAME_ROOM :: 64
#assert(FRAME_ROOM > 0, "the stack doubles as it grows")

// A container the walk is inside.
@(private)
Frame :: struct {
	node:     tape.Node_Index,
	end:      tape.Node_Index, // one past its subtree
	children: u32, // the children written
	facts_lo: u32, // its facts, `Tree.facts[facts_lo:][:facts_n]`
	facts_n:  u32,
	object:   bool,
	// Under `sort_keys` its members are `Tree.pairs[pairs_lo:]`, in the order they are written.
	sorted:   bool,
	pairs_lo: u32,
}

// A member of an object written under `sort_keys`, by its key's text, which `owned` says the walk cloned.
@(private)
Pair :: struct {
	name:  string,
	key:   tape.Node_Index, // `NO_NODE` for a table row's cell, whose key is `cell`
	cell:  tape.Token,
	value: tape.Node_Index,
	owned: bool,
}

// The state of a walk, which `tree_start` sets and `tree_end` frees. It is not copied once started, as its stack starts
// in `room`.
Tree :: struct {
	doc:       ^tape.Document,
	nodes:     [^]tape.Node,
	i:         tape.Node_Index, // the next node
	end:       tape.Node_Index, // one past the written value's subtree
	depth:     int,
	frames:    [^]Frame,
	held:      int, // the frames `frames` holds
	facts:     []tape.Fact,
	fact:      int, // the first fact not yet given or dropped
	first:     int, // the first fact of the written value
	holds:     tape.Facts, // the kinds the target writes
	dropped:   tape.Facts,
	reader:    tape.Reader,
	row:       tape.Children, // the cells of the open row of a table, while `in_row`
	in_row:    bool,
	cell:      tape.Token, // the key of the cell of the last step that has `cell`
	scratch:   []u8, // decoded texts, from `allocator`
	// Under `sort_keys`, the members of the open objects, each object's above its parent's. The members leave text
	// order, so a node's facts are found by its index.
	sort_keys:    bool,
	length_first: bool, // with `sort_keys`, a shorter key first, as CBOR orders text keys
	no_dups:      bool, // with `sort_keys`, a repeated key in an object is `Refused{.No_Spelling}`
	pairs:        [dynamic]Pair,
	allocator: runtime.Allocator,
	err:       Error,
	room:      [FRAME_ROOM]Frame,
}

// Starts a walk over the value `opts.node` of `doc` for a target that writes facts of the kinds `holds`. The facts of
// other kinds the document holds are dropped from the start.
tree_start :: proc(w: ^Tree, doc: ^tape.Document, opts: Options, holds: tape.Facts, allocator: runtime.Allocator) -> Error {
	// A text cut inside its root left out a scalar it cut and closed its open containers, which hold their subtrees to
	// the root's end: a value that ends there may be one, and would be written as less than the text holds.
	if .Cut in doc.flags && (len(doc.nodes) == 0 || int(opts.node) < len(doc.nodes) && doc.nodes[opts.node].kind > .Plain && tape.node_after(doc, opts.node) == tape.node_after(doc, tape.ROOT)) {
		return Refused{opts.node, .Partial}
	}
	if int(opts.node) >= len(doc.nodes) || doc.nodes[opts.node].role != .Value {
		return tape.Bad_Option{"node"}
	}
	w.doc, w.nodes, w.allocator = doc, raw_data(doc.nodes), allocator
	w.i, w.end, w.depth = opts.node, tape.node_after(doc, opts.node), 0
	w.frames, w.held = &w.room[0], FRAME_ROOM
	w.facts, w.fact, w.holds = doc.facts, 0, holds
	w.dropped = doc.present - holds
	w.reader = {doc, nil}
	w.in_row, w.scratch, w.err = false, nil, nil
	w.sort_keys, w.pairs = opts.sort_keys, make([dynamic]Pair, allocator)
	if opts.node != tape.ROOT {
		w.fact = facts_from(doc.facts, opts.node, 0)
		// A subtree drops only the kinds its own facts hold.
		w.dropped = {}
		for k := w.fact; k < len(doc.facts) && doc.facts[k].node < w.end; k += 1 {
			w.dropped += {doc.facts[k].kind}
		}
		w.dropped -= holds
	}
	w.first = w.fact
	return nil
}

// Whether the walk takes the `FACTS` variant: the target writes a kind of fact the document holds.
tree_facts :: #force_inline proc "contextless" (w: ^Tree) -> bool {
	return w.doc.present & w.holds != {}
}

// Whether the walk takes the `TABLES` variant: the document holds tables, whose rows hold no keys.
tree_tables :: #force_inline proc "contextless" (w: ^Tree) -> bool {
	if w.doc.ext == nil {
		return false
	}
	_, tabular := w.doc.ext.format.(tape.Tabular_Ext)
	return tabular
}

// Frees what the walk holds and returns the fact kinds it dropped: those the target does not write, and those it does
// on a node the walk gave no step, as on a key, or that its writer dropped.
tree_end :: proc(w: ^Tree) -> tape.Facts {
	free_stack(w.frames, w.held, FRAME_ROOM, w.allocator)
	if w.scratch != nil {
		delete(w.scratch, w.allocator)
	}
	if w.in_row {
		tape.destroy_children(&w.row)
	}
	pairs_drop(w, 0)
	delete(w.pairs)
	if w.sort_keys {
		// Every node but a key is a step's, so the facts no step gave are the keys'.
		for k := w.first; k < len(w.facts) && w.facts[k].node < w.end; k += 1 {
			if w.nodes[w.facts[k].node].role == .Key {
				w.dropped += {w.facts[k].kind} & w.holds
			}
		}
		return w.dropped
	}
	for ; w.fact < len(w.facts) && w.facts[w.fact].node < w.end; w.fact += 1 {
		w.dropped += {w.facts[w.fact].kind} & w.holds
	}
	return w.dropped
}

// The next step of the walk. After `Done` every call is `Done`.
tree_next :: #force_inline proc(w: ^Tree, $FACTS, $TABLES: bool) -> (s: Step) #no_bounds_check {
	// Every `i` the walk reads is below its frame's `end` or the written value's, both inside `nodes`.
	at: tape.Node_Index
	if w.depth > 0 {
		f := &w.frames[w.depth - 1]
		when TABLES {
			if w.in_row {
				key, value, p := tape.next_child(w.reader, &w.row, .Group)
				if p == .Found {
					w.cell = tape.cell_key(w.reader, w.row)
					s.first, s.key, s.cell = f.children == 0, key, true
					f.children += 1
					return scalar_step(w, s, value, FACTS)
				}
				tape.destroy_children(&w.row)
				w.in_row = false
				w.i = f.end
			}
		}
		if (int(f.children) == len(w.pairs) - int(f.pairs_lo)) if f.sorted else (w.i == f.end) {
			if f.sorted {
				pairs_drop(w, int(f.pairs_lo))
				w.i = f.end
			}
			w.depth -= 1
			s = {node = f.node, depth = w.depth, kind = .Close, first = f.children == 0}
			when FACTS {
				s.facts = w.facts[f.facts_lo:][:f.facts_n]
			}
			return
		}
		s.first = f.children == 0
		s.key = tape.NO_NODE
		if f.sorted {
			p := w.pairs[int(f.pairs_lo) + int(f.children)]
			s.key, w.i = p.key, p.value
			when TABLES {
				if p.key == tape.NO_NODE {
					w.cell, s.cell = p.cell, true
				}
			}
		} else if f.object {
			s.key = w.i
			k := w.nodes[w.i]
			w.i += 1 if k.kind <= .Plain else tape.Node_Index(k.n)
		}
		f.children += 1
	} else {
		if w.i == w.end || w.err != nil {
			return {kind = .Done, node = tape.NO_NODE, key = tape.NO_NODE}
		}
		s.first, s.key = true, tape.NO_NODE
	}
	at = w.i
	t := w.nodes[at]
	if t.kind < .Array {
		w.i += 1
		return scalar_step(w, s, at, FACTS)
	}
	s.node, s.depth, s.kind = at, w.depth, .Open
	when FACTS {
		facts_lo := node_facts(w, at)
		s.facts = w.facts[facts_lo:w.fact]
	}
	if t.spelling & tape.CONTAINER_PARTIAL != 0 {
		w.err = Refused{at, .Partial}
		return {kind = .Done, node = tape.NO_NODE, key = tape.NO_NODE}
	}
	if w.depth == w.held && !grow_stack(&w.frames, &w.held, FRAME_ROOM, w.allocator, &w.err) {
		return {kind = .Done, node = tape.NO_NODE, key = tape.NO_NODE}
	}
	f := &w.frames[w.depth]
	f^ = {node = at, end = at + tape.Node_Index(t.n), object = t.kind == .Object}
	when FACTS {
		f.facts_lo, f.facts_n = u32(facts_lo), u32(len(s.facts))
	}
	w.depth += 1
	w.i += 1
	if f.object && w.sort_keys {
		sort_members(w, f)
		return
	}
	when TABLES {
		if f.object {
			open_row(w, at)
		}
	}
	return
}

// Lists the members of the object of frame `f` in the order of their keys' texts, a table row's by the header's.
@(private)
sort_members :: proc(w: ^Tree, f: ^Frame) {
	f.sorted, f.pairs_lo = true, u32(len(w.pairs))
	c: tape.Children
	p := tape.Presence.Missing
	err: runtime.Allocator_Error
	if tree_tables(w) {
		c, p, err = tape.children(w.reader, f.node, w.allocator)
	}
	if err == nil && p == .Found && c.keys_n != 0 {
		for err == nil {
			key, value, q := tape.next_child(w.reader, &c, .Group)
			if q != .Found {
				break
			}
			_, err = append(&w.pairs, Pair{key = key, cell = tape.cell_key(w.reader, c), value = value})
		}
	} else {
		for k := f.node + 1; err == nil && k < f.end; {
			value := tape.node_after(w.doc, k)
			_, err = append(&w.pairs, Pair{key = k, value = value})
			k = tape.node_after(w.doc, value)
		}
	}
	tape.destroy_children(&c)
	members := w.pairs[f.pairs_lo:]
	for &m in members {
		if err != nil {
			break
		}
		s: string
		ok: bool
		if m.key == tape.NO_NODE {
			s, ok = text_of_token(w, m.cell)
		} else if w.nodes[m.key].kind > .Plain {
			continue
		} else {
			s, ok = text_of(w, m.key)
		}
		if !ok {
			return
		}
		m.name, m.owned = s, raw_data(s) == raw_data(w.scratch)
		if m.owned {
			m.name, err = strings.clone(s, w.allocator)
		}
	}
	if err != nil {
		w.err = err
		w.i, w.depth = w.end, 0
		return
	}
	if w.length_first {
		slice.stable_sort_by(members, proc(a, b: Pair) -> bool {return len(a.name) < len(b.name) || len(a.name) == len(b.name) && a.name < b.name})
	} else {
		slice.stable_sort_by(members, proc(a, b: Pair) -> bool {return a.name < b.name})
	}
	if w.no_dups {
		for i in 1 ..< len(members) {
			a, b := members[i - 1], members[i]
			if a.key != tape.NO_NODE && w.nodes[a.key].kind > .Plain {
				continue
			}
			if b.key != tape.NO_NODE && w.nodes[b.key].kind > .Plain {
				continue
			}
			if b.name == a.name {
				w.err = Refused{b.key if b.key != tape.NO_NODE else f.node, .No_Spelling}
				w.i, w.depth = w.end, 0
				return
			}
		}
	}
}

// Frees the names of `pairs[lo:]` the walk cloned and drops those members.
@(private)
pairs_drop :: proc(w: ^Tree, lo: int) {
	for m in w.pairs[lo:] {
		if m.owned {
			delete(m.name, w.allocator)
		}
	}
	resize(&w.pairs, lo)
}

@(private)
scalar_step :: #force_inline proc(w: ^Tree, s: Step, at: tape.Node_Index, $FACTS: bool) -> Step {
	s := s
	s.node, s.depth, s.kind = at, w.depth, .Scalar
	when FACTS {
		lo := node_facts(w, at)
		s.facts = w.facts[lo:w.fact]
	}
	return s
}

// Moves the fact cursor past the facts of node `at`, dropping the facts of the kinds the target writes on the nodes
// before it, which no step gave, and returns where the facts of `at` start.
@(private)
node_facts :: #force_inline proc "contextless" (w: ^Tree, at: tape.Node_Index) -> int #no_bounds_check {
	if w.sort_keys {
		w.fact = facts_from(w.facts, at, w.fact)
	}
	for w.fact < len(w.facts) && w.facts[w.fact].node < at {
		w.dropped += {w.facts[w.fact].kind} & w.holds
		w.fact += 1
	}
	lo := w.fact
	for w.fact < len(w.facts) && w.facts[w.fact].node == at {
		w.fact += 1
	}
	return lo
}

// The step of value `at`, as `tree_next` gives it, for a writer that walks the nodes itself and calls it for each value
// it writes with facts. `first` is whether the value is the first of its container, `key` its member's key or `NO_NODE`.
value_step :: proc "contextless" (w: ^Tree, at, key: tape.Node_Index, depth: int, first: bool) -> Step #no_bounds_check {
	lo := node_facts(w, at)
	return {facts = w.facts[lo:w.fact], node = at, key = key, depth = depth, kind = .Scalar if w.nodes[at].kind < .Array else .Open, first = first}
}

// The first row from `i` of a walk by rows whose value holds facts, a member's row being its key's, else the largest
// index. Facts on a key are no step's, and are dropped as the facts before a value are.
fact_row :: proc "contextless" (w: ^Tree, i: tape.Node_Index) -> tape.Node_Index #no_bounds_check {
	for w.fact < len(w.facts) {
		at := w.facts[w.fact].node
		if at >= w.end {
			break
		}
		if w.nodes[at].role != .Key {
			row := at - 1 if at > i && w.nodes[at - 1].role == .Key else at
			if row >= i {
				return row
			}
		}
		w.dropped += {w.facts[w.fact].kind} & w.holds
		w.fact += 1
	}
	return max(tape.Node_Index)
}

// The first fact on node `at` or past it, searched outward from the fact `near`, which a sorted object's members stay
// close to.
@(private)
facts_from :: proc "contextless" (facts: []tape.Fact, at: tape.Node_Index, near: int) -> int #no_bounds_check {
	f := min(near, len(facts))
	lo, hi := f, f
	step := 1
	if f < len(facts) && facts[f].node < at {
		lo = f + 1
		hi = lo
		for hi < len(facts) && facts[hi].node < at {
			lo = hi + 1
			hi = lo + step
			step *= 2
		}
		hi = min(hi, len(facts))
	} else {
		for lo > 0 && facts[lo - 1].node >= at {
			hi = lo - 1
			lo = max(lo - 1 - step, 0)
			step *= 2
		}
	}
	for lo < hi {
		mid := (lo + hi) / 2
		if facts[mid].node < at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// Opens the object at `at` as a row when it is one of a table, whose cells the readers name by the header.
@(private)
open_row :: proc(w: ^Tree, at: tape.Node_Index) {
	c, p, err := tape.children(w.reader, at, w.allocator)
	if err != nil {
		w.err = err
		w.i = w.end
		w.depth = 0
		return
	}
	if p == .Found && c.keys_n != 0 {
		w.row, w.in_row = c, true
		return
	}
	tape.destroy_children(&c)
}

// Whether the members of the container at `at` are its nodes in order, key and value for an object, with no table's rows
// and no member a partial document left out.
plain_members :: #force_inline proc "contextless" (w: ^Tree, at: tape.Node_Index) -> bool #no_bounds_check {
	t := w.nodes[at]
	return w.doc.ext == nil && t.kind >= .Array && t.spelling & tape.CONTAINER_PARTIAL == 0
}

// `tape.children` of the container at `at` for a walk that takes every member as written (`.Group`), which skips the
// check of an object's keys for a repeat that `.Group` does not use. A partial container sets `w.err = Refused{at, .Partial}`.
children_as_written :: proc(w: ^Tree, at: tape.Node_Index) -> (c: tape.Children, ok: bool) #no_bounds_check {
	if plain_members(w, at) {
		return tape.Children{container = at, next = at + 1}, true
	}
	if w.nodes[at].kind >= .Array && w.nodes[at].spelling & tape.CONTAINER_PARTIAL != 0 {
		w.err = Refused{at, .Partial}
		return {}, false
	}
	p: tape.Presence
	aerr: runtime.Allocator_Error
	c, p, aerr = tape.children(w.reader, at, w.allocator)
	if aerr != nil {
		w.err = aerr
		return {}, false
	}
	if p == .Not_Loaded {
		tape.destroy_children(&c)
		w.err = Refused{at, .Partial}
		return {}, false
	}
	return c, true
}
