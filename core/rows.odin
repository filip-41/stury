package core

// The row tree: one 32-byte row per value in preorder, spans into a text. A plain row's token is read by core:
// a string or key is its span inside its quotes, or the whole span when `.Bare` (`.Key_Bare`), a number is a
// decimal token `-?d+(.d+)?([eE][+-]?d+)?` whose digit counts are in `first_esc` (`number_digits_pack`). Any
// other token is flagged and read through the document's spelling (`Row_Spelling`).

// The digit pack of a number row whose token is spelled the format's own way (hex, `.5`, `+1`, `Infinity`): no
// decimal token packs zero integer digits, so a reader tests for it only where the counts do not settle the value.
SPELLED_NUMBER :: u16(0xFF00)

// An escaped string row's decoded text: `values[off:][:len]` of the store the walk decodes into (a
// `Document`'s `values`). Offsets rather than a slice keep the row at 32 bytes. Both fit u32 because the
// decoded bytes never outnumber the source's (`MAX_ROW_SOURCE`).
Row_Str :: struct {
	off, len: u32,
}

// An escaped key a decoded document's build decoded: member `node`'s key text, `values[str.off:][:str.len]`.
Key_Text :: struct {
	node: Node,
	str:  Row_Str,
}

// An escaped string's decoded value, under `.Decoded`. An escape-free string has none: its
// text is its source text. A number has none either: each read decodes its source
// text, which the walk only checks, since folding and converting every number slows a document build on
// number-heavy input.
Row_Payload :: struct #raw_union {
	str: Row_Str,
}

// A row's facts in one `u8`: decode state, escape presence and quoting. The values are fixed: renumbering the
// escape bits changes the walks' code generation for the worse.
Row_Flag :: enum u8 {
	// The walk validated and decoded this value: `payload.str` is an escaped string's text (`Row_Str`).
	// Never on a number.
	Decoded     = 0,
	// A string token that is not `.Str_Escaped` is its whole span, `src[lo:hi]`; without the flag it is its text
	// between one opening and one closing byte, `src[lo + 1:hi - 1]`, so a quoted format writes no flag.
	Bare        = 1,
	// The member key's `.Bare`, over `key_lo`/`key_hi`.
	Key_Bare    = 2,
	// The member key's token is spelled the format's own way (a backslash, another quote, none): the
	// document's spelling decodes it.
	Key_Escaped = 5,
	// The value token is a string spelled the format's own way, which the document's spelling decodes.
	Str_Escaped = 6,
}

Row_Flags :: distinct bit_set[Row_Flag; u8]

// The root value.
ROOT :: Node(0)

// One row per value, in preorder: the value's spans, payload and topology. 32 bytes
// with no padding (a padded `---` local is zeroed whole).
Row :: struct {
	// The value token's span in `src`, `[lo, hi)`. u32: see `MAX_ROW_SOURCE`.
	lo, hi: u32,
	// The quoted member key that introduced this value, or `NO_KEY`.
	key_lo, key_hi: u32,
	// Rows this value's subtree occupies, this row included, so the run is
	// `[i, i + subtree_size)`.
	subtree_size: u32,
	kind:         Kind,
	flags:        Row_Flags,
	// A string's first backslash as an offset from `lo`, or a number's digit counts, or `SPELLED_NUMBER`.
	first_esc:    u16,
	// The last word is a scalar's payload or a container's member count: only a
	// scalar is decoded, and only a container has members.
	using _: struct #raw_union {
		// The value's payload, or nothing. See `Row_Payload`.
		payload: Row_Payload,
		// Object members, or array elements. Meaningful on an `.Object` or `.Array`
		// row only: on a scalar these bytes are the payload's.
		cnt:     u32,
	},
}

#assert(offset_of(Row, lo) == 0)
#assert(offset_of(Row, hi) == 4)
#assert(offset_of(Row, key_lo) == 8)
#assert(offset_of(Row, key_hi) == 12)
#assert(offset_of(Row, subtree_size) == 16)
#assert(offset_of(Row, kind) == 20)
#assert(offset_of(Row, flags) == 21)
#assert(offset_of(Row, first_esc) == 22)
#assert(offset_of(Row, payload) == 24)
#assert(offset_of(Row, cnt) == 24)
#assert(size_of(Row) == 32)
#assert(size_of(Row_Payload) == 8)
#assert(size_of(Row_Flags) == 1)

