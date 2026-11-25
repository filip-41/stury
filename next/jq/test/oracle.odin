package jq_tests

import "base:runtime"
import "core:encoding/hex"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:jq"
import "stury:lib/query"
import "stury:testkit"

// The runner half of `tools/jq_oracle.py`: reads the file named by the environment variable STURY_ORACLE_IN, one case
// per line as the program's hex, a space and the input's hex, runs each and writes to STURY_ORACLE_OUT one line per
// case of tokens, each a letter, a colon and hex: `o` an output as compact JSON, `e` the error that ended the run, `c`
// the message of a program that does not compile, `i` an input this reader refuses, `h` a halt, `l` the bytes the run
// did not give back. Without the variable it runs nothing.

ORACLE_STEPS :: 5_000_000
ORACLE_MEMORY :: 3 << 30 // a case that wants more ends with an out of memory error

@(test)
oracle_cases :: proc(t: ^testing.T) {
	testkit.deadline(t)
	in_path, found := os.lookup_env("STURY_ORACLE_IN", context.allocator)
	if !found {
		return
	}
	out_path, _ := os.lookup_env("STURY_ORACLE_OUT", context.allocator)
	data, err := os.read_entire_file_from_path(in_path, context.allocator)
	testing.expect(t, err == nil, in_path)
	out := strings.builder_make(runtime.heap_allocator())
	for line in strings.split_lines(string(data)) {
		if line == "" {
			continue
		}
		prog, _, input := strings.partition(line, " ")
		arena: virtual.Arena
		testing.expect(t, suite_arena(&arena) == nil)
		context.allocator = virtual.arena_allocator(&arena)
		started := time.tick_now()
		oracle_case(&out, unhex(prog), unhex(input))
		if took := time.tick_since(started); took > 2 * time.Second {
			fmt.eprintfln("oracle: %v for %s", took, unhex(prog))
		}
		virtual.arena_destroy(&arena)
		strings.write_byte(&out, '\n')
	}
	testing.expect(t, os.write_entire_file(out_path, out.buf[:]) == nil, out_path)
}

unhex :: proc(s: string) -> string {
	b, _ := hex.decode(transmute([]u8)s)
	return string(b)
}

token :: proc(out: ^strings.Builder, kind: u8, text: string) {
	strings.write_byte(out, kind)
	strings.write_byte(out, ':')
	for b in transmute([]u8)text {
		fmt.sbprintf(out, "%02x", b)
	}
	strings.write_byte(out, ' ')
}

oracle_case :: proc(out: ^strings.Builder, text, input_text: string) {
	prog, errors := jq.compile(text, {modules = corpus_modules()})
	defer jq.destroy_program(prog)
	if len(errors) > 0 {
		token(out, 'c', last_message(errors))
		return
	}
	h: query.Heap
	query.heap_init(&h, runtime.heap_allocator(), ORACLE_MEMORY)
	defer query.heap_destroy(&h)
	input, ok := read_value(&h, input_text)
	if !ok {
		token(out, 'i', input_text)
		return
	}
	run: jq.Run
	calls := 0
	hooks := jq.Hooks{data = &calls, now = fixed_now, random = counted_bytes, parse_json = parse_json_hook}
	jq.run_init(&run, prog, &h, nil, &hooks, ORACLE_STEPS)
	outs := Outputs{h = &h}
	end := jq.run_value(&run, input, collect, &outs)
	for v in outs.vals {
		token(out, 'o', show(&h, v))
		query.release(&h, v)
	}
	#partial switch end {
	case .Failed:
		e := query.take_error(&h)
		token(out, 'e', jq.error_message(&h, &e))
		query.destroy_error(&h, &e)
	case .Halted:
		token(out, 'h', "")
	}
	jq.run_destroy(&run)
	if live := query.heap_live(&h); live != 0 {
		token(out, 'l', fmt.aprint(live))
	}
}
