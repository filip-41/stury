package regex_tests

import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import regex "stury:lib/base/regex"
import "stury:testkit"

// The automaton answers each of these on a long text in one pass, where a backtracker without the visited set takes
// time that is a power of the text's length.
@(test)
test_ecma_automaton_is_linear :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
		testing.expectf(
			t,
			f.automaton && f.err == "" && (f.lo == 0) == c.found,
			"%q: automaton %v, %v %s",
			c.pattern,
			f.automaton,
			f.lo == 0,
			f.err,
		)
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
	testkit.deadline(t)
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
		strings.concatenate(
			{"(a|b)*a(a|b){9}c|(?:", repeat("$", 300, "|"), ")", repeat("()", 20_000), "b"},
			context.temp_allocator,
		),
		strings.concatenate(
			{"(?:", runes(0x100, 2000, 1, "|"), ")", repeat("()", 20_000), "x"},
			context.temp_allocator,
		),
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
		pattern, flags := patterns[k / 2], Mode{ecma = k % 2 == 0}
		automata := 1 if flags.ecma else 3
		program, scratch: mem.Tracking_Allocator
		arena: virtual.Arena
		mem.tracking_allocator_init(&program, growing(&arena))
		defer mem.tracking_allocator_destroy(&program)
		mem.tracking_allocator_init(&scratch, context.allocator)
		defer mem.tracking_allocator_destroy(&scratch)
		_, err := compile(pattern, flags, mem.tracking_allocator(&program), mem.tracking_allocator(&scratch))
		name := pattern[:min(len(pattern), 40)]
		testing.expectf(t, err == "" || !flags.ecma, "%q: %s", name, err)
		testing.expectf(
			t,
			scratch.current_memory_allocated == 0,
			"%q keeps %d bytes of scratch",
			name,
			scratch.current_memory_allocated,
		)
		testing.expectf(
			t,
			scratch.peak_memory_allocated <= 8 << 20,
			"%q: %d bytes of scratch at once",
			name,
			scratch.peak_memory_allocated,
		)
		testing.expectf(
			t,
			scratch.total_memory_allocated <= 16 << 20,
			"%q: %d bytes of scratch in all",
			name,
			scratch.total_memory_allocated,
		)
		testing.expectf(
			t,
			program.current_memory_allocated <= i64(automata << 20 + 300 * len(pattern)),
			"%q keeps %d bytes",
			name,
			program.current_memory_allocated,
		)
	}
}

// On generated patterns and on texts of up to ten characters, some not valid UTF-8, the automaton finds a match exactly
// where the visited set's search does, and the automata that find where a match ends and starts give the match and
// groups that a backtracker without them gives.
@(test)
test_ecma_automaton_keeps_the_answers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 3)
	built := 0
	pieces := [?]string{"a", "a", "b", "é", "😀", "A", "1", " ", "\n", "-", "\xff", "\x80"}
	for i in 0 ..< 4000 {
		b := strings.builder_make(context.temp_allocator)
		if i % 2 == 0 {
			generate_plain(&b, 2)
		} else {
			generate(&b, 2)
		}
		text := random_text(pieces[:])
		pattern := strings.to_string(b)
		whether := search(pattern, text, whether = true)
		with := search(pattern, text)
		plain := search(pattern, text, linear = false)
		built += int(whether.automaton)
		testing.expectf(
			t,
			whether.err == with.err && (whether.lo >= 0) == (with.lo >= 0),
			"%q on %q: %v whether, %v with the set",
			pattern,
			text,
			whether,
			with,
		)
		with.spent, with.automaton, plain.spent = 0, false, 0
		testing.expectf(
			t,
			plain.err != "" || with == plain,
			"%q on %q: %v with the automata, %v backtracking",
			pattern,
			text,
			with,
			plain,
		)
	}
	testing.expectf(t, built > 1600, "%d of 4000 patterns have the automaton", built)
}

