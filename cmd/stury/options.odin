package main

// The command line read as jq 1.8.2's main.c reads it. A long option stands alone, and one-letter options run
// together (`-nr`), `-L` taking the rest of its argument or the next one. Each option's error is jq's, reported as
// soon as it is read.

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import json "../../json"
import "jq"

// What `-V` prints after `stury-`: the version the Makefile passes (a release version, or the short commit
// hash from a git checkout), else "dev". The Makefile hands it over in quotes, as odin's -define would read
// `1.0` or `2` as a number, not a string.
VERSION_DEFINE :: #config(STURY_VERSION, "dev")
VERSION :: VERSION_DEFINE[1:len(VERSION_DEFINE) - 1] when len(VERSION_DEFINE) >= 2 && VERSION_DEFINE[0] == '"' else VERSION_DEFINE

// What `--build-configuration` prints and `$JQ_BUILD_CONFIGURATION` holds, where jq has its configure flags.
BUILD_CONFIGURATION ::
	"odin " + ODIN_VERSION + " -target:" + ODIN_OS_STRING + "_" + ODIN_ARCH_STRING + " " + OPTIMIZATION
@(private = "file")
OPTIMIZATION ::
	"-o:speed" when ODIN_OPTIMIZATION_MODE == .Speed else "-o:aggressive" when ODIN_OPTIMIZATION_MODE == .Aggressive else "-o:size" when ODIN_OPTIMIZATION_MODE == .Size else "-o:minimal" when ODIN_OPTIMIZATION_MODE == .Minimal else "-o:none"

// jq's usage(): this, then the options or where to find them.
@(private = "file")
HELP_HEAD :: "stury - commandline JSON processor [version " + VERSION + `]

Usage:	stury [options] <jq filter> [file...]
	stury [options] --args <jq filter> [strings...]
	stury [options] --jsonargs <jq filter> [JSON_TEXTS...]
	stury check [--from format|--seq] [--strict-limits] [--max-depth n] [file...]
	stury fmt [--from format] [--to format] [--in-place|--check] [--indent n|--tab] [file...]

stury applies the filter to its JSON text inputs and writes the results as
JSON, as jq 1.8.2 does, but reads strictly (RFC 8259): 01, 1., NaN, nan,
Infinity, invalid UTF-8 in a string, a NUL after a value and nesting past
--max-depth are parse errors. For filters see jq(1) and https://jqlang.org/.

`

@(private = "file")
HELP_OPTIONS :: `Command options:
  -n, --null-input          use ` + "`null`" + ` as the single input value;
  -R, --raw-input           read each line as string instead of JSON;
  -s, --slurp               read all inputs into an array and use it as
                            the single input value;
  -c, --compact-output      compact instead of pretty-printed output;
  -r, --raw-output          output strings without escapes and quotes;
      --raw-output0         implies -r and output NUL after each output;
  -j, --join-output         implies -r and output without newline after
                            each output;
  -a, --ascii-output        output strings by only ASCII characters
                            using escape sequences;
  -S, --sort-keys           sort keys of each object on output;
  -C, --color-output        colorize JSON output;
  -M, --monochrome-output   disable colored output;
      --tab                 use tabs for indentation;
      --indent n            use n spaces for indentation (at most 7;
                            -1 is --tab);
      --unbuffered          flush output stream after each output;
      --stream              parse the input value in streaming fashion;
      --stream-errors       implies --stream and report parse error as
                            an array;
      --seq                 parse input/output as application/json-seq;
  -f, --from-file           load the filter from a file;
  -L, --library-path dir    search modules from the directory;
      --arg name value      set $name to the string value;
      --argjson name value  set $name to the JSON value;
      --slurpfile name file set $name to an array of JSON values read
                            from the file;
      --rawfile name file   set $name to string contents of file;
      --args                consume remaining arguments as positional
                            string values;
      --jsonargs            consume remaining arguments as positional
                            JSON values;
  -e, --exit-status         set exit status code based on the output;
  -V, --version             show the version;
  --build-configuration     show stury's build configuration;
  -h, --help                show the help;
  --                        terminates argument processing;

stury's own options:
  check                     judge the inputs, print nothing when valid;
  fmt                       write each input in the printer's layout, or
                            transcode it (--from, --to);
      --from format         read json (default), jsonc, ndjson, csv or tsv;
      --to format           write json (default), jsonc, ndjson, csv or tsv;
      --in-place            with fmt, rewrite each file in place;
      --check               with fmt, print nothing: exit 1 when a file is
                            not already formatted;
      --grow-header         with --to csv or tsv, write a header of every key;
      --max-depth n         refuse nesting past n levels (default 1024);
      --strict-limits       with check, keep the library's number limits.

Named arguments are also available as $ARGS.named[], positional ones as
$ARGS.positional[]. The input differences from jq and each stury option in
full: docs/cli.md in stury's source, or man stury.
`

