package edit

import "base:runtime"
import "core:container/handle_map"
import "core:slice"
import "stury:lib/core/tape"

// Tabular-family composer (DSV: CSV, TSV, Plain).
// Preserves untargeted rows, cells, delimiters, CRLF/LF line endings, and cell quoting verbatim.

Tabular_Spec :: struct {
	target:     ^tape.Format,
	delimiter:  u8,
	comment:    u8,
	no_header:  bool,
	spell_cell: proc(data: rawptr, ov: ^Overlay, h: Handle, out: ^[dynamic]u8) -> Error,
	validate:   proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	data:       rawptr,
}

@(private = "file")
Tabular_Cx :: struct {
	ov:            ^Overlay,
	doc:           ^tape.Document,
	src:           []u8,
	spec:          ^Tabular_Spec,
	opts:          Options,
	delim, comment: u8,
	no_header:     bool,
	eol:           string,
	splices:       ^[dynamic]Splice,
	dropped:       tape.Facts,
	allocator:     runtime.Allocator,
}

commit_tabular :: proc(ov: ^Overlay, spec: ^Tabular_Spec, opts := Options{}, allocator := context.allocator) -> (Commit_Result, Error) {
	cx := Tabular_Cx {
		ov   = ov,
		doc  = ov.base if ov != nil else nil,
		src  = ov.base.src if ov != nil && ov.base != nil else nil,
		spec = spec,
		opts = opts,
	}
	if ov != nil && ov.base != nil {
		cx.delim, cx.comment, cx.no_header = resolve_tabular_opts(ov.base, spec)
	}
	tc := Text_Composer {
		target        = spec.target,
		extra_clean   = true,
		req_root      = .Array,
		root_msg      = "delimited document root must be an array of rows",
		validate      = spec.validate,
		validate_data = spec.data,
		fast_emit     = tabular_fast_emit,
		struct_emit   = tabular_struct_emit,
		frag_check    = tabular_frag_check,
		user          = &cx,
	}
	return run_text_commit(ov, &tc, opts, allocator)
}

@(private = "file")
resolve_tabular_opts :: proc "contextless" (doc: ^tape.Document, spec: ^Tabular_Spec) -> (delim, comment: u8, no_header: bool) {
	delim, comment, no_header = spec.delimiter, spec.comment, spec.no_header
	if doc.ext != nil {
		if ext, ok := doc.ext.format.(tape.Tabular_Ext); ok {
			if delim == 0 { delim = ext.options.delimiter }
			if comment == 0 { comment = ext.options.comment }
			no_header = ext.options.no_header
		}
	}
	if delim == 0 { delim = ',' }
	return delim, comment, no_header
}

@(private = "file")
emit_cell_replace :: proc(cx: ^Tabular_Cx, cell_node: tape.Node_Index, h: Handle, n: ^Edit_Node) -> Error {
	clo, chi, clok := node_byte_span(cx.doc, cell_node)
	if !clok {
		return refuse(.Bad_Handle, "cannot locate cell span", cell_node)
	}
	text: []u8
	if n.val.kind == .Raw {
		text = transmute([]u8)n.val.text
	} else {
		buf := make([dynamic]u8, 0, 32, cx.allocator)
		cx.spec.spell_cell(cx.spec.data, cx.ov, h, &buf) or_return
		text = buf[:]
	}
	push_splice(cx.splices, clo, chi, text, cell_node, subtree_only = true) or_return
	return nil
}

@(private = "file")
tabular_fast_emit :: proc(user: rawptr, ov: ^Overlay, doc: ^tape.Document, splices: ^[dynamic]Splice, scratch: runtime.Allocator) -> (ok: bool, err: Error) {
	cx := (^Tabular_Cx)(user)
	cx.allocator, cx.splices = scratch, splices
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in dynamic_iter_next(&it) {
		if n.state == .Replaced && n.has_edits && n.base != tape.NO_NODE && doc.nodes[n.base].role == .Value {
			emit_cell_replace(cx, n.base, n.handle, n) or_return
		}
	}
	return true, nil
}

@(private = "file")
tabular_struct_emit :: proc(user: rawptr, ov: ^Overlay, doc: ^tape.Document, eol: string, splices: ^[dynamic]Splice, dropped: ^tape.Facts, scratch: runtime.Allocator) -> Error {
	_ = doc
	cx := (^Tabular_Cx)(user)
	cx.allocator, cx.splices, cx.eol = scratch, splices, eol
	if ov.root != NO_HANDLE {
		compose_tabular_root(cx, ov.root) or_return
	}
	dropped^ = cx.dropped
	return nil
}

@(private = "file")
tabular_frag_check :: proc(user: rawptr, out: []u8, recs: []Splice_Record, scratch: runtime.Allocator) -> (bool, Error) {
	_ = scratch
	cx := (^Tabular_Cx)(user)
	for rec in recs {
		if !rec.subtree_only || rec.full_rewalk || !is_simple_dsv_cell(out[rec.dst_lo:rec.dst_hi], cx.delim, cx.comment, rec.dst_lo == 0) {
			return true, nil
		}
	}
	return false, nil
}

