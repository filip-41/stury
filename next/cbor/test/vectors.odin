package cbor_tests

import stock "core:encoding/cbor"
import "core:encoding/json"
import "core:strconv"
import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// RFC 8949 Appendix A: every example's bytes read, and the value the table gives for it is the document's.

APPENDIX_A :: #load("vectors/appendix_a.json", string)

// The table's `simple(24)`, which Appendix F lists among the two-byte simple values below 32 that are not well-formed.
SIMPLE_24 :: "f818"

// Whether node `at` of `doc` reads as the value `v` of the table: a number by its binary64 value, a byte string as the
// base64 the table gives no row of, and a key by its text.
same_value :: proc(doc: ^tape.Document, at: tape.Node_Index, v: json.Value) -> bool {
	node := doc.nodes[at]
	#partial switch x in v {
	case json.Null:
		return node.kind == .Null && node.spelling == 0
	case json.Boolean:
		return node.kind == (.True if x else .False)
	case json.Integer:
		return number_is(doc, at, f64(x))
	case json.Float:
		return number_is(doc, at, x)
	case json.String:
		s, ok := text_of(doc, at)
		return ok && s == x
	case json.Array:
		if node.kind != .Array || int(node.spelling & tape.MAX_CHILDREN) != len(x) {
			return false
		}
		k := at + 1
		for e in x {
			if !same_value(doc, k, e) {
				return false
			}
			k = tape.node_after(doc, k)
		}
		return true
	case json.Object:
		if node.kind != .Object || int(node.spelling & tape.MAX_CHILDREN) != len(x) {
			return false
		}
		for k, e in x {
			m, p := cbor.member({doc = doc}, at, k)
			if p != .Found || !same_value(doc, m, e) {
				return false
			}
		}
		return true
	}
	return false
}

// Whether node `at` of `doc` is a number of binary64 value `want`.
number_is :: proc(doc: ^tape.Document, at: tape.Node_Index, want: f64) -> bool {
	n, ok := cbor.node_number(doc, at)
	got: f64
	switch n.kind {
	case .Int:
		got = f64(i64(n.bits))
	case .Uint:
		got = f64(n.bits)
	case .Float:
		got = transmute(f64)n.bits
	case .Wide:
		buf: [64]u8
		text, held := cbor.node_text(doc, at, buf[:])
		parsed, _ := strconv.parse_f64(text)
		got = parsed
		ok &&= held
	}
	return ok && (got == want || got != got && want != want)
}

// A row with a `decoded` value reads, and its document is that value. A tag is a fact, and a bignum is the number it
// spells.
@(test)
appendix_a_decoded_values :: proc(t: ^testing.T) {
	testkit.deadline(t)
	table, err := json.parse(transmute([]u8)APPENDIX_A, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	rows := table.(json.Array)
	testing.expect_value(t, len(rows), 82)
	compared := 0
	for row in rows {
		entry := row.(json.Object)
		input := testkit.hex(entry["hex"].(json.String))
		if entry["hex"].(json.String) == SIMPLE_24 {
			continue
		}
		if verr := cbor.validate(input, .Cbor); verr != nil {
			testing.expectf(t, false, "%s: %v", entry["hex"], verr)
			continue
		}
		want, has := entry["decoded"]
		if !has {
			continue
		}
		doc, derr := cbor.build(input, .Cbor, allocator = context.temp_allocator)
		if !testing.expectf(t, derr == nil, "%s: %v", entry["hex"], derr) {
			continue
		}
		testing.expectf(t, same_value(&doc, cbor.ROOT, want), "%s: want %v, got %s", entry["hex"], want, dumped(input))
		compared += 1
	}
	testing.expect_value(t, compared, 59)
}

// Appendix A gives `f818` as `simple(24)` and Appendix F lists it as not well-formed. The walk follows Appendix F and
// the pseudocode of Appendix C.
@(test)
appendix_a_simple_24_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, testkit.code_of(cbor.validate(testkit.hex(SIMPLE_24), .Cbor)), "bad_simple")
}

