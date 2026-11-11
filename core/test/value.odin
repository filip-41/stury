// The readers of a value over its two forms, a built value and a node, and the typed bridges to a built value.
package core_test

import "core:fmt"
import "core:math"
import "core:math/big"
import "core:mem"
import "core:math/rand"
import "core:slice"
import "core:strconv"
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
		walktest.expect_nil(t, werr)
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

@(test)
a_built_value_keeps_the_comments_of_its_node :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	text := "// top\n{\"a\": /* before */ 1, // after\n\"b\": 2}"
	doc, err := core.build(transmute([]u8)text, json.as(.Jsonc))
	walktest.expect_nil(t, err)
	built := core.built_value(core.Node_Ref{&doc, core.ROOT})
	node := core.Value(core.Node_Ref{&doc, core.ROOT})
	for role in core.COMMENT_ROLES {
		want, _ := core.comments(node, role)
		got, from := core.comments(built, role)
		testing.expectf(t, len(got) == len(want) && (len(want) == 0) == (from == .None), "root %v: %v against %v", role, got, want)
		for body, i in want {
			testing.expectf(t, got[i] == body, "root %v: %q", role, got[i])
		}
	}
	a, _ := core.member(built, "a")
	bodies, _ := core.comments(a, .Comment)
	testing.expectf(t, len(bodies) == 1 && bodies[0] == "before", "member a: %v", bodies)
	testing.expect(t, core.equal(node, built))
}

// A number literal is the decimal it spells, at any size.
@(test)
literals_are_equal_exactly_at_any_size :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	Pair :: struct {
		x, y:  string,
		order: int,
	}
	pairs := [?]Pair {
		{"1234567890123456789012345678901234567890", "1234567890123456789012345678901234567891", -1},
		{"0.1234567890123456789012345678901234567890", "0.123456789012345678901234567890123456789", 0},
		{"1e400", "1e401", -1},
		{"1e400", "1.0e400", 0},
		{"-1e400", "-1e401", 1},
		{"1e-400", "0", 1},
		{"-1e-400", "0", -1},
		{"1e-400", "1e-401", 1},
		{"1e1000000000", "1e1000000001", -1},
		{"1e-2000000000", "2e-2000000000", -1},
		{"1e-2000000000", "0", 1},
		{"1e99999999999999999999999999999999999", "10e99999999999999999999999999999999998", 0},
		{"1e99999999999999999999999999999999999", "1e99999999999999999999999999999999998", 1},
		{"1.0", "1", 0},
		{"1e0", "10e-1", 0},
		{"-0", "0", 0},
		{"0.0e500", "0", 0},
	}
	for c in pairs {
		x, y := core.Value(core.number_text(c.x)), core.Value(core.number_text(c.y))
		testing.expectf(t, core.compare(x, y) == c.order, "%s <=> %s", c.x, c.y)
		testing.expectf(t, core.compare(y, x) == -c.order, "%s <=> %s", c.y, c.x)
		testing.expectf(t, core.equal(x, y) == (c.order == 0), "%s == %s", c.x, c.y)
		testing.expectf(t, c.order != 0 || core.hash(x) == core.hash(y), "%s and %s hash alike", c.x, c.y)
	}
	// A double is its shortest decimal, and an infinity is above every literal.
	testing.expect(t, core.equal(core.Value(f64(1.5)), core.number_text("1.50")))
	testing.expect(t, !core.equal(core.Value(f64(1.5)), core.number_text("1.5000000000000000000001")))
	testing.expect(t, !core.equal(core.Value(f64(0)), core.number_text("1e-400")))
	inf := core.Value(max(f64) * 2)
	testing.expect(t, core.compare(inf, core.number_text("1e400")) == 1 && core.compare(core.number_text("1e400"), inf) == -1)
	testing.expect(t, core.equal(inf, inf) && !core.equal(inf, core.number_text("1e400")))
}

