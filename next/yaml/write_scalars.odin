package yaml

import "base:intrinsics"
import "core:unicode/utf8"
import "stury:lib/ops/write"

// How a YAML string or key is spelled: plain when safe under both YAML 1.2 Core Schema and YAML 1.1 readers,
// single-quoted when free of control escapes or line breaks, literal/folded block when multi-line in a block context,
// and double-quoted otherwise.

@(private)
Shape :: enum u8 {
	Plain,
	Single,
	Double,
	Literal,
	Folded,
}

@(private)
Text_Facts :: struct {
	escapes:   bool,
	line_ends: bool,
	tab:       bool,
	invalid:   bool,
}

@(private)
Place :: struct {
	flow:   bool,
	key:    bool,
	block:  bool,
	ascii:  bool,
	keeps:  Maybe(Style),
	folded: bool,
	tagged: bool,
}

@(private, rodata)
SAFE_PLAIN := [256]bool {
	'a' ..= 'z' = true,
	'A' ..= 'Z' = true,
	'0' ..= '9' = true,
	'_' = true, '.' = true, '/' = true, '-' = true, '+' = true, '=' = true, ' ' = true, '(' = true, ')' = true, '$' = true, '~' = true, ';' = true,
}

@(private)
put_str :: #force_inline proc(out: ^write.Out, s: string) {
	write.put(out, transmute([]u8)s)
}

@(private)
put_run :: #force_inline proc(out: ^write.Out, n: int, c: u8) #no_bounds_check {
	if n <= 0 {
		return
	}
	if c == ' ' && n + 7 <= write.ROOM_MAX {
		p := write.room(out, n + 7)
		SPACES :: u64(0x2020_2020_2020_2020)
		for at := 0; at < n; at += 8 {
			intrinsics.unaligned_store((^u64)(p[at:]), SPACES)
		}
		out.cursor += n
		return
	}
	put_run_slow(out, n, c)
}

@(private = "file", cold)
put_run_slow :: #force_no_inline proc(out: ^write.Out, n: int, c: u8) {
	buf: [128]u8 = c
	left := n
	for left > len(buf) {
		write.put(out, buf[:])
		left -= len(buf)
	}
	write.put(out, buf[:left])
}

@(private)
put_hex_escape :: proc(out: ^write.Out, prefix: string, code: u32, digits: int) {
	hex := "0123456789abcdef"
	put_str(out, prefix)
	if digits <= 0 {
		return
	}
	buf: [8]u8
	for i := digits - 1; i >= 0; i -= 1 {
		buf[i] = hex[(code >> uint((digits - 1 - i) * 4)) & 0xF]
	}
	write.put(out, buf[:digits])
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

@(private)
printable_ascii :: proc "contextless" (s: string) -> bool #no_bounds_check {
	for c in transmute([]u8)s {
		if c < 0x20 || c > 0x7e {
			return false
		}
	}
	return true
}

