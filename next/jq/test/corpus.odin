package jq_tests

import "core:mem/virtual"
import "core:os"
import "core:strings"

// jq 1.8.2's own test files, read the way jq's run-tests reads them: blank and `#` lines between tests, `%%FAIL [IGNORE
// MSG]` before a program that must not compile (then its message, then lines up to a blank one), otherwise the program,
// one input line and the expected outputs up to a blank or `#` line. A last line `%%ERROR message` says the run ends
// with that error.

CASES_DIR :: "jq/test/cases"

@(private)
ERROR_LINE :: "%%ERROR "

// The files of cases, in the order they run.
SUITES :: [?]string{"jq.test", "onig.test", "ported.test"}

// The suite whose cases must end as they say: jq's own files list outputs only, and may end in an error after them.
STRICT_SUITE :: "ported.test"

Case :: struct {
	file:  string,
	line:  int,
	prog:  string,
	fail:  Fail,
	msg:   string, // a failing case's message
	err:   string, // the message of the error that ends the run, "" for none
	input: string,
	want:  []string,
}

Fail :: enum u8 {
	None,
	Message, // must fail with `msg`
	Any, // must fail, with any message
}

// An arena for a test's cases and what it makes of them, all freed at once.
suite_arena :: proc(a: ^virtual.Arena) -> virtual.Allocator_Error {
	return virtual.arena_init_growing(a)
}

read_suite :: proc(name: string) -> []Case {
	data, err := os.read_entire_file_from_path(strings.concatenate({CASES_DIR, "/", name}), context.allocator)
	if err != nil {
		return nil
	}
	lines := strings.split(string(data), "\n")
	skip :: proc(s: string) -> bool {
		t := strings.trim_left(s, " \t")
		return t == "" || strings.has_prefix(t, "#")
	}
	cases := make([dynamic]Case)
	fail := Fail.None
	for i := 0; i < len(lines); {
		line := lines[i]
		i += 1
		if skip(line) {
			continue
		}
		if line == "%%FAIL" || line == "%%FAIL IGNORE MSG" {
			fail = .Any if strings.has_suffix(line, "MSG") else .Message
			continue
		}
		c := Case{file = name, line = i, prog = line, fail = fail}
		if fail != .None {
			c.msg = lines[i] if i < len(lines) else ""
			for i < len(lines) && lines[i] != "" {
				i += 1
			}
		} else {
			c.input = lines[i] if i < len(lines) else ""
			i += 1
			want := make([dynamic]string)
			for i < len(lines) && !skip(lines[i]) {
				if strings.has_prefix(lines[i], ERROR_LINE) {
					c.err = lines[i][len(ERROR_LINE):]
				} else {
					append(&want, lines[i])
				}
				i += 1
			}
			c.want = want[:]
		}
		fail = .None
		append(&cases, c)
	}
	return cases[:]
}
