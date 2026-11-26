package engine_tests

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "stury:dsv"
import "stury:engine"
import "stury:host"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"
import "stury:xml"

@(private = "file")
Reg_Lines :: struct {
	lines: [dynamic]string,
	alloc: runtime.Allocator,
}

@(private = "file")
reg_lines_emit :: proc(data: rawptr, bytes: []u8) -> bool {
	rl := (^Reg_Lines)(data)
	append(&rl.lines, strings.clone(string(bytes), rl.alloc))
	return true
}

@(private = "file")
reg_lines_destroy :: proc(rl: ^Reg_Lines) {
	for s in rl.lines {
		delete(s, rl.alloc)
	}
	delete(rl.lines)
}

@(private = "file")
Stateful_Eval_Ctx :: struct {
	calls: int,
}

@(private = "file")
stateful_inc_eval :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	_ = doc
	_ = meta
	st := (^Stateful_Eval_Ctx)(ctx)
	// Non-atomic increment: TSan catches any unsynchronized concurrent execution immediately.
	st.calls += 1
	buf: [32]u8
	s := fmt.bprintf(buf[:], "%d", st.calls)
	if !engine.emit_bytes(emit, transmute([]u8)s) {
		return .Stopped
	}
	return .None
}

// Regression (Critical #1): unsynchronized `eval_ctx` without `workers.init` falls back to serial
// across `.Records_Parallel`, `.Spine_Parallel`, and `execute_files`; shared `read.scratch` is mutex-guarded.
@(test)
regression_parallel_unsync_ctx_and_shared_scratch_tsan :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	// 1. `.Records_Parallel` decision + non-nil stateful `eval_ctx` + `workers = {}` MUST NOT race under TSan.
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		for i in 0 ..< 64 {
			fmt.sbprintf(&sb, "{{\"id\":%d}}\n", i)
		}
		ndjson := transmute([]u8)strings.to_string(sb)

		prog, perrs := jq.compile(`.id + 1`)
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)

		dec := engine.decide(&plan.contract, json.Spec.Json, .Lines, {runner = runner, input_bytes = len(ndjson)})
		testing.expect_value(t, dec.kind, engine.Route_Kind.Records_Parallel)

		ctx: Stateful_Eval_Ctx
		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, ndjson, {
			eval     = stateful_inc_eval,
			eval_ctx = &ctx,
			runner   = runner,
			emit     = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, ctx.calls, 64)
		testing.expect_value(t, len(lb.lines), 64)
	}

	// 2. `.Spine_Parallel` with stateful `eval_each_ctx` + `workers = {}` MUST NOT race under TSan.
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		strings.write_string(&sb, `{"items":[`)
		for i in 0 ..< 40 {
			if i > 0 {
				strings.write_byte(&sb, ',')
			}
			fmt.sbprintf(&sb, "{{\"id\":%d}}", i)
		}
		strings.write_string(&sb, `]}`)
		arr_json := transmute([]u8)strings.to_string(sb)

		prog, perrs := jq.compile(`.items[] | .id`)
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)

		dec := engine.decide(&plan.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = len(arr_json)})
		testing.expect_value(t, dec.kind, engine.Route_Kind.Spine_Parallel)

		ctx: Stateful_Eval_Ctx
		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, arr_json, {
			eval          = stateful_inc_eval,
			eval_ctx      = &ctx,
			eval_each     = stateful_inc_eval,
			eval_each_ctx = &ctx,
			runner        = runner,
			emit          = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, ctx.calls, 40)
	}

	// 3. `execute_files` with shared unsynchronized `eval_ctx` + `workers = {}` falls back safely.
	{
		prog, perrs := jq.compile(`.x + 1`)
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)

		files := [4]engine.File_Input {
			{"a.json", transmute([]u8)string(`{"x":1}`), json.Spec.Json, .Single},
			{"b.json", transmute([]u8)string(`{"x":2}`), json.Spec.Json, .Single},
			{"c.json", transmute([]u8)string(`{"x":3}`), json.Spec.Json, .Single},
			{"d.json", transmute([]u8)string(`{"x":4}`), json.Spec.Json, .Single},
		}
		ctx: Stateful_Eval_Ctx
		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute_files(&plan.contract, files[:], {runner = runner}, {
			eval     = stateful_inc_eval,
			eval_ctx = &ctx,
			runner   = runner,
			emit     = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, ctx.calls, 4)
		testing.expect_value(t, lb.lines[3], "4")
	}

	// 4. `execute_files` with shared non-thread-safe `mem.Arena` as `read.scratch` + deeply nested JSON -> race-free under TSan.
	{
		prog, perrs := jq.compile(`.root.leaf`)
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)

		// Deep nesting past FRAME_DEPTH (1024) forces scratch allocation inside every concurrent worker!
		dbuf := strings.builder_make()
		defer strings.builder_destroy(&dbuf)
		strings.write_string(&dbuf, `{"root":`)
		for _ in 0 ..< 1100 {
			strings.write_byte(&dbuf, '[')
		}
		strings.write_byte(&dbuf, '7')
		for _ in 0 ..< 1100 {
			strings.write_byte(&dbuf, ']')
		}
		strings.write_string(&dbuf, `,"leaf":1}`)
		deep_json := transmute([]u8)strings.to_string(dbuf)

		files: [6]engine.File_Input
		for i in 0 ..< len(files) {
			files[i] = {"deep.json", deep_json, json.Spec.Json, .Single}
		}

		scratch_mem := make([]u8, 256 * 1024)
		defer delete(scratch_mem)
		scratch_arena: mem.Arena
		mem.arena_init(&scratch_arena, scratch_mem)

		no_op_eval :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = doc
			_ = meta
			_ = engine.emit_bytes(emit, transmute([]u8)string("ok"))
			return .None
		}

		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute_files(&plan.contract, files[:], {runner = runner}, {
			eval   = no_op_eval, // nil eval_ctx is thread-safe, exercising shared `read.scratch` concurrently
			read   = {budget = {depth = 1200}, scratch = mem.arena_allocator(&scratch_arena)},
			runner = runner,
			emit   = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, res.emitted, u64(6))
		testing.expect(t, scratch_arena.offset > 0)
	}
}

