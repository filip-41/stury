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
// whose digits the double does not spell keeps them as a `Number_Text`, and a byte string is the string of its RFC 4648
// base64, as a text format writes it. An object follows `dups`: `.All` keeps a
// repeated key in order, `.First` the first and the others the last. With `borrow` a string or key that lies in the
// document's text stays a slice of it. A node that has comments in its document carries them, as `Commented` does. The
// containers being filled are frames of a stack in the context allocator, so the native stack does not grow with the
// node's depth.
built_value :: proc(r: Node_Ref, dups := Duplicates.Last, borrow := false) -> Value {
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
	stack := make([dynamic]Filling, 0, 16)
	defer delete(stack)
	append(&stack, Filling{r = r, v = v, it = children(r) if doc_kind(r.doc, r.node) == .Array else pairs(r)})
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
				append(&stack, Filling{r = child, v = cv, it = pairs(child)})
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

// `v` made the next item of the array `f` fills, or the value of its object's member `f.key` under `dups`.
@(private = "file")
built_put :: proc(f: ^$F, v: Value, dups: Duplicates) {
	if a, is_array := f.v.(^Array); is_array {
		append(&a.items, v)
		return
	}
	o := f.v.(^Object)
	switch {
	case dups == .All:
		object_append(o, f.key, v)
	case dups == .First && object_slot(o, f.key) >= 0:
	case:
		object_put(o, f.key, v)
	}
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
		if n.kind == .Int && (i64(n.bits) > MAX_EXACT_DOUBLE_INT || i64(n.bits) < -MAX_EXACT_DOUBLE_INT) ||
		   n.kind == .Uint && n.bits > MAX_EXACT_DOUBLE_INT {
			digits: [spell.INT_ROOM]u8
			size := spell.i64_text(&digits[0], i64(n.bits)) if n.kind == .Int else spell.u64_text(&digits[0], n.bits)
			return number_text(strings.clone(string(digits[:size])))
		}
		// The digits a format spells for a number whose span is not its text are read into `spelled`.
		spelled: [HEX_ROOM]u8
		f, digits, _ := double_of(r, spelled[:] if r.doc.readers.number_text != nil else nil)
		if digits != "" && (n.kind == .Float || n.kind == .Wide) && !spells_digits(f, digits) {
			return number_text(strings.clone(digits))
		}
		return f
	case .Bytes:
		payload := transmute([]u8)node_string(r.doc, r.node)
		text := make([]u8, spell.base64_len(len(payload)))
		return string(text[:spell.base64_put(text, payload)])
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
