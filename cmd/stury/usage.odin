package main

// What the command line says about itself: the version, the build configuration, the help, and the usage error that
// ends the run with jq's exit code 2.

import "core:io"
import "core:os"
import "message"

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
HELP_HEAD :: "stury - command-line JSON and CSV processor [version " + VERSION + `]

Usage:	stury [options] <jq filter> [file...]
	stury [options] --args <jq filter> [strings...]
	stury [options] --jsonargs <jq filter> [JSON_TEXTS...]
	stury check [--from format|--seq] [--max-depth n] [file...]
	stury check --schema <schema> [file...]
	stury check --filter <jq filter> --schema <schema>
	stury fmt [--from format] [--to format] [--in-place|--check]
	          [--indent n|--tab] [--max-depth n] [file...]
	stury fmt --schema <schema> [--to format] [file...]
	stury edit [--from format|--seq] [--in-place|--check|--diff] <jq filter> [file...]
	stury diff [options] <old file> <new file>
	stury diff --old-schema <schema> --new-schema <schema> [--compat direction]
	stury schema infer|sample|gen [options] (stury schema --help)

stury applies the filter to its JSON text inputs and writes the results as
JSON, as jq 1.8.2 does, but reads strictly (RFC 8259): 01, 1., NaN, nan,
Infinity, invalid UTF-8 in a string, a NUL after a value and nesting past
--max-depth are parse errors, and a number prints as it was written (1E2,
not jq's 1E+2). For filters see jq(1) and https://jqlang.org/.

`

@(private = "file")
HELP_OPTIONS :: `Commands:
  check                     judge the inputs, print nothing when valid
                            (stury check --help);
  fmt                       write each input in the printer's layout, or
                            transcode it (stury fmt --help);
  edit                      splice the filter's one output into each
                            input's own bytes (stury edit --help);
  diff                      tell what differs between two inputs, or two
                            schemas (stury diff --help);
  schema                    infer a schema from inputs, sample values from
                            one, or write Odin types for one (stury schema
                            --help);

Command options:
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
  -b, --binary              no effect outside Windows;
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
      --from format         read json (default), jsonc, json5, ndjson,
                            csv or tsv;
      --to format           write json (default), jsonc, ndjson, csv or tsv;
      --in-place            with fmt or edit, rewrite each file in place;
      --check               with fmt or edit, name each file it would
                            change and exit 1;
      --grow-header         with --to csv or tsv, write a header of every key;
      --schema file         with check and fmt, judge each input against
                            this JSON Schema, and refuse one that fails it;
      --schema-ref dir      the directory a file reference may read, the schema's by default;
      --schema-draft d      the draft of a schema with no $schema: 4, 6, 7,
                            2019-09 or 2020-12 (default);
      --format-assert       make format fail an input;
      --max-errors n        keep at most n failures of an input;
      --max-depth n         refuse nesting past n levels (default 1024);
      --follow              with one file, answer each record as it is
                            appended, like tail -f FILE | stury;
      --explain             write how the filter runs and what the run did
                            to stderr, and run the filter.

CSV and TSV options:
      --delimiter c         read cells split at c (one character, \t a tab);
      --no-header           read the first record as data: records are arrays;
      --comment c           skip lines that start with c;
      --infer               read an unquoted cell that is a number, true or
                            false as one (an empty one is null either way);
      --ragged              read records of any width;
      --lazy-quotes         read a quote inside an unquoted cell as text;
      --out-delimiter c     write cells split at c (default: --delimiter when
                            --to is --from, else the format's own);
      --out-comment c       write comment lines that start with c (default:
                            --comment when --from is csv or tsv);
      --out-no-header       write no header line;
      --crlf                end each written record with CR LF.

Named arguments are also available as $ARGS.named[], positional ones as
$ARGS.positional[]. The input differences from jq and each stury option in
full: docs/cli.md in stury's source, or man stury.
`

// `stury check --help`.
@(private = "file")
CHECK_HELP :: `Usage:	stury check [--from format|--seq] [--max-depth n] [--schema file] [file...]
	stury check --filter <jq filter> --schema file [-n] [-s] [-R] [--arg name value]

stury check judges each input as stury . reads it and prints nothing when it
is valid. Every file is judged, and each file's first fault is reported.

Options:
      --from format         read json (default), jsonc, json5, ndjson,
                            csv or tsv;
      --seq                 judge each record after a 0x1E separator as
                            one text;
      --max-depth n         refuse nesting past n levels (default 1024);
      --schema file         also check each input against a JSON Schema and
                            tell every failure, exit 1. For csv and tsv the
                            schema describes the table, an array of rows;
      --schema-ref dir      the directory a file reference may read, the schema's by default;
      --schema-draft d      the draft of a schema with no $schema: 4, 6, 7,
                            2019-09 or 2020-12 (default);
      --format-assert       make format fail an input;
      --max-errors n        keep at most n failures of an input;
      --report kind         tell failures as lines (default), basic (the JSON
                            Schema basic output) or problem (RFC 9457);
      --filter f            read no input: type the jq filter f against
                            --schema, write the schema of its outputs, and
                            exit 1 only after refusing a step no input takes;
      --delimiter c, --no-header, --comment c, --infer, --ragged,
      --lazy-quotes         read csv or tsv as stury --help says;
  -h, --help                show this help.

Exit status: 0 when every input is valid, 1 when one fails the schema, 5 when
one holds a fault, 2 for a usage or file error. In full: stury(1), or docs/cli.md in stury's source.
`

