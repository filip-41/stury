package dsv_tests

import "core:testing"
import core "../../core"
import dsv ".."

// Fact edits over a delimited text with a comment byte. A comment line is a fact of the record that follows it, or of
// the root after the last record, and the output writes the document's comment byte at the line's first byte.

@(private = "file")
body :: proc(t: ^testing.T, doc: ^core.Document, node: u32, role: core.Role, want: string) -> bool {
	it := core.facts_of(doc, node, role)
	got, ok := core.fact_next(&it)
	return testing.expectf(t, ok && string(got) == want, "node %d role %v: %q, want %q", node, role, got, want)
}

// A headed table's comment lines are the fact of the record after them, and a line after the last record is the
// root's foot.
@(test)
fact_read_lines :: proc(t: ^testing.T) {
	doc, err := dsv.build(transmute([]u8)string("a,b\n#head\n1,2\n#foot\n"), .Csv, {comment = '#'})
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	testing.expect(t, body(t, &doc, 4, .Comment, "head"))
	body(t, &doc, core.ROOT, .Comment_Foot, "foot")
}

// Each role is written where the walk reads it: a record's `Comment`, no `Comment_Inline` in a delimited text, and a
// `Comment_Foot` on the root after the last record.
@(test)
fact_set_roles :: proc(t: ^testing.T) {
	for c in ([]struct {
			role:    core.Role,
			node:    u32,
			want:    string,
			dropped: int,
		}{
			{.Comment, 4, "a,b\n#c\n1,2\n", 0},
			{.Comment_Inline, 4, "a,b\n1,2\n", 1},
			{.Comment_Foot, core.ROOT, "a,b\n1,2\n#c\n", 0},
		}) {
		doc, err := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "build: %v", err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		if e := core.set_fact(&list, c.node, c.role, transmute([]u8)string("c")); !testing.expect_value(t, e.kind, core.Document_Error_Kind.None) {
			return
		}
		out, dropped, cerr := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		if !testing.expectf(t, cerr.kind == .None && dropped == c.dropped, "role %v: %v, %d dropped", c.role, cerr, dropped) {
			return
		}
		testing.expectf(t, string(out) == c.want, "role %v: committed %q, want %q", c.role, out, c.want)
	}
}

// A comment line the source holds is replaced or removed through its record's `Comment` fact, and another role's
// edit leaves it alone.
@(test)
fact_replace_and_remove :: proc(t: ^testing.T) {
	{
		doc, _ := dsv.build(transmute([]u8)string("a,b\n#old\n1,2\n"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, 4, .Comment, transmute([]u8)string("new")).kind, core.Document_Error_Kind.None)
		out, dropped, err := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, err.kind == .None && dropped == 0 && string(out) == "a,b\n#new\n1,2\n", "commit: %v, %d dropped, %q", err, dropped, out)
	}
	{
		doc, _ := dsv.build(transmute([]u8)string("a,b\n#old\n1,2\n"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.remove_fact(&list, 4, .Comment).kind, core.Document_Error_Kind.None)
		out, _, err := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, err.kind == .None && string(out) == "a,b\n\n1,2\n", "commit: %v, %q", err, out)
	}
	{
		doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n#old\n"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, core.ROOT, .Comment_Foot, transmute([]u8)string("new")).kind, core.Document_Error_Kind.None)
		out, dropped, err := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, err.kind == .None && dropped == 0 && string(out) == "a,b\n1,2\n#new\n", "foot: %v, %d dropped, %q", err, dropped, out)
	}
	{
		doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n#old\n"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.remove_fact(&list, core.ROOT, .Comment_Foot).kind, core.Document_Error_Kind.None)
		out, _, err := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, err.kind == .None && string(out) == "a,b\n1,2\n\n", "foot remove: %v, %q", err, out)
	}
	{
		doc, _ := dsv.build(transmute([]u8)string("a,b\n#old\n1,2\n"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set(&list, 6, transmute([]u8)string("9")).kind, core.Document_Error_Kind.None)
		out, _, err := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, err.kind == .None && string(out) == "a,b\n#old\n1,9\n", "commit: %v, %q", err, out)
	}
}

