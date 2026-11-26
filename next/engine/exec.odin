package engine

import "base:runtime"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/query"

// Frontend-agnostic execution engine dispatching every `Route_Kind`:
// `.Whole`, `.Scan` (with strict taint guard + opt-in 0-emit rerun), `.Records_Serial`,
// `.Records_Parallel`, `.Spine_Parallel` (`exec_parallel.odin`),
// `.Projection_Direct` (`exec_direct.odin`), `.Conditional_Whole` (`exec_cond.odin`),
// and `.Files_Parallel` (`exec_parallel.odin`).

RECORD_BATCH_SIZE :: 256

Exec_Error :: enum u8 {
	None,
	Stopped,
	Failed,
	Halted,
	Tainted,
	Read_Error,
	Write_Error,
	Unsupported,
	No_Memory,
}

Record_Meta :: struct {
	file_index:   int,
	file_path:    string,
	record_index: u64,
	lo, hi:       u64,
	raw_bytes:    []u8,
	key:          tape.Token,
}

Emit_Proc :: #type proc(ctx: rawptr, bytes: []u8) -> bool

Emitter :: struct {
	fn:   Emit_Proc,
	data: rawptr,
}

emit_bytes :: #force_inline proc(e: Emitter, bytes: []u8) -> bool {
	if e.fn == nil {
		return true
	}
	return e.fn(e.data, bytes)
}

// Evaluates a prepared document (`Whole` or partial `Scan`) and emits formatted outputs via `emit`.
Eval_Doc_Proc :: #type proc(ctx: rawptr, doc: ^tape.Document, meta: Record_Meta, emit: Emitter) -> Exec_Error

// Evaluates only a predicate over a partial document built from `pred_demand` (`Conditional_Whole`).
Pred_Doc_Proc :: #type proc(ctx: rawptr, doc: ^tape.Document, meta: Record_Meta) -> (matched: bool, err: Exec_Error)

// Optional combiner callback for Hint 1 `.Collect` (`[.prefix[] | each] | tail`).
// `doc` is nil unless `Exec_Options.spine_collect_needs_doc` is set.
Spine_Collect_Proc :: #type proc(ctx: rawptr, doc: ^tape.Document, item_outputs: [][]u8, emit: Emitter) -> Exec_Error

// Bad-record notification callback during record iteration; return false to abort.
Bad_Record_Proc :: #type proc(ctx: rawptr, bad: tape.Bad_Record) -> bool

// Per-worker frontend state lifecycle hooks for parallel routes.
Worker_Hooks :: struct {
	init: proc(parent_ctx: rawptr, worker_idx: int, alloc: runtime.Allocator) -> rawptr,
	fini: proc(parent_ctx: rawptr, worker_idx: int, worker_ctx: rawptr),
}

Direct_Output :: enum u8 {
	Json,
	Csv,
	Tsv,
}

File_Input :: struct {
	path:    string,
	src:     []u8,
	spec:    Spec,
	framing: Framing,
}

Exec_Options :: struct {
	eval:                    Eval_Doc_Proc, // required for fallback from Hint 1 / Hint 3 when sub-route cannot handle
	eval_ctx:                rawptr,
	eval_each:               Eval_Doc_Proc,      // element evaluator for Hint 1 (nil falls back to whole-doc `eval`)
	eval_each_ctx:           rawptr,
	pred_eval:               Pred_Doc_Proc,      // optional predicate evaluator when `Simple_Compare` not used
	pred_ctx:                rawptr,
	spine_collect:           Spine_Collect_Proc, // optional tail combiner for Hint 1 `.Collect`
	on_bad_record:           Bad_Record_Proc,
	bad_ctx:                 rawptr,
	workers:                 Worker_Hooks,
	emit:                    Emitter,
	read:                    tape.Options,
	runner:                  ^tape.Runner,
	direct_out:              Direct_Output,
	direct_csv_header:       bool,
	skip_bad:                bool,
	max_bytes:               u64,
	rerun_whole_on_taint:    bool, // opt-in caller rerun ONLY when `emitted == 0`
	eval_ctx_thread_safe:    bool, // set true only when non-nil `eval_ctx` is safe without `workers.init`
	spine_collect_needs_doc: bool, // when true, `.Collect` parses root document to pass to `spine_collect`
	file_index:              int,
	file_path:               string,
	allocator:               runtime.Allocator,
}

