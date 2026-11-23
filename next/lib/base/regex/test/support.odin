package regex_tests

import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import regex "stury:lib/base/regex"

// Returns an allocator over a growing arena kept in `arena`. The arena is destroyed when the caller's scope ends.
@(deferred_in = virtual.arena_destroy)
growing :: proc(arena: ^virtual.Arena, loc := #caller_location) -> mem.Allocator {
	ensure(virtual.arena_init_growing(arena) == nil)
	return virtual.arena_allocator(arena)
}

// The result of `search`: the span of the first match and of group 1 (-1 for none), the error message and kind, the
// steps the search took, and whether the pattern has the automaton that answers a search reading no bounds.
Found :: struct {
	lo, hi, g1, g1_end: int,
	err:                string,
	kind:               regex.Error_Kind,
	spent:              int,
	automaton:          bool, // the pattern has the automaton that answers a search reading no bounds
}

// The syntax and flags of a test: `ecma` apart from the flags that a jq pattern takes.
Mode :: struct {
	using flags: regex.Flags,
	ecma:        bool,
}

split :: proc(m: Mode) -> (regex.Syntax, regex.Flags) {
	return .Ecma if m.ecma else .Oniguruma, m.flags
}

// `regex.compile` under `mode`, with Oniguruma's message for a refusal, "" for none.
compile :: proc(
	pattern: string,
	mode: Mode,
	allocator,
	scratch: mem.Allocator,
	automaton := true,
	spans := false,
) -> (re: regex.Regex, message: string) {
	syntax, flags := split(mode)
	compiled, err := regex.compile(pattern, syntax, flags, allocator, scratch, automaton, spans)
	return compiled, err.message
}

scratch_of :: proc(allocator: mem.Allocator) -> regex.Scratch {
	scratch, err := regex.scratch_make(allocator)
	ensure(err == regex.Error{})
	return scratch
}

sample :: proc(pattern: string, state: ^u64, extra, least: int, allocator: mem.Allocator) -> (text: string, ok: bool) {
	drawn, err := regex.sample(pattern, state, extra, least, allocator, allocator)
	return drawn, err == regex.Error{}
}

// Oniguruma's message for why `pattern` does not compile under `flags`, or "".
compile_message :: proc(pattern: string, flags: Mode) -> string {
	arena: virtual.Arena
	allocator := growing(&arena)
	_, err := compile(pattern, flags, allocator, allocator, automaton = false)
	return strings.clone(err, context.temp_allocator)
}

// Searches `text` for `pattern`. With `flags.ecma` the pattern is ECMA's, otherwise jq's. With `linear` false the
// automata and the visited set are off. With `whether` the search reads no bounds, and the span is 0..0 for a match.
search :: proc(pattern, text: string, linear := true, flags := Mode{ecma = true}, whether := false) -> (f: Found) {
	f = {-1, -1, -1, -1, "", .None, 0, false}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		f.err = "no memory"
		return
	}
	defer virtual.arena_destroy(&arena)
	re, err := compile(
		pattern,
		flags,
		virtual.arena_allocator(&arena),
		context.allocator,
		automaton = linear,
		spans = linear,
	)
	if err != "" {
		f.err = strings.clone(err, context.temp_allocator)
		return
	}
	re.linear &&= linear
	f.automaton = re.dfa != nil
	scratch := scratch_of(context.allocator)
	defer regex.scratch_destroy(&scratch)
	caps: [4]int
	found, search_err := regex.search(&re, text, 0, caps[:0 if whether else min(4, 2 * len(re.names))], &scratch)
	f.err, f.kind, f.spent = strings.clone(
		search_err.message,
		context.temp_allocator,
	), search_err.kind, int(scratch.spent)
	if found {
		f.lo, f.hi = caps[0], caps[1]
		if len(re.names) > 1 && !whether {
			f.g1, f.g1_end = caps[2], caps[3]
		}
	}
	return
}

// Returns a text of up to ten of `pieces` drawn from the test's generator. The last two pieces are used one time in
// eight and are replaced by `pieces[0]` otherwise.
random_text :: proc(pieces: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< rand.int_max(11) {
		k := rand.int_max(len(pieces))
		if k >= len(pieces) - 2 && rand.int_max(8) != 0 {
			k = 0
		}
		strings.write_string(&b, pieces[k])
	}
	return strings.to_string(b)
}

