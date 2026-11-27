package spell_tests

import "core:math"
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

// A value past binary64's largest is `Wide`, as is a span past `MAX_NUMBER_DIGITS` (4096) whose order does not settle
// overflow or underflow. Underflow reads as a signed zero whatever its length, and spellings within the cap read as
// their rounded binary64 values.
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

@(private = "file")
Digit_Case :: struct {
	text:                 string,
	int_digits, frac_dig: int,
}

@(private = "file")
expect_fold_sweep :: proc(
	t: ^testing.T,
	cases: []Digit_Case,
	prefixes, tails: []int,
	odd_fill: u8,
	read: proc "contextless" (src: []u8, lo, hi: u64, int_digits, frac_digits: int) -> spell.Number,
	loc := #caller_location,
) {
	for prefix_len in prefixes {
		for tail_len in tails {
			for c in cases {
				buf := make([]u8, prefix_len + len(c.text) + tail_len, context.temp_allocator)
				for i in 0 ..< prefix_len {
					buf[i] = 0xFF if i & 1 == 0 else odd_fill
				}
				copy(buf[prefix_len:], c.text)
				for i in prefix_len + len(c.text) ..< len(buf) {
					buf[i] = ','
				}
				lo := u64(prefix_len)
				hi := u64(prefix_len + len(c.text))
				want, valid := spell.number_strict(buf, lo, hi)
				got := read(buf, lo, hi, c.int_digits, c.frac_dig)
				testing.expectf(t, valid && got == want, "prefix=%d tail=%d %s: %v %x, want %v %x", prefix_len, tail_len, c.text, got.kind, got.bits, want.kind, want.bits, loc = loc)
			}
		}
	}
}

// `number_fraction` agrees with `number_strict` across the `FOLD_WORDS_FROM + 19` (43) threshold, covering the
// merged-word (`<= 7`), Clinger (`8..15`), fast-float (`16..19`), and long-decimal (`> 19`) paths.
@(test)
number_fraction_across_fold_words_boundary :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	cases := []Digit_Case {
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
	expect_fold_sweep(
		t,
		cases,
		[]int{0, 10, 24, 35, 40, 42, 43, 44, 50},
		[]int{0, 8},
		',',
		proc "contextless" (s: []u8, lo, hi: u64, id, fd: int) -> spell.Number {
			return spell.number_fraction(s, lo, hi, id, fd)
		},
	)
}

