package html

import "base:runtime"
import core "../core"

// The tree construction of the standard's section 13.2.6, which reads the tokenizer's tokens into a document: the
// stack of open elements, the list of active formatting elements, the adoption agency and foster parenting. The
// insertion modes are in modes.odin and foreign content in foreign.odin. The tree is a linked arena, since the
// algorithm inserts before a table, moves children and clones elements. Node 0 is no node and node 1 the document. A
// template's contents are its children, and a fragment's nodes the children of its root, the document's one element.

@(private)
Node_Kind :: enum u8 {
	Document,
	Doctype,
	Element,
	Text,
	Comment,
	Instruction,
}

@(private)
Node_Flag :: enum u8 {
	Implied, // no tag of the source opened it
	Cloned, // a copy of an element, made when formatting is reopened or by the adoption agency
	Moved, // placed away from where its source sits: foster parented, or reparented by the adoption agency
	Open, // on the stack of open elements
	Integration, // an HTML integration point: SVG `foreignObject`, `desc` and `title`, an HTML `annotation-xml`
	Text_Integration, // a MathML text integration point: `mi`, `mo`, `mn`, `ms` and `mtext`
	Annotation, // a MathML `annotation-xml`
}

@(private)
Node_Flags :: bit_set[Node_Flag; u8]

// A node of the tree. `lo` and `hi` are the bytes of the token that made it, the position of the token that implied
// it for an `.Implied` element. `end` is the byte past an element once it is off the stack of open elements: past its
// end tag when that tag closed it, else where the token that closed it starts, and never before `hi`. `name` is an element's name as written, empty for an implied one, a comment's data, an
// instruction's target or a DOCTYPE's name. An element's attributes are `attrs[a:][:b]`, a text's characters the
// pieces from `a` to `b`, and an instruction's data piece `a`.
@(private)
Tree_Node :: struct {
	lo, hi, end:                     u64,
	name:                            Span,
	parent, first, last, prev, next: u32,
	a, b:                            u32,
	kind:                            Node_Kind,
	ns:                              Namespace,
	tag:                             Tag,
	flags:                           Node_Flags,
}

// A run of a text's characters. A text inserted next to a text it extends grows its last piece.
@(private)
Piece :: struct {
	span: Span,
	next: u32,
}

@(private)
Quirks :: enum u8 {
	No,
	Limited,
	Quirks,
}

@(private)
Insertion_Mode :: enum u8 {
	Initial,
	Before_Html,
	Before_Head,
	In_Head,
	In_Head_Noscript,
	After_Head,
	In_Body,
	Text,
	In_Table,
	In_Table_Text,
	In_Caption,
	In_Column_Group,
	In_Table_Body,
	In_Row,
	In_Cell,
	After_Body,
	In_Frameset,
	After_Frameset,
	After_After_Body,
	After_After_Frameset,
	In_Template,
}

// A parse error: what it is and the byte it was found at.
@(private)
Parse_Error :: struct {
	at:     u64,
	detail: Detail,
}

@(private)
Html_Tree :: struct {
	src:             []u8,
	nodes:           [dynamic]Tree_Node,
	attrs:           [dynamic]Attribute,
	pieces:          [dynamic]Piece,
	stack:           [dynamic]u32, // the stack of open elements, the current node last
	active:          [dynamic]u32, // the list of active formatting elements, 0 a marker
	templates:       [dynamic]Insertion_Mode, // the stack of template insertion modes
	pending:         [dynamic]Span, // the pending table character tokens
	scratch:         [dynamic]u8, // decoded text a comparison reads
	public_id:       Span, // the DOCTYPE's
	system_id:       Span,
	head, form:      u32, // the element pointers
	foreign_open:    u32, // the foreign elements on the stack of open elements, and a fragment's foreign context
	context_element: u32, // a fragment's context element, outside the tree, or 0 for a document
	tag:             Tag, // the current tag token's
	mode:            Insertion_Mode,
	original:        Insertion_Mode,
	quirks:          Quirks,
	action:          Token_Action, // the hook's answer to the current token
	encoding:        Encoding, // the document's, as the sniffing or a `meta` names it
	frameset_ok:     bool,
	foster:          bool, // foster parenting is enabled
	skip_lf:         bool, // a line feed that is the next token is dropped
	acknowledged:    bool, // the current start tag's self-closing flag was acknowledged
	pending_text:    bool, // a pending table character is not whitespace
	scripting:       bool,
	in_foreign:      bool, // the tokenizer was last told the adjusted current node is outside the HTML namespace
	selected:        bool, // a `selectedcontent` element was inserted, so a popped option may be copied into it
	tentative:       bool, // no mark or prescan named the encoding, so a `meta` the tree reads may
	misread:         bool, // a `meta` named an encoding that reads the text otherwise than UTF-8
	oom:             bool,
	too_deep:        bool,
	max_depth:       int,
	at:              u64, // where the current token starts
	tok:             ^Html_Token, // the current token, nil before the first
	errors:          [dynamic]Parse_Error, // the tokenizer's included, in the order they were found
	ctx:             runtime.Context,
}

