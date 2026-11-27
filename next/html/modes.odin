package html

import "base:intrinsics"

// The insertion modes of HTML5 §13.2.6.4: each procedure reads one token and returns whether to reprocess it in the new mode.

@(private)
EOF :: Html_Token_Kind.Error

@(private)
DOCUMENT :: u32(1)

@(private)
HEADINGS :: Tags{.H1, .H2, .H3, .H4, .H5, .H6}

@(private)
on_token :: proc "contextless" (t: ^Html_Tree, tok: ^Html_Token) -> Token_Action {
	context = t.ctx
	if tok.kind == .Error { parse_error(t, tok.detail, tok.lo); return .Next }
	t.at, t.tok, t.action, t.acknowledged = tok.lo, tok, .Next, false
	skip_lf := t.skip_lf
	t.skip_lf = false
	#partial switch tok.kind {
	case .Text:
		if tok.data.mode == .Data {
			tok.data.mode = .Text
		} else if tok.data.mode == .Verbatim {
			tok.data.mode = .Text
			if .Nul in tok.data.flags { cdata_nul(t, tok.data) }
		}
		if skip_lf {
			tok.data = drop_lf(t, tok.data)
			if tok.data.n == 0 { return .Next }
		}
	case .Start_Tag, .End_Tag:
		t.tag = tag_of(t.src, tok.name)
	}
	dispatch(t, tok)
	if t.taken_to > tok.lo { t.tail = 0 } else if t.tail == 0 || t.tail < t.taken_to { t.tail = tok.lo }
	if tok.kind == .Start_Tag && .Self_Closing in tok.flags && !t.acknowledged {
		parse_error(t, .Non_Void_Html_Element_Start_Tag_With_Trailing_Solidus, tok.hi)
	}
	if t.oom || t.too_deep || t.misread { return .Stop }
	if t.foreign_open == 0 && !t.in_foreign { return t.action }
	if outside := in_foreign_content(t); outside != t.in_foreign {
		t.in_foreign = outside
		if t.action == .Next { t.action = .Foreign if outside else .Html }
	}
	return t.action
}

@(private)
cdata_nul :: proc(t: ^Html_Tree, s: Span) {
	for c, i in t.src[s.lo:][:s.n] { if c == 0 { parse_error(t, .Unexpected_Null_Character, s.lo + u64(i)) } }
}

@(private)
dispatch :: #force_inline proc(t: ^Html_Tree, tok: ^Html_Token) {
	if t.in_foreign && foreign_token(t, tok) && !foreign_rules(t, tok) { return }
	for !t.oom && !t.too_deep && in_mode(t, tok) {}
}

@(private)
in_mode :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	switch t.mode {
	case .Initial:              return initial(t, tok)
	case .Before_Html:          return before_html(t, tok)
	case .Before_Head:          return before_head(t, tok)
	case .In_Head:              return in_head(t, tok)
	case .In_Head_Noscript:     return in_head_noscript(t, tok)
	case .After_Head:           return after_head(t, tok)
	case .In_Body:              return in_body(t, tok)
	case .Text:                 return in_text(t, tok)
	case .In_Table:             return in_table(t, tok)
	case .In_Table_Text:        return in_table_text(t, tok)
	case .In_Caption:           return in_caption(t, tok)
	case .In_Column_Group:      return in_column_group(t, tok)
	case .In_Table_Body:        return in_table_body(t, tok)
	case .In_Row:               return in_row(t, tok)
	case .In_Cell:              return in_cell(t, tok)
	case .After_Body:           return after_body(t, tok)
	case .In_Frameset:          return in_frameset(t, tok)
	case .After_Frameset:       return after_frameset(t, tok)
	case .After_After_Body:     return after_after_body(t, tok)
	case .After_After_Frameset: return after_after_frameset(t, tok)
	case .In_Template:          return in_template(t, tok)
	}
	return false
}

@(private)
unexpected :: proc(t: ^Html_Tree, tok: ^Html_Token) {
	#partial switch tok.kind {
	case .Text:      parse_error(t, .Unexpected_Text, tok.data.lo)
	case .Start_Tag: misplaced(t, .Unexpected_Start_Tag)
	case .End_Tag:   misplaced(t, .Unexpected_End_Tag)
	case .Doctype:   misplaced(t, .Unexpected_Doctype)
	case EOF:        misplaced(t, .Unclosed_Element)
	}
}

@(private)
Char_Class :: enum u8 { Space, Nul, Other }

@(private)
char_at :: proc "contextless" (t: ^Html_Tree, s: Span, i: u32) -> (Char_Class, u32) #no_bounds_check {
	p := raw_data(t.src)[s.lo + u64(i):]
	c := p[0]
	switch {
	case CLASS[c] & C_WS != 0: return .Space, i + 1
	case c == 0:               return .Nul, i + 1
	case c == '&' && .Ref in s.flags:
		r := read_ref(p, raw_data(t.src)[s.lo + u64(s.n):], false)
		n := u32(intrinsics.ptr_sub(r.q, p))
		if r.n == 1 && CLASS[r.value[0]] & C_WS != 0 { return .Space, i + n }
		return .Other, i + max(n, 1)
	}
	return .Other, i + 1
}

@(private)
space_prefix :: proc "contextless" (t: ^Html_Tree, s: Span) -> u32 #no_bounds_check {
	i := u32(0)
	if .Ref not_in s.flags {
		p := raw_data(t.src)[s.lo:]
		for i < s.n && CLASS[p[i]] & C_WS != 0 { i += 1 }
		return i
	}
	for i < s.n {
		class, next := char_at(t, s, i)
		if class != .Space { break }
		i = next
	}
	return i
}

@(private)
has_text :: proc "contextless" (t: ^Html_Tree, s: Span) -> bool #no_bounds_check {
	if .Ref not_in s.flags {
		p := raw_data(t.src)[s.lo:]
		for i in 0 ..< s.n { if CLASS[p[i]] & C_WS == 0 && p[i] != 0 { return true } }
		return false
	}
	for i := u32(0); i < s.n; {
		class, next := char_at(t, s, i)
		if class == .Other { return true }
		i = next
	}
	return false
}