Opts :: struct {
	compact:          bool,
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
	strict_limits:    bool, // check: the library's depth, digit and scale caps hold
	max_depth_given:  bool, // --max-depth was on the command line
	in_place:         bool,
	check:            bool,
}

// What the command line gives besides the options.
Cli :: struct {
	validating: bool,
	formatting: bool,
	filter:     Maybe(string), // the filter, or under -f the file it is in
	files:      [dynamic]string,
	// --arg, --argjson, --slurpfile and --rawfile, the first of a name standing.
	var_names:  [dynamic]string,
	var_values: [dynamic]jq.Value,
	positional: [dynamic]jq.Value, // --args and --jsonargs
	binding_flag: string,
	lib_dirs:   Maybe([dynamic]string), // -L's, made real paths
	color_set:  bool, // -C
	mono:       bool, // -M
	compact_given: bool,
	// --from and --to as given on the command line. `parse_args` resolves them into `Opts`.
	formats:    struct {
		from, to: Maybe(Format),
	},
	// The first JSON-output-only option given (-r, -c, --indent...), and the first JSON layout option given.
	json_flag, layout_flag: string,
}

// The command line `args` (os.args without the program) into `o`, as jq reads it.
parse_args :: proc(o: ^Opts, args: []string) -> (cli: Cli) {
	args := args
	subcommand := subcommand_index(args)
	if subcommand >= 0 {
		cli.formatting = args[subcommand] == "fmt"
		cli.validating = !cli.formatting
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
				jq.lifted.max_depth = n
				o.max_depth_given = true
			}
		}
	}
	o.from, o.to = cli.formats.from.? or_else .Json, cli.formats.to.? or_else .Json
	if o.from == .Jsonc {
		jq.read_dialect = .Jsonc
	}
	args_done := false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if i == subcommand {
			continue
		}
		if args_done || !is_option(a) {
			switch {
			case !cli.validating && !cli.formatting && cli.filter == nil:
				cli.filter = a
			case rest_as == .Args:
				append(&cli.positional, jq.valid_utf8(a))
			case rest_as == .Json_Args:
				append(&cli.positional, json_arg(a, "--jsonargs"))
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
			note_json_flag(&cli, "--indent", layout = true)
			i += option_arity(a)
		case "max-depth":
			if i + 1 >= len(args) {
				usage_error("--max-depth takes one parameter")
			}
			if _, ok := parse_max_depth(args[i + 1]); !ok {
				usage_error("--max-depth takes a number between 1 and %d", json.DEPTH_CEILING)
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
			fmt.println(BUILD_CONFIGURATION)
			os.exit(0)
		case "library-path":
			i = lib_dir_arg(&cli, args, i)
		case "from", "to":
			i += option_arity(a)
		case "grow-header":
			o.grow_header = true
		case "strict-limits":
			o.strict_limits = true
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
				fmt.eprintf("stury: Unknown option %s\n", a)
				die()
			}
		}
	}
	// fmt writes each input as its own format unless --to says otherwise, so its --to follows --from when --to
	// was not given. `--to ndjson` is what sets the compact layout here, since fmt refuses -c.
	if cli.formatting && cli.formats.to == nil {
		o.to = o.from
	}
	if o.to == .Ndjson {
		o.compact = true
	}
	return
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
		usage_error("%s takes one of %s, not %q", a, format_names(), args[i + 1])
	}
	if a == "--from" {
		cli.formats.from = f
	} else {
		cli.formats.to = f
	}
}

