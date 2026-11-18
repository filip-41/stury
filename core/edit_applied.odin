package core

import "core:encoding/endian"
import "core:slice"
import "core:strings"

// Whether `got`, a read of the text a commit of `list` made, holds the document the edits make. A node no edit reaches
// is the source's bytes, which the read that made `got` has judged, so only its kind and subtree size are compared.
// `known` is false when an edit holds no value to read back: a text the caller spelled, a type tag or an alias set, or
// a flat text's header cell. Works in the context allocator.
reads_as_edited :: proc(list: ^Edit_List, got: Node_Ref) -> (reads, known: bool) {
	a := applied_of(list) or_return
	return reads_applied(&a, ROOT, got), true
}

// Whether `got` reads as node `n` with the edits of `a` made. A container whose members the edits set, insert, remove
// or rename is compared member by member against the source, with no copy of it built. An object that holds its
// members in another order, or repeats a key, is compared by sorted keys.
@(private = "file")
reads_applied :: proc(a: ^Applied, n: Node_Index, got: Value) -> bool {
	if has(a.is_set, n) {
		return reads_as(set_of(a, n), got)
	}
	doc := a.doc
	k := doc.nodes[n].kind
	if (k != .Object && k != .Array) || !has(a.dirty, n) {
		return reads_as(Node_Ref{doc, n}, got)
	}
	_, reordered := entry_of(a.orders, n)
	if reordered || (k == .Object && is_markup(doc)) || value_kind(got) != k {
		return reads_as(applied(a, n), got)
	}
	inserts := of_node(a.inserts, n)
	if k == .Array {
		mine, theirs := doc_children(doc, n), value_children(got)
		i := 0
		for v in doc_child_next(&mine) {
			defer i += 1
			if !reads_inserts(inserts, i, &theirs) {
				return false
			}
			if has(a.gone, v) {
				continue
			}
			if y, more := value_child_next(&theirs); !more || !reads_applied(a, v, y) {
				return false
			}
		}
		if !reads_inserts(inserts, i, &theirs) {
			return false
		}
		_, extra := value_child_next(&theirs)
		return !extra
	}
	mine, theirs := doc_pairs(doc, n), value_pairs(got)
	i := 0
	for key, v in doc_pair_next(&mine) {
		defer i += 1
		if !reads_inserts(inserts, i, &theirs) {
			return reads_as(applied(a, n), got)
		}
		if has(a.gone, v) {
			continue
		}
		name, y, more := value_pair_next(&theirs)
		named := key_equals(doc, key, name)
		if renamed, is_renamed := entry_of(a.renames, v); is_renamed {
			named = name == renamed.key
		}
		if !more || !named || !reads_applied(a, v, y) {
			return reads_as(applied(a, n), got)
		}
	}
	if !reads_inserts(inserts, i, &theirs) {
		return reads_as(applied(a, n), got)
	}
	if _, _, extra := value_pair_next(&theirs); extra {
		return reads_as(applied(a, n), got)
	}
	return true
}

// Whether the next members `it` gives are the values of `inserts` placed at member `at`, under their keys in an object.
@(private = "file")
reads_inserts :: proc(inserts: []Applied_Insert, at: int, it: ^Value_Iter) -> bool {
	for p in inserts {
		if int(p.at) != at {
			continue
		}
		if value_kind(it.v) == .Object {
			name, y, more := value_pair_next(it)
			if !more || name != p.key || !reads_as(p.v, y) {
				return false
			}
		} else if y, more := value_child_next(it); !more || !reads_as(p.v, y) {
			return false
		}
	}
	return true
}

@(private = "file")
reads_as :: proc(want, got: Value) -> bool {
	#partial switch w in want {
	case Node_Ref:
		g, node := got.(Node_Ref)
		if !node || kind(w.doc, w.node) != kind(g.doc, g.node) || subtree_size(w.doc, w.node) != subtree_size(g.doc, g.node) {
			return false
		}
		return !g.doc.readers.floats_apart || same_number_types(want, got)
	case ^Array:
		if value_kind(got) != .Array || value_length(got) != len(w.items) {
			return false
		}
		it := value_children(got)
		for x in w.items {
			y, _ := value_child_next(&it)
			if !reads_as(x, y) {
				return false
			}
		}
		return true
	case ^Object:
		if value_kind(got) != .Object {
			return false
		}
		keys, read := sorted_keys(want), sorted_keys(got)
		if !slice.equal(keys, read) {
			return false
		}
		for k in keys {
			x, _ := value_member(want, k)
			y, _ := value_member(got, k)
			if !reads_as(x, y) {
				return false
			}
		}
		return true
	}
	return reads_back_as(want, got)
}

// Whether `got`, a value read back from the text an edit wrote, is the value `want` the edit wrote: equal as values,
// with a cell or a markup text read as the kind of the value it stands for, and of `want`'s number types where `got`
// is a node of a format that tells an integer from a float.
reads_back_as :: proc(want, got: Value) -> bool {
	if !equal(want, got, read_plain = true) {
		return false
	}
	r, is_node := got.(Node_Ref)
	return !is_node || !r.doc.readers.floats_apart || same_number_types(want, got)
}


