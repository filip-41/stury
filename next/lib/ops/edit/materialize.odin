package edit

import "base:runtime"
import "core:bytes"
import "core:encoding/endian"
import "core:math"
import "core:slice"
import "core:strconv"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Generic rodata `tape.Format` attached to materialized documents when no format-specific `target_format` is passed.
@(private = "file", rodata)
MATERIALIZED_FORMAT := tape.Format {
	name      = "materialized",
	facts     = tape.COMMENTS + {.Tag, .Style, .Attribute},
	dups      = .All,
	bounds    = proc "contextless" (_: []u8, _: tape.Token) -> (u8, u8) { return 0, 0 },
	room      = proc "contextless" (_: []u8, t: tape.Node, _: ^tape.Format_Ext) -> int { return int(t.n) },
	number    = mat_number,
	same_text = proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
		return t.n == o.n && string(src[t.lo : t.lo + u64(t.n)]) == string(other[o.lo : o.lo + u64(o.n)])
	},
	key_hash  = proc "contextless" (src: []u8, t: tape.Token) -> u32 { return tape.text_hash(src[t.lo : t.lo + u64(t.n)]) },
	fact_name = mat_fact_name,
}

@(private = "file")
mat_number :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
	hi := t.lo + u64(t.n)
	if n, ok := spell.number_strict(src, t.lo, hi); ok { return n }
	switch string(src[t.lo:hi]) {
	case "NaN": return {bits = transmute(u64)math.nan_f64(), kind = .Float}
	case "Infinity", "+Infinity": return {bits = transmute(u64)math.inf_f64(1), kind = .Float}
	case "-Infinity": return {bits = transmute(u64)math.inf_f64(-1), kind = .Float}
	}
	return {kind = .Wide}
}

@(private = "file")
mat_fact_name :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index, kind: tape.Fact_Kind) -> (string, bool) {
	for f in tape.facts_of(doc, at) {
		if f.kind == kind && f.n > 0 { return string(tape.span_bytes(doc, f.lo, f.n)), true }
	}
	return "", false
}

Materialize_Options :: struct {
	wrap_key:                                                           string,
	dedup_keys, cbor_tags, xml_attrs, skip_root_attrs, skip_root_tags:  bool,
	include_root_comments, include_root_foot, flatten_xml_arrays:       bool,
	track_handle:                                                       Handle,
	tracked_node:                                                       ^tape.Node_Index,
	target_format:                                                      ^tape.Format,
	root_style:                                                         string,
}

@(private = "file")
Mat_Frame :: struct {
	node_idx, idx, child_n:    int,
	is_obj:                    bool,
	elems:                     []Effective_Element,
	members:                   []Effective_Member,
	owned_keys:                []string,
	base_c, base_end, base_cur: tape.Node_Index,
}

@(private = "file")
Mat_Cx :: struct {
	ov:        ^Overlay,
	opts:      Materialize_Options,
	src:       [dynamic]u8,
	nodes:     [dynamic]tape.Node,
	facts:     [dynamic]tape.Fact,
	counts:    [dynamic]tape.Child_Count,
	present:   tape.Facts,
	stack:     [dynamic]Mat_Frame,
	allocator: runtime.Allocator,
}

