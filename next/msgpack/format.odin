package msgpack

import "stury:lib/core/tape"

// MessagePack format helpers beyond node readers: `reads`, token `bounds`, container `close_end`, and `fact_name`.

// Returns the `tape.Reads` dispatch table for `spec`, or nil when out of range.
reads :: proc "contextless" (spec: Spec) -> ^tape.Reads {
	return tape.format_reads(Spec, ID, validate, build, find, scan, Records, records_open, records_validate, records_find, records_scan) if spec <= max(Spec) else nil
}

// Returns `(head, tail)` authored bytes around scalar token `t`'s payload (`ext` heads are covered too).
@(private)
bounds :: proc "contextless" (src: []u8, t: tape.Token) -> (head, tail: u8) {
	_ = src
	if t.kind != .String && t.kind != .Bytes {
		return 0, 0
	}
	return head_of_spelling(t.spelling), 0
}

// Returns the byte offset just past container node `at` of `doc`, or false when `at` is non-root in a `.Held` document.
@(private)
close_end :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) #no_bounds_check {
	if at == tape.ROOT {
		return doc.root_close, true
	}
	if .Held in doc.flags {
		return 0, false
	}
	last := at + tape.Node_Index(doc.nodes[at].n) - 1
	t := doc.nodes[last]
	if t.kind > .Plain {
		return t.lo + u64(container_head_len(doc.src[t.lo])), true
	}
	return t.lo + u64(t.n), true
}

// Returns `"datetime"` for MessagePack Timestamp (`ext -1`) `.String` nodes.
@(private)
spelled_fact :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index, kind: tape.Fact_Kind) -> (string, bool) {
	if kind == .Tag && doc.nodes[at].spelling & STR_TIMESTAMP != 0 {
		return "datetime", true
	}
	return "", false
}
