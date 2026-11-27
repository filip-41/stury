package yaml_tests

import "core:fmt"
import "core:math"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:testkit"
import "stury:yaml"

@(private = "file")
expect_scalar :: proc(t: ^testing.T, src: string, dialect: yaml.Yaml_Dialect, want_kind: yaml.Kind, want_text := "") {
	opts := yaml.Options{format = yaml.Yaml_Options{dialect = dialect}}
	doc, err := yaml.build(transmute([]u8)src, .Yaml_1_2, opts)
	defer yaml.destroy(&doc)
	if !testing.expectf(t, err == nil, "%v %q: unexpected error %v", dialect, src, err) {
		return
	}
	val, pres := yaml.member({&doc, nil}, yaml.ROOT, "v")
	if !testing.expectf(t, pres == .Found, "%v %q: member v missing", dialect, src) {
		return
	}
	got_kind := doc.nodes[val].kind
	testing.expectf(t, got_kind == want_kind, "%v %q: got kind %v, want %v", dialect, src, got_kind, want_kind)
	if want_kind == .String {
		buf: [128]u8
		txt, ok := yaml.node_text(&doc, val, buf[:])
		testing.expectf(t, ok && txt == want_text, "%v %q: got text %q (ok=%v), want %q", dialect, src, txt, ok, want_text)
	}
}

@(test)
dialect_scalar_resolution_core_json_failsafe :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	Case :: struct {
		yaml_val: string,
		core:     yaml.Kind,
		json:     yaml.Kind,
		failsafe: yaml.Kind,
		text:     string,
	}
	cases := [?]Case {
		// Null forms
		{"null", .Null, .Null, .String, "null"},
		{"Null", .Null, .String, .String, "Null"},
		{"NULL", .Null, .String, .String, "NULL"},
		{"~", .Null, .String, .String, "~"},
		{"", .Null, .String, .String, ""},
		// Boolean forms
		{"true", .True, .True, .String, "true"},
		{"True", .True, .String, .String, "True"},
		{"TRUE", .True, .String, .String, "TRUE"},
		{"false", .False, .False, .String, "false"},
		{"False", .False, .String, .String, "False"},
		{"FALSE", .False, .String, .String, "FALSE"},
		// Strict RFC 8259 JSON numbers
		{"0", .Number, .Number, .String, "0"},
		{"-0", .Number, .Number, .String, "-0"},
		{"42", .Number, .Number, .String, "42"},
		{"-42", .Number, .Number, .String, "-42"},
		{"0.5", .Number, .Number, .String, "0.5"},
		{"-12.34", .Number, .Number, .String, "-12.34"},
		{"1e5", .Number, .Number, .String, "1e5"},
		{"1E+5", .Number, .Number, .String, "1E+5"},
		{"1e-5", .Number, .Number, .String, "1e-5"},
		{"0.0e0", .Number, .Number, .String, "0.0e0"},
		// Non-JSON YAML 1.2 Core numbers -> .String under .Json and .Failsafe
		{"+1", .Number, .String, .String, "+1"},
		{"+0", .Number, .String, .String, "+0"},
		{"00", .Number, .String, .String, "00"},
		{"01", .Number, .String, .String, "01"},
		{"-01", .Number, .String, .String, "-01"},
		{"01.5", .Number, .String, .String, "01.5"},
		{".5", .Number, .String, .String, ".5"},
		{"-.5", .Number, .String, .String, "-.5"},
		{"+.5", .Number, .String, .String, "+.5"},
		{"5.", .Number, .String, .String, "5."},
		{"1.e5", .Number, .String, .String, "1.e5"},
		{"0x10", .Number, .String, .String, "0x10"},
		{"0o10", .Number, .String, .String, "0o10"},
		{".inf", .Number, .String, .String, ".inf"},
		{"+.inf", .Number, .String, .String, "+.inf"},
		{"-.inf", .Number, .String, .String, "-.inf"},
		{".Inf", .Number, .String, .String, ".Inf"},
		{".INF", .Number, .String, .String, ".INF"},
		{".nan", .Number, .String, .String, ".nan"},
		{".NaN", .Number, .String, .String, ".NaN"},
		{".NAN", .Number, .String, .String, ".NAN"},
		// Plain strings & quoted/block scalars stay .String in all dialects
		{"hello", .String, .String, .String, "hello"},
		{"yes", .String, .String, .String, "yes"},
		{"no", .String, .String, .String, "no"},
		{`"null"`, .String, .String, .String, "null"},
		{`'true'`, .String, .String, .String, "true"},
		{`"123"`, .String, .String, .String, "123"},
		{`""`, .String, .String, .String, ""},
	}
	for c in cases {
		line := fmt.tprintf("v: %s\n", c.yaml_val) if len(c.yaml_val) > 0 else "v:\n"
		// Default (opts.format == nil) MUST equal explicit .Core.
		doc_def, err_def := yaml.build(transmute([]u8)line)
		defer yaml.destroy(&doc_def)
		testing.expectf(t, err_def == nil, "default %q: %v", line, err_def)
		v_def, _ := yaml.member({&doc_def, nil}, yaml.ROOT, "v")
		testing.expect_value(t, doc_def.nodes[v_def].kind, c.core)

		expect_scalar(t, line, .Core, c.core, c.text)
		expect_scalar(t, line, .Json, c.json, c.text)
		expect_scalar(t, line, .Failsafe, c.failsafe, c.text)
	}

	// Multi-line folded plain scalars (SPELLING_DECODE != 0 path through `resolve_emitted_scalar`).
	ml_null := "v:\n  null\n"
	expect_scalar(t, ml_null, .Core, .Null)
	expect_scalar(t, ml_null, .Json, .Null)
	expect_scalar(t, ml_null, .Failsafe, .String, "null")

	ml_tilde := "v:\n  ~\n"
	expect_scalar(t, ml_tilde, .Core, .Null)
	expect_scalar(t, ml_tilde, .Json, .String, "~")
	expect_scalar(t, ml_tilde, .Failsafe, .String, "~")

	ml_hex := "v:\n  0x10\n"
	expect_scalar(t, ml_hex, .Core, .Number)
	expect_scalar(t, ml_hex, .Json, .String, "0x10")
	expect_scalar(t, ml_hex, .Failsafe, .String, "0x10")

	ml_num := "v:\n  -42\n"
	expect_scalar(t, ml_num, .Core, .Number)
	expect_scalar(t, ml_num, .Json, .Number)
	expect_scalar(t, ml_num, .Failsafe, .String, "-42")

	// Verify numeric values parsed under `.Json`.
	jdoc, jerr := yaml.build(transmute([]u8)string("i: -42\nf: 1.5e2\n"), .Yaml_1_2, {format = yaml.Yaml_Options{.Json}})
	defer yaml.destroy(&jdoc)
	testing.expect_value(t, jerr, nil)
	i_idx, _ := yaml.member({&jdoc, nil}, yaml.ROOT, "i")
	f_idx, _ := yaml.member({&jdoc, nil}, yaml.ROOT, "f")
	inum, iok := yaml.node_number(&jdoc, i_idx)
	fn, fok := yaml.node_number(&jdoc, f_idx)
	testing.expect(t, iok && inum == yaml.Number{transmute(u64)i64(-42), .Int})
	testing.expect(t, fok && fn.kind == .Float && transmute(f64)fn.bits == 150.0)
}

