package json_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
import json ".."

// `build_entries` against `core.build` of the same text wrapped in its arrays: the same refusals, and of a text both
// accept, the same nodes, each `levels` bytes before its place in the wrapped text but the wrapping arrays'.

@(private = "file")
expect_as_wrapped :: proc(t: ^testing.T, text: string, levels: int, loc := #caller_location) -> bool {
	wrapped := strings.concatenate({strings.repeat("[", levels, context.temp_allocator), text, strings.repeat("]", levels, context.temp_allocator)}, context.temp_allocator)
	want, want_err := core.build(transmute([]u8)wrapped, json.as(.Json), allocator = context.temp_allocator)
	got, got_err := json.build_entries(transmute([]u8)text, levels, json.as(.Json), context.temp_allocator)
	if !testing.expectf(t, (want_err == nil) == (got_err == nil), "%q in %d arrays: wrapped refused %v, in place refused %v", text, levels, want_err != nil, got_err != nil, loc = loc) {
		return false
	}
	if want_err != nil {
		return true
	}
	if !testing.expectf(t, len(want.nodes) == len(got.nodes), "%q in %d arrays: %d nodes, in place %d", text, levels, len(want.nodes), len(got.nodes), loc = loc) {
		return false
	}
	for x, i in want.nodes {
		y := got.nodes[i]
		lo := u64(0) if i < levels else y.lo + u64(levels)
		if !testing.expectf(t, x.kind == y.kind && x.role == y.role && x.n == y.n && x.spelling == y.spelling && (i < levels || x.lo == lo), "%q in %d arrays: node %d is %v, in place %v", text, levels, i, x, y, loc = loc) {
			return false
		}
	}
	return testing.expectf(t, got.root_close == u64(len(text)), "%q in %d arrays: root close %d", text, levels, got.root_close, loc = loc)
}

// Texts of entries and texts that are none: values cut at the end, commas at either end or doubled, brackets that close
// a wrapping array, whitespace alone, and faults inside strings and numbers.
@(private = "file", rodata)
ENTRY_TEXTS := []string{
	``, `  `, "\n", `1`, `1,2,3`, ` 1 , 2 `, "1,\n  [\"s\", 2],\n  {}\n", `"a","b"`, `{"a":1},{"b":[1,2,{"c":null}]}`,
	`[],{},[[]],{"a":{}}`, `true,false,null`, `"é\n\"x\"",-0.5e+3`, `""`, `1],[2`, `1,`, `1,,2`, `,1`, `1 2`, `[1`,
	`1]`, `1]]`, `{"a":1`, `{"a"}`, `01`, `"a\qb"`, `tru`, `nul`, `fals`, `1e`, `-`, `"ab`, `1,]`, `]`, `[1,2],`,
	`{"a":1},{"a":1,}`, "\"a\x01b\"", `[[[[]]]`, "\"\xc3\x28\",1",
}

@(test)
build_entries_reads_as_the_wrapped_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for text in ENTRY_TEXTS {
		for levels in 1 ..= 3 {
			if !expect_as_wrapped(t, text, levels) {
				return
			}
		}
	}
}

@(test)
build_entries_reads_edited_texts_as_the_wrapped_text :: proc(t: ^testing.T) {
	seeds := []string{
		`{"ts":"2026-10-03T04:03:24.502Z","level":"info","n":[1,2.5,-3e2],"ok":true},{"x":null}`,
		`"aéb",[[],{}],12,-0.5`,
		`{"k":{"k":{"k":[1,"\n"]}}},false`,
		"1,\n  [\"s\", 2],\n  {}",
	}
	// The bytes JSON's grammar turns on, and a bad UTF-8 pair and a control byte.
	alphabet := "[]{},:\"\\ \n\t0123456789-.eE+truefalsnu\xc3\x28\x01"
	state := rand.create(1)
	gen := rand.default_random_generator(&state)
	text := make([dynamic]u8)
	defer delete(text)
	for iter in 0 ..< 20_000 {
		clear(&text)
		append(&text, seeds[iter % len(seeds)])
		for _ in 0 ..= rand.int_max(3, gen) {
			at := rand.int_max(len(text) + 1, gen)
			c := alphabet[rand.int_max(len(alphabet), gen)]
			switch rand.int_max(3, gen) {
			case 0:
				inject_at(&text, at, c)
			case 1:
				if at < len(text) {
					ordered_remove(&text, at)
				}
			case:
				if at < len(text) {
					text[at] = c
				}
			}
		}
		ok := expect_as_wrapped(t, string(text[:]), 1 + rand.int_max(3, gen))
		free_all(context.temp_allocator)
		if !ok {
			return
		}
	}
}

@(test)
build_entries_refuses_another_spec_and_no_arrays :: proc(t: ^testing.T) {
	_, err := json.build_entries(transmute([]u8)string(`1`), 1, json.as(.Jsonc))
	e, is_doc := err.(core.Document_Error)
	testing.expect(t, is_doc && e.kind == .Bad_Spec)
	_, err = json.build_entries(transmute([]u8)string(`1`), 0, json.as(.Json))
	e, is_doc = err.(core.Document_Error)
	testing.expect(t, is_doc && e.kind == .Walk && e.inner.kind == .Too_Deep)
}
