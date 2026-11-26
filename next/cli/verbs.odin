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
import "stury:lib/ops/diff"
import "stury:lib/ops/edit"
import "stury:lib/ops/write"
import "stury:lib/query"
import "stury:lib/schema/check"
import "stury:lib/schema/ddl"
import "stury:lib/schema/model"
import "stury:lib/schema/rules"
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
	if path == "/dev/stdout" {
		qw^ = {file = os.stdout, close_file = false, active = true, path = path, alloc = alloc}
		return true
	}
	if path == "/dev/stderr" {
		qw^ = {file = os.stderr, close_file = false, active = true, path = path, alloc = alloc}
		return true
	}
	f, err := os.open(path, {.Write, .Create}, {.Read_User, .Write_User, .Read_Group, .Read_Other})
	if err == nil {
		err = os.truncate(f, 0)
		if err != nil {
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
	if qw == nil || !qw.active {
		return
	}
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
	qw.active = false
	qw.file = nil
	qw.close_file = false
}

@(private = "file")
quarantine_emit_doc :: proc(qw: ^Quarantine_Writer, tt: ^write.Token_Tape, alloc: runtime.Allocator) -> bool {
	if write.token_tape_take(tt, .Close, "") != nil {
		qw.write_failed = true
		return false
	}
	doc, derr := write.token_tape_document(tt)
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
	if qw == nil || !qw.active || qw.write_failed {
		return false
	}
	e, _ := engine.entry_of_spec(sp)
	psrc := place_src if len(place_src) > 0 else text
	err_buf: [512]u8
	msg := tape.error_message(err_buf[:], err, psrc, e.format)
	at_str := display
	at_owned := false
	if f, is_f := err.(tape.Fault); is_f && f.at != tape.NO_BYTE && !e.binary {
		lidx := tape.Line_Index{allocator = alloc}
		defer tape.destroy_line_index(&lidx)
		off := min(place_off + f.at, u64(len(psrc)))
		pl := tape.offset_place(psrc, &lidx, off, 0, 1, alloc)
		at_str = fmt.aprintf("%s:%d:%d", display, pl.line, pl.col, allocator = alloc)
		at_owned = true
	}
	defer if at_owned {
		delete(at_str, alloc)
	}
	tt: write.Token_Tape
	if write.token_tape_start(&tt, false, 0, alloc) != nil {
		qw.write_failed = true
		return false
	}
	defer write.token_tape_drop(&tt)

	num_buf: [24]u8
	if write.token_tape_take(&tt, .Object, "") != nil ||
	   write.token_tape_take(&tt, .Key, "record") != nil ||
	   write.token_tape_take(&tt, .Number, fmt.bprintf(num_buf[:], "%d", rec_no)) != nil ||
	   write.token_tape_take(&tt, .Key, "at") != nil ||
	   write.token_tape_take(&tt, .String, at_str) != nil ||
	   write.token_tape_take(&tt, .Key, "text") != nil ||
	   write.token_tape_take(&tt, .String, string(text)) != nil ||
	   write.token_tape_take(&tt, .Key, "problem") != nil ||
	   write.token_tape_take(&tt, .Object, "") != nil ||
	   write.token_tape_take(&tt, .Key, "title") != nil ||
	   write.token_tape_take(&tt, .String, "Bad record") != nil ||
	   write.token_tape_take(&tt, .Key, "status") != nil ||
	   write.token_tape_take(&tt, .Number, "400") != nil ||
	   write.token_tape_take(&tt, .Key, "errors") != nil ||
	   write.token_tape_take(&tt, .Array, "") != nil ||
	   write.token_tape_take(&tt, .Object, "") != nil ||
	   write.token_tape_take(&tt, .Key, "pointer") != nil ||
	   write.token_tape_take(&tt, .String, "") != nil ||
	   write.token_tape_take(&tt, .Key, "code") != nil ||
	   write.token_tape_take(&tt, .String, "walk") != nil ||
	   write.token_tape_take(&tt, .Key, "message") != nil ||
	   write.token_tape_take(&tt, .String, msg if msg != "" else "parse error") != nil ||
	   write.token_tape_take(&tt, .Close, "") != nil ||
	   write.token_tape_take(&tt, .Close, "") != nil ||
	   write.token_tape_take(&tt, .Close, "") != nil {
		qw.write_failed = true
		return false
	}
	return quarantine_emit_doc(qw, &tt, alloc)
}

@(private = "file")
problem_entry_from_check :: proc(ce: check.Check_Error, alloc: runtime.Allocator) -> model.Error_Entry {
	mk := model.Error_Kind(int(ce.kind)) if int(ce.kind) <= int(model.Error_Kind.Duplicate_Key) else .Check_Failed
	entry := model.Error_Entry{kind = mk, at = ce.at, pointer = ce.instance_location}
	if mk == .Wrong_Kind && ce.expected != "" {
		entry.want = {text = strings.clone(ce.expected, alloc)}
	} else if mk == .Missing_Field && ce.expected != "" {
		entry.operand = fmt.aprintf("member %q", ce.expected, allocator = alloc)
	} else {
		entry.operand = schema.error_message(ce, alloc)
	}
	return entry
}

@(private = "file")
free_problem_entries :: proc(me: []model.Error_Entry, alloc: runtime.Allocator) {
	for item in me {
		if item.want.text != "" {
			delete(item.want.text, alloc)
		}
		if item.operand != "" {
			delete(item.operand, alloc)
		}
	}
	delete(me, alloc)
}

quarantine_write_invalid :: proc(
	qw: ^Quarantine_Writer,
	rec_no: i64,
	display: string,
	entries: []check.Check_Error,
	src: []u8,
	alloc: runtime.Allocator,
	place_src: []u8 = nil,
	place_off: u64 = 0,
	redact_paths: []string = nil,
) -> bool {
	if qw == nil || !qw.active || qw.write_failed {
		return false
	}
	psrc := place_src if len(place_src) > 0 else src
	lidx := tape.Line_Index{allocator = alloc}
	defer tape.destroy_line_index(&lidx)
	at_str := display
	if len(entries) > 0 {
		off := min(place_off + entries[0].at, u64(len(psrc)))
		pl := tape.offset_place(psrc, &lidx, off, 0, 1, alloc)
		at_str = fmt.aprintf("%s:%d:%d", display, pl.line, pl.col, allocator = alloc)
	} else {
		at_str = fmt.aprintf("%s:1:1", display, allocator = alloc)
	}
	defer delete(at_str, alloc)

	me := make([]model.Error_Entry, len(entries), alloc)
	defer free_problem_entries(me, alloc)
	for ce, i in entries {
		me[i] = problem_entry_from_check(ce, alloc)
	}

	tt: write.Token_Tape
	if write.token_tape_start(&tt, false, 0, alloc) != nil {
		qw.write_failed = true
		return false
	}
	defer write.token_tape_drop(&tt)
	num_buf: [24]u8
	if write.token_tape_take(&tt, .Object, "") != nil ||
	   write.token_tape_take(&tt, .Key, "record") != nil ||
	   write.token_tape_take(&tt, .Number, fmt.bprintf(num_buf[:], "%d", rec_no)) != nil ||
	   write.token_tape_take(&tt, .Key, "at") != nil ||
	   write.token_tape_take(&tt, .String, at_str) != nil ||
	   write.token_tape_take(&tt, .Key, "text") != nil ||
	   write.token_tape_take(&tt, .String, string(src)) != nil ||
	   write.token_tape_take(&tt, .Key, "problem") != nil {
		qw.write_failed = true
		return false
	}
	popts := model.Problem_Opts{redact = len(redact_paths) > 0, redact_paths = redact_paths}
	if model.write_problem_tokens(&tt, me, {title = "Invalid input", status = 422}, false, alloc, popts) != nil {
		qw.write_failed = true
		return false
	}
	return quarantine_emit_doc(qw, &tt, alloc)
}

@(private = "file")
verb_file_spec :: proc(o: ^Options, path: string) -> (engine.Spec, engine.Framing) {
	sp, fr := detect_file_spec(o, path)
	if o.merge_keys && sp == engine.spec_of_id(.Yaml) {
		sp = engine.spec_of_id(.Yaml_Merge)
	}
	return sp, fr
}

@(private = "file")
verb_read_opts :: proc(o: ^Options, sp: engine.Spec, runner: ^tape.Runner) -> tape.Options {
	ro := read_opts_of(o, sp, runner)
	if e, ok := engine.entry_of_spec(sp); ok && e.family == .Yaml && o.yaml_schema_set {
		ro.format = tape.Yaml_Options{dialect = o.yaml_schema}
	}
	return ro
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
	cand := path
	joined: string
	if !filepath.is_abs(path) && rc.dir != "" {
		if j, je := filepath.join({rc.dir, path}, alloc); je == nil {
			joined, cand = j, j
		} else {
			return nil, false, false
		}
	}
	defer if joined != "" {
		delete(joined, alloc)
	}
	if rc.dir != "" {
		ad, de := os.get_absolute_path(rc.dir, alloc)
		ac, ce := os.get_absolute_path(cand, alloc)
		defer if de == nil {
			delete(ad, alloc)
		}
		defer if ce == nil {
			delete(ac, alloc)
		}
		if de != nil || ce != nil {
			return nil, false, false
		}
		base := strings.trim_right(ad, "/\\")
		target := strings.trim_right(ac, "/\\")
		contained := target == base ||
			(len(target) > len(base) && (target[len(base)] == '/' || target[len(base)] == '\\') && strings.has_prefix(target, base))
		if !contained {
			return nil, false, false
		}
	}
	raw, rerr := os.read_entire_file_from_path(cand, alloc)
	if rerr == nil {
		return raw, true, true
	}
	return nil, false, false
}

@(private)
compile_schema_file :: proc(o: ^Options, path: string, stderr_w: io.Writer, alloc: runtime.Allocator) -> (^schema.Compiled, Ref_Ctx, bool) {
	if o.schema_ref != "" && !os.is_dir(o.schema_ref) {
		fmt.wprintf(stderr_w, "stury: error: --schema-ref %s is not a directory\n", o.schema_ref)
		return nil, {}, false
	}
	data, rok := read_path_or_stdin(path, false, stderr_w, alloc)
	if !rok {
		return nil, {}, false
	}
	defer delete(data, alloc)

	dir := o.schema_ref if o.schema_ref != "" else filepath.dir(path)
	if dir == "" {
		dir = "."
	}
	rc := Ref_Ctx{dir = dir, alloc = alloc}
	sp := engine.spec_of_id(.Json)
	if se, _, ok := engine.format_of_path(path); ok {
		sp = se.spec
	}
	sopts := schema.Options {
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
		desc, aerr := new(rules.Description, alloc)
		if aerr != nil || desc == nil {
			rules.description_destroy(&d)
			fmt.wprintf(stderr_w, "stury: error: schema %s: out of memory\n", path)
			return nil, {}, false
		}
		desc^ = d
		c, cerr := schema.compile_description(desc, sopts, alloc)
		if cerr.kind != .None {
			rules.description_destroy(desc)
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
			pl := tape.offset_place(data, nil, cerr.at)
			snip_buf: [1024]u8
			if snip, has_snip := tape.error_snippet(snip_buf[:], data, cerr.at); has_snip {
				fmt.wprintf(stderr_w, "stury: error: schema %s:%d:%d: %s\n%s", path, pl.line, pl.col, cerr.message, snip)
			} else {
				fmt.wprintf(stderr_w, "stury: error: schema %s:%d:%d: %s\n", path, pl.line, pl.col, cerr.message)
			}
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
		if !out_stream_bytes(osink, data) {
			return EXIT_USAGE
		}
	}
	return EXIT_OK
}

// ---- `stury check` ----

run_check :: proc(
	o: ^Options,
	stdin_override: Maybe([]u8),
	stdout_w, stderr_w: io.Writer,
	runner: ^tape.Runner,
	alloc: runtime.Allocator,
) -> int {
	sc: ^schema.Compiled
	if o.schema_file != "" {
		ok: bool
		sc, _, ok = compile_schema_file(o, o.schema_file, stderr_w, alloc)
		if !ok {
			return EXIT_USAGE
		}
	}
	defer schema.destroy(sc)

	qw: Quarantine_Writer
	if o.quarantine != "" {
		if !quarantine_open(&qw, o.quarantine, stderr_w, alloc) {
			return EXIT_USAGE
		}
	}
	defer quarantine_close(&qw, stderr_w)

	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, false)

	fb := [1]string{"-"}
	paths := o.files[:] if len(o.files) > 0 else fb[:]
	has_open_err := false
	worst := EXIT_OK

	for p in paths {
		src, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
		if !rok {
			has_open_err = true
			continue
		}
		disp := "<stdin>" if p == "-" else p
		sp, fr := verb_file_spec(o, p)
		e, _ := engine.entry_of_spec(sp)
		ro := verb_read_opts(o, sp, runner)

		if e.family == .Json && fr == .Single && len(bytes.trim_space(src)) == 0 {
			fmt.wprintf(stderr_w, "stury: parse error (%s): No JSON text\n", disp)
			worst = max(worst, EXIT_RUNTIME)
			if owned {
				delete(src, alloc)
			}
			continue
		}

		if !e.tabular && (fr == .Lines || fr == .Seq) {
			it, ok := rec_loop_open(src, sp, fr, ro, o.skip_bad, disp, stderr_w, alloc)
			if !ok {
				worst = max(worst, EXIT_RUNTIME)
				if owned {
					delete(src, alloc)
				}
				continue
			}
			rec_no := i64(0)
			for rec, rinfo, err in rec_loop_next(&it) {
				rec_no += 1
				if err != nil {
					_ = print_tape_error(stderr_w, disp, err, src, sp, ignoring = o.skip_bad)
					worst = max(worst, EXIT_RUNTIME)
					if qw.active {
						_ = quarantine_write_bad(&qw, rec_no, disp, err, rec, sp, alloc, src)
					}
					continue
				}
				if sc != nil {
					code := check_bytes_schema(o, sc, disp, rec, sp, rec_no, &qw, &osink, stderr_w, alloc, src, rinfo.lo)
					worst = max(worst, code)
				} else if o.dups == .Refuse && !e.tabular {
					if doc, berr := engine.build(rec, sp, ro, alloc); berr != nil {
						_ = print_tape_error(stderr_w, disp, berr, rec, sp, false, src, rinfo.lo)
						worst = max(worst, EXIT_RUNTIME)
						if qw.active {
							_ = quarantine_write_bad(&qw, rec_no, disp, berr, rec, sp, alloc, src, rinfo.lo)
						}
					} else {
						tape.destroy_document(&doc)
					}
				}
			}
			if it.tail_err != nil {
				worst = max(worst, EXIT_RUNTIME)
			}
			rec_loop_close(&it)
			if owned {
				delete(src, alloc)
			}
			continue
		}

		if sc != nil {
			code := check_bytes_schema(o, sc, disp, src, sp, 1, &qw, &osink, stderr_w, alloc)
			worst = max(worst, code)
		} else {
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
				worst = max(worst, EXIT_RUNTIME)
			}
		}
		if owned {
			delete(src, alloc)
		}
		if osink.failed {
			return report_stdout_error(stderr_w, osink.io_err)
		}
	}

	if !out_stream_flush(&osink) {
		return report_stdout_error(stderr_w, osink.io_err)
	}
	if qw.write_failed || has_open_err {
		return EXIT_USAGE
	}
	return worst
}

