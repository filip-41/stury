package html

import "base:runtime"
import core "../core"
import typed "../core/typed"

// HTML's document holds the tokens of the tree a text builds (emit.odin), over the caller's bytes, read through core's
// readers, core's markup readers and HTML's handles, in the shape XML's document has for the same markup. The state
// holds what the tokens' spans do not: each element's close and the pieces of a text that is no one span.

// HTML's handles, one per spec, which only `as` names. A handle's readers are the readers an entry point's build holds,
// and its services the reads of that spec. The tables hold pointers to the bound tables, so they are set at
// startup and never written after.
@(private)
HANDLES := [Spec]core.Readers {
	.Document = handle_readers(&SERVICES[.Document]),
	.Fragment = handle_readers(&SERVICES[.Fragment]),
}

@(private)
SERVICES := [Spec]core.Services {
	.Document = handle_services(reads_of(.Document)),
	.Fragment = handle_services(reads_of(.Fragment)),
}

// The readers of a handle: `READERS` with `services`.
@(private)
handle_readers :: proc "contextless" (services: ^core.Services) -> core.Readers {
	r := READERS
	r.services = services
	return r
}

// The run-time services of a spec whose typed reads are `reads`, which a handle reaches. A read by paths builds the
// document whole.
@(private)
handle_services :: proc "contextless" (reads: ^typed.Format_Reads) -> core.Services {
	return {
		build    = build_handle,
		validate = proc "contextless" (src: []u8, as: core.As) -> Maybe(core.Fault) {return validate_spec(src, Spec(as.spec), options_of(as))},
		scan     = proc(src: []u8, as: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
			return scan_spec(src, Spec(as.spec), as, paths, read, state, on, allocator)
		},
		write    = document_write,
		plans    = rawptr(plan_as),
		edit     = &EDIT,
		reads    = reads,
		tokens   = &TOKENS,
		records  = &FRAMING,
		docs     = &RECORD_DOCS,
	}
}

// HTML's fault table, which names the format whatever the spec.
@(private)
rules_of :: proc "contextless" () -> ^core.Rules {
	return &RULES
}

// The handle of an HTML text of `spec` read with `opts`.
as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return as_of(&HANDLES[spec] if spec <= max(Spec) else nil, spec, opts)
}

// The handle of `spec` read with `opts` over `readers`. The option bytes hold `infer`, `scripting` and the fragment's
// context element.
@(private)
as_of :: proc "contextless" (readers: ^core.Readers, spec: Spec, opts: Options) -> core.As {
	r := read_of(opts)
	return {readers = readers, spec = u8(spec), max_depth = r.max_depth, opts = {0 = u8(r.infer), 1 = u8(r.scripting), 2 = u8(r.fragment.ns), 3 = u8(r.fragment.tag), 4 = r.fragment.name}}
}

// The read a handle `as` made holds.
@(private)
options_of :: #force_inline proc "contextless" (as: core.As) -> Read {
	return {
		max_depth = as.max_depth,
		infer = as.opts[0] != 0,
		scripting = as.opts[1] != 0,
		fragment = {ns = Namespace(min(as.opts[2], u8(max(Namespace)))), tag = Tag(min(as.opts[3], u8(max(Tag)))), name = min(as.opts[4], u8(len(FOREIGN_NAMES) - 1))},
	}
}

// HTML's `Readers.text`. A key reads as its form says, and a text value is decoded as the tokenizer read it, piece by
// piece when the state lists it. `core.text_room` sizes `buf`. A container returns false.
@(private)
token_decode :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	if t.kind > .Plain {
		return "", false
	}
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(v.src[t.lo:t.lo + u64(t.n)]), true
	}
	if t.role == .Key {
		return key_text(v.src, t, buf)
	}
	mode := Mode(t.spelling >> TEXT_MODE_SHIFT & 7)
	if t.spelling & TEXT_PIECES == 0 {
		return decode(v.src, Span{lo = t.lo, n = t.n, mode = mode, flags = DECODED}, buf)
	}
	w := 0
	for p in text_pieces(v.state, t.lo) or_return {
		p := p
		p.flags = DECODED
		part := decode(v.src, p, buf[w:]) or_return
		copy(buf[w:], part)
		w += len(part)
	}
	return string(buf[:w]), true
}

