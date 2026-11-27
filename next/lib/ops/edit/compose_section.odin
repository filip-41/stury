package edit

import "base:runtime"
import "core:bytes"
import "core:container/handle_map"
import "core:slice"
import "core:unicode/utf8"
import "stury:lib/core/tape"

// Section-tree composer (TOML 1.0 / 1.1).
// Preserves untargeted sections, inline tables, comments, key quoting, and number bases verbatim.

Section_Spec :: struct {
	target:         ^tape.Format,
	v11:            bool,
	spell_value:    proc(data: rawptr, ov: ^Overlay, h: Handle, out: ^[dynamic]u8, style: string, tag: string) -> Error,
	spell_key:      proc(data: rawptr, key: string, out: ^[dynamic]u8) -> Error,
	spell_document: proc(data: rawptr, ov: ^Overlay, out: ^[dynamic]u8) -> Error,
	validate:       proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	data:           rawptr,
}

@(private = "file")
Toml_Section :: struct {
	header_lo, header_key_lo, header_key_hi, body_lo, body_hi, head_lo: u64,
	path:                                                               string,
	is_array:                                                           bool,
}

@(private = "file")
Section_Cx :: struct {
	ov:        ^Overlay,
	doc:       ^tape.Document,
	src:       []u8,
	spec:      ^Section_Spec,
	opts:      Options,
	eol:       string,
	sections:  [dynamic]Toml_Section,
	splices:   ^[dynamic]Splice,
	dropped:   tape.Facts,
	reflowed:  bool,
	allocator: runtime.Allocator,
}

commit_section :: proc(ov: ^Overlay, spec: ^Section_Spec, opts := Options{}, allocator := context.allocator) -> (Commit_Result, Error) {
	cx := Section_Cx{ov = ov, doc = ov.base if ov != nil else nil, src = ov.base.src if ov != nil && ov.base != nil else nil, spec = spec, opts = opts}
	tc := Text_Composer {
		target = spec.target, extra_clean = true, req_root = .Object, root_msg = "TOML document root must be a table (object)",
		validate = spec.validate, validate_data = spec.data, fast_emit = section_fast_emit, struct_emit = section_struct_emit, frag_check = section_frag_check, user = &cx,
	}
	return run_text_commit(ov, &tc, opts, allocator)
}

@(private = "file")
section_fast_emit :: proc(user: rawptr, ov: ^Overlay, doc: ^tape.Document, splices: ^[dynamic]Splice, scratch: runtime.Allocator) -> (ok: bool, err: Error) {
	cx := (^Section_Cx)(user)
	cx.allocator, cx.splices = scratch, splices
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in dynamic_iter_next(&it) {
		if n.state == .Replaced && n.has_edits && n.base != tape.NO_NODE && doc.nodes[n.base].role == .Value {
			if n.val.kind == .Null || n.val.kind == .None { return false, refuse(.Unspellable_Value, "TOML has no null value", n.base) }
			if n.val.kind == .Raw {
				lo, hi, lok := node_byte_span(doc, n.base)
				if !lok { return false, refuse(.Bad_Handle, "cannot locate base value span", n.base) }
				push_splice(cx.splices, lo, hi, transmute([]u8)n.val.text, n.base, subtree_only = true) or_return
			} else {
				emit_section_replace(cx, n.handle, n) or_return
			}
		}
	}
	return true, nil
}

@(private = "file")
section_struct_emit :: proc(user: rawptr, ov: ^Overlay, doc: ^tape.Document, eol: string, splices: ^[dynamic]Splice, dropped: ^tape.Facts, scratch: runtime.Allocator) -> Error {
	_ = doc
	cx := (^Section_Cx)(user)
	cx.allocator, cx.splices, cx.eol = scratch, splices, eol
	cx.sections = make([dynamic]Toml_Section, 0, 8, scratch)
	scan_toml_sections(cx) or_return
	if ov.root != NO_HANDLE { compose_section_walk(cx, ov.root) or_return }
	dropped^ = cx.dropped
	return nil
}

@(private = "file")
section_frag_check :: proc(user: rawptr, out: []u8, recs: []Splice_Record, scratch: runtime.Allocator) -> (bool, Error) {
	cx := (^Section_Cx)(user)
	chk: [256]u8
	chk[0], chk[1], chk[2], chk[3] = 'v', ' ', '=', ' '
	for rec in recs {
		if !rec.subtree_only || rec.full_rewalk { return true, nil }
		frag := out[rec.dst_lo:rec.dst_hi]
		if is_simple_toml_scalar(frag) { continue }
		if len(frag) > len(chk) - 4 || bytes.index_byte(frag, '#') >= 0 || bytes.index_byte(frag, '\n') >= 0 || bytes.index_byte(frag, '\r') >= 0 || bytes.index_byte(frag, '[') >= 0 || bytes.index_byte(frag, '{') >= 0 {
			return true, nil
		}
		copy(chk[4:], frag)
		if verr := cx.spec.validate(cx.spec.data, chk[:4 + len(frag)], scratch); verr != nil {
			return false, convert_tape_error(verr)
		}
	}
	return false, nil
}

@(private = "file")
section_in_span :: #force_inline proc "contextless" (sec: Toml_Section, lo, hi: u64) -> bool {
	return sec.head_lo >= lo && sec.body_hi <= hi
}

@(private = "file")
path_matches_or_child :: proc "contextless" (sec_path, pref: string) -> bool {
	return sec_path == pref || (len(sec_path) > len(pref) && sec_path[:len(pref)] == pref && sec_path[len(pref)] == '.')
}

@(private = "file")
skip_toml_quoted :: proc "contextless" (src: []u8, start, hi: u64, allow_multiline := false) -> u64 {
	c, p := src[start], start
	if allow_multiline && p + 2 < hi && src[p + 1] == c && src[p + 2] == c {
		p += 3
		for p + 2 < hi {
			if c == '"' && src[p] == '\\' { p += 2; continue }
			if src[p] == c && src[p + 1] == c && src[p + 2] == c {
				p += 3
				for p < hi && src[p] == c { p += 1 }
				return p
			}
			p += 1
		}
		return p
	}
	p += 1
	for p < hi && src[p] != '\n' {
		if c == '"' && src[p] == '\\' && p + 1 < hi { p += 2; continue }
		if src[p] == c { return p + 1 }
		p += 1
	}
	return p
}

@(private = "file")
hex_val :: proc "contextless" (h: u8) -> (u32, bool) {
	switch h {
	case '0' ..= '9': return u32(h - '0'), true
	case 'a' ..= 'f': return u32(h - 'a' + 10), true
	case 'A' ..= 'F': return u32(h - 'A' + 10), true
	}
	return 0, false
}

