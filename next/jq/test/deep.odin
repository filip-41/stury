#+build darwin, linux, freebsd, openbsd, netbsd
package jq_tests

import "core:strings"
import "core:testing"
import "stury:jq"
import "stury:lib/query"
import "stury:testkit"

// Programs nested 100,000 levels deep, each shape the grammar nests by, compiled on a thread of one MiB.
DEEP :: 100_000

deep_program :: proc(shape: int) -> string {
	b := strings.builder_make()
	switch shape {
	case 0:
		for _ in 0 ..< DEEP {
			strings.write_byte(&b, '[')
		}
		strings.write_byte(&b, '.')
		for _ in 0 ..< DEEP {
			strings.write_byte(&b, ']')
		}
	case 1:
		strings.write_byte(&b, '.')
		for _ in 0 ..< DEEP {
			strings.write_string(&b, " + 1")
		}
	case 2:
		for _ in 0 ..< DEEP {
			strings.write_string(&b, ".a")
		}
	case 3:
		for _ in 0 ..< DEEP {
			strings.write_string(&b, "if . then ")
		}
		strings.write_byte(&b, '.')
		for _ in 0 ..< DEEP {
			strings.write_string(&b, " end")
		}
	case 4:
		for i in 0 ..< DEEP {
			strings.write_string(&b, ". as $x | ")
			if i % 2 == 0 {
				strings.write_string(&b, "$x | ")
			}
		}
		strings.write_byte(&b, '.')
	case 5:
		for _ in 0 ..< DEEP {
			strings.write_string(&b, "def f: ")
		}
		strings.write_byte(&b, '.')
		for _ in 0 ..< DEEP {
			strings.write_string(&b, "; f")
		}
	case 6:
		for _ in 0 ..< DEEP {
			strings.write_string(&b, "{a: ")
		}
		strings.write_byte(&b, '.')
		for _ in 0 ..< DEEP {
			strings.write_byte(&b, '}')
		}
	}
	return strings.to_string(b)
}

DEEP_SHAPES :: 7

@(test)
programs_nest_100000_levels_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.expect_reads_on_thread(t, 1 << 20, DEEP_SHAPES, nil, "program", proc(shape: int, _: []u8) -> bool {
		src := deep_program(shape)
		defer delete(src)
		prog, errors := jq.compile(src, {max_depth = 8 * DEEP})
		defer jq.destroy_program(prog)
		return len(errors) == 0
	})
}

// Programs over values 100,000 levels deep, and recursion as deep, each with its one output, on a thread of one MiB.
// The heap's depth budget is lifted past them, so every operation goes all the way down. None makes a path to each
// level, which would take memory square in the depth.
@(rodata)
DEEP_RUNS := [?][2]string {
	{"reduce range(100000) as $_ ([]; [.]) | [..] | length", "100001"},
	{"reduce range(100000) as $_ ([]; [.]) | tojson | length", "200002"},
	{"(reduce range(100000) as $_ ([]; [.])) as $x | (reduce range(100000) as $_ ([]; [.])) as $y | [$x == $y, $x < $y, ([$x, $y] | unique | length)]", "[true,false,1]"},
	{"(reduce range(100000) as $_ ({}; {a: .})) as $x | (reduce range(100000) as $_ ({}; {a: .})) as $y | $x * $y | [..] | length", "100001"},
	{"reduce range(100000) as $_ ([]; [.]) | contains(.)", "true"},
	{"reduce range(100000) as $_ ([]; [.]) | flatten", "[]"},
	{"[reduce range(100000) as $_ (0; [.]) | .. | numbers]", "[0]"},
	{"[range(100000) | 0] as $p | null | setpath($p; 1) | getpath($p)", "1"},
	{"[range(100000) | 0] as $p | null | setpath($p; 1) | delpaths([$p]) | [..] | length", "100000"},
	{"reduce range(100000) as $_ ([]; [.]) | walk(.) | [..] | length", "100001"},
	{"reduce range(100000) as $_ ([]; [.]) | [.] | group_by(.) | length", "1"},
	{"def f: if . == 0 then 0 else (. - 1 | f) + 1 end; 100000 | f", "100000"},
	{"[limit(100000; repeat(1))] | length", "100000"},
}

@(test)
runs_go_100000_levels_deep_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testkit.expect_reads_on_thread(t, 1 << 20, len(DEEP_RUNS), nil, "run", proc(i: int, _: []u8) -> bool {
		prog, errors := jq.compile(DEEP_RUNS[i][0])
		defer jq.destroy_program(prog)
		if len(errors) > 0 {
			return false
		}
		h: query.Heap
		query.heap_init(&h, context.allocator, depth = 1 << 20)
		defer query.heap_destroy(&h)
		run: jq.Run
		jq.run_init(&run, prog, &h, nil)
		outs := Outputs{h = &h}
		end := jq.run_value(&run, query.NULL, collect, &outs)
		jq.run_destroy(&run)
		ok := end == .Done && len(outs.vals) == 1
		if ok {
			got := show(&h, outs.vals[0])
			defer delete(got)
			ok = got == DEEP_RUNS[i][1]
		}
		for v in outs.vals {
			query.release(&h, v)
		}
		delete(outs.vals)
		query.clear_error(&h)
		return ok && query.heap_live(&h) == 0
	})
}
