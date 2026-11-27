package edit

import "base:runtime"
import "core:bytes"
import "core:container/handle_map"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"

// Bracket-family composer (JSON, JSONC, JSON5).
// Preserves untargeted bytes, indentation, trailing commas, comments, and neighbour quote/spacing styles.

Bracket_Comment_Syntax :: struct {
	line, open, close: string,
}

Bracket_Spec :: struct {
	target:          ^tape.Format,
	allows_comments: bool,
	trailing_comma:  bool,
	comment:         Bracket_Comment_Syntax,
	spell_value:     proc(data: rawptr, ov: ^Overlay, h: Handle, out: ^[dynamic]u8, indent, unit, eol, style: string) -> Error,
	spell_key:       proc(data: rawptr, key: string, out: ^[dynamic]u8, quote: u8) -> Error,
	validate:        proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	data:            rawptr,
}

@(private = "file")
Bracket_Cx :: struct {
	ov:        ^Overlay,
	doc:       ^tape.Document,
	src:       []u8,
	spec:      ^Bracket_Spec,
	opts:      Options,
	eol:       string,
	splices:   ^[dynamic]Splice,
	dropped:   tape.Facts,
	allocator: runtime.Allocator,
}

commit_bracket :: proc(ov: ^Overlay, spec: ^Bracket_Spec, opts := Options{}, allocator := context.allocator) -> (Commit_Result, Error) {
	extra_clean := ov != nil && ov.base != nil && (spec.allows_comments || (ov.base.present & tape.COMMENTS) == {})
	cx := Bracket_Cx{ov = ov, doc = ov.base if ov != nil else nil, src = ov.base.src if ov != nil && ov.base != nil else nil, spec = spec, opts = opts}
	tc := Text_Composer {
		target = spec.target, extra_clean = extra_clean, req_root = .End, validate = spec.validate, validate_data = spec.data,
		fast_emit = bracket_fast_emit, struct_emit = bracket_struct_emit, frag_check = bracket_frag_check, user = &cx,
	}
	return run_text_commit(ov, &tc, opts, allocator)
}

@(private = "file")
bracket_fast_emit :: proc(user: rawptr, ov: ^Overlay, doc: ^tape.Document, splices: ^[dynamic]Splice, scratch: runtime.Allocator) -> (ok: bool, err: Error) {
	cx := (^Bracket_Cx)(user)
	if !cx.spec.allows_comments && (doc.present & tape.COMMENTS) != {} { return false, nil }
	cx.allocator, cx.splices = scratch, splices
	sorted_bases, has_prev := true, false
	prev_base := tape.Node_Index(0)
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in dynamic_iter_next(&it) {
		if n.state == .Replaced && n.has_edits && n.base != tape.NO_NODE && doc.nodes[n.base].role == .Value {
			if has_prev && n.base < prev_base { sorted_bases = false }
			prev_base, has_prev = n.base, true
			emit_bracket_replace(cx, n.handle, n) or_return
		}
	}
	if !bracket_fast_has_duplicate_key(doc, cx.splices^[:], sorted_bases, scratch) { return true, nil }
	clear(cx.splices)
	return false, nil
}

@(private = "file")
bracket_struct_emit :: proc(user: rawptr, ov: ^Overlay, doc: ^tape.Document, eol: string, splices: ^[dynamic]Splice, dropped: ^tape.Facts, scratch: runtime.Allocator) -> Error {
	cx := (^Bracket_Cx)(user)
	cx.allocator, cx.splices, cx.eol = scratch, splices, eol
	if !cx.spec.allows_comments && (doc.present & tape.COMMENTS) != {} {
		cx.dropped += doc.present & tape.COMMENTS
		for f in doc.facts {
			if f.kind in tape.COMMENTS {
				lo, hi := comment_delete_span(cx.src, f.lo, f.lo + u64(f.n), !first_on_line(cx.src, f.lo))
				push_splice(cx.splices, lo, hi, base_node = f.node, full_rewalk = true) or_return
			}
		}
	}
	if ov.root != NO_HANDLE { compose_bracket_walk(cx, ov.root) or_return }
	dropped^ = cx.dropped
	return nil
}

@(private = "file")
bracket_frag_check :: proc(user: rawptr, out: []u8, recs: []Splice_Record, scratch: runtime.Allocator) -> (bool, Error) {
	cx := (^Bracket_Cx)(user)
	for rec in recs {
		if !rec.subtree_only || rec.full_rewalk { return true, nil }
		frag := out[rec.dst_lo:rec.dst_hi]
		if is_simple_json_scalar(frag) { continue }
		if has_utf8_bom(frag) || bytes.index_byte(frag, '[') >= 0 || bytes.index_byte(frag, '{') >= 0 ||
			(cx.spec.allows_comments && bytes.index(frag, transmute([]u8)string("//")) >= 0) {
			return true, nil
		}
		if verr := cx.spec.validate(cx.spec.data, frag, scratch); verr != nil {
			return false, convert_tape_error(verr)
		}
	}
	return false, nil
}

@(private = "file")
bracket_comment_syn :: proc "contextless" (cx: ^Bracket_Cx) -> Bracket_Comment_Syntax {
	return cx.spec.comment if cx.spec.comment.line != "" else {"//", "/*", "*/"}
}

@(private = "file")
append_block_comment :: proc(b: ^[dynamic]u8, syn: Bracket_Comment_Syntax, body: string, padded: bool) {
	append(b, syn.open)
	if padded && len(body) > 0 { append(b, ' ') }
	append(b, body)
	if padded && len(body) > 0 { append(b, ' ') }
	append(b, syn.close)
}

