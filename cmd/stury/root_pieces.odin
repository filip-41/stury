package main

// Reads a large input that is one big root array in parallel: it cuts the array into pieces at commas and
// builds, prints or scans each piece on the batch pool, so a single document gets the speed of many records.
//
// The root is an array, or an object with one in its spine (`{"logs": [...]}`, `{"version": 1, "logs": [...]}`,
// `{"data": {"logs": [...]}}`). `json.each_record` hands out the array's entries in pieces, and the commas on either
// side of each piece's first entry, but the first piece's, are the cuts. While the pieces build, the first of the two
// stands in as the `]` that closes the entries before it and the second as the `[` that opens those after it, and the
// one entry between them is built alone. The array is then one of every piece's entries, and the objects around it
// are the frame's (see `root_spine`).
//
// The commas are only right for well-formed input. That needs no proof here: each array piece must build
// with at least one entry, and each lone entry as one text, and pieces that do concatenate to exactly the
// root array, so a wrong cut always fails some piece, and a failure leaves the text to `build_rows` whole,
// which reports what jq would.

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import json "../../json"
import index "../../json/scan/index"
import "jq"

// A chunk's caps: the reader's, with nesting `levels` less, as many as sit above the chunk's own text: an array
// chunk's `[` stands for the spine array's, so it has the spine's objects above it. A lone entry has the array above
// it too. So a chunk that builds holds no nesting the whole text's would refuse.
@(private)
chunk_limits :: proc(levels: int) -> json.Limits {
	limits := jq.lifted
	limits.max_depth -= u64(levels)
	return limits
}

// The levels above chunk `c`, for `chunk_limits`.
@(private)
chunk_levels :: proc(job: ^Root_Job, c: Root_Chunk) -> int {
	return job.levels + 1 if c.alone else job.levels
}

// About how many bytes apart the cuts are, so about how many each chunk built holds.
ROOT_PIECE :: 256 * 1024

// A text built on its own: `[` entries `]`, or one entry `alone`.
Root_Chunk :: struct {
	lo, hi: int,
	alone:  bool,
}

// Chunk `k` of the job's text, and its bytes.
chunk_text :: proc(job: ^Root_Job, k: int) -> (c: Root_Chunk, text: []byte) {
	c = job.chunks[k]
	return c, job.src[c.lo:c.hi]
}

Root_Job :: struct {
	src:       []byte,
	chunks:    []Root_Chunk,
	docs:      []json.Document, // each chunk's, built
	firsts:    []int, // where each chunk's entries start in `items`
	uncounted: bool, // for `demanded_array_pieces`: the array chunks' entries are left to `count_end`
	items:     []jq.Value,
	allocator: runtime.Allocator,
	// For `print_root_pieces`: how the chunks are laid out, how deep the array is, and each chunk's text.
	validate:  bool, // whether each chunk is validated as `build_chunk` validates it before it is printed
	layout:    jq.Layout,
	depth:     int,
	levels:    int, // the objects the array sits in (`Root_Spine`)
	outs:      [][dynamic]byte, // chunk k's printed text, set once `ready[k]`, until it is written
	// Also `print_root_pieces`: chunks are written in order. `ready[k]` is whether chunk k's text is in
	// `outs`, `next` is the first chunk not yet written, and `writing` is whether a thread is writing (only
	// one does, so the order holds). `lock` guards all three.
	lock:      sync.Mutex,
	ready:     []bool,
	next:      int,
	writing:   bool,
	// For `iterate_root_pieces`: the run each chunk prints through a copy of, the paths it is scanned for, and
	// jq's result for its last output.
	run:       ^Run,
	paths:     []json.Path,
	rets:      []int,
	// With a `limit(N; P)` or `first(P)` (the path's `limit`): `limit` is the most outputs wanted, and
	// `ends[k]` where chunk k's first outputs end in its `outs[k]`, so the last chunk written can be cut after
	// the N-th.
	limit:     int,
	ends:      [][]int,
}

