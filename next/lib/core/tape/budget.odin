package tape

// Resource limits for one read, check or query run. 0 means no limit, except for `depth` and `expansion`, which then
// take their defaults.
Budget :: struct {
	depth:     u32, // deepest nesting
	nodes:     u32, // most nodes a build keeps
	// Bytes, counted per allocator block. A build with `Options.runner` counts the blocks of its parts, which may fit a
	// budget a build on one thread is refused.
	memory:    u64,
	steps:     u64, // containers a walk opens, regex backtracks, schema branches, evaluator calls and loop turns
	// Bytes a text's references may expand to, an XML entity's replacement text or a YAML alias's value, each counted
	// with the references it holds. 0 for `default_expansion` of the text's length.
	expansion: u64,
}

// Which `Budget` limit an `Exceeded` ran out of.
Budget_Kind :: enum u8 {
	None,
	Depth,
	Nodes,
	Memory,
	Steps,
	Expansion,
}

DEFAULT_DEPTH :: 10_000

// The expansion a text of `n` bytes may reach when `Budget.expansion` is 0: 8 MiB, or a hundred times the text when
// that is more.
default_expansion :: proc "contextless" (n: u64) -> u64 {
	return max(8 << 20, n * 100 if n <= max(u64) / 100 else max(u64))
}
