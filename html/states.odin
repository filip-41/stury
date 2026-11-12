package html

// The tokenizer's states, in the standard's order, each a procedure that tail-calls the next. Every state takes
// these arguments: `p` is the next input character, `end` one past the text, `t` the tokenizer, and `on` the hook. A
// state that stays in itself loops. The four end tag open states of RCDATA, RAWTEXT, script data and escaped script
// data are one procedure, and their end tag name states another, which return to `t.back`. The quoted DOCTYPE
// identifier states share a procedure per identifier and read their quote from `t.quote`. The character reference
// states are `read_ref` (refs.odin).

@(private, enable_target_feature = STATE_FEATURES)
st_data :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_DATA)
		if q >= end {
			return finish(t, on, end, at(t, end))
		}
		switch q[0] {
		case '<':
			t.text_hi = at(t, q)
			return #must_tail st_tag_open(q[1:], end, t, on)
		case '&':
			t.ret = .Data
			return #must_tail st_char_ref(q, end, t, on)
		case 0:
			t.text_flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.text_flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_rcdata :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_DATA)
		if q >= end {
			return finish(t, on, end, at(t, end))
		}
		switch q[0] {
		case '<':
			t.text_hi = at(t, q)
			return #must_tail st_rcdata_lt(q[1:], end, t, on)
		case '&':
			t.ret = .Rcdata
			return #must_tail st_char_ref(q, end, t, on)
		case 0:
			t.text_flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.text_flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_rawtext :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_RAW)
		if q >= end {
			return finish(t, on, end, at(t, end))
		}
		switch q[0] {
		case '<':
			t.text_hi = at(t, q)
			return #must_tail st_rawtext_lt(q[1:], end, t, on)
		case 0:
			t.text_flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.text_flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_script :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_RAW)
		if q >= end {
			return finish(t, on, end, at(t, end))
		}
		switch q[0] {
		case '<':
			t.text_hi = at(t, q)
			return #must_tail st_script_lt(q[1:], end, t, on)
		case 0:
			t.text_flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.text_flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_plaintext :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_PLAIN)
		if q >= end {
			return finish(t, on, end, at(t, end))
		}
		if q[0] == 0 {
			t.text_flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
			continue
		}
		n, stop := judge(t, on, q, end, &t.text_flags)
		if stop {
			return halt(t, q)
		}
		q = q[n:]
	}
}

// `p` is past a `<` of the data state.
@(private, enable_target_feature = STATE_FEATURES)
st_tag_open :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		if report(t, on, end, .Eof_Before_Tag_Name) {
			return halt(t, end)
		}
		return finish(t, on, end, at(t, end))
	}
	c := p[0]
	switch {
	case c == '!':
		return #must_tail st_markup_open(p[1:], end, t, on)
	case c == '/':
		return #must_tail st_end_tag_open(p[1:], end, t, on)
	case CLASS[c] & C_ALPHA != 0:
		open_tag(t, .Start_Tag, at(t, p) - 1, p)
		return #must_tail st_tag_name(p, end, t, on)
	case c == '?':
		t.tok = Html_Token{kind = .Instruction, lo = at(t, p) - 1}
		t.mark = at(t, p)
		return #must_tail st_pi_open(p[1:], end, t, on)
	}
	if judge_first(t, on, p, end) || report(t, on, p, .Invalid_First_Character_Of_Tag_Name) {
		return halt(t, p)
	}
	return #must_tail st_data(p, end, t, on)
}

// `p` is past `</` of the data state.
@(private, enable_target_feature = STATE_FEATURES)
st_end_tag_open :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		if report(t, on, end, .Eof_Before_Tag_Name) {
			return halt(t, end)
		}
		return finish(t, on, end, at(t, end))
	}
	c := p[0]
	if CLASS[c] & C_ALPHA != 0 {
		open_tag(t, .End_Tag, at(t, p) - 2, p)
		return #must_tail st_tag_name(p, end, t, on)
	}
	if c == '>' {
		if report(t, on, p, .Missing_End_Tag_Name) || flush(t, on, t.text_hi, at(t, p) + 1) {
			return halt(t, p[1:])
		}
		return #must_tail st_data(p[1:], end, t, on)
	}
	if judge_first(t, on, p, end) || report(t, on, p, .Invalid_First_Character_Of_Tag_Name) {
		return halt(t, p)
	}
	open_comment(t, at(t, p) - 2, p)
	return #must_tail st_bogus_comment(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_tag_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		for q < end && CLASS[q[0]] & (C_WS | C_UPPER | C_JUDGE | C_TAG_END) == 0 {
			q = q[1:]
		}
		if q >= end {
			return eof_in_tag(t, on, end)
		}
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
			if emit_tag(t, on, q) {
				return halt(t, q[1:])
			}
			return #must_tail st_content(q[1:], end, t, on)
		case c == 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case CLASS[c] & C_UPPER != 0:
			t.flags += {.Upper}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

