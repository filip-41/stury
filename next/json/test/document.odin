package json_tests

import "base:runtime"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"
import core "../../core"
import walktest "../../walktest"
import json ".."

build :: proc(src: string, $S: json.Spec, opts := json.Options{}, dups := core.Duplicates.Last) -> (core.Document, core.Document_Error) {
	return json.build(transmute([]u8)src, S, opts, dups)
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
		testing.expect_value(t, v, u32(1 + i))
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
	values := []u32{2, 4, 6}
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
	want := []u32{1, 3, 6}
	for w, i in want {
		got, has := core.child_at(&doc, 0, i)
		testing.expect(t, has)
		testing.expect_value(t, got, w)
	}
	_, ok = core.child_at(&doc, 0, 3)
	testing.expect(t, !ok)
}

// A container of `core.CHILDREN_MAX` members records 65535 as its child count, the saturation value, so `child_at`
// walks the members and returns false at `k == CHILDREN_MAX` and past it.
@(test)
child_at_saturated :: proc(t: ^testing.T) {
	text: [dynamic]u8
	defer delete(text)

	// An `Array` of exactly `CHILDREN_MAX` members, and the last member it holds.
	append(&text, '[')
	for i in 0 ..< int(core.CHILDREN_MAX) {
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
	testing.expect_value(t, core.length(&doc, 0), int(core.CHILDREN_MAX))
	last, ok := core.child_at(&doc, 0, int(core.CHILDREN_MAX) - 1)
	testing.expect(t, ok)
	testing.expect_value(t, last, u32(core.CHILDREN_MAX))
	_, ok = core.child_at(&doc, 0, int(core.CHILDREN_MAX))
	testing.expect(t, !ok)
	core.destroy(&doc)

	// A `Map` of `CHILDREN_MAX` members puts the last value at the last node, with its key at `last - 1`.
	clear(&text)
	append(&text, '{')
	key: [24]u8
	for i in 0 ..< int(core.CHILDREN_MAX) {
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
		testing.expect_value(t, core.length(&doc, 0), int(core.CHILDREN_MAX))
		last, ok = core.child_at(&doc, 0, int(core.CHILDREN_MAX) - 1)
		testing.expect(t, ok)
		testing.expect_value(t, last, u32(len(doc.nodes) - 1))
		testing.expect_value(t, doc.nodes[last - 1].role, core.Role.Key)
		_, ok = core.child_at(&doc, 0, int(core.CHILDREN_MAX))
		testing.expect(t, !ok)
		core.destroy(&doc)
	}

	// An `Array` of `CHILDREN_MAX + 1` members keeps its count at 65535, and the last member is still the last node.
	clear(&text)
	append(&text, '[')
	for i in 0 ..< int(core.CHILDREN_MAX) + 1 {
		if i > 0 {
			append(&text, ',')
		}
		append(&text, ..transmute([]u8)string("null"))
	}
	append(&text, ']')
	doc, err = build(string(text[:]), .Json)
	testing.expectf(t, err.kind == .None, "big array: %v", err)
	if err.kind == .None {
		testing.expect_value(t, core.length(&doc, 0), int(core.CHILDREN_MAX) + 1)
		last, ok = core.child_at(&doc, 0, int(core.CHILDREN_MAX))
		testing.expect(t, ok)
		testing.expect_value(t, last, u32(len(doc.nodes) - 1))
		_, ok = core.child_at(&doc, 0, int(core.CHILDREN_MAX) + 1)
		testing.expect(t, !ok)
		core.destroy(&doc)
	}

	// A saturated container nested in another: the outer array's next member follows the inner one, and an index past
	// the inner container's members must not return that node.
	clear(&text)
	append(&text, '[')
	append(&text, '[')
	for i in 0 ..< int(core.CHILDREN_MAX) {
		if i > 0 {
			append(&text, ',')
		}
		append(&text, ..transmute([]u8)string("null"))
	}
	append(&text, ..transmute([]u8)string("],\"sentinel\"]"))
	doc, err = build(string(text[:]), .Json)
	testing.expectf(t, err.kind == .None, "nested: %v", err)
	if err.kind == .None {
		inner := u32(1)
		testing.expect_value(t, core.length(&doc, inner), int(core.CHILDREN_MAX))
		last, ok = core.child_at(&doc, inner, int(core.CHILDREN_MAX) - 1)
		testing.expect(t, ok)
		testing.expect_value(t, last, u32(core.CHILDREN_MAX) + 1)
		_, ok = core.child_at(&doc, inner, int(core.CHILDREN_MAX))
		testing.expect(t, !ok)
		core.destroy(&doc)
	}
}

// Each reader returns its empty answer for `NO_NODE`, which `member` returns on a miss: `Null` from `kind` and
// `resolve`, 0 from `length`, an empty span, `.Wide` from `number`, false from `text`, `key_equals` and
// `first_child`.
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
	_, ok = core.first_child(&doc, i)
	testing.expect(t, !ok)
}