// Records `flag` as the first JSON-output-only option, and as the first layout option when `layout` is set.
@(private = "file")
note_json_flag :: proc(cli: ^Cli, flag: string, layout := false) {
	if cli.json_flag == "" {
		cli.json_flag = flag
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
			fmt.eprintf("stury: Unknown option -%s\n", a[j:j + 1])
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
		v = json_arg(args[i + 2], a)
	case:
		msg: string
		v, msg = load_file(args[i + 2], name == "rawfile")
		if msg != "" {
			fmt.eprintf("stury: Bad JSON in %s %s %s: %s\n", a, args[i + 1], args[i + 2], msg)
			os.exit(EXIT_USAGE)
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

// Whether the short options `a` hold -f: an `f` before any `L`, whose rest is a directory (`-Lfoo`).
@(private = "file")
has_from_file_flag :: proc(a: string) -> bool {
	flags := a[1:]
	if l := strings.index_byte(flags, 'L'); l >= 0 {
		flags = flags[:l]
	}
	return strings.contains_rune(flags, 'f')
}

// Where `check` (or `validate`) or `fmt` stands in `args`, or -1: the first argument that is not an option, before
// `--`. Under -f that argument is the program file's name, which stays a file.
@(private = "file")
subcommand_index :: proc(args: []string) -> int {
	for i := 0; i < len(args) && args[i] != "--"; i += 1 {
		a := args[i]
		switch {
		case a == "--from-file" || is_option(a) && a[1] != '-' && has_from_file_flag(a):
			return -1
		case is_option(a):
			i += option_arity(a)
		case:
			return i if a == "check" || a == "validate" || a == "fmt" else -1
		}
	}
	return -1
}

// How many of the arguments after `a` an option takes as its parameters: the --max-depth prescan steps
// over them as `parse_args` reads them.
@(private = "file")
option_arity :: proc(a: string) -> int {
	switch a {
	case "--indent", "--max-depth", "--library-path", "-L", "--from", "--to":
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
		note_json_flag(cli, "-c")
	case 'C':
		cli.color_set = true
		note_json_flag(cli, "-C")
	case 'M':
		cli.mono = true
	case 'a':
		o.ascii = true
		note_json_flag(cli, "-a")
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
		usage(0, false)
	case 'V':
		fmt.printf("stury-%s\n", VERSION)
		os.exit(0)
	case:
		return false
	}
	return true
}

// -L's directory as the argument after args[i], and where the arguments go on, jq's error if there is none.
@(private = "file")
lib_dir_arg :: proc(cli: ^Cli, args: []string, i: int) -> int {
	if i + 1 >= len(args) {
		fmt.eprintln("-L takes a parameter: (e.g. -L /search/path or -L/search/path)")
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
	dirs := &cli.lib_dirs.?
	append(dirs, jq.real_path(dir))
}

// jq's usage(): to stdout and exit 0 for --help, else to stderr and exit `code`. The options, or with `short` where
// to find them.
usage :: proc(code: int, short: bool) -> ! {
	w := os.to_writer(os.stdout if code == 0 else os.stderr)
	fmt.wprint(w, HELP_HEAD)
	// The jq manpage, which the footer sends on, does not tell how stury's input differs.
	fmt.wprint(w, "How stury's input differs from jq's is in stury(1), not in the jq manpage.\nFor listing the command options, use stury --help.\n" if short else HELP_OPTIONS)
	os.exit(code)
}

// jq's die(): an option it cannot use, reported, then exit 2.
usage_error :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("stury: ")
	fmt.eprintf(format, ..args)
	fmt.eprint("\n")
	die()
}

@(private = "file")
die :: proc() -> ! {
	fmt.eprint("Use stury --help for help with command-line options,\nor see the jq manpage, or online docs at https://jqlang.org\n")
	os.exit(EXIT_USAGE)
}

// A JSON text given to `option` on the command line: exactly one value.
json_arg :: proc(text, option: string) -> jq.Value {
	v, err := jq.read_text(transmute([]byte)text)
	if e, bad := err.?; bad {
		usage_error("invalid JSON text passed to %s: %s", option, jq.parse_message(transmute([]byte)text, e))
	}
	return v
}

// jq's jv_load_file: file `path` as one string (`raw`) or as the array of its JSON texts, or jq's message
// for why not.
load_file :: proc(path: string, raw: bool) -> (v: jq.Value, msg: string) {
	f, err := os.open(path)
	if err != nil {
		return nil, fmt.tprintf("Could not open %s: %s", path, strerror(err))
	}
	defer os.close(f)
	if fi, ferr := os.fstat(f, context.temp_allocator); ferr != nil || fi.type == .Directory {
		return nil, fmt.tprintf("Could not open %s: It's a directory", path)
	}
	data, rerr := read_whole(f, context.allocator)
	if rerr != nil {
		return nil, fmt.tprintf("Error reading from %s", path)
	}
	if raw {
		return jq.valid_utf8(string(data)), ""
	}
	all := jq.new_array()
	// Positions count from past a byte order mark, as the input reader counts them.
	start := len(UTF8_BOM) if bytes.has_prefix(data, UTF8_BOM[:]) else 0
	at := start
	for {
		for at < len(data) && jq.is_space(data[at]) {
			at += 1
		}
		if at == len(data) {
			return all, ""
		}
		end, trailing := text_span(data, at)
		if jq.read_dialect == .Jsonc { // one document per input, as for the files
			end, trailing = len(data), false
		}
		if e, bad := json.validate(data[at:end], {dialect = jq.read_dialect, limits = jq.lifted}).?; bad && e.kind == .Trailing && trailing {
			end = at + int(e.offset)
		}
		x, err := jq.read_text(data[at:end])
		if e, bad := err.?; bad {
			line, column := 1, 0
			jq.advance(&line, &column, data[start:at])
			return nil, jq.parse_message(data[at:], e, line, column)
		}
		append(&all.items, x)
		at = end
	}
}

// -f: the filter in file `path` as jq loads it, or jq's message and exit 2. The file's directory is where
// `get_prog_origin` says the filter came from.
program_file :: proc(run: ^Run, path: string) -> string {
	v, msg := load_file(path, true)
	if msg != "" {
		fmt.eprintf("stury: %s\n", msg)
		os.exit(EXIT_USAGE)
	}
	text, _ := jq.string_of(v)
	if strings.index_byte(text, 0) >= 0 {
		fmt.eprintln("stury: program file contains NUL bytes")
		os.exit(EXIT_USAGE)
	}
	run.ip.prog_origin = jq.real_path(jq.dir_name(path))
	return text
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
@(private = "file")
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

// --max-depth's number: decimal digits, from 1 to the library's ceiling.
@(private = "file")
parse_max_depth :: proc(s: string) -> (n: u64, ok: bool) {
	n, ok = parse_digits(s, json.DEPTH_CEILING + 1) // past the ceiling is refused
	return n, ok && 1 <= n && n <= json.DEPTH_CEILING
}

// jq's colours (jv_print.c), in its order: null, false, true, numbers, strings, arrays, objects, and an
// object's keys.
@(rodata)
DEFAULT_COLORS := [8]string{"\e[0;90m", "\e[0;39m", "\e[0;39m", "\e[0;39m", "\e[0;32m", "\e[1;39m", "\e[1;39m", "\e[1;34m"}

// $JQ_COLORS as jq_set_colors reads it: up to eight colon-separated codes of digits and `;`, each over the default in
// its place, and an empty last one not counted. It returns false, and the defaults, at any other byte before the
// eighth. What follows the eighth is not read.
parse_colors :: proc(spec: string) -> (colors: [8]string, ok: bool) {
	colors = DEFAULT_COLORS
	codes: [8]string
	n, rest := 0, spec
	for {
		span := 0
		for span < len(rest) && (rest[span] == ';' || '0' <= rest[span] && rest[span] <= '9') {
			span += 1
		}
		codes[n], rest = rest[:span], rest[span:]
		if len(rest) == 0 || n + 1 == len(codes) {
			break
		}
		if rest[0] != ':' {
			return DEFAULT_COLORS, false
		}
		rest = rest[1:]
		n += 1
	}
	if codes[n] != "" {
		n += 1
	}
	for code, k in codes[:n] {
		colors[k] = fmt.aprintf("\e[%sm", code)
	}
	return colors, true
}

// jq's choice of colour: with -C, or when stdout is a terminal and $NO_COLOR is unset or empty. Never with -M, and
// never for fmt, which ignores $JQ_COLORS too.
set_colors :: proc(run: ^Run, cli: Cli) {
	no_color := posix.getenv("NO_COLOR")
	run.opts.color = (cli.color_set || is_terminal(os.stdout) && (no_color == nil || no_color == "")) && !cli.mono && !cli.formatting
	if run.opts.color {
		enable_color()
	}
	run.colors = DEFAULT_COLORS
	if spec := posix.getenv("JQ_COLORS"); spec != nil && !cli.formatting {
		ok: bool
		if run.colors, ok = parse_colors(string(spec)); !ok {
			fmt.eprintln("Failed to set $JQ_COLORS")
		}
	}
}
