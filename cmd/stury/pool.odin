package main

// The batch pool: the threads a large input's pieces are read, built and printed on, and the claims that
// share a job's pieces among them.

import "core:os"
import "core:sync"
import host "../../host"
import json "../../json"

// Input bytes per worker of a record batch: 320 KiB per worker for the first four, 1 MiB per worker past them.
BATCH_BYTES_PER_WORKER :: 1 << 20
BATCH_BYTES_PER_FIRST_WORKERS :: 320 * 1024

// The threads for a `json.each_record` over `n` bytes: none, the caller alone, below two workers' worth, else the
// kept pool, with workers for the largest batch so far, up to one per core: a batch wider than the pool starts it
// again. `per` is the bytes per worker past the first four: 1 MiB, and a batch that only validates its bytes
// (`check`) takes the same. Only the demanded-entries array path passes half.
batch_runner :: proc(run: ^Run, n: int, per := BATCH_BYTES_PER_WORKER) -> ^json.Batch_Runner {
	w := min(max(min(n / BATCH_BYTES_PER_FIRST_WORKERS, 4), n / per), os.get_processor_core_count())
	if w > run.pool_width && w >= 2 {
		if run.pool_width > 0 {
			host.batch_pool_destroy(&run.pool)
		}
		host.batch_pool_init(&run.pool, w)
		run.pool_width = w
	}
	return &run.pool.runner if run.pool_width > 0 else nil
}

// `task` on each of the `n` pieces of `job`, numbered from 0, each claimed in turn by the caller or one of
// the pool's threads, until all are claimed or a task returns false: whether none did.
fan_out :: proc(r: ^json.Batch_Runner, n: int, task: proc(job: ^$T, k: int) -> bool, job: ^T) -> bool {
	Claims :: struct {
		job:     ^T,
		task:    proc(job: ^T, k: int) -> bool,
		n, next: int,
		failed:  bool,
	}
	claim :: proc(arg: rawptr) {
		c := (^Claims)(arg)
		for !sync.atomic_load(&c.failed) {
			k := sync.atomic_add(&c.next, 1)
			if k >= c.n {
				return
			}
			if !c.task(c.job, k) {
				sync.atomic_store(&c.failed, true)
			}
		}
	}
	c := Claims{job = job, task = task, n = n}
	if r.threads > 0 {
		r.start(r.data, r.threads, claim, &c)
		claim(&c)
		r.finish(r.data)
	} else {
		claim(&c)
	}
	return !c.failed
}
