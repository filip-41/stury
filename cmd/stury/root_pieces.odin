package main

// Reads a large input that is one big root array in parallel: the library cuts the array into pieces
// (`json.split_array`), and each piece is built, printed or scanned on the batch pool, so a single document gets the
// speed of many records.
//
// The root is an array, or an object with one in its spine (`{"logs": [...]}`, `{"version": 1, "logs": [...]}`,
// `{"data": {"logs": [...]}}`). A piece, framed in brackets, is an array of its own whose `[` stands for the
// spine's. The objects around the array are the frame's (see `root_spine`).
//
// The cuts are only right for well-formed input. That needs no proof here: each piece must read with at least one
// entry, and the pieces hold exactly the array's entries, so a wrong cut always fails some piece, and a failure
// leaves the text to `build_rows` whole, which reports what jq would.

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import core_pkg "../../core"
import json "../../json"
import "jq"

// A piece's caps: the reader's, with nesting `levels` less, as many objects as sit above the spine's array, whose
// `[` the piece's stands for. So a piece that reads holds no nesting the whole text's would refuse.
@(private)
piece_limits :: proc(levels: int) -> json.Limits {
	limits := jq.lifted
	limits.max_depth -= u64(levels)
	return limits
}

Root_Job :: struct {
	src:       []byte,
	pieces:    []json.Piece,
	limits:    json.Limits, // each piece's (`piece_limits`)
	counts:    []int, // each piece's entries, then where they start in the array
	// `build_array_pieces`: each piece's rows, in `allocator`, and the array's entries, each a row of one.
	docs:      []json.Document,
	allocator: runtime.Allocator,
	items:     []jq.Value,
	uncounted: bool, // for `demanded_array_pieces`: the pieces' entries are left to `count_end`
	// For `print_root_pieces`: how the pieces are laid out, how deep the array is, and each piece's text.
	validate:  bool, // whether each piece is validated before it is printed
	layout:    jq.Layout,
	depth:     int,
	levels:    int, // the objects the array sits in (`Root_Spine`)
	outs:      [][dynamic]byte, // piece k's printed text, set once `ready[k]`, until it is written
	// Also `print_root_pieces`: pieces are written in order. `ready[k]` is whether piece k's text is in
	// `outs`, `next` is the first piece not yet written, and `writing` is whether a thread is writing (only
	// one does, so the order holds). `lock` guards all three.
	lock:      sync.Mutex,
	ready:     []bool,
	next:      int,
	writing:   bool,
	// For `iterate_root_pieces`: the run each piece prints through a copy of, the paths it is scanned for, and
	// jq's result for its last output.
	run:       ^Run,
	paths:     []json.Path,
	rets:      []int,
	// With a `limit(N; P)` or `first(P)` (the path's `limit`): `limit` is the most outputs wanted, and
	// `ends[k]` where piece k's first outputs end in its `outs[k]`, so the last piece written can be cut after
	// the N-th.
	limit:     int,
	ends:      [][]int,
}

// The text data[at:], when it has a spine (`root_spine`) whose array is of at least two batch workers' worth, read in
// pieces in parallel. It returns false when it has none or a piece fails. With `prog`, the root it reads: one with
// only the entries `jq.entry_demand` finds it reads built, and every other entry null, when it finds them.
build_root_pieces :: proc(run: ^Run, data: []byte, at: int, prog: ^jq.Node = nil) -> (v: jq.Value, ok: bool) {
	spine := root_spine(data, at) or_return
	if demand, some := jq.entry_demand(prog, spine.keys[:spine.levels]); some {
		explain_demand(run, demand)
		v, ok = demanded_array_pieces(run, data, spine.lo, spine.z, spine.levels, demand)
	} else {
		v, ok = build_array_pieces(run, data, spine.lo, spine.z, spine.levels)
	}
	if !ok {
		spine_free(&spine)
		return
	}
	explain_piece(run, .Root)
	items, _ := v.(^jq.Array)
	run.pieces_root = {rawptr(items), rawptr(items), data[at:], data[spine.lo:spine.z + 1]}
	if spine.levels == 0 {
		return
	}
	// From the array out, each object the frame's with the one inside it for its member, which keeps its place.
	frame := new_clone(spine.frame)
	objects: [json.SPINE_LEVELS]json.Node
	n := json.ROOT
	for i in 0 ..< spine.levels {
		objects[i] = n
		n = json.child(frame, n, spine.keys[i])
	}
	for i := spine.levels - 1; i >= 0; i -= 1 {
		o := jq.own(jq.Ref{frame, objects[i]}).(^jq.Object)
		jq.object_put(o, spine.keys[i], v)
		v = o
	}
	run.pieces_root.root = v.(^jq.Object)
	return
}

