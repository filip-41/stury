package core

// The types shared by every format's walk: tokens, the hook interface and the fault result.

// The deepest nesting a walk reads unless its options say more. An open bracket past the limit faults `Too_Deep` at that
// bracket.
MAX_DEPTH :: 1024

// The deepest a text of `n` bytes or nodes can nest under the limit `max_depth` (0 for `MAX_DEPTH`), never less than
// `MAX_DEPTH`, which bounds the nodes a build reserves. Every stack a walk or a replay keeps, a byte, a word or a frame a
// level, starts at no more than `MAX_DEPTH` levels and grows with the nesting the text reaches.
reserve_depth :: #force_inline proc "contextless" (max_depth: u32, n: int) -> int {
	depth := max(MAX_DEPTH, int(max_depth))
	return depth if n >= depth else min(depth, n + 16)
}

// `Kind` names what a token is: `Array` and `Object` open a container, `End` closes the innermost one, and the other
// kinds are scalars. `Plain` is text whose type the format resolves for the consumer. Each member names the formats
// that give it.
Kind :: enum u8 {
	Null, // json
	False, // json
	True, // json
	Number, // json
	String, // json
	Plain, // json: a comment, dsv: every cell and a comment line
	Array, // json: `[`, dsv: the document, and a record with no header
	Object, // json: `{`, dsv: a record with a header
	End, // json: `]` and `}`, dsv: a record's line end (`n` 1 or 2, 0 at the text's end) and the text's end (`n` 0)
}

// `Role` says what a token is in its container. A `Key` is a member's name in JSON and a header cell in dsv, so its
// `kind` depends on the format. Past `Key` a token is a fact: data a value carries that is not its value and does not
// change its meaning. A comment's role and node follow its position, by the same rule in every format. On the line
// where the previous value ends it is that value's `Comment_Inline`. Before a value the grammar allows it above, it is
// that value's `Comment`. Any other comment is a `Comment_Foot` of the innermost open container, or of the root at
// depth 0. `Tag`, `Anchor` and `Alias` are node properties. Each is a fact span that stands just before the node it
// belongs to, on the node's line, and the span's lead marker length says how much of it is a marker. An `Attribute` is
// a markup element's attribute, a fact of the element's value node, which a walk gives after the element's key and
// before its value. A consumer that wants values only tests `t.role <= .Key`. `Partial` is no token's role: a read by
// paths writes it on a container it kept only some children of.
Role :: enum u8 {
	Value, // json, dsv
	Key, // json: a member's name, always a `String`, in JSON5 quoted or not, dsv: the header cell of a cell's column
	Comment, // json (JSONC, JSON5), dsv: a comment before the value that follows it, `Plain`
	Comment_Inline, // json (JSONC, JSON5): a comment on the line where the value before it ends, `Plain`
	Comment_Foot, // json, dsv: after the last value or in an empty container, on the innermost open container
	// or the root at depth 0, `Plain`
	Tag, // the type tag of the node that follows, `Plain`
	Anchor, // the name the node that follows is given for aliases to read, `Plain`
	Alias, // the node that follows is a copy of a named anchor's node, `Plain`
	Attribute, // markup: an element's attribute, `name="value"` through the closing quote, `spelling` as `Fact` says
	Partial, // a document's container whose children were not all kept, in place of `Value`
}

// A token the walk passes to a hook. Tokens come in the order the walk reads them, text order except for a dsv `Key`,
// whose span is its column's header cell, before the record that names it. `lo` is the first byte and `n` the length,
// 0 where the format writes nothing. A token longer than `n` can hold is the fault `Too_Wide`. `spelling` is the
// format's detail. Core reads bits 0 to 2 of a value or key and a comment's marker lengths, and the rest is the
// format's own. json sets bit 0 for a string or key that needs decoding, bit 1 when it is quoted, bit 2 for a
// tolerated ill-formed sequence, and a number's packed shape. dsv sets bit 0 for a cell that needs decoding, bit 1 for
// a quoted CSV cell, bits 0 and 2 for a tolerated ill-formed sequence, bit 15 for a quoted cell holding a `""` on a walk
// for `Cells` or `Batch`, and bit 14 for the key of a column past the header's last cell.
Token :: struct {
	lo:       u64,
	n:        u32,
	kind:     Kind,
	role:     Role,
	spelling: u16,
}

