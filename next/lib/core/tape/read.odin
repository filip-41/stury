package tape

import "base:intrinsics"
import "stury:lib/base/spell"

// The readers a user calls on a scalar node, over the text the node's spans point into.

// The text of the string or plain scalar token `t` of `src`, a text of format `f`, as a `find` answer's node or a
// record's key: its bytes in the text when it holds no escape, else decoded into `buf`. False for a token of another
// kind, or a `buf` shorter than `text_room` gives.
@(require_results)
node_text_of :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Node, buf: []u8) -> (s: string, ok: bool) #no_bounds_check {
	if t.kind != .String && t.kind != .Plain {
		return "", false
	}
	if t.spelling & SPELLING_DECODE == 0 {
		return string(src[t.lo:][:t.n]), true
	}
	return f.decode(src, t, buf)
}

// `node_text_of` for node `at` of `doc`, false for `NO_NODE`.
@(require_results)
node_text_in :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index, buf: []u8) -> (s: string, ok: bool) {
	src, t := node_src_at(doc, at) or_return
	return node_text_of(doc.format, src, t, buf)
}

// The text of a string or plain node, of a document or of a format and the text the node was read in.
node_text :: proc {
	node_text_of,
	node_text_in,
}

// The bytes a format's readers read node `at` of `doc` in, and the node placed in them, false for `NO_NODE`.
@(private, require_results)
node_src_at :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> ([]u8, Token, bool) #no_bounds_check {
	if at == NO_NODE {
		return nil, {}, false
	}
	src, t := node_src(doc, doc.nodes[at])
	return src, t, true
}

// The bytes a format's readers read token `t` of `doc` in, and `t` placed in them: `doc.src` and `t`, or under `.Held`
// the bytes the read copied `t`'s span to. The flag is the document's rather than each node's, so no node gives up a
// spelling bit for it.
@(private, require_results)
node_src :: #force_inline proc "contextless" (doc: ^Document, t: Token) -> ([]u8, Token) {
	if .Held in doc.flags {
		return held_src(doc, t)
	}
	return doc.src, t
}

@(private, cold)
held_src :: #force_no_inline proc "contextless" (doc: ^Document, t: Token) -> ([]u8, Token) #no_bounds_check {
	held := doc.partial.held
	lo, hi := 0, len(held)
	for lo < hi {
		mid := (lo + hi) / 2
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
@(require_results)
span_bytes :: proc "contextless" (doc: ^Document, lo: u64, n: u32) -> []u8 {
	src, at := node_src(doc, {lo = lo, n = n})
	return src[at.lo:][:n]
}

// The value of the number token `t` of `src`, a text of format `f`, false for a token that is no number.
@(require_results)
node_number_of :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Node) -> (spell.Number, bool) {
	if t.kind != .Number {
		return {}, false
	}
	return f.number(src, t), true
}

// `node_number_of` for node `at` of `doc`, false for `NO_NODE`.
@(require_results)
node_number_in :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> (n: spell.Number, ok: bool) {
	src, t := node_src_at(doc, at) or_return
	return node_number_of(doc.format, src, t)
}

// The value of a number node, of a document or of a format and the text the node was read in.
node_number :: proc {
	node_number_of,
	node_number_in,
}

// The bytes of a buffer that always hold the text `node_text` gives for scalar token `t` of `src`, a text of format
// `f`, 0 for a scalar that reads as its bytes in the text.
@(require_results)
text_room_of :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Node) -> int {
	if t.kind > .Plain || !text_decodes(t) {
		return 0
	}
	return f.room(src, t)
}

// `text_room_of` for node `at` of `doc`, 0 for `NO_NODE`.
@(require_results)
text_room_in :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> int {
	src, t, ok := node_src_at(doc, at)
	return text_room_of(doc.format, src, t) if ok else 0
}

// The bytes a buffer needs for `node_text`, of a document or of a format and the text the node was read in.
text_room :: proc {
	text_room_of,
	text_room_in,
}

// The bytes of scalar token `t` as written in `src`, and whether they hold an escape, so that its text is a decode of
// them.
@(require_results)
key_raw_of :: #force_inline proc "contextless" (src: []u8, t: Node) -> (span: []u8, escaped: bool) {
	return src[t.lo:][:t.n], t.spelling & SPELLING_DECODE != 0
}

// `key_raw_of` for node `at` of `doc`, nil for `NO_NODE`.
@(require_results)
key_raw_in :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> (span: []u8, escaped: bool) {
	src, t, ok := node_src_at(doc, at)
	if !ok {
		return nil, false
	}
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