// Numbers that are equal hash alike, over literals of random size respelled by moving the point, padding with zeros and
// scaling the exponent, and no respelling of a changed digit is equal.
@(test)
equal_literals_hash_alike :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	r := rand.create(0x5eed)
	context.random_generator = rand.default_random_generator(&r)
	spell :: proc(digits: string, exp10: string, split: int, pad: int, upper: bool) -> string {
		// 0.d1d2...dn × 10^exp10, spelled with its point after `split` digits
		point := len(digits) if split > len(digits) else split
		sb := strings.builder_make()
		strings.write_string(&sb, digits[:point])
		if point < len(digits) || pad > 0 {
			strings.write_byte(&sb, '.')
			strings.write_string(&sb, digits[point:])
			strings.write_string(&sb, strings.repeat("0", pad))
		}
		strings.write_byte(&sb, 'E' if upper else 'e')
		strings.write_string(&sb, exp_less(exp10, point))
		return strings.to_string(sb)
	}
	for _ in 0 ..< 3000 {
		n := 1 + int(rand.int_max(45))
		digits := make([]u8, n)
		for &c in digits {
			c = u8('0' + rand.int_max(10))
		}
		digits[0] = u8('1' + rand.int_max(9))
		digits[n - 1] = u8('1' + rand.int_max(9))
		// the exponent of 0.d... × 10^e: a few digits mostly, and sometimes more than any integer holds
		width := 1 + rand.int_max(4) if rand.int_max(4) != 0 else 25 + rand.int_max(15)
		exp := make([]u8, width)
		for &c in exp {
			c = u8('0' + rand.int_max(10))
		}
		exp[0] = u8('1' + rand.int_max(9))
		e := string(exp)
		if rand.int_max(2) == 0 {
			e = strings.concatenate({"-", e})
		}
		base := spell(string(digits), e, rand.int_max(n + 2), 0, false)
		for _ in 0 ..< 4 {
			other := spell(string(digits), e, rand.int_max(n + 2), rand.int_max(5), rand.int_max(2) == 0)
			x, y := core.Value(core.number_text(base)), core.Value(core.number_text(other))
			testing.expectf(t, core.equal(x, y), "%s and %s are one number", base, other)
			testing.expectf(t, core.hash(x) == core.hash(y), "%s and %s hash apart", base, other)
		}
		changed := make([]u8, n)
		copy(changed, digits)
		changed[n - 1] = u8('1' + (changed[n - 1] - '1' + 1) % 9)
		apart := core.Value(core.number_text(spell(string(changed), e, rand.int_max(n + 2), 0, false)))
		testing.expectf(t, !core.equal(core.Value(core.number_text(base)), apart), "%s and a changed last digit", base)
	}
}

// A double and its shortest decimal in any padding are one number with one hash.
@(test)
doubles_and_their_decimals_hash_alike :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	r := rand.create(0xd0b1e)
	context.random_generator = rand.default_random_generator(&r)
	buf: [64]u8
	for _ in 0 ..< 3000 {
		f := transmute(f64)rand.uint64()
		if math.is_nan(f) || math.is_inf(f) {
			continue
		}
		text := strconv.write_float(buf[:], f, 'e', -1, 64)
		at := strings.index_byte(text, 'e')
		padded := fmt.tprintf("%s%s00%s", text[:at], "" if strings.contains(text[:at], ".") else ".", text[at:])
		for lit in ([]string{text, padded}) {
			v := core.Value(core.number_text(lit))
			testing.expectf(t, core.equal(core.Value(f), v) && core.hash(core.Value(f)) == core.hash(v), "%v and %s", f, lit)
		}
	}
}

// The exponent of a literal whose point stands after `point` digits of 0.d... × 10^exp10: `exp10 - point`, as text.
@(private = "file")
exp_less :: proc(exp10: string, point: int) -> string {
	e, p: big.Int
	defer big.int_destroy(&e, &p)
	big.atoi(&e, exp10)
	big.int_set_from_integer(&p, point)
	big.int_sub(&e, &e, &p)
	text, _ := big.int_itoa_string(&e)
	return text
}

