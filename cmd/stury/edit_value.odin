package main

// How `stury edit` turns the filter's output value into edits of the node it replaces. A value the filter took from the
// node keeps its bytes, a container of the node's kind edits the node's members, and a member or element the output
// keeps but moves is moved with its bytes and comments. A value the filter built is written by jq's writer, or as a
// delimited cell. The comments the filter wrote on a value the file holds are written on its node. A whole text's
// value written new keeps its comments, and the comments of the values nested in it, through a second pass over the
// edited text, which holds a node for each.

import "core:bytes"
import "core:slice"
import "core:strings"
import core "../../core"
import "../../core/write"
import records "../../core/records"
import "jq"
import "message"

// One document's edit: the edit list the filter's output is recorded on, why it stopped when it fails, the file it is
// told in and the line of the record being edited, 0 for a whole document. `layout` writes a built value, the layout
// of the container being edited when `shown`, and `sorted` puts every object's members in key order. A table's column order is the whole table's, so its records' members are
// not moved here. `defers` says the caller writes the comments of values written new in a second pass, and `later`
// that one carries comments for it.
Edit_State :: struct {
	doc:    ^core.Document,
	list:   ^core.Edit_List,
	err:    string,
	name:   string,
	line:   int,
	layout: jq.Layout,
	shown:  bool,
	sorted: bool,
	defers: bool,
	later:  bool,
}

// The file, and the record's line when the edit is of a record.
edit_place :: proc(w: ^Edit_State) -> string {
	return message.build_temp("%s:%d", w.name, w.line) if w.line > 0 else w.name
}

// `node` as `v`, in place where the source has the same kind of container, and as one replacement otherwise.
edit_tree :: proc(w: ^Edit_State, node: core.Node_Index, value: jq.Value) -> bool {
	if c, is_commented := value.(^jq.Commented); is_commented {
		edit_comments(w, node, c) or_return
	}
	v := jq.plain(value)
	if r, is_ref := v.(jq.Ref); is_ref {
		if r.doc == w.doc && r.node == node {
			return !w.sorted || edit_sort(w, node)
		}
		// A value taken from another node brings that node's comments.
		if w.defers && !w.later {
			w.later = carries_comments(w, value, true)
		}
		// A flat text's record is not replaced whole, so another record is written into it cell by cell.
		if k := jq.kind(v); core.is_flat(w.doc) && (k == .Object || k == .Array) && core.kind(w.doc, node) == core.kind(r.doc, r.node) {
			v = edit_members_of(v)
		}
	}
	if _, is_ref := v.(jq.Ref); !is_ref {
		switch jq.kind(v) {
		case .Object:
			if core.kind(w.doc, node) == .Object {
				return edit_object(w, node, v.(^jq.Object))
			}
		case .Array:
			if a, is_array := v.(^jq.Array); is_array && core.kind(w.doc, node) == .Array {
				return edit_array(w, node, a.items[:])
			}
		case .Null, .False, .True, .Number, .String:
			if jq.compare(v, jq.Ref{w.doc, node}) == 0 {
				return true
			}
		}
	}
	text, ok := edit_text_of(w, v, core.node_start(w.doc.nodes[node]))
	if !ok {
		return false
	}
	return edit_replace(w, node, text)
}

// The comment edits of `node` for the roles `c` writes: a role's comments replaced by its bodies, or removed, and no
// edit where they are the node's own. A comment written is spelled `// body`, or `/* body */` where a line comment
// cannot end.
@(private = "file")
edit_comments :: proc(w: ^Edit_State, node: core.Node_Index, c: ^jq.Commented) -> bool {
	for role in c.written {
		edit_role(w, node, role, c.bodies[role]) or_return
	}
	return true
}

// The edit that makes `bodies` the comments of `node` with `role`, none when they already are.
edit_role :: proc(w: ^Edit_State, node: core.Node_Index, role: jq.Comment_Role, bodies: []string) -> bool {
	ROLES :: [jq.Comment_Role]core.Role {
		.Comment = .Comment,
		.Inline  = .Comment_Inline,
		.Foot    = .Comment_Foot,
	}
	roles := ROLES
	have, _ := jq.comments(jq.Ref{w.doc, node}, role)
	if slice.equal(bodies, have) {
		return true
	}
	return edit_check(w, core.set_facts(w.list, node, roles[role], bodies, padded = true))
}

