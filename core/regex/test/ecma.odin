package regex_tests

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import regex ".."

// Returns an allocator over a growing arena kept in `arena`. The arena is destroyed when the caller's scope ends.
@(deferred_in = virtual.arena_destroy)
growing :: proc(arena: ^virtual.Arena, loc := #caller_location) -> mem.Allocator {
	ensure(virtual.arena_init_growing(arena) == nil)
	return virtual.arena_allocator(arena)
}

// The result of `search`: the span of the first match and of group 1 (-1 for none), the error message, and the
// alternatives the search resumed.
Found :: struct {
	lo, hi, g1, g1_end: int,
	err:                string,
	resumes:            int,
	automaton:          bool, // the pattern has the automaton that answers a search reading no bounds
	ends:               int, // where the automaton that finds match ends found the match to end, -1 for none
}

// Searches `text` for `pattern`. With `flags.ecma` the pattern is ECMA's, otherwise jq's. With `linear` false the
// automata and the visited set are off. With `whether` the search reads no bounds, and the span is 0..0 for a match.
search :: proc(pattern, text: string, linear := true, flags := regex.Flags{ecma = true}, whether := false) -> (f: Found) {
	f = {-1, -1, -1, -1, "", 0, false, -1}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		f.err = "no memory"
		return
	}
	defer virtual.arena_destroy(&arena)
	re, err := regex.compile(pattern, flags, virtual.arena_allocator(&arena), automaton = linear, spans = linear)
	if err != "" {
		f.err = strings.clone(err, context.temp_allocator)
		return
	}
	re.linear &&= linear
	f.automaton = re.dfa != nil
	scratch: regex.Scratch
	defer regex.scratch_destroy(&scratch)
	caps: [4]int
	found: bool
	found, err = regex.search(&re, text, 0, caps[:0 if whether else min(4, 2 * len(re.names))], &scratch)
	f.err, f.resumes, f.ends = strings.clone(err, context.temp_allocator), scratch.resumes, scratch.ends
	if found {
		f.lo, f.hi = caps[0], caps[1]
		if len(re.names) > 1 && !whether {
			f.g1, f.g1_end = caps[2], caps[3]
		}
	}
	return
}

@(test)
test_ecma_rules :: proc(t: ^testing.T) {
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
		testing.expectf(t, f.lo == c.lo && f.hi == c.hi && f.g1 == c.g1 && f.g1_end == c.g1_end, "%q on %.20q: got %d..%d (%d..%d) %s, want %d..%d (%d..%d)", c.pattern, c.text, f.lo, f.hi, f.g1, f.g1_end, f.err, c.lo, c.hi, c.g1, c.g1_end)
	}
}

@(test)
test_ecma_look_behind_and_back_references :: proc(t: ^testing.T) {
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
		{`(?<=\1(a))b`, "aab", 2, 3, 1, 2}, // a reference in a look-behind reads leftwards, after the group to its right
		{`(?<=\1(a))b`, "cab", -1, -1, -1, -1},
		{`(?<=(a)\1)b`, "ab", 1, 2, 0, 1},
		{`(.)(?<=\1\1)`, "abb", 2, 3, 2, 3},
		{`(?=(a+))a*b\1`, "baaabac", 3, 6, 3, 4},
	}
	for c in cases {
		for linear in ([2]bool{true, false}) {
			f := search(c.pattern, c.text, linear)
			testing.expectf(t, f.lo == c.lo && f.hi == c.hi && f.g1 == c.g1 && f.g1_end == c.g1_end, "%q on %.20q (linear %v): got %d..%d (%d..%d) %s, want %d..%d (%d..%d)", c.pattern, c.text, linear, f.lo, f.hi, f.g1, f.g1_end, f.err, c.lo, c.hi, c.g1, c.g1_end)
		}
	}
	// A back reference keeps the search off the visited set, so an exponential search stops at the retry limit.
	testing.expect_value(t, search(`^(a|a)*\1$`, strings.concatenate({strings.repeat("a", 40, context.temp_allocator), "b"}, context.temp_allocator)).err, "retry-limit-in-match over")
}

@(test)
test_ecma_group_names :: proc(t: ^testing.T) {
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
		re, err := regex.compile(c.pattern, {ecma = true}, growing(&arena))
		if c.name == "" {
			testing.expectf(t, err != "", "%q compiled", c.pattern)
		} else {
			testing.expectf(t, err == "" && len(re.names) == 2 && re.names[1] == c.name, "%q: %q, names %q", c.pattern, err, re.names)
		}
	}
}

