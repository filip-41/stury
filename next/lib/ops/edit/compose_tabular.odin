package edit

import "base:runtime"
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
	fast, _, fast_res, gerr := commit_guard(ov, spec.target, opts, true, spec.validate, spec.data, allocator)
	if gerr != nil {
		return {}, gerr
	}
	if fast {
		return fast_res, nil
	}
	doc := ov.base
	if ov.root != NO_HANDLE && node_kind(ov, ov.root) != .Array {
		return {}, refuse(.Root_Shape, "delimited document root must be an array of rows", tape.ROOT)
	}

	delim := spec.delimiter
	comment_byte := spec.comment
	no_header := spec.no_header
	if doc.ext != nil {
		if ext, ok := doc.ext.format.(tape.Tabular_Ext); ok {
			if delim == 0 {
				delim = ext.options.delimiter
			}
			if comment_byte == 0 {
				comment_byte = ext.options.comment
			}
			no_header = ext.options.no_header
		}
	}
	if delim == 0 {
		delim = ','
	}

	cx := Tabular_Cx {
		ov        = ov,
		doc       = doc,
		src       = doc.src,
		spec      = spec,
		opts      = opts,
		delim     = delim,
		comment   = comment_byte,
		no_header = no_header,
		eol       = detect_eol(doc.src),
		allocator = allocator,
	}
	cx.splices = make([dynamic]Splice, 0, 16, allocator)
	defer {
		for s in cx.splices {
			if s.text != nil {
				delete(s.text, allocator)
			}
			for m in s.moves {
				if m.written && m.text != nil {
					delete(m.text, allocator)
				}
			}
			if s.moves != nil {
				delete(s.moves, allocator)
			}
		}
		delete(cx.splices)
	}

	if ov.root != NO_HANDLE {
		if err = compose_tabular_root(&cx, ov.root); err != nil {
			return {}, err
		}
	}

	out, recs, rew, serr := apply_splices(doc.src, cx.splices[:], allocator)
	if serr != nil {
		return {}, serr
	}
	if spec.validate != nil {
		if verr := spec.validate(spec.data, out, allocator); verr != nil {
			delete(out, allocator)
			delete(recs, allocator)
			delete(rew, allocator)
			return {}, convert_tape_error(verr)
		}
	}
	return Commit_Result {
		bytes     = out,
		dropped   = cx.dropped,
		rewritten = rew,
		splices   = recs,
		allocator = allocator,
	}, nil
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
	splices:   [dynamic]Splice,
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
	hdr_keys, owned_hdr := tabular_header_keys(cx, cx.allocator)
	defer {
		if hdr_keys != nil {
			delete(hdr_keys, cx.allocator)
		}
		for s in owned_hdr {
			delete(s, cx.allocator)
		}
		if owned_hdr != nil {
			delete(owned_hdr, cx.allocator)
		}
	}

	Row_Item :: struct {
		node:    tape.Node_Index,
		lo, hi:  u64,
		deleted: bool,
	}
	rows := make([dynamic]Row_Item, 0, 16, cx.allocator)
	defer delete(rows)
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
			if err := spell_tabular_row(cx, rh, hdr_keys, &buf); err != nil {
				delete(buf)
				return err
			}
			row_end := row.hi
			if row_end > row.lo && cx.src[row_end - 1] == '\n' {
				row_end -= 1
				if row_end > row.lo && cx.src[row_end - 1] == '\r' {
					row_end -= 1
				}
			}
			append(&cx.splices, Splice{lo = row.lo, hi = row_end, text = buf[:], seq = len(cx.splices), base_node = row.node, subtree_only = true})
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
						tape.destroy_children(&rc)
						return refuse(.Bad_Handle, "cannot locate cell span", cell_node)
					}
					buf := make([dynamic]u8, 0, 32, cx.allocator)
					if err := cx.spec.spell_cell(cx.spec.data, cx.ov, ch, &buf); err != nil {
						delete(buf)
						tape.destroy_children(&rc)
						return err
					}
					append(&cx.splices, Splice{lo = clo, hi = chi, text = buf[:], seq = len(cx.splices), base_node = cell_node, subtree_only = true})
				}
			}
		}
		tape.destroy_children(&rc)
	}

	if d == nil {
		return nil
	}

	if len(d.order) > 0 {
		deleted_flags := make([]bool, len(rows), cx.allocator)
		defer delete(deleted_flags, cx.allocator)
		for r, i in rows {
			deleted_flags[i] = r.deleted
		}
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
			append(&cx.splices, Splice{lo = rows[0].lo, hi = rows[len(rows) - 1].hi, moves = moves[:], seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true})
			return nil
		}
	}

	for r in rows {
		if r.deleted {
			append(&cx.splices, Splice{lo = r.lo, hi = r.hi, seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true})
		}
	}

	// Group EOF insertions into ONE splice so multiple EOF inserts never emit a double blank line!
	eof_buf: [dynamic]u8
	eof_started := false
	defer if eof_buf.allocator.procedure != nil {
		delete(eof_buf)
	}
	for ins in d.inserted_elems {
		if ins.at >= 0 && ins.at < len(rows) {
			pos := rows[ins.at].lo
			b := make([dynamic]u8, 0, 64, cx.allocator)
			if err := spell_tabular_row(cx, ins.value, hdr_keys, &b); err != nil {
				delete(b)
				return err
			}
			append(&b, cx.eol)
			append(&cx.splices, Splice{lo = pos, hi = pos, text = b[:], seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true})
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
		append(&cx.splices, Splice{lo = pos, hi = pos, text = eof_buf[:], seq = len(cx.splices), base_node = tape.ROOT, full_rewalk = true})
		eof_buf = {} // transferred ownership to `cx.splices`
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
			existing := make([dynamic]tape.Fact, 0, 4, cx.allocator)
			defer delete(existing)
			for bf in tape.facts_of(cx.doc, node) {
				if bf.kind == f.kind {
					append(&existing, bf)
				}
			}
			if f.deleted || len(f.values) == 0 {
				for bf in existing {
					append(&cx.splices, Splice{lo = line_start(cx.src, bf.lo), hi = next_line(cx.src, bf.lo + u64(bf.n)), seq = len(cx.splices), base_node = node, full_rewalk = true})
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
				append(&cx.splices, Splice{lo = lo, hi = hi, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true})
			} else {
				pos := row_lo if f.kind == .Comment else u64(len(cx.src))
				append(&cx.splices, Splice{lo = pos, hi = pos, text = buf[:], seq = len(cx.splices), base_node = node, full_rewalk = true})
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
			if e.handle != NO_HANDLE {
				cx.spec.spell_cell(cx.spec.data, cx.ov, e.handle, out) or_return
			} else if e.base != tape.NO_NODE {
				clo, chi, ok := node_byte_span(cx.doc, e.base)
				if ok {
					append(out, ..cx.src[clo:chi])
				}
			}
		}
		return nil
	}
	if rk != .Object {
		return refuse(.Unspellable_Value, "table row must be an object or array")
	}
	if len(hdr_keys) > 0 {
		// Verify no unknown keys in inserted/replaced object row are silently dropped!
		members, owned, merr := effective_members(cx.ov, row_h, cx.allocator)
		if merr != nil {
			return merr
		}
		defer destroy_effective_members(members, owned, cx.allocator)
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
			if !found {
				continue
			}
			if ch != NO_HANDLE {
				cx.spec.spell_cell(cx.spec.data, cx.ov, ch, out) or_return
			} else if cb != tape.NO_NODE {
				clo, chi, ok := node_byte_span(cx.doc, cb)
				if ok {
					append(out, ..cx.src[clo:chi])
				}
			}
		}
		return nil
	}
	members, owned, merr := effective_members(cx.ov, row_h, cx.allocator)
	if merr != nil {
		return merr
	}
	defer destroy_effective_members(members, owned, cx.allocator)
	for m, i in members {
		if i > 0 {
			append(out, cx.delim)
		}
		if m.handle != NO_HANDLE {
			cx.spec.spell_cell(cx.spec.data, cx.ov, m.handle, out) or_return
		} else if m.base_val != tape.NO_NODE {
			clo, chi, ok := node_byte_span(cx.doc, m.base_val)
			if ok {
				append(out, ..cx.src[clo:chi])
			}
		}
	}
	return nil
}
