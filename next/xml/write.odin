package xml

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "stury:lib/base/spell"
import "stury:lib/core/markup"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// XML's writer, the inverse of the reader's model: a document is an object of one member, the root element. An
// element is a member under its name, whose value is its text or null for none, or an object of its child elements and
// its `#text` runs, with its attributes as facts of that value. An array under a name is that many elements of the name
// in order, and an empty one has no element to stand for it, so it is refused, as is an array in an array. The text is
// compact: an element has the whitespace its `#text` runs hold and no other.

Write_Options :: write.Options
Write_Error :: write.Error
Token_Kind :: write.Token_Kind
Record_Framing :: write.Record_Framing
Refused :: write.Refused
Refusal :: write.Refusal

// Writes value `opts.node` of `doc`, a document of any format, as a text of `spec` in a buffer from `allocator` that
// the caller owns. Returns the kinds of the facts `doc` holds that the text does not: none of an XML document, of
// another every kind but comments. `indent` and `tab` put each element on a line of its own, but for those that hold
// text of their own. A value with no XML spelling is `Refused` with its node: a root that is no object of one member, a
// key that is no name, an empty or nested array, a number with no decimal text and a text with a control character.
// `ascii`, `sort_keys` and `framing` are `Bad_Option`.
write :: proc(doc: ^tape.Document, spec := Spec.Xml, opts := Write_Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: Write_Error) {
	return write.to_buffer(doc, u8(spec), opts, allocator, write_out)
}

// `write` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. A sink with no procedure is
// `Bad_Option{"sink"}`. On a refusal or a failed sink the sink may hold a prefix of the text.
write_to :: proc(sink: io.Writer, doc: ^tape.Document, spec := Spec.Xml, opts := Write_Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: Write_Error) {
	return write.to_sink(sink, doc, u8(spec), opts, allocator, write_out)
}

// An open container of the walk: the node whose key names its elements, what it is, and for an element the level its
// tag stands at and whether its children go each on a line of their own.
@(private)
Open_Frame :: struct {
	name:   tape.Node_Index,
	level:  int,
	array:  bool,
	root:   bool,
	pretty: bool,
	text:   bool, // the element holds text, so a line end between its children is text
}

// The facts XML writes of a document of its own format, and of any other.
@(private)
HELD_XML :: tape.COMMENTS + {.Attribute, .Instruction, .Instruction_Foot, .Doctype, .Directive}

// The state of a write.
@(private)
Writing :: struct {
	out:    ^write.Out,
	w:      ^write.Tree,
	doc:    ^tape.Document,
	stack:  [dynamic]Open_Frame,
	width:   int, // bytes of indent a level
	fill:    u64, // eight bytes of indent
	xml:     bool, // the document is a real XML read, whose names/texts/attributes/instructions are XML's own
	raw_xml: bool, // `xml` and `doc.flags` has neither `.Held` nor `.Tolerated`, so decode-free strings copy verbatim
	open:    bool, // a start tag is written but for its `>`
	wrote:  bool,
	pretty: bool, // the text is indented
}

@(private)
write_out :: proc(out: ^write.Out, doc: ^tape.Document, spec: u8, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	if e := write_check(spec, opts); e != nil {
		return {}, e
	}
	w: write.Tree
	x := doc.format == &FORMATS[.Xml]
	if e := write.tree_start(&w, doc, opts, HELD_XML if x else tape.COMMENTS, allocator); e != nil {
		return {}, e
	}
	if doc.nodes[opts.node].kind != .Object || tape.child_count(doc, opts.node, doc.nodes[opts.node]) != 1 {
		w.err = write.Refused{opts.node, .No_Spelling}
	} else {
		width, fill := int(opts.indent), u64(0x2020202020202020)
		if opts.tab {
			width, fill = 1, 0x0909090909090909
		}
		s := Writing{out = out, w = &w, doc = doc, width = width, fill = fill, xml = x, raw_xml = x && doc.flags & {.Held, .Tolerated} == {}, pretty = !write.compact(opts)}
		s.stack.allocator = allocator
		facts, tables := write.tree_facts(&w), write.tree_tables(&w)
		switch {
		case facts && tables: write_steps(&s, true, true)
		case facts: write_steps(&s, true, false)
		case tables: write_steps(&s, false, true)
		case: write_steps(&s, false, false)
		}
		delete(s.stack)
	}
	dropped := write.tree_end(&w)
	if w.err == nil {
		w.err = out.err
	}
	return dropped, w.err
}

