// The entries are generic, which the unused-import check does not read.
#+vet !unused-imports
package dsv

import core "../core"
import schema "../core/schema"

// A check of a table against a JSON Schema, from the names of this package: `bind_schema` binds it to the spec and
// options the table is read as, and the checks of `json` run it. Each cell is one kind, a string or under `infer` what
// its text spells, and an empty unquoted cell is a `null`.

// Reads and compiles the schema `text`, a text of spec `S` read with `opts` that outlives the result, with `load`: where
// file references lead, the draft of a schema with no `$schema`, whether `format` asserts and how a repeated key is judged.
load_schema :: proc(text: []u8, $S: Spec, opts := Options{}, load := Schema_Options{}, allocator := context.allocator) -> (^Schema, core.Error) {
	return schema.compile(text, as(S, opts), load, allocator)
}

// Binds `s` to texts of spec `S` read with `opts`, which the checks of the spec judge.
bind_schema :: proc(s: ^Schema, $S: Spec, opts := Options{}, allocator := context.allocator) -> (Bound_Schema, core.Error) {
	return schema.bind(s, checks(S, opts), allocator)
}
