package host_test

import "base:intrinsics"
import "core:sync"
import "core:testing"
import "core:time"
import core "../../core"
import host ".."

// Runs `task(arg)` on the caller and on the runner's threads, as a parallel procedure does.
run :: proc(runner: ^core.Runner, n: int, task: proc(arg: rawptr), arg: rawptr) {
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

// The caller's call always runs, a helper's may be taken back unstarted, and none runs after `finish`.
@(test)
every_started_call_returns_before_finish :: proc(t: ^testing.T) {
	pool: host.Pool
	host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)
	for _ in 0 ..< 2000 {
		count: int
		run(&pool.runner, pool.runner.threads, bump, &count)
		testing.expect(t, 1 <= count && count <= pool.runner.threads + 1)
	}
}

@(test)
no_more_calls_than_asked :: proc(t: ^testing.T) {
	pool: host.Pool
	host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)
	for _ in 0 ..< 200 {
		count: int
		run(&pool.runner, 1, bump, &count)
		testing.expect(t, 1 <= count && count <= 2)
	}
}

@(test)
pool_of_one_runs_on_the_caller :: proc(t: ^testing.T) {
	pool: host.Pool
	host.pool_init(&pool, 1)
	defer host.pool_destroy(&pool)
	testing.expect_value(t, pool.runner.threads, 0)
	count: int
	run(&pool.runner, 0, bump, &count)
	testing.expect_value(t, count, 1)
}

// More tasks than the pool remembers widths for, alternating, each still runs.
@(test)
many_tasks_share_the_pool :: proc(t: ^testing.T) {
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

@(test)
writing_calls_balance :: proc(t: ^testing.T) {
	pool: host.Pool
	host.pool_init(&pool, 2)
	defer host.pool_destroy(&pool)
	host.writing(&pool, true)
	host.writing(&pool, false)
	count: int
	run(&pool.runner, pool.runner.threads, bump, &count)
	testing.expect(t, count >= 1)
}

// Every call waits for a second one to start, so a pool that hands the task to no helper leaves it waiting.
meet :: proc(arg: rawptr) {
	sync.atomic_add((^int)(arg), 1)
	began := time.tick_now()
	for sync.atomic_load((^int)(arg)) < 2 && time.tick_since(began) < 5 * time.Second {
		intrinsics.cpu_relax()
	}
}

@(test)
helpers_run_the_task_beside_the_caller :: proc(t: ^testing.T) {
	pool: host.Pool
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)
	started: int
	run(&pool.runner, pool.runner.threads, meet, &started)
	testing.expect(t, started >= 2)
}

// A nil task is handed to no helper, which keeps every helper for the next call and for `pool_destroy`.
@(test)
nil_task_runs_nowhere :: proc(t: ^testing.T) {
	pool: host.Pool
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)
	// Every width the pool learns names a task, so nil is a task it has not met.
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

// A call ended before its helpers woke: none runs the task after `finish`, and a negative count hands out none.
@(test)
no_call_runs_after_finish :: proc(t: ^testing.T) {
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

@(private = "file")
Stalled :: struct {
	pool:    ^host.Pool,
	caller:  int,
	started: int,
	done:    int,
}

// A helper's long write, which the caller does not share, so `finish` waits for it past `STALL` and sleeps.
@(private = "file")
write_slowly :: proc(arg: rawptr) {
	s := (^Stalled)(arg)
	if sync.current_thread_id() == s.caller {
		for i := 0; sync.atomic_load(&s.started) == 0 && i < 100_000; i += 1 {
			time.sleep(time.Microsecond)
		}
		return
	}
	sync.atomic_add(&s.started, 1)
	host.writing(s.pool, true)
	time.sleep(3 * time.Millisecond)
	host.writing(s.pool, false)
	sync.atomic_add(&s.done, 1)
}

@(test)
finish_sleeps_on_a_stalled_write :: proc(t: ^testing.T) {
	pool: host.Pool
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)
	s := Stalled{pool = &pool, caller = sync.current_thread_id()}
	run(&pool.runner, pool.runner.threads, write_slowly, &s)
	testing.expect(t, s.started >= 1 && s.done == s.started)
}
