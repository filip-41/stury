package dsv_tests

import "core:testing"
import core "../../core"
import dsv ".."

// Tests fact edits over a delimited text with a comment byte. A comment line belongs to the record that follows it, or
// to the root as its foot after the last record. The output writes the document's comment byte at the line's first
// byte.

@(private = "file")
body :: proc(t: ^testing.T, doc: ^core.Document, node: u32, role: core.Role, want: string) -> bool {
	it := core.facts_of(doc, node, role)
	got, ok := core.fact_next(&it)
	if !testing.expectf(t, ok && string(got) == want, "node %d role %v: %q, want %q", node, role, got, want) {
		return false
	}
	if _, more := core.fact_next(&it); !testing.expectf(t, !more, "node %d role %v holds more than one fact", node, role) {
		return false
	}
	return true
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

// A body with a line end has no spelling as a single comment line, so it is dropped and counted. A document with no
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

// A comment above the header row belongs to the root, since no record precedes it to take it. A last line with no
// line end is the root's foot.
@(test)
fact_header_and_last_line :: proc(t: ^testing.T) {
	{
		doc, _ := dsv.build(transmute([]u8)string("#top\na,b\n1,2\n"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		testing.expect(t, body(t, &doc, core.ROOT, .Comment, "top"))
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
		testing.expect(t, body(t, &doc, core.ROOT, .Comment, "/hello"))
	}
	{
		doc, _ := dsv.build(transmute([]u8)string("\xEF\xBB\xBF#c\na,b\n1,2\n"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		body(t, &doc, core.ROOT, .Comment, "c")
	}
}

// A delimited text holds a comment line on a record and a foot on the root only. Any other fact is dropped and counted.
@(test)
fact_slots :: proc(t: ^testing.T) {
	cases := []struct {
		node: u32,
		role: core.Role,
	}{
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

// A headed root accepts a `Comment` at the text's start. A headerless root writes no header row there, so its
// `Comment` is dropped.
@(test)
fact_root_comment :: proc(t: ^testing.T) {
	{
		doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv, {comment = '#'})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, core.ROOT, .Comment, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
		out, dropped, err := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, err.kind == .None && dropped == 0 && string(out) == "#c\na,b\n1,2\n", "commit: %v, %d dropped, %q", err, dropped, out)
	}
	{
		doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv, {comment = '#', no_header = true})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, core.ROOT, .Comment, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
		out, dropped, err := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, err.kind == .None && dropped == 1 && string(out) == "a,b\n1,2\n", "commit: %v, %d dropped, %q", err, dropped, out)
	}
}

// A root comment above the header reads only when a record follows it, so removing every record drops the comment
// and counts it.
@(test)
fact_root_comment_all_records_removed :: proc(t: ^testing.T) {
	doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv, {comment = '#'})
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, core.ROOT, .Comment, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.remove(&list, 4).kind, core.Document_Error_Kind.None)
	out, dropped, err := core.commit(&list)
	defer if len(out) > 0 {
		delete(out)
	}
	testing.expectf(t, err.kind == .None && dropped == 1 && string(out) == "a,b\n", "commit: %v, %d dropped, %q", err, dropped, out)
}

// A U+2028 byte is not a line end in a delimited text, so a comment body may hold one and the output writes it.
@(test)
fact_body_u2028 :: proc(t: ^testing.T) {
	doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv, {comment = '#'})
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	if e := core.set_fact(&list, 4, .Comment, transmute([]u8)string("a\u2028b")); !testing.expect_value(t, e.kind, core.Document_Error_Kind.None) {
		return
	}
	out, dropped, err := core.commit(&list)
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, err.kind == .None && dropped == 0, "commit: %v, %d dropped", err, dropped) {
		return
	}
	testing.expectf(t, string(out) == "a,b\n#a\u2028b\n1,2\n", "committed %q", out)
}

// An insert into a removal run of records moves to the run's cut end, and inserts at one index keep their recording
// order.
@(test)
fact_insert_in_removal_run :: proc(t: ^testing.T) {
	commit_want :: proc(t: ^testing.T, src, want: string, body: proc(list: ^core.Edit_List)) {
		doc, err := dsv.build(transmute([]u8)src, .Csv)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", src, err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		body(&list)
		out, _, cerr := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		if !testing.expectf(t, cerr.kind == .None, "%q: commit %v", src, cerr) {
			return
		}
		testing.expectf(t, string(out) == want, "%q: committed %q, want %q", src, out, want)
		read, rerr := dsv.build(out, .Csv)
		defer core.destroy(&read)
		if !testing.expectf(t, rerr.kind == .None, "%q: committed text does not read: %v in %q", src, rerr, out) {
			return
		}
	}

	commit_want(t, "a,b\n1,2\n3,4\n", "a,b\n7,7\n8,8\n3,4\n", proc(list: ^core.Edit_List) {
		core.remove(list, 4)
		core.insert(list, core.ROOT, 1, transmute([]u8)string("7,7"))
		core.insert(list, core.ROOT, 1, transmute([]u8)string("8,8"))
	})
	commit_want(t, "a,b\n1,2\n3,4", "a,b\n1,2\n9,9", proc(list: ^core.Edit_List) {
		core.remove(list, 7)
		core.insert(list, core.ROOT, 1, transmute([]u8)string("9,9"))
	})
	commit_want(t, "a,b\n1,2\n3,4", "a,b\n1,2\n9,9", proc(list: ^core.Edit_List) {
		core.remove(list, 7)
		core.insert(list, core.ROOT, 2, transmute([]u8)string("9,9"))
	})
}

