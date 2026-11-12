package yaml

// The write of a document as YAML. Pretty text is block style, with one member or element a line, and a collection read
// from a flow collection stays one. Compact text is flow style on one line. A scalar read from YAML keeps its style
// unless `respell_strings` is set, and any other string takes the style `shape_of` picks, which reads back as the same
// string under the 1.2 core schema and a 1.1 reader. Tags and anchors are written back from the facts, and an alias where
// its anchor stands before it. A comment is written when the document holds it, above the line it heads, after the value
// it ends and at the end of a block collection. A comment the output has no place for, and one with a line end in its
// body, is dropped and counted. Null is `null`, or the spelling a YAML source had. A key an object repeats is `.Unwritable`.

import "base:runtime"
import "core:io"
import "core:slice"
import core "../core"
import write "../core/write"

@(private)
Layout :: struct {
	out:       write.Out,
	doc:       ^core.Document,
	opts:      core.Write_Options,
	arena:     runtime.Arena,
	step:      int, // the spaces of one block level
	own:       bool, // the document is YAML
	commented: bool, // the document holds a fact
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

@(private)
Member :: struct {
	key, value: core.Node_Index,
	name:       string,
}

// The members of an object in the order they are written. A document read from YAML is walked as it stands, any other
// is copied so a repeated key is found, and `sort_keys` orders either.
@(private)
Members :: struct {
	items:  []Member,
	it:     core.Pair_Iter,
	at:     int,
	direct: bool,
}

// What a node carries before it: its tag, its anchor, and the alias it stands for.
@(private)
Properties :: struct {
	tag, anchor, alias: string,
}

// The handle's `write`: node `node` of `doc` as YAML.
@(private)
document_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, dropped: int, err: core.Typed_Refusal) {
	if doc.partial || opts.tab {
		return nil, 0, {kind = .Unsupported}
	}
	spill: [write.ROOM_MAX]u8 = ---
	l := Layout{doc = doc, opts = opts, own = is_yaml(doc), step = int(opts.indent) if opts.indent > 0 else 2}
	l.arena.backing_allocator = context.allocator
	defer runtime.arena_destroy(&l.arena)
	l.defined.allocator = runtime.arena_allocator(&l.arena)
	write.init(&l.out, &spill, allocator, stream, len(doc.src) + write.ROOM_MAX if l.own else 0)
	l.commented = len(core.subtree_facts(doc, node)) > 0
	kind := put_root(&l, node)
	text, err = write.finish(&l.out, {kind = kind})
	if err.kind != .None {
		return nil, 0, err
	}
	return text, len(core.subtree_facts(doc, node)) - l.kept - l.skipped, err
}

// The text of `node` as a document: its head comments, the `%TAG` directives of the source, a `---` where they or a
// property on a block collection need one, and the node.
@(private)
put_root :: proc(l: ^Layout, node: core.Node_Index) -> core.Typed_Error_Kind {
	pr := props_of(l, node)
	put_comments(l, node, .Comment, 0)
	directives := l.own && node == core.ROOT && put_directives(l)
	k := core.kind(l.doc, node)
	block := (k == .Object || k == .Array) && l.opts.pretty && core.length(l.doc, node) > 0 && !kept_flow(l, node)
	if directives || block && (pr.tag != "" || pr.anchor != "") {
		if !directives {
			write.put_text(&l.out, "---")
		}
		return put_node(l, node, .Key, 0)
	}
	return put_node(l, node, .Root, 0)
}

// Writes the `%TAG` directives the source text begins with and the `---` after them, and tells whether there were any.
@(private)
put_directives :: proc(l: ^Layout) -> bool {
	src := l.doc.src
	at := 0
	if len(src) >= 3 && src[0] == 0xef && src[1] == 0xbb && src[2] == 0xbf {
		at = 3
	}
	found := false
	for at < len(src) {
		end := at
		for end < len(src) && src[end] != '\n' {
			end += 1
		}
		line := string(src[at:end])
		switch {
		case len(line) > 4 && line[:4] == "%TAG":
			write.put_text(&l.out, line)
			write.put_byte(&l.out, '\n')
			found = true
		case len(line) == 0 || line[0] == '#' || line[0] == '%' || line[0] == '\r':
		case:
			end = len(src)
		}
		at = end + 1
	}
	if found {
		write.put_text(&l.out, "---")
	}
	return found
}

