package regex_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import regex "stury:lib/base/regex"
import "stury:testkit"

@(test)
test_ecma_rules :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		pattern, text: string,
		lo, hi:        int, // -1 for no match
		g1, g1_end:    int,
	}
	letters := strings.repeat("a", 20_000, context.temp_allocator)
	cases := [?]Case {
		{`b+`, "abbbc", 1, 4, -1, -1}, // a pattern is searched, not anchored
		{`^b`, "ab", -1, -1, -1, -1},
		{`a$`, "a\n", -1, -1, -1, -1}, // $ is the end of the text only
		{`a.c`, "a\rc", -1, -1, -1, -1}, // . excludes the line terminators
		{`a.c`, "a€c", 0, 5, -1, -1}, // . is a code point
		{`\d`, "٣", -1, -1, -1, -1}, // \d and \w are ASCII
		{`\w`, "é", -1, -1, -1, -1},
		{`\bb`, "ébc", 2, 3, -1, -1}, // \b is an ASCII boundary
		{`\s\s\s`, "\u00a0\ufeff\u2028", 0, 8, -1, -1}, // \s holds white space and line terminators
		{`\s`, "\u0085", -1, -1, -1, -1},
		{`\u{1F600}`, "x😀", 1, 5, -1, -1}, // \u{} and surrogate pairs name one code point
		{`😀`, "x😀", 1, 5, -1, -1},
		{`\ud83d`, "\ufffd", -1, -1, -1, -1}, // a lone surrogate, which no text holds
		{`[\ud800-\udfff]`, "\ufffd", -1, -1, -1, -1},
		{`\x41\cJ\0`, "A\n\x00", 0, 3, -1, -1},
		{`[\D\W]`, "5", -1, -1, -1, -1}, // a negated set inside a class
		{`[^]`, "\n", 0, 1, -1, -1},
		{`[]`, "a", -1, -1, -1, -1},
		{`\p{Lu}+`, "abCDe", 2, 4, -1, -1},
		{`\p{Script=Greek}\p{gc=L}`, "aβa", 1, 4, -1, -1},
		{`\P{L}`, "a1", 1, 2, -1, -1},
		{`a(?!b)`, "abac", 2, 3, -1, -1}, // look-ahead
		{`(?=(a|aa)*b)c`, "aaaaac", -1, -1, -1, -1},
		{`^a{2,3}?`, "aaaa", 0, 2, -1, -1},
		{`(?:a|ab)(?:c|bcd)`, "abcd", 0, 4, -1, -1}, // leftmost, first alternative first
		{`(a*)*b`, "aaac", -1, -1, -1, -1},
		{`^(?:(?=a)|a){2}$`, "a", 0, 1, -1, -1}, // a required iteration may match empty
		{`(?:|a)+`, "aa", 0, 2, -1, -1}, // an iteration past the least count may not
		{`(?:(a)|b)+`, "ab", 0, 2, -1, -1}, // an iteration unsets its groups
		{`(a?)?`, "b", 0, 0, -1, -1}, // an optional iteration may not match empty either
		{`^[a-z]{0,65535}$`, letters, 0, 20_000, -1, -1}, // a repeat of one character is compiled without copies
		{`(?=(a+))a\d`, "aaa1", 2, 4, 2, 3}, // a group in a look-ahead keeps its span past the visited set's shortcut
		{`(?=(a|aa)*(b))a.*c`, "aabc", 0, 4, 1, 2},
		{`(?<\u0061b>x)`, "x", 0, 1, 0, 1}, // a group name may be written with escapes
		{`\.\/[\/\-\.]`, "x./-", 1, 4, -1, -1}, // a syntax character and `/` are themselves, and `-` in a class
		{`^\/[^\*\?]*$`, "/a?", -1, -1, -1, -1},
		{`\p{Bidi_M}`, "(", 0, 1, -1, -1},
		{`\p{Bidi_M}`, "a", -1, -1, -1, -1},
		{`\p{Bidi_Mirrored}`, "\u2208", 0, 3, -1, -1},
		{`\p{CWKCF}`, "A", 0, 1, -1, -1},
		{`\p{CWKCF}`, "a", -1, -1, -1, -1},
		{`\p{CWKCF}`, "\u00a0", 0, 2, -1, -1},
		{`\p{scx=Common}`, "\u3001", -1, -1, -1, -1},
		{`\p{sc=Common}`, "\u3001", 0, 3, -1, -1},
		{`\p{scx=Hira}`, "\u3001", 0, 3, -1, -1},
		{`\p{Script_Extensions=Latin}`, "\u0363", 0, 2, -1, -1},
		{`^\p{sc=Beria_Erfe}+$`, "\U00016ea0\U00016ed3", 0, 8, -1, -1},
		{`\p{sc=Beria_Erfe}`, "\U00016e9f\U00016ed4", -1, -1, -1, -1},
		{`^\p{sc=Sidetic}+$`, "\U00010940\U00010959", 0, 8, -1, -1},
		{`\p{sc=Sidetic}`, "\U0001093f\U0001095a", -1, -1, -1, -1},
		{`^\p{sc=Tai_Yo}+$`, "\U0001e6c0\U0001e6ff", 0, 8, -1, -1},
		{`\p{sc=Tai_Yo}`, "\U0001e6bf\U0001e700", -1, -1, -1, -1},
		{`^\p{sc=Tolong_Siki}+$`, "\U00011db0\U00011de9", 0, 8, -1, -1},
		{`\p{sc=Tolong_Siki}`, "\U00011daf\U00011dea", -1, -1, -1, -1},
		{`\p{L}`, "\u0c5c", 0, 3, -1, -1}, // the property tables are Unicode 17's
		{`\p{sc=Han}`, "\U000323b0", 0, 4, -1, -1},
		{`\p{Ll}`, "\u0295", -1, -1, -1, -1},
		{`\p{Lo}`, "\u0295", 0, 2, -1, -1},
		{`\p{Extended_Pictographic}`, "\u2388", -1, -1, -1, -1},
		{`\p{Extended_Pictographic}`, "\U0001f600", 0, 4, -1, -1},
		{`(?<\u0c5c>x)`, "x", 0, 1, 0, 1},
	}
	for c in cases {
		f := search(c.pattern, c.text)
		testing.expectf(
			t,
			f.lo == c.lo && f.hi == c.hi && f.g1 == c.g1 && f.g1_end == c.g1_end,
			"%q on %.20q: got %d..%d (%d..%d) %s, want %d..%d (%d..%d)",
			c.pattern,
			c.text,
			f.lo,
			f.hi,
			f.g1,
			f.g1_end,
			f.err,
			c.lo,
			c.hi,
			c.g1,
			c.g1_end,
		)
	}
}

