package schema

import "base:runtime"
import core "../"

// A schema read from its text and compiled, with the document `compiled` borrows from.
Loaded :: struct {
	doc:       core.Document,
	compiled:  Compiled,
	allocator: runtime.Allocator,
}

// Reads the schema `text` in the format `as`, and compiles it. A reference to a file leads below `refs`, the empty string
// for none. `text` outlives the result.
open :: proc(text: []u8, as: core.As, refs := "", format_assert := false, allocator := context.allocator) -> (l: ^Loaded, err: core.Error) {
	l = new(Loaded, allocator)
	l.allocator = allocator
	defer if err != nil {
		loaded_destroy(l)
		l = nil
	}
	l.doc = core.build(text, as, allocator = allocator) or_return
	l.compiled = compile(&l.doc, core.ROOT, {format_assert = format_assert, resolver = {root = refs, as = as}}, allocator) or_return
	return
}

loaded_destroy :: proc(l: ^Loaded) {
	if l == nil {
		return
	}
	destroy(&l.compiled)
	core.destroy(&l.doc)
	free(l, l.allocator)
}
