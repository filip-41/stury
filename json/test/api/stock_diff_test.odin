package json_tests

// Differential against Odin's stock `core:encoding/json`, through
// json/test/stock. Only `.Mismatch` is a defect. The other classes are the
// documented ways the two parsers part.
//
// The fixtures pin one class (and the decoded value, where one matters) each,
// so a classifier that waves everything through fails here, the private suite
// feeds generated documents through the same call.

import json "../.."
import stock "../stock"
import sj "core:encoding/json"
import "core:strings"
import "core:testing"

BITS_ONE :: u64(0x3ff0000000000000)
BITS_NEG_ZERO :: u64(0x8000000000000000)

// --- fixtures ----------------------------------------------------------------

Fixture :: struct {
	doc:   string,
	class: stock.Class,
	row:   int, // the node row whose number `bits` describes
	bits:  Maybe(u64),
}

FIXTURES :: []Fixture {
	{doc = `{"a":1}`, class = .Agree, row = 1, bits = BITS_ONE},
	{doc = "1 ", class = .Agree},
	{doc = "[1]\n", class = .Agree},
	{doc = `{"b":1,"a":2}`, class = .Agree},
	{doc = "-0", class = .Agree, bits = BITS_NEG_ZERO},
	{doc = "-0.0", class = .Agree, bits = BITS_NEG_ZERO},
	{doc = "9007199254740993", class = .Agree, bits = u64(0x4340000000000000)},
	{doc = "1e308", class = .Agree, bits = u64(0x7fe1ccf385ebc8a0)},
	{doc = "-1e308", class = .Agree, bits = u64(0xffe1ccf385ebc8a0)},
	{doc = "5e-324", class = .Agree, bits = u64(0x1)},
	{doc = "1e-323", class = .Agree, bits = u64(0x2)},
	{doc = "-1e-400", class = .Agree, bits = BITS_NEG_ZERO},
	{doc = "-0e400", class = .Agree, bits = BITS_NEG_ZERO},
	{doc = "1e4097", class = .Budget},
	{doc = "1e1000000000", class = .Budget},
	// The largest subnormal and the smallest normal, the pair that sent Java and PHP into a loop, and
	// subnormals deeper down.
	{doc = "2.2250738585072011e-308", class = .Agree, bits = u64(0x000fffffffffffff)},
	{doc = "2.2250738585072014e-308", class = .Agree, bits = u64(0x0010000000000000)},
	{doc = "[1e-310,1e-315,1e-320]", class = .Agree, row = 1, bits = u64(0x12688b70e62b)},
	{doc = "[1e-310,1e-315,1e-320]", class = .Agree, row = 2, bits = u64(0xc1069cd)},
	{doc = "[1e-310,1e-315,1e-320]", class = .Agree, row = 3, bits = u64(0x7e8)},
	// Stock misrounded this by one ULP before Odin dev-2026-10.
	{doc = "295.408154539e39", class = .Agree, bits = u64(0x488b21032883a6ec)},
	{doc = `{"a":1,"a":2}`, class = .Duplicate},
	// Stock drops an empty-keyed member, so only the tape can pin its value.
	{doc = `{"":1,"a":2}`, class = .Agree, row = 1, bits = BITS_ONE},
	{doc = `{"":1,"":2}`, class = .Agree, row = 1, bits = BITS_ONE},
	{doc = `{"":1,"":2}`, class = .Agree, row = 2, bits = u64(0x4000000000000000)},
	{doc = "\xef\xbb\xbf1", class = .Agree, bits = BITS_ONE},
	{doc = "1x", class = .Both_Reject},
	{doc = "1\v", class = .Stock_Lax},
	{doc = "1\f", class = .Stock_Lax},
	{doc = "01", class = .Stock_Lax},
	{doc = "-01", class = .Stock_Lax},
	{doc = "[1,]", class = .Stock_Lax},
	{doc = `{"a":1,}`, class = .Stock_Lax},
	{doc = "1\x00zz", class = .Stock_Lax},
	{doc = "\"a\x01\"", class = .Stock_Lax},
	{doc = "\"\xff\"", class = .Stock_Lax},
	// A lead byte closed by the quote: stury's `Bad_Char`, not `Truncated`.
	{doc = "\"\xe2\"", class = .Stock_Lax},
	// An overlong form and an encoded surrogate half.
	{doc = "\"foo\xc0\xafbar\"", class = .Stock_Lax},
	{doc = "\"foo\xed\xa0\x80bar\"", class = .Stock_Lax},
	// Tokenizer errors stock's parser drops.
	{doc = "1.", class = .Stock_Lax},
	{doc = "[1e]", class = .Stock_Lax},
	{doc = `"\q"`, class = .Stock_Lax},
	{doc = `"\ud97"`, class = .Stock_Lax},
	{doc = `"abc`, class = .Stock_Lax},
	// Stury's refusals of these are right only if the grammar says so.
	{doc = "[-]", class = .Both_Reject},
	// Five invalid bytes in one string overrun stock's buffer.
	{doc = "\"\xff\xff\xff\xff\xff\"", class = .Skipped},
	// Raw UTF-8 in a string must not hit the lax rule.
	{doc = `"é"`, class = .Agree},
	// A surrogate pair, and a lone high surrogate, which stock reads as U+FFFD and stury refuses.
	{doc = `"\ud83d\ude00"`, class = .Agree},
	{doc = `"\ud83d"`, class = .Stock_Lax},
	// A length-prefixed string keeps the NUL and what follows.
	{doc = `"foo\u0000bar"`, class = .Agree},
}

