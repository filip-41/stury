package cli_tests

import "core:os"
import "core:strings"
import "core:testing"
import "stury:engine"
import "stury:testkit"

@(test)
check_syntax_dups_and_schema :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	ok_p := write_tmp_file(t, dir, "ok.json", transmute([]u8)string(`{"a":1,"b":"hi"}`)); defer delete(ok_p)
	bad_p := write_tmp_file(t, dir, "bad.json", transmute([]u8)string(`{"a":1,"b":99,"extra":true}`)); defer delete(bad_p)
	sch_p := write_tmp_file(t, dir, "schema.json", transmute([]u8)string(`{"type":"object","required":["a"],"properties":{"a":{"type":"integer"},"b":{"type":"string"}},"additionalProperties":false}`)); defer delete(sch_p)

	{
		r := invoke({"check", ok_p}); defer run_out_destroy(&r); testing.expect_value(t, r.code, 0)
	}
	{
		r := invoke_str({"check"}, "   \n"); defer run_out_destroy(&r); testing.expect_value(t, r.code, 5)
	}
	{
		r := invoke_str({"check", "--dups", "refuse"}, `{"a":1,"a":2}`); defer run_out_destroy(&r); testing.expect_value(t, r.code, 5)
	}
	{
		r := invoke({"check", "--schema", sch_p, ok_p}); defer run_out_destroy(&r); testing.expect_value(t, r.code, 0)
	}
	{
		r := invoke({"check", "--schema", sch_p, "--max-errors", "1", "--report", "lines", bad_p}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 1)
		testing.expect(t, strings.contains(r.stderr, ":1:"), r.stderr)
	}
	{
		r := invoke({"check", "--schema", sch_p, "--report", "basic", bad_p}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 1)
		testing.expect(t, strings.contains(r.stdout, `"valid"`), r.stdout)
	}
	{
		r := invoke({"check", "--schema", sch_p, "--report", "problem", bad_p}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 1)
		testing.expect(t, strings.contains(r.stdout, `"status":422`), r.stdout)
	}
	{
		ref_p := write_tmp_file(t, dir, "num.json", transmute([]u8)string(`{"type":"integer","minimum":5}`)); defer delete(ref_p)
		top_p := write_tmp_file(t, dir, "top.json", transmute([]u8)string(`{"properties":{"x":{"$ref":"num.json"}}}`)); defer delete(top_p)
		ro := invoke_str({"check", "--schema", top_p, "--schema-ref", dir}, `{"x":7}`); defer run_out_destroy(&ro); testing.expect_value(t, ro.code, 0)
		rx := invoke_str({"check", "--schema", top_p, "--schema-ref", dir}, `{"x":2}`); defer run_out_destroy(&rx); testing.expect_value(t, rx.code, 1)
	}
	{
		qp := join_path(t, dir, "quar.ndjson"); defer delete(qp)
		nd_p := write_tmp_file(t, dir, "items.ndjson", transmute([]u8)string("{\"a\":1}\n{bad\n{\"a\":\"no\"}\n")); defer delete(nd_p)
		r := invoke({"check", "--from", "ndjson", "--schema", sch_p, "--skip-bad", "--quarantine", qp, nd_p}); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 5)
		qd, qerr := os.read_entire_file_from_path(qp, context.allocator); testing.expect(t, qerr == nil, "read quar")
		defer delete(qd)
		qtxt := string(qd)
		lines := strings.split_lines(strings.trim_right(qtxt, "\r\n"), context.allocator)
		defer delete(lines)
		testing.expect_value(t, len(lines), 2)
		for ln in lines {
			testing.expect(t, engine.validate(transmute([]u8)ln, engine.spec_of_id(.Json), {}) == nil, ln)
		}
		testing.expect(t, strings.contains(qtxt, "{bad") && strings.contains(qtxt, `"status":400`), qtxt)
		testing.expect(t, strings.contains(qtxt, `\"no\"`) && strings.contains(qtxt, `"status":422`), qtxt)
		testing.expect(t, strings.contains(qtxt, ":3:") && !strings.contains(qtxt, "expected expected"), qtxt)
	}
}

