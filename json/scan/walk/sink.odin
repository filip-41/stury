package walk

import "base:runtime"

// The collections the walk appends into: a `Request`'s outputs, lent for one scan. A kind not
// queried leaves its field untouched. `.Path` answers are tagged with their query's index, so a
// shared array is every query's answers in walk order.
Scan_Query_Sink :: struct {
	paths:           [dynamic]Path_Answer,
	// How many times a `.Last` repeat retracted rows of `paths` to `RETRACTED_TAG` (`path_supersede`), rows
	// the json layer must drop. An `int`, as a `bool` would pad the struct and a padded `---` local is zeroed.
	paths_retracted: int,
	// How many times a walk met an object a wildcard run under `.First` or `.Last` must resolve key by key
	// (`wild_key`, `demand_wild_open`): one with a repeated key, which the json layer answers on the tape. An
	// `int` for the reason above.
	paths_unresolved: int,
	nodes:           [dynamic]Row,
	// The bytes of every decoded string value whose source text carried an escape, back to back. Rows
	// address them by offset (`Row_Str`), so the store may move as it grows. An escape-free string is
	// not copied: its text is a slice of the caller's `src`.
	value_bytes:     [dynamic]u8,
}

// Append `n` uninitialized bytes to `values` and return where they start. `bound` is the most bytes this
// scan can still append (`n` included): a string decodes to at most its source text, so the source bytes from
// this string on bound every later one. On the heap a grow asks for that at once, since a ladder of grows
// copies the array at every rung while untouched pages of the ask cost
// nothing. `value_bytes_trim` returns the unused tail. Any other allocator, and a heap that refuses the
// ask, gets the doubling ladder, whose first grow is an arena block's size: an arena keeps whatever it
// hands out. Non-zeroing: the runtime's zeroing reserve probes every new page, and every byte below `len`
// is written by the decoder.
// `ok == false` reports a refused grow, with `values` unchanged.
@(private)
value_bytes_reserve :: proc(values: ^[dynamic]u8, n: int, bound: int) -> (at: int, ok: bool) {
	at = len(values)
	if at + n > cap(values) {
		ladder := max(2 * cap(values), at + n, NAME_BLOCK_BYTES)
		one_shot := values.allocator.procedure == runtime.heap_allocator_proc && at + bound > ladder
		grown := one_shot && non_zero_reserve(values, at + bound) == nil
		if !grown && non_zero_reserve(values, ladder) != nil {
			return at, false
		}
	}
	edge_publish(values, at + n)
	return at, true
}

// Whether `values` has room for `bound` more bytes past its length, asking the heap for them at once when it
// has not (the one-shot ask of `value_bytes_reserve`, length unchanged). Any other allocator answers only what
// it already holds, so a decode written ahead of its reserve never makes an arena keep a source's worth.
value_bytes_room :: #force_no_inline proc(values: ^[dynamic]u8, bound: int) -> bool {
	at := len(values)
	if cap(values) - at >= bound {
		return true
	}
	if values.allocator.procedure != runtime.heap_allocator_proc {
		return false
	}
	if _, ok := value_bytes_reserve(values, bound, bound); !ok {
		return false
	}
	edge_publish(values, at)
	return cap(values) - at >= bound
}

// Give back the capacity a scan's one-shot ask left unused, so a document keeps about what it decoded.
// `kept` is the capacity the scan started with: a reused output keeps that much for the next scan. Heap
// only, where shrinking in place costs no copy, and a refused shrink keeps the array as it was.
value_bytes_trim :: proc(values: ^[dynamic]u8, kept: int) {
	want := max(len(values), kept, NAME_BLOCK_BYTES)
	if values.allocator.procedure == runtime.heap_allocator_proc && cap(values) > 2 * want {
		_, _ = shrink(values, want)
	}
}
