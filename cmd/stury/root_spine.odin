package main

// Spine discovery (`root_spine`) and parallel spine printing (`print_root_pieces`) and path iteration
// (`iterate_root_pieces`) for `root_pieces.odin`.

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:slice"
import "core:sync"
import json "../../json"
import index "../../json/scan/index"
import "jq"

// The most objects a spine's array sits in.
SPINE_LEVELS :: 4
// The most bytes a member beside the spine spans, and the most such members on either side of it in each
// object: past either, the root is left whole.
SIDE_BYTES :: 4096
SIDE_MEMBERS :: 16

// Where the text data[at:] has its spine: the array that is its root, or that sits `levels` objects deep,
// each the member `keys[i]` of the one before.
Root_Spine :: struct {
	lo, z:  int, // the array's `[` and `]`
	levels: int,
	keys:   [SPINE_LEVELS]string, // each a string of printable ASCII and no escape, which is its own text form
	// With `levels`, `shell`, the root's text with the array as `[]`, read: the members beside the array.
	frame:  json.Document,
	shell:  []byte,
}

// The text data[at:]'s spine: its root array, or the array its root object holds `levels` deep beside other members
// (see `spine_open`), which read as the whole text reads them and leave the array its keys' value (`frame_holds`). It
// returns false when it has none. The frame is `context.allocator`'s until `spine_free`.
root_spine :: proc(data: []byte, at: int) -> (s: Root_Spine, ok: bool) {
	z := len(data) - 1
	for z > at && jq.is_space(data[z]) {
		z -= 1
	}
	if data[at] == '[' {
		// Under --max-depth 1 a chunk's caps would hold no nesting at all, which `max_depth` 0 does not say.
		return {lo = at, z = z}, jq.lifted.max_depth >= 2
	}
	// Under two workers' worth the pieces would cut nothing (`batch_runner`), so the members go unread.
	if data[at] != '{' || data[z] != '}' || z - at < 2 * BATCH_BYTES_PER_FIRST_WORKERS {
		return
	}
	s.lo = spine_open(data, at, z, &s) or_return
	// A lone entry sits under the array and every object.
	if jq.lifted.max_depth < u64(s.levels) + 2 {
		return
	}
	s.z = spine_close(data, s.lo, z, s.levels) or_return
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

// The `[` of the spine array of the root object data[at:z + 1]: the first member, of the root or of an object the
// spine goes through, whose value does not end within SIDE_BYTES and opens an array (or an object to go into), its
// key and those above it put in `s`. It returns false when there is none, or it has SIDE_MEMBERS before it. Read only
// as far as its framing: `frame_holds` and the pieces validate the rest.
@(private = "file")
spine_open :: proc(data: []byte, at, z: int, s: ^Root_Spine) -> (lo: int, ok: bool) {
	k := at
	for s.levels < SPINE_LEVELS {
		// data[k] opens an object.
		for n := 0; ; n += 1 {
			k = skip_space(data, k + 1, z)
			if n == SIDE_MEMBERS || data[k] != '"' {
				return
			}
			key_lo, plain := k + 1, true
			for k += 1; k < z && data[k] != '"'; k += 1 {
				plain &&= data[k] >= 0x20 && data[k] < 0x7f && data[k] != '\\'
				if data[k] == '\\' {
					k += 1
				}
			}
			key_hi := k
			k = skip_space(data, k + 1, z)
			if data[k] != ':' {
				return
			}
			k = skip_space(data, k + 1, z)
			commas := index.comma_cursor(k)
			if end := index.next_top_comma(&commas, data[:min(k + SIDE_BYTES, z)]); end >= 0 {
				k = end
				continue
			}
			if !plain || data[k] != '[' && data[k] != '{' {
				return
			}
			s.keys[s.levels] = string(data[key_lo:key_hi])
			s.levels += 1
			if data[k] == '[' {
				return k, true
			}
			break
		}
	}
	return
}

// The `]` of the spine array opening at data[lo], `levels` objects into the root object closing at data[z]: found
// from the back, past each object's members after the spine's, SIDE_MEMBERS of SIDE_BYTES each at most. It returns
// false when the text does not end so. From the back the quotes are known: the text ends outside a string.
@(private = "file")
spine_close :: proc(data: []byte, lo, z, levels: int) -> (close: int, ok: bool) {
	p := z
	for level in 0 ..< levels {
		// data[p] closes an object. The spine's member is the first from the back whose value does not open within
		// SIDE_BYTES.
		for n := 0; ; n += 1 {
			p = back_space(data, p - 1, lo)
			floor := max(lo, p - SIDE_BYTES)
			first := p // the member's value's first byte
			switch data[p] {
			case '}', ']':
				first = back_open(data, p, floor)
			case '"':
				first = back_quote(data, p, floor)
			case:
				for first > floor && !jq.is_space(data[first - 1]) && data[first - 1] != ':' {
					first -= 1
				}
			}
			if first < 0 && (data[p] == '}' || data[p] == ']') {
				if data[p] != (']' if level == levels - 1 else '}') {
					return
				}
				break
			}
			if n == SIDE_MEMBERS || first < 0 {
				return
			}
			p = back_space(data, first - 1, lo)
			if data[p] != ':' {
				return
			}
			p = back_space(data, p - 1, lo)
			if data[p] != '"' {
				return
			}
			p = back_quote(data, p, max(lo, p - SIDE_BYTES))
			if p < 0 {
				return
			}
			p = back_space(data, p - 1, lo)
			if data[p] != ',' {
				return
			}
		}
	}
	return p, p > lo
}

@(private = "file")
skip_space :: proc(data: []byte, from, z: int) -> int {
	k := min(from, z)
	for k < z && jq.is_space(data[k]) {
		k += 1
	}
	return k
}

@(private = "file")
back_space :: proc(data: []byte, p, lo: int) -> int {
	p := p
	for p > lo && jq.is_space(data[p]) {
		p -= 1
	}
	return p
}

// Where the container closing at data[p] opens, at `floor` or past, -1 when it opens before.
@(private = "file")
back_open :: proc(data: []byte, p, floor: int) -> int {
	depth := 0
	for q := p; q >= floor; q -= 1 {
		switch data[q] {
		case '"':
			q = back_quote(data, q, floor)
			if q < 0 {
				return -1
			}
		case ']', '}':
			depth += 1
		case '[', '{':
			depth -= 1
			if depth == 0 {
				return q
			}
		}
	}
	return -1
}

// Where the string closing at data[q] opens, at `floor` or past, -1 when it opens before.
@(private = "file")
back_quote :: proc(data: []byte, q, floor: int) -> int {
	for k := q - 1; k >= floor; k -= 1 {
		if data[k] != '"' {
			continue
		}
		backslashes := 0
		for j := k - 1; j >= 0 && data[j] == '\\'; j -= 1 {
			backslashes += 1
		}
		if backslashes % 2 == 0 {
			return k
		}
	}
	return -1
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
// spine's array cut into chunks, each validated where `validate` asks, then each laid out by a thread into a buffer
// of its own and written as soon as it and the chunks before it are. It returns false, with nothing printed, when the
// text has no spine or is too small to cut, or a chunk is not well-formed, which leaves the text's fault to a reader
// of it whole. A chunk that is not in jq's format is built and printed by jq's rules on its thread. A text that sits
// `above` objects deep in the input is validated with their levels counted (`chunk_limits`). Under `run.verbatim`
// (fmt) every chunk is validated and the text is written as `json.marshal` writes it, and under `run.silent` it
// is collected in `run.out`.
print_root_pieces :: proc(run: ^Run, text: []byte, validate := false, above := 0) -> bool {
	spine := root_spine(text, 0) or_return
	defer spine_free(&spine)
	// A text above the input's root has its levels counted unpainted, so a colour run takes only the root's own.
	if run.opts.color && above > 0 {
		return false
	}
	job, cuts, runner := array_chunks(run, text, spine.lo, spine.z, spine.levels + above) or_return
	job.validate = validate || run.verbatim
	job.layout = output_layout(run)
	job.depth = spine.levels
	job.outs = make([][dynamic]byte, len(job.chunks))
	job.ready = make([]bool, len(job.chunks))
	job.run = run
	defer {
		delete(job.chunks)
		delete(cuts)
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
	stand_in(text, cuts, true)
	// What can fail is validated before anything is written. A validated chunk prints.
	if (job.validate || job.levels > 0) && !fan_out(runner, len(job.chunks), judge_chunk, &job) {
		stand_in(text, cuts, false)
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
	printed := fan_out(runner, len(job.chunks), print_chunk, &job)
	stand_in(text, cuts, false)
	if !printed {
		// A validated chunk that fails to print leaves output already written, which nothing takes back.
		for o in job.outs {
			delete(o)
		}
		fmt.eprintf("stury: error: %s: an array chunk could not be printed\n", run.name)
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
	d, err := jq.build_rows(shell[:], run.req.dialect, allocator = runtime.heap_allocator())
	if err != nil {
		return false
	}
	defer json.destroy(&d)
	l := output_layout(run)
	written, merr := json.marshal(&d, {pretty = l.pretty, indent = u8(max(l.indent, 0))}, runtime.heap_allocator())
	if merr != .None {
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
	defer delete(it.seen)
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
// in pieces on the batch pool: each chunk scanned as an array and its outputs settled and printed into a buffer of
// its own, and the buffers written in order. It returns false, with nothing printed, when the array is too small to
// cut, a chunk is not well-formed, or an output is one jq's rules decide: the text's scan whole reports or runs what
// jq would.
iterate_root_pieces :: proc(run: ^Run, data: []byte, at, z, levels: int) -> bool {
	job, cuts, runner := array_chunks(run, data, at, z, levels) or_return
	// Each chunk's outputs are cut at the limit after it is scanned, as the limit is the whole array's. With
	// steps after the `[]` and no other `[]`, the path is tried first without `per_element` (`iterate_chunk`).
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
	job.outs = make([][dynamic]byte, len(job.chunks))
	job.rets = make([]int, len(job.chunks))
	if job.limit > 0 {
		job.ends = make([][]int, len(job.chunks))
	}
	stand_in(data, cuts, true)
	answered := fan_out(runner, len(job.chunks), iterate_chunk, &job)
	stand_in(data, cuts, false)
	defer {
		for o in job.outs {
			delete(o)
		}
		delete(job.chunks)
		delete(cuts)
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
		// Every chunk was validated. Only the first N outputs are written, the N-th ending the last chunk's.
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

// Chunk `k`'s outputs printed into `outs`. It returns false when it is not well-formed (an array chunk with no entry,
// a lone entry that is not one text) or an output is one jq's rules decide.
@(private = "file")
iterate_chunk :: proc(job: ^Root_Job, k: int) -> bool {
	c, text := chunk_text(job, k)
	alone: [dynamic]byte
	defer delete(alone)
	if c.alone {
		// Scanned as an array of the one entry, as the other chunks are.
		alone = make([dynamic]byte, 0, len(text) + 2, runtime.heap_allocator())
		append(&alone, '[')
		append(&alone, ..text)
		append(&alone, ']')
		text = alone[:]
	}
	run := job.run^
	run.held = true
	run.out = make([dynamic]byte, 0, len(text), runtime.heap_allocator())
	job.outs[k] = run.out
	// The path starts at the `[]`.
	req := json.Request({.Path}){dialect = .Json, limits = chunk_limits(job.levels), paths = job.paths[:1], allocator = runtime.heap_allocator()}
	defer json.destroy(&req)
	answers: []json.Path_Answer
	if len(job.paths) > 1 {
		// Without `per_element` first, which the name matcher may answer: past the one `[]` an entry answers at
		// most once, so with as many found answers as entries, each has its own and the per-element scan, on
		// the automaton, has nothing to add.
		req.paths = job.paths[1:]
		if json.scan(text, &req) != nil {
			return false
		}
		if each_entry_answered(req.answers[:], text) {
			answers = req.answers[:]
		}
		req.paths = job.paths[:1]
	}
	if answers == nil {
		if json.scan(text, &req) != nil {
			return false
		}
		answers = jq_outputs(req.answers[:])
	}
	if len(answers) == 0 || c.alone && len(answers) > 1 {
		return false
	}
	for a in answers {
		if a.outcome != .Found && a.outcome != .Missing {
			return false
		}
	}
	if job.limit > 0 {
		answers = answers[:min(len(answers), job.limit)]
		// One answer at a time, so a limit can cut the output after any of them.
		job.ends[k] = make([]int, len(answers))
		for i in 0 ..< len(answers) {
			print_answers(&run, answers[i:i + 1], text, u64(c.lo))
			job.ends[k][i] = len(run.out)
		}
	} else {
		print_answers(&run, answers, text, u64(c.lo))
	}
	job.outs[k], job.rets[k] = run.out, run.ret
	// An answer a pool thread cannot print leaves the text to the main thread's scan, which reports it.
	return !run.faulted
}

// Whether `answers`, the path's over the JSON text `src`, are one found answer for each entry of its root,
// an array.
array_entries_answered :: proc(answers: []json.Path_Answer, src: []byte) -> bool {
	text := bytes.trim_space(src)
	return len(text) > 0 && text[0] == '[' && each_entry_answered(answers, text)
}

// Whether `answers`, the path's over the array chunk `text`, are one found answer for each of its entries.
@(private = "file")
each_entry_answered :: proc(answers: []json.Path_Answer, text: []byte) -> bool {
	for a in answers {
		if a.outcome != .Found {
			return false
		}
	}
	return len(answers) == chunk_entries(text)
}

// Whether chunk `k` is one `print_chunk` can lay out: well-formed when `validate`, and, of an array under
// objects, one that does not close below where it opens.
@(private = "file")
judge_chunk :: proc(job: ^Root_Job, k: int) -> bool {
	c, text := chunk_text(job, k)
	if job.validate {
		return chunk_well_formed(job, c, text)
	}
	// A text the reader validated may still be an object that repeats its key, its array closing before the
	// last `]`: it is one member only when no chunk's brackets close below where the chunk opens. Every
	// chunk then starts and ends at the array's own depth, and the last `]` is the array's.
	return nests(text if c.alone else text[1:len(text) - 1])
}

// Chunk `k`, a validated one, laid out after the comma that follows the chunk before it, and written once the chunks
// before it are. It returns false when it cannot be built.
@(private = "file")
print_chunk :: proc(job: ^Root_Job, k: int) -> bool {
	c, text := chunk_text(job, k)
	entries := text if c.alone else text[1:len(text) - 1]
	out := make([dynamic]byte, 0, len(text) + len(text) / 2, runtime.heap_allocator())
	if k > 0 {
		jq.write_punct(&out, job.layout, .Array, ',')
		jq.newline(&out, job.layout, job.depth + 1)
	}
	if job.run.verbatim {
		if !write_verbatim_items(&out, job, text, c.alone) {
			delete(out)
			return false
		}
	} else if !jq.write_spelled(&out, entries, job.layout, job.depth, items = true) {
		d, err := jq.build_rows(text)
		if err != nil {
			delete(out)
			return false
		}
		if c.alone {
			jq.write_value(&out, jq.Ref{&d, json.ROOT}, job.layout, job.depth + 1)
		} else {
			jq.write_items(&out, jq.Ref{&d, json.ROOT}, job.layout, job.depth)
		}
		json.destroy(&d)
		free_all(context.temp_allocator)
	}
	write_in_order(job, k, out)
	return true
}

// The entries of the chunk `text` as `json.marshal` writes them `job.depth + 1` levels in. The chunk, a lone entry
// `alone` in brackets, is written as an array at depth 0 and cut of its brackets and their line breaks, and every
// line is indented by the levels above it.
@(private = "file")
write_verbatim_items :: proc(out: ^[dynamic]byte, job: ^Root_Job, text: []byte, alone: bool) -> bool {
	l := job.layout
	src := text
	if alone {
		src = make([]byte, len(text) + 2, runtime.heap_allocator())
		src[0], src[len(src) - 1] = '[', ']'
		copy(src[1:], text)
	}
	defer if alone {
		delete(src)
	}
	d, err := jq.build_rows(src, limits = chunk_limits(job.levels))
	if err != nil {
		return false
	}
	defer json.destroy(&d)
	written, merr := json.marshal(&d, {pretty = l.pretty, indent = u8(max(l.indent, 0))}, runtime.heap_allocator())
	if merr != .None {
		return false
	}
	defer delete(written)
	free_all(context.temp_allocator)
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

// Chunk `k`'s text `out` written, with the ready chunks that follow it, if every chunk before it has been, else left
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

// Whether the brackets of `s` outside strings close no more than they have opened, and all they open.
@(private = "file")
nests :: proc(s: []byte) -> bool {
	prev_odd, in_string: u64
	depth: int
	tail: [64]u8
	for lo := 0; lo < len(s); lo += 64 {
		block: [^]u8 = raw_data(s[lo:])
		if len(s) - lo < 64 {
			tail = {}
			copy(tail[:], s[lo:])
			block = raw_data(tail[:])
		}
		_, instr, open, close := index.classify_brackets(block, &prev_odd, &in_string)
		open &= ~instr
		close &= ~instr
		if depth < int(intrinsics.count_ones(close)) {
			// This block may close more than is open: take its brackets in order.
			for m := open | close; m != 0; m &= m - 1 {
				depth += 1 if open & (m & -m) != 0 else -1
				if depth < 0 {
					return false
				}
			}
		} else {
			depth += int(intrinsics.count_ones(open)) - int(intrinsics.count_ones(close))
		}
	}
	return depth == 0
}
