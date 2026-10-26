package main

// `stury fmt`: write each FILE back in the printer's layout, or transcode it (`--from`, `--to`). A plain run writes
// each file's values as they are made, `--check` holds a file's output to compare it with the bytes and writes
// nothing, and `--in-place` holds it and replaces the file through a temporary one beside it. The readers are the
// filter's. A JSON, JSONC or NDJSON value written as one of those keeps its scalars' and keys' source spelling and
// every member, repeated keys included, and changes only its layout (`fmt_verbatim`, and `fmt_pieces` for a text
// large enough to cut); a value written as CSV or TSV is made of cells, as `.` makes them.

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import csv "../../csv"
import json "../../json"
import "jq"

// fmt --check's exit status: a file is not already in the printer's layout.
FMT_EXIT_DIFFERS :: 1

// The first option given that only a filter run honours, or "". fmt reads files and writes their own format, so it
// runs no filter and reshapes neither its input nor its output.
@(private = "file")
fmt_refused_option :: proc(o: ^Opts, cli: ^Cli) -> string {
	switch {
	case o.raw0:
		return "--raw-output0"
	case o.raw:
		return "-j" if o.join else "-r"
	case cli.compact_given:
		return "-c"
	case o.ascii:
		return "-a"
	case o.sort_keys:
		return "-S"
	case cli.color_set:
		return "-C"
	case o.raw_input:
		return "-R"
	case o.null_input:
		return "-n"
	case o.slurp:
		return "-s"
	case o.from_file:
		return "-f"
	case o.seq:
		return "--seq"
	case o.stream_errors:
		return "--stream-errors"
	case o.stream:
		return "--stream"
	case o.exit_status:
		return "-e"
	case o.strict_limits:
		return "--strict-limits"
	case o.explain:
		return "--explain"
	case cli.binding_flag != "":
		return cli.binding_flag
	case o.indent == 0:
		return "--indent 0" // jq's layout of it, newlines without indent, is not one the formatter writes
	case cli.lib_dirs != nil:
		return "-L"
	}
	return ""
}

// `stury fmt`, which reads and writes the files and exits.
fmt_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	o := &run.opts
	if flag := fmt_refused_option(o, cli); flag != "" {
		usage_error("%s has no use with fmt: it runs no filter and writes each input's own format", flag)
	}
	names := cli.files[:] if len(cli.files) > 0 else STDIN_ONLY
	if len(cli.files) == 0 && is_terminal(os.stdin) && is_terminal(os.stdout) {
		usage(EXIT_USAGE, true) // as check, rather than wait on the keyboard
	}
	switch {
	case o.in_place && o.check:
		usage_error("--in-place rewrites each file; --check only reads it")
	case o.in_place && o.to != o.from:
		usage_error("--in-place writes each file back as its own format: --from %s and --to %s differ",
		            FORMATS[o.from].name, FORMATS[o.to].name)
	case o.in_place:
		for name in names {
			if name == "-" {
				usage_error("--in-place needs a FILE: it cannot rewrite standard input")
			}
			// A temporary file and a rename replace a name with a regular file, so a symbolic link, a pipe, a
			// device and a directory are refused. `lstat` does not open the path, which would block on a pipe.
			if info, err := os.lstat(name, context.temp_allocator); err == nil && info.type != .Regular {
				usage_error("--in-place needs a regular file: %s is not one", name)
			}
		}
	}
	run.req.dialect = .Jsonc if o.from == .Jsonc else .Json
	run.req.limits = jq.lifted
	run.name_faults = true
	run.verbatim = !reads_cells(o) && !writes_cells(o)
	reserve(&run.out, FLUSH_AT * 2)
	run.spill = {at = FLUSH_AT, flush = spill_out, data = run}
	finish(run, fmt_files(run, names))
}

