package yaml

// The write of a document as YAML. Pretty text is block style, with one member or element a line, and a collection read
// from a flow collection stays one. Compact text is flow style on one line. A scalar read from YAML keeps its style
// unless `respell_strings` is set, and any other string takes the style `shape_of` picks, which reads back as the same
// string under the 1.2 core schema and a 1.1 reader. Tags and anchors are written back from the facts, and an alias where
// its anchor stands before it. A comment is written when the document holds it, above the line it heads, after the value
// it ends and at the end of a collection, and compact text breaks its flow line at a comment. A comment the output has
// no place for, and one with a line end in its body, is dropped and counted. Null is `null`, or the spelling a YAML
// source had. A key an object repeats is `.Unwritable`.

import "base:runtime"
import "core:io"
import core "../core"
import write "../core/write"

@(private)
Layout :: struct {
	out:       write.Out,
	doc:       ^core.Document,
	opts:      core.Write_Options,
	fail:      core.Node_Index, // the node a refusal stands at, for its path
	arena:     runtime.Arena,
	step:      int, // the spaces of one block level
	own:       bool, // the document is YAML
	commented: bool, // the document holds a fact
	tagged:    bool, // the document is of another format that holds tags
	kept:      int, // the facts written
	skipped:   int, // the facts of the nodes an alias stands for
	defined:   map[string]struct{}, // the anchors written so far
}

// Where a node stands: the start of a text, after a mapping key's colon, or after a sequence's dash.
@(private)
Context :: enum u8 {
	Root,
	Key,
	Dash,
}

// The members of an object in the order they are written. A document read from YAML is walked as it stands, any other
// is copied so a repeated key is found, and `sort_keys` orders either.
@(private)
Members :: struct {
	items:  []write.Node_Member,
	it:     core.Pair_Iter,
	at:     int,
	direct: bool,
}

// What a node carries before it: its tag, its anchor, and the alias it stands for. `spelled` says the tag is spelled
// by no fact span, as another format's datetime may be, so it counts as no fact kept.
@(private)
Properties :: struct {
	tag, anchor, alias: string,
	spelled:            bool,
}

// The least an arena block of a write holds, so a text of one small record asks the allocator for little.
@(private)
ARENA_BLOCK :: 16 * 1024

// The handle's `write`: node `node` of `doc` as YAML.
@(private)
document_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, kept: int, err: core.Typed_Refusal) {
	spill: [write.ROOM_MAX]u8 = ---
	l := Layout{doc = doc, opts = opts, own = is_yaml(doc), step = int(opts.indent) if opts.indent > 0 else 2}
	l.arena = {backing_allocator = context.allocator, minimum_block_size = ARENA_BLOCK}
	defer runtime.arena_destroy(&l.arena)
	l.defined.allocator = runtime.arena_allocator(&l.arena)
	write.init(&l.out, &spill, allocator, stream, len(doc.src) + write.ROOM_MAX if l.own else 0)
	l.commented = len(core.subtree_facts(doc, node)) > 0
	l.tagged = !l.own && .Tag in doc.readers.holds && core.has_tags(doc)
	kind := put_root(&l, node)
	refusal := core.Typed_Refusal{kind = kind}
	if kind == .Unwritable || kind == .Non_Finite {
		write.node_path(&refusal, doc, l.fail)
	}
	text, err = write.finish(&l.out, refusal)
	if err.kind != .None {
		return nil, 0, err
	}
	return text, l.kept + l.skipped, err
}

// The text of `node` as a document: its head comments, the directives and explicit markers of the source, a `---` where a
// property on a block collection needs one, and the node.
@(private)
put_root :: proc(l: ^Layout, node: core.Node_Index) -> core.Typed_Error_Kind {
	pr := props_of(l, node)
	before := l.kept
	put_comments(l, node, .Comment, 0)
	directives := l.own && node == core.ROOT && put_directives(l)
	k := core.kind(l.doc, node)
	block := (k == .Object || k == .Array) && l.opts.pretty && core.length(l.doc, node) > 0 && !kept_flow(l, node)
	// A blank line ends the text's head comment, so the first entry's comments stay its own.
	if block && l.kept > before && !directives {
		write.put_byte(&l.out, '\n')
	}
	if directives || block && (pr.tag != "" || pr.anchor != "") {
		if !directives {
			write.put_text(&l.out, "---")
		}
		put_node(l, node, .Key, 0) or_return
	} else {
		put_node(l, node, .Root, 0) or_return
	}
	if l.own && node == core.ROOT && ends_explicitly(l) {
		// A pretty text ends its last line already.
		write.put_text(&l.out, "...\n" if l.opts.pretty else "\n...")
	}
	return .None
}

