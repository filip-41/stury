package compose

import "base:runtime"
import "core:slice"
import "core:strings"
import "../kernel"
import core ".."

// The edits of a markup format, which commits them itself: an element is no value between separators, since its name
// stands in its start and end tags, its attributes in its start tag, and the items of a repeated name are elements
// apart. A set writes an element's content between its tags, keeping its attributes, a set of the document its root
// element, and a set of `#text` the text run. An array set on a name writes item k as the content of the name's k-th
// element, takes the elements past the items, and adds the items past the elements as elements after the name's last.
// An insert is an element after the member before it, laid out by the white space a reader drops before that member, a
// removal takes an element with that white space, and a rename respells both tags. A fact edit replaces a node's
// comments or attributes where they stand, or writes them before the element, after it, or before its end tag. Every byte no splice touches stays, and the format reads the result again.

// The byte before each item of an array a format spells as an element's content, which no markup text holds.
MARKUP_ITEM :: "\x00"

// Where an element stands: `lo` at its `<`, `name` one past its name, `open` one past its start tag or at the `/` of
// an empty-element tag, `close` at its end tag or where its content ends when it has none, and `hi` one past it.
// `empty` says it is an empty-element tag, and `end_tag` that `close` starts its end tag.
Markup_Element :: struct {
	lo, name, open, close, hi: u64,
	empty, end_tag:            bool,
}

// Why a markup edit is refused, which a format names as a `Frozen` detail of its rules.
Markup_Refusal :: enum u8 {
	Reordered, // a reorder of an element that holds text, or that moves a member a new inline comment follows
	Not_Name, // a rename of `#text`, or a name the format cannot spell
	Text_Markup, // a text given an element or an array, or an element that holds text only given an element
	Nested_Array, // an array set as the document, which has one root element
	Comment_Body, // a comment body the format cannot hold
	Attribute_Body, // an attribute body that is not one attribute the format reads as written
	No_Place, // a fact or a member on a node that has no place for it
	Void, // content given an element that holds none
}

// What a markup format's edits read from it.
Markup :: struct {
	// The element of member value `v`, or the root element for the document.
	element:      proc(doc: ^core.Document, v: core.Node_Index) -> Markup_Element,
	is_name:      proc(name: []u8) -> bool,
	// Whether `body` is a comment's, or with `.Attribute` an attribute's, the format can hold.
	fact:         proc(role: core.Role, body: string) -> bool,
	// The content `text` is written as in element `name`, as a text run for `MARKUP_TEXT` or as the document for "",
	// and whether the element is void, with no end tag. Nil writes every text as it is.
	content:      proc(name: string, text: string, allocator: runtime.Allocator) -> (out: string, void: bool, refusal: Maybe(Markup_Refusal)),
	// A new element with no content is an empty-element tag.
	self_closing: bool,
	rules:        proc "contextless" () -> ^core.Rules,
	refusals:     [Markup_Refusal]u8,
}

@(private = "file")
Cx :: struct {
	doc:     ^core.Document,
	src:     []u8,
	m:       ^Markup,
	a:       runtime.Allocator,
	splices: [dynamic]Splice,
	seen:    map[u64]struct{},
	// The elements a reorder edit names, with the inserts into each, which the reorder places.
	orders:  map[core.Node_Index][dynamic]core.Edit,
	err:     core.Document_Error,
}

// Returns the source bytes `list`'s edits make as splices of the source, and the bytes `cut` removes, in one allocation
// of `allocator`, which the format then reads.
markup_commit :: proc(list: ^core.Edit_List, m: ^Markup, allocator: runtime.Allocator, cut: []Splice = nil) -> (out: []u8, err: core.Document_Error) {
	doc := list.doc
	arena := runtime.Arena{backing_allocator = allocator}
	defer runtime.arena_destroy(&arena)
	cx := Cx{doc = doc, src = doc.src, m = m, a = runtime.arena_allocator(&arena)}
	// The names a format decodes as it reads the elements live as long as the commit.
	context.allocator = cx.a
	cx.splices = make([dynamic]Splice, cx.a)
	cx.seen = make(map[u64]struct{}, cx.a)
	cx.orders = make(map[core.Node_Index][dynamic]core.Edit, cx.a)
	for e in list.edits {
		if e.op == .Reorder {
			cx.orders[e.node] = make([dynamic]core.Edit, cx.a)
		}
	}
	for e in list.edits {
		if e.op == .Insert && e.node in cx.orders {
			append(&cx.orders[e.node], e)
		}
	}
	for e in list.edits {
		if !apply(&cx, list, e) {
			return nil, cx.err
		}
	}
	emptied_layout(&cx, list)
	append(&cx.splices, ..cut)
	return apply_splices(doc.src, cx.splices[:], allocator)
}

