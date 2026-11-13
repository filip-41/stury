package xml

// Writes a node as XML. The node must be an object of one member, the root element, and that member is no array, since
// an XML text has one root. A member is an element of its name, an array member is one element per item, and the member
// `#text` is the text that stands there among its siblings. An object is an element's attributes and children, null an
// empty element, and a scalar its text.
//
// The root of a document read as XML is written from its spans: attributes, namespace declarations and text as
// written, and the doctype, comments and processing instructions where they stood. Every reference then keeps the
// declaration it names. Any other node or document is escaped. Its comments are written before, after or at the end of
// the value that holds them, and its other facts are dropped and counted.
//
// What XML cannot spell so that it reads back is `.Unwritable`: a key that is no XML name or that has a colon, a nested
// or empty array, an empty string or object, an object of only text, and a character XML 1.0 does not allow. A text
// that is not UTF-8 is `.Invalid_Utf8`. Pretty output indents an element whose children are all elements and lays no
// white space into one that holds text. Members keep their order whatever `sort_keys` says, since the order is the
// elements'.

import "base:runtime"
import "core:io"
import "core:slice"
import "core:unicode/utf8"
import core "../core"
import write "../core/write"

@(private)
Writer :: struct {
	out:   write.Out,
	doc:   ^core.Document,
	opts:  core.Write_Options,
	own:   bool, // the root of an XML document, written from its spans
	kept:  int, // the facts written
	facts: []core.Fact, // with `own`, the comments, instructions and doctype by their place in the source
	next:  int, // the first of `facts` not yet written
	buf:   [512]u8,
}

// How `flush` sets apart the facts it writes.
@(private)
Apart :: enum u8 {
	None,
	Indent, // each on a line of its own, at the depth's indent
	After, // each followed by a line end
	Before, // each after a line end
}

// Writes node `node` of `doc` as XML, as `core.write` does with `as(spec)`, and returns the facts it dropped. A document
// of another format is written too.
write :: proc(doc: ^core.Document, spec: Spec, opts := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	if int(node) >= len(doc.nodes) || doc.nodes[node].role == .Key {
		return nil, 0, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	out, cut, refusal := document_write(doc, opts, bound_as(spec), node, {}, allocator)
	return out, cut, core.error_of(refusal)
}

// The handle's `write`. The root of an XML document is written from its spans, any other node by the element write.
@(private)
document_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, dropped: int, err: core.Typed_Refusal) {
	if doc.partial || core.kind(doc, node) != .Object {
		return nil, 0, {kind = .Unsupported}
	}
	spill: [write.ROOM_MAX]u8 = ---
	w := Writer{doc = doc, opts = opts, own = doc.readers.format == rules_of && node == core.ROOT}
	if w.own {
		write.init(&w.out, &spill, allocator, stream, len(doc.src) + write.ROOM_MAX)
		text, err = write.finish(&w.out, {kind = put_own(&w)})
	} else {
		write.init(&w.out, &spill, context.allocator if opts.pretty else allocator, {} if opts.pretty else stream)
		e: Elements
		elements_init(&e, &w.out, opts)
		text, err = elements_finish(&e, put_document(&w, &e, node), opts, stream, allocator)
	}
	if err.kind != .None {
		return nil, 0, err
	}
	return text, len(core.subtree_facts(doc, node)) - w.kept, err
}

@(private)
value_write :: proc(v: core.Value, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal) {
	spill: [write.ROOM_MAX]u8 = ---
	w := Writer{opts = opts}
	write.init(&w.out, &spill, context.allocator if opts.pretty else allocator, {} if opts.pretty else stream)
	e: Elements
	elements_init(&e, &w.out, opts)
	return elements_finish(&e, put_value(&w, &e, v), opts, stream, allocator)
}

@(private)
put_own :: proc(w: ^Writer) -> core.Typed_Error_Kind {
	facts := make([dynamic]core.Fact, 0, len(w.doc.facts), context.temp_allocator)
	for f in w.doc.facts {
		if f.role != .Attribute {
			append(&facts, f)
		}
	}
	slice.sort_by(facts[:], proc(a, b: core.Fact) -> bool {return a.lo < b.lo})
	w.facts = facts[:]
	it := core.pairs(w.doc, core.ROOT)
	key, value, _ := core.pair_next(&it)
	flush(w, w.doc.nodes[key].lo, 0, .After) or_return
	put_element(w, key, value, 0, false) or_return
	return flush(w, u64(len(w.doc.src)), 0, .Before)
}

