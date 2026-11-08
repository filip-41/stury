package json_tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import json ".."
import walktest "../../walktest"

// The edit list: `set`, `insert` and `remove` recorded against an unchanged document, and `commit` splicing them into
// a new text. `expect_commit` compares the bytes and reads them back.

@(private = "file")
read_json :: proc(src: []u8, spec: any) -> (core.Document, core.Document_Error) {
	switch spec.(json.Spec) {
	case .Json:
		return json.build(src, .Json)
	case .Jsonc:
		return json.build(src, .Jsonc)
	case .Json5:
		return json.build(src, .Json5)
	}
	return {}, {kind = .Bad_Value}
}

// Commits `list`, checks the output against `want`, then builds the output as `S` and checks that it reads.
expect_commit :: proc(t: ^testing.T, list: ^core.Edit_List, want: string, $S: json.Spec) -> bool {
	return walktest.expect_commit(t, list, want, read_json, S)
}

@(private = "file")
Edit_Op :: enum {
	Set,
	Insert, // `at` is the position in the array `node`
	Remove,
}

@(private = "file")
Edit_Row :: struct {
	src, want: string,
	op:        Edit_Op,
	node:      core.Node_Index, // the node set or removed, or the array inserted into
	at:        int,
	key:       string, // for an insert into a map
	text:      string,
}

// Applies each row's one edit to a document read as `S` and checks the committed text.
@(private = "file")
edit_rows :: proc(t: ^testing.T, $S: json.Spec, rows: []Edit_Row) {
	for r in rows {
		doc, err := read_json(transmute([]u8)r.src, S)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", r.src, err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		e: core.Document_Error
		switch r.op {
		case .Set:
			e = core.set(&list, r.node, r.text)
		case .Insert:
			if r.key != "" {
				e = core.insert(&list, r.node, r.at, r.key, r.text)
			} else {
				e = core.insert(&list, r.node, r.at, r.text)
			}
		case .Remove:
			e = core.remove(&list, r.node)
		}
		testing.expect_value(t, e.kind, core.Document_Error_Kind.None)
		expect_commit(t, &list, r.want, S)
	}
}

// `set` on a value, a key, a container and the root: the node's bytes become the new text and every other byte stays,
// number spellings included.
@(test)
edit_set :: proc(t: ^testing.T) {
	edit_rows(t, .Json, {
		{`[1,2,3]`, `[1,20,3]`, .Set, 2, 0, "", "20"},
		{`{ "a" : 1e2 , "b" : 2.50 }`, `{ "a" : 1e2 , "b" : 3 }`, .Set, 4, 0, "", "3"},
		{`{"a":1}`, `{"b":1}`, .Set, 1, 0, "", `b`},
		{`{"a":1}`, `{"a":[1]}`, .Set, 2, 0, "", "[1]"},
		{`{"a":1}`, `{"a":2}`, .Set, 0, 0, "", `{"a":2}`},
		{`1`, `{"x":[true,null]}`, .Set, 0, 0, "", `{"x":[true,null]}`},
		{`"x"`, `"y\n"`, .Set, 0, 0, "", `"y\n"`},
	})
	// A JSONC set keeps the `/*c*/` beside the key, and a JSON5 key is written as a string from its decoded name.
	edit_rows(t, .Jsonc, {{`{"a" /*c*/: 1}`, `{"a" /*c*/: 2}`, .Set, 2, 0, "", "2"}})
	edit_rows(t, .Json5, {{`{a: 1}`, `{a: 2}`, .Set, 2, 0, "", "2"}, {`{a: 1}`, `{"b": 1}`, .Set, 1, 0, "", `b`}})
}

// `insert` into an array at the first, a middle and the last place, and into an empty array: the separator is written
// on the side nearer the member it joins.
@(test)
edit_insert_array :: proc(t: ^testing.T) {
	edit_rows(t, .Json, {
		{`[1,2]`, `[0,1,2]`, .Insert, 0, 0, "", "0"},
		{`[1,2]`, `[1,0,2]`, .Insert, 0, 1, "", "0"},
		{`[1,2]`, `[1,2,0]`, .Insert, 0, 2, "", "0"},
		{`[]`, `[0]`, .Insert, 0, 0, "", "0"},
		{`[ ]`, `[ 0]`, .Insert, 0, 0, "", "0"},
		{`[[]]`, `[[0]]`, .Insert, 1, 0, "", "0"},
		// An insert follows the container's own spacing: the whitespace after its separator.
		{`["a", true]`, `["a", true, [1,2]]`, .Insert, 0, 2, "", "[1,2]"},
	})
	// A JSONC entry is written at the member's first byte, and a comment before the next member stays with that member. A
	// JSON5 trailing comma becomes the separator between the last member and the new one.
	edit_rows(t, .Jsonc, {{`[1, /* two */ 2]`, `[0, 1, /* two */ 2]`, .Insert, 0, 0, "", "0"}})
	edit_rows(t, .Json5, {{`[1,2,]`, `[1,2,0,]`, .Insert, 0, 2, "", "0"}, {`[1,2,]`, `[0,1,2,]`, .Insert, 0, 0, "", "0"}})
}

