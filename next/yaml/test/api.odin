package yaml_tests

import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:yaml"

// A program that reads, checks, marshals, writes, and edits YAML imports `yaml` alone.
@(test)
yaml_alone_serves_a_program :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("name: stury\ntags:\n  - a\n  - b\nsize: 12\n")
	testing.expect_value(t, yaml.validate(src), nil)

	doc, err := yaml.build(src)
	defer yaml.destroy(&doc)
	testing.expect_value(t, err, nil)

	r := yaml.Reader{&doc, nil}
	at, p := yaml.member(r, yaml.ROOT, "name")
	buf: [16]u8
	name, ok := yaml.node_text(&doc, at, buf[:])
	testing.expect(t, p == .Found && ok && name == "stury")

	tags, _ := yaml.member(r, yaml.ROOT, "tags")
	n, _, _ := yaml.length(r, tags, context.allocator)
	testing.expect_value(t, n, 2)

	path := []yaml.Step{yaml.Name("size")}
	a, ferr := yaml.find(src, path)
	size, is_number := yaml.node_number(yaml.as(.Yaml_1_2), src, yaml.answer_node(a))
	testing.expect(t, ferr == nil && a.outcome == .Found && is_number && size == yaml.Number{12, .Int})

	d, derr := yaml.demand_of({{yaml.Name("tags"), yaml.Index(-1)}})
	defer yaml.destroy(&d)
	s, serr := yaml.scan(src, &d)
	defer yaml.destroy(&s)
	last, lp, has := yaml.answer({&s, nil}, 0, 0)
	text, _ := yaml.node_text(&s, last, buf[:])
	testing.expect(t, derr == nil && serr == nil && has && lp == .Found && text == "b")

	written, dropped, werr := yaml.write(&doc, .Yaml_1_2, {indent = 2})
	defer delete(written)
	testing.expect(t, werr == nil && dropped == {} && yaml.validate(written) == nil)

	bad := transmute([]u8)string("a: 1\na: [2\n")
	_, berr := yaml.build(bad)
	fault, faulted := berr.(yaml.Fault)
	testing.expect(t, faulted && fault.kind == .Truncated)
	msg: [96]u8
	testing.expect(t, len(yaml.error_message(msg[:], berr, bad)) > 0)

	_, refused := yaml.validate(src, .Yaml_1_2, {tolerate = {.Invalid_Utf8}}).(yaml.Bad_Option)
	testing.expect(t, refused)
	_, bad_fmt := yaml.validate(src, .Yaml_1_2, {format = tape.Dsv_Options{}}).(yaml.Bad_Option)
	testing.expect(t, bad_fmt)
	testing.expect(t, yaml.as(.Yaml_1_2) != nil && yaml.as(.Yaml_Merge) != nil && yaml.as(yaml.Spec(99)) == nil)
	testing.expect(t, yaml.reads(.Yaml_1_2) != nil && yaml.reads(.Yaml_Merge) != nil && yaml.reads(yaml.Spec(99)) == nil)
}

