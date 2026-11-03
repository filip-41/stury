package json_tests

import "core:strconv"
import "core:strings"
import "core:testing"
import core "../../core"
import json ".."
import walktest "../../walktest"

// Reading a built document: its nodes and spans, the readers, duplicate keys, facts, and the faults a build reports.

build :: proc(src: string, $S: json.Spec, opts := json.Options{}, refuse_duplicates := false) -> (core.Document, core.Document_Error) {
	return json.build(transmute([]u8)src, S, opts, refuse_duplicates)
}

// `{"a":[1,2],"b":{}}` makes 7 nodes. A container's `n` counts its subtree in nodes, a key node is written right
// before its value's, `length` counts a container's members, and `span` returns its bytes through the close.
@(test)
node_layout :: proc(t: ^testing.T) {
	src := `{"a":[1,2],"b":{}}`
	doc, err := build(src, .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, len(doc.nodes), 7)
	if len(doc.nodes) != 7 {
		return
	}
	want := []walktest.Node_Want{
		{0, 7, .Map, .Value},
		{2, 1, .String, .Key},
		{5, 3, .Array, .Value},
		{6, 1, .Number, .Value},
		{8, 1, .Number, .Value},
		{12, 1, .String, .Key},
		{15, 1, .Map, .Value},
	}
	if !walktest.expect_nodes(t, &doc, want) {
		return
	}
	testing.expect_value(t, doc.root_close, u64(len(src)))
	testing.expect_value(t, string(core.span(&doc, 0)), src)
	testing.expect_value(t, string(core.span(&doc, 2)), "[1,2]")
	testing.expect_value(t, string(core.span(&doc, 6)), "{}")
	// A string token's span leaves out its quotes, and `core.span` adds them back, as a splice copies them.
	testing.expect_value(t, string(core.span(&doc, 1)), `"a"`)
	testing.expect_value(t, core.length(&doc, 0), 2)
	testing.expect_value(t, core.length(&doc, 2), 2)
	testing.expect_value(t, core.length(&doc, 6), 0)
	testing.expect_value(t, core.length(&doc, 3), 0)
}

// A document's `root_close` is one past the root value's authored bytes: a container's closing bracket, or a scalar's
// last byte, quotes included. A scalar root's span is the same bytes, and trailing text after a container stays out.
@(test)
root_close_reader :: proc(t: ^testing.T) {
	cases := []string{`"x"`, `42`, `true`, `null`}
	for src in cases {
		doc, err := build(src, .Json)
		if !testing.expectf(t, err.kind == .None, "scalar %q: %v", src, err) {
			core.destroy(&doc)
			continue
		}
		testing.expect_value(t, doc.root_close, u64(len(src)))
		testing.expect_value(t, string(core.span(&doc, core.ROOT)), src)
		core.destroy(&doc)
	}

	doc, err := build("[1]  ", .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, doc.root_close, 3)
	testing.expect_value(t, string(core.span(&doc, core.ROOT)), "[1]")
}

// A JSONC `//` comment ends only at LF or CR, so U+2028 and U+2029 inside one belong to it and the root's span runs
// to the close. A JSON5 comment ends at either byte, which is still whitespace there.
@(test)
line_separators_in_comments :: proc(t: ^testing.T) {
	cases := []struct {
		src:  string,
		spec: json.Spec,
	}{
		{"{\"a\":1 // x\u2028y\n}", .Jsonc},
		{"[1 // x\u2029y\n]", .Jsonc},
		{"{\"a\"://x\u20281}", .Json5},
		{"[1,//x\u20292]", .Json5},
	}
	for c in cases {
		doc: core.Document
		err: core.Document_Error
		switch c.spec {
		case .Json:  doc, err = build(c.src, .Json)
		case .Jsonc: doc, err = build(c.src, .Jsonc)
		case .Json5: doc, err = build(c.src, .Json5)
		}
		if !testing.expectf(t, err.kind == .None, "%v %q: %v", c.spec, c.src, err) {
			core.destroy(&doc)
			continue
		}
		got := string(core.span(&doc, 0))
		testing.expectf(t, got == c.src, "%v %q: span %q", c.spec, c.src, got)
		core.destroy(&doc)
	}
}

