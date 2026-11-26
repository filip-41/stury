package jsonpath

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/regex"

// Strict RFC 9485 I-Regexp validator and translator to `stury:lib/base/regex` (Oniguruma syntax).
//
// Key RFC 9485 rules enforced:
// - `.` matches any Unicode scalar value EXCEPT `\r` (U+000D) and `\n` (U+000A) -> translated to `[^\r\n]`.
// - `^` and `$` outside character classes are literal NormalChars -> escaped as `\^` and `\$`.
// - No anchors (`\A`, `\z`, `\b`), no lookarounds, no backreferences, no non-capturing/flag groups `(?...)`,
//   no lazy quantifiers (`*?`, `+?`, `??`, `{m,n}?`), no `\d`/`\w`/`\s`.
// - Only RFC 9485 `SingleCharEsc` (`\( \) \* \+ \- \. \? \[ \\ \] \^ \n \r \t \{ \| \}`) and
//   Unicode General Category escapes `\p{...}` / `\P{...}` (excluding `Cs` surrogates).
// - Character class expressions `[...]` disallow empty `[]`/`[^]`, unescaped `[`, `\`, `]`, invalid ranges `b-a`,
//   and escape `&` as `\&` so Oniguruma never interprets `&&` as class intersection.
// - Full-string `match` wraps the translated pattern in `\A(?:...)\z`; substring `search` does not.
// - Zero recursion: parenthesized groups are tracked with an explicit depth counter.

