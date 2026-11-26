package cli_tests

import "core:fmt"
import "core:io"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "stury:cli"
import "stury:engine"
import "stury:lib/core/tape"
import "stury:testkit"

Run_Out :: struct {
	code:   int,
	stdout: string,
	stderr: string,
}

run_out_destroy :: proc(r: ^Run_Out, alloc := context.allocator) {
	delete(r.stdout, alloc)
	delete(r.stderr, alloc)
	r^ = {}
}

invoke :: proc(args: []string, stdin_bytes: Maybe([]u8) = nil, stdout_tty := false, stdin_tty := false, alloc := context.allocator) -> Run_Out {
	ob := strings.builder_make(alloc)
	eb := strings.builder_make(alloc)
	code := cli.run_cli(args, stdin_bytes, strings.to_writer(&ob), strings.to_writer(&eb), stdout_tty, stdin_tty, alloc)
	return {code = code, stdout = strings.to_string(ob), stderr = strings.to_string(eb)}
}

invoke_str :: proc(args: []string, stdin_text: string, alloc := context.allocator) -> Run_Out {
	return invoke(args, transmute([]u8)stdin_text, false, false, alloc)
}

make_tmp_dir :: proc(t: ^testing.T, alloc := context.allocator) -> string {
	base, ok := os.lookup_env("TMPDIR", alloc)
	if !ok { base, ok = os.lookup_env("TEMP", alloc) }
	if !ok { base, ok = os.lookup_env("TMP", alloc) }
	if !ok || base == "" {
		if ok { delete(base, alloc) }
		base = strings.clone("/tmp", alloc)
	}
	digits: [24]u8
	found: string
	for _ in 0 ..< 32 {
		num := strconv.write_uint(digits[:], rand.uint64(), 10)
		name := strings.concatenate({"stury-cli-test-", num}, alloc)
		cand, jerr := filepath.join({base, name}, alloc)
		delete(name, alloc)
		if jerr != nil { continue }
		if err := os.make_directory(cand); err == nil { found = cand; break }
		delete(cand, alloc)
	}
	delete(base, alloc)
	testing.expect(t, found != "", "could not create temporary directory")
	return found
}

drop_tmp_dir :: proc(dir: string, alloc := context.allocator) {
	_ = os.remove_all(dir)
	delete(dir, alloc)
}

join_path :: proc(t: ^testing.T, dir, name: string, alloc := context.allocator) -> string {
	p, err := filepath.join({dir, name}, alloc)
	testing.expect(t, err == nil, "filepath.join failed")
	return p
}

write_tmp_file :: proc(t: ^testing.T, dir, name: string, data: []u8, alloc := context.allocator) -> string {
	p := join_path(t, dir, name, alloc)
	err := os.write_entire_file(p, data)
	testing.expectf(t, err == nil, "write %s failed: %v", p, err)
	return p
}

@(test)
parses_args_help_version_and_errors :: proc(t: ^testing.T) {
	testkit.deadline(t)
	{
		r := invoke({"--help"}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "--jsonpath"), r.stdout)
	}
	for sub in ([]string{"check", "fmt", "edit", "diff", "schema"}) {
		r := invoke({sub, "--help"}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, sub), r.stdout)
	}
	{
		r := invoke({"--version"}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.has_prefix(r.stdout, "stury-"), r.stdout)
	}
	{
		r := invoke({"--build-configuration"}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "odin "), r.stdout)
	}
	{
		r := invoke(nil, nil, true, true); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 2)
		testing.expect(t, strings.contains(r.stderr, "Usage:"), r.stderr)
	}
	bad_cases := [][]string {
		{"--unknown-flag", "."},
		{"--from", "yaml", "."},
		{"--to", "html", "."},
		{"--indent", "9", "."},
		{"--arg", "k"},
		{"-L"},
		{"edit", "-i", ".a=1"},
		{"fmt", "-i", "-"},
		{"--no-filename", ".a"},
		{"diff", "--set", "--position", "a", "b"},
		{"check", "--jsonpath", "."},
	}
	for bc in bad_cases {
		r := invoke_str(bc, "{}"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 2)
		testing.expect(t, len(r.stderr) > 0, fmt.tprintf("expected stderr for %v", bc))
	}
}

@(test)
jq_core_flags_and_exit_codes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	{
		r := invoke_str({"-r", ".a"}, `{"a":"hi\n"}`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "hi\n\n")
	}
	{
		r := invoke_str({"-j", ".[]"}, `["a","b"]`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "ab")
	}
	{
		r := invoke_str({"--raw-output0", ".[]"}, `["a","b"]`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "a\x00b\x00")
	}
	{
		r := invoke_str({"-c", "-S", "."}, `{"z":1,"a":2}`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "{\"a\":2,\"z\":1}\n")
	}
	{
		r := invoke_str({"--indent", "4", "."}, `[1]`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "[\n    1\n]\n")
	}
	{
		r := invoke_str({"--tab", "."}, `[1]`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "[\n\t1\n]\n")
	}
	{
		r := invoke_str({"-a", "."}, "\"é\""); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "\"\\u00e9\"\n")
	}
	{
		r := invoke_str({"-C", "-c", "."}, `{"a":1}`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "\e["), r.stdout)
	}
	{
		r := invoke({"-n", "--arg", "x", "hi", "--argjson", "n", "[1,2]", "{$x,$n,named:$ARGS.named.x}"}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "\"x\": \"hi\""), r.stdout)
	}
	{
		r := invoke_str({"-n", "--args", "$ARGS.positional", "--", "a", "b"}, ""); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "\"a\""), r.stdout)
	}
	{
		r := invoke_str({"-n", "[inputs]"}, "{\"x\":1}\n{\"x\":2}\n"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "\"x\": 2"), r.stdout)
	}
	{
		r := invoke_str({"-c", "-s", "."}, "1\n2\n3\n"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "[1,2,3]\n")
	}
	{
		r := invoke_str({"-R", "."}, "a\nb"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "\"a\"\n\"b\"\n")
	}
	{
		r := invoke_str({"-R", "-c", "."}, ""); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "")
	}
	{
		r := invoke_str({"-Rs", "."}, ""); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "\"\"\n")
	}
	{
		r0 := invoke_str({"-e", "true"}, "null"); defer run_out_destroy(&r0); testing.expect_value(t, r0.code, 0)
		r1 := invoke_str({"-e", "false"}, "null"); defer run_out_destroy(&r1); testing.expect_value(t, r1.code, 1)
		r4 := invoke_str({"-e", "empty"}, "null"); defer run_out_destroy(&r4); testing.expect_value(t, r4.code, 4)
		r3 := invoke_str({"[1,2"}, "null"); defer run_out_destroy(&r3); testing.expect_value(t, r3.code, 3)
		r5 := invoke_str({"."}, "{bad"); defer run_out_destroy(&r5); testing.expect_value(t, r5.code, 5)
		rh := invoke_str({"-n", `"oops" | halt_error(7)`}, ""); defer run_out_destroy(&rh); testing.expect_value(t, rh.code, 7)
	}
	{
		r := invoke_str({"--seq", "-c", "."}, "\x1e1\n\x1e2\n"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "\x1e1\n\x1e2\n")
	}
	{
		r := invoke_str({"--stream", "-c", "."}, `{"a":1}`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "[[\"a\"],1]\n[[\"a\"]]\n")
	}
	{
		r := invoke_str({"--stream-errors", "-c", "."}, "{\"a\":1}\n{bad\n"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "[[\"a\"],1]"), r.stdout)
	}
}

