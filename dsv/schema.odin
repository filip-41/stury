package dsv

import core "../core"
import schema "../core/schema"

// A check of a table against a JSON Schema that `json.load_schema` read, from the names of this package: `bind_schema` binds
// it to the spec and options the table is read as, and the checks of `json` run it. Each cell is one kind, a string or
// under `infer` what its text spells, and an empty unquoted cell is a `null`.

// Binds `s` to tables of `spec` read with `opts`, which are checked by the spec's checks.
bind_schema :: proc(s: ^Schema, spec: Spec, opts := Options{}, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	h := as(spec, opts)
	return schema.bind(s, {checks_for(h), h}, allocator)
}
