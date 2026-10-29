package core

// What every format's walk gives its caller: one token per event, through one hook, and the first fault. The walks
// differ underneath and is shared between the formats

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
	End, // json: `]` and `}`, dsv: the end of a record and of the text, `n` 0
}

// What a token is to its container. A key may be any value in the formats that allow it.
Role :: enum u8 {
	Value, // json, dsv
	Key, // json: a member's name, always a `String`, dsv: the header cell of a cell's column
}

// One token, in text order. `lo` is its first byte and `n` its length, 0 where the format writes nothing. A token
// longer than `n` holds is `Too_Wide`. `spelling` is the format's own detail, read back only by that format. json: 1
// when a string holds an escape, so a reader decodes only those. dsv: 1 when a cell is quoted.
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
// with no more tokens, its `End` included, while the walk still judges its bytes. On a scalar value it is `Next`.
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

// What went wrong, the same for every format, and where. Each member names the formats that raise it. Zero is no
// fault.
Fault_Kind :: enum u8 {
	Truncated = 1, // json, dsv: the input ended inside a construct, at `len(src)`
	Bad_Char, // json, dsv: the first byte that cannot extend the construct, or that is not UTF-8
	Bad_Escape, // json: at the escape's letter, or a lone surrogate half at its backslash
	Bad_Number, // json: at the byte that breaks the number
	Too_Deep, // json: at the bracket past the format's depth limit
	Trailing, // json's one-document framing: at the first byte after the document
	Bad_Structure, // dsv: well-formed text breaking a rule of the format's structure, at the construct's first byte
	Too_Wide, // json, dsv: a token longer than `Token.n` holds, at its first byte
}

// `detail` tells a format's own rules apart within a kind, and the format turns it into a message. 0 is none.
Fault :: struct {
	offset: u64,
	kind:   Fault_Kind,
	detail: u8,
}