@(test)
jq_files_modules_rawfile_slurpfile_and_each :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)
	mod_dir := join_path(t, dir, "mods"); defer delete(mod_dir)
	testing.expect(t, os.make_directory(mod_dir) == nil, "mkdir mods")

	mod_p := write_tmp_file(t, mod_dir, "m.jq", transmute([]u8)string("def dbl: . * 2;\n")); defer delete(mod_p)
	filt_p := write_tmp_file(t, dir, "f.jq", transmute([]u8)string("import \"m\" as m; (.v | m::dbl) + ($raw | length) + ($sl | length)\n")); defer delete(filt_p)
	raw_p := write_tmp_file(t, dir, "raw.txt", transmute([]u8)string("abc")); defer delete(raw_p)
	sl_p := write_tmp_file(t, dir, "sl.json", transmute([]u8)string("10\n20\n")); defer delete(sl_p)
	d1_p := write_tmp_file(t, dir, "a.json", transmute([]u8)string(`{"v":5}`)); defer delete(d1_p)
	d2_p := write_tmp_file(t, dir, "b.json", transmute([]u8)string(`{"v":7}`)); defer delete(d2_p)

	r := invoke({"-L", mod_dir, "-f", "--rawfile", "raw", raw_p, "--slurpfile", "sl", sl_p, "--each", "-c", filt_p, d1_p, d2_p}); defer run_out_destroy(&r)
	testing.expect_value(t, r.code, 0)
	testing.expect(t, strings.contains(r.stdout, "15\n"), r.stdout)
	testing.expect(t, strings.contains(r.stdout, "19\n"), r.stdout)
	testing.expect(t, strings.contains(r.stdout, d1_p), r.stdout)
}

@(test)
engine_features_explain_where_threads_dups_and_quarantine :: proc(t: ^testing.T) {
	testkit.deadline(t)
	{
		r := invoke_str({"--explain", "-c", ".a"}, `{"a":1,"b":2}`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "1\n")
		testing.expect(t, strings.contains(r.stderr, "route:"), r.stderr)
	}
	{
		dir := make_tmp_dir(t); defer drop_tmp_dir(dir)
		p := write_tmp_file(t, dir, "w.json", transmute([]u8)string("{\n  \"a\": {\n    \"b\": 42\n  }\n}\n")); defer delete(p)
		r := invoke({"--where", "-c", ".a.b", p}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, ":3:10: 42\n"), r.stdout)
	}
	{
		doc, berr := engine.build(transmute([]u8)string(`{"k":99}`), engine.spec_of_id(.Json), {})
		testing.expect(t, berr == nil, "build")
		defer tape.destroy_document(&doc)
		cbor_bytes, _, werr := engine.write(&doc, engine.spec_of_id(.Cbor), {})
		testing.expect(t, werr == nil, "write cbor")
		defer delete(cbor_bytes)
		r := invoke({"--where", "--from", "cbor", "-c", ".k"}, cbor_bytes); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "byte ") && strings.contains(r.stdout, ": 99\n"), r.stdout)
	}
	{
		r := invoke_str({"--dups", "refuse", ".a"}, `{"a":1,"a":2}`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 5)
	}
	{
		rl := invoke_str({"--dups", "last", "-c", ".a"}, `{"a":1,"a":2}`); defer run_out_destroy(&rl)
		rf := invoke_str({"--dups", "first", "-c", ".a"}, `{"a":1,"a":2}`); defer run_out_destroy(&rf)
		testing.expect_value(t, rl.code, 0); testing.expect_value(t, rl.stdout, "2\n")
		testing.expect_value(t, rf.code, 0); testing.expect_value(t, rf.stdout, "1\n")
	}
	{
		dir := make_tmp_dir(t); defer drop_tmp_dir(dir)
		qp := join_path(t, dir, "bad.ndjson"); defer delete(qp)
		dp := write_tmp_file(t, dir, "in.ndjson", transmute([]u8)string("{\"a\":1}\n{bad\n{\"a\":3}\n")); defer delete(dp)
		r := invoke({"--from", "ndjson", "--skip-bad", "--quarantine", qp, "-c", ".a", dp}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 5)
		testing.expect_value(t, r.stdout, "1\n3\n")
		qdata, qerr := os.read_entire_file_from_path(qp, context.allocator); testing.expect(t, qerr == nil, "read quarantine")
		defer delete(qdata)
		testing.expect(t, strings.contains(string(qdata), "{bad"), string(qdata))
	}
	{
		r := invoke_str({"--max-depth", "2", "."}, `[[[1]]]`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 5)
	}
	{
		r := invoke_str({"--threads", "2", "--from", "ndjson", "-c", ".x"}, "{\"x\":1}\n{\"x\":2}\n{\"x\":3}\n"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "1\n2\n3\n")
	}
}

