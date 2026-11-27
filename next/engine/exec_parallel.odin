package engine

import "base:intrinsics"
import "base:runtime"
import "stury:json"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import ops_build "stury:lib/ops/build"
import "stury:lib/ops/write"
import "stury:lib/query"

// Parallel execution workers for `.Records_Parallel`, `.Files_Parallel`, and Hint 1 `.Spine_Parallel`.
// Preserves strict deterministic output order, per-worker allocator/scratch locking, OOM checking,
// and cumulative taint guards (`prior_emitted + res.emitted == 0`).

@(private)
Slot_Buffer :: struct {
	chunks:    [dynamic]u8,
	offs:      [dynamic]int,
	lens:      [dynamic]int,
	err:       Exec_Error,
	read_err:  tape.Error,
	write_err: write.Error,
	tainted:   bool,
	res:       Exec_Result,
}

@(private)
slot_buffer_destroy :: proc(sb: ^Slot_Buffer) {
	delete(sb.chunks)
	delete(sb.offs)
	delete(sb.lens)
}

@(private)
slot_buffer_init_alloc :: proc(sb: ^Slot_Buffer, a: runtime.Allocator) {
	sb.chunks.allocator = a
	sb.offs.allocator = a
	sb.lens.allocator = a
}

@(private)
slot_emit_fn :: proc(data: rawptr, bytes: []u8) -> bool {
	sb := (^Slot_Buffer)(data)
	off := len(sb.chunks)
	if _, aerr := append(&sb.chunks, ..bytes); aerr != nil {
		sb.err, sb.read_err = .No_Memory, aerr
		return false
	}
	if _, a1 := append(&sb.offs, off); a1 != nil {
		resize(&sb.chunks, off)
		sb.err, sb.read_err = .No_Memory, a1
		return false
	}
	if _, a2 := append(&sb.lens, len(bytes)); a2 != nil {
		resize(&sb.chunks, off)
		pop(&sb.offs)
		sb.err, sb.read_err = .No_Memory, a2
		return false
	}
	return true
}

@(private)
drain_slot_chunks :: proc(sb: ^Slot_Buffer, emit: Emitter, total: ^Exec_Result) -> bool {
	for idx in 0 ..< len(sb.offs) {
		off, sz := sb.offs[idx], sb.lens[idx]
		if off < 0 || sz < 0 || off + sz > len(sb.chunks) {
			total.err = .No_Memory
			return false
		}
		if !emit_bytes(emit, sb.chunks[off:][:sz]) {
			total.err = .Stopped
			return false
		}
		total.emitted += 1
	}
	return true
}

// Parallel multi-file execution with locked shared allocator/scratch and deterministic file output order.
@(private)
execute_files_parallel :: proc(
	plan: ^query.Plan,
	files: []File_Input,
	r_opts: Route_Options,
	opts: Exec_Options,
	runner: ^tape.Runner,
	alloc: runtime.Allocator,
) -> Exec_Result {
	slots, serr := make([]Slot_Buffer, len(files), alloc)
	if serr != nil {
		return {err = .No_Memory, read_err = serr}
	}
	defer {
		for &s in slots {
			slot_buffer_destroy(&s)
		}
		delete(slots, alloc)
	}

	File_Job :: struct {
		plan:         ^query.Plan,
		files:        []File_Input,
		route_opts:   Route_Options,
		opts:         Exec_Options,
		slots:        []Slot_Buffer,
		alloc_wrap:   Locked_Allocator,
		scratch_wrap: Locked_Allocator,
		lock_scratch: bool,
	}

	job := File_Job{
		plan         = plan,
		files        = files,
		route_opts   = r_opts,
		opts         = opts,
		slots        = slots,
		lock_scratch = has_custom_scratch(opts.read.scratch),
	}
	locked_alloc_init(&job.alloc_wrap, alloc)
	if job.lock_scratch {
		locked_alloc_init(&job.scratch_wrap, opts.read.scratch, force_lock = true)
	}

	run_file :: proc(arg: rawptr, k: int) {
		j := (^File_Job)(arg)
		lalloc := locked_allocator(&j.alloc_wrap)
		sb := &j.slots[k]
		slot_buffer_init_alloc(sb, lalloc)

		wctx := j.opts.workers.init(j.opts.eval_ctx, k, lalloc) if j.opts.workers.init != nil else j.opts.eval_ctx
		defer if j.opts.workers.fini != nil {
			j.opts.workers.fini(j.opts.eval_ctx, k, wctx)
		}

		f := j.files[k]
		f_route := j.route_opts
		f_route.file_count, f_route.runner, f_route.serial_eval_ctx, f_route.input_bytes = 1, nil, false, len(f.src)
		dec := decide(j.plan, f.spec, f.framing, f_route)

		f_opts := j.opts
		f_opts.runner, f_opts.workers = nil, {}
		f_opts.eval_ctx, f_opts.file_index, f_opts.file_path, f_opts.allocator = wctx, k, f.path, lalloc
		if j.lock_scratch {
			f_opts.read.scratch = locked_allocator(&j.scratch_wrap)
		}
		f_opts.emit = Emitter{fn = slot_emit_fn, data = sb}

		f_res := execute(j.plan, &dec, f.src, f_opts)
		if sb.err == .No_Memory {
			f_res.err, f_res.read_err = .No_Memory, sb.read_err
		}
		sb.res = f_res
	}

	tape.fan_each(runner, len(files), run_file, &job)

	total: Exec_Result
	for &sb in slots {
		if sb.err == .No_Memory || sb.res.err == .No_Memory {
			total.err = .No_Memory
			total.read_err = sb.read_err if sb.read_err != nil else sb.res.read_err
			return total
		}
		if !drain_slot_chunks(&sb, opts.emit, &total) {
			return total
		}
		total.records += sb.res.records
		total.bad_records += sb.res.bad_records
		total.tainted ||= sb.res.tainted
		total.reran_whole ||= sb.res.reran_whole
		if sb.res.err != .None {
			total.err, total.read_err, total.write_err = sb.res.err, sb.res.read_err, sb.res.write_err
			return total
		}
	}
	return total
}

