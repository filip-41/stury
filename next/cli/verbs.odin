package cli

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "stury:engine"
import "stury:jq"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:lib/schema/ddl"
import "stury:lib/schema/model"
import "stury:lib/schema/schema"

// ---- `--quarantine` JSONL Writer ----

Quarantine_Writer :: struct {
	file:         ^os.File,
	close_file:   bool,
	active:       bool,
	write_failed: bool,
	path:         string,
	alloc:        runtime.Allocator,
}

quarantine_open :: proc(qw: ^Quarantine_Writer, path: string, stderr_w: io.Writer, alloc: runtime.Allocator) -> bool {
	if path == "/dev/stdout" || path == "/dev/stderr" {
		qw^ = {file = os.stdout if path == "/dev/stdout" else os.stderr, active = true, path = path, alloc = alloc}
		return true
	}
	f, err := os.open(path, {.Write, .Create}, {.Read_User, .Write_User, .Read_Group, .Read_Other})
	if err == nil {
		if err = os.truncate(f, 0); err != nil {
			os.close(f)
		}
	}
	if err != nil {
		if stderr_w.procedure != nil {
			fmt.wprintf(stderr_w, "stury: error: Could not open file %s: %s\n", path, os.error_string(err))
		}
		qw^ = {}
		return false
	}
	qw^ = {file = f, close_file = true, active = true, path = path, alloc = alloc}
	return true
}

quarantine_close :: proc(qw: ^Quarantine_Writer, stderr_w: io.Writer) {
	if qw == nil || !qw.active { return }
	if ferr := os.flush(qw.file); ferr != nil {
		qw.write_failed = true
		if stderr_w.procedure != nil {
			fmt.wprintf(stderr_w, "stury: error: Could not write file %s: %s\n", qw.path, os.error_string(ferr))
		}
	}
	if qw.close_file && qw.file != nil {
		if cerr := os.close(qw.file); cerr != nil && !qw.write_failed {
			qw.write_failed = true
			if stderr_w.procedure != nil {
				fmt.wprintf(stderr_w, "stury: error: Could not write file %s: %s\n", qw.path, os.error_string(cerr))
			}
		}
	}
	qw.active, qw.file, qw.close_file = false, nil, false
}

@(private = "file")
tt_kv :: proc(tt: ^engine.Write_Token_Tape, k: string, kind: engine.Write_Token_Kind, v: string) -> bool {
	return engine.token_tape_take(tt, .Key, k) == nil && engine.token_tape_take(tt, kind, v) == nil
}

@(private = "file")
quarantine_begin_entry :: proc(tt: ^engine.Write_Token_Tape, rec_no: i64, at_str: string, text: []u8, alloc: runtime.Allocator) -> bool {
	if engine.token_tape_start(tt, false, 0, alloc) != nil { return false }
	num_buf: [24]u8
	return engine.token_tape_take(tt, .Object, "") == nil &&
		tt_kv(tt, "record", .Number, fmt.bprintf(num_buf[:], "%d", rec_no)) &&
		tt_kv(tt, "at", .String, at_str) &&
		tt_kv(tt, "text", .String, string(text)) &&
		engine.token_tape_take(tt, .Key, "problem") == nil
}

@(private = "file")
quarantine_emit_doc :: proc(qw: ^Quarantine_Writer, tt: ^engine.Write_Token_Tape, alloc: runtime.Allocator) -> bool {
	if engine.token_tape_take(tt, .Close, "") != nil {
		qw.write_failed = true
		return false
	}
	doc, derr := engine.token_tape_document(tt)
	if derr != nil {
		qw.write_failed = true
		return false
	}
	txt, _, werr := engine.write(&doc, engine.spec_of_id(.Json), {}, alloc)
	if werr != nil {
		qw.write_failed = true
		return false
	}
	defer delete(txt, alloc)
	line := make([]u8, len(txt) + 1, alloc)
	defer delete(line, alloc)
	copy(line, txt)
	line[len(txt)] = '\n'
	n, ferr := os.write(qw.file, line)
	if ferr != nil || n < len(line) {
		qw.write_failed = true
		return false
	}
	return true
}

quarantine_write_bad :: proc(
	qw: ^Quarantine_Writer,
	rec_no: i64,
	display: string,
	err: tape.Error,
	text: []u8,
	sp: engine.Spec,
	alloc: runtime.Allocator,
	place_src: []u8 = nil,
	place_off: u64 = 0,
) -> bool {
	if qw == nil || !qw.active || qw.write_failed { return false }
	e, _ := engine.entry_of_spec(sp)
	psrc := place_src if len(place_src) > 0 else text
	err_buf: [512]u8
	msg := tape.error_message(err_buf[:], err, psrc, e.format)
	at_str, at_owned := display, false
	if f, is_f := err.(tape.Fault); is_f && f.at != tape.NO_BYTE && !e.binary {
		lidx := tape.Line_Index{allocator = alloc}
		defer tape.destroy_line_index(&lidx)
		pl := tape.offset_place(psrc, &lidx, min(place_off + f.at, u64(len(psrc))), 0, 1, alloc)
		at_str, at_owned = fmt.aprintf("%s:%d:%d", display, pl.line, pl.col, allocator = alloc), true
	}
	defer if at_owned { delete(at_str, alloc) }

	tt: engine.Write_Token_Tape
	if !quarantine_begin_entry(&tt, rec_no, at_str, text, alloc) {
		engine.token_tape_drop(&tt)
		qw.write_failed = true
		return false
	}
	defer engine.token_tape_drop(&tt)
	ok := engine.token_tape_take(&tt, .Object, "") == nil &&
		tt_kv(&tt, "title", .String, "Bad record") &&
		tt_kv(&tt, "status", .Number, "400") &&
		engine.token_tape_take(&tt, .Key, "errors") == nil &&
		engine.token_tape_take(&tt, .Array, "") == nil &&
		engine.token_tape_take(&tt, .Object, "") == nil &&
		tt_kv(&tt, "pointer", .String, "") &&
		tt_kv(&tt, "code", .String, "walk") &&
		tt_kv(&tt, "message", .String, msg if msg != "" else "parse error") &&
		engine.token_tape_take(&tt, .Close, "") == nil &&
		engine.token_tape_take(&tt, .Close, "") == nil &&
		engine.token_tape_take(&tt, .Close, "") == nil
	if !ok {
		qw.write_failed = true
		return false
	}
	return quarantine_emit_doc(qw, &tt, alloc)
}

@(private = "file")
make_problem_entries :: proc(entries: []engine.Check_Error, alloc: runtime.Allocator) -> []model.Error_Entry {
	me := make([]model.Error_Entry, len(entries), alloc)
	for ce, i in entries {
		mk := model.Error_Kind(int(ce.kind)) if int(ce.kind) <= int(model.Error_Kind.Duplicate_Key) else .Check_Failed
		entry := model.Error_Entry{kind = mk, at = ce.at, pointer = ce.instance_location}
		if mk == .Wrong_Kind && ce.expected != "" {
			entry.want = {text = strings.clone(ce.expected, alloc)}
		} else if mk == .Missing_Field && ce.expected != "" {
			entry.operand = fmt.aprintf("member %q", ce.expected, allocator = alloc)
		} else {
			entry.operand = schema.error_message(ce, alloc)
		}
		me[i] = entry
	}
	return me
}

@(private = "file")
free_problem_entries :: proc(me: []model.Error_Entry, alloc: runtime.Allocator) {
	for item in me {
		if item.want.text != "" { delete(item.want.text, alloc) }
		if item.operand != "" { delete(item.operand, alloc) }
	}
	delete(me, alloc)
}

quarantine_write_invalid :: proc(
	qw: ^Quarantine_Writer,
	rec_no: i64,
	display: string,
	entries: []engine.Check_Error,
	src: []u8,
	alloc: runtime.Allocator,
	place_src: []u8 = nil,
	place_off: u64 = 0,
	redact_paths: []string = nil,
) -> bool {
	if qw == nil || !qw.active || qw.write_failed { return false }
	psrc := place_src if len(place_src) > 0 else src
	lidx := tape.Line_Index{allocator = alloc}
	defer tape.destroy_line_index(&lidx)
	at_str: string
	if len(entries) > 0 {
		pl := tape.offset_place(psrc, &lidx, min(place_off + entries[0].at, u64(len(psrc))), 0, 1, alloc)
		at_str = fmt.aprintf("%s:%d:%d", display, pl.line, pl.col, allocator = alloc)
	} else {
		at_str = fmt.aprintf("%s:1:1", display, allocator = alloc)
	}
	defer delete(at_str, alloc)

	me := make_problem_entries(entries, alloc)
	defer free_problem_entries(me, alloc)

	tt: engine.Write_Token_Tape
	if !quarantine_begin_entry(&tt, rec_no, at_str, src, alloc) {
		engine.token_tape_drop(&tt)
		qw.write_failed = true
		return false
	}
	defer engine.token_tape_drop(&tt)
	popts := model.Problem_Opts{redact = len(redact_paths) > 0, redact_paths = redact_paths}
	if model.write_problem_tokens(&tt, me, {title = "Invalid input", status = 422}, false, alloc, popts) != nil {
		qw.write_failed = true
		return false
	}
	return quarantine_emit_doc(qw, &tt, alloc)
}

// ---- Schema Compilation & Path-Contained Ref Loader ----

@(private)
Ref_Ctx :: struct {
	dir:   string,
	alloc: runtime.Allocator,
}

