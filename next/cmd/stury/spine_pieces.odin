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
	defer spine_free(&job)
	if !ok {
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
	if run.opts.seq && put == put_dot {
		jq.put_byte(&o.buf, 0x1e)
	}
	write.put_text(&o.buf, string(head))
	first := true
	for &s in job.slots {
		if s.entries == 0 {
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
	run.route.pieces += len(job.slots)
	if put == put_dot {
		o.result = JQ_OK
		end_output(o)
		finish_input(o)
		run.route.scanned += 1
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
	defer spine_free(&job)
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
	if len(data) < POOLED_BYTES || json.Spec(ins.as.spec) != .Json || !parallel(run) {
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
spine_free :: proc(job: ^Spine_Job) {
	for s in job.slots {
		give_spare(&job.run.spares, s.out, s.room, s.k)
	}
	delete(job.slots)
}

@(private = "file", rodata)
WHITE := " \t\r\n"

// A piece's entries counted, and with a `put` built in the pool thread's arena and written into the piece's own
// output.
@(private = "file")
spine_task :: proc(job: ^Spine_Job, it: ^records.Reader, k: int) -> bool {
	s := Spine_Slot{k = k}
	lo: u64
	ok := true
	for rec in records.next(it) {
		if ok = rec.key == nil; !ok {
			break
		}
		lo = lo if s.entries > 0 else rec.at
		s.end = rec.at + u64(len(rec.text))
		s.entries += 1
	}
	if ok && s.entries > 0 && job.put != nil {
		ok = spine_put(job, it.src[lo:s.end], &s)
	}
	sync.guard(&job.lock)
	if k >= len(job.slots) {
		resize(&job.slots, k + 1)
	}
	job.slots[k] = s
	job.failed ||= !ok
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
	n := job.levels
	wrapped := make([]u8, len(text) + 2 * n)
	for i in 0 ..< n {
		wrapped[i], wrapped[len(wrapped) - 1 - i] = '[', ']'
	}
	copy(wrapped[n:], text)
	doc, fault := jq.build_text(wrapped, job.plain)
	if fault != nil {
		return false
	}
	out: write.Out
	spare: [write.ROOM_MAX]u8
	write.init(&out, &spare, runtime.heap_allocator(), hint = 2 * len(text) + 1024)
	take_spare(&job.run.spares, &out, s.k)
	ok := job.put(job.run, &doc, &out)
	s.room = out.size
	printed, err := write.finish(&out)
	s.out = printed
	if !ok || err.kind != .None {
		return false
	}
	// Past `n` opening brackets and before `n` closing ones, the line break before the first entry kept.
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
