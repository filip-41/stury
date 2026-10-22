package jq

// Sorting, grouping, uniqueness, and extrema (`sort`, `unique`, `sort_by`, `group_by`, `unique_by`,
// `min`, `max`, `min_by`, `max_by`).

import "core:math"
import "core:slice"

// One element of a sort key, resolved once: a document string or number is read out of its row before
// the sort rather than at each of its comparisons. An object atom's `f` is set by `sort_object_keys`,
// which must run before any key is compared.
Sort_Atom :: struct {
	kind: Kind,
	s:    string, // a string, or a number's literal
	f:    f64, // a number's double; an object's place in `object_members`
	v:    Value,
}

// `key` is the sort key's elements (`by`'s array), or the element itself as the one atom.
@(private = "file")
Keyed :: struct {
	key: []Sort_Atom,
	v:   Value,
}

// The depth compare() sees an atom at: inside the key array, or the element itself.
@(private = "file", thread_local)
atom_depth: int

sort_atom :: proc(v: Value) -> Sort_Atom {
	x := scalar(v)
	a := Sort_Atom{kind = kind(x), v = x}
	#partial switch y in x {
	case string:
		a.s = y
	case Number:
		a.f, a.s = y.f, y.lit
	}
	return a
}

// compare() of the two atoms' values, with strings and differing numbers settled here.
compare_atoms :: proc(a, b: Sort_Atom) -> int {
	if a.kind != b.kind {
		return -1 if a.kind < b.kind else 1
	}
	#partial switch a.kind {
	case .Null, .False, .True:
		return 0
	case .String:
		return text_order(a.s, b.s)
	case .Object:
		return compare_members(object_members[int(a.f)], object_members[int(b.f)], atom_depth, false)
	case .Number:
		if a.f < b.f {
			return -1
		}
		if a.f > b.f {
			return 1
		}
		if a.f == b.f && (a.s == b.s || a.s == "" || b.s == "") {
			return 0 // only two literals that differ are compared as decimals
		}
	}
	return compare(a.v, b.v, atom_depth)
}

// compare() of the two sort keys: element-wise, then the shorter first.
@(private = "file")
compare_keys :: proc(a, b: []Sort_Atom) -> int {
	for i in 0 ..< min(len(a), len(b)) {
		if c := compare_atoms(a[i], b[i]); c != 0 {
			return c
		}
	}
	return -1 if len(a) < len(b) else (1 if len(a) > len(b) else 0)
}

// The places of `ks` in their keys' order: a bottom-up merge sort. Equal keys keep input order.
@(private = "file")
sorted_order :: proc(ks: []Keyed) -> []int {
	n := len(ks)
	a, b := make([]int, n), make([]int, n)
	for i in 0 ..< n {
		a[i] = i
	}
	for width := 1; width < n; width *= 2 {
		for lo := 0; lo < n; lo += 2 * width {
			mid, hi := min(lo + width, n), min(lo + 2 * width, n)
			i, j, k := lo, mid, lo
			for i < mid && j < hi {
				// The left key is asked whether it is above the right, as jq's qsort asks: a nan is below
				// every key, another nan too, so keys of nan keep their input order.
				if compare_keys(ks[a[i]].key, ks[a[j]].key) > 0 {
					b[k], j = a[j], j + 1
				} else {
					b[k], i = a[i], i + 1
				}
				k += 1
			}
			k += copy(b[k:], a[i:mid])
			copy(b[k:], a[j:hi])
		}
		a, b = b, a
	}
	return a
}