// The content node `node` holds, as a format spells an edit's value: an element's between its tags, a text run's own
// bytes, and the root element for the document.
markup_content :: proc(doc: ^core.Document, m: ^Markup, node: core.Node_Index) -> (lo, hi: u64) {
	if node == core.ROOT {
		e := m.element(doc, node)
		return e.lo, e.hi
	}
	if n := doc.nodes[node]; n.kind != .Object {
		return n.lo, n.lo + u64(n.n)
	}
	e := m.element(doc, node)
	return e.open, e.close
}

// Writes the decoded name `name`, which a commit judges as the name of a new element.
markup_key_text :: proc(_: ^core.Document, name: []u8, text: ^[dynamic]u8) -> bool {
	return push_all(text, name)
}

// Whether value `v` is a text run, the value of a member `#text`, whose key is the node before it.
@(private = "file")
is_run :: proc(doc: ^core.Document, v: core.Node_Index) -> bool {
	return v != core.ROOT && core.key_equals(doc, v - 1, core.MARKUP_TEXT)
}

// The bytes member value `v` stands on: a text run's own, or its element's after the white space a reader drops before
// it, which stands between the element and the markup before it.
@(private = "file")
extent :: proc(cx: ^Cx, v: core.Node_Index) -> (lead, lo, hi: u64) {
	if is_run(cx.doc, v) {
		n := cx.doc.nodes[v]
		return n.lo, n.lo, n.lo + u64(n.n)
	}
	e := cx.m.element(cx.doc, v)
	lead = e.lo
	for lead > 0 && kernel.is_markup_ws(cx.src[lead - 1]) {
		lead -= 1
	}
	if lead == 0 || cx.src[lead - 1] != '>' {
		lead = e.lo
	}
	return lead, e.lo, e.hi
}

@(private = "file")
add :: proc(cx: ^Cx, lo, hi: u64, text: string) {
	append(&cx.splices, Splice{lo = lo, hi = hi, text = transmute([]u8)text, seq = len(cx.splices)})
}

@(private = "file")
refuse_edit :: proc(cx: ^Cx, node: core.Node_Index, why: Markup_Refusal) -> bool {
	cx.err = {kind = .Frozen, at = u64(node), inner = {rules = cx.m.rules(), detail = cx.m.refusals[why]}}
	return false
}

// Whether `text` is a text run's: no array, and no markup but comments, instructions and CDATA sections.
@(private = "file")
holds_text :: proc(text: string) -> bool {
	for c, i in transmute([]u8)text {
		if c == MARKUP_ITEM[0] || c == '<' && i + 1 < len(text) && text[i + 1] != '!' && text[i + 1] != '?' {
			return false
		}
	}
	return true
}

// The items of the array `text` spells, or `text` alone.
@(private = "file")
items_of :: proc(cx: ^Cx, text: string) -> []string {
	if len(text) == 0 || text[0] != MARKUP_ITEM[0] {
		return slice.clone([]string{text}, cx.a)
	}
	return strings.split(text[1:], MARKUP_ITEM, cx.a)
}

// The content `text` is written as in the element of member value `v`.
@(private = "file")
content_in :: proc(cx: ^Cx, v: core.Node_Index, name: string, text: string) -> (out: string, void, ok: bool) {
	if cx.m.content == nil {
		return text, false, true
	}
	refusal: Maybe(Markup_Refusal)
	out, void, refusal = cx.m.content(name, text, cx.a)
	if why, refused := refusal.?; refused {
		return "", false, refuse_edit(cx, v, why)
	}
	return out, void, true
}

// The elements of name `name` that hold `items`, set apart by `sep`.
@(private = "file")
elements :: proc(cx: ^Cx, at: core.Node_Index, name: string, items: []string, sep: string) -> (text: string, ok: bool) {
	b := make([dynamic]u8, cx.a)
	for item, i in items {
		if i > 0 {
			append(&b, sep)
		}
		content, void := content_in(cx, at, name, item) or_return
		if len(content) == 0 && (void || cx.m.self_closing) {
			puts(&b, "<", name, "/>" if cx.m.self_closing else ">")
		} else {
			puts(&b, "<", name, ">", content, "</", name, ">")
		}
	}
	return string(b[:]), true
}

