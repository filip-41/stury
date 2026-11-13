package core

import "core:bytes"
import "core:slice"

// The edits that take a value. The format spells it, with `Edit_Services.spell`, under the list's `write` options and
// the layout the container it goes in shows, and the text is recorded as it is: a value edit makes no check walk of
// its text. A value taken from the list's own document keeps its source bytes. A value with comments written on it
// is its value and a fact edit for each role written.

// Makes `v` the value of node `node`, spelled as the document's format spells it. A key node takes a text. A fact
// node or a flat text's container returns `.Bad_Index`, and a cell the format has no spelling for `.Bad_Value`.
set_value :: proc(list: ^Edit_List, node: Node_Index, v: Value) -> Error {
	return set_input(list, node, {value = v})
}

// Inserts `v` into the array `container` before its element `at`, or after its last when `at` is its length. In a
// flat text's root `v` is a record: an array or an object of cells.
insert_element_value :: proc(list: ^Edit_List, container: Node_Index, at: int, v: Value) -> Error {
	return insert_input(list, container, at, "", false, {value = v})
}

// Inserts `key` and `v` as a member of the object `container` before its member `at`, or after its last when `at` is its
// length.
insert_member_value :: proc(list: ^Edit_List, container: Node_Index, at: int, key: string, v: Value) -> Error {
	return insert_input(list, container, at, key, true, {value = v})
}

// Whether the format of `list`'s document spells a tag in its value's text, as TOML's datetime is, so a value written
// with a tag is spelled by it and no fact edit writes it.
tags_in_text :: proc(list: ^Edit_List) -> bool {
	return list.doc.readers.tag_fits != nil && (list.edit == nil || list.edit.prefix == nil)
}

// Makes the comments `c` writes the comments of node `node`: a role's bodies replace the node's, and a role whose
// bodies are the node's own makes no edit. A tag the value's text spells is no fact edit.
set_comments :: proc(list: ^Edit_List, node: Node_Index, c: ^Commented) -> Error {
	for role in c.written {
		if role == .Tag && tags_in_text(list) {
			continue
		}
		have, _ := comments(Node_Ref{list.doc, node}, role)
		if slice.equal(c.bodies[role], have) {
			continue
		}
		if e := set_facts(list, node, role, c.bodies[role], padded = true); e != nil {
			return e
		}
	}
	return nil
}

@(private)
set_spelled :: proc(list: ^Edit_List, node: Node_Index, n: Node, v: Value) -> Error {
	doc := list.doc
	if n.role == .Key && !is_flat(doc) {
		name, named := plain(v).(string)
		if !named {
			return refused(.Bad_Value)
		}
		return error_of(edit_add(list, node, .Set, .Key, 0, "", name))
	}
	text, owned, e := spell(list, v, node, false, node_start(n), false)
	if e != nil {
		return e
	}
	// A value spelled as the node already is makes no edit. A binary node's span leaves out its head, so it is no
	// spelling to compare.
	if !doc.readers.binary && bytes.equal(text, span(doc, node)) {
		if owned {
			delete(text, list.allocator)
		}
		return write_comments(list, node, v)
	}
	if err := edit_add_text(list, node, .Set, .Value, 0, text, owned); err.kind != .None {
		return error_of(err)
	}
	return write_comments(list, node, v)
}

@(private)
insert_spelled :: proc(list: ^Edit_List, container: Node_Index, at: int, key: string, member: bool, v: Value) -> Error {
	text, owned, e := insert_text(list, container, v)
	if e != nil {
		return e
	}
	if key == "" && !member {
		if err := edit_add_text(list, container, .Insert, .Value, u32(at), text, owned); err.kind != .None {
			return error_of(err)
		}
		return nil
	}
	// A key and its text share one allocation.
	err := edit_add(list, container, .Insert, .Key, u32(at), key, string(text))
	if owned {
		delete(text, list.allocator)
	}
	return error_of(err)
}

