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
import "stury:toml"
import "stury:xml"

@(private = "file")
Multi_Jq_Ctx :: struct {
	prog:       ^jq.Program,
	var_names:  []string,
	alloc:      runtime.Allocator,
	eval_calls: int,
}

@(private = "file")
Multi_Jq_Worker :: struct {
	prog:      ^jq.Program,
	h:         query.Heap,
	run:       jq.Run,
	globals:   []query.Value,
	built_aux: ^engine.Aux_Set,
	alloc:     runtime.Allocator,
}

@(private = "file")
ensure_worker_run :: proc(w: ^Multi_Jq_Worker, ctx: ^Multi_Jq_Ctx, aux: ^engine.Aux_Set) -> bool {
	if w.built_aux == aux && w.run.m.prog != nil {
		return true
	}
	if w.run.m.prog != nil {
		jq.run_destroy(&w.run)
		for g in w.globals {
			query.release(&w.h, g)
		}
		delete(w.globals, w.alloc)
		query.heap_destroy(&w.h)
	}
	w^ = {prog = ctx.prog, alloc = w.alloc, built_aux = aux}
	query.heap_init(&w.h, w.alloc)

	globals, gerr := make([]query.Value, len(ctx.prog.globals), w.alloc)
	if gerr != nil {
		query.heap_destroy(&w.h)
		return false
	}
	for &g in globals {
		g = query.NULL
	}
	for gname, gi in ctx.prog.globals {
		if gi < 2 {
			continue
		}
		if b, found := engine.aux_binding_for(aux, gname); found {
			v, st := engine.aux_binding_to_value(b, &w.h)
			if st != .Ok {
				for g in globals {
					query.release(&w.h, g)
				}
				delete(globals, w.alloc)
				query.heap_destroy(&w.h)
				return false
			}
			globals[gi] = v
		}
	}
	w.globals = globals
	jq.run_init(&w.run, ctx.prog, &w.h, globals)
	return true
}

@(private = "file")
destroy_worker_run :: proc(w: ^Multi_Jq_Worker) {
	if w.run.m.prog != nil {
		jq.run_destroy(&w.run)
	}
	for g in w.globals {
		query.release(&w.h, g)
	}
	delete(w.globals, w.alloc)
	query.heap_destroy(&w.h)
	w^ = {}
}

@(private = "file")
multi_worker_init :: proc(parent_ctx: rawptr, worker_idx: int, alloc: runtime.Allocator) -> rawptr {
	_ = worker_idx
	ctx := (^Multi_Jq_Ctx)(parent_ctx)
	w := new(Multi_Jq_Worker, alloc)
	w^ = {prog = ctx.prog, alloc = alloc}
	return w
}

@(private = "file")
multi_worker_fini :: proc(parent_ctx: rawptr, worker_idx: int, worker_ctx: rawptr) {
	_ = parent_ctx
	_ = worker_idx
	w := (^Multi_Jq_Worker)(worker_ctx)
	if w != nil {
		alloc := w.alloc
		destroy_worker_run(w)
		free(w, alloc)
	}
}

@(private = "file")
eval_multi_serial :: proc(ctx: rawptr, aux: ^engine.Aux_Set, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	_ = meta
	mctx := (^Multi_Jq_Ctx)(ctx)
	mctx.eval_calls += 1
	w: Multi_Jq_Worker
	w.alloc = mctx.alloc
	if !ensure_worker_run(&w, mctx, aux) {
		return .No_Memory
	}
	defer destroy_worker_run(&w)
	return eval_with_multi_worker(&w, doc, emit)
}

@(private = "file")
eval_multi_worker :: proc(ctx: rawptr, aux: ^engine.Aux_Set, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	_ = meta
	w := (^Multi_Jq_Worker)(ctx)
	mctx := Multi_Jq_Ctx{prog = w.prog, alloc = w.alloc}
	if !ensure_worker_run(w, &mctx, aux) {
		return .No_Memory
	}
	return eval_with_multi_worker(w, doc, emit)
}

@(private = "file")
eval_with_multi_worker :: proc(w: ^Multi_Jq_Worker, doc: ^tape.Document, emit: engine.Emitter) -> engine.Exec_Error {
	w.h.tainted = false
	query.clear_error(&w.h)

	inp: query.Value
	if len(doc.nodes) == 0 {
		inp = query.NULL
	} else {
		var_status: query.Status
		inp, var_status = query.document_value(&w.h, doc^, owned = false)
		if var_status != .Ok {
			return .Failed
		}
	}
	return jq_run_emit(&w.run, &w.h, inp, emit, w.alloc)
}