materialize_subtree :: proc(ov: ^Overlay, root_h: Handle, base_node := tape.NO_NODE, opts := Materialize_Options{}, allocator := context.allocator) -> (doc: tape.Document, err: Error) {
	if ov == nil || ov.base == nil { return {}, refuse(.No_Document, "materialize_subtree requires an overlay") }
	if ov.unlinked_parents {
		if rn, ok := get_node(ov, root_h); !(ok && rn.state == .Replaced && rn.val.kind < .Array) {
			ensure_linked(ov) or_return
		}
	}

	cx := Mat_Cx {
		ov = ov, opts = opts, allocator = allocator,
		src = make([dynamic]u8, 0, 256, allocator), nodes = make([dynamic]tape.Node, 0, 32, allocator),
		facts = make([dynamic]tape.Fact, 0, 8, allocator), counts = make([dynamic]tape.Child_Count, 0, 4, allocator),
		stack = make([dynamic]Mat_Frame, 0, 16, allocator),
	}
	defer {
		for &fr in cx.stack {
			delete(fr.elems, allocator)
			destroy_effective_members(fr.members, fr.owned_keys, allocator)
		}
		delete(cx.stack)
		delete(cx.src)
		delete(cx.nodes)
		delete(cx.facts)
		delete(cx.counts)
	}

	wrapped := len(opts.wrap_key) > 0
	if wrapped {
		append(&cx.nodes, tape.Node{kind = .Object, role = .Value}) or_return
		mat_append_node(&cx, opts.wrap_key, .String, .Key) or_return
	}
	if opts.tracked_node != nil { opts.tracked_node^ = tape.NO_NODE }

	mat_emit_one(&cx, root_h, base_node, .Value, opts.root_style, true) or_return

	for len(cx.stack) > 0 {
		fr := &cx.stack[len(cx.stack) - 1]
		done := (fr.base_cur >= fr.base_end) if fr.base_c != tape.NO_NODE else (fr.idx >= (len(fr.members) if fr.is_obj else len(fr.elems)))
		if done {
			finalize_mat_frame(&cx.nodes, &cx.counts, fr) or_return
			if fr.base_c == tape.NO_NODE {
				if fr.is_obj { destroy_effective_members(fr.members, fr.owned_keys, allocator) } else { delete(fr.elems, allocator) }
			}
			pop(&cx.stack)
			continue
		}
		fr.child_n += 1
		if fr.base_c != tape.NO_NODE {
			kn := fr.base_cur
			vn := kn + 1 if fr.is_obj else kn
			fr.base_cur = tape.node_after(ov.base, vn)
			if fr.is_obj {
				kt := decode_node_text_tmp(ov.base, kn, allocator)
				ksp := tape.SPELLING_TEXT_KEY if (opts.xml_attrs && tape.is_text_key(ov.base.nodes[kn])) else u16(0)
				aerr := mat_append_node(&cx, kt.text, .String, .Key, ksp)
				free_tmp_text(kt, allocator)
				if aerr != nil { return {}, aerr }
			}
			mat_emit_one(&cx, NO_HANDLE, vn, .Value, "", false) or_return
		} else if fr.is_obj {
			m := fr.members[fr.idx]
			fr.idx += 1
			ksp := tape.SPELLING_TEXT_KEY if (opts.xml_attrs && m.key == tape.TEXT_KEY) else u16(0)
			mat_append_node(&cx, m.key, .String, .Key, ksp) or_return
			mat_emit_one(&cx, m.handle, m.base_val, .Value, "", false) or_return
		} else {
			e := fr.elems[fr.idx]
			fr.idx += 1
			mat_emit_one(&cx, e.handle, e.base, .Value, "", false) or_return
		}
	}

	if wrapped { cx.nodes[0].n, cx.nodes[0].spelling = u32(len(cx.nodes)), 1 }
	if opts.tracked_node != nil && opts.tracked_node^ == tape.NO_NODE && opts.track_handle != NO_HANDLE {
		if rn, rok := get_node(ov, opts.track_handle); rok && rn.handle == ov.root { opts.tracked_node^ = 0 }
	}

	out_src := alloc_exact_slice(cx.src[:], allocator) or_return
	defer if err != nil { delete(out_src, allocator) }
	out_nodes := alloc_exact_slice(cx.nodes[:], allocator) or_return
	defer if err != nil { delete(out_nodes, allocator) }
	out_facts := alloc_exact_slice(cx.facts[:], allocator) or_return
	defer if err != nil { delete(out_facts, allocator) }
	out_counts := alloc_exact_slice(cx.counts[:], allocator) or_return

	flags := tape.Doc_Flags{.Owns_Src}
	if opts.target_format != nil { flags += {.Tolerated} }
	return tape.Document {
		src = out_src, nodes = out_nodes, facts = out_facts, counts = out_counts,
		format = opts.target_format if opts.target_format != nil else &MATERIALIZED_FORMAT,
		root_close = u64(len(out_src)), present = cx.present, flags = flags, allocator = allocator,
	}, nil
}

@(private = "file")
mat_append_node :: proc(cx: ^Mat_Cx, s: string, kind: tape.Kind, role: tape.Role, spelling: u16 = 0) -> runtime.Allocator_Error {
	lo := u64(len(cx.src))
	append(&cx.src, s) or_return
	append(&cx.nodes, tape.Node{lo = lo, n = u32(len(s)), kind = kind, role = role, spelling = spelling}) or_return
	return nil
}

