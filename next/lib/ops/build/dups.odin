package build

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Applies a build's policy `dups` to the built `doc`, for the members of one object that share a key, kind and text.
// `.Refuse` fails with `.Duplicate_Key` at the first byte of the first key read that repeats one of its object's,
// which is a quoted key's opening quote. A key read first lies first in the text, but in a markup entity read at each
// reference to it. `.First` and `.Last` keep one member of each key and remove the other members with their nodes and
// facts. Any other policy keeps every member. On an error `doc` is destroyed.
@(require_results)
builder_dups :: proc(doc: ^tape.Document, dups: tape.Duplicates, rules: ^tape.Rules) -> tape.Error {
	if !dups_apply(doc, dups) {
		return nil
	}
	r := Repeats{at = tape.NO_NODE}
	// Copied here because an error destroys `doc`, and a deferred free through `doc.allocator` would then use a zeroed
	// allocator and leak the bitmap.
	allocator := doc.allocator
	defer delete(r.drops, allocator)
	refused := dups_scan(doc, dups, &r)
	return dups_end(doc, &r, refused, rules)
}

// The repeated keys of every object of `doc` under policy `dups`, kept in `r`.
@(private)
dups_scan :: proc(doc: ^tape.Document, dups: tape.Duplicates, r: ^Repeats) -> (refused: runtime.Allocator_Error) {
	keys: [dynamic]Hashed_Key
	keys.allocator = doc.allocator
	defer delete(keys)
	for node, i in doc.nodes {
		if node.kind != .Object {
			continue
		}
		clear(&keys)
		end := tape.Node_Index(i) + tape.Node_Index(node.n)
		for k := tape.Node_Index(i) + 1; k < end; k = tape.node_after(doc, tape.node_after(doc, k)) {
			if _, refused = append(&keys, Hashed_Key{doc.format.key_hash(doc.src, doc.nodes[k]), 0, k}); refused != nil {
				return
			}
		}
		if refused = repeats_in(doc, keys[:], dups, r); refused != nil {
			return
		}
	}
	return
}

// The error of a walk that ended in the fault `fault` with the nodes it stored, which `.Refuse` makes `Duplicate_Key`
// when a key repeats before the fault, as the first fault in the text wins. `regs` are the hook's registers at the end
// of the walk, whose open containers the nodes' sizes are not yet set for.
@(private)
partial_repeat :: proc(h: ^Builder, regs: hook.Regs, fault: tape.Fault, rules: ^tape.Rules) -> tape.Error {
	count := int(builder_cursor(h, regs))
	if count < 3 {
		return fault
	}
	// A copy with a node past the stored ones, which is read when a member's value is missing.
	nodes, merr := make([]tape.Node, count + 1, h.doc.allocator)
	if merr != nil || len(nodes) < count + 1 || raw_data(nodes) == nil {
		return fault
	}
	defer delete(nodes, h.doc.allocator)
	copy(nodes, h.doc.nodes[:count])
	nodes[count] = {}
	if open := int(regs.b >> 32); regs.c > 0 && open < count {
		nodes[open].n = u32(count - open)
	}
	for j in 1 ..< int(regs.c) {
		if open := int(h.stack[j] >> 32); open < count {
			nodes[open].n = u32(count - open)
		}
	}
	view := h.doc
	view.nodes = nodes
	view.facts = nil
	r := Repeats{at = tape.NO_NODE}
	if dups_scan(&view, .Refuse, &r) != nil || r.at == tape.NO_NODE {
		return fault
	}
	head, _ := view.format.bounds(view.src, view.nodes[r.at])
	if at := view.nodes[r.at].lo - u64(head); at < fault.at {
		return tape.Fault{at = at, rules = rules, kind = .Duplicate_Key}
	}
	return fault
}

// Whether policy `dups` may change or refuse `doc`.
@(private)
dups_apply :: #force_inline proc "contextless" (doc: ^tape.Document, dups: tape.Duplicates) -> bool {
	return (dups == .Refuse || dups == .First || dups == .Last) && len(doc.nodes) > 0
}

