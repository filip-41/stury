package main

// The command line read as jq 1.8.2's main.c reads it. A long option stands alone, and one-letter options run
// together (`-nr`), `-L` taking the rest of its argument or the next one. Each option's error is jq's, reported as
// soon as it is read.

import "core:slice"
import "core:strings"
import core "../../core"
import dsv "../../dsv"
import json "../../json"
import "jq"
import "message"

Opts :: struct {
	compact:          bool,
	layout_shown:     bool, // edit: a built value takes the layout of the container it lands in
	indent:           i8, // pretty: N spaces, or -1 for a tab
	raw:              bool,
	join:             bool,
	raw0:             bool, // --raw-output0: a NUL after each output
	ascii:            bool,
	sort_keys:        bool,
	color:            bool, // -C, or stdout a terminal, and no -M
	unbuffered:       bool,
	raw_input:        bool, // -R: each line a string
	from_file:        bool, // -f: FILTER names the file the filter is in
	null_input:       bool,
	slurp:            bool,
	exit_status:      bool,
	seq:              bool, // jq's --seq: texts after record separators, and outputs too
	stream:           bool, // jq's --stream: each input as [path, leaf] events
	stream_errors:    bool, // and an error as a [message, path] event
	from:             Format, // how the input is read
	to:               Format, // how the outputs are written
	grow_header:      bool, // --grow-header: --to csv or tsv holds all rows and writes a header of every key
	cells_in:         dsv.Options, // how a --from csv or tsv text is read
	cells_out:        dsv.Options, // how a --to csv or tsv text is written
	explain:          bool, // --explain: write the filter's plan and what the run did to stderr
	max_depth:        u32, // --max-depth, 0 when it was not given
	in_place:         bool,
	check:            bool,
	follow:           bool, // --follow: the one file is read on as it grows
	diff:             bool, // edit --diff: tell the value changes of the edit
	alias_limit:      u64, // --alias-limit, 0 for the YAML reader's own
	merge_keys:       bool, // --merge-keys
	expansion_limit:  u64, // --expansion-limit, 0 for the XML reader's own
	unread_entities:  bool, // --unread-entities
}

// What the command line gives besides the options.
Cli :: struct {
	validating: bool,
	formatting: bool,
	editing:    bool,
	// `schema`: the verb (`infer` or `sample`) is the first of `files`, and these are its options.
	schema_verb: bool,
	verbs:      Verb_Options,
	diffing:    bool,
	filter:     Maybe(string), // the filter, or under -f the file it is in
	files:      [dynamic]string,
	// --arg, --argjson, --slurpfile and --rawfile, the first of a name standing.
	var_names:  [dynamic]string,
	var_values: [dynamic]jq.Value,
	positional: [dynamic]jq.Value, // --args and --jsonargs
	// How --argjson, --jsonargs, --slurpfile and `fromjson` read their texts, as --from and --max-depth say: as JSON, or
	// the JSON dialect --from names.
	json_reading: core.As,
	binding_flag: string,
	lib_dirs:   Maybe([dynamic]string), // -L's, made real paths
	color_set:  bool, // -C
	mono:       bool, // -M
	compact_given: bool,
	// --from and --to as given on the command line. `parse_args` resolves them into `Opts`.
	formats:    struct {
		from, to: Maybe(Format),
	},
	// The first JSON-output-only option given (-r, -c, --indent...), the first of them that no text of another format
	// takes (-r, --seq, --tab...), and the first JSON layout option given.
	json_flag, text_flag, layout_flag: string,
	// The first option given that reads a delimited text (--delimiter...), and the first that writes one (--crlf...).
	cells_flag, cells_out_flag: string,
	// The option --infer, which types a text value of a delimited text, of XML or of HTML.
	infer_flag: string,
	// The first option given that reads a YAML text (--alias-limit, --merge-keys), and the first that reads an XML
	// text (--expansion-limit, --unread-entities).
	yaml_flag, xml_flag: string,
	out_delimiter, out_comment: Maybe(byte),
	// `check`'s schema options, which `diff` takes too.
	schema: Schema_Options,
	diff:   Diff_Options,
	owned:  [dynamic]string, // the options given that only some commands take, in order
}

