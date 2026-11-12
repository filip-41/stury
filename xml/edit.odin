package xml

// XML's edit services. An element is no value between separators: its name stands in its start and end tags, its
// attributes in its start tag, and the items of a repeated name are elements apart. So the format commits its edits
// itself, through `compose.apply_splices`. A set writes an element's content between its tags, keeping its attributes,
// a set of the document its root element, and a set of `#text` the text run. An array set on a name writes item k as
// the content of the name's k-th element, takes the elements past the items, and adds the items past the elements as
// elements after the name's last. An insert is an element after the member before it, laid out by the white space a
// reader drops before that member, a removal takes an element with that white space, and a rename respells both tags. A
// fact edit replaces a node's comments or attributes where they stand, or writes them at the head of the element's
// content, after the element, or before its end tag. Every byte no splice touches stays, and the result is read again,
// so an edit that breaks a rule of XML is `.Bad_Result`.

import "base:runtime"
import "core:slice"
import "core:strings"
import core "../core"
import compose "../core/compose"
import engine "../core/build"
import typed "../core/typed"
import write "../core/write"

// XML's edit services, the same table for every spec.
@(private, rodata)
EDIT := core.Edit_Services {
	value    = edit_value,
	key_text = edit_key_text,
	validate = proc "contextless" (src: []u8, as: core.As) -> Maybe(core.Fault) {return validate_spec(src, .Xml, options_of(as))},
	spell    = edit_spell,
	relocate = edit_relocate,
	frozen   = frozen,
	commit   = edit_commit,
}

// Returns an edit list over `doc`. A document read as a constant spec holds no edit services, so the list takes XML's.
edit_list_init :: proc {edit_list_init_bound, edit_list_init_chosen}

@(private)
edit_list_init_bound :: proc(doc: ^core.Document, $S: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = &EDIT
	return list
}

@(private)
edit_list_init_chosen :: proc(doc: ^core.Document, spec: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = core.services_of(as(spec)).edit
	return list
}

// Makes `v` the value at every answer of `path` over `src`, in one call, and returns the new text, which the caller frees
// with `allocator`, keeping every byte the edit does not reach. A `typed.Raw` is an element's content as XML, a struct, a
// slice or a map is built by `plan`, and any other value is written as an element's content. A `Name` the path ends in
// that its element lacks is inserted as its last child.
set :: proc {set_bound, set_chosen}

@(private)
set_bound :: proc(src: []u8, $S: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	scratch: write.Scratch
	defer write.scratch_destroy(&scratch)
	in_ := write.edit_input(v, plan, &scratch) or_return
	doc, berr := build_bound(src, S, opts, read.dups, allocator)
	defer core.destroy(&doc)
	if berr != nil {
		return nil, berr
	}
	list := edit_list_init_bound(&doc, S, allocator)
	defer core.edit_list_destroy(&list)
	return engine.set_answers(&list, path, in_, read, allocator)
}

@(private)
set_chosen :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	scratch: write.Scratch
	defer write.scratch_destroy(&scratch)
	in_ := write.edit_input(v, plan, &scratch) or_return
	return engine.set(src, as(spec, opts), path, in_, read, allocator)
}

// The byte before each item of an array a value spells, which no XML text holds.
@(private = "file")
ITEM :: "\x00"

// Checks `src` as an element's content.
@(private)
edit_value :: proc(v: ^core.Token_View, src: []u8, allocator: runtime.Allocator) -> core.Document_Error {
	wrapped := strings.concatenate({"<r>", string(src), "</r>"}, allocator)
	defer delete(wrapped, allocator)
	if fault, bad := validate_spec(transmute([]u8)wrapped, .Xml, options_of(v.as)).?; bad {
		fault.at -= min(fault.at, 3)
		return {kind = .Bad_Value, inner = fault}
	}
	return {}
}

// Writes the decoded name `name`, which a commit judges as the name of a new element.
@(private)
edit_key_text :: proc(_: ^core.Document, name: []u8, text: ^[dynamic]u8) -> bool {
	_, failed := append(text, ..name)
	return failed == nil
}

// A value an edit writes, spelled as an element's content by the element write: null as none, a scalar as its escaped
// text, an object as its members' elements and its `#text` as text among them, and an array as `ITEM` before each
// item's content.
@(private)
edit_spell :: proc(_: ^core.Document, v: core.Value, opts: core.Write_Options, _: string, _: bool, _: u64, allocator: runtime.Allocator) -> ([]u8, core.Error) {
	spill: [write.ROOM_MAX]u8 = ---
	w := Writer{opts = opts}
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
			write.put_byte(&w.out, ITEM[0])
			put_content(w, item, false) or_return
			n += 1
		}
		return .None if n > 0 else .Unwritable
	case .Object:
		// The element whose content this is stands open around the members.
		e: Elements
		elements_init(&e, &w.out, w.opts)
		defer delete(e.names)
		e.levels[0], e.levels[1], e.top = {kind = .Root}, {kind = .Object}, 2
		put_members(w, &e, v) or_return
		return .None if e.levels[1].count > 0 else .Unwritable
	}
	return put_text(&w.out, value_text(w, v) or_return, false, w.opts.ascii)
}