// The filter run on the text data[at:], read by `build_root_pieces` into `arena`, which is emptied first, false, with
// nothing run, when the text is not one it reads, or is under four workers' worth, which one thread's scan reads
// sooner.
run_root_pieces :: proc(run: ^Run, data: []byte, at: int, arena: ^virtual.Arena) -> bool {
	if len(data) - at < 4 * BATCH_BYTES_PER_FIRST_WORKERS {
		return false
	}
	ready_interpreter(run)
	virtual.arena_free_all(arena)
	context.allocator = virtual.arena_allocator(arena)
	// A `select` reads its path alone, and prints the root from the text when it keeps it.
	reads := run.prog.args[0].a if run.select.op != .None else run.prog
	v := build_root_pieces(run, data, at, reads) or_return
	explain_interpreted(run)
	run_once(run, v)
	return true
}

// The array data[at:z + 1], `[` to `]`, of at least two batch workers' worth, as an array of its entries, built in
// pieces in parallel. It returns false when it is not one or a piece fails.
@(private = "file")
build_array_pieces :: proc(run: ^Run, data: []byte, at, z: int, levels: int) -> (v: jq.Value, ok: bool) {
	job, runner := array_pieces(run, data, at, z, levels) or_return
	defer {
		delete(job.pieces)
		delete(job.counts)
	}
	job.allocator = context.allocator
	job.docs = json.pieces_docs(data, job.pieces, build_piece, &job, runner, context.allocator) or_return
	// Each piece's entries go to the root's items from the count of those before it, written on the threads
	// that built them, whose caches hold the rows.
	job.counts = make([]int, len(job.docs))
	n := 0
	for &d, k in job.docs {
		job.counts[k] = n
		n += json.child_count(&d, json.ROOT)
	}
	root := jq.new_array(n)
	non_zero_resize(&root.items, n)
	job.items = root.items[:]
	core_pkg.piece_fan(runner, len(job.docs), fill_items, &job)
	return root, true
}

@(private = "file")
build_piece :: proc(job: ^Root_Job, text: []byte) -> (json.Document, Maybe(json.Error)) {
	return jq.build_rows(text, limits = job.limits, allocator = job.allocator)
}

// Piece `k`'s entries, put in `items` from its first.
@(private = "file")
fill_items :: proc(job: ^Root_Job, k: int, _: ^[dynamic]byte) -> bool {
	d := &job.docs[k]
	at := job.counts[k]
	it := json.children(d, json.ROOT)
	for row in json.children(&it) {
		job.items[at] = jq.Ref{d, row}
		at += 1
	}
	return true
}

// The array data[at:z + 1], `[` to `]`, of at least two batch workers' worth, with only `demand`'s entries built and
// every other entry null: each piece is validated and its entries counted in parallel (or, when the program reads one
// end alone, only that end's, after; see `count_end`), and then the entries demanded are found and built alone. It
// returns false when it is not one or a piece is not well-formed.
@(private = "file")
demanded_array_pieces :: proc(run: ^Run, data: []byte, at, z: int, levels: int, demand: jq.Entry_Demand) -> (v: jq.Value, ok: bool) {
	// Validating a piece is quicker than building it, so more threads share it.
	job, runner := array_pieces(run, data, at, z, levels, BATCH_BYTES_PER_WORKER / 2) or_return
	job.counts = make([]int, len(job.pieces))
	defer {
		delete(job.pieces)
		delete(job.counts)
	}
	// Entries read from one end only, and not how many there are: the array is that end's pieces, up to the
	// demanded entries, and the others go uncounted.
	job.uncounted = !demand.counted && (demand.head == 0 || demand.tail == 0)
	if !core_pkg.piece_fan(runner, len(job.pieces), count_entries, &job) {
		return
	}
	if job.uncounted {
		count_end(&job, max(demand.head, demand.tail), from_back = demand.tail > 0)
	}
	n := 0
	for &f in job.counts {
		f, n = n, n + f
	}
	root := jq.new_array(n)
	// An arena's memory is zero, null's bits: left so, it is not touched until an entry is read.
	if context.allocator.procedure == virtual.arena_allocator_proc {
		non_zero_resize(&root.items, n)
	} else {
		resize(&root.items, n)
	}
	scratch := make([dynamic]byte, runtime.heap_allocator())
	defer delete(scratch)
	for i := 0; i < n; i += 1 {
		if i == demand.head {
			i = max(i, n - demand.tail)
			if i == n {
				break
			}
		}
		root.items[i] = build_entry(&job, i, &scratch) or_return
	}
	return root, true
}

