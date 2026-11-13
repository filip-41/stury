package yaml

// YAML's edit services. A block collection is lines at an indentation, with no bytes of its own to hold a separator,
// so the format commits its edits itself, through `compose.apply_splices`. A value's text is placed at
// its site's indentation, a member or element of a block collection is a group of whole lines, one of a flow
// collection a range with its separator, and a tag, an anchor or a comment the bytes of its fact. Every byte no splice
// touches stays. The result is read again by the walk, so an edit that breaks a rule of the language is `.Bad_Result`.

import "base:runtime"
import "core:bytes"
import core "../core"
import compose "../core/compose"
import write "../core/write"

// Why an edit of a YAML text is refused, indexed by `Edit_Detail`.
@(private)
Edit_Detail :: enum u8 {
	None,
	Aliased, // a node inside the value an alias reads
	Anchored, // an anchored node an alias reads, or a node inside one
	Merged, // a text read with merge keys that holds a `<<`
	Reordered, // a reorder of a collection's members
	Alias_Node, // a member, a tag or an anchor added to an alias, or its alias removed
	No_Line, // a comment where the node has no line of its own
	Flow_Comment, // a comment inside a flow collection
	Block_Comment, // an inline comment on a block collection or a block scalar
	Implicit_Pair, // a member added to or removed from a single pair in a flow sequence
	Long_Key, // a key past the length of an implicit key
}

@(private, rodata)
EDIT_RULES := core.Rules{"yaml_edit", {
	{},
	{"aliased", "This node is what an alias reads: edit the anchored node, or set the alias"},
	{"anchored", "An alias reads this node, so an edit would change the alias's value too"},
	{"merged", "A text read with merge keys has members no line of it holds: edit it without merge keys"},
	{"reordered", "A YAML collection keeps its members in the order of its lines"},
	{"alias_node", "An alias holds no members, tag or anchor of its own: set it instead"},
	{"no_line", "This node has no line of its own to hold a comment"},
	{"flow_comment", "A comment inside a flow collection is not edited"},
	{"block_comment", "A block collection or a block scalar has no line end of its own to hold an inline comment"},
	{"implicit_pair", "A single pair in a flow sequence holds one member"},
	{"long_key", "An implicit key is at most 1024 bytes"},
}}

// A value spelled as YAML for an edit at byte `at`: block text at column 0, which the commit indents to its site or
// turns to flow inside a flow collection.
@(private)
edit_spell :: proc(doc: ^core.Document, v: core.Value, opts: core.Write_Options, _: string, _: bool, at: u64, allocator: runtime.Allocator) -> ([]u8, core.Error) {
	text, err := write.write_laid(v, doc.as, opts, "", &TOKENS, allocator, core.site_at(doc.src, at))
	return text, core.error_of(err)
}

// Checks `src` as exactly one value: one document with a node, no marker, directive, comment or space before it. An
// alias may name an anchor, and a tag a handle, that the document around the value holds, which the commit's read of
// the whole text judges.
@(private)
edit_value :: proc(v: ^core.Token_View, src: []u8, allocator: runtime.Allocator) -> core.Document_Error {
	if len(src) == 0 || src[0] == ' ' || src[0] == '\t' || src[0] == '\n' || src[0] == '\r' || src[0] == '#' || src[0] == '%' || holds_marker(src) {
		return {kind = .Bad_Value}
	}
	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 4 * 1024}
	defer runtime.arena_destroy(&arena)
	doc, value, _, err := build_value(src, v.as, runtime.arena_allocator(&arena))
	if err.kind != .None {
		return err
	}
	if n := doc.nodes[value]; n.kind <= .Plain && n.n == 0 && len(core.all_facts(&doc, value)) == 0 {
		return {kind = .Bad_Value}
	}
	return {}
}

