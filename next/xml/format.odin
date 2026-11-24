package xml

import "base:runtime"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/markup"
import "stury:lib/core/tape"

// The services of the XML spec beyond the node readers: the reads and records that `xml.reads` returns to a caller
// picking the format at run time, the decode of a node's text, and where a container closes.

// In a text's spelling, beside `SPELLING_DECODE`, the text refers to an entity the DTD declares or one the HTML standard
// names, so its decode reads the DTD the document holds.
@(private)
SPELLING_DTD :: u16(1 << 12)

// In a value's spelling, beside `SPELLING_DECODE`, the value is an attribute's, which decodes as an attribute value,
// and with `SPELLING_TOKENIZED` one of a type the DTD declares that is not `CDATA`, which then loses its leading and
// trailing spaces and has each run of spaces made one.
@(private)
SPELLING_ATTRIBUTE :: u16(1 << 14)
@(private)
SPELLING_TOKENIZED :: u16(1 << 15)

#assert((SPELLING_DTD | SPELLING_ATTRIBUTE | SPELLING_TOKENIZED | markup.SPELLING_TEXT_KEY) & 0x7FF == 0)

// The reads of `spec`, for a caller that picks the format at run time, to use with the handle `as` returns. Nil for a
// `spec` out of range.
reads :: proc "contextless" (spec: Spec) -> ^tape.Reads {
	return tape.format_reads(Spec, ID, validate, build, find, scan, Records, records_open, records_validate, records_find, records_scan) if spec <= max(Spec) else nil
}

// A token's span is its whole authored span: an element's text spans its content, and a `#text` key spans no byte.
@(private)
bounds :: proc "contextless" (src: []u8, t: tape.Token) -> (head, tail: u8) {
	return 0, 0
}

@(private)
number_value :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
	num, _ := spell.number_strict(src, t.lo, t.lo + u64(t.n))
	return num
}

// The decode of text `t` of `src` into `buf`: `#text` for a text member's key, an attribute's value as an attribute
// value is decoded, and any other text as content. A text that refers to the DTD's entities reads them from the
// document's format data `ext`, which `prolog_ext` reads for a text of no document. False when `buf` is shorter than
// `decode_room` gives, or for such a text read with no format data.
@(private)
text_decoded :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8, ext: ^tape.Format_Ext) -> (s: string, ok: bool) {
	if markup.is_text_key(t) {
		if len(buf) < len(markup.TEXT_KEY) {
			return "", false
		}
		return string(buf[:copy(buf, markup.TEXT_KEY)]), true
	}
	span := src[t.lo:][:t.n]
	dtd: ^Dtd_View
	if t.spelling & SPELLING_DTD != 0 {
		dtd = dtd_of(ext) or_return
	}
	if t.spelling & SPELLING_ATTRIBUTE != 0 {
		return attribute_text(span, buf, dtd, src, t.spelling & SPELLING_TOKENIZED != 0)
	}
	return content_text(span, buf, dtd, src)
}

// The bytes that hold the decode of text `t` of `src`: its span, and past it what the references to the DTD's entities
// it holds expand to, which the document's format data `ext` tells.
@(private)
decode_room :: proc "contextless" (src: []u8, t: tape.Node, ext: ^tape.Format_Ext) -> int {
	if markup.is_text_key(t) {
		return len(markup.TEXT_KEY)
	}
	dtd, read := dtd_of(ext)
	if t.spelling & SPELLING_DTD == 0 || !read {
		return int(t.n)
	}
	return int(min(expansion_room(dtd, src, src[t.lo:][:t.n]), u64(max(int))))
}

// The tables of the DTD of the text `src` that the decode of a node of no document reads, read from its prolog in
// `allocator`, nil for a text with no DTD. False when memory is refused. A text a read judged has a prolog
// the walk reads to its DTD without a fault.
@(private, cold)
prolog_ext :: proc(src: []u8, allocator: runtime.Allocator) -> (ext: ^tape.Doc_Ext, ok: bool) {
	regs: hook.Regs
	ctx := context
	w: Walk(hook.No_Hooks, false)
	walk_init(&w, {}, 0, 0)
	w.regs, w.base, w.allocator, w.ctx = &regs, raw_data(src), allocator, &ctx
	w.unread, w.expansion, w.dtd_only = true, max(u64), true
	r := prolog(&w, src, 0, 0, 0, 0, hook.no_hook)
	defer dtd_free(w.dtd)
	if u8(r) == hook.WALK_NO_MEMORY {
		return nil, false
	}
	if w.dtd == nil {
		return nil, true
	}
	ext = dtd_keep(w.dtd, raw_data(src), allocator, &ctx)
	return ext, ext != nil
}

// The DTD a document's format data `ext` holds, false for none.
@(private)
dtd_of :: #force_inline proc "contextless" (ext: ^tape.Format_Ext) -> (^Dtd_View, bool) {
	if ext == nil {
		return nil, false
	}
	m, ok := &ext.(tape.Markup_Ext)
	return &m.dtd if ok else nil, ok
}

// Whether keys `t` of `src` and `o` of `other` read as the same text. A key is an element's name as written or a text
// member's, so no key holds a reference.
@(private)
same_text :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
	return key_text(src, t) == key_text(other, o)
}

// The hash of the text key `t` of `src` reads as.
@(private)
key_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {
	return tape.text_hash(transmute([]u8)key_text(src, t))
}

// The text key `t` of `src` reads as.
@(private)
key_text :: #force_inline proc "contextless" (src: []u8, t: tape.Token) -> string {
	return markup.TEXT_KEY if markup.is_text_key(t) else string(src[t.lo:][:t.n])
}
