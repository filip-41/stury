package edit

import "base:runtime"
import "core:container/handle_map"
import "core:slice"
import "stury:lib/core/tape"

// Tabular-family composer (DSV: CSV, TSV, Plain).
//
// Preserves untargeted rows, cells, delimiters, CRLF/LF line endings, and cell quoting verbatim.
// Handles cell edits, row inserts (including multiple EOF inserts without double blank lines),
// row deletes, row reorders, comment lines (replacing existing comments cleanly), and `no_header` tables.

Tabular_Spec :: struct {
	target:     ^tape.Format,
	delimiter:  u8,
	comment:    u8,
	no_header:  bool,
	// Spells one scalar cell `h` into `out` via `dsv.write` / `lib/ops/write`.
	spell_cell: proc(data: rawptr, ov: ^Overlay, h: Handle, out: ^[dynamic]u8) -> Error,
	// Validates final delimited text.
	validate:   proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	data:       rawptr,
}

commit_tabular :: proc(
	ov: ^Overlay,
	spec: ^Tabular_Spec,
	opts := Options{},
	allocator := context.allocator,
) -> (
	res: Commit_Result,
	err: Error,
) {
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
	delim = spec.delimiter
	comment = spec.comment
	no_header = spec.no_header
	if doc.ext != nil {
		if ext, ok := doc.ext.format.(tape.Tabular_Ext); ok {
			if delim == 0 {
				delim = ext.options.delimiter
			}
			if comment == 0 {
				comment = ext.options.comment
			}
			no_header = ext.options.no_header
		}
	}
	if delim == 0 {
		delim = ','
	}
	return delim, comment, no_header
}

@(private = "file")
tabular_fast_emit :: proc(
	user: rawptr,
	ov: ^Overlay,
	doc: ^tape.Document,
	splices: ^[dynamic]Splice,
	scratch: runtime.Allocator,
) -> (ok: bool, err: Error) {
	cx := (^Tabular_Cx)(user)
	cx.allocator = scratch
	cx.splices = splices
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in dynamic_iter_next(&it) {
		if n.state == .Replaced && n.has_edits && n.base != tape.NO_NODE && doc.nodes[n.base].role == .Value {
			clo, chi, clok := node_byte_span(doc, n.base)
			if !clok {
				return false, refuse(.Bad_Handle, "cannot locate cell span", n.base)
			}
			text: []u8
			if n.val.kind == .Raw {
				text = transmute([]u8)n.val.text
			} else {
				buf := make([dynamic]u8, 0, 32, scratch)
				cx.spec.spell_cell(cx.spec.data, ov, n.handle, &buf) or_return
				text = buf[:]
			}
			append(cx.splices, Splice {
				lo           = clo,
				hi           = chi,
				text         = text,
				seq          = len(cx.splices),
				base_node    = n.base,
				subtree_only = true,
			}) or_return
		}
	}
	return true, nil
}