Exec_Result :: struct {
	err:         Exec_Error,
	read_err:    tape.Error,
	write_err:   write.Error,
	emitted:     u64,
	records:     u64,
	bad_records: u64,
	tainted:     bool,
	reran_whole: bool,
}

// Executes a single input `src` according to `decision` and `plan`.
execute :: proc(
	plan: ^query.Plan,
	decision: ^Decision,
	src: []u8,
	opts := Exec_Options{},
) -> Exec_Result {
	alloc := opts.allocator if opts.allocator.procedure != nil else context.allocator
	eff := opts
	eff.allocator = alloc

	switch decision.kind {
	case .Whole:
		return exec_whole(decision, src, &eff)
	case .Scan:
		return exec_scan(plan, decision, src, &eff)
	case .Records_Serial:
		return exec_records(plan, decision, src, &eff, parallel = false)
	case .Records_Parallel:
		return exec_records(plan, decision, src, &eff, parallel = true)
	case .Spine_Parallel:
		return exec_spine_parallel(plan, decision, src, &eff)
	case .Projection_Direct:
		return exec_projection_direct(plan, decision, src, &eff)
	case .Conditional_Whole:
		return exec_conditional_whole(plan, decision, src, &eff)
	case .Files_Parallel:
		return {err = .Unsupported}
	}
	return {err = .Unsupported}
}

// Executes a batch of input files using `decide` + `execute`, dispatching across `opts.runner` when eligible.
execute_files :: proc(
	plan: ^query.Plan,
	files: []File_Input,
	route_opts := Route_Options{},
	opts := Exec_Options{},
) -> Exec_Result {
	if len(files) == 0 {
		return {}
	}
	alloc := opts.allocator if opts.allocator.procedure != nil else context.allocator
	parallel_eval_ok := can_parallel_eval(opts.workers.init != nil, opts.eval_ctx, opts.eval != nil, opts.eval_ctx_thread_safe) &&
		can_parallel_eval(false, opts.pred_ctx, opts.pred_eval != nil, opts.eval_ctx_thread_safe) &&
		can_parallel_eval(false, opts.eval_each_ctx, opts.eval_each != nil, opts.eval_ctx_thread_safe)

	if len(files) == 1 {
		r_opts := route_opts
		r_opts.file_count = 1
		r_opts.input_bytes = len(files[0].src)
		r_opts.serial_eval_ctx = r_opts.serial_eval_ctx || !parallel_eval_ok
		d := decide(plan, files[0].spec, files[0].framing, r_opts)
		f_opts := opts
		f_opts.file_index = 0
		f_opts.file_path = files[0].path
		f_opts.allocator = alloc
		if f_opts.runner == nil {
			f_opts.runner = r_opts.runner
		}
		return execute(plan, &d, files[0].src, f_opts)
	}

	r_opts := route_opts
	r_opts.file_count = len(files)
	r_opts.serial_eval_ctx = r_opts.serial_eval_ctx || !parallel_eval_ok
	if r_opts.runner == nil {
		r_opts.runner = opts.runner
	}
	first_dec := decide(plan, files[0].spec, files[0].framing, r_opts)

	runner := r_opts.runner
	if !first_dec.file_parallel || !parallel_eval_ok || runner == nil || runner.threads <= 0 {
		total: Exec_Result
		for f, idx in files {
			f_route := r_opts
			f_route.file_count = 1
			f_route.runner = runner
			f_route.input_bytes = len(f.src)
			dec := decide(plan, f.spec, f.framing, f_route)
			f_opts := opts
			f_opts.file_index = idx
			f_opts.file_path = f.path
			f_opts.allocator = alloc
			f_opts.runner = runner
			sub := execute(plan, &dec, f.src, f_opts)
			merge_result(&total, sub)
			if sub.err != .None {
				return total
			}
		}
		return total
	}

	return execute_files_parallel(plan, files, r_opts, opts, runner, alloc)
}