// Validates `pat` against RFC 9485 I-Regexp and writes the equivalent Oniguruma pattern into `out`.
// Returns `false` if `pat` is not a valid I-Regexp or contains invalid UTF-8 / surrogates.
// `max_depth` defaults to 500, safely inside `stury:lib/base/regex`'s `MAX_PARSE_DEPTH` (1024).
@(private)
translate_iregexp :: proc(pat: string, anchored: bool, out: ^strings.Builder, max_depth := 500) -> bool {
	if anchored {
		strings.write_string(out, `\A(?:`)
	}
	i := 0
	n := len(pat)
	paren_depth := 0
	// Whether the previous token in the current branch was an atom that can take a quantifier.
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
			// RFC 9485 has no `(?...)` group extensions; `?` cannot start a branch anyway.
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
			if !can_quantify {
				return false
			}
			if !parse_iregexp_quantifier(pat, &i, out) {
				return false
			}
			can_quantify = false
		case '}':
			// Unescaped `}` is not a NormalChar in RFC 9485.
			return false
		case ']':
			// Unescaped `]` is not a NormalChar in RFC 9485.
			return false
		case '.':
			// RFC 9485 Dot: any Unicode scalar value except CR (0x0D) and LF (0x0A).
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
			// Literal NormalChars in RFC 9485 — escape for Oniguruma so they are not anchors.
			strings.write_byte(out, '\\')
			strings.write_byte(out, c)
			i += 1
			can_quantify = true
		case:
			if c < 0x80 {
				// All remaining ASCII bytes are valid NormalChar.
				strings.write_byte(out, c)
				i += 1
				can_quantify = true
			} else {
				r, w := decode_strict_utf8(pat[i:])
				if w == 0 || !is_scalar_value(r) {
					return false
				}
				strings.write_string(out, pat[i:i + w])
				i += w
				can_quantify = true
			}
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

// Parses `{n}`, `{n,}`, or `{n,m}` where `n <= m`.
@(private = "file")
parse_iregexp_quantifier :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> bool {
	i := idx^ + 1 // past '{'
	n := len(pat)
	min_start := i
	min_val: u64
	min_overflow := false
	for i < n && pat[i] >= '0' && pat[i] <= '9' {
		d := u64(pat[i] - '0')
		if min_val > (max(u64) - d) / 10 {
			min_overflow = true
		} else {
			min_val = min_val * 10 + d
		}
		i += 1
	}
	if i == min_start || i >= n {
		return false
	}
	if pat[i] == '}' {
		if min_overflow || min_val > 100_000 {
			return false
		}
		strings.write_string(out, pat[idx^:i + 1])
		idx^ = i + 1
		return true
	}
	if pat[i] != ',' {
		return false
	}
	i += 1
	if i >= n {
		return false
	}
	if pat[i] == '}' {
		if min_overflow || min_val > 100_000 {
			return false
		}
		strings.write_string(out, pat[idx^:i + 1])
		idx^ = i + 1
		return true
	}
	max_start := i
	max_val: u64
	max_overflow := false
	for i < n && pat[i] >= '0' && pat[i] <= '9' {
		d := u64(pat[i] - '0')
		if max_val > (max(u64) - d) / 10 {
			max_overflow = true
		} else {
			max_val = max_val * 10 + d
		}
		i += 1
	}
	if i == max_start || i >= n || pat[i] != '}' {
		return false
	}
	if min_overflow || max_overflow || max_val < min_val || max_val > 100_000 {
		return false
	}
	strings.write_string(out, pat[idx^:i + 1])
	idx^ = i + 1
	return true
}

// Parses RFC 9485 `charClassExpr = "[" [ "^" ] ( "-" / CCE1 ) *CCE1 [ "-" ] "]"`.
@(private = "file")
parse_iregexp_class :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> bool {
	i := idx^ + 1 // past '['
	n := len(pat)
	strings.write_byte(out, '[')
	if i < n && pat[i] == '^' {
		strings.write_byte(out, '^')
		i += 1
	}
	if i >= n || pat[i] == ']' {
		// Empty `[]` or `[^]` is invalid in RFC 9485.
		return false
	}
	// Optional leading literal `-`.
	if pat[i] == '-' {
		// `[-]` or `[^-]` is valid; `[--...]` is invalid unless second `-` is trailing `]` (no, `--` is disallowed:
		// after leading `-`, `*CCE1 [ "-" ]` can only have trailing `-` right before `]`, NOT a range starting from `-`!).
		strings.write_string(out, `\-`)
		i += 1
		if i < n && pat[i] == ']' {
			strings.write_byte(out, ']')
			idx^ = i + 1
			return true
		}
		// Per RFC 9485 §3.1: `charClassExpr = "[" [ "^" ] ( "-" / CCE1 ) *CCE1 [ "-" ] "]"`
		// Wait: if leading `-` is followed immediately by another `-` and then `]`, e.g. `[--]`, that matches
		// `"-" *CCE1 (0 times) "-"`, wait — RFC 9485 Errata/§3.1: `[--]` is explicitly forbidden by prose
		// ("a `-` cannot be immediately followed by `-`"), so reject consecutive unescaped `-`.
		if i < n && pat[i] == '-' {
			return false
		}
	}

	for i < n && pat[i] != ']' {
		// Check trailing literal `-` right before `]`.
		if pat[i] == '-' {
			if i + 1 < n && pat[i + 1] == ']' {
				strings.write_string(out, `\-`)
				i += 1
				break
			}
			return false
		}
		// Must be a `CCE1`: either `charClassEsc` (`\p{...}` / `\P{...}`) or `CCchar [ "-" CCchar ]`.
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
		// Optional range `- CCchar` (only if `-` is NOT immediately before `]`).
		if i < n && pat[i] == '-' {
			if i + 1 < n && pat[i + 1] == ']' {
				// Trailing literal `-`.
				strings.write_string(out, `\-`)
				i += 1
				break
			}
			i += 1 // consume '-'
			if i >= n {
				return false
			}
			// Cannot have a category escape as range end (e.g. `[a-\p{L}]` is invalid).
			if pat[i] == '\\' && i + 1 < n && (pat[i + 1] == 'p' || pat[i + 1] == 'P') {
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

// Parses one `CCchar` inside `[...]`, writing its Oniguruma-safe representation to `out`.
@(private = "file")
parse_iregexp_ccchar :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> (r: rune, ok: bool) {
	i := idx^
	n := len(pat)
	if i >= n {
		return 0, false
	}
	c := pat[i]
	if c == '[' || c == ']' || c == '-' {
		return 0, false
	}
	if c == '\\' {
		r, ok = parse_iregexp_single_char_esc(pat, idx, out)
		return r, ok
	}
	if c < 0x80 {
		// Escape `&` inside `[...]` so Oniguruma never parses `&&` as class intersection.
		if c == '&' {
			strings.write_string(out, `\&`)
		} else {
			strings.write_byte(out, c)
		}
		idx^ = i + 1
		return rune(c), true
	}
	w: int
	r, w = decode_strict_utf8(pat[i:])
	if w == 0 || !is_scalar_value(r) {
		return 0, false
	}
	strings.write_string(out, pat[i:i + w])
	idx^ = i + w
	return r, true
}

// Parses `SingleCharEsc` or `charClassEsc` (`\p{...}` / `\P{...}`).
@(private = "file")
parse_iregexp_escape :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> bool {
	i := idx^
	if i + 1 >= len(pat) {
		return false
	}
	next := pat[i + 1]
	if next == 'p' || next == 'P' {
		return parse_iregexp_prop(pat, idx, out)
	}
	_, ok := parse_iregexp_single_char_esc(pat, idx, out)
	return ok
}

// RFC 9485 `SingleCharEsc`: `\` followed by `( ) * + - . ? [ \ ] ^ n r t { | }`.
@(private = "file")
parse_iregexp_single_char_esc :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> (r: rune, ok: bool) {
	i := idx^
	if i + 1 >= len(pat) {
		return 0, false
	}
	c := pat[i + 1]
	switch c {
	case '(', ')', '*', '+', '-', '.', '?', '[', '\\', ']', '^', '{', '|', '}':
		r = rune(c)
	case 'n':
		r = '\n'
	case 'r':
		r = '\r'
	case 't':
		r = '\t'
	case:
		return 0, false
	}
	strings.write_byte(out, '\\')
	strings.write_byte(out, c)
	idx^ = i + 2
	return r, true
}

// RFC 9485 `catEsc` / `complEsc`: `\p{IsCategory}` / `\P{IsCategory}`.
@(private = "file")
parse_iregexp_prop :: proc(pat: string, idx: ^int, out: ^strings.Builder) -> bool {
	i := idx^
	n := len(pat)
	if i + 3 >= n || pat[i + 2] != '{' {
		return false
	}
	close_idx := strings.index_byte(pat[i + 3:], '}')
	if close_idx <= 0 {
		return false
	}
	name := pat[i + 3:i + 3 + close_idx]
	if !is_iregexp_category(name) {
		return false
	}
	strings.write_string(out, pat[i:i + 3 + close_idx + 1])
	idx^ = i + 3 + close_idx + 1
	return true
}

// Exact set of RFC 9485 §3.1 Unicode General Category names (note: `Cs` surrogates is excluded).
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

// Decodes one valid UTF-8 sequence strictly (rejecting overlongs, surrogates, and truncated bytes).
// Returns width 0 on invalid UTF-8.
@(private)
decode_strict_utf8 :: proc "contextless" (s: string) -> (r: rune, w: int) {
	if len(s) == 0 {
		return 0, 0
	}
	b0 := s[0]
	if b0 < 0x80 {
		return rune(b0), 1
	}
	r, w = utf8.decode_rune_in_string(s)
	if r == utf8.RUNE_ERROR && w == 1 {
		return 0, 0
	}
	// Verify canonical encoding (rejects invalid surrogates / overlong forms).
	if r >= 0xD800 && r <= 0xDFFF || r > 0x10FFFF {
		return 0, 0
	}
	return r, w
}

@(private)
is_scalar_value :: #force_inline proc "contextless" (r: rune) -> bool {
	return r >= 0 && r <= 0x10FFFF && !(r >= 0xD800 && r <= 0xDFFF)
}

// Compiles an RFC 9485 I-Regexp pattern into a `^regex.Regex` in `allocator` using `scratch`.
// Returns `(nil, .Invalid)` if the pattern is not valid I-Regexp, `(nil, .Dynamic)` on OOM,
// or `(re, .Valid)` on success.
@(private)
compile_iregexp :: proc(
	pat: string,
	anchored: bool,
	allocator, scratch: runtime.Allocator,
) -> (re: ^regex.Regex, state: Compiled_Pattern_State, oom: bool) {
	b: strings.Builder
	strings.builder_init_len_cap(&b, 0, len(pat) + 16, scratch)
	defer strings.builder_destroy(&b)

	if !translate_iregexp(pat, anchored, &b) {
		return nil, .Invalid, false
	}
	translated := strings.to_string(b)
	compiled, err := regex.compile(translated, .Oniguruma, {}, allocator, scratch, automaton = true, spans = false)
	if err.kind != .None {
		if err.kind == .Memory {
			return nil, .Invalid, true
		}
		return nil, .Invalid, false
	}
	ptr, alloc_err := new_clone(compiled, allocator)
	if alloc_err != nil {
		return nil, .Invalid, true
	}
	return ptr, .Valid, false
}
