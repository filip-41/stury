package edit

import "base:runtime"
import "stury:lib/core/tape"

// `walk_fragment` incremental tape splice (Roadmap #8 — `splice_document`).
//
// Builds a fresh contiguous `tape.Document` from `base` + a committed `Commit_Result` by:
// 1. Copying untouched prefix/middle/suffix `tape.Node`, `tape.Fact`, and `tape.Child_Count` ranges verbatim
//    (shifting `lo` offsets past each splice by the cumulative byte delta and shifting node indices by node delta).
// 2. Calling the format's `Fragment_Walker` ONLY on the newly written byte range(s) in their context.
// 3. Updating ancestor container `Node.n` (subtree node counts) and shifting `Doc_Ext` (`Markup_Ext`/`Tabular_Ext`).
//
// Falls back transparently to `Full_Builder` whenever a splice sets `full_rewalk`, touches the root, or modifies
// format extensions that require full reconstruction (e.g., XML namespace scopes or DSV headers).

// Shared helper for all 5 formats' `walk_fragment` callbacks:
// strips `strip_nodes` wrapper nodes (e.g. TOML `v=` or XML `<_>...</_>`), shifts every remaining node/fact/count
// offset by `base_lo - strip_bytes`, and frees `d`'s wrapper allocations cleanly!
shift_fragment_tape :: proc(
	d: ^tape.Document,
	base_lo: u64,
	strip_nodes: int,
	strip_bytes: u64,
	allocator: runtime.Allocator,
) -> (
	ft: Fragment_Tape,
	err: runtime.Allocator_Error,
) {
	if strip_nodes == 0 && strip_bytes == 0 {
		for &n in d.nodes {
			n.lo += base_lo
		}
		for &f in d.facts {
			f.lo += base_lo
		}
		ft = Fragment_Tape {
			nodes      = d.nodes,
			facts      = d.facts,
			counts     = d.counts,
			present    = d.present,
			root_close = d.root_close + base_lo,
			allocator  = allocator,
		}
		free(d.ext, allocator)
		free(d.partial, allocator)
		d^ = {}
		return ft, nil
	}
	defer tape.destroy_document(d)
	if len(d.nodes) <= strip_nodes {
		return {}, nil
	}
	sub := d.nodes[strip_nodes:]
	out_nodes := make([]tape.Node, len(sub), allocator) or_return
	defer if err != nil {
		delete(out_nodes, allocator)
	}
	for n, i in sub {
		shifted := n
		if shifted.lo >= strip_bytes {
			shifted.lo = shifted.lo - strip_bytes + base_lo
		}
		out_nodes[i] = shifted
	}
	out_facts := make([dynamic]tape.Fact, 0, len(d.facts), allocator)
	defer if err != nil {
		delete(out_facts)
	}
	for f in d.facts {
		if int(f.node) >= strip_nodes {
			sf := f
			sf.node -= tape.Node_Index(strip_nodes)
			if sf.lo >= strip_bytes {
				sf.lo = sf.lo - strip_bytes + base_lo
			}
			append(&out_facts, sf) or_return
		}
	}
	out_counts := make([dynamic]tape.Child_Count, 0, len(d.counts), allocator)
	defer if err != nil {
		delete(out_counts)
	}
	for cc in d.counts {
		if int(cc.node) >= strip_nodes {
			sc := cc
			sc.node -= tape.Node_Index(strip_nodes)
			append(&out_counts, sc) or_return
		}
	}
	return Fragment_Tape {
		nodes      = out_nodes,
		facts      = out_facts[:],
		counts     = out_counts[:],
		present    = d.present,
		root_close = (d.root_close - strip_bytes + base_lo) if d.root_close >= strip_bytes else base_lo,
		allocator  = allocator,
	}, nil
}

