package diff

import "core:slice"
import "core:strings"
import core ".."

@(rodata)
@(private)
FACT_ROLES := [?]core.Role{.Comment, .Comment_Inline, .Comment_Foot, .Attribute, .Tag, .Anchor}

// Whether neither value holds a fact below it, so equal values have nothing left to tell. A built array holds nodes,
// each of them, only when it is the array of a name a markup node repeats. A node of a format that spells facts may
// hold one.
@(private)
quiet :: proc(a, b: core.Value) -> bool {
	for v in ([2]core.Value{a, b}) {
		#partial switch x in core.plain(v) {
		case core.Node_Ref:
			if spells_facts(x.doc) || len(core.subtree_facts(x.doc, x.node)) > 0 {
				return false
			}
		case ^core.Array:
			for item in x.items {
				r := core.plain(item).(core.Node_Ref) or_break
				if len(core.subtree_facts(r.doc, r.node)) > 0 {
					return false
				}
			}
		}
	}
	return true
}

// Whether the format of `doc` can hold a fact of `role`: a comment needs the format to spell one, an attribute needs it
// to read, a tag needs the edit services to write property facts or the format to spell it in a value's text, and an
// anchor needs the edit services.
@(private)
carries :: proc(doc: ^core.Document, role: core.Role) -> bool {
	if doc.readers == nil {
		return false
	}
	if role == .Attribute {
		return doc.readers.attribute != nil
	}
	if role == .Tag && doc.readers.fact != nil {
		return true
	}
	s := doc.readers.services
	if s == nil || s.edit == nil {
		return false
	}
	if core.is_property(role) {
		return s.edit.prefix != nil
	}
	if s.edit.comment != nil {
		style, _ := s.edit.comment(doc, doc.spec)
		return style != .None
	}
	return false
}

// Reports each role whose facts differ on the nodes `a` and `b`, when both documents carry the role.
@(private)
facts :: proc(d: ^Differ, a, b: core.Value) {
	ra, a_node := core.plain(a).(core.Node_Ref)
	rb, b_node := core.plain(b).(core.Node_Ref)
	if !a_node || !b_node || len(ra.doc.facts) + len(rb.doc.facts) == 0 && !spells_facts(ra.doc) && !spells_facts(rb.doc) {
		return
	}
	ai, bi := memo_of(d, ra.doc), memo_of(d, rb.doc)
	ma, mb := d.memos[ai], d.memos[bi]
	for role, i in FACT_ROLES {
		if !ma.carries[i] || !mb.carries[i] {
			continue
		}
		old, new := fact_texts(ra, role), fact_texts(rb, role)
		if !slice.equal(old, new) {
			emit(d, .Fact, strings.join(old, "\n", d.allocator), strings.join(new, "\n", d.allocator), false, role)
		}
	}
}

// Whether the format of `doc` spells facts its document holds no span of.
@(private = "file")
spells_facts :: proc(doc: ^core.Document) -> bool {
	return doc.readers != nil && doc.readers.fact != nil
}

// The facts of `role` on a node as texts: a comment's, tag's or anchor's body in source order, an attribute as
// `name=value` in name order.
@(private)
fact_texts :: proc(r: core.Node_Ref, role: core.Role) -> []string {
	if role == .Tag {
		tag, held := core.fact_value(r.doc, r.node, .Tag)
		out := make([]string, 1 if held else 0, context.temp_allocator)
		copy(out, []string{tag.text})
		return out
	}
	if core.is_property(role) {
		out := make([dynamic]string, context.temp_allocator)
		it := core.facts_of(r.doc, r.node, role)
		for body in core.fact_next(&it) {
			append(&out, body)
		}
		return out[:]
	}
	if role != .Attribute {
		context.allocator = context.temp_allocator
		bodies, _ := core.comments(r, role)
		return bodies
	}
	out := make([dynamic]string, context.temp_allocator)
	it := core.attributes_of(r.doc, r.node)
	for name, value in core.attribute_next(&it) {
		n, _ := core.token_text(r.doc.readers, &r.doc.view, name, context.temp_allocator)
		v, _ := core.token_text(r.doc.readers, &r.doc.view, value, context.temp_allocator)
		append(&out, strings.concatenate({n, "=", v}, context.temp_allocator))
	}
	slice.sort(out[:])
	return out[:]
}
