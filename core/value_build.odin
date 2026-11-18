package core

// The builders of a built value and an object's key index, which they keep current. A builder allocates from the
// context allocator.

import "base:intrinsics"
import "core:math"
import "core:strings"
import "spell"

// The member count from which an object's keys are indexed.
INDEX_FROM :: 16

new_array :: proc(n := 0) -> ^Array {
	a := new(Array)
	a.items = make([dynamic]Value, 0, n)
	return a
}

new_object :: proc() -> ^Object {
	return new(Object)
}

// Whether a slice shares `a`'s items, so a writer that owns `a` copies it before changing it.
lent :: #force_inline proc(a: ^Array) -> bool {
	return intrinsics.atomic_load_explicit(&a.lent, .Relaxed)
}

// `v` appended to an array being built, in place.
array_append :: proc(a: ^Array, v: Value) {
	make_room(&a.items)
	append(&a.items, v)
}

// The slot of the last member of `o` named `k`, or -1. A dead slot is never found: it has left the index, and an object
// with no index has no dead slot.
object_slot :: proc(o: ^Object, k: string) -> int {
	if len(o.index) > 0 {
		i, has := o.index[k]
		return i if has else -1
	}
	#reverse for key, i in o.slot_keys {
		if key == k {
			return i
		}
	}
	return -1
}

// The keys of `o`'s members in order, valid until the next insert or delete. Dead slots are compacted away first, which
// writes `o`: an object read on several threads is never deleted from, since a delete changes only an object its caller
// owns.
object_keys :: #force_inline proc(o: ^Object) -> []string {
	if o.dead > 0 {
		compact(o)
	}
	return o.slot_keys[:]
}

// The values of `o`'s members, in the order of `object_keys`, under the same terms.
object_vals :: #force_inline proc(o: ^Object) -> []Value {
	if o.dead > 0 {
		compact(o)
	}
	return o.slot_vals[:]
}

// The number of `o`'s members.
object_length :: #force_inline proc(o: ^Object) -> int {
	return len(o.slot_keys) - int(o.dead)
}

// Set `k` in an object being built, in place: a key it has keeps its slot and takes the new value.
object_put :: proc(o: ^Object, k: string, v: Value) {
	if i := object_slot(o, k); i >= 0 {
		o.slot_vals[i] = v
		return
	}
	object_append(o, k, v)
}

// `k` added to `o` as a member of its own, set to `v`, whether `o` has the name or not.
object_append :: #force_inline proc(o: ^Object, k: string, v: Value) {
	make_room(&o.slot_keys)
	make_room(&o.slot_vals)
	append(&o.slot_keys, k)
	append(&o.slot_vals, v)
	if len(o.index) > 0 {
		index_slot(o, k, len(o.slot_keys) - 1)
	} else if len(o.slot_keys) == INDEX_FROM {
		reindex(o)
	}
}

// Room in `o` for `n` members in all.
object_reserve :: proc(o: ^Object, n: int) {
	reserve(&o.slot_keys, n)
	reserve(&o.slot_vals, n)
}

// `o`'s key index made again from its keys, a repeated key's at its last slot. `o` has no dead slot.
reindex :: proc(o: ^Object) {
	clear(&o.index)
	o.repeats = false
	for key, i in o.slot_keys {
		index_slot(o, key, i)
	}
}

// Points `o`'s index at slot `i` for `k`, noting a key that already had one.
@(private = "file")
index_slot :: #force_inline proc(o: ^Object, k: string, i: int) {
	n := len(o.index)
	o.index[k] = i
	o.repeats ||= len(o.index) == n
}

// Room in `a` for one more, doubling from 2 where append reserves 8, since built arrays and objects are mostly small
// and live until their arena is freed.
make_room :: #force_inline proc(a: ^[dynamic]$T) {
	if n := len(a); n == cap(a) {
		reserve(a, max(2, 2 * n))
	}
}

// The key of a dead slot, told from every other key by where its bytes are.
@(private = "file")
dead_byte: u8

@(private = "file")
is_dead :: #force_inline proc(k: string) -> bool {
	return raw_data(k) == &dead_byte
}