// `p` is past a `<` of the RCDATA state.
@(private, enable_target_feature = STATE_FEATURES)
st_rcdata_lt :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end && p[0] == '/' {
		t.back = .Rcdata
		return #must_tail st_text_end_open(p[1:], end, t, on)
	}
	return #must_tail st_rcdata(p, end, t, on)
}

// The end tag open state of RCDATA, RAWTEXT, script data and escaped script data. `p` is past `</`.
@(private, enable_target_feature = STATE_FEATURES)
st_text_end_open :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end && CLASS[p[0]] & C_ALPHA != 0 {
		open_tag(t, .End_Tag, at(t, p) - 2, p)
		return #must_tail st_text_end_name(p, end, t, on)
	}
	return #must_tail st_back(p, end, t, on)
}

// The end tag name state of RCDATA, RAWTEXT, script data and escaped script data. The temporary buffer is the name's
// bytes, from `t.lo`. A name that is no appropriate end tag stays text.
@(private, enable_target_feature = STATE_FEATURES)
st_text_end_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for q < end && CLASS[q[0]] & C_ALPHA != 0 {
		if CLASS[q[0]] & C_UPPER != 0 {
			t.flags += {.Upper}
		}
		q = q[1:]
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
			if emit_tag(t, on, q) {
				return halt(t, q[1:])
			}
			return #must_tail st_content(q[1:], end, t, on)
		}
	}
	return #must_tail st_back(q, end, t, on)
}

// `p` is past a `<` of the RAWTEXT state.
@(private, enable_target_feature = STATE_FEATURES)
st_rawtext_lt :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end && p[0] == '/' {
		t.back = .Rawtext
		return #must_tail st_text_end_open(p[1:], end, t, on)
	}
	return #must_tail st_rawtext(p, end, t, on)
}

// `p` is past a `<` of the script data state.
@(private, enable_target_feature = STATE_FEATURES)
st_script_lt :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end {
		switch p[0] {
		case '/':
			t.back = .Script
			return #must_tail st_text_end_open(p[1:], end, t, on)
		case '!':
			return #must_tail st_script_escape_start(p[1:], end, t, on)
		}
	}
	return #must_tail st_script(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_script_escape_start :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end && p[0] == '-' {
		return #must_tail st_script_escape_start_dash(p[1:], end, t, on)
	}
	return #must_tail st_script(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_script_escape_start_dash :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end && p[0] == '-' {
		return #must_tail st_script_escaped_dash_dash(p[1:], end, t, on)
	}
	return #must_tail st_script(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_script_escaped :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_DASH)
		if q >= end {
			return eof_in_script_comment(t, on, end)
		}
		switch q[0] {
		case '-':
			return #must_tail st_script_escaped_dash(q[1:], end, t, on)
		case '<':
			t.text_hi = at(t, q)
			return #must_tail st_script_escaped_lt(q[1:], end, t, on)
		case 0:
			t.text_flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.text_flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_script_escaped_dash :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_script_comment(t, on, end)
	}
	switch p[0] {
	case '-':
		return #must_tail st_script_escaped_dash_dash(p[1:], end, t, on)
	case '<':
		t.text_hi = at(t, p)
		return #must_tail st_script_escaped_lt(p[1:], end, t, on)
	}
	return #must_tail st_script_escaped(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_script_escaped_dash_dash :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for q < end && q[0] == '-' {
		q = q[1:]
	}
	if q >= end {
		return eof_in_script_comment(t, on, end)
	}
	switch q[0] {
	case '<':
		t.text_hi = at(t, q)
		return #must_tail st_script_escaped_lt(q[1:], end, t, on)
	case '>':
		return #must_tail st_script(q[1:], end, t, on)
	}
	return #must_tail st_script_escaped(q, end, t, on)
}

// `p` is past a `<` of the escaped script data states.
@(private, enable_target_feature = STATE_FEATURES)
st_script_escaped_lt :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end {
		if p[0] == '/' {
			t.back = .Escaped
			return #must_tail st_text_end_open(p[1:], end, t, on)
		}
		if CLASS[p[0]] & C_ALPHA != 0 {
			t.mark = at(t, p)
			return #must_tail st_script_double_escape_start(p, end, t, on)
		}
	}
	return #must_tail st_script_escaped(p, end, t, on)
}

