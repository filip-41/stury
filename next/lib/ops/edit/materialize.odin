package edit

import "base:runtime"
import "core:encoding/endian"
import "core:math"
import "core:strconv"
import "stury:lib/base/spell"
import "stury:lib/core/markup"
import "stury:lib/core/tape"

// Generic rodata `tape.Format` attached to materialized documents when no format-specific `target_format` is passed.
// Every format writer accepts it as a decoded foreign document, never taking raw-source shortcuts, while still reading
// decimal numbers (including NaN/Inf) and `.Style` / `.Tag` fact names cleanly.
@(private = "file", rodata)
MATERIALIZED_FORMAT := tape.Format {
	name      = "materialized",
	id        = 0,
	facts     = tape.COMMENTS + {.Tag, .Style, .Attribute},
	dups      = .All,
	bounds    = mat_bounds,
	room      = mat_room,
	number    = mat_number,
	same_text = mat_same_text,
	key_hash  = mat_key_hash,
	fact_name = mat_fact_name,
}

@(private = "file")
mat_bounds :: proc "contextless" (src: []u8, t: tape.Token) -> (head, tail: u8) {
	_ = src
	_ = t
	return 0, 0
}

@(private = "file")
mat_room :: proc "contextless" (src: []u8, t: tape.Node, ext: ^tape.Format_Ext) -> int {
	_ = src
	_ = ext
	return int(t.n)
}

@(private = "file")
mat_number :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
	hi := t.lo + u64(t.n)
	if n, ok := spell.number_strict(src, t.lo, hi); ok {
		return n
	}
	s := string(src[t.lo:hi])
	if s == "NaN" {
		return {bits = transmute(u64)math.nan_f64(), kind = .Float}
	}
	if s == "Infinity" || s == "+Infinity" {
		return {bits = transmute(u64)math.inf_f64(1), kind = .Float}
	}
	if s == "-Infinity" {
		return {bits = transmute(u64)math.inf_f64(-1), kind = .Float}
	}
	return {kind = .Wide}
}

@(private = "file")
mat_same_text :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
	if t.n != o.n {
		return false
	}
	a := src[t.lo : t.lo + u64(t.n)]
	b := other[o.lo : o.lo + u64(o.n)]
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

@(private = "file")
mat_key_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {
	return tape.text_hash(src[t.lo : t.lo + u64(t.n)])
}

@(private = "file")
mat_fact_name :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index, kind: tape.Fact_Kind) -> (name: string, ok: bool) {
	for f in tape.facts_of(doc, at) {
		if f.kind == kind && f.n > 0 {
			return string(tape.span_bytes(doc, f.lo, f.n)), true
		}
	}
	return "", false
}

// Iterative zero-recursion `materialize_subtree`: builds a self-contained `tape.Document` from an `Overlay`
// subtree `root_h` so ALL 5 format writers (`json.write`, `toml.write`, `xml.write`, `cbor.write`, `dsv.write`)
// can serialize edited/reflowed subtrees using their real, battle-tested writers with zero duplicate encoders!

Materialize_Options :: struct {
	// Optional synthetic wrapper key (e.g. for XML `<tag>...</tag>` or TOML `k = ...`).
	wrap_key:         string,
	// When true, deduplicates object keys keeping the last (winning) occurrence (for JSON reflow).
	dedup_keys:       bool,
	// When true, encodes numeric `.Tag` facts as CBOR major-6 heads and sets `doc.format = target_format`.
	cbor_tags:        bool,
	// When true, formats XML `.Attribute` facts as `name="val"` spans and sets `doc.format = target_format`.
	xml_attrs:        bool,
	// When true, skips `.Attribute` facts on the root materialized node (e.g. XML element content-only replacement).
	skip_root_attrs:       bool,
	// When true, skips `.Tag` facts on the root materialized node (e.g. when composer already emitted outer CBOR tags).
	skip_root_tags:        bool,
	// When true, emits `.Comment`/`.Comment_Inline`/`.Comment_Foot` on the root node too (e.g. full-doc reflow).
	include_root_comments: bool,
	// Optional `doc.format` to attach (nil uses generic `MATERIALIZED_FORMAT`, which every writer accepts!).
	target_format:         ^tape.Format,
	// Optional style override applied to the root node (e.g., `"single"` for JSON5 or `"literal"` for TOML).
	root_style:       string,
}