@(private = "file")
append_comment_line :: proc(b: ^[dynamic]u8, syn: Bracket_Comment_Syntax, body: string, padded: bool) {
	if bytes.index_byte(transmute([]u8)body, '\n') >= 0 || bytes.index_byte(transmute([]u8)body, '\r') >= 0 {
		append_block_comment(b, syn, body, padded)
		return
	}
	append(b, syn.line)
	if padded && len(body) > 0 { append(b, ' ') }
	append(b, body)
}

@(private = "file")
append_indented_comments :: proc(b: ^[dynamic]u8, syn: Bracket_Comment_Syntax, f: Fact_Override, indent, eol: string, lead_first, trailing_eol: bool) {
	for line, i in f.values {
		if i > 0 && !trailing_eol { append(b, eol) }
		if i > 0 || lead_first { append(b, indent) }
		append_comment_line(b, syn, line, f.padded)
		if trailing_eol { append(b, eol) }
	}
}

@(private = "file")
skip_bracket_comment :: proc "contextless" (src: []u8, p, hi: u64) -> (end: u64, ok: bool) {
	if p + 1 >= hi || src[p] != '/' { return p, false }
	if src[p + 1] == '/' {
		q := p + 2
		for q < hi && src[q] != '\n' && src[q] != '\r' { q += 1 }
		return q, true
	}
	if src[p + 1] == '*' {
		q := p + 2
		for q + 1 < hi && !(src[q] == '*' && src[q + 1] == '/') { q += 1 }
		return min(q + 2, hi), true
	}
	return p, false
}

@(private = "file")
scan_for_comma :: proc "contextless" (src: []u8, lo, hi: u64) -> i64 {
	for p := lo; p < hi; {
		if src[p] == ',' { return i64(p) }
		if end, is_c := skip_bracket_comment(src, p, hi); is_c { p = end } else { p += 1 }
	}
	return -1
}

@(private = "file")
compose_bracket_walk :: proc(cx: ^Bracket_Cx, root: Handle) -> Error {
	stack := make([dynamic]Handle, 0, 32, cx.allocator)
	defer delete(stack)
	append(&stack, root) or_return
	for len(stack) > 0 {
		h := pop(&stack)
		n, ok := get_node(cx.ov, h)
		if !ok || !n.has_edits { continue }
		if n.state == .Replaced {
			emit_bracket_replace(cx, h, n) or_return
			continue
		}
		if n.base != tape.NO_NODE && cx.doc.nodes[n.base].kind == .Object && bracket_has_edited_duplicate_key(cx, n) {
			c_lo, c_hi, cok := node_byte_span(cx.doc, n.base)
			if !cx.opts.reflow || !cok {
				return refuse(.Layout_Reflow_Needed, "editing a duplicated object key requires reflow", n.base, c_lo)
			}
			emit_bracket_reflow(cx, h, n, n.base, c_lo, c_hi) or_return
			continue
		}
		if len(n.facts) > 0 { emit_bracket_facts(cx, h, n) or_return }
		if n.state == .Container_Delta {
			emit_bracket_container_delta(cx, h, n, &stack) or_return
			continue
		}
		if n.base != tape.NO_NODE { push_edited_base_children(cx, h, n.base, &stack) or_return }
	}
	return nil
}

@(private = "file")
push_edited_base_children :: proc(cx: ^Bracket_Cx, parent_h: Handle, base_container: tape.Node_Index, stack: ^[dynamic]Handle) -> Error {
	node := cx.doc.nodes[base_container]
	if node.kind < .Array { return nil }
	if cc := tape.child_count(cx.doc, base_container, node); cc > 16 && len(cx.ov.by_base) < cc {
		for _, ch in cx.ov.by_base {
			if cn, ok := get_node(cx.ov, ch); ok && cn.has_edits && cn.parent == parent_h { append(stack, ch) or_return }
		}
		return nil
	}
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_container, cx.allocator)
	if cerr != nil { return cerr }
	defer tape.destroy_children(&c)
	if p != .Found { return nil }
	for {
		_, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
		if np != .Found { break }
		if ch, _, ed := find_edited_child(cx.ov, vn); ed { append(stack, ch) or_return }
	}
	return nil
}

@(private = "file")
style_override_of :: proc "contextless" (n: ^Edit_Node) -> string {
	for f in n.facts { if f.kind == .Style && !f.deleted && len(f.values) > 0 { return f.values[0] } }
	return ""
}

