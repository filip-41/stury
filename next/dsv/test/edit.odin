package dsv_tests

import "base:runtime"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:testkit"

@(test)
dsv_edit_cell_preserves_untargeted_bytes_and_crlf :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("name,note,qty\r\n\"alice\",\"a,b\",12\r\nbob,plain,5\r\n")
	doc, err := dsv.build(src, .Csv, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	ov: dsv.Overlay
	testing.expect(t, dsv.edit_init(&ov, &doc, alloc) == nil)
	defer dsv.edit_destroy(&ov)

	// Edit only row 1's qty cell; row 0's quoted `"alice"` and `"a,b"` and CRLF must remain byte-exact.
	_, e1 := edit.set_path(&ov, {tape.Index(1), tape.Name("qty")}, edit.val_string("99"))
	testing.expect(t, e1 == nil)

	res, cerr := dsv.commit(&ov, .Csv, {}, alloc)
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, string(res.bytes), "name,note,qty\r\n\"alice\",\"a,b\",12\r\nbob,plain,99\r\n")
}

@(test)
dsv_edit_csv_quoting_and_row_ops :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("a,b\n1,x\n2,y\n3,z\n")
	doc, err := dsv.build(src, .Csv, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	ov: dsv.Overlay
	testing.expect(t, dsv.edit_init(&ov, &doc, alloc) == nil)
	defer dsv.edit_destroy(&ov)

	// Quote automatically when cell contains comma or quote.
	_, e1 := edit.set_path(&ov, {tape.Index(0), tape.Name("b")}, edit.val_string("hello, \"world\""))
	testing.expect(t, e1 == nil)
	// Delete row 1 (`2,y`).
	testing.expect(t, edit.del_path(&ov, {tape.Index(1)}) == nil)

	spliced, res, cerr := dsv.commit_document(&ov, .Csv, {}, alloc)
	testing.expect(t, cerr == nil)
	defer tape.destroy_document(&spliced)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, string(res.bytes), "a,b\n1,\"hello, \"\"world\"\"\"\n3,z\n")

	fresh, ferr := dsv.build(res.bytes, .Csv, {}, alloc)
	testing.expect(t, ferr == nil)
	defer tape.destroy_document(&fresh)
	testing.expect_value(t, len(spliced.nodes), len(fresh.nodes))
}

@(test)
dsv_edit_no_header_and_tsv :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	// TSV with header
	src := transmute([]u8)string("k\tv\nalpha\t1\nbeta\t2\n")
	doc, err := dsv.build(src, .Tsv, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	ov: dsv.Overlay
	testing.expect(t, dsv.edit_init(&ov, &doc, alloc) == nil)
	defer dsv.edit_destroy(&ov)

	_, e1 := edit.set_path(&ov, {tape.Index(0), tape.Name("v")}, edit.val_string("ten\ttwo"))
	testing.expect(t, e1 == nil)

	res, cerr := dsv.commit(&ov, .Tsv, {}, alloc)
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, string(res.bytes), "k\tv\nalpha\tten\\ttwo\nbeta\t2\n")

	// CSV without header
	nh_opts := dsv.Options{format = dsv.Dsv_Options{no_header = true}}
	nh_src := transmute([]u8)string("a,b\nc,d\n")
	nh_doc, nh_err := dsv.build(nh_src, .Csv, nh_opts, alloc)
	testing.expect(t, nh_err == nil)
	defer tape.destroy_document(&nh_doc)

	nh_ov: dsv.Overlay
	testing.expect(t, dsv.edit_init(&nh_ov, &nh_doc, alloc) == nil)
	defer dsv.edit_destroy(&nh_ov)

	_, e2 := edit.set_path(&nh_ov, {tape.Index(1), tape.Index(0)}, edit.val_string("C2"))
	testing.expect(t, e2 == nil)

	nh_res, nh_cerr := dsv.commit(&nh_ov, .Csv, {}, alloc)
	testing.expect(t, nh_cerr == nil)
	defer edit.destroy_commit_result(&nh_res)
	testing.expect_value(t, string(nh_res.bytes), "a,b\nC2,d\n")
}

@(test)
dsv_edit_group1_refusals :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("a\tb\nx\ty\n")
	doc, err := dsv.build(src, .Tsv, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	// Non-scalar cell value (array) is Group 1 refused even under reflow.
	ov: dsv.Overlay
	testing.expect(t, dsv.edit_init(&ov, &doc, alloc) == nil)
	defer dsv.edit_destroy(&ov)
	_, e1 := edit.set_path(&ov, {tape.Index(0), tape.Name("b")}, edit.val_array(nil))
	testing.expect(t, e1 == nil)

	res, cerr := dsv.commit(&ov, .Tsv, {reflow = true}, alloc)
	defer edit.destroy_commit_result(&res)
	ref, is_ref := cerr.(edit.Refusal)
	testing.expect(t, is_ref)
	testing.expect_value(t, ref.group, edit.Refusal_Group.Format_Impossible)
}