// The tag, anchor and alias of `node`, as the facts of a document read from YAML hold them.
@(private)
props_of :: proc(l: ^Layout, node: core.Node_Index) -> (pr: Properties) {
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
		l.kept += 1
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
	k := core.kind(l.doc, node)
	#partial switch k {
	case .Object, .Array:
		if core.length(l.doc, node) > 0 && pretty && !kept_flow(l, node) {
			return put_block_open(l, opens, node, pr, ctx, ind)
		}
		put_props(l, &space, pr)
		if space {
			write.put_byte(&l.out, ' ')
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
	ended := put_leaf(l, node, false, false, ind, pr.tag != "") or_return
	if ended {
		return .None
	}
	put_inline_comment(l, node)
	put_line_end(l)
	return .None
}

// Pushes `o` on `opens`.
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
			put_spaces(&l.out, ind)
		}
		o.first = false
		explicit := put_key(l, m.key, false) or_return
		if explicit {
			write.put_byte(&l.out, '\n')
			put_spaces(&l.out, ind)
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
		put_spaces(&l.out, ind)
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
	buf: [512]u8
	text, ok := core.text(l.doc, key, buf[:])
	if !ok {
		text, ok = core.text_clone(l.doc, key, runtime.arena_allocator(&l.arena))
		if !ok {
			return false, .No_Memory
		}
	}
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

// Whether the collection at `node` stays flow style: it was read as one, in a document whose text is not computed.
@(private)
kept_flow :: proc(l: ^Layout, node: core.Node_Index) -> bool {
	return l.own && !l.opts.respell_strings && is_flow(l.doc, l.doc.nodes[node])
}

// The style a scalar was read in, for a document read from YAML whose strings are not respelled.
@(private)
own_style :: proc(l: ^Layout, node: core.Node_Index) -> Maybe(Style) {
	if l.own && !l.opts.respell_strings {
		return style_of(l.doc.nodes[node].spelling)
	}
	return nil
}

// Writes the scalar at `node` as `put_node` places it. A literal block ends its lines itself, which is `ended`.
@(private)
put_leaf :: proc(l: ^Layout, node: core.Node_Index, flow, key: bool, ind: int, tagged: bool) -> (ended: bool, kind: core.Typed_Error_Kind) {
	#partial switch core.kind(l.doc, node) {
	case .String:
		buf: [512]u8
		text, ok := core.text(l.doc, node, buf[:])
		if !ok {
			text, ok = core.text_clone(l.doc, node, runtime.arena_allocator(&l.arena))
			if !ok {
				return false, .No_Memory
			}
		}
		place := Place{flow = flow, key = key, block = l.opts.pretty && !flow && !key, ascii = l.opts.ascii, keeps = own_style(l, node), tagged = tagged}
		shape := shape_of(text, place) or_return
		if shape == .Literal {
			put_literal(&l.out, text, ind if ind > 0 else l.step)
			return true, .None
		}
		put_scalar(&l.out, text, shape, l.opts.ascii)
	case .Number:
		return false, put_number(l, node)
	case .True:
		write.put_text(&l.out, own_text(l, node, "true"))
	case .False:
		write.put_text(&l.out, own_text(l, node, "false"))
	case .Null:
		write.put_text(&l.out, own_text(l, node, "null"))
	case:
		return false, .Unwritable
	}
	return false, .None
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

@(private)
put_number :: proc(l: ^Layout, node: core.Node_Index) -> core.Typed_Error_Kind {
	t := l.doc.nodes[node]
	span := core.span(l.doc, node)
	if l.own {
		write.put_text(&l.out, string(span))
		return .None
	}
	if l.doc.readers.number_text != nil {
		stack: [64]u8
		text, ok := write.node_number_text(l.doc, node, stack[:])
		if !ok {
			return .No_Memory
		}
		write.put_text(&l.out, text)
		return .None
	}
	if t.spelling & core.NUMBER_KIND_MASK == 0 {
		write.put_text(&l.out, string(span))
		return .None
	}
	kind := write.put_decimal(&l.out, string(span), t.spelling)
	if kind != .Non_Finite {
		return kind
	}
	f, ok := core.float_value(l.doc, node)
	if !ok {
		return .Non_Finite
	}
	switch {
	case f != f:
		write.put_text(&l.out, ".nan")
	case f > 0:
		write.put_text(&l.out, ".inf")
	case:
		write.put_text(&l.out, "-.inf")
	}
	return .None
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
			write.put_byte(&l.out, '}')
			return put_flow_close(l, opens)
		}
		if !o.first {
			write.put_text(&l.out, ", ")
		}
		o.first = false
		explicit := put_key(l, m.key, true) or_return
		write.put_text(&l.out, " : " if explicit else ": ")
		return put_flow_start(l, opens, m.value)
	}
	element, more := core.child_next(&o.elements)
	if !more {
		write.put_byte(&l.out, ']')
		return put_flow_close(l, opens)
	}
	if !o.first {
		write.put_text(&l.out, ", ")
	}
	o.first = false
	return put_flow_start(l, opens, element)
}

