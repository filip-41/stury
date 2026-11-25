package cbor_tests

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:testing"
import "stury:cbor"
import "stury:host"
import "stury:testkit"

@(private = "file")
Cbor_Item :: struct {
	id:   i64    `cbor:"id"`,
	name: string `cbor:"name"`,
	ok:   bool   `cbor:"ok"`,
}

@(private = "file")
make_large_cbor_array :: proc(count: int, allocator := context.allocator) -> []u8 {
	// Marshal an array of `count` structs (~600 KiB for 18000 items) so it exceeds `PARALLEL_FROM`.
	items := make([]Cbor_Item, count, context.temp_allocator)
	for &it, i in items {
		it = {id = i64(i), name = "item-payload-value-0123456789", ok = i % 2 == 0}
	}
	out, err := cbor.marshal(&items, .Cbor, allocator = allocator)
	assert(err == nil)
	return out
}

@(test)
parallel_cbor_validate_and_typed :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := make_large_cbor_array(14000)
	defer delete(src)

	// Parallel validate across specs and thread counts
	for spec in cbor.Spec {
		want := cbor.validate(src, spec)
		for workers in ([]int{1, 2, 4, 18}) {
			pool: host.Pool
			_ = host.pool_init(&pool, workers)
			defer host.pool_destroy(&pool)
			got := cbor.validate(src, spec, {runner = &pool.runner})
			testing.expectf(t, got == want, "%v w=%d validate: got=%v want=%v", spec, workers, got, want)
		}
	}

	// Faulty CBOR validate matches serial
	bad := make([]u8, len(src))
	defer delete(bad)
	copy(bad, src)
	bad[len(bad) / 2] = 0xff // unexpected break
	want_bad := cbor.validate(bad, .Cbor)
	pool: host.Pool
	_ = host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)
	got_bad := cbor.validate(bad, .Cbor, {runner = &pool.runner})
	testing.expectf(t, got_bad == want_bad && want_bad != nil, "cbor bad validate: got=%v want=%v", got_bad, want_bad)

	// Parallel typed unmarshal (arena, heap, tracking)
	va_ref: virtual.Arena
	_ = virtual.arena_init_growing(&va_ref)
	defer virtual.arena_destroy(&va_ref)
	want_items: []Cbor_Item
	testing.expect(t, cbor.unmarshal(src, &want_items, .Cbor, allocator = virtual.arena_allocator(&va_ref)) == nil)
	testing.expectf(t, len(want_items) == 14000, "cbor want len=%d", len(want_items))

	for workers in ([]int{1, 2, 4, 18}) {
		p: host.Pool
		_ = host.pool_init(&p, workers)
		defer host.pool_destroy(&p)
		for borrow in ([]bool{false, true}) {
			va: virtual.Arena
			_ = virtual.arena_init_growing(&va)
			defer virtual.arena_destroy(&va)
			got: []Cbor_Item
			err := cbor.unmarshal(src, &got, .Cbor, {borrow_strings = borrow}, {runner = &p.runner}, virtual.arena_allocator(&va))
			testing.expectf(t, err == nil && len(got) == len(want_items), "cbor w=%d borrow=%v err=%v len=%d", workers, borrow, err, len(got))
			for i in 0 ..< min(len(got), len(want_items)) {
				if got[i] != want_items[i] {
					testing.expectf(t, false, "cbor w=%d item[%d]: %v vs %v", workers, i, got[i], want_items[i])
					break
				}
			}
		}
	}

	// Heap (`.Direct`) + Tracking_Allocator
	heap := runtime.heap_allocator()
	hgot: []Cbor_Item
	testing.expect(t, cbor.unmarshal(src, &hgot, .Cbor, {borrow_strings = false}, {runner = &pool.runner}, heap) == nil)
	for it in hgot {
		delete(it.name, heap)
	}
	delete(hgot, heap)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, heap)
	defer mem.tracking_allocator_destroy(&track)
	ta := mem.tracking_allocator(&track)
	tgot: []Cbor_Item
	testing.expect(t, cbor.unmarshal(src, &tgot, .Cbor, {borrow_strings = false}, {runner = &pool.runner}, ta) == nil)
	for it in tgot {
		delete(it.name, ta)
	}
	delete(tgot, ta)
	testing.expectf(t, len(track.allocation_map) == 0 && len(track.bad_free_array) == 0, "cbor tracking leaks=%d", len(track.allocation_map))

	// M7: Budget.memory respected by `cbor.unmarshal` parallel plan_parts and matches serial behavior.
	for lim in ([]u64{1024, 64 << 10, 64 << 20}) {
		va_s, va_p: virtual.Arena
		_ = virtual.arena_init_growing(&va_s)
		_ = virtual.arena_init_growing(&va_p)
		defer virtual.arena_destroy(&va_s)
		defer virtual.arena_destroy(&va_p)
		s_got, p_got: []Cbor_Item
		serr := cbor.unmarshal(src, &s_got, .Cbor, {}, {budget = {memory = lim}}, virtual.arena_allocator(&va_s))
		perr := cbor.unmarshal(src, &p_got, .Cbor, {}, {budget = {memory = lim}, runner = &pool.runner}, virtual.arena_allocator(&va_p))
		testing.expectf(t, perr == serr, "cbor budget %d: perr=%v serr=%v", lim, perr, serr)
	}
}
