// Validate a text, read it into a struct with `unmarshal`, and write it back with `marshal`.
//
// Run from the repository root: odin run examples/quickstart -collection:stury=.
package main

import json "stury:json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"

Person :: struct {
	name: string,
	n:    i64,
}

main :: proc() {
	src := transmute([]byte)string(`{"name":"ada","n":1}`)
	if err, bad := json.validate(src).?; bad {
		fmt.eprintln(json.render_error(src, err))
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
	if uerr, bad := json.unmarshal(src, &person, allocator = alloc).?; bad {
		fmt.eprintln(json.render_error(src, uerr))
		os.exit(1)
	}
	out, merr := json.marshal(person, allocator = alloc)
	if e, bad := merr.?; bad {
		fmt.eprintln(json.render_error(nil, e))
		os.exit(1)
	}
	fmt.println(string(out)) // {"name":"ada","n":1}
}