// On texts of up to ten characters, some not valid UTF-8, the automaton of a pattern that begins with look-aheads after
// `^` finds a match exactly where a backtracker without the visited set does.
@(test)
test_ecma_leading_look_aheads_keep_the_answers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 4)
	built := 0
	pieces := [?]string{"a", "a", "b", "é", "😀", "A", "1", " ", "\n", "-", "\xff", "\x80"}
	for i in 0 ..< 4000 {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "^")
		for _ in 0 ..< 1 + rand.int_max(3) {
			strings.write_string(&b, "(?!" if rand.int_max(4) == 0 else "(?=")
			if i % 4 == 3 {
				generate(&b, 1)
			} else {
				generate_plain(&b, 2)
			}
			strings.write_string(&b, ")")
		}
		generate_plain(&b, 2)
		text := random_text(pieces[:])
		pattern := strings.to_string(b)
		whether := search(pattern, text, whether = true)
		plain := search(pattern, text, linear = false)
		if plain.err != "" {
			// The backtracker gave up at its retry limit, where the visited set does not.
			plain = search(pattern, text)
		}
		built += int(whether.automaton)
		testing.expectf(
			t,
			whether.err == plain.err && (whether.lo >= 0) == (plain.lo >= 0),
			"%q on %q: %v whether, %v backtracking",
			pattern,
			text,
			whether,
			plain,
		)
	}
	testing.expectf(t, built > 2400, "%d of 4000 patterns have the automaton", built)
}

// Under jq's syntax the automaton answers the assertions at a text's edges and line breaks as Oniguruma does.
@(test)
test_jq_automaton_assertions :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		pattern, text: string,
		flags:         Mode,
		found:         bool,
	}
	lines :: Mode{multiline = true}
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
		testing.expectf(
			t,
			(whether.lo >= 0) == c.found && (with.lo >= 0) == c.found,
			"%q %v on %q: %v whether, %v with the set",
			c.pattern,
			c.flags,
			c.text,
			whether,
			with,
		)
	}
}

// Under jq's syntax and flags, on generated patterns and on texts of up to ten characters across words, lines and case,
// the automata find a match exactly where the backtracker does, with the same span and group 1 bounds.
@(test)
test_jq_automaton_keeps_the_answers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 5)
	built := 0
	pieces := [?]string{"a", "a", "A", "b", "k", "K", "\u212a", "é", "É", "ß", "s", "_", "1", " ", "\n", "-", "😀"}
	for _ in 0 ..< 4000 {
		b := strings.builder_make(context.temp_allocator)
		generate_jq(&b, 2)
		count := rand.int_max(11)
		flags := Mode{
			fold = rand.int_max(2) == 0,
			dotall = rand.int_max(2) == 0,
			extend = rand.int_max(2) == 0,
			multiline = rand.int_max(2) == 0,
		}
		text := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< count {
			strings.write_string(&text, pieces[rand.int_max(len(pieces))])
		}
		pattern := strings.to_string(b)
		whether := search(pattern, strings.to_string(text), flags = flags, whether = true)
		with := search(pattern, strings.to_string(text), flags = flags)
		plain := search(pattern, strings.to_string(text), linear = false, flags = flags)
		built += int(whether.automaton)
		testing.expectf(
			t,
			whether.err == plain.err && (whether.lo >= 0) == (plain.lo >= 0),
			"%q %v on %q: %v whether, %v backtracking",
			pattern,
			flags,
			strings.to_string(text),
			whether,
			plain,
		)
		with.spent, with.automaton, plain.spent = 0, false, 0
		testing.expectf(
			t,
			with == plain,
			"%q %v on %q: %v with the automata, %v backtracking",
			pattern,
			flags,
			strings.to_string(text),
			with,
			plain,
		)
	}
	testing.expectf(t, built > 1600, "%d of 4000 patterns have the automaton", built)
}