// Regression (Critical #2): `>256`-record batch taint guard must NEVER replay mid-stream on batch 1+,
// and Hint 1 `.Collect` mode must allow whole-doc taint fallback when 0 downstream outputs flushed.
@(test)
regression_taint_multibatch_and_collect :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	// 1. 300 NDJSON records (> 256 batch size): records 0..259 match `.keep`, record 260 triggers taint on `.secret`.
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		for i in 0 ..< 300 {
			if i == 260 {
				fmt.sbprintf(&sb, "{{\"secret\":%d}}\n", i)
			} else {
				fmt.sbprintf(&sb, "{{\"keep\":%d}}\n", i)
			}
		}
		ndjson := transmute([]u8)strings.to_string(sb)

		prog_keep, _ := jq.compile(`.keep`)
		defer jq.destroy_program(prog_keep)
		under_plan := jq.analyze(prog_keep)
		defer jq.destroy_plan(&under_plan)

		prog_actual, _ := jq.compile(`if has("keep") then .keep else .secret end`)
		defer jq.destroy_program(prog_actual)

		dec := engine.Decision {
			kind        = .Records_Parallel,
			spec        = json.Spec.Json,
			entry       = engine.entry_of(engine.Format_Id.Json) or_else engine.Format_Entry{},
			framing     = .Lines,
			demand_mode = .Partial,
			parallel    = true,
		}

		// Minimal custom per-worker evaluator running `prog_actual` over scanned doc.
		Batch_State :: struct {
			prog:  ^jq.Program,
			h:     query.Heap,
			run:   jq.Run,
			alloc: runtime.Allocator,
		}
		init_bs :: proc(parent: rawptr, idx: int, alloc: runtime.Allocator) -> rawptr {
			_ = idx
			p := (^Batch_State)(parent)
			w := new(Batch_State, alloc)
			w.prog = p.prog
			w.alloc = alloc
			query.heap_init(&w.h, alloc)
			jq.run_init(&w.run, p.prog, &w.h, nil)
			return w
		}
		fini_bs :: proc(parent: rawptr, idx: int, wptr: rawptr) {
			_ = parent
			_ = idx
			w := (^Batch_State)(wptr)
			if w != nil {
				jq.run_destroy(&w.run)
				query.heap_destroy(&w.h)
				free(w, w.alloc)
			}
		}
		eval_bs :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = meta
			w := (^Batch_State)(ctx)
			w.h.tainted = false
			query.clear_error(&w.h)
			inp, st := query.document_value(&w.h, doc^, owned = false)
			if st != .Ok {
				return .Failed
			}
			Cap :: struct {
				h:    ^query.Heap,
				emit: engine.Emitter,
				buf:  [dynamic]u8,
				err:  engine.Exec_Error,
			}
			on_v :: proc(d: rawptr, v: query.Value, h: ^query.Heap) -> bool {
				c := (^Cap)(d)
				defer query.release(h, v)
				clear(&c.buf)
				if query.write_json(h, &c.buf, v) != .Ok {
					c.err = .Tainted if h.tainted else .Write_Error
					return false
				}
				if !engine.emit_bytes(c.emit, c.buf[:]) {
					c.err = .Stopped
					return false
				}
				return true
			}
			cap := Cap{h = &w.h, emit = emit, buf = make([dynamic]u8, w.alloc)}
			defer delete(cap.buf)
			end := jq.run_value(&w.run, inp, on_v, &cap)
			if cap.err != .None {
				return cap.err
			}
			if w.h.tainted || end == .Tainted {
				return .Tainted
			}
			return .None
		}

		parent_bs := Batch_State{prog = prog_actual}
		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&under_plan.contract, &dec, ndjson, {
			eval                 = eval_bs,
			eval_ctx             = &parent_bs,
			workers              = {init = init_bs, fini = fini_bs},
			runner               = runner,
			rerun_whole_on_taint = true,
			emit                 = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.Tainted)
		testing.expect(t, res.tainted)
		testing.expect(t, !res.reran_whole)
		testing.expect_value(t, res.emitted, u64(260))
		testing.expect_value(t, len(lb.lines), 260)
	}

	// 2. Hint 1 `.Collect` mode: items 0..3 buffer without flushing downstream; item 4 taints;
	// because 0 downstream outputs escaped, whole-doc fallback MUST recover cleanly when opted in!
	{
		arr_src := transmute([]u8)string(`{"items":[{"v":1,"s":10},{"v":2,"s":20},{"v":3,"s":30},{"v":4,"s":40}]}`)
		prog_col, _ := jq.compile(`[.items[] | .v] | add`)
		defer jq.destroy_program(prog_col)
		plan := jq.analyze(prog_col)
		defer jq.destroy_plan(&plan)

		dec := engine.Decision {
			kind        = .Spine_Parallel,
			active_hint = .Spine_Split,
			spec        = json.Spec.Json,
			entry       = engine.entry_of(engine.Format_Id.Json) or_else engine.Format_Entry{},
			framing     = .Single,
			parallel    = true,
		}

		each_taint_on_3 :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = doc
			if meta.record_index == 3 {
				return .Tainted
			}
			_ = engine.emit_bytes(emit, transmute([]u8)string("10"))
			return .None
		}
		whole_ok :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = doc
			_ = meta
			_ = engine.emit_bytes(emit, transmute([]u8)string("100"))
			return .None
		}
		noop_collect :: proc(ctx: rawptr, doc: ^tape.Document, item_outputs: [][]u8, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = doc
			_ = item_outputs
			_ = emit
			return .None
		}

		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, arr_src, {
			eval                 = whole_ok,
			eval_each            = each_taint_on_3,
			spine_collect        = noop_collect,
			runner               = runner,
			rerun_whole_on_taint = true,
			emit                 = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect(t, res.reran_whole)
		testing.expect_value(t, len(lb.lines), 1)
		testing.expect_value(t, lb.lines[0], "100")
	}
}

