package main

// Many files answered on the threads of a pool. Tasks claim files one at a time through an atomic index and run each
// as the calling thread would, its writes held (`message.Held`) in its slot of a ring. Whichever task finishes the next
// file to write writes it and every finished file after it, holding a write token taken with an atomic, so the output,
// the messages and the exit status are a serial run's. A task runs no more than the ring's files ahead of the next to
// write: past that, or past HELD_BYTES held, it writes what it can and waits only when there is nothing to write. A
// file a task cannot answer alone (`File_Slot.serial`: a long one, which the pieces share, or one whose answer
// depends on the files before it) ends the call at it. The calling thread answers it on the serial route, and a new
// call goes on past it, the files tasks finished past it kept.

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import core "../../core"
import host "../../host"
import "../../jq"
import "message"

// The files the ring holds for each thread, and the stdout bytes the slots hold, past which only the next file to
// write goes on, writing through: together they bound the output held.
FILES_AHEAD :: 32
HELD_BYTES :: 64 << 20
// The least file left to the pieces of the serial route. A shorter one, read on its task's thread alone, costs less
// than ending a call for it while other files run.
FILES_LONG :: 4 << 20
// The buffer a slot keeps for the next file it holds, and the bytes written files gather in before a write.
SLOT_KEPT :: 1 << 16
WRITE_BYTES :: 1 << 16
// The address space a slot's stdout bytes past SLOT_KEPT reserve, which they grow in place in.
HELD_PAGES :: 1 << 30

File_Slot :: struct {
	held:    message.Held,
	code:    int, // the file's exit status, which `fold` takes, or under a filter run its last input's
	last:    int, // a filter run's: -e's last output, -1 for none
	text:    bool, // a filter run's: the file held a text
	serial:  bool, // left to the serial route
	rest:    bool, // left to the serial route with every file after it
	ends:    bool, // a filter run's: the file ends the run, on a fault
	explain: Explain, // a filter run's: the counts of the file's inputs
	changed: bool, // fmt's and edit's: --check found the file would change, or --in-place changed it
	done:    bool, // set last, once the fields above are the file's
}

Files_Call :: struct {
	run:     ^Run,
	files:   []string,
	// File `k` run on `r`, the calling run or a task's copy of it, its outcome in `slot`.
	job:     proc(fc: ^Files_Call, r: ^Run, k: int, slot: ^File_Slot),
	// File `k` answered on the calling thread after a task left it, nil for `job` there. True when the run ends there.
	serial:  proc(fc: ^Files_Call, k: int) -> bool,
	// Folds file `k`'s slot into the run's outcome, nil for the worst status in `code`.
	fold:    proc(fc: ^Files_Call, k: int, slot: ^File_Slot),
	data:    rawptr,
	code:    int,
	changed: int, // the files `File_Slot.changed` marks
	interp:  bool, // the tasks run the interpreter
	pool:    ^host.Pool,
	// The files are the walk's, which it may still be listing: `files` is its region, and `stop` is no bound on them
	// until the walk ends.
	streams: bool,
	slots:   []File_Slot, // file `k`'s is `k % len(slots)`
	// Shared between tasks, through atomics: the next file a task claims, the first it claims none at or past, and the
	// files before `written` written. `ended` says a fault ended the run at the file before `written`.
	next, stop, written: int,
	ended:   bool,
	held:    int, // the stdout bytes the slots hold
	// The write token's holder alone writes and folds slots, and owns `out`, the bytes of files written that wait for a
	// write of their own.
	token:   i32,
	out:     [dynamic]u8,
	flushes: bool, // stdout is a terminal, so the bytes go out each time the token is given back
	// Rung when `written` or `stop` moves while a task waits.
	bell:    sync.Futex,
	waiting: i32,
}

// The interpreter a thread's files run on, a copy of the run's (`jq.clone`).
@(private = "file", thread_local)
files_ip: jq.Interp

// The call and the file this thread's task holds the writes of.
@(private = "file", thread_local)
files_at: struct {
	fc: ^Files_Call,
	k:  int,
}

