package engine_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:cbor"
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
Jq_Eval_State :: struct {
	prog:       ^jq.Program,
	h:          query.Heap,
	run:        jq.Run,
	hooks:      jq.Hooks,
	hook_data:  Eval_Hook_Data,
	keep_orig:  bool,
	eval_count: int,
	alloc:      runtime.Allocator,
}

@(private = "file")
Eval_Hook_Data :: struct {
	meta: engine.Record_Meta,
}

@(private = "file")
hook_input_filename :: proc(data: rawptr, h: ^query.Heap) -> (query.Value, query.Status) {
	hd := (^Eval_Hook_Data)(data)
	return query.text_value(h, hd.meta.file_path)
}

@(private = "file")
hook_input_line_number :: proc(data: rawptr) -> i64 {
	hd := (^Eval_Hook_Data)(data)
	return i64(hd.meta.record_index) + 1
}

@(private = "file")
eval_state_init :: proc(st: ^Jq_Eval_State, prog: ^jq.Program, keep_orig: bool, alloc := context.allocator) {
	st^ = {
		prog      = prog,
		keep_orig = keep_orig,
		alloc     = alloc,
	}
	query.heap_init(&st.h, alloc)
	st.h.keep_origins = keep_orig
	st.hooks = {
		data              = &st.hook_data,
		input_filename    = hook_input_filename,
		input_line_number = hook_input_line_number,
	}
	jq.run_init(&st.run, prog, &st.h, nil, &st.hooks)
}

@(private = "file")
eval_state_destroy :: proc(st: ^Jq_Eval_State) {
	jq.run_destroy(&st.run)
	query.heap_destroy(&st.h)
	st^ = {}
}

@(private = "file")
worker_eval_init :: proc(parent_ctx: rawptr, worker_idx: int, alloc: runtime.Allocator) -> rawptr {
	_ = worker_idx
	parent := (^Jq_Eval_State)(parent_ctx)
	ws := new(Jq_Eval_State, alloc)
	eval_state_init(ws, parent.prog, parent.keep_orig, alloc)
	return ws
}

@(private = "file")
worker_eval_fini :: proc(parent_ctx: rawptr, worker_idx: int, worker_ctx: rawptr) {
	_ = parent_ctx
	_ = worker_idx
	ws := (^Jq_Eval_State)(worker_ctx)
	if ws != nil {
		alloc := ws.alloc
		eval_state_destroy(ws)
		free(ws, alloc)
	}
}

@(private = "file")
jq_doc_eval :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	st := (^Jq_Eval_State)(ctx)
	st.eval_count += 1
	st.hook_data.meta = meta
	st.h.keep_origins = st.keep_orig
	st.h.tainted = false
	query.clear_error(&st.h)

	inp, status := query.document_value(&st.h, doc^, owned = false)
	if status != .Ok {
		return .Failed
	}

	Out_Bridge :: struct {
		h:       ^query.Heap,
		emit:    engine.Emitter,
		buf:     [dynamic]u8,
		err:     engine.Exec_Error,
		alloc:   runtime.Allocator,
	}
	on_val :: proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool {
		b := (^Out_Bridge)(data)
		defer query.release(h, v)
		clear(&b.buf)
		if query.write_json(h, &b.buf, v) != .Ok {
			if h.tainted {
				b.err = .Tainted
			} else {
				query.clear_error(h)
				b.err = .Write_Error
			}
			return false
		}
		if !engine.emit_bytes(b.emit, b.buf[:]) {
			b.err = .Stopped
			return false
		}
		return true
	}

	br := Out_Bridge{
		h     = &st.h,
		emit  = emit,
		buf   = make([dynamic]u8, 0, 128, st.alloc),
		alloc = st.alloc,
	}
	defer delete(br.buf)

	end := jq.run_value(&st.run, inp, on_val, &br)
	if br.err != .None {
		return br.err
	}
	if st.h.tainted || end == .Tainted {
		return .Tainted
	}
	switch end {
	case .Done:    return .None
	case .Stopped: return .Stopped
	case .Halted:  return .Halted
	case .Failed:  return .Failed
	case .Tainted: return .Tainted
	}
	return .None
}

@(private = "file")
jq_doc_pred :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta) -> (matched: bool, err: engine.Exec_Error) {
	st := (^Jq_Eval_State)(ctx)
	st.hook_data.meta = meta
	st.h.tainted = false
	query.clear_error(&st.h)

	inp, status := query.document_value(&st.h, doc^, owned = false)
	if status != .Ok {
		return false, .Failed
	}

	Pred_Cap :: struct {
		matched: bool,
	}
	on_pred :: proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool {
		p := (^Pred_Cap)(data)
		vt := query.type_of(v)
		if vt != .Null && vt != .False && vt != .Absent {
			p.matched = true
		}
		query.release(h, v)
		return !p.matched
	}

	pc: Pred_Cap
	end := jq.run_value(&st.run, inp, on_pred, &pc)
	if st.h.tainted || end == .Tainted {
		return false, .Tainted
	}
	switch end {
	case .Done, .Stopped: return pc.matched, .None
	case .Halted:         return false, .Halted
	case .Failed:         return false, .Failed
	case .Tainted:        return false, .Tainted
	}
	return false, .None
}

@(private = "file")
Lines_Buf :: struct {
	lines: [dynamic]string,
	alloc: runtime.Allocator,
}

@(private = "file")
lines_emit :: proc(data: rawptr, bytes: []u8) -> bool {
	lb := (^Lines_Buf)(data)
	append(&lb.lines, strings.clone(string(bytes), lb.alloc))
	return true
}

@(private = "file")
destroy_lines :: proc(lb: ^Lines_Buf) {
	for s in lb.lines {
		delete(s, lb.alloc)
	}
	delete(lb.lines)
}

