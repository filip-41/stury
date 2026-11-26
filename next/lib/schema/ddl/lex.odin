// SQL DDL lexer: case-insensitive keywords, `--` line comments, nested `/* ... */` block comments,
// `'...'` strings with `''` escapes, `"ident"` / `` `ident` `` / `[ident]` quoted identifiers,
// integer/decimal/exponent numbers, SQL operators and punctuation, with exact 1-based line:col tracking.
// Zero heap allocations during lexing.
package ddl

import "base:runtime"

@(private)
Token_Kind :: enum u8 {
	Eof,
	Error,
	Ident,
	Quoted_Ident,
	String,
	Number,
	LParen,
	RParen,
	Comma,
	Semi,
	Dot,
	Empty_Brackets,
	Eq,
	Neq,
	Lt,
	Lte,
	Gt,
	Gte,
	Plus,
	Minus,
	Star,
	Slash,
	Percent,
	Concat,
	Cast,
}

@(private)
Token :: struct {
	kind:    Token_Kind,
	lo:      u32,
	hi:      u32,
	line:    u32,
	col:     u32,
	quote:   u8,   // 0, '\'', '"', '`', or '['
	escaped: bool, // true for PostgreSQL `E'...'` backslash-escaped string literals
}

@(private)
Lexer :: struct {
	src:        []u8,
	pos:        int,
	line:       u32,
	col:        u32,
	err_msg:    string,
	err_offset: u64,
	err_line:   u32,
	err_col:    u32,
}

@(private)
lexer_init :: proc "contextless" (l: ^Lexer, src: []u8) {
	l^ = {
		src  = src,
		pos  = 0,
		line = 1,
		col  = 1,
	}
}

@(private = "file")
lexer_advance :: proc "contextless" (l: ^Lexer) -> u8 {
	c := l.src[l.pos]
	l.pos += 1
	if c == '\n' {
		l.line += 1
		l.col = 1
	} else {
		l.col += 1
	}
	return c
}

@(private = "file")
lexer_fail :: proc "contextless" (l: ^Lexer, offset: u64, line, col: u32, msg: string) -> Token {
	l.err_msg = msg
	l.err_offset = offset
	l.err_line = line
	l.err_col = col
	return Token{kind = .Error, lo = u32(offset), hi = u32(l.pos), line = line, col = col}
}

@(private = "file")
is_ident_start :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || c >= 0x80
}

@(private = "file")
is_ident_cont :: proc "contextless" (c: u8) -> bool {
	return is_ident_start(c) || (c >= '0' && c <= '9')
}

@(private = "file")
is_digit :: proc "contextless" (c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
skip_ws_and_comments :: proc "contextless" (l: ^Lexer) -> bool {
	for l.pos < len(l.src) {
		c := l.src[l.pos]
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v' {
			lexer_advance(l)
			continue
		}
		// UTF-8 BOM at byte 0
		if l.pos == 0 && len(l.src) >= 3 && l.src[0] == 0xEF && l.src[1] == 0xBB && l.src[2] == 0xBF {
			l.pos += 3
			continue
		}
		// Line comment: `-- ...`
		if c == '-' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '-' {
			lexer_advance(l)
			lexer_advance(l)
			for l.pos < len(l.src) && l.src[l.pos] != '\n' {
				lexer_advance(l)
			}
			continue
		}
		// Block comment: `/* ... */` (supports nested block comments)
		if c == '/' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '*' {
			start_off := u64(l.pos)
			start_line, start_col := l.line, l.col
			lexer_advance(l)
			lexer_advance(l)
			depth := 1
			for l.pos < len(l.src) && depth > 0 {
				if l.src[l.pos] == '/' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '*' {
					lexer_advance(l)
					lexer_advance(l)
					depth += 1
				} else if l.src[l.pos] == '*' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '/' {
					lexer_advance(l)
					lexer_advance(l)
					depth -= 1
				} else {
					lexer_advance(l)
				}
			}
			if depth > 0 {
				_ = lexer_fail(l, start_off, start_line, start_col, "unterminated block comment")
				return false
			}
			continue
		}
		break
	}
	return true
}

