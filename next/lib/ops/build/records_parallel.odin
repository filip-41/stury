package build

import "base:runtime"
import "core:sync"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Parallel batch runner for independent-record framings (`.Lines`, `.Seq`, DSV rows) over `Options.runner`.
// Guarantees identical records, errors, order, `Records.index`, `Records.pos`, and `Budget` behavior to serial runs,
// falling back to serial on `pieces != nil`, short inputs, `runner == nil`, or quote-parity drift (`astray`).

// Maximum byte chunks per parallel batch call (kept on the stack so planning allocates nothing).
MAX_RECORD_CHUNKS :: 128

// Minimum remaining bytes to engage parallel records execution. Respects `BUILD_PARALLEL_FROM` when set lower for tests.
parallel_records_from :: #force_inline proc "contextless" () -> int {
	return min(PARALLEL_FROM, 1 << 17)
}

// One byte range of a parallel records batch and its per-chunk results.
Record_Chunk :: struct {
	lo, hi:  u64,
	count:   u64, // records in chunk (or processed by validate)
	offset:  int, // starting output slot for find/scan
	limit:   int, // max records this chunk may write for find/scan
	done:    int, // actual records written for find/scan
	end_pos: u64, // `Records.pos` after the records this chunk processed
	fatal:   tape.Error,
	astray:  bool, // chunk boundary assumption failed (e.g. unclosed CSV quote); caller finishes serially from `lo`
}

// A bad record captured by a parallel validate chunk, with exact cursor state right after it for partial-batch resume.
Bad_Entry :: struct {
	rec:         tape.Record,
	index_after: u64,
	pos_after:   u64,
}

// Mutex-guarded wrapper around a caller allocator so worker threads serialize rare chunk/scratch allocations.
Locked_Allocator :: struct {
	lock:    sync.Mutex,
	backing: runtime.Allocator,
}

locked_allocator :: proc "contextless" (l: ^Locked_Allocator) -> runtime.Allocator {
	return {locked_alloc_proc, l}
}

@(private)
locked_alloc_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	l := (^Locked_Allocator)(data)
	sync.mutex_guard(&l.lock)
	return l.backing.procedure(l.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// Wraps `r.opts.scratch` in `l` when set so parallel workers never touch an unlocked caller scratch allocator.
@(private)
locked_scratch_of :: proc "contextless" (r: ^tape.Records, l: ^Locked_Allocator) -> runtime.Allocator {
	if r.opts.scratch.procedure == nil {
		return {}
	}
	l.backing = r.opts.scratch
	return locked_allocator(l)
}

// Cuts `src[pos:]` into non-empty chunks separated at `delim` (every chunk past the first starts 1 byte past `delim`).
cut_delim_chunks :: proc "contextless" (src: []u8, pos: u64, delim: u8, runner: ^tape.Runner, chunks: []Record_Chunk) -> (nc: int) #no_bounds_check {
	n := u64(len(src))
	if pos >= n {
		return 0
	}
	rem := n - pos
	want := min(chunk_count(runner, int(min(rem, u64(max(int))))), len(chunks))
	if want < 2 {
		return 0
	}
	lo := pos
	for k in 0 ..< want {
		hi := n
		if k < want - 1 {
			target := pos + rem * u64(k + 1) / u64(want)
			if target <= lo {
				continue
			}
			if i := kernel.index_byte(src[target:], delim); i >= 0 {
				hi = target + u64(i) + 1
			} else {
				hi = n
			}
		}
		if hi > lo {
			chunks[nc] = {lo = lo, hi = hi, end_pos = hi}
			nc += 1
			lo = hi
		}
		if lo >= n {
			break
		}
	}
	return nc
}

