package html

import "base:intrinsics"
import "base:runtime"
import "core:container/handle_map"
import "core:container/xar"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"

// Byte-preserving HTML5 editing over `edit.Overlay` and `edit.commit_markup`.
// - Preserves original attribute quoting, order, and capitalized attribute names (`<div K=1>` -> `<div K=2>`).
// - Handles HTML void elements (`br`, `img`, `meta`, `input`, etc.), omitted end tags (`<p>x`),
//   trailing read-on whitespace (`<p>a</body></html>\n`), and rawtext (`<script>`).
// - Refuses edits touching constructed nodes (implied `html`/`head`/`body`/`tbody`, foster-parented/cloned nodes),
//   split text across dropped start tags, non-lowercase element names, invalid HTML comments, and structural rereads.

Overlay :: edit.Overlay
Handle :: edit.Handle
Edit_Value :: edit.Edit_Value
Edit_Options :: edit.Options
Edit_Error :: edit.Error
Commit_Result :: edit.Commit_Result

edit_init :: proc(ov: ^Overlay, doc: ^tape.Document, allocator := context.allocator) -> Edit_Error {
	return edit.init(ov, doc, allocator)
}

edit_destroy :: proc(ov: ^Overlay) {
	edit.destroy(ov)
}

@(private = "file")
Edit_Build_Ctx :: struct {
	spec: Spec,
	opts: Options,
}

@(private = "file")
edit_build_opts :: proc "contextless" (base: ^tape.Document, ov: ^Overlay = nil, min_extra := 0) -> Options {
	opts: Options
	need := u64(min_extra) + 64
	if base != nil {
		if doc_inferred(base) {
			opts.format = Xml_Options{infer = true}
		}
		need += u64(len(base.nodes))
	}
	if ov != nil {
		need += u64(xar.len(ov.nodes.items))
	}
	if need > tape.DEFAULT_DEPTH {
		opts.budget.depth = u32(min(need, u64(max(u32))))
	}
	return opts
}

commit :: proc(
	ov: ^Overlay,
	opts := Edit_Options{},
	allocator := context.allocator,
) -> (
	res: Commit_Result,
	err: Edit_Error,
) {
	if ov == nil || ov.base == nil {
		return {}, edit.refuse(.No_Document, "commit requires an initialized overlay")
	}
	if opts.target != nil && opts.target != as(.Html) && opts.target != as(.Fragment) {
		return {}, tape.Bad_Option{"target"}
	}
	spec := spec_of_target(ov.base, opts.target)
	eff_opts := opts
	eff_opts.target = as(spec)

	// Pre-validate HTML constraints: constructed/moved nodes, split text, element name casing, comment/attribute rules.
	pre_check_overlay(ov, spec) or_return

	eb := Edit_Build_Ctx{spec = spec, opts = edit_build_opts(ov.base, ov)}

	// Direct `.Raw` root replacement (common when replacing whole `<html>...` in `.Html` doc).
	if ov.root != edit.NO_HANDLE {
		if rn, ok := edit.get_node(ov, ov.root); ok && rn.state == .Replaced && rn.val.kind == .Raw {
			return commit_raw_root(ov, rn, spec, eb.opts, allocator)
		}
	}

	mspec := edit.Markup_Spec {
		target         = as(spec),
		self_closing   = false,
		element        = html_element_of,
		is_name        = html_is_markup_name_bytes,
		is_void        = is_void_ci,
		spell_content  = html_spell_content,
		spell_attr_val = html_spell_attr_val,
		validate       = html_edit_validate_doc,
		data           = &eb,
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

	// Two-pass read-on resolution matching HTML5:
	// Pass 1 (`keep = true`): keep trailing read-on whitespace if replacement scalar ends with its exact bytes.
	// Pass 2 (`keep = false`): cut remaining read-on spans after ignored tags so element reads back as written.
	for keep in ([?]bool{true, false}) {
		kept_any := false
		if keep {
			kept_any = apply_keep_trim(ov, read_ons[:])
			if !kept_any {
				continue
			}
		}
		res, err = edit.commit_markup(ov, &mspec, eff_opts, allocator)
		if keep {
			restore_keep_trim(read_ons[:])
		}
		if err != nil {
			return {}, err
		}
		if !keep {
			if cerr := apply_read_on_cuts(&res, read_ons[:], allocator); cerr != nil {
				edit.destroy_commit_result(&res)
				return {}, cerr
			}
		}
		restore_delta_key_cases(ov, &saved_cases)
		if rerr := reread_verify(ov, spec, eb.opts, res.bytes, allocator, true); rerr != nil {
			edit.destroy_commit_result(&res)
			if keep {
				saved_cases = apply_delta_key_cases(ov, ov.allocator)
				continue
			}
			return {}, rerr
		}
		return res, nil
	}
	return {}, err
}

commit_document :: proc(
	ov: ^Overlay,
	opts := Edit_Options{},
	allocator := context.allocator,
) -> (
	doc: tape.Document,
	res: Commit_Result,
	err: Edit_Error,
) {
	res = commit(ov, opts, allocator) or_return
	defer if err != nil {
		edit.destroy_commit_result(&res)
	}
	spec := spec_of_target(ov.base, opts.target)
	eff_opts := opts
	eff_opts.target = as(spec)
	eb := Edit_Build_Ctx{spec = spec, opts = edit_build_opts(ov.base, ov, len(res.bytes))}
	doc = edit.splice_document(ov.base, &res, eff_opts, html_walk_fragment_cb, &eb, html_full_build_cb, &eb, allocator) or_return
	return doc, res, nil
}

walk_fragment :: proc(
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	spec := Spec.Fragment,
	allocator := context.allocator,
) -> (
	ft: edit.Fragment_Tape,
	err: tape.Error,
) {
	opts := edit_build_opts(ctx.base, nil, int(range.hi - range.lo))
	return walk_fragment_with_opts(src, range, ctx, spec, opts, allocator)
}

@(private = "file")
walk_fragment_with_opts :: proc(
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	spec: Spec,
	opts: Options,
	allocator: runtime.Allocator,
) -> (
	ft: edit.Fragment_Tape,
	err: tape.Error,
) {
	if ctx.base != nil && ctx.base.ext != nil {
		full := build(src, spec, opts, allocator) or_return
		return edit.Fragment_Tape{full_doc = full, allocator = allocator}, nil
	}
	sub := src[range.lo:range.hi]
	el_name := "div"
	el_ns := Namespace.Html
	el_owned := false
	if ctx.base != nil && ctx.base_node != tape.ROOT && int(ctx.base_node) > 0 && int(ctx.base_node) < len(ctx.base.nodes) {
		el_name = scalar_name_of(ctx.base, ctx.base_node - 1, allocator)
		el_ns = key_namespace(ctx.base.nodes[ctx.base_node - 1])
		el_owned = true
	}
	defer if el_owned {
		delete(el_name, allocator)
	}
	d := build_fragment(sub, {context_name = el_name, context_namespace = el_ns}, opts, allocator) or_return
	out_ft, merr := edit.shift_fragment_tape(&d, range.lo, 1, 0, allocator)
	if merr != nil {
		return {}, merr
	}
	return out_ft, nil
}

@(private = "file")
spec_of_target :: #force_inline proc "contextless" (base: ^tape.Document, target: ^tape.Format) -> Spec {
	if target == as(.Fragment) {
		return .Fragment
	}
	if target == as(.Html) {
		return .Html
	}
	if base != nil && base.format == as(.Fragment) {
		return .Fragment
	}
	return .Html
}

@(private = "file")
html_walk_fragment_cb :: proc(
	data: rawptr,
	src: []u8,
	range: edit.Byte_Range,
	ctx: edit.Fragment_Context,
	allocator: runtime.Allocator,
) -> (edit.Fragment_Tape, tape.Error) {
	eb := (^Edit_Build_Ctx)(data)
	return walk_fragment_with_opts(src, range, ctx, eb.spec, eb.opts, allocator)
}

@(private = "file")
html_full_build_cb :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	eb := (^Edit_Build_Ctx)(data)
	return build(src, eb.spec, eb.opts, allocator)
}

// Validates that committed HTML still builds (parse errors are recovered by HTML5 and verified by `reread_verify`).
@(private = "file")
html_edit_validate_doc :: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error {
	eb := (^Edit_Build_Ctx)(data)
	d, err := build(src, eb.spec, eb.opts, allocator)
	if err == nil {
		tape.destroy(&d)
	}
	return err
}

@(private = "file")
commit_raw_root :: proc(ov: ^Overlay, rn: ^edit.Edit_Node, spec: Spec, build_opts: Options, allocator: runtime.Allocator) -> (Commit_Result, Edit_Error) {
	el := html_element_of(ov.base, tape.ROOT)
	out_len := len(ov.base.src) - int(el.hi - el.lo) + len(rn.val.text)
	bytes, err := runtime.mem_alloc_non_zeroed(out_len, 1, allocator)
	if err != nil {
		return {}, err
	}
	w := 0
	if el.lo > 0 {
		copy(bytes[w:], ov.base.src[:el.lo])
		w += int(el.lo)
	}
	if len(rn.val.text) > 0 {
		copy(bytes[w:], rn.val.text)
		w += len(rn.val.text)
	}
	if int(el.hi) < len(ov.base.src) {
		copy(bytes[w:], ov.base.src[el.hi:])
		w += len(ov.base.src) - int(el.hi)
	}
	splices, serr := make([]edit.Splice_Record, 1, allocator)
	if serr != nil {
		delete(bytes, allocator)
		return {}, serr
	}
	splices[0] = {
		base_node    = tape.ROOT,
		src_lo       = el.lo,
		src_hi       = el.hi,
		dst_lo       = el.lo,
		dst_hi       = el.lo + u64(len(rn.val.text)),
		subtree_only = true,
		full_rewalk  = true,
	}
	if rerr := reread_verify(ov, spec, build_opts, bytes, allocator, true); rerr != nil {
		delete(bytes, allocator)
		delete(splices, allocator)
		return {}, rerr
	}
	return Commit_Result{bytes = bytes, splices = splices, allocator = allocator}, nil
}

