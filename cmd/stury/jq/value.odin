package jq

// jq's values. An input value stays a row of its `json.Document` (`Ref`) until something builds a new
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

// `lit` is the number as written, for a number read from input or the program and not yet computed on:
// jq prints such a number in its canonical form of that literal, and a computed one from `f`.
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

// A value of an input document: rows over a text in any format, read by json's readers, which decode a row the
// document's dialect spells.
Ref :: struct {
	doc:  ^core_pkg.Document,
	node: core_pkg.Node,
}

// A built document as a value: its root, the document moved to the heap.
document_value :: proc(d: json.Document) -> Value {
	doc := new(json.Document)
	doc^ = d
	return Ref{doc, json.ROOT}
}


Kind :: json.Kind

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
		kd, _ := core_pkg.kind(x.doc, x.node)
		return kd
	}
	return .Null
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

// A `Ref` scalar as its own value. Containers stay rows.
scalar :: proc(v: Value) -> Value {
	r, is_ref := v.(Ref)
	if !is_ref {
		return v
	}
	n := r.doc.rows[r.node]
	switch n.kind {
	case .Null:
		return nil
	case .False:
		return false
	case .True:
		return true
	case .Number:
		lit, _ := json.number_text(r.doc, r.node) // a JSON5 spelling is respelled as JSON's
		// The library's correctly rounded value. Only one with none (`1e400`) is left to strconv's infinity.
		if num, _ := core_pkg.get_number(r.doc, r.node); num.exactness != .None {
			return Number{f = num.value, lit = lit}
		}
		f, _ := strconv.parse_f64(lit)
		return Number{f = f, lit = lit}
	case .String:
		s, _ := core_pkg.get_string(r.doc, r.node)
		return s
	case .Array, .Object:
	}
	return v
}

// The scalar of kind `kind` spelled at src[lo:hi], by the library's reader as `scalar` reads a row's: nil also for a
// container or a span that is not one scalar. A string with an escape decodes into `allocator`.
span_value :: proc(src: []byte, lo, hi: u64, kind: json.Kind, allocator := context.allocator) -> Value {
	lit := string(src[lo:hi])
	d, _, _ := json.decode_span(src, lo, hi, kind, allocator)
	switch x in d {
	case json.Null:
	case bool:
		return x
	case i64:
		return Number{f = f64(x), lit = lit}
	case u64:
		return Number{f = f64(x), lit = lit}
	case json.Number:
		return Number{f = x.value, lit = lit}
	case json.Digits:
		f, _ := strconv.parse_f64(lit)
		return Number{f = f, lit = lit}
	case string:
		return x
	}
	return nil
}

number_of :: proc(v: Value) -> (Number, bool) {
	n, ok := scalar(v).(Number)
	return n, ok
}

string_of :: proc(v: Value) -> (string, bool) {
	if r, is_ref := v.(Ref); is_ref {
		return core_pkg.get_string(r.doc, r.node)
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
		n := core_pkg.child_count(x.doc, x.node)
		kd, _ := core_pkg.kind(x.doc, x.node)
		if n > 1 && kd == .Object && has_repeated_key(x) {
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
		return core_pkg.child_count(r.doc, r.node) == 0
	}
	return length_of(v) == 0
}

// The members of an object with a repeated key, which is one member, as jq reads it. Kept out of
// length_of, whose frame would otherwise cost every call, the hot ones from compare and iterate too.
@(private = "file")
distinct_keys :: #force_no_inline proc(r: Ref) -> int {
	n := core_pkg.child_count(r.doc, r.node)
	seen := make(map[string]bool, n, context.temp_allocator)
	m := core_pkg.members(r.doc, r.node)
	for k in core_pkg.members(&m) {
		seen[k] = true
	}
	return len(seen)
}

// Element `i` of an array, or null past its end.
array_at :: proc(v: Value, i: int) -> Value {
	switch x in v {
	case ^Array:
		return x.items[i] if i >= 0 && i < len(x.items) else nil
	case Ref:
		if i < 0 || i >= core_pkg.child_count(x.doc, x.node) {
			return nil
		}
		return Ref{x.doc, core_pkg.child(x.doc, x.node, i)}
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
		row := core_pkg.child(x.doc, x.node, k)
		if row == json.NO_NODE {
			return nil, false
		}
		return Ref{x.doc, row}, true
	case nil, bool, Number, string, ^Array, Path:
	}
	return nil, false
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
	rows:  core_pkg.Members,
	array: bool, // a document's array: its rows have no keys
	seen:  ^map[string]bool, // made at the first repeated key
	dupes: bool,
}

iterate :: proc(v: Value) -> Members {
	r, is_ref := v.(Ref)
	if !is_ref {
		return Members{v = v, n = length_of(v)}
	}
	it := Members{v = v, n = core_pkg.child_count(r.doc, r.node)} // the rows, a repeated key's too
	if it.n > 0 {
		it.rows = core_pkg.children(r.doc, r.node)
		kd, _ := core_pkg.kind(r.doc, r.node)
		it.array = kd == .Array
		it.dupes = kd == .Object && has_repeated_key(r)
	}
	return it
}

has_repeated_key :: proc(r: Ref) -> bool {
	n := core_pkg.child_count(r.doc, r.node)
	if n < 2 || r.doc.distinct_keys {
		return false
	}
	if n <= 16 {
		keys: [16]string
		m := core_pkg.members(r.doc, r.node)
		i := 0
		for k in core_pkg.members(&m) {
			for prev in keys[:i] {
				if prev == k {
					return true
				}
			}
			keys[i] = k
			i += 1
		}
		return false
	}
	if n <= KEY_TABLE / 2 {
		return repeats_in_table(r)
	}
	seen := make(map[string]bool, n, context.temp_allocator)
	defer delete(seen)
	m := core_pkg.members(r.doc, r.node)
	for k in core_pkg.members(&m) {
		if k in seen {
			return true
		}
		seen[k] = true
	}
	return false
}

// Slots of `repeats_in_table`'s open-addressed table, kept at most half full.
@(private = "file")
KEY_TABLE :: 256

// `has_repeated_key` for an object of up to KEY_TABLE / 2 members, hashed on the stack, not in a map.
@(private = "file")
repeats_in_table :: proc(r: Ref) -> bool {
	slots: [KEY_TABLE]u8 // a key's place in `keys`, plus one; 0 is empty
	keys: [KEY_TABLE / 2]string = ---
	m := core_pkg.members(r.doc, r.node)
	i := 0
	for k in core_pkg.members(&m) {
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
			row, _ := core_pkg.children(&it.rows)
			if it.array {
				return "", Ref{x.doc, row}, true
			}
			k, _ := core_pkg.get_key(x.doc, row)
			if !it.dupes {
				return k, Ref{x.doc, row}, true
			}
			if it.seen == nil {
				it.seen = new(map[string]bool)
			}
			if it.seen[k] {
				continue
			}
			it.seen[k] = true
			return k, Ref{x.doc, core_pkg.child(x.doc, x.node, k)}, true
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