// sorted_order() of keys that are each one null, boolean or number, none nan: an LSD radix sort of the numbers' bits,
// as stable as the merge. It is nil when a key is anything else, or when two equal numbers are literals
// compare_decimals() may tell apart. The keys are `ks`', or with `items` the items themselves, read without making
// their atoms. `ties` marks each place whose key is the one before it.
@(private = "file")
number_key_order :: proc(ks: []Keyed, items: []Value = nil) -> (order: []int, ties: []bool) {
	n := len(items) if items != nil else len(ks)
	if n < 64 {
		return nil, nil
	}
	// Keys of another kind are met in the first as soon as in any, before anything is made for them.
	if first, one := key_atom(ks, items, 0); !one || first.kind != .Null && first.kind != .False && first.kind != .True && first.kind != .Number {
		return nil, nil
	}
	Placed :: struct {
		bits: u64,
		at:   int,
	}
	a, b := make([]Placed, n), make([]Placed, n)
	all_of, any_of := ~u64(0), u64(0)
	exact := true // every literal is its double's value, so equal numbers are equal decimals
	for i in 0 ..< n {
		key, one := key_atom(ks, items, i)
		if !one {
			return nil, nil
		}
		u: u64
		#partial switch key.kind {
		case .Null, .False, .True:
			u = u64(key.kind) // below every number's bits, -inf's 0x000f_ffff_ffff_ffff
		case .Number:
			f := key.f
			if math.is_nan(f) {
				return nil, nil
			}
			if f == 0 {
				f = 0 // -0 is 0's equal, and keeps its place among them
			}
			// The bits in the numbers' order: a negative's all flipped, a positive's sign set.
			u = transmute(u64)f
			u ~= ~u64(0) if u >> 63 != 0 else 1 << 63
		case:
			return nil, nil
		}
		a[i] = {u, i}
		all_of &= u
		any_of |= u
		exact = exact && short_integer(key.s)
	}
	for d in 0 ..< 8 {
		shift := 8 * uint(d)
		if ((all_of ~ any_of) >> shift) & 0xff == 0 {
			continue // every number has this byte
		}
		c: [256]int
		for p in a {
			c[(p.bits >> shift) & 0xff] += 1
		}
		at := 0
		for &x in c {
			x, at = at, at + x
		}
		for p in a {
			digit := (p.bits >> shift) & 0xff
			b[c[digit]] = p
			c[digit] += 1
		}
		a, b = b, a
	}
	order, ties = make([]int, n), make([]bool, n)
	lit, first := -1, Sort_Atom{} // the first literal of the current run of equal numbers, and its key
	for p, i in a {
		order[i] = p.at
		ties[i] = i > 0 && a[i - 1].bits == p.bits
		if exact {
			continue
		}
		if !ties[i] {
			lit = -1
		}
		key, _ := key_atom(ks, items, p.at)
		switch {
		case key.s == "":
		case lit < 0:
			lit, first = p.at, key
		case compare_atoms(first, key) != 0:
			return nil, nil
		}
	}
	return order, ties
}

// The sort key at place `i`, `ks`' or with `items` the item itself, and whether it is one atom.
@(private = "file")
key_atom :: #force_inline proc(ks: []Keyed, items: []Value, i: int) -> (Sort_Atom, bool) {
	if items != nil {
		return sort_atom(items[i]), true
	}
	if len(ks[i].key) != 1 {
		return {}, false
	}
	return ks[i].key[0], true
}

