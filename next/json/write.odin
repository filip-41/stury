package json

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// JSON's writer: the layout of a document's values as a JSON, JSONC or JSON5 text, and the spelling of its scalars.
// A string of a JSON, JSONC or JSON5 text is written as it was, escapes included, and respelled only where the target
// cannot hold it: a JSON5 string's own quote, escape or raw control byte in JSON, or a byte past ASCII under `ascii`. A
// string of any other format is written by its text with the fewest escapes. A number is written as written when its
// text is one of the target's, and a key of any scalar kind as a string of its text, as the readers name it.

Write_Options :: write.Options
Write_Error :: write.Error
Token_Kind :: write.Token_Kind
Record_Framing :: write.Record_Framing
Refused :: write.Refused
Refusal :: write.Refusal

// Writes value `opts.node` of `doc`, a document of any format, as a text of `spec`, in a buffer from `allocator` that
// the caller owns. Returns the kinds of the facts `doc` holds that the text does not: every fact for `.Json`, and the
// facts other than comments, and comments with no place, for `.Jsonc` and `.Json5`. A value JSON cannot spell is
// `Refused` with its node, and no text: a non-finite number, a key that is a container, a number with no decimal text,
// a container a path read kept part of. A byte string is a string of its payload's base64, and a number of a binary
// format is written by its value in decimal, exactly.
write :: proc(doc: ^tape.Document, spec := Spec.Json, opts := Write_Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: Write_Error) {
	return write.to_buffer(doc, u8(spec), opts, allocator, write_out)
}

// `write` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. A sink with no procedure is
// `Bad_Option{"sink"}`. On a refusal or a failed sink the sink may hold a prefix of the text.
write_to :: proc(sink: io.Writer, doc: ^tape.Document, spec := Spec.Json, opts := Write_Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: Write_Error) {
	return write.to_sink(sink, doc, u8(spec), opts, allocator, write_out)
}

@(private)
write_out :: proc(out: ^write.Out, doc: ^tape.Document, spec: u8, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	if spec > u8(max(Spec)) {
		return {}, tape.Bad_Option{"spec"}
	}
	if opts.format != nil {
		return {}, tape.Bad_Option{"format"}
	}
	if opts.grow_header || len(opts.header) > 0 {
		return {}, tape.Bad_Option{"header" if len(opts.header) > 0 else "options"}
	}
	if opts.framing == .Lines && !write.compact(opts) {
		return {}, tape.Bad_Option{"framing"}
	}
	if opts.framing == .Seq {
		write.put_byte(out, RECORD_SEPARATOR)
	}
	dropped, err := write_spec(out, doc, Spec(spec), opts, allocator)
	if opts.framing != .None && err == nil {
		write.put_byte(out, '\n')
	}
	return dropped, err
}

@(private)
write_spec :: proc(out: ^write.Out, doc: ^tape.Document, spec: Spec, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	switch spec {
	case .Json:
		return write_as(out, doc, .Json, opts, allocator)
	case .Jsonc:
		return write_as(out, doc, .Jsonc, opts, allocator)
	case .Json5:
	}
	return write_as(out, doc, .Json5, opts, allocator)
}

// The byte that starts each text of an RFC 7464 sequence.
@(private)
RECORD_SEPARATOR :: 0x1E

// What a JSON write knows of its document and layout, and where its comments stand.
@(private)
Layout :: struct {
	width:      int, // bytes of indent a level
	fill:       u64, // eight bytes of indent
	// The document was read as JSON or JSONC and holds its text whole, so a string's span with its quotes is its JSON
	// text, unless it is `SPELLING_LAX`.
	copy_text:  bool,
	// The document was read as JSON5 and holds its text whole, whose strings and keys keep their own quotes, or none.
	json5:      bool,
	// A number of kind 0 is an RFC 8259 number as written: a JSON or delimited document's.
	numbers:    bool,
	// With comments: a value ended on the line being written, so a comment written now reads as its inline one.
	line_value: bool,
	pending:    []tape.Fact, // the facts of the value written last, whose inline comments follow its comma
	root_facts: []tape.Fact, // the root's facts, whose feet after its text follow it
	// With comments and `PRETTY`: the last comment written was a line comment, which a line end must follow.
	line_comment: bool,
	wrote:      bool, // a byte is written, so a value starts its own line
	ascii:      bool, // `Options.ascii`
}

// `write_rows` for the text the document holds: its own quotes when it is JSON5, the ASCII bytes when `ascii`.
@(private)
write_rows_of_text :: #force_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, $PRETTY: bool, $WIDTH: int, facts: bool, spec: Spec) {
	switch {
	case l.json5:
		write_rows(out, w, l, PRETTY, WIDTH, .Json5, facts, spec)
	case l.ascii:
		write_rows(out, w, l, PRETTY, WIDTH, .Ascii, facts, spec)
	case:
		write_rows(out, w, l, PRETTY, WIDTH, .Json, facts, spec)
	}
}

