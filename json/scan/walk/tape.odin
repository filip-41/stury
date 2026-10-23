package walk

// What a JSON value is. One enum for every carrier (`.Nodes` rows, path answers,
// demand spans): a container is the two kinds whose `lo`/`hi` bracket children. Declaration order carries no meaning: nothing indexes by it or orders on it.
Kind :: enum u8 {
	Null,
	False,
	True,
	Number,
	String,
	Array,
	Object,
}

// An escaped string row's decoded text: `values[off:][:len]` of the store the `.Dom`
// walk decodes into (`Scan_Query_Sink.value_bytes`, a `Document`'s `values`).
// Offsets rather than a slice keep the row at 32 bytes. Both fit u32 because the
// decoded bytes never outnumber the source's (`TAPE_MAX_SOURCE`).
Row_Str :: struct {
	off, len: u32,
}

// An escaped string's decoded value, under `.Decoded`. An escape-free string has none: its
// text is its source text, `src[lo + 1:hi - 1]`. A number has none either: each read decodes its source
// text (`dom_number`), which the walk only checks, as folding and converting every number cost a `.Dom`
// build a quarter of its time on number-heavy input.
Row_Payload :: struct #raw_union {
	str: Row_Str,
}

// A row's facts in one `u8`: decode state and escape presence.
//
// `.Exact`/`.Inexact`/`.Underflowed`/`.Refused` are never on a row: they are the number decoder's answer
// (`dom_number_value`), which a reader turns into an `Exactness`.
Row_Flag :: enum u8 {
	// The walk validated and decoded this value: `payload.str` is an escaped string's text (`Row_Str`).
	// Never on a number.
	Decoded,
	// The decoded binary64 is the authored value, bit for bit.
	Exact,
	// The decoded binary64 is the correctly rounded projection. The span is the value.
	Inexact,
	// The authored value is nonzero and the projection is zero.
	Underflowed,
	// Valid grammar, no binary64 value (`1e400`).
	Refused,
	// The member key's source text carried at least one backslash.
	Key_Escaped,
	// The value token's source text carried one.
	Str_Escaped,
}

// The flags on a `.Nodes` row (`Row.flags`).
Row_Flags :: distinct bit_set[Row_Flag; u8]

// A handle to one value of a document: the index of its row. Distinct, so a count or an offset is never
// passed where a value is meant.
Node :: distinct i32

// "No such value": what every lookup answers on a miss, and `Path_Answer.node` without a row.
NO_NODE :: Node(-1)

// The root value, the first row.
ROOT :: Node(0)

// One row per value, in preorder: the value's spans, payload and topology. 32 bytes
// with no padding (a padded `---` local is zeroed whole).
Row :: struct {
	// The value token's span in `src`, `[lo, hi)`. u32: see `TAPE_MAX_SOURCE`.
	lo, hi: u32,
	// The quoted member key that introduced this value, or `NO_KEY`.
	key_lo, key_hi: u32,
	// Rows this value's subtree occupies, this row included, so the run is
	// `[i, i + subtree_size)`.
	subtree_size: u32,
	kind:         Kind,
	flags:        Row_Flags,
	// A string's escape latch (`first_escape_offset`), or a number's digit counts (`number_digits`).
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

// Offsets are u32, so a `.Nodes` scan of a larger source is refused rather than
// truncated. Just under u32 all-ones, so no real offset equals `NO_KEY`. It bounds
// `Row_Str` too: a document's decoded string bytes never outnumber its source's.
TAPE_MAX_SOURCE :: u64(0xFFFF_FFFE)
#assert(TAPE_MAX_SOURCE < u64(NO_KEY))

// The escape latch's ceiling: an offset equal to it is only a lower bound.
FIRST_ESC_SATURATED :: u16(0xFFFF)

// Whether this value token's source text carried an escape. Meaningful only for
// `.String` rows. False on every other kind.
str_escaped :: proc(r: Row) -> bool {
	return .Str_Escaped in r.flags
}

// Where the first backslash in a string value's source text sits, as a byte offset
// from the row's `lo` (the opening quote), and whether it is known.
//
// The offset includes the quote, so the clean head is `src[lo+1:lo+off]`, not
// `lo+1+off`, which would copy the backslash. `known` is false for an escape-free
// string and for every non-`.String` row.
//
// The latch holds `min(off, FIRST_ESC_SATURATED)`: an offset equal to the cap is a
// lower bound. The clean-head range stays valid either way, but a decoder must then
// look for the backslash at or past `lo+off`.
first_escape_offset :: proc(r: Row) -> (offset: u64, known: bool) {
	if r.kind != .String || !(.Str_Escaped in r.flags) {
		return 0, false
	}
	return u64(r.first_esc), true
}

// A number token's digit counts as its row holds them in `first_esc`, which a number has no use for: the
// integer run's in the low byte, the fraction run's in the high one, each capped at 255. The walk counts both
// to check the digit cap, so a reader learns where the runs end without looking for the `.` and the `e`.
number_digits_pack :: #force_inline proc(int_digits, frac_digits: u64) -> u16 {
	return u16(min(int_digits, 255)) | u16(min(frac_digits, 255)) << 8
}