// A pattern that starts with one of a few bytes skips to them with the kernel's byte set scan: it finds a match, and
// refuses a text, as the backtracker does, wherever the first candidate falls among the blocks of the scan.
@(test)
test_ecma_set_prefilter_keeps_the_answers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	patterns := [?]string{`[xyz]b`, `(?:x|y|z)b`, `[é€]b`, `[\x00x]b`, `[^a-w]b`}
	candidates := [?]string{"x", "y", "é", "\x00", "z"}
	for pattern, p in patterns {
		for n in 0 ..< 300 {
			candidate := candidates[p]
			filler := strings.repeat("a", n, context.temp_allocator)
			texts := [?]string {
				strings.concatenate({filler, candidate, "b"}, context.temp_allocator),
				strings.concatenate({filler, candidate, "a", filler, candidate}, context.temp_allocator),
				strings.concatenate({candidate, candidate, filler, candidate, "b"}, context.temp_allocator),
				filler,
			}
			for text in texts {
				with := search(pattern, text, whether = true)
				without := search(pattern, text, linear = false, whether = true)
				testing.expectf(
					t,
					with.automaton && with.err == "" && (with.lo >= 0) == (without.lo >= 0),
					"%q on %d of %q: %v with the automaton, %v without",
					pattern,
					n,
					candidate,
					with,
					without,
				)
			}
		}
	}
}

// A search takes no caps, the match's own two, or two for every group, and a Scratch from `scratch_make`, which one
// search may use after another. A zero Scratch and caps of another length are refused with an `ensure`, which names
// `scratch_make` and the groups.
@(test)
test_search_takes_the_caps_it_documents :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	allocator := growing(&arena)
	re, message := compile(`(a)(?<n>b)?c`, {ecma = true}, allocator, allocator, spans = true)
	testing.expect_value(t, message, "")
	scratch := scratch_of(allocator)
	defer regex.scratch_destroy(&scratch)
	for _ in 0 ..< 2 {
		found, err := regex.search(&re, "xabc", 0, nil, &scratch)
		testing.expect_value(t, err, regex.Error{})
		testing.expect(t, found)
		own: [2]int
		found, err = regex.search(&re, "xabc", 0, own[:], &scratch)
		testing.expect(t, found && err == {})
		testing.expect_value(t, own, [2]int{1, 4})
		every: [6]int
		found, err = regex.search(&re, "xabc", 0, every[:], &scratch)
		testing.expect(t, found && err == {})
		testing.expect_value(t, every, [6]int{1, 4, 1, 2, 2, 3})
	}
}

// Over invalid UTF-8 a search steps over the bytes a lead byte claims, so a candidate inside them is not a start, at
// any distance from the search's start, whether the backtracker or the automaton answers. A search that reads bounds
// goes to the automaton only with the visited set off.
@(test)
test_head_skip_steps_over_the_bytes_a_lead_byte_claims :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Way :: struct {
		linear, whether: bool,
	}
	for gap in ([?]int{0, 1, 5, 7, 8, 9, 40, 200}) {
		filler := strings.repeat("a", gap, context.temp_allocator)
		claimed := strings.concatenate({filler, "\xE2xy"}, context.temp_allocator)
		then := strings.concatenate({claimed, "x"}, context.temp_allocator)
		clean := strings.concatenate({filler, "x"}, context.temp_allocator)
		for way in ([?]Way{{false, false}, {false, true}, {true, true}}) {
			// A search that reads no bounds gives 0 for a match.
			at_then, at_clean := 0 if way.whether else gap + 3, 0 if way.whether else gap
			found := search(`[xy]`, claimed, way.linear, Mode{}, way.whether)
			testing.expectf(t, found.err == "" && found.lo == -1, "gap %d, %v: %d, not none", gap, way, found.lo)
			found = search(`[xy]`, then, way.linear, Mode{}, way.whether)
			testing.expectf(
				t,
				found.err == "" && found.lo == at_then,
				"gap %d, %v: %d, not %d",
				gap,
				way,
				found.lo,
				at_then,
			)
			found = search(`[xy]`, clean, way.linear, Mode{}, way.whether)
			testing.expectf(
				t,
				found.err == "" && found.lo == at_clean,
				"gap %d, %v: %d, not %d",
				gap,
				way,
				found.lo,
				at_clean,
			)
		}
	}
}