// The categories of an element. A foreign element has none of the HTML elements' categories, and an integration point
// or `annotation-xml` is special and bounds a scope.
@(private)
classes :: #force_inline proc "contextless" (n: ^Tree_Node) -> Tag_Classes {
	if n.ns == .Html {
		return TAG_CLASSES[n.tag]
	}
	return {.Special, .Scope} if n.flags & BOUNDARY != {} else {}
}

@(private)
is_html :: #force_inline proc "contextless" (n: ^Tree_Node, tag: Tag) -> bool {
	return n.tag == tag && n.ns == .Html
}

// The tag of a name, `.Other` for one the tree construction does not treat by name.
@(private)
tag_of :: proc "contextless" (src: []u8, name: Span) -> Tag #no_bounds_check {
	if name.n == 0 || name.n > TAG_LONGEST || name.flags & {.Nul, .Invalid} != {} {
		return .Other
	}
	// The name lies in `src`, and `n` caps the bytes read.
	p := raw_data(src)[name.lo:]
	h := (name_key(p, name.n) * TAG_MUL) >> (64 - TAG_BITS)
	for {
		tag := Tag(TAG_SLOTS[h])
		if tag == .Other {
			return .Other
		}
		s := TAG_NAMES[tag]
		if len(s) == int(name.n) && fold_equal(p, transmute([]u8)s) {
			return tag
		}
		h = (h + 1) & (1 << TAG_BITS - 1)
	}
}

// Reads `src` into a tree: a document, or for `.Fragment` the nodes of a fragment whose context element `opts` names,
// from byte `lo`, past the sniffed byte order mark for a document read from its first byte. A tree always builds: the faults are `.No_Memory`, `.Too_Wide` at a span longer than 4 GiB, `.Too_Deep` where the
// stack of open elements would pass `opts.max_depth`, and `.Bad_Char` with `.Encoding` where a document's byte order
// mark or `meta` names an encoding other than UTF-8 and its bytes would read otherwise.
@(private)
build_tree :: proc(src: []u8, spec: Spec, opts: Read, lo := u64(0), allocator := context.allocator) -> (t: Html_Tree, fault: Maybe(core.Fault)) {
	from := min(lo, u64(len(src)))
	if spec == .Document && lo == 0 {
		found: bool
		from, t.encoding, found = sniff(src) or_return
		t.tentative = !found
	}
	context.allocator = allocator
	t.src = src
	t.ctx = context
	t.max_depth = int(opts.max_depth) if opts.max_depth != 0 else core.MAX_DEPTH
	t.scripting = opts.scripting
	t.frameset_ok = true
	estimate := len(src) / 32 + 16
	t.nodes = make([dynamic]Tree_Node, 0, estimate)
	t.pieces = make([dynamic]Piece, 0, estimate / 2)
	t.attrs = make([dynamic]Attribute, 0, estimate / 2)
	t.stack = make([dynamic]u32, 0, 64)
	if t.nodes == nil || t.pieces == nil || t.attrs == nil || t.stack == nil {
		tree_destroy(&t)
		return {}, core.Fault{rules = &RULES, kind = .No_Memory}
	}
	append(&t.nodes, Tree_Node{}, Tree_Node{kind = .Document})
	append(&t.pieces, Piece{})
	start := Content.Data
	if spec == .Fragment {
		start = begin_fragment(&t, opts.fragment)
	}
	_, fault, _ = tokenize(src, &t, on_token, start, from = from, in_foreign = t.in_foreign, allocator = allocator)
	if fault == nil && !t.oom && !t.too_deep && !t.misread {
		eof := Html_Token{kind = EOF, lo = u64(len(src)), hi = u64(len(src))}
		t.at = eof.lo
		t.tok = &eof
		dispatch(&t, &eof)
		pop_to(&t, 0)
		t.tok = nil
	}
	switch {
	case t.oom:
		fault = core.Fault{rules = &RULES, kind = .No_Memory}
	case t.too_deep:
		fault = core.Fault{at = t.at, rules = &RULES, kind = .Too_Deep}
	case t.misread:
		fault = core.Fault{at = t.at, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Encoding)}
	}
	if fault != nil {
		tree_destroy(&t)
		return {}, fault
	}
	return
}

