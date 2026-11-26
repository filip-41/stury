package yaml_tests

import "base:runtime"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:testkit"
import "stury:yaml"

@(private = "file")
path_steps :: proc(path: string) -> []tape.Step {
	if path == "" {
		return nil
	}
	parts := strings.split(path, ".", context.temp_allocator)
	out := make([]tape.Step, len(parts), context.temp_allocator)
	for p, i in parts {
		if len(p) > 0 && p[0] >= '0' && p[0] <= '9' {
			n := 0
			for b in transmute([]u8)p {
				n = n * 10 + int(b - '0')
			}
			out[i] = tape.Index(n)
		} else {
			out[i] = tape.Name(p)
		}
	}
	return out
}

@(private = "file")
base_at :: proc(doc: ^tape.Document, path: string) -> tape.Node_Index {
	cur := yaml.ROOT
	if path == "" {
		return cur
	}
	r := yaml.Reader{doc, nil}
	for p in strings.split(path, ".", context.temp_allocator) {
		if p == "@key" {
			return cur - 1
		}
		if len(p) > 0 && p[0] >= '0' && p[0] <= '9' {
			n := 0
			for b in transmute([]u8)p {
				n = n * 10 + int(b - '0')
			}
			cur, _ = yaml.element(r, cur, n)
		} else {
			cur, _ = yaml.member(r, cur, p)
		}
	}
	return cur
}

@(private = "file")
Edit_Op :: enum u8 {
	Set_Raw,
	Insert_Raw,
	Remove,
	Fact,
	Unfact,
	Reorder,
}

@(private = "file")
Edit_Rule :: struct {
	src:     string,
	op:      Edit_Op,
	path:    string,
	text:    string,
	key:     string,
	at:      int,
	fact:    tape.Fact_Kind,
	want:    string,
	refused: edit.Refusal_Kind,
}

@(private = "file")
run_rule :: proc(r: Edit_Rule, spec := yaml.Spec.Yaml_1_2, edit_opts := yaml.Edit_Options{}) -> (out: string, err: yaml.Edit_Error) {
	doc, berr := yaml.build(transmute([]u8)r.src, spec, {}, context.temp_allocator)
	if berr != nil {
		if f, is_f := berr.(tape.Fault); is_f {
			return "", f
		}
		return "", edit.refuse(.Bad_Handle, "parse error")
	}
	ov: yaml.Overlay
	yaml.edit_init(&ov, &doc, context.temp_allocator) or_return
	defer yaml.edit_destroy(&ov)

	target := base_at(&doc, r.path)
	h: yaml.Handle
	h = edit.handle_for_base(&ov, target) or_return
	switch r.op {
	case .Set_Raw:
		edit.set(&ov, h, edit.val_raw(r.text)) or_return
	case .Insert_Raw:
		if doc.nodes[target].kind == .Object {
			edit.insert_member(&ov, h, r.at, r.key, edit.val_raw(r.text)) or_return
		} else {
			edit.insert_element(&ov, h, r.at, edit.val_raw(r.text)) or_return
		}
	case .Remove:
		parent_path := ""
		if dot := strings.last_index_byte(r.path, '.'); dot >= 0 {
			parent_path = r.path[:dot]
			step := r.path[dot + 1:]
			ph := edit.handle_for_base(&ov, base_at(&doc, parent_path)) or_return
			if doc.nodes[base_at(&doc, parent_path)].kind == .Object {
				edit.del_member(&ov, ph, step) or_return
			} else {
				idx := 0
				for b in transmute([]u8)step {
					idx = idx * 10 + int(b - '0')
				}
				edit.del_element(&ov, ph, idx) or_return
			}
		} else {
			ph := edit.handle_for_base(&ov, yaml.ROOT) or_return
			if doc.nodes[yaml.ROOT].kind == .Object {
				edit.del_member(&ov, ph, r.path) or_return
			} else {
				idx := 0
				for b in transmute([]u8)r.path {
					idx = idx * 10 + int(b - '0')
				}
				edit.del_element(&ov, ph, idx) or_return
			}
		}
	case .Fact:
		edit.set_fact(&ov, h, r.fact, {r.text}) or_return
	case .Unfact:
		edit.del_fact(&ov, h, r.fact) or_return
	case .Reorder:
		order := make([]u32, len(r.text), context.temp_allocator)
		for b, i in transmute([]u8)r.text {
			order[i] = u32(b - '0')
		}
		edit.reorder(&ov, h, order) or_return
	}

	res := yaml.commit(&ov, spec, edit_opts, context.temp_allocator) or_return
	return string(res.bytes), nil
}

