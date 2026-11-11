package json_tests

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"
import core "../../core"
import walktest "../../walktest"
import json ".."
import gen "gen"

same_error :: proc(a, b: core.Error) -> bool {
	return fmt.tprint(a) == fmt.tprint(b)
}

collect :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	append((^[dynamic]core.Token_Answer)(state), a)
	return true
}

// Takes every answer of `it` into `out`, and returns the error the read ended with.
drain :: proc(it: ^json.Answer_Iter, out: ^[dynamic]core.Token_Answer) -> core.Error {
	clear(out)
	for a in json.next(it) {
		append(out, a)
	}
	return it.err
}

// An iterator gives the answers `each_answer` gives and ends with its error, whatever its largest batch, over generated
// texts of the three specs, broken ones among them, with paths that answer at once, at a container's close and all at
// the text's end.
@(test)
answers_agree :: proc(t: ^testing.T) {
	_ = answers_agree_in(t, .Json) && answers_agree_in(t, .Jsonc) && answers_agree_in(t, .Json5)
}

answers_agree_in :: proc(t: ^testing.T, $S: json.Spec) -> bool {
	state := rand.create(11)
	context.random_generator = rand.default_random_generator(&state)
	texts := [?]string{".[]", ".[].a", ".a", "...a", "limit(2; ...b)", ".[1:]", ".[-1]", ".."}
	paths: [len(texts)]core.Path
	for text, i in texts {
		e: core.Error
		paths[i], e = core.parse_path(text)
		testing.expectf(t, e == nil, "%s: %v", text, e)
	}
	defer for &p in paths {
		core.path_destroy(&p)
	}
	want, got: [dynamic]core.Token_Answer
	defer delete(want)
	defer delete(got)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	fixed := []string{`{"b": [{"a": 1, "b": 2, "a": 3}, {"a": [4, {"b": 5}]}], "a": {"a": 6, "a": 7}}`, `[[1, 2, 3], [], [4, [5, 6]], 7, {"a": 8}]`}
	for round in 0 ..< 70 {
		clear(&text)
		if round < 60 {
			gen.text(&text, 1 + round % 6, S)
		} else if round < 68 {
			append(&text, fixed[round % 2])
		} else {
			// Enough answers for every batch size to fill several times over.
			append(&text, '[')
			for i in 0 ..< 300 {
				append(&text, `{"a": [1, 2], "b": 3}, ` if i % 3 == 0 else `{"b": {"a": 4}}, `)
			}
			append(&text, "0]")
		}
		src := text[:]
		if round % 2 == 1 {
			walktest.mutate(&broken, text[:], gen.SHARP)
			src = broken[:]
		}
		for path, i in paths {
			read := core.Path_Options{dups = .First if round % 3 == 0 else .Last}
			clear(&want)
			err := json.each_answer(src, S, path, &want, collect, read = read)
			for batch in ([]int{1, 3, 64}) {
				it := json.answers(src, S, path, read = read)
				it.max_batch = batch
				got_err := drain(&it, &got)
				ok := testing.expectf(t, slice.equal(got[:], want[:]), "%v %q %s batch %d: %d answers, want %d", S, src, texts[i], batch, len(got), len(want))
				ok &&= testing.expectf(t, same_error(got_err, err), "%v %q %s batch %d: %v, want %v", S, src, texts[i], batch, got_err, err)
				if !ok {
					return false
				}
			}
		}
	}
	return true
}

// A fault after three answers comes after them, in `err` once the loop ends.
@(test)
answers_fault_after_three :: proc(t: ^testing.T) {
	src := transmute([]u8)string("[1, 2, 3, x]")
	path, _ := core.parse_path(".[]")
	defer core.path_destroy(&path)
	it := json.answers(src, .Json, path)
	got: [dynamic]core.Token_Answer
	defer delete(got)
	err := drain(&it, &got)
	testing.expect_value(t, len(got), 3)
	testing.expectf(t, err != nil && same_error(err, json.each_answer(src, .Json, path, nil, proc(_: rawptr, _: core.Token_Answer) -> bool {return true})),"%v", err)
}

// Under `.Refuse` a repeated key faults before any answer, and the text is read with the caller's options: a depth past
// `MAX_DEPTH` and a tolerated lone surrogate give the answers `each_answer` gives.
@(test)
answers_refuse :: proc(t: ^testing.T) {
	read := core.Path_Options{dups = .Refuse}
	path, _ := core.parse_path("...a")
	defer core.path_destroy(&path)
	got, want: [dynamic]core.Token_Answer
	defer delete(got)
	defer delete(want)

	repeated := transmute([]u8)string(`[{"a": 1}, {"a": 2, "a": 3}]`)
	it := json.answers(repeated, .Json, path, read = read)
	err := drain(&it, &got)
	testing.expectf(t, len(got) == 0 && err != nil, "%d answers, %v", len(got), err)

	deep: [dynamic]u8
	defer delete(deep)
	for _ in 0 ..< 1500 {
		append(&deep, `{"a": 1, "b": `)
	}
	append(&deep, `"\ud800"`)
	for _ in 0 ..< 1500 {
		append(&deep, '}')
	}
	opts := json.Options{max_depth = 2048, tolerate = {.Lone_Surrogate}}
	want_err := json.each_answer(deep[:], .Json, path, &want, collect, opts, read)
	testing.expectf(t, want_err == nil && len(want) > 1500, "each_answer: %d answers, %v", len(want), want_err)
	it = json.answers(deep[:], .Json, path, opts, read)
	err = drain(&it, &got)
	testing.expectf(t, slice.equal(got[:], want[:]) && err == nil, "%d answers, want %d: %v", len(got), len(want), err)
}

// A loop that ends after the first answer leaves the text past it unjudged, as `stop_early` with a limit of one does,
// and `destroy` frees the read.
@(test)
answers_break_early :: proc(t: ^testing.T) {
	cases := [][2]string{{"[1, x]", ".[]"}, {"[[1], x]", ".[][]"}, {`{"a": 1, x`, ".a"}, {`[{"a": 1}, x`, ".[].a"}}
	for c in cases {
		src := transmute([]u8)c[0]
		path, _ := core.parse_path(c[1])
		defer core.path_destroy(&path)
		read := core.Path_Options{dups = .First}
		first: core.Token_Answer
		it := json.answers(src, .Json, path, read = read)
		for a in json.next(&it) {
			first = a
			break
		}
		testing.expectf(t, it.err == nil && first.outcome == .Found, "%s %s: %v %v", c[0], c[1], first, it.err)
		json.destroy(&it)
		seen := 0
		early := core.Path_Options{dups = .First, stop_early = true}
		one := path
		one.limit = 1
		err := json.each_answer(src, .Json, one, &seen, proc(state: rawptr, _: core.Token_Answer) -> bool {
			(^int)(state)^ += 1
			return true
		}, read = early)
		testing.expectf(t, err == nil && seen == 1, "%s %s with stop_early: %d %v", c[0], c[1], seen, err)
	}
}