@(test)
dialect_explicit_tags_validation_and_resolution :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	Tag_Case :: struct {
		src:          string,
		core_ok:      bool,
		core_kind:    yaml.Kind,
		json_ok:      bool,
		json_kind:    yaml.Kind,
		failsafe_ok:  bool,
		failsafe_txt: string,
	}
	cases := [?]Tag_Case {
		{"v: !!str 123\n", true, .String, true, .String, true, "123"},
		{"v: !!str null\n", true, .String, true, .String, true, "null"},
		{"v: !!null null\n", true, .Null, true, .Null, true, "null"},
		{"v: !!null ~\n", true, .Null, false, .Null, true, "~"},
		{"v: !!null Null\n", true, .Null, false, .Null, true, "Null"},
		{"v: !!null \"\"\n", true, .Null, false, .Null, true, ""},
		{"v: !!bool true\n", true, .True, true, .True, true, "true"},
		{"v: !!bool false\n", true, .False, true, .False, true, "false"},
		{"v: !!bool True\n", true, .True, false, .True, true, "True"},
		{"v: !!bool FALSE\n", true, .False, false, .False, true, "FALSE"},
		{"v: !!int 42\n", true, .Number, true, .Number, true, "42"},
		{"v: !!int -42\n", true, .Number, true, .Number, true, "-42"},
		{"v: !!int \"42\"\n", true, .Number, true, .Number, true, "42"},
		{"v: !!int +1\n", true, .Number, false, .Number, true, "+1"},
		{"v: !!int 01\n", true, .Number, false, .Number, true, "01"},
		{"v: !!int 0x10\n", true, .Number, false, .Number, true, "0x10"},
		{"v: !!int 0o10\n", true, .Number, false, .Number, true, "0o10"},
		{"v: !!int 1.0\n", false, .Number, false, .Number, true, "1.0"},
		{"v: !!int abc\n", false, .Number, false, .Number, true, "abc"},
		{"v: !!float 42\n", true, .Number, true, .Number, true, "42"},
		{"v: !!float 1.5\n", true, .Number, true, .Number, true, "1.5"},
		{"v: !!float \"1e5\"\n", true, .Number, true, .Number, true, "1e5"},
		{"v: !!float .inf\n", true, .Number, false, .Number, true, ".inf"},
		{"v: !!float -.inf\n", true, .Number, false, .Number, true, "-.inf"},
		{"v: !!float .nan\n", true, .Number, false, .Number, true, ".nan"},
		{"v: !!float .5\n", true, .Number, false, .Number, true, ".5"},
		{"v: !!float 5.\n", true, .Number, false, .Number, true, "5."},
		{"v: !!float +1\n", true, .Number, false, .Number, true, "+1"},
		{"v: !!float 01\n", true, .Number, false, .Number, true, "01"},
		{"v: !!binary YWJj\n", true, .Bytes, true, .Bytes, true, "YWJj"},
		{"v: !!binary not*base64!\n", false, .Bytes, false, .Bytes, true, "not*base64!"},
		{"v: !custom 123\n", true, .String, true, .String, true, "123"},
		{"%TAG !e! tag:example.com,2000:\n---\nv: !e!x true\n", true, .String, true, .String, true, "true"},
	}

	for c in cases {
		src := transmute([]u8)c.src
		for d in yaml.Yaml_Dialect {
			want_ok: bool
			want_kind: yaml.Kind
			switch d {
			case .Core:
				want_ok, want_kind = c.core_ok, c.core_kind
			case .Json:
				want_ok, want_kind = c.json_ok, c.json_kind
			case .Failsafe:
				want_ok, want_kind = c.failsafe_ok, .String
			}
			opts := yaml.Options{format = yaml.Yaml_Options{dialect = d}}
			verr := yaml.validate(src, .Yaml_1_2, opts)
			doc, berr := yaml.build(src, .Yaml_1_2, opts)
			defer yaml.destroy(&doc)
			ans, ferr := yaml.find(src, {yaml.Name("v")}, .Yaml_1_2, {}, opts)
			dem, _ := yaml.demand_of({{yaml.Name("v")}})
			defer yaml.destroy(&dem)
			sdoc, serr := yaml.scan(src, &dem, .Yaml_1_2, {}, opts)
			defer yaml.destroy(&sdoc)

			if want_ok {
				testing.expectf(t, verr == nil && berr == nil && ferr == nil && serr == nil, "%v %q: errs=%v,%v,%v,%v", d, c.src, verr, berr, ferr, serr)
				if berr == nil {
					v, pres := yaml.member({&doc, nil}, yaml.ROOT, "v")
					testing.expectf(t, pres == .Found && doc.nodes[v].kind == want_kind, "%v %q: kind=%v want %v", d, c.src, doc.nodes[v].kind, want_kind)
					testing.expectf(t, ans.outcome == .Found && ans.kind == want_kind, "%v %q: find kind=%v want %v", d, c.src, ans.kind, want_kind)
					if d == .Failsafe {
						buf: [64]u8
						txt, ok := yaml.node_text(&doc, v, buf[:])
						testing.expectf(t, ok && txt == c.failsafe_txt, "%v %q: txt=%q want %q", d, c.src, txt, c.failsafe_txt)
						// Tag fact must still be preserved on the node under `.Failsafe`.
						has_tag := false
						for f in tape.facts_of(&doc, v) {
							if f.kind == .Tag {
								has_tag = true
							}
						}
						testing.expectf(t, has_tag, "%v %q: missing .Tag fact", d, c.src)
					}
				}
			} else {
				testing.expectf(t, faults_with(verr, .Tag_Mismatch), "%v %q: validate=%v want Tag_Mismatch", d, c.src, verr)
				testing.expectf(t, faults_with(berr, .Tag_Mismatch), "%v %q: build=%v want Tag_Mismatch", d, c.src, berr)
				testing.expectf(t, faults_with(ferr, .Tag_Mismatch), "%v %q: find=%v want Tag_Mismatch", d, c.src, ferr)
				testing.expectf(t, faults_with(serr, .Tag_Mismatch), "%v %q: scan=%v want Tag_Mismatch", d, c.src, serr)
			}
		}
	}

	// Verify `!!float 42` forces float under `.Json` just like `.Core`.
	fdoc, ferr := yaml.build(transmute([]u8)string("v: !!float 42\n"), .Yaml_1_2, {format = yaml.Yaml_Options{.Json}})
	defer yaml.destroy(&fdoc)
	testing.expect_value(t, ferr, nil)
	fv, _ := yaml.member({&fdoc, nil}, yaml.ROOT, "v")
	num, nok := yaml.node_number(&fdoc, fv)
	testing.expect(t, nok && num.kind == .Float && transmute(f64)num.bits == 42.0)
}