// Refuses a `spec` XML does not have and the options XML writes no text under.
@(private)
write_check :: proc "contextless" (spec: u8, opts: Write_Options) -> Write_Error {
	if spec > u8(max(Spec)) {
		return tape.Bad_Option{"spec"}
	}
	if opts.format != nil || opts.ascii || opts.sort_keys || opts.framing != .None || opts.grow_header || len(opts.header) > 0 {
		opt := "format" if opts.format != nil else "header" if len(opts.header) > 0 || opts.grow_header else "options"
		return tape.Bad_Option{opt}
	}
	return nil
}

@(private)
fail :: proc(w: ^write.Tree, at: tape.Node_Index) {
	if w.err == nil {
		w.err = write.Refused{at, .No_Spelling}
	}
}

// Closes a start tag still open and, in indented text, starts a line at `level`.
@(private)
begin :: #force_inline proc(s: ^Writing, level: int, pretty: bool) {
	if s.open {
		write.put_byte(s.out, '>')
		s.open = false
	}
	if pretty && s.wrote {
		line_indent(s.out, s, level)
	}
	s.wrote = true
}

// A line end and the indent of `level` levels, written in eight-byte stores.
@(private)
line_indent :: #force_inline proc(out: ^write.Out, s: ^Writing, level: int) #no_bounds_check {
	n := level * s.width
	if n + 9 > write.ROOM_MAX {
		line_indent_long(out, s, n)
		return
	}
	p := write.room(out, n + 9)
	p[0] = '\n'
	for k := 0; k < n; k += 8 {
		intrinsics.unaligned_store((^u64)(p[1 + k:]), s.fill)
	}
	out.cursor += n + 1
}

@(private, cold)
line_indent_long :: #force_no_inline proc(out: ^write.Out, s: ^Writing, n: int) {
	write.put_byte(out, '\n')
	for left := n; left > 0; {
		k := min(left, write.ROOM_MAX - 8)
		p := write.room(out, k + 8)
		for i := 0; i < k; i += 8 {
			intrinsics.unaligned_store((^u64)(p[i:]), s.fill)
		}
		out.cursor += k
		left -= k
	}
}

// Writes the facts among `facts` of the kinds `kinds`, each on a line at `level` when `pretty`: a comment as XML spells
// it and an instruction or declaration as it was written. A comment that follows a sibling in compact text would read
// as the inline comment of that sibling, so `lead` puts it on a line of its own.
@(private)
put_misc :: proc(s: ^Writing, facts: []tape.Fact, kinds: tape.Facts, level: int, pretty, lead: bool) {
	for f in facts {
		if f.kind not_in kinds {
			continue
		}
		verbatim := f.kind != .Comment && f.kind != .Comment_Inline && f.kind != .Comment_Foot
		if verbatim && !s.xml {
			continue
		}
		body: []u8
		if !verbatim {
			body, _ = write.comment_body(s.doc, f)
			if !comment_holds(body) {
				s.w.dropped += {f.kind}
				continue
			}
		}
		begin(s, level, pretty)
		if lead && !pretty {
			write.put_byte(s.out, '\n')
		}
		if verbatim {
			write.put(s.out, tape.span_bytes(s.doc, f.lo, f.n))
		} else {
			write.put(s.out, transmute([]u8)string("<!--"))
			write.put(s.out, body)
			write.put(s.out, transmute([]u8)string("-->"))
		}
	}
}

