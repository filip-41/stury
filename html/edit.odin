package html

// HTML's edit services. Edits are committed through `compose.markup_commit`, which holds the edits every markup format
// shares, over the elements HTML spells. A new value is written by the serialization's rules, and a scalar is escaped as
// the element it goes in reads it. An edit that writes at a node the tree construction made, which no bytes of the
// source spell where it stands, is `.Frozen`.
//
// The result is read again, and one whose tree is not the edited tree is `.Bad_Result`. A node the edits leave must
// read as it did, and the content an edit wrote must read in the full text as it reads alone in its element, as a
// fragment.

import "base:runtime"
import "core:slice"
import "core:strings"
import core "../core"
import compose "../core/compose"
import typed "../core/typed"
import write "../core/write"

@(private, rodata)
EDIT := core.Edit_Services {
	key_text = compose.markup_key_text,
	spell    = edit_spell,
	relocate = edit_relocate,
	frozen   = frozen,
	commit   = edit_commit,
}

// The byte `edit_spell` writes before a scalar's text. The content it goes in escapes it. The input stream reads U+0001
// as a parse error, so a relocated content that opens with it is refused, since it would read as a scalar.
@(private)
SCALAR :: "\x01"

// The byte `edit_spell` writes before an object's members. The commit reads them back in the element they go in, as a
// fragment whose context is that element. A relocated content that opens with it is refused.
@(private = "file")
MEMBERS :: "\x02"

// Returns an edit list over `doc`. A document an entry point reads holds no edit services, so the list takes HTML's.
edit_list_init :: proc(doc: ^core.Document, spec: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = &EDIT
	return list
}

// Makes `v` the value at every answer of `path` over `src` and returns the new text, which the caller frees with
// `allocator`. Every byte the edit does not reach is kept. A `typed.Raw` is an element's content as HTML, a struct, a
// slice or a map is built by `plan`, and any other value is written as an element's content. A `Name` the path ends in
// that its element lacks is inserted as its last child.
set :: proc(src: []u8, spec: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	return write.set_with(src, bound_as(spec, opts), build_handle, &EDIT, path, v, plan, read, allocator)
}

// Spells a value an edit writes as an element's content: null as none, a scalar as `SCALAR` and its text, an object as
// `MEMBERS` and its members written compact, and an array as `ITEM` before each item's content.
@(private)
edit_spell :: proc(_: ^core.Document, v: core.Value, opts: core.Write_Options, _: string, _: bool, _: u64, allocator: runtime.Allocator) -> ([]u8, core.Error) {
	spill: [write.ROOM_MAX]u8 = ---
	w := Writer{opts = opts}
	w.opts.pretty = false
	write.init(&w.out, &spill, allocator)
	kind := put_content(&w, v, true)
	text, err := write.finish(&w.out, {kind = kind})
	return text, core.error_of(err)
}

@(private = "file")
put_content :: proc(w: ^Writer, value: core.Value, top: bool) -> core.Typed_Error_Kind {
	v := core.plain(value)
	#partial switch core.value_kind(v) {
	case .Null:
		return .None
	case .Array:
		if !top {
			return .Unwritable
		}
		n := 0
		it := core.value_children(v)
		for item in core.value_child_next(&it) {
			write.put_byte(&w.out, compose.MARKUP_ITEM[0])
			put_content(w, item, false) or_return
			n += 1
		}
		return .None if n > 0 else .Unwritable
	case .Object:
		spill: [write.ROOM_MAX]u8 = ---
		members := Writer{opts = w.opts}
		write.init(&members.out, &spill, context.temp_allocator)
		text, err := write.finish(&members.out, {kind = put_members(&members, v, 0, false)})
		if err.kind != .None {
			return err.kind
		}
		if len(text) == 0 {
			return .Unwritable
		}
		write.put_byte(&w.out, MEMBERS[0])
		write.put_text(&w.out, string(text))
		return .None
	}
	write.put_byte(&w.out, SCALAR[0])
	write.put_text(&w.out, write.value_scalar_text(v, w.buf[:], write.MARKUP_TREE) or_return)
	return .None
}