// For each valid JSONTestSuite text under `.Json`, `.Jsonc` and `.Json5`, and each json5-tests text under `.Json5`,
// every container's span ends where the walk's `End` ends, and its child count is its member count.
@(test)
container_spans :: proc(t: ^testing.T) {
	suite := #load_directory("conformance/JSONTestSuite/test_parsing")
	for file in suite {
		if file.name[0] != 'y' {
			continue
		}
		if !check_spans(t, file.data, .Json) || !check_spans(t, file.data, .Jsonc) || !check_spans(t, file.data, .Json5) {
			return
		}
	}
	for dir in walktest.JSON5_TESTS {
		for file in dir {
			if !check_spans(t, file.data, .Json5) {
				return
			}
		}
	}
}

check_spans :: proc(t: ^testing.T, src: []u8, $S: json.Spec) -> bool {
	log := new(walktest.Log)
	defer free(log)
	regs: core.Hook_Regs
	_, fault := json.walk(src, 0, S, {}, log, &regs, walktest.log_hook)
	doc, err := json.build(src, S)
	defer core.destroy(&doc)
	if fault == nil && log.n == 0 {
		// A text with no value is no document: the walk reads it as a stream would, and `build` refuses it with
		// `.Truncated` at the text's end.
		return testing.expectf(t, err.kind == .Walk && err.inner.kind == .Truncated && err.inner.at == u64(len(src)), "%v %q: build %v", S, string(src), err)
	}
	// `build` returns the fault `validate` returns for the same text, trailing bytes included.
	want, bad := json.validate(src, S).?
	if bad {
		return testing.expectf(t, err.kind == .Walk && err.inner.kind == want.kind && err.inner.at == want.at, "%v %q: build %v, validate %v", S, string(src), err, want)
	}
	if !testing.expectf(t, err.kind == .None, "%v %q: build %v", S, string(src), err) {
		return false
	}
	return walktest.check_containers(t, &doc, log.tokens[:log.n])
}


// `text` and `key_equals` refuse a container node, and `number` refuses a container, a key and a string.
@(test)
readers_refuse_containers :: proc(t: ^testing.T) {
	buf: [8]u8
	doc, err := build(`{"a":[1]}`, .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	_, ok := core.text(&doc, 0, buf[:])
	testing.expect(t, !ok)
	testing.expect(t, !core.key_equals(&doc, 0, "a"))
	_, ok = core.text(&doc, 2, buf[:])
	testing.expect(t, !ok)
	testing.expect_value(t, core.kind(&doc, 0), core.Kind.Map)
	testing.expect_value(t, core.kind(&doc, 2), core.Kind.Array)
	// `number` on a container, a key and a string returns `.Wide`, and `int_value` on a key returns false.
	testing.expect_value(t, core.number(&doc, 0).kind, core.Number_Kind.Wide)
	testing.expect_value(t, core.number(&doc, 2).kind, core.Number_Kind.Wide)
	testing.expect_value(t, core.number(&doc, 1).kind, core.Number_Kind.Wide)
	_, is_int := core.int_value(&doc, 1)
	testing.expect(t, !is_int)
	core.destroy(&doc)

	doc, err = build(`["123"]`, .Json)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.number(&doc, 1).kind, core.Number_Kind.Wide)
}

