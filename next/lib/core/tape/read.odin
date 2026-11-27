package tape

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/spell"

// The readers a user calls on a scalar node, over the text the node's spans point into.

// The text of scalar token `t` of `src`, a text of format `f`: its bytes in the text when it holds no escape, else
// decoded into `buf`. A string, plain, number or byte string token has a text, a byte string's being its payload, and
// so does a key of any kind, which a `Name` takes by its text, as a `find` answer's node or a record's key. A null or
// boolean value has none. A number's text is its exact value: as written, or in a `.Binary` format its value in
// decimal. False for a token with no text, a `buf` shorter than `text_room` gives, a number of a `.Binary` format
// whose value is past what its readers spell, and a text whose decode needs the document it was read into, as an XML
// text that refers to its DTD's entities does, which `node_text_read` reads. A read takes no memory.
@(private = "file", require_results)
node_text_of :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Node, buf: []u8) -> (s: string, ok: bool) {
	return text_of(f, src, t, buf, nil)
}

// `node_text_of` for token `t` of `src` read with the format data `ext` of the document holding it, nil for none.
// Invariant: `t`'s span `(lo, n)` lies within `src`.
@(private = "file", require_results)
text_of :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Node, buf: []u8, ext: ^Format_Ext) -> (s: string, ok: bool) #no_bounds_check {
	if t.kind > .Plain || t.kind < .Number && t.role != .Key {
		return "", false
	}
	if !needs_decode(f, t) {
		return string(src[t.lo:][:t.n]), true
	}
	return f.decode(src, t, buf, ext)
}

// Whether the text of scalar token `t` of a text of format `f` is a decode of its bytes rather than the bytes.
@(private = "file")
needs_decode :: #force_inline proc "contextless" (f: ^Format, t: Token) -> bool {
	return text_decodes(t) || t.kind == .Number && .Binary in f.caps
}

// `node_text_of` for node `at` of `doc`, false for `NO_NODE`.
// Invariant: `at` is `NO_NODE` or a valid index in `doc.nodes`.
@(private = "file", require_results)
node_text_in :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index, buf: []u8) -> (s: string, ok: bool) #no_bounds_check {
	if at == NO_NODE {
		return "", false
	}
	return node_text_token(doc, doc.nodes[at], buf)
}

#assert(u8(Kind.Plain) - u8(Kind.String) == 1)

// `node_text_of` for token `t` of the text of `doc`, a node of it or a token read from it, as an attribute's value a
// markup format reads from a fact. A string or plain text with no escape in a document that holds its text reads as
// its bytes there, and any other through its format.
// Invariant: when `.Held not_in doc.flags`, `t`'s span `(lo, n)` lies within `doc.src`.
@(private = "file", require_results)
node_text_token :: #force_inline proc "contextless" (doc: ^Document, t: Token, buf: []u8) -> (s: string, ok: bool) #no_bounds_check {
	if u8(t.kind) - u8(Kind.String) <= 1 && t.spelling & SPELLING_DECODE == 0 && .Held not_in doc.flags {
		return string(doc.src[t.lo:][:t.n]), true
	}
	return token_text_read(doc, t, buf)
}

// `node_text_token` for a token that needs its format to read it.
@(private = "file", cold)
token_text_read :: #force_no_inline proc "contextless" (doc: ^Document, t: Token, buf: []u8) -> (s: string, ok: bool) {
	src, at := node_src(doc, t)
	return text_of(doc.format, src, at, buf, format_ext(doc))
}

// The format data of `doc`, nil for none.
@(private = "file")
format_ext :: #force_inline proc "contextless" (doc: ^Document) -> ^Format_Ext {
	return &doc.ext.format if doc.ext != nil else nil
}

// The text of a scalar node or key, of a document or of a format and the text the node was read in.
node_text :: proc {
	node_text_of,
	node_text_in,
	node_text_token,
}

// The text of scalar token `t` of `src`, a text of format `f`, in a block of `allocator` that `delete` frees, as
// `node_text_of` reads it, and also when its decode needs the document it was read into, as a `find` answer's XML text
// that refers to its DTD's entities: what the decode needs is read from the text, once, in `allocator`. False for a
// token with no text and when memory is refused.
@(require_results)
node_text_read :: proc(f: ^Format, src: []u8, t: Node, allocator := context.allocator) -> (s: string, ok: bool) {
	if t.kind > .Plain || t.kind < .Number && t.role != .Key {
		return "", false
	}
	ext: ^Doc_Ext
	if f.text_ext != nil && needs_decode(f, t) {
		ext = f.text_ext(src, allocator) or_return
	}
	defer free(ext, allocator)
	format := &ext.format if ext != nil else nil
	stack: [256]u8 = ---
	need := room_of(f, src, t, format)
	buf := stack[:need] if need <= len(stack) else nil
	heap: []u8
	if need > len(stack) {
		err: runtime.Allocator_Error
		heap, err = runtime.mem_alloc_non_zeroed(need, 1, allocator)
		if err != nil || len(heap) < need {
			return "", false
		}
		buf = heap
	}
	text, read := text_of(f, src, t, buf, format)
	if !read || len(text) == 0 {
		delete(heap, allocator)
		return "", read
	}
	if heap != nil {
		if raw_data(text) != raw_data(heap) {
			copy(heap, text)
		}
		if len(text) < len(heap) {
			if shrunk, serr := runtime.mem_resize(raw_data(heap), len(heap), len(text), 1, allocator); serr == nil && len(shrunk) >= len(text) {
				heap = shrunk
			}
		}
		return string(heap[:len(text)]), true
	}
	out, err := runtime.mem_alloc_non_zeroed(len(text), 1, allocator)
	if err != nil || len(out) < len(text) {
		return "", false
	}
	copy(out, text)
	return string(out), true
}

