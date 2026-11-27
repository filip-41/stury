package edit

import "base:runtime"
import "core:container/handle_map"
import "core:slice"
import "core:strings"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"

// Markup-family composer (XML 1.0 + Namespaces).
// Preserves untargeted tags, attributes, CDATA, PIs, DOCTYPE, and comments verbatim.

Markup_Element :: struct {
	lo, name, open, close, hi: u64,
	empty, end_tag:            bool,
}

Markup_Spec :: struct {
	target:         ^tape.Format,
	self_closing:   bool,
	element:        proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> Markup_Element,
	is_name:        proc "contextless" (name: []u8) -> bool,
	is_void:        proc "contextless" (name: string) -> bool,
	spell_content:  proc(data: rawptr, ov: ^Overlay, h: Handle, out: ^[dynamic]u8) -> Error,
	spell_attr_val: proc(data: rawptr, val: string, quote: u8, out: ^[dynamic]u8) -> Error,
	validate:       proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	data:           rawptr,
}

@(private = "file")
Markup_Cx :: struct {
	ov:        ^Overlay,
	doc:       ^tape.Document,
	src:       []u8,
	spec:      ^Markup_Spec,
	opts:      Options,
	eol:       string,
	splices:   ^[dynamic]Splice,
	dropped:   tape.Facts,
	allocator: runtime.Allocator,
}

commit_markup :: proc(ov: ^Overlay, spec: ^Markup_Spec, opts := Options{}, allocator := context.allocator) -> (Commit_Result, Error) {
	cx := Markup_Cx{ov = ov, doc = ov.base if ov != nil else nil, src = ov.base.src if ov != nil && ov.base != nil else nil, spec = spec, opts = opts}
	tc := Text_Composer {
		target = spec.target, extra_clean = true, req_root = .Object, root_msg = "XML document root must be an object with one root element",
		validate = spec.validate, validate_data = spec.data, fast_emit = markup_fast_emit, struct_emit = markup_struct_emit, frag_check = markup_frag_check, user = &cx,
	}
	return run_text_commit(ov, &tc, opts, allocator)
}

@(private = "file")
markup_fast_emit :: proc(user: rawptr, ov: ^Overlay, doc: ^tape.Document, splices: ^[dynamic]Splice, scratch: runtime.Allocator) -> (ok: bool, err: Error) {
	cx := (^Markup_Cx)(user)
	cx.allocator, cx.splices = scratch, splices
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in dynamic_iter_next(&it) {
		if n.state == .Replaced && n.has_edits && n.base != tape.NO_NODE && doc.nodes[n.base].role == .Value {
			bn := doc.nodes[n.base]
			if cx.spec.is_void == nil && n.val.kind == .Raw && !(bn.n == 0 && bn.lo < u64(len(doc.src)) && doc.src[bn.lo] == '/') {
				push_splice(cx.splices, bn.lo, bn.lo + u64(bn.n), transmute([]u8)n.val.text, n.base, subtree_only = true) or_return
			} else {
				emit_markup_replace(cx, n.handle, n) or_return
			}
		}
	}
	return true, nil
}

@(private = "file")
markup_struct_emit :: proc(user: rawptr, ov: ^Overlay, doc: ^tape.Document, eol: string, splices: ^[dynamic]Splice, dropped: ^tape.Facts, scratch: runtime.Allocator) -> Error {
	_ = doc
	cx := (^Markup_Cx)(user)
	cx.allocator, cx.splices, cx.eol = scratch, splices, eol
	if ov.root != NO_HANDLE { compose_markup_walk(cx, ov.root) or_return }
	dropped^ = cx.dropped
	return nil
}

@(private = "file")
markup_frag_check :: proc(user: rawptr, out: []u8, recs: []Splice_Record, scratch: runtime.Allocator) -> (bool, Error) {
	_ = user
	_ = scratch
	for rec in recs {
		if !rec.subtree_only || rec.full_rewalk || !is_simple_xml_text(out[rec.dst_lo:rec.dst_hi]) { return true, nil }
	}
	return false, nil
}

