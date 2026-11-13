#+private
package html

import core "../core"

// The readers the entry points bind. Nothing reachable from here may name `as`, `HANDLES` or `SERVICES`, which reach
// every pass.

// The readers of a document the entry points build. It holds no services.
@(rodata)
READERS := core.Readers {
	text        = token_decode,
	key_equals  = token_key_equals,
	number      = core.markup_number,
	number_text = core.markup_number_text,
	resolve     = spelling_resolve,
	resolves    = proc "contextless" (as: core.As) -> bool {return options_of(as).infer},
	close_end   = close_end,
	format      = rules_of,
	tag_key     = "html",
	attribute   = spelling_attribute,
	fact        = spelling_fact,
}

// The handle of `spec` read with `opts`, over `READERS`.
bound_as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return as_of(&READERS, spec, opts)
}