@(test)
fmt_pretty_compact_in_place_and_convert :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	{
		r := invoke_str({"fmt", "--indent", "4", "-S"}, `{"b":2,"a":1}`); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "{\n    \"a\": 1,\n    \"b\": 2\n}\n")
	}
	{
		p := write_tmp_file(t, dir, "u.json", transmute([]u8)string(`{"a":1,"b":2}`)); defer delete(p)
		rc := invoke({"fmt", "--check", p}); defer run_out_destroy(&rc); testing.expect_value(t, rc.code, 1)
		ri := invoke({"fmt", "-i", "--tab", p}); defer run_out_destroy(&ri); testing.expect_value(t, ri.code, 0)
		rc2 := invoke({"fmt", "--check", "--tab", p}); defer run_out_destroy(&rc2); testing.expect_value(t, rc2.code, 0)
		saved, rerr := os.read_entire_file_from_path(p, context.allocator); testing.expect(t, rerr == nil, "read formatted")
		defer delete(saved)
		testing.expect_value(t, string(saved), "{\n\t\"a\": 1,\n\t\"b\": 2\n}\n")
	}
	{
		r := invoke_str({"fmt", "--from", "toml", "--to", "xml"}, "[root]\nmsg = \"ok\"\n"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect(t, strings.contains(r.stdout, "<root>") && strings.contains(r.stdout, "<msg>ok</msg>"), r.stdout)
	}
	{
		rt := invoke_str({"fmt", "--from", "json", "--to", "toml"}, `{"x":{"y":1}}`); defer run_out_destroy(&rt)
		testing.expect_value(t, rt.code, 0)
		testing.expect(t, strings.contains(rt.stdout, "[x]") && strings.contains(rt.stdout, "y = 1"), rt.stdout)
	}
	{
		rcsv := invoke_str({"fmt", "--from", "json", "--to", "csv"}, `[{"k":1,"v":"a"}]`); defer run_out_destroy(&rcsv)
		testing.expect_value(t, rcsv.code, 0)
		testing.expect_value(t, rcsv.stdout, "k,v\n1,a\n")
	}
	{
		rcbor := invoke_str({"fmt", "--from", "json", "--to", "cbor"}, `{"a":1}`); defer run_out_destroy(&rcbor)
		testing.expect_value(t, rcbor.code, 0)
		rback := invoke({"fmt", "--from", "cbor", "--to", "json", "-c"}, transmute([]u8)rcbor.stdout); defer run_out_destroy(&rback)
		testing.expect_value(t, rback.code, 0)
		testing.expect_value(t, rback.stdout, "{\"a\":1}\n")
	}
}

@(test)
edit_preserves_formatting_and_reflow :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	src := "{\n  // keep comment\n  \"a\":   1,\n  \"b\": 2\n}\n"
	{
		r := invoke_str({"edit", "--from", "jsonc", ".b = 9"}, src); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "{\n  // keep comment\n  \"a\":   1,\n  \"b\": 9\n}\n")
	}
	{
		r := invoke_str({"edit", "--arg", "k", "yes", ".b = $k"}, "{\"a\":1,\"b\":\"no\"}\n"); defer run_out_destroy(&r)
		testing.expect_value(t, r.code, 0)
		testing.expect_value(t, r.stdout, "{\"a\":1,\"b\":\"yes\"}\n")
	}
	{
		p := write_tmp_file(t, dir, "e.json", transmute([]u8)string("{\n  \"a\": 1\n}\n")); defer delete(p)
		rc := invoke({"edit", "--check", ".a = 2", p}); defer run_out_destroy(&rc); testing.expect_value(t, rc.code, 1)
		rd := invoke({"edit", "--diff", ".a = 2", p}); defer run_out_destroy(&rd); testing.expect_value(t, rd.code, 0)
		testing.expect(t, strings.contains(rd.stdout, ".a: 1 -> 2"), rd.stdout)
		ri := invoke({"edit", "-i", ".a = 2", p}); defer run_out_destroy(&ri); testing.expect_value(t, ri.code, 0)
		got, rerr := os.read_entire_file_from_path(p, context.allocator); testing.expect(t, rerr == nil, "read edited")
		defer delete(got)
		testing.expect_value(t, string(got), "{\n  \"a\": 2\n}\n")
	}
	{
		rnd := invoke_str({"edit", "--from", "ndjson", ".a += 10"}, "{\"a\":1}\n{\"a\":2}\n"); defer run_out_destroy(&rnd)
		testing.expect_value(t, rnd.code, 0)
		testing.expect_value(t, rnd.stdout, "{\"a\":11}\n{\"a\":12}\n")
	}
	{
		rref := invoke_str({"edit", "1, 2"}, `{"a":1}`); defer run_out_destroy(&rref)
		testing.expect_value(t, rref.code, 5)
	}
	{
		rno := invoke_str({"edit", ".a = 99"}, `{"a":1,"a":2}`); defer run_out_destroy(&rno)
		testing.expect_value(t, rno.code, 5)
		testing.expect(t, strings.contains(rno.stderr, "--reflow"), rno.stderr)
		ryes := invoke_str({"edit", "--reflow", ".a = 99"}, `{"a":1,"a":2}`); defer run_out_destroy(&ryes)
		testing.expect_value(t, ryes.code, 0)
		testing.expect_value(t, ryes.stdout, `{"a":99}`)
	}
	{
		rxml := invoke_str({"edit", "--from", "xml", `.r.a.&["k"] = "2"`}, `<r><a aria-label="x">t</a></r>`); defer run_out_destroy(&rxml)
		testing.expect_value(t, rxml.code, 0)
		testing.expect_value(t, rxml.stdout, `<r><a aria-label="x" k="2">t</a></r>`)
	}
}

