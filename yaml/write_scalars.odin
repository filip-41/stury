package yaml

// How a string is spelled in a YAML text. A string is plain when the text reads back as the same string under the 1.2
// core schema and under a 1.1 reader, single-quoted when it holds nothing a quote cannot, a literal block when it has
// line ends and the place takes one, and double-quoted otherwise.

import "core:unicode/utf8"
import core "../core"
import write "../core/write"

@(private)
Shape :: enum u8 {
	Plain,
	Single,
	Double,
	Literal,
}

// What a string holds that decides how it can be spelled.
@(private)
Facts :: struct {
	escapes:   bool, // a rune a quoted scalar can only hold as an escape, or any rune past U+007F under `ascii`
	line_ends: bool, // a line feed
	tab:       bool,
	invalid:   bool, // bytes that are no UTF-8
}

// Reads the facts of `s`. A rune is printable when YAML lets a text hold it, and U+2028, U+2029 and U+FEFF are escaped.
@(private)
facts_of_text :: proc(s: string, ascii: bool) -> (f: Facts) {
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '\n':
			f.line_ends = true
			i += 1
		case c == '\t':
			f.tab = true
			i += 1
		case c < 0x20 || c == 0x7f:
			f.escapes = true
			i += 1
		case c < 0x80:
			i += 1
		case:
			r, width := utf8.decode_rune_in_string(s[i:])
			if r == utf8.RUNE_ERROR && width <= 1 {
				f.invalid = true
				return
			}
			if ascii || !printable(r) {
				f.escapes = true
			}
			i += width
		}
	}
	return
}

@(private)
printable :: #force_inline proc "contextless" (r: rune) -> bool {
	switch {
	case r == 0x85:
		return false
	case r < 0xa0:
		return r >= 0x20 && r < 0x7f
	case r == 0x2028 || r == 0x2029 || r == 0xfeff:
		return false
	}
	return r <= 0xd7ff || r >= 0xe000 && r <= 0xfffd || r >= 0x10000
}