// Whether `v` carries a comment that its text does not write: its own, or one of a value nested in it, which a value
// taken from the document keeps in its bytes unless `kept` is false, when its text is spelled new.
@(private = "file")
carries_comments :: proc(w: ^Edit_State, v: jq.Value, kept: bool) -> bool {
	for role in jq.Comment_Role {
		if bodies, _ := jq.comments(v, role); len(bodies) > 0 {
			return true
		}
	}
	p := jq.plain(v)
	k := jq.kind(p)
	if k != .Object && k != .Array {
		return false
	}
	r, is_ref := p.(jq.Ref)
	spelled := !kept || !is_ref || r.doc != w.doc || w.sorted && k == .Object
	if !spelled {
		return false
	}
	it := jq.iterate(p)
	for _, m in jq.next_member(&it) {
		if carries_comments(w, m, false) {
			return true
		}
	}
	return false
}

// The second pass: the comment edits that give `node` of the edited text, which holds the output value `v`, the
// comments `v` carries, and the same for the values nested in it. A comment the filter wrote is written, removed when
// it wrote none, and one `v` takes from a source node is written over the node's own.
edit_comment_tree :: proc(w: ^Edit_State, node: core.Node_Index, v: jq.Value) -> bool {
	for role in jq.Comment_Role {
		bodies, from := jq.comments(v, role)
		if from == .Written || from == .Source && len(bodies) > 0 {
			edit_role(w, node, role, bodies) or_return
		}
	}
	p := jq.plain(v)
	#partial switch jq.kind(p) {
	case .Object:
		if core.kind(w.doc, node) != .Object {
			return true
		}
		members := edit_members(w, node) or_return
		// The member a filter reads for a name is its last.
		read := make(map[string]core.Node_Index, len(members), context.temp_allocator)
		for m in members {
			read[m.name] = m.node
		}
		it := jq.iterate(p)
		for key, m in jq.next_member(&it) {
			if child, found := read[key]; found {
				edit_comment_tree(w, child, m) or_return
			}
		}
	case .Array:
		if core.kind(w.doc, node) != .Array {
			return true
		}
		children := core.children(w.doc, node)
		it := jq.iterate(p)
		for _, m in jq.next_member(&it) {
			child := core.child_next(&children) or_break
			edit_comment_tree(w, child, m) or_return
		}
	}
	return true
}

// Whether `v` carries a comment the filter wrote.
@(private = "file")
writes_comment :: proc(v: jq.Value) -> bool {
	c, is_commented := v.(^jq.Commented)
	if !is_commented {
		return false
	}
	for role in c.written {
		if len(c.bodies[role]) > 0 {
			return true
		}
	}
	return false
}

// A copy of the container `v` whose members are `v`'s own values.
@(private = "file")
edit_members_of :: proc(v: jq.Value) -> jq.Value {
	it := jq.iterate(v)
	if jq.kind(v) == .Array {
		a := jq.new_array()
		for _, m in jq.next_member(&it) {
			append(&a.items, m)
		}
		return a
	}
	o := jq.new_object()
	for key, m in jq.next_member(&it) {
		jq.object_put(o, key, m)
	}
	return o
}

// A source member: its decoded name and its value's node.
@(private = "file")
Source_Member :: struct {
	name: string,
	node: core.Node_Index,
}

// A member or element the output adds: its key, empty for an element, and its text.
@(private = "file")
Edit_New :: struct {
	key, text: string,
}

