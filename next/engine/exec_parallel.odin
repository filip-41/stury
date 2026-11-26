package engine

import "base:runtime"
import "core:sync"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
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
slot_emit_fn :: proc(data: rawptr, bytes: []u8) -> bool {
	sb := (^Slot_Buffer)(data)
	off := len(sb.chunks)
	if _, aerr := append(&sb.chunks, ..bytes); aerr != nil {
		sb.err = .No_Memory
		sb.read_err = aerr
		return false
	}
	if _, aerr := append(&sb.offs, off); aerr != nil {
		resize(&sb.chunks, off)
		sb.err = .No_Memory
		sb.read_err = aerr
		return false
	}
	if _, aerr := append(&sb.lens, len(bytes)); aerr != nil {
		resize(&sb.chunks, off)
		pop(&sb.offs)
		sb.err = .No_Memory
		sb.read_err = aerr
		return false
	}
	return true
}

@(private)
drain_slot_chunks :: proc(sb: ^Slot_Buffer, emit: Emitter, total: ^Exec_Result) -> bool {
	for idx in 0 ..< len(sb.offs) {
		off := sb.offs[idx]
		sz := sb.lens[idx]
		if off < 0 || sz < 0 || off + sz > len(sb.chunks) {
			total.err = .No_Memory
			return false
		}
		chunk := sb.chunks[off:][:sz]
		if !emit_bytes(emit, chunk) {
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
		parent_alloc: runtime.Allocator,
		alloc_lock:   sync.Mutex,
	}

	locked_alloc_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
		j := (^File_Job)(data)
		sync.mutex_guard(&j.alloc_lock)
		return j.parent_alloc.procedure(j.parent_alloc.data, mode, size, alignment, old_ptr, old_size, loc)
	}

	locked_scratch_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
		j := (^File_Job)(data)
		sync.mutex_guard(&j.alloc_lock)
		return j.opts.read.scratch.procedure(j.opts.read.scratch.data, mode, size, alignment, old_ptr, old_size, loc)
	}

	job := File_Job {
		plan         = plan,
		files        = files,
		route_opts   = r_opts,
		opts         = opts,
		slots        = slots,
		parent_alloc = alloc,
	}

	run_file :: proc(arg: rawptr, k: int) {
		j := (^File_Job)(arg)
		lalloc := runtime.Allocator{procedure = locked_alloc_proc, data = j}
		sb := &j.slots[k]
		sb.chunks.allocator = lalloc
		sb.offs.allocator = lalloc
		sb.lens.allocator = lalloc

		wctx := j.opts.eval_ctx
		if j.opts.workers.init != nil {
			wctx = j.opts.workers.init(j.opts.eval_ctx, k, lalloc)
		}
		defer if j.opts.workers.fini != nil {
			j.opts.workers.fini(j.opts.eval_ctx, k, wctx)
		}

		f := j.files[k]
		f_route := j.route_opts
		f_route.file_count = 1
		f_route.runner = nil // runner must never be re-entered inside a worker task
		f_route.serial_eval_ctx = false
		f_route.input_bytes = len(f.src)
		dec := decide(j.plan, f.spec, f.framing, f_route)

		f_opts := j.opts
		f_opts.runner = nil
		f_opts.workers = {}
		f_opts.eval_ctx = wctx
		f_opts.file_index = k
		f_opts.file_path = f.path
		f_opts.allocator = lalloc
		if j.opts.read.scratch.procedure != nil {
			f_opts.read.scratch = runtime.Allocator{procedure = locked_scratch_proc, data = j}
		}
		f_opts.emit = Emitter{fn = slot_emit_fn, data = sb}

		f_res := execute(j.plan, &dec, f.src, f_opts)
		if sb.err == .No_Memory {
			f_res.err = .No_Memory
			f_res.read_err = sb.read_err
		}
		sb.res = f_res
	}

	hook.fan_each(runner, len(files), run_file, &job)

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
			total.err = sb.res.err
			total.read_err = sb.res.read_err
			total.write_err = sb.res.write_err
			return total
		}
	}
	return total
}