@(private = "file")
expect_edit_rules :: proc(t: ^testing.T, rules: []Edit_Rule, spec := yaml.Spec.Yaml_1_2, loc := #caller_location) {
	for r in rules {
		out, err := run_rule(r, spec)
		if r.refused != .None {
			ref, ok := err.(edit.Refusal)
			testing.expectf(t, ok && ref.kind == r.refused, "%q %v %s: got %v, want %v", r.src, r.op, r.path, err, r.refused, loc = loc)
			continue
		}
		testing.expectf(t, err == nil && out == r.want, "%q %v %s %q:\n got %q (%v)\nwant %q", r.src, r.op, r.path, r.text, out, err, r.want, loc = loc)
	}
}

@(test)
scalars_block_scalars_and_indent_preservation :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	expect_edit_rules(t, {
		// Inline scalar, comments, EOL, quoted/block replacements.
		{src = "a: 1  # c\nb: 2\n", path = "a", text = "2", want = "a: 2  # c\nb: 2\n"},
		{src = "a: 1\nb: 2", path = "b", text = "'x'", want = "a: 1\nb: 'x'"},
		{src = "- x\n- y\n", path = "1", text = "z", want = "- x\n- z\n"},
		{src = "a:\nb: 1\n", path = "a", text = "2", want = "a: 2\nb: 1\n"},
		{src = "a:\n  1\nb: 2\n", path = "a", text = "3", want = "a:\n  3\nb: 2\n"},
		{src = "--- # c\na: 1\n...\n", path = "a", text = "2", want = "--- # c\na: 2\n...\n"},
		{src = "a: 1\n", path = "", text = "- 1", want = "- 1\n"},
		{src = "a: !!str 1\n", path = "a", text = "x", want = "a: !!str x\n"},
		{src = "a: 1\n", path = "a.@key", text = "b", want = "b: 1\n"},
		{src = "a: 1\n", path = "a.@key", text = "x: y", want = "'x: y': 1\n"},
		{src = "a: |\n  one\n  two\nb: 1\n", path = "a", text = "x", want = "a: x\nb: 1\n"},
		{src = "a: >-\n  one\n  two\nb: 1\n", path = "a", text = "|-\n  x\n  y", want = "a: |-\n  x\n  y\nb: 1\n"},
		{src = "a: 1  # c\nb: 2\n", path = "a", text = "k: 1\nl: 2", want = "a:  # c\n  k: 1\n  l: 2\nb: 2\n"},
		{src = "top:\n    a: 1\n", path = "top.a", text = "k: 1\nl:\n  - 2", want = "top:\n    a:\n        k: 1\n        l:\n          - 2\n"},
		{src = "a:  # c\n  k: 1\n", path = "a", text = "3", want = "a: 3 # c\n"},
		{src = "c: {p: q}\n", path = "c", text = "- 1", want = "c: [1]\n"},

		// Block insertions & deletions preserving custom indents, CRLF, inner foot comments, and outer head comments when emptying container!
		{src = "a: 1\nb: 2\n", op = .Insert_Raw, at = 2, key = "c", text = "3", want = "a: 1\nb: 2\nc: 3\n"},
		{src = "a: 1\nb: 2\n", op = .Insert_Raw, at = 0, key = "c", text = "3", want = "c: 3\na: 1\nb: 2\n"},
		{src = "top:\n    a: 1\n", op = .Insert_Raw, path = "top", at = 1, key = "b", text = "x", want = "top:\n    a: 1\n    b: x\n"},
		{src = "a: 1\r\nb: 2\r\n", op = .Insert_Raw, at = 2, key = "c", text = "k: v", want = "a: 1\r\nb: 2\r\nc:\r\n  k: v\r\n"},
		{src = "a: 1\n# about b\nb: 2\nc: 3\n", op = .Remove, path = "b", want = "a: 1\nc: 3\n"},
		{src = "a: 1\nb: 2\n# foot\n", op = .Remove, path = "b", want = "a: 1\n# foot\n"},
		{src = "m:\n  a: 1\nn: 2\n", op = .Remove, path = "m.a", want = "m: {}\nn: 2\n"},
		{src = "# outer head\nm:\n  a: 1\nn: 2\n", op = .Remove, path = "m.a", want = "# outer head\nm: {}\nn: 2\n"},
		{src = "l:\n  - 1\n", op = .Remove, path = "l.0", want = "l: []\n"},

		// Flow collections & separators.
		{src = "f: [1, 2, 3]\n", op = .Remove, path = "f.1", want = "f: [1, 3]\n"},
		{src = "f: [1,2]\n", op = .Insert_Raw, path = "f", at = 2, text = "3", want = "f: [1,2,3]\n"},
		{src = "f: [1, 2]\n", op = .Insert_Raw, path = "f", at = 0, text = "0", want = "f: [0, 1, 2]\n"},
		{src = "m: {}\n", op = .Insert_Raw, path = "m", at = 0, key = "a", text = "1", want = "m: {a: 1}\n"},
		{src = "f: { a: 1 }\n", op = .Remove, path = "f.a", want = "f: {}\n"},
		{src = "[\n  1\n]\n", op = .Insert_Raw, at = 1, text = "2", want = "[\n  1,\n  2\n]\n"},

		// Reorders & comments / properties.
		{src = "a: 1 # one\n\n# about b\nb: |\n  x\n  y\n", op = .Reorder, text = "10", want = "# about b\nb: |\n  x\n  y\n\na: 1 # one\n"},
		{src = "f: [1, 2,  3]\n", op = .Reorder, path = "f", text = "210", want = "f: [3, 2,  1]\n"},
		{src = "f: [\n  1, # one\n  2\n  ]\n", op = .Reorder, path = "f", text = "10", want = "f: [\n  2,\n  1 # one\n  ]\n"},
		{src = "a: 1\nb: 2\n", op = .Fact, path = "b", fact = .Comment, text = "note", want = "a: 1\n# note\nb: 2\n"},
		{src = "a: 1\n# old\nb: 2\n", op = .Unfact, path = "b", fact = .Comment, want = "a: 1\nb: 2\n"},
		{src = "a: 1\nb: 2\n", op = .Fact, path = "b", fact = .Comment_Inline, text = "note", want = "a: 1\nb: 2 # note\n"},
		{src = "a: !!str 1\n", op = .Unfact, path = "a", fact = .Tag, want = "a: 1\n"},
		{src = "a:\n  k: 1\n", op = .Fact, path = "a", fact = .Anchor, text = "x", want = "a: &x\n  k: 1\n"},
		{src = "a: &x 1\nb: 2\n", op = .Fact, path = "b", fact = .Alias, text = "x", want = "a: &x 1\nb: *x\n"},
	})
}

