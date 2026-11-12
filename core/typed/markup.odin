package typed

import spell "../spell"
import core ".."
import rules "../rules"
import build "../build"

// The typed read and the check of a built markup document, a document whose format reads attributes. An element is an
// object member whose value is its text, empty when the element is, or an object of its child elements and `#text` runs.
// A read into a type reads an element at a struct as an object of its attributes, its text as the member `#text` and its
// child elements, and collects the siblings of a name a slice, a dynamic or a fixed array reads, wherever they stand.
// Any other type reads an element's text by its kind, as `typed_text` says. The check reads it as its description does:
// - an element with attributes, and a scalar element whose record takes objects and no scalar, is an object of its
//   attributes, then its text as the member whose record binds the text, else `#text`, none when it is empty;
// - a member whose record takes arrays and nothing else but null, or has no type and an array keyword, collects the
//   siblings of its name as one array at the first one's place, wherever they stand, and the later ones are passed
//   over. With `prefixItems` it collects only when its name repeats;
// - an array record with `prefixItems` that takes no object reads a lone element's child sequence, text runs included.
// A member record bound to an attribute, a child element or the text (`Use.node`) reads no other node of its name.
// Every container at a `Checked` record is fed here, child by child, so the outer replay never opens one and a
// collected sibling is read where the first stands. Every record of a description's plan is `Checked`.

// The node of a markup element a member record reads, which a format's `bind` sets from its keyword: `.Any` an
// attribute or a child element of its name.
Markup_Node :: rules.Markup_Node

// The spelling of the key the element step makes for an element's text, which no format's key has.
@(private)
TEXT_KEY :: core.SPELLING_DECODE | 1 << 15

// The name of an element's text when no member record binds it.
@(private)
TEXT_NAME :: core.MARKUP_TEXT

// A markup element's children as `child_step` gives them to the check. The values a collection took are marked by their
// place past `at`, in `small` and past it in `spill`.
@(private)
Element_Read :: struct($H: typeid) {
	d:        ^Document_Read(H),
	at:       core.Node_Index,
	sequence: bool,
	stopped:  bool,
	small:    [4]u64,
	spill:    [dynamic]u64,
}

// The value `t` at node `at` of a markup document.
@(private)
element_step :: proc "contextless" (d: ^Document_Read($H), regs: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	h := &d.reader
	fld := field_at(regs.b)
	when H == Reader {
		// A pointer or a `Maybe` reads its element's tokens.
		for (fld.kind == .Ptr || fld.kind == .Maybe) && fld.first != nil {
			fld = field_at(u64(uintptr(fld.first)))
		}
	}
	// A struct's record reads an element as an object. It collects no repeated child, so a repeat is the struct's.
	structured := fld.kind == .Struct || fld.kind == .Required
	if fld.kind != .Checked && !structured {
		return hook_spelled(h, regs, typed_text(h, fld, t))
	}
	l: ^rules.Leaf
	when H == Check {
		prefixed: bool
		if !structured {
			l, _, prefixed = record_rules(h, fld)
		}
		if l != nil && .Object not_in l.kinds && prefixed {
			return element_children(d, regs, t, at, true)
		}
	}
	if t.kind == .Array {
		return hook_spelled(h, regs, t)
	}
	if t.kind == .Object {
		return element_children(d, regs, t, at, false)
	}
	context = h.ctx
	attributes := core.attributes_of(d.doc, at)
	objects := structured || l != nil && l.kinds & (rules.EVERY_KIND - {.Array}) == {.Object}
	if _, _, held := core.attribute_next(&attributes); !objects && !held {
		return hook_spelled(h, regs, t)
	}
	next, action := element_open(d, regs, {kind = .Object, lo = t.lo})
	if action != .Next {
		return next, action
	}
	if next, action = feed_attributes(d, next, at); action == .Stop {
		return next, action
	}
	if !no_text(t) {
		key := core.Token{lo = t.lo, kind = .String, role = .Key, spelling = TEXT_KEY}
		if next, action = hook(h, next, key); action == .Next {
			next, action = hook_spelled(h, next, typed_text(h, field_at(next.b), t))
		}
		if action == .Stop {
			return next, action
		}
	}
	_, hi := core.scalar_ends(t)
	return element_close(h, next, hi)
}

