package main

// Spine discovery (`root_spine`) and parallel spine printing (`print_root_pieces`) and path iteration
// (`iterate_root_pieces`) for `root_pieces.odin`.

import "base:runtime"
import "core:bytes"
import "core:slice"
import "core:sync"
import core_pkg "../../core"
import json "../../json"
import "jq"
import "message"

// Where the text data[at:] has its spine (`core.Spine`), its offsets into `data`.
Root_Spine :: struct {
	using spine: json.Spine,
	// With `levels`, `shell`, the root's text with the array as `[]`, read: the members beside the array.
	frame:       json.Document,
	shell:       []byte,
}

// The text data[at:]'s spine: its root array, or the array its root object holds `levels` deep beside other members
// (`json.find_spine`), which read as the whole text reads them and leave the array its keys' value (`frame_holds`).
// It returns false when it has none, or a piece's caps (`piece_limits`) would hold no level of its own. The frame is
// `context.allocator`'s until `spine_free`.
root_spine :: proc(data: []byte, at: int) -> (s: Root_Spine, ok: bool) {
	// Under two workers' worth the pieces would cut nothing (`batch_runner`), so the members go unread.
	if data[at] == '{' && len(data) - at < 2 * BATCH_BYTES_PER_FIRST_WORKERS {
		return
	}
	s.spine = json.find_spine(data[at:]) or_return
	s.lo += at
	s.z += at
	if jq.lifted.max_depth <= u64(s.levels) {
		return {}, false
	}
	if s.levels == 0 {
		return s, true
	}
	z := len(data) - 1
	for jq.is_space(data[z]) {
		z -= 1
	}
	s.shell = make([]byte, s.lo + 1 - at + z + 1 - s.z)
	copy(s.shell, data[at:s.lo + 1])
	copy(s.shell[s.lo + 1 - at:], data[s.z:z + 1])
	err: Maybe(json.Error)
	s.frame, err = jq.build_rows(s.shell)
	if err == nil && frame_holds(&s, s.lo - at) {
		return s, true
	}
	spine_free(&s)
	return {}, false
}

spine_free :: proc(s: ^Root_Spine) {
	if s.shell != nil {
		json.destroy(&s.frame)
		delete(s.shell)
	}
}

// Whether the frame's `[]` at shell[at:] is what its keys name: a repeated key's value is its last, so a key
// the array's repeats after it names another value.
@(private = "file")
frame_holds :: proc(s: ^Root_Spine, at: int) -> bool {
	n := json.ROOT
	for key in s.keys[:s.levels] {
		n = json.child(&s.frame, n, key)
	}
	raw := json.get_raw(&s.frame, n)
	return len(raw) == 2 && raw_data(raw) == raw_data(s.shell[at:])
}

// Whether `steps` name the spine's array: its keys, all of them.
spine_named :: proc(s: ^Root_Spine, steps: []json.Step) -> bool {
	if len(steps) != s.levels {
		return false
	}
	for step, i in steps {
		name, is_name := step.(json.Name)
		if !is_name || string(name) != s.keys[i] {
			return false
		}
	}
	return true
}