@(test)
dialect_key_equality_duplicates_and_merge :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	Dup_Case :: struct {
		src:      string,
		core:     bool, // true = collides under `.Refuse`
		json:     bool,
		failsafe: bool,
	}
	cases := [?]Dup_Case {
		{"1: a\n\"1\": b\n", false, false, true},
		{"null: a\n\"null\": b\n", false, false, true},
		{"null: a\n~: b\n", true, false, false},
		{"~: a\n\"~\": b\n", false, true, true},
		{"0x10: a\n16: b\n", true, false, false},
		{"0x10: a\n\"0x10\": b\n", false, true, true},
		{"True: a\ntrue: b\n", true, false, false},
		{"True: a\n\"True\": b\n", false, true, true},
		{": a\n\"\": b\n", false, true, true},
		{"1: a\n1.0: b\n", false, false, false},
		{"1: a\n!!int \"1\": b\n", true, true, true},
	}

	for c in cases {
		src := transmute([]u8)c.src
		for d in yaml.Yaml_Dialect {
			want_dup := c.core if d == .Core else (c.json if d == .Json else c.failsafe)
			opts := yaml.Options{dups = .Refuse, format = yaml.Yaml_Options{dialect = d}}
			doc, err := yaml.build(src, .Yaml_1_2, opts)
			defer yaml.destroy(&doc)
			if want_dup {
				f, ok := err.(yaml.Fault)
				testing.expectf(t, ok && f.kind == .Duplicate_Key, "%v %q: got %v, want Duplicate_Key", d, c.src, err)
			} else {
				testing.expectf(t, err == nil, "%v %q: got %v, want nil (distinct keys)", d, c.src, err)
				if err == nil {
					n, _, _ := yaml.length({&doc, nil}, yaml.ROOT, context.allocator)
					testing.expectf(t, n == 2, "%v %q: len=%d want 2", d, c.src, n)
				}
			}
		}
	}

	// Duplicate policies `.First` / `.Last` under `.Failsafe` where `1` and `"1"` collide.
	dup_src := transmute([]u8)string("1: first\n\"1\": second\n")
	fs_first, err1 := yaml.find(dup_src, {yaml.Name("1")}, .Yaml_1_2, {}, {dups = .First, format = yaml.Yaml_Options{.Failsafe}})
	fs_last, err2 := yaml.find(dup_src, {yaml.Name("1")}, .Yaml_1_2, {}, {dups = .Last, format = yaml.Yaml_Options{.Failsafe}})
	testing.expect(t, err1 == nil && fs_first.outcome == .Found && string(dup_src[fs_first.lo:fs_first.hi]) == "first")
	testing.expect(t, err2 == nil && fs_last.outcome == .Found && string(dup_src[fs_last.lo:fs_last.hi]) == "second")

	// `.Yaml_Merge` (`<<`) respects dialect key equality: under `.Failsafe`, host `"1"` shadows merged `1`;
	// under `.Core` and `.Json`, `"1"` (`.String`) and `1` (`.Number`) are distinct so both remain.
	merge_src := transmute([]u8)string("defs: &d\n  1: from_merge\n  ~: tilde_merge\nhost:\n  <<: *d\n  \"1\": from_host\n  \"~\": tilde_host\n")
	for d in yaml.Yaml_Dialect {
		doc, err := yaml.build(merge_src, .Yaml_Merge, {format = yaml.Yaml_Options{dialect = d}})
		defer yaml.destroy(&doc)
		testing.expectf(t, err == nil, "%v merge: %v", d, err)
		host, pres := yaml.member({&doc, nil}, yaml.ROOT, "host")
		testing.expect(t, pres == .Found)
		cnt, _, _ := yaml.length({&doc, nil}, host, context.allocator)
		want_cnt := 4 if d == .Core else (3 if d == .Json else 2)
		// Core: `1` (num), `~` (null), `"1"` (str), `"~"` (str) => 4
		// Json: `1` (num), `"1"` (str), `"~"` (shadows `~` since both str) => 3
		// Failsafe: `"1"` (shadows `1`), `"~"` (shadows `~`) => 2
		testing.expectf(t, cnt == want_cnt, "%v merge host len=%d want %d", d, cnt, want_cnt)
	}
}