// Writes the element of key `key` and value `value`, with the facts before it. `laid` puts the element, and each fact
// before it, on a line of its own.
@(private)
put_element :: proc(w: ^Writer, key, value: core.Node_Index, depth: int, laid: bool) -> core.Typed_Error_Kind {
	name := core.span(w.doc, key)
	at := w.doc.nodes[key].lo
	flush(w, at, depth, .Indent if laid else .None) or_return
	indent(w, laid, depth)
	write.put_byte(&w.out, '<')
	write.put_text(&w.out, string(name))
	// An attribute that stands before the element's name is a default its doctype declares. A read of the written text
	// supplies it again, so it is counted and not written.
	for f in core.all_facts(w.doc, value) {
		if f.role == .Attribute {
			w.kept += 1
			if f.lo > at {
				write.put_byte(&w.out, ' ')
				write.put_text(&w.out, string(w.doc.src[f.lo:][:f.n]))
			}
		}
	}
	t := w.doc.nodes[value]
	span := core.span(w.doc, value)
	#partial switch core.kind(w.doc, value) {
	case .Object:
		write.put_byte(&w.out, '>')
		inner := put_children(w, value, depth) or_return
		flush(w, t.lo + u64(len(span)) - 1, depth + 1, .Indent if inner else .None) or_return
		indent(w, inner, depth)
	case .Null:
		if t.kind != .Plain || len(span) == 0 {
			write.put_text(&w.out, "/>")
			return .None
		}
		fallthrough
	case:
		write.put_byte(&w.out, '>')
		put_own_text(w, value, false) or_return
	}
	put_close(&w.out, name)
	return .None
}

// Writes the members of an element in order. Returns whether they stand on lines of their own, which only the members
// of an element with no text do.
@(private)
put_children :: proc(w: ^Writer, value: core.Node_Index, depth: int) -> (laid: bool, kind: core.Typed_Error_Kind) {
	laid = w.opts.pretty
	it := core.pairs(w.doc, value)
	for key in core.pair_next(&it) {
		laid &&= !is_text(w, key)
	}
	it = core.pairs(w.doc, value)
	for key, child in core.pair_next(&it) {
		if is_text(w, key) {
			flush(w, w.doc.nodes[child].lo, depth + 1, .None) or_return
			put_own_text(w, child, true) or_return
		} else if core.kind(w.doc, child) != .Array {
			put_element(w, key, child, depth + 1, laid) or_return
		} else {
			items := core.children(w.doc, child)
			for item in core.child_next(&items) {
				put_element(w, key, item, depth + 1, laid) or_return
			}
		}
	}
	return laid, .None
}

// Writes an element's text as it stands in the source, or escaped when the reader decoded it.
@(private)
put_own_text :: proc(w: ^Writer, node: core.Node_Index, among: bool) -> core.Typed_Error_Kind {
	if w.doc.nodes[node].kind == .Plain {
		put_raw(w, core.span(w.doc, node))
		return .None
	}
	return put_text(&w.out, write.scalar_text(w.doc, node, w.buf[:]) or_return, among, w.opts.ascii)
}

@(private)
put_document :: proc(w: ^Writer, e: ^Elements, node: core.Node_Index) -> core.Typed_Error_Kind {
	facts := core.all_facts(w.doc, node)
	for f in facts {
		if is_head(f.role) {
			put_fact(w, f) or_return
			write.put_byte(&w.out, '\n')
		}
	}
	put_value(w, e, core.Node_Ref{w.doc, node}) or_return
	for f in facts {
		if f.role == .Comment_Inline || f.role == .Comment_Foot {
			write.put_byte(&w.out, '\n')
			put_fact(w, f) or_return
		}
	}
	return .None
}

