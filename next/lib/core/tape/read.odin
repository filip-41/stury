package tape

import "stury:lib/base/spell"

// The readers a user calls on a scalar node, over the text the node's spans point into.

// The text of the string node `t` of `src`, a text of format `f`: its bytes in the text when it holds no escape, else
// decoded into `buf`. False for a node that is no string, or a `buf` shorter than the node's span.
@(require_results)
node_text_of :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Node, buf: []u8) -> (s: string, ok: bool) #no_bounds_check {
	if t.kind != .String {
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
	return node_text_of(doc.format, doc.src, t, buf)
}

// The text of a string node, from a document or from a format and the text the node was read in, as a `find` answer's.
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
	return node_number_of(doc.format, doc.src, t)
}

// The value of a number node, from a document or from a format and the text the node was read in.
node_number :: proc {
	node_number_of,
	node_number_in,
}
