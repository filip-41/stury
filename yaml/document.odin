#+private
package yaml

import "base:intrinsics"
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

// The reasons the writer gives a refusal that names none.
@(private)
WRITE_WORDS :: core.Write_Words{"YAML has no spelling for the text, or the object repeats a key", "YAML writes a whole document"}

SERVICES := [Spec]core.Services {
	.Yaml_1_2 = {
		build    = build_as,
		validate = validate_as,
		scan     = scan_as,
		write    = document_write,
		words    = WRITE_WORDS,
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
	intrinsics.unaligned_store((^u64)(&a.opts), opts.alias_limit)
	a.opts[8] = u8(opts.merge_keys)
	return a
}

options_of :: #force_inline proc "contextless" (as: core.As) -> Options {
	as := as
	return {max_depth = as.max_depth, alias_limit = intrinsics.unaligned_load((^u64)(&as.opts)), merge_keys = as.opts[8] != 0}
}

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
