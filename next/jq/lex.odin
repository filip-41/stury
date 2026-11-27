package jq

// jq's lexer, src/lexer.l: longest match wins, then earlier rule. Also number/string/UTF-8 decoding.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/query"

@(private)
lex :: proc(p: ^Parser) -> (Sym, Sem, Loc) {
	s := p.src
	if len(p.modes) > 0 && p.modes[len(p.modes) - 1] == .String {
		return lex_in_string(p)
	}
	for p.pos < len(s) {
		start := p.pos
		if kernel.is_ws(s[start]) {
			for p.pos < len(s) && kernel.is_ws(s[p.pos]) {
				p.pos += 1
			}
			p.last = {start, p.pos}
			continue
		}
		if s[start] == '#' {
			skip_comment(p)
			continue
		}
		break
	}
	if p.pos >= len(s) {
		return .End, {}, p.last
	}
	start := p.pos
	sym, sem := lex_token(p)
	p.last = {start, p.pos}
	return sym, sem, p.last
}

@(private = "file")
skip_comment :: proc(p: ^Parser) {
	s := p.src
	p.last = {p.pos, p.pos + 1}
	p.pos += 1
	for p.pos < len(s) {
		start := p.pos
		rest := s[start:]
		switch {
		case rest[0] == '\n', strings.has_prefix(rest, "\r\n"):
			p.pos += 1 if rest[0] == '\n' else 2
			p.last = {start, p.pos}
			return
		case strings.has_prefix(rest, "\\\\"), strings.has_prefix(rest, "\\\n"):
			p.pos += 2
		case strings.has_prefix(rest, "\\\r\n"):
			p.pos += 3
		case:
			p.pos += 1
		}
		p.last = {start, p.pos}
	}
}

@(private = "file", rodata)
KEYWORDS := [?]struct { text: string, sym: Sym }{
	{"as", .As}, {"import", .Import}, {"include", .Include}, {"module", .Module}, {"def", .Def}, {"if", .If}, {"then", .Then}, {"else", .Else}, {"elif", .Elif}, {"and", .And}, {"or", .Or}, {"end", .End_Kw}, {"reduce", .Reduce}, {"foreach", .Foreach}, {"try", .Try}, {"catch", .Catch}, {"label", .Label}, {"break", .Break},
}

@(private = "file", rodata)
OPERATORS := [?]struct { text: string, sym: Sym }{
	{"?//", .Alternation}, {"//=", .Set_Alt}, {"!=", .Neq}, {"==", .Eq}, {"//", .Alt}, {"|=", .Set_Pipe}, {"+=", .Set_Plus}, {"-=", .Set_Minus}, {"*=", .Set_Mult}, {"/=", .Set_Div}, {"%=", .Set_Mod}, {"<=", .Less_Eq}, {">=", .Greater_Eq}, {"..", .Rec}, {"?", .Question}, {"=", .Assign}, {";", .Semi}, {",", .Comma}, {":", .Colon}, {"|", .Pipe}, {"+", .Plus}, {"-", .Minus}, {"*", .Star}, {"/", .Slash}, {"%", .Percent}, {"<", .Less}, {">", .Greater},
}

@(private = "file")
fact_accessor :: proc(rest: string) -> (name: string, known: bool) {
	end := run_end(rest, 1, ident_byte)
	name = rest[:end]
	if len(name) == 1 {
		return "", true
	}
	_, known = query.fact_named(name[1:])
	for end < len(rest) && kernel.is_ws(rest[end]) {
		end += 1
	}
	if end < len(rest) && rest[end] == '"' {
		return "", true
	}
	return name, known
}

