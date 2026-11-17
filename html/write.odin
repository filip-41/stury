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
// the source. Another document's comments, and those written on a value, are written before, after or at the end of the
// value that holds them, unless HTML cannot hold the comment, and its other facts are dropped and counted.
//
// The text is read back, and one that builds a tree other than the one written is `.Unwritable`: a name HTML folds or
// cannot spell, an element the tree construction moves or closes where it stands, text of only white space among
// elements, and a raw text that holds its end tag. Pretty output indents an element whose children are all elements,
// except in `pre`, `listing` and `textarea`.

import "base:runtime"
import "core:io"
import "core:strings"
import "core:unicode/utf8"
import spell "../core/spell"
import core "../core"
import typed "../core/typed"
import write "../core/write"

@(private)
Writer :: struct {
	out:       write.Out,
	opts:      core.Write_Options,
	kept:      int, // the facts written
	// The members of the element being written end with an element on the output's line, so a comment written after
	// them starts a line, or it would read back as that element's.
	foot_line: bool,
	foot_depth: int, // with `foot_line`, the depth a comment's line starts at, 0 for no indent, as in a compact write
	ended:     int, // the output's length after the last element and its inline comments
	buf:       [512]u8,
}

// Writes node `node` of `doc` as HTML, as `core.write` does with `as(spec)`. A document of another format is written
// too.
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

@(private = "file")
NO_TREE :: "an HTML text is a tree of elements, so its root is an object"

// The handle's `write`. Node `node` of `doc` is written compact, read back as the spec its shape names and compared.
// It is then written as `opts` say, to `stream` or into new bytes from `allocator`.
@(private)
document_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, kept: int, err: core.Typed_Refusal) {
	if doc.partial {
		return nil, 0, {kind = .Unsupported}
	}
	if core.kind(doc, node) != .Object {
		return nil, 0, {kind = .Unwritable, detail = {want = {text = NO_TREE}}}
	}
	return value_write(core.Node_Ref{doc, node}, as, opts, stream, allocator)
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
	if core.kind(v) != .Object {
		return nil, {kind = .Unwritable, detail = {want = {text = NO_TREE}}}
	}
	text, _, err := value_write(v, bound_as(.Document), opts, stream, allocator)
	return text, err
}

@(private)
marshal_text :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits) -> ([]u8, core.Typed_Refusal) {
	return write.marshal_markup(plan, value, opts, stream, allocator, omits, built_write)
}

// The token spelling. The calls make a value in `write.MARKUP_TREE`, which the end reads back and writes. A scalar that
// is no string and has no text the tree can hold bare is `.Unwritable`.
@(private, rodata)
TOKENS := write.Token_Spelling {
	tree = write.MARKUP_TREE,
	built = built_write,
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
	comment = proc(t: ^write.Tokens, role: core.Role, text: string) -> core.Typed_Error_Kind {
		return write.put_marked_comment(t.out, role, text) if holds_comment(text) else .Unwritable
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
	it := core.pairs(root)
	key, value, ok := core.pair_next(&it)
	_, _, more := core.pair_next(&it)
	return ok && !more && key == "html" && core.kind(value) != .Array
}

@(private)
put_root :: proc(w: ^Writer, root: core.Value) -> core.Typed_Error_Kind {
	facts := value_facts(root)
	bodies, written := core.rebuilt_comments(root, .Comment)
	lead := len(bodies) > 0
	for f in facts {
		if is_head(f.role) && !(written && f.role == .Comment) || f.role == .Doctype && own_node(root) {
			before := w.kept
			put_fact(w, root, f) or_return
			lead = is_head(f.role) && w.kept > before || lead && f.role != .Doctype
		}
	}
	put_bodies(w, bodies)
	// A blank line ends the text's head comment, so the comments of the first member stay its own.
	if lead {
		write.put_text(&w.out, "\n\n")
	}
	_ = put_members(w, root, 0, false) or_return
	put_comments(w, root, facts, .Comment_Inline) or_return
	put_comments(w, root, facts, .Comment_Foot) or_return
	w.foot_line = false
	return w.out.err
}

// Writes the members of object `v` in order, a node's as its document holds them, a repeated name each time. They are
// laid on lines of their own when the output is pretty, they hold no text, and `keep` does not hold their white space.
// `closing` says that they were, so the caller ends the line of the element's end tag after the element's foot comments.
@(private)
put_members :: proc(w: ^Writer, v: core.Value, depth: int, in_foreign: bool, keep := false) -> (closing: bool, kind: core.Typed_Error_Kind) {
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
		it := core.pairs(v)
		for key in core.pair_next(&it) {
			laid &&= key != core.MARKUP_TEXT
			n += 1
		}
		it = core.pairs(v)
		for key, child in core.pair_next(&it) {
			put_member(w, key, child, depth, in_foreign, laid) or_return
		}
	}
	w.foot_line = !laid && !keep && n > 0 && w.ended == w.out.cursor + w.out.flushed
	put_empty_runs(w, v, depth, laid) or_return
	return laid && n > 0 && depth > 0, .None
}