// Starts a fragment's tree: its context element, outside the tree, and its root, the `html` element its nodes go in.
// Returns the text state the context's content is read in.
@(private)
begin_fragment :: proc(t: ^Html_Tree, c: Context) -> (start: Content) {
	ns, tag := c.ns, c.tag
	f := &FOREIGN_NAMES[c.name]
	t.context_element = new_node(t, {kind = .Element, ns = ns, tag = tag, flags = {.Implied} + foreign_flags(f, ns, false)})
	root := implied(t, .Html)
	if t.oom {
		return
	}
	link(t, DOCUMENT, root, 0)
	push(t, root)
	t.in_foreign = ns != .Html
	t.foreign_open = u32(t.in_foreign)
	if !t.in_foreign {
		#partial switch tag {
		case .Template:
			if _, err := append(&t.templates, Insertion_Mode.In_Template); err != nil {
				t.oom = true
			}
		case .Form:
			t.form = t.context_element
		}
	}
	reset_insertion_mode(t)
	if t.in_foreign {
		return .Data
	}
	#partial switch tag {
	case .Title, .Textarea:
		return .Rcdata
	case .Style, .Xmp, .Iframe, .Noembed, .Noframes:
		return .Rawtext
	case .Noscript:
		return .Rawtext if t.scripting else .Data
	case .Script:
		return .Script_Data
	case .Plaintext:
		return .Plaintext
	}
	return .Data
}

@(private)
tree_destroy :: proc(t: ^Html_Tree) {
	delete(t.nodes)
	delete(t.attrs)
	delete(t.pieces)
	delete(t.stack)
	delete(t.active)
	delete(t.templates)
	delete(t.errors)
	delete(t.pending)
	delete(t.scratch)
	t^ = {}
}

@(private)
parse_error :: proc(t: ^Html_Tree, d: Detail, at: u64) {
	if _, err := append(&t.errors, Parse_Error{at = at, detail = d}); err != nil {
		t.oom = true
	}
}

// A parse error of the tree construction at the current token.
@(private)
misplaced :: #force_inline proc(t: ^Html_Tree, d: Detail) {
	parse_error(t, d, t.at)
}

@(private)
new_node :: proc(t: ^Html_Tree, n: Tree_Node) -> u32 {
	if _, err := append(&t.nodes, n); err != nil {
		t.oom = true
		return 0
	}
	return u32(len(t.nodes) - 1)
}

// A new element for start tag `tok`, its attributes copied, since a token's attributes live only during the hook.
@(private)
element_for :: proc(t: ^Html_Tree, tok: ^Html_Token, tag: Tag, ns := Namespace.Html) -> u32 {
	a := len(t.attrs)
	if _, err := append(&t.attrs, ..tok.attrs); err != nil {
		t.oom = true
	}
	return new_node(t, {kind = .Element, ns = ns, tag = tag, name = tok.name, lo = tok.lo, hi = tok.hi, a = u32(a), b = u32(len(tok.attrs))})
}

// A new element no tag of the source opened.
@(private)
implied :: proc(t: ^Html_Tree, tag: Tag) -> u32 {
	return new_node(t, {kind = .Element, tag = tag, flags = {.Implied}, lo = t.at, hi = t.at})
}

// A new element for the token `n` was made for, sharing its attributes.
@(private)
clone_node :: proc(t: ^Html_Tree, n: u32) -> u32 {
	c := t.nodes[n]
	c.parent, c.first, c.last, c.prev, c.next = 0, 0, 0, 0, 0
	c.flags = c.flags - {.Open, .Moved} + {.Cloned}
	return new_node(t, c)
}