// A JSONC comment that holds U+2028 or U+2029 ends at the line feed, not at that byte, so an insert at the start and
// an append land inside the container.
@(test)
edit_line_separator_comment :: proc(t: ^testing.T) {
	edit_rows(t, .Jsonc, {
		{"{\"a\":1 // x\u2028y\n}", "{\"b\":2,\"a\":1 // x\u2028y\n}", .Insert, 0, 0, "b", "2"},
		{"{\"a\":1 // x\u2028y\n}", "{\"a\":1, // x\u2028y\n\"b\":2\n}", .Insert, 0, 1, "b", "2"},
		{"[1 // x\u2029y\n]", "[0,1 // x\u2029y\n]", .Insert, 0, 0, "", "0"},
	})
}

// A JSONC line comment that holds U+2028 or U+2029 ends at the line feed. Committed as JSON5, which ends it at that
// byte, the character is respelled as text and a string's own stays.
@(test)
edit_line_separator_comment_as_json5 :: proc(t: ^testing.T) {
	src := "{\"s\":\"a b\", // x y z\n\"a\":1 // w \n}"
	want := "{\"s\":\"a b\", // x\\u2028y\\u2029z\n\"a\":2 // w\\u2028\n}"
	doc, err := json.build(transmute([]u8)src, .Jsonc)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "%v", err) {
		return
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set(&list, 4, "2").kind, core.Document_Error_Kind.None)
	out, _, e := core.commit(&list, json.as(.Json5))
	defer delete(out)
	testing.expect_value(t, e.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, string(out), want)
	_, bad := json.validate(out, .Json5).?
	testing.expect(t, !bad)
}

// `insert` of a member at the first, a middle and the last place, and into an empty object: the key and value are
// joined by the format's key separator.
@(test)
edit_insert_member :: proc(t: ^testing.T) {
	edit_rows(t, .Json, {
		{`{"a":1}`, `{"b":2,"a":1}`, .Insert, 0, 0, "b", "2"},
		{`{"a":1,"c":3}`, `{"a":1,"b":2,"c":3}`, .Insert, 0, 1, "b", "2"},
		{`{"a":1}`, `{"a":1,"b":2}`, .Insert, 0, 1, "b", "2"},
		{`{}`, `{"b":2}`, .Insert, 0, 0, "b", "2"},
		{`{"a":{"x":1}}`, `{"a":{"x":1,"y":[2]}}`, .Insert, 2, 1, "y", "[2]"},
		// A repeated key is an ordinary member: `insert` appends it and the document keeps both in source order.
		{`{"a":1}`, `{"a":1,"a":2}`, .Insert, 0, 1, "a", "2"},
		// The new member takes the line, indent and space after the key separator of the container's members.
		{"{\r\n  \"a\": 1\r\n}", "{\r\n  \"a\": 1,\r\n  \"b\": [ ]\r\n}", .Insert, 0, 1, "b", "[ ]"},
	})
	edit_rows(t, .Json5, {{`{a:1}`, `{a:1,"b":2}`, .Insert, 0, 1, "b", "2"}})
}

// A key is a decoded name, so a quote, a backslash, a line feed and a control byte are written escaped, by `set` on a
// key node and by a member `insert` alike.
@(test)
edit_key_spelling :: proc(t: ^testing.T) {
	edit_rows(t, .Json, {
		{`{"x":1}`, `{"a\"b\\c\nd\u0001":1}`, .Set, 1, 0, "", "a\"b\\c\nd\x01"},
		{`{"x":1}`, `{"x":1,"a\"b\\c\nd\u0001":2}`, .Insert, 0, 1, "a\"b\\c\nd\x01", "2"},
	})
}

