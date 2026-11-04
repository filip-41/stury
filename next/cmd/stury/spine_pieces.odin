package main

// A long JSON text whose bulk is its spine array (`json.spine`) printed whole, or that array's length counted, on the
// pool's threads, with no document of the whole text. Each piece of the array's entries is built alone as an array
// inside as many arrays as the spine is deep, so its entries print at the depth they have in the text, and its text
// between the innermost brackets is kept. The text with the entries cut out, the frame, is built and printed with a
// marker in the array, and the pieces' texts are written in its place in source order, joined by commas. Any piece
// that does not build, or a frame that does not print its array, leaves the text to the serial route, with nothing
// printed.

import "base:runtime"
import "core:bytes"
import "core:sync"
import core "../../core"
import "../../core/write"
import records "../../core/records"
import json "../../json"
import "jq"

// How a document's text is written into an output, false when it cannot be.
Spine_Put :: #type proc(run: ^Run, doc: ^core.Document, out: ^write.Out) -> bool

Spine_Slot :: struct {
	out:     []u8,
	room, k: int, // the bytes `out`'s buffer holds, and the piece's number
	inner:   []u8, // the text of `out` between the innermost brackets
	end:     u64, // the byte past the piece's last entry
	entries: int,
	items:   [dynamic]jq.Value, // a collect's outputs, in the thread's piece arena
}

Spine_Job :: struct {
	run:     ^Run,
	plain:   core.As,
	levels:  int,
	put:     Spine_Put, // nil to count the entries alone
	lock:    sync.Mutex,
	slots:   [dynamic]Spine_Slot,
	failed:  bool,
}

// A marker the frame holds in place of the entries: a string whose spelling every printer keeps.
@(private = "file")
MARKER :: `"\u0001stury"`

// Prints the open file's one text by `put` in pieces, when it is a long strict JSON text with a spine: by `put_dot` as
// `.` prints it, or by `put_fmt` as `fmt` writes it. False, with nothing printed, when it is not printed so.
spine_print :: proc(ins: ^Inputs, put: Spine_Put) -> bool {
	run := ins.run
	data := ins.data
	job, at, ok := spine_run(ins, put)
	defer spine_free(run, job.slots)
	if !ok {
		return false
	}
	entries := 0
	for s in job.slots {
		entries += s.entries
	}
	// An empty spine prints as `[]`, which only the whole text's print gives.
	if entries == 0 {
		return false
	}
	close := array_close(data, at, entries_end(job.slots[:]))
	shell := make([]byte, int(at) + 1 + len(MARKER) + len(data) - int(close), context.temp_allocator)
	copy(shell, data[:at + 1])
	copy(shell[at + 1:], MARKER)
	copy(shell[int(at) + 1 + len(MARKER):], data[close:])
	doc, fault := jq.build_text(shell, ins.as, context.temp_allocator)
	if fault != nil {
		return false
	}
	frame: write.Out
	spare: [write.ROOM_MAX]u8
	write.init(&frame, &spare, context.temp_allocator)
	if !put(run, &doc, &frame) {
		return false
	}
	text, _ := write.finish(&frame)
	if !put_joined(run, text, job.slots[:], put == put_dot) {
		return false
	}
	run.route.pieces += len(job.slots)
	run.route.scanned += int(put == put_dot)
	return true
}

