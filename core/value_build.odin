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

// `k` added to `o` as a member of its own, set to `v`, whether `o` has the name or not.
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

// The value of node `r` as a built value of its own, which outlives the document: a number is a double, but a number
// whose digits the double does not spell keeps them as a `Number_Text`. An object follows `dups`: `.All` keeps a
// repeated key in order, `.First` the first and the others the last. With `borrow` a string or key that lies in the
// document's text stays a slice of it. A node that has comments in its document carries them, as `Commented` does.
built_value :: proc(r: Node_Ref, dups := Duplicates.Last, borrow := false) -> Value {
	v := built_data(r, dups, borrow)
	if len(r.doc.facts) == 0 {
		return v
	}
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
		v = noted(v, role, kept)
	}
	return v
}

@(private = "file")
built_data :: proc(r: Node_Ref, dups: Duplicates, borrow: bool) -> Value {
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
		f, digits, _ := double_of(r)
		if digits != "" && (n.kind == .Float || n.kind == .Wide) && !spells_digits(f, digits) {
			return number_text(strings.clone(digits))
		}
		return f
	case .String:
		return text_kept(r.doc, node_string(r.doc, r.node), borrow)
	case .Array:
		a := new_array(length(r))
		it := children(r)
		for m in child_next(&it) {
			append(&a.items, built_value(m.(Node_Ref), dups, borrow))
		}
		return a
	case .Object:
		o := new_object()
		it := pairs(r)
		for k, m in pair_next(&it) {
			key, v := text_kept(r.doc, k, borrow), built_value(m.(Node_Ref), dups, borrow)
			switch {
			case dups == .All:
				object_append(o, key, v)
			case dups == .First && object_slot(o, key) >= 0:
			case:
				object_put(o, key, v)
			}
		}
		return o
	}
	return nil
}

// `s` as a string of a built value: itself when it lies in the text of `doc` and `borrow` says so, else a copy.
@(private = "file")
text_kept :: proc(doc: ^Document, s: string, borrow: bool) -> string {
	lo, at := uintptr(raw_data(doc.src)), uintptr(raw_data(s))
	if borrow && at >= lo && at + uintptr(len(s)) <= lo + uintptr(len(doc.src)) {
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

// The largest integer every smaller one of which a double holds exactly.
@(private = "file")
MAX_EXACT_DOUBLE_INT :: 1 << 53