@(private = "file")
mat_append_fact :: proc(cx: ^Mat_Cx, out_node: tape.Node_Index, kind: tape.Fact_Kind, raw: []u8, spelling: u16 = 0) -> runtime.Allocator_Error {
	lo := u64(len(cx.src))
	append(&cx.src, ..raw) or_return
	append(&cx.facts, tape.Fact{node = out_node, lo = lo, n = u32(len(raw)), kind = kind, spelling = spelling}) or_return
	cx.present += {kind}
	return nil
}

@(private = "file")
mat_append_xml_attr :: proc(cx: ^Mat_Cx, out_node: tape.Node_Index, name: string, val: []u8) -> runtime.Allocator_Error {
	lo := u64(len(cx.src))
	append(&cx.src, name) or_return
	append(&cx.src, `="`) or_return
	for c in val {
		switch c {
		case '&': append(&cx.src, "&amp;") or_return
		case '<': append(&cx.src, "&lt;") or_return
		case '>': append(&cx.src, "&gt;") or_return
		case '"': append(&cx.src, "&quot;") or_return
		case '\t': append(&cx.src, "&#9;") or_return
		case '\n': append(&cx.src, "&#10;") or_return
		case '\r': append(&cx.src, "&#13;") or_return
		case: append(&cx.src, c) or_return
		}
	}
	append(&cx.src, '"') or_return
	append(&cx.facts, tape.Fact{node = out_node, lo = lo, n = u32(u64(len(cx.src)) - lo), kind = .Attribute, spelling = tape.attribute_spelling(len(name) + 2, true)}) or_return
	cx.present += {.Attribute}
	return nil
}

@(private = "file")
emit_cbor_tag_head :: proc(buf: ^[dynamic]u8, arg: u64) -> (lo: u64, n: u32, aerr: runtime.Allocator_Error) {
	lo = u64(len(buf))
	m := u8(6 << 5)
	switch {
	case arg < 24: append(buf, m | u8(arg)) or_return
	case arg <= 0xFF: append(buf, m | 24, u8(arg)) or_return
	case arg <= 0xFFFF:
		b := [3]u8{m | 25, u8(arg >> 8), u8(arg)}
		append(buf, ..b[:]) or_return
	case arg <= 0xFFFF_FFFF:
		b := [5]u8{m | 26, u8(arg >> 24), u8(arg >> 16), u8(arg >> 8), u8(arg)}
		append(buf, ..b[:]) or_return
	case:
		b: [9]u8
		b[0] = m | 27
		endian.unchecked_put_u64be(b[1:], arg)
		append(buf, ..b[:]) or_return
	}
	return lo, u32(u64(len(buf)) - lo), nil
}