@(test)
test_jq_matches_where_oniguruma_does :: proc(t: ^testing.T) {
	Case :: struct {
		pattern, text: string,
		flags:         regex.Flags,
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
		testing.expectf(t, f.lo == c.lo && f.hi == c.hi, "%q on %q: %d..%d %s, want %d..%d", c.pattern, c.text, f.lo, f.hi, f.err, c.lo, c.hi)
	}
	for pattern in ([?]string{`(?)`, `(?<=(?<=ab?)|)`, `(?<!(?<=ab?)|)`}) {
		testing.expectf(t, search(pattern, "", flags = {}).err != "", "%q compiled", pattern)
	}
	testing.expect(t, search(`(?<=(?<=a+)|)`, "", flags = {}).err == "")
}

@(test)
test_sample_ends_an_empty_repeat :: proc(t: ^testing.T) {
	arena: virtual.Arena
	context.allocator = growing(&arena)
	src := regex.Source{state = 1}
	for pattern in ([?]string{`(?:){2000000000}`, `(?:){9007199254740991}`, `(?:(?:){100000}){100000}`}) {
		text, ok := regex.sample(pattern, &src, 3, 0)
		testing.expectf(t, ok && text == "", "%q: %v %q", pattern, ok, text)
	}
}

@(test)
test_regex_jq_group_names :: proc(t: ^testing.T) {
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
		_, err := regex.compile(c.pattern, {}, context.temp_allocator)
		testing.expectf(t, err == c.want, "%q: %q, want %q", c.pattern, err, c.want)
	}
}