@(private = "file")
normalize_toml_header_path :: proc(cx: ^Section_Cx, raw: []u8) -> (string, Error) {
	out := make([dynamic]u8, 0, len(raw) + 4, cx.allocator)
	seg := make([dynamic]u8, 0, len(raw), cx.allocator)
	defer delete(seg)
	n := u64(len(raw))
	for i, first := u64(0), true; i < n; {
		i = skip_hws(raw, i, n)
		if i >= n { break }
		clear(&seg)
		if raw[i] == '\'' {
			i += 1
			for i < n && raw[i] != '\'' { append(&seg, raw[i]); i += 1 }
			if i < n { i += 1 }
		} else if raw[i] == '"' {
			i += 1
			for i < n && raw[i] != '"' {
				if raw[i] == '\\' && i + 1 < n {
					i += 1
					switch raw[i] {
					case 'b': append(&seg, '\b')
					case 't': append(&seg, '\t')
					case 'n': append(&seg, '\n')
					case 'f': append(&seg, '\f')
					case 'r': append(&seg, '\r')
					case 'u', 'U':
						digits := u64(4 if raw[i] == 'u' else 8)
						if i + digits < n {
							r: u32
							ok := true
							for d in 1 ..= digits {
								v, vok := hex_val(raw[i + d])
								if !vok {
									ok = false
									break
								}
								r = (r << 4) | v
							}
							if ok {
								enc, en := utf8.encode_rune(rune(r))
								append(&seg, ..enc[:en])
								i += digits
							}
						}
					case: append(&seg, raw[i])
					}
					i += 1
					continue
				}
				append(&seg, raw[i])
				i += 1
			}
			if i < n { i += 1 }
		} else {
			start := i
			for i < n && raw[i] != '.' && raw[i] != ' ' && raw[i] != '\t' { i += 1 }
			append(&seg, ..raw[start:i])
		}
		if !first { append(&out, '.') }
		first = false
		if serr := cx.spec.spell_key(cx.spec.data, string(seg[:]), &out); serr != nil {
			delete(out)
			return "", serr
		}
		i = skip_hws(raw, i, n)
		if i < n && raw[i] == '.' { i += 1 }
	}
	return string(out[:]), nil
}

@(private = "file")
scan_toml_sections :: proc(cx: ^Section_Cx) -> Error {
	src, n, in_bracket := cx.src, u64(len(cx.src)), 0
	for p := u64(0); p < n; {
		ls := p
		if q := skip_hws(src, ls, n); in_bracket == 0 && q < n && src[q] == '[' {
			is_arr := q + 1 < n && src[q + 1] == '['
			start := q + (2 if is_arr else 1)
			r := start
			for r < n && src[r] != '\n' && src[r] != '\r' && src[r] != ']' {
				r = skip_toml_quoted(src, r, n) if (src[r] == '"' || src[r] == '\'') else r + 1
			}
			norm := normalize_toml_header_path(cx, src[start:r]) or_return
			head_lo := ls
			for head_lo > 0 {
				prev_ls := line_start(src, head_lo - 1)
				if pq := skip_hws(src, prev_ls, head_lo); pq < head_lo && src[pq] == '#' { head_lo = prev_ls } else { break }
			}
			if len(cx.sections) > 0 { cx.sections[len(cx.sections) - 1].body_hi = head_lo }
			nl := next_line(src, r)
			if _, aerr := append(&cx.sections, Toml_Section{ls, start, r, nl, n, head_lo, norm, is_arr}); aerr != nil {
				delete(norm, cx.allocator)
				return aerr
			}
			p = nl
			continue
		}
		for p < n && src[p] != '\n' {
			c := src[p]
			if c == '#' { for p < n && src[p] != '\n' { p += 1 }; break }
			if c == '"' || c == '\'' { p = skip_toml_quoted(src, p, n, allow_multiline = true); continue }
			if c == '[' || c == '{' { in_bracket += 1 } else if (c == ']' || c == '}') && in_bracket > 0 { in_bracket -= 1 }
			p += 1
		}
		if p < n && src[p] == '\n' { p += 1 }
	}
	return nil
}

@(private = "file")
append_toml_comments :: proc(cx: ^Section_Cx, values: []string, padded, inline: bool, out: ^[dynamic]u8, node: tape.Node_Index, lo: u64 = 0) -> Error {
	if inline && len(values) > 1 { return refuse(.Fact_No_Place, "a TOML line holds at most one inline comment", node, lo) }
	for line in values {
		for c in transmute([]u8)line {
			if (c < 0x20 && c != '\t') || c == 0x7F { return refuse(.Fact_No_Place, "TOML comment contains disallowed control byte", node, lo) }
		}
		append(out, " #" if inline else "#")
		if padded && len(line) > 0 { append(out, ' ') }
		append(out, line)
		if !inline { append(out, cx.eol) }
	}
	return nil
}

@(private = "file")
toml_style_of :: #force_inline proc "contextless" (doc: ^tape.Document, node: tape.Node_Index) -> string {
	name, _ := tape.fact_name(doc, node, .Style)
	return name
}

@(private = "file")
spell_toml_val :: proc(cx: ^Section_Cx, h: Handle, out: ^[dynamic]u8) -> Error {
	style, tag := "", ""
	if n, ok := get_node(cx.ov, h); ok {
		for f in n.facts {
			if f.deleted || len(f.values) == 0 { continue }
			if f.kind == .Style { style = f.values[0] } else if f.kind == .Tag { tag = f.values[0] }
		}
	}
	return cx.spec.spell_value(cx.spec.data, cx.ov, h, out, style, tag)
}

@(private = "file")
append_toml_header :: proc(out: ^[dynamic]u8, path: string, is_aot: bool, eol: string) {
	append(out, "[[" if is_aot else "[")
	append(out, path)
	append(out, "]]" if is_aot else "]")
	append(out, eol)
}

@(private = "file")
emit_section_full_reflow :: proc(cx: ^Section_Cx) -> Error {
	if cx.spec.spell_document == nil { return refuse(.Layout_Reflow_Needed, "TOML document reflow requires spell_document", tape.ROOT) }
	drop_splices_in_range(cx.splices, 0, u64(len(cx.src)) + 1, cx.allocator)
	buf := make([dynamic]u8, 0, 128, cx.allocator)
	cx.spec.spell_document(cx.spec.data, cx.ov, &buf) or_return
	push_splice(cx.splices, 0, u64(len(cx.src)), buf[:], tape.ROOT, full_rewalk = true, rewritten = true) or_return
	cx.reflowed = true
	return nil
}