@(test)
multiformat_query_and_to_conversion :: proc(t: ^testing.T) {
	testkit.deadline(t)
	{
		r := invoke_str({"--from", "toml", "-c", ".pkg.name"}, "[pkg]\nname = \"stury\"\n"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "\"stury\"\n")
	}
	{
		r := invoke_str({"--from", "xml", "-c", ".root.item"}, "<root><item>hi</item></root>"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "\"hi\"\n")
	}
	{
		r := invoke_str({"--from", "csv", "-c", ".a"}, "a,b\n1,2\n3,4\n"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "\"1\"\n\"3\"\n")
	}
	{
		r := invoke_str({"--to", "toml", "."}, `{"app":{"port":8080}}`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "[app]") && strings.contains(r.stdout, "port = 8080"), r.stdout)
	}
	{
		r := invoke_str({"--to", "xml", "."}, `{"root":{"item":"ok"}}`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "<root>") && strings.contains(r.stdout, "<item>ok</item>"), r.stdout)
	}
	{
		r := invoke_str({"--to", "csv", ".[]"}, `[{"a":1,"b":2},{"a":3,"b":4}]`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "a,b\n1,2\n3,4"), r.stdout)
	}
	{
		rx := invoke_str({"--from", "xml", "--to", "xml", "-c", `.r.a.&["k"] = "2"`}, `<r><a aria-label="x">t</a></r>`); defer run_out_destroy(&rx)
		testing.expect_value(t, rx.code, 0)
		testing.expect_value(t, rx.stdout, "<r><a aria-label=\"x\" k=\"2\">t</a></r>\n")
	}
	{
		rs := invoke_str({"--from", "xml", "--to", "xml", "-c", `.`}, `<r><a aria-label="x">t</a></r>`); defer run_out_destroy(&rs)
		testing.expect_value(t, rs.code, 0)
		testing.expect_value(t, rs.stdout, "<r><a aria-label=\"x\">t</a></r>\n")
	}
	{
		rj := invoke_str({"--from", "jsonc", "--to", "jsonc", "."}, "/* c */\n{\"a\":1}\n"); defer run_out_destroy(&rj)
		testing.expect_value(t, rj.code, 0)
		testing.expect(t, strings.contains(rj.stdout, "/* c */") && strings.contains(rj.stdout, "\"a\": 1"), rj.stdout)
	}
}

@(test)
jsonpath_queries_and_options :: proc(t: ^testing.T) {
	testkit.deadline(t)
	{
		r := invoke_str({"--jsonpath", "-c", "$.store.book[?@.price < 10].title"}, `{"store":{"book":[{"title":"A","price":5},{"title":"B","price":15}]}}`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "\"A\"\n")
	}
	{
		r := invoke_str({"--jsonpath", "--explain", "-c", "$..x"}, `{"a":{"x":1},"b":{"x":2}}`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "1\n2\n")
		testing.expect(t, strings.contains(r.stderr, "route:"), r.stderr)
	}
	{
		dir := make_tmp_dir(t); defer drop_tmp_dir(dir)
		p := write_tmp_file(t, dir, "jp.json", transmute([]u8)string("{\n  \"items\": [\"ok\"]\n}\n")); defer delete(p)
		r := invoke({"--jsonpath", "--where", "-c", "$.items[0]", p}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "$['items'][0]") && strings.contains(r.stdout, ":2:13: "), r.stdout)
	}
	{
		r3 := invoke_str({"--path", "$["}, `{}`); defer run_out_destroy(&r3); testing.expect_value(t, r3.code, 3)
		r4 := invoke_str({"--jsonpath", "-e", "$.missing"}, `{}`); defer run_out_destroy(&r4); testing.expect_value(t, r4.code, 4)
		r1 := invoke_str({"--jsonpath", "-e", "$.f"}, `{"f":false}`); defer run_out_destroy(&r1); testing.expect_value(t, r1.code, 1)
	}
}

@(test)
parallel_threads_parity_and_errors :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	// Multi-record NDJSON testing `-e`, runtime errors, halt_error, preloaded globals, and jsonpath under `--threads 4`.
	sb := strings.builder_make(context.allocator); defer strings.builder_destroy(&sb)
	for i in 0 ..< 24 {
		fmt.sbprintf(&sb, "{{\"k\":%d,\"ok\":%s}}\n", i, "false" if i == 23 else "true")
	}
	nd := strings.to_string(sb)
	raw_p := write_tmp_file(t, dir, "raw.txt", transmute([]u8)string("hi")); defer delete(raw_p)
	sl_p := write_tmp_file(t, dir, "sl.json", transmute([]u8)string("10\n20\n")); defer delete(sl_p)

	r_e1 := invoke_str({"--threads", "1", "--from", "ndjson", "-e", ".ok"}, nd); defer run_out_destroy(&r_e1)
	r_e4 := invoke_str({"--threads", "4", "--from", "ndjson", "-e", ".ok"}, nd); defer run_out_destroy(&r_e4)
	testing.expect_value(t, r_e1.code, 1)
	testing.expect(t, r_e1.stderr == "", r_e1.stderr)
	testing.expect_value(t, r_e4.code, 1)
	testing.expect(t, r_e4.stderr == "", r_e4.stderr)
	testing.expect_value(t, r_e4.stdout, r_e1.stdout)

	r_emp := invoke_str({"--threads", "4", "--from", "ndjson", "-e", "empty"}, nd); defer run_out_destroy(&r_emp)
	testing.expect_value(t, r_emp.code, 4)

	r_g1 := invoke_str({"--threads", "1", "--from", "ndjson", "-c", "--argjson", "n", "5", "--rawfile", "r", raw_p, "--slurpfile", "s", sl_p, ".k + $n + ($r|length) + ($s|length)"}, nd); defer run_out_destroy(&r_g1)
	r_g4 := invoke_str({"--threads", "4", "--from", "ndjson", "-c", "--argjson", "n", "5", "--rawfile", "r", raw_p, "--slurpfile", "s", sl_p, ".k + $n + ($r|length) + ($s|length)"}, nd); defer run_out_destroy(&r_g4)
	testing.expect_value(t, r_g4.code, 0)
	testing.expect_value(t, r_g4.stdout, r_g1.stdout)

	r_halt := invoke_str({"--threads", "4", "--from", "ndjson", `if .k == 7 then ("boom" | halt_error(9)) else .k end`}, nd); defer run_out_destroy(&r_halt)
	testing.expect_value(t, r_halt.code, 9)
	testing.expect(t, strings.contains(r_halt.stderr, "boom"), r_halt.stderr)

	r_err := invoke_str({"--threads", "4", "--from", "ndjson", `if .k == 5 then ("x" + 1) else .k end`}, nd); defer run_out_destroy(&r_err)
	testing.expect_value(t, r_err.code, 5)
	testing.expect(t, len(r_err.stderr) > 0, "expected runtime error message on parallel worker error")

	r_jp := invoke_str({"--jsonpath", "--threads", "4", "--from", "ndjson", "-e", "$.ok"}, nd); defer run_out_destroy(&r_jp)
	testing.expect_value(t, r_jp.code, 1)
	r_jpm := invoke_str({"--jsonpath", "--threads", "4", "--from", "ndjson", "-e", "$.missing"}, nd); defer run_out_destroy(&r_jpm)
	testing.expect_value(t, r_jpm.code, 4)
}

