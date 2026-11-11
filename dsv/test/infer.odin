package dsv_tests

import "core:testing"
import rules "../../core/rules"
import schema "../../core/schema"
import dsv ".."

// A table's rows give an array of row objects, which the table and every sample of it pass.
@(test)
infer_and_sample_a_table :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := "id,name,score\n1,ann,2.5\n2,bob,\n3,cy,7\n"
	for spec in ([?]dsv.Spec{.Csv, .Tsv}) {
		as := dsv.as(spec, {infer = true})
		src := text if spec == .Csv else "id\tname\tscore\n1\tann\t2.5\n2\tbob\t\n3\tcy\t7\n"
		inf: schema.Inferred
		defer schema.inferred_destroy(&inf)
		testing.expect(t, schema.infer_records(&inf, transmute([]u8)src, as, .Lines) == nil)
		d, derr := schema.inferred(&inf)
		defer rules.description_destroy(&d)
		testing.expect(t, derr == nil)
		testing.expect_value(t, d.nodes[d.root].kinds, rules.Kinds{.Array})
		c := schema.compile_description(&d)
		b, err := schema.bind(&c, {dsv.checks(.Csv).reads if spec == .Csv else dsv.checks(.Tsv).reads, as})
		defer schema.unbind(&b)
		testing.expect(t, err == nil)
		testing.expect(t, schema.valid(&b, transmute([]u8)src))
		got, serr := schema.sample(&d, as, {reads = dsv.checks(.Csv).reads if spec == .Csv else dsv.checks(.Tsv).reads, count = 5, seed = 1})
		testing.expect(t, serr == nil)
		for s in got {
			testing.expectf(t, schema.valid(&b, s), "%s", s)
			delete(s)
		}
		delete(got)
	}
}

// The table of rows has no length of its own, whatever the ranges of its rows.
@(test)
infer_ranges_leave_the_table_unbounded :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "a,b,c\n1,,x\n,2.5,\n3,4,\"y\"\n"
	inf := schema.Inferred {
		ranges = true,
	}
	defer schema.inferred_destroy(&inf)
	testing.expect(t, schema.infer_records(&inf, transmute([]u8)src, dsv.as(.Csv, {infer = true}), .Lines) == nil)
	d, derr := schema.inferred(&inf)
	defer rules.description_destroy(&d)
	testing.expect(t, derr == nil)
	root := d.nodes[d.root].rules
	testing.expect(t, root.max_items == nil && root.min_items == 0)
}