// Validates `chunks` in parallel and merges bad records into `out` in source order. Returns `(n, done)` where `done`
// false means a chunk went `astray` and the caller should finish serially from the updated `r.pos`.
records_validate_chunks :: proc(r: ^tape.Records, out: []tape.Record, chunks: []Record_Chunk, caller: runtime.Allocator, data: rawptr, run_chunk: proc(data: rawptr, chunk: ^Record_Chunk, k: int, max_bad: int, bad_out: ^[dynamic]Bad_Entry, alloc, scratch: runtime.Allocator)) -> (n: int, done: bool) {
	nc := len(chunks)
	if nc < 2 || nc > MAX_RECORD_CHUNKS {
		return 0, false
	}
	scratch_base := r.opts.scratch if r.opts.scratch.procedure != nil else caller
	locked := Locked_Allocator{backing = scratch_base}
	alloc := locked_allocator(&locked)
	scratch := alloc if r.opts.scratch.procedure != nil else runtime.Allocator{}
	bads: [MAX_RECORD_CHUNKS][dynamic]Bad_Entry
	for k in 0 ..< nc {
		bads[k].allocator = alloc
	}
	defer {
		for k in 0 ..< nc {
			delete(bads[k])
		}
	}
	Job :: struct {
		data:      rawptr,
		chunks:    []Record_Chunk,
		bads:      [][dynamic]Bad_Entry,
		max_bad:   int,
		alloc:     runtime.Allocator,
		scratch:   runtime.Allocator,
		run_chunk: proc(data: rawptr, chunk: ^Record_Chunk, k: int, max_bad: int, bad_out: ^[dynamic]Bad_Entry, alloc, scratch: runtime.Allocator),
	}
	task :: proc(arg: rawptr, k: int) {
		j := (^Job)(arg)
		j.run_chunk(j.data, &j.chunks[k], k, j.max_bad, &j.bads[k], j.alloc, j.scratch)
	}
	job := Job{data = data, chunks = chunks, bads = bads[:nc], max_bad = len(out), alloc = alloc, scratch = scratch, run_chunk = run_chunk}
	hook.fan_each(r.opts.runner, nc, task, &job)
	for &c, k in chunks {
		if c.astray {
			r.pos = c.lo
			r.at = .Open
			return n, false
		}
		b := bads[k][:]
		take := min(len(b), len(out) - n)
		// Pre-reserve quarantine storage before emitting so an OOM never desyncs `r.index`/`r.pos` from `out`.
		if r.quarantine != nil && take > 0 {
			if err := reserve(r.quarantine, len(r.quarantine) + take); err != nil {
				records_stop(r, err)
				return n, true
			}
		}
		base_index := r.index
		for entry in b[:take] {
			if !quarantine_record(r, entry.rec) {
				return n, true
			}
			out[n] = entry.rec
			n += 1
			r.index = base_index + entry.index_after
			r.pos = entry.pos_after
		}
		if len(b) > take {
			r.at = .Open
			return n, true
		}
		r.index = base_index + c.count
		r.pos = c.end_pos
		if c.fatal != nil {
			records_stop(r, c.fatal)
			return n, true
		}
		if n == len(out) {
			r.at = .Done if r.pos >= u64(len(r.src)) else .Open
			return n, true
		}
	}
	r.pos = u64(len(r.src))
	r.at = .Done
	return n, true
}

// Counts records per chunk in parallel and assigns output slots up to `cap`.
@(private)
count_and_plan :: proc(runner: ^tape.Runner, chunks: []Record_Chunk, cap: int, data: rawptr, count_chunk: proc(data: rawptr, chunk: ^Record_Chunk, k: int)) -> (active, total: int) {
	Count_Job :: struct {
		data:        rawptr,
		chunks:      []Record_Chunk,
		count_chunk: proc(data: rawptr, chunk: ^Record_Chunk, k: int),
	}
	count_task :: proc(arg: rawptr, k: int) {
		j := (^Count_Job)(arg)
		j.count_chunk(j.data, &j.chunks[k], k)
	}
	cj := Count_Job{data = data, chunks = chunks, count_chunk = count_chunk}
	hook.fan_each(runner, len(chunks), count_task, &cj)
	return plan_chunk_slots(chunks, cap)
}

// Runs `records_find` across `chunks` in parallel, writing directly into `out` and `answers`. Returns `(n, done)` where
// `done` false means a chunk went `astray` and the caller should finish the remaining slots serially from `r.pos`.
records_find_chunks :: proc(r: ^tape.Records, format: ^tape.Format, path: []tape.Step, chunks: []Record_Chunk, cap: int, caller: runtime.Allocator, data: rawptr, count_chunk: proc(data: rawptr, chunk: ^Record_Chunk, k: int), run_chunk: proc(data: rawptr, chunk: ^Record_Chunk, k: int, alloc, scratch: runtime.Allocator)) -> (n: int, done: bool) {
	if _, refused := find_path(format, r.opts, path); refused != nil {
		return 0, false
	}
	nc := len(chunks)
	if nc < 2 || nc > MAX_RECORD_CHUNKS || cap < 64 {
		return 0, false
	}
	active, total := count_and_plan(r.opts.runner, chunks, cap, data, count_chunk)
	if active < 2 || total < 64 {
		return 0, false
	}
	locked := Locked_Allocator{backing = caller}
	alloc := locked_allocator(&locked)
	locked_scratch: Locked_Allocator
	scratch := locked_scratch_of(r, &locked_scratch)
	Run_Job :: struct {
		data:      rawptr,
		chunks:    []Record_Chunk,
		alloc:     runtime.Allocator,
		scratch:   runtime.Allocator,
		run_chunk: proc(data: rawptr, chunk: ^Record_Chunk, k: int, alloc, scratch: runtime.Allocator),
	}
	run_task :: proc(arg: rawptr, k: int) {
		j := (^Run_Job)(arg)
		j.run_chunk(j.data, &j.chunks[k], k, j.alloc, j.scratch)
	}
	rj := Run_Job{data = data, chunks = chunks[:active], alloc = alloc, scratch = scratch, run_chunk = run_chunk}
	hook.fan_each(r.opts.runner, active, run_task, &rj)
	return settle_chunk_slots(r, chunks[:active], active == nc)
}