// Piece `k`'s entries, counted into `counts`. It returns false when it is not well-formed.
@(private = "file")
count_entries :: proc(job: ^Root_Job, k: int, scratch: ^[dynamic]byte) -> bool {
	text, _ := json.frame_entries(job.src, job.pieces[k], scratch) or_return
	if json.validate(text, {limits = job.limits}) != nil {
		return false
	}
	if !job.uncounted {
		job.counts[k] = entry_count(text)
	}
	return true
}

// How many entries the array text `text` holds.
@(private)
entry_count :: proc(text: []byte) -> (n: int) {
	it := json.records(text, {framing = .Root_Entries})
	for _ in json.next_record(&it) {
		n += 1
	}
	return
}

// The pieces from the array's front, or its back, counted into `counts` until they hold `want` entries. The pieces
// past them count none, so the array is that end's entries alone, as many as its reader asks for.
@(private = "file")
count_end :: proc(job: ^Root_Job, want: int, from_back: bool) {
	have := 0
	scratch := make([dynamic]byte, runtime.heap_allocator())
	defer delete(scratch)
	for j in 0 ..< len(job.pieces) {
		k := len(job.pieces) - 1 - j if from_back else j
		if have >= want {
			job.counts[k] = 0
			continue
		}
		text, _, _ := json.frame_entries(job.src, job.pieces[k], &scratch)
		job.counts[k] = entry_count(text)
		have += job.counts[k]
	}
}

// Entry `i` of the array whose pieces `job` counted, found in its piece and built alone from the source.
@(private = "file")
build_entry :: proc(job: ^Root_Job, i: int, scratch: ^[dynamic]byte) -> (v: jq.Value, ok: bool) {
	k := len(job.counts) - 1
	for job.counts[k] > i {
		k -= 1
	}
	text, shift := json.frame_entries(job.src, job.pieces[k], scratch) or_return
	it := json.records(text, {framing = .Root_Entries})
	rec: json.Record
	for _ in 0 ..= i - job.counts[k] {
		rec = json.next_record(&it) or_return
	}
	lo := shift + int(rec.at)
	d := new(json.Document)
	err: Maybe(json.Error)
	d^, err = jq.build_rows(job.src[lo:lo + len(rec.bytes)])
	return jq.Ref{d, json.ROOT}, err == nil
}

// The array data[at:z + 1], `[` to `]`, of at least two batch workers' worth, cut into pieces on the pool. It returns
// false when it is not one or the cut would not pay (`json.split_array`).
@(private)
array_pieces :: proc(run: ^Run, data: []byte, at, z: int, levels: int, per := BATCH_BYTES_PER_WORKER) -> (job: Root_Job, runner: ^json.Batch_Runner, ok: bool) {
	if u64(z - at) >= json.MAX_ROW_SOURCE {
		return
	}
	// A text followed by others in its window runs to the window's last `]` only in its guess, and a cut of it,
	// which fails, costs about the bytes up to there. So the texts before that `]` would pay it once each: once a
	// cut to it is tried, another is tried only from half way there, and the cuts to one `]` cost about twice
	// the first. A large array within that half is read whole.
	open, close := uintptr(rawptr(&data[at])), uintptr(rawptr(&data[z]))
	if close == run.cut.close && open < run.cut.again {
		return
	}
	runner = batch_runner(run, z - at, per)
	if runner == nil {
		return
	}
	// A value inside the last cut's span, printed alone, leaves it.
	if open < run.cut.open || close >= run.cut.close {
		run.cut = {open, close, open + (close - open) / 2}
	}
	job = Root_Job{src = data, levels = levels, limits = piece_limits(levels)}
	job.pieces = json.split_array(data, at, z + 1, runner, context.allocator) or_return
	return job, runner, true
}
