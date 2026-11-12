package core

import "core:slice"
import spell "./spell"

// The readers every markup format shares, over the document shape they all build: the document is an `Object` whose
// members are elements, an element is a member under its name whose value is its text, a `Plain`, or an `Object` of its
// child elements and `MARKUP_TEXT` runs, and its attributes are `Attribute` facts of that value. A format fills its
// `Readers` with these and adds what its own spelling needs.

// The name of the member that holds the text between an element's children. No element of a markup format can have
// it, since `#` starts no name.
MARKUP_TEXT :: "#text"

// The longest lead an attribute fact's `spelling` holds. A fact whose value starts further in has this lead, and its
// format's `Readers.attribute` finds the value from the name.
ATTRIBUTE_LEAD_MAX :: 255

// The `spelling` of an attribute fact whose value starts `lead` bytes past its name's first byte, saturated at
// `ATTRIBUTE_LEAD_MAX`, with the closing quote as the tail when the value is `quoted`.
attribute_spelling :: #force_inline proc "contextless" (lead: int, quoted: bool) -> u16 {
	return comment_spelling(u8(min(lead, ATTRIBUTE_LEAD_MAX)), 1 if quoted else 0)
}

// What the untyped text `text` is: an empty text is a null, and any other a string, or with `infer` a boolean for
// `true` and `false` and a number for a text that is exactly a JSON number.
markup_kind :: proc(text: []u8, infer: bool) -> Kind {
	if len(text) == 0 {
		return .Null
	}
	if !infer {
		return .String
	}
	kind, _ := plain_kind(text, 0, u64(len(text)), true, true)
	return kind
}

// What `Plain` node `i` is, its text decoded through the format's `text` and read by `markup_kind`. A key reads as a
// string. A decode longer than the stack holds is made in the temp allocator.
markup_resolve :: proc(doc: ^Document, i: Node_Index, infer: bool) -> Kind {
	n := doc.nodes[i]
	if n.role != .Value {
		return .String
	}
	if n.spelling & SPELLING_DECODE == 0 {
		return markup_kind(node_text(doc.src, n), infer)
	}
	stack: [256]u8
	buf := stack[:]
	if size := text_room(doc, i); size > len(stack) {
		buf = make([]u8, size, context.temp_allocator)
	}
	decoded, _ := doc.readers.text(&doc.view, n, buf)
	return markup_kind(transmute([]u8)decoded, infer)
}

// The number a `Plain` element value spells, exactly a JSON number, read through the format's `text`. Only a value the
// document's `infer` resolves as a number has one. A decode longer than the stack holds is made in the temp allocator.
markup_number :: proc(v: ^Token_View, t: Token) -> (Number, bool) {
	if t.kind != .Plain || t.role != .Value {
		return {}, false
	}
	if t.spelling & SPELLING_DECODE == 0 {
		return spell.number_strict(v.src, t.lo, t.lo + u64(t.n))
	}
	stack: [128]u8
	buf := stack[:]
	if room := view_room(v.readers, v, t); room > len(stack) {
		buf = make([]u8, room, context.temp_allocator)
	}
	decoded, ok := v.readers.text(v, t, buf)
	if !ok {
		return {}, false
	}
	return spell.number_strict(transmute([]u8)decoded, 0, u64(len(decoded)))
}

// The digits of a `Plain` element value the document resolves to a number, a markup format's `Readers.number_text`:
// the span when it is the text, else the text decoded through the format's `text`, in `buf`, false when `buf` is too
// short. A decode longer than `buf` is made in the temp allocator first, since a span may hold markup the text drops.
markup_number_text :: proc(v: ^Token_View, t: Token, buf: []u8) -> (s: string, ok: bool) {
	if t.spelling & SPELLING_DECODE == 0 {
		return string(v.src[t.lo:t.lo + u64(t.n)]), true
	}
	room := view_room(v.readers, v, t)
	if room <= len(buf) {
		return v.readers.text(v, t, buf)
	}
	decoded := v.readers.text(v, t, make([]u8, room, context.temp_allocator)) or_return
	if len(decoded) > len(buf) {
		return "", false
	}
	return string(buf[:copy(buf, decoded)]), true
}

