package engine

import "base:runtime"
import "stury:dsv"
import "stury:json"
import "stury:lib/base/kernel"
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

// Counts items emitted for one element sub-document in Hint 1 `.Length` (`[.prefix[] | each] | length`) without formatting outputs.
Count_Doc_Proc :: #type proc(ctx: rawptr, doc: ^tape.Document, meta: Record_Meta) -> (count: u64, err: Exec_Error)

// Emits final integer count in Hint 1 `.Length` (`[.prefix[] | each] | length`) via caller's output configuration.
Emit_Total_Proc :: #type proc(ctx: rawptr, total: u64, emit: Emitter) -> Exec_Error

// Optional combiner callback for Hint 1 `.Collect` (`[.prefix[] | each] | tail`).
// `doc` is nil unless `Exec_Options.spine_collect_needs_doc` is set.
Spine_Collect_Proc :: #type proc(ctx: rawptr, doc: ^tape.Document, item_outputs: [][]u8, emit: Emitter) -> Exec_Error

// Direct strict-JSON formatting fast path when caller outputs plain compact or 2-space pretty JSON for identity filters.
Fast_Json_Mode :: enum u8 {
	None,
	Compact,
	Pretty2,
}

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
	eval_each_count:         Count_Doc_Proc,     // optional element counter for Hint 1 `.Length` with `has_each`
	emit_spine_length:       Emit_Total_Proc,    // optional total count formatter for Hint 1 `.Length` with `has_each`
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
	fast_json:               Fast_Json_Mode, // fast strict-JSON serializer bypass for whole/record identity `.` outputs
	fast_json_each:          Fast_Json_Mode, // fast strict-JSON serializer bypass for Hint 1 identity element streams
	coalesce_emit:           bool,           // coalesce parallel chunk bytes into 1 emit call per chunk when safe
	direct_append_nl:        bool,           // append `\n` inside `.Projection_Direct` JSON row buffer
	spine_collect_compact:   bool,           // emit compact `[` + chunk items + `]\n` directly when `!sp.has_tail`
	rerun_whole_on_taint:    bool,           // opt-in caller rerun ONLY when `emitted == 0`
	eval_ctx_thread_safe:    bool,           // set true only when non-nil `eval_ctx` is safe without `workers.init`
	spine_collect_needs_doc: bool,           // when true, `.Collect` parses root document to pass to `spine_collect`
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

@(private = "file")
Fast_Json_Frame :: struct {
	end_idx:    int,
	key_start:  int,
	key_bloom:  u64,
	is_obj:     bool,
	need_comma: bool,
	expect_val: bool,
}

@(private)
is_thread_safe_heap :: proc(a: runtime.Allocator) -> bool {
	return a.procedure == runtime.heap_allocator().procedure
}

@(private)
has_custom_scratch :: proc(s: runtime.Allocator) -> bool {
	return s.procedure != nil && s.procedure != runtime.heap_allocator().procedure
}

// Rejects raw JSON bytes containing `\/`, `\uXXXX`, or literal DEL (0x7F) where canonical jq
// formatting normalizes or escapes differently from the authored source bytes.
@(private)
has_noncanonical_json_bytes :: proc "contextless" (b: []u8) -> bool {
	if len(b) == 0 {
		return false
	}
	if kernel.index_byte(b, 0x7f) >= 0 {
		return true
	}
	pos := 0
	for pos < len(b) {
		rel := kernel.index_byte(b[pos:], '\\')
		if rel < 0 {
			return false
		}
		esc := pos + rel + 1
		if esc >= len(b) {
			return true
		}
		c := b[esc]
		if c == 'u' || c == '/' {
			return true
		}
		pos = esc + 1
	}
	return false
}

