package jq_tests

@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:strings"
import "core:testing"
import "stury:testkit"

// Runs the cases of the file `-define:PROBE=path`, in corpus form, printing each one's outputs: for looking at the
// evaluator by hand. Without the define it runs nothing.
PROBE :: #config(PROBE, "")

@(test)
probe_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
	when PROBE != "" {
		data, err := os.read_entire_file_from_path(PROBE, context.allocator)
		testing.expect(t, err == nil, PROBE)
		lines := strings.split(string(data), "\n")
		for i := 0; i + 1 < len(lines); i += 2 {
			if lines[i] == "" {
				i -= 1
				continue
			}
			c := Case{file = PROBE, line = i + 1, prog = lines[i], input = lines[i + 1], want = {"<probe>"}}
			fmt.eprintln("PROBE", c.prog)
			run_case(c, true)
		}
	}
}
