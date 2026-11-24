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

// `builder_dups` for a document `segments_join` joined from `segs`, run on the threads of `runner`. Each segment judges
// the objects it holds whole and collects the members it holds of objects that cross its ends. Those members are then
// judged in ranges of their keys' hashes.
@(require_results)
segments_dups :: proc(doc: ^tape.Document, segs: []Segment, dups: tape.Duplicates, rules: ^tape.Rules, runner: ^tape.Runner) -> tape.Error {
	if !dups_apply(doc, dups) {
		return nil
	}
	allocator := doc.allocator
	j := Dups_Job{doc = doc, segs = segs, dups = dups}
	err: runtime.Allocator_Error
	defer {
		for p in j.parts {
			delete(p.keys)
			delete(p.scratch)
		}
		delete(j.parts, allocator)
		delete(j.keys, allocator)
		delete(j.ranges, allocator)
	}
	r := Repeats{at = tape.NO_NODE}
	defer delete(r.drops, allocator)
	if j.parts, err = make([]Dups_Part, len(segs), allocator); err != nil {
		return dups_end(doc, &r, err, rules)
	}
	if dups != .Refuse {
		if r.drops, err = make([]u64, (len(doc.nodes) + 63) / 64, allocator); err != nil {
			return dups_end(doc, &r, err, rules)
		}
	}
	// Each part's `keys` gets the crossing members it reads, and `scratch` the members of the one object it judges at a
	// time.
	for &p in j.parts {
		p.r = {at = tape.NO_NODE, drops = r.drops}
		p.keys.allocator = allocator
		p.scratch.allocator = allocator
	}
	hook.fan_each(runner, len(j.segs), dups_parts, &j)
	crossing := 0
	for p in j.parts {
		r.at, r.dropped = min(r.at, p.r.at), r.dropped || p.r.dropped
		crossing += p.crossing
		if p.err != nil {
			err = p.err
		}
	}
	if crossing > 0 && err == nil {
		// Splits the hashes into `n` ranges, each with the crossing members every part holds in it, sorted in each
		// part.
		n := max(4 * (runner.threads + 1), 1)
		if j.keys, err = non_zero_make([]Hashed_Key, crossing, allocator); err != nil {
			return dups_end(doc, &r, err, rules)
		}
		if j.ranges, err = make([]Dups_Range, n, allocator); err != nil {
			return dups_end(doc, &r, err, rules)
		}
		at := 0
		for &g, i in j.ranges {
			g.hash = u32(u64(i + 1) * (u64(max(u32)) + 1) / u64(n) - 1)
			g.lo = at
			for p in j.parts {
				from, to := dups_range(p.keys[:p.crossing], j.ranges[:], i)
				at += to - from
			}
			g.r = {at = tape.NO_NODE, drops = r.drops}
		}
		hook.fan_each(runner, len(j.ranges), dups_ranges, &j)
		for g in j.ranges {
			r.at, r.dropped = min(r.at, g.r.at), r.dropped || g.r.dropped
			if g.err != nil {
				err = g.err
			}
		}
	}
	return dups_end(doc, &r, err, rules)
}

@(private)
Dups_Job :: struct {
	doc:    ^tape.Document,
	segs:   []Segment,
	dups:   tape.Duplicates,
	parts:  []Dups_Part,
	keys:   []Hashed_Key, // the crossing members of every part, by range
	ranges: []Dups_Range,
}

// A segment's repeats `r`, its `keys` (the `crossing` members it holds of objects that cross its ends, appended and
// then sorted) and `scratch` (the members of the one object it is judging).
@(private)
Dups_Part :: struct {
	r:        Repeats,
	keys:     [dynamic]Hashed_Key,
	scratch:  [dynamic]Hashed_Key,
	crossing: int,
	err:      runtime.Allocator_Error,
}

// A range of hashes: the crossing members with hashes up to `hash` and past the previous range's, which start at
// `keys[lo]` in the job's keys.
@(private)
Dups_Range :: struct {
	hash: u32,
	lo:   int,
	r:    Repeats,
	err:  runtime.Allocator_Error,
}

// The number of keys in sorted `keys` whose hash is at most `hash`.
@(private)
dups_below :: proc "contextless" (keys: []Hashed_Key, hash: u32) -> int {
	lo, hi := 0, len(keys)
	for lo < hi {
		mid := (lo + hi) / 2
		if keys[mid].hash <= hash {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// The bounds `from` and `to` of the keys of sorted `keys` in range `i` of `ranges`, past the hashes of the range
// before it.
@(private)
dups_range :: #force_inline proc "contextless" (keys: []Hashed_Key, ranges: []Dups_Range, i: int) -> (from, to: int) {
	return dups_below(keys, ranges[i - 1].hash) if i > 0 else 0, dups_below(keys, ranges[i].hash)
}

// Judges the objects each segment holds whole and gathers its crossing members. A container crosses the segment's
// start if it is open at its seam, and its end if the segment opens it and leaves it open.
@(private)
dups_parts :: proc(arg: rawptr, k: int) {
	j := (^Dups_Job)(arg)
	doc := j.doc
	s, p := &j.segs[k], &j.parts[k]
	lo, hi := s.at, j.segs[k + 1].at if k + 1 < len(j.segs) else len(doc.nodes)
	// The open containers, each as its node shifted left by one with the low bit set for one that crosses, kept in
	// the frames the segment's walk used.
	stack := s.b.stack
	top := 0
	for node in s.seam {
		stack[top] = u64(node) << 1 | 1
		top += 1
	}
	for i in lo ..< hi {
		for top > 0 && int(stack[top - 1] >> 1) + int(doc.nodes[stack[top - 1] >> 1].n) <= i {
			top -= 1
		}
		node := doc.nodes[i]
		if node.role == .Key && top > 0 && stack[top - 1] & 1 != 0 {
			object := tape.Node_Index(stack[top - 1] >> 1)
			if _, p.err = append(&p.keys, Hashed_Key{doc.format.key_hash(doc.src, node), object, tape.Node_Index(i)}); p.err != nil {
				return
			}
			p.crossing += 1
		}
		if node.kind <= .Plain {
			continue
		}
		whole := i + int(node.n) <= hi
		if node.kind == .Object && whole && p.err == nil {
			clear(&p.scratch)
			for m := tape.Node_Index(i) + 1; int(m) < i + int(node.n); m = tape.node_after(doc, tape.node_after(doc, m)) {
				if _, p.err = append(&p.scratch, Hashed_Key{doc.format.key_hash(doc.src, doc.nodes[m]), 0, m}); p.err != nil {
					return
				}
			}
			p.err = repeats_in(doc, p.scratch[:], j.dups, &p.r)
		}
		stack[top] = u64(i) << 1 | u64(!whole)
		top += 1
	}
	// Sorted by hash, then node, so that a range's keys of one hash come in node order, segment after segment.
	// `repeats_in` relies on that order for a range of `FEW_KEYS` keys or fewer, which it does not sort.
	slice.sort_by(p.keys[:p.crossing], proc(a, b: Hashed_Key) -> bool { return a.hash < b.hash || a.hash == b.hash && a.node < b.node })
}

// Judges the crossing members of each range of hashes.
@(private)
dups_ranges :: proc(arg: rawptr, i: int) {
	j := (^Dups_Job)(arg)
	g := &j.ranges[i]
	at := g.lo
	for p in j.parts {
		from, to := dups_range(p.keys[:p.crossing], j.ranges, i)
		copy(j.keys[at:], p.keys[from:to])
		at += to - from
	}
	g.err = repeats_in(j.doc, j.keys[g.lo:at], j.dups, &g.r)
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