// `child_at` returns the node `child_next` reaches at step `k`. It indexes when each member is one node and walks the
// subtree sizes otherwise, and returns false past the last member, for `k` -1, for `NO_NODE` and for a scalar.
@(test)
child_at_reader :: proc(t: ^testing.T) {
	doc, err := build(`["a","b","c"]`, .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	for i in 0 ..< 3 {
		v, ok := core.child_at(&doc, 0, i)
		testing.expect(t, ok)
		testing.expect_value(t, v, core.Node_Index(1 + i))
		s, _ := core.text(&doc, v, nil)
		testing.expect_value(t, s, string([]u8{u8('a' + i)}))
	}
	_, ok := core.child_at(&doc, 0, 3)
	testing.expect(t, !ok)
	_, ok = core.child_at(&doc, 0, -1)
	testing.expect(t, !ok)
	_, ok = core.child_at(&doc, core.NO_NODE, 0)
	testing.expect(t, !ok)
	// A scalar holds no member, so `child_at` returns false.
	_, ok = core.child_at(&doc, 1, 0)
	testing.expect(t, !ok)
	core.destroy(&doc)

	// A nested member makes `child_at` walk, and a `Map` value's key node is at `value - 1`.
	doc, err = build(`{"a":1,"b":[2,3],"c":{"d":4}}`, .Json)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	it := core.children(&doc, 0)
	k := 0
	for {
		want, more := core.child_next(&it)
		if !more {
			break
		}
		got, has := core.child_at(&doc, 0, k)
		testing.expect(t, has)
		testing.expect_value(t, got, want)
		testing.expect_value(t, doc.nodes[want - 1].role, core.Role.Key)
		k += 1
	}
	testing.expect_value(t, k, 3)
	_, ok = core.child_at(&doc, 0, k)
	testing.expect(t, !ok)
	core.destroy(&doc)

	// A `Map` whose members are one key and one value each uses the index path at a stride of 2, values 2, 4 and 6.
	doc, err = build(`{"a":1,"b":2,"c":3}`, .Json)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	values := []core.Node_Index{2, 4, 6}
	for w, i in values {
		got, has := core.child_at(&doc, 0, i)
		testing.expect(t, has)
		testing.expect_value(t, got, w)
		testing.expect_value(t, doc.nodes[got - 1].role, core.Role.Key)
	}
	_, ok = core.child_at(&doc, 0, len(values))
	testing.expect(t, !ok)
	core.destroy(&doc)

	// A nested `Array` is walked, each member's `n` giving the next step.
	doc, err = build(`[[1],[2,3],[]]`, .Json)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	want := []core.Node_Index{1, 3, 6}
	for w, i in want {
		got, has := core.child_at(&doc, 0, i)
		testing.expect(t, has)
		testing.expect_value(t, got, w)
	}
	_, ok = core.child_at(&doc, 0, 3)
	testing.expect(t, !ok)
}

// A container of `core.MAX_CHILDREN` members records 65535 as its child count, the saturation value. `child_at`
// reads the true count from `Document.counts`, so a uniform array still indexes and a `k` past the last member is
// false without a walk.
@(test)
child_at_saturated :: proc(t: ^testing.T) {
	text: [dynamic]u8
	defer delete(text)

	// An `Array` of exactly `MAX_CHILDREN` members, and the last member it holds.
	append(&text, '[')
	for i in 0 ..< int(core.MAX_CHILDREN) {
		if i > 0 {
			append(&text, ',')
		}
		append(&text, ..transmute([]u8)string("null"))
	}
	append(&text, ']')
	doc, err := build(string(text[:]), .Json)
	testing.expectf(t, err.kind == .None, "array: %v", err)
	if err.kind != .None {
		return
	}
	testing.expect_value(t, core.length(&doc, 0), int(core.MAX_CHILDREN))
	last, ok := core.child_at(&doc, 0, int(core.MAX_CHILDREN) - 1)
	testing.expect(t, ok)
	testing.expect_value(t, last, core.Node_Index(core.MAX_CHILDREN))
	_, ok = core.child_at(&doc, 0, int(core.MAX_CHILDREN))
	testing.expect(t, !ok)
	core.destroy(&doc)

	// A `Map` of `MAX_CHILDREN` members puts the last value at the last node, with its key at `last - 1`.
	clear(&text)
	append(&text, '{')
	key: [24]u8
	for i in 0 ..< int(core.MAX_CHILDREN) {
		if i > 0 {
			append(&text, ',')
		}
		append(&text, '"')
		append(&text, ..transmute([]u8)strconv.write_int(key[:], i64(i), 10))
		append(&text, ..transmute([]u8)string("\":1"))
	}
	append(&text, '}')
	doc, err = build(string(text[:]), .Json)
	testing.expectf(t, err.kind == .None, "map: %v", err)
	if err.kind == .None {
		testing.expect_value(t, core.length(&doc, 0), int(core.MAX_CHILDREN))
		last, ok = core.child_at(&doc, 0, int(core.MAX_CHILDREN) - 1)
		testing.expect(t, ok)
		testing.expect_value(t, last, core.Node_Index(len(doc.nodes) - 1))
		testing.expect_value(t, doc.nodes[last - 1].role, core.Role.Key)
		_, ok = core.child_at(&doc, 0, int(core.MAX_CHILDREN))
		testing.expect(t, !ok)
		core.destroy(&doc)
	}

	// An `Array` of `MAX_CHILDREN + 1` members keeps its count at 65535, and the last member is still the last node.
	clear(&text)
	append(&text, '[')
	for i in 0 ..< int(core.MAX_CHILDREN) + 1 {
		if i > 0 {
			append(&text, ',')
		}
		append(&text, ..transmute([]u8)string("null"))
	}
	append(&text, ']')
	doc, err = build(string(text[:]), .Json)
	testing.expectf(t, err.kind == .None, "big array: %v", err)
	if err.kind == .None {
		testing.expect_value(t, core.length(&doc, 0), int(core.MAX_CHILDREN) + 1)
		last, ok = core.child_at(&doc, 0, int(core.MAX_CHILDREN))
		testing.expect(t, ok)
		testing.expect_value(t, last, core.Node_Index(len(doc.nodes) - 1))
		_, ok = core.child_at(&doc, 0, int(core.MAX_CHILDREN) + 1)
		testing.expect(t, !ok)
		core.destroy(&doc)
	}

	// A saturated container nested in another: the outer array's next member follows the inner one, and an index past
	// the inner container's members must not return that node.
	clear(&text)
	append(&text, '[')
	append(&text, '[')
	for i in 0 ..< int(core.MAX_CHILDREN) {
		if i > 0 {
			append(&text, ',')
		}
		append(&text, ..transmute([]u8)string("null"))
	}
	append(&text, ..transmute([]u8)string("],\"sentinel\"]"))
	doc, err = build(string(text[:]), .Json)
	testing.expectf(t, err.kind == .None, "nested: %v", err)
	if err.kind == .None {
		inner := core.Node_Index(1)
		testing.expect_value(t, core.length(&doc, inner), int(core.MAX_CHILDREN))
		last, ok = core.child_at(&doc, inner, int(core.MAX_CHILDREN) - 1)
		testing.expect(t, ok)
		testing.expect_value(t, last, core.Node_Index(core.MAX_CHILDREN) + 1)
		_, ok = core.child_at(&doc, inner, int(core.MAX_CHILDREN))
		testing.expect(t, !ok)
		core.destroy(&doc)
	}
}

// Each reader returns its empty answer for `NO_NODE`, which `member` returns on a miss: `Null` from `kind` and
// `resolve`, 0 from `length`, an empty span, `.Wide` from `number`, false from `text`, `key_equals` and
// `child_next`.
@(test)
readers_refuse_no_node :: proc(t: ^testing.T) {
	buf: [8]u8
	doc, err := build(`{"a":1}`, .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	i := core.NO_NODE
	testing.expect_value(t, core.kind(&doc, i), core.Kind.Null)
	testing.expect_value(t, core.length(&doc, i), 0)
	testing.expect_value(t, len(core.span(&doc, i)), 0)
	testing.expect_value(t, core.number(&doc, i).kind, core.Number_Kind.Wide)
	testing.expect_value(t, core.resolve(&doc, i), core.Kind.Null)
	_, ok := core.text(&doc, i, buf[:])
	testing.expect(t, !ok)
	testing.expect(t, !core.key_equals(&doc, i, "a"))
	it := core.children(&doc, i)
	_, ok = core.child_next(&it)
	testing.expect(t, !ok)
}


// Checks `length`, `children` and `child_next` on an empty array and a nested one, and `kind`, `span` and
// `int_value` on a number.
@(test)
readers :: proc(t: ^testing.T) {
	doc, err := build(`[]`, .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.length(&doc, 0), 0)
	empty := core.children(&doc, 0)
	_, ok := core.child_next(&empty)
	testing.expect(t, !ok)
	core.destroy(&doc)

	doc, err = build(`[[[]]]`, .Json)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.length(&doc, 0), 1)
	testing.expect_value(t, core.length(&doc, 1), 1)
	testing.expect_value(t, core.length(&doc, 2), 0)
	it := core.children(&doc, 0)
	first, has := core.child_next(&it)
	testing.expect(t, has)
	testing.expect_value(t, first, 1)
	_, more := core.child_next(&it)
	testing.expect(t, !more)
	core.destroy(&doc)

	doc, err = build(`1`, .Json)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.kind(&doc, 0), core.Kind.Number)
	testing.expect_value(t, core.length(&doc, 0), 0)
	testing.expect_value(t, string(core.span(&doc, 0)), "1")
	n, is_int := core.int_value(&doc, 0)
	testing.expect(t, is_int)
	testing.expect_value(t, n, i64(1))
	core.destroy(&doc)
}