// Checks `length`, `first_child` and `next_child` on an empty array and a nested one, and `kind`, `span` and
// `int_value` on a number.
@(test)
readers :: proc(t: ^testing.T) {
	doc, err := build(`[]`, .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.length(&doc, 0), 0)
	_, ok := core.first_child(&doc, 0)
	testing.expect(t, !ok)
	core.destroy(&doc)

	doc, err = build(`[[[]]]`, .Json)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.length(&doc, 0), 1)
	testing.expect_value(t, core.length(&doc, 1), 1)
	testing.expect_value(t, core.length(&doc, 2), 0)
	first, has := core.first_child(&doc, 0)
	testing.expect(t, has)
	testing.expect_value(t, first, 1)
	_, more := core.next_child(&doc, 0, first)
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

// Checks `member` with `.First` and `.Last`, `member_all` over both values, and `.Refuse` failing at the repeat's byte.
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
	it := core.member_all(&doc, 0, "a")
	v, ok = core.member_next(&it)
	testing.expect(t, ok)
	testing.expect_value(t, v, 2)
	v, ok = core.member_next(&it)
	testing.expect(t, ok)
	testing.expect_value(t, v, 4)
	_, ok = core.member_next(&it)
	testing.expect(t, !ok)
	core.destroy(&doc)

	doc, err = build(src, .Json, {}, .Refuse)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 7)
	testing.expect_value(t, len(doc.nodes), 0)

	// `"\u0061"` and `"a"` are the same key, so `.Refuse` fails at the later key's byte, 12.
	doc, err = build(`{"\u0061":1,"a":2}`, .Json, {}, .Refuse)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 12)

	doc, err = build(`{"\u0061":1,"b":2}`, .Json, {}, .Refuse)
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
	doc, err := build(`{"":0,"":,}`, .Json, {}, .Refuse)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 6)
	testing.expect_value(t, len(doc.nodes), 0)

	// A closed inner object finds its own repeat first, at byte 15. The root's repeat at byte 6 is earlier.
	doc, err = build(`{"":0,"":{"":1,"":2},x}`, .Json, {}, .Refuse)
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
		value: u32,
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
		it := core.member_all(&doc, 0, c.name)
		v, vok := core.member_next(&it)
		testing.expectf(t, vok == c.found && (!vok || v == c.value), "%q member_all %q: %v %v", c.text, c.name, v, vok)
		_, more := core.member_next(&it)
		testing.expectf(t, !more, "%q member_all %q: more than one", c.text, c.name)
		core.destroy(&doc)
	}
}

// Checks `bytes_equal` on lengths 0 to 40, with the last byte differing and with the second slice a byte shorter.
@(test)
bytes_equal_table :: proc(t: ^testing.T) {
	a, b: [64]u8
	for i in 0 ..< len(a) {
		a[i] = u8(i * 31 + 7)
		b[i] = a[i]
	}
	for n in 0 ..= 40 {
		testing.expectf(t, core.bytes_equal(a[:n], b[:n]), "length %d: equal", n)
		if n > 0 {
			b[n - 1] = a[n - 1] ~ 0x80
			testing.expectf(t, !core.bytes_equal(a[:n], b[:n]), "length %d: last byte differs", n)
			b[n - 1] = a[n - 1]
			testing.expectf(t, !core.bytes_equal(a[:n], b[:n - 1]), "length %d against %d", n, n - 1)
		}
	}
}

