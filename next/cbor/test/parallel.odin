package cbor_tests

import "base:runtime"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:testing"
import "stury:cbor"
import "stury:host"
import "stury:lib/core/tape"
import "stury:testkit"

// The build of a CBOR text on the threads of a runner.

// A build under `Budget.memory` runs on the runner's threads whatever the text holds: a tag, a repeated key under a
// policy past `.Default`, or neither.
@(test)
memory_budget_builds_on_the_runner :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	items := make([dynamic]u8, context.temp_allocator)
	append(&items, 0x9f)
	for k in 0 ..< 40 {
		append(&items, 0xa2, 0x61, 'a', u8(k % 20), 0x61, 'a', 0x01)
		append(&items, 0xc1, 0x1a, 0x00, 0x01, 0x02, 0x03)
	}
	append(&items, 0xff)
	for opts in ([]cbor.Options{{budget = {memory = 1 << 20}}, {budget = {memory = 1 << 20}, dups = .First}, {budget = {memory = 1 << 20}, dups = .All}}) {
		calls := 0
		runner := testkit.counting_runner(3, &calls)
		wide := opts
		wide.runner = &runner
		doc, err := cbor.build(items[:], .Cbor, wide)
		defer cbor.destroy(&doc)
		testing.expectf(t, err == nil && calls > 0, "%v: %v, %d runner calls", opts.dups, err, calls)
	}
}

// A text cut at every byte, with floats and simple values at the cuts, builds on many threads as on one: a chunk that
// ends inside the head of an item reads no byte past the text.
@(test)
builds_on_threads_agree_on_every_prefix :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	// The second ends in a simple value cut after its head, as a chunk of a text this short does.
	for text in ([]string {
			"a4 61 61 fb 3ff0000000000000 61 62 fa 3fc00000 61 63 f9 3c00 61 64 f8 20 a1 61 65 82 fb 3ff8000000000000 f8 21",
			"85 a0 82 d9d9f7 a3 40 1a00016053 60 6178 4263 62 a5 2a 198b4b 3835 198dd2 38b8 d9d9f7 82 c4 82 21 196ab3 1933 f8",
		}) {
		whole := testkit.hex(text)
		for n in 0 ..= len(whole) {
			for spec in cbor.Spec {
				r := testkit.serial_runner(17)
				if ok, _ := testkit.threads_agree(t, cbor.reads(spec), cbor.as(spec), whole[:n], {}, &r, "prefix"); !ok {
					return
				}
			}
		}
	}
}

// The thread counts of the thread law.
@(private = "file")
THREADS :: [?]int{1, 2, 3, 17, 70}

// The options a build on threads is checked under: the defaults, each repeated-key policy, budgets of depth, nodes,
// steps and memory, and a tolerance.
@(private = "file")
THREAD_OPTIONS := [?]cbor.Options{{}, {dups = .First}, {dups = .Refuse}, {budget = {depth = 3}}, {budget = {nodes = 12}}, {budget = {steps = 4}}, {tolerate = {.Invalid_Utf8}}}

// The options a build on threads is checked under a memory budget: the document of one thread or a refusal of the
// budget.
@(private = "file")
MEMORY_OPTIONS := [?]cbor.Options{{budget = {memory = 1 << 20}}, {budget = {memory = 1 << 20}, dups = .First}, {budget = {memory = 64}}}

// A build with a runner of every thread count of the law is the build on one thread, node for node, and refuses a
// text with the same error, over the texts read in pieces and random items and their mutations of every spec.
@(test)
builds_on_threads_agree :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xcb1)
	defer free_all(context.temp_allocator)
	texts := make([dynamic][]u8, context.temp_allocator)
	for h in PIECE_HEX {
		append(&texts, testkit.hex(h))
	}
	{
		context.allocator = context.temp_allocator
		for _ in 0 ..< testkit.rounds(30) {
			src := random_item()
			append(&texts, src, testkit.mutate(src))
		}
	}
	for text in texts {
		for spec in cbor.Spec {
			for opts in THREAD_OPTIONS {
				for threads in THREADS {
					r := testkit.serial_runner(threads)
					if ok, _ := testkit.threads_agree(t, cbor.reads(spec), cbor.as(spec), text, opts, &r, "text"); !ok {
						return
					}
				}
			}
			for opts in MEMORY_OPTIONS {
				for threads in THREADS {
					r := testkit.serial_runner(threads)
					if !testkit.threads_fit(t, cbor.reads(spec), cbor.as(spec), text, opts, &r, "memory") {
						return
					}
				}
			}
		}
	}
}

