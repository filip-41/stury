package html

// The write of a document as HTML, by the standard's serialization of HTML fragments over a markup document's shape. A
// member is an element of its name, an array member is one element per item, and the member `#text` is the text that
// stands there among its siblings. An object is an element's attributes and children, null an element with no content,
// and a scalar its text. An object whose one member is `html` is written as a document, and any other as the nodes of
// a fragment read in `body`.
//
// An element the tree implied is written with its tags, as the tree holds it. A void element has no end tag and the
// text of a raw text element is written as it stands. Any other text escapes `&`, U+00A0, `<` and `>`, and an attribute
// value escapes `&`, U+00A0 and `"`. An HTML document's doctype, comments and attributes are written as they stand in
// the source. Another document's comments are written before, after or at the end of the value that holds them, unless
// HTML cannot hold the comment, and its other facts are dropped and counted.
//
// The text is read back, and one that builds a tree other than the one written is `.Unwritable`: a name HTML folds or
// cannot spell, an element the tree construction moves or closes where it stands, text of only white space among
// elements, and a raw text that holds its end tag. Pretty output indents an element whose children are all elements,
// except in `pre`, `listing` and `textarea`.

import "base:runtime"
import "core:io"
import "core:strings"
import "core:unicode/utf8"
import core "../core"
import typed "../core/typed"
import write "../core/write"

@(private)
Writer :: struct {
	out:  write.Out,
	opts: core.Write_Options,
	kept: int, // the facts written
	buf:  [512]u8,
}

// Writes node `node` of `doc` as HTML, as `core.write` does with `as(spec)`, and returns the facts it dropped. A
// document of another format is written too.
write :: proc(doc: ^core.Document, spec: Spec, opts := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	if int(node) >= len(doc.nodes) || doc.nodes[node].role == .Key {
		return nil, 0, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	out, cut, refusal := document_write(doc, opts, bound_as(spec), node, {}, allocator)
	return out, cut, core.error_of(refusal)
}

// The handle's `write`. Node `node` of `doc` is written compact, read back as the spec its shape names and compared.
// It is then written as `opts` say, to `stream` or into new bytes from `allocator`.
@(private)
document_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, dropped: int, err: core.Typed_Refusal) {
	if doc.partial || core.kind(doc, node) != .Object {
		return nil, 0, {kind = .Unsupported}
	}
	kept: int
	text, kept, err = value_write(core.Node_Ref{doc, node}, as, opts, stream, allocator)
	return text, len(core.subtree_facts(doc, node)) - kept if err.kind == .None else 0, err
}

// Writes object `root` compact, reads it back by the handle `as` and compares, then writes it as `opts` say. Returns the
// facts it wrote.
@(private)
value_write :: proc(root: core.Value, as: core.As, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, kept: int, err: core.Typed_Refusal) {
	compact := opts
	compact.pretty = false
	first, _, refused := serialize(root, compact, {}, context.allocator)
	if refused.kind != .None {
		return nil, 0, refused
	}
	defer delete(first)
	if kind := read_back(first, is_document(root), as, compact); kind != .None {
		return nil, 0, {kind = kind}
	}
	return serialize(root, opts, stream, allocator)
}

// Writes a built value as `value_write` does, for `marshal` and the token write.
@(private)
built_write :: proc(v: core.Value, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal) {
	if core.value_kind(v) != .Object {
		return nil, {kind = .Unsupported}
	}
	text, _, err := value_write(v, bound_as(.Document), opts, stream, allocator)
	return text, err
}

@(private)
marshal_text :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits) -> ([]u8, core.Typed_Refusal) {
	return write.marshal_markup(plan, value, opts, stream, allocator, omits, built_write)
}

