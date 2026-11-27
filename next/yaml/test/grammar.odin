package yaml_tests

import "core:math"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:yaml"

@(test)
core_schema_types_and_scalars :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string("n: ~\nn2: null\nn3: NULL\nt: True\nf: FALSE\ni: -12\nx: 0x1F\no: 0o17\nd: 1.5e3\ninf: -.inf\npinf: +.Inf\nnan: .NaN\ns: yes\nq: \"1\"\nz: 1_000\nb: !!binary SGVsbG8=\n")
	doc, err := yaml.build(src)
	defer yaml.destroy(&doc)
	expect_nil(t, err)

	want := [?]struct {
		key:  string,
		kind: yaml.Kind,
	}{
		{"n", .Null}, {"n2", .Null}, {"n3", .Null},
		{"t", .True}, {"f", .False},
		{"i", .Number}, {"x", .Number}, {"o", .Number}, {"d", .Number}, {"inf", .Number}, {"pinf", .Number}, {"nan", .Number},
		{"s", .String}, {"q", .String}, {"z", .String},
		{"b", .Bytes},
	}
	r := yaml.Reader{&doc, nil}
	for w in want {
		idx, p := yaml.member(r, yaml.ROOT, w.key)
		testing.expectf(t, p == .Found && doc.nodes[idx].kind == w.kind, "%s: found=%v got=%v want=%v", w.key, p, doc.nodes[idx].kind, w.kind)
	}
	b_idx, _ := yaml.member(r, yaml.ROOT, "b")
	bbuf: [32]u8
	got_bin, bok := yaml.node_text(&doc, b_idx, bbuf[:])
	testing.expect(t, bok && got_bin == "Hello")
}

@(test)
number_values_and_canonical_digits :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	doc, err := yaml.build(transmute([]u8)string("a: 0x1F\nb: 0o17\nc: 007\nd: .5\ne: +3\nf: -0.25\ng: -.inf\nh: .nan\ni: 5.\nj: -0\nk: -00\nl: 0x1000000000000000000000000000000000000000\n"))
	defer yaml.destroy(&doc)
	expect_nil(t, err)
	r := yaml.Reader{&doc, nil}

	floats := [?]struct{ key: string, v: f64 }{{"a", 31}, {"b", 15}, {"c", 7}, {"d", 0.5}, {"e", 3}, {"f", -0.25}}
	for w in floats {
		idx, _ := yaml.member(r, yaml.ROOT, w.key)
		nv, ok := yaml.node_number(&doc, idx)
		f := f64(i64(nv.bits)) if nv.kind == .Int else transmute(f64)nv.bits
		testing.expectf(t, ok && f == w.v, "%s: %v", w.key, nv)
	}
	g_idx, _ := yaml.member(r, yaml.ROOT, "g")
	gn, _ := yaml.node_number(&doc, g_idx)
	testing.expect(t, gn.kind == .Float && math.is_inf(transmute(f64)gn.bits, -1))
	h_idx, _ := yaml.member(r, yaml.ROOT, "h")
	hn, _ := yaml.node_number(&doc, h_idx)
	testing.expect(t, hn.kind == .Float && math.is_nan(transmute(f64)hn.bits))

	l_idx, _ := yaml.member(r, yaml.ROOT, "l")
	lbuf: [80]u8
	ltxt, lok := yaml.node_text(&doc, l_idx, lbuf[:])
	testing.expectf(t, lok && ltxt == "0x1000000000000000000000000000000000000000", "hex raw got %q", ltxt)
	lcanon, lcok := yaml.as(.Yaml_1_2).decode(doc.src, doc.nodes[l_idx], lbuf[:], nil)
	testing.expectf(t, lcok && lcanon == "91343852333181432387730302044767688728495783936", "hex canonical got %q", lcanon)

	// Numeric keys decode to canonical decimal text via `node_text`.
	kdoc, kdoc_err := yaml.build(transmute([]u8)string("0x1000000000000000000000000000000000000000: 1\n"))
	defer yaml.destroy(&kdoc)
	expect_nil(t, kdoc_err)
	_, kp := yaml.member({&kdoc, nil}, yaml.ROOT, "91343852333181432387730302044767688728495783936")
	testing.expect_value(t, kp, yaml.Presence.Found)
}