// For numbers of 3 to 19 digits with a point after `total / 2` of them, `number` returns `.Float` with the bits
// `strconv.parse_f64` returns.
@(test)
number_digit_count :: proc(t: ^testing.T) {
	state := u64(7)
	text: [32]u8
	for total in 3 ..= 19 {
		for _ in 0 ..< 100 {
			k := 0
			for i in 0 ..< total {
				// A point after half the digits keeps both runs non-empty and the significand at `total` digits.
				if i == total / 2 {
					text[k] = '.'
					k += 1
				}
				state = state * 6364136223846793005 + 1442695040888963407
				d := u8('0' + (state >> 33) % 10)
				if i == 0 && d == '0' {
					d = '1'
				}
				text[k] = d
				k += 1
			}
			src := string(text[:k])
			doc, err := build(src, .Json)
			testing.expectf(t, err.kind == .None, "%q: %v", src, err)
			if err.kind == .None {
				got := core.number(&doc, 0)
				want, ok := strconv.parse_f64(src)
				testing.expectf(t, ok && got.kind == .Float && got.bits == transmute(u64)want, "%q: %v, want %x", src, got, transmute(u64)want)
				core.destroy(&doc)
			}
		}
	}
}

// Facts follow the ownership rule. A head comment belongs to the next value, an inline comment to the last value
// completed, and a foot to the innermost open container, or to the root at depth 0.
@(test)
facts :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		node:  u32,
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

// Checks JSON5's identifier and `\u`-escaped keys, single-quoted strings, `\x` and `\0` escapes, and number forms.
@(test)
json5 :: proc(t: ^testing.T) {
	src := `{'a': 'x', b: 'y', \u0063: 0x10}`
	doc, err := build(src, .Json5)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	for w in ([]struct {
		name: string,
		text: string,
	}{{"a", "x"}, {"b", "y"}, {"c", ""}}) {
		v, ok := core.member(&doc, 0, w.name)
		testing.expectf(t, ok, "key %q", w.name)
		if !ok {
			continue
		}
		if w.text != "" {
			s, _ := core.text(&doc, v, nil)
			testing.expect_value(t, s, w.text)
		}
	}
	v, _ := core.member(&doc, 0, "c")
	num := core.number(&doc, v)
	testing.expect_value(t, num.kind, core.Number_Kind.Int)
	testing.expect_value(t, num.bits, u64(16))
	core.destroy(&doc)

	doc, err = build(`['\x41\0\n\'\\', "\uD83D\uDE00"]`, .Json5)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	buf: [256]u8
	s, ok := core.text(&doc, 1, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "A\x00\n'\\")
	s, ok = core.text(&doc, 2, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "\U0001F600")
	core.destroy(&doc)

	doc, err = build(`[+1, .5, 5., Infinity, -Infinity, NaN, -NaN, 0x10, -0x10]`, .Json5)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	want := []struct {
		kind: core.Number_Kind,
		bits: u64,
	}{
		{.Int, 1},
		{.Float, 0x3fe0000000000000},
		{.Float, 0x4014000000000000},
		{.Float, 0x7ff0000000000000},
		{.Float, 0xfff0000000000000},
		{.Float, 0x7ff8000000000000},
		{.Float, 0x7ff8000000000000},
		{.Int, 16},
		{.Int, ~u64(15)},
	}
	first, _ := core.first_child(&doc, 0)
	for w, i in want {
		n := core.number(&doc, first + u32(i))
		testing.expectf(t, n.kind == w.kind && n.bits == w.bits, "number %d: %v, want %v", i, n, w)
	}
	core.destroy(&doc)
}