@(private)
only_nul :: proc "contextless" (t: ^Html_Tree, s: Span) -> bool #no_bounds_check {
	if .Nul not_in s.flags { return false }
	p := raw_data(t.src)[s.lo:]
	for i in 0 ..< s.n { if p[i] != 0 { return false } }
	return true
}

@(private)
head_of :: #force_inline proc "contextless" (s: Span, n: u32) -> Span { return {lo = s.lo, n = n, mode = s.mode, flags = s.flags} }

@(private)
tail_of :: #force_inline proc "contextless" (s: Span, n: u32) -> Span { return {lo = s.lo + u64(n), n = s.n - n, mode = s.mode, flags = s.flags} }

@(private)
drop_lf :: proc "contextless" (t: ^Html_Tree, s: Span) -> Span #no_bounds_check {
	p := raw_data(t.src)[s.lo:]
	switch p[0] {
	case '\n': return tail_of(s, 1)
	case '\r': return tail_of(s, 2 if s.n > 1 && p[1] == '\n' else 1)
	case '&':
		if .Ref in s.flags {
			r := read_ref(p, p[s.n:], false)
			if r.n == 1 && r.value[0] == '\n' { return tail_of(s, u32(intrinsics.ptr_sub(r.q, p))) }
		}
	}
	return s
}

@(private)
skip_spaces :: #force_inline proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	n := space_prefix(t, tok.data)
	if n == tok.data.n { return true }
	tok.data = tail_of(tok.data, n)
	return false
}

@(private)
take_space :: proc(t: ^Html_Tree, tok: ^Html_Token, body := false) -> bool {
	n := space_prefix(t, tok.data)
	if n > 0 { insert_spaces_as(t, head_of(tok.data, n), body) }
	tok.data = tail_of(tok.data, n)
	return tok.data.n > 0
}

@(private)
insert_spaces :: proc(t: ^Html_Tree, s: Span, body := false) {
	run_lo, i := u32(0), u32(0)
	reported := false
	for i < s.n {
		class, next := char_at(t, s, i)
		if class != .Space {
			if i > run_lo { insert_spaces_as(t, head_of(tail_of(s, run_lo), i - run_lo), body) }
			if !reported { parse_error(t, .Unexpected_Text, s.lo + u64(i)); reported = true }
			run_lo = next
		} else {
			reported = false
		}
		i = next
	}
	if s.n > run_lo { insert_spaces_as(t, tail_of(s, run_lo), body) }
}

@(private)
insert_spaces_as :: #force_inline proc(t: ^Html_Tree, s: Span, body: bool) {
	if body { body_text(t, s) } else { insert_text(t, s) }
}

@(private)
body_text :: proc(t: ^Html_Tree, s: Span) {
	if only_nul(t, s) { return }
	reconstruct(t)
	insert_text(t, s)
	if t.frameset_ok && has_text(t, s) { t.frameset_ok = false }
}

@(private)
acknowledge :: #force_inline proc "contextless" (t: ^Html_Tree) { t.acknowledged = true }

@(private)
insert_void :: #force_inline proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	if _, ok := insert_for(t, tok); !ok { return false }
	pop_current(t)
	t.acknowledged = true
	return true
}

@(private)
text_element :: proc(t: ^Html_Tree, tok: ^Html_Token, action: Token_Action) {
	if _, ok := insert_for(t, tok); !ok { return }
	t.action, t.original, t.mode = action, t.mode, .Text
}

@(private)
initial :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch tok.kind {
	case .Text:                 if skip_spaces(t, tok) { return false }
	case .Comment, .Instruction: insert_misc(t, tok, DOCUMENT); return false
	case .Doctype:              doctype(t, tok); t.mode = .Before_Html; return false
	}
	misplaced(t, .Missing_Doctype)
	t.quirks, t.mode = .Quirks, .Before_Html
	return true
}

@(private)
doctype :: proc(t: ^Html_Tree, tok: ^Html_Token) {
	name := decoded(t, tok.name, 0)
	public_missing, system_missing := .Missing in tok.public_id.flags, .Missing in tok.system_id.flags
	system := decoded(t, tok.system_id, len(name))
	if name != "html" || !public_missing || !system_missing && system != "about:legacy-compat" { misplaced(t, .Bad_Doctype) }
	if n := new_node(t, {kind = .Doctype, name = tok.name, lo = tok.lo, hi = tok.hi}); n != 0 { link(t, DOCUMENT, n, 0) }
	t.public_id, t.system_id = tok.public_id, tok.system_id
	public := decoded(t, tok.public_id, len(name) + len(system))
	switch {
	case .Force_Quirks in tok.flags || name != "html" || quirks_ids(public, system, system_missing):
		t.quirks = .Quirks
	case has_prefix_in(public, LIMITED_PREFIXES[:]) || !system_missing && has_prefix_in(public, HTML401_PREFIXES[:]):
		t.quirks = .Limited
	}
}

@(private)
quirks_ids :: proc "contextless" (public, system: string, system_missing: bool) -> bool {
	for id in QUIRKS_PUBLIC { if ascii_fold_equal(public, id) { return true } }
	if ascii_fold_equal(system, QUIRKS_SYSTEM) { return true }
	return has_prefix_in(public, QUIRKS_PREFIXES[:]) || (system_missing || len(system) == 0) && has_prefix_in(public, HTML401_PREFIXES[:])
}

@(private)
has_prefix_in :: proc "contextless" (s: string, prefixes: []string) -> bool {
	for p in prefixes { if len(s) >= len(p) && ascii_fold_equal(s[:len(p)], p) { return true } }
	return false
}

