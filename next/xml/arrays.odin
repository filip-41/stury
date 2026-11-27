package xml

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Predicate deciding whether a single element at `path` (decoded element names from the document root, e.g.
// `["root", "item"]`) should be wrapped in a 1-element array under `Xml_Arrays.Schema`.
Array_Predicate :: #type proc(ctx: rawptr, path: []string) -> bool

// Normalizes `doc` in place according to `mode`, using a strictly iterative pass (explicit heap stack; safe at
// arbitrary nesting depths without recursion, zero `context.temp_allocator`, WASM-clean).
//
// - `.Auto` (or empty document): immediate no-op (`nil`).
// - `.Always`: every non-`#text` child element at depth >= 1 becomes an `.Array` node (even when single).
//   The unique XML document root element (depth 0) is never wrapped under `.Always`. Single `#text` members stay
//   unwrapped; 2+ `#text` members under one element are grouped into an `.Array` to preserve unique keys.
// - `.Schema`: repeated sibling elements (2+ occurrences, adjacent or non-adjacent) are grouped into one `.Array`
//   in document order; a single non-`#text` element is wrapped in a 1-element `.Array` when `pred != nil` and
//   `pred(pred_ctx, path)` returns `true`.
//
// All `tape.Document` invariants (`nodes[0].n`, container `.n` and `spelling`, saturated `counts`, remapped and
// `(node, source order)`-sorted `facts`, `Markup_Ext` namespace scopes/URIs, DTD, `root_close`, `present`, `flags`)
// are preserved. New document slices are allocated from `doc.allocator` (falling back to `allocator`), temporary work
// buffers from `allocator`. On any error (including OOM), `doc` is left untouched and leak-free.
@(require_results)
normalize_arrays :: proc(
	doc: ^tape.Document,
	mode: tape.Xml_Arrays,
	pred: Array_Predicate = nil,
	pred_ctx: rawptr = nil,
	allocator := context.allocator,
	budget := tape.Budget{},
) -> (err: tape.Error) {
	if mode > max(tape.Xml_Arrays) {
		return tape.Bad_Option{"format"}
	}
	if mode == .Auto {
		return nil
	}
	if doc == nil || .Borrowed in doc.flags || doc.partial != nil {
		return tape.Bad_Option{"document"}
	}
	if doc.format == nil || doc.format.options != .Xml {
		return tape.Bad_Option{"format"}
	}
	if len(doc.nodes) == 0 || doc.nodes[0].kind <= .Plain {
		return nil
	}

	node_limit := u64(budget.nodes) if budget.nodes > 0 else u64(tape.NO_NODE) - 1
	doc_alloc := doc.allocator if doc.allocator.procedure != nil else allocator
	scratch := allocator

	rb: hook.Read_Budget
	eff_doc_alloc := doc_alloc
	eff_scratch := scratch
	if budget.memory > 0 {
		// Existing document slices remain live until atomic commit, so charge them against `budget.memory`.
		live := u64(len(doc.nodes)) * u64(size_of(tape.Node)) +
			u64(len(doc.facts)) * u64(size_of(tape.Fact)) +
			u64(len(doc.counts)) * u64(size_of(tape.Child_Count))
		if live > budget.memory {
			return tape.Exceeded{kind = .Memory, at = tape.NO_BYTE}
		}
		rb.main = {backing = doc_alloc, limit = budget.memory, held = live, peer = &rb.scratch}
		rb.scratch = {backing = scratch, limit = budget.memory, peer = &rb.main}
		eff_doc_alloc = hook.memory_budget(&rb.main)
		eff_scratch = hook.memory_budget(&rb.scratch)
	}
	defer if err != nil && budget.memory > 0 {
		err = hook.memory_budget_error(&rb.main, err)
	}

	old_nodes := doc.nodes
	need_path := mode == .Schema && pred != nil

	init_cap := min(len(old_nodes), int(min(node_limit, u64(max(int)))))
	new_nodes, nn_err := make([dynamic]tape.Node, 0, init_cap, eff_doc_alloc)
	if nn_err != nil {
		return nn_err
	}
	committed := false
	defer if !committed {
		delete(new_nodes)
	}

	old_to_new, map_err := make([]tape.Node_Index, len(old_nodes), eff_scratch)
	if map_err != nil {
		return map_err
	}
	defer delete(old_to_new, eff_scratch)
	for &m in old_to_new {
		m = tape.NO_NODE
	}

	frames: [dynamic]Norm_Frame
	frames.allocator = eff_scratch
	defer delete(frames)

	groups_pool: [dynamic]Member_Group
	groups_pool.allocator = eff_scratch
	defer delete(groups_pool)

	vals_pool: [dynamic]tape.Node_Index
	vals_pool.allocator = eff_scratch
	defer delete(vals_pool)

	sat_counts: [dynamic]tape.Child_Count
	sat_counts.allocator = eff_scratch
	defer delete(sat_counts)

	// Reusable scratch buffers for grouping an object's direct members in O(K) time.
	grp_scratch: Group_Scratch
	grp_scratch.raw_members.allocator = eff_scratch
	grp_scratch.next_occ.allocator = eff_scratch
	grp_scratch.slots.allocator = eff_scratch
	grp_scratch.key_a.allocator = eff_scratch
	grp_scratch.key_b.allocator = eff_scratch
	defer {
		delete(grp_scratch.raw_members)
		delete(grp_scratch.next_occ)
		delete(grp_scratch.slots)
		delete(grp_scratch.key_a)
		delete(grp_scratch.key_b)
	}

	// Path state (used only when `mode == .Schema && pred != nil`).
	path_text: [dynamic]u8
	path_text.allocator = eff_scratch
	defer delete(path_text)
	path_spans: [dynamic]Path_Span
	path_spans.allocator = eff_scratch
	defer delete(path_spans)
	path_strs: [dynamic]string
	path_strs.allocator = eff_scratch
	defer delete(path_strs)

	// Emit root container (node 0) and push its frame.
	if aerr := push_container(
		doc,
		tape.ROOT,
		0,
		false,
		node_limit,
		&new_nodes,
		old_to_new,
		&frames,
		&groups_pool,
		&vals_pool,
		&grp_scratch,
	); aerr != nil {
		return aerr
	}

	for len(frames) > 0 {
		top_idx := len(frames) - 1
		f := &frames[top_idx]

		switch f.kind {
		case .Object:
			if f.cur >= f.hi {
				// Close this object container.
				finished := pop(&frames)
				if cerr := finish_container(&new_nodes, finished, &sat_counts); cerr != nil {
					return cerr
				}
				resize(&groups_pool, finished.groups_mark)
				resize(&vals_pool, finished.vals_mark)
				if finished.pushed_path {
					pop_path(&path_text, &path_spans)
				}
				continue
			}

			g := groups_pool[f.cur]
			f.cur += 1
			obj_depth := f.depth

			// Emit the kept first key node of this group.
			key_node := old_nodes[g.first_key]
			new_key_idx := tape.Node_Index(len(new_nodes))
			if u64(len(new_nodes)) >= node_limit {
				return tape.Exceeded{kind = .Nodes, at = tape.NO_BYTE}
			}
			if _, aerr := append(&new_nodes, key_node); aerr != nil {
				return aerr
			}
			old_to_new[g.first_key] = new_key_idx
			f.child_count += 1

			is_text := tape.is_text_key(key_node)
			pushed_seg := false
			if need_path && !is_text {
				if perr := push_path_key(doc, key_node, &path_text, &path_spans); perr != nil {
					return perr
				}
				pushed_seg = true
			}

			occ_count := g.vals_hi - g.vals_lo
			first_val_idx := vals_pool[g.vals_lo]
			first_val_node := old_nodes[first_val_idx]

			should_wrap := false
			if occ_count >= 2 {
				should_wrap = true
			} else if !is_text && first_val_node.kind != .Array {
				switch mode {
				case .Always:
					should_wrap = obj_depth >= 1
				case .Schema:
					if pred != nil {
						if serr := materialize_path(path_text[:], path_spans[:], &path_strs); serr != nil {
							return serr
						}
						should_wrap = pred(pred_ctx, path_strs[:])
					}
				case .Auto:
				}
			}

			if should_wrap {
				// Emit synthesized `.Array` node and push a `.Synth_Array` frame over `vals_pool[g.vals_lo:g.vals_hi]`.
				if u64(len(new_nodes)) >= node_limit {
					return tape.Exceeded{kind = .Nodes, at = tape.NO_BYTE}
				}
				arr_idx := tape.Node_Index(len(new_nodes))
				arr_node := tape.Node {
					lo       = first_val_node.lo,
					n        = 0,
					kind     = .Array,
					role     = .Value,
					spelling = 0,
				}
				if _, aerr := append(&new_nodes, arr_node); aerr != nil {
					return aerr
				}
				if _, aerr := append(&frames, Norm_Frame{
					kind        = .Synth_Array,
					new_idx     = arr_idx,
					depth       = obj_depth + 1,
					cur         = g.vals_lo,
					hi          = g.vals_hi,
					pushed_path = pushed_seg,
				}); aerr != nil {
					return aerr
				}
			} else if first_val_node.kind <= .Plain {
				// Unwrapped scalar value.
				if u64(len(new_nodes)) >= node_limit {
					return tape.Exceeded{kind = .Nodes, at = tape.NO_BYTE}
				}
				val_new_idx := tape.Node_Index(len(new_nodes))
				if _, aerr := append(&new_nodes, first_val_node); aerr != nil {
					return aerr
				}
				old_to_new[first_val_idx] = val_new_idx
				if pushed_seg {
					pop_path(&path_text, &path_spans)
				}
			} else {
				// Unwrapped container value (`.Object` or existing `.Array`).
				if cerr := push_container(
					doc,
					first_val_idx,
					obj_depth + 1,
					pushed_seg,
					node_limit,
					&new_nodes,
					old_to_new,
					&frames,
					&groups_pool,
					&vals_pool,
					&grp_scratch,
				); cerr != nil {
					return cerr
				}
			}

		case .Synth_Array:
			if f.cur >= f.hi {
				finished := pop(&frames)
				if cerr := finish_container(&new_nodes, finished, &sat_counts); cerr != nil {
					return cerr
				}
				if finished.pushed_path {
					pop_path(&path_text, &path_spans)
				}
				continue
			}

			v_old := vals_pool[f.cur]
			f.cur += 1
			f.child_count += 1
			elem_depth := f.depth
			v_node := old_nodes[v_old]

			if v_node.kind <= .Plain {
				if u64(len(new_nodes)) >= node_limit {
					return tape.Exceeded{kind = .Nodes, at = tape.NO_BYTE}
				}
				val_new_idx := tape.Node_Index(len(new_nodes))
				if _, aerr := append(&new_nodes, v_node); aerr != nil {
					return aerr
				}
				old_to_new[v_old] = val_new_idx
			} else {
				if cerr := push_container(
					doc,
					v_old,
					elem_depth,
					false,
					node_limit,
					&new_nodes,
					old_to_new,
					&frames,
					&groups_pool,
					&vals_pool,
					&grp_scratch,
				); cerr != nil {
					return cerr
				}
			}

		case .Existing_Array:
			if f.cur >= f.hi {
				finished := pop(&frames)
				if cerr := finish_container(&new_nodes, finished, &sat_counts); cerr != nil {
					return cerr
				}
				if finished.pushed_path {
					pop_path(&path_text, &path_spans)
				}
				continue
			}

			v_old := tape.Node_Index(f.cur)
			v_node := old_nodes[v_old]
			f.cur = int(tape.node_after(doc, v_old))
			f.child_count += 1
			elem_depth := f.depth

			if v_node.kind <= .Plain {
				if u64(len(new_nodes)) >= node_limit {
					return tape.Exceeded{kind = .Nodes, at = tape.NO_BYTE}
				}
				val_new_idx := tape.Node_Index(len(new_nodes))
				if _, aerr := append(&new_nodes, v_node); aerr != nil {
					return aerr
				}
				old_to_new[v_old] = val_new_idx
			} else {
				if cerr := push_container(
					doc,
					v_old,
					elem_depth,
					false,
					node_limit,
					&new_nodes,
					old_to_new,
					&frames,
					&groups_pool,
					&vals_pool,
					&grp_scratch,
				); cerr != nil {
					return cerr
				}
			}
		}
	}

	// Build remapped & `(node, source order)`-sorted `facts`.
	new_facts: []tape.Fact
	defer if !committed {
		delete(new_facts, eff_doc_alloc)
	}
	if len(doc.facts) > 0 {
		entries, ferr := make([dynamic]Remapped_Fact, 0, len(doc.facts), eff_scratch)
		if ferr != nil {
			return ferr
		}
		defer delete(entries)
		needs_sort := false
		prev_node := tape.Node_Index(0)
		for f, orig_i in doc.facts {
			if int(f.node) >= len(old_to_new) {
				continue
			}
			mapped := old_to_new[f.node]
			if mapped == tape.NO_NODE {
				continue
			}
			nf := f
			nf.node = mapped
			if len(entries) > 0 && mapped < prev_node {
				needs_sort = true
			}
			prev_node = mapped
			if _, aerr := append(&entries, Remapped_Fact{fact = nf, order = u32(orig_i)}); aerr != nil {
				return aerr
			}
		}
		if len(entries) > 0 {
			if needs_sort {
				slice.sort_by(entries[:], proc(a, b: Remapped_Fact) -> bool {
					return a.fact.node < b.fact.node || (a.fact.node == b.fact.node && a.order < b.order)
				})
			}
			nf_slice, nferr := make([]tape.Fact, len(entries), eff_doc_alloc)
			if nferr != nil {
				return nferr
			}
			if raw_data(nf_slice) == nil {
				return runtime.Allocator_Error.Out_Of_Memory
			}
			for e, idx in entries {
				nf_slice[idx] = e.fact
			}
			new_facts = nf_slice
		}
	}

	// Build sorted `counts` for containers whose `spelling` saturated at `MAX_CHILDREN`.
	new_counts: []tape.Child_Count
	defer if !committed {
		delete(new_counts, eff_doc_alloc)
	}
	if len(sat_counts) > 0 {
		slice.sort_by(sat_counts[:], proc(a, b: tape.Child_Count) -> bool {
			return a.node < b.node
		})
		nc_slice, ncerr := make([]tape.Child_Count, len(sat_counts), eff_doc_alloc)
		if ncerr != nil {
			return ncerr
		}
		if raw_data(nc_slice) == nil {
			return runtime.Allocator_Error.Out_Of_Memory
		}
		copy(nc_slice, sat_counts[:])
		new_counts = nc_slice
	}

	// Rebuild `Markup_Ext` namespace scopes/URIs when namespace declarations are present.
	new_ext: ^tape.Doc_Ext
	replace_ext := false
	defer if !committed && replace_ext {
		free(new_ext, eff_doc_alloc)
	}
	if doc.ext != nil {
		if m, ok := doc.ext.format.(tape.Markup_Ext); ok && len(m.scopes) > 0 {
			ext_built, ext_err := rebuild_markup_ext(doc, new_nodes[:], new_facts, m, eff_doc_alloc, eff_scratch)
			if ext_err != nil {
				return ext_err
			}
			new_ext = ext_built
			replace_ext = true
		}
	}

	// Commit atomically: free old slices using `doc_alloc` and install the new ones.
	free(raw_data(doc.nodes), doc_alloc)
	free(raw_data(doc.facts), doc_alloc)
	free(raw_data(doc.counts), doc_alloc)
	doc.nodes = new_nodes[:]
	doc.facts = new_facts
	doc.counts = new_counts
	if replace_ext {
		free(doc.ext, doc_alloc)
		doc.ext = new_ext
	}
	if doc.allocator.procedure == nil {
		doc.allocator = doc_alloc
	}
	committed = true
	return nil
}

@(private = "file")
Frame_Kind :: enum u8 {
	Object,
	Synth_Array,
	Existing_Array,
}

@(private = "file")
Norm_Frame :: struct {
	kind:        Frame_Kind,
	new_idx:     tape.Node_Index,
	depth:       int,
	cur:         int,
	hi:          int,
	groups_mark: int,
	vals_mark:   int,
	child_count: u32,
	pushed_path: bool,
}

@(private = "file")
Member_Group :: struct {
	first_key: tape.Node_Index,
	vals_lo:   int,
	vals_hi:   int,
	hash:      u32,
}

@(private = "file")
Raw_Member :: struct {
	key:  tape.Node_Index,
	val:  tape.Node_Index,
	hash: u32,
}

@(private = "file")
Group_Scratch :: struct {
	raw_members: [dynamic]Raw_Member,
	next_occ:    [dynamic]i32,
	slots:       [dynamic]u32,
	key_a:       [dynamic]u8,
	key_b:       [dynamic]u8,
}

@(private = "file")
Path_Span :: struct {
	lo: int,
	hi: int,
}

@(private = "file")
Remapped_Fact :: struct {
	fact:  tape.Fact,
	order: u32,
}

// Emits container node `old_idx` into `new_nodes`, records `old_to_new[old_idx]`, and pushes its traversal frame.
@(private = "file")
push_container :: proc(
	doc: ^tape.Document,
	old_idx: tape.Node_Index,
	depth: int,
	pushed_path: bool,
	node_limit: u64,
	new_nodes: ^[dynamic]tape.Node,
	old_to_new: []tape.Node_Index,
	frames: ^[dynamic]Norm_Frame,
	groups_pool: ^[dynamic]Member_Group,
	vals_pool: ^[dynamic]tape.Node_Index,
	gs: ^Group_Scratch,
) -> tape.Error {
	if u64(len(new_nodes)) >= node_limit {
		return tape.Exceeded{kind = .Nodes, at = tape.NO_BYTE}
	}
	old_node := doc.nodes[old_idx]
	new_idx := tape.Node_Index(len(new_nodes))
	if _, aerr := append(new_nodes, old_node); aerr != nil {
		return aerr
	}
	old_to_new[old_idx] = new_idx

	if old_node.kind == .Array {
		if _, aerr := append(frames, Norm_Frame{
			kind        = .Existing_Array,
			new_idx     = new_idx,
			depth       = depth,
			cur         = int(old_idx) + 1,
			hi          = int(old_idx) + int(old_node.n),
			pushed_path = pushed_path,
		}); aerr != nil {
			return aerr
		}
		return nil
	}

	// `.Object`: collect direct members and group repeated keys in O(K) time preserving first-occurrence & doc order.
	groups_mark := len(groups_pool)
	vals_mark := len(vals_pool)
	if gerr := group_object_members(doc, old_idx, groups_pool, vals_pool, gs); gerr != nil {
		return gerr
	}
	if _, aerr := append(frames, Norm_Frame{
		kind        = .Object,
		new_idx     = new_idx,
		depth       = depth,
		cur         = groups_mark,
		hi          = len(groups_pool),
		groups_mark = groups_mark,
		vals_mark   = vals_mark,
		pushed_path = pushed_path,
	}); aerr != nil {
		return aerr
	}
	return nil
}

// Closes container frame `f`, writing its final `.n` and `.spelling` child count and recording saturation if needed.
@(private = "file")
finish_container :: proc(
	new_nodes: ^[dynamic]tape.Node,
	f: Norm_Frame,
	sat_counts: ^[dynamic]tape.Child_Count,
) -> runtime.Allocator_Error {
	node := &new_nodes[f.new_idx]
	node.n = u32(len(new_nodes) - int(f.new_idx))
	style := node.spelling & (tape.CONTAINER_STYLE | tape.CONTAINER_PARTIAL)
	node.spelling = style | u16(min(f.child_count, u32(tape.MAX_CHILDREN)))
	if f.child_count >= u32(tape.MAX_CHILDREN) {
		_, err := append(sat_counts, tape.Child_Count{node = f.new_idx, count = f.child_count})
		return err
	}
	return nil
}

// Scans direct members of `old_obj` and appends deduplicated groups to `groups_pool` and their values to `vals_pool`.
@(private = "file")
group_object_members :: proc(
	doc: ^tape.Document,
	old_obj: tape.Node_Index,
	groups_pool: ^[dynamic]Member_Group,
	vals_pool: ^[dynamic]tape.Node_Index,
	gs: ^Group_Scratch,
) -> runtime.Allocator_Error {
	old_nodes := doc.nodes
	end := old_obj + tape.Node_Index(old_nodes[old_obj].n)

	clear(&gs.raw_members)
	for k := old_obj + 1; k < end; {
		v := k + 1
		next_k := tape.node_after(doc, v)
		append(&gs.raw_members, Raw_Member{key = k, val = v}) or_return
		k = next_k
	}

	k_cnt := len(gs.raw_members)
	if k_cnt == 0 {
		return nil
	}
	if k_cnt == 1 {
		m := gs.raw_members[0]
		v_lo := len(vals_pool)
		append(vals_pool, m.val) or_return
		append(groups_pool, Member_Group{first_key = m.key, vals_lo = v_lo, vals_hi = v_lo + 1}) or_return
		return nil
	}

	// Compute key hashes once.
	for &m in gs.raw_members {
		m.hash = norm_key_hash(doc, old_nodes[m.key], &gs.key_a) or_return
	}

	// Prepare per-member occurrence linked list and open-addressing group table.
	resize(&gs.next_occ, k_cnt) or_return
	for i in 0 ..< k_cnt {
		gs.next_occ[i] = -1
	}

	table_len := 16
	for table_len < k_cnt * 2 {
		table_len *= 2
	}
	resize(&gs.slots, table_len) or_return
	slice.zero(gs.slots[:table_len])
	mask := u32(table_len - 1)

	groups_start := len(groups_pool)
	// Reuse `vals_lo` / `vals_hi` temporarily as linked-list head / tail indices into `raw_members`.
	for i in 0 ..< k_cnt {
		m := gs.raw_members[i]
		slot := m.hash & mask
		found_g := -1
		for {
			entry := gs.slots[slot]
			if entry == 0 {
				break
			}
			g_idx := groups_start + int(entry - 1)
			g := &groups_pool[g_idx]
			if g.hash == m.hash {
				eq, eq_err := norm_same_key(doc, old_nodes[g.first_key], old_nodes[m.key], &gs.key_a, &gs.key_b)
				if eq_err != nil {
					return eq_err
				}
				if eq {
					found_g = g_idx
					break
				}
			}
			slot = (slot + 1) & mask
		}
		if found_g >= 0 {
			g := &groups_pool[found_g]
			gs.next_occ[g.vals_hi] = i32(i)
			g.vals_hi = i
		} else {
			new_g := len(groups_pool) - groups_start
			append(groups_pool, Member_Group{
				first_key = m.key,
				vals_lo   = i,
				vals_hi   = i,
				hash      = m.hash,
			}) or_return
			gs.slots[slot] = u32(new_g + 1)
		}
	}

	// Flatten each group's occurrence list into `vals_pool` in document order.
	for gi in groups_start ..< len(groups_pool) {
		g := &groups_pool[gi]
		head := g.vals_lo
		v_lo := len(vals_pool)
		for cur := head; cur >= 0; cur = int(gs.next_occ[cur]) {
			append(vals_pool, gs.raw_members[cur].val) or_return
		}
		g.vals_lo = v_lo
		g.vals_hi = len(vals_pool)
	}
	return nil
}

@(private = "file")
norm_key_text :: proc(doc: ^tape.Document, k: tape.Node, buf: ^[dynamic]u8) -> (s: string, err: runtime.Allocator_Error) {
	if tape.is_text_key(k) {
		return tape.TEXT_KEY, nil
	}
	if k.spelling & tape.SPELLING_DECODE == 0 && (doc.format == nil || doc.format == &FORMATS[.Xml] || k.kind != .Number) {
		return string(tape.span_bytes(doc, k.lo, k.n)), nil
	}
	need := max(tape.text_room(doc, k), int(k.n))
	resize(buf, need) or_return
	decoded, ok := tape.node_text(doc, k, buf[:])
	if !ok {
		return string(tape.span_bytes(doc, k.lo, k.n)), nil
	}
	return decoded, nil
}

@(private = "file")
norm_key_hash :: proc(doc: ^tape.Document, k: tape.Node, buf: ^[dynamic]u8) -> (h: u32, err: runtime.Allocator_Error) {
	s := norm_key_text(doc, k, buf) or_return
	return tape.text_hash(transmute([]u8)s), nil
}

@(private = "file")
norm_same_key :: proc(doc: ^tape.Document, a, b: tape.Node, buf_a, buf_b: ^[dynamic]u8) -> (same: bool, err: runtime.Allocator_Error) {
	sa := norm_key_text(doc, a, buf_a) or_return
	sb := norm_key_text(doc, b, buf_b) or_return
	return sa == sb, nil
}

@(private = "file")
push_path_key :: proc(
	doc: ^tape.Document,
	k: tape.Node,
	path_text: ^[dynamic]u8,
	path_spans: ^[dynamic]Path_Span,
) -> runtime.Allocator_Error {
	lo := len(path_text)
	if tape.is_text_key(k) {
		append(path_text, tape.TEXT_KEY) or_return
	} else if k.spelling & tape.SPELLING_DECODE == 0 {
		span := tape.span_bytes(doc, k.lo, k.n)
		append(path_text, ..span) or_return
	} else {
		need := max(tape.text_room(doc, k), int(k.n))
		resize(path_text, lo + need) or_return
		decoded, ok := tape.node_text(doc, k, path_text[lo:])
		if ok {
			copy(path_text[lo:], decoded)
			resize(path_text, lo + len(decoded)) or_return
		} else {
			resize(path_text, lo) or_return
			append(path_text, ..tape.span_bytes(doc, k.lo, k.n)) or_return
		}
	}
	append(path_spans, Path_Span{lo = lo, hi = len(path_text)}) or_return
	return nil
}

@(private = "file")
pop_path :: proc(path_text: ^[dynamic]u8, path_spans: ^[dynamic]Path_Span) {
	if len(path_spans) == 0 {
		return
	}
	sp := pop(path_spans)
	resize(path_text, sp.lo)
}

@(private = "file")
materialize_path :: proc(path_text: []u8, path_spans: []Path_Span, out: ^[dynamic]string) -> runtime.Allocator_Error {
	resize(out, len(path_spans)) or_return
	for sp, i in path_spans {
		out[i] = string(path_text[sp.lo:sp.hi])
	}
	return nil
}

// Rebuilds `Markup_Ext` namespace scopes and decoded URIs for `new_nodes`/`new_facts` without mutating `doc`.
@(private = "file")
rebuild_markup_ext :: proc(
	doc: ^tape.Document,
	new_nodes: []tape.Node,
	new_facts: []tape.Fact,
	old_m: tape.Markup_Ext,
	doc_alloc: runtime.Allocator,
	scratch: runtime.Allocator,
) -> (ext: ^tape.Doc_Ext, err: runtime.Allocator_Error) {
	first := len(new_facts)
	for f, i in new_facts {
		if f.kind == .Attribute && f.spelling & ATTRIBUTE_NS != 0 {
			first = i
			break
		}
	}
	n, m_cnt := 0, 0
	last := tape.NO_NODE
	for f in new_facts[first:] {
		if f.kind == .Attribute && f.spelling & ATTRIBUTE_NS != 0 {
			if f.node != last {
				n, last = n + 1, f.node
			}
			m_cnt += 1
		}
	}
	scopes := make([]tape.Markup_Scope, n, scratch) or_return
	defer delete(scopes, scratch)
	uris := make([]tape.Markup_Uri, m_cnt, scratch) or_return
	defer delete(uris, scratch)
	text := make([dynamic]u8, scratch)
	defer delete(text)

	k, d := 0, 0
	last = tape.NO_NODE
	for f, j in new_facts[first:] {
		if f.kind != .Attribute || f.spelling & ATTRIBUTE_NS == 0 {
			continue
		}
		if _, value := attribute(doc, f); value.spelling & tape.SPELLING_DECODE != 0 {
			w := len(text)
			resize(&text, w + tape.text_room(doc, value)) or_return
			uri, decodes := tape.node_text(doc, value, text[w:])
			at := intrinsics.ptr_sub(raw_data(uri), raw_data(text)) if decodes && len(uri) > 0 else 0
			uris[d] = {fact = u32(first + j), n = u32(len(uri)) if decodes else 0, lo = u64(at)}
			d += 1
		}
		if f.node == last {
			continue
		}
		last = f.node
		end := f.node + (tape.Node_Index(new_nodes[f.node].n) if new_nodes[f.node].kind == .Object else 1)
		parent := u32(k) - 1 if k > 0 else tape.NO_SCOPE
		for parent != tape.NO_SCOPE && scopes[parent].end <= f.node {
			parent = scopes[parent].parent
		}
		scopes[k] = {node = f.node, end = end, parent = parent}
		k += 1
	}

	kept := tape.Markup_Ext {
		scopes   = scopes,
		uris     = uris[:d],
		uri_text = text[:],
		dtd      = old_m.dtd,
		whole    = old_m.whole,
	}
	ext = tape.ext_make(doc.ext.held, kept, doc_alloc, doc.ext.origin) or_return
	return ext, nil
}
