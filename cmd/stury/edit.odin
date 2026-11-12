package main

// `stury edit`: run the filter on each input and write the input back with its outputs spliced into its own bytes. A
// whole JSON text takes one output. A table, NDJSON, `--seq`, `-R` lines and a stream of documents (YAML) run the
// filter on each record, or under `-s` once on the array of them, and the outputs are the records written back: a
// record with no output is dropped, and each output past a record's first is a new record after it. `--in-place`
// rewrites each file, and `--check` names each one that would change.

import "base:runtime"
import "core:bytes"
import "core:mem/virtual"
import "core:os"
import core "../../core"
import compose "../../core/compose"
import records "../../core/records"
import json "../../json"
import "jq"
import "message"

// What the outputs say for `-e`: whether the filter made one, and whether the last was false or null.
Edit_Status :: struct {
	any, falsy: bool,
}

// One file's edit: the run, the inputs it reads, how a built value is written, and the outputs' status.
Edit_Run :: struct {
	run:    ^Run,
	ins:    ^Inputs,
	layout: jq.Layout,
	status: Edit_Status,
}

// Holds the filter's outputs.
@(private = "file")
Edit_Sink :: struct {
	using sink: jq.Sink,
	values:     [dynamic]jq.Value,
}

@(private = "file")
edit_emit :: proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {
	e := (^Edit_Sink)(s)
	append(&e.values, it.v)
	return .Go
}

// The filter may call `input`, but there is no text after the one being edited.
edit_no_input :: proc(data: rawptr) -> (jq.Value, string, jq.Parse_Status) {
	return nil, "", .More
}

// The file and the line of the record being edited, which a filter error names.
edit_position :: proc(data: rawptr) -> (string, int) {
	ins := (^Inputs)(data)
	return ins.name, ins.line
}

// The position while a reader feeds `input`. Each reader's first field is its inputs.
edit_reader_position :: proc(data: rawptr) -> (string, int) {
	return edit_position((^^Inputs)(data)^)
}

// Refuses what an edit cannot honour. An edit writes each input back in its own bytes and format.
refuse_edit :: proc(o: ^Opts) {
	if o.in_place && o.check {
		usage_error("--in-place rewrites each file; --check only reads it")
	}
	if o.diff && (o.check || o.raw_input || o.seq || reads_lines(o)) {
		usage_error("--diff previews the changes of a whole document: it takes neither --check nor records")
	}
	o.to = o.from
}

// `stury edit`, which edits each file in turn and exits.
edit_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	files := cli.files[:] if len(cli.files) > 0 else STDIN_ONLY
	if len(cli.files) == 0 && is_terminal(os.stdin) && is_terminal(os.stdout) {
		// As fmt, rather than wait on the keyboard.
		usage(EXIT_USAGE, true)
	}
	if run.opts.in_place {
		refuse_in_place_inputs(files)
	}
	ins := Inputs {
		source = input_source(&run.opts, cli.json_reading),
		files  = files,
		run    = run,
	}
	// A built value takes its container's layout, or is compact where the source shows none, unless -c, --indent or
	// --tab asks for one.
	run.opts.compact = run.opts.compact || cli.layout_flag != "--indent" && cli.layout_flag != "--tab"
	run.opts.layout_shown = !cli.compact_given && cli.layout_flag != "--indent" && cli.layout_flag != "--tab"
	// The filter recurses, and so does a value being spliced, so the edit runs on the interpreter's stack.
	run_deep(run, &ins, edit_files)
	os.exit(0)
}