// Writes the directives of the source's document and the `---` after them, when it has them or an explicit `---`, and
// tells whether it wrote the `---`.
@(private)
put_directives :: proc(l: ^Layout) -> bool {
	it := core.facts_of(l.doc, core.ROOT, .Directive)
	start := false
	for body in core.fact_next(&it) {
		if body[0] == '%' {
			write.put_text(&l.out, body)
			write.put_byte(&l.out, '\n')
		}
		start ||= body[0] != '.'
	}
	if start {
		write.put_text(&l.out, "---")
	}
	return start
}

// Whether the source's document ends in an explicit `...`.
@(private)
ends_explicitly :: proc(l: ^Layout) -> bool {
	it := core.facts_of(l.doc, core.ROOT, .Directive)
	for body in core.fact_next(&it) {
		if body[0] == '.' {
			return true
		}
	}
	return false
}

// The tag, anchor and alias of `node`, as the facts of a document read from YAML hold them. A tag of another format
// is the YAML tag of its meaning: `!!binary`, and `!!timestamp` on a text YAML reads as a timestamp of that kind.
@(private)
props_read :: proc(l: ^Layout, node: core.Node_Index) -> (pr: Properties) {
	if l.tagged && core.kind(l.doc, node) == .String {
		tag, _ := core.fact_value(l.doc, node, .Tag)
		pr.spelled = !tag.span
		if tag.meaning != .Own {
			buf: [64]u8 = ---
			text, _ := core.text(l.doc, node, buf[:])
			pr.tag = meaning_tag(text, tag.meaning)
		}
	}
	if !l.own || !l.commented {
		return
	}
	it := core.facts_of(l.doc, node, .Tag)
	pr.tag, _ = core.fact_next(&it)
	it = core.facts_of(l.doc, node, .Anchor)
	pr.anchor, _ = core.fact_next(&it)
	it = core.facts_of(l.doc, node, .Alias)
	pr.alias, _ = core.fact_next(&it)
	return
}

// The properties of `node`, none for a document that holds no fact and is not another format's with tags.
@(private)
props_of :: #force_inline proc(l: ^Layout, node: core.Node_Index) -> (pr: Properties) {
	if l.tagged || l.own && l.commented {
		return props_read(l, node)
	}
	return
}

// The kind of `node`. A plain value of a document that holds no fact, written as it was read, is a number when its text
// is a decimal that starts with a digit from 1 to 9, an optional fraction following, which skips the parse of the number
// the document's own resolution makes.
@(private)
node_kind :: #force_inline proc(l: ^Layout, node: core.Node_Index) -> core.Kind {
	if l.own && !l.commented {
		n := l.doc.nodes[node]
		if n.kind == .Plain && n.role == .Value && plain_decimal(l.doc.src[n.lo:n.lo + u64(n.n)]) {
			return .Number
		}
	}
	return core.kind(l.doc, node)
}

// Whether `text` is an optional minus, a digit from 1 to 9 and more digits, and optionally a point with digits after it.
@(private)
plain_decimal :: proc(text: []u8) -> bool {
	i := 1 if len(text) > 0 && text[0] == '-' else 0
	if i >= len(text) || text[i] < '1' || text[i] > '9' {
		return false
	}
	for i += 1; i < len(text) && text[i] >= '0' && text[i] <= '9'; i += 1 {
	}
	if i == len(text) {
		return true
	}
	if text[i] != '.' || i + 1 == len(text) {
		return false
	}
	for i += 1; i < len(text); i += 1 {
		if text[i] < '0' || text[i] > '9' {
			return false
		}
	}
	return true
}

// Writes a space unless `space` is clear, then `text`, and sets `space`.
@(private)
put_token :: proc(l: ^Layout, space: ^bool, text: string) {
	if space^ {
		write.put_byte(&l.out, ' ')
	}
	write.put_text(&l.out, text)
	space^ = true
}

// Writes the tag and the anchor in front of a node.
@(private)
put_props :: proc(l: ^Layout, space: ^bool, pr: Properties) {
	if pr.tag != "" {
		put_token(l, space, pr.tag)
		l.kept += 0 if pr.spelled else 1
	}
	if pr.anchor != "" {
		put_token(l, space, "&")
		write.put_text(&l.out, pr.anchor)
		l.defined[pr.anchor] = {}
		l.kept += 1
	}
}

