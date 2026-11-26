package edit

import "base:runtime"
import "core:bytes"
import "stury:lib/core/tape"

// Binary-family composer (CBOR: Cbor, Preferred, Deterministic, Length_First).
//
// Preserves untouched sub-item byte spans verbatim when target compatibility allows it, re-encodes
// modified/upgraded subtrees via the format's real `cbor.write` (getting binary16 subnormals, canonical
// heads, bignums, and child tags for free), supports `.@tag` edits, sorts modified map keys under
// Deterministic / Length_First, validates reorder permutations, and uses an explicit heap stack.

Binary_Spec :: struct {
	target:       ^tape.Format,
	strict:       bool, // Preferred / Deterministic / Length_First: shortest heads, definite containers
	sorted_maps:  bool, // Deterministic / Length_First: sort modified maps by encoded key
	length_first: bool, // Length_First: shorter encoded key first, then lexicographic
	// Returns `(tags_lo, item_lo, item_hi)` of base node `at` in `doc.src`.
	item_span:    proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (tags_lo, item_lo, item_hi: u64),
	// Encodes a CBOR major-type head `(major, val)` into `out`.
	put_head:     proc(data: rawptr, major: u8, val: u64, out: ^[dynamic]u8),
	// Encodes a UTF-8 map key string as a CBOR text string into `out`.
	put_key:      proc(data: rawptr, key: string, out: ^[dynamic]u8),
	// Encodes an `Edit_Node` `h` (or untouched `base_node` when `h == NO_HANDLE`) via `cbor.write` into `out`.
	spell_value:  proc(data: rawptr, ov: ^Overlay, h: Handle, base_node: tape.Node_Index, out: ^[dynamic]u8) -> Error,
	// Validates final CBOR output.
	validate:     proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	data:         rawptr,
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
	// Cross-spec upgrade to a strict CBOR spec (e.g. `.Cbor` -> `.Preferred`/`.Deterministic`/`.Length_First`)
	// cannot blindly verbatim-copy non-preferred bytes even when `!ov.dirty`!
	same_format := ov != nil && ov.base != nil && ((opts.target if opts.target != nil else spec.target) == ov.base.format || !spec.strict)
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
		ov            = ov,
		doc           = doc,
		src           = doc.src,
		spec          = spec,
		opts          = opts,
		verbatim_ok   = !spec.strict || doc.format == target,
		allocator     = allocator,
	}
	out := make([dynamic]u8, 0, len(doc.src), allocator)
	defer if err != nil {
		delete(out)
	}
	recs := make([dynamic]Splice_Record, 0, 8, allocator)
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

// Emits CBOR tag header(s) for node `n` (or copies original stacked tags if untouched), recording any dropped non-tag facts.
@(private = "file")
emit_binary_tags :: proc(cx: ^Binary_Cx, n: ^Edit_Node, tags_lo, item_lo: u64, out: ^[dynamic]u8) -> Error {
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
			append(out, ..cx.src[tags_lo:item_lo])
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
	cx.spec.put_head(cx.spec.data, 6, tag_num, out)
	return nil
}

@(private = "file")
Sorted_Pair :: struct {
	lo, mid, hi: int,
}