// Each of the files edited in turn, each telling its own fault. The exit is the worst file's, or under `-e` the last
// output's when every file was edited.
@(private = "file")
edit_files :: proc(run: ^Run, ins: ^Inputs) {
	o := &run.opts
	edit := Edit_Run {
		run    = run,
		ins    = ins,
		layout = {opts = {pretty = !o.compact, indent = u8(max(o.indent, 0)), tab = o.indent < 0, ascii = o.ascii, sort_keys = o.sort_keys}},
	}
	er := &edit
	run.ip.printer = nil
	run.ip.inputs = {data = ins, next = edit_no_input, position = edit_position}
	values, temp: virtual.Arena
	if virtual.arena_init_growing(&values) != nil || virtual.arena_init_growing(&temp) != nil {
		message.write_stderr("stury: error: out of memory\n")
		os.exit(EXIT_INPUT)
	}
	context.allocator = jq.arena_allocator(&values)
	context.temp_allocator = jq.arena_allocator(&temp)
	exit := 0
	for path in ins.files {
		f, read := open_file(path)
		if read {
			ins.data, read = read_file(f)
		}
		code := EXIT_USAGE
		if read {
			ins.name = file_name(path)
			switch {
			case run.opts.raw_input:
				code = edit_lines(er, path)
			case reads_cells(&run.opts):
				code = edit_table(er, path)
			case ins.framing == .Concatenated:
				code = edit_document(er, path)
			case:
				code = edit_records(er, path)
			}
			delete(ins.data, runtime.heap_allocator())
		}
		exit = max(exit, code)
		free_all(context.allocator)
		free_all(context.temp_allocator)
	}
	virtual.arena_destroy(&values)
	virtual.arena_destroy(&temp)
	if exit == 0 && run.opts.exit_status {
		exit = 4 if !er.status.any else 1 if er.status.falsy else 0
	}
	os.exit(exit)
}

// Runs the filter on `input` and returns its outputs, or false, told, when it fails.
edit_outputs :: proc(er: ^Edit_Run, input: jq.Value) -> ([]jq.Value, bool) {
	ip := &er.run.ip
	ip.free_envs = nil
	sink := Edit_Sink{sink = {emit = edit_emit}}
	sig := jq.eval(ip, er.run.prog, {v = input}, ip.globals, false, &sink.sink)
	if len(ip.messages) > 0 {
		jq.flush_messages(ip)
	}
	if code, halted := ip.halted.?; halted {
		os.exit(code)
	}
	if sig == .Fail {
		tell_filter_error(ip, nil)
		return nil, false
	}
	if n := len(sink.values); n > 0 {
		k := jq.kind(sink.values[n - 1])
		er.status = {any = true, falsy = k == .Null || k == .False}
	}
	return sink.values[:], true
}

// Under `-s` the filter's outputs are arrays of records, which follow one another.
edit_slurped :: proc(er: ^Edit_Run, w: ^Edit_State, input: jq.Value) -> (items, outs: []jq.Value, ok: bool) {
	outs, ok = edit_outputs(er, input)
	if !ok {
		return nil, nil, false
	}
	kept := make([dynamic]jq.Value, context.temp_allocator)
	for v in outs {
		if jq.kind(v) != .Array {
			message.write_stderr("stury: error: %s: under -s each output is an array of records, not %s\n", w.name, jq.type_name(v))
			return nil, nil, false
		}
		it := jq.iterate(v)
		for _, m in jq.next_member(&it) {
			append(&kept, m)
		}
	}
	return kept[:], outs, true
}

edit_state :: proc(er: ^Edit_Run, doc: ^core.Document, list: ^core.Edit_List) -> Edit_State {
	// A built value is written in the CLI's layout and numbers, and in the container's where that shows one.
	if list != nil {
		list.write = er.layout.opts
		list.write.escape_del, list.write.jq_numbers = true, true
		list.fixed = !er.run.opts.layout_shown
	}
	return {doc = doc, list = list, name = er.ins.name, sorted = er.run.opts.sort_keys}
}

