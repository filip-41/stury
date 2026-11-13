package toml

// TOML's edit services. A table is not one range of bytes: its lines stand under its header, its sub-tables are
// sections elsewhere, and a dotted key spreads its lines over a section. So the format commits its edits itself
// instead of through `compose.commit`, which composes one range per container. Each edit becomes splices of source
// bytes: a scalar or inline value is replaced in place, a member of a table is a line placed after the table's last
// line and before its sections, a table or an array of tables is removed section by section, and a comment is a
// line above a statement or a comment after its value. Every byte no splice touches stays. The result is read again
// by the walk, so an edit that breaks a rule of the language is `.Bad_Result`.

import "base:runtime"
import "core:bytes"
import "core:slice"
import core "../core"
import compose "../core/compose"
import engine "../core/build"
import typed "../core/typed"
import write "../core/write"

// Why an edit of a TOML text is refused, indexed by `Edit_Detail`.
@(private)
Edit_Detail :: enum u8 {
	None,
	Table_Replaced, // a set of a table or of the document
	Table_Key, // a rename of the key of a table
	Reordered, // a reorder of a table's members
	Inline_Comment, // a comment inside an inline table or array
	Foot_Comment, // a foot comment of a table
	No_Statement, // a comment on a node that has no line of its own
	Tag_Fact, // a tag, an anchor or an alias
	Many_Comments, // several inline comments
	Element_Not_Table, // an element of an array of tables that is no table
	Misplaced, // a section that would join another element of an array of tables
	Comment_Body, // a comment that holds a control byte
	Inline_Dotted, // a member added to a table dotted inside an inline table
}

@(private, rodata)
EDIT_RULES := core.Rules{"toml_edit", {
	{},
	{"table_replaced", "A TOML table is not replaced by a value, and a TOML document is a table: change its members"},
	{"table_key", "The key of a TOML table is written in more than one place"},
	{"reordered", "A TOML table keeps its members in the order its lines and sections have"},
	{"inline_comment", "A comment inside an inline table or array is not edited"},
	{"foot_comment", "A TOML table has no foot comment: a comment after its last line is the head of what follows"},
	{"no_statement", "This node has no line of its own to hold a comment"},
	{"tag_fact", "A TOML datetime is written by its text: a tag, an anchor or an alias is not an edit"},
	{"many_comments", "A line holds one comment after its value"},
	{"element_not_table", "An array of tables takes a table"},
	{"misplaced", "The new section would join the last element of an array of tables, not the one holding this table"},
	{"comment_body", "A comment holds a control byte TOML cannot read"},
	{"inline_dotted", "A key dotted inside an inline table takes no new member"},
}}

// TOML's edit services, the same table for both specs.
@(private, rodata)
EDIT := core.Edit_Services {
	value    = edit_value,
	key_text = edit_key_text,
	comment  = proc(_: ^core.Document, _: u8) -> (core.Comment_Spelling, u8) {return .Byte, '#'},
	validate = edit_validate,
	spell    = edit_spell,
	relocate = edit_relocate,
	commit   = edit_commit,
}

// Returns an edit list over `doc`. A document an entry point reads holds no edit services, so the list takes TOML's.
edit_list_init :: proc(doc: ^core.Document, spec: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = &EDIT
	return list
}

// Makes `v` the value at every answer of `path` over `src`, in one call, and returns the new text, which the caller frees
// with `allocator`, keeping every byte the edit does not reach. A `typed.Raw` is the text of a TOML value, a struct, a
// slice or a map is built by `plan`, and any other value is spelled as an inline TOML value. A `Name` the path ends in
// that its table lacks is inserted as the TOML commit places it.
set :: proc(src: []u8, spec: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	scratch: write.Scratch
	defer write.scratch_destroy(&scratch)
	in_ := write.edit_input(v, plan, &scratch) or_return
	doc, berr := build(src, spec, opts, read.dups, allocator)
	defer core.destroy(&doc)
	if berr != nil {
		return nil, berr
	}
	list := edit_list_init(&doc, spec, allocator)
	defer core.edit_list_destroy(&list)
	return engine.set_answers(&list, path, in_, read, allocator)
}

// A value an edit writes, spelled as the inline value a line holds: the token write at a site of the document.
@(private)
edit_spell :: proc(doc: ^core.Document, v: core.Value, opts: core.Write_Options, _: string, _: bool, at: u64, allocator: runtime.Allocator) -> ([]u8, core.Error) {
	text, err := write.write_laid(v, doc.as, opts, "", &TOKENS, allocator, core.site_at(doc.src, at))
	return text, core.error_of(err)
}

// Checks `src` as exactly one value: `r = ` before it reads as one member, and the value ends where `src` ends.
@(private)
edit_value :: proc(v: ^core.Token_View, src: []u8, allocator: runtime.Allocator) -> core.Document_Error {
	buf, failed := make([]u8, len(src) + 5, allocator)
	if failed != nil {
		return {kind = .No_Memory}
	}
	defer delete(buf, allocator)
	copy(buf, "r = ")
	copy(buf[4:], src)
	buf[len(buf) - 1] = '\n'
	doc, err := build_text(buf, v.as, allocator)
	defer core.destroy(&doc)
	#partial switch err.kind {
	case .None:
	case .Walk:
		bad := core.Document_Error{kind = .Bad_Value, inner = err.inner}
		bad.inner.at -= min(bad.inner.at, 4)
		return bad
	case:
		return err
	}
	if core.length(&doc, core.ROOT) != 1 {
		return {kind = .Bad_Value}
	}
	it := core.pairs(&doc, core.ROOT)
	_, value, _ := core.pair_next(&it)
	cx := Cx{doc = &doc, src = buf}
	lo, _ := core.scalar_ends(doc.nodes[value])
	if doc.nodes[value].kind > .Plain {
		lo = doc.nodes[value].lo
	}
	if lo != 4 || node_end(&cx, u32(value)) != u64(len(src)) + 4 {
		return {kind = .Bad_Value}
	}
	return {}
}

