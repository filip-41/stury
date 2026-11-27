package html

import "base:runtime"
import "core:container/handle_map"
import "core:container/xar"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"

// Byte-preserving HTML5 editing over `edit.Overlay` and `edit.commit_markup`.

Overlay :: edit.Overlay
Handle :: edit.Handle
Edit_Value :: edit.Edit_Value
Edit_Options :: edit.Options
Edit_Error :: edit.Error
Commit_Result :: edit.Commit_Result

edit_init :: proc(ov: ^Overlay, doc: ^tape.Document, allocator := context.allocator) -> Edit_Error {
	return edit.init(ov, doc, allocator)
}

edit_destroy :: proc(ov: ^Overlay) { edit.destroy(ov) }

@(private = "file")
Edit_Build_Ctx :: struct { spec: Spec, opts: Options }

@(private = "file")
edit_build_opts :: proc "contextless" (base: ^tape.Document, ov: ^Overlay = nil, min_extra := 0) -> Options {
	opts: Options
	need := u64(min_extra) + 64
	if base != nil {
		if doc_inferred(base) { opts.format = Xml_Options{infer = true} }
		need += u64(len(base.nodes))
	}
	if ov != nil { need += u64(xar.len(ov.nodes.items)) }
	if need > tape.DEFAULT_DEPTH { opts.budget.depth = u32(min(need, u64(max(u32)))) }
	return opts
}

commit :: proc(ov: ^Overlay, opts := Edit_Options{}, allocator := context.allocator) -> (res: Commit_Result, err: Edit_Error) {
	if ov == nil || ov.base == nil { return {}, edit.refuse(.No_Document, "commit requires an initialized overlay") }
	if opts.target != nil && opts.target != as(.Html) && opts.target != as(.Fragment) { return {}, tape.Bad_Option{"target"} }
	spec := spec_of_target(ov.base, opts.target)
	eff_opts := opts
	eff_opts.target = as(spec)

	pre_check_overlay(ov) or_return
	eb := Edit_Build_Ctx{spec = spec, opts = edit_build_opts(ov.base, ov)}

	if ov.root != edit.NO_HANDLE {
		if rn, ok := edit.get_node(ov, ov.root); ok && rn.state == .Replaced && rn.val.kind == .Raw {
			return commit_raw_root(ov, rn, spec, eb.opts, allocator)
		}
	}

	mspec := edit.Markup_Spec {
		target = as(spec), self_closing = false, element = html_element_of, is_name = html_is_markup_name_bytes,
		is_void = is_void_ci, spell_content = html_spell_content, spell_attr_val = html_spell_attr_val,
		validate = html_edit_validate_doc, data = &eb,
	}

	read_ons := collect_read_ons(ov, ov.allocator) or_return
	defer destroy_read_ons(&read_ons, ov.allocator)

	saved_cases := apply_delta_key_cases(ov, ov.allocator)
	defer restore_delta_key_cases(ov, &saved_cases)

	if len(read_ons) == 0 {
		res = edit.commit_markup(ov, &mspec, eff_opts, allocator) or_return
		restore_delta_key_cases(ov, &saved_cases)
		if rerr := reread_verify(ov, spec, eb.opts, res.bytes, allocator, false); rerr != nil {
			edit.destroy_commit_result(&res)
			return {}, rerr
		}
		return res, nil
	}

	for keep in ([?]bool{true, false}) {
		if keep && !apply_keep_trim(read_ons[:]) { continue }
		res, err = edit.commit_markup(ov, &mspec, eff_opts, allocator)
		if keep { restore_keep_trim(read_ons[:]) }
		if err != nil { return {}, err }
		if !keep {
			if cerr := apply_read_on_cuts(&res, read_ons[:], allocator); cerr != nil {
				edit.destroy_commit_result(&res)
				return {}, cerr
			}
		}
		restore_delta_key_cases(ov, &saved_cases)
		if rerr := reread_verify(ov, spec, eb.opts, res.bytes, allocator, true); rerr != nil {
			edit.destroy_commit_result(&res)
			if keep { saved_cases = apply_delta_key_cases(ov, ov.allocator); continue }
			return {}, rerr
		}
		return res, nil
	}
	return {}, err
}

commit_document :: proc(ov: ^Overlay, opts := Edit_Options{}, allocator := context.allocator) -> (doc: tape.Document, res: Commit_Result, err: Edit_Error) {
	res = commit(ov, opts, allocator) or_return
	defer if err != nil { edit.destroy_commit_result(&res) }
	spec := spec_of_target(ov.base, opts.target)
	eff_opts := opts
	eff_opts.target = as(spec)
	eb := Edit_Build_Ctx{spec = spec, opts = edit_build_opts(ov.base, ov, len(res.bytes))}
	doc = edit.splice_document(ov.base, &res, eff_opts, html_walk_fragment_cb, &eb, html_full_build_cb, &eb, allocator) or_return
	return doc, res, nil
}

walk_fragment :: proc(src: []u8, range: edit.Byte_Range, ctx: edit.Fragment_Context, spec := Spec.Fragment, allocator := context.allocator) -> (edit.Fragment_Tape, tape.Error) {
	return walk_fragment_with_opts(src, range, ctx, spec, edit_build_opts(ctx.base, nil, int(range.hi - range.lo)), allocator)
}

@(private = "file")
walk_fragment_with_opts :: proc(src: []u8, range: edit.Byte_Range, ctx: edit.Fragment_Context, spec: Spec, opts: Options, allocator: runtime.Allocator) -> (ft: edit.Fragment_Tape, err: tape.Error) {
	if ctx.base != nil && ctx.base.ext != nil {
		full := build(src, spec, opts, allocator) or_return
		return edit.Fragment_Tape{full_doc = full, allocator = allocator}, nil
	}
	el_name, el_ns, el_owned := "div", Namespace.Html, false
	if ctx.base != nil && ctx.base_node != tape.ROOT && int(ctx.base_node) > 0 && int(ctx.base_node) < len(ctx.base.nodes) {
		el_name = scalar_name_of(ctx.base, ctx.base_node - 1, allocator)
		el_ns = key_namespace(ctx.base.nodes[ctx.base_node - 1])
		el_owned = true
	}
	defer if el_owned { delete(el_name, allocator) }
	d := build_fragment(src[range.lo:range.hi], {context_name = el_name, context_namespace = el_ns}, opts, allocator) or_return
	out_ft, merr := edit.shift_fragment_tape(&d, range.lo, 1, 0, allocator)
	if merr != nil { return {}, merr }
	return out_ft, nil
}

@(private = "file")
spec_of_target :: #force_inline proc "contextless" (base: ^tape.Document, target: ^tape.Format) -> Spec {
	if target == as(.Fragment) { return .Fragment }
	if target == as(.Html) { return .Html }
	return .Fragment if base != nil && base.format == as(.Fragment) else .Html
}

@(private = "file")
html_walk_fragment_cb :: proc(data: rawptr, src: []u8, range: edit.Byte_Range, ctx: edit.Fragment_Context, allocator: runtime.Allocator) -> (edit.Fragment_Tape, tape.Error) {
	eb := (^Edit_Build_Ctx)(data)
	return walk_fragment_with_opts(src, range, ctx, eb.spec, eb.opts, allocator)
}

@(private = "file")
html_full_build_cb :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	eb := (^Edit_Build_Ctx)(data)
	return build(src, eb.spec, eb.opts, allocator)
}

@(private = "file")
html_edit_validate_doc :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error {
	eb := (^Edit_Build_Ctx)(data)
	d, err := build(src, eb.spec, eb.opts, allocator)
	if err == nil { tape.destroy(&d) }
	return err
}

@(private = "file")
commit_raw_root :: proc(ov: ^Overlay, rn: ^edit.Edit_Node, spec: Spec, build_opts: Options, allocator: runtime.Allocator) -> (Commit_Result, Edit_Error) {
	el := html_element_of(ov.base, tape.ROOT)
	out_len := len(ov.base.src) - int(el.hi - el.lo) + len(rn.val.text)
	bytes, err := runtime.mem_alloc_non_zeroed(out_len, 1, allocator)
	if err != nil { return {}, err }
	w := copy(bytes, ov.base.src[:el.lo])
	w += copy(bytes[w:], rn.val.text)
	copy(bytes[w:], ov.base.src[el.hi:])
	splices, serr := make([]edit.Splice_Record, 1, allocator)
	if serr != nil { delete(bytes, allocator); return {}, serr }
	splices[0] = {base_node = tape.ROOT, src_lo = el.lo, src_hi = el.hi, dst_lo = el.lo, dst_hi = el.lo + u64(len(rn.val.text)), subtree_only = true, full_rewalk = true}
	if rerr := reread_verify(ov, spec, build_opts, bytes, allocator, true); rerr != nil {
		delete(bytes, allocator); delete(splices, allocator)
		return {}, rerr
	}
	return Commit_Result{bytes = bytes, splices = splices, allocator = allocator}, nil
}