// `remove` of a member at the first, a middle and the last place, and of the only member: its key and one separator go
// with it, and an emptied container keeps just its brackets.
@(test)
edit_remove :: proc(t: ^testing.T) {
	edit_rows(t, .Json, {
		{`[1,2,3]`, `[2,3]`, .Remove, 1, 0, "", ""},
		{`[1,2,3]`, `[1,3]`, .Remove, 2, 0, "", ""},
		{`[1,2,3]`, `[1,2]`, .Remove, 3, 0, "", ""},
		{`[1]`, `[]`, .Remove, 1, 0, "", ""},
		{`[ 1 ]`, `[]`, .Remove, 1, 0, "", ""},
		{`{"a":1}`, `{}`, .Remove, 2, 0, "", ""},
		{`{"a":1,"b":2}`, `{"b":2}`, .Remove, 2, 0, "", ""},
		{`{"a":1,"b":2}`, `{"a":1}`, .Remove, 4, 0, "", ""},
		{`{"a":[1,2],"b":3}`, `{"a":[1],"b":3}`, .Remove, 4, 0, "", ""},
	})
	// Removing a JSONC member removes its own head comment above it and inline comment after it. A `//` comment after
	// the last member keeps its line end, so the close bracket is not commented out.
	edit_rows(t, .Jsonc, {
		{"[1,\n  /* head */\n  2\n]", "[1\n]", .Remove, 2, 0, "", ""},
		{`[1 /* a */, 2]`, `[2]`, .Remove, 1, 0, "", ""},
		{`[1, 2 /* b */]`, `[1]`, .Remove, 2, 0, "", ""},
		{"[1, 2 // b\n]", "[1\n]", .Remove, 2, 0, "", ""},
	})
	edit_rows(t, .Json5, {{`[1,2,]`, `[1,]`, .Remove, 2, 0, "", ""}, {`{a:1,b:2,}`, `{a:1,}`, .Remove, 4, 0, "", ""}})
}

// The list's allocator holds the log as well as each edit's copy, so one `set` makes both allocations there.
@(test)
edit_log_uses_list_allocator :: proc(t: ^testing.T) {
	doc, err := json.build(transmute([]u8)string(`[1]`), .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	list := core.edit_list_init(&doc, mem.tracking_allocator(&track))
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set(&list, 1, string("2")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, len(track.allocation_map), 2)
}

// `commit` on edits in different subtrees, on two adjacent members, on an insert that conflicts with a removal, and on
// two inserts at one position.
@(test)
edit_mixed :: proc(t: ^testing.T) {
	{
		doc, err := json.build(transmute([]u8)string(`{"a":[1,2],"b":{"c":3},"d":[4]}`), .Json)
		defer core.destroy(&doc)
		testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set(&list, 2, string(`[9]`)).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.set(&list, 8, string("30")).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.remove(&list, 10).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_commit(t, &list, `{"a":[9],"b":{"c":30}}`, .Json))
	}
	{
		// Removing adjacent members 2 and 3 leaves `[1,4]`: the separator between them is removed once.
		doc, _ := json.build(transmute([]u8)string(`[1,2,3,4]`), .Json)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.remove(&list, 2).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.remove(&list, 3).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_commit(t, &list, `[1,4]`, .Json))
	}
	{
		// An insert at position 1 lies in the removal's run, so it moves to the cut end: `[1,9,3]`.
		doc, _ := json.build(transmute([]u8)string(`[1,2,3]`), .Json)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.remove(&list, 2).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.insert(&list, 0, 1, string("9")).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_commit(t, &list, `[1,9,3]`, .Json))
	}
	{
		// Two inserts at position 0 keep their recorded order: `[7,8,1]`.
		doc, _ := json.build(transmute([]u8)string(`[1]`), .Json)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.insert(&list, 0, 0, string("7")).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.insert(&list, 0, 0, string("8")).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_commit(t, &list, `[7,8,1]`, .Json))
	}
}