@(private = "file")
lex_token :: proc(p: ^Parser) -> (Sym, Sem) {
	s := p.src
	start := p.pos
	c := s[start]
	next: u8 = s[start + 1] if start + 1 < len(s) else 0
	after: u8 = s[start + 2] if start + 2 < len(s) else 0
	fact, known := "", true
	if c == '.' && next == '@' {
		fact, known = fact_accessor(s[start + 1:])
	}
	switch {
	case c == '.' && (next == '@' && after == '(' || next == '&' && after == '['):
		p.computed[start + 2] = .Fact if next == '@' else .Attribute
		p.pos += 2
		return .Dot, {}
	case c == '(' && p.computed[start] == .Fact:
		p.pos += 1
		append(&p.modes, Mode.Fact)
		return .LBracket, {}
	case is_digit(c) || (c == '.' && is_digit(next)):
		return .Literal, {value = lex_number(p)}
	case !known && len(fact) > 1:
		p.pos += 1 + len(fact)
		report(p, {start, p.pos}, fmt.aprintf("unknown fact .%s, the facts are %s", fact, query.FACT_LIST))
		return .Field, {text = "@comment"}
	case fact != "":
		p.pos += 1 + len(fact)
		return .Field, {text = fact}
	case c == '.' && next == '&' && start + 2 < len(s) && (ident_start(s[start + 2]) || s[start + 2] == '"'):
		return lex_attribute(p)
	case c == '.' && ident_start(next):
		p.pos = run_end(s, start + 1, ident_byte)
		return .Field, {text = s[start + 1:p.pos]}
	case c == '$' && ident_start(next):
		p.pos += 1
		name := take_ident(p)
		return Sym.Loc if name == "__loc__" else Sym.Binding, {text = name}
	case ident_start(c):
		name := take_ident(p)
		for k in KEYWORDS {
			if k.text == name {
				return k.sym, {text = name}
			}
		}
		return .Ident, {text = name}
	case c == '@' && ident_byte(next):
		p.pos = run_end(s, start + 1, ident_byte)
		return .Format, {text = s[start + 1:p.pos]}
	case c == '"':
		p.pos += 1
		append(&p.modes, Mode.String)
		return .QQ_Start, {}
	case c == '(' || c == '[' || c == '{':
		p.pos += 1
		append(&p.modes, Mode.Paren if c == '(' else (Mode.Bracket if c == '[' else Mode.Brace))
		return Sym.LParen if c == '(' else (Sym.LBracket if c == '[' else Sym.LBrace), {}
	case c == ')' || c == ']' || c == '}':
		p.pos += 1
		return close_bracket(p, c), {}
	}
	for op in OPERATORS {
		if strings.has_prefix(s[start:], op.text) {
			p.pos += len(op.text)
			return op.sym, {}
		}
	}
	p.pos += 1
	return (.Dot if c == '.' else (.Dollar if c == '$' else .Invalid)), {}
}

@(private = "file")
lex_attribute :: proc(p: ^Parser) -> (Sym, Sem) {
	s, at := p.src, p.pos + 2
	if s[at] == '"' {
		end := at + 1
		for end < len(s) && s[end] != '"' {
			end += 1
		}
		if end >= len(s) {
			p.pos = end
			report(p, {p.pos - 1, p.pos}, "unterminated attribute name")
			return .Field, {text = "&"}
		}
		p.pos = end + 1
		return .Field, {text = strings.concatenate({"&", s[at + 1:end]})}
	}
	end := at
	for end < len(s) && (ident_byte(s[end]) || s[end] == ':' || s[end] == '-') {
		end += 1
	}
	p.pos = end
	return .Field, {text = s[at - 1:end]}
}

@(private = "file")
close_bracket :: proc(p: ^Parser, c: u8) -> Sym {
	CLOSING := [Mode]struct { c: u8, sym: Sym }{
		.Paren = {')', .RParen}, .Bracket = {']', .RBracket}, .Brace = {'}', .RBrace},
		.Interp = {')', .QQ_Interp_End}, .Fact = {')', .RBracket}, .String = {},
	}
	if len(p.modes) == 0 || CLOSING[p.modes[len(p.modes) - 1]].c != c {
		return .Invalid
	}
	return CLOSING[pop(&p.modes)].sym
}

