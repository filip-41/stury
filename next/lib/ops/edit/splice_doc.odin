package edit

import "base:runtime"
import "stury:lib/core/tape"

// `walk_fragment` incremental tape splice (`splice_document`).

shift_fragment_tape :: proc(d: ^tape.Document, base_lo: u64, strip_nodes: int, strip_bytes: u64, allocator: runtime.Allocator) -> (ft: Fragment_Tape, err: runtime.Allocator_Error) {
	if strip_nodes == 0 && strip_bytes == 0 {
		for &n in d.nodes { n.lo += base_lo }
		for &f in d.facts { f.lo += base_lo }
		ft = {d.nodes, d.facts, d.counts, d.present, d.root_close + base_lo, nil, allocator}
		free(d.ext, allocator)
		free(d.partial, allocator)
		d^ = {}
		return ft, nil
	}
	defer tape.destroy_document(d)
	if len(d.nodes) <= strip_nodes { return {}, nil }
	sub := d.nodes[strip_nodes:]
	out_nodes := make([]tape.Node, len(sub), allocator) or_return
	defer if err != nil { delete(out_nodes, allocator) }
	for n, i in sub {
		shifted := n
		if shifted.lo >= strip_bytes { shifted.lo = shifted.lo - strip_bytes + base_lo }
		out_nodes[i] = shifted
	}
	out_facts := make([dynamic]tape.Fact, 0, len(d.facts), allocator)
	defer if err != nil { delete(out_facts) }
	for f in d.facts {
		if int(f.node) >= strip_nodes {
			sf := f
			sf.node -= tape.Node_Index(strip_nodes)
			if sf.lo >= strip_bytes { sf.lo = sf.lo - strip_bytes + base_lo }
			append(&out_facts, sf) or_return
		}
	}
	out_counts := make([dynamic]tape.Child_Count, 0, len(d.counts), allocator)
	defer if err != nil { delete(out_counts) }
	for cc in d.counts {
		if int(cc.node) >= strip_nodes {
			sc := cc
			sc.node -= tape.Node_Index(strip_nodes)
			append(&out_counts, sc) or_return
		}
	}
	return Fragment_Tape{out_nodes, out_facts[:], out_counts[:], d.present, (d.root_close - strip_bytes + base_lo) if d.root_close >= strip_bytes else base_lo, nil, allocator}, nil
}

@(private = "file")
check_depth_budget :: proc(nodes: []tape.Node, max_depth: u32, at: u64, allocator: runtime.Allocator) -> Error {
	if max_depth == 0 { return nil }
	if (frag_max_depth(nodes, allocator) or_return) > max_depth { return tape.Exceeded{kind = .Depth, at = at} }
	return nil
}