// Evaluates a batch of records across worker threads (either pre-scanned `docs` or built whole when `docs == nil`).
@(private = "file")
eval_record_batch_par_impl :: proc(
	dec: ^Decision,
	src: []u8,
	out_recs: []tape.Record,
	docs: []tape.Document,
	rec_ro: tape.Options,
	clear_partial: bool,
	base_rec_idx: u64,
	prior_emitted: u64,
	allow_taint_rerun: bool,
	dsv_header_end: u64,
	opts: ^Exec_Options,
) -> Exec_Result {
	n := len(out_recs)
	slots, serr := make([]Slot_Buffer, n, opts.allocator)
	if serr != nil {
		return {err = .No_Memory, read_err = serr}
	}
	defer {
		for &s in slots {
			slot_buffer_destroy(&s)
		}
		delete(slots, opts.allocator)
	}

	Batch_Job :: struct {
		dec:           ^Decision,
		src:           []u8,
		out_recs:      []tape.Record,
		docs:          []tape.Document,
		rec_ro:        tape.Options,
		clear_partial: bool,
		base_rec_idx:  u64,
		opts:          ^Exec_Options,
		slots:         []Slot_Buffer,
		alloc_wrap:    Locked_Allocator,
		scratch_wrap:  Locked_Allocator,
		lock_scratch:  bool,
	}

	build_whole := docs == nil
	job := Batch_Job{
		dec           = dec,
		src           = src,
		out_recs      = out_recs,
		docs          = docs,
		rec_ro        = rec_ro,
		clear_partial = clear_partial,
		base_rec_idx  = base_rec_idx,
		opts          = opts,
		slots         = slots,
		lock_scratch  = build_whole && has_custom_scratch(rec_ro.scratch),
	}
	locked_alloc_init(&job.alloc_wrap, opts.allocator)
	if job.lock_scratch {
		locked_alloc_init(&job.scratch_wrap, rec_ro.scratch, force_lock = true)
	}

	worker_fn :: proc(arg: rawptr, k: int) {
		j := (^Batch_Job)(arg)
		r_info := j.out_recs[k]
		if r_info.err != nil {
			return
		}
		lalloc := locked_allocator(&j.alloc_wrap)
		sb := &j.slots[k]
		slot_buffer_init_alloc(sb, lalloc)

		raw := record_slice(j.src, r_info)
		doc_val: tape.Document
		built_doc := false
		if j.docs == nil {
			w_ro := j.rec_ro
			w_ro.runner = nil
			if j.lock_scratch {
				w_ro.scratch = locked_allocator(&j.scratch_wrap)
			}
			d, berr := build(raw, j.dec.spec, w_ro, lalloc)
			if berr != nil {
				sb.err = .No_Memory if is_alloc_err(berr) else .Read_Error
				sb.read_err = berr
				return
			}
			doc_val, built_doc = d, true
		} else {
			doc_val = j.docs[k]
			if j.clear_partial && doc_val.partial != nil {
				doc_val.partial = nil
			}
		}
		defer if built_doc {
			tape.destroy(&doc_val)
		}

		wctx := j.opts.workers.init(j.opts.eval_ctx, k, lalloc) if j.opts.workers.init != nil else j.opts.eval_ctx
		defer if j.opts.workers.fini != nil {
			j.opts.workers.fini(j.opts.eval_ctx, k, wctx)
		}

		meta := make_record_meta(j.opts, j.base_rec_idx + u64(k), r_info, raw)
		ret_err := j.opts.eval(wctx, &doc_val, meta, Emitter{fn = slot_emit_fn, data = sb})
		if sb.err == .None {
			sb.err = ret_err
		}
		if sb.err == .Tainted {
			sb.tainted = true
		}
	}

	tape.fan_each(opts.runner, n, worker_fn, &job)

	dsv_row_buf := make([dynamic]u8, opts.allocator)
	defer delete(dsv_row_buf)

	res: Exec_Result
	for i in 0 ..< n {
		r_info := out_recs[i]
		if r_info.err != nil {
			if !handle_bad_record(opts, src, r_info, &res) {
				return res
			}
			continue
		}
		sb := &slots[i]
		if sb.err == .No_Memory {
			res.err, res.read_err = .No_Memory, sb.read_err
			return res
		}
		if build_whole && sb.err == .Read_Error && sb.read_err != nil {
			bad := r_info
			bad.err = sb.read_err
			if !handle_bad_record(opts, src, bad, &res) {
				return res
			}
			continue
		}
		raw := record_slice(src, r_info)
		res.records += 1
		if !build_whole && sb.tainted {
			if allow_taint_rerun && (prior_emitted + res.emitted) == 0 && (opts.rerun_whole_on_taint || dec.rerun_safe) {
				meta := make_record_meta(opts, base_rec_idx + u64(i), r_info, raw)
				if sub, ok := rerun_record_whole(dec, src, dsv_header_end, raw, &dsv_row_buf, meta, opts); ok {
					merge_result(&res, sub)
					res.reran_whole = true
					if sub.err != .None {
						return res
					}
					continue
				}
			}
			res.err, res.tainted = .Tainted, true
			return res
		}
		if !drain_slot_chunks(sb, opts.emit, &res) {
			return res
		}
		if sb.err != .None {
			res.err, res.read_err, res.write_err = sb.err, sb.read_err, sb.write_err
			return res
		}
	}
	return res
}

@(private)
eval_record_batch_parallel :: proc(
	dec: ^Decision,
	src: []u8,
	out_recs: []tape.Record,
	docs: []tape.Document,
	clear_partial: bool,
	base_rec_idx: u64,
	prior_emitted: u64,
	allow_taint_rerun: bool,
	dsv_header_end: u64,
	opts: ^Exec_Options,
) -> Exec_Result {
	return eval_record_batch_par_impl(dec, src, out_recs, docs, {}, clear_partial, base_rec_idx, prior_emitted, allow_taint_rerun, dsv_header_end, opts)
}

@(private)
eval_record_batch_whole_parallel :: proc(
	dec: ^Decision,
	src: []u8,
	out_recs: []tape.Record,
	rec_ro: tape.Options,
	base_rec_idx: u64,
	opts: ^Exec_Options,
) -> Exec_Result {
	return eval_record_batch_par_impl(dec, src, out_recs, nil, rec_ro, false, base_rec_idx, 0, false, 0, opts)
}

@(private = "file")
spine_fallback_whole :: proc(dec: ^Decision, src: []u8, opts: ^Exec_Options, reran := false) -> Exec_Result {
	if opts.eval == nil {
		return {err = .Failed}
	}
	wres := exec_whole(dec, src, opts)
	wres.reran_whole ||= reran
	return wres
}

@(private = "file")
spine_fallback :: proc(plan: ^query.Plan, dec: ^Decision, src: []u8, opts: ^Exec_Options) -> Exec_Result {
	if opts.eval == nil {
		return {err = .Failed}
	}
	if dec.demand_mode != .Whole && dec.entry.supports_scan && plan != nil && plan.sources[.Main].mode == .Partial {
		return exec_scan(plan, dec, src, opts)
	}
	return exec_whole(dec, src, opts)
}

@(private = "file")
finish_spine_length :: proc(total_count: u64, opts: ^Exec_Options, res: ^Exec_Result) {
	g := Guard_Emit{inner = opts.emit}
	cerr := opts.emit_spine_length(opts.eval_ctx, total_count, Emitter{fn = guard_emit_fn, data = &g})
	res.emitted += g.emitted
	if g.stopped && cerr == .None {
		cerr = .Stopped
	}
	res.err = cerr
}

@(private = "file")
finish_spine_collect :: proc(dec: ^Decision, src: []u8, item_outputs: [][]u8, opts: ^Exec_Options, res: ^Exec_Result) {
	doc_w: tape.Document
	doc_ptr: ^tape.Document = nil
	has_doc := false
	if opts.spine_collect_needs_doc {
		wdoc, werr := build(src, dec.spec, build_tape_opts(opts, allow_parallel = false), opts.allocator)
		if werr != nil {
			res.err = .No_Memory if is_alloc_err(werr) else .Read_Error
			res.read_err = werr
			return
		}
		doc_w, has_doc, doc_ptr = wdoc, true, &doc_w
	}
	defer if has_doc {
		tape.destroy(&doc_w)
	}
	g := Guard_Emit{inner = opts.emit}
	cerr := opts.spine_collect(opts.eval_ctx, doc_ptr, item_outputs, Emitter{fn = guard_emit_fn, data = &g})
	res.emitted += g.emitted
	if g.stopped && cerr == .None {
		cerr = .Stopped
	}
	res.err = cerr
}