// The temporary buffer is the letters from `t.mark`.
@(private, enable_target_feature = STATE_FEATURES)
st_script_double_escape_start :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for q < end && CLASS[q[0]] & C_ALPHA != 0 {
		q = q[1:]
	}
	if q < end && (CLASS[q[0]] & C_WS != 0 || q[0] == '/' || q[0] == '>') {
		if q[0] == '\r' {
			t.text_flags += {.Cr}
		}
		if is_script(t, q) {
			return #must_tail st_script_double_escaped(q[1:], end, t, on)
		}
		return #must_tail st_script_escaped(q[1:], end, t, on)
	}
	return #must_tail st_script_escaped(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_script_double_escaped :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_DASH)
		if q >= end {
			return eof_in_script_comment(t, on, end)
		}
		switch q[0] {
		case '-':
			return #must_tail st_script_double_escaped_dash(q[1:], end, t, on)
		case '<':
			return #must_tail st_script_double_escaped_lt(q[1:], end, t, on)
		case 0:
			t.text_flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.text_flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_script_double_escaped_dash :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_script_comment(t, on, end)
	}
	switch p[0] {
	case '-':
		return #must_tail st_script_double_escaped_dash_dash(p[1:], end, t, on)
	case '<':
		return #must_tail st_script_double_escaped_lt(p[1:], end, t, on)
	}
	return #must_tail st_script_double_escaped(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_script_double_escaped_dash_dash :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for q < end && q[0] == '-' {
		q = q[1:]
	}
	if q >= end {
		return eof_in_script_comment(t, on, end)
	}
	switch q[0] {
	case '<':
		return #must_tail st_script_double_escaped_lt(q[1:], end, t, on)
	case '>':
		return #must_tail st_script(q[1:], end, t, on)
	}
	return #must_tail st_script_double_escaped(q, end, t, on)
}

// `p` is past a `<` of the double escaped script data states.
@(private, enable_target_feature = STATE_FEATURES)
st_script_double_escaped_lt :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end && p[0] == '/' {
		t.mark = at(t, p) + 1
		return #must_tail st_script_double_escape_end(p[1:], end, t, on)
	}
	return #must_tail st_script_double_escaped(p, end, t, on)
}

// The temporary buffer is the letters from `t.mark`.
@(private, enable_target_feature = STATE_FEATURES)
st_script_double_escape_end :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for q < end && CLASS[q[0]] & C_ALPHA != 0 {
		q = q[1:]
	}
	if q < end && (CLASS[q[0]] & C_WS != 0 || q[0] == '/' || q[0] == '>') {
		if q[0] == '\r' {
			t.text_flags += {.Cr}
		}
		if is_script(t, q) {
			return #must_tail st_script_escaped(q[1:], end, t, on)
		}
		return #must_tail st_script_double_escaped(q[1:], end, t, on)
	}
	return #must_tail st_script_double_escaped(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_before_attr_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	if q >= end || q[0] == '/' || q[0] == '>' {
		return #must_tail st_after_attr_name(q, end, t, on)
	}
	open_attr(t, q)
	if q[0] == '=' {
		if report(t, on, q, .Unexpected_Equals_Sign_Before_Attribute_Name) {
			return halt(t, q)
		}
		return #must_tail st_attr_name(q[1:], end, t, on)
	}
	return #must_tail st_attr_name(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_attr_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		for q < end && CLASS[q[0]] & (C_WS | C_UPPER | C_JUDGE | C_TAG_END | C_ATTR_END) == 0 {
			q = q[1:]
		}
		c := q[0] if q < end else '>'
		switch {
		case q >= end || CLASS[c] & C_WS != 0 || c == '/' || c == '>':
			if end_attr_name(t, on, q) {
				return halt(t, q)
			}
			return #must_tail st_after_attr_name(q, end, t, on)
		case c == '=':
			if end_attr_name(t, on, q) {
				return halt(t, q)
			}
			return #must_tail st_before_attr_value(q[1:], end, t, on)
		case CLASS[c] & C_UPPER != 0:
			t.flags += {.Upper}
			q = q[1:]
		case c == 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case c == '"' || c == '\'' || c == '<':
			if report(t, on, q, .Unexpected_Character_In_Attribute_Name) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_after_attr_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	if q >= end {
		return eof_in_tag(t, on, end)
	}
	switch q[0] {
	case '/':
		return #must_tail st_self_closing(q[1:], end, t, on)
	case '=':
		return #must_tail st_before_attr_value(q[1:], end, t, on)
	case '>':
		if emit_tag(t, on, q) {
			return halt(t, q[1:])
		}
		return #must_tail st_content(q[1:], end, t, on)
	}
	open_attr(t, q)
	return #must_tail st_attr_name(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_before_attr_value :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
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
			if report(t, on, q, .Missing_Attribute_Value) || emit_tag(t, on, q) {
				return halt(t, q[1:])
			}
			return #must_tail st_content(q[1:], end, t, on)
		}
	}
	open_attr(t, q)
	return #must_tail st_attr_value_unquoted(q, end, t, on)
}

