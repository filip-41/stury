#+private file
package core

import "base:intrinsics"
import "base:runtime"
import "core:unicode/utf8"
import spell "./spell"

// The readers of a path's text: jq path text and JSON Pointer.

Parser :: struct {
	text:     string,
	at:       int,
	n:        int,
	steps:    [MAX_STEPS]Step,
	optional: bit_set[0 ..< MAX_STEPS; u64],
	// The `Name` steps that still hold their source spelling, which `path_of` decodes.
	escaped:  bit_set[0 ..< MAX_STEPS; u64],
	limit:    Maybe(int),
	fault:    Path_Error,
}

bad_path :: proc(p: ^Parser, at: int, reason: Path_Reason) -> bool {
	p.fault = {kind = .Bad_Path, reason = reason, at = u64(at), text = p.text}
	return false
}

@(private = "package")
parse :: proc(text: string, allocator: runtime.Allocator, $POINTER: bool) -> (Path, Path_Error) {
	p := Parser{text = text}
	if !(parse_tokens(&p) if POINTER else parse_text(&p)) {
		return {}, p.fault
	}
	return path_of(&p, allocator, POINTER)
}

parse_text :: proc(p: ^Parser) -> bool {
	skip_spaces(p)
	closes := false
	if eat(p, "first(") {
		p.limit = 1
		closes = true
	} else if eat(p, "limit(") {
		closes = true
		skip_spaces(p)
		lo := p.at
		n, ok := parse_int(p)
		if !ok || n < 0 {
			return bad_path(p, lo, .Bad_Limit)
		}
		p.limit = n
		skip_spaces(p)
		if !eat(p, ";") {
			return bad_path(p, p.at, .No_Semicolon)
		}
	}
	skip_spaces(p)
	parse_chain(p) or_return
	skip_spaces(p)
	if closes {
		if !eat(p, ")") {
			return bad_path(p, p.at, .Unclosed_Paren)
		}
		skip_spaces(p)
	}
	return p.at == len(p.text) || bad_path(p, p.at, .Trailing)
}

parse_tokens :: proc(p: ^Parser) -> bool {
	t := p.text
	if len(t) > 0 && t[0] != '/' {
		return bad_path(p, 0, .No_Slash)
	}
	for p.at < len(t) {
		lo := p.at + 1
		hi := lo
		tilde := false
		for hi < len(t) && t[hi] != '/' {
			if t[hi] >= 0x80 {
				end, ok := utf8_end(t, hi)
				if !ok {
					return bad_path(p, hi, .Invalid_Utf8)
				}
				hi = end
				continue
			}
			if t[hi] == '~' {
				if hi + 1 == len(t) || t[hi + 1] != '0' && t[hi + 1] != '1' {
					return bad_path(p, hi, .Bad_Tilde)
				}
				tilde = true
			}
			hi += 1
		}
		p.at = hi
		token := t[lo:hi]
		if index, ok := pointer_index(token); ok {
			push_step(p, Index_Or_Name{token, index}) or_return
			continue
		}
		push_step(p, Name(token)) or_return
		if tilde {
			p.escaped += {p.n - 1}
		}
	}
	return true
}

// Copies the parser's steps into one block with the names it decodes, as a pointer when `$POINTER`.
path_of :: proc(p: ^Parser, allocator: runtime.Allocator, $POINTER: bool) -> (Path, Path_Error) {
	if p.n == 0 {
		return {limit = p.limit}, {}
	}
	head := p.n * size_of(Step)
	size := head
	for i in p.escaped {
		size += len(p.steps[i].(Name))
	}
	block, failed := runtime.mem_alloc_bytes(size, align_of(Step), allocator)
	if failed != nil {
		return {}, {kind = .No_Memory}
	}
	steps := ([^]Step)(raw_data(block))[:p.n]
	copy(steps, p.steps[:p.n])
	w := head
	for i in p.escaped {
		k := decode_pointer(string(p.steps[i].(Name)), block[w:]) if POINTER else decode_quoted(string(p.steps[i].(Name)), block[w:])
		steps[i] = Name(string(block[w:w + k]))
		w += k
	}
	return {steps = steps, optional = p.optional, limit = p.limit, block = block, allocator = allocator}, {}
}