@(test)
tags_directives_and_properties :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	doc, err := yaml.build(transmute([]u8)string("a: !!str 12\nb: !!int \"12\"\nc: !!float 3\nd: !local 5\ne: !!null null\nf: !<tag:yaml.org,2002:bool> 'true'\n"))
	defer yaml.destroy(&doc)
	expect_nil(t, err)
	r := yaml.Reader{&doc, nil}
	want := [?]struct{ key: string, kind: yaml.Kind }{{"a", .String}, {"b", .Number}, {"c", .Number}, {"d", .String}, {"e", .Null}, {"f", .True}}
	for w in want {
		idx, _ := yaml.member(r, yaml.ROOT, w.key)
		testing.expectf(t, doc.nodes[idx].kind == w.kind, "%s: %v", w.key, doc.nodes[idx].kind)
	}
	a_idx, _ := yaml.member(r, yaml.ROOT, "a")
	tag := ""
	for fct in tape.facts_of(&doc, a_idx) {
		if fct.kind == .Tag {
			tag = string(yaml.span_bytes(&doc, fct.lo, fct.n))
			break
		}
	}
	testing.expect(t, tag == "!!str")
	b_idx, _ := yaml.member(r, yaml.ROOT, "b")
	bn, _ := yaml.node_number(&doc, b_idx)
	testing.expect_value(t, bn, yaml.Number{12, .Int})

	for bad_tag in ([?]string{"a: !!bool yes\n", "a: !!int 1.5\n", "a: !!null 0\n", "- !!float \"x\"\n"}) {
		fault := yaml.validate(transmute([]u8)bad_tag)
		testing.expectf(t, faults_with(fault, .Tag_Mismatch), "%q: %v", bad_tag, fault)
	}

	tag_dir, derr := yaml.build(transmute([]u8)string("%TAG !! tag:example.com,2000:\n---\na: !!int x\n"))
	defer yaml.destroy(&tag_dir)
	expect_nil(t, derr)
	td_a, _ := yaml.member({&tag_dir, nil}, yaml.ROOT, "a")
	testing.expect_value(t, tag_dir.nodes[td_a].kind, yaml.Kind.String)

	key_val, kerr := yaml.build(transmute([]u8)string("!!str 1: !!int 47\n"))
	defer yaml.destroy(&key_val)
	expect_nil(t, kerr)
	kv_a, _ := yaml.member({&key_val, nil}, yaml.ROOT, "1")
	testing.expect_value(t, key_val.nodes[kv_a].kind, yaml.Kind.Number)
}

@(test)
scalar_quoting_folding_and_chomping :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	cases := [][2]string {
		{"plain  words", "plain  words"},
		{"'it''s'", "it's"},
		{"\"a\\tb\\u00e9\\n\"", "a\tb\u00e9\n"},
		{"\"a\\\n   b\"", "ab"},
		{"'a\n\n  b'", "a\nb"},
		{"|\n a\n  b\n", "a\n b\n"},
		{">\n a\n b\n\n c\n", "a b\nc\n"},
		{"|-\n a\n", "a"},
		{"|+\n a\n\n", "a\n\n"},
		{"|2\n   a\n", " a\n"},
	}
	for c in cases {
		doc, err := yaml.build(transmute([]u8)c[0])
		defer yaml.destroy(&doc)
		expect_nil(t, err)
		buf: [128]u8
		got, ok := yaml.node_text(&doc, yaml.ROOT, buf[:])
		testing.expectf(t, ok && got == c[1], "%q -> %q want %q", c[0], got, c[1])
	}
}

@(test)
comments_styles_and_walk_tokens :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	got, hi, fault := tokens_of("a: 1\nb:\n  - x\n  - 'y'\n")
	testing.expect_value(t, fault, nil)
	testing.expect_value(t, hi, u64(21))
	testing.expect_value(t, got, "Object Key:a Number:1 Key:b Array String:x String*:y End End")

	cg, _, cf := tokens_of("# top\n\na: 1 # one\n# above b\nb: 2\n")
	testing.expect_value(t, cf, nil)
	testing.expect_value(t, cg, "Comment:# top Object Key:a Number:1 Inline:# one Comment:# above b Key:b Number:2 End")

	doc, derr := yaml.build(transmute([]u8)string("a: x\nb: 'x'\nc: \"x\"\nd: |\n  x\ne: >\n  x\nf: [x]\ng: {y: z}\nh: 5\n"))
	defer yaml.destroy(&doc)
	expect_nil(t, derr)
	wants := [?]string{"plain", "single", "double", "literal", "folded", "flow", "flow", "plain"}
	for name, k in ([?]string{"a", "b", "c", "d", "e", "f", "g", "h"}) {
		idx, _ := yaml.member({&doc, nil}, yaml.ROOT, name)
		st, ok := yaml.fact_name(&doc, idx, .Style)
		testing.expectf(t, ok && st == wants[k], "%s: %q vs %q", name, st, wants[k])
	}
}