@(private = "file")
emit_bracket_replace :: proc(cx: ^Bracket_Cx, h: Handle, n: ^Edit_Node) -> Error {
	if n.base == tape.NO_NODE { return nil }
	lo, hi, ok := node_byte_span(cx.doc, n.base)
	if !ok { return refuse(.Bad_Handle, "cannot locate base node span", n.base) }
	has_foot := false
	foot_override: Fact_Override
	for f in n.facts {
		if f.kind == .Comment_Foot && !f.deleted && len(f.values) > 0 { has_foot, foot_override = true, f }
	}
	text: []u8
	if n.val.kind == .Raw {
		text = transmute([]u8)n.val.text
		if has_foot && cx.spec.allows_comments {
			if injected, iok := inject_raw_bracket_foot(cx, text, lo, foot_override); iok { text = injected }
		}
	} else {
		needs_indent := n.val.kind == .Array || n.val.kind == .Object ||
			(n.val.kind == .Base_Ref && n.val.base_ref != tape.NO_NODE && cx.doc.nodes[n.val.base_ref].kind >= .Array) ||
			(has_foot && cx.spec.allows_comments)
		eol := cx.eol
		if needs_indent && len(eol) == 0 {
			eol = detect_eol(cx.src)
			cx.eol = eol
		}
		buf := make([dynamic]u8, 0, 64, cx.allocator)
		cx.spec.spell_value(cx.spec.data, cx.ov, h, &buf, line_indent(cx.src, lo) if needs_indent else "", default_indent_unit(cx.opts) if needs_indent else "", eol, style_override_of(n)) or_return
		text = buf[:]
	}
	push_splice(cx.splices, lo, hi, text, n.base, subtree_only = true) or_return
	if len(n.facts) > 0 { emit_bracket_facts(cx, h, n, skip_foot = true, skip_span = {lo, hi}) or_return }
	return nil
}

@(private = "file")
inject_raw_bracket_foot :: proc(cx: ^Bracket_Cx, raw: []u8, base_lo: u64, f: Fact_Override) -> ([]u8, bool) {
	if len(raw) < 2 { return nil, false }
	close_idx := len(raw) - 1
	for close_idx > 0 && (raw[close_idx] == ' ' || raw[close_idx] == '\t' || raw[close_idx] == '\r' || raw[close_idx] == '\n') { close_idx -= 1 }
	if raw[close_idx] != ']' && raw[close_idx] != '}' { return nil, false }
	eol := cx.eol if len(cx.eol) > 0 else "\n"
	c_indent := line_indent(cx.src, base_lo)
	inner_indent := strings.concatenate({c_indent, default_indent_unit(cx.opts)}, cx.allocator)
	b := make([dynamic]u8, 0, len(raw) + 32, cx.allocator)
	append(&b, ..raw[:close_idx])
	if close_idx > 0 && raw[close_idx - 1] != '\n' { append(&b, eol) }
	append_indented_comments(&b, bracket_comment_syn(cx), f, inner_indent, eol, true, true)
	append(&b, c_indent)
	append(&b, ..raw[close_idx:])
	return b[:], true
}

@(private = "file")
emit_bracket_facts :: proc(cx: ^Bracket_Cx, h: Handle, n: ^Edit_Node, skip_foot := false, skip_span := Byte_Range{}) -> Error {
	if n.base == tape.NO_NODE { return nil }
	lo, hi, ok := node_byte_span(cx.doc, n.base)
	if !ok { return nil }
	head_anchor := lo
	if n.base > 0 && cx.doc.nodes[n.base - 1].role == .Key {
		if klo, _, kok := node_byte_span(cx.doc, n.base - 1); kok { head_anchor = klo }
	}
	for f in n.facts {
		#partial switch f.kind {
		case .Comment, .Comment_Inline, .Comment_Foot:
			if !cx.spec.allows_comments {
				if !f.deleted { cx.dropped += {f.kind} }
				continue
			}
			if !(skip_foot && f.kind == .Comment_Foot) {
				emit_bracket_comment_fact(cx, n.base, f, head_anchor, hi, skip_span) or_return
			}
		case .Style:
			if n.state != .Replaced && !f.deleted && len(f.values) > 0 {
				buf := make([dynamic]u8, 0, 32, cx.allocator)
				cx.spec.spell_value(cx.spec.data, cx.ov, h, &buf, "", "", cx.eol, f.values[0]) or_return
				push_splice(cx.splices, lo, hi, buf[:], n.base, subtree_only = true) or_return
			}
		case:
			if !f.deleted { cx.dropped += {f.kind} }
		}
	}
	return nil
}

@(private = "file")
emit_bracket_comment_fact :: proc(cx: ^Bracket_Cx, node: tape.Node_Index, f: Fact_Override, head_anchor, val_hi: u64, skip_span := Byte_Range{}) -> Error {
	existing := collect_base_facts(cx.doc, node, f.kind, cx.allocator)
	defer delete(existing)
	if f.deleted || len(f.values) == 0 {
		for bf in existing {
			lo, hi := comment_delete_span(cx.src, bf.lo, bf.lo + u64(bf.n), f.kind == .Comment_Inline)
			if !(skip_span.hi > skip_span.lo && lo >= skip_span.lo && hi <= skip_span.hi) {
				push_splice(cx.splices, lo, hi, base_node = node, full_rewalk = true) or_return
			}
		}
		return nil
	}

	syn := bracket_comment_syn(cx)
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	#partial switch f.kind {
	case .Comment:
		anchor := existing[0].lo if len(existing) > 0 else head_anchor
		fol := first_on_line(cx.src, anchor)
		append_indented_comments(&buf, syn, f, line_indent(cx.src, head_anchor), cx.eol, fol, true)
		lo := line_start(cx.src, anchor) if fol else anchor
		hi := lo
		if len(existing) > 0 {
			last := existing[len(existing) - 1]
			hi = next_line(cx.src, last.lo + u64(last.n)) if first_on_line(cx.src, last.lo) else last.lo + u64(last.n)
		}
		push_splice(cx.splices, lo, hi, buf[:], node, full_rewalk = true) or_return
	case .Comment_Inline:
		append(&buf, ' ')
		append_comment_line(&buf, syn, f.values[0], f.padded)
		if len(existing) > 0 {
			last := existing[len(existing) - 1]
			push_splice(cx.splices, trim_left_hws(cx.src, existing[0].lo), last.lo + u64(last.n), buf[:], node, full_rewalk = true) or_return
		} else {
			q := skip_hws(cx.src, val_hi, u64(len(cx.src)))
			ins_at := q + 1 if (q < u64(len(cx.src)) && cx.src[q] == ',') else val_hi
			push_splice(cx.splices, ins_at, ins_at, buf[:], node, full_rewalk = true) or_return
		}
	case .Comment_Foot:
		close_at := val_hi - 1 if val_hi > 0 else val_hi
		inner_indent := strings.concatenate({line_indent(cx.src, close_at), default_indent_unit(cx.opts)}, cx.allocator)
		if len(existing) > 0 {
			append_indented_comments(&buf, syn, f, inner_indent, cx.eol, true, false)
			lo := line_start(cx.src, existing[0].lo) if first_on_line(cx.src, existing[0].lo) else existing[0].lo
			push_splice(cx.splices, lo, existing[len(existing) - 1].lo + u64(existing[len(existing) - 1].n), buf[:], node, full_rewalk = true) or_return
		} else {
			if !first_on_line(cx.src, close_at) { append(&buf, cx.eol) }
			append_indented_comments(&buf, syn, f, inner_indent, cx.eol, true, true)
			ins_at := line_start(cx.src, close_at) if first_on_line(cx.src, close_at) else close_at
			push_splice(cx.splices, ins_at, ins_at, buf[:], node, full_rewalk = true) or_return
		}
	}
	return nil
}