@(private = "file")
run_jq_engine :: proc(
	t: ^testing.T,
	jq_src: string,
	spec: engine.Spec,
	framing: engine.Framing,
	input: []u8,
	route_opts := engine.Route_Options{},
	exec_opts := engine.Exec_Options{},
) -> (
	res: engine.Exec_Result,
	dec: engine.Decision,
	lines: Lines_Buf,
) {
	prog, errs := jq.compile(jq_src)
	testing.expectf(t, len(errs) == 0, "compile %q failed: %v", jq_src, errs)
	defer jq.destroy_program(prog)

	plan := jq.analyze(prog)
	defer jq.destroy_plan(&plan)

	dec = engine.decide(&plan.contract, spec, framing, route_opts)

	st := new(Jq_Eval_State)
	eval_state_init(st, prog, dec.keep_origins)
	defer {
		eval_state_destroy(st)
		free(st)
	}

	lb := new(Lines_Buf)
	lb.alloc = context.allocator
	defer free(lb)
	eopts := exec_opts
	if eopts.eval == nil {
		eopts.eval = jq_doc_eval
		eopts.eval_ctx = st
	}
	eopts.emit = engine.Emitter{fn = lines_emit, data = lb}

	res = engine.execute(&plan.contract, &dec, input, eopts)
	return res, dec, lb^
}

@(test)
exec_scan_parity_facts_and_where :: proc(t: ^testing.T) {
	testkit.deadline(t)

	json_src := transmute([]u8)string("{\n  // note on a\n  \"a\": 10,\n  \"b\": {\"x\": 20, \"ignored\": [1,2,3]},\n  \"c\": \"secret\"\n}\n")

	for q in ([?]string{
		`.a + .b.x`,
		`(.a | type), (.b | length), has("c")`,
		`[(.b.x | where.line), .b.x]`,
		`.a.@comment`,
	}) {
		ro_base := engine.Route_Options{comments_out = true, where_mode = strings.contains(q, "where")}
		r_scan, dec_scan, l_scan := run_jq_engine(t, q, json.Spec.Jsonc, .Single, json_src, ro_base)
		defer destroy_lines(&l_scan)
		testing.expect_value(t, dec_scan.kind, engine.Route_Kind.Scan)
		testing.expect_value(t, r_scan.err, engine.Exec_Error.None)

		ro_whole := ro_base
		ro_whole.force_whole = true
		r_whole, dec_whole, l_whole := run_jq_engine(t, q, json.Spec.Jsonc, .Single, json_src, ro_whole)
		defer destroy_lines(&l_whole)
		testing.expect_value(t, dec_whole.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, r_whole.err, engine.Exec_Error.None)

		testing.expect_value(t, len(l_scan.lines), len(l_whole.lines))
		for i in 0 ..< len(l_scan.lines) {
			testing.expectf(t, l_scan.lines[i] == l_whole.lines[i], "query %q line %d: scan=%q != whole=%q", q, i, l_scan.lines[i], l_whole.lines[i])
		}
	}
}