@(test)
aliases_expansion_budgets_and_merge_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Expansion / alias-bomb protection (`Budget.expansion`). Default cap is `default_expansion(len)` (>= 8 MiB).
	bomb := transmute([]u8)string("a: &a [xxxxxxxxxxxxxxxxxxxx, xxxxxxxxxxxxxxxxxxxx, xxxxxxxxxxxxxxxxxxxx, xxxxxxxxxxxxxxxxxxxx, xxxxxxxxxxxxxxxxxxxx, xxxxxxxxxxxxxxxxxxxx, xxxxxxxxxxxxxxxxxxxx, xxxxxxxxxxxxxxxxxxxx, xxxxxxxxxxxxxxxxxxxx, xxxxxxxxxxxxxxxxxxxx]\nb: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a, *a]\nc: &c [*b, *b, *b, *b, *b, *b, *b, *b, *b, *b]\nd: &d [*c, *c, *c, *c, *c, *c, *c, *c, *c, *c]\ne: &e [*d, *d, *d, *d, *d, *d, *d, *d, *d, *d]\nf: [*e, *e, *e, *e]\n")
	f, bad := yaml.validate(bomb).(yaml.Exceeded)
	testing.expect(t, bad && f.kind == .Expansion)
	testing.expect_value(t, yaml.validate(bomb, .Yaml_1_2, {budget = {expansion = 1 << 30}}), nil)

	// Exact alias replay within expansion budget, cycle refusal, undefined alias refusal.
	small := transmute([]u8)string("a: &a [1, 2, 3]\nb: *a\nc: *a\n")
	testing.expect_value(t, yaml.validate(small), nil)
	ex_err := yaml.validate(small, .Yaml_1_2, {budget = {expansion = 12}})
	ex_s, ok_ex := ex_err.(yaml.Exceeded)
	testing.expect(t, ok_ex && ex_s.kind == .Expansion)
	testing.expect_value(t, yaml.validate(small, .Yaml_1_2, {budget = {expansion = 24}}), nil)
	testing.expect(t, faults_with(yaml.validate(transmute([]u8)string("a: *a\n")), .Undefined_Alias))
	testing.expect(t, faults_with(yaml.validate(transmute([]u8)string("a: &a [*a]\n")), .Alias_Cycle))

	// Hash-index anchor lookup when count > 32.
	hb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 50 {
		strings.write_string(&hb, "- &a")
		strings.write_int(&hb, i)
		strings.write_string(&hb, " 1\n")
	}
	strings.write_string(&hb, "- &a3 7\n- *a3\n- *a0\n")
	hd, herr := yaml.build(transmute([]u8)strings.to_string(hb))
	defer yaml.destroy(&hd)
	expect_nil(t, herr)
	v_50, _ := yaml.element({&hd, nil}, yaml.ROOT, 51)
	testing.expect_value(t, hd.nodes[v_50].kind, yaml.Kind.Number)

	// Depth, nodes, steps, and memory budgets.
	testing.expect(t, yaml.validate(transmute([]u8)string("[[[[1]]]]"), .Yaml_1_2, {budget = {depth = 3}}) != nil)
	testing.expect_value(t, yaml.validate(transmute([]u8)string("[[[1]]]"), .Yaml_1_2, {budget = {depth = 3}}), nil)
	_, nodes_err := yaml.build(transmute([]u8)string("[1, 2, 3, 4]"), .Yaml_1_2, {budget = {nodes = 3}})
	testing.expect(t, nodes_err != nil)
	testing.expect(t, yaml.validate(transmute([]u8)string("a: [1, [2]]"), .Yaml_1_2, {budget = {steps = 2}}) != nil)
	testing.expect(t, yaml.validate(transmute([]u8)string("[[[[[1]]]]]"), .Yaml_1_2, {budget = {memory = 1}}) != nil)

	// Merge keys `<<` under `.Yaml_1_2` vs `.Yaml_Merge`.
	mtext := transmute([]u8)string("base: &b {a: 1, b: 2}\nmore: &m {b: 3, c: 4}\nhost:\n  <<: [*b, *m]\n  a: 0\nsingle: {<<: *m, d: 5}\nodd: {<<: 7}\n")
	plain, _ := yaml.build(mtext, .Yaml_1_2)
	defer yaml.destroy(&plain)
	phost, _ := yaml.member({&plain, nil}, yaml.ROOT, "host")
	_, pmerge := yaml.member({&plain, nil}, phost, "<<")
	testing.expect(t, pmerge == .Found)

	mdoc, merr := yaml.build(mtext, .Yaml_Merge)
	defer yaml.destroy(&mdoc)
	expect_nil(t, merr)
	mhost, _ := yaml.member({&mdoc, nil}, yaml.ROOT, "host")
	_, mmerge := yaml.member({&mdoc, nil}, mhost, "<<")
	testing.expect(t, mmerge != .Found)
	for w in ([?]struct{ key: string, val: i64 }{{"a", 0}, {"b", 2}, {"c", 4}}) {
		idx, ok := yaml.member({&mdoc, nil}, mhost, w.key)
		nv, _ := yaml.node_number(&mdoc, idx)
		testing.expectf(t, ok == .Found && nv == yaml.Number{u64(w.val), .Int}, "merge host.%s = %v", w.key, nv)
	}
	msingle, _ := yaml.member({&mdoc, nil}, yaml.ROOT, "single")
	for w in ([?]struct{ key: string, val: i64 }{{"b", 3}, {"c", 4}, {"d", 5}}) {
		idx, ok := yaml.member({&mdoc, nil}, msingle, w.key)
		nv, _ := yaml.node_number(&mdoc, idx)
		testing.expectf(t, ok == .Found && nv == yaml.Number{u64(w.val), .Int}, "merge single.%s = %v", w.key, nv)
	}
}