@(test)
group1_and_group2_refusals_and_reflow :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Group 1 (`Format_Impossible`): aliases, anchors, merges, reorder past anchor, invalid raw/comment/UTF-8, >1024B implicit key.
	// MUST still refuse even when `Options.reflow = true`!
	g1 := []Edit_Rule {
		{src = "a: &x 1\nb: *x\n", path = "a", text = "2", refused = .Unspellable_Value},
		{src = "a: &x\n  k: 1\nb: *x\n", path = "a.k", text = "2", refused = .Unspellable_Value},
		{src = "a: &x\n  k: 1\nb: *x\n", path = "b.k", text = "2", refused = .Unspellable_Value},
		{src = "a: &x\n  k: 1\nb: *x\n", op = .Insert_Raw, path = "b", at = 1, key = "l", text = "2", refused = .Unspellable_Value},
		{src = "l:\n  - &x 1\n  - &x 2\nb: *x\n", op = .Reorder, path = "l", text = "10", refused = .Bad_Order},
		{src = "a: 1\n", path = "a", text = "bad\n---\ntwo", refused = .Unspellable_Value},
		{src = "a: 1\n", op = .Fact, path = "a", fact = .Comment, text = "bad\x01c", refused = .Fact_No_Place},
	}
	for r in g1 {
		for reflow in ([2]bool{false, true}) {
			_, err := run_rule(r, .Yaml_1_2, {reflow = reflow})
			ref, ok := err.(edit.Refusal)
			testing.expectf(t, ok && ref.group == .Format_Impossible && ref.kind == r.refused, "g1 reflow=%v %q: got %v", reflow, r.src, err)
		}
	}

	// Active `<<` merge freeze under `.Yaml_Merge` even with `reflow = true`.
	merge_rule := Edit_Rule{src = "a: &x {k: 1}\nb:\n  <<: *x\n  l: 2\n", path = "b.l", text = "3"}
	for reflow in ([2]bool{false, true}) {
		_, merr := run_rule(merge_rule, .Yaml_Merge, {reflow = reflow})
		ref, ok := merr.(edit.Refusal)
		testing.expectf(t, ok && ref.group == .Format_Impossible && ref.kind == .Unspellable_Value, "merge reflow=%v: %v", reflow, merr)
	}

	// Inactive `<<` literal does NOT block edits.
	_, ok_lit := run_rule({src = "a: 1\nb: \"<<\"\n", path = "a", text = "2"}, .Yaml_Merge)
	testing.expect_value(t, ok_lit, nil)

	// Group 2 (`Layout_Reflow_Needed`): refused without `reflow = true`, rewritten cleanly WITH `reflow = true`!
	g2 := []Edit_Rule {
		{src = "f: [a: 1]\n", op = .Insert_Raw, path = "f.0", at = 1, key = "b", text = "2", refused = .Layout_Reflow_Needed},
		{src = "f: [1, # one\n  2]\n", op = .Reorder, path = "f", text = "10", refused = .Layout_Reflow_Needed},
		{src = "f: [1, 2]\n", op = .Fact, path = "f.0", fact = .Comment, text = "note", refused = .Layout_Reflow_Needed},
		{src = "f: [1, 2]\n", op = .Fact, path = "f", fact = .Style, text = "block", refused = .Layout_Reflow_Needed},
	}
	for r in g2 {
		_, err_no := run_rule(r, .Yaml_1_2, {reflow = false})
		ref, ok := err_no.(edit.Refusal)
		testing.expectf(t, ok && ref.group == .Layout_Conflict && ref.kind == .Layout_Reflow_Needed, "g2 no reflow %q: %v", r.src, err_no)
		// Verify flow->block style reflow produces valid block YAML when `reflow = true`!
		if r.fact == .Style {
			doc, _ := yaml.build(transmute([]u8)r.src)
			defer yaml.destroy(&doc)
			ov: yaml.Overlay
			_ = yaml.edit_init(&ov, &doc)
			defer yaml.edit_destroy(&ov)
			fh, _ := edit.handle_for_base(&ov, base_at(&doc, "f"))
			_ = edit.set_fact(&ov, fh, .Style, {"block"})
			res, cerr := yaml.commit(&ov, .Yaml_1_2, {reflow = true})
			testing.expect_value(t, cerr, nil)
			defer edit.destroy_commit_result(&res)
			testing.expect(t, len(res.rewritten) > 0 && strings.contains(string(res.bytes), "- 1"))
			testing.expect_value(t, yaml.validate(res.bytes), nil)
		}
	}
}

