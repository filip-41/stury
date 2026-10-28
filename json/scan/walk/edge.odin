package walk

// The edge cursor over caller-owned row arrays.

import "base:runtime"
import "../../../core/spell"

// Cursor over a caller-owned `[dynamic]`: its `{data, len, cap}` taken without copying. `edge_push` stores
// without touching the array's header. `edge_publish` writes the length back. A nil `arr` has no storage, so
// the row is dropped.
Edge :: struct($T: typeid) {
	base: [^]T,
	len:  int,
	cap:  int,
	// The array this cursor writes into, so growth has something to grow.
	arr:  ^[dynamic]T,
	// The run this cursor belongs to, so a refused growth can record itself call-scoped.
	q: ^Query_Ctx,
}

// The cursor over `arr`'s existing storage. Nothing is allocated here, and nothing is written back
// until `edge_publish`.
edge_begin :: #force_inline proc(q: ^Query_Ctx, arr: ^[dynamic]$T) -> (e: Edge(T), ok: bool) {
	if cap(arr^) > 0 && raw_data(arr^) == nil {
		return e, false // capacity that cannot be reached
	}
	e.arr = arr
	e.base = cast([^]T)raw_data(arr^)
	e.len = 0
	e.cap = cap(arr^)
	e.q = q
	return e, true
}

// Store `row` at the cursor, growing the array first when it is full. A refused growth loses the row and
// records the shortfall under `kind` (`note_oom`).
edge_push :: #force_inline proc(e: ^Edge($T), row: T, kind: Walk_Kind) {
	if e.len >= e.cap {
		if e.arr == nil {
			return
		}
		// Growth moves the storage by value (see `edge_grow`), so nothing non-inlined holds the cursor's
		// address.
		base, room, grew := edge_grow(e.arr, e.cap)
		if !grew {
			// Growth refused: the row is lost, so record it on the run's own context and the run reports the
			// shortfall.
			note_oom(e.q, kind)
			return
		}
		e.base = base
		e.cap = room
	}
	i := e.len
	// Commit the cursor before the row store: that store goes through a pointer of unknown provenance and
	// Odin emits no TBAA, so a later read of `e.len` would be a reload.
	e.len = i + 1
	e.base[i] = row
}

// Grow capacity only, without zeroing: `edge_push` writes every slot before `edge_publish` exposes it.
// (`reserve` zeroes the tail, `resize` zeroes the rows the cursor already wrote.)
edge_reserve :: proc(arr: ^[dynamic]$T, n: int) -> bool {
	if n <= cap(arr^) {
		return true
	}
	return non_zero_reserve(arr, n) == .None
}

// Bytes of input per seeded row. A document of 8 or more bytes per row fits the seed, and a denser one is one ×4
// growth past it, since `(len/8)*4 = len/2`.
ROW_CAP_K :: 8

// Ceiling on the seed, in rows: `len/8` of a 16 MiB input. Past that the ask is clipped so a sparse document
// does not reserve tens of millions of rows. An arena keeps what it hands out, so this clip holds for any
// allocator but the heap.
ROW_CAP_MAX :: 1 << 21

// The heap's ceiling: `len/8` of a 128 MiB input. `non_zero_reserve` leaves the tail untouched, so a sparse
// document pays address space, not pages, and a large record array takes no x4 grow and copy.
ROW_CAP_HEAP_MAX :: 1 << 24

// The ladder's first rung: a smaller seed would make the next growth start from a smaller rung.
ROW_CAP_FLOOR :: 256

// Reserve `len(src)/ROW_CAP_K` rows on a cold nodes sink, once, before the cursor is taken. A reused or
// caller-sized sink is left alone (`edge_reserve` never shrinks), and a refused reserve is not a shortfall:
// the walk continues on `edge_grow`'s ladder. Not inside `edge_grow`: that sees the capacity, not `len(src)`,
// and threading it through `Edge` would load it on every push.
seed_row_cap :: proc(arr: ^[dynamic]$T, src_len: int) {
	if arr == nil || src_len <= 0 {
		return
	}
	n := src_len / ROW_CAP_K
	// A sink already holding a row per `SEEDED_ROW_BYTES` is sized, whatever the caller sized it by.
	if cap(arr^) >= src_len / SEEDED_ROW_BYTES {
		return
	}
	limit := ROW_CAP_HEAP_MAX if arr.allocator.procedure == runtime.heap_allocator_proc else ROW_CAP_MAX
	if n > limit {
		n = limit
	}
	if n <= ROW_CAP_FLOOR {
		return
	}
	_ = edge_reserve(arr, n)
}

// Bytes of input per row at which a sink the caller already sized is not seeded further: the seed's
// `ROW_CAP_K` is a third as many bytes per row, and rows past the document's own are zeroed again by an
// arena's reset, so they stay resident. A denser document grows once from the caller's size, x4.
SEEDED_ROW_BYTES :: 24

// Make room for one more row and hand back the storage to push into. By-value in and out so `Edge` (a
// `Query_Ctx` field) is never address-captured by a non-inlined call, which would force `base`/`len`/`cap`
// reloads on every push.
edge_grow :: proc(arr: ^[dynamic]$T, cur_cap: int) -> (base: [^]T, room: int, ok: bool) {
	// ×4 growth from a ROW_CAP_FLOOR seed. Refuse instead of wrapping: a negative `want` would make
	// `edge_reserve` answer true without allocating, leaving a nil `base` that `edge_push` would write
	// through.
	want: int
	switch {
	case cur_cap == 0:
		want = ROW_CAP_FLOOR
	case cur_cap > max(int) / 4:
		return nil, cur_cap, false
	case:
		want = cur_cap * 4
	}
	if !edge_reserve(arr, want) {
		return nil, cur_cap, false
	}
	return cast([^]T)raw_data(arr^), cap(arr^), true
}

// Say that `n` rows are in the array: the caller's rows first, this kind's rows after. Legal because
// `edge_reserve` secured the capacity first, so `n <= cap`.
edge_publish :: spell.put_publish

// Append `row` to a caller's array: one store while it has room, and the builtin `append`, which may grow it,
// once it is full. False when it could not grow.
row_append :: #force_inline proc(arr: ^[dynamic]$T, row: T) -> (ok: bool) {
	n := len(arr^)
	if n < cap(arr^) {
		edge_publish(arr, n + 1)
		#no_bounds_check arr[n] = row
		return true
	}
	_, err := append(arr, row)
	return err == nil
}
