package json_tests

import "core:testing"
import core "../../core"
import json ".."

// Tests of fact edits. Each fact role is read, set and removed, and each output's marker and dropped facts are
// checked.

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

// A comment above a value, one after it on its line, and one after the container's last value are each written where
// the walk reads it back in the same role on the same node.
@(test)
fact_set_roles :: proc(t: ^testing.T) {
	src := `{"a":1}`
	for c in ([]struct {
			node: u32,
			role: core.Role,
			want: string,
		}{
			{2, .Comment, "{\n//c\n\"a\":1}"},
			{2, .Comment_Inline, "{\"a\":1 /*c*/}"},
			{0, .Comment_Foot, "{\"a\":1}\n//c\n"},
		}) {
		doc, err := json.build(transmute([]u8)src, .Jsonc)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", src, err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		if e := core.set_fact(&list, c.node, c.role, transmute([]u8)string("c")); !testing.expect_value(t, e.kind, core.Document_Error_Kind.None) {
			return
		}
		if !expect_fact_commit(t, &list, u8(json.Spec.Jsonc), c.want, 0, .Jsonc) {
			return
		}
	}
}

// The three roles are read as follows: a head comment above the root, a block comment after a value, and a line
// comment after the last member of an object, which is the object's foot. A body is the text between the markers.
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
	body(t, &foot, core.ROOT, .Comment_Foot, "f")
}

// An inline fact on a member that survives a neighbour's removal stays on that member. The removal takes the comma
// the fact's line led, so the fact is written at the value's end.
@(test)
fact_inline_beside_removed_neighbour :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`[1,2]`), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, 1, .Comment_Inline, transmute([]u8)string("x")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.remove(&list, 2).kind, core.Document_Error_Kind.None)
	out, dropped, err := core.commit(&list)
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, err.kind == .None && dropped == 0, "commit: %v, %d dropped", err, dropped) {
		return
	}
	testing.expectf(t, string(out) == "[1 /*x*/]", "committed %q", out)
	read, rerr := json.build(out, .Jsonc)
	defer core.destroy(&read)
	if !testing.expectf(t, rerr.kind == .None, "committed text does not read: %v in %q", rerr, out) {
		return
	}
	body(t, &read, 1, .Comment_Inline, "x")
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
		// The edit names two head comments as one fact of the node and role. Both are removed and one comment replaces
		// them.
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

// A body with an LF is written as a block comment. An LF in an inline fact's body is refused with `.Bad_Fact`.
@(test)
fact_shapes :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, core.ROOT, .Comment, transmute([]u8)string("one\ntwo")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.set_fact(&list, 2, .Comment_Inline, transmute([]u8)string("a\nb")).kind, core.Document_Error_Kind.Bad_Fact)
	testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "/*one\ntwo*/\n{\"a\":1}", 0, .Jsonc))
}