splice_document :: proc(base: ^tape.Document, res: ^Commit_Result, opts: Options, walker: Fragment_Walker, walker_data: rawptr, full_build: Full_Builder, full_data: rawptr, allocator := context.allocator) -> (doc: tape.Document, err: Error) {
	if base == nil || len(base.nodes) == 0 { return {}, refuse(.No_Document, "splice_document requires a built base document") }
	if base.partial != nil { return {}, refuse(.Partial_Document, "cannot splice a partial document") }
	new_src := res.bytes

	if len(res.splices) == 0 {
		if opts.target != nil && opts.target != base.format { return fallback_full_build(new_src, opts, full_build, full_data, allocator) }
		cloned := tape.clone_document(base, allocator) or_return
		if .Owns_Src in cloned.flags {
			delete(cloned.src, cloned.allocator)
			cloned.flags -= {.Owns_Src}
		}
		cloned.src = new_src
		if opts.own_src { cloned.flags += {.Owns_Src} }
		return cloned, nil
	}

	can_incremental := walker != nil && .Held not_in base.flags && (opts.target == nil || opts.target == base.format)
	if can_incremental {
		prev_end, prev_src_hi := tape.Node_Index(0), u64(0)
		for sp in res.splices {
			if sp.full_rewalk || !sp.subtree_only || sp.base_node == tape.NO_NODE || sp.base_node == tape.ROOT || int(sp.base_node) >= len(base.nodes) || sp.base_node < prev_end || sp.src_lo < prev_src_hi {
				can_incremental = false
				break
			}
			bn := base.nodes[sp.base_node]
			prev_end = sp.base_node + (tape.Node_Index(bn.n) if bn.kind >= .Array else 1)
			prev_src_hi = sp.src_hi
		}
	}
	if !can_incremental { return fallback_full_build(new_src, opts, full_build, full_data, allocator) }

	eff_max_depth := opts.budget.depth if opts.budget.depth > 0 else u32(tape.DEFAULT_DEPTH)
	base_depths := make([]u32, len(res.splices), allocator)
	defer delete(base_depths, allocator)
	compute_splice_base_depths(base, res.splices, base_depths, eff_max_depth, allocator) or_return

	frags := make([]Fragment_Tape, len(res.splices), allocator)
	defer {
		for &ft in frags { destroy_fragment_tape(&ft) }
		delete(frags, allocator)
	}

	for sp, i in res.splices {
		ft, ferr := walker(walker_data, new_src, Byte_Range{sp.dst_lo, sp.dst_hi}, Fragment_Context{base, sp.base_node, base_depths[i], opts.budget}, allocator)
		if ferr != nil {
			#partial switch _ in ferr {
			case tape.Exceeded, runtime.Allocator_Error: return {}, convert_tape_error(ferr)
			}
			return fallback_full_build(new_src, opts, full_build, full_data, allocator)
		}
		if full, has_full := ft.full_doc.?; has_full {
			ft.full_doc = nil
			destroy_fragment_tape(&ft)
			if derr := check_depth_budget(full.nodes, opts.budget.depth, sp.dst_lo, allocator); derr != nil {
				tape.destroy_document(&full)
				return {}, derr
			}
			if opts.own_src { full.flags += {.Owns_Src} }
			return full, nil
		}
		if len(ft.nodes) == 0 {
			destroy_fragment_tape(&ft)
			return fallback_full_build(new_src, opts, full_build, full_data, allocator)
		}
		fd, merr := frag_max_depth(ft.nodes, allocator)
		if merr != nil || base_depths[i] + fd > eff_max_depth {
			destroy_fragment_tape(&ft)
			return {}, merr if merr != nil else tape.Exceeded{kind = .Depth, at = sp.dst_lo}
		}
		frags[i] = ft
	}

	spliced, need_full, serr := assemble_spliced_document(base, new_src, res.splices, frags, opts, allocator)
	if need_full { return fallback_full_build(new_src, opts, full_build, full_data, allocator) }
	return spliced, serr
}

@(private = "file")
compute_splice_base_depths :: proc(base: ^tape.Document, splices: []Splice_Record, depths: []u32, max_depth: u32, allocator: runtime.Allocator) -> Error {
	ends := make([dynamic]tape.Node_Index, 0, 32, allocator) or_return
	defer delete(ends)
	nodes, cur := base.nodes, tape.Node_Index(0)
	for sp, i in splices {
		for cur < sp.base_node {
			for len(ends) > 0 && cur >= ends[len(ends) - 1] { pop(&ends) }
			cn := nodes[cur]
			if cn.kind >= .Array && cn.n > 1 && cur + tape.Node_Index(cn.n) > sp.base_node {
				append(&ends, cur + tape.Node_Index(cn.n)) or_return
				cur += 1
			} else {
				cur += tape.Node_Index(cn.n) if cn.kind >= .Array else 1
			}
		}
		for len(ends) > 0 && cur >= ends[len(ends) - 1] { pop(&ends) }
		if u32(len(ends)) > max_depth { return tape.Exceeded{kind = .Depth, at = nodes[sp.base_node].lo} }
		depths[i] = u32(len(ends))
	}
	return nil
}

@(private = "file")
frag_max_depth :: proc(nodes: []tape.Node, allocator: runtime.Allocator) -> (max_d: u32, err: runtime.Allocator_Error) {
	ends := make([dynamic]tape.Node_Index, 0, 16, allocator) or_return
	defer delete(ends)
	for n, i in nodes {
		idx := tape.Node_Index(i)
		for len(ends) > 0 && idx >= ends[len(ends) - 1] { pop(&ends) }
		if n.kind >= .Array {
			max_d = max(max_d, u32(len(ends) + 1))
			if n.n > 1 { append(&ends, idx + tape.Node_Index(n.n)) or_return }
		}
	}
	return max_d, nil
}

@(private = "file")
fallback_full_build :: proc(new_src: []u8, opts: Options, full_build: Full_Builder, full_data: rawptr, allocator: runtime.Allocator) -> (tape.Document, Error) {
	if full_build == nil { return {}, refuse(.Invalid_Result, "full builder required for non-incremental splice") }
	built, berr := full_build(full_data, new_src, allocator)
	if berr != nil { return {}, convert_tape_error(berr) }
	if derr := check_depth_budget(built.nodes, opts.budget.depth, tape.NO_BYTE, allocator); derr != nil {
		tape.destroy_document(&built)
		return {}, derr
	}
	if opts.own_src { built.flags += {.Owns_Src} }
	return built, nil
}