// `t.lo` is where the value starts, and `p` where the state resumes.
@(private, enable_target_feature = STATE_FEATURES)
st_attr_value_double :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_DOUBLE)
		if q >= end {
			return eof_in_tag(t, on, end)
		}
		switch q[0] {
		case '"':
			end_value(t, q)
			return #must_tail st_after_attr_value(q[1:], end, t, on)
		case '&':
			t.ret = .Double
			return #must_tail st_char_ref(q, end, t, on)
		case 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_attr_value_single :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_SINGLE)
		if q >= end {
			return eof_in_tag(t, on, end)
		}
		switch q[0] {
		case '\'':
			end_value(t, q)
			return #must_tail st_after_attr_value(q[1:], end, t, on)
		case '&':
			t.ret = .Single
			return #must_tail st_char_ref(q, end, t, on)
		case 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_attr_value_unquoted :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		if q >= end {
			return eof_in_tag(t, on, end)
		}
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
			if emit_tag(t, on, q) {
				return halt(t, q[1:])
			}
			return #must_tail st_content(q[1:], end, t, on)
		case c == 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case c == '"' || c == '\'' || c == '<' || c == '=' || c == '`':
			if report(t, on, q, .Unexpected_Character_In_Unquoted_Attribute_Value) {
				return halt(t, q)
			}
			q = q[1:]
		case CLASS[c] & C_JUDGE != 0:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		case:
			q = q[1:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_after_attr_value :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_tag(t, on, end)
	}
	switch {
	case CLASS[p[0]] & C_WS != 0:
		return #must_tail st_before_attr_name(p[1:], end, t, on)
	case p[0] == '/':
		return #must_tail st_self_closing(p[1:], end, t, on)
	case p[0] == '>':
		if emit_tag(t, on, p) {
			return halt(t, p[1:])
		}
		return #must_tail st_content(p[1:], end, t, on)
	}
	if judge_first(t, on, p, end) || report(t, on, p, .Missing_Whitespace_Between_Attributes) {
		return halt(t, p)
	}
	return #must_tail st_before_attr_name(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_self_closing :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_tag(t, on, end)
	}
	if p[0] == '>' {
		t.tok.flags += {.Self_Closing}
		if emit_tag(t, on, p) {
			return halt(t, p[1:])
		}
		return #must_tail st_content(p[1:], end, t, on)
	}
	if judge_first(t, on, p, end) || report(t, on, p, .Unexpected_Solidus_In_Tag) {
		return halt(t, p)
	}
	return #must_tail st_before_attr_name(p, end, t, on)
}

// The comment's data starts at `t.lo`.
@(private, enable_target_feature = STATE_FEATURES)
st_bogus_comment :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
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
			if emit(t, on, q[1:]) {
				return halt(t, q[1:])
			}
			return #must_tail st_content(q[1:], end, t, on)
		case 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

// `p` is past `<!`.
@(private, enable_target_feature = STATE_FEATURES)
st_markup_open :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	left := int(at(t, end) - at(t, p))
	lo := at(t, p) - 2
	if left >= 2 && p[0] == '-' && p[1] == '-' {
		open_comment(t, lo, p[2:])
		return #must_tail st_comment_start(p[2:], end, t, on)
	}
	if left >= 7 && fold_equal(p, transmute([]u8)string("doctype")) {
		missing := Span{flags = {.Missing}}
		t.tok = Html_Token{kind = .Doctype, lo = lo, name = missing, public_id = missing, system_id = missing}
		return #must_tail st_doctype(p[7:], end, t, on)
	}
	if left >= 7 && string(p[:7]) == "[CDATA[" {
		// The text before is the tree's first, since it can move the adjusted current node into or out of foreign content.
		if flush(t, on, t.text_hi, at(t, p) + 7) {
			return halt(t, p[7:])
		}
		if t.in_foreign {
			t.text_mode = .Verbatim
			return #must_tail st_cdata(p[7:], end, t, on)
		}
		if report(t, on, p[6:], .Cdata_In_Html_Content) {
			return halt(t, p[7:])
		}
		open_comment(t, lo, p)
		return #must_tail st_bogus_comment(p[7:], end, t, on)
	}
	if judge_first(t, on, p, end) || report(t, on, p, .Incorrectly_Opened_Comment) {
		return halt(t, p)
	}
	open_comment(t, lo, p)
	return #must_tail st_bogus_comment(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_comment_start :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end {
		switch p[0] {
		case '-':
			return #must_tail st_comment_start_dash(p[1:], end, t, on)
		case '>':
			return #must_tail st_empty_comment(p, end, t, on)
		}
	}
	return #must_tail st_comment(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_comment_start_dash :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		t.mark = t.lo
		return eof_in_comment(t, on, end)
	}
	switch p[0] {
	case '-':
		t.mark = t.lo
		return #must_tail st_comment_end(p[1:], end, t, on)
	case '>':
		return #must_tail st_empty_comment(p, end, t, on)
	}
	return #must_tail st_comment(p, end, t, on)
}

