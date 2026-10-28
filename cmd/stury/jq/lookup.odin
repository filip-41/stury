package jq

// Finding without a scan: an object's key index and the edits that keep it current, and the scalar index of an
// array's elements.

INDEX_FROM :: 16

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
@(private)
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
		switch k {
		case .Number:
			n, _ := number_of(x)
			prev, seen := ix.numbers[n.f + 0] // + 0: -0 and 0 are one key
			ix.numbers[n.f + 0] = len(ix.nums)
			append(&ix.chain, prev if seen else -1)
			append(&ix.nums, x)
		case .String:
			s, _ := string_of(x)
			ix.texts[s] = true
		case .Null, .False, .True, .Array, .Object:
		}
	}
	return
}

// Whether an element of the indexed array equals the scalar `v` (a string only exactly), and whether `v` is a
// scalar, which no other element can be found equal to.
index_has :: proc(ix: ^Scalar_Index, v: Value) -> (found, scalar: bool) {
	k := kind(v)
	switch k {
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
	case .Array, .Object:
	}
	return false, false
}
