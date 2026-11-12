package html

// Foreign content, the standard's section 13.2.6.5: the tokens whose adjusted current node is an SVG or MathML
// element, the integration points that read HTML inside it, and the adjusted names of SVG elements and foreign
// attributes. A name is adjusted when it is read, from FOREIGN_NAMES, so a node stores its name as written.

// The namespace of an adjusted foreign attribute.
@(private)
Attribute_Namespace :: enum u8 {
	None,
	Xlink,
	Xml,
	Xmlns,
}

@(private)
Foreign_Kind :: enum u8 {
	Svg_Element, // an SVG element name the standard writes in mixed case
	Svg_Attribute, // an SVG attribute name the standard writes in mixed case
	Math_Attribute, // a MathML attribute name the standard writes in mixed case
	Foreign_Attribute, // an attribute of SVG and MathML elements in the XLink, XML or XMLNS namespace
	Math_Text, // a MathML text integration point
	Math_Annotation, // `annotation-xml`, an HTML integration point when its `encoding` is HTML
	Svg_Integration, // an SVG HTML integration point
}

// A name foreign content adjusts or treats by name: `key` its ASCII lowercase, `name` the local name it reads as, and
// `prefix` and `ns` a foreign attribute's.
@(private)
Foreign_Name :: struct {
	key, name, prefix: string,
	ns:                Attribute_Namespace,
	kinds:             bit_set[Foreign_Kind; u8],
}

// The flags of the foreign elements the dispatcher reads some tokens of as HTML, and of those that are special and
// bound a scope.
@(private)
INTEGRATION :: Node_Flags{.Integration, .Text_Integration}
@(private)
BOUNDARY :: Node_Flags{.Integration, .Text_Integration, .Annotation}

// The first eight bytes of the `n` bytes at `p`, each with its 0x20 bit set, loaded little-endian and mixed with `n`:
// the key TAG_SLOTS and FOREIGN_SLOTS hash.
@(private)
name_key :: #force_inline proc "contextless" (p: [^]u8, n: u32) -> u64 #no_bounds_check {
	w: u64
	// The caller holds `n` bytes at `p`.
	for i in 0 ..< min(n, 8) {
		w |= u64(p[i] | 0x20) << (8 * i)
	}
	return w ~ u64(n)
}

// The index in FOREIGN_NAMES of the name of `n` bytes at `p`, ASCII case folded, 0 for none.
@(private)
foreign_of :: proc "contextless" (p: [^]u8, n: u32) -> int #no_bounds_check {
	if n == 0 || n > FOREIGN_LONGEST {
		return 0
	}
	h := (name_key(p, n) * FOREIGN_MUL) >> (64 - FOREIGN_BITS)
	for {
		// A slot is below 1 << FOREIGN_BITS and holds an index of FOREIGN_NAMES.
		i := int(FOREIGN_SLOTS[h])
		if i == 0 {
			return 0
		}
		key := FOREIGN_NAMES[i].key
		if len(key) == int(n) && fold_equal(p, transmute([]u8)key) {
			return i
		}
		h = (h + 1) & (1 << FOREIGN_BITS - 1)
	}
}

// The FOREIGN_NAMES entry of a name span of `src`, the empty entry for none.
@(private)
foreign_name :: proc "contextless" (src: []u8, s: Span) -> ^Foreign_Name {
	if s.flags & {.Nul, .Invalid} != {} {
		return &FOREIGN_NAMES[0]
	}
	return &FOREIGN_NAMES[foreign_of(raw_data(src)[s.lo:], s.n)]
}

// The flags of an element of namespace `ns` named by FOREIGN_NAMES entry `f`. An `annotation-xml` element is an HTML
// integration point when `html` says its `encoding` names HTML.
@(private)
foreign_flags :: proc "contextless" (f: ^Foreign_Name, ns: Namespace, html: bool) -> (flags: Node_Flags) {
	switch ns {
	case .Html:
	case .Math:
		if .Math_Text in f.kinds {
			flags += {.Text_Integration}
		}
		if .Math_Annotation in f.kinds {
			flags += {.Annotation, .Integration} if html else {.Annotation}
		}
	case .Svg:
		if .Svg_Integration in f.kinds {
			flags += {.Integration}
		}
	}
	return
}

// The adjusted current node: the context element while a fragment's stack holds only its root, else the current node.
@(private)
adjusted_current :: #force_inline proc(t: ^Html_Tree) -> ^Tree_Node {
	if t.context_element != 0 && len(t.stack) == 1 {
		return &t.nodes[t.context_element]
	}
	return current_node(t)
}

// Whether the adjusted current node is outside the HTML namespace, where the tokenizer opens CDATA sections.
@(private)
in_foreign_content :: #force_inline proc(t: ^Html_Tree) -> bool {
	return len(t.stack) > 0 && adjusted_current(t).ns != .Html
}

// Whether the tree construction dispatcher reads `tok` by the rules of foreign content rather than the insertion mode,
// once the adjusted current node is outside the HTML namespace.
@(private)
foreign_token :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	n := adjusted_current(t)
	#partial switch tok.kind {
	case .Start_Tag:
		switch {
		case .Text_Integration in n.flags:
			return t.tag == .Mglyph || t.tag == .Malignmark
		case .Integration in n.flags:
			return false
		case .Annotation in n.flags:
			return t.tag != .Svg
		}
	case .Text:
		return n.flags & INTEGRATION == {}
	case EOF:
		return false
	}
	return true
}

