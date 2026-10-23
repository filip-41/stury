package main

// The batch pool: the threads a large input's pieces are read, built and printed on, and the claims that
// share a job's pieces among them.

import "core:mem/virtual"
import "core:os"
import "core:sync"
import host "../../host"
import json "../../json"

// Input bytes per worker of a record batch: 320 KiB for each of the first four workers, 1 MiB for each one after.
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

// The output of one piece of a job (`Piece_Output`).
Record_Piece :: struct {
	out:      [dynamic]byte,
	ret:      int, // jq's exit result for the piece's last record with an output
	answered: bool,
	records:  int, // records the piece completed, excluding the one it stopped at
	done:     bool,
	stop:     int, // where (JSON: an offset) or why (CSV: a `*_STOP` code) the main thread takes over, or -1
}

// The output of a job's pieces from `json.each_record` or `csv.each_record`. Each piece prints into its own buffer.
// A buffer is written once every earlier piece has been written.
Piece_Output :: struct {
	run:     ^Run,
	// `pieces` is indexed by the library's piece number. Pieces are appended to the output in order, up to the
	// first piece that hands off to the main thread; `stop` is its stop value, or -1. A written piece's buffer is
	// reused for a later piece.
	lock:    sync.Mutex,
	// Signalled when `printed` advances or `stop` is set, to wake a piece waiting in `begin_piece`.
	moved:   sync.Cond,
	arena:   virtual.Arena,
	pieces:  [dynamic]Record_Piece,
	spare:   [dynamic][dynamic]byte,
	printed: int,
	stop:    int,
	// The record count of the pieces appended so far. For an object table, `keys` is the header written before
	// the first output while `table_due` is set.
	records:   int,
	table_due: bool,
	keys:      []string,
	// The output being written while the lock is released. The thread that set `writing` swaps the pending output
	// into `wbuf`, so only one thread writes at a time and output stays in order. Other threads keep appending to
	// the run's output.
	writing: bool,
	wbuf:    [dynamic]byte,
}

// `PIECES_IN_FLIGHT` is the number of pieces per lane that may be finished but not yet appended. `HELD_AT` is the
// number of appended, unwritten bytes at which later pieces wait for a write in progress.
PIECES_IN_FLIGHT :: 2
HELD_AT :: 2 * FLUSH_AT

// Prepares `po` to print `run`'s pieces until `end_pieces`.
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

// Returns a copy of the run for piece `k`, with its own output buffer: a spare, or a new one with room for `size`
// bytes. The copy is made under the lock, because another piece may be appending through the run.
//
// The piece waits while it is `PIECES_IN_FLIGHT` per lane ahead of the first unappended piece, and while a write
// is in progress with `HELD_AT` bytes pending. This bounds the held output in pieces and bytes, however slow the
// writer is. The first unappended piece waits only for the writer, and every piece before `k` is already claimed,
// so the wait ends when the write does.
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

// Stores piece `k`'s result `p`, then appends and writes every piece whose turn has come. Returns false once a
// piece has handed the rest of the input to the main thread.
publish_piece :: proc(po: ^Piece_Output, k: int, p: Record_Piece) -> bool {
	sync.guard(&po.lock)
	if k >= len(po.pieces) {
		resize(&po.pieces, k + 1)
	}
	po.pieces[k] = p
	for ; po.stop < 0 && po.printed < len(po.pieces) && po.pieces[po.printed].done; po.printed += 1 {
		q := &po.pieces[po.printed]
		po.records += q.records
		if q.answered {
			if po.table_due {
				po.table_due = false
				open_object_table(po.run, po.keys)
			}
			append(&po.run.out, ..q.out[:])
			po.run.ret = q.ret
			po.run.rows_begun = po.run.rows_begun || po.run.table != nil
		}
		clear(&q.out)
		append(&po.spare, q.out)
		po.stop = q.stop
	}
	sync.cond_broadcast(&po.moved)
	// The pending output is written with the lock released, so other pieces can append meanwhile. Only one thread
	// writes at a time, which keeps the output in order.
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