// Evaluates a scanned batch of records across worker threads while preserving output order
// and enforcing `prior_emitted + res.emitted == 0` on taint recovery.
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
		src:           []u8,
		out_recs:      []tape.Record,
		docs:          []tape.Document,
		clear_partial: bool,
		base_rec_idx:  u64,
		opts:          ^Exec_Options,
		slots:         []Slot_Buffer,
		alloc_lock:    sync.Mutex,
	}

	locked_alloc_fn :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
		j := (^Batch_Job)(data)
		sync.mutex_guard(&j.alloc_lock)
		return j.opts.allocator.procedure(j.opts.allocator.data, mode, size, alignment, old_ptr, old_size, loc)
	}

	job := Batch_Job {
		src           = src,
		out_recs      = out_recs,
		docs          = docs,
		clear_partial = clear_partial,
		base_rec_idx  = base_rec_idx,
		opts          = opts,
		slots         = slots,
	}

	worker_fn :: proc(arg: rawptr, k: int) {
		j := (^Batch_Job)(arg)
		r_info := j.out_recs[k]
		if r_info.err != nil {
			return
		}
		lalloc := runtime.Allocator{procedure = locked_alloc_fn, data = j}
		sb := &j.slots[k]
		sb.chunks.allocator = lalloc
		sb.offs.allocator = lalloc
		sb.lens.allocator = lalloc

		wctx := j.opts.eval_ctx
		if j.opts.workers.init != nil {
			wctx = j.opts.workers.init(j.opts.eval_ctx, k, lalloc)
		}
		defer if j.opts.workers.fini != nil {
			j.opts.workers.fini(j.opts.eval_ctx, k, wctx)
		}

		doc_val := j.docs[k]
		if j.clear_partial && doc_val.partial != nil {
			doc_val.partial = nil
		}
		meta := make_record_meta(j.opts, j.base_rec_idx + u64(k), r_info, record_slice(j.src, r_info))
		ret_err := j.opts.eval(wctx, &doc_val, meta, Emitter{fn = slot_emit_fn, data = sb})
		if sb.err == .None {
			sb.err = ret_err
		}
		if sb.err == .Tainted {
			sb.tainted = true
		}
	}

	hook.fan_each(opts.runner, n, worker_fn, &job)

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
		raw := record_slice(src, r_info)
		res.records += 1
		sb := &slots[i]
		if sb.err == .No_Memory {
			res.err = .No_Memory
			res.read_err = sb.read_err
			return res
		}
		if sb.tainted {
			can_rerun := allow_taint_rerun && (prior_emitted + res.emitted) == 0 && (opts.rerun_whole_on_taint || dec.rerun_safe)
			if can_rerun {
				meta := make_record_meta(opts, base_rec_idx + u64(i), r_info, raw)
				if can_build_single_record(dec, raw) {
					sub := exec_single_record_whole(dec, raw, meta, opts)
					res.emitted += sub.emitted
					res.reran_whole = true
					if sub.err != .None {
						res.err = sub.err
						res.read_err = sub.read_err
						return res
					}
					continue
				}
				if dec.entry.family == .Dsv && len(raw) > 0 {
					sub := exec_single_dsv_row_from_raw(dec, src, dsv_header_end, raw, &dsv_row_buf, meta, opts)
					res.emitted += sub.emitted
					res.reran_whole = true
					if sub.err != .None {
						res.err = sub.err
						res.read_err = sub.read_err
						res.write_err = sub.write_err
						return res
					}
					continue
				}
			}
			res.err = .Tainted
			res.tainted = true
			return res
		}
		if !drain_slot_chunks(sb, opts.emit, &res) {
			return res
		}
		if sb.err != .None {
			res.err = sb.err
			res.read_err = sb.read_err
			res.write_err = sb.write_err
			return res
		}
	}
	return res
}

