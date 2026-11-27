package jsonpath

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/regex"

// Strict RFC 9485 I-Regexp validator and translator to `stury:lib/base/regex` (Oniguruma syntax).

@(private)
translate_iregexp :: proc(pat: string, anchored: bool, out: ^strings.Builder, max_depth := 500) -> bool {
	if anchored {
		strings.write_string(out, `\A(?:`)
	}
	i, n, paren_depth := 0, len(pat), 0
	can_quantify := false
	for i < n {
		c := pat[i]
		switch c {
		case '|':
			strings.write_byte(out, '|')
			i += 1
			can_quantify = false
		case '(':
			paren_depth += 1
			if paren_depth > max_depth {
				return false
			}
			strings.write_string(out, "(?:")
			i += 1
			can_quantify = false
		case ')':
			if paren_depth == 0 {
				return false
			}
			paren_depth -= 1
			strings.write_byte(out, ')')
			i += 1
			can_quantify = true
		case '*', '+', '?':
			if !can_quantify {
				return false
			}
			strings.write_byte(out, c)
			i += 1
			can_quantify = false
		case '{':
			if !can_quantify || !parse_iregexp_quantifier(pat, &i, out) {
				return false
			}
			can_quantify = false
		case '}', ']':
			return false
		case '.':
			strings.write_string(out, `[^\r\n]`)
			i += 1
			can_quantify = true
		case '[':
			if !parse_iregexp_class(pat, &i, out) {
				return false
			}
			can_quantify = true
		case '\\':
			if !parse_iregexp_escape(pat, &i, out) {
				return false
			}
			can_quantify = true
		case '^', '$':
			strings.write_byte(out, '\\')
			strings.write_byte(out, c)
			i += 1
			can_quantify = true
		case:
			if c < 0x80 {
				strings.write_byte(out, c)
				i += 1
			} else {
				r, w := decode_strict_utf8(pat[i:])
				if w == 0 || !is_scalar_value(r) {
					return false
				}
				strings.write_string(out, pat[i:i + w])
				i += w
			}
			can_quantify = true
		}
	}
	if paren_depth != 0 {
		return false
	}
	if anchored {
		strings.write_string(out, `)\z`)
	}
	return true
}

@(private = "file")
scan_quant_uint :: proc "contextless" (pat: string, i: ^int) -> (val: u64, ok: bool) {
	start := i^
	overflow := false
	for i^ < len(pat) && pat[i^] >= '0' && pat[i^] <= '9' {
		d := u64(pat[i^] - '0')
		if val > (max(u64) - d) / 10 {
			overflow = true
		} else {
			val = val * 10 + d
		}
		i^ += 1
	}
	return val, i^ > start && !overflow && val <= 100_000
}

// Parses `{n}`, `{n,}`, or `{n,m}` where `n <= m <= 100_000`.
@(private = "file")
parse_iregexp_quantifier :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> bool {
	i, n := idx^ + 1, len(pat)
	min_val, min_ok := scan_quant_uint(pat, &i)
	if !min_ok || i >= n {
		return false
	}
	if pat[i] == ',' {
		i += 1
		if i >= n {
			return false
		}
		if pat[i] != '}' {
			max_val, max_ok := scan_quant_uint(pat, &i)
			if !max_ok || max_val < min_val || i >= n {
				return false
			}
		}
	}
	if pat[i] != '}' {
		return false
	}
	strings.write_string(out, pat[idx^:i + 1])
	idx^ = i + 1
	return true
}

// Parses RFC 9485 `charClassExpr = "[" [ "^" ] ( "-" / CCE1 ) *CCE1 [ "-" ] "]"`.
@(private = "file")
parse_iregexp_class :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> bool {
	i, n := idx^ + 1, len(pat)
	strings.write_byte(out, '[')
	if i < n && pat[i] == '^' {
		strings.write_byte(out, '^')
		i += 1
	}
	if i >= n || pat[i] == ']' {
		return false
	}
	if pat[i] == '-' {
		strings.write_string(out, `\-`)
		i += 1
		if i < n && pat[i] == ']' {
			strings.write_byte(out, ']')
			idx^ = i + 1
			return true
		}
		if i < n && pat[i] == '-' {
			return false
		}
	}
	for i < n && pat[i] != ']' {
		if pat[i] == '-' {
			if i + 1 < n && pat[i + 1] == ']' {
				strings.write_string(out, `\-`)
				i += 1
				break
			}
			return false
		}
		if pat[i] == '\\' && i + 1 < n && (pat[i + 1] == 'p' || pat[i + 1] == 'P') {
			if !parse_iregexp_prop(pat, &i, out) {
				return false
			}
			continue
		}
		r1, ok1 := parse_iregexp_ccchar(pat, &i, out)
		if !ok1 {
			return false
		}
		if i < n && pat[i] == '-' {
			if i + 1 < n && pat[i + 1] == ']' {
				strings.write_string(out, `\-`)
				i += 1
				break
			}
			i += 1
			if i >= n || (pat[i] == '\\' && i + 1 < n && (pat[i + 1] == 'p' || pat[i + 1] == 'P')) {
				return false
			}
			strings.write_byte(out, '-')
			r2, ok2 := parse_iregexp_ccchar(pat, &i, out)
			if !ok2 || r1 > r2 {
				return false
			}
		}
	}
	if i >= n || pat[i] != ']' {
		return false
	}
	strings.write_byte(out, ']')
	idx^ = i + 1
	return true
}

