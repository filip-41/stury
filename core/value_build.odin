package core

// The builders of a built value and an object's key index, which they keep current. A builder allocates from the
// context allocator.

import "base:intrinsics"
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

// The slot of the last member of `o` named `k`, or -1.
object_slot :: proc(o: ^Object, k: string) -> int {
	if len(o.index) > 0 {
		i, has := o.index[k]
		return i if has else -1
	}
	#reverse for key, i in o.keys {
		if key == k {
			return i
		}
	}
	return -1
}

// Set `k` in an object being built, in place: a key it has keeps its slot and takes the new value.
object_put :: proc(o: ^Object, k: string, v: Value) {
	if i := object_slot(o, k); i >= 0 {
		o.vals[i] = v
		return
	}
	object_append(o, k, v)
}

// Set `k` in an object being changed, in place: a member replaced keeps the comments `v` does not bring.
object_set :: proc(o: ^Object, k: string, v: Value) {
	if i := object_slot(o, k); i >= 0 {
		o.vals[i] = keep_comments(o.vals[i], v)
		return
	}
	object_append(o, k, v)
}

// `k`, which `o` does not have, set to `v`.
@(private = "file")
object_append :: #force_inline proc(o: ^Object, k: string, v: Value) {
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

// `o`'s key index made again from its keys, a repeated key's at its last slot.
reindex :: proc(o: ^Object) {
	clear(&o.index)
	for key, i in o.keys {
		o.index[key] = i
	}
}

// Room in `a` for one more, the room doubled from 2: append's first reserve is 8, mostly unused by the small arrays
// and objects built by the million, and none of it is freed before the arena is.
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

// The value of node `r` as a built value of its own, which outlives the document: a number is a double, but an integer
// no double holds exactly, which keeps its digits as a `Number_Text`. An object with a repeated key keeps the last.
built_value :: proc(r: Node_Ref) -> Value {
	#partial switch doc_kind(r.doc, r.node) {
	case .False:
		return false
	case .True:
		return true
	case .Number:
		n, _ := doc_number(r.doc, r.node)
		if n.kind == .Int && (i64(n.bits) > MAX_EXACT_DOUBLE_INT || i64(n.bits) < -MAX_EXACT_DOUBLE_INT) ||
		   n.kind == .Uint && n.bits > MAX_EXACT_DOUBLE_INT {
			digits: [spell.INT_ROOM]u8
			size := spell.i64_text(&digits[0], i64(n.bits)) if n.kind == .Int else spell.u64_text(&digits[0], n.bits)
			return number_text(strings.clone(string(digits[:size])))
		}
		f, _, _ := double_of(r)
		return f
	case .String:
		return strings.clone(node_string(r.doc, r.node))
	case .Array:
		a := new_array(length(r))
		it := children(r)
		for m in child_next(&it) {
			append(&a.items, built_value(m.(Node_Ref)))
		}
		return a
	case .Object:
		o := new_object()
		it := pairs(r)
		for k, m in pair_next(&it) {
			object_put(o, strings.clone(k), built_value(m.(Node_Ref)))
		}
		return o
	}
	return nil
}

// The largest integer every smaller one of which a double holds exactly.
@(private = "file")
MAX_EXACT_DOUBLE_INT :: 1 << 53