// The command line `args` (os.args without the program) into `o`, as jq reads it.
parse_args :: proc(o: ^Opts, args: []string) -> (cli: Cli) {
	args := args
	subcommand := subcommand_index(args)
	if subcommand >= 0 {
		switch args[subcommand] {
		case "fmt":  cli.formatting = true
		case "edit": cli.editing = true
		case "schema": cli.schema_verb = true
		case "diff": cli.diffing = true
		case:        cli.validating = true
		}
	}
	rest_as: enum {
		Files,
		Args,
		Json_Args,
	}
	// --max-depth and the formats are read first, so an earlier --argjson is validated under them too.
	for i := 0; i < len(args) && args[i] != "--"; i += 1 + option_arity(args[i]) {
		format_option(&cli, args, i)
		if args[i] == "--max-depth" && i + 1 < len(args) {
			if n, ok := parse_max_depth(args[i + 1]); ok {
				o.max_depth = u32(n)
			}
		}
	}
	o.from, o.to = cli.formats.from.? or_else .Json, cli.formats.to.? or_else .Json
	cli.json_reading = json.as(FORMATS[o.from].spec, {max_depth = o.max_depth, refuse_non_finite = true})
	args_done := false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if i == subcommand {
			continue
		}
		if args_done || !is_option(a) {
			switch {
			case !cli.validating && !cli.formatting && !cli.schema_verb && !cli.diffing && cli.filter == nil:
				cli.filter = a
			case rest_as == .Args:
				append(&cli.positional, jq.valid_utf8(a))
			case rest_as == .Json_Args:
				append(&cli.positional, json_arg(cli.json_reading, a, "--jsonargs"))
			case:
				append(&cli.files, a)
			}
			continue
		}
		if a == "--" {
			args_done = true
			continue
		}
		if a[1] != '-' {
			i = short_options(o, &cli, args, i)
			continue
		}
		if owned_option(a[2:]) != nil {
			append(&cli.owned, a)
		}
		switch name := a[2:]; name {
		case "tab":
			o.compact, o.indent = false, -1
			note_json_flag(&cli, "--tab", layout = true)
		case "indent":
			if i + 1 >= len(args) {
				usage_error("--indent takes one parameter")
			}
			n, ok := parse_indent(args[i + 1])
			if !ok {
				usage_error("--indent takes a number between -1 and 7")
			}
			o.compact, o.indent = false, n
			note_json_flag(&cli, "--indent", layout = true, laid = true)
			i += option_arity(a)
		case "max-depth":
			if i + 1 >= len(args) {
				usage_error("--max-depth takes one parameter")
			}
			if _, ok := parse_max_depth(args[i + 1]); !ok {
				usage_error("--max-depth takes a number between 1 and %d", DEPTH_CEILING)
			}
			i += option_arity(a)
		case "raw-output0":
			o.raw, o.join, o.raw0 = true, true, true
			note_json_flag(&cli, "--raw-output0")
		case "unbuffered":
			o.unbuffered = true
		case "arg", "argjson", "slurpfile", "rawfile":
			note_binding_flag(&cli, a)
			bind_variable_option(&cli, args, i)
			i += option_arity(a)
		case "args":
			note_binding_flag(&cli, a)
			rest_as = .Args
		case "jsonargs":
			note_binding_flag(&cli, a)
			rest_as = .Json_Args
		case "build-configuration":
			message.write_stdout("%s\n", BUILD_CONFIGURATION)
			exit_closing_stdout(0)
		case "library-path":
			i = lib_dir_arg(&cli, args, i)
		case "from", "to":
			i += option_arity(a)
		case "schema", "schema-ref", "schema-draft", "max-errors", "report", "format-assert", "filter":
			schema_option(&cli.schema, args, i)
			i += option_arity(a)
		case "ranges", "invalid", "comments", "seed", "count", "package":
			verb_option(&cli.verbs, args, i)
			i += option_arity(a)
		case "old-schema", "new-schema", "compat", "key", "set", "position", "facts", "json", "shape":
			diff_option(&cli.diff, args, i)
			i += option_arity(a)
		case "diff":
			o.diff = true
		case "grow-header":
			o.grow_header = true
		case "delimiter", "comment", "out-delimiter", "out-comment":
			if i + 1 >= len(args) {
				usage_error("%s takes one parameter", a)
			}
			c := cell_byte(a, args[i + 1])
			switch name {
			case "delimiter":     o.cells_in.delimiter = c
			case "comment":       o.cells_in.comment = c
			case "out-delimiter": cli.out_delimiter = c
			case "out-comment":   cli.out_comment = c
			}
			note_cells_flag(&cli, a, strings.has_prefix(name, "out-"))
			i += option_arity(a)
		case "no-header", "ragged", "lazy-quotes":
			switch name {
			case "no-header":   o.cells_in.no_header = true
			case "ragged":      o.cells_in.tolerate += {.Ragged}
			case "lazy-quotes": o.cells_in.tolerate += {.Bare_Quote}
			}
			note_cells_flag(&cli, a, false)
		case "infer":
			o.cells_in.infer = true
			cli.infer_flag = a
		case "alias-limit", "expansion-limit":
			if i + 1 >= len(args) {
				usage_error("%s takes one parameter", a)
			}
			n, ok := parse_digits(args[i + 1], 1 << 62)
			if !ok || n < 1 {
				usage_error("%s takes a number of bytes, 1 or more", a)
			}
			if name == "alias-limit" {
				o.alias_limit = n
				note_first(&cli.yaml_flag, a)
			} else {
				o.expansion_limit = n
				note_first(&cli.xml_flag, a)
			}
			i += option_arity(a)
		case "merge-keys":
			o.merge_keys = true
			note_first(&cli.yaml_flag, a)
		case "unread-entities":
			o.unread_entities = true
			note_first(&cli.xml_flag, a)
		case "out-no-header":
			o.cells_out.no_header = true
			note_cells_flag(&cli, a, true)
		case "crlf":
			o.cells_out.crlf = true
			note_cells_flag(&cli, a, true)
		case "explain":
			o.explain = true
		case "follow":
			o.follow = true
		case "in-place":
			o.in_place = true
		case "check":
			o.check = true
		case "seq":
			o.seq = true
			note_json_flag(&cli, "--seq")
		case "stream":
			o.stream = true
		case "stream-errors":
			o.stream, o.stream_errors = true, true
		case:
			c: byte
			for l in LONG_LETTERS {
				if l.name == name {
					c = l.letter
				}
			}
			if c == 0 || !letter_option(o, &cli, c) {
				message.write_stderr("stury: Unknown option %s\n", a)
				die()
			}
		}
	}
	// fmt writes each input as its own format unless --to says otherwise, so its --to follows --from when --to
	// was not given. `--to ndjson` is what sets the compact layout here, since fmt refuses -c.
	if cli.formatting && cli.formats.to == nil {
		o.to = FORMATS[o.from].written_as.? or_else o.from
	}
	if writes_lines(o) {
		o.compact = true
	}
	// A table written in the format read keeps the read's delimiter and headerless rows, and one written from any table
	// keeps the read's comment character and --infer, so it reads back with the same options.
	if o.to == o.from {
		o.cells_out.delimiter = o.cells_in.delimiter
		o.cells_out.no_header ||= o.cells_in.no_header
	}
	if reads_cells(o) && writes_cells(o) {
		o.cells_out.comment, o.cells_out.infer = o.cells_in.comment, o.cells_in.infer
	}
	o.cells_out.delimiter = cli.out_delimiter.? or_else o.cells_out.delimiter
	o.cells_out.comment = cli.out_comment.? or_else o.cells_out.comment
	return
}