@(private = "file")
Bracket_Item :: struct {
	key_node, val_node:         tape.Node_Index,
	lo, hi, head_lo, inline_hi: u64,
	deleted:                    bool,
}

@(private = "file")
Bracket_Layout :: struct {
	multiline, trailing_comma:                   bool,
	key_quote:                                   u8,
	colon, sep, item_indent, close_indent, unit: string,
}

@(private = "file")
emit_bracket_container_delta :: proc(cx: ^Bracket_Cx, h: Handle, n: ^Edit_Node, stack: ^[dynamic]Handle) -> Error {
	base_c, d := n.base, n.delta
	if d == nil { return push_edited_base_children(cx, h, base_c, stack) }
	c_lo, c_hi, cok := node_byte_span(cx.doc, base_c)
	if !cok || c_hi < c_lo + 2 { return refuse(.Bad_Handle, "cannot locate container span", base_c) }
	is_obj := cx.doc.nodes[base_c].kind == .Object

	items := make([dynamic]Bracket_Item, 0, 8, cx.allocator)
	defer delete(items)
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
	if cerr != nil { return cerr }
	defer tape.destroy_children(&c)
	has_del := false
	if p == .Found {
		for idx := u32(0); ; idx += 1 {
			kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
			if np != .Found { break }
			vlo, vhi, vok := node_byte_span(cx.doc, vn)
			if !vok { return refuse(.Bad_Handle, "cannot locate child span", vn) }
			ilo := vlo
			if is_obj && kn != tape.NO_NODE {
				if klo, _, kok := node_byte_span(cx.doc, kn); kok { ilo = klo }
			}
			head_lo, inline_hi := base_item_comment_bounds(cx.doc, vn, ilo, vhi)
			is_del, ren_to := false, ""
			if is_obj {
				kstr := decode_node_text_tmp(cx.doc, kn, cx.allocator)
				is_del, ren_to = base_delta_status(d, kstr.text, idx, true)
				free_tmp_text(kstr, cx.allocator)
				if !is_del && len(ren_to) > 0 {
					if klo, khi, kok := node_byte_span(cx.doc, kn); kok {
						q := cx.src[klo] if klo < u64(len(cx.src)) && (cx.src[klo] == '"' || cx.src[klo] == '\'') else u8('"')
						kb := make([dynamic]u8, 0, len(ren_to) + 2, cx.allocator)
						cx.spec.spell_key(cx.spec.data, ren_to, &kb, q) or_return
						push_splice(cx.splices, klo, khi, kb[:], base_c) or_return
					}
				}
			} else {
				is_del, _ = base_delta_status(d, "", idx, false)
			}
			if is_del { has_del = true }
			append(&items, Bracket_Item{kn, vn, ilo, vhi, head_lo, inline_hi, is_del}) or_return
		}
	}

	for it in items {
		if !it.deleted {
			if ch, _, ed := find_edited_child(cx.ov, it.val_node); ed { append(stack, ch) or_return }
		}
	}

	layout := detect_bracket_layout(cx, c_lo, c_hi, items[:], is_obj)
	ins_count := len(d.inserted_members) if is_obj else len(d.inserted_elems)
	if !has_del && ins_count == 0 && len(d.order) == 0 { return nil }
	ins_texts := make([][]u8, ins_count, cx.allocator)
	ins_ats := make([]int, ins_count, cx.allocator)
	for i in 0 ..< ins_count {
		if is_obj {
			ins_texts[i] = spell_bracket_insert(cx, d.inserted_members[i].key, d.inserted_members[i].value, true, layout) or_return
			ins_ats[i] = d.inserted_members[i].at
		} else {
			ins_texts[i] = spell_bracket_insert(cx, "", d.inserted_elems[i].value, false, layout) or_return
			ins_ats[i] = d.inserted_elems[i].at
		}
	}

	if len(d.order) > 0 {
		deleted_flags := make_deleted_flags(items[:], cx.allocator) or_return
		defer delete(deleted_flags, cx.allocator)
		validate_order(d.order, deleted_flags, ins_count, cx.allocator) or_return
		if emit_bracket_reorder(cx, base_c, c_lo, c_hi, items[:], d.order, ins_texts, layout) or_return { return nil }
		if !cx.opts.reflow { return refuse(.Layout_Reflow_Needed, "container reorder requires reflow", base_c, c_lo) }
		return emit_bracket_reflow(cx, h, n, base_c, c_lo, c_hi, reemit_outer = false)
	}
	return emit_bracket_insert_delete(cx, base_c, c_lo, c_hi, items[:], ins_texts, ins_ats, layout)
}