@(test)
collection_close_end_and_fault_details :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for c in ([][2]string {
		{"a: &b [2, 3]\nc: [1, *b]\n", "[1, *b]"},
		{"a: &b {k: 1}\nc:\n  y: 1\n  z: *b\nd: 2\n", "y: 1\n  z: *b"},
		{"a: &b 1\nc:\n- 1\n- *b # tail\n- *b\nd: 2\n", "- 1\n- *b # tail\n- *b"},
		{"c: [[&b 1, 2], *b]\n", "[[&b 1, 2], *b]"},
		{"a: &b 1\nc:\n  *b : *b\n", "*b : *b"},
	}) {
		doc, err := yaml.build(transmute([]u8)c[0])
		defer yaml.destroy(&doc)
		expect_nil(t, err)
		v, _ := yaml.member({&doc, nil}, yaml.ROOT, "c")
		lo := doc.nodes[v].lo
		hi, ok := yaml.as(.Yaml_1_2).close_end(&doc, v)
		testing.expectf(t, ok && string(doc.src[lo:hi]) == c[1], "%q -> %q want %q", c[0], string(doc.src[lo:hi]), c[1])
	}

	_, ckey_err := yaml.build(transmute([]u8)string("? [a]\n: b\n"))
	testing.expect(t, faults_with(ckey_err, .Complex_Key))
	_, ex_doc := yaml.build(transmute([]u8)string("a: 1\n---\nb: 2\n"))
	testing.expect(t, faults_with(ex_doc, .Extra_Document))
	_, no_doc := yaml.build(transmute([]u8)string("# comment only\n"))
	testing.expect(t, faults_with(no_doc, .No_Document))

	for trunc in ([]string{"{a", "[a", "{a:", "{a: ", "[a:", "[? ", "[&x", "[!t ", "{a: &x"}) {
		testing.expectf(t, faults_with(yaml.validate(transmute([]u8)trunc), .Open_Collection), "trunc %q", trunc)
	}
	for bad_u in ([]string{"\xff", "a: \"\\ud800\"\n", "a: \"x\n", "a: 'x\n", "%YAML 2.0\n---\na\n", "&a &b c\n", "!<x\n", "a:\n\t- 1\n"}) {
		testing.expectf(t, yaml.validate(transmute([]u8)bad_u) != nil, "invalid %q", bad_u)
	}
}

