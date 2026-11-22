package spell_tests

import "core:strconv"
import "core:strings"
import "core:testing"
import "stury:lib/base/spell"
import "stury:testkit"

Case :: struct {
	text: string,
	kind: spell.Number_Kind,
	bits: u64,
}

float_bits :: proc(f: f64) -> u64 {
	return transmute(u64)f
}

// `1` followed by `zeros` zeros, or `0.` followed by `zeros` zeros and a `1`.
big_one :: proc(zeros: int) -> string {
	return strings.concatenate({"1", strings.repeat("0", zeros, context.temp_allocator)}, context.temp_allocator)
}

small_one :: proc(zeros: int) -> string {
	return strings.concatenate({"0.", strings.repeat("0", zeros, context.temp_allocator), "1"}, context.temp_allocator)
}

expect_cases :: proc(t: ^testing.T, cases: []Case) {
	for c in cases {
		src := transmute([]u8)c.text
		num, ok := spell.number_strict(src, 0, u64(len(src)))
		testing.expectf(t, ok && num.kind == c.kind && num.bits == c.bits, "%s: %v %x, want %v %x", c.text, num.kind, num.bits, c.kind, c.bits)
	}
}

// Only a value past binary64's largest is `Wide`. Its spelling's length is no verdict: underflow reads as a signed zero,
// and long spellings of values that fit read as those values.
@(test)
wide_is_only_overflow :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := []Case {
		{"1e-5000", .Float, 0},
		{"-1e-5000", .Float, 1 << 63},
		{"0e5000", .Float, 0},
		{"-0e5000", .Float, 1 << 63},
		{"0.0e-99999999999999999999", .Float, 0},
		{"1e-324", .Float, 0},
		{"1e-323", .Float, 2},
		{"4.9e-324", .Float, 1},
		{"1e400", .Wide, 0},
		{"1e99999999999999999999", .Wide, 0},
		{"1e309", .Wide, 0},
		{"1.7976931348623157e308", .Float, 0x7FEF_FFFF_FFFF_FFFF},
		{"1.7976931348623159e308", .Wide, 0},
		{"0.00000000000000000000000000001e40", .Float, float_bits(1e11)},
		{"0.00000000000000000000000000001e340", .Wide, 0},
		{"100000000000000000000000000000e-5000", .Float, 0},
		{"10000000000000000000000000000000000000e-5000", .Float, 0},
		{"0.0000000000000000000000000000000000000000000000000000000000000001e320", .Float, float_bits(1e256)},
		{small_one(300), .Float, float_bits(1e-301)},
		{small_one(299), .Float, float_bits(1e-300)},
		{big_one(299), .Float, float_bits(1e299)},
		{big_one(308), .Float, float_bits(1e308)},
		{big_one(309), .Wide, 0},
		{big_one(400), .Wide, 0},
		{big_one(5000), .Wide, 0},
		{small_one(400), .Float, 0},
		{small_one(5000), .Float, 0},
	}
	expect_cases(t, cases)
}

// The Clinger fast path takes a significand up to 2^53 and a power of ten up to 10^37 when the product stays an exact
// integer below 10^15 before the last multiply, and every other case reads the same as `strconv` reads it.
@(test)
fast_path_boundaries_round_correctly :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := []Case {
		{"9007199254740992", .Int, 9007199254740992},
		{"9007199254740992e0", .Float, float_bits(9007199254740992)},
		{"9007199254740992e1", .Float, float_bits(9.007199254740992e16)},
		{"9007199254740993e0", .Float, float_bits(9007199254740992)},
		{"9007199254740993e1", .Float, float_bits(9.007199254740993e16)},
		{"9007199254740992e-1", .Float, float_bits(900719925474099.2)},
		{"9007199254740992e-22", .Float, float_bits(9.007199254740992e-7)},
		{"1e22", .Float, float_bits(1e22)},
		{"1e23", .Float, float_bits(1e23)},
		{"1e30", .Float, float_bits(1e30)},
		{"1e37", .Float, float_bits(1e37)},
		{"1e38", .Float, float_bits(1e38)},
		{"1.5e37", .Float, float_bits(1.5e37)},
		{"15e36", .Float, float_bits(1.5e37)},
		{"15e22", .Float, float_bits(1.5e23)},
		{"1000000000000000e22", .Float, float_bits(1e37)},
		{"1000000000000001e22", .Float, float_bits(1.000000000000001e37)},
		{"1000000000000001e23", .Float, float_bits(1.000000000000001e38)},
		{"123456789012345e23", .Float, float_bits(1.23456789012345e37)},
		{"4503599627370496e22", .Float, float_bits(4.503599627370496e37)},
		{"2e-22", .Float, float_bits(2e-22)},
		{"2e-23", .Float, float_bits(2e-23)},
		{"1.5e23", .Float, float_bits(1.5e23)},
		{"8.41e21", .Float, float_bits(8.41e21)},
		{"5e-324", .Float, 1},
	}
	expect_cases(t, cases)
}

// A decimal of any length reads as `strconv` reads it, or as `Wide` when `strconv` finds it past binary64.
@(test)
long_decimals_read_as_strconv_reads_them :: proc(t: ^testing.T) {
	testkit.deadline(t)
	texts := []string {
		"0.1000000000000000055511151231257827021181583404541015625",
		"0.30000000000000004440892098500626161694526672363281250000001",
		"123456789012345678901234567890",
		"123456789012345678901234567890e-20",
		"123456789012345678901234567890.123456789012345678901234567890",
		"1234567890123456789012345678901234567890e260",
		"0.000000000000000000001e-300",
		"2.2250738585072011e-308",
		"2.2250738585072014e-308",
		"1.00000000000000011102230246251565404236316680908203125",
		"1.00000000000000011102230246251565404236316680908203126",
		"9007199254740993.00000000000000000000001",
	}
	for text in texts {
		src := transmute([]u8)text
		num, ok := spell.number_strict(src, 0, u64(len(src)))
		want, _ := strconv.parse_f64(text)
		testing.expectf(t, ok && num.kind == .Float && num.bits == float_bits(want), "%s: %v %x, want %x", text, num.kind, num.bits, float_bits(want))
	}
}

// JSON5's decimals take the same size verdicts as strict ones.
@(test)
loose_numbers_share_the_size_verdicts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := []Case {
		{"+1e-5000", .Float, 0},
		{"-.0e5000", .Float, 1 << 63},
		{".5", .Float, float_bits(0.5)},
		{"+1e400", .Wide, 0},
	}
	for c in cases {
		src := transmute([]u8)c.text
		num, ok := spell.number_loose(src, 0, u64(len(src)))
		testing.expectf(t, ok && num.kind == c.kind && num.bits == c.bits, "%s: %v %x, want %v %x", c.text, num.kind, num.bits, c.kind, c.bits)
	}
}

// An integer of 19 to 21 digits is exact while it fits `u64`, and the 20th digit is read from the text.
@(test)
twenty_digit_integers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := []Case {
		{"1000000000000000000", .Int, 1_000_000_000_000_000_000},
		{"9999999999999999999", .Uint, 9_999_999_999_999_999_999},
		{"18446744073709551615", .Uint, max(u64)},
		{"18446744073709551616", .Float, float_bits(18446744073709551616.0)},
		{"99999999999999999999", .Float, float_bits(1e20)},
		{"-10000000000000000000", .Float, float_bits(-1e19)},
		{"184467440737095516150", .Float, float_bits(1.8446744073709552e20)},
	}
	expect_cases(t, cases)
}