// Takes member value `v` from the text.
@(private = "file")
drop :: proc(cx: ^Cx, v: core.Node_Index) {
	lead, _, hi := extent(cx, v)
	add(cx, lead, hi, "")
}

// Takes the white space a reader drops between the children of each element whose members the edits all remove and
// into which none inserts, which would read as its text once no child is left, so that the element reads as null, as
// it does when no white space is laid out. The element's comments and instructions stay.
@(private = "file")
emptied_layout :: proc(cx: ^Cx, list: ^core.Edit_List) {
	doc := cx.doc
	removed := make([dynamic]core.Node_Index, cx.a)
	for e in list.edits {
		if e.op == .Remove {
			append(&removed, e.node)
		}
	}
	slice.sort(removed[:])
	stack := make([dynamic]core.Node_Index, cx.a)
	held := make(map[core.Node_Index]int, cx.a)
	next := core.Node_Index(0)
	for r in slice.unique(removed[:]) {
		if parent, ok := parent_of(doc, r, &stack, &next); ok && parent != core.NO_NODE && parent != core.ROOT {
			held[parent] += 1
		}
	}
	parents: for parent, gone in held {
		for e in list.edits {
			if e.op == .Insert && e.node == parent {
				continue parents
			}
		}
		count := 0
		it := core.pairs(doc, parent)
		for _, _ in core.pair_next(&it) {
			count += 1
		}
		if count != gone {
			continue
		}
		e := cx.m.element(doc, parent)
		at := e.open
		it = core.pairs(doc, parent)
		for _, v in core.pair_next(&it) {
			lead, _, hi := extent(cx, v)
			drop_layout(cx, at, lead)
			at = hi
		}
		drop_layout(cx, at, e.close)
	}
}

// Takes each run of white space in `lo` through `hi` of the source that stands outside a comment or an instruction.
@(private = "file")
drop_layout :: proc(cx: ^Cx, lo, hi: u64) {
	src := cx.src[:hi]
	for i := lo; i < hi; {
		switch {
		case kernel.is_markup_ws(src[i]):
			j := i
			for j < hi && kernel.is_markup_ws(src[j]) {
				j += 1
			}
			add(cx, i, j, "")
			i = j
		case src[i] == '<':
			end := "-->" if strings.has_prefix(string(src[i:]), "<!--") else "?>" if strings.has_prefix(string(src[i:]), "<?") else ">"
			past := strings.index(string(src[i:]), end)
			i = hi if past < 0 else i + u64(past + len(end))
		case:
			i += 1
		}
	}
}

@(private = "file")
apply :: proc(cx: ^Cx, list: ^core.Edit_List, e: core.Edit) -> bool {
	switch e.op {
	case .Set:
		if e.role == .Key {
			return rename(cx, e)
		}
		return set_value(cx, e.node, string(e.text))
	case .Insert:
		// A reorder places the inserts into its element.
		return e.node in cx.orders || insert_edit(cx, e)
	case .Remove:
		drop(cx, e.node)
	case .Reorder:
		return reorder(cx, list, e)
	case .Set_Fact, .Remove_Fact:
		return fact_edit(cx, e)
	}
	return true
}