@(private = "file")
pre_check_overlay :: proc(ov: ^Overlay) -> Edit_Error {
	doc := ov.base
	if ov.has_structural && ov.unlinked_parents { edit.ensure_linked(ov) or_return }
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in html_iter_next(&it) {
		if !n.has_edits { continue }
		v, bv := n.base, edit.node_base_container(n)
		if v != tape.NO_NODE && (n.state == .Replaced || len(n.facts) > 0) {
			if is_constructed_node(doc, v) { return edit.refuse(.Invalid_Result, "cannot edit node implied, moved or copied by tree construction", v) }
			if is_split_text(doc, v) { return edit.refuse(.Invalid_Result, "cannot edit text split across tags", v) }
		}
		if bv != tape.NO_NODE && n.delta != nil { check_delta_edits(doc, bv, n.delta) or_return }
		void_base := false
		if bv != tape.NO_NODE && bv != tape.ROOT && int(bv) < len(doc.nodes) && key_namespace(doc.nodes[bv - 1]) == .Html {
			vbuf: [64]u8 = ---
			vname, v_owned := key_name_temp(doc, bv - 1, vbuf[:], ov.allocator)
			void_base = is_void_ci(vname)
			if v_owned { delete(vname, ov.allocator) }
		}
		for f in n.facts {
			if f.deleted { continue }
			err_node := bv if bv != tape.NO_NODE else v
			#partial switch f.kind {
			case .Comment, .Comment_Inline, .Comment_Foot:
				if f.kind == .Comment_Foot && void_base { return edit.refuse(.Fact_No_Place, "void HTML element cannot hold foot comment", err_node) }
				for b in f.values { if !holds_comment(b) { return edit.refuse(.Fact_No_Place, "invalid HTML comment body", err_node) } }
			case .Attribute:
				if !html_attr_name_ok(doc, bv, f.attr) { return edit.refuse(.Bad_Name, "invalid HTML attribute name", err_node) }
			}
		}
		if n.state == .Replaced { check_replaced_subtree(ov, n) or_return }
	}
	return nil
}

@(private = "file")
Child_Pair :: struct { k, v: tape.Node_Index }

@(private = "file")
check_delta_edits :: proc(doc: ^tape.Document, container: tape.Node_Index, d: ^edit.Container_Delta) -> Edit_Error {
	children := collect_children_pairs(doc, container, doc.allocator)
	defer delete(children, doc.allocator)
	if len(d.order) > 0 {
		for ch in children {
			if is_constructed_node(doc, ch.v) { return edit.refuse(.Invalid_Result, "cannot reorder container with constructed element", container) }
			if tape.is_text_key(doc.nodes[ch.k]) { return edit.refuse(.Layout_Reflow_Needed, "cannot reorder container holding #text", container) }
		}
	}
	for ins in d.inserted_members {
		if ins.key != tape.TEXT_KEY && !is_html_name(ins.key) { return edit.refuse(.Bad_Name, "invalid HTML element name", container) }
		target := container if len(children) == 0 else children[ins.at if ins.at >= 0 && ins.at < len(children) else len(children) - 1].v
		if is_constructed_node(doc, target) { return edit.refuse(.Invalid_Result, "cannot insert beside constructed element", container) }
	}
	buf: [256]u8 = ---
	check_match :: proc(doc: ^tape.Document, children: []Child_Pair, want: string, buf: []u8, msg: string) -> Edit_Error {
		for ch in children {
			ck, owned := key_name_temp(doc, ch.k, buf, doc.allocator)
			matched := ck == want
			if owned { delete(ck, doc.allocator) }
			if matched && is_constructed_node(doc, ch.v) { return edit.refuse(.Invalid_Result, msg, ch.v) }
		}
		return nil
	}
	for dk in d.deleted_keys { check_match(doc, children, dk, buf[:], "cannot delete constructed element") or_return }
	for r in d.renamed_members {
		if r.new_key != tape.TEXT_KEY && !is_html_name(r.new_key) { return edit.refuse(.Bad_Name, "invalid HTML element name", container) }
		check_match(doc, children, r.old_key, buf[:], "cannot rename constructed element") or_return
	}
	return nil
}

@(private = "file")
check_replaced_subtree :: proc(ov: ^Overlay, root_n: ^edit.Edit_Node) -> Edit_Error {
	stack := make([dynamic]Handle, 0, 8, ov.allocator)
	defer delete(stack)
	append(&stack, root_n.handle)
	for len(stack) > 0 {
		n, ok := edit.get_node(ov, pop(&stack))
		if !ok || n.state != .Replaced { continue }
		if n.val.kind == .Object {
			for m in n.members {
				if m.key != tape.TEXT_KEY && !is_html_name(m.key) { return edit.refuse(.Bad_Name, "invalid HTML element name", n.base) }
				append(&stack, m.value)
			}
		} else if n.val.kind == .Array {
			append(&stack, ..n.elems[:])
		}
	}
	return nil
}

@(private = "file")
is_constructed_node :: proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> bool {
	if v == tape.ROOT || v == tape.NO_NODE || int(v) >= len(doc.nodes) { return false }
	k, n := doc.nodes[v - 1], doc.nodes[v]
	return (k.role == .Key && key_is_frozen(k)) || (n.kind == .Plain && n.spelling & TEXT_FROZEN != 0)
}

@(private = "file")
is_split_text :: proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> bool {
	if v == tape.NO_NODE || int(v) >= len(doc.nodes) { return false }
	n := doc.nodes[v]
	if n.kind != .Plain || n.spelling & TEXT_PIECES == 0 || doc.ext == nil { return false }
	b, head, entry, ok := find_text_entry(&doc.ext.format, n.lo)
	if !ok { return false }
	for i in 1 ..< entry.count {
		prev := load_piece(b, head, entry.first + i - 1)
		cur := load_piece(b, head, entry.first + i)
		end := prev.lo + u64(prev.n)
		hi := max(cur.lo, end)
		if hi > end && hi <= u64(len(doc.src)) {
			gap := doc.src[end:hi]
			for c, k in gap {
				if c == '<' && k + 1 < len(gap) && ((gap[k + 1] | 0x20) - 'a' < 26) { return true }
			}
		}
	}
	return false
}

@(private = "file")
is_void_ci :: proc "contextless" (name: string) -> bool {
	if len(name) < 2 || len(name) > 8 { return false }
	lower: [8]u8 = ---
	for i in 0 ..< len(name) { c := name[i]; lower[i] = c | 0x20 if c - 'A' < 26 else c }
	return is_void_name(string(lower[:len(name)]))
}

@(private = "file")
html_is_markup_name_bytes :: proc "contextless" (name: []u8) -> bool {
	if len(name) == 0 { return false }
	for c in name {
		if is_space(c) || c == '/' || c == '>' || c == '=' || c == '"' || c == '\'' || c == '<' || c == 0 || c < 0x20 { return false }
	}
	return true
}

@(private = "file")
html_attr_name_ok :: proc(doc: ^tape.Document, v: tape.Node_Index, attr: string) -> bool {
	if len(attr) == 0 || !html_is_markup_name_bytes(transmute([]u8)attr) { return false }
	if v != tape.NO_NODE && int(v) < len(doc.nodes) {
		for bf in tape.facts_of(doc, v) {
			if bf.kind == .Attribute {
				kt, _ := attribute(doc, bf)
				if string(tape.span_bytes(doc, kt.lo, kt.n)) == attr { return true }
			}
		}
		if v != tape.ROOT && doc.nodes[v - 1].role == .Key {
			if ns := key_namespace(doc.nodes[v - 1]); ns != .Html {
				fi := foreign_of(raw_data(attr), u32(len(attr)))
				if fi > 0 && FOREIGN_NAMES[fi].name == attr {
					kinds := FOREIGN_NAMES[fi].kinds
					if .Foreign_Attribute in kinds || (.Svg_Attribute in kinds && ns == .Svg) || (.Math_Attribute in kinds && ns == .Math) { return true }
				}
			}
		}
	}
	for c in transmute([]u8)attr { if 'A' <= c && c <= 'Z' { return false } }
	return true
}

