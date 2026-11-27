package cli_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "stury:engine"
import "stury:testkit"

@(test)
cli_perf_lazy_pool_and_env_pruning :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Null-input (`-n`) and small single-doc queries skip worker pool init cleanly when threads are auto.
	{
		rn := invoke({"-nc", `[range(5)] | add`})
		defer run_out_destroy(&rn)
		testing.expect_value(t, rn.code, 0)
		testing.expect_value(t, rn.stdout, "10\n")
	}

	// 2. Unused `$ENV`/`ARGS` pruning leaves output identical while referenced `$ENV.HOME != null` still reads env.
	{
		r_no_env := invoke_str({"-c", `{a: .x, b: .y}`}, `{"x":1,"y":2,"z":3}`)
		defer run_out_destroy(&r_no_env)
		testing.expect_value(t, r_no_env.code, 0)
		testing.expect_value(t, r_no_env.stdout, "{\"a\":1,\"b\":2}\n")

		r_env := invoke({"-nc", `($ENV | type)`})
		defer run_out_destroy(&r_env)
		testing.expect_value(t, r_env.code, 0)
		testing.expect_value(t, r_env.stdout, "\"object\"\n")

		r_arg := invoke_str({"--arg", "x", "hi", "--arg", "unused", "skip", "-c", `$x`}, `{}`)
		defer run_out_destroy(&r_arg)
		testing.expect_value(t, r_arg.code, 0)
		testing.expect_value(t, r_arg.stdout, "\"hi\"\n")
	}
}