@(test)
cross_format_joins_and_partial_pruning :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Streaming CSV primary (`.Lines`) joined against JSON aux lookup with `index_by_key = "id"` + partial pruning.
	{
		csv_orders := transmute([]u8)string("oid,uid,qty\n101,1,2\n102,2,5\n103,99,1\n")
		json_users := transmute([]u8)string(`[
			{"id":1,"name":"Ada","secret":"s1","bio":"long"},
			{"id":2,"name":"Bob","secret":"s2","bio":"long"}
		]`)

		prog, errs := jq.compile(`{oid, name: ($users[.uid].name // "unknown")}`, {variables = {"users"}})
		testing.expect(t, len(errs) == 0)
		defer jq.destroy_program(prog)

		plan, ok := jq.analyze_with_vars(prog, {"users"})
		testing.expect(t, ok)
		defer query.destroy_plan(&plan)

		ud, uok := query.aux_demand_for(&plan, "users")
		testing.expect(t, uok)
		testing.expect_value(t, ud.mode, query.Demand_Mode.Partial)

		aux := []engine.Aux_Source{
			{
				name         = "users",
				src          = json_users,
				spec         = json.Spec.Json,
				framing      = .Single,
				index_by_key = "id",
			},
		}

		// Verify pruning BEFORE executing: load aux independently and check un-demanded `.secret` taints!
		set, lres := engine.load_aux_sources(&plan, aux, context.allocator)
		testing.expect_value(t, lres.err, engine.Exec_Error.None)
		defer engine.destroy_aux_set(&set)

		b, bok := engine.aux_binding_for(&set, "users")
		testing.expect(t, bok && b.partial)
		{
			h: query.Heap
			query.heap_init(&h, context.allocator)
			defer query.heap_destroy(&h)
			idx_val, vs := engine.aux_binding_to_value(b, &h)
			testing.expect_value(t, vs, query.Status.Ok)
			defer query.release(&h, idx_val)

			u1, m1 := query.member(&h, idx_val, "1")
			testing.expect_value(t, m1, query.Status.Ok)
			defer query.release(&h, u1)
			nm, m2 := query.member(&h, u1, "name")
			testing.expect_value(t, m2, query.Status.Ok)
			testing.expect(t, !h.tainted)
			testing.expect_value(t, query.text_of(nm), "Ada")
			query.release(&h, nm)

			sec, m3 := query.member(&h, u1, "secret")
			testing.expect_value(t, m3, query.Status.Ok)
			testing.expect(t, h.tainted)
			testing.expect_value(t, sec.kind, query.Kind.Absent)
		}

		// Execute end-to-end streaming CSV primary against indexed JSON aux source.
		sink := Lines_Buf{alloc = context.allocator}
		sink.lines.allocator = context.allocator
		defer destroy_lines(&sink)
		mctx := Multi_Jq_Ctx{prog = prog, alloc = context.allocator}

		exec_res, load_err := engine.execute_with_sources(
			&plan,
			csv_orders,
			dsv.Spec.Csv,
			.Lines,
			aux,
			{
				exec = {
					emit      = {fn = lines_emit, data = &sink},
					allocator = context.allocator,
				},
				aux_eval = eval_multi_serial,
				aux_ctx  = &mctx,
			},
		)
		testing.expect_value(t, load_err.err, engine.Exec_Error.None)
		testing.expect_value(t, exec_res.err, engine.Exec_Error.None)
		testing.expect_value(t, exec_res.emitted, u64(3))
		testing.expect_value(t, sink.lines[0], `{"oid":"101","name":"Ada"}`)
		testing.expect_value(t, sink.lines[1], `{"oid":"102","name":"Bob"}`)
		testing.expect_value(t, sink.lines[2], `{"oid":"103","name":"unknown"}`)
	}

	// 2. NDJSON primary + TOML aux lookup (non-scannable aux format `.Whole`).
	{
		ndjson_events := transmute([]u8)string("{\"env\":\"prod\",\"ms\":12}\n{\"env\":\"dev\",\"ms\":4}\n")
		toml_cfg := transmute([]u8)string("[limits.prod]\nmax_ms = 10\n[limits.dev]\nmax_ms = 50\n")

		prog, errs := jq.compile(`select(.ms > $cfg.limits[.env].max_ms) | .env`, {variables = {"cfg"}})
		testing.expect(t, len(errs) == 0)
		defer jq.destroy_program(prog)

		plan, ok := jq.analyze_with_vars(prog, {"cfg"})
		testing.expect(t, ok)
		defer query.destroy_plan(&plan)

		sink := Lines_Buf{alloc = context.allocator}
		sink.lines.allocator = context.allocator
		defer destroy_lines(&sink)
		mctx := Multi_Jq_Ctx{prog = prog, alloc = context.allocator}

		res, lres := engine.execute_with_sources(
			&plan,
			ndjson_events,
			json.Spec.Json,
			.Lines,
			{{name = "cfg", src = toml_cfg, spec = toml.Spec.Toml_1_0, framing = .Single}},
			{
				exec     = {emit = {fn = lines_emit, data = &sink}, allocator = context.allocator},
				aux_eval = eval_multi_serial,
				aux_ctx  = &mctx,
			},
		)
		testing.expect_value(t, lres.err, engine.Exec_Error.None)
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, res.emitted, u64(1))
		testing.expect_value(t, sink.lines[0], `"prod"`)
	}

	// 3. JSON primary + XML aux lookup + framed NDJSON aux + unused aux source (`.None` skipped).
	{
		json_req := transmute([]u8)string(`{"dept":"eng"}`)
		xml_org := transmute([]u8)string(`<org><dept id="eng"><lead>Grace</lead></dept><unused>dropme</unused></org>`)
		ndjson_roles := transmute([]u8)string("{\"id\":\"eng\",\"role\":\"build\",\"secret\":\"skip\"}\n{\"id\":\"ops\",\"role\":\"run\",\"secret\":\"skip\"}\n")
		bad_unused := transmute([]u8)string(`{{{definitely invalid json if ever parsed`)

		prog, errs := jq.compile_with_joins(
			`.dept as $d | {lead: ($org.org.dept | if type == "array" then .[0] else . end | .lead), roles: [$roles[] | select(.id == $d) | .role]}`,
			{variables = {"org", "roles", "unused"}},
		)
		testing.expectf(t, len(errs) == 0, "compile errors: %v", errs)
		defer jq.destroy_program(prog)

		plan, ok := jq.analyze_with_vars(prog, {"org", "roles", "unused"})
		testing.expect(t, ok)
		defer query.destroy_plan(&plan)

		// Unused aux stays `.None`.
		un_dem, un_ok := query.aux_demand_for(&plan, "unused")
		testing.expect(t, un_ok)
		testing.expect_value(t, un_dem.mode, query.Demand_Mode.None)

		aux := []engine.Aux_Source{
			{name = "org", src = xml_org, spec = xml.Spec.Xml, framing = .Single},
			{name = "roles", src = ndjson_roles, spec = json.Spec.Json, framing = .Lines},
			{name = "unused", src = bad_unused, spec = json.Spec.Json, framing = .Single},
		}

		// Verify framed NDJSON aux used per-record partial scan!
		set, lres := engine.load_aux_sources(&plan, aux, context.allocator)
		testing.expect_value(t, lres.err, engine.Exec_Error.None)
		rb, rok := engine.aux_binding_for(&set, "roles")
		testing.expect(t, rok && rb.partial && rb.records == 2)
		ub, uok := engine.aux_binding_for(&set, "unused")
		testing.expect(t, uok && ub.kind == .None)
		engine.destroy_aux_set(&set)

		sink := Lines_Buf{alloc = context.allocator}
		sink.lines.allocator = context.allocator
		defer destroy_lines(&sink)
		mctx := Multi_Jq_Ctx{prog = prog, alloc = context.allocator}

		res, _ := engine.execute_with_sources(
			&plan,
			json_req,
			json.Spec.Json,
			.Single,
			aux,
			{
				exec     = {emit = {fn = lines_emit, data = &sink}, allocator = context.allocator},
				aux_eval = eval_multi_serial,
				aux_ctx  = &mctx,
			},
		)
		testing.expect_value(t, res.err, engine.Exec_Error.None)
		testing.expect_value(t, res.emitted, u64(1))
		testing.expect_value(t, sink.lines[0], `{"lead":"Grace","roles":["build"]}`)
	}

	// 4. CSV (infer numbers) joined with CBOR aux via `aux_binding_hash_index` (`1 == 1.0`).
	{
		// CBOR array: [{"id": 1.0, "tier": "gold"}, {"id": 1, "tier": "vip"}]
		cbor_users := []u8{
			0x82,
			0xA2, 0x62, 'i', 'd', 0xF9, 0x3C, 0x00, 0x64, 't', 'i', 'e', 'r', 0x64, 'g', 'o', 'l', 'd',
			0xA2, 0x62, 'i', 'd', 0x01, 0x64, 't', 'i', 'e', 'r', 0x63, 'v', 'i', 'p',
		}
		csv_left := transmute([]u8)string("id\n1\n2\n")
		csv_opts := tape.Options{format = tape.Dsv_Options{infer = true}}

		aux := []engine.Aux_Source{
			{name = "tiers", src = cbor_users, spec = cbor.Spec.Cbor, framing = .Single, index_by_key = "id"},
		}
		set, lres := engine.load_aux_sources(nil, aux, context.allocator)
		testing.expect_value(t, lres.err, engine.Exec_Error.None)
		defer engine.destroy_aux_set(&set)

		cdoc, cerr := engine.build(csv_left, dsv.Spec.Csv, csv_opts, context.allocator)
		testing.expect_value(t, cerr, tape.Error(nil))
		defer tape.destroy(&cdoc)

		h: query.Heap
		query.heap_init(&h, context.allocator)
		defer query.heap_destroy(&h)

		lval, ls := query.document_value(&h, cdoc, false)
		testing.expect_value(t, ls, query.Status.Ok)
		defer query.release(&h, lval)

		tb, _ := engine.aux_binding_for(&set, "tiers")
		idx, is := engine.aux_binding_hash_index(tb, &h, "id")
		testing.expect_value(t, is, query.Status.Ok)
		defer query.hash_index_destroy(&idx)

		// Probe with CSV integer `1` matches BOTH `1.0` and `1` in CBOR!
		extract_id :: proc(_: rawptr, hp: ^query.Heap, row: query.Value) -> (query.Value, bool, query.Status) {
			v, s := query.member(hp, row, "id")
			return v, v.kind != .Absent, s
		}
		r0, _ := query.element(&h, lval, 0)
		defer query.release(&h, r0)
		k0, _, _ := extract_id(nil, &h, r0)
		defer query.release(&h, k0)
		matches, ms := query.hash_index_lookup(&idx, k0)
		testing.expect_value(t, ms, query.Status.Ok)
		testing.expect_value(t, len(matches), 2)
	}
}

