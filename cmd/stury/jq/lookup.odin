package jq

// Finding without a scan: the scalar index of an array's elements.

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