// A long text built on runners of every thread count of the law, in chunks that start inside every kind of container
// and of string, is the build on one thread and refuses a mutated text with its error.
@(test)
builds_on_long_texts_agree :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xcb4)
	defer free_all(context.temp_allocator)
	texts := make([dynamic][]u8, context.temp_allocator)
	{
		context.allocator = context.temp_allocator
		for kind in 0 ..< 8 {
			src := long_text(kind, testkit.rounds(1500)) if kind < 5 else sorted_text(kind - 5, testkit.rounds(1500))
			append(&texts, src)
			for _ in 0 ..< 3 {
				append(&texts, testkit.mutate(src))
			}
		}
	}
	for text in texts {
		for spec in cbor.Spec {
			for threads in ([]int{2, 3, 5}) {
				r := testkit.serial_runner(threads)
				if ok, _ := testkit.threads_agree(t, cbor.reads(spec), cbor.as(spec), text, {}, &r, "long text"); !ok {
					return
				}
			}
		}
	}
}

// A valid long text built on a runner is built in parts and not again on one thread, as the plan of a text it misreads
// has it: the blocks the build takes stay near those of a build on one thread, where a build made twice takes about
// twice as many.
@(test)
builds_on_a_runner_do_not_fall_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xcb5)
	defer free_all(context.temp_allocator)
	texts := make([dynamic][]u8, context.temp_allocator)
	{
		context.allocator = context.temp_allocator
		for kind in 0 ..< 5 {
			append(&texts, long_text(kind, testkit.rounds(6000)))
		}
		for kind in 0 ..< 3 {
			append(&texts, sorted_text(kind, testkit.rounds(6000)))
		}
	}
	for text, k in texts {
		bytes_of :: proc(text: []u8, spec: cbor.Spec, runner: ^tape.Runner) -> u64 {
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, context.allocator)
			defer mem.tracking_allocator_destroy(&track)
			doc, err := cbor.build(text, spec, {runner = runner}, mem.tracking_allocator(&track))
			cbor.destroy(&doc)
			return u64(track.total_memory_allocated) if err == nil else 0
		}
		r := testkit.serial_runner(3)
		spec := cbor.Spec.Cbor if k < 5 else .Length_First if k == 7 else .Deterministic
		one, many := bytes_of(text, spec, nil), bytes_of(text, spec, &r)
		testing.expectf(t, one > 0 && many > 0 && many * 10 < one * 15, "text %d: %d bytes on one thread, %d on a runner", k, one, many)
	}
}

// The bytes of the long text of `builds_on_pools_agree`, enough for parts on every thread count of the law.
@(private = "file")
POOL_TEXT :: 4 << 20

// A long indefinite array of the texts read in pieces and of random items each spec reads, built on pools of every
// thread count of the law, is the build on one thread, under the defaults and a repeated-key policy, and under a memory
// budget the document of one thread or a refusal.
@(test)
builds_on_pools_agree :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xcb3)
	b := make([dynamic]u8)
	defer delete(b)
	append(&b, 0x9f)
	for k := 0; len(b) < POOL_TEXT; k += 1 {
		append(&b, ..testkit.hex(PIECE_HEX[k % 5]))
		item := random_item()
		if cbor.validate(item) == nil {
			append(&b, ..item)
		}
		delete(item)
		free_all(context.temp_allocator)
	}
	append(&b, 0xff)
	options := [?]cbor.Options{{}, {dups = .First}}
	for threads in THREADS {
		pool: host.Pool
		host.pool_init(&pool, threads)
		defer host.pool_destroy(&pool)
		for spec in cbor.Spec {
			for opts in options {
				if ok, _ := testkit.threads_agree(t, cbor.reads(spec), cbor.as(spec), b[:], opts, &pool.runner, "long"); !ok {
					return
				}
			}
			for memory in ([]u64{1 << 30, u64(len(b))}) {
				if !testkit.threads_fit(t, cbor.reads(spec), cbor.as(spec), b[:], {budget = {memory = memory}}, &pool.runner, "long memory") {
					return
				}
			}
		}
	}
}

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