@(private)
write_as :: #force_no_inline proc(out: ^write.Out, doc: ^tape.Document, $T: Spec, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	// NDJSON lines cannot hold raw line breaks, so comments are dropped cleanly under `.Lines`.
	holds := tape.Facts{} if opts.framing == .Lines else FORMATS[T].facts
	// Bypass `write.Tree` stack zeroing when a strict whole JSON document routes to `write_dense`.
	if doc.present & holds == {} && doc.ext == nil && len(doc.nodes) > 0 && doc.nodes[0].role == .Value {
		if dense := dense_route(doc, opts); dense != nil {
			write_dense(out, dense)
			return doc.present, out.err
		}
	}
	return write_walked(out, doc, T, opts, holds, allocator)
}

@(private)
write_walked :: #force_no_inline proc(out: ^write.Out, doc: ^tape.Document, $T: Spec, opts: Write_Options, holds: tape.Facts, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	w: write.Tree
	if e := write.tree_start(&w, doc, opts, holds, allocator); e != nil {
		return {}, e
	}
	l := Layout{width = int(opts.indent), fill = 0x2020202020202020}
	if opts.tab {
		l.width, l.fill = 1, 0x0909090909090909
	}
	whole := .Held not_in doc.flags
	l.ascii = opts.ascii
	l.copy_text = whole && (doc.format == &FORMATS[.Json] || doc.format == &FORMATS[.Jsonc])
	l.json5 = whole && doc.format == &FORMATS[.Json5]
	l.numbers = doc.format == &FORMATS[.Json] || doc.format == &FORMATS[.Jsonc] || doc.format == &FORMATS[.Json5] || doc.format.options == .Dsv
	facts, tables := write.tree_facts(&w), write.tree_tables(&w)
	if !tables && (l.copy_text || l.json5 && T == .Json5 && !l.ascii) && !opts.sort_keys && .Tolerated not_in doc.flags {
		switch {
		case write.compact(opts):
			write_rows_of_text(out, &w, &l, false, 0, facts, T)
		case l.width == 2:
			write_rows_of_text(out, &w, &l, true, 2, facts, T)
		case:
			write_rows_of_text(out, &w, &l, true, 0, facts, T)
		}
	} else if write.compact(opts) {
		write_tree_for(out, &w, &l, T, facts, tables, false)
	} else {
		write_tree_for(out, &w, &l, T, facts, tables, true)
	}
	dropped := write.tree_end(&w)
	if w.err == nil {
		w.err = out.err
	}
	return dropped, w.err
}

// `write_tree` with `facts` and `tables` as constants.
@(private)
write_tree_for :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, $T: Spec, facts, tables: bool, $PRETTY: bool) {
	switch {
	case !facts && !tables:
		write_tree(out, w, l, T, false, false, PRETTY)
	case !facts:
		write_tree(out, w, l, T, false, true, PRETTY)
	case !tables:
		write_tree(out, w, l, T, true, false, PRETTY)
	case:
		write_tree(out, w, l, T, true, true, PRETTY)
	}
}

// The layout loop: each step of the walk as JSON's punctuation and the step's scalar, one value or member a line with
// `PRETTY`, and with `FACTS` the comments on each value where a read takes them back.
@(private)
write_tree :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, $T: Spec, $FACTS, $TABLES, $PRETTY: bool) {
	for {
		s := write.tree_next(w, FACTS, TABLES)
		switch s.kind {
		case .Scalar, .Open:
			if !step_value(out, w, l, s, T, FACTS, TABLES, PRETTY) {
				return
			}
		case .Close:
			step_close(out, w, l, s, ']' if w.nodes[s.node].kind == .Array else '}', T, FACTS, PRETTY)
		case .Done:
			when FACTS {
				if w.err == nil {
					end_comments(out, w, l, T, PRETTY)
				}
			}
			return
		}
	}
}

// The scalar or container open of step `s`, with its comma, its key and, with `FACTS`, the comments around them. False
// with `w.err` set for a scalar JSON cannot spell.
@(private)
step_value :: #force_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, s: write.Step, $T: Spec, $FACTS, $TABLES, $PRETTY: bool) -> bool {
	if !s.first {
		write.put_byte(out, ',')
	}
	when FACTS {
		lead_comments(out, w, l, s, T, PRETTY)
	}
	when PRETTY {
		if s.depth > 0 || FACTS && l.wrote {
			line_indent(out, l, s.depth)
		}
	}
	when TABLES {
		if s.cell {
			if !put_cell_key(out, w, l) {
				return false
			}
			put_colon(out, PRETTY)
		}
	}
	if s.key != tape.NO_NODE {
		if !put_key(out, w, l, s.key, T) {
			return false
		}
		put_colon(out, PRETTY)
		when FACTS {
			key_comments(out, w, l, s, T, PRETTY)
		}
	}
	if s.kind == .Scalar {
		if !put_scalar(out, w, l, s.node, T) {
			return false
		}
		when FACTS {
			l.pending, l.line_value = s.facts, true
			if s.depth == 0 {
				l.root_facts = s.facts
			}
		}
	} else {
		write.put_byte(out, bracket_of(w.nodes[s.node].kind))
		when FACTS {
			l.line_value = false
		}
	}
	when FACTS {
		l.wrote = true
	}
	return true
}

