package engine

import "base:runtime"
import "stury:lib/core/tape"
import "stury:lib/query"

// Hint 3: `.Conditional_Whole` scans only predicate demand first, building/emitting the whole
// record/document only when the predicate matches.
@(private)
exec_conditional_whole :: proc(plan: ^query.Plan, dec: ^Decision, src: []u8, opts: ^Exec_Options) -> Exec_Result {
	cw := &plan.hints.conditional
	if !cw.active || (cw.cmp.op == .None && opts.pred_eval == nil) || dec.keep_origins || dups_needs_build(dec.entry, opts.read.dups) {
		return exec_whole(dec, src, opts) if dec.framing == .Single else exec_records(plan, dec, src, opts, dec.parallel)
	}
	dem, dem_owned, derr := prepare_demand(&cw.pred_demand, keep_facts = false, alloc = opts.allocator)
	if derr != nil {
		return {err = .No_Memory, read_err = derr}
	}
	defer if dem_owned {
		tape.destroy_demand(&dem)
	}

	tf, framed := to_tape_framing(dec.framing)
	if !framed {
		pdoc, serr := scan(src, &dem, dec.spec, {}, build_tape_opts(opts, allow_parallel = false), opts.allocator)
		if serr != nil {
			return {err = .No_Memory if is_alloc_err(serr) else .Read_Error, read_err = serr}
		}
		meta := Record_Meta{file_index = opts.file_index, file_path = opts.file_path, lo = 0, hi = u64(len(src)), raw_bytes = src}
		matched, wrong, perr := eval_predicate_doc(&pdoc, cw, meta, opts)
		tape.destroy(&pdoc)
		if wrong || perr == .Tainted {
			if perr == .Tainted && !opts.rerun_whole_on_taint && !dec.rerun_safe {
				return {err = .Tainted, tainted = true}
			}
			if opts.eval == nil {
				return {err = .Failed}
			}
			wres := exec_whole(dec, src, opts)
			wres.reran_whole ||= perr == .Tainted
			return wres
		}
		if perr != .None {
			return {err = perr}
		}
		return exec_whole(dec, src, opts) if matched else {}
	}

	ro := build_tape_opts(opts, allow_parallel = opts.runner != nil && opts.runner.threads > 0)
	recs, open_err_res, open_ok := open_framed_records(src, dec.spec, tf, ro, nil, opts)
	if !open_ok {
		return open_err_res
	}
	defer tape.destroy_records(recs)

	whole_dem: tape.Demand
	has_whole_dem := false
	defer if has_whole_dem {
		tape.destroy_demand(&whole_dem)
	}
	dsv_header_end := dsv_header_end_of(dec, ro, recs)
	dsv_row_buf := make([dynamic]u8, opts.allocator)
	defer delete(dsv_row_buf)

	out_recs: [RECORD_BATCH_SIZE]tape.Record
	docs: [RECORD_BATCH_SIZE]tape.Document
	res: Exec_Result
	for {
		n := tape.records_scan(recs, &dem, out_recs[:], docs[:], {}, opts.allocator)
		if n == 0 {
			break
		}
		for i in 0 ..< n {
			r_info := out_recs[i]
			if r_info.err != nil {
				if !handle_bad_record(opts, src, r_info, &res) {
					return res
				}
				continue
			}
			raw := record_slice(src, r_info)
			meta := make_record_meta(opts, res.records, r_info, raw)
			res.records += 1
			matched, wrong, perr := eval_predicate_doc(&docs[i], cw, meta, opts)
			is_tainted := perr == .Tainted
			if wrong || is_tainted {
				if is_tainted && (res.emitted > 0 || (!opts.rerun_whole_on_taint && !dec.rerun_safe)) {
					res.err = .Tainted
					res.tainted = true
					return res
				}
				if opts.eval == nil {
					res.err = .Failed
					return res
				}
			} else if perr != .None {
				res.err = perr
				return res
			} else if !matched {
				continue
			}

			if dec.entry.family == .Dsv && !has_whole_dem {
				wd, _, werr := prepare_demand(nil, dec.keep_facts, opts.allocator)
				if werr != nil {
					res.err = .No_Memory
					res.read_err = werr
					return res
				}
				whole_dem = wd
				has_whole_dem = true
			}
			sub, ok := rerun_record_whole(dec, src, dsv_header_end, raw, &dsv_row_buf, meta, opts, &whole_dem if has_whole_dem else nil)
			if !ok {
				res.err = .Failed if (wrong || is_tainted) else .Unsupported
				return res
			}
			merge_result(&res, sub)
			if is_tainted {
				res.reran_whole = true
			}
			if sub.err != .None {
				return res
			}
		}
	}
	if recs.err != nil {
		res.err = .No_Memory if is_alloc_err(recs.err) else .Read_Error
		res.read_err = recs.err
	}
	return res
}

