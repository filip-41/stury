package yaml_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:yaml"

@(private = "file")
walk_of :: proc($S: yaml.Spec) -> testkit.Probe_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
		at, err, _ := yaml.walk(src, S, opts, h, regs, testkit.probe_hook)
		return at, err
	}
}

@(private = "file")
bare_walk_of :: proc($S: yaml.Spec) -> testkit.Bare_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe_Bare, regs: ^hook.Regs) -> (u64, tape.Error) {
		at, err, _ := yaml.walk(src, S, opts, h, regs, testkit.bare_hook)
		return at, err
	}
}

@(private = "file")
PROTOCOL_TEXTS := [?]string {
	"a: 1\n",
	"",
	"# only a comment\n",
	"a: [1, [2, 3], {b: 'x'}] # after\nc: {d: {e: true}}\n",
	"# head\n\n# above\na:\n  - 1 # one\n  - |\n    line1\n    line2\n  # foot\n",
	"defs: &d\n  k: 1\nhost: &h\n  <<: *d\n  extra: [1, *d]\n",
	"%YAML 1.2\n%TAG !e! tag:example.com,2000:\n---\na: !e!x 5\n...\n",
}

@(test)
yaml_walks_keep_the_hook_protocol :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.hook_protocol(t, walk_of(.Yaml_1_2), PROTOCOL_TEXTS[:])
	testkit.hook_protocol(t, walk_of(.Yaml_Merge), PROTOCOL_TEXTS[:])
	testkit.hook_inner_rooms(t, bare_walk_of(.Yaml_1_2), PROTOCOL_TEXTS[:])
}

@(test)
yaml_walk_cancels_through_a_flag :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 200 {
		fmt.sbprintf(&b, "- k%d: [1, 2, 3]\n", i)
	}
	testkit.hook_cancel(t, walk_of(.Yaml_1_2), strings.to_string(b), 300)
}

@(private = "file")
check_single_doc_refusal :: proc(t: ^testing.T, data: []u8, name: string, a: ^testkit.Agreement) -> bool {
	doc, berr := yaml.build(data, .Yaml_1_2)
	yaml.destroy(&doc)
	if !faults_with(berr, .Extra_Document) && !faults_with(berr, .No_Document) && !faults_with(berr, .Complex_Key) {
		return false
	}
	a.refused += 1
	for dups in ([2]tape.Duplicates{.Last, .First}) {
		_, ferr := yaml.find(data, {yaml.Name("a")}, .Yaml_1_2, {}, {dups = dups})
		testing.expectf(t, testkit.same_refusal(ferr, berr), "%s: find disagrees with build: got %v, want %v", name, ferr, berr)
	}
	_, ferr := yaml.find(data, {}, .Yaml_1_2)
	testing.expectf(t, testkit.same_refusal(ferr, berr), "%s: root find disagrees with build: got %v, want %v", name, ferr, berr)
	d, _ := yaml.demand_of({{yaml.Name("a")}})
	defer yaml.destroy(&d)
	r, serr := yaml.scan(data, &d, .Yaml_1_2)
	yaml.destroy(&r)
	testing.expectf(t, testkit.same_refusal(serr, berr), "%s: scan disagrees with build: got %v, want %v", name, serr, berr)
	return true
}

// `readers_agree` law across single-document yaml-test-suite cases (and error cases).
@(test)
reads_agree_on_the_conformance_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
	list := load_suite_cases(context.allocator)
	defer free_suite_cases(list, context.allocator)
	a: testkit.Agreement
	defer delete(a.shapes)
	checked := 0
	for c in list {
		data, ok := read_suite_file(c.dir, "in.yaml", context.allocator)
		if !ok {
			continue
		}
		defer delete(data)
		// Multi-document streams, comment-only streams, and complex-key documents either pass `validate` or hit
		// a later syntax error in `validate`, while single-document readers (`build`, `find`, `scan`) must agree
		// on refusing them with `.Extra_Document`, `.No_Document`, or `.Complex_Key`.
		checked += 1
		if check_single_doc_refusal(t, data, c.name, &a) {
			free_all(context.temp_allocator)
			continue
		}
		testkit.readers_agree(t, yaml.reads(.Yaml_1_2), yaml.as(.Yaml_1_2), data, {}, c.name, &a)
		free_all(context.temp_allocator)
	}
	testing.expect(t, checked > 340)
	testkit.expect_agreement(t, &a, {texts = 250, refused = 50, scans = 5000, on_path = 5000, shapes = 20})
}

