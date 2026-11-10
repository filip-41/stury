package spell_tests

import "core:testing"
import spell ".."

Decimal_Case :: struct {
	x, y:     string,
	order:    int,
	multiple: bool,
	exact:    bool,
}

@(test)
decimals_compare_and_divide_exactly :: proc(t: ^testing.T) {
	cases := [?]Decimal_Case {
		{"1.0", "1", 0, true, true},
		{"10e-1", "1", 0, true, true},
		{"-0", "0", 0, true, true},
		{"-1e-400", "0", -1, false, true},
		{"1e400", "1e-400", 1, true, true},
		{"1e-400", "1e400", -1, false, true},
		{"1e99999999999999999999", "1e99999999999999999998", 1, true, true}, // a 20-digit exponent is exact
		{"1e2147483648", "1e2147483649", -1, false, true},
		{"2e2147483648", "1e2147483649", -1, false, true},
		{"0.3", "0.1", 1, true, true},
		{"0.35", "0.1", 1, false, true},
		{"7", "0", 1, false, true},
		{"12345678901234567890123", "100000000000000000007", 1, false, true},
		{"300000000000000000021", "100000000000000000007", 1, true, true},
		{"3e30", "100000000000000000007", 1, false, true},
		{"1e500", "100000000000000000007", 1, false, false},
	}
	for c in cases {
		x, y := spell.decimal_of(c.x), spell.decimal_of(c.y)
		multiple, exact := spell.decimal_multiple_of(x, y)
		order, _ := spell.decimal_compare(x, y)
		testing.expectf(t, order == c.order, "%s <=> %s", c.x, c.y)
		testing.expectf(t, multiple == c.multiple && exact == c.exact, "%s multiple of %s: %v %v", c.x, c.y, multiple, exact)
	}
}

@(test)
decimals_past_an_exponent_of_thirty_digits_are_not_exact :: proc(t: ^testing.T) {
	x, y := spell.decimal_of("1e999999999999999999999999999999999999"), spell.decimal_of("1e999999999999999999999999999999999998")
	_, ordered := spell.decimal_compare(x, y)
	_, divided := spell.decimal_multiple_of(x, y)
	testing.expect(t, !ordered && !divided)
}
