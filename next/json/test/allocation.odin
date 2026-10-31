package json_tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import core "../../core"
import json ".."
import walktest "../../walktest"

// Building with an allocator that refuses an allocation: reservations, retries and the errors they keep.

// The first reservation is one node, 16 bytes, per source byte. A 24 MB arena refuses an 8 MB text holding one string,
// and the retry, with the checked hook, fits. A text of 2,000,000 nested arrays needs 2,000,001 nodes, 32 MB, and
// still fails with `.No_Memory`.
@(test)
reservation_retry :: proc(t: ^testing.T) {
	backing := make([]u8, 24 << 20, context.allocator)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	alloc := mem.arena_allocator(&arena)

	src := make([]u8, 8 << 20, context.allocator)
	defer delete(src)
	src[0] = '"'
	for i in 1 ..< len(src) - 1 {
		src[i] = 'a'
	}
	src[len(src) - 1] = '"'
	doc, err := json.build(src, .Json, {}, false, alloc)
	testing.expectf(t, err.kind == .None, "longtext in 24 MB: %v", err)
	core.destroy(&doc)

	// One node per level: 2,000,001 nodes of 16 bytes, more than the 24 MB arena.
	arena.offset = 0
	depth := 2_000_000
	nested := make([]u8, 2 * depth + 1, context.allocator)
	defer delete(nested)
	for i in 0 ..< depth {
		nested[i] = '['
		nested[len(nested) - 1 - i] = ']'
	}
	nested[depth] = '0'
	doc, err = json.build(nested, .Json, {max_depth = u32(depth + 1)}, false, alloc)
	testing.expectf(t, err.kind == .No_Memory, "deep in 24 MB: %v", err)
	core.destroy(&doc)
}

// A `.Duplicate_Key` found before an allocation that then fails stays the error: `.No_Memory` names no byte and does
// not replace it.
@(test)
refuse_oom_keeps_duplicate :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `[{"a":1,"a":2},{`)
	for i in 0 ..< 41 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '"')
		strings.write_byte(&b, 'a' + u8(i))
		strings.write_string(&b, `":0`)
	}
	strings.write_string(&b, "}]")
	src := transmute([]u8)strings.to_string(b)
	// Allocations 0 and 1 are the node array and the open stack, before any repeat is found. Failing 2 to 4 leaves the
	// `.Duplicate_Key` at byte 8 as the error.
	for fail_at in 2 ..= 4 {
		f := walktest.Failing_Alloc{inner = context.allocator, fail_at = fail_at}
		doc, err := json.build(src, .Json, {}, true, walktest.failing_allocator(&f))
		testing.expectf(t, err.kind == core.Document_Error_Kind.Duplicate_Key && err.at == 8, "fail_at %d: %v at %d", fail_at, err.kind, err.at)
		core.destroy(&doc)
	}
}


// An allocator that writes zeroes over a block when it is freed, so a read after the free finds other bytes.
Poison_Free_Alloc :: struct {
	inner: runtime.Allocator,
}

poison_free_alloc_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	p := (^Poison_Free_Alloc)(data)
	if mode == .Free && old_memory != nil {
		mem.set(old_memory, 0, old_size)
	}
	return p.inner.procedure(p.inner.data, mode, size, alignment, old_memory, old_size, loc)
}

// Two identical keys of 300 escaped bytes decode to 300 bytes, past `text_equals`'s 256-byte stack buffer, so its
// compare reads an allocation. A refusing build fails at the second key, whose quote is at byte 1806.
@(test)
refuse_equal_long_escaped_keys :: proc(t: ^testing.T) {
	key := strings.repeat(`\u0041`, 300, context.temp_allocator)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"`)
	strings.write_string(&b, key)
	strings.write_string(&b, `":1,"`)
	strings.write_string(&b, key)
	strings.write_string(&b, `":2}`)
	p := Poison_Free_Alloc{inner = context.allocator}
	alloc := runtime.Allocator{procedure = poison_free_alloc_proc, data = &p}
	doc, err := json.build(transmute([]u8)strings.to_string(b), .Json, {}, true, alloc)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 1806)
}


// An inner object's repeat is recorded at its close and the walk goes on. A later node-buffer growth does not stop the
// walk, so the enclosing object's repeat at byte 7 is found at its close and kept over the inner one at byte 18.
@(test)
refuse_grow_keeps_earliest_repeat :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"a":1,"a":{"b":1,"b":2}`)
	for _ in 0 ..< 40 {
		strings.write_string(&b, `,"c":0`)
	}
	strings.write_byte(&b, '}')
	src := transmute([]u8)strings.to_string(b)
	// Allocation 0 is the token-bound node array. Its refusal retries with the checked hook and one node per 8 bytes,
	// and the text makes 89 nodes against a 33-node reservation, so the buffer grows after the inner repeat.
	f := walktest.Failing_Alloc{inner = context.allocator, fail_at = 0}
	doc, err := json.build(src, .Json, {}, true, walktest.failing_allocator(&f))
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 7)
}