// Writes the decoded name `name` as a key: bare when it can be, else a basic string.
@(private)
edit_key_text :: proc(_: ^core.Document, name: []u8, text: ^[dynamic]u8) -> bool {
	spelled := spell_key(name, context.allocator)
	defer delete(spelled)
	_, failed := append(text, ..spelled)
	return failed == nil
}

@(private = "file")
spell_key :: proc(name: []u8, allocator: runtime.Allocator) -> []u8 {
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, allocator)
	put_key(&out, string(name))
	bytes, _ := write.finish(&out)
	return bytes
}

// The bytes node `node` has at a site of the document: its own for a scalar or an inline value, else the table written
// in line.
@(private)
edit_relocate :: proc(doc: ^core.Document, node: core.Node_Index, _: core.Site, allocator: runtime.Allocator) -> ([]u8, bool) {
	cx := Cx{doc = doc, src = doc.src, a = allocator}
	build_parents(&cx)
	defer delete(cx.parent, allocator)
	switch form_of(&cx, u32(node)) {
	case .Scalar, .Inline:
		lo, _ := core.scalar_ends(doc.nodes[node])
		return slice.clone(doc.src[lo:node_end(&cx, u32(node))], allocator), true
	case .Root, .Header, .Dotted, .Implicit, .Tables:
	}
	spill: [write.ROOM_MAX]u8 = ---
	l := Layout{doc = doc, own = doc.readers.format == rules_of}
	l.arena.backing_allocator = context.allocator
	defer runtime.arena_destroy(&l.arena)
	l.path.allocator = runtime.arena_allocator(&l.arena)
	write.init(&l.out, &spill, allocator)
	kind := put_inline(&l, node)
	text, err := write.finish(&l.out, {kind = kind})
	return text, err.kind == .None
}

// How a node stands in the text.
@(private = "file")
Form :: enum u8 {
	Root, // the document
	Scalar, // a value with one range
	Inline, // an inline table or array, one range with its brackets
	Header, // a table a `[header]` or `[[header]]` names
	Dotted, // a table a dotted key made, whose lines lie in the table that holds the key
	Implicit, // a table only the headers of its members name
	Tables, // an array of tables
}

// A header and the lines after it, in source order. `head` is where its head comments start.
@(private = "file")
Section :: struct {
	ls, head: u64,
	node:     u32,
}

@(private = "file")
Open :: struct {
	id, end: u32,
}

@(private = "file")
Cx :: struct {
	doc:      ^core.Document,
	src:      []u8,
	a:        runtime.Allocator,
	eol:      string,
	parent:   []u32,
	sections: [dynamic]Section,
	sec_of:   []i32,
	comments: [dynamic]u64, // where each comment starts, sorted
	splices:  [dynamic]compose.Splice,
	seen:     map[u64]struct{},
	removed:  map[u32]int, // the members or elements an inline container loses
	refill:   map[u32][dynamic]Refill, // what a container that loses all of them gets in their place
	foot_at:  u64, // where the root's foot comments start, or the end of the text
	err:      core.Document_Error,
}

// A member or element inserted into an inline container that is left with only what it is given.
@(private = "file")
Refill :: struct {
	at:   u32,
	text: string,
}

@(private = "file")
refuse_edit :: proc(cx: ^Cx, node: core.Node_Index, detail: Edit_Detail) -> bool {
	cx.err = {kind = .Frozen, at = u64(node), inner = {rules = &EDIT_RULES, detail = u8(detail)}}
	return false
}

@(private = "file")
build_parents :: proc(cx: ^Cx) {
	nodes := cx.doc.nodes
	cx.parent = make([]u32, len(nodes), cx.a)
	stack := make([dynamic]Open, cx.a)
	defer delete(stack)
	for i in 0 ..< len(nodes) {
		for len(stack) > 0 && u32(i) >= stack[len(stack) - 1].end {
			pop(&stack)
		}
		cx.parent[i] = stack[len(stack) - 1].id if len(stack) > 0 else NIL
		if n := nodes[i]; n.kind == .Object || n.kind == .Array {
			append(&stack, Open{u32(i), u32(i) + n.n})
		}
	}
}

@(private = "file")
form_of :: proc(cx: ^Cx, i: u32) -> Form {
	if i == 0 {
		return .Root
	}
	n := cx.doc.nodes[i]
	#partial switch n.kind {
	case .Object:
		switch cx.src[n.lo] {
		case '{':
			return .Inline
		case '[':
			return .Header
		}
		key := cx.doc.nodes[i - 1]
		if first_byte(cx.src, compose.line_start(cx.src, key.lo)) == '[' {
			return .Implicit
		}
		return .Dotted
	case .Array:
		if n.n > 1 {
			first := cx.doc.nodes[i + 1]
			if first.kind == .Object && cx.src[first.lo] == '[' {
				return .Tables
			}
		}
		return .Inline
	}
	return .Scalar
}