// Regression (Critical #3): Hint 1 with `eval_each == nil` falls back to whole-doc `opts.eval`
// (never invokes `eval` on element sub-docs), and returns `.Failed` when `eval == nil`.
@(test)
regression_spine_nil_eval_each_fallback :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 2) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	src := transmute([]u8)string(`{"items":[{"id":1},{"id":2},{"id":3}]}`)
	prog, _ := jq.compile(`.items[] | .id`)
	defer jq.destroy_program(prog)
	plan := jq.analyze(prog)
	defer jq.destroy_plan(&plan)

	dec := engine.Decision {
		kind        = .Spine_Parallel,
		active_hint = .Spine_Split,
		spec        = json.Spec.Json,
		entry       = engine.entry_of(engine.Format_Id.Json) or_else engine.Format_Entry{},
		framing     = .Single,
		parallel    = true,
	}

	Whole_Probe :: struct {
		calls:    int,
		saw_root: bool,
	}
	probe_eval :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
		_ = meta
		p := (^Whole_Probe)(ctx)
		p.calls += 1
		_, pres := tape.member(tape.Reader{doc = doc}, tape.ROOT, "items")
		p.saw_root = pres == .Found
		_ = engine.emit_bytes(emit, transmute([]u8)string("whole"))
		return .None
	}

	probe: Whole_Probe
	lb := Reg_Lines{alloc = context.allocator}
	defer reg_lines_destroy(&lb)
	res_ok := engine.execute(&plan.contract, &dec, src, {
		eval      = probe_eval,
		eval_ctx  = &probe,
		eval_each = nil,
		runner    = runner,
		emit      = {fn = reg_lines_emit, data = &lb},
	})
	testing.expect_value(t, res_ok.err, engine.Exec_Error.None)
	testing.expect_value(t, probe.calls, 1)
	testing.expect(t, probe.saw_root)
	testing.expect_value(t, lb.lines[0], "whole")

	// When BOTH `eval_each == nil` AND `eval == nil`, must return `.Failed` (not emit raw document).
	lb_fail := Reg_Lines{alloc = context.allocator}
	defer reg_lines_destroy(&lb_fail)
	res_fail := engine.execute(&plan.contract, &dec, src, {
		runner = runner,
		emit   = {fn = reg_lines_emit, data = &lb_fail},
	})
	testing.expect_value(t, res_fail.err, engine.Exec_Error.Failed)
	testing.expect_value(t, len(lb_fail.lines), 0)
}