// The close `bracket` of the container of step `s`, with, under `FACTS`, the comments before it and its own after.
@(private)
step_close :: #force_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, s: write.Step, bracket: u8, $T: Spec, $FACTS, $PRETTY: bool) {
	when PRETTY {
		feet := false
		when FACTS {
			feet = foot_comments(out, w, l, s, T, PRETTY)
		}
		if !s.first || feet {
			line_indent(out, l, s.depth)
		}
	} else {
		when FACTS {
			foot_comments(out, w, l, s, T, PRETTY)
		}
	}
	write.put_byte(out, bracket)
	when FACTS {
		l.pending, l.line_value = s.facts, true
		if s.depth == 0 {
			l.root_facts = s.facts
		}
	}
}

// A line end and the indent of `depth` levels.
@(private)
line_indent :: #force_inline proc(out: ^write.Out, l: ^Layout, depth: int) #no_bounds_check {
	write.line_indent(out, l.width, l.fill, depth)
}

// The word of each literal's bytes, which `false`'s five take eight bytes of.
@(private)
NULL_TEXT :: u32('n') | u32('u') << 8 | u32('l') << 16 | u32('l') << 24
@(private)
TRUE_TEXT :: u32('t') | u32('r') << 8 | u32('u') << 16 | u32('e') << 24
@(private)
FALSE_TEXT :: u64('f') | u64('a') << 8 | u64('l') << 16 | u64('s') << 24 | u64('e') << 32

// Writes scalar node `at`, false with `w.err` set for one JSON cannot spell.
@(private)
put_scalar :: #force_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, at: tape.Node_Index, $T: Spec) -> bool #no_bounds_check {
	t := w.nodes[at]
	switch t.kind {
	case .Null:
		intrinsics.unaligned_store((^u32)(write.room(out, 4)), NULL_TEXT)
		out.cursor += 4
	case .True:
		intrinsics.unaligned_store((^u32)(write.room(out, 4)), TRUE_TEXT)
		out.cursor += 4
	case .False:
		intrinsics.unaligned_store((^u64)(write.room(out, 8)), FALSE_TEXT)
		out.cursor += 5
	case .Number:
		if l.numbers && (t.spelling & tape.NUMBER_KIND == 0 || T == .Json5 && l.json5) {
			write.put(out, tape.span_bytes(w.doc, t.lo, t.n))
			return true
		}
		return put_number(out, w, at, t, T)
	case .String, .Plain:
		return put_text(out, w, l, at, t, T)
	case .Bytes:
		return put_bytes(out, w, at)
	case .Array, .Object, .End:
		w.err = write.Refused{at, .No_Spelling}
		return false
	}
	return true
}

// Writes byte string node `at` as a string of the base64 of its payload, as a byte string key is written.
@(private, cold)
put_bytes :: #force_no_inline proc(out: ^write.Out, w: ^write.Tree, at: tape.Node_Index) -> bool {
	s := write.bytes_base64(w, at) or_return
	defer delete(s, w.allocator)
	write.put_byte(out, '"')
	write.put(out, transmute([]u8)s)
	write.put_byte(out, '"')
	return true
}

// Writes the string or plain scalar `t` at `at` as a JSON string: the span of a JSON, JSONC or JSON5 text as written,
// where the target holds it, else the text with the fewest escapes.
@(private)
put_text :: #force_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, at: tape.Node_Index, t: tape.Node, $T: Spec) -> bool #no_bounds_check {
	if t.spelling & tape.SPELLING_LAX == 0 && t.kind == .String {
		src := w.doc.src
		// A string of a JSON or JSONC text lies between its quotes, `lo - 1` and `lo + n`, whatever escapes it holds.
		if l.copy_text {
			put_span(out, l, src[t.lo - 1:][:t.n + 2], t.spelling)
			return true
		}
		if l.json5 {
			// The quote bytes on each side of the string, none for a key written bare.
			head, _ := quotes(src, t)
			when T == .Json5 {
				span := src[t.lo - u64(head):][:t.n + 2 * u32(head)]
				// A bare key's `\u` escapes cannot spell a pair past the BMP, so under `ascii` it is quoted.
				if head == 0 && l.ascii && t.spelling & tape.SPELLING_ASCII == 0 && has_astral(span) {
					write.put_byte(out, '"')
					put_ascii_text(out, span)
					write.put_byte(out, '"')
					return true
				}
				put_span(out, l, span, t.spelling)
				return true
			} else {
				if t.spelling & tape.SPELLING_DECODE != 0 || head != 0 && src[t.lo - 1] == '\'' {
					put_json5_as_json(out, l, src[t.lo:][:t.n])
					return true
				}
				if head == 0 {
					// A key written bare holds identifier characters, which a JSON string holds as they are.
					write.put_byte(out, '"')
					put_span(out, l, src[t.lo:][:t.n], t.spelling)
					write.put_byte(out, '"')
					return true
				}
			}
		}
	}
	return put_text_of(out, w, l, at)
}