// `number_exponent` agrees with `number_strict` across `FOLD_WORDS_FROM` (24), both <= 19 and > 19 digits, and falls
// back cleanly when the supplied digit counts do not match.
@(test)
number_exponent_across_fold_words_boundary :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	cases := []Digit_Case {
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
	expect_fold_sweep(
		t,
		cases,
		[]int{0, 8, 16, 22, 23, 24, 25, 32},
		[]int{4},
		' ',
		proc "contextless" (s: []u8, lo, hi: u64, id, fd: int) -> spell.Number {
			return spell.number_exponent(s, lo, hi, id, fd)
		},
	)
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

// IEEE-754 halfway midpoints (exact `2^-1075`, subnormal/normal, `max(f64)` halfway, Eisel-Lemire 19-digit edges)
// and the `MAX_NUMBER_DIGITS` (4096 vs 4097) slow-path cutoff.
@(test)
ieee754_midpoints_and_max_number_digits :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	// Exact 2^-1075 (752 significant digits): midpoint between 0 and min subnormal 2^-1074.
	HALF_SUB_DIGITS :: "2.4703282292062327208828439643411068618252990130716238221279284125033775363510437593264991818081799618989828234772285886546332835517796989819938739800539093906315035659515570226392290858392449105184435931802849936536152500319370457678249219365623669863658480757001585769269903706311928279558551332927834338409351978015531246597263579574622766465272827220056374006485499977096599470454020828166226237857393450736339007967761930577506740176324673600968951340535537458516661134223766678604162159680461914467291840300530057530849048765391711386591646239524912623653881879636239373280423891018672348497668235089863388587925628302755995657524455507255189313690836254779186948667994968324049705821028513185451396213837722826145437693412532098591327667236328125"
	// Exact (2^53 - 0.5) * 2^971: midpoint between max(f64) and +Inf.
	MAX_HALF :: "179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792"
	MAX_BELOW :: "179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497791"

	cases := []Case {
		{HALF_SUB_DIGITS + "e-324", .Float, 0},
		{HALF_SUB_DIGITS + "1e-324", .Float, 1},
		{"-" + HALF_SUB_DIGITS + "e-324", .Float, 1 << 63},
		{"-" + HALF_SUB_DIGITS + "1e-324", .Float, (1 << 63) | 1},
		{"2.2250738585072011e-308", .Float, 0x000F_FFFF_FFFF_FFFF},
		{"2.2250738585072012e-308", .Float, 0x0010_0000_0000_0000},
		{MAX_BELOW, .Float, 0x7FEF_FFFF_FFFF_FFFF},
		{MAX_HALF, .Wide, 0},
		{"-" + MAX_BELOW, .Float, 0xFFEF_FFFF_FFFF_FFFF},
		{"-" + MAX_HALF, .Wide, 0},
		// 19-digit Eisel-Lemire boundaries.
		{"2470328229206232720e-342", .Float, 0},
		{"2470328229206232721e-342", .Float, 1},
		{"1797693134862315807e290", .Float, 0x7FEF_FFFF_FFFF_FFFF},
		{"1797693134862315808e290", .Wide, 0},
		// `MAX_NUMBER_DIGITS` (4096 vs 4097 total digits).
		{strings.concatenate({"1.", strings.repeat("0", 4095, context.temp_allocator)}, context.temp_allocator), .Float, float_bits(1.0)},
		{strings.concatenate({"1.", strings.repeat("0", 4096, context.temp_allocator)}, context.temp_allocator), .Wide, 0},
		{strings.concatenate({"0.", strings.repeat("0", 4096, context.temp_allocator)}, context.temp_allocator), .Float, 0},
		{strings.concatenate({"-0.", strings.repeat("0", 4096, context.temp_allocator)}, context.temp_allocator), .Float, 1 << 63},
		{strings.concatenate({"1.", strings.repeat("0", 4096, context.temp_allocator), "e-500"}, context.temp_allocator), .Float, 0},
	}
	expect_cases(t, cases)
}

// `number_loose` follows JSON5's decimal grammar: allows leading `+` and one-sided decimal points, and rejects
// multi-digit leading zeros (preventing int/float misclassification past 19-20 digits) and digitless spans.
@(test)
loose_leading_zeros_and_json5_edges :: proc(t: ^testing.T) {
	testkit.deadline(t)
	valid := []Case {
		{"0", .Int, 0},
		{"-0", .Int, 0},
		{"+0", .Int, 0},
		{"+123", .Int, 123},
		{"0.", .Float, 0},
		{"-0.", .Float, 1 << 63},
		{"+0.", .Float, 0},
		{".0", .Float, 0},
		{"-.0", .Float, 1 << 63},
		{"+.0", .Float, 0},
		{"5.", .Float, float_bits(5.0)},
		{"5.e2", .Float, float_bits(500.0)},
		{"0e0", .Float, 0},
		{"-0e0", .Float, 1 << 63},
		{"0.000000000000000000001", .Float, float_bits(1e-21)},
	}
	for c in valid {
		src := transmute([]u8)c.text
		num, ok := spell.number_loose(src, 0, u64(len(src)))
		testing.expectf(t, ok && num.kind == c.kind && num.bits == c.bits, "%q: %v %x (ok=%v), want %v %x", c.text, num.kind, num.bits, ok, c.kind, c.bits)
	}
	rejects := []string {
		"00", "01", "-00", "+01", "00.5", "01e5",
		"000000000000000000001", "-00000000000000000001", "-00000000000000000000", "+000000000000000000001",
		"", "+", "-", ".", "+.", "-.", "e1", ".e1",
	}
	for text in rejects {
		src := transmute([]u8)text
		_, ok := spell.number_loose(src, 0, u64(len(src)))
		testing.expectf(t, !ok, "number_loose(%q): expected reject", text)
	}
}