// The text an insert of `v` into `container` writes, which is the source bytes of a node of the list's document when `v`
// is one, else a new allocation, which `owned` says. A caller that records the text on another list inserts it as
// text.
insert_text :: proc(list: ^Edit_List, container: Node_Index, v: Value) -> (text: []u8, owned: bool, err: Error) {
	doc := list.doc
	// A record goes at the text's end for a byte order mark, and a member where the first member starts.
	place: u64 = u64(len(doc.src)) if is_flat(doc) && container == ROOT else member_start(doc, container)
	return spell(list, v, container, true, place, container == ROOT && is_flat(doc))
}

@(private)
write_comments :: proc(list: ^Edit_List, node: Node_Index, v: Value) -> Error {
	if c, is_commented := v.(^Commented); is_commented {
		return set_comments(list, node, c)
	}
	return nil
}

// The byte a member of container `c` is written at, whose line's indent a value over lines takes: the first member's, or
// the container's own.
@(private)
member_start :: proc(doc: ^Document, c: Node_Index) -> u64 {
	if first, ok := child_at(doc, c, 0); ok {
		return node_start(doc.nodes[first])
	}
	return node_start(doc.nodes[c])
}

// The text of `v` for the site `target`, a node the value replaces or with `into` the container it goes in. The text
// is the source bytes of a node of the list's document when `v` is one, or the bytes its format gives the node at
// `at`, else a new allocation, which `owned` says.
@(private)
spell :: proc(list: ^Edit_List, v: Value, target: Node_Index, into: bool, at: u64, record: bool) -> (text: []u8, owned: bool, err: Error) {
	doc := list.doc
	p := plain(v)
	// A tag written on the value that its text spells is written with it, so its node's bytes are not its text.
	c, is_commented := v.(^Commented)
	retagged := is_commented && .Tag in c.written && tags_in_text(list)
	if r, is_ref := p.(Node_Ref); is_ref && r.doc == doc && !retagged && !(list.write.sort_keys && value_kind(p) == .Object) {
		if list.edit == nil || list.edit.relocate == nil {
			return span(doc, r.node), false, nil
		}
		moved, fits := list.edit.relocate(doc, r.node, site_at(doc.src, at), list.allocator)
		if !fits {
			return nil, false, refused(.Bad_Value, .No_Spelling)
		}
		return moved, true, nil
	}
	if list.edit == nil || list.edit.spell == nil {
		return nil, false, refused(.Bad_Spec)
	}
	opts, colon := list.write, ""
	flat := is_flat(doc)
	// A format that commits its own edits, whose containers need no bracket, places and indents the text itself, so the
	// value keeps the list's base layout.
	placed := list.edit.commit != nil
	if k := value_kind(p); !flat && !placed && !list.fixed && (k == .Array || k == .Object) {
		opts, colon = site_layout(list, target, into)
	}
	text = list.edit.spell(doc, v if retagged else p, opts, colon, record, at, list.allocator) or_return
	if flat || placed || !opts.pretty || bytes.index_byte(text, '\n') < 0 {
		return text, true, nil
	}
	indent := line_indent(doc.src, at)
	if len(indent) == 0 {
		return text, true, nil
	}
	lines := bytes.count(text, {'\n'})
	spaced, merr := make([]u8, len(text) + lines * len(indent), list.allocator)
	if merr != nil {
		delete(text, list.allocator)
		return nil, false, refused(.No_Memory)
	}
	at_ := 0
	for b in text {
		spaced[at_] = b
		at_ += 1
		if b == '\n' {
			at_ += copy(spaced[at_:], indent)
		}
	}
	delete(text, list.allocator)
	return spaced, true, nil
}

// The container of each node of `list`'s document, `NO_NODE` for the root, kept in `list` for its next call, or nil
// when the table cannot be allocated.
parents_of :: proc(list: ^Edit_List) -> []Node_Index {
	if list.parents != nil {
		return list.parents
	}
	nodes := list.doc.nodes
	parents, merr := make([]Node_Index, len(nodes), list.allocator)
	if merr != nil {
		return nil
	}
	open := NO_NODE
	for node, i in nodes {
		for open != NO_NODE && int(open) + int(nodes[open].n) <= i {
			open = parents[open]
		}
		parents[i] = open
		if node.kind == .Array || node.kind == .Object {
			open = Node_Index(i)
		}
	}
	list.parents = parents
	return parents
}