// Writes a pattern drawn from the test's generator with `depth` levels of nesting left.
Generator :: proc(b: ^strings.Builder, depth: int)

// Writes `open`, a pattern from `gen`, then with `alternatives` a `|` and a second pattern, then `)`.
nested :: proc(gen: Generator, b: ^strings.Builder, depth: int, open: string, alternatives := false) {
	strings.write_string(b, open)
	gen(b, depth - 1)
	if alternatives {
		strings.write_string(b, "|")
		gen(b, depth - 1)
	}
	strings.write_string(b, ")")
}

// Writes a pattern over `a` and `b` drawn from the test's generator.
generate :: proc(b: ^strings.Builder, depth: int) {
	for _ in 0 ..< 1 + rand.int_max(3) {
		repeatable := true
		k := rand.int_max(14)
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
			nested(generate, b, depth, "(")
		case k == 10:
			nested(generate, b, depth, "(?:", true)
		case:
			nested(generate, b, depth, "(?=" if k < 13 else "(?!")
			repeatable = false
		}
		if repeatable {
			quantifiers := [?]string{"", "", "", "*", "+", "?", "*?", "+?", "??", "{2}", "{1,3}", "{2,}", "{0,2}?"}
			strings.write_string(b, quantifiers[rand.int_max(len(quantifiers))])
		}
	}
}

// Writes a pattern drawn from the test's generator of the characters `a`, `b`, `é` and `😀`, classes, `^`, `$` and
// groups, which the automaton runs.
generate_plain :: proc(b: ^strings.Builder, depth: int) {
	for _ in 0 ..< 1 + rand.int_max(3) {
		atoms := [?]string{
			"a",
			"b",
			"é",
			"😀",
			".",
			"[^a]",
			"[a-cé]",
			"\\w",
			"\\d",
			"\\s",
			"\\p{L}",
			"\\P{Ll}",
			"[^\\p{Lu}b]",
			"ab",
			"aé",
		}
		k := rand.int_max(len(atoms) + 6)
		repeatable := true
		switch {
		case k < len(atoms):
			strings.write_string(b, atoms[k])
		case k == len(atoms):
			strings.write_string(b, "^" if rand.int_max(2) == 0 else "$")
			repeatable = false
		case depth == 0:
			strings.write_string(b, "a")
		case k < len(atoms) + 3:
			nested(generate_plain, b, depth, "(")
		case:
			nested(generate_plain, b, depth, "(?:", true)
		}
		if repeatable {
			quantifiers := [?]string{
				"",
				"",
				"",
				"*",
				"+",
				"?",
				"*?",
				"+?",
				"??",
				"{2}",
				"{1,3}",
				"{2,}",
				"{0,2}?",
				"{3}",
			}
			strings.write_string(b, quantifiers[rand.int_max(len(quantifiers))])
		}
	}
}

// Writes a jq pattern drawn from the test's generator, of the instructions and assertions the automaton runs and some
// it does not, such as `(?=a)`.
generate_jq :: proc(b: ^strings.Builder, depth: int) {
	for _ in 0 ..< 1 + rand.int_max(3) {
		atoms := [?]string{
			"a",
			"A",
			"b",
			"k",
			"é",
			"É",
			"ß",
			"_",
			" ",
			"1",
			".",
			"[a-c]",
			"[^a]",
			"[K\\d]",
			"\\w",
			"\\W",
			"\\d",
			"\\s",
			"\\p{L}",
			"[\\w-]",
			"\\b",
			"\\B",
			"^",
			"$",
			"\\A",
			"\\z",
			"\\Z",
			"\\n",
			"ab",
			"(?i:a)",
			"(?i:[k-m])",
			"(?i:é)",
			"(?=a)",
		}
		k := rand.int_max(len(atoms) + 4)
		switch {
		case k < len(atoms):
			strings.write_string(b, atoms[k])
		case depth == 0:
			strings.write_string(b, "a")
		case k < len(atoms) + 2:
			nested(generate_jq, b, depth, "(")
		case:
			nested(generate_jq, b, depth, "(?:", true)
		}
		quantifiers := [?]string{"", "", "", "*", "+", "?", "*?", "+?", "{2}", "{1,3}", "{2,}"}
		strings.write_string(b, quantifiers[rand.int_max(len(quantifiers))])
	}
}