// Splices `res` into `base` using `walker` (incremental fast path) or `full_build` (fallback).
splice_document :: proc(
	base: ^tape.Document,
	res: ^Commit_Result,
	opts: Options,
	walker: Fragment_Walker,
	walker_data: rawptr,
	full_build: Full_Builder,
	full_data: rawptr,
	allocator := context.allocator,
) -> (
	doc: tape.Document,
	err: Error,
) {
	if base == nil || len(base.nodes) == 0 {
		return {}, refuse(.No_Document, "splice_document requires a built base document")
	}
	if base.partial != nil {
		return {}, refuse(.Partial_Document, "cannot splice a partial document")
	}
	new_src := res.bytes

	// Fast path: zero splices (no-op commit) -> clone base document pointing to `new_src`!
	if len(res.splices) == 0 {
		if opts.target != nil && opts.target != base.format {
			return fallback_full_build(new_src, opts, full_build, full_data, allocator)
		}
		cloned, cerr := tape.clone_document(base, allocator)
		if cerr != nil {
			return {}, cerr
		}
		if .Owns_Src in cloned.flags {
			delete(cloned.src, cloned.allocator)
			cloned.flags -= {.Owns_Src}
		}
		cloned.src = new_src
		if opts.own_src {
			cloned.flags += {.Owns_Src}
		}
		return cloned, nil
	}

	can_incremental := walker != nil && .Held not_in base.flags && len(res.splices) > 0 && (opts.target == nil || opts.target == base.format)
	if can_incremental {
		prev_end := tape.Node_Index(0)
		prev_src_hi := u64(0)
		for sp in res.splices {
			if sp.full_rewalk || !sp.subtree_only || sp.base_node == tape.NO_NODE || int(sp.base_node) >= len(base.nodes) {
				can_incremental = false
				break
			}
			if sp.base_node == tape.ROOT {
				can_incremental = false
				break
			}
			if sp.base_node < prev_end || sp.src_lo < prev_src_hi {
				can_incremental = false
				break
			}
			bn := base.nodes[sp.base_node]
			sub_n := tape.Node_Index(bn.n) if bn.kind >= .Array else 1
			prev_end = sp.base_node + sub_n
			prev_src_hi = sp.src_hi
		}
	}

	if !can_incremental {
		return fallback_full_build(new_src, opts, full_build, full_data, allocator)
	}

	eff_budget := opts.budget
	eff_max_depth := eff_budget.depth if eff_budget.depth > 0 else u32(tape.DEFAULT_DEPTH)
	n_splices := len(res.splices)
	base_depths := make([]u32, n_splices, allocator)
	defer delete(base_depths, allocator)
	if derr := compute_splice_base_depths(base, res.splices, base_depths, eff_max_depth, allocator); derr != nil {
		return {}, derr
	}

	frags := make([]Fragment_Tape, n_splices, allocator)
	defer {
		for &ft in frags {
			destroy_fragment_tape(&ft)
		}
		delete(frags, allocator)
	}

	for sp, i in res.splices {
		ctx := Fragment_Context {
			base       = base,
			base_node  = sp.base_node,
			base_depth = base_depths[i],
			budget     = eff_budget,
		}
		ft, ferr := walker(walker_data, new_src, Byte_Range{sp.dst_lo, sp.dst_hi}, ctx, allocator)
		if ferr != nil {
			#partial switch e in ferr {
			case tape.Exceeded, runtime.Allocator_Error:
				return {}, convert_tape_error(ferr)
			}
			return fallback_full_build(new_src, opts, full_build, full_data, allocator)
		}
		if full, has_full := ft.full_doc.?; has_full {
			ft.full_doc = nil
			destroy_fragment_tape(&ft)
			if opts.budget.depth > 0 {
				fd, merr := frag_max_depth(full.nodes, allocator)
				if merr != nil {
					tape.destroy_document(&full)
					return {}, merr
				}
				if fd > opts.budget.depth {
					tape.destroy_document(&full)
					return {}, tape.Exceeded{kind = .Depth, at = sp.dst_lo}
				}
			}
			out_doc := full
			if opts.own_src {
				out_doc.flags += {.Owns_Src}
			}
			return out_doc, nil
		}
		if len(ft.nodes) == 0 {
			destroy_fragment_tape(&ft)
			return fallback_full_build(new_src, opts, full_build, full_data, allocator)
		}
		fd, merr := frag_max_depth(ft.nodes, allocator)
		if merr != nil {
			destroy_fragment_tape(&ft)
			return {}, merr
		}
		if base_depths[i] + fd > eff_max_depth {
			destroy_fragment_tape(&ft)
			return {}, tape.Exceeded{kind = .Depth, at = sp.dst_lo}
		}
		frags[i] = ft
	}

	spliced, need_full, serr := assemble_spliced_document(base, new_src, res.splices, frags, opts, allocator)
	if need_full {
		return fallback_full_build(new_src, opts, full_build, full_data, allocator)
	}
	return spliced, serr
}