expect_class :: proc(t: ^testing.T, doc: []byte, want: stock.Class, loc := #caller_location) -> stock.Diff {
	d := stock.diff_document(doc)
	testing.expectf(
		t,
		d.class == want,
		"%q: class %v, want %v (stury %v, stock %v, detail %q)",
		string(doc),
		d.class,
		want,
		d.stury_err,
		d.stock_err,
		d.detail,
		loc = loc,
	)
	return d
}

@(test)
test_stock_diff_fixtures :: proc(t: ^testing.T) {
	for f in FIXTURES {
		expect_class(t, raw(f.doc), f.class)
		want, has := f.bits.?
		if !has {
			continue
		}
		doc := build_ok(t, f.doc)
		defer json.destroy(&doc)
		got, _ := json.get_number(&doc, json.Node(f.row))
		testing.expectf(t, transmute(u64)got.value == want, "%q row %d: bits %#x, want %#x", f.doc, f.row, transmute(u64)got.value, want)
	}
}

// Past binary64's range stury refuses the number and stock reads infinity, the
// result is `.None`, not a zero.
@(test)
test_stock_diff_overflow_is_refused :: proc(t: ^testing.T) {
	for doc in ([]string{"2e308", "1e309", "1e400", "-1e400", "1e4096"}) {
		expect_class(t, raw(doc), .Agree)
		built := build_ok(t, doc)
		defer json.destroy(&built)
		n, _ := json.get_number(&built, json.ROOT)
		testing.expect_value(t, n.exactness, json.Exactness.None)
	}
}

// The ones that need building: past the digit cap, and at the depth cap.
@(test)
test_stock_diff_built_documents :: proc(t: ^testing.T) {
	ones := make([]u8, 257)
	defer delete(ones)
	for &b in ones {
		b = '1'
	}
	expect_class(t, ones, .Budget)

	Nest :: struct {
		depth: int,
		want:  stock.Class,
	}
	for n in ([]Nest{{stock.STOCK_MAX_DEPTH, .Agree}, {stock.STOCK_MAX_DEPTH + 1, .Skipped}}) {
		depth, want := n.depth, n.want
		doc := strings.concatenate({strings.repeat("[", depth, context.temp_allocator), "-0", strings.repeat("]", depth, context.temp_allocator)}, context.temp_allocator)
		expect_class(t, raw(doc), want)
		if want != .Agree {
			continue
		}
		built := build_ok(t, doc)
		defer json.destroy(&built)
		got, _ := json.get_number(&built, json.Node(depth))
		testing.expect_value(t, transmute(u64)got.value, BITS_NEG_ZERO)
	}
}

// The walk reports the first disagreement: a nested value's, not the member count its parent then differs by.
@(test)
test_stock_diff_reports_first_disagreement :: proc(t: ^testing.T) {
	doc := build_ok(t, `{"a":{"x":"y"}}`)
	defer json.destroy(&doc)
	inner := make(sj.Object)
	inner["x"] = sj.String("z")
	defer delete(inner)
	outer := make(sj.Object)
	outer["a"], outer["b"] = inner, sj.Null{}
	defer delete(outer)
	w := stock.Walk{doc = &doc}
	stock.walk_value(&w, json.ROOT, outer)
	testing.expect_value(t, w.detail, "string differs")
}
