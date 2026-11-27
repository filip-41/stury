package xml

import "base:intrinsics"
import "core:unicode/utf8"
import "stury:lib/base/spell"

// Decoding of text the walk has judged. With no DTD a decode is never longer than its span, so a buffer of the span's
// length holds it. A reference to an entity of a DTD decodes to its replacement text, which `expansion_room` sizes.

// Decodes the content of an element, the text between its tags: references are replaced by their characters, a CDATA
// section by its bytes, a comment or a processing instruction by nothing, and CR LF and CR by LF. A reference to an
// entity of `dtd` is replaced by its replacement text, decoded the same way, and any other by its own text. Returns
// false when `buf` is too short.
@(private)
content_text :: proc "contextless" (span: []u8, buf: []u8, dtd: ^Dtd_View = nil, src: []u8 = nil) -> (s: string, ok: bool) #no_bounds_check {
	return decode_text(span, buf, dtd, src, false, false)
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
	p := raw_data(span)
	past, _ := markup_end(p[i:], p[len(span):])
	return intrinsics.ptr_sub(past, p)
}

// Decodes the value of an attribute, the bytes between its quotes: references are replaced by their characters, and a
// tab, an LF, a CR LF or a CR that is written, not referred to, by one space. A reference to an entity of `dtd` is
// replaced by its replacement text, whose tabs, LFs and CRs read as spaces. A value of a `tokenized` type then loses
// its leading and trailing spaces, and each run of spaces is one.
@(private)
attribute_text :: proc "contextless" (span: []u8, buf: []u8, dtd: ^Dtd_View = nil, src: []u8 = nil, tokenized := false) -> (s: string, ok: bool) #no_bounds_check {
	return decode_text(span, buf, dtd, src, true, tokenized)
}

@(private)
decode_text :: #force_inline proc "contextless" (span, buf: []u8, dtd: ^Dtd_View, src: []u8, $ATTR: bool, tokenized: bool) -> (s: string, ok: bool) #no_bounds_check {
	if dtd != nil {
		x := Expander{dtd, src, buf, 0}
		ok = expand(&x, span, true, ATTR, 0)
		s = collapse(buf[:x.w]) if ATTR && tokenized else string(buf[:x.w])
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
				w += rune_text(buf[w:], r)
			}
			i += n
		case '\r':
			buf[w] = ' ' when ATTR else '\n'
			w += 1
			i += 2 if i + 1 < len(span) && span[i + 1] == '\n' else 1
		case '\n', '\t':
			buf[w] = ' ' when ATTR else c
			w += 1
			i += 1
		case '<':
			when !ATTR {
				i = markup_text(span, i, buf, &w, true)
			} else {
				buf[w] = c
				w += 1
				i += 1
			}
		case:
			buf[w] = c
			w += 1
			i += 1
		}
	}
	return collapse(buf[:w]) if ATTR && tokenized else string(buf[:w]), true
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
				if x.w + utf8.rune_size(r) > len(x.buf) {
					return false
				}
				x.w += rune_text(x.buf[x.w:], r)
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
			} else if .Html in x.v.flags {
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
			p := raw_data(span)
			past, _ := markup_end(p[i:], p[len(span):])
			if len(x.buf) - x.w < intrinsics.ptr_sub(past, p[i:]) {
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
		r = r * base + rune(spell.HEX_NIBBLE[p[n]])
		n += 1
	}
	return n + 1, r, false
}

// Writes code point `r` as UTF-8 at the start of `buf`, which has room for it, and returns its length. A surrogate or a
// value past U+10FFFF writes U+FFFD.
@(private)
rune_text :: #force_inline proc "contextless" (buf: []u8, r: rune) -> int {
	s, n := utf8.encode_rune(r)
	copy(buf, s[:n])
	return n
}