// The text's geometry: lines, comment lines and the comments directly above a line.

// One past the line feed that ends the line holding `p`, or the end of the text.
@(private = "file")
line_end :: proc(src: []u8, p: u64) -> u64 {
	i := min(p, u64(len(src)))
	for i < u64(len(src)) && src[i] != '\n' {
		i += 1
	}
	return min(i + 1, u64(len(src)))
}

// The first byte on the line at `ls` that is no blank, or 0.
@(private = "file")
first_byte :: proc(src: []u8, ls: u64) -> u8 {
	for i := ls; i < u64(len(src)); i += 1 {
		switch src[i] {
		case ' ', '\t', '\r':
		case:
			return src[i] if src[i] != '\n' else 0
		}
	}
	return 0
}

@(private = "file")
blank_line :: proc(src: []u8, ls: u64) -> bool {
	return ls >= u64(len(src)) || first_byte(src, ls) == 0
}

@(private = "file")
indent_of :: proc(src: []u8, p: u64) -> []u8 {
	ls := compose.line_start(src, p)
	end := ls
	for end < u64(len(src)) && (src[end] == ' ' || src[end] == '\t') {
		end += 1
	}
	return src[ls:end]
}

// Whether the line at `ls` is a comment of its own.
@(private = "file")
comment_line :: proc(cx: ^Cx, ls: u64) -> bool {
	for i := ls; i < u64(len(cx.src)) && cx.src[i] != '\n'; i += 1 {
		if cx.src[i] != ' ' && cx.src[i] != '\t' {
			_, found := slice.binary_search(cx.comments[:], i)
			return found
		}
	}
	return false
}

// Where the comment lines that end at line `ls` start.
@(private = "file")
head_start :: proc(cx: ^Cx, ls: u64) -> u64 {
	at := ls
	for at > 0 {
		prev := compose.line_start(cx.src, at - 1)
		if !comment_line(cx, prev) {
			break
		}
		at = prev
	}
	return at
}