// `reorder` moves each member with its bytes and comments, keeps the gaps and the trailing comma in their places, and
// commits with an edit inside a moved member, a removal and an insert.
@(test)
edit_reorder :: proc(t: ^testing.T) {
	Case :: struct {
		src, want: string,
		spec:      json.Spec,
		order:     []u32,
		set:       core.Node_Index, // a node set to `text`, or 0 for none
		remove:    core.Node_Index, // a member removed, or 0 for none
		text, key: string, // a member inserted at the end when `key` is not empty, else the set's text
	}
	cases := []Case{
		{`{"b":1,"a":2}`, `{"a":2,"b":1}`, .Json, {1, 0}, 0, 0, "", ""},
		{"[\n  1,\n  2,\n  3\n]", "[\n  3,\n  2,\n  1\n]", .Json, {2, 1, 0}, 0, 0, "", ""},
		{"{\n  \"b\": 1, // bee\n  \"a\": 2 // ay\n}", "{\n  \"a\": 2, // ay\n  \"b\": 1 // bee\n}", .Jsonc, {1, 0}, 0, 0, "", ""},
		{"{\n  \"b\": 1,\n  // head a\n  \"a\": 2,\n}", "{\n  // head a\n  \"a\": 2,\n  \"b\": 1,\n}", .Jsonc, {1, 0}, 0, 0, "", ""},
		{`{"b":[1],"a":2}`, `{"a":2,"b":[9]}`, .Json, {1, 0}, 3, 0, "9", ""},
		{`{"a":1,"b":2,"c":3}`, `{"c":3,"x":0,"a":1}`, .Json, {2, 3, 0}, 0, 4, "0", "x"},
	}
	for c in cases {
		doc, err := read_json(transmute([]u8)c.src, c.spec)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", c.src, err) {
			continue
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		if c.set != 0 {
			testing.expect_value(t, core.set(&list, c.set, c.text).kind, core.Document_Error_Kind.None)
		}
		if c.remove != 0 {
			testing.expect_value(t, core.remove(&list, c.remove).kind, core.Document_Error_Kind.None)
		}
		if c.key != "" {
			testing.expect_value(t, core.insert(&list, 0, int(core.length(&doc, 0)), c.key, c.text).kind, core.Document_Error_Kind.None)
		}
		testing.expect_value(t, core.reorder(&list, 0, c.order).kind, core.Document_Error_Kind.None)
		switch c.spec {
		case .Json:  expect_commit(t, &list, c.want, .Json)
		case .Jsonc: expect_commit(t, &list, c.want, .Jsonc)
		case .Json5: expect_commit(t, &list, c.want, .Json5)
		}
	}
	// An order that names a member twice, leaves a surviving one out, or names a removed one is refused.
	doc, _ := json.build(transmute([]u8)string(`[1,2,3]`), .Json)
	defer core.destroy(&doc)
	bad := [][]u32{{0, 0, 1}, {0, 1}, {0, 1, 2}}
	for order, i in bad {
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		if i == 2 {
			core.remove(&list, 2)
		}
		testing.expect_value(t, core.reorder(&list, 0, order).kind, core.Document_Error_Kind.None)
		out, _, e := core.commit(&list)
		testing.expectf(t, e.kind == .Bad_Index, "%v: commit %v", order, e.kind)
		if len(out) > 0 {
			delete(out)
		}
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.reorder(&list, 1, {0}).kind, core.Document_Error_Kind.Wrong_Container)
}

// The conflicts `commit` refuses: two edits of one node, an edit inside a replaced value, an insert inside a removed
// member, and a set of a container with an insert inside it.
@(test)
edit_conflicts :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":[1,2],"b":3}`), .Json)
	defer core.destroy(&doc)
	Case :: struct {
		name: string,
		edits: []struct {
			node: core.Node_Index,
			op:   u8,
			text: string,
		},
	}
	cases := []Case{
		{"set twice", {{2, 0, "9"}, {2, 0, "8"}}},
		{"set and remove", {{2, 0, "9"}, {2, 3, ""}}},
		{"remove twice", {{2, 3, ""}, {2, 3, ""}}},
		{"set a node and its parent", {{0, 0, `{}`}, {2, 0, "9"}}},
		{"set a node and its child", {{2, 0, `[9]`}, {3, 0, "9"}}},
		{"remove a member and set inside it", {{2, 3, ""}, {4, 0, "9"}}},
		{"remove a member and insert inside it", {{2, 3, ""}, {3, 0, "9"}}},
		{"set a container and insert inside it", {{2, 0, `[9]`}, {2, 0, "9"}}},
	}
	for c in cases {
		list := core.edit_list_init(&doc)
		ok := true
		for e in c.edits {
			res: core.Document_Error
			switch e.op {
			case 0:
				res = core.set(&list, e.node, e.text)
			case 1:
				res = core.insert(&list, e.node, 0, e.text)
			case:
				res = core.remove(&list, e.node)
			}
			ok &&= testing.expectf(t, res.kind == .None, "%s: record %v", c.name, res)
		}
		if ok {
			out, _, e := core.commit(&list)
			testing.expectf(t, e.kind == .Conflicting_Edits, "%s: commit %v", c.name, e.kind)
			if len(out) > 0 {
				delete(out)
			}
		}
		core.edit_list_destroy(&list)
	}
}

