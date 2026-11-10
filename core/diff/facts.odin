package diff

import "core:slice"
import "core:strings"
import core ".."

@(rodata)
@(private)
FACT_ROLES := [?]core.Role{.Comment, .Comment_Inline, .Comment_Foot, .Attribute}

// Whether neither value holds a fact below it, so equal values have nothing left to tell.
@(private)
quiet :: proc(a, b: core.Value) -> bool {
	for v in ([2]core.Value{a, b}) {
		if r, is_node := core.plain(v).(core.Node_Ref); is_node && len(core.subtree_facts(r.doc, r.node)) > 0 {
			return false
		}
	}
	return true
}

// Whether the format of `doc` can hold a fact of `role`, which a comment needs the format to spell and an attribute
// needs it to read.
@(private)
carries :: proc(doc: ^core.Document, role: core.Role) -> bool {
	if doc.readers == nil {
		return false
	}
	if role == .Attribute {
		return doc.readers.attribute != nil
	}
	if s := doc.readers.services; s != nil && s.edit != nil && s.edit.comment != nil {
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
	if !a_node || !b_node || len(ra.doc.facts) + len(rb.doc.facts) == 0 {
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

// The facts of `role` on a node as texts: a comment's body in source order, an attribute as `name=value` in name order.
@(private)
fact_texts :: proc(r: core.Node_Ref, role: core.Role) -> []string {
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