@(private = "file")
spell_html_escaped :: proc(s: string, quote: u8, out: ^[dynamic]u8) -> edit.Error {
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c == '&':                                          append(out, "&amp;")
		case c == 0xC2 && i + 1 < len(s) && s[i + 1] == 0xA0:  append(out, "&nbsp;"); i += 1
		case quote == 0 && c == '<':                            append(out, "&lt;")
		case quote == 0 && c == '>':                            append(out, "&gt;")
		case quote == '"' && c == '"':                          append(out, "&quot;")
		case quote == '\'' && c == '\'':                        append(out, "&#39;")
		case:                                                   append(out, c)
		}
	}
	return nil
}

@(private = "file")
html_spell_attr_val :: proc(_: rawptr, val: string, quote: u8, out: ^[dynamic]u8) -> edit.Error {
	return spell_html_escaped(val, quote, out)
}

@(private = "file")
spell_scalar_text_into :: proc(txt, ename: string, enclosing_raw, enclosing_keeps: bool, out: ^[dynamic]u8) -> edit.Error {
	if enclosing_keeps && strings.has_prefix(txt, "\n") { append(out, '\n') }
	if !enclosing_raw || ename == "title" || ename == "textarea" { return spell_html_escaped(txt, 0, out) }
	append(out, txt)
	return nil
}

@(private = "file")
html_spell_content :: proc(data: rawptr, ov: ^Overlay, h: Handle, out: ^[dynamic]u8) -> edit.Error {
	eb := (^Edit_Build_Ctx)(data)
	build_opts := eb.opts if eb != nil else Options{}
	if h == edit.NO_HANDLE { return nil }
	n, has_n := edit.get_node(ov, h)
	if !has_n || edit.node_kind(ov, h) == .Null { return nil }

	ename, ename_owned, enclosing_ns := "", false, Namespace.Html
	enclosing_raw, enclosing_keeps := false, false
	ebuf: [128]u8 = ---
	if n.base != tape.NO_NODE && n.base != tape.ROOT && int(n.base) < len(ov.base.nodes) {
		ename, ename_owned = key_name_temp(ov.base, n.base - 1, ebuf[:], ov.allocator)
		enclosing_ns = key_namespace(ov.base.nodes[n.base - 1])
		enclosing_raw = enclosing_ns == .Html && (is_raw_name(ename) || ename == "title" || ename == "textarea")
		enclosing_keeps = enclosing_ns == .Html && keeps_space_name(ename)
	}
	defer if ename_owned { delete(ename, ov.allocator) }

	if n.state == .Replaced {
		if n.val.kind == .Raw {
			if enclosing_raw && strings.contains_any(n.val.text, "<&" if is_raw_name(ename) else "<") {
				return edit.refuse(.Text_Markup, "rawtext element cannot contain markup", n.base)
			}
			append(out, n.val.text)
			return nil
		}
		if n.val.kind < .Array {
			buf: [64]u8 = ---
			return spell_scalar_text_into(scalar_edit_val_str(&n.val, buf[:]), ename, enclosing_raw, enclosing_keeps, out)
		}
		if n.val.kind == .Base_Ref {
			bn := n.val.base_ref
			if bn != tape.NO_NODE && int(bn) < len(ov.base.nodes) && ov.base.nodes[bn].kind < .Array {
				sc := make([dynamic]u8, 0, 64, ov.allocator)
				defer delete(sc)
				return spell_scalar_text_into(scalar_string(ov.base, bn, &sc), ename, enclosing_raw, enclosing_keeps, out)
			}
		}
	}

	tmp_doc := edit.materialize_subtree(ov, h, tape.NO_NODE, {wrap_key = "_", xml_attrs = true, skip_root_attrs = true, target_format = as(.Html)}, ov.allocator) or_return
	defer tape.destroy(&tmp_doc)
	for nd, ni in tmp_doc.nodes {
		if ni <= 1 || nd.role != .Key { continue }
		kname := tape.span_bytes(&tmp_doc, nd.lo, nd.n)
		if string(kname) != tape.TEXT_KEY && !is_html_name(string(kname)) {
			fi := foreign_of(raw_data(kname), u32(len(kname)))
			if !(fi > 0 && FOREIGN_NAMES[fi].name == string(kname)) { return edit.refuse(.Bad_Name, "invalid HTML element name", n.base) }
		}
	}

	encoded, werr := write_unverified(&tmp_doc, {}, ov.allocator)
	if werr != nil {
		#partial switch e in werr {
		case runtime.Allocator_Error: return e
		case tape.Bad_Option:        return e
		}
		return edit.refuse(.Unspellable_Value, "value cannot be serialized as HTML")
	}
	defer delete(encoded, ov.allocator)

	s := string(encoded)
	if strings.has_prefix(s, "<_>") && strings.has_suffix(s, "</_>") { s = s[3 : len(s) - 4] }
	if ename != "" && len(s) > 0 {
		frag, ferr := build_fragment(transmute([]u8)s, {context_name = ename, context_namespace = enclosing_ns}, build_opts, ov.allocator)
		if ferr != nil { return edit.refuse(.Unspellable_Value, "value cannot read back in target HTML element", n.base) }
		defer tape.destroy(&frag)
		again, aerr := write_unverified(&frag, {}, ov.allocator)
		if aerr != nil { return edit.refuse(.Unspellable_Value, "value does not round-trip in target HTML element", n.base) }
		defer delete(again, ov.allocator)
		if string(again) != s { return edit.refuse(.Unspellable_Value, "value reads back as different HTML elements in target context", n.base) }
	}
	append(out, s)
	return nil
}

@(private = "file")
scalar_edit_val_str :: proc(v: ^Edit_Value, buf: []u8) -> string {
	#partial switch v.kind {
	case .String, .Number_Text, .Raw: return v.text
	case .True:                       return "true"
	case .False:                      return "false"
	case .Int:                        return strconv.write_int(buf, v.i, 10)
	case .Uint:                       return strconv.write_uint(buf, v.u, 10)
	case .Float:                      return strconv.write_float(buf, v.f, 'g', -1, 64, {})
	}
	return ""
}

@(private = "file")
leaf_element_of :: proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> (e: edit.Markup_Element) {
	src := doc.src
	k, n := doc.nodes[v - 1], doc.nodes[v]
	if k.n == 0 {
		e.lo, e.name, e.open = k.lo, k.lo, k.lo
	} else {
		e.lo, e.name = k.lo - 1, k.lo + u64(k.n)
		e.open = html_tag_end(src, e.lo)
	}
	c := max(e.open, n.lo + u64(n.n))
	if n.kind == .Plain && n.spelling & TEXT_PIECES != 0 { c = max(e.open, min(c, text_before_read_on(doc, n.lo))) }
	for f in tape.facts_of(doc, v) {
		if (f.kind == .Comment || f.kind == .Instruction) && f.lo >= e.open { c = max(c, f.lo + u64(f.n)) }
	}
	e.close, e.hi = c, c
	if k.n > 0 && end_tag_matches_key(doc, k, c) {
		e.hi, e.end_tag = html_tag_end(src, c), true
	} else if k.n > 0 && key_namespace(k) != .Html && c == e.open && e.open >= 2 && src[e.open - 2] == '/' {
		e.open, e.close, e.empty = e.open - 2, e.open - 2, true
	}
	return
}

@(private = "file")
html_element_of :: proc "contextless" (doc: ^tape.Document, v_in: tape.Node_Index) -> (e: edit.Markup_Element) {
	src, v := doc.src, v_in
	if v == tape.ROOT {
		if doc.format == as(.Fragment) { e.close, e.hi = u64(len(src)), u64(len(src)); return }
		if len(doc.nodes) <= 2 { return {} }
		v = tape.ROOT + 2
	}
	k, n := doc.nodes[v - 1], doc.nodes[v]
	if n.kind != .Object { return leaf_element_of(doc, v) }
	if k.n == 0 {
		e.lo, e.name, e.open = k.lo, k.lo, k.lo
	} else {
		e.lo, e.name = k.lo - 1, k.lo + u64(k.n)
		e.open = html_tag_end(src, e.lo)
	}
	e.hi, _ = close_end(doc, v)
	e.close = e.hi
	last := tape.NO_NODE
	for ck, end := v + 1, tape.node_after(doc, v); ck < end; {
		cv := tape.node_after(doc, ck)
		last, ck = cv, tape.node_after(doc, cv)
	}
	after := e.open
	if last != tape.NO_NODE {
		if doc.nodes[last].kind == .Object {
			after, _ = close_end(doc, last)
		} else if tape.is_text_key(doc.nodes[last - 1]) {
			ln := doc.nodes[last]
			after = ln.lo + u64(ln.n)
			if ln.kind == .Plain && ln.spelling & TEXT_PIECES != 0 { after = min(after, text_before_read_on(doc, ln.lo)) }
		} else {
			after = leaf_element_of(doc, last).hi
		}
	}
	for lt := e.hi; lt > after; lt -= 1 {
		if src[lt - 1] == '<' {
			if end_tag_matches_key(doc, k, lt - 1) && html_tag_end(src, lt - 1) == e.hi { e.close, e.end_tag = lt - 1, true }
			break
		}
	}
	return
}