// Each refused edit returns its error kind and leaves `list.edits` empty.
@(test)
edit_errors :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":[1,2]}`), .Json)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set(&list, 99, string("1")).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, core.set(&list, 2, string("1 // c")).kind, core.Document_Error_Kind.Bad_Value)
	testing.expect_value(t, core.set(&list, 2, string("[1] /* c */")).kind, core.Document_Error_Kind.Bad_Value)
	testing.expect_value(t, core.set(&list, 2, string("")).kind, core.Document_Error_Kind.Bad_Value)
	testing.expect_value(t, core.insert(&list, 1, 0, string("1")).kind, core.Document_Error_Kind.Wrong_Container)
	testing.expect_value(t, core.insert(&list, 0, 0, string("1")).kind, core.Document_Error_Kind.Wrong_Container)
	testing.expect_value(t, core.insert(&list, 2, 3, string("1")).kind, core.Document_Error_Kind.Bad_Position)
	testing.expect_value(t, core.insert(&list, 2, -1, string("1")).kind, core.Document_Error_Kind.Bad_Position)
	testing.expect_value(t, core.insert(&list, 2, 2, string("k"), string("1")).kind, core.Document_Error_Kind.Wrong_Container)
	testing.expect_value(t, core.remove(&list, 0).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, core.remove(&list, 1).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, core.remove(&list, 99).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, len(list.edits), 0)

	// JSON5 refuses a comment after a value.
	j5, _ := json.build(transmute([]u8)string(`{a:1}`), .Json5)
	defer core.destroy(&j5)
	l5 := core.edit_list_init(&j5)
	defer core.edit_list_destroy(&l5)
	testing.expect_value(t, core.insert(&l5, 0, 1, string("b"), string("2")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.set(&l5, 2, string("1 /*c*/")).kind, core.Document_Error_Kind.Bad_Value)
	testing.expect_value(t, core.set(&l5, 2, string("0x10")).kind, core.Document_Error_Kind.None)

	// A commit of no edit returns a copy of the source, at a different address.
	empty := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&empty)
	out, _, e := core.commit(&empty)
	defer delete(out)
	testing.expect_value(t, e.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, string(out), `{"a":[1,2]}`)
	testing.expect(t, raw_data(out) != raw_data(doc.src))
}

// Two lists over one document commit separately, and a commit leaves the document's source and spans unchanged.
@(test)
edit_document_unchanged :: proc(t: ^testing.T) {
	src := `{"a":[1,2],"b":"x"}`
	doc, _ := json.build(transmute([]u8)src, .Json)
	defer core.destroy(&doc)
	spans: [8]string
	for i in 0 ..< len(doc.nodes) {
		spans[i] = string(core.span(&doc, core.Node_Index(i)))
	}
	one := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&one)
	two := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&two)
	testing.expect_value(t, core.set(&one, 2, string(`[9]`)).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.set(&two, 6, string(`"y"`)).kind, core.Document_Error_Kind.None)
	testing.expect(t, expect_commit(t, &one, `{"a":[9],"b":"x"}`, .Json))
	testing.expect(t, expect_commit(t, &two, `{"a":[1,2],"b":"y"}`, .Json))

	testing.expect_value(t, string(doc.src), src)
	for i in 0 ..< len(doc.nodes) {
		testing.expectf(t, string(core.span(&doc, core.Node_Index(i))) == spans[i], "node %d changed", i)
	}
	v, ok := core.member(&doc, 0, "a")
	testing.expect(t, ok)
	testing.expect_value(t, v, core.Node_Index(2))
	testing.expect_value(t, core.length(&doc, 2), 2)
}