@(private = "file")
fmt_files :: proc(run: ^Run, files: []string) -> (code: int) {
	o := &run.opts
	check, in_place := o.check, o.in_place
	differ, failures := false, 0
	for &name in files {
		ins: Inputs
		inputs_init(&ins, run, ([^]string)(&name)[:1])
		ins.may_stream = false // a file is formatted whole, and --check needs every byte of it
		open_next(&ins)
		if ins.failures > 0 {
			failures += 1
			delete(ins.spent)
			continue
		}
		run.name, run.whole = ins.name, ins.data
		run.silent = check || in_place
		clear(&run.out)
		run.rows_begun = false
		if writes_cells(o) && !reads_cells(o) {
			run.table = table_make(o)
		}
		// Past MAX_DEPTH the library and the printer recurse, so they run on the interpreter's stack, as a filter
		// run does (`--max-depth` raises the limit to 2^20).
		if jq.lifted.max_depth > json.MAX_DEPTH {
			run_deep(run, &ins, fmt_input)
		} else {
			fmt_input(run, &ins)
		}
		if run.table != nil && run.table.grow && !write_held_rows(run) {
			finish(run, EXIT_INPUT)
		}
		switch {
		case check:
			differ = differ || !bytes.equal(run.out[:], ins.data)
		case in_place:
			if !bytes.equal(run.out[:], ins.data) && !rewrite_file(ins.name, run.out[:]) {
				failures += 1
			}
		case:
			flush_some(run, force = true)
		}
		run.silent, run.table = false, nil
		clear(&run.out)
		free_data({ins.data, ins.mapped})
		delete(ins.spent)
	}
	switch {
	case failures > 0:
		return EXIT_USAGE
	case differ:
		return FMT_EXIT_DIFFERS
	}
	return 0
}

@(private = "file")
fmt_input :: proc(run: ^Run, ins: ^Inputs) {
	if reads_cells(&run.opts) {
		fmt_cells(run, ins)
	} else {
		fmt_texts(run, ins)
	}
}

// Formats the JSON, JSONC or NDJSON texts of one open input, as `stury .` reads them and the printer writes them.
// A value's memory is an arena's, emptied once the value is printed, as a filter run empties it once the next input
// is wanted.
@(private = "file")
fmt_texts :: proc(run: ^Run, ins: ^Inputs) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.eprintln("stury: error: out of memory")
		finish(run, EXIT_INPUT)
	}
	old := context.allocator
	defer {
		context.allocator = old
		virtual.arena_destroy(&arena)
	}
	context.allocator = virtual.arena_allocator(&arena)
	if run.verbatim && fmt_pieces(run, ins) {
		return
	}
	for {
		v, msg, status := next_input(ins)
		switch status {
		case .Value:
			if run.verbatim {
				fmt_verbatim(run, v.(jq.Ref))
			} else {
				print_jq(run, v)
				run.pieces_root = {}
			}
			virtual.arena_free_all(&arena)
			free_all(context.temp_allocator)
			free_spent(ins)
		case .Error:
			parse_failed(run, msg, ins.fault_note)
			finish(run, EXIT_INPUT)
		case .More:
			return
		}
	}
}

// The open input written in pieces on the pool when it is one JSON text, an array or an object holding a large one
// (`print_root_pieces`). It returns false, with nothing written, when it is not, and `fmt_texts` reads it whole.
@(private = "file")
fmt_pieces :: proc(run: ^Run, ins: ^Inputs) -> bool {
	at, limit, trailing, found := next_text(ins)
	if !found || !trailing || limit != len(ins.data) || run.opts.from == .Jsonc || jq.lifted.max_depth > json.MAX_DEPTH {
		return false
	}
	if !print_root_pieces(run, ins.data[at:]) {
		return false
	}
	ins.pos = limit
	return true
}

// One value of the open input written in the layout of `output_layout`, from its source text: every scalar and key
// as authored and every member of an object, by the library's `marshal` of a document. A JSONC value keeps its
// comments under `--to jsonc` and loses them, with its trailing commas, otherwise. The text ends in one newline.
@(private = "file")
fmt_verbatim :: proc(run: ^Run, r: jq.Ref) {
	l := output_layout(run)
	if l.drop_comments {
		clear(&r.doc.facts)
	}
	text, err := json.marshal(r.doc, {pretty = l.pretty, indent = u8(max(l.indent, 0)), trailing_newline = true})
	if err == .Too_Deep {
		fmt.eprintf("stury: error: %s: nesting past %d levels is not written in the format it was read in\n", run.name, json.MAX_DEPTH)
		finish(run, EXIT_INPUT)
	} else if err != .None {
		fmt.eprintf("stury: error: %s: cannot write the value: %v\n", run.name, err)
		finish(run, EXIT_INPUT)
	}
	append(&run.out, ..text)
	flush_some(run)
}

// Formats one open CSV or TSV input. The header record is read first. A CSV-like output writes it and every record
// back through `csv.write_record`, so quoting is normalised and a header with no records is still written; any
// other output reads each record as an object of cells and prints it (`--from csv --to json`).
@(private = "file")
fmt_cells :: proc(run: ^Run, ins: ^Inputs) {
	o := &run.opts
	c := Cells{dialect = FORMATS[o.from].dialect, data = ins.data}
	c.whole = csv.records(c.data, {dialect = c.dialect}, runtime.heap_allocator())
	c.it = &c.whole
	defer fmt_cells_done(&c)
	rec, ok := csv.next_record(&c.whole)
	if ok {
		if msg := read_header(ins, &c, rec); msg != "" {
			fmt_cells_fault(run, msg)
		}
		if writes_cells(o) {
			fmt_cells_write(run, &c, rec)
			for {
				r, more := csv.next_record(&c.whole)
				if !more {
					break
				}
				fmt_cells_write(run, &c, r)
			}
		} else {
			fmt_cells_objects(run, &c)
		}
	}
	if e, bad := cells_err(&c); bad {
		fmt_cells_fault(run, cells_fault(ins, &c, e))
	}
}

