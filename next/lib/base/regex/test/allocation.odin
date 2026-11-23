package regex_tests

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import regex "stury:lib/base/regex"
import "stury:testkit"

// An allocator that fails the `fail_at`th allocation through it, and every later one when `sticky`. `fail_at` 0 never
// fails. `count` is the allocations asked so far.
Failing :: struct {
	inner:   mem.Allocator,
	fail_at: int,
	sticky:  bool,
	count:   int,
}

failing_allocator :: proc(f: ^Failing) -> mem.Allocator {
	return {procedure = failing_proc, data = f}
}

failing_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size,
	alignment: int,
	old_ptr: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	f := (^Failing)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		f.count += 1
		if f.fail_at != 0 && (f.count == f.fail_at || f.sticky && f.count > f.fail_at) {
			return nil, .Out_Of_Memory
		}
	}
	return f.inner.procedure(f.inner.data, mode, size, alignment, old_ptr, old_size, loc)
}

// A pattern, the syntax it is read under, and a text to search that makes the search grow its scratch.
Subject :: struct {
	pattern: string,
	mode:    Mode,
	text:    string,
}

subjects :: proc() -> [dynamic]Subject {
	rows := make([dynamic]Subject, context.temp_allocator)
	letters := strings.repeat("ab", 200, context.temp_allocator)
	append(&rows, Subject{`(a|b)*c\1`, {}, strings.concatenate({letters, "cb"}, context.temp_allocator)})
	append(
		&rows,
		Subject{
			`(?<x>[a-c]+)(?=d)(?:é|😀)?`,
			{ecma = true},
			strings.concatenate({letters, "d"}, context.temp_allocator),
		},
	)
	append(&rows, Subject{`^(?:a{1,9}){1,9}$`, {ecma = true}, strings.repeat("a", 60, context.temp_allocator)})
	append(
		&rows,
		Subject{
			`(?i)\p{L}+\d{2,3}(?:x|yy)*\X`,
			{fold = true},
			strings.concatenate({letters, "12x"}, context.temp_allocator),
		},
	)
	append(&rows, Subject{`^(a|a)*b`, {ecma = true}, strings.concatenate({letters[:100], "b"}, context.temp_allocator)})
	append(&rows, Subject{`(?<=a)b|(?<n>c)\k<n>*`, {}, letters})
	append(&rows, Subject{`(a+?)(b*+)(?!c)\w{2,50}?x`, {}, strings.concatenate({letters, "x"}, context.temp_allocator)})
	append(
		&rows,
		Subject{`(?:a|b)+?c(?=(d))(?<=b)`, {ecma = true}, strings.concatenate({letters, "cd"}, context.temp_allocator)},
	)
	append(&rows, Subject{`(a*)*(?>b|ab)+(?:c|\1)`, {}, strings.concatenate({letters, "bc"}, context.temp_allocator)})
	return rows
}

// Whichever allocation of a compile fails, it comes back as a memory error or as a program that answers as the one that
// no allocation failed for, and nothing crashes.
@(test)
test_compile_survives_a_failing_allocator :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for subject in subjects() {
		syntax, flags := split(subject.mode)
		for spans in ([?]bool{false, true}) {
			// The allocations of a compile that does not fail, which are those of the result and those of the scratch.
			counted: [2]Failing
			for &c in counted {
				c.inner = context.allocator
			}
			arena, scratch_arena: virtual.Arena
			ok_re, ok_err := regex.compile(
				subject.pattern,
				syntax,
				flags,
				failing_over(&counted[0], &arena),
				failing_over(&counted[1], &scratch_arena),
				spans = spans,
			)
			testing.expectf(t, ok_err == {}, "%q: %v", subject.pattern, ok_err)
			baseline := run_search(&ok_re, subject.text)
			for side in 0 ..< 2 {
				for sticky in ([?]bool{false, true}) {
					for at in 1 ..= counted[side].count {
						fails: [2]Failing
						for &f in fails {
							f.inner = context.allocator
						}
						fails[side].fail_at, fails[side].sticky = at, sticky
						a, b: virtual.Arena
						re, err := regex.compile(
							subject.pattern,
							syntax,
							flags,
							failing_over(&fails[0], &a),
							failing_over(&fails[1], &b),
							spans = spans,
						)
						if err.kind == .None {
							testing.expectf(
								t,
								run_search(&re, subject.text) == baseline,
								"%q, allocation %d of %d failed, answers differ",
								subject.pattern,
								at,
								side,
							)
						} else {
							testing.expectf(
								t,
								err.kind == .Memory,
								"%q, allocation %d of %d failed: %v",
								subject.pattern,
								at,
								side,
								err,
							)
						}
						virtual.arena_destroy(&a)
						virtual.arena_destroy(&b)
					}
				}
			}
			virtual.arena_destroy(&arena)
			virtual.arena_destroy(&scratch_arena)
		}
	}
}