// The byte `arg` names for option `flag`: one ASCII character, or `\t` for a tab.
@(private = "file")
cell_byte :: proc(flag, arg: string) -> byte {
	if arg == `\t` {
		return '\t'
	}
	if len(arg) != 1 || arg[0] >= 0x80 {
		usage_error("%s takes one ASCII character, or \\t for a tab, not %q", flag, arg)
	}
	return arg[0]
}

// Records `flag` as the first option that reads a delimited text, or with `out` the first that writes one.
@(private = "file")
note_cells_flag :: proc(cli: ^Cli, flag: string, out: bool) {
	first := &cli.cells_out_flag if out else &cli.cells_flag
	if first^ == "" {
		first^ = flag
	}
}

// Records `flag` in `first` unless an earlier option is there.
@(private = "file")
note_first :: proc(first: ^string, flag: string) {
	if first^ == "" {
		first^ = flag
	}
}

// Records a `--from NAME` or `--to NAME` option at `args[i]` in `cli.formats`. A later one overrides an earlier one.
@(private = "file")
format_option :: proc(cli: ^Cli, args: []string, i: int) {
	a := args[i]
	if a != "--from" && a != "--to" {
		return
	}
	if i + 1 >= len(args) {
		usage_error("%s takes one parameter", a)
	}
	f, ok := format_named(args[i + 1])
	if !ok {
		usage_error("%s takes one of %s, not %q", a, format_names(a == "--to"), args[i + 1])
	}
	if a == "--from" {
		cli.formats.from = f
	} else if FORMATS[f].written_as != nil {
		usage_error("--to does not write %s: --to %s writes its values and comments", args[i + 1], FORMATS[FORMATS[f].written_as.?].name)
	} else {
		cli.formats.to = f
	}
}

