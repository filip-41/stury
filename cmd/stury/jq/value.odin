package jq

// jq's values. An input value stays a row of its `json.Document` (`Ref`) until something builds a new
// value out of it, so a filter that only reads pays for what it reads. Built containers are immutable
// once made, except inside an update that owns them (`eval_update`).

import "core:hash"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import json "../../../json"
import enc "../../../json/encode"

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

// A value of an input document.
Ref :: struct {
	doc:  ^json.Document,
	node: json.Node,
}

// A built document as a value: its root, the document moved to the heap.
document_value :: proc(d: json.Document) -> Value {
	doc := new(json.Document)
	doc^ = d
	return Ref{doc, json.ROOT}
}

INDEX_FROM :: 16

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
		kd, _ := json.kind(x.doc, x.node)
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
		lit := string(r.doc.src[n.lo:n.hi])
		// The library's correctly rounded value. Only one with none (`1e400`) is left to strconv's infinity.
		if num, _ := json.get_number(r.doc, r.node); num.exactness != .None {
			return Number{f = num.value, lit = lit}
		}
		f, _ := strconv.parse_f64(lit)
		return Number{f = f, lit = lit}
	case .String:
		s, _ := json.get_string(r.doc, r.node)
		return s
	case .Array, .Object:
	}
	return v
}

number_of :: proc(v: Value) -> (Number, bool) {
	n, ok := scalar(v).(Number)
	return n, ok
}

string_of :: proc(v: Value) -> (string, bool) {
	s, ok := scalar(v).(string)
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
		n := json.child_count(x.doc, x.node)
		kd, _ := json.kind(x.doc, x.node)
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
		return json.child_count(r.doc, r.node) == 0
	}
	return length_of(v) == 0
}

// The members of an object with a repeated key, which is one member, as jq reads it. Kept out of
// length_of, whose frame would otherwise cost every call, the hot ones from compare and iterate too.
@(private = "file")
distinct_keys :: #force_no_inline proc(r: Ref) -> int {
	n := json.child_count(r.doc, r.node)
	seen := make(map[string]bool, n, context.temp_allocator)
	m := json.members(r.doc, r.node)
	for k in json.members(&m) {
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
		if i < 0 || i >= json.child_count(x.doc, x.node) {
			return nil
		}
		return Ref{x.doc, json.child(x.doc, x.node, i)}
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
		row := json.child(x.doc, x.node, k)
		if row == json.NO_NODE {
			return nil, false
		}
		return Ref{x.doc, row}, true
	case nil, bool, Number, string, ^Array, Path:
	}
	return nil, false
}

object_slot :: proc(o: ^Object, k: string) -> int {
	if len(o.index) > 0 {
		i, has := o.index[k]
		return i if has else -1
	}
	for key, i in o.keys {
		if key == k {
			return i
		}
	}
	return -1
}

// Set `k` in an object being built, in place: a repeated key keeps its slot and takes the new value.
object_put :: proc(o: ^Object, k: string, v: Value) {
	if i := object_slot(o, k); i >= 0 {
		o.vals[i] = v
		return
	}
	make_room(&o.keys)
	make_room(&o.vals)
	append(&o.keys, k)
	append(&o.vals, v)
	if len(o.index) > 0 {
		o.index[k] = len(o.keys) - 1
	} else if len(o.keys) == INDEX_FROM {
		reindex(o)
	}
}

// `o`'s key index made again from its keys.
@(private = "file")
reindex :: proc(o: ^Object) {
	clear(&o.index)
	for key, i in o.keys {
		o.index[key] = i
	}
}

// Room in `a` for one more, the room doubled from 2: append's first reserve is 8, mostly unused by the
// small arrays and objects a filter builds by the million (`[.a, .b]`, `{key, value}`), and none of it is
// freed before the input is.
make_room :: #force_inline proc(a: ^[dynamic]$T) {
	if n := len(a); n == cap(a) {
		reserve(a, max(2, 2 * n))
	}
}