// Writes `value` through the element write. A node of another document brings the comments before it, its attributes and
// the comments after it. The comments of the document's object belong to `put_document`, and an array's are dropped.
@(private)
put_value :: proc(w: ^Writer, e: ^Elements, value: core.Value) -> core.Typed_Error_Kind {
	v := core.plain(value)
	kind := core.value_kind(v)
	facts: []core.Fact
	if r, is_node := v.(core.Node_Ref); is_node && e.top > 0 && kind != .Array {
		w.doc, facts = r.doc, core.all_facts(r.doc, r.node)
	}
	doc := w.doc
	for f in facts {
		if is_head(f.role) {
			put_fact(w, f) or_return
			if e.top == 1 {
				write.put_byte(&w.out, '\n')
			}
		}
	}
	for f in facts {
		if f.role == .Attribute {
			w.kept += 1
			name_token, value_token := w.doc.readers.attribute(w.doc, f)
			name, named := core.token_text(w.doc.readers, &w.doc.view, name_token, context.temp_allocator)
			text, read := core.token_text(w.doc.readers, &w.doc.view, value_token, context.temp_allocator)
			if !named || !read {
				return .No_Memory
			}
			el_attribute(e, name, text) or_return
		}
	}
	#partial switch kind {
	case .Object:
		el_open(e, true) or_return
		put_members(w, e, v) or_return
		w.doc = doc
		for f in facts {
			if f.role == .Comment_Foot {
				put_fact(w, f) or_return
			}
		}
		el_close(e) or_return
	case .Array:
		el_open(e, false) or_return
		items := core.value_children(v)
		for item in core.value_child_next(&items) {
			put_value(w, e, item) or_return
		}
		el_close(e) or_return
	case .Null:
		el_value(e, "", true) or_return
	case:
		el_value(e, write.value_scalar_text(v, w.buf[:], write.MARKUP_TREE) or_return) or_return
	}
	w.doc = doc
	for f in facts {
		if f.role == .Comment_Inline {
			put_fact(w, f) or_return
		}
	}
	return w.out.err
}

@(private)
put_members :: proc(w: ^Writer, e: ^Elements, v: core.Value) -> core.Typed_Error_Kind {
	context.allocator = context.temp_allocator
	if r, is_node := v.(core.Node_Ref); is_node {
		it := core.pairs(r.doc, r.node)
		for key, child in core.pair_next(&it) {
			el_key(e, core.node_string(r.doc, key)) or_return
			put_value(w, e, core.Node_Ref{r.doc, child}) or_return
		}
		return .None
	}
	it := core.value_pairs(v)
	for key, child in core.value_pair_next(&it) {
		el_key(e, key) or_return
		put_value(w, e, child) or_return
	}
	return .None
}

// Writes the facts of an XML document that were not written yet and stand before byte `upto`, set apart by `apart`.
@(private)
flush :: proc(w: ^Writer, upto: u64, depth: int, apart: Apart) -> core.Typed_Error_Kind {
	for ; w.next < len(w.facts) && w.facts[w.next].lo < upto; w.next += 1 {
		#partial switch apart {
		case .Indent:
			write.put_line(&w.out, w.opts, depth)
		case .Before:
			write.put_byte(&w.out, '\n')
		}
		put_fact(w, w.facts[w.next]) or_return
		if apart == .After {
			write.put_byte(&w.out, '\n')
		}
	}
	return .None
}

// Writes an element's text as it stands. The comments and instructions inside it repeat the document's facts, so they
// are counted and not written again.
@(private)
put_raw :: proc(w: ^Writer, span: []u8) {
	hi := u64(uintptr(raw_data(span)) - uintptr(raw_data(w.doc.src))) + u64(len(span))
	for ; w.next < len(w.facts) && w.facts[w.next].lo < hi; w.next += 1 {
		w.kept += 1
	}
	write.put_text(&w.out, string(span))
}


@(private)
put_close :: proc(out: ^write.Out, name: []u8) {
	write.put_text(out, "</")
	write.put_text(out, string(name))
	write.put_byte(out, '>')
}

// Writes `s` as character data, `among` an element's children or not. An empty text is `.Unwritable`, since it reads
// back as null. A text among children that is only white space is written as references, since a reader drops such a
// run.
@(private)
put_text :: proc(out: ^write.Out, s: string, among, ascii: bool) -> core.Typed_Error_Kind {
	if len(s) == 0 {
		return .Unwritable
	}
	if among && only_whitespace(s) {
		for c in transmute([]u8)s {
			put_reference(out, rune(c))
		}
		return .None
	}
	return put_escaped(out, s, false, ascii)
}