@(private, rodata)
QUIRKS_PUBLIC := [?]string{"-//w3o//dtd w3 html strict 3.0//en//", "-/w3c/dtd html 4.0 transitional/en", "html"}
@(private)
QUIRKS_SYSTEM :: "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd"
@(private, rodata)
HTML401_PREFIXES := [?]string{"-//w3c//dtd html 4.01 frameset//", "-//w3c//dtd html 4.01 transitional//"}
@(private, rodata)
LIMITED_PREFIXES := [?]string{"-//w3c//dtd xhtml 1.0 frameset//", "-//w3c//dtd xhtml 1.0 transitional//"}
@(private, rodata)
QUIRKS_PREFIXES := [?]string {
	"+//silmaril//dtd html pro v0r11 19970101//", "-//as//dtd html 3.0 aswedit + extensions//", "-//advasoft ltd//dtd html 3.0 aswedit + extensions//",
	"-//ietf//dtd html 2.0 level 1//", "-//ietf//dtd html 2.0 level 2//", "-//ietf//dtd html 2.0 strict level 1//", "-//ietf//dtd html 2.0 strict level 2//",
	"-//ietf//dtd html 2.0 strict//", "-//ietf//dtd html 2.0//", "-//ietf//dtd html 2.1e//", "-//ietf//dtd html 3.0//", "-//ietf//dtd html 3.2 final//",
	"-//ietf//dtd html 3.2//", "-//ietf//dtd html 3//", "-//ietf//dtd html level 0//", "-//ietf//dtd html level 1//", "-//ietf//dtd html level 2//",
	"-//ietf//dtd html level 3//", "-//ietf//dtd html strict level 0//", "-//ietf//dtd html strict level 1//", "-//ietf//dtd html strict level 2//",
	"-//ietf//dtd html strict level 3//", "-//ietf//dtd html strict//", "-//ietf//dtd html//", "-//metrius//dtd metrius presentational//",
	"-//microsoft//dtd internet explorer 2.0 html strict//", "-//microsoft//dtd internet explorer 2.0 html//", "-//microsoft//dtd internet explorer 2.0 tables//",
	"-//microsoft//dtd internet explorer 3.0 html strict//", "-//microsoft//dtd internet explorer 3.0 html//", "-//microsoft//dtd internet explorer 3.0 tables//",
	"-//netscape comm. corp.//dtd html//", "-//netscape comm. corp.//dtd strict html//", "-//o'reilly and associates//dtd html 2.0//",
	"-//o'reilly and associates//dtd html extended 1.0//", "-//o'reilly and associates//dtd html extended relaxed 1.0//",
	"-//sq//dtd html 2.0 hotmetal + extensions//", "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
	"-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//", "-//spyglass//dtd html 2.0 extended//",
	"-//sun microsystems corp.//dtd hotjava html//", "-//sun microsystems corp.//dtd hotjava strict html//", "-//w3c//dtd html 3 1995-03-24//",
	"-//w3c//dtd html 3.2 draft//", "-//w3c//dtd html 3.2 final//", "-//w3c//dtd html 3.2//", "-//w3c//dtd html 3.2s draft//",
	"-//w3c//dtd html 4.0 frameset//", "-//w3c//dtd html 4.0 transitional//", "-//w3c//dtd html experimental 19960712//",
	"-//w3c//dtd html experimental 970421//", "-//w3c//dtd w3 html//", "-//w3o//dtd w3 html 3.0//", "-//webtechs//dtd mozilla html 2.0//",
	"-//webtechs//dtd mozilla html//",
}

@(private)
before_html :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch tok.kind {
	case .Doctype:               misplaced(t, .Unexpected_Doctype); return false
	case .Comment, .Instruction: insert_misc(t, tok, DOCUMENT); return false
	case .Text:                  if skip_spaces(t, tok) { return false }
	case .Start_Tag:
		if t.tag == .Html {
			n := element_for(t, tok, .Html)
			if t.oom { return false }
			link(t, DOCUMENT, n, 0)
			_ = push(t, n)
			t.mode = .Before_Head
			return false
		}
	case .End_Tag:
		if t.tag not_in (Tags{.Head, .Body, .Html, .Br}) { misplaced(t, .Unexpected_End_Tag); return false }
	}
	n := implied(t, .Html)
	if t.oom { return false }
	link(t, DOCUMENT, n, 0)
	if !push(t, n) { return false }
	t.mode = .Before_Head
	return true
}

@(private)
before_head :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch tok.kind {
	case .Text:                  if skip_spaces(t, tok) { return false }
	case .Comment, .Instruction: insert_misc(t, tok); return false
	case .Doctype:               misplaced(t, .Unexpected_Doctype); return false
	case .Start_Tag:
		if t.tag == .Html { return in_body(t, tok) }
		if t.tag == .Head {
			if head, ok := insert_for(t, tok); ok { t.head, t.mode = head, .In_Head }
			return false
		}
	case .End_Tag:
		if t.tag not_in (Tags{.Head, .Body, .Html, .Br}) { misplaced(t, .Unexpected_End_Tag); return false }
	}
	head, ok := insert_implied(t, .Head)
	if !ok { return false }
	t.head, t.mode = head, .In_Head
	return true
}

@(private)
in_head :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch tok.kind {
	case .Text:                  if !take_space(t, tok) { return false }
	case .Comment, .Instruction: insert_misc(t, tok); return false
	case .Doctype:               misplaced(t, .Unexpected_Doctype); return false
	case .Start_Tag:
		#partial switch t.tag {
		case .Html: return in_body(t, tok)
		case .Base, .Basefont, .Bgsound, .Link, .Meta:
			if insert_void(t, tok) && t.tag == .Meta && t.tentative { meta_changes_encoding(t, tok.attrs) }
			return false
		case .Title:            text_element(t, tok, .Rcdata); return false
		case .Noframes, .Style: text_element(t, tok, .Rawtext); return false
		case .Script:           text_element(t, tok, .Script_Data); return false
		case .Noscript:
			if t.scripting { text_element(t, tok, .Rawtext) } else if _, ok := insert_for(t, tok); ok { t.mode = .In_Head_Noscript }
			return false
		case .Template:
			if _, ok := insert_for(t, tok); !ok { return false }
			push_marker(t)
			t.frameset_ok, t.mode = false, .In_Template
			if _, err := append(&t.templates, Insertion_Mode.In_Template); err != nil { t.oom = true }
			return false
		case .Head: misplaced(t, .Unexpected_Start_Tag); return false
		}
	case .End_Tag:
		#partial switch t.tag {
		case .Head:             pop_current(t); t.mode = .After_Head; return false
		case .Template:         close_template(t); return false
		case .Body, .Html, .Br:
		case:                   misplaced(t, .Unexpected_End_Tag); return false
		}
	}
	pop_current(t)
	t.mode = .After_Head
	return true
}