// The edits of `list` gathered by the node they change, each list sorted by node, with each container on the way to one
// marked dirty unless `ways` is false, for a read that follows the source node by node and needs no way to an edit.
@(private)
applied_of :: proc(list: ^Edit_List, ways := true) -> (a: Applied, known: bool) {
	reach := on_way if ways else proc(_: ^Applied, _: Node_Index, _: bool) {}
	doc := list.doc
	a.doc = doc
	words := (len(doc.nodes) + 63) / 64
	a.dirty, a.is_set, a.gone = make([]u64, words), make([]u64, words), make([]u64, words)
	sets := make([dynamic]Applied_Set, 0, len(list.edits))
	inserts: [dynamic]Applied_Insert
	renames: [dynamic]Applied_Rename
	orders: [dynamic]Applied_Order
	for e in list.edits {
		switch e.op {
		case .Set:
			if e.role == .Key {
				append(&renames, Applied_Rename{e.node + 1, string(e.text)})
				mark(a.is_set, e.node)
				reach(&a, e.node + 1, false)
			} else if e.value == nil || doc.nodes[e.node].role == .Key {
				return {}, false
			} else {
				append(&sets, Applied_Set{e.node, e.value})
				mark(a.is_set, e.node)
				reach(&a, e.node, false)
			}
		case .Insert:
			if e.value == nil {
				return {}, false
			}
			append(&inserts, Applied_Insert{node = e.node, at = e.at, key = string(e.key), v = e.value})
			reach(&a, e.node, true)
		case .Remove:
			mark(a.gone, e.node)
			reach(&a, e.node, false)
		case .Reorder:
			append(&orders, Applied_Order{e.node, e.text})
			reach(&a, e.node, true)
		case .Set_Fact, .Remove_Fact:
			if e.role == .Tag || e.role == .Alias || e.role == .Anchor {
				return {}, false
			}
		}
	}
	a.sets, a.renames, a.orders = by_node(sets[:]), by_node(renames[:]), by_node(orders[:])
	insert_before :: proc(x, y: Applied_Insert) -> bool {return x.node < y.node || x.node == y.node && x.at < y.at}
	if a.inserts = inserts[:]; !slice.is_sorted_by(a.inserts, insert_before) {
		slice.stable_sort_by(a.inserts, insert_before)
	}
	if !slice.is_sorted(a.reached[:]) {
		slice.sort(a.reached[:])
	}
	resize(&a.reached, len(slice.unique(a.reached[:])))
	return a, true
}

// `xs` sorted by node, the entries of one node in their order.
@(private = "file")
by_node :: proc(xs: []$T) -> []T {
	before :: proc(x, y: T) -> bool {return x.node < y.node}
	if !slice.is_sorted_by(xs, before) {
		slice.stable_sort_by(xs, before)
	}
	return xs
}

// The entries of `xs`, sorted by node, that node `n` holds.
@(private)
of_node :: proc(xs: []$T, n: Node_Index) -> []T {
	lo := lower_node(xs, n)
	end := lo
	for end < len(xs) && xs[end].node == n {
		end += 1
	}
	return xs[lo:end]
}

@(private)
set_of :: proc(a: ^Applied, n: Node_Index) -> Value {
	// A read in document order asks for the sets in node order, so each is the entry the last one left off at.
	at := a.set_at
	if at >= len(a.sets) || a.sets[at].node != n {
		at = lower_node(a.sets, n)
	}
	v := a.sets[at].v
	for at < len(a.sets) && a.sets[at].node == n {
		at += 1
	}
	a.set_at = at
	return v
}

// The first entry of `xs`, sorted by node, that node `n` holds.
@(private)
entry_of :: proc(xs: []$T, n: Node_Index) -> (T, bool) {
	at := lower_node(xs, n)
	if at < len(xs) && xs[at].node == n {
		return xs[at], true
	}
	return {}, false
}

// Marks each container from the root down to node `x` dirty, and `x` itself when `itself`, with the member each holds
// on the way. A container's subtree is the nodes that follow it within its count, so the member that holds `x` is
// found by subtree sizes with no table of parents. While the way follows the last call's, the search in a container
// starts at the member that call found there when it lies at or before `x`, so edits given in node order step over
// each member once.
@(private = "file")
on_way :: proc(a: ^Applied, x: Node_Index, itself: bool) {
	n, depth, same := ROOT, 0, true
	for n != x {
		mark(a.dirty, n)
		c := n + 1
		same &&= depth < len(a.way)
		if same && a.way[depth] <= x {
			c = a.way[depth]
		}
		for c + Node_Index(subtree_size(a.doc, c)) <= x {
			c += Node_Index(subtree_size(a.doc, c))
		}
		if same && c != a.way[depth] {
			resize(&a.way, depth)
			same = false
		}
		if !same {
			append(&a.way, c)
			append(&a.reached, c)
		}
		n = c
		depth += 1
	}
	resize(&a.way, depth)
	append(&a.reached, x)
	if itself {
		mark(a.dirty, x)
	}
}

