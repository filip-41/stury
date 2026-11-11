package main

// `stury diff` over schemas: two schemas compared, and a schema against the data of one file.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import core "../../core"
import "../../core/rules"
import "../../core/write"
import "../../core/schema"
import json "../../json"
import "jq"
import "message"

// The description that every record of the file `path` passes, or an exit telling why not.
infer_file :: proc(o: ^Opts, src: Source, path: string) -> ^rules.Description {
	return infer_data(o, src, path, operand_bytes(path))
}

// The description that every record of `data`, the bytes of the file `path`, passes, or an exit telling why not.
infer_data :: proc(o: ^Opts, src: Source, path: string, data: []byte) -> ^rules.Description {
	heap := runtime.heap_allocator()
	inf := new(schema.Inferred, heap)
	if !infer_read(inf, src, path, data, o) {
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
			l: Json_Line
			json_line_open(&l)
			json_path(&l, "path", ch.path)
			json_word(&l, "keyword", ch.keyword)
			json_side(&l, "old", ch.old)
			json_side(&l, "new", ch.new)
			json_word(&l, "effect", word(ch.effect))
			json_line_close(&l, &out)
		} else {
			put_path(&out, ch.path)
			fmt.sbprintf(&out, "  %s: %s -> %s  %s\n", ch.keyword, side_text(ch.keyword, ch.old), side_text(ch.keyword, ch.new), word(ch.effect))
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

// One side of a schema change as `--json` writes it: the value, or null for none.
@(private = "file")
json_side :: proc(l: ^Json_Line, name: string, side: Maybe(core.Value)) {
	json_member(l, name, side.? or_else nil)
}

// One side of a schema change as a line tells it: `none`, a word as it is, any other value as JSON. The members of an
// `enum` and a `const` are values, so a string among them is quoted.
@(private = "file")
side_text :: proc(keyword: string, side: Maybe(core.Value)) -> string {
	v, present := side.?
	if !present {
		return "none"
	}
	if s, is_word := v.(string); is_word && !strings.has_suffix(keyword, "enum") && !strings.has_suffix(keyword, "const") {
		return s
	}
	b := strings.builder_make(context.temp_allocator)
	put_value(&b, v)
	return strings.to_string(b)
}

// Tells whether the schema `from` takes only values `to` takes. `name` is the direction. A witness of the JSON the
// comparison is made in is written as the value it spells.
write_inclusion :: proc(b: ^strings.Builder, as_json: bool, name: string, in_: schema.Inclusion, from, to: string) {
	if as_json {
		l: Json_Line
		json_line_open(&l)
		write.key(&l.t, name)
		write.open_object(&l.t)
		json_word(&l, "verdict", word(in_.verdict))
		if in_.witness != "" {
			write.key(&l.t, "witness")
			witness, fault := jq.build_text(transmute([]u8)in_.witness, json.as(.Json), context.temp_allocator)
			if fault == nil {
				write.value_of(&l.t, core.Node_Ref{&witness, core.ROOT})
			} else {
				write.value_string(&l.t, in_.witness)
			}
		}
		if in_.reason != "" {
			json_word(&l, "reason", in_.reason)
		}
		write.close(&l.t)
		json_line_close(&l, b)
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
	verdict, why := schema_judge(sc, options, file_name(path), data, src, nil)
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
		if ch.keyword != "properties" || ch.old != nil || ch.effect != .Narrows {
			continue
		}
		drifted = true
		if cli.diff.json {
			l: Json_Line
			json_line_open(&l)
			json_path(&l, "path", ch.path)
			write.key(&l.t, "undescribed")
			write.value_bool(&l.t, true)
			json_line_close(&l, &out)
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