// Hint 1: `.Spine_Parallel` splits array elements reached by `prefix` across `opts.runner`,
// preserving strict element order cleanly.
@(private)
exec_spine_parallel :: proc(plan: ^query.Plan, dec: ^Decision, src: []u8, opts: ^Exec_Options) -> Exec_Result {
	sp := &plan.hints.split
	is_length := sp.kind == .Length && sp.has_each
	if dups_needs_build(dec.entry, opts.read.dups) || opts.eval_each == nil {
		return spine_fallback_whole(dec, src, opts)
	}
	if opts.runner == nil || opts.runner.threads <= 0 || len(src) < SPINE_PARALLEL_FROM ||
	   (sp.kind == .Collect && opts.spine_collect == nil && !opts.spine_collect_compact) ||
	   (is_length && (opts.eval_each_count == nil || opts.emit_spine_length == nil)) {
		return spine_fallback(plan, dec, src, opts)
	}

	can_par_each := can_parallel_eval(opts.workers.init != nil, opts.eval_each_ctx, true, opts.eval_ctx_thread_safe)
	if dec.entry.id == .Json && opts.read.pieces == nil && opts.read.tolerate == {} && opts.read.budget == {} &&
	   opts.max_bytes == 0 && len(src) >= max(SPINE_PARALLEL_FROM, 4096) && can_par_each {
		if cres, handled := exec_spine_coarse_parallel(plan, dec, src, opts); handled {
			return cres
		}
	}
	if sp.kind == .Collect && opts.spine_collect == nil {
		return spine_fallback(plan, dec, src, opts)
	}

	use_partial := dec.entry.supports_scan && sp.each_demand.mode == .Partial
	dem, dem_owned, derr := prepare_demand(&sp.each_demand if use_partial else nil, dec.keep_facts || !use_partial, opts.allocator)
	if derr != nil {
		return {err = .No_Memory, read_err = derr}
	}
	defer if dem_owned {
		tape.destroy_demand(&dem)
	}

	recs, open_err_res, open_ok := open_framed_records(src, dec.spec, .Elements, build_tape_opts(opts, false), sp.prefix, opts)
	if !open_ok {
		return open_err_res if open_err_res.err == .No_Memory else spine_fallback_whole(dec, src, opts)
	}
	defer tape.destroy_records(recs)

	collected: [dynamic][]u8
	collected.allocator = opts.allocator
	defer if sp.kind == .Collect {
		for item in collected {
			delete(item, opts.allocator)
		}
		delete(collected)
	}

	Collect_Emit :: struct {
		list:  ^[dynamic][]u8,
		alloc: runtime.Allocator,
		oom:   bool,
	}
	collect_emit_fn :: proc(data: rawptr, bytes: []u8) -> bool {
		ce := (^Collect_Emit)(data)
		copy_buf, merr := make([]u8, len(bytes), ce.alloc)
		if merr != nil {
			ce.oom = true
			return false
		}
		copy(copy_buf, bytes)
		if _, aerr := append(ce.list, copy_buf); aerr != nil {
			delete(copy_buf, ce.alloc)
			ce.oom = true
			return false
		}
		return true
	}

	each_opts := opts^
	each_opts.eval, each_opts.eval_ctx = opts.eval_each, opts.eval_each_ctx
	ce := Collect_Emit{list = &collected, alloc = opts.allocator}
	if sp.kind == .Collect {
		each_opts.emit = Emitter{fn = collect_emit_fn, data = &ce}
	}

	out_recs: [RECORD_BATCH_SIZE]tape.Record
	docs: [RECORD_BATCH_SIZE]tape.Document
	res: Exec_Result
	downstream_emitted, length_total := u64(0), u64(0)

	for {
		n := tape.records_scan(recs, &dem, out_recs[:], docs[:], {}, opts.allocator)
		if n == 0 {
			break
		}
		err_idx := -1
		for i in 0 ..< n {
			if out_recs[i].err != nil {
				err_idx = i
				break
			}
		}
		valid_n := err_idx if err_idx >= 0 else n
		if valid_n > 0 {
			if is_length {
				cnt, csub := eval_spine_count_batch(src, out_recs[:valid_n], docs[:valid_n], !use_partial, res.records, can_par_each, &each_opts)
				res.records += csub.records
				res.tainted ||= csub.tainted
				if csub.err == .Tainted && (opts.rerun_whole_on_taint || dec.rerun_safe) {
					return spine_fallback_whole(dec, src, opts, reran = true)
				}
				if csub.err != .None {
					res.err, res.read_err, res.write_err = csub.err, csub.read_err, csub.write_err
					return res
				}
				length_total += cnt
			} else {
				sub: Exec_Result
				if can_par_each && valid_n > 1 {
					sub = eval_record_batch_parallel(dec, src, out_recs[:valid_n], docs[:valid_n], !use_partial, res.records, downstream_emitted, sp.kind == .Stream, 0, &each_opts)
				} else {
					sub = eval_spine_batch_serial(dec, src, out_recs[:valid_n], docs[:valid_n], !use_partial, res.records, downstream_emitted, sp.kind == .Stream, &each_opts)
				}
				res.records += sub.records
				if sp.kind == .Stream {
					res.emitted += sub.emitted
					downstream_emitted += sub.emitted
				}
				res.tainted ||= sub.tainted
				res.reran_whole ||= sub.reran_whole
				if ce.oom || sub.err == .No_Memory {
					res.err = .No_Memory
					res.read_err = runtime.Allocator_Error.Out_Of_Memory if sub.read_err == nil else sub.read_err
					return res
				}
				if sub.err != .None {
					if sub.err == .Tainted && downstream_emitted == 0 && (opts.rerun_whole_on_taint || dec.rerun_safe) {
						return spine_fallback_whole(dec, src, opts, reran = true)
					}
					res.err, res.read_err, res.write_err = sub.err, sub.read_err, sub.write_err
					return res
				}
			}
		}
		if err_idx >= 0 {
			res.records += 1
			res.bad_records += 1
			res.err = .No_Memory if is_alloc_err(out_recs[err_idx].err) else .Read_Error
			res.read_err = out_recs[err_idx].err
			return res
		}
	}
	if recs.err != nil {
		if bo, is_bo := recs.err.(tape.Bad_Option); is_bo && bo.option == "framing" && res.records == 0 {
			return spine_fallback_whole(dec, src, opts)
		}
		res.err = .No_Memory if is_alloc_err(recs.err) else .Read_Error
		res.read_err = recs.err
		return res
	}
	if res.records == 0 {
		if ans, ferr := find(src, sp.prefix, dec.spec, {stop_early = true}, build_tape_opts(opts, false), opts.allocator); ferr != nil || ans.outcome != .Found || ans.kind != .Array {
			return spine_fallback_whole(dec, src, opts)
		}
	}
	if is_length {
		finish_spine_length(length_total, opts, &res)
	} else if sp.kind == .Collect && opts.spine_collect != nil {
		finish_spine_collect(dec, src, collected[:], opts, &res)
	}
	return res
}

@(private = "file")
eval_spine_batch_serial :: proc(
	dec: ^Decision,
	src: []u8,
	out_recs: []tape.Record,
	docs: []tape.Document,
	clear_partial: bool,
	base_rec_idx: u64,
	prior_emitted: u64,
	allow_taint_rerun: bool,
	each_opts: ^Exec_Options,
) -> Exec_Result {
	res: Exec_Result
	for r_info, i in out_recs {
		raw := record_slice(src, r_info)
		meta := make_record_meta(each_opts, base_rec_idx + u64(i), r_info, raw)
		res.records += 1
		doc_val := docs[i]
		if clear_partial && doc_val.partial != nil {
			doc_val.partial = nil
		}
		r := eval_or_emit_doc(&doc_val, meta, each_opts)
		res.emitted += r.emitted
		if r.err == .Tainted {
			if allow_taint_rerun && (prior_emitted + res.emitted) == 0 && (each_opts.rerun_whole_on_taint || dec.rerun_safe) && can_build_single_record(dec, raw) {
				sub := exec_single_record_whole(dec, raw, meta, each_opts)
				merge_result(&res, sub)
				res.reran_whole = true
				if sub.err != .None {
					return res
				}
				continue
			}
			res.err, res.tainted = .Tainted, true
			return res
		}
		if r.err != .None {
			res.err = r.err
			return res
		}
	}
	return res
}