// Checks `member` with `.First` and `.Last`, `members_named` over both values, and a refusing build failing at the
// repeat's byte.
@(test)
duplicates :: proc(t: ^testing.T) {
	src := `{"a":1,"a":2,"b":3}`
	doc, err := build(src, .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	v, ok := core.member(&doc, 0, "a", .First)
	testing.expect(t, ok)
	testing.expect_value(t, v, 2)
	v, ok = core.member(&doc, 0, "a", .Last)
	testing.expect(t, ok)
	testing.expect_value(t, v, 4)
	it := core.members_named(&doc, 0, "a")
	v, ok = core.member_next(&it)
	testing.expect(t, ok)
	testing.expect_value(t, v, 2)
	v, ok = core.member_next(&it)
	testing.expect(t, ok)
	testing.expect_value(t, v, 4)
	_, ok = core.member_next(&it)
	testing.expect(t, !ok)
	core.destroy(&doc)

	doc, err = build(src, .Json, {}, true)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 7)
	testing.expect_value(t, len(doc.nodes), 0)

	// `"\u0061"` and `"a"` are the same key, so a refusing build fails at the later key's byte, 12.
	doc, err = build(`{"\u0061":1,"a":2}`, .Json, {}, true)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 12)

	doc, err = build(`{"\u0061":1,"b":2}`, .Json, {}, true)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	defer core.destroy(&doc)
	v, ok = core.member(&doc, 0, "a")
	testing.expect(t, ok)
	testing.expect_value(t, v, 2)
}