// The text data[at:], when it has a spine (`root_spine`) whose array is of at least two batch workers' worth, read in
// pieces in parallel. It returns false when it has none or a piece fails. `data` is the same once this returns. With
// `prog`, the root it reads: one with only the entries `jq.entry_demand` finds it reads built, and every other entry
// null, when it finds them.
build_root_pieces :: proc(run: ^Run, data: []byte, at: int, prog: ^jq.Node = nil) -> (v: jq.Value, ok: bool) {
	spine := root_spine(data, at) or_return
	if demand, some := jq.entry_demand(prog, spine.keys[:spine.levels]); some {
		v, ok = demanded_array_pieces(run, data, spine.lo, spine.z, spine.levels, demand)
	} else {
		v, ok = build_array_pieces(run, data, spine.lo, spine.z, spine.levels)
	}
	if !ok {
		spine_free(&spine)
		return
	}
	run.pieces_root = {rawptr(v.(^jq.Array)), rawptr(v.(^jq.Array)), data[at:], data[spine.lo:spine.z + 1]}
	if spine.levels == 0 {
		return
	}
	// From the array out, each object the frame's with the one inside it for its member, which keeps its place.
	frame := new_clone(spine.frame)
	objects: [SPINE_LEVELS]json.Node
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
	run_once(run, v)
	return true
}

// The array data[at:z + 1], `[` to `]`, of at least two batch workers' worth, as an array of its entries, read in
// pieces in parallel. It returns false when it is not one or a piece fails.
@(private = "file")
build_array_pieces :: proc(run: ^Run, data: []byte, at, z: int, levels: int) -> (v: jq.Value, ok: bool) {
	job, cuts, runner := array_chunks(run, data, at, z, levels) or_return
	chunks := job.chunks
	stand_in(data, cuts, true)
	job.docs = make([]json.Document, len(chunks))
	job.firsts = make([]int, len(chunks))
	built := fan_out(runner, len(chunks), build_chunk, &job)
	stand_in(data, cuts, false)
	defer {
		delete(chunks)
		delete(cuts)
		delete(job.firsts)
	}
	if !built {
		for &d in job.docs {
			json.destroy(&d)
		}
		delete(job.docs)
		return
	}
	// Each chunk's entries go to the root's items from the count of those before it, written on the threads
	// that built them, whose caches hold the rows.
	n := 0
	for &d, k in job.docs {
		job.firsts[k] = n
		n += 1 if chunks[k].alone else json.child_count(&d, 0)
	}
	root := jq.new_array(n)
	non_zero_resize(&root.items, n)
	job.items = root.items[:]
	fan_out(runner, len(job.docs), fill_items, &job)
	return root, true
}

// The array data[at:z + 1], `[` to `]`, of at least two batch workers' worth, with only `demand`'s entries built and
// every other entry null: each chunk is validated and its entries counted in parallel (or, when the program reads one
// end alone, only that end's, after; see `count_end`), and then the entries demanded are found and built alone. It
// returns false when it is not one or a chunk is not well-formed.
@(private = "file")
demanded_array_pieces :: proc(run: ^Run, data: []byte, at, z: int, levels: int, demand: jq.Entry_Demand) -> (v: jq.Value, ok: bool) {
	// Validating a piece is quicker than building it, so smaller pieces share it more evenly among the threads.
	job, cuts, runner := array_chunks(run, data, at, z, levels, ROOT_PIECE / 4, BATCH_BYTES_PER_WORKER / 2) or_return
	job.firsts = make([]int, len(job.chunks))
	// Each chunk stays an array text while its entries are found, and is the source's bytes once this returns.
	stand_in(data, cuts, true)
	defer {
		stand_in(data, cuts, false)
		delete(job.chunks)
		delete(cuts)
		delete(job.firsts)
	}
	// Entries read from one end only, and not how many there are: the array is that end's chunks, up to the
	// demanded entries, and the commas of the others go uncounted.
	job.uncounted = !demand.counted && (demand.head == 0 || demand.tail == 0)
	if !fan_out(runner, len(job.chunks), count_entries, &job) {
		return
	}
	if job.uncounted {
		count_end(&job, max(demand.head, demand.tail), from_back = demand.tail > 0)
	}
	n := 0
	for &f in job.firsts {
		f, n = n, n + f
	}
	root := jq.new_array(n)
	// An arena's memory is zero, null's bits: left so, it is not touched until an entry is read.
	if context.allocator.procedure == virtual.arena_allocator_proc {
		non_zero_resize(&root.items, n)
	} else {
		resize(&root.items, n)
	}
	for i := 0; i < n; i += 1 {
		if i == demand.head {
			i = max(i, n - demand.tail)
			if i == n {
				break
			}
		}
		root.items[i] = build_entry(&job, i) or_return
	}
	return root, true
}