// Records `flag` as the first JSON-output-only option, as the first one a format written with a layout of its own
// refuses unless `laid` is set, and as the first layout option when `layout` is set.
@(private = "file")
note_json_flag :: proc(cli: ^Cli, flag: string, layout := false, laid := false) {
	if cli.json_flag == "" {
		cli.json_flag = flag
	}
	if !laid && cli.text_flag == "" {
		cli.text_flag = flag
	}
	if layout && cli.layout_flag == "" {
		cli.layout_flag = flag
	}
}

@(private = "file")
note_binding_flag :: proc(cli: ^Cli, flag: string) {
	if cli.binding_flag == "" {
		cli.binding_flag = flag
	}
}

// The short options in `args[i]` (`-nr`, `-Ldir`, `-L dir`), as `letter_option` reads each letter. Answers the
// index of the last argument they used.
@(private = "file")
short_options :: proc(o: ^Opts, cli: ^Cli, args: []string, i: int) -> int {
	i := i
	a := args[i]
	for j := 1; j < len(a); j += 1 {
		if a[j] == 'L' {
			// -Ldir, or -L dir
			if j + 1 < len(a) {
				add_lib_dir(cli, a[j + 1:])
			} else {
				i = lib_dir_arg(cli, args, i)
			}
			break
		}
		if !letter_option(o, cli, a[j]) {
			message.write_stderr("stury: Unknown option -%s\n", a[j:j + 1])
			die()
		}
	}
	return i
}

// The variable `args[i]` (`--arg`, `--argjson`, `--slurpfile` or `--rawfile`, then a name and a value) binds.
@(private = "file")
bind_variable_option :: proc(cli: ^Cli, args: []string, i: int) {
	a := args[i]
	name := a[2:]
	if i + 2 >= len(args) {
		what := "value" if name == "arg" else "text" if name == "argjson" else "filename"
		usage_error("%s takes two parameters (e.g. %s varname %s)", a, a, what)
	}
	// As jq: a name's first definition stands, and a later one is not read. An --arg value's bytes are
	// a string as jq makes one, with U+FFFD for what is not UTF-8.
	if slice.contains(cli.var_names[:], args[i + 1]) {
		return
	}
	v: jq.Value
	switch name {
	case "arg":
		v = jq.valid_utf8(args[i + 2])
	case "argjson":
		v = json_arg(cli.json_reading, args[i + 2], a)
	case:
		msg: string
		read: bool
		v, msg, read = load(args[i + 2], name == "rawfile", cli.json_reading)
		if msg != "" {
			// jq says "Bad JSON" of a file that did not open or read too.
			message.write_stderr("stury: %s%s %s %s: %s\n", "Bad JSON in " if read else "", a, args[i + 1], args[i + 2], msg)
			exit_closing_stdout(EXIT_USAGE)
		}
	}
	append(&cli.var_names, args[i + 1])
	append(&cli.var_values, v)
}

// As in jq, an argument is an option only if it is `-` and a letter or a second `-`, so `-1` is a filter.
@(private = "file")
is_option :: proc(a: string) -> bool {
	return len(a) >= 2 && a[0] == '-' && (a[1] == '-' || ('a' <= a[1] && a[1] <= 'z') || ('A' <= a[1] && a[1] <= 'Z'))
}

// Where `check` (or `validate`), `fmt`, `edit` or `schema` stands in `args`, or -1: the first argument that is not an option, before
// `--`. Under -f that argument is the program file's name, which stays a file. Short options hold -f when an `f` comes
// before any `L`, whose rest is a directory (`-Lfoo`).
@(private = "file")
subcommand_index :: proc(args: []string) -> int {
	for i := 0; i < len(args) && args[i] != "--"; i += 1 {
		a := args[i]
		f, l := strings.index_byte(a, 'f'), strings.index_byte(a, 'L')
		switch {
		case a == "--from-file" || is_option(a) && a[1] != '-' && f > 0 && (l < 0 || f < l):
			return -1
		case is_option(a):
			i += option_arity(a)
		case:
			return i if a == "schema" || a == "check" || a == "validate" || a == "fmt" || a == "edit" || a == "diff" else -1
		}
	}
	return -1
}

