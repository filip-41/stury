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

int_bits :: proc(v: i64) -> u64 {
	return u64(v)
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

// The short readers read every span they take as `number_strict` does, and `integer_short` takes every integer of at
// most 16 digits that has 8 bytes past its first digit: each span of each text, with bytes past it or none.
@(test)
short_readers_agree_with_the_strict_one :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	texts := []string {
		"0", "-0", "7", "-7", "10", "007", "-01", "1234567", "12345678", "-12345678", "123456789", "9999999999999999",
		"-9999999999999999", "10000000000000000", "1790000002", "1.5", "-67.54717", "68789.78", "0.25", "00.5", "1.", ".5",
		"1e5", "+1", "--1", "1-", "12a4", "1 2", "", "-", "1.2.3", "123456789012345.6", "1234567890123456.7",
		"12345678.12345678", "1234567.12345678", "-0.5", "0.30000000000000004", "9007199.254740993", "147.19909",
	}
	for text in ([]string{"147.19909", "-67.54717", "0.25", "-0", "12345678", "1234567.12345678", "1.5"}) {
		src := transmute([]u8)strings.concatenate({text, strings.repeat(",", 17, context.temp_allocator)}, context.temp_allocator)
		_, ok := spell.float_short(src, 0, u64(len(text)))
		testing.expectf(t, ok, "float %q refused", text)
	}
	for text in texts {
		for pad in ([]int{0, 16}) {
			src := transmute([]u8)strings.concatenate({text, strings.repeat(",", pad, context.temp_allocator)}, context.temp_allocator)
			for lo in 0 ..< len(text) {
				for hi in lo ..= len(text) {
					want, valid := spell.number_strict(src, u64(lo), u64(hi))
					digits := hi - lo - int(text[lo] == '-')
					if v, ok := spell.integer_short(src, u64(lo), u64(hi)); ok {
						testing.expectf(t, valid && want.kind == .Int && i64(want.bits) == v, "integer %q: %d, want %v %v", text[lo:hi], v, want, valid)
					} else if pad > 0 && valid && want.kind == .Int && digits <= 16 && !strings.contains_any(text[lo:hi], ".eE") {
						testing.expectf(t, false, "integer %q refused", text[lo:hi])
					}
					if n, ok := spell.number_short(src, u64(lo), u64(hi)); ok {
						testing.expectf(t, valid && n == want, "short %q: %v, want %v %v", text[lo:hi], n, want, valid)
					}
					if f, ok := spell.float_short(src, u64(lo), u64(hi)); ok {
						// `-0` is the integer 0 to the strict reader, and a float keeps its sign.
						as_float := transmute(f64)want.bits if want.kind == .Float else f64(i64(want.bits))
						minus := text[lo] == '-'
						testing.expectf(t, valid && want.kind <= .Float && f == as_float && (f < 0 || f == 0 && minus) == minus, "float %q: %v, want %v %v", text[lo:hi], f, want, valid)
					}
				}
			}
		}
	}
}