@(test)
dialect_laws_pieces_and_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	texts := [?]string {
		"a: 1\nb: ~\nc: True\nd: 0x10\ne: null\nf:\n",
		"1: int_k\n\"1\": str_k\n0x10: hex_k\n~: tilde_k\n",
		"list:\n  - null\n  - ~\n  - true\n  - True\n  - 42\n  - 0x10\n  - .inf\n",
		"defs: &d {k: ~, n: 0o10}\nhost:\n  <<: *d\n  x: 1.5e2\n",
		"t: !!int 0x10\n",
		"t: !!null ~\n",
		"t: !!int abc\n",
	}
	paths := [][]yaml.Step {
		{},
		{yaml.Name("a")},
		{yaml.Name("b")},
		{yaml.Name("list"), yaml.Index(0)},
		{yaml.Name("list"), yaml.Index(-1)},
		{yaml.Name("host"), yaml.Name("k")},
		{yaml.Name("t")},
	}

	a: testkit.Agreement
	defer delete(a.shapes)

	for d in yaml.Yaml_Dialect {
		opts := yaml.Options{format = yaml.Yaml_Options{dialect = d}}
		for text in texts {
			src := transmute([]u8)text
			for spec in yaml.Spec {
				testkit.readers_agree(t, yaml.reads(spec), yaml.as(spec), src, opts, text, &a)
				if !testkit.agree_in_pieces(t, yaml.reads(spec), yaml.as(spec), src, opts, paths, text, containers = true) {
					return
				}
			}
		}

		// `.Concatenated`, `.Elements`, and `.Members` records all honor `Yaml_Options.dialect`.
		multi := transmute([]u8)string("v: ~\n---\nv: 0x10\n---\nv: 42\n")
		rc := yaml.records_open(multi, .Concatenated, .Yaml_1_2, opts)
		defer yaml.destroy(&rc)
		recs: [4]yaml.Record
		ans: [4]yaml.Span_Answer
		n := yaml.records_find(&rc, {yaml.Name("v")}, recs[:], ans[:])
		testing.expect_value(t, n, 3)
		want_k0 := yaml.Kind.Null if d == .Core else .String
		want_k1 := yaml.Kind.Number if d == .Core else .String
		want_k2 := yaml.Kind.String if d == .Failsafe else .Number
		testing.expectf(t, ans[0].kind == want_k0 && ans[1].kind == want_k1 && ans[2].kind == want_k2, "%v concat kinds: %v %v %v", d, ans[0].kind, ans[1].kind, ans[2].kind)

		// `.Elements` framing (`members_open` -> `build_as` MUST forward `opts.format`!)
		arr_src := transmute([]u8)string("[~, 0x10, 42]\n")
		re := yaml.records_open(arr_src, .Elements, .Yaml_1_2, opts)
		defer yaml.destroy(&re)
		ne := yaml.records_find(&re, nil, recs[:], ans[:])
		testing.expect_value(t, ne, 3)
		testing.expectf(t, ans[0].kind == want_k0 && ans[1].kind == want_k1 && ans[2].kind == want_k2, "%v elements kinds: %v %v %v", d, ans[0].kind, ans[1].kind, ans[2].kind)

		// `.Members` framing
		obj_src := transmute([]u8)string("a: ~\nb: 0x10\nc: 42\n")
		rm := yaml.records_open(obj_src, .Members, .Yaml_1_2, opts)
		defer yaml.destroy(&rm)
		nm := yaml.records_find(&rm, nil, recs[:], ans[:])
		testing.expect_value(t, nm, 3)
		testing.expectf(t, ans[0].kind == want_k0 && ans[1].kind == want_k1 && ans[2].kind == want_k2, "%v members kinds: %v %v %v", d, ans[0].kind, ans[1].kind, ans[2].kind)
	}
}