@(private)
close_template :: proc(t: ^Html_Tree) {
	if !has_template(t) { misplaced(t, .Unexpected_End_Tag); return }
	pop_closed(t, .Template, class = .Thorough_End)
	clear_to_marker(t)
	pop(&t.templates)
	reset_insertion_mode(t)
}

@(private)
in_head_noscript :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch tok.kind {
	case .Doctype:               misplaced(t, .Unexpected_Doctype); return false
	case .Comment, .Instruction: return in_head(t, tok)
	case .Text:                  if !take_space(t, tok) { return false }
	case .Start_Tag:
		#partial switch t.tag {
		case .Html:                                             return in_body(t, tok)
		case .Basefont, .Bgsound, .Link, .Meta, .Noframes, .Style: return in_head(t, tok)
		case .Head, .Noscript:                                  misplaced(t, .Unexpected_Start_Tag); return false
		}
	case .End_Tag:
		if t.tag == .Noscript { pop_current(t); t.mode = .In_Head; return false }
		if t.tag != .Br { misplaced(t, .Unexpected_End_Tag); return false }
	}
	unexpected(t, tok)
	pop_current(t)
	t.mode = .In_Head
	return true
}

@(private)
after_head :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch tok.kind {
	case .Text:                  if !take_space(t, tok) { return false }
	case .Comment, .Instruction: insert_misc(t, tok); return false
	case .Doctype:               misplaced(t, .Unexpected_Doctype); return false
	case .Start_Tag:
		#partial switch t.tag {
		case .Html: return in_body(t, tok)
		case .Body:
			if _, ok := insert_for(t, tok); ok { t.frameset_ok, t.mode = false, .In_Body }
			return false
		case .Frameset:
			if _, ok := insert_for(t, tok); ok { t.mode = .In_Frameset }
			return false
		case .Base, .Basefont, .Bgsound, .Link, .Meta, .Noframes, .Script, .Style, .Template, .Title:
			misplaced(t, .Unexpected_Start_Tag)
			if push(t, t.head) { in_head(t, tok); remove_from_stack(t, t.head) }
			return false
		case .Head: misplaced(t, .Unexpected_Start_Tag); return false
		}
	case .End_Tag:
		if t.tag == .Template { return in_head(t, tok) }
		if t.tag not_in (Tags{.Body, .Html, .Br}) { misplaced(t, .Unexpected_End_Tag); return false }
	}
	if _, ok := insert_implied(t, .Body); !ok { return false }
	t.frameset_ok, t.mode = true, .In_Body
	return true
}

@(private)
in_body :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	switch tok.kind {
	case .Text:                  body_text(t, tok.data)
	case .Comment, .Instruction: insert_misc(t, tok)
	case .Doctype:               misplaced(t, .Unexpected_Doctype)
	case .Start_Tag:             return body_start_tag(t, tok)
	case .End_Tag:               return body_end_tag(t, tok)
	case EOF:
		if len(t.templates) > 0 { return in_template(t, tok) }
		check_open_at_end(t)
	}
	return false
}