// Under `Invalid_Utf8` and `Lone_Surrogate`, an ill-formed sequence or a lone surrogate half decodes to U+FFFD, one
// per maximal subpart.
@(test)
tolerated :: proc(t: ^testing.T) {
	doc, err := build("\"a\xffb\"", .Json, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	buf: [64]u8
	s, ok := core.text(&doc, 0, buf[:])
	testing.expect(t, ok)
	testing.expectf(t, s == "a\uFFFDb", "got %x want %x", transmute([]u8)s, transmute([]u8)string("a\uFFFDb"))
	core.destroy(&doc)

	doc, err = build("\"\\uD800\"", .Json, {tolerate = {.Lone_Surrogate}})
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	s, ok = core.text(&doc, 0, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "\uFFFD")
	core.destroy(&doc)

	// `E1 80 41` is U+FFFD for the maximal subpart `E1 80`, then `A`.
	doc, err = build("'\xe1\x80A'", .Json5, {tolerate = {.Invalid_Utf8}})
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	s, ok = core.text(&doc, 0, buf[:])
	testing.expect(t, ok)
	testing.expectf(t, s == "\uFFFDA", "got %x want %x", transmute([]u8)s, transmute([]u8)string("\uFFFDA"))
	core.destroy(&doc)
}

// Checks a number's kind and bits at the i64 and u64 edges, at the binary64 edges, and against `strconv.parse_f64` on
// random digits.
@(test)
numbers :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		kind: core.Number_Kind,
		bits: u64,
	}
	cases := []Case{
		{"0", .Int, 0},
		{"-0", .Int, 0},
		{"9223372036854775807", .Int, u64(max(i64))},
		{"9223372036854775808", .Uint, u64(1) << 63},
		{"18446744073709551615", .Uint, max(u64)},
		{"18446744073709551616", .Float, 0x43f0000000000000},
		{"-9223372036854775808", .Int, u64(1) << 63},
		{"-9223372036854775809", .Float, 0xc3e0000000000000},
		{"0.1", .Float, 0x3fb999999999999a},
		{"1e308", .Float, 0x7fe1ccf385ebc8a0},
		{"1e309", .Wide, 0},
		{"-1e309", .Wide, 0},
		{"1e-400", .Float, 0},
		{"-1e-400", .Float, 0x8000000000000000},
		{"5e-324", .Float, 1},
		{"2.2250738585072014e-308", .Float, 0x0010000000000000},
		// A fraction of 78 digits saturates the token's recorded count, and `number` reads the whole span.
		{"-0.000000000000000000000000000000000000000000000000000000000000000000000000000001", .Float, 0xafbda48ce468e7c7},
		{"1.0000000000000000001e2", .Float, 0x4059000000000000},
		{"1e5000", .Wide, 0},
	}
	for c in cases {
		doc, err := build(c.text, .Json)
		testing.expectf(t, err.kind == .None, "%q: %v", c.text, err)
		if err.kind != .None {
			continue
		}
		n := core.number(&doc, 0)
		testing.expectf(t, n.kind == c.kind && n.bits == c.bits, "%q: %v, want %v", c.text, n, c)
		core.destroy(&doc)
	}

	long: [301]u8
	long[0] = '1'
	for i in 1 ..< len(long) {
		long[i] = '0'
	}
	long_doc, long_err := build(string(long[:]), .Json)
	testing.expect_value(t, long_err.kind, core.Document_Error_Kind.None)
	if long_err.kind == .None {
		testing.expect_value(t, core.number(&long_doc, 0).kind, core.Number_Kind.Wide)
		core.destroy(&long_doc)
	}

	// 20 to 40 random digits with an optional fraction and exponent: a `.Float` has `strconv.parse_f64`'s bits, and
	// `.Wide` is what `strconv.parse_f64` refuses.
	state := u64(1)
	digits: [40]u8
	for round in 0 ..< 2000 {
		length := 20 + int(round % 21)
		for i in 0 ..< length {
			state = state * 6364136223846793005 + 1442695040888963407
			digits[i] = u8('0' + (state >> 33) % 10)
		}
		if digits[0] == '0' {
			digits[0] = '1'
		}
		text: [64]u8
		k := copy(text[:], digits[:length])
		if round % 3 == 0 {
			text[k] = '.'
			k += 1
			for i := 0; i < 5; i += 1 {
				state = state * 6364136223846793005 + 1442695040888963407
				text[k] = u8('0' + (state >> 33) % 10)
				k += 1
			}
		}
		if round % 4 == 0 {
			text[k] = 'e'
			k += 1
			text[k] = '-' if round % 8 == 0 else '+'
			k += 1
			text[k] = '3'
			k += 1
			text[k] = '0'
			k += 1
			text[k] = '0'
			k += 1
		}
		src := string(text[:k])
		doc, err := build(src, .Json)
		testing.expectf(t, err.kind == .None, "%q: %v", src, err)
		if err.kind != .None {
			return
		}
		got := core.number(&doc, 0)
		want, ok := strconv.parse_f64(src)
		if !ok {
			testing.expectf(t, got.kind == .Wide, "%q: %v, strconv refused", src, got)
		} else {
			testing.expectf(t, got.kind == .Float && got.bits == transmute(u64)want, "%q: %v, want %x", src, got, transmute(u64)want)
		}
		core.destroy(&doc)
	}
}

