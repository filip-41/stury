// Read request bodies into a model, answer a refused one with a problem document, apply a patch with `patch`,
// and write the result with `dump`.
//
// Run from the repository root: odin run examples/model -collection:stury=.
package main

import "stury:core"
import model "stury:core/model"
import typed "stury:core/typed"
import "stury:json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"

User :: struct {
	id:    i64 `model:"read_only"`,
	name:  string `model:"len>=2"`,
	email: Maybe(string),
	role:  string `model:"optional"`,
	set:   model.Fields_Set,
}

main :: proc() {
	if err := run(); err != nil {
		fmt.eprintln(err)
		os.exit(1)
	}
}

run :: proc() -> core.Error {
	arena: virtual.Arena
	virtual.arena_init_growing(&arena) or_return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	reg: model.Registry
	model.register(&reg, User, "role", "member") or_return
	m := model.compile(&reg, User, json.checks(.Json)) or_return

	// Every refusal of a body, gathered by the sink, as one RFC 9457 document.
	bad: User
	sink: typed.Sink
	if model.load(&m, transmute([]u8)string(`{"name": "a", "email": 3}`), &bad, &sink) != nil {
		p := model.problem(sink.entries[:], "Invalid body", 422) or_return
		fmt.println(string(json.marshal(p) or_return))
	}

	user: User
	model.load(&m, transmute([]u8)string(`{"name": "ada", "email": "ada@example.org"}`), &user) or_return
	user.id = 1
	fmt.println(string(model.dump(&m, &user) or_return))

	// A patch changes only the members it holds, and the merged value is judged whole.
	model.patch(&m, &user, transmute([]u8)string(`{"email": null, "role": "admin"}`)) or_return
	fmt.println(string(model.dump(&m, &user, {exclude_none = true}) or_return))
	fmt.println(string(model.dump(&m, &user, {exclude_unset = true, exclude_defaults = true}) or_return))
	return nil
}
