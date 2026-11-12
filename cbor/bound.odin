#+private
package cbor

import core "../core"

// The tables an entry point of the package binds, in rodata, so a program links the passes of the entry points it
// names. Nothing reachable from here may name `as`, `HANDLE` or `SERVICES`, which reach every pass.

// The readers of a built document: the leaves and `close_end`. It holds no services.
@(rodata)
READERS := core.Readers {
	text        = text,
	key_equals  = spelling_key_equals,
	number      = number,
	number_text = number_text,
	close_end   = close_end,
	format      = format_rules,
	fact        = fact,
	tag_key     = "cbor",
	binary      = true,
	key_bytes   = key_bytes,
}

// The handle of an item of `spec` read with `opts`, over `READERS`.
bound_as :: #force_inline proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return as_of(&READERS, spec, opts)
}

// The leaves of a plan and a typed read, with what a plan compares a key by, and no `close_end` and no services. Every
// plan holds this table, and the option bytes in `As`.
@(rodata)
PLAN_READERS := core.Readers {
	text        = text,
	key_equals  = spelling_key_equals,
	number      = number,
	number_text = number_text,
	format      = format_rules,
	tag_key     = "cbor",
	binary      = true,
	key_bytes   = key_bytes,
}