@(private = "file")
random_yaml :: proc() -> string {
	b := strings.builder_make()
	n := 1 + rand.int_max(6)
	put_val :: proc(b: ^strings.Builder, depth: int) {
		switch rand.int_max(11 if depth > 0 else 7) {
		case 0:
			strings.write_string(b, rand.choice([]string{"~", "null", "true", "False"}))
		case 1:
			strings.write_string(b, rand.choice([]string{"0", "42", "-7", "0x1f", "0o17", "+5", ".5", "1.5e2", "-.inf"}))
		case 2:
			strings.write_string(b, rand.choice([]string{`"s"`, `'a''b'`, `plain`, `yes`, `"a\nb"`}))
		case 3:
			strings.write_string(b, "!!str 123")
		case 4, 5, 6:
			strings.write_string(b, rand.choice([]string{"x", "y", "01", "foo bar"}))
		case 7, 8:
			strings.write_byte(b, '[')
			cnt := rand.int_max(4)
			for i in 0 ..< cnt {
				if i > 0 {
					strings.write_string(b, ", ")
				}
				put_val(b, depth - 1)
			}
			strings.write_byte(b, ']')
		case:
			strings.write_byte(b, '{')
			cnt := rand.int_max(3)
			for i in 0 ..< cnt {
				if i > 0 {
					strings.write_string(b, ", ")
				}
				strings.write_string(b, rand.choice([]string{"a", "b", "c", "1", `"1"`}))
				strings.write_string(b, ": ")
				put_val(b, depth - 1)
			}
			strings.write_byte(b, '}')
		}
	}
	for i in 0 ..< n {
		if i == 0 && rand.int_max(4) == 0 {
			strings.write_string(&b, "# head\n")
		}
		strings.write_string(&b, rand.choice([]string{"a", "b", "c", "d", "k"}))
		strings.write_string(&b, ": ")
		put_val(&b, 3)
		if rand.int_max(4) == 0 {
			strings.write_string(&b, " # inline")
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(test)
reads_agree_on_generated_and_mutated_texts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a: testkit.Agreement
	defer delete(a.shapes)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x7A31)
	for _ in 0 ..< testkit.rounds(50) {
		text := random_yaml()
		defer delete(text)
		src := transmute([]u8)text
		for spec in yaml.Spec {
			testkit.readers_agree(t, yaml.reads(spec), yaml.as(spec), src, {}, "generated", &a)
		}
		for _ in 0 ..< 2 {
			bad := testkit.mutate(src, "[]:-\"'\n,{}#*&!a1")
			if !check_single_doc_refusal(t, bad, "mutated", &a) {
				testkit.readers_agree(t, yaml.reads(.Yaml_1_2), yaml.as(.Yaml_1_2), bad, {}, "mutated", &a)
			}
		}
		free_all(context.temp_allocator)
	}
	testkit.expect_agreement(t, &a, {texts = 40, refused = 15, scans = 5000, on_path = 5000, shapes = 15})
}

@(test)
pieces_and_records_laws :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	paths := [][]yaml.Step {
		{},
		{yaml.Name("a")},
		{yaml.Name("t"), yaml.Name("b")},
		{yaml.Name("l"), yaml.Index(0)},
		{yaml.Name("l"), yaml.Index(-1)},
		{yaml.All{}},
		{yaml.Name("host"), yaml.Name("b")},
	}
	texts := [?]string {
		"a: 1\n",
		"# c\na: 1\n---\nb: 2\n...\n",
		"t:\n  b: [1, 2]\nl:\n  - &x {p: 1}\n  - *x\n",
		"a: |\n  line1\n  line2\n---\nb: >-\n  folded\n",
		"%TAG !e! tag:example.com,2000:\n---\n!e!x a: 1\n",
		"defs: &d {b: 7}\nhost:\n  <<: *d\n  a: 1\n",
		"a: 1\na: 2\n",
		"a: [1, 2\nb: 3\n",
	}
	options := []yaml.Options{{}, {budget = {steps = 3}}, {budget = {depth = 2}}}
	for text in texts {
		for spec in yaml.Spec {
			for opts in options {
				if !testkit.agree_in_pieces(t, yaml.reads(spec), yaml.as(spec), transmute([]u8)text, opts, paths, text, containers = true) {
					return
				}
			}
		}
	}

	// `find_agrees_with_member` & `records_at_agree` on single-document texts; `records_alone_agree` on all streams.
	for i in ([?]int{0, 2, 4, 5}) {
		src := transmute([]u8)texts[i]
		testkit.find_agrees_with_member(t, yaml.reads(.Yaml_1_2), yaml.as(.Yaml_1_2), src, {"a", "t", "l", "b", "host"}, texts[i])
		testkit.records_at_agree(t, yaml.reads(.Yaml_1_2), yaml.as(.Yaml_1_2), src, {}, texts[i])
	}
	for text in texts[:6] {
		src := transmute([]u8)text
		alone := testkit.Alone{framing = .Concatenated}
		run := testkit.Piece_Run{src, yaml.reads(.Yaml_1_2), yaml.as(.Yaml_1_2), {}, testkit.cuts_by(len(src), 7)}
		testkit.records_alone_agree(t, run, alone, paths[:5], text)
	}
}