@(private)
lexer_next :: proc "contextless" (l: ^Lexer) -> Token {
	if !skip_ws_and_comments(l) {
		return Token{kind = .Error, lo = u32(l.err_offset), hi = u32(l.pos), line = l.err_line, col = l.err_col}
	}
	if l.pos >= len(l.src) {
		return Token{kind = .Eof, lo = u32(l.pos), hi = u32(l.pos), line = l.line, col = l.col}
	}

	start_pos := l.pos
	start_line, start_col := l.line, l.col
	c := l.src[l.pos]

	// PostgreSQL E'...' (backslash-escaped) or N'...' prefixed string literals
	if (c == 'E' || c == 'e') && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '\'' {
		lexer_advance(l)
		return scan_quoted(l, '\'', start_pos, start_line, start_col, .String, true)
	}
	if (c == 'N' || c == 'n') && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '\'' {
		lexer_advance(l)
		return scan_quoted(l, '\'', start_pos, start_line, start_col, .String, false)
	}

	// Single-quoted string literal `'...'`
	if c == '\'' {
		return scan_quoted(l, '\'', start_pos, start_line, start_col, .String, false)
	}

	// Double-quoted `"ident"` or backtick-quoted `` `ident` `` identifier
	if c == '"' || c == '`' {
		return scan_quoted(l, c, start_pos, start_line, start_col, .Quoted_Ident, false)
	}

	// Empty `[]` array type suffix vs bracket-quoted `[ident]`
	if c == '[' {
		if l.pos + 1 < len(l.src) && l.src[l.pos + 1] == ']' {
			lexer_advance(l)
			lexer_advance(l)
			return Token{kind = .Empty_Brackets, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
		}
		return scan_quoted(l, ']', start_pos, start_line, start_col, .Quoted_Ident, false)
	}

	// Numbers: `123`, `12.34`, `.5`, `1e10`, `1.5e-3`
	if is_digit(c) || (c == '.' && l.pos + 1 < len(l.src) && is_digit(l.src[l.pos + 1])) {
		return scan_number(l, start_pos, start_line, start_col)
	}

	// Unquoted identifier or keyword
	if is_ident_start(c) {
		lexer_advance(l)
		for l.pos < len(l.src) && is_ident_cont(l.src[l.pos]) {
			lexer_advance(l)
		}
		return Token{kind = .Ident, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	}

	// Punctuation and operators
	lexer_advance(l)
	switch c {
	case '(':
		return Token{kind = .LParen, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case ')':
		return Token{kind = .RParen, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case ',':
		return Token{kind = .Comma, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case ';':
		return Token{kind = .Semi, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case '.':
		return Token{kind = .Dot, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case '=':
		return Token{kind = .Eq, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case '+':
		return Token{kind = .Plus, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case '-':
		return Token{kind = .Minus, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case '*':
		return Token{kind = .Star, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case '/':
		return Token{kind = .Slash, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case '%':
		return Token{kind = .Percent, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case '<':
		if l.pos < len(l.src) {
			if l.src[l.pos] == '=' {
				lexer_advance(l)
				return Token{kind = .Lte, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
			}
			if l.src[l.pos] == '>' {
				lexer_advance(l)
				return Token{kind = .Neq, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
			}
		}
		return Token{kind = .Lt, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case '>':
		if l.pos < len(l.src) && l.src[l.pos] == '=' {
			lexer_advance(l)
			return Token{kind = .Gte, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
		}
		return Token{kind = .Gt, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
	case '!':
		if l.pos < len(l.src) && l.src[l.pos] == '=' {
			lexer_advance(l)
			return Token{kind = .Neq, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
		}
		return lexer_fail(l, u64(start_pos), start_line, start_col, "unexpected '!' (expected '!=')")
	case '|':
		if l.pos < len(l.src) && l.src[l.pos] == '|' {
			lexer_advance(l)
			return Token{kind = .Concat, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
		}
		return lexer_fail(l, u64(start_pos), start_line, start_col, "unexpected '|' (expected '||')")
	case ':':
		if l.pos < len(l.src) && l.src[l.pos] == ':' {
			lexer_advance(l)
			return Token{kind = .Cast, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
		}
		return lexer_fail(l, u64(start_pos), start_line, start_col, "unexpected ':' (expected '::')")
	}
	return lexer_fail(l, u64(start_pos), start_line, start_col, "unexpected character in SQL DDL")
}

@(private = "file")
scan_quoted :: proc "contextless" (l: ^Lexer, close: u8, start_pos: int, start_line, start_col: u32, kind: Token_Kind, pg_escape: bool) -> Token {
	open := lexer_advance(l) // consume opening quote / '['
	content_lo := u32(l.pos)
	for l.pos < len(l.src) {
		ch := lexer_advance(l)
		if pg_escape && ch == '\\' {
			if l.pos < len(l.src) {
				lexer_advance(l)
				continue
			}
			break
		}
		if ch == close {
			// Doubled closing delimiter escapes itself (`''`, `""`, `` `` ``, `]]`)
			if l.pos < len(l.src) && l.src[l.pos] == close {
				lexer_advance(l)
				continue
			}
			return Token{
				kind    = kind,
				lo      = content_lo,
				hi      = u32(l.pos - 1),
				line    = start_line,
				col     = start_col,
				quote   = open,
				escaped = pg_escape,
			}
		}
	}
	msg := "unterminated string literal" if kind == .String else "unterminated quoted identifier"
	return lexer_fail(l, u64(start_pos), start_line, start_col, msg)
}

@(private = "file")
scan_number :: proc "contextless" (l: ^Lexer, start_pos: int, start_line, start_col: u32) -> Token {
	for l.pos < len(l.src) && is_digit(l.src[l.pos]) {
		lexer_advance(l)
	}
	if l.pos < len(l.src) && l.src[l.pos] == '.' {
		lexer_advance(l)
		for l.pos < len(l.src) && is_digit(l.src[l.pos]) {
			lexer_advance(l)
		}
	}
	if l.pos < len(l.src) && (l.src[l.pos] == 'e' || l.src[l.pos] == 'E') {
		lexer_advance(l)
		if l.pos < len(l.src) && (l.src[l.pos] == '+' || l.src[l.pos] == '-') {
			lexer_advance(l)
		}
		exp_digits := 0
		for l.pos < len(l.src) && is_digit(l.src[l.pos]) {
			lexer_advance(l)
			exp_digits += 1
		}
		if exp_digits == 0 {
			return lexer_fail(l, u64(start_pos), start_line, start_col, "malformed numeric exponent")
		}
	}
	return Token{kind = .Number, lo = u32(start_pos), hi = u32(l.pos), line = start_line, col = start_col}
}

@(private)
token_raw :: proc "contextless" (src: []u8, tok: Token) -> string {
	return string(src[tok.lo:tok.hi])
}

// ASCII case-insensitive equality against an uppercase keyword literal `kw`.
@(private)
ascii_eq_fold :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'a' && ca <= 'z' {
			ca -= 32
		}
		if cb >= 'a' && cb <= 'z' {
			cb -= 32
		}
		if ca != cb {
			return false
		}
	}
	return true
}

@(private)
token_is_kw :: proc "contextless" (src: []u8, tok: Token, kw: string) -> bool {
	if tok.kind != .Ident {
		return false
	}
	return ascii_eq_fold(token_raw(src, tok), kw)
}

// Decodes doubled-quote escapes (and PostgreSQL `E'...'` backslash escapes) into `allocator`.
@(private)
decode_quoted :: proc(src: []u8, tok: Token, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	raw := src[tok.lo:tok.hi]
	close := u8(']') if tok.quote == '[' else tok.quote
	// Count decoded bytes first so we allocate exact length once.
	out_len := 0
	i := 0
	for i < len(raw) {
		if tok.escaped && raw[i] == '\\' && i + 1 < len(raw) {
			i += 2
		} else if raw[i] == close && i + 1 < len(raw) && raw[i + 1] == close {
			i += 2
		} else {
			i += 1
		}
		out_len += 1
	}
	buf, err := make([]u8, out_len, allocator)
	if err != nil {
		return "", err
	}
	n := 0
	i = 0
	for i < len(raw) {
		if tok.escaped && raw[i] == '\\' && i + 1 < len(raw) {
			nxt := raw[i + 1]
			switch nxt {
			case 'n':
				buf[n] = '\n'
			case 'r':
				buf[n] = '\r'
			case 't':
				buf[n] = '\t'
			case 'b':
				buf[n] = '\b'
			case 'f':
				buf[n] = '\f'
			case '\'':
				buf[n] = '\''
			case '\\':
				buf[n] = '\\'
			case:
				buf[n] = nxt
			}
			n += 1
			i += 2
		} else if raw[i] == close && i + 1 < len(raw) && raw[i + 1] == close {
			buf[n] = raw[i]
			n += 1
			i += 2
		} else {
			buf[n] = raw[i]
			n += 1
			i += 1
		}
	}
	return string(buf), nil
}