@(private = "file")
lex_number :: proc(p: ^Parser) -> query.Value {
	s, start := p.src, p.pos
	i := run_end(s, start, is_digit)
	if i < len(s) && s[i] == '.' {
		i = run_end(s, i + 1, is_digit)
	}
	if i < len(s) && s[i] | 0x20 == 'e' {
		j := i + 1 + int(i + 1 < len(s) && (s[i + 1] == '+' || s[i + 1] == '-'))
		if j < len(s) && is_digit(s[j]) {
			i = run_end(s, j, is_digit)
		}
	}
	p.pos = i
	v, _ := read_number(&p.unit.heap, s[start:i])
	return query.freeze(v)
}

@(private = "file")
lex_in_string :: proc(p: ^Parser) -> (sym: Sym, sem: Sem, loc: Loc) {
	s, start := p.src, p.pos
	if start >= len(s) {
		return .End, {}, p.last
	}
	switch {
	case strings.has_prefix(s[start:], "\\("):
		p.pos += 2
		append(&p.modes, Mode.Interp)
		sym = .QQ_Interp_Start
	case s[start] == '"':
		p.pos += 1
		pop(&p.modes)
		sym = .QQ_End
	case s[start] == '\\':
		end := start
		for end + 1 < len(s) && s[end] == '\\' && s[end + 1] != '(' {
			if s[end + 1] != 'u' {
				end += 2
				continue
			}
			j := end + 2
			for j < len(s) && j < end + 6 && ident_byte(s[j]) && s[j] != '_' {
				j += 1
			}
			end = j
		}
		if end == start {
			p.pos += 1
			sym = .Invalid
		} else {
			p.pos, sym, sem.value = end, .QQ_Text, unescape(p, s[start:end], {start, end})
		}
	case:
		end := start
		for end < len(s) && s[end] != '\\' && s[end] != '"' {
			end += 1
		}
		p.pos, sym, sem.value = end, .QQ_Text, query.text_borrowed(s[start:end])
	}
	p.last = {start, p.pos}
	return sym, sem, p.last
}

@(private = "file")
unescape :: proc(p: ^Parser, run: string, at: Loc) -> query.Value {
	b := strings.builder_make()
	msg := decode_string(&b, run)
	if msg == "" {
		return query.text_borrowed(strings.to_string(b))
	}
	line, column := 1, 1
	for ch in transmute([]byte)run {
		column += 1
		if ch == '\n' {
			line, column = line + 1, 0
		}
	}
	report(p, at, fmt.aprintf("%s at line %d, column %d (while parsing '\"%s\"')", msg, line, column + 1, run))
	return query.NULL
}

@(private = "file")
is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }

@(private = "file")
ident_start :: proc(c: u8) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

@(private)
ident_byte :: proc(c: u8) -> bool { return ident_start(c) || is_digit(c) }

@(private = "file")
run_end :: proc(s: string, at: int, in_run: proc(c: u8) -> bool) -> int {
	end := at
	for end < len(s) && in_run(s[end]) {
		end += 1
	}
	return end
}

@(private = "file")
take_ident :: proc(p: ^Parser) -> string {
	s, start := p.src, p.pos
	for {
		p.pos = run_end(s, p.pos, ident_byte)
		if p.pos + 2 < len(s) && s[p.pos] == ':' && s[p.pos + 1] == ':' && ident_start(s[p.pos + 2]) {
			p.pos += 2
			continue
		}
		return s[start:p.pos]
	}
}

