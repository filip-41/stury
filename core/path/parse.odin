package path

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Query path vocabulary, shared by every codec: a chain of steps from a node.
//
// `Name` compares by decoded text, so an escaped key matches its literal text.
// `Index` is signed: non-negative counts from the start of an array, negative from its end.
// `Any` reads every member of an object or element of an array. `Name` stays first so the zero step
// is still `Name("")`.
Step :: union #no_nil {
	Name,
	Index,
	Any,
}

Name :: distinct string

Index :: distinct i64

Any :: struct {}

// A borrowed chain of steps: the caller owns the storage and keeps it alive for
// the walk. An empty path means the node itself.
//
// `limit` caps the `Found` answers (jq `limit(n; f)`, where `first(f)` is 1), and drops every answer after the
// last of them. 0 asks for every answer.
//
// `per_element` makes a path with an `Any` step answer as jq outputs it: once for each element an `Any` step
// reads, `.Missing` where jq gives null (a `Name` or `Index` step after the last `Any` finds no such member
// or element, or meets null) and `.Type_Mismatch` where jq errors (any other step that does not apply). Its
// `limit` then counts every answer. Without it, an `Any` path answers only where it lands.
Path :: struct {
	steps:       []Step,
	limit:       int,
	per_element: bool,
}

// Path syntax, for callers that write a path as text. It lowers to exactly the `Step` values
// a caller would build by hand. The scanner does not know it exists.
//
// The text is the jq path subset, so a jq path means the same thing here or is refused, never reread:
//
//	.a.b             Name("a"), Name("b")
//	."a-b"  .["a-b"] Name("a-b")        a quoted name is a JSON string: `."a\"b"` is Name(`a"b`)
//	.""  .[""]       Name(""), the empty key
//	.[0]  .[-1]      Index(0), Index(-1)
//	.[]  .a[]        Any, and Name("a"), Any
//	.                the empty path, the root
//	first(P)         P with limit 1
//	limit(N; P)      P with limit N (N >= 1)
//
// A bare name is a jq identifier, `[A-Za-z_][A-Za-z0-9_]*`. Anything else is quoted, as in jq, where
// `.a-b` is a subtraction. Whitespace is allowed around the whole text and inside `first(` and `limit(`,
// never inside a path. Everything else (`..`, `|`, `,`, `?`, slices, filters, functions, `$vars`, string
// interpolation, a path that does not start with `.`) is `Unsupported_Syntax` at its offset.
//
// A quoted name without escapes borrows `text`, and one with escapes decodes into the caller's `names` buffer,
// which `len(text)` bytes always suffice for. A lone surrogate escape is `Bad_Escape`, as in a JSON string.

Parse_Error :: enum {
	None,
	// A `[` with no matching `]`.
	Unclosed_Bracket,
	// A `"` with no closing quote.
	Unclosed_Quote,
	// A `\` in a quoted name that starts no JSON escape, or a lone surrogate half.
	Bad_Escape,
	// A `.` that ends the text with no step after it. (`.""` and `[""]` name the empty key, a member like another.)
	Empty_Key,
	// A bracket holding a `-` or an integer that is not followed by `]`.
	Bad_Index,
	// An integer the `Index` arm or `Path.limit` cannot hold (past `2^63 - 1`, or `2^63` on the
	// negative side). Well formed but too large: refused, never wrapped.
	Limit_Index,
	// The caller's buffer cannot hold the steps this text names, or `names` the escaped names, or `json.query`'s
	// `out` could not grow.
	Out_Of_Room,
	// A construct outside the jq path subset above, or one this package cannot lower: `limit(0; ...)`
	// (a limit of 0 means every answer here, jq's means none).
	Unsupported_Syntax,
}

// Why a parse failed, and where.
Parse_Fault :: struct {
	error:  Parse_Error,
	offset: u64, // the byte the parser stopped on
}

// Parse `text` into `steps`. The path borrows `steps` and, for its names, `text` and `names`.
//
// All-or-nothing: a fault reports an empty path. `steps` must hold every step `text` names and `names`
// every escaped name decoded. A buffer too small reports `Out_Of_Room` and never truncates.
parse_path :: proc(text: string, steps: []Step, names: []u8 = nil) -> (p: Path, err: Maybe(Parse_Fault)) {
	i := skip_space(text, 0)
	limit, n: int
	fault: Parse_Fault
	ok: bool
	wrapped := false
	switch {
	case strings.has_prefix(text[i:], "first("):
		limit = 1
		wrapped = true
		i = skip_space(text, i + len("first("))
	case strings.has_prefix(text[i:], "limit("):
		wrapped = true
		i = skip_space(text, i + len("limit("))
		limit, i, fault, ok = scan_limit(text, i)
		if !ok {
			return {}, fault
		}
		i = skip_space(text, i)
		if i >= len(text) || text[i] != ';' {
			return {}, unsupported(i)
		}
		i = skip_space(text, i + 1)
	}
	n, i, fault, ok = lower_path(text, i, steps, names)
	if !ok {
		return {}, fault
	}
	i = skip_space(text, i)
	if wrapped {
		if i >= len(text) || text[i] != ')' {
			return {}, unsupported(i)
		}
		i = skip_space(text, i + 1)
	}
	if i < len(text) {
		return {}, unsupported(i)
	}
	return Path{steps = steps[:n], limit = limit}, nil
}