@(private = "file")
eval_spine_count_batch :: proc(
	src: []u8,
	out_recs: []tape.Record,
	docs: []tape.Document,
	clear_partial: bool,
	base_rec_idx: u64,
	can_par_each: bool,
	each_opts: ^Exec_Options,
) -> (total: u64, res: Exec_Result) {
	if !can_par_each || len(out_recs) <= 1 {
		for r_info, i in out_recs {
			res.records += 1
			doc_val := docs[i]
			if clear_partial && doc_val.partial != nil {
				doc_val.partial = nil
			}
			cnt, err := each_opts.eval_each_count(each_opts.eval_ctx, &doc_val, make_record_meta(each_opts, base_rec_idx + u64(i), r_info, record_slice(src, r_info)))
			if err != .None {
				res.err, res.tainted = err, err == .Tainted
				return total, res
			}
			total += cnt
		}
		return total, res
	}

	Count_Slot :: struct {
		count: u64,
		err:   Exec_Error,
	}
	slots, serr := make([]Count_Slot, len(out_recs), each_opts.allocator)
	if serr != nil {
		return 0, {err = .No_Memory, read_err = serr}
	}
	defer delete(slots, each_opts.allocator)

	Count_Job :: struct {
		src:           []u8,
		out_recs:      []tape.Record,
		docs:          []tape.Document,
		clear_partial: bool,
		base_rec_idx:  u64,
		opts:          ^Exec_Options,
		slots:         []Count_Slot,
		alloc_wrap:    Locked_Allocator,
	}
	job := Count_Job{src = src, out_recs = out_recs, docs = docs, clear_partial = clear_partial, base_rec_idx = base_rec_idx, opts = each_opts, slots = slots}
	locked_alloc_init(&job.alloc_wrap, each_opts.allocator)

	worker_fn :: proc(arg: rawptr, k: int) {
		j := (^Count_Job)(arg)
		lalloc := locked_allocator(&j.alloc_wrap)
		wctx := j.opts.workers.init(j.opts.eval_ctx, k, lalloc) if j.opts.workers.init != nil else j.opts.eval_ctx
		defer if j.opts.workers.fini != nil {
			j.opts.workers.fini(j.opts.eval_ctx, k, wctx)
		}
		doc_val := j.docs[k]
		if j.clear_partial && doc_val.partial != nil {
			doc_val.partial = nil
		}
		cnt, err := j.opts.eval_each_count(wctx, &doc_val, make_record_meta(j.opts, j.base_rec_idx + u64(k), j.out_recs[k], record_slice(j.src, j.out_recs[k])))
		j.slots[k] = {count = cnt, err = err}
	}
	tape.fan_each(each_opts.runner, len(out_recs), worker_fn, &job)
	for s in slots {
		res.records += 1
		if s.err != .None {
			res.err, res.tainted = s.err, s.err == .Tainted
			return total, res
		}
		total += s.count
	}
	return total, res
}

@(private = "file")
Coarse_Event_Kind :: enum u8 {
	Emit_Slice,
	Ack_Recs,
	Bad_Record,
	Tainted_Rec,
}

@(private = "file")
Coarse_Event :: struct {
	kind:    Coarse_Event_Kind,
	off, sz: int,
	count:   u64,
	recs:    u64,
	rec_idx: u64,
	rec:     tape.Record,
}

@(private = "file")
Coarse_Chunk_Slot :: struct {
	base_idx:          u64,
	out_buf:           [dynamic]u8,
	offs, lens:        [dynamic]int,
	events:            [dynamic]Coarse_Event,
	records:           u64,
	emitted_items:     u64,
	item_count:        u64,
	err:               Exec_Error,
	read_err:          tape.Error,
	write_err:         write.Error,
	tainted:           bool,
	read_err_fallback: bool,
}

@(private = "file")
coarse_chunk_slot_destroy :: proc(s: ^Coarse_Chunk_Slot) {
	delete(s.out_buf)
	delete(s.offs)
	delete(s.lens)
	delete(s.events)
}

@(private = "file")
slot_push_slice :: proc(slot: ^Coarse_Chunk_Slot, off, sz: int) -> bool {
	if _, a1 := append(&slot.offs, off); a1 != nil {
		slot.err, slot.read_err = .No_Memory, a1
		return false
	}
	if _, a2 := append(&slot.lens, sz); a2 != nil {
		slot.err, slot.read_err = .No_Memory, a2
		return false
	}
	return true
}

@(private = "file")
count_json_records_chunk :: proc "contextless" (src: []u8, lo, hi: u64, tf: tape.Framing) -> (count: u64) #no_bounds_check {
	base := raw_data(src)
	end := base[hi:]
	delim := u8('\n') if tf == .Lines else 0x1e
	for pos := lo; pos < hi; {
		p := u64(intrinsics.ptr_sub(kernel.skip_ws(base[pos:], end), base))
		if p >= hi {
			break
		}
		if tf == .Seq && src[p] == 0x1e {
			pos = p + 1
			continue
		}
		count += 1
		if i := kernel.index_byte(src[p:hi], delim); i >= 0 {
			pos = p + u64(i) + 1
		} else {
			break
		}
	}
	return
}

