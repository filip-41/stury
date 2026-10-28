package json

// A value written token by token by a caller that walks values of its own (the command line's), laid out as
// `marshal` lays out a document: pretty, a line break before each entry and the close, and a JSONC value's comments
// where they are attached (encode/jsonc.odin places them). With `colors`, each token is painted as jq paints it.
//
// The caller writes one value: a scalar by `write_token`, `write_number`, `write_float` or `write_string`; a
// container by `write_open`, then for each entry `write_element` (and, in an object, `write_key`) and the entry's
// value, then `write_close`. Entries are written in the order given: the caller orders keys. `write_raw` lays out
// JSON text already in the writer's spelling. Each procedure returns `.Out_Of_Memory` when `out` cannot grow.

import "base:intrinsics"
import "core:bytes"
import "core:math"
import "core:simd"
import enc "encode"

// jq's colours, as terminal escape sequences, in its order: null, false, true, numbers, strings, arrays, objects,
// keys. A kind's colour is `Colors[kind]`.
Colors :: [8]string

// Where a value goes and how it is spelled and laid out. `depth` is the count of containers open around the next
// token: the indent of the next line break.
Writer :: struct {
	out:         ^[dynamic]byte,
	pretty:      bool,
	indent:      int, // pretty: N spaces per level, 0 line breaks only, -1 a tab per level
	ascii:       bool, // each character past U+007F, in strings, keys and comments, as `\u` escapes
	jq_spelling: bool, // a number literal as decNumber prints it, a computed one as jq's dtoa, DEL as `\u007f`
	colors:      ^Colors, // nil for none
	src:         []byte, // the text the comments passed to the writer are spans of
	depth:       int,
}

@(private = "file")
KEY_COLOR :: 7

@(private = "file")
paint :: #force_inline proc(w: ^Writer, color: int) -> Marshal_Error_Kind {
	if w.colors != nil {
		return enc.put_bytes(w.out, w.colors[color])
	}
	return .None
}

@(private = "file")
unpaint :: #force_inline proc(w: ^Writer) -> Marshal_Error_Kind {
	if w.colors != nil {
		return enc.put_bytes(w.out, "\e[0m")
	}
	return .None
}

// `text` as it is, in the colour of `kind`: `null`, `false`, `true`, or a token the caller has spelled.
write_token :: #force_inline proc(w: ^Writer, kind: Kind, text: string) -> Marshal_Error_Kind {
	paint(w, int(kind)) or_return
	enc.put_bytes(w.out, text) or_return
	return unpaint(w)
}

// The JSON number token `lit`: under `jq_spelling` as decNumber prints it (`1e2` is `1E+2`) or, past its range, as
// the double it reads as; otherwise as it is.
write_number :: proc(w: ^Writer, lit: string) -> Marshal_Error_Kind {
	paint(w, int(Kind.Number)) or_return
	if w.jq_spelling && !enc.plain_literal(lit) {
		// The written form is at most a few bytes longer than the literal, or a double's 40: room first, so its
		// appends cannot be refused.
		if enc.put_room(w.out, len(w.out), len(lit) + 64) == nil {
			return .Out_Of_Memory
		}
		enc.put_jq_literal(w.out, lit)
	} else {
		enc.put_bytes(w.out, lit) or_return
	}
	return unpaint(w)
}

// A computed number: under `jq_spelling` as jq's dtoa lays out its shortest digits, an infinity as the largest
// finite number of its sign and a NaN as `null` painted inside a number's colour; otherwise JSON's shortest
// digits, and `.Non_Finite` for an infinity or a NaN.
write_float :: proc(w: ^Writer, f: f64) -> Marshal_Error_Kind {
	if !w.jq_spelling {
		paint(w, int(Kind.Number)) or_return
		enc.put_f64(w.out, f) or_return
		return unpaint(w)
	}
	paint(w, int(Kind.Number)) or_return
	if math.is_nan(f) {
		write_token(w, .Null, "null") or_return
	} else {
		if enc.put_room(w.out, len(w.out), 64) == nil {
			return .Out_Of_Memory
		}
		enc.put_jq_double(w.out, f)
	}
	return unpaint(w)
}

// `s` as a JSON string. `.Bad_Utf8`, with nothing written, when `s` is not UTF-8.
write_string :: #force_inline proc(w: ^Writer, s: string) -> Marshal_Error_Kind {
	mark := len(w.out)
	paint(w, int(Kind.String)) or_return
	spell_string(w, s, mark) or_return
	return unpaint(w)
}