@(private)
can_parallel_eval :: proc "contextless" (has_worker_hooks: bool, ctx: rawptr, has_eval, eval_ctx_thread_safe: bool) -> bool {
	if !has_eval {
		return true
	}
	return has_worker_hooks || ctx == nil || eval_ctx_thread_safe
}

@(private)
merge_result :: proc "contextless" (dst: ^Exec_Result, src: Exec_Result) {
	dst.emitted += src.emitted
	dst.records += src.records
	dst.bad_records += src.bad_records
	dst.tainted ||= src.tainted
	dst.reran_whole ||= src.reran_whole
	if src.err != .None {
		dst.err = src.err
		dst.read_err = src.read_err
		dst.write_err = src.write_err
	}
}

@(private)
build_tape_opts :: proc "contextless" (opts: ^Exec_Options, allow_parallel: bool) -> tape.Options {
	ro := opts.read
	if allow_parallel && opts.runner != nil && opts.runner.threads > 0 {
		ro.runner = opts.runner
	} else {
		ro.runner = nil
	}
	return ro
}

@(private)
Guard_Emit :: struct {
	inner:   Emitter,
	emitted: u64,
	stopped: bool,
}

@(private)
guard_emit_fn :: proc(data: rawptr, bytes: []u8) -> bool {
	g := (^Guard_Emit)(data)
	ok := emit_bytes(g.inner, bytes)
	if ok {
		g.emitted += 1
	} else {
		g.stopped = true
	}
	return ok
}

// Opens framed records cleanly with `skip_bad`, `max_bytes`, and initial `r.err` validation.
@(private)
open_framed_records :: proc(
	src: []u8,
	spec: Spec,
	tf: tape.Framing,
	ro: tape.Options,
	path: []tape.Step,
	opts: ^Exec_Options,
) -> (
	recs: ^tape.Records,
	err_res: Exec_Result,
	ok: bool,
) {
	r, oerr := records_open(src, spec, tf, ro, path, opts.allocator)
	if oerr != nil {
		err := Exec_Error.No_Memory if is_alloc_err(oerr) else .Read_Error
		return nil, {err = err, read_err = oerr}, false
	}
	if r == nil {
		return nil, {err = .Unsupported}, false
	}
	r.skip_bad = opts.skip_bad
	r.max_bytes = opts.max_bytes
	if r.err != nil {
		r_err := r.err
		tape.destroy_records(r)
		return nil, {err = .Read_Error, read_err = r_err}, false
	}
	return r, {}, true
}

@(private)
is_alloc_err :: proc "contextless" (e: tape.Error) -> bool {
	_, is_a := e.(runtime.Allocator_Error)
	return is_a
}

// Handles per-record error cleanly: only skips syntax faults (`tape.Fault`), never budget/OOM/option errors.
@(private)
handle_bad_record :: proc(opts: ^Exec_Options, src: []u8, r_info: tape.Record, res: ^Exec_Result) -> bool {
	raw := record_slice(src, r_info)
	res.records += 1
	res.bad_records += 1
	f, is_fault := r_info.err.(tape.Fault)
	skippable := is_fault && f.rules != &tape.RECORDS_RULES
	cont := opts.skip_bad && skippable
	if skippable && opts.on_bad_record != nil {
		cont = opts.on_bad_record(opts.bad_ctx, tape.Bad_Record{lo = r_info.lo, hi = r_info.hi, err = r_info.err, text = raw})
	}
	if !cont {
		res.err = .No_Memory if is_alloc_err(r_info.err) else .Read_Error
		res.read_err = r_info.err
		return false
	}
	return true
}