// The bytes a format's readers read token `t` of `doc` in, and `t` placed in them: `doc.src` and `t`, or under `.Held`
// the bytes the read copied `t`'s span to. The flag is the document's rather than each node's, so no node gives up a
// spelling bit for it.
@(private, require_results)
node_src :: #force_inline proc "contextless" (doc: ^Document, t: Token) -> ([]u8, Token) {
	if intrinsics.expect(.Held in doc.flags, false) {
		return held_src(doc, t)
	}
	return doc.src, t
}

// Invariant: `0 <= mid < len(held)` throughout the loop and `1 <= lo <= len(held)` when `lo > 0`.
@(private = "file", cold)
held_src :: #force_no_inline proc "contextless" (doc: ^Document, t: Token) -> ([]u8, Token) #no_bounds_check {
	// A key named by its place holds no bytes, and its `lo` is its place, which the slice reaches with no byte to read.
	if t.kind == .String && t.spelling & SPELLING_PLACED != 0 {
		return ([^]u8)(raw_data(doc.src))[:t.lo], t
	}
	if doc.ext == nil {
		return nil, t
	}
	held := doc.ext.held
	lo, hi := 0, len(held)
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		if held[mid].lo <= t.lo {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	// A container holds no bytes, and may lie before every span.
	if lo == 0 {
		return nil, t
	}
	at := t
	at.lo = held[lo - 1].at + t.lo - held[lo - 1].lo
	return doc.src, at
}

// The `n` bytes at offset `lo` of the text of `doc`, the span of one of its nodes or facts.
// Invariant: `(lo, n)` is a valid span of a node or fact of `doc` (in `doc.src`, or held in `doc.ext.held` under `.Held`).
@(require_results)
span_bytes :: #force_inline proc "contextless" (doc: ^Document, lo: u64, n: u32) -> []u8 #no_bounds_check {
	if !intrinsics.expect(.Held in doc.flags, false) {
		return doc.src[lo:][:n]
	}
	src, at := held_src(doc, {lo = lo, n = n})
	return src[at.lo:][:n] if src != nil else nil
}

// The value of the number token `t` of `src`, a text of format `f`, false for a token that is no number.
@(private = "file", require_results)
node_number_of :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Node) -> (spell.Number, bool) {
	if t.kind != .Number {
		return {}, false
	}
	return f.number(src, t), true
}

// `node_number_of` for node `at` of `doc`, false for `NO_NODE`.
// Invariant: `at` is `NO_NODE` or a valid index in `doc.nodes`.
@(private = "file", require_results)
node_number_in :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> (n: spell.Number, ok: bool) #no_bounds_check {
	if at == NO_NODE || doc.nodes[at].kind != .Number {
		return {}, false
	}
	src, t := node_src(doc, doc.nodes[at])
	return doc.format.number(src, t), true
}

// The value of a number node, of a document or of a format and the text the node was read in.
node_number :: proc {
	node_number_of,
	node_number_in,
}

// The bytes of a buffer that always hold the text `node_text` gives for scalar token `t` of `src`, a text of format
// `f`, 0 for a scalar that reads as its bytes in the text.
@(private = "file", require_results)
text_room_of :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Node) -> int {
	return room_of(f, src, t, nil)
}

// `text_room_of` for token `t` of `src` read with the format data `ext` of the document holding it, nil for none.
// Invariant: formats leave `SPELLING_DECODE` clear on `.Null`/`.False`/`.True` values, so `needs_decode` is false on them.
@(private = "file", require_results)
room_of :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Node, ext: ^Format_Ext) -> int {
	if t.kind > .Plain || !needs_decode(f, t) {
		return 0
	}
	return f.room(src, t, ext)
}

// `text_room_of` for node `at` of `doc`, 0 for `NO_NODE`.
// Invariant: `at` is `NO_NODE` or a valid index in `doc.nodes`.
@(private = "file", require_results)
text_room_in :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> int #no_bounds_check {
	return text_room_token(doc, doc.nodes[at]) if at != NO_NODE else 0
}

