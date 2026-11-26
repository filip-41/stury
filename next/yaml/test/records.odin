package yaml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:yaml"

@(test)
concatenated_streams_validate_find_and_scan :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := transmute([]u8)string("a: 1\n---\n- b\n...\n# end\n---\na: 3\n")
	r := yaml.records_open(text, .Concatenated)
	defer yaml.destroy(&r)
	recs: [8]yaml.Record
	ans: [8]yaml.Span_Answer
	docs: [8]yaml.Document
	n := yaml.records_find(&r, {yaml.Name("a")}, recs[:], ans[:])
	testing.expect_value(t, r.err, nil)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, ans[0].outcome, yaml.Presence.Found)
	testing.expect_value(t, ans[1].outcome, yaml.Presence.Wrong_Kind)
	testing.expect_value(t, ans[2].outcome, yaml.Presence.Found)
	testing.expect_value(t, string(text[ans[0].lo:ans[0].hi]), "1")
	testing.expect_value(t, string(text[ans[2].lo:ans[2].hi]), "3")

	rv := yaml.records_open(text, .Concatenated)
	defer yaml.destroy(&rv)
	testing.expect_value(t, yaml.records_validate(&rv, recs[:]), 0)
	testing.expect_value(t, rv.err, nil)
	testing.expect_value(t, rv.index, 3)

	rs := yaml.records_open(text, .Concatenated)
	defer yaml.destroy(&rs)
	d, _ := yaml.demand_of({{yaml.Name("a")}})
	defer yaml.destroy(&d)
	ns := yaml.records_scan(&rs, &d, recs[:], docs[:])
	testing.expect_value(t, rs.err, nil)
	testing.expect_value(t, ns, 3)
	for &sd in docs[:ns] {
		yaml.destroy(&sd)
	}
}

@(test)
concatenated_streams_skip_bad_documents_and_window_pieces :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Bad record surrounded by valid records under `skip_bad`: recovers across `---` / `...`!
	bad_stream := transmute([]u8)string("a: 1\n---\na: [unclosed\n---\na: 3\n")
	r := yaml.records_open(bad_stream, .Concatenated, .Yaml_1_2)
	r.skip_bad = true
	defer yaml.destroy(&r)
	recs: [8]yaml.Record
	ans: [8]yaml.Span_Answer
	n := yaml.records_find(&r, {yaml.Name("a")}, recs[:], ans[:])
	testing.expect_value(t, r.err, nil)
	testing.expect_value(t, n, 3)
	testing.expect(t, recs[0].err == nil && recs[1].err != nil && recs[2].err == nil)
	testing.expect_value(t, string(bad_stream[ans[0].lo:ans[0].hi]), "1")
	testing.expect_value(t, string(bad_stream[ans[2].lo:ans[2].hi]), "3")

	// Quarantine limit & `max_bytes` limit.
	quarantine := make([dynamic]tape.Bad_Record)
	defer delete(quarantine)
	qr := yaml.records_open(bad_stream, .Concatenated, .Yaml_1_2)
	qr.skip_bad = true
	qr.quarantine = &quarantine
	defer yaml.destroy(&qr)
	_ = yaml.records_validate(&qr, recs[:])
	testing.expect_value(t, qr.err, nil)
	testing.expect_value(t, len(quarantine), 1)

	mb := yaml.records_open(transmute([]u8)string("a: 1\n---\na: [unclosed\n  more padding bytes\n---\na: 3\n"), .Concatenated, .Yaml_1_2)
	mb.skip_bad = true
	mb.max_bytes = 5
	defer yaml.destroy(&mb)
	_ = yaml.records_validate(&mb, recs[:])
	testing.expect(t, mb.err != nil)

	// Pieces windowed concatenated stream across bad & good docs.
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 40 {
		if i > 0 {
			strings.write_string(&b, "---\n")
		}
		fmt.sbprintf(&b, "idx: %d\npayload: \"val-%d\"\n", i, i)
	}
	full := transmute([]u8)strings.to_string(b)
	p := tape.Pieces{allocator = context.allocator}
	defer yaml.destroy(&p)
	step := 37
	end := min(step, len(full))
	p.last = end == len(full)
	rp := yaml.records_open(full[:end], .Concatenated, .Yaml_1_2, {pieces = &p})
	defer yaml.destroy(&rp)
	total := 0
	for {
		chunk: [4]yaml.Record
		ca: [4]yaml.Span_Answer
		k := yaml.records_find(&rp, {yaml.Name("idx")}, chunk[:], ca[:])
		total += k
		if !p.more || p.last {
			break
		}
		start := int(p.keep)
		next_end := min(end + step, len(full))
		p.from, p.last = p.keep, next_end == len(full)
		end = next_end
		expect_nil(t, yaml.records_window(&rp, full[start:end]))
	}
	expect_nil(t, rp.err)
	testing.expect_value(t, total, 40)
}

