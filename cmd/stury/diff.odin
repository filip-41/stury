package main

// `stury diff` tells what differs between two inputs. Two data files give the changes of their values, path by path.
// `--old-schema S1 --new-schema S2` compares two schemas, and a schema with one data file judges the data against it.
// One line to a change, `--json` writing a record each, and the exit is 0 for none, 1 for a difference, 5 for an
// input that does not parse, 2 for a usage or file error. `edit --diff` previews the value changes of an edit.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"
import core "../../core"
import "../../core/diff"
import "../../core/write"
import "../../core/records"
import json "../../json"
import "jq"
import "message"

Compat :: enum u8 {
	None,
	Backward,
	Forward,
	Full,
}

// The options of `diff`. `flag` is the first one given, which no other command takes.
Diff_Options :: struct {
	flag:                   string,
	json, facts, shape:     bool,
	arrays:                 diff.Arrays,
	keys:                   [dynamic]diff.Key_Rule,
	old_schema, new_schema: string,
	compat:                 Compat,
}

// Takes the diff option `args[i]` and its parameter.
diff_option :: proc(d: ^Diff_Options, args: []string, i: int) {
	a := args[i]
	if d.flag == "" {
		d.flag = a
	}
	switch a {
	case "--json":     d.json = true
	case "--facts":    d.facts = true
	case "--shape":    d.shape = true
	case "--set", "--position":
		if d.arrays != .Sequence && d.arrays != (.Set if a == "--set" else .Position) {
			usage_error("--set and --position are two ways to match elements: give one")
		}
		d.arrays = .Set if a == "--set" else .Position
	case:
		if i + 1 >= len(args) {
			usage_error("%s takes one parameter", a)
		}
		value := args[i + 1]
		switch a {
		case "--old-schema": d.old_schema = value
		case "--new-schema": d.new_schema = value
		case "--compat":
			switch value {
			case "backward": d.compat = .Backward
			case "forward":  d.compat = .Forward
			case "full":     d.compat = .Full
			case:            usage_error("--compat takes backward, forward or full, not %s", value)
			}
		case "--key":
			append(&d.keys, key_rule(value))
		}
	}
}

// `--key MEMBER` for the root array, or `--key PATH=MEMBER` for the array at PATH, which `All` steps run through. A member
// that holds an `=` is given with an empty path, `--key =MEMBER`.
@(private = "file")
key_rule :: proc(spec: string) -> diff.Key_Rule {
	at, member := "", spec
	if eq := strings.index_byte(spec, '='); eq >= 0 {
		at, member = spec[:eq], spec[eq + 1:]
	}
	rule := diff.Key_Rule{member = member}
	if at != "" {
		path, err := core.parse_path(at if at[0] == '.' || at[0] == '[' else strings.concatenate({".", at}, context.temp_allocator), runtime.heap_allocator())
		if err != nil {
			usage_error("--key %s: %s is no path", spec, at)
		}
		rule.at = path.steps
	}
	if member == "" {
		usage_error("--key %s names no member", spec)
	}
	return rule
}

// `stury diff`, which tells the difference and exits.
diff_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	d := &cli.diff
	o := &run.opts
	src := input_source(o, cli.json_reading)
	one_schema := (d.old_schema != "") != (d.new_schema != "")
	two_schemas := d.old_schema != "" && d.new_schema != ""
	judges := cli.schema.file != "" || cli.schema.filter != nil || cli.schema.max_errors != 0
	if judges || (cli.schema.refs != "" || cli.schema.format_assert || cli.schema.draft != nil) && !(one_schema || two_schemas) {
		usage_error("%s has no use with diff: it judges no input and runs no filter, and --old-schema and --new-schema name the schemas it compares", cli.schema.flag)
	}
	if d.arrays != .Sequence && len(d.keys) > 0 {
		usage_error("--key pairs elements by a member, and %s pairs them another way: give one", "--set" if d.arrays == .Set else "--position")
	}
	if d.compat != .None && !(d.shape || two_schemas) {
		usage_error("--compat compares two schemas, --old-schema and --new-schema, or two shapes with --shape")
	}
	if (d.shape || one_schema || two_schemas) && (d.facts || d.arrays != .Sequence || len(d.keys) > 0) {
		usage_error("--facts, --set, --position and --key compare the values of two data files")
	}
	switch {
	case d.shape:
		if len(cli.files) != 2 || one_schema || two_schemas {
			usage_error("--shape compares the shapes of two data files, OLD and NEW")
		}
		compare_report(cli, src, infer_file(o, src, cli.files[0]), infer_file(o, src, cli.files[1]))
	case two_schemas:
		if len(cli.files) > 0 {
			usage_error("--old-schema with --new-schema compares the two schemas and takes no file")
		}
		diff_schemas(cli, src)
	case one_schema:
		if len(cli.files) != 1 {
			usage_error("a schema and one data file are compared: %s takes one file", d.flag)
		}
		diff_contract(o, cli, src)
	case len(cli.files) != 2:
		usage_error("diff takes two files, OLD and NEW")
	case cli.files[0] == "-" && cli.files[1] == "-":
		usage_error("diff reads standard input once, and - names it twice")
	}
	a, b := read_operand(o, src, cli.files[0]), read_operand(o, src, cli.files[1])
	r, err := diff.values(core.Node_Ref{&a, core.ROOT}, core.Node_Ref{&b, core.ROOT}, diff_options(d))
	if err != nil {
		out_of_memory()
	}
	for unused in r.unused_keys {
		usage_error("--key %s matches no array in both files; a bare MEMBER keys the root array, and PATH=MEMBER the array at PATH", d.keys[unused].member)
	}
	out := strings.builder_make(runtime.heap_allocator())
	write_value_changes(&out, d.json, r.changes, "")
	flush_out(&out, true)
	if r.truncated {
		message.write_stderr("stury: an array differs by more edits than are told, and is reported as replaced\n")
	}
	os.exit(1 if len(r.changes) > 0 else 0)
}