// A collection the write has open: the members or elements still to write, and where its lines stand. A block
// collection's entries start at column `ind`, and `compact` puts its first on the dash's line. A flow collection whose
// `tail` is set stands where a block node would, so its inline comment and line end follow its bracket.
@(private)
Put_Open :: struct {
	members:  Members,
	elements: core.Child_Iter,
	node:     core.Node_Index,
	ind:      int,
	object:   bool,
	flow:     bool,
	first:    bool,
	compact:  bool,
	tail:     bool,
}

// Writes node `node` where `ctx` says it stands, and ends its last line in pretty text. `ind` is the column the lines
// of a collection or block scalar below it start at: after a key, the key's column and one step, after a dash, two past
// the dash. A mapping or sequence after a dash starts on the dash's line. The collections inside it are frames of
// `opens`, in the context allocator, not calls, so the native stack does not grow with the document's depth.
@(private)
put_node :: proc(l: ^Layout, node: core.Node_Index, ctx: Context, ind: int) -> core.Typed_Error_Kind {
	opens := make([dynamic]Put_Open, 0, 16)
	defer delete(opens)
	put_node_start(l, &opens, node, ctx, ind) or_return
	for len(opens) > 0 {
		if opens[len(opens) - 1].flow {
			put_flow_next(l, &opens) or_return
		} else {
			put_block_next(l, &opens) or_return
		}
	}
	return .None
}

// Writes the start of node `node` as `put_node` places it: the whole node when it is not a collection the write opens
// in `opens`.
@(private)
put_node_start :: proc(l: ^Layout, opens: ^[dynamic]Put_Open, node: core.Node_Index, ctx: Context, ind: int) -> core.Typed_Error_Kind {
	pr := props_of(l, node)
	space := ctx != .Root
	pretty := l.opts.pretty
	if pr.alias != "" && !l.opts.sort_keys && pr.alias in l.defined {
		put_token(l, &space, "*")
		write.put_text(&l.out, pr.alias)
		l.skipped += len(core.subtree_facts(l.doc, node))
		put_inline_comment(l, node)
		put_line_end(l)
		return .None
	}
	k := node_kind(l, node)
	#partial switch k {
	case .Object, .Array:
		if core.length(l.doc, node) > 0 && pretty && !kept_flow(l, node) {
			return put_block_open(l, opens, node, pr, ctx, ind)
		}
		put_props(l, &space, pr)
		if space {
			write.put_byte(&l.out, ' ')
		}
		if pretty && l.commented && core.length(l.doc, node) == 0 && has_fact(l, node, .Comment_Foot) {
			put_empty_foot(l, node, k == .Object, ind)
			return .None
		}
		return put_flow_open(l, opens, node, true)
	case .Null:
		if ctx != .Root && l.own && pr.tag == "" && pr.anchor == "" && len(core.span(l.doc, node)) == 0 {
			put_inline_comment(l, node)
			put_line_end(l)
			return .None
		}
	}
	put_props(l, &space, pr)
	if space {
		write.put_byte(&l.out, ' ')
	}
	ended := put_leaf(l, node, k, false, false, ind, pr.tag != "") or_return
	if ended {
		return .None
	}
	if ctx == .Root {
		put_flow_inline(l, node)
	}
	put_inline_comment(l, node)
	put_line_end(l)
	return .None
}

@(private)
put_open_push :: proc(opens: ^[dynamic]Put_Open, o: Put_Open) -> core.Typed_Error_Kind {
	if _, failed := append(opens, o); failed != nil {
		return .No_Memory
	}
	return .None
}

@(private)
put_line_end :: #force_inline proc(l: ^Layout) {
	if l.opts.pretty {
		write.put_byte(&l.out, '\n')
	}
}

// Writes the start of the block collection at `node`, whose properties are `pr`, and opens it.
@(private)
put_block_open :: proc(l: ^Layout, opens: ^[dynamic]Put_Open, node: core.Node_Index, pr: Properties, ctx: Context, ind: int) -> core.Typed_Error_Kind {
	space := ctx != .Root
	compact := ctx == .Dash && pr.tag == "" && pr.anchor == "" && !has_fact(l, node, .Comment_Inline) && !first_headed(l, node)
	if compact {
		write.put_byte(&l.out, ' ')
	} else {
		put_props(l, &space, pr)
		put_inline_comment(l, node)
		if ctx != .Root {
			write.put_byte(&l.out, '\n')
		}
	}
	o := Put_Open{node = node, ind = ind, first = true, compact = compact}
	if core.kind(l.doc, node) == .Object {
		o.object = true
		o.members = members_of(l, node) or_return
	} else {
		o.elements = core.children(l.doc, node)
	}
	return put_open_push(opens, o)
}

