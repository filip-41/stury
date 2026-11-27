package spell_tests

import "core:math"
import "core:strings"
import "core:testing"
import "stury:lib/base/spell"
import "stury:testkit"

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