@(private = "file")
set_value :: proc(cx: ^Cx, v: core.Node_Index, text: string) -> bool {
	n := cx.doc.nodes[v]
	array := len(text) > 0 && text[0] == MARKUP_ITEM[0]
	switch {
	case v == core.ROOT:
		if array {
			return refuse_edit(cx, v, .Nested_Array)
		}
		e := cx.m.element(cx.doc, v)
		root, _ := content_in(cx, v, "", text) or_return
		add(cx, e.lo, e.hi, root)
	case array:
		return set_items(cx, {v}, items_of(cx, text))
	case is_run(cx.doc, v):
		run, _ := content_in(cx, v, core.MARKUP_TEXT, text) or_return
		if !holds_text(run) {
			return refuse_edit(cx, v, .Text_Markup)
		}
		add(cx, n.lo, n.lo + u64(n.n), run)
	case:
		e := cx.m.element(cx.doc, v)
		name := string(cx.src[e.lo + 1:e.name])
		content, void := content_in(cx, v, core.node_string(cx.doc, v - 1), text) or_return
		if !e.empty {
			add(cx, e.open, e.close, content)
		} else if len(content) > 0 && !void {
			add(cx, e.open, e.hi, strings.concatenate({">", content, "</", name, ">"}, cx.a))
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
	if is_run(cx.doc, last) {
		return refuse_edit(cx, last, .Text_Markup)
	}
	lead, lo, hi := extent(cx, last)
	sep := string(cx.src[lead:lo])
	more := elements(cx, last, core.node_string(cx.doc, last - 1), items[len(elems):], sep) or_return
	add(cx, hi, hi, strings.concatenate({sep, more}, cx.a))
	return true
}

// Respells the name in both tags of the element of key `e.node`.
@(private = "file")
rename :: proc(cx: ^Cx, e: core.Edit) -> bool {
	k := e.node
	if cx.doc.nodes[k].spelling & core.SPELLING_SYNTHETIC == core.SPELLING_SYNTHETIC || !cx.m.is_name(e.text) {
		return refuse_edit(cx, k, .Not_Name)
	}
	el := cx.m.element(cx.doc, k + 1)
	add(cx, el.lo + 1, el.name, string(e.text))
	if el.end_tag {
		add(cx, el.close + 2, el.close + 1 + el.name - el.lo, string(e.text))
	}
	return true
}

// Puts the members of element `e.node` in the order `e.text` gives, with the inserts into it. A member keeps its bytes
// from its first head comment through its inline comment, an edit inside it still applies, and the gaps between the
// places of the members the order keeps stay where they are, with the members a removal takes. An insert past those
// places follows the last, laid out by the white space before it. An element that holds text is refused, as moving a
// run would join it to another.
@(private = "file")
reorder :: proc(cx: ^Cx, list: ^core.Edit_List, e: core.Edit) -> bool {
	c := e.node
	claim(&cx.seen, &cx.err, u64(c) << 8 | 0xfe) or_return
	members := make([dynamic]core.Node_Index, cx.a)
	index := make(map[core.Node_Index]int, cx.a)
	it := core.pairs(cx.doc, c)
	for _, v in core.pair_next(&it) {
		if is_run(cx.doc, v) {
			return refuse_edit(cx, c, .Reordered)
		}
		index[v] = len(members)
		append(&members, v)
	}
	removed := make([]bool, len(members), cx.a)
	// A new inline comment goes at a member's end, where the gap after its place starts, so a moved member takes none.
	commented := make([]bool, len(members), cx.a)
	for x in list.edits {
		if i, member := index[x.node]; member {
			removed[i] ||= x.op == .Remove
			commented[i] ||= x.role == .Comment_Inline && (x.op == .Set_Fact || x.op == .Remove_Fact)
		}
	}
	inserts := cx.orders[c][:]
	slice.stable_sort_by(inserts, proc(a, b: core.Edit) -> bool {return a.at < b.at})
	if err := order_check(e.text, removed, len(inserts), cx.a); err.kind != .None {
		cx.err = err
		return false
	}
	// Each member's bytes, and the places of the members the order keeps, in source order.
	lo := make([]u64, len(members), cx.a)
	hi := make([]u64, len(members), cx.a)
	places := make([dynamic]int, cx.a)
	for v, i in members {
		el := cx.m.element(cx.doc, v)
		lo[i], hi[i] = el.lo, el.hi
		for f in core.all_facts(cx.doc, v) {
			#partial switch f.role {
			case .Comment:
				lo[i] = min(lo[i], f.lo)
			case .Comment_Inline:
				hi[i] = max(hi[i], f.lo + u64(f.n))
			}
		}
		if !removed[i] {
			append(&places, i)
		}
	}
	count := len(e.text) / 4
	if len(places) == 0 {
		for j in 0 ..< count {
			insert_edit(cx, inserts[order_at(e.text, j) - len(members)]) or_return
		}
		return true
	}
	last := places[len(places) - 1]
	lead, at, _ := extent(cx, members[last])
	sep := string(cx.src[lead:at])
	moves := make([dynamic]Move, cx.a)
	for j in 0 ..< count {
		k := order_at(e.text, j)
		switch {
		case j == 0:
		case j < len(places):
			append(&moves, Move{lo = hi[places[j - 1]], hi = lo[places[j]]})
		case:
			append(&moves, Move{text = transmute([]u8)sep, written = true})
		}
		if k >= len(members) {
			x := inserts[k - len(members)]
			if string(x.key) == core.MARKUP_TEXT || !cx.m.is_name(x.key) {
				return refuse_edit(cx, c, .Reordered if string(x.key) == core.MARKUP_TEXT else .Not_Name)
			}
			written := elements(cx, c, string(x.key), items_of(cx, string(x.text)), sep) or_return
			append(&moves, Move{text = transmute([]u8)written, written = true})
			continue
		}
		if commented[k] && (j >= len(places) || places[j] != k) {
			return refuse_edit(cx, c, .Reordered)
		}
		append(&moves, Move{lo = lo[k], hi = hi[k]})
	}
	append(&cx.splices, Splice{lo = lo[places[0]], hi = hi[last], moves = moves[:], seq = len(cx.splices)})
	return true
}

// Writes a new member of the element `e.node` before the member at `e.at`, or after the last.
@(private = "file")
insert_edit :: proc(cx: ^Cx, e: core.Edit) -> bool {
	c := e.node
	text := string(e.text)
	name := string(e.key)
	run := name == core.MARKUP_TEXT
	if !run && !cx.m.is_name(e.key) {
		return refuse_edit(cx, c, .Not_Name)
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
	lead, lo, hi := extent(cx, last)
	if at != core.NO_NODE {
		// Before the white space of the member, which a removal of the member takes too.
		lead, lo, _ = extent(cx, at)
		hi = lead
	} else {
		for f in core.all_facts(cx.doc, last) {
			if f.role == .Comment_Inline {
				hi = max(hi, f.lo + u64(f.n))
			}
		}
	}
	sep := string(cx.src[lead:lo])
	written: string
	if run {
		written, _ = content_in(cx, c, core.MARKUP_TEXT, text) or_return
		if !holds_text(written) {
			return refuse_edit(cx, c, .Text_Markup)
		}
	} else {
		written = elements(cx, c, name, items_of(cx, text), sep) or_return
	}
	add(cx, hi, hi, strings.concatenate({sep, written}, cx.a))
	return true
}

// Replaces the comments or the attributes of `e.node` of `e.role`: the first where it stands, the others with the white
// space before them. New ones go before an element, after an element, before an end tag or the text's end, or after an
// element's name.
@(private = "file")
fact_edit :: proc(cx: ^Cx, e: core.Edit) -> bool {
	v := e.node
	id := u64(v) << 8 | u64(e.role)
	claim(&cx.seen, &cx.err, id) or_return
	if is_run(cx.doc, v) {
		return refuse_edit(cx, v, .No_Place)
	}
	el := cx.m.element(cx.doc, v)
	b := make([dynamic]u8, cx.a)
	count := 0 if e.op == .Remove_Fact else fact_count(e)
	for k in 0 ..< count {
		body := string(fact_body(e, k))
		if !cx.m.fact(e.role, body) {
			return refuse_edit(cx, v, .Attribute_Body if e.role == .Attribute else .Comment_Body)
		}
		if e.role == .Attribute {
			puts(&b, " ", body)
		} else {
			spell_comment(&b, core.MARKUP_COMMENTS, transmute([]u8)body, false, false)
		}
	}
	first := true
	for f in core.all_facts(cx.doc, v) {
		if f.role != e.role || f.role == .Attribute && f.lo < el.lo {
			continue
		}
		lo := f.lo
		for lo > 0 && kernel.is_markup_ws(cx.src[lo - 1]) && (f.role == .Attribute || !first) {
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
	case e.role == .Comment:
		at = el.lo
	case e.role == .Comment_Foot && v == core.ROOT:
		at = u64(len(cx.src))
	case e.role == .Comment_Foot && !el.empty:
		at = el.close
	case:
		return refuse_edit(cx, v, .No_Place)
	}
	if v == core.ROOT && e.role == .Comment {
		// A blank line ends the text's head comment, which stands before the root element's comments at the same byte.
		puts(&b, "\n\n")
		append(&cx.splices, Splice{lo = at, hi = at, text = b[:], seq = -1})
		return true
	}
	add(cx, at, at, string(b[:]))
	return true
}
