// Validate a text, read it into a struct with `unmarshal`, and write it back with `marshal`.
//
// Run from the repository root: odin run examples/quickstart -collection:stury=.
package main

import "stury:core"
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
report :: proc(src: []u8, e: $E) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	core.render(strings.to_writer(&b), src, e)
	fmt.eprintln(strings.to_string(b))
}

main :: proc() {
	src := transmute([]byte)string(`{"name":"ada","n":1}`)
	if fault, bad := json.validate(src, .Json).?; bad {
		report(src, fault)
		os.exit(1)
	}

	// What the read and the write allocate, freed at once.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		os.exit(1)
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	person: Person
	if err := json.unmarshal(src, .Json, &person, allocator = alloc); err.kind != .None {
		report(src, err)
		os.exit(1)
	}
	out, err := json.marshal(person, allocator = alloc)
	if err.kind != .None {
		report(nil, err)
		os.exit(1)
	}
	fmt.println(string(out)) // {"name":"ada","n":1}
}