// The bytes of the file this thread's task runs, read before its job into the thread's buffer, which the job's open of
// that path takes (`task_bytes`).
@(private = "file", thread_local)
task_read: struct {
	path: string,
	data: []byte,
}
@(private = "file", thread_local)
task_buffer: [dynamic]byte

Short_Read :: enum u8 {
	Read,
	Long, // FILES_LONG or more, the pieces'
	Left, // to be opened as any file is
}

// A filter run over many files, its filter answering each input alone, answered file by file on the pool's threads.
// False when it is not: the filter or the options read across inputs, or the files are one stream (--seq), or one of
// them is stdin or a table, or the outputs are one table. A long file, a table, one that does not open, or one that
// opens with a byte order mark after a text is left to the serial route. A fault ends the run after its file.
stream_files :: proc(run: ^Run, ins: ^Inputs) -> bool {
	o := &run.opts
	if !walk_streams && len(ins.files) < 2 || o.threads == 1 || o.seq || o.follow || o.froms & {.Csv, .Tsv} != {} || writes_cells(o) || !parallel(run) {
		return false
	}
	for path in ins.files {
		if path == "-" {
			return false
		}
	}
	fc := Files_Call{run = run, files = ins.files, job = stream_file, serial = stream_serial, fold = stream_fold, data = ins, interp = true}
	each_file(&fc, true)
	ins.files = fc.files
	return true
}

// A filter run's file `k` answered alone, or left to the serial route.
@(private = "file")
stream_file :: proc(fc: ^Files_Call, r: ^Run, k: int, slot: ^File_Slot) {
	run_ins := (^Inputs)(fc.data)
	ins := new_clone(Inputs{source = run_ins.source, parsed = {line = 1}, files = fc.files[:k + 1], next_file = k, has_text = k > 0, many = true, run = r}, runtime.heap_allocator())
	defer free(ins, runtime.heap_allocator())
	if src, _ := file_source(&r.opts, fc.files[k], ins.source); reads_cells(&r.opts) || src.format == .Csv || src.format == .Tsv {
		slot.serial = true
		return
	}
	bind_inputs(&r.ip, ins)
	r.output.ret, r.output.last_result = min(int), -1
	r.route.explain = {on = r.route.on}
	run_inputs(r, ins)
	flush_some(&r.output, force = true)
	release_spent(ins)
	slot.code, slot.last, slot.text, slot.explain = r.output.ret, r.output.last_result, r.output.ret != min(int), r.route.explain
	slot.serial, slot.rest, slot.ends = ins.failures > 0 || ins.stray_bom, ins.failures > 0, ins.told != ""
}

// File `k`, which a task left, on the serial route, with every file after it when it did not open. True when the run
// ends there.
@(private = "file")
stream_serial :: proc(fc: ^Files_Call, k: int) -> bool {
	ins := (^Inputs)(fc.data)
	rest := fc.slots[k % len(fc.slots)].rest
	if rest && fc.streams {
		fc.files, fc.streams = walk_end(), false
	}
	ins.files, ins.next_file, ins.many = fc.files if rest else fc.files[:k + 1], k, true
	bind_inputs(&fc.run.ip, ins)
	run_inputs(fc.run, ins)
	ins.files = fc.files
	return rest || ins.failures > 0 || ins.told != "" || fc.run.halted
}

// The run's last input's status and -e's last output, from file `k`'s when it held an input.
@(private = "file")
stream_fold :: proc(fc: ^Files_Call, k: int, slot: ^File_Slot) {
	o := &fc.run.output
	if slot.code != min(int) {
		o.ret = slot.code
	}
	if slot.last >= 0 {
		o.last_result = slot.last
	}
	(^Inputs)(fc.data).has_text ||= slot.text
	r := &fc.run.route
	explain_add(r, slot.explain)
	r.input += slot.explain.input
	r.files += 1
}