@(private = "file")
text_before_read_on :: proc "contextless" (doc: ^tape.Document, lo: u64) -> u64 {
	if doc.ext == nil { return lo }
	b, head, entry, ok := find_text_entry(&doc.ext.format, lo)
	if !ok || entry.count == 0 { return lo }
	k := entry.count - 1
	for k > 0 {
		cur, prev := load_piece(b, head, entry.first + k), load_piece(b, head, entry.first + k - 1)
		if cur.lo <= prev.lo + u64(prev.n) { break }
		all_ws := true
		if cur.lo + u64(cur.n) <= u64(len(doc.src)) {
			for c in doc.src[cur.lo:][:cur.n] { if !is_space(c) { all_ws = false; break } }
		}
		if !all_ws { return cur.lo + u64(cur.n) }
		k -= 1
	}
	last := load_piece(b, head, entry.first + k)
	return last.lo + u64(last.n)
}

@(private = "file")
html_tag_end :: proc "contextless" (src: []u8, lo: u64) -> u64 {
	quote: u8
	for i := lo + 1; i < u64(len(src)); i += 1 {
		c := src[i]
		if quote != 0 { if c == quote { quote = 0 }; continue }
		if c == '"' || c == '\'' { quote = c } else if c == '>' { return i + 1 }
	}
	return u64(len(src))
}

@(private = "file")
end_tag_at :: proc "contextless" (src: []u8, at: u64, name: string) -> bool {
	lo, hi := at + 2, at + 2 + u64(len(name))
	if hi >= u64(len(src)) || src[at] != '<' || src[at + 1] != '/' || !fold_name_equal(src[lo:hi], name) { return false }
	return is_space(src[hi]) || src[hi] == '/' || src[hi] == '>'
}

@(private = "file")
end_tag_matches_key :: proc "contextless" (doc: ^tape.Document, k: tape.Token, at: u64) -> bool {
	src := doc.src
	if at + 2 >= u64(len(src)) || src[at] != '<' || src[at + 1] != '/' { return false }
	if fx := table_key_text(src, k); len(fx) > 0 { return end_tag_at(src, at, fx) }
	if k.n == 0 { return false }
	if k.spelling & tape.SPELLING_DECODE == 0 && .Held not_in doc.flags { return end_tag_at(src, at, string(src[k.lo:][:k.n])) }
	buf: [256]u8 = ---
	if s, ok := tape.node_text(doc, k, buf[:]); ok { return end_tag_at(src, at, s) }
	if .Held not_in doc.flags && k.lo + u64(k.n) <= u64(len(src)) {
		sp, lax, pos := src[k.lo:][:k.n], k.spelling & tape.SPELLING_LAX != 0, at + 2
		for c in sp {
			if lax && c == 0 {
				if pos + 3 > u64(len(src)) || src[pos] != 0xEF || src[pos + 1] != 0xBF || src[pos + 2] != 0xBD { return false }
				pos += 3
				continue
			}
			if pos >= u64(len(src)) { return false }
			sc := src[pos]
			if (c | 0x20 if c - 'A' < 26 else c) != (sc | 0x20 if sc - 'A' < 26 else sc) { return false }
			pos += 1
		}
		return pos < u64(len(src)) && (is_space(src[pos]) || src[pos] == '/' || src[pos] == '>')
	}
	return false
}

// ---------- Read-on detection and two-pass trimming / excision ----------

@(private = "file")
Read_On_Edit :: struct {
	node:       ^edit.Edit_Node,
	tail:       []edit.Byte_Range,
	joined:     int,
	trimmed:    string,
	can_trim:   bool,
	old_val:    edit.Edit_Value,
	old_inline: bool,
	old_buf:    [16]u8,
}

@(private = "file")
collect_read_ons :: proc(ov: ^Overlay, allocator: runtime.Allocator) -> ([dynamic]Read_On_Edit, Edit_Error) {
	out := make([dynamic]Read_On_Edit, 0, 2, allocator)
	doc := ov.base
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	ebuf: [128]u8 = ---
	for n in html_iter_next(&it) {
		if !n.has_edits || n.state != .Replaced || n.base == tape.NO_NODE || n.base == tape.ROOT || tape.is_text_key(doc.nodes[n.base - 1]) { continue }
		el := html_element_of(doc, n.base)
		ename, ename_owned := key_name_temp(doc, n.base - 1, ebuf[:], allocator)
		skip := (el.end_tag && ename != "body") || el.close >= u64(len(doc.src))
		if ename_owned { delete(ename, allocator) }
		if skip { continue }
		if err := ensure_html_parents(ov); err != nil { destroy_read_ons(&out, allocator); return {}, err }
		tail := text_past(doc, ov.parents, n.base, el.close, allocator)
		if len(tail) == 0 { continue }
		joined := 0
		for sp in tail { joined += int(sp.hi - sp.lo) }
		ro := Read_On_Edit{node = n, tail = tail[:], joined = joined}
		if n.val.kind != .Raw && n.val.kind < .Array {
			buf: [64]u8 = ---
			txt := scalar_edit_val_str(&n.val, buf[:])
			if len(txt) >= joined && ends_with_byte_ranges(txt, doc.src, tail[:]) {
				ro.can_trim = true
				ro.trimmed = strings.clone(txt[:len(txt) - joined], allocator)
			}
		}
		append(&out, ro)
	}
	return out, nil
}

@(private = "file")
destroy_read_ons :: proc(items: ^[dynamic]Read_On_Edit, allocator: runtime.Allocator) {
	for &ro in items { delete(ro.tail, allocator); delete(ro.trimmed, allocator) }
	delete(items^)
}

@(private = "file")
apply_keep_trim :: proc(items: []Read_On_Edit) -> (kept: bool) {
	for &ro in items {
		if !ro.can_trim { continue }
		n := ro.node
		ro.old_val, ro.old_inline, ro.old_buf = n.val, n.val_inline, n.inline_buf
		n.val, n.val_inline = edit.val_string(ro.trimmed), false
		kept = true
	}
	return
}

@(private = "file")
restore_keep_trim :: proc(items: []Read_On_Edit) {
	for &ro in items {
		if !ro.can_trim { continue }
		ro.node.val, ro.node.val_inline, ro.node.inline_buf = ro.old_val, ro.old_inline, ro.old_buf
	}
}

@(private = "file")
ends_with_byte_ranges :: proc(text: string, src: []u8, spans: []edit.Byte_Range) -> bool {
	at := len(text)
	#reverse for sp in spans {
		n := int(sp.hi - sp.lo)
		if at < n || string(src[sp.lo:sp.hi]) != text[at - n:at] { return false }
		at -= n
	}
	return true
}

@(private = "file")
text_past :: proc(doc: ^tape.Document, parents: []tape.Node_Index, v: tape.Node_Index, close: u64, allocator: runtime.Allocator) -> [dynamic]edit.Byte_Range {
	Past :: struct { src: []u8, name: string, closes: [dynamic]u64, texts: [dynamic]edit.Byte_Range, allocator: runtime.Allocator, ctx: runtime.Context }
	on :: proc "contextless" (p: ^Past, t: ^Html_Token) -> Token_Action {
		context = p.ctx
		context.allocator = p.allocator
		#partial switch t.kind {
		case .Text: append(&p.texts, edit.Byte_Range{lo = t.lo, hi = t.hi})
		case .Comment, .Error:
		case .End_Tag:
			name := p.src[t.name.lo:][:t.name.n]
			if fold_name_equal(name, "body") || fold_name_equal(name, "html") { return .Next }
			if fold_name_equal(name, p.name) || slice.contains(p.closes[:], t.lo) { return .Stop }
		case: return .Stop
		}
		return .Next
	}
	nbuf: [128]u8 = ---
	name, name_owned := key_name_temp(doc, v - 1, nbuf[:], allocator)
	defer if name_owned { delete(name, allocator) }
	p := Past{src = doc.src, name = name, closes = make([dynamic]u64, 0, 8, allocator), texts = make([dynamic]edit.Byte_Range, 0, 4, allocator), allocator = allocator, ctx = context}
	defer delete(p.closes)
	if parents != nil {
		for a := parents[v]; a != tape.ROOT && a != tape.NO_NODE; a = parents[a] {
			if doc.nodes[a].kind == .Object { if el := html_element_of(doc, a); el.end_tag { append(&p.closes, el.close) } }
		}
	}
	_, _, _ = tokenize(doc.src, &p, on, from = close, allocator = allocator)
	return p.texts
}