// The first byte past blanks, commas and comments.
@(private = "file")
skip_blank :: proc(src: []u8, p: u64) -> u64 {
	i := p
	for i < u64(len(src)) {
		switch src[i] {
		case ' ', '\t', '\r', '\n', ',':
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

@(private = "file")
last_value :: proc(cx: ^Cx, c: u32) -> u32 {
	last := NIL
	if cx.doc.nodes[c].kind == .Object {
		it := core.pairs(cx.doc, core.Node_Index(c))
		for _, v in core.pair_next(&it) {
			last = u32(v)
		}
		return last
	}
	it := core.children(cx.doc, core.Node_Index(c))
	for v in core.child_next(&it) {
		last = u32(v)
	}
	return last
}

// One past the last byte of a value, a closing bracket included. A dotted table ends where its last member does.
@(private = "file")
node_end :: proc(cx: ^Cx, i: u32) -> u64 {
	n := cx.doc.nodes[i]
	#partial switch n.kind {
	case .Object, .Array:
		last := last_value(cx, i)
		if form_of(cx, i) == .Inline {
			from := n.lo + 1
			if last != NIL {
				from = node_end(cx, last)
			}
			return skip_blank(cx.src, from) + 1
		}
		return node_end(cx, last) if last != NIL else n.lo
	}
	_, hi := core.scalar_ends(n)
	return hi
}

// The end of the last line of a statement: the line that holds the end of a value, its comment included.
@(private = "file")
statement_end :: proc(cx: ^Cx, i: u32) -> u64 {
	return line_end(cx.src, node_end(cx, i))
}

// The first and last line of a member of a table that is written as lines: the start of the comments above it and the
// end of its last line. A dotted table's lines may lie apart, so the last is the latest.
@(private = "file")
lines_of :: proc(cx: ^Cx, v: u32) -> (head, end: u64, ok: bool) {
	#partial switch form_of(cx, v) {
	case .Scalar, .Inline:
		head = head_start(cx, compose.line_start(cx.src, cx.doc.nodes[v - 1].lo))
		return head, statement_end(cx, v), true
	case .Dotted:
		head = head_start(cx, compose.line_start(cx.src, cx.doc.nodes[v - 1].lo))
		it := core.pairs(cx.doc, core.Node_Index(v))
		for _, w in core.pair_next(&it) {
			_, e, _ := lines_of(cx, u32(w))
			end = max(end, e)
		}
		return head, end, true
	}
	return 0, 0, false
}

@(private = "file")
build_sections :: proc(cx: ^Cx) {
	nodes := cx.doc.nodes
	cx.sec_of = make([]i32, len(nodes), cx.a)
	for i in 1 ..< len(nodes) {
		cx.sec_of[i] = -1
		if nodes[i].kind == .Object && form_of(cx, u32(i)) == .Header {
			ls := compose.line_start(cx.src, nodes[i].lo)
			append(&cx.sections, Section{ls = ls, head = head_start(cx, ls), node = u32(i)})
		}
	}
	slice.sort_by(cx.sections[:], proc(a, b: Section) -> bool {return a.ls < b.ls})
	for s, k in cx.sections {
		cx.sec_of[s.node] = i32(k)
	}
}

// One past the last byte of the section `k`: the line before the comments of the next section, or the text's end.
@(private = "file")
section_end :: proc(cx: ^Cx, k: int) -> u64 {
	hi := cx.foot_at
	if k + 1 < len(cx.sections) {
		hi = cx.sections[k + 1].head
	}
	return max(hi, line_end(cx.src, cx.sections[k].ls))
}

@(private = "file")
add :: proc(cx: ^Cx, lo, hi: u64, text: []u8) {
	append(&cx.splices, compose.Splice{lo = lo, hi = hi, text = slice.clone(text, cx.a), seq = len(cx.splices)})
}

@(private = "file")
add_text :: proc(cx: ^Cx, lo, hi: u64, text: string) {
	add(cx, lo, hi, transmute([]u8)text)
}

@(private = "file")
key_source :: proc(cx: ^Cx, key: u32) -> string {
	k := cx.doc.nodes[key]
	return string(cx.src[k.lo:k.lo + u64(k.n)])
}

// The text of an inserted member or element.
@(private = "file")
member_text :: proc(cx: ^Cx, e: core.Edit, keyed: bool) -> string {
	if !keyed {
		return string(e.text)
	}
	b := make([dynamic]u8, cx.a)
	compose.puts(&b, string(spell_key(e.key, cx.a)), " = ", string(e.text))
	return string(b[:])
}

// Applies one edit as splices.
@(private = "file")
apply :: proc(cx: ^Cx, e: core.Edit) -> bool {
	switch e.op {
	case .Set:
		if e.role == .Key {
			return set_key(cx, e)
		}
		return set_value(cx, e)
	case .Insert:
		return insert_edit(cx, e)
	case .Remove:
		return remove_edit(cx, e)
	case .Reorder:
		return refuse_edit(cx, e.node, .Reordered)
	case .Set_Fact, .Remove_Fact:
		return fact_edit(cx, e)
	}
	return true
}

@(private = "file")
set_value :: proc(cx: ^Cx, e: core.Edit) -> bool {
	i := u32(e.node)
	n := cx.doc.nodes[i]
	switch form_of(cx, i) {
	case .Scalar:
		lo, hi := core.scalar_ends(n)
		add_text(cx, lo, hi, string(e.text))
	case .Inline:
		add_text(cx, n.lo, node_end(cx, i), string(e.text))
	case .Root, .Header, .Dotted, .Implicit, .Tables:
		return refuse_edit(cx, e.node, .Table_Replaced)
	}
	return true
}

@(private = "file")
set_key :: proc(cx: ^Cx, e: core.Edit) -> bool {
	i := u32(e.node)
	switch form_of(cx, i + 1) {
	case .Scalar, .Inline:
		k := cx.doc.nodes[i]
		add(cx, k.lo, k.lo + u64(k.n), spell_key(e.text, cx.a))
	case .Root, .Header, .Dotted, .Implicit, .Tables:
		return refuse_edit(cx, e.node, .Table_Key)
	}
	return true
}

// A member of an inline table or an element of an inline array, and the bytes it covers.
@(private = "file")
Item :: struct {
	start, end: u64,
	node:       u32,
}

@(private = "file")
items_of :: proc(cx: ^Cx, c: u32) -> []Item {
	items := make([dynamic]Item, cx.a)
	if cx.doc.nodes[c].kind == .Object {
		it := core.pairs(cx.doc, core.Node_Index(c))
		for k, v in core.pair_next(&it) {
			append(&items, Item{cx.doc.nodes[k].lo, node_end(cx, u32(v)), u32(v)})
		}
		return items[:]
	}
	it := core.children(cx.doc, core.Node_Index(c))
	for v in core.child_next(&it) {
		lo, _ := core.scalar_ends(cx.doc.nodes[v])
		append(&items, Item{lo, node_end(cx, u32(v)), u32(v)})
	}
	return items[:]
}

@(private = "file")
starts_line :: proc(cx: ^Cx, p: u64) -> bool {
	for b in cx.src[compose.line_start(cx.src, p):p] {
		if b != ' ' && b != '\t' {
			return false
		}
	}
	return true
}

@(private = "file")
insert_edit :: proc(cx: ^Cx, e: core.Edit) -> bool {
	c := u32(e.node)
	switch form_of(cx, c) {
	case .Inline:
		return insert_inline(cx, e, c)
	case .Root, .Header, .Implicit:
		return insert_line(cx, e, c)
	case .Dotted:
		return insert_dotted(cx, e, c)
	case .Tables:
		return insert_element(cx, e, c)
	case .Scalar:
	}
	return true
}

// Whether the `n` members of inline container `c` are all removed and the container holds no comment, so what is left
// is written in one piece.
@(private = "file")
cleared :: proc(cx: ^Cx, c: u32, n: int) -> bool {
	if n == 0 || cx.removed[c] != n {
		return false
	}
	return bytes.index_byte(cx.src[cx.doc.nodes[c].lo:node_end(cx, c)], '#') < 0
}

// The interior of every container `cleared` found, now its refill: the inserts in their order, or nothing.
@(private = "file")
refill_cleared :: proc(cx: ^Cx) {
	for c, count in cx.removed {
		if !cleared(cx, c, count) || len(items_of(cx, c)) != count {
			continue
		}
		list := cx.refill[c]
		slice.stable_sort_by(list[:], proc(a, b: Refill) -> bool {return a.at < b.at})
		keyed := cx.doc.nodes[c].kind == .Object
		b := make([dynamic]u8, cx.a)
		for r, i in list {
			compose.puts(&b, ", " if i > 0 else " " if keyed else "", r.text)
		}
		if keyed && len(list) > 0 {
			compose.puts(&b, " ")
		}
		add(cx, cx.doc.nodes[c].lo + 1, node_end(cx, c) - 1, b[:])
	}
}

@(private = "file")
insert_inline :: proc(cx: ^Cx, e: core.Edit, c: u32) -> bool {
	src := cx.src
	items := items_of(cx, c)
	keyed := cx.doc.nodes[c].kind == .Object
	item := member_text(cx, e, keyed)
	closer := node_end(cx, c) - 1
	at := int(e.at)
	n := len(items)
	if cleared(cx, c, n) {
		list := cx.refill[c]
		if list == nil {
			list = make([dynamic]Refill, cx.a)
		}
		append(&list, Refill{e.at, item})
		cx.refill[c] = list
		return true
	}
	if n == 0 {
		if bytes.index_byte(src[cx.doc.nodes[c].lo + 1:closer], '#') >= 0 {
			return refuse_edit(cx, e.node, .Inline_Comment)
		}
		b := make([dynamic]u8, cx.a)
		compose.puts(&b, " " if keyed else "", item, " " if keyed else "")
		add(cx, cx.doc.nodes[c].lo + 1, closer, b[:])
		return true
	}
	if at >= n {
		last := items[n - 1]
		if starts_line(cx, last.start) && closer >= line_end(src, last.end) {
			pos := line_end(src, last.end)
			p := last.end
			for p < u64(len(src)) && (src[p] == ' ' || src[p] == '\t') {
				p += 1
			}
			if src[p] != ',' {
				add_text(cx, last.end, last.end, ",")
			}
			b := make([dynamic]u8, cx.a)
			compose.puts(&b, string(indent_of(src, last.start)), item, ",", cx.eol)
			add(cx, pos, pos, b[:])
		} else {
			b := make([dynamic]u8, cx.a)
			compose.puts(&b, ", ", item)
			add(cx, last.end, last.end, b[:])
		}
		return true
	}
	t := items[at]
	b := make([dynamic]u8, cx.a)
	if starts_line(cx, t.start) {
		compose.puts(&b, string(indent_of(src, t.start)), item, ",", cx.eol)
		ls := compose.line_start(src, t.start)
		add(cx, ls, ls, b[:])
	} else {
		compose.puts(&b, item, ", ")
		add(cx, t.start, t.start, b[:])
	}
	return true
}

// A line `text` placed at `pos`, with a line end first when the text ends without one.
@(private = "file")
put_line_at :: proc(cx: ^Cx, pos: u64, line: string, blank_after: bool) {
	b := make([dynamic]u8, cx.a)
	if pos > 0 && cx.src[pos - 1] != '\n' {
		compose.puts(&b, cx.eol)
	}
	compose.puts(&b, line, cx.eol)
	if blank_after && pos < u64(len(cx.src)) && !blank_line(cx.src, pos) {
		compose.puts(&b, cx.eol)
	}
	add(cx, pos, pos, b[:])
}

@(private = "file")
insert_line :: proc(cx: ^Cx, e: core.Edit, t: u32) -> bool {
	line := member_text(cx, e, true)
	if insert_member_sections(cx, e, t) {
		return true
	}
	if form_of(cx, t) == .Implicit {
		return insert_section(cx, e, t, line)
	}
	src := cx.src
	pos, found := u64(0), false
	before, has_before := u64(0), false
	at, k := int(e.at), 0
	it := core.pairs(cx.doc, core.Node_Index(t))
	for _, v in core.pair_next(&it) {
		if head, end, ok := lines_of(cx, u32(v)); ok {
			pos, found = max(pos, end), true
			if k == at {
				before, has_before = head, true
			}
		}
		k += 1
	}
	if has_before {
		put_line_at(cx, before, line, false)
		return true
	}
	if found {
		put_line_at(cx, pos, line, false)
		return true
	}
	switch {
	case t != 0:
		put_line_at(cx, line_end(src, cx.doc.nodes[t].lo), line, true)
	case len(cx.sections) > 0:
		put_line_at(cx, cx.sections[0].head, line, true)
	case:
		put_line_at(cx, cx.foot_at, line, false)
	}
	return true
}

// A dotted table's new member goes after its latest line, behind the dotted keys that lead to it.
@(private = "file")
insert_dotted :: proc(cx: ^Cx, e: core.Edit, d: u32) -> bool {
	src := cx.src
	for p := cx.parent[d]; p != NIL; p = cx.parent[p] {
		if form_of(cx, p) == .Inline {
			return refuse_edit(cx, e.node, .Inline_Dotted)
		}
	}
	key := cx.doc.nodes[d - 1]
	ls := compose.line_start(src, key.lo)
	lead := ls
	for lead < u64(len(src)) && (src[lead] == ' ' || src[lead] == '\t') {
		lead += 1
	}
	b := make([dynamic]u8, cx.a)
	compose.puts(&b, string(src[lead:key.lo + u64(key.n)]), ".", member_text(cx, e, true))
	_, end, _ := lines_of(cx, d)
	at, k := int(e.at), 0
	it := core.pairs(cx.doc, core.Node_Index(d))
	for _, v in core.pair_next(&it) {
		if k == at {
			head, _, ok := lines_of(cx, u32(v))
			if ok {
				put_line_at(cx, head, string(b[:]), false)
				return true
			}
		}
		k += 1
	}
	put_line_at(cx, end, string(b[:]), false)
	return true
}

// The header path of node `i`, which is a table or an array of tables, and whether a section written at the end of the
// text joins it: every array of tables above it must be at its last element.
@(private = "file")
header_path :: proc(cx: ^Cx, i: u32) -> (path: string, ok: bool) {
	parts := make([dynamic]string, cx.a)
	cur := i
	for cur != 0 {
		p := cx.parent[cur]
		if form_of(cx, p) == .Tables {
			if cur + cx.doc.nodes[cur].n != p + cx.doc.nodes[p].n {
				return "", false
			}
			cur = p
			continue
		}
		if form_of(cx, p) == .Inline {
			return "", false
		}
		append(&parts, key_source(cx, cur - 1))
		cur = p
	}
	b := make([dynamic]u8, cx.a)
	#reverse for part, k in parts {
		if k != len(parts) - 1 {
			compose.puts(&b, ".")
		}
		compose.puts(&b, part)
	}
	return string(b[:]), true
}

