package jq

// jq's lexer, src/lexer.l: the longest match wins, then the earlier rule.

import "core:fmt"
import "core:strings"

@(private)
lex :: proc(p: ^Parser) -> (Sym, Sem, Loc) {
	s := p.src
	if len(p.modes) > 0 && p.modes[len(p.modes) - 1] == .String {
		return lex_in_string(p)
	}
	for p.pos < len(s) {
		start := p.pos
		switch s[start] {
		case ' ', '\t', '\n', '\r':
			for p.pos < len(s) && is_space(s[p.pos]) {
				p.pos += 1
			}
			p.last = {start, p.pos}
			continue
		case '#':
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

// A comment, each piece of it a match of its own: a `\` escapes a `\` or a line end.
@(private = "file")
skip_comment :: proc(p: ^Parser) {
	s := p.src
	p.last = {p.pos, p.pos + 1}
	p.pos += 1
	for p.pos < len(s) {
		start := p.pos
		rest := s[start:]
		switch {
		case strings.has_prefix(rest, "\n"), strings.has_prefix(rest, "\r\n"):
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
KEYWORDS := [?]struct {
	text: string,
	sym:  Sym,
}{{"as", .As}, {"import", .Import}, {"include", .Include}, {"module", .Module}, {"def", .Def}, {"if", .If}, {"then", .Then}, {"else", .Else}, {"elif", .Elif}, {"and", .And}, {"or", .Or}, {"end", .End_Kw}, {"reduce", .Reduce}, {"foreach", .Foreach}, {"try", .Try}, {"catch", .Catch}, {"label", .Label}, {"break", .Break}}

@(private = "file", rodata)
OPERATORS := [?]struct {
	text: string,
	sym:  Sym,
}{{"?//", .Alternation}, {"//=", .Set_Alt}, {"!=", .Neq}, {"==", .Eq}, {"//", .Alt}, {"|=", .Set_Pipe}, {"+=", .Set_Plus}, {"-=", .Set_Minus}, {"*=", .Set_Mult}, {"/=", .Set_Div}, {"%=", .Set_Mod}, {"<=", .Less_Eq}, {">=", .Greater_Eq}, {"..", .Rec}, {"?", .Question}, {"=", .Assign}, {";", .Semi}, {",", .Comma}, {":", .Colon}, {"|", .Pipe}, {"+", .Plus}, {"-", .Minus}, {"*", .Star}, {"/", .Slash}, {"%", .Percent}, {"<", .Less}, {">", .Greater}}

// stury's comment accessors, which `rest`, the program after a `.`, starts with: `@comment`, `@comment_inline` or
// `@comment_foot`, "" for anything else. jq reads `.@name` only as `.@name "string"`, a format applied to a string
// key, which stays so: no jq program has one of these.
@(private = "file")
fact_accessor :: proc(rest: string) -> string {
	end := 1
	for end < len(rest) && ident_byte(rest[end]) {
		end += 1
	}
	name := rest[:end]
	if name != "@comment" && name != "@comment_inline" && name != "@comment_foot" {
		return ""
	}
	for end < len(rest) && is_space(rest[end]) {
		end += 1
	}
	return "" if end < len(rest) && rest[end] == '"' else name
}

@(private = "file")
lex_token :: proc(p: ^Parser) -> (Sym, Sem) {
	s := p.src
	start := p.pos
	c := s[start]
	next: u8 = s[start + 1] if start + 1 < len(s) else 0
	fact := fact_accessor(s[start + 1:]) if c == '.' && next == '@' else ""
	switch {
	case is_digit(c) || (c == '.' && is_digit(next)):
		return .Literal, {value = lex_number(p)}
	case fact != "":
		p.pos += 1 + len(fact)
		return .Field, {text = fact}
	case c == '.' && ident_start(next):
		p.pos += 1
		end := p.pos
		for end < len(s) && ident_byte(s[end]) {
			end += 1
		}
		p.pos = end
		return .Field, {text = s[start + 1:end]}
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
	case c == '@' && (ident_byte(next)):
		end := start + 1
		for end < len(s) && ident_byte(s[end]) {
			end += 1
		}
		p.pos = end
		return .Format, {text = s[start + 1:end]}
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
		return close(p, c), {}
	}
	for op in OPERATORS {
		if strings.has_prefix(s[start:], op.text) {
			p.pos += len(op.text)
			return op.sym, {}
		}
	}
	p.pos += 1
	if c == '.' {
		return .Dot, {}
	}
	if c == '$' {
		return .Dollar, {}
	}
	return .Invalid, {}
}

// A closing bracket ends the innermost (), [], {} or interpolation it matches, or is invalid.
@(private = "file")
close :: proc(p: ^Parser, c: u8) -> Sym {
	if len(p.modes) == 0 {
		return .Invalid
	}
	top := p.modes[len(p.modes) - 1]
	sym: Sym
	switch {
	case top == .Paren && c == ')':
		sym = .RParen
	case top == .Bracket && c == ']':
		sym = .RBracket
	case top == .Brace && c == '}':
		sym = .RBrace
	case top == .Interp && c == ')':
		sym = .QQ_Interp_End
	case:
		return .Invalid
	}
	pop(&p.modes)
	return sym
}

// `([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?`, as a number that keeps its original text.
@(private = "file")
lex_number :: proc(p: ^Parser) -> Value {
	s := p.src
	start := p.pos
	i := start
	for i < len(s) && is_digit(s[i]) {
		i += 1
	}
	if i < len(s) && s[i] == '.' {
		i += 1
		for i < len(s) && is_digit(s[i]) {
			i += 1
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			j += 1
		}
		if j < len(s) && is_digit(s[j]) {
			for j < len(s) && is_digit(s[j]) {
				j += 1
			}
			i = j
		}
	}
	p.pos = i
	v, _ := read_number(s[start:i])
	return v
}

// Inside a string: an interpolation's start, the closing quote, a run of escapes, or plain text.
@(private = "file")
lex_in_string :: proc(p: ^Parser) -> (sym: Sym, sem: Sem, loc: Loc) {
	s := p.src
	start := p.pos
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
			for j < len(s) && j < end + 6 && is_alnum(s[j]) {
				j += 1
			}
			end = j
		}
		if end == start {
			p.pos += 1
			sym = .Invalid
		} else {
			p.pos = end
			sym = .QQ_Text
			sem.value = unescape(p, s[start:end], {start, end})
		}
	case:
		end := start
		for end < len(s) && s[end] != '\\' && s[end] != '"' {
			end += 1
		}
		p.pos = end
		sym = .QQ_Text
		sem.value = s[start:end]
	}
	p.last = {start, p.pos}
	return sym, sem, p.last
}

// A run of escapes decoded as jq's JSON parser decodes `"run"`, or nil after reporting why it cannot be.
@(private = "file")
unescape :: proc(p: ^Parser, run: string, at: Loc) -> Value {
	b := strings.builder_make()
	msg := decode_string(&b, run)
	if msg == "" {
		return strings.to_string(b)
	}
	// The JSON parser counts lines and columns over `"run"`, to its closing quote.
	line, column := 1, 1
	for ch in transmute([]byte)run {
		column += 1
		if ch == '\n' {
			line, column = line + 1, 0
		}
	}
	report(p, at, fmt.aprintf("%s at line %d, column %d (while parsing '\"%s\"')", msg, line, column + 1, run))
	return nil
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_alnum :: proc(c: u8) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private = "file")
ident_start :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

ident_byte :: proc(c: u8) -> bool {
	return ident_start(c) || is_digit(c)
}

// `([a-zA-Z_][a-zA-Z_0-9]*::)*[a-zA-Z_][a-zA-Z_0-9]*` from `p.pos`, which starts one.
@(private = "file")
take_ident :: proc(p: ^Parser) -> string {
	s := p.src
	start := p.pos
	for {
		for p.pos < len(s) && ident_byte(s[p.pos]) {
			p.pos += 1
		}
		if p.pos + 2 < len(s) && s[p.pos] == ':' && s[p.pos + 1] == ':' && ident_start(s[p.pos + 2]) {
			p.pos += 2
			continue
		}
		return s[start:p.pos]
	}
}