@(private)
can_fast_json_doc :: proc "contextless" (dec: ^Decision, doc: ^tape.Document, mode: Fast_Json_Mode, opts: ^Exec_Options) -> bool {
	if mode == .None || dec.entry.id != .Json {
		return false
	}
	if opts.read.tolerate != {} || opts.read.budget != {} || opts.max_bytes != 0 || opts.read.dups == .All {
		return false
	}
	if dec.keep_facts || dec.keep_origins || doc.format == nil {
		return false
	}
	if doc.flags & {.Tolerated, .Held, .Stopped, .Cut} != {} || len(doc.nodes) == 0 {
		return false
	}
	root := doc.nodes[0]
	if root.role != .Value || int(root.n) != len(doc.nodes) {
		return false
	}
	lo := root.lo
	if root.kind == .String && lo > 0 {
		lo -= 1
	}
	if doc.root_close > u64(len(doc.src)) || lo > doc.root_close {
		return false
	}
	return !has_noncanonical_json_bytes(doc.src[lo:doc.root_close])
}

// Directly serializes a strict canonical JSON document (`Compact` or `Pretty2`) into `buf`
// without `query.Heap` conversion. Returns false (restoring `len(buf)`) on partial/dup edge cases.
@(private)
append_fast_json_doc :: proc(buf: ^[dynamic]u8, doc: ^tape.Document, mode: Fast_Json_Mode, append_nl: bool) -> bool #no_bounds_check {
	if mode == .None || len(doc.nodes) == 0 {
		return false
	}
	saved := len(buf)
	est := int(doc.root_close - doc.nodes[0].lo) + (len(doc.nodes) * 4 if mode == .Pretty2 else 8)
	if aerr := reserve(buf, saved + max(est, 16)); aerr != nil {
		resize(buf, saved)
		return false
	}
	check_dups := doc.partial != nil
	frames: [64]Fast_Json_Frame = ---
	depth := 0
	obj_keys: [64]tape.Node = ---
	key_count := 0

	append_spaces :: #force_inline proc(out: ^[dynamic]u8, n: int) {
		if n <= 0 {
			return
		}
		spaces := "                                                                "
		rem := n
		for rem > len(spaces) {
			append(out, spaces)
			rem -= len(spaces)
		}
		append(out, spaces[:rem])
	}

	nodes := doc.nodes
	src := doc.src
	pretty := mode == .Pretty2
	for idx := 0; idx < len(nodes); idx += 1 {
		for depth > 0 && idx >= frames[depth - 1].end_idx {
			depth -= 1
			f := &frames[depth]
			if check_dups && f.is_obj {
				key_count = f.key_start
			}
			if pretty {
				append(buf, '\n')
				append_spaces(buf, depth * 2)
			}
			append(buf, '}' if f.is_obj else ']')
		}
		if depth > 0 {
			top := &frames[depth - 1]
			if top.expect_val {
				top.expect_val = false
			} else {
				if top.need_comma {
					append(buf, ',')
				}
				top.need_comma = true
				if pretty {
					append(buf, '\n')
					append_spaces(buf, depth * 2)
				}
			}
		}

		t := nodes[idx]
		if t.role == .Key {
			if depth <= 0 || !frames[depth - 1].is_obj {
				resize(buf, saved)
				return false
			}
			top := &frames[depth - 1]
			if check_dups {
				if key_count >= len(obj_keys) {
					resize(buf, saved)
					return false
				}
				h := u32(t.n) * 0x9e3779b1
				if t.n > 0 {
					h ~= u32(src[t.lo]) * 0x85ebca6b ~ u32(src[t.lo + u64(t.n) - 1]) * 0xc2b2ae35
				}
				bit := u64(1) << (h & 63)
				if top.key_bloom & bit != 0 {
					kraw := src[t.lo:][:t.n]
					for k in obj_keys[top.key_start:key_count] {
						if k.n == t.n && (t.n == 0 || runtime.memory_compare(raw_data(src[k.lo:]), raw_data(kraw), int(t.n)) == 0) {
							resize(buf, saved)
							return false
						}
					}
				}
				top.key_bloom |= bit
				obj_keys[key_count] = t
				key_count += 1
			}
			append(buf, '"')
			append(buf, ..src[t.lo:][:t.n])
			append(buf, "\": " if pretty else "\":")
			top.expect_val = true
			continue
		}
		if t.role != .Value {
			resize(buf, saved)
			return false
		}
		#partial switch t.kind {
		case .Null:
			append(buf, "null")
		case .False:
			append(buf, "false")
		case .True:
			append(buf, "true")
		case .Number:
			append(buf, ..src[t.lo:][:t.n])
		case .String:
			append(buf, '"')
			append(buf, ..src[t.lo:][:t.n])
			append(buf, '"')
		case .Array, .Object:
			if t.spelling & tape.CONTAINER_PARTIAL != 0 {
				resize(buf, saved)
				return false
			}
			is_obj := t.kind == .Object
			if t.n <= 1 {
				append(buf, "{}" if is_obj else "[]")
			} else {
				if depth >= len(frames) {
					resize(buf, saved)
					return false
				}
				append(buf, '{' if is_obj else '[')
				frames[depth] = {
					end_idx   = idx + int(t.n),
					key_start = key_count,
					is_obj    = is_obj,
				}
				depth += 1
			}
		case:
			resize(buf, saved)
			return false
		}
	}
	for depth > 0 {
		depth -= 1
		f := &frames[depth]
		if pretty {
			append(buf, '\n')
			append_spaces(buf, depth * 2)
		}
		append(buf, '}' if f.is_obj else ']')
	}
	if append_nl {
		append(buf, '\n')
	}
	return true
}