@(test)
merge_key_edge_cases_and_replay_regression :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Merge source ending with `.Comment_Foot` and member with `.Comment_Inline` (regression: no OOB in `merge_members`).
	foot_src := transmute([]u8)string("def: &d\n  a: 1 # inline a\n  b: 2\n  # foot inside def\nhost:\n  <<: *d\n  c: 3\n")
	fdoc, ferr := yaml.build(foot_src, .Yaml_Merge)
	defer yaml.destroy(&fdoc)
	expect_nil(t, ferr)
	host, hp := yaml.member({&fdoc, nil}, yaml.ROOT, "host")
	testing.expect_value(t, hp, yaml.Presence.Found)
	for name in ([?]string{"a", "b", "c"}) {
		_, mp := yaml.member({&fdoc, nil}, host, name)
		testing.expectf(t, mp == .Found, "missing merged %s", name)
	}

	// Anchored mapping containing `<<:` replayed via alias `*h`, plus nested `&inn` defined inside `<<:`, plus multiple `<<:`!
	replay_src := transmute([]u8)string("d1: &d1\n  a: 1\n  b: 2\n  # foot1\nd2: &d2\n  b: 20\n  c: 3\nhost: &h\n  <<: *d1\n  <<:\n    inner: &inn 99\n    c: 30\n  d: 4\ncopy: *h\nref: *inn\nmulti:\n  <<: *d1\n  <<: *d2\n  a: 0\n")
	rdoc, rerr := yaml.build(replay_src, .Yaml_Merge)
	defer yaml.destroy(&rdoc)
	expect_nil(t, rerr)
	rr := yaml.Reader{&rdoc, nil}
	copy_n, cp := yaml.member(rr, yaml.ROOT, "copy")
	testing.expect_value(t, cp, yaml.Presence.Found)
	_, has_raw_merge := yaml.member(rr, copy_n, "<<")
	testing.expect(t, has_raw_merge != .Found)
	for want in ([?]struct{ k: string, v: i64 }{{"a", 1}, {"b", 2}, {"inner", 99}, {"c", 30}, {"d", 4}}) {
		idx, mp := yaml.member(rr, copy_n, want.k)
		nv, _ := yaml.node_number(&rdoc, idx)
		testing.expectf(t, mp == .Found && nv == yaml.Number{u64(want.v), .Int}, "copy.%s = %v", want.k, nv)
	}
	ref_n, ref_p := yaml.member(rr, yaml.ROOT, "ref")
	ref_v, _ := yaml.node_number(&rdoc, ref_n)
	testing.expect(t, ref_p == .Found && ref_v == yaml.Number{99, .Int})

	multi_n, _ := yaml.member(rr, yaml.ROOT, "multi")
	for want in ([?]struct{ k: string, v: i64 }{{"a", 0}, {"b", 2}, {"c", 3}}) {
		idx, mp := yaml.member(rr, multi_n, want.k)
		nv, _ := yaml.node_number(&rdoc, idx)
		testing.expectf(t, mp == .Found && nv == yaml.Number{u64(want.v), .Int}, "multi.%s = %v", want.k, nv)
	}
}

@(test)
huge_canonical_keys_and_equality :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// >4096-digit explicit radix / leading-zero decimal keys must stream canonical digits accurately (`key_hash` + `same_keys`).
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "? ")
	for _ in 0 ..< 4200 {
		strings.write_byte(&b, '0')
	}
	strings.write_string(&b, "42\n: leading_zero\n? 42\n: plain_42\n")
	dup_huge := transmute([]u8)strings.to_string(b)
	_, derr := yaml.build(dup_huge, .Yaml_1_2, {dups = .Refuse})
	f, is_f := derr.(yaml.Fault)
	testing.expect(t, is_f && f.kind == .Duplicate_Key)

	// Distinct huge hex keys >4096 digits that differ only near the tail must stay distinct under `.Refuse`.
	hb := strings.builder_make(context.temp_allocator)
	strings.write_string(&hb, "? 0x1")
	for _ in 0 ..< 4200 {
		strings.write_byte(&hb, '0')
	}
	strings.write_string(&hb, "1\n: first\n? 0x1")
	for _ in 0 ..< 4200 {
		strings.write_byte(&hb, '0')
	}
	strings.write_string(&hb, "2\n: second\n")
	dist_huge := transmute([]u8)strings.to_string(hb)
	hdoc, herr := yaml.build(dist_huge, .Yaml_1_2, {dups = .Refuse})
	defer yaml.destroy(&hdoc)
	expect_nil(t, herr)
	cnt, _, _ := yaml.length({&hdoc, nil}, yaml.ROOT, context.allocator)
	testing.expect_value(t, cnt, 2)

	// Exact `W == 4096` boundary check in `same_streamed_long` (`4096` vs `4097` decoded string keys).
	wb := strings.builder_make(context.temp_allocator)
	strings.write_string(&wb, "? \"")
	for _ in 0 ..< 4095 {
		strings.write_byte(&wb, 'a')
	}
	strings.write_string(&wb, "\\n\"\n: k4096\n? \"")
	for _ in 0 ..< 4096 {
		strings.write_byte(&wb, 'a')
	}
	strings.write_string(&wb, "\\n\"\n: k4097\n")
	wdoc, werr := yaml.build(transmute([]u8)strings.to_string(wb), .Yaml_1_2, {dups = .Refuse})
	defer yaml.destroy(&wdoc)
	expect_nil(t, werr)
	wcnt, _, _ := yaml.length({&wdoc, nil}, yaml.ROOT, context.allocator)
	testing.expect_value(t, wcnt, 2)
}