// Writes the printed frame `text` with the texts of the pieces `slots` in place of its marker, joined by commas, as
// one output of `.` when `dot`, else as `fmt` writes a text. False, with nothing written, when the marker is not one
// array's only entry.
@(private = "file")
put_joined :: proc(run: ^Run, text: []u8, slots: []Spine_Slot, dot: bool) -> bool {
	mark := bytes.index(text, transmute([]u8)string(MARKER))
	if mark < 0 || bytes.index(text[mark + 1:], transmute([]u8)string(MARKER)) >= 0 {
		return false
	}
	head := bytes.trim_right(text[:mark], transmute([]u8)WHITE)
	if len(head) == 0 || head[len(head) - 1] != '[' {
		return false
	}
	o := &run.output
	flush_some(o, force = true)
	if run.opts.seq && dot {
		jq.put_byte(&o.buf, 0x1e)
	}
	write.put_text(&o.buf, string(head))
	first := true
	for &s in slots {
		if len(s.inner) == 0 {
			continue
		}
		if !first {
			jq.put_byte(&o.buf, ',')
		}
		first = false
		// A piece's text is written from its own buffer, but into a held output.
		if o.held {
			write.put_text(&o.buf, string(s.inner))
		} else {
			flush_some(o, force = true)
			write_out(s.inner)
			o.written += len(s.inner)
		}
		give_spare(&run.spares, s.out, s.room, s.k)
		s.out = nil
	}
	write.put_text(&o.buf, string(text[mark + len(MARKER):]))
	if dot {
		o.result = JQ_OK
		end_output(o)
		finish_input(o)
	} else {
		jq.put_byte(&o.buf, '\n')
		flush_some(o)
	}
	return true
}

// Prints the length of the spine array of the open file's one text, counted on the pool's threads, when the filter is
// `length` on a root array or `.NAME... | length` on the array the names lead to. False, with nothing printed, when it
// is not.
spine_length :: proc(ins: ^Inputs) -> bool {
	run := ins.run
	names := make([dynamic]string, context.temp_allocator)
	if !length_of_names(run.prog, &names) {
		return false
	}
	job, at, ok := spine_run(ins, nil)
	defer spine_free(run, job.slots)
	if !ok || len(names) > job.levels - 1 {
		return false
	}
	n := 0
	for s in job.slots {
		n += s.entries
	}
	if job.levels > 1 {
		// The names lead to the array or to an object, whose length is its keys.
		doc, node, found := spine_walk(ins.data, at, array_close(ins.data, at, entries_end(job.slots[:])), ins.as, names[:])
		if !found {
			return false
		}
		if t := doc.nodes[node]; t.kind == .Map {
			n = unique_keys(&doc, node)
		} else if t.kind != .Array || u64(t.lo) != at {
			return false
		}
	}
	run.route.interpreted += 1
	run.route.pieces += len(job.slots)
	emit(&run.output, jq.num(f64(n)))
	finish_input(&run.output)
	return true
}

// The keys of the object `node`, a key its object repeats counted once, as jq reads it.
@(private = "file")
unique_keys :: proc(doc: ^core.Document, node: core.Node_Index) -> int {
	seen := make(map[string]struct{}, context.temp_allocator)
	it := core.pairs(doc, node)
	for k in core.pair_next(&it) {
		seen[jq.node_string(doc, k)] = {}
	}
	return len(seen)
}

// Whether `n` is `length` after `.NAME...`, whose names are appended to `names`.
@(private = "file")
length_of_names :: proc(n: ^jq.Node, names: ^[dynamic]string) -> bool {
	if jq.is_length(n) {
		return true
	}
	if n.kind != .Pipe || !jq.is_length(n.b) {
		return false
	}
	f := n.a
	for ; f.kind == .Field && !f.opt; f = f.a {
		inject_at(names, 0, f.name)
	}
	return f.kind == .Identity && len(names) > 0
}

// Reads the spine array's entries of the open file's one text in pieces on the pool's threads, each piece put by `put`
// or counted. False when the text is not one to read so or a piece cannot.
@(private = "file")
spine_run :: proc(ins: ^Inputs, put: Spine_Put) -> (job: Spine_Job, at: u64, ok: bool) {
	run := ins.run
	data := ins.data
	if len(data) < POOLED_BYTES || ins.spec != .Json || !parallel(run) {
		return
	}
	entries: core.As
	entries, at, ok = json.spine(data, ins.as)
	if !ok {
		return
	}
	job = {run = run, plain = ins.as, levels = int(entries.opts[0]) + 1, put = put}
	job.slots.allocator = runtime.heap_allocator()
	ok = records.each(data, entries, .Entries, spine_task, &job, run_pool(run), at) == nil && !job.failed
	return
}

@(private = "file")
spine_free :: proc(run: ^Run, slots: [dynamic]Spine_Slot) {
	for s in slots {
		give_spare(&run.spares, s.out, s.room, s.k)
	}
	delete(slots)
}