// A whole text, which holds one document, so the filter makes one output. Under `-s` it is the one record of an array.
// A text of a format with a handle of its own whose fault is of a text after its first, a YAML stream, has each document
// edited as a record.
@(private = "file")
edit_document :: proc(er: ^Edit_Run, path: string) -> int {
	ins := er.ins
	src := ins.data
	heap := runtime.heap_allocator()
	doc, fault := jq.build_text(src, ins.as, heap)
	if f, bad := fault.?; bad && FORMATS[ins.format].whole_as != nil && FORMATS[ins.format].follows != nil && FORMATS[ins.format].follows(f) {
		return edit_records(er, path)
	} else if bad {
		tell_fault(ins, f)
		return EXIT_INPUT
	}
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc, heap)
	defer core.edit_list_destroy(&list)
	w := edit_state(er, &doc, &list)
	w.defers = true
	ins.line = 1
	root := jq.scalar(jq.Ref{&doc, core.ROOT})
	outs: []jq.Value
	ok: bool
	if er.run.opts.slurp {
		a := jq.new_array(1)
		append(&a.items, root)
		outs, _, ok = edit_slurped(er, &w, a)
	} else {
		outs, ok = edit_outputs(er, root)
	}
	if !ok {
		return EXIT_INPUT
	}
	if len(outs) != 1 {
		message.write_stderr("stury: error: %s: a file holds one document, and the filter made %s\n", w.name, "none" if len(outs) == 0 else message.build_temp("%d", len(outs)))
		return EXIT_INPUT
	}
	if !edit_tree(&w, core.ROOT, outs[0]) {
		message.write_stderr("stury: error: %s: %s\n", edit_place(&w), w.err)
		return EXIT_INPUT
	}
	out, owned, committed := edit_commit(&w, src, src, 0)
	if !committed {
		return EXIT_INPUT
	}
	defer if owned {
		delete(out, heap)
	}
	if w.later {
		later, later_owned, written := edit_later_comments(er, out, outs[0])
		if !written {
			return EXIT_INPUT
		}
		if later_owned {
			delete(out, heap)
			out = later
		}
	}
	return edit_publish(er.run, path, src, out)
}

// The comments of the values the first pass wrote new, written on the nodes the edited text `text` holds for them:
// the text `text` becomes, `owned` when it is a new heap allocation.
@(private = "file")
edit_later_comments :: proc(er: ^Edit_Run, text: []u8, v: jq.Value) -> (out: []u8, owned, ok: bool) {
	heap := runtime.heap_allocator()
	doc, fault := jq.build_text(text, er.ins.as, heap)
	if _, bad := fault.?; bad {
		message.write_stderr("stury: error: %s: The edited text does not read\n", er.ins.name)
		return nil, false, false
	}
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc, heap)
	defer core.edit_list_destroy(&list)
	w := edit_state(er, &doc, &list)
	if !edit_comment_tree(&w, core.ROOT, v) {
		message.write_stderr("stury: error: %s: %s\n", edit_place(&w), w.err)
		return nil, false, false
	}
	return edit_commit(&w, text, text, 0)
}

// The bytes `w`'s edits make of `text`, which starts at `base` in the file's `src`, or false, told, when the commit
// refuses. `owned` says the result is a new allocation on the heap, and no edit gives `text` itself.
edit_commit :: proc(w: ^Edit_State, src, text: []u8, base: u64) -> (out: []u8, owned, ok: bool) {
	if len(w.list.edits) == 0 {
		return text, false, true
	}
	committed, dropped, cerr := compose.commit(w.list, allocator = runtime.heap_allocator())
	if cerr != nil {
		cerr = moved_error(cerr, base)
		message.write_stderr("stury: error: %s: %s\n", w.name, edit_error_text(src, cerr))
		return nil, false, false
	}
	if dropped > 0 && edit_writes_fact(w.list) {
		delete(committed, runtime.heap_allocator())
		flat, style := core.is_flat(w.doc), core.Comment_Spelling.None
		if flat {
			style, _ = w.doc.readers.services.edit.comment(w.doc, w.doc.as.spec)
		}
		switch {
		case flat && style == .None:
			message.write_stderr("stury: error: %s: a table holds comments only with a comment character, which --comment names\n", w.name)
		case flat:
			message.write_stderr("stury: error: %s: a table holds a comment only as whole lines above a record or after the last one\n", w.name)
		case:
			message.write_stderr("stury: error: %s: the format cannot hold a comment the edit writes\n", w.name)
		}
		return nil, false, false
	}
	return committed, true, true
}