// `<!-->` and `<!--->`: `p` is at the `>`.
@(private, enable_target_feature = STATE_FEATURES)
st_empty_comment :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	t.tok.data = span_of(t, t.lo, t.lo, .Raw, {})
	if report(t, on, p, .Abrupt_Closing_Of_Empty_Comment) || emit(t, on, p[1:]) {
		return halt(t, p[1:])
	}
	return #must_tail st_content(p[1:], end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_comment :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_DASH)
		if q >= end {
			t.mark = at(t, end)
			return eof_in_comment(t, on, end)
		}
		switch q[0] {
		case '<':
			return #must_tail st_comment_lt(q[1:], end, t, on)
		case '-':
			t.mark = at(t, q)
			return #must_tail st_comment_end_dash(q[1:], end, t, on)
		case 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

// `p` is past a `<` of the comment.
@(private, enable_target_feature = STATE_FEATURES)
st_comment_lt :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for q < end && q[0] == '<' {
		q = q[1:]
	}
	if q < end && q[0] == '!' {
		return #must_tail st_comment_lt_bang(q[1:], end, t, on)
	}
	return #must_tail st_comment(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_comment_lt_bang :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end && p[0] == '-' {
		return #must_tail st_comment_lt_bang_dash(p[1:], end, t, on)
	}
	return #must_tail st_comment(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_comment_lt_bang_dash :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end && p[0] == '-' {
		return #must_tail st_comment_lt_bang_dash_dash(p[1:], end, t, on)
	}
	t.mark = at(t, p) - 1
	return #must_tail st_comment_end_dash(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_comment_lt_bang_dash_dash :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	t.mark = at(t, p) - 2
	if p < end && p[0] != '>' {
		if judge_first(t, on, p, end) || report(t, on, p, .Nested_Comment) {
			return halt(t, p)
		}
	}
	return #must_tail st_comment_end(p, end, t, on)
}

// A `-` at `t.mark` may start the comment's end.
@(private, enable_target_feature = STATE_FEATURES)
st_comment_end_dash :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_comment(t, on, end)
	}
	if p[0] == '-' {
		return #must_tail st_comment_end(p[1:], end, t, on)
	}
	return #must_tail st_comment(p, end, t, on)
}

// `--` from `t.mark` may end the comment.
@(private, enable_target_feature = STATE_FEATURES)
st_comment_end :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for q < end && q[0] == '-' {
		t.mark += 1
		q = q[1:]
	}
	if q >= end {
		return eof_in_comment(t, on, end)
	}
	switch q[0] {
	case '>':
		t.tok.data = span_of(t, t.lo, t.mark, .Raw, t.flags)
		if emit(t, on, q[1:]) {
			return halt(t, q[1:])
		}
		return #must_tail st_content(q[1:], end, t, on)
	case '!':
		return #must_tail st_comment_end_bang(q[1:], end, t, on)
	}
	return #must_tail st_comment(q, end, t, on)
}

// `--!` from `t.mark` may end the comment.
@(private, enable_target_feature = STATE_FEATURES)
st_comment_end_bang :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_comment(t, on, end)
	}
	switch p[0] {
	case '-':
		t.mark = at(t, p)
		return #must_tail st_comment_end_dash(p[1:], end, t, on)
	case '>':
		t.tok.data = span_of(t, t.lo, t.mark, .Raw, t.flags)
		if report(t, on, p, .Incorrectly_Closed_Comment) || emit(t, on, p[1:]) {
			return halt(t, p[1:])
		}
		return #must_tail st_content(p[1:], end, t, on)
	}
	return #must_tail st_comment(p, end, t, on)
}

// `p` is past `<!DOCTYPE`.
@(private, enable_target_feature = STATE_FEATURES)
st_doctype :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_doctype(t, on, end)
	}
	if CLASS[p[0]] & C_WS != 0 {
		return #must_tail st_before_doctype_name(p[1:], end, t, on)
	}
	if p[0] != '>' && (judge_first(t, on, p, end) || report(t, on, p, .Missing_Whitespace_Before_Doctype_Name)) {
		return halt(t, p)
	}
	return #must_tail st_before_doctype_name(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_before_doctype_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	if q >= end {
		return eof_in_doctype(t, on, end)
	}
	if q[0] == '>' {
		t.tok.flags += {.Force_Quirks}
		if report(t, on, q, .Missing_Doctype_Name) || emit(t, on, q[1:]) {
			return halt(t, q[1:])
		}
		return #must_tail st_content(q[1:], end, t, on)
	}
	t.lo = at(t, q)
	t.flags = {}
	return #must_tail st_doctype_name(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_doctype_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		for q < end && CLASS[q[0]] & (C_WS | C_UPPER | C_JUDGE) == 0 && q[0] != '>' && q[0] != 0 {
			q = q[1:]
		}
		if q >= end {
			t.tok.name = span_of(t, t.lo, at(t, end), .Name, t.flags)
			return eof_in_doctype(t, on, end)
		}
		c := q[0]
		switch {
		case CLASS[c] & C_WS != 0:
			t.tok.name = span_of(t, t.lo, at(t, q), .Name, t.flags)
			return #must_tail st_after_doctype_name(q[1:], end, t, on)
		case c == '>':
			t.tok.name = span_of(t, t.lo, at(t, q), .Name, t.flags)
			if emit(t, on, q[1:]) {
				return halt(t, q[1:])
			}
			return #must_tail st_content(q[1:], end, t, on)
		case c == 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case CLASS[c] & C_UPPER != 0:
			t.flags += {.Upper}
			q = q[1:]
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_after_doctype_name :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	if q >= end {
		return eof_in_doctype(t, on, end)
	}
	if q[0] == '>' {
		return #must_tail st_doctype_close(q, end, t, on)
	}
	left := int(at(t, end) - at(t, q))
	if left >= 6 && fold_equal(q, transmute([]u8)string("public")) {
		return #must_tail st_after_doctype_public_keyword(q[6:], end, t, on)
	}
	if left >= 6 && fold_equal(q, transmute([]u8)string("system")) {
		return #must_tail st_after_doctype_system_keyword(q[6:], end, t, on)
	}
	if doctype_error(t, on, q, end, .Invalid_Character_Sequence_After_Doctype_Name, true) {
		return halt(t, q)
	}
	return #must_tail st_bogus_doctype(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_after_doctype_public_keyword :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_doctype(t, on, end)
	}
	switch {
	case CLASS[p[0]] & C_WS != 0:
		return #must_tail st_before_doctype_public_id(p[1:], end, t, on)
	case p[0] == '"' || p[0] == '\'':
		if report(t, on, p, .Missing_Whitespace_After_Doctype_Public_Keyword) {
			return halt(t, p)
		}
		open_id(t, p)
		return #must_tail st_doctype_public_id(p[1:], end, t, on)
	case p[0] == '>':
		if doctype_error(t, on, p, end, .Missing_Doctype_Public_Identifier, false) {
			return halt(t, p)
		}
		return #must_tail st_doctype_close(p, end, t, on)
	}
	if doctype_error(t, on, p, end, .Missing_Quote_Before_Doctype_Public_Identifier, true) {
		return halt(t, p)
	}
	return #must_tail st_bogus_doctype(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_before_doctype_public_id :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	if q >= end {
		return eof_in_doctype(t, on, end)
	}
	switch q[0] {
	case '"', '\'':
		open_id(t, q)
		return #must_tail st_doctype_public_id(q[1:], end, t, on)
	case '>':
		if doctype_error(t, on, q, end, .Missing_Doctype_Public_Identifier, false) {
			return halt(t, q)
		}
		return #must_tail st_doctype_close(q, end, t, on)
	}
	if doctype_error(t, on, q, end, .Missing_Quote_Before_Doctype_Public_Identifier, true) {
		return halt(t, q)
	}
	return #must_tail st_bogus_doctype(q, end, t, on)
}