@(test)
edit_preserves_quotes_style_and_incremental_commit_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Preserves existing quote/fold styles & foreign `json` node spelling via `Base_Ref`.
	src := transmute([]u8)string("d: \"x\"\ns: 'a b'\nf: >\n  old\nj: 1\n")
	doc, err := yaml.build(src)
	defer yaml.destroy(&doc)
	expect_nil(t, err)

	held, jerr := json.build(transmute([]u8)string(`{"k":[1,{"m":null}]}`), .Json)
	defer json.destroy(&held)
	testing.expect_value(t, jerr, nil)

	ov: yaml.Overlay
	testing.expect_value(t, yaml.edit_init(&ov, &doc), nil)
	defer yaml.edit_destroy(&ov)

	_, _ = edit.set_path(&ov, path_steps("d"), edit.val_string("nginx:1.27"))
	_, _ = edit.set_path(&ov, path_steps("s"), edit.val_string("it's"))
	_, _ = edit.set_path(&ov, path_steps("f"), edit.val_string("new line\n"))
	held_yaml, _, _ := yaml.write(&held, .Yaml_1_2, {indent = 2}, context.temp_allocator)
	_, _ = edit.set_path(&ov, path_steps("j"), edit.val_raw(string(held_yaml)))
	_, _ = edit.set_path(&ov, path_steps("copied"), edit.val_base_ref(base_at(&doc, "d")))

	new_doc, res, cerr := yaml.commit_document(&ov, .Yaml_1_2)
	defer yaml.destroy(&new_doc)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, cerr, nil)
	got := string(res.bytes)
	testing.expect(t, strings.contains(got, "d: \"nginx:1.27\""), got)
	testing.expect(t, strings.contains(got, "s: 'it''s'"), got)
	testing.expect(t, strings.contains(got, "f: >\n  new line"), got)
	testing.expect(t, strings.contains(got, "k:\n"), got)

	// Verify `commit_document` on simple scalar produces `subtree_only` incremental splice matching full `yaml.build`!
	inc_src := transmute([]u8)string("a: 100\nb:\n  c: hello\n")
	inc_doc, _ := yaml.build(inc_src)
	defer yaml.destroy(&inc_doc)
	ov2: yaml.Overlay
	_ = yaml.edit_init(&ov2, &inc_doc)
	defer yaml.edit_destroy(&ov2)
	_, _ = edit.set_path(&ov2, path_steps("b.c"), edit.val_string("world"))
	d2, r2, c2 := yaml.commit_document(&ov2, .Yaml_1_2)
	defer yaml.destroy(&d2)
	defer edit.destroy_commit_result(&r2)
	testing.expect_value(t, c2, nil)
	testing.expect(t, len(r2.splices) == 1 && r2.splices[0].subtree_only)

	rebuilt, rb_err := yaml.build(r2.bytes)
	defer yaml.destroy(&rebuilt)
	expect_nil(t, rb_err)
	testing.expect(t, testkit.values_agree(t, &d2, yaml.ROOT, &rebuilt, yaml.ROOT, {}, "incremental commit_document"))
}