@(private = "file")
edit_writes_fact :: proc(list: ^core.Edit_List) -> bool {
	for e in list.edits {
		if e.op == .Set_Fact {
			return true
		}
	}
	return false
}

// Writes the edited text, or under `--check` names the file when it differs, or under `--in-place` replaces the file
// with it.
edit_publish :: proc(run: ^Run, path: string, src, out: []u8) -> int {
	if run.opts.diff {
		if !diff_preview(run, path, src, out) {
			return EXIT_INPUT
		}
		if !run.opts.in_place {
			return 0
		}
	}
	switch {
	case run.opts.check:
		if bytes.equal(out, src) {
			return 0
		}
		message.write_stderr("stury: %s would change\n", file_name(path))
		return FMT_EXIT_DIFFERS
	case run.opts.in_place:
		if !bytes.equal(out, src) && !rewrite_file(path, out) {
			return EXIT_USAGE
		}
	case:
		write_out(out)
	}
	return 0
}

// A record of a line or record-separated text: where its bytes are in the file. `full` ends the text the record's
// document holds, which under `--seq` takes the space after the value, and `end` ends the record before that space,
// which the gap after it keeps.
@(private = "file")
Edit_Span :: struct {
	at, end, full: u64,
}

// What the records' outputs make of the file, written as they come: each output record's text in turn, between the
// gaps the file has at those places, so its line ends and separators stay. Output `j` takes the gap before record `j`,
// which is known once that record is read, so an output past the records read so far waits. A gap past the file's own
// is its last gap between records, or past a file's one record its line end and a record separator under `--seq`.
// A stream of a format that parts its texts, YAML's, has each document start on a line of its own, after a line end the
// joiner adds when the text before it lacks one, and one after the first start with a `---` line, which the joiner adds
// when the document has none. A stream of no document, a text of comments, is kept as it is.
@(private = "file")
Edit_Joiner :: struct {
	src:     []u8,
	seq:     bool,
	stream:  bool,
	out:     [dynamic]u8,
	written: int,
	waiting: [dynamic]Edit_Text,
}

// An output record's text, and whether it is a heap allocation the joiner frees once it is written.
@(private = "file")
Edit_Text :: struct {
	text:  []u8,
	owned: bool,
}

@(private = "file")
edit_joiner :: proc(src: []u8, framing: core.Framing, format: Format) -> Edit_Joiner {
	heap := runtime.heap_allocator()
	return {src = src, seq = framing == .Seq, stream = framing == .Concatenated && FORMATS[format].parted != nil, out = make([dynamic]u8, 0, len(src), heap), waiting = make([dynamic]Edit_Text, heap)}
}

@(private = "file")
edit_joiner_destroy :: proc(j: ^Edit_Joiner) {
	for t in j.waiting {
		if t.owned {
			delete(t.text, runtime.heap_allocator())
		}
	}
	delete(j.waiting)
	delete(j.out)
}

@(private = "file")
edit_gap :: proc(src: []u8, spans: []Edit_Span, g: int) -> []u8 {
	lo := spans[g - 1].end if g > 0 else 0
	hi := spans[g].at if g < len(spans) else u64(len(src))
	return src[lo:hi]
}

// Adds an output record's text, and writes each waiting text whose gap the records read so far give.
@(private = "file")
edit_join :: proc(j: ^Edit_Joiner, spans: []Edit_Span, text: []u8, owned: bool) {
	if len(j.waiting) == 0 && j.written < len(spans) {
		edit_join_write(j, edit_gap(j.src, spans, j.written), {text, owned})
		return
	}
	append(&j.waiting, Edit_Text{text, owned})
	edit_join_flush(j, spans)
}