// `s` quoted and escaped, then rewritten to ASCII when the writer is. On a refusal `out` goes back to `mark`.
@(private = "file")
spell_string :: #force_inline proc(w: ^Writer, s: string, mark: int) -> Marshal_Error_Kind {
	at := len(w.out)
	err := enc.put_string_escaping_del(w.out, s) if w.jq_spelling else enc.put_string(w.out, s)
	if err == .None && w.ascii {
		err = enc.reescape_tail(w.out, at, enc.reescape_of({ascii_only = true}))
	}
	if err != .None {
		resize(w.out, mark)
	}
	return err
}

// A row writer's member at the write cursor `at` of `out` (see `put_room`): `lead` (at least 4 bytes, spelled
// already: a comma, key and colon) then `s` as `write_string` writes it in jq's spelling, `null` for nil. `s` is
// UTF-8 its reader has judged. Returns the cursor past it; the length of `out` is the caller's to set.
write_led_string :: proc(out: ^[dynamic]byte, at: int, lead: string, s: Maybe(string)) -> int {
	text, present := s.?
	if !present {
		p := enc.put_room(out, at, len(lead) + 4)
		enc.copy_lead(p, raw_data(lead), len(lead))
		intrinsics.unaligned_store((^u32)(&p[len(lead)]), 0x6c6c756e) // "null"
		return at + len(lead) + 4
	}
	end, _ := enc.spell_led_string(out, at, raw_data(lead), len(lead), text, false, true)
	return end
}

// The open of an array or object, painted in its kind's colour, which the first entry or the close resets.
write_open :: #force_inline proc(w: ^Writer, kind: Kind) -> Marshal_Error_Kind {
	paint(w, int(kind)) or_return
	w.depth += 1
	return enc.put_byte(w.out, '[' if kind == .Array else '{')
}

// Before entry `i` of the container open innermost, of `kind`: a comma after entry `i - 1`, followed by that
// entry's trailing comments `prev`, then the line break, then entry `i`'s leading comments `own`.
write_element :: #force_inline proc(w: ^Writer, kind: Kind, i: int, prev, own: []Fact) -> Marshal_Error_Kind {
	if i > 0 {
		paint(w, int(kind)) or_return
		enc.put_byte(w.out, ',') or_return
	}
	unpaint(w) or_return
	if i > 0 {
		write_comments(w, prev, .Trail) or_return
	}
	write_newline(w) or_return
	return write_comments(w, own, .Lead)
}

// An object entry's key, after its `write_element`, then its colon and the entry's comments `own` that sit
// between key and value. `.Bad_Utf8`, with nothing written, when `key` is not UTF-8.
write_key :: #force_inline proc(w: ^Writer, key: string, own: []Fact) -> Marshal_Error_Kind {
	mark := len(w.out)
	paint(w, KEY_COLOR) or_return
	spell_string(w, key, mark) or_return
	unpaint(w) or_return
	return key_tail(w, own)
}

// What follows a key: its colon in its object's colour, a space when pretty, and the entry's inline comments.
@(private)
key_tail :: #force_inline proc(w: ^Writer, own: []Fact) -> Marshal_Error_Kind {
	paint(w, int(Kind.Object)) or_return
	enc.put_byte(w.out, ':') or_return
	unpaint(w) or_return
	if w.pretty {
		enc.put_byte(w.out, ' ') or_return
	}
	return write_comments(w, own, .Inline)
}

// The close of the container open innermost, of `kind`, after its `count` entries: the trailing comments `last`
// of its last entry, its own comments `own` after its entries, a line break unless it is empty with no comment,
// and its bracket.
write_close :: proc(w: ^Writer, kind: Kind, count: int, last, own: []Fact) -> Marshal_Error_Kind {
	if count > 0 {
		write_comments(w, last, .Trail) or_return
	}
	feet := false
	if len(own) > 0 {
		cl := comment_layout(w)
		feet = enc.put_feet(w.out, &cl, own, w.depth - 1) or_return
	}
	w.depth -= 1
	if count > 0 {
		write_newline(w) or_return
		paint(w, int(kind)) or_return
	} else if feet {
		write_newline(w) or_return
	}
	enc.put_byte(w.out, ']' if kind == .Array else '}') or_return
	return unpaint(w)
}