// Coarse chunk-level `.Records_Parallel` execution for strict JSON `.Lines` / `.Seq`.
@(private)
exec_records_coarse_parallel :: proc(
	dec: ^Decision,
	src: []u8,
	tf: tape.Framing,
	ro: tape.Options,
	dem: ^tape.Demand,
	clear_partial: bool,
	opts: ^Exec_Options,
) -> (res: Exec_Result, handled: bool) {
	jspec, is_json := dec.spec.(json.Spec)
	if !is_json || jspec != .Json {
		return {}, false
	}
	delim := u8('\n') if tf == .Lines else 0x1e
	chunks: [ops_build.MAX_RECORD_CHUNKS]ops_build.Record_Chunk = ---
	nc := ops_build.cut_delim_chunks(src, u64(spell.bom_length(src)), delim, ro.runner, chunks[:])
	if nc < 2 {
		return {}, false
	}
	slots, serr := make([]Coarse_Chunk_Slot, nc, opts.allocator)
	if serr != nil {
		return {err = .No_Memory, read_err = serr}, true
	}
	defer {
		for &s in slots {
			coarse_chunk_slot_destroy(&s)
		}
		delete(slots, opts.allocator)
	}

	Count_Rec_Job :: struct {
		src:    []u8,
		tf:     tape.Framing,
		chunks: []ops_build.Record_Chunk,
		slots:  []Coarse_Chunk_Slot,
	}
	cjob := Count_Rec_Job{src = src, tf = tf, chunks = chunks[:nc], slots = slots}
	tape.fan_each(ro.runner, nc, proc(arg: rawptr, k: int) {
		j := (^Count_Rec_Job)(arg)
		j.slots[k].base_idx = count_json_records_chunk(j.src, j.chunks[k].lo, j.chunks[k].hi, j.tf)
	}, &cjob)
	running_idx := u64(0)
	for &s in slots {
		cnt := s.base_idx
		s.base_idx = running_idx
		running_idx += cnt
	}

	Coarse_Rec_Job :: struct {
		dec:           ^Decision,
		src:           []u8,
		tf:            tape.Framing,
		jspec:         json.Spec,
		ro:            tape.Options,
		dem:           ^tape.Demand,
		clear_partial: bool,
		opts:          ^Exec_Options,
		chunks:        []ops_build.Record_Chunk,
		slots:         []Coarse_Chunk_Slot,
		alloc_wrap:    Locked_Allocator,
		scratch_wrap:  Locked_Allocator,
		lock_scratch:  bool,
	}

	job := Coarse_Rec_Job{
		dec           = dec,
		src           = src,
		tf            = tf,
		jspec         = jspec,
		ro            = ro,
		dem           = dem,
		clear_partial = clear_partial,
		opts          = opts,
		chunks        = chunks[:nc],
		slots         = slots,
		lock_scratch  = has_custom_scratch(ro.scratch),
	}
	locked_alloc_init(&job.alloc_wrap, opts.allocator)
	if job.lock_scratch {
		locked_alloc_init(&job.scratch_wrap, ro.scratch, force_lock = true)
	}

	Rec_Emit_Ctx :: struct {
		slot:          ^Coarse_Chunk_Slot,
		flushed:       int,
		pending_items: u64,
		pending_recs:  u64,
		coalesce:      bool,
	}

	flush_rec_pending :: proc(ec: ^Rec_Emit_Ctx) -> bool {
		if len(ec.slot.out_buf) > ec.flushed {
			if _, aerr := append(&ec.slot.events, Coarse_Event{kind = .Emit_Slice, off = ec.flushed, sz = len(ec.slot.out_buf) - ec.flushed, count = ec.pending_items, recs = ec.pending_recs}); aerr != nil {
				ec.slot.err, ec.slot.read_err = .No_Memory, aerr
				return false
			}
			ec.flushed, ec.pending_items, ec.pending_recs = len(ec.slot.out_buf), 0, 0
		} else if ec.pending_recs > 0 {
			if _, aerr := append(&ec.slot.events, Coarse_Event{kind = .Ack_Recs, recs = ec.pending_recs}); aerr != nil {
				ec.slot.err, ec.slot.read_err = .No_Memory, aerr
				return false
			}
			ec.pending_recs = 0
		}
		return true
	}

	rec_emit_fn :: proc(data: rawptr, bytes: []u8) -> bool {
		ec := (^Rec_Emit_Ctx)(data)
		off := len(ec.slot.out_buf)
		if _, aerr := append(&ec.slot.out_buf, ..bytes); aerr != nil {
			ec.slot.err, ec.slot.read_err = .No_Memory, aerr
			return false
		}
		ec.slot.emitted_items += 1
		ec.pending_items += 1
		if !ec.coalesce && !flush_rec_pending(ec) {
			resize(&ec.slot.out_buf, off)
			return false
		}
		return true
	}

	run_chunk :: proc(arg: rawptr, k: int) {
		j := (^Coarse_Rec_Job)(arg)
		lalloc := locked_allocator(&j.alloc_wrap)
		slot := &j.slots[k]
		c := j.chunks[k]
		init_cap := max(int(c.hi - c.lo) * (2 if j.opts.fast_json == .Pretty2 else 1), 256)
		slot.out_buf = make([dynamic]u8, 0, init_cap, lalloc)
		slot.events.allocator = lalloc

		chunk_ro := j.ro
		chunk_ro.runner = nil
		if j.lock_scratch {
			chunk_ro.scratch = locked_allocator(&j.scratch_wrap)
		}
		lr, base_off, oerr_k, oerr_v := open_json_chunk_records(j.src, c, k, j.tf, j.jspec, chunk_ro, j.opts)
		if oerr_k != .None {
			slot.err, slot.read_err = oerr_k, oerr_v
			return
		}
		defer tape.destroy_records(&lr)

		wctx := j.opts.eval_ctx
		has_wctx := false
		defer if has_wctx && j.opts.workers.fini != nil {
			j.opts.workers.fini(j.opts.eval_ctx, k, wctx)
		}

		ec := Rec_Emit_Ctx{slot = slot, coalesce = j.opts.coalesce_emit}
		local_idx := u64(0)
		out_recs: [RECORD_BATCH_SIZE]tape.Record = ---
		docs: [RECORD_BATCH_SIZE]tape.Document = ---
		for {
			n := json.records_scan(&lr, j.dem, out_recs[:], docs[:], {}, lalloc)
			if n == 0 {
				break
			}
			for i in 0 ..< n {
				r_info := adjust_rec_offset(out_recs[i], base_off)
				if r_info.err != nil {
					local_idx += 1
					if !flush_rec_pending(&ec) {
						return
					}
					if _, aerr := append(&slot.events, Coarse_Event{kind = .Bad_Record, rec = r_info}); aerr != nil {
						slot.err, slot.read_err = .No_Memory, aerr
						return
					}
					continue
				}
				raw := record_slice(j.src, r_info)
				if can_fast_json_doc(j.dec, &docs[i], j.opts.fast_json, j.opts) {
					off := len(slot.out_buf)
					if append_fast_json_doc(&slot.out_buf, &docs[i], j.opts.fast_json, true) {
						slot.records += 1
						ec.pending_recs += 1
						slot.emitted_items += 1
						ec.pending_items += 1
						local_idx += 1
						if !ec.coalesce && !flush_rec_pending(&ec) {
							resize(&slot.out_buf, off)
							return
						}
						continue
					}
				}
				if !has_wctx {
					if j.opts.workers.init != nil {
						wctx = j.opts.workers.init(j.opts.eval_ctx, k, lalloc)
					}
					has_wctx = true
				}
				doc_val := docs[i]
				if j.clear_partial && doc_val.partial != nil {
					doc_val.partial = nil
				}
				rec_idx := slot.base_idx + local_idx
				local_idx += 1
				slot.records += 1
				ec.pending_recs += 1
				eval_err := j.opts.eval(wctx, &doc_val, make_record_meta(j.opts, rec_idx, r_info, raw), Emitter{fn = rec_emit_fn, data = &ec})
				if slot.err == .No_Memory {
					return
				}
				if eval_err == .Tainted {
					if slot.emitted_items > 0 {
						if len(slot.events) > 0 && !flush_rec_pending(&ec) {
							return
						}
						slot.err, slot.tainted = .Tainted, true
						return
					}
					slot.records -= 1
					ec.pending_recs -= 1
					if !flush_rec_pending(&ec) {
						return
					}
					if _, aerr := append(&slot.events, Coarse_Event{kind = .Tainted_Rec, rec = r_info, rec_idx = rec_idx}); aerr != nil {
						slot.err, slot.read_err = .No_Memory, aerr
						return
					}
					slot.tainted = true
					return
				}
				if eval_err != .None {
					if len(slot.events) > 0 && !flush_rec_pending(&ec) {
						return
					}
					slot.err = eval_err
					return
				}
			}
		}
		if len(slot.events) > 0 && !flush_rec_pending(&ec) {
			return
		}
		if lr.err != nil {
			err_v := adjust_err_offset(lr.err, base_off)
			slot.err = .No_Memory if is_alloc_err(err_v) else .Read_Error
			slot.read_err = err_v
		}
	}

	tape.fan_each(ro.runner, nc, run_chunk, &job)

	finish_serial_tail :: proc(dec: ^Decision, src: []u8, c: ops_build.Record_Chunk, start_pos: u64, tf: tape.Framing, ro: tape.Options, dem: ^tape.Demand, clear_partial: bool, opts: ^Exec_Options, res: ^Exec_Result) -> bool {
		tail_ro := ro
		tail_ro.runner = nil
		base_off := u64(0)
		chunk_src := src[:c.hi]
		if tf == .Seq && start_pos > 0 {
			p := start_pos
			for p < c.hi && src[p] != 0x1e {
				p += 1
			}
			if p >= c.hi {
				return true
			}
			base_off = p
			chunk_src = src[base_off:c.hi]
		}
		recs, open_err_res, open_ok := open_framed_records(chunk_src, dec.spec, tf, tail_ro, nil, opts)
		if !open_ok {
			merge_result(res, open_err_res)
			return false
		}
		defer tape.destroy_records(recs)
		if tf == .Lines && start_pos > recs.pos {
			recs.pos, recs.at = start_pos, .Open
		}
		out_recs: [RECORD_BATCH_SIZE]tape.Record
		docs: [RECORD_BATCH_SIZE]tape.Document
		for {
			n := tape.records_scan(recs, dem, out_recs[:], docs[:], {}, opts.allocator)
			if n == 0 {
				break
			}
			if !eval_serial_batch(dec, src, out_recs[:n], docs[:n], clear_partial, base_off, 0, false, nil, nil, opts, res) {
				return false
			}
		}
		if recs.err != nil {
			err_v := adjust_err_offset(recs.err, base_off)
			res.err = .No_Memory if is_alloc_err(err_v) else .Read_Error
			res.read_err = err_v
			return false
		}
		return true
	}

	for &slot, k in slots {
		if slot.err == .No_Memory {
			res.err, res.read_err = .No_Memory, slot.read_err
			return res, true
		}
		if len(slot.events) == 0 {
			res.records += slot.records
			if len(slot.out_buf) > 0 {
				if !emit_bytes(opts.emit, slot.out_buf[:]) {
					res.err = .Stopped
					return res, true
				}
				res.emitted += slot.emitted_items
			}
			if slot.err != .None {
				res.err, res.read_err, res.write_err = slot.err, slot.read_err, slot.write_err
				return res, true
			}
			continue
		}
		tainted_reran := false
		tainted_rec: tape.Record
		for ev in slot.events {
			switch ev.kind {
			case .Emit_Slice:
				res.records += ev.recs
				if ev.sz > 0 {
					if !emit_bytes(opts.emit, slot.out_buf[ev.off:][:ev.sz]) {
						res.err = .Stopped
						return res, true
					}
					res.emitted += ev.count
				}
			case .Ack_Recs:
				res.records += ev.recs
			case .Bad_Record:
				if !handle_bad_record(opts, src, ev.rec, &res) {
					return res, true
				}
			case .Tainted_Rec:
				res.records += 1
				raw := record_slice(src, ev.rec)
				if res.emitted == 0 && (opts.rerun_whole_on_taint || dec.rerun_safe) && can_build_single_record(dec, raw) {
					sub := exec_single_record_whole(dec, raw, make_record_meta(opts, ev.rec_idx, ev.rec, raw), opts)
					merge_result(&res, sub)
					res.reran_whole = true
					if sub.err != .None {
						return res, true
					}
					tainted_reran, tainted_rec = true, ev.rec
				} else {
					res.err, res.tainted = .Tainted, true
					return res, true
				}
			}
		}
		if tainted_reran {
			if tainted_rec.hi < chunks[k].hi && !finish_serial_tail(dec, src, chunks[k], tainted_rec.hi, tf, ro, dem, clear_partial, opts, &res) {
				return res, true
			}
			continue
		}
		if slot.err != .None {
			res.err, res.read_err, res.write_err = slot.err, slot.read_err, slot.write_err
			return res, true
		}
	}
	return res, true
}