// Reads `src` as a value, judged after the anchors and tag handles it names that it does not hold, and returns the
// value's node and where `src` starts in the text read. A node's bytes before the first line end of `src` lie at
// `offset` past their place in `src`.
@(private)
build_value :: proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (doc: core.Document, value: core.Node_Index, offset: u64, err: core.Document_Error) {
	text := src
	names := Judged_Names{anchors = make([dynamic]u8, allocator), handles = make([dynamic]u8, allocator)}
	for tries := 0; ; tries += 1 {
		doc, err = build_as(text, as, false, allocator)
		#partial switch err.kind {
		case .None:
		case .Walk:
			f := err.inner
			if f.rules != &RULES || tries == NAMES_MAX {
				return doc, 0, 0, {kind = .Bad_Value, inner = err.inner}
			}
			#partial switch Detail(f.detail) {
			case .Undefined_Alias:
				name_anchor(&names, text[f.at + 1:])
			case .Undeclared_Handle:
				name_handle(&names, text[f.at:])
			case:
				return doc, 0, 0, {kind = .Bad_Value, inner = err.inner}
			}
			text, offset = judged_text(&names, src, allocator)
			continue
		case:
			return
		}
		if names.named > 0 {
			value, _ = core.child_at(&doc, core.ROOT, names.named)
		}
		return
	}
}

// The most anchors and tag handles a value's judge declares before it refuses the value.
@(private = "file")
NAMES_MAX :: 64

// The anchors and tag handles a value's judge declares: an alias to another anchor reads a null, and a tag with
// another handle a tag of its own.
@(private = "file")
Judged_Names :: struct {
	anchors: [dynamic]u8, // the sequence elements before the value, `- &name ~` lines
	handles: [dynamic]u8, // `%TAG` lines
	named:   int,
}

// Names the anchor the alias name at the start of `rest` reads.
@(private = "file")
name_anchor :: proc(names: ^Judged_Names, rest: []u8) {
	name := 0
	for name < len(rest) && !is_blank_byte(rest[name]) && bytes.index_byte(transmute([]u8)string(",[]{}"), rest[name]) < 0 {
		name += 1
	}
	append(&names.anchors, "- &")
	append(&names.anchors, ..rest[:name])
	append(&names.anchors, " ~\n")
	names.named += 1
}

// Declares the handle of the tag at the start of `rest`, from its `!` to its second.
@(private = "file")
name_handle :: proc(names: ^Judged_Names, rest: []u8) {
	bang := bytes.index_byte(rest[1:], '!') + 2
	append(&names.handles, "%TAG ")
	append(&names.handles, ..rest[:bang])
	append(&names.handles, " tag:stury,0:\n")
}

// The text `src` judged after the names: a document under the `%TAG` lines, and the last element of a block sequence
// whose earlier elements are the anchored nulls.
@(private = "file")
judged_text :: proc(names: ^Judged_Names, src: []u8, allocator: runtime.Allocator) -> (text: []u8, offset: u64) {
	b := make([dynamic]u8, 0, len(names.handles) + len(names.anchors) + len(src) + 64, allocator)
	if len(names.handles) > 0 {
		append(&b, ..names.handles[:])
		append(&b, "---\n")
	}
	if names.named == 0 {
		offset = u64(len(b))
		append(&b, ..src)
		return b[:], offset
	}
	append(&b, ..names.anchors[:])
	append(&b, "- ")
	offset = u64(len(b))
	for c in src {
		append(&b, c)
		if c == '\n' {
			append(&b, "  ")
		}
	}
	return b[:], offset
}

// Whether a line of `src` starts with a document marker, which would end the document the text is placed in.
@(private = "file")
holds_marker :: proc(src: []u8) -> bool {
	for ls := 0; ls < len(src); {
		if rest := src[ls:]; len(rest) >= 3 && (string(rest[:3]) == "---" || string(rest[:3]) == "...") && (len(rest) == 3 || is_blank_byte(rest[3])) {
			return true
		}
		nl := bytes.index_byte(src[ls:], '\n')
		if nl < 0 {
			break
		}
		ls += nl + 1
	}
	return false
}

@(private)
is_blank_byte :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// Writes the decoded name `name` as a block mapping's key: plain when it reads back as itself, else quoted.
@(private)
edit_key_text :: proc(_: ^core.Document, name: []u8, text: ^[dynamic]u8) -> bool {
	spelled, ok := spell_key(string(name), false, context.allocator)
	defer delete(spelled)
	if !ok {
		return false
	}
	_, failed := append(text, ..spelled)
	return failed == nil
}

// The spelling of the key `name` in a block or a flow collection, in the style `keeps` when it holds one, or false for
// one too long for an implicit key or no UTF-8.
@(private)
spell_key :: proc(name: string, flow: bool, allocator: runtime.Allocator, keeps: Maybe(Style) = nil) -> ([]u8, bool) {
	if len(name) > KEY_MAX {
		return nil, false
	}
	return spell_scalar(name, Place{flow = flow, key = true, keeps = keeps}, allocator)
}