@(private = "file")
pre_check_overlay :: proc(ov: ^Overlay, spec: Spec) -> Edit_Error {
	doc := ov.base
	if ov.has_structural && ov.unlinked_parents {
		edit.ensure_linked(ov) or_return
	}
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in html_iter_next(&it) {
		if !n.has_edits {
			continue
		}
		v := n.base
		bv := edit.node_base_container(n)
		if v != tape.NO_NODE {
			if n.state == .Replaced || len(n.facts) > 0 {
				if is_constructed_node(doc, v) {
					return edit.refuse(.Invalid_Result, "cannot edit node implied, moved or copied by tree construction", v)
				}
				if is_split_text(doc, v) {
					return edit.refuse(.Invalid_Result, "cannot edit text split across tags", v)
				}
			}
		}
		if bv != tape.NO_NODE && n.delta != nil {
			check_delta_edits(doc, bv, n.delta) or_return
		}
		void_base := false
		if bv != tape.NO_NODE && bv != tape.ROOT && int(bv) < len(doc.nodes) && key_namespace(doc.nodes[bv - 1]) == .Html {
			vbuf: [64]u8 = ---
			vname, v_owned := key_name_temp(doc, bv - 1, vbuf[:], ov.allocator)
			void_base = is_void_ci(vname)
			if v_owned {
				delete(vname, ov.allocator)
			}
		}
		for f in n.facts {
			if f.deleted {
				continue
			}
			err_node := bv if bv != tape.NO_NODE else v
			#partial switch f.kind {
			case .Comment, .Comment_Inline, .Comment_Foot:
				if f.kind == .Comment_Foot && void_base {
					return edit.refuse(.Fact_No_Place, "void HTML element cannot hold foot comment", err_node)
				}
				for b in f.values {
					if !holds_comment(b) {
						return edit.refuse(.Fact_No_Place, "invalid HTML comment body", err_node)
					}
				}
			case .Attribute:
				if !html_attr_name_ok(ov.base, bv, f.attr) {
					return edit.refuse(.Bad_Name, "invalid HTML attribute name", err_node)
				}
			}
		}
		if n.state == .Replaced {
			check_replaced_subtree(ov, n) or_return
		}
	}
	_ = spec
	return nil
}

@(private = "file")
check_delta_edits :: proc(doc: ^tape.Document, container: tape.Node_Index, d: ^edit.Container_Delta) -> Edit_Error {
	children := make([dynamic]struct{ k, v: tape.Node_Index }, 0, 8, doc.allocator)
	defer delete(children)
	if container != tape.NO_NODE && int(container) < len(doc.nodes) && doc.nodes[container].kind == .Object {
		end := tape.node_after(doc, container)
		for k := container + 1; k < end; {
			v := tape.node_after(doc, k)
			append(&children, struct{ k, v: tape.Node_Index }{k, v})
			k = tape.node_after(doc, v)
		}
	}
	if len(d.order) > 0 {
		for ch in children {
			if is_constructed_node(doc, ch.v) {
				return edit.refuse(.Invalid_Result, "cannot reorder container with constructed element", container)
			}
			if tape.is_text_key(doc.nodes[ch.k]) {
				return edit.refuse(.Layout_Reflow_Needed, "cannot reorder container holding #text", container)
			}
		}
	}
	for ins in d.inserted_members {
		if ins.key != tape.TEXT_KEY && !html_is_name(ins.key) {
			return edit.refuse(.Bad_Name, "invalid HTML element name", container)
		}
		if len(children) == 0 {
			if is_constructed_node(doc, container) {
				return edit.refuse(.Invalid_Result, "cannot insert into empty constructed element", container)
			}
		} else {
			idx := ins.at if ins.at >= 0 && ins.at < len(children) else len(children) - 1
			if is_constructed_node(doc, children[idx].v) {
				return edit.refuse(.Invalid_Result, "cannot insert beside constructed element", container)
			}
		}
	}
	buf: [256]u8 = ---
	for dk in d.deleted_keys {
		for ch in children {
			ck, ck_owned := key_name_temp(doc, ch.k, buf[:], doc.allocator)
			matched := ck == dk
			if ck_owned {
				delete(ck, doc.allocator)
			}
			if matched && is_constructed_node(doc, ch.v) {
				return edit.refuse(.Invalid_Result, "cannot delete constructed element", ch.v)
			}
		}
	}
	for r in d.renamed_members {
		if r.new_key != tape.TEXT_KEY && !html_is_name(r.new_key) {
			return edit.refuse(.Bad_Name, "invalid HTML element name", container)
		}
		for ch in children {
			ck, ck_owned := key_name_temp(doc, ch.k, buf[:], doc.allocator)
			matched := ck == r.old_key
			if ck_owned {
				delete(ck, doc.allocator)
			}
			if matched && is_constructed_node(doc, ch.v) {
				return edit.refuse(.Invalid_Result, "cannot rename constructed element", ch.v)
			}
		}
	}
	return nil
}

@(private = "file")
check_replaced_subtree :: proc(ov: ^Overlay, root_n: ^edit.Edit_Node) -> Edit_Error {
	stack := make([dynamic]Handle, 0, 8, ov.allocator)
	defer delete(stack)
	append(&stack, root_n.handle)
	for len(stack) > 0 {
		h := pop(&stack)
		n, ok := edit.get_node(ov, h)
		if !ok {
			continue
		}
		if n.state == .Replaced {
			if n.val.kind == .Object {
				for m in n.members {
					if m.key != tape.TEXT_KEY && !html_is_name(m.key) {
						return edit.refuse(.Bad_Name, "invalid HTML element name", n.base)
					}
					append(&stack, m.value)
				}
			} else if n.val.kind == .Array {
				for eh in n.elems {
					append(&stack, eh)
				}
			}
		}
	}
	return nil
}

@(private = "file")
is_constructed_node :: proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> bool {
	if v == tape.ROOT || v == tape.NO_NODE || int(v) >= len(doc.nodes) {
		return false
	}
	k, n := doc.nodes[v - 1], doc.nodes[v]
	if k.role == .Key && key_is_frozen(k) {
		return true
	}
	return n.kind == .Plain && n.spelling & TEXT_FROZEN != 0
}

@(private = "file")
is_split_text :: proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> bool {
	if v == tape.NO_NODE || int(v) >= len(doc.nodes) {
		return false
	}
	n := doc.nodes[v]
	if n.kind != .Plain || n.spelling & TEXT_PIECES == 0 || doc.ext == nil {
		return false
	}
	b, head, entry, ok := find_text_entry(&doc.ext.format, n.lo)
	if !ok {
		return false
	}
	for i in 1 ..< entry.count {
		prev := load_piece(b, head, entry.first + i - 1)
		cur := load_piece(b, head, entry.first + i)
		end := prev.lo + u64(prev.n)
		hi := max(cur.lo, end)
		if hi > end && hi <= u64(len(doc.src)) {
			gap := doc.src[end:hi]
			for c, k in gap {
				if c == '<' && k + 1 < len(gap) && ((gap[k + 1] | 0x20) - 'a' < 26) {
					return true
				}
			}
		}
	}
	return false
}

@(private = "file")
is_void_ci :: proc "contextless" (name: string) -> bool {
	if len(name) < 2 || len(name) > 8 {
		return false
	}
	lower: [8]u8 = ---
	for i in 0 ..< len(name) {
		c := name[i]
		lower[i] = c | 0x20 if c - 'A' < 26 else c
	}
	return is_void_name(string(lower[:len(name)]))
}

@(private = "file")
html_is_name :: proc "contextless" (s: string) -> bool {
	return is_html_name(s)
}

// `Markup_Spec.is_name` allows ASCII letters inside attribute names (pre-pass checks all element names for lowercase).
@(private = "file")
html_is_markup_name_bytes :: proc "contextless" (name: []u8) -> bool {
	if len(name) == 0 {
		return false
	}
	for c in name {
		if is_space(c) || c == '/' || c == '>' || c == '=' || c == '"' || c == '\'' || c == '<' || c == 0 || c < 0x20 {
			return false
		}
	}
	return true
}

@(private = "file")
html_attr_name_ok :: proc(doc: ^tape.Document, v: tape.Node_Index, attr: string) -> bool {
	if len(attr) == 0 || !html_is_markup_name_bytes(transmute([]u8)attr) {
		return false
	}
	if v != tape.NO_NODE && int(v) < len(doc.nodes) {
		for bf in tape.facts_of(doc, v) {
			if bf.kind == .Attribute {
				kt, _ := attribute(doc, bf)
				if string(tape.span_bytes(doc, kt.lo, kt.n)) == attr {
					return true
				}
			}
		}
		if v != tape.ROOT && doc.nodes[v - 1].role == .Key {
			ns := key_namespace(doc.nodes[v - 1])
			if ns != .Html {
				fi := foreign_of(raw_data(attr), u32(len(attr)))
				if fi > 0 && FOREIGN_NAMES[fi].name == attr {
					kinds := FOREIGN_NAMES[fi].kinds
					if .Foreign_Attribute in kinds || (.Svg_Attribute in kinds && ns == .Svg) || (.Math_Attribute in kinds && ns == .Math) {
						return true
					}
				}
			}
		}
	}
	for c in transmute([]u8)attr {
		if 'A' <= c && c <= 'Z' {
			return false
		}
	}
	return true
}