// All span readers reject empty/nil slices and out-of-bounds `(lo, hi)` safely without reading past `len(src)`,
// `number_fraction` rejects `frac_digits == 0` on its fast path, and `float_short` accepts exact `p + 16 == len(src)`.
@(test)
oob_spans_and_slack_boundaries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Empty/nil slice checks.
	empty: []u8 = nil
	for span in ([][2]u64{{0, 0}, {0, 1}, {1, 2}, {0, max(u64)}}) {
		lo, hi := span[0], span[1]
		_, ok_strict := spell.number_strict(empty, lo, hi)
		_, ok_loose := spell.number_loose(empty, lo, hi)
		_, ok_short := spell.number_short(empty, lo, hi)
		_, ok_ishort := spell.integer_short(empty, lo, hi)
		_, ok_fshort := spell.float_short(empty, lo, hi)
		_, ok_nint := spell.number_int(empty, lo, hi, 1)
		_ = spell.number_fraction(empty, lo, hi, 1, 1)
		_ = spell.number_exponent(empty, lo, hi, 1, 1)
		testing.expectf(t, !ok_strict && !ok_loose && !ok_short && !ok_ishort && !ok_fshort && !ok_nint, "empty (%d, %d): expected reject", lo, hi)
	}

	// Sub-slice with valid digits immediately past `len(src)` must never be read.
	backing := transmute([]u8)string("1234567890123456")
	sub := backing[:10]
	for span in ([][2]u64{{0, 12}, {10, 11}, {12, 15}, {5, 5}, {6, 4}, {0, max(u64)}}) {
		lo, hi := span[0], span[1]
		_, ok_strict := spell.number_strict(sub, lo, hi)
		_, ok_loose := spell.number_loose(sub, lo, hi)
		_, ok_short := spell.number_short(sub, lo, hi)
		_, ok_ishort := spell.integer_short(sub, lo, hi)
		_, ok_fshort := spell.float_short(sub, lo, hi)
		_, ok_nint := spell.number_int(sub, lo, hi, 12)
		_ = spell.number_fraction(sub, lo, hi, 5, 5)
		_ = spell.number_exponent(sub, lo, hi, 5, 5)
		testing.expectf(t, !ok_strict && !ok_loose && !ok_short && !ok_ishort && !ok_fshort && !ok_nint, "sub (%d, %d): expected reject", lo, hi)
	}

	// `number_fraction` with `frac_digits == 0` must not take the fast path and fabricate a `.Float`.
	trailing_dot := transmute([]u8)string("000000000000000000000000000000000000000000001234567890123456789.")
	nf := spell.number_fraction(trailing_dot, 44, u64(len(trailing_dot)), 19, 0)
	testing.expectf(t, nf.kind != .Float, "number_fraction trailing dot: got %v %x, expected non-Float fallback", nf.kind, nf.bits)

	// `float_short` accepts exact `p + 16 == len(src)` and rejects `p + 15 == len(src)`.
	exact_pos := transmute([]u8)string("1234567.12345678")
	v_pos, ok_pos := spell.float_short(exact_pos, 0, 16)
	testing.expectf(t, ok_pos && v_pos == 1234567.12345678, "float_short exact 16: %v %v", v_pos, ok_pos)

	exact_neg := transmute([]u8)string("-1234567.12345678")
	v_neg, ok_neg := spell.float_short(exact_neg, 0, 17)
	testing.expectf(t, ok_neg && v_neg == -1234567.12345678, "float_short exact -16: %v %v", v_neg, ok_neg)

	exact_pad := transmute([]u8)string("1.5,,,,,,,,,,,,,")
	v_pad, ok_pad := spell.float_short(exact_pad, 0, 3)
	testing.expectf(t, ok_pad && v_pad == 1.5, "float_short padded 16: %v %v", v_pad, ok_pad)

	short_pad := transmute([]u8)string("1.5,,,,,,,,,,,,")
	_, ok_short_pad := spell.float_short(short_pad, 0, 3)
	testing.expectf(t, !ok_short_pad, "float_short padded 15: expected reject")
}