@(private = "file")
schema_vfs_load_bytes :: proc(data: rawptr, uri: string, alloc: runtime.Allocator) -> ([]u8, bool, bool) {
	rc := (^Ref_Ctx)(data)
	path := uri[len("file://"):] if strings.has_prefix(uri, "file://") else uri
	if !strings.has_prefix(uri, "file://") && strings.contains(uri, "://") {
		return nil, false, false
	}
	cand, joined := path, ""
	if !filepath.is_abs(path) && rc.dir != "" {
		j, je := filepath.join({rc.dir, path}, alloc)
		if je != nil { return nil, false, false }
		joined, cand = j, j
	}
	defer if joined != "" { delete(joined, alloc) }
	if rc.dir != "" {
		ad, de := os.get_absolute_path(rc.dir, alloc)
		ac, ce := os.get_absolute_path(cand, alloc)
		defer if de == nil { delete(ad, alloc) }
		defer if ce == nil { delete(ac, alloc) }
		if de != nil || ce != nil { return nil, false, false }
		base, target := strings.trim_right(ad, "/\\"), strings.trim_right(ac, "/\\")
		if !(target == base || (len(target) > len(base) && (target[len(base)] == '/' || target[len(base)] == '\\') && strings.has_prefix(target, base))) {
			return nil, false, false
		}
	}
	raw, rerr := os.read_entire_file_from_path(cand, alloc)
	if rerr == nil { return raw, true, true }
	return nil, false, false
}

@(private)
compile_schema_file :: proc(o: ^Options, path: string, stderr_w: io.Writer, alloc: runtime.Allocator) -> (^schema.Compiled, Ref_Ctx, bool) {
	if o.schema_ref != "" && !os.is_dir(o.schema_ref) {
		fmt.wprintf(stderr_w, "stury: error: --schema-ref %s is not a directory\n", o.schema_ref)
		return nil, {}, false
	}
	data, rok := read_path_or_stdin(path, false, stderr_w, alloc)
	if !rok { return nil, {}, false }
	defer delete(data, alloc)

	dir := o.schema_ref if o.schema_ref != "" else filepath.dir(path)
	if dir == "" { dir = "." }
	rc := Ref_Ctx{dir = dir, alloc = alloc}
	sp := engine.spec_of_id(.Json)
	if se, _, ok := engine.format_of_path(path); ok { sp = se.spec }
	sopts := schema.Options{
		format_assert = o.format_assert,
		base          = path,
		loader        = {data = &rc, load_bytes = schema_vfs_load_bytes},
		draft         = o.schema_draft,
		dups          = o.dups,
		budget        = o.budget,
	}
	ext := filepath.ext(path)
	if strings.equal_fold(ext, ".sql") || strings.equal_fold(ext, ".ddl") {
		d, derr := ddl.compile_description(data, {dups = o.dups, budget = o.budget}, alloc)
		if derr.kind != .None {
			if derr.line > 0 {
				fmt.wprintf(stderr_w, "stury: error: schema %s:%d:%d: %s\n", path, derr.line, derr.col, derr.message)
			} else {
				fmt.wprintf(stderr_w, "stury: error: schema %s: %s\n", path, derr.message)
			}
			ddl.error_destroy(&derr)
			return nil, {}, false
		}
		desc, aerr := new(engine.Schema_Description, alloc)
		if aerr != nil || desc == nil {
			engine.destroy_schema_description(&d)
			fmt.wprintf(stderr_w, "stury: error: schema %s: out of memory\n", path)
			return nil, {}, false
		}
		desc^ = d
		c, cerr := schema.compile_description(desc, sopts, alloc)
		if cerr.kind != .None {
			engine.destroy_schema_description(desc)
			free(desc, alloc)
			fmt.wprintf(stderr_w, "stury: error: schema %s: %s\n", path, cerr.message)
			schema.error_destroy(&cerr)
			return nil, {}, false
		}
		c.owns_description = true
		return c, rc, true
	}
	se, _ := engine.entry_of_spec(sp)
	c: ^schema.Compiled
	cerr: schema.Error
	if se.id == .Json {
		c, cerr = schema.compile_json(data, sopts, alloc)
	} else {
		bo := tape.Options{budget = o.budget, dups = o.dups}
		if se.family == .Yaml && o.yaml_schema_set {
			bo.format = tape.Yaml_Options{dialect = o.yaml_schema}
		}
		doc, berr := engine.build(data, sp, bo, alloc)
		if berr != nil {
			_ = print_tape_error(stderr_w, path, berr, data, sp)
			return nil, {}, false
		}
		defer tape.destroy_document(&doc)
		c, cerr = schema.compile_document(&doc, tape.ROOT, sopts, alloc)
	}
	if cerr.kind != .None {
		if cerr.kind == .Parse && cerr.tape_err != nil {
			_ = print_tape_error(stderr_w, path, cerr.tape_err, data, sp)
		} else if cerr.at != tape.NO_BYTE && !se.binary && len(data) > 0 {
			print_located_error(stderr_w, "stury: error: schema", path, data, cerr.at, cerr.message)
		} else {
			fmt.wprintf(stderr_w, "stury: error: schema %s: %s\n", path, cerr.message)
		}
		schema.error_destroy(&cerr)
		return nil, {}, false
	}
	return c, rc, true
}

@(private = "file")
commit_file_output :: proc(o: ^Options, path, display: string, orig, data: []u8, check_msg: string, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	switch {
	case o.check:
		if !bytes.equal(data, orig) {
			fmt.wprintf(stderr_w, "stury: %s %s\n", display, check_msg)
			return EXIT_FALSY
		}
	case o.in_place:
		if !bytes.equal(data, orig) {
			if err := atomic_write_file(path, data, alloc); err != nil {
				fmt.wprintf(stderr_w, "stury: error: Could not write %s: %s\n", path, os.error_string(err))
				return EXIT_USAGE
			}
		}
	case !o.diff_preview:
		if !out_stream_bytes(osink, data) { return EXIT_USAGE }
	}
	return EXIT_OK
}

// ---- `stury check` ----

@(private = "file")
check_one_file :: proc(
	o: ^Options,
	sc: ^schema.Compiled,
	p: string,
	stdin_override: Maybe([]u8),
	qw: ^Quarantine_Writer,
	osink: ^Out_Stream,
	stderr_w: io.Writer,
	runner: ^tape.Runner,
	alloc: runtime.Allocator,
) -> (code: int, open_err: bool) {
	src, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
	if !rok { return EXIT_OK, true }
	defer if owned { delete(src, alloc) }

	disp := "<stdin>" if p == "-" else p
	sp, fr := detect_file_spec(o, p)
	e, _ := engine.entry_of_spec(sp)
	ro := read_opts_of(o, sp, runner)

	if e.family == .Json && fr == .Single && len(bytes.trim_space(src)) == 0 {
		fmt.wprintf(stderr_w, "stury: parse error (%s): No JSON text\n", disp)
		return EXIT_RUNTIME, false
	}
	if !e.tabular && (fr == .Lines || fr == .Seq) {
		it, ok := rec_loop_open(src, sp, fr, ro, o.skip_bad, disp, stderr_w, alloc)
		if !ok { return EXIT_RUNTIME, false }
		defer rec_loop_close(&it)
		worst := EXIT_OK
		rec_no := i64(0)
		for rec, rinfo, err in rec_loop_next(&it) {
			rec_no += 1
			if err != nil {
				_ = print_tape_error(stderr_w, disp, err, src, sp, ignoring = o.skip_bad)
				worst = max(worst, EXIT_RUNTIME)
				if qw.active { _ = quarantine_write_bad(qw, rec_no, disp, err, rec, sp, alloc, src) }
				continue
			}
			if sc != nil {
				worst = max(worst, check_bytes_schema(o, sc, disp, rec, sp, rec_no, qw, osink, stderr_w, alloc, src, rinfo.lo))
			} else if o.dups == .Refuse && !e.tabular {
				if doc, berr := engine.build(rec, sp, ro, alloc); berr != nil {
					_ = print_tape_error(stderr_w, disp, berr, rec, sp, false, src, rinfo.lo)
					worst = max(worst, EXIT_RUNTIME)
					if qw.active { _ = quarantine_write_bad(qw, rec_no, disp, berr, rec, sp, alloc, src, rinfo.lo) }
				} else {
					tape.destroy_document(&doc)
				}
			}
		}
		if it.tail_err != nil { worst = max(worst, EXIT_RUNTIME) }
		return worst, false
	}
	if sc != nil {
		return check_bytes_schema(o, sc, disp, src, sp, 1, qw, osink, stderr_w, alloc), false
	}
	err: tape.Error
	if o.dups == .Refuse && e.format != nil && .Names_Ahead not_in e.format.caps {
		doc, berr := engine.build(src, sp, ro, alloc)
		err = berr
		tape.destroy_document(&doc)
	} else {
		err = engine.validate(src, sp, ro, alloc)
	}
	if err != nil {
		_ = print_tape_error(stderr_w, disp, err, src, sp)
		return EXIT_RUNTIME, false
	}
	return EXIT_OK, false
}

