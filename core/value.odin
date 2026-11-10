package core

// A value of the library in either form: a node of a document (`Node_Ref`) or a value built in memory. A number built
// is a double, or the digits of one that no double holds or that was read and not computed on (`Number_Text`). A built value
// lives in the allocator it was made with, usually an arena, and has no destructor. It is not changed once shared,
// and a slice of an array marks the array `lent`, which a writer copies before changing it.
//
// The readers have the document readers' names and take either form. An object is its members in the order they were
// added, repeats allowed: `member`, `equal`, `hash` and the order see the last member of each name, and `pairs`,
// `length` and the writer see all of them.

import "spell"

// `nil` is null.
Value :: union {
	bool,
	f64,
	^Number_Text,
	string,
	^Array,
	^Object,
	Node_Ref,
	^Commented,
	Trail,
}

#assert(size_of(Value) == 24)

// A number's text: an integer no double holds exactly, or a number read and not computed on, whose digits are kept, with
// the double they round to. `text` is a JSON number. As a typed target it takes any number, and an `any` holds a number
// no integer or binary64 reads as one.
Number_Text :: struct {
	text:   string,
	double: f64,
}

// A `Number_Text` of `text`, a JSON number, in `allocator`. `text` is not copied.
number_text :: proc(text: string, allocator := context.allocator) -> ^Number_Text {
	n := new(Number_Text, allocator)
	n^ = {text, text_f64(text)}
	return n
}

Array :: struct {
	items: [dynamic]Value,
	lent:  bool,
}

// `index` maps a key to its slot once the object has `INDEX_FROM` members.
Object :: struct {
	keys:  [dynamic]string,
	vals:  [dynamic]Value,
	index: map[string]int,
}

kind :: proc {
	doc_kind,
	value_kind,
}

child_at :: proc {
	doc_child_at,
	value_child_at,
}

length :: proc {
	doc_length,
	value_length,
}

member :: proc {
	doc_member,
	value_member,
}

children :: proc {
	doc_children,
	value_children,
}

child_next :: proc {
	doc_child_next,
	value_child_next,
}

pairs :: proc {
	doc_pairs,
	value_pairs,
}

pair_next :: proc {
	doc_pair_next,
	value_pair_next,
}

text :: proc {
	doc_text,
	value_text,
}

number :: proc {
	doc_number,
	value_number,
}

// The kind of `v`. A node's is the document's `kind`, which reads a `Plain` cell as its format does.
value_kind :: #force_inline proc(v: Value) -> Kind {
	switch x in v {
	case nil:
		return .Null
	case bool:
		return .True if x else .False
	case f64, ^Number_Text:
		return .Number
	case string:
		return .String
	case ^Array, Trail:
		return .Array
	case ^Object:
		return .Object
	case Node_Ref:
		return doc_kind(x.doc, x.node)
	case ^Commented:
		return x.kind
	}
	return .Null
}

// The number of members of a container, a repeated key's each time, or 0 for a scalar.
value_length :: #force_inline proc(v: Value) -> int {
	#partial switch x in plain(v) {
	case ^Array:
		return len(x.items)
	case ^Object:
		return len(x.keys)
	case Node_Ref:
		return doc_length(x.doc, x.node)
	case Trail:
		return x.depth
	}
	return 0
}

// Member `k` of array `v`, counted from 0, or false past its end or for anything else.
value_child_at :: proc(v: Value, k: int) -> (Value, bool) {
	#partial switch x in plain(v) {
	case ^Array:
		if k >= 0 && k < len(x.items) {
			return x.items[k], true
		}
	case Node_Ref:
		if node, ok := doc_child_at(x.doc, x.node, k); ok && doc_kind(x.doc, x.node) == .Array {
			return Node_Ref{x.doc, node}, true
		}
	case Trail:
		if k >= 0 && k < x.depth {
			s := (^Trail_Step)(x)
			for s.depth > k + 1 {
				s = s.parent
			}
			return s.key, true
		}
	}
	return nil, false
}

// The value of the member of object `v` named `name`, the first under `.First` and else the last.
value_member :: #force_inline proc(v: Value, name: string, dups := Duplicates.Last) -> (Value, bool) {
	#partial switch x in plain(v) {
	case ^Object:
		i := object_slot(x, name) if dups != .First else first_slot(x, name)
		if i < 0 {
			return nil, false
		}
		return x.vals[i], true
	case Node_Ref:
		node, ok := doc_member(x.doc, x.node, name, dups)
		if !ok {
			return nil, false
		}
		return Node_Ref{x.doc, node}, true
	}
	return nil, false
}

@(private = "file")
first_slot :: proc(o: ^Object, k: string) -> int {
	for key, i in o.keys {
		if key == k {
			return i
		}
	}
	return -1
}

