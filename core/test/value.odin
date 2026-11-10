// The readers of a value over its two forms, a built value and a node, and the typed bridges to a built value.
package core_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import core ".."
import typed "../typed"
import write "../write"
import json "../../json"
import dsv "../../dsv"
import walktest "../../walktest"

// What each reader answers for one text, which a node of the text and its built value must both give.
@(private = "file")
Reader_Case :: struct {
	text:   string,
	kind:   core.Kind,
	length: int,
	first:  core.Kind, // the kind of child 0, `.Null` when there is none
	member: string, // a member `a` holds as text, "" when there is none
}

@(private = "file")
READER_CASES := [?]Reader_Case {
	{`null`, .Null, 0, .Null, ""},
	{`true`, .True, 0, .Null, ""},
	{`12.5`, .Number, 0, .Null, ""},
	{`"x"`, .String, 0, .Null, ""},
	{`[1,"b",[]]`, .Array, 3, .Number, ""},
	{`{"a":"v","b":[1]}`, .Object, 2, .String, "v"},
	{`[]`, .Array, 0, .Null, ""},
	{`{}`, .Object, 0, .Null, ""},
}

@(test)
readers_answer_alike_for_a_node_and_a_built_value :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	for c in READER_CASES {
		doc, err := core.build(transmute([]u8)c.text, json.as(.Json))
		walktest.expect_nil(t, err)
		node := core.Value(core.Node_Ref{&doc, core.ROOT})
		built := core.built_value(core.Node_Ref{&doc, core.ROOT})
		for v in ([]core.Value{node, built}) {
			testing.expectf(t, core.kind(v) == c.kind, "%s: kind %v", c.text, core.kind(v))
			testing.expectf(t, core.length(v) == c.length, "%s: length %d", c.text, core.length(v))
			first, has := core.child_at(v, 0)
			if c.kind == .Object {
				it := core.pairs(v)
				_, first, has = core.pair_next(&it)
			}
			testing.expectf(t, (core.kind(first) if has else .Null) == c.first, "%s: first child", c.text)
			a, found := core.member(v, "a")
			buf: [16]u8
			s, _ := core.text(a, buf[:])
			testing.expectf(t, found == (c.member != "") && s == c.member, "%s: member a", c.text)
		}
		testing.expectf(t, core.equal(node, built) && core.hash(node) == core.hash(built), "%s: equal and hash", c.text)
		core.destroy(&doc)
	}
	n, _ := core.number(core.Value(f64(3)))
	testing.expect_value(t, n.kind, core.Number_Kind.Int)
	n, _ = core.number(core.Value(f64(2.5)))
	testing.expect_value(t, n.kind, core.Number_Kind.Float)
}

// An object with a repeated key, as a node and as a built value holding both members: `member` takes the last but under
// `.First`, `pairs` and the writer give both, and two such objects are equal and hash alike.
@(test)
repeated_key_reads_alike_in_both_forms :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	src := `{"a":1,"b":true,"a":2}`
	doc, err := core.build(transmute([]u8)string(src), json.as(.Json))
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	built := core.new_object()
	append(&built.keys, "a", "b", "a")
	append(&built.vals, core.Value(core.number_text("1")), core.Value(true), core.Value(f64(2)))
	node := core.Value(core.Node_Ref{&doc, core.ROOT})
	for v in ([]core.Value{node, built}) {
		last, _ := core.member(v, "a")
		first, _ := core.member(v, "a", .First)
		l, _ := core.number(last)
		f, _ := core.number(first)
		testing.expect_value(t, l.bits, 2)
		testing.expect_value(t, f.bits, 1)
		it := core.pairs(v)
		keys: [dynamic]string
		for k in core.pair_next(&it) {
			append(&keys, k)
		}
		testing.expect_value(t, len(keys), 3)
		text, werr := write.write_value(v, json.as(.Json))
		testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(text), src)
	}
	testing.expect(t, core.equal(node, built))
	testing.expect_value(t, core.hash(node), core.hash(built))
}