@(private = "file")
parse_iregexp_ccchar :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> (rune, bool) {
	i := idx^
	if i >= len(pat) {
		return 0, false
	}
	c := pat[i]
	if c == '[' || c == ']' || c == '-' {
		return 0, false
	}
	if c == '\\' {
		return parse_iregexp_single_char_esc(pat, idx, out)
	}
	if c < 0x80 {
		if c == '&' {
			strings.write_string(out, `\&`)
		} else {
			strings.write_byte(out, c)
		}
		idx^ = i + 1
		return rune(c), true
	}
	r, w := decode_strict_utf8(pat[i:])
	if w == 0 || !is_scalar_value(r) {
		return 0, false
	}
	strings.write_string(out, pat[i:i + w])
	idx^ = i + w
	return r, true
}

@(private = "file")
parse_iregexp_escape :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> bool {
	if idx^ + 1 >= len(pat) {
		return false
	}
	if next := pat[idx^ + 1]; next == 'p' || next == 'P' {
		return parse_iregexp_prop(pat, idx, out)
	}
	_, ok := parse_iregexp_single_char_esc(pat, idx, out)
	return ok
}

@(private = "file")
parse_iregexp_single_char_esc :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> (r: rune, ok: bool) {
	i := idx^
	if i + 1 >= len(pat) {
		return 0, false
	}
	c := pat[i + 1]
	switch c {
	case '(', ')', '*', '+', '-', '.', '?', '[', '\\', ']', '^', '{', '|', '}': r = rune(c)
	case 'n': r = '\n'
	case 'r': r = '\r'
	case 't': r = '\t'
	case: return 0, false
	}
	strings.write_byte(out, '\\')
	strings.write_byte(out, c)
	idx^ = i + 2
	return r, true
}

@(private = "file")
parse_iregexp_prop :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> bool {
	i := idx^
	if i + 3 >= len(pat) || pat[i + 2] != '{' {
		return false
	}
	close_idx := strings.index_byte(pat[i + 3:], '}')
	if close_idx <= 0 || !is_iregexp_category(pat[i + 3:i + 3 + close_idx]) {
		return false
	}
	end := i + 3 + close_idx + 1
	strings.write_string(out, pat[i:end])
	idx^ = end
	return true
}

@(private = "file")
is_iregexp_category :: proc "contextless" (name: string) -> bool {
	switch name {
	case "L", "Lu", "Ll", "Lt", "Lm", "Lo",
	     "M", "Mn", "Mc", "Me",
	     "N", "Nd", "Nl", "No",
	     "P", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
	     "S", "Sm", "Sc", "Sk", "So",
	     "Z", "Zs", "Zl", "Zp",
	     "C", "Cc", "Cf", "Co", "Cn":
		return true
	}
	return false
}

@(private)
decode_strict_utf8 :: proc "contextless" (s: string) -> (r: rune, w: int) {
	if len(s) == 0 {
		return 0, 0
	}
	if s[0] < 0x80 {
		return rune(s[0]), 1
	}
	r, w = utf8.decode_rune_in_string(s)
	if (r == utf8.RUNE_ERROR && w == 1) || !is_scalar_value(r) {
		return 0, 0
	}
	return r, w
}

@(private)
is_scalar_value :: #force_inline proc "contextless" (r: rune) -> bool {
	return r >= 0 && r <= 0x10FFFF && !(r >= 0xD800 && r <= 0xDFFF)
}

@(private)
compile_iregexp :: proc(pat: string, anchored: bool, allocator, scratch: runtime.Allocator) -> (re: ^regex.Regex, state: Compiled_Pattern_State, oom: bool) {
	b: strings.Builder
	strings.builder_init_len_cap(&b, 0, len(pat) + 16, scratch)
	defer strings.builder_destroy(&b)
	if !translate_iregexp(pat, anchored, &b) {
		return nil, .Invalid, false
	}
	compiled, err := regex.compile(strings.to_string(b), .Oniguruma, {}, allocator, scratch, automaton = true, spans = false)
	if err.kind != .None {
		return nil, .Invalid, err.kind == .Memory
	}
	ptr, alloc_err := new_clone(compiled, allocator)
	if alloc_err != nil {
		return nil, .Invalid, true
	}
	return ptr, .Valid, false
}