@(private)
put_flow_close :: proc(l: ^Layout, opens: ^[dynamic]Put_Open) -> core.Typed_Error_Kind {
	o := pop(opens)
	if o.tail {
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
	k := core.kind(l.doc, node)
	if k == .Object || k == .Array {
		return put_flow_open(l, opens, node, false)
	}
	_, kind := put_leaf(l, node, true, false, 0, pr.tag != "")
	return kind
}

// The members of the object at `node`. A key a copied object repeats is `.Unwritable`.
// Mappings with fewer keys than this check for a repeated key by comparing names in turn.
@(private)
LINEAR_KEYS :: 16

@(private)
members_of :: proc(l: ^Layout, node: core.Node_Index) -> (Members, core.Typed_Error_Kind) {
	if l.own && !l.opts.sort_keys {
		return Members{it = core.pairs(l.doc, node), direct = true}, .None
	}
	scratch := runtime.arena_allocator(&l.arena)
	items := make([dynamic]Member, scratch)
	seen: map[string]struct{}
	it := core.pairs(l.doc, node)
	for key, value in core.pair_next(&it) {
		name, whole := core.text(l.doc, key, nil)
		if !whole {
			name, whole = core.text_clone(l.doc, key, scratch)
			if !whole {
				return {}, .No_Memory
			}
		}
		if !l.own {
			if len(items) < LINEAR_KEYS {
				for m in items {
					if m.name == name {
						return {}, .Unwritable
					}
				}
			} else {
				if seen == nil {
					seen = make(map[string]struct{}, scratch)
					for m in items {
						seen[m.name] = {}
					}
				}
				if name in seen {
					return {}, .Unwritable
				}
				seen[name] = {}
			}
		}
		if _, failed := append(&items, Member{key, value, name}); failed != nil {
			return {}, .No_Memory
		}
	}
	if l.opts.sort_keys {
		slice.stable_sort_by(items[:], proc(a, b: Member) -> bool {return a.name < b.name})
	}
	return Members{items = items[:]}, .None
}

@(private)
members_next :: proc(m: ^Members) -> (Member, bool) {
	if m.direct {
		key, value, ok := core.pair_next(&m.it)
		return Member{key = key, value = value}, ok
	}
	if m.at >= len(m.items) {
		return {}, false
	}
	m.at += 1
	return m.items[m.at - 1], true
}

// Whether a comment body can be written: no line end, and no control byte but tab.
@(private)
comment_ok :: proc(body: string) -> bool {
	for b in transmute([]u8)body {
		if b < 0x20 && b != '\t' || b == 0x7f {
			return false
		}
	}
	return true
}

// Each comment of `role` on `node` as a line of its own at column `ind`.
@(private)
put_comments :: proc(l: ^Layout, node: core.Node_Index, role: core.Role, ind: int) {
	if !l.commented {
		return
	}
	it := core.facts_of(l.doc, node, role)
	for body in core.fact_next(&it) {
		if comment_ok(body) {
			l.kept += 1
			put_spaces(&l.out, ind)
			write.put_byte(&l.out, '#')
			write.put_text(&l.out, body)
			write.put_byte(&l.out, '\n')
		}
	}
}

// The first comment of `node` that ends on its line, after the value, in pretty text.
@(private)
put_inline_comment :: proc(l: ^Layout, node: core.Node_Index) {
	if !l.commented || !l.opts.pretty {
		return
	}
	it := core.facts_of(l.doc, node, .Comment_Inline)
	for body in core.fact_next(&it) {
		if comment_ok(body) {
			l.kept += 1
			write.put_text(&l.out, " #")
			write.put_text(&l.out, body)
			return
		}
	}
}
