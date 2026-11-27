package host_test

import "base:intrinsics"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import "stury:lib/core/tape"
import "stury:host"
import "stury:testkit"

// Runs `task(arg)` on the caller and on up to `n` of the runner's threads, as `tape.fan` does on all of them.
run :: proc(runner: ^tape.Runner, n: int, task: proc(arg: rawptr), arg: rawptr) {
	runner.start(runner.data, n, task, arg)
	task(arg)
	runner.finish(runner.data)
}

bump :: proc(arg: rawptr) {
	sync.atomic_add((^int)(arg), 1)
}

bump_twice :: proc(arg: rawptr) {
	sync.atomic_add((^int)(arg), 2)
}

// The caller's call always runs, a helper's may be taken back unstarted, none runs after `finish`, and no more run than
// the width asked for.
@(test)
started_calls_return_before_finish_and_are_no_more_than_asked :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)
	for width in ([]int{1, pool.runner.threads}) {
		for _ in 0 ..< 1000 {
			count: int
			run(&pool.runner, width, bump, &count)
			testing.expect(t, 1 <= count && count <= width + 1)
		}
	}
}

@(test)
pool_of_one_runs_on_the_caller :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	host.pool_init(&pool, 1)
	defer host.pool_destroy(&pool)
	testing.expect_value(t, pool.runner.threads, 0)
	count: int
	run(&pool.runner, 0, bump, &count)
	testing.expect_value(t, count, 1)
}

// Alternating tasks share the pool cleanly.
@(test)
many_tasks_share_the_pool :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)
	count: int
	for i in 0 ..< 400 {
		run(&pool.runner, pool.runner.threads, bump if i % 2 == 0 else bump_twice, &count)
	}
	testing.expect(t, count >= 600)
	testing.expect(t, count <= 400 * 3 * (pool.runner.threads + 1) / 2)
}

// Every call waits for a second one to start, so a pool that gives the task to no helper leaves it waiting.
meet :: proc(arg: rawptr) {
	sync.atomic_add((^int)(arg), 1)
	began := time.tick_now()
	for sync.atomic_load((^int)(arg)) < 2 && time.tick_since(began) < 5 * time.Second {
		intrinsics.cpu_relax()
	}
}

// A nil task is given to no helper, so every helper stays for the next call and for `pool_destroy`.
@(test)
nil_task_runs_nowhere :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)
	// Fill all 4 width slots before handing a nil task so a bug in `width_of` would evict a live task.
	count: int
	for task in ([]proc(arg: rawptr){bump, bump_twice, meet, proc(arg: rawptr) {}}) {
		run(&pool.runner, pool.runner.threads, task, &count)
	}
	pool.runner.start(pool.runner.data, pool.runner.threads, nil, nil)
	time.sleep(10 * time.Millisecond)
	pool.runner.finish(pool.runner.data)
	testing.expect(t, pool.widths[0].task != nil)
	started: int
	run(&pool.runner, pool.runner.threads, meet, &started)
	testing.expect(t, started >= 2)
}

// A call ended before its helpers woke: none runs the task after `finish`, and a negative count gives out none.
@(test)
no_call_runs_after_finish :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)
	for i in 0 ..< 200 {
		count: int
		pool.runner.start(pool.runner.data, pool.runner.threads if i % 2 == 0 else -1, bump, &count)
		pool.runner.finish(pool.runner.data)
		seen := sync.atomic_load(&count)
		time.sleep(50 * time.Microsecond)
		testing.expect_value(t, sync.atomic_load(&count), seen)
	}
}

// `workers <= 0` defaults to one worker per processor core (counting the caller).
@(test)
non_positive_workers_uses_core_count :: proc(t: ^testing.T) {
	testkit.deadline(t)
	want := max(os.get_processor_core_count() - 1, 0)
	for workers in ([]int{0, -3}) {
		pool: host.Pool
		err := host.pool_init(&pool, workers)
		defer host.pool_destroy(&pool)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, pool.runner.threads, want)
		count: int
		run(&pool.runner, pool.runner.threads, bump, &count)
		testing.expect(t, count >= 1)
	}
}

// Destroying a zero-initialized or never-called pool is safe and leaves it zeroed.
@(test)
destroy_zero_pool_is_safe :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	host.pool_destroy(&pool)
	testing.expect_value(t, pool.runner.threads, 0)
	testing.expect(t, !pool.spawned)
	host.pool_init(&pool, 3)
	testing.expect_value(t, pool.settled, 0)
	host.pool_destroy(&pool)
	testing.expect(t, !pool.spawned)
}

// Calls with `n <= 0` or `task == nil` do not spawn helper threads; the first real parallel call spawns them and
// keeps helpers warm (`spin == true`) on call #1.
@(test)
empty_or_nil_first_calls_do_not_spawn_threads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)

	count: int
	pool.runner.start(pool.runner.data, 0, bump, &count)
	pool.runner.finish(pool.runner.data)
	testing.expect(t, !pool.spawned)
	testing.expect_value(t, pool.settled, 0)
	testing.expect(t, pool.spin)

	pool.runner.start(pool.runner.data, -1, bump, &count)
	pool.runner.finish(pool.runner.data)
	testing.expect(t, !pool.spawned)
	testing.expect_value(t, pool.settled, 0)

	pool.runner.start(pool.runner.data, pool.runner.threads, nil, nil)
	pool.runner.finish(pool.runner.data)
	testing.expect(t, !pool.spawned)
	testing.expect_value(t, pool.settled, 0)

	started: int
	run(&pool.runner, pool.runner.threads, meet, &started)
	testing.expect(t, pool.spawned)
	testing.expect(t, started >= 2)
}
