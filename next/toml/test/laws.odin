// The read laws of `testkit` over the toml-test cases, random texts and their mutations: the walk keeps the hook
// protocol, the readers answer a scan's partial document as the build, and every read refuses a text the build refuses.
package toml_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

@(private = "file")
walk_of :: proc($S: toml.Spec) -> testkit.Probe_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
		at, err, _ := toml.walk(src, S, opts, h, regs, testkit.probe_hook)
		return at, err
	}
}

@(private = "file")
bare_walk_of :: proc($S: toml.Spec) -> testkit.Bare_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe_Bare, regs: ^hook.Regs) -> (u64, tape.Error) {
		at, err, _ := toml.walk(src, S, opts, h, regs, testkit.bare_hook)
		return at, err
	}
}

// Texts of every kind of value and container, tables written apart, arrays of tables and comments of each role.
@(private = "file")
PROTOCOL_TEXTS := [?]string {
	"a = 1\n",
	"",
	"# only a comment\n",
	"a = [1, [2, 3], {b = 'x'}] # after\nc = {d = {e = true}}\n",
	"[a.b]\nx = 1\n[a]\ny = 2\n[a.b.c]\nz = 3\n",
	"[[l]]\nn = 1\n[l.sub]\ns = 'a'\n[[l]]\nn = 2\n[[l.k]]\n",
	"a.b.c = 1\na.d = 2\n[t]\ne.f = \"\"\"\nx\"\"\"\n",
	"# head\n\n# above\na = [ # open\n  1, # one\n  # last\n]\n[t] # header\n# foot\n",
	"a = {}\nb = []\n[c]\n[d.e]\n",
}

@(test)
toml_walks_keep_the_hook_protocol :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// The protocol frees the temporary allocator after each text, so the texts are in the context's allocator.
	texts := make([]string, len(PROTOCOL_TEXTS))
	defer {
		for text in texts {
			delete(text)
		}
		delete(texts)
	}
	for text, i in PROTOCOL_TEXTS {
		texts[i] = strings.clone(text)
	}
	testkit.hook_protocol(t, walk_of(.Toml_1_0), texts)
	testkit.hook_protocol(t, walk_of(.Toml_1_1), texts)
	testkit.hook_inner_rooms(t, bare_walk_of(.Toml_1_0), texts)
}

// A hook stops a walk from another thread through a flag.
@(test)
toml_walk_cancels_through_a_flag :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 200 {
		strings.write_string(&b, "[[l]]\nn = 1\n")
	}
	testkit.hook_cancel(t, walk_of(.Toml_1_0), strings.to_string(b), 300)
}

// The readers law and the refusal law over every case of the toml-test lists, and the verdict each list gives a case: a
// valid case reads and an invalid one is refused.
@(test)
reads_agree_on_the_conformance_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
	lists := [toml.Spec]string {
		.Toml_1_0 = LIST_1_0,
		.Toml_1_1 = LIST_1_1,
	}
	counts := [toml.Spec]int{}
	a: testkit.Agreement
	defer delete(a.shapes)
	for list, spec in lists {
		rest := list
		for name in strings.split_lines_iterator(&rest) {
			if !strings.has_suffix(name, ".toml") {
				continue
			}
			data, found := case_data(name)
			if !testing.expectf(t, found, "%s is not vendored", name) {
				continue
			}
			counts[spec] += 1
			// A case is read from a copy, so its bytes past the text are no constant data.
			src := make([]u8, len(data))
			defer delete(src)
			copy(src, data)
			err := toml.validate(src, spec)
			if strings.has_prefix(name, "valid/") {
				testing.expectf(t, err == nil, "%s %v: %v", name, spec, err)
			} else {
				testing.expectf(t, err != nil, "%s %v: read", name, spec)
			}
			testkit.readers_agree(t, toml.reads(spec), toml.as(spec), src, {}, name, &a)
		}
	}
	testing.expect_value(t, counts[.Toml_1_0], 717)
	testing.expect_value(t, counts[.Toml_1_1], 720)
	testkit.expect_agreement(t, &a, {texts = 400, refused = 1000, scans = 1_000_000, on_path = 100_000, shapes = 30})
}

// Appends a random key: bare, quoted or literal, from few enough names that tables often meet one another.
@(private = "file")
put_key :: proc(b: ^strings.Builder) {
	name := rand.choice([]string{"a", "b", "c", "d"})
	switch rand.int_max(6) {
	case 0:
		strings.write_string(b, `"`)
		strings.write_string(b, name)
		strings.write_string(b, `"`)
	case 1:
		strings.write_string(b, "'")
		strings.write_string(b, name)
		strings.write_string(b, "'")
	case 2:
		strings.write_string(b, name)
		strings.write_byte(b, '.')
		strings.write_string(b, rand.choice([]string{"a", "b", "c"}))
	case:
		strings.write_string(b, name)
	}
}