@(private = "file")
dsv_opts_for :: proc "contextless" (o: ^Options, sp: engine.Spec) -> (d: tape.Dsv_Options, active: bool) {
	e, ok := engine.entry_of_spec(sp)
	if !ok || e.family != .Dsv {
		return {}, false
	}
	return o.dsv_in, o.dsv_in_set || o.infer
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
	sink: check.Sink
	check.sink_init(&sink, alloc)
	defer check.sink_destroy(&sink)

	psrc := place_src if len(place_src) > 0 else src
	e, _ := engine.entry_of_spec(sp)
	use_doc := (e.family == .Dsv && o.dsv_tolerate != {}) || (e.family == .Xml && (o.xml_tolerate != {} || o.xml_arrays != .Auto))
	res: check.Result
	if use_doc {
		ro := verb_read_opts(o, sp, nil)
		doc, berr := engine.build(src, sp, ro, alloc)
		if berr != nil {
			_ = print_tape_error(stderr_w, display, berr, src, sp, false, place_src, place_off)
			if qw != nil && qw.active {
				_ = quarantine_write_bad(qw, rec_no, display, berr, src, sp, alloc, place_src, place_off)
			}
			return EXIT_RUNTIME
		}
		defer tape.destroy_document(&doc)
		if e.family == .Xml && o.xml_arrays == .Schema {
			if nerr := engine.apply_xml_arrays(&doc, .Schema, sc.description, alloc); nerr != nil {
				_ = print_tape_error(stderr_w, display, nerr, src, sp, false, place_src, place_off)
				if qw != nil && qw.active {
					_ = quarantine_write_bad(qw, rec_no, display, nerr, src, sp, alloc, place_src, place_off)
				}
				return EXIT_RUNTIME
			}
		}
		// Normalized XML documents have already grouped siblings and wrapped schema/always arrays, so avoid
		// `check_document`'s `.Group` re-wrapping pass (which would double-wrap existing `.Array` nodes).
		check_dups := o.dups
		if e.family == .Xml && o.xml_arrays != .Auto && (check_dups == .Default || check_dups == .Group) {
			check_dups = .All
		}
		res = engine.check_document(&doc, &sc.plan, {dups = check_dups, budget = o.budget}, &sink, alloc)
	} else {
		dopts, has_dsv := dsv_opts_for(o, sp)
		yopts := tape.Yaml_Options{dialect = o.yaml_schema} if (e.family == .Yaml && o.yaml_schema_set) else {}
		res = engine.check_schema(src, sp, &sc.plan, {dups = o.dups, budget = o.budget}, &sink, alloc, dopts if has_dsv else {}, yopts)
	}
	defer check.result_destroy(&res)

	if res.walk_err != nil {
		_ = print_tape_error(stderr_w, display, res.walk_err, src, sp, false, place_src, place_off)
		if qw != nil && qw.active {
			_ = quarantine_write_bad(qw, rec_no, display, res.walk_err, src, sp, alloc, place_src, place_off)
		}
		return EXIT_RUNTIME
	}
	if res.valid {
		if o.report == .Basic {
			if txt, berr := schema.write_basic_report(nil, sc.description.uri, sc.description.bases[:], {file = display}, alloc); berr.kind == .None {
				ok := out_stream_bytes_nl(osink, txt)
				delete(txt, alloc)
				if !ok {
					return EXIT_USAGE
				}
			}
		}
		return EXIT_OK
	}

	if qw != nil && qw.active {
		_ = quarantine_write_invalid(qw, rec_no, display, sink.entries[:], src, alloc, place_src, place_off, o.redact_paths[:])
	}
	entries := sink.entries[:]
	truncated := false
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
			if !ok {
				return EXIT_USAGE
			}
		}
	case .Problem:
		me := make([]model.Error_Entry, len(entries), alloc)
		defer free_problem_entries(me, alloc)
		for ce, i in entries {
			me[i] = problem_entry_from_check(ce, alloc)
		}
		tt: write.Token_Tape
		if write.token_tape_start(&tt, false, 0, alloc) == nil {
			defer write.token_tape_drop(&tt)
			popts := model.Problem_Opts{redact = len(o.redact_paths) > 0, redact_paths = o.redact_paths[:]}
			if model.write_problem_tokens(&tt, me, {title = "Invalid input", status = 422}, truncated, alloc, popts) == nil {
				if doc, derr := write.token_tape_document(&tt); derr == nil {
					if !write_doc_line(osink, &doc, engine.spec_of_id(.Json), {}, alloc) {
						return EXIT_USAGE
					}
				}
			}
		}
	}
	return EXIT_FALSY
}