@(private = "file")
apply_read_on_cuts :: proc(res: ^Commit_Result, items: []Read_On_Edit, allocator: runtime.Allocator) -> edit.Error {
	Cut_Span :: struct { src_lo, src_hi, pre_lo, pre_hi: u64, base_node: tape.Node_Index }
	cuts := make([dynamic]Cut_Span, 0, 4, allocator)
	defer delete(cuts)
	for ro in items {
		for sp in ro.tail {
			covered, shift := false, i64(0)
			for sr in res.splices {
				if sp.lo >= sr.src_lo && sp.hi <= sr.src_hi { covered = true; break }
				if sr.src_hi <= sp.lo { shift += i64(sr.dst_hi - sr.dst_lo) - i64(sr.src_hi - sr.src_lo) }
			}
			if covered { continue }
			dst_lo, dst_hi := u64(i64(sp.lo) + shift), u64(i64(sp.hi) + shift)
			if dst_hi <= u64(len(res.bytes)) && dst_lo < dst_hi {
				append(&cuts, Cut_Span{sp.lo, sp.hi, dst_lo, dst_hi, ro.node.base})
			}
		}
	}
	if len(cuts) == 0 { return nil }
	slice.sort_by(cuts[:], proc(a, b: Cut_Span) -> bool { return a.pre_lo < b.pre_lo if a.pre_lo != b.pre_lo else a.src_lo < b.src_lo })
	merged := make([dynamic]Cut_Span, 0, len(cuts), allocator)
	defer delete(merged)
	for c in cuts {
		if len(merged) == 0 || c.pre_lo > merged[len(merged) - 1].pre_hi {
			append(&merged, c)
		} else {
			prev := &merged[len(merged) - 1]
			has_boundary_sr := false
			if c.pre_lo == prev.pre_hi && c.src_lo > prev.src_hi {
				for sr in res.splices {
					if sr.src_lo >= prev.src_hi && sr.src_hi <= c.src_lo { has_boundary_sr = true; break }
				}
			}
			if has_boundary_sr {
				append(&merged, c)
			} else {
				prev.pre_hi = max(prev.pre_hi, c.pre_hi)
				prev.src_hi = max(prev.src_hi, c.src_hi)
				prev.src_lo = min(prev.src_lo, c.src_lo)
			}
		}
	}
	drop_len := 0
	for c in merged { drop_len += int(c.pre_hi - c.pre_lo) }
	new_bytes, err := runtime.mem_alloc_non_zeroed(len(res.bytes) - drop_len, 1, allocator)
	if err != nil { return err }
	new_splices, serr := make([]edit.Splice_Record, len(res.splices) + len(merged), allocator)
	if serr != nil { delete(new_bytes, allocator); return serr }

	pos, w := u64(0), 0
	for c in merged {
		if c.pre_lo > pos { w += copy(new_bytes[w:], res.bytes[pos:c.pre_lo]) }
		pos = c.pre_hi
	}
	if pos < u64(len(res.bytes)) { copy(new_bytes[w:], res.bytes[pos:]) }

	cut_before := proc "contextless" (merged: []Cut_Span, p, src_p: u64, check_src: bool) -> (acc: u64) {
		for c in merged {
			if c.pre_hi < p || (c.pre_hi == p && (!check_src || c.src_hi <= src_p)) { acc += c.pre_hi - c.pre_lo } else { break }
		}
		return
	}
	for &rw in res.rewritten { rw.lo -= cut_before(merged[:], rw.lo, 0, false); rw.hi -= cut_before(merged[:], rw.hi, 0, false) }
	si := 0
	for sr in res.splices {
		drop := cut_before(merged[:], sr.dst_lo, sr.src_lo, true)
		adj := sr
		adj.dst_lo -= drop; adj.dst_hi -= drop; adj.full_rewalk = true
		new_splices[si] = adj; si += 1
	}
	for c in merged {
		adj_pos := c.pre_lo - cut_before(merged[:], c.pre_lo, c.src_lo, true)
		new_splices[si] = {base_node = c.base_node, src_lo = c.src_lo, src_hi = c.src_hi, dst_lo = adj_pos, dst_hi = adj_pos, full_rewalk = true}
		si += 1
	}
	slice.sort_by(new_splices, proc(a, b: edit.Splice_Record) -> bool {
		if a.src_lo != b.src_lo { return a.src_lo < b.src_lo }
		return a.dst_lo < b.dst_lo if a.dst_lo != b.dst_lo else a.src_hi < b.src_hi
	})
	delete(res.bytes, allocator); delete(res.splices, allocator)
	res.bytes, res.splices = new_bytes, new_splices
	return nil
}

// ---------- Arena-backed iterative reread verification (`reread_verify`) ----------

@(private = "file")
is_safe_ascii_scalar :: proc "contextless" (txt: string, no_markup: bool) -> bool {
	if len(txt) == 0 || is_space(txt[0]) || is_space(txt[len(txt) - 1]) { return false }
	for c in transmute([]u8)txt {
		if c < 0x20 || c >= 0x80 || (no_markup && (c == '<' || c == '>' || c == '&')) { return false }
	}
	return true
}

@(private = "file")
reread_verify :: proc(ov: ^Overlay, spec: Spec, build_opts: Options, out: []u8, allocator: runtime.Allocator, force_full: bool) -> Edit_Error {
	if !force_full && !ov.has_structural {
		simple := true
		it := handle_map.dynamic_iterator_make(&ov.nodes)
		ebuf: [128]u8 = ---
		for n in html_iter_next(&it) {
			if !n.has_edits || (n.state == .Ancestor && len(n.facts) == 0) { continue }
			if len(n.facts) > 0 || n.state != .Replaced || n.base == tape.NO_NODE || n.base == tape.ROOT { simple = false; break }
			bn := ov.base.nodes[n.base]
			if bn.kind >= .Array || bn.kind == .Null || n.val.kind >= .Array || n.val.kind == .Null || n.val.kind == .Base_Ref || tape.is_text_key(ov.base.nodes[n.base - 1]) {
				simple = false; break
			}
			ename, ename_owned := key_name_temp(ov.base, n.base - 1, ebuf[:], allocator)
			bad_ctx := key_namespace(ov.base.nodes[n.base - 1]) != .Html || is_void_ci(ename) || keeps_space_name(ename) || ename == "plaintext"
			raw_ctx := n.val.kind == .Raw || is_raw_name(ename) || ename == "title" || ename == "textarea"
			if ename_owned { delete(ename, allocator) }
			buf: [64]u8 = ---
			if bad_ctx || !html_element_of(ov.base, n.base).end_tag || !is_safe_ascii_scalar(scalar_edit_val_str(&n.val, buf[:]), raw_ctx) {
				simple = false; break
			}
		}
		if simple { return nil }
	}

	arena, ar_err := new(runtime.Arena, allocator)
	if ar_err != nil { return ar_err }
	defer free(arena, allocator)
	if ierr := runtime.arena_init(arena, 64 * 1024, allocator); ierr != nil { return ierr }
	defer runtime.arena_destroy(arena)
	scratch := runtime.arena_allocator(arena)

	built, berr := build(out, spec, build_opts, scratch)
	if berr != nil {
		if aerr, is_a := berr.(runtime.Allocator_Error); is_a { return aerr }
		return edit.refuse(.Invalid_Result, "edited output failed HTML parse")
	}
	if len(ov.base.nodes) == 0 || len(built.nodes) == 0 { return edit.refuse(.Invalid_Result, "edited output produced empty HTML tree") }
	if spec == .Html && (count_elem_children(&built, tape.ROOT) != 1 || count_elem_children(&built, tape.ROOT) != count_elem_children(ov.base, tape.ROOT)) {
		return edit.refuse(.Invalid_Result, "edited document root does not hold single html element")
	}
	if !verify_subtree_counts(ov, &built, tape.ROOT, tape.ROOT, build_opts, scratch) {
		return edit.refuse(.Invalid_Result, "edited HTML reads back as a different tree structure")
	}
	return nil
}

@(private = "file")
Verify_Item :: struct {
	key_name:    string,
	renamed:     bool,
	is_text:     bool,
	src_lo:      u64,
	seq:         int,
	base_k:      tape.Node_Index,
	base_v:      tape.Node_Index,
	edit_h:      Handle,
	is_inserted: bool,
	is_arr_rep:  bool,
	arr_elems:   []Handle,
}