// The text `t` of an element as the record `fld` reads it. A `Plain` text has no kind, which a `Checked` record's
// leaf picks. A record of a type reads it by that type, as a delimited cell is read by its column's: a number where the
// type is a number and the text is exactly a JSON number, `true` and `false` where the type is a boolean, and a string
// anywhere else. A union reads it as `infer` does, an empty text as null.
@(private)
typed_text :: proc "contextless" (h: ^Reader, fld: ^Field, t: core.Token) -> core.Token {
	t := t
	if t.kind != .Plain || fld.kind == .Checked {
		return t
	}
	t.kind = .String
	#partial switch fld.kind {
	case .I8 ..= .F64:
		text_number(h, &t)
	case .Bool:
		text_bool(h, &t)
	case .Union:
		if t.n == 0 {
			t.kind = .Null
		} else if !text_number(h, &t) {
			text_bool(h, &t)
		}
	}
	return t
}

// Makes the text `t` a number when it is exactly a JSON number. A number's digits are its span, so a text that needs a
// decode is none.
@(private)
text_number :: proc "contextless" (h: ^Reader, t: ^core.Token) -> bool {
	if t.spelling & core.SPELLING_DECODE != 0 {
		return false
	}
	int_digits, frac_digits, has_exp, ok := spell.number_shape_strict(h.src, t.lo, t.lo + u64(t.n))
	if ok {
		t.kind = .Number
		t.spelling = core.number_spelling(0, int_digits, frac_digits) | (core.NUMBER_EXP if has_exp else 0)
		h.mant = fold_digits(h.src, t^)
	}
	return ok
}

// Makes the text `t` a boolean when it is `true` or `false`.
@(private)
text_bool :: proc "contextless" (h: ^Reader, t: ^core.Token) {
	buf: [TEXT_ROOM]u8 = ---
	switch text, _ := decoded_text(h, t^, buf[:]); text {
	case "true":
		t.kind, t.spelling = .True, 0
	case "false":
		t.kind, t.spelling = .False, 0
	}
}

// The children of the element `t` at node `at`, an object or, as `sequence` says, an array of its child values.
@(private)
element_children :: proc "contextless" (d: ^Document_Read($H), regs: core.Hook_Regs, t: core.Token, at: core.Node_Index, sequence: bool) -> (core.Hook_Regs, core.Action) {
	h := &d.reader
	context = h.ctx
	open := t
	if sequence {
		open.kind = .Array
	}
	next, action := element_open(d, regs, open)
	if action != .Next {
		return next, action
	}
	if t.kind <= .Plain {
		// The sequence of an element with no child element is its text, none when it is empty.
		if !no_text(t) {
			if next, action = hook_spelled(h, next, t); action == .Stop {
				return next, action
			}
		}
		_, hi := core.scalar_ends(t)
		return element_close(h, next, hi)
	}
	if !sequence {
		if next, action = feed_attributes(d, next, at); action == .Stop {
			return next, action
		}
	}
	e := Element_Read(H){d = d, at = at, sequence = sequence}
	defer delete(e.spill)
	// The children open no container but at a record that is not `Checked`, so the ends rarely grow.
	ends: [4]u32 = ---
	if !build.feed_nodes(d.doc, u32(at) + 1, u32(at) + t.n, &e, &next, ends[:], child_step, child_keyed, child_deepen, true) {
		d.short = true
	}
	if e.stopped || d.short {
		return next, .Stop
	}
	return element_close(h, next, d.doc.readers.close_end(d.doc, at))
}

// A child of the element `e` reads, a key a member and a value a step of the document, a key passed over in a sequence
// and at a sibling a collection took.
@(private)
child_step :: proc "contextless" (e: ^Element_Read($H), regs: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	h := &e.d.reader
	context = h.ctx
	next, action := regs, core.Action.Next
	switch {
	case t.role != .Key:
		next, action = document_step(e.d, regs, t, at)
	case e.sequence:
	case marked(e, at + 1):
		action = .Skip
	case !binds(h, t, .Element):
		action = .Skip
	case:
		if next, action = hook(h, regs, t); action == .Next {
			if arrays, prefixed := collects(h, field_at(next.b)); arrays {
				next, action = collect(e, next, at, prefixed)
			}
		}
	}
	e.stopped ||= action == .Stop
	return next, action
}