// Anchors whose aliases are all deleted become editable again.
@(test)
removing_aliases_unfreezes_anchor_for_edits :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	src := transmute([]u8)string("a: &x\n  k: 1\nb: *x\nc: [*x]\nd: 3\n")
	doc, err := yaml.build(src)
	defer yaml.destroy(&doc)
	expect_nil(t, err)

	ov: yaml.Overlay
	_ = yaml.edit_init(&ov, &doc)
	defer yaml.edit_destroy(&ov)
	_, _ = edit.set_path(&ov, path_steps("a.k"), edit.val_int(2))
	_, _ = edit.set_path(&ov, path_steps("b"), edit.val_int(0))

	// Still has `c: [*x]`, so refused!
	res1, e1 := yaml.commit(&ov, .Yaml_1_2)
	defer edit.destroy_commit_result(&res1)
	r1, ok1 := e1.(edit.Refusal)
	testing.expect(t, ok1 && r1.kind == .Unspellable_Value)

	// Delete `c`, now `&x` has zero remaining live aliases!
	root_h, _ := edit.ensure_root(&ov)
	_ = edit.del_member(&ov, root_h, "c")
	res, e2 := yaml.commit(&ov, .Yaml_1_2)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, e2, nil)
	testing.expect_value(t, string(res.bytes), "a: &x\n  k: 2\nb: 0\nd: 3\n")
}

