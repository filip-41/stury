package jq

// jq's values. An input value stays a node of its `core.Document` (`core.Node_Ref`) until something builds a new
// value out of it, so a filter that only reads pays for what it reads. Built containers are immutable
// once made, except inside an update that owns them (`eval_update`). Key and value lookup is in
// lookup.odin, order and equality in compare.odin.

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "core:strings"
import core_pkg "../core"
import "../core/write"
import json "../json"

// The string of text node `i`. A byte string value's is its RFC 4648 base64 and a byte string key's its bytes, as the
// library writes them as JSON.
@(private)
node_string :: proc(doc: ^core_pkg.Document, i: core_pkg.Node_Index) -> string {
	if int(i) < len(doc.nodes) && doc.nodes[i].kind == .Bytes && doc.nodes[i].role != .Key {
		return bytes_string(doc, i)
	}
	return core_pkg.node_string(doc, i)
}

@(private = "file", cold)
bytes_string :: proc(doc: ^core_pkg.Document, i: core_pkg.Node_Index) -> string {
	text, _ := write.node_bytes_text(doc, i, nil)
	return strings.clone(text)
}

// A number as jq reads it: its double, and the digits it keeps (`core.double_of`).
@(private)
Num :: struct {
	f:   f64,
	lit: string,
}

// jq's kinds, in jq's order of values.
Kind :: enum u8 {
	Null,
	False,
	True,
	Number,
	String,
	Array,
	Object,
}

@(private)
num :: #force_inline proc(f: f64) -> core_pkg.Value {
	return f
}

// The readers of a value's data see through a `^Commented`, which never wraps another, in a case of their own, so a
// value without comments pays nothing for them.
kind :: proc(v: core_pkg.Value) -> Kind {
	switch x in v {
	case nil:
		return .Null
	case bool:
		return .True if x else .False
	case f64, core_pkg.Number_View:
		return .Number
	case string:
		return .String
	case ^core_pkg.Array, core_pkg.Trail:
		return .Array
	case ^core_pkg.Object:
		return .Object
	case core_pkg.Node_Ref:
		return node_kind(x.doc, x.node)
	case ^core_pkg.Commented:
		return jq_kind(x.kind)
	}
	return .Null
}

// jq's kind of a kind of the library's other than `.Plain`, which jq reads as its node does.
@(private = "file")
jq_kind :: #force_inline proc(k: core_pkg.Kind) -> Kind {
	#partial switch k {
	case .String, .Bytes:
		return .String
	case .Array:
		return .Array
	case .Object:
		return .Object
	case .End:
		return .Null
	}
	return Kind(k)
}

// A document node's jq kind. A build with `infer` stores a cell's kind in its node, and a cell it left `Plain` is a
// string or null. A `Plain` value of a document that stored no kinds is the kind its format resolves.
@(private)
node_kind :: #force_inline proc(doc: ^core_pkg.Document, i: core_pkg.Node_Index) -> Kind {
	#partial switch k := doc.nodes[i].kind if int(i) < len(doc.nodes) else core_pkg.Kind.Null; k {
	case .Array:
		return .Array
	case .Object:
		return .Object
	case .Plain:
		if !doc.kinds_stored {
			return unstored_kind(doc, i)
		}
		// A delimited cell: an empty unquoted one is null, a quoted one keeps its quotes in its span.
		return .Null if doc.nodes[i].n == 0 && doc.nodes[i].role == .Value else .String
	case .String, .Bytes:
		return .String
	case:
		return Kind(k)
	}
}

// The kind of a `Plain` value of a document that did not store kinds. In a delimited text, a record or a partial read,
// an empty unquoted cell is null and the first byte of another decides whether the format has anything to resolve. Any
// other format resolves its own.
@(private, cold)
unstored_kind :: proc(doc: ^core_pkg.Document, i: core_pkg.Node_Index) -> Kind {
	n := doc.nodes[i]
	switch {
	case n.role != .Value:
		return .String
	case !doc.readers.flat:
		k := core_pkg.kind(doc, i)
		return .String if k == .Plain else jq_kind(k)
	case n.n == 0:
		return .Null
	case n.spelling == 0:
		if c := doc.src[n.lo]; c == 't' || c == 'f' || c == '-' || c - '0' < 10 {
			return jq_kind(core_pkg.kind(doc, i))
		}
	}
	return .String
}