@(private = "file")
ensure_html_parents :: proc(ov: ^Overlay) -> runtime.Allocator_Error {
	if ov.parents != nil { return nil }
	n := len(ov.base.nodes)
	p := make([]tape.Node_Index, n, ov.allocator) or_return
	slice.fill(p, tape.NO_NODE)
	Frame :: struct { node, end: tape.Node_Index }
	st := make([dynamic]Frame, 0, 32, ov.allocator)
	defer delete(st)
	if n > 0 && ov.base.nodes[0].kind > .Plain { append(&st, Frame{0, tape.Node_Index(ov.base.nodes[0].n)}) }
	for i := tape.Node_Index(1); int(i) < n; {
		for len(st) > 0 && st[len(st) - 1].end <= i { _ = pop(&st) }
		parent := st[len(st) - 1].node if len(st) > 0 else tape.ROOT
		p[i] = parent
		nd := ov.base.nodes[i]
		if nd.role == .Key {
			if val := i + 1; int(val) < n {
				p[val] = parent
				if ov.base.nodes[val].kind > .Plain { append(&st, Frame{val, val + tape.Node_Index(ov.base.nodes[val].n)}) }
			}
			i += 2
			continue
		}
		if nd.kind > .Plain { append(&st, Frame{i, i + tape.Node_Index(nd.n)}) }
		i += 1
	}
	ov.parents = p
	return nil
}

@(private = "file")
Verify_Pair :: struct { a, b: tape.Node_Index, follow_ov: bool }

@(private = "file")
verify_subtree_counts :: proc(ov: ^Overlay, built: ^tape.Document, a, b: tape.Node_Index, build_opts: Options, sc: runtime.Allocator) -> bool {
	stack := make([dynamic]Verify_Pair, 0, 16, sc)
	append(&stack, Verify_Pair{a, b, true})
	for len(stack) > 0 {
		pair := pop(&stack)
		base_n, built_n := ov.base.nodes[pair.a], built.nodes[pair.b]
		cn: ^edit.Edit_Node
		has_cn := false
		if pair.follow_ov {
			if ch, has := ov.by_base[pair.a]; has { cn, has_cn = edit.get_node(ov, ch) }
		}
		if has_cn && cn.has_edits && has_attr_fact(cn) {
			if !verify_edited_attributes(ov.base, pair.a, cn, built, pair.b, sc) { return false }
		} else if !same_attributes(ov.base, pair.a, built, pair.b) {
			return false
		}
		if has_cn && cn.has_edits && cn.state == .Replaced {
			if !verify_replaced_content(built, pair.b, build_opts, sc) || !verify_edit_handle(ov, cn.handle, built, pair.b, build_opts, sc) { return false }
			continue
		}
		if has_cn && cn.has_edits && cn.state == .Container_Delta && cn.delta != nil {
			if built_n.kind != .Object || !verify_container_delta(ov, built, pair.a, pair.b, cn.delta, &stack, build_opts, true, sc) { return false }
			continue
		}
		if base_n.kind != built_n.kind {
			if !(has_cn && len(cn.facts) > 0 && base_n.kind <= .Plain && base_n.kind != .Null && built_n.kind <= .Plain && built_n.kind != .Null) { return false }
		}
		if base_n.kind != .Object {
			if scalar_sc(ov.base, pair.a, sc) != scalar_sc(built, pair.b, sc) { return false }
			continue
		}
		ca, cb := collect_children_pairs(ov.base, pair.a, sc), collect_children_pairs(built, pair.b, sc)
		expected := make([dynamic]Verify_Item, 0, len(ca), sc)
		array_rep := make([dynamic]string, 0, 2, sc)
		for cp in ca {
			kn := scalar_sc(ov.base, cp.k, sc)
			is_txt := tape.is_text_key(ov.base.nodes[cp.k])
			if !is_txt && slice.contains(array_rep[:], kn) { continue }
			if pair.follow_ov {
				if ch, h_ok := ov.by_base[cp.v]; h_ok {
					if chn, cok := edit.get_node(ov, ch); cok && chn.has_edits && chn.state == .Replaced && chn.val.kind == .Array && !is_txt {
						append(&array_rep, kn)
						append(&expected, Verify_Item{base_k = cp.k, base_v = cp.v, is_arr_rep = true, arr_elems = chn.elems[:]})
						continue
					}
				}
			}
			append(&expected, Verify_Item{base_k = cp.k, base_v = cp.v})
		}
		bi := 0
		for item in expected {
			if item.is_arr_rep {
				for eh in item.arr_elems {
					if bi >= len(cb) || !same_key(ov.base, item.base_k, built, cb[bi].k, sc) || !verify_edit_handle(ov, eh, built, cb[bi].v, build_opts, sc) { return false }
					bi += 1
				}
				continue
			}
			if bi >= len(cb) || !same_key(ov.base, item.base_k, built, cb[bi].k, sc) { return false }
			append(&stack, Verify_Pair{item.base_v, cb[bi].v, pair.follow_ov})
			bi += 1
		}
		if bi != len(cb) { return false }
	}
	return true
}

@(private = "file")
verify_container_delta :: proc(ov: ^Overlay, built: ^tape.Document, a, b: tape.Node_Index, d: ^edit.Container_Delta, stack: ^[dynamic]Verify_Pair, build_opts: Options, follow_by_base: bool, sc: runtime.Allocator) -> bool {
	ca, cb := collect_children_pairs(ov.base, a, sc), collect_children_pairs(built, b, sc)
	items := make([dynamic]Verify_Item, 0, len(ca) + len(d.inserted_members), sc)
	base_items := make([dynamic]Verify_Item, 0, len(ca), sc)
	array_rep := make([dynamic]string, 0, 2, sc)

	for cp, idx in ca {
		is_txt := tape.is_text_key(ov.base.nodes[cp.k])
		kname := scalar_sc(ov.base, cp.k, sc)
		del := slice.contains(d.deleted_keys[:], kname) || (!is_txt && slice.contains(array_rep[:], kname))
		eff_name, renamed := kname, false
		if !del {
			for r in d.renamed_members { if r.old_key == kname { eff_name, renamed = r.new_key, true; break } }
		}
		it := Verify_Item{key_name = eff_name, renamed = renamed, is_text = is_txt, src_lo = ov.base.nodes[cp.v].lo, seq = idx * 2 + 1, base_k = tape.NO_NODE if del else cp.k, base_v = cp.v}
		if !del && follow_by_base {
			if ch, has := ov.by_base[cp.v]; has {
				if chn, cok := edit.get_node(ov, ch); cok && chn.has_edits && chn.state == .Replaced && chn.val.kind == .Array && !is_txt {
					append(&array_rep, kname)
					it.is_arr_rep, it.arr_elems = true, chn.elems[:]
				}
			}
		}
		append(&base_items, it)
	}

	if len(d.order) > 0 {
		for raw in d.order {
			idx := int(raw)
			if idx < len(base_items) {
				append(&items, base_items[idx])
			} else {
				ins := d.inserted_members[idx - len(base_items)]
				append(&items, Verify_Item{key_name = ins.key, is_text = ins.key == tape.TEXT_KEY, edit_h = ins.value, is_inserted = true})
			}
		}
	} else {
		for it in base_items { if it.base_k != tape.NO_NODE { append(&items, it) } }
		for ins, ins_i in d.inserted_members {
			in_r := ins.at >= 0 && ins.at < len(base_items)
			append(&items, Verify_Item{
				key_name = ins.key, is_text = ins.key == tape.TEXT_KEY,
				src_lo = base_items[ins.at].src_lo if in_r else max(u64),
				seq = ins.at * 2 if in_r else (len(base_items) + ins_i) * 2,
				edit_h = ins.value, is_inserted = true,
			})
		}
		slice.stable_sort_by(items[:], proc(x, y: Verify_Item) -> bool { return x.src_lo < y.src_lo if x.src_lo != y.src_lo else x.seq < y.seq })
	}

	bi := 0
	for it in items {
		if it.is_arr_rep {
			for eh in it.arr_elems {
				if bi >= len(cb) || scalar_sc(built, cb[bi].k, sc) != it.key_name || !verify_edit_handle(ov, eh, built, cb[bi].v, build_opts, sc) { return false }
				bi += 1
			}
			continue
		}
		if bi >= len(cb) { return false }
		if it.is_inserted {
			if scalar_sc(built, cb[bi].k, sc) != it.key_name || !verify_edit_handle(ov, it.edit_h, built, cb[bi].v, build_opts, sc) { return false }
			bi += 1
			continue
		}
		if it.renamed {
			if scalar_sc(built, cb[bi].k, sc) != it.key_name { return false }
		} else if !same_key(ov.base, it.base_k, built, cb[bi].k, sc) {
			return false
		}
		append(stack, Verify_Pair{it.base_v, cb[bi].v, follow_by_base})
		bi += 1
	}
	return bi == len(cb)
}

