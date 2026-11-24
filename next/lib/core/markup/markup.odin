package markup

import "base:runtime"
import "stury:lib/core/tape"

// The document shape every markup format builds, which XML's walk and HTML's tree construction give as tokens and the
// readers here read. The document is an `Object` of its root elements. An element is a member under its name, a key
// as written: its value is its text, a `String` or a `Null` for none, or an `Object` of its child elements and of the
// `#text` runs of text between them, in document order. Its attributes are `Attribute` facts of its value, each
// spanning its name through its value, and comments, instructions and declarations are facts too. A name an element's
// children repeat reads as an array of each in document order, as the format's `Duplicates.Group` gives it.

// The name of the member that holds the text between an element's children. No element of a markup format can have
// it, since `#` starts no name.
TEXT_KEY :: "#text"

// In a key's spelling, beside `SPELLING_DECODE`, the key is a `#text` member's, which spans no byte of the text. Bit 11
// is the first a format owns, and every markup format gives it this meaning.
SPELLING_TEXT_KEY :: u16(1 << 11)

// Whether key `t` is a `#text` member's.
is_text_key :: #force_inline proc "contextless" (t: tape.Token) -> bool {
	return t.role == .Key && t.spelling & SPELLING_TEXT_KEY != 0
}

// The `spelling` of a fact whose span starts with `lead` bytes of markup before its body and ends with `tail` bytes
// after it, as a comment's `<!--` and `-->`.
fact_spelling :: #force_inline proc "contextless" (lead, tail: u8) -> u16 {
	return u16(lead) | u16(tail) << 8
}

// The bytes of markup a fact's span starts with before its body, as `fact_spelling` holds them.
fact_lead :: #force_inline proc "contextless" (spelling: u16) -> u64 {
	return u64(spelling & 0xFF)
}

// The longest lead an attribute fact's spelling holds. A fact whose value starts further in has this lead, and its
// format finds the value from the name.
ATTRIBUTE_LEAD_MAX :: 255

// The spelling of an attribute fact whose value starts `lead` bytes past its name's first byte, saturated at
// `ATTRIBUTE_LEAD_MAX`, with the closing quote as the tail when the value is `quoted`. Bits 9 to 15 are the format's.
attribute_spelling :: #force_inline proc "contextless" (lead: int, quoted: bool) -> u16 {
	return fact_spelling(u8(min(lead, ATTRIBUTE_LEAD_MAX)), 1 if quoted else 0)
}

// The string value of the element whose value is node `at` of `doc`: the text of each of the strings in its subtree,
// in document order, made in `allocator`. Empty for a null, and false only when memory is refused.
content :: proc(doc: ^tape.Document, at: tape.Node_Index, allocator: runtime.Allocator) -> (text: string, ok: bool) {
	if at == tape.NO_NODE {
		return "", true
	}
	node := doc.nodes[at]
	end := at + 1
	if node.kind == .Object {
		end = at + tape.Node_Index(node.n)
	}
	size := 0
	for j in at ..< end {
		if t := doc.nodes[j]; t.role == .Value && t.kind != .Null && t.kind <= .Plain {
			size += max(tape.text_room(doc, j), int(t.n)) if t.kind >= .Bytes else int(t.n)
		}
	}
	buf, err := make([]u8, size, allocator)
	if err != nil {
		return "", false
	}
	w := 0
	for j in at ..< end {
		t := doc.nodes[j]
		if t.role != .Value || t.kind == .Null || t.kind > .Plain {
			continue
		}
		// A text an inferring read took as a number or a boolean needs no decode, and reads as its bytes.
		s, _ := tape.node_text(doc, j, buf[w:])
		if t.kind < .Bytes {
			s = string(tape.span_bytes(doc, t.lo, t.n))
		}
		w += copy(buf[w:], s)
	}
	return string(buf[:w]), true
}
