#+private
package regex

// Parses escapes at `\` outside a class, and the single-character escapes that classes share.

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import spell "../spell"

// Parses the escape at `\` outside a class.
parse_escape :: proc(p: ^Parser) -> ^Node {
	esc := p.i
	p.i += 1
	if at_end(p) {
		return fail(p, "end pattern at escape")
	}
	c := peek(p)
	p.i += 1
	if p.flags.ecma {
		return ecma_escape(p, c)
	}
	switch c {
	case 'w', 'W', 'd', 'D', 's', 'S':
		return prop_node(escape_prop(c))
	case 'b', 'B', 'A', 'z', 'Z', 'G':
		kinds := [?]Assert_Kind{.Word_Boundary, .Not_Word_Boundary, .Begin_Buf, .End_Buf, .Semi_End_Buf, .Search_Start}
		return assert_node(kinds[strings.index_byte("bBAzZG", c)])
	case 'K':
		return new_node(.Keep)
	case 'R':
		return new_node(.Linebreak)
	case 'X':
		return new_node(.Grapheme)
	case 'N', 'O':
		n := new_node(.Any)
		n.dotall = c == 'O'
		return n
	case 'p', 'P':
		if peek(p) == '{' && !at_end(p) {
			it, ok := parse_property(p, c == 'P')
			return prop_node(it) if ok else nil
		}
	case 'k':
		if (peek(p) == '<' || peek(p) == '\'') && !at_end(p) {
			return parse_backref_name(p)
		}
	case 'g':
		if (peek(p) == '<' || peek(p) == '\'') && !at_end(p) {
			return parse_call(p)
		}
	case 'Q':
		cat := new_node(.Cat)
		end := strings.index(p.src[p.i:], `\E`)
		lit := p.src[p.i:] if end < 0 else p.src[p.i:][:end]
		for r in lit {
			append(&cat.kids, char_node(p, r))
		}
		p.i += len(lit) if end < 0 else end + 2
		return cat
	case '1' ..= '9':
		start := p.i - 1
		p.i = start
		num, _ := number(p.src, &p.i, MAX_BACKREF + 1)
		if num <= 9 || num < len(p.names) {
			if num > MAX_BACKREF {
				return fail(p, "too big backref number")
			}
			n := new_node(.Backref)
			n.fold = p.flags.fold
			append(&n.refs, num)
			add_ref(p, n)
			return n
		}
		if c == '8' || c == '9' {
			p.i = start + 1
			return char_node(p, rune(c))
		}
	}
	p.i = esc
	r, _, ok := parse_char_escape(p, false)
	return char_node(p, r) if ok else nil
}

// Parses the escape after `\` and its letter `c` outside a class, under ECMA.
@(private = "file")
ecma_escape :: proc(p: ^Parser, c: byte) -> ^Node {
	switch c {
	case 'b':
		return assert_node(.Ascii_Boundary)
	case 'B':
		return assert_node(.Not_Ascii_Boundary)
	case 'd', 'D', 'w', 'W', 's', 'S':
		set, negated := escape_set(c)
		return class_node(set, negated)
	case 'p', 'P':
		it, ok := parse_property(p, c == 'P')
		return prop_node(it) if ok else nil
	case 'k', '1' ..= '9':
		if !p.syntax_only {
			return fail(p, "back references are not supported")
		}
		// When only syntax is judged, `resolve_refs` still checks at the end that the reference names a group.
		n := new_node(.Backref)
		if c != 'k' {
			p.i -= 1
			num, _ := number(p.src, &p.i, MAX_CAPTURES + 1)
			append(&n.refs, num)
		} else if at_end(p) || peek(p) != '<' {
			return fail(p, "invalid named reference")
		} else {
			p.i += 1
			ok: bool
			if n.name, ok = ecma_name(p, '>'); !ok {
				return nil
			}
			if !ecma_identifier(n.name) {
				return fail(p, "invalid named reference")
			}
		}
		append(&p.refs, n)
		return char_node(p, 0)
	}
	r, ok := ecma_char(p, c)
	return char_node(p, r) if ok else nil
}

// Returns the character of an ECMA escape after `\` and its letter `c`: \t \n \v \f \r \0 \cX \xHH, \uHHHH or a pair
// of them for a surrogate pair, \u{H...}, or an escaped syntax character. A lone surrogate is returned as a character
// that no text holds.
ecma_char :: proc(p: ^Parser, c: byte) -> (r: rune, ok: bool) {
	if k := strings.index_byte("tnvfr", c); k >= 0 {
		controls := "\t\n\v\f\r"
		return rune(controls[k]), true
	}
	switch c {
	case '0':
		if spell.HEX_NIBBLE[peek(p)] >= 10 {
			return 0, true
		}
	case 'c':
		if x := peek(p) | 0x20; x >= 'a' && x <= 'z' {
			p.i += 1
			return rune(x - 0x60), true
		}
	case 'x':
		if v, n := number(p.src, &p.i, 0xFF, 16, 2); n == 2 {
			return rune(v), true
		}
	case 'u':
		if peek(p) == '{' {
			p.i += 1
			v, n := number(p.src, &p.i, utf8.MAX_RUNE + 1, 16)
			if n > 0 && v <= utf8.MAX_RUNE && peek(p) == '}' {
				p.i += 1
				return rune(v), true
			}
		} else if v, n := number(p.src, &p.i, 0xFFFF, 16, 4); n == 4 {
			j := p.i + 2
			if low, m := number(p.src, &j, 0xFFFF, 16, 4); spell.high_surrogate(u32(v)) && peek(p) == '\\' && peek(p, 1) == 'u' && m == 4 && spell.low_surrogate(u32(low)) {
				p.i = j
				v = int(spell.surrogate_pair(u32(v), u32(low)))
			}
			return rune(v), true
		}
	case:
		if escaped_punctuation(c, true) {
			return rune(c), true
		}
		_, w := utf8.decode_rune_in_string(p.src[p.i - 1:])
		buf: [20]byte
		fail(p, strings.concatenate({"invalid escape \\", p.src[p.i - 1:][:w], " at offset ", strconv.write_int(buf[:], i64(p.i - 2), 10)}))
		return
	}
	fail(p, "invalid escape")
	return
}