@(private = "file")
spell_bracket_insert :: proc(cx: ^Bracket_Cx, key: string, val_h: Handle, is_obj: bool, layout: Bracket_Layout) -> (out: []u8, err: Error) {
	b := make([dynamic]u8, 0, 64, cx.allocator)
	ins_n, has_n := get_node(cx.ov, val_h)
	syn := bracket_comment_syn(cx)
	style := ""
	if has_n {
		style = style_override_of(ins_n)
		for f in ins_n.facts {
			if f.deleted { continue }
			#partial switch f.kind {
			case .Comment:
				if !cx.spec.allows_comments { cx.dropped += {.Comment}; continue }
				for line in f.values {
					if layout.multiline {
						append_comment_line(&b, syn, line, f.padded)
						append(&b, cx.eol)
						append(&b, layout.item_indent)
					} else {
						append_block_comment(&b, syn, line, f.padded)
						append(&b, ' ')
					}
				}
			case .Comment_Inline, .Comment_Foot, .Style:
			case: cx.dropped += {f.kind}
			}
		}
	}
	if is_obj {
		cx.spec.spell_key(cx.spec.data, key, &b, layout.key_quote) or_return
		append(&b, layout.colon)
	}
	cx.spec.spell_value(cx.spec.data, cx.ov, val_h, &b, layout.item_indent, layout.unit, cx.eol, style) or_return
	if has_n {
		for f in ins_n.facts {
			if !f.deleted && f.kind == .Comment_Inline && len(f.values) > 0 {
				if !cx.spec.allows_comments {
					cx.dropped += {.Comment_Inline}
				} else {
					append(&b, ' ')
					append_block_comment(&b, syn, f.values[0], f.padded)
				}
			}
		}
	}
	return b[:], nil
}

@(private = "file")
detect_bracket_layout :: proc(cx: ^Bracket_Cx, c_lo, c_hi: u64, items: []Bracket_Item, is_obj: bool) -> Bracket_Layout {
	l := Bracket_Layout{key_quote = '"', colon = ": ", sep = ", ", close_indent = line_indent(cx.src, c_lo), unit = default_indent_unit(cx.opts)}
	if len(items) == 0 {
		l.multiline = bytes.index_byte(cx.src[c_lo:c_hi], '\n') >= 0
		return l
	}
	first := items[0]
	l.multiline = first_on_line(cx.src, first.lo) && bytes.index_byte(cx.src[c_lo:first.lo], '\n') >= 0
	if l.multiline {
		l.item_indent = line_indent(cx.src, first.lo)
		if len(l.item_indent) > len(l.close_indent) && bytes.has_prefix(transmute([]u8)l.item_indent, transmute([]u8)l.close_indent) {
			l.unit = l.item_indent[len(l.close_indent):]
		}
	}
	if is_obj && first.key_node != tape.NO_NODE {
		klo, khi, kok := node_byte_span(cx.doc, first.key_node)
		vlo, _, vok := node_byte_span(cx.doc, first.val_node)
		if kok && klo < u64(len(cx.src)) { l.key_quote = cx.src[klo] if (cx.src[klo] == '"' || cx.src[klo] == '\'') else 0 }
		if kok && vok && khi < vlo {
			gap := cx.src[khi:vlo]
			if bytes.index_byte(gap, '/') < 0 && bytes.index_byte(gap, '\n') < 0 { l.colon = string(gap) }
		}
	}
	if len(items) >= 2 && !l.multiline {
		gap := cx.src[items[0].hi:items[1].lo]
		if bytes.index_byte(gap, '/') < 0 && bytes.index_byte(gap, '\n') < 0 && bytes.index_byte(gap, ',') >= 0 { l.sep = string(gap) }
	}
	l.trailing_comma = cx.spec.trailing_comma && scan_for_comma(cx.src, items[len(items) - 1].hi, c_hi - 1) >= 0
	return l
}

// Unified duplicate-key detection shared by fast path and structural walk.
@(private = "file")
key_has_duplicate :: #force_inline proc "contextless" (doc: ^tape.Document, obj, end, kn: tape.Node_Index) -> bool #no_bounds_check {
	src, knode := doc.src, doc.nodes[kn]
	raw_ok := knode.spelling & tape.SPELLING_DECODE == 0
	kbytes := string(src[knode.lo : knode.lo + u64(knode.n)]) if raw_ok else ""
	for ok := obj + 1; ok < end; ok = tape.node_after(doc, ok + 1) {
		if ok == kn { continue }
		on := doc.nodes[ok]
		if raw_ok && on.spelling & tape.SPELLING_DECODE == 0 {
			if on.n == knode.n && string(src[on.lo : on.lo + u64(on.n)]) == kbytes { return true }
		} else if tape.same_keys(doc.format, src, knode, src, on) {
			return true
		}
	}
	return false
}