// A walk's fault becomes `.Walk` with the fault in `inner`, and `render_document` prints both lines.
@(test)
errors :: proc(t: ^testing.T) {
	src := `{`
	doc, err := build(src, .Json)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Walk)
	testing.expect_value(t, err.inner.at, 1)
	testing.expect_value(t, err.inner.kind, core.Fault_Kind.Truncated)
	testing.expect_value(t, len(doc.nodes), 0)
	b := strings.builder_make(context.temp_allocator)
	core.render_document(strings.to_writer(&b), transmute([]u8)src, err)
	testing.expect_value(t, strings.to_string(b), "1:2: Input does not parse\n  caused by 1:2: Unfinished input")

	doc, err = build(`{"a":1,"a":2}`, .Json, {}, .Refuse)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 7)
	strings.builder_reset(&b)
	core.render_document(strings.to_writer(&b), transmute([]u8)string(`{"a":1,"a":2}`), err)
	testing.expect_value(t, strings.to_string(b), "1:8: Duplicate key")
}

// `.Refuse` finds a repeat of an unquoted JSON5 key, at the later key's byte, 5.
@(test)
json5_duplicates :: proc(t: ^testing.T) {
	doc, err := build(`{a:1,a:2}`, .Json5, {}, .Refuse)
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

// A JSON document's spelling table has all five read services, and its edit table has `value`, `key` and `reads`, with
// `,` and `:` as the separators.
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
	testing.expect(t, s.edit != nil && s.edit.value != nil && s.edit.key != nil && s.edit.reads != nil)
	testing.expect_value(t, s.edit.member_sep, ",")
	testing.expect_value(t, s.edit.key_sep, ":")
}

// `.Refuse` finds a repeat in `{"a":1,"a":2 /* c */}` under JSONC, at byte 7, and leaves no nodes.
@(test)
refuse_with_comment :: proc(t: ^testing.T) {
	doc, err := build(`{"a":1,"a":2 /* c */}`, .Jsonc, {}, .Refuse)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 7)
	testing.expect_value(t, len(doc.nodes), 0)
}


// A number token's spelling has no `SPELLING_DECODE` bit, stays below bit 15, and `number_spelling_of` returns the
// spelling of each form.
@(test)
number_spelling_bits :: proc(t: ^testing.T) {
	doc, err := build(`[0, 1.5, 1e2, 0x10, Infinity, NaN, +1, .5, 5.]`, .Json5)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	want := []json.Number_Spelling{.Json, .Json, .Json, .Hex, .Infinity, .Nan, .Decimal, .Decimal, .Decimal}
	it := core.children(&doc, 0)
	i := 0
	for {
		v, more := core.child_next(&it)
		if !more {
			break
		}
		n := doc.nodes[v]
		testing.expect_value(t, n.kind, core.Kind.Number)
		testing.expect_value(t, n.spelling & core.SPELLING_DECODE, 0)
		testing.expect(t, n.spelling < 1 << 15)
		testing.expect_value(t, json.number_spelling_of(n.spelling), want[i])
		i += 1
	}
	testing.expect_value(t, i, len(want))
}