@(private)
Applied :: struct {
	doc:     ^Document,
	sets:    []Applied_Set,
	inserts: []Applied_Insert, // sorted by node, then by index, each index's in their order
	renames: []Applied_Rename,
	orders:  []Applied_Order,
	is_set:  []u64, // bit n: node n is in `sets`, or is the key of a node in `renames`
	gone:    []u64, // bit n: node n is removed
	dirty:   []u64, // bit n: node n is a container an edit changes, or one that holds such a container
	reached: [dynamic]Node_Index, // each edit's node and each member on the way to one, sorted once the edits are read
	way:     [dynamic]Node_Index, // the member held at each depth on the last call of `on_way`
	set_at:  int, // the entry of `sets` past the node the last `set_of` found, where the next search starts
}

@(private)
has :: #force_inline proc "contextless" (bits: []u64, n: Node_Index) -> bool {
	return bits[n >> 6] & (1 << (u64(n) & 63)) != 0
}

@(private)
mark :: #force_inline proc "contextless" (bits: []u64, n: Node_Index) {
	bits[n >> 6] |= 1 << (u64(n) & 63)
}

@(private = "file")
Applied_Set :: struct {
	node: Node_Index,
	v:    Value,
}

@(private)
Applied_Insert :: struct {
	node: Node_Index, // the container
	at:   u32,
	key:  string,
	v:    Value,
}

@(private = "file")
Applied_Rename :: struct {
	node: Node_Index, // the value whose key is renamed
	key:  string,
}

@(private = "file")
Applied_Order :: struct {
	node:  Node_Index,
	order: []u8,
}

// The value of node `n` with the edits of `a` made.
@(private)
applied :: proc(a: ^Applied, n: Node_Index) -> Value {
	if has(a.is_set, n) {
		return set_of(a, n)
	}
	doc := a.doc
	if k := doc.nodes[n].kind; (k != .Object && k != .Array) || !has(a.dirty, n) {
		return Node_Ref{doc, n}
	}
	Member :: struct {
		key: string,
		v:   Node_Index,
	}
	object := doc.nodes[n].kind == .Object
	read := make([dynamic]Member)
	if object {
		it := doc_pairs(doc, n)
		for k, v in doc_pair_next(&it) {
			append(&read, Member{node_string(doc, k), v})
		}
	} else {
		it := doc_children(doc, n)
		for v in doc_child_next(&it) {
			append(&read, Member{"", v})
		}
	}
	members := read[:]
	if order, reordered := entry_of(a.orders, n); reordered {
		members = make([]Member, len(read))
		for &m, i in members {
			m = read[endian.unchecked_get_u32le(order.order[4 * i:])]
		}
	}
	b := Applied_Build{object = object, markup = object && is_markup(doc), o = new_object(), arr = new_array(len(members))}
	inserts := of_node(a.inserts, n)
	for i in 0 ..= len(members) {
		for p in inserts {
			if int(p.at) == i {
				applied_put(&b, p.key, p.v)
			}
		}
		if i == len(members) || has(a.gone, members[i].v) {
			continue
		}
		key := members[i].key
		if renamed, is_renamed := entry_of(a.renames, members[i].v); is_renamed {
			key = renamed.key
		}
		applied_put(&b, key, applied(a, members[i].v))
	}
	// An element the edits leave with no child element reads as its text, and with none as null.
	if keys, vals := object_keys(b.o), object_vals(b.o); b.markup && n != ROOT && (len(keys) == 0 || len(keys) == 1 && keys[0] == MARKUP_TEXT) {
		return vals[0] if len(keys) == 1 else nil
	}
	return b.o if object else b.arr
}

// A container being built from its members in order, `last` the key of the member put last.
@(private = "file")
Applied_Build :: struct {
	object, markup: bool,
	o:              ^Object,
	arr:            ^Array,
	last:           string,
}

// Puts member `key` of value `v` in `b`. A markup object groups a repeated name as its reading does: an array an edit
// writes is an element of the name for each item, and a text that follows a text joins it, as a read of the output
// joins them.
@(private = "file")
applied_put :: proc(b: ^Applied_Build, key: string, v: Value) {
	switch {
	case !b.object:
		array_append(b.arr, v)
		return
	case !b.markup:
		object_append(b.o, key, v)
		return
	}
	if items, many := v.(^Array); many {
		for item in items.items {
			applied_put(b, key, item)
		}
		return
	}
	defer b.last = key
	if key != MARKUP_TEXT || b.last != MARKUP_TEXT {
		markup_put(b.o, key, v)
		return
	}
	at := &b.o.slot_vals[object_slot(b.o, key)]
	if group, grouped := at.(^Array); grouped {
		at = &group.items[len(group.items) - 1]
	}
	at^ = strings.concatenate({string_text(at^), string_text(v)})
}