// Inserts `n` into `parent` before `before`, or last for 0.
@(private)
link :: proc(t: ^Html_Tree, parent, n, before: u32) {
	nodes := t.nodes[:]
	nodes[n].parent = parent
	nodes[n].next = before
	prev := nodes[before].prev if before != 0 else nodes[parent].last
	nodes[n].prev = prev
	if prev != 0 {
		nodes[prev].next = n
	} else {
		nodes[parent].first = n
	}
	if before != 0 {
		nodes[before].prev = n
	} else {
		nodes[parent].last = n
	}
}

// Removes `n` from its parent, if it has one.
@(private)
unlink :: proc(t: ^Html_Tree, n: u32) {
	nodes := t.nodes[:]
	parent := nodes[n].parent
	if parent == 0 {
		return
	}
	prev, next := nodes[n].prev, nodes[n].next
	if prev != 0 {
		nodes[prev].next = next
	} else {
		nodes[parent].first = next
	}
	if next != 0 {
		nodes[next].prev = prev
	} else {
		nodes[parent].last = prev
	}
	nodes[n].parent, nodes[n].prev, nodes[n].next = 0, 0, 0
}

@(private)
is_inclusive_ancestor :: proc(t: ^Html_Tree, a, n: u32) -> bool {
	for m := n; m != 0; m = t.nodes[m].parent {
		if m == a {
			return true
		}
	}
	return false
}

@(private)
current :: #force_inline proc(t: ^Html_Tree) -> u32 {
	return t.stack[len(t.stack) - 1]
}

@(private)
current_node :: #force_inline proc(t: ^Html_Tree) -> ^Tree_Node {
	return &t.nodes[t.stack[len(t.stack) - 1]]
}

@(private)
push :: proc(t: ^Html_Tree, n: u32) {
	if len(t.stack) >= t.max_depth {
		t.too_deep = true
		return
	}
	if _, err := append(&t.stack, n); err != nil {
		t.oom = true
		return
	}
	t.nodes[n].flags += {.Open}
}

@(private)
pop_current :: #force_inline proc(t: ^Html_Tree) {
	n := pop(&t.stack)
	unstacked(t, n)
	if t.nodes[n].tag == .Option && t.selected {
		show_selected_option(t, n)
	}
}

// Marks element `n` as taken off the stack of open elements.
@(private)
unstacked :: #force_inline proc(t: ^Html_Tree, n: u32) {
	node := &t.nodes[n]
	node.flags -= {.Open}
	if node.ns != .Html {
		t.foreign_open -= 1
	}
	ended(t, n)
}

// Sets the end of element `n`, which the current token closes: past it when it is the element's end tag.
@(private)
ended :: proc "contextless" (t: ^Html_Tree, n: u32) {
	node := &t.nodes[n]
	end := t.at
	if tok := t.tok; tok != nil && tok.kind == .End_Tag && node.tag == t.tag && (node.tag != .Other || names_equal(raw_data(t.src), node.name, tok.name)) {
		end = tok.hi
	}
	node.end = max(end, node.hi)
}

// Pops the stack down to its first `depth` elements.
@(private)
pop_to :: proc(t: ^Html_Tree, depth: int) {
	for len(t.stack) > depth {
		pop_current(t)
	}
}

// Pops elements until an HTML element of a tag in `tags` is popped.
@(private)
pop_until :: proc(t: ^Html_Tree, tags: Tags) {
	for len(t.stack) > 0 {
		n := current_node(t)
		pop_current(t)
		if n.tag in tags && n.ns == .Html {
			return
		}
	}
}

@(private)
remove_from_stack :: proc(t: ^Html_Tree, n: u32) {
	#reverse for m, i in t.stack {
		if m == n {
			ordered_remove(&t.stack, i)
			unstacked(t, n)
			return
		}
	}
}

@(private)
stack_index :: proc(t: ^Html_Tree, n: u32) -> int {
	#reverse for m, i in t.stack {
		if m == n {
			return i
		}
	}
	return -1
}

@(private)
Tags :: bit_set[Tag; u128]

// The categories that bound each scope.
@(private)
SCOPE :: Tag_Classes{.Scope}
@(private)
LIST_SCOPE :: Tag_Classes{.Scope, .List_Scope}
@(private)
BUTTON_SCOPE :: Tag_Classes{.Scope, .Button_Scope}
@(private)
TABLE_SCOPE :: Tag_Classes{.Table_Scope}