@(private)
child_keyed :: proc "contextless" (e: ^Element_Read($H), regs: core.Hook_Regs, i, open: core.Node_Index) -> (core.Node_Index, bool) {
	return document_keyed(e.d, regs, i, open)
}

@(private)
child_deepen :: proc "contextless" (e: ^Element_Read($H), extra: int) -> bool {
	return document_deepen(e.d, extra)
}

// The leaf and the use of the `Checked` record `fld`, nil for no leaf, and whether its arrays have `prefixItems`.
@(private)
record_rules :: proc "contextless" (h: ^Check, fld: ^Field) -> (l: ^rules.Leaf, u: ^Use, prefixed: bool) {
	if rule_set := h.plan.meta[fld.meta].rule_set; rule_set > 0 {
		l = &h.plan.leaves[rule_set - 1]
	}
	u = &h.plan.uses[fld.meta]
	// `items` is the cursor past the first element's record.
	return l, u, u.items > 0 && h.plan.uses[h.plan.fields[u.items - 1].meta].step
}

// Whether the member record `fld` collects the siblings of its name, and whether it has `prefixItems`, so it collects only
// a name that repeats. A type's member collects them when it is a list, under a check as under a read.
@(private)
collects :: proc "contextless" (h: ^$H, fld: ^Field) -> (arrays, prefixed: bool) {
	#partial switch fld.kind {
	case .Slice, .Dynamic, .Array, .Fixed_List:
		return true, false
	case .Checked:
		when H == Check {
			l, u, prefixed_ := record_rules(h, fld)
			if l == nil {
				return u.inside, prefixed_
			}
			untyped := l.kinds == rules.EVERY_KIND && (u.inside || l.min_items > 0 || l.max_items != max(u64))
			return l.kinds - {.Null} == {.Array} || untyped, prefixed_
		}
	}
	return false, false
}

// The member whose key is node `k` of the element `e` reads and its siblings of the same name, as one array, each later
// one marked. A record with `prefixItems` whose name does not repeat reads its element as it stands.
@(private)
collect :: proc(e: ^Element_Read($H), regs: core.Hook_Regs, k: core.Node_Index, prefixed: bool) -> (core.Hook_Regs, core.Action) {
	d := e.d
	h := &d.reader
	doc := d.doc
	buf: [TEXT_ROOM]u8 = ---
	name, ok := decoded_text(h, doc.nodes[k], buf[:])
	if !ok {
		return regs, .Stop
	}
	if prefixed && next_named(e, k, name) == core.NO_NODE {
		return regs, .Next
	}
	next, action := element_open(d, regs, {kind = .Array, lo = doc.nodes[k + 1].lo})
	if action == .Stop {
		return next, action
	}
	reading := action == .Next
	last := k + 1
	it := core.doc_pairs(doc, e.at)
	for key, v in core.doc_pair_next(&it) {
		if key < k || key > k && !h.plan.readers.key_equals(&h.view, doc.nodes[key], name) {
			continue
		}
		if key > k && !mark(e, v) {
			d.short = true
			return next, .Stop
		}
		last = v
		if reading {
			if next, action = document_step(d, next, doc.nodes[v], v); action == .Stop {
				return next, action
			}
		}
	}
	if !reading {
		return next, action
	}
	if doc.nodes[last].kind > .Plain {
		return element_close(h, next, doc.readers.close_end(doc, last))
	}
	_, hi := core.scalar_ends(doc.nodes[last])
	return element_close(h, next, hi)
}

// The value of the first sibling past key `k` of the element `e` reads whose key is `name`, `NO_NODE` for none.
@(private)
next_named :: proc(e: ^Element_Read($H), k: core.Node_Index, name: string) -> core.Node_Index {
	h := &e.d.reader
	it := core.doc_pairs(e.d.doc, e.at)
	for key, v in core.doc_pair_next(&it) {
		if key > k && h.plan.readers.key_equals(&h.view, e.d.doc.nodes[key], name) {
			return v
		}
	}
	return core.NO_NODE
}