// A section for the table `t`, which only its members' headers name: a header at the end of the text.
@(private = "file")
insert_section :: proc(cx: ^Cx, e: core.Edit, t: u32, line: string) -> bool {
	path, ok := header_path(cx, t)
	if !ok {
		return refuse_edit(cx, e.node, .Misplaced)
	}
	b := make([dynamic]u8, cx.a)
	compose.puts(&b, "[", path, "]", cx.eol, line)
	put_section_at(cx, cx.foot_at, b[:])
	return true
}

// A section's text `body` placed at `pos`, set apart from the lines before it by a blank line and from the section
// after it by another.
@(private = "file")
put_section_at :: proc(cx: ^Cx, pos: u64, body: []u8) {
	src := cx.src
	b := make([dynamic]u8, cx.a)
	if pos > 0 && src[pos - 1] != '\n' {
		compose.puts(&b, cx.eol)
	}
	if pos > 0 && !blank_line(src, compose.line_start(src, pos - 1)) {
		compose.puts(&b, cx.eol)
	}
	append(&b, ..body)
	compose.puts(&b, cx.eol)
	if pos < u64(len(src)) && !blank_line(src, pos) {
		compose.puts(&b, cx.eol)
	}
	add(cx, pos, pos, b[:])
}

// The sections that spell the value `text`, read as TOML, under the header path `prefix`: a table or an array of tables as
// the member `name` of the table `prefix` names, or, for an element, the table `text` is as the next element of the array
// `prefix` names. Nothing when the value is not one of those.
@(private = "file")
value_sections :: proc(cx: ^Cx, text: []u8, prefix: string, name: []u8, element: bool) -> (body: []u8, ok: bool) {
	wrapped := make([]u8, len(text) + 5, cx.a)
	copy(wrapped, "r = ")
	copy(wrapped[4:], text)
	wrapped[len(wrapped) - 1] = '\n'
	doc, err := build_text(wrapped, bound_as(.Toml_1_0), cx.a)
	if err.kind != .None {
		return nil, false
	}
	it := core.pairs(&doc, core.ROOT)
	_, value, found := core.pair_next(&it)
	if !found {
		return nil, false
	}
	spill: [write.ROOM_MAX]u8 = ---
	l := Layout{doc = &doc, own = true, prefix = prefix}
	l.arena.backing_allocator = context.allocator
	defer runtime.arena_destroy(&l.arena)
	l.path.allocator = runtime.arena_allocator(&l.arena)
	write.init(&l.out, &spill, cx.a)
	kind := core.Typed_Error_Kind.None
	switch {
	case element:
		if core.kind(&doc, value) != .Object {
			return nil, false
		}
		kind = put_table(&l, value, true)
	case !is_section(&l, value):
		return nil, false
	case:
		append(&l.path, string(name))
		if core.kind(&doc, value) == .Object {
			kind = put_table(&l, value, false)
		} else {
			elements := core.children(&doc, value)
			for e in core.child_next(&elements) {
				if kind = put_table(&l, e, true); kind != .None {
					break
				}
			}
		}
	}
	laid, lerr := write.finish(&l.out, {kind = kind})
	if lerr.kind != .None {
		return nil, false
	}
	b := make([dynamic]u8, cx.a)
	for c in laid[:len(laid) - 1] {
		if c == '\n' {
			compose.puts(&b, cx.eol)
		} else {
			append(&b, c)
		}
	}
	return b[:], true
}