@(private = "file")
edit_join_flush :: proc(j: ^Edit_Joiner, spans: []Edit_Span) {
	k := 0
	for k < len(j.waiting) && j.written < len(spans) {
		edit_join_write(j, edit_gap(j.src, spans, j.written), j.waiting[k])
		k += 1
	}
	remove_range(&j.waiting, 0, k)
}

@(private = "file")
edit_join_write :: proc(j: ^Edit_Joiner, gap: []u8, t: Edit_Text) {
	append(&j.out, ..gap)
	if j.stream && len(t.text) > 0 && len(j.out) > 0 {
		if j.out[len(j.out) - 1] != '\n' {
			append(&j.out, '\n')
		}
		if j.written > 0 && !edit_marked(t.text) {
			append(&j.out, "---\n")
		}
	}
	append(&j.out, ..t.text)
	if t.owned {
		delete(t.text, runtime.heap_allocator())
	}
	j.written += 1
}

// The file's text once every record is read: the waiting texts, then the gap after the last record.
@(private = "file")
edit_join_end :: proc(j: ^Edit_Joiner, spans: []Edit_Span) -> []u8 {
	n := len(spans)
	if j.stream && n == 0 {
		return j.src
	}
	if j.written == 0 && len(j.waiting) == 0 || n == 0 {
		return j.out[:0]
	}
	edit_join_flush(j, spans)
	for t in j.waiting {
		if n >= 2 {
			edit_join_write(j, edit_gap(j.src, spans, n - 1), t)
			continue
		}
		end := edit_gap(j.src, spans, n)
		append(&j.out, "\r\n" if len(end) >= 2 && end[0] == '\r' && end[1] == '\n' else "\n")
		if j.seq {
			append(&j.out, 0x1e)
		}
		edit_join_write(j, nil, t)
	}
	clear(&j.waiting)
	append(&j.out, ..edit_gap(j.src, spans, n))
	return j.out[:]
}

// A line or record-separated text: each record is its own document. Its outputs are the records written back, the
// first keeping the record's bytes, or under `-s` the outputs of the one run on the array of them. A record the
// filter reads with `input` is consumed: it writes no record of its own.
@(private = "file")
edit_records :: proc(er: ^Edit_Run, path: string) -> int {
	ins := er.ins
	src := ins.data
	heap := runtime.heap_allocator()
	r := Edit_Reader {
		ins      = ins,
		it       = records.open(src, ins.as, ins.framing, allocator = heap),
		docs     = make([dynamic]^core.Document, heap),
		spans    = make([dynamic]Edit_Span, heap),
		lines_at = make([dynamic]int, heap),
	}
	defer {
		records.close(&r.it)
		edit_drop_docs(&r)
		delete(r.docs)
		delete(r.spans)
		delete(r.lines_at)
	}
	join := edit_joiner(src, ins.framing, ins.format)
	defer edit_joiner_destroy(&join)
	slurp := er.run.opts.slurp
	if !slurp {
		er.run.ip.inputs = {data = &r, next = edit_read_input, position = edit_reader_position}
	}
	defer er.run.ip.inputs = {data = ins, next = edit_no_input, position = edit_position}
	for {
		doc, more := edit_read(&r)
		if !more {
			break
		}
		if slurp {
			continue
		}
		i := len(r.spans) - 1
		outs, ran := edit_outputs(er, jq.scalar(jq.Ref{doc, core.ROOT}))
		if !ran || edit_read_failed(&r) {
			return EXIT_INPUT
		}
		for v, k in outs {
			text, fresh, written := edit_record_text(er, doc, src, r.spans[i], r.lines_at[i], v, k == 0)
			if !written {
				return EXIT_INPUT
			}
			edit_join(&join, r.spans[:], text, fresh)
		}
		// The record's values are not read again, so the next record's run starts with an empty arena, and its documents
		// and those `input` read go. A text taken from one is a view of the file.
		free_all(context.allocator)
		free_all(context.temp_allocator)
		edit_drop_docs(&r)
	}
	if edit_read_failed(&r) {
		return EXIT_INPUT
	}
	if slurp {
		docs := r.docs[:]
		sources := make([]jq.Value, len(docs), context.temp_allocator)
		owner := make(map[^core.Document]int, len(docs), context.temp_allocator)
		for d, i in docs {
			sources[i] = jq.scalar(jq.Ref{d, core.ROOT})
			owner[d] = i
		}
		a := jq.new_array(len(docs))
		append(&a.items, ..sources)
		ins.line = 1
		probe := Edit_State{name = ins.name}
		items, _, ran := edit_slurped(er, &probe, a)
		if !ran {
			return EXIT_INPUT
		}
		claims := make([]int, len(items), context.temp_allocator)
		for v, j in items {
			claims[j] = -1
			if ref, is_ref := v.(jq.Ref); is_ref && ref.node == core.ROOT {
				claims[j] = owner[ref.doc] if ref.doc in owner else -1
			}
		}
		pairs := match_items(sources, items, claims)
		for v, j in items {
			i := pairs[j]
			doc := docs[i] if i >= 0 else nil
			span := r.spans[i] if i >= 0 else Edit_Span{}
			line := r.lines_at[i] if i >= 0 else 0
			ins.line = line
			text, fresh, written := edit_record_text(er, doc, src, span, line, v, i >= 0)
			if !written {
				return EXIT_INPUT
			}
			edit_join(&join, r.spans[:], text, fresh)
		}
	}
	return edit_publish(er.run, path, src, edit_join_end(&join, r.spans[:]))
}