@(private = "file")
html_spell_attr_val :: proc(data: rawptr, val: string, quote: u8, out: ^[dynamic]u8) -> edit.Error {
	_ = data
	for i := 0; i < len(val); i += 1 {
		c := val[i]
		if c == '&' {
			append(out, "&amp;")
		} else if c == 0xC2 && i + 1 < len(val) && val[i + 1] == 0xA0 {
			append(out, "&nbsp;")
			i += 1
		} else if c == '"' && quote == '"' {
			append(out, "&quot;")
		} else if c == '\'' && quote == '\'' {
			append(out, "&#39;")
		} else {
			append(out, c)
		}
	}
	return nil
}

@(private = "file")
spell_scalar_text_into :: proc(txt, ename: string, enclosing_raw, enclosing_keeps: bool, out: ^[dynamic]u8) -> edit.Error {
	if enclosing_keeps && strings.has_prefix(txt, "\n") {
		append(out, '\n')
	}
	if !enclosing_raw || ename == "title" || ename == "textarea" {
		return spell_html_text(txt, out)
	}
	append(out, txt)
	return nil
}

@(private = "file")
html_spell_content :: proc(data: rawptr, ov: ^Overlay, h: Handle, out: ^[dynamic]u8) -> edit.Error {
	eb := (^Edit_Build_Ctx)(data)
	build_opts := eb.opts if eb != nil else Options{}
	if h == edit.NO_HANDLE {
		return nil
	}
	n, has_n := edit.get_node(ov, h)
	if !has_n {
		return nil
	}
	if edit.node_kind(ov, h) == .Null {
		return nil
	}

	ename := ""
	ename_owned := false
	ebuf: [128]u8 = ---
	enclosing_ns := Namespace.Html
	enclosing_raw := false
	enclosing_keeps := false
	if n.base != tape.NO_NODE && n.base != tape.ROOT && int(n.base) < len(ov.base.nodes) {
		ename, ename_owned = key_name_temp(ov.base, n.base - 1, ebuf[:], ov.allocator)
		enclosing_ns = key_namespace(ov.base.nodes[n.base - 1])
		enclosing_raw = enclosing_ns == .Html && (is_raw_name(ename) || ename == "title" || ename == "textarea")
		enclosing_keeps = enclosing_ns == .Html && keeps_space_name(ename)
	}
	defer if ename_owned {
		delete(ename, ov.allocator)
	}

	if n.state == .Replaced && n.val.kind == .Raw {
		if enclosing_raw && strings.contains_any(n.val.text, "<&" if is_raw_name(ename) else "<") {
			return edit.refuse(.Text_Markup, "rawtext element cannot contain markup", n.base)
		}
		append(out, n.val.text)
		return nil
	}

	// Scalar fast path (zero materialization).
	if n.state == .Replaced && n.val.kind < .Array {
		buf: [64]u8 = ---
		txt := scalar_edit_val_str(&n.val, buf[:])
		return spell_scalar_text_into(txt, ename, enclosing_raw, enclosing_keeps, out)
	}

	// Base_Ref scalar fast path (preserves enclosing rawtext/keeps_space context when moving e.g. <script> text to <p>).
	if n.state == .Replaced && n.val.kind == .Base_Ref {
		bn_idx := n.val.base_ref
		if bn_idx != tape.NO_NODE && int(bn_idx) < len(ov.base.nodes) && ov.base.nodes[bn_idx].kind < .Array {
			sc := make([dynamic]u8, 0, 64, ov.allocator)
			defer delete(sc)
			txt := scalar_string(ov.base, bn_idx, &sc)
			return spell_scalar_text_into(txt, ename, enclosing_raw, enclosing_keeps, out)
		}
	}

	tmp_doc := edit.materialize_subtree(ov, h, tape.NO_NODE, {
		wrap_key        = "_",
		xml_attrs       = true,
		skip_root_attrs = true,
		target_format   = as(.Html),
	}, ov.allocator) or_return
	defer tape.destroy(&tmp_doc)

	// `write_unverified` skips element-name validation when `tmp_doc.format == as(.Html)`; check all child keys explicitly (skip index 1 wrapper `"_"`).
	for nd, ni in tmp_doc.nodes {
		if ni <= 1 || nd.role != .Key {
			continue
		}
		kname := tape.span_bytes(&tmp_doc, nd.lo, nd.n)
		if string(kname) != tape.TEXT_KEY && !is_html_name(string(kname)) {
			// Allow mixed-case foreign SVG/MathML tags cloned from base doc inside a foreign context.
			fi := foreign_of(raw_data(kname), u32(len(kname)))
			if !(fi > 0 && FOREIGN_NAMES[fi].name == string(kname)) {
				return edit.refuse(.Bad_Name, "invalid HTML element name", n.base)
			}
		}
	}

	encoded, werr := write_unverified(&tmp_doc, {}, ov.allocator)
	if werr != nil {
		#partial switch e in werr {
		case runtime.Allocator_Error:
			return e
		case tape.Bad_Option:
			return e
		}
		return edit.refuse(.Unspellable_Value, "value cannot be serialized as HTML")
	}
	defer delete(encoded, ov.allocator)

	s := string(encoded)
	if strings.has_prefix(s, "<_>") && strings.has_suffix(s, "</_>") {
		s = s[3 : len(s) - 4]
	}
	if ename != "" && len(s) > 0 {
		frag, ferr := build_fragment(transmute([]u8)s, {context_name = ename, context_namespace = enclosing_ns}, build_opts, ov.allocator)
		if ferr != nil {
			return edit.refuse(.Unspellable_Value, "value cannot read back in target HTML element", n.base)
		}
		defer tape.destroy(&frag)
		again, aerr := write_unverified(&frag, {}, ov.allocator)
		if aerr != nil {
			return edit.refuse(.Unspellable_Value, "value does not round-trip in target HTML element", n.base)
		}
		defer delete(again, ov.allocator)
		if string(again) != s {
			return edit.refuse(.Unspellable_Value, "value reads back as different HTML elements in target context", n.base)
		}
	}
	append(out, s)
	return nil
}

@(private = "file")
scalar_edit_val_str :: proc(v: ^Edit_Value, buf: []u8) -> string {
	#partial switch v.kind {
	case .String, .Number_Text, .Raw:
		return v.text
	case .True:
		return "true"
	case .False:
		return "false"
	case .Int:
		return strconv.write_int(buf, v.i, 10)
	case .Uint:
		return strconv.write_uint(buf, v.u, 10)
	case .Float:
		return strconv.write_float(buf, v.f, 'g', -1, 64, {})
	}
	return ""
}

@(private = "file")
spell_html_text :: proc(s: string, out: ^[dynamic]u8) -> edit.Error {
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '&' {
			append(out, "&amp;")
		} else if c == '<' {
			append(out, "&lt;")
		} else if c == '>' {
			append(out, "&gt;")
		} else if c == 0xC2 && i + 1 < len(s) && s[i + 1] == 0xA0 {
			append(out, "&nbsp;")
			i += 1
		} else {
			append(out, c)
		}
	}
	return nil
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
	if n.kind == .Plain && n.spelling & TEXT_PIECES != 0 {
		c = max(e.open, min(c, text_before_read_on(doc, n.lo)))
	}
	for f in tape.facts_of(doc, v) {
		if (f.kind == .Comment || f.kind == .Instruction) && f.lo >= e.open {
			c = max(c, f.lo + u64(f.n))
		}
	}
	e.close, e.hi = c, c
	if k.n > 0 && end_tag_matches_key(doc, k, c) {
		e.hi, e.end_tag = html_tag_end(src, c), true
	} else if k.n > 0 && key_namespace(k) != .Html && c == e.open && e.open >= 2 && src[e.open - 2] == '/' {
		e.open, e.close, e.empty = e.open - 2, e.open - 2, true
	}
	return e
}

@(private = "file")
html_element_of :: proc "contextless" (doc: ^tape.Document, v_in: tape.Node_Index) -> (e: edit.Markup_Element) {
	src := doc.src
	v := v_in
	if v == tape.ROOT {
		if doc.format == as(.Fragment) {
			e.close, e.hi = u64(len(src)), u64(len(src))
			return e
		}
		if len(doc.nodes) > 2 {
			v = tape.ROOT + 2
		} else {
			return {}
		}
	}
	k, n := doc.nodes[v - 1], doc.nodes[v]
	if n.kind != .Object {
		return leaf_element_of(doc, v)
	}
	if k.n == 0 {
		e.lo, e.name, e.open = k.lo, k.lo, k.lo
	} else {
		e.lo, e.name = k.lo - 1, k.lo + u64(k.n)
		e.open = html_tag_end(src, e.lo)
	}
	e.hi, _ = close_end(doc, v)
	e.close = e.hi
	last := tape.NO_NODE
	end := tape.node_after(doc, v)
	for ck := v + 1; ck < end; {
		cv := tape.node_after(doc, ck)
		last = cv
		ck = tape.node_after(doc, cv)
	}
	after := e.open
	if last != tape.NO_NODE {
		if doc.nodes[last].kind == .Object {
			after, _ = close_end(doc, last)
		} else if tape.is_text_key(doc.nodes[last - 1]) {
			ln := doc.nodes[last]
			after = ln.lo + u64(ln.n)
			if ln.kind == .Plain && ln.spelling & TEXT_PIECES != 0 {
				after = min(after, text_before_read_on(doc, ln.lo))
			}
		} else {
			after = leaf_element_of(doc, last).hi
		}
	}
	for lt := e.hi; lt > after; lt -= 1 {
		if src[lt - 1] == '<' {
			if end_tag_matches_key(doc, k, lt - 1) && html_tag_end(src, lt - 1) == e.hi {
				e.close, e.end_tag = lt - 1, true
			}
			break
		}
	}
	return e
}