// --each: each file a run of its own, on the pool's threads unless the filter halts or recurses, and the worst file's
// exit status in `run.output.ret`.
each_files :: proc(run: ^Run, ins: ^Inputs) {
	o := &run.opts
	fc := Files_Call{run = run, files = ins.files, job = each_one, data = ins, interp = true}
	each_file(&fc, run.shape.serial & {.Halts, .Recurses} == {} && o.max_depth <= core.MAX_DEPTH && !o.explain && !o.unbuffered)
	ins.files = fc.files
	run.output.ret = fc.code
}

// File `k` run on its own, its outputs labelled. A halt ends the process once the files before it are written.
@(private = "file")
each_one :: proc(fc: ^Files_Call, r: ^Run, k: int, slot: ^File_Slot) {
	path, heap := fc.files[k], runtime.heap_allocator()
	ins := new_clone(Inputs{source = (^Inputs)(fc.data).source, parsed = {line = 1}, files = fc.files[k:k + 1], name = file_name(path), many = fc.run.labels, slurp = r.opts.slurp, run = r}, heap)
	defer free(ins, heap)
	bind_inputs(&r.ip, ins)
	o := &r.output
	o.ret, o.result, o.last_result, o.parted_at = JQ_OK_NO_OUTPUT, JQ_OK_NO_OUTPUT, -1, -1
	// Each file's outputs are a table of their own.
	if o.table != nil {
		o.table = table_start(r)
	}
	l := current_label()
	if r.labels {
		l^ = {strings.concatenate({"\x1b[35m" if r.opts.color else "", ins.name, "\x1b[0m" if r.opts.color else "", ":"}, heap), !r.opts.join && !r.opts.seq, false}
	}
	defer {
		delete(l.text, heap)
		l^ = {}
	}
	if r.opts.null_input {
		run_once(r, nil)
	} else {
		run_inputs(r, ins)
	}
	table_end(o)
	flush_some(o, force = true)
	if l.open {
		put_stdout({'\n'})
	}
	release_spent(ins)
	slot.code = run_status(r, ins.failures)
	if r.halted {
		finish(r, o.ret)
	}
}

// The worse of two exit statuses: a file that did not open, then a fault, then -e's statuses, then success.
worse :: proc(a, b: int) -> int {
	rank :: proc(c: int) -> int {return 6 if c == EXIT_USAGE else c}
	return a if rank(a) >= rank(b) else b
}

// Runs every file of `fc`, on the pool's threads when `parallel` and there may be more than one. A walk that streams
// is read as it lists, and `fc.files` is every file once this returns.
each_file :: proc(fc: ^Files_Call, parallel: bool) {
	fc.streams = walk_streams
	if fc.streams {
		fc.files = walked.paths[:WALK_PATHS]
	}
	defer if fc.streams {
		fc.files, fc.streams = walk_end(), false
	}
	if !parallel || !fc.streams && len(fc.files) < 2 || fc.run.opts.threads == 1 {
		for k := 0; file_listed(fc, k); k += 1 {
			slot: File_Slot
			read_ahead(fc, k)
			fc.job(fc, fc.run, k, &slot)
			task_read = {}
			fold_slot(fc, k, &slot)
		}
		return
	}
	run_pool(fc.run)
	fc.pool = fc.run.pool
	fc.pool.steady = true
	defer fc.pool.steady = false
	heap := runtime.heap_allocator()
	fc.slots = make([]File_Slot, FILES_AHEAD * (fc.pool.runner.threads + 1), heap)
	for &s in fc.slots {
		s.held.out.allocator, s.held.marks.allocator = {held_pages, nil}, heap
	}
	fc.out.allocator, fc.flushes = heap, is_terminal(os.stdout)
	defer {
		for &s in fc.slots {
			delete(s.held.out)
			delete(s.held.marks)
		}
		delete(fc.slots, heap)
		delete(fc.out)
	}
	for !fc.ended && file_listed(fc, fc.written) {
		fc.stop = max(int) if fc.streams else len(fc.files)
		for k in fc.written ..< fc.next {
			if s := slot_of(fc, k); s.serial {
				fc.stop = k
				break
			}
		}
		fc.pool.runner.start(fc.pool.runner.data, fc.pool.runner.threads, files_task, fc)
		files_task(fc)
		fc.pool.runner.finish(fc.pool.runner.data)
		flush_written(fc)
		k := fc.written
		if fc.ended || !file_listed(fc, k) {
			break
		}
		s := slot_of(fc, k)
		if fc.serial != nil {
			if fc.serial(fc, k) {
				return
			}
		} else {
			slot: File_Slot
			fc.job(fc, fc.run, k, &slot)
			fold_slot(fc, k, &slot)
		}
		s.done = false
		fc.written = k + 1
		write_ready(fc)
		flush_written(fc)
	}
}