// Regression (High #4): Hint 2 `.Projection_Direct` deferred CSV header, `tape.Index` headers,
// JSON5 / `.Non_Finite` normalization & refusal, and TSV `\0` NUL escaping.
@(test)
regression_projection_direct_parity_and_headers :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Malformed / empty input must NEVER emit a stray CSV/TSV header!
	{
		prog, _ := jq.compile(`{who: .name, years: .age}`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)

		dec_json := engine.decide(&plan.contract, json.Spec.Json, .Single)
		lb1 := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb1)
		r1 := engine.execute(&plan.contract, &dec_json, transmute([]u8)string(`{broken`), {
			direct_out        = .Csv,
			direct_csv_header = true,
			emit              = {fn = reg_lines_emit, data = &lb1},
		})
		testing.expect_value(t, r1.err, engine.Exec_Error.Read_Error)
		testing.expect_value(t, len(lb1.lines), 0)

		dec_csv := engine.decide(&plan.contract, dsv.Spec.Csv, .Lines)
		lb2 := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb2)
		r2 := engine.execute(&plan.contract, &dec_csv, transmute([]u8)string("name,age\n"), {
			direct_out        = .Csv,
			direct_csv_header = true,
			emit              = {fn = reg_lines_emit, data = &lb2},
		})
		testing.expect_value(t, r2.err, engine.Exec_Error.None)
		testing.expect_value(t, len(lb2.lines), 0)
	}

	// 2. `tape.Index` header formatting (`[.[0], .[2]]` -> `"0,2"`).
	{
		prog, _ := jq.compile(`[.[0], .[2]]`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, json.Spec.Json, .Single)
		testing.expect_value(t, dec.kind, engine.Route_Kind.Projection_Direct)

		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, transmute([]u8)string(`[10, 20, 30]`), {
			direct_out        = .Csv,
			direct_csv_header = true,
			emit              = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, len(lb.lines), 2)
		testing.expect_value(t, lb.lines[0], "0,2")
		testing.expect_value(t, lb.lines[1], "10,30")
	}

	// 3. JSON5 finite numbers normalize in BOTH JSON and CSV; non-finite `NaN`/`Infinity` fail cleanly
	// in strict JSON & CSV (before emitting any CSV header!).
	{
		prog, _ := jq.compile(`{x: .x, y: .y}`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)

		j5_dec := engine.decide(&plan.contract, json.Spec.Json5, .Single)
		j5_src := transmute([]u8)string(`{x: 0x10, y: .5}`)

		lb_json := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb_json)
		r_j := engine.execute(&plan.contract, &j5_dec, j5_src, {
			direct_out = .Json,
			emit       = {fn = reg_lines_emit, data = &lb_json},
		})
		testing.expect_value(t, r_j.err, engine.Exec_Error.None)
		testing.expect_value(t, lb_json.lines[0], `{"x":16,"y":0.5}`)

		lb_csv := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb_csv)
		r_c := engine.execute(&plan.contract, &j5_dec, j5_src, {
			direct_out        = .Csv,
			direct_csv_header = true,
			emit              = {fn = reg_lines_emit, data = &lb_csv},
		})
		testing.expect_value(t, r_c.err, engine.Exec_Error.None)
		testing.expect_value(t, lb_csv.lines[0], "x,y")
		testing.expect_value(t, lb_csv.lines[1], "16,0.5")

		// Tolerant `.Non_Finite` (`NaN`) in `.Json` must NOT pass raw fast path into strict JSON or CSV!
		j_dec := engine.decide(&plan.contract, json.Spec.Json, .Single)
		nan_src := transmute([]u8)string(`{"x":NaN,"y":1}`)

		lb_nan_json := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb_nan_json)
		r_nj := engine.execute(&plan.contract, &j_dec, nan_src, {
			direct_out = .Json,
			read       = {tolerate = {.Non_Finite}},
			emit       = {fn = reg_lines_emit, data = &lb_nan_json},
		})
		testing.expect_value(t, r_nj.err, engine.Exec_Error.Write_Error)
		testing.expect_value(t, len(lb_nan_json.lines), 0)

		lb_nan_csv := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb_nan_csv)
		r_nc := engine.execute(&plan.contract, &j_dec, nan_src, {
			direct_out        = .Csv,
			direct_csv_header = true,
			read              = {tolerate = {.Non_Finite}},
			emit              = {fn = reg_lines_emit, data = &lb_nan_csv},
		})
		testing.expect_value(t, r_nc.err, engine.Exec_Error.Write_Error)
		testing.expect_value(t, len(lb_nan_csv.lines), 0) // no header leaked!
	}

	// 4. TSV escapes `\0` NUL byte cleanly.
	{
		prog, _ := jq.compile(`{s: .s}`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, json.Spec.Json, .Single)

		src := transmute([]u8)string(`{"s":"a\u0000b"}`)
		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, src, {
			direct_out = .Tsv,
			emit       = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, lb.lines[0], `a\0b`)
	}
}

// Regression (High #5): Runtime execution under `dups = .All` and `dups = .Refuse` on JSON single & NDJSON.
@(test)
regression_exec_dups_all_and_refuse_framed :: proc(t: ^testing.T) {
	testkit.deadline(t)

	prog, _ := jq.compile(`.a`)
	defer jq.destroy_program(prog)
	plan := jq.analyze(prog)
	defer jq.destroy_plan(&plan)

	ndjson := transmute([]u8)string("{\"a\":1}\n{\"a\":2,\"a\":3}\n")

	// `dups = .Refuse` catches Duplicate_Key on record #1 instead of failing with `Bad_Option{"dups"}`!
	dec_ref := engine.decide(&plan.contract, json.Spec.Json, .Lines, {dups = .Refuse})
	lb_ref := Reg_Lines{alloc = context.allocator}
	defer reg_lines_destroy(&lb_ref)
	res_ref := engine.execute(&plan.contract, &dec_ref, ndjson, {
		eval = nil,
		read = {dups = .Refuse},
		emit = {fn = reg_lines_emit, data = &lb_ref},
	})
	testing.expect_value(t, res_ref.err, engine.Exec_Error.Read_Error)
	f_err, is_fault := res_ref.read_err.(tape.Fault)
	testing.expect(t, is_fault && f_err.kind == .Duplicate_Key)
	testing.expect_value(t, len(lb_ref.lines), 1)
	testing.expect_value(t, lb_ref.lines[0], `{"a":1}`)

	// `dups = .All` builds whole record preserving duplicate keys cleanly.
	dec_all := engine.decide(&plan.contract, json.Spec.Json, .Lines, {dups = .All})
	lb_all := Reg_Lines{alloc = context.allocator}
	defer reg_lines_destroy(&lb_all)
	res_all := engine.execute(&plan.contract, &dec_all, ndjson, {
		eval = nil,
		read = {dups = .All},
		emit = {fn = reg_lines_emit, data = &lb_all},
	})
	testing.expect_value(t, res_all.err, engine.Exec_Error.None)
	testing.expect_value(t, len(lb_all.lines), 2)
	testing.expect_value(t, lb_all.lines[1], `{"a":2,"a":3}`)

	// Parallel `exec_records_find_whole` under `dups = .All` (`runner != nil`, `eval_ctx_thread_safe = true`) matches serial parity.
	{
		pool: host.Pool
		testing.expect(t, host.pool_init(&pool, 2) == nil)
		defer host.pool_destroy(&pool)
		runner := &pool.runner

		par_ndjson := transmute([]u8)string("{\"a\":1,\"a\":2}\n{\"a\":3,\"a\":4}\n{\"a\":5,\"a\":6}\n")
		dec_par := engine.decide(&plan.contract, json.Spec.Json, .Lines, {dups = .All, runner = runner, input_bytes = len(par_ndjson)})
		testing.expect_value(t, dec_par.kind, engine.Route_Kind.Records_Parallel)

		emit_doc_compact :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = meta
			txt, _, werr := json.write(doc, .Json, {})
			if werr != nil {
				return .Write_Error
			}
			defer delete(txt)
			if !engine.emit_bytes(emit, txt) {
				return .Stopped
			}
			return .None
		}

		lb_par := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb_par)
		res_par := engine.execute(&plan.contract, &dec_par, par_ndjson, {
			eval   = emit_doc_compact,
			runner = runner,
			read   = {dups = .All},
			emit   = {fn = reg_lines_emit, data = &lb_par},
		})
		testing.expect_value(t, res_par.err, engine.Exec_Error.None)
		testing.expect_value(t, len(lb_par.lines), 3)
		testing.expect_value(t, lb_par.lines[0], `{"a":1,"a":2}`)
		testing.expect_value(t, lb_par.lines[2], `{"a":5,"a":6}`)
	}
}

