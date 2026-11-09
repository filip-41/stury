package json_tests

import "core:strings"
import "core:testing"
import core "../../core"
import json ".."
import walktest "../../walktest"

// Tests of fact edits. Each fact role is read, set and removed, and each output's marker and dropped facts are
// checked.

// Commits `list` with the output spec `as`, checks the text against `want` and the dropped count, and builds the text
// as `S`.
expect_fact_commit :: proc(t: ^testing.T, list: ^core.Edit_List, as: json.Spec, want: string, dropped: int, $S: json.Spec) -> bool {
	out, got, err := core.commit(list, json.as(as))
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, err == nil, "commit: %v", err) {
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
	return testing.expectf(t, derr == nil, "committed text does not read: %v", derr)
}

// The three roles are read as follows: a head comment above the root, a block comment after a value, and a line
// comment after the last member of an object, which is the object's foot. A body is the text between the markers.
@(test)
fact_read_roles :: proc(t: ^testing.T) {
	doc, err := json.build(transmute([]u8)string("//head\n{\"a\":1 /*i*/}"), .Jsonc)
	defer core.destroy(&doc)
	if !testing.expectf(t, err == nil, "build: %v", err) {
		return
	}
	if !walktest.body(t, &doc, core.ROOT, .Comment, "head") || !walktest.body(t, &doc, 2, .Comment_Inline, "i") {
		return
	}
	foot, ferr := json.build(transmute([]u8)string("{\"a\":1\n//f\n}"), .Jsonc)
	defer core.destroy(&foot)
	if !testing.expectf(t, ferr == nil, "build: %v", ferr) {
		return
	}
	walktest.body(t, &foot, core.ROOT, .Comment_Foot, "f")
}

// A body with an LF is written as a block comment. An LF in an inline fact's body is refused with `.Bad_Fact`.
@(test)
fact_shapes :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	walktest.expect_nil(t, core.set_fact(&list, core.ROOT, .Comment, string("one\ntwo")))
	walktest.expect_kind(t, core.set_fact(&list, 2, .Comment_Inline, string("a\nb")), core.Document_Error_Kind.Bad_Fact)
	testing.expect(t, expect_fact_commit(t, &list, json.Spec.Jsonc, "/*one\ntwo*/\n{\"a\":1}", 0, .Jsonc))
}

// Every role is set, replaced and removed on the node it belongs to: a source fact of the role becomes the new body,
// and a removal leaves no fact of the role.
@(test)
fact_each_role :: proc(t: ^testing.T) {
	for c in ([]struct {
			role: core.Role,
			node: core.Node_Index,
			src:  string,
		}{
			{.Comment, 1, "[\n//old\n1]"},
			{.Comment_Inline, 1, "[1 //old\n]"},
			{.Comment_Foot, 0, "[1\n//old\n]"},
		}) {
		doc, err := json.build(transmute([]u8)c.src, .Jsonc)
		defer core.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", c.src, err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		if e := core.set_fact(&list, c.node, c.role, string("new")); !walktest.expect_nil(t, e) {
			return
		}
		out, dropped, cerr := core.commit(&list, json.as(.Jsonc))
		defer if len(out) > 0 {
			delete(out)
		}
		if !testing.expectf(t, cerr == nil && dropped == 0, "role %v: %v, %d dropped", c.role, cerr, dropped) {
			return
		}
		read, rerr := json.build(out, .Jsonc)
		if !testing.expectf(t, rerr == nil, "replace does not read: %v in %q", rerr, out) {
			core.destroy(&read)
			return
		}
		walktest.body(t, &read, c.node, c.role, "new")
		core.destroy(&read)

		gone := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&gone)
		if e := core.remove_fact(&gone, c.node, c.role); !walktest.expect_nil(t, e) {
			return
		}
		out2, _, err2 := core.commit(&gone, json.as(.Jsonc))
		defer if len(out2) > 0 {
			delete(out2)
		}
		read2, rerr2 := json.build(out2, .Jsonc)
		it := core.facts_of(&read2, c.node, c.role)
		_, still := core.fact_next(&it)
		testing.expectf(t, err2 == nil && rerr2 == nil && !still, "remove role %v: %v %v %q", c.role, err2, rerr2, out2)
		core.destroy(&read2)
	}
}