@(private = "file")
mat_emit_facts :: proc(cx: ^Mat_Cx, h: Handle, bn, out_node: tape.Node_Index, extra_style: string, is_root_val: bool) -> Error {
	opts, base := cx.opts, cx.ov.base
	n, has_n := get_node(cx.ov, h)
	allow_comment :: proc "contextless" (kind: tape.Fact_Kind, opts: Materialize_Options, is_root: bool) -> bool {
		return !is_root || opts.include_root_comments || (opts.include_root_foot && kind == .Comment_Foot)
	}
	if bn != tape.NO_NODE && int(bn) < len(base.nodes) {
		for bf in tape.facts_of(base, bn) {
			overridden := false
			if has_n {
				for fo in n.facts {
					if fo.kind != bf.kind { continue }
					if bf.kind != .Attribute {
						overridden = true
						break
					}
					if base.format != nil && base.format.attribute != nil {
						kt, _ := base.format.attribute(base, bf)
						if string(tape.span_bytes(base, kt.lo, kt.n)) == fo.attr {
							overridden = true
							break
						}
					}
				}
			}
			if overridden || (bf.kind == .Style && len(extra_style) > 0) { continue }
			if bf.kind == .Tag && opts.cbor_tags && !(is_root_val && opts.skip_root_tags) {
				mat_append_fact(cx, out_node, .Tag, tape.span_bytes(base, bf.lo, bf.n)) or_return
			} else if bf.kind == .Attribute && opts.xml_attrs && !(is_root_val && opts.skip_root_attrs) {
				if base.ext != nil && base.format != nil && base.format.attribute != nil {
					kt, vt := base.format.attribute(base, bf)
					if tape.text_room(base, vt) > 0 {
						tk := decode_token_text_tmp(base, vt, cx.allocator)
						aerr := mat_append_xml_attr(cx, out_node, string(tape.span_bytes(base, kt.lo, kt.n)), transmute([]u8)tk.text if len(tk.text) > 0 else tape.span_bytes(base, vt.lo, vt.n))
						free_tmp_text(tk, cx.allocator)
						if aerr != nil { return aerr }
						continue
					}
				}
				mat_append_fact(cx, out_node, .Attribute, tape.span_bytes(base, bf.lo, bf.n), bf.spelling) or_return
			} else if bf.kind in tape.COMMENTS && allow_comment(bf.kind, opts, is_root_val) {
				raw := tape.span_bytes(base, bf.lo, bf.n)
				lead := min(int(tape.fact_lead(bf.spelling)), len(raw))
				tail := min(int(tape.fact_tail(bf.spelling)), len(raw) - lead)
				mat_append_fact(cx, out_node, bf.kind, raw[lead : len(raw) - tail]) or_return
			} else if bf.kind == .Style {
				if sname, ok := tape.fact_name(base, bn, .Style); ok { mat_append_fact(cx, out_node, .Style, transmute([]u8)sname) or_return }
			}
		}
	}
	if has_n {
		for fo in n.facts {
			if fo.deleted { continue }
			#partial switch fo.kind {
			case .Tag:
				if is_root_val && opts.skip_root_tags { continue }
				if opts.cbor_tags {
					tag_num, tok := cbor_parse_tag_override(fo)
					if !tok { return refuse(.Fact_No_Place, "CBOR tag must be an unsigned 64-bit integer", bn) }
					flo, fn := emit_cbor_tag_head(&cx.src, tag_num) or_return
					append(&cx.facts, tape.Fact{node = out_node, lo = flo, n = fn, kind = .Tag}) or_return
					cx.present += {.Tag}
				} else if len(fo.values) > 0 {
					mat_append_fact(cx, out_node, .Tag, transmute([]u8)fo.values[0]) or_return
				}
			case .Attribute:
				if opts.xml_attrs && !(is_root_val && opts.skip_root_attrs) && len(fo.values) > 0 {
					mat_append_xml_attr(cx, out_node, fo.attr, transmute([]u8)fo.values[0]) or_return
				}
			case .Comment, .Comment_Inline, .Comment_Foot:
				if !allow_comment(fo.kind, opts, is_root_val) { continue }
				for line in fo.values {
					flo, pad := u64(len(cx.src)), fo.padded && len(line) > 0
					if pad && line[0] != ' ' && line[0] != '\t' { append(&cx.src, ' ') or_return }
					append(&cx.src, line) or_return
					if pad && line[len(line) - 1] != ' ' && line[len(line) - 1] != '\t' {
						has_nl := !opts.xml_attrs && (bytes.index_byte(transmute([]u8)line, '\n') >= 0 || bytes.index_byte(transmute([]u8)line, '\r') >= 0)
						if opts.xml_attrs || (opts.target_format == nil && has_nl) { append(&cx.src, ' ') or_return }
					}
					append(&cx.facts, tape.Fact{node = out_node, lo = flo, n = u32(u64(len(cx.src)) - flo), kind = fo.kind}) or_return
					cx.present += {fo.kind}
				}
			case .Style:
				if len(fo.values) > 0 && len(extra_style) == 0 { mat_append_fact(cx, out_node, .Style, transmute([]u8)fo.values[0]) or_return }
			}
		}
	}
	if len(extra_style) > 0 { mat_append_fact(cx, out_node, .Style, transmute([]u8)extra_style) or_return }
	return nil
}