// Whether `fc` has a file `k`, waiting for a walk that streams to list it or end.
@(private = "file")
file_listed :: proc(fc: ^Files_Call, k: int) -> bool {
	if !fc.streams {
		return k < len(fc.files)
	}
	_, _, listed := walk_path(k)
	return listed
}

@(private = "file")
slot_of :: #force_inline proc(fc: ^Files_Call, k: int) -> ^File_Slot {
	return &fc.slots[k % len(fc.slots)]
}

@(private = "file")
fold_slot :: proc(fc: ^Files_Call, k: int, slot: ^File_Slot) {
	fc.changed += int(slot.changed)
	if fc.fold != nil {
		fc.fold(fc, k, slot)
	} else {
		fc.code = worse(fc.code, slot.code)
	}
}

// Claims files and runs them until none is left to claim.
@(private = "file")
files_task :: proc(arg: rawptr) {
	fc := (^Files_Call)(arg)
	values, temp, mapped := piece_arenas()
	if !mapped {
		return
	}
	context.allocator, context.temp_allocator = values, temp
	r := fc.run^
	if fc.interp {
		jq.clone(&fc.run.ip, &files_ip)
		r.ip = files_ip
	}
	init_output(&r.output, &r)
	for k in claim_file(fc) {
		run_file(fc, &r, k)
		free_all(values)
		free_all(temp)
	}
	if fc.interp {
		files_ip = r.ip
	}
}

// File `k` run into its slot, read first into the thread's buffer when it is a short regular file, or left to the
// serial route when it is long. Writes it and the files after it once it is the next to write.
@(private = "file")
run_file :: proc(fc: ^Files_Call, r: ^Run, k: int) {
	s := slot_of(fc, k)
	s.code, s.last, s.text, s.serial, s.rest, s.ends, s.changed = 0, 0, false, false, false, false, false
	if read_ahead(fc, k) == .Long {
		s.serial = true
	} else {
		message.holding, files_at = &s.held, {fc, k}
		fc.job(fc, r, k, s)
		message.holding, files_at, task_read = nil, {}, {}
	}
	if s.serial || s.ends {
		lower_stop(fc, k + int(!s.serial))
	}
	if s.serial {
		drop_held(fc, s)
	}
	sync.atomic_store(&s.done, true)
	write_ready(fc)
}

// File `k` read into the thread's buffer when the walk found it a regular file and it is short, for its job's open to
// take (`task_bytes`).
@(private = "file")
read_ahead :: proc(fc: ^Files_Call, k: int) -> (read: Short_Read) {
	#partial switch walk_kind(fc.files, k) {
	case .Long:
		return .Long
	case .File:
	case:
		return .Left
	}
	task_buffer.allocator = runtime.heap_allocator()
	task_read.data, read = read_short(fc.files[k], &task_buffer, FILES_LONG)
	task_read.path = fc.files[k] if read == .Read else ""
	return
}

// The bytes of `path` when it is the file this thread's task read before its job.
task_bytes :: proc(path: string) -> ([]byte, bool) {
	t := &task_read
	return t.data, t.path != "" && raw_data(t.path) == raw_data(path) && len(t.path) == len(path)
}

// Whether `data` is the thread's task buffer, which outlives the file read into it.
task_holds :: proc(data: []byte) -> bool {
	return task_buffer != nil && raw_data(data) == raw_data(task_buffer)
}

