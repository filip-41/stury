package core

// The facts a document holds beside its nodes: comments, properties such as tags and anchors, and markup's
// attributes and instructions, with the readers of their bodies.

// A `Fact` holds a comment, property or attribute token, the node it belongs to and its role. Facts are sorted by the
// node they belong to, and two facts of one node keep their source order. `lo` is the first byte and `n` the span's
// length, markers included. `kind` is the kind of the token the fact came from: `Plain` for a comment, an attribute and
// a text tag, and `Number` for a binary format's numeric tag, whose span `fact_number` reads through the format's
// `number` as a node's is. A `Plain` fact's `spelling` has the marker's lead length in its low byte and its tail length
// in the next, so core slices a body without knowing a format's markers. A `//` comment leads with two bytes and trails
// none, a `/* */` comment leads and trails with two, and a delimited text's comment line leads with one. An attribute's
// `spelling` has the same layout: it leads through the value's opening quote and trails with the closing one, so its
// body is the value as written, and a valueless attribute leads with its whole span. A lead past 255 bytes is stored
// as 255, and then only the format's `attribute` finds the value. Only a comment role is a comment:
// a writer or an edit that walks facts by their markers tests the role first.
Fact :: struct {
	lo:       u64,
	node:     Node_Index,
	n:        u32,
	role:     Role,
	kind:     Kind,
	spelling: u16,
}

// The `spelling` of a comment token, from the length of its leading marker and of its trailing one. `Fact` documents
// the layout.
comment_spelling :: #force_inline proc "contextless" (lead, tail: u8) -> u16 {
	return u16(lead) | u16(tail) << 8
}

// The length of the leading marker of a comment token whose spelling is `spelling`.
comment_lead :: #force_inline proc "contextless" (spelling: u16) -> u64 {
	return u64(spelling & 0xFF)
}

// The length of the trailing marker of a comment token whose spelling is `spelling`.
comment_tail :: #force_inline proc "contextless" (spelling: u16) -> u64 {
	return u64(spelling >> 8)
}

// The kinds of fact. Each has a span of its role, or for `Style`, `Name`, `Namespace` and `Content` a node's spelling or
// shape holds it, see `fact_value`. `Style` is how a scalar or a collection is written (a quoting, a block or flow
// form). `Tag` may be held in the spelling too, as a TOML datetime's. `Name` is a markup element's name as written,
// `Namespace` its namespace URI, absent for a name in none, and `Content` its string value, its text and its
// descendants' in document order.
Fact_Kind :: enum u8 {
	Comment,
	Comment_Inline,
	Comment_Foot,
	Tag,
	Anchor,
	Alias,
	Style,
	Name,
	Namespace,
	Content,
	Instruction,
	Doctype,
	Directive,
	Attribute,
}

// How a fact kind is read and written: the name a filter reads it by after `.@`, the role of its span (`.Value` for a
// fact no span holds), whether an edit may write it, and its class.
Fact_Info :: struct {
	name:      string,
	role:      Role,
	read_only: bool,
	class:     Fact_Class,
}

// A comment has bodies of its role, a property one value read by `fact_value`, and markup's other facts are read by
// their role.
Fact_Class :: enum u8 {
	Comment,
	Property,
	Markup,
}

@(rodata)
FACTS := [Fact_Kind]Fact_Info {
	.Comment        = {"comment", .Comment, false, .Comment},
	.Comment_Inline = {"comment_inline", .Comment_Inline, false, .Comment},
	.Comment_Foot   = {"comment_foot", .Comment_Foot, false, .Comment},
	.Tag            = {"tag", .Tag, false, .Property},
	.Anchor         = {"anchor", .Anchor, false, .Property},
	.Alias          = {"alias", .Alias, false, .Property},
	.Style          = {"style", .Value, false, .Property},
	.Name           = {"name", .Value, true, .Property},
	.Namespace      = {"namespace", .Value, true, .Property},
	.Content        = {"content", .Value, true, .Property},
	.Instruction    = {"pi", .Instruction, true, .Markup},
	.Doctype        = {"doctype", .Doctype, true, .Markup},
	.Directive      = {"directives", .Directive, true, .Markup},
	.Attribute      = {"attrs", .Attribute, false, .Markup},
}

// The comment kinds, and the facts of an element that a markup format reads from its shape.
COMMENT_FACTS :: bit_set[Fact_Kind]{.Comment, .Comment_Inline, .Comment_Foot}
ELEMENT_FACTS :: bit_set[Fact_Kind]{.Name, .Namespace, .Content, .Attribute, .Doctype}

// The fact kind whose spans take `role`, and false for a role no fact has.
fact_of_role :: proc "contextless" (role: Role) -> (Fact_Kind, bool) {
	for info, k in FACTS {
		if info.role == role && role != .Value {
			return k, true
		}
	}
	return .Comment, false
}