// Where a section for the table `t` goes: after the last section it owns, or at the end of the text for the root.
@(private = "file")
sections_end :: proc(cx: ^Cx, t: u32) -> u64 {
	pos := cx.foot_at if t == 0 else 0
	for i in max(t, 1) ..< t + cx.doc.nodes[t].n {
		if k := cx.sec_of[i]; k >= 0 {
			pos = max(pos, section_end(cx, int(k)))
		}
	}
	return pos
}

// A new member of the table `t` that is a table or an array of tables is sections after the last section `t` owns. False
// when it is neither, or when a section there would not join `t`.
@(private = "file")
insert_member_sections :: proc(cx: ^Cx, e: core.Edit, t: u32) -> bool {
	prefix, ok := header_path(cx, t)
	if !ok {
		return false
	}
	body, found := value_sections(cx, e.text, prefix, e.key, false)
	if !found {
		return false
	}
	put_section_at(cx, sections_end(cx, t), body)
	return true
}

// A new element of an array of tables is a `[[header]]` section after the last element's sections, with the sections of
// the tables inside it.
@(private = "file")
insert_element :: proc(cx: ^Cx, e: core.Edit, arr: u32) -> bool {
	text := bytes.trim_space(e.text)
	if len(text) == 0 || text[0] != '{' {
		return refuse_edit(cx, e.node, .Element_Not_Table)
	}
	path, ok := header_path(cx, arr)
	if !ok {
		return refuse_edit(cx, e.node, .Misplaced)
	}
	body, found := value_sections(cx, text, path, nil, true)
	if !found {
		return refuse_edit(cx, e.node, .Element_Not_Table)
	}
	last := last_value(cx, arr)
	pos := u64(0)
	for i in last ..< last + cx.doc.nodes[last].n {
		if k := cx.sec_of[i]; k >= 0 {
			pos = max(pos, section_end(cx, int(k)))
		}
	}
	put_section_at(cx, pos, body)
	return true
}

