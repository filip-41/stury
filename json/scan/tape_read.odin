package scan

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

// The text of the string token [lo, hi) of `doc`: an escape-free one as a slice of `src`, an escaped one
// unescaped by the document's dialect into its cache's arena (`row_cache`), which grows
// at each call: the caller keeps what it decoded. `first_esc` is as in `dom_unescape_copy`, read only when
// `escaped`.
dom_span_text :: #force_inline proc(doc: ^Row_Document, lo, hi: u64, escaped: bool, first_esc: u64) -> (s: []u8, ok: bool) {
	src := doc.src
	if !escaped {
		if !dom_str_span_ok(src, lo, hi) {
			return nil, false
		}
		return src[lo + 1:hi - 1], true
	}
	c := row_cache(doc)
	if c == nil {
		return nil, false
	}
	if own_spelling(doc.dialect) {
		return json5_span_text(src, &c.arena, doc.rows.allocator, lo, hi)
	}
	if !dom_str_span_ok(src, lo, hi) {
		return nil, false
	}
	slot, reserved := name_arena_reserve(&c.arena, int(hi - lo - 2))
	if !reserved {
		return nil, false
	}
	w := dom_unescape_into(slot, src, lo, hi, first_esc)
	if w < 0 {
		return nil, false
	}
	name_arena_unreserve(&c.arena, len(slot) - w)
	return slot[:w], true
}