@(test)
test_ecma_look_behind_and_back_references :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		pattern, text: string,
		lo, hi:        int, // -1 for no match
		g1, g1_end:    int,
	}
	cases := [?]Case {
		{`(?<=\$)\d+`, "cost $10", 6, 8, -1, -1},
		{`(?<!a)b`, "abcb", 3, 4, -1, -1},
		{`(?<=a+)b`, "caaab", 4, 5, -1, -1}, // of any length
		{`(?<=(a+))b`, "aaab", 3, 4, 0, 3}, // matched leftwards, so a greedy repeat takes all it can to the left
		{`(?<=(a+?))b`, "aaab", 3, 4, 2, 3},
		{`(?<=(\d+)\d+)$`, "1053", 4, 4, 0, 1},
		{`(?<=(ab|b))c`, "abc", 2, 3, 0, 2},
		{`(?<=(b|ab))c`, "abc", 2, 3, 1, 2},
		{`(?<=\ud83d\ude00)a`, "\U0001f600a", 4, 5, -1, -1},
		{`(?<=.{2})a`, "\U0001f600\u00e9a", 6, 7, -1, -1},
		{`(?<=.{3})a`, "\U0001f600\u00e9a", -1, -1, -1, -1},
		{`(?<=(?<=a)b)c`, "bbcabc", 5, 6, -1, -1}, // nested
		{`(?<=a(?!b))..`, "acab", 1, 3, -1, -1}, // a look-ahead inside reads rightwards
		{`(?<=$)`, "a", 1, 1, -1, -1},
		{`(a)\1`, "abaa", 2, 4, 2, 3},
		{`(\ud83d\ude00)\1`, "\U0001f600\U0001f600", 0, 8, 0, 4},
		{`\1(a)`, "a", 0, 1, 0, 1}, // a group that has not matched matches empty
		{`(a\1)`, "a", 0, 1, 0, 1},
		{`(?:(a)|b)\1`, "b", 0, 1, -1, -1},
		{`(?:(a)|(b))+\1\2`, "abb", 0, 3, -1, -1}, // an iteration unsets the groups a reference reads
		{`(?<a>x)\k<a>`, "xx", 0, 2, 0, 1},
		{`\k<a>(?<a>x)`, "x", 0, 1, 0, 1},
		{`(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)\10`, "abcdefghijj", 0, 11, 0, 1},
		// a reference in a look-behind reads leftwards, after the group to its right
		{`(?<=\1(a))b`, "aab", 2, 3, 1, 2},
		{`(?<=\1(a))b`, "cab", -1, -1, -1, -1},
		{`(?<=(a)\1)b`, "ab", 1, 2, 0, 1},
		{`(.)(?<=\1\1)`, "abb", 2, 3, 2, 3},
		{`(?=(a+))a*b\1`, "baaabac", 3, 6, 3, 4},
	}
	for c in cases {
		for linear in ([2]bool{true, false}) {
			f := search(c.pattern, c.text, linear)
			testing.expectf(
				t,
				f.lo == c.lo && f.hi == c.hi && f.g1 == c.g1 && f.g1_end == c.g1_end,
				"%q on %.20q (linear %v): got %d..%d (%d..%d) %s, want %d..%d (%d..%d)",
				c.pattern,
				c.text,
				linear,
				f.lo,
				f.hi,
				f.g1,
				f.g1_end,
				f.err,
				c.lo,
				c.hi,
				c.g1,
				c.g1_end,
			)
		}
	}
	// A back reference keeps the search off the visited set, so an exponential search stops at the retry limit.
	testing.expect_value(
		t,
		search(
			`^(a|a)*\1$`,
			strings.concatenate({strings.repeat("a", 40, context.temp_allocator), "b"}, context.temp_allocator),
		).err,
		"retry-limit-in-match over",
	)
}