// Inserts a foreign element of namespace `ns` for start tag `tok` and pushes it.
@(private)
insert_foreign :: proc(t: ^Html_Tree, tok: ^Html_Token, ns: Namespace) {
	n := element_for(t, tok, t.tag, ns)
	if t.oom {
		return
	}
	f := foreign_name(t.src, tok.name)
	html := false
	if .Math_Annotation in f.kinds {
		_, html = attr_value_is(t, tok.attrs, "encoding", "text/html")
		if !html {
			_, html = attr_value_is(t, tok.attrs, "encoding", "application/xhtml+xml")
		}
	}
	t.nodes[n].flags += foreign_flags(f, ns, html)
	insert_node(t, n)
	t.foreign_open += 1
}

// The rules for parsing tokens in foreign content. Returns whether the token is to be read again in the insertion
// mode, as a tag that breaks out of foreign content is.
@(private)
foreign_rules :: proc(t: ^Html_Tree, tok: ^Html_Token) -> (again: bool) {
	switch tok.kind {
	case .Text:
		// Foreign content keeps U+0000 as U+FFFD, in text and in a CDATA section.
		s := tok.data
		if s.mode == .Text {
			s.mode = .Rcdata
		}
		insert_text(t, s)
		if t.frameset_ok && has_text(t, s) {
			t.frameset_ok = false
		}
	case .Comment:
		insert_comment(t, tok)
	case .Instruction:
		insert_instruction(t, tok)
	case .Doctype:
		misplaced(t, .Unexpected_Doctype)
	case .Start_Tag:
		if .Breakout in TAG_CLASSES[t.tag] || t.tag == .Font && font_breaks_out(t, tok) {
			misplaced(t, .Unexpected_Start_Tag)
			pop_to_html(t)
			return true
		}
		insert_foreign(t, tok, adjusted_current(t).ns)
		if .Self_Closing in tok.flags {
			pop_current(t)
			acknowledge(t)
		}
	case .End_Tag:
		if t.tag == .Br || t.tag == .P {
			misplaced(t, .Unexpected_End_Tag)
			pop_to_html(t)
			return true
		}
		return foreign_end_tag(t, tok)
	case EOF:
	}
	return false
}

// Whether a `font` start tag has a `color`, `face` or `size` attribute, which breaks out of foreign content.
@(private)
font_breaks_out :: proc(t: ^Html_Tree, tok: ^Html_Token) -> bool {
	for name in ([?]string{"color", "face", "size"}) {
		if found, _ := attr_value_is(t, tok.attrs, name, ""); found {
			return true
		}
	}
	return false
}

// Pops until the current node is an HTML element or an integration point.
@(private)
pop_to_html :: proc(t: ^Html_Tree) {
	for len(t.stack) > 0 {
		n := current_node(t)
		if n.ns == .Html || n.flags & INTEGRATION != {} {
			return
		}
		pop_current(t)
	}
}

// An end tag in foreign content closes the nearest open element of its name, ASCII case folded, that no HTML element
// stands above. Returns whether the token is to be read in the insertion mode, at the first HTML element.
@(private)
foreign_end_tag :: proc(t: ^Html_Tree, tok: ^Html_Token) -> (again: bool) {
	i := len(t.stack) - 1
	if !same_name(t, &t.nodes[t.stack[i]], tok) {
		misplaced(t, .Unexpected_End_Tag)
	}
	for i > 0 {
		if same_name(t, &t.nodes[t.stack[i]], tok) {
			pop_to(t, i)
			return false
		}
		i -= 1
		if t.nodes[t.stack[i]].ns == .Html {
			return true
		}
	}
	return false
}

// Whether element `n`'s name is tag `tok`'s, ASCII case folded.
@(private)
same_name :: #force_inline proc(t: ^Html_Tree, n: ^Tree_Node, tok: ^Html_Token) -> bool {
	return n.tag == t.tag && (t.tag != .Other || names_equal(raw_data(t.src), n.name, tok.name))
}

// The local name an element reads as, ASCII lowered and with SVG's mixed case restored.
@(private)
element_name :: proc(t: ^Html_Tree, n: ^Tree_Node) -> string {
	if n.ns == .Svg {
		if f := foreign_name(t.src, n.name); .Svg_Element in f.kinds {
			return f.name
		}
	}
	return TAG_NAMES[n.tag] if n.tag != .Other else decoded(t, n.name, 0)
}

// The namespace and local name attribute `a` of element `n` reads as, adjusted for SVG and MathML.
@(private)
attribute_name :: proc(t: ^Html_Tree, n: ^Tree_Node, a: ^Attribute) -> (ns: Attribute_Namespace, name: string) {
	if n.ns != .Html {
		f := foreign_name(t.src, a.name)
		if .Foreign_Attribute in f.kinds || .Svg_Attribute in f.kinds && n.ns == .Svg || .Math_Attribute in f.kinds && n.ns == .Math {
			return f.ns, f.name
		}
	}
	return .None, decoded(t, a.name, 0)
}