// The layout a value takes at a site: the base `write`, then the layout each container from the root down to the site's
// container shows, each falling back to the one before. The site's container is `target`'s, or with `into` is `target`.
@(private)
site_layout :: proc(list: ^Edit_List, target: Node_Index, into: bool) -> (opts: Write_Options, colon: string) {
	opts = list.write
	parents := parents_of(list)
	if parents == nil {
		return
	}
	chain: [MAX_DEPTH]Node_Index
	n := 0
	for c := target if into else parents[target]; c != NO_NODE && n < len(chain); c = parents[c] {
		chain[n] = c
		n += 1
	}
	for i := n - 1; i >= 0; i -= 1 {
		opts, colon = shown_layout(list.doc, chain[i], opts, colon)
	}
	return
}

// The layout of the values container `c` holds: one member or element a line, in the indent and colon spacing `c`
// shows, when its first member starts a line, and compact when it shares the bracket's line. A container with no
// members, or with an indent the writer cannot repeat, shows none and takes `opts` and `colon`. A format whose
// containers need no bracket commits its own edits, and `spell` reads no layout for it.
@(private)
shown_layout :: proc(doc: ^Document, c: Node_Index, opts: Write_Options, colon: string) -> (Write_Options, string) {
	first, has := child_at(doc, c, 0)
	if !has {
		return opts, colon
	}
	l, spelled := opts, colon
	start := node_start(doc.nodes[first])
	if doc.nodes[c].kind == .Object {
		it := doc_pairs(doc, c)
		key, value, _ := doc_pair_next(&it)
		start = node_start(doc.nodes[key])
		if gap, spaced := colon_gap(doc.src[start + u64(len(span(doc, key))):node_start(doc.nodes[value])]); spaced {
			spelled = gap
		}
	}
	open := node_start(doc.nodes[c])
	if !has_line_end(doc.src[open + 1:start]) {
		l.pretty = false
		return l, ""
	}
	outer := line_indent(doc.src, open)
	inner := line_indent(doc.src, start)
	if !bytes.has_prefix(inner, outer) {
		return opts, colon
	}
	unit := inner[len(outer):]
	switch {
	case string(unit) == "\t":
		l.tab = true
	case len(unit) <= int(max(u8)) && bytes.count(unit, {' '}) == len(unit):
		l.tab, l.indent = false, u8(len(unit))
	case:
		return opts, colon
	}
	l.pretty = true
	return l, spelled
}

// The colon of a member with the blanks around it, when that is all `gap` holds.
@(private)
colon_gap :: proc(gap: []u8) -> (string, bool) {
	if bytes.count(gap, {':'}) != 1 {
		return "", false
	}
	for b in gap {
		if b != ':' && b != ' ' && b != '\t' {
			return "", false
		}
	}
	return string(gap), true
}

// The spaces and tabs that start the line holding byte `at`.
@(private)
line_indent :: proc(src: []u8, at: u64) -> []u8 {
	lo := min(at, u64(len(src)))
	for lo > 0 && src[lo - 1] != '\n' && src[lo - 1] != '\r' {
		lo -= 1
	}
	hi := lo
	for hi < u64(len(src)) && (src[hi] == ' ' || src[hi] == '\t') {
		hi += 1
	}
	return src[lo:hi]
}

// Appends an edit whose text is `text`, which the list takes over when `owned` and copies otherwise.
@(private)
edit_add_text :: proc(list: ^Edit_List, node: Node_Index, op: Edit_Op, role: Role, at: u32, text: []u8, owned: bool) -> Document_Error {
	if !owned {
		return edit_add(list, node, op, role, at, "", string(text))
	}
	if _, err := append(&list.edits, Edit{node = node, op = op, role = role, at = at, text = text if len(text) > 0 else nil}); err != nil {
		delete(text, list.allocator)
		return {kind = .No_Memory}
	}
	return {}
}