@(private = "file")
Splice_Meta :: struct {
	old_start, old_end, new_start: tape.Node_Index,
	src_lo, src_hi:                u64,
	node_delta, byte_delta:        i64,
}

@(private = "file")
assemble_spliced_document :: proc(base: ^tape.Document, new_src: []u8, splices: []Splice_Record, frags: []Fragment_Tape, opts: Options, allocator: runtime.Allocator) -> (doc: tape.Document, need_full: bool, err: Error) {
	old_nodes := base.nodes
	total_node_delta, total_byte_delta: i64
	any_node_delta := false
	for sp, i in splices {
		bn := old_nodes[sp.base_node]
		nd := i64(len(frags[i].nodes)) - (i64(bn.n) if bn.kind >= .Array else 1)
		total_node_delta += nd
		if nd != 0 { any_node_delta = true }
		total_byte_delta += i64(sp.dst_hi - sp.dst_lo) - i64(sp.src_hi - sp.src_lo)
	}

	new_node_count := int(i64(len(old_nodes)) + total_node_delta)
	if new_node_count <= 0 || u64(new_node_count) >= u64(tape.NO_NODE) {
		return {}, false, refuse(.Invalid_Result, "spliced node count out of range")
	}
	raw_nodes := runtime.mem_alloc_non_zeroed(new_node_count * size_of(tape.Node), align_of(tape.Node), allocator) or_return
	new_nodes := ([^]tape.Node)(raw_data(raw_nodes))[:new_node_count]
	defer if err != nil || need_full { runtime.mem_free(raw_data(new_nodes), allocator) }

	metas := make([]Splice_Meta, len(splices), allocator) or_return
	defer delete(metas, allocator)

	old_pos, new_pos, running_byte_delta := 0, 0, i64(0)
	for sp, i in splices {
		start := int(sp.base_node)
		bn := old_nodes[start]
		old_sub, new_sub := int(bn.n) if bn.kind >= .Array else 1, len(frags[i].nodes)
		if prefix_len := start - old_pos; prefix_len > 0 {
			copy(new_nodes[new_pos : new_pos + prefix_len], old_nodes[old_pos:start])
			if running_byte_delta != 0 { shift_node_offsets(new_nodes[new_pos : new_pos + prefix_len], metas[:i], running_byte_delta) }
			new_pos += prefix_len
		}
		metas[i] = {sp.base_node, sp.base_node + tape.Node_Index(old_sub), tape.Node_Index(new_pos), sp.src_lo, sp.src_hi, i64(new_sub) - i64(old_sub), i64(sp.dst_hi - sp.dst_lo) - i64(sp.src_hi - sp.src_lo)}
		copy(new_nodes[new_pos : new_pos + new_sub], frags[i].nodes)
		new_nodes[new_pos].role = bn.role
		new_pos += new_sub
		old_pos = start + old_sub
		running_byte_delta += metas[i].byte_delta
	}
	if tail_len := len(old_nodes) - old_pos; tail_len > 0 {
		copy(new_nodes[new_pos : new_pos + tail_len], old_nodes[old_pos:])
		if running_byte_delta != 0 { shift_node_offsets(new_nodes[new_pos : new_pos + tail_len], metas, running_byte_delta) }
	}
	if any_node_delta { patch_ancestor_counts(new_nodes, metas) }

	new_facts, present, facts_spliced := assemble_spliced_facts(base.facts, frags, metas, allocator) or_return
	defer if (err != nil || need_full) && new_facts != nil { runtime.mem_free(raw_data(new_facts), allocator) }

	new_counts := assemble_spliced_counts(base.counts, frags, metas, allocator) or_return
	defer if (err != nil || need_full) && new_counts != nil { runtime.mem_free(raw_data(new_counts), allocator) }

	new_ext: ^tape.Doc_Ext
	if base.ext != nil {
		ext_ok: bool
		new_ext, ext_ok = clone_shifted_ext(base.ext, metas, facts_spliced, allocator) or_return
		if !ext_ok { return {}, true, nil }
	}

	flags := base.flags - {.Owns_Src}
	if opts.own_src { flags += {.Owns_Src} }
	return tape.Document {
		src = new_src, nodes = new_nodes, facts = new_facts, counts = new_counts,
		format = opts.target if opts.target != nil else base.format, ext = new_ext,
		root_close = u64(i64(base.root_close) + total_byte_delta), present = present, flags = flags, allocator = allocator,
	}, false, nil
}

