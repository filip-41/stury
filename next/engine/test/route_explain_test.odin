package engine_tests

import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:engine"
import "stury:host"
import "stury:jq"
import "stury:json"
import "stury:lib/query"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

@(private = "file")
plan_for :: proc(t: ^testing.T, src: string, opts := jq.Analyze_Options{}) -> (^jq.Program, jq.Plan) {
	prog, errs := jq.compile(src)
	testing.expectf(t, len(errs) == 0, "compile %q failed: %v", src, errs)
	return prog, jq.analyze(prog, opts)
}

@(test)
route_decisions_all_kinds_and_whys :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	// 1. Edit / fmt / in_place always forces `.Whole` with `.Edit_Needs_Layout` and `keep_facts = true`.
	{
		prog, plan := plan_for(t, `.user.name`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		dec := engine.decide(&plan.contract, json.Spec.Json, .Single, {edit = true, runner = runner})
		testing.expect_value(t, dec.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, dec.primary_why, engine.Route_Why.Edit_Needs_Layout)
		testing.expect(t, dec.keep_facts)
		testing.expect(t, .Edit_Needs_Layout in dec.whys)
	}

	// 2. Explicit force_whole / slurp / raw / null overrides.
	{
		prog, plan := plan_for(t, `{a: .x}`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		df := engine.decide(&plan.contract, json.Spec.Json, .Single, {force_whole = true})
		testing.expect_value(t, df.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, df.primary_why, engine.Route_Why.Force_Whole)

		ds := engine.decide(&plan.contract, json.Spec.Json, .Lines, {slurp = true})
		testing.expect_value(t, ds.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, ds.primary_why, engine.Route_Why.Slurp_Whole)

		dr := engine.decide(&plan.contract, json.Spec.Json, .Lines, {raw_input = true})
		testing.expect_value(t, dr.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, dr.primary_why, engine.Route_Why.Raw_Lines)

		dn := engine.decide(&plan.contract, json.Spec.Json, .Single, {null_input = true})
		testing.expect_value(t, dn.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, dn.primary_why, engine.Route_Why.Demand_None)

		// `force_whole = true` on framed inputs keeps framed record iteration while forcing whole per-record build.
		df_lines := engine.decide(&plan.contract, json.Spec.Json, .Lines, {force_whole = true, runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, df_lines.kind, engine.Route_Kind.Records_Parallel)
		testing.expect_value(t, df_lines.demand_mode, query.Demand_Mode.Whole)
		testing.expect(t, .Force_Whole in df_lines.whys)
	}

	// 3. TOML forces `.Whole` with `.Format_No_Scan`.
	{
		prog, plan := plan_for(t, `.pkg.name`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		dec := engine.decide(&plan.contract, toml.Spec.Toml_1_0, .Single, {comments_out = true})
		testing.expect_value(t, dec.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, dec.primary_why, engine.Route_Why.Format_No_Scan)
		testing.expect(t, .Format_No_Scan in dec.whys)
		testing.expect(t, .Facts_Need_Whole in dec.whys)
	}

	// 4. All_Unbounded (`.[]`) forces `.Whole` with `.All_Unbounded`.
	{
		prog, plan := plan_for(t, `.[]`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		dec := engine.decide(&plan.contract, json.Spec.Json, .Single)
		testing.expect_value(t, dec.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, dec.primary_why, engine.Route_Why.All_Unbounded)
		testing.expect(t, .All_Unbounded in dec.whys)
	}

	// 5. Partial non-projection query (arithmetic) selects `.Scan`; `--where` and `comments_out` stay `.Scan`.
	{
		prog, plan := plan_for(t, `.a + .b`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		d1 := engine.decide(&plan.contract, json.Spec.Json, .Single)
		testing.expect_value(t, d1.kind, engine.Route_Kind.Scan)
		testing.expect_value(t, d1.primary_why, engine.Route_Why.Partial_Demand)
		testing.expect(t, !d1.keep_facts)

		d2 := engine.decide(&plan.contract, json.Spec.Jsonc, .Single, {comments_out = true})
		testing.expect_value(t, d2.kind, engine.Route_Kind.Scan)
		testing.expect_value(t, d2.primary_why, engine.Route_Why.Facts_Need_Scan)
		testing.expect(t, d2.keep_facts)

		d3 := engine.decide(&plan.contract, json.Spec.Json, .Single, {where_mode = true})
		testing.expect_value(t, d3.kind, engine.Route_Kind.Scan)
		testing.expect(t, d3.keep_origins)
		testing.expect(t, .Where_Needs_Evaluator in d3.whys)
	}

	// 6. Hint 2 (`Projection_Direct`): hits on JSON/DSV/CBOR, falls back when `where_mode`, `comments_out`, `xml` (`groups_dups`), or `serial != {}`.
	{
		prog, plan := plan_for(t, `{a: .x, b: .y}`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		d_json := engine.decide(&plan.contract, json.Spec.Json, .Single)
		testing.expect_value(t, d_json.kind, engine.Route_Kind.Projection_Direct)
		testing.expect_value(t, d_json.active_hint, engine.Active_Hint.Projection_Direct)
		testing.expect_value(t, d_json.primary_why, engine.Route_Why.Projection_Direct_Hit)

		d_csv := engine.decide(&plan.contract, dsv.Spec.Csv, .Lines, {runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_csv.kind, engine.Route_Kind.Projection_Direct)

		d_where := engine.decide(&plan.contract, json.Spec.Json, .Single, {where_mode = true})
		testing.expect_value(t, d_where.kind, engine.Route_Kind.Scan)
		testing.expect(t, .Where_Needs_Evaluator in d_where.whys)

		d_xml := engine.decide(&plan.contract, xml.Spec.Xml, .Single)
		testing.expect_value(t, d_xml.kind, engine.Route_Kind.Scan)

		d_facts := engine.decide(&plan.contract, json.Spec.Jsonc, .Single, {facts = true})
		testing.expect_value(t, d_facts.kind, engine.Route_Kind.Scan)
	}

	// 7. Hint 3 (`Conditional_Whole`): hits cleanly, blocked by `serial` and TOML.
	{
		prog, plan := plan_for(t, `select(.status == "ok")`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		d_hit := engine.decide(&plan.contract, json.Spec.Json, .Lines, {runner = runner})
		testing.expect_value(t, d_hit.kind, engine.Route_Kind.Conditional_Whole)
		testing.expect_value(t, d_hit.active_hint, engine.Active_Hint.Conditional_Whole)
		testing.expect_value(t, d_hit.primary_why, engine.Route_Why.Conditional_Whole_Hit)

		d_toml := engine.decide(&plan.contract, toml.Spec.Toml_1_0, .Single)
		testing.expect_value(t, d_toml.kind, engine.Route_Kind.Whole)
	}
	{
		prog, plan := plan_for(t, `def f: .; if (input_filename | length) > 0 then select(.a == 1) else select(.a == 1) end`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		// Any serial property forces serial execution even for framed inputs.
		prog_s, plan_s := plan_for(t, `debug | .a`)
		defer jq.destroy_program(prog_s)
		defer jq.destroy_plan(&plan_s)

		d_ser := engine.decide(&plan_s.contract, json.Spec.Json, .Lines, {runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_ser.kind, engine.Route_Kind.Records_Serial)
		testing.expect(t, !d_ser.parallel)
		testing.expect(t, .Serial_Program in d_ser.whys)
		testing.expect(t, .Records_Framing in d_ser.whys)
	}

	// 8. `Records_Serial` vs `Records_Parallel` (and `Input_Too_Small` when `RECORDS_PARALLEL_FROM > 0`).
	{
		prog, plan := plan_for(t, `.x + 1`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		d_par := engine.decide(&plan.contract, json.Spec.Json, .Lines, {runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_par.kind, engine.Route_Kind.Records_Parallel)
		testing.expect(t, d_par.parallel)
		testing.expect_value(t, d_par.primary_why, engine.Route_Why.Parallel_Worker_Pool)

		d_no_runner := engine.decide(&plan.contract, json.Spec.Json, .Lines, {input_bytes = 1 << 20})
		testing.expect_value(t, d_no_runner.kind, engine.Route_Kind.Records_Serial)
		testing.expect(t, .No_Runner in d_no_runner.whys)

		d_cbor := engine.decide(&plan.contract, cbor.Spec.Cbor, .Concatenated, {runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_cbor.kind, engine.Route_Kind.Records_Serial)

		when engine.RECORDS_PARALLEL_FROM > 0 {
			d_small := engine.decide(&plan.contract, json.Spec.Json, .Lines, {runner = runner, input_bytes = 16})
			testing.expect_value(t, d_small.kind, engine.Route_Kind.Records_Serial)
			testing.expect(t, .Input_Too_Small in d_small.whys)
		}
	}

	// 9. Hint 1 (`Spine_Parallel`) on JSON array elements with pool; falls back to `.Scan` without pool.
	{
		prog, plan := plan_for(t, `.items[] | .id`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		d_sp := engine.decide(&plan.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_sp.kind, engine.Route_Kind.Spine_Parallel)
		testing.expect_value(t, d_sp.active_hint, engine.Active_Hint.Spine_Split)
		testing.expect(t, d_sp.parallel)
		testing.expect_value(t, d_sp.primary_why, engine.Route_Why.Spine_Split_Hit)

		d_no_pool := engine.decide(&plan.contract, json.Spec.Json, .Single)
		testing.expect_value(t, d_no_pool.kind, engine.Route_Kind.Scan)
	}

	// 10. `Files_Parallel`: multi-file fan-out when `file_count > 1`, `runner != nil`, and `!serial`.
	{
		prog, plan := plan_for(t, `.id`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		d_mf := engine.decide(&plan.contract, json.Spec.Json, .Single, {runner = runner, file_count = 4})
		testing.expect_value(t, d_mf.kind, engine.Route_Kind.Files_Parallel)
		testing.expect(t, d_mf.file_parallel)
		testing.expect_value(t, d_mf.primary_why, engine.Route_Why.Many_Files)

		prog_ser, plan_ser := plan_for(t, `halt`)
		defer jq.destroy_program(prog_ser)
		defer jq.destroy_plan(&plan_ser)
		d_mf_ser := engine.decide(&plan_ser.contract, json.Spec.Json, .Single, {runner = runner, file_count = 4})
		testing.expect(t, !d_mf_ser.file_parallel)
		testing.expect(t, .Serial_Program in d_mf_ser.whys)
	}
}

@(test)
explain_output_determinism_and_contents :: proc(t: ^testing.T) {
	testkit.deadline(t)

	prog, plan := plan_for(t, `{a: .x, b: .y}`)
	defer jq.destroy_program(prog)
	defer jq.destroy_plan(&plan)

	dec := engine.decide(&plan.contract, json.Spec.Jsonc, .Lines, {comments_out = true})
	txt1 := engine.explain(&plan.contract, &dec)
	defer delete(txt1)
	txt2 := engine.explain(&plan.contract, &dec)
	defer delete(txt2)

	testing.expect_value(t, txt1, txt2)
	testing.expect(t, strings.contains(txt1, "format: JSON with comments (jsonc), framing: lines"))
	testing.expect(t, strings.contains(txt1, "route: records_serial"))
	testing.expect(t, strings.contains(txt1, "why: "))
	testing.expect(t, strings.contains(txt1, "facts=yes"))
	testing.expect(t, strings.contains(txt1, engine.route_why_text(.Facts_Need_Scan)))
	testing.expect_value(t, engine.route_kind_name(.Projection_Direct), "projection_direct")
}

@(test)
route_dups_where_facts_and_serial_eval_ctx :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	// 1. `dups == .All` forces `.Whole` on JSON single & `.Whole` demand on NDJSON (no Scan / Hint 1/2/3).
	{
		prog, plan := plan_for(t, `{a: .x}`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		d_all := engine.decide(&plan.contract, json.Spec.Json, .Single, {dups = .All})
		testing.expect_value(t, d_all.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, d_all.primary_why, engine.Route_Why.Dups_Need_Build)
		testing.expect(t, .Dups_Need_Build in d_all.whys)

		d_ref := engine.decide(&plan.contract, json.Spec.Json, .Single, {dups = .Refuse})
		testing.expect_value(t, d_ref.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, d_ref.primary_why, engine.Route_Why.Dups_Need_Build)

		d_lines_ref := engine.decide(&plan.contract, json.Spec.Json, .Lines, {dups = .Refuse, runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_lines_ref.kind, engine.Route_Kind.Records_Parallel)
		testing.expect_value(t, d_lines_ref.demand_mode, query.Demand_Mode.Whole)
		testing.expect(t, .Dups_Need_Build in d_lines_ref.whys)

		// CSV has `.Names_Ahead` so `dups == .Refuse` stays `.Projection_Direct`,
		// whereas `dups == .All` forces `.Whole` (since DSV `records_scan` refuses `.All`).
		d_csv_ref := engine.decide(&plan.contract, dsv.Spec.Csv, .Lines, {dups = .Refuse})
		testing.expect_value(t, d_csv_ref.kind, engine.Route_Kind.Projection_Direct)
		testing.expect(t, .Dups_Need_Build not_in d_csv_ref.whys)

		d_csv_all := engine.decide(&plan.contract, dsv.Spec.Csv, .Lines, {dups = .All})
		testing.expect_value(t, d_csv_all.kind, engine.Route_Kind.Whole)
		testing.expect_value(t, d_csv_all.demand_mode, query.Demand_Mode.Whole)
		testing.expect_value(t, d_csv_all.primary_why, engine.Route_Why.Dups_Need_Build)
	}

	// 2. Hint 3 (`Conditional_Whole`) is blocked by `where_mode`, `comments_out`, `facts`, and `dups == .All`.
	{
		prog, plan := plan_for(t, `select(.status == "ok")`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		for ro in ([?]engine.Route_Options{{where_mode = true}, {comments_out = true}, {facts = true}, {dups = .All}}) {
			d := engine.decide(&plan.contract, json.Spec.Json, .Single, ro)
			testing.expect_value(t, d.kind, engine.Route_Kind.Whole)
			testing.expect_value(t, d.active_hint, engine.Active_Hint.None)
		}
	}

	// 3. `serial_eval_ctx = true` disables parallel routes cleanly and records `.Eval_Ctx_Serial` in `--explain`.
	{
		prog, plan := plan_for(t, `.x + 1`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		d_recs := engine.decide(&plan.contract, json.Spec.Json, .Lines, {runner = runner, input_bytes = 1 << 20, serial_eval_ctx = true})
		testing.expect_value(t, d_recs.kind, engine.Route_Kind.Records_Serial)
		testing.expect(t, !d_recs.parallel)
		testing.expect_value(t, d_recs.primary_why, engine.Route_Why.Eval_Ctx_Serial)

		exp := engine.explain(&plan.contract, &d_recs)
		defer delete(exp)
		testing.expect(t, strings.contains(exp, engine.route_why_text(.Eval_Ctx_Serial)))

		d_files := engine.decide(&plan.contract, json.Spec.Json, .Single, {runner = runner, file_count = 4, serial_eval_ctx = true})
		testing.expect(t, !d_files.file_parallel)
		testing.expect(t, .Eval_Ctx_Serial in d_files.whys)
	}
}

@(test)
plan_pin_json_roundtrip_and_comparison :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	// 1. Canonical JSON determinism & roundtrip across routes.
	{
		prog, plan := plan_for(t, `{a: .x, b: .y}`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		dec := engine.decide(&plan.contract, json.Spec.Json, .Single)
		j1 := engine.explain_pin_json(&dec)
		defer delete(j1)
		j2 := engine.explain_pin_json(&dec)
		defer delete(j2)
		testing.expect_value(t, j1, j2)
		testing.expect_value(
			t,
			j1,
			"{\"route\":\"projection_direct\",\"framing\":\"single\",\"parallel\":false,\"hint\":\"projection_direct\",\"demand_kind\":\"partial\",\"format\":\"json\"}\n",
		)

		parsed, ok := engine.parse_plan_pin_json(j1)
		testing.expect(t, ok, j1)
		defer engine.destroy_plan_pin(&parsed)
		testing.expect(t, engine.compare_plan_pin(parsed, engine.plan_pin_of(&dec)))
	}

	// 2. Parallel spine split pin & diff detection when downgraded to serial scan or whole.
	{
		prog, plan := plan_for(t, `.items[] | .id`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		dec_par := engine.decide(&plan.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = 1 << 20})
		pin_json := engine.explain_pin_json(&dec_par)
		defer delete(pin_json)
		testing.expect(t, strings.contains(pin_json, `"route":"spine_parallel"`), pin_json)
		testing.expect(t, strings.contains(pin_json, `"parallel":true`), pin_json)
		testing.expect(t, strings.contains(pin_json, `"hint":"spine_split"`), pin_json)

		expected, pok := engine.parse_plan_pin_json(pin_json)
		testing.expect(t, pok)
		defer engine.destroy_plan_pin(&expected)

		dec_ser := engine.decide(&plan.contract, json.Spec.Json, .Single)
		diff_sb := strings.builder_make()
		defer strings.builder_destroy(&diff_sb)
		matched := engine.compare_plan_pin(expected, engine.plan_pin_of(&dec_ser), &diff_sb)
		testing.expect(t, !matched)
		diff_txt := strings.to_string(diff_sb)
		testing.expect(t, strings.contains(diff_txt, "expected route spine_parallel, got scan"), diff_txt)
		testing.expect(t, strings.contains(diff_txt, "expected parallel true, got false"), diff_txt)
		testing.expect(t, strings.contains(diff_txt, "expected hint spine_split, got none"), diff_txt)
	}

	// 3. Reordered keys and whitespace parse cleanly; missing fields / bad JSON are rejected.
	{
		reordered := "{\n  \"format\": \"toml\",\n  \"demand_kind\": \"whole\",\n  \"hint\": \"none\",\n  \"parallel\": false,\n  \"framing\": \"single\",\n  \"route\": \"whole\"\n}\n"
		pin, ok := engine.parse_plan_pin_json(reordered)
		testing.expect(t, ok)
		defer engine.destroy_plan_pin(&pin)
		testing.expect_value(t, pin.route, "whole")
		testing.expect_value(t, pin.format, "toml")
		testing.expect_value(t, pin.demand_kind, "whole")

		for bad in ([]string{
			"",
			"{}",
			`{"route":"whole"}`,
			`{"route":"whole","framing":"single","parallel":"false","hint":"none","demand_kind":"whole","format":"json"}`,
			`{"route":"whole","framing":"single","parallel":false,"hint":"none","demand_kind":"whole","format":"json","extra":"x"}`,
			`{"route":"whole","framing":"single","parallel":false,"hint":"none","demand_kind":"whole","format":"json"} trailing`,
			`{"route":"whole","framing":"single","parallel":false,"hint":"none","demand_kind":"whole","format":"\u00ZZ"}`,
			`{"route":"whole","framing":"single","parallel":false,"hint":"none","demand_kind":"whole","format":"\uD800"}`,
			`{"route":"whole","framing":"single","parallel":false,"hint":"none","demand_kind":"whole","format":"\uDC00"}`,
		}) {
			bp, bok := engine.parse_plan_pin_json(bad)
			engine.destroy_plan_pin(&bp)
			testing.expect(t, !bok, bad)
		}
	}

	// 4. `\uXXXX` escapes (including control byte `\u001f` emitted by `explain_pin_json` and UTF-16 surrogate pairs) round-trip cleanly.
	{
		dec := engine.Decision{
			kind        = .Whole,
			framing     = .Single,
			active_hint = .None,
			demand_mode = .Whole,
			entry       = {name = "f\x1fx"},
		}
		j := engine.explain_pin_json(&dec)
		defer delete(j)
		testing.expect(t, strings.contains(j, `"format":"f\u001fx"`), j)

		parsed, ok := engine.parse_plan_pin_json(j)
		testing.expect(t, ok, j)
		defer engine.destroy_plan_pin(&parsed)
		testing.expect(t, engine.compare_plan_pin(parsed, engine.plan_pin_of(&dec)))
		testing.expect_value(t, parsed.format, "f\x1fx")

		sur := `{"route":"whole","framing":"single","parallel":false,"hint":"none","demand_kind":"whole","format":"\u00e9\uD83D\uDE00"}`
		sp, sok := engine.parse_plan_pin_json(sur)
		testing.expect(t, sok)
		defer engine.destroy_plan_pin(&sp)
		testing.expect_value(t, sp.format, "é😀")
	}
}

@(test)
route_projection_direct_parallel_and_length_each :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	testing.expect(t, host.pool_init(&pool, 4) == nil)
	defer host.pool_destroy(&pool)
	runner := &pool.runner

	{
		prog, plan := plan_for(t, `.id`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		d_par := engine.decide(&plan.contract, json.Spec.Json, .Lines, {runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_par.kind, engine.Route_Kind.Projection_Direct)
		testing.expect(t, d_par.parallel)
		testing.expect(t, .Parallel_Worker_Pool in d_par.whys)

		d_seq := engine.decide(&plan.contract, json.Spec.Json, .Seq, {runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_seq.kind, engine.Route_Kind.Projection_Direct)
		testing.expect(t, d_seq.parallel)

		d_single := engine.decide(&plan.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_single.kind, engine.Route_Kind.Projection_Direct)
		testing.expect(t, !d_single.parallel)

		d_serial_ctx := engine.decide(&plan.contract, json.Spec.Json, .Lines, {runner = runner, input_bytes = 1 << 20, serial_eval_ctx = true})
		testing.expect_value(t, d_serial_ctx.kind, engine.Route_Kind.Projection_Direct)
		testing.expect(t, !d_serial_ctx.parallel)

		d_csv := engine.decide(&plan.contract, dsv.Spec.Csv, .Lines, {runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_csv.kind, engine.Route_Kind.Projection_Direct)
		testing.expect(t, !d_csv.parallel)
	}

	{
		prog, plan := plan_for(t, `[.items[].msg | splits(" +")] | length`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		d_len := engine.decide(&plan.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_len.kind, engine.Route_Kind.Spine_Parallel)
		testing.expect(t, d_len.parallel)
	}

	{
		prog, plan := plan_for(t, `reduce .items[] as $x (0; . + $x.id)`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)

		testing.expect_value(t, plan.hints.split.kind, query.Split_Kind.Reduce)
		d_red := engine.decide(&plan.contract, json.Spec.Json, .Single, {runner = runner, input_bytes = 1 << 20})
		testing.expect_value(t, d_red.kind, engine.Route_Kind.Spine_Parallel)
		testing.expect_value(t, d_red.active_hint, engine.Active_Hint.Spine_Split)
		testing.expect_value(t, d_red.primary_why, engine.Route_Why.Spine_Split_Hit)
		testing.expect(t, d_red.parallel)

		d_no_pool := engine.decide(&plan.contract, json.Spec.Json, .Single)
		testing.expect_value(t, d_no_pool.kind, engine.Route_Kind.Scan)
	}
}