// Whether the stack has an HTML element of a tag in `tags` in the scope `bound` closes.
@(private)
in_scope :: proc(t: ^Html_Tree, tags: Tags, bound := SCOPE) -> bool {
	#reverse for m in t.stack {
		n := &t.nodes[m]
		if n.tag in tags && n.ns == .Html {
			return true
		}
		if classes(n) & bound != {} {
			return false
		}
	}
	return false
}

@(private)
node_in_scope :: proc(t: ^Html_Tree, target: u32, bound := SCOPE) -> bool {
	#reverse for m in t.stack {
		if m == target {
			return true
		}
		if classes(&t.nodes[m]) & bound != {} {
			return false
		}
	}
	return false
}

// Pops the elements the standard closes with implied end tags, `except` excluded, or with the implied end tags it
// generates thoroughly for `.Thorough_End`.
@(private)
close_implied :: proc(t: ^Html_Tree, except := Tag.Other, class := Tag_Class.Implied_End) {
	for len(t.stack) > 0 {
		n := current_node(t)
		if class not_in classes(n) || n.tag == except {
			return
		}
		pop_current(t)
	}
}

@(private)
has_template :: proc(t: ^Html_Tree) -> bool {
	#reverse for m in t.stack {
		if is_html(&t.nodes[m], .Template) {
			return true
		}
	}
	return false
}

// Whether the tokens go into a template's contents, with a template element open or in a fragment whose context is
// one: the form rules then leave the form element pointer alone. The stack of template insertion modes is empty
// otherwise.
@(private)
in_template_contents :: #force_inline proc(t: ^Html_Tree) -> bool {
	return len(t.templates) > 0
}

// Whether the tree is a fragment whose context element is a `select`, where an `input` or `select` start tag is
// ignored.
@(private)
in_select_context :: #force_inline proc(t: ^Html_Tree) -> bool {
	return t.context_element != 0 && is_html(&t.nodes[t.context_element], .Select)
}

// Pops until the current node is an HTML element of the `context` category.
@(private)
clear_to :: proc(t: ^Html_Tree, ctx: Tag_Class) {
	for !(ctx in classes(current_node(t))) {
		pop_current(t)
	}
}

// Closes a `p` element.
@(private)
close_p :: proc(t: ^Html_Tree) {
	close_implied(t, .P)
	if !is_html(current_node(t), .P) {
		misplaced(t, .Unclosed_Element)
	}
	pop_until(t, {.P})
}

// Closes a `p` element when one is in button scope.
@(private)
close_open_p :: #force_inline proc(t: ^Html_Tree) {
	if in_scope(t, {.P}, BUTTON_SCOPE) {
		close_p(t)
	}
}

// Reports an element the stack holds that its end leaves open with a parse error.
@(private)
check_open_at_end :: proc(t: ^Html_Tree) {
	for m in t.stack {
		if .Open_At_End not_in classes(&t.nodes[m]) {
			misplaced(t, .Unclosed_Element)
			return
		}
	}
}

// The appropriate place for inserting a node, in `target` or the current node: its parent, the child it goes before
// (0 for last), and whether it was foster parented.
@(private)
place :: proc(t: ^Html_Tree, target: u32 = 0) -> (parent, before: u32, fostered: bool) {
	parent = target if target != 0 else current(t)
	if !t.foster || .Foster not_in classes(&t.nodes[parent]) {
		return parent, 0, false
	}
	#reverse for m, i in t.stack {
		n := &t.nodes[m]
		if is_html(n, .Template) {
			return m, 0, true
		}
		if !is_html(n, .Table) {
			continue
		}
		if p := n.parent; p != 0 {
			return p, m, true
		}
		return t.stack[i - 1], 0, true
	}
	return t.stack[0], 0, true
}

// Inserts element `n` at the appropriate place and pushes it.
@(private)
insert_node :: proc(t: ^Html_Tree, n: u32) {
	if t.oom {
		return
	}
	parent, before, fostered := place(t)
	link(t, parent, n, before)
	if fostered {
		t.nodes[n].flags += {.Moved}
	}
	push(t, n)
}

// Inserts an HTML element for start tag `tok` and pushes it.
@(private)
insert_for :: proc(t: ^Html_Tree, tok: ^Html_Token, ns := Namespace.Html) -> u32 {
	n := element_for(t, tok, t.tag, ns)
	insert_node(t, n)
	return n
}

