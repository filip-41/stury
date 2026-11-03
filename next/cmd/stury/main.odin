package main

// The stury command line: a jq filter over JSON files.
//
//	stury [OPTIONS] [FILTER] [FILE...]
//	stury check [--from format|--seq] [--max-depth n] [FILE...]
//	stury fmt [--from format] [--to format] [--in-place|--check] [--indent n|--tab] [--max-depth n] [FILE...]
//
// The options are listed in HELP_OPTIONS (usage.odin). The exit codes are jq's: 2 for a usage or file error, 3 for a
// filter that does not compile, 5 for invalid input or an error the filter raises. Under `-e`, 1 when the last output
// is false or null and 4 when there is none.
//
// Where things live in cmd/stury:
//
//	options.odin                     the command line
//	usage.odin                       the help, the version and the usage error
//	load_values.odin                 JSON texts and files the options name
//	colors.odin                      jq's output colours and when a run uses them
//	formats.odin                     the formats --from reads and --to writes
//	input.odin                       reading files and stdin
//	filter.odin                      the jq interpreter over each input
//	message/                         the text of every message, built from a format and its values (package `message`)
//	platform_posix.odin,
//	platform_windows.odin            the calls into the system, one file per platform
//	regex/                           the Oniguruma-compatible matcher behind `test`, `match` and `sub`

import "core:os"
import "message"

EXIT_USAGE :: 2
EXIT_COMPILE :: 3
EXIT_INPUT :: 5

Run :: struct {
	opts:   Opts,
	colors: [8]string, // when opts.color, jq's colours (DEFAULT_COLORS) as $JQ_COLORS sets them
}

main :: proc() {
	run: Run
	run.opts.indent = 2
	cli := parse_args(&run.opts, command_args()[1:])
	set_colors(&run, cli)
	o := &run.opts
	refuse_format_clashes(o, &cli)
	validating := cli.validating
	switch {
	case o.in_place || o.check:
		usage_error("%s is fmt's: a filter run has no use for it", "--in-place" if o.in_place else "--check")
	case o.stream && validating:
		usage_error("--stream makes jq's events of each input; check only judges it")
	case o.explain && validating:
		usage_error("--explain reports a filter's route: check has no filter")
	case o.raw_input && validating:
		usage_error("check reads JSON texts, not -R's lines")
	}
	if _, has := cli.filter.?; !has && !o.from_file && is_terminal(os.stdin) && is_terminal(os.stdout) {
		usage(EXIT_USAGE, true)
	}
	message.write_stderr("stury: this build runs no filter\n")
	os.exit(EXIT_USAGE)
}