@(test)
test_ecma_refusals :: proc(t: ^testing.T) {
	refused := [?]string {
		`\k<x>`, `(a)\2`, `(?<x>a)\k<x`, `(?<=a)*`, `(?<!a)+b`, `(?<=a){2}`, `a{`, `a{2,1}`, `]`, `}`, `\q`, `[b-a]`, `[\d-z]`,
		`\u{110000}`, `\p{Nope}`, `\p{scx=Nope}`, `\p{scx}`, `\p{letter}`, `\p{Greek}`, `\p{Word}`, `\p{gc=Greek}`, `(?<1>a)`,
		`(?<n>a)(?<n>b)`, `(?=a)*`, `^*`, `a**`, `(a`, `a)`, `(?x)`, `\c1`, `\00`, `\-?`, `a+?\-`,
		`\&`, `\%`, `[\&]`, `[\%]`, `\#`, `\ `, `\!`, `\"`, `\,`, `\:`, `\;`, `\<`, `\=`, `\>`, `\@`, `\~`, `\_`, `\'`, `[\_]`,
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
	// A back reference is valid when it names a group the pattern has, before or after it, and a name is an identifier.
	refused := [?]string{`\1`, `\5`, `(a)\2`, `(a)\10`, `\8`, `\k<a>`, `(?<a>x)\k<b>`, `\k<1>`, `\k<a>x`, `\k`, `\k<>`, `\ka`}
	for pattern in refused {
		testing.expectf(t, !regex.valid(pattern, {ecma = true}), "%q is valid", pattern)
	}
	accepted := [?]string{`(a)\1`, `\1(a)`, `\k<a>(?<a>x)`, `(?<a>x)\k<a>`, `(?<a>x)\k<\u0061>`, `(?<=a)b`, `(?<!a)b`}
	for pattern in accepted {
		testing.expectf(t, regex.valid(pattern, {ecma = true}), "%q is not valid", pattern)
		testing.expectf(t, regex.refusal(pattern, {ecma = true}, context.temp_allocator) == "", "%q does not compile", pattern)
	}
}

@(test)
test_ecma_search_is_linear :: proc(t: ^testing.T) {
	// Without the visited set each of these resumes exponentially or quadratically many alternatives. With it, on four
	// times the text the search resumes under six times as many.
	Case :: struct {
		pattern, tail: string,
		flags:         regex.Flags,
	}
	cases := [?]Case {
		{`(a*)*b`, "c", {ecma = true}},
		{`(a|a)*b`, "c", {ecma = true}},
		{`^(a+)+$`, "!", {ecma = true}},
		{`(a|aa)+$`, "!", {ecma = true}},
		{`a*a*a*a*a*b`, "", {ecma = true}},
		{`(?=(a|aa)*b)c`, "c", {ecma = true}}, // a look-ahead is tried at every start
		{`(?=a*b)c`, "c", {ecma = true}},
		{`(?!(a|aa)*c)b`, "b", {ecma = true}},
		{`^(a|a)*b`, "xb", {}}, // a jq program of choices in a loop
		{`(a|aa)+$`, "!", {}},
	}
	for c in cases {
		small := search(c.pattern, strings.concatenate({strings.repeat("a", 2_000, context.temp_allocator), c.tail}, context.temp_allocator), flags = c.flags)
		large := search(c.pattern, strings.concatenate({strings.repeat("a", 8_000, context.temp_allocator), c.tail}, context.temp_allocator), flags = c.flags)
		testing.expectf(t, small.err == "" && large.err == "", "%q: %s %s", c.pattern, small.err, large.err)
		testing.expectf(t, large.resumes < 6 * max(small.resumes, 100), "%q: %d resumed on 2000 letters, %d on 8000", c.pattern, small.resumes, large.resumes)
	}
}

@(test)
test_ecma_search_is_capped_by_memory :: proc(t: ^testing.T) {
	text := strings.repeat("x", 1 << 20, context.temp_allocator)
	testing.expect_value(t, search(`(?:a|b){1000}`, text).err, "fail to memory allocation")
}

@(test)
test_ecma_counted_search_is_bounded :: proc(t: ^testing.T) {
	// Nested counted repeats multiply the pairs a search visits. A search that reads groups, or one under a look-ahead,
	// gives up with the memory error within a bound linear in the program and the text. Each search uses its whole work
	// budget, so few patterns are run: the lazy and wider spellings of the first reach the same budget in the same code.
	letters := strings.repeat("a", 3_000, context.temp_allocator)
	text := strings.concatenate({letters, "cbx"}, context.temp_allocator)
	for pattern in ([?]string{`((a{1,100}){1,100}){1,100}b`, `(?=(?:a{1,200}){1,200})x`}) {
		for whether in ([?]bool{false, true}) {
			if whether && pattern[1] != '?' {
				continue
			}
			f := search(pattern, text, whether = whether)
			testing.expectf(t, f.err == "fail to memory allocation" && f.resumes <= 1 << 26, "%q: %q after %d", pattern, f.err, f.resumes)
		}
	}
	testing.expect_value(t, search(`^(a{1,1000}){1,1000}b`, strings.concatenate({letters[:500], "b"}, context.temp_allocator)).hi, 501)
}

// A search that reads no bounds decides the counted repeats that the backtracker's budget or memory leaves undecided.
@(test)
test_ecma_counted_whether_is_decided :: proc(t: ^testing.T) {
	Case :: struct {
		pattern, piece: string,
		times:          int,
		tail:           string,
		found:          bool,
	}
	cases := [?]Case {
		{`((a{1,100}){1,100}){1,100}b`, "a", 3_000, "cbx", false},
		{`((a{1,100}){1,100}){1,100}b`, "a", 3_000, "b", true},
		{`(?:a|b){1000}`, "x", 1 << 20, "", false},
		{`(?:a|b){1000}`, "ab", 1 << 19, "", true},
	}
	for c in cases {
		text := strings.concatenate({strings.repeat(c.piece, c.times, context.temp_allocator), c.tail}, context.temp_allocator)
		f := search(c.pattern, text, whether = true)
		testing.expectf(t, f.err == "" && (f.hi >= 0) == c.found, "%q on %d of %q: %q, %v", c.pattern, c.times, c.piece, f.err, f.hi >= 0)
	}
}

// Advances the generator state `state` and returns a draw from 0..<n.
next :: proc(state: ^u64, n: int) -> int {
	state^ = state^ * 6364136223846793005 + 1442695040888963407
	return int(state^ >> 33) % n
}

// Returns a text of up to ten of `pieces` drawn from `state`. The last two pieces are used one time in eight and are
// replaced by `pieces[0]` otherwise.
random_text :: proc(state: ^u64, pieces: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< next(state, 11) {
		k := next(state, len(pieces))
		if k >= len(pieces) - 2 && state^ & 7 != 0 {
			k = 0
		}
		strings.write_string(&b, pieces[k])
	}
	return strings.to_string(b)
}

// Writes a pattern drawn from `state` with `depth` levels of nesting left.
Generator :: proc(b: ^strings.Builder, state: ^u64, depth: int)

// Writes `open`, a pattern from `gen`, then with `alternatives` a `|` and a second pattern, then `)`.
nested :: proc(gen: Generator, b: ^strings.Builder, state: ^u64, depth: int, open: string, alternatives := false) {
	strings.write_string(b, open)
	gen(b, state, depth - 1)
	if alternatives {
		strings.write_string(b, "|")
		gen(b, state, depth - 1)
	}
	strings.write_string(b, ")")
}

// Writes a pattern over `a` and `b` drawn from `state`.
generate :: proc(b: ^strings.Builder, state: ^u64, depth: int) {
	for _ in 0 ..< 1 + next(state, 3) {
		repeatable := true
		k := next(state, 14)
		switch {
		case k < 3:
			strings.write_string(b, "a")
		case k < 5:
			strings.write_string(b, "b")
		case k == 5:
			strings.write_string(b, ".")
		case k == 6:
			strings.write_string(b, "[^a]")
		case k == 7:
			strings.write_string(b, "(?:^|$|\\b)")
			repeatable = false
		case depth == 0:
			strings.write_string(b, "ab")
		case k == 8, k == 9:
			nested(generate, b, state, depth, "(")
		case k == 10:
			nested(generate, b, state, depth, "(?:", true)
		case:
			nested(generate, b, state, depth, "(?=" if k < 13 else "(?!")
			repeatable = false
		}
		if repeatable {
			quantifiers := [?]string{"", "", "", "*", "+", "?", "*?", "+?", "??", "{2}", "{1,3}", "{2,}", "{0,2}?"}
			strings.write_string(b, quantifiers[next(state, len(quantifiers))])
		}
	}
}

// With and without the visited set the search finds the same match and groups, on texts over `a`, `b` and `c` of up
// to ten letters.
@(test)
test_ecma_visited_set_keeps_the_matches :: proc(t: ^testing.T) {
	state := u64(20261109)
	for _ in 0 ..< 8000 {
		b := strings.builder_make(context.temp_allocator)
		generate(&b, &state, 2)
		text := make([]byte, next(&state, 11), context.temp_allocator)
		letters := "aaabbc"
		for &c in text {
			c = letters[next(&state, 6)]
		}
		pattern := strings.to_string(b)
		with, without := search(pattern, string(text)), search(pattern, string(text), linear = false)
		with.resumes, with.automaton, with.ends, without.resumes = 0, false, -1, 0
		testing.expectf(t, with == without, "%q on %q: %v with the set, %v without", pattern, string(text), with, without)
	}
}

// The automaton answers each of these on a long text in one pass, where a backtracker without the visited set takes
// time that is a power of the text's length.
@(test)
test_ecma_automaton_is_linear :: proc(t: ^testing.T) {
	Case :: struct {
		pattern, tail: string,
		found:         bool,
	}
	cases := [?]Case {
		{`^(a|a)*$`, "!", false},
		{`^(a|a)*$`, "", true},
		{`^a*a*a*b`, "c", false},
		{`(a*)*b`, "c", false},
		{`(a|aa)+$`, "!", false},
		{`^(a+)+$`, "a", true},
		{`^[^@]+@[^@]+\.[a-z]+$`, "@a.b.c.d!", false},
		{`^(?:a|ab|b)*c`, "c", true},
		{`^(?=[^!*,;{}[\]~\n]+$)(?=(.*\w)).+$`, "", true},
		{`^(?=[^!*,;{}[\]~\n]+$)(?=(.*\w)).+$`, "!", false},
		{`^(?!(a|aa)*b)(?=a*$)(a|a)*$`, "", true},
		{`^(?!(a|aa)*b)a*`, "b", false},
	}
	text := strings.repeat("a", 200_000, context.temp_allocator)
	for c in cases {
		f := search(c.pattern, strings.concatenate({text, c.tail}, context.temp_allocator), whether = true)
		testing.expectf(t, f.automaton && f.err == "" && (f.lo == 0) == c.found, "%q: automaton %v, %v %s", c.pattern, f.automaton, f.lo == 0, f.err)
	}
	// A look-ahead past the text's start leaves a pattern with no automaton, so the visited set runs it. `\b` does not.
	for pattern in ([?]string{`(?=a)b`, `(?!a*b)a`, `^a(?=a)`, `^(?=a(?=b))`, `^(?<=a)b`}) {
		testing.expectf(t, !search(pattern, "a").automaton, "%q has an automaton", pattern)
	}
	for pattern in ([?]string{`\ba`, `a\B`}) {
		testing.expectf(t, search(pattern, "a").automaton, "%q has no automaton", pattern)
	}
}

// Building the automata of each of these patterns stays within 8 MiB of working memory at once and 16 MiB allocated in
// all, frees its working memory before it returns, and keeps at most a megabyte of table per automaton in the program.
@(test)
test_ecma_automaton_build_is_bounded :: proc(t: ^testing.T) {
	repeat :: proc(piece: string, n: int, sep := "") -> string {
		b := strings.builder_make(context.temp_allocator)
		for i in 0 ..< n {
			strings.write_string(&b, sep if i > 0 else "")
			strings.write_string(&b, piece)
		}
		return strings.to_string(b)
	}
	runes :: proc(first: rune, n, step: int, sep: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		for i in 0 ..< n {
			strings.write_string(&b, sep if i > 0 else "")
			strings.write_rune(&b, first + rune(i * step))
		}
		return strings.to_string(b)
	}
	cut :: proc(piece: string) -> string {
		return strings.concatenate({"[^", piece, "]"}, context.temp_allocator)
	}
	patterns := [?]string {
		strings.concatenate({"^(?:[a-z]{0,1700}|", runes(0x100, 250, 1, "|"), ")$"}, context.temp_allocator),
		strings.concatenate({"(a|b)*a(a|b){9}c|(?:", repeat("$", 300, "|"), ")", repeat("()", 20_000), "b"}, context.temp_allocator),
		strings.concatenate({"(?:", runes(0x100, 2000, 1, "|"), ")", repeat("()", 20_000), "x"}, context.temp_allocator),
		repeat(`\p{L}`, 1000),
		repeat(`[\p{scx=Latn}\p{scx=Grek}\p{scx=Cyrl}\p{scx=Arab}\p{scx=Hani}\p{L}\p{N}\p{P}\p{S}\p{M}\p{Cn}]`, 500),
		repeat(cut(runes(0x10000, 20_000, 2, "")), 5),
		`^[a-j]{2046}$`,
		`(a|b)*a(a|b){20}`,
		`^[a-z]{0,1000}$`,
	}
	// Under jq's syntax the build makes three automata within a single budget. Only under ECMA's syntax may a pattern
	// fail to compile.
	for k in 0 ..< 2 * len(patterns) {
		pattern, flags := patterns[k / 2], regex.Flags{ecma = k % 2 == 0}
		automata := 1 if flags.ecma else 3
		program, scratch: mem.Tracking_Allocator
		arena: virtual.Arena
		mem.tracking_allocator_init(&program, growing(&arena))
		defer mem.tracking_allocator_destroy(&program)
		mem.tracking_allocator_init(&scratch, context.allocator)
		defer mem.tracking_allocator_destroy(&scratch)
		err: string
		{
			context.allocator = mem.tracking_allocator(&scratch)
			_, err = regex.compile(pattern, flags, mem.tracking_allocator(&program))
		}
		name := pattern[:min(len(pattern), 40)]
		testing.expectf(t, err == "" || !flags.ecma, "%q: %s", name, err)
		testing.expectf(t, scratch.current_memory_allocated == 0, "%q keeps %d bytes of scratch", name, scratch.current_memory_allocated)
		testing.expectf(t, scratch.peak_memory_allocated <= 8 << 20, "%q: %d bytes of scratch at once", name, scratch.peak_memory_allocated)
		testing.expectf(t, scratch.total_memory_allocated <= 16 << 20, "%q: %d bytes of scratch in all", name, scratch.total_memory_allocated)
		testing.expectf(t, program.current_memory_allocated <= i64(automata << 20 + 300 * len(pattern)), "%q keeps %d bytes", name, program.current_memory_allocated)
	}
}

// A search from past the end of the text finds nothing, with the automaton and without it.
@(test)
test_ecma_search_from_past_the_end :: proc(t: ^testing.T) {
	arena: virtual.Arena
	allocator := growing(&arena)
	scratch: regex.Scratch
	defer regex.scratch_destroy(&scratch)
	for pattern in ([?]string{`a*`, `$`, `(?=a)|`}) {
		re, err := regex.compile(pattern, {ecma = true}, allocator)
		testing.expect(t, err == "")
		for start in ([?]int{3, 5}) {
			found: bool
			found, err = regex.search(&re, "ab", start, nil, &scratch)
			testing.expectf(t, !found && err == "", "%q from %d on \"ab\": %v %s", pattern, start, found, err)
		}
	}
}

// Writes a pattern drawn from `state` of the characters `a`, `b`, `é` and `😀`, classes, `^`, `$` and groups, which the
// automaton runs.
generate_plain :: proc(b: ^strings.Builder, state: ^u64, depth: int) {
	for _ in 0 ..< 1 + next(state, 3) {
		atoms := [?]string{"a", "b", "é", "😀", ".", "[^a]", "[a-cé]", "\\w", "\\d", "\\s", "\\p{L}", "\\P{Ll}", "[^\\p{Lu}b]", "ab", "aé"}
		k := next(state, len(atoms) + 6)
		repeatable := true
		switch {
		case k < len(atoms):
			strings.write_string(b, atoms[k])
		case k == len(atoms):
			strings.write_string(b, "^" if next(state, 2) == 0 else "$")
			repeatable = false
		case depth == 0:
			strings.write_string(b, "a")
		case k < len(atoms) + 3:
			nested(generate_plain, b, state, depth, "(")
		case:
			nested(generate_plain, b, state, depth, "(?:", true)
		}
		if repeatable {
			quantifiers := [?]string{"", "", "", "*", "+", "?", "*?", "+?", "??", "{2}", "{1,3}", "{2,}", "{0,2}?", "{3}"}
			strings.write_string(b, quantifiers[next(state, len(quantifiers))])
		}
	}
}

// On generated patterns and on texts of up to ten characters, some not valid UTF-8, the automaton finds a match exactly
// where the visited set's search does, and the automata that find where a match ends and starts give the match and
// groups that a backtracker without them gives.
@(test)
test_ecma_automaton_keeps_the_answers :: proc(t: ^testing.T) {
	state := u64(20261110)
	built, first := 0, 0
	pieces := [?]string{"a", "a", "b", "é", "😀", "A", "1", " ", "\n", "-", "\xff", "\x80"}
	for i in 0 ..< 4000 {
		b := strings.builder_make(context.temp_allocator)
		if i % 2 == 0 {
			generate_plain(&b, &state, 2)
		} else {
			generate(&b, &state, 2)
		}
		text := random_text(&state, pieces[:])
		pattern := strings.to_string(b)
		whether := search(pattern, text, whether = true)
		with := search(pattern, text)
		plain := search(pattern, text, linear = false)
		built += int(whether.automaton)
		first += int(with.ends >= 0)
		testing.expectf(t, whether.err == with.err && (whether.lo >= 0) == (with.lo >= 0), "%q on %q: %v whether, %v with the set", pattern, text, whether, with)
		with.resumes, with.ends, with.automaton, plain.resumes = 0, -1, false, 0
		testing.expectf(t, plain.err != "" || with == plain, "%q on %q: %v with the automata, %v backtracking", pattern, text, with, plain)
	}
	testing.expectf(t, built > 1600 && first > 600, "%d of 4000 patterns have the automaton, %d searches found a match's end with it", built, first)
}

// A counted repeat too long to write out runs as a counter loop, and finds the match and groups that the same repeat
// written out finds. A body grows past the bound with alternatives of characters that no text holds, which change no
// match, and a repeat around a counter loop grows the same way. The counter loop's search gives the same answers
// without the visited set.
@(test)
test_ecma_counter_loops_keep_the_answers :: proc(t: ^testing.T) {
	fill := strings.builder_make(context.temp_allocator)
	for k in 0 ..< 700 {
		strings.write_string(&fill, "|")
		strings.write_rune(&fill, 0xE000 + rune(k))
	}
	counts := [?]string{"{4}", "{1,4}", "{0,4}", "{0,4}?", "{4,}", "{4,}?", "{4}?", "{2,5}", "{3,6}?"}
	state := u64(20261111)
	for i in 0 ..< 2000 {
		g := strings.builder_make(context.temp_allocator)
		if i % 2 == 0 {
			generate_plain(&g, &state, 2)
		} else {
			generate(&g, &state, 1)
		}
		inner, outer := counts[next(&state, len(counts))], counts[next(&state, len(counts))]
		written, looped: string
		if i % 3 == 0 {
			written = strings.concatenate({"(?:(?:", strings.to_string(g), ")", inner, ")", outer}, context.temp_allocator)
			looped = strings.concatenate({"(?:(?:", strings.to_string(g), strings.to_string(fill), ")", inner, strings.to_string(fill), ")", outer}, context.temp_allocator)
		} else {
			written = strings.concatenate({"(?:", strings.to_string(g), ")", inner}, context.temp_allocator)
			looped = strings.concatenate({"(?:", strings.to_string(g), strings.to_string(fill), ")", inner}, context.temp_allocator)
		}
		text := make([]byte, next(&state, 11), context.temp_allocator)
		letters := "aaabbc"
		for &c in text {
			c = letters[next(&state, 6)]
		}
		want, got := search(written, string(text)), search(looped, string(text))
		want.resumes, want.automaton, want.ends, got.resumes = 0, false, -1, 0
		testing.expectf(t, got == want, "%q%s on %q: %v as a counter loop, %v written out", strings.to_string(g), inner, string(text), got, want)
		if i % 4 == 0 {
			plain := search(looped, string(text), linear = false)
			plain.resumes = 0
			testing.expectf(t, plain.err != "" || plain == got, "%q%s on %q: %v without the visited set, %v with it", strings.to_string(g), inner, string(text), plain, got)
		}
	}
}

// Nested counted repeats compile to a program the size of their bodies, a count too large for the text to hold
// (`{0,2000000000}`) compiles within 4 MiB, and a search whose visited set would pass the memory bound is refused
// before it allocates the set.
@(test)
test_ecma_nested_counts_are_bounded :: proc(t: ^testing.T) {
	Case :: struct {
		pattern, text: string,
		found:         bool,
		refused:       bool,
	}
	text := strings.concatenate({strings.repeat("ab", 2_000, context.temp_allocator), "c"}, context.temp_allocator)
	cases := [?]Case {
		{`^(?:(?:ab){1,100}){1,100}d`, text, false, false},
		{`(?:(?:ab){1,100}){1,100}c`, text, true, false},
		{`((((a|b){1,100}){1,100}){1,100}){1,100}c`, text, false, true},
		{`((((a|b){1,100}){1,100}){1,100}){1,100}c`, "abc", true, false},
		{`(?:ab){0,2000000000}c`, text, true, false},
		{`((?:ab){0,2000000000}){0,2000000000}c`, "ababc", true, false},
		{`^(?:(?:ab){2000,})c`, text, true, false},
		{`^(?:(?:ab){2001,})c`, text, false, false},
	}
	for c in cases {
		program: mem.Tracking_Allocator
		arena: virtual.Arena
		mem.tracking_allocator_init(&program, growing(&arena))
		defer mem.tracking_allocator_destroy(&program)
		re, err := regex.compile(c.pattern, {ecma = true}, mem.tracking_allocator(&program))
		testing.expectf(t, err == "" && program.peak_memory_allocated < 4 << 20, "%q: %s, %d bytes", c.pattern, err, program.peak_memory_allocated)
		scratch: regex.Scratch
		defer regex.scratch_destroy(&scratch)
		caps: [2]int
		found, search_err := regex.search(&re, c.text, 0, caps[:], &scratch)
		if c.refused {
			testing.expectf(t, search_err == "fail to memory allocation" && cap(scratch.seen) == 0, "%q: %v %q", c.pattern, found, search_err)
		} else {
			testing.expectf(t, search_err == "" && found == c.found, "%q: %v %q", c.pattern, found, search_err)
		}
	}
}

// On texts of up to ten characters, some not valid UTF-8, the automaton of a pattern that begins with look-aheads after
// `^` finds a match exactly where a backtracker without the visited set does.
@(test)
test_ecma_leading_look_aheads_keep_the_answers :: proc(t: ^testing.T) {
	state := u64(20261111)
	built := 0
	pieces := [?]string{"a", "a", "b", "é", "😀", "A", "1", " ", "\n", "-", "\xff", "\x80"}
	for i in 0 ..< 4000 {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "^")
		for _ in 0 ..< 1 + next(&state, 3) {
			state = state * 6364136223846793005 + 1442695040888963407
			strings.write_string(&b, "(?!" if state >> 62 == 0 else "(?=")
			if i % 4 == 3 {
				generate(&b, &state, 1)
			} else {
				generate_plain(&b, &state, 2)
			}
			strings.write_string(&b, ")")
		}
		generate_plain(&b, &state, 2)
		text := random_text(&state, pieces[:])
		pattern := strings.to_string(b)
		whether := search(pattern, text, whether = true)
		plain := search(pattern, text, linear = false)
		if plain.err != "" {
			// The backtracker gave up at its retry limit, where the visited set does not.
			plain = search(pattern, text)
		}
		built += int(whether.automaton)
		testing.expectf(t, whether.err == plain.err && (whether.lo >= 0) == (plain.lo >= 0), "%q on %q: %v whether, %v backtracking", pattern, text, whether, plain)
	}
	testing.expectf(t, built > 2400, "%d of 4000 patterns have the automaton", built)
}

