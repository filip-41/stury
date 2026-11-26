package html

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// HTML5 tree construction (WHATWG section 13.2.6): stack of open elements, active formatting elements,
// adoption agency, foster parenting, and explicit chunked arena (`Node_Chunks`) backed by the caller's allocator.

@(private)
Tree_Spec :: enum u8 {
	Document,
	Fragment,
}

Fragment_Options :: struct {
	context_name:      string,
	context_namespace: Namespace,
	scripting:         bool,
}

@(private)
Context :: struct {
	ns:   Namespace,
	tag:  Tag,
	name: u8,
}

#assert(len(FOREIGN_NAMES) <= 256)

@(private)
fragment_context :: proc "contextless" (fopts: Fragment_Options) -> Context {
	name := fopts.context_name if fopts.context_name != "" else "body"
	n := u32(min(u64(len(name)), u64(max(u32))))
	return {
		ns   = fopts.context_namespace,
		tag  = tag_of(transmute([]u8)name, Span{n = n}),
		name = u8(foreign_of(raw_data(name), n)),
	}
}

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
	Implied,
	Cloned,
	Moved,
	Open,
	Integration,
	Text_Integration,
	Annotation,
}

@(private)
Node_Flags :: bit_set[Node_Flag; u8]

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

@(private)
Text_Piece :: struct {
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

@(private)
Parse_Error :: struct {
	at:     u64,
	detail: Detail,
}

@(private)
Html_Tree :: struct {
	src:             []u8,
	nodes:           Node_Chunks,
	count:           u32,
	attrs:           [dynamic]Attribute,
	pieces:          [dynamic]Text_Piece,
	stack:           [dynamic]u32,
	open_tags:       Tags,
	tag_counts:      [len(Tag)]u32,
	active:          [dynamic]u32,
	templates:       [dynamic]Insertion_Mode,
	pending:         [dynamic]Span,
	scratch:         [dynamic]u8,
	public_id:       Span,
	system_id:       Span,
	head, form:      u32,
	foreign_open:    u32,
	context_element: u32,
	tag:             Tag,
	mode:            Insertion_Mode,
	original:        Insertion_Mode,
	quirks:          Quirks,
	action:          Token_Action,
	encoding:        Encoding,
	frameset_ok:     bool,
	foster:          bool,
	skip_lf:         bool,
	acknowledged:    bool,
	pending_text:    bool,
	scripting:       bool,
	in_foreign:      bool,
	selected:        bool,
	tentative:       bool,
	misread:         bool,
	oom:             bool,
	too_deep:        bool,
	max_depth:       int,
	at:              u64,
	body_end:        Span,
	html_hi:         u64,
	tail:            u64,
	taken_to:        u64,
	tok:             ^Html_Token,
	errors:          [dynamic]Parse_Error,
	ctx:             runtime.Context,
}

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

@(private)
tag_of :: proc "contextless" (src: []u8, name: Span) -> Tag #no_bounds_check {
	if name.n == 0 || name.n > TAG_LONGEST || name.flags & {.Nul, .Invalid} != {} {
		return .Other
	}
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

@(private)
build_tree :: proc(
	src: []u8,
	tree_spec: Tree_Spec,
	opts: tape.Options,
	fopts: Fragment_Options,
	lo := u64(0),
	allocator := context.allocator,
) -> (
	t: Html_Tree,
	err: tape.Error,
) {
	from := min(lo, u64(len(src)))
	if tree_spec == .Document && lo == 0 {
		found: bool
		from, t.encoding, found = sniff(src) or_return
		t.tentative = !found
	}
	context.allocator = allocator
	t.src = src
	t.ctx = context
	depth := build.read_depth(opts)
	t.max_depth = int(min(depth, u64(max(int))))
	t.scripting = fopts.scripting
	t.frameset_ok = true
	estimate := len(src) / 32 + 16
	t.pieces = make([dynamic]Text_Piece, 0, estimate / 2, allocator)
	t.attrs = make([dynamic]Attribute, 0, estimate / 2, allocator)
	t.stack = make([dynamic]u32, 0, 64, allocator)
	t.active.allocator = allocator
	t.templates.allocator = allocator
	t.pending.allocator = allocator
	t.scratch.allocator = allocator
	t.errors.allocator = allocator
	if t.pieces == nil || t.attrs == nil || t.stack == nil {
		tree_destroy(&t)
		return {}, runtime.Allocator_Error.Out_Of_Memory
	}
	new_node(&t, {})
	new_node(&t, {kind = .Document})
	if t.oom {
		tree_destroy(&t)
		return {}, runtime.Allocator_Error.Out_Of_Memory
	}
	append(&t.pieces, Text_Piece{})
	start := Content.Data
	if tree_spec == .Fragment {
		start = begin_fragment(&t, fragment_context(fopts))
	}
	if !t.oom {
		_, err, _ = tokenize(src, &t, on_token, start, from = from, in_foreign = t.in_foreign, allocator = allocator, ctx = &t.ctx)
	}
	if err == nil && !t.oom && !t.too_deep && !t.misread {
		eof := Html_Token{kind = EOF, lo = u64(len(src)), hi = u64(len(src))}
		t.at = eof.lo
		t.tok = &eof
		dispatch(&t, &eof)
		pop_to(&t, 0)
		t.tok = nil
	}
	switch {
	case t.oom:
		err = runtime.Allocator_Error.Out_Of_Memory
	case t.too_deep:
		err = tape.Exceeded{at = t.at, kind = .Depth}
	case t.misread:
		err = tape.Fault{at = t.at, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Encoding)}
	}
	if err != nil {
		tree_destroy(&t)
		return {}, err
	}
	return t, nil
}

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
	if !t.oom && !push(t, root) {
		return
	}
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
	for chunk, k in t.nodes {
		if chunk != nil {
			runtime.mem_free_with_size(chunk, chunk_size(k) * size_of(Tree_Node), t.ctx.allocator)
		}
	}
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

