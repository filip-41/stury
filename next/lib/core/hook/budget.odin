package hook

import "base:runtime"
import "stury:lib/core/tape"

// The blocks a read holds against `Budget.memory`, taken from `backing` through `memory_budget`, which refuses a
// block past `limit`. A block freed with no size is counted as still held.
Memory_Budget :: struct {
	backing: runtime.Allocator,
	limit:   u64,
	held:    u64,
	refused: bool, // the last block refused was refused for the budget, not by `backing`
	peer:    ^Memory_Budget, // a budget whose blocks count against the same `limit`, as one count over two backings
}

// An allocator over `m.backing` that holds the bytes of its blocks within `m.limit`.
memory_budget :: proc "contextless" (m: ^Memory_Budget) -> runtime.Allocator {
	return {memory_budget_proc, m}
}

// The bytes `m` still lets its blocks grow by, counting a peer's.
memory_budget_left :: proc "contextless" (m: ^Memory_Budget) -> u64 {
	held := m.held
	if m.peer != nil {
		held += m.peer.held
	}
	return m.limit - min(held, m.limit)
}

// The error a read that ended with `err` gives under `m`: `Exceeded` for a refusal the budget made.
memory_budget_error :: proc "contextless" (m: ^Memory_Budget, err: tape.Error) -> tape.Error {
	if _, refused := err.(runtime.Allocator_Error); refused && (m.refused || m.peer != nil && m.peer.refused) {
		return tape.Exceeded{at = tape.NO_BYTE, kind = .Memory}
	}
	return err
}

@(private)
memory_budget_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	m := (^Memory_Budget)(data)
	if m.backing.procedure == nil {
		return nil, nil
	}
	grows := 0
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		grows = size
	case .Resize, .Resize_Non_Zeroed:
		grows = size - old_size
	}
	held := m.held
	if m.peer != nil {
		held += m.peer.held
	}
	if grows > 0 && u64(grows) > m.limit - min(held, m.limit) {
		m.refused = true
		return nil, .Out_Of_Memory
	}
	block, err := m.backing.procedure(m.backing.data, mode, size, alignment, old_memory, old_size, loc)
	if err != nil {
		m.refused = false
		return block, err
	}
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		m.held += u64(size)
	case .Resize, .Resize_Non_Zeroed:
		m.held = m.held - min(m.held, u64(old_size)) + u64(size)
	case .Free:
		m.held -= min(m.held, u64(old_size))
	case .Free_All:
		m.held = 0
	}
	return block, err
}
