package main

// jq's output colours: its defaults, `$JQ_COLORS`, and whether the run colours at all.

import "core:os"
import "core:sys/posix"
import "message"

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
		colors[k] = message.build("\e[%sm", code)
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
			message.write_stderr("Failed to set $JQ_COLORS\n")
		}
	}
}