// Regression (High #6): Hint 3 `.Conditional_Whole` single-doc `Wrong_Kind` with `eval == nil`,
// DSV taint rerun `reran_whole`, and `emit_raw_or_compact` forwarding `opts.read`.
@(test)
regression_conditional_whole_fixes :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Single-doc Wrong_Kind with `eval == nil` returns `.Failed` (matching framed mode, NOT emitting raw input).
	{
		prog, _ := jq.compile(`select(.a.b == 1)`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, json.Spec.Json, .Single)
		testing.expect_value(t, dec.kind, engine.Route_Kind.Conditional_Whole)

		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, transmute([]u8)string(`{"a":5}`), {
			eval = nil,
			emit = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.Failed)
		testing.expect_value(t, len(lb.lines), 0)
	}

	// 2. Framed taint rerun sets `reran_whole = true` cleanly on JSON and DSV.
	{
		prog, _ := jq.compile(`select(.status == "ok")`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		// Craft `cw` with `pred_eval` returning `.Tainted` to exercise framed taint fallback on CSV.
		dec_csv := engine.decide(&plan.contract, dsv.Spec.Csv, .Lines)
		testing.expect_value(t, dec_csv.kind, engine.Route_Kind.Conditional_Whole)

		plan.contract.hints.conditional.cmp.op = .None
		pred_taint :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta) -> (bool, engine.Exec_Error) {
			_ = ctx
			_ = doc
			_ = meta
			return false, .Tainted
		}
		eval_echo :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = meta
			txt, _, err := json.write(doc, .Json, {})
			if err != nil {
				return .Write_Error
			}
			defer delete(txt)
			_ = engine.emit_bytes(emit, txt)
			return .None
		}
		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec_csv, transmute([]u8)string("status,n\nok,1\n"), {
			eval                 = eval_echo,
			pred_eval            = pred_taint,
			rerun_whole_on_taint = true,
			emit                 = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect(t, res.reran_whole)
		testing.expect_value(t, lb.lines[0], `{"status":"ok","n":"1"}`)
	}

	// 3. Framed XML/JSON matching without `eval` forwards `opts.read` (`Xml_Options{infer = true}`).
	{
		prog, _ := jq.compile(`select(.r.flag == true)`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.Decision {
			kind        = .Conditional_Whole,
			active_hint = .Conditional_Whole,
			spec        = xml.Spec.Xml,
			entry       = engine.entry_of(engine.Format_Id.Xml) or_else engine.Format_Entry{},
			framing     = .Concatenated,
		}
		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, transmute([]u8)string(`<r><flag>true</flag></r>`), {
			eval = nil,
			read = {format = tape.Xml_Options{infer = true}},
			emit = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, lb.lines[0], `{"r":{"flag":true}}`)
	}
}