// Reads a file's records one at a time, for the edit's loop and for the filter's `input`, keeping each one's document,
// span and line.
@(private = "file")
Edit_Reader :: struct {
	ins:      ^Inputs,
	it:       records.Reader,
	docs:     [dynamic]^core.Document,
	spans:    [dynamic]Edit_Span,
	lines_at: [dynamic]int,
	line:     int,
	counted:  u64,
	fault:    Maybe(core.Fault),
}

@(private = "file")
edit_drop_docs :: proc(r: ^Edit_Reader) {
	for d in r.docs {
		core.destroy(d)
		free(d, runtime.heap_allocator())
	}
	clear(&r.docs)
}

// The next record's document, or false at the text's end or at a fault, which `fault` keeps.
@(private = "file")
edit_read :: proc(r: ^Edit_Reader) -> (doc: ^core.Document, more: bool) {
	heap := runtime.heap_allocator()
	rec, next := records.next(&r.it)
	if !next {
		r.fault = r.it.fault
		return nil, false
	}
	r.line += jq.count_newlines(r.ins.data[r.counted:rec.at])
	r.counted = rec.at
	line := r.line + 1
	built, err := records.build(&r.it, rec, heap)
	d, fault := jq.judge_build(built, err)
	if f, bad := fault.?; bad {
		r.fault = f
		return nil, false
	}
	doc = new(core.Document, heap)
	doc^ = d
	append(&r.docs, doc)
	full := rec.at + u64(len(rec.text))
	end := full
	for r.ins.framing == .Seq && end > rec.at && jq.is_space(r.ins.data[end - 1]) {
		end -= 1
	}
	append(&r.spans, Edit_Span{rec.at, end, full})
	append(&r.lines_at, line)
	r.ins.line = line
	return doc, true
}

// `input` while records are edited: the next record, whose place the outputs of the record being edited take.
@(private = "file")
edit_read_input :: proc(data: rawptr) -> (jq.Value, string, jq.Parse_Status) {
	r := (^Edit_Reader)(data)
	if r.fault != nil {
		return nil, "", .More
	}
	if doc, more := edit_read(r); more {
		return jq.scalar(jq.Ref{doc, core.ROOT}), "", .Value
	}
	if f, bad := r.fault.?; bad {
		return nil, fault_told(r.ins.name, r.ins.data, f), .Error
	}
	return nil, "", .More
}