// The content of node `node`, as `edit_spell` writes a value: an element's between its tags, a raw text's escaped, and
// the root element for the document. Content that opens with `SCALAR` or `MEMBERS` is refused.
@(private)
edit_relocate :: proc(doc: ^core.Document, node: core.Node_Index, _: core.Site, allocator: runtime.Allocator) -> ([]u8, bool) {
	context.allocator = context.temp_allocator
	if node != core.ROOT && doc.nodes[node].kind != .Object && raw_text(core.node_string(doc, node - 1)) {
		escaped, ok := escape(core.node_string(doc, node), allocator)
		return transmute([]u8)escaped, ok
	}
	lo, hi := compose.markup_content(doc, &MARKUP, node)
	if lo < hi && (doc.src[lo] == SCALAR[0] || doc.src[lo] == MEMBERS[0]) {
		return nil, false
	}
	return slice.clone(doc.src[lo:hi], allocator), true
}

@(private, rodata)
MARKUP := compose.Markup {
	element = element_of,
	is_name = proc(name: []u8) -> bool {
		if len(name) == 0 || name[0] - 'a' >= 26 {
			return false
		}
		for c in name {
			if c - 'A' < 26 || is_space(c) || c == '/' || c == '>' || c == 0 {
				return false
			}
		}
		return true
	},
	fact = edit_fact,
	content = edit_content,
	rules = rules_of,
	refusals = {
		.Reordered = u8(Detail.Reordered),
		.Not_Name = u8(Detail.Not_Name),
		.Text_Markup = u8(Detail.Text_Markup),
		.Nested_Array = u8(Detail.Nested_Array),
		.Comment_Body = u8(Detail.Comment_Body),
		.Attribute_Body = u8(Detail.Attribute_Body),
		.No_Place = u8(Detail.No_Place),
		.Void = u8(Detail.Void),
	},
}

// Whether HTML element `name` reads its text as written, or with references only, so that it holds no element.
@(private = "file")
raw_text :: proc(name: string) -> bool {
	return is_raw(name) || name == "title" || name == "textarea"
}

// Escapes `text` as the serialization escapes a text, into a buffer from `allocator`.
@(private = "file")
escape :: proc(text: string, allocator: runtime.Allocator) -> (string, bool) {
	spill: [write.ROOM_MAX]u8 = ---
	w := Writer{}
	write.init(&w.out, &spill, allocator)
	out, err := write.finish(&w.out, {kind = put_escaped(&w, text, false)})
	return string(out), err.kind == .None
}

// The content `text` is written as in element `name`: a scalar's text escaped, or as it stands in a raw text element.
// Markup stands as it is, and a void element or an element that holds only text refuses it.
@(private = "file")
edit_content :: proc(name, text: string, allocator: runtime.Allocator) -> (out: string, void: bool, refusal: Maybe(compose.Markup_Refusal)) {
	scalar := strings.has_prefix(text, SCALAR)
	body := text[1:] if scalar || strings.has_prefix(text, MEMBERS) else text
	switch {
	case is_void(name):
		if len(body) > 0 {
			return "", true, .Void
		}
		return "", true, nil
	case scalar && is_raw(name):
		out = body
	case !scalar && raw_text(name) && strings.contains_any(body, "<&" if is_raw(name) else "<"):
		return "", false, .Text_Markup
	case scalar:
		escaped, ok := escape(body, allocator)
		if !ok {
			return "", false, .Text_Markup
		}
		out = escaped
	case:
		out = body
	}
	// A read drops the line end that opens the text of `pre`, `listing` and `textarea`.
	if scalar && keeps_space(name) && strings.has_prefix(body, "\n") {
		out = strings.concatenate({"\n", out}, allocator)
	}
	return out, false, nil
}