@(private = "file")
mat_push_overlay_container :: proc(cx: ^Mat_Cx, eff_h: Handle, is_obj: bool, out_idx: tape.Node_Index, role: tape.Role) -> Error {
	append(&cx.nodes, tape.Node{kind = .Object if is_obj else .Array, role = role}) or_return
	if is_obj {
		ms, oks := materialize_obj_members(cx.ov, eff_h, cx.opts, cx.allocator) or_return
		append(&cx.stack, Mat_Frame{node_idx = int(out_idx), is_obj = true, members = ms, owned_keys = oks, base_c = tape.NO_NODE}) or_return
	} else {
		es := effective_elements(cx.ov, eff_h, cx.allocator) or_return
		append(&cx.stack, Mat_Frame{node_idx = int(out_idx), elems = es, base_c = tape.NO_NODE}) or_return
	}
	return nil
}

@(private = "file")
mat_emit_one :: proc(cx: ^Mat_Cx, h: Handle, bn: tape.Node_Index, role: tape.Role, extra_style: string, is_root_val: bool) -> Error {
	out_idx := tape.Node_Index(len(cx.nodes))
	if cx.opts.tracked_node != nil && cx.opts.track_handle != NO_HANDLE && h == cx.opts.track_handle { cx.opts.tracked_node^ = out_idx }

	eff_h, eff_bn := h, bn
	if n, ok := get_node(cx.ov, eff_h); ok {
		if n.state == .Replaced && n.val.kind == .Base_Ref {
			eff_bn, eff_h = n.val.base_ref, NO_HANDLE
		} else if n.state == .Ancestor && !n.has_edits {
			eff_bn, eff_h = n.base, NO_HANDLE
		} else if n.base != tape.NO_NODE && eff_bn == tape.NO_NODE {
			eff_bn = n.base
		}
	}

	mat_emit_facts(cx, h, eff_bn, out_idx, extra_style, is_root_val) or_return

	if eff_h != NO_HANDLE {
		n, ok := get_node(cx.ov, eff_h)
		if !ok { return refuse(.Bad_Handle, "invalid handle in materialize_subtree") }
		if n.state == .Replaced {
			nbuf: [64]u8
			switch n.val.kind {
			case .None, .Null: append(&cx.nodes, tape.Node{kind = .Null, role = role}) or_return
			case .False: append(&cx.nodes, tape.Node{kind = .False, role = role}) or_return
			case .True: append(&cx.nodes, tape.Node{kind = .True, role = role}) or_return
			case .Int: mat_append_node(cx, strconv.write_int(nbuf[:], n.val.i, 10), .Number, role) or_return
			case .Uint: mat_append_node(cx, strconv.write_uint(nbuf[:], n.val.u, 10), .Number, role) or_return
			case .Float: mat_append_node(cx, format_float_str(n.val.f, nbuf[:]), .Number, role) or_return
			case .Number_Text: mat_append_node(cx, n.val.text, .Number, role) or_return
			case .String: mat_append_node(cx, n.val.text, .String, role) or_return
			case .Raw: mat_append_node(cx, n.val.text, .Plain, role) or_return
			case .Bytes: mat_append_node(cx, string(n.val.raw), .Bytes, role) or_return
			case .Base_Ref:
			case .Array, .Object: return mat_push_overlay_container(cx, eff_h, n.val.kind == .Object, out_idx, role)
			}
			return nil
		}
		if k := node_kind(cx.ov, eff_h); k == .Object || k == .Array {
			return mat_push_overlay_container(cx, eff_h, k == .Object, out_idx, role)
		}
	}

	base := cx.ov.base
	if eff_bn == tape.NO_NODE || int(eff_bn) >= len(base.nodes) {
		append(&cx.nodes, tape.Node{kind = .Null, role = role}) or_return
		return nil
	}
	bt := base.nodes[eff_bn]
	#partial switch bt.kind {
	case .Null, .False, .True:
		append(&cx.nodes, tape.Node{kind = bt.kind, role = role}) or_return
	case .Number:
		if num, nok := tape.node_number(base, eff_bn); nok && num.kind != .Wide {
			nbuf: [64]u8
			s: string
			#partial switch num.kind {
			case .Int: s = strconv.write_int(nbuf[:], i64(num.bits), 10)
			case .Uint: s = strconv.write_uint(nbuf[:], num.bits, 10)
			case .Float: s = format_float_str(transmute(f64)num.bits, nbuf[:])
			}
			mat_append_node(cx, s, .Number, role) or_return
		} else {
			tk := decode_node_text_tmp(base, eff_bn, cx.allocator)
			defer free_tmp_text(tk, cx.allocator)
			mat_append_node(cx, tk.text, .Number, role) or_return
		}
	case .String, .Plain, .Bytes:
		tk := decode_node_text_tmp(base, eff_bn, cx.allocator)
		defer free_tmp_text(tk, cx.allocator)
		mat_append_node(cx, tk.text, .Bytes if bt.kind == .Bytes else .String, role) or_return
	case .Array, .Object:
		append(&cx.nodes, tape.Node{kind = bt.kind, role = role}) or_return
		append(&cx.stack, Mat_Frame{node_idx = int(out_idx), is_obj = bt.kind == .Object, base_c = eff_bn, base_cur = eff_bn + 1, base_end = eff_bn + tape.Node_Index(bt.n)}) or_return
	}
	return nil
}

