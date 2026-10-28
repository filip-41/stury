package regex

// Escapes at `\` outside a class and the single-character escapes a class shares.

import "core:strings"
import "core:unicode/utf8"

// At `\`, outside a class.
@(private)
parse_escape :: proc(p: ^Parser) -> ^Node {
	esc := p.i
	p.i += 1
	if at_end(p) {
		return fail(p, "end pattern at escape")
	}
	c := peek(p)
	p.i += 1
	switch c {
	case 'w', 'W', 'd', 'D', 's', 'S':
		return prop_node(escape_prop(c))
	case 'b':
		return assert_node(.Word_Boundary)
	case 'B':
		return assert_node(.Not_Word_Boundary)
	case 'A':
		return assert_node(.Begin_Buf)
	case 'z':
		return assert_node(.End_Buf)
	case 'Z':
		return assert_node(.Semi_End_Buf)
	case 'G':
		return assert_node(.Search_Start)
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

// At `<` or `'` after \k: `\k<name>`, `\k<n>` or `\k<-n>`.
@(private = "file")
parse_backref_name :: proc(p: ^Parser) -> ^Node {
	close: byte = '>' if peek(p) == '<' else '\''
	p.i += 1
	name, named := read_name(p, close)
	if !named {
		return nil
	}
	n := new_node(.Backref)
	n.fold = p.flags.fold
	switch name[0] {
	case '0' ..= '9', '-', '+':
		num, rel := 0, name[0] == '-'
		digits := name[1:] if name[0] == '-' || name[0] == '+' else name
		if name[0] == '+' || digits == "" {
			return fail(p, "invalid backref number/name")
		}
		j := 0
		if num, _ = number(digits, &j, MAX_BACKREF + 1); j < len(digits) {
			return fail(p, "invalid backref number/name")
		}
		if rel {
			num = len(p.names) - num
		}
		if num <= 0 {
			return fail(p, "invalid backref number/name")
		}
		append(&n.refs, num)
	case:
		n.name = name
		if !resolve_name(p, n) {
			return nil
		}
	}
	add_ref(p, n)
	return n
}

// At `<` or `'` after \g: a call of a group by number, by number relative to the groups opened so far
// (`-1` the last, `+1` the next), or by name, read as Oniguruma's fetch_name reads one, with its messages.
// A name of odd characters is still a name, which no group has.
@(private = "file")
parse_call :: proc(p: ^Parser) -> ^Node {
	close: rune = '>' if peek(p) == '<' else '\''
	p.i += 1
	start := p.i
	if at_end(p) || rune(peek(p)) == close {
		return fail(p, "group name is empty")
	}
	next :: proc(p: ^Parser) -> rune {
		r, w := utf8.decode_rune_in_string(p.src[p.i:])
		p.i += w
		return r
	}
	digit :: proc(r: rune) -> bool {
		return r >= '0' && r <= '9'
	}
	c := next(p)
	numeric, sign := digit(c), c == '-' || c == '+'
	if !numeric && !sign && !is_word(c) {
		for !at_end(p) {
			if c = next(p); c == close || c == ')' {
				break
			}
		}
		return fail(p, strings.concatenate({"invalid char in group name <", p.src[start:p.i], ">"}))
	}
	numeric ||= sign
	name_end := len(p.src)
	for !at_end(p) {
		name_end = p.i
		if c = next(p); c == close || c == ')' {
			break
		}
		numeric &&= digit(c)
	}
	name := p.src[start:name_end]
	if c != close {
		return fail(p, strings.concatenate({"invalid group name <", name, ">"}))
	}
	n := new_node(.Call)
	n.name, n.group = name, -1
	append(&p.calls, n)
	if !numeric {
		return n
	}
	num := 0
	for d in transmute([]byte)(name[1:] if sign else name) {
		if num = num * 10 + int(d - '0'); num > int(max(i32)) {
			return fail(p, "too big number")
		}
	}
	if sign && num == 0 {
		return fail(p, strings.concatenate({"invalid group name <", name, ">"}))
	}
	opened := len(p.names) - 1
	switch name[0] {
	case '-':
		n.group = opened + 1 - num
	case '+':
		n.group = opened + num if num <= int(max(i32)) - opened else -1
	case:
		n.group = num
	}
	if n.group < 0 {
		return fail(p, strings.concatenate({"undefined group <", name, "> reference"}))
	}
	return n
}

// A single-character escape at `\`: \t \n \r \f \a \e, \xHH, \x{H...}, \0oo, \ooo, \o{o...}, \cX, or the
// escaped character itself. \x and octal give bytes, and bytes that start a UTF-8 sequence take the
// escapes that follow to finish it. In a class a byte that starts none is `lone`, its value as it is.
@(private)
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

// One escape at `\`, or one character: its value, and whether it is a raw byte.
@(private = "file")
escape_unit :: proc(p: ^Parser) -> (r: rune, is_byte: bool, ok: bool) {
	if peek(p) != '\\' {
		w: int
		r, w = utf8.decode_rune_in_string(p.src[p.i:])
		p.i += w
		return r, false, true
	}
	p.i += 1
	if at_end(p) {
		fail(p, "end pattern at escape")
		return 0, false, false
	}
	c := peek(p)
	p.i += 1
	digit :: proc(c: byte, base: int) -> int {
		d := -1
		switch c {
		case '0' ..= '9': d = int(c - '0')
		case 'a' ..= 'f': d = int(c - 'a') + 10
		case 'A' ..= 'F': d = int(c - 'A') + 10
		}
		return d if d < base else -1
	}
	switch c {
	case 't': return '\t', false, true
	case 'n': return '\n', false, true
	case 'r': return '\r', false, true
	case 'f': return '\f', false, true
	case 'a': return 0x07, false, true
	case 'e': return 0x1B, false, true
	case 'x':
		if peek(p) == '{' && !at_end(p) && digit(peek(p, 1), 16) >= 0 {
			p.i += 1
			n, v := 0, 0
			for !at_end(p) && digit(peek(p), 16) >= 0 {
				v = v * 16 + digit(peek(p), 16)
				n += 1
				p.i += 1
			}
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
		v := 0
		for k := 0; k < 2 && !at_end(p) && digit(peek(p), 16) >= 0; k += 1 {
			v = v * 16 + digit(peek(p), 16)
			p.i += 1
		}
		return rune(v), true, true
	case 'o':
		if peek(p) == '{' && !at_end(p) {
			p.i += 1
			v := 0
			for !at_end(p) && digit(peek(p), 8) >= 0 {
				v = min(v * 8 + digit(peek(p), 8), 0x7FFFFFFF)
				p.i += 1
			}
			if at_end(p) || peek(p) != '}' {
				fail(p, "invalid code point value")
				return 0, false, false
			}
			p.i += 1
			return rune(v), false, true
		}
	case '0' ..= '7':
		v := int(c - '0')
		for k := 0; k < 2 && !at_end(p) && digit(peek(p), 8) >= 0; k += 1 {
			v = v * 8 + digit(peek(p), 8)
			p.i += 1
		}
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
	w: int
	r, w = utf8.decode_rune_in_string(p.src[p.i:])
	p.i += w
	return r, false, true
}
