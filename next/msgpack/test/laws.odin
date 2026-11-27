package msgpack_tests

import "core:math/rand"
import "core:testing"
import "stury:msgpack"
import "stury:testkit"

// The read and record laws of `testkit` across random MessagePack items, specs, and mutations.

@(test)
reads_agree_on_generated_items :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a: testkit.Agreement
	defer delete(a.shapes)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x99a0)
	for _ in 0 ..< testkit.rounds(40) {
		src := random_item()
		defer delete(src)
		for spec in msgpack.Spec {
			testkit.readers_agree(t, msgpack.reads(spec), msgpack.as(spec), src, {}, "generated", &a)
		}
		for _ in 0 ..< 4 {
			bad := testkit.mutate(src)
			testkit.readers_agree(t, msgpack.reads(.Msgpack), msgpack.as(.Msgpack), bad, {}, "mutated", &a)
		}
		free_all(context.temp_allocator)
	}
	testkit.expect_agreement(t, &a, {texts = 60, refused = 60, scans = 10_000, on_path = 10_000, shapes = 20})
}

@(test)
records_at_a_path_agree_with_the_build :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x99a1)
	read := 0
	for _ in 0 ..< testkit.rounds(40) {
		src := random_item()
		defer delete(src)
		for spec in msgpack.Spec {
			read += testkit.records_at_agree(t, msgpack.reads(spec), msgpack.as(spec), src, {}, "generated")
		}
		for _ in 0 ..< 4 {
			bad := testkit.mutate(src)
			read += testkit.records_at_agree(t, msgpack.reads(.Msgpack), msgpack.as(.Msgpack), bad, {}, "mutated")
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, read > 100, "%d containers read", read)
}