// Starts a token write, as `write.tokens_init` does with `as(spec)`. The calls give a value as `write` takes a node. It
// is read back as `write.put_markup` reads a marshal's, so a write to a stream is `.Unsupported`.
tokens_init :: proc(t: ^write.Tokens, spec: Spec, opts := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind {
	return write.tokens_init(t, bound_as(spec), opts, allocator, stream, &TOKENS)
}

// The token spelling. The calls make a value in `write.MARKUP_TREE`, which the end reads back and writes. A scalar that
// is no string and has no text the tree can hold bare is `.Unwritable`.
@(private, rodata)
TOKENS := write.Token_Spelling {
	tree = write.MARKUP_TREE,
	start = proc(t: ^write.Tokens, _: core.As) -> core.Typed_Error_Kind {
		return .Unsupported if t.out.stream.procedure != nil else .None
	},
	value = proc(t: ^write.Tokens, v: write.Scalar) -> core.Typed_Error_Kind {
		stack: [512]u8
		text, _ := write.token_scalar_text(v, stack[:]) or_return
		#partial switch _ in v {
		case string, write.Tagged_Text:
			return write.put_marked(t.out, nil, text, nil)
		}
		if len(text) == 0 || strings.index_any(text, "{}[],: \t\n\"") >= 0 {
			return .Unwritable
		}
		write.put_text(t.out, text)
		return .None
	},
	end = proc(t: ^write.Tokens, bytes: []u8) -> ([]u8, core.Typed_Refusal) {
		defer delete(bytes, t.base.allocator)
		return write.put_markup(string(bytes), t.opts, {}, t.base.allocator, built_write)
	},
}

@(private)
serialize :: proc(root: core.Value, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, kept: int, err: core.Typed_Refusal) {
	spill: [write.ROOM_MAX]u8 = ---
	w := Writer{opts = opts}
	write.init(&w.out, &spill, allocator, stream)
	text, err = write.finish(&w.out, {kind = put_root(&w, root)})
	return text, w.kept, err
}

// Builds `text` as a document when `document`, else as a fragment. Returns `.Unwritable` unless its compact write is
// `text` again.
@(private)
read_back :: proc(text: []u8, document: bool, as: core.As, compact: core.Write_Options) -> core.Typed_Error_Kind {
	doc, built := build_spec(text, .Document if document else .Fragment, as, false, context.allocator)
	defer core.destroy(&doc)
	if built.kind != .None {
		return .No_Memory if built.kind == .No_Memory else .Unwritable
	}
	again, _, err := serialize(core.Node_Ref{&doc, core.ROOT}, compact, {}, context.allocator)
	defer delete(again)
	if err.kind != .None {
		return err.kind
	}
	return .None if string(again) == string(text) else .Unwritable
}

// Whether object `root` is a document: it has one member, `html`, which is no array.
@(private)
is_document :: proc(root: core.Value) -> bool {
	it := core.value_pairs(root)
	key, value, ok := core.value_pair_next(&it)
	_, _, more := core.value_pair_next(&it)
	return ok && !more && key == "html" && core.value_kind(value) != .Array
}

@(private)
put_root :: proc(w: ^Writer, root: core.Value) -> core.Typed_Error_Kind {
	facts := value_facts(root)
	for f in facts {
		if is_head(f.role) || f.role == .Doctype && own_node(root) {
			put_fact(w, root, f) or_return
		}
	}
	put_members(w, root, 0, false) or_return
	for f in facts {
		if f.role == .Comment_Inline || f.role == .Comment_Foot {
			put_fact(w, root, f) or_return
		}
	}
	return w.out.err
}

// Writes the members of object `v` in order, a node's as its document holds them, a repeated name each time. They are
// laid on lines of their own when the output is pretty, they hold no text, and `keep` does not hold their white space.
@(private)
put_members :: proc(w: ^Writer, v: core.Value, depth: int, in_foreign: bool, keep := false) -> core.Typed_Error_Kind {
	context.allocator = context.temp_allocator
	laid := w.opts.pretty && !keep
	n := 0
	if r, is_node := v.(core.Node_Ref); is_node {
		it := core.pairs(r.doc, r.node)
		for key in core.pair_next(&it) {
			laid &&= core.node_string(r.doc, key) != core.MARKUP_TEXT
			n += 1
		}
		it = core.pairs(r.doc, r.node)
		for key, child in core.pair_next(&it) {
			put_member(w, core.node_string(r.doc, key), core.Node_Ref{r.doc, child}, depth, in_foreign, laid) or_return
		}
	} else {
		it := core.value_pairs(v)
		for key in core.value_pair_next(&it) {
			laid &&= key != core.MARKUP_TEXT
			n += 1
		}
		it = core.value_pairs(v)
		for key, child in core.value_pair_next(&it) {
			put_member(w, key, child, depth, in_foreign, laid) or_return
		}
	}
	if laid && n > 0 && depth > 0 {
		write.put_line(&w.out, w.opts, depth - 1)
	}
	return .None
}

