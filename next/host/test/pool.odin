package host_test

import "base:intrinsics"
import "core:sync"
import "core:testing"
import "core:time"
import "stury:lib/core/tape"
import "stury:host"
import "stury:testkit"

// Runs `task(arg)` on the caller and on up to `n` of the runner's threads, as `hook.fan` does on all of them.
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

// A pool that runs no call starts no thread, and one that runs a call starts them.
@(test)
threads_start_at_the_first_call :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	host.pool_init(&pool, 3)
	testing.expect_value(t, pool.settled, 0)
	host.pool_destroy(&pool)
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)
	count: int
	run(&pool.runner, pool.runner.threads, bump, &count)
	testing.expect(t, pool.spawned)
}

// More tasks than the pool remembers widths for, alternating, each still runs.
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

@(test)
helpers_run_the_task_beside_the_caller :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)
	started: int
	run(&pool.runner, pool.runner.threads, meet, &started)
	testing.expect(t, started >= 2)
}

// A nil task is given to no helper, so every helper stays for the next call and for `pool_destroy`.
@(test)
nil_task_runs_nowhere :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pool: host.Pool
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)
	// These four tasks fill the pool's four-entry width table, so nil has no width entry yet.
	count: int
	for task in ([]proc(arg: rawptr){bump, bump_twice, meet, proc(arg: rawptr) {}}) {
		run(&pool.runner, pool.runner.threads, task, &count)
	}
	pool.runner.start(pool.runner.data, pool.runner.threads, nil, nil)
	time.sleep(10 * time.Millisecond)
	pool.runner.finish(pool.runner.data)
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