// `number_int` agrees with `number_strict` below, at, and above `FOLD_WORDS_FROM` (24), including `i64` extremes and
// 19-digit unsigned values, and rejects out-of-range digit counts or values below `min(i64)`.
@(test)
number_int_across_fold_words_boundary :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	cases := []Case {
		{"0", .Int, 0},
		{"-0", .Int, 0},
		{"7", .Int, 7},
		{"-7", .Int, int_bits(-7)},
		{"12345678", .Int, 12_345_678},
		{"-12345678", .Int, int_bits(-12_345_678)},
		{"123456789", .Int, 123_456_789},
		{"1234567890123456", .Int, 1_234_567_890_123_456},
		{"-1234567890123456", .Int, int_bits(-1_234_567_890_123_456)},
		{"12345678901234567", .Int, 12_345_678_901_234_567},
		{"9223372036854775807", .Int, u64(max(i64))},
		{"-9223372036854775808", .Int, u64(1) << 63},
		{"9223372036854775808", .Uint, u64(1) << 63},
		{"9999999999999999999", .Uint, 9_999_999_999_999_999_999},
	}
	// Sweep prefix lengths so `hi` crosses `FOLD_WORDS_FROM` (24) with arbitrary non-ASCII prefix bytes before `lo`.
	for prefix_len in ([]int{0, 1, 5, 8, 15, 16, 22, 23, 24, 25, 32}) {
		for c in cases {
			buf := make([]u8, prefix_len + len(c.text) + 4, context.temp_allocator)
			for i in 0 ..< prefix_len {
				buf[i] = 0xFF if i & 1 == 0 else 'x'
			}
			copy(buf[prefix_len:], c.text)
			for i in prefix_len + len(c.text) ..< len(buf) {
				buf[i] = ','
			}
			lo := u64(prefix_len)
			hi := u64(prefix_len + len(c.text))
			digits := len(c.text) - int(c.text[0] == '-')
			num, ok := spell.number_int(buf, lo, hi, digits)
			testing.expectf(t, ok && num.kind == c.kind && num.bits == c.bits, "prefix=%d %s: %v %x (ok=%v), want %v %x", prefix_len, c.text, num.kind, num.bits, ok, c.kind, c.bits)
		}
	}
	// Values below `min(i64)` and invalid digit counts are rejected by `number_int`.
	rejects := []struct {
		text:   string,
		digits: int,
	} {
		{"-9223372036854775809", 19},
		{"-9999999999999999999", 19},
		{"12345678901234567890", 20},
		{"123", 0},
		{"123", 2},
		{"123", 4},
	}
	for prefix_len in ([]int{0, 24}) {
		for r in rejects {
			buf := make([]u8, prefix_len + len(r.text), context.temp_allocator)
			for i in 0 ..< prefix_len {
				buf[i] = ' '
			}
			copy(buf[prefix_len:], r.text)
			_, ok := spell.number_int(buf, u64(prefix_len), u64(len(buf)), r.digits)
			testing.expectf(t, !ok, "prefix=%d %s (digits=%d): expected reject", prefix_len, r.text, r.digits)
		}
	}
}

// `number_fraction` agrees with `number_strict` across the `FOLD_WORDS_FROM + 19` (43) threshold, covering the
// merged-word (`<= 7`), Clinger (`8..15`), fast-float (`16..19`), and long-decimal (`> 19`) paths.
@(test)
number_fraction_across_fold_words_boundary :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	cases := []struct {
		text:                string,
		int_digits, frac_dig: int,
	} {
		{"0.0", 1, 1},
		{"-0.0", 1, 1},
		{"1.5", 1, 1},
		{"-67.54717", 2, 5},
		{"123456.7", 6, 1},
		{"1.234567", 1, 6},
		{"12345678.1", 8, 1},
		{"-12345.67890123", 5, 8},
		{"12345678.1234567", 8, 7},
		{"123456789.1234567", 9, 7},
		{"-123456789.123456789", 9, 9},
		{"1234567890.123456789", 10, 9},
		{"9999999999.999999999", 10, 9},
		{"-0.123456789012345678", 1, 18},
		{"123456789012345678.9", 18, 1},
		{"1234567890.12345678901234567890", 10, 20},
		{"12345678901234567890.12345678901234567890", 20, 20},
	}
	// Sweep `prefix_len` and `tail_len` so `hi` sits below, at, and above `43` and `start + 8` crosses `len(src)`.
	for prefix_len in ([]int{0, 10, 24, 35, 40, 42, 43, 44, 50}) {
		for tail_len in ([]int{0, 8}) {
			for c in cases {
				buf := make([]u8, prefix_len + len(c.text) + tail_len, context.temp_allocator)
				for i in 0 ..< prefix_len {
					buf[i] = 0xFF if i & 1 == 0 else ','
				}
				copy(buf[prefix_len:], c.text)
				for i in prefix_len + len(c.text) ..< len(buf) {
					buf[i] = ','
				}
				lo := u64(prefix_len)
				hi := u64(prefix_len + len(c.text))
				want, valid := spell.number_strict(buf, lo, hi)
				got := spell.number_fraction(buf, lo, hi, c.int_digits, c.frac_dig)
				testing.expectf(t, valid && got == want, "prefix=%d tail=%d %s: %v %x, want %v %x", prefix_len, tail_len, c.text, got.kind, got.bits, want.kind, want.bits)
			}
		}
	}
}

