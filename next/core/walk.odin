package core

// The types shared by every format's walk: tokens, the hook interface and the fault result.

// `Kind` names what a token is: `Array` and `Map` open a container, `End` closes the innermost one, and the other
// kinds are scalars. `Plain` is text whose type the format resolves for the consumer. Each member names the formats
// that give it.
Kind :: enum u8 {
	Null, // json
	False, // json
	True, // json
	Number, // json
	String, // json
	Plain, // dsv: every cell
	Array, // json: `[`, dsv: the document, and a record with no header
	Map, // json: `{`, dsv: a record with a header
	End, // json: `]` and `}`, dsv: a record's line end (`n` 1 or 2, 0 at the text's end) and the text's end (`n` 0)
}

// `Role` says what a token is in its container. A `Key` is a member's name in JSON and a header cell in dsv, so its
// `kind` depends on the format. Past `Key` a token is a fact: data a value carries that is not its value and does not
// change its meaning. A comment's role and node follow its position, by the same rule in every format. On the line
// where the previous value ends it is that value's `Comment_Inline`. Before a value the grammar allows it above, it is
// that value's `Comment`. Any other comment is a `Comment_Foot` of the innermost open container, or of the root at
// depth 0. A consumer that wants values only tests `t.role <= .Key`.
Role :: enum u8 {
	Value, // json, dsv
	Key, // json: a member's name, always a `String`, in JSON5 quoted or not, dsv: the header cell of a cell's column
	Comment, // json (JSONC, JSON5), dsv: a comment before the value that follows it, `Plain`
	Comment_Inline, // json (JSONC, JSON5): a comment on the line where the value before it ends, `Plain`
	Comment_Foot, // json, dsv: after the last value or in an empty container, on the innermost open container
	// or the root at depth 0, `Plain`
}

// A token the walk passes to a hook. Tokens come in the order the walk reads them, text order except for a dsv `Key`,
// whose span is its column's header cell, before the record that names it. `lo` is the first byte and `n` the length,
// 0 where the format writes nothing. A token longer than `n` can hold is the fault `Too_Wide`. `spelling` is the
// format's detail, read only by that format. json sets bit 0 for a string or key that needs decoding, bit 1 when it
// is quoted, bit 2 for a tolerated ill-formed sequence, a comment's marker lengths in the low two bytes, and a
// number's packed shape. dsv sets bit 0 for a cell that needs decoding, bit 1 for a quoted CSV cell, and the lead
// length 1 for a comment line.
Token :: struct {
	lo:       u64,
	n:        u32,
	kind:     Kind,
	role:     Role,
	spelling: u16,
}

// 16 bytes with no padding, so a Token is passed in two registers.
#assert(size_of(Token) == 16)

// The action a hook returns to the walk. `Skip` on an `Array` or `Map`, or on a `Key` for its member's value, passes
// that value with no more tokens, its `End` included, and on a `Key` also the comments before the value, while the
// walk still judges their bytes. The comments after the value are still given. On a scalar value `Skip` acts as
// `Next`. `Stop` ends the walk at once with no fault, with the rest of the text unjudged.
Action :: enum u8 {
	Next,
	Skip,
	Stop,
}

// Three `u64` words of hook state passed in the walk's argument registers. A hook receives them and returns them
// with its `Action`, so a cursor or count kept here needs no load or store. Three is what fits beside a walk's own
// arguments. Anything a pointer reaches stays in the hook's state.
Hook_Regs :: struct {
	a, b, c: u64,
}

// Returns `lo`, or 3 when `lo` is 0 and `src` starts with a UTF-8 byte order mark.
text_start :: proc "contextless" (src: []u8, lo: u64) -> u64 {
	if lo == 0 && len(src) >= 3 && src[0] == 0xef && src[1] == 0xbb && src[2] == 0xbf {
		return 3
	}
	return lo
}