// How many of the arguments after `a` an option takes as its parameters: the --max-depth prescan steps
// over them as `parse_args` reads them.
@(private = "file")
option_arity :: proc(a: string) -> int {
	switch a {
	case "--indent", "--max-depth", "--library-path", "-L", "--from", "--to", "--delimiter", "--comment", "--out-delimiter", "--out-comment", "--schema", "--schema-ref", "--schema-draft", "--max-errors", "--report", "--filter", "--seed", "--count", "--package", "--old-schema", "--new-schema", "--compat", "--key", "--alias-limit", "--expansion-limit":
		return 1
	case "--arg", "--argjson", "--slurpfile", "--rawfile":
		return 2
	}
	return 0
}

// The long options that are another way to write a letter.
@(private = "file", rodata)
LONG_LETTERS := [?]struct {
	name:   string,
	letter: byte,
}{
	{"slurp", 's'},
	{"raw-output", 'r'},
	{"join-output", 'j'},
	{"compact-output", 'c'},
	{"color-output", 'C'},
	{"monochrome-output", 'M'},
	{"ascii-output", 'a'},
	{"sort-keys", 'S'},
	{"raw-input", 'R'},
	{"null-input", 'n'},
	{"from-file", 'f'},
	{"binary", 'b'},
	{"exit-status", 'e'},
	{"help", 'h'},
	{"version", 'V'},
}

// The option of letter `c` (but `L`), or false if there is none.
@(private = "file")
letter_option :: proc(o: ^Opts, cli: ^Cli, c: byte) -> bool {
	switch c {
	case 's':
		o.slurp = true
	case 'r':
		o.raw = true
		note_json_flag(cli, "-r")
	case 'j':
		o.raw, o.join = true, true
		note_json_flag(cli, "-j")
	case 'c':
		o.compact = true
		cli.compact_given = true
		note_json_flag(cli, "-c", laid = true)
	case 'C':
		cli.color_set = true
		note_json_flag(cli, "-C")
	case 'M':
		cli.mono = true
	case 'a':
		o.ascii = true
		note_json_flag(cli, "-a", laid = true)
	case 'S':
		o.sort_keys = true
	case 'R':
		o.raw_input = true
	case 'n':
		o.null_input = true
	case 'f':
		o.from_file = true
	case 'b':
	// jq's -b stops Windows' C streams turning LF into CRLF. stury's streams never translate on any system
	// (platform_windows.odin writes with WriteFile), so the flag is accepted for jq's scripts and changes
	// nothing. jq lists it in --help only on Windows builds, and stury's help follows jq's POSIX one.
	case 'e':
		o.exit_status = true
	case 'h':
		usage(0, false, command_name(cli))
	case 'V':
		message.write_stdout("stury-%s\n", VERSION)
		exit_closing_stdout(0)
	case:
		return false
	}
	return true
}

// -L's directory as the argument after args[i], and where the arguments go on, jq's error if there is none.
@(private = "file")
lib_dir_arg :: proc(cli: ^Cli, args: []string, i: int) -> int {
	if i + 1 >= len(args) {
		message.write_stderr("-L takes a parameter: (e.g. -L /search/path or -L/search/path)\n")
		die()
	}
	add_lib_dir(cli, args[i + 1])
	return i + 1
}

// `dir` on the module search list, as jq_realpath makes it: its real path, or itself when it has none.
@(private = "file")
add_lib_dir :: proc(cli: ^Cli, dir: string) {
	if cli.lib_dirs == nil {
		cli.lib_dirs = make([dynamic]string)
	}
	append(&cli.lib_dirs.?, jq.real_path(dir))
}

// --indent's number as jq's strtol reads it: a sign, then decimal digits to the end, from -1 to 7.
@(private = "file")
parse_indent :: proc(s: string) -> (n: i8, ok: bool) {
	signed := len(s) > 0 && (s[0] == '+' || s[0] == '-')
	digits, digits_ok := parse_digits(s[1:] if signed else s, 100) // anything past 7 is refused
	if !digits_ok {
		return
	}
	v := int(digits)
	if s[0] == '-' {
		v = -v
	}
	return i8(v), -1 <= v && v <= 7
}