// `s` as a scalar at a place of `at`'s kind, in the style the writer picks for it there.
@(private)
spell_scalar :: proc(s: string, at: Place, allocator: runtime.Allocator) -> ([]u8, bool) {
	shape, kind := shape_of(s, at)
	if kind != .None {
		return nil, false
	}
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, allocator)
	put_scalar(&out, s, shape, false)
	spelled, err := write.finish(&out)
	return spelled, err.kind == .None
}

// The marker and body of a property: a tag as its text, `&` and an anchor's name, `*` and an alias's.
@(private)
edit_prefix :: proc(_: ^core.Document, role: core.Role, body: []u8, text: ^[dynamic]u8) -> bool {
	#partial switch role {
	case .Tag:
		if len(body) == 0 || body[0] != '!' {
			append(text, '!')
		}
	case .Anchor:
		append(text, '&')
	case .Alias:
		append(text, '*')
	case:
		return false
	}
	_, failed := append(text, ..body)
	return failed == nil
}

// The bytes node `node` has at a site of the document: its own, with the lines after its first dedented by the column
// its site indents them by, so that `edit_commit` placing the text at that site writes the same bytes.
@(private)
edit_relocate :: proc(doc: ^core.Document, node: core.Node_Index, _: core.Site, allocator: runtime.Allocator) -> ([]u8, bool) {
	arena := runtime.Arena{backing_allocator = allocator}
	defer runtime.arena_destroy(&arena)
	cx := Cx{doc = doc, src = doc.src, a = runtime.arena_allocator(&arena)}
	build_geometry(&cx)
	v := u32(node)
	basis := basis_of(&cx, v)
	src := cx.src[cx.lo[v]:cx.hi[v]]
	out := make([dynamic]u8, 0, len(src) + 2, allocator)
	// An implicit pair of a flow sequence is a flow mapping anywhere else.
	pair := cx.doc.nodes[v].kind == .Object && cx.flags[v] & {.Flow, .Bracket} == {.Flow}
	if pair {
		append(&out, '{')
	}
	for ls := 0; ls < len(src); {
		nl := bytes.index_byte(src[ls:], '\n')
		stop := len(src) if nl < 0 else ls + nl + 1
		line := src[ls:stop]
		if ls > 0 {
			cut := 0
			for cut < basis && cut < len(line) && line[cut] == ' ' {
				cut += 1
			}
			line = line[cut:]
		}
		append(&out, ..line)
		ls = stop
	}
	if pair {
		append(&out, '}')
	}
	return out[:], true
}

// Marks the nodes an edit may not touch: every node of a text read with merge keys that holds a `<<`, each node of an
// alias's copy, and each node of an anchored node an alias reads. A copy starts where its anchored node starts, with its
// kind, and only aliases and copies share both.
@(private = "file")
mark_frozen :: proc(cx: ^Cx) {
	doc := cx.doc
	nodes := doc.nodes
	cx.frozen = make([]Edit_Detail, len(nodes), cx.a)
	if options_of(doc.as).merge_keys && bytes.contains(cx.src, transmute([]u8)string("<<")) {
		for &d in cx.frozen {
			d = .Merged
		}
		return
	}
	read := make(map[[2]u64]struct{}, cx.a)
	for i := u32(0); i < u32(len(nodes)); i += 1 {
		if .Alias in cx.flags[i] && cx.frozen[i] == .None {
			for j in i + 1 ..< i + u32(core.subtree_size(doc, core.Node_Index(i))) {
				cx.frozen[j] = .Aliased
			}
			read[{nodes[i].lo, u64(nodes[i].kind)}] = {}
		}
	}
	if len(read) == 0 {
		return
	}
	for i := u32(0); i < u32(len(nodes)); i += 1 {
		key := [2]u64{nodes[i].lo, u64(nodes[i].kind)}
		if .Alias not_in cx.flags[i] && cx.frozen[i] == .None && key in read {
			for j in i ..< i + u32(core.subtree_size(doc, core.Node_Index(i))) {
				cx.frozen[j] = .Anchored
			}
		}
	}
}

