package xml

// Writes a node as XML. The node must be an object of one member, the root element, and that member is no array, since
// an XML text has one root. A member is an element of its name, an array member is one element per item, and the member
// `#text` is the text that stands there among its siblings. An object is an element's attributes and children, null an
// empty element, and a scalar its text.
//
// The root of a document read as XML is written from its spans: attributes, namespace declarations and text as
// written, and the doctype, comments and processing instructions where they stood. Every reference then keeps the
// declaration it names. Any other node or document is escaped. Its comments are written before, after or at the end of
// the value that holds them, a doctype that names only the root element is written, and its other facts are dropped
// and counted.
//
// What XML cannot spell so that it reads back is `.Unwritable`: a key that is no XML name or that has a colon, a nested
// or empty array, an empty string or object, an object of only text, and a character XML 1.0 does not allow. A text
// that is not UTF-8 is `.Invalid_Utf8`. Pretty output indents an element whose children are all elements and lays no
// white space into one that holds text. Members keep their order whatever `sort_keys` says, since the order is the
// elements'.

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:simd"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import kernel "../core/kernel"
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
	seek:  int, // where the facts of the elements not yet written start in the document's
	ended: int, // the output's length after the line end that last ended an inline comment
	buf:   [512]u8,
}

// How `flush` sets apart the facts it writes.
@(private)
Apart :: enum u8 {
	None,
	Indent, // each on a line of its own, at the depth's indent
	After, // each followed by a line end
	Foot, // on the line of the element before them, the first not inline one after a line end
	Before, // each after a line end
}

// Writes node `node` of `doc` as XML, as `core.write` does with `as(spec)`. A document of another format is written too.
write :: proc(doc: ^core.Document, $S: Spec, write := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	return core.write(doc, write, as(S), node, allocator)
}

// Reads `src` as spec `S` and writes it back as `write` says, as `core.format` does with `as(spec, opts)`.
format :: proc(src: []u8, $S: Spec, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	return core.format(src, as(S, opts), write, allocator)
}