@(private = "file")
tabular_struct_emit :: proc(
	user: rawptr,
	ov: ^Overlay,
	doc: ^tape.Document,
	eol: string,
	splices: ^[dynamic]Splice,
	dropped: ^tape.Facts,
	scratch: runtime.Allocator,
) -> Error {
	_ = doc
	cx := (^Tabular_Cx)(user)
	cx.allocator = scratch
	cx.splices = splices
	cx.eol = eol
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
Tabular_Cx :: struct {
	ov:        ^Overlay,
	doc:       ^tape.Document,
	src:       []u8,
	spec:      ^Tabular_Spec,
	opts:      Options,
	delim:     u8,
	comment:   u8,
	no_header: bool,
	eol:       string,
	splices:   ^[dynamic]Splice,
	dropped:   tape.Facts,
	allocator: runtime.Allocator,
}

@(private = "file")
tabular_header_keys :: proc(cx: ^Tabular_Cx, allocator: runtime.Allocator) -> (keys: []string, owned: []string) {
	if cx.no_header || cx.doc.ext == nil {
		return nil, nil
	}
	ext, ok := cx.doc.ext.format.(tape.Tabular_Ext)
	if !ok || len(ext.tables) == 0 {
		return nil, nil
	}
	t := ext.tables[0]
	if t.keys_n == 0 {
		return nil, nil
	}
	kslice := ext.keys[t.keys_lo:][:t.keys_n]
	out := make([]string, len(kslice), allocator)
	dec := make([dynamic]string, 0, 4, allocator)
	for kt, i in kslice {
		room := tape.text_room(cx.doc, kt)
		if room == 0 {
			out[i] = string(tape.span_bytes(cx.doc, kt.lo, kt.n))
		} else {
			buf := make([]u8, room, allocator)
			if s, dok := tape.node_text(cx.doc, kt, buf); dok {
				out[i] = s
				if raw_data(s) == raw_data(buf) {
					append(&dec, string(buf))
				} else {
					delete(buf, allocator)
				}
			} else {
				delete(buf, allocator)
			}
		}
	}
	return out, dec[:]
}

@(private = "file")
compose_tabular_root :: proc(cx: ^Tabular_Cx, root_h: Handle) -> Error {
	rn, ok := get_node(cx.ov, root_h)
	if !ok || !rn.has_edits {
		return nil
	}
	hdr_keys, _ := tabular_header_keys(cx, cx.allocator)

	Row_Item :: struct {
		node:    tape.Node_Index,
		lo, hi:  u64,
		deleted: bool,
	}
	rows := make([dynamic]Row_Item, 0, 16, cx.allocator)
	d := rn.delta
	c, p, cerr := tape.children(tape.Reader{doc = cx.doc}, tape.ROOT, cx.allocator)
	if cerr != nil {
		return cerr
	}
	defer tape.destroy_children(&c)
	if p == .Found {
		idx := u32(0)
		for {
			_, vn, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
			if np != .Found {
				break
			}
			rlo, rhi, rok := node_byte_span(cx.doc, vn)
			if !rok {
				return refuse(.Bad_Handle, "cannot locate row span", vn)
			}
			is_del := false
			if d != nil {
				for di in d.deleted_indices {
					if di == idx {
						is_del = true
						break
					}
				}
			}
			append(&rows, Row_Item{node = vn, lo = rlo, hi = rhi, deleted = is_del})
			idx += 1
		}
	}

	if len(rn.facts) > 0 {
		emit_tabular_facts(cx, tape.ROOT, rn, 0) or_return
	}

	for row in rows {
		if row.deleted {
			continue
		}
		rh, has := cx.ov.by_base[row.node]
		if !has {
			continue
		}
		rown, rok := get_node(cx.ov, rh)
		if !rok || !rown.has_edits {
			continue
		}
		if len(rown.facts) > 0 {
			emit_tabular_facts(cx, row.node, rown, row.lo) or_return
		}
		if rown.state == .Replaced {
			buf := make([dynamic]u8, 0, 64, cx.allocator)
			spell_tabular_row(cx, rh, hdr_keys, &buf) or_return
			row_end := row.hi
			if row_end > row.lo && cx.src[row_end - 1] == '\n' {
				row_end -= 1
				if row_end > row.lo && cx.src[row_end - 1] == '\r' {
					row_end -= 1
				}
			}
			append(cx.splices, Splice{lo = row.lo, hi = row_end, text = buf[:], seq = len(cx.splices), base_node = row.node, subtree_only = true})
			continue
		}
		// Refuse unknown newly added column keys inside a base object row unless header matches!
		if rown.delta != nil && len(rown.delta.inserted_members) > 0 && len(hdr_keys) > 0 {
			for ins in rown.delta.inserted_members {
				if !slice.contains(hdr_keys, ins.key) {
					return refuse(.Bad_Name, "inserted column key not present in DSV header", row.node, row.lo)
				}
			}
		}
		rc, rp, rcerr := tape.children(tape.Reader{doc = cx.doc}, row.node, cx.allocator)
		if rcerr != nil {
			return rcerr
		}
		if rp == .Found {
			for {
				_, cell_node, np := tape.next_child(tape.Reader{doc = cx.doc}, &rc)
				if np != .Found {
					break
				}
				ch, chas := cx.ov.by_base[cell_node]
				if !chas {
					continue
				}
				cn, cok := get_node(cx.ov, ch)
				if !cok || !cn.has_edits {
					continue
				}
				if cn.state == .Replaced {
					clo, chi, clok := node_byte_span(cx.doc, cell_node)
					if !clok {
						return refuse(.Bad_Handle, "cannot locate cell span", cell_node)
					}
					buf := make([dynamic]u8, 0, 32, cx.allocator)
					cx.spec.spell_cell(cx.spec.data, cx.ov, ch, &buf) or_return
					append(cx.splices, Splice{lo = clo, hi = chi, text = buf[:], seq = len(cx.splices), base_node = cell_node, subtree_only = true})
				}
			}
		}
		tape.destroy_children(&rc)
	}

	if d == nil {
		return nil
	}

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
						append(&moves, Move{text = slice.clone(transmute([]u8)cx.eol, cx.allocator), written = true})
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
			append(cx.splices, Splice{lo = rows[0].lo, hi = rows[len(rows) - 1].hi, moves = moves[:], seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true})
			return nil
		}
	}

	for r in rows {
		if r.deleted {
			append(cx.splices, Splice{lo = r.lo, hi = r.hi, seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true})
		}
	}

	// Group EOF insertions into ONE splice so multiple EOF inserts never emit a double blank line!
	eof_buf: [dynamic]u8
	eof_started := false
	for ins in d.inserted_elems {
		if ins.at >= 0 && ins.at < len(rows) {
			pos := rows[ins.at].lo
			b := make([dynamic]u8, 0, 64, cx.allocator)
			spell_tabular_row(cx, ins.value, hdr_keys, &b) or_return
			append(&b, cx.eol)
			append(cx.splices, Splice{lo = pos, hi = pos, text = b[:], seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true})
		} else {
			if !eof_started {
				eof_buf = make([dynamic]u8, 0, 64, cx.allocator)
				eof_started = true
				if len(cx.src) > 0 && cx.src[len(cx.src) - 1] != '\n' {
					append(&eof_buf, cx.eol)
				}
			}
			spell_tabular_row(cx, ins.value, hdr_keys, &eof_buf) or_return
			append(&eof_buf, cx.eol)
		}
	}
	if eof_started {
		pos := u64(len(cx.src))
		append(cx.splices, Splice{lo = pos, hi = pos, text = eof_buf[:], seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true})
	}
	return nil
}