// A literal of at most 15 digits, and no point or exponent, or none: a number its double holds exactly.
@(private = "file")
short_integer :: proc(lit: string) -> bool {
	digits := lit[1:] if len(lit) > 0 && lit[0] == '-' else lit
	if len(digits) > 15 {
		return false
	}
	for c in transmute([]byte)digits {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// sorted_order() of keys that are each one string, of few distinct values (group_by on a field, say): the distinct
// strings sorted, and every element counted into its string's place. It is nil when the keys are not all one string,
// or too many differ for that to pay. `ties` as number_key_order() gives them.
@(private = "file")
string_key_order :: proc(ks: []Keyed) -> (order: []int, ties: []bool) {
	n := len(ks)
	if n < 64 {
		return nil, nil
	}
	if len(ks[0].key) != 1 || ks[0].key[0].kind != .String {
		return nil, nil
	}
	ids := make(map[string]int, 16)
	group := make([]int, n)
	for k, i in ks {
		if len(k.key) != 1 || k.key[0].kind != .String {
			return nil, nil
		}
		id, has := ids[k.key[0].s]
		if !has {
			if len(ids) >= n / 16 {
				return nil, nil
			}
			id = len(ids)
			ids[k.key[0].s] = id
		}
		group[i] = id
	}
	Distinct :: struct {
		s:  string,
		id: int,
	}
	names := make([]Distinct, len(ids))
	for s, id in ids {
		names[id] = {s, id}
	}
	slice.sort_by(names, proc(a, b: Distinct) -> bool {return a.s < b.s})
	rank := make([]int, len(ids))
	for d, r in names {
		rank[d.id] = r
	}
	start := make([]int, len(ids))
	for g in group {
		start[rank[g]] += 1
	}
	at := 0
	for &s in start {
		s, at = at, at + s
	}
	order, ties = make([]int, n), make([]bool, n)
	for g, i in group {
		order[start[rank[g]]] = i
		start[rank[g]] += 1
	}
	for i in 1 ..< n {
		ties[i] = group[order[i]] == group[order[i - 1]]
	}
	return order, ties
}

// The elements paired with themselves as their sort keys, one atom each.
@(private = "file")
keys_of :: proc(items: []Value) -> []Keyed {
	ks := make([]Keyed, len(items))
	atoms := make([]Sort_Atom, len(items))
	for x, i in items {
		atoms[i] = sort_atom(x)
		ks[i] = {key = atoms[i:i + 1], v = x}
	}
	return ks
}

// The sorted members of the objects among the atoms of the sort under way, each sorted once for
// sorted_order() and not at each of its comparisons. Kept beside the atoms, whose size sort_by on numbers pays for.
// The table is made anew in the sort's allocator each time: that may be an input's or a reduce's arena, freed
// before the next sort, which a table kept across sorts would still point into.
@(private = "file", thread_local)
object_members: [dynamic][]Member

@(private = "file")
sort_object_keys :: proc(ks: []Keyed) {
	object_members = make([dynamic][]Member)
	for i in 0 ..< len(ks) {
		atoms := ks[i].key
		for j in 0 ..< len(atoms) {
			if atoms[j].kind == .Object {
				atoms[j].f = f64(len(object_members))
				append(&object_members, sorted_members(atoms[j].v))
			}
		}
	}
}

// The places of `ks` in their keys' stable order, and which places' keys are the one before, where the
// sort knows that without comparing (nil where it does not).
@(private = "file")
sort_keyed :: proc(ip: ^Interp, ks: []Keyed, depth: int) -> (order: []int, ties: []bool, sig: Signal) {
	too_deep = false
	atom_depth = depth
	order, ties = number_key_order(ks)
	if order == nil {
		order, ties = string_key_order(ks)
	}
	if order == nil {
		sort_object_keys(ks)
		order = sorted_order(ks)
	}
	if too_deep {
		return nil, nil, fail(ip, "Comparison too deep")
	}
	return order, ties, .Go
}

@(private = "file")
Sort_Shape :: enum {
	Sorted,
	Grouped,
	Unique,
}

// What the sort builtin of `shape` makes of `items` in sort_keyed()'s order: them in order, runs of equal
// keys as groups (group_by), or each run's first (unique). `ks` are their keys, compared where `ties` is nil.
@(private = "file")
sorted_result :: proc(shape: Sort_Shape, items: []Value, ks: []Keyed, order: []int, ties: []bool) -> Value {
	grouping := shape == .Grouped
	unique := shape == .Unique
	a := new_array(0 if grouping || unique else len(items))
	group: ^Array
	for at, i in order {
		new_run := (grouping || unique) && (i == 0 || (!ties[i] if ties != nil else compare_keys(ks[order[i - 1]].key, ks[at].key) != 0))
		switch {
		case grouping:
			if new_run {
				group = new_array()
				append(&a.items, group)
			}
			append(&group.items, items[at])
		case unique:
			if new_run {
				append(&a.items, items[at])
			}
		case:
			append(&a.items, items[at])
		}
	}
	return a
}

fn_sort :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return sort_array(ip, v, .Sorted)
}

fn_unique :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return sort_array(ip, v, .Unique)
}

@(private = "file")
sort_array :: proc(ip: ^Interp, v: Value, shape: Sort_Shape) -> (Value, Signal) {
	if kind(v) != .Array {
		return nil, fail(ip, "%s (%s) cannot be sorted, as it is not an array", type_name(v), brief(v))
	}
	items := elements(v)
	// Numbers are sorted from themselves without making their keys first.
	if order, ties := number_key_order(nil, items); order != nil {
		return sorted_result(shape, items, nil, order, ties), .Go
	}
	ks := keys_of(items)
	order, ties, sig := sort_keyed(ip, ks, 0)
	if sig != .Go {
		return nil, sig
	}
	return sorted_result(shape, items, ks, order, ties), .Go
}

@(private = "file")
not_both_arrays :: proc(ip: ^Interp, v, keys: Value) -> Signal {
	return fail(ip, "%s (%s) and %s (%s) cannot be sorted, as they are not both arrays", type_name(v), brief(v), type_name(keys), brief(keys))
}

Atom_Sink :: struct {
	using sink: Sink,
	atoms:      ^[dynamic]Sort_Atom,
}

// The sort keys of `items` under `f`: its outputs on each, read into their atoms without building the arrays
// jq's `map([f])` makes.
@(private = "file")
keys_by :: proc(ip: ^Interp, f: ^Node, items: []Value, env: ^Env) -> ([]Keyed, Signal) {
	atoms := make([dynamic]Sort_Atom, 0, len(items))
	ends := make([]int, len(items))
	s := Atom_Sink{sink = {emit = proc(s: ^Sink, it: Item) -> Signal {
				append((^Atom_Sink)(s).atoms, sort_atom(it.v))
				return .Go
			}}, atoms = &atoms}
	for x, i in items {
		if sig := eval(ip, f, {v = x}, env, false, &s); sig != .Go {
			return nil, sig
		}
		ends[i] = len(atoms)
	}
	ks := make([]Keyed, len(items))
	for x, i in items {
		ks[i] = {key = atoms[ends[i - 1] if i > 0 else 0:ends[i]], v = x}
	}
	return ks, .Go
}

