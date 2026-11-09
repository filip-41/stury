package regex_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import regex ".."

// The first match of `pattern` in `text`, its span and group 1's (-1 for none), or the message of why there is none,
// with the alternatives the search resumed. Under `ecma` the pattern is ECMA's, otherwise jq's.
Found :: struct {
	lo, hi, g1, g1_end: int,
	err:                string,
	resumes:            int,
}

search :: proc(pattern, text: string, linear := true, flags := regex.Flags{ecma = true}) -> (f: Found) {
	f = {-1, -1, -1, -1, "", 0}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		f.err = "no memory"
		return
	}
	defer virtual.arena_destroy(&arena)
	re, err := regex.compile(pattern, flags, virtual.arena_allocator(&arena))
	if err != "" {
		f.err = strings.clone(err, context.temp_allocator)
		return
	}
	re.linear &&= linear
	scratch: regex.Scratch
	defer regex.scratch_destroy(&scratch)
	caps: [4]int
	found: bool
	found, err = regex.search(&re, text, 0, caps[:min(4, 2 * len(re.names))], &scratch)
	f.err, f.resumes = strings.clone(err, context.temp_allocator), scratch.resumes
	if found {
		f.lo, f.hi = caps[0], caps[1]
		if len(re.names) > 1 {
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
		{`^[a-z]{0,65535}$`, letters, 0, 20_000, -1, -1}, // a repeat of one character is no copies
	}
	for c in cases {
		f := search(c.pattern, c.text)
		testing.expectf(t, f.lo == c.lo && f.hi == c.hi && f.g1 == c.g1 && f.g1_end == c.g1_end, "%q on %.20q: got %d..%d (%d..%d) %s, want %d..%d (%d..%d)", c.pattern, c.text, f.lo, f.hi, f.g1, f.g1_end, f.err, c.lo, c.hi, c.g1, c.g1_end)
	}
}

@(test)
test_ecma_refusals :: proc(t: ^testing.T) {
	refused := [?]string {
		`(a)\1`, `\k<x>`, `(?<x>a)\k<x>`, `(?<=a)b`, `(?<!a)b`, `a{`, `a{2,1}`, `]`, `}`, `\q`, `\-`, `[b-a]`, `[\d-z]`,
		`\u{110000}`, `\p{Nope}`, `\p{scx=Latn}`, `\p{letter}`, `\p{Greek}`, `\p{Word}`, `\p{gc=Greek}`, `(?<1>a)`,
		`(?<n>a)(?<n>b)`, `(?=a)*`, `^*`, `a**`, `(a`, `a)`, `(?x)`, `\c1`, `\00`,
	}
	for pattern in refused {
		testing.expectf(t, search(pattern, "").err != "", "%q compiled", pattern)
	}
	testing.expect(t, search(`a`, "", flags = {ecma = true, fold = true}).err != "")
}

@(test)
test_ecma_search_is_linear :: proc(t: ^testing.T) {
	// Each of these resumes exponentially or quadratically many alternatives without the visited set: on four times the
	// text it resumes about four times as many.
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

// A pattern over `a` and `b` drawn from `state`.
generate :: proc(b: ^strings.Builder, state: ^u64, depth: int) {
	next :: proc(state: ^u64, n: int) -> int {
		state^ = state^ * 6364136223846793005 + 1442695040888963407
		return int(state^ >> 33) % n
	}
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
			strings.write_string(b, "(")
			generate(b, state, depth - 1)
			strings.write_string(b, ")")
		case k == 10:
			strings.write_string(b, "(?:")
			generate(b, state, depth - 1)
			strings.write_string(b, "|")
			generate(b, state, depth - 1)
			strings.write_string(b, ")")
		case:
			strings.write_string(b, "(?=" if k < 13 else "(?!")
			generate(b, state, depth - 1)
			strings.write_string(b, ")")
			repeatable = false
		}
		if repeatable {
			quantifiers := [?]string{"", "", "", "*", "+", "?", "*?", "+?", "??", "{2}", "{1,3}", "{2,}", "{0,2}?"}
			strings.write_string(b, quantifiers[next(state, len(quantifiers))])
		}
	}
}

// With and without the visited set the search finds the same match and groups, on texts over `a`, `b` and `c` no longer than ten
// letters.
@(test)
test_ecma_visited_set_keeps_the_matches :: proc(t: ^testing.T) {
	state := u64(20261109)
	for _ in 0 ..< 8000 {
		b := strings.builder_make(context.temp_allocator)
		generate(&b, &state, 2)
		state = state * 6364136223846793005 + 1442695040888963407
		text := make([]byte, int(state >> 33) % 11, context.temp_allocator)
		letters := "aaabbc"
		for &c in text {
			state = state * 6364136223846793005 + 1442695040888963407
			c = letters[int(state >> 33) % 6]
		}
		pattern := strings.to_string(b)
		with, without := search(pattern, string(text)), search(pattern, string(text), linear = false)
		with.resumes, without.resumes = 0, 0
		if strings.contains(pattern, "(?=") { // the set may leave a look-ahead's groups unset (match.odin)
			with.g1, with.g1_end, without.g1, without.g1_end = 0, 0, 0, 0
		}
		testing.expectf(t, with == without, "%q on %q: %v with the set, %v without", pattern, string(text), with, without)
	}
}
