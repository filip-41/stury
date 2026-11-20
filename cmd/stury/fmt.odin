package main

// `stury fmt` writes each FILE back in the printer's layout, or in another format (`--from`, `--to`). A plain run
// writes each file's output as it is made, `--check` holds it to compare with the file and writes nothing, and
// `--in-place` holds it and replaces the file through a temporary one beside it. A text written in its own family,
// JSON, JSONC or NDJSON as one of those or CSV as CSV, is written by the library's writer, which keeps every literal as
// written, a repeated key and, where the output has them, the comments. Across families a value is written as `.`
// writes it.

import "base:runtime"
import "core:bytes"
import "core:io"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import core "../../core"
import "../../core/write"
import records "../../core/records"
import json "../../json"
import "../../jq"
import "message"

// fmt --check's exit status: a file is not already in the printer's layout.
FMT_EXIT_DIFFERS :: 1

// `stury fmt`, which reads and writes the files and exits.
fmt_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	o := &run.opts
	files := input_files(cli.files[:], cli.walked, command_name(cli))
	switch {
	case o.in_place && o.to != o.from:
		usage_error("--in-place writes each file back as its own format: %s, not --to %s", FORMATS[o.from].name, FORMATS[o.to].name)
	case o.in_place:
		refuse_in_place_inputs(files)
	}
	ins := Inputs {
		source = input_source(o, cli.json_reading),
		files  = files,
		run    = run,
	}
	if cli.schema.flag != "" {
		run.convert = conversion_open(run, cli.schema, ins.source)
	}
	init_output(&run.output, run)
	run.output.held = o.check || o.in_place
	// Past the library's nesting cap the printer recurses, so it runs on the interpreter's stack, as a filter run does.
	run_deep(run, &ins, fmt_files)
	finish(run, run.output.ret)
}

// What each file's format reads: the run's source, whether its outputs are held, and -c, which NDJSON's lines are
// written compact without.
@(private = "file")
Fmt_Run :: struct {
	src:           Source,
	held, compact: bool,
}

// Each of `ins.files` formatted, on the pool's threads unless a schema judges them, the printer may recurse past the
// library's cap, or a text of one file is parted from the last of the file before. The output comes to the worst
// file's status: 2 after a file that did not open, read or write or that the schema could not judge, else EXIT_INPUT
// after a fault, else 1 after one that fails the schema or, under --check, differs, which it names. A file that fails
// the schema or faults under it is not written.
@(private = "file")
fmt_files :: proc(run: ^Run, ins: ^Inputs) {
	o := &run.opts
	fr := Fmt_Run{ins.source, run.output.held, o.compact && !writes_lines(o)}
	fc := Files_Call{run = run, files = ins.files, job = fmt_file, data = &fr}
	parted := FORMATS[o.to].parted != nil || writes_one_document(o)
	for f in o.froms {
		parted ||= o.to_by_file && FORMATS[f].parted != nil
	}
	each_file(&fc, run.convert == nil && o.max_depth <= core.MAX_DEPTH && (fr.held || !parted))
	tell_changed(&fc)
	run.output.ret = fc.code
}

// Under --check or --in-place over more than one file, how many of them would change or changed.
tell_changed :: proc(fc: ^Files_Call) {
	if o := &fc.run.opts; (o.check || o.in_place) && len(fc.files) > 1 {
		message.write_stderr("stury: %d of %d files %s\n", fc.changed, len(fc.files), "would change" if o.check else "changed")
	}
}