// The rows the table gives only a diagnostic notation for: the value each one reads as.
@(test)
appendix_a_diagnostic_rows :: proc(t: ^testing.T) {
	testkit.deadline(t)
	rows := [?]struct {
		hex, want: string,
	} {
		{"f97c00", "f:7ff0000000000000"},
		{"f97e00", "nan"},
		{"f9fc00", "f:fff0000000000000"},
		{"fa7f800000", "f:7ff0000000000000"},
		{"fa7fc00000", "nan"},
		{"faff800000", "f:fff0000000000000"},
		{"fb7ff0000000000000", "f:7ff0000000000000"},
		{"fb7ff8000000000000", "nan"},
		{"fbfff0000000000000", "f:fff0000000000000"},
		{"f7", "simple(23)"},
		{"f0", "simple(16)"},
		{"f8ff", "simple(255)"},
		{"c074323031332d30332d32315432303a30343a30305a", `"2013-03-21T20:04:00Z"`},
		{"c11a514b67b0", "i:1363896240"},
		{"c1fb41d452d9ec200000", "f:41d452d9ec200000"},
		{"d74401020304", "h:01020304"},
		{"d818456449455446", "h:6449455446"},
		{"d82076687474703a2f2f7777772e6578616d706c652e636f6d", `"http://www.example.com"`},
		{"40", "h:"},
		{"4401020304", "h:01020304"},
		{"a201020304", `{"1":i:2,"3":i:4}`},
		{"5f42010243030405ff", "h:0102030405"},
	}
	for r in rows {
		got := dumped(testkit.hex(r.hex))
		testing.expectf(t, got == r.want, "%s: want %s, got %s", r.hex, r.want, got)
	}
}

// Every row of Appendix A reads through a find that stops early and through a scan of the whole text, as it does
// through a build.
@(test)
appendix_a_reads_through_finds_and_scans :: proc(t: ^testing.T) {
	testkit.deadline(t)
	table, _ := json.parse(transmute([]u8)APPENDIX_A, allocator = context.temp_allocator)
	for row in table.(json.Array) {
		text := row.(json.Object)["hex"].(json.String)
		if text == SIMPLE_24 {
			continue
		}
		src := testkit.hex(text)
		for path in ([][]tape.Step{{tape.Name("a")}, {tape.Index(0)}, {tape.Index(0), tape.Name("a")}}) {
			_, err := cbor.find(src, path, .Cbor, {stop_early = true}, allocator = context.temp_allocator)
			testing.expectf(t, err == nil, "%s: find %v", text, err)
		}
		demand := tape.Demand{}
		_, err := cbor.scan(src, &demand, .Cbor, allocator = context.temp_allocator)
		testing.expectf(t, err == nil, "%s: scan %v", text, err)
	}
}

// A text nested to the default depth limit reads, and one level more is refused for its depth.
@(test)
the_default_depth_is_the_boundary :: proc(t: ^testing.T) {
	testkit.deadline(t)
	nest := proc(levels: int) -> []u8 {
		b := make([]u8, levels + 1, context.temp_allocator)
		for i in 0 ..< levels {
			b[i] = 0x81
		}
		return b
	}
	testing.expect_value(t, cbor.validate(nest(tape.DEFAULT_DEPTH)), nil)
	testing.expect_value(t, testkit.code_of(cbor.validate(nest(tape.DEFAULT_DEPTH + 1))), "exceeded Depth")
}

// The stock decoder reads every row of Appendix A, and refuses the malformed items this one refuses but for the ones it
// reads loosely.
@(test)
the_stock_decoder_agrees_on_the_appendices :: proc(t: ^testing.T) {
	testkit.deadline(t)
	table, _ := json.parse(transmute([]u8)APPENDIX_A, allocator = context.temp_allocator)
	for row in table.(json.Array) {
		text := row.(json.Object)["hex"].(json.String)
		if text == SIMPLE_24 {
			continue
		}
		_, err := stock.decode_from_string(string(testkit.hex(text)), allocator = context.temp_allocator)
		testing.expectf(t, err == nil, "%s: the stock decoder gives %v", text, err)
	}
	for c in MALFORMED {
		// The stock decoder reads one item and ignores what follows it, and reads the two-byte simples below 32.
		if c.code == "trailing" || c.code == "bad_simple" || c.hex == "9f ff ff" {
			continue
		}
		_, err := stock.decode_from_string(string(testkit.hex(c.hex)), allocator = context.temp_allocator)
		testing.expectf(t, err != nil, "%s: the stock decoder reads it", c.hex)
	}
}