@(test)
engine_fast_paths_spine_pred_proj_files :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	// Build a >550 KiB JSON array of objects to exceed `engine.SPINE_PARALLEL_FROM` (512 KiB).
	ab := strings.builder_make(context.allocator); defer strings.builder_destroy(&ab)
	strings.write_byte(&ab, '[')
	for i in 0 ..< 14000 {
		if i > 0 {
			strings.write_byte(&ab, ',')
		}
		fmt.sbprintf(&ab, "{{\"k\":%d,\"pad\":\"abcdefghijklmnopqrstuvwxyz\"}}", i)
	}
	strings.write_byte(&ab, ']')
	big_arr := strings.to_string(ab)

	// Spine_Parallel (.Stream).
	rs1 := invoke_str({"--threads", "1", "-c", ".[] | .k"}, big_arr); defer run_out_destroy(&rs1)
	rs4 := invoke_str({"--threads", "4", "--explain", "-c", ".[] | .k"}, big_arr); defer run_out_destroy(&rs4)
	testing.expect_value(t, rs4.code, 0)
	testing.expect(t, strings.contains(rs4.stderr, "spine_parallel"), rs4.stderr)
	testing.expect_value(t, rs4.stdout, rs1.stdout)

	// Spine_Parallel (.Collect).
	rc1 := invoke_str({"--threads", "1", "-c", "[.[] | .k + 1]"}, big_arr); defer run_out_destroy(&rc1)
	rc4 := invoke_str({"--threads", "4", "--explain", "-c", "[.[] | .k + 1]"}, big_arr); defer run_out_destroy(&rc4)
	testing.expect_value(t, rc4.code, 0)
	testing.expect(t, strings.contains(rc4.stderr, "spine_parallel"), rc4.stderr)
	testing.expect_value(t, rc4.stdout, rc1.stdout)

	// Conditional_Whole general predicate (`pred_eval` + `pred_prog`).
	ob := strings.builder_make(context.allocator); defer strings.builder_destroy(&ob)
	fmt.sbprintf(&ob, "{{\"items\":%s}}", big_arr)
	big_obj := strings.to_string(ob)
	rp1 := invoke_str({"--threads", "1", "-c", "select((.items | length) > 10 and .items[0].k == 0)"}, big_obj); defer run_out_destroy(&rp1)
	rp4 := invoke_str({"--threads", "4", "--explain", "-c", "select((.items | length) > 10 and .items[0].k == 0)"}, big_obj); defer run_out_destroy(&rp4)
	testing.expect_value(t, rp4.code, 0)
	testing.expect(t, strings.contains(rp4.stderr, "conditional_whole"), rp4.stderr)
	testing.expect_value(t, rp4.stdout, rp1.stdout)
	rp_no := invoke_str({"--threads", "4", "--explain", "-c", "select((.items | length) > 99999 and .items[0].k == 0)"}, big_obj); defer run_out_destroy(&rp_no)
	testing.expect_value(t, rp_no.code, 0)
	testing.expect(t, strings.contains(rp_no.stderr, "conditional_whole"), rp_no.stderr)
	testing.expect_value(t, rp_no.stdout, "")

	// Projection_Direct JSON and CSV.
	nd := "{\"k\":1,\"b\":\"x\"}\n{\"k\":2,\"b\":\"y\"}\n"
	rproj := invoke_str({"--explain", "--from", "ndjson", "-c", ".k"}, nd); defer run_out_destroy(&rproj)
	testing.expect_value(t, rproj.code, 0)
	testing.expect(t, strings.contains(rproj.stderr, "projection_direct"), rproj.stderr)
	testing.expect_value(t, rproj.stdout, "1\n2\n")

	rproj_csv := invoke_str({"--explain", "--from", "ndjson", "--to", "csv", "{k,b}"}, nd); defer run_out_destroy(&rproj_csv)
	testing.expect_value(t, rproj_csv.code, 0)
	testing.expect(t, strings.contains(rproj_csv.stderr, "projection_direct"), rproj_csv.stderr)
	testing.expect_value(t, rproj_csv.stdout, "k,b\n1,x\n2,y\n")

	// Files_Parallel across 3 regular files preserves `(file_idx, rec_idx)` order.
	p1 := write_tmp_file(t, dir, "f1.ndjson", transmute([]u8)string("{\"k\":1}\n{\"k\":2}\n")); defer delete(p1)
	p2 := write_tmp_file(t, dir, "f2.ndjson", transmute([]u8)string("{\"k\":3}\n")); defer delete(p2)
	p3 := write_tmp_file(t, dir, "f3.ndjson", transmute([]u8)string("{\"k\":4}\n{\"k\":5}\n")); defer delete(p3)
	rfp := invoke({"--threads", "4", "--explain", "-c", ".k", p1, p2, p3}); defer run_out_destroy(&rfp)
	testing.expect_value(t, rfp.code, 0)
	testing.expect(t, strings.contains(rfp.stderr, "files_parallel"), rfp.stderr)
	testing.expect_value(t, rfp.stdout, "1\n2\n3\n4\n5\n")
}