// Builds a `tape.Demand` with desired `facts` setting if the source demand differs (or returns borrowed `&s.demand`).
@(private)
prepare_demand :: proc(s: ^query.Source_Demand, keep_facts: bool, alloc: runtime.Allocator) -> (dem: tape.Demand, owned: bool, err: runtime.Allocator_Error) {
	if s == nil {
		whole_paths := [1][]tape.Step{{}}
		whole_grains := [1]tape.Grain{.Whole}
		d := tape.demand_of(whole_paths[:], whole_grains[:], nil, keep_facts, alloc) or_return
		return d, true, nil
	}
	if s.mode == .None {
		d := tape.demand_of(nil, nil, nil, keep_facts, alloc) or_return
		return d, true, nil
	}
	if s.mode == .Partial {
		if !keep_facts || s.demand.facts {
			return s.demand, false, nil
		}
		raw_steps := make([][]tape.Step, len(s.paths), alloc) or_return
		grains := make([]tape.Grain, len(s.paths), alloc) or_return
		limits := make([]int, len(s.paths), alloc) or_return
		defer {
			delete(raw_steps, alloc)
			delete(grains, alloc)
			delete(limits, alloc)
		}
		for p, i in s.paths {
			raw_steps[i] = p.steps
			grains[i] = p.grain
			limits[i] = p.limit
		}
		d := tape.demand_of(raw_steps, grains, limits, true, alloc) or_return
		return d, true, nil
	}
	whole_paths := [1][]tape.Step{{}}
	whole_grains := [1]tape.Grain{.Whole}
	d := tape.demand_of(whole_paths[:], whole_grains[:], nil, true, alloc) or_return
	return d, true, nil
}

@(private)
make_record_meta :: proc "contextless" (opts: ^Exec_Options, idx: u64, r_info: tape.Record, raw: []u8) -> Record_Meta {
	return {
		file_index   = opts.file_index,
		file_path    = opts.file_path,
		record_index = idx,
		lo           = r_info.lo,
		hi           = r_info.hi,
		raw_bytes    = raw,
		key          = r_info.key,
	}
}

@(private)
dsv_header_end_of :: proc "contextless" (dec: ^Decision, ro: tape.Options, recs: ^tape.Records) -> u64 {
	if dec.entry.family != .Dsv {
		return 0
	}
	dopts, has_dsv := ro.format.(tape.Dsv_Options)
	if has_dsv && dopts.no_header {
		return 0
	}
	return recs.pos
}

@(private)
exec_whole :: proc(dec: ^Decision, src: []u8, opts: ^Exec_Options) -> Exec_Result {
	ro := build_tape_opts(opts, allow_parallel = true)
	doc, err := build(src, dec.spec, ro, opts.allocator)
	if err != nil {
		return {err = .No_Memory if is_alloc_err(err) else .Read_Error, read_err = err}
	}
	defer tape.destroy(&doc)

	meta := Record_Meta{file_index = opts.file_index, file_path = opts.file_path, lo = 0, hi = u64(len(src)), raw_bytes = src}
	if opts.eval == nil {
		return exec_emit_default_doc(&doc, opts.emit, opts.allocator)
	}
	g := Guard_Emit{inner = opts.emit}
	e := opts.eval(opts.eval_ctx, &doc, meta, Emitter{fn = guard_emit_fn, data = &g})
	if g.stopped && e == .None {
		e = .Stopped
	}
	return {err = e, emitted = g.emitted}
}

