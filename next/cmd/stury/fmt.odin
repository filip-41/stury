package main

// `stury fmt` writes each FILE back in the printer's layout, or in another format (`--from`, `--to`). A plain run
// writes each file's output as it is made, `--check` holds it to compare with the file and writes nothing, and
// `--in-place` holds it and replaces the file through a temporary one beside it. A text written in its own family,
// JSON, JSONC or NDJSON as one of those or CSV as CSV, is written by the library's writer, which keeps every literal as
// written, a repeated key and, where the output has them, the comments. Across families a value is written as `.`
// writes it.

import "base:runtime"
import "core:bytes"
import "core:os"
import core "../../core"
import "../../core/write"
import records "../../core/records"
import dsv "../../dsv"
import json "../../json"
import "jq"
import "message"

// fmt --check's exit status: a file is not already in the printer's layout.
FMT_EXIT_DIFFERS :: 1

// `stury fmt`, which reads and writes the files and exits.
fmt_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	o := &run.opts
	if flag := fmt_refused_option(o, cli); flag != "" {
		usage_error("%s has no use with fmt: it runs no filter and writes each input's own format", flag)
	}
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
		for path in files {
			if path == "-" {
				usage_error("--in-place needs a FILE: it cannot rewrite standard input")
			}
			// A temporary file and a rename replace a name with a regular file, so a symbolic link, a pipe, a device and
			// a directory are refused. `lstat` does not open the path, which would block on a pipe.
			if info, err := os.lstat(path, context.temp_allocator); err == nil && info.type != .Regular {
				usage_error("--in-place needs a regular file: %s is not one", path)
			}
		}
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

// The first option given that only a filter run honours, or "". fmt reads files and writes their own format, so it
// runs no filter and reshapes neither its input nor its output.
@(private = "file")
fmt_refused_option :: proc(o: ^Opts, cli: ^Cli) -> string {
	switch {
	case o.raw0:            return "--raw-output0"
	case o.raw:             return "-j" if o.join else "-r"
	case cli.compact_given: return "-c"
	case o.ascii:           return "-a"
	case o.sort_keys:       return "-S"
	case cli.color_set:     return "-C"
	case o.raw_input:       return "-R"
	case o.null_input:      return "-n"
	case o.slurp:           return "-s"
	case o.from_file:       return "-f"
	case o.seq:             return "--seq"
	case o.stream_errors:   return "--stream-errors"
	case o.stream:          return "--stream"
	case o.exit_status:     return "-e"
	case o.explain:         return "--explain"
	case cli.binding_flag != "": return cli.binding_flag
	// jq's layout of it, newlines without indent, is not one the writer writes.
	case o.indent == 0:     return "--indent 0"
	case cli.lib_dirs != nil: return "-L"
	}
	return ""
}

