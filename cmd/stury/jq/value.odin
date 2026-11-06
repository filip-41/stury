package jq

// jq's values. An input value stays a node of its `core.Document` (`Ref`) until something builds a new
// value out of it, so a filter that only reads pays for what it reads. Built containers are immutable
// once made, except inside an update that owns them (`eval_update`). Key and value lookup is in
// lookup.odin, order and equality in compare.odin.

import "core:hash"
import "core:slice"
import "core:strconv"
import core_pkg "../../../core"
import json "../../../json"

// `nil` is jq's null.
Value :: union {
	bool,
	Number,
	string,
	^Array,
	^Object,
	Ref,
	Path,
}

// `lit` is the number as written, for a number read from input or the program and not yet computed on. It prints as
// written and a computed number prints from `f`.
Number :: struct {
	f:   f64,
	lit: string,
}

Array :: struct {
	items: [dynamic]Value,
}

// Keys keep their insertion order. `index` maps a key to its slot once the object is wide.
Object :: struct {
	keys:  [dynamic]string,
	vals:  [dynamic]Value,
	index: map[string]int,
}

// A value of an input document: a node of a text in any format, read by core's readers, which decode a node the
// document's format spells.
Ref :: struct {
	doc:  ^core_pkg.Document,
	node: core_pkg.Node_Index,
}

// A built document as a value: its root, the document moved to the heap.
document_value :: proc(d: core_pkg.Document) -> Value {
	doc := new(core_pkg.Document)
	doc^ = d
	return Ref{doc, core_pkg.ROOT}
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

num :: proc(f: f64) -> Value {
	return Number{f = f}
}

kind :: proc(v: Value) -> Kind {
	switch x in v {
	case nil:
		return .Null
	case bool:
		return .True if x else .False
	case Number:
		return .Number
	case string:
		return .String
	case ^Array, Path:
		return .Array
	case ^Object:
		return .Object
	case Ref:
		return node_kind(x.doc, x.node)
	}
	return .Null
}

// A document node's jq kind. A dsv cell is a string.
node_kind :: #force_inline proc(doc: ^core_pkg.Document, i: core_pkg.Node_Index) -> Kind {
	#partial switch k := core_pkg.kind(doc, i); k {
	case .Array:
		return .Array
	case .Map:
		return .Object
	case .Plain:
		// A delimited cell: an empty unquoted one is null, a quoted one keeps its quotes in its span.
		return .Null if doc.nodes[i].n == 0 && doc.nodes[i].role == .Value else .String
	case:
		return Kind(k)
	}
}