// A search over text that is not valid UTF-8 gives the same answer with or without caps, with or without the automata,
// and the same span from the backtracker and from the automaton that finds spans.
@(test)
test_invalid_utf8_gives_one_answer_by_every_path :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 7)
	patterns := [?]string {
		`[xy]`,
		`x`,
		`xy`,
		`[a-c]+d`,
		`é|a`,
		`[^a]b`,
		`\d+`,
		`(?<=a)b`,
		`a|b`,
		`\p{L}`,
		`x*y`,
		`[xyé]z`,
		`(a|x)(y|b)`,
		`[\x80-\xff]a`,
		`.x`,
		`\Ax`,
		`y$`,
		`\bx`,
	}
	pieces := [?]string{
		"a",
		"b",
		"x",
		"y",
		"d",
		"z",
		"1",
		"é",
		"😀",
		"\xE2",
		"\xE2\x82",
		"\xF0\x9F",
		"\x80",
		"\xff",
		"\xC3",
	}
	for pattern in patterns {
		for mode in ([?]Mode{{}, {ecma = true}}) {
			for _ in 0 ..< testkit.rounds(300) {
				b := strings.builder_make(context.temp_allocator)
				for _ in 0 ..< rand.int_max(24) {
					strings.write_string(&b, pieces[rand.int_max(len(pieces))])
				}
				text := strings.to_string(b)
				// A long clean stretch makes the kernel's scan the one that looks.
				if rand.int_max(3) == 0 {
					text = strings.concatenate(
						{strings.repeat("a", 130, context.temp_allocator), text},
						context.temp_allocator,
					)
				}
				plain := search(pattern, text, false, mode, true)
				bounds := search(pattern, text, false, mode)
				automaton := search(pattern, text, true, mode, true)
				spans := search(pattern, text, true, mode)
				if plain.err != "" || bounds.err != "" || automaton.err != "" || spans.err != "" {
					continue
				}
				found := bounds.lo >= 0
				testing.expectf(
					t,
					(plain.lo >= 0) == found,
					"%q %v on %q: whether %v, bounds %v",
					pattern,
					mode,
					text,
					plain.lo >= 0,
					found,
				)
				testing.expectf(
					t,
					(automaton.lo >= 0) == found,
					"%q %v on %q: automaton %v, backtracker %v",
					pattern,
					mode,
					text,
					automaton.lo >= 0,
					found,
				)
				testing.expectf(
					t,
					spans.lo == bounds.lo && spans.hi == bounds.hi,
					"%q %v on %q: spans %d..%d, backtracker %d..%d",
					pattern,
					mode,
					text,
					spans.lo,
					spans.hi,
					bounds.lo,
					bounds.hi,
				)
			}
		}
	}
}

// `.Give_Back` and case-folded `backref` step single invalid UTF-8 bytes the same way `decode` does.
@(test)
test_invalid_utf8_give_back_and_folded_backref :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for text in ([?]string{"a\x80", "é\x80", "\xe2\x82"}) {
		for linear in ([?]bool{false, true}) {
			f := search(`^.*.$`, text, linear, {})
			testing.expectf(t, f.err == "" && f.lo == 0 && f.hi == len(text), "linear=%v on %q: %v", linear, text, f)
		}
	}
	same := search(`(?i)(.)\1`, "\x80\x80", false, {})
	testing.expectf(t, same.err == "" && same.lo == 0 && same.hi == 2, "folded backref same: %v", same)
	diff := search(`(?i)(.)\1`, "\x80\uFFFD", false, {})
	testing.expectf(t, diff.err == "" && diff.lo < 0, "folded backref diff: %v", diff)
}