// `stury schema --help`.
@(private = "file")
SCHEMA_HELP :: `Usage:	stury schema infer [--from format] [--ranges] [file...]
	stury schema sample [--to format] [--count n] [--seed n] [--invalid] [--comments]
	          [--schema-ref dir] [--schema-draft d] schema
	stury schema gen [--package name] [--format-assert] [--schema-ref dir] [--schema-draft d] schema

infer writes the JSON Schema that every record of the inputs passes. sample
writes values that pass the schema file, a text a line. gen writes the Odin
types a model reads the schema's values with.

Options:
      --from format         read json (default), jsonc, json5, ndjson, csv or tsv;
      --ranges              infer: keep the least and greatest number, string
                            length and array length;
      --to format           sample: write json (default), jsonc, ndjson, csv or tsv;
      --count n, --seed n   sample: how many values, and from which seed;
      --invalid             sample: values that fail the schema;
      --comments            sample: write descriptions as comments;
      --package name        gen: the package of the types, by default the
                            schema file's name;
      --schema-ref dir      sample and gen: the directory a file reference
                            may read, the schema's by default;
      --schema-draft d      sample and gen: the draft of a schema with no
                            $schema: 4, 6, 7, 2019-09 or 2020-12 (default);
      --format-assert       gen: spell a format as the type that reads it;
      -c, --indent n, --tab, -S, -a   infer and sample: the layout of the text
                            written;
  -h, --help                show this help.

Exit status: 0, 1 when no value that passes the schema is found or no Odin type spells a
keyword, 5 when an input holds a fault, 2 for a usage or file error.
`

// `stury fmt --help`.
@(private = "file")
FMT_HELP :: `Usage:	stury fmt [--from format] [--to format] [--in-place|--check]
	          [--indent n|--tab] [--max-depth n] [file...]
	stury fmt --schema file [--to format] [--schema-ref dir] [--max-errors n] [--format-assert] [file...]

stury fmt writes each input back in the printer's layout, or transcodes it
from --from to --to. It runs no filter. Every file is formatted, and each
file's first fault is reported. Under --schema a file that fails the schema is
not written, and a table written is judged again as it reads back.

Options:
      --from format         read json (default), jsonc, json5, ndjson,
                            csv or tsv;
      --to format           write json, jsonc, ndjson, csv or tsv (default
                            the --from format);
      --in-place            rewrite each file in place;
      --check               write nothing, name each file that is not
                            already formatted, and exit 1;
      --indent n            use n spaces for indentation (0 to 7);
      --tab                 use tabs for indentation;
      --grow-header         with --to csv or tsv, write a header of every key;
      --max-depth n         refuse nesting past n levels (default 1024);
      --schema file         judge each input against this JSON Schema as
                            stury check --schema does, and write only an
                            input that passes it;
      --schema-ref dir      the directory a file reference may read, the schema's by default;
      --schema-draft d      the draft of a schema with no $schema: 4, 6, 7,
                            2019-09 or 2020-12 (default);
      --format-assert       make format fail an input;
      --max-errors n        keep at most n failures of an input;
      --delimiter c, --no-header, --comment c, --infer, --ragged,
      --lazy-quotes, --out-delimiter c, --out-comment c, --out-no-header,
      --crlf                read and write csv or tsv as stury --help says;
                            a table written as the format read keeps its
                            delimiter and comment character, and its
                            comments when it has a comment character;
  -h, --help                show this help.

Exit status: 0, or 1 under --check when a file is not formatted or under
--schema when one fails the schema, 5 when one holds a fault or a value the
output cannot write, 2 for a usage or file error. In full: stury(1), or docs/cli.md
in stury's source.
`