// The JSON text `text`, a large array or object, printed as `print_jq` prints it, in pieces on the batch pool: its
// spine's array cut into pieces (`json.split_array`), each validated where `validate` asks, then each laid out by a thread
// into a buffer of its own and written as soon as it and the pieces before it are. It returns false, with nothing
// printed, when the text has no spine or is too small to cut, or a piece is not well-formed, which leaves the text's
// fault to a reader of it whole. A piece that is not in jq's format is built and printed by jq's rules on its thread.
// A text that sits `above` objects deep in the input is validated with their levels counted (`piece_limits`). Under
// `run.verbatim` (fmt) every piece is validated and the text is written as `json.marshal` writes it, and under `run.silent` it
// is collected in `run.out`.
print_root_pieces :: proc(run: ^Run, text: []byte, validate := false, above := 0) -> bool {
	spine := root_spine(text, 0) or_return
	defer spine_free(&spine)
	// A text above the input's root has its levels counted unpainted, so a colour run takes only the root's own.
	if run.opts.color && above > 0 {
		return false
	}
	job, runner := array_pieces(run, text, spine.lo, spine.z, spine.levels + above) or_return
	job.validate = validate || run.verbatim
	job.layout = output_layout(run)
	job.depth = spine.levels
	job.outs = make([][dynamic]byte, len(job.pieces))
	job.ready = make([]bool, len(job.pieces))
	job.run = run
	defer {
		delete(job.pieces)
		delete(job.outs)
		delete(job.ready)
	}
	head, foot: [dynamic]byte
	defer {
		delete(head)
		delete(foot)
	}
	if run.verbatim && !verbatim_frame(run, text, &spine, &head, &foot) {
		return false
	}
	// What can fail is validated before anything is written. A validated piece prints.
	if (job.validate || job.levels > 0) && !core_pkg.piece_fan(runner, len(job.pieces), judge_piece, &job) {
		return false
	}
	l, d := job.layout, job.depth
	run.ret = JQ_OK
	flush_some(run, force = true)
	tail: [dynamic]byte
	defer delete(tail)
	if run.verbatim {
		append(&run.out, ..head[:])
		append(&tail, ..foot[:])
	} else {
		write_frame(&run.out, &tail, &spine, json.ROOT, 0, l)
	}
	jq.write_punct(&run.out, l, .Array, '[')
	jq.newline(&run.out, l, d + 1)
	flush_some(run, force = true)
	if !core_pkg.piece_fan(runner, len(job.pieces), print_piece, &job) {
		// A validated piece that fails to print leaves output already written, which nothing takes back.
		for o in job.outs {
			delete(o)
		}
		message.write_stderr("stury: error: %s: an array piece could not be printed\n", run.name)
		finish(run, EXIT_INPUT)
	}
	jq.newline(&run.out, l, d)
	jq.write_punct(&run.out, l, .Array, ']')
	append(&run.out, ..tail[:])
	end_output(run)
	return true
}

// The text around the spine's array as `json.marshal` writes it, `head` up to where the array goes and `foot` after
// it, found by writing the text with a string in the array's place. False when the text does not read so or the
// string is not found exactly once.
@(private = "file")
verbatim_frame :: proc(run: ^Run, text: []byte, s: ^Root_Spine, head, foot: ^[dynamic]byte) -> bool {
	STAND :: `"stury:root-array"`
	stand := transmute([]byte)string(STAND)
	shell := make([dynamic]byte, 0, len(text) - (s.z + 1 - s.lo) + len(stand), runtime.heap_allocator())
	defer delete(shell)
	append(&shell, ..text[:s.lo])
	append(&shell, ..stand)
	append(&shell, ..text[s.z + 1:])
	d, err := jq.build_rows(shell[:], run.read.dialect, allocator = runtime.heap_allocator())
	if err != nil {
		return false
	}
	defer json.destroy(&d)
	l := output_layout(run)
	written, merr := json.marshal(&d, {pretty = l.pretty, indent = u8(max(l.indent, 0))}, runtime.heap_allocator())
	if merr != nil {
		return false
	}
	defer delete(written)
	at := bytes.index(written, stand)
	if at < 0 || bytes.index(written[at + len(stand):], stand) >= 0 {
		return false
	}
	append(head, ..written[:at])
	append(foot, ..written[at + len(stand):])
	return true
}

// The frame's objects from `n`, `level` deep, laid out around the spine's array: up to its `[` onto `head`,
// after its `]` onto `tail`.
@(private = "file")
write_frame :: proc(head, tail: ^[dynamic]byte, s: ^Root_Spine, n: json.Node, level: int, l: jq.Layout) {
	if level == s.levels {
		return
	}
	out := head
	jq.write_punct(out, l, .Object, '{')
	it := jq.iterate(jq.Ref{&s.frame, n})
	defer if it.seen != nil {
		delete(it.seen^)
		free(it.seen)
	}
	first := true
	for k, m in jq.next_member(&it) {
		if !first {
			jq.write_punct(out, l, .Object, ',')
		}
		first = false
		jq.newline(out, l, level + 1)
		if l.colors != nil {
			append(out, l.colors[7])
		}
		jq.write_string(out, k, l.ascii)
		if l.colors != nil {
			append(out, "\e[0m")
		}
		jq.write_punct(out, l, .Object, ':')
		if l.pretty {
			append(out, ' ')
		}
		if k == s.keys[level] {
			write_frame(head, tail, s, m.(jq.Ref).node, level + 1, l)
			out = tail
		} else {
			jq.write_value(out, m, l, level + 1)
		}
	}
	jq.newline(out, l, level)
	jq.write_punct(out, l, .Object, '}')
}