out_of_memory :: proc() -> ! {
	message.write_stderr("stury: error: out of memory\n")
	os.exit(EXIT_INPUT)
}

@(private = "file")
diff_options :: proc(d: ^Diff_Options) -> diff.Options {
	return {arrays = d.arrays, keys = d.keys[:], facts = d.facts}
}

// Writes what `b` holds when it is large or `all` is set, so the output never waits on the whole diff.
flush_out :: proc(b: ^strings.Builder, all: bool) {
	if all || len(b.buf) >= 1 << 16 {
		write_out(b.buf[:])
		clear(&b.buf)
	}
}

// The bytes of the file `path`, or an exit telling why not.
operand_bytes :: proc(path: string) -> []byte {
	f, opened := open_file(path)
	if !opened {
		os.exit(EXIT_USAGE)
	}
	data, read := read_file(f)
	if !read {
		os.exit(EXIT_USAGE)
	}
	return data
}

// Tells the fault `bad` of the file `path`, whose bytes are `data`, as `check` tells it.
tell_operand_fault :: proc(o: ^Opts, src: Source, path: string, data: []byte, bad: core.Fault) {
	name := file_name(path)
	message.write_stderr("stury: parse error: %s\n%s", fault_told(name, data, bad), fault_note(name, data, bad, src.spec, o))
}

// Exits telling the first fault of `data`, the file `path`, read as the records of `src`.
exit_on_fault :: proc(o: ^Opts, src: Source, path: string, data: []byte) {
	if bad, is_fault := first_fault(data, src.as, src.framing, nil, 0).?; is_fault {
		tell_operand_fault(o, src, path, data, bad)
		os.exit(EXIT_INPUT)
	}
}

// The records of `data` as the text of one JSON array, which is how a value sees them.
@(private = "file")
records_array :: proc(data: []byte, src: Source) -> []byte {
	heap := runtime.heap_allocator()
	text := make([dynamic]byte, heap)
	append(&text, '[')
	it := records.open(data, src.as, src.framing, allocator = heap)
	defer records.close(&it)
	for rec in records.next(&it) {
		if len(text) > 1 {
			append(&text, ',')
		}
		append(&text, ..rec.text)
	}
	append(&text, ']')
	return text[:]
}

// Whether the operands of the source are records, which make one array, and not a text each.
@(private = "file")
by_records :: proc(src: Source) -> bool {
	return src.framing != .Concatenated && !table_source(src)
}

// The document of the file `path`, or an exit telling why not. A file of records is one array of them, and so is a
// concatenated text that is not one value, which every other command reads value by value.
@(private = "file")
read_operand :: proc(o: ^Opts, src: Source, path: string) -> core.Document {
	data := operand_bytes(path)
	if msg := blank_told(file_name(path), data, src, o); msg != "" {
		message.write_stderr("stury: parse error: %s", msg)
		os.exit(EXIT_INPUT)
	}
	text := data
	if by_records(src) {
		exit_on_fault(o, src, path, data)
		text = records_array(data, src)
	}
	heap := runtime.heap_allocator()
	doc, fault := jq.build_text(text, src.as, heap)
	if _, is_fault := fault.?; is_fault && src.framing == .Concatenated && !table_source(src) {
		exit_on_fault(o, src, path, data)
		doc, fault = jq.build_text(records_array(data, src), src.as, heap)
	}
	if bad, is_fault := fault.?; is_fault {
		tell_operand_fault(o, src, path, data, bad)
		os.exit(EXIT_INPUT)
	}
	return doc
}

// Writes `v` as JSON.
put_value :: proc(b: ^strings.Builder, v: core.Value) {
	heap := runtime.heap_allocator()
	text, err := write.write_value(v, json.as(.Json), allocator = heap)
	if err != nil {
		out_of_memory()
	}
	defer delete(text, heap)
	strings.write_string(b, string(text))
}

// The name of the enum value `e` in lower case.
word :: proc(e: $T) -> string {
	return strings.to_lower(reflect.enum_string(e), context.temp_allocator)
}