type_name :: #force_inline proc(v: core_pkg.Value) -> string {
	switch kind(v) {
	case .Null:
		return "null"
	case .False, .True:
		return "boolean"
	case .Number:
		return "number"
	case .String:
		return "string"
	case .Array:
		return "array"
	case .Object:
		return "object"
	}
	return "null"
}

truthy :: proc(v: core_pkg.Value) -> bool {
	k := kind(v)
	return k != .Null && k != .False
}

// A `core.Node_Ref` scalar as its own value. Containers stay nodes.
scalar :: proc(v: core_pkg.Value) -> core_pkg.Value {
	r, is_ref := v.(core_pkg.Node_Ref)
	if !is_ref {
		c, is_commented := v.(^core_pkg.Commented)
		if !is_commented {
			return v
		}
		return scalar(c.v)
	}
	switch node_kind(r.doc, r.node) {
	case .Null:
		return nil
	case .False:
		return false
	case .True:
		return true
	case .Number:
		return node_number(r.doc, r.node)
	case .String:
		return node_string(r.doc, r.node)
	case .Array, .Object:
	}
	return v
}

// Number node `i`: its literal, its text but for a spelling other than its format's plain decimal (JSON5's `+1.5`,
// `0x10`), where it is the JSON text the library writes for it, and for a format whose number span is not its text,
// where it is the digits the format spells.
@(private)
node_number :: proc(doc: ^core_pkg.Document, i: core_pkg.Node_Index) -> core_pkg.Value {
	room: [core_pkg.HEX_ROOM]u8 = ---
	lit, f, is_literal := node_literal(doc, i, room[:])
	if !is_literal {
		return num(f)
	}
	// Digits the format spelled into `room` are kept in a copy. The others lie outside it, in the place they are written.
	if at := uintptr(raw_data(lit)); at >= uintptr(&room[0]) && at < uintptr(&room[0]) + len(room) {
		return core_pkg.number_text(lit)
	}
	return core_pkg.number_view(string(([^]u8)(rawptr(raw_data(lit)))[:len(lit)]), 0)
}

// The literal of number node `i` as `node_number` reads it, or its double when JSON cannot write it. The digits of a
// format whose number span is not its text lie in the source or in `room`, which holds `core.HEX_ROOM` bytes.
@(private)
node_literal :: proc(doc: ^core_pkg.Document, i: core_pkg.Node_Index, room: []u8) -> (lit: string, f: f64, is_literal: bool) {
	if doc.readers.number_text != nil {
		// A number with no digits, an infinity or a NaN, is its double.
		digits: string
		f, digits, _ = core_pkg.double_of(core_pkg.Node_Ref{doc, i}, room)
		return digits, f, digits != ""
	}
	lit = string(core_pkg.span(doc, i))
	// The `NUMBER_*` layout holds only for a `.Number` token. A dsv cell is `.Plain`, its spelling bits mean other things.
	if doc.nodes[i].kind == .Number && doc.nodes[i].spelling & core_pkg.NUMBER_KIND_MASK != 0 {
		text, _, err := core_pkg.write(doc, {}, json.as(.Json), i)
		if err != nil {
			// A number JSON cannot write is computed.
			n, _ := core_pkg.number(doc, i)
			return "", core_pkg.number_f64(n, lit), false
		}
		lit = string(text)
	}
	return lit, 0, true
}

// A double or a literal is read here, a number of any other form by the library's `double_of`.
@(private)
number_of :: #force_inline proc(v: core_pkg.Value) -> (Num, bool) {
	#partial switch x in v {
	case f64:
		return {f = x}, true
	case core_pkg.Number_View:
		if f, held := core_pkg.held_f64(x); held {
			return {f, core_pkg.view_text(x)}, true
		}
	}
	return other_number(v)
}

@(private = "file")
other_number :: #force_no_inline proc(v: core_pkg.Value) -> (Num, bool) {
	f, digits, ok := core_pkg.double_of(v)
	return {f, digits}, ok
}

string_of :: #force_inline proc(value: core_pkg.Value) -> (string, bool) {
	v := core_pkg.plain(value)
	if r, is_ref := v.(core_pkg.Node_Ref); is_ref {
		if node_kind(r.doc, r.node) != .String {
			return "", false
		}
		return node_string(r.doc, r.node), true
	}
	s, ok := v.(string)
	return s, ok
}