// The content node `node` holds, as `edit_spell` writes a value: an element's between its tags, and the root element
// for the document.
@(private)
edit_relocate :: proc(doc: ^core.Document, node: core.Node_Index, _: core.Site, allocator: runtime.Allocator) -> ([]u8, bool) {
	cx := Cx{doc = doc, src = doc.src}
	lo, hi := content_of(&cx, node)
	return slice.clone(doc.src[lo:hi], allocator), true
}

@(private = "file")
Cx :: struct {
	doc:     ^core.Document,
	src:     []u8,
	a:       runtime.Allocator,
	splices: [dynamic]compose.Splice,
	seen:    map[u64]struct{},
	err:     core.Document_Error,
}

// Where an element stands: `lo` at its `<`, `name` one past its name, `open` one past its start tag or at the `/` of an
// empty-element tag, `close` at its end tag or at `open` again, and `hi` one past its last `>`.
@(private = "file")
Element :: struct {
	lo, name, open, close, hi: u64,
	empty:                     bool,
}

// The element of value `v`, or the root element for the document. A tag holds no `<`, not even in an attribute's value,
// so the start of a scalar's element is the last `<` before its content.
@(private = "file")
element_of :: proc(cx: ^Cx, v: core.Node_Index) -> (e: Element) {
	if v == core.ROOT {
		return element_of(cx, core.ROOT + 2)
	}
	src := cx.src
	n := cx.doc.nodes[v]
	if n.kind == .Object {
		e.lo, e.hi = n.lo, close_end(cx.doc, v)
		quote: u8
		for e.open = e.lo + 1; quote != 0 || src[e.open] != '>'; e.open += 1 {
			if quote == 0 && (src[e.open] == '"' || src[e.open] == '\'') {
				quote = src[e.open]
			} else if src[e.open] == quote {
				quote = 0
			}
		}
		e.open += 1
		for e.close = e.hi - 1; src[e.close] != '<'; e.close -= 1 {}
	} else {
		for e.lo = n.lo - 1; src[e.lo] != '<'; e.lo -= 1 {}
		e.empty = n.n == 0 && src[n.lo] == '/'
		e.open, e.close = n.lo, n.lo + u64(n.n)
		e.hi = n.lo + 2 if e.empty else end_tag_end(src, e.close)
	}
	for e.name = e.lo + 1; !is_ws(src[e.name]) && src[e.name] != '>' && src[e.name] != '/'; e.name += 1 {}
	return e
}

// The content of node `v` as written.
@(private = "file")
content_of :: proc(cx: ^Cx, v: core.Node_Index) -> (lo, hi: u64) {
	if v == core.ROOT {
		e := element_of(cx, v)
		return e.lo, e.hi
	}
	if n := cx.doc.nodes[v]; n.kind != .Object {
		return n.lo, n.lo + u64(n.n)
	}
	e := element_of(cx, v)
	return e.open, e.close
}

// Whether value `v` is a text run, the value of a member `#text`, whose key is the node before it.
@(private = "file")
is_run :: proc(cx: ^Cx, v: core.Node_Index) -> bool {
	return v != core.ROOT && cx.doc.nodes[v - 1].spelling & core.SPELLING_SYNTHETIC == core.SPELLING_SYNTHETIC
}

// The bytes member value `v` stands on: a text run's own, or its element's after the white space a reader drops before
// it, which stands between the element and the markup before it.
@(private = "file")
extent :: proc(cx: ^Cx, v: core.Node_Index) -> (lead, lo, hi: u64) {
	if is_run(cx, v) {
		n := cx.doc.nodes[v]
		return n.lo, n.lo, n.lo + u64(n.n)
	}
	e := element_of(cx, v)
	lead = e.lo
	for lead > 0 && is_ws(cx.src[lead - 1]) {
		lead -= 1
	}
	if lead == 0 || cx.src[lead - 1] != '>' {
		lead = e.lo
	}
	return lead, e.lo, e.hi
}

@(private = "file")
puts :: proc(b: ^[dynamic]u8, parts: ..string) {
	for s in parts {
		append(b, s)
	}
}

@(private = "file")
add :: proc(cx: ^Cx, lo, hi: u64, text: string) {
	append(&cx.splices, compose.Splice{lo = lo, hi = hi, text = transmute([]u8)text, seq = len(cx.splices)})
}

