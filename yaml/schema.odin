// The entries are generic, which the unused-import check does not read.
#+vet !unused-imports
package yaml

import core "../core"
import schema "../core/schema"

// A check of a text against a JSON Schema, from the names of this package: `bind_schema` binds it to the spec and
// options the text is read as, and `check_schema` judges a text, each failure going to a `Sink`. A scalar is the kind the
// core schema reads it as.

// Reads and compiles the schema `text`, a text of spec `S` read with `opts` that outlives the result, with `load`: where
// file references lead, the draft of a schema with no `$schema`, whether `format` asserts and how a repeated key is judged.
load_schema :: proc(text: []u8, $S: Spec, opts := Options{}, load := Schema_Options{}, allocator := context.allocator) -> (^Schema, core.Error) {
	return schema.compile(text, as(S, opts), load, allocator)
}

// Binds `s` to texts of spec `S` read with `opts`, which the checks of the spec judge.
bind_schema :: proc(s: ^Schema, $S: Spec, opts := Options{}, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	return schema.bind(s, checks(S, opts), allocator)
}