@(private = "file")
shift_byte_offset :: #force_inline proc "contextless" (old_lo: u64, prev_metas: []Splice_Meta) -> u64 #no_bounds_check {
	delta := i64(0)
	for m in prev_metas {
		if m.src_hi <= old_lo { delta += m.byte_delta } else { break }
	}
	return u64(i64(old_lo) + delta)
}

@(private = "file")
shift_lo_fast :: #force_inline proc "contextless" (lo: u64, prev_metas: []Splice_Meta, running_byte_delta: i64) -> u64 #no_bounds_check {
	if len(prev_metas) == 0 { return lo }
	return u64(i64(lo) + running_byte_delta) if lo >= prev_metas[len(prev_metas) - 1].src_hi else shift_byte_offset(lo, prev_metas)
}

@(private = "file")
shift_node_offsets :: proc "contextless" (nodes: []tape.Node, prev_metas: []Splice_Meta, total_delta: i64) #no_bounds_check {
	if len(prev_metas) == 0 { return }
	for &nd in nodes { nd.lo = shift_lo_fast(nd.lo, prev_metas, total_delta) }
}

@(private = "file")
patch_ancestor_counts :: proc "contextless" (new_nodes: []tape.Node, metas: []Splice_Meta) #no_bounds_check {
	n_metas, old_idx, new_idx, mi := len(metas), tape.Node_Index(0), tape.Node_Index(0), 0
	for int(new_idx) < len(new_nodes) {
		if mi < n_metas && new_idx == metas[mi].new_start {
			old_idx = metas[mi].old_end
			new_idx += tape.Node_Index(i64(metas[mi].old_end - metas[mi].old_start) + metas[mi].node_delta)
			mi += 1
			continue
		}
		nd := &new_nodes[new_idx]
		if nd.kind >= .Array && nd.n > 1 {
			old_end := old_idx + tape.Node_Index(nd.n)
			if mi >= n_metas || old_end <= metas[mi].old_start {
				old_idx, new_idx = old_end, new_idx + tape.Node_Index(nd.n)
				continue
			}
			delta := i64(0)
			for j := mi; j < n_metas && metas[j].old_start < old_end; j += 1 { delta += metas[j].node_delta }
			nd.n = u32(i64(nd.n) + delta)
		}
		old_idx += 1
		new_idx += 1
	}
}

@(private = "file")
assemble_spliced_facts :: proc(old_facts: []tape.Fact, frags: []Fragment_Tape, metas: []Splice_Meta, allocator: runtime.Allocator) -> (out: []tape.Fact, present: tape.Facts, facts_spliced: bool, err: runtime.Allocator_Error) {
	est := len(old_facts)
	for ft in frags { est += len(ft.facts) }
	if est == 0 { return nil, {}, false, nil }
	buf := make([dynamic]tape.Fact, 0, est, allocator)
	defer delete(buf)
	after_buf := make([dynamic]tape.Fact, 0, 4, allocator)
	defer delete(after_buf)

	fi, running_node_delta, running_byte_delta := 0, i64(0), i64(0)
	copy_before :: proc(old_facts: []tape.Fact, fi: ^int, stop: tape.Node_Index, prev_metas: []Splice_Meta, nd, bd: i64, buf: ^[dynamic]tape.Fact, present: ^tape.Facts) -> runtime.Allocator_Error {
		for fi^ < len(old_facts) && old_facts[fi^].node < stop {
			f := old_facts[fi^]
			f.node = tape.Node_Index(i64(f.node) + nd)
			f.lo = shift_lo_fast(f.lo, prev_metas, bd)
			append(buf, f) or_return
			present^ += {f.kind}
			fi^ += 1
		}
		return nil
	}

	for m, si in metas {
		copy_before(old_facts, &fi, m.old_start, metas[:si], running_node_delta, running_byte_delta, &buf, &present) or_return
		clear(&after_buf)
		for fi < len(old_facts) && old_facts[fi].node < m.old_end {
			f := old_facts[fi]
			fi += 1
			if f.node != m.old_start || (f.lo >= m.src_lo && f.lo < m.src_hi) {
				facts_spliced = true
				continue
			}
			dup := false
			for ff in frags[si].facts {
				if ff.node == 0 && ff.kind == f.kind && f.kind != .Attribute {
					dup = true
					break
				}
			}
			if dup {
				facts_spliced = true
				continue
			}
			before := f.lo < m.src_lo
			f.node, f.lo = m.new_start, shift_byte_offset(f.lo, metas[:si])
			if before {
				append(&buf, f) or_return
				present += {f.kind}
			} else {
				f.lo = u64(i64(f.lo) + m.byte_delta)
				append(&after_buf, f) or_return
			}
		}
		if len(frags[si].facts) > 0 { facts_spliced = true }
		for ff in frags[si].facts {
			f := ff
			f.node += m.new_start
			append(&buf, f) or_return
			present += {f.kind}
		}
		for af in after_buf {
			append(&buf, af) or_return
			present += {af.kind}
		}
		present += frags[si].present
		running_node_delta += m.node_delta
		running_byte_delta += m.byte_delta
	}
	copy_before(old_facts, &fi, tape.NO_NODE, metas, running_node_delta, running_byte_delta, &buf, &present) or_return
	out = alloc_exact_slice(buf[:], allocator) or_return
	return out, present, facts_spliced, nil
}