@(test)
exec_taint_guard_strict_contract :: proc(t: ^testing.T) {
	testkit.deadline(t)

	src := transmute([]u8)string(`{"keep": 1, "secret": 99}`)

	// Under-demanded plan (`plan` only demands `.keep`, while evaluator reads `.keep` or `.secret`).
	prog_keep, errs1 := jq.compile(`.keep`)
	testing.expect_value(t, len(errs1), 0)
	defer jq.destroy_program(prog_keep)
	under_plan := jq.analyze(prog_keep)
	defer jq.destroy_plan(&under_plan)

	prog_emit_zero_then_secret, errs2 := jq.compile(`.secret`)
	testing.expect_value(t, len(errs2), 0)
	defer jq.destroy_program(prog_emit_zero_then_secret)

	prog_emit_one_then_secret, errs3 := jq.compile(`.keep, .secret`)
	testing.expect_value(t, len(errs3), 0)
	defer jq.destroy_program(prog_emit_one_then_secret)

	// Force `.Scan` decision using `under_plan` (single field arithmetic makes it .Scan).
	dec := engine.Decision {
		kind        = .Scan,
		spec        = json.Spec.Json,
		entry       = engine.entry_of(engine.Format_Id.Json) or_else engine.Format_Entry{},
		framing     = .Single,
		demand_mode = .Partial,
	}

	// 1. 0 emits before taint, opt-out rerun -> aborts cleanly with `.Tainted`, zero corrupt emissions!
	{
		st: Jq_Eval_State
		eval_state_init(&st, prog_emit_zero_then_secret, false)
		defer eval_state_destroy(&st)
		lb := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb)

		res := engine.execute(&under_plan.contract, &dec, src, {
			eval     = jq_doc_eval,
			eval_ctx = &st,
			emit     = {fn = lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.Tainted)
		testing.expect(t, res.tainted)
		testing.expect_value(t, res.emitted, u64(0))
		testing.expect(t, !res.reran_whole)
		testing.expect_value(t, len(lb.lines), 0)
	}

	// 2. 1+ emits before taint EVEN with `rerun_whole_on_taint = true` -> MUST NEVER replay mid-stream!
	{
		st: Jq_Eval_State
		eval_state_init(&st, prog_emit_one_then_secret, false)
		defer eval_state_destroy(&st)
		lb := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb)

		res := engine.execute(&under_plan.contract, &dec, src, {
			eval                 = jq_doc_eval,
			eval_ctx             = &st,
			emit                 = {fn = lines_emit, data = &lb},
			rerun_whole_on_taint = true,
		})
		testing.expect_value(t, res.err, engine.Exec_Error.Tainted)
		testing.expect(t, res.tainted)
		testing.expect_value(t, res.emitted, u64(1))
		testing.expect(t, !res.reran_whole)
		testing.expect_value(t, len(lb.lines), 1)
		testing.expect_value(t, lb.lines[0], "1")
	}

	// 3. 0 emits before taint + `rerun_whole_on_taint = true` -> single whole rerun succeeds!
	{
		st: Jq_Eval_State
		eval_state_init(&st, prog_emit_zero_then_secret, false)
		defer eval_state_destroy(&st)
		lb := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb)

		res := engine.execute(&under_plan.contract, &dec, src, {
			eval                 = jq_doc_eval,
			eval_ctx             = &st,
			emit                 = {fn = lines_emit, data = &lb},
			rerun_whole_on_taint = true,
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect(t, res.reran_whole)
		testing.expect(t, !res.tainted)
		testing.expect_value(t, len(lb.lines), 1)
		testing.expect_value(t, lb.lines[0], "99")
	}
}

@(test)
exec_projection_direct_hint2_zero_eval_and_csv :: proc(t: ^testing.T) {
	testkit.deadline(t)

	json_doc := transmute([]u8)string(`{"user":{"name":"ada","age":36},"scores":[10,20,30],"flag":true}`)
	ndjson := transmute([]u8)string("{\"user\":{\"name\":\"ada\"},\"scores\":[10]}\n{\"user\":{\"name\":\"lin\"},\"scores\":[20]}\n")
	csv_doc := transmute([]u8)string("name,age\nada,36\n\"bob, jr\",40\n")

	// Zero-evaluator test (`eval == nil` proves evaluator is never invoked!) across all 4 projection shapes!
	for q in ([?]string{
		`.user.name`,
		`.user.name, .scores[0]`,
		`[.user.name, .flag]`,
		`{who: .user.name, pts: .scores[0]}`,
	}) {
		prog, perrs := jq.compile(q)
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)

		dec := engine.decide(&plan.contract, json.Spec.Json, .Single)
		testing.expect_value(t, dec.kind, engine.Route_Kind.Projection_Direct)

		lb_direct := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb_direct)
		r_direct := engine.execute(&plan.contract, &dec, json_doc, {
			eval = nil, // ZERO evaluator!
			emit = {fn = lines_emit, data = &lb_direct},
		})
		testing.expect_value(t, r_direct.err, engine.Exec_Error.None)

		_, dec_whole, lb_whole := run_jq_engine(t, q, json.Spec.Json, .Single, json_doc, {force_whole = true})
		defer destroy_lines(&lb_whole)
		testing.expect_value(t, dec_whole.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, len(lb_direct.lines), len(lb_whole.lines))
		for i in 0 ..< len(lb_direct.lines) {
			testing.expectf(t, lb_direct.lines[i] == lb_whole.lines[i], "proj %q line %d: %q != %q", q, i, lb_direct.lines[i], lb_whole.lines[i])
		}
	}

	// Framed NDJSON + CSV zero-evaluator projection & CSV output with header + quoting!
	{
		prog, perrs := jq.compile(`{n: .user.name, s: .scores[0]}`)
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, json.Spec.Json, .Lines)
		testing.expect_value(t, dec.kind, engine.Route_Kind.Projection_Direct)

		lb := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb)
		res := engine.execute(&plan.contract, &dec, ndjson, {
			eval = nil,
			emit = {fn = lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, len(lb.lines), 2)
		testing.expect_value(t, lb.lines[0], `{"n":"ada","s":10}`)
		testing.expect_value(t, lb.lines[1], `{"n":"lin","s":20}`)
	}
	{
		prog, perrs := jq.compile(`{who: .name, years: .age}`)
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, dsv.Spec.Csv, .Lines)
		testing.expect_value(t, dec.kind, engine.Route_Kind.Projection_Direct)

		lb := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb)
		res := engine.execute(&plan.contract, &dec, csv_doc, {
			eval              = nil,
			direct_out        = .Csv,
			direct_csv_header = true,
			emit              = {fn = lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, len(lb.lines), 3)
		testing.expect_value(t, lb.lines[0], "who,years")
		testing.expect_value(t, lb.lines[1], "ada,36")
		testing.expect_value(t, lb.lines[2], `"bob, jr",40`)
	}
	{
		// TSV direct output escaping tabs & backslashes without invoking evaluator.
		tsv_doc := transmute([]u8)string("name\tmsg\nada\thi\\\\there\n")
		prog, perrs := jq.compile(`{who: .name, note: .msg}`)
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, dsv.Spec.Tsv, .Lines)
		testing.expect_value(t, dec.kind, engine.Route_Kind.Projection_Direct)

		lb := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb)
		res := engine.execute(&plan.contract, &dec, tsv_doc, {
			eval              = nil,
			direct_out        = .Tsv,
			direct_csv_header = true,
			emit              = {fn = lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, len(lb.lines), 2)
		testing.expect_value(t, lb.lines[0], "who\tnote")
		testing.expect_value(t, lb.lines[1], "ada\thi\\\\there")
	}

	// Wrong_Kind fallback when `eval != nil` vs `.Failed` when `eval == nil`.
	{
		bad_shape := transmute([]u8)string(`{"a":5}`)
		prog, _ := jq.compile(`.a.b`)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, json.Spec.Json, .Single)
		testing.expect_value(t, dec.kind, engine.Route_Kind.Projection_Direct)

		lb := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb)
		r_no_eval := engine.execute(&plan.contract, &dec, bad_shape, {
			eval = nil,
			emit = {fn = lines_emit, data = &lb},
		})
		testing.expect_value(t, r_no_eval.err, engine.Exec_Error.Failed)

		r_with_eval, _, l_eval := run_jq_engine(t, `.a.b`, json.Spec.Json, .Single, bad_shape)
		defer destroy_lines(&l_eval)
		testing.expect_value(t, r_with_eval.err, engine.Exec_Error.Failed)
	}
}