@(test)
diff_values_patch_shape_and_schemas :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	a_p := write_tmp_file(t, dir, "a.json", transmute([]u8)string(`{"a":1,"b":[1,2]}`)); defer delete(a_p)
	b_p := write_tmp_file(t, dir, "b.json", transmute([]u8)string(`{"a":2,"b":[2,1],"c":true}`)); defer delete(b_p)
	s1_p := write_tmp_file(t, dir, "s1.json", transmute([]u8)string(`{"type":"object","required":["a"],"properties":{"a":{"type":"integer"}},"additionalProperties":false}`)); defer delete(s1_p)
	s2_p := write_tmp_file(t, dir, "s2.json", transmute([]u8)string(`{"type":"object","required":["a","b"],"properties":{"a":{"type":"integer"},"b":{"type":"string"}},"additionalProperties":false}`)); defer delete(s2_p)
	s3_p := write_tmp_file(t, dir, "s3.json", transmute([]u8)string(`{"type":"object","required":["a"],"properties":{"a":{"type":"integer"},"b":{"type":"string"}},"additionalProperties":false}`)); defer delete(s3_p)

	{
		rs := invoke({"diff", a_p, a_p}); defer run_out_destroy(&rs); testing.expect_value(t, rs.code, 0)
		rd := invoke({"diff", a_p, b_p}); defer run_out_destroy(&rd); testing.expect_value(t, rd.code, 1)
		testing.expect(t, strings.contains(rd.stdout, ".a: 1 -> 2") && strings.contains(rd.stdout, "+ .c: true"), rd.stdout)
	}
	{
		rset := invoke({"diff", "--set", a_p, b_p}); defer run_out_destroy(&rset); testing.expect_value(t, rset.code, 1)
		testing.expect(t, !strings.contains(rset.stdout, ".b["), rset.stdout)
	}
	{
		rp := invoke({"diff", "--patch", a_p, b_p}); defer run_out_destroy(&rp); testing.expect_value(t, rp.code, 1)
		testing.expect(t, strings.contains(rp.stdout, `"op": "replace"`) && strings.contains(rp.stdout, `"/a"`), rp.stdout)
	}
	{
		rsh := invoke({"diff", "--shape", a_p, b_p}); defer run_out_destroy(&rsh); testing.expect_value(t, rsh.code, 1)
		testing.expect(t, strings.contains(rsh.stdout, "backward:"), rsh.stdout)
	}
	{
		rsc := invoke({"diff", "--schema", "--compat", "backward", s1_p, s2_p}); defer run_out_destroy(&rsc)
		testing.expect_value(t, rsc.code, 1)
		rsc2 := invoke({"diff", "--old-schema", s1_p, "--new-schema", s3_p, "--compat", "backward"}); defer run_out_destroy(&rsc2)
		testing.expect_value(t, rsc2.code, 0)
	}
	{
		extra_p := write_tmp_file(t, dir, "extra.json", transmute([]u8)string(`{"a":5,"extra":1}`)); defer delete(extra_p)
		rdrift := invoke({"diff", "--old-schema", s1_p, extra_p}); defer run_out_destroy(&rdrift)
		testing.expect_value(t, rdrift.code, 1)
		testing.expect(t, strings.contains(rdrift.stdout, ".extra  not described by schema"), rdrift.stdout)
	}
	{
		rj := invoke({"diff", "--json", a_p, b_p}); defer run_out_destroy(&rj); testing.expect_value(t, rj.code, 1)
		testing.expect(t, strings.contains(rj.stdout, `"op":"changed"`), rj.stdout)
		k1 := write_tmp_file(t, dir, "k1.json", transmute([]u8)string(`[{"id":1,"v":"a"},{"id":2,"v":"b"}]`)); defer delete(k1)
		k2 := write_tmp_file(t, dir, "k2.json", transmute([]u8)string(`[{"id":2,"v":"b"},{"id":1,"v":"c"}]`)); defer delete(k2)
		rk := invoke({"diff", "--key", "id", k1, k2}); defer run_out_destroy(&rk); testing.expect_value(t, rk.code, 1)
		testing.expect(t, strings.contains(rk.stdout, ".v: \"a\" -> \"c\"") || strings.contains(rk.stdout, "\"a\" -> \"c\""), rk.stdout)
		f1 := write_tmp_file(t, dir, "f1.jsonc", transmute([]u8)string("/* old */\n{\"a\":1}\n")); defer delete(f1)
		f2 := write_tmp_file(t, dir, "f2.jsonc", transmute([]u8)string("/* new */\n{\"a\":1}\n")); defer delete(f2)
		rf := invoke({"diff", "--facts", f1, f2}); defer run_out_destroy(&rf); testing.expect_value(t, rf.code, 1)
		testing.expect(t, strings.contains(rf.stdout, "old") && strings.contains(rf.stdout, "new"), rf.stdout)
	}
}

