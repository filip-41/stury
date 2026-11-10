package regex_tests

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import regex ".."

// The first match of `pattern` in `text`, its span and group 1's (-1 for none), or the message of why there is none,
// with the alternatives the search resumed. Under `ecma` the pattern is ECMA's, otherwise jq's. Under `whether` the
// search reads no bounds, and the span is 0..0 for a match.
Found :: struct {
	lo, hi, g1, g1_end: int,
	err:                string,
	resumes:            int,
	automaton:          bool, // the pattern has the automaton that answers a search reading no bounds
}

search :: proc(pattern, text: string, linear := true, flags := regex.Flags{ecma = true}, whether := false) -> (f: Found) {
	f = {-1, -1, -1, -1, "", 0, false}
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
	f.automaton = re.dfa != nil
	scratch: regex.Scratch
	defer regex.scratch_destroy(&scratch)
	caps: [4]int
	found: bool
	found, err = regex.search(&re, text, 0, caps[:0 if whether else min(4, 2 * len(re.names))], &scratch)
	f.err, f.resumes = strings.clone(err, context.temp_allocator), scratch.resumes
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
		{`^[a-z]{0,65535}$`, letters, 0, 20_000, -1, -1}, // a repeat of one character is no copies
		{`(?=(a+))a\d`, "aaa1", 2, 4, 2, 3}, // a group in a look-ahead keeps its span past the visited set's shortcut
		{`(?=(a|aa)*(b))a.*c`, "aabc", 0, 4, 1, 2},
		{`(?<\u0061b>x)`, "x", 0, 1, 0, 1}, // a group name may be written with escapes
		{`\&\%[\&\%]`, "x&%%", 1, 4, -1, -1}, // an escaped ASCII punctuation character is itself
		{`^\/[^\*\?\&\%]*$`, "/a&", -1, -1, -1, -1},
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
	}
	for c in cases {
		f := search(c.pattern, c.text)
		testing.expectf(t, f.lo == c.lo && f.hi == c.hi && f.g1 == c.g1 && f.g1_end == c.g1_end, "%q on %.20q: got %d..%d (%d..%d) %s, want %d..%d (%d..%d)", c.pattern, c.text, f.lo, f.hi, f.g1, f.g1_end, f.err, c.lo, c.hi, c.g1, c.g1_end)
	}
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
		testing.expect(t, virtual.arena_init_growing(&arena) == nil)
		defer virtual.arena_destroy(&arena)
		re, err := regex.compile(c.pattern, {ecma = true}, virtual.arena_allocator(&arena))
		if c.name == "" {
			testing.expectf(t, err != "", "%q compiled", c.pattern)
		} else {
			testing.expectf(t, err == "" && len(re.names) == 2 && re.names[1] == c.name, "%q: %q, names %q", c.pattern, err, re.names)
		}
	}
}

@(test)
test_regex_jq_group_names :: proc(t: ^testing.T) {
	// Oniguruma's: a name starts with a word character, and a backslash in it is a backslash.
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
		`(a)\1`, `\k<x>`, `(?<x>a)\k<x>`, `(?<=a)b`, `(?<!a)b`, `a{`, `a{2,1}`, `]`, `}`, `\q`, `[b-a]`, `[\d-z]`,
		`\u{110000}`, `\p{Nope}`, `\p{scx=Nope}`, `\p{scx}`, `\p{letter}`, `\p{Greek}`, `\p{Word}`, `\p{gc=Greek}`, `(?<1>a)`,
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
		testing.expectf(t, with == without, "%q on %q: %v with the set, %v without", pattern, string(text), with, without)
	}
}

// The automaton answers each of these on a long text in one pass, where a backtracker without the visited set takes a
// power of the text's length.
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
	}
	text := strings.repeat("a", 200_000, context.temp_allocator)
	for c in cases {
		f := search(c.pattern, strings.concatenate({text, c.tail}, context.temp_allocator), whether = true)
		testing.expectf(t, f.automaton && f.err == "" && (f.lo == 0) == c.found, "%q: automaton %v, %v %s", c.pattern, f.automaton, f.lo == 0, f.err)
	}
	// Look-ahead and `\b` leave a pattern to the visited set.
	for pattern in ([?]string{`(?=a)b`, `(?!a*b)a`, `\ba`, `a\B`}) {
		testing.expectf(t, !search(pattern, "a").automaton, "%q has an automaton", pattern)
	}
}