@(private = "file")
edit_object :: proc(w: ^Edit_State, node: core.Node_Index, obj: ^jq.Object) -> bool {
	parent := w.layout
	defer w.layout = parent
	w.layout = edit_shown_layout(w, node, parent)
	if len(obj.keys) > 0 && edit_bare(w, node) {
		return edit_replace(w, node, edit_text_of(w, obj, core.node_start(w.doc.nodes[node])) or_return)
	}
	members := edit_members(w, node) or_return
	// The member a filter reads for a name is its last, as the CLI reads a repeated key.
	read: map[string]int
	if len(members) > 8 {
		read = make(map[string]int, len(members), context.temp_allocator)
		for m, i in members {
			read[m.name] = i
		}
	}
	read_of :: proc(members: []Source_Member, read: map[string]int, key: string) -> int {
		if read != nil {
			return read[key] if key in read else -1
		}
		#reverse for m, i in members {
			if m.name == key {
				return i
			}
		}
		return -1
	}
	keys := obj.keys[:]
	if w.sorted {
		keys = slice.clone(keys, context.temp_allocator)
		slice.sort(keys)
	}
	entries := make([dynamic]int, 0, len(keys), context.temp_allocator)
	news := make([dynamic]Edit_New, context.temp_allocator)
	at := edit_member_at(w, node)
	for key in keys {
		value, _ := jq.object_get(obj, key)
		if i := read_of(members, read, key); i >= 0 {
			// A repeated name's other members keep their bytes and go just before the one the filter read.
			for m, k in members[:i] {
				if m.name == key {
					append(&entries, k)
				}
			}
			edit_tree(w, members[i].node, value) or_return
			append(&entries, i)
			continue
		}
		text := edit_text_of(w, value, at) or_return
		append(&news, Edit_New{key = key, text = text})
		append(&entries, -1 - (len(news) - 1))
	}
	for m in members {
		if _, kept := jq.object_get(obj, m.name); !kept {
			edit_check(w, core.remove(w.list, m.node)) or_return
		}
	}
	return edit_place_entries(w, node, len(members), entries[:], news[:])
}

// Records the inserts of `news` and, when the kept members are out of their source order, the order `entries` gives:
// a source member's position, or `-1 - k` for `news[k]`. A table's record keeps its column order here, since the
// table's column order is planned across its records.
@(private = "file")
edit_place_entries :: proc(w: ^Edit_State, node: core.Node_Index, length: int, entries: []int, news: []Edit_New) -> bool {
	flat := core.is_flat(w.doc) && core.kind(w.doc, node) == .Object
	monotone := true
	last := -1
	for e in entries {
		if e >= 0 {
			monotone = monotone && e > last
			last = e
		}
	}
	if !monotone && !flat {
		order := make([]u32, len(entries), context.temp_allocator)
		for e, i in entries {
			order[i] = u32(e) if e >= 0 else u32(length + (-1 - e))
		}
		for n in news {
			edit_insert(w, node, length, n) or_return
		}
		return edit_check(w, core.reorder(w.list, node, order))
	}
	last = -1
	for e in entries {
		switch {
		case e >= 0:
			last = e
		case flat:
			edit_insert(w, node, length, news[-1 - e]) or_return
		case:
			edit_insert(w, node, last + 1, news[-1 - e]) or_return
		}
	}
	return true
}

@(private = "file")
edit_insert :: proc(w: ^Edit_State, node: core.Node_Index, at: int, n: Edit_New) -> bool {
	if core.kind(w.doc, node) == .Object {
		return edit_check(w, core.insert(w.list, node, at, n.key, n.text))
	}
	return edit_check(w, core.insert(w.list, node, at, n.text))
}

// An array's elements: an element the output takes from it is kept and may move, one the output repeats or builds is
// matched by value or by place with one it does not take, and the rest are removed or inserted.
@(private = "file")
edit_array :: proc(w: ^Edit_State, node: core.Node_Index, items: []jq.Value) -> bool {
	parent := w.layout
	defer w.layout = parent
	w.layout = edit_shown_layout(w, node, parent)
	if len(items) > 0 && edit_bare(w, node) {
		built := jq.new_array(len(items))
		append(&built.items, ..items)
		return edit_replace(w, node, edit_text_of(w, built, core.node_start(w.doc.nodes[node])) or_return)
	}
	have := core.length(w.doc, node)
	children := make([]core.Node_Index, have, context.temp_allocator)
	sources := make([]jq.Value, have, context.temp_allocator)
	it := core.children(w.doc, node)
	for i in 0 ..< have {
		children[i], _ = core.child_next(&it)
		sources[i] = jq.Ref{w.doc, children[i]}
	}
	claims := make([]int, len(items), context.temp_allocator)
	for v, j in items {
		claims[j] = -1
		if r, is_ref := v.(jq.Ref); is_ref && r.doc == w.doc {
			if i, found := slice.binary_search(children, r.node); found {
				claims[j] = i
			}
		}
	}
	pairs := match_items(sources, items, claims)
	used := make([]bool, have, context.temp_allocator)
	entries := make([]int, len(items), context.temp_allocator)
	news := make([dynamic]Edit_New, context.temp_allocator)
	at := edit_member_at(w, node)
	for v, j in items {
		if i := pairs[j]; i >= 0 {
			used[i] = true
			edit_tree(w, children[i], v) or_return
			entries[j] = i
			continue
		}
		text := edit_text_of(w, v, at) or_return
		append(&news, Edit_New{text = text})
		entries[j] = -1 - (len(news) - 1)
	}
	#reverse for child, i in children {
		if !used[i] {
			edit_check(w, core.remove(w.list, child)) or_return
		}
	}
	return edit_place_entries(w, node, have, entries, news[:])
}