@(test)
streaming_large_primary_with_indexed_aux_parallel_and_oom :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Build 10,000-line primary NDJSON + 200-entry JSON lookup array (only `uid` + `name` pruned!).
	num_primary :: 2000 // big enough to cross batch boundaries cleanly while fast under ASan
	pb := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&pb)
	for i in 0 ..< num_primary {
		fmt.sbprintf(&pb, "{{\"id\":%d,\"uid\":%d,\"pad\":\"xxxxxxxxxxxxxxxx\"}}\n", i, i % 50)
	}
	primary_src := transmute([]u8)strings.to_string(pb)

	ab := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&ab)
	strings.write_byte(&ab, '[')
	for i in 0 ..< 50 {
		if i > 0 {
			strings.write_byte(&ab, ',')
		}
		fmt.sbprintf(&ab, "{{\"uid\":%d,\"name\":\"u%d\",\"secret\":\"big-ignored-field\"}}", i, i)
	}
	strings.write_byte(&ab, ']')
	aux_src := transmute([]u8)strings.to_string(ab)

	prog, errs := jq.compile(`{id, who: $users[.uid | tostring].name}`, {variables = {"users"}})
	testing.expect(t, len(errs) == 0)
	defer jq.destroy_program(prog)

	plan, ok := jq.analyze_with_vars(prog, {"users"})
	testing.expect(t, ok)
	defer query.destroy_plan(&plan)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 2) == nil)
	defer host.pool_destroy(&pool)

	sink := Lines_Buf{alloc = context.allocator}
	sink.lines.allocator = context.allocator
	defer destroy_lines(&sink)
	mctx := Multi_Jq_Ctx{prog = prog, alloc = context.allocator}

	aux := []engine.Aux_Source{
		{name = "users", src = aux_src, spec = json.Spec.Json, framing = .Single, index_by_key = "uid"},
	}

	res, lres := engine.execute_with_sources(
		&plan,
		primary_src,
		json.Spec.Json,
		.Lines,
		aux,
		{
			exec = {
				emit      = {fn = lines_emit, data = &sink},
				runner    = &pool.runner,
				workers   = {init = multi_worker_init, fini = multi_worker_fini},
				allocator = context.allocator,
			},
			aux_eval = eval_multi_worker,
			aux_ctx  = &mctx,
		},
	)
	testing.expectf(t, lres.err == engine.Exec_Error.None, "lres=%v (aux0=%v)", lres, plan.aux)
	testing.expectf(t, res.err == engine.Exec_Error.None, "res=%v", res)
	testing.expect_value(t, res.records, u64(num_primary))
	testing.expect_value(t, res.emitted, u64(num_primary))
	if len(sink.lines) == num_primary {
		testing.expect_value(t, sink.lines[0], `{"id":0,"who":"u0"}`)
		testing.expect_value(t, sink.lines[num_primary - 1], `{"id":1999,"who":"u49"}`)
	}

	// OOM sweep across `load_aux_sources` (JSON partial, NDJSON framed partial, CSV partial, TOML whole) and `aux_binding_hash_index`.
	Oom_Fixture :: struct {
		plan: ^query.Plan,
		srcs: []engine.Aux_Source,
	}
	json_aux := transmute([]u8)string(`[{"uid":1,"name":"ada","drop":9},{"uid":2,"name":"bob","drop":8}]`)
	ndjson_aux := transmute([]u8)string("{\"id\":1,\"name\":\"a\"}\n{\"id\":2,\"name\":\"b\"}\n")
	csv_aux := transmute([]u8)string("id,name,drop\n1,a,x\n2,b,y\n")
	toml_aux := transmute([]u8)string("mode = \"fast\"\n")

	p2, errs2 := jq.compile(`{j: $j[.k].name, n: $nd[].name, c: $csv[].name, t: $t.mode}`, {variables = {"j", "nd", "csv", "t"}})
	testing.expect(t, len(errs2) == 0)
	defer jq.destroy_program(p2)
	plan2, _ := jq.analyze_with_vars(p2, {"j", "nd", "csv", "t"})
	defer query.destroy_plan(&plan2)

	fix := Oom_Fixture{
		plan = &plan2,
		srcs = {
			{name = "j", src = json_aux, spec = json.Spec.Json, framing = .Single, index_by_key = "uid"},
			{name = "nd", src = ndjson_aux, spec = json.Spec.Json, framing = .Lines},
			{name = "csv", src = csv_aux, spec = dsv.Spec.Csv, framing = .Lines},
			{name = "t", src = toml_aux, spec = toml.Spec.Toml_1_0, framing = .Single},
		},
	}

	run_aux_oom :: proc(raw_f: rawptr, alloc: runtime.Allocator) {
		f := (^Oom_Fixture)(raw_f)
		set, lres := engine.load_aux_sources(f.plan, f.srcs, alloc)
		if lres.err != .None {
			return
		}
		defer engine.destroy_aux_set(&set)
		h: query.Heap
		query.heap_init(&h, alloc)
		defer query.heap_destroy(&h)
		if b, ok := engine.aux_binding_for(&set, "j"); ok {
			if idx, bs := engine.aux_binding_hash_index(b, &h); bs == .Ok {
				query.hash_index_destroy(&idx)
			}
			if v, vs := engine.aux_binding_to_value(b, &h); vs == .Ok {
				query.release(&h, v)
			}
		}
		if b2, ok2 := engine.aux_binding_for(&set, "nd"); ok2 {
			if v2, vs2 := engine.aux_binding_to_value(b2, &h); vs2 == .Ok {
				query.release(&h, v2)
			}
		}
	}

	sweep := testkit.sweep_failures(run_aux_oom, &fix)
	testing.expect(t, sweep.runs > 10)
	testing.expect_value(t, sweep.bad, 0)
}