// Removes `k`'s last member from `o`. An indexed object with no repeated key leaves the slot dead, its key out of the
// index, so the other slots keep their place and a delete costs a hash lookup. The dead slots are compacted once they
// are half the slots, or at the next read through `object_keys`.
object_delete :: proc(o: ^Object, k: string) {
	i := object_slot(o, k)
	if i < 0 {
		return
	}
	if len(o.index) == 0 || o.repeats {
		if o.dead > 0 {
			compact(o)
			i = object_slot(o, k)
		}
		ordered_remove(&o.slot_keys, i)
		ordered_remove(&o.slot_vals, i)
		if len(o.index) > 0 {
			reindex(o)
		}
		return
	}
	delete_key(&o.index, k)
	o.slot_keys[i] = string(([^]u8)(&dead_byte)[:0])
	o.slot_vals[i] = nil
	o.dead += 1
	if int(o.dead) * 2 >= len(o.slot_keys) {
		compact(o)
	}
}

// `o` with its dead slots dropped and its index made again.
@(private = "file")
compact :: proc(o: ^Object) {
	kept := 0
	for k, i in o.slot_keys {
		if !is_dead(k) {
			o.slot_keys[kept], o.slot_vals[kept] = k, o.slot_vals[i]
			kept += 1
		}
	}
	resize(&o.slot_keys, kept)
	resize(&o.slot_vals, kept)
	o.dead = 0
	reindex(o)
}

// `o` without the keys in `gone`, in one pass however many there are.
object_delete_all :: proc(o: ^Object, gone: map[string]bool) {
	keys, vals := object_keys(o), object_vals(o)
	kept := 0
	for k, i in keys {
		if !gone[k] {
			keys[kept], vals[kept] = k, vals[i]
			kept += 1
		}
	}
	if kept == len(keys) {
		return
	}
	resize(&o.slot_keys, kept)
	resize(&o.slot_vals, kept)
	if len(o.index) > 0 {
		reindex(o)
	}
}

// The value of node `r` as a built value of its own, which outlives the document. A number is a double, or a
// `Number_View` of its digits where the double does not spell them, and a byte string is its RFC 4648 base64. An object
// follows `dups`: `.All` keeps a repeated key in order, `.First` the first, `.Last` the last, and `.Default` is the
// format's own, a markup document's repeated name being an array as `markup_members` reads it. With `borrow` a string
// or key in the document's text stays a slice of it. Comments the node has in its document come with it as
// `Commented`. The containers being filled are frames of a stack in the context allocator, so the native stack does
// not grow with the node's depth.
built_value :: proc(r: Node_Ref, dups := Duplicates.Default, borrow := false) -> Value {
	// A container being filled, from `it`. `key` is the key of the member whose value is being built.
	Filling :: struct {
		r:   Node_Ref,
		v:   Value,
		it:  Value_Iter,
		key: string,
	}
	v := built_data(r, borrow)
	#partial switch _ in v {
	case ^Array, ^Object:
	case:
		return built_comments(r, v, borrow)
	}
	// `.Default` stands for a markup document's arrays from here, and the pairs are the nodes', each key each time.
	dups := dups
	if dups == .Default && !is_markup(r.doc) {
		dups = .Last
	}
	stack := make([dynamic]Filling, 0, 16)
	defer delete(stack)
	append(&stack, Filling{r = r, v = v, it = children(r) if doc_kind(r.doc, r.node) == .Array else node_pairs(r)})
	for {
		top := len(stack) - 1
		f := &stack[top]
		m: Value
		more: bool
		if _, is_array := f.v.(^Array); is_array {
			m, more = child_next(&f.it)
		} else {
			k: string
			k, m, more = pair_next(&f.it)
			if more {
				f.key = text_kept(r.doc, k, borrow)
			}
		}
		if more {
			child := m.(Node_Ref)
			cv := built_data(child, borrow)
			#partial switch _ in cv {
			case ^Array:
				append(&stack, Filling{r = child, v = cv, it = children(child)})
				continue
			case ^Object:
				append(&stack, Filling{r = child, v = cv, it = node_pairs(child)})
				continue
			}
			built_put(f, built_comments(child, cv, borrow), dups)
			continue
		}
		done := pop(&stack)
		filled := built_comments(done.r, done.v, borrow)
		if top == 0 {
			return filled
		}
		built_put(&stack[top - 1], filled, dups)
	}
}

