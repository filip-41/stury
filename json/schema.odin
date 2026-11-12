package json

import core "../core"
import schema "../core/schema"

// A check of a text against a JSON Schema, from the names of this package. The schema is read once with `load_schema`, bound
// to the spec the inputs are read as with `bind_schema`, and `check_schema` or `check_schema_records` judge a text or its
// records, each failure going to a `Sink`. See `docs/guide.md`.

// Reads and compiles the schema `text`, a JSON text that outlives the result, with `opts`: where file references lead,
// the draft of a schema with no `$schema`, whether `format` asserts and how a repeated key is judged.
load_schema :: proc(text: []u8, opts := Schema_Options{}, allocator := context.allocator) -> (^Schema, core.Error) {
	return schema.compile(text, as(.Json), opts, allocator)
}

// Binds `s` to texts of `spec` read with `opts`.
bind_schema :: proc(s: ^Schema, spec: Spec, opts := Options{}, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	return schema.bind(s, {layout = as(spec, opts)}, allocator)
}