// A named fact's value: its text, `numeric` when the text spells a number, as a CBOR tag does, `span` when a fact span
// holds it, which `subtree_facts` counts, and for a `Tag` its meaning.
Fact_Value :: struct {
	text:    string,
	numeric: bool,
	span:    bool,
	meaning: Tag_Meaning,
}

// What a tag says its value is, which every format with a tag of that meaning spells in its own syntax: a date and time
// with an offset, a date and time, a date or a time with none, and a byte string its text holds as base64. `Own` is a
// tag no other format spells. A datetime's text is RFC 3339's or the format's own spelling of it.
Tag_Meaning :: enum u8 {
	Own,
	Datetime,
	Local_Datetime,
	Local_Date,
	Local_Time,
	Binary,
}

// What a scalar's `Style` says, which each format names in its own words (`Readers.styles`) and writes in its own
// spelling where it has one, and in its default where it has none. `None` is a format's default spelling.
Scalar_Style :: enum u8 {
	None,
	Single, // one line between quotes with no escapes: YAML's single-quoted, TOML's literal
	Double, // one line between quotes with escapes: YAML's double-quoted
	Literal, // lines as written with no escapes: YAML's `|`, TOML's `'''`
	Folded, // YAML's `>`
	Multiline, // lines with escapes: TOML's `"""`
	Hex,
	Octal,
	Binary,
}

// A format's name of a scalar style.
Style_Name :: struct {
	name:  string,
	style: Scalar_Style,
}

// The scalar style named `name` in the format `readers` reads, and false for a name it has none of.
style_named :: proc "contextless" (readers: ^Readers, name: string) -> (Scalar_Style, bool) {
	if readers != nil && .Style in readers.holds {
		for s in readers.styles {
			if s.name == name {
				return s.style, true
			}
		}
	}
	return .None, false
}

// The style `v` is written in: the one written on it, else its node's, read in the words of the value's format.
value_style :: proc(v: Value) -> Scalar_Style {
	r, is_ref := facts_node(v)
	if !is_ref || .Style not_in r.doc.readers.holds {
		return .None
	}
	name: string
	if c, is_commented := v.(^Commented); is_commented && .Value in c.written {
		name = c.bodies[.Value][0] if len(c.bodies[.Value]) > 0 else ""
	} else {
		fv, held := fact_value(r.doc, r.node, .Style)
		if !held {
			return .None
		}
		name = fv.text
	}
	style, _ := style_named(r.doc.readers, name)
	return style
}

// Returns the value of node `i`'s property `name`: the body of its span fact of that role when it holds one (`Tag`,
// `Anchor` and `Alias`), else what the format's `fact` service reads from the node's spelling. Returns false for a node
// that has none and for a format with no such service. A `Number` fact, a binary format's tag, is read by the format's
// `fact` service when it has one, which gives the tag's digits, in the temp allocator.
fact_value :: proc(doc: ^Document, i: Node_Index, name: Fact_Kind) -> (v: Fact_Value, ok: bool) {
	if int(i) >= len(doc.nodes) {
		return
	}
	role := FACTS[name].role
	if role != .Value && len(doc.facts) > 0 {
		for f in all_facts(doc, i) {
			if f.role == role {
				v.span = true
				// A `Number` fact's span is its encoding, which a format with a `fact` service spells as digits.
				if f.kind != .Number || doc.readers == nil || doc.readers.fact == nil {
					v.text, v.numeric, ok = string(fact_body(doc, f)), f.kind == .Number, true
				}
				break
			}
		}
	}
	if !ok && doc.readers != nil && doc.readers.fact != nil {
		span := v.span
		v, ok = doc.readers.fact(doc, i, name)
		v.span = span
	}
	if ok && name == .Tag && doc.readers != nil && doc.readers.tag_meaning != nil {
		v.meaning = doc.readers.tag_meaning(doc, i, v.text)
	}
	return
}

// Whether a node of `doc` may have a tag: a fact span holds one, or a token's spelling does. A writer that asks no
// node of a document without one for its tag keeps an untagged document's write free of the question.
has_tags :: proc "contextless" (doc: ^Document) -> bool {
	if doc.spelled_tags {
		return true
	}
	for f in doc.facts {
		if f.role == .Tag {
			return true
		}
	}
	return false
}

// Whether `role` is a property fact, which stands before its node and is written by `Edit_Services.prefix`.
is_property :: #force_inline proc "contextless" (role: Role) -> bool {
	return role == .Tag || role == .Anchor || role == .Alias
}

// How a format spells a comment in an output: `line` starts a comment that runs to its line end, and `open` and `close`
// delimit a block comment, whose body holds no `close`. A body holding a line end is written as a block when the
// format has one, so a line comment's body cannot end its line early. The zero value spells no comment.
Comment_Syntax :: struct {
	line, open, close: string,
}

// The comment syntax of JSONC and JSON5.
SLASH_COMMENTS :: Comment_Syntax{line = "//", open = "/*", close = "*/"}