// The DOCTYPE public identifier states, double- and single-quoted. The identifier starts at `t.lo`.
@(private, enable_target_feature = STATE_FEATURES)
st_doctype_public_id :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q, stop := doctype_id(t, on, p, end)
	if stop {
		return halt(t, q)
	}
	t.tok.public_id = span_of(t, t.lo, at(t, q), .Raw, t.flags)
	if q >= end {
		return eof_in_doctype(t, on, end)
	}
	if q[0] == '>' {
		t.tok.flags += {.Force_Quirks}
		if report(t, on, q, .Abrupt_Doctype_Public_Identifier) {
			return halt(t, q)
		}
		return #must_tail st_doctype_close(q, end, t, on)
	}
	return #must_tail st_after_doctype_public_id(q[1:], end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_after_doctype_public_id :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_doctype(t, on, end)
	}
	switch {
	case CLASS[p[0]] & C_WS != 0:
		return #must_tail st_between_doctype_ids(p[1:], end, t, on)
	case p[0] == '>':
		return #must_tail st_doctype_close(p, end, t, on)
	case p[0] == '"' || p[0] == '\'':
		if report(t, on, p, .Missing_Whitespace_Between_Doctype_Public_And_System_Identifiers) {
			return halt(t, p)
		}
		open_id(t, p)
		return #must_tail st_doctype_system_id(p[1:], end, t, on)
	}
	if doctype_error(t, on, p, end, .Missing_Quote_Before_Doctype_System_Identifier, true) {
		return halt(t, p)
	}
	return #must_tail st_bogus_doctype(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_between_doctype_ids :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	if q >= end {
		return eof_in_doctype(t, on, end)
	}
	switch q[0] {
	case '>':
		return #must_tail st_doctype_close(q, end, t, on)
	case '"', '\'':
		open_id(t, q)
		return #must_tail st_doctype_system_id(q[1:], end, t, on)
	}
	if doctype_error(t, on, q, end, .Missing_Quote_Before_Doctype_System_Identifier, true) {
		return halt(t, q)
	}
	return #must_tail st_bogus_doctype(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_after_doctype_system_keyword :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_doctype(t, on, end)
	}
	switch {
	case CLASS[p[0]] & C_WS != 0:
		return #must_tail st_before_doctype_system_id(p[1:], end, t, on)
	case p[0] == '"' || p[0] == '\'':
		if report(t, on, p, .Missing_Whitespace_After_Doctype_System_Keyword) {
			return halt(t, p)
		}
		open_id(t, p)
		return #must_tail st_doctype_system_id(p[1:], end, t, on)
	case p[0] == '>':
		if doctype_error(t, on, p, end, .Missing_Doctype_System_Identifier, false) {
			return halt(t, p)
		}
		return #must_tail st_doctype_close(p, end, t, on)
	}
	if doctype_error(t, on, p, end, .Missing_Quote_Before_Doctype_System_Identifier, true) {
		return halt(t, p)
	}
	return #must_tail st_bogus_doctype(p, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_before_doctype_system_id :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	if q >= end {
		return eof_in_doctype(t, on, end)
	}
	switch q[0] {
	case '"', '\'':
		open_id(t, q)
		return #must_tail st_doctype_system_id(q[1:], end, t, on)
	case '>':
		if doctype_error(t, on, q, end, .Missing_Doctype_System_Identifier, false) {
			return halt(t, q)
		}
		return #must_tail st_doctype_close(q, end, t, on)
	}
	if doctype_error(t, on, q, end, .Missing_Quote_Before_Doctype_System_Identifier, true) {
		return halt(t, q)
	}
	return #must_tail st_bogus_doctype(q, end, t, on)
}