@(test)
schema_infer_sample_and_odin :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	d_p := write_tmp_file(t, dir, "rows.ndjson", transmute([]u8)string("{\"id\":1,\"ok\":true}\n{\"id\":5,\"ok\":false}\n")); defer delete(d_p)
	rinf := invoke({"schema", "infer", "--ranges", d_p}); defer run_out_destroy(&rinf)
	testing.expect_value(t, rinf.code, 0)
	testing.expect(t, strings.contains(rinf.stdout, `"minimum": 1`) && strings.contains(rinf.stdout, `"maximum": 5`), rinf.stdout)

	sch_p := write_tmp_file(t, dir, "user.json", transmute([]u8)string(`{"type":"object","required":["id"],"properties":{"id":{"type":"integer","minimum":1,"maximum":9}}}`)); defer delete(sch_p)
	rsmp := invoke({"schema", "sample", "--count", "2", "--seed", "7", sch_p}); defer run_out_destroy(&rsmp)
	testing.expect_value(t, rsmp.code, 0)
	testing.expect(t, strings.contains(rsmp.stdout, `"id":`), rsmp.stdout)

	rodin := invoke({"schema", "odin", "--package", "users", "--format-assert", sch_p}); defer run_out_destroy(&rodin)
	testing.expect_value(t, rodin.code, 0)
	testing.expect(t, strings.contains(rodin.stdout, "package users") && strings.contains(rodin.stdout, "id: i64"), rodin.stdout)

	rchk := invoke_str({"schema", "check", "--schema", sch_p}, `{"id":3}`); defer run_out_destroy(&rchk)
	testing.expect_value(t, rchk.code, 0)
	rchk_bad := invoke_str({"schema", "check", "--schema", sch_p}, `{"id":99}`); defer run_out_destroy(&rchk_bad)
	testing.expect_value(t, rchk_bad.code, 1)
	rdiff := invoke({"schema", "diff", sch_p, sch_p}); defer run_out_destroy(&rdiff)
	testing.expect_value(t, rdiff.code, 0)
}