@(test)
exec_conditional_whole_hint3_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)

	ndjson := transmute([]u8)string(
		"{\"status\":\"ok\",\"id\":1,\"payload\":[1,2]}\n" +
		"{\"status\":\"skip\",\"id\":2,\"payload\":[3,4]}\n" +
		"{\"status\":\"ok\",\"id\":3,\"payload\":[5,6]}\n",
	)
	csv_with_comments_and_bad := transmute([]u8)string(
		"# initial comment\n" +
		"status,qty\n" +
		"\"unclosed,999\n" +
		"ok,9500\n" +
		"skip,9999\n" +
		"ok,100\n",
	)

	// 1. Simple compare (`select(.status == "ok")`): `pred_eval == nil` works natively, and `eval` is called ONLY on matched rows!
	{
		prog, perrs := jq.compile(`select(.status == "ok")`)
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, json.Spec.Json, .Lines)
		testing.expect_value(t, dec.kind, engine.Route_Kind.Conditional_Whole)

		st: Jq_Eval_State
		eval_state_init(&st, prog, false)
		defer eval_state_destroy(&st)
		lb := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb)

		res := engine.execute(&plan.contract, &dec, ndjson, {
			eval      = jq_doc_eval,
			eval_ctx  = &st,
			pred_eval = nil,
			emit      = {fn = lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, res.records, u64(3))
		testing.expect_value(t, st.eval_count, 2) // skipped record #2!
		testing.expect_value(t, len(lb.lines), 2)
		testing.expect_value(t, lb.lines[0], `{"status":"ok","id":1,"payload":[1,2]}`)
		testing.expect_value(t, lb.lines[1], `{"status":"ok","id":3,"payload":[5,6]}`)

		// Parity with forced whole.
		_, _, l_whole := run_jq_engine(t, `select(.status == "ok")`, json.Spec.Json, .Lines, ndjson, {force_whole = true})
		defer destroy_lines(&l_whole)
		testing.expect_value(t, len(l_whole.lines), len(lb.lines))
		for i in 0 ..< len(lb.lines) {
			testing.expect_value(t, lb.lines[i], l_whole.lines[i])
		}
	}

	// 2. General predicate (`select(.qty | tonumber >= 9000)`) over CSV with `#` comments AND broken row #0!
	{
		prog, perrs := jq.compile(`select(.qty | tonumber >= 9000)`)
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		dec := engine.decide(&plan.contract, dsv.Spec.Csv, .Lines)
		testing.expect_value(t, dec.kind, engine.Route_Kind.Conditional_Whole)

		// Extract predicate-only program for `pred_eval` (or compile `.qty | tonumber >= 9000`!).
		pred_prog, pperrs := jq.compile(`.qty | tonumber >= 9000`)
		testing.expect_value(t, len(pperrs), 0)
		defer jq.destroy_program(pred_prog)

		eval_st, pred_st: Jq_Eval_State
		eval_state_init(&eval_st, prog, false)
		defer eval_state_destroy(&eval_st)
		eval_state_init(&pred_st, pred_prog, false)
		defer eval_state_destroy(&pred_st)

		lb := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb)
		res := engine.execute(&plan.contract, &dec, csv_with_comments_and_bad, {
			eval      = jq_doc_eval,
			eval_ctx  = &eval_st,
			pred_eval = jq_doc_pred,
			pred_ctx  = &pred_st,
			skip_bad  = true,
			read      = {format = tape.Dsv_Options{comment = '#'}},
			emit      = {fn = lines_emit, data = &lb},
		})
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, res.bad_records, u64(1))
		testing.expect_value(t, eval_st.eval_count, 2) // row 3 (`ok,100`) filtered out!
		testing.expect_value(t, len(lb.lines), 2)
		testing.expect_value(t, lb.lines[0], `{"status":"ok","qty":"9500"}`)
		testing.expect_value(t, lb.lines[1], `{"status":"skip","qty":"9999"}`)
	}

	// 3. Single document Simple_Compare on `.Null` vs `.Wrong_Kind` matches jq `.Whole`.
	{
		null_doc := transmute([]u8)string(`{"a":null}`)
		res_cond, _, l_cond := run_jq_engine(t, `select(.a.b == null)`, json.Spec.Json, .Single, null_doc)
		defer destroy_lines(&l_cond)
		res_whole, _, l_whole := run_jq_engine(t, `select(.a.b == null)`, json.Spec.Json, .Single, null_doc, {force_whole = true})
		defer destroy_lines(&l_whole)
		testing.expect_value(t, res_cond.err, res_whole.err)
		testing.expect_value(t, len(l_cond.lines), len(l_whole.lines))
		testing.expect_value(t, l_cond.lines[0], l_whole.lines[0])
	}
}

@(test)
exec_records_serial_parallel_skip_bad_and_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	// Build 120 NDJSON records to test parallel ordering across threads + serial parity.
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for i in 0 ..< 120 {
		fmt.sbprintf(&sb, "{{\"id\":%d,\"v\":%d}}\n", i, i * 3 + 1)
	}
	big_ndjson := transmute([]u8)strings.to_string(sb)

	wh := engine.Worker_Hooks{init = worker_eval_init, fini = worker_eval_fini}
	r_par, dec_par, l_par := run_jq_engine(
		t,
		`.id * 1000 + .v`,
		json.Spec.Json,
		.Lines,
		big_ndjson,
		{runner = runner, input_bytes = len(big_ndjson)},
		{runner = runner, workers = wh},
	)
	defer destroy_lines(&l_par)
	testing.expect_value(t, dec_par.kind, engine.Route_Kind.Records_Parallel)
	testing.expect_value(t, r_par.err, engine.Exec_Error.None)
	testing.expect_value(t, r_par.records, u64(120))
	testing.expect_value(t, len(l_par.lines), 120)

	r_ser, dec_ser, l_ser := run_jq_engine(t, `.id * 1000 + .v`, json.Spec.Json, .Lines, big_ndjson)
	defer destroy_lines(&l_ser)
	testing.expect_value(t, dec_ser.kind, engine.Route_Kind.Records_Serial)
	testing.expect_value(t, r_ser.err, engine.Exec_Error.None)
	for i in 0 ..< 120 {
		testing.expect_value(t, l_par.lines[i], l_ser.lines[i])
	}

	// RFC 7464 JSON `.Seq` and CBOR `.Concatenated`.
	seq_bytes := []u8{0x1E, '{', '"', 'x', '"', ':', '1', '}', '\n', 0x1E, '{', '"', 'x', '"', ':', '2', '}', '\n'}
	r_seq, d_seq, l_seq := run_jq_engine(t, `.x + 10`, json.Spec.Json, .Seq, seq_bytes, {runner = runner, input_bytes = len(seq_bytes)}, {runner = runner, workers = wh})
	defer destroy_lines(&l_seq)
	testing.expect_value(t, r_seq.err, engine.Exec_Error.None)
	_ = d_seq
	testing.expect_value(t, len(l_seq.lines), 2)
	testing.expect_value(t, l_seq.lines[0], "11")
	testing.expect_value(t, l_seq.lines[1], "12")

	cbor_seq := []u8{0xA1, 0x61, 'x', 0x05, 0xA1, 0x61, 'x', 0x09}
	r_cbor, _, l_cbor := run_jq_engine(t, `.x * 2`, cbor.Spec.Cbor, .Concatenated, cbor_seq)
	defer destroy_lines(&l_cbor)
	testing.expect_value(t, r_cbor.err, engine.Exec_Error.None)
	testing.expect_value(t, len(l_cbor.lines), 2)
	testing.expect_value(t, l_cbor.lines[0], "10")
	testing.expect_value(t, l_cbor.lines[1], "18")

	// Quarantine callback + `skip_bad` on malformed middle NDJSON line.
	bad_ndjson := transmute([]u8)string("{\"x\":1}\n{broken\n{\"x\":2}\n")
	seen_bad := 0
	on_bad :: proc(ctx: rawptr, bad: tape.Bad_Record) -> bool {
		cnt := (^int)(ctx)
		cnt^ += 1
		return len(bad.text) > 0
	}
	r_skip, _, l_skip := run_jq_engine(t, `.x`, json.Spec.Json, .Lines, bad_ndjson, {}, {skip_bad = true, on_bad_record = on_bad, bad_ctx = &seen_bad})
	defer destroy_lines(&l_skip)
	testing.expect_value(t, r_skip.err, engine.Exec_Error.None)
	testing.expect_value(t, r_skip.bad_records, u64(1))
	testing.expect_value(t, seen_bad, 1)
	testing.expect_value(t, len(l_skip.lines), 2)
	testing.expect_value(t, l_skip.lines[0], "1")
	testing.expect_value(t, l_skip.lines[1], "2")

	// Without `skip_bad`, aborts cleanly with `.Read_Error`.
	r_fail, _, l_fail := run_jq_engine(t, `.x`, json.Spec.Json, .Lines, bad_ndjson)
	defer destroy_lines(&l_fail)
	testing.expect_value(t, r_fail.err, engine.Exec_Error.Read_Error)
	testing.expect(t, r_fail.read_err != nil)

	// Per-record `Budget` enforcement (`steps = 2` fails nested record).
	deep_ndjson := transmute([]u8)string("{\"a\":{\"b\":{\"c\":{\"d\":1}}}}\n")
	r_bud, _, l_bud := run_jq_engine(t, `.a`, json.Spec.Json, .Lines, deep_ndjson, {}, {read = {budget = {steps = 2}}})
	defer destroy_lines(&l_bud)
	testing.expect_value(t, r_bud.err, engine.Exec_Error.Read_Error)
	testing.expect(t, r_bud.read_err != nil)
}