type_name :: proc(v: Value) -> string {
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

truthy :: proc(v: Value) -> bool {
	k := kind(v)
	return k != .Null && k != .False
}

// A `Ref` scalar as its own value. Containers stay nodes.
scalar :: proc(v: Value) -> Value {
	r, is_ref := v.(Ref)
	if !is_ref {
		return v
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

// Number node `i`. Its literal is its text, but for a spelling other than its format's plain decimal (JSON5's `+1.5`,
// `0x10`), where it is the JSON text the library writes for it.
node_number :: proc(doc: ^core_pkg.Document, i: core_pkg.Node_Index) -> Number {
	lit := string(core_pkg.span(doc, i))
	n, _ := core_pkg.number(doc, i)
	f := number_f64(n, lit)
	// The `NUMBER_*` layout holds only for a `.Number` token. A dsv cell is `.Plain`, its spelling bits mean other things.
	if doc.nodes[i].kind == .Number && doc.nodes[i].spelling & core_pkg.NUMBER_KIND_MASK != 0 {
		// A number JSON cannot write has no literal and prints as computed.
		text, _, err := core_pkg.write(doc, {}, json.as(.Json), i)
		lit = string(text) if err.kind == .None else ""
	}
	return Number{f = f, lit = lit}
}

// The binary64 of `n`, a number spelled `lit`.
number_f64 :: proc(n: core_pkg.Number, lit: string) -> f64 {
	switch n.kind {
	case .Int:
		// `-0` is an integer whose bits carry no sign
		return -0.0 if n.bits == 0 && lit[0] == '-' else f64(i64(n.bits))
	case .Uint:
		return f64(n.bits)
	case .Float:
		return transmute(f64)n.bits
	case .Wide:
	}
	// past binary64's digits or range, `1e400` among them, which strconv reads as infinity
	f, _ := strconv.parse_f64(lit)
	return f
}

// The decoded text of string or key node `i`: a slice of the source, or a decode made in the context allocator.
node_string :: proc(doc: ^core_pkg.Document, i: core_pkg.Node_Index) -> string {
	if s, ok := core_pkg.text(doc, i, nil); ok {
		return s
	}
	s, _ := core_pkg.text_clone(doc, i)
	return s
}

number_of :: proc(v: Value) -> (Number, bool) {
	n, ok := scalar(v).(Number)
	return n, ok
}

string_of :: proc(v: Value) -> (string, bool) {
	if r, is_ref := v.(Ref); is_ref {
		if node_kind(r.doc, r.node) != .String {
			return "", false
		}
		return node_string(r.doc, r.node), true
	}
	s, ok := v.(string)
	return s, ok
}

length_of :: proc(v: Value) -> int {
	switch x in v {
	case ^Array:
		return len(x.items)
	case Path:
		return x.depth
	case ^Object:
		return len(x.keys)
	case Ref:
		n := core_pkg.length(x.doc, x.node)
		if n > 1 && core_pkg.kind(x.doc, x.node) == .Map && has_repeated_key(x) {
			return distinct_keys(x)
		}
		return n
	case nil, bool, Number, string:
	}
	return 0
}

// Whether `v` has no element or member. A document's object holds one or more however its keys repeat, so
// this does not count them as `length_of` does.
is_empty :: proc(v: Value) -> bool {
	if r, is_ref := v.(Ref); is_ref {
		return core_pkg.length(r.doc, r.node) == 0
	}
	return length_of(v) == 0
}

// The keys of a document object in source order, a repeated one each time.
@(private = "file")
next_key :: #force_inline proc(it: ^core_pkg.Pair_Iter) -> (string, bool) {
	k, _, ok := core_pkg.pair_next(it)
	if !ok {
		return "", false
	}
	return node_string(it.doc, k), true
}

// The members of an object with a repeated key, which is one member, as jq reads it. Kept out of
// length_of, whose frame would otherwise cost every call, the hot ones from compare and iterate too.
@(private = "file")
distinct_keys :: #force_no_inline proc(r: Ref) -> int {
	seen := make(map[string]bool, core_pkg.length(r.doc, r.node), context.temp_allocator)
	it := core_pkg.pairs(r.doc, r.node)
	for k in next_key(&it) {
		seen[k] = true
	}
	return len(seen)
}

// A document array read at or past this position is indexed first, so each read is a lookup and not a walk from the
// first member. Below it the walk is cheaper than the index.
INDEX_MEMBERS_FROM :: 256

// Indexes every array of `v`'s documents that `array_at` or `array_slice` would index, for a value every thread of a
// run reads, before the threads start: their `index_children` calls then find the entry and write nothing.
index_shared :: proc(v: Value) {
	switch x in v {
	case Ref:
		for n, i in x.doc.nodes {
			at := core_pkg.Node_Index(i)
			if n.kind == .Array && core_pkg.length(x.doc, at) >= INDEX_MEMBERS_FROM {
				core_pkg.index_children(x.doc, at)
			}
		}
	case ^Array:
		for item in x.items {
			index_shared(item)
		}
	case ^Object:
		for val in x.vals {
			index_shared(val)
		}
	case nil, bool, Number, string, Path:
	}
}

// Element `i` of an array, or null past its end.
array_at :: proc(v: Value, i: int) -> Value {
	switch x in v {
	case ^Array:
		return x.items[i] if i >= 0 && i < len(x.items) else nil
	case Ref:
		// Only an array `index_shared` would index, so a shared document is never written here.
		if i >= INDEX_MEMBERS_FROM && i < core_pkg.length(x.doc, x.node) {
			core_pkg.index_children(x.doc, x.node)
		}
		if node, ok := core_pkg.child_at(x.doc, x.node, i); ok {
			return Ref{x.doc, node}
		}
		return nil
	case Path:
		if i < 0 || i >= x.depth {
			return nil
		}
		s := (^Path_Step)(x)
		for s.depth > i + 1 {
			s = s.parent
		}
		return s.key
	case nil, bool, Number, string, ^Object:
	}
	return nil
}

// Member `k` of an object, and whether it is there.
object_get :: proc(v: Value, k: string) -> (Value, bool) {
	switch x in v {
	case ^Object:
		i := object_slot(x, k)
		if i < 0 {
			return nil, false
		}
		return x.vals[i], true
	case Ref:
		node, ok := core_pkg.member(x.doc, x.node, k)
		if !ok {
			return nil, false
		}
		return Ref{x.doc, node}, true
	case nil, bool, Number, string, ^Array, Path:
	}
	return nil, false
}

// Elements `lo` to `hi` of an array as a new array, for `lo <= hi <= length_of(v)`.
array_slice :: proc(v: Value, lo, hi: int) -> ^Array {
	a := new_array(hi - lo)
	r, is_ref := v.(Ref)
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
		append(&a.items, Ref{r.doc, node})
	}
	return a
}

new_array :: proc(n := 0) -> ^Array {
	a := new(Array)
	a.items = make([dynamic]Value, 0, n)
	return a
}

new_object :: proc() -> ^Object {
	return new(Object)
}