// End of the text at `lo` before any trailing discontiguous whitespace pieces read past ignored tags.
@(private = "file")
text_before_read_on :: proc "contextless" (doc: ^tape.Document, lo: u64) -> u64 {
	if doc.ext == nil {
		return lo
	}
	b, head, entry, ok := find_text_entry(&doc.ext.format, lo)
	if !ok || entry.count == 0 {
		return lo
	}
	k := entry.count - 1
	for k > 0 {
		cur := load_piece(b, head, entry.first + k)
		prev := load_piece(b, head, entry.first + k - 1)
		if cur.lo <= prev.lo + u64(prev.n) {
			break
		}
		all_ws := true
		if cur.lo + u64(cur.n) <= u64(len(doc.src)) {
			for c in doc.src[cur.lo:][:cur.n] {
				if !is_space(c) {
					all_ws = false
					break
				}
			}
		}
		if !all_ws {
			return cur.lo + u64(cur.n)
		}
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
		if quote != 0 {
			if c == quote {
				quote = 0
			}
			continue
		}
		if c == '"' || c == '\'' {
			quote = c
		} else if c == '>' {
			return i + 1
		}
	}
	return u64(len(src))
}

@(private = "file")
end_tag_at :: proc "contextless" (src: []u8, at: u64, name: string) -> bool {
	lo := at + 2
	hi := lo + u64(len(name))
	if hi >= u64(len(src)) || src[at] != '<' || src[at + 1] != '/' || !fold_name_equal(src[lo:hi], name) {
		return false
	}
	return is_space(src[hi]) || src[hi] == '/' || src[hi] == '>'
}

@(private = "file")
end_tag_matches_key :: proc "contextless" (doc: ^tape.Document, k: tape.Token, at: u64) -> bool {
	src := doc.src
	if at + 2 >= u64(len(src)) || src[at] != '<' || src[at + 1] != '/' {
		return false
	}
	if fx := table_key_text(src, k); len(fx) > 0 {
		return end_tag_at(src, at, fx)
	}
	if k.n == 0 {
		return false
	}
	if k.spelling & tape.SPELLING_DECODE == 0 && .Held not_in doc.flags {
		return end_tag_at(src, at, string(src[k.lo:][:k.n]))
	}
	buf: [256]u8 = ---
	if s, ok := tape.node_text(doc, k, buf[:]); ok {
		return end_tag_at(src, at, s)
	}
	if .Held not_in doc.flags && k.lo + u64(k.n) <= u64(len(src)) {
		sp := src[k.lo:][:k.n]
		lax := k.spelling & tape.SPELLING_LAX != 0
		pos := at + 2
		i := 0
		for i < len(sp) {
			c := sp[i]
			if lax && c == 0 {
				if pos + 3 > u64(len(src)) || src[pos] != 0xEF || src[pos + 1] != 0xBF || src[pos + 2] != 0xBD {
					return false
				}
				pos += 3
				i += 1
				continue
			}
			if pos >= u64(len(src)) {
				return false
			}
			sc := src[pos]
			lc := c | 0x20 if c - 'A' < 26 else c
			lsc := sc | 0x20 if sc - 'A' < 26 else sc
			if lc != lsc {
				return false
			}
			pos += 1
			i += 1
		}
		return pos < u64(len(src)) && (is_space(src[pos]) || src[pos] == '/' || src[pos] == '>')
	}
	return false
}

// ========================================================================================================
// Read-on detection and two-pass trimming / excision for omitted end tags (`<p>a</body></html>\n`, etc.).
// ========================================================================================================

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
		if !n.has_edits || n.state != .Replaced || n.base == tape.NO_NODE || n.base == tape.ROOT {
			continue
		}
		if tape.is_text_key(doc.nodes[n.base - 1]) {
			continue
		}
		el := html_element_of(doc, n.base)
		ename, ename_owned := key_name_temp(doc, n.base - 1, ebuf[:], allocator)
		skip := (el.end_tag && ename != "body") || el.close >= u64(len(doc.src))
		if ename_owned {
			delete(ename, allocator)
		}
		if skip {
			continue
		}
		if err := ensure_html_parents(ov); err != nil {
			destroy_read_ons(&out, allocator)
			return {}, err
		}
		tail := text_past(doc, ov.parents, n.base, el.close, allocator)
		if len(tail) == 0 {
			continue
		}
		joined := 0
		for sp in tail {
			joined += int(sp.hi - sp.lo)
		}
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
	for &ro in items {
		if ro.tail != nil {
			delete(ro.tail, allocator)
		}
		if ro.trimmed != "" {
			delete(ro.trimmed, allocator)
		}
	}
	delete(items^)
}

@(private = "file")
apply_keep_trim :: proc(ov: ^Overlay, items: []Read_On_Edit) -> bool {
	kept := false
	for &ro in items {
		if !ro.can_trim {
			continue
		}
		n := ro.node
		ro.old_val = n.val
		ro.old_inline = n.val_inline
		ro.old_buf = n.inline_buf
		n.val = edit.val_string(ro.trimmed)
		n.val_inline = false
		_ = ov
		kept = true
	}
	return kept
}

@(private = "file")
restore_keep_trim :: proc(items: []Read_On_Edit) {
	for &ro in items {
		if !ro.can_trim {
			continue
		}
		n := ro.node
		n.val = ro.old_val
		n.val_inline = ro.old_inline
		n.inline_buf = ro.old_buf
	}
}

@(private = "file")
ends_with_byte_ranges :: proc(text: string, src: []u8, spans: []edit.Byte_Range) -> bool {
	at := len(text)
	#reverse for sp in spans {
		n := int(sp.hi - sp.lo)
		if at < n || string(src[sp.lo:sp.hi]) != text[at - n:at] {
			return false
		}
		at -= n
	}
	return true
}

@(private = "file")
text_past :: proc(doc: ^tape.Document, parents: []tape.Node_Index, v: tape.Node_Index, close: u64, allocator: runtime.Allocator) -> [dynamic]edit.Byte_Range {
	Past :: struct {
		src:       []u8,
		name:      string,
		closes:    [dynamic]u64,
		texts:     [dynamic]edit.Byte_Range,
		allocator: runtime.Allocator,
		ctx:       runtime.Context,
	}
	on :: proc "contextless" (p: ^Past, t: ^Html_Token) -> Token_Action {
		context = p.ctx
		context.allocator = p.allocator
		#partial switch t.kind {
		case .Text:
			append(&p.texts, edit.Byte_Range{lo = t.lo, hi = t.hi})
		case .Comment, .Error:
		case .End_Tag:
			name := p.src[t.name.lo:][:t.name.n]
			if fold_name_equal(name, "body") || fold_name_equal(name, "html") {
				return .Next
			}
			if fold_name_equal(name, p.name) {
				return .Stop
			}
			if slice.contains(p.closes[:], t.lo) {
				return .Stop
			}
		case:
			return .Stop
		}
		return .Next
	}
	nbuf: [128]u8 = ---
	name, name_owned := key_name_temp(doc, v - 1, nbuf[:], allocator)
	defer if name_owned {
		delete(name, allocator)
	}
	p := Past {
		src       = doc.src,
		name      = name,
		closes    = make([dynamic]u64, 0, 8, allocator),
		texts     = make([dynamic]edit.Byte_Range, 0, 4, allocator),
		allocator = allocator,
		ctx       = context,
	}
	defer delete(p.closes)
	if parents != nil {
		for a := parents[v]; a != tape.ROOT && a != tape.NO_NODE; a = parents[a] {
			if doc.nodes[a].kind == .Object {
				if el := html_element_of(doc, a); el.end_tag {
					append(&p.closes, el.close)
				}
			}
		}
	}
	_, _, _ = tokenize(doc.src, &p, on, from = close, allocator = allocator)
	return p.texts
}