@(private)
read_number :: proc(h: ^query.Heap, text: string) -> (query.Value, bool) {
	if strings.index_byte(text, 0) >= 0 {
		return query.NULL, false
	}
	t, neg := text, false
	if len(t) > 0 && (t[0] == '+' || t[0] == '-') {
		neg, t = t[0] == '-', t[1:]
	}
	if len(t) > 0 && t[0] | 0x20 >= 'a' && t[0] | 0x20 <= 'z' {
		lower := strings.to_lower(t)
		defer delete(lower)
		if lower == "inf" || lower == "infinity" {
			return query.double_value(math.inf_f64(-1 if neg else 1)), true
		}
		if strings.has_prefix(lower, "nan") || strings.has_prefix(lower, "snan") {
			if strings.trim_left(lower[3 if lower[0] == 'n' else 4:], "0") != "" {
				return query.NULL, false
			}
			return query.double_value(math.nan_f64()), true
		}
	}
	v, ok, _ := query.parse_number(h, text, true)
	return v, ok
}

@(private)
decode_string :: proc(out: ^strings.Builder, in_: string, lone_low_surrogate_at: ^int = nil) -> string {
	s := transmute([]byte)in_
	for i := 0; i < len(s); {
		run_start := i
		for i < len(s) && s[i] != '\\' && s[i] >= 0x20 {
			i += 1
		}
		strings.write_string(out, in_[run_start:i])
		if i == len(s) {
			break
		}
		if s[i] != '\\' {
			return "Invalid string: control characters from U+0000 through U+001F must be escaped"
		}
		if i + 1 == len(s) {
			return "Expected escape character at end of string"
		}
		if b := spell.ESCAPED[s[i + 1]]; b != 0 {
			strings.write_byte(out, b)
			i += 2
			continue
		}
		if s[i + 1] != 'u' {
			return "Invalid escape"
		}
		if len(s) - (i + 2) < 4 {
			return "Invalid \\uXXXX escape"
		}
		cp, hex_ok := spell.hex4(raw_data(s[i + 2:]))
		if !hex_ok {
			return "Invalid characters in \\uXXXX escape"
		}
		next := i + 6
		if spell.low_surrogate(cp) {
			if lone_low_surrogate_at != nil {
				lone_low_surrogate_at^ = i
			}
			return "Invalid escape"
		}
		if spell.high_surrogate(cp) {
			if next + 6 > len(s) || s[next] != '\\' || s[next + 1] != 'u' {
				return "Invalid \\uXXXX\\uXXXX surrogate pair escape"
			}
			low, low_ok := spell.hex4(raw_data(s[next + 2:]))
			if !low_ok || !spell.low_surrogate(low) {
				return "Invalid \\uXXXX\\uXXXX surrogate pair escape"
			}
			cp, next = u32(spell.surrogate_pair(cp, low)), next + 6
		}
		strings.write_rune(out, rune(cp))
		i = next
	}
	return ""
}

@(private)
valid_utf8 :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_valid_utf8(&b, s)
	return strings.to_string(b)
}

@(private)
write_valid_utf8 :: proc(b: ^strings.Builder, s: string) {
	run := 0
	for i := 0; i < len(s); {
		if s[i] < 0x80 {
			i += 1
			continue
		}
		n, ok := utf8_next(s[i:])
		if !ok {
			strings.write_string(b, s[run:i])
			strings.write_rune(b, utf8.RUNE_ERROR)
			run = i + n
		}
		i += n
	}
	strings.write_string(b, s[run:])
}

@(private)
utf8_next :: proc(s: string) -> (n: int, ok: bool) {
	c := s[0]
	if c < 0x80 {
		return 1, true
	}
	if c < 0xc2 || c > 0xf4 {
		return 1, false
	}
	n = spell.lead_width(c)
	if n > len(s) {
		return len(s), false
	}
	cp := rune(c) & (0x1f if n == 2 else (0x0f if n == 3 else 0x07))
	for i in 1 ..< n {
		if s[i] & 0xc0 != 0x80 {
			return i, false
		}
		cp = cp << 6 | rune(s[i] & 0x3f)
	}
	first := [5]rune{0, 0, 0x80, 0x800, 0x10000}
	return n, cp >= first[n] && !(0xd800 <= cp && cp <= 0xdfff) && cp <= 0x10ffff
}