// Chunk `k`'s entries, counted into `firsts`. It returns false when it is not well-formed.
@(private = "file")
count_entries :: proc(job: ^Root_Job, k: int) -> bool {
	c, text := chunk_text(job, k)
	if !chunk_well_formed(job, c, text) {
		return false
	}
	if c.alone {
		job.firsts[k] = 1
	} else if !job.uncounted {
		job.firsts[k] = chunk_entries(text)
	}
	return true
}

// How many entries the array chunk `text` holds.
@(private)
chunk_entries :: proc(text: []byte) -> int {
	// The commas, not the entries: a chunk of a well-formed array has no empty one.
	n := 1
	commas := index.comma_cursor(1)
	for index.next_top_comma(&commas, text[:len(text) - 1]) >= 0 {
		n += 1
	}
	return n
}

// The chunks from the array's front, or its back, counted into `firsts` until they hold `want` entries. The chunks
// past them count none, so the array is that end's entries alone, as many as its reader asks for.
@(private = "file")
count_end :: proc(job: ^Root_Job, want: int, from_back: bool) {
	have := 0
	for j in 0 ..< len(job.chunks) {
		k := len(job.chunks) - 1 - j if from_back else j
		if have >= want {
			job.firsts[k] = 0
			continue
		}
		c, text := chunk_text(job, k)
		if !c.alone {
			job.firsts[k] = chunk_entries(text)
		}
		have += job.firsts[k]
	}
}

// Entry `i` of the array whose chunks `job` counted, found in its chunk and built alone.
@(private = "file")
build_entry :: proc(job: ^Root_Job, i: int) -> (v: jq.Value, ok: bool) {
	k := len(job.firsts) - 1
	for job.firsts[k] > i {
		k -= 1
	}
	c, text := chunk_text(job, k)
	if !c.alone {
		entries := text[:len(text) - 1]
		commas := index.comma_cursor(1)
		lo := 1
		for _ in 0 ..< i - job.firsts[k] {
			lo = index.next_top_comma(&commas, entries) + 1
		}
		hi := index.next_top_comma(&commas, entries)
		text = entries[lo:hi if hi >= 0 else len(entries)]
	}
	d := new(json.Document)
	err: Maybe(json.Error)
	d^, err = jq.build_rows(text)
	return jq.Ref{d, json.ROOT}, err == nil
}

// The array data[at:z + 1], `[` to `]`, of at least two batch workers' worth, cut into chunks at two top-level commas
// in a row, which the pool finds. It returns false when it is not one, or a chunk is over half of it. A chunk's text
// is one entry `alone`, or `[` entries `]` while the cuts' commas `stand_in` as `]` and `[`.
@(private)
array_chunks :: proc(run: ^Run, data: []byte, at, z: int, levels: int, piece := ROOT_PIECE, per := BATCH_BYTES_PER_WORKER) -> (job: Root_Job, cuts: [][2]int, runner: ^json.Batch_Runner, ok: bool) {
	if data[z] != ']' || u64(z - at) >= json.MAX_ROW_SOURCE {
		return
	}
	// No top-level comma in the first quarter means one entry holds most of the array, and the cuts would leave
	// one piece to read it. Finding that out on every thread costs about the pass the read would, so the cuts are
	// not looked for.
	commas := index.comma_cursor(at + 1)
	if index.next_top_comma(&commas, data[:min(z, at + 1 + (z - at) / 4)]) < 0 {
		return
	}
	runner = batch_runner(run, z - at, per)
	if runner == nil {
		return
	}
	job = Root_Job{src = data, allocator = context.allocator, levels = levels}
	cuts = comma_pairs(runner, data, at, z, piece) or_return
	chunks := make([]Root_Chunk, 2 * len(cuts) + 1)
	lo, widest := at, 0
	for c, k in cuts {
		chunks[2 * k] = {lo, c[0] + 1, false}
		chunks[2 * k + 1] = {c[0] + 1, c[1], true}
		widest = max(widest, c[1] - lo)
		lo = c[1]
	}
	chunks[len(chunks) - 1] = {lo, z + 1, false}
	// A chunk holding nearly all of the text takes about as long as the whole would, so the pieces would only add.
	// Below nine tenths the others run beside it, and the text is done when it is.
	if max(widest, z + 1 - lo) > (z - at) / 10 * 9 {
		delete(chunks)
		delete(cuts)
		return
	}
	job.chunks = chunks
	return job, cuts, runner, true
}