// A copy of `v` in the context allocator, with its texts, which outlives the document a node of it is in. A node of
// `keep` stays a reference, another node is built by `dups`, a trail is its array and a comment is dropped.
kept_value :: proc(v: Value, keep: ^Document = nil, dups := Duplicates.Default) -> Value {
	switch x in plain(v) {
	case nil, bool, f64:
		return x
	case string:
		return strings.clone(x)
	case Number_View:
		return view_copy(x)
	case ^Array:
		a := new_array(len(x.items))
		for item in x.items {
			array_append(a, kept_value(item, keep, dups))
		}
		return a
	case ^Object:
		o := new_object()
		keys, vals := object_keys(x), object_vals(x)
		for k, i in keys {
			object_append(o, strings.clone(k), kept_value(vals[i], keep, dups))
		}
		return o
	case Node_Ref:
		return x if x.doc == keep else built_value(x, dups)
	case Trail:
		return kept_value(trail_array(x), keep, dups)
	case ^Commented:
		return kept_value(x.v, keep, dups)
	}
	return nil
}

// `v` made the next item of the array `f` fills, or the value of its object's member `f.key` under `dups`, which is
// `.Default` only for a markup document.
@(private = "file")
built_put :: proc(f: ^$F, v: Value, dups: Duplicates) {
	if a, is_array := f.v.(^Array); is_array {
		append(&a.items, v)
		return
	}
	o := f.v.(^Object)
	#partial switch dups {
	case .All:
		object_append(o, f.key, v)
	case .First:
		if object_slot(o, f.key) < 0 {
			object_append(o, f.key, v)
		}
	case .Default:
		markup_put(o, f.key, v)
	case:
		object_put(o, f.key, v)
	}
}

// A `Value_Iter` over the members of object node `r` as its document holds them, a repeated key's each time.
@(private = "file")
node_pairs :: proc(r: Node_Ref) -> Value_Iter {
	return {v = r, pairs = doc_pairs(r.doc, r.node)}
}

// `v`, the value of node `r`, with the comments `r` has in its document.
@(private = "file")
built_comments :: proc(r: Node_Ref, v: Value, borrow: bool) -> Value {
	if len(r.doc.facts) == 0 {
		return v
	}
	noted_v := v
	for role in COMMENT_ROLES {
		bodies, from := comments(r, role)
		if from == .None {
			continue
		}
		kept := make([]string, len(bodies))
		for body, i in bodies {
			kept[i] = text_kept(r.doc, body, borrow)
		}
		delete(bodies)
		noted_v = noted(noted_v, role, kept)
	}
	return noted_v
}

// The value of a scalar node, or a new empty array or object for a container, which `built_value` fills.
@(private = "file")
built_data :: proc(r: Node_Ref, borrow: bool) -> Value {
	#partial switch doc_kind(r.doc, r.node) {
	case .False:
		return false
	case .True:
		return true
	case .Number:
		n, _ := doc_number(r.doc, r.node)
		if n.kind == .Int && (i64(n.bits) > MAX_EXACT_INT || i64(n.bits) < -MAX_EXACT_INT) ||
		   n.kind == .Uint && n.bits > MAX_EXACT_INT {
			digits: [spell.INT_ROOM]u8
			size := spell.i64_text(&digits[0], i64(n.bits)) if n.kind == .Int else spell.u64_text(&digits[0], n.bits)
			return number_text(string(digits[:size]))
		}
		// The digits of a number whose span is not a JSON number are read into `spelled`.
		spelled: [HEX_ROOM]u8
		f, digits, _ := double_of(r, spelled[:])
		if digits != "" && (n.kind == .Float || n.kind == .Wide) && !spells_digits(f, digits) {
			return number_text(digits)
		}
		return f
	case .Bytes:
		payload := transmute([]u8)node_string(r.doc, r.node)
		text := make([]u8, spell.base64_room(len(payload)))
		return string(text[:spell.base64_text(text, payload)])
	case .String:
		return text_kept(r.doc, node_string(r.doc, r.node), borrow)
	case .Array:
		return new_array(length(r))
	case .Object:
		return new_object()
	}
	return nil
}

// `s` as a string of a built value: itself when it lies in the text of `doc` and `borrow` says so, else a copy.
@(private = "file")
text_kept :: proc(doc: ^Document, s: string, borrow: bool) -> string {
	if borrow && lies_in_source(doc, s) {
		return s
	}
	return strings.clone(s)
}

// Whether the double `f` is the number spelled `digits`: its shortest decimal is that number. A number of at most 15
// characters and no exponent always is.
@(private = "file")
spells_digits :: proc(f: f64, digits: string) -> bool {
	if len(digits) <= 15 && strings.index_any(digits, "eE") < 0 {
		return true
	}
	if math.is_inf(f) || math.is_nan(f) {
		return false
	}
	buf: [spell.F64_ROOM]u8
	order := spell.decimal_compare(spell.decimal_of(digits), spell.decimal_of(string(buf[:spell.f64_text(&buf[0], f)])))
	return order == 0
}