// File `k` formatted on `r`, its status in `slot`.
@(private = "file")
fmt_file :: proc(fc: ^Files_Call, r: ^Run, k: int, slot: ^File_Slot) {
	fr := (^Fmt_Run)(fc.data)
	o, out, c, path := &r.opts, &r.output, r.convert, fc.files[k]
	ins := Inputs{files = fc.files[k:k + 1], run = r}
	from := o.from
	if ins.source, _ = file_source(o, path, fr.src); o.from != from {
		o.compact = fr.compact || writes_lines(o)
		out.layout.opts.pretty, out.layout.comments = !o.compact, writes_comments(o)
		out.table, out.parted_at = table_start(r) if writes_cells(o) else nil, -1
	}
	spent, read := file_bytes(path, o.in_place)
	if !read {
		slot.code = EXIT_USAGE
		return
	}
	defer free_spent(spent)
	defer free_all(context.temp_allocator)
	ins.data, ins.name = spent.data, file_name(path)
	judged := conversion_judge(r, &ins) if c != nil else .Valid
	cells := c != nil && c.cells_as.readers != nil
	if cells {
		c.table = reads_cells(o)
	}
	// A file the schema judged is held until it passes, and one it found a fault in is formatted only to tell the
	// fault, as fmt tells it.
	out.held = fr.held || cells || judged == .Fault
	formatted := (judged == .Valid || judged == .Fault) && fmt_text(r, &ins)
	table_end(out)
	if out.table != nil {
		out.table = table_start(r)
	}
	text := out.buf.buf[:out.buf.cursor]
	passes := !formatted || !cells || conversion_cells_pass(c, &ins, text)
	out.held = fr.held
	switch {
	case judged == .Refused:
		slot.code = EXIT_USAGE
	case judged == .Invalid || !passes:
		slot.code = 1
	case !formatted:
		slot.code = EXIT_INPUT
		if judged == .Valid {
			flush_some(out, force = true)
		}
	case o.check:
		if slot.changed = !bytes.equal(text, ins.data); slot.changed {
			message.write_stderr("stury: %s is not formatted\n", ins.name)
			slot.code = FMT_EXIT_DIFFERS
		}
	case o.in_place:
		slot.changed = !bytes.equal(text, ins.data)
		if slot.changed && !rewrite_file(path, text) {
			slot.code, slot.changed = EXIT_USAGE, false
		}
	case:
		flush_some(out, force = true)
	}
	// A held file's text is a file of its own, parted from no other.
	out.buf.cursor, out.parted_at = 0, -1 if fr.held else out.parted_at
}

// The texts of the open file written, or the texts before its first fault and the fault told, and false. A text
// written in its own family, or as a table's rows, is built whole when it is the file's one text, else each record is.
@(private = "file")
fmt_text :: proc(run: ^Run, ins: ^Inputs) -> bool {
	o := &run.opts
	data := ins.data
	cells := reads_cells(o)
	if !cells && blank_input(data, ins.spec) {
		return true
	}
	if msg := header_fault(ins.name, data, ins.as) if cells else ""; msg != "" {
		message.write_stderr("stury: parse error: %s", msg)
		return false
	}
	heap := runtime.heap_allocator()
	if !cells && ins.framing == .Concatenated && spine_print(ins, put_fmt) {
		return true
	}
	if (cells == writes_cells(o) || !cells) && (cells || ins.framing == .Concatenated) {
		doc, fault, texts := build_whole(data, ins.source, heap)
		// A delimited text's fault is told at the record it is in, which the records below reach.
		if f, bad := fault.?; bad && !cells {
			tell_fault(ins, f)
			return false
		} else if !bad && !texts {
			written := put_document(run, ins, &doc) if cells == writes_cells(o) else put_rows(run, ins, &doc)
			core.destroy(&doc)
			return written
		}
	}
	it := records.open(data, ins.as, ins.framing, allocator = heap)
	// Where the records written as cells end, which a table cut short at a fault is written up to.
	cut := -1
	// A table's record written as a value waits for the next record, so the last takes the comment lines after it.
	held: core.Value
	noted := cells && o.cells_in.comment != 0
	for {
		rec, more := records.next(&it)
		if held != nil {
			put_value(run, ins, held if more else core.noted(held, .Comment_Foot, cells_notes(ins, cut, len(data)))) or_return
			held = nil
		}
		if !more {
			break
		}
		// A record's document lives until the next record is read.
		free_all(context.temp_allocator)
		doc, fault := core.refuse_key_clash(records.build(&it, rec, context.temp_allocator))
		if f, bad := fault.?; bad {
			cells_cut(run, ins, cut)
			tell_fault(ins, f)
			return false
		}
		// What an output holds past its write lives as long as its record.
		context.allocator = context.temp_allocator
		switch {
		case cells && writes_cells(o):
			cut = int(rec.at) + len(rec.text)
		case cells == writes_cells(o):
			put_document(run, ins, &doc) or_return
		case noted:
			held = core.noted(core.document_value(doc), .Comment, cells_notes(ins, cut, int(rec.at)))
			cut = int(rec.at) + len(rec.text)
		case cells:
			put_value(run, ins, core.document_value(doc)) or_return
		case:
			put_rows(run, ins, &doc) or_return
		}
	}
	if f, bad := it.fault.?; bad {
		cells_cut(run, ins, cut)
		tell_fault(ins, f)
		return false
	}
	return true
}