// Appends a random value of at most `depth` levels.
@(private = "file")
put_value :: proc(b: ^strings.Builder, depth: int) {
	pick := rand.int_max(14 if depth > 0 else 10)
	switch pick {
	case 0:
		strings.write_string(b, rand.choice([]string{"1", "-7", "0x1F", "0o7", "0b10", "1_000", "+3"}))
	case 1:
		strings.write_string(b, rand.choice([]string{"1.5", "-2e3", "inf", "-nan", "6.0e-1"}))
	case 2:
		strings.write_string(b, rand.choice([]string{`"x"`, `"a\tbé"`, `""`}))
	case 3:
		strings.write_string(b, rand.choice([]string{"'lit'", "''", "'''\nm\n'''", "\"\"\"\nq\\\n  r\"\"\""}))
	case 4:
		strings.write_string(b, rand.choice([]string{"true", "false"}))
	case 5:
		strings.write_string(b, rand.choice([]string{"1979-05-27T07:32:00Z", "1979-05-27", "07:32:00", "1979-05-27 07:32:00.5"}))
	case 6 ..< 10:
		strings.write_string(b, `"s"`)
	case 10, 11:
		strings.write_byte(b, '[')
		n := rand.int_max(4)
		for i in 0 ..< n {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			if rand.int_max(5) == 0 {
				strings.write_string(b, "# c\n")
			}
			put_value(b, depth - 1)
		}
		strings.write_byte(b, ']')
	case:
		strings.write_byte(b, '{')
		n := rand.int_max(3)
		for i in 0 ..< n {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			put_key(b)
			strings.write_string(b, " = ")
			put_value(b, depth - 1)
		}
		strings.write_byte(b, '}')
	}
}

// A random text of a few statements: keys and values, headers and arrays of tables, and comments.
@(private)
random_text :: proc() -> string {
	b := strings.builder_make()
	for _ in 0 ..< 2 + rand.int_max(8) {
		switch rand.int_max(8) {
		case 0:
			strings.write_byte(&b, '[')
			put_key(&b)
			strings.write_string(&b, "]")
		case 1:
			strings.write_string(&b, "[[")
			put_key(&b)
			strings.write_string(&b, "]]")
		case 2:
			strings.write_string(&b, "# note")
		case:
			put_key(&b)
			strings.write_string(&b, " = ")
			put_value(&b, 3)
			if rand.int_max(4) == 0 {
				strings.write_string(&b, " # inline")
			}
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// `src` with a byte changed, a byte left out, or cut short, in the context's allocator.
@(private)
mutated :: proc(src: string) -> []u8 {
	b := make([dynamic]u8, len(src))
	copy(b[:], src)
	if len(src) == 0 {
		return b[:]
	}
	at := rand.int_max(len(src))
	switch rand.int_max(3) {
	case 0:
		b[at] = rand.choice([]u8{'[', ']', '=', '.', '"', '\'', '\n', ',', '{', '}', '#', 'a', '1'})
	case 1:
		ordered_remove(&b, at)
	case:
		resize(&b, at)
	}
	return b[:]
}

// The readers law and the refusal law over random texts, as each spec reads them, and their mutations.
@(test)
reads_agree_on_generated_texts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a: testkit.Agreement
	defer delete(a.shapes)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x7031)
	for _ in 0 ..< testkit.rounds(60) {
		text := random_text()
		defer delete(text)
		src := transmute([]u8)text
		for spec in toml.Spec {
			testkit.readers_agree(t, toml.reads(spec), toml.as(spec), src, {}, "generated", &a)
		}
		for _ in 0 ..< 3 {
			bad := mutated(text)
			defer delete(bad)
			testkit.readers_agree(t, toml.reads(.Toml_1_1), toml.as(.Toml_1_1), bad, {}, "mutated", &a)
		}
	}
	testkit.expect_agreement(t, &a, {texts = 60, refused = 30, scans = 10_000, on_path = 10_000, shapes = 20})
}

// `Budget.steps` counts the containers a build, scan or find gives, those it passes included, and refuses one past it.
@(test)
reads_keep_the_steps_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a = [1, {b = 2}]\n[t]\nc = {}\n[[l]]\n")
	CONTAINERS :: 7
	for steps in 1 ..= CONTAINERS + 1 {
		opts := toml.Options{budget = {steps = u64(steps)}}
		want := toml.validate(src, opts = opts)
		x, over := want.(tape.Exceeded)
		testing.expectf(t, (steps < CONTAINERS) == (over && x.kind == .Steps), "%d steps: %v", steps, want)
		doc, err := toml.build(src, opts = opts)
		toml.destroy(&doc)
		testing.expectf(t, testkit.same_refusal(err, want), "%d steps: build %v, validate %v", steps, err, want)
		_, ferr := toml.find(src, {tape.Name("t"), tape.Name("c")}, opts = opts)
		testing.expectf(t, testkit.same_refusal(ferr, want), "%d steps: find %v, validate %v", steps, ferr, want)
	}
}