// A repeat read before a later walk fault is reported at its byte. The walk stops before the root object closes, so
// the close-time check never runs for it.
@(test)
refuse_repeat_before_fault :: proc(t: ^testing.T) {
	// The root's second `""` is at byte 6, and the comma after the colon is the fault at byte 8.
	doc, err := build(`{"":0,"":,}`, .Json, {}, true)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 6)
	testing.expect_value(t, len(doc.nodes), 0)

	// A closed inner object finds its own repeat first, at byte 15. The root's repeat at byte 6 is earlier.
	doc, err = build(`{"":0,"":{"":1,"":2},x}`, .Json, {}, true)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 6)
	testing.expect_value(t, len(doc.nodes), 0)
}

// `member` does not find a key inside a member's value: the step over a key or a value is its whole subtree, which
// keeps the next key and its value aligned.
@(test)
member_nested_keys :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		name:  string,
		value: core.Node_Index,
		found: bool,
	}
	cases := []Case{
		{`{"a":{"b":1},"c":2}`, "b", 0, false},
		{`{"a":{"b":1},"c":2}`, "c", 6, true},
		{`{"a":[1,2,3],"b":4}`, "b", 7, true},
		{`{"a":[1,2,3],"b":4}`, "3", 0, false},
	}
	for c in cases {
		doc, err := build(c.text, .Json)
		testing.expectf(t, err.kind == .None, "%q: %v", c.text, err)
		if err.kind != .None {
			return
		}
		last, ok := core.member(&doc, 0, c.name)
		testing.expectf(t, ok == c.found && (!ok || last == c.value), "%q member %q: %v %v, want %v %v", c.text, c.name, last, ok, c.value, c.found)
		first, fok := core.member(&doc, 0, c.name, .First)
		testing.expectf(t, fok == c.found && (!fok || first == c.value), "%q member %q First: %v %v", c.text, c.name, first, fok)
		it := core.members_named(&doc, 0, c.name)
		v, vok := core.member_next(&it)
		testing.expectf(t, vok == c.found && (!vok || v == c.value), "%q members_named %q: %v %v", c.text, c.name, v, vok)
		_, more := core.member_next(&it)
		testing.expectf(t, !more, "%q members_named %q: more than one", c.text, c.name)
		core.destroy(&doc)
	}
}