@(test)
decimal_parts_and_plain_int_dec :: proc(t: ^testing.T) {
	testkit.deadline(t)

	neg, dig := spell.decimal_parts("0")
	testing.expect(t, !neg && dig == "0")
	neg, dig = spell.decimal_parts("-0")
	testing.expect(t, !neg && dig == "0")
	neg, dig = spell.decimal_parts("-000")
	testing.expect(t, !neg && dig == "0")
	neg, dig = spell.decimal_parts("00042")
	testing.expect(t, !neg && dig == "42")
	neg, dig = spell.decimal_parts("-00042")
	testing.expect(t, neg && dig == "42")

	testing.expect(t, spell.is_plain_int_dec("0"))
	testing.expect(t, spell.is_plain_int_dec("-0"))
	testing.expect(t, spell.is_plain_int_dec("123456789012345678901234567890"))
	testing.expect(t, spell.is_plain_int_dec("-999999999999999999999999"))
	testing.expect(t, !spell.is_plain_int_dec(""))
	testing.expect(t, !spell.is_plain_int_dec("-"))
	testing.expect(t, !spell.is_plain_int_dec("+1"))
	testing.expect(t, !spell.is_plain_int_dec("1.0"))
	testing.expect(t, !spell.is_plain_int_dec("1e5"))
	testing.expect(t, !spell.is_plain_int_dec("12a"))
}

@(test)
wide_double_long_and_boundary_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// >4096-digit decimals whose order is finite MUST NOT return +Inf.
	long_one := strings.concatenate({"1.", strings.repeat("0", 4100, context.temp_allocator), "1"}, context.temp_allocator)
	testing.expect_value(t, spell.wide_double(transmute([]u8)long_one), f64(1.0))

	neg_long_one := strings.concatenate({"-", long_one}, context.temp_allocator)
	testing.expect_value(t, spell.wide_double(transmute([]u8)neg_long_one), f64(-1.0))

	long_scaled := strings.concatenate({"0.", strings.repeat("0", 4100, context.temp_allocator), "1e4101"}, context.temp_allocator)
	testing.expect_value(t, spell.wide_double(transmute([]u8)long_scaled), f64(1.0))

	// Overflow with negative exponent MUST return ±Inf, not 0.0.
	over_neg_exp := strings.concatenate({"1", strings.repeat("0", 400, context.temp_allocator), "e-1"}, context.temp_allocator)
	f_over := spell.wide_double(transmute([]u8)over_neg_exp)
	testing.expect(t, math.is_inf(f_over, 1))

	neg_over_neg_exp := strings.concatenate({"-", over_neg_exp}, context.temp_allocator)
	f_nover := spell.wide_double(transmute([]u8)neg_over_neg_exp)
	testing.expect(t, math.is_inf(f_nover, -1))

	// Underflow preserves sign bit.
	under := strings.concatenate({"-0.", strings.repeat("0", 4100, context.temp_allocator), "1"}, context.temp_allocator)
	f_under := spell.wide_double(transmute([]u8)under)
	testing.expect_value(t, transmute(u64)f_under, u64(1) << 63)

	// Near binary64 max & min subnormal boundaries.
	testing.expect_value(t, transmute(u64)spell.wide_double(transmute([]u8)string("1.7976931348623157e308")), u64(0x7FEF_FFFF_FFFF_FFFF))
	testing.expect(t, math.is_inf(spell.wide_double(transmute([]u8)string("1.7976931348623159e308")), 1))
	testing.expect(t, math.is_inf(spell.wide_double(transmute([]u8)string("-1.7976931348623159e308")), -1))
	testing.expect_value(t, transmute(u64)spell.wide_double(transmute([]u8)string("4.9e-324")), u64(1))
	testing.expect_value(t, transmute(u64)spell.wide_double(transmute([]u8)string("-2.4e-324")), u64(1) << 63)
}