@(private = "file")
apply_read_on_cuts :: proc(res: ^Commit_Result, items: []Read_On_Edit, allocator: runtime.Allocator) -> edit.Error {
	Cut_Span :: struct {
		src_lo, src_hi: u64,
		pre_lo, pre_hi: u64,
		base_node:      tape.Node_Index,
	}
	cuts := make([dynamic]Cut_Span, 0, 4, allocator)
	defer delete(cuts)
	for ro in items {
		for sp in ro.tail {
			covered := false
			shift := i64(0)
			for sr in res.splices {
				if sp.lo >= sr.src_lo && sp.hi <= sr.src_hi {
					covered = true
					break
				}
				if sr.src_hi <= sp.lo {
					shift += i64(sr.dst_hi - sr.dst_lo) - i64(sr.src_hi - sr.src_lo)
				}
			}
			if covered {
				continue
			}
			dst_lo := u64(i64(sp.lo) + shift)
			dst_hi := u64(i64(sp.hi) + shift)
			if dst_hi <= u64(len(res.bytes)) && dst_lo < dst_hi {
				append(&cuts, Cut_Span{
					src_lo    = sp.lo,
					src_hi    = sp.hi,
					pre_lo    = dst_lo,
					pre_hi    = dst_hi,
					base_node = ro.node.base,
				})
			}
		}
	}
	if len(cuts) == 0 {
		return nil
	}
	slice.sort_by(cuts[:], proc(a, b: Cut_Span) -> bool {
		if a.pre_lo != b.pre_lo {
			return a.pre_lo < b.pre_lo
		}
		return a.src_lo < b.src_lo
	})
	merged := make([dynamic]Cut_Span, 0, len(cuts), allocator)
	defer delete(merged)
	for c in cuts {
		if len(merged) == 0 || c.pre_lo > merged[len(merged) - 1].pre_hi {
			append(&merged, c)
		} else {
			prev := &merged[len(merged) - 1]
			// Do not merge across an insertion splice at the boundary if `src` offsets would jump over an edit splice.
			has_boundary_sr := false
			if c.pre_lo == prev.pre_hi && c.src_lo > prev.src_hi {
				for sr in res.splices {
					if sr.src_lo >= prev.src_hi && sr.src_hi <= c.src_lo {
						has_boundary_sr = true
						break
					}
				}
			}
			if has_boundary_sr {
				append(&merged, c)
			} else {
				if c.pre_hi > prev.pre_hi {
					prev.pre_hi = c.pre_hi
				}
				if c.src_hi > prev.src_hi {
					prev.src_hi = c.src_hi
				}
				if c.src_lo < prev.src_lo {
					prev.src_lo = c.src_lo
				}
			}
		}
	}
	drop_len := 0
	for c in merged {
		drop_len += int(c.pre_hi - c.pre_lo)
	}
	new_bytes, err := runtime.mem_alloc_non_zeroed(len(res.bytes) - drop_len, 1, allocator)
	if err != nil {
		return err
	}
	new_splices, serr := make([]edit.Splice_Record, len(res.splices) + len(merged), allocator)
	if serr != nil {
		delete(new_bytes, allocator)
		return serr
	}

	pos := u64(0)
	w := 0
	for c in merged {
		if c.pre_lo > pos {
			n := int(c.pre_lo - pos)
			copy(new_bytes[w:], res.bytes[pos:c.pre_lo])
			w += n
		}
		pos = c.pre_hi
	}
	if pos < u64(len(res.bytes)) {
		copy(new_bytes[w:], res.bytes[pos:])
	}

	cut_before_pos := proc "contextless" (merged: []Cut_Span, p: u64, src_p: u64, check_src: bool) -> u64 {
		acc := u64(0)
		for c in merged {
			if c.pre_hi < p || (c.pre_hi == p && (!check_src || c.src_hi <= src_p)) {
				acc += c.pre_hi - c.pre_lo
			} else {
				break
			}
		}
		return acc
	}

	for &rw in res.rewritten {
		lo_drop := cut_before_pos(merged[:], rw.lo, 0, false)
		hi_drop := cut_before_pos(merged[:], rw.hi, 0, false)
		rw.lo -= lo_drop
		rw.hi -= hi_drop
	}

	si := 0
	for sr in res.splices {
		drop := cut_before_pos(merged[:], sr.dst_lo, sr.src_lo, true)
		adj := sr
		adj.dst_lo -= drop
		adj.dst_hi -= drop
		adj.full_rewalk = true
		new_splices[si] = adj
		si += 1
	}
	for c in merged {
		drop := cut_before_pos(merged[:], c.pre_lo, c.src_lo, true)
		adj_pos := c.pre_lo - drop
		new_splices[si] = edit.Splice_Record {
			base_node    = c.base_node,
			src_lo       = c.src_lo,
			src_hi       = c.src_hi,
			dst_lo       = adj_pos,
			dst_hi       = adj_pos,
			subtree_only = false,
			full_rewalk  = true,
		}
		si += 1
	}
	slice.sort_by(new_splices, proc(a, b: edit.Splice_Record) -> bool {
		if a.src_lo != b.src_lo {
			return a.src_lo < b.src_lo
		}
		if a.dst_lo != b.dst_lo {
			return a.dst_lo < b.dst_lo
		}
		return a.src_hi < b.src_hi
	})

	delete(res.bytes, allocator)
	delete(res.splices, allocator)
	res.bytes = new_bytes
	res.splices = new_splices
	return nil
}

// ========================================================================================================
// Iterative full reread verification (`reread_verify`).
// ========================================================================================================

@(private = "file")
is_safe_ascii_scalar :: proc "contextless" (txt: string, no_markup: bool) -> bool {
	if len(txt) == 0 || is_space(txt[0]) || is_space(txt[len(txt) - 1]) {
		return false
	}
	for c in transmute([]u8)txt {
		if c < 0x20 || c >= 0x80 {
			return false
		}
		if no_markup && (c == '<' || c == '>' || c == '&') {
			return false
		}
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
			if !n.has_edits || (n.state == .Ancestor && len(n.facts) == 0) {
				continue
			}
			if len(n.facts) > 0 || n.state != .Replaced || n.base == tape.NO_NODE || n.base == tape.ROOT {
				simple = false
				break
			}
			bn := ov.base.nodes[n.base]
			if bn.kind >= .Array || bn.kind == .Null {
				simple = false
				break
			}
			if n.val.kind >= .Array || n.val.kind == .Null || n.val.kind == .Base_Ref {
				simple = false
				break
			}
			if tape.is_text_key(ov.base.nodes[n.base - 1]) {
				simple = false
				break
			}
			ename, ename_owned := key_name_temp(ov.base, n.base - 1, ebuf[:], allocator)
			bad_ctx := key_namespace(ov.base.nodes[n.base - 1]) != .Html || is_void_ci(ename) || keeps_space_name(ename) || ename == "plaintext"
			raw_ctx := n.val.kind == .Raw || is_raw_name(ename) || ename == "title" || ename == "textarea"
			if ename_owned {
				delete(ename, allocator)
			}
			if bad_ctx {
				simple = false
				break
			}
			el := html_element_of(ov.base, n.base)
			if !el.end_tag {
				simple = false
				break
			}
			buf: [64]u8 = ---
			txt := scalar_edit_val_str(&n.val, buf[:])
			if !is_safe_ascii_scalar(txt, raw_ctx) {
				simple = false
				break
			}
		}
		if simple {
			return nil
		}
	}

	built, berr := build(out, spec, build_opts, allocator)
	if berr != nil {
		if aerr, is_a := berr.(runtime.Allocator_Error); is_a {
			return aerr
		}
		return edit.refuse(.Invalid_Result, "edited output failed HTML parse")
	}
	defer tape.destroy(&built)

	if len(ov.base.nodes) == 0 || len(built.nodes) == 0 {
		return edit.refuse(.Invalid_Result, "edited output produced empty HTML tree")
	}

	if spec == .Html {
		if count_elem_children(&built, tape.ROOT) != 1 || count_elem_children(&built, tape.ROOT) != count_elem_children(ov.base, tape.ROOT) {
			return edit.refuse(.Invalid_Result, "edited document root does not hold single html element")
		}
	}

	if !verify_subtree_counts(ov, &built, tape.ROOT, tape.ROOT, build_opts, allocator) {
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
	if ov.parents != nil {
		return nil
	}
	n := len(ov.base.nodes)
	p := make([]tape.Node_Index, n, ov.allocator) or_return
	slice.fill(p, tape.NO_NODE)
	Frame :: struct {
		node, end: tape.Node_Index,
	}
	st := make([dynamic]Frame, 0, 32, ov.allocator)
	defer delete(st)
	if n > 0 && ov.base.nodes[0].kind > .Plain {
		append(&st, Frame{0, tape.Node_Index(ov.base.nodes[0].n)})
	}
	for i := tape.Node_Index(1); int(i) < n; {
		for len(st) > 0 && st[len(st) - 1].end <= i {
			_ = pop(&st)
		}
		parent := st[len(st) - 1].node if len(st) > 0 else tape.ROOT
		p[i] = parent
		nd := ov.base.nodes[i]
		if nd.role == .Key {
			val := i + 1
			if int(val) < n {
				p[val] = parent
				if ov.base.nodes[val].kind > .Plain {
					append(&st, Frame{val, val + tape.Node_Index(ov.base.nodes[val].n)})
				}
			}
			i += 2
			continue
		}
		if nd.kind > .Plain {
			append(&st, Frame{i, i + tape.Node_Index(nd.n)})
		}
		i += 1
	}
	ov.parents = p
	return nil
}

@(private = "file")
Verify_Pair :: struct {
	a, b:      tape.Node_Index,
	follow_ov: bool,
}