@(private = "file")
fmt_cells_write :: proc(run: ^Run, c: ^Cells, rec: csv.Record) {
	o := &run.opts
	cells := make([]Maybe(string), len(rec.fields), context.temp_allocator)
	for f, i in rec.fields {
		if f.lo == f.hi {
			continue
		}
		text, _, _ := csv.field_text(rec.src, f, c.dialect, context.temp_allocator)
		cells[i] = string(text)
	}
	if err := csv.write_record(&run.out, cells, FORMATS[o.to].dialect, at_start = !run.rows_begun); err != .None {
		t := Table{dialect = FORMATS[o.to].dialect, format = FORMATS[o.to].name}
		fmt.eprintf("stury: error: %s\n", row_refusal(&t, err))
		finish(run, EXIT_INPUT)
	}
	run.rows_begun = true
	free_all(context.temp_allocator)
}

@(private = "file")
fmt_cells_objects :: proc(run: ^Run, c: ^Cells) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.eprintln("stury: error: out of memory")
		finish(run, EXIT_INPUT)
	}
	old := context.allocator
	defer {
		context.allocator = old
		virtual.arena_destroy(&arena)
	}
	context.allocator = virtual.arena_allocator(&arena)
	for {
		rec, more := csv.next_record(&c.whole)
		if !more {
			return
		}
		print_jq(run, record_object(c, rec))
		virtual.arena_free_all(&arena)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
fmt_cells_done :: proc(c: ^Cells) {
	csv.destroy(&c.whole)
	for name in c.header {
		delete(name, runtime.heap_allocator())
	}
	delete(c.header, runtime.heap_allocator())
}

// A fault in a CSV input ends the run as a filter run tells it: `stury: parse error: FILE:LINE:COLUMN: what`.
@(private = "file")
fmt_cells_fault :: proc(run: ^Run, msg: string) -> ! {
	parse_failed(run, msg)
	finish(run, EXIT_INPUT)
}

// Replaces `path` with `text` through a temporary file beside it, so a reader sees the old file or the new one.
@(private = "file")
rewrite_file :: proc(path: string, text: []byte) -> bool {
	info, serr := os.stat(path, context.temp_allocator)
	if serr != nil {
		fmt_write_failed(path, serr)
		return false
	}
	// A bare name's dir is "", which create_temp_file reads as the system temp dir, where the rename may cross
	// devices.
	dir := os.dir(path)
	f, terr := os.create_temp_file(dir if dir != "" else ".", ".stury-fmt-*.tmp")
	if terr != nil {
		fmt_write_failed(path, terr)
		return false
	}
	temp, ierr := temp_name(f)
	if ierr != nil {
		os.close(f)
		fmt_write_failed(path, ierr)
		return false
	}
	ok := true
	for at := 0; ok && at < len(text); {
		n, werr := os.write(f, text[at:])
		switch {
		case werr != nil:
			fmt_write_failed(path, werr)
			ok = false
		case n == 0:
			fmt.eprintf("stury: error: Could not write file %s: Short write\n", path)
			ok = false
		case:
			at += n
		}
	}
	if ok {
		keep_owner(f, path) // before the mode: changing the owner clears the setuid and setgid bits
		if merr := os.fchmod(f, info.mode); merr != nil {
			fmt_write_failed(path, merr)
			ok = false
		} else if yerr := os.sync(f); yerr != nil {
			fmt_write_failed(path, yerr)
			ok = false
		}
	}
	os.close(f)
	if ok {
		if rerr := os.rename(temp, path); rerr != nil {
			fmt_write_failed(path, rerr)
			ok = false
		}
	}
	if !ok {
		os.remove(temp)
	}
	return ok
}

@(private = "file")
temp_name :: proc(f: ^os.File) -> (string, os.Error) {
	info, err := os.fstat(f, context.temp_allocator)
	return info.fullpath, err
}

@(private = "file")
fmt_write_failed :: proc(path: string, err: os.Error) {
	fmt.eprintf("stury: error: Could not write file %s: %s\n", path, strerror(err))
}
