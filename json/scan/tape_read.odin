package scan

import "base:runtime"
import number "./number"

// The decoded number of row `i`, and what it is relative to the authored value, decoded from its source
// text at each call (`number_token`): a row holds no number's value (`Row_Payload`), and a read must not
// mutate the tape. A row that is not a number, or has no binary64 value (`1e400`), is `NO_NUMBER`.
dom_number :: #force_inline proc(nodes: []Row, src: []byte, i: Node) -> Number {
	if i < 0 || int(i) >= len(nodes) || nodes[i].kind != .Number {
		return number.NO_NUMBER
	}
	n := nodes[i]
	return number.number_token(src, u64(n.lo), u64(n.hi), n.first_esc)
}

// The `i64` number row `i` writes (`decode_int`'s answer), from the row's digit counts where they settle it
// (`int_token`) and from its source text otherwise.
dom_int :: #force_inline proc(nodes: []Row, src: []byte, i: Node) -> (v: i64, ok: bool) {
	if i < 0 || int(i) >= len(nodes) || nodes[i].kind != .Number {
		return 0, false
	}
	n := nodes[i]
	known: bool
	if v, ok, known = number.int_token(src, u64(n.lo), u64(n.hi), n.first_esc); known {
		return v, ok
	}
	if n.first_esc == number.DIALECT_SPELLED && n.lo < n.hi && int(n.hi) <= len(src) {
		return json5_int(src, u64(n.lo), u64(n.hi))
	}
	return decode_int(src, u64(n.lo), u64(n.hi))
}

// Is [lo, hi) a string token of `src`?
dom_str_span_ok :: #force_inline proc(src: []byte, lo, hi: u64) -> bool {
	return hi >= lo + 2 && hi <= u64(len(src)) && src[lo] == '"' && src[hi - 1] == '"'
}

// The decoded text of string row `i`, whatever scan produced the rows: an escape-free text as a slice
// of `src`, a `.Decoded` escaped one as its slice of `values` (the store the `.Dom` walk decoded into), and
// any other escaped one unescaped into `arena` (bound to `alloc` on first use). That last is the cold path
// and is not cached here: each call decodes again and grows the arena. Its reserve is the text length,
// as the row carries no decoded length. `ok` is false for a row that is not a string, a malformed span,
// or a refused allocation.
dom_get_string :: proc(
	nodes: []Row,
	src: []byte,
	values: []u8,
	arena: ^Name_Arena,
	alloc: runtime.Allocator,
	i: Node,
	dialect := Dialect.Json,
) -> (s: []u8, ok: bool) {
	if i < 0 || int(i) >= len(nodes) || nodes[i].kind != .String {
		return nil, false
	}
	n := nodes[i]
	escaped := str_escaped(n)
	if .Decoded in n.flags {
		if escaped {
			return values[n.payload.str.off:][:n.payload.str.len], true
		}
		return src[n.lo + 1:n.hi - 1], true
	}
	// Lets the decoder's bulk copy start at the first backslash.
	esc, _ := first_escape_offset(n)
	return dom_span_text(src, arena, alloc, u64(n.lo), u64(n.hi), escaped, esc, dialect)
}

// The decoded key of member row `i`: an escape-free key as a slice of `src`, an escaped one unescaped into
// `arena` (bound to `alloc` on first use). The row's payload belongs to its value, so an escaped key is
// not cached: each read decodes again and grows the arena. `ok` is false for a row with no key, a
// malformed span, or a refused allocation.
dom_key :: proc(
	nodes: []Row,
	src: []byte,
	arena: ^Name_Arena,
	alloc: runtime.Allocator,
	i: Node,
	dialect := Dialect.Json,
) -> (s: []u8, ok: bool) {
	if i < 0 || int(i) >= len(nodes) || nodes[i].key_lo == NO_KEY {
		return nil, false
	}
	return dom_span_text(src, arena, alloc, u64(nodes[i].key_lo), u64(nodes[i].key_hi), .Key_Escaped in nodes[i].flags, 0, dialect)
}

// The text of the string token [lo, hi): an escape-free one as a slice of `src`, an escaped one unescaped
// into `arena` (bound to `alloc` on first use). `first_esc` is as in `dom_unescape_copy`.
@(private = "file")
dom_span_text :: #force_inline proc(
	src: []byte,
	arena: ^Name_Arena,
	alloc: runtime.Allocator,
	lo, hi: u64,
	escaped: bool,
	first_esc: u64,
	dialect: Dialect,
) -> (s: []u8, ok: bool) {
	if escaped && dialect == .Json5 {
		return json5_span_text(src, arena, alloc, lo, hi)
	}
	if !dom_str_span_ok(src, lo, hi) {
		return nil, false
	}
	if !escaped {
		return src[lo + 1:hi - 1], true
	}
	if !name_arena_adopt(arena, alloc) {
		return nil, false
	}
	slot, reserved := name_arena_reserve(arena, int(hi - lo - 2))
	if !reserved {
		return nil, false
	}
	w := dom_unescape_into(slot, src, lo, hi, first_esc)
	if w < 0 {
		return nil, false
	}
	name_arena_unreserve(arena, len(slot) - w)
	return slot[:w], true
}