// Writes `span`, the text of a string with its quotes, as it is, or under `ascii` with each character past ASCII as a
// `\u` escape, of which a text `spelling` marks ASCII has none.
@(private)
put_span :: #force_inline proc(out: ^write.Out, l: ^Layout, span: []u8, spelling: u16) {
	if l.ascii && spelling & tape.SPELLING_ASCII == 0 {
		put_ascii_text(out, span)
	} else {
		write.put(out, span)
	}
}

// Writes key node `at` as a JSON string of its text, or under JSON5 a JSON5 key's span as written. A key that is a
// container has no text.
@(private)
put_key :: #force_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, at: tape.Node_Index, $T: Spec) -> bool #no_bounds_check {
	t := w.nodes[at]
	if t.kind == .String || t.kind == .Plain {
		return put_text(out, w, l, at, t, T)
	}
	if t.kind > .Plain {
		w.err = write.Refused{at, .No_Spelling}
		return false
	}
	return put_text_of(out, w, l, at)
}

// Grows `w.scratch` to at least `room` bytes, matching `write.scratch_grow`.
@(private, cold)
grow_tree_scratch :: #force_no_inline proc(w: ^write.Tree, room: int) -> bool {
	size := max(room, 2 * len(w.scratch), 256)
	raw, err := runtime.mem_alloc_non_zeroed(size, 1, w.allocator)
	if err == nil && (raw_data(raw) == nil || len(raw) < size) {
		err = .Out_Of_Memory
	}
	if err != nil {
		w.err = err
		return false
	}
	if w.scratch != nil {
		delete(w.scratch, w.allocator)
	}
	w.scratch = raw
	return true
}

// Writes the text of scalar node `at` as a JSON string, false with `w.err` set when it cannot be read.
// Invariant: `at` is a valid node index and its decoded or raw bytes lie in `w.doc` / `w.scratch`.
@(private)
put_text_of :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, at: tape.Node_Index) -> bool #no_bounds_check {
	doc := w.doc
	t := doc.nodes[at]
	if u8(t.kind) - u8(tape.Kind.String) <= 1 && t.spelling & tape.SPELLING_DECODE == 0 {
		put_string(out, l, string(tape.span_bytes(doc, t.lo, t.n)))
		return true
	}
	room := tape.text_room(doc, at)
	if room == 0 {
		put_string(out, l, string(tape.span_bytes(doc, t.lo, t.n)))
		return true
	}
	if len(w.scratch) < room && !grow_tree_scratch(w, room) {
		return false
	}
	s, ok := tape.node_text(doc, at, w.scratch)
	if ok {
		put_string(out, l, s)
	}
	return ok
}

// Writes the key of a table's row's cell, which has no node, as a JSON string of its text.
@(private)
put_cell_key :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout) -> bool {
	s, ok := write.text_of_token(w, w.cell)
	if ok {
		put_string(out, l, s)
	}
	return ok
}

// Writes the colon after a key, with a space after it under `PRETTY`.
@(private)
put_colon :: #force_inline proc(out: ^write.Out, $PRETTY: bool) {
	p := write.room(out, 2)
	p[0], p[1] = ':', ' '
	out.cursor += 2 if PRETTY else 1
}

// The open bracket of a container of kind `kind`, its close two bytes past it.
@(private)
bracket_of :: #force_inline proc "contextless" (kind: tape.Kind) -> u8 {
	return '[' | u8(kind == .Object) << 5
}

// Writes `s` as a JSON string, under `ascii` with each character past ASCII escaped.
@(private)
put_string :: #force_inline proc(out: ^write.Out, l: ^Layout, s: string) {
	if l.ascii {
		put_ascii(out, s, true)
	} else {
		put_escaped(out, s)
	}
}

// Writes `s` with each character past ASCII as a `\u` escape, a surrogate pair past U+FFFF, between quotes and with
// the escapes of `put_escaped` when `quoted`, else as it is, as a comment's body.
@(private)
put_ascii :: proc(out: ^write.Out, s: string, quoted: bool) {
	if quoted {
		write.put_byte(out, '"')
	}
	for r in s {
		p := write.room(out, 12)
		n := 1
		switch {
		case r >= 0x80:
			n = rune_units(p, r)
		case quoted && ESCAPE_OF[u8(r)] != 0:
			// Previous arm handles `r >= 0x80` (including `utf8.RUNE_ERROR`), so here `0 <= r < 0x80`.
			n = escape_into(p, u8(r))
		case:
			p[0] = u8(r)
		}
		out.cursor += n
	}
	if quoted {
		write.put_byte(out, '"')
	}
}