// A typed value becomes a built value, an integer past 2^53 keeping its digits, and reads back into its type.
@(test)
typed_bridges_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	S :: struct {
		n:   int,
		f:   f64,
		s:   string,
		big: u64,
		xs:  []i32,
	}
	plan, perr := json.plan_make(S, reads = json.reads(.Json))
	walktest.expect_nil(t, perr)
	in_value := S{n = 7, f = 2.5, s = "x", big = 1 << 60 + 1, xs = {1, -2}}
	v, merr := write.marshal_value(in_value, &plan)
	walktest.expect_nil(t, merr)
	n, _ := core.member(v, "n")
	big, _ := core.member(v, "big")
	_, is_double := n.(f64)
	testing.expect(t, is_double)
	testing.expect_value(t, big.(^core.Number_Text).text, "1152921504606846977")
	out: S
	walktest.expect_nil(t, typed.unmarshal(v, &out, &plan))
	testing.expect_value(t, out.n, 7)
	testing.expect_value(t, out.f, 2.5)
	testing.expect_value(t, out.s, "x")
	testing.expect_value(t, out.big, in_value.big)
	testing.expect(t, len(out.xs) == 2 && out.xs[1] == -2)
	// An integer field takes a double that holds an integer, and refuses one that does not.
	I :: struct {
		n: int,
	}
	iplan, _ := json.plan_make(I, reads = json.reads(.Json))
	whole := core.new_object()
	core.object_put(whole, "n", f64(3))
	i: I
	walktest.expect_nil(t, typed.unmarshal(core.Value(whole), &i, &iplan))
	testing.expect_value(t, i.n, 3)
	core.object_put(whole, "n", f64(3.5))
	testing.expect(t, typed.unmarshal(core.Value(whole), &i, &iplan) != nil)
}

// Two numbers equal by exact value hash alike however they are spelled, a node and a built value included, and numbers
// that differ only past a double's digits are not equal.
@(test)
equal_numbers_hash_alike :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	same := [?][]string{{"0", "-0", "0.0", "-0e5"}, {"1", "1.0", "10e-1", "0.1e1", "1E0"}, {"1e400", "10e399", "1.0e+400"}}
	for group in same {
		first := core.Value(core.number_text(group[0]))
		for spelling in group {
			doc, err := core.build(transmute([]u8)spelling, json.as(.Json))
			walktest.expect_nil(t, err)
			for v in ([]core.Value{core.Node_Ref{&doc, core.ROOT}, core.number_text(spelling)}) {
				testing.expectf(t, core.equal(first, v) && core.hash(first) == core.hash(v), "%s and %s", group[0], spelling)
			}
			core.destroy(&doc)
		}
	}
	a, b := core.Value(core.number_text("100000000000000000001")), core.Value(core.number_text("100000000000000000000"))
	testing.expect(t, !core.equal(a, b))
	testing.expect(t, !core.equal(core.number_text("1e400"), core.number_text("1e401")))
}

// A number whose digits a double does not spell keeps them when built, and then equals what its node equals.
@(test)
built_numbers_keep_digits_and_equal_like_nodes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	pairs := [?][2]string {
		{"100000000000000000001", "100000000000000000000"},
		{"1.5e-400", "0"},
		{"0.10000000000000000000001", "0.1"},
		{"9007199254740993.0", "9007199254740992"},
		{"123456789012345678901234567890", "1.2345678901234568e+29"},
	}
	for pair in pairs {
		built: [2]core.Value
		nodes: [2]core.Value
		docs: [2]core.Document
		for text, i in pair {
			err: core.Error
			docs[i], err = core.build(transmute([]u8)text, json.as(.Json))
			walktest.expect_nil(t, err)
			nodes[i] = core.Node_Ref{&docs[i], core.ROOT}
			built[i] = core.built_value(nodes[i].(core.Node_Ref))
		}
		_, kept := built[0].(^core.Number_Text)
		testing.expectf(t, kept, "%s keeps its digits", pair[0])
		testing.expectf(t, core.equal(nodes[0], nodes[1]) == core.equal(built[0], built[1]), "%s and %s", pair[0], pair[1])
		testing.expectf(t, !core.equal(built[0], built[1]), "%s and %s are two numbers", pair[0], pair[1])
	}
}