// Each cut's two commas as `]` and `[`, so that each chunk between is an array text, or back as commas.
@(private)
stand_in :: proc(data: []byte, cuts: [][2]int, on: bool) {
	for c in cuts {
		data[c[0]], data[c[1]] = ']' if on else ',', '[' if on else ','
	}
}

// The commas on either side of the first entry of each piece of the array data[at:z + 1] that `json.each_record`
// hands out, in order, but where a piece's first entry is the array's, or starts less than `piece` bytes past the cut
// before. It returns false when there are none, or the array's framing fails.
@(private = "file")
comma_pairs :: proc(runner: ^json.Batch_Runner, data: []byte, at, z, piece: int) -> (cuts: [][2]int, ok: bool) {
	found := Comma_Pairs{src = data, at = at, z = z}
	found.cuts = make([dynamic][2]int, 0, (z - at) / (32 * 1024) + 2)
	if json.each_record(data[at:z + 1], .Root_Entries, cut_piece, &found, runner) != nil {
		return
	}
	slice.sort_by(found.cuts[:], proc(a, b: [2]int) -> bool {return a[0] < b[0]})
	n, last := 0, at
	for c in found.cuts {
		if c[0] - last >= piece {
			found.cuts[n] = c
			n += 1
			last = c[1]
		}
	}
	if n == 0 {
		delete(found.cuts)
	}
	return found.cuts[:n], n > 0
}

@(private = "file")
Comma_Pairs :: struct {
	src:   []byte,
	at, z: int,
	lock:  sync.Mutex,
	cuts:  [dynamic][2]int,
}

// The commas on either side of the first entry of a piece, when both are.
@(private = "file")
cut_piece :: proc(data: rawptr, piece: ^json.Records, k: int) -> bool {
	f := (^Comma_Pairs)(data)
	rec, found := json.next_record(piece)
	if !found {
		return true
	}
	p, n := f.at + int(rec.at) - 1, f.at + int(rec.at) + len(rec.bytes)
	for p > f.at && jq.is_space(f.src[p]) {
		p -= 1
	}
	for n < f.z && jq.is_space(f.src[n]) {
		n += 1
	}
	if f.src[p] == ',' && f.src[n] == ',' {
		sync.lock(&f.lock)
		append(&f.cuts, [2]int{p, n})
		sync.unlock(&f.lock)
	}
	return true
}

// Chunk `k`, built: false unless an array chunk holds at least one entry and a lone entry is one text with
// no byte order mark (which the library steps over at a text's start).
@(private = "file")
build_chunk :: proc(job: ^Root_Job, k: int) -> bool {
	context.allocator = job.allocator
	c, text := chunk_text(job, k)
	if !chunk_readable(c, text) {
		return false
	}
	d, err := jq.build_rows(text, limits = chunk_limits(chunk_levels(job, c)))
	if err != nil {
		return false
	}
	job.docs[k] = d
	kd, _ := json.kind(&job.docs[k], 0)
	return c.alone || kd == .Array && json.child_count(&job.docs[k], 0) > 0
}

// What `build_chunk` asks of a chunk's text before it builds it.
@(private = "file")
chunk_readable :: proc(c: Root_Chunk, text: []byte) -> bool {
	return !c.alone || len(text) > 0 && text[0] != UTF8_BOM[0]
}

// What `build_chunk` checks in a chunk, without building it.
@(private)
chunk_well_formed :: proc(job: ^Root_Job, c: Root_Chunk, text: []byte) -> bool {
	if !chunk_readable(c, text) || json.validate(text, limits = chunk_limits(chunk_levels(job, c))) != nil {
		return false
	}
	if c.alone {
		return true
	}
	for b in text[1:len(text) - 1] {
		if !jq.is_space(b) {
			return true
		}
	}
	return false
}

// Chunk `k`'s entries, put in `items` from its first.
@(private = "file")
fill_items :: proc(job: ^Root_Job, k: int) -> bool {
	d := &job.docs[k]
	at := job.firsts[k]
	if job.chunks[k].alone {
		job.items[at] = jq.Ref{d, json.ROOT}
		return true
	}
	it := json.children(d, json.ROOT)
	for row in json.children(&it) {
		job.items[at] = jq.Ref{d, row}
		at += 1
	}
	return true
}