// The next file to run, once it is listed and within the ring of the next to write, or false when none is left to
// claim. A task that may claim none yet writes what is ready, or else waits. One file at a time: a claim costs nothing
// beside a file's open, and a run of files claimed together may hold a long one back.
@(private = "file")
claim_file :: proc(fc: ^Files_Call) -> (k: int, ok: bool) {
	for {
		stop, written: int
		k, stop, written = sync.atomic_load(&fc.next), sync.atomic_load(&fc.stop), sync.atomic_load(&fc.written)
		if k >= stop {
			return
		}
		if fc.streams {
			help_walk(k)
		}
		if !file_listed(fc, k) {
			lower_stop(fc, k)
			return
		}
		// Past HELD_BYTES held, only the next file to write starts.
		if k >= written + len(fc.slots) || k > written && sync.atomic_load(&fc.held) >= HELD_BYTES {
			if !write_ready(fc) {
				wait_written(fc, written, stop)
			}
			continue
		}
		if _, took := sync.atomic_compare_exchange_strong(&fc.next, k, k + 1); took {
			return k, true
		}
	}
}

// Lowers `fc.stop` to `to`, past which no task claims a file, and wakes the tasks that wait so they see it.
@(private = "file")
lower_stop :: proc(fc: ^Files_Call, to: int) {
	for {
		stop := sync.atomic_load(&fc.stop)
		if to >= stop {
			return
		}
		if _, took := sync.atomic_compare_exchange_strong(&fc.stop, stop, to); took {
			ring(fc)
			return
		}
	}
}

// Waits until `fc.written` or `fc.stop` moves from what the caller saw.
@(private = "file")
wait_written :: proc(fc: ^Files_Call, written, stop: int) {
	sync.atomic_add(&fc.waiting, 1)
	bell := sync.atomic_load(&fc.bell)
	if sync.atomic_load(&fc.written) == written && sync.atomic_load(&fc.stop) == stop {
		sync.futex_wait(&fc.bell, u32(bell))
	}
	sync.atomic_sub(&fc.waiting, 1)
}

@(private = "file")
ring :: proc(fc: ^Files_Call) {
	if sync.atomic_load(&fc.waiting) > 0 {
		sync.atomic_add(&fc.bell, 1)
		sync.futex_broadcast(&fc.bell)
	}
}

// Takes the write token, or false when another task holds it.
@(private = "file")
take_token :: #force_inline proc(fc: ^Files_Call) -> bool {
	_, took := sync.atomic_compare_exchange_strong(&fc.token, 0, 1)
	return took
}

// Writes the finished files that follow those written, up to one left to the serial route, unless another task holds
// the write token, which then writes them. True when it wrote one.
@(private = "file")
write_ready :: proc(fc: ^Files_Call) -> (wrote: bool) {
	for sync.atomic_load(&fc.token) == 0 && take_token(fc) {
		k := fc.written
		advanced := false
		for !fc.ended {
			s := slot_of(fc, k)
			if !sync.atomic_load(&s.done) || s.serial {
				break
			}
			put_slot(fc, s)
			fold_slot(fc, k, s)
			sync.atomic_store(&fc.ended, s.ends)
			sync.atomic_store(&s.done, false)
			k += 1
			sync.atomic_store(&fc.written, k)
			advanced = true
		}
		if fc.flushes {
			flush_written(fc)
		}
		sync.atomic_store(&fc.token, 0)
		if advanced {
			ring(fc)
		}
		wrote ||= advanced
		// A file finished after the look above and before the token was given back found it taken, so look again.
		s := slot_of(fc, k)
		if sync.atomic_load(&fc.ended) || !sync.atomic_load(&s.done) || s.serial {
			return
		}
	}
	return
}