run_check :: proc(o: ^Options, stdin_override: Maybe([]u8), stdout_w, stderr_w: io.Writer, runner: ^tape.Runner, alloc: runtime.Allocator) -> int {
	sc: ^schema.Compiled
	if o.schema_file != "" {
		ok: bool
		sc, _, ok = compile_schema_file(o, o.schema_file, stderr_w, alloc)
		if !ok { return EXIT_USAGE }
	}
	defer schema.destroy(sc)

	qw: Quarantine_Writer
	if o.quarantine != "" && !quarantine_open(&qw, o.quarantine, stderr_w, alloc) {
		return EXIT_USAGE
	}
	defer quarantine_close(&qw, stderr_w)

	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, false)
	fb := [1]string{"-"}
	paths := o.files[:] if len(o.files) > 0 else fb[:]
	has_open_err, worst := false, EXIT_OK

	for p in paths {
		code, oerr := check_one_file(o, sc, p, stdin_override, &qw, &osink, stderr_w, runner, alloc)
		if oerr { has_open_err = true; continue }
		worst = max(worst, code)
		if osink.failed { return report_stdout_error(stderr_w, osink.io_err) }
	}
	if !out_stream_flush(&osink) { return report_stdout_error(stderr_w, osink.io_err) }
	if qw.write_failed || has_open_err { return EXIT_USAGE }
	return worst
}

@(private = "file")
check_bytes_schema :: proc(
	o: ^Options,
	sc: ^schema.Compiled,
	display: string,
	src: []u8,
	sp: engine.Spec,
	rec_no: i64,
	qw: ^Quarantine_Writer,
	osink: ^Out_Stream,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
	place_src: []u8 = nil,
	place_off: u64 = 0,
) -> int {
	fail_walk :: proc(err: tape.Error, display: string, src: []u8, sp: engine.Spec, rec_no: i64, qw: ^Quarantine_Writer, stderr_w: io.Writer, alloc: runtime.Allocator, place_src: []u8, place_off: u64) -> int {
		_ = print_tape_error(stderr_w, display, err, src, sp, false, place_src, place_off)
		if qw != nil && qw.active { _ = quarantine_write_bad(qw, rec_no, display, err, src, sp, alloc, place_src, place_off) }
		return EXIT_RUNTIME
	}

	sink: engine.Check_Sink
	engine.check_sink_init(&sink, alloc)
	defer engine.check_sink_destroy(&sink)

	psrc := place_src if len(place_src) > 0 else src
	e, _ := engine.entry_of_spec(sp)
	use_doc := (e.family == .Dsv && o.dsv_tolerate != {}) || (e.family == .Xml && (o.xml_tolerate != {} || o.xml_arrays != .Auto))
	res: engine.Check_Result
	if use_doc {
		doc, berr := engine.build(src, sp, read_opts_of(o, sp, nil), alloc)
		if berr != nil { return fail_walk(berr, display, src, sp, rec_no, qw, stderr_w, alloc, place_src, place_off) }
		defer tape.destroy_document(&doc)
		if e.family == .Xml && o.xml_arrays == .Schema {
			if nerr := engine.apply_xml_arrays(&doc, .Schema, sc.description, alloc); nerr != nil {
				return fail_walk(nerr, display, src, sp, rec_no, qw, stderr_w, alloc, place_src, place_off)
			}
		}
		check_dups := tape.Duplicates.All if (e.family == .Xml && o.xml_arrays != .Auto && (o.dups == .Default || o.dups == .Group)) else o.dups
		res = engine.check_document(&doc, &sc.plan, {dups = check_dups, budget = o.budget}, &sink, alloc)
	} else {
		dopts := o.dsv_in if (e.family == .Dsv && (o.dsv_in_set || o.infer)) else {}
		yopts := tape.Yaml_Options{dialect = o.yaml_schema} if (e.family == .Yaml && o.yaml_schema_set) else {}
		res = engine.check_schema(src, sp, &sc.plan, {dups = o.dups, budget = o.budget}, &sink, alloc, dopts, yopts)
	}
	defer engine.check_result_destroy(&res)

	if res.walk_err != nil {
		return fail_walk(res.walk_err, display, src, sp, rec_no, qw, stderr_w, alloc, place_src, place_off)
	}
	if res.valid {
		if o.report == .Basic {
			if txt, berr := schema.write_basic_report(nil, sc.description.uri, sc.description.bases[:], {file = display}, alloc); berr.kind == .None {
				ok := out_stream_bytes_nl(osink, txt)
				delete(txt, alloc)
				if !ok { return EXIT_USAGE }
			}
		}
		return EXIT_OK
	}

	if qw != nil && qw.active {
		_ = quarantine_write_invalid(qw, rec_no, display, sink.entries[:], src, alloc, place_src, place_off, o.redact_paths[:])
	}
	entries, truncated := sink.entries[:], false
	if o.max_errors > 0 && len(entries) > o.max_errors {
		entries, truncated = entries[:o.max_errors], true
	}
	switch o.report {
	case .Lines:
		lidx := tape.Line_Index{allocator = alloc}
		defer tape.destroy_line_index(&lidx)
		snip_buf: [1024]u8
		for ce in entries {
			off := min(place_off + ce.at, u64(len(psrc)))
			pl := tape.offset_place(psrc, &lidx, off, 0, 1, alloc)
			msg := schema.error_message(ce, alloc)
			loc := ce.instance_location if ce.instance_location != "" else "/"
			if !e.binary && len(psrc) > 0 {
				if snip, has_snip := tape.error_snippet(snip_buf[:], psrc, off); has_snip {
					fmt.wprintf(stderr_w, "%s:%d:%d: %s at %s\n%s", display, pl.line, pl.col, msg, loc, snip)
					delete(msg, alloc)
					continue
				}
			}
			fmt.wprintf(stderr_w, "%s:%d:%d: %s at %s\n", display, pl.line, pl.col, msg, loc)
			delete(msg, alloc)
		}
	case .Basic:
		if txt, berr := schema.write_basic_report(entries, sc.description.uri, sc.description.bases[:], {file = display, truncated = truncated}, alloc); berr.kind == .None {
			ok := out_stream_bytes_nl(osink, txt)
			delete(txt, alloc)
			if !ok { return EXIT_USAGE }
		}
	case .Problem:
		me := make_problem_entries(entries, alloc)
		defer free_problem_entries(me, alloc)
		tt: engine.Write_Token_Tape
		if engine.token_tape_start(&tt, false, 0, alloc) == nil {
			defer engine.token_tape_drop(&tt)
			popts := model.Problem_Opts{redact = len(o.redact_paths) > 0, redact_paths = o.redact_paths[:]}
			if model.write_problem_tokens(&tt, me, {title = "Invalid input", status = 422}, truncated, alloc, popts) == nil {
				if doc, derr := engine.token_tape_document(&tt); derr == nil {
					if !write_doc_line(osink, &doc, engine.spec_of_id(.Json), {}, alloc) { return EXIT_USAGE }
				}
			}
		}
	}
	return EXIT_FALSY
}

@(private = "file")
write_doc_line :: proc(osink: ^Out_Stream, doc: ^tape.Document, sp: engine.Spec, wopts: engine.Write_Options, alloc: runtime.Allocator) -> bool {
	if _, err := engine.write_to(out_stream_writer(osink), doc, sp, wopts, alloc); err != nil {
		if ioe, is_io := err.(io.Error); is_io {
			osink.failed, osink.io_err = true, ioe
		}
		return false
	}
	nl := [1]u8{'\n'}
	return out_stream_write(osink, nl[:])
}

// ---- `stury fmt` ----

@(private = "file")
format_single_doc_to :: proc(
	dst_w: io.Writer,
	o: ^Options,
	sc: ^schema.Compiled,
	src: []u8,
	sp, to_sp: engine.Spec,
	ro: tape.Options,
	wopts: engine.Write_Options,
	alloc: runtime.Allocator,
) -> (dropped: tape.Facts, err: engine.Format_Error) {
	e, _ := engine.entry_of_spec(sp)
	need_xml_schema := e.family == .Xml && o.xml_arrays == .Schema && sc != nil
	if o.to_render != .None || need_xml_schema {
		doc, berr := engine.build(src, sp, ro, alloc)
		if berr != nil { return {}, berr }
		defer tape.destroy_document(&doc)
		if need_xml_schema {
			if nerr := engine.apply_xml_arrays(&doc, .Schema, sc.description, alloc); nerr != nil {
				return {}, nerr
			}
		}
		if o.to_render != .None {
			if werr := write_doc_render_to(dst_w, &doc, o.to_render, o.sort_keys, o.compact, o.dsv_out.no_header, tape.ROOT, alloc); werr != nil {
				return {}, werr
			}
			return {}, nil
		}
		wdr, werr := engine.write_to(dst_w, &doc, to_sp, wopts, alloc)
		if werr != nil { return wdr, werr }
		return wdr, nil
	}
	return engine.format_to(dst_w, src, sp, to_sp, ro, wopts, alloc)
}