// Writes a jq pattern drawn from `state`, of the instructions and assertions the automaton runs and some it does not,
// such as `(?=a)`.
generate_jq :: proc(b: ^strings.Builder, state: ^u64, depth: int) {
	for _ in 0 ..< 1 + next(state, 3) {
		atoms := [?]string{"a", "A", "b", "k", "é", "É", "ß", "_", " ", "1", ".", "[a-c]", "[^a]", "[K\\d]", "\\w", "\\W", "\\d", "\\s", "\\p{L}", "[\\w-]", "\\b", "\\B", "^", "$", "\\A", "\\z", "\\Z", "\\n", "ab", "(?i:a)", "(?i:[k-m])", "(?i:é)", "(?=a)"}
		k := next(state, len(atoms) + 4)
		switch {
		case k < len(atoms):
			strings.write_string(b, atoms[k])
		case depth == 0:
			strings.write_string(b, "a")
		case k < len(atoms) + 2:
			nested(generate_jq, b, state, depth, "(")
		case:
			nested(generate_jq, b, state, depth, "(?:", true)
		}
		quantifiers := [?]string{"", "", "", "*", "+", "?", "*?", "+?", "{2}", "{1,3}", "{2,}"}
		strings.write_string(b, quantifiers[next(state, len(quantifiers))])
	}
}