@(private = "file")
verify_edit_handle :: proc(ov: ^Overlay, root_h: Handle, built: ^tape.Document, root_b: tape.Node_Index, build_opts: Options, sc: runtime.Allocator) -> bool {
	Handle_Check :: struct { is_pair: bool, h: Handle, a, b: tape.Node_Index }
	stack := make([dynamic]Handle_Check, 0, 16, sc)
	delta_pairs := make([dynamic]Verify_Pair, 0, 8, sc)
	append(&stack, Handle_Check{h = root_h, b = root_b})

	for len(stack) > 0 {
		item := pop(&stack)
		if item.is_pair {
			if !verify_subtree_counts(ov, built, item.a, item.b, build_opts, sc) { return false }
			continue
		}
		if item.h == edit.NO_HANDLE { continue }
		n, ok := edit.get_node(ov, item.h)
		if !ok { continue }
		b := item.b
		bn := built.nodes[b]
		if n.state == .Replaced {
			#partial switch n.val.kind {
			case .Null:
				if !(bn.kind == .Null || (bn.kind == .Plain && bn.n == 0)) { return false }
			case .Raw:
				if !verify_replaced_content(built, b, build_opts, sc) { return false }
			case .Base_Ref:
				if n.val.base_ref != tape.NO_NODE && int(n.val.base_ref) < len(ov.base.nodes) {
					if len(n.facts) > 0 && has_attr_fact(n) && !verify_edited_attributes(ov.base, n.val.base_ref, n, built, b, sc) { return false }
					if !same_subtree(ov.base, n.val.base_ref, built, b, false, true, sc) { return false }
				}
			case .Object:
				if bn.kind != .Object { return false }
				cb := collect_children_pairs(built, b, sc)
				bi := 0
				for m in n.members {
					if en, eok := edit.get_node(ov, m.value); eok && en.state == .Replaced && en.val.kind == .Array {
						for eh in en.elems {
							if bi >= len(cb) || scalar_sc(built, cb[bi].k, sc) != m.key { return false }
							append(&stack, Handle_Check{h = eh, b = cb[bi].v}); bi += 1
						}
						continue
					}
					if bi >= len(cb) || scalar_sc(built, cb[bi].k, sc) != m.key { return false }
					append(&stack, Handle_Check{h = m.value, b = cb[bi].v}); bi += 1
				}
				if bi != len(cb) { return false }
			case .Array:
			case:
				if bn.kind == .Object { return false }
				buf: [64]u8 = ---
				want := scalar_edit_val_str(&n.val, buf[:])
				if bn.kind == .Null { if want != "" { return false } } else if scalar_sc(built, b, sc) != want { return false }
			}
		} else if n.state == .Container_Delta && n.delta != nil {
			base_c := edit.node_base_container(n)
			if base_c == tape.NO_NODE || bn.kind != .Object { return false }
			if has_attr_fact(n) {
				if !verify_edited_attributes(ov.base, base_c, n, built, b, sc) { return false }
			} else if !same_attributes(ov.base, base_c, built, b) {
				return false
			}
			clear(&delta_pairs)
			if !verify_container_delta(ov, built, base_c, b, n.delta, &delta_pairs, build_opts, n.base != tape.NO_NODE, sc) { return false }
			for dp in delta_pairs {
				if dp.follow_ov { append(&stack, Handle_Check{is_pair = true, a = dp.a, b = dp.b}) } else if !same_subtree(ov.base, dp.a, built, dp.b, false, true, sc) { return false }
			}
		}
	}
	return true
}

// Unified iterative subtree comparison (used by both `Base_Ref` and `verify_replaced_content`).
@(private = "file")
same_subtree :: proc(a: ^tape.Document, na: tape.Node_Index, b: ^tape.Document, nb: tape.Node_Index, check_attrs, loose_scalar: bool, sc: runtime.Allocator) -> bool {
	stack := make([dynamic]Verify_Pair, 0, 16, sc)
	if _, err := append(&stack, Verify_Pair{na, nb, false}); err != nil { return false }
	for len(stack) > 0 {
		pair := pop(&stack)
		nda, ndb := a.nodes[pair.a], b.nodes[pair.b]
		if nda.kind != ndb.kind {
			if !(loose_scalar && nda.kind <= .Plain && nda.kind != .Null && ndb.kind <= .Plain && ndb.kind != .Null) { return false }
		}
		if nda.kind != .Object {
			if scalar_sc(a, pair.a, sc) != scalar_sc(b, pair.b, sc) { return false }
			continue
		}
		ca, cb := collect_children_pairs(a, pair.a, sc), collect_children_pairs(b, pair.b, sc)
		if len(ca) != len(cb) { return false }
		for i := len(ca) - 1; i >= 0; i -= 1 {
			if check_attrs {
				if !same_key(a, ca[i].k, b, cb[i].k, sc) || !same_attributes(a, ca[i].v, b, cb[i].v) { return false }
			} else if scalar_sc(a, ca[i].k, sc) != scalar_sc(b, cb[i].k, sc) {
				return false
			}
			if _, err := append(&stack, Verify_Pair{ca[i].v, cb[i].v, false}); err != nil { return false }
		}
	}
	return true
}

@(private = "file")
verify_replaced_content :: proc(built: ^tape.Document, b: tape.Node_Index, build_opts: Options, sc: runtime.Allocator) -> bool {
	if b == tape.ROOT {
		if built.format != as(.Html) { return true }
		el := html_element_of(built, b)
		alone, err := build(built.src[el.lo:el.hi], .Html, build_opts, sc)
		return err == nil && same_subtree(built, b, &alone, tape.ROOT, true, false, sc)
	}
	el := html_element_of(built, b)
	name, ns := scalar_name_of(built, b - 1, sc), key_namespace(built.nodes[b - 1])
	if el.close < el.open || el.close > u64(len(built.src)) { return true }
	base_content := built.src[el.open:el.close]
	if ns == .Html && keeps_space_name(name) {
		if strings.has_prefix(string(base_content), "\r\n") { base_content = base_content[2:] } else if len(base_content) > 0 && (base_content[0] == '\n' || base_content[0] == '\r') { base_content = base_content[1:] }
	}
	tail := read_on_bytes(built, b, el.close, sc)
	content := slice.concatenate([][]u8{base_content, tail}, sc) if len(tail) > 0 else base_content
	frag, err := build_fragment(content, {context_name = name, context_namespace = ns}, build_opts, sc)
	if err != nil { return false }
	if built.nodes[b].kind == .Object { return same_subtree(built, b, &frag, tape.ROOT, true, false, sc) }
	if built.nodes[b].kind == .Null { return count_elem_children(&frag, tape.ROOT) == 0 && len(frag.nodes) <= 1 }
	frag_txt := ""
	if len(frag.nodes) == 3 && tape.is_text_key(frag.nodes[1]) { frag_txt = scalar_sc(&frag, 2, sc) } else if len(frag.nodes) > 1 { return false }
	got := scalar_sc(built, b, sc)
	return frag_txt == got || (frag_txt == "" && strings.trim(got, " \t\n\r\f") == "")
}

@(private = "file")
read_on_bytes :: proc(y: ^tape.Document, b: tape.Node_Index, close: u64, sc: runtime.Allocator) -> []u8 {
	out := make([dynamic]u8, 0, 16, sc)
	for k in b ..< tape.node_after(y, b) {
		if y.nodes[k].kind != .Plain || y.nodes[k].spelling & TEXT_PIECES == 0 || y.ext == nil { continue }
		if b_bytes, head, entry, ok := find_text_entry(&y.ext.format, y.nodes[k].lo); ok {
			for i in 0 ..< entry.count {
				p := load_piece(b_bytes, head, entry.first + i)
				if p.lo >= close && p.lo + u64(p.n) <= u64(len(y.src)) { append(&out, ..y.src[p.lo:][:p.n]) }
			}
		}
	}
	return out[:]
}

@(private = "file")
same_key :: proc(x: ^tape.Document, ka: tape.Node_Index, y: ^tape.Document, kb: tape.Node_Index, sc: runtime.Allocator) -> bool {
	sa, sb := x.nodes[ka], y.nodes[kb]
	if (sa.n == 0) != (sb.n == 0) || key_namespace(sa) != key_namespace(sb) { return false }
	buf_a, buf_b: [256]u8 = ---, ---
	a_str, _ := key_name_temp(x, ka, buf_a[:], sc)
	b_str, _ := key_name_temp(y, kb, buf_b[:], sc)
	return a_str == b_str
}

