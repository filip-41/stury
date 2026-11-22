package value_test

import "core:math/big"
import "core:testing"
import "stury:lib/base/spell"
import "stury:lib/core/value"
import "stury:lib/core/value/bigint"
import "stury:testkit"

// `bigint.integer_of` at and past the `i64` limits, and the spellings that are no integer.
@(test)
integer_of_reads_every_kind :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		number:  spell.Number,
		text:    string,
		decimal: string, // "" for a refusal
	}
	cases := [?]Case {
		{{bits = 0, kind = .Int}, "0", "0"},
		{{bits = u64(max(u64)), kind = .Int}, "-1", "-1"},
		{{bits = u64(1) << 63, kind = .Int}, "-9223372036854775808", "-9223372036854775808"},
		{{bits = max(u64), kind = .Uint}, "18446744073709551615", "18446744073709551615"},
		{{kind = .Wide}, "18446744073709551616", "18446744073709551616"},
		{{kind = .Wide}, "-123456789012345678901234567890", "-123456789012345678901234567890"},
		{{kind = .Float}, "1.5", ""},
		{{kind = .Wide}, "1e400", ""},
		{{kind = .Wide}, "-", ""},
	}
	for c in cases {
		n: big.Int
		defer big.destroy(&n)
		err := bigint.integer_of(value.number_of(c.number, c.text), &n)
		if c.decimal == "" {
			testing.expectf(t, err == .Invalid_Argument, "%s gave %v", c.text, err)
			continue
		}
		testing.expect_value(t, err, nil)
		s, serr := big.itoa(&n, allocator = context.temp_allocator)
		testing.expect_value(t, serr, nil)
		testing.expectf(t, s == c.decimal, "%s read as %s", c.text, s)
	}
}

// A number keeps its value and the span it borrows.
@(test)
number_keeps_value_and_span :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "[12.50]"
	n := value.number_of({bits = transmute(u64)f64(12.5), kind = .Float}, src[1:6])
	v: value.Value = n
	got, ok := v.(value.Number)
	testing.expect(t, ok)
	testing.expect_value(t, value.number_text(got), "12.50")
	testing.expect(t, raw_data(value.number_text(got)) == raw_data(src[1:]))
	testing.expect_value(t, value.number_value(got), spell.Number{bits = transmute(u64)f64(12.5), kind = .Float})
}

// The size a value takes in arrays and objects, which changes only on purpose.
@(test)
value_size :: proc(t: ^testing.T) {
	testkit.deadline(t)
	when size_of(uintptr) == 8 {
		testing.expect_value(t, size_of(value.Number), 24)
		testing.expect_value(t, size_of(value.Value), 32)
	}
}