// The pieces the state lists for the text whose first byte is `lo`.
@(private)
text_pieces :: proc "contextless" (state: []u8, lo: u64) -> (pieces: []Span, ok: bool) {
	_, texts, all := state_tables(state)
	i, j := 0, len(texts)
	for i < j {
		mid := (i + j) / 2
		if texts[mid].lo < lo {
			i = mid + 1
		} else {
			j = mid
		}
	}
	if i == len(texts) || texts[i].lo != lo {
		return nil, false
	}
	return all[texts[i].first:][:texts[i].count], true
}

// The text of key `t`, whose `SPELLING_DECODE` is set.
@(private)
key_text :: proc "contextless" (src: []u8, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	index := t.spelling >> KEY_INDEX_SHIFT
	switch key_form(t.spelling) {
	case .Span:
		return TEXT_KEY, true
	case .Tag:
		return TAG_NAMES[Tag(index)], true
	case .Foreign:
		return FOREIGN_NAMES[index].name, true
	case .Fold:
		if t.spelling & core.SPELLING_LAX != 0 {
			return decode(src, Span{lo = t.lo, n = t.n, mode = .Name, flags = DECODED}, buf)
		}
		if len(buf) < int(t.n) {
			return "", false
		}
		for c, i in src[t.lo:t.lo + u64(t.n)] {
			buf[i] = c | 0x20 if c - 'A' < 26 else c
		}
		return string(buf[:t.n]), true
	}
	return "", false
}

// The name of the member that holds the text between an element's children.
TEXT_KEY :: core.MARKUP_TEXT

// Whether key `t` reads as `name`.
@(private)
token_key_equals :: proc "contextless" (v: ^core.Token_View, t: core.Token, name: string) -> bool {
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(v.src[t.lo:t.lo + u64(t.n)]) == name
	}
	if key_form(t.spelling) != .Fold {
		s, _ := key_text(v.src, t, nil)
		return s == name
	}
	if t.spelling & core.SPELLING_LAX == 0 {
		return fold_name_equal(v.src[t.lo:t.lo + u64(t.n)], name)
	}
	if len(name) > 3 * int(t.n) {
		return false
	}
	context = runtime.default_context()
	buf := make([]u8, 3 * int(t.n), context.temp_allocator)
	s, _ := decode(v.src, Span{lo = t.lo, n = t.n, mode = .Name, flags = DECODED}, buf)
	return s == name
}

// Whether the name `written` with its ASCII upper case lowered is `name`.
@(private)
fold_name_equal :: proc "contextless" (written: []u8, name: string) -> bool {
	if len(written) != len(name) {
		return false
	}
	for c, i in written {
		if (c | 0x20 if c - 'A' < 26 else c) != name[i] {
			return false
		}
	}
	return true
}

// HTML's `Readers.resolve`, what a `Plain` value is: its decoded text as the document's `infer` reads it.
@(private)
spelling_resolve :: proc(doc: ^core.Document, i: core.Node_Index) -> core.Kind {
	return core.markup_resolve(doc, i, options_of(doc.as).infer)
}

// HTML's `Readers.attribute`: the name of attribute fact `f` as a `Key`, its case lowered and, on an SVG or MathML
// element, its mixed case restored, and its value as a `Plain`, the bytes between its quotes or the unquoted value,
// decoded by `token_decode` when it holds a reference, U+0000, a CR or a byte past ASCII. A valueless attribute's value
// is an empty `String`.
@(private)
spelling_attribute :: proc "contextless" (doc: ^core.Document, f: core.Fact) -> (name, value: core.Token) {
	src := doc.src
	hi := f.lo + u64(f.n)
	q := f.lo + 1
	for q < hi && !is_space(src[q]) && src[q] != '/' && src[q] != '>' && src[q] != '=' {
		q += 1
	}
	name = {lo = f.lo, n = u32(q - f.lo), kind = .String, role = .Key}
	// An attribute is a fact of its element's value, which the element's key stands before.
	ns := Namespace.Html
	if f.node > 0 && int(f.node) <= len(doc.nodes) && doc.nodes[f.node - 1].role == .Key {
		ns = Namespace(doc.nodes[f.node - 1].spelling >> KEY_NS_SHIFT & 3)
	}
	written := src[f.lo:q]
	if ns != .Html {
		i := foreign_of(raw_data(written), u32(len(written)))
		kinds := FOREIGN_NAMES[i].kinds
		if .Svg_Attribute in kinds && ns == .Svg || .Math_Attribute in kinds && ns == .Math {
			name.spelling = core.SPELLING_DECODE | u16(Key_Form.Foreign) << KEY_FORM_SHIFT | u16(i) << KEY_INDEX_SHIFT
		}
	}
	if name.spelling == 0 {
		name.spelling = name_spelling(byte_flags(written))
	}
	lead, tail := core.comment_lead(f.spelling), core.comment_tail(f.spelling)
	start := f.lo + lead
	if lead == core.ATTRIBUTE_LEAD_MAX {
		start = q
		for start < hi && is_space(src[start]) {
			start += 1
		}
		if start < hi && src[start] == '=' {
			start += 1
			for start < hi && is_space(src[start]) {
				start += 1
			}
			start += tail
		} else {
			start = hi
		}
	}
	if tail == 0 && start >= hi {
		return name, {lo = hi, kind = .String}
	}
	value = {lo = start, n = u32(hi - tail - start), kind = .Plain}
	if byte_flags(src[start:hi - tail]) & {.Ref, .Nul, .Cr, .Invalid} != {} {
		value.spelling = core.SPELLING_DECODE | core.SPELLING_LAX | u16(Mode.Value) << TEXT_MODE_SHIFT
	}
	return
}