// Writes `s`, a string of a JSON or JSON5 text with its quotes, with each character past ASCII as a `\u` escape and
// every other byte, escapes included, as it is. `s` is well formed UTF-8.
@(private)
put_ascii_text :: proc(out: ^write.Out, s: []u8) #no_bounds_check {
	run, i := 0, 0
	for i < len(s) {
		for i + 8 <= len(s) && intrinsics.unaligned_load((^u64)(raw_data(s[i:]))) & 0x8080808080808080 == 0 {
			i += 8
		}
		if i >= len(s) {
			break
		}
		if s[i] < 0x80 {
			i += 1
			continue
		}
		// An odd run of backslashes before the character escapes it: JSON5 reads it as the character, and as nothing for a
		// line separator, which JSON has no escape for.
		end, back := i, 0
		for end - back > run && s[end - back - 1] == '\\' {
			back += 1
		}
		if back & 1 == 1 {
			end -= 1
			if is_line_separator(s[i:]) {
				i += 3
			}
		}
		write.put(out, s[run:end])
		if i < len(s) && s[i] >= 0x80 {
			i = put_ascii_burst(out, s, i)
		}
		run = i
	}
	write.put(out, s[run:])
}

// Whether `s` holds a character past the BMP, which UTF-8 leads with a byte from 0xF0.
@(private)
has_astral :: proc "contextless" (s: []u8) -> bool {
	for c in s {
		if c >= 0xF0 {
			return true
		}
	}
	return false
}

// Whether `s` holds U+2028 or U+2029.
@(private)
holds_line_separator :: proc "contextless" (s: []u8) -> bool {
	for c, i in s {
		if c == 0xE2 && is_line_separator(s[i:]) {
			return true
		}
	}
	return false
}

// Whether `s` starts with U+2028 or U+2029.
@(private)
is_line_separator :: #force_inline proc "contextless" (s: []u8) -> bool {
	return len(s) >= 3 && s[0] == 0xE2 && s[1] == 0x80 && s[2] | 1 == 0xA9
}

// Writes the characters of `s` from `at`, which holds one past ASCII, as `\u` escapes, and each ASCII byte that stands
// between two characters past ASCII as it is, in the room of the whole burst. Returns where it stopped: at the end, or
// at an ASCII byte that another follows. `s` is well formed UTF-8.
@(private)
put_ascii_burst :: #force_no_inline proc(out: ^write.Out, s: []u8, at: int) -> int #no_bounds_check {
	// A byte of `s` takes at most three of the output, and a character that starts before `end` ends at most three
	// bytes past it.
	end := min(len(s), at + write.ROOM_MAX / 3 - 4)
	p := write.room(out, 3 * (end - at + 4))
	o, i := 0, at
	for i < end {
		c := s[i]
		switch {
		case c < 0x80:
			if i + 1 >= len(s) || s[i + 1] < 0x80 {
				out.cursor += o
				return i
			}
			// A backslash escapes the character after it, which is read as itself, or as nothing for a line separator.
			if c != '\\' {
				p[o] = c
				o += 1
			}
			i += 1
			if c == '\\' && is_line_separator(s[i:]) {
				i += 3
			}
		case c < 0xE0:
			o += u_escape(p[o:], u32(c & 0x1F) << 6 | u32(s[i + 1] & 0x3F))
			i += 2
		case c < 0xF0:
			o += u_escape(p[o:], u32(c & 0x0F) << 12 | u32(s[i + 1] & 0x3F) << 6 | u32(s[i + 2] & 0x3F))
			i += 3
		case:
			o += rune_units(p[o:], rune(u32(c & 0x07) << 18 | u32(s[i + 1] & 0x3F) << 12 | u32(s[i + 2] & 0x3F) << 6 | u32(s[i + 3] & 0x3F)))
			i += 4
		}
	}
	out.cursor += o
	return i
}