@(test)
stdout_errors_unbuffered_and_one_doc :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Fail_Sink :: struct {
		fail_write: bool,
		fail_flush: bool,
		flushes:    int,
		out:        [dynamic]u8,
	}
	sink_writer :: proc(fs: ^Fail_Sink) -> io.Writer {
		p :: proc(d: rawptr, mode: io.Stream_Mode, buf: []u8, _: i64, _: io.Seek_From) -> (i64, io.Error) {
			s := (^Fail_Sink)(d)
			#partial switch mode {
			case .Query:
				return io.query_utility({.Write, .Flush})
			case .Write:
				if s.fail_write {
					return 0, .Unknown
				}
				append(&s.out, ..buf)
				return i64(len(buf)), .None
			case .Flush:
				s.flushes += 1
				if s.fail_flush {
					return 0, .Unknown
				}
				return 0, .None
			}
			return 0, .Empty
		}
		return io.Writer{procedure = p, data = fs}
	}

	// Failing stdout exits 2 across query and verbs.
	{
		fs := Fail_Sink{fail_write = true, out = make([dynamic]u8)}
		defer delete(fs.out)
		eb := strings.builder_make(); defer strings.builder_destroy(&eb)
		c := cli.run_cli({"-c", "."}, transmute([]u8)string(`{"a":1}`), sink_writer(&fs), strings.to_writer(&eb), false, false)
		testing.expect_value(t, c, 2)
	}
	{
		fs := Fail_Sink{fail_flush = true, out = make([dynamic]u8)}
		defer delete(fs.out)
		eb := strings.builder_make(); defer strings.builder_destroy(&eb)
		c := cli.run_cli({"fmt", "-c"}, transmute([]u8)string(`{"a": 1}`), sink_writer(&fs), strings.to_writer(&eb), false, false)
		testing.expect_value(t, c, 2)
	}
	{
		fs := Fail_Sink{fail_write = true, out = make([dynamic]u8)}
		defer delete(fs.out)
		eb := strings.builder_make(); defer strings.builder_destroy(&eb)
		c := cli.run_cli({"edit", ".a=2"}, transmute([]u8)string(`{"a":1}`), sink_writer(&fs), strings.to_writer(&eb), false, false)
		testing.expect_value(t, c, 2)
	}

	// `--unbuffered` flushes per emitted value.
	{
		fs_u := Fail_Sink{out = make([dynamic]u8)}; defer delete(fs_u.out)
		eb_u := strings.builder_make(); defer strings.builder_destroy(&eb_u)
		cu := cli.run_cli({"--unbuffered", "-c", ".[]"}, transmute([]u8)string("[1,2,3]"), sink_writer(&fs_u), strings.to_writer(&eb_u), false, false)
		testing.expect_value(t, cu, 0)
		testing.expect(t, fs_u.flushes >= 3, fmt.tprintf("expected >=3 flushes, got %d", fs_u.flushes))

		fs_b := Fail_Sink{out = make([dynamic]u8)}; defer delete(fs_b.out)
		eb_b := strings.builder_make(); defer strings.builder_destroy(&eb_b)
		cb := cli.run_cli({"-c", ".[]"}, transmute([]u8)string("[1,2,3]"), sink_writer(&fs_b), strings.to_writer(&eb_b), false, false)
		testing.expect_value(t, cb, 0)
		testing.expect_value(t, fs_b.flushes, 1)
	}

	// `--to toml` and `--to xml` refuse a second document with exit 5.
	{
		rt := invoke_str({"--to", "toml", ".[]"}, `[{"a":1},{"a":2}]`); defer run_out_destroy(&rt)
		testing.expect_value(t, rt.code, 5)
		testing.expect(t, strings.contains(rt.stderr, "--to toml writes one document"), rt.stderr)
		rx := invoke_str({"--to", "xml", ".[]"}, `[{"r":1},{"r":2}]`); defer run_out_destroy(&rx)
		testing.expect_value(t, rx.code, 5)
		testing.expect(t, strings.contains(rx.stderr, "--to xml writes one document"), rx.stderr)
	}
}

@(test)
format_options_isolation_and_edges :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	// XML `--infer` & TSV `--infer` + `--delimiter`.
	{
		rx := invoke_str({"--from", "xml", "--infer", "-c", ".r.n == 5"}, `<r><n>5</n></r>`); defer run_out_destroy(&rx)
		testing.expect_value(t, rx.code, 0); testing.expect_value(t, rx.stdout, "true\n")

		rt := invoke_str({"--from", "tsv", "--infer", "-c", ".a == 1"}, "a\tb\n1\tx\n"); defer run_out_destroy(&rt)
		testing.expect_value(t, rt.code, 0); testing.expect_value(t, rt.stdout, "true\n")

		rd := invoke_str({"--from", "csv", "--delimiter", ";", "-c", ".b"}, "a;b\n1;hi\n"); defer run_out_destroy(&rd)
		testing.expect_value(t, rd.code, 0); testing.expect_value(t, rd.stdout, "\"hi\"\n")

		rr := invoke_str({"--from", "csv", "--ragged", "--lazy-quotes", "-c", ".b"}, "a,b\n1\n2,ok\n"); defer run_out_destroy(&rr)
		testing.expect_value(t, rr.code, 0); testing.expect_value(t, rr.stdout, "null\n\"ok\"\n")

		rg := invoke_str({"--to", "csv", "--grow-header", ".[]"}, `[{"a":1},{"a":2,"b":3}]`); defer run_out_destroy(&rg)
		testing.expect_value(t, rg.code, 0); testing.expect_value(t, rg.stdout, "a,b\n1,\n2,3\n")
	}
	// JSONC multi-line auto-detected from extension parses as single document, never Concatenated.
	{
		jc_p := write_tmp_file(t, dir, "cfg.jsonc", transmute([]u8)string("{\n  // c\n  \"a\": 1,\n  \"b\": 2\n}\n")); defer delete(jc_p)
		r := invoke({"-c", ".a + .b", jc_p}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0); testing.expect_value(t, r.stdout, "3\n")
	}
	// Missing file continues to subsequent valid file and exits 2.
	{
		ok_p := write_tmp_file(t, dir, "ok.json", transmute([]u8)string(`{"a":7}`)); defer delete(ok_p)
		miss_p := join_path(t, dir, "missing.json"); defer delete(miss_p)
		r := invoke({"-c", ".a", miss_p, ok_p}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 2); testing.expect_value(t, r.stdout, "7\n")
		testing.expect(t, len(r.stderr) > 0, "expected open error")
	}
	// `-n [inputs]` with multi-file CSV keeps header clean across every row.
	{
		c1 := write_tmp_file(t, dir, "c1.csv", transmute([]u8)string("a,b\n1,x\n")); defer delete(c1)
		c2 := write_tmp_file(t, dir, "c2.csv", transmute([]u8)string("a,b\n2,y\n")); defer delete(c2)
		r := invoke({"--from", "csv", "-n", "-c", "[inputs | .b]", c1, c2}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0); testing.expect_value(t, r.stdout, "[\"x\",\"y\"]\n")
	}
	// Output flags: `-r -a`, `--raw-output0` NUL error, `--seq -r` no RS before raw strings, `NaN` slot 0 color, negative filter, duplicate `--arg`.
	{
		ra := invoke_str({"-r", "-a", "."}, `"é"`); defer run_out_destroy(&ra)
		testing.expect_value(t, ra.code, 0); testing.expect_value(t, ra.stdout, "\"\\u00e9\"\n")

		rnul := invoke_str({"--raw-output0", "."}, "\"a\\u0000b\""); defer run_out_destroy(&rnul)
		testing.expect_value(t, rnul.code, 5)

		rsr := invoke_str({"--seq", "-r", ".a"}, "\x1e{\"a\":\"hi\"}\n"); defer run_out_destroy(&rsr)
		testing.expect_value(t, rsr.code, 0); testing.expect(t, rsr.stderr == "", rsr.stderr); testing.expect_value(t, rsr.stdout, "hi\n")

		rnan := invoke_str({"-C", "-c", "nan"}, "null"); defer run_out_destroy(&rnan)
		testing.expect_value(t, rnan.code, 0); testing.expect_value(t, rnan.stdout, "\e[0;90mnull\e[0m\n")

		rneg := invoke_str({"-1"}, `{"x":1}`); defer run_out_destroy(&rneg)
		testing.expect_value(t, rneg.code, 0); testing.expect_value(t, rneg.stdout, "-1\n")

		rdup := invoke_str({"-n", "--arg", "k", "first", "--arg", "k", "second", "$k"}, ""); defer run_out_destroy(&rdup)
		testing.expect_value(t, rdup.code, 0); testing.expect_value(t, rdup.stdout, "\"first\"\n")

		rloc := invoke_str({"-n", "-c", "0 | localtime | length"}, ""); defer run_out_destroy(&rloc)
		testing.expect_value(t, rloc.code, 0); testing.expect_value(t, rloc.stdout, "8\n")
	}
	// Streaming delimited spans handle unterminated final LF lines without looping.
	{
		nd_p := write_tmp_file(t, dir, "noeol.ndjson", transmute([]u8)string("{\"x\":1}\ntru")); defer delete(nd_p)
		bs, bok := cli.byte_stream_open(nd_p, nil, {}, context.allocator)
		testing.expect(t, bok, "open stream")
		defer cli.byte_stream_close(&bs)
		sbuf := make([dynamic]u8); defer delete(sbuf)
		span: []u8
		has1, d1, e1 := cli.byte_stream_next_delim_span(&bs, '\n', &span, &sbuf, true)
		testing.expect(t, has1 && d1 && e1 == nil && string(span) == "{\"x\":1}", string(span))
		has2, d2, e2 := cli.byte_stream_next_delim_span(&bs, '\n', &span, &sbuf, true)
		testing.expect(t, has2 && !d2 && e2 == nil && string(span) == "tru", string(span))
		has3, _, e3 := cli.byte_stream_next_delim_span(&bs, '\n', &span, &sbuf, true)
		testing.expect(t, !has3 && e3 == nil, "EOF")
	}
}