@(private = "file")
reflow_or_refuse :: proc(cx: ^Section_Cx, msg: string, node: tape.Node_Index) -> Error {
	return emit_section_full_reflow(cx) if cx.opts.reflow else refuse(.Layout_Reflow_Needed, msg, node)
}

@(private = "file")
Section_Frame :: struct {
	h:                              Handle,
	path_pref, owner_sec, dot_pref: string,
	span_lo, span_hi:               u64,
}

@(private = "file")
Aot_Item :: struct {
	lo, hi:  u64,
	deleted: bool,
}

@(private = "file")
collect_aot_items :: proc(cx: ^Section_Cx, path_pref: string, span_lo, span_hi: u64, deleted_indices: []u32) -> [dynamic]Aot_Item {
	items := make([dynamic]Aot_Item, 0, 4, cx.allocator)
	for sec, si in cx.sections {
		if !section_in_span(sec, span_lo, span_hi) || !sec.is_array || sec.path != path_pref { continue }
		hi := sec.body_hi
		for sub in cx.sections[si + 1:] {
			if sub.body_hi > span_hi || sub.path == path_pref || !path_matches_or_child(sub.path, path_pref) { break }
			hi = sub.body_hi
		}
		append(&items, Aot_Item{lo = sec.head_lo, hi = hi})
	}
	for di in deleted_indices { if int(di) < len(items) { items[di].deleted = true } }
	return items
}

@(private = "file")
join_dotted_path :: proc(cx: ^Section_Cx, pref, raw_key: string) -> (string, Error) {
	kb := make([dynamic]u8, 0, len(pref) + len(raw_key) + 4, cx.allocator)
	if len(pref) > 0 { append(&kb, pref); append(&kb, '.') }
	if serr := cx.spec.spell_key(cx.spec.data, raw_key, &kb); serr != nil {
		delete(kb)
		return "", serr
	}
	return string(kb[:]), nil
}

@(private = "file")
compose_section_walk :: proc(cx: ^Section_Cx, root: Handle) -> Error {
	stack := make([dynamic]Section_Frame, 0, 32, cx.allocator)
	append(&stack, Section_Frame{h = root, span_hi = u64(len(cx.src))}) or_return
	for len(stack) > 0 && !cx.reflowed {
		fr := pop(&stack)
		n, ok := get_node(cx.ov, fr.h)
		if !ok || !n.has_edits { continue }
		if n.state == .Replaced {
			if n.base == tape.ROOT {
				return emit_section_full_reflow(cx) if cx.spec.spell_document != nil else refuse(.Root_Shape, "cannot replace TOML root table", tape.ROOT)
			}
			emit_section_replace(cx, fr.h, n) or_return
			continue
		}
		if len(n.facts) > 0 { emit_section_facts(cx, fr.h, n) or_return }
		if n.state == .Container_Delta {
			node := cx.doc.nodes[n.base]
			if (node.kind == .Array || node.kind == .Object) && toml_style_of(cx.doc, n.base) == "inline" {
				emit_toml_inline_delta(cx, n, fr, &stack) or_return
			} else if node.kind == .Object {
				emit_toml_table_delta(cx, n, fr, &stack) or_return
			} else if node.kind == .Array {
				emit_toml_aot_delta(cx, n, fr, &stack) or_return
			}
			continue
		}
		if n.base != tape.NO_NODE { push_section_children(cx, n.base, fr, &stack) or_return }
	}
	return nil
}

@(private = "file")
push_section_child_frame :: proc(cx: ^Section_Cx, fr: Section_Frame, ch: Handle, kn, vn: tape.Node_Index, is_obj_parent: bool, idx: int, aot_items: []Aot_Item, stack: ^[dynamic]Section_Frame) -> Error {
	child := fr
	child.h = ch
	if is_obj_parent && kn != tape.NO_NODE {
		k := decode_node_text_tmp(cx.doc, kn, cx.allocator)
		defer free_tmp_text(k, cx.allocator)
		child.path_pref = join_dotted_path(cx, fr.path_pref, k.text) or_return
		if toml_style_of(cx.doc, vn) == "dotted" {
			child.dot_pref = join_dotted_path(cx, fr.dot_pref, k.text) or_return
		} else {
			child.owner_sec, child.dot_pref = child.path_pref, ""
		}
	} else if !is_obj_parent && idx >= 0 && idx < len(aot_items) {
		child.span_lo, child.span_hi, child.owner_sec, child.dot_pref = aot_items[idx].lo, aot_items[idx].hi, fr.path_pref, ""
	}
	append(stack, child) or_return
	return nil
}

@(private = "file")
push_section_children :: proc(cx: ^Section_Cx, base_c: tape.Node_Index, fr: Section_Frame, stack: ^[dynamic]Section_Frame) -> Error {
	node := cx.doc.nodes[base_c]
	if node.kind < .Array { return nil }
	aot_items: [dynamic]Aot_Item
	defer delete(aot_items)
	if node.kind == .Array && toml_style_of(cx.doc, base_c) != "inline" {
		aot_items = collect_aot_items(cx, fr.path_pref, fr.span_lo, fr.span_hi, nil)
	}
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
	if cerr != nil { return cerr }
	defer tape.destroy_children(&c)
	if p != .Found { return nil }
	for idx := 0; ; idx += 1 {
		kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
		if np != .Found { break }
		if ch, _, ed := find_edited_child(cx.ov, vn); ed {
			push_section_child_frame(cx, fr, ch, kn, vn, node.kind == .Object, idx, aot_items[:], stack) or_return
		}
	}
	return nil
}

@(private = "file")
emit_section_replace :: proc(cx: ^Section_Cx, h: Handle, n: ^Edit_Node) -> Error {
	if n.base == tape.NO_NODE { return nil }
	if n.val.kind == .Null || n.val.kind == .None { return refuse(.Unspellable_Value, "TOML has no null value", n.base) }
	if cx.doc.nodes[n.base].kind == .Object && toml_style_of(cx.doc, n.base) != "inline" {
		return reflow_or_refuse(cx, "replacing a TOML header table requires reflow", n.base)
	}
	lo, hi, ok := node_byte_span(cx.doc, n.base)
	if !ok { return refuse(.Bad_Handle, "cannot locate base value span", n.base) }
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	spell_toml_val(cx, h, &buf) or_return
	push_splice(cx.splices, lo, hi, buf[:], n.base, subtree_only = true) or_return
	if len(n.facts) > 0 { emit_section_facts(cx, h, n) or_return }
	return nil
}