// Writes the next member or element of the innermost open collection, a block one, up to the start of its value: one
// member of a block mapping runs from its key through its value, with the mapping's lines at column `ind`. With none
// left, the collection's foot comments end it.
@(private)
put_block_next :: proc(l: ^Layout, opens: ^[dynamic]Put_Open) -> core.Typed_Error_Kind {
	o := &opens[len(opens) - 1]
	ind := o.ind
	if o.object {
		m, more := members_next(&o.members)
		if !more {
			return put_block_close(l, opens)
		}
		if !(o.first && o.compact) {
			put_comments(l, m.value, .Comment, ind)
			write.put_run(&l.out, ind, ' ')
		}
		o.first = false
		explicit := put_key(l, m.key, false) or_return
		if explicit {
			write.put_byte(&l.out, '\n')
			write.put_run(&l.out, ind, ' ')
		}
		write.put_byte(&l.out, ':')
		return put_node_start(l, opens, m.value, .Key, ind + l.step)
	}
	element, more := core.child_next(&o.elements)
	if !more {
		return put_block_close(l, opens)
	}
	if !(o.first && o.compact) {
		put_comments(l, element, .Comment, ind)
		write.put_run(&l.out, ind, ' ')
	}
	o.first = false
	write.put_byte(&l.out, '-')
	return put_node_start(l, opens, element, .Dash, ind + 2)
}

@(private)
put_block_close :: proc(l: ^Layout, opens: ^[dynamic]Put_Open) -> core.Typed_Error_Kind {
	o := pop(opens)
	put_comments(l, o.node, .Comment_Foot, o.ind)
	return .None
}

// Whether the first member or element of the collection `node` has a comment above it, which cannot stand on a dash's line.
@(private)
first_headed :: proc(l: ^Layout, node: core.Node_Index) -> bool {
	if !l.commented {
		return false
	}
	first := node + 1
	if core.kind(l.doc, node) == .Object {
		it := core.pairs(l.doc, node)
		_, first, _ = core.pair_next(&it)
	}
	return has_fact(l, first, .Comment)
}

@(private)
has_fact :: proc(l: ^Layout, node: core.Node_Index, role: core.Role) -> bool {
	if !l.commented {
		return false
	}
	it := core.facts_of(l.doc, node, role)
	_, found := core.fact_next(&it)
	return found
}

// Writes a mapping key as a scalar on one line, and tells whether it is too long to stand before a colon and was written
// as an explicit key, `? key`.
@(private)
put_key :: proc(l: ^Layout, key: core.Node_Index, flow: bool) -> (explicit: bool, kind: core.Typed_Error_Kind) {
	buf: [512]u8 = ---
	text := write.node_text(l.doc, key, buf[:], runtime.arena_allocator(&l.arena)) or_return
	explicit = len(text) > KEY_MAX
	if explicit {
		write.put_text(&l.out, "? ")
	}
	place := Place{flow = flow, key = true, ascii = l.opts.ascii, keeps = own_style(l, key)}
	shape := shape_of(text, place) or_return
	if shape == .Plain && explicit {
		shape = .Single
	}
	put_scalar(&l.out, text, shape, l.opts.ascii)
	return explicit, .None
}

// Whether the collection at `node` stays flow style, in a document whose text is not computed: it was read as one, or
// another format's document writes it in line (`flow`) and it holds no fact inside, which a flow collection drops.
@(private)
kept_flow :: proc(l: ^Layout, node: core.Node_Index) -> bool {
	if l.opts.respell_strings {
		return false
	}
	if l.own {
		return is_flow(l.doc, l.doc.nodes[node])
	}
	style, _ := core.fact_value(l.doc, node, .Style)
	return style.text == "flow" && !write.holds_inner_fact(l.doc, node)
}

// The style a scalar was read in, for a document read from YAML whose strings are not respelled.
@(private)
own_style :: proc(l: ^Layout, node: core.Node_Index) -> Maybe(Style) {
	if l.own && !l.opts.respell_strings {
		return style_of(l.doc.nodes[node].spelling)
	}
	return nil
}