// With a tracking allocator on the list, every edit copy and the commit's output are freed, and no allocation is left.
@(test)
edit_no_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	src := `{"a":[1,2],"b":{"c":3}}`
	doc, err := json.build(transmute([]u8)src, .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	list := core.edit_list_init(&doc, allocator = alloc)
	testing.expect_value(t, core.set(&list, 4, string("9")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.insert(&list, 2, 2, string("3")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.insert(&list, 0, 2, string("d"), string("4")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.remove(&list, 8).kind, core.Document_Error_Kind.None)
	out, _, cerr := core.commit(&list, allocator = alloc)
	testing.expect_value(t, cerr.kind, core.Document_Error_Kind.None)
	delete(out, allocator = alloc)
	core.edit_list_destroy(&list)
	testing.expectf(t, len(track.allocation_map) == 0, "%d allocations left", len(track.allocation_map))
}


// Checks the code and message of each error kind in `cases`. A conflict at commit names the byte where the second edit
// starts, 1.
@(test)
edit_error_codes :: proc(t: ^testing.T) {
	cases := []struct {
		kind:    core.Document_Error_Kind,
		code:    string,
		message: string,
	}{
		{.Bad_Index, "document.bad_index", "The node takes no such edit"},
		{.Bad_Position, "document.bad_position", "Insert position is past the container"},
		{.Wrong_Container, "document.wrong_container", "The container takes the other insert form"},
		{.Bad_Value, "document.bad_value", "Not one value of the format"},
		{.Bad_Spec, "document.bad_spec", "The commit cannot write that spec"},
		{.Bad_Width, "document.bad_width", "The edit would break the table's width"},
		{.Bad_Result, "document.bad_result", "The edited text does not read"},
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for c in cases {
		strings.builder_reset(&b)
		e := core.Document_Error{kind = c.kind}
		core.write_code(strings.to_writer(&b), e)
		testing.expectf(t, strings.to_string(b) == c.code, "%v: code %q, want %q", c.kind, strings.to_string(b), c.code)
		strings.builder_reset(&b)
		core.render(strings.to_writer(&b), transmute([]u8)string(""), e)
		testing.expectf(t, strings.to_string(b) == c.message, "%v: message %q, want %q", c.kind, strings.to_string(b), c.message)
	}

	// The conflict names byte 1, where the second set of node 1 starts.
	doc, _ := json.build(transmute([]u8)string(`[1,2]`), .Json)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set(&list, 1, string("8")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.set(&list, 1, string("9")).kind, core.Document_Error_Kind.None)
	_, _, e := core.commit(&list)
	testing.expect_value(t, e.kind, core.Document_Error_Kind.Conflicting_Edits)
	testing.expect_value(t, e.at, u64(1))
	strings.builder_reset(&b)
	core.write_code(strings.to_writer(&b), e)
	testing.expect_value(t, strings.to_string(b), "document.conflicting_edits")
	strings.builder_reset(&b)
	core.render(strings.to_writer(&b), doc.src, e)
	testing.expect_value(t, strings.to_string(b), "1:2: Edits conflict")
}

// A value that starts with a byte-order mark is refused when recorded, because a splice writes it after other bytes.
@(test)
edit_value_bom :: proc(t: ^testing.T) {
	doc, err := json.build(transmute([]u8)string(`[1,2]`), .Jsonc)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	bom := []u8{0xEF, 0xBB, 0xBF, '2'}
	testing.expect_value(t, core.set(&list, 1, string(bom)).kind, core.Document_Error_Kind.Bad_Value)
	testing.expect_value(t, core.set(&list, 1, "2").kind, core.Document_Error_Kind.None)
}

@(private = "file")
edit_accepts :: proc(_: ^core.Document, _: []u8, _: runtime.Allocator) -> core.Document_Error {
	return {}
}

@(private = "file")
reads_faults :: proc "contextless" (_: []u8, _: core.As) -> Maybe(core.Fault) {
	return core.Fault{}
}

// `commit` refuses an output that fails even the format's tolerant read, even when the source needed that tolerance.
@(test)
edit_check_policy :: proc(t: ^testing.T) {
	src := transmute([]u8)string("{\"a\":\"\xff\",\"b\":1}")
	doc, err := json.build(src, .Json, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	edit := core.Edit_Spelling{value = edit_accepts}
	doc.spelling = &core.Spelling{edit = &edit, validate = reads_faults}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	if !testing.expect_value(t, core.set(&list, 4, string("2")).kind, core.Document_Error_Kind.None) {
		return
	}
	out, _, cerr := compose.commit(&list, doc.as.spec, context.allocator)
	defer if len(out) > 0 {
		delete(out)
	}
	testing.expect_value(t, cerr.kind, core.Document_Error_Kind.Bad_Result)
}

// A document built with `Invalid_Utf8` commits with no edit and with one, and each output reads under the same
// tolerance.
@(test)
edit_tolerated_source :: proc(t: ^testing.T) {
	src := "{\"a\":\"\xff\",\"b\":1}"
	doc, err := json.build(transmute([]u8)string(src), .Json, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	// `commit` reads its output with the source's tolerance.
	for want in ([]string{src, "{\"a\":\"\xff\",\"b\":2}"}) {
		if want != src {
			testing.expect_value(t, core.set(&list, 4, string("2")).kind, core.Document_Error_Kind.None)
		}
		out, _, cerr := core.commit(&list)
		if !testing.expectf(t, cerr.kind == .None, "commit: %v", cerr) {
			return
		}
		testing.expect_value(t, string(out), want)
		read, rerr := json.build(out, .Json, {tolerate = {.Invalid_Utf8}})
		testing.expectf(t, rerr.kind == .None, "committed text does not read: %v", rerr)
		core.destroy(&read)
		delete(out)
	}
}

// `remove` deletes the separator comma from the trivia between comments, not from a comment body, and no cut starts
// inside a comment.
@(test)
edit_comma_in_comment :: proc(t: ^testing.T) {
	edit_rows(t, .Jsonc, {
		{"[1,\n /* , */ 2]", "[/* , */ 2]", .Remove, 1, 0, "", ""},
		{"[0, 1,\n//h\n2]", "[0, \n//h\n2]", .Remove, 2, 0, "", ""},
		{"[1,\n /* , */ 2,\n 3]", "[1,\n 3]", .Remove, 2, 0, "", ""},
		{"[\n /* , */ 1, 2]", "[\n 2]", .Remove, 1, 0, "", ""},
		{"[1, /* a , b */ 2, 3]", "[1, /* a , b */ 3]", .Remove, 2, 0, "", ""},
	})
}

// Removing the last member keeps the previous member's inline comment.
@(test)
edit_inline_comment_survives :: proc(t: ^testing.T) {
	edit_rows(t, .Jsonc, {
		{"[1, /* keep */ 2]", "[1 /* keep */]", .Remove, 2, 0, "", ""},
		{"[1, // keep\n 2]", "[1 // keep\n]", .Remove, 2, 0, "", ""},
		// The removed member's head comment is removed with it.
		{"[1,\n /* keep */ 2]", "[1]", .Remove, 2, 0, "", ""},
	})
	edit_rows(t, .Json5, {{"[1, /*x*/ 2,]", "[1 /*x*/,]", .Remove, 2, 0, "", ""}})
}

// `commit` allocates from its own allocator, not the list's: a list whose allocator refuses every allocation still
// commits.
@(test)
edit_commit_allocator :: proc(t: ^testing.T) {
	doc, err := json.build(transmute([]u8)string("[1,2,3]"), .Json)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	a := walktest.Failing_Alloc{inner = context.allocator, fail_at = -1}
	list := core.edit_list_init(&doc, walktest.failing_allocator(&a))
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set(&list, 1, string("9")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.insert(&list, 0, 1, string("8")).kind, core.Document_Error_Kind.None)
	a.fail_all = true
	out, _, cerr := core.commit(&list)
	defer if len(out) > 0 {
		delete(out)
	}
	testing.expect_value(t, cerr.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, string(out), "[9,8,2,3]")
}

// A removal of one member and a set of the next, which are siblings, do not conflict.
@(test)
edit_sibling_remove_and_set :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string("[10,20]"), .Json)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.remove(&list, 1).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.set(&list, 2, string("3")).kind, core.Document_Error_Kind.None)
	testing.expect(t, expect_commit(t, &list, `[3]`, .Json))
}

// A build's `max_depth` is stored in the document and both edit reads use it. A 2,000-deep array built with a depth
// of 4096 commits a set of its innermost node and reads back.
@(test)
edit_deep_document :: proc(t: ^testing.T) {
	depth := 2000
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, strings.repeat("[", depth, context.temp_allocator))
	strings.write_byte(&b, '0')
	strings.write_string(&b, strings.repeat("]", depth, context.temp_allocator))
	doc, err := json.build(transmute([]u8)strings.to_string(b), .Json, {max_depth = 4096})
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	if !testing.expect_value(t, core.set(&list, core.Node_Index(depth), "1").kind, core.Document_Error_Kind.None) {
		return
	}
	out, _, cerr := core.commit(&list)
	defer delete(out)
	if !testing.expectf(t, cerr.kind == .None, "commit: %v", cerr) {
		return
	}
	testing.expect_value(t, len(out), 2 * depth + 1)
	testing.expect_value(t, out[depth], u8('1'))
	back, berr := json.build(out, .Json, {max_depth = 4096})
	defer core.destroy(&back)
	testing.expectf(t, berr.kind == .None, "read back: %v", berr)
	num, num_ok := core.number(&back, core.Node_Index(depth))
	testing.expect(t, num_ok)
	testing.expect_value(t, num.kind, core.Number_Kind.Int)
	testing.expect_value(t, num.bits, u64(1))
}

// A value text nesting 1,500 levels reads under a document built with `max_depth` 4096 and is refused as `.Bad_Value`
// under one built with the default.
@(test)
edit_deep_value :: proc(t: ^testing.T) {
	deep := strings.concatenate({
		strings.repeat("[", 1500, context.temp_allocator),
		strings.repeat("]", 1500, context.temp_allocator),
	}, context.temp_allocator)
	doc, err := json.build(transmute([]u8)string(`[1]`), .Json, {max_depth = 4096})
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	if !testing.expect_value(t, core.set(&list, 1, deep).kind, core.Document_Error_Kind.None) {
		return
	}
	out, _, cerr := core.commit(&list)
	defer delete(out)
	testing.expectf(t, cerr.kind == .None, "commit: %v", cerr)

	shallow, serr := json.build(transmute([]u8)string(`[1]`), .Json)
	defer core.destroy(&shallow)
	testing.expectf(t, serr.kind == .None, "build: %v", serr)
	other := core.edit_list_init(&shallow)
	defer core.edit_list_destroy(&other)
	e := core.set(&other, 1, deep)
	testing.expect_value(t, e.kind, core.Document_Error_Kind.Bad_Value)
	testing.expect_value(t, e.inner.kind, core.Fault_Kind.Too_Deep)
}

// `render` writes the inner fault's message with no position for `.Bad_Value` and `.Bad_Result`, since `inner.at` is a
// byte of the recorded text or of the commit's output, not of `src`.
@(test)
render_inner_cause :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	doc, _ := json.build(transmute([]u8)string(`{"a":[1,2]}`), .Json)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	e := core.set(&list, 2, string("[1"))
	testing.expect_value(t, e.kind, core.Document_Error_Kind.Bad_Value)
	testing.expect_value(t, e.inner.kind, core.Fault_Kind.Truncated)
	core.render(strings.to_writer(&b), doc.src, e)
	testing.expect_value(t, strings.to_string(b), "Not one value of the format: Unfinished input at offset 2 of the new text")

	// A JSON5 text committed under strict JSON reads as no JSON value, at the unquoted key.
	j5, _ := json.build(transmute([]u8)string(`{a:1}`), .Json5)
	defer core.destroy(&j5)
	l5 := core.edit_list_init(&j5)
	defer core.edit_list_destroy(&l5)
	testing.expect_value(t, core.set(&l5, 2, string("2")).kind, core.Document_Error_Kind.None)
	_, _, ce := core.commit(&l5, json.as(.Json))
	testing.expect_value(t, ce.kind, core.Document_Error_Kind.Bad_Result)
	strings.builder_reset(&b)
	core.render(strings.to_writer(&b), j5.src, ce)
	testing.expect_value(t, strings.to_string(b), "The edited text does not read: Object keys must be strings at offset 1 of the edited text")
}

// `span` on a string or a key returns its source bytes with the quotes, which the splice writer copies.
@(test)
splice_spans :: proc(t: ^testing.T) {
	src := `{"a":"x\ny","b":'q'}`
	doc, err := build(src, .Json5)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, string(core.span(&doc, 1)), `"a"`)
	testing.expect_value(t, string(core.span(&doc, 2)), `"x\ny"`)
	testing.expect_value(t, string(core.span(&doc, 4)), `'q'`)
}