// A built object follows the read's `Duplicates`.
@(test)
built_object_follows_duplicates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	src := `{"k": 1, "j": 0, "k": 2}`
	doc, err := core.build(transmute([]u8)src, json.as(.Json))
	walktest.expect_nil(t, err)
	root := core.Node_Ref{&doc, core.ROOT}
	testing.expect_value(t, core.length(core.built_value(root, .All)), 3)
	first := core.built_value(root, .First)
	testing.expect_value(t, core.length(first), 2)
	k, _ := core.member(first, "k")
	testing.expect_value(t, k.(f64), 1)
	testing.expect_value(t, core.length(core.built_value(root, .Last)), 2)
}

// Literals of one double that differ past its digits hash apart, so a uniqueness check pairs none of them.
@(test)
distinct_literals_of_one_double_hash_apart :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	seen := make(map[u64]bool)
	zeros := strings.repeat("0", 20)
	start := time.now()
	for i in 1 ..= 2000 {
		lit := fmt.tprintf("0.1%s1%04d", zeros, i)
		seen[core.hash(core.number_text(lit))] = true
	}
	testing.expect_value(t, len(seen), 2000)
	testing.expect(t, time.since(start) < time.Second)
}

// Spellings of one value hash alike, a shortest-form literal like its double.
@(test)
shortest_and_long_spellings_hash_alike :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	same := [?][]string{{"0.1", "0.10", "1e-1", "0.1000"}, {"0.30000000000000004", "3.0000000000000004e-1"}, {"5e-324", "0.5e-323"}}
	for group in same {
		first := core.Value(core.number_text(group[0]))
		for spelling in group {
			v := core.Value(core.number_text(spelling))
			testing.expectf(t, core.equal(first, v) && core.hash(first) == core.hash(v), "%s and %s", group[0], spelling)
		}
	}
	// Past decNumber's range a literal reads as its double, so these are equal.
	far := [?][2]string{{"1e-2000000000", "2e-2000000000"}, {"1e-2000000000", "0"}, {"1e1000000000", "2e1000000000"}}
	for pair in far {
		x, y := core.Value(core.number_text(pair[0])), core.Value(core.number_text(pair[1]))
		testing.expectf(t, core.equal(x, y) && core.hash(x) == core.hash(y), "%s and %s", pair[0], pair[1])
	}
	testing.expect(t, core.hash(core.number_text("0.30000000000000004")) == core.hash(core.Value(0.30000000000000004)))
	testing.expect(t, core.hash(core.number_text("0.1")) == core.hash(core.Value(0.1)))
}

// A delimited cell hashes as the number an int operand makes it, and objects hash alike in any key order.
@(test)
cell_and_key_order_hash_alike :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	doc, err := core.build(transmute([]u8)string("a\n7\n"), dsv.as(.Csv))
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	row, _ := core.doc_child_at(&doc, core.ROOT, 0)
	cell, _ := core.doc_child_at(&doc, row, 0)
	testing.expect(t, core.hash(core.Node_Ref{&doc, cell}, like = core.Value(f64(7))) == core.hash(core.Value(f64(7))))
	a, aerr := core.build(transmute([]u8)string(`{"x":1.0,"y":[0.10]}`), json.as(.Json))
	defer core.destroy(&a)
	b, berr := core.build(transmute([]u8)string(`{"y":[1e-1],"x":1}`), json.as(.Json))
	defer core.destroy(&b)
	walktest.expect_nil(t, aerr)
	walktest.expect_nil(t, berr)
	na, nb := core.Node_Ref{&a, core.ROOT}, core.Node_Ref{&b, core.ROOT}
	testing.expect(t, core.equal(na, nb) && core.hash(na) == core.hash(nb))
}
