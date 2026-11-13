#+private
package yaml

import spell "../core/spell"
import core "../core"

// YAML's document holds the walk's tokens over the caller's bytes, read through core's readers and YAML's handles. A
// scalar is a `Plain` node that `resolve` types, and a block collection has no bytes of its own.

// YAML's handles, one per spec, which only `as` names. A handle's readers are the readers an entry point's build holds,
// and its services the walks of that spec. The tables hold pointers to the bound tables, so they are set at
// startup and never written after.
HANDLES := [Spec]core.Readers {
	.Yaml_1_2 = core.with_services(READERS, &SERVICES[.Yaml_1_2]),
}

SERVICES := [Spec]core.Services {
	.Yaml_1_2 = {
		build    = build_as,
		validate = validate_as,
		scan     = scan_as,
		write    = document_write,
		edit     = &EDIT,
		plans    = rawptr(plan_as),
		reads    = &CHECKS,
		tokens   = &TOKENS,
		records  = &FRAMING,
		docs     = &RECORD_DOCS,
	},
}

// YAML's fault table, which names the format whatever the spec.
rules_of :: proc "contextless" () -> ^core.Rules {
	return &RULES
}

// The handle of `spec` read with `opts` over `readers`.
as_of :: proc "contextless" (readers: ^core.Readers, spec: Spec, opts: Options) -> core.As {
	a := core.As{readers = readers, spec = u8(spec), max_depth = opts.max_depth}
	limit := opts.alias_limit
	for i in 0 ..< 8 {
		a.opts[i] = u8(limit >> (8 * uint(i)))
	}
	a.opts[8] = u8(opts.merge_keys)
	return a
}

options_of :: #force_inline proc "contextless" (as: core.As) -> Options {
	limit: u64
	for i in 0 ..< 8 {
		limit |= u64(as.opts[i]) << (8 * uint(i))
	}
	return {max_depth = as.max_depth, alias_limit = limit, merge_keys = as.opts[8] != 0}
}

// Whether `doc` was read from a YAML text.
is_yaml :: #force_inline proc "contextless" (doc: ^core.Document) -> bool {
	return doc.readers != nil && doc.readers.format == rules_of
}

// Whether the decoded text of key `t` is `name`. A key longer than the stack buffer decodes on the heap.
spelling_key_equals :: proc "contextless" (v: ^core.Token_View, t: core.Token, name: string) -> bool {
	Key :: struct {
		span:     []u8,
		spelling: u16,
	}
	span := v.src[t.lo:t.lo + u64(t.n)]
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(span) == name
	}
	key := Key{span, t.spelling}
	return spell.buffered_equals(len(span) * 3 + 4, name, &key, proc "contextless" (c: rawptr, buf: []u8) -> (string, bool) {
		k := (^Key)(c)
		return decode(k.span, k.spelling, buf)
	})
}