// A `Value_Iter` walks the members of a container: an array's elements, an object's values, or with `value_pairs`
// an object's keys and values, in order and a repeated key's each time.
Value_Iter :: struct {
	v:     Value,
	i:     int,
	nodes: Child_Iter,
	pairs: Pair_Iter,
}

// Starts a `Value_Iter` over the members of `v`. A scalar has none. A trail's array is made here, in the context
// allocator.
value_children :: proc(v: Value) -> Value_Iter {
	it := Value_Iter{v = plain(v)}
	#partial switch x in it.v {
	case Node_Ref:
		it.nodes = doc_children(x.doc, x.node)
	case Trail:
		it.v = trail_array(x)
	}
	return it
}

value_child_next :: #force_inline proc(it: ^Value_Iter) -> (Value, bool) {
	#partial switch x in it.v {
	case ^Array:
		if it.i < len(x.items) {
			it.i += 1
			return x.items[it.i - 1], true
		}
	case ^Object:
		if it.i < len(x.vals) {
			it.i += 1
			return x.vals[it.i - 1], true
		}
	case Node_Ref:
		if node, ok := doc_child_next(&it.nodes); ok {
			return Node_Ref{x.doc, node}, true
		}
	}
	return nil, false
}

// Starts a `Value_Iter` over the keys and values of object `v`. Anything else has none.
value_pairs :: proc(v: Value) -> Value_Iter {
	it := Value_Iter{v = plain(v)}
	if r, is_ref := it.v.(Node_Ref); is_ref {
		it.pairs = doc_pairs(r.doc, r.node)
	}
	return it
}

// Returns the next key and value. A node's key that needs decoding is decoded into the context allocator.
value_pair_next :: #force_inline proc(it: ^Value_Iter) -> (key: string, val: Value, ok: bool) {
	#partial switch x in it.v {
	case ^Object:
		if it.i < len(x.keys) {
			it.i += 1
			return x.keys[it.i - 1], x.vals[it.i - 1], true
		}
	case Node_Ref:
		if k, n, has := doc_pair_next(&it.pairs); has {
			return node_string(x.doc, k), Node_Ref{x.doc, n}, true
		}
	}
	return "", nil, false
}

// The decoded text of a string or a key node, a slice of the source or a decode made in the context allocator.
node_string :: proc(doc: ^Document, i: Node_Index) -> string {
	if s, ok := doc_text(doc, i, nil); ok {
		return s
	}
	s, _ := text_clone(doc, i)
	return s
}

// The text of string `v`. A node's is the document's `text`, written into `buf` when it needs decoding.
value_text :: #force_inline proc(v: Value, buf: []u8) -> (string, bool) {
	#partial switch x in plain(v) {
	case string:
		return x, true
	case Node_Ref:
		return doc_text(x.doc, x.node, buf)
	}
	return "", false
}

// The number `v` holds. A double that holds an integer of at most 53 bits is an `.Int`, any other a `.Float`. A
// `Number_Text` is read as the document's `number` reads a number's text.
value_number :: #force_inline proc(v: Value) -> (Number, bool) {
	#partial switch x in plain(v) {
	case f64:
		if abs(x) <= MAX_EXACT_INT && f64(i64(x)) == x && transmute(u64)x != 1 << 63 {
			return {bits = u64(i64(x)), kind = .Int}, true
		}
		return {bits = transmute(u64)x, kind = .Float}, true
	case ^Number_Text:
		return spell.number_strict(transmute([]u8)x.text, 0, u64(len(x.text)))
	case Node_Ref:
		return doc_number(x.doc, x.node)
	}
	return {}, false
}

// The largest integer every smaller one of which a double holds exactly.
@(private = "file")
MAX_EXACT_INT :: 1 << 53

// A path from the root as a value, read as an array of its keys from the root. Its steps are shared with the trails
// that extend it, and a reader that needs the array makes it (`value_children`).
Trail :: distinct ^Trail_Step

// One step of a path from the root, linked back toward it: `key` is the object key or array index.
Trail_Step :: struct {
	parent: ^Trail_Step,
	key:    Value,
	depth:  int, // steps from the root to this one
}

// The keys of trail `t` from the root as a new array in the context allocator.
trail_array :: proc(t: Trail) -> ^Array {
	n := t.depth if t != nil else 0
	a := new_array(n)
	resize(&a.items, n)
	trail_keys(t, a.items[:])
	return a
}

// Writes the keys of trail `t` from the root into `into`, which holds `t.depth` values.
trail_keys :: proc(t: Trail, into: []Value) {
	n := len(into)
	for s := (^Trail_Step)(t); s != nil; s = s.parent {
		n -= 1
		into[n] = s.key
	}
}