@(private = "file")
Spine_Quotes :: struct {
	quoted: bool,
	odd:    bool,
	depth:  [2]int,
	low:    [2]int,
}

@(private = "file", enable_target_feature = kernel.FEATURES[kernel.Tier(0)])
spine_quote_run :: proc "contextless" (src: []u8) -> (res: Spine_Quotes) #no_bounds_check {
	n := len(src)
	if n == 0 {
		return
	}
	odd, parity := u64(0), u64(0)
	d0, low0, d1, low1 := 0, 0, 0, 0
	for base := 0; base < n; base += 64 {
		rem := min(64, n - base)
		valid := ~u64(0) if rem == 64 else (u64(1) << uint(rem)) - 1
		b := kernel.load_block(src, base)
		esc := kernel.escaped(kernel.pack(kernel.eq(b, '\\')) & valid, &odd)
		q := (kernel.pack(kernel.eq(b, '"')) & valid) &~ esc
		in0 := kernel.prefix_xor(kernel.Tier(0), q) ~ parity
		opens := (kernel.pack(kernel.eq(b, '[')) | kernel.pack(kernel.eq(b, '{'))) & valid
		closes := (kernel.pack(kernel.eq(b, ']')) | kernel.pack(kernel.eq(b, '}'))) & valid
		for m0 := (opens | closes) & (~in0 & valid); m0 != 0; m0 &= m0 - 1 {
			d0 += 1 if (opens & (m0 & (~m0 + 1))) != 0 else -1
			low0 = min(low0, d0)
		}
		for m1 := (opens | closes) & (in0 & valid); m1 != 0; m1 &= m1 - 1 {
			d1 += 1 if (opens & (m1 & (~m1 + 1))) != 0 else -1
			low1 = min(low1, d1)
		}
		parity = ~u64(0) if ((in0 >> uint(rem - 1)) & 1) != 0 else 0
	}
	bs := 0
	for k := n - 1; k >= 0 && src[k] == '\\'; k -= 1 {
		bs += 1
	}
	return {quoted = parity != 0, odd = (bs & 1) != 0, depth = {d0, d1}, low = {low0, low1}}
}

@(private = "file", enable_target_feature = kernel.FEATURES[kernel.Tier(0)])
spine_scan_commas :: proc "contextless" (src: []u8, entry_quoted: bool, entry_depth: int) -> (first_comma: int, trailing_commas: u64) #no_bounds_check {
	first_comma = -1
	n := len(src)
	if n == 0 || entry_depth < 0 {
		return
	}
	odd := u64(0)
	parity := ~u64(0) if entry_quoted else u64(0)
	depth := entry_depth
	for base := 0; base < n; base += 64 {
		rem := min(64, n - base)
		valid := ~u64(0) if rem == 64 else (u64(1) << uint(rem)) - 1
		b := kernel.load_block(src, base)
		esc := kernel.escaped(kernel.pack(kernel.eq(b, '\\')) & valid, &odd)
		q := (kernel.pack(kernel.eq(b, '"')) & valid) &~ esc
		in_q := kernel.prefix_xor(kernel.Tier(0), q) ~ parity
		opens := (kernel.pack(kernel.eq(b, '[')) | kernel.pack(kernel.eq(b, '{'))) & valid
		closes := (kernel.pack(kernel.eq(b, ']')) | kernel.pack(kernel.eq(b, '}'))) & valid
		commas := kernel.pack(kernel.eq(b, ',')) & valid
		for ev := (opens | closes | commas) & (~in_q & valid); ev != 0; ev &= ev - 1 {
			idx := int(intrinsics.count_trailing_zeros(ev))
			bit := u64(1) << uint(idx)
			if (opens & bit) != 0 {
				depth += 1
			} else if (closes & bit) != 0 {
				depth -= 1
				if depth < 0 {
					return
				}
			} else if depth == 0 {
				if first_comma < 0 {
					first_comma = base + idx
				} else {
					trailing_commas += 1
				}
			}
		}
		parity = ~u64(0) if ((in_q >> uint(rem - 1)) & 1) != 0 else 0
	}
	return
}

@(private = "file")
Spine_Quote_Chunk :: struct {
	lo, hi:          int,
	q:               Spine_Quotes,
	entry_quoted:    bool,
	entry_depth:     int,
	comma_rel:       int,
	trailing_commas: u64,
}

@(private = "file")
Spine_Part :: struct {
	lo, hi:   int,
	base_idx: u64,
}

@(private = "file")
find_spine_close :: proc "contextless" (sub: []u8, start_depth: int, start_quoted: bool) -> (rel: int, is_arr_close: bool) #no_bounds_check {
	depth, quoted, esc := start_depth, start_quoted, false
	for b, i in sub {
		if esc {
			esc = false
			continue
		}
		if quoted {
			if b == '\\' {
				esc = true
			} else if b == '"' {
				quoted = false
			}
			continue
		}
		switch b {
		case '"':      quoted = true
		case '[', '{': depth += 1
		case ']', '}':
			depth -= 1
			if depth < 0 {
				return i, b == ']'
			}
		}
	}
	return -1, false
}