@(private = "file")
xml_comment_valid :: proc "contextless" (body: string) -> bool {
	if len(body) > 0 && body[len(body) - 1] == '-' { return false }
	for i := 0; i + 1 < len(body); i += 1 {
		if body[i] == '-' && body[i + 1] == '-' { return false }
	}
	return true
}

@(private = "file")
is_text_run :: proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> bool {
	return v != tape.ROOT && v > 0 && tape.is_text_key(doc.nodes[v - 1])
}

@(private = "file")
markup_extent :: proc(cx: ^Markup_Cx, v: tape.Node_Index) -> (lead, lo, hi: u64) {
	if is_text_run(cx.doc, v) {
		n := cx.doc.nodes[v]
		return n.lo, n.lo, n.lo + u64(n.n)
	}
	el := cx.spec.element(cx.doc, v)
	lead = el.lo
	for lead > 0 && kernel.is_markup_ws(cx.src[lead - 1]) { lead -= 1 }
	if lead == 0 || cx.src[lead - 1] != '>' { lead = el.lo }
	return lead, el.lo, el.hi
}

@(private = "file")
append_xml_close_tag :: proc(out: ^[dynamic]u8, name: string) {
	append(out, "</")
	append(out, name)
	append(out, '>')
}

@(private = "file")
append_xml_attr :: proc(cx: ^Markup_Cx, name, val: string, out: ^[dynamic]u8, v := tape.NO_NODE, at := tape.NO_BYTE) -> Error {
	if len(name) == 0 || !cx.spec.is_name(transmute([]u8)name) {
		return refuse(.Bad_Name, "invalid XML attribute name", v, at)
	}
	append(out, ' ')
	append(out, name)
	append(out, `="`)
	cx.spec.spell_attr_val(cx.spec.data, val, '"', out) or_return
	append(out, '"')
	return nil
}

@(private = "file")
compose_markup_walk :: proc(cx: ^Markup_Cx, root: Handle) -> Error {
	stack := make([dynamic]Handle, 0, 32, cx.allocator)
	defer delete(stack)
	append(&stack, root) or_return
	for len(stack) > 0 {
		h := pop(&stack)
		n, ok := get_node(cx.ov, h)
		if !ok || !n.has_edits { continue }
		if n.state == .Replaced {
			emit_markup_replace(cx, h, n) or_return
			continue
		}
		if len(n.facts) > 0 { emit_markup_facts(cx, n) or_return }
		if n.state == .Container_Delta {
			emit_markup_container_delta(cx, h, n, &stack) or_return
			continue
		}
		if n.base != tape.NO_NODE && cx.doc.nodes[n.base].kind == .Object {
			c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, n.base, cx.allocator)
			if cerr != nil { return cerr }
			defer tape.destroy_children(&c)
			if p == .Found {
				array_replaced := make([dynamic]string, 0, 2, cx.allocator)
				defer delete(array_replaced)
				for {
					kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c, .Group)
					if np != .Found { break }
					is_txt := is_text_run(cx.doc, vn)
					ename := tape.TEXT_KEY if is_txt else string(tape.span_bytes(cx.doc, cx.doc.nodes[kn].lo, cx.doc.nodes[kn].n))
					if !is_txt && slice.contains(array_replaced[:], ename) {
						lead, _, hi := markup_extent(cx, vn)
						push_splice(cx.splices, lead, hi, base_node = n.base, full_rewalk = true) or_return
						continue
					}
					if ch, cn, ed := find_edited_child(cx.ov, vn); ed {
						if cn.state == .Replaced && cn.val.kind == .Array && !is_txt { append(&array_replaced, ename) }
						append(&stack, ch) or_return
					}
				}
			}
		}
	}
	return nil
}