@(private)
put_member :: proc(w: ^Writer, name: string, v: core.Value, depth: int, in_foreign, laid: bool) -> core.Typed_Error_Kind {
	if core.value_kind(v) != .Array {
		return put_node(w, name, v, depth, in_foreign, laid)
	}
	items := core.value_children(v)
	for item in core.value_child_next(&items) {
		if core.value_kind(item) == .Array {
			return .Unwritable
		}
		put_node(w, name, item, depth, in_foreign, laid) or_return
	}
	return .None
}

@(private)
put_node :: proc(w: ^Writer, name: string, v: core.Value, depth: int, in_foreign, laid: bool) -> core.Typed_Error_Kind {
	if name == core.MARKUP_TEXT {
		return put_escaped(w, write.value_scalar_text(core.plain(v), w.buf[:], write.MARKUP_TREE) or_return, false)
	}
	facts := value_facts(v)
	for f in facts {
		if is_head(f.role) && !leads_children(v, f) {
			put_fact(w, v, f) or_return
		}
	}
	if laid && w.out.cursor + w.out.flushed > 0 {
		write.put_line(&w.out, w.opts, depth)
	}
	write.put_byte(&w.out, '<')
	write.put_text(&w.out, name)
	for f in facts {
		if f.role == .Attribute {
			put_attribute(w, v, f) or_return
		}
	}
	write.put_byte(&w.out, '>')
	for f in facts {
		if is_head(f.role) && leads_children(v, f) {
			put_fact(w, v, f) or_return
		}
	}
	void := !in_foreign && is_void(name)
	x := core.plain(v)
	#partial switch core.value_kind(x) {
	case .Object:
		if void {
			return .Unwritable
		}
		put_members(w, x, depth + 1, in_foreign || name == "svg" || name == "math", keeps_space(name)) or_return
		for f in facts {
			if f.role == .Comment_Foot {
				put_fact(w, v, f) or_return
			}
		}
	case .Null:
	case:
		if void {
			return .Unwritable
		}
		text := write.value_scalar_text(x, w.buf[:], write.MARKUP_TREE) or_return
		if keeps_space(name) && strings.has_prefix(text, "\n") {
			write.put_byte(&w.out, '\n')
		}
		if !in_foreign && is_raw(name) {
			write.put_text(&w.out, text)
		} else {
			put_escaped(w, text, false) or_return
		}
	}
	if !void {
		write.put_text(&w.out, "</")
		write.put_text(&w.out, name)
		write.put_byte(&w.out, '>')
	}
	for f in facts {
		if f.role == .Comment_Inline {
			put_fact(w, v, f) or_return
		}
	}
	return .None
}

@(private)
value_facts :: proc(v: core.Value) -> []core.Fact {
	if r, is_node := v.(core.Node_Ref); is_node {
		return core.all_facts(r.doc, r.node)
	}
	return nil
}

// Whether head fact `f` of element `v` of an HTML document stands inside it, before its first child: the tree gives a
// comment there to the element, whose node starts at its start tag.
@(private)
leads_children :: proc(v: core.Value, f: core.Fact) -> bool {
	return own_node(v) && core.value_kind(v) == .Object && f.lo > v.(core.Node_Ref).doc.nodes[v.(core.Node_Ref).node].lo
}

// Whether `v` is a node of an HTML document, whose facts are written as they stand.
@(private)
own_node :: proc(v: core.Value) -> bool {
	r, is_node := v.(core.Node_Ref)
	return is_node && r.doc.readers.format == rules_of
}

// Writes attribute `f` of `v`: as it stands in an HTML document, and as `name="value"` from any other. A name HTML
// reads as another is `.Unwritable`.
@(private)
put_attribute :: proc(w: ^Writer, v: core.Value, f: core.Fact) -> core.Typed_Error_Kind {
	r := v.(core.Node_Ref)
	w.kept += 1
	write.put_byte(&w.out, ' ')
	if own_node(v) {
		write.put_text(&w.out, string(r.doc.src[f.lo:][:f.n]))
		return .None
	}
	name_token, value_token := r.doc.readers.attribute(r.doc, f)
	name, named := core.token_text(r.doc.readers, &r.doc.view, name_token, context.temp_allocator)
	text, read := core.token_text(r.doc.readers, &r.doc.view, value_token, context.temp_allocator)
	if !named || !read {
		return .No_Memory
	}
	if len(name) == 0 {
		return .Unwritable
	}
	for c in transmute([]u8)name {
		if is_space(c) || c == 0 || c == '"' || c == '\'' || c == '>' || c == '/' || c == '=' || c == '<' || c - 'A' < 26 {
			return .Unwritable
		}
	}
	write.put_text(&w.out, name)
	write.put_text(&w.out, `="`)
	put_escaped(w, text, true) or_return
	write.put_byte(&w.out, '"')
	return .None
}