@(test)
exec_spine_parallel_hint1_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, `{"items":[`)
	for i in 0 ..< 40 {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		fmt.sbprintf(&sb, "{{\"id\":%d,\"val\":%d}}", i, i + 10)
	}
	strings.write_string(&sb, `]}`)
	doc_bytes := transmute([]u8)strings.to_string(sb)

	// 1. `.Stream` Hint 1 (`items[] | .id`): parallel element split preserves strict element order vs `.Whole`.
	{
		prog_full, e1 := jq.compile(`.items[] | .id * 3`)
		testing.expect_value(t, len(e1), 0)
		defer jq.destroy_program(prog_full)
		plan := jq.analyze(prog_full)
		defer jq.destroy_plan(&plan)

		prog_each, e2 := jq.compile(`.id * 3`)
		testing.expect_value(t, len(e2), 0)
		defer jq.destroy_program(prog_each)

		dec := engine.decide(&plan.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = len(doc_bytes)})
		testing.expect_value(t, dec.kind, engine.Route_Kind.Spine_Parallel)

		each_st, full_st: Jq_Eval_State
		eval_state_init(&each_st, prog_each, false)
		defer eval_state_destroy(&each_st)
		eval_state_init(&full_st, prog_full, false)
		defer eval_state_destroy(&full_st)

		lb_sp := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb_sp)
		res_sp := engine.execute(&plan.contract, &dec, doc_bytes, {
			eval          = jq_doc_eval,
			eval_ctx      = &full_st,
			eval_each     = jq_doc_eval,
			eval_each_ctx = &each_st,
			workers       = {init = worker_eval_init, fini = worker_eval_fini},
			runner        = runner,
			emit          = {fn = lines_emit, data = &lb_sp},
		})
		testing.expect_value(t, res_sp.err, engine.Exec_Error.None)
		testing.expect_value(t, len(lb_sp.lines), 40)

		_, _, lb_w := run_jq_engine(t, `.items[] | .id * 3`, json.Spec.Json, .Single, doc_bytes, {force_whole = true})
		defer destroy_lines(&lb_w)
		testing.expect_value(t, len(lb_sp.lines), len(lb_w.lines))
		for i in 0 ..< len(lb_sp.lines) {
			testing.expect_value(t, lb_sp.lines[i], lb_w.lines[i])
		}
	}

	// 2. `.Collect` Hint 1 (`[.items[] | .val] | add`) via `spine_collect` tail combiner!
	{
		prog_full, e1 := jq.compile(`[.items[] | .val] | add`)
		testing.expect_value(t, len(e1), 0)
		defer jq.destroy_program(prog_full)
		plan := jq.analyze(prog_full)
		defer jq.destroy_plan(&plan)

		prog_each, e2 := jq.compile(`.val`)
		testing.expect_value(t, len(e2), 0)
		defer jq.destroy_program(prog_each)

		dec := engine.decide(&plan.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = len(doc_bytes)})
		testing.expect_value(t, dec.kind, engine.Route_Kind.Spine_Parallel)

		collect_add :: proc(ctx: rawptr, doc: ^tape.Document, item_outputs: [][]u8, emit: engine.Emitter) -> engine.Exec_Error {
			_ = ctx
			_ = doc
			// Build JSON array from collected item bytes and run `add` via jq!
			ab := strings.builder_make()
			defer strings.builder_destroy(&ab)
			strings.write_byte(&ab, '[')
			for item, idx in item_outputs {
				if idx > 0 {
					strings.write_byte(&ab, ',')
				}
				strings.write_bytes(&ab, item)
			}
			strings.write_byte(&ab, ']')

			adoc, berr := json.build(transmute([]u8)strings.to_string(ab), .Json)
			if berr != nil {
				return .Read_Error
			}
			defer tape.destroy(&adoc)

			p_add, _ := jq.compile(`add`)
			defer jq.destroy_program(p_add)
			ast: Jq_Eval_State
			eval_state_init(&ast, p_add, false)
			defer eval_state_destroy(&ast)
			return jq_doc_eval(&ast, &adoc, {}, emit)
		}

		each_st, full_st: Jq_Eval_State
		eval_state_init(&each_st, prog_each, false)
		defer eval_state_destroy(&each_st)
		eval_state_init(&full_st, prog_full, false)
		defer eval_state_destroy(&full_st)

		lb_col := Lines_Buf{alloc = context.allocator}
		defer destroy_lines(&lb_col)
		res_col := engine.execute(&plan.contract, &dec, doc_bytes, {
			eval          = jq_doc_eval,
			eval_ctx      = &full_st,
			eval_each     = jq_doc_eval,
			eval_each_ctx = &each_st,
			spine_collect = collect_add,
			workers       = {init = worker_eval_init, fini = worker_eval_fini},
			runner        = runner,
			emit          = {fn = lines_emit, data = &lb_col},
		})
		testing.expect_value(t, res_col.err, engine.Exec_Error.None)
		testing.expect_value(t, len(lb_col.lines), 1)
		testing.expect_value(t, lb_col.lines[0], "1180")
	}

	// 3. Hint 1 fallback when `prefix` resolves to non-array matches `.Whole` error parity cleanly.
	{
		bad_arr := transmute([]u8)string(`{"items": 123}`)
		r_sp, dec_sp, l_sp := run_jq_engine(t, `.items[] | .id`, json.Spec.Json, .Single, bad_arr, {runner = runner, input_bytes = len(bad_arr)}, {runner = runner})
		defer destroy_lines(&l_sp)
		_ = dec_sp
		r_wh, _, l_wh := run_jq_engine(t, `.items[] | .id`, json.Spec.Json, .Single, bad_arr, {force_whole = true})
		defer destroy_lines(&l_wh)
		testing.expect_value(t, r_sp.err, r_wh.err)
		testing.expect_value(t, r_sp.err, engine.Exec_Error.Failed)
	}
}