@(private = "file")
finalize_mat_frame :: proc(nodes: ^[dynamic]tape.Node, counts: ^[dynamic]tape.Child_Count, fr: ^Mat_Frame) -> runtime.Allocator_Error {
	idx := fr.node_idx
	nodes[idx].n = u32(len(nodes) - idx)
	if fr.child_n < int(tape.MAX_CHILDREN) {
		nodes[idx].spelling = u16(fr.child_n)
	} else {
		nodes[idx].spelling = tape.MAX_CHILDREN
		append(counts, tape.Child_Count{node = tape.Node_Index(idx), count = u32(fr.child_n)}) or_return
	}
	return nil
}

@(private)
dedup_effective_members :: proc "contextless" (members: []Effective_Member) -> []Effective_Member {
	w := 0
	for i in 0 ..< len(members) {
		dup_later := false
		for j in i + 1 ..< len(members) {
			if members[j].key == members[i].key {
				dup_later = true
				break
			}
		}
		if !dup_later {
			members[w] = members[i]
			w += 1
		}
	}
	return members[:w]
}

@(private = "file")
materialize_obj_members :: proc(ov: ^Overlay, obj_h: Handle, opts: Materialize_Options, allocator: runtime.Allocator) -> (members: []Effective_Member, owned_keys: []string, err: runtime.Allocator_Error) {
	ms, oks := effective_members(ov, obj_h, allocator) or_return
	if opts.dedup_keys && len(ms) > 1 { ms = dedup_effective_members(ms) }
	if !opts.flatten_xml_arrays || len(ms) == 0 { return ms, oks, nil }
	has_arr := false
	for m in ms {
		if cn, ok := get_node(ov, m.handle); ok && cn.state == .Replaced && cn.val.kind == .Array {
			has_arr = true
			break
		}
	}
	if !has_arr { return ms, oks, nil }
	defer delete(ms, allocator)
	flat := make([dynamic]Effective_Member, 0, len(ms) + 4, allocator)
	defer if err != nil { delete(flat) }
	replaced_keys := make([dynamic]string, 0, 2, allocator)
	defer delete(replaced_keys)
	for m in ms {
		if m.base_val != tape.NO_NODE && !m.is_inserted && slice.contains(replaced_keys[:], m.key) { continue }
		if cn, ok := get_node(ov, m.handle); ok && cn.state == .Replaced && cn.val.kind == .Array {
			append(&replaced_keys, m.key) or_return
			for eh in cn.elems {
				append(&flat, Effective_Member{m.key, eh, tape.NO_NODE, tape.NO_NODE, -1, -1, true, false}) or_return
			}
			continue
		}
		append(&flat, m) or_return
	}
	return flat[:], oks, nil
}

cbor_parse_tag_override :: proc "contextless" (f: Fact_Override) -> (tag: u64, ok: bool) {
	if n, has := f.num_tag.?; has { return n, true }
	if len(f.values) != 1 || len(f.values[0]) == 0 || len(f.values[0]) > 20 { return 0, false }
	val: u64
	for c in transmute([]u8)f.values[0] {
		if c < '0' || c > '9' { return 0, false }
		d := u64(c - '0')
		if val > (max(u64) - d) / 10 { return 0, false }
		val = val * 10 + d
	}
	return val, true
}