@(test)
multidoc_streaming_pieces_bounded_memory_and_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Multi-document YAML stream containing `---` and `...` INSIDE block scalars and quoted strings,
	// plus real column-0 `---` / `...` boundaries, directives, anchors/aliases, and comments.
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 30 {
		if i == 0 || (i % 3 == 0 && (i - 1) % 2 == 0) {
			strings.write_string(&b, "%YAML 1.2\n---\n")
		} else if i > 0 {
			strings.write_string(&b, "---\n")
		}
		fmt.sbprintf(&b, "id: &id_%d %d\nref: *id_%d\nblk: |\n  ---\n  ...\n  inside block %d\nq: \"line1\\n---\\n...\\nline2\"\n", i, i, i, i)
		if i % 2 == 0 {
			strings.write_string(&b, "...\n# between docs\n")
		}
	}
	full := transmute([]u8)strings.to_string(b)
	testing.expect_value(t, yaml.validate(full), nil)

	// Stream across small windows, dropping bytes before `p.keep`, and assert bounded memory (`max_win < len(full) / 4`)!
	for step in ([?]int{19, 37, 113}) {
		p := tape.Pieces{allocator = context.allocator}
		defer yaml.destroy(&p)
		max_win := 0
		keep_advances := 0
		prev_keep := u64(0)
		end := 0
		for {
			start := int(p.keep)
			next_end := min(end + step, len(full))
			p.from = p.keep
			p.last = next_end == len(full)
			end = next_end
			win := full[start:end]
			if len(win) > max_win { max_win = len(win) }
			err := yaml.validate(win, .Yaml_1_2, {pieces = &p})
			testing.expect_value(t, err, nil)
			if p.keep > prev_keep {
				keep_advances += 1
				prev_keep = p.keep
			}
			if !p.more || p.last { break }
		}
		testing.expect(t, !p.more)
		testing.expectf(t, keep_advances >= 20, "step=%d: expected p.keep to advance across docs, got %d advances", step, keep_advances)
		testing.expectf(t, max_win < len(full) / 4, "step=%d: expected bounded window (< %d), got %d", step, len(full) / 4, max_win)
	}

	// Verify exact fault parity on a multi-doc stream whose 15th document has a syntax error.
	bad_b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 20 {
		if i > 0 { strings.write_string(&bad_b, "---\n") }
		if i == 15 {
			strings.write_string(&bad_b, "bad: [1, 2\n")
		} else {
			fmt.sbprintf(&bad_b, "ok: %d\n...\n", i)
		}
	}
	bad_full := transmute([]u8)strings.to_string(bad_b)
	want_bad := yaml.validate(bad_full)
	testing.expect(t, want_bad != nil)
	{
		p := tape.Pieces{allocator = context.allocator}
		defer yaml.destroy(&p)
		got_bad: tape.Error
		end := 0
		for {
			start := int(p.keep)
			next_end := min(end + 23, len(bad_full))
			p.from = p.keep
			p.last = next_end == len(bad_full)
			end = next_end
			got_bad = yaml.validate(bad_full[start:end], .Yaml_1_2, {pieces = &p})
			if got_bad != nil || !p.more || p.last { break }
		}
		testing.expect_value(t, got_bad, want_bad)
	}

	// Single-doc `find` & `scan` with explicit `...` + long trailing comments releases doc 1 bytes (`p.keep` advances!).
	tail_b := strings.builder_make(context.temp_allocator)
	strings.write_string(&tail_b, "target: 42\nother: [1, 2, 3]\n...\n")
	for i in 0 ..< 40 {
		fmt.sbprintf(&tail_b, "# trailing comment line %d with padding text\n", i)
	}
	tail_full := transmute([]u8)strings.to_string(tail_b)
	{
		p := tape.Pieces{allocator = context.allocator}
		defer yaml.destroy(&p)
		max_win := 0
		end := 0
		ans: tape.Span_Answer
		err: tape.Error
		for {
			start := int(p.keep)
			next_end := min(end + 31, len(tail_full))
			p.from = p.keep
			p.last = next_end == len(tail_full)
			end = next_end
			win := tail_full[start:end]
			if len(win) > max_win { max_win = len(win) }
			ans, err = yaml.find(win, {yaml.Name("target")}, .Yaml_1_2, {}, {pieces = &p})
			if err != nil || !p.more || p.last { break }
		}
		testing.expect_value(t, err, nil)
		testing.expect_value(t, ans.outcome, yaml.Presence.Found)
		testing.expect_value(t, string(p.text), "42")
		testing.expectf(t, max_win < len(tail_full) / 4, "single-doc tail find expected bounded window, got %d / %d", max_win, len(tail_full))
	}

	// Exhaustive byte-cut parity via `agree_in_pieces` on tricky boundary-inside-scalar multi-doc texts.
	tricky := [?]string {
		"a: |\n  ---\n  ...\n...\n# tail\n",
		"a: \"---\\n...\"\n---\nb: 2\n...\n",
		"a: 1\n...\n---\nb: 2\n...\n---\nc: 3\n",
	}
	paths := [][]yaml.Step{{}, {yaml.Name("a")}, {yaml.Name("b")}}
	for txt in tricky {
		testing.expect(t, testkit.agree_in_pieces(t, yaml.reads(.Yaml_1_2), yaml.as(.Yaml_1_2), transmute([]u8)txt, {}, paths, txt, containers = true))
		testing.expect(t, testkit.agree_in_pieces(t, yaml.reads(.Yaml_1_2), yaml.as(.Yaml_1_2), transmute([]u8)txt, {budget = {steps = 2}}, paths, txt, containers = true))
	}
}