// An allocator that counts and fails through `f`, over a growing arena kept in `arena`, which the caller destroys.
failing_over :: proc(f: ^Failing, arena: ^virtual.Arena) -> mem.Allocator {
	ensure(virtual.arena_init_growing(arena) == nil)
	f.inner = virtual.arena_allocator(arena)
	return failing_allocator(f)
}

Answer :: struct {
	found: bool,
	caps:  [8]int,
	err:   regex.Error,
}

run_search :: proc(re: ^regex.Regex, text: string) -> (answer: Answer) {
	scratch := scratch_of(context.allocator)
	defer regex.scratch_destroy(&scratch)
	n := min(len(answer.caps), 2 * len(regex.group_names(re)))
	answer.found, answer.err = regex.search(re, text, 0, answer.caps[:n], &scratch)
	return
}

// Whichever allocation of a search fails, it answers as it would not have or says it ran out of memory.
@(test)
test_search_survives_a_failing_allocator :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for subject in subjects() {
		syntax, flags := split(subject.mode)
		arena: virtual.Arena
		allocator := growing(&arena)
		re, err := regex.compile(subject.pattern, syntax, flags, allocator, allocator)
		testing.expect_value(t, err, regex.Error{})
		baseline := run_search(&re, subject.text)
		counted := Failing{inner = allocator}
		counting, make_err := regex.scratch_make(failing_allocator(&counted))
		testing.expect_value(t, make_err, regex.Error{})
		for _ in 0 ..< 2 {
			answer: Answer
			n := min(len(answer.caps), 2 * len(regex.group_names(&re)))
			_, _ = regex.search(&re, subject.text, 0, answer.caps[:n], &counting)
		}
		regex.scratch_destroy(&counting)
		for caps in ([?]bool{true, false}) {
			for sticky in ([?]bool{false, true}) {
				for at in 1 ..= counted.count {
					fail := Failing{inner = allocator, fail_at = at, sticky = sticky}
					scratch, scratch_err := regex.scratch_make(failing_allocator(&fail))
					if scratch_err.kind != .None {
						testing.expect_value(t, scratch_err.kind, regex.Error_Kind.Memory)
						continue
					}
					answer: Answer
					n := min(len(answer.caps), 2 * len(regex.group_names(&re)))
					answer.found, answer.err = regex.search(
						&re,
						subject.text,
						0,
						answer.caps[:n if caps else 0],
						&scratch,
					)
					regex.scratch_destroy(&scratch)
					if answer.err.kind == .None {
						if caps {
							testing.expectf(
								t,
								answer == baseline,
								"%q, allocation %d failed, answers differ",
								subject.pattern,
								at,
							)
						} else {
							testing.expectf(
								t,
								answer.found == baseline.found,
								"%q, allocation %d failed, answers differ",
								subject.pattern,
								at,
							)
						}
					} else {
						testing.expectf(
							t,
							answer.err.kind == .Memory,
							"%q, allocation %d failed: %v",
							subject.pattern,
							at,
							answer.err,
						)
					}
				}
			}
		}
		virtual.arena_destroy(&arena)
	}
}

// A pattern of many classes compiles in time that grows with their number, not with its square.
@(test)
test_many_classes_compile_in_linear_time :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	allocator := growing(&arena)
	pattern := strings.repeat("[ab]", 100_000, context.temp_allocator)
	re, message := compile(pattern, {ecma = true}, allocator, allocator)
	testing.expect_value(t, message, "")
	testing.expect_value(t, len(re.classes), 100_000)
}

// Every allocation comes from an allocator the caller passed: the ambient ones panic.
@(test)
test_regex_allocates_only_from_the_callers_allocators :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	allocator := growing(&arena)
	scratch_arena: virtual.Arena
	scratch_allocator := growing(&scratch_arena)
	context.allocator, context.temp_allocator = mem.panic_allocator(), mem.panic_allocator()
	scratch := scratch_of(allocator)
	defer regex.scratch_destroy(&scratch)
	state := u64(3)
	patterns := [?]struct {
		pattern: string,
		mode:    Mode,
	}{
		{`(a|b)*c\1`, {}},
		{`(?<x>[a-c]+)(?=d)`, {ecma = true}},
		{`(?:ab){3,40}\p{L}\X`, {}},
		{`^(?:a{1,9}){1,9}$`, {ecma = true}},
	}
	for c in patterns {
		syntax, flags := split(c.mode)
		testing.expect_value(t, regex.refusal(c.pattern, syntax, flags, allocator, scratch_allocator), regex.Error{})
		re, err := regex.compile(c.pattern, syntax, flags, allocator, scratch_allocator, spans = true)
		testing.expect_value(t, err, regex.Error{})
		caps := make([]int, 2 * len(regex.group_names(&re)), allocator)
		for text in ([?]string{"abacb", "abababababababababc", "dddd"}) {
			_, _ = regex.search(&re, text, 0, caps, &scratch)
			_, _ = regex.search(&re, text, 0, nil, &scratch)
		}
	}
	_, err := regex.sample(`[a-c]{2}x+`, &state, 3, 5, allocator, scratch_allocator)
	testing.expect_value(t, err, regex.Error{})
}