// A container's own copy, one level deep: its members are shared. Scalars are returned as they are.
own :: proc(v: Value) -> Value {
	switch kind(v) {
	case .Array:
		a := new_array(length_of(v))
		if x, is_array := v.(^Array); is_array {
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
		o := new_object()
		if x, is_object := v.(^Object); is_object {
			o.keys, o.vals = slice.clone_to_dynamic(x.keys[:]), slice.clone_to_dynamic(x.vals[:])
		} else {
			it := iterate(v)
			reserve(&o.keys, it.n)
			reserve(&o.vals, it.n)
			for k, m in next_member(&it) {
				append(&o.keys, k)
				append(&o.vals, m)
			}
		}
		if len(o.keys) >= INDEX_FROM {
			reindex(o)
		}
		return o
	case .Null, .False, .True, .Number, .String:
	}
	return scalar(v)
}

// The members of a container in order: an array's elements, an object's values with their keys. A
// document object's repeated key yields once, at its first place, with its last value, as jq reads it.
Members :: struct {
	v:     Value,
	i, n:  int,
	items: core_pkg.Child_Iter, // a document array's
	pairs: core_pkg.Pair_Iter, // a document object's
	array: bool, // a document's array: its nodes have no keys
	last:  ^map[string]core_pkg.Node_Index, // when a key repeats: a key's last node, 0 once yielded
	dupes: bool,
}

iterate :: proc(v: Value) -> Members {
	r, is_ref := v.(Ref)
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
			it.dupes = has_repeated_key(r)
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

has_repeated_key :: proc(r: Ref) -> bool {
	n := core_pkg.length(r.doc, r.node)
	if n < 2 {
		return false
	}
	it := core_pkg.pairs(r.doc, r.node)
	if n <= 16 {
		keys: [16]string = ---
		// A key's length and end bytes set a bit, so only a key whose bit is set is compared with the ones before it.
		seen: [4]u64
		i := 0
		for k in next_key(&it) {
			h := u32(len(k))
			if len(k) > 0 {
				h = h * 7 + u32(k[0]) * 31 + u32(k[len(k) - 1]) * 131
			}
			bit := u64(1) << (h & 63)
			if seen[(h >> 6) & 3] & bit != 0 {
				for prev in keys[:i] {
					if prev == k {
						return true
					}
				}
			}
			seen[(h >> 6) & 3] |= bit
			keys[i] = k
			i += 1
		}
		return false
	}
	if n <= KEY_TABLE / 2 {
		return repeats_in_table(&it)
	}
	seen := make(map[string]bool, n, context.temp_allocator)
	defer delete(seen)
	for k in next_key(&it) {
		if k in seen {
			return true
		}
		seen[k] = true
	}
	return false
}

// Whether an object in the subtree of `r` repeats a key.
repeats_key :: proc(r: Ref) -> bool {
	end := r.node + core_pkg.Node_Index(r.doc.nodes[r.node].n)
	for i := r.node; i < end; i += 1 {
		if r.doc.nodes[i].kind == .Map && has_repeated_key({r.doc, i}) {
			return true
		}
	}
	return false
}

// Slots of `repeats_in_table`'s open-addressed table, kept at most half full.
@(private = "file")
KEY_TABLE :: 256

// `has_repeated_key` for an object of up to KEY_TABLE / 2 members, hashed on the stack, not in a map.
@(private = "file")
repeats_in_table :: proc(it: ^core_pkg.Pair_Iter) -> bool {
	slots: [KEY_TABLE]u8 // a key's place in `keys`, plus one, 0 is empty
	keys: [KEY_TABLE / 2]string = ---
	i := 0
	for k in next_key(it) {
		h := hash.fnv32a(transmute([]byte)k)
		for s := h % KEY_TABLE;; s = (s + 1) % KEY_TABLE {
			if slots[s] == 0 {
				keys[i] = k
				i += 1
				slots[s] = u8(i)
				break
			}
			if keys[slots[s] - 1] == k {
				return true
			}
		}
	}
	return false
}

next_member :: #force_inline proc(it: ^Members) -> (key: string, v: Value, ok: bool) {
	for it.i < it.n {
		i := it.i
		it.i += 1
		switch x in it.v {
		case ^Array:
			return "", x.items[i], true
		case Path:
			a := path_array((^Path_Step)(x)) // made at the first member, read as an array from then on
			it.v = a
			return "", a.items[i], true
		case ^Object:
			return x.keys[i], x.vals[i], true
		case Ref:
			if it.array {
				node, _ := core_pkg.child_next(&it.items)
				return "", Ref{x.doc, node}, true
			}
			kn, vn, _ := core_pkg.pair_next(&it.pairs)
			k := node_string(x.doc, kn)
			if !it.dupes {
				return k, Ref{x.doc, vn}, true
			}
			if it.last[k] == 0 {
				continue
			}
			vn = it.last[k]
			it.last[k] = 0
			return k, Ref{x.doc, vn}, true
		case nil, bool, Number, string:
		}
	}
	return "", nil, false
}

// An object's keys, sorted by codepoint as `keys` lists them.
sorted_keys :: proc(v: Value) -> []string {
	it := iterate(v)
	ks := make([dynamic]string, 0, it.n)
	for k in next_member(&it) {
		append(&ks, k)
	}
	slice.sort(ks[:])
	return ks[:]
}
