package main

// The batch pool: the threads a large input's pieces are read, built and printed on, and the claims that
// share a job's pieces among them.

import "core:mem/virtual"
import "core:os"
import "core:sync"
import host "../../host"
import json "../../json"

// Input bytes per worker of a record batch: 128 KiB per worker for the first four, 1 MiB per worker past them.
BATCH_BYTES_PER_WORKER :: 1 << 20
BATCH_BYTES_PER_FIRST_WORKERS :: 1 << 17

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

// What one piece of a job printed (`Piece_Output`).
Record_Piece :: struct {
	out:      [dynamic]byte,
	ret:      int, // jq's result for the piece's last record, when it answered one
	answered: bool,
	done:     bool,
	stop:     int, // where the piece left the rest to the main thread, or -1
}

// The output of a job's pieces, `json.each_record`'s or `csv.each_record`'s: each piece prints into a buffer of its
// own, and a buffer is written as soon as the pieces before it are.
Piece_Output :: struct {
	run:     ^Run,
	// The pieces by the library's number, each printed once those before it are, up to the first that left the rest
	// to the main thread, `stop`, or -1. A printed piece's buffer is a spare for another piece, since a fresh one
	// costs more than a piece of small answers.
	lock:    sync.Mutex,
	// Signalled when `printed` moves or `stop` is set, for a piece waiting in `begin_piece`.
	moved:   sync.Cond,
	arena:   virtual.Arena,
	pieces:  [dynamic]Record_Piece,
	spare:   [dynamic][dynamic]byte,
	printed: int,
	stop:    int,
	// The output written while the lock is let go: its holder owns `writing`, with the held output swapped into
	// `wbuf`, so that one thread writes at a time and in order, and the others go on appending to the run's.
	writing: bool,
	wbuf:    [dynamic]byte,
}

// Pieces per lane that may be answered and not yet printed, and the bytes printed and not yet written that hold
// the pieces after them back while a write is under way.
PIECES_IN_FLIGHT :: 2
HELD_AT :: 2 * FLUSH_AT

// Ready `po` to print `run`'s pieces, until `end_pieces`.
start_pieces :: proc(po: ^Piece_Output, run: ^Run) {
	po.run, po.stop = run, -1
	po.pieces.allocator = virtual.arena_allocator(&po.arena)
	po.spare.allocator = po.pieces.allocator
	reserve(&po.wbuf, cap(run.out))
}

end_pieces :: proc(po: ^Piece_Output) {
	virtual.arena_destroy(&po.arena)
	delete(po.wbuf)
}

// A copy of the run for piece `k`, whose output goes into a buffer of its own: a spare, or one with room for
// `size` bytes of answers. Copied under the lock, as another piece may be printing through the run.
//
// The piece waits while it is `PIECES_IN_FLIGHT` per lane ahead of the first piece not yet printed, and while a
// write is under way with `HELD_AT` bytes held behind it, so that the output held is a bounded count of pieces
// and bytes however slow the writer is. The first unprinted piece waits only for the writer, and every piece
// before `k` is claimed, so the wait ends when the write does.
begin_piece :: proc(po: ^Piece_Output, k, size: int) -> (run: Run) {
	sync.guard(&po.lock)
	window := PIECES_IN_FLIGHT * max(po.run.pool_width, 1)
	for po.stop < 0 && (k - po.printed >= window || po.writing && len(po.run.out) >= HELD_AT) {
		sync.cond_wait(&po.moved, &po.lock)
	}
	run = po.run^
	run.out = pop_safe(&po.spare) or_else make([dynamic]byte, 0, min(size, FLUSH_AT), po.pieces.allocator)
	run.held = true
	return
}

// Piece `k`, answered as `p`, and then the pieces now in turn printed. It returns false once a piece has left the
// rest to the main thread.
publish_piece :: proc(po: ^Piece_Output, k: int, p: Record_Piece) -> bool {
	sync.guard(&po.lock)
	if k >= len(po.pieces) {
		resize(&po.pieces, k + 1)
	}
	po.pieces[k] = p
	for ; po.stop < 0 && po.printed < len(po.pieces) && po.pieces[po.printed].done; po.printed += 1 {
		q := &po.pieces[po.printed]
		if q.answered {
			append(&po.run.out, ..q.out[:])
			po.run.ret = q.ret
			po.run.rows_begun = po.run.rows_begun || po.run.table != nil
		}
		clear(&q.out)
		append(&po.spare, q.out)
		po.stop = q.stop
	}
	sync.cond_broadcast(&po.moved)
	// The held output is written with the lock let go, so another piece can be printed meanwhile, and only by
	// one thread at a time, so that what is written stays in order.
	for !po.writing && output_due(po.run) {
		po.writing = true
		po.run.out, po.wbuf = po.wbuf, po.run.out
		sync.unlock(&po.lock)
		write_out(po.wbuf[:], worker = true, pool = &po.run.pool)
		clear(&po.wbuf)
		sync.lock(&po.lock)
		po.writing = false
		sync.cond_broadcast(&po.moved)
	}
	return p.stop < 0
}