// Writes `s` as character data, or as an attribute value between double quotes when `attribute`. Every byte a reader
// would read otherwise is written as a reference, and with `ascii` so is every rune past U+007F.
@(private)
put_escaped :: proc(out: ^write.Out, s: string, attribute, ascii: bool) -> core.Typed_Error_Kind {
	run := 0
	for i := 0; i < len(s); {
		c := s[i]
		if c >= 0x20 && c < 0x80 && c != '&' && c != '<' && c != '>' && c != '"' {
			i += 1
			continue
		}
		write.put_text(out, s[run:i])
		r, size := rune(c), 1
		if c >= 0x80 {
			r, size = utf8.decode_rune_in_string(s[i:])
			if r == utf8.RUNE_ERROR && size <= 1 {
				return .Invalid_Utf8
			}
			if r == 0xfffe || r == 0xffff {
				return .Unwritable
			}
		}
		switch {
		case c == '&':
			write.put_text(out, "&amp;")
		case c == '<':
			write.put_text(out, "&lt;")
		case c == '>':
			write.put_text(out, "&gt;")
		case c == '"' && attribute:
			write.put_text(out, "&quot;")
		case c == '\r' || attribute && (c == '\t' || c == '\n'):
			put_reference(out, r)
		case c < 0x20 && c != '\t' && c != '\n':
			return .Unwritable
		case c >= 0x80 && ascii:
			put_reference(out, r)
		case:
			write.put_text(out, s[i:i + size])
		}
		i += size
		run = i
	}
	write.put_text(out, s[run:])
	return .None
}

@(private)
put_reference :: proc(out: ^write.Out, r: rune) {
	HEX := "0123456789abcdef"
	digits: [8]u8
	n := 0
	for v := u32(r); n == 0 || v > 0; v >>= 4 {
		digits[len(digits) - 1 - n] = HEX[v & 15]
		n += 1
	}
	write.put_text(out, "&#x")
	write.put_text(out, string(digits[len(digits) - n:]))
	write.put_byte(out, ';')
}

// Writes a comment, an instruction or the doctype. An XML document's own is written as it stands. Another document's
// comment is written as an XML comment, unless its body holds `--` or ends in `-`, which no XML comment can. Then it is
// dropped, as is another document's instruction.
@(private)
put_fact :: proc(w: ^Writer, f: core.Fact) -> core.Typed_Error_Kind {
	if w.own {
		w.kept += 1
		write.put_text(&w.out, string(w.doc.src[f.lo:][:f.n]))
		return .None
	}
	if f.role == .Instruction {
		return .None
	}
	body := string(w.doc.src[f.lo:][:f.n])
	if f.kind == .Plain {
		body = body[core.comment_lead(f.spelling):u64(f.n) - core.comment_tail(f.spelling)]
	}
	for i in 0 ..< len(body) {
		if body[i] == '-' && (i + 1 == len(body) || body[i + 1] == '-') {
			return .None
		}
	}
	write.put_text(&w.out, "<!--")
	put_escaped_comment(w, body) or_return
	write.put_text(&w.out, "-->")
	w.kept += 1
	return .None
}

// Writes a comment's body. XML reads it with no references, so a byte XML 1.0 does not allow is `.Unwritable`.
@(private)
put_escaped_comment :: proc(w: ^Writer, body: string) -> core.Typed_Error_Kind {
	for i := 0; i < len(body); {
		c := body[i]
		if c < 0x20 && c != '\t' && c != '\n' && c != '\r' {
			return .Unwritable
		}
		if c < 0x80 {
			i += 1
			continue
		}
		r, size := utf8.decode_rune_in_string(body[i:])
		if r == utf8.RUNE_ERROR && size <= 1 {
			return .Invalid_Utf8
		}
		if r == 0xfffe || r == 0xffff {
			return .Unwritable
		}
		i += size
	}
	write.put_text(&w.out, body)
	return .None
}

// Whether a fact of `role` stands before the value it is held by.
@(private)
is_head :: #force_inline proc(role: core.Role) -> bool {
	return role == .Comment || role == .Instruction
}

@(private)
is_text :: proc(w: ^Writer, key: core.Node_Index) -> bool {
	text, ok := core.text(w.doc, key, w.buf[:])
	return ok && text == core.MARKUP_TEXT
}

// Whether `s` is an XML name with no colon, which a reader with namespaces takes with no declaration.
@(private)
is_name :: proc(s: []u8) -> bool {
	if len(s) == 0 {
		return false
	}
	p := raw_data(s)
	q, fault, colon := name_end_colon(p, p[len(s):])
	return fault == .None && !colon && q == p[len(s):]
}

@(private)
only_whitespace :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if !is_ws(c) {
			return false
		}
	}
	return true
}

@(private)
indent :: #force_inline proc(w: ^Writer, laid: bool, depth: int) {
	if laid {
		write.put_line(&w.out, w.opts, depth)
	}
}
