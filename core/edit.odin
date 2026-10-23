package core

// What every codec's text edits share: the byte-span edit, its ordering rule, its application, and the
// allocator that tells a refused allocation from an edit that found nothing.

import "base:runtime"
import "core:mem"

// One edit: `src[lo:hi]` becomes `bytes`.
Edit :: struct {
	lo, hi: u64,
	bytes:  []u8,
}

// An `insert` position after the last entry, whatever the count.
APPEND :: max(int)

// Whether `edits` are sorted by `lo`, disjoint, and inside `src`.
edits_ordered :: proc(src: []byte, edits: []Edit) -> bool {
	at: u64
	for e in edits {
		if e.lo < at || e.hi < e.lo || e.hi > u64(len(src)) {
			return false
		}
		at = e.hi
	}
	return true
}

// `src` with sorted, disjoint edits applied: one copy per gap and one per replacement into an exact,
// uninitialized allocation. A refused allocation is `oom`.
edits_apply :: proc(src: []byte, edits: []Edit, allocator: runtime.Allocator, oom: $E) -> (out: []byte, err: Maybe(E)) {
	n := len(src)
	for e in edits {
		n += len(e.bytes) - int(e.hi - e.lo)
	}
	buf, aerr := mem.alloc_bytes_non_zeroed(n, allocator = allocator)
	if aerr != nil {
		return nil, oom
	}
	w := 0
	at: u64
	for e in edits {
		w += copy(buf[w:], src[at:e.lo])
		w += copy(buf[w:], e.bytes)
		at = e.hi
	}
	copy(buf[w:], src[at:])
	return buf, nil
}

// The allocator of a path edit: `backing`, remembering a refusal, so that an edit whose scratch lost an
// entry to one answers out of memory (`unless_refused`) rather than a result missing an edit.
Refusal_Watch :: struct {
	backing: runtime.Allocator,
	refused: bool,
}

watched :: proc(w: ^Refusal_Watch) -> runtime.Allocator {
	return {watch_proc, w}
}

@(private = "file")
watch_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	w := (^Refusal_Watch)(data)
	out, err := w.backing.procedure(w.backing.data, mode, size, alignment, old_memory, old_size, loc)
	if err == .Out_Of_Memory {
		w.refused = true
	}
	return out, err
}

// The edit's answer, or `oom` with `out` freed when the watch saw a refusal.
unless_refused :: proc(w: ^Refusal_Watch, out: []byte, err: Maybe($E), oom: E) -> ([]byte, Maybe(E)) {
	if w.refused {
		delete(out, w.backing)
		return nil, oom
	}
	return out, err
}