// Materializes `root_h` (or `base_node` if `root_h == NO_HANDLE`) in `ov` into a self-contained `tape.Document`
// owned by the caller (destroy with `tape.destroy_document`). Zero native recursion!
materialize_subtree :: proc(
	ov: ^Overlay,
	root_h: Handle,
	base_node := tape.NO_NODE,
	opts := Materialize_Options{},
	allocator := context.allocator,
) -> (
	doc: tape.Document,
	err: Error,
) {
	if ov == nil || ov.base == nil {
		return {}, refuse(.No_Document, "materialize_subtree requires an overlay")
	}

	Mat_Frame :: struct {
		node_idx:   int,
		is_obj:     bool,
		elems:      []Effective_Element,
		members:    []Effective_Member,
		owned_keys: []string,
		idx:        int,
		base_c:     tape.Node_Index, // non-NO_NODE when walking an untouched base container
		base_end:   tape.Node_Index,
		base_cur:   tape.Node_Index,
		child_n:    int,
	}

	src := make([dynamic]u8, 0, 256, allocator)
	defer if err != nil {
		delete(src)
	}
	nodes := make([dynamic]tape.Node, 0, 32, allocator)
	defer if err != nil {
		delete(nodes)
	}
	facts := make([dynamic]tape.Fact, 0, 8, allocator)
	defer if err != nil {
		delete(facts)
	}
	counts := make([dynamic]tape.Child_Count, 0, 4, allocator)
	defer if err != nil {
		delete(counts)
	}
	present: tape.Facts

	stack := make([dynamic]Mat_Frame, 0, 16, allocator)
	defer {
		for &fr in stack {
			delete(fr.elems, allocator)
			destroy_effective_members(fr.members, fr.owned_keys, allocator)
		}
		delete(stack)
	}

	append_str :: proc(buf: ^[dynamic]u8, s: string) -> (lo: u64, n: u32, aerr: runtime.Allocator_Error) {
		lo = u64(len(buf))
		append(buf, s) or_return
		return lo, u32(len(s)), nil
	}

	append_bytes :: proc(buf: ^[dynamic]u8, b: []u8) -> (lo: u64, n: u32, aerr: runtime.Allocator_Error) {
		lo = u64(len(buf))
		append(buf, ..b) or_return
		return lo, u32(len(b)), nil
	}

	emit_cbor_tag_head :: proc(buf: ^[dynamic]u8, arg: u64) -> (lo: u64, n: u32, aerr: runtime.Allocator_Error) {
		lo = u64(len(buf))
		m := u8(6 << 5)
		switch {
		case arg < 24:
			append(buf, m | u8(arg)) or_return
		case arg <= 0xFF:
			append(buf, m | 24, u8(arg)) or_return
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

	emit_facts_for :: proc(
		ov: ^Overlay,
		h: Handle,
		bn: tape.Node_Index,
		out_node: tape.Node_Index,
		src: ^[dynamic]u8,
		facts: ^[dynamic]tape.Fact,
		present: ^tape.Facts,
		opts: Materialize_Options,
		extra_style: string,
		is_root_val: bool,
		allocator: runtime.Allocator,
	) -> Error {
		n: ^Edit_Node
		has_n := false
		if h != NO_HANDLE {
			n, has_n = get_node(ov, h)
		}
		// Copy untouched base facts not overridden by `n.facts`.
		if bn != tape.NO_NODE && int(bn) < len(ov.base.nodes) {
			for bf in tape.facts_of(ov.base, bn) {
				overridden := false
				if has_n {
					for fo in n.facts {
						if fo.kind == bf.kind {
							if bf.kind != .Attribute {
								overridden = true
								break
							}
							if ov.base.format != nil && ov.base.format.attribute != nil {
								kt, _ := ov.base.format.attribute(ov.base, bf)
								if string(tape.span_bytes(ov.base, kt.lo, kt.n)) == fo.attr {
									overridden = true
									break
								}
							}
						}
					}
				}
				if overridden {
					continue
				}
				if bf.kind == .Style && len(extra_style) > 0 {
					continue
				}
				if bf.kind == .Tag && opts.cbor_tags && !(is_root_val && opts.skip_root_tags) {
					span := tape.span_bytes(ov.base, bf.lo, bf.n)
					flo, fn := append_bytes(src, span) or_return
					append(facts, tape.Fact{node = out_node, lo = flo, n = fn, kind = .Tag}) or_return
					present^ += {.Tag}
				} else if bf.kind == .Attribute && opts.xml_attrs && !(is_root_val && opts.skip_root_attrs) {
					span := tape.span_bytes(ov.base, bf.lo, bf.n)
					flo, fn := append_bytes(src, span) or_return
					append(facts, tape.Fact{node = out_node, lo = flo, n = fn, kind = .Attribute, spelling = bf.spelling}) or_return
					present^ += {.Attribute}
				} else if (bf.kind == .Comment || bf.kind == .Comment_Inline || bf.kind == .Comment_Foot) && (!is_root_val || opts.include_root_comments) {
					raw := tape.span_bytes(ov.base, bf.lo, bf.n)
					lead := min(int(tape.fact_lead(bf.spelling)), len(raw))
					tail := min(int(tape.fact_tail(bf.spelling)), len(raw) - lead)
					body := raw[lead : len(raw) - tail]
					flo, fn := append_bytes(src, body) or_return
					append(facts, tape.Fact{node = out_node, lo = flo, n = fn, kind = bf.kind}) or_return
					present^ += {bf.kind}
				} else if bf.kind == .Style {
					if sname, ok := tape.fact_name(ov.base, bn, .Style); ok {
						flo, fn := append_str(src, sname) or_return
						append(facts, tape.Fact{node = out_node, lo = flo, n = fn, kind = .Style}) or_return
						present^ += {.Style}
					}
				}
			}
		}
		if has_n {
			for fo in n.facts {
				if fo.deleted {
					continue
				}
				#partial switch fo.kind {
				case .Tag:
					if is_root_val && opts.skip_root_tags {
						continue
					}
					if opts.cbor_tags {
						tag_num, tok := cbor_parse_tag_override(fo)
						if !tok {
							return refuse(.Fact_No_Place, "CBOR tag must be an unsigned 64-bit integer", bn)
						}
						flo, fn := emit_cbor_tag_head(src, tag_num) or_return
						append(facts, tape.Fact{node = out_node, lo = flo, n = fn, kind = .Tag}) or_return
						present^ += {.Tag}
					} else if len(fo.values) > 0 {
						flo, fn := append_str(src, fo.values[0]) or_return
						append(facts, tape.Fact{node = out_node, lo = flo, n = fn, kind = .Tag}) or_return
						present^ += {.Tag}
					}
				case .Attribute:
					if opts.xml_attrs && !(is_root_val && opts.skip_root_attrs) && len(fo.values) > 0 {
						flo := u64(len(src))
						append(src, fo.attr) or_return
						append(src, `="`) or_return
						for c in transmute([]u8)fo.values[0] {
							switch c {
							case '&':
								append(src, "&amp;") or_return
							case '<':
								append(src, "&lt;") or_return
							case '>':
								append(src, "&gt;") or_return
							case '"':
								append(src, "&quot;") or_return
							case '\t':
								append(src, "&#9;") or_return
							case '\n':
								append(src, "&#10;") or_return
							case '\r':
								append(src, "&#13;") or_return
							case:
								append(src, c) or_return
							}
						}
						append(src, '"') or_return
						sp := markup.attribute_spelling(len(fo.attr) + 2, true)
						append(facts, tape.Fact{node = out_node, lo = flo, n = u32(u64(len(src)) - flo), kind = .Attribute, spelling = sp}) or_return
						present^ += {.Attribute}
					}
				case .Comment, .Comment_Inline, .Comment_Foot:
					if !is_root_val || opts.include_root_comments {
						for line in fo.values {
							flo, fn := append_str(src, line) or_return
							append(facts, tape.Fact{node = out_node, lo = flo, n = fn, kind = fo.kind}) or_return
							present^ += {fo.kind}
						}
					}
				case .Style:
					if len(fo.values) > 0 && len(extra_style) == 0 {
						flo, fn := append_str(src, fo.values[0]) or_return
						append(facts, tape.Fact{node = out_node, lo = flo, n = fn, kind = .Style}) or_return
						present^ += {.Style}
					}
				}
			}
		}
		if len(extra_style) > 0 {
			flo, fn := append_str(src, extra_style) or_return
			append(facts, tape.Fact{node = out_node, lo = flo, n = fn, kind = .Style}) or_return
			present^ += {.Style}
		}
		_ = allocator
		return nil
	}

	emit_one :: proc(
		ov: ^Overlay,
		h: Handle,
		bn: tape.Node_Index,
		role: tape.Role,
		src: ^[dynamic]u8,
		nodes: ^[dynamic]tape.Node,
		facts: ^[dynamic]tape.Fact,
		present: ^tape.Facts,
		stack: ^[dynamic]Mat_Frame,
		opts: Materialize_Options,
		extra_style: string,
		is_root_val: bool,
		allocator: runtime.Allocator,
	) -> Error {
		out_idx := tape.Node_Index(len(nodes))

		// Resolve handle vs untouched base node.
		eff_h := h
		eff_bn := bn
		if eff_h != NO_HANDLE {
			if n, ok := get_node(ov, eff_h); ok {
				if n.state == .Replaced && n.val.kind == .Base_Ref {
					eff_bn = n.val.base_ref
					eff_h = NO_HANDLE
					// Emit facts attached to the wrapper `h` on `out_idx` below as well.
				} else if n.state == .Ancestor && !n.has_edits {
					eff_bn = n.base
					eff_h = NO_HANDLE
				} else if n.base != tape.NO_NODE && eff_bn == tape.NO_NODE {
					eff_bn = n.base
				}
			}
		}

		emit_facts_for(ov, h, eff_bn, out_idx, src, facts, present, opts, extra_style, is_root_val, allocator) or_return

		if eff_h != NO_HANDLE {
			n, ok := get_node(ov, eff_h)
			if !ok {
				return refuse(.Bad_Handle, "invalid handle in materialize_subtree")
			}
			if n.state == .Replaced {
				switch n.val.kind {
				case .None, .Null:
					append(nodes, tape.Node{kind = .Null, role = role}) or_return
					return nil
				case .False:
					append(nodes, tape.Node{kind = .False, role = role}) or_return
					return nil
				case .True:
					append(nodes, tape.Node{kind = .True, role = role}) or_return
					return nil
				case .Int:
					nbuf: [32]u8
					s := strconv.write_int(nbuf[:], n.val.i, 10)
					lo, ln := append_str(src, s) or_return
					append(nodes, tape.Node{lo = lo, n = ln, kind = .Number, role = role}) or_return
					return nil
				case .Uint:
					nbuf: [32]u8
					s := strconv.write_uint(nbuf[:], n.val.u, 10)
					lo, ln := append_str(src, s) or_return
					append(nodes, tape.Node{lo = lo, n = ln, kind = .Number, role = role}) or_return
					return nil
				case .Float:
					s: string
					nbuf: [64]u8
					if math.is_nan(n.val.f) {
						s = "NaN"
					} else if math.is_inf(n.val.f) {
						s = "-Infinity" if n.val.f < 0 else "Infinity"
					} else {
						s = strconv.write_float(nbuf[:], n.val.f, 'g', -1, 64, {})
					}
					lo, ln := append_str(src, s) or_return
					append(nodes, tape.Node{lo = lo, n = ln, kind = .Number, role = role}) or_return
					return nil
				case .Number_Text:
					lo, ln := append_str(src, n.val.text) or_return
					append(nodes, tape.Node{lo = lo, n = ln, kind = .Number, role = role}) or_return
					return nil
				case .String:
					lo, ln := append_str(src, n.val.text) or_return
					append(nodes, tape.Node{lo = lo, n = ln, kind = .String, role = role}) or_return
					return nil
				case .Raw:
					lo, ln := append_str(src, n.val.text) or_return
					append(nodes, tape.Node{lo = lo, n = ln, kind = .Plain, role = role}) or_return
					return nil
				case .Bytes:
					lo, ln := append_bytes(src, n.val.raw) or_return
					append(nodes, tape.Node{lo = lo, n = ln, kind = .Bytes, role = role}) or_return
					return nil
				case .Base_Ref:
					// Handled above.
				case .Array, .Object:
					is_obj := n.val.kind == .Object
					append(nodes, tape.Node{kind = .Object if is_obj else .Array, role = role}) or_return
					if is_obj {
						ms, oks, merr := effective_members(ov, eff_h, allocator)
						if merr != nil {
							return merr
						}
						if opts.dedup_keys && len(ms) > 1 {
							ms = dedup_effective_members(ms)
						}
						append(stack, Mat_Frame{node_idx = int(out_idx), is_obj = true, members = ms, owned_keys = oks, base_c = tape.NO_NODE}) or_return
					} else {
						es, eerr := effective_elements(ov, eff_h, allocator)
						if eerr != nil {
							return eerr
						}
						append(stack, Mat_Frame{node_idx = int(out_idx), is_obj = false, elems = es, base_c = tape.NO_NODE}) or_return
					}
					return nil
				}
			}
			// `.Ancestor` (with edits) or `.Container_Delta`:
			k := node_kind(ov, eff_h)
			if k == .Object || k == .Array {
				is_obj := k == .Object
				append(nodes, tape.Node{kind = k, role = role}) or_return
				if is_obj {
					ms, oks, merr := effective_members(ov, eff_h, allocator)
					if merr != nil {
						return merr
					}
					if opts.dedup_keys && len(ms) > 1 {
						ms = dedup_effective_members(ms)
					}
					append(stack, Mat_Frame{node_idx = int(out_idx), is_obj = true, members = ms, owned_keys = oks, base_c = tape.NO_NODE}) or_return
				} else {
					es, eerr := effective_elements(ov, eff_h, allocator)
					if eerr != nil {
						return eerr
					}
					append(stack, Mat_Frame{node_idx = int(out_idx), is_obj = false, elems = es, base_c = tape.NO_NODE}) or_return
				}
				return nil
			}
			// Fact-only edit on a base scalar -> fall through to emit base scalar!
		}

		// Untouched base node `eff_bn`:
		if eff_bn == tape.NO_NODE || int(eff_bn) >= len(ov.base.nodes) {
			append(nodes, tape.Node{kind = .Null, role = role}) or_return
			return nil
		}
		bt := ov.base.nodes[eff_bn]
		#partial switch bt.kind {
		case .Null, .False, .True:
			append(nodes, tape.Node{kind = bt.kind, role = role}) or_return
		case .Number:
			if num, nok := tape.node_number(ov.base, eff_bn); nok {
				nbuf: [64]u8
				s: string
				switch num.kind {
				case .Int:
					s = strconv.write_int(nbuf[:], i64(num.bits), 10)
				case .Uint:
					s = strconv.write_uint(nbuf[:], num.bits, 10)
				case .Float:
					fv := transmute(f64)num.bits
					if math.is_nan(fv) {
						s = "NaN"
					} else if math.is_inf(fv) {
						s = "-Infinity" if fv < 0 else "Infinity"
					} else {
						s = strconv.write_float(nbuf[:], fv, 'g', -1, 64, {})
					}
				case .Wide:
					tk := decode_node_text_tmp(ov.base, eff_bn, allocator)
					defer free_tmp_text(tk, allocator)
					lo, ln := append_str(src, tk.text) or_return
					append(nodes, tape.Node{lo = lo, n = ln, kind = .Number, role = role}) or_return
					return nil
				}
				lo, ln := append_str(src, s) or_return
				append(nodes, tape.Node{lo = lo, n = ln, kind = .Number, role = role}) or_return
			} else {
				tk := decode_node_text_tmp(ov.base, eff_bn, allocator)
				defer free_tmp_text(tk, allocator)
				lo, ln := append_str(src, tk.text) or_return
				append(nodes, tape.Node{lo = lo, n = ln, kind = .Number, role = role}) or_return
			}
		case .String, .Plain:
			tk := decode_node_text_tmp(ov.base, eff_bn, allocator)
			defer free_tmp_text(tk, allocator)
			lo, ln := append_str(src, tk.text) or_return
			append(nodes, tape.Node{lo = lo, n = ln, kind = .String, role = role}) or_return
		case .Bytes:
			tk := decode_node_text_tmp(ov.base, eff_bn, allocator)
			defer free_tmp_text(tk, allocator)
			lo, ln := append_bytes(src, transmute([]u8)tk.text) or_return
			append(nodes, tape.Node{lo = lo, n = ln, kind = .Bytes, role = role}) or_return
		case .Array, .Object:
			append(nodes, tape.Node{kind = bt.kind, role = role}) or_return
			append(stack, Mat_Frame {
				node_idx = int(out_idx),
				is_obj   = bt.kind == .Object,
				base_c   = eff_bn,
				base_cur = eff_bn + 1,
				base_end = eff_bn + tape.Node_Index(bt.n),
			}) or_return
		}
		return nil
	}

	// Optional single-member root wrapper (e.g. XML `<tag>...</tag>`).
	wrapped := len(opts.wrap_key) > 0
	if wrapped {
		append(&nodes, tape.Node{kind = .Object, role = .Value}) or_return
		klo, kn := append_str(&src, opts.wrap_key) or_return
		append(&nodes, tape.Node{lo = klo, n = kn, kind = .String, role = .Key}) or_return
	}

	emit_one(ov, root_h, base_node, .Value, &src, &nodes, &facts, &present, &stack, opts, opts.root_style, true, allocator) or_return

	for len(stack) > 0 {
		fr := &stack[len(stack) - 1]
		if fr.base_c != tape.NO_NODE {
			// Walking untouched base container iteratively.
			if fr.base_cur >= fr.base_end {
				finalize_mat_frame(&nodes, &counts, fr, allocator) or_return
				pop(&stack)
				continue
			}
			if fr.is_obj {
				kn := fr.base_cur
				vn := kn + 1
				fr.base_cur = tape.node_after(ov.base, vn)
				fr.child_n += 1
				kt := decode_node_text_tmp(ov.base, kn, allocator)
				klo, klen := append_str(&src, kt.text) or_return
				free_tmp_text(kt, allocator)
				append(&nodes, tape.Node{lo = klo, n = klen, kind = .String, role = .Key}) or_return
				emit_one(ov, NO_HANDLE, vn, .Value, &src, &nodes, &facts, &present, &stack, opts, "", false, allocator) or_return
			} else {
				vn := fr.base_cur
				fr.base_cur = tape.node_after(ov.base, vn)
				fr.child_n += 1
				emit_one(ov, NO_HANDLE, vn, .Value, &src, &nodes, &facts, &present, &stack, opts, "", false, allocator) or_return
			}
			continue
		}

		if fr.is_obj {
			if fr.idx >= len(fr.members) {
				finalize_mat_frame(&nodes, &counts, fr, allocator) or_return
				destroy_effective_members(fr.members, fr.owned_keys, allocator)
				pop(&stack)
				continue
			}
			m := fr.members[fr.idx]
			fr.idx += 1
			fr.child_n += 1
			klo, klen := append_str(&src, m.key) or_return
			append(&nodes, tape.Node{lo = klo, n = klen, kind = .String, role = .Key}) or_return
			emit_one(ov, m.handle, m.base_val, .Value, &src, &nodes, &facts, &present, &stack, opts, "", false, allocator) or_return
		} else {
			if fr.idx >= len(fr.elems) {
				finalize_mat_frame(&nodes, &counts, fr, allocator) or_return
				delete(fr.elems, allocator)
				pop(&stack)
				continue
			}
			e := fr.elems[fr.idx]
			fr.idx += 1
			fr.child_n += 1
			emit_one(ov, e.handle, e.base, .Value, &src, &nodes, &facts, &present, &stack, opts, "", false, allocator) or_return
		}
	}

	if wrapped {
		nodes[0].n = u32(len(nodes))
		nodes[0].spelling = 1
	}

	// Copy into exact-sized slices matching `tape.destroy_document` (`free(raw_data(...), doc.allocator)`).
	out_src: []u8
	if len(src) > 0 {
		out_src = make([]u8, len(src), allocator) or_return
		copy(out_src, src[:])
	}
	delete(src)

	out_nodes := alloc_exact_slice(nodes[:], allocator) or_return
	delete(nodes)

	out_facts: []tape.Fact
	if len(facts) > 0 {
		out_facts = alloc_exact_slice(facts[:], allocator) or_return
	}
	delete(facts)

	out_counts: []tape.Child_Count
	if len(counts) > 0 {
		out_counts = alloc_exact_slice(counts[:], allocator) or_return
	}
	delete(counts)

	flags := tape.Doc_Flags{.Owns_Src}
	if opts.target_format != nil {
		// Prevent format writers from taking raw already-escaped copy-through shortcuts (without requiring `.Held` ext!).
		flags += {.Tolerated}
	}
	return tape.Document {
		src        = out_src,
		nodes      = out_nodes,
		facts      = out_facts,
		counts     = out_counts,
		format     = opts.target_format if opts.target_format != nil else &MATERIALIZED_FORMAT,
		root_close = u64(len(out_src)),
		present    = present,
		flags      = flags,
		allocator  = allocator,
	}, nil
}