@(test)
reaudit_parallel_streaming_and_seq_fixes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	// 1. Allocator race safety & outcome merge under `--threads 4` on `.Records_Parallel` and `.Spine_Parallel`.
	{
		sb := strings.builder_make(); defer strings.builder_destroy(&sb)
		for i in 0 ..< 600 {
			fmt.sbprintf(&sb, "{{\"i\":%d,\"s\":\"payload-item-%d\"}}\n", i, i)
		}
		nd_p := write_tmp_file(t, dir, "par.ndjson", transmute([]u8)strings.to_string(sb)); defer delete(nd_p)
		r_ok := invoke({"--threads", "4", "-c", ".i + 1", nd_p}); defer run_out_destroy(&r_ok)
		testing.expect_value(t, r_ok.code, 0)
		testing.expect(t, strings.has_prefix(r_ok.stdout, "1\n2\n") && strings.has_suffix(r_ok.stdout, "599\n600\n"), "parallel records order")

		r_err := invoke({"--threads", "4", "-c", "if .i == 300 then error(\"boom\") else .i end", nd_p}); defer run_out_destroy(&r_err)
		testing.expect_value(t, r_err.code, 5)
		testing.expect(t, strings.contains(r_err.stderr, "boom"), r_err.stderr)

		// Hint 1 `.Collect` (`[.[].x] | input_filename`) keeps real filename & locked allocs cleanly.
		sp_sb := strings.builder_make(); defer strings.builder_destroy(&sp_sb)
		strings.write_string(&sp_sb, `{"items":[`)
		for i in 0 ..< 2500 {
			if i > 0 { strings.write_byte(&sp_sb, ',') }
			fmt.sbprintf(&sp_sb, "{{\"x\":%d,\"pad\":\"abcdefghijklmnopqrstuvwxyz\"}}", i)
		}
		strings.write_string(&sp_sb, "]}")
		sp_p := write_tmp_file(t, dir, "spine.json", transmute([]u8)strings.to_string(sp_sb)); defer delete(sp_p)
		r_sp := invoke({"--threads", "4", "-c", `[.items[] | .x + 1] | [length, input_filename]`, sp_p}); defer run_out_destroy(&r_sp)
		testing.expect_value(t, r_sp.code, 0)
		testing.expect(t, strings.contains(r_sp.stdout, "[2500,") && strings.contains(r_sp.stdout, "spine.json"), r_sp.stdout)
	}

	// 2. `.Files_Parallel`: heterogeneous formats (`--infer`), failing filename on `Read_Error`, >32KiB chunks, and blocked-direct flags.
	{
		j1 := write_tmp_file(t, dir, "mix1.json", transmute([]u8)string(`{"a":1,"b":"ok"}`)); defer delete(j1)
		c1 := write_tmp_file(t, dir, "mix2.csv", transmute([]u8)string("a,b\n10,row\n")); defer delete(c1)
		rmix := invoke({"--threads", "4", "--infer", "-c", ".", j1, c1}); defer run_out_destroy(&rmix)
		testing.expect_value(t, rmix.code, 0)
		testing.expect_value(t, rmix.stdout, "{\"a\":1,\"b\":\"ok\"}\n{\"a\":10,\"b\":\"row\"}\n")

		g1 := write_tmp_file(t, dir, "goodf.json", transmute([]u8)string(`{"a":1}`)); defer delete(g1)
		b2 := write_tmp_file(t, dir, "badf2.json", transmute([]u8)string(`{"a": [1, }`)); defer delete(b2)
		rf_err := invoke({"--threads", "4", "-c", ".a", g1, b2}); defer run_out_destroy(&rf_err)
		testing.expect_value(t, rf_err.code, 5)
		testing.expect(t, strings.contains(rf_err.stderr, "badf2.json") && !strings.contains(rf_err.stderr, "<files>"), rf_err.stderr)

		// Large > 80 KiB value across `.Files_Parallel` must never get `\n` injected mid-chunk.
		big_pad := strings.repeat("x", 80 * 1024); defer delete(big_pad)
		big_doc := strings.concatenate({`{"big":"`, big_pad, `","k":{"z":2,"a":1}}`}); defer delete(big_doc)
		bf1 := write_tmp_file(t, dir, "bf1.json", transmute([]u8)big_doc); defer delete(bf1)
		bf2 := write_tmp_file(t, dir, "bf2.json", transmute([]u8)big_doc); defer delete(bf2)
		rbig := invoke({"--threads", "4", "-c", ".big", bf1, bf2}); defer run_out_destroy(&rbig)
		testing.expect_value(t, rbig.code, 0)
		want_line := strings.concatenate({`"`, big_pad, `"`}); defer delete(want_line)
		want_two := strings.concatenate({want_line, "\n", want_line, "\n"}); defer delete(want_two)
		testing.expect_value(t, len(rbig.stdout), len(want_two))
		testing.expect(t, rbig.stdout == want_two, "80 KiB projection output corrupted")

		rsort := invoke({"--threads", "4", "-S", "-c", ".k", bf1, bf2}); defer run_out_destroy(&rsort)
		testing.expect_value(t, rsort.code, 0)
		testing.expect_value(t, rsort.stdout, "{\"a\":1,\"z\":2}\n{\"a\":1,\"z\":2}\n")

		rexit := invoke({"--threads", "4", "-e", ".missing", bf1, bf2}); defer run_out_destroy(&rexit)
		testing.expect_value(t, rexit.code, 1)
	}

	// 3. Concatenated JSON under `-S`/`--explain` avoids `.Single` double-scan (`framing: concatenated`).
	{
		rcat := invoke_str({"--explain", "-S", "-c", ".a"}, "{\"a\":{\"y\":2,\"x\":1}}\n{\"a\":{\"z\":3}}\n"); defer run_out_destroy(&rcat)
		testing.expect_value(t, rcat.code, 0)
		testing.expect_value(t, rcat.stdout, "{\"x\":1,\"y\":2}\n{\"z\":3}\n")
		testing.expect(t, strings.contains(rcat.stderr, "framing: concatenated"), rcat.stderr)
		testing.expect(t, !strings.contains(rcat.stderr, "framing: single"), rcat.stderr)
	}

	// 4. Multi-file `--to csv` keeps header + `Table_Writer` intact across files (jq + JSONPath).
	{
		t1 := write_tmp_file(t, dir, "t1.json", transmute([]u8)string(`{"a":1,"b":"x"}`)); defer delete(t1)
		t2 := write_tmp_file(t, dir, "t2.json", transmute([]u8)string(`{"a":2,"b":"y"}`)); defer delete(t2)
		rj := invoke({"--to", "csv", "{a, b}", t1, t2}); defer run_out_destroy(&rj)
		testing.expect_value(t, rj.code, 0)
		testing.expect_value(t, rj.stdout, "a,b\n1,x\n2,y\n")
		rjp := invoke({"--jsonpath", "--to", "csv", "$", t1, t2}); defer run_out_destroy(&rjp)
		testing.expect_value(t, rjp.code, 0)
		testing.expect_value(t, rjp.stdout, "a,b\n1,x\n2,y\n")
	}

	// 5. `-n --stream` emits `tostream` events cleanly for `inputs` / `fromstream` / `--stream-errors` and releases on early stop.
	{
		rs := invoke_str({"-nc", "--stream", "[inputs]"}, "{\"a\":[1,2]}\n{\"b\":true}\n"); defer run_out_destroy(&rs)
		testing.expect_value(t, rs.code, 0)
		testing.expect_value(t, rs.stdout, `[[["a",0],1],[["a",1],2],[["a",1]],[["a"]],[["b"],true],[["b"]]]`+"\n")

		rf := invoke_str({"-nc", "--stream", "fromstream(inputs)"}, "{\"a\":1}\n"); defer run_out_destroy(&rf)
		testing.expect_value(t, rf.code, 0)
		testing.expect_value(t, rf.stdout, "{\"a\":1}\n")

		rse := invoke_str({"-nc", "--stream", "--stream-errors", "[inputs]"}, "[1]\n:\n[2]\n"); defer run_out_destroy(&rse)
		testing.expect_value(t, rse.code, 0)
		testing.expect(t, strings.contains(rse.stdout, "[[0],1]") && strings.contains(rse.stdout, ",[]]"), rse.stdout)

		rfirst := invoke_str({"-nc", "--stream", "first(inputs)"}, "{\"a\":[1,2,3]}\n"); defer run_out_destroy(&rfirst)
		testing.expect_value(t, rfirst.code, 0)
		testing.expect_value(t, rfirst.stdout, `[["a",0],1]`+"\n")
	}

	// 6. `--seq` trailing RS & error semantics, failing stdout exit 2, `-f` NUL byte exit 2, `-R` `input_line_number`, `JQ_COLORS`.
	{
		// Trailing RS at EOF (`\x1e[1]\x1e` and `\x1e\x1e`) yields zero empty-record parse errors.
		sq_p := write_tmp_file(t, dir, "trail.seq", transmute([]u8)string("\x1e[1]\x1e")); defer delete(sq_p)
		bs, bok := cli.byte_stream_open(sq_p, nil, {}, context.allocator)
		testing.expect(t, bok, "open trail.seq")
		defer cli.byte_stream_close(&bs)
		sbuf := make([dynamic]u8); defer delete(sbuf)
		span: []u8
		h1, d1, e1 := cli.byte_stream_next_delim_span(&bs, 0x1e, &span, &sbuf, false)
		testing.expect(t, h1 && d1 && e1 == nil && string(span) == "[1]", string(span))
		h2, _, e2 := cli.byte_stream_next_delim_span(&bs, 0x1e, &span, &sbuf, false)
		testing.expect(t, !h2 && e2 == nil, "trailing RS consumed cleanly")

		// Non-stdin `.Seq` ignores parse errors cleanly with exit 0, while filter runtime error aborts with exit 5.
		rseq_ok := invoke_str({"--seq", "-c", "."}, "\x1e{\"a\":1}\n\x1e[bad\n\x1e{\"a\":2}\n"); defer run_out_destroy(&rseq_ok)
		testing.expect_value(t, rseq_ok.code, 0)
		testing.expect_value(t, rseq_ok.stdout, "\x1e{\"a\":1}\n\x1e{\"a\":2}\n")

		rseq_err := invoke_str({"--seq", "-c", `if . == 1 then error("boom") else . end`}, "\x1e1\n\x1e2\n"); defer run_out_destroy(&rseq_err)
		testing.expect_value(t, rseq_err.code, 5)
		testing.expect_value(t, rseq_err.stdout, "")

		// `-f` with NUL byte rejected with exit 2.
		nul_f := write_tmp_file(t, dir, "bad.jq", []u8{'.', 0, 'a'}); defer delete(nul_f)
		rnul := invoke_str({"-f", nul_f}, `{}`); defer run_out_destroy(&rnul)
		testing.expect_value(t, rnul.code, 2)
		testing.expect(t, strings.contains(rnul.stderr, "NUL"), rnul.stderr)

		// `-R` `input_line_number` counts newlines seen rather than unterminated EOF segments.
		rr1 := invoke_str({"-Rc", "[., input_line_number]"}, "a"); defer run_out_destroy(&rr1)
		testing.expect_value(t, rr1.code, 0); testing.expect_value(t, rr1.stdout, "[\"a\",0]\n")
		rr2 := invoke_str({"-Rnc", "[inputs | [., input_line_number]]"}, "a\nb\nc"); defer run_out_destroy(&rr2)
		testing.expect_value(t, rr2.code, 0); testing.expect_value(t, rr2.stdout, "[[\"a\",1],[\"b\",2],[\"c\",2]]\n")

		// Failing `stdout_w` must return EXIT_USAGE (2) everywhere, never 0, and avoid double-write in `write_value_as_format`.
		Fail_Sink :: struct {
			writes: int,
		}
		fs := Fail_Sink{}
		fail_proc :: proc(data: rawptr, mode: io.Stream_Mode, _: []u8, _: i64, _: io.Seek_From) -> (i64, io.Error) {
			#partial switch mode {
			case .Query:
				return io.query_utility({.Write})
			case .Write:
				(^Fail_Sink)(data).writes += 1
				return 0, .Unexpected_EOF
			}
			return 0, .None
		}
		fail_w := io.Writer{procedure = fail_proc, data = &fs}
		eb := strings.builder_make(); defer strings.builder_destroy(&eb)
		big_pad2 := strings.repeat("z", 70 * 1024); defer delete(big_pad2)
		big_json := strings.concatenate({`{"big":"`, big_pad2, `"}`}); defer delete(big_json)
		fc := cli.run_cli({"--to", "jsonc", "."}, transmute([]u8)big_json, fail_w, strings.to_writer(&eb))
		testing.expect_value(t, fc, 2)
		testing.expect_value(t, fs.writes, 1)

		eb2 := strings.builder_make(); defer strings.builder_destroy(&eb2)
		fc2 := cli.run_cli({"-R", "."}, transmute([]u8)big_pad2, fail_w, strings.to_writer(&eb2))
		testing.expect_value(t, fc2, 2)

		// `$JQ_COLORS` matches `cli.tsv:708` (`:::::::::` accepted cleanly, default slot 7 preserved).
		cols, owned, cok := cli.parse_jq_colors(":::::::::", context.allocator)
		testing.expect(t, cok, "parse_jq_colors :::::::::")
		testing.expect_value(t, cols[7], cli.DEFAULT_COLORS[7])
		cfg := cli.Render_Config{colors = cols, colors_owned = owned}
		cli.render_config_destroy(&cfg, context.allocator)

		// `try input` after malformed JSON cursor failure closes cursor cleanly instead of re-polling.
		rtry := invoke_str({"-nc", "[try input catch \"err\", try input catch \"eof\"]"}, "[1,\n"); defer run_out_destroy(&rtry)
		testing.expect_value(t, rtry.code, 0)
		testing.expect_value(t, rtry.stdout, "[\"err\",\"eof\"]\n")
	}

	// 7. `--to csv`/`tsv` `--grow-header` early-exit flush + leak freedom, and `Projection_Direct` tabular fallback.
	{
		gf1 := write_tmp_file(t, dir, "gf1.json", transmute([]u8)string(`{"a":1}`)); defer delete(gf1)
		gf2_bad := write_tmp_file(t, dir, "gf2_bad.json", transmute([]u8)string(`{bad`)); defer delete(gf2_bad)
		gf2_b := write_tmp_file(t, dir, "gf2_b.json", transmute([]u8)string(`{"b":2}`)); defer delete(gf2_b)

		// Multi-file `--grow-header` hitting parse error on file 2 flushes buffered rows and does not leak `worker.tw`.
		r_ge := invoke({"--to", "csv", "--grow-header", ".", gf1, gf2_bad}); defer run_out_destroy(&r_ge)
		testing.expect_value(t, r_ge.code, 5)
		testing.expect_value(t, r_ge.stdout, "a\n1\n")

		// Multi-file `--grow-header` hitting `halt_error(1)` on file 2 flushes buffered rows and frees cleanly.
		r_gh := invoke({"--to", "csv", "--grow-header", `if has("b") then halt_error(1) else . end`, gf1, gf2_b}); defer run_out_destroy(&r_gh)
		testing.expect_value(t, r_gh.code, 1)
		testing.expect_value(t, r_gh.stdout, "a\n1\n")

		// Single-doc `Projection_Direct` fallback (`null.x` triggers `.Wrong_Kind` -> `eval_jq_doc`).
		r_f1 := invoke_str({"--to", "csv", "{x: .a.x}"}, `{"a":null}`); defer run_out_destroy(&r_f1)
		testing.expect_value(t, r_f1.code, 0)
		testing.expect_value(t, r_f1.stdout, "x\n\n")

		r_f_err := invoke_str({"--to", "csv", "{x: .b.c}"}, `{"b":1}`); defer run_out_destroy(&r_f_err)
		testing.expect_value(t, r_f_err.code, 5)
		testing.expect(t, !strings.contains(r_f_err.stderr, "tabular output requires serial execution"), r_f_err.stderr)

		// Mixed NDJSON records across direct -> fallback -> direct keep exact row order and single header.
		r_fmix1 := invoke_str({"--to", "csv", "{x: .a.x}"}, "{\"a\":{\"x\":1}}\n{\"a\":null}\n{\"a\":{\"x\":2}}\n"); defer run_out_destroy(&r_fmix1)
		testing.expect_value(t, r_fmix1.code, 0)
		testing.expect_value(t, r_fmix1.stdout, "x\n1\n\n2\n")

		// Mixed NDJSON records starting with fallback -> direct suppress duplicate header cleanly.
		r_fmix2 := invoke_str({"--to", "csv", "{x: .a.x}"}, "{\"a\":null}\n{\"a\":{\"x\":1}}\n"); defer run_out_destroy(&r_fmix2)
		testing.expect_value(t, r_fmix2.code, 0)
		testing.expect_value(t, r_fmix2.stdout, "x\n\n1\n")

		// JSONPath `--to csv` `Projection_Direct` fallback on `.Wrong_Kind` (`[1]` / `null`) + `--to tsv` fallback.
		r_jpfb := invoke_str({"--jsonpath", "--to", "csv", "$.a.x"}, "{\"a\":{\"x\":1}}\n[1]\n{\"a\":null}\n{\"a\":{\"x\":2}}\n"); defer run_out_destroy(&r_jpfb)
		testing.expect_value(t, r_jpfb.code, 0)
		testing.expect_value(t, r_jpfb.stdout, "x\n1\n\n2\n")

		r_tsv := invoke_str({"--to", "tsv", "{x: .a.x}"}, "{\"a\":null}\n{\"a\":{\"x\":\"hi\"}}\n"); defer run_out_destroy(&r_tsv)
		testing.expect_value(t, r_tsv.code, 0)
		testing.expect_value(t, r_tsv.stdout, "x\n\nhi\n")

		r_jpfb2 := invoke_str({"--jsonpath", "--to", "csv", "--out-no-header", "$.a.x"}, "[1]\n{\"a\":{\"x\":7}}\n"); defer run_out_destroy(&r_jpfb2)
		testing.expect_value(t, r_jpfb2.code, 0)
		testing.expect_value(t, r_jpfb2.stdout, "7\n")
	}
}