@(private)
body_start_tag :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch t.tag {
	case .Html:
		misplaced(t, .Unexpected_Start_Tag)
		if !has_template(t) { merge_attrs(t, t.stack[0], tok) }
	case .Base, .Basefont, .Bgsound, .Link, .Meta, .Noframes, .Script, .Style, .Template, .Title:
		return in_head(t, tok)
	case .Body:
		misplaced(t, .Unexpected_Start_Tag)
		if len(t.stack) > 1 && is_html(tree_node(t, t.stack[1]), .Body) && !has_template(t) {
			t.frameset_ok = false
			merge_attrs(t, t.stack[1], tok)
		}
	case .Frameset:
		misplaced(t, .Unexpected_Start_Tag)
		if len(t.stack) > 1 && is_html(tree_node(t, t.stack[1]), .Body) && t.frameset_ok {
			unlink(t, t.stack[1]); pop_to(t, 1); insert_for(t, tok); t.mode = .In_Frameset
		}
	case .Address, .Article, .Aside, .Blockquote, .Center, .Details, .Dialog, .Dir, .Div, .Dl, .Fieldset, .Figcaption, .Figure, .Footer, .Header, .Hgroup, .Main, .Menu, .Nav, .Ol, .P, .Search, .Section, .Summary, .Ul:
		close_open_p(t); insert_for(t, tok)
	case .H1, .H2, .H3, .H4, .H5, .H6:
		close_open_p(t)
		if .Heading in classes(current_node(t)) { misplaced(t, .Unexpected_Start_Tag); pop_current(t) }
		insert_for(t, tok)
	case .Pre, .Listing:
		close_open_p(t); insert_for(t, tok); t.skip_lf, t.frameset_ok = true, false
	case .Form:
		template := in_template_contents(t)
		if t.form != 0 && !template { misplaced(t, .Unexpected_Start_Tag); return false }
		close_open_p(t)
		form := insert_for(t, tok)
		if !template { t.form = form }
	case .Li, .Dd, .Dt:
		t.frameset_ok = false
		close_list_item(t, {.Li} if t.tag == .Li else {.Dd, .Dt})
		close_open_p(t)
		insert_for(t, tok)
	case .Plaintext:
		close_open_p(t); insert_for(t, tok); t.action = .Plaintext
	case .Button:
		if in_scope(t, {.Button}) { misplaced(t, .Unexpected_Start_Tag); close_implied(t); pop_until(t, {.Button}) }
		reconstruct(t); insert_for(t, tok); t.frameset_ok = false
	case .A:
		if i := active_after_marker(t, .A); i >= 0 {
			misplaced(t, .Misnested_Tag)
			a := t.active[i]
			if adoption_agency(t, .A) { any_other_end_tag(t, tok) }
			if j := active_index(t, a); j >= 0 { ordered_remove(&t.active, j) }
			if .Open in tree_node(t, a).flags { remove_from_stack(t, a) }
		}
		reconstruct(t); push_active(t, insert_for(t, tok))
	case .B, .Big, .Code, .Em, .Font, .I, .S, .Small, .Strike, .Strong, .Tt, .U:
		reconstruct(t); push_active(t, insert_for(t, tok))
	case .Nobr:
		reconstruct(t)
		if in_scope(t, {.Nobr}) {
			misplaced(t, .Misnested_Tag)
			if adoption_agency(t, .Nobr) { any_other_end_tag(t, tok) }
			reconstruct(t)
		}
		push_active(t, insert_for(t, tok))
	case .Applet, .Marquee, .Object:
		reconstruct(t)
		if _, ok := insert_for(t, tok); ok { push_marker(t); t.frameset_ok = false }
	case .Table:
		if t.quirks != .Quirks { close_open_p(t) }
		if _, ok := insert_for(t, tok); ok { t.frameset_ok, t.mode = false, .In_Table }
	case .Image:
		misplaced(t, .Unexpected_Start_Tag); t.tag = .Img; return body_start_tag(t, tok)
	case .Area, .Br, .Embed, .Img, .Keygen, .Wbr:
		reconstruct(t)
		if insert_void(t, tok) { t.frameset_ok = false }
	case .Input:
		if in_select_context(t) { misplaced(t, .Unexpected_Start_Tag); return false }
		if in_scope(t, {.Select}) { misplaced(t, .Unexpected_Start_Tag); pop_until(t, {.Select}) }
		reconstruct(t)
		if !insert_void(t, tok) { return false }
		if found, hidden := attr_value_is(t, tok.attrs, "type", "hidden"); !found || !hidden { t.frameset_ok = false }
	case .Param, .Source, .Track:
		insert_void(t, tok)
	case .Hr:
		close_open_p(t)
		if in_scope(t, {.Select}) {
			close_implied(t)
			if in_scope(t, {.Option, .Optgroup}) { misplaced(t, .Unexpected_Start_Tag) }
		}
		if insert_void(t, tok) { t.frameset_ok = false }
	case .Textarea:
		if _, ok := insert_for(t, tok); ok {
			t.skip_lf, t.action, t.original, t.frameset_ok, t.mode = true, .Rcdata, t.mode, false, .Text
		}
	case .Xmp:
		close_open_p(t); reconstruct(t); t.frameset_ok = false; text_element(t, tok, .Rawtext)
	case .Iframe:
		t.frameset_ok = false; text_element(t, tok, .Rawtext)
	case .Noembed:
		text_element(t, tok, .Rawtext)
	case .Noscript:
		if t.scripting { text_element(t, tok, .Rawtext) } else { reconstruct(t); insert_for(t, tok) }
	case .Selectedcontent:
		reconstruct(t); insert_for(t, tok); t.selected = true
	case .Select:
		if in_select_context(t) { misplaced(t, .Unexpected_Start_Tag); return false }
		if in_scope(t, {.Select}) { misplaced(t, .Unexpected_Start_Tag); pop_until(t, {.Select}); return false }
		reconstruct(t); insert_for(t, tok); t.frameset_ok = false
	case .Option, .Optgroup:
		if in_scope(t, {.Select}) {
			if t.tag == .Option {
				close_implied(t, .Optgroup)
				if in_scope(t, {.Option}) { misplaced(t, .Unexpected_Start_Tag) }
			} else {
				close_implied(t)
				if in_scope(t, {.Option, .Optgroup}) { misplaced(t, .Unexpected_Start_Tag) }
			}
		} else if is_html(current_node(t), .Option) {
			pop_current(t)
		}
		reconstruct(t); insert_for(t, tok)
	case .Rb, .Rtc:
		if in_scope(t, {.Ruby}) {
			close_implied(t)
			if !is_html(current_node(t), .Ruby) { misplaced(t, .Unexpected_Start_Tag) }
		}
		insert_for(t, tok)
	case .Rp, .Rt:
		if in_scope(t, {.Ruby}) {
			close_implied(t, .Rtc)
			if n := current_node(t); !is_html(n, .Rtc) && !is_html(n, .Ruby) { misplaced(t, .Unexpected_Start_Tag) }
		}
		insert_for(t, tok)
	case .Math, .Svg:
		reconstruct(t)
		if insert_foreign(t, tok, .Math if t.tag == .Math else .Svg) && .Self_Closing in tok.flags { pop_current(t); t.acknowledged = true }
	case .Caption, .Col, .Colgroup, .Frame, .Head, .Tbody, .Td, .Tfoot, .Th, .Thead, .Tr:
		misplaced(t, .Unexpected_Start_Tag)
	case:
		reconstruct(t); insert_for(t, tok)
	}
	return false
}

@(private)
close_list_item :: proc(t: ^Html_Tree, tags: Tags) {
	#reverse for m in t.stack {
		n := tree_node(t, m)
		if n.tag in tags && n.ns == .Html { pop_closed(t, n.tag, except = n.tag); return }
		if .Special in classes(n) && n.tag not_in (Tags{.Address, .Div, .P}) { return }
	}
}