// The digit counts of number row `r` (`number_digits_pack`). A checked token has an integer digit, so
// `int_digits == 0` is a row no walk counted. 255 is a lower bound.
number_digits :: #force_inline proc(r: Row) -> (int_digits, frac_digits: u64) {
	return u64(r.first_esc & 0xFF), u64(r.first_esc >> 8)
}

Number_Spelling_Flag :: enum u8 {
	Negative,     // token began '-'
	Has_Exponent, // authored 'e'/'E'
	Has_Fraction, // authored '.'
}

// These co-occur (`-1.5e2` has all three), so a token carries them as a flag set.
Number_Spelling :: bit_set[Number_Spelling_Flag; u8]

// The `key_lo`/`key_hi` pair for a node with no member key: the row's u32
// all-ones, which `TAPE_MAX_SOURCE` keeps any real offset from reaching.
NO_KEY :: u32(0xFFFF_FFFF)

// "No key" in the walk's u64 latch (`Query_Ctx.node_key_lo`). `emit_node`'s
// u32 cast turns it into `NO_KEY`, which the assertion pins.
NO_KEY_LATCH :: u64(0xFFFF_FFFF_FFFF_FFFF)
#assert(NO_KEY_LATCH & 0xFFFF_FFFF == u64(NO_KEY))

// "No row", in the width a row index is stored in: `Open_Frame.row` holds it when
// `edge_push` dropped the row on a failed grow. It is never a real row index.
NO_ROW :: u32(0xFFFF_FFFF)

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

// Whether `n` names a row of `nodes`.
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

// The last member of object `i` whose key decodes to `name`, or `NO_NODE`.
// An array has no keys and answers none.
//
// Last match is JSON object semantics, the same reading as a path's default
// `.Last`. A member with no row is not found.
dom_find_key :: proc(nodes: []Row, src: []byte, i: Node, name: string, hooks: ^Format_Hooks) -> Node {
	if !dom_has(nodes, i) || nodes[i].kind != .Object {
		return NO_NODE
	}
	found := NO_NODE
	end := i + Node(nodes[i].subtree_size)
	j := dom_first_member(nodes, i)
	for _ in 0 ..< nodes[i].cnt {
		if !dom_has(nodes, j) {
			return NO_NODE
		}
		r := nodes[j]
		if r.key_lo != NO_KEY && key_equals_hooked(hooks, src, u64(r.key_lo), u64(r.key_hi), .Key_Escaped in r.flags, name) {
			found = j
		}
		// `dom_next_member`, with the container's end loaded once.
		j += Node(r.subtree_size)
		if j >= end {
			j = NO_NODE
		}
	}
	return found
}