@(test)
empty_reorder_dead_ancestor_key_raw_and_oom_regression :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// 1. Reorder inserted elements inside previously empty flow `[]` and `{}` without OOB (`regroup_flow` count==0 guard).
	{
		doc, _ := yaml.build(transmute([]u8)string("f: []\nm: {}\n"))
		defer yaml.destroy(&doc)
		ov: yaml.Overlay
		_ = yaml.edit_init(&ov, &doc)
		defer yaml.edit_destroy(&ov)
		fh, _ := edit.handle_for_base(&ov, base_at(&doc, "f"))
		_, _ = edit.insert_element(&ov, fh, 0, edit.val_int(1))
		_, _ = edit.insert_element(&ov, fh, 1, edit.val_int(2))
		_ = edit.reorder(&ov, fh, {1, 0})

		mh, _ := edit.handle_for_base(&ov, base_at(&doc, "m"))
		_, _ = edit.insert_member(&ov, mh, 0, "a", edit.val_int(1))
		_, _ = edit.insert_member(&ov, mh, 1, "b", edit.val_int(2))
		_ = edit.reorder(&ov, mh, {1, 0})

		res, err := yaml.commit(&ov, .Yaml_1_2)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, string(res.bytes), "f: [2, 1]\nm: {b: 2, a: 1}\n")
	}

	// 2. Post-walk `.Key` rename skipped cleanly when parent/ancestor container is replaced, deleted, or reflowed!
	{
		doc, _ := yaml.build(transmute([]u8)string("outer:\n  mid:\n    old: 1\nkeep: 2\n"))
		defer yaml.destroy(&doc)
		ov: yaml.Overlay
		_ = yaml.edit_init(&ov, &doc)
		defer yaml.edit_destroy(&ov)
		kh, _ := edit.handle_for_base(&ov, base_at(&doc, "outer.mid.old.@key"))
		_ = edit.set(&ov, kh, edit.val_string("new"))
		outer_h, _ := edit.handle_for_base(&ov, base_at(&doc, "outer"))
		_ = edit.set(&ov, outer_h, edit.val_int(99))
		res, err := yaml.commit(&ov, .Yaml_1_2)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, string(res.bytes), "outer: 99\nkeep: 2\n")
	}

	// 3. `.Raw` `subtree_only` guard: disabled on container / flow parent / facted node / empty scalar / multi-line raw;
	// enabled only on un-facted block-parent scalar replaced by inline scalar raw!
	{
		src := transmute([]u8)string("s: 1\nc: [1]\nf: [1, 2]\nt: !!str 1\ne:\n")
		doc, _ := yaml.build(src)
		defer yaml.destroy(&doc)

		// Container replaced by scalar raw -> full rewalk (`subtree_only == false`) and agrees with rebuild!
		ov1: yaml.Overlay
		_ = yaml.edit_init(&ov1, &doc)
		defer yaml.edit_destroy(&ov1)
		ch, _ := edit.handle_for_base(&ov1, base_at(&doc, "c"))
		_ = edit.set(&ov1, ch, edit.val_raw("2"))
		d1, r1, e1 := yaml.commit_document(&ov1, .Yaml_1_2)
		defer yaml.destroy(&d1)
		defer edit.destroy_commit_result(&r1)
		testing.expect(t, e1 == nil && len(r1.splices) == 1 && !r1.splices[0].subtree_only)

		// Flow element & facted scalar & empty node -> not `subtree_only`, exact document match!
		ov2: yaml.Overlay
		_ = yaml.edit_init(&ov2, &doc)
		defer yaml.edit_destroy(&ov2)
		fh, _ := edit.handle_for_base(&ov2, base_at(&doc, "f.0"))
		_ = edit.set(&ov2, fh, edit.val_raw("9"))
		th, _ := edit.handle_for_base(&ov2, base_at(&doc, "t"))
		_ = edit.set(&ov2, th, edit.val_raw("x"))
		eh, _ := edit.handle_for_base(&ov2, base_at(&doc, "e"))
		_ = edit.set(&ov2, eh, edit.val_raw("z"))
		d2, r2, e2 := yaml.commit_document(&ov2, .Yaml_1_2)
		defer yaml.destroy(&d2)
		defer edit.destroy_commit_result(&r2)
		testing.expect_value(t, e2, nil)
		for sp in r2.splices {
			testing.expect(t, !sp.subtree_only)
		}
		rb2, _ := yaml.build(r2.bytes)
		defer yaml.destroy(&rb2)
		testing.expect(t, testkit.values_agree(t, &d2, yaml.ROOT, &rb2, yaml.ROOT, {}, "raw commit_document"))
	}

	// Verify flow->block style reflow on `yaml.ROOT` produces valid block YAML cleanly without dangling splice (`emit_yaml_reflow`)!
	{
		rdoc, _ := yaml.build(transmute([]u8)string("[1, 2]\n"))
		defer yaml.destroy(&rdoc)
		rov: yaml.Overlay
		_ = yaml.edit_init(&rov, &rdoc)
		defer yaml.edit_destroy(&rov)
		rh, _ := edit.ensure_root(&rov)
		_ = edit.set_fact(&rov, rh, .Style, {"block"})
		rres, rcerr := yaml.commit(&rov, .Yaml_1_2, {reflow = true})
		defer edit.destroy_commit_result(&rres)
		testing.expect(t, rcerr == nil && len(rres.rewritten) > 0 && strings.contains(string(rres.bytes), "- 1"))
		testing.expect_value(t, yaml.validate(rres.bytes), nil)
	}

	// 4. Failing-allocator sweep across `yaml.edit_init`, mutations, and `yaml.commit` (`bad == 0`, zero leaks).
	{
		src := transmute([]u8)string("a: 1\nb:\n  - 10\n  - 20\nf: [1, 2]\n")
		doc, _ := yaml.build(src)
		defer yaml.destroy(&doc)
		Sweep_Ctx :: struct {
			doc: ^yaml.Document,
		}
		sweep_edit := proc(data: rawptr, a: runtime.Allocator) {
			sc := (^Sweep_Ctx)(data)
			ov: yaml.Overlay
			if yaml.edit_init(&ov, sc.doc, a) != nil {
				return
			}
			defer yaml.edit_destroy(&ov)
			if _, err := edit.set_path(&ov, {tape.Name("a")}, edit.val_string("updated")); err != nil {
				return
			}
			bh, herr := edit.handle_for_base(&ov, base_at(sc.doc, "b"))
			if herr != nil {
				return
			}
			if edit.reorder(&ov, bh, {1, 0}) != nil {
				return
			}
			res, cerr := yaml.commit(&ov, .Yaml_1_2, {}, a)
			if cerr == nil {
				edit.destroy_commit_result(&res)
			}
		}
		sc := Sweep_Ctx{&doc}
		sw := testkit.sweep_failures(sweep_edit, &sc)
		testing.expectf(t, sw.bad == 0 && sw.refused >= 1, "edit OOM sweep: %v", sw)
	}
}