// Whether `body` is a comment that HTML reads back as written, or with `.Attribute` a single attribute. HTML folds
// capitals in an attribute's name.
@(private = "file")
edit_fact :: proc(role: core.Role, body: string) -> bool {
	if role != .Attribute {
		return holds_comment(body)
	}
	Tag_Read :: struct {
		tags, attrs, errors: int,
		hi:                  u64,
	}
	on :: proc "contextless" (r: ^Tag_Read, t: ^Html_Token) -> Token_Action {
		#partial switch t.kind {
		case .Error:
			r.errors += 1
		case .Start_Tag:
			r.tags, r.attrs, r.hi = r.tags + 1, len(t.attrs), t.hi
		case:
			r.tags += 1
		}
		return .Next
	}
	tag := strings.concatenate({"<x ", body, ">"}, context.temp_allocator)
	r: Tag_Read
	_, fault, _ := tokenize(transmute([]u8)tag, &r, on, allocator = context.temp_allocator)
	return fault == nil && r.errors == 0 && r.tags == 1 && r.attrs == 1 && r.hi == u64(len(tag))
}

@(private = "file")
tag_end :: proc(src: []u8, lo: u64) -> u64 {
	on :: proc "contextless" (hi: ^u64, t: ^Html_Token) -> Token_Action {
		if t.kind != .Start_Tag && t.kind != .End_Tag {
			return .Next
		}
		hi^ = t.hi
		return .Stop
	}
	hi := u64(len(src))
	tokenize(src, &hi, on, from = lo, allocator = context.temp_allocator)
	return hi
}

@(private = "file")
end_tag_at :: proc(src: []u8, at: u64, name: string) -> bool {
	lo := at + 2
	hi := lo + u64(len(name))
	if hi >= u64(len(src)) || src[at] != '<' || src[at + 1] != '/' || !fold_name_equal(src[lo:hi], name) {
		return false
	}
	return is_space(src[hi]) || src[hi] == '/' || src[hi] == '>'
}

// The element of value `v`, the root element for the document, or the whole text for a fragment. An implied element has
// no tags. Its start tag ends where the tokenizer ends it. An element with child elements has an end tag when the last
// tag in it closes its name past its last child. One without child elements has one when the tag after its text and
// comments does.
@(private = "file")
element_of :: proc(doc: ^core.Document, v: core.Node_Index) -> (e: compose.Markup_Element) {
	src := doc.src
	if v == core.ROOT {
		if Spec(doc.as.spec) == .Fragment {
			e.close, e.hi = u64(len(src)), u64(len(src))
			return e
		}
		return element_of(doc, core.ROOT + 2)
	}
	k, n := doc.nodes[v - 1], doc.nodes[v]
	name := core.node_string(doc, v - 1)
	if k.n == 0 {
		e.lo, e.name, e.open = k.lo, k.lo, k.lo
	} else {
		e.lo, e.name = k.lo - 1, k.lo + u64(k.n)
		e.open = tag_end(src, e.lo)
	}
	if n.kind == .Object {
		e.hi = close_end(doc, v)
		e.close = e.hi
		last := core.NO_NODE
		it := core.pairs(doc, v)
		for _, m in core.pair_next(&it) {
			last = m
		}
		after := e.open
		switch {
		case last == core.NO_NODE:
		case doc.nodes[last].kind == .Object:
			after = close_end(doc, last)
		case core.key_equals(doc, last - 1, core.MARKUP_TEXT):
			after = doc.nodes[last].lo + u64(doc.nodes[last].n)
		case:
			after = element_of(doc, last).hi
		}
		for lt := e.hi; lt > after; lt -= 1 {
			if src[lt - 1] == '<' {
				if end_tag_at(src, lt - 1, name) && tag_end(src, lt - 1) == e.hi {
					e.close, e.end_tag = lt - 1, true
				}
				break
			}
		}
		return e
	}
	c := max(e.open, n.lo + u64(n.n))
	for f in core.all_facts(doc, v) {
		if (f.role == .Comment || f.role == .Instruction) && f.lo >= e.open {
			c = max(c, f.lo + u64(f.n))
		}
	}
	e.close, e.hi = c, c
	if end_tag_at(src, c, name) {
		e.hi, e.end_tag = tag_end(src, c), true
	} else if k.n > 0 && Namespace(k.spelling >> KEY_NS_SHIFT & 3) != .Html && c == e.open && src[e.open - 2] == '/' {
		e.open, e.close, e.empty = e.open - 2, e.open - 2, true
	}
	return e
}