@(private)
exec_scan :: proc(plan: ^query.Plan, dec: ^Decision, src: []u8, opts: ^Exec_Options) -> Exec_Result {
	main := &plan.sources[.Main] if plan != nil else nil
	if !dec.entry.supports_scan || (main != nil && main.mode == .Whole) {
		return exec_whole(dec, src, opts)
	}
	ro := build_tape_opts(opts, allow_parallel = false)
	if dups_needs_build(dec.entry, ro.dups) {
		return exec_whole(dec, src, opts)
	}
	dem, dem_owned, derr := prepare_demand(main, dec.keep_facts, opts.allocator)
	if derr != nil {
		return {err = .No_Memory, read_err = derr}
	}
	defer if dem_owned {
		tape.destroy_demand(&dem)
	}

	doc, err := scan(src, &dem, dec.spec, {}, ro, opts.allocator)
	if err != nil {
		return {err = .No_Memory if is_alloc_err(err) else .Read_Error, read_err = err}
	}

	if opts.eval == nil {
		tape.destroy(&doc)
		return {err = .Unsupported}
	}

	meta := Record_Meta{file_index = opts.file_index, file_path = opts.file_path, lo = 0, hi = u64(len(src)), raw_bytes = src}
	g := Guard_Emit{inner = opts.emit}
	eval_err := opts.eval(opts.eval_ctx, &doc, meta, Emitter{fn = guard_emit_fn, data = &g})
	tape.destroy(&doc)

	if eval_err == .Tainted {
		// Guard contract (`analysis.md` §3): NEVER replay mid-stream once any output has been emitted!
		if g.emitted == 0 && (opts.rerun_whole_on_taint || dec.rerun_safe) {
			wres := exec_whole(dec, src, opts)
			wres.reran_whole = true
			return wres
		}
		return {err = .Tainted, emitted = g.emitted, tainted = true}
	}
	if g.stopped && eval_err == .None {
		eval_err = .Stopped
	}
	return {err = eval_err, emitted = g.emitted}
}

