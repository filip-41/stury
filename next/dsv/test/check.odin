// Streaming `dsv.check` vs `check.check_document(dsv.build)` parity across CSV, TSV, and Plain.
package dsv_tests

import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:testkit"

@(test)
test_dsv_check_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Schema: array of rows {name: string minLength 1, score: integer 0..100}
	d: rules.Description
	d.allocator = context.allocator
	defer rules.description_destroy(&d)

	name_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.String}, rules = {min_length = 1}, array = -1, object = -1})
	score_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Integer}, rules = {minimum = "0", maximum = "100"}, array = -1, object = -1})
	false_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {}, array = -1, object = -1})

	row_members := make([]rules.Member, 2)
	row_members[0] = {name = "name", node = name_n, required = true}
	row_members[1] = {name = "score", node = score_n, required = true}
	append(&d.objects, rules.Object{members = row_members, additional = false_n, keys = rules.NONE})

	row_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})

	append(&d.arrays, rules.Array{items = row_n})
	root := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Array}, array = 0, object = -1})
	d.root = root

	plan, cerr := check.compile(&d)
	testing.expect_value(t, cerr.kind, check.Error_Kind.None)
	defer check.plan_destroy(&plan)

	Case :: struct {
		spec:  dsv.Spec,
		input: string,
		valid: bool,
	}
	cases := [?]Case{
		{.Csv, "name,score\nAlice,95\nBob,80\n", true},
		{.Tsv, "name\tscore\nAlice\t100\nBob\t0\n", true},
		{.Plain, "name,score\nAlice,42\n", true},
		{.Csv, "name,score\nAlice,150\n", false},
		{.Csv, "name,score\n,50\n", false},
		{.Tsv, "name\tscore\nAlice\tnope\n", false},
	}

	dsv_opts := tape.Dsv_Options{infer = true}
	for c in cases {
		src := transmute([]u8)c.input
		r_s := dsv.check(src, &plan, c.spec, {}, nil, context.allocator, dsv_opts)
		defer check.result_destroy(&r_s)
		testing.expectf(t, r_s.valid == c.valid, "dsv stream %v on %q: got %v want %v", c.spec, c.input, r_s.valid, c.valid)

		sink_s: check.Sink
		check.sink_init(&sink_s)
		defer check.sink_destroy(&sink_s)
		r_ss := dsv.check(src, &plan, c.spec, {}, &sink_s, context.allocator, dsv_opts)
		defer check.result_destroy(&r_ss)
		testing.expect_value(t, r_ss.valid, c.valid)

		doc, berr := dsv.build(src, c.spec, {format = dsv_opts})
		testing.expect_value(t, berr, nil)
		defer tape.destroy(&doc)

		r_d := check.check_document(&doc, &plan)
		defer check.result_destroy(&r_d)
		testing.expect_value(t, r_d.valid, c.valid)

		sink_d: check.Sink
		check.sink_init(&sink_d)
		defer check.sink_destroy(&sink_d)
		r_ds := check.check_document(&doc, &plan, {}, &sink_d)
		defer check.result_destroy(&r_ds)
		testing.expect_value(t, r_ds.valid, c.valid)
		testing.expect_value(t, len(sink_s.entries), len(sink_d.entries))
	}
}