@(test)
prepare_single_aux_demand_non_zero_path_and_conditional_whole_workers :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Regression #1: `paths[0]` is a shallow field (`.m`) while `paths[1]` walks `.data.rows[]`.
	// `prepare_single_aux_demand` MUST slice from the matched path index, never `paths[0]`.
	{
		aux_json := transmute([]u8)string(`{"m":1,"drop":99,"data":{"rows":[{"id":1,"name":"ada","secret":"s"}]}}`)
		primary_json := transmute([]u8)string(`{"id":0}`)

		prog, errs := jq.compile(`{meta: $aux.m, item: $aux.data.rows[.id].name}`, {variables = {"aux"}})
		testing.expectf(t, len(errs) == 0, "compile errors: %v", errs)
		defer jq.destroy_program(prog)

		plan, ok := jq.analyze_with_vars(prog, {"aux"})
		testing.expect(t, ok)
		defer query.destroy_plan(&plan)

		aux := []engine.Aux_Source{
			{name = "aux", src = aux_json, spec = json.Spec.Json, framing = .Single, index_by_key = "id"},
		}
		set, lres := engine.load_aux_sources(&plan, aux, context.allocator)
		testing.expectf(t, lres.err == .None, "load_aux_sources failed: %v", lres)
		defer engine.destroy_aux_set(&set)

		b, bok := engine.aux_binding_for(&set, "aux")
		testing.expect(t, bok && b.partial)

		// Verify `.m`, `.data.rows[].name`, and augmented `.data.rows[].id` are kept while `.drop`/`.secret` taint.
		h: query.Heap
		query.heap_init(&h, context.allocator)
		defer query.heap_destroy(&h)
		v, vs := query.document_value(&h, b.doc, owned = false)
		testing.expect_value(t, vs, query.Status.Ok)
		defer query.release(&h, v)

		mv, ms := query.member(&h, v, "m")
		testing.expect(t, ms == .Ok && !h.tainted && mv.kind == .Node)
		query.release(&h, mv)

		data_v, _ := query.member(&h, v, "data")
		rows_v, _ := query.member(&h, data_v, "rows")
		r0, _ := query.element(&h, rows_v, 0)
		nm_v, _ := query.member(&h, r0, "name")
		id_v, _ := query.member(&h, r0, "id")
		testing.expect(t, !h.tainted && query.text_of(nm_v) == "ada")
		query.release(&h, id_v)
		query.release(&h, nm_v)
		sec_v, _ := query.member(&h, r0, "secret")
		testing.expect(t, h.tainted && sec_v.kind == .Absent)
		query.release(&h, r0)
		query.release(&h, rows_v)
		query.release(&h, data_v)

		// Full end-to-end execution of `{meta: $aux.m, item: $aux.data.rows[.id].name}` without index_by_key.
		sink := Lines_Buf{alloc = context.allocator}
		sink.lines.allocator = context.allocator
		defer destroy_lines(&sink)
		mctx := Multi_Jq_Ctx{prog = prog, alloc = context.allocator}
		aux_direct := []engine.Aux_Source{
			{name = "aux", src = aux_json, spec = json.Spec.Json, framing = .Single},
		}
		eres, elres := engine.execute_with_sources(
			&plan,
			primary_json,
			json.Spec.Json,
			.Single,
			aux_direct,
			{
				exec = {emit = {fn = lines_emit, data = &sink}, allocator = context.allocator},
				aux_eval = eval_multi_serial,
				aux_ctx  = &mctx,
			},
		)
		testing.expect_value(t, elres.err, engine.Exec_Error.None)
		testing.expect_value(t, eres.err, engine.Exec_Error.None)
		testing.expect_value(t, eres.emitted, u64(1))
		testing.expect_value(t, sink.lines[0], `{"meta":1,"item":"ada"}`)
	}

	// 2. Regression #3a: `.Conditional_Whole` (`aux_pred` + `aux_eval`) with `workers.init != nil`:
	//    tests BOTH shared worker-initialized `aux_pred` (`pred_ctx == nil`) AND explicit `exec.pred_ctx != nil`.
	{
		ndjson_src := transmute([]u8)string(
			"{\"keep\":true,\"uid\":1,\"tag\":\"a\"}\n" +
			"{\"keep\":false,\"uid\":2,\"tag\":\"b\"}\n" +
			"{\"keep\":true,\"uid\":2,\"tag\":\"c\"}\n",
		)
		users_src := transmute([]u8)string(`[{"uid":1,"name":"Ada"},{"uid":2,"name":"Bob"}]`)
		rules_src := transmute([]u8)string(`{"allow":true}`)

		// `select(P)` at top-level triggers `.Conditional_Whole` with `pred_demand = .Partial` and `cmp.op == .None`.
		plan_prog, perrs := jq.compile(`select(.keep and $rules.allow and ($users[.uid | tostring].name != null))`, {variables = {"users", "rules"}})
		testing.expect_value(t, len(perrs), 0)
		defer jq.destroy_program(plan_prog)

		plan, ok := jq.analyze_plan_with_vars(plan_prog, {"users", "rules"})
		testing.expect(t, ok)
		defer query.destroy_plan(&plan)

		prog, errs := jq.compile(`{tag, user: $users[.uid | tostring].name}`, {variables = {"users", "rules"}})
		testing.expect_value(t, len(errs), 0)
		defer jq.destroy_program(prog)

		pool: host.Pool
		testing.expect(t, host.pool_init(&pool, 2) == nil)
		defer host.pool_destroy(&pool)

		dec := engine.decide(&plan.contract, json.Spec.Json, .Lines, {runner = &pool.runner, input_bytes = len(ndjson_src)})
		testing.expect_value(t, dec.kind, engine.Route_Kind.Conditional_Whole)
		testing.expect_value(t, plan.contract.hints.conditional.cmp.op, query.Compare_Op.None)

		aux := []engine.Aux_Source{
			{name = "users", src = users_src, spec = json.Spec.Json, framing = .Single, index_by_key = "uid"},
			{name = "rules", src = rules_src, spec = json.Spec.Json, framing = .Single},
		}

		pred_worker :: proc(ctx: rawptr, aux_set: ^engine.Aux_Set, doc: ^tape.Document, meta: engine.Record_Meta) -> (bool, engine.Exec_Error) {
			_ = meta
			// Must receive `^Multi_Jq_Worker` from `multi_worker_init`, never `^Multi_Jq_Ctx` or `^Bridge_Slot`!
			w := (^Multi_Jq_Worker)(ctx)
			mctx := Multi_Jq_Ctx{prog = w.prog, alloc = w.alloc}
			if !ensure_worker_run(w, &mctx, aux_set) {
				return false, .No_Memory
			}
			h := &w.h
			rb, rok := engine.aux_binding_for(aux_set, "rules")
			if !rok {
				return false, .Failed
			}
			rval, rs := engine.aux_binding_to_value(rb, h)
			if rs != .Ok {
				return false, .Failed
			}
			defer query.release(h, rval)
			allow_v, as := query.member(h, rval, "allow")
			if as != .Ok {
				return false, .Failed
			}
			defer query.release(h, allow_v)
			if query.type_of(allow_v) != .True {
				return false, .None
			}

			val, st := query.document_value(h, doc^, owned = false)
			if st != .Ok {
				return false, .Failed
			}
			defer query.release(h, val)
			kv, ks := query.member(h, val, "keep")
			if ks != .Ok {
				return false, .Failed
			}
			defer query.release(h, kv)
			return query.type_of(kv) == .True, .None
		}

		// Case (i): shared `workers.init` (`exec.pred_ctx == nil`).
		sink1 := Lines_Buf{alloc = context.allocator}
		sink1.lines.allocator = context.allocator
		defer destroy_lines(&sink1)
		mctx1 := Multi_Jq_Ctx{prog = prog, alloc = context.allocator}

		r1, lr1 := engine.execute_with_sources(
			&plan.contract,
			ndjson_src,
			json.Spec.Json,
			.Lines,
			aux,
			{
				exec = {
					emit      = {fn = lines_emit, data = &sink1},
					runner    = &pool.runner,
					workers   = {init = multi_worker_init, fini = multi_worker_fini},
					allocator = context.allocator,
				},
				route    = {runner = &pool.runner},
				aux_eval = eval_multi_worker,
				aux_pred = pred_worker,
				aux_ctx  = &mctx1,
			},
		)
		testing.expect_value(t, lr1.err, engine.Exec_Error.None)
		testing.expect_value(t, r1.err, engine.Exec_Error.None)
		testing.expect_value(t, r1.emitted, u64(2))
		testing.expect_value(t, len(sink1.lines), 2)
		if len(sink1.lines) == 2 {
			testing.expect(t, strings.contains(sink1.lines[0], `"user":"Ada"`))
			testing.expect(t, strings.contains(sink1.lines[1], `"user":"Bob"`))
		}

		// Case (ii): explicit non-worker `exec.pred_ctx` passed alongside `workers.init != nil` for `aux_eval`.
		Pred_Counter :: struct {
			magic: u64,
			seen:  int,
		}
		pred_direct :: proc(ctx: rawptr, aux_set: ^engine.Aux_Set, doc: ^tape.Document, meta: engine.Record_Meta) -> (bool, engine.Exec_Error) {
			_ = aux_set
			_ = meta
			pc := (^Pred_Counter)(ctx)
			if pc == nil || pc.magic != 0xCAFE_1234 {
				return false, .Failed
			}
			pc.seen += 1
			h: query.Heap
			query.heap_init(&h, context.allocator)
			defer query.heap_destroy(&h)
			v, _ := query.document_value(&h, doc^, owned = false)
			defer query.release(&h, v)
			kv, _ := query.member(&h, v, "keep")
			defer query.release(&h, kv)
			return query.type_of(kv) == .True, .None
		}

		pc := Pred_Counter{magic = 0xCAFE_1234}
		sink2 := Lines_Buf{alloc = context.allocator}
		sink2.lines.allocator = context.allocator
		defer destroy_lines(&sink2)
		mctx2 := Multi_Jq_Ctx{prog = prog, alloc = context.allocator}

		r2, lr2 := engine.execute_with_sources(
			&plan.contract,
			ndjson_src,
			json.Spec.Json,
			.Lines,
			aux,
			{
				exec = {
					pred_ctx  = &pc,
					emit      = {fn = lines_emit, data = &sink2},
					runner    = &pool.runner,
					workers   = {init = multi_worker_init, fini = multi_worker_fini},
					allocator = context.allocator,
				},
				route    = {runner = &pool.runner},
				aux_eval = eval_multi_worker,
				aux_pred = pred_direct,
				aux_ctx  = &mctx2,
			},
		)
		testing.expect_value(t, lr2.err, engine.Exec_Error.None)
		testing.expect_value(t, r2.err, engine.Exec_Error.None)
		testing.expect_value(t, pc.seen, 3)
		testing.expect_value(t, r2.emitted, u64(2))
	}
}