// `doc` written as a table's rows: a text whose root is an array is a list of rows, its comments placed as the library's
// writer places them, and any other value is a row. False, told, when a row cannot be written.
@(private = "file")
put_rows :: proc(run: ^Run, ins: ^Inputs, doc: ^core.Document) -> bool {
	if ins.framing != .Concatenated || core.is_markup(doc) || doc.nodes[core.ROOT].kind != .Array {
		return put_value(run, ins, core.document_value(doc^))
	}
	if run.convert != nil {
		run.convert.table = true
	}
	table_document(&run.output, doc)
	return true
}

// The value `v` of the open file written as an output, or false, told, when the output's format cannot hold it.
@(private = "file")
put_value :: proc(run: ^Run, ins: ^Inputs, v: core.Value) -> bool {
	if emit(&run.output, v) {
		return true
	}
	flush_some(&run.output, force = true)
	why, _ := jq.string_of(run.output.ip.err)
	message.write_stderr("stury: error: %s: %s\n", ins.name, why)
	return false
}

// The header of the open file and its records up to byte `cut`, or its header alone when `cut` is -1, written as its
// own format: what a CSV file holds before a fault.
@(private = "file")
cells_cut :: proc(run: ^Run, ins: ^Inputs, cut: int) {
	if !reads_cells(&run.opts) || !writes_cells(&run.opts) {
		return
	}
	end := cut
	if end < 0 {
		end = bytes.index_byte(ins.data, '\n') + 1
	}
	if doc, fault := build_text(ins.data[:end], ins.as, runtime.heap_allocator()); fault == nil {
		_ = put_document(run, ins, &doc)
	}
}

// The document `doc` of the open file written by the library's writer in the output's format and layout, and a
// newline after it unless it ends with one, is empty, as a CSV file with no header is, or is a binary format's item.
// A text of a format whose input is a stream of texts is parted from the one before it, so the output reads back as
// that stream. False, told, when it cannot be.
@(private = "file")
put_document :: proc(run: ^Run, ins: ^Inputs, doc: ^core.Document) -> bool {
	as := written_as(&run.opts)
	out := &run.output
	// A text with no text before it to part it from, and none that holds it back, goes to stdout as it is made, so its
	// size is not held.
	follows := FORMATS[run.opts.to].caps.follows != nil
	streamed := !out.held && !writes_one_document(&run.opts) && (FORMATS[run.opts.to].parted == nil || out.parted_at != out.written + out.buf.cursor)
	text: []u8
	dropped: int
	err: core.Error
	sent := Document_Sent{out = out}
	start, written := out.buf.cursor, out.written
	if streamed {
		dropped, err = core.write_stream(sent_stream(&sent), doc, out.layout.opts, as, allocator = context.temp_allocator)
	} else {
		text, dropped, err = core.write(doc, out.layout.opts, as, allocator = context.temp_allocator)
	}
	tell_dropped(ins.name, run.opts.to, dropped)
	if err != nil {
		if out.written == written {
			// What the refused text put in the buffer is not output.
			out.buf.cursor = start
		}
		flush_some(out, force = true)
		kind := write_refusal_kind(err)
		if kind == .Too_Deep {
			message.write_stderr("stury: error: %s: nesting this deep is not written in the format it was read in\n", ins.name)
		} else {
			message.write_stderr("stury: error: %s: %s\n", ins.name, edit_error_text(nil, err))
		}
		return false
	}
	if writes_one_document(&run.opts) {
		refuse_second_document(out, "the input gave a second text; --in-place writes each file as its own")
	}
	if streamed {
		end_format_text(out, as, sent.last, follows)
		return true
	}
	put_format_text(out, as, text, follows)
	return true
}