put_path :: proc(b: ^strings.Builder, steps: []core.Step) {
	if len(steps) == 0 {
		strings.write_byte(b, '.')
	}
	core.write_steps(strings.to_writer(b), steps, true)
}

// A line of `--json`: one compact object, made member by member and then added to the output with its newline.
Json_Line :: struct {
	t: write.Tokens,
}

json_line_open :: proc(l: ^Json_Line) {
	write.tokens_init(&l.t, json.as(.Json), {}, runtime.heap_allocator())
	write.open_object(&l.t)
}

json_line_close :: proc(l: ^Json_Line, b: ^strings.Builder) {
	write.close(&l.t)
	text, err := write.tokens_finish(&l.t)
	if err.kind != .None {
		out_of_memory()
	}
	defer delete(text, runtime.heap_allocator())
	strings.write_string(b, string(text))
	strings.write_byte(b, '\n')
}

json_member :: proc(l: ^Json_Line, name: string, v: core.Value) {
	write.key(&l.t, name)
	write.value_of(&l.t, v)
}

json_word :: proc(l: ^Json_Line, name, text: string) {
	write.key(&l.t, name)
	write.value_string(&l.t, text)
}

// Writes the member `name` as the steps in the form `getpath` takes, null for a step that stands for every element.
json_path :: proc(l: ^Json_Line, name: string, steps: []core.Step) {
	write.key(&l.t, name)
	write.open_array(&l.t)
	for s in steps {
		#partial switch v in s {
		case core.Name:  write.value_string(&l.t, string(v))
		case core.Index: write.value_int(&l.t, i64(v))
		case:            write.value_null(&l.t)
		}
	}
	write.close(&l.t)
}

@(private = "file", rodata)
OP_MARKS := [diff.Op]u8{.Added = '+', .Removed = '-', .Changed = '~', .Fact = '~'}

// Writes `changes`, a line each or a record each under `--json`, after the `--- file` line when `file` is not "". The
// output goes out as it fills.
@(private = "file")
write_value_changes :: proc(b: ^strings.Builder, as_json: bool, changes: []diff.Change, file: string) {
	if file != "" && len(changes) > 0 && !as_json {
		fmt.sbprintf(b, "--- %s\n", file)
	}
	for c in changes {
		was := c.op != .Added && c.op != .Removed && !slice.equal(c.path, c.old_path)
		if as_json {
			l: Json_Line
			json_line_open(&l)
			json_path(&l, "path", c.path)
			if was {
				json_path(&l, "old_path", c.old_path)
			}
			json_word(&l, "op", word(c.op))
			if c.op == .Fact {
				json_word(&l, "role", word(c.role))
			}
			if c.op != .Added {
				json_member(&l, "old", c.old)
			}
			if c.op != .Removed {
				json_member(&l, "new", c.new)
			}
			if file != "" {
				json_word(&l, "file", file)
			}
			json_line_close(&l, b)
			flush_out(b, false)
			continue
		}
		strings.write_byte(b, OP_MARKS[c.op])
		strings.write_byte(b, ' ')
		put_path(b, c.path)
		switch c.op {
		case .Added:
			strings.write_string(b, ": ")
			put_value(b, c.new)
		case .Removed:
			strings.write_string(b, ": ")
			put_value(b, c.old)
		case .Changed, .Fact:
			if c.op == .Fact {
				fmt.sbprintf(b, " @%s", word(c.role))
			}
			strings.write_string(b, ": ")
			put_value(b, c.old)
			strings.write_string(b, " -> ")
			put_value(b, c.new)
		}
		if c.kind_changed {
			fmt.sbprintf(b, "  (%s -> %s)", jq.type_name(c.old), jq.type_name(c.new))
		}
		if was {
			strings.write_string(b, "  (was ")
			put_path(b, c.old_path)
			strings.write_byte(b, ')')
		}
		strings.write_byte(b, '\n')
		flush_out(b, false)
	}
}

// `edit --diff`: the value changes the edit makes of `src`, told under a `--- path` line.
diff_preview :: proc(run: ^Run, path: string, src, out: []u8) -> bool {
	as := input_source(&run.opts, run.ip.reading).as
	heap := runtime.heap_allocator()
	a, a_fault := jq.build_text(src, as, heap)
	b, b_fault := jq.build_text(out, as, heap)
	if a_fault != nil || b_fault != nil {
		message.write_stderr("stury: error: %s: --diff compares whole documents, which this input is not\n", file_name(path))
		return false
	}
	defer core.destroy(&a)
	defer core.destroy(&b)
	r, err := diff.values(core.Node_Ref{&a, core.ROOT}, core.Node_Ref{&b, core.ROOT})
	if err != nil {
		out_of_memory()
	}
	defer diff.result_destroy(&r)
	sb := strings.builder_make(heap)
	defer strings.builder_destroy(&sb)
	write_value_changes(&sb, false, r.changes, file_name(path))
	flush_out(&sb, true)
	return true
}