@(private)
put_member :: proc(w: ^Writer, name: string, v: core.Value, depth: int, in_foreign, laid: bool) -> core.Typed_Error_Kind {
	if core.kind(v) != .Array {
		return put_node(w, name, v, depth, in_foreign, laid)
	}
	// The run's comments read back as those of its first and last elements.
	n := core.length(v)
	items := core.children(v)
	for i := 0; ; i += 1 {
		item := core.child_next(&items) or_break
		if core.kind(item) == .Array {
			return .Unwritable
		}
		put_node(w, name, item, depth, in_foreign, laid, v if i == 0 else nil, v if i == n - 1 else nil) or_return
	}
	return .None
}

// Writes the comments of each empty array among the members of object `v` after the last member, as the object's foot,
// since an empty array is no element to hold them.
@(private)
put_empty_runs :: proc(w: ^Writer, v: core.Value, depth: int, laid: bool) -> core.Typed_Error_Kind {
	it := core.pairs(v)
	for _, child in core.pair_next(&it) {
		if core.kind(child) != .Array || core.length(child) > 0 {
			continue
		}
		_, commented := child.(^core.Commented)
		facts := value_facts(child)
		if laid && (commented || len(facts) > 0) {
			write.put_line(&w.out, w.opts, depth)
		}
		for role in ([]core.Role{.Comment, .Comment_Inline, .Comment_Foot}) {
			put_comments(w, child, facts, role) or_return
		}
	}
	return .None
}

// Writes element `name` of value `v`, with the lead comments of `lead` before it and the foot and inline comments of
// `tail` after its own.
@(private)
put_node :: proc(w: ^Writer, name: string, v: core.Value, depth: int, in_foreign, laid: bool, lead: core.Value = nil, tail: core.Value = nil) -> core.Typed_Error_Kind {
	if name == core.MARKUP_TEXT {
		return put_escaped(w, write.value_scalar_text(core.plain(v), w.buf[:], write.MARKUP_TREE) or_return, false)
	}
	// A comment on the line of the element before is that element's.
	if laid && w.out.cursor + w.out.flushed > 0 {
		write.put_line(&w.out, w.opts, depth)
	}
	put_comments(w, lead, value_facts(lead), .Comment) or_return
	facts := value_facts(v)
	bodies, written := core.rebuilt_comments(v, .Comment)
	for f in facts {
		if is_head(f.role) && !(written && f.role == .Comment) {
			put_fact(w, v, f) or_return
		}
	}
	put_bodies(w, bodies)
	write.put_byte(&w.out, '<')
	write.put_text(&w.out, name)
	attributes, rebuilt := core.rebuilt_attributes(v)
	if attributes != nil {
		for key, i in attributes.keys {
			write.put_byte(&w.out, ' ')
			put_attribute_text(w, key, attributes.vals[i].(string) or_else "") or_return
		}
	}
	for f in facts {
		if f.role == .Attribute && !rebuilt {
			put_attribute(w, v, f) or_return
		}
	}
	write.put_byte(&w.out, '>')
	void := !in_foreign && is_void(name)
	x := core.plain(v)
	closing := false
	#partial switch core.kind(x) {
	case .Object:
		if void {
			return .Unwritable
		}
		closing = put_members(w, x, depth + 1, in_foreign || name == "svg" || name == "math", keeps_space(name)) or_return
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
	tail_facts := value_facts(tail)
	if !void {
		if closing {
			w.foot_line, w.foot_depth = true, depth + 1
		}
		put_comments(w, v, facts, .Comment_Foot) or_return
		put_comments(w, tail, tail_facts, .Comment_Foot) or_return
		w.foot_line, w.foot_depth = false, 0
		if closing {
			write.put_line(&w.out, w.opts, depth)
		}
		write.put_text(&w.out, "</")
		write.put_text(&w.out, name)
		write.put_byte(&w.out, '>')
	}
	put_comments(w, v, facts, .Comment_Inline) or_return
	put_comments(w, tail, tail_facts, .Comment_Inline) or_return
	w.ended = w.out.cursor + w.out.flushed
	return .None
}