object_delete :: proc(o: ^Object, k: string) {
	i := object_slot(o, k)
	if i < 0 {
		return
	}
	ordered_remove(&o.keys, i)
	ordered_remove(&o.vals, i)
	if len(o.index) > 0 {
		reindex(o)
	}
}

// `o` without the keys in `gone`, in one pass however many there are.
object_delete_all :: proc(o: ^Object, gone: map[string]bool) {
	kept := 0
	for k, i in o.keys {
		if !gone[k] {
			o.keys[kept], o.vals[kept] = k, o.vals[i]
			kept += 1
		}
	}
	if kept == len(o.keys) {
		return
	}
	resize(&o.keys, kept)
	resize(&o.vals, kept)
	if len(o.index) > 0 {
		reindex(o)
	}
}

new_array :: proc(n := 0) -> ^Array {
	a := new(Array)
	a.items = make([dynamic]Value, 0, n)
	return a
}

new_object :: proc() -> ^Object {
	return new(Object)
}

// Returns an object of `keys` and their `vals`, one value per key, taking ownership of both. The keys must be
// distinct.
object_from :: proc(keys: [dynamic]string, vals: [dynamic]Value) -> ^Object {
	o := new(Object)
	o.keys, o.vals = keys, vals
	if len(keys) >= INDEX_FROM {
		reindex(o)
	}
	return o
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
	rows:  json.Members,
	seen:  map[string]bool,
	dupes: bool,
}

iterate :: proc(v: Value) -> Members {
	r, is_ref := v.(Ref)
	if !is_ref {
		return Members{v = v, n = length_of(v)}
	}
	it := Members{v = v, n = json.child_count(r.doc, r.node)} // the rows, a repeated key's too
	if it.n > 0 {
		it.rows = json.children(r.doc, r.node)
		kd, _ := json.kind(r.doc, r.node)
		it.dupes = kd == .Object && has_repeated_key(r)
	}
	return it
}