@(private)
facts_of_text :: proc "contextless" (s: string, ascii: bool) -> (f: Text_Facts) #no_bounds_check {
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
plain_fits :: proc "contextless" (s: string, flow: bool) -> bool #no_bounds_check {
	if len(s) == 0 || s[0] == ' ' || s[len(s) - 1] == ' ' || s[len(s) - 1] == ':' {
		return false
	}
	switch s[0] {
	case ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`':
		return false
	case '-', '?', ':':
		if len(s) == 1 || s[1] == ' ' || flow && is_flow_indicator(s[1]) {
			return false
		}
	}
	if len(s) >= 3 && (s[:3] == "---" || s[:3] == "...") {
		return false
	}
	for i in 0 ..< len(s) {
		switch s[i] {
		case ':':
			if i + 1 < len(s) && (s[i + 1] == ' ' || flow && is_flow_indicator(s[i + 1])) {
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
plainly_safe :: proc "contextless" (s: string) -> bool #no_bounds_check {
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

@(private)
reads_as_other :: proc "contextless" (s: string) -> bool #no_bounds_check {
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
	return looks_numeric_11(s) || looks_timestamp(s)
}

@(private)
digit_run :: proc "contextless" (s: string, from: int) -> int #no_bounds_check {
	i := from
	for i < len(s) && (s[i] >= '0' && s[i] <= '9' || s[i] == '_') {
		i += 1
	}
	return i
}

@(private)
looks_numeric_11 :: proc "contextless" (s: string) -> bool #no_bounds_check {
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

@(private)
looks_timestamp :: proc "contextless" (s: string) -> bool #no_bounds_check {
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

@(private)
block_fits :: proc "contextless" (s: string, f: Text_Facts, place: Place) -> bool #no_bounds_check {
	if !place.block || place.key || place.flow || f.escapes || len(s) == 0 || s[0] == ' ' || s[0] == '\n' || s[0] == '\t' {
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

@(private)
shape_of :: proc "contextless" (s: string, place: Place) -> (shape: Shape, valid_utf8: bool) {
	if (place.keeps == nil || place.keeps == .Plain) && plainly_safe(s) && !reads_as_other(s) {
		return .Plain, true
	}
	f := facts_of_text(s, place.ascii)
	if f.invalid {
		return .Double, false
	}
	if style, kept := place.keeps.?; kept {
		switch style {
		case .Plain:
			if !f.escapes && !f.line_ends && !f.tab && plain_fits(s, place.flow) && (place.key || place.tagged || classify(transmute([]u8)s) == .Text) {
				return .Plain, true
			}
		case .Single:
			if !f.escapes && !f.line_ends {
				return .Single, true
			}
			return .Double, true
		case .Double:
			return .Double, true
		case .Block:
			if place.folded && block_fits(s, f, place) {
				return .Folded, true
			}
			if f.line_ends && block_fits(s, f, place) {
				return .Literal, true
			}
		}
	}
	switch {
	case len(s) == 0:
		return .Double, true
	case !f.escapes && !f.line_ends && !f.tab && plain_fits(s, place.flow) && (place.tagged || !reads_as_other(s)):
		return .Plain, true
	case f.line_ends && block_fits(s, f, place):
		return .Literal, true
	case !f.escapes && !f.line_ends:
		return .Single, true
	}
	return .Double, true
}

@(private)
put_single :: proc(out: ^write.Out, s: string) {
	write.put_byte(out, '\'')
	run := 0
	for i in 0 ..< len(s) {
		if s[i] == '\'' {
			put_str(out, s[run:i + 1])
			write.put_byte(out, '\'')
			run = i + 1
		}
	}
	put_str(out, s[run:])
	write.put_byte(out, '\'')
}

@(private)
put_double :: proc(out: ^write.Out, s: string, ascii: bool) {
	write.put_byte(out, '"')
	run := 0
	for i := 0; i < len(s); {
		c := s[i]
		escape: string
		width, digits, code := 1, 0, u32(c)
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
			escape, digits = `\x`, 2
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
				escape, digits, code = `\U`, 8, u32(r)
			case r > 0xff:
				escape, digits, code = `\u`, 4, u32(r)
			case:
				escape, digits, code = `\x`, 2, u32(r)
			}
		}
		put_str(out, s[run:i])
		put_hex_escape(out, escape, code, digits)
		i += width
		run = i
	}
	put_str(out, s[run:])
	write.put_byte(out, '"')
}

@(private)
put_scalar :: proc(out: ^write.Out, s: string, shape: Shape, ascii: bool) {
	switch shape {
	case .Plain, .Literal, .Folded:
		put_str(out, s)
	case .Single:
		put_single(out, s)
	case .Double:
		put_double(out, s, ascii)
	}
}

@(private)
put_block :: proc(out: ^write.Out, s: string, shape: Shape, ind: int) {
	body := s
	for len(body) > 0 && body[len(body) - 1] == '\n' {
		body = body[:len(body) - 1]
	}
	ends := len(s) - len(body)
	write.put_byte(out, '>' if shape == .Folded else '|')
	switch {
	case ends == 0:
		write.put_byte(out, '-')
	case ends > 1:
		write.put_byte(out, '+')
	}
	write.put_byte(out, '\n')
	rest := body
	spaced := true
	for {
		line := rest
		cut := -1
		for b, k in transmute([]u8)rest {
			if b == '\n' {
				cut = k
				break
			}
		}
		if cut >= 0 {
			line = rest[:cut]
		}
		if len(line) > 0 {
			if shape == .Folded {
				if !spaced && line[0] != ' ' && line[0] != '\t' {
					write.put_byte(out, '\n')
				}
				spaced = line[0] == ' ' || line[0] == '\t'
			}
			put_run(out, ind, ' ')
			put_str(out, line)
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