// Coarse 3-wave Hint 1 execution for strict JSON arrays.
@(private = "file")
exec_spine_coarse_parallel :: proc(plan: ^query.Plan, dec: ^Decision, src: []u8, opts: ^Exec_Options) -> (res: Exec_Result, handled: bool) {
	if dec.entry.id != .Json || opts.read.pieces != nil || opts.read.tolerate != {} || opts.read.budget != {} || opts.max_bytes != 0 || dec.keep_origins {
		return {}, false
	}
	sp := &plan.hints.split
	at, _, sok := json.spine(src, .Json, {dups = opts.read.dups, budget = opts.read.budget})
	if !sok || int(at) + 1 >= len(src) {
		return {}, false
	}
	inner := src[at + 1:]
	n_inner := len(inner)
	chunk_min := max(min(SPINE_PARALLEL_FROM / 16, 16384), 2048)
	want := min((opts.runner.threads + 1) * 4, n_inner / chunk_min, ops_build.MAX_RECORD_CHUNKS)
	if want < 2 {
		return {}, false
	}

	qchunks: [ops_build.MAX_RECORD_CHUNKS]Spine_Quote_Chunk
	qnc, lo := 0, 0
	for k in 0 ..< want {
		hi := n_inner if k == want - 1 else max(lo, n_inner * (k + 1) / want)
		for hi < n_inner && hi > lo && inner[hi - 1] == '\\' {
			hi += 1
		}
		if hi > lo {
			qchunks[qnc] = {lo = lo, hi = hi}
			qnc += 1
			lo = hi
		}
		if lo >= n_inner {
			break
		}
	}
	if qnc < 2 {
		return {}, false
	}

	Quote_Job :: struct {
		inner:  []u8,
		chunks: []Spine_Quote_Chunk,
	}
	qjob := Quote_Job{inner = inner, chunks = qchunks[:qnc]}
	tape.fan_each(opts.runner, qnc, proc(arg: rawptr, k: int) {
		j := (^Quote_Job)(arg)
		c := &j.chunks[k]
		c.q = spine_quote_run(j.inner[c.lo:c.hi])
	}, &qjob)

	quoted, depth, close_chunk := false, 0, -1
	for k in 0 ..< qnc {
		c := &qchunks[k]
		c.entry_quoted, c.entry_depth = quoted, depth
		g := 1 if quoted else 0
		if depth + c.q.low[g] < 0 {
			close_chunk = k
			break
		}
		depth += c.q.depth[g]
		quoted = quoted != c.q.quoted
		if k < qnc - 1 && c.q.odd {
			return {}, false
		}
	}
	if close_chunk < 0 {
		return {}, false
	}
	cc := qchunks[close_chunk]
	close_rel, is_arr_close := find_spine_close(inner[cc.lo:cc.hi], cc.entry_depth, cc.entry_quoted)
	if close_rel < 0 || !is_arr_close {
		return {}, false
	}
	close_inner_off := cc.lo + close_rel
	abs_close := int(at + 1) + close_inner_off

	shell_len := int(at) + 2 + len(src) - (abs_close + 1)
	if shell_len > max(len(src) / 2, 1 << 20) {
		return {}, false
	}
	shell, sh_err := make([]u8, shell_len, opts.allocator)
	if sh_err != nil {
		return {err = .No_Memory, read_err = sh_err}, true
	}
	defer delete(shell, opts.allocator)
	copy(shell, src[:at])
	shell[at], shell[at + 1] = '[', ']'
	copy(shell[at + 2:], src[abs_close + 1:])

	v_opts := json.Options{dups = opts.read.dups, runner = opts.runner}
	if json.validate(shell, .Json, v_opts) != nil {
		return {}, false
	}
	if ans, ferr := json.find(shell, sp.prefix, .Json, {stop_early = true}, v_opts, opts.allocator); ferr != nil || ans.outcome != .Found || ans.kind != .Array || ans.lo != at {
		return {}, false
	}

	Comma_Job :: struct {
		inner:           []u8,
		chunks:          []Spine_Quote_Chunk,
		close_chunk:     int,
		close_inner_off: int,
	}
	cjob := Comma_Job{inner = inner, chunks = qchunks[:close_chunk + 1], close_chunk = close_chunk, close_inner_off = close_inner_off}
	tape.fan_each(opts.runner, close_chunk + 1, proc(arg: rawptr, k: int) {
		j := (^Comma_Job)(arg)
		c := &j.chunks[k]
		hi := j.close_inner_off if k == j.close_chunk else c.hi
		if hi <= c.lo {
			c.comma_rel, c.trailing_commas = -1, 0
			return
		}
		c.comma_rel, c.trailing_commas = spine_scan_commas(j.inner[c.lo:hi], c.entry_quoted, c.entry_depth)
	}, &cjob)

	parts: [ops_build.MAX_RECORD_CHUNKS + 1]Spine_Part
	np, prev := 0, int(at) + 1
	acc, pending_elem := u64(0), u64(0)
	for k in 0 ..= close_chunk {
		if crel := qchunks[k].comma_rel; crel >= 0 {
			cabs := int(at + 1) + qchunks[k].lo + crel
			parts[np] = {lo = prev, hi = cabs, base_idx = acc}
			acc += pending_elem + 1
			np += 1
			prev = cabs + 1
			pending_elem = qchunks[k].trailing_commas
		}
	}
	parts[np] = {lo = prev, hi = abs_close, base_idx = acc}
	np += 1
	if np < 2 {
		return {}, false
	}

	use_partial := dec.entry.supports_scan && sp.each_demand.mode == .Partial
	dem, dem_owned, derr := prepare_demand(&sp.each_demand if use_partial else nil, dec.keep_facts || !use_partial, opts.allocator)
	if derr != nil {
		return {err = .No_Memory, read_err = derr}, true
	}
	defer if dem_owned {
		tape.destroy_demand(&dem)
	}

	slots, serr := make([]Coarse_Chunk_Slot, np, opts.allocator)
	if serr != nil {
		return {err = .No_Memory, read_err = serr}, true
	}
	defer {
		for &s in slots {
			coarse_chunk_slot_destroy(&s)
		}
		delete(slots, opts.allocator)
	}

	is_length := sp.kind == .Length && sp.has_each
	is_collect := sp.kind == .Collect
	collect_compact := is_collect && opts.spine_collect_compact && !sp.has_tail

	Spine_Eval_Job :: struct {
		dec:             ^Decision,
		sp:              ^query.Per_Element_Split,
		src:             []u8,
		dem:             ^tape.Demand,
		clear_partial:   bool,
		opts:            ^Exec_Options,
		parts:           []Spine_Part,
		slots:           []Coarse_Chunk_Slot,
		is_length:       bool,
		is_collect:      bool,
		collect_compact: bool,
		alloc_wrap:      Locked_Allocator,
	}

	job := Spine_Eval_Job{
		dec             = dec,
		sp              = sp,
		src             = src,
		dem             = &dem,
		clear_partial   = !use_partial,
		opts            = opts,
		parts           = parts[:np],
		slots           = slots,
		is_length       = is_length,
		is_collect      = is_collect,
		collect_compact = collect_compact,
	}
	locked_alloc_init(&job.alloc_wrap, opts.allocator)

	Spine_Emit_Ctx :: struct {
		slot:            ^Coarse_Chunk_Slot,
		collect_compact: bool,
		store_slices:    bool,
	}

	spine_chunk_emit_fn :: proc(data: rawptr, bytes: []u8) -> bool {
		sc := (^Spine_Emit_Ctx)(data)
		slot := sc.slot
		if sc.collect_compact {
			trimmed := bytes[:len(bytes) - 1] if (len(bytes) > 0 && bytes[len(bytes) - 1] == '\n') else bytes
			if slot.item_count > 0 {
				if _, aerr := append(&slot.out_buf, ','); aerr != nil {
					slot.err, slot.read_err = .No_Memory, aerr
					return false
				}
			}
			if _, aerr := append(&slot.out_buf, ..trimmed); aerr != nil {
				slot.err, slot.read_err = .No_Memory, aerr
				return false
			}
			slot.item_count += 1
			slot.emitted_items += 1
			return true
		}
		off := len(slot.out_buf)
		if _, aerr := append(&slot.out_buf, ..bytes); aerr != nil {
			slot.err, slot.read_err = .No_Memory, aerr
			return false
		}
		if sc.store_slices && !slot_push_slice(slot, off, len(bytes)) {
			return false
		}
		slot.emitted_items += 1
		return true
	}

	run_part :: proc(arg: rawptr, k: int) {
		j := (^Spine_Eval_Job)(arg)
		lalloc := locked_allocator(&j.alloc_wrap)
		slot := &j.slots[k]
		p := j.parts[k]
		plen := p.hi - p.lo
		store_slices := (j.is_collect && !j.collect_compact) || (!j.is_length && !j.is_collect && !j.opts.coalesce_emit)
		if !j.is_length {
			slot.out_buf = make([dynamic]u8, 0, max(plen * (2 if j.opts.fast_json_each == .Pretty2 else 1), 256), lalloc)
		}
		if store_slices {
			slot.offs.allocator, slot.lens.allocator = lalloc, lalloc
		}

		wrapped, werr := make([]u8, plen + 2, lalloc)
		if werr != nil {
			slot.err, slot.read_err = .No_Memory, werr
			return
		}
		defer delete(wrapped, lalloc)
		wrapped[0] = '['
		copy(wrapped[1:], j.src[p.lo:p.hi])
		wrapped[len(wrapped) - 1] = ']'

		lr := json.records_open(wrapped, .Elements, .Json, {dups = j.opts.read.dups})
		defer tape.destroy_records(&lr)
		if lr.err != nil {
			slot.read_err_fallback = true
			return
		}

		wctx := j.opts.eval_each_ctx
		has_wctx := false
		defer if has_wctx && j.opts.workers.fini != nil {
			j.opts.workers.fini(j.opts.eval_each_ctx, k, wctx)
		}

		sc := Spine_Emit_Ctx{slot = slot, collect_compact = j.collect_compact, store_slices = store_slices}
		local_idx := u64(0)
		out_recs: [RECORD_BATCH_SIZE]tape.Record = ---
		docs: [RECORD_BATCH_SIZE]tape.Document = ---
		for {
			n := json.records_scan(&lr, j.dem, out_recs[:], docs[:], {}, lalloc)
			if n == 0 {
				break
			}
			for i in 0 ..< n {
				r_info := out_recs[i]
				if r_info.err != nil {
					slot.read_err_fallback = true
					return
				}
				slot.records += 1
				raw := record_slice(wrapped, r_info)
				rec_idx := p.base_idx + local_idx
				local_idx += 1

				if !j.is_length && !j.sp.has_each && can_fast_json_doc(j.dec, &docs[i], j.opts.fast_json_each, j.opts) {
					off := len(slot.out_buf)
					if j.collect_compact && slot.item_count > 0 {
						append(&slot.out_buf, ',')
					}
					if append_fast_json_doc(&slot.out_buf, &docs[i], .Compact if j.is_collect else j.opts.fast_json_each, !j.is_collect) {
						if j.collect_compact {
							slot.item_count += 1
						} else if store_slices && !slot_push_slice(slot, off, len(slot.out_buf) - off) {
							return
						}
						slot.emitted_items += 1
						continue
					}
					resize(&slot.out_buf, off)
				}

				if !has_wctx {
					if j.opts.workers.init != nil {
						wctx = j.opts.workers.init(j.opts.eval_each_ctx, k, lalloc)
					}
					has_wctx = true
				}
				doc_val := docs[i]
				if j.clear_partial && doc_val.partial != nil {
					doc_val.partial = nil
				}
				meta := Record_Meta{
					file_index   = j.opts.file_index,
					file_path    = j.opts.file_path,
					record_index = rec_idx,
					lo           = u64(p.lo) + r_info.lo - 1,
					hi           = u64(p.lo) + r_info.hi - 1,
					raw_bytes    = raw,
				}
				if j.is_length {
					cnt, cerr := j.opts.eval_each_count(wctx, &doc_val, meta)
					if cerr != .None {
						slot.err, slot.tainted = cerr, cerr == .Tainted
						return
					}
					slot.item_count += cnt
					continue
				}
				eval_err := j.opts.eval_each(wctx, &doc_val, meta, Emitter{fn = spine_chunk_emit_fn, data = &sc})
				if slot.err == .No_Memory {
					return
				}
				if eval_err != .None {
					slot.err, slot.tainted = eval_err, eval_err == .Tainted
					return
				}
			}
		}
		if lr.err != nil || slot.records == 0 {
			slot.read_err_fallback = true
		}
	}

	tape.fan_each(opts.runner, np, run_part, &job)

	for &slot in slots {
		if slot.err == .No_Memory {
			return {err = .No_Memory, read_err = slot.read_err}, true
		}
		if slot.read_err_fallback {
			return {}, false
		}
	}

	if is_length || is_collect {
		total_count := u64(0)
		total_items := 0
		for &slot in slots {
			res.records += slot.records
			if slot.err != .None {
				if slot.err == .Tainted && (opts.rerun_whole_on_taint || dec.rerun_safe) {
					return spine_fallback_whole(dec, src, opts, reran = true), true
				}
				res.err, res.tainted = slot.err, slot.tainted
				return res, true
			}
			total_count += slot.item_count
			if is_collect && !collect_compact {
				total_items += len(slot.offs)
			}
		}
		if is_length {
			finish_spine_length(total_count, opts, &res)
			return res, true
		}
		if collect_compact {
			open_b, comma_b, close_nl := [1]u8{'['}, [1]u8{','}, [2]u8{']', '\n'}
			if !emit_bytes(opts.emit, open_b[:]) {
				res.err = .Stopped
				return res, true
			}
			need_sep := false
			for &slot in slots {
				if slot.item_count == 0 {
					continue
				}
				if (need_sep && !emit_bytes(opts.emit, comma_b[:])) || (len(slot.out_buf) > 0 && !emit_bytes(opts.emit, slot.out_buf[:])) {
					res.err = .Stopped
					return res, true
				}
				need_sep = true
			}
			if !emit_bytes(opts.emit, close_nl[:]) {
				res.err = .Stopped
				return res, true
			}
			res.emitted = 1
			return res, true
		}

		item_outputs, io_err := make([][]u8, total_items, opts.allocator)
		if io_err != nil {
			res.err, res.read_err = .No_Memory, io_err
			return res, true
		}
		defer delete(item_outputs, opts.allocator)
		idx := 0
		for &slot in slots {
			for k in 0 ..< len(slot.offs) {
				item_outputs[idx] = slot.out_buf[slot.offs[k]:][:slot.lens[k]]
				idx += 1
			}
		}
		finish_spine_collect(dec, src, item_outputs, opts, &res)
		return res, true
	}

	// `.Stream`: emit chunks in deterministic order.
	for &slot in slots {
		res.records += slot.records
		if opts.coalesce_emit {
			if len(slot.out_buf) > 0 {
				if !emit_bytes(opts.emit, slot.out_buf[:]) {
					res.err = .Stopped
					return res, true
				}
				res.emitted += slot.emitted_items
			}
		} else {
			for k in 0 ..< len(slot.offs) {
				if !emit_bytes(opts.emit, slot.out_buf[slot.offs[k]:][:slot.lens[k]]) {
					res.err = .Stopped
					return res, true
				}
				res.emitted += 1
			}
		}
		if slot.err != .None {
			if slot.err == .Tainted && res.emitted == 0 && (opts.rerun_whole_on_taint || dec.rerun_safe) {
				return spine_fallback_whole(dec, src, opts, reran = true), true
			}
			res.err, res.read_err, res.write_err = slot.err, slot.read_err, slot.write_err
			res.tainted ||= slot.tainted
			return res, true
		}
	}
	return res, true
}