@(private = "file")
remove_edit :: proc(cx: ^Cx, e: core.Edit) -> bool {
	v := u32(e.node)
	p := cx.parent[v]
	switch form_of(cx, p) {
	case .Inline:
		return remove_inline(cx, p, v)
	case .Tables:
		remove_sections(cx, v)
	case .Root, .Header, .Dotted, .Implicit, .Scalar:
		switch form_of(cx, v) {
		case .Scalar, .Inline, .Dotted:
			remove_lines(cx, v)
		case .Header, .Implicit, .Tables:
			remove_sections(cx, v)
		case .Root:
		}
	}
	return true
}

@(private = "file")
remove_inline :: proc(cx: ^Cx, c, v: u32) -> bool {
	items := items_of(cx, c)
	idx := 0
	for it, k in items {
		if it.node == v {
			idx = k
		}
	}
	if cleared(cx, c, len(items)) {
		return true
	}
	closer := node_end(cx, c) - 1
	lo := cx.doc.nodes[c].lo
	switch {
	case len(items) == 1 && bytes.index_byte(cx.src[lo + 1:closer], '#') < 0:
		add(cx, lo + 1, closer, nil)
	case idx + 1 < len(items):
		add(cx, items[idx].start, items[idx + 1].start, nil)
	case idx > 0:
		add(cx, items[idx - 1].end, items[idx].end, nil)
	case:
		add(cx, items[idx].start, items[idx].end, nil)
	}
	return true
}

// The lines of a member of a table, with the comments directly above them.
@(private = "file")
remove_lines :: proc(cx: ^Cx, v: u32) {
	if form_of(cx, v) == .Dotted {
		it := core.pairs(cx.doc, core.Node_Index(v))
		for _, w in core.pair_next(&it) {
			remove_lines(cx, u32(w))
		}
		return
	}
	ls := compose.line_start(cx.src, cx.doc.nodes[v - 1].lo)
	add(cx, head_start(cx, ls), statement_end(cx, v), nil)
}

// Every section the table `v` or the array of tables `v` owns, each with the comments above its header. A section that
// ends the text takes the blank lines before it.
@(private = "file")
remove_sections :: proc(cx: ^Cx, v: u32) {
	first, last := u64(0), u64(0)
	count := 0
	for i in v ..< v + cx.doc.nodes[v].n {
		k := cx.sec_of[i]
		if k < 0 {
			continue
		}
		lo, hi := cx.sections[k].head, section_end(cx, int(k))
		if count == 0 {
			first = lo
		}
		count += 1
		last = hi
		add(cx, lo, hi, nil)
	}
	if count == 0 || last < cx.foot_at {
		return
	}
	// The sections end the text: the blank lines before the first go with them.
	lo := first
	for lo > 0 && blank_line(cx.src, compose.line_start(cx.src, lo - 1)) {
		lo = compose.line_start(cx.src, lo - 1)
	}
	if lo < first {
		add(cx, lo, first, nil)
	}
}

@(private = "file")
fact_edit :: proc(cx: ^Cx, e: core.Edit) -> bool {
	if core.is_property(e.role) {
		return refuse_edit(cx, e.node, .Tag_Fact)
	}
	id := u64(e.node) << 8 | u64(e.role)
	compose.claim(&cx.seen, &cx.err, id) or_return
	node := u32(e.node)
	for p := cx.parent[node]; p != NIL; p = cx.parent[p] {
		if form_of(cx, p) == .Inline {
			return refuse_edit(cx, e.node, .Inline_Comment)
		}
	}
	lines := compose.fact_lines(e, cx.a)
	for line in lines {
		if !write.comment_ok(string(line)) {
			return refuse_edit(cx, e.node, .Comment_Body)
		}
	}
	existing := compose.role_facts(cx.doc, e, cx.a)
	switch e.role {
	case .Comment_Inline:
		return inline_comment(cx, e, node, lines[:], existing[:])
	case .Comment_Foot:
		if node != 0 {
			return refuse_edit(cx, e.node, .Foot_Comment)
		}
		return block_comment(cx, e, cx.foot_at, nil, lines[:], existing[:])
	case .Comment:
		return head_comment(cx, e, node, lines[:], existing[:])
	case .Key, .Value, .Tag, .Anchor, .Alias, .Instruction, .Doctype, .Attribute, .Partial:
	}
	return refuse_edit(cx, e.node, .Tag_Fact)
}

