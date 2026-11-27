package edit

import "base:runtime"
import "core:bytes"
import "stury:lib/core/tape"

// Binary-family composer (CBOR & MessagePack).
//
// Preserves untouched sub-item byte spans verbatim when target compatibility allows it, delegates modified/upgraded
// subtrees to format callbacks, supports tag overrides/checks, sorts modified CBOR maps under Deterministic /
// Length_First, validates reorder permutations, handles `.Base_Ref` containers, and uses an explicit heap stack.

Binary_Spec :: struct {
	target:           ^tape.Format,
	same_family:      bool, // true when `ov.base.format` belongs to this binary format family
	strict:           bool, // Preferred / Deterministic / Length_First / Compact: shortest heads, definite containers
	sorted_maps:      bool, // Deterministic / Length_First: sort modified maps by encoded key
	length_first:     bool, // Length_First: shorter encoded key first, then lexicographic
	has_indefinite:   bool, // CBOR: preserve indefinite container encoding when `!strict`
	no_prefix_tags:   bool, // MessagePack: tags alter leaf encoding (fact-edited leaves delegate to `spell_value`)
	spell_containers: bool, // CBOR: replaced `.Array`/`.Object` delegate to `spell_value`
	// Optional: returns `(tags_lo, item_lo, item_hi)` of base node `at` in `doc.src` (defaults to `binary_item_span`).
	item_span:        proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (tags_lo, item_lo, item_hi: u64),
	// Optional: returns original container head byte length at `src[at]` for head-shrink detection.
	head_len:         proc "contextless" (src: []u8, at: u64) -> u64,
	// Encodes a container or CBOR tag head `(major, val)` into `out` (`major`: 4=array, 5=map, 6=CBOR tag).
	put_head:         proc(data: rawptr, major: u8, val: u64, out: ^[dynamic]u8) -> Error,
	// Encodes a UTF-8 map key string into `out`.
	put_key:          proc(data: rawptr, key: string, node: tape.Node_Index, out: ^[dynamic]u8) -> Error,
	// Optional: encodes an untouched non-verbatim base map key (preserving integer/bytes/timestamp keys).
	put_base_key:     proc(data: rawptr, doc: ^tape.Document, base_key: tape.Node_Index, dropped: ^tape.Facts, out: ^[dynamic]u8) -> Error,
	// Optional: validates/emits tags on a container (nil uses CBOR prefix-tag handling).
	emit_tags:        proc(data: rawptr, doc: ^tape.Document, n: ^Edit_Node, base_c: tape.Node_Index, tags_lo, item_lo: u64, dropped: ^tape.Facts, out: ^[dynamic]u8) -> Error,
	// Encodes an `Edit_Node` `h` (or untouched `base_node` when `h == NO_HANDLE`) into `out`.
	spell_value:      proc(data: rawptr, ov: ^Overlay, h: Handle, base_node: tape.Node_Index, dropped: ^tape.Facts, out: ^[dynamic]u8) -> Error,
	// Validates final binary output.
	validate:         proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	data:             rawptr,
}

binary_item_span :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (tags_lo, item_lo, item_hi: u64) {
	item_lo, item_hi, _ = node_byte_span(doc, at)
	tags_lo = item_lo
	for f in tape.facts_of(doc, at) {
		if f.kind == .Tag && f.lo < tags_lo {
			tags_lo = f.lo
		}
	}
	return tags_lo, item_lo, item_hi
}

commit_binary :: proc(
	ov: ^Overlay,
	spec: ^Binary_Spec,
	opts := Options{},
	allocator := context.allocator,
) -> (
	res: Commit_Result,
	err: Error,
) {
	// Cross-spec upgrade to a strict spec or cross-family edit cannot verbatim-copy base bytes even when `!ov.dirty`.
	target_fmt := opts.target if opts.target != nil else spec.target
	same_format := ov != nil && ov.base != nil && spec.same_family && (target_fmt == ov.base.format || !spec.strict)
	fast, target, fast_res, gerr := commit_guard(ov, spec.target, opts, same_format, spec.validate, spec.data, allocator)
	if gerr != nil {
		return {}, gerr
	}
	if fast {
		return fast_res, nil
	}
	if ov.unlinked_parents {
		ensure_linked(ov) or_return
	}

	doc := ov.base
	cx := Binary_Cx {
		ov          = ov,
		doc         = doc,
		src         = doc.src,
		spec        = spec,
		opts        = opts,
		verbatim_ok = spec.same_family && (!spec.strict || doc.format == target),
		allocator   = allocator,
	}
	out := make([dynamic]u8, 0, len(doc.src), allocator) or_return
	defer if err != nil {
		delete(out)
	}
	recs := make([dynamic]Splice_Record, 0, 8, allocator) or_return
	defer if err != nil {
		delete(recs)
	}

	emit_binary_iterative(&cx, &out, &recs) or_return

	if spec.validate != nil {
		if verr := spec.validate(spec.data, out[:], allocator); verr != nil {
			return {}, convert_tape_error(verr)
		}
	}
	return Commit_Result {
		bytes     = out[:],
		dropped   = cx.dropped,
		splices   = recs[:],
		allocator = allocator,
	}, nil
}