@(test)
in_place_symlink_refused_and_target_untouched :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	orig := `{"a":1,"b":2}`
	target_p := write_tmp_file(t, dir, "target.json", transmute([]u8)orig); defer delete(target_p)
	link_p := join_path(t, dir, "link.json"); defer delete(link_p)
	if os.symlink(target_p, link_p) != nil {
		return
	}

	rf := invoke({"fmt", "-i", link_p}); defer run_out_destroy(&rf)
	testing.expect_value(t, rf.code, 2)
	testing.expect(t, strings.contains(rf.stderr, "not a regular file"), rf.stderr)

	re := invoke({"edit", "-i", ".a = 9", link_p}); defer run_out_destroy(&re)
	testing.expect_value(t, re.code, 2)

	li, lerr := os.lstat(link_p, context.allocator)
	testing.expect(t, lerr == nil, "symlink still exists")
	if lerr == nil {
		testing.expect_value(t, li.type, os.File_Type.Symlink)
		os.file_info_delete(li, context.allocator)
	}
	saved, rerr := os.read_entire_file_from_path(target_p, context.allocator)
	testing.expect(t, rerr == nil, "target intact")
	defer delete(saved)
	testing.expect_value(t, string(saved), orig)
}

@(test)
fmt_edit_diff_and_schema_ref_audit_fixes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	// No double trailing newline when `fmt` converts to XML or TOML.
	{
		rx := invoke_str({"fmt", "--from", "toml", "--to", "xml"}, "[root]\nmsg = \"ok\"\n"); defer run_out_destroy(&rx)
		testing.expect_value(t, rx.code, 0)
		testing.expect(t, !strings.has_suffix(rx.stdout, "\n\n"), rx.stdout)
		rt := invoke_str({"fmt", "--from", "json", "--to", "toml"}, `{"x":{"y":1}}`); defer run_out_destroy(&rt)
		testing.expect_value(t, rt.code, 0)
		testing.expect(t, !strings.has_suffix(rt.stdout, "\n\n"), rt.stdout)
	}
	// `edit` handles record-dropping and multi-output filters cleanly on NDJSON.
	{
		rf := invoke_str({"edit", "--from", "ndjson", "select(.a > 1) | .a += 10"}, "{\"a\":1}\n{\"a\":2}\n"); defer run_out_destroy(&rf)
		testing.expect_value(t, rf.code, 0)
		testing.expect_value(t, rf.stdout, "{\"a\":12}\n")
		rm := invoke_str({"edit", "--from", "ndjson", ".a += 1, .a += 2"}, "{\"a\":1}\n"); defer run_out_destroy(&rm)
		testing.expect_value(t, rm.code, 0)
		testing.expect_value(t, rm.stdout, "{\"a\":2}\n{\"a\":3}\n")
	}
	// `diff --json --facts` produces valid JSON; unused `--key` exits 2; `--from ndjson` compares records.
	{
		f1 := write_tmp_file(t, dir, "f1.jsonc", transmute([]u8)string("/* old \"quote\" */\n{\"a\":1}\n")); defer delete(f1)
		f2 := write_tmp_file(t, dir, "f2.jsonc", transmute([]u8)string("/* new */\n{\"a\":1}\n")); defer delete(f2)
		rjf := invoke({"diff", "--json", "--facts", f1, f2}); defer run_out_destroy(&rjf)
		testing.expect_value(t, rjf.code, 1)
		lines := strings.split_lines(strings.trim_right(rjf.stdout, "\r\n"), context.allocator)
		defer delete(lines)
		testing.expect(t, len(lines) > 0, rjf.stdout)
		for ln in lines {
			testing.expect(t, engine.validate(transmute([]u8)ln, engine.spec_of_id(.Json), {}) == nil, ln)
		}

		k1 := write_tmp_file(t, dir, "k1.json", transmute([]u8)string(`[{"id":1},{"id":2}]`)); defer delete(k1)
		k2 := write_tmp_file(t, dir, "k2.json", transmute([]u8)string(`[{"id":1},{"id":3}]`)); defer delete(k2)
		ru := invoke({"diff", "--key", "items=id", k1, k2}); defer run_out_destroy(&ru)
		testing.expect_value(t, ru.code, 2)

		n1 := write_tmp_file(t, dir, "n1.ndjson", transmute([]u8)string("{\"a\":1}\n{\"a\":2}\n")); defer delete(n1)
		n2 := write_tmp_file(t, dir, "n2.ndjson", transmute([]u8)string("{\"a\":1}\n{\"a\":3}\n")); defer delete(n2)
		rnd_diff := invoke({"diff", "--from", "ndjson", n1, n2}); defer run_out_destroy(&rnd_diff)
		testing.expect_value(t, rnd_diff.code, 1)
		rnd_same := invoke({"diff", "--from", "ndjson", n1, n1}); defer run_out_destroy(&rnd_same)
		testing.expect_value(t, rnd_same.code, 0)
	}
	// Sibling-prefix directory traversal in `--schema-ref` (`dir/sub` vs `dir/sub_extra`) must be refused.
	{
		sub := join_path(t, dir, "sub"); defer delete(sub)
		sib := join_path(t, dir, "sub_extra"); defer delete(sib)
		testing.expect(t, os.make_directory(sub) == nil, "mkdir sub")
		testing.expect(t, os.make_directory(sib) == nil, "mkdir sib")
		sec := write_tmp_file(t, sib, "secret.json", transmute([]u8)string(`{"type":"integer"}`)); defer delete(sec)
		top := write_tmp_file(t, sub, "top.json", transmute([]u8)string(`{"properties":{"x":{"$ref":"../sub_extra/secret.json"}}}`)); defer delete(top)
		resc := invoke_str({"check", "--schema", top, "--schema-ref", sub}, `{"x":1}`); defer run_out_destroy(&resc)
		testing.expect_value(t, resc.code, 2)
		testing.expect(t, strings.contains(resc.stderr, "Schema is refused") || strings.contains(resc.stderr, "schema"), resc.stderr)
	}
}