// Writes `s`, the bytes between the quotes of a JSON5 string, as a JSON string. An escape JSON has is kept as written,
// and one it lacks is spelled by what the reader decodes it to: `\x`, `\v`, `\0`, an escaped character that needs no
// escape, and a line continuation, which stands for nothing. A raw quote of the other kind is escaped, as is a raw
// control byte, and under `ascii` each character past ASCII is a `\u` escape. `s` is well formed.
@(private)
put_json5_as_json :: proc(out: ^write.Out, l: ^Layout, s: []u8) #no_bounds_check {
	write.put_byte(out, '"')
	run, i := 0, 0
	for {
		i = escape_from(s, i, ASCII_BYTES if l.ascii else 0)
		if i >= len(s) {
			break
		}
		write.put(out, s[run:i])
		p := write.room(out, 12)
		n := 0
		switch c := s[i]; {
		case c != '\\':
			if c >= 0x80 {
				r, size := utf8.decode_rune(s[i:])
				n = rune_units(p, r)
				i += size
			} else {
				n = escape_into(p, c)
				i += 1
			}
		case spell.ESCAPED[s[i + 1]] != 0 || s[i + 1] == 'u':
			n = 6 if s[i + 1] == 'u' else 2
			copy(p[:n], s[i:])
			i += n
		case:
			decoded: [2]u8
			w, next := decode5_escape(raw_data(s), u64(i), u64(len(s)), &decoded[0], 0)
			n = put_decoded(p, decoded[:w], l.ascii)
			i = int(next)
		}
		out.cursor += n
		run = i
	}
	write.put(out, s[run:])
	write.put_byte(out, '"')
}

// Writes the character `d` of an escape, as the reader decodes it, at `p` as a JSON string holds it, and returns its
// length: a byte below 0x80 with its escape if it needs one, else its UTF-8, under `ascii` as a `\u` escape.
@(private)
put_decoded :: #force_inline proc "contextless" (p: [^]u8, d: []u8, ascii: bool) -> int #no_bounds_check {
	switch {
	case len(d) == 0:
		return 0
	case len(d) == 1:
		if ESCAPE_OF[d[0]] != 0 {
			return escape_into(p, d[0])
		}
		p[0] = d[0]
		return 1
	case ascii:
		r, _ := utf8.decode_rune(d)
		return rune_units(p, r)
	}
	p[0], p[1] = d[0], d[1]
	return 2
}

// Writes the `\u` escapes of code point `r`, past ASCII, at `p`: a surrogate pair past U+FFFF. Returns their length.
@(private)
rune_units :: #force_inline proc "contextless" (p: [^]u8, r: rune) -> int #no_bounds_check {
	if r >= 0x10000 {
		c := u32(r) - 0x10000
		return u_escape(p, 0xD800 + c >> 10) + u_escape(p[6:], 0xDC00 + c & 0x3FF)
	}
	return u_escape(p, u32(r))
}

// Writes `\u` and the four lowercase hex digits of `unit` at `p` and returns 6.
@(private)
u_escape :: #force_inline proc "contextless" (p: [^]u8, unit: u32) -> int #no_bounds_check {
	p[0], p[1] = '\\', 'u'
	p[2], p[3], p[4], p[5] = HEX_DIGITS[unit >> 12 & 15], HEX_DIGITS[unit >> 8 & 15], HEX_DIGITS[unit >> 4 & 15], HEX_DIGITS[unit & 15]
	return 6
}

// Writes byte `c`, which a JSON string cannot hold as itself, at `p` with its shortest escape, and returns its length.
@(private)
escape_into :: #force_inline proc "contextless" (p: [^]u8, c: u8) -> int #no_bounds_check {
	if e := ESCAPE_OF[c]; e != 'u' {
		p[0], p[1] = '\\', e
		return 2
	}
	return u_escape(p, u32(c))
}

// The escape of each byte a JSON string cannot hold as itself: the letter after the backslash, `u` for `\u00XX`, and 0
// for a byte that stands for itself.
@(private, rodata)
ESCAPE_OF := [256]u8 {
	0x00 ..= 0x07 = 'u',
	'\b' = 'b',
	'\t' = 't',
	'\n' = 'n',
	0x0B = 'u',
	'\f' = 'f',
	'\r' = 'r',
	0x0E ..= 0x1F = 'u',
	'"' = '"',
	'\\' = '\\',
}

@(private, rodata)
HEX_DIGITS := [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

// The high bit of each of eight bytes, which a byte past 0x7F has set.
@(private)
ASCII_BYTES :: u64(0x8080808080808080)

// The first offset from `i` of a byte of `s` that a JSON string cannot hold as itself, a quote, a backslash or a control
// byte, and with `past_ascii` set to `ASCII_BYTES` a byte past 0x7F too, else `len(s)`.
@(private)
escape_from :: #force_inline proc "contextless" (s: []u8, i: int, past_ascii: u64) -> int #no_bounds_check {
	i := i
	// Eight bytes at a time while none needs an escape. A byte past 0x7F never flags unless `past_ascii` says so, and the
	// lowest flagged byte is a byte below 0x20, a quote or a backslash, as a borrow only flags bytes above a true one.
	for i + 8 <= len(s) {
		v := intrinsics.unaligned_load((^u64)(raw_data(s[i:])))
		ONES :: u64(0x0101010101010101)
		quote := v ~ (ONES * '"')
		slash := v ~ (ONES * '\\')
		hit := ((v - ONES * 0x20) | (quote - ONES) | (slash - ONES)) & ~v & ASCII_BYTES | v & past_ascii
		if hit != 0 {
			i += int(intrinsics.count_trailing_zeros(hit) >> 3)
			break
		}
		i += 8
	}
	for i < len(s) && ESCAPE_OF[s[i]] == 0 && (s[i] < 0x80 || past_ascii == 0) {
		i += 1
	}
	return i
}

