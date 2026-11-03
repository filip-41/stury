package json_tests

import "base:runtime"
import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"
import core "../../core"
import build "../../core/build"
import json ".."
import walktest "../../walktest"

// Building with an allocator that refuses an allocation: reservations, retries and the errors they keep.

// The first reservation is one node, 16 bytes, per two source bytes. An 8 MB arena refuses an 8 MB text holding one
// string, and the retry, sized by a count, fits. A text of 2,000,000 nested arrays needs 2,000,001 nodes, 32 MB, and
// still fails with `.No_Memory`.
@(test)
reservation_retry :: proc(t: ^testing.T) {
	backing := make([]u8, 8 << 20, context.allocator)
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
	testing.expectf(t, err.kind == .None, "longtext in 8 MB: %v", err)
	core.destroy(&doc)

	// One node per level: 2,000,001 nodes of 16 bytes, more than the arena.
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
	testing.expectf(t, err.kind == .No_Memory, "deep in 8 MB: %v", err)
	core.destroy(&doc)
}

// A text whose one node is far smaller than its reservation builds in a 1 MB arena: the first reservation is refused,
// and the second holds what a count of the text found.
@(test)
sparse_text_fits_small_arena :: proc(t: ^testing.T) {
	backing := make([]u8, 1 << 20, context.allocator)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)

	src := make([]u8, 8 << 20, context.allocator)
	defer delete(src)
	src[0] = '"'
	for i in 1 ..< len(src) - 1 {
		src[i] = 'a'
	}
	src[len(src) - 1] = '"'
	doc, err := json.build(src, .Json, {}, false, mem.arena_allocator(&arena))
	defer core.destroy(&doc)
	testing.expectf(t, err.kind == .None, "8 MB string in 1 MB arena: %v", err)
	testing.expect_value(t, len(doc.nodes), 1)
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
	// Allocations 0 and 1 are the open stack and the node array, before any repeat is found. Failing 2 to 4 leaves the
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


// An inner object's repeat is recorded at its close and the walk goes on, so the enclosing object's repeat at byte 7 is
// found at its close and kept over the inner one at byte 18, on the retry after a refused reservation too.
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
	// Allocation 1 is the node array.
	f := walktest.Failing_Alloc{inner = context.allocator, fail_at = 1}
	doc, err := json.build(src, .Json, {}, true, walktest.failing_allocator(&f))
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 7)
}


// Counts the nodes of `src` and checks them against `json.build`'s reservation, which its hooks write with no capacity
// test, and runs that build.
bound_holds :: proc(t: ^testing.T, src: string, $S: json.Spec, max_depth: u32 = 0) {
	count: build.Count
	regs: core.Hook_Regs
	json.walk(transmute([]u8)src, 0, S, {max_depth = max_depth}, &count, &regs, build.builder_hook_count)
	bound := (len(src) + max(core.MAX_DEPTH, int(max_depth))) / 2 + 16
	testing.expectf(t, count.nodes <= bound, "%v %q: %d nodes, reservation %d", S, src[:min(len(src), 16)], count.nodes, bound)
	doc, _ := json.build(transmute([]u8)src, S, {max_depth = max_depth})
	core.destroy(&doc)
}

// No text makes more nodes than the reservation holds, whether it reads or faults. Each unit is a shape with few bytes
// per node, repeated alone, past the depth limit where it nests, and mixed at random.
@(test)
reservation_bound :: proc(t: ^testing.T) {
	units := [?]string{"[", "1,", "[1,", "[],", "{\"\":1,", "{\"\":[", "{\"\":{", "[[]],", "1 ", "\"\"", "1\"\"", "]", "}", ",", ":", "/**/", "//\n"}
	units5 := [?]string{"{a:1,", "{a:[", "{a:{", "+1,", ".5,", "[.5,", "a:", "'',", "{'':''"}
	for n in ([?]int{1, 2, 3, 1000, 4000}) {
		for unit in units {
			src := strings.repeat(unit, n, context.temp_allocator)
			wrapped := strings.concatenate({"[", src, "]"}, context.temp_allocator)
			bound_holds(t, src, .Json)
			bound_holds(t, src, .Jsonc)
			bound_holds(t, src, .Json5)
			bound_holds(t, wrapped, .Json)
			bound_holds(t, wrapped, .Json, 5000)
			bound_holds(t, src, .Jsonc, 5000)
		}
		for unit in units5 {
			src := strings.repeat(unit, n, context.temp_allocator)
			bound_holds(t, src, .Json5)
			bound_holds(t, src, .Json5, 5000)
			bound_holds(t, strings.concatenate({"[", src}, context.temp_allocator), .Json5, 5000)
		}
	}
	state := rand.create(1)
	gen := rand.default_random_generator(&state)
	for _ in 0 ..< 2000 {
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< 400 {
			if rand.int_max(2, gen) == 0 {
				strings.write_string(&b, rand.choice(units[:], gen))
			} else {
				strings.write_string(&b, rand.choice(units5[:], gen))
			}
		}
		bound_holds(t, strings.to_string(b), .Json5, 5000)
		free_all(context.temp_allocator)
	}
}

// Builds `src` in an arena of its nodes, its facts and its deepest nesting's stack, plus `extra` bytes.
@(private)
fits_arena :: proc(t: ^testing.T, src: string, $S: json.Spec, extra: int) {
	count: build.Count
	regs: core.Hook_Regs
	json.walk(transmute([]u8)src, 0, S, {}, &count, &regs, build.builder_hook_count)
	need := count.nodes * size_of(core.Node) + count.facts * size_of(core.Fact) + count.deepest * size_of(u64) + extra
	backing := make([]u8, need, context.allocator)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	doc, err := json.build(transmute([]u8)src, S, {}, false, mem.arena_allocator(&arena))
	defer core.destroy(&doc)
	testing.expectf(t, err.kind == .None, "%d bytes: %v", need, err)
	testing.expect_value(t, len(doc.nodes), count.nodes)
}

// A document fits an arena that holds it: a refused reservation leaves the arena room for the sized one.
@(test)
smallest_arena :: proc(t: ^testing.T) {
	dense := strings.concatenate({"[", strings.repeat("1,", 20000, context.temp_allocator), "1]"}, context.temp_allocator)
	sparse := strings.concatenate({"[", strings.repeat("\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",", 20000, context.temp_allocator), "1]"}, context.temp_allocator)
	commented := strings.concatenate({"[", strings.repeat("1,/*a*/", 20000, context.temp_allocator), "1]"}, context.temp_allocator)
	fits_arena(t, dense, .Json, 64)
	fits_arena(t, sparse, .Json, 64)
	fits_arena(t, commented, .Jsonc, 64)
}

// An arena that takes the reservation gets its unused tail back at the end of the build.
@(test)
arena_tail_returns :: proc(t: ^testing.T) {
	backing := make([]u8, 4 << 20, context.allocator)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	src := strings.concatenate({"[\"", strings.repeat("a", 1 << 20, context.temp_allocator), "\"]"}, context.temp_allocator)
	doc, err := json.build(transmute([]u8)src, .Json, {}, false, mem.arena_allocator(&arena))
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	stack := core.MAX_DEPTH * size_of(u64)
	testing.expectf(t, arena.offset <= stack + 64 + len(doc.nodes) * size_of(core.Node), "%d bytes held", arena.offset)
}