// The DOCTYPE system identifier states, double- and single-quoted. The identifier starts at `t.lo`.
@(private, enable_target_feature = STATE_FEATURES)
st_doctype_system_id :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q, stop := doctype_id(t, on, p, end)
	if stop {
		return halt(t, q)
	}
	t.tok.system_id = span_of(t, t.lo, at(t, q), .Raw, t.flags)
	if q >= end {
		return eof_in_doctype(t, on, end)
	}
	if q[0] == '>' {
		t.tok.flags += {.Force_Quirks}
		if report(t, on, q, .Abrupt_Doctype_System_Identifier) {
			return halt(t, q)
		}
		return #must_tail st_doctype_close(q, end, t, on)
	}
	return #must_tail st_after_doctype_system_id(q[1:], end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_after_doctype_system_id :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	if q >= end {
		return eof_in_doctype(t, on, end)
	}
	if q[0] == '>' {
		return #must_tail st_doctype_close(q, end, t, on)
	}
	if judge_first(t, on, q, end) || report(t, on, q, .Unexpected_Character_After_Doctype_System_Identifier) {
		return halt(t, q)
	}
	return #must_tail st_bogus_doctype(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_bogus_doctype :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		for q < end && q[0] != '>' && q[0] != 0 && CLASS[q[0]] & C_JUDGE == 0 {
			q = q[1:]
		}
		if q >= end {
			return emit_at_end(t, on, end)
		}
		switch q[0] {
		case '>':
			return #must_tail st_doctype_close(q, end, t, on)
		case 0:
			if report(t, on, q, .Unexpected_Null_Character) {
				return halt(t, q)
			}
			q = q[1:]
		case:
			scratch: Span_Flags
			n, stop := judge(t, on, q, end, &scratch)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

// The DOCTYPE's `>` is at `p`.
@(private, enable_target_feature = STATE_FEATURES)
st_doctype_close :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if emit(t, on, p[1:]) {
		return halt(t, p[1:])
	}
	return #must_tail st_content(p[1:], end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_cdata :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_CDATA)
		if q >= end {
			if report(t, on, end, .Eof_In_Cdata) {
				return halt(t, end)
			}
			return finish(t, on, end, at(t, end))
		}
		switch q[0] {
		case ']':
			t.mark = at(t, q)
			return #must_tail st_cdata_bracket(q[1:], end, t, on)
		case 0:
			// The tree, not the tokenizer, reports a U+0000 of a CDATA section.
			t.text_flags += {.Nul}
			q = q[1:]
			continue
		}
		n, stop := judge(t, on, q, end, &t.text_flags)
		if stop {
			return halt(t, q)
		}
		q = q[n:]
	}
}

@(private, enable_target_feature = STATE_FEATURES)
st_cdata_bracket :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p < end && p[0] == ']' {
		return #must_tail st_cdata_end(p[1:], end, t, on)
	}
	return #must_tail st_cdata(p, end, t, on)
}

// `]]` from `t.mark` may end the section.
@(private, enable_target_feature = STATE_FEATURES)
st_cdata_end :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for q < end && q[0] == ']' {
		t.mark += 1
		q = q[1:]
	}
	if q < end && q[0] == '>' {
		if flush(t, on, t.mark, at(t, q) + 1) {
			return halt(t, q[1:])
		}
		t.content = .Data
		t.text_mode = .Data
		return #must_tail st_data(q[1:], end, t, on)
	}
	return #must_tail st_cdata(q, end, t, on)
}

// `p` is past `<?`, whose `?` is at `t.mark`.
@(private, enable_target_feature = STATE_FEATURES)
st_pi_open :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_pi(t, on, end)
	}
	if CLASS[p[0]] & C_ALPHA != 0 || p[0] == '_' {
		t.lo = at(t, p)
		return #must_tail st_pi_target(p, end, t, on)
	}
	if judge_first(t, on, p, end) || report(t, on, p, .Invalid_First_Character_Of_Processing_Instruction_Target) {
		return halt(t, p)
	}
	open_comment(t, t.tok.lo, t.base[t.mark:])
	return #must_tail st_bogus_comment(p, end, t, on)
}