// Inserts an implied HTML element and pushes it.
@(private)
insert_implied :: proc(t: ^Html_Tree, tag: Tag) -> u32 {
	n := implied(t, tag)
	insert_node(t, n)
	return n
}

// Inserts the characters of `s` at the appropriate place, into the text before it when there is one.
@(private)
insert_text :: proc(t: ^Html_Tree, s: Span) {
	if s.n == 0 || t.oom || s.mode == .Text && only_nul(t, s) {
		return
	}
	parent, before, fostered := place(t)
	if t.nodes[parent].kind == .Document {
		return
	}
	prev := t.nodes[before].prev if before != 0 else t.nodes[parent].last
	if prev != 0 && t.nodes[prev].kind == .Text {
		extend_text(t, prev, s)
		return
	}
	piece := add_piece(t, s)
	n := new_node(t, {kind = .Text, lo = s.lo, hi = s.lo + u64(s.n), a = piece, b = piece, flags = {.Moved} if fostered else {}})
	if n != 0 {
		link(t, parent, n, before)
	}
}

@(private)
add_piece :: proc(t: ^Html_Tree, s: Span) -> u32 {
	if _, err := append(&t.pieces, Piece{span = s}); err != nil {
		t.oom = true
		return 0
	}
	return u32(len(t.pieces) - 1)
}

// Appends `s` to text `n`, growing its last piece when `s` continues it in the source.
@(private)
extend_text :: proc(t: ^Html_Tree, n: u32, s: Span) {
	text := &t.nodes[n]
	last := &t.pieces[text.b]
	if last.span.lo + u64(last.span.n) == s.lo && last.span.mode == s.mode && u64(last.span.n) + u64(s.n) <= u64(max(u32)) {
		last.span.n += s.n
		last.span.flags += s.flags
	} else {
		p := add_piece(t, s)
		t.pieces[t.nodes[n].b].next = p
		t.nodes[n].b = p
	}
	t.nodes[n].hi = s.lo + u64(s.n)
}

// Inserts comment `tok` into `parent`, or at the appropriate place for 0.
@(private)
insert_comment :: proc(t: ^Html_Tree, tok: ^Html_Token, parent: u32 = 0) {
	at, before := parent, u32(0)
	if at == 0 {
		at, before, _ = place(t)
	}
	n := new_node(t, {kind = .Comment, name = tok.data, lo = tok.lo, hi = tok.hi})
	if n != 0 {
		link(t, at, n, before)
	}
}

// Inserts processing instruction `tok` into `parent`, or at the appropriate place for 0.
@(private)
insert_instruction :: proc(t: ^Html_Tree, tok: ^Html_Token, parent: u32 = 0) {
	at, before := parent, u32(0)
	if at == 0 {
		at, before, _ = place(t)
	}
	data := add_piece(t, tok.data)
	n := new_node(t, {kind = .Instruction, name = tok.name, lo = tok.lo, hi = tok.hi, a = data})
	if n != 0 {
		link(t, at, n, before)
	}
}

// Adds attributes of `tok` that element `n` lacks, for an `html` or `body` start tag seen again.
@(private)
merge_attrs :: proc(t: ^Html_Tree, n: u32, tok: ^Html_Token) {
	for attr in tok.attrs {
		node := &t.nodes[n]
		if has_attr(t, node, attr.name) {
			continue
		}
		// An element's attributes are one run, so a run that does not end the list moves to its end first.
		if int(node.a + node.b) != len(t.attrs) {
			a := len(t.attrs)
			if _, err := append(&t.attrs, ..t.attrs[node.a:][:node.b]); err != nil {
				t.oom = true
				return
			}
			t.nodes[n].a = u32(a)
		}
		if _, err := append(&t.attrs, attr); err != nil {
			t.oom = true
			return
		}
		t.nodes[n].b += 1
	}
}

@(private)
has_attr :: proc(t: ^Html_Tree, n: ^Tree_Node, name: Span) -> bool {
	for a in t.attrs[n.a:][:n.b] {
		if names_equal(raw_data(t.src), a.name, name) {
			return true
		}
	}
	return false
}

// Whether `attrs` has attribute `name`, and whether its value, decoded in the scratch buffer, is `want`, ASCII case
// folded.
@(private)
attr_value_is :: proc(t: ^Html_Tree, attrs: []Attribute, name, want: string) -> (found, equal: bool) {
	a := attribute_of(t, attrs, name)
	if a == nil {
		return false, false
	}
	return true, ascii_fold_equal(decoded(t, a.value, 0), want)
}