@(private = "file")
compute_splice_base_depths :: proc(
	base: ^tape.Document,
	splices: []Splice_Record,
	depths: []u32,
	max_depth: u32,
	allocator: runtime.Allocator,
) -> Error {
	ends := make([dynamic]tape.Node_Index, 0, 32, allocator) or_return
	defer delete(ends)
	nodes := base.nodes
	cur := tape.Node_Index(0)
	for sp, i in splices {
		target := sp.base_node
		for cur < target {
			for len(ends) > 0 && cur >= ends[len(ends) - 1] {
				pop(&ends)
			}
			cn := nodes[cur]
			if cn.kind >= .Array && cn.n > 1 && cur + tape.Node_Index(cn.n) > target {
				append(&ends, cur + tape.Node_Index(cn.n)) or_return
				cur += 1
			} else {
				cur += tape.Node_Index(cn.n) if cn.kind >= .Array else 1
			}
		}
		for len(ends) > 0 && cur >= ends[len(ends) - 1] {
			pop(&ends)
		}
		d := u32(len(ends))
		if d > max_depth {
			return tape.Exceeded{kind = .Depth, at = nodes[target].lo}
		}
		depths[i] = d
	}
	return nil
}

@(private = "file")
frag_max_depth :: proc(nodes: []tape.Node, allocator: runtime.Allocator) -> (max_d: u32, err: runtime.Allocator_Error) {
	ends := make([dynamic]tape.Node_Index, 0, 16, allocator) or_return
	defer delete(ends)
	for n, i in nodes {
		idx := tape.Node_Index(i)
		for len(ends) > 0 && idx >= ends[len(ends) - 1] {
			pop(&ends)
		}
		if n.kind >= .Array {
			d := u32(len(ends) + 1)
			if d > max_d {
				max_d = d
			}
			if n.n > 1 {
				append(&ends, idx + tape.Node_Index(n.n)) or_return
			}
		}
	}
	return max_d, nil
}

@(private = "file")
fallback_full_build :: proc(
	new_src: []u8,
	opts: Options,
	full_build: Full_Builder,
	full_data: rawptr,
	allocator: runtime.Allocator,
) -> (
	doc: tape.Document,
	err: Error,
) {
	if full_build == nil {
		return {}, refuse(.Invalid_Result, "full builder required for non-incremental splice")
	}
	built, berr := full_build(full_data, new_src, allocator)
	if berr != nil {
		return {}, convert_tape_error(berr)
	}
	if opts.budget.depth > 0 {
		fd, merr := frag_max_depth(built.nodes, allocator)
		if merr != nil {
			tape.destroy_document(&built)
			return {}, merr
		}
		if fd > opts.budget.depth {
			tape.destroy_document(&built)
			return {}, tape.Exceeded{kind = .Depth, at = tape.NO_BYTE}
		}
	}
	if opts.own_src {
		built.flags += {.Owns_Src}
	}
	return built, nil
}

@(private = "file")
Splice_Meta :: struct {
	old_start:  tape.Node_Index,
	old_end:    tape.Node_Index,
	new_start:  tape.Node_Index,
	src_lo:     u64,
	src_hi:     u64,
	node_delta: i64,
	byte_delta: i64,
}