length_of :: proc(v: core_pkg.Value) -> int {
	switch x in v {
	case ^core_pkg.Array:
		return len(x.items)
	case core_pkg.Trail:
		return x.depth
	case ^core_pkg.Object:
		return len(core_pkg.object_keys(x))
	case core_pkg.Node_Ref:
		n := core_pkg.length(x.doc, x.node)
		if n > 1 && core_pkg.kind(x.doc, x.node) == .Object && core_pkg.has_repeated_key(x) {
			return core_pkg.distinct_keys(x)
		}
		return n
	case ^core_pkg.Commented:
		return length_of(x.v)
	case nil, bool, f64, core_pkg.Number_View, string:
	}
	return 0
}

// Whether `v` has no element or member. A document's object holds one or more however its keys repeat, so
// this does not count them as `length_of` does.
@(private)
is_empty :: proc(v: core_pkg.Value) -> bool {
	if r, is_ref := core_pkg.plain(v).(core_pkg.Node_Ref); is_ref {
		return core_pkg.length(r.doc, r.node) == 0
	}
	return length_of(v) == 0
}

// A document array read at or past this position is indexed first, so each read is a lookup and not a walk from the
// first member. Below it the walk is cheaper than the index.
@(private)
INDEX_MEMBERS_FROM :: 256

// Indexes every array of `v`'s documents that `array_at` or `array_slice` would index, for a value every thread of a
// run reads, before the threads start: their `index_children` calls then find the entry and write nothing.
@(private)
index_shared :: proc(v: core_pkg.Value) {
	switch x in v {
	case core_pkg.Node_Ref:
		for n, i in x.doc.nodes {
			at := core_pkg.Node_Index(i)
			if n.kind == .Array && core_pkg.length(x.doc, at) >= INDEX_MEMBERS_FROM {
				core_pkg.index_children(x.doc, at)
			}
		}
	case ^core_pkg.Array:
		for item in x.items {
			index_shared(item)
		}
	case ^core_pkg.Object:
		for val in core_pkg.object_vals(x) {
			index_shared(val)
		}
	case ^core_pkg.Commented:
		index_shared(x.v)
	case nil, bool, f64, core_pkg.Number_View, string, core_pkg.Trail:
	}
}

// Element `i` of an array, or null past its end.
@(private)
array_at :: proc(v: core_pkg.Value, i: int) -> core_pkg.Value {
	switch x in v {
	case ^core_pkg.Array:
		return x.items[i] if i >= 0 && i < len(x.items) else nil
	case core_pkg.Node_Ref:
		// Only an array `index_shared` would index, so a shared document is never written here.
		if i >= INDEX_MEMBERS_FROM && i < core_pkg.length(x.doc, x.node) {
			core_pkg.index_children(x.doc, x.node)
		}
		if node, ok := core_pkg.child_at(x.doc, x.node, i); ok {
			return core_pkg.Node_Ref{x.doc, node}
		}
		return nil
	case core_pkg.Trail:
		if i < 0 || i >= x.depth {
			return nil
		}
		s := (^core_pkg.Trail_Step)(x)
		for s.depth > i + 1 {
			s = s.parent
		}
		return s.key
	case ^core_pkg.Commented:
		return array_at(x.v, i)
	case nil, bool, f64, core_pkg.Number_View, string, ^core_pkg.Object:
	}
	return nil
}

// Member `k` of an object, and whether it is there.
@(private)
object_get :: proc(v: core_pkg.Value, k: string) -> (core_pkg.Value, bool) {
	switch x in v {
	case ^core_pkg.Object:
		i := core_pkg.object_slot(x, k)
		if i < 0 {
			return nil, false
		}
		return x.slot_vals[i], true
	case core_pkg.Node_Ref:
		if core_pkg.is_markup(x.doc) {
			return core_pkg.markup_member(x, k)
		}
		node, ok := core_pkg.member(x.doc, x.node, k)
		if !ok {
			return nil, false
		}
		return core_pkg.Node_Ref{x.doc, node}, true
	case ^core_pkg.Commented:
		return object_get(x.v, k)
	case nil, bool, f64, core_pkg.Number_View, string, ^core_pkg.Array, core_pkg.Trail:
	}
	return nil, false
}