@(private)
misplaced :: #force_inline proc(t: ^Html_Tree, d: Detail) {
	parse_error(t, d, t.at)
}

@(private)
Node_Chunks :: [32 - CHUNK_SHIFT][^]Tree_Node

@(private)
CHUNK_SHIFT :: 6

@(private)
chunk_size :: #force_inline proc "contextless" (k: int) -> int {
	return 1 << uint(CHUNK_SHIFT + k)
}

@(private)
tree_node :: #force_inline proc "contextless" (t: ^Html_Tree, n: u32) -> ^Tree_Node #no_bounds_check {
	m := u64(n) + (1 << CHUNK_SHIFT)
	k := 63 - intrinsics.count_leading_zeros(m) - CHUNK_SHIFT
	return &t.nodes[k][m - (1 << CHUNK_SHIFT << k)]
}

@(private)
new_node :: proc(t: ^Html_Tree, n: Tree_Node) -> u32 {
	i := t.count
	m := u64(i) + (1 << CHUNK_SHIFT)
	k := int(63 - intrinsics.count_leading_zeros(m) - CHUNK_SHIFT)
	if k >= len(t.nodes) {
		t.oom = true
		return 0
	}
	if t.nodes[k] == nil {
		chunk, err := runtime.mem_alloc_non_zeroed(chunk_size(k) * size_of(Tree_Node), align_of(Tree_Node), t.ctx.allocator)
		if err != nil {
			t.oom = true
			return 0
		}
		t.nodes[k] = ([^]Tree_Node)(raw_data(chunk))
	}
	t.count += 1
	tree_node(t, i)^ = n
	return i
}

@(private)
element_for :: proc(t: ^Html_Tree, tok: ^Html_Token, tag: Tag, ns := Namespace.Html) -> u32 {
	a := len(t.attrs)
	if _, err := append(&t.attrs, ..tok.attrs); err != nil {
		t.oom = true
	}
	return new_node(t, {kind = .Element, ns = ns, tag = tag, name = tok.name, lo = tok.lo, hi = tok.hi, a = u32(a), b = u32(len(tok.attrs))})
}

@(private)
implied :: proc(t: ^Html_Tree, tag: Tag) -> u32 {
	return new_node(t, {kind = .Element, tag = tag, flags = {.Implied}, lo = t.at, hi = t.at})
}

@(private)
clone_node :: proc(t: ^Html_Tree, n: u32) -> u32 {
	c := tree_node(t, n)^
	c.parent, c.first, c.last, c.prev, c.next = 0, 0, 0, 0, 0
	c.flags = c.flags - {.Open, .Moved} + {.Cloned}
	return new_node(t, c)
}

@(private)
link :: proc(t: ^Html_Tree, parent, n, before: u32) {
	if tree_node(t, n).kind == .Element {
		taken(t)
	}
	tree_node(t, n).parent = parent
	tree_node(t, n).next = before
	prev := tree_node(t, before).prev if before != 0 else tree_node(t, parent).last
	tree_node(t, n).prev = prev
	if prev != 0 {
		tree_node(t, prev).next = n
	} else {
		tree_node(t, parent).first = n
	}
	if before != 0 {
		tree_node(t, before).prev = n
	} else {
		tree_node(t, parent).last = n
	}
}

