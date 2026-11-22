package json_tests

import "core:strings"
import "core:testing"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:testkit"

// Only a value past binary64's largest reads as `Wide`, through the digit counts a walk gives: a spelling's length or
// exponent that a value outgrows or undercuts is no verdict, and underflow keeps its sign.
@(test)
numbers_are_wide_only_on_overflow :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		text: string,
		kind: spell.Number_Kind,
		bits: u64,
	}
	zeros := strings.repeat("0", 299, context.temp_allocator)
	cases := []Case {
		{"1e-5000", .Float, 0},
		{"-1e-5000", .Float, 1 << 63},
		{"0e5000", .Float, 0},
		{"-0.0e5000", .Float, 1 << 63},
		{"1e-324", .Float, 0},
		{"1e-323", .Float, 2},
		{"1e400", .Wide, 0},
		{"1e99999999999999999999", .Wide, 0},
		{"1.7976931348623157e308", .Float, 0x7FEF_FFFF_FFFF_FFFF},
		{"1.7976931348623159e308", .Wide, 0},
		{strings.concatenate({"0.", zeros, "1"}, context.temp_allocator), .Float, transmute(u64)f64(1e-300)},
		{strings.concatenate({"1", zeros}, context.temp_allocator), .Float, transmute(u64)f64(1e299)},
		{strings.concatenate({"1", zeros, "e10"}, context.temp_allocator), .Wide, 0},
		{strings.concatenate({"0.", zeros, "1e300"}, context.temp_allocator), .Float, transmute(u64)f64(1)},
		{"9007199254740992e22", .Float, transmute(u64)f64(9.007199254740992e37)},
		{"1.5e37", .Float, transmute(u64)f64(1.5e37)},
		{"1e23", .Float, transmute(u64)f64(1e23)},
		{"1e30", .Float, transmute(u64)f64(1e30)},
	}
	for c in cases {
		for sep in ([]string{"", "  "}) {
			doc, err := build(t, strings.concatenate({"[", sep, c.text, sep, "]"}, context.temp_allocator))
			testing.expect_value(t, err, nil)
			num, ok := tape.node_number(&doc, first_value(t, &doc))
			testing.expectf(t, ok && num.kind == c.kind && num.bits == c.bits, "%s: %v %x, want %v %x", c.text, num.kind, num.bits, c.kind, c.bits)
			tape.destroy(&doc)
		}
	}
}