// `s` as decimal digits only, and at least one, to `cap` at most. The cap keeps a long run from overflowing.
parse_digits :: proc(s: string, cap: u64) -> (n: u64, ok: bool) {
	if len(s) == 0 {
		return
	}
	for c in transmute([]byte)s {
		if c < '0' || c > '9' {
			return
		}
		n = min(n * 10 + u64(c - '0'), cap)
	}
	return n, true
}

// The deepest --max-depth: the interpreter and the printer recurse once per level, on a stack sized for this.
@(private = "file")
DEPTH_CEILING :: 1 << 20

// --max-depth's number: decimal digits, from 1 to DEPTH_CEILING.
@(private = "file")
parse_max_depth :: proc(s: string) -> (n: u64, ok: bool) {
	n, ok = parse_digits(s, DEPTH_CEILING + 1) // past the ceiling is refused
	return n, ok && 1 <= n && n <= DEPTH_CEILING
}

// A command, as the owner of the options that only some commands take.
Command :: enum u8 {
	Run,
	Check,
	Fmt,
	Edit,
	Diff,
	Infer,
	Sample,
	Gen,
}

@(rodata)
COMMAND_NAMES := [Command]string {
	.Run    = "",
	.Check  = "check",
	.Fmt    = "fmt",
	.Edit   = "edit",
	.Diff   = "diff",
	.Infer  = "schema infer",
	.Sample = "schema sample",
	.Gen    = "schema gen",
}

// Options, without their dashes, that only the commands `by` take, and what they do, which is why the others refuse them.
Owned_Options :: struct {
	names: []string,
	by:    bit_set[Command],
	does:  string,
}

@(rodata)
OWNED_OPTIONS := [?]Owned_Options {
	{{"schema", "max-errors"}, {.Check, .Fmt}, "it judges the inputs against a schema"},
	{{"report"}, {.Check}, "it sets the layout of a schema check's report"},
	{{"filter"}, {.Check}, "it types a filter against a schema"},
	{{"schema-ref", "schema-draft"}, {.Check, .Fmt, .Diff, .Sample, .Gen}, "it says how a schema is read"},
	{{"format-assert"}, {.Check, .Fmt, .Diff, .Gen}, "it asserts the formats a schema names"},
	{{"ranges"}, {.Infer}, "it keeps the bounds of the inferred numbers, lengths and counts"},
	{{"invalid", "comments", "seed", "count"}, {.Sample}, "it shapes the samples"},
	{{"package"}, {.Gen}, "it names the package of the Odin types"},
	{{"old-schema", "new-schema", "compat", "key", "set", "position", "facts", "json", "shape"}, {.Diff}, "it shapes what diff compares and tells"},
	{{"diff"}, {.Edit}, "it previews the changes of an edit"},
	{{"in-place", "check"}, {.Fmt, .Edit}, "it writes each file back, or tells whether it would change"},
}

// The entry of `name`, an option without its dashes, when only some commands take it.
owned_option :: proc(name: string) -> ^Owned_Options {
	for &o in OWNED_OPTIONS {
		if slice.contains(o.names, name) {
			return &o
		}
	}
	return nil
}

// Refuses the first option given that only other commands take, naming them and what the option does. A schema verb
// not named is left for `schema_main` to refuse.
refuse_unowned :: proc(cli: ^Cli) {
	command := Command.Run
	switch {
	case cli.validating: command = .Check
	case cli.formatting: command = .Fmt
	case cli.editing:    command = .Edit
	case cli.diffing:    command = .Diff
	case cli.schema_verb:
		verb := cli.files[0] if len(cli.files) > 0 else ""
		switch verb {
		case "infer":  command = .Infer
		case "sample": command = .Sample
		case "gen":    command = .Gen
		case:          return
		}
	}
	for flag in cli.owned {
		if o := owned_option(flag[2:]); command not_in o.by {
			owners := make([dynamic]string, context.temp_allocator)
			for c in o.by {
				append(&owners, strings.concatenate({COMMAND_NAMES[c], "'s"}, context.temp_allocator))
			}
			last := len(owners) - 1
			listed := strings.join(owners[:last], ", ", context.temp_allocator)
			usage_error("%s is %s: %s", flag, strings.join({listed, owners[last]}, " and ", context.temp_allocator) if last > 0 else owners[0], o.does)
		}
	}
}

