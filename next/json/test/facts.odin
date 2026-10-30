package json_tests

import "core:testing"
import core "../../core"
import json ".."

// Fact edits: a read, a set and a removal for each fact role, the marker each output writes, and the facts an output
// drops.

// Commits `list` with the output spec `as`, checks the text against `want` and the dropped count, and builds the text
// as `S`.
expect_fact_commit :: proc(t: ^testing.T, list: ^core.Edit_List, as: u8, want: string, dropped: int, $S: json.Spec) -> bool {
	out, got, err := core.commit(list, as)
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, err.kind == .None, "commit: %v", err) {
		return false
	}
	if !testing.expectf(t, got == dropped, "dropped %d facts, want %d", got, dropped) {
		return false
	}
	if !testing.expectf(t, string(out) == want, "committed %q, want %q", string(out), want) {
		return false
	}
	doc, derr := json.build(out, S)
	defer core.destroy(&doc)
	return testing.expectf(t, derr.kind == .None, "committed text does not read: %v", derr)
}

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

// `set_fact` for each role: a comment above the value, one after it on its line, and one after the last value. Each is
// written where the walk reads it back as that role.
@(test)
fact_set_roles :: proc(t: ^testing.T) {
	src := `{"a":1}`
	for c in ([]struct {
			role: core.Role,
			want: string,
		}{
			{.Comment, "{\n//c\n\"a\":1}"},
			{.Comment_Inline, "{\"a\":1 //c\n}"},
			{.Comment_Foot, "{\"a\":1\n//c\n}"},
		}) {
		doc, err := json.build(transmute([]u8)src, .Jsonc)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", src, err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		if e := core.set_fact(&list, 2, c.role, transmute([]u8)string("c")); !testing.expect_value(t, e.kind, core.Document_Error_Kind.None) {
			return
		}
		if !expect_fact_commit(t, &list, u8(json.Spec.Jsonc), c.want, 0, .Jsonc) {
			return
		}
	}
}

// `facts_of` and `fact_next` for the three roles: a head comment above the root, a block comment after a value, and a
// line comment after the last member. A body is the text between the markers.
@(test)
fact_read_roles :: proc(t: ^testing.T) {
	doc, err := json.build(transmute([]u8)string("//head\n{\"a\":1 /*i*/}"), .Jsonc)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	if !body(t, &doc, core.ROOT, .Comment, "head") || !body(t, &doc, 2, .Comment_Inline, "i") {
		return
	}
	foot, ferr := json.build(transmute([]u8)string("{\"a\":1\n//f\n}"), .Jsonc)
	defer core.destroy(&foot)
	if !testing.expectf(t, ferr.kind == .None, "build: %v", ferr) {
		return
	}
	body(t, &foot, 2, .Comment_Foot, "f")
}

// `set_fact` replaces every fact of the node and role in place, and `remove_fact` removes them and no other role's.
@(test)
fact_replace_and_remove :: proc(t: ^testing.T) {
	{
		doc, _ := json.build(transmute([]u8)string("//old\n{\"a\":1}"), .Jsonc)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, core.ROOT, .Comment, transmute([]u8)string("new")).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "//new\n{\"a\":1}", 0, .Jsonc))
	}
	{
		// The edit sees two head comments as one fact of the node and role: both go, and one comment replaces them.
		doc, _ := json.build(transmute([]u8)string("//one\n//two\n[1]"), .Jsonc)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, core.ROOT, .Comment, transmute([]u8)string("new")).kind, core.Document_Error_Kind.None)
		out, dropped, err := core.commit(&list, u8(json.Spec.Jsonc))
		defer if len(out) > 0 {
			delete(out)
		}
		if !testing.expectf(t, err.kind == .None && dropped == 0, "commit: %v, %d dropped", err, dropped) {
			return
		}
		read, rerr := json.build(out, .Jsonc)
		defer core.destroy(&read)
		if !testing.expectf(t, rerr.kind == .None, "committed text does not read: %v", rerr) {
			return
		}
		if !body(t, &read, core.ROOT, .Comment, "new") {
			return
		}
	}
	{
		doc, _ := json.build(transmute([]u8)string("{\"a\":1}\n//foot"), .Jsonc)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.remove_fact(&list, core.ROOT, .Comment_Foot).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "{\"a\":1}\n", 0, .Jsonc))
	}
}

// A body with a line end is written as a block comment. A body with a line end for an inline fact is refused with
// `.Bad_Fact`.
@(test)
fact_shapes :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, core.ROOT, .Comment, transmute([]u8)string("one\ntwo")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.set_fact(&list, 2, .Comment_Inline, transmute([]u8)string("a\nb")).kind, core.Document_Error_Kind.Bad_Fact)
	testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "/*one\ntwo*/{\"a\":1}", 0, .Jsonc))
}