@(private = "file")
emit_section_facts :: proc(cx: ^Section_Cx, h: Handle, n: ^Edit_Node) -> Error {
	if n.base == tape.NO_NODE { return nil }
	lo, hi, ok := node_byte_span(cx.doc, n.base)
	if !ok { return nil }
	stmt_ls := line_start(cx.src, lo)
	need_respell := false
	style_override, tag_override := "", ""
	for f in n.facts {
		#partial switch f.kind {
		case .Comment, .Comment_Inline:
			emit_toml_comment(cx, n.base, f, stmt_ls, hi) or_return
		case .Comment_Foot:
			if n.base != tape.ROOT { return refuse(.Fact_No_Place, "TOML table has no foot comment", n.base, lo) }
			emit_toml_foot_comment(cx, f) or_return
		case .Tag:
			if f.deleted {
				if n.state != .Replaced { need_respell = true }
				continue
			}
			if len(f.values) == 0 { return refuse(.Fact_No_Place, "TOML tag requires a datetime type name", n.base, lo) }
			if node_kind(cx.ov, h) != .String { return refuse(.Fact_No_Place, "TOML tag applies only to a datetime string", n.base, lo) }
			tag_override = f.values[0]
			if n.state != .Replaced { need_respell = true }
		case .Style:
			if !f.deleted && len(f.values) > 0 {
				style_override = f.values[0]
				if n.state != .Replaced { need_respell = true }
			}
		case:
			if !f.deleted { cx.dropped += {f.kind} }
		}
	}
	if need_respell {
		buf := make([dynamic]u8, 0, 32, cx.allocator)
		cx.spec.spell_value(cx.spec.data, cx.ov, h, &buf, style_override, tag_override) or_return
		push_splice(cx.splices, lo, hi, buf[:], n.base, subtree_only = true) or_return
	}
	return nil
}

@(private = "file")
emit_toml_comment :: proc(cx: ^Section_Cx, node: tape.Node_Index, f: Fact_Override, stmt_ls, val_hi: u64) -> Error {
	existing := collect_base_facts(cx.doc, node, f.kind, cx.allocator)
	defer delete(existing)
	inline := f.kind == .Comment_Inline
	if f.deleted || len(f.values) == 0 {
		for bf in existing {
			lo, hi := comment_delete_span(cx.src, bf.lo, bf.lo + u64(bf.n), inline)
			push_splice(cx.splices, lo, hi, base_node = node, full_rewalk = true) or_return
		}
		return nil
	}
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	anchor := val_hi if inline else stmt_ls
	append_toml_comments(cx, f.values, f.padded, inline, &buf, node, anchor) or_return
	lo, hi := anchor, anchor
	if len(existing) > 0 {
		last := existing[len(existing) - 1]
		lo = trim_left_hws(cx.src, existing[0].lo) if inline else line_start(cx.src, existing[0].lo)
		hi = last.lo + u64(last.n) if inline else next_line(cx.src, last.lo + u64(last.n))
	}
	push_splice(cx.splices, lo, hi, buf[:], node, full_rewalk = true) or_return
	return nil
}

@(private = "file")
emit_toml_foot_comment :: proc(cx: ^Section_Cx, f: Fact_Override) -> Error {
	eof := u64(len(cx.src))
	if f.deleted || len(f.values) == 0 {
		for bf in tape.facts_of(cx.doc, tape.ROOT) {
			if bf.kind == .Comment_Foot {
				push_splice(cx.splices, line_start(cx.src, bf.lo), next_line(cx.src, bf.lo + u64(bf.n)), base_node = tape.ROOT, full_rewalk = true) or_return
			}
		}
		return nil
	}
	buf := make([dynamic]u8, 0, 64, cx.allocator)
	if eof > 0 && cx.src[eof - 1] != '\n' { append(&buf, cx.eol) }
	append_toml_comments(cx, f.values, f.padded, false, &buf, tape.ROOT) or_return
	push_splice(cx.splices, eof, eof, buf[:], tape.ROOT, full_rewalk = true) or_return
	return nil
}

@(private = "file")
push_move_nl_indent :: proc(moves: ^[dynamic]Move, eol, indent: string, comma: bool, allocator: runtime.Allocator) {
	b := make([dynamic]u8, 0, len(eol) + len(indent) + 1, allocator)
	if comma { append(&b, ',') }
	append(&b, eol)
	append(&b, indent)
	append(moves, Move{text = b[:], written = true})
}