// Iterative CBOR serializer over `cx.ov`: copies every untouched compatible subtree verbatim and encodes edited/upgraded
// subtrees via `cbor.write` without native recursion.
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

	stack := make([dynamic]Frame, 0, 32, cx.allocator)
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

	// Resolves the innermost active buffer: nearest enclosing sorting frame's `sort_buf`, or `out`!
	// Ensures nested non-sorting containers (e.g. arrays inside a sorted map) write into the map's `sort_buf`.
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
		// Untouched base subtree -> verbatim byte copy ONLY when target format is compatible!
		if h == NO_HANDLE {
			if cx.verbatim_ok {
				tags_lo, _, item_hi := cx.spec.item_span(cx.doc, base_node)
				append(dst, ..cx.src[tags_lo:item_hi])
				return nil
			}
			// Cross-spec upgrade (e.g. `.Cbor` -> `.Preferred`/`.Deterministic`/`.Length_First`): re-encode via `cbor.write`!
			return cx.spec.spell_value(cx.spec.data, cx.ov, NO_HANDLE, base_node, dst)
		}
		n, ok := get_node(cx.ov, h)
		if !ok {
			return refuse(.Bad_Handle, "invalid overlay handle")
		}
		if !n.has_edits && n.base != tape.NO_NODE {
			if cx.verbatim_ok {
				tags_lo, _, item_hi := cx.spec.item_span(cx.doc, n.base)
				append(dst, ..cx.src[tags_lo:item_hi])
				return nil
			}
			return cx.spec.spell_value(cx.spec.data, cx.ov, h, n.base, dst)
		}
		tags_lo, item_lo, item_hi: u64
		if n.base != tape.NO_NODE {
			tags_lo, item_lo, item_hi = cx.spec.item_span(cx.doc, n.base)
		}
		dst_start := u64(len(dst))

		// Replaced or newly built value -> `cbor.write` emits both tags and value cleanly!
		if n.state == .Replaced || n.base == tape.NO_NODE {
			cx.spec.spell_value(cx.spec.data, cx.ov, h, tape.NO_NODE, dst) or_return
			if n.base != tape.NO_NODE && !in_sorted {
				append(recs, Splice_Record {
					base_node    = n.base,
					src_lo       = tags_lo,
					src_hi       = item_hi,
					dst_lo       = dst_start,
					dst_hi       = u64(len(dst)),
					subtree_only = true,
				})
			}
			return nil
		}

		// Fact-only edit on a base leaf: emit tag override + item bytes (re-encoding under strict cross-spec upgrade).
		bnode := cx.doc.nodes[n.base]
		if bnode.kind < .Array {
			if !cx.verbatim_ok {
				cx.spec.spell_value(cx.spec.data, cx.ov, h, n.base, dst) or_return
			} else {
				emit_binary_tags(cx, n, tags_lo, item_lo, dst) or_return
				append(dst, ..cx.src[item_lo:item_hi])
			}
			if !in_sorted {
				append(recs, Splice_Record {
					base_node    = n.base,
					src_lo       = tags_lo,
					src_hi       = item_hi,
					dst_lo       = dst_start,
					dst_hi       = u64(len(dst)),
					subtree_only = true,
				})
			}
			return nil
		}

		// Base container with structural, tag, or descendant edits:
		emit_binary_tags(cx, n, tags_lo, item_lo, dst) or_return
		is_obj := bnode.kind == .Object
		was_indef := (cx.src[item_lo] & 31) == 31
		use_indef := was_indef && !cx.spec.strict

		// Validate explicit reorder permutation if present on this container!
		if d := n.delta; n.state == .Container_Delta && d != nil && len(d.order) > 0 {
			bc := max(0, tape.child_count(cx.doc, n.base, bnode))
			deleted_flags := make([]bool, bc, cx.allocator)
			defer delete(deleted_flags, cx.allocator)
			if is_obj {
				c, _, cerr := tape.children(tape.Reader{doc = cx.doc}, n.base, cx.allocator)
				if cerr != nil {
					return cerr
				}
				bi := 0
				for {
					kn, _, np := tape.next_child(tape.Reader{doc = cx.doc}, &c)
					if np != .Found || bi >= bc {
						break
					}
					tk := decode_node_text_tmp(cx.doc, kn, cx.allocator)
					for dk in d.deleted_keys {
						if dk == tk.text {
							deleted_flags[bi] = true
							break
						}
					}
					free_tmp_text(tk, cx.allocator)
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
		if is_obj {
			eff, ok_keys, merr := effective_members(cx.ov, h, cx.allocator)
			if merr != nil {
				return merr
			}
			defer delete(eff, cx.allocator)
			items = make([]Item_Ref, len(eff), cx.allocator)
			owned_keys = ok_keys
			for m, i in eff {
				items[i] = {
					handle      = m.handle,
					base_key    = m.base_key,
					base_val    = m.base_val,
					key_text    = m.key,
					use_key_str = !cx.verbatim_ok || m.is_inserted || m.renamed || m.base_key == tape.NO_NODE,
				}
			}
		} else {
			eff, eerr := effective_elements(cx.ov, h, cx.allocator)
			if eerr != nil {
				return eerr
			}
			defer delete(eff, cx.allocator)
			items = make([]Item_Ref, len(eff), cx.allocator)
			for e, i in eff {
				items[i] = {handle = e.handle, base_key = tape.NO_NODE, base_val = e.base}
			}
		}

		major := u8(5) if is_obj else u8(4)
		head_start := len(dst)
		if use_indef {
			append(dst, (major << 5) | 31)
		} else {
			cx.spec.put_head(cx.spec.data, major, u64(len(items)), dst)
		}
		head_changed := u64(len(dst) - head_start) != (item_lo - tags_lo + 1) && (was_indef != use_indef || n.state == .Container_Delta)
		sorting := is_obj && cx.spec.sorted_maps && len(items) > 1
		// Any structural container edit, tag edit on container, sorting, or cross-spec upgrade forces `full_rewalk`
		// so `splice_document` never keeps stale child counts/order!
		if !in_sorted && (n.state == .Container_Delta || sorting || len(n.facts) > 0 || head_changed || !cx.verbatim_ok) {
			append(recs, Splice_Record {
				base_node   = n.base,
				src_lo      = tags_lo,
				src_hi      = item_hi,
				dst_lo      = dst_start,
				dst_hi      = dst_start,
				full_rewalk = true,
			})
		}

		fr := Frame {
			base_c     = n.base,
			is_obj     = is_obj,
			indefinite = use_indef,
			items      = items,
			owned_keys = owned_keys,
			sorting    = sorting,
		}
		if sorting {
			fr.sort_buf = make([dynamic]u8, 0, 128, cx.allocator)
			fr.sort_entries = make([dynamic]Sorted_Pair, 0, len(items), cx.allocator)
		}
		append(stack, fr)
		return nil
	}

	root_h := cx.ov.root
	emit_or_push(cx, out, false, recs, &stack, root_h, tape.ROOT) or_return

	for len(stack) > 0 {
		fr := &stack[len(stack) - 1]
		target_buf, in_sorted := active_buf(out, stack[:])
		if fr.sorting && fr.in_val {
			append(&fr.sort_entries, Sorted_Pair{lo = fr.cur_lo, mid = fr.cur_mid, hi = len(fr.sort_buf)})
			fr.in_val = false
		}

		if fr.idx >= len(fr.items) {
			parent_buf, _ := active_buf(out, stack[:len(stack) - 1])
			if fr.sorting {
				sort_cbor_pairs(fr.sort_entries[:], fr.sort_buf[:], cx.spec.length_first)
				for e in fr.sort_entries {
					append(parent_buf, ..fr.sort_buf[e.lo:e.hi])
				}
			}
			if fr.indefinite {
				append(parent_buf, 0xFF)
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
				cx.spec.put_key(cx.spec.data, item.key_text, target_buf)
			} else {
				ktlo, _, khi := cx.spec.item_span(cx.doc, item.base_key)
				append(target_buf, ..cx.src[ktlo:khi])
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