@(private = "file")
write_doc_line :: proc(osink: ^Out_Stream, doc: ^tape.Document, sp: engine.Spec, wopts: write.Options, alloc: runtime.Allocator) -> bool {
	if _, err := engine.write_to(out_stream_writer(osink), doc, sp, wopts, alloc); err != nil {
		if ioe, is_io := err.(io.Error); is_io {
			osink.failed = true
			osink.io_err = ioe
		}
		return false
	}
	nl := [1]u8{'\n'}
	return out_stream_write(osink, nl[:])
}

@(private = "file")
build_xml_schema_doc :: proc(
	src: []u8,
	sp: engine.Spec,
	ro: tape.Options,
	desc: ^rules.Description,
	alloc: runtime.Allocator,
) -> (doc: tape.Document, err: engine.Format_Error) {
	built, berr := engine.build(src, sp, ro, alloc)
	if berr != nil {
		return {}, berr
	}
	if nerr := engine.apply_xml_arrays(&built, .Schema, desc, alloc); nerr != nil {
		tape.destroy_document(&built)
		return {}, nerr
	}
	return built, nil
}

// ---- `stury fmt` ----

run_fmt :: proc(
	o: ^Options,
	stdin_override: Maybe([]u8),
	stdout_w, stderr_w: io.Writer,
	runner: ^tape.Runner,
	alloc: runtime.Allocator,
) -> int {
	if !preflight_in_place(o, true, stderr_w, alloc) {
		return EXIT_USAGE
	}
	sc: ^schema.Compiled
	if o.schema_file != "" {
		ok: bool
		sc, _, ok = compile_schema_file(o, o.schema_file, stderr_w, alloc)
		if !ok {
			return EXIT_USAGE
		}
	}
	defer schema.destroy(sc)

	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, false)

	fb := [1]string{"-"}
	paths := o.files[:] if len(o.files) > 0 else fb[:]
	has_open_err := false
	worst := EXIT_OK

	for p in paths {
		src, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
		if !rok {
			has_open_err = true
			continue
		}
		disp := "<stdin>" if p == "-" else p
		sp, fr := verb_file_spec(o, p)
		e, _ := engine.entry_of_spec(sp)
		ro := verb_read_opts(o, sp, runner)
		to_sp := o.to_spec if o.has_to else sp
		to_e, _ := engine.entry_of_spec(to_sp)
		wopts := make_write_opts(o, to_sp, 0 if (!o.indent_set && (fr == .Lines || o.to_framing == .Lines)) else o.indent)

		if sc != nil {
			chk := check_bytes_schema(o, sc, disp, src, sp, 1, nil, &osink, stderr_w, alloc)
			if chk != EXIT_OK {
				worst = max(worst, chk)
				if owned {
					delete(src, alloc)
				}
				continue
			}
		}

		// Stream directly to stdout via `engine.format_to` / `format` when not buffering for `--check` / `-i`.
		direct_stream := !o.check && !o.in_place && (e.tabular || (fr != .Lines && fr != .Seq))
		if direct_stream {
			before_bytes := osink.total_written
			dropped: tape.Facts
			ferr: engine.Format_Error
			if o.to_render != .None {
				doc: tape.Document
				if e.family == .Xml && o.xml_arrays == .Schema && sc != nil {
					doc, ferr = build_xml_schema_doc(src, sp, ro, sc.description, alloc)
				} else {
					berr: tape.Error
					doc, berr = engine.build(src, sp, ro, alloc)
					if berr != nil {
						ferr = berr
					}
				}
				if ferr == nil {
					defer tape.destroy_document(&doc)
					if werr := write_doc_render_to(out_stream_writer(&osink), &doc, o.to_render, o.sort_keys, o.compact, o.dsv_out.no_header, tape.ROOT, alloc); werr != nil {
						ferr = werr
					}
				}
			} else if e.family == .Xml && o.xml_arrays == .Schema && sc != nil {
				doc, derr := build_xml_schema_doc(src, sp, ro, sc.description, alloc)
				if derr != nil {
					ferr = derr
				} else {
					defer tape.destroy_document(&doc)
					wdr, werr := engine.write_to(out_stream_writer(&osink), &doc, to_sp, wopts, alloc)
					dropped = wdr
					if werr != nil {
						ferr = werr
					}
				}
			} else {
				dropped, ferr = engine.format_to(out_stream_writer(&osink), src, sp, to_sp, ro, wopts, alloc)
			}
			if ferr != nil {
				fcode := report_format_error(ferr, disp, src, sp, &osink, stderr_w, alloc)
				if fcode == EXIT_USAGE {
					if owned {
						delete(src, alloc)
					}
					return report_stdout_error(stderr_w, osink.io_err)
				}
				worst = max(worst, fcode)
				if owned {
					delete(src, alloc)
				}
				continue
			}
			if !to_e.binary && (osink.total_written == before_bytes || osink.last_byte != '\n') {
				nl := [1]u8{'\n'}
				if !out_stream_write(&osink, nl[:]) {
					if owned {
						delete(src, alloc)
					}
					return report_stdout_error(stderr_w, osink.io_err)
				}
			}
			if osink.unbuffered && !out_stream_flush(&osink) {
				if owned {
					delete(src, alloc)
				}
				return report_stdout_error(stderr_w, osink.io_err)
			}
			if o.diff_facts && dropped != {} {
				fmt.wprintf(stderr_w, "stury: note (%s): dropped %v\n", disp, dropped)
			}
			if owned {
				delete(src, alloc)
			}
			continue
		}

		formatted: []u8
		dropped: tape.Facts
		if !e.tabular && (fr == .Lines || fr == .Seq) {
			if o.to_render != .None {
				docs := make([dynamic]tape.Document, alloc)
				defer {
					for &d in docs {
						tape.destroy_document(&d)
					}
					delete(docs)
				}
				failed := false
				it, ok := rec_loop_open(src, sp, fr, ro, false, disp, stderr_w, alloc)
				if !ok {
					worst = max(worst, EXIT_RUNTIME)
					if owned {
						delete(src, alloc)
					}
					continue
				}
				for rec, rinfo, err in rec_loop_next(&it) {
					if err != nil {
						_ = print_tape_error(stderr_w, disp, err, src, sp)
						failed = true
						break
					}
					d, berr := engine.build(rec, sp, ro, alloc)
					if berr != nil {
						_ = print_tape_error(stderr_w, disp, berr, rec, sp, false, src, rinfo.lo)
						failed = true
						break
					}
					append(&docs, d)
				}
				tail_bad := it.tail_err != nil
				rec_loop_close(&it)
				if failed || tail_bad {
					worst = max(worst, EXIT_RUNTIME)
					if owned {
						delete(src, alloc)
					}
					continue
				}
				wtxt: []u8
				werr: write.Error
				if o.to_render == .Table {
					wtxt, werr = write.write_table_docs(docs[:], {style = .Compact if o.compact else .Plain, sort_keys = o.sort_keys, no_header = o.dsv_out.no_header}, alloc)
				} else {
					wtxt, werr = write.write_markdown_docs(docs[:], {sort_keys = o.sort_keys, compact = o.compact}, alloc)
				}
				if werr != nil {
					fcode := report_format_error(werr, disp, src, sp, &osink, stderr_w, alloc)
					if owned {
						delete(src, alloc)
					}
					if fcode == EXIT_USAGE {
						return report_stdout_error(stderr_w, osink.io_err)
					}
					worst = max(worst, fcode)
					continue
				}
				formatted = wtxt
			} else {
				fb_out := make([dynamic]u8, 0, len(src), alloc)
				failed := false
				it, ok := rec_loop_open(src, sp, fr, ro, false, disp, stderr_w, alloc)
				if !ok {
					delete(fb_out)
					worst = max(worst, EXIT_RUNTIME)
					if owned {
						delete(src, alloc)
					}
					continue
				}
				for rec, rinfo, err in rec_loop_next(&it) {
					if err != nil {
						_ = print_tape_error(stderr_w, disp, err, src, sp)
						failed = true
						break
					}
					if o.to_framing == .Seq || fr == .Seq {
						append(&fb_out, 0x1e)
					}
					part, dr, ferr := engine.format(rec, sp, to_sp, ro, wopts, alloc)
					if ferr != nil {
						_ = report_format_error(ferr, disp, rec, sp, &osink, stderr_w, alloc, src, rinfo.lo)
						failed = true
						break
					}
					dropped += dr
					append(&fb_out, ..part)
					append(&fb_out, '\n')
					delete(part, alloc)
				}
				tail_bad := it.tail_err != nil
				rec_loop_close(&it)
				if failed || tail_bad {
					delete(fb_out)
					worst = max(worst, EXIT_RUNTIME)
					if owned {
						delete(src, alloc)
					}
					continue
				}
				formatted = fb_out[:]
			}
		} else {
			ftxt: []u8
			dr: tape.Facts
			ferr: engine.Format_Error
			if o.to_render != .None {
				doc: tape.Document
				if e.family == .Xml && o.xml_arrays == .Schema && sc != nil {
					doc, ferr = build_xml_schema_doc(src, sp, ro, sc.description, alloc)
				} else {
					berr: tape.Error
					doc, berr = engine.build(src, sp, ro, alloc)
					if berr != nil {
						ferr = berr
					}
				}
				if ferr == nil {
					defer tape.destroy_document(&doc)
					wtxt, werr := write_doc_render(&doc, o.to_render, o.sort_keys, o.compact, o.dsv_out.no_header, tape.ROOT, alloc)
					ftxt = wtxt
					if werr != nil {
						ferr = werr
					}
				}
			} else if e.family == .Xml && o.xml_arrays == .Schema && sc != nil {
				doc, derr := build_xml_schema_doc(src, sp, ro, sc.description, alloc)
				if derr != nil {
					ferr = derr
				} else {
					defer tape.destroy_document(&doc)
					wtxt, wdr, werr := engine.write(&doc, to_sp, wopts, alloc)
					ftxt, dr = wtxt, wdr
					if werr != nil {
						ferr = werr
					}
				}
			} else {
				ftxt, dr, ferr = engine.format(src, sp, to_sp, ro, wopts, alloc)
			}
			if ferr != nil {
				fcode := report_format_error(ferr, disp, src, sp, &osink, stderr_w, alloc)
				if owned {
					delete(src, alloc)
				}
				if fcode == EXIT_USAGE {
					return report_stdout_error(stderr_w, osink.io_err)
				}
				worst = max(worst, fcode)
				continue
			}
			dropped = dr
			if !to_e.binary && (len(ftxt) == 0 || ftxt[len(ftxt) - 1] != '\n') {
				nb := make([dynamic]u8, 0, len(ftxt) + 1, alloc)
				append(&nb, ..ftxt)
				append(&nb, '\n')
				delete(ftxt, alloc)
				formatted = nb[:]
			} else {
				formatted = ftxt
			}
		}
		if o.diff_facts && dropped != {} {
			fmt.wprintf(stderr_w, "stury: note (%s): dropped %v\n", disp, dropped)
		}
		ccode := commit_file_output(o, p, disp, src, formatted, "is not formatted", &osink, stderr_w, alloc)
		delete(formatted, alloc)
		if owned {
			delete(src, alloc)
		}
		if ccode == EXIT_USAGE && osink.failed {
			return report_stdout_error(stderr_w, osink.io_err)
		}
		worst = max(worst, ccode)
	}

	if !out_stream_flush(&osink) {
		return report_stdout_error(stderr_w, osink.io_err)
	}
	if has_open_err {
		return EXIT_USAGE
	}
	return worst
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
	case write.Error:
		if ioe, is_io := err.(io.Error); is_io {
			osink.failed = true
			osink.io_err = ioe
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
Edit_Span :: struct {
	lo, end: u64,
}

@(private = "file")
Edit_Part :: struct {
	span_idx: int,
	bytes:    []u8,
}

@(private = "file")
edit_run_doc :: proc(
	o: ^Options,
	sh: ^Shared_Jq_State,
	worker: ^Jq_Worker,
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
	defer {
		query.release(&h, inp)
		h.write_fact, h.write_fact_data = nil, nil
	}
	globs, gok := build_globals_from_shared(&h, sh.main_prog, sh, alloc)
	if !gok {
		return parts, false, false, EXIT_RUNTIME
	}
	defer {
		for g in globs {
			query.release(&h, g)
		}
		delete(globs, alloc)
	}

	worker.hook_ctx.file_path = display
	jrun: jq.Run
	jq.run_init(&jrun, sh.main_prog, &h, globs, &worker.hooks, steps = int(o.budget.steps))
	defer jq.run_destroy(&jrun)

	Outs :: struct {
		vals: [dynamic]query.Value,
	}
	outs := Outs{vals = make([dynamic]query.Value, alloc)}
	defer {
		for v in outs.vals {
			query.release(&h, v)
		}
		delete(outs.vals)
	}
	end := jq.run_value(&jrun, inp, proc(d: rawptr, v: query.Value, _h: ^query.Heap) -> bool {
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
	eopts := edit.Options{
		reflow = o.reflow,
		indent = 0 if o.compact else u8(max(o.indent, 0)),
		tab    = o.tab && !o.compact,
	}
	for v, i in outs.vals {
		vt := query.type_of(v)
		last_falsy = (vt == .Null || vt == .False)
		if i == 0 {
			yopts := tape.Yaml_Options{dialect = o.yaml_schema} if o.yaml_schema_set else {}
			cres, cerr := engine.reconcile_edit(&h, ov, v, sp, eopts, alloc, yopts)
			if cerr != nil {
				edit.destroy_commit_result(&cres)
				msg := edit_error_text(cerr, alloc)
				fmt.wprintf(stderr_w, "stury: edit refused (%s): %s\n", display, msg)
				delete(msg, alloc)
				for pt in parts {
					delete(pt, alloc)
				}
				clear(&parts)
				return parts, false, false, EXIT_RUNTIME
			}
			append(&parts, slice.clone(cres.bytes, alloc))
			edit.destroy_commit_result(&cres)
		} else {
			buf := make([dynamic]u8, 0, 128, alloc)
			wopts := make_write_opts(o, sp, 0 if o.compact else o.indent)
			ok, emsg := write_value_as_format(&h, v, sp, wopts, &buf, {}, int(o.budget.depth), alloc)
			if !ok {
				delete(buf)
				fmt.wprintf(stderr_w, "stury: edit (%s): %s\n", display, emsg)
				delete(emsg, alloc)
				for pt in parts {
					delete(pt, alloc)
				}
				clear(&parts)
				return parts, false, false, EXIT_RUNTIME
			}
			append(&parts, buf[:])
		}
	}
	return parts, last_falsy, false, EXIT_OK
}

@(private = "file")
edit_join_records :: proc(src: []u8, spans: []Edit_Span, outs: []Edit_Part, fr: engine.Framing, alloc: runtime.Allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(src), alloc)
	if len(outs) == 0 || len(spans) == 0 {
		return out[:]
	}
	prev_span := -1
	for p in outs {
		s := spans[p.span_idx]
		if p.span_idx == prev_span {
			tail := src[s.end:]
			eol := "\r\n" if (len(tail) >= 2 && tail[0] == '\r' && tail[1] == '\n') else "\n"
			append(&out, eol)
			if fr == .Seq {
				append(&out, 0x1e)
			}
		} else if prev_span >= 0 {
			gap_start := spans[prev_span].end if p.span_idx == prev_span + 1 else spans[p.span_idx - 1].end
			append(&out, ..src[gap_start:s.lo])
		} else if p.span_idx == 0 {
			append(&out, ..src[0:s.lo])
		} else if fr == .Seq {
			lead := src[spans[p.span_idx - 1].end:s.lo]
			if rs := bytes.index_byte(lead, 0x1e); rs >= 0 {
				append(&out, ..lead[rs:])
			} else {
				append(&out, 0x1e)
			}
		} else {
			append(&out, ..src[0:spans[0].lo])
		}
		append(&out, ..p.bytes)
		prev_span = p.span_idx
	}
	append(&out, ..src[spans[len(spans) - 1].end:])
	return out[:]
}

run_edit :: proc(
	o: ^Options,
	stdin_override: Maybe([]u8),
	stdout_w, stderr_w: io.Writer,
	runner: ^tape.Runner,
	exe_dir, cwd, home_dir: string,
	alloc: runtime.Allocator,
) -> int {
	if !preflight_in_place(o, false, stderr_w, alloc) {
		return EXIT_USAGE
	}
	if o.filter == nil && !o.from_file {
		fmt.wprintln(stderr_w, "stury: edit requires a jq filter")
		return EXIT_USAGE
	}
	prog, _, cok, ccode := compile_jq_cmd(o, exe_dir, cwd, home_dir, stderr_w, alloc)
	if !cok {
		return ccode
	}
	defer jq.destroy_program(prog)

	plan := jq.analyze(prog, {slurp = o.slurp, raw_input = o.raw_input}, alloc)
	defer jq.destroy_plan(&plan)

	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, false)

	cfg := Render_Config{compact = o.compact, indent = o.indent, tab = o.tab, sort_keys = o.sort_keys, ascii = o.ascii, colors = DEFAULT_COLORS}
	sh, serr := shared_jq_init(o, &cfg, prog, &plan, &osink, stderr_w, alloc)
	if serr != "" {
		fmt.wprintf(stderr_w, "stury: error: %s\n", serr)
		delete(serr, alloc)
		return EXIT_USAGE
	}
	defer shared_jq_destroy(sh)

	worker, wok := new_jq_worker(sh, alloc, true)
	if !wok {
		fmt.wprintln(stderr_w, "stury: error: out of memory")
		return EXIT_RUNTIME
	}
	defer free_jq_worker(worker)

	fb := [1]string{"-"}
	paths := o.files[:] if len(o.files) > 0 else fb[:]
	has_open_err := false
	worst := EXIT_OK
	any_out := false
	last_falsy := false

	for p in paths {
		src, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
		if !rok {
			has_open_err = true
			continue
		}
		disp := "<stdin>" if p == "-" else p
		sp, fr := verb_file_spec(o, p)
		e, _ := engine.entry_of_spec(sp)
		ro := verb_read_opts(o, sp, runner)

		edited: []u8
		edited_owned := false

		if !e.tabular && (fr == .Lines || fr == .Seq) {
			spans := make([dynamic]Edit_Span, alloc)
			outs := make([dynamic]Edit_Part, alloc)
			defer {
				delete(spans)
				for pt in outs {
					delete(pt.bytes, alloc)
				}
				delete(outs)
			}
			it, ok := rec_loop_open(src, sp, fr, ro, false, disp, stderr_w, alloc)
			if !ok {
				worst = max(worst, EXIT_RUNTIME)
				if owned {
					delete(src, alloc)
				}
				continue
			}
			failed := false
			for rec, rinfo, err in rec_loop_next(&it) {
				if err != nil {
					_ = print_tape_error(stderr_w, disp, err, src, sp)
					failed = true
					break
				}
				end_pos := rinfo.hi
				for fr == .Seq && end_pos > rinfo.lo && (src[end_pos - 1] == ' ' || src[end_pos - 1] == '\t' || src[end_pos - 1] == '\r' || src[end_pos - 1] == '\n') {
					end_pos -= 1
				}
				span_idx := len(spans)
				append(&spans, Edit_Span{lo = rinfo.lo, end = end_pos})
				parts, lf, hlt, ec := edit_run_doc(o, sh, worker, rec, sp, ro, false, disp, stderr_w, alloc, src, rinfo.lo)
				if hlt {
					for pt in parts {
						delete(pt, alloc)
					}
					delete(parts)
					rec_loop_close(&it)
					if owned {
						delete(src, alloc)
					}
					return ec
				}
				if ec != EXIT_OK {
					delete(parts)
					failed = true
					break
				}
				for pb in parts {
					any_out = true
					last_falsy = lf
					append(&outs, Edit_Part{span_idx = span_idx, bytes = pb})
				}
				delete(parts)
			}
			tail_bad := it.tail_err != nil
			rec_loop_close(&it)
			if failed || tail_bad {
				worst = max(worst, EXIT_RUNTIME)
				if owned {
					delete(src, alloc)
				}
				continue
			}
			edited = edit_join_records(src, spans[:], outs[:], fr, alloc)
			edited_owned = true
		} else {
			parts, lf, hlt, ec := edit_run_doc(o, sh, worker, src, sp, ro, true, disp, stderr_w, alloc)
			if hlt {
				for pt in parts {
					delete(pt, alloc)
				}
				delete(parts)
				if owned {
					delete(src, alloc)
				}
				return ec
			}
			if ec != EXIT_OK || len(parts) == 0 {
				for pt in parts {
					delete(pt, alloc)
				}
				delete(parts)
				worst = max(worst, ec if ec != EXIT_OK else EXIT_RUNTIME)
				if owned {
					delete(src, alloc)
				}
				continue
			}
			any_out = true
			last_falsy = lf
			edited = parts[0]
			delete(parts)
			edited_owned = true
		}

		if o.diff_preview {
			doc_a, tt_a, ut_a, ok_da := build_diff_document(o, src, disp, sp, fr, ro, stderr_w, alloc)
			doc_b, tt_b, ut_b, ok_db := build_diff_document(o, edited, disp, sp, fr, ro, stderr_w, alloc)
			if ok_da && ok_db {
				if dr, derr := engine.diff_documents(&doc_a, &doc_b, {max_depth = int(o.budget.depth)}, alloc); derr == nil {
					if !print_diff_changes(&osink, &doc_a, &doc_b, dr.changes, false, disp if len(paths) > 1 else "", alloc) {
						diff.destroy_result(&dr)
						if ut_a {
							write.token_tape_drop(&tt_a)
						} else {
							tape.destroy_document(&doc_a)
						}
						if ut_b {
							write.token_tape_drop(&tt_b)
						} else {
							tape.destroy_document(&doc_b)
						}
						if edited_owned {
							delete(edited, alloc)
						}
						if owned {
							delete(src, alloc)
						}
						return report_stdout_error(stderr_w, osink.io_err)
					}
					diff.destroy_result(&dr)
				}
			}
			if ok_da {
				if ut_a {
					write.token_tape_drop(&tt_a)
				} else {
					tape.destroy_document(&doc_a)
				}
			}
			if ok_db {
				if ut_b {
					write.token_tape_drop(&tt_b)
				} else {
					tape.destroy_document(&doc_b)
				}
			}
		}
		out_code := commit_file_output(o, p, disp, src, edited, "would change", &osink, stderr_w, alloc)
		if edited_owned {
			delete(edited, alloc)
		}
		if owned {
			delete(src, alloc)
		}
		if out_code == EXIT_USAGE && osink.failed {
			return report_stdout_error(stderr_w, osink.io_err)
		}
		worst = max(worst, out_code)
	}

	if !out_stream_flush(&osink) {
		return report_stdout_error(stderr_w, osink.io_err)
	}
	if has_open_err {
		return EXIT_USAGE
	}
	if worst == EXIT_OK && o.exit_status {
		if !any_out {
			return EXIT_NO_OUTPUT
		}
		if last_falsy {
			return EXIT_FALSY
		}
	}
	return worst
}

@(private = "file")
edit_error_text :: proc(err: edit.Error, alloc: runtime.Allocator) -> string {
	switch e in err {
	case edit.Refusal:
		if e.group == .Layout_Conflict {
			return fmt.aprintf("%s (re-run with --reflow)", e.detail, allocator = alloc)
		}
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
DIFF_OP_NAMES := [diff.Op]string {
	.Added   = "added",
	.Removed = "removed",
	.Changed = "changed",
	.Fact    = "fact",
}

// Builds a single `tape.Document` from either a whole file or a framed sequence (`.Lines` / `.Seq` array of records).
@(private = "file")
build_diff_document :: proc(
	o: ^Options,
	src: []u8,
	display: string,
	sp: engine.Spec,
	fr: engine.Framing,
	ro: tape.Options,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
) -> (doc: tape.Document, tt: write.Token_Tape, using_tt: bool, ok: bool) {
	e, _ := engine.entry_of_spec(sp)
	if !e.tabular && (fr == .Lines || fr == .Seq) {
		it, iok := rec_loop_open(src, sp, fr, ro, false, display, stderr_w, alloc)
		if !iok {
			return {}, {}, false, false
		}
		defer rec_loop_close(&it)
		if write.token_tape_start(&tt, false, int(o.budget.depth), alloc) != nil {
			return {}, {}, false, false
		}
		if write.token_tape_take(&tt, .Array, "") != nil {
			write.token_tape_drop(&tt)
			return {}, {}, false, false
		}
		for rec, rinfo, err in rec_loop_next(&it) {
			if err != nil {
				_ = print_tape_error(stderr_w, display, err, src, sp)
				write.token_tape_drop(&tt)
				return {}, {}, false, false
			}
			rdoc, berr := engine.build(rec, sp, ro, alloc)
			if berr != nil {
				_ = print_tape_error(stderr_w, display, berr, rec, sp, false, src, rinfo.lo)
				write.token_tape_drop(&tt)
				return {}, {}, false, false
			}
			werr := write.tokens_of(&rdoc, tape.ROOT, &tt, write.token_tape_take, alloc)
			tape.destroy_document(&rdoc)
			if werr != nil {
				write.token_tape_drop(&tt)
				return {}, {}, false, false
			}
		}
		if it.tail_err != nil || write.token_tape_take(&tt, .Close, "") != nil {
			write.token_tape_drop(&tt)
			return {}, {}, false, false
		}
		tdoc, derr := write.token_tape_document(&tt)
		if derr != nil {
			write.token_tape_drop(&tt)
			return {}, {}, false, false
		}
		return tdoc, tt, true, true
	}
	bdoc, berr := engine.build(src, sp, ro, alloc)
	if berr != nil {
		_ = print_tape_error(stderr_w, display, berr, src, sp)
		return {}, {}, false, false
	}
	return bdoc, {}, false, true
}

run_diff :: proc(
	o: ^Options,
	stdin_override: Maybe([]u8),
	stdout_w, stderr_w: io.Writer,
	runner: ^tape.Runner,
	alloc: runtime.Allocator,
) -> int {
	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, false)

	two_named := o.old_schema != "" && o.new_schema != ""
	schema_two := (o.schema_file != "" || o.schema_flag_set) && len(o.files) == 2 && o.old_schema == "" && o.new_schema == ""
	if two_named || schema_two {
		sa, _, oka := compile_schema_file(o, o.old_schema if two_named else o.files[0], stderr_w, alloc)
		sb, _, okb := compile_schema_file(o, o.new_schema if two_named else o.files[1], stderr_w, alloc)
		defer schema.destroy(sa)
		defer schema.destroy(sb)
		if !oka || !okb {
			return EXIT_USAGE
		}
		code := report_schema_compare(o, sa.description, sb.description, &osink, stderr_w, alloc)
		if !out_stream_flush(&osink) {
			return report_stdout_error(stderr_w, osink.io_err)
		}
		return code
	}

	if (o.schema_file != "" || o.old_schema != "" || o.new_schema != "") && len(o.files) == 1 {
		sp_file := o.schema_file if o.schema_file != "" else o.old_schema if o.old_schema != "" else o.new_schema
		sc, _, ok := compile_schema_file(o, sp_file, stderr_w, alloc)
		defer schema.destroy(sc)
		if !ok {
			return EXIT_USAGE
		}
		src, owned, rok := read_input_bytes(o.files[0], stdin_override, stderr_w, alloc)
		if !rok {
			return EXIT_USAGE
		}
		defer if owned {
			delete(src, alloc)
		}
		disp := "<stdin>" if o.files[0] == "-" else o.files[0]
		sp, _ := verb_file_spec(o, o.files[0])
		chk := check_bytes_schema(o, sc, disp, src, sp, 1, nil, &osink, stderr_w, alloc)
		if chk == EXIT_RUNTIME || chk == EXIT_USAGE {
			return report_stdout_error(stderr_w, osink.io_err) if chk == EXIT_USAGE else EXIT_RUNTIME
		}
		seen, scode := infer_one_desc(o, o.files[0], stdin_override, runner, stderr_w, alloc)
		defer rules.description_destroy(&seen)
		if scode != EXIT_OK {
			return scode
		}
		cmp, cerr := schema.compare(sc.description, &seen, {format_assert = o.format_assert}, alloc)
		if cerr != nil {
			return EXIT_RUNTIME
		}
		defer schema.comparison_destroy(&cmp)

		drifted := false
		for ch in cmp.changes {
			if ch.keyword == "properties" && ch.old == nil && ch.effect != .Unknown {
				drifted = true
				sb := strings.builder_make(alloc)
				if o.diff_json {
					strings.write_string(&sb, `{"path":`)
					write_steps(&sb, ch.path, true)
					strings.write_string(&sb, ",\"undescribed\":true}\n")
				} else {
					strings.write_string(&sb, "+ ")
					write_steps(&sb, ch.path, false)
					strings.write_string(&sb, "  not described by schema\n")
				}
				written_ok := out_stream_bytes(&osink, transmute([]u8)strings.to_string(sb))
				strings.builder_destroy(&sb)
				if !written_ok {
					return report_stdout_error(stderr_w, osink.io_err)
				}
			}
		}
		if !out_stream_flush(&osink) {
			return report_stdout_error(stderr_w, osink.io_err)
		}
		return EXIT_FALSY if (chk != EXIT_OK || drifted) else EXIT_OK
	}

	if o.diff_shape {
		if len(o.files) != 2 {
			fmt.wprintln(stderr_w, "stury: --shape requires two files")
			return EXIT_USAGE
		}
		da, code_a := infer_one_desc(o, o.files[0], stdin_override, runner, stderr_w, alloc)
		defer rules.description_destroy(&da)
		if code_a != EXIT_OK {
			return code_a
		}
		db, code_b := infer_one_desc(o, o.files[1], stdin_override, runner, stderr_w, alloc)
		defer rules.description_destroy(&db)
		if code_b != EXIT_OK {
			return code_b
		}
		code := report_schema_compare(o, &da, &db, &osink, stderr_w, alloc)
		if !out_stream_flush(&osink) {
			return report_stdout_error(stderr_w, osink.io_err)
		}
		return code
	}

	if len(o.files) != 2 {
		fmt.wprintln(stderr_w, "stury: diff takes two files, OLD and NEW")
		return EXIT_USAGE
	}
	if o.files[0] == "-" && o.files[1] == "-" {
		fmt.wprintln(stderr_w, "stury: diff cannot read stdin (-) twice")
		return EXIT_USAGE
	}

	src_a, own_a, ok_a := read_input_bytes(o.files[0], stdin_override, stderr_w, alloc)
	if !ok_a {
		return EXIT_USAGE
	}
	defer if own_a {
		delete(src_a, alloc)
	}
	src_b, own_b, ok_b := read_input_bytes(o.files[1], stdin_override, stderr_w, alloc)
	if !ok_b {
		return EXIT_USAGE
	}
	defer if own_b {
		delete(src_b, alloc)
	}

	disp_a := "<stdin>" if o.files[0] == "-" else o.files[0]
	disp_b := "<stdin>" if o.files[1] == "-" else o.files[1]
	sp_a, fr_a := verb_file_spec(o, o.files[0])
	sp_b, fr_b := verb_file_spec(o, o.files[1])
	ro_a := verb_read_opts(o, sp_a, runner)
	ro_b := verb_read_opts(o, sp_b, runner)

	doc_a, tt_a, ut_a, build_a := build_diff_document(o, src_a, disp_a, sp_a, fr_a, ro_a, stderr_w, alloc)
	if !build_a {
		return EXIT_RUNTIME
	}
	defer if ut_a {
		write.token_tape_drop(&tt_a)
	} else {
		tape.destroy_document(&doc_a)
	}
	doc_b, tt_b, ut_b, build_b := build_diff_document(o, src_b, disp_b, sp_b, fr_b, ro_b, stderr_w, alloc)
	if !build_b {
		return EXIT_RUNTIME
	}
	defer if ut_b {
		write.token_tape_drop(&tt_b)
	} else {
		tape.destroy_document(&doc_b)
	}

	dopts := diff.Options{
		arrays    = o.diff_arrays,
		keys      = o.diff_keys[:],
		facts     = o.diff_facts,
		max_depth = int(o.budget.depth),
	}
	if o.diff_patch {
		patch, perr := diff.diff_to_patch(&doc_a, &doc_b, dopts, alloc)
		if perr != nil {
			return EXIT_RUNTIME
		}
		defer diff.destroy_patch(&patch)
		if patch.too_deep {
			fmt.wprintln(stderr_w, "stury: error: value nests past --max-depth")
			return EXIT_RUNTIME
		}
		if !print_rfc6902_patch(&osink, &patch, alloc) || !out_stream_flush(&osink) {
			return report_stdout_error(stderr_w, osink.io_err)
		}
		return EXIT_FALSY if len(patch.ops) > 0 else EXIT_OK
	}

	res, derr := engine.diff_documents(&doc_a, &doc_b, dopts, alloc)
	if derr != nil {
		return EXIT_RUNTIME
	}
	defer diff.destroy_result(&res)
	if res.too_deep {
		fmt.wprintln(stderr_w, "stury: error: value nests past --max-depth")
		return EXIT_RUNTIME
	}
	if len(res.unused_keys) > 0 {
		idx := res.unused_keys[0]
		spec_str := o.diff_keys_raw[idx] if idx >= 0 && idx < len(o.diff_keys_raw) else "?"
		fmt.wprintf(stderr_w, "stury: --key %s matched no array element\n", spec_str)
		return EXIT_USAGE
	}
	if !print_diff_changes(&osink, &doc_a, &doc_b, res.changes, o.diff_json, "", alloc) || !out_stream_flush(&osink) {
		return report_stdout_error(stderr_w, osink.io_err)
	}
	return EXIT_FALSY if len(res.changes) > 0 else EXIT_OK
}

@(private = "file")
print_rfc6902_patch :: proc(osink: ^Out_Stream, patch: ^diff.Patch, alloc: runtime.Allocator) -> bool {
	tt: write.Token_Tape
	if write.token_tape_start(&tt, false, 0, alloc) != nil {
		return false
	}
	defer write.token_tape_drop(&tt)
	_ = write.token_tape_take(&tt, .Array, "")
	for po in patch.ops {
		_ = write.token_tape_take(&tt, .Object, "")
		_ = write.token_tape_take(&tt, .Key, "op")
		_ = write.token_tape_take(&tt, .String, "remove" if po.op == .Remove else "replace" if po.op == .Replace else "add")
		_ = write.token_tape_take(&tt, .Key, "path")
		_ = write.token_tape_take(&tt, .String, po.path)
		if po.op != .Remove {
			_ = write.token_tape_take(&tt, .Key, "value")
			if po.doc != nil && po.node != tape.NO_NODE {
				_ = write.tokens_of(po.doc, po.node, &tt, write.token_tape_take, alloc)
			} else if po.doc != nil && len(po.nodes) > 0 {
				_ = write.token_tape_take(&tt, .Array, "")
				for n in po.nodes {
					_ = write.tokens_of(po.doc, n, &tt, write.token_tape_take, alloc)
				}
				_ = write.token_tape_take(&tt, .Close, "")
			} else {
				_ = write.token_tape_take(&tt, .Null, "")
			}
		}
		_ = write.token_tape_take(&tt, .Close, "")
	}
	_ = write.token_tape_take(&tt, .Close, "")
	if doc, derr := write.token_tape_document(&tt); derr == nil {
		return write_doc_line(osink, &doc, engine.spec_of_id(.Json), {indent = 2}, alloc)
	}
	return false
}

@(private = "file")
node_json_text :: proc(doc: ^tape.Document, node: tape.Node_Index, fallback: string, alloc: runtime.Allocator) -> (string, bool) {
	if doc == nil || node == tape.NO_NODE {
		return fallback if fallback != "" else "null", false
	}
	if txt, _, werr := engine.write(doc, engine.spec_of_id(.Json), {node = node}, alloc); werr == nil {
		return string(txt), true
	}
	return "null", false
}

@(private = "file")
print_diff_changes :: proc(osink: ^Out_Stream, doc_a, doc_b: ^tape.Document, changes: []diff.Change, as_json: bool, file: string, alloc: runtime.Allocator) -> bool {
	sb := strings.builder_make(alloc)
	defer strings.builder_destroy(&sb)
	if file != "" && len(changes) > 0 && !as_json {
		fmt.sbprintf(&sb, "--- %s\n", file)
		if !out_stream_write(osink, transmute([]u8)strings.to_string(sb)) {
			return false
		}
	}
	for c in changes {
		strings.builder_reset(&sb)
		ot, ow := c.old_text, false
		nt, nw := c.new_text, false
		if c.op != .Fact {
			if c.op != .Added {
				ot, ow = node_json_text(doc_a, c.old_node, c.old_text, alloc)
			}
			if c.op != .Removed {
				nt, nw = node_json_text(doc_b, c.new_node, c.new_text, alloc)
			}
		}
		defer {
			if ow {
				delete(ot, alloc)
			}
			if nw {
				delete(nt, alloc)
			}
		}
		if as_json {
			strings.write_string(&sb, `{"path":`)
			write_steps(&sb, c.path, true)
			fmt.sbprintf(&sb, ",\"op\":\"%s\"", DIFF_OP_NAMES[c.op])
			if c.op != .Added {
				if c.op == .Fact {
					fmt.sbprintf(&sb, ",\"old\":%q", ot)
				} else {
					fmt.sbprintf(&sb, ",\"old\":%s", ot if ot != "" else "null")
				}
			}
			if c.op != .Removed {
				if c.op == .Fact {
					fmt.sbprintf(&sb, ",\"new\":%q", nt)
				} else {
					fmt.sbprintf(&sb, ",\"new\":%s", nt if nt != "" else "null")
				}
			}
			strings.write_string(&sb, "}\n")
		} else {
			fmt.sbprintf(&sb, "%c ", '+' if c.op == .Added else '-' if c.op == .Removed else '~')
			write_steps(&sb, c.path, false)
			switch c.op {
			case .Added:
				fmt.sbprintf(&sb, ": %s\n", nt)
			case .Removed:
				fmt.sbprintf(&sb, ": %s\n", ot)
			case .Changed, .Fact:
				fmt.sbprintf(&sb, ": %s -> %s\n", ot, nt)
			}
		}
		if !out_stream_write(osink, transmute([]u8)strings.to_string(sb)) {
			return false
		}
	}
	return true
}

@(private = "file")
write_steps :: proc(sb: ^strings.Builder, steps: []tape.Step, as_json: bool) {
	if as_json {
		strings.write_byte(sb, '[')
	} else {
		strings.write_byte(sb, '.')
	}
	for s, i in steps {
		if as_json && i > 0 {
			strings.write_byte(sb, ',')
		}
		if v, ok := s.(tape.Name); ok {
			fmt.sbprintf(sb, "%q" if as_json else (".%s" if i > 0 else "%s"), string(v))
		} else if iv, iok := s.(tape.Index); iok {
			fmt.sbprintf(sb, "%d" if as_json else "[%d]", int(iv))
		} else if as_json {
			strings.write_string(sb, "null")
		}
	}
	if as_json {
		strings.write_byte(sb, ']')
	}
}

@(private = "file")
report_schema_compare :: proc(o: ^Options, old, new: ^rules.Description, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	c, err := schema.compare(old, new, {format_assert = o.format_assert}, alloc)
	if err != nil {
		fmt.wprintln(stderr_w, "stury: error: out of memory")
		return EXIT_RUNTIME
	}
	defer schema.comparison_destroy(&c)

	sb := strings.builder_make(alloc)
	defer strings.builder_destroy(&sb)
	for ch in c.changes {
		strings.builder_reset(&sb)
		os_txt, ns_txt := "none", "none"
		os_own, ns_own := false, false
		if ov, ok := ch.old.?; ok {
			if jb, jok := schema.value_to_json(ov, 0, false, alloc, alloc); jok {
				os_txt, os_own = string(jb), true
			}
		}
		if nv, ok := ch.new.?; ok {
			if jb, jok := schema.value_to_json(nv, 0, false, alloc, alloc); jok {
				ns_txt, ns_own = string(jb), true
			}
		}
		if o.diff_json {
			strings.write_string(&sb, `{"path":`)
			write_steps(&sb, ch.path, true)
			fmt.sbprintf(&sb, ",\"keyword\":%q", ch.keyword)
			if os_own {
				fmt.sbprintf(&sb, ",\"old\":%s", os_txt)
			}
			if ns_own {
				fmt.sbprintf(&sb, ",\"new\":%s", ns_txt)
			}
			fmt.sbprintf(&sb, ",\"effect\":\"%v\"}\n", ch.effect)
		} else {
			write_steps(&sb, ch.path, false)
			fmt.sbprintf(&sb, "  %s: %s -> %s  %v\n", ch.keyword, os_txt, ns_txt, ch.effect)
		}
		if os_own {
			delete(os_txt, alloc)
		}
		if ns_own {
			delete(ns_txt, alloc)
		}
		if !out_stream_write(osink, transmute([]u8)strings.to_string(sb)) {
			return EXIT_USAGE
		}
	}
	if !print_inclusion(osink, &sb, o.diff_json, "backward", c.old_in_new, "old", "new") ||
	   !print_inclusion(osink, &sb, o.diff_json, "forward", c.new_in_old, "new", "old") {
		return EXIT_USAGE
	}
	proven := c.old_in_new.verdict == .Yes && c.new_in_old.verdict == .Yes
	switch o.compat {
	case .None:
		return EXIT_OK if (proven && len(c.changes) == 0) else EXIT_FALSY
	case .Backward:
		return EXIT_OK if c.old_in_new.verdict == .Yes else EXIT_FALSY
	case .Forward:
		return EXIT_OK if c.new_in_old.verdict == .Yes else EXIT_FALSY
	case .Full:
		return EXIT_OK if proven else EXIT_FALSY
	}
	return EXIT_FALSY
}

@(private = "file")
print_inclusion :: proc(osink: ^Out_Stream, sb: ^strings.Builder, as_json: bool, name: string, inc: schema.Inclusion, from, to: string) -> bool {
	strings.builder_reset(sb)
	if as_json {
		fmt.sbprintf(sb, "{{\"%s\":{{\"verdict\":\"%v\"", name, inc.verdict)
		if inc.witness != "" {
			fmt.sbprintf(sb, ",\"witness\":%s", inc.witness)
		}
		if inc.reason != "" {
			fmt.sbprintf(sb, ",\"reason\":%q", inc.reason)
		}
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
infer_one_desc :: proc(o: ^Options, path: string, stdin_override: Maybe([]u8), runner: ^tape.Runner, stderr_w: io.Writer, alloc: runtime.Allocator) -> (rules.Description, int) {
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
	if !rok {
		return EXIT_USAGE
	}
	defer if owned {
		delete(src, alloc)
	}
	display := "<stdin>" if path == "-" else path
	sp, fr := verb_file_spec(o, path)
	ro := verb_read_opts(o, sp, runner)
	if se, ok_e := engine.entry_of_spec(sp); ok_e && !se.tabular && (fr == .Lines || fr == .Seq) {
		it, ok := rec_loop_open(src, sp, fr, ro, false, display, stderr_w, alloc)
		if !ok {
			return EXIT_RUNTIME
		}
		defer rec_loop_close(&it)
		for rec, rinfo, err in rec_loop_next(&it) {
			if err != nil {
				_ = print_tape_error(stderr_w, display, err, src, sp)
				return EXIT_RUNTIME
			}
			doc, berr := engine.build(rec, sp, ro, alloc)
			if berr != nil {
				_ = print_tape_error(stderr_w, display, berr, rec, sp, false, src, rinfo.lo)
				return EXIT_RUNTIME
			}
			ierr := schema.infer_document(inf, &doc, tape.ROOT, alloc)
			tape.destroy_document(&doc)
			if ierr != nil {
				return EXIT_RUNTIME
			}
		}
		return EXIT_OK if it.tail_err == nil else EXIT_RUNTIME
	}
	doc, berr := engine.build(src, sp, ro, alloc)
	if berr != nil {
		_ = print_tape_error(stderr_w, display, berr, src, sp)
		return EXIT_RUNTIME
	}
	defer tape.destroy_document(&doc)
	return EXIT_OK if schema.infer_document(inf, &doc, tape.ROOT, alloc) == nil else EXIT_RUNTIME
}

@(private = "file")
emit_schema_text :: proc(osink: ^Out_Stream, txt: []u8, o: ^Options, ind: i8, alloc: runtime.Allocator) -> (formatted_ok: bool, io_ok: bool) {
	if o.to_render != .None {
		doc, berr := engine.build(txt, engine.spec_of_id(.Json), {}, alloc)
		if berr != nil {
			return false, true
		}
		defer tape.destroy_document(&doc)
		ft, werr := write_doc_render(&doc, o.to_render, o.sort_keys, o.compact, o.dsv_out.no_header, tape.ROOT, alloc)
		if werr != nil {
			return false, true
		}
		defer delete(ft, alloc)
		return true, out_stream_bytes_nl(osink, ft)
	}
	if o.has_to && o.to_name != "json" {
		ft, _, ferr := engine.format(txt, engine.spec_of_id(.Json), o.to_spec, {}, make_write_opts(o, o.to_spec, ind), alloc)
		if ferr != nil {
			return false, true
		}
		defer delete(ft, alloc)
		return true, out_stream_bytes_nl(osink, ft)
	}
	return true, out_stream_bytes_nl(osink, txt)
}

run_schema :: proc(
	o: ^Options,
	stdin_override: Maybe([]u8),
	stdout_w, stderr_w: io.Writer,
	runner: ^tape.Runner,
	alloc: runtime.Allocator,
) -> int {
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
		paths := o.files[:] if len(o.files) > 0 else fb[:]
		for p in paths {
			if code := infer_file_into(&inf, o, p, stdin_override, runner, stderr_w, alloc); code != EXIT_OK {
				return code
			}
		}
		desc, ierr := schema.inferred(&inf, alloc)
		if ierr != nil {
			return EXIT_RUNTIME
		}
		defer rules.description_destroy(&desc)
		wopts := schema.Write_Options{indent = 0 if o.compact else u8(max(o.indent, 0)), tab = o.tab && !o.compact}
		txt, werr := schema.write_schema(&desc, wopts, alloc)
		if werr.kind != .None {
			fmt.wprintf(stderr_w, "stury: error: %s\n", werr.message)
			schema.error_destroy(&werr)
			return EXIT_RUNTIME
		}
		defer delete(txt, alloc)
		fok, iok := emit_schema_text(&osink, txt, o, i8(wopts.indent), alloc)
		if !fok {
			fmt.wprintln(stderr_w, "stury: error formatting inferred schema")
			return EXIT_RUNTIME
		}
		if !iok || !out_stream_flush(&osink) {
			return report_stdout_error(stderr_w, osink.io_err)
		}
		return EXIT_OK
	case .Sample, .Odin:
		spath := o.files[0] if len(o.files) == 1 else o.schema_file
		if spath == "" || len(o.files) > 1 {
			fmt.wprintln(stderr_w, "stury: schema command takes one schema file")
			return EXIT_USAGE
		}
		sc, _, ok := compile_schema_file(o, spath, stderr_w, alloc)
		if !ok {
			return EXIT_USAGE
		}
		defer schema.destroy(sc)

		if o.schema_verb == .Sample {
			SOut :: struct {
				osink: ^Out_Stream,
				o:     ^Options,
				alloc: runtime.Allocator,
			}
			sout := SOut{osink = &osink, o = o, alloc = alloc}
			sopts := schema.Sample_Options{
				seed          = o.seed,
				count         = o.count if o.count > 0 else 1,
				invalid       = o.invalid,
				format_assert = o.format_assert,
				indent        = u8(max(o.indent, 0)) if o.indent_set && !o.compact else 0,
				tab           = o.tab && !o.compact,
			}
			serr := schema.sample_each(sc.description, sopts, proc(text: []u8, user: rawptr) {
				so := (^SOut)(user)
				if so.osink.failed {
					return
				}
				fok, iok := emit_schema_text(so.osink, text, so.o, so.o.indent if so.o.indent_set else 0, so.alloc)
				if !fok {
					_ = out_stream_bytes_nl(so.osink, text)
				} else {
					_ = iok
				}
			}, &sout, alloc)
			if osink.failed || !out_stream_flush(&osink) {
				return report_stdout_error(stderr_w, osink.io_err)
			}
			if serr.kind != .None {
				fmt.wprintf(stderr_w, "stury: error: schema sample %s: %s\n", spath, serr.message)
				schema.error_destroy(&serr)
				return EXIT_FALSY
			}
			return EXIT_OK
		}
		pkg := strings.clone(o.schema_package, alloc) if o.schema_package != "" else strings.to_snake_case(filepath.short_stem(spath), alloc)
		defer delete(pkg, alloc)
		if pkg == "" {
			pkg = strings.clone("schema_types", alloc)
		}
		src, oerr := schema.write_odin(sc.description, pkg, o.format_assert, alloc)
		if oerr.kind != .None {
			fmt.wprintf(stderr_w, "stury: error: schema odin %s: %s\n", spath, oerr.message)
			schema.error_destroy(&oerr)
			return EXIT_FALSY
		}
		defer delete(src, alloc)
		if !out_stream_bytes(&osink, transmute([]u8)src) || !out_stream_flush(&osink) {
			return report_stdout_error(stderr_w, osink.io_err)
		}
		return EXIT_OK
	}
	return EXIT_USAGE
}
