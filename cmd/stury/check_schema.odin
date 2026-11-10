package main

// `stury check --schema` judges each input against a JSON Schema as well as for faults. The schema is read, compiled and
// bound once. A text is checked on the pool when it is long, a failure is told as `file:line:col: message at path`, or
// written as the basic output or a problem document on standard output. A text that does not parse is the plain
// check's fault, told as it tells it.

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import core "../../core"
import "../../core/typed"
import "../../core/write"
import "../../core/schema"
import json "../../json"
import "message"

Report_Kind :: enum {
	Lines,
	Basic,
	Problem,
}

// The options of `check` that name a schema. `flag` is the first one given.
Schema_Options :: struct {
	flag:          string,
	file:          string,
	refs:          string,
	max_errors:    int,
	report:        Report_Kind,
	format_assert: bool,
}

// A schema compiled and bound to the format the inputs are read as. `doc` is the schema's text, which `compiled` borrows.
Schema_Check :: struct {
	doc:      core.Document,
	text:     []byte,
	compiled: schema.Compiled,
	bound:    schema.Bound,
}

// What a schema check of one input found. A fault is the plain check's to tell, and a refusal is anything else that
// stopped the check without a failure to tell.
Verdict :: enum {
	Valid,
	Invalid,
	Fault,
	Refused,
}

// Takes the schema option `args[i]` and its parameter.
schema_option :: proc(s: ^Schema_Options, args: []string, i: int) {
	a := args[i]
	if s.flag == "" {
		s.flag = a
	}
	if a == "--format-assert" {
		s.format_assert = true
		return
	}
	if i + 1 >= len(args) {
		usage_error("%s takes one parameter", a)
	}
	value := args[i + 1]
	switch a {
	case "--schema":
		s.file = value
	case "--schema-ref":
		s.refs = value
	case "--max-errors":
		n, ok := parse_digits(value, 1 << 31)
		if !ok || n < 1 {
			usage_error("--max-errors takes a number from 1")
		}
		s.max_errors = int(n)
	case "--report":
		switch value {
		case "lines":   s.report = .Lines
		case "basic":   s.report = .Basic
		case "problem": s.report = .Problem
		case:
			usage_error("--report takes lines, basic or problem, not %s", value)
		}
	}
}

// The schema `s` names, read, compiled and bound to the inputs' format, or a usage error telling why not.
schema_open :: proc(s: Schema_Options, src: Source, option := "--schema") -> ^Schema_Check {
	sc := schema_read(s, option)
	err: core.Error
	if sc.bound, err = schema.bind(&sc.compiled, src.as); err != nil {
		usage_error("%s %s: %s", option, s.file, edit_error_text(sc.text, err))
	}
	return sc
}

// The schema `s` names, read and compiled but not bound, or a usage error telling why not under the name `option`.
schema_read :: proc(s: Schema_Options, option := "--schema") -> ^Schema_Check {
	if s.file == "" {
		usage_error("%s needs --schema", s.flag)
	}
	f, opened := open_file(s.file, "check")
	if !opened {
		os.exit(EXIT_USAGE)
	}
	sc := new(Schema_Check, runtime.heap_allocator())
	read: bool
	if sc.text, read = read_file(f); !read {
		os.exit(EXIT_USAGE)
	}
	err: core.Error
	sc.doc, err = core.build(sc.text, json.as(.Json))
	if err != nil {
		usage_error("%s %s: %s", option, s.file, edit_error_text(sc.text, err))
	}
	refs := s.refs if s.refs != "" else filepath.dir(s.file)
	opts := schema.Options {
		format_assert = s.format_assert,
		resolver = {root = refs, as = json.as(.Json)},
	}
	if sc.compiled, err = schema.compile(&sc.doc, core.ROOT, opts); err != nil {
		usage_error("%s %s: %s", option, s.file, edit_error_text(sc.text, err))
	}
	return sc
}