// The temporary buffer is the target, from `t.lo`.
@(private, enable_target_feature = STATE_FEATURES)
st_pi_target :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for q < end && (CLASS[q[0]] & C_ALNUM != 0 || q[0] == '-' || q[0] == '_') {
		q = q[1:]
	}
	if q >= end {
		return eof_in_pi(t, on, end)
	}
	c := q[0]
	if CLASS[c] & C_WS != 0 || c == '?' || c == '>' {
		n := int(at(t, q) - t.lo)
		target := t.base[t.lo:]
		if (n == 3 && fold_equal(target, transmute([]u8)string("xml"))) || (n == 14 && fold_equal(target, transmute([]u8)string("xml-stylesheet"))) {
			if report(t, on, q, .Disallowed_Processing_Instruction_Target) {
				return halt(t, q)
			}
			open_comment(t, t.tok.lo, t.base[t.mark:])
			return #must_tail st_bogus_comment(q, end, t, on)
		}
		t.tok.name = span_of(t, t.lo, at(t, q), .Verbatim, {})
		return #must_tail st_after_pi_target(q, end, t, on)
	}
	if judge_first(t, on, q, end) || report(t, on, q, .Invalid_Processing_Instruction_Target) {
		return halt(t, q)
	}
	open_comment(t, t.tok.lo, t.base[t.mark:])
	return #must_tail st_bogus_comment(q, end, t, on)
}

@(private, enable_target_feature = STATE_FEATURES)
st_after_pi_target :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := skip_ws(p, end)
	t.lo = at(t, q)
	t.flags = {}
	return #must_tail st_pi_data(q, end, t, on)
}

// The data starts at `t.lo`.
@(private, enable_target_feature = STATE_FEATURES)
st_pi_data :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	q := p
	for {
		q = stop_at(q, end, STOP_PI)
		if q >= end {
			return eof_in_pi(t, on, end)
		}
		switch q[0] {
		case '?':
			t.mark = at(t, q)
			return #must_tail st_pi_questionable(q[1:], end, t, on)
		case '>':
			t.tok.data = span_of(t, t.lo, at(t, q), .Verbatim, t.flags)
			if emit(t, on, q[1:]) {
				return halt(t, q[1:])
			}
			return #must_tail st_content(q[1:], end, t, on)
		case:
			n, stop := judge(t, on, q, end, &t.flags)
			if stop {
				return halt(t, q)
			}
			q = q[n:]
		}
	}
}

// A `?` at `t.mark` may end the instruction.
@(private, enable_target_feature = STATE_FEATURES)
st_pi_questionable :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	if p >= end {
		return eof_in_pi(t, on, end)
	}
	if p[0] == '>' {
		t.tok.data = span_of(t, t.lo, t.mark, .Verbatim, t.flags)
		if emit(t, on, p[1:]) {
			return halt(t, p[1:])
		}
		return #must_tail st_content(p[1:], end, t, on)
	}
	return #must_tail st_pi_data(p, end, t, on)
}

// The character reference state, at the `&`, which returns to `t.ret`.
@(private, enable_target_feature = STATE_FEATURES)
st_char_ref :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	attr := t.ret >= .Double
	r := read_ref(p, end, attr)
	if attr {
		t.flags += {.Ref}
	} else {
		t.text_flags += {.Ref}
	}
	for i in 0 ..< 2 {
		if r.errors[i] != .None && report(t, on, r.err_at[i], r.errors[i]) {
			return halt(t, r.q)
		}
	}
	switch t.ret {
	case .Data:
		return #must_tail st_data(r.q, end, t, on)
	case .Rcdata:
		return #must_tail st_rcdata(r.q, end, t, on)
	case .Double:
		return #must_tail st_attr_value_double(r.q, end, t, on)
	case .Single:
		return #must_tail st_attr_value_single(r.q, end, t, on)
	case .Unquoted:
		return #must_tail st_attr_value_unquoted(r.q, end, t, on)
	}
	return #must_tail st_data(r.q, end, t, on)
}

// The text state the tokenizer is in after a token.
@(private, enable_target_feature = STATE_FEATURES)
st_content :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	switch t.content {
	case .Data:
		return #must_tail st_data(p, end, t, on)
	case .Rcdata:
		return #must_tail st_rcdata(p, end, t, on)
	case .Rawtext:
		return #must_tail st_rawtext(p, end, t, on)
	case .Script_Data:
		return #must_tail st_script(p, end, t, on)
	case .Plaintext:
		return #must_tail st_plaintext(p, end, t, on)
	case .Cdata_Section:
		return #must_tail st_cdata(p, end, t, on)
	}
	return #must_tail st_data(p, end, t, on)
}

// The text state a `</` that is no appropriate end tag returns to.
@(private, enable_target_feature = STATE_FEATURES)
st_back :: #force_no_inline proc "contextless" (p, end: [^]u8, t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action) -> u64 {
	switch t.back {
	case .Rcdata:
		return #must_tail st_rcdata(p, end, t, on)
	case .Rawtext:
		return #must_tail st_rawtext(p, end, t, on)
	case .Script:
		return #must_tail st_script(p, end, t, on)
	case .Escaped:
		return #must_tail st_script_escaped(p, end, t, on)
	}
	return #must_tail st_script_escaped(p, end, t, on)
}
