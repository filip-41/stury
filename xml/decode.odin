package xml

import spell "../core/spell"

// Decoding of text the walk has judged. With no DTD a decode is never longer than its span, so a buffer of the span's
// length holds it. A reference to an entity of a DTD decodes to its replacement text, which `expansion_room` sizes.

// Decodes the content of an element, the text between its tags: references are replaced by their characters, a CDATA
// section by its bytes, a comment or a processing instruction by nothing, and CR LF and CR by LF. A reference to an
// entity of `dtd` is replaced by its replacement text, decoded the same way, and any other by its own text. Returns
// false when `buf` is too short.
@(private)
content_text :: proc "contextless" (span: []u8, buf: []u8, dtd: ^Dtd_View = nil, src: []u8 = nil) -> (s: string, ok: bool) #no_bounds_check {
	if dtd != nil && dtd.head != nil {
		x := Expander{dtd, src, buf, 0}
		ok = expand(&x, span, true, false, 0)
		return string(buf[:x.w]), ok
	}
	if len(buf) < len(span) {
		return "", false
	}
	w, i := 0, 0
	for i < len(span) {
		switch c := span[i]; c {
		case '&':
			n, r, named := decode_reference(span[i:])
			if named {
				copy(buf[w:], span[i:i + n])
				w += n
			} else {
				w += put_rune(buf[w:], r)
			}
			i += n
		case '\r':
			buf[w] = '\n'
			w += 1
			i += 2 if i + 1 < len(span) && span[i + 1] == '\n' else 1
		case '<':
			i = markup_text(span, i, buf, &w, true)
		case:
			buf[w] = c
			w += 1
			i += 1
		}
	}
	return string(buf[:w]), true
}

// Decodes the comment, instruction or CDATA section at `span[i]`, a `<`, into `buf` at `w^`: a CDATA section's bytes,
// with its line ends read as LF when `lines`, and nothing for the others. Returns the index past it.
@(private)
markup_text :: proc "contextless" (span: []u8, i: int, buf: []u8, w: ^int, lines: bool) -> int #no_bounds_check {
	i := i
	if span[i + 1] == '!' && span[i + 2] == '[' {
		i += len("<![CDATA[")
		for !(span[i] == ']' && span[i + 1] == ']' && span[i + 2] == '>') {
			b := span[i]
			if b == '\r' && lines {
				b = '\n'
				if span[i + 1] == '\n' {
					i += 1
				}
			}
			buf[w^] = b
			w^ += 1
			i += 1
		}
		return i + 3
	}
	if span[i + 1] == '!' {
		i += 4
		for !(span[i] == '-' && span[i + 1] == '-' && span[i + 2] == '>') {
			i += 1
		}
		return i + 3
	}
	i += 2
	for !(span[i] == '?' && span[i + 1] == '>') {
		i += 1
	}
	return i + 2
}

// Decodes the value of an attribute, the bytes between its quotes: references are replaced by their characters, and a
// tab, an LF, a CR LF or a CR that is written, not referred to, by one space. A reference to an entity of `dtd` is
// replaced by its replacement text, whose tabs, LFs and CRs read as spaces. A value of a `tokenized` type then loses
// its leading and trailing spaces, and each run of spaces is one.
@(private)
attribute_text :: proc "contextless" (span: []u8, buf: []u8, dtd: ^Dtd_View = nil, src: []u8 = nil, tokenized := false) -> (s: string, ok: bool) #no_bounds_check {
	if dtd != nil && dtd.head != nil {
		x := Expander{dtd, src, buf, 0}
		ok = expand(&x, span, true, true, 0)
		s = string(buf[:x.w])
		if tokenized {
			s = collapse(buf[:x.w])
		}
		return
	}
	if len(buf) < len(span) {
		return "", false
	}
	w, i := 0, 0
	for i < len(span) {
		switch c := span[i]; c {
		case '&':
			n, r, named := decode_reference(span[i:])
			if named {
				copy(buf[w:], span[i:i + n])
				w += n
			} else {
				w += put_rune(buf[w:], r)
			}
			i += n
		case '\r':
			buf[w] = ' '
			w += 1
			i += 2 if i + 1 < len(span) && span[i + 1] == '\n' else 1
		case '\n', '\t':
			buf[w] = ' '
			w += 1
			i += 1
		case:
			buf[w] = c
			w += 1
			i += 1
		}
	}
	return string(buf[:w]), true
}

// The decode of a text that refers to the entities of `v`, written into `buf` at `w`.
@(private)
Expander :: struct {
	v:   ^Dtd_View,
	src: []u8,
	buf: []u8,
	w:   int,
}