// Every role is set, replaced and removed on the node it belongs to: a source fact of the role becomes the new body,
// and a removal leaves no fact of the role.
@(test)
fact_each_role :: proc(t: ^testing.T) {
	for c in ([]struct {
			role: core.Role,
			node: u32,
			src:  string,
		}{
			{.Comment, 1, "[\n//old\n1]"},
			{.Comment_Inline, 1, "[1 //old\n]"},
			{.Comment_Foot, 0, "[1\n//old\n]"},
		}) {
		doc, err := json.build(transmute([]u8)c.src, .Jsonc)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", c.src, err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		if e := core.set_fact(&list, c.node, c.role, transmute([]u8)string("new")); !testing.expect_value(t, e.kind, core.Document_Error_Kind.None) {
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
		body(t, &read, c.node, c.role, "new")
		core.destroy(&read)

		gone := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&gone)
		if e := core.remove_fact(&gone, c.node, c.role); !testing.expect_value(t, e.kind, core.Document_Error_Kind.None) {
			return
		}
		out2, _, err2 := core.commit(&gone, u8(json.Spec.Jsonc))
		defer if len(out2) > 0 {
			delete(out2)
		}
		read2, rerr2 := json.build(out2, .Jsonc)
		it := core.facts_of(&read2, c.node, c.role)
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

// The output spec decides the result. `.Json` drops the comment the edit added and counts it, and `.Jsonc` writes it
// and reads it back with the same body.
@(test)
fact_output_drops :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`), .Json)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, 2, .Comment_Inline, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
	testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Json), `{"a":1}`, 1, .Json))
	if !expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "{\"a\":1 /*c*/}", 0, .Jsonc) {
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

// `set_fact` refuses `.Value` and a key node with `.Bad_Index`, and the same node and role twice with
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
		testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "[2 /*c*/]", 0, .Jsonc))
	}
}

// A fact edit on a node the same list removes is a conflict, whatever the role and whichever edit is recorded first.
@(test)
fact_on_removed_node :: proc(t: ^testing.T) {
	for order in 0 ..< 2 {
		doc, _ := json.build(transmute([]u8)string(`{"a":1,"b":2}`), .Jsonc)
		list := core.edit_list_init(&doc)
		if order == 0 {
			testing.expect_value(t, core.set_fact(&list, 2, .Comment_Inline, transmute([]u8)string("x")).kind, core.Document_Error_Kind.None)
			testing.expect_value(t, core.remove(&list, 2).kind, core.Document_Error_Kind.None)
		} else {
			testing.expect_value(t, core.remove(&list, 2).kind, core.Document_Error_Kind.None)
			testing.expect_value(t, core.set_fact(&list, 2, .Comment_Inline, transmute([]u8)string("x")).kind, core.Document_Error_Kind.None)
		}
		out, _, err := core.commit(&list)
		if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, err.kind == .Conflicting_Edits, "order %d: commit %v", order, err)
		core.edit_list_destroy(&list)
		core.destroy(&doc)
	}
}

// An insert into an enclosing container does not remove a foot on the inner container whose close it precedes.
@(test)
fact_foot_enclosing_insert :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string("[[1\n//f\n],2]"), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.insert(&list, core.ROOT, 2, transmute([]u8)string("3")).kind, core.Document_Error_Kind.None)
	out, dropped, err := core.commit(&list)
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, err.kind == .None && dropped == 0, "commit: %v, %d dropped", err, dropped) {
		return
	}
	read, rerr := json.build(out, .Jsonc)
	defer core.destroy(&read)
	if !testing.expectf(t, rerr.kind == .None, "committed text does not read: %v in %q", rerr, out) {
		return
	}
	body(t, &read, 1, .Comment_Foot, "f")
}

// An insert before a commented member keeps the comment with its member, and an append to a container is written
// before the foot that precedes the container's close.
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
		doc, _ := json.build(transmute([]u8)string(`[[1,2]]`), .Jsonc)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, 1, .Comment_Foot, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.insert(&list, 1, 2, transmute([]u8)string("3")).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_fact_commit(t, &list, u8(json.Spec.Jsonc), "[[1,2,3\n//c\n]]", 0, .Jsonc))
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

// The last member's inline fact stays on the last member when a new member is appended: the append needs no guard
// against the comment, since it writes after the value and the comment.
@(test)
fact_inline_before_append :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`[1,2]`), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set_fact(&list, 2, .Comment_Inline, transmute([]u8)string("c")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.insert(&list, 0, 2, transmute([]u8)string("3")).kind, core.Document_Error_Kind.None)
	out, dropped, err := core.commit(&list)
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, err.kind == .None && dropped == 0, "commit: %v, %d dropped", err, dropped) {
		return
	}
	read, rerr := json.build(out, .Jsonc)
	defer core.destroy(&read)
	if !testing.expectf(t, rerr.kind == .None, "committed text does not read: %v in %q", rerr, out) {
		return
	}
	body(t, &read, 2, .Comment_Inline, "c")
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

// A cut takes the line end before a head comment and an insert writes at its byte. The set body still reads as the
// head of its node, with or without blanks before the comment.
@(test)
fact_head_after_removed_line_end :: proc(t: ^testing.T) {
	for src in ([]string{"//\r[ \"a\"\r/*old*/,\rnull /**/\t,\r]\n\r", "//\r[ \"a\"\r  /*old*/,\rnull /**/\t,\r]\n\r"}) {
		doc, _ := json.build(transmute([]u8)src, .Jsonc)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.remove(&list, 1).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.insert(&list, core.ROOT, 1, transmute([]u8)string("{}")).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.set_fact(&list, 2, .Comment, transmute([]u8)string("two words")).kind, core.Document_Error_Kind.None)
		out, dropped, err := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, err.kind == .None && dropped == 0, "commit: %v, %d dropped", err, dropped)
		read, rerr := json.build(out, .Jsonc)
		defer core.destroy(&read)
		testing.expectf(t, rerr.kind == .None, "read: %v in %q", rerr, out)
		body(t, &read, 2, .Comment, "two words")
	}
}

// A member's inline fact after a trailing comma goes with the removed member, even though the comma stops the
// member's extent before it. The root's own foot is removed by `remove_fact` in the same list.
@(test)
fact_removed_member_takes_its_inline :: proc(t: ^testing.T) {
	src := "[0//x\n,\"\",//\n//\n]"
	doc, err := json.build(transmute([]u8)src, .Jsonc)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	if !body(t, &doc, 2, .Comment_Inline, "") || !body(t, &doc, core.ROOT, .Comment_Foot, "") {
		return
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.remove(&list, 2).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.remove_fact(&list, core.ROOT, .Comment_Foot).kind, core.Document_Error_Kind.None)
	out, dropped, cerr := core.commit(&list, u8(json.Spec.Jsonc))
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, cerr.kind == .None && dropped == 0, "commit: %v, %d dropped", cerr, dropped) {
		return
	}
	if !testing.expectf(t, string(out) == "[0//x\n,\n\n]", "committed %q", out) {
		return
	}
	read, rerr := json.build(out, .Jsonc)
	defer core.destroy(&read)
	if !testing.expectf(t, rerr.kind == .None, "committed text does not read: %v in %q", rerr, out) {
		return
	}
	it := core.facts_of(&read, core.ROOT, .Comment_Foot)
	_, still := core.fact_next(&it)
	testing.expectf(t, !still, "the root still holds a foot fact")
	body(t, &read, 1, .Comment_Inline, "x")
}

// A replaced head or foot fact after a U+2028 line end starts on that line, with no LF added before its marker.
@(test)
fact_u2028_line_start :: proc(t: ^testing.T) {
	{
		doc, err := json.build(transmute([]u8)string("[1,\u2028//old\u20282]"), .Json5)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "build: %v", err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, 2, .Comment, transmute([]u8)string("new")).kind, core.Document_Error_Kind.None)
		out, dropped, cerr := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		if !testing.expectf(t, cerr.kind == .None && dropped == 0, "head: %v, %d dropped", cerr, dropped) {
			return
		}
		testing.expectf(t, string(out) == "[1,\u2028//new\u20282]", "head: committed %q", out)
		read, rerr := json.build(out, .Json5)
		defer core.destroy(&read)
		if !testing.expectf(t, rerr.kind == .None, "head: read: %v in %q", rerr, out) {
			return
		}
		body(t, &read, 2, .Comment, "new")
	}
	{
		doc, err := json.build(transmute([]u8)string("[1\u2028//old\u2028]"), .Json5)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "build: %v", err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set_fact(&list, core.ROOT, .Comment_Foot, transmute([]u8)string("new")).kind, core.Document_Error_Kind.None)
		out, dropped, cerr := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		if !testing.expectf(t, cerr.kind == .None && dropped == 0, "foot: %v, %d dropped", cerr, dropped) {
			return
		}
		testing.expectf(t, string(out) == "[1\u2028//new\u2028]", "foot: committed %q", out)
		read, rerr := json.build(out, .Json5)
		defer core.destroy(&read)
		if !testing.expectf(t, rerr.kind == .None, "foot: read: %v in %q", rerr, out) {
			return
		}
		body(t, &read, core.ROOT, .Comment_Foot, "new")
	}
}
