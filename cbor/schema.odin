package cbor

import core "../core"
import schema "../core/schema"

// A check of an item against a JSON Schema, from the names of this package. The schema is read and compiled by a format
// that reads its text, as `json.load_schema` does, bound to CBOR with `bind_schema`, and `check_schema` judges an item,
// each failure going to a `Sink`.

// Binds `s` to items of `spec` read with `opts`.
bind_schema :: proc(s: ^Schema, spec: Spec, opts := Options{}, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	if spec > max(Spec) {
		return {}, core.error_of(core.Typed_Refusal{kind = .Bad_Option})
	}
	return schema.bind(s, {&CHECKS, bound_as(spec, opts)}, allocator)
}