@(test)
spine_parallel_collect_with_aux_and_workers :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Regression #3b: `.Spine_Parallel` `.Collect` with `workers.init != nil` and `spine_collect != nil`.
	// 65 elements exercises BOTH a 64-element parallel batch (`workers.init`) AND a 1-element trailing
	// serial batch (`eval_spine_batch_serial`), AND `spine_collect` receives user's `eval_ctx` (never raw adapter).
	pad_buf: [1024]u8
	for &ch in pad_buf {
		ch = 'x'
	}
	pad_str := string(pad_buf[:])

	sb := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, `{"items":[`)
	num_items :: 65
	for i in 0 ..< num_items {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		fmt.sbprintf(&sb, "{{\"uid\":%d,\"pad\":\"%s\"}}", i % 4, pad_str)
	}
	strings.write_string(&sb, `]}`)
	doc_bytes := transmute([]u8)strings.to_string(sb)
	users_src := transmute([]u8)string(`[{"uid":0,"w":1},{"uid":1,"w":2},{"uid":2,"w":3},{"uid":3,"w":4}]`)

	prog_full, e1 := jq.compile(`[.items[] | $users[.uid | tostring].w] | add`, {variables = {"users"}})
	testing.expect_value(t, len(e1), 0)
	defer jq.destroy_program(prog_full)
	plan_full, ok := jq.analyze_plan_with_vars(prog_full, {"users"})
	testing.expect(t, ok)
	defer jq.destroy_plan(&plan_full)
	testing.expect_value(t, plan_full.hints.split.kind, query.Split_Kind.Collect)

	prog_each, e2 := jq.compile(`$users[.uid | tostring].w`, {variables = {"users"}})
	testing.expect_value(t, len(e2), 0)
	defer jq.destroy_program(prog_each)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)

	dec := engine.decide(&plan_full.contract, json.Spec.Json, .Single, {runner = &pool.runner, input_bytes = len(doc_bytes)})
	testing.expect_value(t, dec.kind, engine.Route_Kind.Spine_Parallel)

	Collect_State :: struct {
		magic: u64,
		calls: int,
		count: int,
	}
	collect_sum :: proc(ctx: rawptr, doc: ^tape.Document, item_outputs: [][]u8, emit: engine.Emitter) -> engine.Exec_Error {
		_ = doc
		cs := (^Collect_State)(ctx)
		if cs == nil || cs.magic != 0x51C0_BEEF {
			return .Failed
		}
		cs.calls += 1
		cs.count = len(item_outputs)
		total := i64(0)
		for item in item_outputs {
			v := i64(0)
			for b in item {
				if b >= '0' && b <= '9' {
					v = v * 10 + i64(b - '0')
				}
			}
			total += v
		}
		out_buf: [32]u8
		txt := fmt.bprintf(out_buf[:], "%d", total)
		if !engine.emit_bytes(emit, transmute([]u8)txt) {
			return .Stopped
		}
		return .None
	}

	full_ctx := Multi_Jq_Ctx{prog = prog_full, alloc = context.allocator}
	each_ctx := Multi_Jq_Ctx{prog = prog_each, alloc = context.allocator}

	collect_with_full :: proc(ctx: rawptr, doc: ^tape.Document, item_outputs: [][]u8, emit: engine.Emitter) -> engine.Exec_Error {
		_ = doc
		// MUST receive `^Multi_Jq_Ctx` (`&full_ctx`), NEVER raw `^Join_Exec_Adapter` or `^Bridge_Slot`!
		mc := (^Multi_Jq_Ctx)(ctx)
		if mc == nil || mc.prog == nil {
			return .Failed
		}
		mc.eval_calls += 1
		total := i64(0)
		for item in item_outputs {
			v := i64(0)
			for b in item {
				if b >= '0' && b <= '9' {
					v = v * 10 + i64(b - '0')
				}
			}
			total += v
		}
		out_buf: [32]u8
		txt := fmt.bprintf(out_buf[:], "%d", total)
		if !engine.emit_bytes(emit, transmute([]u8)txt) {
			return .Stopped
		}
		return .None
	}

	sink := Lines_Buf{alloc = context.allocator}
	sink.lines.allocator = context.allocator
	defer destroy_lines(&sink)

	aux := []engine.Aux_Source{
		{name = "users", src = users_src, spec = json.Spec.Json, framing = .Single, index_by_key = "uid"},
	}

	// Case (A): `aux_eval != nil` + `aux_each != nil` + `workers.init != nil` + `spine_collect != nil`.
	// `join_spine_collect_bridge` must unwrap and pass `&full_ctx` (`eval_ctx`), never `&adapter`.
	res, lres := engine.execute_with_sources(
		&plan_full.contract,
		doc_bytes,
		json.Spec.Json,
		.Single,
		aux,
		{
			exec = {
				eval_ctx      = &full_ctx,
				eval_each_ctx = &each_ctx,
				spine_collect = collect_with_full,
				workers       = {init = multi_worker_init, fini = multi_worker_fini},
				runner        = &pool.runner,
				emit          = {fn = lines_emit, data = &sink},
				allocator     = context.allocator,
			},
			route    = {runner = &pool.runner},
			aux_eval = eval_multi_worker,
			aux_each = eval_multi_worker,
			aux_ctx  = &full_ctx,
		},
	)
	testing.expect_value(t, lres.err, engine.Exec_Error.None)
	testing.expect_value(t, res.err, engine.Exec_Error.None)
	testing.expect_value(t, full_ctx.eval_calls, 1)
	testing.expect_value(t, res.emitted, u64(1))
	// Sum for `i in 0..<65`: `16 * (1+2+3+4) + 1 = 161`.
	testing.expect_value(t, sink.lines[0], "161")

	// Case (B): `aux_eval == nil` (`eval_ctx == &cstate` passed directly to `collect_sum`) with
	// `aux_each != nil` + `workers.init != nil`.
	cstate := Collect_State{magic = 0x51C0_BEEF}
	sink_b := Lines_Buf{alloc = context.allocator}
	sink_b.lines.allocator = context.allocator
	defer destroy_lines(&sink_b)
	res_b, lres_b := engine.execute_with_sources(
		&plan_full.contract,
		doc_bytes,
		json.Spec.Json,
		.Single,
		aux,
		{
			exec = {
				eval_ctx      = &cstate,
				eval_each_ctx = &each_ctx,
				spine_collect = collect_sum,
				workers       = {init = multi_worker_init, fini = multi_worker_fini},
				runner        = &pool.runner,
				emit          = {fn = lines_emit, data = &sink_b},
				allocator     = context.allocator,
			},
			route    = {runner = &pool.runner},
			aux_each = eval_multi_worker,
			aux_ctx  = &each_ctx,
		},
	)
	testing.expect_value(t, lres_b.err, engine.Exec_Error.None)
	testing.expect_value(t, res_b.err, engine.Exec_Error.None)
	testing.expect_value(t, cstate.calls, 1)
	testing.expect_value(t, cstate.count, num_items)
	testing.expect_value(t, sink_b.lines[0], "161")
}