@(private = "file")
alloc_exact_slice :: proc(items: []$T, allocator: runtime.Allocator) -> (out: []T, err: runtime.Allocator_Error) {
	if len(items) == 0 {
		return nil, nil
	}
	raw := runtime.mem_alloc_non_zeroed(len(items) * size_of(T), align_of(T), allocator) or_return
	out = ([^]T)(raw_data(raw))[:len(items)]
	copy(out, items)
	return out, nil
}

@(private = "file")
finalize_mat_frame :: proc(
	nodes: ^[dynamic]tape.Node,
	counts: ^[dynamic]tape.Child_Count,
	fr: ^$F,
	allocator: runtime.Allocator,
) -> runtime.Allocator_Error {
	_ = allocator
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

@(private)
cbor_parse_tag_override :: proc "contextless" (f: Fact_Override) -> (tag: u64, ok: bool) {
	if n, has := f.num_tag.?; has {
		return n, true
	}
	if len(f.values) != 1 || len(f.values[0]) == 0 || len(f.values[0]) > 20 {
		return 0, false
	}
	val: u64
	for c in transmute([]u8)f.values[0] {
		if c < '0' || c > '9' {
			return 0, false
		}
		d := u64(c - '0')
		if val > (max(u64) - d) / 10 {
			return 0, false
		}
		val = val * 10 + d
	}
	return val, true
}