@(test)
cli_perf_fast_json_and_coarse_parallel_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)

	min_bytes := max(int(engine.RECORDS_PARALLEL_FROM), int(engine.SPINE_PARALLEL_FROM), 48 * 1024)

	// 1. Canonical + non-canonical (`\/`, `\u0041`, DEL) `fast_json` `.Compact` & `.Pretty2` parity against `-S` non-fast fallback.
	{
		inputs := [?]string{
			`{"b":[1,true,null],"a":{"k":"plain","n":42}}`,
			`{"a":"a\/b\u0041"}`,
			"{\"a\":\"ctrl\x7fend\"}",
		}
		for raw in inputs {
			r_fast_c := invoke_str({"-c", `.`}, raw)
			defer run_out_destroy(&r_fast_c)
			testing.expect_value(t, r_fast_c.code, 0)

			// Force general serializer via `if true then . else . end` (`!is_identity`).
			r_gen_c := invoke_str({"-c", `if true then . else . end`}, raw)
			defer run_out_destroy(&r_gen_c)
			testing.expect_value(t, r_gen_c.code, 0)
			testing.expect_value(t, r_fast_c.stdout, r_gen_c.stdout)

			r_fast_p := invoke_str({`.`}, raw)
			defer run_out_destroy(&r_fast_p)
			testing.expect_value(t, r_fast_p.code, 0)

			r_gen_p := invoke_str({`if true then . else . end`}, raw)
			defer run_out_destroy(&r_gen_p)
			testing.expect_value(t, r_gen_p.code, 0)
			testing.expect_value(t, r_fast_p.stdout, r_gen_p.stdout)
		}
	}

	// 2. Coarse parallel NDJSON (`.`, `.id` Projection_Direct) `--threads 4` == `--threads 1`.
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		svcs := [?]string{"auth", "api", "db", "edge"}
		for i := 0; strings.builder_len(sb) < min_bytes || i < 400; i += 1 {
			if i == 111 {
				strings.write_string(&sb, "{\"id\":111,\"service\":\"auth\",\"msg\":\"esc \\/ \\u0041\"}\n")
			} else {
				fmt.sbprintf(&sb, "{{\"id\":%d,\"service\":\"%s\",\"msg\":\"ok worker started port %d\"}}\n", i, svcs[i % len(svcs)], 8000 + (i % 100))
			}
		}
		nd := strings.to_string(sb)

		for args in ([?][]string{
			{"--from", "ndjson", "-c", `.`},
			{"--from", "ndjson", "-c", `.id`},
		}) {
			a1 := make([dynamic]string, 0, len(args) + 2)
			defer delete(a1)
			append(&a1, "--threads", "1")
			append(&a1, ..args)
			r1 := invoke_str(a1[:], nd)
			defer run_out_destroy(&r1)
			testing.expect_value(t, r1.code, 0)

			a4 := make([dynamic]string, 0, len(args) + 2)
			defer delete(a4)
			append(&a4, "--threads", "4")
			append(&a4, ..args)
			r4 := invoke_str(a4[:], nd)
			defer run_out_destroy(&r4)
			testing.expect_value(t, r4.code, 0)
			testing.expect_value(t, r4.stdout, r1.stdout)
		}
	}

	// 3. Large single JSON document: `--threads 4` vs `--threads 1` exact stdout parity across Hint 1, `group_by`, `gsub`, `splits`, `tally`.
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		strings.write_string(&sb, `{"logs":[`)
		svcs := [?]string{"auth", "api", "db", "cache", "edge"}
		for i := 0; strings.builder_len(sb) < min_bytes || i < 400; i += 1 {
			if i > 0 {
				strings.write_byte(&sb, ',')
			}
			fmt.sbprintf(
				&sb,
				"{{\"id\":%d,\"service\":\"%s\",\"duration_ms\":%d,\"msg\":\"worker %d timeout retry ok\",\"arr\":[1,2,%d]}}",
				i,
				svcs[i % len(svcs)],
				(i * 7) % 100,
				i,
				i,
			)
		}
		// Ensure the last element contains a long string boundary right before `]}` (`entry_quoted` split case).
		strings.write_string(&sb, `,{"id":999999,"service":"edge","duration_ms":1,"msg":"`)
		for _ in 0 ..< 4096 {
			strings.write_byte(&sb, 'a')
		}
		strings.write_string(&sb, `","arr":[9,8,7]}]}`)
		doc := strings.to_string(sb)

		for pair in ([?][2]string{
			{"", `.logs[]`},
			{"-c", `.logs | map({id, ms: .duration_ms})`},
			{"-c", `.logs | group_by(.service) | map([.[0].service, length])`},
			{"-r", `.logs[].msg | gsub("\\b(?<w>[a-z])"; "\(.w | ascii_upcase)")`},
			{"-c", `[.logs[].msg | splits(" +")] | length`},
			{"-c", `[.logs[].arr[]] | length`},
			{"-c", `.logs[].arr | arrays | .[-1]`},
		}) {
			a1: [dynamic]string
			defer delete(a1)
			append(&a1, "--threads", "1")
			if pair[0] != "" {
				append(&a1, pair[0])
			}
			append(&a1, pair[1])

			a4: [dynamic]string
			defer delete(a4)
			append(&a4, "--threads", "4")
			if pair[0] != "" {
				append(&a4, pair[0])
			}
			append(&a4, pair[1])

			r1 := invoke_str(a1[:], doc)
			defer run_out_destroy(&r1)
			testing.expectf(t, r1.code == 0, "t=1 %s failed: %s", pair[1], r1.stderr)

			r4 := invoke_str(a4[:], doc)
			defer run_out_destroy(&r4)
			testing.expectf(t, r4.code == 0, "t=4 %s failed: %s", pair[1], r4.stderr)
			testing.expectf(t, r4.stdout == r1.stdout, "parity mismatch on %s", pair[1])
		}
	}
}