@(private)
exec_records :: proc(
	plan: ^query.Plan,
	dec: ^Decision,
	src: []u8,
	opts: ^Exec_Options,
	parallel: bool,
) -> Exec_Result {
	tf, framed := to_tape_framing(dec.framing)
	if !framed {
		return exec_scan(plan, dec, src, opts) if dec.demand_mode == .Partial else exec_whole(dec, src, opts)
	}
	ro := build_tape_opts(opts, allow_parallel = parallel && opts.runner != nil && opts.runner.threads > 0)
	if dups_needs_build(dec.entry, ro.dups) {
		if dec.entry.family == .Dsv {
			return exec_whole(dec, src, opts)
		}
		return exec_records_find_whole(plan, dec, src, tf, ro, opts, parallel)
	}

	main := &plan.sources[.Main] if plan != nil else nil
	use_partial := dec.demand_mode != .Whole && dec.entry.supports_scan && main != nil && (main.mode == .Partial || main.mode == .None)
	dem, dem_owned, derr := prepare_demand(main if use_partial else nil, dec.keep_facts || !use_partial, opts.allocator)
	if derr != nil {
		return {err = .No_Memory, read_err = derr}
	}
	defer if dem_owned {
		tape.destroy_demand(&dem)
	}

	recs, open_err_res, open_ok := open_framed_records(src, dec.spec, tf, ro, nil, opts)
	if !open_ok {
		return open_err_res
	}
	defer tape.destroy_records(recs)

	dsv_header_end := dsv_header_end_of(dec, ro, recs)
	dsv_row_buf := make([dynamic]u8, opts.allocator)
	defer delete(dsv_row_buf)

	out_recs: [RECORD_BATCH_SIZE]tape.Record
	docs: [RECORD_BATCH_SIZE]tape.Document
	res: Exec_Result
	can_eval_par := parallel &&
		ro.runner != nil &&
		ro.runner.threads > 0 &&
		opts.eval != nil &&
		(plan == nil || plan.serial == {}) &&
		can_parallel_eval(opts.workers.init != nil, opts.eval_ctx, true, opts.eval_ctx_thread_safe)

	for {
		n := tape.records_scan(recs, &dem, out_recs[:], docs[:], {}, opts.allocator)
		if n == 0 {
			break
		}
		if can_eval_par && n > 1 {
			sub := eval_record_batch_parallel(dec, src, out_recs[:n], docs[:n], !use_partial, res.records, res.emitted, true, dsv_header_end, opts)
			merge_result(&res, sub)
			if sub.err != .None {
				return res
			}
			continue
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
			doc_ptr := &docs[i]
			whole_rec_doc: tape.Document
			if !use_partial && doc_ptr.partial != nil {
				whole_rec_doc = doc_ptr^
				whole_rec_doc.partial = nil
				doc_ptr = &whole_rec_doc
			}
			if opts.eval == nil {
				sub := exec_emit_default_doc(doc_ptr, opts.emit, opts.allocator)
				res.emitted += sub.emitted
				if sub.err != .None {
					res.err = sub.err
					res.write_err = sub.write_err
					return res
				}
				continue
			}
			g := Guard_Emit{inner = opts.emit}
			eval_err := opts.eval(opts.eval_ctx, doc_ptr, meta, Emitter{fn = guard_emit_fn, data = &g})
			res.emitted += g.emitted
			if eval_err == .Tainted {
				if res.emitted == 0 && (opts.rerun_whole_on_taint || dec.rerun_safe) {
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
			if g.stopped && eval_err == .None {
				eval_err = .Stopped
			}
			if eval_err != .None {
				res.err = eval_err
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

// Whole-record framing fallback when `dups` (`All`, or `Refuse` without `.Names_Ahead`) prevents `records_scan`.
@(private)
exec_records_find_whole :: proc(
	plan: ^query.Plan,
	dec: ^Decision,
	src: []u8,
	tf: tape.Framing,
	ro: tape.Options,
	opts: ^Exec_Options,
	parallel: bool,
) -> Exec_Result {
	frame_ro := ro
	frame_ro.dups = .Default
	recs, open_err_res, open_ok := open_framed_records(src, dec.spec, tf, frame_ro, nil, opts)
	if !open_ok {
		return open_err_res
	}
	defer tape.destroy_records(recs)

	out_recs: [RECORD_BATCH_SIZE]tape.Record
	answers: [RECORD_BATCH_SIZE]tape.Span_Answer
	res: Exec_Result
	can_eval_par := parallel &&
		ro.runner != nil &&
		ro.runner.threads > 0 &&
		opts.eval != nil &&
		(plan == nil || plan.serial == {}) &&
		can_parallel_eval(opts.workers.init != nil, opts.eval_ctx, true, opts.eval_ctx_thread_safe)

	rec_ro := ro
	rec_ro.runner = nil

	for {
		n := tape.records_find(recs, nil, out_recs[:], answers[:], {}, opts.allocator)
		if n == 0 {
			break
		}
		if can_eval_par && n > 1 {
			sub := eval_record_batch_whole_parallel(dec, src, out_recs[:n], rec_ro, res.records, opts)
			merge_result(&res, sub)
			if sub.err != .None {
				return res
			}
			continue
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
			doc, berr := build(raw, dec.spec, rec_ro, opts.allocator)
			if berr != nil {
				bad := r_info
				bad.err = berr
				if !handle_bad_record(opts, src, bad, &res) {
					return res
				}
				continue
			}
			meta := make_record_meta(opts, res.records, r_info, raw)
			res.records += 1
			if opts.eval == nil {
				sub := exec_emit_default_doc(&doc, opts.emit, opts.allocator)
				tape.destroy(&doc)
				res.emitted += sub.emitted
				if sub.err != .None {
					res.err = sub.err
					res.write_err = sub.write_err
					return res
				}
				continue
			}
			g := Guard_Emit{inner = opts.emit}
			eval_err := opts.eval(opts.eval_ctx, &doc, meta, Emitter{fn = guard_emit_fn, data = &g})
			tape.destroy(&doc)
			res.emitted += g.emitted
			if g.stopped && eval_err == .None {
				eval_err = .Stopped
			}
			if eval_err != .None {
				res.err = eval_err
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

@(private)
can_build_single_record :: proc "contextless" (dec: ^Decision, raw: []u8) -> bool {
	return len(raw) > 0 && dec.entry.family != .Dsv && dec.framing != .Members
}

@(private)
exec_single_record_whole :: proc(dec: ^Decision, raw: []u8, meta: Record_Meta, opts: ^Exec_Options) -> Exec_Result {
	ro := build_tape_opts(opts, allow_parallel = false)
	doc, err := build(raw, dec.spec, ro, opts.allocator)
	if err != nil {
		return {err = .No_Memory if is_alloc_err(err) else .Read_Error, read_err = err}
	}
	defer tape.destroy(&doc)
	if opts.eval == nil {
		return exec_emit_default_doc(&doc, opts.emit, opts.allocator)
	}
	g := Guard_Emit{inner = opts.emit}
	e := opts.eval(opts.eval_ctx, &doc, meta, Emitter{fn = guard_emit_fn, data = &g})
	if g.stopped && e == .None {
		e = .Stopped
	}
	return {err = e, emitted = g.emitted}
}

@(private)
exec_single_dsv_row_from_raw :: proc(
	dec: ^Decision,
	src: []u8,
	dsv_header_end: u64,
	raw: []u8,
	buf: ^[dynamic]u8,
	meta: Record_Meta,
	opts: ^Exec_Options,
) -> Exec_Result {
	wd, _, werr := prepare_demand(nil, dec.keep_facts, opts.allocator)
	if werr != nil {
		return {err = .No_Memory, read_err = werr}
	}
	defer tape.destroy_demand(&wd)

	clear(buf)
	if dsv_header_end > 0 {
		if _, aerr := append(buf, ..src[:dsv_header_end]); aerr != nil {
			return {err = .No_Memory, read_err = aerr}
		}
	}
	if _, aerr := append(buf, ..raw); aerr != nil {
		return {err = .No_Memory, read_err = aerr}
	}
	return exec_single_dsv_row_whole(dec.spec.(dsv.Spec), buf[:], &wd, build_tape_opts(opts, false), meta, opts)
}

@(private)
exec_single_dsv_row_whole :: proc(
	spec: dsv.Spec,
	combined: []u8,
	whole_dem: ^tape.Demand,
	ro: tape.Options,
	meta: Record_Meta,
	opts: ^Exec_Options,
) -> Exec_Result {
	r := dsv.records_open(combined, .Lines, spec, ro)
	defer tape.destroy_records(&r)
	if r.err != nil {
		return {err = .No_Memory if is_alloc_err(r.err) else .Read_Error, read_err = r.err}
	}
	rec: [1]tape.Record
	doc: [1]tape.Document
	n := dsv.records_scan(&r, whole_dem, rec[:], doc[:], {}, opts.allocator)
	if n == 0 || rec[0].err != nil {
		rerr := rec[0].err if n > 0 else r.err
		return {err = .No_Memory if is_alloc_err(rerr) else .Read_Error, read_err = rerr}
	}
	row_doc := doc[0]
	row_doc.partial = nil
	if opts.eval == nil {
		return exec_emit_default_doc(&row_doc, opts.emit, opts.allocator)
	}
	g := Guard_Emit{inner = opts.emit}
	e := opts.eval(opts.eval_ctx, &row_doc, meta, Emitter{fn = guard_emit_fn, data = &g})
	if g.stopped && e == .None {
		e = .Stopped
	}
	return {err = e, emitted = g.emitted}
}

@(private)
emit_raw_or_compact :: proc(dec: ^Decision, raw: []u8, opts: ^Exec_Options) -> Exec_Result {
	ro := build_tape_opts(opts, allow_parallel = false)
	doc, err := build(raw, dec.spec, ro, opts.allocator)
	if err != nil {
		return {err = .No_Memory if is_alloc_err(err) else .Read_Error, read_err = err}
	}
	defer tape.destroy(&doc)
	return exec_emit_default_doc(&doc, opts.emit, opts.allocator)
}

@(private)
exec_emit_default_doc :: proc(doc: ^tape.Document, emit: Emitter, alloc: runtime.Allocator) -> Exec_Result {
	text, _, werr := json.write(doc, .Json, {}, alloc)
	if werr != nil {
		return {err = .Write_Error, write_err = werr}
	}
	defer delete(text, alloc)
	if !emit_bytes(emit, text) {
		return {err = .Stopped}
	}
	return {emitted = 1}
}

@(private)
record_slice :: proc "contextless" (src: []u8, r: tape.Record) -> []u8 {
	if r.hi > r.lo && int(r.hi) <= len(src) {
		return src[r.lo:r.hi]
	}
	return nil
}