// The comments of `own` at `place`: `.Lead` before an entry (and, at the `root` of the output, `.Inline` too),
// `.Inline` between a key and its value, `.Trail` after an entry and its comma, `.Foot` after the last entry of
// the container open innermost. A line comment that ends the `root`'s trailing ones ends the output's line.
write_comments :: #force_inline proc(w: ^Writer, own: []Fact, place: Fact_Place, root := false) -> Marshal_Error_Kind {
	if len(own) == 0 {
		return .None
	}
	return put_comments(w, own, place, root)
}

@(private = "file")
put_comments :: proc(w: ^Writer, own: []Fact, place: Fact_Place, root: bool) -> Marshal_Error_Kind {
	cl := comment_layout(w)
	switch place {
	case .Lead:
		return enc.put_leads(w.out, &cl, own, w.depth, root)
	case .Inline:
		return enc.put_inlines(w.out, &cl, own, w.depth)
	case .Trail:
		return enc.put_trails(w.out, &cl, own, w.depth, root)
	case .Foot:
		_, err := enc.put_feet(w.out, &cl, own, w.depth - 1)
		return err
	}
	return .None
}

@(private = "file")
comment_layout :: proc(w: ^Writer) -> enc.Comment_Layout {
	ind: enc.Indent
	switch {
	case w.indent < 0:
		ind = enc.indent_of({})
	case w.indent == 0:
		ind = {head = {0 = '\n'}}
	case:
		ind = enc.indent_of({indent = u8(w.indent)})
	}
	return {src = w.src, pretty = w.pretty, indent = ind, ascii = w.ascii}
}

// A line break and the indent for `depth` levels, when pretty.
write_newline :: #force_inline proc(w: ^Writer) -> Marshal_Error_Kind {
	if !w.pretty {
		return .None
	}
	return put_newline(w)
}

@(private = "file")
put_newline :: proc(w: ^Writer) -> Marshal_Error_Kind {
	SPACES :: "\n                                                                "
	TABS :: "\n\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t"
	pad, n := SPACES, w.depth * w.indent
	if w.indent < 0 {
		pad, n = TABS, w.depth
	}
	// The pad's newline goes with its first run.
	k := min(n, len(pad) - 1)
	enc.put_bytes(w.out, pad[:k + 1]) or_return
	for n -= k; n > 0; n -= k {
		k = min(n, len(pad) - 1)
		enc.put_bytes(w.out, pad[1:k + 1]) or_return
	}
	return .None
}

// Well-formed JSON text of an array or object laid out at `w.depth` as the writer lays out the value it reads as,
// when that is its own spelling with only the whitespace changed: no escape or DEL, no object that repeats a key
// (`unique`: the caller knows none does) and, under `jq_spelling`, no number decNumber respells. Otherwise false
// with `out` as it was, as always with colours. With `items`, `text` is the entries of an array open at `w.depth`,
// without its brackets.
write_raw :: proc(w: ^Writer, text: []byte, items := false, unique := false) -> bool {
	if w.colors != nil {
		return false
	}
	numbers := may_respell(text)
	if numbers && (bytes.index_byte(text, '\\') >= 0 || bytes.index_byte(text, 0x7f) >= 0) {
		return false
	}
	mark, base := len(w.out), w.depth
	ok := raw_walk(w, text, numbers && w.jq_spelling, items, unique) == .None
	w.depth = base
	if !ok {
		resize(w.out, mark)
	}
	return ok
}

// The deepest nesting, and the most keys open at once, `raw_walk` follows.
@(private = "file")
RAW_DEPTH :: 64
@(private = "file")
RAW_KEYS :: 128

