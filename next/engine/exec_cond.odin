package engine

import "base:runtime"
import "stury:dsv"
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
		ro := build_tape_opts(opts, allow_parallel = false)
		pdoc, serr := scan(src, &dem, dec.spec, {}, ro, opts.allocator)
		if serr != nil {
			return {err = .No_Memory if is_alloc_err(serr) else .Read_Error, read_err = serr}
		}
		meta := Record_Meta{file_index = opts.file_index, file_path = opts.file_path, lo = 0, hi = u64(len(src)), raw_bytes = src}
		matched, wrong, perr := eval_predicate_doc(&pdoc, cw, meta, opts)
		tape.destroy(&pdoc)
		if wrong || perr == .Tainted {
			if perr == .Tainted {
				if !opts.rerun_whole_on_taint && !dec.rerun_safe {
					return {err = .Tainted, tainted = true}
				}
				if opts.eval == nil {
					return {err = .Failed}
				}
				wres := exec_whole(dec, src, opts)
				wres.reran_whole = true
				return wres
			}
			if opts.eval == nil {
				return {err = .Failed}
			}
			return exec_whole(dec, src, opts)
		}
		if perr != .None {
			return {err = perr}
		}
		if !matched {
			return {}
		}
		return exec_whole(dec, src, opts)
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
			if wrong || perr == .Tainted {
				is_tainted := perr == .Tainted
				if is_tainted && (res.emitted > 0 || (!opts.rerun_whole_on_taint && !dec.rerun_safe)) {
					res.err = .Tainted
					res.tainted = true
					return res
				}
				if opts.eval == nil {
					res.err = .Failed
					return res
				}
				if can_build_single_record(dec, raw) {
					sub := exec_single_record_whole(dec, raw, meta, opts)
					res.emitted += sub.emitted
					if is_tainted {
						res.reran_whole = true
					}
					if sub.err != .None {
						res.err = sub.err
						res.read_err = sub.read_err
						return res
					}
					continue
				}
				if dec.entry.family == .Dsv && len(raw) > 0 {
					if !has_whole_dem {
						wd, _, werr := prepare_demand(nil, dec.keep_facts, opts.allocator)
						if werr != nil {
							res.err = .No_Memory
							res.read_err = werr
							return res
						}
						whole_dem = wd
						has_whole_dem = true
					}
					sub := run_dsv_row_whole(dec.spec.(dsv.Spec), src, dsv_header_end, raw, &dsv_row_buf, &whole_dem, meta, opts)
					res.emitted += sub.emitted
					if is_tainted {
						res.reran_whole = true
					}
					if sub.err != .None {
						res.err = sub.err
						res.read_err = sub.read_err
						res.write_err = sub.write_err
						return res
					}
					continue
				}
				res.err = .Failed
				return res
			}
			if perr != .None {
				res.err = perr
				return res
			}
			if !matched {
				continue
			}
			if can_build_single_record(dec, raw) {
				if opts.eval != nil {
					sub := exec_single_record_whole(dec, raw, meta, opts)
					res.emitted += sub.emitted
					if sub.err != .None {
						res.err = sub.err
						res.read_err = sub.read_err
						return res
					}
				} else {
					sub := emit_raw_or_compact(dec, raw, opts)
					res.emitted += sub.emitted
					if sub.err != .None {
						res.err = sub.err
						res.read_err = sub.read_err
						res.write_err = sub.write_err
						return res
					}
				}
			} else if dec.entry.family == .Dsv && len(raw) > 0 {
				if !has_whole_dem {
					wd, _, werr := prepare_demand(nil, dec.keep_facts, opts.allocator)
					if werr != nil {
						res.err = .No_Memory
						res.read_err = werr
						return res
					}
					whole_dem = wd
					has_whole_dem = true
				}
				sub := run_dsv_row_whole(dec.spec.(dsv.Spec), src, dsv_header_end, raw, &dsv_row_buf, &whole_dem, meta, opts)
				res.emitted += sub.emitted
				if sub.err != .None {
					res.err = sub.err
					res.read_err = sub.read_err
					res.write_err = sub.write_err
					return res
				}
			} else {
				res.err = .Unsupported
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
run_dsv_row_whole :: proc(
	spec: dsv.Spec,
	src: []u8,
	dsv_header_end: u64,
	raw: []u8,
	buf: ^[dynamic]u8,
	whole_dem: ^tape.Demand,
	meta: Record_Meta,
	opts: ^Exec_Options,
) -> Exec_Result {
	clear(buf)
	if dsv_header_end > 0 {
		if _, aerr := append(buf, ..src[:dsv_header_end]); aerr != nil {
			return {err = .No_Memory, read_err = aerr}
		}
	}
	if _, aerr := append(buf, ..raw); aerr != nil {
		return {err = .No_Memory, read_err = aerr}
	}
	return exec_single_dsv_row_whole(spec, buf[:], whole_dem, build_tape_opts(opts, false), meta, opts)
}

@(private = "file")
eval_predicate_doc :: proc(
	doc: ^tape.Document,
	cw: ^query.Conditional_Whole,
	meta: Record_Meta,
	opts: ^Exec_Options,
) -> (
	matched: bool,
	wrong_kind: bool,
	err: Exec_Error,
) {
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
) -> (
	matched: bool,
	wrong_kind: bool,
	err: Exec_Error,
) {
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
		next: query.Value
		nst: query.Status
		switch s in step {
		case tape.Name:
			if tt == .Null || tt == .Absent {
				query.release(&h, cur)
				cur = query.NULL
				break
			}
			if tt != .Object {
				query.release(&h, cur)
				cur = query.ABSENT
				return false, true, .None
			}
			next, nst = query.member(&h, cur, string(s))
		case tape.Index:
			if tt == .Null || tt == .Absent {
				query.release(&h, cur)
				cur = query.NULL
				break
			}
			if tt != .Array {
				query.release(&h, cur)
				cur = query.ABSENT
				return false, true, .None
			}
			next, nst = query.element(&h, cur, int(s))
		case tape.All, tape.Slice, tape.Descend:
			query.release(&h, cur)
			cur = query.ABSENT
			return false, true, .None
		}
		if cur.kind == .Null {
			break
		}
		query.release(&h, cur)
		cur = next
		if h.tainted {
			query.release(&h, cur)
			cur = query.ABSENT
			return false, false, .Tainted
		}
		if nst != .Ok {
			query.clear_error(&h)
			query.release(&h, cur)
			cur = query.ABSENT
			return false, true, .None
		}
		if cur.kind == .Absent {
			query.release(&h, cur)
			cur = query.NULL
			break
		}
	}

	switch cmp.op {
	case .Eq:
		eq, est := query.equal(&h, cur, cmp.literal)
		if h.tainted {
			return false, false, .Tainted
		}
		if est != .Ok {
			query.clear_error(&h)
			return false, false, .Failed
		}
		return eq, false, .None
	case .Ne:
		eq, est := query.equal(&h, cur, cmp.literal)
		if h.tainted {
			return false, false, .Tainted
		}
		if est != .Ok {
			query.clear_error(&h)
			return false, false, .Failed
		}
		return !eq, false, .None
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
