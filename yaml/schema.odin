package yaml

import core "../core"
import schema "../core/schema"

// A check of a text against a JSON Schema that `json.load_schema` read, from the names of this package: `bind_schema`
// binds it to the spec and options the text is read as, and `check_schema` judges a text, each failure going to a `Sink`.
// A scalar is the kind the core schema reads it as.

// Binds `s` to texts of `spec` read with `opts`.
bind_schema :: proc(s: ^Schema, spec: Spec, opts := Options{}, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	switch spec {
	case .Yaml_1_2: return schema.bind(s, {checks(.Yaml_1_2).reads, as(spec, opts)}, allocator)
	}
	return {}, core.error_of(core.Typed_Refusal{kind = .Bad_Option})
}