// Writes the scalar at `node` as `put_node` places it. A block scalar ends its lines itself, which is `ended`.
@(private)
put_leaf :: proc(l: ^Layout, node: core.Node_Index, k: core.Kind, flow, key: bool, ind: int, tagged: bool) -> (ended: bool, kind: core.Typed_Error_Kind) {
	#partial switch k {
	case .String:
		if body, whole := single_quoted_body(l, node); whole {
			write.put_text(&l.out, body)
			return false, .None
		}
		buf: [512]u8 = ---
		text := write.node_text(l.doc, node, buf[:], runtime.arena_allocator(&l.arena)) or_return
		keeps := own_style(l, node)
		folded := keeps == .Block && l.doc.src[l.doc.nodes[node].lo] == '>'
		place := Place{flow = flow, key = key, block = l.opts.pretty && !flow && !key, ascii = l.opts.ascii, keeps = keeps, folded = folded, tagged = tagged}
		shape := shape_of(text, place) or_return
		if shape == .Literal || shape == .Folded {
			put_block(&l.out, text, shape, ind if ind > 0 else l.step)
			return true, .None
		}
		put_scalar(&l.out, text, shape, l.opts.ascii)
	case .Number:
		refused := write.put_number_node(&l.out, l.doc, node, TREE, l.own, NUMBER_FORMS)
		if refused != .None {
			l.fail = node
		}
		return false, refused
	case .True:
		write.put_text(&l.out, own_text(l, node, "true"))
	case .False:
		write.put_text(&l.out, own_text(l, node, "false"))
	case .Null:
		write.put_text(&l.out, own_text(l, node, "null"))
	case .Bytes:
		stack: [512]u8 = ---
		text, ok := write.node_bytes_text(l.doc, node, stack[:])
		if !ok {
			return false, .No_Memory
		}
		write.put_text(&l.out, "!!binary ")
		put_scalar(&l.out, text, .Plain if len(text) > 0 else .Double, false)
	case:
		l.fail = node
		return false, .Unwritable
	}
	return false, .None
}

// The source text of the string at `node` with its quotes, when a document read from YAML keeps it single-quoted and
// its body holds only the printable ASCII bytes, which is the text `put_single` writes for its decoded string.
@(private)
single_quoted_body :: proc(l: ^Layout, node: core.Node_Index) -> (text: string, whole: bool) {
	if !l.own || l.opts.respell_strings || style_of(l.doc.nodes[node].spelling) != .Single {
		return "", false
	}
	span := core.span(l.doc, node)
	return string(span), printable_ascii(string(span[1:len(span) - 1]))
}

// The spelling a YAML source gave a boolean or a null, or `word`.
@(private)
own_text :: proc(l: ^Layout, node: core.Node_Index, word: string) -> string {
	if l.own {
		if span := core.span(l.doc, node); len(span) > 0 {
			return string(span)
		}
	}
	return word
}

// Writes the empty collection at `node` in pretty text with its foot comments on lines of their own at column `ind`
// between its brackets, where they read back as its foot.
@(private)
put_empty_foot :: proc(l: ^Layout, node: core.Node_Index, object: bool, ind: int) {
	write.put_text(&l.out, "{\n" if object else "[\n")
	put_comments(l, node, .Comment_Foot, ind)
	write.put_run(&l.out, ind, ' ')
	write.put_byte(&l.out, '}' if object else ']')
	put_inline_comment(l, node)
	put_line_end(l)
}

// Writes the opening bracket of the flow collection at `node` and opens it. `tail` is the `Put_Open` field.
@(private)
put_flow_open :: proc(l: ^Layout, opens: ^[dynamic]Put_Open, node: core.Node_Index, tail: bool) -> core.Typed_Error_Kind {
	o := Put_Open{node = node, flow = true, first = true, tail = tail}
	if core.kind(l.doc, node) == .Object {
		write.put_byte(&l.out, '{')
		o.object = true
		o.members = members_of(l, node) or_return
	} else {
		write.put_byte(&l.out, '[')
		o.elements = core.children(l.doc, node)
	}
	return put_open_push(opens, o)
}

