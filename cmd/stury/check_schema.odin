package main

// `stury check --schema` judges each input against a JSON Schema as well as for faults. The schema is read, compiled and
// bound once. A text is checked on the pool when it is long, a failure is told as `file:line:col: message at path`, or
// written as the basic output or a problem document on standard output. A text that does not parse is the plain
// check's fault, told as it tells it.

import "base:runtime"
import "core:os"
import "core:strings"
import core "../../core"
import "../../core/typed"
import "../../core/write"
import "../../core/schema"
import json "../../json"

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

Verdict :: enum {
	Valid,
	Invalid,
	Fault,
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
schema_open :: proc(s: Schema_Options, src: Source) -> ^Schema_Check {
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
		usage_error("--schema %s: %s", s.file, edit_error_text(sc.text, err))
	}
	opts := schema.Options {
		format_assert = s.format_assert,
		resolver = {root = s.refs, as = json.as(.Json)},
	}
	if sc.compiled, err = schema.compile(&sc.doc, core.ROOT, opts); err != nil {
		usage_error("--schema %s: %s", s.file, edit_error_text(sc.text, err))
	}
	if sc.bound, err = schema.bind(&sc.compiled, src.as); err != nil {
		usage_error("--schema %s: %s", s.file, edit_error_text(sc.text, err))
	}
	return sc
}

// Judges `data`, the file `name`, against the schema and tells what it finds. A fault is left for `check_text` to tell.
schema_judge :: proc(sc: ^Schema_Check, s: Schema_Options, name: string, data: []byte, src: Source, runner: ^core.Runner) -> Verdict {
	sink := typed.Sink {
		max_errors = s.max_errors,
		entries    = make([dynamic]core.Error_Entry, runtime.heap_allocator()),
	}
	defer typed.sink_destroy(&sink)
	by_record := src.framing != .Concatenated
	err := schema.check_records(&sc.bound, data, src.framing, &sink, runner) if by_record else schema.check(&sc.bound, data, &sink, runner)
	if err == nil {
		if s.report == .Basic {
			report(sc, s, sink.entries[:], false)
		}
		return .Valid
	}
	for e in sink.entries {
		if e.kind == .Walk {
			return .Fault
		}
	}
	if len(sink.entries) == 0 {
		return .Fault
	}
	if s.report == .Lines {
		told(name, data, sink.entries[:])
	} else {
		report(sc, s, sink.entries[:], by_record, sink.truncated)
	}
	return .Invalid
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
report :: proc(sc: ^Schema_Check, s: Schema_Options, entries: []core.Error_Entry, records: bool, truncated := false) {
	t: write.Tokens
	write.tokens_init(&t, json.as(.Json), {}, context.temp_allocator)
	r := write.Report{uri = sc.compiled.description.uri, records = records, truncated = truncated}
	if s.report == .Basic {
		write.write_basic(&t, entries, r)
	} else {
		write.write_problem(&t, entries, {title = "Invalid input", status = 422}, r)
	}
	text, _ := write.tokens_finish(&t)
	os.write(os.stdout, text)
	os.write_string(os.stdout, "\n")
}