@(private = "file")
eval_predicate_doc :: proc(
	doc: ^tape.Document,
	cw: ^query.Conditional_Whole,
	meta: Record_Meta,
	opts: ^Exec_Options,
) -> (matched: bool, wrong_kind: bool, err: Exec_Error) {
	if cw.cmp.op == .None {
		if opts.pred_eval == nil {
			return false, false, .Unsupported
		}
		m, e := opts.pred_eval(opts.pred_ctx, doc, meta)
		return m, false, e
	}
	return eval_simple_compare(doc, cw.cmp, opts.allocator)
}

@(private = "file")
eval_simple_compare :: proc(
	doc: ^tape.Document,
	cmp: query.Simple_Compare,
	alloc: runtime.Allocator,
) -> (matched: bool, wrong_kind: bool, err: Exec_Error) {
	h: query.Heap
	query.heap_init(&h, alloc)
	defer query.heap_destroy(&h)

	cur, st := query.document_value(&h, doc^, owned = false)
	if st != .Ok {
		return false, false, .Failed
	}
	defer query.release(&h, cur)
	if h.tainted {
		return false, false, .Tainted
	}

	for step in cmp.path {
		tt := query.type_of(cur)
		if tt == .Null || tt == .Absent {
			query.release(&h, cur)
			cur = query.NULL
			break
		}
		next: query.Value
		nst: query.Status
		switch s in step {
		case tape.Name:
			if tt != .Object {
				return false, true, .None
			}
			next, nst = query.member(&h, cur, string(s))
		case tape.Index:
			if tt != .Array {
				return false, true, .None
			}
			next, nst = query.element(&h, cur, int(s))
		case tape.All, tape.Slice, tape.Descend:
			return false, true, .None
		}
		query.release(&h, cur)
		cur = next
		if h.tainted {
			return false, false, .Tainted
		}
		if nst != .Ok {
			query.clear_error(&h)
			return false, true, .None
		}
		if cur.kind == .Absent {
			query.release(&h, cur)
			cur = query.NULL
			break
		}
	}

	switch cmp.op {
	case .Eq, .Ne:
		eq, est := query.equal(&h, cur, cmp.literal)
		if h.tainted {
			return false, false, .Tainted
		}
		if est != .Ok {
			query.clear_error(&h)
			return false, false, .Failed
		}
		return eq if cmp.op == .Eq else !eq, false, .None
	case .Lt, .Le, .Gt, .Ge:
		c, cst := query.compare(&h, cur, cmp.literal, query.JSON_ORDER)
		if h.tainted {
			return false, false, .Tainted
		}
		if cst != .Ok {
			query.clear_error(&h)
			return false, false, .Failed
		}
		#partial switch cmp.op {
		case .Lt: return c < 0, false, .None
		case .Le: return c <= 0, false, .None
		case .Gt: return c > 0, false, .None
		case .Ge: return c >= 0, false, .None
		}
	case .None:
	}
	return false, false, .Unsupported
}