// The filter's path, `[]` then steps with no `[]`, answered over each entry of the array data[at:z + 1], `[` to `]`,
// in pieces on the batch pool: each piece scanned as an array and its outputs settled and printed into a buffer of
// its own, and the buffers written in order. It returns false, with nothing printed, when the array is too small to
// cut, a piece is not well-formed, or an output is one jq's rules decide: the text's scan whole reports or runs what
// jq would.
iterate_root_pieces :: proc(run: ^Run, data: []byte, at, z, levels: int) -> bool {
	job, runner := array_pieces(run, data, at, z, levels) or_return
	// Each piece's outputs are cut at the limit after it is scanned, as the limit is the whole array's. With
	// steps after the `[]` and no other `[]`, the path is tried first without `per_element` (`iterate_piece`).
	steps := run.paths[0].steps[run.any_at:]
	paths := [2]json.Path{{steps = steps, per_element = true}, {steps = steps}}
	tried := len(steps) > 1
	for s in steps[1:] {
		if _, is_any := s.(json.Any); is_any {
			tried = false
		}
	}
	job.run, job.paths = run, paths[:2 if tried else 1]
	job.limit = run.paths[0].limit
	job.outs = make([][dynamic]byte, len(job.pieces))
	job.rets = make([]int, len(job.pieces))
	if job.limit > 0 {
		job.ends = make([][]int, len(job.pieces))
	}
	answered := core_pkg.piece_fan(runner, len(job.pieces), iterate_piece, &job)
	defer {
		for o in job.outs {
			delete(o)
		}
		delete(job.pieces)
		delete(job.outs)
		delete(job.rets)
		for e in job.ends {
			delete(e)
		}
		delete(job.ends)
	}
	if !answered {
		return false
	}
	flush_some(run, force = true)
	if job.limit > 0 {
		// Every piece was validated. Only the first N outputs are written, the N-th ending the last piece's.
		left := job.limit
		for o, k in job.outs {
			n := min(left, len(job.ends[k]))
			write_out(o[:job.ends[k][n - 1]])
			left -= n
			run.ret = job.rets[k]
			if left == 0 {
				break
			}
		}
		return true
	}
	for o in job.outs {
		write_out(o[:])
	}
	run.ret = job.rets[len(job.rets) - 1]
	return true
}

// Piece `k`'s outputs printed into `outs`. It returns false when it is not well-formed (no entry) or an output is
// one jq's rules decide.
@(private = "file")
iterate_piece :: proc(job: ^Root_Job, k: int, scratch: ^[dynamic]byte) -> bool {
	text, shift := json.frame_entries(job.src, job.pieces[k], scratch) or_return
	run := job.run^
	run.held = true
	run.out = make([dynamic]byte, 0, len(text), runtime.heap_allocator())
	job.outs[k] = run.out
	// The path starts at the `[]`.
	req: json.Request({.Path})
	defer json.destroy(&req)
	read := json.Read_Opts{dialect = .Json, limits = job.limits}
	alloc := runtime.heap_allocator()
	answers: []json.Answer
	settled := true
	if len(job.paths) > 1 {
		// Without `per_element` first, which the name matcher may answer: past the one `[]` an entry answers at
		// most once, so with as many found answers as entries, each has its own and the per-element scan, on
		// the automaton, has nothing to add.
		if json.request_init(&req, job.paths[1], opts = read, allocator = alloc) != nil || json.scan(text, &req) != nil {
			return false
		}
		if each_entry_answered(req.answers[:], text) {
			answers = req.answers[:]
		}
	}
	if answers == nil {
		if json.request_init(&req, job.paths[0], opts = read, allocator = alloc) != nil || json.scan(text, &req) != nil {
			return false
		}
		answers, settled = jq_outputs(req.answers[:])
	}
	if !settled || len(answers) == 0 {
		return false
	}
	if job.limit > 0 {
		answers = answers[:min(len(answers), job.limit)]
		// One answer at a time, so a limit can cut the output after any of them.
		job.ends[k] = make([]int, len(answers))
		for i in 0 ..< len(answers) {
			print_answers(&run, answers[i:i + 1], text, u64(shift))
			job.ends[k][i] = len(run.out)
		}
	} else {
		print_answers(&run, answers, text, u64(shift))
	}
	job.outs[k], job.rets[k] = run.out, run.ret
	// An answer a pool thread cannot print leaves the text to the main thread's scan, which reports it.
	return !run.faulted
}

// Whether `answers`, the path's over the JSON text `src`, are one found answer for each entry of its root,
// an array.
array_entries_answered :: proc(answers: []json.Answer, src: []byte) -> bool {
	text := bytes.trim_space(src)
	return len(text) > 0 && text[0] == '[' && each_entry_answered(answers, text)
}