@(private)
body_end_tag :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	tag := t.tag
	#partial switch tag {
	case .Body, .Html:
		if !in_scope(t, {.Body}) { misplaced(t, .Unexpected_End_Tag); return false }
		check_open_at_end(t)
		t.mode = .After_Body
		if t.body_end.n == 0 { t.body_end = {lo = tok.lo, n = u32(tok.hi - tok.lo)} }
		return tag == .Html
	case .Address, .Article, .Aside, .Blockquote, .Button, .Center, .Details, .Dialog, .Dir, .Div, .Dl, .Fieldset, .Figcaption, .Figure, .Footer, .Header, .Hgroup, .Listing, .Main, .Menu, .Nav, .Ol, .Pre, .Search, .Section, .Select, .Summary, .Ul, .Dd, .Dt:
		close_element(t, tag, SCOPE)
	case .Li: close_element(t, .Li, LIST_SCOPE)
	case .Form:
		if in_template_contents(t) { close_element(t, .Form, SCOPE); return false }
		node := t.form
		t.form = 0
		if node == 0 || !node_in_scope(t, node) { misplaced(t, .Unexpected_End_Tag); return false }
		close_implied(t)
		if current(t) != node { misplaced(t, .Unclosed_Element) }
		remove_from_stack(t, node)
	case .P:
		if !in_scope(t, {.P}, BUTTON_SCOPE) { misplaced(t, .Unexpected_End_Tag); insert_implied(t, .P) }
		close_p(t)
	case .H1, .H2, .H3, .H4, .H5, .H6:
		if !in_scope(t, HEADINGS) { misplaced(t, .Unexpected_End_Tag); return false }
		pop_closed(t, tag, HEADINGS)
	case .A, .B, .Big, .Code, .Em, .Font, .I, .Nobr, .S, .Small, .Strike, .Strong, .Tt, .U:
		if adoption_agency(t, tag) { any_other_end_tag(t, tok) }
	case .Applet, .Marquee, .Object:
		if close_element(t, tag, SCOPE) { clear_to_marker(t) }
	case .Br:
		misplaced(t, .Unexpected_End_Tag)
		reconstruct(t)
		if _, ok := insert_implied(t, .Br); ok { pop_current(t); t.frameset_ok = false }
	case .Template: return in_head(t, tok)
	case:           any_other_end_tag(t, tok)
	}
	return false
}

@(private)
close_element :: proc(t: ^Html_Tree, tag: Tag, bound: Tag_Classes) -> bool {
	if !in_scope(t, {tag}, bound) { misplaced(t, .Unexpected_End_Tag); return false }
	pop_closed(t, tag, except = tag if tag == .Li || tag == .Dd || tag == .Dt else .Other)
	return true
}

@(private)
any_other_end_tag :: proc(t: ^Html_Tree, tok: ^Html_Token) {
	#reverse for m, i in t.stack {
		n := tree_node(t, m)
		if n.ns == .Html && n.tag == t.tag && (t.tag != .Other || names_equal(raw_data(t.src), n.name, tok.name)) {
			close_implied(t, t.tag)
			if m != current(t) { misplaced(t, .Unclosed_Element) }
			pop_to(t, i)
			return
		}
		if .Special in classes(n) { misplaced(t, .Unexpected_End_Tag); return }
	}
}

@(private)
in_text :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch tok.kind {
	case .Text:    insert_text(t, tok.data)
	case EOF:      misplaced(t, .Unclosed_Element); pop_current(t); t.mode = t.original; return true
	case .End_Tag: pop_current(t); t.mode = t.original
	}
	return false
}

@(private)
in_table :: proc(t: ^Html_Tree, tok: ^Html_Token) -> (again: bool) {
	switch tok.kind {
	case .Text:
		if n := current_node(t); .Foster in classes(n) || is_html(n, .Template) {
			clear(&t.pending); t.pending_text = false; t.original, t.mode = t.mode, .In_Table_Text
			return true
		}
	case .Comment, .Instruction: insert_misc(t, tok); return false
	case .Doctype:               misplaced(t, .Unexpected_Doctype); return false
	case .Start_Tag:
		#partial switch t.tag {
		case .Caption:
			clear_to(t, .Table_Scope); push_marker(t)
			if _, ok := insert_for(t, tok); ok { t.mode = .In_Caption }
			return false
		case .Colgroup:
			clear_to(t, .Table_Scope)
			if _, ok := insert_for(t, tok); ok { t.mode = .In_Column_Group }
			return false
		case .Col:
			clear_to(t, .Table_Scope)
			if _, ok := insert_implied(t, .Colgroup); !ok { return false }
			t.mode = .In_Column_Group; return true
		case .Tbody, .Tfoot, .Thead:
			clear_to(t, .Table_Scope)
			if _, ok := insert_for(t, tok); ok { t.mode = .In_Table_Body }
			return false
		case .Td, .Th, .Tr:
			clear_to(t, .Table_Scope)
			if _, ok := insert_implied(t, .Tbody); !ok { return false }
			t.mode = .In_Table_Body; return true
		case .Table:
			misplaced(t, .Unexpected_Start_Tag)
			if !in_scope(t, {.Table}, TABLE_SCOPE) { return false }
			pop_until(t, {.Table}); reset_insertion_mode(t); return true
		case .Style, .Script, .Template: return in_head(t, tok)
		case .Input:
			if _, hidden := attr_value_is(t, tok.attrs, "type", "hidden"); hidden {
				misplaced(t, .Unexpected_Start_Tag); insert_void(t, tok); return false
			}
		case .Form:
			misplaced(t, .Unexpected_Start_Tag)
			template := in_template_contents(t)
			if t.form != 0 && !template { return false }
			form, ok := insert_for(t, tok)
			if !ok { return false }
			if !template { t.form = form }
			pop_current(t); return false
		}
	case .End_Tag:
		#partial switch t.tag {
		case .Table:
			if !in_scope(t, {.Table}, TABLE_SCOPE) { misplaced(t, .Unexpected_End_Tag); return false }
			pop_until(t, {.Table}); reset_insertion_mode(t); return false
		case .Body, .Caption, .Col, .Colgroup, .Html, .Tbody, .Td, .Tfoot, .Th, .Thead, .Tr:
			misplaced(t, .Unexpected_End_Tag); return false
		case .Template: return in_head(t, tok)
		}
	case EOF: return in_body(t, tok)
	}
	unexpected(t, tok)
	t.foster = true
	again = in_body(t, tok)
	t.foster = false
	return
}