@(private)
edit_commit :: proc(list: ^core.Edit_List, spec: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	for e in list.edits {
		if at := written_at(list.doc, e); constructed(list.doc, at) {
			return nil, 0, {kind = .Frozen, at = u64(e.node), inner = {rules = &RULES, detail = u8(Detail.Constructed)}}
		}
	}
	out, err = compose.markup_commit(list, &MARKUP, allocator)
	if err.kind != .None {
		return nil, 0, err
	}
	if err = reread(list, out); err.kind != .None {
		delete(out, allocator)
		return nil, 0, err
	}
	return out, 0, {}
}

// The member value whose bytes edit `e` writes at. For an insert it is the member the insert goes before, or the last
// one it goes after. For a renamed key it is the key's value, and for any other edit the node the edit names.
@(private = "file")
written_at :: proc(doc: ^core.Document, e: core.Edit) -> core.Node_Index {
	switch {
	case e.op == .Insert:
		at := core.NO_NODE
		i := 0
		it := core.pairs(doc, e.node)
		for _, v in core.pair_next(&it) {
			if i <= int(e.at) {
				at = v
			}
			i += 1
		}
		return at
	case e.op == .Set && e.role == .Key:
		return e.node + 1
	}
	return e.node
}

// Whether the tree construction implied, moved or copied member value `v`, or moved its text. No bytes of the source
// then spell it where it stands.
@(private = "file")
constructed :: proc(doc: ^core.Document, v: core.Node_Index) -> bool {
	if v == core.ROOT || v == core.NO_NODE {
		return false
	}
	k, n := doc.nodes[v - 1], doc.nodes[v]
	return k.spelling & KEY_FROZEN != 0 || n.kind == .Plain && n.spelling & TEXT_FROZEN != 0
}

// What the commit's read of its output compares: the nodes whose content an edit wrote, the nodes whose name or
// attributes an edit wrote, and where the first difference stands in the output.
@(private = "file")
Reread :: struct {
	doc:       ^core.Document,
	written:   [dynamic]Written,
	respelled: [dynamic]core.Node_Index,
	at:        Maybe(u64),
}

// An element whose content an edit wrote. When `counted`, its edits are inserts, removals and items of an array, and
// they change its child elements by `delta`.
@(private = "file")
Written :: struct {
	node:    core.Node_Index,
	delta:   int,
	counted: bool,
}

// Reads `out` as the document's spec and compares its tree with the tree the edits of `list` make.
@(private = "file")
reread :: proc(list: ^core.Edit_List, out: []u8) -> core.Document_Error {
	doc := list.doc
	arena := runtime.Arena{backing_allocator = runtime.default_allocator()}
	defer runtime.arena_destroy(&arena)
	context.allocator = runtime.arena_allocator(&arena)
	r := Reread{doc = doc}
	parents := core.parents_of(list)
	if parents == nil {
		return {kind = .No_Memory}
	}
	edits: for e in list.edits {
		if kind := members_read_back(list, e); kind != .None {
			return {kind = .No_Memory} if kind == .No_Memory else {kind = .Bad_Value, reason = .No_Spelling}
		}
		w := Written{node = e.node, counted = true}
		array := len(e.text) > 0 && e.text[0] == compose.MARKUP_ITEM[0]
		items := strings.count(string(e.text), compose.MARKUP_ITEM) if array else 1
		run := e.node != core.ROOT && core.key_equals(doc, e.node - 1, core.MARKUP_TEXT)
		#partial switch e.op {
		case .Set:
			switch {
			case e.role == .Key:
				append(&r.respelled, e.node + 1)
				continue edits
			case run:
				w.node = parent_of(parents, e.node)
			case array:
				w.node, w.delta = parent_of(parents, e.node), items - 1
			case:
				w.counted = false
			}
		case .Insert:
			w.delta = 0 if string(e.key) == core.MARKUP_TEXT else items
		case .Remove:
			w.node, w.delta = parent_of(parents, e.node), 0 if run else -1
		case .Set_Fact, .Remove_Fact:
			if e.role == .Attribute {
				append(&r.respelled, e.node)
			}
			continue
		}
		for &v in r.written {
			if v.node == w.node {
				v.delta, v.counted = v.delta + w.delta, v.counted && w.counted
				continue edits
			}
		}
		append(&r.written, w)
	}
	built, berr := build_handle(out, doc.as, false, context.allocator)
	if berr.kind != .None {
		if berr.kind == .No_Memory {
			return berr
		}
		return {kind = .Bad_Result, inner = berr.inner}
	}
	if same(&r, doc, core.ROOT, &built, core.ROOT) {
		return {}
	}
	return {kind = .Bad_Result, inner = core.Fault{at = r.at.? or_else 0, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Reread)}}
}