// The bytes a document's writer has made, which `sent_stream` puts into the output and flushes as they pass FLUSH_AT.
@(private = "file")
Document_Sent :: struct {
	out:  ^Output,
	last: u8, // the last byte put, 0 while none is
}

@(private = "file")
sent_stream :: proc(sent: ^Document_Sent) -> io.Stream {
	return {data = sent, procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, _: i64, _: io.Seek_From) -> (i64, io.Error) {
		#partial switch mode {
		case .Write:
			sent := (^Document_Sent)(data)
			write.put_text(&sent.out.buf, string(p))
			if len(p) > 0 {
				sent.last = p[len(p) - 1]
			}
			flush_some(sent.out)
			return i64(len(p)), nil
		case .Query:
			return io.query_utility({.Write, .Query})
		}
		return 0, .Empty
	}}
}

// The format fmt and the schema verbs write in, as --to and the output options say.
written_as :: proc(o: ^Opts) -> core.As {
	switch {
	case writes_cells(o):
		return cells_written_as(o)
	case writes_texts(o):
		return text_written_as(o)
	}
	return json.as(FORMATS[o.to].spec, {max_depth = o.max_depth})
}

// Refuses an input `--in-place` cannot rewrite. A temporary file and a rename replace a name with a regular file, so
// standard input, a symbolic link, a pipe, a device and a directory are refused. `lstat` does not open the path, which
// would block on a pipe.
refuse_in_place_inputs :: proc(files: []string) {
	for path in files {
		if path in unlisted {
			continue
		}
		if path == "-" {
			usage_error("--in-place needs a FILE: it cannot rewrite standard input")
		}
		if info, err := os.lstat(path, context.temp_allocator); err == nil && info.type != .Regular {
			usage_error("--in-place needs a regular file: %s is not one", path)
		}
	}
}

// Replaces `path` with `text` through a temporary file beside it, so a reader sees the old file or the new one.
rewrite_file :: proc(path: string, text: []byte) -> bool {
	info, serr := os.stat(path, context.temp_allocator)
	if serr != nil {
		return write_failed(path, serr)
	}
	f, temp, err := create_private_temp(path)
	if err != nil {
		return write_failed(path, err)
	}
	n: int
	if n, err = os.write(f, text); err == nil && n < len(text) {
		err = .Short_Write
	}
	if err == nil {
		// Before the mode: changing the owner clears the setuid and setgid bits.
		keep_owner(f, path)
		if err = os.fchmod(f, info.mode); err == nil {
			err = os.sync(f)
		}
	}
	os.close(f)
	if err == nil {
		err = os.rename(temp, path)
	}
	if err != nil {
		os.remove(temp)
		return write_failed(path, err)
	}
	return true
}

// A new file beside `path` that only its owner may open, so no other user can open it while the text is written,
// which a mode set after the writes would allow.
@(private = "file")
create_private_temp :: proc(path: string) -> (f: ^os.File, name: string, err: os.Error) {
	// A bare name's dir is "": the file goes in ".", not in the system temp dir, where the rename may cross devices.
	dir := os.dir(path)
	digits: [20]byte
	for _ in 0 ..< 64 {
		number := strconv.write_uint(digits[:], rand.uint64(), 10)
		name = strings.concatenate({dir if dir != "" else ".", "/.stury-fmt-", number, ".tmp"}, context.temp_allocator)
		f, err = os.open(name, {.Read, .Write, .Create, .Excl}, {.Read_User, .Write_User})
		if err != .Exist {
			return
		}
	}
	return
}

@(private = "file")
write_failed :: proc(path: string, err: os.Error) -> bool {
	message.write_stderr("stury: error: Could not write file %s: %s\n", path, strerror(err))
	return false
}

// The kind of typed refusal `err`, a write's, which is a typed error or an allocation refused.
write_refusal_kind :: proc(err: core.Error) -> core.Typed_Error_Kind {
	switch e in err {
	case core.Typed_Error:
		return e.kind
	case core.Typed_Error_Kind:
		return e
	case core.Fault, core.Document_Error, core.Path_Error, runtime.Allocator_Error:
		return .No_Memory
	case nil:
	}
	return .None
}