@(private)
value_facts :: proc(v: core.Value) -> []core.Fact {
	if r, is_node := core.plain(v).(core.Node_Ref); is_node {
		return core.all_facts(r.doc, r.node)
	}
	return nil
}

// Whether `v` is a node of an HTML document, whose facts are written as they stand.
@(private)
own_node :: proc(v: core.Value) -> bool {
	r, is_node := core.plain(v).(core.Node_Ref)
	return is_node && r.doc.readers.format == rules_of
}

// Writes attribute `f` of `v`: as it stands in an HTML document, and as `put_attribute_text` writes it from any other.
@(private)
put_attribute :: proc(w: ^Writer, v: core.Value, f: core.Fact) -> core.Typed_Error_Kind {
	r := core.plain(v).(core.Node_Ref)
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
	return put_attribute_text(w, name, text)
}

// Writes attribute `name` with the value `text` as `name="value"`. A name HTML reads as another is `.Unwritable`.
@(private)
put_attribute_text :: proc(w: ^Writer, name, text: string) -> core.Typed_Error_Kind {
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
	r := core.plain(v).(core.Node_Ref)
	span := string(r.doc.src[f.lo:][:f.n])
	if own_node(v) {
		w.kept += 1
		write.put_text(&w.out, span)
		return .None
	}
	if f.role == .Instruction || f.role == .Doctype || f.kind != .Plain {
		return .None
	}
	body, padded := core.comment_text(r.doc, f)
	if !holds_comment(body) {
		return .None
	}
	w.kept += 1
	put_comment(w, body, padded)
	return .None
}

@(private)
put_comment :: proc(w: ^Writer, body: string, padded: bool) {
	write.put_text(&w.out, "<!-- " if padded else "<!--")
	write.put_text(&w.out, body)
	write.put_text(&w.out, " -->" if padded else "-->")
}

// Writes comment bodies a value brings, each one HTML can hold.
@(private)
put_bodies :: proc(w: ^Writer, bodies: []string) {
	for body in bodies {
		if holds_comment(body) {
			put_comment(w, body, true)
		}
	}
}

// Writes the comments of `role` on `v`: those it brings, else its node's.
@(private)
put_comments :: proc(w: ^Writer, v: core.Value, facts: []core.Fact, role: core.Role) -> core.Typed_Error_Kind {
	if bodies, written := core.rebuilt_comments(v, role); written {
		if len(bodies) > 0 {
			start_foot(w)
		}
		put_bodies(w, bodies)
		return .None
	}
	for f in facts {
		if f.role == role {
			start_foot(w)
			put_fact(w, v, f) or_return
		}
	}
	return .None
}

@(private)
start_foot :: #force_inline proc(w: ^Writer) {
	switch {
	case w.foot_depth > 0:
		write.put_line(&w.out, w.opts, w.foot_depth)
	case w.foot_line:
		write.put_byte(&w.out, '\n')
		w.foot_line = false
	}
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
			digits: [spell.INT_ROOM]u8
			n := spell.u64_text(&digits[0], u64(r))
			write.put_text(&w.out, "&#")
			write.put_text(&w.out, string(digits[:n]))
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