@(private = "file")
tabular_header_keys :: proc(cx: ^Tabular_Cx, allocator: runtime.Allocator) -> []string {
	if cx.no_header || cx.doc.ext == nil { return nil }
	ext, ok := cx.doc.ext.format.(tape.Tabular_Ext)
	if !ok || len(ext.tables) == 0 || ext.tables[0].keys_n == 0 { return nil }
	t := ext.tables[0]
	kslice := ext.keys[t.keys_lo:][:t.keys_n]
	out := make([]string, len(kslice), allocator)
	for kt, i in kslice {
		out[i] = decode_token_text_tmp(cx.doc, kt, allocator).text
	}
	return out
}

@(private = "file")
compose_tabular_root :: proc(cx: ^Tabular_Cx, root_h: Handle) -> Error {
	rn, ok := get_node(cx.ov, root_h)
	if !ok || !rn.has_edits { return nil }
	hdr_keys := tabular_header_keys(cx, cx.allocator)

	Row_Item :: struct {
		node:    tape.Node_Index,
		lo, hi:  u64,
		deleted: bool,
	}
	rows := make([dynamic]Row_Item, 0, 16, cx.allocator)
	d := rn.delta
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, tape.ROOT, cx.allocator)
	if cerr != nil { return cerr }
	defer tape.destroy_children(&c)
	if p == .Found {
		for idx := u32(0); ; idx += 1 {
			_, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
			if np != .Found { break }
			rlo, rhi, rok := node_byte_span(cx.doc, vn)
			if !rok { return refuse(.Bad_Handle, "cannot locate row span", vn) }
			is_del, _ := base_delta_status(d, "", idx, false)
			append(&rows, Row_Item{vn, rlo, rhi, is_del})
		}
	}

	if len(rn.facts) > 0 { emit_tabular_facts(cx, tape.ROOT, rn, 0) or_return }

	for row in rows {
		if row.deleted { continue }
		rh, rown, ed := find_edited_child(cx.ov, row.node)
		if !ed { continue }
		if len(rown.facts) > 0 { emit_tabular_facts(cx, row.node, rown, row.lo) or_return }
		if rown.state == .Replaced {
			buf := make([dynamic]u8, 0, 64, cx.allocator)
			spell_tabular_row(cx, rh, hdr_keys, &buf) or_return
			row_end := row.hi
			if row_end > row.lo && cx.src[row_end - 1] == '\n' {
				row_end -= 1
				if row_end > row.lo && cx.src[row_end - 1] == '\r' { row_end -= 1 }
			}
			push_splice(cx.splices, row.lo, row_end, buf[:], row.node, subtree_only = true) or_return
			continue
		}
		if rown.delta != nil && len(hdr_keys) > 0 {
			for ins in rown.delta.inserted_members {
				if !slice.contains(hdr_keys, ins.key) {
					return refuse(.Bad_Name, "inserted column key not present in DSV header", row.node, row.lo)
				}
			}
		}
		rc, rp, rcerr := tape.children(tape.Reader{doc = cx.doc}, row.node, cx.allocator)
		if rcerr != nil { return rcerr }
		if rp == .Found {
			for {
				_, cell_node, np := tape.next_child(tape.Reader{doc = cx.doc}, &rc)
				if np != .Found { break }
				if ch, cn, ced := find_edited_child(cx.ov, cell_node); ced && cn.state == .Replaced {
					emit_cell_replace(cx, cell_node, ch, cn) or_return
				}
			}
		}
		tape.destroy_children(&rc)
	}

	if d == nil { return nil }

	if len(d.order) > 0 {
		deleted_flags := make_deleted_flags(rows[:], cx.allocator) or_return
		defer delete(deleted_flags, cx.allocator)
		validate_order(d.order, deleted_flags, len(d.inserted_elems), cx.allocator) or_return
		if len(rows) > 0 {
			moves := make([dynamic]Move, 0, len(d.order) * 2, cx.allocator)
			for raw in d.order {
				k := int(raw)
				if k < len(rows) {
					r := rows[k]
					append(&moves, Move{lo = r.lo, hi = r.hi})
					if r.hi > r.lo && cx.src[r.hi - 1] != '\n' {
						push_move_str(&moves, cx.eol, cx.allocator) or_return
					}
				} else {
					ins := d.inserted_elems[k - len(rows)]
					b := make([dynamic]u8, 0, 64, cx.allocator)
					if err := spell_tabular_row(cx, ins.value, hdr_keys, &b); err != nil {
						delete(b)
						return err
					}
					append(&b, cx.eol)
					append(&moves, Move{text = b[:], written = true})
				}
			}
			push_splice(cx.splices, rows[0].lo, rows[len(rows) - 1].hi, base_node = tape.ROOT, full_rewalk = true, moves = moves[:]) or_return
			return nil
		}
	}

	for r in rows {
		if r.deleted {
			push_splice(cx.splices, r.lo, r.hi, base_node = tape.ROOT, full_rewalk = true) or_return
		}
	}

	eof_buf: [dynamic]u8
	for ins in d.inserted_elems {
		if ins.at >= 0 && ins.at < len(rows) {
			pos := rows[ins.at].lo
			b := make([dynamic]u8, 0, 64, cx.allocator)
			spell_tabular_row(cx, ins.value, hdr_keys, &b) or_return
			append(&b, cx.eol)
			push_splice(cx.splices, pos, pos, b[:], tape.ROOT, full_rewalk = true) or_return
		} else {
			if eof_buf.allocator.procedure == nil {
				eof_buf = make([dynamic]u8, 0, 64, cx.allocator)
				if len(cx.src) > 0 && cx.src[len(cx.src) - 1] != '\n' { append(&eof_buf, cx.eol) }
			}
			spell_tabular_row(cx, ins.value, hdr_keys, &eof_buf) or_return
			append(&eof_buf, cx.eol)
		}
	}
	if len(eof_buf) > 0 {
		pos := u64(len(cx.src))
		push_splice(cx.splices, pos, pos, eof_buf[:], tape.ROOT, full_rewalk = true) or_return
	}
	return nil
}