// Building the automaton of each of these patterns stays within a bound on its working memory, on the bytes it moves
// and on its time, frees its working memory before it returns and keeps the program and a table of at most a megabyte.
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
	for pattern in patterns {
		program, scratch: mem.Tracking_Allocator
		arena: virtual.Arena
		testing.expect(t, virtual.arena_init_growing(&arena) == nil)
		defer virtual.arena_destroy(&arena)
		mem.tracking_allocator_init(&program, virtual.arena_allocator(&arena))
		defer mem.tracking_allocator_destroy(&program)
		mem.tracking_allocator_init(&scratch, context.allocator)
		defer mem.tracking_allocator_destroy(&scratch)
		start := time.tick_now()
		err: string
		{
			context.allocator = mem.tracking_allocator(&scratch)
			_, err = regex.compile(pattern, {ecma = true}, mem.tracking_allocator(&program))
		}
		took := time.tick_since(start)
		name := pattern[:min(len(pattern), 40)]
		testing.expectf(t, err == "", "%q: %s", name, err)
		testing.expectf(t, scratch.current_memory_allocated == 0, "%q keeps %d bytes of scratch", name, scratch.current_memory_allocated)
		testing.expectf(t, scratch.peak_memory_allocated <= 8 << 20, "%q: %d bytes of scratch at once", name, scratch.peak_memory_allocated)
		testing.expectf(t, scratch.total_memory_allocated <= 16 << 20, "%q: %d bytes of scratch in all", name, scratch.total_memory_allocated)
		testing.expectf(t, program.current_memory_allocated <= i64(1 << 20 + 300 * len(pattern)), "%q keeps %d bytes", name, program.current_memory_allocated)
		testing.expectf(t, took < 2 * time.Second, "%q compiles in %v", name, took)
	}
}

// A search from past the end of the text finds nothing, with the automaton and without it.
@(test)
test_ecma_search_from_past_the_end :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	scratch: regex.Scratch
	defer regex.scratch_destroy(&scratch)
	for pattern in ([?]string{`a*`, `$`, `(?=a)|`}) {
		re, err := regex.compile(pattern, {ecma = true}, virtual.arena_allocator(&arena))
		testing.expect(t, err == "")
		for start in ([?]int{3, 5}) {
			found: bool
			found, err = regex.search(&re, "ab", start, nil, &scratch)
			testing.expectf(t, !found && err == "", "%q from %d on \"ab\": %v %s", pattern, start, found, err)
		}
	}
}

// A pattern over `a`, `b`, `é` and `😀` drawn from `state`, of the instructions the automaton runs.
generate_plain :: proc(b: ^strings.Builder, state: ^u64, depth: int) {
	next :: proc(state: ^u64, n: int) -> int {
		state^ = state^ * 6364136223846793005 + 1442695040888963407
		return int(state^ >> 33) % n
	}
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
			strings.write_string(b, "(")
			generate_plain(b, state, depth - 1)
			strings.write_string(b, ")")
		case:
			strings.write_string(b, "(?:")
			generate_plain(b, state, depth - 1)
			strings.write_string(b, "|")
			generate_plain(b, state, depth - 1)
			strings.write_string(b, ")")
		}
		if repeatable {
			quantifiers := [?]string{"", "", "", "*", "+", "?", "*?", "+?", "??", "{2}", "{1,3}", "{2,}", "{0,2}?", "{3}"}
			strings.write_string(b, quantifiers[next(state, len(quantifiers))])
		}
	}
}

// The automaton finds a match exactly where the visited set's search does, on generated patterns and on texts of up to
// ten characters, some of them not valid UTF-8.
@(test)
test_ecma_automaton_keeps_the_answers :: proc(t: ^testing.T) {
	state := u64(20261110)
	built := 0
	pieces := [?]string{"a", "a", "b", "é", "😀", "A", "1", " ", "\n", "-", "\xff", "\x80"}
	for i in 0 ..< 20000 {
		b := strings.builder_make(context.temp_allocator)
		if i % 2 == 0 {
			generate_plain(&b, &state, 2)
		} else {
			generate(&b, &state, 2)
		}
		state = state * 6364136223846793005 + 1442695040888963407
		text := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< int(state >> 33) % 11 {
			state = state * 6364136223846793005 + 1442695040888963407
			k := int(state >> 33) % len(pieces)
			if k >= len(pieces) - 2 && state & 7 != 0 {
				k = 0
			}
			strings.write_string(&text, pieces[k])
		}
		pattern := strings.to_string(b)
		whether := search(pattern, strings.to_string(text), whether = true)
		with := search(pattern, strings.to_string(text))
		built += int(whether.automaton)
		testing.expectf(t, whether.err == with.err && (whether.lo >= 0) == (with.lo >= 0), "%q on %q: %v whether, %v with the set", pattern, strings.to_string(text), whether, with)
	}
	testing.expectf(t, built > 8000, "%d of 20000 patterns have the automaton", built)
}