// Facts follow the ownership rule. A head comment belongs to the next value, an inline comment to the last value
// completed, and a foot to the innermost open container, or to the root at depth 0.
@(test)
facts :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		node:  core.Node_Index,
		roles: []core.Role,
	}
	cases := []Case{
		{`/* h */ 1 /* i */`, 0, {.Comment, .Comment_Inline}},
		{"{ /* h */ \"k\": /* h2 */ 1 /* i */ }\n/* foot */", 0, {.Comment_Foot}},
		{"{ /* h */ \"k\": /* h2 */ 1 /* i */ }\n/* foot */", 2, {.Comment, .Comment, .Comment_Inline}},
		{`[ /* f */ ]`, 0, {.Comment_Foot}},
		{`[1 /* i */, 2]`, 1, {.Comment_Inline}},
		{"[1,\n/* f */ ]", 0, {.Comment_Foot}},
		{`{"a": {} /* i */}`, 2, {.Comment_Inline}},
	}
	for c in cases {
		doc, err := build(c.text, .Jsonc)
		testing.expectf(t, err.kind == .None, "%q: %v", c.text, err)
		if err.kind != .None {
			continue
		}
		got: [dynamic]core.Role
		for role in ([]core.Role{.Comment, .Comment_Inline, .Comment_Foot}) {
			it := core.facts_of(&doc, c.node, role)
			for _ in core.fact_next(&it) {
				append(&got, role)
			}
		}
		ok := testing.expectf(t, len(got) == len(c.roles), "%q node %d: %d facts, want %d", c.text, c.node, len(got), len(c.roles))
		for role, i in got {
			ok &&= testing.expectf(t, role == c.roles[i], "%q node %d fact %d: %v, want %v", c.text, c.node, i, role, c.roles[i])
		}
		delete(got)
		if !ok {
			core.destroy(&doc)
			return
		}
		core.destroy(&doc)
	}
}


// A walk's fault becomes `.Walk` with the fault in `inner`, and `render` prints both lines.
@(test)
errors :: proc(t: ^testing.T) {
	src := `{`
	doc, err := build(src, .Json)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Walk)
	testing.expect_value(t, err.inner.at, 1)
	testing.expect_value(t, err.inner.kind, core.Fault_Kind.Truncated)
	testing.expect_value(t, len(doc.nodes), 0)
	b := strings.builder_make(context.temp_allocator)
	core.render(strings.to_writer(&b), transmute([]u8)src, err)
	testing.expect_value(t, strings.to_string(b), "1:2: Input does not parse\n  caused by 1:2: Unfinished input")

	doc, err = build(`{"a":1,"a":2}`, .Json, {}, true)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 7)
	strings.builder_reset(&b)
	core.render(strings.to_writer(&b), transmute([]u8)string(`{"a":1,"a":2}`), err)
	testing.expect_value(t, strings.to_string(b), "1:8: Duplicate key")
}

// A refusing build finds a repeat of an unquoted JSON5 key, at the later key's byte, 5.
@(test)
json5_duplicates :: proc(t: ^testing.T) {
	doc, err := build(`{a:1,a:2}`, .Json5, {}, true)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 5)
	testing.expect_value(t, len(doc.nodes), 0)
}

// JSON5 comments get the same roles as JSONC's. `/* h */` above the key and `// i` after the value are both facts of
// the value node, 2.
@(test)
json5_facts :: proc(t: ^testing.T) {
	doc, err := build("{/* h */ a: 1 // i\n}", .Json5)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	facts := core.facts_of(&doc, 2, .Comment)
	_, head := core.fact_next(&facts)
	more := core.facts_of(&doc, 2, .Comment_Inline)
	_, inline := core.fact_next(&more)
	testing.expect_value(t, head, true)
	testing.expect_value(t, inline, true)
}