// Parallel whole-record builder + evaluator for framed streams whose `dups` policy requires full builds.
@(private)
eval_record_batch_whole_parallel :: proc(
	dec: ^Decision,
	src: []u8,
	out_recs: []tape.Record,
	rec_ro: tape.Options,
	base_rec_idx: u64,
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

	Whole_Job :: struct {
		dec:          ^Decision,
		src:          []u8,
		out_recs:     []tape.Record,
		rec_ro:       tape.Options,
		base_rec_idx: u64,
		opts:         ^Exec_Options,
		slots:        []Slot_Buffer,
		alloc_lock:   sync.Mutex,
	}

	locked_alloc_fn :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
		j := (^Whole_Job)(data)
		sync.mutex_guard(&j.alloc_lock)
		return j.opts.allocator.procedure(j.opts.allocator.data, mode, size, alignment, old_ptr, old_size, loc)
	}

	locked_scratch_fn :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
		j := (^Whole_Job)(data)
		sync.mutex_guard(&j.alloc_lock)
		return j.rec_ro.scratch.procedure(j.rec_ro.scratch.data, mode, size, alignment, old_ptr, old_size, loc)
	}

	job := Whole_Job {
		dec          = dec,
		src          = src,
		out_recs     = out_recs,
		rec_ro       = rec_ro,
		base_rec_idx = base_rec_idx,
		opts         = opts,
		slots        = slots,
	}

	worker_fn :: proc(arg: rawptr, k: int) {
		j := (^Whole_Job)(arg)
		r_info := j.out_recs[k]
		if r_info.err != nil {
			return
		}
		lalloc := runtime.Allocator{procedure = locked_alloc_fn, data = j}
		sb := &j.slots[k]
		sb.chunks.allocator = lalloc
		sb.offs.allocator = lalloc
		sb.lens.allocator = lalloc

		w_ro := j.rec_ro
		w_ro.runner = nil
		if j.rec_ro.scratch.procedure != nil {
			w_ro.scratch = runtime.Allocator{procedure = locked_scratch_fn, data = j}
		}

		raw := record_slice(j.src, r_info)
		doc, berr := build(raw, j.dec.spec, w_ro, lalloc)
		if berr != nil {
			sb.err = .No_Memory if is_alloc_err(berr) else .Read_Error
			sb.read_err = berr
			return
		}
		defer tape.destroy(&doc)

		wctx := j.opts.eval_ctx
		if j.opts.workers.init != nil {
			wctx = j.opts.workers.init(j.opts.eval_ctx, k, lalloc)
		}
		defer if j.opts.workers.fini != nil {
			j.opts.workers.fini(j.opts.eval_ctx, k, wctx)
		}

		meta := make_record_meta(j.opts, j.base_rec_idx + u64(k), r_info, raw)
		ret_err := j.opts.eval(wctx, &doc, meta, Emitter{fn = slot_emit_fn, data = sb})
		if sb.err == .None {
			sb.err = ret_err
		}
	}

	hook.fan_each(opts.runner, n, worker_fn, &job)

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
			res.err = .No_Memory
			res.read_err = sb.read_err
			return res
		}
		if sb.err == .Read_Error && sb.read_err != nil {
			bad := r_info
			bad.err = sb.read_err
			if !handle_bad_record(opts, src, bad, &res) {
				return res
			}
			continue
		}
		res.records += 1
		if !drain_slot_chunks(sb, opts.emit, &res) {
			return res
		}
		if sb.err != .None {
			res.err = sb.err
			res.read_err = sb.read_err
			res.write_err = sb.write_err
			return res
		}
	}
	return res
}

