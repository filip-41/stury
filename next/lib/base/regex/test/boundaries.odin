package regex_tests

import "core:testing"
import "stury:testkit"

// Oniguruma's message for each number or character value near the edges of an int, as it gives them for the same
// patterns.
@(test)
test_numbers_at_the_edges :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		pattern: string,
		ecma:    bool,
		message: string,
	}
	cases := [?]Case {
		{`(a)\g<18446744073709551617>`, false, "too big number"},
		{`(a)\g<18446744073709551616>`, false, "too big number"},
		{`(a)\g<+18446744073709551617>`, false, "too big number"},
		{`(a)\g<-18446744073709551617>`, false, "too big number"},
		{`\g<2147483646>(a)`, false, "undefined group <2147483646> reference"},
		{`\g<2147483647>(a)`, false, "undefined group <2147483647> reference"},
		{`\g<2147483648>(a)`, false, "too big number"},
		{`\g<+2147483647>(a)`, false, "undefined group <+2147483647> reference"},
		{`\g<-2147483647>(a)`, false, "undefined group <-2147483647> reference"},
		{`\g<-2147483648>(a)`, false, "too big number"},
		{`(a)\g<4294967296>`, false, "too big number"},
		{`(a)\k<2147483647>`, false, "invalid backref number/name"},
		{`(a)\k<2147483648>`, false, "invalid backref number/name"},
		{`(a)\k<18446744073709551617>`, false, "invalid backref number/name"},
		{`(a)\g<0>`, false, "never ending recursion"},
		{`(a)\1000`, false, ""},
		{`(a)\k<2147483648>`, true, "invalid named reference"},
		{`\x{7FFFFFFF}`, false, ""},
		{`\x{110000}`, false, ""},
		{`\x{80000000}`, false, "too big wide-char value"},
		{`\x{FFFFFFFF}`, false, "too big wide-char value"},
		{`[\x{7FFFFFFF}-\x{80000000}]`, false, "too big wide-char value"},
		{`\x{123456789}`, false, "too long wide-char value"},
	}
	for c in cases {
		message := compile_message(c.pattern, {ecma = c.ecma})
		testing.expectf(t, message == c.message, "%q: %q, want %q", c.pattern, message, c.message)
	}
}

// Parser, look-behind, escape, property, and backref parity/overflow regression cases.
@(test)
test_review_regression_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Look-behind overflow & empty \Q\E.
	testing.expect(t, compile_message(`(?<=((((a{65536}){65536}){65536}){65536}))`, {}) != "")
	testing.expect(t, compile_message(`(?<=((a{50000}){50000}))`, {}) != "")
	testing.expect_value(t, compile_message(`(?<=\Q\E)`, {}), "")
	testing.expect(t, search(`(?<=\Q\E)`, "", true, {}).lo == 0)
	// Backref \k<-0>, named group ')', Kelvin-sign property, [[:]], \xff / \xf5, ab(?#comment)*, (?i) p.head.
	testing.expect_value(t, compile_message(`(a)\k<-0>(b)`, {}), "invalid group name <-0>")
	testing.expect_value(t, compile_message(`(?<a)b>x)`, {}), "invalid group name <a>")
	testing.expect(t, compile_message(`\p{KataKana}`, {}) != "")
	testing.expect_value(t, compile_message(`[[:]]`, {}), "")
	testing.expect(t, search(`\xff`, "\u00ff", true, {}).lo < 0)
	testing.expect(t, search(`\xc0\x80`, "\ufffd", true, {}).lo < 0)
	testing.expect_value(t, compile_message(`\xf5\x80\x80\x80`, {}), "invalid code point value")
	testing.expect_value(t, compile_message(`\o{7777777777777}`, {}), "too big number")
	testing.expect(t, search(`ab(?#comment)*`, "a", true, {}).lo == 0)
	testing.expect(t, search(`(a)(?(1)(?i)(?:x|y))`, "ay", true, {}).lo == 0)
	// ECMA max(i32) repeat must not overflow or falsely match empty.
	testing.expect(t, search(`a{2147483647,}`, "aaa", true, {ecma = true}).lo < 0)
}
