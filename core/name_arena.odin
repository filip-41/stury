package core

import "base:runtime"

// The block size the retained-name arena grows in. A name longer than a block
// gets a block of its own, so this is a speed choice, not a cap.
NAME_BLOCK_BYTES :: 64 * 1024

// The stable store behind every retained member name. `Name`s are slices, so their bytes must never move
// while the answer lives (a `[dynamic]u8` would reallocate on append and leave earlier names dangling). The
// bytes live in fixed-size blocks that are never resized or moved until `name_arena_destroy`.
Name_Arena :: struct {
	// Slice headers only. The bytes they point at never move. Its allocator is the blocks' too.
	blocks: [dynamic][]u8,
	// The block the next write goes into. Blocks before it are full.
	cur:    int,
	used:   int,
}

// Bind the arena's allocator: the first query to name the sink sets it, and a later query must agree, so a
// single arena cannot grow under two different allocators.
name_arena_adopt :: #force_inline proc(a: ^Name_Arena, want: runtime.Allocator) -> bool {
	return adopt_allocator(&a.blocks, want)
}

// Reserve `n` writable bytes, uninitialized, valid until the arena is destroyed. `ok == false` reports that a
// block could not be allocated. For callers that write the bytes themselves (the DOM string decoder unescapes
// straight into the block and keeps only the produced prefix).
name_arena_reserve :: proc(a: ^Name_Arena, n: int) -> (out: []u8, ok: bool) {
	// An empty run has no bytes to keep and nothing to dangle.
	if n <= 0 {
		return nil, true
	}
	// Try the current block, then later ones (those exist only after `name_arena_reset`).
	for a.cur < len(a.blocks) {
		blk := a.blocks[a.cur]
		// Subtraction form so `a.used + n` cannot wrap. Not `intrinsics.overflow_add`:
		// its flag is inverted on the pinned toolchain.
		room := len(blk) - a.used
		if n <= room {
			out = blk[a.used:a.used + n]
			a.used += n
			return out, true
		}
		a.cur += 1
		a.used = 0
	}
	size := NAME_BLOCK_BYTES
	if n > size {
		size = n
	}
	blk, err := runtime.mem_alloc_non_zeroed(size, 1, a.blocks.allocator)
	if err == .Mode_Not_Implemented {
		blk, err = runtime.mem_alloc(size, 1, a.blocks.allocator)
	}
	// A zero allocator yields nil and reports no error, so nil is a failure too.
	if err != nil || blk == nil {
		return nil, false
	}
	if _, aerr := append(&a.blocks, blk); aerr != .None {
		delete(blk, a.blocks.allocator)
		return nil, false
	}
	a.used = n
	a.cur = len(a.blocks) - 1
	return blk[:n], true
}

// Hand back the last `n` bytes of the latest `name_arena_reserve`, which the caller did not fill.
name_arena_unreserve :: #force_inline proc(a: ^Name_Arena, n: int) {
	a.used -= n
}

// Reuse every block from the start, so a long-lived sink does not grow without bound. Safe only when nothing
// reads through the arena any more.
name_arena_reset :: proc(a: ^Name_Arena) {
	a.cur = 0
	a.used = 0
}


// Release every block. Called with the rest of what owns the arena (a document), because the names are only as
// long-lived as what owns the bytes they name.
name_arena_destroy :: proc(a: ^Name_Arena) {
	for b in a.blocks {
		delete(b, a.blocks.allocator)
	}
	delete(a.blocks)
	// The allocator goes with the blocks: left bound, a reused sink would pass
	// the `allocator_ok` check against an allocator from the ended scan.
	a^ = {}
}
