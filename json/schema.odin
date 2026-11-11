package json

import core "../core"
import schema "../core/schema"

// A check of a text against a JSON Schema, from the names of this package. The schema is read once with `load_schema`, bound
// to the spec the inputs are read as with `bind_schema`, and `check_schema` or `check_schema_records` judge a text or its
// records, each failure going to a `Sink`. See `docs/guide.md`.

// Reads and compiles the schema `text`, a JSON text that outlives the result. A reference to a file leads below `refs`.
load_schema :: proc(text: []u8, refs := "", format_assert := false, allocator := context.allocator) -> (^Schema, core.Error) {
	return schema.open(text, as(.Json), refs, format_assert, allocator)
}

// Binds `s` to texts of `spec`.
bind_schema :: proc(s: ^Schema, spec: Spec, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	return schema.bind(&s.compiled, {layout = as(spec)}, allocator)
}