// Pairs each of `items` with the source it edits, or -1 for a new one. `claims` names the source an item was taken
// from, and the first item to take a source keeps it. The rest are matched in order: equal ends first, so an insert
// or removal keeps the tail's bytes, then by place.
match_items :: proc(sources, items: []jq.Value, claims: []int) -> []int {
	pairs := make([]int, len(items), context.temp_allocator)
	taken := make([]bool, len(sources), context.temp_allocator)
	free_items := make([dynamic]int, 0, len(items), context.temp_allocator)
	for c, j in claims {
		pairs[j] = -1
		if c >= 0 && !taken[c] {
			taken[c] = true
			pairs[j] = c
		} else {
			append(&free_items, j)
		}
	}
	free_sources := make([dynamic]int, 0, len(sources), context.temp_allocator)
	for t, i in taken {
		if !t {
			append(&free_sources, i)
		}
	}
	fi, fs := free_items[:], free_sources[:]
	equal :: proc(a, b: jq.Value) -> bool {
		return jq.compare(a, b) == 0
	}
	prefix := 0
	for prefix < min(len(fi), len(fs)) && equal(sources[fs[prefix]], items[fi[prefix]]) {
		pairs[fi[prefix]] = fs[prefix]
		prefix += 1
	}
	suffix := 0
	for suffix < min(len(fi), len(fs)) - prefix && equal(sources[fs[len(fs) - 1 - suffix]], items[fi[len(fi) - 1 - suffix]]) {
		pairs[fi[len(fi) - 1 - suffix]] = fs[len(fs) - 1 - suffix]
		suffix += 1
	}
	for k in prefix ..< min(len(fi), len(fs)) - suffix {
		pairs[fi[k]] = fs[k]
	}
	return pairs
}

// Under `-S`, a node the output keeps as it is still has its objects' members put in key order.
@(private = "file")
edit_sort :: proc(w: ^Edit_State, node: core.Node_Index) -> bool {
	#partial switch core.kind(w.doc, node) {
	case .Object:
		members := edit_members(w, node) or_return
		if !core.is_flat(w.doc) {
			Named :: struct {
				name: string,
				at:   u32,
			}
			named := make([]Named, len(members), context.temp_allocator)
			for m, i in members {
				named[i] = {m.name, u32(i)}
			}
			slice.stable_sort_by(named, proc(a, b: Named) -> bool { return a.name < b.name })
			order := make([]u32, len(members), context.temp_allocator)
			moved := false
			for n, i in named {
				order[i] = n.at
				moved ||= int(n.at) != i
			}
			if moved {
				edit_check(w, core.reorder(w.list, node, order)) or_return
			}
		}
		for m in members {
			edit_sort(w, m.node) or_return
		}
	case .Array:
		it := core.children(w.doc, node)
		for child in core.child_next(&it) {
			edit_sort(w, child) or_return
		}
	}
	return true
}

// The members of the object `node`, in source order.
@(private = "file")
edit_members :: proc(w: ^Edit_State, node: core.Node_Index) -> ([]Source_Member, bool) {
	members := make([dynamic]Source_Member, 0, core.length(w.doc, node), context.temp_allocator)
	it := core.pairs(w.doc, node)
	for {
		key, value, ok := core.pair_next(&it)
		if !ok {
			return members[:], true
		}
		name, named := edit_key_text(w, key)
		if !named {
			w.err = "cannot decode a member name"
			return nil, false
		}
		append(&members, Source_Member{name, value})
	}
}