@(private)
unlink :: proc(t: ^Html_Tree, n: u32) {
	parent := tree_node(t, n).parent
	if parent == 0 {
		return
	}
	prev, next := tree_node(t, n).prev, tree_node(t, n).next
	if prev != 0 {
		tree_node(t, prev).next = next
	} else {
		tree_node(t, parent).first = next
	}
	if next != 0 {
		tree_node(t, next).prev = prev
	} else {
		tree_node(t, parent).last = prev
	}
	tree_node(t, n).parent, tree_node(t, n).prev, tree_node(t, n).next = 0, 0, 0
}

@(private)
is_inclusive_ancestor :: proc(t: ^Html_Tree, a, n: u32) -> bool {
	for m := n; m != 0; m = tree_node(t, m).parent {
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
	return tree_node(t, t.stack[len(t.stack) - 1])
}

@(private)
stack_track_push :: #force_inline proc "contextless" (t: ^Html_Tree, n: u32) {
	node := tree_node(t, n)
	if node.ns == .Html {
		t.tag_counts[node.tag] += 1
		t.open_tags += {node.tag}
	}
}

@(private)
stack_track_pop :: #force_inline proc "contextless" (t: ^Html_Tree, n: u32) {
	node := tree_node(t, n)
	if node.ns == .Html {
		c := t.tag_counts[node.tag]
		if c <= 1 {
			t.tag_counts[node.tag] = 0
			t.open_tags -= {node.tag}
		} else {
			t.tag_counts[node.tag] = c - 1
		}
	}
}

@(private)
push :: proc(t: ^Html_Tree, n: u32) -> bool {
	if len(t.stack) >= t.max_depth {
		t.too_deep = true
		return false
	}
	if _, err := append(&t.stack, n); err != nil {
		t.oom = true
		return false
	}
	stack_track_push(t, n)
	tree_node(t, n).flags += {.Open}
	taken(t)
	return true
}

@(private)
taken :: #force_inline proc "contextless" (t: ^Html_Tree) {
	if t.tok != nil {
		t.taken_to = max(t.taken_to, t.tok.hi)
	}
}

@(private)
pop_current :: #force_inline proc(t: ^Html_Tree) {
	n := pop(&t.stack)
	unstacked(t, n)
	if tree_node(t, n).tag == .Option && t.selected {
		show_selected_option(t, n)
	}
}

@(private)
unstacked :: #force_inline proc(t: ^Html_Tree, n: u32) {
	stack_track_pop(t, n)
	taken(t)
	node := tree_node(t, n)
	node.flags -= {.Open}
	if node.ns != .Html {
		t.foreign_open -= 1
	}
	ended(t, n)
}

@(private)
ended :: proc "contextless" (t: ^Html_Tree, n: u32) {
	node := tree_node(t, n)
	end := t.at
	if tok := t.tok; tok != nil && tok.kind == .End_Tag && node.tag == t.tag && (node.tag != .Other || names_equal(raw_data(t.src), node.name, tok.name)) {
		end = tok.hi
	} else if t.body_end.n > 0 && node.ns == .Html && node.tag == .Html {
		end = t.html_hi if t.html_hi > 0 else end
	} else if t.body_end.n > 0 && node.ns == .Html && node.tag == .Body {
		end = t.body_end.lo + u64(t.body_end.n)
	} else {
		end = t.body_end.lo if t.body_end.n > 0 else end
		end = min(end, t.tail) if t.tail > 0 else end
	}
	node.end = max(end, node.hi)
}

@(private)
pop_to :: proc(t: ^Html_Tree, depth: int) {
	for len(t.stack) > depth {
		pop_current(t)
	}
}

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

@(private)
SCOPE :: Tag_Classes{.Scope}
@(private)
LIST_SCOPE :: Tag_Classes{.Scope, .List_Scope}
@(private)
BUTTON_SCOPE :: Tag_Classes{.Scope, .Button_Scope}
@(private)
TABLE_SCOPE :: Tag_Classes{.Table_Scope}