// Whether `body` can stand in an XML comment: valid UTF-8, no U+FFFE/U+FFFF noncharacter, no `--`, no trailing `-`,
// and no control character but tab and the line ends.
@(private)
comment_holds :: proc "contextless" (body: []u8) -> bool #no_bounds_check {
	prev := u8(0)
	p := raw_data(body)
	end := intrinsics.ptr_offset(p, len(body))
	for i := 0; i < len(body); {
		c := body[i]
		if c >= 0x80 {
			q, kind := spell.utf8_char(p[i:], end)
			if kind != .None || c == 0xef && non_char(p[i:], end) {
				return false
			}
			prev = 0
			i = intrinsics.ptr_sub(q, p)
			continue
		}
		if c < 0x20 && c != '\t' && c != '\n' && c != '\r' || c == '-' && prev == '-' {
			return false
		}
		prev = c
		i += 1
	}
	return prev != '-'
}

// Whether the object at `at` holds a `#text` member, so that no whitespace may be added between its children.
@(private)
holds_text :: proc(w: ^write.Tree, at: tape.Node_Index, xml: bool) -> bool {
	end := tape.node_after(w.doc, at)
	for k := at + 1; k < end; k = tape.node_after(w.doc, k + 1) {
		// The reader marks the `#text` member of an XML document, whose text is no bytes of the source.
		if xml {
			if markup.is_text_key(w.nodes[k]) {
				return true
			}
			continue
		}
		// A key with no escape has the length of its text.
		if t := w.nodes[k]; t.spelling & tape.SPELLING_DECODE == 0 && int(t.n) != len(TEXT_KEY) {
			continue
		}
		if name, ok := write.text_of(w, k); ok && name == TEXT_KEY {
			return true
		}
	}
	return false
}

// Whether `facts` hold a comment or instruction that ends its element.
@(private)
has_foot :: proc "contextless" (facts: []tape.Fact) -> bool {
	for f in facts {
		if f.kind == .Comment_Foot || f.kind == .Instruction_Foot {
			return true
		}
	}
	return false
}