@(private = "file")
fmt_one_file :: proc(
	o: ^Options,
	sc: ^schema.Compiled,
	p: string,
	stdin_override: Maybe([]u8),
	osink: ^Out_Stream,
	stderr_w: io.Writer,
	runner: ^tape.Runner,
	alloc: runtime.Allocator,
) -> (code: int, open_err: bool, io_fatal: bool) {
	src, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
	if !rok { return EXIT_OK, true, false }
	defer if owned { delete(src, alloc) }

	disp := "<stdin>" if p == "-" else p
	sp, fr := detect_file_spec(o, p)
	e, _ := engine.entry_of_spec(sp)
	ro := read_opts_of(o, sp, runner)
	to_sp := o.to_spec if o.has_to else sp
	to_e, _ := engine.entry_of_spec(to_sp)
	wopts := make_write_opts(o, to_sp, 0 if (!o.indent_set && (fr == .Lines || o.to_framing == .Lines)) else o.indent)

	if sc != nil {
		if chk := check_bytes_schema(o, sc, disp, src, sp, 1, nil, osink, stderr_w, alloc); chk != EXIT_OK {
			return chk, false, false
		}
	}

	if !o.check && !o.in_place && (e.tabular || (fr != .Lines && fr != .Seq)) {
		before_bytes := osink.total_written
		dropped, ferr := format_single_doc_to(out_stream_writer(osink), o, sc, src, sp, to_sp, ro, wopts, alloc)
		if ferr != nil {
			fcode := report_format_error(ferr, disp, src, sp, osink, stderr_w, alloc)
			return fcode, false, fcode == EXIT_USAGE
		}
		if !to_e.binary && (osink.total_written == before_bytes || osink.last_byte != '\n') {
			nl := [1]u8{'\n'}
			if !out_stream_write(osink, nl[:]) { return EXIT_USAGE, false, true }
		}
		if osink.unbuffered && !out_stream_flush(osink) { return EXIT_USAGE, false, true }
		if o.diff_facts && dropped != {} { fmt.wprintf(stderr_w, "stury: note (%s): dropped %v\n", disp, dropped) }
		return EXIT_OK, false, false
	}

	formatted: []u8
	dropped: tape.Facts
	if !e.tabular && (fr == .Lines || fr == .Seq) {
		it, ok := rec_loop_open(src, sp, fr, ro, false, disp, stderr_w, alloc)
		if !ok { return EXIT_RUNTIME, false, false }
		defer rec_loop_close(&it)

		if o.to_render != .None {
			docs := make([dynamic]tape.Document, alloc)
			defer {
				for &d in docs { tape.destroy_document(&d) }
				delete(docs)
			}
			for rec, rinfo, err in rec_loop_next(&it) {
				if err != nil { _ = print_tape_error(stderr_w, disp, err, src, sp); return EXIT_RUNTIME, false, false }
				d, berr := engine.build(rec, sp, ro, alloc)
				if berr != nil { _ = print_tape_error(stderr_w, disp, berr, rec, sp, false, src, rinfo.lo); return EXIT_RUNTIME, false, false }
				append(&docs, d)
			}
			if it.tail_err != nil { return EXIT_RUNTIME, false, false }
			wtxt: []u8
			werr: engine.Write_Error
			if o.to_render == .Table {
				wtxt, werr = engine.write_table_docs(docs[:], {style = .Compact if o.compact else .Plain, sort_keys = o.sort_keys, no_header = o.dsv_out.no_header}, alloc)
			} else {
				wtxt, werr = engine.write_markdown_docs(docs[:], {sort_keys = o.sort_keys, compact = o.compact}, alloc)
			}
			if werr != nil {
				fcode := report_format_error(werr, disp, src, sp, osink, stderr_w, alloc)
				return fcode, false, fcode == EXIT_USAGE
			}
			formatted = wtxt
		} else {
			fb_out := make([dynamic]u8, 0, len(src), alloc)
			fb_ok := false
			defer if !fb_ok { delete(fb_out) }
			for rec, rinfo, err in rec_loop_next(&it) {
				if err != nil { _ = print_tape_error(stderr_w, disp, err, src, sp); return EXIT_RUNTIME, false, false }
				if o.to_framing == .Seq || fr == .Seq { append(&fb_out, 0x1e) }
				part, dr, ferr := engine.format(rec, sp, to_sp, ro, wopts, alloc)
				if ferr != nil { _ = report_format_error(ferr, disp, rec, sp, osink, stderr_w, alloc, src, rinfo.lo); return EXIT_RUNTIME, false, false }
				dropped += dr
				append(&fb_out, ..part)
				append(&fb_out, '\n')
				delete(part, alloc)
			}
			if it.tail_err != nil { return EXIT_RUNTIME, false, false }
			fb_ok = true
			formatted = fb_out[:]
		}
	} else {
		buf: bytes.Buffer
		bytes.buffer_init_allocator(&buf, 0, len(src), alloc)
		defer bytes.buffer_destroy(&buf)
		dr, ferr := format_single_doc_to(bytes.buffer_to_stream(&buf), o, sc, src, sp, to_sp, ro, wopts, alloc)
		if ferr != nil {
			fcode := report_format_error(ferr, disp, src, sp, osink, stderr_w, alloc)
			return fcode, false, fcode == EXIT_USAGE
		}
		dropped = dr
		if !to_e.binary && (bytes.buffer_length(&buf) == 0 || bytes.buffer_to_bytes(&buf)[bytes.buffer_length(&buf) - 1] != '\n') {
			bytes.buffer_write_byte(&buf, '\n')
		}
		formatted = slice.clone(bytes.buffer_to_bytes(&buf), alloc)
	}
	defer delete(formatted, alloc)
	if o.diff_facts && dropped != {} { fmt.wprintf(stderr_w, "stury: note (%s): dropped %v\n", disp, dropped) }
	ccode := commit_file_output(o, p, disp, src, formatted, "is not formatted", osink, stderr_w, alloc)
	return ccode, false, ccode == EXIT_USAGE && osink.failed
}

run_fmt :: proc(o: ^Options, stdin_override: Maybe([]u8), stdout_w, stderr_w: io.Writer, runner: ^tape.Runner, alloc: runtime.Allocator) -> int {
	if !preflight_in_place(o, true, stderr_w, alloc) { return EXIT_USAGE }
	sc: ^schema.Compiled
	if o.schema_file != "" {
		ok: bool
		sc, _, ok = compile_schema_file(o, o.schema_file, stderr_w, alloc)
		if !ok { return EXIT_USAGE }
	}
	defer schema.destroy(sc)

	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, false)
	fb := [1]string{"-"}
	paths := o.files[:] if len(o.files) > 0 else fb[:]
	has_open_err, worst := false, EXIT_OK

	for p in paths {
		code, oerr, io_fatal := fmt_one_file(o, sc, p, stdin_override, &osink, stderr_w, runner, alloc)
		if io_fatal { return report_stdout_error(stderr_w, osink.io_err) }
		if oerr { has_open_err = true; continue }
		worst = max(worst, code)
	}
	if !out_stream_flush(&osink) { return report_stdout_error(stderr_w, osink.io_err) }
	return EXIT_USAGE if has_open_err else worst
}

@(private = "file")
report_format_error :: proc(
	ferr: engine.Format_Error,
	display: string,
	src: []u8,
	sp: engine.Spec,
	osink: ^Out_Stream,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
	place_src: []u8 = nil,
	place_off: u64 = 0,
) -> int {
	switch err in ferr {
	case tape.Error:
		return print_tape_error(stderr_w, display, err, src, sp, false, place_src, place_off)
	case engine.Write_Error:
		if ioe, is_io := err.(io.Error); is_io {
			osink.failed, osink.io_err = true, ioe
			return EXIT_USAGE
		}
		msg := write_error_string(err, alloc)
		fmt.wprintf(stderr_w, "stury: error (%s): %s\n", display, msg)
		delete(msg, alloc)
		return EXIT_RUNTIME
	}
	return EXIT_RUNTIME
}

// ---- `stury edit` ----

@(private = "file")
Edit_Span :: struct { lo, end: u64 }
@(private = "file")
Edit_Part :: struct { span_idx: int, bytes: []u8 }

