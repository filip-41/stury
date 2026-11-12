// RFC 8949 Appendix A: every example's bytes read, and the value the table gives for it equals the document written as JSON.
package cbor_tests

import "core:encoding/json"
import "core:strings"
import "core:testing"
import core "../../core"
import walktest "../../walktest"
import cbor ".."
import stury_json "../../json"

@(private)
APPENDIX_A :: #load("vectors/appendix_a.json", string)

// The table's `simple(24)`, which Appendix F lists among the two-byte simple values below 32 that are not well-formed.
@(private)
SIMPLE_24 :: "f818"

@(private)
same_value :: proc(a, b: json.Value) -> bool {
	number :: proc(v: json.Value) -> (f64, bool) {
		#partial switch n in v {
		case json.Integer:
			return f64(n), true
		case json.Float:
			return f64(n), true
		}
		return 0, false
	}
	if x, ok := number(a); ok {
		y, other := number(b)
		return other && (x == y || x != x && y != y)
	}
	#partial switch x in a {
	case json.Null:
		_, ok := b.(json.Null)
		return ok
	case json.Boolean:
		y, ok := b.(json.Boolean)
		return ok && x == y
	case json.String:
		y, ok := b.(json.String)
		return ok && x == y
	case json.Array:
		y, ok := b.(json.Array)
		if !ok || len(x) != len(y) {
			return false
		}
		for _, i in x {
			if !same_value(x[i], y[i]) {
				return false
			}
		}
		return true
	case json.Object:
		y, ok := b.(json.Object)
		if !ok || len(x) != len(y) {
			return false
		}
		for k, v in x {
			w, found := y[k]
			if !found || !same_value(v, w) {
				return false
			}
		}
		return true
	}
	return false
}

// A row with a `decoded` value reads, and the document written as JSON is that value. A bignum is a number there, a
// tag is dropped, and a byte string would be base64 text.
@(test)
appendix_a_decoded_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	table, err := json.parse(transmute([]u8)APPENDIX_A)
	testing.expect_value(t, err, json.Error.None)
	rows := table.(json.Array)
	testing.expect_value(t, len(rows), 82)
	compared := 0
	for row in rows {
		entry := row.(json.Object)
		input := hex(entry["hex"].(json.String))
		if entry["hex"].(json.String) == SIMPLE_24 {
			continue
		}
		if fault, bad := walktest.fault_of(cbor.validate(input, .Cbor)).?; bad {
			testing.expectf(t, false, "%s: %v", entry["hex"], fault)
			continue
		}
		want, has := entry["decoded"]
		if !has {
			continue
		}
		doc, derr := cbor.build(input, .Cbor)
		if !testing.expectf(t, derr == nil, "%s: %v", entry["hex"], derr) {
			continue
		}
		defer core.destroy(&doc)
		text, _, werr := core.write(&doc, {}, stury_json.as(.Json))
		if !testing.expectf(t, werr == nil, "%s: %v", entry["hex"], werr) {
			continue
		}
		got, perr := json.parse(text)
		if !testing.expectf(t, perr == .None, "%s wrote %s", entry["hex"], string(text)) {
			continue
		}
		testing.expectf(t, same_value(want, got), "%s: want %v, wrote %s", entry["hex"], want, string(text))
		compared += 1
	}
	testing.expect_value(t, compared, 59)
}

// Appendix A gives `f818` as `simple(24)` and Appendix F lists it as not well-formed. The walk follows Appendix F and the
// pseudocode of Appendix C.
@(test)
appendix_a_simple_24_is_refused :: proc(t: ^testing.T) {
	fault, bad := walktest.fault_of(cbor.validate(hex(SIMPLE_24), .Cbor)).?
	testing.expect(t, bad)
	testing.expect_value(t, cbor.Detail(fault.detail), cbor.Detail.Bad_Simple)
}

// A row with `roundtrip` true is in preferred serialization, so the walk that judges it accepts it.
@(test)
appendix_a_roundtrip_rows_are_preferred :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	table, _ := json.parse(transmute([]u8)APPENDIX_A)
	preferred := 0
	for row in table.(json.Array) {
		entry := row.(json.Object)
		input := hex(entry["hex"].(json.String))
		if !entry["roundtrip"].(json.Boolean) || entry["hex"].(json.String) == SIMPLE_24 {
			continue
		}
		fault, bad := walktest.fault_of(cbor.validate(input, .Preferred)).?
		testing.expectf(t, !bad, "%s: %v", entry["hex"], fault)
		preferred += 1
	}
	testing.expect_value(t, preferred, 64)
}

// The rows the table gives only a diagnostic notation for: the value each one reads as.
@(test)
appendix_a_diagnostic_rows :: proc(t: ^testing.T) {
	Row :: struct {
		hex:  string,
		want: string,
	}
	rows := [?]Row {
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
		doc, err := cbor.build(hex(r.hex), .Cbor)
		if !testing.expectf(t, err == nil, "%s: %v", r.hex, err) {
			continue
		}
		defer core.destroy(&doc)
		sb := strings.builder_make(context.temp_allocator)
		dump(&sb, &doc, core.ROOT)
		testing.expectf(t, strings.to_string(sb) == r.want, "%s: want %s, got %s", r.hex, r.want, strings.to_string(sb))
	}
}

// The tags of the diagnostic rows are facts before their content, and a tag is the number its head spells.
@(test)
appendix_a_tags_are_facts :: proc(t: ^testing.T) {
	doc, err := cbor.build(hex("c11a514b67b0"), .Cbor)
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	testing.expect_value(t, len(doc.facts), 1)
	testing.expect_value(t, doc.facts[0].role, core.Role.Tag)
	number, ok := core.fact_number(&doc, doc.facts[0])
	testing.expect(t, ok)
	testing.expect_value(t, number.bits, 1)
}