// Whether each object that edit `e` wrote, as `edit_spell` spells it, reads back as written in the element it goes in:
// as a fragment whose context is that element, and for the document's `ROOT` as a document.
@(private = "file")
members_read_back :: proc(list: ^core.Edit_List, e: core.Edit) -> core.Typed_Error_Kind {
	doc := list.doc
	name, key := "", core.NO_NODE
	switch {
	case e.op == .Insert:
		name = string(e.key)
		key = e.node - 1 if e.node != core.ROOT else core.NO_NODE
	case e.op == .Set && e.role == .Value && e.node != core.ROOT:
		key = e.node - 1
		name = core.node_string(doc, key)
	case e.op != .Set || e.role != .Value:
		return .None
	}
	as := doc.as
	if name != "" {
		read := options_of(doc.as)
		opts := Options{max_depth = read.max_depth, infer = read.infer, scripting = read.scripting, context_name = name}
		if key != core.NO_NODE {
			opts.context_namespace = Namespace(doc.nodes[key].spelling >> KEY_NS_SHIFT & 3)
		}
		as = as_of(&READERS, .Fragment, opts)
	}
	compact := list.write
	compact.pretty = false
	items := string(e.text)
	if strings.has_prefix(items, compose.MARKUP_ITEM) {
		items = items[1:]
	}
	for item in strings.split_iterator(&items, compose.MARKUP_ITEM) {
		if strings.has_prefix(item, MEMBERS) {
			read_back(transmute([]u8)item[1:], name == "" && Spec(as.spec) == .Document, as, compact) or_return
		}
	}
	return .None
}

// The element that holds `v`, and `ROOT` for `ROOT`. An HTML document holds no arrays, so it is `v`'s container.
@(private = "file")
parent_of :: proc(parents: []core.Node_Index, v: core.Node_Index) -> core.Node_Index {
	return parents[v] if v != core.ROOT else core.ROOT
}

// Whether node `b` of `y` holds the tree that node `a` of `x` holds: its kind, its attributes and its text or members.
// Under `r`, a node whose content an edit wrote holds the tree that content reads as alone. A node whose name or
// attributes an edit wrote keeps its members only.
@(private = "file")
same :: proc(r: ^Reread, x: ^core.Document, a: core.Node_Index, y: ^core.Document, b: core.Node_Index) -> (ok: bool) {
	defer if !ok && r != nil && r.at == nil {
		r.at = y.nodes[b].lo
	}
	if r != nil {
		for w in r.written {
			if w.node == a {
				return same_content(r.doc, y, b) && (!w.counted || elements(y, b) == elements(x, a) + w.delta)
			}
		}
	}
	na, nb := x.nodes[a], y.nodes[b]
	if na.kind != nb.kind || !(r != nil && slice.contains(r.respelled[:], a)) && !same_attributes(x, a, y, b) {
		return false
	}
	if na.kind != .Object {
		return core.node_string(x, a) == core.node_string(y, b)
	}
	return same_members(r, x, a, y, b)
}