@(test)
test_ecma_group_names :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		pattern, name: string, // the name of group 1, "" for a pattern that is refused
	}
	cases := [?]Case {
		{`(?<a>x)`, "a"},
		{`(?<\u0061b>x)`, "ab"},
		{`(?<a\u{62}>x)`, "ab"},
		{`(?<\ud835\udc4ex>x)`, "\U0001d44ex"}, // a surrogate pair
		{`(?<\u{1d44e}>x)`, "\U0001d44e"},
		{`(?<\u0031>x)`, ""}, // a digit starts no name
		{`(?<a\u0020>x)`, ""},
		{`(?<\ud835>x)`, ""}, // a lone surrogate
		{`(?<a\x62>x)`, ""}, // only \u is a name escape
		{`(?<\u00>x)`, ""},
		{`(?<a\u0062>x)(?<ab>y)`, ""}, // the same name twice
	}
	for c in cases {
		arena: virtual.Arena
		re, err := compile(c.pattern, {ecma = true}, growing(&arena), context.allocator)
		if c.name == "" {
			testing.expectf(t, err != "", "%q compiled", c.pattern)
		} else {
			testing.expectf(
				t,
				err == "" && len(re.names) == 2 && re.names[1] == c.name,
				"%q: %q, names %q",
				c.pattern,
				err,
				re.names,
			)
		}
	}
}

@(test)
test_jq_matches_where_oniguruma_does :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		pattern, text: string,
		flags:         Mode,
		lo, hi:        int,
	}
	cases := [?]Case {
		{`$`, "\n", {}, 0, 0}, // a newline that is the whole text ends a line at 0
		{`\Z`, "\n", {}, 0, 0},
		{`(?:)\Z`, "\n", {}, 0, 0},
		{`$`, "\n\n", {}, 1, 1},
		{`ss$`, "s\u017f", {fold = true}, 0, 3},
		{`ss$`, "\u017f\u017f", {fold = true}, 0, 4},
		{`ss\z`, "Ss\u017f", {fold = true}, 1, 4},
		{"\u00df$", "x\u017fs", {fold = true}, 1, 4},
		// jq 1.8.2 holds Oniguruma's Unicode 16.0, stury Unicode 17.0 under the same names.
		{`\p{L}`, "\u0c5c", {}, 0, 3},
		{`\w`, "\u0c5c", {}, 0, 3},
		{`\p{Lo}`, "\u0295", {}, 0, 2},
		{`\p{Ll}`, "\u0295", {}, -1, -1},
		{`\p{Extended_Pictographic}`, "\u2388", {}, -1, -1},
		{`\p{Unknown}`, "\U00010940", {}, -1, -1}, // Sidetic, a script with no name in Oniguruma 6.9.10
		{`\x{a7d2}`, "\ua7d3", {fold = true}, 0, 3},
	}
	for c in cases {
		f := search(c.pattern, c.text, flags = c.flags)
		testing.expectf(
			t,
			f.lo == c.lo && f.hi == c.hi,
			"%q on %q: %d..%d %s, want %d..%d",
			c.pattern,
			c.text,
			f.lo,
			f.hi,
			f.err,
			c.lo,
			c.hi,
		)
	}
	for pattern in ([?]string{`(?)`, `(?<=(?<=ab?)|)`, `(?<!(?<=ab?)|)`}) {
		testing.expectf(t, search(pattern, "", flags = {}).err != "", "%q compiled", pattern)
	}
	testing.expect(t, search(`(?<=(?<=a+)|)`, "", flags = {}).err == "")
}