// Ordering and hashing numbers of any exponent allocate nothing, so a sort of them uses no temporary memory.
@(test)
wide_exponents_compare_and_hash_without_allocating :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	r := rand.create(0x71de)
	context.random_generator = rand.default_random_generator(&r)
	values := make([]core.Value, 4000)
	for &v in values {
		exp := make([]u8, 31 + rand.int_max(8))
		for &c in exp {
			c = u8('0' + rand.int_max(10))
		}
		exp[0] = u8('1' + rand.int_max(9))
		if rand.int_max(3) == 0 {
			// the neighbours of a power of ten, where the digit strings borrow and carry
			for &c in exp[1:] {
				c = '9' if rand.int_max(2) == 0 else '0'
			}
		}
		sign := "-" if rand.int_max(2) == 0 else ""
		v = core.number_text(fmt.aprintf("%de%s%s", 1 + rand.int_max(30), sign, string(exp)))
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.temp_allocator = mem.tracking_allocator(&track)
	slice.sort_by(values, proc(a, b: core.Value) -> bool {return core.compare(a, b) < 0})
	for i in 1 ..< len(values) {
		testing.expect(t, core.compare(values[i - 1], values[i]) <= 0)
		if core.equal(values[i - 1], values[i]) {
			testing.expect(t, core.hash(values[i - 1]) == core.hash(values[i]))
		}
	}
	testing.expect_value(t, track.total_allocation_count, 0)
}

// A decimal's exponent is told apart from a nearby one at the carry of its digits, whichever way it is held.
@(test)
exponents_at_a_carry_compare_exactly :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	pairs := [?][3]string {
		{"1e999999999999999999999999999999", "1e1000000000000000000000000000000", "-1"},
		{"10e999999999999999999999999999999", "1e1000000000000000000000000000000", "0"},
		{"1e1000000000000000000000000000000", "0.1e1000000000000000000000000000001", "0"},
		{"1e99999999999999999999999999999999999999", "1e100000000000000000000000000000000000000", "-1"},
		{"100e99999999999999999999999999999999999998", "1e100000000000000000000000000000000000000", "0"},
		{"1e100000000000000000000000000000000000000", "9.9e99999999999999999999999999999999999999", "1"},
		{"1e-999999999999999999999999999999", "1e-1000000000000000000000000000000", "1"},
		{"1e-1000000000000000000000000000000", "-1e-1000000000000000000000000000000", "1"},
		{"1e100000000000000000000000000000000000001", "1e100000000000000000000000000000000000000", "1"},
		{"1e100000000000000000000000000000000000000", "1e99999999999999999999999999999999999999", "1"},
		{"1e1000000000000000000000000000000", "1e999999999999999999999999999999", "1"},
		{"1e1000000000000000000000000000000", "1e1000000000000000000000000000000000", "-1"},
		{"1e1000000000000000000000000000000", "1e99999999999999999999999999999", "1"},
		{"5e-1000000000000000000000000000000", "-3e-1", "1"},
		{"1e1000000000000000000000000000000", "1e400", "1"},
	}
	for c in pairs {
		want := 0 if c[2] == "0" else (1 if c[2] == "1" else -1)
		x, y := core.Value(core.number_text(c[0])), core.Value(core.number_text(c[1]))
		testing.expectf(t, core.compare(x, y) == want, "%s <=> %s", c[0], c[1])
		testing.expectf(t, core.compare(y, x) == -want, "%s <=> %s", c[1], c[0])
		testing.expectf(t, want != 0 || core.hash(x) == core.hash(y), "%s and %s hash alike", c[0], c[1])
	}
}

// A decimal JSON5 spells with a sign or a point of its own is the number it spells, as the JSON spelling is, and a hex
// integer of at most 128 bits is the integer it spells.
@(test)
json5_spellings_compare_by_their_digits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	doc, err := core.build(transmute([]u8)string("[+1e400, 1e400, 1e401, .5e400, 5.e399, +1e-400, 0, 0x20000000000001, 9007199254740992, 9007199254740993]"), json.as(.Json5))
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	at :: proc(doc: ^core.Document, i: int) -> core.Value {
		n, _ := core.doc_child_at(doc, core.ROOT, i)
		return core.Node_Ref{doc, n}
	}
	same := [?][2]int{{0, 1}, {3, 4}, {7, 9}}
	for p in same {
		x, y := at(&doc, p[0]), at(&doc, p[1])
		testing.expectf(t, core.equal(x, y) && core.hash(x) == core.hash(y), "elements %d and %d", p[0], p[1])
	}
	below := [?][2]int{{1, 2}, {0, 2}, {6, 5}, {8, 9}, {8, 7}}
	for p in below {
		testing.expectf(t, core.compare(at(&doc, p[0]), at(&doc, p[1])) == -1, "element %d below %d", p[0], p[1])
		testing.expectf(t, core.compare(at(&doc, p[1]), at(&doc, p[0])) == 1, "element %d above %d", p[1], p[0])
	}
}