@(private = "file", rodata)
WHITE := " \t\r\n"

// A piece's entries counted, and with a `put` built in the pool thread's arena and written into the piece's own
// output.
@(private = "file")
spine_task :: proc(job: ^Spine_Job, it: ^records.Reader, k: int) -> bool {
	s := Spine_Slot{k = k}
	text, ok := piece_entries(it, &s)
	if ok && s.entries > 0 && job.put != nil {
		ok = spine_put(job, text, &s)
	}
	return publish(&job.lock, &job.slots, &job.failed, s, ok)
}

// The text of the piece's entries, counted into `s`. False when an entry is a key's value, a repeated key's.
@(private = "file")
piece_entries :: proc(it: ^records.Reader, s: ^Spine_Slot) -> (text: []u8, ok: bool) {
	lo: u64
	for rec in records.next(it) {
		if rec.key != nil {
			return
		}
		lo = lo if s.entries > 0 else rec.at
		s.end = rec.at + u64(len(rec.text))
		s.entries += 1
	}
	return it.src[lo:s.end], true
}

// Keeps the piece's slot `s` at its number in `slots`, and whether it failed.
@(private = "file")
publish :: proc(lock: ^sync.Mutex, slots: ^[dynamic]Spine_Slot, failed: ^bool, s: Spine_Slot, ok: bool) -> bool {
	sync.guard(lock)
	if s.k >= len(slots) {
		resize(slots, s.k + 1)
	}
	slots[s.k] = s
	failed^ ||= !ok
	return ok
}

// The entries `text` built inside `job.levels` arrays and written, with the text between the innermost brackets
// kept.
@(private = "file")
spine_put :: proc(job: ^Spine_Job, text: []u8, s: ^Spine_Slot) -> bool {
	values, temp, mapped := piece_arenas()
	if !mapped {
		return false
	}
	context.allocator, context.temp_allocator = values, temp
	defer {
		free_all(values)
		free_all(temp)
	}
	doc, fault := spine_build(text, job.levels, job.plain)
	if fault != nil {
		return false
	}
	out: write.Out
	spare: [write.ROOM_MAX]u8
	piece_out(&out, &spare, job.run, len(text), s.k)
	return job.put(job.run, &doc, &out) && piece_inner(&out, job.levels, s)
}

// Readies piece `k`'s output `out` of a text of `text_bytes`, which takes the piece's spare buffer.
@(private = "file")
piece_out :: proc(out: ^write.Out, spill: ^[write.ROOM_MAX]u8, run: ^Run, text_bytes, k: int) {
	write.init(out, spill, runtime.heap_allocator(), hint = 2 * text_bytes + 1024)
	take_spare(&run.spares, out, k)
}

// Finishes the piece's output `out` into `s`, with the text of `out` within `n` arrays as `s.inner`: past `n` opening
// brackets and before `n` closing ones, the line break before the first entry kept.
@(private = "file")
piece_inner :: proc(out: ^write.Out, n: int, s: ^Spine_Slot) -> bool {
	s.room = out.size
	printed, err := write.finish(out)
	s.out = printed
	if err.kind != .None {
		return false
	}
	inner := printed
	for _ in 0 ..< n {
		inner = bytes.trim(inner, transmute([]u8)WHITE)
		if len(inner) < 2 || inner[0] != '[' || inner[len(inner) - 1] != ']' {
			return false
		}
		inner = inner[1:len(inner) - 1]
	}
	s.inner = bytes.trim_right(inner, transmute([]u8)WHITE)
	return true
}

// The entries `text` of a spine array built inside `n` arrays, so each sits at the depth it has in the text.
spine_build :: proc(text: []u8, n: int, plain: core.As) -> (core.Document, Maybe(core.Fault)) {
	wrapped := make([]u8, len(text) + 2 * n)
	for i in 0 ..< n {
		wrapped[i], wrapped[len(wrapped) - 1 - i] = '[', ']'
	}
	copy(wrapped[n:], text)
	return jq.build_text(wrapped, plain)
}