// `write_raw`'s layout of `text`, `.Bad_Raw` at the first byte it cannot keep: a repeated key (each key is compared with
// its object's earlier ones; objects past RAW_KEYS answer no), when `numbers` a literal decNumber respells, or text
// past RAW_DEPTH.
@(private = "file")
raw_walk :: proc(w: ^Writer, text: []byte, numbers: bool, items: bool, unique: bool) -> Marshal_Error_Kind #no_bounds_check {
	// Where each open container's keys start in `keys`, -1 for an array.
	opened: [RAW_DEPTH]int = ---
	keys: [RAW_KEYS]string = ---
	base := w.depth
	depth, n := 0, 0
	if items {
		opened[0], depth = -1, 1
	}
	key_next := false
	for i := 0; i < len(text); i += 1 {
		switch c := text[i]; c {
		case ' ', '\t', '\n', '\r':
		case '"':
			// With no escape, the next quote ends the string.
			end := i + 1 + bytes.index_byte(text[i + 1:], '"')
			if key_next {
				if !unique {
					key := string(text[i + 1:end])
					for k in keys[opened[depth - 1]:n] {
						if len(k) == len(key) && k == key {
							return .Bad_Raw
						}
					}
					if n == RAW_KEYS {
						return .Bad_Raw
					}
					keys[n] = key
					n += 1
				}
				key_next = false
			}
			enc.put_bytes(w.out, string(text[i:end + 1])) or_return
			i = end
		case '{', '[':
			if depth == RAW_DEPTH {
				return .Bad_Raw
			}
			j := i + 1
			for is_json_space(text[j]) {
				j += 1
			}
			if text[j] == '}' || text[j] == ']' {
				enc.put_byte(w.out, c) or_return
				enc.put_byte(w.out, text[j]) or_return
				i = j
				break
			}
			enc.put_byte(w.out, c) or_return
			depth += 1
			w.depth = base + depth
			write_newline(w) or_return
			key_next = c == '{'
			opened[depth - 1] = n if key_next else -1
		case '}', ']':
			depth -= 1
			if opened[depth] >= 0 {
				n = opened[depth]
			}
			w.depth = base + depth
			write_newline(w) or_return
			enc.put_byte(w.out, c) or_return
		case ',':
			key_next = opened[depth - 1] >= 0
			enc.put_byte(w.out, ',') or_return
			w.depth = base + depth
			write_newline(w) or_return
		case ':':
			enc.put_byte(w.out, ':') or_return
			if w.pretty {
				enc.put_byte(w.out, ' ') or_return
			}
		case:
			// A number or literal, up to the byte that ends it.
			end := i + 1
			for end < len(text) && !is_json_space(text[end]) && text[end] != ',' && text[end] != '}' && text[end] != ']' {
				end += 1
			}
			if numbers && c != 't' && c != 'f' && c != 'n' && !enc.plain_literal(string(text[i:end])) {
				return .Bad_Raw
			}
			enc.put_bytes(w.out, string(text[i:end])) or_return
			i = end - 1
		}
	}
	return .None
}

@(private = "file")
is_json_space :: #force_inline proc "contextless" (c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// Whether `text` has a byte `raw_walk` must look at: a backslash or DEL, an `e` or `E` after a digit and before a
// byte from `+` to `9` (a sign or digit), or a `.` between zeros, one of which every number `enc.plain_literal`
// refuses has. Strings may hold false alarms.
@(private = "file")
may_respell :: proc(text: []byte) -> bool #no_bounds_check {
	n := len(text)
	// A JSON text's first and last bytes are none of these, so a last block may overlap the one before.
	if n < 18 {
		for i in 1 ..< n - 1 {
			c, prev, next := text[i], text[i - 1], text[i + 1]
			if c == '\\' || c == 0x7f || c | 0x20 == 'e' && prev - '0' < 10 && next - '+' < 15 || c == '.' && prev == '0' && next == '0' {
				return true
			}
		}
		return false
	}
	i := 1
	for ; i + 65 <= n; i += 64 {
		if simd.reduce_or(odd_lanes(text, i) | odd_lanes(text, i + 16) | odd_lanes(text, i + 32) | odd_lanes(text, i + 48)) != 0 {
			return true
		}
	}
	for ; i + 17 <= n; i += 16 {
		if simd.reduce_or(odd_lanes(text, i)) != 0 {
			return true
		}
	}
	return simd.reduce_or(odd_lanes(text, n - 17)) != 0
}

// The lanes of the 16 bytes at `i` that `may_respell` looks for. `text` has a byte before them and after.
@(private = "file")
odd_lanes :: #force_inline proc "contextless" (text: []byte, i: int) -> #simd[16]u8 #no_bounds_check {
	V :: #simd[16]u8
	v := intrinsics.unaligned_load((^V)(&text[i]))
	prev := intrinsics.unaligned_load((^V)(&text[i - 1]))
	next := intrinsics.unaligned_load((^V)(&text[i + 1]))
	odd := simd.lanes_eq(v, V('\\')) | simd.lanes_eq(v, V(0x7f))
	odd |= simd.lanes_eq(v | V(0x20), V('e')) & simd.lanes_lt(prev - V('0'), V(10)) & simd.lanes_lt(next - V('+'), V(15))
	return odd | simd.lanes_eq(v, V('.')) & simd.lanes_eq(prev, V('0')) & simd.lanes_eq(next, V('0'))
}