// A headerless document's commit is read back with the build's header choice, so a ragged text it read still reads.
@(test)
fact_headerless_commit_reads_headerless :: proc(t: ^testing.T) {
	doc, err := dsv.build(transmute([]u8)string("a\nb,c\n"), .Csv, {no_header = true, tolerate = {.Ragged}})
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	out, _, cerr := core.commit(&list)
	defer if len(out) > 0 {
		delete(out)
	}
	testing.expectf(t, cerr.kind == .None, "commit: %v", cerr)
	if len(out) > 0 {
		testing.expectf(t, string(out) == "a\nb,c\n", "committed %q", out)
	}
}

// An insert whose separator comes after its text accepts a zero-width set at the same byte, in that order. An insert
// whose separator comes first refuses it, since the set text would otherwise join the inserted record.
@(test)
fact_zero_width_set_beside_insert :: proc(t: ^testing.T) {
	{
		doc, _ := dsv.build(transmute([]u8)string("a,b\n,2\n"), .Csv)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.insert(&list, core.ROOT, 0, transmute([]u8)string("3,4")).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.set(&list, 5, transmute([]u8)string("9")).kind, core.Document_Error_Kind.None)
		out, dropped, err := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		if !testing.expectf(t, err.kind == .None && dropped == 0, "accept: %v, %d dropped", err, dropped) {
			return
		}
		testing.expectf(t, string(out) == "a,b\n3,4\n9,2\n", "accept: committed %q", out)
	}
	{
		doc, _ := dsv.build(transmute([]u8)string("1,2\n3,"), .Csv, {no_header = true})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.insert(&list, core.ROOT, 2, transmute([]u8)string("7,8")).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.set(&list, 6, transmute([]u8)string("9")).kind, core.Document_Error_Kind.None)
		out, _, err := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, err.kind == .Conflicting_Edits, "refuse: commit %v", err)
	}
}

// A spec change would respell every cell, so it is refused with `Bad_Result` and nothing is written.
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

// A foot written after a last record that ends in a blank cell starts its own line, since a comment byte reads as a
// comment only at a line's start.
@(test)
fact_foot_after_blank_cell :: proc(t: ^testing.T) {
	doc, _ := dsv.build(transmute([]u8)string("a\tb\n1\t2\n\t"), .Tsv, {comment = '!'})
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, core.ROOT, .Comment_Foot, transmute([]u8)string("x")).kind, core.Document_Error_Kind.None)
	out, dropped, err := core.commit(&list)
	defer if len(out) > 0 {
		delete(out)
	}
	testing.expectf(t, err.kind == .None && dropped == 0 && string(out) == "a\tb\n1\t2\n\t\n!x\n", "foot: %v, %d dropped, %q", err, dropped, out)
}

// An unnamed root comment above the header stays when every record is removed. It reads as the root's foot, and no
// fact is dropped.
@(test)
fact_root_comment_all_records_removed_unnamed :: proc(t: ^testing.T) {
	doc, err := dsv.build(transmute([]u8)string("#top\nh\n1\n"), .Csv, {comment = '#'})
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.remove(&list, 3).kind, core.Document_Error_Kind.None)
	out, dropped, cerr := core.commit(&list)
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, cerr.kind == .None && dropped == 0, "commit: %v, %d dropped", cerr, dropped) {
		return
	}
	if !testing.expectf(t, string(out) == "#top\nh\n", "committed %q", out) {
		return
	}
	read, rerr := dsv.build(out, .Csv, {comment = '#'})
	defer core.destroy(&read)
	if !testing.expectf(t, rerr.kind == .None, "committed text does not read: %v", rerr) {
		return
	}
	it := core.facts_of(&read, core.ROOT, .Comment_Foot)
	b, ok := core.fact_next(&it)
	testing.expectf(t, ok && string(b) == "top", "foot: %q %v", b, ok)
}