@(test)
test_sample_ends_an_empty_repeat :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	allocator := growing(&arena)
	state := u64(1)
	for pattern in ([?]string{`(?:){2000000000}`, `(?:){9007199254740991}`, `(?:(?:){100000}){100000}`}) {
		text, ok := sample(pattern, &state, 3, 0, allocator)
		testing.expectf(t, ok && text == "", "%q: %v %q", pattern, ok, text)
	}
}

@(test)
test_regex_jq_group_names :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Group names as jq's Oniguruma reads them: a name starts with a word character, and a backslash in it is a
	// backslash.
	Case :: struct {
		pattern, want: string,
	}
	cases := [?]Case {
		{`(?<a\u0061>x)`, ""},
		{`(?<_a-b>x)`, ""},
		{`(?<é>x)`, ""},
		{`(?<\u0061>x)`, "invalid char in group name <\\u0061>"},
		{`(?<$a>x)`, "invalid char in group name <$a>"},
		{`(?<-a>x)`, "invalid group name <-a>"},
		{`(?<1a>x)`, "invalid group name <1a>"},
	}
	for c in cases {
		_, err := compile(c.pattern, {}, context.temp_allocator, context.temp_allocator)
		testing.expectf(t, err == c.want, "%q: %q, want %q", c.pattern, err, c.want)
	}
}

@(test)
test_ecma_refusals :: proc(t: ^testing.T) {
	testkit.deadline(t)
	refused := [?]string {
		`\k<x>`, `(a)\2`, `(?<x>a)\k<x`, `(?<=a)*`, `(?<!a)+b`, `(?<=a){2}`, `a{`, `a{2,1}`, `]`, `}`, `\q`, `[b-a]`,
		`[\d-z]`,
		`\u{110000}`, `\p{Nope}`, `\p{scx=Nope}`, `\p{scx}`, `\p{letter}`, `\p{Greek}`, `\p{Word}`, `\p{gc=Greek}`,
		`(?<1>a)`,
		`(?<n>a)(?<n>b)`, `(?=a)*`, `^*`, `a**`, `(a`, `a)`, `(?x)`, `\c1`, `\00`, `\-?`, `a+?\-`,
		`\&`, `\%`, `[\&]`, `[\%]`, `\#`, `\ `, `\!`, `\"`, `\,`, `\:`, `\;`, `\<`, `\=`, `\>`, `\@`, `\~`, `\_`, `\'`,
		`[\_]`,
		`\p{=L}`, `\p{gc=}`,
	}
	for pattern in refused {
		testing.expectf(t, search(pattern, "").err != "", "%q compiled", pattern)
	}
	testing.expect(t, search(`a`, "", flags = {ecma = true, fold = true}).err != "")
	testing.expect_value(t, search(`a\&b`, "").err, "invalid escape \\& at offset 1")
	testing.expect_value(t, search(`[a\%]`, "").err, "invalid escape \\% at offset 2")
	testing.expect(t, search(`\&\%[\&\%]`, "", flags = {}).err == "") // jq's Oniguruma accepts these escapes
}

@(test)
test_ecma_valid_back_references :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// A back reference is valid when it names a group the pattern has, before or after it, and a name is an identifier.
	refused := [?]string{
		`\1`,
		`\5`,
		`(a)\2`,
		`(a)\10`,
		`\8`,
		`\k<a>`,
		`(?<a>x)\k<b>`,
		`\k<1>`,
		`\k<a>x`,
		`\k`,
		`\k<>`,
		`\ka`,
	}
	for pattern in refused {
		testing.expectf(t, compile_message(pattern, {ecma = true}) != "", "%q is valid", pattern)
	}
	accepted := [?]string{`(a)\1`, `\1(a)`, `\k<a>(?<a>x)`, `(?<a>x)\k<a>`, `(?<a>x)\k<\u0061>`, `(?<=a)b`, `(?<!a)b`}
	for pattern in accepted {
		testing.expectf(t, compile_message(pattern, {ecma = true}) == "", "%q does not compile", pattern)
		testing.expect_value(
			t,
			regex.refusal(pattern, .Ecma, {}, context.temp_allocator, context.temp_allocator),
			regex.Error{},
		)
	}
}

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