// `build` and `validate` refuse a 0x1e at every byte of nine base texts, and behind a comment or JSON5 whitespace,
// with the same fault.
@(test)
build_vs_validate_0x1e :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		spec: json.Spec,
	}
	bases := []Case{
		{`1`, .Json}, {`[]`, .Json}, {`{}`, .Json},
		{`/*c*/1`, .Jsonc}, {`//c\n1`, .Jsonc}, {`/*a*/ 1`, .Jsonc},
		{`'x'`, .Json5}, {`a:1`, .Json5}, {`{a:1}`, .Json5},
	}
	for c in bases {
		for pos in 0 ..= len(c.text) {
			text: [dynamic]u8
			defer delete(text)
			append(&text, ..transmute([]u8)c.text[:pos])
			append(&text, 0x1e)
			append(&text, ..transmute([]u8)c.text[pos:])
			if !check_0x1e(t, text[:], c.spec, string(text[:])) {
				return
			}
		}
	}
	for c in ([]Case{
		{"/*c*/\x1e1", .Jsonc},
		{"//c\n\x1e1", .Jsonc},
		{"/*a*/ \x1e/*b*/ 1", .Jsonc},
		{"\u00a0\x1e1", .Json5},
		{"\v\x1e1", .Json5},
		{"\u2028\x1e{}", .Json5},
		{"\u3000\x1e1", .Json5},
	}) {
		if !check_0x1e(t, transmute([]u8)c.text, c.spec, c.text) {
			return
		}
	}
}

check_0x1e :: proc(t: ^testing.T, src: []u8, spec: json.Spec, text: string) -> bool {
	switch spec {
	case .Json:
		return check_0x1e_one(t, src, .Json, text)
	case .Jsonc:
		return check_0x1e_one(t, src, .Jsonc, text)
	case .Json5:
		return check_0x1e_one(t, src, .Json5, text)
	}
	return false
}

check_0x1e_one :: proc(t: ^testing.T, src: []u8, $S: json.Spec, text: string) -> bool {
	want, bad := json.validate(src, S).?
	doc, err := json.build(src, S)
	defer core.destroy(&doc)
	if bad {
		return testing.expectf(t, err.kind == .Walk && err.inner.kind == want.kind && err.inner.at == want.at, "%v %q: build %v, validate %v", S, text, err, want)
	}
	return testing.expectf(t, err.kind == .None, "%v %q: %v", S, text, err)
}


// A JSON document's spelling table has all five read services, and its edit table has `value`, `key_text` and `reads`,
// with `,` and `:` as the separators.
@(test)
spelling_complete :: proc(t: ^testing.T) {
	src := []u8{'1'}
	doc, err := json.build(src, .Json)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	s := doc.spelling
	testing.expect(t, s.text != nil && s.key_equals != nil && s.number != nil && s.resolve != nil && s.close_end != nil)
	testing.expect(t, s.edit != nil && s.edit.value != nil && s.edit.key_text != nil && s.edit.reads != nil)
	testing.expect_value(t, s.edit.member_sep(nil), ",")
	testing.expect_value(t, s.edit.key_sep, ":")
}

// A refusing build finds a repeat in `{"a":1,"a":2 /* c */}` under JSONC, at byte 7, and leaves no nodes.
@(test)
refuse_with_comment :: proc(t: ^testing.T) {
	doc, err := build(`{"a":1,"a":2 /* c */}`, .Jsonc, {}, true)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 7)
	testing.expect_value(t, len(doc.nodes), 0)
}



// An `Array` of 65535 members records `MAX_CHILDREN` in its spelling, and `length` counts all 65535.
@(test)
saturated_length :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_byte(&b, '[')
	for i in 0 ..< 65535 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '0')
	}
	strings.write_byte(&b, ']')
	src := strings.to_string(b)
	doc, err := build(src, .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, len(doc.nodes), 65536)
	testing.expect_value(t, doc.nodes[0].spelling, core.MAX_CHILDREN)
	testing.expect_value(t, core.length(&doc, 0), 65535)
}