@(private = "file")
emit_markup_replace :: proc(cx: ^Markup_Cx, h: Handle, n: ^Edit_Node) -> Error {
	if n.base == tape.NO_NODE { return nil }
	v := n.base
	if v == tape.ROOT {
		if n.val.kind != .Object || len(n.members) != 1 || node_kind(cx.ov, n.members[0].value) == .Array {
			return refuse(.Root_Shape, "XML document root must have exactly one root element", v)
		}
		m := n.members[0]
		if !cx.spec.is_name(transmute([]u8)m.key) { return refuse(.Bad_Name, "invalid XML root element name", v) }
		el := cx.spec.element(cx.doc, v)
		buf := make([dynamic]u8, 0, 64, cx.allocator)
		spell_xml_element(cx, m.key, m.value, &buf) or_return
		push_splice(cx.splices, el.lo, el.hi, buf[:], v, full_rewalk = true) or_return
		return nil
	}
	if is_text_run(cx.doc, v) {
		if n.val.kind == .Array || n.val.kind == .Object { return refuse(.Text_Markup, "cannot replace #text run with element or array", v) }
		node := cx.doc.nodes[v]
		buf := make([dynamic]u8, 0, 32, cx.allocator)
		cx.spec.spell_content(cx.spec.data, cx.ov, h, &buf) or_return
		push_splice(cx.splices, node.lo, node.lo + u64(node.n), buf[:], v, subtree_only = true) or_return
		return nil
	}

	el := cx.spec.element(cx.doc, v)
	tag_name := string(cx.src[el.lo + 1:el.name])
	if n.val.kind == .Array {
		if len(n.elems) == 0 { return refuse(.Empty_Markup_Array, "XML element cannot be replaced by an empty array", v) }
		for eh in n.elems {
			if node_kind(cx.ov, eh) == .Array { return refuse(.Nested_Markup_Array, "XML does not support nested arrays", v) }
		}
		emit_element_content_splice(cx, v, el, tag_name, n.elems[0]) or_return
		if len(n.elems) > 1 {
			lead, lo, hi := markup_extent(cx, v)
			sep := string(cx.src[lead:lo])
			more := make([dynamic]u8, 0, 64, cx.allocator)
			for eh in n.elems[1:] {
				append(&more, sep)
				spell_xml_element(cx, tag_name, eh, &more) or_return
			}
			push_splice(cx.splices, hi, hi, more[:], v, full_rewalk = true) or_return
		}
	} else {
		emit_element_content_splice(cx, v, el, tag_name, h) or_return
	}
	if len(n.facts) > 0 { emit_markup_facts(cx, n) or_return }
	return nil
}

@(private = "file")
emit_element_content_splice :: proc(cx: ^Markup_Cx, v: tape.Node_Index, el: Markup_Element, tag_name: string, val_h: Handle) -> Error {
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	cx.spec.spell_content(cx.spec.data, cx.ov, val_h, &buf) or_return
	if len(buf) > 0 && cx.spec.is_void != nil && cx.spec.is_void(tag_name) {
		return refuse(.Void_Content, "void element cannot hold content", v, el.lo)
	}
	if !el.empty {
		push_splice(cx.splices, el.open, el.close, buf[:], v, subtree_only = true) or_return
	} else if len(buf) > 0 {
		expanded := make([dynamic]u8, 0, len(buf) + len(tag_name) + 5, cx.allocator)
		append(&expanded, '>')
		append(&expanded, ..buf[:])
		append_xml_close_tag(&expanded, tag_name)
		push_splice(cx.splices, el.open, el.hi, expanded[:], v, subtree_only = true) or_return
	}
	return nil
}

@(private = "file")
spell_xml_comment_runs :: proc(cx: ^Markup_Cx, f: Fact_Override, out: ^[dynamic]u8, v := tape.NO_NODE, at := tape.NO_BYTE) -> Error {
	for body, i in f.values {
		if !xml_comment_valid(body) { return refuse(.Bad_Xml_Comment, "XML comment cannot contain '--' or end with '-'", v, at) }
		if i > 0 { append(out, cx.eol) }
		append(out, "<!--")
		if f.padded { append(out, ' ') }
		append(out, body)
		if f.padded { append(out, ' ') }
		append(out, "-->")
	}
	return nil
}

@(private = "file")
spell_node_xml_comments :: proc(cx: ^Markup_Cx, vn: ^Edit_Node, kind: tape.Fact_Kind, out: ^[dynamic]u8) -> Error {
	if vn == nil { return nil }
	for f in vn.facts {
		if !f.deleted && f.kind == kind && len(f.values) > 0 { spell_xml_comment_runs(cx, f, out) or_return }
	}
	return nil
}

