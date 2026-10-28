package core

// A format's spelling: how the tokens of one format variant that a row flags are read. A plain row is read by
// core alone (rows.odin); a flagged one (`.Str_Escaped`, `.Key_Escaped`, a number whose digit pack is
// `SPELLED_NUMBER`) calls through the table of the document that holds it. A table is immutable and shared by
// every document and thread that reads its format variant.
Row_Spelling :: struct {
	// The text of flagged string or key token `src[lo:hi]`, decoded into `arena`: what a reader keeps. `first_esc` is a
	// string row's `first_esc` (0 for a key). False when the arena refused, or the span is no such token.
	decode:     proc(src: []byte, lo, hi, first_esc: u64, arena: ^Name_Arena) -> (text: []u8, ok: bool),
	// Whether flagged key token `src[lo:hi]` decodes to `want`, decoding nothing.
	key_equals: proc(src: []byte, lo, hi: u64, want: string) -> bool,
	// The value of a number row spelled the format's own way.
	number:     proc(src: []byte, lo, hi: u64) -> Number,
	// The `i64` such a row writes, false when it writes none.
	int:        proc(src: []byte, lo, hi: u64) -> (v: i64, ok: bool),
}