// Runs `records_scan` across `chunks` in parallel, each chunk building into its own `tape.Record_Block` whose chunks
// are adopted into `r.block` on the calling thread before returning.
records_scan_chunks :: proc(r: ^tape.Records, format: ^tape.Format, demand: ^tape.Demand, docs: []tape.Document, chunks: []Record_Chunk, cap: int, caller: runtime.Allocator, data: rawptr, count_chunk: proc(data: rawptr, chunk: ^Record_Chunk, k: int), run_chunk: proc(data: rawptr, chunk: ^Record_Chunk, k: int, block: ^tape.Record_Block, batch_alloc, scratch: runtime.Allocator)) -> (n: int, done: bool) {
	if scan_refused(format, r.opts, demand) != nil {
		return 0, false
	}
	nc := len(chunks)
	if nc < 2 || nc > MAX_RECORD_CHUNKS || cap < 64 {
		return 0, false
	}
	active, total := count_and_plan(r.opts.runner, chunks, cap, data, count_chunk)
	if active < 2 || total < 64 {
		return 0, false
	}
	batch_alloc := tape.record_block_batch(&r.block, caller)
	locked := Locked_Allocator{backing = caller}
	backing := locked_allocator(&locked)
	locked_scratch: Locked_Allocator
	scratch := locked_scratch_of(r, &locked_scratch)
	blocks: [MAX_RECORD_CHUNKS]tape.Record_Block
	for k in 0 ..< active {
		blocks[k].backing = backing
		blocks[k].outgrown.allocator = backing
		blocks[k].last = -1
	}
	Run_Job :: struct {
		data:        rawptr,
		chunks:      []Record_Chunk,
		blocks:      []tape.Record_Block,
		batch_alloc: runtime.Allocator,
		scratch:     runtime.Allocator,
		run_chunk:   proc(data: rawptr, chunk: ^Record_Chunk, k: int, block: ^tape.Record_Block, batch_alloc, scratch: runtime.Allocator),
	}
	run_task :: proc(arg: rawptr, k: int) {
		j := (^Run_Job)(arg)
		j.run_chunk(j.data, &j.chunks[k], k, &j.blocks[k], j.batch_alloc, j.scratch)
	}
	rj := Run_Job{data = data, chunks = chunks[:active], blocks = blocks[:active], batch_alloc = batch_alloc, scratch = scratch, run_chunk = run_chunk}
	hook.fan_each(r.opts.runner, active, run_task, &rj)
	// Pre-reserve `r.block.outgrown` before adopting any chunk so an OOM never frees memory a returned Document points into.
	need_chunks := 0
	for k in 0 ..< active {
		if blocks[k].chunk != nil {
			need_chunks += 1
		}
		need_chunks += len(blocks[k].outgrown)
	}
	if err := reserve(&r.block.outgrown, len(r.block.outgrown) + need_chunks); err != nil {
		for k in 0 ..< active {
			b := &blocks[k]
			if b.chunk != nil {
				runtime.mem_free_with_size(raw_data(b.chunk), len(b.chunk), caller)
			}
			for c in b.outgrown {
				runtime.mem_free_with_size(raw_data(c), len(c), caller)
			}
			delete(b.outgrown)
		}
		for i in 0 ..< min(total, len(docs)) {
			docs[i] = {}
		}
		records_stop(r, err)
		return 0, true
	}
	// Adopt every worker block's allocated chunks into `r.block.outgrown` so the next batch or `destroy_records` frees them.
	for k in 0 ..< active {
		b := &blocks[k]
		if b.chunk != nil {
			append(&r.block.outgrown, b.chunk)
			r.block.spent += b.used
		}
		for c in b.outgrown {
			append(&r.block.outgrown, c)
		}
		r.block.spent += b.spent
		delete(b.outgrown)
	}
	return settle_chunk_slots(r, chunks[:active], active == nc)
}

// Assigns `offset` and `limit` per chunk from `count`, stopping once `cap` slots are filled.
@(private)
plan_chunk_slots :: proc "contextless" (chunks: []Record_Chunk, cap: int) -> (active, total: int) {
	for &c, k in chunks {
		if total >= cap {
			break
		}
		take := int(min(c.count, u64(cap - total)))
		c.offset = total
		c.limit = take
		total += take
		active = k + 1
	}
	return
}

// Finalizes `r.index`, `r.pos`, and `r.at` after a parallel find/scan batch.
@(private)
settle_chunk_slots :: proc "contextless" (r: ^tape.Records, chunks: []Record_Chunk, reached_end: bool) -> (n: int, done: bool) {
	for c in chunks {
		if c.astray {
			r.pos = c.lo
			r.at = .Open
			return n, false
		}
		n += c.done
		r.index += u64(c.done)
		r.pos = c.end_pos
		if c.fatal != nil {
			records_stop(r, c.fatal)
			return n, true
		}
		if c.done < c.limit {
			// Stopped early inside this chunk.
			return n, true
		}
	}
	if reached_end && r.pos >= u64(len(r.src)) {
		r.pos = u64(len(r.src))
		r.at = .Done
	} else {
		r.at = .Open
	}
	return n, true
}