// A body with a line end has no spelling as one comment line, so it is dropped and counted. A document with no
// comment byte drops a comment too.
@(test)
fact_shapes_and_output :: proc(t: ^testing.T) {
	doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv, {comment = '#'})
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, 4, .Comment, transmute([]u8)string("one\ntwo")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.set_fact(&list, 4, .Comment_Inline, transmute([]u8)string("a\nb")).kind, core.Document_Error_Kind.Bad_Fact)
	out, dropped, err := core.commit(&list)
	defer if len(out) > 0 {
		delete(out)
	}
	testing.expectf(t, err.kind == .None && dropped == 1 && string(out) == "a,b\n1,2\n", "commit: %v, %d dropped, %q", err, dropped, out)

	plain, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv)
	defer core.destroy(&plain)
	one := core.edit_list_init(&plain)
	defer core.edit_list_destroy(&one)
	testing.expect_value(t, core.set_fact(&one, 4, .Comment, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
	dropped_out, plain_dropped, derr := core.commit(&one)
	defer if len(dropped_out) > 0 {
		delete(dropped_out)
	}
	testing.expectf(t, derr.kind == .None && plain_dropped == 1 && string(dropped_out) == "a,b\n1,2\n", "commit: %v, %d dropped, %q", derr, plain_dropped, dropped_out)
}

// A comment above the header row belongs to the first record, as any comment before a record does. A last line with
// no line end is the root's foot.
@(test)
fact_header_and_last_line :: proc(t: ^testing.T) {
	{
		doc, _ := dsv.build(transmute([]u8)string("#top\na,b\n1,2\n"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		testing.expect(t, body(t, &doc, 4, .Comment, "top"))
	}
	{
		doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n#end"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		body(t, &doc, core.ROOT, .Comment_Foot, "end")
	}
}

// The comment byte is the format's alone, so a `/` line's body keeps its second `/`. A text with a byte-order mark
// still reads its first comment line.
@(test)
fact_comment_byte_and_bom :: proc(t: ^testing.T) {
	{
		doc, _ := dsv.build(transmute([]u8)string("//hello\na,b\n1,2\n"), .Csv, {comment = '/'})
		defer core.destroy(&doc)
		testing.expect(t, body(t, &doc, 4, .Comment, "/hello"))
	}
	{
		doc, _ := dsv.build(transmute([]u8)string("\xEF\xBB\xBF#c\na,b\n1,2\n"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		body(t, &doc, 4, .Comment, "c")
	}
}

// A delimited text holds a comment line on a record and a foot on the root only. Any other fact is dropped and counted.
@(test)
fact_slots :: proc(t: ^testing.T) {
	cases := []struct {
		node: u32,
		role: core.Role,
	}{
		{core.ROOT, .Comment},
		{4, .Comment_Foot},
		{6, .Comment},
		{4, .Comment_Inline},
	}
	for c in cases {
		doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv, {comment = '#'})
		list := core.edit_list_init(&doc)
		e := core.set_fact(&list, c.node, c.role, transmute([]u8)string("c"))
		out, dropped, cerr := core.commit(&list)
		testing.expectf(t, e.kind == .None && cerr.kind == .None && dropped == 1 && string(out) == "a,b\n1,2\n", "node %d role %v: %v %v, %d dropped, %q", c.node, c.role, e, cerr, dropped, out)
		if len(out) > 0 {
			delete(out)
		}
		core.edit_list_destroy(&list)
		core.destroy(&doc)
	}
}

// A commit under another spec would respell every cell, so it is refused with `Bad_Result` and writes nothing.
@(test)
fact_spec_change_refused :: proc(t: ^testing.T) {
	doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	out, _, err := core.commit(&list, u8(dsv.Spec.Tsv))
	defer if len(out) > 0 {
		delete(out)
	}
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Bad_Result)
}
