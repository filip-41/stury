package msgpack_tests

import "core:math/rand"
import "core:mem"
import "core:testing"
import "stury:host"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:testkit"

// Multi-threaded runner tests for `validate`, `build`, and parallel root-array `unmarshal`.

@(private = "file")
counting_runner :: proc(calls: ^int) -> tape.Runner {
	return {
		threads = 3,
		data = calls,
		start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {
			(^int)(data)^ += 1
		},
		finish = proc(data: rawptr) {},
	}
}

@(test)
memory_budget_builds_on_the_runner :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	items := make([dynamic]u8, context.temp_allocator)
	put_array_head(&items, 80)
	for k in 0 ..< 40 {
		append(&items, 0x82, 0xa1, 'a', u8(k % 20), 0xa1, 'a', 0x01)
		append(&items, 0xd6, 0xff, 0x00, 0x01, 0x02, 0x03)
	}
	for opts in ([]msgpack.Options{{budget = {memory = 1 << 20}}, {budget = {memory = 1 << 20}, dups = .First}, {budget = {memory = 1 << 20}, dups = .All}}) {
		calls := 0
		runner := counting_runner(&calls)
		wide := opts
		wide.runner = &runner
		doc, err := msgpack.build(items[:], .Msgpack, wide)
		defer msgpack.destroy(&doc)
		testing.expectf(t, err == nil && calls > 0, "%v: %v, %d runner calls", opts.dups, err, calls)
	}
}

@(private = "file")
THREADS :: [?]int{1, 2, 3, 17, 70}

@(private = "file")
THREAD_OPTIONS := [?]msgpack.Options{{}, {dups = .First}, {dups = .Refuse}, {budget = {depth = 3}}, {budget = {nodes = 12}}, {budget = {steps = 4}}, {tolerate = {.Invalid_Utf8}}}

@(private = "file")
MEMORY_OPTIONS := [?]msgpack.Options{{budget = {memory = 1 << 20}}, {budget = {memory = 1 << 20}, dups = .First}, {budget = {memory = 64}}}

@(test)
builds_on_threads_agree :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x99b1)
	defer free_all(context.temp_allocator)
	texts := make([dynamic][]u8, context.temp_allocator)
	for h in PIECE_HEX {
		append(&texts, hex(h))
	}
	{
		context.allocator = context.temp_allocator
		for _ in 0 ..< testkit.rounds(25) {
			src := random_item()
			append(&texts, src, mutated(src))
		}
	}
	for text in texts {
		for spec in msgpack.Spec {
			for opts in THREAD_OPTIONS {
				for threads in THREADS {
					r := testkit.serial_runner(threads)
					if ok, _ := testkit.threads_agree(t, msgpack.reads(spec), msgpack.as(spec), text, opts, &r, "text"); !ok {
						return
					}
				}
			}
			for opts in MEMORY_OPTIONS {
				for threads in THREADS {
					r := testkit.serial_runner(threads)
					if !testkit.threads_fit(t, msgpack.reads(spec), msgpack.as(spec), text, opts, &r, "memory") {
						return
					}
				}
			}
		}
	}
}

@(test)
builds_on_long_texts_and_pools_agree :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x99b2)
	defer free_all(context.temp_allocator)
	for kind in 0 ..< 4 {
		src := long_text(kind, testkit.rounds(800))
		defer delete(src)
		for spec in msgpack.Spec {
			for threads in ([]int{2, 3, 5}) {
				r := testkit.serial_runner(threads)
				if ok, _ := testkit.threads_agree(t, msgpack.reads(spec), msgpack.as(spec), src, {}, &r, "long text"); !ok {
					return
				}
			}
		}
	}

	// Parallel root array unmarshal on a real OS thread pool vs serial unmarshal.
	Row :: struct {
		id:   i64,
		name: string,
	}
	rows := make([]Row, 400, context.temp_allocator)
	for &row, i in rows {
		row = {i64(i), "row"}
	}
	encoded, merr := msgpack.marshal(&rows, .Compact, allocator = context.temp_allocator)
	testing.expect_value(t, merr, nil)

	pool: host.Pool
	host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)

	serial_out: []Row
	testing.expect_value(t, msgpack.unmarshal(encoded, &serial_out, .Compact, allocator = context.temp_allocator), nil)

	par_out: []Row
	testing.expect_value(t, msgpack.unmarshal(encoded, &par_out, .Compact, opts = {runner = &pool.runner}, allocator = context.temp_allocator), nil)
	testing.expect_value(t, len(par_out), len(serial_out))
	for i in 0 ..< len(serial_out) {
		testing.expect(t, par_out[i].id == serial_out[i].id && par_out[i].name == serial_out[i].name)
	}

	// Verify pool parallel build agrees on multi-megabyte array.
	big := make([dynamic]u8)
	defer delete(big)
	count := u32(80_000)
	put_array_head(&big, count)
	for i in u32(0) ..< count {
		append(&big, u8(i & 0x7f))
	}
	doc, berr := msgpack.build(big[:], .Compact, {runner = &pool.runner})
	defer msgpack.destroy(&doc)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, len(doc.nodes), int(count) + 1)

	// Measure memory does not double by falling back when parallel plan succeeds.
	track_one, track_par: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track_one, context.allocator)
	defer mem.tracking_allocator_destroy(&track_one)
	d1, e1 := msgpack.build(big[:], .Compact, {}, mem.tracking_allocator(&track_one))
	msgpack.destroy(&d1)
	testing.expect_value(t, e1, nil)

	mem.tracking_allocator_init(&track_par, context.allocator)
	defer mem.tracking_allocator_destroy(&track_par)
	r := testkit.serial_runner(3)
	dp, ep := msgpack.build(big[:], .Compact, {runner = &r}, mem.tracking_allocator(&track_par))
	msgpack.destroy(&dp)
	testing.expect_value(t, ep, nil)
	testing.expect(t, track_par.total_memory_allocated > 0 && track_par.total_memory_allocated * 10 < track_one.total_memory_allocated * 18)
}