// `number_exponent` agrees with `number_strict` across `FOLD_WORDS_FROM` (24), both <= 19 and > 19 digits, and falls
// back cleanly when the supplied digit counts do not match.
@(test)
number_exponent_across_fold_words_boundary :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	cases := []struct {
		text:                 string,
		int_digits, frac_dig: int,
	} {
		{"0e0", 1, 0},
		{"-0e0", 1, 0},
		{"1e5", 1, 0},
		{"1.5e23", 1, 1},
		{"-67.54717e-2", 2, 5},
		{"12345678e10", 8, 0},
		{"123456789e-10", 9, 0},
		{"-12345678.901234567E+12", 8, 9},
		{"1234567890123456789e-18", 19, 0},
		{"1.7976931348623157e308", 1, 16},
		{"1.7976931348623159e308", 1, 16},
		{"1e-5000", 1, 0},
		{"12345678901234567890.12345e-5", 20, 5},
		// Mismatched counts still fall back to `number_decimal`.
		{"12.34e5", 1, 2},
		{"1234e5", 4, 1},
	}
	for prefix_len in ([]int{0, 8, 16, 22, 23, 24, 25, 32}) {
		for c in cases {
			buf := make([]u8, prefix_len + len(c.text) + 4, context.temp_allocator)
			for i in 0 ..< prefix_len {
				buf[i] = 0xFF if i & 1 == 0 else ' '
			}
			copy(buf[prefix_len:], c.text)
			for i in prefix_len + len(c.text) ..< len(buf) {
				buf[i] = ','
			}
			lo := u64(prefix_len)
			hi := u64(prefix_len + len(c.text))
			want, valid := spell.number_strict(buf, lo, hi)
			got := spell.number_exponent(buf, lo, hi, c.int_digits, c.frac_dig)
			testing.expectf(t, valid && got == want, "prefix=%d %s: %v %x, want %v %x", prefix_len, c.text, got.kind, got.bits, want.kind, want.bits)
		}
	}
}

// `number_strict` handles `i64` extremes (`min(i64)`, `max(i64)`, `min(i64) - 1`) and never mistakes high-bit
// non-ASCII bytes (`0x80`, `0xB0`, `0xBA`, `0xFF`) for ASCII digits in either `number_short` or `digit_fold`.
@(test)
i64_extremes_and_high_bit_terminators :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	expect_cases(t, []Case {
		{"9223372036854775807", .Int, u64(max(i64))},
		{"9223372036854775808", .Uint, u64(1) << 63},
		{"-9223372036854775808", .Int, u64(1) << 63},
		{"-9223372036854775809", .Float, float_bits(-9223372036854775809.0)},
	})
	high_bytes := []u8{0x80, 0xAF, 0xB0, 0xB9, 0xBA, 0xFF}
	prefixes := []string{"1", "1234567", "12345678", "123456789", "1234567890123456", "12345678901234567", "9223372036854775807"}
	for b in high_bytes {
		for pad in ([]int{0, 16}) {
			for p in prefixes {
				// High-bit byte inside the span must be rejected.
				bad := make([]u8, len(p) + 1 + pad, context.temp_allocator)
				copy(bad, p)
				bad[len(p)] = b
				for i in len(p) + 1 ..< len(bad) {
					bad[i] = '0'
				}
				_, bad_ok := spell.number_strict(bad, 0, u64(len(p) + 1))
				testing.expectf(t, !bad_ok, "prefix=%q byte=0x%02x pad=%d: high-bit byte inside span accepted", p, b, pad)

				// High-bit byte immediately past `hi` must not corrupt the valid span before it.
				good_want, want_ok := spell.number_strict(transmute([]u8)p, 0, u64(len(p)))
				good_got, got_ok := spell.number_strict(bad, 0, u64(len(p)))
				testing.expectf(t, want_ok && got_ok && good_got == good_want, "prefix=%q trailing=0x%02x pad=%d: %v %x, want %v %x", p, b, pad, good_got.kind, good_got.bits, good_want.kind, good_want.bits)
			}
		}
	}
}
