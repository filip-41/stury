package yaml

import core "../core"
import schema "../core/schema"

// A check of a text against a JSON Schema that `json.load_schema` read, from the names of this package: `bind_schema`
// binds it to the spec and options the text is read as, and `check_schema` judges a text, each failure going to a `Sink`.
// A scalar is the kind the core schema reads it as.

// Binds `s` to texts of `spec` read with `opts`.
bind_schema :: proc(s: ^Schema, spec: Spec, opts := Options{}, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	return schema.bind(s, {layout = as(spec, opts)}, allocator)
}