@(private = "file")
head_comment :: proc(cx: ^Cx, e: core.Edit, node: u32, lines: [][]u8, existing: []core.Fact) -> bool {
	ls: u64
	switch form_of(cx, node) {
	case .Scalar, .Inline:
		ls = compose.line_start(cx.src, cx.doc.nodes[node - 1].lo)
	case .Dotted, .Header:
		ls = compose.line_start(cx.src, cx.doc.nodes[node].lo if form_of(cx, node) == .Header else cx.doc.nodes[node - 1].lo)
	case .Root, .Implicit, .Tables:
		return refuse_edit(cx, e.node, .No_Statement)
	}
	return block_comment(cx, e, ls, indent_of(cx.src, ls), lines, existing)
}

// Comment lines `lines` in place of the lines `existing` holds, or before line `ls` when it holds none.
@(private = "file")
block_comment :: proc(cx: ^Cx, e: core.Edit, ls: u64, indent: []u8, lines: [][]u8, existing: []core.Fact) -> bool {
	b := make([dynamic]u8, cx.a)
	if len(existing) == 0 && ls > 0 && cx.src[ls - 1] != '\n' {
		compose.puts(&b, cx.eol)
	}
	for line in lines {
		compose.puts(&b, string(indent), "#", " " if e.padded else "", string(line), cx.eol)
	}
	if len(existing) == 0 {
		if len(lines) > 0 {
			add(cx, ls, ls, b[:])
		}
		return true
	}
	for f, k in existing {
		lo, hi := compose.line_start(cx.src, f.lo), line_end(cx.src, f.lo)
		add(cx, lo, hi, b[:] if k == 0 else nil)
	}
	return true
}

@(private = "file")
inline_comment :: proc(cx: ^Cx, e: core.Edit, node: u32, lines: [][]u8, existing: []core.Fact) -> bool {
	if len(lines) > 1 || len(existing) > 1 {
		return refuse_edit(cx, e.node, .Many_Comments)
	}
	pos: u64
	switch form_of(cx, node) {
	case .Scalar, .Inline, .Dotted:
		pos = node_end(cx, node)
	case .Header:
		pos = line_end(cx.src, cx.doc.nodes[node].lo)
		for pos > 0 && (cx.src[pos - 1] == '\n' || cx.src[pos - 1] == '\r' || cx.src[pos - 1] == ' ' || cx.src[pos - 1] == '\t') {
			pos -= 1
		}
	case .Root, .Implicit, .Tables:
		return refuse_edit(cx, e.node, .No_Statement)
	}
	text := make([dynamic]u8, cx.a)
	if len(lines) == 1 {
		compose.puts(&text, "#", " " if e.padded else "", string(lines[0]))
	}
	if len(existing) == 1 {
		f := existing[0]
		if len(lines) == 0 {
			lo := f.lo
			for lo > 0 && (cx.src[lo - 1] == ' ' || cx.src[lo - 1] == '\t') {
				lo -= 1
			}
			add(cx, lo, f.lo + u64(f.n), nil)
		} else {
			add(cx, f.lo, f.lo + u64(f.n), text[:])
		}
		return true
	}
	if len(lines) == 1 {
		b := make([dynamic]u8, cx.a)
		compose.puts(&b, " ", string(text[:]))
		add(cx, pos, pos, b[:])
	}
	return true
}

// Returns the source bytes `list`'s edits make, each a splice of the source, then reads them again.
@(private)
edit_commit :: proc(list: ^core.Edit_List, spec: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	doc := list.doc
	if doc == nil || doc.partial {
		return nil, 0, {kind = .Bad_Index}
	}
	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 64 * 1024}
	defer runtime.arena_destroy(&arena)
	cx := Cx{doc = doc, src = doc.src, a = runtime.arena_allocator(&arena), foot_at = u64(len(doc.src))}
	cx.eol = "\r\n" if bytes.contains(doc.src, []u8{'\r', '\n'}) else "\n"
	cx.sections = make([dynamic]Section, cx.a)
	cx.comments = make([dynamic]u64, cx.a)
	cx.splices = make([dynamic]compose.Splice, cx.a)
	cx.seen = make(map[u64]struct{}, cx.a)
	for f in doc.facts {
		if f.role <= .Key {
			continue
		}
		append(&cx.comments, f.lo)
	}
	slice.sort(cx.comments[:])
	for f in core.all_facts(doc, 0) {
		if f.role == .Comment_Foot {
			cx.foot_at = min(cx.foot_at, compose.line_start(doc.src, f.lo))
		}
	}
	build_parents(&cx)
	build_sections(&cx)
	cx.removed = make(map[u32]int, cx.a)
	cx.refill = make(map[u32][dynamic]Refill, cx.a)
	for e in list.edits {
		if e.op == .Remove && form_of(&cx, cx.parent[e.node]) == .Inline {
			cx.removed[cx.parent[e.node]] += 1
		}
	}
	for e in list.edits {
		if !apply(&cx, e) {
			return nil, 0, cx.err
		}
	}
	refill_cleared(&cx)
	out, err = compose.apply_splices(doc.src, cx.splices[:], allocator)
	if err.kind != .None {
		return nil, 0, err
	}
	if fault, bad := validate_text(out, Spec(spec), options_of(doc.as)).?; bad {
		delete(out, allocator)
		return nil, 0, {kind = .Bad_Result, inner = fault}
	}
	return out, 0, {}
}