skip_spaces :: proc(p: ^Parser) {
	for p.at < len(p.text) && (p.text[p.at] == ' ' || p.text[p.at] == '\t' || p.text[p.at] == '\n' || p.text[p.at] == '\r') {
		p.at += 1
	}
}

eat :: proc(p: ^Parser, s: string) -> bool {
	if len(p.text) - p.at >= len(s) && p.text[p.at:p.at + len(s)] == s {
		p.at += len(s)
		return true
	}
	return false
}

push_step :: proc(p: ^Parser, s: Step) -> bool {
	if p.n == MAX_STEPS {
		p.fault = {kind = .Over_Capacity}
		return false
	}
	p.steps[p.n] = s
	p.n += 1
	return true
}

// Reads a path from its `.` up to the first byte that continues no step, which the caller judges.
parse_chain :: proc(p: ^Parser) -> bool {
	t := p.text
	if p.at == len(t) || t[p.at] != '.' {
		return bad_path(p, p.at, .Pointer_Text if p.at < len(t) && t[p.at] == '/' else .No_Dot)
	}
	if eat(p, "..") {
		push_step(p, Descend{}) or_return
	} else if p.at + 1 == len(t) || !(t[p.at + 1] == '"' || t[p.at + 1] == '[' || is_name_start(t[p.at + 1])) {
		p.at += 1
	}
	for p.at < len(t) {
		switch t[p.at] {
		case '?':
			if p.n > 0 {
				p.optional += {p.n - 1}
			}
			p.at += 1
		case '[':
			parse_bracket(p) or_return
		case '.':
			parse_field(p) or_return
		case:
			return true
		}
	}
	return true
}

@(private = "package")
is_name_start :: proc(b: u8) -> bool {
	return b == '_' || b | 0x20 >= 'a' && b | 0x20 <= 'z'
}

// Reads the step after a `.`: a bare name or a quoted one. A `.` before a `[` is passed over for the next step to read.
parse_field :: proc(p: ^Parser) -> bool {
	t := p.text
	if p.at + 1 == len(t) {
		return bad_path(p, p.at, .Bad_Name)
	}
	b := t[p.at + 1]
	switch {
	case b == '[':
		p.at += 1
		return true
	case b == '"':
		p.at += 1
		return parse_quoted(p)
	case is_name_start(b):
		lo := p.at + 1
		p.at = lo
		for p.at < len(t) && (is_name_start(t[p.at]) || t[p.at] >= '0' && t[p.at] <= '9') {
			p.at += 1
		}
		return push_step(p, Name(t[lo:p.at]))
	}
	return bad_path(p, p.at, .Bad_Name)
}

// Reads the quoted name at `p.at` as a JSON string. A name with an escape is judged here and decoded in `path_of`.
parse_quoted :: proc(p: ^Parser) -> bool {
	t := p.text
	lo := p.at + 1
	i := lo
	escape := false
	for i < len(t) && t[i] != '"' {
		if t[i] == '\\' {
			_, n := spell.string_escape(raw_data(t)[i:], len(t) - i)
			if n == 0 {
				return bad_path(p, i, .Bad_Escape)
			}
			escape = true
			i += n
		} else if t[i] >= 0x80 {
			end, ok := utf8_end(t, i)
			if !ok {
				return bad_path(p, i, .Invalid_Utf8)
			}
			i = end
		} else {
			i += 1
		}
	}
	if i >= len(t) {
		return bad_path(p, p.at, .Unclosed_Quote)
	}
	raw := t[lo:i]
	push_step(p, Name(raw)) or_return
	if escape {
		p.escaped += {p.n - 1}
	}
	p.at = i + 1
	return true
}