@(private = "file")
refuse_edit :: proc(cx: ^Cx, node: core.Node_Index, detail: Detail) -> bool {
	cx.err = {kind = .Frozen, at = u64(node), inner = {rules = &RULES, detail = u8(detail)}}
	return false
}

// Whether `text` is a text run's: no array, and no markup but comments, instructions and CDATA sections.
@(private = "file")
holds_text :: proc(text: string) -> bool {
	for c, i in transmute([]u8)text {
		if c == ITEM[0] || c == '<' && i + 1 < len(text) && text[i + 1] != '!' && text[i + 1] != '?' {
			return false
		}
	}
	return true
}

// The items of the array `text` spells, or `text` alone.
@(private = "file")
items_of :: proc(cx: ^Cx, text: string) -> []string {
	if len(text) == 0 || text[0] != ITEM[0] {
		return slice.clone([]string{text}, cx.a)
	}
	return strings.split(text[1:], ITEM, cx.a)
}

// The elements of name `name` that hold `items`, set apart by `sep`.
@(private = "file")
elements :: proc(cx: ^Cx, name: string, items: []string, sep: string) -> string {
	b := make([dynamic]u8, cx.a)
	for item, i in items {
		if i > 0 {
			append(&b, sep)
		}
		if len(item) == 0 {
			puts(&b, "<", name, "/>")
		} else {
			puts(&b, "<", name, ">", item, "</", name, ">")
		}
	}
	return string(b[:])
}

// Takes member value `v` from the text.
@(private = "file")
drop :: proc(cx: ^Cx, v: core.Node_Index) {
	lead, _, hi := extent(cx, v)
	add(cx, lead, hi, "")
}

@(private = "file")
apply :: proc(cx: ^Cx, e: core.Edit) -> bool {
	switch e.op {
	case .Set:
		if e.role == .Key {
			return rename(cx, e)
		}
		return set_value(cx, e.node, string(e.text))
	case .Insert:
		return insert_edit(cx, e)
	case .Remove:
		drop(cx, e.node)
	case .Reorder:
		return refuse_edit(cx, e.node, .Reordered)
	case .Set_Fact, .Remove_Fact:
		return fact_edit(cx, e)
	}
	return true
}

@(private = "file")
set_value :: proc(cx: ^Cx, v: core.Node_Index, text: string) -> bool {
	n := cx.doc.nodes[v]
	array := len(text) > 0 && text[0] == ITEM[0]
	switch {
	case v == core.ROOT:
		if array {
			return refuse_edit(cx, v, .Nested_Array)
		}
		e := element_of(cx, v)
		add(cx, e.lo, e.hi, text)
	case array:
		return set_items(cx, {v}, items_of(cx, text))
	case is_run(cx, v):
		if !holds_text(text) {
			return refuse_edit(cx, v, .Text_Markup)
		}
		add(cx, n.lo, n.lo + u64(n.n), text)
	case:
		e := element_of(cx, v)
		if !e.empty {
			add(cx, e.open, e.close, text)
		} else if len(text) > 0 {
			name := string(cx.src[e.lo + 1:e.name])
			add(cx, e.open, e.hi, strings.concatenate({">", text, "</", name, ">"}, cx.a))
		}
	}
	return true
}

// Writes item `k` as the content of `elems[k]`, takes the elements past the items, and writes the items past the
// elements as new elements of the name after the last.
@(private = "file")
set_items :: proc(cx: ^Cx, elems: []core.Node_Index, items: []string) -> bool {
	for v, k in elems {
		if k >= len(items) {
			drop(cx, v)
		} else if !set_value(cx, v, items[k]) {
			return false
		}
	}
	last := elems[len(elems) - 1]
	if len(items) <= len(elems) {
		return true
	}
	if is_run(cx, last) {
		return refuse_edit(cx, last, .Text_Markup)
	}
	lead, lo, hi := extent(cx, last)
	e := element_of(cx, last)
	sep := string(cx.src[lead:lo])
	add(cx, hi, hi, strings.concatenate({sep, elements(cx, string(cx.src[e.lo + 1:e.name]), items[len(elems):], sep)}, cx.a))
	return true
}

// Respells the name in both tags of the element of key `e.node`.
@(private = "file")
rename :: proc(cx: ^Cx, e: core.Edit) -> bool {
	k := e.node
	if cx.doc.nodes[k].spelling & core.SPELLING_SYNTHETIC == core.SPELLING_SYNTHETIC || !is_name(e.text) {
		return refuse_edit(cx, k, .Not_Name)
	}
	el := element_of(cx, k + 1)
	add(cx, el.lo + 1, el.name, string(e.text))
	if !el.empty {
		add(cx, el.close + 2, el.close + 1 + el.name - el.lo, string(e.text))
	}
	return true
}