// Writes `s` as a JSON string: a quote, a backslash and the control bytes escaped, each with its shortest escape, and
// every other byte as itself.
@(private)
put_escaped :: proc(out: ^write.Out, s: string) #no_bounds_check {
	write.put_byte(out, '"')
	b := transmute([]u8)s
	run, i := 0, 0
	for {
		i = escape_from(b, i, 0)
		if i >= len(b) {
			break
		}
		write.put(out, b[run:i])
		out.cursor += escape_into(write.room(out, 6), b[i])
		i += 1
		run = i
	}
	write.put(out, b[run:])
	write.put_byte(out, '"')
}

// Writes a number whose text is not JSON's: a JSON5 number, or one a JSON read took under `.Non_Finite`, in JSON's
// spelling of the same value, any other format's in the RFC 8259 text `write.number_text` gives. Infinity and NaN have
// none, and a JSON5 text writes them as they were read.
@(private, cold)
put_number :: #force_no_inline proc(out: ^write.Out, w: ^write.Tree, at: tape.Node_Index, t: tape.Node, $T: Spec) -> bool {
	json := w.doc.format == &FORMATS[.Json5] || w.doc.format == &FORMATS[.Json] || w.doc.format == &FORMATS[.Jsonc]
	if kind := Number_Spelling(t.spelling & tape.NUMBER_KIND); json && (kind == .Infinity || kind == .Nan) {
		when T == .Json5 {
			write.put(out, tape.span_bytes(w.doc, t.lo, t.n))
			return true
		}
	} else {
		buf: [write.NUMBER_ROOM]u8
		if s, ok := write.number_text(w, at, &buf); ok {
			write.put(out, transmute([]u8)s)
			return true
		}
	}
	if w.err == nil {
		w.err = write.Refused{at, .No_Spelling}
	}
	return false
}

// Before value `s`: the inline comments of the value before it, after its comma, then its own lead comments, each on
// a line of its own.
@(private)
lead_comments :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, s: write.Step, $T: Spec, $PRETTY: bool) {
	inline_comments(out, w, l, T, PRETTY)
	for f in s.facts {
		if f.kind != .Comment || after_key(w, s, f) {
			continue
		}
		when PRETTY {
			if l.wrote {
				line_indent(out, l, s.depth)
			}
		} else {
			if l.line_value {
				write.put_byte(out, '\n')
			}
		}
		l.line_value = false
		put_comment(out, w, l, f, false, T, PRETTY)
		l.wrote = true
	}
}

// Between the key and the value of member `s`: the lead comments of the value that stand after the key in the text,
// each a block comment followed by its value on the line where its body allows.
@(private)
key_comments :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, s: write.Step, $T: Spec, $PRETTY: bool) {
	for f in s.facts {
		if f.kind != .Comment || !after_key(w, s, f) {
			continue
		}
		if put_comment(out, w, l, f, true, T, PRETTY) {
			when PRETTY {
				line_indent(out, l, s.depth)
			}
		} else {
			when PRETTY {
				write.put_byte(out, ' ')
			}
		}
	}
}

// Whether lead comment `f` of member `s` stands after its key in the text.
@(private)
after_key :: #force_inline proc(w: ^write.Tree, s: write.Step, f: tape.Fact) -> bool {
	return s.key != tape.NO_NODE && f.lo > w.nodes[s.key].lo
}

// Whether foot comment `f` of the root container stands after the root's close bracket in the text, so it follows the
// root.
@(private)
after_root :: #force_inline proc(w: ^write.Tree, f: tape.Fact) -> bool {
	doc := w.doc
	return f.node == tape.ROOT && doc.root_close > 0 && doc.root_close <= u64(len(doc.src)) && f.lo >= doc.root_close && doc.src[doc.root_close - 1] | 0x20 == '}'
}

// Before the close of container `s`: the inline comments of its last child, then its foot comments, each on a line of
// its own, but for those of the root that follow it. Returns whether it wrote a foot.
@(private)
foot_comments :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, s: write.Step, $T: Spec, $PRETTY: bool) -> (feet: bool) {
	inline_comments(out, w, l, T, PRETTY)
	for f in s.facts {
		if f.kind != .Comment_Foot || s.depth == 0 && after_root(w, f) {
			continue
		}
		when PRETTY {
			line_indent(out, l, s.depth + 1)
		} else {
			if l.line_value {
				write.put_byte(out, '\n')
			}
		}
		l.line_value = false
		put_comment(out, w, l, f, false, T, PRETTY)
		feet = true
	}
	return
}

