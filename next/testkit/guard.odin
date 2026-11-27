package testkit

import "base:runtime"
import "core:mem"

// The bytes after each block that a `Guarded` allocator fills, and checks when the block ends or is checked.
GUARD_BYTES :: 32

// An allocator over `backing` that detects a write past the end of a block: each block has `GUARD_BYTES` more after it,
// holding a pattern, and `broken` counts the blocks found with it changed, at their end or at `guarded_check`. A plain
// test build runs with no bounds check on the heap, so this is how a write past a room shows there.
Guarded :: struct {
	backing: runtime.Allocator,
	sizes:   map[rawptr]int, // each live block's size
	broken:  int,
}

guarded_init :: proc(g: ^Guarded, backing: runtime.Allocator) {
	g.backing = backing
	g.sizes = make(map[rawptr]int, backing)
	g.broken = 0
}

guarded_destroy :: proc(g: ^Guarded) {
	delete(g.sizes)
}

guarded_allocator :: proc(g: ^Guarded) -> runtime.Allocator {
	return {guarded_proc, g}
}

// Counts each live block whose guard bytes changed, and returns whether none has.
guarded_check :: proc(g: ^Guarded) -> bool {
	for block, size in g.sizes {
		guard_check(g, block, size)
	}
	return g.broken == 0
}

@(private)
guard_check :: proc(g: ^Guarded, block: rawptr, size: int) {
	for b in ([^]u8)(block)[size:][:GUARD_BYTES] {
		if b != GUARD_PATTERN {
			g.broken += 1
			return
		}
	}
}

@(private)
GUARD_PATTERN :: u8(0xA5)

@(private)
guarded_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	g := (^Guarded)(data)
	b := g.backing
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		block, err := b.procedure(b.data, mode, size + GUARD_BYTES, alignment, nil, 0, loc)
		if err != nil {
			return nil, err
		}
		mem.set(raw_data(block)[size:], GUARD_PATTERN, GUARD_BYTES)
		g.sizes[raw_data(block)] = size
		return block[:size], nil
	case .Free:
		if old_memory == nil {
			return nil, nil
		}
		held := g.sizes[old_memory]
		guard_check(g, old_memory, held)
		delete_key(&g.sizes, old_memory)
		_, err := b.procedure(b.data, .Free, 0, alignment, old_memory, held + GUARD_BYTES, loc)
		return nil, err
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return guarded_proc(data, .Alloc, size, alignment, nil, 0, loc)
		}
		held := g.sizes[old_memory]
		block, err := guarded_proc(data, .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		if err != nil {
			return nil, err
		}
		mem.copy(raw_data(block), old_memory, min(held, size))
		if mode == .Resize && size > held {
			mem.zero(raw_data(block)[held:], size - held)
		}
		_, ferr := guarded_proc(data, .Free, 0, alignment, old_memory, held, loc)
		return block, ferr
	case .Free_All, .Query_Features, .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}