// The facts every markup format reads from the document's shape for node `i`, the value of an element: `Name`, the key
// before the value, and `Content`, the element's string value, its text and its descendants' text in document order
// in the temp allocator. Returns false for any other name, which the format answers itself.
markup_fact :: proc(doc: ^Document, i: Node_Index, name: Fact_Name) -> (Fact_Value, bool) {
	#partial switch name {
	case .Name:
		if i == ROOT || doc.nodes[i - 1].role != .Key {
			return {}, false
		}
		s, ok := token_text(doc.readers, &doc.view, doc.nodes[i - 1], context.temp_allocator)
		return {text = s}, ok
	case .Content:
		return {text = markup_content(doc, i)}, true
	}
	return {}, false
}

// The string value of the element at node `i`: the decoded text of every `Plain` value in its subtree, in document
// order, in the temp allocator.
@(private)
markup_content :: proc(doc: ^Document, i: Node_Index) -> string {
	out := make([dynamic]u8, context.temp_allocator)
	end := i + 1
	if doc.nodes[i].kind == .Object {
		end = i + Node_Index(doc.nodes[i].n)
	}
	for j in i ..< end {
		t := doc.nodes[j]
		if t.role != .Value || t.kind != .Plain {
			continue
		}
		if t.spelling & SPELLING_DECODE == 0 {
			append(&out, ..node_text(doc.src, t))
			continue
		}
		start := len(out)
		resize(&out, start + text_room(doc, j))
		decoded, _ := doc.readers.text(&doc.view, t, out[start:])
		copy(out[start:], decoded)
		resize(&out, start + len(decoded))
	}
	return string(out[:])
}

// Whether `doc` is a markup document: its format has attributes. Its values read a name an element's children repeat
// as one member, an array of each of the elements in document order, as `markup_members` gives them. A markup document
// holds no array, so an array member of its value is such a group.
is_markup :: #force_inline proc "contextless" (doc: ^Document) -> bool {
	return doc.readers != nil && doc.readers.attribute != nil
}

// The members of object node `r` of a markup document as a built object one level deep, in the context allocator:
// each name once at the place of its first element, with its node, or with an array of the nodes of each element of the
// name in document order when the name repeats.
markup_members :: proc(r: Node_Ref) -> ^Object {
	o := new_object()
	it := doc_pairs(r.doc, r.node)
	for k, v in doc_pair_next(&it) {
		markup_put(o, node_string(r.doc, k), Node_Ref{r.doc, v})
	}
	return o
}

// The value of the member `name` of object node `r` of a markup document: the node of the one element of the name, or
// an array of the nodes of each in document order, made in the context allocator, when the name repeats.
markup_member :: proc(r: Node_Ref, name: string) -> (v: Value, found: bool) {
	it := members_named(r.doc, r.node, name)
	first := member_next(&it) or_return
	second, repeated := member_next(&it)
	if !repeated {
		return Node_Ref{r.doc, first}, true
	}
	group := new_array(2)
	append(&group.items, Node_Ref{r.doc, first}, Node_Ref{r.doc, second})
	for node in member_next(&it) {
		array_append(group, Node_Ref{r.doc, node})
	}
	return group, true
}

// `k` set to `v` in an object of a markup value being built, in place: a name it has becomes an array of its values in
// the order they were set, or grows by `v` when it is one already.
@(private)
markup_put :: proc(o: ^Object, k: string, v: Value) {
	i := object_slot(o, k)
	if i < 0 {
		object_append(o, k, v)
		return
	}
	if group, grouped := o.vals[i].(^Array); grouped {
		array_append(group, v)
		return
	}
	group := new_array(2)
	append(&group.items, o.vals[i], v)
	o.vals[i] = group
}

