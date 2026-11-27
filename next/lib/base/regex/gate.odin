#+private
package regex

import "core:mem"

// The bytes of a compile's or sample's stack that serve its allocations once the caller's allocator has failed.
SPARE_BYTES :: 8192

// The allocator every allocation of a compile or a search goes through. Code that allocates keeps going when an
// allocation fails, so a failure is latched here and served from `spare`, where the caller's allocator is no longer
// asked, and the phases of compile and search read `failed` between their steps and return an out-of-memory error. A
// request that `spare` cannot hold fails, which only the phases that check for it may meet. Wrap `Dynamic_Arena` inside
// `Gate` (never `Gate` inside `Dynamic_Arena`) so `gate_failed` sees it and `spare` serves individual allocations.
Gate :: struct {
	inner:  mem.Allocator,
	spare:  []byte, // a stack buffer of the compile, none for a search
	used:   int,
	failed: bool,
}

gate_allocator :: proc(g: ^Gate) -> mem.Allocator {
	return {procedure = gate_proc, data = g}
}

// Whether an allocation through the gate `a` has failed.
gate_failed :: #force_inline proc(a: mem.Allocator) -> bool {
	return a.procedure == gate_proc && (^Gate)(a.data).failed
}

@(private = "file")
gate_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size,
	alignment: int,
	old_ptr: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	g := (^Gate)(data)
	#partial switch mode {
	case .Free, .Free_All, .Query_Features, .Query_Info:
		base := uintptr(raw_data(g.spare))
		if old_ptr != nil && uintptr(old_ptr) >= base && uintptr(old_ptr) < base + uintptr(len(g.spare)) {
			return nil, nil
		}
		return g.inner.procedure(g.inner.data, mode, size, alignment, old_ptr, old_size, loc)
	}
	if !g.failed {
		result, err := g.inner.procedure(g.inner.data, mode, size, alignment, old_ptr, old_size, loc)
		if err == nil && (size == 0 || result != nil) {
			return result, nil
		}
		g.failed = true
	}
	return take_spare(g, size, alignment, old_ptr, old_size)
}

@(private = "file")
take_spare :: proc(g: ^Gate, size, alignment: int, old_ptr: rawptr, old_size: int) -> ([]byte, mem.Allocator_Error) {
	base := uintptr(raw_data(g.spare))
	at := int(mem.align_forward_uintptr(base + uintptr(g.used), uintptr(max(alignment, 1))) - base)
	if size < 0 || at < 0 || at > len(g.spare) || size > len(g.spare) - at {
		return nil, .Out_Of_Memory
	}
	g.used = at + size
	block := g.spare[at:][:size]
	mem.zero_slice(block)
	if old_ptr != nil && old_size > 0 && size > 0 {
		mem.copy(raw_data(block), old_ptr, min(old_size, size))
	}
	return block, nil
}