@(private = "file")
assemble_spliced_document :: proc(
	base: ^tape.Document,
	new_src: []u8,
	splices: []Splice_Record,
	frags: []Fragment_Tape,
	opts: Options,
	allocator: runtime.Allocator,
) -> (
	doc: tape.Document,
	need_full: bool,
	err: Error,
) {
	old_nodes := base.nodes
	total_node_delta := i64(0)
	total_byte_delta := i64(0)
	for sp, i in splices {
		bn := old_nodes[sp.base_node]
		old_sub := i64(bn.n) if bn.kind >= .Array else 1
		new_sub := i64(len(frags[i].nodes))
		total_node_delta += new_sub - old_sub
		total_byte_delta += i64(sp.dst_hi - sp.dst_lo) - i64(sp.src_hi - sp.src_lo)
	}

	new_node_count := int(i64(len(old_nodes)) + total_node_delta)
	if new_node_count <= 0 || u64(new_node_count) >= u64(tape.NO_NODE) {
		return {}, false, refuse(.Invalid_Result, "spliced node count out of range")
	}

	raw_nodes, nerr := runtime.mem_alloc_non_zeroed(new_node_count * size_of(tape.Node), align_of(tape.Node), allocator)
	if nerr != nil {
		return {}, false, nerr
	}
	new_nodes := ([^]tape.Node)(raw_data(raw_nodes))[:new_node_count]
	defer if err != nil || need_full {
		runtime.mem_free(raw_data(new_nodes), allocator)
	}

	metas, merr := make([]Splice_Meta, len(splices), allocator)
	if merr != nil {
		return {}, false, merr
	}
	defer delete(metas, allocator)

	old_pos := 0
	new_pos := 0
	running_byte_delta := i64(0)

	for sp, i in splices {
		start := int(sp.base_node)
		bn := old_nodes[start]
		old_sub := int(bn.n) if bn.kind >= .Array else 1
		new_sub := len(frags[i].nodes)

		prefix_len := start - old_pos
		if prefix_len > 0 {
			copy(new_nodes[new_pos : new_pos + prefix_len], old_nodes[old_pos:start])
			if running_byte_delta != 0 {
				shift_node_offsets(new_nodes[new_pos : new_pos + prefix_len], metas[:i], running_byte_delta)
			}
			new_pos += prefix_len
		}

		metas[i] = {
			old_start  = sp.base_node,
			old_end    = sp.base_node + tape.Node_Index(old_sub),
			new_start  = tape.Node_Index(new_pos),
			src_lo     = sp.src_lo,
			src_hi     = sp.src_hi,
			node_delta = i64(new_sub) - i64(old_sub),
			byte_delta = i64(sp.dst_hi - sp.dst_lo) - i64(sp.src_hi - sp.src_lo),
		}

		copy(new_nodes[new_pos : new_pos + new_sub], frags[i].nodes)
		new_nodes[new_pos].role = bn.role
		new_pos += new_sub
		old_pos = start + old_sub
		running_byte_delta += metas[i].byte_delta
	}

	tail_len := len(old_nodes) - old_pos
	if tail_len > 0 {
		copy(new_nodes[new_pos : new_pos + tail_len], old_nodes[old_pos:])
		if running_byte_delta != 0 {
			shift_node_offsets(new_nodes[new_pos : new_pos + tail_len], metas, running_byte_delta)
		}
		new_pos += tail_len
	}

	if total_node_delta != 0 || any_nonzero_node_delta(metas) {
		patch_ancestor_counts(new_nodes, metas)
	}

	new_facts, present, facts_spliced, ferr := assemble_spliced_facts(base.facts, frags, metas, allocator)
	if ferr != nil {
		return {}, false, ferr
	}
	defer if err != nil || need_full {
		if new_facts != nil {
			runtime.mem_free(raw_data(new_facts), allocator)
		}
	}

	new_counts, cerr := assemble_spliced_counts(base.counts, frags, metas, allocator)
	if cerr != nil {
		return {}, false, cerr
	}
	defer if err != nil || need_full {
		if new_counts != nil {
			runtime.mem_free(raw_data(new_counts), allocator)
		}
	}

	new_ext: ^tape.Doc_Ext
	if base.ext != nil {
		eerr: runtime.Allocator_Error
		ext_ok: bool
		new_ext, ext_ok, eerr = clone_shifted_ext(base.ext, metas, facts_spliced, allocator)
		if eerr != nil {
			return {}, false, eerr
		}
		if !ext_ok {
			return {}, true, nil
		}
	}

	flags := base.flags - {.Owns_Src}
	if opts.own_src {
		flags += {.Owns_Src}
	}
	format := opts.target if opts.target != nil else base.format

	return tape.Document {
		src        = new_src,
		nodes      = new_nodes,
		facts      = new_facts,
		counts     = new_counts,
		format     = format,
		ext        = new_ext,
		root_close = u64(i64(base.root_close) + total_byte_delta),
		present    = present,
		flags      = flags,
		allocator  = allocator,
	}, false, nil
}

@(private = "file")
any_nonzero_node_delta :: proc "contextless" (metas: []Splice_Meta) -> bool {
	for m in metas {
		if m.node_delta != 0 {
			return true
		}
	}
	return false
}

// Shifts `old_lo` ONLY by splices whose `src_hi <= old_lo` so DTD `<!ATTLIST>` defaults and `In_Place` entity
// nodes sitting before a splice never shift or underflow `u64`.
@(private = "file")
shift_byte_offset :: #force_inline proc "contextless" (old_lo: u64, prev_metas: []Splice_Meta) -> u64 #no_bounds_check {
	delta := i64(0)
	for m in prev_metas {
		if m.src_hi <= old_lo {
			delta += m.byte_delta
		} else {
			break
		}
	}
	return u64(i64(old_lo) + delta)
}