// Reads a file's lines one at a time, for the edit's loop and for the filter's `input`.
@(private = "file")
Edit_Line_Reader :: struct {
	ins:   ^Inputs,
	at:    u64,
	spans: [dynamic]Edit_Span,
}

// The next line, without its LF, or false at the text's end.
@(private = "file")
edit_line :: proc(r: ^Edit_Line_Reader) -> (line: string, more: bool) {
	src := r.ins.data
	if r.at >= u64(len(src)) {
		return "", false
	}
	end := r.at
	for end < u64(len(src)) && src[end] != '\n' {
		end += 1
	}
	append(&r.spans, Edit_Span{r.at, end, end})
	r.ins.line = len(r.spans)
	line = string(src[r.at:end])
	r.at = end + 1
	return line, true
}

@(private = "file")
edit_line_input :: proc(data: rawptr) -> (jq.Value, string, jq.Parse_Status) {
	if line, more := edit_line((^Edit_Line_Reader)(data)); more {
		return line, "", .Value
	}
	return nil, "", .More
}

// Whether the text had a fault, told here, so the file is not written.
@(private = "file")
edit_read_failed :: proc(r: ^Edit_Reader) -> bool {
	f, bad := r.fault.?
	if bad {
		tell_fault(r.ins, f)
	}
	return bad
}

// The text a record's output `v` writes: the record's own bytes edited when `kept`, else a new record in the input's
// spelling, a value taken from a record keeping that record's bytes. `fresh` says the text is a heap allocation, which
// outlives the record's arena.
@(private = "file")
edit_record_text :: proc(er: ^Edit_Run, doc: ^core.Document, src: []u8, span: Edit_Span, line: int, v: jq.Value, kept: bool) -> (text: []u8, fresh, ok: bool) {
	heap := runtime.heap_allocator()
	// A record read with `input` keeps its bytes wherever it goes.
	stream := er.ins.framing == .Concatenated
	if r, is_ref := v.(jq.Ref); is_ref && (!kept || r.doc != doc) && !er.run.opts.sort_keys {
		if stream {
			return edit_moved_document(er, r)
		}
		return core.span(r.doc, r.node), false, true
	}
	if !kept && stream {
		return edit_new_document(er, v)
	}
	if !kept {
		layout := er.layout
		// One NDJSON record is one line.
		layout.opts.pretty = layout.opts.pretty && er.ins.framing == .Seq
		return transmute([]u8)jq.to_json(v, layout, heap), true, true
	}
	list := core.edit_list_init(doc, heap)
	defer core.edit_list_destroy(&list)
	w := edit_state(er, doc, &list)
	w.line = line
	list.write.pretty = list.write.pretty && er.ins.framing == .Seq
	if !edit_tree(&w, core.ROOT, v) {
		message.write_stderr("stury: error: %s: %s\n", edit_place(&w), w.err)
		return nil, false, false
	}
	out, owned := edit_commit(&w, src, src[span.at:span.full], span.at) or_return
	return out[:len(out) - int(span.full - span.end)], owned, true
}

// A stream's document made of value `r` of a record: the whole record, or the value's bytes moved to column 0. The
// joiner starts it with a marker line when it has none.
@(private = "file")
edit_moved_document :: proc(er: ^Edit_Run, r: jq.Ref) -> (text: []u8, fresh, ok: bool) {
	if r.node == core.ROOT {
		return r.doc.src, false, true
	}
	services := r.doc.readers.services if r.doc.readers != nil else nil
	if services == nil || services.edit == nil || services.edit.relocate == nil {
		return edit_new_document(er, r)
	}
	moved, fits := services.edit.relocate(r.doc, r.node, {placed = true}, runtime.heap_allocator())
	if !fits {
		message.write_stderr("stury: error: %s: the format cannot spell the value as a document\n", er.ins.name)
		return nil, false, false
	}
	return moved, true, true
}