// Writes the comment, instruction or doctype `f` of `v`: as it stands in an HTML document. From any other document only
// a comment HTML can hold is written, and the rest is dropped.
@(private)
put_fact :: proc(w: ^Writer, v: core.Value, f: core.Fact) -> core.Typed_Error_Kind {
	r := v.(core.Node_Ref)
	span := string(r.doc.src[f.lo:][:f.n])
	if own_node(v) {
		w.kept += 1
		write.put_text(&w.out, span)
		return .None
	}
	if f.role == .Instruction || f.role == .Doctype || f.kind != .Plain {
		return .None
	}
	body := span[core.comment_lead(f.spelling):u64(f.n) - core.comment_tail(f.spelling)]
	if !holds_comment(body) {
		return .None
	}
	w.kept += 1
	write.put_text(&w.out, "<!--")
	write.put_text(&w.out, body)
	write.put_text(&w.out, "-->")
	return .None
}

// Whether `body` is a comment body that HTML reads back as written.
@(private)
holds_comment :: proc(body: string) -> bool {
	return !strings.has_prefix(body, ">") && !strings.has_prefix(body, "->") && !strings.has_suffix(body, "<!-") && !strings.contains(body, "<!--") && !strings.contains(body, "-->") && !strings.contains(body, "--!>") && utf8.valid_string(body)
}

// Writes `s` as text, or as an attribute value body when `attribute`, escaped as the standard's serialization escapes
// it. With `ascii` every rune past U+007F is written as a reference. A text that is not UTF-8 is `.Invalid_Utf8`.
@(private)
put_escaped :: proc(w: ^Writer, s: string, attribute: bool) -> core.Typed_Error_Kind {
	run := 0
	for i := 0; i < len(s); {
		c := s[i]
		if c < 0x80 && c != '&' && c != '<' && c != '>' && c != '"' {
			i += 1
			continue
		}
		write.put_text(&w.out, s[run:i])
		r, size := rune(c), 1
		if c >= 0x80 {
			r, size = utf8.decode_rune_in_string(s[i:])
			if r == utf8.RUNE_ERROR && size <= 1 {
				return .Invalid_Utf8
			}
		}
		switch {
		case c == '&':
			write.put_text(&w.out, "&amp;")
		case r == 0xa0:
			write.put_text(&w.out, "&nbsp;")
		case c == '"' && attribute:
			write.put_text(&w.out, "&quot;")
		case c == '<' && !attribute:
			write.put_text(&w.out, "&lt;")
		case c == '>' && !attribute:
			write.put_text(&w.out, "&gt;")
		case c >= 0x80 && w.opts.ascii:
			digits: [8]u8
			n := len(digits)
			for v := u32(r); v > 0; v /= 10 {
				n -= 1
				digits[n] = '0' + u8(v % 10)
			}
			write.put_text(&w.out, "&#")
			write.put_text(&w.out, string(digits[n:]))
			write.put_byte(&w.out, ';')
		case:
			write.put_text(&w.out, s[i:i + size])
		}
		i += size
		run = i
	}
	write.put_text(&w.out, s[run:])
	return .None
}

// Whether a fact of `role` stands before the value it is held by.
@(private)
is_head :: #force_inline proc(role: core.Role) -> bool {
	return role == .Comment || role == .Instruction
}

// Whether HTML element `name` is void, written with no end tag and no content.
@(private)
is_void :: proc(name: string) -> bool {
	switch name {
	case "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input", "keygen", "link", "meta", "param", "source", "track", "wbr":
		return true
	}
	return false
}

// Whether the text of HTML element `name` is written as it stands.
@(private)
is_raw :: proc(name: string) -> bool {
	switch name {
	case "style", "script", "xmp", "iframe", "noembed", "noframes", "plaintext":
		return true
	}
	return false
}

// Whether HTML element `name` holds its white space. A read drops the first line end that opens its text, so a line end
// there is written twice, and no indent is laid into it.
@(private)
keeps_space :: proc(name: string) -> bool {
	return name == "pre" || name == "listing" || name == "textarea"
}