// Replaces existing comment lines in place (instead of duplicating them) or inserts new comment lines.
@(private = "file")
emit_tabular_facts :: proc(cx: ^Tabular_Cx, node: tape.Node_Index, n: ^Edit_Node, row_lo: u64) -> Error {
	for f in n.facts {
		#partial switch f.kind {
		case .Comment, .Comment_Foot:
			if cx.comment == 0 {
				if !f.deleted {
					cx.dropped += {f.kind}
				}
				continue
			}
			existing := collect_base_facts(cx.doc, node, f.kind, cx.allocator)
			defer delete(existing)
			if f.deleted || len(f.values) == 0 {
				for bf in existing {
					append(cx.splices, Splice{lo = line_start(cx.src, bf.lo), hi = next_line(cx.src, bf.lo + u64(bf.n)), seq = len(cx.splices), base_node = node, full_rewalk = true})
				}
				continue
			}
			buf := make([dynamic]u8, 0, 64, cx.allocator)
			if len(existing) == 0 && f.kind == .Comment_Foot && len(cx.src) > 0 && cx.src[len(cx.src) - 1] != '\n' {
				append(&buf, cx.eol)
			}
			for line in f.values {
				append(&buf, cx.comment)
				if f.padded && len(line) > 0 {
					append(&buf, ' ')
				}
				append(&buf, line)
				append(&buf, cx.eol)
			}
			if len(existing) > 0 {
				lo := line_start(cx.src, existing[0].lo)
				hi := next_line(cx.src, existing[len(existing) - 1].lo + u64(existing[len(existing) - 1].n))
				append(cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true})
			} else {
				pos := row_lo if f.kind == .Comment else u64(len(cx.src))
				append(cx.splices, Splice{lo = pos, hi = pos, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true})
			}
		case:
			if !f.deleted {
				cx.dropped += {f.kind}
			}
		}
	}
	return nil
}

@(private = "file")
append_tabular_cell :: proc(cx: ^Tabular_Cx, h: Handle, base_node: tape.Node_Index, out: ^[dynamic]u8) -> Error {
	if h != NO_HANDLE {
		return cx.spec.spell_cell(cx.spec.data, cx.ov, h, out)
	}
	if base_node != tape.NO_NODE {
		if clo, chi, ok := node_byte_span(cx.doc, base_node); ok {
			append(out, ..cx.src[clo:chi])
		}
	}
	return nil
}

@(private = "file")
spell_tabular_row :: proc(cx: ^Tabular_Cx, row_h: Handle, hdr_keys: []string, out: ^[dynamic]u8) -> Error {
	rk := node_kind(cx.ov, row_h)
	if rk == .Array {
		eff, err := effective_elements(cx.ov, row_h, cx.allocator)
		if err != nil {
			return err
		}
		defer delete(eff, cx.allocator)
		for e, i in eff {
			if i > 0 {
				append(out, cx.delim)
			}
			append_tabular_cell(cx, e.handle, e.base, out) or_return
		}
		return nil
	}
	if rk != .Object {
		return refuse(.Unspellable_Value, "table row must be an object or array")
	}
	members, owned, merr := effective_members(cx.ov, row_h, cx.allocator)
	if merr != nil {
		return merr
	}
	defer destroy_effective_members(members, owned, cx.allocator)
	if len(hdr_keys) > 0 {
		for m in members {
			if !slice.contains(hdr_keys, m.key) {
				return refuse(.Bad_Name, "object row contains column key absent from DSV header")
			}
		}
		for k, i in hdr_keys {
			if i > 0 {
				append(out, cx.delim)
			}
			ch, cb, found := lookup_member(cx.ov, row_h, k)
			if found {
				append_tabular_cell(cx, ch, cb, out) or_return
			}
		}
		return nil
	}
	for m, i in members {
		if i > 0 {
			append(out, cx.delim)
		}
		append_tabular_cell(cx, m.handle, m.base_val, out) or_return
	}
	return nil
}