// A document of node `r` of a markup document, its root, read as its value reads it: each name of an element once, a
// repeated one as an `Array` of each of its elements in document order. Its nodes, facts and child counts are new
// allocations from `allocator`, freed by `free_grouped`, and the rest is `r.doc`'s own, its text and its format's
// tables, so it lives no longer than `r.doc` does. A writer of a format with no attributes writes this, so that the
// text it makes reads back as the value. A frame of the stack it is filled from is in the temp allocator.
@(private)
markup_grouped :: proc(r: Node_Ref, allocator := context.allocator) -> Document {
	// An object being copied: `at` its node in the copy, `members` its names in the order of their first element, and
	// `group` the array whose items are being copied from `item` on, with its node at `group_at`.
	Frame :: struct {
		at:       Node_Index,
		next:     int, // the member copied next
		members:  ^Object,
		group:    ^Array,
		group_at: Node_Index,
		item:     int,
	}
	src := r.doc
	g := src^
	g.allocator = allocator
	g.root_close = 0
	g.indexed = nil
	g.answers, g.kept, g.missing, g.reads_block = nil, nil, nil, nil
	nodes := make([dynamic]Node, 0, len(src.nodes), allocator)
	facts := make([dynamic]Fact, 0, len(src.facts), allocator)
	counts := make([dynamic]Child_Count, 0, len(src.counts), allocator)
	stack := make([dynamic]Frame, 0, 16, context.temp_allocator)
	// Node `i` of the source appended to the copy with its facts, and an object made the frame that its members follow.
	put :: proc(src: ^Document, i: Node_Index, nodes: ^[dynamic]Node, facts: ^[dynamic]Fact, stack: ^[dynamic]Frame) {
		at := Node_Index(len(nodes))
		end := i + 1
		if t := src.nodes[i]; t.kind == .Object && t.role == .Value {
			context.allocator = context.temp_allocator
			append(stack, Frame{at = at, members = markup_members(Node_Ref{src, i})})
		} else if t.kind >= .Array {
			end = i + Node_Index(t.n)
		}
		for j in i ..< end {
			append(nodes, src.nodes[j])
			for f in all_facts(src, j) {
				f := f
				f.node = at + (j - i)
				append(facts, f)
			}
		}
	}
	// Container `at` of the copy closed with `count` children.
	close :: proc(nodes: []Node, counts: ^[dynamic]Child_Count, at: Node_Index, count: int) {
		nodes[at].n = u32(len(nodes) - int(at))
		nodes[at].spelling = u16(min(count, int(MAX_CHILDREN)))
		if count >= int(MAX_CHILDREN) {
			append(counts, Child_Count{at, u32(count)})
		}
	}
	put(src, r.node, &nodes, &facts, &stack)
	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		if f.group != nil {
			if f.item < len(f.group.items) {
				f.item += 1
				put(src, f.group.items[f.item - 1].(Node_Ref).node, &nodes, &facts, &stack)
				continue
			}
			close(nodes[:], &counts, f.group_at, len(f.group.items))
			f.group = nil
		}
		if f.next < len(f.members.vals) {
			v := f.members.vals[f.next]
			f.next += 1
			if group, grouped := v.(^Array); grouped {
				first := group.items[0].(Node_Ref).node
				append(&nodes, src.nodes[first - 1])
				f.group, f.item, f.group_at = group, 0, Node_Index(len(nodes))
				append(&nodes, Node{lo = src.nodes[first].lo, kind = .Array, role = .Value})
				continue
			}
			node := v.(Node_Ref).node
			put(src, node - 1, &nodes, &facts, &stack)
			put(src, node, &nodes, &facts, &stack)
			continue
		}
		close(nodes[:], &counts, f.at, len(f.members.keys))
		pop(&stack)
	}
	// Nodes and so facts are appended in node order, and a container's count when it closes, after its children's.
	slice.sort_by(counts[:], proc(a, b: Child_Count) -> bool {return a.node < b.node})
	g.nodes, g.nodes_alloc = nodes[:], raw_data(nodes)[:cap(nodes)]
	g.facts, g.facts_alloc = facts[:], raw_data(facts)[:cap(facts)]
	g.counts, g.counts_alloc = counts[:], raw_data(counts)[:cap(counts)]
	return g
}

// Frees what `markup_grouped` made `g` from, leaving the source document's text and tables alone.
@(private)
free_grouped :: proc(g: ^Document) {
	delete(g.nodes_alloc, g.allocator)
	delete(g.facts_alloc, g.allocator)
	delete(g.counts_alloc, g.allocator)
	g^ = {}
}