// Writes slot `s` into the bytes written files gather, a message after those before it, and empties it.
@(private = "file")
put_slot :: proc(fc: ^Files_Call, s: ^File_Slot) {
	sync.atomic_sub(&fc.held, len(s.held.out))
	at := 0
	for m in s.held.marks {
		gather_written(fc, s.held.out[at:m.at])
		flush_written(fc)
		os.write_string(os.stderr, m.text)
		at = m.at
	}
	gather_written(fc, s.held.out[at:])
	message.write_held(&s.held, nil)
	if cap(s.held.out) > SLOT_KEPT {
		shrink(&s.held.out, 0)
	}
}

@(private = "file")
gather_written :: proc(fc: ^Files_Call, p: []byte) {
	if len(fc.out) + len(p) > WRITE_BYTES {
		flush_written(fc)
	}
	if len(p) >= WRITE_BYTES {
		write_through(p)
	} else {
		append(&fc.out, ..p)
	}
}

// Writes the bytes written files gather, by the token's holder or the calling thread between calls.
@(private = "file")
flush_written :: proc(fc: ^Files_Call) {
	if len(fc.out) > 0 {
		write_through(fc.out[:])
		clear(&fc.out)
	}
}

// `p` written to stdout from a thread whose writes are held.
@(private = "file")
write_through :: proc(p: []byte) {
	held, fc := message.holding, files_at.fc
	message.holding = nil
	if fc != nil {
		host.writing(fc.pool, true)
	}
	put_stdout(p)
	if fc != nil {
		host.writing(fc.pool, false)
	}
	message.holding = held
}

// Drops what slot `s` holds, for a file the serial route answers again.
@(private = "file")
drop_held :: proc(fc: ^Files_Call, s: ^File_Slot) {
	sync.atomic_sub(&fc.held, len(s.held.out))
	message.write_held(&s.held, nil)
}

// The allocator of a slot's stdout bytes: the heap's up to SLOT_KEPT, and past it pages of their own, in an address
// range reserved for HELD_PAGES that they grow in place in, given back when freed. The heap keeps a freed block that
// large for reuse, which the next slots' growing blocks do not reuse, and a block grown by copying holds both.
@(private = "file")
held_pages :: proc(_: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> (data: []byte, err: runtime.Allocator_Error) {
	heap := runtime.heap_allocator()
	big, was_big := size >= SLOT_KEPT, old_size >= SLOT_KEPT
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if big {
			pages := virtual.reserve(HELD_PAGES) or_return
			virtual.commit(raw_data(pages), uint(size)) or_return
			return pages[:size], nil
		}
	case .Free:
		if was_big {
			virtual.release(old, HELD_PAGES)
			return nil, nil
		}
	case .Resize, .Resize_Non_Zeroed:
		switch {
		case was_big && big && size <= HELD_PAGES:
			virtual.commit(old, uint(size)) or_return
			return ([^]byte)(old)[:size], nil
		case was_big || big:
			data = held_pages(nil, .Alloc_Non_Zeroed, size, alignment, nil, 0, loc) or_return
			copy(data, ([^]byte)(old)[:min(size, old_size)])
			held_pages(nil, .Free, 0, 0, old, old_size, loc)
			return
		}
	}
	return heap.procedure(heap.data, mode, size, alignment, old, old_size, loc)
}

// Counts `n` bytes a task's file added to what its slot holds. Past HELD_BYTES the task writes the files ready before
// its own or waits for them, and once its file is the next to write it writes what it holds through. A file past one
// the call leaves to the serial route does not wait, as that one is written only after the call.
held_more :: proc(n: int) {
	fc, k := files_at.fc, files_at.k
	if fc == nil || sync.atomic_add(&fc.held, n) + n < HELD_BYTES {
		return
	}
	for {
		written, stop := sync.atomic_load(&fc.written), sync.atomic_load(&fc.stop)
		if k >= stop || sync.atomic_load(&fc.held) < HELD_BYTES {
			return
		}
		if written == k {
			// The token's holder has written the files before this one and is giving it back.
			for !take_token(fc) {
				thread.yield()
			}
			put_slot(fc, slot_of(fc, k))
			flush_written(fc)
			sync.atomic_store(&fc.token, 0)
			return
		}
		if !write_ready(fc) {
			wait_written(fc, written, stop)
		}
	}
}