// Resolved-value key equality (`AGENTS.md` settled invariant): `1`, `+1`, and `0x1` read as the same integer key,
// whereas `1`, `"1"`, `1.0`, `true`, and `null` are distinct keys under YAML 1.2 Core Schema!
@(test)
resolved_key_equality_and_duplicate_policies :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Distinct resolved types sharing spelling text do NOT collide under `.Refuse` (`validate` refuses `.Refuse`, `build` enforces it).
	distinct_src := transmute([]u8)string("1: int_one\n\"1\": str_one\n1.0: float_one\ntrue: bool_t\n\"true\": str_t\nnull: null_v\n\"null\": str_n\n")
	testing.expect_value(t, yaml.validate(distinct_src, .Yaml_1_2, {dups = .Refuse}), yaml.Error(yaml.Bad_Option{"dups"}))
	doc, derr := yaml.build(distinct_src, .Yaml_1_2, {dups = .Refuse})
	defer yaml.destroy(&doc)
	testing.expect_value(t, derr, nil)
	n, _, _ := yaml.length({&doc, nil}, yaml.ROOT, context.allocator)
	testing.expect_value(t, n, 7)

	// Equivalent resolved keys DO collide under `build(..., {dups = .Refuse})`, and respect `.Last`/`.First`/`.Default`/`.All`.
	for equiv in ([?]string{"1: first\n0x1: second\n", "0o10: a\n8: b\n", "a\tb: 1\n\"a\\tb\": 2\n", "null: 1\n~: 2\n", "True: 1\ntrue: 2\n", "!!str 1: 1\n'1': 2\n"}) {
		src := transmute([]u8)equiv
		bdoc, ref := yaml.build(src, .Yaml_1_2, {dups = .Refuse})
		defer yaml.destroy(&bdoc)
		f, ok := ref.(yaml.Fault)
		testing.expectf(t, ok && f.kind == .Duplicate_Key, "%q: %v", equiv, ref)
		testing.expect_value(t, yaml.validate(src, .Yaml_1_2, {dups = .Default}), nil)
		testing.expect_value(t, yaml.validate(src, .Yaml_1_2, {dups = .Last}), nil)
		testing.expect_value(t, yaml.validate(src, .Yaml_1_2, {dups = .First}), nil)
	}

	// Concrete query policy check across `.Default`, `.Last`, `.First`, `.All`, `.Refuse`.
	dup := transmute([]u8)string("a: 1\na: 2\nb: 3\n")
	for want, policy in (#partial [yaml.Duplicates]string{.Default = "2", .Last = "2", .First = "1"}) {
		if want == "" {
			continue
		}
		ans, aerr := yaml.find(dup, {yaml.Name("a")}, opts = {dups = policy})
		testing.expectf(t, aerr == nil && ans.outcome == .Found && string(dup[ans.lo:ans.hi]) == want, "find %v: %v %v", policy, aerr, ans)
	}
	_, all_err := yaml.find(dup, {yaml.Name("a")}, opts = {dups = .All})
	testing.expect_value(t, all_err, yaml.Error(yaml.Bad_Option{"dups"}))

	all_doc, ab_err := yaml.build(dup, .Yaml_1_2, {dups = .All})
	defer yaml.destroy(&all_doc)
	testing.expect_value(t, ab_err, nil)
	len_all, _, _ := yaml.length({&all_doc, nil}, yaml.ROOT, context.allocator)
	testing.expect_value(t, len_all, 2)
	raw_count := 0
	all_r := yaml.Reader{&all_doc, nil}
	ch, ch_p, ch_err := yaml.children(all_r, yaml.ROOT, context.allocator)
	defer tape.destroy_children(&ch)
	testing.expect(t, ch_p == .Found && ch_err == nil)
	for {
		_, _, np := yaml.next_child(all_r, &ch, .Group)
		if np != .Found {
			break
		}
		raw_count += 1
	}
	testing.expect_value(t, raw_count, 3)

	// Canonical `key_hash` matches `same_text` even when one key uses hex `0x10` and lookup uses `"16"`, or `"1"` vs `1`!
	num_key_doc, nk_err := yaml.build(transmute([]u8)string("0x10: hex_16\n\"16\": str_16\n"), .Yaml_1_2, {dups = .Refuse})
	defer yaml.destroy(&num_key_doc)
	testing.expect_value(t, nk_err, nil)
	idx_v, p_v := yaml.member({&num_key_doc, nil}, yaml.ROOT, "16")
	buf: [16]u8
	got_s, _ := yaml.node_text(&num_key_doc, idx_v, buf[:])
	// Note `tape.member` matches by text (`"16"` matches both numeric `0x10` key or string `"16"` key via canonical key text: check `.Last` returns `"str_16"`!).
	testing.expect(t, p_v == .Found && got_s == "str_16")
}