@(private = "file")
spine_fallback_whole :: proc(dec: ^Decision, src: []u8, opts: ^Exec_Options, reran := false) -> Exec_Result {
	if opts.eval == nil {
		return {err = .Failed}
	}
	wres := exec_whole(dec, src, opts)
	if reran {
		wres.reran_whole = true
	}
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

// Hint 1: `.Spine_Parallel` splits array elements reached by `prefix` across `opts.runner`,
// preserving strict element order cleanly. When `eval_each == nil` or fallback is needed, falls
// back to whole-document evaluation via `opts.eval` (returning `.Failed` if `opts.eval == nil`).
@(private)
exec_spine_parallel :: proc(plan: ^query.Plan, dec: ^Decision, src: []u8, opts: ^Exec_Options) -> Exec_Result {
	sp := &plan.hints.split
	if dups_needs_build(dec.entry, opts.read.dups) || opts.eval_each == nil {
		return spine_fallback_whole(dec, src, opts)
	}
	if opts.runner == nil || opts.runner.threads <= 0 || len(src) < SPINE_PARALLEL_FROM {
		return spine_fallback(plan, dec, src, opts)
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

	ro := build_tape_opts(opts, allow_parallel = false)
	recs, open_err_res, open_ok := open_framed_records(src, dec.spec, .Elements, ro, sp.prefix, opts)
	if !open_ok {
		if open_err_res.err == .No_Memory {
			return open_err_res
		}
		return spine_fallback_whole(dec, src, opts)
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
	each_opts.eval = opts.eval_each
	each_opts.eval_ctx = opts.eval_each_ctx
	ce := Collect_Emit{list = &collected, alloc = opts.allocator}
	if sp.kind == .Collect {
		each_opts.emit = Emitter{fn = collect_emit_fn, data = &ce}
	}

	can_par_each := can_parallel_eval(opts.workers.init != nil, opts.eval_each_ctx, true, opts.eval_ctx_thread_safe)
	out_recs: [RECORD_BATCH_SIZE]tape.Record
	docs: [RECORD_BATCH_SIZE]tape.Document
	res: Exec_Result
	downstream_emitted := u64(0)

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
			sub: Exec_Result
			if can_par_each && valid_n > 1 {
				sub = eval_record_batch_parallel(
					dec,
					src,
					out_recs[:valid_n],
					docs[:valid_n],
					!use_partial,
					res.records,
					downstream_emitted,
					sp.kind == .Stream,
					0,
					&each_opts,
				)
			} else {
				sub = eval_spine_batch_serial(
					dec,
					src,
					out_recs[:valid_n],
					docs[:valid_n],
					!use_partial,
					res.records,
					downstream_emitted,
					sp.kind == .Stream,
					&each_opts,
				)
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
				res.err = sub.err
				res.read_err = sub.read_err
				res.write_err = sub.write_err
				return res
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
		ans, ferr := find(src, sp.prefix, dec.spec, {stop_early = true}, build_tape_opts(opts, false), opts.allocator)
		if ferr != nil || ans.outcome != .Found || ans.kind != .Array {
			return spine_fallback_whole(dec, src, opts)
		}
	}
	if sp.kind == .Collect && opts.spine_collect != nil {
		doc_w: tape.Document
		doc_ptr: ^tape.Document = nil
		has_doc := false
		if opts.spine_collect_needs_doc {
			ro_w := build_tape_opts(opts, allow_parallel = false)
			wdoc, werr := build(src, dec.spec, ro_w, opts.allocator)
			if werr != nil {
				res.err = .No_Memory if is_alloc_err(werr) else .Read_Error
				res.read_err = werr
				return res
			}
			doc_w = wdoc
			has_doc = true
			doc_ptr = &doc_w
		}
		defer if has_doc {
			tape.destroy(&doc_w)
		}
		g := Guard_Emit{inner = opts.emit}
		cerr := opts.spine_collect(opts.eval_ctx, doc_ptr, collected[:], Emitter{fn = guard_emit_fn, data = &g})
		res.emitted += g.emitted
		if g.stopped && cerr == .None {
			cerr = .Stopped
		}
		res.err = cerr
		return res
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
		g := Guard_Emit{inner = each_opts.emit}
		eval_err := each_opts.eval(each_opts.eval_ctx, &doc_val, meta, Emitter{fn = guard_emit_fn, data = &g})
		res.emitted += g.emitted
		if eval_err == .Tainted {
			if allow_taint_rerun && (prior_emitted + res.emitted) == 0 && (each_opts.rerun_whole_on_taint || dec.rerun_safe) && can_build_single_record(dec, raw) {
				sub := exec_single_record_whole(dec, raw, meta, each_opts)
				res.emitted += sub.emitted
				res.reran_whole = true
				if sub.err != .None {
					res.err = sub.err
					res.read_err = sub.read_err
					return res
				}
				continue
			}
			res.err = .Tainted
			res.tainted = true
			return res
		}
		if g.stopped && eval_err == .None {
			eval_err = .Stopped
		}
		if eval_err != .None {
			res.err = eval_err
			return res
		}
	}
	return res
}