@(private)
write_steps :: proc(s: ^Writing, $FACTS, $TABLES: bool) {
	w, out, doc := s.w, s.out, s.doc
	for w.err == nil {
		step := write.tree_next(w, FACTS, TABLES)
		if step.kind == .Done {
			if s.pretty && s.wrote && w.err == nil {
				write.put_byte(out, '\n')
			}
			return
		}
		if step.kind == .Close {
			top := pop(&s.stack)
			if top.root {
				// What follows the root element, each on a line of its own.
				when FACTS {
					if len(step.facts) != 0 {
						put_misc(s, step.facts, {.Comment_Foot, .Instruction_Foot}, 0, s.pretty, true)
					}
				}
				continue
			}
			if top.array {
				continue
			}
			feet := false
			when FACTS {
				feet = has_foot(step.facts)
			}
			if s.open && !feet {
				write.put(out, transmute([]u8)string("/>"))
				s.open = false
			} else {
				when FACTS {
					if len(step.facts) != 0 {
						put_misc(s, step.facts, {.Comment_Foot, .Instruction_Foot}, top.level + 1, top.pretty, false)
					}
				}
				begin(s, top.level, top.pretty)
				write.put(out, transmute([]u8)string("</"))
				name, _ := write.text_of(w, top.name)
				write.put(out, transmute([]u8)name)
				write.put_byte(out, '>')
			}
			when FACTS {
				if len(step.facts) != 0 {
					put_misc(s, step.facts, {.Comment_Inline}, 0, false, false)
				}
			}
			continue
		}
		parent: Open_Frame
		if len(s.stack) > 0 {
			parent = s.stack[len(s.stack) - 1]
		}
		name_node := step.key
		if name_node == tape.NO_NODE {
			name_node = parent.name
		}
		is_array := step.kind == .Open && w.nodes[step.node].kind == .Array
		if len(s.stack) == 0 {
			// The document's object, whose declaration and document type stand before its element.
			when FACTS {
				if len(step.facts) != 0 {
					put_misc(s, step.facts, {.Comment, .Instruction, .Directive, .Doctype}, 0, s.pretty, false)
				}
			}
			if _, e := append(&s.stack, Open_Frame{root = true, pretty = s.pretty, level = -1}); e != nil {
				w.err = e
			}
			continue
		}
		if is_array {
			if parent.array || parent.root || tape.child_count(doc, step.node, w.nodes[step.node]) <= 0 {
				fail(w, step.node)
				return
			}
			if _, e := append(&s.stack, Open_Frame{name = name_node, array = true, pretty = parent.pretty, level = parent.level}); e != nil {
				w.err = e
			}
			continue
		}
		name, ok := write.text_of(w, name_node)
		if !ok {
			return
		}
		level := parent.level + 1
		when FACTS {
			if len(step.facts) != 0 {
				put_misc(s, step.facts, {.Comment, .Instruction}, level, parent.pretty, !step.first && !parent.text)
			}
		}
		if name == TEXT_KEY {
			if parent.root {
				fail(w, name_node)
				return
			}
			begin(s, 0, false)
			if step.kind == .Open || !put_text(s, step.node) {
				fail(w, step.node)
				return
			}
			continue
		}
		if !s.xml && !is_name(name) {
			fail(w, name_node)
			return
		}
		begin(s, level, parent.pretty)
		if step.kind == .Scalar && len(step.facts) == 0 && put_leaf(s, name, step.node) {
			continue
		}
		write.put_byte(out, '<')
		write.put(out, transmute([]u8)name)
		when FACTS {
			if s.xml {
				put_attributes(s, step.facts)
			}
		}
		if step.kind == .Open {
			text := holds_text(w, step.node, s.xml)
			frame := Open_Frame{name = name_node, level = level, pretty = parent.pretty && !text, text = text}
			if _, e := append(&s.stack, frame); e != nil {
				w.err = e
				return
			}
			s.open = true
			continue
		}
		feet := false
		when FACTS {
			feet = has_foot(step.facts)
		}
		null := w.nodes[step.node].kind == .Null
		if null && !feet {
			write.put(out, transmute([]u8)string("/>"))
		} else {
			write.put_byte(out, '>')
			if !null && !put_text(s, step.node) {
				fail(w, step.node)
				return
			}
			when FACTS {
				if len(step.facts) != 0 {
					put_misc(s, step.facts, {.Comment_Foot, .Instruction_Foot}, 0, false, false)
				}
			}
			write.put(out, transmute([]u8)string("</"))
			again, _ := write.text_of(w, name_node)
			write.put(out, transmute([]u8)again)
			write.put_byte(out, '>')
		}
		when FACTS {
			if len(step.facts) != 0 {
				put_misc(s, step.facts, {.Comment_Inline}, 0, false, false)
			}
		}
	}
}

// Writes the attributes among `facts` of an XML document, each as ` name="value"`, its value as it was written.
@(private)
put_attributes :: proc(s: ^Writing, facts: []tape.Fact) {
	out, doc := s.out, s.doc
	for f in facts {
		if f.kind != .Attribute {
			continue
		}
		name, value := markup.attribute_parts(tape.span_bytes(doc, f.lo, f.n), f.spelling)
		quote := u8('"')
		for c in value {
			if c == '"' {
				quote = '\''
			}
		}
		write.put_byte(out, ' ')
		write.put(out, name)
		write.put_byte(out, '=')
		write.put_byte(out, quote)
		write.put(out, value)
		write.put_byte(out, quote)
	}
}

// The text of the scalar at `at` as the walk reads it, in `buf` or the walk's scratch. False for a scalar that is not
// written as text of its own, and with `w.err` set when memory is refused.
@(private)
scalar_text :: #force_inline proc(w: ^write.Tree, at: tape.Node_Index, buf: ^[write.NUMBER_ROOM]u8) -> (s: string, ok: bool) {
	#partial switch w.nodes[at].kind {
	case .True:
		return "true", true
	case .False:
		return "false", true
	case .Number:
		return write.number_text(w, at, buf)
	case .String, .Plain:
		return write.text_of(w, at)
	}
	return "", false
}