// Checks strings that cross the decoder's 64-byte block edge: an escape at the edge, a surrogate pair across it,
// `\u0000`, a string of escapes only, and plain strings of 63, 64 and 65 bytes.
@(test)
decode_edges :: proc(t: ^testing.T) {
	buf: [256]u8
	expect_decode :: proc(t: ^testing.T, src: string, want: []u8, buf: []u8) {
		doc, err := build(src, .Json)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", src, err) {
			return
		}
		s, ok := core.text(&doc, 0, buf)
		testing.expectf(t, ok && string(want) == s, "%q: %q, want %q", src, s, want)
	}

	// 63 `a` bytes then `\n`: the escape starts at byte 64, the second block's first byte.
	esc: [128]u8
	esc[0] = '"'
	for i in 1 ..= 63 {
		esc[i] = 'a'
	}
	esc[64] = '\\'
	esc[65] = 'n'
	esc[66] = '"'
	want: [64]u8
	for i in 0 ..< 63 {
		want[i] = 'a'
	}
	want[63] = '\n'
	expect_decode(t, string(esc[:67]), want[:64], buf[:])

	// A surrogate pair whose second escape starts past byte 64.
	for i in 1 ..= 58 {
		esc[i] = 'a'
	}
	copy(esc[59:], `\ud83d\ude00`)
	esc[71] = '"'
	for i in 0 ..< 58 {
		want[i] = 'a'
	}
	copy(want[58:], "\xf0\x9f\x98\x80")
	expect_decode(t, string(esc[:72]), want[:62], buf[:])

	expect_decode(t, `"\u0000"`, []u8{0}, buf[:])
	expect_decode(t, `"\n\t\r\"\\\/\b\f"`, []u8{'\n', '\t', '\r', '"', '\\', '/', '\b', '\f'}, buf[:])

	// Plain strings of 63, 64 and 65 bytes, and each with `\t` as its last byte.
	for n in 63 ..= 65 {
		plain: [80]u8
		plain[0] = '"'
		for i in 1 ..= n {
			plain[i] = 'b'
		}
		plain[n + 1] = '"'
		got: [80]u8
		for i in 0 ..< n {
			got[i] = 'b'
		}
		expect_decode(t, string(plain[:n + 2]), got[:n], buf[:])

		escaped: [80]u8
		escaped[0] = '"'
		for i in 1 ..< n {
			escaped[i] = 'b'
		}
		copy(escaped[n:], `\t"`)
		got[n - 1] = '\t'
		expect_decode(t, string(escaped[:n + 3]), got[:n], buf[:])
	}
}

