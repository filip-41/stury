package core

// What every format's walk gives its caller: one token per event, through one hook, and the first fault. The walks
// differ underneath, and what they give is shared between the formats.

// What a token is. `Array` and `Map` open a container, `End` closes the innermost one, and every other kind is a
// scalar. `Plain` is text whose type the format resolves for the consumer. Each member names the formats that give it.
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

// What a token is to its container. A key may be any value in the formats that allow it. Past `Key` a token is a
// fact: what a value carries that is not its value, which never changes its meaning. A comment belongs to one value,
// by one rule for every format: on the line where the previous value ends it is that value's `Comment_Inline`, else
// before a value the grammar lets it stand above it is that value's `Comment`, else it is the previous value's, or
// the container's, `Comment_Foot`. A consumer that wants values only tests `t.role <= .Key`.
Role :: enum u8 {
	Value, // json, dsv
	Key, // json: a member's name, always a `String`, in JSON5 quoted or not, dsv: the header cell of a cell's column
	Comment, // json (JSONC, JSON5): a comment above the value after it, `Plain`
	Comment_Inline, // json (JSONC, JSON5): a comment on the line where the value before it ends, `Plain`
	Comment_Foot, // json (JSONC, JSON5): a comment after the value before it, or in an empty container, with no value after it, `Plain`
}

// One token, in the order the walk reads it. That is text order except for a dsv `Key`, whose span is its column's
// header cell, before the record the key names. `lo` is its first byte and `n` its length, 0 where the format writes
// nothing. A token longer than `n` holds is `Too_Wide`. `spelling` is the format's own detail, read back only by that
// format. json: 1 when a string holds an escape, so a reader decodes only those, 1 when a comment is `/* */` rather
// than `//`, and a number's `json.Number_Spelling`. dsv: 1 when a cell is quoted.
Token :: struct {
	lo:       u64,
	n:        u32,
	kind:     Kind,
	role:     Role,
	spelling: u16,
}

// Two registers in a call, with no gap.
#assert(size_of(Token) == 16)

// What a hook asks of the walk. `Skip` on an `Array` or `Map`, or on a `Key` for its member's value, passes that value
// with no more tokens, its `End` included, and on a `Key` the comments before the value, while the walk still judges
// their bytes. The comments after the value are still given. On a scalar value it is `Next`.
// `Stop` ends the walk at once with no fault, the rest of the text unjudged.
Action :: enum u8 {
	Next,
	Skip,
	Stop,
}

// The hottest three words of a hook's state, which ride the walk's argument registers from token to token: a hook
// takes them and returns them with its `Action`, so a cursor or a count kept here costs no load or store. Three is
// what fits beside a walk's own arguments. Anything a pointer reaches stays in the hook's state.
Hook_Regs :: struct {
	a, b, c: u64,
}

// Where a text read from `lo` starts: past one UTF-8 byte order mark when `lo` is the text's first byte.
text_start :: proc "contextless" (src: []u8, lo: u64) -> u64 {
	if lo == 0 && len(src) >= 3 && src[0] == 0xef && src[1] == 0xbb && src[2] == 0xbf {
		return 3
	}
	return lo
}