@(private = "file")
spell_xml_element :: proc(cx: ^Markup_Cx, name: string, val_h: Handle, out: ^[dynamic]u8) -> Error {
	if !cx.spec.is_name(transmute([]u8)name) { return refuse(.Bad_Name, "invalid XML element name") }
	if node_kind(cx.ov, val_h) == .Array {
		elems := effective_elements(cx.ov, val_h, cx.allocator) or_return
		defer delete(elems, cx.allocator)
		if len(elems) == 0 { return refuse(.Empty_Markup_Array, "XML element cannot be replaced by an empty array") }
		for e in elems {
			eh := e.handle
			if eh == NO_HANDLE && e.base != tape.NO_NODE { eh = handle_for_base(cx.ov, e.base, val_h) or_return }
			if node_kind(cx.ov, eh) == .Array { return refuse(.Nested_Markup_Array, "XML does not support nested arrays") }
			spell_xml_element(cx, name, eh, out) or_return
		}
		return nil
	}
	content := make([dynamic]u8, 0, 64, cx.allocator)
	defer delete(content)
	cx.spec.spell_content(cx.spec.data, cx.ov, val_h, &content) or_return
	void_el := cx.spec.is_void != nil && cx.spec.is_void(name)
	if len(content) > 0 && void_el { return refuse(.Void_Content, "void element cannot hold content") }
	vn, _ := get_node(cx.ov, val_h)
	has_foot := false
	if vn != nil {
		for f in vn.facts {
			if !f.deleted && f.kind == .Comment_Foot && len(f.values) > 0 {
				if void_el { return refuse(.Fact_No_Place, "void element cannot hold a foot comment") }
				has_foot = true
			}
		}
	}
	spell_node_xml_comments(cx, vn, .Comment, out) or_return
	append(out, '<')
	append(out, name)
	if vn != nil {
		for f in vn.facts {
			if f.kind == .Attribute && !f.deleted && len(f.values) > 0 { append_xml_attr(cx, f.attr, f.values[0], out) or_return }
		}
	}
	if len(content) == 0 && !has_foot && (void_el || cx.spec.self_closing) {
		append(out, "/>" if cx.spec.self_closing else ">")
	} else {
		append(out, '>')
		append(out, ..content[:])
		if has_foot { spell_node_xml_comments(cx, vn, .Comment_Foot, out) or_return }
		append_xml_close_tag(out, name)
	}
	return spell_node_xml_comments(cx, vn, .Comment_Inline, out)
}

@(private = "file")
emit_markup_facts :: proc(cx: ^Markup_Cx, n: ^Edit_Node) -> Error {
	if n.base == tape.NO_NODE { return nil }
	v := n.base
	if is_text_run(cx.doc, v) {
		for f in n.facts { if !f.deleted { return refuse(.Fact_No_Place, "cannot attach fact to #text run", v) } }
		return nil
	}
	el := cx.spec.element(cx.doc, v)
	for f in n.facts {
		#partial switch f.kind {
		case .Attribute:
			if v == tape.ROOT { return refuse(.Fact_No_Place, "document root has no attributes (target the root element instead)", v) }
			emit_xml_attribute_fact(cx, v, el, f) or_return
		case .Comment, .Comment_Inline, .Comment_Foot:
			emit_xml_comment_fact(cx, v, el, f) or_return
		case:
			if !f.deleted { cx.dropped += {f.kind} }
		}
	}
	return nil
}