@(private = "file")
shift_node_offsets :: proc "contextless" (nodes: []tape.Node, prev_metas: []Splice_Meta, total_delta: i64) #no_bounds_check {
	if len(prev_metas) == 0 {
		return
	}
	last_hi := prev_metas[len(prev_metas) - 1].src_hi
	d := u64(total_delta)
	for i := 0; i < len(nodes); i += 1 {
		lo := nodes[i].lo
		if lo >= last_hi {
			nodes[i].lo = lo + d
		} else {
			nodes[i].lo = shift_byte_offset(lo, prev_metas)
		}
	}
}

@(private = "file")
patch_ancestor_counts :: proc "contextless" (new_nodes: []tape.Node, metas: []Splice_Meta) #no_bounds_check {
	n_metas := len(metas)
	old_idx := tape.Node_Index(0)
	new_idx := tape.Node_Index(0)
	mi := 0
	for int(new_idx) < len(new_nodes) {
		if mi < n_metas && new_idx == metas[mi].new_start {
			new_sub := i64(metas[mi].old_end - metas[mi].old_start) + metas[mi].node_delta
			old_idx = metas[mi].old_end
			new_idx += tape.Node_Index(new_sub)
			mi += 1
			continue
		}
		nd := &new_nodes[new_idx]
		if nd.kind >= .Array && nd.n > 1 {
			old_end := old_idx + tape.Node_Index(nd.n)
			if mi >= n_metas || old_end <= metas[mi].old_start {
				old_idx = old_end
				new_idx += tape.Node_Index(nd.n)
				continue
			}
			delta := i64(0)
			for j := mi; j < n_metas && metas[j].old_start < old_end; j += 1 {
				delta += metas[j].node_delta
			}
			nd.n = u32(i64(nd.n) + delta)
		}
		old_idx += 1
		new_idx += 1
	}
}

