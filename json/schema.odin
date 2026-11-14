// The entries are generic, which the unused-import check does not read.
#+vet !unused-imports
package json

import core "../core"
import schema "../core/schema"

// A check of a text against a JSON Schema, from the names of this package. The schema is read once with `load_schema`, bound
// to the spec the inputs are read as with `bind_schema`, and `check_schema` or `check_schema_records` judge a text or its
// records, each failure going to a `Sink`. See `docs/guide.md`.

// Reads and compiles the schema `text`, a text of spec `S` read with `opts` that outlives the result, with `load`: where
// file references lead, the draft of a schema with no `$schema`, whether `format` asserts and how a repeated key is judged.
load_schema :: proc(text: []u8, $S: Spec, opts := Options{}, load := Schema_Options{}, allocator := context.allocator) -> (^Schema, core.Error) {
	return schema.compile(text, as(S, opts), load, allocator)
}

// Binds `s` to texts of spec `S` read with `opts`, which the checks of the spec judge.
bind_schema :: proc(s: ^Schema, $S: Spec, opts := Options{}, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	return schema.bind(s, checks(S, opts), allocator)
}
