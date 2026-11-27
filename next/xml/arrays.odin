package xml

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
// All `tape.Document` invariants are preserved. On any error (including OOM), `doc` is left untouched and leak-free.
@(require_results)
normalize_arrays :: proc(
	doc: ^tape.Document,
	mode: tape.Xml_Arrays,
	pred: Array_Predicate = nil,
	pred_ctx: rawptr = nil,
	allocator := context.allocator,
	budget := tape.Budget{},
) -> (err: tape.Error) {
	if mode > max(tape.Xml_Arrays) { return tape.Bad_Option{"format"} }
	if mode == .Auto { return nil }
	if doc == nil || .Borrowed in doc.flags || doc.partial != nil { return tape.Bad_Option{"document"} }
	if doc.format == nil || doc.format.options != .Xml { return tape.Bad_Option{"format"} }
	if len(doc.nodes) == 0 || doc.nodes[0].kind <= .Plain { return nil }

	node_limit := u64(budget.nodes) if budget.nodes > 0 else u64(tape.NO_NODE) - 1
	doc_alloc := doc.allocator if doc.allocator.procedure != nil else allocator
	scratch := allocator

	rb: hook.Read_Budget
	eff_doc_alloc, eff_scratch := doc_alloc, scratch
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

	st := Norm_State{doc = doc, node_limit = node_limit}
	init_cap := min(len(old_nodes), int(min(node_limit, u64(max(int)))))
	st.new_nodes = make([dynamic]tape.Node, 0, init_cap, eff_doc_alloc) or_return
	committed := false
	defer if !committed { delete(st.new_nodes) }

	st.old_to_new = make([]tape.Node_Index, len(old_nodes), eff_scratch) or_return
	defer delete(st.old_to_new, eff_scratch)
	slice.fill(st.old_to_new, tape.NO_NODE)

	st.frames.allocator = eff_scratch
	st.groups_pool.allocator = eff_scratch
	st.vals_pool.allocator = eff_scratch
	st.sat_counts.allocator = eff_scratch
	st.gs.raw_members.allocator = eff_scratch
	st.gs.next_occ.allocator = eff_scratch
	st.gs.slots.allocator = eff_scratch
	st.gs.key_a.allocator = eff_scratch
	st.gs.key_b.allocator = eff_scratch
	defer {
		delete(st.frames)
		delete(st.groups_pool)
		delete(st.vals_pool)
		delete(st.sat_counts)
		delete(st.gs.raw_members)
		delete(st.gs.next_occ)
		delete(st.gs.slots)
		delete(st.gs.key_a)
		delete(st.gs.key_b)
	}

	path_text: [dynamic]u8
	path_spans: [dynamic]Path_Span
	path_strs: [dynamic]string
	path_text.allocator, path_spans.allocator, path_strs.allocator = eff_scratch, eff_scratch, eff_scratch
	defer {
		delete(path_text)
		delete(path_spans)
		delete(path_strs)
	}

	push_container(&st, tape.ROOT, 0, false) or_return

	for len(st.frames) > 0 {
		f := &st.frames[len(st.frames) - 1]
		if f.cur >= f.hi {
			finished := pop(&st.frames)
			finish_container(&st, finished) or_return
			if finished.kind == .Object {
				resize(&st.groups_pool, finished.groups_mark)
				resize(&st.vals_pool, finished.vals_mark)
			}
			if finished.pushed_path {
				pop_path(&path_text, &path_spans)
			}
			continue
		}

		switch f.kind {
		case .Object:
			g := st.groups_pool[f.cur]
			f.cur += 1
			f.child_count += 1
			obj_depth := f.depth

			key_node := old_nodes[g.first_key]
			_ = emit_node(&st, g.first_key, key_node) or_return

			is_text := tape.is_text_key(key_node)
			pushed_seg := false
			if need_path && !is_text {
				push_path_key(doc, key_node, &st.gs.key_a, &path_text, &path_spans) or_return
				pushed_seg = true
			}

			first_val_idx := st.vals_pool[g.vals_lo]
			first_val_node := old_nodes[first_val_idx]
			should_wrap := g.vals_hi - g.vals_lo >= 2
			if !should_wrap && !is_text && first_val_node.kind != .Array {
				#partial switch mode {
				case .Always:
					should_wrap = obj_depth >= 1
				case .Schema:
					if pred != nil {
						materialize_path(path_text[:], path_spans[:], &path_strs) or_return
						should_wrap = pred(pred_ctx, path_strs[:])
					}
				}
			}

			if should_wrap {
				arr_idx := emit_node(&st, tape.NO_NODE, tape.Node{lo = first_val_node.lo, kind = .Array, role = .Value}) or_return
				append(&st.frames, Norm_Frame{
					kind        = .Synth_Array,
					new_idx     = arr_idx,
					depth       = obj_depth + 1,
					cur         = g.vals_lo,
					hi          = g.vals_hi,
					pushed_path = pushed_seg,
				}) or_return
			} else {
				emit_value(&st, first_val_idx, obj_depth + 1, pushed_seg, &path_text, &path_spans) or_return
			}

		case .Synth_Array, .Existing_Array:
			v_old: tape.Node_Index
			if f.kind == .Synth_Array {
				v_old = st.vals_pool[f.cur]
				f.cur += 1
			} else {
				v_old = tape.Node_Index(f.cur)
				f.cur = int(tape.node_after(doc, v_old))
			}
			f.child_count += 1
			emit_value(&st, v_old, f.depth, false, &path_text, &path_spans) or_return
		}
	}

	// Build remapped & `(node, source order)`-sorted `facts`.
	new_facts: []tape.Fact
	defer if !committed { delete(new_facts, eff_doc_alloc) }
	if len(doc.facts) > 0 {
		entries := make([dynamic]Remapped_Fact, 0, len(doc.facts), eff_scratch) or_return
		defer delete(entries)
		needs_sort := false
		prev_node := tape.Node_Index(0)
		for f, orig_i in doc.facts {
			if int(f.node) >= len(st.old_to_new) { continue }
			mapped := st.old_to_new[f.node]
			if mapped == tape.NO_NODE { continue }
			nf := f
			nf.node = mapped
			if len(entries) > 0 && mapped < prev_node { needs_sort = true }
			prev_node = mapped
			append(&entries, Remapped_Fact{fact = nf, order = u32(orig_i)}) or_return
		}
		if len(entries) > 0 {
			if needs_sort {
				slice.sort_by(entries[:], proc(a, b: Remapped_Fact) -> bool {
					return a.fact.node < b.fact.node || (a.fact.node == b.fact.node && a.order < b.order)
				})
			}
			nf_slice := make([]tape.Fact, len(entries), eff_doc_alloc) or_return
			if raw_data(nf_slice) == nil { return runtime.Allocator_Error.Out_Of_Memory }
			for e, idx in entries { nf_slice[idx] = e.fact }
			new_facts = nf_slice
		}
	}

	// Build sorted `counts` for containers whose `spelling` saturated at `MAX_CHILDREN`.
	new_counts: []tape.Child_Count
	defer if !committed { delete(new_counts, eff_doc_alloc) }
	if len(st.sat_counts) > 0 {
		slice.sort_by(st.sat_counts[:], proc(a, b: tape.Child_Count) -> bool { return a.node < b.node })
		nc_slice := make([]tape.Child_Count, len(st.sat_counts), eff_doc_alloc) or_return
		if raw_data(nc_slice) == nil { return runtime.Allocator_Error.Out_Of_Memory }
		copy(nc_slice, st.sat_counts[:])
		new_counts = nc_slice
	}

	// Rebuild `Markup_Ext` namespace scopes/URIs when namespace declarations are present.
	new_ext: ^tape.Doc_Ext
	defer if !committed && new_ext != nil { free(new_ext, eff_doc_alloc) }
	if doc.ext != nil {
		if m, ok := doc.ext.format.(tape.Markup_Ext); ok && len(m.scopes) > 0 {
			new_ext = build_markup_ext(doc, st.new_nodes[:], new_facts, m.whole, true, m.dtd, doc.ext.held, doc.ext.origin, eff_doc_alloc, eff_scratch) or_return
		}
	}

	// Commit atomically: release old slices using `doc_alloc` (or unmap if OS-reserved) and install the new ones.
	if .Mapped_Nodes in doc.flags {
		tape.nodes_unmap(doc.nodes)
		doc.flags -= {.Mapped_Nodes}
	} else {
		free(raw_data(doc.nodes), doc_alloc)
	}
	free(raw_data(doc.facts), doc_alloc)
	free(raw_data(doc.counts), doc_alloc)
	doc.nodes, doc.facts, doc.counts = st.new_nodes[:], new_facts, new_counts
	if new_ext != nil {
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
Frame_Kind :: enum u8 { Object, Synth_Array, Existing_Array }

@(private = "file")
Norm_Frame :: struct {
	kind:        Frame_Kind,
	new_idx:     tape.Node_Index,
	depth:       int,
	cur, hi:     int,
	groups_mark: int,
	vals_mark:   int,
	child_count: u32,
	pushed_path: bool,
}

@(private = "file")
Member_Group :: struct {
	first_key:        tape.Node_Index,
	vals_lo, vals_hi: int,
	hash:             u32,
}

@(private = "file")
Raw_Member :: struct {
	key, val: tape.Node_Index,
	hash:     u32,
}

@(private = "file")
Group_Scratch :: struct {
	raw_members:  [dynamic]Raw_Member,
	next_occ:     [dynamic]i32,
	slots:        [dynamic]u32,
	key_a, key_b: [dynamic]u8,
}

@(private = "file")
Norm_State :: struct {
	doc:         ^tape.Document,
	node_limit:  u64,
	new_nodes:   [dynamic]tape.Node,
	old_to_new:  []tape.Node_Index,
	frames:      [dynamic]Norm_Frame,
	groups_pool: [dynamic]Member_Group,
	vals_pool:   [dynamic]tape.Node_Index,
	sat_counts:  [dynamic]tape.Child_Count,
	gs:          Group_Scratch,
}

@(private = "file")
Path_Span :: struct { lo, hi: int }

@(private = "file")
Remapped_Fact :: struct { fact: tape.Fact, order: u32 }

@(private = "file")
emit_node :: proc(st: ^Norm_State, old_idx: tape.Node_Index, node: tape.Node) -> (idx: tape.Node_Index, err: tape.Error) {
	if u64(len(st.new_nodes)) >= st.node_limit {
		return tape.NO_NODE, tape.Exceeded{kind = .Nodes, at = tape.NO_BYTE}
	}
	idx = tape.Node_Index(len(st.new_nodes))
	append(&st.new_nodes, node) or_return
	if old_idx != tape.NO_NODE {
		st.old_to_new[old_idx] = idx
	}
	return idx, nil
}

@(private = "file")
emit_value :: proc(st: ^Norm_State, old_idx: tape.Node_Index, depth: int, pushed_path: bool, path_text: ^[dynamic]u8, path_spans: ^[dynamic]Path_Span) -> tape.Error {
	node := st.doc.nodes[old_idx]
	if node.kind <= .Plain {
		_ = emit_node(st, old_idx, node) or_return
		if pushed_path {
			pop_path(path_text, path_spans)
		}
		return nil
	}
	return push_container(st, old_idx, depth, pushed_path)
}

// Emits container node `old_idx` into `st.new_nodes`, records `st.old_to_new[old_idx]`, and pushes its traversal frame.
@(private = "file")
push_container :: proc(st: ^Norm_State, old_idx: tape.Node_Index, depth: int, pushed_path: bool) -> tape.Error {
	old_node := st.doc.nodes[old_idx]
	new_idx := emit_node(st, old_idx, old_node) or_return
	if old_node.kind == .Array {
		append(&st.frames, Norm_Frame{
			kind        = .Existing_Array,
			new_idx     = new_idx,
			depth       = depth,
			cur         = int(old_idx) + 1,
			hi          = int(old_idx) + int(old_node.n),
			pushed_path = pushed_path,
		}) or_return
		return nil
	}
	groups_mark, vals_mark := len(st.groups_pool), len(st.vals_pool)
	group_object_members(st.doc, old_idx, &st.groups_pool, &st.vals_pool, &st.gs) or_return
	append(&st.frames, Norm_Frame{
		kind        = .Object,
		new_idx     = new_idx,
		depth       = depth,
		cur         = groups_mark,
		hi          = len(st.groups_pool),
		groups_mark = groups_mark,
		vals_mark   = vals_mark,
		pushed_path = pushed_path,
	}) or_return
	return nil
}

// Closes container frame `f`, writing its final `.n` and `.spelling` child count and recording saturation if needed.
@(private = "file")
finish_container :: proc(st: ^Norm_State, f: Norm_Frame) -> runtime.Allocator_Error {
	node := &st.new_nodes[f.new_idx]
	node.n = u32(len(st.new_nodes) - int(f.new_idx))
	style := node.spelling & (tape.CONTAINER_STYLE | tape.CONTAINER_PARTIAL)
	node.spelling = style | u16(min(f.child_count, u32(tape.MAX_CHILDREN)))
	if f.child_count >= u32(tape.MAX_CHILDREN) {
		append(&st.sat_counts, tape.Child_Count{node = f.new_idx, count = f.child_count}) or_return
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
	if k_cnt == 0 { return nil }
	if k_cnt == 1 {
		m := gs.raw_members[0]
		v_lo := len(vals_pool)
		append(vals_pool, m.val) or_return
		append(groups_pool, Member_Group{first_key = m.key, vals_lo = v_lo, vals_hi = v_lo + 1}) or_return
		return nil
	}

	for &m in gs.raw_members {
		s := norm_key_text(doc, old_nodes[m.key], &gs.key_a) or_return
		m.hash = tape.text_hash(transmute([]u8)s)
	}

	resize(&gs.next_occ, k_cnt) or_return
	slice.fill(gs.next_occ[:k_cnt], -1)

	table_len := 16
	for table_len < k_cnt * 2 { table_len *= 2 }
	resize(&gs.slots, table_len) or_return
	slice.zero(gs.slots[:table_len])
	mask := u32(table_len - 1)

	groups_start := len(groups_pool)
	// Reuse `vals_lo` / `vals_hi` temporarily as linked-list head / tail indices into `raw_members`.
	for i in 0 ..< k_cnt {
		m := gs.raw_members[i]
		slot := m.hash & mask
		found_g := -1
		for entry := gs.slots[slot]; entry != 0; entry = gs.slots[slot] {
			g_idx := groups_start + int(entry - 1)
			g := &groups_pool[g_idx]
			if g.hash == m.hash {
				sa := norm_key_text(doc, old_nodes[g.first_key], &gs.key_a) or_return
				sb := norm_key_text(doc, old_nodes[m.key], &gs.key_b) or_return
				if sa == sb {
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
			append(groups_pool, Member_Group{first_key = m.key, vals_lo = i, vals_hi = i, hash = m.hash}) or_return
			gs.slots[slot] = u32(new_g + 1)
		}
	}

	for gi in groups_start ..< len(groups_pool) {
		g := &groups_pool[gi]
		v_lo := len(vals_pool)
		for cur := g.vals_lo; cur >= 0; cur = int(gs.next_occ[cur]) {
			append(vals_pool, gs.raw_members[cur].val) or_return
		}
		g.vals_lo, g.vals_hi = v_lo, len(vals_pool)
	}
	return nil
}

@(private = "file")
norm_key_text :: proc(doc: ^tape.Document, k: tape.Node, buf: ^[dynamic]u8) -> (s: string, err: runtime.Allocator_Error) {
	if tape.is_text_key(k) { return tape.TEXT_KEY, nil }
	if k.spelling & tape.SPELLING_DECODE == 0 && (doc.format == nil || doc.format == &FORMATS[.Xml] || k.kind != .Number) {
		return string(tape.span_bytes(doc, k.lo, k.n)), nil
	}
	need := max(tape.text_room(doc, k), int(k.n))
	resize(buf, need) or_return
	decoded, ok := tape.node_text(doc, k, buf[:])
	return decoded if ok else string(tape.span_bytes(doc, k.lo, k.n)), nil
}

@(private = "file")
push_path_key :: proc(doc: ^tape.Document, k: tape.Node, tmp: ^[dynamic]u8, path_text: ^[dynamic]u8, path_spans: ^[dynamic]Path_Span) -> runtime.Allocator_Error {
	lo := len(path_text)
	s := norm_key_text(doc, k, tmp) or_return
	append(path_text, s) or_return
	append(path_spans, Path_Span{lo = lo, hi = len(path_text)}) or_return
	return nil
}

@(private = "file")
pop_path :: proc(path_text: ^[dynamic]u8, path_spans: ^[dynamic]Path_Span) {
	if len(path_spans) > 0 {
		resize(path_text, pop(path_spans).lo)
	}
}

@(private = "file")
materialize_path :: proc(path_text: []u8, path_spans: []Path_Span, out: ^[dynamic]string) -> runtime.Allocator_Error {
	resize(out, len(path_spans)) or_return
	for sp, i in path_spans {
		out[i] = string(path_text[sp.lo:sp.hi])
	}
	return nil
}