@(private = "file")
object_keys_all_unique :: proc "contextless" (doc: ^tape.Document, obj, end: tape.Node_Index, n_keys: int) -> bool #no_bounds_check {
	nodes, src := doc.nodes, doc.src
	mask := u32(15) if n_keys <= 8 else (u32(31) if n_keys <= 16 else (u32(63) if n_keys <= 32 else u32(127)))
	slots: [128]tape.Node_Index = ---
	slice.zero(slots[:mask + 1])
	max_seen, seen := int(mask >> 1) + 1, 0
	for ok := obj + 1; ok < end; ok = tape.node_after(doc, ok + 1) {
		if seen >= max_seen { return false }
		seen += 1
		kn := nodes[ok]
		if kn.spelling & tape.SPELLING_DECODE != 0 { return false }
		h := kn.n * 2654435761
		if kn.n > 0 { h ~= u32(src[kn.lo]) * 16777619 ~ u32(src[kn.lo + u64(kn.n) - 1]) }
		for slot := h & mask; ; slot = (slot + 1) & mask {
			prev := slots[slot]
			if prev == 0 { slots[slot] = ok; break }
			pn := nodes[prev]
			if pn.n == kn.n && string(src[pn.lo : pn.lo + u64(pn.n)]) == string(src[kn.lo : kn.lo + u64(kn.n)]) { return false }
		}
	}
	return true
}

@(private = "file")
Skip_Frame :: struct {
	node, end, cur, last_kn:    tape.Node_Index,
	n_keys:                     int,
	is_obj, dup_free, has_dups: bool,
}

@(private = "file")
make_skip_frame :: #force_inline proc "contextless" (doc: ^tape.Document, node, end: tape.Node_Index) -> Skip_Frame #no_bounds_check {
	is_obj := doc.nodes[node].kind == .Object
	nk := tape.child_count(doc, node, doc.nodes[node]) if is_obj else 0
	return {node, end, node + 1, tape.NO_NODE, nk, is_obj, !is_obj || (nk >= 0 && nk <= 1), false}
}

@(private = "file")
bracket_fast_has_duplicate_key :: proc(doc: ^tape.Document, splices: []Splice, sorted: bool, scratch: runtime.Allocator) -> bool #no_bounds_check {
	if len(splices) == 0 || len(doc.nodes) == 0 || doc.nodes[0].kind < .Array { return false }
	nodes := doc.nodes
	edited_buf: []tape.Node_Index
	if !sorted {
		eb, aerr := make([]tape.Node_Index, len(splices), scratch)
		if aerr != nil { return true }
		for s, i in splices { eb[i] = s.base_node }
		slice.sort(eb)
		edited_buf = eb
	}
	stack_buf: [64]Skip_Frame = ---
	stack_buf[0] = make_skip_frame(doc, 0, tape.Node_Index(nodes[0].n))
	stack_len := 1
	for si in 0 ..< len(splices) {
		target := splices[si].base_node if sorted else edited_buf[si]
		for stack_len > 0 && target >= stack_buf[stack_len - 1].end { stack_len -= 1 }
		if stack_len == 0 { return true }
		descend: for stack_buf[stack_len - 1].node < target {
			fr := &stack_buf[stack_len - 1]
			for cur := fr.cur; cur < fr.end; {
				vn := cur + 1 if fr.is_obj else cur
				if vn >= fr.end { return true }
				after := tape.node_after(doc, vn)
				if after <= target { cur = after; continue }
				fr.cur = cur
				if fr.is_obj && !fr.dup_free && cur != fr.last_kn {
					fr.last_kn = cur
					if !fr.has_dups {
						if fr.n_keys >= 0 && fr.n_keys <= 64 && object_keys_all_unique(doc, fr.node, fr.end, fr.n_keys) {
							fr.dup_free = true
						} else {
							fr.has_dups = true
						}
					}
					if fr.has_dups && key_has_duplicate(doc, fr.node, fr.end, cur) { return true }
				}
				if vn == target { break descend }
				if nodes[vn].kind < .Array || stack_len >= len(stack_buf) { return true }
				stack_buf[stack_len] = make_skip_frame(doc, vn, after)
				stack_len += 1
				continue descend
			}
			return true
		}
	}
	return false
}

@(private = "file")
bracket_has_edited_duplicate_key :: proc(cx: ^Bracket_Cx, n: ^Edit_Node) -> bool {
	if n.base == tape.NO_NODE { return false }
	obj := cx.doc.nodes[n.base]
	if obj.kind != .Object || obj.n <= 1 { return false }
	end := n.base + tape.Node_Index(obj.n)
	if nk := tape.child_count(cx.doc, n.base, obj); nk >= 0 && nk <= 64 && object_keys_all_unique(cx.doc, n.base, end, nk) {
		return false
	}
	for kn := n.base + 1; kn < end; kn = tape.node_after(cx.doc, kn + 1) {
		vn := kn + 1
		if vn >= end { break }
		is_ed := n.state == .Container_Delta
		if !is_ed { _, _, is_ed = find_edited_child(cx.ov, vn) }
		if is_ed && key_has_duplicate(cx.doc, n.base, end, kn) { return true }
	}
	return false
}

