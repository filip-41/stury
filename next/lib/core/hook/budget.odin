package hook

import "base:runtime"
import "stury:lib/core/tape"

// The blocks a read holds against `Budget.memory`, taken from `backing` through `memory_budget`, which refuses a
// block past `limit`. A block freed with no size is counted as still held.
Memory_Budget :: struct {
	backing: runtime.Allocator,
	limit:   u64,
	held:    u64,
	refused: bool, // the last block refused was refused for the budget, not by `backing`; kept across `.Free` so unwinding preserves it
	peer:    ^Memory_Budget, // a budget whose blocks count against the same `limit`, as one count over two backings
}

// An allocator over `m.backing` that holds the bytes of its blocks within `m.limit`.
memory_budget :: proc "contextless" (m: ^Memory_Budget) -> runtime.Allocator {
	return {memory_budget_proc, m}
}

// The pair of budgets a read with `Budget.memory` owns on its stack: `main` for blocks the read keeps or gives back,
// and `scratch` for short-lived blocks freed before it returns, sharing one limit. Neither writes into any caller's
// `Memory_Budget`.
Read_Budget :: struct {
	main:    Memory_Budget,
	scratch: Memory_Budget,
}

// Starts `b` for a read under `opts` backed by `caller`, returning the allocator for the read's own blocks. When
// `opts.budget.memory` is 0, returns `caller` untouched. Otherwise the read's blocks and its scratch share the limit.
read_budget :: #force_inline proc "contextless" (b: ^Read_Budget, opts: tape.Options, caller: runtime.Allocator) -> runtime.Allocator {
	if opts.budget.memory == 0 {
		return caller
	}
	if backing, ok := scratch_backing(opts); ok {
		b.main = {backing = caller, limit = opts.budget.memory, peer = &b.scratch}
		b.scratch = {backing = backing, limit = opts.budget.memory, peer = &b.main}
	} else {
		b.main = {backing = caller, limit = opts.budget.memory}
	}
	return memory_budget(&b.main)
}

// The allocator for memory a read holds only while it runs and frees before returning, see `scratch_backing`, else
// `allocator`. Under `opts.budget.memory`, scratch blocks share the read's limit: when `allocator` is a `Read_Budget`
// whose peer backs the scratch, returns that peer; otherwise counts against `opts.budget.memory` in `local`, reading
// `allocator`'s budget if any without writing `peer` or `refused` into any caller's `Memory_Budget`.
scratch :: proc "contextless" (opts: tape.Options, allocator: runtime.Allocator, local: ^Memory_Budget) -> runtime.Allocator {
	backing, ok := scratch_backing(opts)
	if !ok {
		return allocator
	}
	if opts.budget.memory == 0 {
		return backing
	}
	m := (^Memory_Budget)(allocator.data) if allocator.procedure == memory_budget_proc else nil
	if m != nil && m.peer != nil && m.peer.backing == backing && m.peer.limit <= opts.budget.memory {
		return memory_budget(m.peer)
	}
	local^ = {backing = backing, limit = opts.budget.memory, peer = m}
	return memory_budget(local)
}

// Where a read's scratch comes from: `opts.scratch` when set, else the runtime's default heap. False on a build whose
// default allocator is the nil or panic one (a freestanding target), where scratch stays in the read's allocator.
@(private = "file")
scratch_backing :: #force_inline proc "contextless" (opts: tape.Options) -> (runtime.Allocator, bool) {
	if opts.scratch.procedure != nil {
		return opts.scratch, true
	}
	when ODIN_DEFAULT_TO_NIL_ALLOCATOR || ODIN_DEFAULT_TO_PANIC_ALLOCATOR {
		return {}, false
	} else {
		return {runtime.default_allocator_proc, nil}, true
	}
}

// The bytes `m` still lets its blocks grow by, counting a peer's.
memory_budget_left :: proc "contextless" (m: ^Memory_Budget) -> u64 {
	held := budget_held(m)
	return m.limit - min(held, m.limit)
}

// The bytes held by `m` and its peer chain (up to two hops, avoiding a symmetric cycle).
@(private = "file")
budget_held :: #force_inline proc "contextless" (m: ^Memory_Budget) -> u64 {
	held := m.held
	if p := m.peer; p != nil {
		held += p.held
		if p.peer != nil && p.peer != m {
			held += p.peer.held
		}
	}
	return held
}

// The error a read that ended with `err` gives under `m`: `Exceeded` for a refusal the budget or its peer chain (up to
// two hops, matching `budget_held`) made.
memory_budget_error :: proc "contextless" (m: ^Memory_Budget, err: tape.Error) -> tape.Error {
	if ae, ok := err.(runtime.Allocator_Error); ok && ae == .Out_Of_Memory {
		p := m.peer
		if m.refused || p != nil && (p.refused || p.peer != nil && p.peer.refused) {
			return tape.Exceeded{at = tape.NO_BYTE, kind = .Memory}
		}
	}
	return err
}

@(private = "file")
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
	if grows > 0 && u64(grows) > memory_budget_left(m) {
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