// `set_fact` refuses `.Value` and a key node with `.Bad_Index`. A second edit of the same node and role is recorded
// and refused by `commit` with `.Conflicting_Edits`.
@(test)
fact_errors :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	walktest.expect_kind(t, core.set_fact(&list, 1, .Comment, string("c")), core.Document_Error_Kind.Bad_Index)
	walktest.expect_kind(t, core.set_fact(&list, 2, .Value, string("c")), core.Document_Error_Kind.Bad_Index)
	walktest.expect_nil(t, core.set_fact(&list, 2, .Comment, string("c")))
	walktest.expect_nil(t, core.set_fact(&list, 2, .Comment, string("d")))
	_, _, err := core.commit(&list)
	walktest.expect_kind(t, err, core.Document_Error_Kind.Conflicting_Edits)
}

// `Role(200)` is refused with `.Bad_Fact`, not a node error.
@(test)
fact_unknown_role :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`), .Jsonc)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	walktest.expect_kind(t, core.set_fact(&list, 2, core.Role(200), string("c")), core.Document_Error_Kind.Bad_Fact)
}

// A fact edit on a node the same list removes is a conflict, whatever the role and whichever edit is recorded first.
@(test)
fact_on_removed_node :: proc(t: ^testing.T) {
	for order in 0 ..< 2 {
		doc, _ := json.build(transmute([]u8)string(`{"a":1,"b":2}`), .Jsonc)
		list := core.edit_list_init(&doc)
		if order == 0 {
			walktest.expect_nil(t, core.set_fact(&list, 2, .Comment_Inline, string("x")))
			walktest.expect_nil(t, core.remove(&list, 2))
		} else {
			walktest.expect_nil(t, core.remove(&list, 2))
			walktest.expect_nil(t, core.set_fact(&list, 2, .Comment_Inline, string("x")))
		}
		out, _, err := core.commit(&list)
		if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, walktest.document_of(err).kind == .Conflicting_Edits, "order %d: commit %v", order, err)
		core.edit_list_destroy(&list)
		core.destroy(&doc)
	}
}

// An output spec other than the document's reads without the source's tolerance: a JSON5 text committed as `.Json`
// fails with `.Bad_Result` and drops nothing.
@(test)
fact_spec_change_reads_strictly :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string("{a:1}"), .Json5)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	out, dropped, err := core.commit(&list, json.as(.Json))
	defer if len(out) > 0 {
		delete(out)
	}
	walktest.expect_kind(t, err, core.Document_Error_Kind.Bad_Result)
	testing.expect_value(t, dropped, 0)
}

// A member's inline fact after a trailing comma goes with the removed member, even though the comma stops the
// member's extent before it. The root's own foot is removed by `remove_fact` in the same list.
@(test)
fact_removed_member_takes_its_inline :: proc(t: ^testing.T) {
	src := "[0//x\n,\"\",//\n//\n]"
	doc, err := json.build(transmute([]u8)src, .Jsonc)
	defer core.destroy(&doc)
	if !testing.expectf(t, err == nil, "build: %v", err) {
		return
	}
	if !walktest.body(t, &doc, 2, .Comment_Inline, "") || !walktest.body(t, &doc, core.ROOT, .Comment_Foot, "") {
		return
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	walktest.expect_nil(t, core.remove(&list, 2))
	walktest.expect_nil(t, core.remove_fact(&list, core.ROOT, .Comment_Foot))
	out, dropped, cerr := core.commit(&list, json.as(.Jsonc))
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, cerr == nil && dropped == 0, "commit: %v, %d dropped", cerr, dropped) {
		return
	}
	if !testing.expectf(t, string(out) == "[0//x\n]", "committed %q", out) {
		return
	}
	read, rerr := json.build(out, .Jsonc)
	defer core.destroy(&read)
	if !testing.expectf(t, rerr == nil, "committed text does not read: %v in %q", rerr, out) {
		return
	}
	it := core.facts_of(&read, core.ROOT, .Comment_Foot)
	_, still := core.fact_next(&it)
	testing.expectf(t, !still, "the root still holds a foot fact")
	walktest.body(t, &read, 1, .Comment_Inline, "x")
}

Fact_Op_Kind :: enum {
	Set_Fact,
	Remove_Fact,
	Set,
	Insert,
	Remove,
	Reorder,
	Set_Facts,
}

Fact_Op :: struct {
	kind: Fact_Op_Kind,
	node: core.Node_Index,
	role: core.Role,
	at:   int, // the position of an insert, or 1 for padded fact bodies
	text: string, // a reorder's order, one digit per entry, or a fact set's bodies split by `|`
}

Fact_Body :: struct {
	node: core.Node_Index,
	role: core.Role,
	text: string,
}

// A text read as `from`, one list of edits, and the commit as `as`: its text when `want` is set, the count of facts
// dropped, and the one fact `body` names when it is set, read back from the committed text.
Fact_Row :: struct {
	src:     string,
	from:    json.Spec,
	as:      json.Spec,
	ops:     []Fact_Op,
	want:    string,
	dropped: int,
	body:    Maybe(Fact_Body),
}

fact_rows :: proc(t: ^testing.T, rows: []Fact_Row) {
	for r in rows {
		doc, err := json.build(transmute([]u8)r.src, r.from)
		defer core.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", r.src, err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		for op in r.ops {
			e: core.Error
			switch op.kind {
			case .Set_Fact:
				e = core.set_fact(&list, op.node, op.role, op.text, op.at == 1)
			case .Set_Facts:
				e = core.set_facts(&list, op.node, op.role, strings.split(op.text, "|", context.temp_allocator), op.at == 1)
			case .Remove_Fact:
				e = core.remove_fact(&list, op.node, op.role)
			case .Set:
				e = core.set(&list, op.node, op.text)
			case .Insert:
				e = core.insert(&list, op.node, op.at, op.text)
			case .Remove:
				e = core.remove(&list, op.node)
			case .Reorder:
				order: [8]u32
				for c, i in op.text {
					order[i] = u32(c - '0')
				}
				e = core.reorder(&list, op.node, order[:len(op.text)])
			}
			if !testing.expectf(t, e == nil, "%q: record %v", r.src, e) {
				return
			}
		}
		out, dropped, cerr := core.commit(&list, json.as(r.as))
		defer if len(out) > 0 {
			delete(out)
		}
		if !testing.expectf(t, cerr == nil && dropped == r.dropped, "%q: commit %v, %d dropped, want %d", r.src, cerr, dropped, r.dropped) {
			return
		}
		if r.want != "" && !testing.expectf(t, string(out) == r.want, "%q: committed %q, want %q", r.src, out, r.want) {
			return
		}
		read, rerr := json.build(out, r.as)
		defer core.destroy(&read)
		if !testing.expectf(t, rerr == nil, "%q: committed text does not read: %v in %q", r.src, rerr, out) {
			return
		}
		if b, has := r.body.?; has && !walktest.body(t, &read, b.node, b.role, b.text) {
			return
		}
	}
}

// Each fact role is set where the walk reads it back in the same role on the same node, `set_fact` replaces every fact
// of the node and role in place, and `remove_fact` removes them and no other role's.
@(test)
fact_set_and_replace :: proc(t: ^testing.T) {
	fact_rows(t, {
		{`{"a":1}`, .Jsonc, .Jsonc, {{.Set_Fact, 2, .Comment, 0, "c"}}, "{\n//c\n\"a\":1}", 0, Fact_Body{2, .Comment, "c"}},
		{`{"a":1}`, .Jsonc, .Jsonc, {{.Set_Fact, 2, .Comment_Inline, 0, "c"}}, "{\"a\":1 /*c*/}", 0, Fact_Body{2, .Comment_Inline, "c"}},
		{`{"a":1}`, .Jsonc, .Jsonc, {{.Set_Fact, 0, .Comment_Foot, 0, "c"}}, "{\"a\":1}\n//c\n", 0, Fact_Body{0, .Comment_Foot, "c"}},
		{"//old\n{\"a\":1}", .Jsonc, .Jsonc, {{.Set_Fact, core.ROOT, .Comment, 0, "new"}}, "//new\n{\"a\":1}", 0, Fact_Body{core.ROOT, .Comment, "new"}},
		// Two head comments are one fact of the node and role. Both are removed and one comment replaces them.
		{"//one\n//two\n[1]", .Jsonc, .Jsonc, {{.Set_Fact, core.ROOT, .Comment, 0, "new"}}, "", 0, Fact_Body{core.ROOT, .Comment, "new"}},
		{"{\"a\":1}\n//foot", .Jsonc, .Jsonc, {{.Remove_Fact, core.ROOT, .Comment_Foot, 0, ""}}, "{\"a\":1}\n", 0, nil},
		// A U+2028 line end starts the line of a replaced head or foot fact, with no LF added before its marker.
		{"[1,\u2028//old\u20282]", .Json5, .Json5, {{.Set_Fact, 2, .Comment, 0, "new"}}, "[1,\u2028//new\u20282]", 0, Fact_Body{2, .Comment, "new"}},
		{"[1\u2028//old\u2028]", .Json5, .Json5, {{.Set_Fact, core.ROOT, .Comment_Foot, 0, "new"}}, "[1\u2028//new\u2028]", 0, Fact_Body{core.ROOT, .Comment_Foot, "new"}},
		// U+2028 and U+2029 in a body count as a line end under both specs, since a JSON5 line comment ends at them. The
		// body is written as a block comment, and neither fact is dropped.
		{`{"a":1}`, .Jsonc, .Jsonc, {{.Set_Fact, core.ROOT, .Comment, 0, "one\u2028two"}, {.Set_Fact, 2, .Comment_Inline, 0, "a\u2029b"}}, "/*one\u2028two*/\n{\"a\":1 /*a\u2029b*/}", 0, nil},
		{`{"a":1}`, .Json5, .Json5, {{.Set_Fact, core.ROOT, .Comment, 0, "one\u2028two"}, {.Set_Fact, 2, .Comment_Inline, 0, "a\u2029b"}}, "/*one\u2028two*/\n{\"a\":1 /*a\u2029b*/}", 0, nil},
		// A body holding a line end and `*/` cannot be written as a comment, so it is dropped and counted. An inline fact
		// after a value that ends its line writes no second line end.
		{`{"a":1}`, .Jsonc, .Jsonc, {{.Set_Fact, 2, .Comment, 0, "x\n*/"}}, `{"a":1}`, 1, nil},
		{"{\n\"a\":1\n}", .Jsonc, .Jsonc, {{.Set_Fact, 2, .Comment_Inline, 0, "c"}}, "{\n\"a\":1 //c\n}", 0, nil},
		// The output spec decides the result: `.Json` drops the comment the edit added and counts it.
		{`{"a":1}`, .Json, .Json, {{.Set_Fact, 2, .Comment_Inline, 0, "c"}}, `{"a":1}`, 1, nil},
		{`{"a":1}`, .Json, .Jsonc, {{.Set_Fact, 2, .Comment_Inline, 0, "c"}}, "{\"a\":1 /*c*/}", 0, Fact_Body{2, .Comment_Inline, "c"}},
	})
}

// A fact beside an edit of a neighbour or of the container keeps its member: a removed neighbour, an insert before a
// commented member, an append that precedes a foot or follows an inline fact, a cut that takes a line end before a
// head comment, and an insert into an enclosing container.
@(test)
fact_beside_edits :: proc(t: ^testing.T) {
	fact_rows(t, {
		{`{"a" /*c*/: 1}`, .Jsonc, .Jsonc, {{.Set, 2, .Value, 0, "2"}}, `{"a" /*c*/: 2}`, 0, nil},
		{`[1,2]`, .Jsonc, .Jsonc, {{.Set_Fact, 2, .Comment, 0, "c"}, {kind = .Remove, node = 1}}, "[\n//c\n2]", 0, nil},
		{`[1,2]`, .Jsonc, .Jsonc, {{.Set_Fact, 2, .Comment_Inline, 0, "c"}, {kind = .Remove, node = 1}}, "[2 /*c*/]", 0, nil},
		// The removal takes the comma the fact's line led, so the fact is written at the value's end.
		{`[1,2]`, .Jsonc, .Jsonc, {{.Set_Fact, 1, .Comment_Inline, 0, "x"}, {kind = .Remove, node = 2}}, "[1 /*x*/]", 0, Fact_Body{1, .Comment_Inline, "x"}},
		{`[1,2]`, .Jsonc, .Jsonc, {{.Set_Fact, 2, .Comment, 0, "c"}, {.Insert, 0, .Value, 1, "0"}}, "[1,0,\n//c\n2]", 0, nil},
		{`[[1,2]]`, .Jsonc, .Jsonc, {{.Set_Fact, 1, .Comment_Foot, 0, "c"}, {.Insert, 1, .Value, 2, "3"}}, "[[1,2,3\n//c\n]]", 0, nil},
		{`[1,2]`, .Jsonc, .Jsonc, {{.Set_Fact, 2, .Comment_Inline, 0, "c"}, {.Insert, 0, .Value, 2, "3"}}, "", 0, Fact_Body{2, .Comment_Inline, "c"}},
		{"[[1\n//f\n],2]", .Jsonc, .Jsonc, {{.Insert, core.ROOT, .Value, 2, "3"}}, "", 0, Fact_Body{1, .Comment_Foot, "f"}},
		{"//\r[ \"a\"\r/*old*/,\rnull /**/\t,\r]\n\r", .Jsonc, .Jsonc, {{kind = .Remove, node = 1}, {.Insert, core.ROOT, .Value, 1, "{}"}, {.Set_Fact, 2, .Comment, 0, "two words"}}, "", 0, Fact_Body{2, .Comment, "two words"}},
		{"//\r[ \"a\"\r  /*old*/,\rnull /**/\t,\r]\n\r", .Jsonc, .Jsonc, {{kind = .Remove, node = 1}, {.Insert, core.ROOT, .Value, 1, "{}"}, {.Set_Fact, 2, .Comment, 0, "two words"}}, "", 0, Fact_Body{2, .Comment, "two words"}},
	})
}

// A fact edit inside a reordered container applies to its member wherever the order puts it: a head comment moves with
// its member, an inline comment is written after the member's value, and a container's foot stays before its close. A
// removed comment alone on its line takes the line. The read-back text holds the members in the new order.
@(test)
fact_in_reordered_container :: proc(t: ^testing.T) {
	src := "[\n  //a\n  1, //b\n  2\n  //f\n]"
	fact_rows(t, {
		{src, .Jsonc, .Jsonc, {{kind = .Reorder, node = core.ROOT, text = "10"}, {.Set_Fact, 1, .Comment, 0, "moved"}}, "[\n  2,\n  //moved\n  1 //b\n  //f\n]", 0, Fact_Body{2, .Comment, "moved"}},
		{src, .Jsonc, .Jsonc, {{kind = .Reorder, node = core.ROOT, text = "10"}, {.Remove_Fact, 1, .Comment, 0, ""}}, "[\n  2,\n  1 //b\n  //f\n]", 0, nil},
		{src, .Jsonc, .Jsonc, {{kind = .Reorder, node = core.ROOT, text = "10"}, {.Set_Fact, 1, .Comment_Inline, 0, "one"}}, "[\n  2,\n  //a\n  1 //one\n  //f\n]", 0, Fact_Body{2, .Comment_Inline, "one"}},
		{src, .Jsonc, .Jsonc, {{kind = .Reorder, node = core.ROOT, text = "10"}, {.Remove_Fact, 1, .Comment_Inline, 0, ""}}, "[\n  2,\n  //a\n  1\n  //f\n]", 0, nil},
		{src, .Jsonc, .Jsonc, {{kind = .Reorder, node = core.ROOT, text = "10"}, {.Set_Fact, 2, .Comment, 0, "two"}}, "[\n  //two\n  2,\n  //a\n  1 //b\n  //f\n]", 0, Fact_Body{1, .Comment, "two"}},
		{src, .Jsonc, .Jsonc, {{kind = .Reorder, node = core.ROOT, text = "10"}, {.Set_Fact, core.ROOT, .Comment_Foot, 0, "g"}}, "[\n  2,\n  //a\n  1 //b\n  //g\n]", 0, Fact_Body{core.ROOT, .Comment_Foot, "g"}},
		{src, .Jsonc, .Jsonc, {{kind = .Reorder, node = core.ROOT, text = "10"}, {.Remove_Fact, core.ROOT, .Comment_Foot, 0, ""}}, "[\n  2,\n  //a\n  1 //b\n]", 0, nil},
		{`[1,2]`, .Jsonc, .Jsonc, {{kind = .Reorder, node = core.ROOT, text = "10"}, {.Set_Fact, 1, .Comment_Inline, 0, "x"}}, "[2,1 /*x*/]", 0, Fact_Body{2, .Comment_Inline, "x"}},
	})
}

// A fact set of several bodies writes them in order: a head or a foot one to a line in the line's indent, and an inline
// set on the value's line, block comments before the last. A padded body has one space inside each marker.
@(test)
fact_sets :: proc(t: ^testing.T) {
	fact_rows(t, {
		{"{\n  //old\n  \"a\": 1\n}", .Jsonc, .Jsonc, {{.Set_Facts, 2, .Comment, 1, "x|y"}}, "{\n  // x\n  // y\n  \"a\": 1\n}", 0, nil},
		{`{"a":1}`, .Jsonc, .Jsonc, {{.Set_Facts, 2, .Comment, 0, "x|y"}}, "{\n//x\n//y\n\"a\":1}", 0, nil},
		{`{"a":1}`, .Jsonc, .Jsonc, {{.Set_Facts, 2, .Comment_Inline, 1, "x|y"}}, "{\"a\":1 /* x */ /* y */}", 0, nil},
		{"{\n\"a\":1\n}", .Jsonc, .Jsonc, {{.Set_Facts, 2, .Comment_Inline, 1, "x|y"}}, "{\n\"a\":1 /* x */ // y\n}", 0, nil},
		{`[1]`, .Jsonc, .Jsonc, {{.Set_Facts, core.ROOT, .Comment_Foot, 1, "x|y"}}, "[1]\n// x\n// y\n", 0, nil},
		{"[\n  [1\n  ]\n]", .Jsonc, .Jsonc, {{.Set_Facts, 1, .Comment_Foot, 1, "x|y"}}, "[\n  [1\n  // x\n  // y\n  ]\n]", 0, nil},
		{`{"a":1}`, .Jsonc, .Jsonc, {{.Set_Fact, 2, .Comment_Inline, 1, "c"}}, "{\"a\":1 /* c */}", 0, Fact_Body{2, .Comment_Inline, " c "}},
		{"[\n  1, // one\n  2\n]", .Jsonc, .Jsonc, {{kind = .Reorder, node = core.ROOT, text = "10"}, {.Set_Facts, 1, .Comment_Inline, 1, "x|y"}}, "[\n  2,\n  1 /* x */ // y\n]", 0, nil},
		{"[\n  1,\n  2\n]", .Jsonc, .Jsonc, {{kind = .Reorder, node = core.ROOT, text = "10"}, {.Set_Facts, 1, .Comment, 1, "x|y"}}, "[\n  2,\n  // x\n  // y\n  1\n]", 0, nil},
		// A block comment cannot hold `*/`, so an inline body holding it is dropped unless it is the last.
		{`{"a":1}`, .Jsonc, .Jsonc, {{.Set_Facts, 2, .Comment_Inline, 0, "x*/|y"}}, "{\"a\":1 /*y*/}", 1, nil},
	})
}