@(test)
cli_review_regressions_b1_b3_b4_b6_b7 :: proc(t: ^testing.T) {
	testkit.deadline(t)

	min_bytes := max(int(engine.RECORDS_PARALLEL_FROM), int(engine.SPINE_PARALLEL_FROM), 140 * 1024)
	dir := make_tmp_dir(t)
	defer drop_tmp_dir(dir)

	// 1. B1: concurrent `strflocaltime` across parallel workers (TSan) and pre-1970 `-1 | strflocaltime("%Y")`.
	{
		r_pre := invoke_str({"-c", `strflocaltime("%Y")`}, "-1\n")
		defer run_out_destroy(&r_pre)
		testing.expect_value(t, r_pre.code, 0)
		testing.expect(t, r_pre.stdout == `"1969"`+"\n" || r_pre.stdout == `"1970"`+"\n", r_pre.stdout)

		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		for i := 0; strings.builder_len(sb) < min_bytes || i < 400; i += 1 {
			if i % 3 == 0 {
				strings.write_string(&sb, "-1\n")
			} else if i % 2 == 0 {
				strings.write_string(&sb, "1700000000\n")
			} else {
				strings.write_string(&sb, "1690000000\n")
			}
		}
		ts_nd := strings.to_string(sb)
		r1 := invoke_str({"--threads", "1", "--from", "ndjson", "-c", `strflocaltime("%Y-%m-%d %Z %z")`}, ts_nd)
		defer run_out_destroy(&r1)
		testing.expect_value(t, r1.code, 0)

		r4 := invoke_str({"--threads", "4", "--from", "ndjson", "-c", `strflocaltime("%Y-%m-%d %Z %z")`}, ts_nd)
		defer run_out_destroy(&r4)
		testing.expect_value(t, r4.code, 0)
		testing.expect_value(t, r4.stdout, r1.stdout)
	}

	// 2. B3: `--where '.logs[] | .a'` real source offsets, `input_line_number` sequential ordering, and `--max-depth 4` on deep spine element.
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		strings.write_string(&sb, "{\n  \"logs\": [\n")
		i := 0
		for strings.builder_len(sb) < min_bytes || i < 300 {
			if i > 0 {
				strings.write_string(&sb, ",\n")
			}
			fmt.sbprintf(&sb, `    {{"a":%d,"pad":"spine_guard_pad_%d_0123456789"}}`, i, i)
			i += 1
		}
		strings.write_string(&sb, "\n  ]\n}\n")
		p_where := write_tmp_file(t, dir, "where_spine.json", transmute([]u8)strings.to_string(sb))
		defer delete(p_where)

		rw1 := invoke({"--threads", "1", "--where", "-c", `.logs[] | .a`, p_where})
		defer run_out_destroy(&rw1)
		testing.expect_value(t, rw1.code, 0)

		rw4 := invoke({"--threads", "4", "--where", "-c", `.logs[] | .a`, p_where})
		defer run_out_destroy(&rw4)
		testing.expect_value(t, rw4.code, 0)
		testing.expect_value(t, rw4.stdout, rw1.stdout)
		testing.expect(t, strings.contains(rw4.stdout, ":3:10: "), rw4.stdout)

		// Sequential `input_line_number` across coarse parallel NDJSON and single-doc spine.
		nd_sb := strings.builder_make()
		defer strings.builder_destroy(&nd_sb)
		n_lines := 0
		for strings.builder_len(nd_sb) < min_bytes || n_lines < 300 {
			fmt.sbprintf(&nd_sb, "{{\"k\":%d,\"msg\":\"nd_line_num_pad_%d_0123456789\"}}\n", n_lines, n_lines)
			n_lines += 1
		}
		r_ln1 := invoke_str({"--threads", "1", "--from", "ndjson", "-c", `input_line_number`}, strings.to_string(nd_sb))
		defer run_out_destroy(&r_ln1)
		r_ln4 := invoke_str({"--threads", "4", "--from", "ndjson", "-c", `input_line_number`}, strings.to_string(nd_sb))
		defer run_out_destroy(&r_ln4)
		testing.expect_value(t, r_ln1.code, 0)
		testing.expect_value(t, r_ln4.stdout, r_ln1.stdout)

		r_spln := invoke({"--threads", "4", "-c", `.logs[] | input_line_number`, p_where})
		defer run_out_destroy(&r_spln)
		testing.expect_value(t, r_spln.code, 0)

		// Deep spine element (> depth 4) rejected cleanly by `--max-depth 4`.
		deep_sb := strings.builder_make()
		defer strings.builder_destroy(&deep_sb)
		strings.write_string(&deep_sb, `{"logs":[{"a":{"b":{"c":{"d":1}}}}`)
		for j := 0; strings.builder_len(deep_sb) < min_bytes || j < 300; j += 1 {
			fmt.sbprintf(&deep_sb, `,{"id":%d,"pad":"depth_check_%d_0123456789"}`, j, j)
		}
		strings.write_string(&deep_sb, `]}`)
		deep_doc := strings.to_string(deep_sb)

		rd1 := invoke_str({"--threads", "1", "--max-depth", "4", "-c", `.logs[].id`}, deep_doc)
		defer run_out_destroy(&rd1)
		rd4 := invoke_str({"--threads", "4", "--max-depth", "4", "-c", `.logs[].id`}, deep_doc)
		defer run_out_destroy(&rd4)
		testing.expect_value(t, rd1.code, 5)
		testing.expect_value(t, rd4.code, 5)
	}

	// 3. B4: `--dups all -c '.'` deduplicates keys identically to `--dups all -c '. | .'`.
	{
		r_dot := invoke_str({"--dups", "all", "-c", `.`}, `{"a":1,"a":2}`)
		defer run_out_destroy(&r_dot)
		r_pipe := invoke_str({"--dups", "all", "-c", `. | .`}, `{"a":1,"a":2}`)
		defer run_out_destroy(&r_pipe)
		testing.expect_value(t, r_dot.code, 0)
		testing.expect_value(t, r_pipe.code, 0)
		testing.expect_value(t, r_dot.stdout, "{\"a\":2}\n")
		testing.expect_value(t, r_dot.stdout, r_pipe.stdout)
	}

	// 4. B6: 20,000-level deep `.a.a...` filter succeeds cleanly in CLI without stack overflow.
	{
		fb := strings.builder_make()
		defer strings.builder_destroy(&fb)
		for _ in 0 ..< 20_000 {
			strings.write_string(&fb, ".a")
		}
		r_deep := invoke_str({"-c", strings.to_string(fb)}, `{"a":null}`)
		defer run_out_destroy(&r_deep)
		testing.expect_value(t, r_deep.code, 0)
		testing.expect_value(t, r_deep.stdout, "null\n")
	}

	// 5. B7: `--explain`, `--plan-out`, and `--plan-file` match actual route on large single JSON file.
	{
		wb := strings.builder_make()
		defer strings.builder_destroy(&wb)
		strings.write_string(&wb, `{"vals":[`)
		for i := 0; strings.builder_len(wb) < min_bytes || i < 4000; i += 1 {
			if i > 0 {
				strings.write_byte(&wb, ',')
			}
			fmt.sbprintf(&wb, `%d`, i)
		}
		strings.write_string(&wb, `]}`)
		big_p := write_tmp_file(t, dir, "big_whole.json", transmute([]u8)strings.to_string(wb))
		defer delete(big_p)
		pin_p := join_path(t, dir, "big_whole.pin.json")
		defer delete(pin_p)

		// Identity filter `.` selects the `.Whole` route on a single large JSON file.
		r_norm := invoke({"--threads", "4", "-c", `.`, big_p})
		defer run_out_destroy(&r_norm)
		testing.expect_value(t, r_norm.code, 0)

		r_exp := invoke({"--threads", "4", "--explain", "-c", `.`, big_p})
		defer run_out_destroy(&r_exp)
		testing.expect_value(t, r_exp.code, 0)
		testing.expect_value(t, r_exp.stdout, r_norm.stdout)
		testing.expect(t, strings.contains(r_exp.stderr, "framing: single"), r_exp.stderr)
		testing.expect(t, strings.contains(r_exp.stderr, "route: whole"), r_exp.stderr)

		r_pout := invoke({"--threads", "4", "--plan-out", pin_p, "-c", `.`, big_p})
		defer run_out_destroy(&r_pout)
		testing.expect_value(t, r_pout.code, 0)
		testing.expect_value(t, r_pout.stdout, r_norm.stdout)

		pin_bytes, perr := os.read_entire_file_from_path(pin_p, context.allocator)
		testing.expect(t, perr == nil)
		defer delete(pin_bytes)
		testing.expect(t, strings.contains(string(pin_bytes), `"framing":"single"`), string(pin_bytes))
		testing.expect(t, strings.contains(string(pin_bytes), `"route":"whole"`), string(pin_bytes))

		r_pin := invoke({"--threads", "4", "--plan-file", pin_p, "-c", `.`, big_p})
		defer run_out_destroy(&r_pin)
		testing.expect_value(t, r_pin.code, 0)
		testing.expect_value(t, r_pin.stdout, r_norm.stdout)
	}
}