// 16 bytes with no padding, so a Token is passed in two registers.
#assert(size_of(Token) == 16)

// The action a hook returns to the walk. `Skip` on an `Array` or `Object`, or on a `Key` for its member's value, passes
// that value with no more tokens, its `End` included, and on a `Key` also the comments before the value, while the
// walk still judges their bytes. The comments after the value are still given. On a scalar value `Skip` acts as
// `Next`. `Keep` on an `Array` or `Object` is `Next` and says the hook wants every token up to its `End` written as they are,
// which a walk may do by the builder's plain hook, past this hook. `Stop` ends the walk at once with no fault, with the
// rest of the text unjudged.
Action :: enum u8 {
	Next,
	Skip,
	Keep,
	Stop,
}

// Three `u64` words of hook state passed in the walk's argument registers. A hook receives them and returns them
// with its `Action`, so a cursor or count kept here needs no load or store. On arm64 all three fit beside the walk's
// five arguments in registers, while on x86-64 SysV two words spill to the stack under contextless calling.
// Anything a pointer reaches stays in the hook's state.
Hook_Regs :: struct {
	a, b, c: u64,
}

// The key a hook expects next, the first member of the records `Hook_Regs.b` walks through when the hook has a field
// `expect` of a pointer to such a record. `word` holds the first 16 of the key's bytes as written, open quote through
// colon, `mask` the bytes of `word` that count, `rest` those past the 16th, and `n` their number. A record no key
// matches has a mask that covers an all-zero word, since a key's first byte is a quote.
Expected_Key :: struct {
	word, mask: [2]u64,
	rest:       [^]u8,
	n:          u32,
}

// Returns `lo`, or 3 when `lo` is 0 and `src` starts with a UTF-8 byte order mark.
text_start :: proc "contextless" (src: []u8, lo: u64) -> u64 {
	if lo == 0 && len(src) >= 3 && src[0] == 0xef && src[1] == 0xbb && src[2] == 0xbf {
		return 3
	}
	return lo
}

// `Tolerance` names a rule a caller lets a text break, in a format's `Options.tolerate`. The walk does not fault where
// the text breaks it, and the value a token decodes to shows the rule's one fixed reading. A rule that a format's grammar
// has no instance of, such as `Ragged` in JSON or `Lone_Surrogate` in dsv, is never broken there, so naming it changes
// nothing, and one set can be given to every format.
Tolerance :: enum u8 {
	// Ill-formed UTF-8 in a JSON string or a dsv cell. Each maximal subpart of an ill-formed sequence reads as U+FFFD.
	Invalid_Utf8,
	// A JSON `\u` escape of a surrogate half that no other half pairs with. It reads as U+FFFD.
	Lone_Surrogate,
	// A dsv record of any width. A narrower record's missing columns are absent. With a header, a wider record's cells
	// past the header's last are columns named by their 1-based position, `"3"` for the third.
	Ragged,
	// A quote inside an unquoted CSV cell. It is a byte of the cell, and the block's quotes pair up without it.
	Bare_Quote,
}

// `Framing` says how a text holds a list of records. `Lines` is one record per line end, a row in dsv and a value per
// line in JSON (NDJSON). `Seq` puts 0x1E before each record (RFC 7464). `Concatenated` is documents one after another,
// as jq reads them. `Entries` is each element of the root array or member of the root object.
Framing :: enum u8 {
	Lines,
	Seq,
	Concatenated,
	Entries,
}