// Judges `data`, the file `name`, against the schema and tells what it finds. `named` puts the file's name in a report.
// A fault is left for the plain check to tell, and is returned for the case it finds nothing.
schema_judge :: proc(sc: ^Schema_Check, s: Schema_Options, name: string, named: bool, data: []byte, src: Source, runner: ^core.Runner) -> (Verdict, core.Error) {
	sink := typed.Sink {
		max_errors = s.max_errors,
		entries    = make([dynamic]core.Error_Entry, runtime.heap_allocator()),
	}
	defer typed.sink_destroy(&sink)
	records, err := check_input(sc, data, src, runner, &sink)
	by_record := !table_source(src) && (src.framing != .Concatenated || records > 1)
	file := name if named else ""
	#partial switch _ in err {
	case nil:
		if records == 0 {
			return .Fault, nil
		}
		if s.report == .Basic {
			report(sc, s, file, sink.entries[:], false)
		}
		return .Valid, nil
	case core.Fault:
		// The failures of the records before a cut one are told before the fault, which the plain check tells.
		if told_before := failures_before(sink.entries[:]); len(told_before) > 0 && (src.framing != .Concatenated || records > 0) {
			tell(sc, s, name, file, data, told_before, by_record, &sink)
		}
		return .Fault, err
	case core.Typed_Failure:
		if len(sink.entries) > 0 {
			tell(sc, s, name, file, data, sink.entries[:], by_record, &sink)
			return .Invalid, nil
		}
	}
	message.write_stderr("stury: %s: %s\n", name, edit_error_text(data, err))
	return .Refused, err
}

// Whether `src` reads delimited text, whose schema describes the whole table, an array of rows.
table_source :: proc(src: Source) -> bool {
	return src.as.readers != nil && src.as.readers.flat
}

// Checks `data` by its records, or as one text when the framing is concatenated and it is one or the source is a table,
// and returns how many records it read. A concatenated text that does not check as one is read again value by value.
@(private = "file")
check_input :: proc(sc: ^Schema_Check, data: []byte, src: Source, runner: ^core.Runner, sink: ^typed.Sink) -> (records: i64, err: core.Error) {
	if table_source(src) {
		return 1, schema.check(&sc.bound, data, sink, runner)
	}
	if src.framing != .Concatenated {
		return schema.check_records(&sc.bound, data, src.framing, sink, runner)
	}
	err = schema.check(&sc.bound, data, sink, runner)
	if _, parse := err.(core.Fault); !parse {
		return 1, err
	}
	typed.sink_restore(sink, {})
	return schema.check_records(&sc.bound, data, .Concatenated, sink, runner)
}

// The entries of a check that ended on a fault, without the entry that places the fault among them.
@(private = "file")
failures_before :: proc(entries: []core.Error_Entry) -> []core.Error_Entry {
	n := len(entries)
	for n > 0 && entries[n - 1].kind == .Walk {
		n -= 1
	}
	return entries[:n]
}

// Tells `entries` of the file `name` as the report says: lines on standard error, or the basic output or problem document.
@(private = "file")
tell :: proc(sc: ^Schema_Check, s: Schema_Options, name, file: string, data: []byte, entries: []core.Error_Entry, by_record: bool, sink: ^typed.Sink) {
	if s.report == .Lines {
		told(name, data, entries)
		if sink.truncated {
			message.write_stderr("%s: more failures past --max-errors %d\n", name, len(sink.entries))
		}
	} else {
		report(sc, s, file, entries, by_record, sink.truncated)
	}
}

// Tells each entry of the file `name` on standard error, one to a line.
@(private = "file")
told :: proc(name: string, data: []byte, entries: []core.Error_Entry) {
	lines: core.Lines
	b := strings.builder_make(context.temp_allocator)
	for e in entries {
		strings.write_string(&b, name)
		strings.write_byte(&b, ':')
		core.render_entry(strings.to_writer(&b), data, e, &lines)
		strings.write_byte(&b, '\n')
	}
	os.write_string(os.stderr, strings.to_string(b))
}

// Writes the basic output or the problem document of `entries` and a newline to standard output.
@(private = "file")
report :: proc(sc: ^Schema_Check, s: Schema_Options, file: string, entries: []core.Error_Entry, records: bool, truncated := false) {
	t: write.Tokens
	write.tokens_init(&t, json.as(.Json), {}, context.temp_allocator)
	r := write.Report{file = file, records = records, truncated = truncated}
	if s.report == .Basic {
		schema.write_basic(&t, entries, sc.compiled.description.uri, r)
	} else {
		write.write_problem(&t, entries, {title = "Invalid input", status = 422}, r)
	}
	text, _ := write.tokens_finish(&t)
	os.write(os.stdout, text)
	os.write_string(os.stdout, "\n")
}