// The byte a new member of `node` is written at, whose line's indent a value written over lines takes: the first
// member's, or the container's own.
@(private = "file")
edit_member_at :: proc(w: ^Edit_State, node: core.Node_Index) -> u64 {
	if first, ok := core.child_at(w.doc, node, 0); ok {
		return core.node_start(w.doc.nodes[first])
	}
	return core.node_start(w.doc.nodes[node])
}

@(private = "file")
edit_replace :: proc(w: ^Edit_State, node: core.Node_Index, text: string) -> bool {
	if text == string(core.span(w.doc, node)) {
		return true
	}
	return edit_check(w, core.set(w.list, node, text))
}

// Whether an edit was recorded, with its refusal in `w.err` when not.
@(private = "file")
edit_check :: proc(w: ^Edit_State, e: core.Error) -> bool {
	if e != nil {
		w.err = edit_error_text(w.doc.src, e)
		return false
	}
	return true
}

// The source text `v` takes at byte `at`: a value taken from the document keeps its span, and a value built is spelled
// by the document's format, a JSON value or a delimited cell. A JSON value written over lines takes the indent of
// `at`'s line on each line after its first.
edit_text_of :: proc(w: ^Edit_State, value: jq.Value, at: u64) -> (text: string, ok: bool) {
	// A value written new has no node to hold its comments until the second pass.
	if w.defers {
		w.later = w.later || carries_comments(w, value, true)
	} else if writes_comment(value) {
		w.err = "cannot write a comment on a value the file does not hold"
		return "", false
	}
	v := jq.plain(value)
	if r, is_ref := v.(jq.Ref); is_ref && r.doc == w.doc && !(w.sorted && jq.kind(v) == .Object) {
		return string(core.span(r.doc, r.node)), true
	}
	if core.is_flat(w.doc) {
		return edit_cell_of(w, v, at)
	}
	text = jq.to_json(v, w.layout, context.temp_allocator)
	if !w.layout.opts.pretty || !strings.contains(text, "\n") {
		return text, true
	}
	indent := edit_line_indent(w.doc.src, at)
	if len(indent) == 0 {
		return text, true
	}
	b := strings.builder_make(0, len(text) + 8 * len(indent), context.temp_allocator)
	for line, i in strings.split_lines(text, context.temp_allocator) {
		if i > 0 {
			strings.write_byte(&b, '\n')
			strings.write_string(&b, string(indent))
		}
		strings.write_string(&b, line)
	}
	return strings.to_string(b), true
}

// The layout a value built in the container `c` is written in under `shown`: one member or element a line, in the
// indent and colon spacing `c` shows, when its first member starts a line, and compact when it shares the bracket's
// line. A container with no members, or with an indent the writer cannot repeat, shows none and takes `parent`.
@(private = "file")
edit_shown_layout :: proc(w: ^Edit_State, c: core.Node_Index, parent: jq.Layout) -> jq.Layout {
	doc := w.doc
	first, has := core.child_at(doc, c, 0)
	if !w.shown || !has || core.is_flat(doc) {
		return parent
	}
	l := parent
	start := core.node_start(doc.nodes[first])
	if core.kind(doc, c) == .Object {
		it := core.pairs(doc, c)
		key, value, _ := core.pair_next(&it)
		start = core.node_start(doc.nodes[key])
		if colon, spaced := edit_colon(doc.src[start + u64(len(core.span(doc, key))):core.node_start(doc.nodes[value])]); spaced {
			l.colon = colon
		}
	}
	open := core.node_start(doc.nodes[c])
	if !core.has_line_end(doc.src[open + 1:start]) {
		l.opts.pretty, l.colon = false, ""
		return l
	}
	outer := edit_line_indent(doc.src, open)
	inner := edit_line_indent(doc.src, start)
	if !bytes.has_prefix(inner, outer) {
		return parent
	}
	unit := inner[len(outer):]
	switch {
	case string(unit) == "\t":
		l.opts.tab = true
	case len(unit) <= int(max(u8)) && bytes.count(unit, {' '}) == len(unit):
		l.opts.tab, l.opts.indent = false, u8(len(unit))
	case:
		return parent
	}
	l.opts.pretty = true
	return l
}