// The commit's view of the text: each node's parent, last child, first and past-last byte and flags.
@(private)
Cx :: struct {
	doc:     ^core.Document,
	src:     []u8,
	a:       runtime.Allocator,
	eol:     string,
	parent:  []u32,
	last:    []u32,
	lo, hi:  []u64,
	flags:   []Node_Flags,
	frozen:  []Edit_Detail,
	step:    int, // the spaces a block collection under a key is indented by
	seq_off: int, // the spaces a block sequence under a key is indented by
	learnt:  bool,
	splices: [dynamic]compose.Splice,
	seen:    map[u64]struct{},
	groups:  map[u32]Group,
	items:   map[u32][]Item,
	err:     core.Document_Error,
}

@(private)
Node_Flag :: enum u8 {
	Bracket, // a flow collection, in brackets
	Flow, // inside a flow collection, or one
	Alias, // an alias: its bytes are its `*name`
	After_Props, // an empty node: its bytes are none, past its properties
}

@(private)
Node_Flags :: bit_set[Node_Flag;u8]

// The members a container loses and gains.
@(private)
Group :: struct {
	removed: [dynamic]int,
	inserts: [dynamic]core.Edit,
}

// A member of a mapping or an element of a sequence: its key (`NIL` for an element) and value, where it starts (its
// key's first byte with the key's properties, or its dash) and where its value ends.
@(private)
Item :: struct {
	key, value: u32,
	start, end: u64,
}

@(private)
NIL :: max(u32)

@(private)
is_container :: #force_inline proc "contextless" (k: core.Kind) -> bool {
	return k == .Array || k == .Object
}

// Whether node `i` is a block collection, whose bytes are its members' lines.
@(private)
is_block :: #force_inline proc(cx: ^Cx, i: u32) -> bool {
	return is_container(cx.doc.nodes[i].kind) && cx.flags[i] & {.Bracket, .Alias} == {}
}

@(private)
build_geometry :: proc(cx: ^Cx) {
	doc := cx.doc
	nodes := doc.nodes
	n := len(nodes)
	cx.parent = make([]u32, n, cx.a)
	cx.last = make([]u32, n, cx.a)
	cx.lo = make([]u64, n, cx.a)
	cx.hi = make([]u64, n, cx.a)
	cx.flags = make([]Node_Flags, n, cx.a)
	Open :: struct {
		id, end: u32,
	}
	stack := make([dynamic]Open, cx.a)
	fi := 0
	// The nodes of an alias's copy end at `copy_end`. The others start in order: `last_lo` is the latest start,
	// `last_node` the node at it, and `last_end` the furthest end.
	copy_end, last_node := u32(0), NIL
	last_lo, last_end := u64(0), u64(0)
	for i in 0 ..< n {
		for len(stack) > 0 && u32(i) >= stack[len(stack) - 1].end {
			pop(&stack)
		}
		p := stack[len(stack) - 1].id if len(stack) > 0 else NIL
		cx.parent[i], cx.last[i] = p, NIL
		if p != NIL {
			cx.last[p] = u32(i)
			if .Flow in cx.flags[p] {
				cx.flags[i] += {.Flow}
			}
		}
		nd := nodes[i]
		lo, hi := core.scalar_ends(nd)
		for fi < len(doc.facts) && doc.facts[fi].node < core.Node_Index(i) {
			fi += 1
		}
		props_end := u64(0)
		for k := fi; k < len(doc.facts) && doc.facts[k].node == core.Node_Index(i); k += 1 {
			#partial switch f := doc.facts[k]; f.role {
			case .Alias:
				cx.flags[i] += {.Alias}
				lo, hi = f.lo, f.lo + u64(f.n)
			case .Tag, .Anchor:
				props_end = max(props_end, f.lo + u64(f.n))
			}
		}
		switch {
		case u32(i) < copy_end:
		case .Alias in cx.flags[i]:
			copy_end = u32(i) + u32(core.subtree_size(doc, core.Node_Index(i)))
			last_end = max(last_end, hi)
		case nd.role == .Key && (nd.lo < last_lo || nd.lo == last_lo && (last_node != p || u32(i) != p + 1)):
			cx.flags[i] += {.Alias}
			lo, hi = alias_key_at(cx.src, cx.lo[p] if u32(i) == p + 1 else last_end, .Flow in cx.flags[i])
			last_end = hi
		case:
			if nd.lo >= last_lo {
				last_lo, last_node = nd.lo, u32(i)
			}
			if nd.kind <= .Plain && nd.n == 0 {
				if nd.role == .Key {
					props_end = key_props_end(cx.src, lo)
				}
				if props_end > lo {
					lo, hi = props_end, props_end
					cx.flags[i] += {.After_Props}
				} else if p != NIL && nodes[p].kind == .Object && nd.role == .Value && lo < cx.hi[i - 1] {
					lo, hi = cx.hi[i - 1], cx.hi[i - 1]
				}
			}
			last_end = max(last_end, hi)
		}
		if is_container(nd.kind) {
			if .Alias not_in cx.flags[i] {
				lo = nd.lo
				if is_flow(doc, nd) {
					cx.flags[i] += {.Bracket, .Flow}
					hi = close_end(doc, core.Node_Index(i))
				} else if nd.kind == .Object && i + 1 < n {
					lo = min(lo, key_start(doc, cx.src, u32(i + 1), max(lo, nodes[i + 1].lo)))
				}
			}
			append(&stack, Open{u32(i), u32(i) + nd.n})
		}
		cx.lo[i], cx.hi[i] = lo, hi
	}
	for i := n - 1; i >= 0; i -= 1 {
		if is_block(cx, u32(i)) {
			cx.hi[i] = cx.hi[cx.last[i]] if cx.last[i] != NIL else cx.lo[i]
		}
	}
}