// `key_equals` decodes a key whose `\n` escape starts 64 bytes into the key's span, and compares 65 decoded bytes.
@(test)
key_equals_escaped :: proc(t: ^testing.T) {
	src: [256]u8
	src[0] = '{'
	src[1] = '"'
	for i in 2 ..= 65 {
		src[i] = 'k'
	}
	copy(src[66:], `\n":1}`)
	doc, err := build(string(src[:72]), .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	name: [65]u8
	for i in 0 ..< 64 {
		name[i] = 'k'
	}
	name[64] = '\n'
	testing.expect(t, core.key_equals(&doc, 1, string(name[:65])))
	testing.expect(t, !core.key_equals(&doc, 1, "kk"))
}

// Under `Invalid_Utf8`, a key holding `\xff` decodes to `a\uFFFDb`, and `key_equals` and `member` find it by that text.
@(test)
tolerated_key :: proc(t: ^testing.T) {
	src := "{\"a\xffb\":0}"
	doc, err := build(src, .Json, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	buf: [16]u8
	k, ok := core.text(&doc, 1, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, k, "a\uFFFDb")
	testing.expect(t, core.key_equals(&doc, 1, k))
	v, found := core.member(&doc, 0, k)
	testing.expect(t, found)
	testing.expect_value(t, v, 2)
}

// Reads `text` into a buffer as long as the token's span and checks that it allocates nothing, for the scalar decoder
// and the block decoder. The decoded text is no longer than the span.
@(test)
decode_into_token_sized_buffer :: proc(t: ^testing.T) {
	arena: mem.Arena
	backing := make([]u8, 1 << 16, context.allocator)
	defer delete(backing)
	mem.arena_init(&arena, backing)
	alloc := mem.arena_allocator(&arena)
	texts := []string{`"\u0041"`, `"\uD800"`}
	for src in texts {
		doc, err := json.build(transmute([]u8)src, .Json, {tolerate = {.Lone_Surrogate}}, .Last, alloc)
		if !testing.expectf(t, err.kind == .None, "%q: %v", src, err) {
			continue
		}
		before := arena.offset
		buf: [16]u8
		s, ok := core.text(&doc, 0, buf[:len(src) - 2], alloc)
		testing.expectf(t, ok, "%q: no text", src)
		testing.expectf(t, arena.offset == before, "%q: allocated %d bytes", src, arena.offset - before)
		if src == texts[0] {
			testing.expect_value(t, s, "A")
		}
		core.destroy(&doc)
	}

	// The block decoder on a string of 300 `x` bytes and `\u0041`, past its 256-byte split.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_byte(&b, '"')
	for _ in 0 ..< 300 {
		strings.write_byte(&b, 'x')
	}
	strings.write_string(&b, `\u0041"`)
	src := strings.to_string(b)
	doc, err := json.build(transmute([]u8)src, .Json, {}, .Last, alloc)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "long: %v", err) {
		return
	}
	before := arena.offset
	buf: [400]u8
	s, ok := core.text(&doc, 0, buf[:len(src) - 2], alloc)
	testing.expect(t, ok)
	testing.expectf(t, arena.offset == before, "long: allocated %d bytes", arena.offset - before)
	testing.expect_value(t, len(s), 301)
	testing.expect_value(t, s[300], 'A')
}

// The first reservation is one node, 16 bytes, per source byte. A 24 MB arena refuses an 8 MB text holding one string,
// and the retry, with the checked hook, fits. A text of 2,000,000 nested arrays needs 2,000,001 nodes, 32 MB, and
// still fails with `.No_Memory`.
@(test)
reservation_retry :: proc(t: ^testing.T) {
	backing := make([]u8, 24 << 20, context.allocator)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	alloc := mem.arena_allocator(&arena)

	src := make([]u8, 8 << 20, context.allocator)
	defer delete(src)
	src[0] = '"'
	for i in 1 ..< len(src) - 1 {
		src[i] = 'a'
	}
	src[len(src) - 1] = '"'
	doc, err := json.build(src, .Json, {}, .Last, alloc)
	testing.expectf(t, err.kind == .None, "longtext in 24 MB: %v", err)
	core.destroy(&doc)

	// One node per level: 2,000,001 nodes of 16 bytes, more than the 24 MB arena.
	arena.offset = 0
	depth := 2_000_000
	nested := make([]u8, 2 * depth + 1, context.allocator)
	defer delete(nested)
	for i in 0 ..< depth {
		nested[i] = '['
		nested[len(nested) - 1 - i] = ']'
	}
	nested[depth] = '0'
	doc, err = json.build(nested, .Json, {max_depth = u32(depth + 1)}, .Last, alloc)
	testing.expectf(t, err.kind == .No_Memory, "deep in 24 MB: %v", err)
	core.destroy(&doc)
}

// A `Failing_Alloc` refuses the allocation numbered `fail_at`, counting from 0, and forwards every other call to
// `inner`.
Failing_Alloc :: struct {
	inner:   runtime.Allocator,
	n:       int,
	fail_at: int,
}

failing_alloc_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	f := (^Failing_Alloc)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if f.n == f.fail_at {
			f.n += 1
			return nil, .Out_Of_Memory
		}
		f.n += 1
	case .Free, .Free_All, .Query_Features, .Query_Info:
	}
	return f.inner.procedure(f.inner.data, mode, size, alignment, old_memory, old_size, loc)
}