has_repeated_key :: proc(r: Ref) -> bool {
	n := json.child_count(r.doc, r.node)
	if n < 2 {
		return false
	}
	if n <= 16 {
		keys: [16]string
		m := json.members(r.doc, r.node)
		i := 0
		for k in json.members(&m) {
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
	m := json.members(r.doc, r.node)
	for k in json.members(&m) {
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
	m := json.members(r.doc, r.node)
	i := 0
	for k in json.members(&m) {
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
			row, _ := json.children(&it.rows)
			if kd, _ := json.kind(x.doc, x.node); kd == .Array {
				return "", Ref{x.doc, row}, true
			}
			k, _ := json.get_key(x.doc, row)
			if !it.dupes {
				return k, Ref{x.doc, row}, true
			}
			if it.seen[k] {
				continue
			}
			it.seen[k] = true
			return k, Ref{x.doc, json.child(x.doc, x.node, k)}, true
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

// The null, boolean, number and string elements of an array, found again by value in one lookup and not a scan.
// Numbers are keyed by their double and chained, for two literals of one double that compare() tells apart.
Scalar_Index :: struct {
	has:     [Kind]bool, // an element of this kind is there (what null, false and true need)
	numbers: map[f64]int, // a number's double to the last of the numbers with it, in `nums`
	chain:   [dynamic]int, // the number before it with that double, or -1
	nums:    [dynamic]Value,
	texts:   map[string]bool,
}

// Whether `n` lookups of the elements of another array are worth indexing the `m` elements they are looked up in.
worth_indexing :: proc(m, n: int) -> bool {
	return n >= 16 && m * n > 1024
}

index_scalars :: proc(xs: []Value) -> (ix: Scalar_Index) {
	ix.numbers = make(map[f64]int, context.temp_allocator)
	ix.texts = make(map[string]bool, context.temp_allocator)
	for x in xs {
		k := kind(x)
		ix.has[k] = true
		#partial switch k {
		case .Number:
			n, _ := number_of(x)
			prev, seen := ix.numbers[n.f + 0] // + 0: -0 and 0 are one key
			ix.numbers[n.f + 0] = len(ix.nums)
			append(&ix.chain, prev if seen else -1)
			append(&ix.nums, x)
		case .String:
			s, _ := string_of(x)
			ix.texts[s] = true
		}
	}
	return
}

// Whether an element of the indexed array equals the scalar `v` (a string only exactly), and whether `v` is a
// scalar, which no other element can be found equal to.
index_has :: proc(ix: ^Scalar_Index, v: Value) -> (found, scalar: bool) {
	k := kind(v)
	#partial switch k {
	case .Null, .False, .True:
		return ix.has[k], true
	case .Number:
		n, _ := number_of(v)
		i, seen := ix.numbers[n.f + 0]
		for seen && i >= 0 {
			if compare(ix.nums[i], v, 0, true) == 0 {
				return true, true
			}
			i = ix.chain[i]
		}
		return false, true
	case .String:
		s, _ := string_of(v)
		return s in ix.texts, true
	}
	return false, false
}

// The members from which compare() and -S sort keys and values together: a key lookup in a document object scans
// every member, so past this many one walk over both sorted lists beats a lookup per key. Below it, a
// key-only sort and a few lookups are cheaper than sorting pairs.
WIDE_OBJECT :: 64

// Whether `v` has at least WIDE_OBJECT members. A document object's rows are counted, a repeated key's too, since
// length_of would scan them for repeats on every comparison.
is_wide :: proc(v: Value) -> bool {
	#partial switch x in v {
	case ^Object:
		return len(x.keys) >= WIDE_OBJECT
	case Ref:
		return json.child_count(x.doc, x.node) >= WIDE_OBJECT
	}
	return false
}

// One member of an object, as `sorted_members` lists it.
Member :: struct {
	key: string,
	val: Value,
}

// An object's members sorted by their keys' codepoints, each key once (a repeated key has its last value), so
// a comparison or a sorted reprint is one walk and not a key lookup per member.
sorted_members :: proc(v: Value) -> []Member {
	it := iterate(v)
	ms := make([dynamic]Member, 0, it.n)
	for k, m in next_member(&it) {
		append(&ms, Member{k, m})
	}
	slice.sort_by(ms[:], proc(a, b: Member) -> bool {return a.key < b.key})
	return ms[:]
}

// jq's order of two objects from their sorted members: the key sets, then the values in key order.
compare_members :: proc(a, b: []Member, depth: int, eq: bool) -> int {
	for i in 0 ..< min(len(a), len(b)) {
		if c := text_order(a[i].key, b[i].key); c != 0 {
			return c
		}
	}
	if len(a) != len(b) {
		return -1 if len(a) < len(b) else 1
	}
	for m, i in a {
		if c := compare(m.val, b[i].val, depth + 1, eq); c != 0 {
			return c
		}
	}
	return 0
}

compare_decimals :: proc(a, b: string) -> int {
	x, y := enc.decimal_of(a), enc.decimal_of(b)
	if x.neg != y.neg {
		return -1 if x.neg else 1
	}
	mag: int
	switch {
	case x.head == "" || y.head == "":
		mag = int(x.head != "") - int(y.head != "")
	case x.point != y.point:
		mag = -1 if x.point < y.point else 1
	case x.tail == "" && y.tail == "":
		mag = strings.compare(x.head, y.head)
	case:
		nx, ny := len(x.head) + len(x.tail), len(y.head) + len(y.tail)
		for i in 0 ..< min(nx, ny) {
			cx := x.head[i] if i < len(x.head) else x.tail[i - len(x.head)]
			cy := y.head[i] if i < len(y.head) else y.tail[i - len(y.head)]
			if cx != cy {
				mag = -1 if cx < cy else 1
				break
			}
		}
		if mag == 0 {
			mag = -1 if nx < ny else (1 if nx > ny else 0)
		}
	}
	return -mag if x.neg else mag
}

// How deep jq nests values it parses, prints, compares, checks for containment or merges.
MAX_DEPTH :: 10000

// Set when a comparison met values nested deeper than MAX_DEPTH, which jq reports as an error.
@(thread_local)
too_deep: bool

// jq's jv_cmp, or with `eq` its jv_equal, which takes a value as equal to itself without reading it: so `. == .`
// holds however deep the value is. jq's order: null < false < true < numbers < strings < arrays < objects. Arrays
// element-wise, objects by their sorted key sets and then their values in key order.
compare :: proc(a, b: Value, depth := 0, eq := false) -> int {
	if depth > MAX_DEPTH {
		too_deep = true
		return 0
	}
	if eq && same(a, b) {
		return 0
	}
	ka, kb := kind(a), kind(b)
	if ka != kb {
		return -1 if ka < kb else 1
	}
	switch ka {
	case .Null, .False, .True:
		return 0
	case .Number:
		x, _ := number_of(a)
		y, _ := number_of(b)
		// jq orders nan below every number, itself included.
		if math.is_nan(x.f) {
			return -1
		}
		if math.is_nan(y.f) {
			return 1
		}
		if x.f == y.f && x.lit != y.lit && x.lit != "" && y.lit != "" {
			// jq compares two literals as decimals, unless one is past decNumber's range and so a plain double.
			if lx, ly := enc.bounded_literal(x.lit), enc.bounded_literal(y.lit); lx != "" && ly != "" {
				return compare_decimals(lx, ly)
			}
		}
		return -1 if x.f < y.f else (1 if x.f > y.f else 0)
	case .String:
		x, _ := string_of(a)
		y, _ := string_of(b)
		return text_order(x, y)
	case .Array:
		if x, a_arr := a.(^Array); a_arr {
			if y, b_arr := b.(^Array); b_arr {
				return compare_items(x.items[:], y.items[:], depth, eq)
			}
		}
		_, a_path := a.(Path)
		_, b_path := b.(Path)
		if a_path || b_path {
			return compare_path_members(a, b, depth, eq)
		}
		na, nb := length_of(a), length_of(b)
		ia, ib := iterate(a), iterate(b)
		for _ in 0 ..< min(na, nb) {
			_, x, _ := next_member(&ia)
			_, y, _ := next_member(&ib)
			if c := compare(x, y, depth + 1, eq); c != 0 {
				return c
			}
		}
		return -1 if na < nb else (1 if na > nb else 0)
	case .Object:
		if is_wide(a) && is_wide(b) {
			return compare_members(sorted_members(a), sorted_members(b), depth, eq)
		}
		ka, kb := sorted_keys(a), sorted_keys(b)
		for i in 0 ..< min(len(ka), len(kb)) {
			if c := text_order(ka[i], kb[i]); c != 0 {
				return c
			}
		}
		if len(ka) != len(kb) {
			return -1 if len(ka) < len(kb) else 1
		}
		for k in ka {
			x, _ := object_get(a, k)
			y, _ := object_get(b, k)
			if c := compare(x, y, depth + 1, eq); c != 0 {
				return c
			}
		}
	}
	return 0
}

// Two strings' byte order. Odin's own orders an empty string with no buffer (a program's `""`) apart
// from an empty one with a buffer (an input's).
text_order :: proc(a, b: string) -> int {
	if len(a) == 0 || len(b) == 0 {
		return int(len(a) > 0) - int(len(b) > 0)
	}
	return strings.compare(a, b)
}

// `compare` of two arrays' members, then of their lengths.
compare_items :: proc(xs, ys: []Value, depth: int, eq: bool) -> int {
	for i in 0 ..< min(len(xs), len(ys)) {
		if c := compare(xs[i], ys[i], depth + 1, eq); c != 0 {
			return c
		}
	}
	return -1 if len(xs) < len(ys) else (1 if len(xs) > len(ys) else 0)
}

equal :: proc(a, b: Value) -> bool {
	return compare(a, b, eq = true) == 0
}

// Whether `a` and `b` are one container, not two alike.
@(private = "file")
same :: proc(a, b: Value) -> bool {
	#partial switch x in a {
	case ^Array:
		y, ok := b.(^Array)
		return ok && x == y
	case Path:
		y, ok := b.(Path)
		return ok && x == y
	case ^Object:
		y, ok := b.(^Object)
		return ok && x == y
	case Ref:
		y, ok := b.(Ref)
		return ok && x == y
	}
	return false
}