// The bytes of the alias key past `from`: its `*` and name.
@(private = "file")
alias_key_at :: proc(src: []u8, from: u64, flow: bool) -> (lo, hi: u64) {
	lo = from
	for lo < u64(len(src)) {
		at_token := lo == 0 || is_blank_byte(src[lo - 1])
		if src[lo] == '#' && at_token {
			lo = content_end(src, lo)
			continue
		}
		if src[lo] == '*' && (at_token || bytes.index_byte(transmute([]u8)string(",[{?"), src[lo - 1]) >= 0) {
			break
		}
		lo += 1
	}
	hi = lo + 1
	for hi < u64(len(src)) && !is_blank_byte(src[hi]) && !(flow && bytes.index_byte(transmute([]u8)string(",[]{}"), src[hi]) >= 0) {
		hi += 1
	}
	return
}

// The end of the properties an empty key at `p` holds on its line, which no fact holds, or `p` when it has none.
@(private = "file")
key_props_end :: proc(src: []u8, p: u64) -> u64 {
	end := p
	for i := p; i < u64(len(src)); {
		for i < u64(len(src)) && (src[i] == ' ' || src[i] == '\t') {
			i += 1
		}
		if i == u64(len(src)) || src[i] != '!' && src[i] != '&' {
			return end
		}
		for i < u64(len(src)) && !is_blank_byte(src[i]) {
			i += 1
		}
		end = i
	}
	return end
}

// The first byte of node `i`'s properties, its tag and anchor, or `lo` when it has none.
@(private)
props_lo :: proc(doc: ^core.Document, i: u32, lo: u64) -> u64 {
	at := lo
	for f in core.all_facts(doc, core.Node_Index(i)) {
		if f.role == .Tag || f.role == .Anchor {
			at = min(at, f.lo)
		}
	}
	return at
}

// The first byte of key `j` at `lo`: its properties, which a key on its line holds as no fact, and the `?` of an
// explicit key.
@(private)
key_start :: proc(doc: ^core.Document, src: []u8, j: u32, lo: u64) -> u64 {
	at := props_lo(doc, j, lo)
	// An empty explicit key starts at its `?`, which may stand on an earlier line.
	if doc.nodes[j].n == 0 {
		q := at
		for q > 0 && is_blank_byte(src[q - 1]) {
			q -= 1
		}
		if q > 0 && src[q - 1] == '?' {
			return q - 1
		}
	}
	for {
		k := at
		for k > 0 && (src[k - 1] == ' ' || src[k - 1] == '\t') {
			k -= 1
		}
		if k == at {
			return at
		}
		t := k
		for t > 0 && !is_blank_byte(src[t - 1]) {
			t -= 1
		}
		// A flow indicator ends a token inside a flow collection, but a verbatim tag may hold one.
		if src[t] != '!' && src[t] != '&' {
			for f := k; f > t; f -= 1 {
				if bytes.index_byte(transmute([]u8)string(",[{"), src[f - 1]) >= 0 {
					t = f
					break
				}
			}
		}
		switch {
		case t == k:
			return at
		case src[t] == '!' || src[t] == '&':
			at = t
		case k - t == 1 && src[t] == '?':
			return t
		case:
			return at
		}
	}
}