// `text_room_of` for token `t` of the text of `doc` that is no node of it, as `node_text_token` reads it.
@(private = "file", require_results)
text_room_token :: #force_inline proc "contextless" (doc: ^Document, t: Token) -> int {
	if t.kind > .Plain || !needs_decode(doc.format, t) {
		return 0
	}
	src, at := node_src(doc, t)
	return doc.format.room(src, at, format_ext(doc))
}

// The bytes a buffer needs for `node_text`, of a document or of a format and the text the node was read in.
text_room :: proc {
	text_room_of,
	text_room_in,
	text_room_token,
}

// The name of the fact of kind `kind` that node `at` of `doc` holds in its spelling rather than as a span, as its
// format names it: a `.Style`, how the node is written, as a string's quotes or a number's base, or a `.Tag`, a type
// the format gives a scalar. False for a node that holds none, for a format that names none and for `NO_NODE`.
@(require_results)
fact_name :: proc "contextless" (doc: ^Document, at: Node_Index, kind: Fact_Kind) -> (name: string, ok: bool) {
	if at == NO_NODE || doc.format == nil || doc.format.fact_name == nil {
		return "", false
	}
	return doc.format.fact_name(doc, at, kind)
}

// The number of tag `fact` of `doc`, a fact of kind `.Tag`, whose span is the tag's head. False for another fact or
// a non-`.Binary` format whose tags are text rather than binary heads.
@(require_results)
fact_number :: proc "contextless" (doc: ^Document, fact: Fact) -> (spell.Number, bool) {
	if fact.kind != .Tag || fact.n == 0 || doc.format == nil || .Binary not_in doc.format.caps {
		return {}, false
	}
	src, t := node_src(doc, {lo = fact.lo, n = fact.n, kind = .Number, role = .Tag})
	return doc.format.number(src, t), true
}

// The bytes of scalar token `t` as written in `src`, and whether they hold an escape, so that its text is a decode of
// them.
@(private = "file", require_results)
key_raw_of :: #force_inline proc "contextless" (src: []u8, t: Node) -> (span: []u8, escaped: bool) {
	return src[t.lo:][:t.n], t.spelling & SPELLING_DECODE != 0
}

// `key_raw_of` for node `at` of `doc`, nil for `NO_NODE`.
// Invariant: `at` is `NO_NODE` or a valid index in `doc.nodes`.
@(private = "file", require_results)
key_raw_in :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> (span: []u8, escaped: bool) #no_bounds_check {
	if at == NO_NODE {
		return nil, false
	}
	src, t := node_src(doc, doc.nodes[at])
	return key_raw_of(src, t)
}

// A scalar's bytes as written, of a document or of the text a record's key was read in.
key_raw :: proc {
	key_raw_of,
	key_raw_in,
}

// How a number token is written, from its spelling: its integer and fraction digits, each saturated at 31, whether it
// has an exponent or a point with no digit after it, and the format's number kind, 0 for its plain decimal.
Number_Form :: struct {
	int_digits, frac_digits: u8,
	exponent, point:         bool,
	kind:                    u8,
}

// How number node `at` of `doc` is written, false for a node that is no number and for `NO_NODE`.
@(require_results)
number_form :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> (Number_Form, bool) #no_bounds_check {
	if at == NO_NODE || doc.nodes[at].kind != .Number {
		return {}, false
	}
	spelling := doc.nodes[at].spelling
	i, f := number_digits(spelling)
	return {u8(i), u8(f), spelling & NUMBER_EXP != 0, spelling & NUMBER_POINT != 0, u8(spelling & NUMBER_KIND)}, true
}

// The integer number node `at` of `doc` holds as `i64` or else `u64`, false for a value that fits neither, a fraction,
// a node that is no number and `NO_NODE`.
@(require_results)
number_exact :: proc "contextless" (doc: ^Document, at: Node_Index) -> (i: i64, u: u64, unsigned, ok: bool) {
	n := node_number_in(doc, at) or_return
	#partial switch n.kind {
	case .Int:
		return i64(n.bits), 0, false, true
	case .Uint:
		return 0, n.bits, true, true
	}
	return
}

// Whether the text of string or plain node `at` of `doc` is all ASCII, decoding it into `buf` when it holds an escape,
// as `node_text` does. False for `ok` as `node_text` gives it.
@(require_results)
text_is_ascii :: proc "contextless" (doc: ^Document, at: Node_Index, buf: []u8) -> (ascii, ok: bool) #no_bounds_check {
	s := node_text_in(doc, at, buf) or_return
	p, n := raw_data(s), len(s)
	i := 0
	for ; i + 8 <= n; i += 8 {
		if intrinsics.unaligned_load((^u64)(p[i:])) & 0x8080808080808080 != 0 {
			return false, true
		}
	}
	for ; i < n; i += 1 {
		if p[i] >= 0x80 {
			return false, true
		}
	}
	return true, true
}