// The repeated keys found. `at` is, under `.Refuse`, the node of the first repeated key read, else `tape.NO_NODE`.
// `drops` has a bit per key node of each dropped member, and `dropped` says whether any is set.
@(private)
Repeats :: struct {
	at:      tape.Node_Index,
	drops:   []u64,
	dropped: bool,
}

// Removes the members `r` drops, or returns the error `refused` or the duplicate key `r` holds. `doc` is destroyed on
// an error.
@(private)
dups_end :: proc(doc: ^tape.Document, r: ^Repeats, refused: runtime.Allocator_Error, rules: ^tape.Rules) -> tape.Error {
	refused := refused
	if refused == nil && r.dropped {
		refused = drop_members(doc, r.drops)
		doc.flags += {.Dropped}
	}
	err: tape.Error
	if refused != nil {
		err = refused
	} else if r.at != tape.NO_NODE {
		head, _ := doc.format.bounds(doc.src, doc.nodes[r.at])
		err = tape.Fault{at = doc.nodes[r.at].lo - u64(head), rules = rules, kind = .Duplicate_Key}
	}
	if err != nil {
		tape.destroy(doc)
	}
	return err
}

// Marks the repeated keys among `keys`, which are in node order. Two keys are equal by the format's `key_hash` and
// `same_keys`, as for the readers, and keys of different `object` are never equal. With more than `FEW_KEYS` keys they
// are sorted by hash, object and node, and each is compared only within its run of one hash and object.
@(private)
repeats_in :: proc(doc: ^tape.Document, keys: []Hashed_Key, dups: tape.Duplicates, r: ^Repeats) -> runtime.Allocator_Error #no_bounds_check {
	sorted := len(keys) > FEW_KEYS
	if sorted {
		slice.sort_by(keys, proc(a, b: Hashed_Key) -> bool {
			return a.hash < b.hash || a.hash == b.hash && (a.object < b.object || a.object == b.object && a.node < b.node)
		})
	}
	for run := 0; run < len(keys); {
		past := run + 1 if sorted else len(keys)
		for past < len(keys) && keys[past].hash == keys[run].hash && keys[past].object == keys[run].object {
			past += 1
		}
		// Each key of the run in text order. Its later equal keys are marked taken by setting their node to
		// `tape.NO_NODE`.
		for j in run ..< past {
			first := keys[j].node
			if first == tape.NO_NODE {
				continue
			}
			last := first
			for &later in keys[j + 1:past] {
				if later.node == tape.NO_NODE || later.hash != keys[j].hash || later.object != keys[j].object {
					continue
				}
				if !tape.same_keys(doc.format, doc.src, doc.nodes[first], doc.src, doc.nodes[later.node]) {
					continue
				}
				switch dups {
				case .Refuse:
					r.at = min(r.at, later.node)
				case .First:
					drop_mark(doc, r, later.node) or_return
				case .Last:
					drop_mark(doc, r, last) or_return
				case .Default, .All, .Group:
				}
				last, later.node = later.node, tape.NO_NODE
			}
		}
		run = past
	}
	return nil
}

// The most keys that `repeats_in` compares pairwise without sorting.
@(private)
FEW_KEYS :: 16

// A key node with the hash of its key. `object` is the node of its object for a member of an object that crosses a
// seam, else 0.
@(private)
Hashed_Key :: struct {
	hash:   u32,
	object: tape.Node_Index,
	node:   tape.Node_Index,
}

// Sets the bit of key node `k` in `r.drops`, allocating the bitset on first use. A build in parts allocates it
// beforehand, as its threads share it.
@(private)
drop_mark :: proc(doc: ^tape.Document, r: ^Repeats, k: tape.Node_Index) -> runtime.Allocator_Error {
	if r.drops == nil {
		r.drops = make([]u64, (len(doc.nodes) + 63) / 64, doc.allocator) or_return
	}
	intrinsics.atomic_or(&r.drops[k / 64], 1 << uint(k % 64))
	r.dropped = true
	return nil
}

