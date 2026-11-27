package html

// The tokenizer's states (HTML5 §13.2.5): hot loops share `#force_inline` templates inside thin `#force_no_inline`
// state wrappers (preserving identical `#must_tail` signatures and zero-overhead codegen); cold multi-state chains
// (script-escaped, comments, doctypes, CDATA, PIs) run iteratively and `#must_tail` back to hot states.

@(private, enable_target_feature = STATE_FEATURES)
st_data :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q, act, res := text_loop(p, end, t, on, .Data)
	if act == 1 { return #must_tail st_tag_open(q, end, t, on) }
	if act == 2 { return #must_tail st_char_ref(q, end, t, on) }
	return res
}
@(private, enable_target_feature = STATE_FEATURES)
st_rcdata :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q, act, res := text_loop(p, end, t, on, .Rcdata)
	if act == 1 { return #must_tail st_text_end_open(q, end, t, on) }
	if act == 2 { return #must_tail st_char_ref(q, end, t, on) }
	return res
}
@(private, enable_target_feature = STATE_FEATURES)
st_rawtext :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q, act, res := text_loop(p, end, t, on, .Rawtext)
	if act == 1 { return #must_tail st_text_end_open(q, end, t, on) }
	return res
}
@(private, enable_target_feature = STATE_FEATURES)
st_script :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q, act, res := text_loop(p, end, t, on, .Script_Data)
	if act == 1 { return #must_tail st_script_lt(q, end, t, on) }
	return res
}
@(private, enable_target_feature = STATE_FEATURES)
st_plaintext :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	_, _, res := text_loop(p, end, t, on, .Plaintext)
	return res
}

@(private = "file", enable_target_feature = STATE_FEATURES)
text_loop :: #force_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, $K: Content) -> ([^]u8, u8, u64) {
	q := p
	for {
		when K == .Data || K == .Rcdata {
			q = stop_at(q, end, STOP_DATA)
		} else when K == .Rawtext || K == .Script_Data {
			q = stop_at(q, end, STOP_RAW)
		} else {
			q = stop_at(q, end, STOP_PLAIN)
		}
		if q >= end {
			when STREAM {
				safe_hi := at(t, end)
				if safe_hi > t.text_lo && t.base[safe_hi - 1] == '\r' {
					safe_hi -= 1
				}
				return nil, 0, stream_pause_at_text(t, on, safe_hi)
			}
			return nil, 0, finish(t, on, end, at(t, end))
		}
		switch q[0] {
		case '<':
			when K == .Data {
				t.text_hi = at(t, q)
				when STREAM {
					t.text_err_len = len(t.h.errors)
					t.text_judged = t.judged
				}
				return q[1:], 1, 0
			} else when K == .Rcdata || K == .Rawtext {
				t.text_hi = at(t, q)
				when STREAM {
					t.text_err_len = len(t.h.errors)
					t.text_judged = t.judged
				}
				q = q[1:]
				when STREAM {
					if q >= end { return nil, 0, stream_pause_tag(t) }
				}
				if q < end && q[0] == '/' {
					t.back = .Rcdata when K == .Rcdata else .Rawtext
					return q[1:], 1, 0
				}
				continue
			} else when K == .Script_Data {
				t.text_hi = at(t, q)
				when STREAM {
					t.text_err_len = len(t.h.errors)
					t.text_judged = t.judged
				}
				return q[1:], 1, 0
			}
		case '&':
			when K == .Data || K == .Rcdata {
				t.ret = .Data when K == .Data else .Rcdata
				return q, 2, 0
			}
		case 0:
			t.text_flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) { return nil, 0, halt(t, q) }
			q = q[1:]
			continue
		}
		n, stop := judge(t, on, q, end, &t.text_flags)
		if stop {
			when STREAM {
				if t.need_more { return nil, 0, stream_pause_at_text(t, on, at(t, q)) }
			}
			return nil, 0, halt(t, q)
		}
		q = q[n:]
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_tag_open :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end { return eof_error(t, on, end, .Eof_Before_Tag_Name) }
	c := p[0]
	switch {
	case c == '!': return #must_tail st_markup_open(p[1:], end, t, on)
	case c == '/': return #must_tail st_end_tag_open(p[1:], end, t, on)
	case CLASS[c] & C_ALPHA != 0:
		open_tag(t, .Start_Tag, at(t, p) - 1, p)
		return #must_tail st_tag_name(p, end, t, on)
	case c == '?':
		t.tok = Html_Token{kind = .Instruction, lo = at(t, p) - 1}
		t.mark = at(t, p)
		return #must_tail st_pi(p[1:], end, t, on)
	}
	if judge_first(t, on, p, end) || report(t, on, p, .Invalid_First_Character_Of_Tag_Name) { return halt(t, p) }
	return #must_tail st_data(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_end_tag_open :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end { return eof_error(t, on, end, .Eof_Before_Tag_Name) }
	c := p[0]
	if CLASS[c] & C_ALPHA != 0 {
		open_tag(t, .End_Tag, at(t, p) - 2, p)
		return #must_tail st_tag_name(p, end, t, on)
	}
	if c == '>' {
		if report(t, on, p, .Missing_End_Tag_Name) || flush(t, on, t.text_hi, at(t, p) + 1) { return halt(t, p[1:]) }
		return #must_tail st_data(p[1:], end, t, on)
	}
	if judge_first(t, on, p, end) || report(t, on, p, .Invalid_First_Character_Of_Tag_Name) { return halt(t, p) }
	open_comment(t, at(t, p) - 2, p)
	return #must_tail st_bogus_comment(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_tag_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		for q < end && CLASS[q[0]] & (C_WS | C_UPPER | C_JUDGE | C_TAG_END) == 0 { q = q[1:] }
		if q >= end { return eof_in_tag(t, on, end) }
		c := q[0]
		switch {
		case CLASS[c] & C_WS != 0:
			end_name(t, q)
			return #must_tail st_before_attr_name(q[1:], end, t, on)
		case c == '/':
			end_name(t, q)
			return #must_tail st_self_closing(q[1:], end, t, on)
		case c == '>':
			end_name(t, q)
			if emit_tag(t, on, q) { return halt(t, q[1:]) }
			return #must_tail st_content(q[1:], end, t, on)
		case c == 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) { return halt(t, q) }
			q = q[1:]
		case CLASS[c] & C_UPPER != 0:
			t.flags += {.Upper}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop { return halt(t, q) }
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_text_end_open :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	when STREAM {
		if p >= end { return stream_pause_tag(t) }
	}
	if p >= end || CLASS[p[0]] & C_ALPHA == 0 { return #must_tail st_back(p, end, t, on) }
	open_tag(t, .End_Tag, at(t, p) - 2, p)
	q := p
	for q < end && CLASS[q[0]] & C_ALPHA != 0 {
		if CLASS[q[0]] & C_UPPER != 0 { t.flags += {.Upper} }
		q = q[1:]
	}
	when STREAM {
		if q >= end { return stream_pause_tag(t) }
	}
	if q < end && appropriate(t, q) {
		c := q[0]
		switch {
		case CLASS[c] & C_WS != 0:
			end_name(t, q)
			return #must_tail st_before_attr_name(q[1:], end, t, on)
		case c == '/':
			end_name(t, q)
			return #must_tail st_self_closing(q[1:], end, t, on)
		case c == '>':
			end_name(t, q)
			if emit_tag(t, on, q) { return halt(t, q[1:]) }
			return #must_tail st_content(q[1:], end, t, on)
		}
	}
	return #must_tail st_back(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_script_lt :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	when STREAM {
		if p >= end { return stream_pause_tag(t) }
	}
	if p < end {
		if p[0] == '/' {
			t.back = .Script
			return #must_tail st_text_end_open(p[1:], end, t, on)
		}
		if p[0] == '!' {
			q := p[1:]
			when STREAM {
				if q >= end { return stream_pause_tag(t) }
			}
			if q < end && q[0] == '-' {
				q = q[1:]
				when STREAM {
					if q >= end { return stream_pause_tag(t) }
				}
				if q < end && q[0] == '-' {
					q = q[1:]
					for q < end && q[0] == '-' { q = q[1:] }
					if q >= end { return eof_error(t, on, end, .Eof_In_Script_Html_Comment_Like_Text) }
					if q[0] == '>' { return #must_tail st_script(q[1:], end, t, on) }
					when STREAM {
						t.esc_lo = t.text_hi
						t.esc_err_len = t.text_err_len
						t.esc_judged = t.text_judged
					}
					return #must_tail st_script_escaped(q, end, t, on)
				}
			}
			return #must_tail st_script(q, end, t, on)
		}
	}
	return #must_tail st_script(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_script_escaped :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	dbl := false
	for {
		q = stop_at(q, end, STOP_DASH)
		if q >= end { return eof_error(t, on, end, .Eof_In_Script_Html_Comment_Like_Text) }
		switch q[0] {
		case '-':
			q = q[1:]
			if q >= end { return eof_error(t, on, end, .Eof_In_Script_Html_Comment_Like_Text) }
			if q[0] == '-' {
				for q < end && q[0] == '-' { q = q[1:] }
				if q >= end { return eof_error(t, on, end, .Eof_In_Script_Html_Comment_Like_Text) }
				if q[0] == '>' {
					when STREAM { t.esc_lo = max(u64) }
					return #must_tail st_script(q[1:], end, t, on)
				}
			}
		case '<':
			if !dbl {
				t.text_hi = at(t, q)
				q = q[1:]
				when STREAM {
					if q >= end { return stream_pause_tag(t) }
				}
				if q < end && q[0] == '/' {
					t.back = .Escaped
					return #must_tail st_text_end_open(q[1:], end, t, on)
				}
				if q < end && CLASS[q[0]] & C_ALPHA != 0 {
					t.mark = at(t, q)
					for q < end && CLASS[q[0]] & C_ALPHA != 0 { q = q[1:] }
					when STREAM {
						if q >= end { return stream_pause_tag(t) }
					}
					if q < end && (CLASS[q[0]] & C_WS != 0 || q[0] == '/' || q[0] == '>') {
						if q[0] == '\r' { t.text_flags += {.Cr} }
						if is_script(t, q) { dbl = true }
						q = q[1:]
					}
				}
			} else {
				q = q[1:]
				when STREAM {
					if q >= end { return stream_pause_tag(t) }
				}
				if q < end && q[0] == '/' {
					q = q[1:]
					when STREAM {
						if q >= end { return stream_pause_tag(t) }
					}
					t.mark = at(t, q)
					for q < end && CLASS[q[0]] & C_ALPHA != 0 { q = q[1:] }
					when STREAM {
						if q >= end { return stream_pause_tag(t) }
					}
					if q < end && (CLASS[q[0]] & C_WS != 0 || q[0] == '/' || q[0] == '>') {
						if q[0] == '\r' { t.text_flags += {.Cr} }
						if is_script(t, q) { dbl = false }
						q = q[1:]
					}
				}
			}
		case 0:
			t.text_flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) { return halt(t, q) }
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.text_flags)
			if stop { return halt(t, q) }
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_before_attr_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	if q >= end || q[0] == '/' || q[0] == '>' { return #must_tail st_after_attr_name(q, end, t, on) }
	open_attr(t, q)
	if q[0] == '=' {
		if report(t, on, q, .Unexpected_Equals_Sign_Before_Attribute_Name) { return halt(t, q) }
		return #must_tail st_attr_name(q[1:], end, t, on)
	}
	return #must_tail st_attr_name(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_attr_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		for q < end && CLASS[q[0]] & (C_WS | C_UPPER | C_JUDGE | C_TAG_END | C_ATTR_END) == 0 { q = q[1:] }
		c := q[0] if q < end else '>'
		switch {
		case q >= end || CLASS[c] & C_WS != 0 || c == '/' || c == '>':
			if end_attr_name(t, on, q) { return halt(t, q) }
			return #must_tail st_after_attr_name(q, end, t, on)
		case c == '=':
			if end_attr_name(t, on, q) { return halt(t, q) }
			return #must_tail st_before_attr_value(q[1:], end, t, on)
		case CLASS[c] & C_UPPER != 0:
			t.flags += {.Upper}
			q = q[1:]
		case c == 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) { return halt(t, q) }
			q = q[1:]
		case c == '"' || c == '\'' || c == '<':
			if report(t, on, q, .Unexpected_Character_In_Attribute_Name) { return halt(t, q) }
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop { return halt(t, q) }
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_after_attr_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	if q >= end { return eof_in_tag(t, on, end) }
	switch q[0] {
	case '/': return #must_tail st_self_closing(q[1:], end, t, on)
	case '=': return #must_tail st_before_attr_value(q[1:], end, t, on)
	case '>':
		if emit_tag(t, on, q) { return halt(t, q[1:]) }
		return #must_tail st_content(q[1:], end, t, on)
	}
	open_attr(t, q)
	return #must_tail st_attr_name(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_before_attr_value :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	if q < end {
		switch q[0] {
		case '"':
			open_attr(t, q[1:])
			return #must_tail st_attr_value_double(q[1:], end, t, on)
		case '\'':
			open_attr(t, q[1:])
			return #must_tail st_attr_value_single(q[1:], end, t, on)
		case '>':
			if report(t, on, q, .Missing_Attribute_Value) || emit_tag(t, on, q) { return halt(t, q[1:]) }
			return #must_tail st_content(q[1:], end, t, on)
		}
	}
	open_attr(t, q)
	return #must_tail st_attr_value_unquoted(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_attr_value_double :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q, act, res := attr_quoted_loop(p, end, t, on, '"')
	if act == 1 { return #must_tail st_after_attr_value(q, end, t, on) }
	if act == 2 { return #must_tail st_char_ref(q, end, t, on) }
	return res
}
@(private, enable_target_feature = STATE_FEATURES)
st_attr_value_single :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q, act, res := attr_quoted_loop(p, end, t, on, '\'')
	if act == 1 { return #must_tail st_after_attr_value(q, end, t, on) }
	if act == 2 { return #must_tail st_char_ref(q, end, t, on) }
	return res
}

@(private = "file", enable_target_feature = STATE_FEATURES)
attr_quoted_loop :: #force_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, $Q: u8) -> ([^]u8, u8, u64) {
	q := p
	for {
		q = stop_at(q, end, STOP_DOUBLE when Q == '"' else STOP_SINGLE)
		if q >= end { return nil, 0, eof_in_tag(t, on, end) }
		switch q[0] {
		case Q:
			end_value(t, q)
			return q[1:], 1, 0
		case '&':
			t.ret = .Double when Q == '"' else .Single
			return q, 2, 0
		case 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) { return nil, 0, halt(t, q) }
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop { return nil, 0, halt(t, q) }
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_attr_value_unquoted :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		if q >= end { return eof_in_tag(t, on, end) }
		c := q[0]
		switch {
		case CLASS[c] & C_WS != 0:
			end_value(t, q)
			return #must_tail st_before_attr_name(q[1:], end, t, on)
		case c == '&':
			t.ret = .Unquoted
			return #must_tail st_char_ref(q, end, t, on)
		case c == '>':
			end_value(t, q)
			if emit_tag(t, on, q) { return halt(t, q[1:]) }
			return #must_tail st_content(q[1:], end, t, on)
		case c == 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) { return halt(t, q) }
			q = q[1:]
		case c == '"' || c == '\'' || c == '<' || c == '=' || c == '`':
			if report(t, on, q, .Unexpected_Character_In_Unquoted_Attribute_Value) { return halt(t, q) }
			q = q[1:]
		case CLASS[c] & C_JUDGE != 0:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop { return halt(t, q) }
			q = q[n:]
		case:
			q = q[1:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_after_attr_value :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end { return eof_in_tag(t, on, end) }
	switch {
	case CLASS[p[0]] & C_WS != 0: return #must_tail st_before_attr_name(p[1:], end, t, on)
	case p[0] == '/':             return #must_tail st_self_closing(p[1:], end, t, on)
	case p[0] == '>':
		if emit_tag(t, on, p) { return halt(t, p[1:]) }
		return #must_tail st_content(p[1:], end, t, on)
	}
	if judge_first(t, on, p, end) || report(t, on, p, .Missing_Whitespace_Between_Attributes) { return halt(t, p) }
	return #must_tail st_before_attr_name(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_self_closing :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end { return eof_in_tag(t, on, end) }
	if p[0] == '>' {
		t.tok.flags += {.Self_Closing}
		if emit_tag(t, on, p) { return halt(t, p[1:]) }
		return #must_tail st_content(p[1:], end, t, on)
	}
	if judge_first(t, on, p, end) || report(t, on, p, .Unexpected_Solidus_In_Tag) { return halt(t, p) }
	return #must_tail st_before_attr_name(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_bogus_comment :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_BOGUS)
		if q >= end {
			t.tok.data = span_of(t, t.lo, at(t, end), .Raw, t.flags)
			return emit_at_end(t, on, end)
		}
		switch q[0] {
		case '>':
			t.tok.data = span_of(t, t.lo, at(t, q), .Raw, t.flags)
			if emit(t, on, q[1:]) { return halt(t, q[1:]) }
			return #must_tail st_content(q[1:], end, t, on)
		case 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) { return halt(t, q) }
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop { return halt(t, q) }
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_markup_open :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	left := int(at(t, end) - at(t, p))
	when STREAM {
		if left < 7 { return stream_pause_tag(t) }
	}
	lo := at(t, p) - 2
	if left >= 2 && p[0] == '-' && p[1] == '-' {
		open_comment(t, lo, p[2:])
		return #must_tail st_comment(p[2:], end, t, on)
	}
	if left >= 7 && fold_equal(p, transmute([]u8)string("doctype")) {
		missing := Span{flags = {.Missing}}
		t.tok = Html_Token{kind = .Doctype, lo = lo, name = missing, public_id = missing, system_id = missing}
		return #must_tail st_doctype(p[7:], end, t, on)
	}
	if left >= 7 && string(p[:7]) == "[CDATA[" {
		when STREAM {
			if !t.in_foreign {
				closed := false
				for q := p[7:]; q < end; q = q[1:] {
					if q[0] == '>' { closed = true; break }
				}
				if !closed { return stream_pause_tag(t) }
			}
		}
		if flush(t, on, t.text_hi, at(t, p) + 7) { return halt(t, p[7:]) }
		if t.in_foreign {
			t.content = .Cdata_Section
			t.text_mode = .Verbatim
			return #must_tail st_cdata(p[7:], end, t, on)
		}
		if report(t, on, p[6:], .Cdata_In_Html_Content) { return halt(t, p[7:]) }
		open_comment(t, lo, p)
		return #must_tail st_bogus_comment(p[7:], end, t, on)
	}
	if judge_first(t, on, p, end) || report(t, on, p, .Incorrectly_Opened_Comment) { return halt(t, p) }
	open_comment(t, lo, p)
	return #must_tail st_bogus_comment(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_comment :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	in_end := false
	if q < end {
		if q[0] == '>' {
			t.tok.data = span_of(t, t.lo, t.lo, .Raw, {})
			if report(t, on, q, .Abrupt_Closing_Of_Empty_Comment) || emit(t, on, q[1:]) { return halt(t, q[1:]) }
			return #must_tail st_content(q[1:], end, t, on)
		}
		if q[0] == '-' {
			q = q[1:]
			if q >= end { t.mark = t.lo; return eof_in_comment(t, on, end) }
			if q[0] == '>' {
				t.tok.data = span_of(t, t.lo, t.lo, .Raw, {})
				if report(t, on, q, .Abrupt_Closing_Of_Empty_Comment) || emit(t, on, q[1:]) { return halt(t, q[1:]) }
				return #must_tail st_content(q[1:], end, t, on)
			}
			if q[0] == '-' { t.mark = t.lo; q = q[1:]; in_end = true }
		}
	}
	for {
		if in_end {
			for q < end && q[0] == '-' { t.mark += 1; q = q[1:] }
			if q >= end { return eof_in_comment(t, on, end) }
			if q[0] == '>' {
				t.tok.data = span_of(t, t.lo, t.mark, .Raw, t.flags)
				if emit(t, on, q[1:]) { return halt(t, q[1:]) }
				return #must_tail st_content(q[1:], end, t, on)
			}
			if q[0] == '!' {
				q = q[1:]
				if q >= end { return eof_in_comment(t, on, end) }
				if q[0] == '>' {
					t.tok.data = span_of(t, t.lo, t.mark, .Raw, t.flags)
					if report(t, on, q, .Incorrectly_Closed_Comment) || emit(t, on, q[1:]) { return halt(t, q[1:]) }
					return #must_tail st_content(q[1:], end, t, on)
				}
				if q[0] == '-' {
					t.mark = at(t, q)
					q = q[1:]
					if q >= end { return eof_in_comment(t, on, end) }
					if q[0] == '-' { q = q[1:]; continue }
				}
			}
			in_end = false
			continue
		}
		q = stop_at(q, end, STOP_DASH)
		if q >= end { t.mark = at(t, end); return eof_in_comment(t, on, end) }
		switch q[0] {
		case '<':
			for q < end && q[0] == '<' { q = q[1:] }
			if q < end && q[0] == '!' {
				q = q[1:]
				if q < end && q[0] == '-' {
					q = q[1:]
					if q < end && q[0] == '-' {
						q = q[1:]
						t.mark = at(t, q) - 2
						if q < end && q[0] != '>' && (judge_first(t, on, q, end) || report(t, on, q, .Nested_Comment)) { return halt(t, q) }
						in_end = true
					} else {
						t.mark = at(t, q) - 1
						if q >= end { return eof_in_comment(t, on, end) }
					}
				}
			}
		case '-':
			t.mark = at(t, q)
			q = q[1:]
			if q >= end { return eof_in_comment(t, on, end) }
			if q[0] == '-' { q = q[1:]; in_end = true }
		case 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) { return halt(t, q) }
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop { return halt(t, q) }
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_doctype :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	if q >= end { return eof_in_doctype(t, on, end) }
	if CLASS[q[0]] & C_WS != 0 {
		q = skip_ws(q[1:], end)
	} else if q[0] != '>' && (judge_first(t, on, q, end) || report(t, on, q, .Missing_Whitespace_Before_Doctype_Name)) {
		return halt(t, q)
	}
	if q >= end { return eof_in_doctype(t, on, end) }
	if q[0] == '>' {
		t.tok.flags += {.Force_Quirks}
		if report(t, on, q, .Missing_Doctype_Name) || emit(t, on, q[1:]) { return halt(t, q[1:]) }
		return #must_tail st_content(q[1:], end, t, on)
	}
	t.lo, t.flags = at(t, q), {}
	for {
		for q < end && CLASS[q[0]] & (C_WS | C_UPPER | C_JUDGE) == 0 && q[0] != '>' && q[0] != 0 { q = q[1:] }
		if q >= end { t.tok.name = span_of(t, t.lo, at(t, end), .Name, t.flags); return eof_in_doctype(t, on, end) }
		c := q[0]
		switch {
		case CLASS[c] & C_WS != 0:
			t.tok.name = span_of(t, t.lo, at(t, q), .Name, t.flags)
			q = skip_ws(q[1:], end)
			break
		case c == '>':
			t.tok.name = span_of(t, t.lo, at(t, q), .Name, t.flags)
			if emit(t, on, q[1:]) { return halt(t, q[1:]) }
			return #must_tail st_content(q[1:], end, t, on)
		case c == 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) { return halt(t, q) }
			q = q[1:]
			continue
		case CLASS[c] & C_UPPER != 0:
			t.flags += {.Upper}
			q = q[1:]
			continue
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop { return halt(t, q) }
			q = q[n:]
			continue
		}
		break
	}
	if q >= end { return eof_in_doctype(t, on, end) }
	if q[0] == '>' {
		if emit(t, on, q[1:]) { return halt(t, q[1:]) }
		return #must_tail st_content(q[1:], end, t, on)
	}
	bogus := false
	left := int(at(t, end) - at(t, q))
	when STREAM {
		if left < 6 { return stream_pause_tag(t) }
	}
	if left >= 6 && (fold_equal(q, transmute([]u8)string("public")) || fold_equal(q, transmute([]u8)string("system"))) {
		t.system = (q[0] | 0x20) == 's'
		q = q[6:]
		if q >= end { return eof_in_doctype(t, on, end) }
		after_kw := true
		for {
			if after_kw {
				after_kw = false
				if CLASS[q[0]] & C_WS != 0 {
					q = skip_ws(q[1:], end)
					if q >= end { return eof_in_doctype(t, on, end) }
				} else if q[0] == '"' || q[0] == '\'' {
					if report(t, on, q, .Missing_Whitespace_After_Doctype_System_Keyword if t.system else .Missing_Whitespace_After_Doctype_Public_Keyword) { return halt(t, q) }
				} else if q[0] == '>' {
					if doctype_error(t, on, q, end, .Missing_Doctype_System_Identifier if t.system else .Missing_Doctype_Public_Identifier, false) { return halt(t, q) }
					if emit(t, on, q[1:]) { return halt(t, q[1:]) }
					return #must_tail st_content(q[1:], end, t, on)
				} else {
					if doctype_error(t, on, q, end, .Missing_Quote_Before_Doctype_System_Identifier if t.system else .Missing_Quote_Before_Doctype_Public_Identifier, true) { return halt(t, q) }
					bogus = true; break
				}
			}
			if q[0] == '>' {
				if doctype_error(t, on, q, end, .Missing_Doctype_System_Identifier if t.system else .Missing_Doctype_Public_Identifier, false) { return halt(t, q) }
				if emit(t, on, q[1:]) { return halt(t, q[1:]) }
				return #must_tail st_content(q[1:], end, t, on)
			}
			if q[0] != '"' && q[0] != '\'' {
				if doctype_error(t, on, q, end, .Missing_Quote_Before_Doctype_System_Identifier if t.system else .Missing_Quote_Before_Doctype_Public_Identifier, true) { return halt(t, q) }
				bogus = true; break
			}
			open_id(t, q)
			stop: bool
			q, stop = doctype_id(t, on, q[1:], end)
			if stop { return halt(t, q) }
			id := span_of(t, t.lo, at(t, q), .Raw, t.flags)
			if t.system { t.tok.system_id = id } else { t.tok.public_id = id }
			if q >= end { return eof_in_doctype(t, on, end) }
			if q[0] == '>' {
				t.tok.flags += {.Force_Quirks}
				if report(t, on, q, .Abrupt_Doctype_System_Identifier if t.system else .Abrupt_Doctype_Public_Identifier) { return halt(t, q) }
				if emit(t, on, q[1:]) { return halt(t, q[1:]) }
				return #must_tail st_content(q[1:], end, t, on)
			}
			q = q[1:]
			if t.system {
				q = skip_ws(q, end)
				if q >= end { return eof_in_doctype(t, on, end) }
				if q[0] == '>' {
					if emit(t, on, q[1:]) { return halt(t, q[1:]) }
					return #must_tail st_content(q[1:], end, t, on)
				}
				if judge_first(t, on, q, end) || report(t, on, q, .Unexpected_Character_After_Doctype_System_Identifier) { return halt(t, q) }
				bogus = true; break
			}
			if q >= end { return eof_in_doctype(t, on, end) }
			if CLASS[q[0]] & C_WS != 0 {
				q = skip_ws(q[1:], end)
				if q >= end { return eof_in_doctype(t, on, end) }
				if q[0] == '>' {
					if emit(t, on, q[1:]) { return halt(t, q[1:]) }
					return #must_tail st_content(q[1:], end, t, on)
				}
			} else if q[0] == '>' {
				if emit(t, on, q[1:]) { return halt(t, q[1:]) }
				return #must_tail st_content(q[1:], end, t, on)
			} else if q[0] == '"' || q[0] == '\'' {
				if report(t, on, q, .Missing_Whitespace_Between_Doctype_Public_And_System_Identifiers) { return halt(t, q) }
			}
			t.system = true
		}
	} else {
		if doctype_error(t, on, q, end, .Invalid_Character_Sequence_After_Doctype_Name, true) { return halt(t, q) }
		bogus = true
	}
	if bogus {
		for {
			for q < end && q[0] != '>' && q[0] != 0 && CLASS[q[0]] & C_JUDGE == 0 { q = q[1:] }
			if q >= end { return emit_at_end(t, on, end) }
			if q[0] == '>' {
				if emit(t, on, q[1:]) { return halt(t, q[1:]) }
				return #must_tail st_content(q[1:], end, t, on)
			}
			if q[0] == 0 {
				if report(t, on, q, .Unexpected_Null_Character) { return halt(t, q) }
				q = q[1:]
			} else {
				scratch: Span_Flags
				n, stop := judge(t, on, q, end, &scratch)
				if stop { return halt(t, q) }
				q = q[n:]
			}
		}
	}
	return #must_tail st_content(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_cdata :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_CDATA)
		if q >= end {
			when STREAM {
				safe_hi := at(t, end)
				if safe_hi > t.text_lo && t.base[safe_hi - 1] == '\r' {
					safe_hi -= 1
				}
				return stream_pause_at_text(t, on, safe_hi)
			}
			return eof_error(t, on, end, .Eof_In_Cdata)
		}
		switch q[0] {
		case ']':
			t.mark = at(t, q)
			q = q[1:]
			when STREAM {
				if q >= end { return stream_pause_at_text(t, on, t.mark) }
			}
			if q < end && q[0] == ']' {
				q = q[1:]
				for q < end && q[0] == ']' { t.mark += 1; q = q[1:] }
				when STREAM {
					if q >= end { return stream_pause_at_text(t, on, t.mark) }
				}
				if q < end && q[0] == '>' {
					if flush(t, on, t.mark, at(t, q) + 1) { return halt(t, q[1:]) }
					t.content, t.text_mode = .Data, .Data
					return #must_tail st_data(q[1:], end, t, on)
				}
			}
		case 0:
			t.text_flags += {.Nul}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.text_flags)
			if stop {
				when STREAM {
					if t.need_more { return stream_pause_at_text(t, on, at(t, q)) }
				}
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_pi :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end { return eof_in_pi(t, on, end) }
	if CLASS[p[0]] & C_ALPHA == 0 && p[0] != '_' {
		if judge_first(t, on, p, end) || report(t, on, p, .Invalid_First_Character_Of_Processing_Instruction_Target) { return halt(t, p) }
		open_comment(t, t.tok.lo, t.base[t.mark:])
		return #must_tail st_bogus_comment(p, end, t, on)
	}
	t.lo = at(t, p)
	q := p
	for q < end && (CLASS[q[0]] & C_ALNUM != 0 || q[0] == '-' || q[0] == '_') { q = q[1:] }
	if q >= end { return eof_in_pi(t, on, end) }
	c := q[0]
	if CLASS[c] & C_WS == 0 && c != '?' && c != '>' {
		if judge_first(t, on, q, end) || report(t, on, q, .Invalid_Processing_Instruction_Target) { return halt(t, q) }
		open_comment(t, t.tok.lo, t.base[t.mark:])
		return #must_tail st_bogus_comment(q, end, t, on)
	}
	n := int(at(t, q) - t.lo)
	target := t.base[t.lo:]
	if (n == 3 && fold_equal(target, transmute([]u8)string("xml"))) || (n == 14 && fold_equal(target, transmute([]u8)string("xml-stylesheet"))) {
		if report(t, on, q, .Disallowed_Processing_Instruction_Target) { return halt(t, q) }
		open_comment(t, t.tok.lo, t.base[t.mark:])
		return #must_tail st_bogus_comment(q, end, t, on)
	}
	t.tok.name = span_of(t, t.lo, at(t, q), .Verbatim, {})
	q = skip_ws(q, end)
	t.lo, t.flags = at(t, q), {}
	for {
		q = stop_at(q, end, STOP_PI)
		if q >= end { return eof_in_pi(t, on, end) }
		switch q[0] {
		case '?':
			t.mark = at(t, q)
			q = q[1:]
			if q >= end { return eof_in_pi(t, on, end) }
			if q[0] == '>' {
				t.tok.data = span_of(t, t.lo, t.mark, .Verbatim, t.flags)
				if emit(t, on, q[1:]) { return halt(t, q[1:]) }
				return #must_tail st_content(q[1:], end, t, on)
			}
		case '>':
			t.tok.data = span_of(t, t.lo, at(t, q), .Verbatim, t.flags)
			if emit(t, on, q[1:]) { return halt(t, q[1:]) }
			return #must_tail st_content(q[1:], end, t, on)
		case:
			step_n, stop := judge(t, on, q, end, &t.flags)
			if stop { return halt(t, q) }
			q = q[step_n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_char_ref :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	attr := t.ret >= .Double
	when STREAM {
		if !ref_complete(p, end) {
			if !attr { return stream_pause_at_text(t, on, at(t, p)) }
			return stream_pause_tag(t)
		}
	}
	r := read_ref(p, end, attr)
	if attr { t.flags += {.Ref} } else { t.text_flags += {.Ref} }
	for i in 0 ..< 2 {
		if r.errors[i] != .None && report(t, on, r.err_at[i], r.errors[i]) { return halt(t, r.q) }
	}
	switch t.ret {
	case .Data:     return #must_tail st_data(r.q, end, t, on)
	case .Rcdata:   return #must_tail st_rcdata(r.q, end, t, on)
	case .Double:   return #must_tail st_attr_value_double(r.q, end, t, on)
	case .Single:   return #must_tail st_attr_value_single(r.q, end, t, on)
	case .Unquoted: return #must_tail st_attr_value_unquoted(r.q, end, t, on)
	}
	return #must_tail st_data(r.q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_content :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	switch t.content {
	case .Data:          return #must_tail st_data(p, end, t, on)
	case .Rcdata:        return #must_tail st_rcdata(p, end, t, on)
	case .Rawtext:       return #must_tail st_rawtext(p, end, t, on)
	case .Script_Data:   return #must_tail st_script(p, end, t, on)
	case .Plaintext:     return #must_tail st_plaintext(p, end, t, on)
	case .Cdata_Section: return #must_tail st_cdata(p, end, t, on)
	}
	return #must_tail st_data(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_back :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H, $STREAM), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	switch t.back {
	case .Rcdata:  return #must_tail st_rcdata(p, end, t, on)
	case .Rawtext: return #must_tail st_rawtext(p, end, t, on)
	case .Script:  return #must_tail st_script(p, end, t, on)
	case .Escaped: return #must_tail st_script_escaped(p, end, t, on)
	}
	return #must_tail st_script_escaped(p, end, t, on)
}