@(private = "file")
Binary_Cx :: struct {
	ov:          ^Overlay,
	doc:         ^tape.Document,
	src:         []u8,
	spec:        ^Binary_Spec,
	opts:        Options,
	verbatim_ok: bool,
	dropped:     tape.Facts,
	allocator:   runtime.Allocator,
}

@(private = "file")
span_of :: #force_inline proc "contextless" (cx: ^Binary_Cx, at: tape.Node_Index) -> (tags_lo, item_lo, item_hi: u64) {
	if cx.spec.item_span != nil {
		return cx.spec.item_span(cx.doc, at)
	}
	return binary_item_span(cx.doc, at)
}

// Emits tag header(s) or runs the format's container-tag check for node `n`, recording any dropped non-tag facts.
@(private = "file")
emit_binary_tags :: proc(cx: ^Binary_Cx, n: ^Edit_Node, base_c: tape.Node_Index, tags_lo, item_lo: u64, out: ^[dynamic]u8) -> Error {
	if cx.spec.emit_tags != nil {
		return cx.spec.emit_tags(cx.spec.data, cx.doc, n, base_c, tags_lo, item_lo, &cx.dropped, out)
	}
	has_tag_override := false
	tag_fo: Fact_Override
	for f in n.facts {
		if f.kind == .Tag {
			has_tag_override = true
			tag_fo = f
		} else if !f.deleted {
			cx.dropped += {f.kind}
		}
	}
	if !has_tag_override {
		if tags_lo < item_lo {
			append(out, ..cx.src[tags_lo:item_lo]) or_return
		}
		return nil
	}
	if tag_fo.deleted {
		return nil
	}
	tag_num, tok := cbor_parse_tag_override(tag_fo)
	if !tok {
		return refuse(.Fact_No_Place, "CBOR tag must be an unsigned 64-bit integer", n.base, tags_lo)
	}
	return cx.spec.put_head(cx.spec.data, 6, tag_num, out)
}

@(private = "file")
Sorted_Pair :: struct {
	lo, mid, hi: int,
}