@(private = "file")
same_members :: proc(r: ^Reread, x: ^core.Document, a: core.Node_Index, y: ^core.Document, b: core.Node_Index) -> bool {
	ia, ib := core.pairs(x, a), core.pairs(y, b)
	for {
		ka, va, more := core.pair_next(&ia)
		kb, vb, also := core.pair_next(&ib)
		if more != also || !more {
			return more == also
		}
		respelled := r != nil && slice.contains(r.respelled[:], va)
		if !respelled && !same_key(x, ka, y, kb) || !same(r, x, va, y, vb) {
			return false
		}
	}
}

@(private = "file")
elements :: proc(doc: ^core.Document, v: core.Node_Index) -> (n: int) {
	if doc.nodes[v].kind != .Object {
		return 0
	}
	it := core.pairs(doc, v)
	for k in core.pair_next(&it) {
		n += 0 if core.key_equals(doc, k, core.MARKUP_TEXT) else 1
	}
	return n
}

// Whether keys `ka` of `x` and `kb` of `y` name one element: the same name in the same namespace, both written or both
// implied.
@(private = "file")
same_key :: proc(x: ^core.Document, ka: core.Node_Index, y: ^core.Document, kb: core.Node_Index) -> bool {
	sa, sb := x.nodes[ka], y.nodes[kb]
	return (sa.n == 0) == (sb.n == 0) && sa.spelling >> KEY_NS_SHIFT & 3 == sb.spelling >> KEY_NS_SHIFT & 3 && core.node_string(x, ka) == core.node_string(y, kb)
}

@(private = "file")
same_attributes :: proc(x: ^core.Document, a: core.Node_Index, y: ^core.Document, b: core.Node_Index) -> bool {
	fa, fb := core.all_facts(x, a), core.all_facts(y, b)
	i, j := 0, 0
	for {
		for i < len(fa) && fa[i].role != .Attribute {
			i += 1
		}
		for j < len(fb) && fb[j].role != .Attribute {
			j += 1
		}
		if i == len(fa) || j == len(fb) {
			return i == len(fa) && j == len(fb)
		}
		if string(x.src[fa[i].lo:][:fa[i].n]) != string(y.src[fb[j].lo:][:fb[j].n]) {
			return false
		}
		i, j = i + 1, j + 1
	}
}

// Whether the element of value `b` of `y` holds the tree its content reads as in a fragment whose context is the
// element, read as `doc` was read. For the document it is the tree the root element reads as alone.
@(private = "file")
same_content :: proc(doc: ^core.Document, y: ^core.Document, b: core.Node_Index) -> bool {
	e := element_of(y, b)
	if b == core.ROOT {
		alone, err := build_handle(y.src[e.lo:e.hi], doc.as, false, context.allocator)
		return err.kind == .None && same_members(nil, y, b, &alone, core.ROOT)
	}
	name := core.node_string(y, b - 1)
	ns := Namespace(y.nodes[b - 1].spelling >> KEY_NS_SHIFT & 3)
	content := y.src[e.open:e.close]
	// The line end a read drops after the start tag of `pre`, `listing` and `textarea` is no text of the element.
	if ns == .Html && keeps_space(name) {
		if strings.has_prefix(string(content), "\r\n") {
			content = content[2:]
		} else if len(content) > 0 && (content[0] == '\n' || content[0] == '\r') {
			content = content[1:]
		}
	}
	read := options_of(doc.as)
	opts := Options{max_depth = read.max_depth, infer = read.infer, scripting = read.scripting, context_name = name, context_namespace = ns}
	frag, err := build_spec(content, .Fragment, as_of(&READERS, .Fragment, opts), false, context.allocator)
	if err.kind != .None {
		return false
	}
	if y.nodes[b].kind == .Object {
		return same_members(nil, y, b, &frag, core.ROOT)
	}
	text := ""
	it := core.pairs(&frag, core.ROOT)
	for k, v in core.pair_next(&it) {
		if !core.key_equals(&frag, k, core.MARKUP_TEXT) {
			return false
		}
		text = core.node_string(&frag, v)
	}
	got := core.node_string(y, b)
	return text == got || text == "" && strings.trim(got, " \t\n\r\f") == ""
}