// Regression (High #7 & #8 & Medium #10): Hint 1 batch error prefix preservation,
// `.Collect` `doc == nil` by default, `Slot_Buffer` OOM safety, `skip_bad` refusing `Budget`,
// and `guard_emit_fn` `emitted` counting when downstream returns `false`.
@(test)
regression_spine_errors_oom_budget_and_emitted_counts :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 2) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	// 1. Hint 1 `.Spine_Parallel`: batch with valid prefix `0..1` + syntax fault at element `2`
	// preserves valid emissions before returning `.Read_Error`.
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		strings.write_string(&sb, `{"items":[{"id":1},{"id":2},broken]}`)
		// Pad past `SPINE_PARALLEL_FROM` if needed? Force decision cleanly.
		src := transmute([]u8)strings.to_string(sb)
		prog, _ := jq.compile(`.items[] | .id`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)

		dec := engine.Decision {
			kind        = .Spine_Parallel,
			active_hint = .Spine_Split,
			spec        = json.Spec.Json,
			entry       = engine.entry_of(engine.Format_Id.Json) or_else engine.Format_Entry{},
			framing     = .Single,
			parallel    = true,
		}
		// Ensure `len(src) >= SPINE_PARALLEL_FROM` only if SPINE_PARALLEL_FROM is huge?
		// Wait: make padding array >= `engine.SPINE_PARALLEL_FROM` inside `"pad"` or use large array.
		if len(src) < engine.SPINE_PARALLEL_FROM {
			pad_len := max(int(engine.SPINE_PARALLEL_FROM), 128)
			strings.builder_reset(&sb)
			strings.write_string(&sb, `{"pad":"`)
			for _ in 0 ..< pad_len {
				strings.write_byte(&sb, 'a')
			}
			strings.write_string(&sb, `","items":[{"id":1},{"id":2},broken]}`)
			src = transmute([]u8)strings.to_string(sb)
		}

		each_fn :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = doc
			_ = meta
			_ = engine.emit_bytes(emit, transmute([]u8)string("item"))
			return .None
		}
		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, src, {
			eval_each = each_fn,
			eval      = each_fn,
			runner    = runner,
			emit      = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.Read_Error)
		testing.expect_value(t, res.emitted, u64(2))
		testing.expect_value(t, len(lb.lines), 2)
	}

	// 2. Hint 1 `.Collect` passes `doc == nil` when `spine_collect_needs_doc == false`.
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		pad_len := max(int(engine.SPINE_PARALLEL_FROM), 128)
		strings.write_string(&sb, `{"pad":"`)
		for _ in 0 ..< pad_len {
			strings.write_byte(&sb, 'b')
		}
		strings.write_string(&sb, `","items":[10,20,30]}`)
		src := transmute([]u8)strings.to_string(sb)

		prog, _ := jq.compile(`[.items[] | .] | add`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = len(src)})
		testing.expect_value(t, dec.kind, engine.Route_Kind.Spine_Parallel)

		each_el :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = doc
			_ = meta
			_ = engine.emit_bytes(emit, transmute([]u8)string("x"))
			return .None
		}
		collect_check_nil :: proc(ctx: rawptr, doc: ^tape.Document, item_outputs: [][]u8, emit: engine.Emitter) -> engine.Exec_Error {
			saw_doc := (^bool)(ctx)
			saw_doc^ = doc != nil
			if len(item_outputs) == 3 {
				_ = engine.emit_bytes(emit, transmute([]u8)string("3"))
			}
			return .None
		}
		saw_doc := true
		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, src, {
			eval          = each_el,
			eval_ctx      = &saw_doc,
			eval_each     = each_el,
			spine_collect = collect_check_nil,
			runner        = runner,
			emit          = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect(t, !saw_doc)
		testing.expect_value(t, lb.lines[0], "3")

		// Opt-in `spine_collect_needs_doc = true` passes non-nil root `doc`.
		saw_doc = false
		lb_doc := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb_doc)
		res_doc := engine.execute(&plan.contract, &dec, src, {
			eval                    = each_el,
			eval_ctx                = &saw_doc,
			eval_each               = each_el,
			spine_collect           = collect_check_nil,
			spine_collect_needs_doc = true,
			runner                  = runner,
			emit                    = {fn = reg_lines_emit, data = &lb_doc},
		})
		testing.expect_value(t, res_doc.err, engine.Exec_Error.None)
		testing.expect(t, saw_doc)
		testing.expect_value(t, lb_doc.lines[0], "3")
	}

	// 3. `skip_bad = true` NEVER skips `tape.Exceeded` (`Budget.steps`), only syntax `tape.Fault`!
	{
		ndjson := transmute([]u8)string("{\"a\":{\"b\":{\"c\":1}}}\n{\"a\":2}\n")
		prog, _ := jq.compile(`.a`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, json.Spec.Json, .Lines)

		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, ndjson, {
			eval     = nil,
			skip_bad = true,
			read     = {budget = {steps = 2}},
			emit     = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.Read_Error)
		_, is_ex := res.read_err.(tape.Exceeded)
		testing.expect(t, is_ex)
		testing.expect_value(t, len(lb.lines), 0)
	}

	// 4. `guard_emit_fn`: when downstream sink rejects emission (`return false`), `emitted` stays 0 and `.Stopped` is returned.
	{
		stop_immediately :: proc(ctx: rawptr, bytes: []u8) -> bool {
			_ = ctx
			_ = bytes
			return false
		}
		echo_eval :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = doc
			_ = meta
			if !engine.emit_bytes(emit, transmute([]u8)string("1")) {
				return .Stopped
			}
			return .None
		}
		dec := engine.Decision {
			kind    = .Whole,
			spec    = json.Spec.Json,
			entry   = engine.entry_of(engine.Format_Id.Json) or_else engine.Format_Entry{},
			framing = .Single,
		}
		res := engine.execute(nil, &dec, transmute([]u8)string(`{}`), {
			eval = echo_eval,
			emit = {fn = stop_immediately},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.Stopped)
		testing.expect_value(t, res.emitted, u64(0))
	}

	// 5. OOM inside `Slot_Buffer` append returns `.No_Memory` cleanly without out-of-bounds panic.
	{
		Fail_After :: struct {
			backing: runtime.Allocator,
			armed:   bool,
		}
		fail_alloc_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
			fa := (^Fail_After)(data)
			if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
				if sync.atomic_load(&fa.armed) {
					return nil, .Out_Of_Memory
				}
			}
			return fa.backing.procedure(fa.backing.data, mode, size, alignment, old_ptr, old_size, loc)
		}

		ndjson := transmute([]u8)string("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n{\"a\":4}\n")
		dec := engine.Decision {
			kind        = .Records_Parallel,
			spec        = json.Spec.Json,
			entry       = engine.entry_of(engine.Format_Id.Json) or_else engine.Format_Entry{},
			framing     = .Lines,
			demand_mode = .Whole,
			parallel    = true,
		}
		emit_big_oom :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = doc
			_ = meta
			fa := (^Fail_After)(ctx)
			sync.atomic_store(&fa.armed, true)
			buf: [4096]u8
			for i in 0 ..< len(buf) {
				buf[i] = 'x'
			}
			if !engine.emit_bytes(emit, buf[:]) {
				return .Stopped
			}
			return .None
		}

		fa := Fail_After{backing = context.allocator}
		res := engine.execute(nil, &dec, ndjson, {
			eval                 = emit_big_oom,
			eval_ctx             = &fa,
			eval_ctx_thread_safe = true,
			runner               = runner,
			allocator            = runtime.Allocator{procedure = fail_alloc_proc, data = &fa},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.No_Memory)
	}
}