@(private = "file")
emit_toml_inline_delta :: proc(cx: ^Section_Cx, n: ^Edit_Node, fr: Section_Frame, stack: ^[dynamic]Section_Frame) -> Error {
	d := n.delta
	if d == nil { return nil }
	base_c := n.base
	is_obj := cx.doc.nodes[base_c].kind == .Object
	c_lo, c_hi, cok := node_byte_span(cx.doc, base_c)
	if !cok || c_hi < c_lo + 2 { return refuse(.Bad_Handle, "cannot locate inline TOML container span", base_c) }

	Item :: struct { kn, vn: tape.Node_Index, lo, hi, key_lo, key_hi: u64, renamed_to: string, deleted: bool }
	items := make([dynamic]Item, 0, 8, cx.allocator)
	defer delete(items)
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
	if cerr != nil { return cerr }
	defer tape.destroy_children(&c)
	if p == .Found {
		for idx := u32(0); ; idx += 1 {
			kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
			if np != .Found { break }
			vlo, vhi, vok := node_byte_span(cx.doc, vn)
			if !vok { return refuse(.Bad_Handle, "cannot locate inline item span", vn) }
			ilo, klo, khi := vlo, u64(0), u64(0)
			if is_obj && kn != tape.NO_NODE {
				if lo_k, hi_k, kok := node_byte_span(cx.doc, kn); kok { ilo, klo, khi = lo_k, lo_k, hi_k }
			}
			is_del, ren_to := false, ""
			if is_obj {
				k := decode_node_text_tmp(cx.doc, kn, cx.allocator)
				is_del, ren_to = base_delta_status(d, k.text, idx, true)
				free_tmp_text(k, cx.allocator)
			} else {
				is_del, _ = base_delta_status(d, "", idx, false)
			}
			append(&items, Item{kn, vn, ilo, vhi, klo, khi, ren_to, is_del})
		}
	}

	for it in items {
		if !it.deleted {
			if ch, _, ed := find_edited_child(cx.ov, it.vn); ed {
				append(stack, Section_Frame{h = ch, span_lo = fr.span_lo, span_hi = fr.span_hi})
			}
		}
	}

	ins_count := len(d.inserted_members) if is_obj else len(d.inserted_elems)
	ins_texts := make([][]u8, ins_count, cx.allocator)
	defer delete(ins_texts, cx.allocator)
	for i in 0 ..< ins_count {
		b := make([dynamic]u8, 0, 32, cx.allocator)
		vh: Handle
		if is_obj {
			cx.spec.spell_key(cx.spec.data, d.inserted_members[i].key, &b) or_return
			append(&b, " = ")
			vh = d.inserted_members[i].value
		} else {
			vh = d.inserted_elems[i].value
		}
		spell_toml_val(cx, vh, &b) or_return
		ins_texts[i] = b[:]
	}

	deleted_flags := make_deleted_flags(items[:], cx.allocator) or_return
	defer delete(deleted_flags, cx.allocator)
	if len(d.order) > 0 { validate_order(d.order, deleted_flags, ins_count, cx.allocator) or_return }
	order: [dynamic]int
	if is_obj {
		order = build_effective_slots(len(items), deleted_flags, d.inserted_members[:], d.order, cx.allocator) or_return
	} else {
		order = build_effective_slots(len(items), deleted_flags, d.inserted_elems[:], d.order, cx.allocator) or_return
	}
	defer delete(order)

	multiline := len(items) > 0 && bytes.index_byte(cx.src[c_lo:c_hi], '\n') >= 0
	item_indent := line_indent(cx.src, items[0].lo) if multiline else ""
	moves := make([dynamic]Move, 0, len(order) * 4 + 2, cx.allocator)
	if is_obj && len(order) > 0 && !multiline { push_move_str(&moves, " ", cx.allocator) or_return }
	prev_had_comma := false
	for k, pos in order {
		if pos > 0 {
			if multiline { push_move_nl_indent(&moves, cx.eol, item_indent, !prev_had_comma, cx.allocator) } else { push_move_str(&moves, ", ", cx.allocator) or_return }
		} else if multiline {
			push_move_nl_indent(&moves, cx.eol, item_indent, false, cx.allocator)
		}
		prev_had_comma = false
		if k < len(items) {
			it := items[k]
			if len(it.renamed_to) > 0 && it.key_hi > it.key_lo {
				kb := make([dynamic]u8, 0, len(it.renamed_to) + 2, cx.allocator)
				if serr := cx.spec.spell_key(cx.spec.data, it.renamed_to, &kb); serr != nil {
					delete(kb)
					return serr
				}
				append(&moves, Move{text = kb[:], written = true})
				append(&moves, Move{lo = it.key_hi, hi = it.hi})
			} else {
				append(&moves, Move{lo = it.lo, hi = it.hi})
			}
			next_b := items[k + 1].lo if k + 1 < len(items) else c_hi - 1
			q := it.hi
			for q < next_b && (cx.src[q] == ' ' || cx.src[q] == '\t' || cx.src[q] == ',') { q += 1 }
			if q < next_b && cx.src[q] == '#' {
				end_c := q
				for end_c < next_b && cx.src[end_c] != '\n' && cx.src[end_c] != '\r' { end_c += 1 }
				if pos + 1 < len(order) {
					push_move_str(&moves, ",", cx.allocator) or_return
					prev_had_comma = true
				}
				append(&moves, Move{text = slice.clone(cx.src[q - 1:end_c], cx.allocator), written = true})
			}
		} else {
			append(&moves, Move{text = slice.clone(ins_texts[k - len(items)], cx.allocator), written = true})
		}
	}
	if is_obj && len(order) > 0 && !multiline {
		push_move_str(&moves, " ", cx.allocator) or_return
	} else if multiline && len(order) > 0 {
		push_move_nl_indent(&moves, cx.eol, line_indent(cx.src, c_hi - 1), false, cx.allocator)
	}
	push_splice(cx.splices, c_lo + 1, c_hi - 1, base_node = base_c, moves = moves[:]) or_return
	return nil
}

@(private = "file")
leaf_line_range :: proc(cx: ^Section_Cx, kn, vn: tape.Node_Index) -> (Byte_Range, bool) {
	klo, _, kok := node_byte_span(cx.doc, kn)
	_, vhi, vok := node_byte_span(cx.doc, vn)
	if !kok || !vok { return {}, false }
	ls := line_start(cx.src, klo)
	for f in tape.facts_of(cx.doc, vn) {
		if f.kind == .Comment { ls = min(ls, line_start(cx.src, f.lo)) }
	}
	return {ls, next_line(cx.src, vhi)}, true
}

@(private = "file")
collect_dotted_member_ranges :: proc(cx: ^Section_Cx, base_d: tape.Node_Index, base_path: string, span_lo, span_hi: u64, ranges: ^[dynamic]Byte_Range) {
	Frame :: struct { node: tape.Node_Index, path: string }
	stack := make([dynamic]Frame, 0, 4, cx.allocator)
	defer delete(stack)
	append(&stack, Frame{base_d, base_path})
	for len(stack) > 0 {
		fr := pop(&stack)
		c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, fr.node, cx.allocator)
		if cerr != nil { continue }
		if p == .Found {
			for {
				kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
				if np != .Found { break }
				st := toml_style_of(cx.doc, vn)
				vnode := cx.doc.nodes[vn]
				if (vnode.kind == .Object || vnode.kind == .Array) && (st == "header" || st == "implicit" || (vnode.kind == .Object && st == "dotted")) {
					tk := decode_node_text_tmp(cx.doc, kn, cx.allocator)
					cp, jerr := join_dotted_path(cx, fr.path, tk.text)
					free_tmp_text(tk, cx.allocator)
					if jerr == nil {
						if st == "dotted" {
							append(&stack, Frame{vn, cp})
						} else {
							for sec in cx.sections {
								if section_in_span(sec, span_lo, span_hi) && path_matches_or_child(sec.path, cp) {
									append(ranges, Byte_Range{sec.head_lo, sec.body_hi})
								}
							}
						}
					}
					continue
				}
				if kn != tape.NO_NODE {
					if r, rok := leaf_line_range(cx, kn, vn); rok { append(ranges, r) }
				}
			}
		}
		tape.destroy_children(&c)
	}
}

@(private = "file")
toml_dotted_segment_span :: proc "contextless" (src: []u8, key_token_lo: u64, seg_idx: int) -> (lo, hi: u64, ok: bool) {
	p, n := line_start(src, key_token_lo), u64(len(src))
	for s := 0; s <= seg_idx; s += 1 {
		p = skip_hws(src, p, n)
		if p >= n || src[p] == '=' || src[p] == '\n' || src[p] == '\r' { return 0, 0, false }
		seg_lo := p
		if src[p] == '\'' || src[p] == '"' {
			p = skip_toml_quoted(src, p, n)
		} else {
			for p < n && src[p] != '.' && src[p] != '=' && src[p] != ' ' && src[p] != '\t' && src[p] != '\n' && src[p] != '\r' { p += 1 }
		}
		if s == seg_idx { return seg_lo, p, p > seg_lo }
		p = skip_hws(src, p, n)
		if p >= n || src[p] != '.' { return 0, 0, false }
		p += 1
	}
	return 0, 0, false
}