@(test)
reaudit_verbs_comments_diff_edit_fixes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dir := make_tmp_dir(t); defer drop_tmp_dir(dir)

	// `--comments` rejected on JSON schema sample (exit 2) and non-sample verbs (exit 2), accepted on `--to jsonc`.
	{
		sch := write_tmp_file(t, dir, "sc.json", transmute([]u8)string(`{"description":"count","const":4}`)); defer delete(sch)
		rj := invoke({"schema", "sample", "--comments", sch}); defer run_out_destroy(&rj)
		testing.expect_value(t, rj.code, 2)
		testing.expect(t, strings.contains(rj.stderr, "holds no comment"), rj.stderr)

		rjc := invoke({"schema", "sample", "--to", "jsonc", "--comments", sch}); defer run_out_destroy(&rjc)
		testing.expect_value(t, rjc.code, 0)
		testing.expect_value(t, rjc.stdout, "4\n")

		rf := invoke_str({"fmt", "--comments"}, `{}`); defer run_out_destroy(&rf)
		testing.expect_value(t, rf.code, 2)
	}

	// Missing input files in `schema infer`, `diff --shape`, and `diff --schema` exit `2` (usage/open), not `5`.
	{
		missing := join_path(t, dir, "does_not_exist.json"); defer delete(missing)
		real_f := write_tmp_file(t, dir, "real.json", transmute([]u8)string(`{"x":1}`)); defer delete(real_f)
		sch := write_tmp_file(t, dir, "s.json", transmute([]u8)string(`{"type":"object"}`)); defer delete(sch)

		ri := invoke({"schema", "infer", missing}); defer run_out_destroy(&ri)
		testing.expect_value(t, ri.code, 2)

		rsh := invoke({"diff", "--shape", real_f, missing}); defer run_out_destroy(&rsh)
		testing.expect_value(t, rsh.code, 2)

		rds := invoke({"diff", "--schema", sch, missing}); defer run_out_destroy(&rds)
		testing.expect_value(t, rds.code, 2)
	}

	// `edit --diff --from ndjson` builds framed diff documents cleanly, and preserves leading text before dropped record 0.
	{
		red := invoke_str({"edit", "--diff", "--from", "ndjson", ".a += 10"}, "{\"a\":1}\n{\"a\":2}\n"); defer run_out_destroy(&red)
		testing.expect_value(t, red.code, 0)
		testing.expect(t, strings.contains(red.stdout, "[0].a: 1 -> 11") && strings.contains(red.stdout, "[1].a: 2 -> 12"), red.stdout)

		rlead := invoke_str({"edit", "--from", "ndjson", "select(.a > 1)"}, "\n\n{\"a\":1}\n{\"a\":2}\n"); defer run_out_destroy(&rlead)
		testing.expect_value(t, rlead.code, 0)
		testing.expect_value(t, rlead.stdout, "\n\n{\"a\":2}\n")
	}
}
