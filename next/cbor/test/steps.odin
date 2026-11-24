package cbor_tests

import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// The budget of steps, which counts containers.

// `Budget.steps` counts the containers a build, scan or find opens, those it passes included, and refuses one past it.
@(test)
reads_keep_the_steps_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("a3 61 61 82 a1 61 62 01 a1 61 62 02 61 63 a1 61 64 81 03 61 65 04")
	CONTAINERS :: 6
	path := []tape.Step{tape.Name("e")}
	paths := [][]tape.Step{path}
	for steps in u64(1) ..= CONTAINERS + 1 {
		opts := cbor.Options{budget = {steps = steps}}
		over := steps < CONTAINERS
		verr := cbor.validate(src, .Cbor, opts)
		_, berr := cbor.build(src, .Cbor, opts, context.temp_allocator)
		_, ferr := cbor.find(src, path, .Cbor, {}, opts)
		demand, _ := tape.demand_of(paths, allocator = context.temp_allocator)
		_, serr := cbor.scan(src, &demand, .Cbor, {}, opts, context.temp_allocator)
		for err in ([?]tape.Error{verr, berr, ferr, serr}) {
			e, exceeded := err.(tape.Exceeded)
			testing.expectf(t, exceeded == over && (!over || e.kind == .Steps), "steps %d: %v", steps, err)
		}
	}
}