// What a collect's pieces share: the interpreter they start as, the collected filter `f` (nil for the entries
// themselves), and whether each prints its outputs.
Collect_Job :: struct {
	run:    ^Run,
	ip:     jq.Interp,
	id:     int, // `run.collects` when the job started
	f:      ^jq.Node,
	plain:  core.As,
	levels: int, // the arrays a piece's entries are built inside: one per object around the spine array, and its own
	print:  bool,
	lock:   sync.Mutex,
	slots:  [dynamic]Spine_Slot,
	failed: bool,
}

// Answers the open file's one text on the pool's threads when it is a long strict JSON text and the filter collects `f`
// over the entries of its spine array, then runs a tail on the array: `[.NAME...[] | f] | tail` or
// `.NAME... | map(f) | tail`. Each piece runs `f` on its entries, and the pieces' outputs are joined in source order into
// the one array, which the tail runs on as the serial route runs the filter. With no tail, each piece prints its
// outputs, and their texts are joined as the array prints. False, with nothing printed, when the filter is not so, or
// `f` fails, halts or writes a message on an entry, which leaves the text to the serial route whole.
collect_pieces :: proc(ins: ^Inputs) -> bool {
	run := ins.run
	data := ins.data
	if len(data) < POOLED_BYTES || ins.spec != .Json || !parallel(run) {
		return false
	}
	names := make([dynamic]string, context.temp_allocator)
	f, tail, shaped := collect_shape(run.prog, &names)
	if !shaped {
		return false
	}
	entries, at, found := json.spine(data, ins.as)
	if !found || int(entries.opts[0]) != len(names) {
		return false
	}
	layout := run.output.layout
	run.collects += 1
	job := Collect_Job{run = run, ip = run.ip, id = run.collects, f = f, plain = ins.as, levels = len(names) + 1}
	job.print = tail == nil && layout.colors == nil && !layout.comments && run.output.table == nil
	// A piece's interpreter keeps nothing of the run's arenas and caches.
	job.ip.scope, job.ip.recycler, job.ip.text, job.ip.free_envs, job.ip.messages = {}, {}, {}, nil, {}
	job.slots.allocator = runtime.heap_allocator()
	defer {
		spine_free(run, job.slots)
		run.ip.err = nil // an error the tail raised may lie in a piece arena
	}
	if records.each(data, entries, .Entries, collect_task, &job, run_pool(run), at) != nil || job.failed || !spine_named(data, at, array_close(data, at, entries_end(job.slots[:])), ins.as, names[:]) {
		return false
	}
	n := 0
	for s in job.slots {
		n += len(s.items)
	}
	run.route.interpreted += 1
	run.route.pieces += len(job.slots)
	// An empty array prints with no line break inside, as the joined texts would give it.
	if job.print && n > 0 {
		frame: write.Out
		spare: [write.ROOM_MAX]u8
		write.init(&frame, &spare, context.temp_allocator)
		marked := jq.Array{}
		append(&marked.items, "\x01stury")
		layout.spill = nil
		jq.write_value(&frame, &marked, layout)
		text, _ := write.finish(&frame)
		if put_joined(run, text, job.slots[:], true) {
			return true
		}
	}
	joined := jq.new_array(n)
	for s in job.slots {
		append(&joined.items, ..s.items[:])
	}
	identity := jq.Node{kind = .Identity}
	prog := run.prog
	run.prog = tail if tail != nil else &identity
	run_once(run, joined)
	run.prog = prog
	return true
}

// The filter `n` split into the collected filter `f` and the `tail` run on the array of its outputs, nil for none, the
// names that lead to the iterated array appended to `names`. False when `n` is no such filter.
@(private = "file")
collect_shape :: proc(n: ^jq.Node, names: ^[dynamic]string) -> (f, tail: ^jq.Node, ok: bool) {
	c := n
	for c.kind == .Pipe && names_of(c.a, names) {
		c = c.b
	}
	if c.kind == .Pipe {
		c, tail = c.a, c.b
	}
	switch {
	case c.kind == .Call && c.name == "map" && len(c.args) == 1 && c.def != nil && c.def.in_prelude:
		f = c.args[0]
	case c.kind == .Array && c.a != nil:
		it := c.a
		for it.kind == .Pipe && names_of(it.a, names) {
			it = it.b
		}
		if it.kind == .Pipe {
			it, f = it.a, it.b
		}
		if it.kind != .Iterate || it.opt || !names_of(it.a, names) {
			return
		}
	case:
		return
	}
	return f, tail, true
}

