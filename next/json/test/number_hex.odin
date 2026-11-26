package json_tests

import "core:strings"
import "core:testing"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:testkit"

// JSON5 hex integers return exact `Int`/`Uint` while they fit 64 bits, round larger values to nearest-even binary64
// with sticky tie-breaking across trailing digits, and return `Wide` past binary64's range.
@(test)
json5_hex_rounding_and_overflow :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Hex_Case :: struct {
		digits: string,
		neg:    bool,
		kind:   spell.Number_Kind,
		bits:   u64,
	}
	cases := []Hex_Case {
		{"0", false, .Int, 0},
		{"0", true, .Int, 0},
		{"00000000000000000000", false, .Int, 0},
		{"000000000000000000ff", false, .Int, 0xFF},
		{"deadBEEF", true, .Int, ~u64(0xDEADBEEF - 1)},
		{"7fffffffffffffff", false, .Int, u64(max(i64))},
		{"8000000000000000", false, .Uint, u64(1) << 63},
		{"8000000000000000", true, .Int, u64(1) << 63},
		{"ffffffffffffffff", false, .Uint, max(u64)},
		{"ffffffffffffffff", true, .Float, 0xC3F0_0000_0000_0000},
		// 16-digit negative round-to-even + sticky boundaries.
		{"8000000000000001", true, .Float, 0xC3E0_0000_0000_0000},
		{"8000000000000400", true, .Float, 0xC3E0_0000_0000_0000},
		{"8000000000000401", true, .Float, 0xC3E0_0000_0000_0001},
		{"8000000000000c00", true, .Float, 0xC3E0_0000_0000_0002},
		// 17-digit and 18-digit round-to-even + sticky tie-breaking.
		{"10000000000000800", false, .Float, 0x43F0_0000_0000_0000},
		{"10000000000000801", false, .Float, 0x43F0_0000_0000_0001},
		{"10000000000001800", false, .Float, 0x43F0_0000_0000_0002},
		{"100000000000008000", false, .Float, 0x4430_0000_0000_0000},
		{"100000000000008001", false, .Float, 0x4430_0000_0000_0001},
		{"100000000000018000", false, .Float, 0x4430_0000_0000_0002},
		// 256-digit max finite vs midpoint overflow, and 257-digit overflow (with and without leading zeros).
		{strings.concatenate({"fffffffffffffb", strings.repeat("f", 242, context.temp_allocator)}, context.temp_allocator), false, .Float, 0x7FEF_FFFF_FFFF_FFFF},
		{strings.concatenate({"FFFFFFFFFFFFFC", strings.repeat("0", 242, context.temp_allocator)}, context.temp_allocator), false, .Wide, 0},
		{strings.concatenate({"1", strings.repeat("0", 255, context.temp_allocator)}, context.temp_allocator), false, .Float, 0x7FB0_0000_0000_0000},
		{strings.concatenate({"00001", strings.repeat("0", 255, context.temp_allocator)}, context.temp_allocator), false, .Float, 0x7FB0_0000_0000_0000},
		{strings.concatenate({"1", strings.repeat("0", 256, context.temp_allocator)}, context.temp_allocator), false, .Wide, 0},
		{strings.concatenate({"1", strings.repeat("0", 256, context.temp_allocator)}, context.temp_allocator), true, .Wide, 0},
	}
	for c in cases {
		prefix := "-0x" if c.neg else "0x"
		src := strings.concatenate({"[", prefix, c.digits, "]"}, context.temp_allocator)
		doc, err := build(t, src, spec = .Json5)
		testing.expect_value(t, err, nil)
		got, ok := tape.node_number(&doc, first_value(t, &doc))
		testing.expectf(t, ok && got.kind == c.kind && got.bits == c.bits, "hex(neg=%v, len=%d): %v %x, want %v %x", c.neg, len(c.digits), got.kind, got.bits, c.kind, c.bits)
		tape.destroy(&doc)
	}
}

// Short escaped keys across every UTF-8 width boundary (1..4 bytes) keep exact decoded lengths and text.
@(test)
short_escaped_key_utf8_widths :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		key_raw: string,
		want:    string,
	}
	cases := []Case {
		{`\u0000`, "\x00"},
		{`\u0041`, "A"},
		{`\u007F`, "\x7F"},
		{`\u0080`, "\xc2\x80"},
		{`\u00E9`, "\xc3\xa9"},
		{`\u07FF`, "\xdf\xbf"},
		{`\u0800`, "\xe0\xa0\x80"},
		{`\u20AC`, "\xe2\x82\xac"},
		{`\uFFFF`, "\xef\xbf\xbf"},
		{`\uD800\uDC00`, "\xf0\x90\x80\x80"},
		{`\uD83D\uDE00`, "\xf0\x9f\x98\x80"},
		{`\uDBFF\uDFFF`, "\xf4\x8f\xbf\xbf"},
	}
	for c in cases {
		// Pad past `PROBE_MAX` (32 bytes) so `key_escaped_head` -> `escape_credit` -> `rune_len` runs.
		src := strings.concatenate({`{"`, c.key_raw, `":1,"padding_past_probe_max_32_bytes":2}`}, context.temp_allocator)
		doc, err := build(t, src)
		testing.expect_value(t, err, nil)
		key_idx := tape.Node_Index(1)
		buf: [64]u8
		got, ok := tape.node_text(&doc, doc.nodes[key_idx], buf[:])
		testing.expectf(t, ok && got == c.want, "%q: got (%q, %v), want %q", c.key_raw, got, ok, c.want)
		tape.destroy(&doc)
	}
}