// Regressions for Neon follow-up items:
// 1) DSV + `dups == .All` routes and executes cleanly without `Bad_Option{"dups"}`.
// 2) Same arena passed for BOTH `allocator` and `read.scratch` + stateful `pred_ctx` / `eval_each_ctx` in `execute_files` are race-free under TSan.
// 3) Direct / Conditional / Spine routes guard `opts.read.dups` fallback, and DSV cell OOM maps to `.No_Memory`.
@(test)
regression_dsv_dups_same_arena_ctx_gates_and_direct_oom :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	// 1. DSV + `dups == .All` works through `decide` + `execute` and through direct `.Records_Serial` fallback.
	{
		csv_dups := transmute([]u8)string("a,a\n1,2\n")
		prog, _ := jq.compile(`.`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)

		dec := engine.decide(&plan.contract, dsv.Spec.Csv, .Lines, {dups = .All})
		testing.expect_value(t, dec.kind, engine.Route_Kind.Whole)

		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, csv_dups, {
			eval = nil,
			read = {dups = .All},
			emit = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, lb.lines[0], `[{"a":"1","a":"2"}]`)

		// Forced `.Records_Serial` with `read.dups = .All` on CSV also falls back cleanly to `exec_whole`.
		dec_recs := engine.Decision {
			kind    = .Records_Serial,
			spec    = dsv.Spec.Csv,
			entry   = engine.entry_of(engine.Format_Id.Csv) or_else engine.Format_Entry{},
			framing = .Lines,
		}
		lb2 := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb2)
		res2 := engine.execute(&plan.contract, &dec_recs, csv_dups, {
			eval = nil,
			read = {dups = .All},
			emit = {fn = reg_lines_emit, data = &lb2},
		})
		testing.expect_value(t, res2.err, engine.Exec_Error.None)
		testing.expect_value(t, lb2.lines[0], `[{"a":"1","a":"2"}]`)
	}

	// 2. Shared `mem.Arena` passed for BOTH `allocator` and `read.scratch` simultaneously across parallel `execute_files`.
	{
		dbuf := strings.builder_make()
		defer strings.builder_destroy(&dbuf)
		strings.write_string(&dbuf, `{"root":`)
		for _ in 0 ..< 1100 {
			strings.write_byte(&dbuf, '[')
		}
		strings.write_byte(&dbuf, '1')
		for _ in 0 ..< 1100 {
			strings.write_byte(&dbuf, ']')
		}
		strings.write_byte(&dbuf, '}')
		deep_json := transmute([]u8)strings.to_string(dbuf)

		files: [6]engine.File_Input
		for i in 0 ..< len(files) {
			files[i] = {"deep.json", deep_json, json.Spec.Json, .Single}
		}

		shared_mem := make([]u8, 2 * 1024 * 1024)
		defer delete(shared_mem)
		shared_arena: mem.Arena
		mem.arena_init(&shared_arena, shared_mem)
		shared_alloc := mem.arena_allocator(&shared_arena)

		emit_one :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = doc
			_ = meta
			_ = engine.emit_bytes(emit, transmute([]u8)string("ok"))
			return .None
		}

		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute_files(nil, files[:], {runner = runner}, {
			eval      = emit_one,
			runner    = runner,
			read      = {budget = {depth = 1200}, scratch = shared_alloc},
			allocator = shared_alloc,
			emit      = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, res.emitted, u64(6))
	}

	// 3. `execute_files` serializes cleanly under TSan when `pred_ctx` or `eval_each_ctx` is unsynchronized,
	// even if `workers.init != nil` for `eval_ctx`!
	{
		prog, _ := jq.compile(`select(.ok == true)`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		plan.contract.hints.conditional.cmp.op = .None

		files := [4]engine.File_Input {
			{"0.json", transmute([]u8)string(`{"ok":true}`), json.Spec.Json, .Single},
			{"1.json", transmute([]u8)string(`{"ok":false}`), json.Spec.Json, .Single},
			{"2.json", transmute([]u8)string(`{"ok":true}`), json.Spec.Json, .Single},
			{"3.json", transmute([]u8)string(`{"ok":true}`), json.Spec.Json, .Single},
		}

		init_noop :: proc(parent: rawptr, idx: int, alloc: runtime.Allocator) -> rawptr {
			_ = parent
			_ = idx
			_ = alloc
			return nil
		}
		pred_inc :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta) -> (bool, engine.Exec_Error) {
			_ = doc
			_ = meta
			st := (^Stateful_Eval_Ctx)(ctx)
			st.calls += 1 // non-atomic write: TSan fails immediately if concurrent!
			return st.calls != 2, .None
		}
		pass_eval :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = doc
			_ = meta
			_ = engine.emit_bytes(emit, transmute([]u8)string("y"))
			return .None
		}

		pred_state: Stateful_Eval_Ctx
		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute_files(&plan.contract, files[:], {runner = runner}, {
			eval      = pass_eval,
			pred_eval = pred_inc,
			pred_ctx  = &pred_state,
			workers   = {init = init_noop},
			runner    = runner,
			emit      = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, pred_state.calls, 4)
		testing.expect_value(t, len(lb.lines), 3)
	}

	// 4. `dups_needs_build` fallback guards inside `exec_projection_direct`, `exec_conditional_whole`, `exec_spine_parallel`
	// when caller passes `read.dups = .All` without updating `Decision`.
	{
		dup_json := transmute([]u8)string(`{"a":1,"a":2}`)
		emit_all_doc :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = meta
			txt, _, werr := json.write(doc, .Json, {})
			if werr != nil {
				return .Write_Error
			}
			defer delete(txt)
			_ = engine.emit_bytes(emit, txt)
			return .None
		}

		p_dir, _ := jq.compile(`.a`)
		defer jq.destroy_program(p_dir)
		pl_dir := jq.analyze(p_dir)
		defer jq.destroy_plan(&pl_dir)
		d_dir := engine.decide(&pl_dir.contract, json.Spec.Json, .Single)
		testing.expect_value(t, d_dir.kind, engine.Route_Kind.Projection_Direct)

		lb1 := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb1)
		r1 := engine.execute(&pl_dir.contract, &d_dir, dup_json, {
			eval = emit_all_doc,
			read = {dups = .All},
			emit = {fn = reg_lines_emit, data = &lb1},
		})
		testing.expect_value(t, r1.err, engine.Exec_Error.None)
		testing.expect_value(t, lb1.lines[0], `{"a":1,"a":2}`)

		p_cw, _ := jq.compile(`select(.a == 1)`)
		defer jq.destroy_program(p_cw)
		pl_cw := jq.analyze(p_cw)
		defer jq.destroy_plan(&pl_cw)
		d_cw := engine.decide(&pl_cw.contract, json.Spec.Json, .Single)
		testing.expect_value(t, d_cw.kind, engine.Route_Kind.Conditional_Whole)

		lb2 := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb2)
		r2 := engine.execute(&pl_cw.contract, &d_cw, dup_json, {
			eval = emit_all_doc,
			read = {dups = .All},
			emit = {fn = reg_lines_emit, data = &lb2},
		})
		testing.expect_value(t, r2.err, engine.Exec_Error.None)
		testing.expect_value(t, lb2.lines[0], `{"a":1,"a":2}`)

		p_sp, _ := jq.compile(`.items[] | .a`)
		defer jq.destroy_program(p_sp)
		pl_sp := jq.analyze(p_sp)
		defer jq.destroy_plan(&pl_sp)
		d_sp := engine.Decision {
			kind        = .Spine_Parallel,
			active_hint = .Spine_Split,
			spec        = json.Spec.Json,
			entry       = engine.entry_of(engine.Format_Id.Json) or_else engine.Format_Entry{},
			framing     = .Single,
			parallel    = true,
		}
		lb3 := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb3)
		r3 := engine.execute(&pl_sp.contract, &d_sp, transmute([]u8)string(`{"items":[{"a":1,"a":2}]}`), {
			eval      = emit_all_doc,
			eval_each = emit_all_doc,
			runner    = runner,
			read      = {dups = .All},
			emit      = {fn = reg_lines_emit, data = &lb3},
		})
		testing.expect_value(t, r3.err, engine.Exec_Error.None)
		testing.expect_value(t, lb3.lines[0], `{"items":[{"a":1,"a":2}]}`)
	}

	// 5. DSV cell temp-buffer OOM in `exec_projection_direct` propagates as `.No_Memory` (not `.Write_Error`).
	{
		Fail_Size :: struct {
			backing: runtime.Allocator,
			target:  int,
		}
		fail_size_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
			fs := (^Fail_Size)(data)
			if (mode == .Alloc || mode == .Alloc_Non_Zeroed) && size == fs.target {
				return nil, .Out_Of_Memory
			}
			return fs.backing.procedure(fs.backing.data, mode, size, alignment, old_ptr, old_size, loc)
		}

		// JSON string with `t.n == 73` raw bytes (`"a"` + `\n` (2) + 70 `'b'`s) triggers `make([]u8, 73, alloc)` in `append_node_dsv_cell`.
		payload := strings.builder_make()
		defer strings.builder_destroy(&payload)
		strings.write_string(&payload, `{"s":"a\n`)
		for _ in 0 ..< 70 {
			strings.write_byte(&payload, 'b')
		}
		strings.write_string(&payload, `"}`)

		prog, _ := jq.compile(`.s`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, json.Spec.Json, .Single)
		testing.expect_value(t, dec.kind, engine.Route_Kind.Projection_Direct)

		fs := Fail_Size{backing = context.allocator, target = 73}
		lb := Reg_Lines{alloc = context.allocator}
		defer reg_lines_destroy(&lb)
		res := engine.execute(&plan.contract, &dec, transmute([]u8)strings.to_string(payload), {
			direct_out = .Csv,
			allocator  = runtime.Allocator{procedure = fail_size_proc, data = &fs},
			emit       = {fn = reg_lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.No_Memory)
	}
}