@(private = "file")
toml_dotted_depth :: proc "contextless" (dot_pref: string) -> int {
	if len(dot_pref) == 0 { return 0 }
	count := 1
	b := transmute([]u8)dot_pref
	for i, n := u64(0), u64(len(b)); i < n; {
		if b[i] == '"' || b[i] == '\'' {
			i = skip_toml_quoted(b, i, n)
		} else {
			if b[i] == '.' { count += 1 }
			i += 1
		}
	}
	return count
}

@(private = "file")
toml_member_ranges :: proc(cx: ^Section_Cx, kn, vn: tape.Node_Index, full_path: string, span_lo, span_hi: u64, allocator: runtime.Allocator) -> (ranges: [dynamic]Byte_Range, is_section, is_dotted: bool) {
	ranges = make([dynamic]Byte_Range, 0, 2, allocator)
	vnode, st := cx.doc.nodes[vn], toml_style_of(cx.doc, vn)
	if (vnode.kind == .Object || vnode.kind == .Array) && (st == "header" || st == "implicit") {
		for sec in cx.sections {
			if section_in_span(sec, span_lo, span_hi) && path_matches_or_child(sec.path, full_path) {
				append(&ranges, Byte_Range{sec.head_lo, sec.body_hi})
			}
		}
		if len(ranges) > 0 { return ranges, true, false }
	}
	if vnode.kind == .Object && st == "dotted" {
		collect_dotted_member_ranges(cx, vn, full_path, span_lo, span_hi, &ranges)
		return ranges, false, true
	}
	if r, rok := leaf_line_range(cx, kn, vn); rok { append(&ranges, r) }
	return ranges, false, false
}

@(private = "file")
toml_table_insert_pos_ex :: proc(cx: ^Section_Cx, sec_path: string, span_lo, span_hi: u64, allow_array := false) -> (u64, bool) {
	if len(sec_path) == 0 {
		for sec in cx.sections { if section_in_span(sec, span_lo, span_hi) { return sec.head_lo, true } }
		return span_hi, true
	}
	for sec in cx.sections {
		if section_in_span(sec, span_lo, span_hi) && sec.path == sec_path && (!sec.is_array || allow_array) {
			return sec.body_hi, true
		}
	}
	return span_hi, false
}

@(private = "file")
toml_implicit_insert_pos :: proc(cx: ^Section_Cx, path_pref: string, span_lo, span_hi: u64) -> u64 {
	best, has_best := span_hi, false
	for sec in cx.sections {
		if section_in_span(sec, span_lo, span_hi) && path_matches_or_child(sec.path, path_pref) { best, has_best = sec.body_hi, true }
	}
	return best if has_best else span_hi
}

@(private = "file")
emit_toml_header_renames :: proc(cx: ^Section_Cx, path_pref, old_full, renamed_to: string, base_c: tape.Node_Index, span_lo, span_hi: u64) -> Error {
	new_pref := join_dotted_path(cx, path_pref, renamed_to) or_return
	defer delete(new_pref, cx.allocator)
	for sec in cx.sections {
		if !section_in_span(sec, span_lo, span_hi) || !path_matches_or_child(sec.path, old_full) { continue }
		nb := make([dynamic]u8, 0, len(new_pref) + len(sec.path), cx.allocator)
		append(&nb, new_pref)
		if len(sec.path) > len(old_full) { append(&nb, sec.path[len(old_full):]) }
		push_splice(cx.splices, sec.header_key_lo, sec.header_key_hi, nb[:], base_c, full_rewalk = true) or_return
	}
	return nil
}

