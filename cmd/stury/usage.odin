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
HELP_HEAD :: "stury - commandline JSON processor [version " + VERSION + `]

Usage:	stury [options] <jq filter> [file...]
	stury [options] --args <jq filter> [strings...]
	stury [options] --jsonargs <jq filter> [JSON_TEXTS...]
	stury check [--from format|--seq] [--strict-limits] [--max-depth n] [file...]
	stury fmt [--from format] [--to format] [--in-place|--check]
	          [--indent n|--tab] [--max-depth n] [file...]

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
      --from format         read json (default), jsonc, json5, ndjson,
                            csv or tsv;
      --to format           write json (default), jsonc, ndjson, csv or tsv;
      --in-place            with fmt, rewrite each file in place;
      --check               with fmt, print nothing: exit 1 when a file is
                            not already formatted;
      --grow-header         with --to csv or tsv, write a header of every key;
      --max-depth n         refuse nesting past n levels (default 1024);
      --strict-limits       with check, keep the library's number limits;
      --explain             write the filter's route, its plan and what the
                            run did to stderr, and run the filter.

Named arguments are also available as $ARGS.named[], positional ones as
$ARGS.positional[]. The input differences from jq and each stury option in
full: docs/cli.md in stury's source, or man stury.
`

// jq's usage(): to stdout and exit 0 for --help, else to stderr and exit `code`. The options, or with `short` where
// to find them.
usage :: proc(code: int, short: bool) -> ! {
	w := os.to_writer(os.stdout if code == 0 else os.stderr)
	io.write_string(w, HELP_HEAD)
	// The jq manpage, which the footer sends on, does not tell how stury's input differs.
	io.write_string(w, "How stury's input differs from jq's is in stury(1), not in the jq manpage.\nFor listing the command options, use stury --help.\n" if short else HELP_OPTIONS)
	os.exit(code)
}

// jq's die(): an option it cannot use, reported, then exit 2.
usage_error :: proc(format: string, args: ..any) -> ! {
	message.write_stderr("stury: %s\n", message.build_temp(format, ..args))
	die()
}

@(private)
die :: proc() -> ! {
	message.write_stderr("Use stury --help for help with command-line options,\nor see the jq manpage, or online docs at https://jqlang.org\n")
	os.exit(EXIT_USAGE)
}
