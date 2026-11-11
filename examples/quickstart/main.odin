// Validate a text, read it into a struct with `unmarshal`, and write it back with `marshal`.
//
// Run from the repository root: odin run examples/quickstart -collection:stury=.
// With a file argument it reads that file in place of the built-in text.
package main

import "stury:json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

Person :: struct {
	name: string,
	n:    i64,
}

// A fault or an error renders as `line:col: message`, with the path when it has one.
report :: proc(src: []u8, e: json.Error) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	json.render(strings.to_writer(&b), src, e)
	fmt.eprintln(strings.to_string(b))
}

main :: proc() {
	src := transmute([]byte)string(`{"name":"ada","n":1}`)
	if len(os.args) > 1 {
		data, rerr := os.read_entire_file(os.args[1], context.allocator)
		if rerr != nil {
			os.print_error(os.stderr, rerr, os.args[1])
			os.exit(1)
		}
		src = data
	}
	if err := run(src); err != nil {
		report(src, err)
		os.exit(1)
	}
}

run :: proc(src: []u8) -> json.Error {
	json.validate(src, .Json) or_return

	// What the read and the write allocate, freed at once.
	arena: virtual.Arena
	virtual.arena_init_growing(&arena) or_return
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	person: Person
	json.unmarshal(src, .Json, &person, allocator = alloc) or_return
	out := json.marshal(person, allocator = alloc) or_return
	fmt.println(string(out)) // {"name":"ada","n":1}
	return nil
}