@(private = "file")
emit_tabular_facts :: proc(cx: ^Tabular_Cx, node: tape.Node_Index, n: ^Edit_Node, row_lo: u64) -> Error {
	for f in n.facts {
		#partial switch f.kind {
		case .Comment, .Comment_Foot:
			if cx.comment == 0 {
				if !f.deleted { cx.dropped += {f.kind} }
				continue
			}
			existing := collect_base_facts(cx.doc, node, f.kind, cx.allocator)
			defer delete(existing)
			if f.deleted || len(f.values) == 0 {
				for bf in existing {
					push_splice(cx.splices, line_start(cx.src, bf.lo), next_line(cx.src, bf.lo + u64(bf.n)), base_node = node, full_rewalk = true) or_return
				}
				continue
			}
			buf := make([dynamic]u8, 0, 64, cx.allocator)
			if len(existing) == 0 && f.kind == .Comment_Foot && len(cx.src) > 0 && cx.src[len(cx.src) - 1] != '\n' {
				append(&buf, cx.eol)
			}
			for line in f.values {
				append(&buf, cx.comment)
				if f.padded && len(line) > 0 { append(&buf, ' ') }
				append(&buf, line)
				append(&buf, cx.eol)
			}
			lo, hi := (row_lo if f.kind == .Comment else u64(len(cx.src))), (row_lo if f.kind == .Comment else u64(len(cx.src)))
			if len(existing) > 0 {
				last := existing[len(existing) - 1]
				lo, hi = line_start(cx.src, existing[0].lo), next_line(cx.src, last.lo + u64(last.n))
			}
			push_splice(cx.splices, lo, hi, buf[:], node, full_rewalk = true) or_return
		case:
			if !f.deleted { cx.dropped += {f.kind} }
		}
	}
	return nil
}

@(private = "file")
append_tabular_cell :: proc(cx: ^Tabular_Cx, h: Handle, base_node: tape.Node_Index, out: ^[dynamic]u8) -> Error {
	if h != NO_HANDLE {
		return cx.spec.spell_cell(cx.spec.data, cx.ov, h, out)
	}
	if clo, chi, ok := node_byte_span(cx.doc, base_node); ok {
		append(out, ..cx.src[clo:chi])
	}
	return nil
}

@(private = "file")
spell_tabular_row :: proc(cx: ^Tabular_Cx, row_h: Handle, hdr_keys: []string, out: ^[dynamic]u8) -> Error {
	rk := node_kind(cx.ov, row_h)
	if rk == .Array {
		eff := effective_elements(cx.ov, row_h, cx.allocator) or_return
		defer delete(eff, cx.allocator)
		for e, i in eff {
			if i > 0 { append(out, cx.delim) }
			append_tabular_cell(cx, e.handle, e.base, out) or_return
		}
		return nil
	}
	if rk != .Object {
		return refuse(.Unspellable_Value, "table row must be an object or array")
	}
	members, owned := effective_members(cx.ov, row_h, cx.allocator) or_return
	defer destroy_effective_members(members, owned, cx.allocator)
	if len(hdr_keys) > 0 {
		for m in members {
			if !slice.contains(hdr_keys, m.key) {
				return refuse(.Bad_Name, "object row contains column key absent from DSV header")
			}
		}
		for k, i in hdr_keys {
			if i > 0 { append(out, cx.delim) }
			if ch, cb, found := lookup_member(cx.ov, row_h, k); found {
				append_tabular_cell(cx, ch, cb, out) or_return
			}
		}
		return nil
	}
	for m, i in members {
		if i > 0 { append(out, cx.delim) }
		append_tabular_cell(cx, m.handle, m.base_val, out) or_return
	}
	return nil
}