// Whether `n` is `.` or `.NAME...` with no `?`, whose names are appended to `names`.
@(private = "file")
names_of :: proc(n: ^jq.Node, names: ^[dynamic]string) -> bool {
	at := len(names)
	x := n
	for ; x.kind == .Field && !x.opt; x = x.a {
		inject_at(names, at, x.name)
	}
	if x.kind != .Identity {
		resize(names, at)
		return false
	}
	return true
}

// The collect job whose outputs the thread's piece arena holds.
@(private = "file", thread_local)
piece_job: int

// A piece's entries built in its thread's piece arena, as one document, and run through `f`, their outputs kept in
// order and printed when the job prints. The arena holds them past the job, until a piece of another job empties it.
@(private = "file")
collect_task :: proc(job: ^Collect_Job, it: ^records.Reader, k: int) -> bool {
	s := Spine_Slot{k = k}
	values, _, ok := piece_arenas()
	if ok && piece_job != job.id {
		free_all(values)
		piece_job = job.id
	}
	text: []u8
	if ok {
		text, ok = piece_entries(it, &s)
	}
	if ok && s.entries > 0 {
		ok = collect_entries(job, text, values, &s)
	}
	return publish(&job.lock, &job.slots, &job.failed, s, ok)
}

// The entries `text` built and run through `f` into `s.items`, in `values`, and printed into `s.out` when the job
// prints.
@(private = "file")
collect_entries :: proc(job: ^Collect_Job, text: []u8, values: runtime.Allocator, s: ^Spine_Slot) -> bool {
	// What `f` makes, temporary or not, lives as long as the serial route keeps it: until the input is answered.
	context.allocator, context.temp_allocator = values, values
	doc := new(core.Document)
	fault: Maybe(core.Fault)
	if doc^, fault = spine_build(text, job.levels, job.plain); fault != nil {
		return false
	}
	ip := job.ip
	node := core.ROOT
	for _ in 1 ..< job.levels {
		c := core.children(doc, node)
		node, _ = core.child_next(&c)
	}
	s.items = make([dynamic]jq.Value, 0, s.entries if job.f == nil else 0)
	ch := core.children(doc, node)
	for e in core.child_next(&ch) {
		if job.f == nil {
			append(&s.items, jq.Ref{doc, e})
		} else if jq.collect_into(&ip, job.f, {v = jq.Ref{doc, e}}, ip.globals, &s.items) != .Go {
			return false
		}
	}
	if len(ip.messages) > 0 || ip.halted != nil {
		return false
	}
	if !job.print || len(s.items) == 0 {
		return true
	}
	layout := job.run.output.layout
	layout.spill = nil
	out: write.Out
	spare: [write.ROOM_MAX]u8
	piece_out(&out, &spare, job.run, len(text), s.k)
	a := jq.Array{s.items}
	jq.write_value(&out, &a, layout)
	return out.err == .None && piece_inner(&out, 1, s)
}

// `.` as jq prints it, without the trailing newline.
put_dot :: proc(run: ^Run, doc: ^core.Document, out: ^write.Out) -> bool {
	layout := run.output.layout
	if layout.colors != nil || layout.comments || run.output.table != nil {
		return false
	}
	layout.spill = nil
	jq.write_value(out, jq.Ref{doc, core.ROOT}, layout)
	return out.err == .None
}

// The document as `fmt` writes it, without the trailing newline.
put_fmt :: proc(run: ^Run, doc: ^core.Document, out: ^write.Out) -> bool {
	if writes_cells(&run.opts) || writes_comments(&run.opts) {
		return false
	}
	text, _, err := core.write(doc, run.output.layout.opts, json.as(.Json, {max_depth = run.opts.max_depth}), allocator = context.temp_allocator)
	write.put_text(out, string(text))
	return err.kind == .None
}
