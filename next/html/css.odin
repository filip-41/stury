package html

import "base:runtime"
import "stury:lib/core/tape"
import "stury:lib/ops/css"

// CSS selectors (Selectors Level 4 static subset) over built HTML documents.
// Matches element/attribute names ASCII case-insensitively per HTML5 rules.

Selector :: css.Selector
Found :: css.Found
Match :: css.Match
Selector_Step :: css.Step

compile :: css.compile
destroy_selector :: css.destroy
destroy_found :: css.destroy_found
steps_of :: css.steps_of

select :: proc {
	select_doc,
	select_from,
}

select_doc :: proc(doc: ^tape.Document, sel: ^Selector, from := tape.ROOT, allocator := context.allocator) -> (Found, runtime.Allocator_Error) {
	return css.select(doc, from, sel, {attribute = attribute, fold = true}, allocator)
}

select_from :: proc(doc: ^tape.Document, from: tape.Node_Index, sel: ^Selector, allocator := context.allocator) -> (Found, runtime.Allocator_Error) {
	return css.select(doc, from, sel, {attribute = attribute, fold = true}, allocator)
}