// Under jq's syntax the automaton answers the assertions at a text's edges and line breaks as Oniguruma does.
@(test)
test_jq_automaton_assertions :: proc(t: ^testing.T) {
	Case :: struct {
		pattern, text: string,
		flags:         regex.Flags,
		found:         bool,
	}
	lines :: regex.Flags{multiline = true}
	cases := [?]Case {
		{"\\n^", "a\n", lines, false}, // `^` does not hold after a newline that ends the text
		{"\\n^", "a\nb", lines, true},
		{"\\n^", "a\nb", {}, false},
		{"a$", "a\nb", lines, true},
		{"a$\\n", "a\n", lines, true},
		{"a$", "a\nb", {}, false},
		{"a$", "a\n", {}, true},
		{"a$", "a\n\n", {}, false},
		{"\\n$", "a\n\n", {}, true},
		{"$", "", {}, true},
		{"a\\z", "a\n", {}, false},
		{"a\\Z", "a\n", {}, true},
		{"a\\Z\\n", "a\n", {}, true},
		{"\\Aa", "ba", {}, false},
		{"^$", "", {}, true},
		{"\\ba\\b", "b a_", {}, false},
		{"\\ba\\b", "b a-", {}, true},
		{"\\Ba", "ba", {}, true},
		{"\\bé", " é", {}, true}, // a letter past ASCII is a word character
		{"k", "\u212a", {fold = true}, true},
		{"[^k]", "\u212a", {fold = true}, false},
		{"ss", "ß", {fold = true}, true},
		{".", "\n", {}, false},
		{".", "\n", {dotall = true}, true},
		{"a b", "ab", {extend = true}, true},
		{"$", "\n", {}, true},
		{"ss$", "s\u017f", {fold = true}, true}, // a folded character may be longer than the one it folds to
		{"ss\\z", "x\u017f\u017f", {fold = true}, true},
		{"\u00df$", "x\u017fs", {fold = true}, true},
	}
	for c in cases {
		whether := search(c.pattern, c.text, flags = c.flags, whether = true)
		with := search(c.pattern, c.text, flags = c.flags)
		testing.expectf(t, whether.automaton, "%q has no automaton", c.pattern)
		testing.expectf(t, (whether.lo >= 0) == c.found && (with.lo >= 0) == c.found, "%q %v on %q: %v whether, %v with the set", c.pattern, c.flags, c.text, whether, with)
	}
}

