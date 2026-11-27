// SQL DDL lexer: case-insensitive keywords, `--` and nested `/* ... */` comments,
// `'...'` strings, `"ident"` / `` `ident` `` / `[ident]` quoted identifiers, numbers, and operators.
// Zero heap allocations during lexing.
package ddl

import "base:runtime"

@(private)
Token_Kind :: enum u8 {
	Eof, Error, Ident, Quoted_Ident, String, Number,
	LParen, RParen, Comma, Semi, Dot, Empty_Brackets,
	Eq, Neq, Lt, Lte, Gt, Gte,
	Plus, Minus, Star, Slash, Percent, Concat, Cast,
}

@(private)
Token :: struct {
	kind:    Token_Kind,
	lo:      u32,
	hi:      u32,
	line:    u32,
	col:     u32,
	quote:   u8,
	escaped: bool,
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
	l^ = {src = src, line = 1, col = 1}
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
lexer_match :: proc "contextless" (l: ^Lexer, c: u8) -> bool {
	if l.pos < len(l.src) && l.src[l.pos] == c {
		lexer_advance(l)
		return true
	}
	return false
}

@(private = "file")
lexer_match2 :: proc "contextless" (l: ^Lexer, a, b: u8) -> bool {
	if l.pos + 1 < len(l.src) && l.src[l.pos] == a && l.src[l.pos + 1] == b {
		lexer_advance(l)
		lexer_advance(l)
		return true
	}
	return false
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
		if l.pos == 0 && len(l.src) >= 3 && l.src[0] == 0xEF && l.src[1] == 0xBB && l.src[2] == 0xBF {
			l.pos += 3
			continue
		}
		if lexer_match2(l, '-', '-') {
			for l.pos < len(l.src) && l.src[l.pos] != '\n' {
				lexer_advance(l)
			}
			continue
		}
		if l.pos + 1 < len(l.src) && c == '/' && l.src[l.pos + 1] == '*' {
			off, line, col := u64(l.pos), l.line, l.col
			lexer_advance(l)
			lexer_advance(l)
			depth := 1
			for l.pos < len(l.src) && depth > 0 {
				if lexer_match2(l, '/', '*') {
					depth += 1
				} else if lexer_match2(l, '*', '/') {
					depth -= 1
				} else {
					lexer_advance(l)
				}
			}
			if depth > 0 {
				_ = lexer_fail(l, off, line, col, "unterminated block comment")
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

	pos, line, col := l.pos, l.line, l.col
	c := l.src[pos]
	has_next := pos + 1 < len(l.src)

	if has_next && l.src[pos + 1] == '\'' && (c == 'E' || c == 'e' || c == 'N' || c == 'n') {
		lexer_advance(l)
		return scan_quoted(l, '\'', pos, line, col, .String, c == 'E' || c == 'e')
	}
	if c == '\'' {
		return scan_quoted(l, '\'', pos, line, col, .String, false)
	}
	if c == '"' || c == '`' {
		return scan_quoted(l, c, pos, line, col, .Quoted_Ident, false)
	}
	if c == '[' {
		if lexer_match2(l, '[', ']') {
			return Token{kind = .Empty_Brackets, lo = u32(pos), hi = u32(l.pos), line = line, col = col}
		}
		return scan_quoted(l, ']', pos, line, col, .Quoted_Ident, false)
	}
	if is_digit(c) || (c == '.' && has_next && is_digit(l.src[pos + 1])) {
		return scan_number(l, pos, line, col)
	}
	if is_ident_start(c) {
		lexer_advance(l)
		for l.pos < len(l.src) && (is_ident_start(l.src[l.pos]) || is_digit(l.src[l.pos])) {
			lexer_advance(l)
		}
		return Token{kind = .Ident, lo = u32(pos), hi = u32(l.pos), line = line, col = col}
	}

	lexer_advance(l)
	kind: Token_Kind
	switch c {
	case '(': kind = .LParen
	case ')': kind = .RParen
	case ',': kind = .Comma
	case ';': kind = .Semi
	case '.': kind = .Dot
	case '=': kind = .Eq
	case '+': kind = .Plus
	case '-': kind = .Minus
	case '*': kind = .Star
	case '/': kind = .Slash
	case '%': kind = .Percent
	case '<':
		kind = .Lte if lexer_match(l, '=') else (.Neq if lexer_match(l, '>') else .Lt)
	case '>':
		kind = .Gte if lexer_match(l, '=') else .Gt
	case '!':
		if !lexer_match(l, '=') {
			return lexer_fail(l, u64(pos), line, col, "unexpected '!' (expected '!=')")
		}
		kind = .Neq
	case '|':
		if !lexer_match(l, '|') {
			return lexer_fail(l, u64(pos), line, col, "unexpected '|' (expected '||')")
		}
		kind = .Concat
	case ':':
		if !lexer_match(l, ':') {
			return lexer_fail(l, u64(pos), line, col, "unexpected ':' (expected '::')")
		}
		kind = .Cast
	case:
		return lexer_fail(l, u64(pos), line, col, "unexpected character in SQL DDL")
	}
	return Token{kind = kind, lo = u32(pos), hi = u32(l.pos), line = line, col = col}
}

@(private = "file")
scan_quoted :: proc "contextless" (l: ^Lexer, close: u8, pos: int, line, col: u32, kind: Token_Kind, pg_escape: bool) -> Token {
	open := lexer_advance(l)
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
			if lexer_match(l, close) {
				continue
			}
			return Token{kind = kind, lo = content_lo, hi = u32(l.pos - 1), line = line, col = col, quote = open, escaped = pg_escape}
		}
	}
	return lexer_fail(l, u64(pos), line, col, "unterminated string literal" if kind == .String else "unterminated quoted identifier")
}

@(private = "file")
scan_number :: proc "contextless" (l: ^Lexer, pos: int, line, col: u32) -> Token {
	for l.pos < len(l.src) && is_digit(l.src[l.pos]) {
		lexer_advance(l)
	}
	if lexer_match(l, '.') {
		for l.pos < len(l.src) && is_digit(l.src[l.pos]) {
			lexer_advance(l)
		}
	}
	if l.pos < len(l.src) && (l.src[l.pos] == 'e' || l.src[l.pos] == 'E') {
		lexer_advance(l)
		if l.pos < len(l.src) && (l.src[l.pos] == '+' || l.src[l.pos] == '-') {
			lexer_advance(l)
		}
		exp_start := l.pos
		for l.pos < len(l.src) && is_digit(l.src[l.pos]) {
			lexer_advance(l)
		}
		if l.pos == exp_start {
			return lexer_fail(l, u64(pos), line, col, "malformed numeric exponent")
		}
	}
	return Token{kind = .Number, lo = u32(pos), hi = u32(l.pos), line = line, col = col}
}

@(private)
token_raw :: proc "contextless" (src: []u8, tok: Token) -> string {
	return string(src[tok.lo:tok.hi])
}

@(private)
ascii_eq_fold :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ca, cb := a[i], b[i]
		if ca >= 'a' && ca <= 'z' { ca -= 32 }
		if cb >= 'a' && cb <= 'z' { cb -= 32 }
		if ca != cb {
			return false
		}
	}
	return true
}

@(private)
token_is_kw :: proc "contextless" (src: []u8, tok: Token, kw: string) -> bool {
	return tok.kind == .Ident && ascii_eq_fold(token_raw(src, tok), kw)
}

@(private)
decode_quoted :: proc(src: []u8, tok: Token, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	raw := src[tok.lo:tok.hi]
	close := u8(']') if tok.quote == '[' else tok.quote
	buf, err := make([]u8, len(raw), allocator)
	if err != nil {
		return "", err
	}
	n := 0
	for i := 0; i < len(raw); {
		if tok.escaped && raw[i] == '\\' && i + 1 < len(raw) {
			switch raw[i + 1] {
			case 'n':  buf[n] = '\n'
			case 'r':  buf[n] = '\r'
			case 't':  buf[n] = '\t'
			case 'b':  buf[n] = '\b'
			case 'f':  buf[n] = '\f'
			case:      buf[n] = raw[i + 1]
			}
			i += 2
		} else if raw[i] == close && i + 1 < len(raw) && raw[i + 1] == close {
			buf[n] = close
			i += 2
		} else {
			buf[n] = raw[i]
			i += 1
		}
		n += 1
	}
	return string(buf[:n]), nil
}