// Writes the next member or element of the innermost open collection, a flow one, or its closing bracket when none is
// left.
@(private)
put_flow_next :: proc(l: ^Layout, opens: ^[dynamic]Put_Open) -> core.Typed_Error_Kind {
	o := &opens[len(opens) - 1]
	if o.object {
		m, more := members_next(&o.members)
		if !more {
			put_flow_comments(l, o.node, .Comment_Foot)
			write.put_byte(&l.out, '}')
			return put_flow_close(l, opens)
		}
		if !o.first {
			write.put_text(&l.out, ", ")
		}
		o.first = false
		put_flow_comments(l, m.value, .Comment)
		explicit := put_key(l, m.key, true) or_return
		write.put_text(&l.out, " : " if explicit else ": ")
		return put_flow_start(l, opens, m.value)
	}
	element, more := core.child_next(&o.elements)
	if !more {
		put_flow_comments(l, o.node, .Comment_Foot)
		write.put_byte(&l.out, ']')
		return put_flow_close(l, opens)
	}
	if !o.first {
		write.put_text(&l.out, ", ")
	}
	o.first = false
	put_flow_comments(l, element, .Comment)
	return put_flow_start(l, opens, element)
}

@(private)
put_flow_close :: proc(l: ^Layout, opens: ^[dynamic]Put_Open) -> core.Typed_Error_Kind {
	o := pop(opens)
	if !o.tail {
		put_flow_inline(l, o.node)
	} else {
		put_inline_comment(l, o.node)
		put_line_end(l)
	}
	return .None
}

// Writes the start of a node inside a flow collection: its properties, then the scalar, or the opening of the
// collection.
@(private)
put_flow_start :: proc(l: ^Layout, opens: ^[dynamic]Put_Open, node: core.Node_Index) -> core.Typed_Error_Kind {
	pr := props_of(l, node)
	space := false
	if pr.alias != "" && !l.opts.sort_keys && pr.alias in l.defined {
		write.put_byte(&l.out, '*')
		write.put_text(&l.out, pr.alias)
		l.skipped += len(core.subtree_facts(l.doc, node))
		return .None
	}
	put_props(l, &space, pr)
	if space {
		write.put_byte(&l.out, ' ')
	}
	k := node_kind(l, node)
	if k == .Object || k == .Array {
		return put_flow_open(l, opens, node, false)
	}
	put_leaf(l, node, k, true, false, 0, pr.tag != "") or_return
	put_flow_inline(l, node)
	return .None
}

// The members of the object at `node`. A key a copied object repeats is `.Unwritable`.
@(private)
members_of :: proc(l: ^Layout, node: core.Node_Index) -> (m: Members, kind: core.Typed_Error_Kind) {
	if l.own && !l.opts.sort_keys {
		return Members{it = core.pairs(l.doc, node), direct = true}, .None
	}
	m.items = write.node_members(l.doc, node, l.opts.sort_keys, !l.own, runtime.arena_allocator(&l.arena)) or_return
	return m, .None
}

@(private)
members_next :: proc(m: ^Members) -> (write.Node_Member, bool) {
	if m.direct {
		key, value, ok := core.pair_next(&m.it)
		return {key = key, value = value}, ok
	}
	if m.at >= len(m.items) {
		return {}, false
	}
	m.at += 1
	return m.items[m.at - 1], true
}

// Each comment of `role` on `node` as a line of its own at column `ind`.
@(private)
put_comments :: proc(l: ^Layout, node: core.Node_Index, role: core.Role, ind: int) {
	if l.commented {
		l.kept += write.put_comment_lines(&l.out, l.doc, node, role, ind)
	}
}

// The one-line comments of `node` that end on its line, after the value, joined into one, in pretty text.
@(private)
put_inline_comment :: proc(l: ^Layout, node: core.Node_Index) {
	if l.commented && l.opts.pretty {
		l.kept += write.put_comment_inline(&l.out, l.doc, node)
	}
}

// Each comment of `role` on `node` inside a flow collection of compact text, on a line of its own.
@(private)
put_flow_comments :: proc(l: ^Layout, node: core.Node_Index, role: core.Role) {
	if !l.commented || l.opts.pretty || !has_fact(l, node, role) {
		return
	}
	if l.out.cursor > 0 && l.out.buf[l.out.cursor - 1] == ' ' {
		l.out.cursor -= 1
	}
	if l.out.cursor > 0 && l.out.buf[l.out.cursor - 1] != '\n' {
		write.put_byte(&l.out, '\n')
	}
	put_comments(l, node, role, 0)
}

// The inline comments of `node` inside a flow collection of compact text, or on its root, which end the line.
@(private)
put_flow_inline :: proc(l: ^Layout, node: core.Node_Index) {
	if !l.commented || l.opts.pretty {
		return
	}
	if joined := write.put_comment_inline(&l.out, l.doc, node); joined > 0 {
		l.kept += joined
		write.put_byte(&l.out, '\n')
	}
}