// Each role is replaced and removed on node 1: the new body reads back in the same role, and a removal leaves the
// role with no fact.
@(test)
fact_each_role :: proc(t: ^testing.T) {
	for c in ([]struct {
			role: core.Role,
			src:  string,
		}{
			{.Comment, "[\n//old\n1]"},
			{.Comment_Inline, "[1 //old\n]"},
			{.Comment_Foot, "[1\n//old\n]"},
		}) {
		doc, err := json.build(transmute([]u8)c.src, .Jsonc)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", c.src, err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		if e := core.set_fact(&list, 1, c.role, transmute([]u8)string("new")); !testing.expect_value(t, e.kind, core.Document_Error_Kind.None) {
			return
		}
		out, dropped, cerr := core.commit(&list, u8(json.Spec.Jsonc))
		defer if len(out) > 0 {
			delete(out)
		}
		if !testing.expectf(t, cerr.kind == .None && dropped == 0, "role %v: %v, %d dropped", c.role, cerr, dropped) {
			return
		}
		read, rerr := json.build(out, .Jsonc)
		if !testing.expectf(t, rerr.kind == .None, "replace does not read: %v in %q", rerr, out) {
			core.destroy(&read)
			return
		}
		body(t, &read, 1, c.role, "new")
		core.destroy(&read)

		gone := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&gone)
		if e := core.remove_fact(&gone, 1, c.role); !testing.expect_value(t, e.kind, core.Document_Error_Kind.None) {
			return
		}
		out2, _, err2 := core.commit(&gone, u8(json.Spec.Jsonc))
		defer if len(out2) > 0 {
			delete(out2)
		}
		read2, rerr2 := json.build(out2, .Jsonc)
		it := core.facts_of(&read2, 1, c.role)
		_, still := core.fact_next(&it)
		testing.expectf(t, err2.kind == .None && rerr2.kind == .None && !still, "remove role %v: %v %v %q", c.role, err2, rerr2, out2)
		core.destroy(&read2)
	}
}

// A `set` of a value beside a comment keeps the comment's bytes.
@(test)
fact_kept_beside_set :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a" /*c*/: 1}`), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set(&list, 2, transmute([]u8)string("2")).kind, core.Document_Error_Kind.None)
	testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), `{"a" /*c*/: 2}`, 0, .Jsonc))
}

// The output spec decides: `.Json` drops the comment the edit added and counts it, `.Jsonc` writes it and reads it back
// with the same body.
@(test)
fact_output_drops :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`), .Json)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, 2, .Comment_Inline, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
	testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Json), `{"a":1}`, 1, .Json))
	if !expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "{\"a\":1 //c\n}", 0, .Jsonc) {
		return
	}
	out, dropped, err := core.commit(&list, u8(json.Spec.Jsonc))
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, err.kind == .None && dropped == 0, "commit: %v, %d dropped", err, dropped) {
		return
	}
	read, rerr := json.build(out, .Jsonc)
	defer core.destroy(&read)
	if !testing.expectf(t, rerr.kind == .None, "committed text does not read: %v", rerr) {
		return
	}
	body(t, &read, 2, .Comment_Inline, "c")
}

// `set_fact` refuses `.Value` and a key node with `.Bad_Index`, and a second fact of one node and role with
// `.Conflicting_Edits`.
@(test)
fact_errors :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, 1, .Comment, transmute([]u8)string("c")).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, core.set_fact(&list, 2, .Value, transmute([]u8)string("c")).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, core.set_fact(&list, 2, .Comment, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.set_fact(&list, 2, .Comment, transmute([]u8)string("d")).kind, core.Document_Error_Kind.Conflicting_Edits)
}

// `Role(200)` is refused with `.Bad_Fact`, not a node error.
@(test)
fact_unknown_role :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, 2, core.Role(200), transmute([]u8)string("c")).kind, core.Document_Error_Kind.Bad_Fact)
}

// A fact on a member beside a removed neighbour does not conflict, because the fact's bytes are not in the removal's
// range.
@(test)
fact_beside_neighbour_edits :: proc(t: ^testing.T) {
	{
		doc, _ := json.build(transmute([]u8)string(`[1,2]`), .Jsonc)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, 2, .Comment, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.remove(&list, 1).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "[\n//c\n2]", 0, .Jsonc))
	}
	{
		doc, _ := json.build(transmute([]u8)string(`[1,2]`), .Jsonc)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, 2, .Comment_Inline, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.remove(&list, 1).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "[2 //c\n]", 0, .Jsonc))
	}
}

// An insert before a commented member keeps the comment with its member. A foot comment the insert moves off the last
// member is dropped and counted, not moved to the new member.
@(test)
fact_beside_insert :: proc(t: ^testing.T) {
	{
		doc, _ := json.build(transmute([]u8)string(`[1,2]`), .Jsonc)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, 2, .Comment, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.insert(&list, 0, 1, transmute([]u8)string("0")).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "[1,0,\n//c\n2]", 0, .Jsonc))
	}
	{
		doc, _ := json.build(transmute([]u8)string(`[1,2]`), .Jsonc)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, 2, .Comment_Foot, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.insert(&list, 0, 2, transmute([]u8)string("3")).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "[1,2,3]", 1, .Jsonc))
	}
}

// A body holding a line end and `*/` cannot be written as a comment, so it is dropped and counted.
@(test)
fact_body_unholdable :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, 2, .Comment, transmute([]u8)string("x\n*/")).kind, core.Document_Error_Kind.None)
	testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), `{"a":1}`, 1, .Jsonc))
}

// An inline fact after a value that ends its line writes no second line end.
@(test)
fact_inline_no_blank_line :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string("{\n\"a\":1\n}"), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, 2, .Comment_Inline, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
	testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "{\n\"a\":1 //c\n}", 0, .Jsonc))
}

// An output spec other than the document's reads without the source's tolerance: a JSON5 text committed as `.Json`
// fails with `.Bad_Result` and drops nothing.
@(test)
fact_spec_change_reads_strictly :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string("{a:1}"), .Json5)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	out, dropped, err := core.commit(&list, u8(json.Spec.Json))
	defer if len(out) > 0 {
		delete(out)
	}
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Bad_Result)
	testing.expect_value(t, dropped, 0)
}