@(private = "file")
assemble_spliced_facts :: proc(
	old_facts: []tape.Fact,
	frags: []Fragment_Tape,
	metas: []Splice_Meta,
	allocator: runtime.Allocator,
) -> (
	out: []tape.Fact,
	present: tape.Facts,
	facts_spliced: bool,
	err: runtime.Allocator_Error,
) {
	est := len(old_facts)
	for ft in frags {
		est += len(ft.facts)
	}
	if est == 0 {
		return nil, {}, false, nil
	}
	buf := make([dynamic]tape.Fact, 0, est, allocator)
	defer delete(buf)
	after_buf := make([dynamic]tape.Fact, 0, 4, allocator)
	defer delete(after_buf)

	fi := 0
	running_node_delta := i64(0)
	running_byte_delta := i64(0)

	for m, si in metas {
		prev_hi := metas[si - 1].src_hi if si > 0 else u64(0)
		for fi < len(old_facts) && old_facts[fi].node < m.old_start {
			f := old_facts[fi]
			f.node = tape.Node_Index(i64(f.node) + running_node_delta)
			if si > 0 {
				if f.lo >= prev_hi {
					f.lo = u64(i64(f.lo) + running_byte_delta)
				} else {
					f.lo = shift_byte_offset(f.lo, metas[:si])
				}
			}
			append(&buf, f) or_return
			present += {f.kind}
			fi += 1
		}
		clear(&after_buf)
		for fi < len(old_facts) && old_facts[fi].node < m.old_end {
			f := old_facts[fi]
			fi += 1
			if f.node != m.old_start {
				facts_spliced = true
				continue
			}
			if f.lo >= m.src_lo && f.lo < m.src_hi {
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
			if f.lo < m.src_lo {
				f.node = m.new_start
				if si > 0 {
					f.lo = shift_byte_offset(f.lo, metas[:si])
				}
				append(&buf, f) or_return
				present += {f.kind}
			} else {
				f.node = m.new_start
				f.lo = shift_byte_offset(f.lo, metas[:si])
				f.lo = u64(i64(f.lo) + m.byte_delta)
				append(&after_buf, f) or_return
			}
		}
		if len(frags[si].facts) > 0 {
			facts_spliced = true
		}
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
	last_hi := metas[len(metas) - 1].src_hi if len(metas) > 0 else u64(0)
	for fi < len(old_facts) {
		f := old_facts[fi]
		f.node = tape.Node_Index(i64(f.node) + running_node_delta)
		if len(metas) > 0 {
			if f.lo >= last_hi {
				f.lo = u64(i64(f.lo) + running_byte_delta)
			} else {
				f.lo = shift_byte_offset(f.lo, metas)
			}
		}
		append(&buf, f) or_return
		present += {f.kind}
		fi += 1
	}
	if len(buf) == 0 {
		return nil, present, facts_spliced, nil
	}
	raw := runtime.mem_alloc_non_zeroed(len(buf) * size_of(tape.Fact), align_of(tape.Fact), allocator) or_return
	out = ([^]tape.Fact)(raw_data(raw))[:len(buf)]
	copy(out, buf[:])
	return out, present, facts_spliced, nil
}

@(private = "file")
assemble_spliced_counts :: proc(
	old_counts: []tape.Child_Count,
	frags: []Fragment_Tape,
	metas: []Splice_Meta,
	allocator: runtime.Allocator,
) -> (
	out: []tape.Child_Count,
	err: runtime.Allocator_Error,
) {
	est := len(old_counts)
	for ft in frags {
		est += len(ft.counts)
	}
	if est == 0 {
		return nil, nil
	}
	buf := make([dynamic]tape.Child_Count, 0, est, allocator)
	defer delete(buf)

	ci := 0
	running_node_delta := i64(0)
	for m, si in metas {
		for ci < len(old_counts) && old_counts[ci].node < m.old_start {
			cc := old_counts[ci]
			cc.node = tape.Node_Index(i64(cc.node) + running_node_delta)
			append(&buf, cc) or_return
			ci += 1
		}
		for ci < len(old_counts) && old_counts[ci].node < m.old_end {
			ci += 1
		}
		for fc in frags[si].counts {
			cc := fc
			cc.node += m.new_start
			append(&buf, cc) or_return
		}
		running_node_delta += m.node_delta
	}
	for ci < len(old_counts) {
		cc := old_counts[ci]
		cc.node = tape.Node_Index(i64(cc.node) + running_node_delta)
		append(&buf, cc) or_return
		ci += 1
	}
	if len(buf) == 0 {
		return nil, nil
	}
	raw := runtime.mem_alloc_non_zeroed(len(buf) * size_of(tape.Child_Count), align_of(tape.Child_Count), allocator) or_return
	out = ([^]tape.Child_Count)(raw_data(raw))[:len(buf)]
	copy(out, buf[:])
	return out, nil
}

@(private = "file")
clone_shifted_ext :: proc(
	old_ext: ^tape.Doc_Ext,
	metas: []Splice_Meta,
	facts_spliced: bool,
	allocator: runtime.Allocator,
) -> (
	ext: ^tape.Doc_Ext,
	ok: bool,
	err: runtime.Allocator_Error,
) {
	// If XML namespace scopes or URIs could have shifted fact indices (including equal-count delete+insert!)
	// or been replaced inside a splice, request full rebuild so `Markup_Ext.uris` / `scopes` stay 100% exact!
	#partial switch f in old_ext.format {
	case tape.Markup_Ext:
		if len(f.uris) > 0 && facts_spliced {
			return nil, false, nil
		}
		if .In_Place in f.dtd.flags {
			return nil, false, nil
		}
		for sc in f.scopes {
			for m in metas {
				if sc.node >= m.old_start && sc.node < m.old_end {
					return nil, false, nil
				}
			}
		}
	case tape.Tabular_Ext:
		// If any splice touched the header line bytes (`keys` live before `first_row`), request full rebuild.
		for k in f.keys {
			for m in metas {
				if m.src_lo < k.lo + u64(k.n) {
					return nil, false, nil
				}
			}
		}
	}
	ext = tape.ext_make(old_ext.held, old_ext.format, allocator, old_ext.origin) or_return
	#partial switch &f in ext.format {
	case tape.Markup_Ext:
		for &sc in f.scopes {
			sc.node = shift_node_idx(sc.node, metas)
			sc.end = shift_node_idx(sc.end, metas)
		}
	case tape.Tabular_Ext:
		for &t in f.tables {
			t.node = shift_node_idx(t.node, metas)
			t.first_row = shift_node_idx(t.first_row, metas)
		}
	}
	return ext, true, nil
}

@(private = "file")
shift_node_idx :: proc "contextless" (idx: tape.Node_Index, metas: []Splice_Meta) -> tape.Node_Index {
	delta := i64(0)
	for m in metas {
		if idx >= m.old_end {
			delta += m.node_delta
		} else {
			break
		}
	}
	return tape.Node_Index(i64(idx) + delta)
}
