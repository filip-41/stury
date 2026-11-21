package tape_test

import "core:math/big"
import "core:testing"
import "stury:lib/core/tape"

// `integer_value` at and just past the `i64` limits.
@(test)
integer_value_narrows :: proc(t: ^testing.T) {
	Case :: struct {
		decimal: string,
		fits:    bool,
		small:   i64,
	}
	cases := [?]Case {
		{"0", true, 0},
		{"-1", true, -1},
		{"9223372036854775807", true, max(i64)},
		{"-9223372036854775808", true, min(i64)},
		{"9223372036854775808", false, 0},
		{"-9223372036854775809", false, 0},
		{"18446744073709551616", false, 0},
		{"-18446744073709551616", false, 0},
	}
	for c in cases {
		n: big.Int
		defer big.destroy(&n)
		testing.expect_value(t, big.atoi(&n, c.decimal), nil)
		v, err := tape.integer_value(&n)
		testing.expect_value(t, err, nil)
		switch x in v {
		case i64:
			testing.expectf(t, c.fits && x == c.small, "%s gave i64 %d", c.decimal, x)
		case ^big.Int:
			testing.expectf(t, !c.fits && x == &n, "%s stayed big", c.decimal)
		case bool, f64, tape.Number_View, string, tape.Bytes, ^tape.Array, ^tape.Object, tape.Node_Ref:
			testing.expectf(t, false, "%s gave %v", c.decimal, v)
		}
	}
}