// Parses a single-character escape at `\`: \t \n \r \f \a \e, \xHH, \x{H...}, \0oo, \ooo, \o{o...}, \cX, or the
// escaped character itself. \x and octal give bytes. A byte that starts a UTF-8 sequence is completed by the escapes
// that follow, which give its continuation bytes. In a class a byte that starts no sequence is returned with `lone`
// set, as its byte value.
parse_char_escape :: proc(p: ^Parser, in_class: bool) -> (r: rune, lone: bool, ok: bool) {
	b, is_byte, b_ok := escape_unit(p)
	if !b_ok || !is_byte || b < 0x80 {
		return b, false, b_ok
	}
	if b < 0xC0 && !in_class {
		fail(p, "invalid code point value")
		return 0, false, false
	}
	if b < 0xC0 || b > 0xF7 {
		return b, true, true
	}
	need := 1 if b < 0xE0 else 2 if b < 0xF0 else 3
	buf: [4]byte
	buf[0] = byte(b)
	for k in 1 ..= need {
		if peek(p) != '\\' || at_end(p) {
			fail(p, "too short multibyte code string")
			return 0, false, false
		}
		next, next_byte, next_ok := escape_unit(p)
		if !next_ok {
			return 0, false, false
		}
		if !next_byte || next < 0x80 || next > 0xBF {
			fail(p, "too short multibyte code string")
			return 0, false, false
		}
		buf[k] = byte(next)
	}
	r, _ = utf8.decode_rune(buf[:need + 1])
	return r, false, true
}

// Reads one escape at `\`, or one character. Returns its value, and whether it is a raw byte.
@(private = "file")
escape_unit :: proc(p: ^Parser) -> (r: rune, is_byte: bool, ok: bool) {
	if peek(p) != '\\' {
		return next_rune(p), false, true
	}
	p.i += 1
	if at_end(p) {
		fail(p, "end pattern at escape")
		return 0, false, false
	}
	c := peek(p)
	p.i += 1
	if k := strings.index_byte("tnrfae", c); k >= 0 {
		values := "\t\n\r\f\a\x1b"
		return rune(values[k]), false, true
	}
	switch c {
	case 'x':
		if peek(p) == '{' && !at_end(p) && spell.HEX_NIBBLE[peek(p, 1)] < 16 {
			p.i += 1
			v, n := number(p.src, &p.i, 1 << 40, 16)
			if n > 8 {
				fail(p, "too long wide-char value")
				return 0, false, false
			}
			if at_end(p) || peek(p) != '}' {
				fail(p, "invalid code point value")
				return 0, false, false
			}
			p.i += 1
			return rune(v), false, true
		}
		v, _ := number(p.src, &p.i, 0xFF, 16, 2)
		return rune(v), true, true
	case 'o':
		if peek(p) == '{' && !at_end(p) {
			p.i += 1
			v, _ := number(p.src, &p.i, 0x7FFFFFFF, 8)
			if at_end(p) || peek(p) != '}' {
				fail(p, "invalid code point value")
				return 0, false, false
			}
			p.i += 1
			return rune(v), false, true
		}
	case '0' ..= '7':
		p.i -= 1
		v, _ := number(p.src, &p.i, 0x1FF, 8, 3)
		return rune(v & 0xFF), true, true
	case 'c':
		if at_end(p) {
			fail(p, "end pattern at control")
			return 0, false, false
		}
		x := peek(p)
		p.i += 1
		return 0x7F if x == '?' else rune(x & 0x1F), false, true
	}
	p.i -= 1
	return next_rune(p), false, true
}

// Builds a class node of one property item. \w and \W (TABLE_WORD) keep their negation in the item, as Oniguruma's word
// type. For any other item (\d \s \p{...}) the class itself is negated as a whole, which shows at a lone continuation
// byte.
prop_node :: proc(it: Prop_Item) -> ^Node {
	n := new_node(.Class)
	n.class = new(Class)
	if it.table == TABLE_WORD {
		append(&n.class.props, it)
	} else {
		append(&n.class.props, Prop_Item{table = it.table})
		n.class.negated = it.neg
	}
	return n
}