@(private = "file")
edit_run_doc :: proc(
	o: ^Options,
	sh: ^Shared_Query_State,
	worker: ^Query_Worker,
	src: []u8,
	sp: engine.Spec,
	ro: tape.Options,
	single_doc: bool,
	display: string,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
	place_src: []u8 = nil,
	place_off: u64 = 0,
) -> (parts: [dynamic][]u8, last_falsy, halted: bool, code: int) {
	parts = make([dynamic][]u8, alloc)
	keep_parts := false
	defer if !keep_parts {
		for pt in parts { delete(pt, alloc) }
		clear(&parts)
	}

	doc, berr := engine.build(src, sp, ro, alloc)
	if berr != nil {
		_ = print_tape_error(stderr_w, display, berr, src, sp, false, place_src, place_off)
		return parts, false, false, EXIT_RUNTIME
	}
	h: query.Heap
	query.heap_init(&h, alloc, memory_limit = o.budget.memory, depth = int(o.budget.depth))
	defer query.heap_destroy(&h)
	inp, ov, ost := query.overlay_from_doc(&h, doc, doc_owned = true)
	if ost != .Ok {
		tape.destroy_document(&doc)
		return parts, false, false, EXIT_RUNTIME
	}
	_ = query.retain(inp)
	defer { query.release(&h, inp); h.write_fact, h.write_fact_data = nil, nil }

	globs, gok := build_globals_from_shared(&h, sh.main_prog, sh, alloc)
	if !gok { return parts, false, false, EXIT_RUNTIME }
	defer {
		for g in globs { query.release(&h, g) }
		delete(globs, alloc)
	}

	worker.hook_ctx.file_path = display
	jrun: jq.Run
	jq.run_init(&jrun, sh.main_prog, &h, globs, &worker.hooks, steps = int(o.budget.steps))
	defer jq.run_destroy(&jrun)

	Outs :: struct { vals: [dynamic]query.Value }
	outs := Outs{vals = make([dynamic]query.Value, alloc)}
	defer {
		for v in outs.vals { query.release(&h, v) }
		delete(outs.vals)
	}
	end := jq.run_value(&jrun, inp, proc(d: rawptr, v: query.Value, _: ^query.Heap) -> bool {
		append(&(^Outs)(d).vals, v)
		return true
	}, &outs)
	if end == .Halted {
		hs := jq.run_halt(&jrun)
		format_halt_message(worker, hs)
		if worker.halt_msg != "" {
			_, _ = io.write_string(stderr_w, worker.halt_msg)
			delete(worker.halt_msg, alloc)
			worker.halt_msg = ""
		}
		return parts, false, true, hs.code
	}
	if end != .Done {
		e := query.take_error(&h)
		msg := jq.error_message(&h, &e, alloc)
		query.destroy_error(&h, &e)
		fmt.wprintf(stderr_w, "jq: error (at %s): %s\n", display, msg)
		delete(msg, alloc)
		return parts, false, false, EXIT_RUNTIME
	}
	if single_doc {
		if len(outs.vals) == 0 {
			fmt.wprintf(stderr_w, "stury: edit (%s): filter produced no output\n", display)
			return parts, false, false, EXIT_RUNTIME
		}
		if len(outs.vals) > 1 {
			fmt.wprintf(stderr_w, "stury: edit (%s): filter must emit 1 output, got %d\n", display, len(outs.vals))
			return parts, false, false, EXIT_RUNTIME
		}
	}
	eopts := engine.Edit_Options{reflow = o.reflow, indent = 0 if o.compact else u8(max(o.indent, 0)), tab = o.tab && !o.compact}
	for v, i in outs.vals {
		vt := query.type_of(v)
		last_falsy = (vt == .Null || vt == .False)
		if i == 0 {
			yopts := tape.Yaml_Options{dialect = o.yaml_schema} if o.yaml_schema_set else {}
			cres, cerr := engine.reconcile_edit(&h, ov, v, sp, eopts, alloc, yopts)
			if cerr != nil {
				engine.destroy_commit_result(&cres)
				msg := edit_error_text(cerr, alloc)
				fmt.wprintf(stderr_w, "stury: edit refused (%s): %s\n", display, msg)
				delete(msg, alloc)
				return parts, false, false, EXIT_RUNTIME
			}
			append(&parts, slice.clone(cres.bytes, alloc))
			engine.destroy_commit_result(&cres)
		} else {
			buf := make([dynamic]u8, 0, 128, alloc)
			ok, emsg := write_value_as_format(&h, v, sp, make_write_opts(o, sp, 0 if o.compact else o.indent), &buf, {}, int(o.budget.depth), alloc)
			if !ok {
				delete(buf)
				fmt.wprintf(stderr_w, "stury: edit (%s): %s\n", display, emsg)
				delete(emsg, alloc)
				return parts, false, false, EXIT_RUNTIME
			}
			append(&parts, buf[:])
		}
	}
	keep_parts = true
	return parts, last_falsy, false, EXIT_OK
}

@(private = "file")
edit_join_records :: proc(src: []u8, spans: []Edit_Span, outs: []Edit_Part, fr: engine.Framing, alloc: runtime.Allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(src), alloc)
	if len(outs) == 0 || len(spans) == 0 { return out[:] }
	prev_span := -1
	for p in outs {
		s := spans[p.span_idx]
		if p.span_idx == prev_span {
			tail := src[s.end:]
			append(&out, "\r\n" if (len(tail) >= 2 && tail[0] == '\r' && tail[1] == '\n') else "\n")
			if fr == .Seq { append(&out, 0x1e) }
		} else if prev_span >= 0 {
			append(&out, ..src[spans[prev_span if p.span_idx == prev_span + 1 else p.span_idx - 1].end:s.lo])
		} else if p.span_idx == 0 {
			append(&out, ..src[0:s.lo])
		} else if fr == .Seq {
			lead := src[spans[p.span_idx - 1].end:s.lo]
			if rs := bytes.index_byte(lead, 0x1e); rs >= 0 { append(&out, ..lead[rs:]) } else { append(&out, 0x1e) }
		} else {
			append(&out, ..src[0:spans[0].lo])
		}
		append(&out, ..p.bytes)
		prev_span = p.span_idx
	}
	append(&out, ..src[spans[len(spans) - 1].end:])
	return out[:]
}

@(private = "file")
edit_one_file :: proc(
	o: ^Options,
	sh: ^Shared_Query_State,
	worker: ^Query_Worker,
	p: string,
	multi_files: bool,
	stdin_override: Maybe([]u8),
	osink: ^Out_Stream,
	stderr_w: io.Writer,
	runner: ^tape.Runner,
	any_out, last_falsy: ^bool,
	alloc: runtime.Allocator,
) -> (code: int, open_err, halted, io_fatal: bool) {
	src, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
	if !rok { return EXIT_OK, true, false, false }
	defer if owned { delete(src, alloc) }

	disp := "<stdin>" if p == "-" else p
	sp, fr := detect_file_spec(o, p)
	e, _ := engine.entry_of_spec(sp)
	ro := read_opts_of(o, sp, runner)
	edited: []u8
	defer delete(edited, alloc)

	if !e.tabular && (fr == .Lines || fr == .Seq) {
		spans := make([dynamic]Edit_Span, alloc)
		outs := make([dynamic]Edit_Part, alloc)
		defer {
			delete(spans)
			for pt in outs { delete(pt.bytes, alloc) }
			delete(outs)
		}
		it, ok := rec_loop_open(src, sp, fr, ro, false, disp, stderr_w, alloc)
		if !ok { return EXIT_RUNTIME, false, false, false }
		defer rec_loop_close(&it)
		for rec, rinfo, err in rec_loop_next(&it) {
			if err != nil { _ = print_tape_error(stderr_w, disp, err, src, sp); return EXIT_RUNTIME, false, false, false }
			end_pos := rinfo.hi
			for fr == .Seq && end_pos > rinfo.lo && (src[end_pos - 1] == ' ' || src[end_pos - 1] == '\t' || src[end_pos - 1] == '\r' || src[end_pos - 1] == '\n') {
				end_pos -= 1
			}
			span_idx := len(spans)
			append(&spans, Edit_Span{lo = rinfo.lo, end = end_pos})
			parts, lf, hlt, ec := edit_run_doc(o, sh, worker, rec, sp, ro, false, disp, stderr_w, alloc, src, rinfo.lo)
			defer delete(parts)
			if hlt { return ec, false, true, false }
			if ec != EXIT_OK { return EXIT_RUNTIME, false, false, false }
			for pb in parts {
				any_out^, last_falsy^ = true, lf
				append(&outs, Edit_Part{span_idx = span_idx, bytes = pb})
			}
		}
		if it.tail_err != nil { return EXIT_RUNTIME, false, false, false }
		edited = edit_join_records(src, spans[:], outs[:], fr, alloc)
	} else {
		parts, lf, hlt, ec := edit_run_doc(o, sh, worker, src, sp, ro, true, disp, stderr_w, alloc)
		defer delete(parts)
		if hlt { return ec, false, true, false }
		if ec != EXIT_OK || len(parts) == 0 {
			return ec if ec != EXIT_OK else EXIT_RUNTIME, false, false, false
		}
		any_out^, last_falsy^ = true, lf
		edited = parts[0]
	}

	if o.diff_preview {
		da, ok_da := build_diff_document(o, src, disp, sp, fr, ro, stderr_w, alloc)
		defer if ok_da { diff_doc_destroy(&da) }
		db, ok_db := build_diff_document(o, edited, disp, sp, fr, ro, stderr_w, alloc)
		defer if ok_db { diff_doc_destroy(&db) }
		if ok_da && ok_db {
			if dr, derr := engine.diff_documents(&da.doc, &db.doc, {max_depth = int(o.budget.depth)}, alloc); derr == nil {
				defer engine.destroy_diff_result(&dr)
				if !print_diff_changes(osink, &da.doc, &db.doc, dr.changes, false, disp if multi_files else "", alloc) {
					return EXIT_USAGE, false, false, true
				}
			}
		}
	}
	out_code := commit_file_output(o, p, disp, src, edited, "would change", osink, stderr_w, alloc)
	return out_code, false, false, out_code == EXIT_USAGE && osink.failed
}

run_edit :: proc(o: ^Options, stdin_override: Maybe([]u8), stdout_w, stderr_w: io.Writer, runner: ^tape.Runner, exe_dir, cwd, home_dir: string, alloc: runtime.Allocator) -> int {
	if !preflight_in_place(o, false, stderr_w, alloc) { return EXIT_USAGE }
	if o.filter == nil && !o.from_file {
		fmt.wprintln(stderr_w, "stury: edit requires a jq filter")
		return EXIT_USAGE
	}
	prog, _, cok, ccode := compile_jq_cmd(o, exe_dir, cwd, home_dir, stderr_w, alloc)
	if !cok { return ccode }
	defer jq.destroy_program(prog)

	plan := jq.analyze(prog, {slurp = o.slurp, raw_input = o.raw_input}, alloc)
	defer jq.destroy_plan(&plan)

	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, false)
	cfg := Render_Config{compact = o.compact, indent = o.indent, tab = o.tab, sort_keys = o.sort_keys, ascii = o.ascii, colors = DEFAULT_COLORS}
	sh, serr := shared_query_init_jq(o, &cfg, prog, &plan, &osink, stderr_w, alloc)
	if serr != "" {
		fmt.wprintf(stderr_w, "stury: error: %s\n", serr)
		delete(serr, alloc)
		return EXIT_USAGE
	}
	defer shared_query_destroy(sh)

	worker, wok := new_query_worker(sh, alloc, true)
	if !wok {
		fmt.wprintln(stderr_w, "stury: error: out of memory")
		return EXIT_RUNTIME
	}
	defer free_query_worker(worker)

	fb := [1]string{"-"}
	paths := o.files[:] if len(o.files) > 0 else fb[:]
	has_open_err, any_out, last_falsy := false, false, false
	worst := EXIT_OK

	for p in paths {
		code, oerr, hlt, io_fatal := edit_one_file(o, sh, worker, p, len(paths) > 1, stdin_override, &osink, stderr_w, runner, &any_out, &last_falsy, alloc)
		if hlt { return code }
		if io_fatal { return report_stdout_error(stderr_w, osink.io_err) }
		if oerr { has_open_err = true; continue }
		worst = max(worst, code)
	}
	if !out_stream_flush(&osink) { return report_stdout_error(stderr_w, osink.io_err) }
	if has_open_err { return EXIT_USAGE }
	if worst == EXIT_OK && o.exit_status {
		if !any_out { return EXIT_NO_OUTPUT }
		if last_falsy { return EXIT_FALSY }
	}
	return worst
}

