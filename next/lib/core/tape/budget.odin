package tape

// Resource limits for one read, check or query run. 0 means no limit, except for `depth`, where it means
// `DEFAULT_DEPTH`.
Budget :: struct {
	depth:  u32, // deepest nesting
	nodes:  u32, // most nodes a build keeps
	// Bytes, counted per allocator block. A build with `Options.runner` counts the blocks of its parts, which may fit a
	// budget a build on one thread is refused.
	memory: u64,
	steps:  u64, // containers a walk opens, regex backtracks, schema branches, evaluator calls and loop turns
}

// Which `Budget` limit an `Exceeded` ran out of.
Budget_Kind :: enum u8 {
	Depth,
	Nodes,
	Memory,
	Steps,
}

DEFAULT_DEPTH :: 10_000