// Whether node `at` is an XML text node whose source bytes already passed XML validation with no decoding needed, so
// they hold no `<`, `&`, CR, control byte, `]]>` or U+FFFE/U+FFFF noncharacter and can be copied verbatim.
@(private)
is_raw_xml_text :: #force_inline proc "contextless" (s: ^Writing, node: tape.Node) -> bool {
	return s.raw_xml && node.kind == .String && node.spelling & tape.SPELLING_DECODE == 0
}

// Writes the element `<name>text</name>` whole when the scalar at `at` has a text with nothing to escape that fits one
// room of the output, with one copy per part. Returns false, having written nothing, for any other.
@(private)
put_leaf :: proc(s: ^Writing, name: string, at: tape.Node_Index) -> bool {
	buf: [write.NUMBER_ROOM]u8 = ---
	text, ok := scalar_text(s.w, at, &buf)
	n := len(name)
	total := 2 * n + len(text) + 5
	raw := is_raw_xml_text(s, s.w.nodes[at])
	if !ok || total + 16 > write.ROOM_MAX {
		return false
	}
	p := write.room(s.out, total + 16)
	p[0] = '<'
	intrinsics.mem_copy_non_overlapping(p[1:], raw_data(name), n)
	p[1 + n] = '>'
	if raw {
		intrinsics.mem_copy_non_overlapping(p[2 + n:], raw_data(text), len(text))
	} else if !write.copy_clean(p[2 + n:], transmute([]u8)text, .Xml_Text) {
		return false
	}
	q := p[2 + n + len(text):]
	q[0], q[1] = '<', '/'
	intrinsics.mem_copy_non_overlapping(q[2:], raw_data(name), n)
	q[2 + n] = '>'
	s.out.cursor += total
	s.wrote = true
	return true
}

// Writes the text of the scalar at `at`, `&`, `<`, `>` and a carriage return as references. False for a number with no
// text, a control character or U+FFFE/U+FFFF noncharacter that XML forbids, or with `w.err` set when memory is refused.
@(private)
put_text :: proc(s: ^Writing, at: tape.Node_Index) -> bool {
	out, w := s.out, s.w
	s.wrote = true
	buf: [write.NUMBER_ROOM]u8 = ---
	node := w.nodes[at]
	if node.kind == .Bytes {
		encoded, ok := write.bytes_base64(w, at)
		if !ok {
			return false
		}
		defer delete(encoded, w.allocator)
		write.put(out, transmute([]u8)encoded)
		return true
	}
	text, ok := scalar_text(w, at, &buf)
	if !ok {
		return false
	}
	if is_raw_xml_text(s, node) {
		write.put(out, transmute([]u8)text)
		return true
	}
	b := transmute([]u8)text
	for len(b) > 0 {
		clean := write.clean_prefix(b, .Xml_Text)
		write.put(out, b[:clean])
		if clean == len(b) {
			break
		}
		c := b[clean]
		if c == 0xef {
			if non_char(raw_data(b[clean:]), intrinsics.ptr_offset(raw_data(b), len(b))) {
				return false
			}
			write.put_byte(out, c)
			b = b[clean + 1:]
			continue
		}
		ref: string
		switch c {
		case '&': ref = "&amp;"
		case '<': ref = "&lt;"
		case '>': ref = "&gt;"
		case '\r': ref = "&#13;"
		case:
			return false
		}
		write.put(out, transmute([]u8)ref)
		b = b[clean + 1:]
	}
	return true
}

// Whether `s` is an XML NCName that a non-XML key can spell (valid XML 1.0 Name with no colons/unbound prefixes).
@(private)
is_name :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	p := raw_data(s)
	end := intrinsics.ptr_offset(p, len(s))
	q, fault, colon := name_end_colon(p, end)
	return fault == .None && q == end && !colon
}
