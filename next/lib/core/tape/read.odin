package tape

import "base:intrinsics"
import "stury:lib/base/spell"

// The readers a user calls on a scalar node, over the text the node's spans point into.

// The text of the string or plain scalar node `t` of `src`, a text of format `f`: its bytes in the text when it holds
// no escape, else decoded into `buf`. False for a node of another kind, or a `buf` shorter than `text_room` gives.
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

// `node_text_of` for a node of a document.
@(require_results)
node_text_in :: #force_inline proc "contextless" (doc: ^Document, t: Node, buf: []u8) -> (string, bool) {
	src, at := node_src(doc, t)
	return node_text_of(doc.format, src, at, buf)
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

// The text of a string or plain node, from a document or from a format and the text the node was read in, as a `find`
// answer's.
node_text :: proc {
	node_text_of,
	node_text_in,
}

// The value of the number node `t` of `src`, a text of format `f`, false for a node that is no number.
@(require_results)
node_number_of :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Node) -> (spell.Number, bool) {
	if t.kind != .Number {
		return {}, false
	}
	return f.number(src, t), true
}

// `node_number_of` for a node of a document.
@(require_results)
node_number_in :: #force_inline proc "contextless" (doc: ^Document, t: Node) -> (spell.Number, bool) {
	src, at := node_src(doc, t)
	return node_number_of(doc.format, src, at)
}

// The value of a number node, from a document or from a format and the text the node was read in.
node_number :: proc {
	node_number_of,
	node_number_in,
}

// The bytes of a buffer that always hold the text `node_text` gives for scalar `t` of `src`, a text of format `f`, 0
// for a scalar that reads as its bytes in the text.
@(require_results)
text_room :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Node) -> int {
	if t.kind > .Plain || !text_decodes(t) {
		return 0
	}
	return f.room(src, t)
}

// The bytes of scalar `t` as written in `src`, and whether they hold an escape, so that its text is a decode of them.
@(require_results)
key_raw :: #force_inline proc "contextless" (src: []u8, t: Node) -> (span: []u8, escaped: bool) {
	return src[t.lo:][:t.n], t.spelling & SPELLING_DECODE != 0
}

// How a number token is written, from its spelling: its integer and fraction digits, each saturated at 31, whether it
// has an exponent or a point with no digit after it, and the format's number kind, 0 for its plain decimal.
Number_Form :: struct {
	int_digits, frac_digits: u8,
	exponent, point:         bool,
	kind:                    u8,
}

// How number node `t` is written, false for a node that is no number.
@(require_results)
number_form :: #force_inline proc "contextless" (t: Node) -> (Number_Form, bool) {
	if t.kind != .Number {
		return {}, false
	}
	i, f := number_digits(t.spelling)
	return {u8(i), u8(f), t.spelling & NUMBER_EXP != 0, t.spelling & NUMBER_POINT != 0, u8(t.spelling & NUMBER_KIND)}, true
}

// The integer number node `t` of `src`, a text of format `f`, holds as `i64` or else `u64`, false for a value that fits
// neither, a fraction, and a node that is no number.
@(require_results)
number_exact :: proc "contextless" (f: ^Format, src: []u8, t: Node) -> (i: i64, u: u64, unsigned, ok: bool) {
	n := node_number_of(f, src, t) or_return
	#partial switch n.kind {
	case .Int:
		return i64(n.bits), 0, false, true
	case .Uint:
		return 0, n.bits, true, true
	}
	return
}

// Whether the text of string or plain node `t` of `src`, a text of format `f`, is all ASCII, decoding it into `buf`
// when it holds an escape, as `node_text` does. False for `ok` as `node_text` gives it.
@(require_results)
text_is_ascii :: proc "contextless" (f: ^Format, src: []u8, t: Node, buf: []u8) -> (ascii, ok: bool) #no_bounds_check {
	s := node_text_of(f, src, t, buf) or_return
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