@(private)
in_table_text :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	if tok.kind == .Text {
		t.pending_text ||= has_text(t, tok.data)
		if _, err := append(&t.pending, tok.data); err != nil { t.oom = true }
		return false
	}
	if t.pending_text {
		parse_error(t, .Unexpected_Text, t.pending[0].lo)
		t.foster = true
		for s in t.pending { body_text(t, s) }
		t.foster = false
	} else {
		for s in t.pending { insert_text(t, s) }
	}
	clear(&t.pending)
	t.mode = t.original
	return true
}

@(private)
close_caption :: proc(t: ^Html_Tree) -> bool {
	if !in_scope(t, {.Caption}, TABLE_SCOPE) { misplaced(t, .Unexpected_End_Tag); return false }
	pop_closed(t, .Caption); clear_to_marker(t); t.mode = .In_Table
	return true
}

@(private)
in_caption :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch tok.kind {
	case .End_Tag:
		#partial switch t.tag {
		case .Caption: close_caption(t); return false
		case .Table:   return close_caption(t)
		case .Body, .Col, .Colgroup, .Html, .Tbody, .Td, .Tfoot, .Th, .Thead, .Tr: misplaced(t, .Unexpected_End_Tag); return false
		}
	case .Start_Tag:
		if t.tag in (Tags{.Caption, .Col, .Colgroup, .Tbody, .Td, .Tfoot, .Th, .Thead, .Tr}) { return close_caption(t) }
	}
	return in_body(t, tok)
}

@(private)
in_column_group :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	switch tok.kind {
	case .Text:                  if !take_space(t, tok) { return false }
	case .Comment, .Instruction: insert_misc(t, tok); return false
	case .Doctype:               misplaced(t, .Unexpected_Doctype); return false
	case .Start_Tag:
		#partial switch t.tag {
		case .Html:     return in_body(t, tok)
		case .Col:      insert_void(t, tok); return false
		case .Template: return in_head(t, tok)
		}
	case .End_Tag:
		#partial switch t.tag {
		case .Template: return in_head(t, tok)
		case .Colgroup:
			if !is_html(current_node(t), .Colgroup) { misplaced(t, .Unexpected_End_Tag); return false }
			pop_current(t); t.mode = .In_Table; return false
		case .Col: misplaced(t, .Unexpected_End_Tag); return false
		}
	case EOF: return in_body(t, tok)
	}
	if !is_html(current_node(t), .Colgroup) { unexpected(t, tok); return false }
	pop_current(t); t.mode = .In_Table
	return true
}

@(private)
close_table_ctx :: proc(t: ^Html_Tree, tags: Tags, ctx: Tag_Class, next: Insertion_Mode) -> bool {
	if !in_scope(t, tags, TABLE_SCOPE) { misplaced(t, .Unexpected_End_Tag); return false }
	clear_to(t, ctx); pop_current(t); t.mode = next
	return true
}

@(private)
in_table_body :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch tok.kind {
	case .Start_Tag:
		#partial switch t.tag {
		case .Tr:
			clear_to(t, .Body_Context)
			if _, ok := insert_for(t, tok); ok { t.mode = .In_Row }
			return false
		case .Th, .Td:
			misplaced(t, .Unexpected_Start_Tag); clear_to(t, .Body_Context)
			if _, ok := insert_implied(t, .Tr); !ok { return false }
			t.mode = .In_Row; return true
		case .Caption, .Col, .Colgroup, .Tbody, .Tfoot, .Thead:
			return close_table_ctx(t, {.Tbody, .Thead, .Tfoot}, .Body_Context, .In_Table)
		}
	case .End_Tag:
		#partial switch t.tag {
		case .Tbody, .Tfoot, .Thead:
			close_table_ctx(t, {t.tag}, .Body_Context, .In_Table); return false
		case .Table:
			return close_table_ctx(t, {.Tbody, .Thead, .Tfoot}, .Body_Context, .In_Table)
		case .Body, .Caption, .Col, .Colgroup, .Html, .Td, .Th, .Tr:
			misplaced(t, .Unexpected_End_Tag); return false
		}
	}
	return in_table(t, tok)
}

@(private)
in_row :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch tok.kind {
	case .Start_Tag:
		#partial switch t.tag {
		case .Th, .Td:
			clear_to(t, .Row_Context)
			if _, ok := insert_for(t, tok); ok { t.mode = .In_Cell; push_marker(t) }
			return false
		case .Caption, .Col, .Colgroup, .Tbody, .Tfoot, .Thead, .Tr:
			return close_table_ctx(t, {.Tr}, .Row_Context, .In_Table_Body)
		}
	case .End_Tag:
		#partial switch t.tag {
		case .Tr:    close_table_ctx(t, {.Tr}, .Row_Context, .In_Table_Body); return false
		case .Table: return close_table_ctx(t, {.Tr}, .Row_Context, .In_Table_Body)
		case .Tbody, .Tfoot, .Thead:
			if !in_scope(t, {t.tag}, TABLE_SCOPE) { misplaced(t, .Unexpected_End_Tag); return false }
			return in_scope(t, {.Tr}, TABLE_SCOPE) && close_table_ctx(t, {.Tr}, .Row_Context, .In_Table_Body)
		case .Body, .Caption, .Col, .Colgroup, .Html, .Td, .Th:
			misplaced(t, .Unexpected_End_Tag); return false
		}
	}
	return in_table(t, tok)
}