// Iterative binary serializer over `cx.ov`: copies untouched compatible subtrees verbatim and delegates edited/upgraded
// subtrees to `cx.spec` callbacks without native recursion.
@(private = "file")
emit_binary_iterative :: proc(cx: ^Binary_Cx, out: ^[dynamic]u8, recs: ^[dynamic]Splice_Record) -> Error {
	Item_Ref :: struct {
		handle:      Handle,
		base_key:    tape.Node_Index,
		base_val:    tape.Node_Index,
		key_text:    string,
		use_key_str: bool,
	}
	Frame :: struct {
		base_c:       tape.Node_Index,
		is_obj:       bool,
		indefinite:   bool,
		items:        []Item_Ref,
		owned_keys:   []string,
		idx:          int,
		sorting:      bool,
		sort_buf:     [dynamic]u8,
		sort_entries: [dynamic]Sorted_Pair,
		cur_lo:       int,
		cur_mid:      int,
		in_val:       bool,
	}

	stack := make([dynamic]Frame, 0, 32, cx.allocator) or_return
	defer {
		for &fr in stack {
			delete(fr.items, cx.allocator)
			for s in fr.owned_keys {
				delete(s, cx.allocator)
			}
			delete(fr.owned_keys, cx.allocator)
			delete(fr.sort_buf)
			delete(fr.sort_entries)
		}
		delete(stack)
	}

	// Resolves the innermost active buffer: nearest enclosing sorting frame's `sort_buf`, or `out`.
	active_buf :: proc "contextless" (out: ^[dynamic]u8, s: []Frame) -> (^[dynamic]u8, bool) {
		for i := len(s) - 1; i >= 0; i -= 1 {
			if s[i].sorting {
				return &s[i].sort_buf, true
			}
		}
		return out, false
	}

	emit_or_push :: proc(
		cx: ^Binary_Cx,
		dst: ^[dynamic]u8,
		in_sorted: bool,
		recs: ^[dynamic]Splice_Record,
		stack: ^[dynamic]Frame,
		h: Handle,
		base_node: tape.Node_Index,
	) -> Error {
		// Untouched base subtree -> verbatim byte copy ONLY when target format is compatible.
		if h == NO_HANDLE {
			if cx.verbatim_ok {
				tags_lo, _, item_hi := span_of(cx, base_node)
				append(dst, ..cx.src[tags_lo:item_hi]) or_return
				return nil
			}
			return cx.spec.spell_value(cx.spec.data, cx.ov, NO_HANDLE, base_node, &cx.dropped, dst)
		}
		n, ok := get_node(cx.ov, h)
		if !ok {
			return refuse(.Bad_Handle, "invalid overlay handle")
		}
		if !n.has_edits && n.base != tape.NO_NODE && n.base_ref == tape.NO_NODE {
			if cx.verbatim_ok {
				tags_lo, _, item_hi := span_of(cx, n.base)
				append(dst, ..cx.src[tags_lo:item_hi]) or_return
				return nil
			}
			return cx.spec.spell_value(cx.spec.data, cx.ov, h, n.base, &cx.dropped, dst)
		}
		tags_lo, item_lo, item_hi: u64
		if n.base != tape.NO_NODE {
			tags_lo, item_lo, item_hi = span_of(cx, n.base)
		}
		dst_start := u64(len(dst))

		// Replaced or newly built node:
		if n.state == .Replaced || (n.base == tape.NO_NODE && n.base_ref == tape.NO_NODE) {
			if !cx.spec.spell_containers && (n.val.kind == .Array || n.val.kind == .Object) {
				emit_binary_tags(cx, n, tape.NO_NODE, tags_lo, item_lo, dst) or_return
				is_obj := n.val.kind == .Object
				items: []Item_Ref
				ok_push := false
				defer if !ok_push {
					delete(items, cx.allocator)
				}
				if is_obj {
					items = make([]Item_Ref, len(n.members), cx.allocator) or_return
					for m, i in n.members {
						items[i] = {handle = m.value, base_val = tape.NO_NODE, base_key = tape.NO_NODE, key_text = m.key, use_key_str = true}
					}
				} else {
					items = make([]Item_Ref, len(n.elems), cx.allocator) or_return
					for e, i in n.elems {
						items[i] = {handle = e, base_val = tape.NO_NODE, base_key = tape.NO_NODE}
					}
				}
				cx.spec.put_head(cx.spec.data, 5 if is_obj else 4, u64(len(items)), dst) or_return
				append(stack, Frame{is_obj = is_obj, items = items}) or_return
				ok_push = true
				if n.base != tape.NO_NODE && !in_sorted {
					append(recs, Splice_Record {
						base_node   = n.base,
						src_lo      = tags_lo,
						src_hi      = item_hi,
						dst_lo      = dst_start,
						dst_hi      = dst_start,
						full_rewalk = true,
					}) or_return
				}
				return nil
			}
			cx.spec.spell_value(cx.spec.data, cx.ov, h, tape.NO_NODE, &cx.dropped, dst) or_return
			if n.base != tape.NO_NODE && !in_sorted {
				append(recs, Splice_Record {
					base_node    = n.base,
					src_lo       = tags_lo,
					src_hi       = item_hi,
					dst_lo       = dst_start,
					dst_hi       = u64(len(dst)),
					subtree_only = true,
				}) or_return
			}
			return nil
		}

		// Base node in `.Ancestor` or `.Container_Delta` (including `.Base_Ref` containers with structural edits):
		base_c := node_base_container(n)
		if base_c == tape.NO_NODE {
			return refuse(.Bad_Handle, "missing base container for overlay edit")
		}
		bnode := cx.doc.nodes[base_c]
		if bnode.kind < .Array {
			if !cx.verbatim_ok || cx.spec.no_prefix_tags {
				cx.spec.spell_value(cx.spec.data, cx.ov, h, base_c, &cx.dropped, dst) or_return
			} else {
				emit_binary_tags(cx, n, base_c, tags_lo, item_lo, dst) or_return
				append(dst, ..cx.src[item_lo:item_hi]) or_return
			}
			if n.base != tape.NO_NODE && !in_sorted {
				append(recs, Splice_Record {
					base_node    = n.base,
					src_lo       = tags_lo,
					src_hi       = item_hi,
					dst_lo       = dst_start,
					dst_hi       = u64(len(dst)),
					subtree_only = true,
				}) or_return
			}
			return nil
		}

		// Base container with structural, tag, or descendant edits:
		emit_binary_tags(cx, n, base_c, tags_lo, item_lo, dst) or_return
		is_obj := bnode.kind == .Object
		was_indef := cx.spec.has_indefinite && cx.spec.same_family && n.base != tape.NO_NODE && n.base_ref == tape.NO_NODE && (cx.src[item_lo] & 31) == 31
		use_indef := was_indef && !cx.spec.strict

		// Validate explicit reorder permutation if present on this container.
		if d := n.delta; n.state == .Container_Delta && d != nil && len(d.order) > 0 {
			bc := max(0, tape.child_count(cx.doc, base_c, bnode))
			deleted_flags := make([]bool, bc, cx.allocator) or_return
			defer delete(deleted_flags, cx.allocator)
			if is_obj {
				c, _, cerr := tape.children(tape.Reader{doc = cx.doc}, base_c, cx.allocator)
				if cerr != nil {
					return cerr
				}
				bi := 0
				for {
					kn, _, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
					if np != .Found || bi >= bc {
						break
					}
					if kn != tape.NO_NODE {
						tk := decode_node_text_tmp(cx.doc, kn, cx.allocator)
						for dk in d.deleted_keys {
							if dk == tk.text {
								deleted_flags[bi] = true
								break
							}
						}
						free_tmp_text(tk, cx.allocator)
					} else if c.keys_n != 0 {
						kt := tape.cell_key(tape.Reader{doc = cx.doc}, c)
						kroom := tape.text_room(cx.doc, kt)
						if kroom == 0 {
							ktext := string(tape.span_bytes(cx.doc, kt.lo, kt.n))
							for dk in d.deleted_keys {
								if dk == ktext {
									deleted_flags[bi] = true
									break
								}
							}
						} else {
							kbuf := make([]u8, kroom, cx.allocator) or_return
							if ktext, kok := tape.node_text(cx.doc, kt, kbuf); kok {
								for dk in d.deleted_keys {
									if dk == ktext {
										deleted_flags[bi] = true
										break
									}
								}
							}
							delete(kbuf, cx.allocator)
						}
					}
					bi += 1
				}
				tape.destroy_children(&c)
				validate_order(d.order, deleted_flags[:bi], len(d.inserted_members), cx.allocator) or_return
			} else {
				for di in d.deleted_indices {
					if int(di) < bc {
						deleted_flags[di] = true
					}
				}
				validate_order(d.order, deleted_flags, len(d.inserted_elems), cx.allocator) or_return
			}
		}

		items: []Item_Ref
		owned_keys: []string
		ok_push := false
		defer if !ok_push {
			delete(items, cx.allocator)
			for s in owned_keys {
				delete(s, cx.allocator)
			}
			delete(owned_keys, cx.allocator)
		}
		if is_obj {
			eff, ok_keys, merr := effective_members(cx.ov, h, cx.allocator)
			if merr != nil {
				return merr
			}
			owned_keys = ok_keys
			defer delete(eff, cx.allocator)
			items = make([]Item_Ref, len(eff), cx.allocator) or_return
			for m, i in eff {
				items[i] = {
					handle      = m.handle,
					base_key    = m.base_key,
					base_val    = m.base_val,
					key_text    = m.key,
					use_key_str = m.is_inserted || m.renamed || m.base_key == tape.NO_NODE || (!cx.verbatim_ok && cx.spec.put_base_key == nil),
				}
			}
		} else {
			eff, eerr := effective_elements(cx.ov, h, cx.allocator)
			if eerr != nil {
				return eerr
			}
			defer delete(eff, cx.allocator)
			items = make([]Item_Ref, len(eff), cx.allocator) or_return
			for e, i in eff {
				items[i] = {handle = e.handle, base_key = tape.NO_NODE, base_val = e.base}
			}
		}

		major := u8(5) if is_obj else u8(4)
		head_start := len(dst)
		if use_indef {
			append(dst, (major << 5) | 31) or_return
		} else {
			cx.spec.put_head(cx.spec.data, major, u64(len(items)), dst) or_return
		}
		head_changed: bool
		if cx.spec.head_len != nil {
			orig_head_len := cx.spec.head_len(cx.src, item_lo) if (cx.spec.same_family && n.base != tape.NO_NODE && n.base_ref == tape.NO_NODE) else u64(0)
			head_changed = u64(len(dst) - head_start) != orig_head_len
		} else {
			head_changed = u64(len(dst) - head_start) != (item_lo - tags_lo + 1) && (was_indef != use_indef || n.state == .Container_Delta)
		}
		sorting := is_obj && cx.spec.sorted_maps && len(items) > 1
		// Any structural container edit, tag edit on container, sorting, head size change, or cross-spec upgrade forces `full_rewalk`.
		if n.base != tape.NO_NODE && !in_sorted && (n.state == .Container_Delta || n.base_ref != tape.NO_NODE || sorting || len(n.facts) > 0 || head_changed || !cx.verbatim_ok) {
			append(recs, Splice_Record {
				base_node   = n.base,
				src_lo      = tags_lo,
				src_hi      = item_hi,
				dst_lo      = dst_start,
				dst_hi      = dst_start,
				full_rewalk = true,
			}) or_return
		}

		fr := Frame {
			base_c     = base_c,
			is_obj     = is_obj,
			indefinite = use_indef,
			items      = items,
			owned_keys = owned_keys,
			sorting    = sorting,
		}
		if sorting {
			sbuf, sberr := make([dynamic]u8, 0, 128, cx.allocator)
			if sberr != nil {
				return sberr
			}
			sent, seerr := make([dynamic]Sorted_Pair, 0, len(items), cx.allocator)
			if seerr != nil {
				delete(sbuf)
				return seerr
			}
			fr.sort_buf = sbuf
			fr.sort_entries = sent
		}
		if _, perr := append(stack, fr); perr != nil {
			delete(fr.sort_buf)
			delete(fr.sort_entries)
			return perr
		}
		ok_push = true
		return nil
	}

	root_h := cx.ov.root
	emit_or_push(cx, out, false, recs, &stack, root_h, tape.ROOT) or_return

	for len(stack) > 0 {
		fr := &stack[len(stack) - 1]
		target_buf, in_sorted := active_buf(out, stack[:])
		if fr.sorting && fr.in_val {
			append(&fr.sort_entries, Sorted_Pair{lo = fr.cur_lo, mid = fr.cur_mid, hi = len(fr.sort_buf)}) or_return
			fr.in_val = false
		}

		if fr.idx >= len(fr.items) {
			parent_buf, _ := active_buf(out, stack[:len(stack) - 1])
			if fr.sorting {
				sort_cbor_pairs(fr.sort_entries[:], fr.sort_buf[:], cx.spec.length_first)
				for e in fr.sort_entries {
					append(parent_buf, ..fr.sort_buf[e.lo:e.hi]) or_return
				}
			}
			if fr.indefinite {
				append(parent_buf, 0xFF) or_return
			}
			delete(fr.items, cx.allocator)
			for s in fr.owned_keys {
				delete(s, cx.allocator)
			}
			delete(fr.owned_keys, cx.allocator)
			delete(fr.sort_buf)
			delete(fr.sort_entries)
			pop(&stack)
			continue
		}

		item := fr.items[fr.idx]
		fr.idx += 1
		if fr.sorting {
			fr.cur_lo = len(fr.sort_buf)
		}
		if fr.is_obj {
			if item.use_key_str {
				cx.spec.put_key(cx.spec.data, item.key_text, item.base_key, target_buf) or_return
			} else if cx.verbatim_ok {
				ktlo, _, khi := span_of(cx, item.base_key)
				append(target_buf, ..cx.src[ktlo:khi]) or_return
			} else {
				cx.spec.put_base_key(cx.spec.data, cx.doc, item.base_key, &cx.dropped, target_buf) or_return
			}
		}
		if fr.sorting {
			fr.cur_mid = len(fr.sort_buf)
			fr.in_val = true
		}
		emit_or_push(cx, target_buf, in_sorted, recs, &stack, item.handle, item.base_val) or_return
	}
	return nil
}

@(private = "file")
sort_cbor_pairs :: proc(entries: []Sorted_Pair, buf: []u8, length_first: bool) {
	less :: proc(a, b: Sorted_Pair, buf: []u8, length_first: bool) -> bool {
		ka := buf[a.lo:a.mid]
		kb := buf[b.lo:b.mid]
		if length_first && len(ka) != len(kb) {
			return len(ka) < len(kb)
		}
		return bytes.compare(ka, kb) < 0
	}
	n := len(entries)
	for gap := n / 2; gap > 0; gap /= 2 {
		for i := gap; i < n; i += 1 {
			tmp := entries[i]
			j := i
			for j >= gap && less(tmp, entries[j - gap], buf, length_first) {
				entries[j] = entries[j - gap]
				j -= gap
			}
			entries[j] = tmp
		}
	}
}