@(private = "file")
assemble_spliced_counts :: proc(old_counts: []tape.Child_Count, frags: []Fragment_Tape, metas: []Splice_Meta, allocator: runtime.Allocator) -> (out: []tape.Child_Count, err: runtime.Allocator_Error) {
	est := len(old_counts)
	for ft in frags { est += len(ft.counts) }
	if est == 0 { return nil, nil }
	buf := make([dynamic]tape.Child_Count, 0, est, allocator)
	defer delete(buf)
	ci, running_node_delta := 0, i64(0)
	copy_counts :: proc(old_counts: []tape.Child_Count, ci: ^int, stop: tape.Node_Index, nd: i64, buf: ^[dynamic]tape.Child_Count) -> runtime.Allocator_Error {
		for ci^ < len(old_counts) && old_counts[ci^].node < stop {
			cc := old_counts[ci^]
			cc.node = tape.Node_Index(i64(cc.node) + nd)
			append(buf, cc) or_return
			ci^ += 1
		}
		return nil
	}
	for m, si in metas {
		copy_counts(old_counts, &ci, m.old_start, running_node_delta, &buf) or_return
		for ci < len(old_counts) && old_counts[ci].node < m.old_end { ci += 1 }
		for fc in frags[si].counts {
			cc := fc
			cc.node += m.new_start
			append(&buf, cc) or_return
		}
		running_node_delta += m.node_delta
	}
	copy_counts(old_counts, &ci, tape.NO_NODE, running_node_delta, &buf) or_return
	return alloc_exact_slice(buf[:], allocator)
}

@(private = "file")
clone_shifted_ext :: proc(old_ext: ^tape.Doc_Ext, metas: []Splice_Meta, facts_spliced: bool, allocator: runtime.Allocator) -> (ext: ^tape.Doc_Ext, ok: bool, err: runtime.Allocator_Error) {
	#partial switch f in old_ext.format {
	case tape.Markup_Ext:
		if (len(f.uris) > 0 && facts_spliced) || .In_Place in f.dtd.flags { return nil, false, nil }
		for sc in f.scopes {
			for m in metas { if sc.node >= m.old_start && sc.node < m.old_end { return nil, false, nil } }
		}
	case tape.Tabular_Ext:
		for k in f.keys {
			for m in metas { if m.src_lo < k.lo + u64(k.n) { return nil, false, nil } }
		}
	}
	ext = tape.ext_make(old_ext.held, old_ext.format, allocator, old_ext.origin) or_return
	#partial switch &f in ext.format {
	case tape.Markup_Ext:
		for &sc in f.scopes { sc.node, sc.end = shift_node_idx(sc.node, metas), shift_node_idx(sc.end, metas) }
	case tape.Tabular_Ext:
		for &t in f.tables { t.node, t.first_row = shift_node_idx(t.node, metas), shift_node_idx(t.first_row, metas) }
	}
	return ext, true, nil
}

@(private = "file")
shift_node_idx :: proc "contextless" (idx: tape.Node_Index, metas: []Splice_Meta) -> tape.Node_Index {
	delta := i64(0)
	for m in metas {
		if idx >= m.old_end { delta += m.node_delta } else { break }
	}
	return tape.Node_Index(i64(idx) + delta)
}