@(private)
items_of :: proc(cx: ^Cx, c: u32) -> []Item {
	if cached, ok := cx.items[c]; ok {
		return cached
	}
	nodes := cx.doc.nodes
	list := make([dynamic]Item, cx.a)
	end := c + nodes[c].n
	for j := c + 1; j < end; {
		it := Item{key = NIL, value = j}
		if nodes[c].kind == .Object {
			it.key, it.value = j, j + 1
			it.start = key_start(cx.doc, cx.src, j, cx.lo[j] if .Alias in cx.flags[j] else min(cx.lo[j], nodes[j].lo))
		} else if .Bracket in cx.flags[c] {
			it.start = props_lo(cx.doc, j, cx.lo[j])
		} else {
			it.start = cx.lo[c] if len(list) == 0 else dash_after(cx.src, list[len(list) - 1].end)
		}
		it.end = cx.hi[it.value]
		append(&list, it)
		j = it.value + u32(core.subtree_size(cx.doc, core.Node_Index(it.value)))
	}
	cx.items[c] = list[:]
	return list[:]
}

// The dash of the next element of a block sequence, the first byte past `p` that is no space, line end or comment.
@(private = "file")
dash_after :: proc(src: []u8, p: u64) -> u64 {
	i := p
	for i < u64(len(src)) {
		switch src[i] {
		case ' ', '\t', '\r', '\n':
			i += 1
		case '#':
			for i < u64(len(src)) && src[i] != '\n' {
				i += 1
			}
		case:
			return i
		}
	}
	return i
}

// The column at which a node's lines after its first are indented at its site, and by which `edit_relocate` dedents
// them: a block collection's own, else its block parent's, and none inside a flow collection.
@(private)
basis_of :: proc(cx: ^Cx, v: u32) -> int {
	if is_block(cx, v) {
		return column_of(cx.src, cx.lo[v])
	}
	p := cx.parent[v]
	if p == NIL || .Flow in cx.flags[p] {
		return 0
	}
	return column_of(cx.src, cx.lo[p])
}

// Learns how the text indents a block collection under a key, 2 spaces when it holds none.
@(private)
learn_layout :: proc(cx: ^Cx) {
	if cx.learnt {
		return
	}
	cx.learnt = true
	step, seq := -1, -1
	nodes := cx.doc.nodes
	for i in 1 ..< len(nodes) {
		p := cx.parent[i]
		if p == NIL || nodes[p].kind != .Object || nodes[i].role != .Value || !is_block(cx, u32(i)) || !is_block(cx, p) {
			continue
		}
		off := column_of(cx.src, cx.lo[i]) - column_of(cx.src, cx.lo[i - 1])
		if nodes[i].kind == .Object && step < 0 && off > 0 {
			step = off
		} else if nodes[i].kind == .Array && seq < 0 && off >= 0 {
			seq = off
		}
		if step >= 0 && seq >= 0 {
			break
		}
	}
	cx.step = step if step > 0 else 2
	cx.seq_off = seq if seq >= 0 else cx.step
}

@(private)
refuse_edit :: proc(cx: ^Cx, node: u32, detail: Edit_Detail) -> bool {
	cx.err = {kind = .Frozen, at = u64(node), inner = {rules = &EDIT_RULES, detail = u8(detail)}}
	return false
}

@(private)
add :: proc(cx: ^Cx, lo, hi: u64, text: []u8) {
	append(&cx.splices, compose.Splice{lo = lo, hi = hi, text = text, seq = len(cx.splices)})
}

// The end of the line at `p`, before its line end.
@(private)
content_end :: proc(src: []u8, p: u64) -> u64 {
	i := p
	for i < u64(len(src)) && src[i] != '\n' {
		i += 1
	}
	if i > p && i < u64(len(src)) && src[i - 1] == '\r' {
		i -= 1
	}
	return i
}

@(private)
column_of :: proc(src: []u8, p: u64) -> int {
	return int(p - compose.line_start(src, p))
}

// The byte past the last that is no space or tab before `p` on its line.
@(private)
lead_end :: proc(src: []u8, p: u64) -> u64 {
	i := p
	for i > 0 && (src[i - 1] == ' ' || src[i - 1] == '\t') {
		i -= 1
	}
	return i
}

// Whether the rest of the line from `p` holds nothing but spaces and a comment.
@(private)
rest_is_blank :: proc(src: []u8, p: u64) -> bool {
	for i := p; i < u64(len(src)) && src[i] != '\n' && src[i] != '\r'; i += 1 {
		if src[i] == '#' {
			return true
		}
		if src[i] != ' ' && src[i] != '\t' {
			return false
		}
	}
	return true
}