@(test)
exec_files_parallel_order_and_errors :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	prog, perrs := jq.compile(`input_filename + ":" + .v`)
	// Note: using `input_filename` would mark `.Serial.Position`, so test parallel fan-out with pure `.id + ":" + .v` AND test serial multi-file with `input_filename`!
	jq.destroy_program(prog)
	testing.expect_value(t, len(perrs), 0)

	// 1. Parallel across 6 heterogeneous files (JSON, JSONC, CSV, NDJSON, CBOR): strict deterministic output order!
	prog_par, ep := jq.compile(`[.name, .val]`)
	testing.expect_value(t, len(ep), 0)
	defer jq.destroy_program(prog_par)
	plan_par := jq.analyze(prog_par)
	defer jq.destroy_plan(&plan_par)

	files := [?]engine.File_Input {
		{"f0.json", transmute([]u8)string(`{"name":"a","val":1}`), json.Spec.Json, .Single},
		{"f1.jsonc", transmute([]u8)string("// c\n{\"name\":\"b\",\"val\":2}"), json.Spec.Jsonc, .Single},
		{"f2.csv", transmute([]u8)string("name,val\nc,3\nd,4\n"), dsv.Spec.Csv, .Lines},
		{"f3.ndjson", transmute([]u8)string("{\"name\":\"e\",\"val\":5}\n"), json.Spec.Json, .Lines},
		{"f4.cbor", []u8{0xA2, 0x64, 'n', 'a', 'm', 'e', 0x61, 'f', 0x63, 'v', 'a', 'l', 0x06}, cbor.Spec.Cbor, .Single},
		{"f5.xml", transmute([]u8)string(`<root><name>g</name><val>7</val></root>`), xml.Spec.Xml, .Single},
	}

	st_par: Jq_Eval_State
	eval_state_init(&st_par, prog_par, false)
	defer eval_state_destroy(&st_par)

	lb_par := Lines_Buf{alloc = context.allocator}
	defer destroy_lines(&lb_par)
	res_par := engine.execute_files(
		&plan_par.contract,
		files[:],
		{runner = runner},
		{
			eval     = jq_doc_eval,
			eval_ctx = &st_par,
			workers  = {init = worker_eval_init, fini = worker_eval_fini},
			runner   = runner,
			emit     = {fn = lines_emit, data = &lb_par},
		},
	)
	testing.expect_value(t, res_par.err, engine.Exec_Error.None)

	lb_ser := Lines_Buf{alloc = context.allocator}
	defer destroy_lines(&lb_ser)
	res_ser := engine.execute_files(
		&plan_par.contract,
		files[:],
		{},
		{
			eval     = jq_doc_eval,
			eval_ctx = &st_par,
			emit     = {fn = lines_emit, data = &lb_ser},
		},
	)
	testing.expect_value(t, res_ser.err, engine.Exec_Error.None)
	testing.expect_value(t, len(lb_par.lines), len(lb_ser.lines))
	for i in 0 ..< len(lb_par.lines) {
		testing.expect_value(t, lb_par.lines[i], lb_ser.lines[i])
	}

	// 2. Deterministic first-error order when middle file is malformed.
	bad_files := [?]engine.File_Input {
		{"ok.json", transmute([]u8)string(`{"name":"ok","val":1}`), json.Spec.Json, .Single},
		{"bad.json", transmute([]u8)string(`{broken`), json.Spec.Json, .Single},
		{"after.json", transmute([]u8)string(`{"name":"after","val":2}`), json.Spec.Json, .Single},
	}
	lb_bad := Lines_Buf{alloc = context.allocator}
	defer destroy_lines(&lb_bad)
	res_bad := engine.execute_files(
		&plan_par.contract,
		bad_files[:],
		{runner = runner},
		{
			eval     = jq_doc_eval,
			eval_ctx = &st_par,
			workers  = {init = worker_eval_init, fini = worker_eval_fini},
			runner   = runner,
			emit     = {fn = lines_emit, data = &lb_bad},
		},
	)
	testing.expect_value(t, res_bad.err, engine.Exec_Error.Read_Error)
	testing.expect_value(t, len(lb_bad.lines), 1)
	testing.expect_value(t, lb_bad.lines[0], `["ok",1]`)
}