@(private = "file")
verify_subtree_counts :: proc(ov: ^Overlay, built: ^tape.Document, a, b: tape.Node_Index, build_opts: Options, allocator: runtime.Allocator) -> bool {
	stack := make([dynamic]Verify_Pair, 0, 16, allocator)
	defer delete(stack)
	append(&stack, Verify_Pair{a, b, true})

	for len(stack) > 0 {
		pair := pop(&stack)
		base_n := ov.base.nodes[pair.a]
		built_n := built.nodes[pair.b]

		cn: ^edit.Edit_Node
		has_cn := false
		if pair.follow_ov {
			if ch, has := ov.by_base[pair.a]; has {
				cn, has_cn = edit.get_node(ov, ch)
			}
		}

		if has_cn && cn.has_edits && has_attr_fact(cn) {
			if !verify_edited_attributes(ov.base, pair.a, cn, built, pair.b, allocator) {
				return false
			}
		} else if !same_attributes(ov.base, pair.a, built, pair.b) {
			return false
		}

		if has_cn && cn.has_edits && cn.state == .Replaced {
			if !verify_replaced_node(ov, built, pair.b, cn, build_opts, allocator) {
				return false
			}
			continue
		}

		if has_cn && cn.has_edits && cn.state == .Container_Delta && cn.delta != nil {
			if built_n.kind != .Object {
				return false
			}
			if !verify_container_delta(ov, built, pair.a, pair.b, cn.delta, &stack, build_opts, true, allocator) {
				return false
			}
			continue
		}

		if base_n.kind != built_n.kind {
			if !(has_cn && len(cn.facts) > 0 && base_n.kind <= .Plain && base_n.kind != .Null && built_n.kind <= .Plain && built_n.kind != .Null) {
				return false
			}
		}
		if base_n.kind != .Object {
			sa := scalar_alloc(ov.base, pair.a, allocator)
			sb := scalar_alloc(built, pair.b, allocator)
			ok := sa == sb
			delete(sa, allocator)
			delete(sb, allocator)
			if !ok {
				return false
			}
			continue
		}

		ca := collect_children_pairs(ov.base, pair.a, allocator)
		cb := collect_children_pairs(built, pair.b, allocator)
		defer {
			delete(ca, allocator)
			delete(cb, allocator)
		}
		// Base containers can contain an array-replaced child whose extra siblings were dropped in `built`.
		expected := make([dynamic]Verify_Item, 0, len(ca), allocator)
		defer delete(expected)
		array_rep := make([dynamic]string, 0, 2, allocator)
		defer delete(array_rep)
		for cp in ca {
			kn := scalar_alloc(ov.base, cp.k, allocator)
			defer delete(kn, allocator)
			is_txt := tape.is_text_key(ov.base.nodes[cp.k])
			if !is_txt && slice.contains(array_rep[:], kn) {
				continue
			}
			if pair.follow_ov {
				if ch, h_ok := ov.by_base[cp.v]; h_ok {
					if chn, cok := edit.get_node(ov, ch); cok && chn.has_edits && chn.state == .Replaced && chn.val.kind == .Array && !is_txt {
						append(&array_rep, scalar_alloc(ov.base, cp.k, allocator))
						append(&expected, Verify_Item{base_k = cp.k, base_v = cp.v, is_arr_rep = true, arr_elems = chn.elems[:]})
						continue
					}
				}
			}
			append(&expected, Verify_Item{base_k = cp.k, base_v = cp.v})
		}
		defer for rep_s in array_rep {
			delete(rep_s, allocator)
		}
		bi := 0
		for item in expected {
			if item.is_arr_rep {
				for eh in item.arr_elems {
					if bi >= len(cb) || !same_key(ov.base, item.base_k, built, cb[bi].k, allocator) {
						return false
					}
					if !verify_edit_handle(ov, eh, built, cb[bi].v, build_opts, allocator) {
						return false
					}
					bi += 1
				}
				continue
			}
			if bi >= len(cb) || !same_key(ov.base, item.base_k, built, cb[bi].k, allocator) {
				return false
			}
			append(&stack, Verify_Pair{item.base_v, cb[bi].v, pair.follow_ov})
			bi += 1
		}
		if bi != len(cb) {
			return false
		}
	}
	return true
}