@(private = "file")
emit_toml_table_delta :: proc(cx: ^Section_Cx, n: ^Edit_Node, fr: Section_Frame, stack: ^[dynamic]Section_Frame) -> Error {
	d := n.delta
	if d == nil { return nil }
	base_c, path_pref := n.base, fr.path_pref
	T_Member :: struct {
		kn, vn:                         tape.Node_Index,
		key, full_path, renamed_to:     string,
		ranges:                         [dynamic]Byte_Range,
		is_section, is_dotted, deleted: bool,
	}
	members := make([dynamic]T_Member, 0, 8, cx.allocator)
	defer {
		for m in members { delete(m.ranges) }
		delete(members)
	}
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
	if cerr != nil { return cerr }
	defer tape.destroy_children(&c)
	if p == .Found {
		for {
			kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
			if np != .Found { break }
			k := decode_node_text_tmp(cx.doc, kn, cx.allocator)
			k_owned := string(slice.clone(transmute([]u8)k.text, cx.allocator))
			free_tmp_text(k, cx.allocator)
			fp, jerr := join_dotted_path(cx, path_pref, k_owned)
			if jerr != nil {
				delete(k_owned, cx.allocator)
				return jerr
			}
			is_del, ren_to := base_delta_status(d, k_owned, 0, true)
			ranges, is_sec, is_dot := toml_member_ranges(cx, kn, vn, fp, fr.span_lo, fr.span_hi, cx.allocator)
			append(&members, T_Member{kn, vn, k_owned, fp, ren_to, ranges, is_sec, is_dot, is_del})
		}
	}

	for m in members {
		if m.deleted { continue }
		if ch, _, ed := find_edited_child(cx.ov, m.vn); ed {
			push_section_child_frame(cx, fr, ch, m.kn, m.vn, true, -1, nil, stack) or_return
		}
		if len(m.renamed_to) == 0 { continue }
		if m.is_section {
			emit_toml_header_renames(cx, path_pref, m.full_path, m.renamed_to, base_c, fr.span_lo, fr.span_hi) or_return
		} else if m.is_dotted {
			seg_idx := toml_dotted_depth(fr.dot_pref)
			new_seg := make([dynamic]u8, 0, len(m.renamed_to) + 2, cx.allocator)
			cx.spec.spell_key(cx.spec.data, m.renamed_to, &new_seg) or_return
			for r in m.ranges {
				if t := skip_hws(cx.src, r.lo, r.hi); t < r.hi && cx.src[t] == '[' { continue }
				if slo, shi, sok := toml_dotted_segment_span(cx.src, r.lo, seg_idx); sok {
					push_splice(cx.splices, slo, shi, slice.clone(new_seg[:], cx.allocator), base_c, full_rewalk = true) or_return
				}
			}
			delete(new_seg)
			emit_toml_header_renames(cx, path_pref, m.full_path, m.renamed_to, base_c, fr.span_lo, fr.span_hi) or_return
		} else if klo, khi, kok := node_byte_span(cx.doc, m.kn); kok {
			kb := make([dynamic]u8, 0, len(m.renamed_to) + 2, cx.allocator)
			cx.spec.spell_key(cx.spec.data, m.renamed_to, &kb) or_return
			push_splice(cx.splices, klo, khi, kb[:], base_c, full_rewalk = true) or_return
		}
	}

	for ins in d.inserted_members {
		if node_kind(cx.ov, ins.value) == .Null { return refuse(.Unspellable_Value, "TOML has no null value", base_c) }
	}

	allow_arr_owner := len(fr.owner_sec) > 0 && n.base != tape.NO_NODE && n.base != tape.ROOT
	if len(d.order) > 0 {
		deleted_flags := make_deleted_flags(members[:], cx.allocator) or_return
		defer delete(deleted_flags, cx.allocator)
		validate_order(d.order, deleted_flags, len(d.inserted_members), cx.allocator) or_return

		span_lo, span_hi := fr.span_hi, fr.span_lo
		for m in members {
			for r in m.ranges { span_lo, span_hi = min(span_lo, r.lo), max(span_hi, r.hi) }
		}
		if span_lo < span_hi {
			for sec in cx.sections {
				if sec.head_lo < span_lo || sec.head_lo >= span_hi { continue }
				owned := false
				outer: for m in members {
					for r in m.ranges {
						if sec.head_lo >= r.lo && sec.body_hi <= r.hi {
							owned = true
							break outer
						}
					}
				}
				if !owned { return reflow_or_refuse(cx, "TOML table reorder spans a foreign section; pass reflow=true", base_c) }
			}
			_, found_sec := toml_table_insert_pos_ex(cx, path_pref, fr.span_lo, fr.span_hi, allow_array = allow_arr_owner)
			need_implicit_hdr := len(fr.dot_pref) == 0 && len(path_pref) > 0 && !found_sec
			if need_implicit_hdr {
				has_base_nonsec, has_ins_scalar := false, false
				for raw in d.order {
					k := int(raw)
					if k < len(members) {
						if !members[k].is_section { has_base_nonsec = true }
					} else if node_kind(cx.ov, d.inserted_members[k - len(members)].value) != .Object {
						has_ins_scalar = true
					}
				}
				if has_base_nonsec && has_ins_scalar {
					return reflow_or_refuse(cx, "TOML table reorder with dotted keys and implicit header requires reflow=true", base_c)
				}
			}
			moves := make([dynamic]Move, 0, len(d.order) * 2 + 1, cx.allocator)
			emitted_implicit_hdr := false
			for pass in 0 ..< (1 if len(fr.dot_pref) > 0 else 2) {
				want_sec := pass == 1
				for raw in d.order {
					k := int(raw)
					if k < len(members) {
						if members[k].is_section == want_sec {
							for r in members[k].ranges { append(&moves, Move{lo = r.lo, hi = r.hi}) }
						}
					} else {
						ins := d.inserted_members[k - len(members)]
						if (len(fr.dot_pref) == 0 && node_kind(cx.ov, ins.value) == .Object) != want_sec { continue }
						if !want_sec && need_implicit_hdr && !emitted_implicit_hdr {
							emitted_implicit_hdr = true
							hb := make([dynamic]u8, 0, len(path_pref) + 4, cx.allocator)
							append_toml_header(&hb, path_pref, false, cx.eol)
							append(&moves, Move{text = hb[:], written = true})
						}
						append(&moves, Move{text = spell_toml_member_line(cx, ins.key, ins.value, path_pref, fr.dot_pref) or_return, written = true})
					}
				}
			}
			push_splice(cx.splices, span_lo, span_hi, base_node = base_c, full_rewalk = true, moves = moves[:]) or_return
			return nil
		}
	}

	for m in members {
		if !m.deleted { continue }
		for r in m.ranges { push_splice(cx.splices, r.lo, r.hi, base_node = base_c, full_rewalk = true) or_return }
	}
	if len(d.inserted_members) == 0 { return nil }

	if len(fr.dot_pref) == 0 {
		ins_pos, found_sec := toml_table_insert_pos_ex(cx, path_pref, fr.span_lo, fr.span_hi, allow_array = allow_arr_owner)
		if !found_sec && len(path_pref) > 0 {
			impl_pos := toml_implicit_insert_pos(cx, path_pref, fr.span_lo, fr.span_hi)
			scalar_batch := make([dynamic]u8, 0, 64, cx.allocator)
			for ins in d.inserted_members {
				if node_kind(cx.ov, ins.value) == .Object {
					append_toml_line_splice(cx, impl_pos, spell_toml_member_line(cx, ins.key, ins.value, path_pref, "") or_return, base_c) or_return
					continue
				}
				if len(scalar_batch) == 0 { append_toml_header(&scalar_batch, path_pref, false, cx.eol) }
				line := spell_toml_member_line(cx, ins.key, ins.value, path_pref, "") or_return
				append(&scalar_batch, ..line)
				delete(line, cx.allocator)
			}
			if len(scalar_batch) > 0 { append_toml_line_splice(cx, impl_pos, scalar_batch[:], base_c) or_return } else { delete(scalar_batch) }
			return nil
		}
		for ins in d.inserted_members {
			is_obj_val := node_kind(cx.ov, ins.value) == .Object
			pos := fr.span_hi if is_obj_val else ins_pos
			if ins.at >= 0 && ins.at < len(members) && len(members[ins.at].ranges) > 0 && is_obj_val == members[ins.at].is_section {
				pos = members[ins.at].ranges[0].lo
			}
			append_toml_line_splice(cx, pos, spell_toml_member_line(cx, ins.key, ins.value, path_pref, "") or_return, base_c) or_return
		}
		return nil
	}

	dot_ins_pos, has_non_sec := u64(0), false
	for m in members {
		if m.is_section { continue }
		for r in m.ranges {
			if !has_non_sec || r.hi > dot_ins_pos { dot_ins_pos, has_non_sec = r.hi, true }
		}
	}
	if !has_non_sec {
		dot_ins_pos, _ = toml_table_insert_pos_ex(cx, fr.owner_sec, fr.span_lo, fr.span_hi, allow_array = allow_arr_owner)
	}
	for ins in d.inserted_members {
		pos := dot_ins_pos
		if ins.at >= 0 && ins.at < len(members) && !members[ins.at].is_section && len(members[ins.at].ranges) > 0 {
			pos = members[ins.at].ranges[0].lo
		}
		append_toml_line_splice(cx, pos, spell_toml_member_line(cx, ins.key, ins.value, path_pref, fr.dot_pref) or_return, base_c) or_return
	}
	return nil
}