// Whether `s`, which holds no control byte, can stand as a plain scalar: it starts and ends with a character a plain
// scalar may, holds no `: ` or ` #`, and in a flow collection no flow indicator.
@(private)
plain_fits :: proc(s: string, flow: bool) -> bool {
	if len(s) == 0 || s[0] == ' ' || s[len(s) - 1] == ' ' || s[len(s) - 1] == ':' {
		return false
	}
	switch s[0] {
	case ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`':
		return false
	case '-', '?', ':':
		if len(s) == 1 || s[1] == ' ' || flow && is_flow_byte(s[1]) {
			return false
		}
	}
	if len(s) >= 3 && (s[:3] == "---" || s[:3] == "...") {
		return false
	}
	for i in 0 ..< len(s) {
		switch s[i] {
		case ':':
			if i + 1 < len(s) && (s[i + 1] == ' ' || flow && is_flow_byte(s[i + 1])) {
				return false
			}
		case '#':
			if s[i - 1] == ' ' {
				return false
			}
		case ',', '[', ']', '{', '}':
			if flow {
				return false
			}
		}
	}
	return true
}

@(private)
is_flow_byte :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == ',' || b == '[' || b == ']' || b == '{' || b == '}'
}

// Whether a reader of the core schema or of YAML 1.1 reads the plain scalar `s` as anything but a string: a null, a
// boolean, a number in either schema (underscores, leading zeros, sexagesimal and base-two forms of 1.1 included), a
// timestamp, or the merge and value keys.
@(private)
reads_as_other :: proc(s: string) -> bool {
	// A word of either schema is at most five bytes and starts with one of y, n, o, t or f.
	if len(s) > 0 && s[0] | 0x20 >= 'a' && s[0] | 0x20 <= 'z' {
		switch s[0] | 0x20 {
		case 'y', 'n', 'o', 't', 'f':
			if len(s) > 5 {
				return false
			}
		case:
			return false
		}
	}
	if classify(transmute([]u8)s) != .Text {
		return true
	}
	if len(s) <= 5 {
		lower: [5]u8
		for c, i in transmute([]u8)s {
			lower[i] = c | 0x20 if c >= 'A' && c <= 'Z' else c
		}
		switch string(lower[:len(s)]) {
		case "y", "n", "yes", "no", "on", "off", "true", "false", "null", "=", "<<":
			return true
		}
	}
	return s == "<<" || looks_numeric_11(s) || looks_timestamp(s)
}

@(private)
digit_run :: proc(s: string, from: int) -> int {
	i := from
	for i < len(s) && (s[i] >= '0' && s[i] <= '9' || s[i] == '_') {
		i += 1
	}
	return i
}

// The forms of YAML 1.1 numbers: integers with underscores, a leading zero or a `0b`, `0x` prefix, sexagesimal
// numbers, and floats with a point.
@(private)
looks_numeric_11 :: proc(s: string) -> bool {
	i := 1 if len(s) > 0 && (s[0] == '-' || s[0] == '+') else 0
	if i >= len(s) {
		return false
	}
	if s[i] == '0' && i + 1 < len(s) {
		switch s[i + 1] | 0x20 {
		case 'b', 'x', 'o':
			return i + 2 < len(s)
		}
	}
	at := digit_run(s, i)
	if at > i && s[i] == '_' {
		return false
	}
	if at == i && s[i] != '.' {
		return false
	}
	if at < len(s) && s[at] == ':' {
		for at < len(s) && s[at] == ':' {
			next := at + 1
			for next < len(s) && next < at + 3 && s[next] >= '0' && s[next] <= '9' {
				next += 1
			}
			if next == at + 1 {
				return false
			}
			at = next
		}
		if at < len(s) && s[at] == '.' {
			return digit_run(s, at + 1) == len(s)
		}
		return at == len(s)
	}
	if at == len(s) {
		return true
	}
	if s[at] != '.' {
		return false
	}
	at = digit_run(s, at + 1)
	if at == len(s) {
		return true
	}
	if s[at] | 0x20 != 'e' || at + 2 >= len(s) || s[at + 1] != '-' && s[at + 1] != '+' {
		return false
	}
	for c in transmute([]u8)s[at + 2:] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// A date as 1.1 reads it: four digits, a hyphen, and the month and day.
@(private)
looks_timestamp :: proc(s: string) -> bool {
	if len(s) < 8 {
		return false
	}
	for c in transmute([]u8)s[:4] {
		if c < '0' || c > '9' {
			return false
		}
	}
	if s[4] != '-' {
		return false
	}
	at := 5
	for at < len(s) && at < 7 && s[at] >= '0' && s[at] <= '9' {
		at += 1
	}
	return at > 5 && at < len(s) && s[at] == '-' && at + 1 < len(s) && s[at + 1] >= '0' && s[at + 1] <= '9'
}

// Where a string is written and what the writer may choose from.
@(private)
Place :: struct {
	flow:   bool, // inside a flow collection
	key:    bool, // a mapping key, which is one line
	block:  bool, // a literal block can stand here
	ascii:  bool,
	// The source's own style, which a text read from YAML keeps when it still reads back, and `nil` for a computed string.
	keeps:  Maybe(Style),
	// A tag is written with the string, which settles the type a plain scalar would be read as.
	tagged: bool,
}

// The bytes a plain scalar holds anywhere in a block or flow collection without a second look.
@(private, rodata)
SAFE_PLAIN := [256]bool {
	'a' ..= 'z' = true,
	'A' ..= 'Z' = true,
	'0' ..= '9' = true,
	'_' = true, '.' = true, '/' = true, '-' = true, '+' = true, '=' = true, ' ' = true, '(' = true, ')' = true, '$' = true, '~' = true, ';' = true,
}

// Whether `s` is plain in every place: it starts with a letter, a numeral, a slash or an underscore, ends with no space
// and holds only bytes of `SAFE_PLAIN`.
@(private)
plainly_safe :: proc(s: string) -> bool {
	if len(s) == 0 || s[len(s) - 1] == ' ' {
		return false
	}
	switch s[0] {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '/':
	case:
		return false
	}
	for c in transmute([]u8)s {
		if !SAFE_PLAIN[c] {
			return false
		}
	}
	return true
}

// Chooses how `s` is spelled in `place`. A string that is no UTF-8 is `.Invalid_Utf8`.
@(private)
shape_of :: proc(s: string, place: Place) -> (Shape, core.Typed_Error_Kind) {
	if place.keeps == nil && plainly_safe(s) && !reads_as_other(s) {
		return .Plain, .None
	}
	f := facts_of_text(s, place.ascii)
	if f.invalid {
		return .Double, .Invalid_Utf8
	}
	if style, kept := place.keeps.?; kept {
		switch style {
		case .Plain:
			if !f.escapes && !f.line_ends && !f.tab && plain_fits(s, place.flow) && (place.key || place.tagged || classify(transmute([]u8)s) == .Text) {
				return .Plain, .None
			}
		case .Single:
			if !f.escapes && !f.line_ends {
				return .Single, .None
			}
			return .Double, .None
		case .Double:
			return .Double, .None
		case .Block:
			if literal_fits(s, f, place) {
				return .Literal, .None
			}
		}
	}
	switch {
	case len(s) == 0:
		return .Double, .None
	case !f.escapes && !f.line_ends && !f.tab && plain_fits(s, place.flow) && !reads_as_other(s):
		return .Plain, .None
	case literal_fits(s, f, place):
		return .Literal, .None
	case !f.escapes && !f.line_ends:
		return .Single, .None
	}
	return .Double, .None
}

// Whether `s` is a literal block scalar's text here: it has a line end, holds nothing a block cannot, starts with a
// character that sets the block's indent, and has no line of white space alone.
@(private)
literal_fits :: proc(s: string, f: Facts, place: Place) -> bool {
	if !place.block || place.key || place.flow || f.escapes || !f.line_ends || s[0] == ' ' || s[0] == '\n' || s[0] == '\t' {
		return false
	}
	body := s
	for len(body) > 0 && body[len(body) - 1] == '\n' {
		body = body[:len(body) - 1]
	}
	if len(body) == 0 {
		return false
	}
	line_start := 0
	for i in 0 ..= len(body) {
		if i == len(body) || body[i] == '\n' {
			blank := i > line_start
			for c in transmute([]u8)body[line_start:i] {
				blank &&= c == ' ' || c == '\t'
			}
			if blank {
				return false
			}
			line_start = i + 1
		}
	}
	return true
}

// Writes `s` between single quotes.
@(private)
put_single :: proc(out: ^write.Out, s: string) {
	write.put_byte(out, '\'')
	run := 0
	for i in 0 ..< len(s) {
		if s[i] == '\'' {
			write.put_text(out, s[run:i + 1])
			write.put_byte(out, '\'')
			run = i + 1
		}
	}
	write.put_text(out, s[run:])
	write.put_byte(out, '\'')
}

// Writes `s`, which is UTF-8, between double quotes. Quote, backslash, the control bytes, the runes YAML cannot hold
// as they are and, under `ascii`, every rune past U+007F are escaped.
@(private)
put_double :: proc(out: ^write.Out, s: string, ascii: bool) {
	HEX := "0123456789abcdef"
	write.put_byte(out, '"')
	run := 0
	for i := 0; i < len(s); {
		c := s[i]
		escape: string
		width := 1
		buf: [10]u8
		switch {
		case c == '"':
			escape = `\"`
		case c == '\\':
			escape = `\\`
		case c == '\n':
			escape = `\n`
		case c == '\t':
			escape = `\t`
		case c == '\r':
			escape = `\r`
		case c == 0:
			escape = `\0`
		case c == 7:
			escape = `\a`
		case c == 8:
			escape = `\b`
		case c == 11:
			escape = `\v`
		case c == 12:
			escape = `\f`
		case c == 27:
			escape = `\e`
		case c < 0x20 || c == 0x7f:
			buf = {'\\', 'x', HEX[c >> 4], HEX[c & 15], 0, 0, 0, 0, 0, 0}
			escape = string(buf[:4])
		case c < 0x80:
			i += 1
			continue
		case:
			r, w := utf8.decode_rune_in_string(s[i:])
			width = w
			switch {
			case r == 0x85:
				escape = `\N`
			case r == 0xa0 && ascii:
				escape = `\_`
			case r == 0x2028:
				escape = `\L`
			case r == 0x2029:
				escape = `\P`
			case !ascii && printable(r):
				i += w
				continue
			case r > 0xffff:
				buf = {'\\', 'U', HEX[(r >> 28) & 15], HEX[(r >> 24) & 15], HEX[(r >> 20) & 15], HEX[(r >> 16) & 15], HEX[(r >> 12) & 15], HEX[(r >> 8) & 15], HEX[(r >> 4) & 15], HEX[r & 15]}
				escape = string(buf[:10])
			case r > 0xff:
				buf = {'\\', 'u', HEX[(r >> 12) & 15], HEX[(r >> 8) & 15], HEX[(r >> 4) & 15], HEX[r & 15], 0, 0, 0, 0}
				escape = string(buf[:6])
			case:
				buf = {'\\', 'x', HEX[(r >> 4) & 15], HEX[r & 15], 0, 0, 0, 0, 0, 0}
				escape = string(buf[:4])
			}
		}
		write.put_text(out, s[run:i])
		write.put_text(out, escape)
		i += width
		run = i
	}
	write.put_text(out, s[run:])
	write.put_byte(out, '"')
}