// Decodes `span` into the expander's buffer, as `attribute_text` when `attr` and as `content_text` otherwise. A
// replacement text, `top` false, is read with its CRs as written, since only the document's line ends are normalized.
// Returns false when the buffer is too short.
@(private, cold)
expand :: proc "contextless" (x: ^Expander, span: []u8, top, attr: bool, nest: int) -> bool #no_bounds_check {
	i := 0
	for i < len(span) {
		c := span[i]
		switch {
		case c == '&':
			n, r, named := decode_reference(span[i:])
			i += n
			if !named {
				if x.w + rune_size(r) > len(x.buf) {
					return false
				}
				x.w += put_rune(x.buf[x.w:], r)
				continue
			}
			name := span[i - n + 1:i - 1]
			if j := dtd_find(x.v, .General, name); j != NO_DECL && nest < MAX_NEST {
				e := &x.v.entities[j]
				if e.flags & {.External, .Unparsed} == {} {
					if !expand(x, entity_text(x.v, x.src, e), false, attr, nest + 1) {
						return false
					}
					continue
				}
			} else if .Html in x.v.head.flags {
				if value, ok := spell.entity_named(name); ok {
					if !put_bytes(x, value) {
						return false
					}
					continue
				}
			}
			if !put_bytes(x, span[i - n:i]) {
				return false
			}
		case c == '\r' && top:
			if !put_bytes(x, {' ' if attr else '\n'}) {
				return false
			}
			i += 2 if i + 1 < len(span) && span[i + 1] == '\n' else 1
		case attr && (c == '\t' || c == '\n' || c == '\r'):
			if !put_bytes(x, {' '}) {
				return false
			}
			i += 1
		case c == '<' && !attr:
			// A comment or an instruction decodes to nothing and a CDATA section to fewer bytes than it spans.
			if len(x.buf) - x.w < markup_end_index(span, i) - i {
				return false
			}
			i = markup_text(span, i, x.buf, &x.w, top)
		case:
			if !put_bytes(x, span[i:i + 1]) {
				return false
			}
			i += 1
		}
	}
	return true
}

@(private)
put_bytes :: #force_inline proc "contextless" (x: ^Expander, b: []u8) -> bool {
	if len(x.buf) - x.w < len(b) {
		return false
	}
	copy(x.buf[x.w:], b)
	x.w += len(b)
	return true
}

@(private)
rune_size :: #force_inline proc "contextless" (r: rune) -> int {
	return 1 if r < 0x80 else 2 if r < 0x800 else 3 if r < 0x10000 else 4
}

// The index past the comment, instruction or CDATA section at `span[i]`, which the walk judged.
@(private)
markup_end_index :: proc "contextless" (span: []u8, i: int) -> int {
	p := raw_data(span)
	return int(uintptr(markup_end(p[i:], p[len(span):])) - uintptr(p))
}

// Removes the leading and trailing spaces of `b` and makes each run of spaces one, in place.
@(private)
collapse :: proc "contextless" (b: []u8) -> string #no_bounds_check {
	w := 0
	space := false
	for c in b {
		if c == ' ' {
			space = w > 0
			continue
		}
		if space {
			b[w] = ' '
			w += 1
			space = false
		}
		b[w] = c
		w += 1
	}
	return string(b[:w])
}

// Returns the length of the reference at `p`, where `p[0]` is `&` and the walk has judged it, and the character it
// stands for, or `named` for a reference to an entity other than the predefined ones.
@(private)
decode_reference :: proc "contextless" (p: []u8) -> (n: int, r: rune, named: bool) #no_bounds_check {
	if p[1] != '#' {
		n = 1
		for p[n] != ';' {
			n += 1
		}
		ok: bool
		r, ok = predefined(p[1:n])
		return n + 1, r, !ok
	}
	base := rune(10)
	n = 2
	if p[n] == 'x' {
		base = 16
		n += 1
	}
	for p[n] != ';' {
		c := p[n]
		d: rune
		switch {
		case c <= '9':
			d = rune(c - '0')
		case c <= 'F':
			d = rune(c - 'A' + 10)
		case:
			d = rune(c - 'a' + 10)
		}
		r = r * base + d
		n += 1
	}
	return n + 1, r, false
}

// Writes `r` as UTF-8 at the start of `buf`, which holds room for it. Returns its length.
@(private)
put_rune :: proc "contextless" (buf: []u8, r: rune) -> int #no_bounds_check {
	switch {
	case r < 0x80:
		buf[0] = u8(r)
		return 1
	case r < 0x800:
		buf[0] = 0xc0 | u8(r >> 6)
		buf[1] = 0x80 | u8(r & 0x3f)
		return 2
	case r < 0x10000:
		buf[0] = 0xe0 | u8(r >> 12)
		buf[1] = 0x80 | u8(r >> 6 & 0x3f)
		buf[2] = 0x80 | u8(r & 0x3f)
		return 3
	}
	buf[0] = 0xf0 | u8(r >> 18)
	buf[1] = 0x80 | u8(r >> 12 & 0x3f)
	buf[2] = 0x80 | u8(r >> 6 & 0x3f)
	buf[3] = 0x80 | u8(r & 0x3f)
	return 4
}