@(private = "file")
emit_bracket_reflow :: proc(cx: ^Bracket_Cx, h: Handle, n: ^Edit_Node, base_c: tape.Node_Index, c_lo, c_hi: u64, reemit_outer := true) -> Error {
	drop_splices_in_range(cx.splices, c_lo, c_hi, cx.allocator)
	is_multiline := bytes.index_byte(cx.src[c_lo:c_hi], '\n') >= 0
	buf := make([dynamic]u8, 0, 128, cx.allocator)
	cx.spec.spell_value(cx.spec.data, cx.ov, h, &buf, line_indent(cx.src, c_lo), default_indent_unit(cx.opts) if is_multiline else "", cx.eol, "") or_return
	push_splice(cx.splices, c_lo, c_hi, buf[:], base_c, subtree_only = true, rewritten = true) or_return
	if reemit_outer && len(n.facts) > 0 { emit_bracket_facts(cx, h, n, skip_foot = true, skip_span = {c_lo, c_hi}) or_return }
	return nil
}

@(private = "file")
emit_bracket_reorder :: proc(cx: ^Bracket_Cx, base_c: tape.Node_Index, c_lo, c_hi: u64, items: []Bracket_Item, order: []u32, ins_texts: [][]u8, layout: Bracket_Layout) -> (ok: bool, err: Error) {
	_ = c_lo
	n := len(items)
	if n == 0 || len(order) == 0 { return false, nil }
	item_lo := make([]u64, n, cx.allocator)
	item_hi := make([]u64, n, cx.allocator)
	defer delete(item_lo, cx.allocator)
	defer delete(item_hi, cx.allocator)

	for it, k in items {
		hi := it.hi
		next_bound := items[k + 1].head_lo if k + 1 < n else c_hi - 1
		if comma_pos := scan_for_comma(cx.src, hi, next_bound); comma_pos >= 0 {
			if end_c, is_c := skip_bracket_comment(cx.src, skip_hws(cx.src, u64(comma_pos) + 1, next_bound), next_bound); is_c { hi = end_c }
		} else if it.inline_hi > hi {
			hi = it.inline_hi
		}
		item_lo[k], item_hi[k] = it.head_lo, hi
	}

	moves := make([dynamic]Move, 0, len(order) * 3, cx.allocator)
	flow_after_comma := " "
	if ci := bytes.index_byte(transmute([]u8)layout.sep, ','); ci >= 0 { flow_after_comma = layout.sep[ci + 1:] }
	for raw, pos in order {
		k := int(raw)
		if pos > 0 {
			if layout.multiline {
				sep_buf := make([dynamic]u8, 0, len(cx.eol) + len(layout.item_indent), cx.allocator)
				append(&sep_buf, cx.eol)
				append(&sep_buf, layout.item_indent)
				append(&moves, Move{text = sep_buf[:], written = true}) or_return
			} else {
				push_move_str(&moves, flow_after_comma, cx.allocator) or_return
			}
		}
		want_comma := pos + 1 < len(order) || layout.trailing_comma
		if k < n {
			it := items[k]
			comma_pos := scan_for_comma(cx.src, it.hi, item_hi[k])
			if (comma_pos >= 0) == want_comma {
				append(&moves, Move{lo = item_lo[k], hi = item_hi[k]})
			} else if comma_pos >= 0 {
				append(&moves, Move{lo = item_lo[k], hi = u64(comma_pos)})
				if u64(comma_pos) + 1 < item_hi[k] { append(&moves, Move{lo = u64(comma_pos) + 1, hi = item_hi[k]}) }
			} else {
				append(&moves, Move{lo = item_lo[k], hi = it.hi})
				push_move_str(&moves, ",", cx.allocator) or_return
				if it.hi < item_hi[k] { append(&moves, Move{lo = it.hi, hi = item_hi[k]}) }
			}
		} else {
			txt := ins_texts[k - n]
			tbuf := make([dynamic]u8, 0, len(txt) + 1, cx.allocator)
			append(&tbuf, ..txt)
			if want_comma { append(&tbuf, ',') }
			append(&moves, Move{text = tbuf[:], written = true})
		}
	}

	span_hi := item_hi[n - 1]
	if tc := scan_for_comma(cx.src, span_hi, c_hi - 1); tc >= 0 { span_hi = u64(tc) + 1 }
	push_splice(cx.splices, item_lo[0], span_hi, base_node = base_c, moves = moves[:]) or_return
	return true, nil
}

@(private = "file")
append_bracket_sep :: proc(b: ^[dynamic]u8, layout: Bracket_Layout, eol, indent: string, extra_indent := "") {
	if layout.multiline {
		append(b, ',')
		append(b, eol)
		append(b, indent)
		if len(extra_indent) > 0 { append(b, extra_indent) }
	} else {
		append(b, layout.sep)
	}
}

@(private = "file")
emit_bracket_delete_item :: proc(cx: ^Bracket_Cx, base_c: tape.Node_Index, it: Bracket_Item, bound: u64, multiline, drop_comma: bool, prev_surv_hi: u64 = 0, trim_after_prev_comma := false) -> Error {
	del_lo, del_hi, extra_comma := bracket_delete_item_span(cx.src, it.lo, it.hi, bound, multiline, drop_comma)
	if trim_after_prev_comma {
		if comma := scan_for_comma(cx.src, prev_surv_hi, it.lo); comma >= 0 {
			if q := u64(comma) + 1; q <= del_lo && bytes.index_byte(cx.src[q:del_lo], '/') < 0 { del_lo = q }
		}
	}
	push_splice(cx.splices, del_lo, del_hi, base_node = base_c) or_return
	if extra_comma >= 0 { push_splice(cx.splices, u64(extra_comma), u64(extra_comma) + 1, base_node = base_c) or_return }
	return nil
}