@(private = "file")
same_attributes :: proc "contextless" (x: ^tape.Document, a: tape.Node_Index, y: ^tape.Document, b: tape.Node_Index) -> bool {
	fa, fb := tape.facts_of(x, a), tape.facts_of(y, b)
	i, j := 0, 0
	for {
		for i < len(fa) && fa[i].kind != .Attribute { i += 1 }
		for j < len(fb) && fb[j].kind != .Attribute { j += 1 }
		if i == len(fa) || j == len(fb) { return i == len(fa) && j == len(fb) }
		if string(x.src[fa[i].lo:][:fa[i].n]) != string(y.src[fb[j].lo:][:fb[j].n]) { return false }
		i, j = i + 1, j + 1
	}
}

@(private = "file")
has_attr_fact :: proc "contextless" (cn: ^edit.Edit_Node) -> bool {
	for f in cn.facts { if f.kind == .Attribute { return true } }
	return false
}

@(private = "file")
verify_edited_attributes :: proc(orig: ^tape.Document, a: tape.Node_Index, cn: ^edit.Edit_Node, built: ^tape.Document, b: tape.Node_Index, sc: runtime.Allocator) -> bool {
	Attr :: struct { name, val: string }
	collect_attrs :: proc(doc: ^tape.Document, v: tape.Node_Index, sc: runtime.Allocator) -> [dynamic]Attr {
		out := make([dynamic]Attr, 0, 4, sc)
		for bf in tape.facts_of(doc, v) {
			if bf.kind != .Attribute { continue }
			kt, vt := attribute(doc, bf)
			append(&out, Attr{scalar_tok_sc(doc, kt, sc), scalar_tok_sc(doc, vt, sc)})
		}
		return out
	}
	expected, got := collect_attrs(orig, a, sc), collect_attrs(built, b, sc)
	html_ns := a > 0 && a != tape.ROOT && orig.nodes[a - 1].role == .Key && key_namespace(orig.nodes[a - 1]) == .Html
	for f in cn.facts {
		if f.kind != .Attribute { continue }
		idx := -1
		for it, i in expected {
			if (strings.equal_fold(it.name, f.attr) if html_ns else it.name == f.attr) { idx = i; break }
		}
		if f.deleted || len(f.values) == 0 {
			if idx >= 0 { ordered_remove(&expected, idx) }
		} else if idx >= 0 {
			expected[idx].val = f.values[0]
		} else {
			append(&expected, Attr{strings.to_lower(f.attr, sc) if html_ns else f.attr, f.values[0]})
		}
	}
	if len(expected) != len(got) { return false }
	for i in 0 ..< len(expected) { if expected[i] != got[i] { return false } }
	return true
}

@(private = "file")
scalar_sc :: proc(doc: ^tape.Document, at: tape.Node_Index, sc: runtime.Allocator) -> string {
	buf := make([dynamic]u8, 0, 64, sc)
	return scalar_string(doc, at, &buf)
}

@(private = "file")
scalar_tok_sc :: proc(doc: ^tape.Document, tok: tape.Token, sc: runtime.Allocator) -> string {
	buf := make([]u8, max(tape.text_room(doc, tok), int(tok.n), 16), sc)
	s, ok := tape.node_text(doc, tok, buf)
	return s if ok else ""
}

@(private = "file")
collect_children_pairs :: proc(doc: ^tape.Document, c: tape.Node_Index, a: runtime.Allocator) -> []Child_Pair {
	out := make([dynamic]Child_Pair, 0, 8, a)
	if c == tape.NO_NODE || int(c) >= len(doc.nodes) || doc.nodes[c].kind != .Object { return out[:] }
	for k, end := c + 1, tape.node_after(doc, c); k < end; {
		v := tape.node_after(doc, k)
		append(&out, Child_Pair{k, v})
		k = tape.node_after(doc, v)
	}
	return out[:]
}

@(private = "file")
count_elem_children :: proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> (cnt: int) {
	if doc.nodes[v].kind != .Object { return 0 }
	for k, end := v + 1, tape.node_after(doc, v); k < end; {
		val := tape.node_after(doc, k)
		if !tape.is_text_key(doc.nodes[k]) { cnt += 1 }
		k = tape.node_after(doc, val)
	}
	return
}

@(private = "file")
key_name_temp :: proc(doc: ^tape.Document, k: tape.Node_Index, buf: []u8, a: runtime.Allocator) -> (string, bool) {
	t := doc.nodes[k]
	if fx := table_key_text(doc.src, t); len(fx) > 0 { return fx, false }
	if !tape.text_decodes(t) && .Held not_in doc.flags { return string(doc.src[t.lo:][:t.n]), false }
	if res, ok := tape.node_text(doc, k, buf); ok { return res, false }
	return scalar_name_of(doc, k, a), true
}

@(private = "file")
html_iter_next :: proc "contextless" (it: ^handle_map.Dynamic_Handle_Map_Iterator(handle_map.Dynamic_Handle_Map(edit.Edit_Node, Handle))) -> (^edit.Edit_Node, bool) {
	for it.index < xar.len(it.m.items) {
		p := xar.get_ptr_unsafe(&it.m.items, it.index)
		it.index += 1
		if p.handle.idx != 0 { return p, true }
	}
	return nil, false
}

@(private = "file")
Saved_Key_Case :: struct { slot: ^string, orig, raw: string }

@(private = "file")
apply_delta_key_cases :: proc(ov: ^Overlay, allocator: runtime.Allocator) -> [dynamic]Saved_Key_Case {
	saved := make([dynamic]Saved_Key_Case, 0, 4, allocator)
	swap_case :: proc(saved: ^[dynamic]Saved_Key_Case, slot: ^string, raw: string, a: runtime.Allocator) {
		if raw != slot^ && strings.equal_fold(raw, slot^) {
			cloned := strings.clone(raw, a)
			append(saved, Saved_Key_Case{slot, slot^, cloned})
			slot^ = cloned
		}
	}
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	kbuf: [256]u8 = ---
	for n in html_iter_next(&it) {
		bv := edit.node_base_container(n)
		if !n.has_edits || bv == tape.NO_NODE || int(bv) >= len(ov.base.nodes) { continue }
		if n.delta != nil && ov.base.nodes[bv].kind == .Object {
			ca := collect_children_pairs(ov.base, bv, allocator)
			defer delete(ca, allocator)
			for &r in n.delta.renamed_members {
				kn := ca[r.base_idx].k if r.base_idx >= 0 && r.base_idx < len(ca) else tape.NO_NODE
				if kn == tape.NO_NODE {
					for cp in ca {
						ks, own := key_name_temp(ov.base, cp.k, kbuf[:], allocator)
						m := ks == r.old_key
						if own { delete(ks, allocator) }
						if m { kn = cp.k; break }
					}
				}
				if kn != tape.NO_NODE && !tape.is_text_key(ov.base.nodes[kn]) {
					swap_case(&saved, &r.old_key, string(tape.span_bytes(ov.base, ov.base.nodes[kn].lo, ov.base.nodes[kn].n)), allocator)
				}
			}
			for &dk in n.delta.deleted_keys {
				for cp in ca {
					if tape.is_text_key(ov.base.nodes[cp.k]) { continue }
					ks, own := key_name_temp(ov.base, cp.k, kbuf[:], allocator)
					m := ks == dk
					if own { delete(ks, allocator) }
					if m {
						swap_case(&saved, &dk, string(tape.span_bytes(ov.base, ov.base.nodes[cp.k].lo, ov.base.nodes[cp.k].n)), allocator)
						break
					}
				}
			}
		}
		if len(n.facts) > 0 && bv != tape.ROOT && ov.base.nodes[bv - 1].role == .Key && key_namespace(ov.base.nodes[bv - 1]) == .Html {
			for &f in n.facts {
				if f.kind != .Attribute { continue }
				for bf in tape.facts_of(ov.base, bv) {
					if bf.kind != .Attribute { continue }
					kt, _ := attribute(ov.base, bf)
					raw_attr := string(tape.span_bytes(ov.base, kt.lo, kt.n))
					if strings.equal_fold(raw_attr, f.attr) { swap_case(&saved, &f.attr, raw_attr, allocator); break }
				}
			}
		}
	}
	return saved
}

@(private = "file")
restore_delta_key_cases :: proc(ov: ^Overlay, saved: ^[dynamic]Saved_Key_Case) {
	for s in saved { s.slot^ = s.orig; delete(s.raw, ov.allocator) }
	delete(saved^)
	saved^ = {}
}

@(private = "file")
scalar_name_of :: proc(doc: ^tape.Document, k: tape.Node_Index, a: runtime.Allocator) -> string {
	buf, err := make([]u8, max(tape.text_room(doc, k), int(doc.nodes[k].n), 16), a)
	if err != nil { return strings.clone("div", a) }
	s, ok := tape.node_text(doc, k, buf)
	out := strings.clone(s if ok else "div", a)
	delete(buf, a)
	return out
}
