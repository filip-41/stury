package json_tests

// A public call hands the caller's `context.allocator` back as it found it: the walks that need an allocator
// take it explicitly, and the few that still reach the context (the key-check scratch, an edit's canonical
// text, an `any` tree) restore it on every return.

import json "../.."
import "base:runtime"
import "core:mem/virtual"
import "core:testing"

@(private = "file")
same_allocator :: proc(a, b: runtime.Allocator) -> bool {
	return a.procedure == b.procedure && a.data == b.data
}

@(test)
test_a_call_leaves_the_callers_allocator_in_place :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	other := virtual.arena_allocator(&arena)
	saved := context.allocator
	defer context.allocator = saved

	src := raw(`{"a":1,"b":[true,false],"c":{"d":"x"}}`)

	// A `.Refuse` scan runs the key check, whose scratch is the request's allocator, reached through the
	// context. The caller's is the heap's again once it returns.
	{
		req: json.Request({.Nodes})
		_ = json.request_init(&req, opts = {duplicates = .Refuse}, allocator = other)
		_ = json.scan(src, &req)
		json.destroy(&req)
		testing.expect(
			t,
			same_allocator(context.allocator, saved),
			"a `.Refuse` scan left the request's allocator in the caller's context",
		)
	}

	// An edit marshals the replacement through the context and validates it, a JSONC `Raw` lists comments
	// there too.
	{
		_, _ = json.set(src, ".a", 2, allocator = other)
		testing.expect(t, same_allocator(context.allocator, saved), "an edit left its allocator in the caller's context")
	}

	// An `any` unmarshal builds its tree in the call's allocator, assigned to the context for the shape
	// walk's leaf.
	{
		v: any
		_ = json.unmarshal(src, &v, allocator = other)
		testing.expect(
			t,
			same_allocator(context.allocator, saved),
			"an `any` unmarshal left its allocator in the caller's context",
		)
	}
}

@(test)
test_a_deep_walk_frees_its_spill_with_the_scanner_allocator :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)

	// One frame past MAX_DEPTH: the walk spills the fixed array into the scanner's allocator and frees it
	// with the same one. Built in the arena, so a free against any other allocator fails loudly under ASan.
	depth := int(json.MAX_DEPTH) + 8
	src := make([]u8, depth * 2 + 1, virtual.arena_allocator(&arena))
	for i in 0 ..< depth {
		src[i] = '['
	}
	src[depth] = '1'
	for i in 0 ..< depth {
		src[depth + 1 + i] = ']'
	}

	saved := context.allocator
	defer context.allocator = saved
	testing.expect_value(t, json.validate(src, {limits = {max_depth = u64(depth)}}), nil)
	testing.expect(
		t,
		same_allocator(context.allocator, saved),
		"a deep validate left its allocator in the caller's context",
	)
}