@(private)
in_scope :: proc(t: ^Html_Tree, tags: Tags, bound := SCOPE) -> bool {
	if t.open_tags & tags == {} {
		return false
	}
	#reverse for m in t.stack {
		n := tree_node(t, m)
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
		if classes(tree_node(t, m)) & bound != {} {
			return false
		}
	}
	return false
}

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
pop_closed :: proc(t: ^Html_Tree, tag: Tag, until := Tags{}, except := Tag.Other, class := Tag_Class.Implied_End) {
	close_implied(t, except, class)
	if !is_html(current_node(t), tag) {
		misplaced(t, .Unclosed_Element)
	}
	pop_until(t, until if until != {} else Tags{tag})
}

@(private)
has_template :: #force_inline proc "contextless" (t: ^Html_Tree) -> bool {
	return .Template in t.open_tags
}

@(private)
in_template_contents :: #force_inline proc(t: ^Html_Tree) -> bool {
	return len(t.templates) > 0
}

@(private)
in_select_context :: #force_inline proc(t: ^Html_Tree) -> bool {
	return t.context_element != 0 && is_html(tree_node(t, t.context_element), .Select)
}

@(private)
clear_to :: proc(t: ^Html_Tree, ctx: Tag_Class) {
	for !(ctx in classes(current_node(t))) {
		pop_current(t)
	}
}

@(private)
close_p :: proc(t: ^Html_Tree) {
	pop_closed(t, .P, except = .P)
}

@(private)
close_open_p :: #force_inline proc(t: ^Html_Tree) {
	if in_scope(t, {.P}, BUTTON_SCOPE) {
		close_p(t)
	}
}

@(private)
check_open_at_end :: proc(t: ^Html_Tree) {
	for m in t.stack {
		if .Open_At_End not_in classes(tree_node(t, m)) {
			misplaced(t, .Unclosed_Element)
			return
		}
	}
}

@(private)
place :: proc(t: ^Html_Tree, target: u32 = 0) -> (parent, before: u32, fostered: bool) {
	parent = target if target != 0 else current(t)
	if !t.foster || .Foster not_in classes(tree_node(t, parent)) {
		return parent, 0, false
	}
	#reverse for m, i in t.stack {
		n := tree_node(t, m)
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

@(private)
insert_node :: proc(t: ^Html_Tree, n: u32) -> bool {
	if t.oom || t.too_deep || n == 0 {
		return false
	}
	parent, before, fostered := place(t)
	link(t, parent, n, before)
	if fostered {
		tree_node(t, n).flags += {.Moved}
	}
	return push(t, n)
}

@(private)
insert_for :: proc(t: ^Html_Tree, tok: ^Html_Token, ns := Namespace.Html) -> (u32, bool) #optional_ok {
	n := element_for(t, tok, t.tag, ns)
	if !insert_node(t, n) {
		return 0, false
	}
	return n, true
}

@(private)
insert_implied :: proc(t: ^Html_Tree, tag: Tag) -> (u32, bool) #optional_ok {
	n := implied(t, tag)
	if !insert_node(t, n) {
		return 0, false
	}
	return n, true
}