// A `.Duplicate_Key` found before an allocation that then fails stays the error: `.No_Memory` names no byte and does
// not replace it.
@(test)
refuse_oom_keeps_duplicate :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `[{"a":1,"a":2},{`)
	for i in 0 ..< 41 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '"')
		strings.write_byte(&b, 'a' + u8(i))
		strings.write_string(&b, `":0`)
	}
	strings.write_string(&b, "}]")
	src := transmute([]u8)strings.to_string(b)
	// Allocations 0 and 1 are the node array and the open stack, before any repeat is found. Failing 2 to 4 leaves the
	// `.Duplicate_Key` at byte 8 as the error.
	for fail_at in 2 ..= 4 {
		f: Failing_Alloc
		f.inner = context.allocator
		f.fail_at = fail_at
		alloc := runtime.Allocator{procedure = failing_alloc_proc, data = &f}
		doc, err := json.build(src, .Json, {}, .Refuse, alloc)
		testing.expectf(t, err.kind == core.Document_Error_Kind.Duplicate_Key && err.at == 8, "fail_at %d: %v at %d", fail_at, err.kind, err.at)
		core.destroy(&doc)
	}
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
	commit_want :: proc(t: ^testing.T, src, want: string, $S: json.Spec, body: proc(list: ^core.Edit_List)) {
		doc, err := json.build(transmute([]u8)src, S)
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
		read, rerr := json.build(out, S)
		defer core.destroy(&read)
		if !testing.expectf(t, rerr.kind == .None, "%q: committed text does not read: %v in %q", src, rerr, out) {
			return
		}
	}

	commit_want(t, `[1,2]`, `[1,3]`, .Json, proc(list: ^core.Edit_List) {
		core.remove(list, 2)
		core.insert(list, 0, 1, transmute([]u8)string("3"))
	})
	commit_want(t, `[1,2]`, `[1,3]`, .Json, proc(list: ^core.Edit_List) {
		core.remove(list, 2)
		core.insert(list, 0, 2, transmute([]u8)string("3"))
	})
	commit_want(t, `{"a":1,"b":2,"c":3}`, `{"a":1,"x":9,"c":3}`, .Json, proc(list: ^core.Edit_List) {
		core.remove(list, 4)
		core.insert(list, 0, 1, transmute([]u8)string(`"x"`), transmute([]u8)string("9"))
	})
	commit_want(t, `{"a":1,"b":2,"c":3}`, `{"a":1,"x":9,"c":3}`, .Json, proc(list: ^core.Edit_List) {
		core.remove(list, 4)
		core.insert(list, 0, 2, transmute([]u8)string(`"x"`), transmute([]u8)string("9"))
	})
	commit_want(t, `[1]`, `[9]`, .Json, proc(list: ^core.Edit_List) {
		core.remove(list, 1)
		core.insert(list, 0, 0, transmute([]u8)string("9"))
	})
	commit_want(t, `[1]`, `[9]`, .Json, proc(list: ^core.Edit_List) {
		core.remove(list, 1)
		core.insert(list, 0, 1, transmute([]u8)string("9"))
	})
	commit_want(t, `[1,2,3]`, `[9,3]`, .Json, proc(list: ^core.Edit_List) {
		core.remove(list, 1)
		core.remove(list, 2)
		core.insert(list, 0, 1, transmute([]u8)string("9"))
	})
	commit_want(t, `[1,2]`, `[8,9]`, .Json, proc(list: ^core.Edit_List) {
		core.remove(list, 1)
		core.remove(list, 2)
		core.insert(list, 0, 0, transmute([]u8)string("8"))
		core.insert(list, 0, 2, transmute([]u8)string("9"))
	})

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
	testing.expect_value(t, core.insert(&list, 0, 2, transmute([]u8)string(`"x"`), transmute([]u8)string("9")).kind, core.Document_Error_Kind.None)
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

// A leading zero in a multi-digit integer run is a digit, not the zero of a `0.<fraction>` significand.
@(test)
number_decimal_leading_zero :: proc(t: ^testing.T) {
	for src in ([]string{"012345678901234567890123456789", "0012345678901234567890123456789"}) {
		got := core.number_decimal(transmute([]u8)src, 0, u64(len(src)))
		want, ok := strconv.parse_f64(src)
		testing.expectf(t, ok && got.kind == .Float && got.bits == transmute(u64)want, "%q: %v, want %x", src, got, transmute(u64)want)
	}
}

// An `Array` of 65535 members records `CHILDREN_MAX` in its spelling, and `length` counts all 65535.
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
	testing.expect_value(t, doc.nodes[0].spelling, core.CHILDREN_MAX)
	testing.expect_value(t, core.length(&doc, 0), 65535)
}