@(test)
elements_and_members_records_at_paths :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	src := transmute([]u8)string("a: 0\nlogs:\n  - id: 1\n    s: x\n  - [1, 2]\n  - 3\n")
	r := yaml.records_open(src, .Elements, .Yaml_1_2, {}, {yaml.Name("logs")})
	defer yaml.destroy(&r)
	recs: [8]yaml.Record
	docs: [8]yaml.Document
	d, _ := yaml.demand_of({{}})
	defer yaml.destroy(&d)
	n := yaml.records_scan(&r, &d, recs[:], docs[:])
	expect_nil(t, r.err)
	testing.expect_value(t, n, 3)
	for &sd in docs[:n] {
		yaml.destroy(&sd)
	}

	// Anchors, `%TAG`, and merge keys inside element records!
	merged := transmute([]u8)string("def: &b {x: 1, y: 2}\nl:\n  - <<: *b\n    y: 3\n  - *b\n")
	rm := yaml.records_open(merged, .Elements, .Yaml_Merge, {}, {yaml.Name("l")})
	defer yaml.destroy(&rm)
	mans: [4]yaml.Span_Answer
	mn := yaml.records_find(&rm, {yaml.Name("y")}, recs[:], mans[:])
	expect_nil(t, rm.err)
	testing.expect_value(t, mn, 2)
	testing.expect_value(t, string(merged[mans[0].lo:mans[0].hi]), "3")
	testing.expect_value(t, string(merged[mans[1].lo:mans[1].hi]), "2")

	// Unsupported framings refused cleanly.
	for bad_f in ([]yaml.Framing{.Lines, .Seq}) {
		bx := yaml.records_open(src, bad_f)
		defer yaml.destroy(&bx)
		testing.expect_value(t, yaml.records_validate(&bx, recs[:]), 0)
		testing.expect_value(t, testkit.code_of(bx.err), "bad option framing")
	}

	// `.Members` / `.Elements` refuse `.Refuse` upfront via `validate_dups` / `path_dups`, and preserve `.First` vs `.Last` across nested duplicate keys.
	dup_mem := transmute([]u8)string("m:\n  first:\n    k: 1\n    k: 2\n")
	rv_ref := yaml.records_open(dup_mem, .Members, .Yaml_1_2, {dups = .Refuse}, {yaml.Name("m")})
	defer yaml.destroy(&rv_ref)
	testing.expect_value(t, yaml.records_validate(&rv_ref, recs[:]), 0)
	testing.expect_value(t, rv_ref.err, yaml.Error(yaml.Bad_Option{"dups"}))

	rf_ref := yaml.records_open(dup_mem, .Members, .Yaml_1_2, {dups = .Refuse}, {yaml.Name("m")})
	defer yaml.destroy(&rf_ref)
	fans: [4]yaml.Span_Answer
	testing.expect_value(t, yaml.records_find(&rf_ref, {yaml.Name("k")}, recs[:], fans[:]), 0)
	testing.expect_value(t, rf_ref.err, yaml.Error(yaml.Bad_Option{"dups"}))

	rf_first := yaml.records_open(dup_mem, .Members, .Yaml_1_2, {dups = .First}, {yaml.Name("m")})
	defer yaml.destroy(&rf_first)
	testing.expect_value(t, yaml.records_find(&rf_first, {yaml.Name("k")}, recs[:], fans[:]), 1)
	expect_nil(t, rf_first.err)
	testing.expect_value(t, string(dup_mem[fans[0].lo:fans[0].hi]), "1")

	rf_last := yaml.records_open(dup_mem, .Members, .Yaml_1_2, {dups = .Last}, {yaml.Name("m")})
	defer yaml.destroy(&rf_last)
	testing.expect_value(t, yaml.records_find(&rf_last, {yaml.Name("k")}, recs[:], fans[:]), 1)
	expect_nil(t, rf_last.err)
	testing.expect_value(t, string(dup_mem[fans[0].lo:fans[0].hi]), "2")
}