// A path from `pos`: the root `.` and the steps after it. Stops at the first byte that continues no step,
// and the caller decides whether that byte may follow.
@(private)
lower_path :: proc(text: string, pos: int, out: []Step, names: []u8) -> (n, next: int, fault: Parse_Fault, ok: bool) {
	i := pos
	used := 0
	if i >= len(text) || text[i] != '.' {
		return 0, i, unsupported(i), false
	}
	i += 1
	// A name step may open the path or follow a `.`. A bracket step may follow anything.
	name_ok := true
	// Just consumed a `.` between two steps, so a step must follow.
	after_dot := false
	for {
		c: u8 = text[i] if i < len(text) else 0
		is_name := c == '"' || is_ident_start(c)
		if !is_name && c != '[' {
			if after_dot {
				if c == 0 || is_space(c) || c == ')' || c == ';' {
					return 0, i, Parse_Fault{error = .Empty_Key, offset = u64(i)}, false
				}
				return 0, i, unsupported(i), false
			}
			return n, i, {}, true
		}
		if is_name && !name_ok {
			// A name with no `.` before it: `."a""b"`.
			return 0, i, unsupported(i), false
		}
		step: Step
		at := i
		if is_name {
			step, i, fault, ok = scan_name(text, i, names, &used)
		} else {
			step, i, fault, ok = scan_bracket(text, i, names, &used)
		}
		if !ok {
			return 0, i, fault, false
		}
		if n >= len(out) {
			return 0, i, Parse_Fault{error = .Out_Of_Room, offset = u64(at)}, false
		}
		out[n] = step
		n += 1
		after_dot = i < len(text) && text[i] == '.'
		if after_dot {
			i += 1
		}
		name_ok = after_dot
	}
}

// A quoted name (`"a-b"`) or a bare identifier, as the step starting at `pos`.
@(private)
scan_name :: proc(text: string, pos: int, names: []u8, used: ^int) -> (step: Step, next: int, fault: Parse_Fault, ok: bool) {
	if text[pos] == '"' {
		key, after, f, kok := scan_quoted(text, pos, names, used)
		if !kok {
			return Step{}, after, f, false
		}
		return Name(key), after, {}, true
	}
	i := pos + 1
	for i < len(text) && is_ident_byte(text[i]) {
		i += 1
	}
	return Name(text[pos:i]), i, {}, true
}

// `"key"` from its opening quote: the decoded name, and the index past the closing quote. A name with
// escapes decodes into `names[used^:]`.
@(private)
scan_quoted :: proc(text: string, pos: int, names: []u8, used: ^int) -> (key: string, next: int, fault: Parse_Fault, ok: bool) {
	lo := pos + 1
	n, escaped := 0, false
	n, next, escaped, fault, ok = unquote(text, lo, nil)
	if !ok {
		return "", next, fault, false
	}
	switch {
	case !escaped:
		return text[lo:next - 1], next, {}, true
	case len(names) - used^ < n:
		return "", next, Parse_Fault{error = .Out_Of_Room, offset = u64(pos)}, false
	}
	dst := names[used^:][:n]
	unquote(text, lo, dst)
	used^ += n
	return string(dst), next, {}, true
}

// The JSON string body from `lo` to its closing quote: its decoded length, the index past the quote, and
// whether it holds an escape. The decoded bytes go to `dst` when it is not nil.
@(private)
unquote :: proc(text: string, lo: int, dst: []u8) -> (n, next: int, escaped: bool, fault: Parse_Fault, ok: bool) {
	i := lo
	for i < len(text) {
		c := text[i]
		if c == '"' {
			return n, i + 1, escaped, {}, true
		}
		if c != '\\' {
			if dst != nil {
				dst[n] = c
			}
			n += 1
			i += 1
			continue
		}
		escaped = true
		if i + 1 >= len(text) {
			break
		}
		r: rune
		width := 2
		switch e := text[i + 1]; e {
		case '"', '\\', '/':
			r = rune(e)
		case 'b':
			r = '\b'
		case 'f':
			r = '\f'
		case 'n':
			r = '\n'
		case 'r':
			r = '\r'
		case 't':
			r = '\t'
		case 'u':
			hi, hex := hex4(text, i + 2)
			if !hex {
				return 0, i, escaped, Parse_Fault{error = .Bad_Escape, offset = u64(i)}, false
			}
			r, width = rune(hi), 6
			if hi >= 0xD800 && hi < 0xE000 {
				low, pair := hex4(text, i + 8)
				if !(hi < 0xDC00 && pair && text[i + 6] == '\\' && text[i + 7] == 'u' && low >= 0xDC00 && low < 0xE000) {
					return 0, i, escaped, Parse_Fault{error = .Bad_Escape, offset = u64(i)}, false
				}
				r, width = rune(0x10000 + (hi - 0xD800) << 10 + (low - 0xDC00)), 12
			}
		case '(':
			// jq's string interpolation.
			return 0, i, escaped, unsupported(i), false
		case:
			return 0, i, escaped, Parse_Fault{error = .Bad_Escape, offset = u64(i)}, false
		}
		bytes, size := utf8.encode_rune(r)
		if dst != nil {
			copy(dst[n:], bytes[:size])
		}
		n += size
		i += width
	}
	return 0, i, escaped, Parse_Fault{error = .Unclosed_Quote, offset = u64(lo - 1)}, false
}