// Whether the line at `ls` holds only a comment, and the comment's column.
@(private)
comment_line :: proc(src: []u8, ls: u64) -> (col: int, ok: bool) {
	i := ls
	for i < u64(len(src)) && (src[i] == ' ' || src[i] == '\t') {
		i += 1
	}
	return int(i - ls), i < u64(len(src)) && src[i] == '#'
}

// Whether the line at `ls` holds only spaces, tabs and a carriage return.
@(private)
blank_line :: proc(src: []u8, ls: u64) -> bool {
	i := ls
	for i < u64(len(src)) && (src[i] == ' ' || src[i] == '\t' || src[i] == '\r') {
		i += 1
	}
	return i >= u64(len(src)) || src[i] == '\n'
}

@(private)
put_spaces_to :: proc(b: ^[dynamic]u8, n: int) {
	for _ in 0 ..< n {
		append(b, ' ')
	}
}

// Appends `text` with each line after its first indented by `n` spaces, an empty line left empty, and its line ends
// written as the file's.
@(private)
put_lines :: proc(cx: ^Cx, b: ^[dynamic]u8, text: []u8, n: int) {
	ls := 0
	for {
		nl := bytes.index_byte(text[ls:], '\n')
		line := text[ls:] if nl < 0 else text[ls:ls + nl]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		if ls > 0 && len(line) > 0 {
			put_spaces_to(b, n)
		}
		append(b, ..line)
		if nl < 0 {
			return
		}
		compose.puts(b, cx.eol)
		ls += nl + 1
	}
}

// Returns the source bytes the edits make. Each edit becomes splices, and refused ones end the commit.
@(private)
edit_commit :: proc(list: ^core.Edit_List, _: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	doc := list.doc
	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 64 * 1024}
	defer runtime.arena_destroy(&arena)
	cx := Cx{doc = doc, src = doc.src, a = runtime.arena_allocator(&arena)}
	cx.eol = "\r\n" if bytes.contains(doc.src, []u8{'\r', '\n'}) else "\n"
	cx.splices = make([dynamic]compose.Splice, cx.a)
	cx.seen = make(map[u64]struct{}, cx.a)
	cx.groups = make(map[u32]Group, cx.a)
	cx.items = make(map[u32][]Item, cx.a)
	build_geometry(&cx)
	mark_frozen(&cx)
	for e in list.edits {
		if !apply(&cx, e) {
			return nil, 0, cx.err
		}
	}
	for c, &g in cx.groups {
		if !regroup(&cx, c, &g) {
			return nil, 0, cx.err
		}
	}
	out, err = compose.apply_splices(doc.src, cx.splices[:], allocator)
	return out, 0, err
}

// Applies one edit as splices, or for a member added or removed records it with its container's.
@(private = "file")
apply :: proc(cx: ^Cx, e: core.Edit) -> bool {
	i := u32(e.node)
	if d := cx.frozen[i]; d != .None {
		return refuse_edit(cx, i, d)
	}
	switch e.op {
	case .Set:
		compose.claim(&cx.seen, &cx.err, u64(i) << 8 | 0xff) or_return
		if e.role == .Key {
			return set_key(cx, i, string(e.text))
		}
		return set_value(cx, i, e.text)
	case .Insert:
		if .Alias in cx.flags[i] {
			return refuse_edit(cx, i, .Alias_Node)
		}
		g := group_of(cx, i)
		append(&g.inserts, e)
	case .Remove:
		compose.claim(&cx.seen, &cx.err, u64(i) << 8 | 0xff) or_return
		p := cx.parent[i]
		for it, k in items_of(cx, p) {
			if it.value == i {
				g := group_of(cx, p)
				append(&g.removed, k)
			}
		}
	case .Reorder:
		return refuse_edit(cx, i, .Reordered)
	case .Set_Fact, .Remove_Fact:
		compose.claim(&cx.seen, &cx.err, u64(i) << 8 | u64(e.role)) or_return
		return fact_edit(cx, e)
	}
	return true
}

@(private = "file")
group_of :: proc(cx: ^Cx, c: u32) -> ^Group {
	if c not_in cx.groups {
		cx.groups[c] = {removed = make([dynamic]int, cx.a), inserts = make([dynamic]core.Edit, cx.a)}
	}
	return &cx.groups[c]
}