// Each of `ins.files` formatted in turn. `ins.failures` counts the files that did not open, read or write, and the
// output comes to FMT_EXIT_DIFFERS when --check finds one that differs.
@(private = "file")
fmt_files :: proc(run: ^Run, ins: ^Inputs) {
	o := &run.opts
	out := &run.output
	heap := runtime.heap_allocator()
	for path in ins.files {
		f, read := open_file(path)
		if read {
			ins.data, read = read_file(f)
		}
		if !read {
			ins.failures += 1
			continue
		}
		ins.name = file_name(path)
		fmt_text(run, ins)
		table_end(out)
		if out.table != nil {
			out.table = table_start(run)
		}
		text := out.buf.buf[:out.buf.cursor]
		switch {
		case o.check:
			if !bytes.equal(text, ins.data) {
				out.ret = FMT_EXIT_DIFFERS
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

// The texts of the open file written, or the run ended at its first fault, after the texts before it. A text written
// in its own family is built whole when it is the file's one text, else each record is.
@(private = "file")
fmt_text :: proc(run: ^Run, ins: ^Inputs) {
	o := &run.opts
	data := ins.data
	cells := reads_cells(o)
	if !cells && json.blank(data, ins.spec.?) {
		return
	}
	heap := runtime.heap_allocator()
	if !cells && ins.framing == .Concatenated && spine_print(ins, put_fmt) {
		return
	}
	if cells == writes_cells(o) && (cells || ins.framing == .Concatenated) {
		doc, fault, texts := build_whole(data, ins.source, heap)
		// A delimited text's fault is told at the record it is in, which the records below reach.
		if f, bad := fault.?; bad && !cells {
			fmt_failed(run, ins, f)
		} else if !bad && !texts {
			put_document(run, ins, &doc)
			core.destroy(&doc)
			return
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
		doc, fault := jq.judge_build(built, err, rec.at)
		if f, bad := fault.?; bad {
			cells_cut(run, ins, cut)
			fmt_failed(run, ins, f)
		}
		switch {
		case cells && writes_cells(o):
			cut = int(rec.at) + len(rec.text)
		case cells == writes_cells(o):
			put_document(run, ins, &doc)
		case:
			emit(&run.output, jq.document_value(doc))
		}
	}
	if f, bad := it.fault.?; bad {
		cells_cut(run, ins, cut)
		fmt_failed(run, ins, f)
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
		put_document(run, ins, &doc)
	}
}

// The document `doc` of the open file written by the library's writer in the output's format and layout, and a
// newline after it unless it ends with one or is empty, as a CSV file with no header is.
@(private = "file")
put_document :: proc(run: ^Run, ins: ^Inputs, doc: ^core.Document) {
	o := &run.opts
	as := dsv.as(.Csv if o.to == .Csv else .Tsv) if writes_cells(o) else json.as(.Jsonc if writes_comments(o) else .Json, {max_depth = o.max_depth})
	out := &run.output
	text, _, err := core.write(doc, out.layout.opts, as, allocator = context.temp_allocator)
	if err.kind != .None {
		flush_some(out, force = true)
		if err.kind == .Too_Deep {
			message.write_stderr("stury: error: %s: nesting past %d levels is not written in the format it was read in\n", ins.name, core.MAX_DEPTH)
		} else {
			message.write_stderr("stury: error: %s: cannot write the value: %v\n", ins.name, err.kind)
		}
		finish(run, EXIT_INPUT)
	}
	write.put_text(&out.buf, string(text))
	if len(text) > 0 && text[len(text) - 1] != '\n' {
		jq.put_byte(&out.buf, '\n')
	}
	flush_some(out)
}

// A fault in the open file ends the run, told as `NAME:LINE:COLUMN: SENTENCE`, a JSON or CSV text's as a parse error,
// as jq calls it, and a JSONC or JSON5 text's as a filter run tells it.
@(private = "file")
fmt_failed :: proc(run: ^Run, ins: ^Inputs, fault: core.Fault) -> ! {
	flush_some(&run.output, force = true)
	f := literal_cut(ins.data, fault, ins.framing)
	what := "parse error" if reads_cells(&run.opts) || ins.spec == .Json else "error"
	message.write_stderr("stury: %s: %s\n%s", what, fault_told(ins.name, ins.data, f, ins.spec), fault_note(ins.data, f, ins.spec, &run.opts))
	finish(run, EXIT_INPUT)
}

// Replaces `path` with `text` through a temporary file beside it, so a reader sees the old file or the new one.
@(private = "file")
rewrite_file :: proc(path: string, text: []byte) -> bool {
	info, serr := os.stat(path, context.temp_allocator)
	if serr != nil {
		return write_failed(path, serr)
	}
	// A bare name's dir is "", which create_temp_file reads as the system temp dir, where the rename may cross devices.
	dir := os.dir(path)
	f, terr := os.create_temp_file(dir if dir != "" else ".", ".stury-fmt-*.tmp")
	if terr != nil {
		return write_failed(path, terr)
	}
	temp_info, ierr := os.fstat(f, context.temp_allocator)
	if ierr != nil {
		os.close(f)
		return write_failed(path, ierr)
	}
	temp := temp_info.fullpath
	err: os.Error
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

@(private = "file")
write_failed :: proc(path: string, err: os.Error) -> bool {
	message.write_stderr("stury: error: Could not write file %s: %s\n", path, strerror(err))
	return false
}