// Removes the members whose key nodes `drops` marks, with their values' subtrees and facts, moving the nodes past
// them down and giving each container its new size and count.
@(private)
drop_members :: proc(doc: ^tape.Document, drops: []u64) -> runtime.Allocator_Error #no_bounds_check {
	nodes := doc.nodes
	moved := make([]tape.Node_Index, len(nodes), doc.allocator) or_return
	defer delete(moved, doc.allocator)
	open: [dynamic]Open_Moved
	open.allocator = doc.allocator
	defer delete(open)
	w := 0
	for i := 0; i < len(nodes); {
		for len(open) > 0 && open[len(open) - 1].end == i {
			close_moved(nodes, pop(&open), w)
		}
		if drops[i / 64] & (1 << uint(i % 64)) != 0 {
			past := int(tape.node_after(doc, tape.node_after(doc, tape.Node_Index(i))))
			for j in i ..< past {
				moved[j] = tape.NO_NODE
			}
			open[len(open) - 1].dropped += 1
			i = past
			continue
		}
		moved[i] = tape.Node_Index(w)
		nodes[w] = nodes[i]
		if nodes[i].kind > .Plain {
			append(&open, Open_Moved{w, i + int(nodes[i].n), 0}) or_return
		}
		w += 1
		i += 1
	}
	for len(open) > 0 {
		close_moved(nodes, pop(&open), w)
	}
	doc.nodes = nodes[:w]
	kept := 0
	for f in doc.facts {
		if node := moved[f.node]; node != tape.NO_NODE {
			doc.facts[kept] = f
			doc.facts[kept].node = node
			kept += 1
		}
	}
	doc.facts = doc.facts[:kept]
	delete(doc.counts, doc.allocator)
	doc.counts = nil
	counts := builder_counts(doc.nodes, doc.allocator) or_return
	if len(counts) > 0 {
		doc.counts = counts[:]
	} else {
		delete(counts)
	}
	return nil
}

// A container open in `drop_members`.
@(private)
Open_Moved :: struct {
	at:      int, // its new index
	end:     int, // index one past its old subtree
	dropped: u16,
}

// Sets the size of container `o`, which closes at the new index `w`, and its child count less the members dropped from
// it. A count that had saturated is counted again from the nodes.
@(private)
close_moved :: proc(nodes: []tape.Node, o: Open_Moved, w: int) {
	node := &nodes[o.at]
	node.n = u32(w - o.at)
	if node.spelling & tape.MAX_CHILDREN < tape.MAX_CHILDREN {
		node.spelling -= o.dropped
	} else {
		node.spelling = node.spelling &~ tape.MAX_CHILDREN | u16(min(child_count(nodes[o.at + 1:w]), u32(tape.MAX_CHILDREN)))
	}
}

// The full child counts of the containers in `nodes` whose `spelling` saturated at `MAX_CHILDREN`, in node order.
@(private, cold)
builder_counts :: proc(nodes: []tape.Node, allocator: runtime.Allocator) -> (counts: [dynamic]tape.Child_Count, err: runtime.Allocator_Error) #no_bounds_check {
	counts.allocator = allocator
	for i := 0; i < len(nodes); {
		node := nodes[i]
		if node.kind <= .Plain {
			i += 1
			continue
		}
		// A subtree of fewer nodes than `MAX_CHILDREN` holds no saturated container.
		if node.n < u32(tape.MAX_CHILDREN) {
			i += max(int(node.n), 1)
			continue
		}
		if node.spelling & tape.MAX_CHILDREN == tape.MAX_CHILDREN {
			append(&counts, tape.Child_Count{tape.Node_Index(i), child_count(nodes[i + 1:i + int(node.n)])}) or_return
		}
		i += 1
	}
	return
}

// The children among `nodes`, a container's descendants. A key is not a child.
@(private)
child_count :: proc(nodes: []tape.Node) -> (count: u32) #no_bounds_check {
	for j := 0; j < len(nodes); {
		child := nodes[j]
		if child.kind <= .Plain {
			count += u32(child.role == .Value)
			j += 1
		} else {
			count += 1
			j += int(child.n)
		}
	}
	return
}
