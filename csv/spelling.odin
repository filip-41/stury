package csv

// CSV's spellings of a document's flagged rows (`core.Row_Spelling`): a quoted cell or name that holds a `""`,
// and under `Quoting.Backslash` one that holds an escape. A dialect with neither has no flagged row. CSV rows
// hold no numbers, so the tables read none.

import core_pkg "../core"

// The spelling of `dialect`'s documents.
@(private)
spelling_of :: proc "contextless" (dialect: Dialect) -> ^core_pkg.Row_Spelling {
	return &SPELLING_ESCAPES if dialect.quoting == .Backslash else &SPELLING_QUOTES
}

@(rodata, private = "file")
SPELLING_QUOTES := core_pkg.Row_Spelling{
	decode     = quotes_decode,
	key_equals = quotes_equals,
}

@(rodata, private = "file")
SPELLING_ESCAPES := core_pkg.Row_Spelling{
	decode     = escapes_decode,
	key_equals = escapes_equals,
}

@(private = "file")
QUOTES :: Dialect{}
@(private = "file")
ESCAPES :: Dialect{quoting = .Backslash}

// A flagged token's text decoded into `arena`; `first_esc` is not read.
@(private = "file")
quotes_decode :: proc(src: []byte, lo, hi, _: u64, arena: ^core_pkg.Name_Arena) -> (text: []u8, ok: bool) {
	return token_decode(src, lo, hi, QUOTES, arena)
}

@(private = "file")
escapes_decode :: proc(src: []byte, lo, hi, _: u64, arena: ^core_pkg.Name_Arena) -> (text: []u8, ok: bool) {
	return token_decode(src, lo, hi, ESCAPES, arena)
}

@(private = "file")
token_decode :: proc(src: []byte, lo, hi: u64, dialect: Dialect, arena: ^core_pkg.Name_Arena) -> (text: []u8, ok: bool) {
	if lo > hi || hi > u64(len(src)) {
		return nil, false
	}
	view, _ := field_view(src, {lo, hi}, dialect)
	slot := core_pkg.name_arena_reserve(arena, len(view)) or_return
	n := field_unescape(view, slot, dialect)
	core_pkg.name_arena_unreserve(arena, len(slot) - n)
	return slot[:n], true
}

@(private = "file")
quotes_equals :: proc(src: []byte, lo, hi: u64, want: string) -> bool {
	return lo <= hi && hi <= u64(len(src)) && text_is(src, {lo, hi}, QUOTES, want)
}

@(private = "file")
escapes_equals :: proc(src: []byte, lo, hi: u64, want: string) -> bool {
	return lo <= hi && hi <= u64(len(src)) && text_is(src, {lo, hi}, ESCAPES, want)
}