@(private = "file")
edit_error_text :: proc(err: engine.Edit_Error, alloc: runtime.Allocator) -> string {
	switch e in err {
	case engine.Edit_Refusal:
		if e.group == .Layout_Conflict { return fmt.aprintf("%s (re-run with --reflow)", e.detail, allocator = alloc) }
		return strings.clone(e.detail if e.detail != "" else "edit refused", alloc)
	case tape.Fault, tape.Exceeded, tape.Bad_Option:
		return strings.clone("invalid edit target or syntax", alloc)
	case runtime.Allocator_Error:
		return strings.clone("out of memory", alloc)
	}
	return strings.clone("edit failed", alloc)
}

// ---- `stury diff` ----

@(private = "file", rodata)
DIFF_OP_NAMES := [engine.Diff_Op]string{.Added = "added", .Removed = "removed", .Changed = "changed", .Fact = "fact"}

@(private = "file")
Diff_Doc :: struct {
	doc:      tape.Document,
	tt:       engine.Write_Token_Tape,
	using_tt: bool,
}

@(private = "file")
diff_doc_destroy :: proc(d: ^Diff_Doc) {
	if d.using_tt { engine.token_tape_drop(&d.tt) } else { tape.destroy_document(&d.doc) }
}

@(private = "file")
build_diff_document :: proc(o: ^Options, src: []u8, display: string, sp: engine.Spec, fr: engine.Framing, ro: tape.Options, stderr_w: io.Writer, alloc: runtime.Allocator) -> (res: Diff_Doc, ok: bool) {
	e, _ := engine.entry_of_spec(sp)
	if !e.tabular && (fr == .Lines || fr == .Seq) {
		it, iok := rec_loop_open(src, sp, fr, ro, false, display, stderr_w, alloc)
		if !iok { return {}, false }
		defer rec_loop_close(&it)
		if engine.token_tape_start(&res.tt, false, int(o.budget.depth), alloc) != nil { return {}, false }
		keep := false
		defer if !keep { engine.token_tape_drop(&res.tt) }
		if engine.token_tape_take(&res.tt, .Array, "") != nil { return {}, false }
		for rec, rinfo, err in rec_loop_next(&it) {
			if err != nil { _ = print_tape_error(stderr_w, display, err, src, sp); return {}, false }
			rdoc, berr := engine.build(rec, sp, ro, alloc)
			if berr != nil { _ = print_tape_error(stderr_w, display, berr, rec, sp, false, src, rinfo.lo); return {}, false }
			werr := engine.tokens_of(&rdoc, tape.ROOT, &res.tt, engine.token_tape_take, alloc)
			tape.destroy_document(&rdoc)
			if werr != nil { return {}, false }
		}
		if it.tail_err != nil || engine.token_tape_take(&res.tt, .Close, "") != nil { return {}, false }
		tdoc, derr := engine.token_tape_document(&res.tt)
		if derr != nil { return {}, false }
		res.doc, res.using_tt, keep = tdoc, true, true
		return res, true
	}
	bdoc, berr := engine.build(src, sp, ro, alloc)
	if berr != nil {
		_ = print_tape_error(stderr_w, display, berr, src, sp)
		return {}, false
	}
	return {doc = bdoc}, true
}

run_diff :: proc(o: ^Options, stdin_override: Maybe([]u8), stdout_w, stderr_w: io.Writer, runner: ^tape.Runner, alloc: runtime.Allocator) -> int {
	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, false)

	two_named := o.old_schema != "" && o.new_schema != ""
	schema_two := (o.schema_file != "" || o.schema_flag_set) && len(o.files) == 2 && o.old_schema == "" && o.new_schema == ""
	if two_named || schema_two {
		sa, _, oka := compile_schema_file(o, o.old_schema if two_named else o.files[0], stderr_w, alloc)
		sb, _, okb := compile_schema_file(o, o.new_schema if two_named else o.files[1], stderr_w, alloc)
		defer schema.destroy(sa)
		defer schema.destroy(sb)
		if !oka || !okb { return EXIT_USAGE }
		code := report_schema_compare(o, sa.description, sb.description, &osink, stderr_w, alloc)
		return report_stdout_error(stderr_w, osink.io_err) if !out_stream_flush(&osink) else code
	}

	if (o.schema_file != "" || o.old_schema != "" || o.new_schema != "") && len(o.files) == 1 {
		sp_file := o.schema_file if o.schema_file != "" else o.old_schema if o.old_schema != "" else o.new_schema
		sc, _, ok := compile_schema_file(o, sp_file, stderr_w, alloc)
		defer schema.destroy(sc)
		if !ok { return EXIT_USAGE }
		src, owned, rok := read_input_bytes(o.files[0], stdin_override, stderr_w, alloc)
		if !rok { return EXIT_USAGE }
		defer if owned { delete(src, alloc) }
		disp := "<stdin>" if o.files[0] == "-" else o.files[0]
		sp, _ := detect_file_spec(o, o.files[0])
		chk := check_bytes_schema(o, sc, disp, src, sp, 1, nil, &osink, stderr_w, alloc)
		if chk == EXIT_RUNTIME || chk == EXIT_USAGE {
			return report_stdout_error(stderr_w, osink.io_err) if chk == EXIT_USAGE else EXIT_RUNTIME
		}
		seen, scode := infer_one_desc(o, o.files[0], stdin_override, runner, stderr_w, alloc)
		defer engine.destroy_schema_description(&seen)
		if scode != EXIT_OK { return scode }
		cmp, cerr := schema.compare(sc.description, &seen, {format_assert = o.format_assert}, alloc)
		if cerr != nil { return EXIT_RUNTIME }
		defer schema.comparison_destroy(&cmp)

		drifted := false
		sb := strings.builder_make(alloc)
		defer strings.builder_destroy(&sb)
		for ch in cmp.changes {
			if ch.keyword == "properties" && ch.old == nil && ch.effect != .Unknown {
				drifted = true
				strings.builder_reset(&sb)
				if o.diff_json {
					strings.write_string(&sb, `{"path":`)
					write_steps(&sb, ch.path, true)
					strings.write_string(&sb, ",\"undescribed\":true}\n")
				} else {
					strings.write_string(&sb, "+ ")
					write_steps(&sb, ch.path, false)
					strings.write_string(&sb, "  not described by schema\n")
				}
				if !out_stream_bytes(&osink, transmute([]u8)strings.to_string(sb)) {
					return report_stdout_error(stderr_w, osink.io_err)
				}
			}
		}
		if !out_stream_flush(&osink) { return report_stdout_error(stderr_w, osink.io_err) }
		return EXIT_FALSY if (chk != EXIT_OK || drifted) else EXIT_OK
	}

	if o.diff_shape {
		if len(o.files) != 2 { fmt.wprintln(stderr_w, "stury: --shape requires two files"); return EXIT_USAGE }
		da, code_a := infer_one_desc(o, o.files[0], stdin_override, runner, stderr_w, alloc)
		defer engine.destroy_schema_description(&da)
		if code_a != EXIT_OK { return code_a }
		db, code_b := infer_one_desc(o, o.files[1], stdin_override, runner, stderr_w, alloc)
		defer engine.destroy_schema_description(&db)
		if code_b != EXIT_OK { return code_b }
		code := report_schema_compare(o, &da, &db, &osink, stderr_w, alloc)
		return report_stdout_error(stderr_w, osink.io_err) if !out_stream_flush(&osink) else code
	}

	if len(o.files) != 2 { fmt.wprintln(stderr_w, "stury: diff takes two files, OLD and NEW"); return EXIT_USAGE }
	if o.files[0] == "-" && o.files[1] == "-" { fmt.wprintln(stderr_w, "stury: diff cannot read stdin (-) twice"); return EXIT_USAGE }

	src_a, own_a, ok_a := read_input_bytes(o.files[0], stdin_override, stderr_w, alloc)
	if !ok_a { return EXIT_USAGE }
	defer if own_a { delete(src_a, alloc) }
	src_b, own_b, ok_b := read_input_bytes(o.files[1], stdin_override, stderr_w, alloc)
	if !ok_b { return EXIT_USAGE }
	defer if own_b { delete(src_b, alloc) }

	sp_a, fr_a := detect_file_spec(o, o.files[0])
	sp_b, fr_b := detect_file_spec(o, o.files[1])
	da, build_a := build_diff_document(o, src_a, "<stdin>" if o.files[0] == "-" else o.files[0], sp_a, fr_a, read_opts_of(o, sp_a, runner), stderr_w, alloc)
	if !build_a { return EXIT_RUNTIME }
	defer diff_doc_destroy(&da)
	db, build_b := build_diff_document(o, src_b, "<stdin>" if o.files[1] == "-" else o.files[1], sp_b, fr_b, read_opts_of(o, sp_b, runner), stderr_w, alloc)
	if !build_b { return EXIT_RUNTIME }
	defer diff_doc_destroy(&db)

	dopts := engine.Diff_Options{arrays = o.diff_arrays, keys = o.diff_keys[:], facts = o.diff_facts, max_depth = int(o.budget.depth)}
	if o.diff_patch {
		patch, perr := engine.diff_to_patch(&da.doc, &db.doc, dopts, alloc)
		if perr != nil { return EXIT_RUNTIME }
		defer engine.destroy_diff_patch(&patch)
		if patch.too_deep { fmt.wprintln(stderr_w, "stury: error: value nests past --max-depth"); return EXIT_RUNTIME }
		if !print_rfc6902_patch(&osink, &patch, alloc) || !out_stream_flush(&osink) { return report_stdout_error(stderr_w, osink.io_err) }
		return EXIT_FALSY if len(patch.ops) > 0 else EXIT_OK
	}

	res, derr := engine.diff_documents(&da.doc, &db.doc, dopts, alloc)
	if derr != nil { return EXIT_RUNTIME }
	defer engine.destroy_diff_result(&res)
	if res.too_deep { fmt.wprintln(stderr_w, "stury: error: value nests past --max-depth"); return EXIT_RUNTIME }
	if len(res.unused_keys) > 0 {
		idx := res.unused_keys[0]
		fmt.wprintf(stderr_w, "stury: --key %s matched no array element\n", o.diff_keys_raw[idx] if (idx >= 0 && idx < len(o.diff_keys_raw)) else "?")
		return EXIT_USAGE
	}
	if !print_diff_changes(&osink, &da.doc, &db.doc, res.changes, o.diff_json, "", alloc) || !out_stream_flush(&osink) {
		return report_stdout_error(stderr_w, osink.io_err)
	}
	return EXIT_FALSY if len(res.changes) > 0 else EXIT_OK
}

