package schema

import core "../"
import "../typed"

// The text of a conversion's output checked as its format reads it, as one document, or, when `rows`, each element of its
// root array as a document of its own: the check of an output a reader takes row by row.
check_written :: proc(b: ^Bound, text: []u8, as: core.As, rows: bool, sink: ^typed.Sink = nil) -> (err: core.Error) {
	if !rows {
		return check(b, text, sink)
	}
	doc, built := core.build(text, as, allocator = context.temp_allocator)
	if fault, faulted := built.(core.Fault); faulted && fault.kind != .Duplicate_Key {
		return built
	}
	it := core.children(core.Node_Ref{&doc, core.ROOT})
	for row in core.child_next(&it) {
		if failed := check_node(b, &doc, row.(core.Node_Ref).node, sink); err == nil {
			err = failed
		}
	}
	return
}
