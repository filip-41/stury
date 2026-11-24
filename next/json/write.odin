package json

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// JSON's writer: the layout of a document's values as a JSON, JSONC or JSON5 text, and the spelling of its scalars.
// A string is written with the fewest escapes that keep it valid and the same text, a number as written when its text
// is one of the target's, and a key of any scalar kind as a string of its text, as the readers name it.

Write_Options :: write.Options
Write_Error :: write.Error

// Writes value `opts.node` of `doc`, a document of any format, as a text of `spec`, in a buffer from `allocator` that
// the caller owns. Returns the kinds of the facts `doc` holds that the text does not: every fact for `.Json`, and the
// facts other than comments, and comments with no place, for `.Jsonc` and `.Json5`. A value JSON cannot spell is
// `Refused` with its node, and no text: a non-finite number or a byte string, a key that is a container, a number with
// no decimal text, a container a path read kept part of.
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
	switch Spec(spec) {
	case .Json:
		return write_as(out, doc, .Json, opts, allocator)
	case .Jsonc:
		return write_as(out, doc, .Jsonc, opts, allocator)
	case .Json5:
	}
	return write_as(out, doc, .Json5, opts, allocator)
}

// What a JSON write knows of its document and layout, and where its comments stand.
@(private)
Layout :: struct {
	width:      int, // bytes of indent a level
	fill:       u64, // eight bytes of indent
	// The document was read as JSON or JSONC and holds its text whole, so an unescaped string's span with its quotes
	// is its JSON text.
	copy_text:  bool,
	// The document was read as JSON5, whose unescaped strings and keys keep their own quotes, or none.
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

@(private)
write_as :: #force_no_inline proc(out: ^write.Out, doc: ^tape.Document, $T: Spec, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	w: write.Tree
	if e := write.tree_start(&w, doc, opts, FORMATS[T].facts, allocator); e != nil {
		return {}, e
	}
	l := Layout{width = int(opts.indent), fill = 0x2020202020202020}
	if opts.tab {
		l.width, l.fill = 1, 0x0909090909090909
	}
	whole := .Held not_in doc.flags
	l.ascii = opts.ascii
	l.copy_text = whole && !opts.ascii && (doc.format == &FORMATS[.Json] || doc.format == &FORMATS[.Jsonc])
	l.json5 = whole && doc.format == &FORMATS[.Json5]
	l.numbers = doc.format == &FORMATS[.Json] || doc.format == &FORMATS[.Jsonc] || doc.format == &FORMATS[.Json5] || doc.format.options == .Dsv
	facts, tables := write.tree_facts(&w), write.tree_tables(&w)
	dense: []u8
	if !facts && !tables {
		dense = dense_route(doc, opts)
	}
	if dense != nil {
		write_dense(out, dense)
	} else if !facts && !tables && l.copy_text && !opts.sort_keys && .Tolerated not_in doc.flags {
		switch {
		case write.compact(opts):
			write_rows(out, &w, &l, false, 0)
		case l.width == 2:
			write_rows(out, &w, &l, true, 2)
		case:
			write_rows(out, &w, &l, true, 0)
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
			if s.key != tape.NO_NODE {
				if !put_key(out, w, l, s.key, T) {
					return
				}
				put_colon(out, PRETTY)
				when FACTS {
					key_comments(out, w, l, s, T, PRETTY)
				}
			}
			if s.kind == .Scalar {
				if !put_scalar(out, w, l, s.node, T) {
					return
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
		case .Close:
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
			write.put_byte(out, ']' if w.nodes[s.node].kind == .Array else '}')
			when FACTS {
				l.pending, l.line_value = s.facts, true
				if s.depth == 0 {
					l.root_facts = s.facts
				}
			}
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

// A line end and the indent of `depth` levels.
@(private)
line_indent :: #force_inline proc(out: ^write.Out, l: ^Layout, depth: int) #no_bounds_check {
	n := depth * l.width
	if n + 9 > write.ROOM_MAX {
		line_indent_long(out, l, n)
		return
	}
	// `room` gives `n + 9` bytes, so the last eight-byte store ends inside it.
	p := write.room(out, n + 9)
	p[0] = '\n'
	for k := 0; k < n; k += 8 {
		intrinsics.unaligned_store((^u64)(p[1 + k:]), l.fill)
	}
	out.cursor += n + 1
}

@(private, cold)
line_indent_long :: #force_no_inline proc(out: ^write.Out, l: ^Layout, n: int) {
	write.put_byte(out, '\n')
	for left := n; left > 0; {
		k := min(left, write.ROOM_MAX - 8)
		p := write.room(out, k + 8)
		for i := 0; i < k; i += 8 {
			intrinsics.unaligned_store((^u64)(p[i:]), l.fill)
		}
		out.cursor += k
		left -= k
	}
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
	case .Bytes, .Array, .Object, .End:
		w.err = write.Refused{at, .No_Spelling}
		return false
	}
	return true
}

// Writes the string or plain scalar `t` at `at` as a JSON string, or under JSON5 a JSON5 one's span as written.
@(private)
put_text :: #force_inline proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, at: tape.Node_Index, t: tape.Node, $T: Spec) -> bool #no_bounds_check {
	if t.spelling & tape.SPELLING_DECODE == 0 {
		// A string read whole from JSON or JSONC with no escape lies between its quotes, `lo - 1` and `lo + n`.
		if l.copy_text && t.kind == .String {
			write.put(out, w.doc.src[t.lo - 1:][:t.n + 2])
			return true
		}
		when T == .Json5 {
			if l.json5 && !l.ascii {
				head, tail := quotes(w.doc.src, t)
				write.put(out, w.doc.src[t.lo - u64(head):][:t.n + u32(head) + u32(tail)])
				return true
			}
		}
	}
	return put_text_of(out, w, l, at)
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

// Writes the text of scalar node `at` as a JSON string, false with `w.err` set when it cannot be read.
@(private)
put_text_of :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, at: tape.Node_Index) -> bool {
	s, ok := write.text_of(w, at)
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
		case r >= 0x10000:
			c := u32(r) - 0x10000
			n = u_escape(p, 0xD800 + c >> 10) + u_escape(p[6:], 0xDC00 + c & 0x3FF)
		case r >= 0x80:
			n = u_escape(p, u32(r))
		case quoted && ESCAPE_OF[r] != 0:
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

// Writes `s` as a JSON string: a quote, a backslash and the control bytes escaped, each with its shortest escape, and
// every other byte as itself.
@(private)
put_escaped :: proc(out: ^write.Out, s: string) #no_bounds_check {
	write.put_byte(out, '"')
	b := transmute([]u8)s
	run := 0
	i := 0
	for i < len(b) {
		// Eight bytes at a time while none needs an escape. Bytes past 0x7F never flag, and the lowest flagged byte is
		// a byte below 0x20, a quote or a backslash, as a borrow only flags bytes above a true one.
		for i + 8 <= len(b) {
			v := intrinsics.unaligned_load((^u64)(raw_data(b[i:])))
			ONES :: u64(0x0101010101010101)
			HIGH :: u64(0x8080808080808080)
			quote := v ~ (ONES * '"')
			slash := v ~ (ONES * '\\')
			hit := ((v - ONES * 0x20) | (quote - ONES) | (slash - ONES)) & ~v & HIGH
			if hit != 0 {
				i += int(intrinsics.count_trailing_zeros(hit) >> 3)
				break
			}
			i += 8
		}
		for i < len(b) && ESCAPE_OF[b[i]] == 0 {
			i += 1
		}
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
@(private)
inline_comments :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, $T: Spec, $PRETTY: bool) {
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

// Writes comment `f` as a line comment when it was one and its body holds no line end, else as a block comment when
// its body holds no `*/`, else drops it. With `block` it takes the block form where it can. In compact text a line
// comment ends with a line end, which pretty text writes after it anyway. Returns whether it wrote a line comment.
@(private)
put_comment :: proc(out: ^write.Out, w: ^write.Tree, l: ^Layout, f: tape.Fact, block: bool, $T: Spec, $PRETTY: bool) -> (line_comment: bool) {
	body, line := write.comment_body(w.doc, f)
	can_line, can_block := true, true
	for c, i in body {
		switch c {
		case '\n', '\r':
			can_line = false
		case '*':
			can_block &&= i + 1 >= len(body) || body[i + 1] != '/'
		case 0xE2:
			// U+2028 and U+2029 end a JSON5 line comment.
			if T == .Json5 && i + 2 < len(body) && body[i + 1] == 0x80 && body[i + 2] & 0xFE == 0xA8 {
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