@(private = "file")
print_rfc6902_patch :: proc(osink: ^Out_Stream, patch: ^engine.Diff_Patch, alloc: runtime.Allocator) -> bool {
	tt: engine.Write_Token_Tape
	if engine.token_tape_start(&tt, false, 0, alloc) != nil { return false }
	defer engine.token_tape_drop(&tt)
	_ = engine.token_tape_take(&tt, .Array, "")
	for po in patch.ops {
		_ = engine.token_tape_take(&tt, .Object, "")
		_ = tt_kv(&tt, "op", .String, "remove" if po.op == .Remove else "replace" if po.op == .Replace else "add")
		_ = tt_kv(&tt, "path", .String, po.path)
		if po.op != .Remove {
			_ = engine.token_tape_take(&tt, .Key, "value")
			if po.doc != nil && po.node != tape.NO_NODE {
				_ = engine.tokens_of(po.doc, po.node, &tt, engine.token_tape_take, alloc)
			} else if po.doc != nil && len(po.nodes) > 0 {
				_ = engine.token_tape_take(&tt, .Array, "")
				for n in po.nodes { _ = engine.tokens_of(po.doc, n, &tt, engine.token_tape_take, alloc) }
				_ = engine.token_tape_take(&tt, .Close, "")
			} else {
				_ = engine.token_tape_take(&tt, .Null, "")
			}
		}
		_ = engine.token_tape_take(&tt, .Close, "")
	}
	_ = engine.token_tape_take(&tt, .Close, "")
	if doc, derr := engine.token_tape_document(&tt); derr == nil {
		return write_doc_line(osink, &doc, engine.spec_of_id(.Json), {indent = 2}, alloc)
	}
	return false
}

@(private = "file")
node_json_text :: proc(doc: ^tape.Document, node: tape.Node_Index, fallback: string, alloc: runtime.Allocator) -> (string, bool) {
	if doc == nil || node == tape.NO_NODE { return fallback if fallback != "" else "null", false }
	if txt, _, werr := engine.write(doc, engine.spec_of_id(.Json), {node = node}, alloc); werr == nil {
		return string(txt), true
	}
	return "null", false
}

@(private = "file")
print_diff_changes :: proc(osink: ^Out_Stream, doc_a, doc_b: ^tape.Document, changes: []engine.Diff_Change, as_json: bool, file: string, alloc: runtime.Allocator) -> bool {
	sb := strings.builder_make(alloc)
	defer strings.builder_destroy(&sb)
	if file != "" && len(changes) > 0 && !as_json {
		fmt.sbprintf(&sb, "--- %s\n", file)
		if !out_stream_write(osink, transmute([]u8)strings.to_string(sb)) { return false }
	}
	for c in changes {
		strings.builder_reset(&sb)
		ot, ow := c.old_text, false
		nt, nw := c.new_text, false
		if c.op != .Fact {
			if c.op != .Added { ot, ow = node_json_text(doc_a, c.old_node, c.old_text, alloc) }
			if c.op != .Removed { nt, nw = node_json_text(doc_b, c.new_node, c.new_text, alloc) }
		}
		defer {
			if ow { delete(ot, alloc) }
			if nw { delete(nt, alloc) }
		}
		if as_json {
			strings.write_string(&sb, `{"path":`)
			write_steps(&sb, c.path, true)
			fmt.sbprintf(&sb, ",\"op\":\"%s\"", DIFF_OP_NAMES[c.op])
			if c.op != .Added { fmt.sbprintf(&sb, ",\"old\":%q" if c.op == .Fact else ",\"old\":%s", ot if (c.op == .Fact || ot != "") else "null") }
			if c.op != .Removed { fmt.sbprintf(&sb, ",\"new\":%q" if c.op == .Fact else ",\"new\":%s", nt if (c.op == .Fact || nt != "") else "null") }
			strings.write_string(&sb, "}\n")
		} else {
			fmt.sbprintf(&sb, "%c ", '+' if c.op == .Added else '-' if c.op == .Removed else '~')
			write_steps(&sb, c.path, false)
			switch c.op {
			case .Added:          fmt.sbprintf(&sb, ": %s\n", nt)
			case .Removed:        fmt.sbprintf(&sb, ": %s\n", ot)
			case .Changed, .Fact: fmt.sbprintf(&sb, ": %s -> %s\n", ot, nt)
			}
		}
		if !out_stream_write(osink, transmute([]u8)strings.to_string(sb)) { return false }
	}
	return true
}

@(private = "file")
write_steps :: proc(sb: ^strings.Builder, steps: []tape.Step, as_json: bool) {
	strings.write_byte(sb, '[' if as_json else '.')
	for s, i in steps {
		if as_json && i > 0 { strings.write_byte(sb, ',') }
		if v, ok := s.(tape.Name); ok {
			fmt.sbprintf(sb, "%q" if as_json else (".%s" if i > 0 else "%s"), string(v))
		} else if iv, iok := s.(tape.Index); iok {
			fmt.sbprintf(sb, "%d" if as_json else "[%d]", int(iv))
		} else if as_json {
			strings.write_string(sb, "null")
		}
	}
	if as_json { strings.write_byte(sb, ']') }
}

@(private = "file")
report_schema_compare :: proc(o: ^Options, old, new: ^engine.Schema_Description, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	c, err := schema.compare(old, new, {format_assert = o.format_assert}, alloc)
	if err != nil { fmt.wprintln(stderr_w, "stury: error: out of memory"); return EXIT_RUNTIME }
	defer schema.comparison_destroy(&c)

	sb := strings.builder_make(alloc)
	defer strings.builder_destroy(&sb)
	for ch in c.changes {
		strings.builder_reset(&sb)
		os_txt, ns_txt := "none", "none"
		os_own, ns_own := false, false
		if ov, ok := ch.old.?; ok {
			if jb, jok := schema.value_to_json(ov, 0, false, alloc, alloc); jok { os_txt, os_own = string(jb), true }
		}
		if nv, ok := ch.new.?; ok {
			if jb, jok := schema.value_to_json(nv, 0, false, alloc, alloc); jok { ns_txt, ns_own = string(jb), true }
		}
		if o.diff_json {
			strings.write_string(&sb, `{"path":`)
			write_steps(&sb, ch.path, true)
			fmt.sbprintf(&sb, ",\"keyword\":%q", ch.keyword)
			if os_own { fmt.sbprintf(&sb, ",\"old\":%s", os_txt) }
			if ns_own { fmt.sbprintf(&sb, ",\"new\":%s", ns_txt) }
			fmt.sbprintf(&sb, ",\"effect\":\"%v\"}\n", ch.effect)
		} else {
			write_steps(&sb, ch.path, false)
			fmt.sbprintf(&sb, "  %s: %s -> %s  %v\n", ch.keyword, os_txt, ns_txt, ch.effect)
		}
		if os_own { delete(os_txt, alloc) }
		if ns_own { delete(ns_txt, alloc) }
		if !out_stream_write(osink, transmute([]u8)strings.to_string(sb)) { return EXIT_USAGE }
	}
	if !print_inclusion(osink, &sb, o.diff_json, "backward", c.old_in_new, "old", "new") ||
	   !print_inclusion(osink, &sb, o.diff_json, "forward", c.new_in_old, "new", "old") {
		return EXIT_USAGE
	}
	proven := c.old_in_new.verdict == .Yes && c.new_in_old.verdict == .Yes
	switch o.compat {
	case .None:     return EXIT_OK if (proven && len(c.changes) == 0) else EXIT_FALSY
	case .Backward: return EXIT_OK if c.old_in_new.verdict == .Yes else EXIT_FALSY
	case .Forward:  return EXIT_OK if c.new_in_old.verdict == .Yes else EXIT_FALSY
	case .Full:     return EXIT_OK if proven else EXIT_FALSY
	}
	return EXIT_FALSY
}