// Writes `s` as the scalar `shape` names, which is not `.Literal`: that one is a block of lines, see `put_literal`.
@(private)
put_scalar :: proc(out: ^write.Out, s: string, shape: Shape, ascii: bool) {
	switch shape {
	case .Plain, .Literal:
		write.put_text(out, s)
	case .Single:
		put_single(out, s)
	case .Double:
		put_double(out, s, ascii)
	}
}

// Writes the header and lines of a literal block scalar for `s`, with its lines indented by `ind` spaces, each line
// ended. A header chomps the final line ends: `-` for none, nothing for one and `+` for more.
@(private)
put_literal :: proc(out: ^write.Out, s: string, ind: int) {
	body := s
	for len(body) > 0 && body[len(body) - 1] == '\n' {
		body = body[:len(body) - 1]
	}
	ends := len(s) - len(body)
	write.put_byte(out, '|')
	switch {
	case ends == 0:
		write.put_byte(out, '-')
	case ends > 1:
		write.put_byte(out, '+')
	}
	write.put_byte(out, '\n')
	rest := body
	for {
		line := rest
		cut := -1
		for c, i in transmute([]u8)rest {
			if c == '\n' {
				cut = i
				break
			}
		}
		if cut >= 0 {
			line = rest[:cut]
		}
		if len(line) > 0 {
			put_spaces(out, ind)
			write.put_text(out, line)
		}
		write.put_byte(out, '\n')
		if cut < 0 {
			break
		}
		rest = rest[cut + 1:]
	}
	for _ in 1 ..< ends {
		write.put_byte(out, '\n')
	}
}

@(private)
put_spaces :: proc(out: ^write.Out, n: int) {
	for _ in 0 ..< n {
		write.put_byte(out, ' ')
	}
}
