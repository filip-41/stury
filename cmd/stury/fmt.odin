package main

// `stury fmt` writes each FILE back in the printer's layout, or in another format (`--from`, `--to`). A plain run
// writes each file's output as it is made, `--check` holds it to compare with the file and writes nothing, and
// `--in-place` holds it and replaces the file through a temporary one beside it. A text written in its own family,
// JSON, JSONC or NDJSON as one of those or CSV as CSV, is written by the library's writer, which keeps every literal as
// written, a repeated key and, where the output has them, the comments. Across families a value is written as `.`
// writes it.

import "base:runtime"
import "core:bytes"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import core "../../core"
import "../../core/write"
import records "../../core/records"
import json "../../json"
import "jq"
import "message"

// fmt --check's exit status: a file is not already in the printer's layout.
FMT_EXIT_DIFFERS :: 1

// `stury fmt`, which reads and writes the files and exits.
fmt_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	o := &run.opts
	files := cli.files[:] if len(cli.files) > 0 else STDIN_ONLY
	if len(cli.files) == 0 && is_terminal(os.stdin) && is_terminal(os.stdout) {
		// As check, rather than wait on the keyboard.
		usage(EXIT_USAGE, true)
	}
	switch {
	case o.in_place && o.check:
		usage_error("--in-place rewrites each file; --check only reads it")
	case o.in_place && FORMATS[o.from].written_as != nil:
		usage_error("--in-place writes each file back as its own format, and json5 is read only")
	case o.check && FORMATS[o.from].written_as != nil:
		usage_error("--check compares each file with its own format, and json5 is read only")
	case o.in_place && o.to != o.from:
		usage_error("--in-place writes each file back as its own format: --from %s and --to %s differ", FORMATS[o.from].name, FORMATS[o.to].name)
	case o.in_place:
		refuse_in_place_inputs(files)
	}
	init_output(&run.output, run)
	run.output.held = o.check || o.in_place
	ins := Inputs {
		source = input_source(o, cli.json_reading),
		files  = files,
		run    = run,
	}
	// Past the library's nesting cap the printer recurses, so it runs on the interpreter's stack, as a filter run does.
	run.output.ret = 0
	run_deep(run, &ins, fmt_files)
	finish(run, EXIT_USAGE if ins.failures > 0 else run.output.ret)
}

// Each of `ins.files` formatted in turn. `ins.failures` counts the files that did not open, read or write, and the
// output comes to EXIT_INPUT after a file with a fault, else to FMT_EXIT_DIFFERS when --check finds one that differs,
// which it names.
@(private = "file")
fmt_files :: proc(run: ^Run, ins: ^Inputs) {
	o := &run.opts
	out := &run.output
	heap := runtime.heap_allocator()
	for path in ins.files {
		f, read := open_file(path, "fmt")
		if read {
			ins.data, read = read_file(f)
		}
		if !read {
			ins.failures += 1
			continue
		}
		ins.name = file_name(path)
		formatted := fmt_text(run, ins)
		table_end(out)
		if out.table != nil {
			out.table = table_start(run)
		}
		text := out.buf.buf[:out.buf.cursor]
		switch {
		case !formatted:
			out.ret = EXIT_INPUT
			flush_some(out, force = true)
		case o.check:
			if !bytes.equal(text, ins.data) {
				message.write_stderr("stury: %s is not formatted\n", ins.name)
				out.ret = max(out.ret, FMT_EXIT_DIFFERS)
			}
		case o.in_place:
			if !bytes.equal(text, ins.data) && !rewrite_file(path, text) {
				ins.failures += 1
			}
		case:
			flush_some(out, force = true)
		}
		out.buf.cursor = 0
		delete(ins.data, heap)
		free_all(context.temp_allocator)
	}
}

// The texts of the open file written, or the texts before its first fault and the fault told, and false. A text
// written in its own family, or as a table's rows, is built whole when it is the file's one text, else each record is.
@(private = "file")
fmt_text :: proc(run: ^Run, ins: ^Inputs) -> bool {
	o := &run.opts
	data := ins.data
	cells := reads_cells(o)
	if !cells && json.blank(data, ins.spec.?) {
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
			written := true
			if cells == writes_cells(o) {
				written = put_document(run, ins, &doc)
			} else {
				emit_rows(run, ins, jq.document_value(doc))
			}
			core.destroy(&doc)
			return written
		}
	}
	it := records.open(data, ins.as, ins.framing, allocator = heap)
	// Where the records written as cells end, which a table cut short at a fault is written up to.
	cut := -1
	for {
		rec, more := records.next(&it)
		if !more {
			break
		}
		// A record's document lives until the next record is read.
		free_all(context.temp_allocator)
		built, err := records.build(&it, rec, context.temp_allocator)
		doc, fault := jq.judge_build(built, err)
		if f, bad := fault.?; bad {
			cells_cut(run, ins, cut)
			tell_fault(ins, f)
			return false
		}
		switch {
		case cells && writes_cells(o):
			cut = int(rec.at) + len(rec.text)
		case cells == writes_cells(o):
			put_document(run, ins, &doc) or_return
		case cells:
			emit(&run.output, jq.document_value(doc))
		case:
			emit_rows(run, ins, jq.document_value(doc))
		}
	}
	if f, bad := it.fault.?; bad {
		cells_cut(run, ins, cut)
		tell_fault(ins, f)
		return false
	}
	return true
}

// The text `v` written as a table's rows. A text whose root is an array is a list of rows, as the library's writer
// takes it, its comments placed as the writer places a document's, and a record is a row.
@(private = "file")
emit_rows :: proc(run: ^Run, ins: ^Inputs, v: jq.Value) {
	if ins.framing != .Concatenated || jq.kind(v) != .Array {
		emit(&run.output, v)
		return
	}
	table_root(&run.output, v)
	it := jq.iterate(v)
	for _, row in jq.next_member(&it) {
		emit(&run.output, row)
	}
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
	if doc, fault := jq.build_text(ins.data[:end], ins.as, runtime.heap_allocator()); fault == nil {
		_ = put_document(run, ins, &doc)
	}
}

// The document `doc` of the open file written by the library's writer in the output's format and layout, and a
// newline after it unless it ends with one or is empty, as a CSV file with no header is. False, told, when it cannot be.
@(private = "file")
put_document :: proc(run: ^Run, ins: ^Inputs, doc: ^core.Document) -> bool {
	o := &run.opts
	as := cells_written_as(o) if writes_cells(o) else json.as(.Jsonc if writes_comments(o) else .Json, {max_depth = o.max_depth})
	out := &run.output
	text, _, err := core.write(doc, out.layout.opts, as, allocator = context.temp_allocator)
	if err.kind != .None {
		flush_some(out, force = true)
		if err.kind == .Too_Deep {
			message.write_stderr("stury: error: %s: nesting this deep is not written in the format it was read in\n", ins.name)
		} else {
			message.write_stderr("stury: error: %s: cannot write the value: %v\n", ins.name, err.kind)
		}
		return false
	}
	write.put_text(&out.buf, string(text))
	if len(text) > 0 && text[len(text) - 1] != '\n' {
		jq.put_byte(&out.buf, '\n')
	}
	flush_some(out)
	return true
}

// Refuses an input `--in-place` cannot rewrite. A temporary file and a rename replace a name with a regular file, so
// standard input, a symbolic link, a pipe, a device and a directory are refused. `lstat` does not open the path, which
// would block on a pipe.
refuse_in_place_inputs :: proc(files: []string) {
	for path in files {
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