// Writes a new member of the element `e.node` before the member at `e.at`, or after the last.
@(private = "file")
insert_edit :: proc(cx: ^Cx, e: core.Edit) -> bool {
	c := e.node
	text := string(e.text)
	name := string(e.key)
	run := name == TEXT_KEY
	if !run && !is_name(e.key) {
		return refuse_edit(cx, c, .Not_Name)
	}
	if run && !holds_text(text) {
		return refuse_edit(cx, c, .Text_Markup)
	}
	at := core.NO_NODE
	last := core.NO_NODE
	i := 0
	it := core.pairs(cx.doc, c)
	for _, v in core.pair_next(&it) {
		if i == int(e.at) {
			at = v
		}
		last, i = v, i + 1
	}
	if at != core.NO_NODE {
		// Before the white space of the member, which a removal of the member takes too.
		lead, lo, _ := extent(cx, at)
		sep := string(cx.src[lead:lo])
		add(cx, lead, lead, strings.concatenate({sep, text if run else elements(cx, name, items_of(cx, text), sep)}, cx.a))
		return true
	}
	lead, lo, hi := extent(cx, last)
	for f in core.all_facts(cx.doc, last) {
		if f.role == .Comment_Inline {
			hi = max(hi, f.lo + u64(f.n))
		}
	}
	sep := string(cx.src[lead:lo])
	add(cx, hi, hi, strings.concatenate({sep, text if run else elements(cx, name, items_of(cx, text), sep)}, cx.a))
	return true
}

// Replaces the comments or the attributes of `e.node` of `e.role`: the first where it stands, the others with the white
// space before them. New ones go at the head of an element's content, before the root element, after an element, before
// an end tag or the text's end, or after an element's name.
@(private = "file")
fact_edit :: proc(cx: ^Cx, e: core.Edit) -> bool {
	v := e.node
	id := u64(v) << 8 | u64(e.role)
	if id in cx.seen {
		cx.err = {kind = .Conflicting_Edits}
		return false
	}
	cx.seen[id] = {}
	if is_run(cx, v) {
		return refuse_edit(cx, v, .No_Place)
	}
	el := element_of(cx, v)
	b := make([dynamic]u8, cx.a)
	count := 0 if e.op == .Remove_Fact else compose.fact_count(e)
	for k in 0 ..< count {
		body := string(compose.fact_body(e, k))
		if e.role == .Attribute {
			puts(&b, " ", body)
			continue
		}
		if strings.contains(body, "--") || strings.has_suffix(body, "-") {
			return refuse_edit(cx, v, .Comment_Body)
		}
		puts(&b, "<!--", body, "-->")
	}
	first := true
	for f in core.all_facts(cx.doc, v) {
		if f.role != e.role || f.role == .Attribute && f.lo < el.lo {
			continue
		}
		lo := f.lo
		for lo > 0 && is_ws(cx.src[lo - 1]) && (f.role == .Attribute || !first) {
			lo -= 1
		}
		add(cx, lo, f.lo + u64(f.n), string(b[:]) if first else "")
		first = false
	}
	if !first || len(b) == 0 {
		return true
	}
	at: u64
	switch {
	case e.role == .Attribute && v != core.ROOT:
		at = el.name
	case e.role == .Comment_Inline && v != core.ROOT:
		at = el.hi
	case e.role == .Comment && v == core.ROOT:
		at = el.lo
	case e.role == .Comment && !el.empty:
		at = el.open
	case e.role == .Comment_Foot && v == core.ROOT:
		at = u64(len(cx.src))
	case e.role == .Comment_Foot && cx.doc.nodes[v].kind == .Object:
		at = el.close
	case:
		return refuse_edit(cx, v, .No_Place)
	}
	add(cx, at, at, string(b[:]))
	return true
}

// XML's commit: each edit as splices of the source, which the walk then reads.
@(private)
edit_commit :: proc(list: ^core.Edit_List, spec: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	doc := list.doc
	if doc == nil || doc.partial {
		return nil, 0, {kind = .Bad_Index}
	}
	arena := runtime.Arena{backing_allocator = allocator}
	defer runtime.arena_destroy(&arena)
	cx := Cx{doc = doc, src = doc.src, a = runtime.arena_allocator(&arena)}
	cx.splices = make([dynamic]compose.Splice, cx.a)
	cx.seen = make(map[u64]struct{}, cx.a)
	for e in list.edits {
		if !apply(&cx, e) {
			return nil, 0, cx.err
		}
	}
	out, err = compose.apply_splices(doc.src, cx.splices[:], allocator)
	if err.kind != .None {
		return nil, 0, err
	}
	if fault, bad := validate_spec(out, .Xml, options_of(doc.as)).?; bad {
		delete(out, allocator)
		return nil, 0, {kind = .Bad_Result, inner = fault}
	}
	return out, 0, {}
}