// The command `cli` names, or "" for a filter run.
command_name :: proc(cli: ^Cli) -> string {
	return "check" if cli.validating else "fmt" if cli.formatting else "edit" if cli.editing else "diff" if cli.diffing else "schema" if cli.schema_verb else ""
}

// What the command writes, which is why it refuses an option `command_refused_option` names.
command_writes :: proc(cli: ^Cli) -> string {
	switch {
	case cli.validating && cli.schema.filter != nil: return "it types the filter and writes the schema of its outputs"
	case cli.validating && cli.schema.reported:      return "it runs no filter and writes its report in one layout"
	case cli.validating:                             return "it runs no filter and prints nothing"
	case cli.formatting:                             return "it runs no filter and writes each input in its own format or the one --to names"
	case generates_odin(cli):                        return "it runs no filter and writes Odin types"
	case cli.schema_verb:                            return "it runs no filter and writes a schema or samples"
	}
	return "it writes each input back in its own bytes"
}

// The first option given that `check`, `fmt`, `edit` or `schema` has no use for, or "". fmt writes each input's own format,
// and check prints nothing, so neither takes a layout or reshapes its input, but check takes --seq, which frames the records
// it judges. schema writes a description or samples, so it takes the layout options and, for sample, --to, but schema gen
// writes Odin and takes none. edit writes each input back in its own format, so it takes no output format and no option that respells
// the output as a whole, but its filter takes the options of a filter run's input and its bindings, and a built value
// is written with -a, -S, --indent and --tab.
command_refused_option :: proc(o: ^Opts, cli: ^Cli) -> string {
	// check --filter runs no filter but types one, on the inputs the input options describe, and writes a schema.
	typing := cli.validating && cli.schema.filter != nil
	editing, schema := cli.editing, cli.schema_verb && !generates_odin(cli) || typing
	switch {
	case (editing || cli.diffing) && cli.formats.to != nil: return "--to"
	case !cli.formatting && !schema && cli.cells_out_flag != "": return cli.cells_out_flag
	case o.raw0:                 return "--raw-output0"
	case o.raw:                  return "-j" if o.join else "-r"
	case cli.compact_given && !editing && !schema && !cli.formatting: return "-c"
	case o.ascii && !editing && !schema: return "-a"
	case o.sort_keys && !editing && !schema: return "-S"
	case cli.color_set:          return "-C"
	case o.raw_input && !editing && !typing: return "-R"
	case o.null_input && !typing: return "-n"
	case o.slurp && !editing && !typing: return "-s"
	case o.from_file && !editing && !typing: return "-f"
	case o.seq && (cli.formatting || typing): return "--seq"
	case o.stream_errors:        return "--stream-errors"
	case o.stream:               return "--stream"
	case o.exit_status && !editing: return "-e"
	case o.explain && !editing:  return "--explain"
	case cli.binding_flag != "" && !editing && !typing: return cli.binding_flag
	case !cli.formatting && !editing && !schema && cli.layout_flag != "": return cli.layout_flag
	case cli.lib_dirs != nil && !editing && !typing: return "-L"
	}
	return ""
}

// Refuses what --follow cannot do: it answers the records of one file as they are appended, so it needs the file
// named, a filter run, and an input that is records rather than whole texts.
refuse_follow :: proc(o: ^Opts, cli: ^Cli) {
	other := command_name(cli)
	other = other if other != "" else "--slurp" if o.slurp else "--null-input" if o.null_input else "--stream" if o.stream else ""
	if other != "" {
		usage_error("--follow answers each record of a file as it is appended: it cannot be combined with %s", other)
	}
	switch {
	case len(cli.files) == 0:
		usage_error("--follow follows one named file, and none was given")
	case len(cli.files) > 1:
		usage_error("--follow follows one named file, not %d files", len(cli.files))
	case cli.files[0] == "-":
		usage_error("--follow follows one named file, not stdin")
	}
	if FORMATS[o.from].spec != .Json || reads_whole(o) {
		usage_error("--follow reads records: --from %s makes one text of a file", FORMATS[o.from].name)
	}
	// A follow window ends at a line end, and a binary sequence has none between its items.
	if o.from == .Cbor {
		usage_error("--follow reads lines: --from cbor items are not lines")
	}
}