// At the end of the text: the inline comments of the root, then the foot comments that follow it, all a scalar root's,
// and a line end after a last line comment.
@(private)
end_comments :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, $T: Spec, $PRETTY: bool) {
	l.line_comment = false
	inline_comments(out, w, l, T, PRETTY)
	for f in l.root_facts {
		if f.kind == .Comment_Foot && (w.nodes[f.node].kind < .Array || after_root(w, f)) {
			when PRETTY {
				write.put_byte(out, '\n')
			} else {
				if l.line_value {
					write.put_byte(out, '\n')
				}
			}
			l.line_value = false
			put_comment(out, w, l, f, false, T, PRETTY)
		}
	}
	when PRETTY {
		if l.line_comment {
			write.put_byte(out, '\n')
		}
	}
}

// The inline comments of the value written last, on its line. A line comment ends the line, so one that another
// follows is written as a block comment where its body allows.
// Invariant: `k` is a valid index in `pending`, so `k + 1 <= len(pending)`.
@(private)
inline_comments :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, $T: Spec, $PRETTY: bool) #no_bounds_check {
	pending := l.pending
	l.pending = nil
	for f, k in pending {
		if f.kind != .Comment_Inline {
			continue
		}
		more := false
		for g in pending[k + 1:] {
			more ||= g.kind == .Comment_Inline
		}
		// A block comment that holds U+2028 reads back as several lines in JSON5, so an inline comment after it would be read
		// as the next value's lead comment: it is dropped.
		if body, _ := write.comment_body(w.doc, f); T == .Json5 && more && holds_line_separator(body) {
			w.dropped += {f.kind}
			continue
		}
		when PRETTY {
			write.put_byte(out, ' ')
		}
		put_comment(out, w, l, f, more, T, PRETTY)
	}
}

// Writes a comment's body, under `ascii` with each character past ASCII as the text of a `\u` escape.
@(private)
put_body :: proc(out: ^write.Out, l: ^Layout, body: []u8) {
	if l.ascii {
		put_ascii(out, string(body), false)
	} else {
		write.put(out, body)
	}
}

// Whether `body`, a comment's text, holds none of the bytes its form depends on: a line end, a `*`, and in JSON5 the
// first byte of U+2028 and U+2029.
@(private)
comment_plain :: proc "contextless" (body: []u8, $T: Spec) -> bool #no_bounds_check {
	ONES :: u64(0x0101010101010101)
	HIGH :: u64(0x8080808080808080)
	i := 0
	for ; i + 8 <= len(body); i += 8 {
		v := intrinsics.unaligned_load((^u64)(raw_data(body[i:])))
		a, b, c := v ~ (ONES * '\n'), v ~ (ONES * '\r'), v ~ (ONES * '*')
		hit := (a - ONES) & ~a | (b - ONES) & ~b | (c - ONES) & ~c
		when T == .Json5 {
			d := v ~ (ONES * 0xE2)
			hit |= (d - ONES) & ~d
		}
		if hit & HIGH != 0 {
			return false
		}
	}
	for ; i < len(body); i += 1 {
		c := body[i]
		if c == '\n' || c == '\r' || c == '*' || T == .Json5 && c == 0xE2 {
			return false
		}
	}
	return true
}

// Writes comment `f` as a line comment when it was one and its body holds no line end, else as a block comment when
// its body holds no `*/`, else drops it. With `block` it takes the block form where it can. In compact text a line
// comment ends with a line end, which pretty text writes after it anyway. Returns whether it wrote a line comment.
// Invariant: `scan` is either `nil` or `body`, so `0 <= i < len(body)` and `i + 1 < len(body)` guards `body[i + 1]`.
@(private)
put_comment :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, f: tape.Fact, block: bool, $T: Spec, $PRETTY: bool) -> (line_comment: bool) #no_bounds_check {
	body, line := write.comment_body(w.doc, f)
	can_line, can_block := true, true
	scan := body if !comment_plain(body, T) else nil
	for c, i in scan {
		switch c {
		case '\n', '\r':
			can_line = false
		case '*':
			can_block &&= i + 1 >= len(body) || body[i + 1] != '/'
		case 0xE2:
			// U+2028 and U+2029 end a JSON5 line comment.
			if T == .Json5 && is_line_separator(body[i:]) {
				can_line = false
			}
		}
	}
	switch {
	case can_line && (line && !(block && can_block) || !can_block):
		write.put(out, transmute([]u8)string("//"))
		put_body(out, l, body)
		when !PRETTY {
			write.put_byte(out, '\n')
			l.line_value = false
		}
		line_comment = true
	case can_block:
		write.put(out, transmute([]u8)string("/*"))
		put_body(out, l, body)
		write.put(out, transmute([]u8)string("*/"))
	case:
		w.dropped += {f.kind}
		return
	}
	l.line_comment = line_comment
	return
}