@(private)
emit_fast_json_doc :: proc(doc: ^tape.Document, mode: Fast_Json_Mode, emit: Emitter, alloc: runtime.Allocator) -> (res: Exec_Result, ok: bool) {
	buf := make([dynamic]u8, 0, max(int(doc.root_close - doc.nodes[0].lo) + 16, 64), alloc)
	defer delete(buf)
	if !append_fast_json_doc(&buf, doc, mode, true) {
		return {}, false
	}
	if !emit_bytes(emit, buf[:]) {
		return {err = .Stopped}, true
	}
	return {emitted = 1}, true
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
	if can_fast_json_doc(dec, &doc, opts.fast_json, opts) {
		if fres, ok := emit_fast_json_doc(&doc, opts.fast_json, opts.emit, opts.allocator); ok {
			return fres
		}
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

	if parallel &&
		ro.runner != nil &&
		ro.runner.threads > 0 &&
		dec.entry.family == .Json &&
		(tf == .Lines || tf == .Seq) &&
		ro.pieces == nil &&
		(plan == nil || plan.serial == {}) &&
		opts.eval != nil &&
		can_parallel_eval(opts.workers.init != nil, opts.eval_ctx, true, opts.eval_ctx_thread_safe) &&
		len(src) >= max(RECORDS_PARALLEL_FROM, 4096) {
		if cres, handled := exec_records_coarse_parallel(dec, src, tf, ro, &dem, !use_partial, opts); handled {
			return cres
		}
	}

	recs, open_err_res, open_ok := open_framed_records(src, dec.spec, tf, ro, nil, opts)
	if !open_ok {
		return open_err_res
	}
	defer tape.destroy_records(recs)

	dsv_header_end := dsv_header_end_of(dec, ro, recs)
	dsv_row_buf := make([dynamic]u8, opts.allocator)
	defer delete(dsv_row_buf)
	fast_buf := make([dynamic]u8, opts.allocator)
	defer delete(fast_buf)

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
			if can_fast_json_doc(dec, doc_ptr, opts.fast_json, opts) {
				clear(&fast_buf)
				if append_fast_json_doc(&fast_buf, doc_ptr, opts.fast_json, true) {
					if !emit_bytes(opts.emit, fast_buf[:]) {
						res.err = .Stopped
						return res
					}
					res.emitted += 1
					continue
				}
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