// The comment syntax of YAML and TOML.
HASH_COMMENTS :: Comment_Syntax{line = "#"}

// The comment syntax of XML and HTML.
MARKUP_COMMENTS :: Comment_Syntax{open = "<!--", close = "-->"}

// Whether syntax `s` spells a comment.
has_comments :: #force_inline proc "contextless" (s: Comment_Syntax) -> bool {
	return s.line != "" || s.open != ""
}

// Returns a walk over the bodies of node `i`'s facts of `role`, in source order, with `fact_next` giving one at a
// time. `NO_NODE` returns an empty walk. This is the public fact reader. A fact body is a slice of the source, so
// a read allocates nothing.
facts_of :: proc(doc: ^Document, i: Node_Index, role: Role) -> Fact_Iter {
	return {doc = doc, facts = all_facts(doc, i), role = role}
}

// Returns a walk over the attributes of the element whose value is node `i`, with `attribute_next` giving one at a
// time, none for a format with no attributes.
attributes_of :: proc(doc: ^Document, i: Node_Index) -> Attribute_Iter {
	return Attribute_Iter(facts_of(doc, i, .Attribute))
}

// A `Fact_Iter` walk reads the bodies of one node's facts of one role, in source order. `fact_next` returns one at a time.
Fact_Iter :: struct {
	doc:   ^Document,
	facts: []Fact,
	role:  Role,
}

// The walk `attributes_of` returns.
Attribute_Iter :: distinct Fact_Iter

// Returns the next body without the markers its format writes: the fact's `spelling` gives the lead and tail
// lengths, and core reads the bytes between them without knowing any format's marker.
fact_next :: proc(it: ^Fact_Iter) -> (body: string, ok: bool) {
	f := next_of_role(it) or_return
	return string(fact_body(it.doc, f)), true
}

// Returns the next comment's text as `comment_text` reads it.
comment_next :: proc(it: ^Fact_Iter) -> (text: string, padded: bool, ok: bool) {
	f := next_of_role(it) or_return
	text, padded = comment_text(it.doc, f)
	return text, padded, true
}

// Returns the next attribute's name as a `Key` token and its value as a `Value` token, as `Readers.attribute` reads them.
attribute_next :: proc(it: ^Attribute_Iter) -> (name, value: Token, ok: bool) {
	f := next_of_role((^Fact_Iter)(it)) or_return
	name, value = it.doc.readers.attribute(it.doc, f)
	return name, value, true
}

@(private)
next_of_role :: proc(it: ^Fact_Iter) -> (Fact, bool) {
	for len(it.facts) > 0 {
		f := it.facts[0]
		it.facts = it.facts[1:]
		if f.role == it.role {
			return f, true
		}
	}
	return {}, false
}

// Returns the text of comment fact `f` without its markers and the one space next to each, and whether a space
// followed its leading marker, which a writer gives back.
comment_text :: proc(doc: ^Document, f: Fact) -> (text: string, padded: bool) {
	text = string(fact_body(doc, f))
	if comment_lead(f.spelling) > 0 && len(text) > 0 && text[0] == ' ' {
		text, padded = text[1:], true
	}
	if comment_tail(f.spelling) > 0 && len(text) > 0 && text[len(text) - 1] == ' ' {
		text = text[:len(text) - 1]
	}
	return
}

// Returns the facts of node `i` and of every node in its subtree, all the document's for the root.
subtree_facts :: proc(doc: ^Document, i: Node_Index) -> []Fact {
	if i == ROOT {
		return doc.facts
	}
	t := doc.nodes[i]
	end := i + (1 if t.kind < .Array else Node_Index(t.n))
	return doc.facts[lower_node(doc.facts, i):lower_node(doc.facts, end)]
}

// Returns node `i`'s facts of every role, sorted by node and then source order. Core's edit and span code walk
// them, and a caller reads one role at a time through `facts_of`.
all_facts :: #force_inline proc(doc: ^Document, i: Node_Index) -> []Fact {
	if i == NO_NODE {
		return nil
	}
	return doc.facts[lower_node(doc.facts, i):lower_node(doc.facts, i + 1)]
}

// Returns the number fact `f` writes, which is a `Number` fact like a CBOR tag, read as its token through the format's
// `number`, and false for any other fact.
fact_number :: proc(doc: ^Document, f: Fact) -> (Number, bool) {
	if f.kind != .Number {
		return {}, false
	}
	return doc.readers.number(&doc.view, {lo = f.lo, n = f.n, kind = f.kind, role = f.role, spelling = f.spelling})
}

// A fact that is not `Plain` has no markers: its `spelling` is its token's, and its body is the whole span.
@(private)
fact_body :: #force_inline proc(doc: ^Document, f: Fact) -> []u8 {
	if f.kind != .Plain {
		return doc.src[f.lo:f.lo + u64(f.n)]
	}
	return doc.src[f.lo + comment_lead(f.spelling) : f.lo + u64(f.n) - comment_tail(f.spelling)]
}