@(test)
exec_coarse_parallel_paths_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	Raw_Accum :: struct {
		sb: strings.Builder,
	}
	raw_emit :: proc(data: rawptr, bytes: []u8) -> bool {
		a := (^Raw_Accum)(data)
		strings.write_bytes(&a.sb, bytes)
		return true
	}

	min_bytes := max(int(engine.RECORDS_PARALLEL_FROM), int(engine.SPINE_PARALLEL_FROM), 32 * 1024)

	// 1. `exec_direct_coarse_parallel` on large NDJSON (`.Emit_Slice`, `.Wrong_Kind` fallback via `null`, and error parity).
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		for idx := 0; strings.builder_len(sb) < min_bytes || idx < 400; idx += 1 {
			if idx == 150 {
				strings.write_string(&sb, "{\"v\":null,\"pad\":\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"}\n")
			} else {
				fmt.sbprintf(&sb, "{{\"v\":{{\"x\":%d}},\"pad\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}\n", idx)
			}
		}
		nd := transmute([]u8)strings.to_string(sb)

		r_par, d_par, l_par := run_jq_engine(
			t,
			`.v.x`,
			json.Spec.Json,
			.Lines,
			nd,
			{runner = runner, input_bytes = len(nd)},
			{runner = runner, coalesce_emit = true, direct_append_nl = true},
		)
		defer destroy_lines(&l_par)
		testing.expect_value(t, d_par.kind, engine.Route_Kind.Projection_Direct)
		testing.expect(t, d_par.parallel)
		testing.expect_value(t, r_par.err, engine.Exec_Error.None)

		r_ser, _, l_ser := run_jq_engine(t, `.v.x`, json.Spec.Json, .Lines, nd)
		defer destroy_lines(&l_ser)
		testing.expect_value(t, r_ser.err, engine.Exec_Error.None)

		par_cat := strings.concatenate(l_par.lines[:])
		defer delete(par_cat)
		ser_cat := make_joined_lines(l_ser.lines[:])
		defer delete(ser_cat)
		testing.expect_value(t, par_cat, ser_cat)

		// Non-object `.v` (number `1`) also preserves `.Failed` parity between coarse parallel and serial.
		sb_bad := strings.builder_make()
		defer strings.builder_destroy(&sb_bad)
		for idx := 0; strings.builder_len(sb_bad) < min_bytes || idx < 400; idx += 1 {
			if idx == 150 {
				strings.write_string(&sb_bad, "{\"v\":1,\"pad\":\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"}\n")
			} else {
				fmt.sbprintf(&sb_bad, "{{\"v\":{{\"x\":%d}},\"pad\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}\n", idx)
			}
		}
		nd_bad := transmute([]u8)strings.to_string(sb_bad)
		rp_b, _, lp_b := run_jq_engine(t, `.v.x`, json.Spec.Json, .Lines, nd_bad, {runner = runner, input_bytes = len(nd_bad)}, {runner = runner, coalesce_emit = true, direct_append_nl = true})
		defer destroy_lines(&lp_b)
		rs_b, _, ls_b := run_jq_engine(t, `.v.x`, json.Spec.Json, .Lines, nd_bad)
		defer destroy_lines(&ls_b)
		testing.expect_value(t, rp_b.err, engine.Exec_Error.Failed)
		testing.expect_value(t, rs_b.err, engine.Exec_Error.Failed)
	}

	// 2. `exec_records_coarse_parallel` on large NDJSON (`.Compact` fast_json + general evaluator + non-canonical fallback).
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		for idx := 0; strings.builder_len(sb) < min_bytes || idx < 400; idx += 1 {
			if idx == 77 {
				strings.write_string(&sb, "{\"s\":\"a\\/b\\u0041\",\"n\":77}\n")
			} else {
				fmt.sbprintf(&sb, "{{\"s\":\"row_%d_payload_0123456789abcdef\",\"n\":%d}}\n", idx, idx)
			}
		}
		nd := transmute([]u8)strings.to_string(sb)

		prog, perrs := jq.compile(`.`)
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)

		st: Jq_Eval_State
		eval_state_init(&st, prog, false)
		defer eval_state_destroy(&st)

		dec_par := engine.decide(&plan.contract, json.Spec.Json, .Lines, {runner = runner, input_bytes = len(nd)})
		testing.expect_value(t, dec_par.kind, engine.Route_Kind.Records_Parallel)

		acc_par := Raw_Accum{sb = strings.builder_make()}
		defer strings.builder_destroy(&acc_par.sb)
		res_par := engine.execute(&plan.contract, &dec_par, nd, {
			eval          = jq_doc_eval_nl,
			eval_ctx      = &st,
			workers       = {init = worker_eval_init, fini = worker_eval_fini},
			runner        = runner,
			fast_json     = .Compact,
			coalesce_emit = true,
			emit          = {fn = raw_emit, data = &acc_par},
		})
		testing.expect_value(t, res_par.err, engine.Exec_Error.None)

		dec_ser := engine.decide(&plan.contract, json.Spec.Json, .Lines)
		acc_ser := Raw_Accum{sb = strings.builder_make()}
		defer strings.builder_destroy(&acc_ser.sb)
		res_ser := engine.execute(&plan.contract, &dec_ser, nd, {
			eval     = jq_doc_eval_nl,
			eval_ctx = &st,
			emit     = {fn = raw_emit, data = &acc_ser},
		})
		testing.expect_value(t, res_ser.err, engine.Exec_Error.None)
		testing.expect_value(t, strings.to_string(acc_par.sb), strings.to_string(acc_ser.sb))
	}

	// 3. `exec_spine_coarse_parallel`: `.Stream` (quoted string crossing chunk boundary + `.Pretty2`), `.Collect` compact, and `.Length` with `eval_each_count`.
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		strings.write_string(&sb, `{"items":[`)
		for idx := 0; strings.builder_len(sb) < min_bytes || idx < 450; idx += 1 {
			if idx > 0 {
				strings.write_byte(&sb, ',')
			}
			fmt.sbprintf(&sb, "{{\"id\":%d,\"msg\":\"alpha beta gamma_%d\"}}", idx, idx)
		}
		// Add a trailing long quoted string right before closing `]` so `close_chunk.entry_quoted == true` can occur.
		strings.write_string(&sb, `,{"id":999999,"msg":"`)
		for _ in 0 ..< 4096 {
			strings.write_byte(&sb, 'q')
		}
		strings.write_string(&sb, `"}]}`)
		doc_bytes := transmute([]u8)strings.to_string(sb)

		// 3a. `.Stream` `.Compact` identity (`fast_json_each = .Compact` + `coalesce_emit`)
		{
			p_full, _ := jq.compile(`.items[]`)
			defer jq.destroy_program(p_full)
			pl := jq.analyze(p_full, {materialize_each = true})
			defer jq.destroy_plan(&pl)
			p_id, _ := jq.compile(`.`)
			defer jq.destroy_program(p_id)

			st_full, st_each: Jq_Eval_State
			eval_state_init(&st_full, p_full, false)
			defer eval_state_destroy(&st_full)
			eval_state_init(&st_each, p_id, false)
			defer eval_state_destroy(&st_each)

			dec := engine.decide(&pl.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = len(doc_bytes)})
			testing.expect_value(t, dec.kind, engine.Route_Kind.Spine_Parallel)

			acc_s := Raw_Accum{sb = strings.builder_make()}
			defer strings.builder_destroy(&acc_s.sb)
			r_s := engine.execute(&pl.contract, &dec, doc_bytes, {
				eval           = jq_doc_eval_nl,
				eval_ctx       = &st_full,
				eval_each      = jq_doc_eval_nl,
				eval_each_ctx  = &st_each,
				workers        = {init = worker_eval_init, fini = worker_eval_fini},
				runner         = runner,
				fast_json_each = .Compact,
				coalesce_emit  = true,
				emit           = {fn = raw_emit, data = &acc_s},
			})
			testing.expect_value(t, r_s.err, engine.Exec_Error.None)

			_, _, l_w := run_jq_engine(t, `.items[]`, json.Spec.Json, .Single, doc_bytes, {force_whole = true})
			defer destroy_lines(&l_w)
			want_s := make_joined_lines(l_w.lines[:])
			defer delete(want_s)
			testing.expect_value(t, strings.to_string(acc_s.sb), want_s)
		}

		// 3b. `.Collect` compact (`[.items[] | {id}]` -> `spine_collect_compact = true`)
		{
			p_full, _ := jq.compile(`.items | map({id})`)
			defer jq.destroy_program(p_full)
			pl := jq.analyze(p_full, {materialize_each = true})
			defer jq.destroy_plan(&pl)

			p_each := p_full^
			p_each.body = pl.each_body

			st_full, st_each: Jq_Eval_State
			eval_state_init(&st_full, p_full, false)
			defer eval_state_destroy(&st_full)
			eval_state_init(&st_each, &p_each, false)
			defer eval_state_destroy(&st_each)

			dec := engine.decide(&pl.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = len(doc_bytes)})
			testing.expect_value(t, dec.kind, engine.Route_Kind.Spine_Parallel)

			acc_c := Raw_Accum{sb = strings.builder_make()}
			defer strings.builder_destroy(&acc_c.sb)
			r_c := engine.execute(&pl.contract, &dec, doc_bytes, {
				eval                  = jq_doc_eval_nl,
				eval_ctx              = &st_full,
				eval_each             = jq_doc_eval,
				eval_each_ctx         = &st_each,
				workers               = {init = worker_eval_init, fini = worker_eval_fini},
				runner                = runner,
				spine_collect_compact = true,
				emit                  = {fn = raw_emit, data = &acc_c},
			})
			testing.expect_value(t, r_c.err, engine.Exec_Error.None)

			_, _, l_w := run_jq_engine(t, `.items | map({id})`, json.Spec.Json, .Single, doc_bytes, {force_whole = true})
			defer destroy_lines(&l_w)
			want := fmt.aprintf("%s\n", l_w.lines[0])
			defer delete(want)
			testing.expect_value(t, strings.to_string(acc_c.sb), want)
		}

		// 3c. `.Length` with `eval_each_count` + `emit_spine_length`
		{
			p_full, _ := jq.compile(`[.items[].msg | splits(" +")] | length`)
			defer jq.destroy_program(p_full)
			pl := jq.analyze(p_full, {materialize_each = true})
			defer jq.destroy_plan(&pl)

			p_each := p_full^
			p_each.body = pl.each_body

			st_full, st_each: Jq_Eval_State
			eval_state_init(&st_full, p_full, false)
			defer eval_state_destroy(&st_full)
			eval_state_init(&st_each, &p_each, false)
			defer eval_state_destroy(&st_each)

			dec := engine.decide(&pl.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = len(doc_bytes)})
			testing.expect_value(t, dec.kind, engine.Route_Kind.Spine_Parallel)

			count_each :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta) -> (u64, engine.Exec_Error) {
				_ = meta
				st := (^Jq_Eval_State)(ctx)
				st.h.tainted = false
				query.clear_error(&st.h)
				inp, s := query.document_value(&st.h, doc^, owned = false)
				if s != .Ok {
					return 0, .Failed
				}
				c, end := jq.run_count(&st.run, inp)
				if st.h.tainted || end == .Tainted {
					return 0, .Tainted
				}
				if end != .Done {
					return 0, .Failed
				}
				return c, .None
			}
			emit_total :: proc(ctx: rawptr, total: u64, emit: engine.Emitter) -> engine.Exec_Error {
				_ = ctx
				buf: [32]u8
				s := fmt.bprintf(buf[:], "%d", total)
				return .None if engine.emit_bytes(emit, transmute([]u8)s) else .Stopped
			}

			lb_cnt := Lines_Buf{alloc = context.allocator}
			defer destroy_lines(&lb_cnt)
			r_cnt := engine.execute(&pl.contract, &dec, doc_bytes, {
				eval              = jq_doc_eval,
				eval_ctx          = &st_full,
				eval_each         = jq_doc_eval,
				eval_each_ctx     = &st_each,
				eval_each_count   = count_each,
				emit_spine_length = emit_total,
				workers           = {init = worker_eval_init, fini = worker_eval_fini},
				runner            = runner,
				emit              = {fn = lines_emit, data = &lb_cnt},
			})
			testing.expect_value(t, r_cnt.err, engine.Exec_Error.None)

			_, _, lb_w := run_jq_engine(t, `[.items[].msg | splits(" +")] | length`, json.Spec.Json, .Single, doc_bytes, {force_whole = true})
			defer destroy_lines(&lb_w)
			testing.expect_value(t, len(lb_cnt.lines), 1)
			testing.expect_value(t, lb_cnt.lines[0], lb_w.lines[0])
		}
	}
}

@(private = "file")
make_joined_lines :: proc(lines: []string) -> string {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for l in lines {
		strings.write_string(&sb, l)
		strings.write_byte(&sb, '\n')
	}
	return strings.clone(strings.to_string(sb))
}

@(private = "file")
jq_doc_eval_nl :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	Emit_NL :: struct {
		inner: engine.Emitter,
		buf:   [dynamic]u8,
	}
	nl_fn :: proc(d: rawptr, bytes: []u8) -> bool {
		en := (^Emit_NL)(d)
		clear(&en.buf)
		append(&en.buf, ..bytes)
		append(&en.buf, '\n')
		return engine.emit_bytes(en.inner, en.buf[:])
	}
	en := Emit_NL{inner = emit, buf = make([dynamic]u8, 0, 128, context.allocator)}
	defer delete(en.buf)
	return jq_doc_eval(ctx, doc, meta, engine.Emitter{fn = nl_fn, data = &en})
}
