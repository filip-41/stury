#+private
package xml

import core "../core"

// The tables a constant-spec entry point binds to its spec. Each factory returns the address of a `@(static, rodata)`
// local of its instance, so a program links the walks of the specs it names. Nothing reachable from here may name `as`,
// `HANDLES` or `SERVICES`, which reach every spec's walk.

// The readers of a document built as spec `S`. It holds no services.
readers_of :: proc "contextless" ($S: Spec) -> ^core.Readers {
	@(static, rodata) r := core.Readers {
		text        = token_decode,
		key_equals  = token_key_equals,
		number      = core.markup_number,
		number_text = core.markup_number_text,
		resolve     = spelling_resolve,
		resolves    = proc "contextless" (as: core.As) -> bool {return options_of(as).infer},
		close_end   = close_end,
		format      = rules_of,
		tag_key     = "xml",
		attribute   = spelling_attribute,
		fact        = spelling_fact,
		key_is      = key_is,
		room        = room,
	}
	return &r
}

// The handle of spec `S` read with `opts`, over `readers_of(S)`.
bound_as :: proc "contextless" ($S: Spec, opts := Options{}) -> core.As {
	return as_of(readers_of(S), S, opts)
}
