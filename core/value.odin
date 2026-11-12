package core

// A value of the library in either form: a node of a document (`Node_Ref`) or a value built in memory. A number built
// is a double, or the digits of one that no double holds or that was read and not computed on (`Number_Text`). A built value
// lives in the allocator it was made with, usually an arena, and has no destructor. It is not changed once shared,
// and a slice of an array marks the array `lent`, which a writer copies before changing it.
//
// The readers have the document readers' names and take either form. An object is its members in the order they were
// added, repeats allowed: `member`, `equal`, `hash` and the order see the last member of each name, and `pairs`,
// `length` and the writer see all of them. An object node of a markup document has each name once, a repeated one with
// an array of each of its elements (`markup_members`), so each of them sees that.

import "core:hash"
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
// the double they round to. `text` is a JSON number. As a typed target it takes any number.
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
		n := doc_length(x.doc, x.node)
		if n > 1 && is_markup(x.doc) && has_repeated_key(x) {
			return distinct_keys(x)
		}
		return n
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

// The value of the member of object `v` named `name`, the first under `.First` and else the last. A markup node's is
// its `markup_member`, under any `dups`, whose array is made in the temp allocator.
value_member :: #force_inline proc(v: Value, name: string, dups := Duplicates.Last) -> (Value, bool) {
	#partial switch x in plain(v) {
	case ^Object:
		i := object_slot(x, name) if dups != .First else first_slot(x, name)
		if i < 0 {
			return nil, false
		}
		return x.vals[i], true
	case Node_Ref:
		if is_markup(x.doc) {
			context.allocator = context.temp_allocator
			return markup_member(x, name)
		}
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
// allocator, and a markup node's members in the temp allocator.
value_children :: proc(v: Value) -> Value_Iter {
	it := Value_Iter{v = plain(v)}
	#partial switch x in it.v {
	case Node_Ref:
		it.nodes = doc_children(x.doc, x.node)
		if is_markup(x.doc) && has_repeated_key(x) {
			context.allocator = context.temp_allocator
			it.v = markup_members(x)
		}
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

// Starts a `Value_Iter` over the keys and values of object `v`. Anything else has none. A node's `pairs` are its
// document's own, a repeated key's each time, even where the iterator reads a markup node's `markup_members`, made in
// the temp allocator.
value_pairs :: proc(v: Value) -> Value_Iter {
	it := Value_Iter{v = plain(v)}
	if r, is_ref := it.v.(Node_Ref); is_ref {
		it.pairs = doc_pairs(r.doc, r.node)
		if is_markup(r.doc) && has_repeated_key(r) {
			context.allocator = context.temp_allocator
			it.v = markup_members(r)
		}
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

// Whether object node `r` has a key that one before it has.
has_repeated_key :: proc(r: Node_Ref) -> bool {
	n := doc_length(r.doc, r.node)
	if n < 2 {
		return false
	}
	it := doc_pairs(r.doc, r.node)
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

// The number of names of object node `r`, a repeated one once. Kept out of the length readers, whose frames would
// otherwise cost every call.
distinct_keys :: #force_no_inline proc(r: Node_Ref) -> int {
	seen := make(map[string]bool, doc_length(r.doc, r.node), context.temp_allocator)
	it := doc_pairs(r.doc, r.node)
	for k in next_key(&it) {
		seen[k] = true
	}
	return len(seen)
}

// The keys of a document object in source order, a repeated one each time.
@(private = "file")
next_key :: #force_inline proc(it: ^Pair_Iter) -> (string, bool) {
	k, _, ok := doc_pair_next(it)
	if !ok {
		return "", false
	}
	return node_string(it.doc, k), true
}

// Slots of `repeats_in_table`'s open-addressed table, kept at most half full.
@(private = "file")
KEY_TABLE :: 256

// `has_repeated_key` for an object of up to KEY_TABLE / 2 members, hashed on the stack, not in a map.
@(private = "file")
repeats_in_table :: proc(it: ^Pair_Iter) -> bool {
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