// The word of the bit of value `v`'s place in the element `e` reads, nil past the spill.
@(private)
bit_word :: proc "contextless" (e: ^Element_Read($H), v: core.Node_Index) -> ^u64 {
	bit := int(v - e.at)
	if bit < 64 * len(e.small) {
		return &e.small[bit >> 6]
	}
	if w := bit >> 6 - len(e.small); w < len(e.spill) {
		return &e.spill[w]
	}
	return nil
}

@(private)
marked :: proc "contextless" (e: ^Element_Read($H), v: core.Node_Index) -> bool {
	w := bit_word(e, v)
	return w != nil && w^ & (1 << uint(int(v - e.at) & 63)) != 0
}

// Marks value `v`, false when the spill cannot grow.
@(private)
mark :: proc(e: ^Element_Read($H), v: core.Node_Index) -> bool {
	if bit_word(e, v) == nil && resize(&e.spill, int(v - e.at) >> 6 - len(e.small) + 1) != nil {
		return false
	}
	bit_word(e, v)^ |= 1 << uint(int(v - e.at) & 63)
	return true
}

// Opens the container `t` at `regs`, with room for its frame.
@(private)
element_open :: proc "contextless" (d: ^Document_Read($H), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if d.reader.sp + 2 > d.room && !document_deepen(d, d.room) {
		d.short = true
		return regs, .Stop
	}
	return hook(&d.reader, regs, t)
}

// Closes the container `element_open` opened, whose bytes end before `hi`. A replay passes over its nodes.
@(private)
element_close :: proc "contextless" (h: ^$H, regs: core.Hook_Regs, hi: u64) -> (core.Hook_Regs, core.Action) {
	next, action := hook(h, regs, {kind = .End, lo = hi - 1, n = 1})
	return next, .Stop if action == .Stop else .Skip
}

// Feeds the attributes of the element whose value is node `at` to the open object at `regs`, as members.
@(private)
feed_attributes :: proc(d: ^Document_Read($H), regs: core.Hook_Regs, at: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	regs := regs
	it := core.attributes_of(d.doc, at)
	for name, value in core.attribute_next(&it) {
		if !binds(&d.reader, name, .Attribute) {
			continue
		}
		next, action := hook(&d.reader, regs, name)
		if action == .Next {
			next, action = hook_spelled(&d.reader, next, typed_text(&d.reader, field_at(next.b), value))
		}
		if action == .Stop {
			return next, action
		}
		regs = next
	}
	return regs, .Next
}

// Whether the member `key` names in the open object may be read from a `node`: no member record of its name binds
// another node.
@(private)
binds :: proc(h: ^Reader, key: core.Token, node: Markup_Node) -> bool {
	owner := field_at(h.frames[h.sp - 1].b)
	m := &h.plan.meta[owner.meta]
	if m.members == 0 || len(h.plan.uses) == 0 {
		return true
	}
	buf: [TEXT_ROOM]u8 = ---
	name, ok := decoded_text(h, key, buf[:])
	i := member_index(h, owner, m, name) if ok else -1
	return i < 0 || h.plan.uses[([^]Field)(owner.first)[i].meta].node in bit_set[Markup_Node]{.Any, node}
}

// The text of key `t` of the object at the record `owner`, for the element's text the name of the member whose record
// binds it, else `#text`.
@(private)
member_text :: #force_inline proc "contextless" (h: ^Check, owner: ^Field, t: core.Token, buf: []u8) -> (string, bool) {
	if t.spelling & core.SPELLING_DECODE == 0 || t.spelling != TEXT_KEY {
		return decoded_text(h, t, buf)
	}
	m := &h.plan.meta[owner.meta]
	at := ([^]Field)(owner.first)
	for i in 0 ..< int(m.members) {
		if len(h.plan.uses) > 0 && h.plan.uses[at[i].meta].node == .Text {
			return h.plan.meta[at[i].meta].name, true
		}
	}
	return TEXT_NAME, true
}

// Whether the scalar element `t` holds no text: an empty element, or one a format reads as null.
@(private)
no_text :: #force_inline proc "contextless" (t: core.Token) -> bool {
	return t.kind == .Null || (t.kind == .String || t.kind == .Plain) && t.n == 0
}
