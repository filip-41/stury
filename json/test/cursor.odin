package json_tests

import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import walktest "../../walktest"
import json ".."
import gen "gen"

// A hook that logs every token into `tokens` and stops the walk at every `every`th.
Stopping :: struct {
	tokens: []core.Token,
	n:      int,
	every:  int,
}

stopping_hook :: proc "contextless" (h: ^Stopping, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	h.tokens[h.n] = t
	h.n += 1
	if h.n % h.every == 0 {
		return {s.a + 1, s.b, s.c}, .Stop
	}
	return {s.a + 1, s.b, s.c}, .Next
}

// Walks `src` with a stop at every `every`th token, resuming each time, and checks that the tokens, the end and the
// fault are those of an unbroken walk.
resumed_agrees :: proc(t: ^testing.T, src: []u8, $S: json.Spec, opts: json.Options, every: int, full: ^walktest.Log) -> bool {
	full^ = {}
	hi, fault := json.walk(src, 0, S, opts, full, nil, walktest.log_hook)
	h := Stopping{every = every}
	h.tokens = make([]core.Token, full.n + 1)
	defer delete(h.tokens)
	stack := make([]u8, 2048)
	defer delete(stack)
	cursor := json.Cursor{stack = stack}
	regs: core.Hook_Regs
	hi2, fault2 := json.walk(src, 0, S, opts, &h, &regs, stopping_hook, &cursor)
	stops := 0
	for json.can_resume(&cursor) {
		stops += 1
		hi2, fault2 = json.walk_resume(src, &cursor, S, opts, &h, &regs, stopping_hook)
	}
	ok := testing.expectf(t, slice.equal(h.tokens[:h.n], full.tokens[:full.n]), "%v every %d: %d tokens, want %d", S, every, h.n, full.n)
	ok &&= testing.expectf(t, hi2 == hi && fault2 == fault, "%v %q every %d: %d %v, want %d %v", S, src[:min(len(src), 80)], every, hi2, fault2, hi, fault)
	ok &&= testing.expectf(t, regs.a == u64(h.n), "%v every %d: registers %d after %d tokens", S, every, regs.a, h.n)
	ok &&= testing.expectf(t, stops >= h.n / every - 1, "%v every %d: %d stops", S, every, stops)
	return ok
}

// A walk stopped at every token and resumed each time gives the tokens of an unbroken walk, for generated texts of the
// three specs, broken ones among them, and texts with comment runs before keys, colons, values and closes and past the
// root.
@(test)
cursor_resumes :: proc(t: ^testing.T) {
	_ = cursor_resumes_in(t, .Json) && cursor_resumes_in(t, .Jsonc) && cursor_resumes_in(t, .Json5)
}

cursor_resumes_in :: proc(t: ^testing.T, $S: json.Spec) -> bool {
	state := rand.create(7)
	context.random_generator = rand.default_random_generator(&state)
	full := new(walktest.Log)
	defer free(full)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	for round in 0 ..< 60 {
		clear(&text)
		if round % 3 == 2 {
			gen.pretty(&text, 1 + round % 6, S)
		} else {
			gen.text(&text, 1 + round % 6, S)
		}
		src := text[:]
		if round % 2 == 1 {
			walktest.mutate(&broken, text[:], gen.SHARP)
			src = broken[:]
		}
		for every in ([]int{1, 2, 5}) {
			if !resumed_agrees(t, src, S, {}, every, full) {
				return false
			}
		}
	}
	when S != .Json {
		runs := []string{
			"// head\n{ /* a */ \"k\" /* b */ : /* c */ 1 /* d */, // e\n \"m\": [ /* f */ ] /* g */, /* h */ \"n\" // i\n /* j */ } // foot\n/* tail */",
			"[1, /* a */ /* b */\n /* c */ 2 /* d */ /* e */\n /* f */ ] /* g */ /* h */\n/* next */ 3",
			"{\"a\" /* x */ /* y */ : 1}",
			"[1 /* x */ /* y */ , 2]",
			"/* x */ /* y */ 1 /* z */ /* w */",
		}
		for run in runs {
			for every in ([]int{1, 2, 3}) {
				if !resumed_agrees(t, transmute([]u8)run, S, {}, every, full) {
					return false
				}
			}
		}
	}
	return true
}

// A text nesting past `MAX_DEPTH` resumes on the stack the caller gave, at every token, and a cursor's stack bounds
// the depth.
@(test)
cursor_resumes_deep :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 1500 {
		strings.write_string(&b, "{\"k\":[" if i % 2 == 0 else "[")
	}
	strings.write_string(&b, "1")
	for i := 1499; i >= 0; i -= 1 {
		strings.write_string(&b, "]}" if i % 2 == 0 else "]")
	}
	src := transmute([]u8)strings.to_string(b)
	full := new(walktest.Log)
	defer free(full)
	if !resumed_agrees(t, src, .Json, {max_depth = 2048}, 1, full) || !resumed_agrees(t, src, .Jsonc, {max_depth = 2048}, 7, full) {
		return
	}
	h := Stopping{every = 1 << 30}
	h.tokens = make([]core.Token, full.n + 1)
	defer delete(h.tokens)
	small: [1024]u8
	cursor := json.Cursor{stack = small[:]}
	_, fault := json.walk(src, 0, .Json, {max_depth = 2048}, &h, nil, stopping_hook, &cursor)
	f, faulted := fault.?
	testing.expectf(t, faulted && f.kind == .Too_Deep && f.at == 2392, "a cursor's stack of 1024 levels: %v", fault)
}

// A cursor resumes only the text its walk read, and only once per stop.
@(test)
cursor_refuses :: proc(t: ^testing.T) {
	src := transmute([]u8)string("[1, 2, 3]")
	copied := slice.clone(src)
	defer delete(copied)
	h := Stopping{every = 2}
	h.tokens = make([]core.Token, 8)
	defer delete(h.tokens)
	stack: [8]u8
	cursor := json.Cursor{stack = stack[:]}
	json.walk(src, 0, .Json, {}, &h, nil, stopping_hook, &cursor)
	testing.expect(t, json.can_resume(&cursor))
	_, fault := json.walk_resume(copied, &cursor, .Json, {}, &h, nil, stopping_hook)
	f, faulted := fault.?
	testing.expectf(t, faulted && f.kind == .Bad_Option, "another text: %v", fault)
	_, fault = json.walk_resume(src[:len(src) - 1], &cursor, .Json, {}, &h, nil, stopping_hook)
	f, faulted = fault.?
	testing.expectf(t, faulted && f.kind == .Bad_Option, "a cut text: %v", fault)
	_, fault = json.walk_resume(src, &cursor, .Json, {}, &h, nil, stopping_hook)
	testing.expectf(t, fault == nil && h.n == 4, "resumed: %v after %d tokens", fault, h.n)
	none := json.Cursor{stack = stack[:]}
	_, fault = json.walk_resume(src, &none, .Json, {}, &h, nil, stopping_hook)
	f, faulted = fault.?
	testing.expectf(t, faulted && f.kind == .Bad_Option, "no stop: %v", fault)
}