@(private = "file")
emit_xml_attribute_fact :: proc(cx: ^Markup_Cx, v: tape.Node_Index, el: Markup_Element, f: Fact_Override) -> Error {
	if len(f.attr) == 0 || !cx.spec.is_name(transmute([]u8)f.attr) {
		return refuse(.Bad_Name, "invalid XML attribute name", v, el.lo)
	}
	touches_xmlns := f.attr == "xmlns" || strings.has_prefix(f.attr, "xmlns:")
	found_fact: tape.Fact
	has_existing := false
	for bf in tape.facts_of(cx.doc, v) {
		if bf.kind != .Attribute || bf.lo < el.lo || bf.lo >= el.open { continue }
		kt, _ := cx.doc.format.attribute(cx.doc, bf)
		if string(tape.span_bytes(cx.doc, kt.lo, kt.n)) == f.attr {
			found_fact, has_existing = bf, true
			break
		}
	}
	if f.deleted || len(f.values) == 0 {
		if !has_existing { return nil }
		lo := found_fact.lo
		for lo > el.name && kernel.is_markup_ws(cx.src[lo - 1]) { lo -= 1 }
		push_splice(cx.splices, lo, found_fact.lo + u64(found_fact.n), base_node = v, full_rewalk = touches_xmlns) or_return
		return nil
	}
	if has_existing {
		_, vt := cx.doc.format.attribute(cx.doc, found_fact)
		quote := cx.src[vt.lo - 1] if (vt.lo > 0 && (cx.src[vt.lo - 1] == '"' || cx.src[vt.lo - 1] == '\'')) else u8('"')
		buf := make([dynamic]u8, 0, len(f.values[0]) + 4, cx.allocator)
		cx.spec.spell_attr_val(cx.spec.data, f.values[0], quote, &buf) or_return
		push_splice(cx.splices, vt.lo, vt.lo + u64(vt.n), buf[:], v, full_rewalk = touches_xmlns) or_return
		return nil
	}
	ins_at := el.open if el.empty else el.open - 1
	buf := make([dynamic]u8, 0, len(f.attr) + len(f.values[0]) + 6, cx.allocator)
	append_xml_attr(cx, f.attr, f.values[0], &buf, v, el.lo) or_return
	push_splice(cx.splices, ins_at, ins_at, buf[:], v, full_rewalk = touches_xmlns) or_return
	return nil
}

@(private = "file")
emit_xml_comment_fact :: proc(cx: ^Markup_Cx, v: tape.Node_Index, el: Markup_Element, f: Fact_Override) -> Error {
	existing := collect_base_facts(cx.doc, v, f.kind, cx.allocator)
	defer delete(existing)
	if f.deleted || len(f.values) == 0 {
		for bf in existing { push_splice(cx.splices, bf.lo, bf.lo + u64(bf.n), base_node = v, full_rewalk = true) or_return }
		return nil
	}
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	spell_xml_comment_runs(cx, f, &buf, v, el.lo) or_return
	if len(existing) > 0 {
		last := existing[len(existing) - 1]
		push_splice(cx.splices, existing[0].lo, last.lo + u64(last.n), buf[:], v, full_rewalk = true) or_return
		return nil
	}
	ins_at: u64
	#partial switch f.kind {
	case .Comment: ins_at = el.lo
	case .Comment_Inline: ins_at = el.hi
	case .Comment_Foot:
		if v == tape.ROOT {
			ins_at = el.hi
		} else {
			if el.empty { return refuse(.Fact_No_Place, "self-closing XML element cannot hold a foot comment", v, el.lo) }
			ins_at = el.close
		}
	}
	push_splice(cx.splices, ins_at, ins_at, buf[:], v, full_rewalk = true) or_return
	return nil
}

@(private = "file")
spell_markup_slot_inserts :: proc(cx: ^Markup_Cx, base_c: tape.Node_Index, d: ^Container_Delta, slot_ins: []int, sep: string, sep_before: bool) -> (out: []u8, err: Error) {
	b := make([dynamic]u8, 0, 64, cx.allocator)
	for ins_i in slot_ins {
		ins := d.inserted_members[ins_i]
		use_sep := ins.key != tape.TEXT_KEY && len(sep) > 0
		if use_sep && sep_before { append(&b, sep) }
		spell_markup_insert(cx, base_c, ins, &b) or_return
		if use_sep && !sep_before { append(&b, sep) }
	}
	return b[:], nil
}

