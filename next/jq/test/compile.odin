package jq_tests

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:jq"
import "stury:testkit"

// The message jq prints last for a program that does not compile: its last error's first line.
last_message :: proc(errors: []jq.Compile_Error) -> string {
	located := jq.locate(errors[len(errors) - 1])
	first, _, _ := strings.partition(located, "\n")
	return strings.concatenate({"jq: error: ", first})
}

// Why compiling case `c`'s program gave `errors` and not what jq gives, "" when it did: no error for a program that
// compiles, an error for one that must not, and jq's message where the case has one.
compile_mismatch :: proc(c: Case, errors: []jq.Compile_Error) -> string {
	switch {
	case c.fail == .None && len(errors) > 0:
		return last_message(errors)
	case c.fail != .None && len(errors) == 0:
		return "compiled"
	case c.fail == .Message && last_message(errors) != c.msg:
		return fmt.aprintf("%q, want %q", last_message(errors), c.msg)
	}
	return ""
}

// Every program of the corpus compiles, but those that must not, which fail with jq's message.
@(test)
corpus_programs_compile_as_jq_compiles_them :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	bad := 0
	ledger := read_divergences()
	for name in SUITES {
		cases := read_suite(name)
		testing.expect(t, len(cases) > 0, name)
		for c in cases {
			when DEBUG_CASES {
				fmt.eprintln(c.file, c.line)
			}
			prog, errors := jq.compile(c.prog, {modules = corpus_modules()})
			defer jq.destroy_program(prog)
			if why := compile_mismatch(c, errors); why != "" && fmt.aprintf("%s:%d", c.file, c.line) not_in ledger {
				bad += 1
				fmt.printfln("%s:%d %s: %s", c.file, c.line, c.prog, why)
			}
		}
	}
	testing.expect_value(t, bad, 0)
}

DEBUG_CASES :: #config(DEBUG_CASES, false)