// `ks`' keys as the arrays jq's `map([f])` would have made, for an error message.
@(private = "file")
keys_array :: proc(ks: []Keyed) -> ^Array {
	keys := new_array(len(ks))
	for key in ks {
		a := new_array(len(key.key))
		for atom in key.key {
			append(&a.items, atom.v)
		}
		append(&keys.items, a)
	}
	return keys
}

// The elements of `input` that sort_by and min_by iterate and their keys under `f`.
@(private = "file")
keyed_elements :: proc(ip: ^Interp, f: ^Node, input: Item, env: ^Env) -> (items: []Value, ks: []Keyed, sig: Signal) {
	if k := kind(input.v); k != .Array && k != .Object {
		return nil, nil, fail(ip, "Cannot iterate over %s (%s)", type_name(input.v), brief(input.v))
	}
	items = elements(input.v)
	ks, sig = keys_by(ip, f, items, env)
	return
}

// `sort_by(f)`, `group_by(f)` and `unique_by(f)`, which jq defines as their `_impl` of `map([f])`: the
// same keys, each `f`'s outputs on an element, read into their atoms without building the arrays.
native_sort_by :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return sort_by(ip, n, input, env, track, out, .Sorted)
}

native_group_by :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return sort_by(ip, n, input, env, track, out, .Grouped)
}

native_unique_by :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return sort_by(ip, n, input, env, track, out, .Unique)
}

@(private = "file")
sort_by :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink, shape: Sort_Shape) -> Signal {
	items, ks, sig := keyed_elements(ip, n.args[0], input, env)
	if sig != .Go {
		return sig
	}
	if kind(input.v) != .Array {
		return not_both_arrays(ip, input.v, keys_array(ks))
	}
	order, ties, sorted_sig := sort_keyed(ip, ks, 1)
	if sorted_sig != .Go {
		return sorted_sig
	}
	return emit_made(out, input, sorted_result(shape, items, ks, order, ties), track)
}

// The place of the first least element of `xs` under `cmp`, or of the last greatest, as jq's min and max keep.
@(private = "file")
extreme_place :: proc(xs: []$T, want_max: bool, $cmp: proc(a, b: T) -> int) -> int {
	best := -1
	for i in 0 ..< len(xs) {
		if best < 0 {
			best = i
			continue
		}
		c := cmp(xs[i], xs[best])
		if (want_max && c >= 0) || (!want_max && c < 0) {
			best = i
		}
	}
	return best
}

// `min_by(f)` and `max_by(f)`, jq's `_min_by_impl(map([f]))` over the same keys as sort_by: the first least
// element, or the last greatest, found in one pass.
native_min_by :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return extreme_by(ip, n, input, env, track, out, false)
}

native_max_by :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return extreme_by(ip, n, input, env, track, out, true)
}

@(private = "file")
extreme_by :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink, want_max: bool) -> Signal {
	items, ks, sig := keyed_elements(ip, n.args[0], input, env)
	if sig != .Go {
		return sig
	}
	if kind(input.v) != .Array {
		keys := keys_array(ks)
		return fail(ip, "%s (%s) and %s (%s) cannot be iterated over", type_name(input.v), brief(input.v), type_name(keys), brief(keys))
	}
	too_deep = false
	atom_depth = 1
	sort_object_keys(ks)
	best := extreme_place(ks, want_max, proc(a, b: Keyed) -> int {return compare_keys(a.key, b.key)})
	if failed := compare_failed(ip, false); failed != .Go {
		return failed
	}
	return emit_made(out, input, items[best] if best >= 0 else nil, track)
}

fn_min :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return extreme(ip, v, false)
}

fn_max :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	return extreme(ip, v, true)
}

@(private = "file")
extreme :: proc(ip: ^Interp, v: Value, want_max: bool) -> (Value, Signal) {
	if kind(v) != .Array {
		return nil, fail(ip, "%s (%s) and %s (%s) cannot be iterated over", type_name(v), brief(v), type_name(v), brief(v))
	}
	items := elements(v)
	too_deep = false
	best := extreme_place(items, want_max, proc(a, b: Value) -> int {return compare(a, b)})
	if sig := compare_failed(ip, false); sig != .Go {
		return nil, sig
	}
	return items[best] if best >= 0 else nil, .Go
}