@(test)
zmij_and_integer_formatting :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [64]u8

	// Integer formatting across 1..20 digits and signed extremes.
	u_cases := []struct {v: u64, want: string}{
		{0, "0"}, {7, "7"}, {99_999_999, "99999999"}, {100_000_000, "100000000"},
		{9_999_999_999_999_999, "9999999999999999"}, {10_000_000_000_000_000, "10000000000000000"},
		{max(u64), "18446744073709551615"},
	}
	for c in u_cases {
		n := spell.put_u64(&buf[0], c.v)
		testing.expect_value(t, string(buf[:n]), c.want)
	}
	i_cases := []struct {v: i64, want: string}{
		{min(i64), "-9223372036854775808"}, {-1, "-1"}, {0, "0"}, {max(i64), "9223372036854775807"},
	}
	for c in i_cases {
		n := spell.put_i64(&buf[0], c.v)
		testing.expect_value(t, string(buf[:n]), c.want)
	}

	// `put_f64` and `put_f32` round-trip and layout checks.
	f64_cases := []struct {v: f64, want: string}{
		{0.0, "0.0"}, {transmute(f64)(u64(1) << 63), "-0.0"}, {1.5, "1.5"}, {-1.0, "-1.0"},
		{1e-4, "0.0001"}, {9.999999999999999e-5, "9.999999999999999e-05"}, {999999.0, "999999.0"}, {1e6, "1e+06"},
		{transmute(f64)u64(1), "5e-324"}, {transmute(f64)u64(0x7FEF_FFFF_FFFF_FFFF), "1.7976931348623157e+308"},
	}
	for c in f64_cases {
		n, ok := spell.put_f64(&buf[0], c.v)
		testing.expectf(t, ok && string(buf[:n]) == c.want, "put_f64(%v): got %q, want %q", c.v, string(buf[:n]), c.want)
	}
	_, nan_ok := spell.put_f64(&buf[0], math.nan_f64())
	_, inf_ok := spell.put_f64(&buf[0], math.inf_f64(1))
	testing.expect(t, !nan_ok && !inf_ok)

	f32_cases := []struct {v: f32, want: string}{
		{0.0, "0.0"}, {transmute(f32)(u32(1) << 31), "-0.0"}, {1.5, "1.5"}, {1e-4, "0.0001"}, {1e6, "1e+06"},
		{transmute(f32)u32(1), "1e-45"}, {transmute(f32)u32(0x7F7F_FFFF), "3.4028235e+38"},
	}
	for c in f32_cases {
		n, ok := spell.put_f32(&buf[0], c.v)
		testing.expectf(t, ok && string(buf[:n]) == c.want, "put_f32(%v): got %q, want %q", c.v, string(buf[:n]), c.want)
	}

	// `float64_text` jq layout agreement (plain up to 1e15, `.0` on whole, empty on non-finite).
	jq_cases := []struct {v: f64, want: string}{
		{0.0, "0.0"}, {transmute(f64)(u64(1) << 63), "-0.0"}, {1e6, "1000000.0"}, {1e15, "1000000000000000.0"},
		{1e16, "1e+16"}, {1e-4, "0.0001"}, {1e-5, "1e-05"}, {math.nan_f64(), ""}, {math.inf_f64(-1), ""},
	}
	for c in jq_cases {
		s, ok := spell.float64_text(c.v, buf[:32])
		testing.expectf(t, ok && s == c.want, "float64_text(%v): got %q, want %q", c.v, s, c.want)
	}
}