// An insert whose position lies in a removal run moves to the run's cut end, with its separator chosen by what
// survives: after the run, before it, or neither.
@(test)
edit_insert_in_removal_run :: proc(t: ^testing.T) {
	Case :: struct {
		src, want: string,
		remove:    []core.Node_Index,
		at:        []int, // the position of each insert, which adds the member `key` and `text` when `key` is set
		key, text: string,
	}
	for c in ([]Case {
			{`[1,2]`, `[1,3]`, {2}, {1}, "", "3"},
			{`[1,2]`, `[1,3]`, {2}, {2}, "", "3"},
			{`{"a":1,"b":2,"c":3}`, `{"a":1,"x":9,"c":3}`, {4}, {1}, "x", "9"},
			{`{"a":1,"b":2,"c":3}`, `{"a":1,"x":9,"c":3}`, {4}, {2}, "x", "9"},
			{`[1]`, `[9]`, {1}, {0}, "", "9"},
			{`[1]`, `[9]`, {1}, {1}, "", "9"},
			{`[1,2,3]`, `[9,3]`, {1, 2}, {1}, "", "9"},
		}) {
		doc, err := json.build(transmute([]u8)c.src, .Json)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", c.src, err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		for n in c.remove {
			core.remove(&list, n)
		}
		for at in c.at {
			if c.key != "" {
				core.insert(&list, 0, at, c.key, c.text)
			} else {
				core.insert(&list, 0, at, c.text)
			}
		}
		out, _, cerr := core.commit(&list)
		defer if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, cerr.kind == .None && string(out) == c.want, "%q: committed %q (%v), want %q", c.src, out, cerr, c.want)
	}

	// The removal takes the comma the insert counted on. The new member stays off the head comment's line, so the
	// comment still leads `"c"`.
	src := "{\n  \"a\": 1,\n  \"b\": 2,\n  //hc\n  \"c\": 3\n}"
	doc, err := json.build(transmute([]u8)src, .Jsonc)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.remove(&list, 4).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.insert(&list, 0, 2, string("x"), string("9")).kind, core.Document_Error_Kind.None)
	out, _, cerr := core.commit(&list)
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, cerr.kind == .None, "multiline: commit %v", cerr) {
		return
	}
	read, rerr := json.build(out, .Jsonc)
	defer core.destroy(&read)
	if !testing.expectf(t, rerr.kind == .None, "multiline: committed text does not read: %v in %q", rerr, out) {
		return
	}
	v, ok := core.member(&read, 0, "c")
	if !testing.expect(t, ok) {
		return
	}
	it := core.facts_of(&read, v, .Comment)
	got, more := core.fact_next(&it)
	testing.expectf(t, more && string(got) == "hc", "head comment on c: %q %v", got, more)
}