// Whether the stream document `text` starts with a `---` or directive line, after its blank and comment lines.
@(private = "file")
edit_marked :: proc(text: []u8) -> bool {
	for ls := 0; ls < len(text); {
		nl := bytes.index_byte(text[ls:], '\n')
		line := text[ls:] if nl < 0 else text[ls:ls + nl]
		lead := bytes.trim_left(line, {' ', '\t', '\r'})
		switch {
		case len(lead) == 0 || lead[0] == '#':
		case line[0] == '%':
			return true
		case:
			return bytes.has_prefix(line, transmute([]u8)string("---")) && (len(line) == 3 || jq.is_space(line[3]))
		}
		if nl < 0 {
			break
		}
		ls += nl + 1
	}
	return false
}

// A document a stream's filter adds: the value as the format's document writer writes it, in block style.
@(private = "file")
edit_new_document :: proc(er: ^Edit_Run, v: jq.Value) -> (text: []u8, fresh, ok: bool) {
	built, fault := jq.build_text(transmute([]u8)jq.to_json(v, {}, context.temp_allocator), json.as(.Json), context.temp_allocator)
	body: []u8
	err: core.Error
	if fault == nil {
		opts := er.layout.opts
		opts.pretty = true
		body, _, err = core.write(&built, opts, er.ins.as, core.ROOT, runtime.heap_allocator())
	}
	if fault != nil || err != nil {
		message.write_stderr("stury: error: %s: the format cannot spell the value\n", er.ins.name)
		return nil, false, false
	}
	return body, true, true
}

// `-R`: each line is a string, and each output is written back as a line, a string raw and any other value as JSON. A
// line the filter reads with `input` is consumed. Under `-s` the file is one string and its outputs, written raw, are
// the file.
@(private = "file")
edit_lines :: proc(er: ^Edit_Run, path: string) -> int {
	ins := er.ins
	src := ins.data
	heap := runtime.heap_allocator()
	r := Edit_Line_Reader{ins = ins, spans = make([dynamic]Edit_Span, heap)}
	join := edit_joiner(src, .Lines, ins.format)
	defer {
		delete(r.spans)
		edit_joiner_destroy(&join)
	}
	raw :: proc(v: jq.Value) -> []u8 {
		if s, is_string := jq.string_of(v); is_string {
			return transmute([]u8)s
		}
		return transmute([]u8)jq.to_json(v, {}, context.temp_allocator)
	}
	if er.run.opts.slurp {
		ins.line = 1
		outs, ran := edit_outputs(er, string(src))
		if !ran {
			return EXIT_INPUT
		}
		out := make([dynamic]u8, 0, len(src), heap)
		defer delete(out)
		for v in outs {
			append(&out, ..raw(v))
		}
		return edit_publish(er.run, path, src, out[:])
	}
	er.run.ip.inputs = {data = &r, next = edit_line_input, position = edit_reader_position}
	defer er.run.ip.inputs = {data = ins, next = edit_no_input, position = edit_position}
	for {
		line, more := edit_line(&r)
		if !more {
			break
		}
		outs, ran := edit_outputs(er, line)
		if !ran {
			return EXIT_INPUT
		}
		for v in outs {
			edit_join(&join, r.spans[:], raw(v), false)
		}
	}
	return edit_publish(er.run, path, src, edit_join_end(&join, r.spans[:]))
}

// The refusal `err` of an edit in a text that starts `by` bytes into the file.
moved_error :: proc(err: core.Error, by: u64) -> core.Error {
	switch e in err {
	case core.Document_Error:
		moved := e
		core.move_document_error(&moved, by)
		return moved
	case core.Fault:
		moved := e
		moved.at += by
		return moved
	case core.Path_Error, core.Typed_Error, core.Typed_Error_Kind, runtime.Allocator_Error:
	case nil:
	}
	return err
}