@(private = "file")
emit_markup_container_delta :: proc(cx: ^Markup_Cx, h: Handle, n: ^Edit_Node, stack: ^[dynamic]Handle) -> Error {
	d := n.delta
	if d == nil { return nil }
	base_c := n.base
	Child_Item :: struct {
		kn, vn:                           tape.Node_Index,
		name:                             string,
		lead, lo, hi, head_lo, inline_hi: u64,
		deleted, is_text:                 bool,
	}
	items := make([dynamic]Child_Item, 0, 8, cx.allocator)
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
	if cerr != nil { return cerr }
	defer tape.destroy_children(&c)
	has_text := false
	if p == .Found {
		for {
			kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c, .Group)
			if np != .Found { break }
			is_txt := is_text_run(cx.doc, vn)
			if is_txt { has_text = true }
			name := tape.TEXT_KEY if is_txt else string(tape.span_bytes(cx.doc, cx.doc.nodes[kn].lo, cx.doc.nodes[kn].n))
			lead, lo, hi := markup_extent(cx, vn)
			head_lo, inline_hi := base_item_comment_bounds(cx.doc, vn, lo, hi)
			is_del, ren_to := base_delta_status(d, name, 0, true)
			if !is_del && len(ren_to) > 0 {
				if is_txt || !cx.spec.is_name(transmute([]u8)ren_to) { return refuse(.Bad_Name, "cannot rename #text or use invalid XML name", kn) }
				el := cx.spec.element(cx.doc, vn)
				push_splice(cx.splices, el.lo + 1, el.name, slice.clone(transmute([]u8)ren_to, cx.allocator), base_c, full_rewalk = true) or_return
				if el.end_tag {
					push_splice(cx.splices, el.close + 2, el.close + 1 + el.name - el.lo, slice.clone(transmute([]u8)ren_to, cx.allocator), base_c, full_rewalk = true) or_return
				}
			}
			append(&items, Child_Item{kn, vn, name, lead, lo, hi, head_lo, inline_hi, is_del, is_txt})
		}
	}

	if len(d.order) > 0 {
		deleted_flags := make_deleted_flags(items[:], cx.allocator) or_return
		defer delete(deleted_flags, cx.allocator)
		validate_order(d.order, deleted_flags, len(d.inserted_members), cx.allocator) or_return
		if has_text {
			if !cx.opts.reflow {
				return refuse(.Layout_Reflow_Needed, "cannot reorder XML element containing #text runs", base_c, cx.spec.element(cx.doc, base_c).lo)
			}
			return emit_markup_reflow(cx, h, base_c)
		}
	}

	array_replaced := make([dynamic]string, 0, 2, cx.allocator)
	for &it in items {
		if it.deleted { continue }
		if !it.is_text && slice.contains(array_replaced[:], it.name) {
			it.deleted = true
			continue
		}
		if ch, cn, ed := find_edited_child(cx.ov, it.vn); ed {
			if cn.state == .Replaced && cn.val.kind == .Array && !it.is_text { append(&array_replaced, it.name) }
			append(stack, ch)
		}
	}

	if len(d.order) > 0 {
		places := make([dynamic]int, 0, len(items), cx.allocator)
		for it, i in items { if !it.deleted { append(&places, i) } }
		if len(places) > 0 {
			last := items[places[len(places) - 1]]
			sep := string(cx.src[last.lead:last.lo])
			moves := make([dynamic]Move, 0, len(d.order) * 2, cx.allocator)
			for raw, pos in d.order {
				k := int(raw)
				if pos > 0 {
					if pos < len(places) {
						append(&moves, Move{lo = items[places[pos - 1]].inline_hi, hi = items[places[pos]].head_lo})
					} else if len(sep) > 0 {
						push_move_str(&moves, sep, cx.allocator) or_return
					}
				}
				if k < len(items) {
					append(&moves, Move{lo = items[k].head_lo, hi = items[k].inline_hi})
				} else {
					ins := d.inserted_members[k - len(items)]
					b := make([dynamic]u8, 0, 64, cx.allocator)
					spell_xml_element(cx, ins.key, ins.value, &b) or_return
					append(&moves, Move{text = b[:], written = true})
				}
			}
			push_splice(cx.splices, items[places[0]].head_lo, last.inline_hi, base_node = base_c, full_rewalk = true, moves = moves[:]) or_return
			return nil
		}
	}

	parent_el := cx.spec.element(cx.doc, base_c)
	if len(items) == 0 && len(d.inserted_members) > 0 && parent_el.empty {
		b := make([dynamic]u8, 0, 64, cx.allocator)
		append(&b, '>')
		for ins in d.inserted_members { spell_markup_insert(cx, base_c, ins, &b) or_return }
		append_xml_close_tag(&b, string(cx.src[parent_el.lo + 1:parent_el.name]))
		push_splice(cx.splices, parent_el.open, parent_el.hi, b[:], base_c, full_rewalk = true) or_return
		return nil
	}

	slots := make([][dynamic]int, len(items) + 1, cx.allocator)
	for ins, i in d.inserted_members {
		slot := ins.at if (ins.at >= 0 && ins.at < len(items)) else len(items)
		if slots[slot].allocator.procedure == nil { slots[slot] = make([dynamic]int, 0, 2, cx.allocator) }
		append(&slots[slot], i)
	}

	sep := string(cx.src[items[len(items) - 1].lead:items[len(items) - 1].lo]) if len(items) > 0 else ""
	surviving := 0
	for it, k in items {
		slot_ins := slots[k]
		if it.deleted {
			txt: []u8
			if len(slot_ins) > 0 { txt = spell_markup_slot_inserts(cx, base_c, d, slot_ins[:], string(cx.src[it.lead:it.lo]), true) or_return }
			push_splice(cx.splices, it.lead, it.hi, txt, base_c, full_rewalk = true) or_return
		} else {
			surviving += 1
			if len(slot_ins) > 0 {
				txt := spell_markup_slot_inserts(cx, base_c, d, slot_ins[:], sep, false) or_return
				push_splice(cx.splices, it.lo, it.lo, txt, base_c, full_rewalk = true) or_return
			}
		}
	}

	if surviving == 0 && len(d.inserted_members) == 0 && base_c != tape.ROOT && len(items) > 0 {
		last_hi := items[len(items) - 1].hi
		if last_hi < parent_el.close {
			all_ws := true
			for q := last_hi; q < parent_el.close; q += 1 {
				if !kernel.is_markup_ws(cx.src[q]) {
					all_ws = false
					break
				}
			}
			if all_ws { push_splice(cx.splices, last_hi, parent_el.close, base_node = base_c, full_rewalk = true) or_return }
		}
	}

	if tail_ins := slots[len(items)]; len(tail_ins) > 0 {
		pos := items[len(items) - 1].hi if len(items) > 0 else parent_el.close
		txt := spell_markup_slot_inserts(cx, base_c, d, tail_ins[:], sep if len(items) > 0 else "", true) or_return
		push_splice(cx.splices, pos, pos, txt, base_c, full_rewalk = true) or_return
	}
	return nil
}

@(private = "file")
spell_markup_insert :: proc(cx: ^Markup_Cx, base_c: tape.Node_Index, ins: Member_Insert, out: ^[dynamic]u8) -> Error {
	if ins.key == tape.TEXT_KEY {
		if node_kind(cx.ov, ins.value) == .Array || node_kind(cx.ov, ins.value) == .Object {
			return refuse(.Text_Markup, "cannot insert element or array as #text", base_c)
		}
		return cx.spec.spell_content(cx.spec.data, cx.ov, ins.value, out)
	}
	return spell_xml_element(cx, ins.key, ins.value, out)
}

@(private = "file")
emit_markup_reflow :: proc(cx: ^Markup_Cx, h: Handle, base_c: tape.Node_Index) -> Error {
	el := cx.spec.element(cx.doc, base_c)
	drop_splices_in_range(cx.splices, el.open, el.close, cx.allocator, keep_at_hi_node = base_c)
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	cx.spec.spell_content(cx.spec.data, cx.ov, h, &buf) or_return
	push_splice(cx.splices, el.open, el.close, buf[:], base_c, full_rewalk = true, rewritten = true) or_return
	return nil
}