// Elements `lo` to `hi` of an array as a new array, for `lo <= hi <= length_of(v)`.
@(private)
array_slice :: proc(value: core_pkg.Value, lo, hi: int) -> ^core_pkg.Array {
	v := core_pkg.plain(value)
	if x, is_array := v.(^core_pkg.Array); is_array && lo < hi {
		a := new(core_pkg.Array)
		// At its capacity, the slice moves before anything appends to it, so it writes nothing into `x`.
		(^runtime.Raw_Dynamic_Array)(&a.items)^ = {data = &x.items[lo], len = hi - lo, cap = hi - lo, allocator = context.allocator}
		if !core_pkg.lent(x) {
			intrinsics.atomic_store_explicit(&x.lent, true, .Relaxed) // a global array may be sliced on many threads
		}
		return a
	}
	a := core_pkg.new_array(hi - lo)
	r, is_ref := v.(core_pkg.Node_Ref)
	if !is_ref {
		for i in lo ..< hi {
			append(&a.items, array_at(v, i))
		}
		return a
	}
	if lo >= INDEX_MEMBERS_FROM {
		core_pkg.index_children(r.doc, r.node)
	}
	it := core_pkg.children_from(r.doc, r.node, lo)
	for _ in lo ..< hi {
		node, _ := core_pkg.child_next(&it)
		append(&a.items, core_pkg.Node_Ref{r.doc, node})
	}
	return a
}

// A container's own copy, one level deep: its members are shared. Scalars are returned as they are.
@(private)
own :: proc(value: core_pkg.Value) -> core_pkg.Value {
	v := core_pkg.plain(value)
	switch kind(v) {
	case .Array:
		a := core_pkg.new_array(length_of(v))
		if x, is_array := v.(^core_pkg.Array); is_array {
			append(&a.items, ..x.items[:])
			return a
		}
		it := iterate(v)
		for _, m in next_member(&it) {
			append(&a.items, m)
		}
		return a
	case .Object:
		// `iterate` yields each key once, so the members are appended as they come, and indexed once.
		o := core_pkg.new_object()
		if x, is_object := v.(^core_pkg.Object); is_object {
			o.slot_keys, o.slot_vals = slice.clone_to_dynamic(core_pkg.object_keys(x)), slice.clone_to_dynamic(core_pkg.object_vals(x))
		} else {
			it := iterate(v)
			reserve(&o.slot_keys, it.n)
			reserve(&o.slot_vals, it.n)
			for k, m in next_member(&it) {
				append(&o.slot_keys, k)
				append(&o.slot_vals, m)
			}
		}
		if core_pkg.object_length(o) >= core_pkg.INDEX_FROM {
			core_pkg.reindex(o)
		}
		return o
	case .Null, .False, .True, .Number, .String:
	}
	return scalar(v)
}

// The members of a container in order: an array's elements, an object's values with their keys. A
// document object's repeated key yields once, at its first place, with its last value, as jq reads it, or a markup
// document's with the array of each of its values (`core.markup_members`).
Members :: struct {
	v:     core_pkg.Value,
	i, n:  int,
	items: core_pkg.Child_Iter, // a document array's
	pairs: core_pkg.Pair_Iter, // a document object's
	array: bool, // a document's array: its nodes have no keys
	last:  ^map[string]core_pkg.Node_Index, // when a key repeats: a key's last node, 0 once yielded
	dupes: bool,
}

iterate :: proc(value: core_pkg.Value) -> Members {
	v := core_pkg.plain(value)
	r, is_ref := v.(core_pkg.Node_Ref)
	if !is_ref {
		return Members{v = v, n = length_of(v)}
	}
	it := Members{v = v, n = core_pkg.length(r.doc, r.node)} // the nodes, a repeated key's too
	if it.n > 0 {
		if core_pkg.kind(r.doc, r.node) == .Array {
			it.array = true
			it.items = core_pkg.children(r.doc, r.node)
		} else {
			it.pairs = core_pkg.pairs(r.doc, r.node)
			it.dupes = core_pkg.has_repeated_key(r)
			if it.dupes && core_pkg.is_markup(r.doc) {
				members := core_pkg.markup_members(r)
				return Members{v = members, n = len(core_pkg.object_keys(members))}
			}
			if it.dupes {
				it.last = new(map[string]core_pkg.Node_Index)
				all := it.pairs
				for kn, vn in core_pkg.pair_next(&all) {
					it.last[node_string(r.doc, kn)] = vn
				}
			}
		}
	}
	return it
}