// Returns the byte past the character that starts at `t[i]`, a byte past ASCII, and false when it is ill-formed UTF-8 or
// the text cuts it short.
utf8_end :: proc(t: string, i: int) -> (end: int, ok: bool) {
	base := raw_data(t)
	q, kind := spell.utf8_char(base[i:], base[len(t):])
	return int(intrinsics.ptr_sub(q, base)), kind == .None
}

// Reads `[...]`: `[]`, a quoted name, an index or a slice.
parse_bracket :: proc(p: ^Parser) -> bool {
	t := p.text
	open := p.at
	p.at += 1
	if p.at == len(t) {
		return bad_path(p, open, .Unclosed_Bracket)
	}
	if eat(p, "]") {
		return push_step(p, All{})
	}
	if p.at < len(t) && t[p.at] == '"' {
		parse_quoted(p) or_return
		return eat(p, "]") || bad_path(p, p.at, .Unclosed_Bracket)
	}
	lo, has_lo := parse_int(p)
	if !eat(p, ":") {
		if !has_lo {
			return bad_path(p, open, .Bad_Bracket)
		}
		push_step(p, Index(lo)) or_return
		return eat(p, "]") || bad_path(p, p.at, .Unclosed_Bracket)
	}
	hi, has_hi := parse_int(p)
	if !has_lo && !has_hi {
		return bad_path(p, open, .Bad_Bracket)
	}
	s := Slice{lo = lo if has_lo else 0, hi = hi if has_hi else nil}
	push_step(p, s) or_return
	return eat(p, "]") || bad_path(p, p.at, .Unclosed_Bracket)
}

// Reads the digits at `t[i:]` as an `int`, returning the byte past them, and false when there is none or it overflows.
digits_int :: proc(t: string, i: int) -> (value: int, end: int, ok: bool) {
	end = i
	for end < len(t) && t[end] >= '0' && t[end] <= '9' {
		d := int(t[end] - '0')
		if value > (max(int) - d) / 10 {
			return 0, i, false
		}
		value = value * 10 + d
		end += 1
	}
	return value, end, end > i
}

// Reads an optional `-` and its digits, and leaves `p.at` where it was when they make no `int`.
parse_int :: proc(p: ^Parser) -> (value: int, ok: bool) {
	i := p.at
	minus := i < len(p.text) && p.text[i] == '-'
	n, end, good := digits_int(p.text, i + 1 if minus else i)
	if !good {
		return 0, false
	}
	p.at = end
	return -n if minus else n, true
}

// Decodes a judged quoted name into `out`, which holds `len(raw)` bytes, as no escape grows. Returns the bytes written.
decode_quoted :: proc(raw: string, out: []u8) -> int {
	w := 0
	for i := 0; i < len(raw); {
		if raw[i] != '\\' {
			out[w] = raw[i]
			w += 1
			i += 1
			continue
		}
		r, n := spell.string_escape(raw_data(raw)[i:], len(raw) - i)
		bytes, size := utf8.encode_rune(r)
		copy(out[w:], bytes[:size])
		w += size
		i += n
	}
	return w
}

// Decodes a judged pointer token into `out`, which holds `len(raw)` bytes. Returns the bytes written.
decode_pointer :: proc(raw: string, out: []u8) -> int {
	w := 0
	for i := 0; i < len(raw); i += 1 {
		b := raw[i]
		if b == '~' {
			i += 1
			b = '/' if raw[i] == '1' else '~'
		}
		out[w] = b
		w += 1
	}
	return w
}

// Returns the array index `token` spells: `0`, or digits with no leading zero. An index past what an `int` holds is
// `max(int)`, past the end of every array.
pointer_index :: proc(token: string) -> (index: int, ok: bool) {
	if len(token) == 0 || len(token) > 1 && token[0] == '0' {
		return 0, false
	}
	for b in transmute([]u8)token {
		if b < '0' || b > '9' {
			return 0, false
		}
	}
	n, _, fits := digits_int(token, 0)
	return n if fits else max(int), true
}