// The four hex digits at `at`, if `text` has them there.
@(private)
hex4 :: proc(text: string, at: int) -> (v: u32, ok: bool) {
	if at + 4 > len(text) {
		return 0, false
	}
	for j in 0 ..< 4 {
		d := strconv._digit_value(rune(text[at + j]))
		if d >= 16 {
			return 0, false
		}
		v = v << 4 | u32(d)
	}
	return v, true
}

// `[]`, `["key"]` or `[index]`, from the `[`.
@(private)
scan_bracket :: proc(text: string, pos: int, names: []u8, used: ^int) -> (step: Step, next: int, fault: Parse_Fault, ok: bool) {
	open := pos
	i := pos + 1
	if i >= len(text) {
		return Step{}, i, Parse_Fault{error = .Unclosed_Bracket, offset = u64(open)}, false
	}
	switch c := text[i]; {
	case c == ']':
		return Any{}, i + 1, {}, true
	case c == '"':
		key, after, f, kok := scan_quoted(text, i, names, used)
		if !kok {
			return Step{}, after, f, false
		}
		if after >= len(text) || text[after] != ']' {
			return Step{}, after, Parse_Fault{error = .Unclosed_Bracket, offset = u64(open)}, false
		}
		return Name(key), after + 1, {}, true
	case c == '-' || (c >= '0' && c <= '9'):
		return scan_index(text, i)
	}
	// An expression, a slice, a variable: not a path.
	return Step{}, i, unsupported(i), false
}

// An integer index from `lo` (its sign or first digit) up to the `]`.
@(private)
scan_index :: proc(text: string, lo: int) -> (step: Step, next: int, fault: Parse_Fault, ok: bool) {
	i := lo
	if text[i] == '-' {
		i += 1
	}
	digits := i
	for i < len(text) && text[i] >= '0' && text[i] <= '9' {
		i += 1
	}
	if i < len(text) && text[i] == ':' && i > digits {
		// `[1:3]`: a slice.
		return Step{}, i, unsupported(i), false
	}
	if i == digits || i >= len(text) || text[i] != ']' {
		return Step{}, i, Parse_Fault{error = .Bad_Index, offset = u64(lo)}, false
	}
	neg := text[lo] == '-'
	mag := magnitude(text[digits:i])
	if mag > u64(max(i64)) {
		// `2^63` is still an index, but only when negative.
		if !neg || mag > u64(max(i64)) + 1 {
			return Step{}, i, Parse_Fault{error = .Limit_Index, offset = u64(lo)}, false
		}
	}
	v := i64(mag)
	if neg {
		// Negating `2^63` overflows, so `min(i64)` is named directly.
		v = mag == u64(max(i64)) + 1 ? min(i64) : -v
	}
	return Index(v), i + 1, {}, true
}

// The `N` of `limit(N; ...)`: a positive decimal integer.
@(private)
scan_limit :: proc(text: string, lo: int) -> (limit, next: int, fault: Parse_Fault, ok: bool) {
	i := lo
	for i < len(text) && text[i] >= '0' && text[i] <= '9' {
		i += 1
	}
	if i == lo {
		return 0, i, unsupported(lo), false
	}
	mag := magnitude(text[lo:i])
	if mag > u64(max(int)) {
		return 0, i, Parse_Fault{error = .Limit_Index, offset = u64(lo)}, false
	}
	if mag == 0 {
		return 0, i, unsupported(lo), false
	}
	return int(mag), i, {}, true
}

// The magnitude of a run of digits, clamped one past `2^63` so an overlong run stays distinguishable from
// one form `2^63`. It clamps rather than wraps.
@(private)
magnitude :: proc(digits: string) -> u64 {
	mag_cap := u64(max(i64)) + 2
	mag: u64 = 0
	for j in 0 ..< len(digits) {
		d := u64(digits[j] - '0')
		if mag > (mag_cap - d) / 10 {
			mag = mag_cap
		} else {
			mag = mag * 10 + d
		}
	}
	return mag
}

@(private)
unsupported :: proc(offset: int) -> Parse_Fault {
	return Parse_Fault{error = .Unsupported_Syntax, offset = u64(offset)}
}

// JSON's whitespace, which jq's lexer shares.
@(private = "file")
is_space :: #force_inline proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

@(private)
skip_space :: proc(text: string, pos: int) -> int {
	i := pos
	for i < len(text) && is_space(text[i]) {
		i += 1
	}
	return i
}

@(private)
is_ident_start :: proc(c: u8) -> bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'
}

@(private)
is_ident_byte :: proc(c: u8) -> bool {
	return is_ident_start(c) || (c >= '0' && c <= '9')
}