@(private)
insert_text :: proc(t: ^Html_Tree, s: Span) {
	if s.n == 0 || t.oom || s.mode == .Text && only_nul(t, s) {
		return
	}
	parent, before, fostered := place(t)
	if tree_node(t, parent).kind == .Document {
		return
	}
	if t.tail == 0 || space_prefix(t, s) < s.n {
		t.taken_to = max(t.taken_to, s.lo + u64(s.n))
	}
	prev := tree_node(t, before).prev if before != 0 else tree_node(t, parent).last
	if prev != 0 && tree_node(t, prev).kind == .Text {
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
	if _, err := append(&t.pieces, Text_Piece{span = s}); err != nil {
		t.oom = true
		return 0
	}
	return u32(len(t.pieces) - 1)
}

@(private)
extend_text :: proc(t: ^Html_Tree, n: u32, s: Span) {
	text := tree_node(t, n)
	last := &t.pieces[text.b]
	if last.span.lo + u64(last.span.n) == s.lo && last.span.mode == s.mode && u64(last.span.n) + u64(s.n) <= u64(max(u32)) {
		last.span.n += s.n
		last.span.flags += s.flags
	} else {
		p := add_piece(t, s)
		t.pieces[tree_node(t, n).b].next = p
		tree_node(t, n).b = p
	}
	tree_node(t, n).hi = s.lo + u64(s.n)
}

@(private)
insert_misc :: proc(t: ^Html_Tree, tok: ^Html_Token, parent: u32 = 0) {
	node := Tree_Node{kind = .Comment, name = tok.data, lo = tok.lo, hi = tok.hi}
	if tok.kind == .Instruction {
		node = {kind = .Instruction, name = tok.name, lo = tok.lo, hi = tok.hi, a = add_piece(t, tok.data)}
	}
	n := new_node(t, node)
	if n == 0 {
		return
	}
	at, before := parent, u32(0)
	if at == 0 {
		at, before, _ = place(t)
	}
	link(t, at, n, before)
}

@(private)
merge_attrs :: proc(t: ^Html_Tree, n: u32, tok: ^Html_Token) {
	for attr in tok.attrs {
		node := tree_node(t, n)
		if has_attr(t, node, attr.name) {
			continue
		}
		if int(node.a + node.b) != len(t.attrs) {
			a := len(t.attrs)
			if _, err := append(&t.attrs, ..t.attrs[node.a:][:node.b]); err != nil {
				t.oom = true
				return
			}
			tree_node(t, n).a = u32(a)
		}
		if _, err := append(&t.attrs, attr); err != nil {
			t.oom = true
			return
		}
		tree_node(t, n).b += 1
		taken(t)
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

@(private)
attr_value_is :: proc(t: ^Html_Tree, attrs: []Attribute, name, want: string) -> (found, equal: bool) {
	a := attribute_of(t, attrs, name)
	if a == nil {
		return false, false
	}
	return true, ascii_fold_equal(decoded(t, a.value, 0), want)
}

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

@(private)
push_active :: proc(t: ^Html_Tree, n: u32) {
	if n == 0 || t.oom || t.too_deep {
		return
	}
	same, earliest := 0, -1
	#reverse for e, i in t.active {
		if e == 0 {
			break
		}
		x, y := tree_node(t, e), tree_node(t, n)
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

@(private)
active_after_marker :: proc(t: ^Html_Tree, tag: Tag) -> int {
	#reverse for e, i in t.active {
		if e == 0 {
			return -1
		}
		if is_html(tree_node(t, e), tag) {
			return i
		}
	}
	return -1
}

@(private)
reconstruct :: proc(t: ^Html_Tree) {
	n := len(t.active)
	if n == 0 {
		return
	}
	last := t.active[n - 1]
	if last == 0 || .Open in tree_node(t, last).flags {
		return
	}
	i := n - 1
	for i > 0 {
		e := t.active[i - 1]
		if e == 0 || .Open in tree_node(t, e).flags {
			break
		}
		i -= 1
	}
	taken_to := t.taken_to
	for ; i < n && !t.oom && !t.too_deep; i += 1 {
		c := clone_node(t, t.active[i])
		if !insert_node(t, c) {
			break
		}
		t.active[i] = c
	}
	t.taken_to = taken_to
}

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
			if .Special in classes(tree_node(t, m)) {
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
			tree_node(t, node).flags -= {.Open}
			ended(t, node)
			tree_node(t, c).flags += {.Open}
			t.active[ai] = c
			stack_track_pop(t, node)
			t.stack[ni] = c
			stack_track_push(t, c)
			if bookmark == 0 {
				bookmark = c
			}
			unlink(t, last)
			link(t, c, last, 0)
			tree_node(t, last).flags += {.Moved}
			last = c
		}
		parent, before, _ := place(t, common)
		unlink(t, last)
		if !is_inclusive_ancestor(t, last, parent) {
			link(t, parent, last, before)
			tree_node(t, last).flags += {.Moved}
		}
		fresh := clone_node(t, formatting)
		if t.oom {
			return false
		}
		if bookmark == 0 {
			t.active[active_index(t, formatting)] = fresh
		} else {
			if _, err := inject_at(&t.active, active_index(t, bookmark) + 1, fresh); err != nil {
				t.oom = true
				return false
			}
			ordered_remove(&t.active, active_index(t, formatting))
		}
		remove_from_stack(t, formatting)
		if _, err := inject_at(&t.stack, stack_index(t, furthest) + 1, fresh); err != nil {
			t.oom = true
			return false
		}
		stack_track_push(t, fresh)
		tree_node(t, fresh).flags += {.Open}
		for child := tree_node(t, furthest).first; child != 0; child = tree_node(t, furthest).first {
			unlink(t, child)
			link(t, fresh, child, 0)
			tree_node(t, child).flags += {.Moved}
		}
		link(t, furthest, fresh, 0)
	}
	return false
}

@(private)
reset_insertion_mode :: proc(t: ^Html_Tree) {
	#reverse for m, i in t.stack {
		last := i == 0
		n := tree_node(t, t.context_element if last && t.context_element != 0 else m)
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