// Offsets are u32, so a document of a larger source is refused rather than
// truncated. Just under u32 all-ones, so no real offset equals `NO_KEY`. It bounds
// `Row_Str` too: a document's decoded string bytes never outnumber its source's.
MAX_ROW_SOURCE :: u64(0xFFFF_FFFE)
#assert(MAX_ROW_SOURCE < u64(NO_KEY))

// The `key_lo`/`key_hi` pair for a node with no member key: the row's u32
// all-ones, which `MAX_ROW_SOURCE` keeps any real offset from reaching.
NO_KEY :: u32(0xFFFF_FFFF)

// Where a fact sits relative to the value it is attached to.
//
//	.Lead    on the lines before the entry (its key, or the value of an element), after the previous entry's
//	         line. The document's leading comments lead the root
//	.Inline  inside a member, between its key and its value
//	.Trail   after the entry on its own line: after its value, its comma, or an earlier trailing comment.
//	         The document's trailing comments trail the root
//	.Foot    inside a container, after its last entry's line and before its close
Fact_Place :: enum u8 {
	Lead,
	Inline,
	Trail,
	Foot,
}

// A fact's span in the source and the value it is attached to. A comment's span includes its markers and
// excludes the line break (CR, LF or CRLF) ending a line comment. A document keeps its facts sorted by
// node, then place, then source order. One that validation found is attached to nothing: `node` is
// `NO_NODE` and `place` `.Lead`.
Fact :: struct {
	lo, hi: u64,
	node:   Node,
	place:  Fact_Place,
}

// Tape navigation. The tape is preorder: a value's run is `[i, i + subtree_size)`
// (a scalar's size is 1), its first member is `i + 1` and each next is
// `j + subtree_size(j)`.
//
// On a tape missing rows (a refused append), every accessor stays inside one container's run and
// answers `NO_NODE` past it. A value whose parent has no row reads back as a root.

dom_has :: #force_inline proc(nodes: []Row, n: Node) -> bool {
	return n >= 0 && int(n) < len(nodes)
}

// The first member of `container` in document order, or `NO_NODE`.
dom_first_member :: proc(nodes: []Row, container: Node) -> Node {
	if !dom_has(nodes, container) {
		return NO_NODE
	}
	c := nodes[container]
	if (c.kind != .Object && c.kind != .Array) || c.subtree_size <= 1 {
		return NO_NODE
	}
	return container + 1
}

// An array of all-scalar members: `subtree_size == cnt + 1`, so member `n` is `container + 1 + n`.
dom_flat_array :: #force_inline proc(c: Row) -> bool {
	return c.kind == .Array && int(c.subtree_size) == int(c.cnt) + 1
}

// The `n`th member of `container` in document order, 0-based, or `NO_NODE`: an add over a
// `dom_flat_array`, a walk over anything else.
dom_nth_member :: #force_inline proc(nodes: []Row, container: Node, n: int) -> Node {
	if n < 0 || !dom_has(nodes, container) {
		return NO_NODE
	}
	// On a scalar `cnt` is payload bytes. A miss there is the walk's, from no first member.
	c := nodes[container]
	if n >= int(c.cnt) {
		return NO_NODE
	}
	if dom_flat_array(c) {
		return container + 1 + Node(n)
	}
	return dom_nth_walk(nodes, container, n)
}

@(private = "file")
dom_nth_walk :: proc(nodes: []Row, container: Node, n: int) -> Node {
	j := dom_first_member(nodes, container)
	for _ in 0 ..< n {
		if j < 0 {
			return NO_NODE
		}
		j = dom_next_member(nodes, container, j)
	}
	return j
}

// The member of `container` after `i`, in document order, or `NO_NODE`. On a
// tape missing rows that is the next rowed member, while `cnt` still counts every
// member the walk saw.
dom_next_member :: proc(nodes: []Row, container, i: Node) -> Node {
	if !dom_has(nodes, container) || !dom_has(nodes, i) {
		return NO_NODE
	}
	nx := i + Node(nodes[i].subtree_size)
	if nx < container + Node(nodes[container].subtree_size) {
		return nx
	}
	return NO_NODE
}

// `i`'s direct members, object pairs or array elements. Zero on a scalar.
dom_child_count :: proc(nodes: []Row, i: Node) -> int {
	if !dom_has(nodes, i) {
		return 0
	}
	n := nodes[i]
	if n.kind != .Object && n.kind != .Array {
		return 0
	}
	return int(n.cnt)
}
