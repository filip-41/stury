package spell_tests

import "core:strconv"
import "core:testing"
import spell ".."

// A leading zero in a multi-digit integer run is a digit, not the zero of a `0.<fraction>` significand.
@(test)
number_loose_leading_zero :: proc(t: ^testing.T) {
	for src in ([]string{"012345678901234567890123456789", "0012345678901234567890123456789"}) {
		got, _, _, _ := spell.number_loose(transmute([]u8)src, 0, u64(len(src)))
		want, ok := strconv.parse_f64(src)
		testing.expectf(t, ok && got.kind == .Float && got.bits == transmute(u64)want, "%q: %v, want %x", src, got, transmute(u64)want)
	}
}

// JSON5's `5.` has a point and no fraction digits, read from far enough into the text that the digits are loaded as
// words.
@(test)
number_fraction_without_digits :: proc(t: ^testing.T) {
	src := "123456789012345678901234567890 5."
	lo := u64(len(src) - 2)
	got := spell.number_fraction(transmute([]u8)src, lo, u64(len(src)), 1, 0)
	testing.expectf(t, got.kind == .Float && got.bits == transmute(u64)f64(5), "%v", got)
}
