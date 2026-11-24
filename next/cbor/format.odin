package cbor

import "stury:lib/core/tape"

// The services of the CBOR specs beyond the node readers: the reads and records that `cbor.reads` returns to a caller
// picking the format at run time, the bytes around a token's span, and where a container closes.

// The reads of `spec`, for a caller that picks the format at run time, to use with the handle `as` returns. Nil for a
// `spec` out of range.
reads :: proc "contextless" (spec: Spec) -> ^tape.Reads {
	return tape.format_reads(Spec, ID, validate, build, find, scan, Records, records_open, records_validate, records_find, records_scan) if spec <= max(Spec) else nil
}

// The bytes of a string's head before its span, and an indefinite string's break after it. Any other scalar's span is
// its whole item.
@(private)
bounds :: proc "contextless" (src: []u8, t: tape.Token) -> (head, tail: u8) {
	if t.kind != .String && t.kind != .Bytes {
		return 0, 0
	}
	return head_of_spelling(t.spelling), u8(t.spelling & STR_INDEF != 0)
}

// The offset just past the close of container node `at` of `doc`: past its last descendant, and the break of each
// indefinite container that ends with it. False for a container other than the root of a `.Held` document, which
// holds no byte between its nodes.
@(private)
close_end :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) #no_bounds_check {
	if at == tape.ROOT {
		return doc.root_close, true
	}
	if .Held in doc.flags {
		return 0, false
	}
	last := at + tape.Node_Index(doc.nodes[at].n) - 1
	breaks: u64
	x := at
	for {
		node := doc.nodes[x]
		if node.kind < .Array {
			break
		}
		breaks += u64(node.spelling & STYLE_INDEFINITE != 0)
		if x == last {
			break
		}
		// The child whose subtree holds `last` is the last child.
		k := x + 1
		for {
			after := tape.node_after(doc, k)
			if after > last {
				break
			}
			k = after
		}
		x = k
	}
	t := doc.nodes[last]
	end := t.lo + u64(t.n)
	if t.kind > .Plain {
		end = t.lo + max(u64(HEAD_LEN[doc.src[t.lo] & 31]), 1)
	} else {
		_, tail := bounds(doc.src, t)
		end += u64(tail)
	}
	return end + breaks, true
}