@(private)
close_cell :: proc(t: ^Html_Tree) {
	close_implied(t)
	if n := current_node(t); !is_html(n, .Td) && !is_html(n, .Th) { misplaced(t, .Unclosed_Element) }
	pop_until(t, {.Td, .Th}); clear_to_marker(t); t.mode = .In_Row
}

@(private)
in_cell :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	#partial switch tok.kind {
	case .End_Tag:
		#partial switch t.tag {
		case .Td, .Th:
			if !in_scope(t, {t.tag}, TABLE_SCOPE) { misplaced(t, .Unexpected_End_Tag); return false }
			pop_closed(t, t.tag); clear_to_marker(t); t.mode = .In_Row; return false
		case .Body, .Caption, .Col, .Colgroup, .Html:
			misplaced(t, .Unexpected_End_Tag); return false
		case .Table, .Tbody, .Tfoot, .Thead, .Tr:
			if !in_scope(t, {t.tag}, TABLE_SCOPE) { misplaced(t, .Unexpected_End_Tag); return false }
			close_cell(t); return true
		}
	case .Start_Tag:
		if t.tag in (Tags{.Caption, .Col, .Colgroup, .Tbody, .Td, .Tfoot, .Th, .Thead, .Tr}) { close_cell(t); return true }
	}
	return in_body(t, tok)
}

@(private)
reread_in_body :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	unexpected(t, tok)
	t.mode = .In_Body
	if tok.kind != .End_Tag || t.tag != .Body && t.tag != .Html { t.body_end, t.html_hi = {}, 0 }
	return true
}

@(private)
after_body :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	switch tok.kind {
	case .Text:                  if !take_space(t, tok, body = true) { return false }
	case .Comment, .Instruction: insert_misc(t, tok, t.stack[0]); return false
	case .Doctype:               misplaced(t, .Unexpected_Doctype); return false
	case .Start_Tag:             if t.tag == .Html { return in_body(t, tok) }
	case .End_Tag:
		if t.tag == .Html {
			if t.context_element != 0 { misplaced(t, .Unexpected_End_Tag); return false }
			t.mode = .After_After_Body
			if t.html_hi == 0 { t.html_hi = tok.hi }
			return false
		}
	case EOF: return false
	}
	return reread_in_body(t, tok)
}

@(private)
in_frameset :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	switch tok.kind {
	case .Text:                  insert_spaces(t, tok.data); return false
	case .Comment, .Instruction: insert_misc(t, tok); return false
	case .Doctype:
	case .Start_Tag:
		#partial switch t.tag {
		case .Html:     return in_body(t, tok)
		case .Frameset: insert_for(t, tok); return false
		case .Frame:    insert_void(t, tok); return false
		case .Noframes: return in_head(t, tok)
		}
	case .End_Tag:
		if t.tag == .Frameset {
			if len(t.stack) == 1 { misplaced(t, .Unexpected_End_Tag); return false }
			pop_current(t)
			if t.context_element == 0 && !is_html(current_node(t), .Frameset) { t.mode = .After_Frameset }
			return false
		}
	case EOF:
		if len(t.stack) > 1 { misplaced(t, .Unclosed_Element) }
		return false
	}
	unexpected(t, tok)
	return false
}

@(private)
after_frameset :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	switch tok.kind {
	case .Text:                  insert_spaces(t, tok.data); return false
	case .Comment, .Instruction: insert_misc(t, tok); return false
	case .Doctype:
	case .Start_Tag:
		if t.tag == .Html { return in_body(t, tok) }
		if t.tag == .Noframes { return in_head(t, tok) }
	case .End_Tag: if t.tag == .Html { t.mode = .After_After_Frameset; return false }
	case EOF:      return false
	}
	unexpected(t, tok)
	return false
}

@(private)
after_after_body :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	switch tok.kind {
	case .Comment, .Instruction: insert_misc(t, tok, DOCUMENT); return false
	case .Doctype:               return in_body(t, tok)
	case .Text:                  if !take_space(t, tok, body = true) { return false }
	case .Start_Tag:             if t.tag == .Html { return in_body(t, tok) }
	case .End_Tag:
	case EOF:                    return false
	}
	return reread_in_body(t, tok)
}

@(private)
after_after_frameset :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	switch tok.kind {
	case .Comment, .Instruction: insert_misc(t, tok, DOCUMENT); return false
	case .Doctype:               return in_body(t, tok)
	case .Text:                  insert_spaces(t, tok.data, body = true); return false
	case .Start_Tag:
		if t.tag == .Html { return in_body(t, tok) }
		if t.tag == .Noframes { return in_head(t, tok) }
	case .End_Tag:
	case EOF: return false
	}
	unexpected(t, tok)
	return false
}

@(private)
in_template :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	switch tok.kind {
	case .Text, .Comment, .Instruction, .Doctype: return in_body(t, tok)
	case .Start_Tag:
		#partial switch t.tag {
		case .Base, .Basefont, .Bgsound, .Link, .Meta, .Noframes, .Script, .Style, .Template, .Title: return in_head(t, tok)
		case .Caption, .Colgroup, .Tbody, .Tfoot, .Thead: return template_mode(t, .In_Table)
		case .Col:     return template_mode(t, .In_Column_Group)
		case .Tr:      return template_mode(t, .In_Table_Body)
		case .Td, .Th: return template_mode(t, .In_Row)
		}
		return template_mode(t, .In_Body)
	case .End_Tag:
		if t.tag == .Template { return in_head(t, tok) }
		misplaced(t, .Unexpected_End_Tag)
	case EOF:
		if !has_template(t) { return false }
		misplaced(t, .Unclosed_Element)
		pop_until(t, {.Template}); clear_to_marker(t); pop(&t.templates); reset_insertion_mode(t)
		return true
	}
	return false
}

@(private)
template_mode :: proc(t: ^Html_Tree, mode: Insertion_Mode) -> bool {
	t.templates[len(t.templates) - 1] = mode
	t.mode = mode
	return true
}