@(private = "file")
verify_container_delta :: proc(
	ov: ^Overlay,
	built: ^tape.Document,
	a, b: tape.Node_Index,
	d: ^edit.Container_Delta,
	stack: ^[dynamic]Verify_Pair,
	build_opts: Options,
	follow_by_base: bool,
	allocator: runtime.Allocator,
) -> bool {
	ca := collect_children_pairs(ov.base, a, allocator)
	cb := collect_children_pairs(built, b, allocator)
	defer {
		delete(ca, allocator)
		delete(cb, allocator)
	}

	items := make([dynamic]Verify_Item, 0, len(ca) + len(d.inserted_members), allocator)
	array_rep := make([dynamic]string, 0, 2, allocator)
	owned_names := make([dynamic]string, 0, len(ca), allocator)
	defer {
		for s in array_rep { delete(s, allocator) }
		for s in owned_names { delete(s, allocator) }
		delete(array_rep)
		delete(owned_names)
		delete(items)
	}

	base_items := make([dynamic]Verify_Item, 0, len(ca), allocator)
	defer delete(base_items)
	for cp, idx in ca {
		is_txt := tape.is_text_key(ov.base.nodes[cp.k])
		kname := scalar_alloc(ov.base, cp.k, allocator)
		append(&owned_names, kname)
		del := false
		for dk in d.deleted_keys {
			if dk == kname {
				del = true
				break
			}
		}
		if !del && !is_txt {
			for rep_s in array_rep {
				if rep_s == kname {
					del = true
					break
				}
			}
		}
		eff_name := kname
		renamed := false
		if !del {
			for r in d.renamed_members {
				if r.old_key == kname {
					eff_name = r.new_key
					renamed = true
					break
				}
			}
		}
		it := Verify_Item {
			key_name = eff_name,
			renamed  = renamed,
			is_text  = is_txt,
			src_lo   = ov.base.nodes[cp.v].lo,
			seq      = idx * 2 + 1,
			base_k   = cp.k,
			base_v   = cp.v,
		}
		if del {
			it.base_k = tape.NO_NODE // mark deleted
		} else if follow_by_base {
			if ch, has := ov.by_base[cp.v]; has {
				if chn, cok := edit.get_node(ov, ch); cok && chn.has_edits && chn.state == .Replaced && chn.val.kind == .Array && !is_txt {
					append(&array_rep, strings.clone(kname, allocator))
					it.is_arr_rep = true
					it.arr_elems = chn.elems[:]
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
		for it in base_items {
			if it.base_k != tape.NO_NODE {
				append(&items, it)
			}
		}
		for ins, ins_i in d.inserted_members {
			pos_lo := max(u64)
			seq := (len(base_items) + ins_i) * 2
			if ins.at >= 0 && ins.at < len(base_items) {
				pos_lo = base_items[ins.at].src_lo
				seq = ins.at * 2
			}
			append(&items, Verify_Item {
				key_name    = ins.key,
				is_text     = ins.key == tape.TEXT_KEY,
				src_lo      = pos_lo,
				seq         = seq,
				edit_h      = ins.value,
				is_inserted = true,
			})
		}
		slice.stable_sort_by(items[:], proc(x, y: Verify_Item) -> bool {
			if x.src_lo != y.src_lo {
				return x.src_lo < y.src_lo
			}
			return x.seq < y.seq
		})
	}

	bi := 0
	for it in items {
		if it.is_arr_rep {
			for eh in it.arr_elems {
				if bi >= len(cb) {
					return false
				}
				bk := scalar_alloc(built, cb[bi].k, allocator)
				match_k := bk == it.key_name
				delete(bk, allocator)
				if !match_k || !verify_edit_handle(ov, eh, built, cb[bi].v, build_opts, allocator) {
					return false
				}
				bi += 1
			}
			continue
		}
		if bi >= len(cb) {
			return false
		}
		if it.is_inserted {
			bk := scalar_alloc(built, cb[bi].k, allocator)
			match_k := bk == it.key_name
			delete(bk, allocator)
			if !match_k || !verify_edit_handle(ov, it.edit_h, built, cb[bi].v, build_opts, allocator) {
				return false
			}
			bi += 1
			continue
		}
		if it.renamed {
			bk := scalar_alloc(built, cb[bi].k, allocator)
			match_k := bk == it.key_name
			delete(bk, allocator)
			if !match_k {
				return false
			}
		} else {
			if !same_key(ov.base, it.base_k, built, cb[bi].k, allocator) {
				return false
			}
		}
		append(stack, Verify_Pair{it.base_v, cb[bi].v, follow_by_base})
		bi += 1
	}
	return bi == len(cb)
}

@(private = "file")
verify_replaced_node :: proc(ov: ^Overlay, built: ^tape.Document, b: tape.Node_Index, cn: ^edit.Edit_Node, build_opts: Options, allocator: runtime.Allocator) -> bool {
	if !verify_replaced_content(built, b, build_opts, allocator) {
		return false
	}
	return verify_edit_handle(ov, cn.handle, built, b, build_opts, allocator)
}

@(private = "file")
verify_edit_handle :: proc(ov: ^Overlay, root_h: Handle, built: ^tape.Document, root_b: tape.Node_Index, build_opts: Options, allocator: runtime.Allocator) -> bool {
	Handle_Check :: struct {
		kind: enum { Handle_Node, Base_Pair },
		h:    Handle,
		a, b: tape.Node_Index,
	}
	stack := make([dynamic]Handle_Check, 0, 16, allocator)
	defer delete(stack)
	delta_pairs := make([dynamic]Verify_Pair, 0, 8, allocator)
	defer delete(delta_pairs)
	append(&stack, Handle_Check{kind = .Handle_Node, h = root_h, b = root_b})

	for len(stack) > 0 {
		item := pop(&stack)
		if item.kind == .Base_Pair {
			if !verify_subtree_counts(ov, built, item.a, item.b, build_opts, allocator) {
				return false
			}
			continue
		}
		if item.h == edit.NO_HANDLE {
			continue
		}
		n, ok := edit.get_node(ov, item.h)
		if !ok {
			continue
		}
		b := item.b
		bn := built.nodes[b]
		if n.state == .Replaced {
			#partial switch n.val.kind {
			case .Null:
				if !(bn.kind == .Null || (bn.kind == .Plain && bn.n == 0)) {
					return false
				}
			case .Raw:
				if !verify_replaced_content(built, b, build_opts, allocator) {
					return false
				}
			case .Base_Ref:
				if n.val.base_ref != tape.NO_NODE && int(n.val.base_ref) < len(ov.base.nodes) {
					if len(n.facts) > 0 && has_attr_fact(n) {
						if !verify_edited_attributes(ov.base, n.val.base_ref, n, built, b, allocator) {
							return false
						}
					}
					if !verify_base_ref_match(ov.base, n.val.base_ref, built, b, allocator) {
						return false
					}
				}
			case .Object:
				if bn.kind != .Object {
					return false
				}
				cb := collect_children_pairs(built, b, allocator)
				defer delete(cb, allocator)
				bi := 0
				for m in n.members {
					if en, eok := edit.get_node(ov, m.value); eok && en.state == .Replaced && en.val.kind == .Array {
						for eh in en.elems {
							if bi >= len(cb) {
								return false
							}
							bk := scalar_alloc(built, cb[bi].k, allocator)
							mk := bk == m.key
							delete(bk, allocator)
							if !mk {
								return false
							}
							append(&stack, Handle_Check{kind = .Handle_Node, h = eh, b = cb[bi].v})
							bi += 1
						}
						continue
					}
					if bi >= len(cb) {
						return false
					}
					bk := scalar_alloc(built, cb[bi].k, allocator)
					mk := bk == m.key
					delete(bk, allocator)
					if !mk {
						return false
					}
					append(&stack, Handle_Check{kind = .Handle_Node, h = m.value, b = cb[bi].v})
					bi += 1
				}
				if bi != len(cb) {
					return false
				}
			case .Array:
			case:
				if bn.kind == .Object {
					return false
				}
				buf: [64]u8 = ---
				want := scalar_edit_val_str(&n.val, buf[:])
				if bn.kind == .Null {
					if want != "" {
						return false
					}
				} else {
					got := scalar_alloc(built, b, allocator)
					match := got == want
					delete(got, allocator)
					if !match {
						return false
					}
				}
			}
		} else if n.state == .Container_Delta && n.delta != nil {
			base_c := edit.node_base_container(n)
			if base_c == tape.NO_NODE || bn.kind != .Object {
				return false
			}
			if has_attr_fact(n) {
				if !verify_edited_attributes(ov.base, base_c, n, built, b, allocator) {
					return false
				}
			} else if !same_attributes(ov.base, base_c, built, b) {
				return false
			}
			clear(&delta_pairs)
			if !verify_container_delta(ov, built, base_c, b, n.delta, &delta_pairs, build_opts, n.base != tape.NO_NODE, allocator) {
				return false
			}
			for dp in delta_pairs {
				if dp.follow_ov {
					append(&stack, Handle_Check{kind = .Base_Pair, a = dp.a, b = dp.b})
				} else {
					if !verify_base_ref_match(ov.base, dp.a, built, dp.b, allocator) {
						return false
					}
				}
			}
		}
	}
	return true
}

@(private = "file")
verify_base_ref_match :: proc(src_doc: ^tape.Document, a: tape.Node_Index, built: ^tape.Document, b: tape.Node_Index, allocator: runtime.Allocator) -> bool {
	stack := make([dynamic]Verify_Pair, 0, 16, allocator)
	defer delete(stack)
	if _, err := append(&stack, Verify_Pair{a, b, false}); err != nil {
		return false
	}
	for len(stack) > 0 {
		pair := pop(&stack)
		na, nb := src_doc.nodes[pair.a], built.nodes[pair.b]
		if na.kind != nb.kind {
			if (na.kind <= .Plain && na.kind != .Null) && (nb.kind <= .Plain && nb.kind != .Null) {
			} else {
				return false
			}
		}
		if na.kind != .Object {
			sa := scalar_alloc(src_doc, pair.a, allocator)
			sb := scalar_alloc(built, pair.b, allocator)
			ok := sa == sb
			delete(sa, allocator)
			delete(sb, allocator)
			if !ok {
				return false
			}
			continue
		}
		ca := collect_children_pairs(src_doc, pair.a, allocator)
		cb := collect_children_pairs(built, pair.b, allocator)
		if len(ca) != len(cb) {
			delete(ca, allocator)
			delete(cb, allocator)
			return false
		}
		for i := len(ca) - 1; i >= 0; i -= 1 {
			ka := scalar_alloc(src_doc, ca[i].k, allocator)
			kb := scalar_alloc(built, cb[i].k, allocator)
			mk := ka == kb
			delete(ka, allocator)
			delete(kb, allocator)
			if !mk {
				delete(ca, allocator)
				delete(cb, allocator)
				return false
			}
			if _, err := append(&stack, Verify_Pair{ca[i].v, cb[i].v, false}); err != nil {
				delete(ca, allocator)
				delete(cb, allocator)
				return false
			}
		}
		delete(ca, allocator)
		delete(cb, allocator)
	}
	return true
}

@(private = "file")
verify_replaced_content :: proc(built: ^tape.Document, b: tape.Node_Index, build_opts: Options, allocator: runtime.Allocator) -> bool {
	if b == tape.ROOT {
		if built.format == as(.Html) {
			el := html_element_of(built, b)
			alone, err := build(built.src[el.lo:el.hi], .Html, build_opts, allocator)
			if err != nil {
				return false
			}
			defer tape.destroy(&alone)
			return same_children_tree(built, b, &alone, tape.ROOT, allocator)
		}
		return true
	}
	el := html_element_of(built, b)
	name := scalar_name_of(built, b - 1, allocator)
	defer delete(name, allocator)
	ns := key_namespace(built.nodes[b - 1])
	if el.close < el.open || el.close > u64(len(built.src)) {
		return true
	}
	base_content := built.src[el.open:el.close]
	if ns == .Html && keeps_space_name(name) {
		if strings.has_prefix(string(base_content), "\r\n") {
			base_content = base_content[2:]
		} else if len(base_content) > 0 && (base_content[0] == '\n' || base_content[0] == '\r') {
			base_content = base_content[1:]
		}
	}
	tail := read_on_bytes(built, b, el.close, allocator)
	defer delete(tail, allocator)
	content := base_content
	combined: []u8
	if len(tail) > 0 {
		combined = slice.concatenate([][]u8{base_content, tail}, allocator)
		content = combined
	}
	defer if combined != nil {
		delete(combined, allocator)
	}

	frag, err := build_fragment(content, {context_name = name, context_namespace = ns}, build_opts, allocator)
	if err != nil {
		return false
	}
	defer tape.destroy(&frag)
	if built.nodes[b].kind == .Object {
		return same_children_tree(built, b, &frag, tape.ROOT, allocator)
	}
	if built.nodes[b].kind == .Null {
		return count_elem_children(&frag, tape.ROOT) == 0 && len(frag.nodes) <= 1
	}
	frag_txt := ""
	has_frag_txt := false
	if len(frag.nodes) == 3 && tape.is_text_key(frag.nodes[1]) {
		frag_txt = scalar_alloc(&frag, 2, allocator)
		has_frag_txt = true
	} else if len(frag.nodes) > 1 {
		return false
	}
	defer if has_frag_txt {
		delete(frag_txt, allocator)
	}
	got := scalar_alloc(built, b, allocator)
	defer delete(got, allocator)
	return frag_txt == got || (frag_txt == "" && strings.trim(got, " \t\n\r\f") == "")
}

@(private = "file")
read_on_bytes :: proc(y: ^tape.Document, b: tape.Node_Index, close: u64, allocator: runtime.Allocator) -> []u8 {
	out := make([dynamic]u8, 0, 16, allocator)
	end := tape.node_after(y, b)
	for k in b ..< end {
		if y.nodes[k].kind != .Plain || y.nodes[k].spelling & TEXT_PIECES == 0 || y.ext == nil {
			continue
		}
		if b_bytes, head, entry, ok := find_text_entry(&y.ext.format, y.nodes[k].lo); ok {
			for i in 0 ..< entry.count {
				p := load_piece(b_bytes, head, entry.first + i)
				if p.lo >= close && p.lo + u64(p.n) <= u64(len(y.src)) {
					append(&out, ..y.src[p.lo:][:p.n])
				}
			}
		}
	}
	return out[:]
}

@(private = "file")
same_children_tree :: proc(a: ^tape.Document, na: tape.Node_Index, b: ^tape.Document, nb: tape.Node_Index, allocator: runtime.Allocator) -> bool {
	stack := make([dynamic]Verify_Pair, 0, 16, allocator)
	defer delete(stack)
	if _, err := append(&stack, Verify_Pair{na, nb, false}); err != nil {
		return false
	}
	for len(stack) > 0 {
		pair := pop(&stack)
		ca := collect_children_pairs(a, pair.a, allocator)
		cb := collect_children_pairs(b, pair.b, allocator)
		if len(ca) != len(cb) {
			delete(ca, allocator)
			delete(cb, allocator)
			return false
		}
		for i := len(ca) - 1; i >= 0; i -= 1 {
			if !same_key(a, ca[i].k, b, cb[i].k, allocator) {
				delete(ca, allocator)
				delete(cb, allocator)
				return false
			}
			va, vb := ca[i].v, cb[i].v
			if a.nodes[va].kind != b.nodes[vb].kind || !same_attributes(a, va, b, vb) {
				delete(ca, allocator)
				delete(cb, allocator)
				return false
			}
			if a.nodes[va].kind == .Object {
				if _, err := append(&stack, Verify_Pair{va, vb, false}); err != nil {
					delete(ca, allocator)
					delete(cb, allocator)
					return false
				}
			} else {
				sa := scalar_alloc(a, va, allocator)
				sb := scalar_alloc(b, vb, allocator)
				ok := sa == sb
				delete(sa, allocator)
				delete(sb, allocator)
				if !ok {
					delete(ca, allocator)
					delete(cb, allocator)
					return false
				}
			}
		}
		delete(ca, allocator)
		delete(cb, allocator)
	}
	return true
}

@(private = "file")
same_key :: proc(x: ^tape.Document, ka: tape.Node_Index, y: ^tape.Document, kb: tape.Node_Index, allocator: runtime.Allocator) -> bool {
	sa, sb := x.nodes[ka], y.nodes[kb]
	if (sa.n == 0) != (sb.n == 0) || key_namespace(sa) != key_namespace(sb) {
		return false
	}
	buf_a: [256]u8 = ---
	buf_b: [256]u8 = ---
	a_str, a_owned := key_name_temp(x, ka, buf_a[:], allocator)
	b_str, b_owned := key_name_temp(y, kb, buf_b[:], allocator)
	defer {
		if a_owned {
			delete(a_str, allocator)
		}
		if b_owned {
			delete(b_str, allocator)
		}
	}
	return a_str == b_str
}

@(private = "file")
same_attributes :: proc "contextless" (x: ^tape.Document, a: tape.Node_Index, y: ^tape.Document, b: tape.Node_Index) -> bool {
	fa, fb := tape.facts_of(x, a), tape.facts_of(y, b)
	i, j := 0, 0
	for {
		for i < len(fa) && fa[i].kind != .Attribute {
			i += 1
		}
		for j < len(fb) && fb[j].kind != .Attribute {
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

@(private = "file")
has_attr_fact :: proc "contextless" (cn: ^edit.Edit_Node) -> bool {
	for f in cn.facts {
		if f.kind == .Attribute {
			return true
		}
	}
	return false
}

@(private = "file")
verify_edited_attributes :: proc(orig: ^tape.Document, a: tape.Node_Index, cn: ^edit.Edit_Node, built: ^tape.Document, b: tape.Node_Index, allocator: runtime.Allocator) -> bool {
	Attr :: struct {
		name, val: string,
	}
	collect_attrs :: proc(doc: ^tape.Document, v: tape.Node_Index, allocator: runtime.Allocator) -> [dynamic]Attr {
		out := make([dynamic]Attr, 0, 4, allocator)
		for bf in tape.facts_of(doc, v) {
			if bf.kind != .Attribute {
				continue
			}
			kt, vt := attribute(doc, bf)
			kn := scalar_tok_alloc(doc, kt, allocator)
			kv := scalar_tok_alloc(doc, vt, allocator)
			append(&out, Attr{kn, kv})
		}
		return out
	}
	expected := collect_attrs(orig, a, allocator)
	got := collect_attrs(built, b, allocator)
	defer {
		for it in expected { delete(it.name, allocator); delete(it.val, allocator) }
		for it in got { delete(it.name, allocator); delete(it.val, allocator) }
		delete(expected)
		delete(got)
	}
	html_ns := a > 0 && a != tape.ROOT && orig.nodes[a - 1].role == .Key && key_namespace(orig.nodes[a - 1]) == .Html
	for f in cn.facts {
		if f.kind != .Attribute {
			continue
		}
		idx := -1
		for it, i in expected {
			match := strings.equal_fold(it.name, f.attr) if html_ns else it.name == f.attr
			if match {
				idx = i
				break
			}
		}
		if f.deleted || len(f.values) == 0 {
			if idx >= 0 {
				delete(expected[idx].name, allocator)
				delete(expected[idx].val, allocator)
				ordered_remove(&expected, idx)
			}
		} else if idx >= 0 {
			delete(expected[idx].val, allocator)
			expected[idx].val = strings.clone(f.values[0], allocator)
		} else {
			aname := strings.to_lower(f.attr, allocator) if html_ns else strings.clone(f.attr, allocator)
			append(&expected, Attr{aname, strings.clone(f.values[0], allocator)})
		}
	}
	if len(expected) != len(got) {
		return false
	}
	for i in 0 ..< len(expected) {
		if expected[i].name != got[i].name || expected[i].val != got[i].val {
			return false
		}
	}
	return true
}

@(private = "file")
scalar_alloc :: proc(doc: ^tape.Document, at: tape.Node_Index, allocator: runtime.Allocator) -> string {
	buf := make([dynamic]u8, 0, 64, allocator)
	s := scalar_string(doc, at, &buf)
	out := strings.clone(s, allocator)
	delete(buf)
	return out
}

@(private = "file")
scalar_tok_alloc :: proc(doc: ^tape.Document, tok: tape.Token, allocator: runtime.Allocator) -> string {
	room := max(tape.text_room(doc, tok), int(tok.n), 16)
	buf := make([]u8, room, allocator)
	s, ok := tape.node_text(doc, tok, buf)
	out := strings.clone(s if ok else "", allocator)
	delete(buf, allocator)
	return out
}

@(private = "file")
collect_children_pairs :: proc(doc: ^tape.Document, c: tape.Node_Index, allocator: runtime.Allocator) -> []struct{ k, v: tape.Node_Index } {
	out := make([dynamic]struct{ k, v: tape.Node_Index }, 0, 8, allocator)
	if doc.nodes[c].kind != .Object {
		return out[:]
	}
	end := tape.node_after(doc, c)
	for k := c + 1; k < end; {
		v := tape.node_after(doc, k)
		append(&out, struct{ k, v: tape.Node_Index }{k, v})
		k = tape.node_after(doc, v)
	}
	return out[:]
}

@(private = "file")
count_elem_children :: proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> int {
	if doc.nodes[v].kind != .Object {
		return 0
	}
	cnt := 0
	end := tape.node_after(doc, v)
	for k := v + 1; k < end; {
		val := tape.node_after(doc, k)
		if !tape.is_text_key(doc.nodes[k]) {
			cnt += 1
		}
		k = tape.node_after(doc, val)
	}
	return cnt
}

@(private = "file")
key_name_temp :: proc(doc: ^tape.Document, k: tape.Node_Index, buf: []u8, allocator: runtime.Allocator) -> (s: string, owned: bool) {
	t := doc.nodes[k]
	if fx := table_key_text(doc.src, t); len(fx) > 0 {
		return fx, false
	}
	if !tape.text_decodes(t) && .Held not_in doc.flags {
		return string(doc.src[t.lo:][:t.n]), false
	}
	if res, ok := tape.node_text(doc, k, buf); ok {
		return res, false
	}
	return scalar_name_of(doc, k, allocator), true
}

@(private = "file")
html_iter_next :: proc "contextless" (it: ^handle_map.Dynamic_Handle_Map_Iterator(handle_map.Dynamic_Handle_Map(edit.Edit_Node, Handle))) -> (^edit.Edit_Node, bool) {
	for it.index < xar.len(it.m.items) {
		p := xar.get_ptr_unsafe(&it.m.items, it.index)
		it.index += 1
		if p.handle.idx != 0 {
			return p, true
		}
	}
	return nil, false
}

@(private = "file")
Saved_Key_Case :: struct {
	slot: ^string,
	orig: string,
	raw:  string,
}

@(private = "file")
apply_delta_key_cases :: proc(ov: ^Overlay, allocator: runtime.Allocator) -> [dynamic]Saved_Key_Case {
	saved := make([dynamic]Saved_Key_Case, 0, 4, allocator)
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in html_iter_next(&it) {
		bv := edit.node_base_container(n)
		if !n.has_edits || bv == tape.NO_NODE || int(bv) >= len(ov.base.nodes) {
			continue
		}
		if n.delta != nil && ov.base.nodes[bv].kind == .Object {
			ca := collect_children_pairs(ov.base, bv, allocator)
			defer delete(ca, allocator)
			for &r in n.delta.renamed_members {
				kn := tape.NO_NODE
				if r.base_idx >= 0 && r.base_idx < len(ca) {
					kn = ca[r.base_idx].k
				} else {
					for cp in ca {
						kstr := scalar_alloc(ov.base, cp.k, allocator)
						matched := kstr == r.old_key
						delete(kstr, allocator)
						if matched {
							kn = cp.k
							break
						}
					}
				}
				if kn != tape.NO_NODE && !tape.is_text_key(ov.base.nodes[kn]) {
					raw_span := string(tape.span_bytes(ov.base, ov.base.nodes[kn].lo, ov.base.nodes[kn].n))
					if raw_span != r.old_key && strings.equal_fold(raw_span, r.old_key) {
						cloned := strings.clone(raw_span, allocator)
						append(&saved, Saved_Key_Case{slot = &r.old_key, orig = r.old_key, raw = cloned})
						r.old_key = cloned
					}
				}
			}
			for &dk in n.delta.deleted_keys {
				for cp in ca {
					if tape.is_text_key(ov.base.nodes[cp.k]) {
						continue
					}
					kstr := scalar_alloc(ov.base, cp.k, allocator)
					matched := kstr == dk
					delete(kstr, allocator)
					if matched {
						raw_span := string(tape.span_bytes(ov.base, ov.base.nodes[cp.k].lo, ov.base.nodes[cp.k].n))
						if raw_span != dk && strings.equal_fold(raw_span, dk) {
							cloned := strings.clone(raw_span, allocator)
							append(&saved, Saved_Key_Case{slot = &dk, orig = dk, raw = cloned})
							dk = cloned
						}
						break
					}
				}
			}
		}
		if len(n.facts) > 0 && bv != tape.ROOT && ov.base.nodes[bv - 1].role == .Key && key_namespace(ov.base.nodes[bv - 1]) == .Html {
			for &f in n.facts {
				if f.kind != .Attribute {
					continue
				}
				for bf in tape.facts_of(ov.base, bv) {
					if bf.kind != .Attribute {
						continue
					}
					kt, _ := attribute(ov.base, bf)
					raw_attr := string(tape.span_bytes(ov.base, kt.lo, kt.n))
					if raw_attr != f.attr && strings.equal_fold(raw_attr, f.attr) {
						cloned := strings.clone(raw_attr, allocator)
						append(&saved, Saved_Key_Case{slot = &f.attr, orig = f.attr, raw = cloned})
						f.attr = cloned
						break
					}
				}
			}
		}
	}
	return saved
}

@(private = "file")
restore_delta_key_cases :: proc(ov: ^Overlay, saved: ^[dynamic]Saved_Key_Case) {
	for s in saved {
		s.slot^ = s.orig
		delete(s.raw, ov.allocator)
	}
	clear(saved)
	delete(saved^)
	saved^ = {}
}

@(private = "file")
scalar_name_of :: proc(doc: ^tape.Document, k: tape.Node_Index, allocator: runtime.Allocator) -> string {
	room := max(tape.text_room(doc, k), int(doc.nodes[k].n), 16)
	buf, err := make([]u8, room, allocator)
	if err != nil {
		return strings.clone("div", allocator)
	}
	s, ok := tape.node_text(doc, k, buf)
	out := strings.clone(s if ok else "div", allocator)
	delete(buf, allocator)
	return out
}