@(test)
dialect_check_unmarshal_write_marshal_and_edit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// 1. `yaml.check` honors `yaml_opts` and agrees with `check.check_document(yaml.build)`.
	d: rules.Description
	d.allocator = context.allocator
	defer rules.description_destroy(&d)
	str_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.String}, array = -1, object = -1})
	int_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Integer}, array = -1, object = -1})
	members := make([]rules.Member, 2)
	members[0] = {name = "code", node = str_n, required = true}
	members[1] = {name = "count", node = int_n, required = true}
	append(&d.objects, rules.Object{members = members, additional = str_n, keys = rules.NONE})
	root_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})
	d.root = root_n
	plan, cerr := check.compile(&d)
	testing.expect_value(t, cerr.kind, check.Error_Kind.None)
	defer check.plan_destroy(&plan)

	// `code: 0x10` is `.Number` in `.Core` (fails String), `.String` in `.Json` (passes!), and `count: 5` is `.String` in `.Failsafe` (fails Integer).
	chk_src := transmute([]u8)string("code: 0x10\ncount: 5\n")
	for dialect in yaml.Yaml_Dialect {
		r_s := yaml.check(chk_src, &plan, .Yaml_1_2, {}, nil, context.allocator, {dialect = dialect})
		defer check.result_destroy(&r_s)
		doc, berr := yaml.build(chk_src, .Yaml_1_2, {format = yaml.Yaml_Options{dialect = dialect}})
		defer yaml.destroy(&doc)
		testing.expect_value(t, berr, nil)
		r_d := check.check_document(&doc, &plan)
		defer check.result_destroy(&r_d)
		want_valid := dialect == .Json
		testing.expectf(t, r_s.valid == want_valid && r_d.valid == want_valid, "%v check: stream=%v doc=%v want=%v", dialect, r_s.valid, r_d.valid, want_valid)
	}

	// 2. `yaml.unmarshal` honors `Yaml_Options.dialect`.
	All_Strings :: struct {
		a, b, c, d: string,
	}
	raw_str := transmute([]u8)string("a: 123\nb: true\nc: ~\nd:\n")
	as_fs: All_Strings
	testing.expect_value(t, yaml.unmarshal(raw_str, &as_fs, .Yaml_1_2, {}, {format = yaml.Yaml_Options{.Failsafe}}, context.temp_allocator), nil)
	testing.expect(t, as_fs.a == "123" && as_fs.b == "true" && as_fs.c == "~" && as_fs.d == "")

	Json_Struct :: struct {
		n:     int,
		hex:   string,
		tilde: string,
		flag:  bool,
	}
	json_in := transmute([]u8)string("n: 42\nhex: 0x10\ntilde: ~\nflag: true\n")
	js: Json_Struct
	testing.expect_value(t, yaml.unmarshal(json_in, &js, .Yaml_1_2, {}, {format = yaml.Yaml_Options{.Json}}, context.temp_allocator), nil)
	testing.expect(t, js.n == 42 && js.hex == "0x10" && js.tilde == "~" && js.flag)

	// 3. `yaml.write` round-trips `.Failsafe` documents safely under default Core Schema AND honors explicit `Write_Options.format`.
	fs_src := transmute([]u8)string("123: true\n~: 0x10\nempty:\n")
	fs_doc, fs_err := yaml.build(fs_src, .Yaml_1_2, {format = yaml.Yaml_Options{.Failsafe}})
	defer yaml.destroy(&fs_doc)
	testing.expect_value(t, fs_err, nil)

	// Writing a `.Failsafe`-built doc under default Core Schema quotes Core-resolvable strings & keys so Core re-read stays `.String`!
	core_written, _, cw_err := yaml.write(&fs_doc, .Yaml_1_2, {indent = 2})
	defer delete(core_written)
	testing.expect_value(t, cw_err, nil)
	core_back, cb_err := yaml.build(core_written)
	defer yaml.destroy(&core_back)
	testing.expect_value(t, cb_err, nil)
	testing.expect(t, testkit.values_agree(t, &fs_doc, yaml.ROOT, &core_back, yaml.ROOT, {}, "failsafe -> core write round-trip"))

	// Writing a `.Failsafe`-built doc with `{format = Yaml_Options{.Failsafe}}` round-trips under `.Failsafe`.
	fs_written, _, fw_err := yaml.write(&fs_doc, .Yaml_1_2, {indent = 2, format = yaml.Yaml_Options{.Failsafe}})
	defer delete(fs_written)
	testing.expect_value(t, fw_err, nil)
	fs_back, fb_err := yaml.build(fs_written, .Yaml_1_2, {format = yaml.Yaml_Options{.Failsafe}})
	defer yaml.destroy(&fs_back)
	testing.expect_value(t, fb_err, nil)
	testing.expect(t, testkit.values_agree(t, &fs_doc, yaml.ROOT, &fs_back, yaml.ROOT, {}, "failsafe -> failsafe write round-trip"))

	// Writing a `.Core`-built doc with `{format = Yaml_Options{.Json}}` normalizes `~`/`True`/`0x10`/`.5`/empty-null to strict JSON scalars.
	core_src := transmute([]u8)string("a: ~\nb: True\nc: 0x10\nd: .5\ne:\n")
	core_doc, cd_err := yaml.build(core_src)
	defer yaml.destroy(&core_doc)
	testing.expect_value(t, cd_err, nil)

	json_written, _, jw_err := yaml.write(&core_doc, .Yaml_1_2, {indent = 2, format = yaml.Yaml_Options{.Json}})
	defer delete(json_written)
	testing.expect_value(t, jw_err, nil)
	json_back, jb_err := yaml.build(json_written, .Yaml_1_2, {format = yaml.Yaml_Options{.Json}})
	defer yaml.destroy(&json_back)
	testing.expect_value(t, jb_err, nil)
	testing.expect(t, testkit.values_agree(t, &core_doc, yaml.ROOT, &json_back, yaml.ROOT, {number_values = true}, "core -> json write round-trip"))

	// Writing non-string scalars under `.Failsafe` refuses `.No_Spelling`.
	_, _, fs_ref := yaml.write(&core_doc, .Yaml_1_2, {indent = 2, format = yaml.Yaml_Options{.Failsafe}})
	ref_fs, is_ref_fs := fs_ref.(yaml.Refused)
	testing.expect(t, is_ref_fs && ref_fs.why == .No_Spelling)

	// Writing `.inf`/`.nan` under `.Json` refuses `.No_Spelling` in both `write` and `marshal`.
	inf_doc, _ := yaml.build(transmute([]u8)string("x: .inf\n"))
	defer yaml.destroy(&inf_doc)
	_, _, inf_ref := yaml.write(&inf_doc, .Yaml_1_2, {indent = 2, format = yaml.Yaml_Options{.Json}})
	ref_inf, is_ref_inf := inf_ref.(yaml.Refused)
	testing.expect(t, is_ref_inf && ref_inf.why == .No_Spelling)

	Inf_Struct :: struct {
		x: f64,
	}
	inf_val := Inf_Struct{x = math.inf_f64(1)}
	_, m_inf_err := yaml.marshal(&inf_val, .Yaml_1_2, {indent = 2, format = yaml.Yaml_Options{.Json}})
	m_ref, is_m_ref := m_inf_err.(yaml.Refused)
	testing.expect(t, is_m_ref && m_ref.why == .No_Spelling)

	Num_Struct :: struct {
		n: int,
	}
	num_val := Num_Struct{n = 7}
	_, m_fs_err := yaml.marshal(&num_val, .Yaml_1_2, {indent = 2, format = yaml.Yaml_Options{.Failsafe}})
	m_fs_ref, is_m_fs_ref := m_fs_err.(yaml.Refused)
	testing.expect(t, is_m_fs_ref && m_fs_ref.why == .No_Spelling)

	// 4. `yaml.edit` (`commit`, `commit_document`, `walk_fragment`) honors `yaml_opts`.
	edit_fs_src := transmute([]u8)string("tag: !!int abc\nval: 123\n")
	ed_doc, ed_err := yaml.build(edit_fs_src, .Yaml_1_2, {format = yaml.Yaml_Options{.Failsafe}})
	defer yaml.destroy(&ed_doc)
	testing.expect_value(t, ed_err, nil)

	ov: yaml.Overlay
	testing.expect_value(t, yaml.edit_init(&ov, &ed_doc), nil)
	defer yaml.edit_destroy(&ov)
	_, serr_ed := edit.set_path(&ov, {yaml.Name("val")}, edit.val_raw("456"))
	testing.expect_value(t, serr_ed, nil)

	new_doc, cres, cerr_ed := yaml.commit_document(&ov, .Yaml_1_2, {}, context.allocator, {.Failsafe})
	defer yaml.destroy(&new_doc)
	defer edit.destroy_commit_result(&cres)
	testing.expect_value(t, cerr_ed, nil)
	new_v, _ := yaml.member({&new_doc, nil}, yaml.ROOT, "val")
	testing.expect_value(t, new_doc.nodes[new_v].kind, yaml.Kind.String)
	ebuf: [16]u8
	etxt, eok := yaml.node_text(&new_doc, new_v, ebuf[:])
	testing.expect(t, eok && etxt == "456")

	// Under `.Json`, setting raw `!!int 0x10` is refused by edit validation!
	jbase_src := transmute([]u8)string("n: 1\n")
	jbase, _ := yaml.build(jbase_src, .Yaml_1_2, {format = yaml.Yaml_Options{.Json}})
	defer yaml.destroy(&jbase)
	jov: yaml.Overlay
	testing.expect_value(t, yaml.edit_init(&jov, &jbase), nil)
	defer yaml.edit_destroy(&jov)
	_, jserr := edit.set_path(&jov, {yaml.Name("n")}, edit.val_raw("!!int 0x10"))
	testing.expect_value(t, jserr, nil)
	_, jcerr := yaml.commit(&jov, .Yaml_1_2, {}, context.allocator, {.Json})
	testing.expect(t, jcerr != nil)
}

