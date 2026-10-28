package scan

import core_pkg "../../core"
import number "./number"

// The decoded number of row `i`, and what it is relative to the authored value, decoded from its source
// text at each call (`core.number_token`), a JSON5 spelling by JSON5's: a row holds no number's value
// (`Row_Payload`), and a read must not mutate the tape. A row that is not a number, or has no binary64 value
// (`1e400`), is `NO_NUMBER`.
dom_number :: #force_inline proc(nodes: []Row, src: []byte, i: Node) -> Number {
	if i < 0 || int(i) >= len(nodes) || nodes[i].kind != .Number {
		return number.NO_NUMBER
	}
	n := nodes[i]
	return core_pkg.number_token(src, u64(n.lo), u64(n.hi), n.first_esc, spelling_of(.Json5))
}

// Is [lo, hi) a string token of `src`?
dom_str_span_ok :: #force_inline proc(src: []byte, lo, hi: u64) -> bool {
	return hi >= lo + 2 && hi <= u64(len(src)) && src[lo] == '"' && src[hi - 1] == '"'
}

// The text of the string token [lo, hi) of `doc`: an escape-free one as a slice of `src`, an escaped one
// decoded by the document's spelling into its cache's arena (`row_cache`), which grows at each call: the caller
// keeps what it decoded. `first_esc` is as in `dom_unescape_copy`, read only when `escaped`.
dom_span_text :: #force_inline proc(doc: ^Document, lo, hi: u64, escaped: bool, first_esc: u64) -> (s: []u8, ok: bool) {
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
	return (doc.spelling if doc.spelling != nil else spelling_of(.Json)).decode(src, lo, hi, first_esc, &c.arena)
}