@(private = "file")
emit_bracket_insert_delete :: proc(cx: ^Bracket_Cx, base_c: tape.Node_Index, c_lo, c_hi: u64, items: []Bracket_Item, ins_texts: [][]u8, ins_ats: []int, layout: Bracket_Layout) -> Error {
	n, last_surv := len(items), -1
	for it, k in items { if !it.deleted { last_surv = k } }

	if last_surv < 0 {
		for k in 0 ..< n {
			emit_bracket_delete_item(cx, base_c, items[k], items[k + 1].lo if k + 1 < n else c_hi - 1, layout.multiline, true) or_return
		}
		if len(ins_texts) == 0 { return nil }
		b := make([dynamic]u8, 0, 64, cx.allocator)
		for t, i in ins_texts {
			if i > 0 {
				append_bracket_sep(&b, layout, cx.eol, layout.close_indent, layout.unit)
			} else if layout.multiline {
				append(&b, cx.eol)
				append(&b, layout.close_indent)
				append(&b, layout.unit)
			}
			append(&b, ..t)
		}
		if layout.multiline {
			if layout.trailing_comma { append(&b, ',') }
			append(&b, cx.eol)
			append(&b, layout.close_indent)
		}
		push_splice(cx.splices, c_lo + 1 if n == 0 else c_hi - 1, c_hi - 1, b[:], base_c) or_return
		return nil
	}

	slots := make([][dynamic]int, n + 1, cx.allocator)
	for at, ins_i in ins_ats {
		slot := n
		if at >= 0 && at < n {
			for k := at; k < n; k += 1 {
				if !items[k].deleted {
					slot = k
					break
				}
			}
		}
		if slots[slot].allocator.procedure == nil { slots[slot] = make([dynamic]int, 0, 2, cx.allocator) }
		append(&slots[slot], ins_i)
	}
	has_tail_ins := len(slots[n]) > 0

	for k in 0 ..< n {
		if !items[k].deleted { continue }
		it := items[k]
		if k == last_surv + 1 && !has_tail_ins && !layout.trailing_comma {
			if comma := scan_for_comma(cx.src, items[last_surv].hi, it.lo); comma >= 0 {
				push_splice(cx.splices, u64(comma), u64(comma) + 1, base_node = base_c) or_return
			}
		}
		emit_bracket_delete_item(cx, base_c, it, items[k + 1].lo if k + 1 < n else c_hi - 1, layout.multiline, k < last_surv || has_tail_ins || !layout.trailing_comma, items[last_surv].hi, !layout.multiline && k == last_surv + 1) or_return
	}

	for k in 0 ..< n {
		if len(slots[k]) == 0 { continue }
		b := make([dynamic]u8, 0, 64, cx.allocator)
		for ins_i in slots[k] {
			append(&b, ..ins_texts[ins_i])
			append_bracket_sep(&b, layout, cx.eol, layout.item_indent)
		}
		push_splice(cx.splices, items[k].head_lo, items[k].head_lo, b[:], base_c) or_return
	}

	if has_tail_ins {
		ls := items[last_surv]
		existing_comma := scan_for_comma(cx.src, ls.hi, items[last_surv + 1].lo if last_surv + 1 < n else c_hi - 1)
		b := make([dynamic]u8, 0, 64, cx.allocator)
		ins_pos := ls.hi
		if existing_comma >= 0 {
			ins_pos = u64(existing_comma) + 1
			if layout.multiline {
				ins_pos = next_line(cx.src, ins_pos)
				for ins_i, idx in slots[n] {
					if idx > 0 { append(&b, ','); append(&b, cx.eol) }
					append(&b, layout.item_indent)
					append(&b, ..ins_texts[ins_i])
				}
				if layout.trailing_comma { append(&b, ',') }
				append(&b, cx.eol)
			} else {
				for ins_i, idx in slots[n] {
					append(&b, layout.sep if idx > 0 else " ")
					append(&b, ..ins_texts[ins_i])
				}
			}
		} else {
			for ins_i in slots[n] {
				append_bracket_sep(&b, layout, cx.eol, layout.item_indent)
				append(&b, ..ins_texts[ins_i])
			}
			if layout.multiline && layout.trailing_comma { append(&b, ',') }
		}
		if !layout.multiline && bytes.index(b[:], transmute([]u8)string("//")) >= 0 { append(&b, cx.eol) }
		push_splice(cx.splices, ins_pos, ins_pos, b[:], base_c) or_return
	}
	return nil
}

@(private = "file")
bracket_delete_item_span :: proc "contextless" (src: []u8, lo, hi, bound: u64, multiline, drop_comma: bool) -> (del_lo, del_hi: u64, extra_comma: i64) {
	del_lo, del_hi, extra_comma = lo, hi, -1
	if drop_comma {
		if comma := scan_for_comma(src, hi, bound); comma >= 0 {
			if bytes.index_byte(src[hi:u64(comma)], '/') < 0 { del_hi = u64(comma) + 1 } else { extra_comma = comma }
		}
	}
	if extra_comma >= 0 { return del_lo, del_hi, extra_comma }
	if multiline && first_on_line(src, del_lo) {
		q := del_hi
		for q < bound && (src[q] == ' ' || src[q] == '\t' || src[q] == '\r') { q += 1 }
		if q < bound && src[q] == '\n' { del_lo, del_hi = line_start(src, del_lo), q + 1 }
	} else if !multiline {
		del_hi = skip_hws(src, del_hi, bound)
	}
	return del_lo, del_hi, extra_comma
}