// The first of `attrs` named `name`, ASCII case folded, or nil.
@(private)
attribute_of :: proc(t: ^Html_Tree, attrs: []Attribute, name: string) -> ^Attribute {
	for &a in attrs {
		if a.name.n == u32(len(name)) && fold_equal(raw_data(t.src)[a.name.lo:], transmute([]u8)name) && a.name.flags & {.Nul, .Invalid} == {} {
			return &a
		}
	}
	return nil
}

@(private)
ascii_fold_equal :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if 'A' <= x && x <= 'Z' {
			x |= 0x20
		}
		if 'A' <= y && y <= 'Z' {
			y |= 0x20
		}
		if x != y {
			return false
		}
	}
	return true
}

// Decodes `s` into the scratch buffer from byte `from` and returns it.
@(private)
decoded :: proc(t: ^Html_Tree, s: Span, from: int) -> string {
	if s.flags & ~{.Missing} == {} {
		return string(t.src[s.lo:][:s.n])
	}
	if err := resize(&t.scratch, from + decode_room(s)); err != nil {
		t.oom = true
		return ""
	}
	text, _ := decode(t.src, s, t.scratch[from:])
	return text
}

// Whether two elements' tokens have the same attributes, by name and value, for the Noah's Ark clause.
@(private)
same_attrs :: proc(t: ^Html_Tree, x, y: ^Tree_Node) -> bool {
	if x.b != y.b {
		return false
	}
	src := raw_data(t.src)
	outer: for a in t.attrs[x.a:][:x.b] {
		for b in t.attrs[y.a:][:y.b] {
			if !names_equal(src, a.name, b.name) {
				continue
			}
			va := decoded(t, a.value, 0)
			if va == decoded(t, b.value, len(va)) {
				continue outer
			}
			return false
		}
		return false
	}
	return true
}

// Pushes formatting element `n` onto the list of active formatting elements, first dropping the earliest of three
// after the last marker that match it.
@(private)
push_active :: proc(t: ^Html_Tree, n: u32) {
	same, earliest := 0, -1
	#reverse for e, i in t.active {
		if e == 0 {
			break
		}
		x, y := &t.nodes[e], &t.nodes[n]
		if x.tag == y.tag && x.ns == y.ns && (x.tag != .Other || names_equal(raw_data(t.src), x.name, y.name)) && same_attrs(t, x, y) {
			same += 1
			earliest = i
		}
	}
	if same >= 3 {
		ordered_remove(&t.active, earliest)
	}
	if _, err := append(&t.active, n); err != nil {
		t.oom = true
	}
}

@(private)
push_marker :: proc(t: ^Html_Tree) {
	if _, err := append(&t.active, 0); err != nil {
		t.oom = true
	}
}

@(private)
clear_to_marker :: proc(t: ^Html_Tree) {
	for len(t.active) > 0 {
		if pop(&t.active) == 0 {
			return
		}
	}
}

@(private)
active_index :: proc(t: ^Html_Tree, n: u32) -> int {
	#reverse for e, i in t.active {
		if e == n {
			return i
		}
	}
	return -1
}

// The last element of HTML tag `tag` in the list of active formatting elements after its last marker, or -1.
@(private)
active_after_marker :: proc(t: ^Html_Tree, tag: Tag) -> int {
	#reverse for e, i in t.active {
		if e == 0 {
			return -1
		}
		if is_html(&t.nodes[e], tag) {
			return i
		}
	}
	return -1
}

// Reopens the formatting elements opened in the current body, cell or caption that were not closed.
@(private)
reconstruct :: proc(t: ^Html_Tree) {
	n := len(t.active)
	if n == 0 {
		return
	}
	last := t.active[n - 1]
	if last == 0 || .Open in t.nodes[last].flags {
		return
	}
	i := n - 1
	for i > 0 {
		e := t.active[i - 1]
		if e == 0 || .Open in t.nodes[e].flags {
			break
		}
		i -= 1
	}
	for ; i < n && !t.oom && !t.too_deep; i += 1 {
		c := clone_node(t, t.active[i])
		insert_node(t, c)
		t.active[i] = c
	}
}