// `stury edit --help`.
@(private = "file")
EDIT_HELP :: `Usage:	stury edit [--from format|--seq|-R] [-s] [--in-place|--check|--diff] <jq filter> [file...]

stury edit runs the filter on each input and writes the input back with the
filter's outputs spliced in: the bytes the edit does not reach, comments,
spacing and number spellings among them, stay as written. A JSON text takes
one output. A table, NDJSON, --seq and -R lines are edited record by record: a
record with no output is dropped, and each output past the first is a new
record after it. Members, elements and columns take the output's order, a
moved one keeping its bytes and comments. Of a repeated key the last member is
edited. Every file is edited, and each file's first fault is reported.

Options:
      --from format         read json (default), jsonc, json5, ndjson,
                            csv or tsv;
      --seq                 edit each record after a 0x1E separator;
  -R, --raw-input           edit each line as a string;
  -s, --slurp               run the filter once on the array of records;
      --in-place            rewrite each file in place;
      --check               write nothing, name each file the filter would
                            change, and exit 1;
      --diff                tell the value changes of each file's edit, and
                            with --in-place write it too. It exits 0 when
                            the edit succeeds, where stury diff exits 1 on a
                            difference;
  -a, --ascii-output        write built values with ASCII escapes;
  -S, --sort-keys           sort the keys of every object, and the columns;
      --indent n            write built values with n spaces (0 to 7);
      --tab                 write built values with a tab;
  -e, --exit-status         set the exit status by the last output;
      --max-depth n         refuse nesting past n levels (default 1024);
  -f, --from-file           load the filter from a file;
  -L, --library-path dir    search modules from the directory;
      --arg name value      set $name to the string value, and --argjson,
                            --slurpfile, --rawfile, --args, --jsonargs as in
                            stury --help;
      --delimiter c, --no-header, --comment c, --infer, --ragged,
      --lazy-quotes         read csv or tsv as stury --help says;
  -h, --help                show this help.

Exit status: 0, or 1 under --check when a file would change, 5 when one holds
a fault or the filter fails on it, 2 for a usage or file error, and under -e
as for a filter run. In full: stury(1), or docs/cli.md in stury's source.
`

// `stury diff --help`.
@(private = "file")
DIFF_HELP :: `Usage:	stury diff [options] <old file> <new file>
	stury diff --old-schema <schema> --new-schema <schema> [--compat direction]
	stury diff --old-schema <schema> <data file>
	stury diff --shape [--from format] <old file> <new file>

stury diff tells the changes that turn the first input into the second, a line
each: + for an added member or element, - for a removed one, ~ for a changed
value, with its path. Objects match by member name and arrays as sequences, so
one inserted element is one change. Two schemas are compared too: each change
names the keyword and whether it widens or narrows what the schema takes, and
backward and forward tell whether the new schema takes what the old one does
and the reverse, with a value that breaks it when not. A schema and one data
file judge the data by the schema, as stury check --schema does, and tell the
members the data has that the schema does not describe. A file of records is
one array of them. --shape compares the shapes of two data files.

Options:
      --from format         read json (default), jsonc, json5, ndjson or csv, tsv;
      --key member          match array elements by the value of member, or
                            PATH=member for the array at PATH (.a[].b=id);
      --set                 match equal elements wherever they stand;
      --position            compare the elements at one index;
      --facts               tell changes of comments and attributes too;
      --json                write one record a line;
      --shape               compare the shapes the two files infer to;
      --old-schema file     the first input is this JSON Schema;
      --new-schema file     the second input is this JSON Schema;
      --compat direction    backward, forward or full: exit 1 unless the
                            schemas are proven compatible that way;
      --schema-ref dir      where file $refs of a schema resolve;
      --schema-draft d      the draft of a schema with no $schema: 4, 6, 7,
                            2019-09 or 2020-12 (default);
      --format-assert       let format assert, as stury check does;
  -h, --help                show this help.

Exit status: 0 when nothing differs, 1 when something does or compatibility is
not proven, 5 when an input does not parse, 2 for a usage or file error. In
full: stury(1), or docs/cli.md in stury's source.
`

// jq's usage(): to stdout and exit 0 for --help, else to stderr and exit `code`. The options, or with `short` where
// to find them. A `command`'s help is its own.
usage :: proc(code: int, short: bool, command := "") -> ! {
	w := os.to_writer(os.stdout if code == 0 else os.stderr)
	switch command {
	case "check":
		io.write_string(w, CHECK_HELP)
	case "fmt":
		io.write_string(w, FMT_HELP)
	case "edit":
		io.write_string(w, EDIT_HELP)
	case "schema":
		io.write_string(w, SCHEMA_HELP)
	case "diff":
		io.write_string(w, DIFF_HELP)
	case:
		io.write_string(w, HELP_HEAD)
		// The jq manpage, which the footer sends on, does not tell how stury's input differs.
		io.write_string(w, "How stury's input differs from jq's is in stury(1), not in the jq manpage.\nFor listing the command options, use stury --help.\n" if short else HELP_OPTIONS)
	}
	os.exit(code)
}

// jq's die(): an option it cannot use, reported, then exit 2.
usage_error :: proc(format: string, args: ..any) -> ! {
	message.write_stderr("stury: %s\n", message.build_temp(format, ..args))
	die()
}

// jq's footer, but it sends the reader to stury's pages, which tell what jq's do not.
@(private)
die :: proc() -> ! {
	message.write_stderr("Use stury --help for help with command-line options,\nor see stury(1), or docs/cli.md at https://github.com/filip-41/stury\n")
	os.exit(EXIT_USAGE)
}