// Whether the container `node` is empty with nothing but blanks inside, so a value built for it is written whole in the
// layout it takes, as it shows none for its members.
@(private = "file")
edit_bare :: proc(w: ^Edit_State, node: core.Node_Index) -> bool {
	if core.length(w.doc, node) > 0 || core.is_flat(w.doc) {
		return false
	}
	text := core.span(w.doc, node)
	for b in text[1:len(text) - 1] {
		if b != ' ' && b != '\t' && b != '\n' && b != '\r' {
			return false
		}
	}
	return true
}

// The colon of a member with the blanks around it, when that is all `gap` holds.
@(private = "file")
edit_colon :: proc(gap: []u8) -> (string, bool) {
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
@(private = "file")
edit_line_indent :: proc(src: []u8, at: u64) -> []u8 {
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

// The text of one delimited cell at byte `at`: the format's own writer spells the quotes and escapes. A null cell is
// empty.
edit_cell_of :: proc(w: ^Edit_State, v: jq.Value, at: u64) -> (text: string, ok: bool) {
	cell: string
	scalar: write.Scalar
	switch jq.kind(v) {
	case .Null:
		return "", true
	case .False:
		cell, scalar = "false", write.Tree_Part.False
	case .True:
		cell, scalar = "true", write.Tree_Part.True
	case .String:
		cell, _ = jq.string_of(v)
	case .Number:
		cell = jq.to_json(v, {}, context.temp_allocator)
		scalar = write.Number_Literal{cell}
	case .Array, .Object:
		what := "an array" if jq.kind(v) == .Array else "an object"
		w.err = message.build_temp("a cell is a text, a number, true, false or null; tojson makes text of %s", what)
		return "", false
	}
	// An empty string is the one text a TSV cell cannot tell from null.
	if jq.kind(v) == .String && len(cell) == 0 && w.doc.as.opts[0] == '\t' {
		w.err = "cannot write an empty text: a TSV cell cannot hold one"
		return "", false
	}
	// A TSV cell has no quotes, so a byte order mark it starts with is refused only where it would start the text.
	bom := ""
	if w.doc.as.opts[0] == '\t' && strings.has_prefix(cell, "\xef\xbb\xbf") && at > core.text_start(w.doc.src, 0) {
		bom, cell = cell[:3], cell[3:]
	}
	wr: records.Writer
	if kind := records.writer_init(&wr, {}, w.doc.as, .Lines, allocator = context.temp_allocator); kind != .None {
		w.err = "a delimited cell cannot be written"
		return "", false
	}
	if jq.kind(v) == .String {
		scalar = cell
	}
	cells := [1]write.Scalar{scalar}
	if kind := records.write_cells(&wr, cells[:]); kind != .None {
		w.err = edit_cell_refusal(cell, jq.kind(v) == .String && w.doc.spelling.resolves != nil && w.doc.spelling.resolves(w.doc.as))
		return "", false
	}
	out, verr := records.writer_end(&wr)
	if verr != nil {
		w.err = edit_cell_refusal(cell, false)
		return "", false
	}
	text = strings.trim_right(string(out), "\r\n")
	// A table cell is a string or null, and a quoted empty one is the string.
	if jq.kind(v) == .String && len(text) == 0 && bom == "" {
		text = `""`
	}
	if bom != "" {
		text = strings.concatenate({bom, text}, context.temp_allocator)
	}
	return text, true
}

// Why the table's writer refused `cell`.
@(private = "file")
edit_cell_refusal :: proc(cell: string, inferred: bool) -> string {
	why := "the format has no spelling for it"
	if strings.has_prefix(cell, "\xef\xbb\xbf") {
		why = "it would start the text with a byte order mark"
	} else if inferred {
		why = "--infer would read it back as a number, true or false, and the format has no quotes"
	}
	return message.build_temp("cannot write the cell %q: %s", cell, why)
}

edit_key_text :: proc(w: ^Edit_State, key: core.Node_Index) -> (string, bool) {
	buf: [256]u8
	if text, ok := core.text(w.doc, key, buf[:]); ok {
		return strings.clone(text, context.temp_allocator), true
	}
	return core.text_clone(w.doc, key, context.temp_allocator)
}

edit_error_text :: proc(src: []u8, e: core.Error) -> string {
	b := strings.builder_make(context.temp_allocator)
	core.render(strings.to_writer(&b), src, e)
	return strings.to_string(b)
}