// Whether `answers`, the path's over the array text `text`, are one found answer for each of its entries.
@(private = "file")
each_entry_answered :: proc(answers: []json.Answer, text: []byte) -> bool {
	for a in answers {
		if a.outcome != .Found {
			return false
		}
	}
	return len(answers) == entry_count(text)
}

// Whether piece `k` is one `print_piece` can lay out: well-formed when `validate`, and, of an array under
// objects, one whose shape reads.
@(private = "file")
judge_piece :: proc(job: ^Root_Job, k: int, scratch: ^[dynamic]byte) -> bool {
	text, _ := json.frame_entries(job.src, job.pieces[k], scratch) or_return
	// A text the reader validated may still be an object that repeats its key, its array closing before the
	// last `]`: it is one member only when every piece's brackets close where the piece's own open. Every
	// piece then starts and ends at the array's own depth, and the last `]` is the array's.
	strictness: json.Strictness = .Strict if job.validate else .Structural
	return json.validate(text, {strictness = strictness, limits = job.limits}) == nil
}

// Piece `k`, a judged one, laid out after the comma that follows the piece before it, and written once the pieces
// before it are. It returns false when it cannot be built.
@(private = "file")
print_piece :: proc(job: ^Root_Job, k: int, scratch: ^[dynamic]byte) -> bool {
	p := job.pieces[k]
	entries := job.src[p.lo:p.hi]
	out := make([dynamic]byte, 0, len(entries) + len(entries) / 2, runtime.heap_allocator())
	if k > 0 {
		jq.write_punct(&out, job.layout, .Array, ',')
		jq.newline(&out, job.layout, job.depth + 1)
	}
	if job.run.verbatim || !jq.write_spelled(&out, entries, job.layout, job.depth, items = true) {
		text, _ := json.frame_entries(job.src, p, scratch) or_return
		if !write_items(&out, job, text) {
			delete(out)
			return false
		}
	}
	write_in_order(job, k, out)
	return true
}

// The entries of the array text `text` written `job.depth + 1` levels in: by jq's rules, or, under `run.verbatim`, as
// `json.marshal` writes them, the array written at depth 0 and cut of its brackets and their line breaks, and every
// line indented by the levels above it.
@(private = "file")
write_items :: proc(out: ^[dynamic]byte, job: ^Root_Job, text: []byte) -> bool {
	l := job.layout
	d, err := jq.build_rows(text, limits = job.limits if job.run.verbatim else jq.lifted)
	if err != nil {
		return false
	}
	defer json.destroy(&d)
	defer free_all(context.temp_allocator)
	if !job.run.verbatim {
		jq.write_items(out, jq.Ref{&d, json.ROOT}, l, job.depth)
		return true
	}
	written, merr := json.marshal(&d, {pretty = l.pretty, indent = u8(max(l.indent, 0))}, runtime.heap_allocator())
	if merr != nil {
		return false
	}
	defer delete(written)
	unit := max(l.indent, 1)
	items := written[1:len(written) - 1]
	if !l.pretty {
		append(out, ..items)
		return true
	}
	items = items[1 + unit:len(items) - 1]
	pad := make([]byte, job.depth * unit, runtime.heap_allocator())
	defer delete(pad)
	slice.fill(pad, ' ' if l.indent > 0 else '\t')
	for {
		k := bytes.index_byte(items, '\n')
		if k < 0 {
			append(out, ..items)
			return true
		}
		append(out, ..items[:k + 1])
		append(out, ..pad)
		items = items[k + 1:]
	}
}

// Piece `k`'s text `out` written, with the ready pieces that follow it, if every piece before it has been, else left
// for the thread that writes the one before it. One thread writes at a time, so the order holds.
@(private = "file")
write_in_order :: proc(job: ^Root_Job, k: int, out: [dynamic]byte) {
	sync.lock(&job.lock)
	job.outs[k], job.ready[k] = out, true
	if job.writing {
		sync.unlock(&job.lock)
		return
	}
	job.writing = true
	for job.next < len(job.ready) && job.ready[job.next] {
		o := job.outs[job.next]
		job.outs[job.next] = nil
		job.next += 1
		sync.unlock(&job.lock)
		if job.run.silent {
			append(&job.run.out, ..o[:])
		} else {
			write_out(o[:], worker = true, pool = &job.run.pool)
		}
		delete(o)
		sync.lock(&job.lock)
	}
	job.writing = false
	sync.unlock(&job.lock)
}