@(test)
dialect_bad_format_options_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	src := transmute([]u8)string("a: 1\n")
	bad_opts := [?]tape.Format_Options {
		tape.Dsv_Options{},
		tape.Xml_Options{},
		yaml.Yaml_Options{dialect = yaml.Yaml_Dialect(99)},
	}
	want := yaml.Error(yaml.Bad_Option{"format"})

	dem, _ := yaml.demand_of({{yaml.Name("a")}})
	defer yaml.destroy(&dem)

	doc, _ := yaml.build(src)
	defer yaml.destroy(&doc)

	for fmt_opt in bad_opts {
		opts := yaml.Options{format = fmt_opt}
		testing.expect_value(t, yaml.validate(src, .Yaml_1_2, opts), want)
		_, berr := yaml.build(src, .Yaml_1_2, opts)
		testing.expect_value(t, berr, want)
		_, ferr := yaml.find(src, {yaml.Name("a")}, .Yaml_1_2, {}, opts)
		testing.expect_value(t, ferr, want)
		_, serr := yaml.scan(src, &dem, .Yaml_1_2, {}, opts)
		testing.expect_value(t, serr, want)

		nh: hook.No_Hooks
		regs: hook.Regs
		_, werr, _ := yaml.walk(src, .Yaml_1_2, opts, &nh, &regs, hook.no_hook)
		testing.expect_value(t, werr, want)
		_, wnerr, _ := yaml.walk_next(src, 0, .Yaml_1_2, opts, &nh, &regs, hook.no_hook)
		testing.expect_value(t, wnerr, want)

		r := yaml.records_open(src, .Concatenated, .Yaml_1_2, opts)
		testing.expect_value(t, r.err, want)
		yaml.destroy(&r)

		target: struct { a: int }
		testing.expect_value(t, yaml.unmarshal(src, &target, .Yaml_1_2, {}, opts), want)

		_, _, wr_err := yaml.write(&doc, .Yaml_1_2, {format = fmt_opt})
		testing.expect_value(t, wr_err, yaml.Write_Error(yaml.Bad_Option{"format"}))

		_, m_err := yaml.marshal(&target, .Yaml_1_2, {format = fmt_opt})
		testing.expect_value(t, m_err, yaml.Write_Error(yaml.Bad_Option{"format"}))

		tw: yaml.Writer
		testing.expect_value(t, yaml.writer_start(&tw, .Yaml_1_2, {format = fmt_opt}), yaml.Write_Error(yaml.Bad_Option{"format"}))
	}

	// Out-of-range `Yaml_Dialect` also refused by `check`, `commit`, and `commit_document`.
	d: rules.Description
	d.allocator = context.allocator
	defer rules.description_destroy(&d)
	append(&d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1})
	d.root = 0
	plan, _ := check.compile(&d)
	defer check.plan_destroy(&plan)
	cres := yaml.check(src, &plan, .Yaml_1_2, {}, nil, context.allocator, {dialect = yaml.Yaml_Dialect(99)})
	defer check.result_destroy(&cres)
	testing.expect(t, !cres.valid && cres.err.kind == .Bad_Option)

	ov: yaml.Overlay
	testing.expect_value(t, yaml.edit_init(&ov, &doc), nil)
	defer yaml.edit_destroy(&ov)
	_, c_err := yaml.commit(&ov, .Yaml_1_2, {}, context.allocator, {dialect = yaml.Yaml_Dialect(99)})
	testing.expect_value(t, c_err, yaml.Edit_Error(yaml.Bad_Option{"format"}))
	_, _, cd_err := yaml.commit_document(&ov, .Yaml_1_2, {}, context.allocator, {dialect = yaml.Yaml_Dialect(99)})
	testing.expect_value(t, cd_err, yaml.Edit_Error(yaml.Bad_Option{"format"}))
}