@(test)
dsv_edit_infer_double_eof_unknown_col_comments_and_empty_cell :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. `infer = true` keeps string `"123"` quoted so it reads back as a string, NOT a number!
	{
		opts := dsv.Options{format = dsv.Dsv_Options{infer = true}}
		src := transmute([]u8)string("k,v\na,1\n")
		doc, err := dsv.build(src, .Csv, opts, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: dsv.Overlay
		testing.expect(t, dsv.edit_init(&ov, &doc, alloc) == nil)
		defer dsv.edit_destroy(&ov)
		_, _ = edit.set_path(&ov, {tape.Index(0), tape.Name("v")}, edit.val_string("123"))

		res, cerr := dsv.commit(&ov, .Csv, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), "k,v\na,\"123\"\n")
	}

	// 2. Multiple EOF row inserts produce NO blank line, and unknown column key is refused!
	{
		src := transmute([]u8)string("a,b\n1,2\n")
		doc, err := dsv.build(src, .Csv, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: dsv.Overlay
		testing.expect(t, dsv.edit_init(&ov, &doc, alloc) == nil)
		defer dsv.edit_destroy(&ov)
		root_h, _ := edit.ensure_root(&ov)

		a1, _ := edit.new_node(&ov, edit.val_string("3"))
		b1, _ := edit.new_node(&ov, edit.val_string("4"))
		e1 := [2]edit.Object_Entry{{key = "a", value = a1}, {key = "b", value = b1}}
		_, _ = edit.insert_element(&ov, root_h, -1, edit.val_object(e1[:]))

		a2, _ := edit.new_node(&ov, edit.val_string("5"))
		b2, _ := edit.new_node(&ov, edit.val_string("6"))
		e2 := [2]edit.Object_Entry{{key = "a", value = a2}, {key = "b", value = b2}}
		_, _ = edit.insert_element(&ov, root_h, -1, edit.val_object(e2[:]))

		res, cerr := dsv.commit(&ov, .Csv, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), "a,b\n1,2\n3,4\n5,6\n")

		// Unknown column key in inserted row must be refused!
		bad_v, _ := edit.new_node(&ov, edit.val_string("x"))
		bad_e := [1]edit.Object_Entry{{key = "no_such_col", value = bad_v}}
		_, _ = edit.insert_element(&ov, root_h, -1, edit.val_object(bad_e[:]))
		_, bad_err := dsv.commit(&ov, .Csv, {}, alloc)
		ref, is_ref := bad_err.(edit.Refusal)
		testing.expect(t, is_ref && ref.kind == .Bad_Name)
	}

	// 3. Root comment replacement does NOT duplicate existing comment lines, and empty cell `""` splices cleanly!
	{
		opts := dsv.Options{format = dsv.Dsv_Options{comment = '#'}}
		src := transmute([]u8)string("# old header note\na,b\n1,2\n")
		doc, err := dsv.build(src, .Csv, opts, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: dsv.Overlay
		testing.expect(t, dsv.edit_init(&ov, &doc, alloc) == nil)
		defer dsv.edit_destroy(&ov)
		root_h, _ := edit.ensure_root(&ov)
		testing.expect(t, edit.set_fact(&ov, root_h, .Comment, {"new header note"}, padded = true) == nil)
		_, _ = edit.set_path(&ov, {tape.Index(0), tape.Name("b")}, edit.val_string(""))

		spliced, res, cerr := dsv.commit_document(&ov, .Csv, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), "# new header note\na,b\n1,\n")

		fresh, ferr := dsv.build(res.bytes, .Csv, opts, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		testing.expect_value(t, len(spliced.nodes), len(fresh.nodes))
	}

	// 4. Multi-cell `commit_document` splice (zero leak under Tracking_Allocator + exact node/byte parity).
	{
		src := transmute([]u8)string("a,b,c\n1,2,3\n4,5,6\n")
		doc, err := dsv.build(src, .Csv, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: dsv.Overlay
		testing.expect(t, dsv.edit_init(&ov, &doc, alloc) == nil)
		defer dsv.edit_destroy(&ov)
		_, _ = edit.set_path(&ov, {tape.Index(0), tape.Name("a")}, edit.val_string("ten"))
		_, _ = edit.set_path(&ov, {tape.Index(1), tape.Name("c")}, edit.val_string("sixty"))

		spliced, res, cerr := dsv.commit_document(&ov, .Csv, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), "a,b,c\nten,2,3\n4,5,sixty\n")
	}
}