// Whether an object in the subtree of `r` repeats a key.
@(private)
repeats_key :: proc(r: core_pkg.Node_Ref) -> bool {
	t := r.doc.nodes[r.node]
	end := r.node + (1 if t.kind < .Array else core_pkg.Node_Index(t.n))
	for i := r.node; i < end; i += 1 {
		if r.doc.nodes[i].kind == .Object && core_pkg.has_repeated_key({r.doc, i}) {
			return true
		}
	}
	return false
}

// An array of document nodes that a sort or a group made reads them in an order unrelated to their text, so a member's
// node is fetched 2 * FETCH_AHEAD members before it is read and the first bytes of its text FETCH_AHEAD members before,
// all of the first ones at once.
@(private = "file")
fetch_ahead :: #force_inline proc(items: []core_pkg.Value, i: int) {
	if i == 0 {
		for j in 1 ..< min(len(items), 2 * FETCH_AHEAD) {
			fetch_node(items[j])
		}
		for j in 1 ..< min(len(items), FETCH_AHEAD) {
			fetch_text(items[j])
		}
	}
	if i + 2 * FETCH_AHEAD < len(items) {
		fetch_node(items[i + 2 * FETCH_AHEAD])
	}
	if i + FETCH_AHEAD < len(items) {
		fetch_text(items[i + FETCH_AHEAD])
	}
}

@(private = "file")
fetch_node :: #force_inline proc(v: core_pkg.Value) {
	if r, is_ref := v.(core_pkg.Node_Ref); is_ref {
		intrinsics.prefetch_read_data(&r.doc.nodes[r.node], 3)
		intrinsics.prefetch_read_data(&r.doc.nodes[min(int(r.node) + 8, len(r.doc.nodes) - 1)], 3)
	}
}

@(private = "file")
fetch_text :: #force_inline proc(v: core_pkg.Value) {
	if r, is_ref := v.(core_pkg.Node_Ref); is_ref && len(r.doc.src) > 0 {
		at := r.doc.nodes[r.node].lo
		intrinsics.prefetch_read_data(&r.doc.src[min(at, u64(len(r.doc.src) - 1))], 3)
		intrinsics.prefetch_read_data(&r.doc.src[min(at + 64, u64(len(r.doc.src) - 1))], 3)
	}
}

@(private)
FETCH_AHEAD :: 8

next_member :: #force_inline proc(it: ^Members) -> (key: string, v: core_pkg.Value, ok: bool) {
	for it.i < it.n {
		i := it.i
		it.i += 1
		switch x in it.v {
		case ^core_pkg.Array:
			fetch_ahead(x.items[:], i)
			return "", x.items[i], true
		case core_pkg.Trail:
			a := path_array((^core_pkg.Trail_Step)(x)) // made at the first member, read as an array from then on
			it.v = a
			return "", a.items[i], true
		case ^core_pkg.Object:
			return core_pkg.object_keys(x)[i], core_pkg.object_vals(x)[i], true
		case core_pkg.Node_Ref:
			if it.array {
				node, _ := core_pkg.child_next(&it.items)
				return "", core_pkg.Node_Ref{x.doc, node}, true
			}
			kn, vn, _ := core_pkg.pair_next(&it.pairs)
			k := node_string(x.doc, kn)
			if !it.dupes {
				return k, core_pkg.Node_Ref{x.doc, vn}, true
			}
			if it.last[k] == 0 {
				continue
			}
			vn = it.last[k]
			it.last[k] = 0
			return k, core_pkg.Node_Ref{x.doc, vn}, true
		case nil, bool, f64, core_pkg.Number_View, string, ^core_pkg.Commented: // `iterate` takes off a `^Commented`
		}
	}
	return "", nil, false
}

// `v`'s property `name`: the filter's write, else the value of its node's fact, a number when the fact spells one.
property_value :: proc(v: core_pkg.Value, name: core_pkg.Fact_Kind) -> core_pkg.Value {
	if c, is_commented := v.(^core_pkg.Commented); is_commented {
		if role := core_pkg.FACTS[name].role; role != .Value && role in c.written {
			return c.bodies[role][0] if len(c.bodies[role]) > 0 else nil
		}
	}
	r, is_ref := core_pkg.facts_node(v)
	if !is_ref {
		return nil
	}
	fv, held := core_pkg.fact_value(r.doc, r.node, name)
	if !held {
		return nil
	}
	if fv.numeric {
		if n, is_number := read_number(fv.text); is_number {
			return n
		}
	}
	return fv.text
}