@(test)
dialect_audit_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// 1a. `edit.val_int` / `val_bool` / `val_null` under `.Failsafe` must refuse `.Unspellable_Value` in `spell_overlay_value` & reflow.
	fs_src := transmute([]u8)string("a: hello\n")
	fs_doc, fs_err := yaml.build(fs_src, .Yaml_1_2, {format = yaml.Yaml_Options{.Failsafe}})
	defer yaml.destroy(&fs_doc)
	testing.expect_value(t, fs_err, nil)

	for bad_v in ([?]edit.Edit_Value{edit.val_int(42), edit.val_bool(true), edit.val_null()}) {
		ov: yaml.Overlay
		testing.expect_value(t, yaml.edit_init(&ov, &fs_doc), nil)
		defer yaml.edit_destroy(&ov)
		_, serr := edit.set_path(&ov, {yaml.Name("a")}, bad_v)
		testing.expect_value(t, serr, nil)
		_, cerr := yaml.commit(&ov, .Yaml_1_2, {}, context.allocator, {.Failsafe})
		ref, is_ref := cerr.(edit.Refusal)
		testing.expectf(t, is_ref && ref.kind == .Unspellable_Value, "failsafe edit %v: got %v, want Unspellable_Value", bad_v.kind, cerr)
	}

	// 1b. `edit.val_float(+Inf)` / `NaN` under `.Json` must refuse `.Unspellable_Value`.
	js_src := transmute([]u8)string("x: 1.0\n")
	js_doc, js_err := yaml.build(js_src, .Yaml_1_2, {format = yaml.Yaml_Options{.Json}})
	defer yaml.destroy(&js_doc)
	testing.expect_value(t, js_err, nil)

	for bad_f in ([?]f64{math.inf_f64(1), math.nan_f64()}) {
		ov: yaml.Overlay
		testing.expect_value(t, yaml.edit_init(&ov, &js_doc), nil)
		defer yaml.edit_destroy(&ov)
		_, serr := edit.set_path(&ov, {yaml.Name("x")}, edit.val_float(bad_f))
		testing.expect_value(t, serr, nil)
		_, cerr := yaml.commit(&ov, .Yaml_1_2, {}, context.allocator, {.Json})
		ref, is_ref := cerr.(edit.Refusal)
		testing.expectf(t, is_ref && ref.kind == .Unspellable_Value, "json edit %v: got %v, want Unspellable_Value", bad_f, cerr)
	}

	// 2. Core-built `!!int "01"`, `!!int "+1"`, and `!!float ".5"` written under `.Json` normalize to valid JSON Schema numbers.
	quoted_core := transmute([]u8)string("a: !!int \"01\"\nb: !!int \"+1\"\nc: !!float \".5\"\n")
	qc_doc, qc_err := yaml.build(quoted_core)
	defer yaml.destroy(&qc_doc)
	testing.expect_value(t, qc_err, nil)

	qj_out, _, qj_werr := yaml.write(&qc_doc, .Yaml_1_2, {indent = 2, format = yaml.Yaml_Options{.Json}})
	defer delete(qj_out)
	testing.expect_value(t, qj_werr, nil)
	qj_back, qj_berr := yaml.build(qj_out, .Yaml_1_2, {format = yaml.Yaml_Options{.Json}})
	defer yaml.destroy(&qj_back)
	testing.expectf(t, qj_berr == nil, "Core -> Json re-read failed on %q: %v", string(qj_out), qj_berr)
	if qj_berr == nil {
		testing.expect(t, testkit.values_agree(t, &qc_doc, yaml.ROOT, &qj_back, yaml.ROOT, {number_values = true}, "quoted core -> json round-trip"))
	}

	// 3. `.Yaml_Merge` doc with `.Core`-invalid tag (`!!int abc`) before `<<:` under `.Failsafe` still detects `.Merged` in `edit`.
	merge_fs := transmute([]u8)string("bad: !!int abc\ndefs: &d\n  k: 1\nhost:\n  <<: *d\n  a: 2\n")
	mf_doc, mf_err := yaml.build(merge_fs, .Yaml_Merge, {format = yaml.Yaml_Options{.Failsafe}})
	defer yaml.destroy(&mf_doc)
	testing.expect_value(t, mf_err, nil)

	mov: yaml.Overlay
	testing.expect_value(t, yaml.edit_init(&mov, &mf_doc), nil)
	defer yaml.edit_destroy(&mov)
	_, mserr := edit.set_path(&mov, {yaml.Name("host"), yaml.Name("a")}, edit.val_string("3"))
	testing.expect_value(t, mserr, nil)
	_, mcerr := yaml.commit(&mov, .Yaml_Merge, {}, context.allocator, {.Failsafe})
	mref, is_mref := mcerr.(edit.Refusal)
	testing.expectf(t, is_mref && mref.group == .Alias_Unshare && mref.kind == .Alias_Edit_Requires_Reflow, "failsafe merge edit: got %v, want Alias_Edit_Requires_Reflow", mcerr)

	// 4. `.Plain` `.Number` key `1.1234: val` (whose `number_spelling` bits overlap `Style.Single` + `SPELLING_ASCII`)
	// must NEVER be emitted as `'1.1234': val` by `single_quoted_body`!
	nk_src := transmute([]u8)string("1.1234: val\n")
	for d in ([?]yaml.Yaml_Dialect{.Core, .Json}) {
		nk_doc, nk_err := yaml.build(nk_src, .Yaml_1_2, {format = yaml.Yaml_Options{dialect = d}})
		defer yaml.destroy(&nk_doc)
		testing.expect_value(t, nk_err, nil)

		nk_out, _, nk_werr := yaml.write(&nk_doc, .Yaml_1_2, {indent = 2, format = yaml.Yaml_Options{dialect = d}})
		defer delete(nk_out)
		testing.expect_value(t, nk_werr, nil)
		testing.expectf(t, string(nk_out) == "1.1234: val\n", "%v number key wrote %q, want \"1.1234: val\\n\"", d, string(nk_out))

		nk_back, nk_berr := yaml.build(nk_out, .Yaml_1_2, {format = yaml.Yaml_Options{dialect = d}})
		defer yaml.destroy(&nk_back)
		testing.expect_value(t, nk_berr, nil)
		testing.expect_value(t, nk_back.nodes[1].kind, yaml.Kind.Number)
	}
}
