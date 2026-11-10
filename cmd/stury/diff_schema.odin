package main

// `stury diff` over schemas: two schemas compared, and a schema against the data of one file.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "../../core/rules"
import "../../core/schema"
import "message"

// The description that every record of the file `path` passes, or an exit telling why not.
infer_file :: proc(o: ^Opts, src: Source, path: string) -> ^rules.Description {
	return infer_data(o, src, path, operand_bytes(path))
}

// The description that every record of `data`, the bytes of the file `path`, passes, or an exit telling why not.
infer_data :: proc(o: ^Opts, src: Source, path: string, data: []byte) -> ^rules.Description {
	heap := runtime.heap_allocator()
	inf := new(schema.Inferred, heap)
	if !infer_read(inf, src, path, data, told_by = o) {
		os.exit(EXIT_INPUT)
	}
	d, derr := schema.inferred(inf, heap)
	if derr != nil {
		out_of_memory()
	}
	out := new(rules.Description, heap)
	out^ = d
	return out
}

// Two schemas compared: the changes, then whether each side takes what the other writes. Exits.
diff_schemas :: proc(cli: ^Cli, src: Source) -> ! {
	d := &cli.diff
	options := cli.schema
	options.file = d.old_schema
	old := schema_read(options, "--old-schema")
	options.file = d.new_schema
	new := schema_read(options, "--new-schema")
	compare_report(cli, src, old.compiled.description, new.compiled.description)
}

// Compares the descriptions `old` and `new` and tells the changes, then whether each side takes what the other writes.
compare_report :: proc(cli: ^Cli, src: Source, old, new: ^rules.Description) -> ! {
	d := &cli.diff
	c, err := schema.compare(old, new, {as = src.as, reads = checks_of(src.as, src.spec == nil), format_assert = cli.schema.format_assert})
	if err != nil {
		out_of_memory()
	}
	out := strings.builder_make(runtime.heap_allocator())
	for ch in c.changes {
		if d.json {
			strings.write_string(&out, `{"path":`)
			put_path_array(&out, ch.path)
			put_field(&out, "keyword", ch.keyword)
			put_field(&out, "old", ch.old)
			put_field(&out, "new", ch.new)
			fmt.sbprintf(&out, `,"effect":"%s"}}`+"\n", word(ch.effect))
		} else {
			put_path(&out, ch.path)
			fmt.sbprintf(&out, "  %s: %s -> %s  %s\n", ch.keyword, ch.old if ch.old != "" else "none", ch.new if ch.new != "" else "none", word(ch.effect))
		}
		flush_out(&out, false)
	}
	if c.truncated {
		message.write_stderr("stury: the comparison reached its bound, so the changes may be missing some and are not all proven\n")
	}
	write_inclusion(&out, d.json, "backward", c.old_in_new, "old", "new")
	write_inclusion(&out, d.json, "forward", c.new_in_old, "new", "old")
	flush_out(&out, true)
	proven := c.old_in_new.verdict == .Yes && c.new_in_old.verdict == .Yes
	switch d.compat {
	case .None:     os.exit(0 if proven && len(c.changes) == 0 else 1)
	case .Backward: os.exit(0 if c.old_in_new.verdict == .Yes else 1)
	case .Forward:  os.exit(0 if c.new_in_old.verdict == .Yes else 1)
	case .Full:     os.exit(0 if proven else 1)
	}
	os.exit(1)
}

// Tells whether the schema `from` takes only values `to` takes. `name` is the direction.
write_inclusion :: proc(b: ^strings.Builder, as_json: bool, name: string, in_: schema.Inclusion, from, to: string) {
	if as_json {
		fmt.sbprintf(b, `{{"%s":{{"verdict":"%s"`, name, word(in_.verdict))
		if in_.witness != "" {
			put_field(b, "witness", in_.witness)
		}
		if in_.reason != "" {
			put_field(b, "reason", in_.reason)
		}
		strings.write_string(b, "}}\n")
		return
	}
	fmt.sbprintf(b, "%s: %s", name, word(in_.verdict))
	switch in_.verdict {
	case .No:      fmt.sbprintf(b, ", %s passes the %s schema and fails the %s one", in_.witness, from, to)
	case .Unknown: fmt.sbprintf(b, ", not proven at %s", in_.reason)
	case .Yes:
	}
	strings.write_byte(b, '\n')
}

// A schema and a data file: the data is judged by the schema, as `check --schema` judges it, and the members it has
// that the schema does not describe are told, one place a line. Exits.
diff_contract :: proc(o: ^Opts, cli: ^Cli, src: Source) -> ! {
	options := cli.schema
	flag := "--old-schema" if cli.diff.old_schema != "" else "--new-schema"
	options.file = cli.diff.old_schema if cli.diff.old_schema != "" else cli.diff.new_schema
	sc := schema_open(options, src, flag)
	path := cli.files[0]
	data := operand_bytes(path)
	verdict, why := schema_judge(sc, options, file_name(path), false, data, src, nil)
	switch verdict {
	case .Refused: os.exit(EXIT_USAGE)
	case .Fault:
		exit_on_fault(o, src, path, data)
		message.write_stderr("stury: parse error: %s: %s\n", file_name(path), edit_error_text(data, why))
		os.exit(EXIT_INPUT)
	case .Valid, .Invalid:
	}
	seen := infer_data(o, src, path, data)
	c, err := schema.compare(sc.compiled.description, seen, {as = src.as, reads = checks_of(src.as, src.spec == nil), format_assert = cli.schema.format_assert})
	if err != nil {
		out_of_memory()
	}
	out := strings.builder_make(runtime.heap_allocator())
	drifted := false
	for ch in c.changes {
		// Only a member that no keyword of the schema takes up is undescribed: where a pattern may describe it the effect is unknown.
		if ch.keyword != "properties" || ch.old != "" || ch.effect != .Narrows {
			continue
		}
		drifted = true
		if cli.diff.json {
			strings.write_string(&out, `{"path":`)
			put_path_array(&out, ch.path)
			strings.write_string(&out, ",\"undescribed\":true}\n")
		} else {
			strings.write_string(&out, "+ ")
			put_path(&out, ch.path)
			strings.write_string(&out, "  not described by the schema\n")
		}
		flush_out(&out, false)
	}
	flush_out(&out, true)
	os.exit(1 if verdict == .Invalid || drifted else 0)
}
