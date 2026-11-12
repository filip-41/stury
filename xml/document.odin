package xml

import "base:intrinsics"
import "base:runtime"
import core "../core"

// XML's document holds the walk's tokens over the caller's bytes, read through core's readers and XML's handles. The
// document is an `Object` of one member, the root element. An element is a member under its name: its value is its
// text, a `Plain`, or an `Object` of its child elements and `#text` runs, and its attributes are `Attribute` facts of
// that value.

// XML's handles, one per spec, which only `as` names. A handle's readers are the readers a constant build of its spec
// holds, and its services the walks of that spec. The tables hold pointers to the bound tables, so they are set at
// startup and never written after.
@(private)
HANDLES := [Spec]core.Readers {
	.Xml = handle_readers(.Xml, &SERVICES[.Xml]),
}

@(private)
SERVICES := [Spec]core.Services {
	.Xml = handle_services(.Xml),
}

// The readers of the handle of spec `S`: `readers_of(S)` with the services of `S`.
@(private)
handle_readers :: proc "contextless" ($S: Spec, services: ^core.Services) -> core.Readers {
	r := readers_of(S)^
	r.services = services
	return r
}

// The run-time services of spec `S`, which a handle reaches.
@(private)
handle_services :: proc "contextless" ($S: Spec) -> core.Services {
	return {
		build    = build_of(S),
		validate = proc "contextless" (src: []u8, as: core.As) -> Maybe(core.Fault) {return validate_spec(src, S, options_of(as))},
		scan     = proc(src: []u8, as: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
			return scan_spec(src, S, as, paths, read, state, on, allocator)
		},
		write    = document_write,
		plans    = rawptr(plan_as),
		edit     = &EDIT,
		reads    = reads_of(S),
		tokens   = &TOKENS,
		records  = framing_of(S),
		docs     = record_docs(S),
	}
}

// XML's fault table, which names the format whatever the spec.
@(private)
rules_of :: proc "contextless" () -> ^core.Rules {
	return &RULES
}

// The handle of an XML text of `spec` read with `opts`.
as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return as_of(&HANDLES[spec] if spec <= max(Spec) else nil, spec, opts)
}

// The handle of `spec` read with `opts` over `readers`. The option bytes hold `infer` and then `max_expansion`.
@(private)
as_of :: proc "contextless" (readers: ^core.Readers, spec: Spec, opts: Options) -> core.As {
	a := core.As{readers = readers, spec = u8(spec), max_depth = opts.max_depth, tolerate = opts.tolerate, opts = {0 = u8(opts.infer)}}
	intrinsics.unaligned_store((^u64)(&a.opts[1]), opts.max_expansion)
	return a
}

#assert(size_of(core.As) - offset_of(core.As, opts) >= 1 + size_of(u64))

// The options a handle `as` made holds.
@(private)
options_of :: #force_inline proc "contextless" (as: core.As) -> Options {
	as := as
	return {max_depth = as.max_depth, infer = as.opts[0] != 0, tolerate = as.tolerate, max_expansion = intrinsics.unaligned_load((^u64)(&as.opts[1]))}
}

// The DTD of the text `v` views, in `out`, or nil for a text with none.
@(private)
dtd_of :: #force_inline proc "contextless" (v: ^core.Token_View, out: ^Dtd_View) -> ^Dtd_View {
	if len(v.state) == 0 {
		return nil
	}
	out^ = dtd_view(v.state)
	return out
}

// XML's `Readers.room`: a span that refers to entities decodes to their replacement texts.
@(private)
room :: proc(v: ^core.Token_View, lo: u64, n: u32) -> int {
	dtd: Dtd_View
	if dtd_of(v, &dtd) == nil {
		return int(n)
	}
	return int(min(expansion_room(&dtd, v.src, v.src[lo:lo + u64(n)]), u64(max(int))))
}

// `Token.spelling`'s bits for an attribute's value that is not its own text, which `Readers.attribute` sets beside
// `SPELLING_DECODE`: the value is decoded as an attribute's is, and one whose declared type is not `CDATA` then loses its
// leading and trailing spaces and has each run of spaces made one. Core reads bits 0 to 2 of a value.
@(private)
SPELLING_ATTRIBUTE :: u16(1 << 14)
@(private)
SPELLING_TOKENIZED :: u16(1 << 15)

#assert((SPELLING_ATTRIBUTE | SPELLING_TOKENIZED) & (core.SPELLING_DECODE | core.SPELLING_QUOTED | core.SPELLING_LAX) == 0)

// XML's `Readers.text`. An element's name is its span and the `#text` member's name is `#text`. An element's text and
// a `#text` run are decoded into `buf` as content, and an attribute's value, which `SPELLING_ATTRIBUTE` marks, as an
// attribute value, unless the walk found nothing to decode. `core.text_room` sizes `buf`. A container returns false.
@(private)
token_decode :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	if t.kind > .Plain {
		return "", false
	}
	if t.role == .Key {
		if t.spelling & core.SPELLING_SYNTHETIC == core.SPELLING_SYNTHETIC {
			return TEXT_KEY, true
		}
		return string(v.src[t.lo:t.lo + u64(t.n)]), true
	}
	span := v.src[t.lo:t.lo + u64(t.n)]
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(span), true
	}
	dtd: Dtd_View
	if t.spelling & SPELLING_ATTRIBUTE != 0 {
		return attribute_text(span, buf, dtd_of(v, &dtd), v.src, t.spelling & SPELLING_TOKENIZED != 0)
	}
	return content_text(span, buf, dtd_of(v, &dtd), v.src)
}

// The name of the member that holds the text between an element's children.
TEXT_KEY :: core.MARKUP_TEXT

// Whether key `t` is spelled `name`. An expanded name needs the key's place in the document, see `key_is`.
@(private)
token_key_equals :: proc "contextless" (v: ^core.Token_View, t: core.Token, name: string) -> bool {
	if t.spelling & core.SPELLING_SYNTHETIC == core.SPELLING_SYNTHETIC {
		return name == TEXT_KEY
	}
	return string(v.src[t.lo:t.lo + u64(t.n)]) == name
}

// XML's `Readers.resolve`, what a `Plain` value is: its decoded text as the document's `infer` reads it.
@(private)
spelling_resolve :: proc(doc: ^core.Document, i: core.Node_Index) -> core.Kind {
	return core.markup_resolve(doc, i, options_of(doc.as).infer)
}

// Says why an edit may not touch `node`, as `core.Edit_Services.frozen` asks: a node whose bytes lie in the internal
// subset is an entity's replacement text walked in place or an attribute-list default, which no edit of the document
// can respell.
@(private)
frozen :: proc(doc: ^core.Document, node: core.Node_Index) -> (rules: ^core.Rules, detail: u8) {
	dtd: Dtd_View
	if dtd_of(&doc.view, &dtd) == nil {
		return nil, 0
	}
	lo := doc.nodes[node].lo
	if lo < dtd.head.subset_lo || lo >= dtd.head.subset_hi {
		return nil, 0
	}
	return &RULES, u8(Detail.Replacement)
}
