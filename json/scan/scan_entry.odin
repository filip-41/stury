package scan

import lex "lex"

// See `lex.SCAN_FORCE_SLOW`.
SCAN_FORCE_SLOW :: lex.SCAN_FORCE_SLOW

// Resolve the caller's caps, held to `ceiling`, and step over the BOM. Whitespace is not yet skipped. A walk on the
// fixed frames passes MAX_DEPTH, a bound the compiler then knows, so a checked push does not test its frame index again.
enter_document :: #force_inline proc(src: []byte, limits: Limits, $ceiling: u64) -> Scanner {
	return Scanner{src = src, limits = resolve_under(limits, ceiling), pos = u64(bom_len(src)), alloc = context.allocator}
}

// Whole-document result: whether the source is well-formed. Its walk carries no scan-fact code, and
// `scan_queries` also records the facts a request named.
//
// Error offsets follow one rule per fault class, because only syntax faults have a faulting byte:
//   - syntax (`Truncated`, `Bad_*`, `Trailing`): the first byte that cannot extend the construct, or
//     len(src) when the input ended. `Truncated` means "append bytes and this could still be well-formed".
//   - budget (`Limit_Digits`, `Limit_Scale`, `Too_Deep`): the first byte of the construct that exceeded
//     the cap, since the token is well-formed and merely too large. `Too_Deep` for 1025 `[` is 1024.
// The digit cap is decided as soon as the mantissa run is counted, before any later grammar is examined:
// 257 digits then `.` is `Limit_Digits` at the token start, not `Truncated`.
//
// Always a whole-item result (no query can settle early), so it has no `validity` out-parameter. A cap past
// MAX_DEPTH is held to it: `scan_plain_deep` reads deeper.
//
// Inlined, so a caller's constant strictness picks one walk at compile time: a `.Locate` walk is linked only
// into a program that can ask for one.
scan_plain :: #force_inline proc(
	src: []byte,
	strictness := Strictness.Strict,
	limits := Limits{},
) -> Maybe(Error) {
	// One literal per arm: the walk's check level is a polymorphic parameter and must be constant. No
	// `case:` default, so a new `Check_Level` member fails to compile instead of being swallowed.
	switch axes_check_level(axes_for(strictness, .All)) {
	case .Values:
		return scan_plain_at(src, limits, .Values)
	case .Locate:
		return scan_plain_at(src, limits, .Locate)
	}
	unreachable()
}

@(private = "file")
scan_plain_at :: proc(src: []byte, limits: Limits, $check: Check_Level) -> Maybe(Error) {
	s := enter_document(src, limits, MAX_DEPTH)
	lex.skip_ws(&s)
	if pretty_head(src, int(s.pos)) {
		return scan_plain_pretty(src, limits, check)
	}
	if err := walk_value(&s, s.limits.max_depth, check); err != nil {
		return err
	}
	return finish(&s)
}

// Runs `scan_plain` on the pretty cursor, for a document that starts like pretty-printed output
// (`pretty_head`). It has its own function and scanner so the compact walk's scanner stays in registers.
@(private = "file")
scan_plain_pretty :: #force_no_inline proc(src: []byte, limits: Limits, $check: Check_Level) -> Maybe(Error) {
	s := enter_document(src, limits, MAX_DEPTH)
	lex.skip_ws(&s)
	cur: Pretty_Cursor
	if err := walk_value_q(&s, nil, s.limits.max_depth, check, {}, &cur, false, false); err != nil {
		return err
	}
	return finish(&s)
}

// `scan_plain` under a cap past MAX_DEPTH, on `walk_deep`: `.Structural` keeps its level, and `.Strict` and
// `.Lazy` (which has nothing to stop at) check every value. The caller picks it before the walk, so
// `scan_plain` compiles as if it did not exist. Inlined as `scan_plain` is.
scan_plain_deep :: #force_inline proc(src: []byte, strictness: Strictness, limits: Limits) -> Maybe(Error) {
	switch axes_check_level(axes_for(strictness, .All)) {
	case .Values:
		return scan_plain_deep_at(src, limits, .Values)
	case .Locate:
		return scan_plain_deep_at(src, limits, .Locate)
	}
	unreachable()
}

@(private = "file")
scan_plain_deep_at :: #force_no_inline proc(src: []byte, limits: Limits, $check: Check_Level) -> Maybe(Error) {
	s := enter_document(src, limits, DEPTH_CEILING)
	lex.skip_ws(&s)
	cur := Jsonc_Cursor{json = true}
	if err := walk_deep(&s, nil, s.limits.max_depth, check, {}, &cur, false, nil); err != nil {
		return err
	}
	return finish(&s)
}

// Whether the RFC 7464 record `text`, which starts past whitespace and is not empty, is a number with
// nothing after it, which RFC 7464 §2.4 holds may have been cut short.
seq_truncated_number :: proc(text: []byte) -> bool {
	if text[0] != '-' && (text[0] < '0' || text[0] > '9') {
		return false
	}
	for b in text {
		switch b {
		case '0' ..= '9', '-', '+', '.', 'e', 'E':
		case:
			return false
		}
	}
	return true
}

// A framed record or text that ends inside a literal is `.Truncated` alone, but when a byte follows it (a
// space, a newline, the framing's end) that byte is what ended it, and checking the text with it reports
// `.Bad_Literal`, shifting no offset.
cut_by_next_byte :: proc(data: []byte, at, limit: int, e: Error, dialect := Dialect.Json, limits := Limits{}) -> Error {
	if e.kind == .Truncated && e.offset == u64(limit - at) && limit < len(data) {
		slice := data[at:limit + 1]
		if with, bad := validate_dialect(slice, dialect, nil, limits).?; bad && with.kind == .Bad_Literal {
			return with
		}
	}
	return e
}