// Writes node `node` of `doc` as spec `S` to `w`, as `core.write_stream` does with `as(spec)`.
write_stream :: proc(w: io.Stream, doc: ^core.Document, $S: Spec, write := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (dropped: int, err: core.Error) {
	return core.write_stream(w, doc, write, as(S), node, allocator)
}

// The handle's `write`. The root of an XML document is written from its spans, any other node by the element write.
@(private)
document_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, kept: int, err: core.Typed_Refusal) {
	if core.kind(doc, node) != .Object {
		return nil, 0, {kind = .Unwritable, detail = {want = {text = "an XML document is one element, so its root is an object"}}}
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
	return text, w.kept, err
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
	at := w.doc.nodes[key].lo
	lead := at
	for f in w.facts {
		if f.lo < at && f.node != core.ROOT {
			lead = f.lo
			break
		}
	}
	flush(w, lead, 0, .After) or_return
	// A blank line ends the text's head comment, so the comments of the root element stay its own.
	if w.next > 0 && w.facts[w.next - 1].role == .Comment {
		write.put_byte(&w.out, '\n')
	}
	flush(w, at, 0, .After) or_return
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
	if put_leaf(w, name, value) {
		return .None
	}
	write.put_byte(&w.out, '<')
	write.put_text(&w.out, string(name))
	// An attribute that stands before the element's name is a default its doctype declares. A read of the written text
	// supplies it again, so it is counted and not written.
	for f in value_facts(w, value) {
		if f.role == .Attribute {
			w.kept += 1
			if f.lo > at {
				write.put_byte(&w.out, ' ')
				write.put_text(&w.out, string(w.doc.src[f.lo:][:f.n]))
			}
		}
	}
	t := w.doc.nodes[value]
	#partial switch core.kind(w.doc, value) {
	case .Object:
		write.put_byte(&w.out, '>')
		inner, last_element := put_children(w, value, depth) or_return
		// The end of the element is found only for facts that may stand inside it.
		if w.next < len(w.facts) {
			flush(w, t.lo + u64(len(core.span(w.doc, value))) - 1, depth + 1, .Indent if inner else .Foot if last_element else .None) or_return
		}
		indent(w, inner, depth)
	case .Null:
		if t.kind != .Plain || len(core.span(w.doc, value)) == 0 {
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

// The facts of value node `value`. The elements come in node order, so the search starts where the last one's ended.
@(private)
value_facts :: #force_inline proc(w: ^Writer, value: core.Node_Index) -> []core.Fact {
	all := w.doc.facts
	i := w.seek
	for i < len(all) && all[i].node < value {
		i += 1
	}
	w.seek = i
	j := i
	for j < len(all) && all[j].node == value {
		j += 1
	}
	return all[i:j]
}

// Writes the element of `name` and value node `value` whole when it is a text copied as it stands, has no attribute and
// fits one room of the output, with one copy per part. Returns false, having written nothing, for any other element.
@(private)
put_leaf :: #force_inline proc(w: ^Writer, name: []u8, value: core.Node_Index) -> bool {
	t := w.doc.nodes[value]
	if t.kind != .Plain || !write.copies_raw(w.opts) || len(value_facts(w, value)) != 0 {
		return false
	}
	span := core.span(w.doc, value)
	n := len(name)
	total := 2 * n + len(span) + 5
	if len(span) == 0 || total > write.ROOM_MAX {
		return false
	}
	hi := u64(uintptr(raw_data(span)) - uintptr(raw_data(w.doc.src))) + u64(len(span))
	for ; w.next < len(w.facts) && w.facts[w.next].lo < hi; w.next += 1 {
		w.kept += 1
	}
	p := write.room(&w.out, total)
	p[0] = '<'
	intrinsics.mem_copy_non_overlapping(p[1:], raw_data(name), n)
	p[1 + n] = '>'
	intrinsics.mem_copy_non_overlapping(p[2 + n:], raw_data(span), len(span))
	q := p[2 + n + len(span):]
	q[0], q[1] = '<', '/'
	intrinsics.mem_copy_non_overlapping(q[2:], raw_data(name), n)
	q[2 + n] = '>'
	w.out.cursor += total
	return true
}

// Writes the members of an element in order. Returns whether they stand on lines of their own, which only the members
// of an element with no text do, and whether the last one is an element.
@(private)
put_children :: proc(w: ^Writer, value: core.Node_Index, depth: int) -> (laid, last_element: bool, kind: core.Typed_Error_Kind) {
	laid = w.opts.pretty
	it := core.pairs(w.doc, value)
	for key in core.pair_next(&it) {
		laid &&= !is_text(w, key)
	}
	it = core.pairs(w.doc, value)
	for key, child in core.pair_next(&it) {
		last_element = !is_text(w, key)
		if !last_element {
			flush(w, w.doc.nodes[child].lo, depth + 1, .None) or_return
			put_own_text(w, child, true) or_return
		} else if w.doc.nodes[child].kind != .Array {
			put_element(w, key, child, depth + 1, laid) or_return
		} else {
			items := core.children(w.doc, child)
			for item in core.child_next(&items) {
				put_element(w, key, item, depth + 1, laid) or_return
			}
		}
	}
	return laid, last_element, .None
}

// Writes an element's text as it stands in the source, or escaped when the reader decoded it.
@(private)
put_own_text :: proc(w: ^Writer, node: core.Node_Index, among: bool) -> core.Typed_Error_Kind {
	if w.doc.nodes[node].kind == .Plain && write.copies_raw(w.opts) {
		put_raw(w, core.span(w.doc, node))
		return .None
	}
	return put_text(&w.out, write.scalar_text(w.doc, node, w.buf[:]) or_return, among, w.opts.ascii)
}

// Writes the document of another format: its doctype, when it names only a root element, its head comments and a blank
// line that ends them, the root, then its foot comments.
@(private)
put_document :: proc(w: ^Writer, e: ^Elements, node: core.Node_Index) -> core.Typed_Error_Kind {
	facts := core.all_facts(w.doc, node)
	for f in facts {
		if f.role == .Doctype {
			put_doctype(w, f)
		}
	}
	before := w.kept
	for f in facts {
		if is_head(f.role) {
			put_fact(w, f) or_return
			write.put_byte(&w.out, '\n')
		}
	}
	if w.kept > before {
		write.put_byte(&w.out, '\n')
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

// Writes `value` through the element write, with the facts `lead` before its own and `tail` after them. A node of
// another document brings the comments before it, its attributes and the comments after it. A value an update put in
// place of an element brings the attributes and comments it reads, and a comment role written on a value stands for its
// node's. The comments of the document's object belong to `put_document`, and an array's go to its items, where they
// read back: the lead ones to the first and the rest to the last.
@(private)
put_value :: proc(w: ^Writer, e: ^Elements, value: core.Value, lead: []core.Fact = nil, tail: []core.Fact = nil) -> core.Typed_Error_Kind {
	v := core.plain(value)
	kind := core.kind(v)
	facts: []core.Fact
	if r, is_node := v.(core.Node_Ref); is_node && e.top > 0 {
		w.doc, facts = r.doc, core.all_facts(r.doc, r.node)
	}
	if len(lead) + len(tail) > 0 {
		facts = slice.concatenate([][]core.Fact{lead, facts, tail}, context.temp_allocator)
	}
	run_lead, run_tail: [dynamic]core.Fact
	if kind == .Array {
		run_lead.allocator, run_tail.allocator = context.temp_allocator, context.temp_allocator
		for f in facts {
			append(&run_lead if is_head(f.role) else &run_tail, f)
		}
		facts = nil
	}
	doc := w.doc
	brought: [core.Role][]string
	rebuilt: bit_set[core.Role]
	if kind != .Array {
		context.allocator = context.temp_allocator
		for role in core.COMMENT_ROLES {
			if bodies, is_rebuilt := core.rebuilt_comments(value, role); is_rebuilt {
				brought[role] = bodies
				rebuilt += {role}
			}
		}
	}
	for f in facts {
		if is_head(f.role) && f.role not_in rebuilt {
			put_fact(w, f) or_return
			if e.top == 1 {
				write.put_byte(&w.out, '\n')
			}
		}
	}
	for body in brought[.Comment] {
		_ = put_comment(&w.out, body, true) or_return
		if e.top == 1 {
			write.put_byte(&w.out, '\n')
		}
	}
	if kind != .Array {
		context.allocator = context.temp_allocator
		written, is_rebuilt := core.rebuilt_attributes(value)
		rebuilt += {.Attribute} if is_rebuilt else {}
		if written != nil {
			for name, i in core.object_keys(written) {
				el_attribute(e, name, core.object_vals(written)[i].(string) or_else "") or_return
			}
		}
	}
	for f in facts {
		if f.role == .Attribute && .Attribute not_in rebuilt {
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
	foot := kind == .Object || len(brought[.Comment_Foot]) > 0
	for f in facts {
		foot ||= f.role == .Comment_Foot && .Comment_Foot not_in rebuilt
	}
	#partial switch kind {
	case .Object:
		el_open(e, true) or_return
		put_members(w, e, v) or_return
	case .Array:
		el_open(e, false) or_return
		n := core.length(v)
		items := core.children(v)
		for i := 0; ; i += 1 {
			item := core.child_next(&items) or_break
			put_value(w, e, item, run_lead[:] if i == 0 else nil, run_tail[:] if i == n - 1 else nil) or_return
		}
		el_close(e) or_return
	case .Null:
		el_value(e, "", true, foot) or_return
	case:
		el_value(e, write.value_scalar_text(v, w.buf[:], write.MARKUP_TREE) or_return, false, foot) or_return
	}
	w.doc = doc
	if foot {
		for f in facts {
			if f.role == .Comment_Foot && .Comment_Foot not_in rebuilt {
				put_foot(w, kind)
				put_fact(w, f) or_return
			}
		}
		for body in brought[.Comment_Foot] {
			put_foot(w, kind)
			_ = put_comment(&w.out, body, true) or_return
		}
		el_close(e) or_return
	}
	// A comment is inline only while a line end follows it on the element's line.
	for f in facts {
		if f.role == .Comment_Inline && .Comment_Inline not_in rebuilt {
			put_fact(w, f) or_return
			end_inline(w)
		}
	}
	for body in brought[.Comment_Inline] {
		_ = put_comment(&w.out, body, true) or_return
		end_inline(w)
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
	it := core.pairs(v)
	for key, child in core.pair_next(&it) {
		el_key(e, key) or_return
		put_value(w, e, child) or_return
	}
	return .None
}

@(private)
end_inline :: #force_inline proc(w: ^Writer) {
	write.put_byte(&w.out, '\n')
	w.ended = w.out.cursor + w.out.flushed
}

// Starts a foot comment of an element of `kind`. A comment on the line of the last child element would be that
// element's, unless an inline comment's line end stands between them.
@(private)
put_foot :: #force_inline proc(w: ^Writer, kind: core.Kind) {
	if kind == .Object && w.out.cursor + w.out.flushed != w.ended {
		write.put_byte(&w.out, '\n')
	}
}

// Writes the facts of an XML document that were not written yet and stand before byte `upto`, set apart by `apart`.
@(private)
flush :: proc(w: ^Writer, upto: u64, depth: int, apart: Apart) -> core.Typed_Error_Kind {
	footed := false
	for ; w.next < len(w.facts) && w.facts[w.next].lo < upto; w.next += 1 {
		inline := w.facts[w.next].role == .Comment_Inline
		if apart == .Foot && !inline && !footed {
			write.put_byte(&w.out, '\n')
			footed = true
		}
		#partial switch apart {
		case .Indent, .Before:
			if inline {
				// An inline comment stays on the line of the element before it.
				write.put_byte(&w.out, ' ')
			} else if apart == .Indent {
				write.put_line(&w.out, w.opts, depth)
			} else {
				write.put_byte(&w.out, '\n')
			}
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
put_close :: #force_inline proc(out: ^write.Out, name: []u8) {
	n := len(name)
	if n + 3 > write.ROOM_MAX {
		write.put_text(out, "</")
		write.put_text(out, string(name))
		write.put_byte(out, '>')
		return
	}
	p := write.room(out, n + 3)
	p[0], p[1] = '<', '/'
	intrinsics.mem_copy_non_overlapping(p[2:], raw_data(name), n)
	p[2 + n] = '>'
	out.cursor += n + 3
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
	for i := plain_run(s); i < len(s); i += plain_run(s[i:]) {
		c := s[i]
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

// The length of the run at the start of `s` that `put_escaped` copies as it stands: the bytes from 0x20 to 0x7F but `&`,
// `<`, `>` and `"`. It reads 16 bytes at a time.
@(private)
plain_run :: #force_inline proc "contextless" (s: string) -> int #no_bounds_check {
	stops :: #force_inline proc "contextless" (v: #simd[16]u8) -> #simd[16]u8 {
		return kernel.control_or_high16(v, false) | simd.lanes_eq(v, '&') | simd.lanes_eq(v, '<') | simd.lanes_eq(v, '>') | simd.lanes_eq(v, '"')
	}
	src, n := raw_data(s), len(s)
	i := 0
	for ; i + 16 <= n; i += 16 {
		if m := stops(kernel.load16(src[i:])); kernel.any_lane16(m) {
			return i + int(kernel.first_lane16(m))
		}
	}
	if i == n {
		return n
	}
	if v, live, ok := kernel.head16(src[i:], n - i); ok {
		return min(n, i + int(kernel.first_lane16(stops(v) & live)))
	}
	for i < n && src[i] >= 0x20 && src[i] < 0x80 && src[i] != '&' && src[i] != '<' && src[i] != '>' && src[i] != '"' {
		i += 1
	}
	return i
}

@(private)
put_reference :: proc(out: ^write.Out, r: rune) {
	digits := 1
	for v := u32(r) >> 4; v > 0; v >>= 4 {
		digits += 1
	}
	write.put_hex(out, "&#x", u32(r), digits)
	write.put_byte(out, ';')
}

// Writes a comment, an instruction, the doctype or the declaration. An XML document's own is written as it stands.
// Another document's comment is written as an XML comment, unless its body holds `--` or ends in `-` with no space after
// it, which no XML comment can. Then it is dropped, as is another document's instruction.
@(private)
put_fact :: proc(w: ^Writer, f: core.Fact) -> core.Typed_Error_Kind {
	if w.own {
		w.kept += int(f.role != .Directive)
		write.put_text(&w.out, string(w.doc.src[f.lo:][:f.n]))
		return .None
	}
	if f.role == .Instruction {
		return .None
	}
	body, padded := string(w.doc.src[f.lo:][:f.n]), false
	if f.kind == .Plain {
		body, padded = core.comment_text(w.doc, f)
	}
	written := put_comment(&w.out, body, padded) or_return
	w.kept += int(written)
	return .None
}

// Writes comment `body`, set apart from its markers by a space when `padded`, unless it holds `--` or, unpadded, ends in
// `-`, which no XML comment can.
@(private)
put_comment :: proc(out: ^write.Out, body: string, padded: bool) -> (written: bool, kind: core.Typed_Error_Kind) {
	for i in 0 ..< len(body) {
		if body[i] == '-' && (i + 1 == len(body) && !padded || i + 1 < len(body) && body[i + 1] == '-') {
			return false, .None
		}
	}
	write.put_text(out, "<!-- " if padded else "<!--")
	put_escaped_comment(out, body) or_return
	write.put_text(out, " -->" if padded else "-->")
	return true, .None
}

// Writes the doctype `f` of another format's document as `<!DOCTYPE name>` when it names an XML name and no more, as
// HTML's does. One with an external identifier, which HTML spells otherwise than XML, is dropped.
@(private)
put_doctype :: proc(w: ^Writer, f: core.Fact) {
	span := string(w.doc.src[f.lo:][:f.n])
	if len(span) < len("<!DOCTYPE>") || !strings.equal_fold(span[:len("<!DOCTYPE")], "<!DOCTYPE") || span[len(span) - 1] != '>' {
		return
	}
	name := strings.trim_space(span[len("<!DOCTYPE"):len(span) - 1])
	if !is_name(transmute([]u8)name) {
		return
	}
	write.put_text(&w.out, "<!DOCTYPE ")
	write.put_text(&w.out, name)
	write.put_text(&w.out, ">\n")
	w.kept += 1
}

// Writes a comment's body. XML reads it with no references, so a byte XML 1.0 does not allow is `.Unwritable`.
@(private)
put_escaped_comment :: proc(out: ^write.Out, body: string) -> core.Typed_Error_Kind {
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
	write.put_text(out, body)
	return .None
}

// Whether a fact of `role` stands before the value it is held by.
@(private)
is_head :: #force_inline proc(role: core.Role) -> bool {
	return role == .Comment || role == .Instruction
}

@(private)
is_text :: #force_inline proc(w: ^Writer, key: core.Node_Index) -> bool {
	return w.doc.nodes[key].spelling & core.SPELLING_SYNTHETIC == core.SPELLING_SYNTHETIC
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

// Splits `s`, an XML name with one colon between two names, into its prefix and local name.
@(private)
split_qname :: proc(s: string) -> (prefix, local: string, ok: bool) {
	i := strings.index_byte(s, ':')
	if i <= 0 || i == len(s) - 1 {
		return
	}
	prefix, local = s[:i], s[i + 1:]
	return prefix, local, is_name(transmute([]u8)prefix) && is_name(transmute([]u8)local)
}

// Whether `s` is an element's name with a prefix, which any prefix but `xmlns` may be.
@(private)
is_element_qname :: proc(s: string) -> bool {
	prefix, _, ok := split_qname(s)
	return ok && prefix != "xmlns"
}

@(private)
UNBOUND_PREFIX :: "a name with a prefix, which no declaration of an enclosing element binds"

@(private)
BAD_BINDING :: "a namespace declaration that binds an empty name, the prefix xmlns, or xml or its name wrongly"

@(private)
XML_NAMESPACE :: "http://www.w3.org/XML/1998/namespace"

@(private)
only_whitespace :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if !kernel.is_ws(c) {
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