// The flags a scan of `b` finds that `decode` would change: an `&`, U+0000, an ASCII capital, a CR, and any byte past
// ASCII, which may be ill-formed.
@(private)
byte_flags :: proc "contextless" (b: []u8) -> (flags: Span_Flags) {
	for c in b {
		switch {
		case c == '&':
			flags += {.Ref}
		case c == 0:
			flags += {.Nul}
		case c - 'A' < 26:
			flags += {.Upper}
		case c == '\r':
			flags += {.Cr}
		case c >= 0x80:
			flags += {.Invalid}
		}
	}
	return
}

// The namespace URIs of HTML's elements.
@(private, rodata)
NAMESPACE_URIS := [Namespace]string {
	.Html = "http://www.w3.org/1999/xhtml",
	.Svg  = "http://www.w3.org/2000/svg",
	.Math = "http://www.w3.org/1998/Math/MathML",
}

// The facts HTML names for node `i`, the value of an element or the document: its name and string value as every
// markup format reads them, and the namespace of its element.
@(private)
spelling_fact :: proc(doc: ^core.Document, i: core.Node_Index, name: core.Fact_Name) -> (core.Fact_Value, bool) {
	switch name {
	case .Tag, .Anchor, .Alias, .Style:
		return {}, false
	case .Name, .Content:
		return core.markup_fact(doc, i, name)
	case .Namespace:
		if i == core.ROOT || doc.nodes[i - 1].role != .Key {
			return {}, false
		}
		k := doc.nodes[i - 1]
		if k.spelling & core.SPELLING_SYNTHETIC == core.SPELLING_SYNTHETIC && key_form(k.spelling) == .Span {
			return {}, false
		}
		return {text = NAMESPACE_URIS[Namespace(k.spelling >> KEY_NS_SHIFT & 3)]}, true
	}
	return {}, false
}

// The byte just past the element at container node `i`, from the state, or past the text for the document's node.
@(private)
close_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	if i == core.ROOT {
		return u64(len(doc.src))
	}
	ends, _, _ := state_tables(doc.state)
	lo, hi := 0, len(ends)
	for lo < hi {
		mid := (lo + hi) / 2
		if ends[mid].node < u32(i) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(ends) && ends[lo].node == u32(i) {
		return ends[lo].end
	}
	return doc.nodes[i].lo
}

// Says why an edit may not touch `node`, as `core.Edit_Services.frozen` asks: a text read across a start tag the tree
// dropped holds the tag's effect in its span. The commit refuses an edit that writes at a node the tree construction
// made, since only it knows where the edit writes.
@(private)
frozen :: proc(doc: ^core.Document, node: core.Node_Index) -> (rules: ^core.Rules, detail: u8) {
	n := doc.nodes[node]
	if n.kind != .Plain || n.spelling & TEXT_PIECES == 0 {
		return nil, 0
	}
	pieces, _ := text_pieces(doc.state, n.lo)
	for i in 1 ..< len(pieces) {
		end := pieces[i - 1].lo + u64(pieces[i - 1].n)
		gap := doc.src[end:max(pieces[i].lo, end)]
		for c, k in gap {
			if c == '<' && k + 1 < len(gap) && gap[k + 1] | 0x20 - 'a' < 26 {
				return &RULES, u8(Detail.Split)
			}
		}
	}
	return nil, 0
}