@(private = "file")
append_toml_line_splice :: proc(cx: ^Section_Cx, pos: u64, txt: []u8, base_node: tape.Node_Index) -> Error {
	out_txt := txt
	if pos > 0 && pos <= u64(len(cx.src)) && cx.src[pos - 1] != '\n' {
		prefixed := make([dynamic]u8, 0, len(cx.eol) + len(txt), cx.allocator)
		append(&prefixed, cx.eol)
		append(&prefixed, ..txt)
		delete(txt, cx.allocator)
		out_txt = prefixed[:]
	}
	push_splice(cx.splices, pos, pos, out_txt, base_node, full_rewalk = true) or_return
	return nil
}

@(private = "file")
spell_toml_table_body :: proc(cx: ^Section_Cx, obj_h: Handle, out: ^[dynamic]u8) -> Error {
	mems, owned := effective_members(cx.ov, obj_h, cx.allocator) or_return
	defer destroy_effective_members(mems, owned, cx.allocator)
	for m in mems {
		cx.spec.spell_key(cx.spec.data, m.key, out) or_return
		append(out, " = ")
		vh := m.handle
		if vh == NO_HANDLE && m.base_val != tape.NO_NODE { vh = handle_for_base(cx.ov, m.base_val) or_return }
		spell_toml_val(cx, vh, out) or_return
		append(out, cx.eol)
	}
	return nil
}

@(private = "file")
spell_toml_member_line :: proc(cx: ^Section_Cx, key: string, val_h: Handle, path_pref, dot_pref: string) -> (out: []u8, err: Error) {
	b := make([dynamic]u8, 0, 64, cx.allocator)
	if node_kind(cx.ov, val_h) == .Object && len(dot_pref) == 0 {
		append(&b, cx.eol)
		append(&b, '[')
		if len(path_pref) > 0 { append(&b, path_pref); append(&b, '.') }
		cx.spec.spell_key(cx.spec.data, key, &b) or_return
		append(&b, ']')
		append(&b, cx.eol)
		spell_toml_table_body(cx, val_h, &b) or_return
		return b[:], nil
	}
	vn, vok := get_node(cx.ov, val_h)
	if vok {
		for f in vn.facts { if f.kind == .Comment && !f.deleted { append_toml_comments(cx, f.values, f.padded, false, &b, tape.NO_NODE) or_return } }
	}
	if len(dot_pref) > 0 { append(&b, dot_pref); append(&b, '.') }
	cx.spec.spell_key(cx.spec.data, key, &b) or_return
	append(&b, " = ")
	spell_toml_val(cx, val_h, &b) or_return
	if vok {
		for f in vn.facts { if f.kind == .Comment_Inline && !f.deleted && len(f.values) > 0 { append_toml_comments(cx, f.values, f.padded, true, &b, tape.NO_NODE) or_return } }
	}
	append(&b, cx.eol)
	return b[:], nil
}

@(private = "file")
emit_toml_aot_delta :: proc(cx: ^Section_Cx, n: ^Edit_Node, fr: Section_Frame, stack: ^[dynamic]Section_Frame) -> Error {
	d := n.delta
	if d == nil { return nil }
	path_pref := fr.path_pref
	aot_items := collect_aot_items(cx, path_pref, fr.span_lo, fr.span_hi, d.deleted_indices[:])
	defer delete(aot_items)

	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, n.base, cx.allocator)
	if cerr != nil { return cerr }
	defer tape.destroy_children(&c)
	if p == .Found {
		for idx := 0; ; idx += 1 {
			kn, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
			if np != .Found { break }
			if idx < len(aot_items) && aot_items[idx].deleted { continue }
			if ch, _, ed := find_edited_child(cx.ov, vn); ed {
				push_section_child_frame(cx, fr, ch, kn, vn, false, idx, aot_items[:], stack) or_return
			}
		}
	}

	ins_texts := make([][]u8, len(d.inserted_elems), cx.allocator)
	defer delete(ins_texts, cx.allocator)
	for ins, i in d.inserted_elems {
		if node_kind(cx.ov, ins.value) != .Object { return refuse(.Unspellable_Value, "TOML array of tables requires table elements", n.base) }
		b := make([dynamic]u8, 0, 64, cx.allocator)
		append_toml_header(&b, path_pref, true, cx.eol)
		spell_toml_table_body(cx, ins.value, &b) or_return
		ins_texts[i] = b[:]
	}

	if len(d.order) > 0 {
		deleted_flags := make_deleted_flags(aot_items[:], cx.allocator) or_return
		defer delete(deleted_flags, cx.allocator)
		validate_order(d.order, deleted_flags, len(d.inserted_elems), cx.allocator) or_return
		if len(aot_items) > 0 {
			span_lo, span_hi := aot_items[0].lo, aot_items[len(aot_items) - 1].hi
			for sec in cx.sections {
				if sec.head_lo >= span_lo && sec.head_lo < span_hi && !path_matches_or_child(sec.path, path_pref) {
					return reflow_or_refuse(cx, "TOML array-of-tables reorder spans a foreign section; pass reflow=true", n.base)
				}
			}
			moves := make([dynamic]Move, 0, len(d.order), cx.allocator)
			for raw in d.order {
				k := int(raw)
				if k < len(aot_items) {
					append(&moves, Move{lo = aot_items[k].lo, hi = aot_items[k].hi})
				} else {
					append(&moves, Move{text = slice.clone(ins_texts[k - len(aot_items)], cx.allocator), written = true})
				}
			}
			push_splice(cx.splices, span_lo, span_hi, base_node = n.base, full_rewalk = true, moves = moves[:]) or_return
			return nil
		}
	}

	for it in aot_items {
		if it.deleted { push_splice(cx.splices, it.lo, it.hi, base_node = n.base, full_rewalk = true) or_return }
	}
	for ins, i in d.inserted_elems {
		pos := fr.span_hi
		if ins.at >= 0 && ins.at < len(aot_items) {
			pos = aot_items[ins.at].lo
		} else if len(aot_items) > 0 {
			pos = aot_items[len(aot_items) - 1].hi
		}
		append_toml_line_splice(cx, pos, ins_texts[i], n.base) or_return
	}
	return nil
}