// Runs the adoption agency for an end tag of formatting element `tag`. Returns whether the tag is to be read as any
// other end tag.
@(private)
adoption_agency :: proc(t: ^Html_Tree, tag: Tag) -> (other: bool) {
	if n := current_node(t); is_html(n, tag) && active_index(t, current(t)) < 0 {
		pop_current(t)
		return false
	}
	for _ in 0 ..< 8 {
		fi := active_after_marker(t, tag)
		if fi < 0 {
			return true
		}
		formatting := t.active[fi]
		si := stack_index(t, formatting)
		if si < 0 {
			misplaced(t, .Misnested_Tag)
			ordered_remove(&t.active, fi)
			return false
		}
		if !node_in_scope(t, formatting) {
			misplaced(t, .Misnested_Tag)
			return false
		}
		if formatting != current(t) {
			misplaced(t, .Misnested_Tag)
		}
		furthest := u32(0)
		for m in t.stack[si + 1:] {
			if .Special in classes(&t.nodes[m]) {
				furthest = m
				break
			}
		}
		if furthest == 0 {
			pop_to(t, si)
			ordered_remove(&t.active, fi)
			return false
		}
		common := t.stack[si - 1]
		// The new element goes where `formatting` is in the list, or right after `bookmark` once that is set.
		bookmark := u32(0)
		last := furthest
		ni := stack_index(t, furthest)
		for inner := 1;; inner += 1 {
			ni -= 1
			node := t.stack[ni]
			if node == formatting {
				break
			}
			ai := active_index(t, node)
			if inner > 3 && ai >= 0 {
				ordered_remove(&t.active, ai)
				ai = -1
			}
			if ai < 0 {
				ordered_remove(&t.stack, ni)
				unstacked(t, node)
				continue
			}
			c := clone_node(t, node)
			if t.oom {
				return false
			}
			t.nodes[node].flags -= {.Open}
			ended(t, node)
			t.nodes[c].flags += {.Open}
			t.active[ai] = c
			t.stack[ni] = c
			if bookmark == 0 {
				bookmark = c
			}
			unlink(t, last)
			link(t, c, last, 0)
			t.nodes[last].flags += {.Moved}
			last = c
		}
		parent, before, _ := place(t, common)
		unlink(t, last)
		if !is_inclusive_ancestor(t, last, parent) {
			link(t, parent, last, before)
			t.nodes[last].flags += {.Moved}
		}
		fresh := clone_node(t, formatting)
		if t.oom {
			return false
		}
		if bookmark == 0 {
			t.active[active_index(t, formatting)] = fresh
		} else {
			inject_at(&t.active, active_index(t, bookmark) + 1, fresh)
			ordered_remove(&t.active, active_index(t, formatting))
		}
		remove_from_stack(t, formatting)
		inject_at(&t.stack, stack_index(t, furthest) + 1, fresh)
		t.nodes[fresh].flags += {.Open}
		for child := t.nodes[furthest].first; child != 0; child = t.nodes[furthest].first {
			unlink(t, child)
			link(t, fresh, child, 0)
			t.nodes[child].flags += {.Moved}
		}
		link(t, furthest, fresh, 0)
	}
	return false
}

// Resets the insertion mode from the stack of open elements, a fragment's context element in place of its root.
@(private)
reset_insertion_mode :: proc(t: ^Html_Tree) {
	#reverse for m, i in t.stack {
		last := i == 0
		n := &t.nodes[t.context_element if last && t.context_element != 0 else m]
		if n.ns != .Html {
			continue
		}
		#partial switch n.tag {
		case .Td, .Th:
			if !last {
				t.mode = .In_Cell
				return
			}
		case .Tr:
			t.mode = .In_Row
			return
		case .Tbody, .Thead, .Tfoot:
			t.mode = .In_Table_Body
			return
		case .Caption:
			t.mode = .In_Caption
			return
		case .Colgroup:
			t.mode = .In_Column_Group
			return
		case .Table:
			t.mode = .In_Table
			return
		case .Template:
			if len(t.templates) > 0 {
				t.mode = t.templates[len(t.templates) - 1]
				return
			}
		case .Head:
			if !last {
				t.mode = .In_Head
				return
			}
		case .Body:
			t.mode = .In_Body
			return
		case .Frameset:
			t.mode = .In_Frameset
			return
		case .Html:
			t.mode = .Before_Head if t.head == 0 else .After_Head
			return
		}
	}
	t.mode = .In_Body
}