// `json.text` refuses a container and an index past the last node, and reads a number's digits and a string.
@(test)
text_refuses_containers :: proc(t: ^testing.T) {
	doc, err := build(`[[0],[1,2,3],{"k":1},7,"s"]`, .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	buf: [8]u8
	// Node 0 is an array of 5 children, node 1 of 1, node 3 of 3, node 7 an object of 1 member, and
	// `len(doc.nodes)` is past the last node.
	for i in ([]core.Node_Index{0, 1, 3, 7, core.Node_Index(len(doc.nodes))}) {
		s, ok := core.text(&doc, i, buf[:])
		testing.expectf(t, !ok && s == "", "node %d: %q, %v", i, s, ok)
	}
	n, nok := core.text(&doc, 10, buf[:])
	testing.expect(t, nok)
	testing.expect_value(t, n, "7")
	s, ok := core.text(&doc, 11, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "s")
	testing.expect_value(t, core.number(&doc, core.Node_Index(len(doc.nodes))).kind, core.Number_Kind.Wide)
}

// `core.pairs` walks every member pair of a `Map` container in source order. An empty object yields an empty
// iterator, nested containers step over their full subtree, duplicate keys yield both pairs, and a non-`Map`
// container or scalar yields an empty iterator.
@(test)
pairs_iteration :: proc(t: ^testing.T) {
	// Nested container values: array and object values step over their subtree.
	doc, err := build(`{"a":[1,2],"b":{"c":3},"d":4}`, .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	it := core.pairs(&doc, 0)
	buf: [32]u8
	k1, v1, ok1 := core.pair_next(&it)
	s1, _ := core.text(&doc, k1, buf[:])
	testing.expect(t, ok1 && s1 == "a" && doc.nodes[v1].kind == .Array)
	k2, v2, ok2 := core.pair_next(&it)
	s2, _ := core.text(&doc, k2, buf[:])
	testing.expect(t, ok2 && s2 == "b" && doc.nodes[v2].kind == .Map)
	k3, v3, ok3 := core.pair_next(&it)
	s3, _ := core.text(&doc, k3, buf[:])
	testing.expect(t, ok3 && s3 == "d" && doc.nodes[v3].kind == .Number)
	_, _, ok4 := core.pair_next(&it)
	testing.expect(t, !ok4)

	// Empty object: returns empty iterator.
	empty_doc, eerr := build(`{}`, .Json)
	defer core.destroy(&empty_doc)
	testing.expect_value(t, eerr.kind, core.Document_Error_Kind.None)
	eit := core.pairs(&empty_doc, 0)
	_, _, eok := core.pair_next(&eit)
	testing.expect(t, !eok)

	// Duplicate keys: both pairs are yielded in source order.
	dup_doc, derr := build(`{"k":1,"k":2}`, .Json)
	defer core.destroy(&dup_doc)
	testing.expect_value(t, derr.kind, core.Document_Error_Kind.None)
	dit := core.pairs(&dup_doc, 0)
	dk1, dv1, dok1 := core.pair_next(&dit)
	ds1, _ := core.text(&dup_doc, dk1, buf[:])
	testing.expect(t, dok1 && ds1 == "k" && dv1 == 2)
	dk2, dv2, dok2 := core.pair_next(&dit)
	ds2, _ := core.text(&dup_doc, dk2, buf[:])
	testing.expect(t, dok2 && ds2 == "k" && dv2 == 4)
	_, _, dok3 := core.pair_next(&dit)
	testing.expect(t, !dok3)

	// Non-Map containers and scalars: Array, scalar, or out of range index yields empty iterator.
	arr_doc, aerr := build(`[1,2,{"x":3}]`, .Json)
	defer core.destroy(&arr_doc)
	testing.expect_value(t, aerr.kind, core.Document_Error_Kind.None)
	ait := core.pairs(&arr_doc, 0)
	_, _, aok := core.pair_next(&ait)
	testing.expect(t, !aok)
	sit := core.pairs(&arr_doc, 1)
	_, _, sok := core.pair_next(&sit)
	testing.expect(t, !sok)
	oit := core.pairs(&arr_doc, 999)
	_, _, ook := core.pair_next(&oit)
	testing.expect(t, !ook)
}