// Under jq's syntax and flags, on generated patterns and on texts of up to ten characters across words, lines and case,
// the automata find a match exactly where the backtracker does, with the same span and group 1 bounds.
@(test)
test_jq_automaton_keeps_the_answers :: proc(t: ^testing.T) {
	state := u64(20261111)
	built, first := 0, 0
	pieces := [?]string{"a", "a", "A", "b", "k", "K", "\u212a", "é", "É", "ß", "s", "_", "1", " ", "\n", "-", "😀"}
	for _ in 0 ..< 4000 {
		b := strings.builder_make(context.temp_allocator)
		generate_jq(&b, &state, 2)
		count := next(&state, 11)
		flags := regex.Flags{fold = state & 8 != 0, dotall = state & 16 != 0, extend = state & 32 != 0, multiline = state & 64 != 0}
		text := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< count {
			strings.write_string(&text, pieces[next(&state, len(pieces))])
		}
		pattern := strings.to_string(b)
		whether := search(pattern, strings.to_string(text), flags = flags, whether = true)
		with := search(pattern, strings.to_string(text), flags = flags)
		plain := search(pattern, strings.to_string(text), linear = false, flags = flags)
		built += int(whether.automaton)
		first += int(with.ends >= 0)
		testing.expectf(t, whether.err == plain.err && (whether.lo >= 0) == (plain.lo >= 0), "%q %v on %q: %v whether, %v backtracking", pattern, flags, strings.to_string(text), whether, plain)
		testing.expectf(t, with.ends < 0 || with.ends == with.hi, "%q %v on %q: the automaton ends the match at %d, the backtracker at %d", pattern, flags, strings.to_string(text), with.ends, with.hi)
		with.resumes, with.ends, with.automaton, plain.resumes = 0, -1, false, 0
		testing.expectf(t, with == plain, "%q %v on %q: %v with the automata, %v backtracking", pattern, flags, strings.to_string(text), with, plain)
	}
	testing.expectf(t, built > 1600 && first > 600, "%d of 4000 patterns have the automaton, %d searches found a match's end with it", built, first)
}