// A cell of a delimited text is a string, in the library as in the command line, unless `read_plain` reads it as the number it is
// compared with.
@(test)
a_cell_is_a_string_unless_read_as_a_number :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	doc, err := core.build(transmute([]u8)string("a\n1e-400\n"), dsv.as(.Csv))
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	row, _ := core.doc_child_at(&doc, core.ROOT, 0)
	n, _ := core.doc_child_at(&doc, row, 0)
	cell := core.Value(core.Node_Ref{&doc, n})
	number := core.Value(core.number_text("1e-400"))
	testing.expect(t, core.equal(cell, number, read_plain = true))
	testing.expect(t, core.compare(cell, number, eq = true) != 0)
	testing.expect(t, core.compare(cell, core.Value("1e-400"), eq = true) == 0)
}

// A hex integer of up to 128 bits equals, orders and hashes as the decimal that spells it, and one past 128 bits is its double.
@(test)
hex_integers_are_their_decimals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	r := rand.create(0x4ec5)
	context.random_generator = rand.default_random_generator(&r)
	N :: 600
	hexes, decimals := strings.builder_make(), strings.builder_make()
	strings.write_byte(&hexes, '[')
	strings.write_byte(&decimals, '[')
	for i in 0 ..< N {
		bits := 1 + rand.int_max(128)
		v: u128
		for _ in 0 ..< bits {
			v = v << 1 | u128(rand.int_max(2))
		}
		if i % 5 == 0 {
			v = v >> uint(rand.int_max(bits)) // short ones, where a double holds the integer
		}
		neg := rand.int_max(3) == 0 && v != 0
		sep := "," if i > 0 else ""
		fmt.sbprintf(&hexes, "%s%s%s%s%x", sep, "-" if neg else "", "0x" if rand.int_max(2) == 0 else "0X", strings.repeat("0", rand.int_max(3)), v)
		fmt.sbprintf(&decimals, "%s%s%d", sep, "-" if neg else "", v)
	}
	strings.write_byte(&hexes, ']')
	strings.write_byte(&decimals, ']')
	hd, herr := core.build(transmute([]u8)strings.to_string(hexes), json.as(.Json5))
	defer core.destroy(&hd)
	dd, derr := core.build(transmute([]u8)strings.to_string(decimals), json.as(.Json5))
	defer core.destroy(&dd)
	walktest.expect_nil(t, herr)
	walktest.expect_nil(t, derr)
	at :: proc(doc: ^core.Document, i: int) -> core.Value {
		n, _ := core.doc_child_at(doc, core.ROOT, i)
		return core.Node_Ref{doc, n}
	}
	for i in 0 ..< N {
		x, y := at(&hd, i), at(&dd, i)
		testing.expectf(t, core.equal(x, y) && core.hash(x) == core.hash(y), "element %d", i)
		if i > 0 {
			testing.expectf(t, core.compare(x, at(&dd, i - 1)) == core.compare(y, at(&dd, i - 1)), "element %d against %d", i, i - 1)
		}
	}
	big, berr := core.build(transmute([]u8)string("[0x100000000000000000000000000000000, 340282366920938463463374607431768211456, 3.402823669209385e38]"), json.as(.Json5))
	defer core.destroy(&big)
	walktest.expect_nil(t, berr)
	testing.expect(t, core.equal(at(&big, 0), at(&big, 2)) && core.hash(at(&big, 0)) == core.hash(at(&big, 2)))
	testing.expect(t, !core.equal(at(&big, 0), at(&big, 1)))
}