@(private = "file")
print_inclusion :: proc(osink: ^Out_Stream, sb: ^strings.Builder, as_json: bool, name: string, inc: schema.Inclusion, from, to: string) -> bool {
	strings.builder_reset(sb)
	if as_json {
		fmt.sbprintf(sb, "{{\"%s\":{{\"verdict\":\"%v\"", name, inc.verdict)
		if inc.witness != "" { fmt.sbprintf(sb, ",\"witness\":%s", inc.witness) }
		if inc.reason != "" { fmt.sbprintf(sb, ",\"reason\":%q", inc.reason) }
		strings.write_string(sb, "}}\n")
	} else {
		fmt.sbprintf(sb, "%s: %v", name, inc.verdict)
		if inc.verdict == .No {
			fmt.sbprintf(sb, ", %s passes %s and fails %s", inc.witness, from, to)
		} else if inc.verdict == .Unknown && inc.reason != "" {
			fmt.sbprintf(sb, ", not proven at %s", inc.reason)
		}
		strings.write_byte(sb, '\n')
	}
	return out_stream_write(osink, transmute([]u8)strings.to_string(sb^))
}

// ---- `stury schema` ----

@(private = "file")
infer_one_desc :: proc(o: ^Options, path: string, stdin_override: Maybe([]u8), runner: ^tape.Runner, stderr_w: io.Writer, alloc: runtime.Allocator) -> (engine.Schema_Description, int) {
	inf := schema.Inferred{ranges = o.ranges}
	defer schema.inferred_destroy(&inf)
	if code := infer_file_into(&inf, o, path, stdin_override, runner, stderr_w, alloc); code != EXIT_OK {
		return {}, code
	}
	out, ierr := schema.inferred(&inf, alloc)
	return out, EXIT_OK if ierr == nil else EXIT_RUNTIME
}

@(private = "file")
infer_file_into :: proc(inf: ^schema.Inferred, o: ^Options, path: string, stdin_override: Maybe([]u8), runner: ^tape.Runner, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	src, owned, rok := read_input_bytes(path, stdin_override, stderr_w, alloc)
	if !rok { return EXIT_USAGE }
	defer if owned { delete(src, alloc) }

	display := "<stdin>" if path == "-" else path
	sp, fr := detect_file_spec(o, path)
	ro := read_opts_of(o, sp, runner)
	if se, ok_e := engine.entry_of_spec(sp); ok_e && !se.tabular && (fr == .Lines || fr == .Seq) {
		it, ok := rec_loop_open(src, sp, fr, ro, false, display, stderr_w, alloc)
		if !ok { return EXIT_RUNTIME }
		defer rec_loop_close(&it)
		for rec, rinfo, err in rec_loop_next(&it) {
			if err != nil { _ = print_tape_error(stderr_w, display, err, src, sp); return EXIT_RUNTIME }
			doc, berr := engine.build(rec, sp, ro, alloc)
			if berr != nil { _ = print_tape_error(stderr_w, display, berr, rec, sp, false, src, rinfo.lo); return EXIT_RUNTIME }
			ierr := schema.infer_document(inf, &doc, tape.ROOT, alloc)
			tape.destroy_document(&doc)
			if ierr != nil { return EXIT_RUNTIME }
		}
		return EXIT_OK if it.tail_err == nil else EXIT_RUNTIME
	}
	doc, berr := engine.build(src, sp, ro, alloc)
	if berr != nil { _ = print_tape_error(stderr_w, display, berr, src, sp); return EXIT_RUNTIME }
	defer tape.destroy_document(&doc)
	return EXIT_OK if schema.infer_document(inf, &doc, tape.ROOT, alloc) == nil else EXIT_RUNTIME
}

@(private = "file")
emit_schema_text :: proc(osink: ^Out_Stream, txt: []u8, o: ^Options, ind: i8, alloc: runtime.Allocator) -> (formatted_ok, io_ok: bool) {
	if o.to_render != .None {
		doc, berr := engine.build(txt, engine.spec_of_id(.Json), {}, alloc)
		if berr != nil { return false, true }
		defer tape.destroy_document(&doc)
		ft, werr := write_doc_render(&doc, o.to_render, o.sort_keys, o.compact, o.dsv_out.no_header, tape.ROOT, alloc)
		if werr != nil { return false, true }
		defer delete(ft, alloc)
		return true, out_stream_bytes_nl(osink, ft)
	}
	if o.has_to && o.to_name != "json" {
		ft, _, ferr := engine.format(txt, engine.spec_of_id(.Json), o.to_spec, {}, make_write_opts(o, o.to_spec, ind), alloc)
		if ferr != nil { return false, true }
		defer delete(ft, alloc)
		return true, out_stream_bytes_nl(osink, ft)
	}
	return true, out_stream_bytes_nl(osink, txt)
}

run_schema :: proc(o: ^Options, stdin_override: Maybe([]u8), stdout_w, stderr_w: io.Writer, runner: ^tape.Runner, alloc: runtime.Allocator) -> int {
	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, false)
	switch o.schema_verb {
	case .None:
		fmt.wprintln(stderr_w, "stury: schema takes infer, sample, odin, check, or diff")
		return EXIT_USAGE
	case .Check:
		return run_check(o, stdin_override, stdout_w, stderr_w, runner, alloc)
	case .Diff:
		return run_diff(o, stdin_override, stdout_w, stderr_w, runner, alloc)
	case .Infer:
		inf := schema.Inferred{ranges = o.ranges}
		defer schema.inferred_destroy(&inf)
		fb := [1]string{"-"}
		for p in (o.files[:] if len(o.files) > 0 else fb[:]) {
			if code := infer_file_into(&inf, o, p, stdin_override, runner, stderr_w, alloc); code != EXIT_OK { return code }
		}
		desc, ierr := schema.inferred(&inf, alloc)
		if ierr != nil { return EXIT_RUNTIME }
		defer engine.destroy_schema_description(&desc)
		wopts := schema.Write_Options{indent = 0 if o.compact else u8(max(o.indent, 0)), tab = o.tab && !o.compact}
		txt, werr := schema.write_schema(&desc, wopts, alloc)
		if werr.kind != .None {
			fmt.wprintf(stderr_w, "stury: error: %s\n", werr.message)
			schema.error_destroy(&werr)
			return EXIT_RUNTIME
		}
		defer delete(txt, alloc)
		fok, iok := emit_schema_text(&osink, txt, o, i8(wopts.indent), alloc)
		if !fok { fmt.wprintln(stderr_w, "stury: error formatting inferred schema"); return EXIT_RUNTIME }
		return report_stdout_error(stderr_w, osink.io_err) if (!iok || !out_stream_flush(&osink)) else EXIT_OK
	case .Sample, .Odin:
		spath := o.files[0] if len(o.files) == 1 else o.schema_file
		if spath == "" || len(o.files) > 1 {
			fmt.wprintln(stderr_w, "stury: schema command takes one schema file")
			return EXIT_USAGE
		}
		sc, _, ok := compile_schema_file(o, spath, stderr_w, alloc)
		if !ok { return EXIT_USAGE }
		defer schema.destroy(sc)

		if o.schema_verb == .Sample {
			SOut :: struct { osink: ^Out_Stream, o: ^Options, alloc: runtime.Allocator }
			sout := SOut{osink = &osink, o = o, alloc = alloc}
			sopts := schema.Sample_Options{
				seed = o.seed, count = o.count if o.count > 0 else 1, invalid = o.invalid,
				format_assert = o.format_assert, indent = u8(max(o.indent, 0)) if o.indent_set && !o.compact else 0, tab = o.tab && !o.compact,
			}
			serr := schema.sample_each(sc.description, sopts, proc(text: []u8, user: rawptr) {
				so := (^SOut)(user)
				if so.osink.failed { return }
				if fok, _ := emit_schema_text(so.osink, text, so.o, so.o.indent if so.o.indent_set else 0, so.alloc); !fok {
					_ = out_stream_bytes_nl(so.osink, text)
				}
			}, &sout, alloc)
			if osink.failed || !out_stream_flush(&osink) { return report_stdout_error(stderr_w, osink.io_err) }
			if serr.kind != .None {
				fmt.wprintf(stderr_w, "stury: error: schema sample %s: %s\n", spath, serr.message)
				schema.error_destroy(&serr)
				return EXIT_FALSY
			}
			return EXIT_OK
		}
		pkg := strings.clone(o.schema_package, alloc) if o.schema_package != "" else strings.to_snake_case(filepath.short_stem(spath), alloc)
		defer delete(pkg, alloc)
		if pkg == "" { pkg = strings.clone("schema_types", alloc) }
		src, oerr := schema.write_odin(sc.description, pkg, o.format_assert, alloc)
		if oerr.kind != .None {
			fmt.wprintf(stderr_w, "stury: error: schema odin %s: %s\n", spath, oerr.message)
			schema.error_destroy(&oerr)
			return EXIT_FALSY
		}
		defer delete(src, alloc)
		return report_stdout_error(stderr_w, osink.io_err) if (!out_stream_bytes(&osink, transmute([]u8)src) || !out_stream_flush(&osink)) else EXIT_OK
	}
	return EXIT_USAGE
}
