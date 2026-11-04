# stury command line

`stury` is a jq-compatible JSON processor. It runs jq 1.8 filters and gives jq's results and exit codes. Its
messages start with `stury:`, and parse errors are worded its own way ([Errors and exit
codes](#errors-and-exit-codes)). On top of jq it:

- validates JSON without running a filter (`stury check`);
- writes each input back in the printer's layout, or transcodes it (`stury fmt`);
- reads and writes JSONC, NDJSON, CSV and TSV (`--from FORMAT`, `--to FORMAT`, [Formats](#formats));
- reads input strictly, as RFC 8259 says ([Differences from jq](#differences-from-jq)).

The examples below assume `stury` is on your `PATH`; otherwise use `build/stury` (`make build-cli`).

```sh
stury [-c] [-r] [-j] [--raw-output0] [-a] [-S] [-C|-M] [--tab|--indent N] [--unbuffered] [-b]
      [-n] [-R] [-s] [-e] [-f FILE] [-L DIR] [--seq] [--stream|--stream-errors]
      [--from FORMAT] [--to FORMAT] [--grow-header]
      [--max-depth N] [--follow] [--explain]
      [--arg NAME VALUE] [--argjson NAME JSON] [--slurpfile NAME FILE] [--rawfile NAME FILE]
      [FILTER] [FILE...] [--args STRING...|--jsonargs JSON...]
stury check [--from FORMAT|--seq] [--max-depth N] [FILE...]
stury fmt [--from FORMAT] [--to FORMAT] [--in-place|--check] [--indent N|--tab] [--max-depth N] [FILE...]
stury -h | -V | --build-configuration
```

## Quick examples

```sh
$ echo '{"foo": 0}' | stury .
{
  "foo": 0
}

$ echo '{"a": {"b": [1, 2, 3]}}' | stury '.a.b[]'
1
2
3

$ printf '{"foo": 01}' | stury check
stury: error: <stdin>:1:10: Invalid numeric literal

$ printf '{"n": 1}\n{"n": 2}\n' | stury --from ndjson '.n'
1
2

$ printf '{\n  // lead\n  "a": 1 // inline\n}\n' | stury --from jsonc --to jsonc .
{
  // lead
  "a": 1 // inline
}

$ tail -f log | stury .msg
"one"
"two"
```

`check` prints nothing when an input is a document. On the bad text above it prints the fault and exits 5.

## Options

stury takes all of jq's options except `--run-tests` (jq's test-file runner, which stury does not have) and
adds its own. Each letter has jq's long form (`--compact-output`,
`--null-input`, `--from-file`, `--library-path`, ...); the synopsis above gives the full list. `FILTER` is a
jq 1.8 program, modules included (`import`, `include`, `-L`, `~/.jq`).

`FILE` and `FILTER` are positional:

| Given | stury |
| --- | --- |
| no `FILE` | reads stdin |
| no `FILTER` | runs `.` |
| no `FILTER`, and stdin and stdout are both a terminal | prints the usage and exits 2 |

### stury's own options

| Option | Behaviour |
| --- | --- |
| `check`, `validate` | A subcommand, recognised when it is the first argument that is not an option, before any `--` (`stury -c check FILE`); under `-f` that argument is the program file. See [`check`](#check). |
| `fmt` | A subcommand, recognised as `check` is: writes each input back in the printer's layout, or in another format, and runs no filter. See [`fmt`](#fmt). |
| `--from FORMAT` | Read `json` (the default), `jsonc`, `json5`, `ndjson`, `csv` or `tsv` ([Formats](#formats)). |
| `--to FORMAT` | Write `json` (the default), `jsonc`, `ndjson`, `csv` or `tsv` ([Formats](#formats), [CSV and TSV output](#csv-and-tsv-output)). `fmt` writes the `--from` format when `--to` is not given. |
| `--in-place` | `fmt` only: rewrite each file through a temporary one and a rename, when `--to` is `--from` ([`fmt`](#fmt)). |
| `--check` | `fmt` only: write nothing, and exit 1 when a file is not already formatted ([`fmt`](#fmt)). |
| `--grow-header` | With `--to csv` or `--to tsv`, write a header of every key of every object output ([CSV and TSV output](#csv-and-tsv-output)). |
| `--max-depth N` | Refuse nesting past N levels (1024 by default, up to 2^20, where jq's limit is 10000). A value deeper than the default also runs on one thread. |
| `--follow` | With one named file, answer each record as it is appended, like `tail -f FILE | stury FILTER` without the pipe ([`--follow`](#--follow)). |
| `--explain` | Write the plan the filter runs under and what the run did to stderr ([`--explain`](#--explain)), and run the filter as without it. |

### Options that differ from jq

| Option | Behaviour |
| --- | --- |
| `-C`, `-M` | `-C` colours output with jq's defaults or `JQ_COLORS`. It is on by default when stdout is a terminal and `NO_COLOR` is unset; `-M` turns it off. |
| `--tab`, `--indent N` | `--indent 0` prints each line with no indent, as jq does. N is -1 to 7; -1 is `--tab`. |
| `-b` | Does nothing outside Windows. |
| `-V` | Prints `stury-` and the version it was built with: the release version (for example `0.0.3`), or the short commit hash from a source build (`dev` outside a checkout). |
| `--help` | It and the short usage point to stury(1) (`docs/stury.1`) and this page. |

### Behaviour notes

- Plain paths such as `.a.b[]` are answered without building the document. These options switch to the
  general interpreter, which may be slower on large inputs: `-n`, `-s`, `-S`, `-a`, `-e`, `-R`,
  `--raw-output0`, `--seq`, `--stream`.
- Under `--from csv` or `--from tsv`, a filter that only picks columns (`.name`, `.a, .b`, `[.a, .b]`,
  `{a, b: .c}`, `.`, or `select(F)` where `F` reads named columns) is answered from each record's cells,
  without building an object, and on threads for a large file. Any other filter runs on the interpreter.
- A key repeated in one object is read as jq reads it: the last value wins.
- A number is printed as it was written, in the input or the filter: `1E2` stays `1E2`, `1.50` stays `1.50` and `0.1e1`
  stays `0.1e1`. jq prints its own spelling (`1E+2`, `1.50`, `1`). A number a filter computes is printed as jq prints
  a double (`1e+29`), and a string as jq prints it (`"\/"` is `"/"`, DEL is `\u007f`).
- A long input is answered on all cores ([Long input](#long-input)). The output, the exit status and the errors are
  those of a serial run.

### `--explain`

`--explain` writes `stury: explain: KEY: FACTS` lines to stderr and runs the filter as it would without the
option: the same stdout, the same exit status, the same other stderr. The facts are `key=value` tokens, named as
the code names them, in lower case. The plan block is written once the route is chosen, before any input is read; the
run block when the run ends, whether it ends normally or on an error. A filter that does not compile has the
`program` line and its compile error alone.

```sh
$ stury --explain -c '.logs[].id' in.json
stury: explain: program: ".logs[].id"
stury: explain: input: format=json dialect=json records=whole duplicates=last
stury: explain: route: path_scan
stury: explain: path: .logs[].id any_at=1 select=none limit=0
stury: explain: compile_time: 88us
1
2
stury: explain: run: texts=1 scanned=1 interpreted=0 pieces=none
stury: explain: run_time: 66us
stury: explain: cost: peak_rss=2818048 input=35 output=4
$ stury --explain -c '.a | tostring' in.json
stury: explain: program: ".a | tostring"
stury: explain: input: format=json dialect=json records=whole duplicates=last
stury: explain: route: interpreter
stury: explain: refused: not_path
stury: explain: compile_time: 142us
"1"
stury: explain: run: texts=1 scanned=0 interpreted=1 pieces=none
stury: explain: run_time: 140us
stury: explain: cost: peak_rss=3096576 input=35 output=4
```

| Key | Facts |
| --- | --- |
| `program` | The filter, quoted. Written as soon as it is known, so a compile error follows it; a `-f` file that cannot be read has no line. |
| `input` | `format` (`json`, `jsonc`, `ndjson`, `csv`, `tsv`), and for the JSON formats `dialect` (`json`, `jsonc`, `json5`), `records` and `duplicates` (a repeated key answers with its last value). `records` is how the input is cut into texts: `whole` (texts as jq reads them), `ndjson`, `seq` (`--seq`), `raw_lines` (`-R`) or `none` (`-n`). |
| `route` | `path_scan`, `columns` or `interpreter`. |
| `path` | The path scan answers this path: `any_at` is the index of its first `[]` step or `none`; `select` is `none`, or the comparison of `select(PATH op LITERAL)` as `eq`, `ne`, `lt`, `le`, `gt` or `ge` and its `literal`, and the path is PATH; `limit` is the count of `first(P)` or `limit(N; P)`, 0 for every answer. |
| `columns` | The column route answers: `read` the columns it reads (`*` for every column), `shape` of the output (`column`: a single column; `array`; `object`; `all`: every column of the record) and `selecting` (`yes` for `select(F)`, where F runs on an object of the columns it reads and a kept record is printed from its cells). |
| `refused` | The interpreter answers because of these reasons, every one that holds, comma-joined. |
| `compile_time` | From reading the filter to the route chosen. The interpreter's parse is in it only when the route needs the interpreter before the first input. |
| `run` | Texts read: `texts` is `scanned` (the scan answered) plus `interpreted` (the interpreter ran on it). Under the interpreter the unit is what its main loop reads: a text, a `--stream` event, a CSV record. `-n` reads none of its own. The column route has `files` (CSV files opened) instead. `pieces` is how many pieces of the input were answered on the pool's threads ([Long input](#long-input)), or `none`. |
| `fallback` | The first text the scan handed to the interpreter: its number from 1 and the `why`. Not written when the scan kept every text. |
| `run_time` | From the route chosen to the end of the run. |
| `cost` | `peak_rss` bytes, `input` bytes taken (a file mapped or read whole counts in full) and `output` bytes written to stdout. |

Reasons in `refused`:

| Token | Meaning |
| --- | --- |
| `null_input` | `-n` reads no input. |
| `slurp` | `-s` needs the input whole. |
| `sort_keys` | `-S` sorts keys on output. |
| `raw_input` | `-R` reads lines as strings. |
| `seq` | `--seq` writes record separators. |
| `stream` | `--stream` reads jq's events. |
| `exit_status` | `-e` reads each output. |
| `raw0` | `--raw-output0` writes NUL. |
| `ascii` | `-a` writes ASCII only. |
| `cells_out` | `--to csv|tsv` writes each output as a record. |
| `comments_out` | `--to jsonc` prints a value's comments, which a path answer does not keep. |
| `not_path` | The filter is not a path and not `select(PATH op LITERAL)`. |
| `dialect_select` | `--from jsonc` scans plain paths only, as its texts print with their comments. |
| `select_redefined` | `select` is redefined, by the filter or by `~/.jq`. |
| `select_compare` | `select(F)`: F is not `PATH op LITERAL` with a scalar `LITERAL`. |
| `select_path` | `select(F)`: PATH is not a path the scan answers, or has a `[]`. |
| `not_columns` | `--from csv|tsv`: the filter does not name only columns. |
| `object_key` | An object key is not a constant, or repeats. |
| `object_member` | An object member is not a column of the input. |
| `select_columns` | `select(F)`: F reads more than named columns. |
| `own_spelling` | `--from json5`: a path answer would print a token as written (`'a'`, `0x1F`). |

`refused` lists them in this order. For `--from csv|tsv` they are the column route's, for any other input the scan's.

Why the scan handed a text back (`fallback`'s `why`):

| Token | Meaning |
| --- | --- |
| `step_kind` | A step met a value of another kind (`.a` over a number, `[]` over a string): jq's rules answer the text. |
| `bad_text` | The text does not parse as the scan reads it: the interpreter reports the fault. |
| `object_members` | A `[]` met an object, whose repeated keys jq gives once and the scan gives each time. |

The counts, `pieces` and `cost` differ between hosts and runs, and so do the times. `check` and `fmt`
refuse `--explain` as a usage error.

## `check`

`check` (or `validate`) validates its inputs and prints nothing when they are valid.

- It accepts every input that `stury .` reads without error, several texts included.
- It requires at least one JSON text. An empty or whitespace-only input fails with `No JSON text` and exit 5,
  where `stury .` reads it as a stream of no texts and exits 0.
- With no `FILE` on a terminal it prints the short usage and exits 2, as `stury` with no filter does.
- It stops at the first fault. A long input is judged on all cores and tells the fault a serial read tells.

| Flag | Effect |
| --- | --- |
| `--from ndjson`, `--seq` | Validate one record per line or per `0x1E` separator, each record being one text. `--seq` uses `check`'s records, not jq's text sequence; each `FILE` is read alone, so a text cut at a file's end is a fault. |
| `--from jsonc` | Validate JSONC as `stury --from jsonc .` reads it, to the same limits. A comment's text holds no escape. |
| `--from json5` | Validate JSON5 as `stury --from json5 .` reads it, to the same limits, except that `Infinity` and `NaN` pass (a filter run refuses them). |
| `--from csv`, `--from tsv` | Validate as `stury --from FORMAT .` reads. A fault is told as a filter run tells it ([CSV and TSV](#csv-and-tsv)). An empty input fails with `No CSV text` or `No TSV text`; a header alone is valid. |
| `--max-depth N` | As [above](#sturys-own-options). |
| `FILE...` | One file per argument, read as the filter reads them. |

`check` writes nothing, so `--to` with a format other than the default is a usage error.

Exit codes: 0 on success, 5 for invalid input, 2 for a usage or file error.

## `fmt`

`fmt` writes each input back in the printer's layout, or in another format. It runs no filter, so it takes no
`FILTER`.

```sh
stury fmt [--from FORMAT] [--to FORMAT] [--in-place|--check] [--indent N|--tab] [--max-depth N] [FILE...]
```

| Format | What `fmt` writes |
| --- | --- |
| `json`, `jsonc` (the default is `json`) | Each text laid out as `stury .` lays it out: pretty by default, `--indent N` (1 to 7) or `--tab` as given, keys in their order. Only the layout changes: every number and string is written as it was (`1e2`, `"\u00e9"`, `"\/"`) and every member of an object is kept, a repeated key included. JSONC keeps its comments where `stury --from jsonc --to jsonc .` puts them and drops its trailing commas, so a file already in that layout comes back byte for byte. |
| `ndjson` | One compact value per line, as `--to ndjson` writes it, spelled as above. |
| `csv`, `tsv` | The header, then one record per row, re-spelled by the CSV writer: a field that needs no quotes loses them, one that does gains them, and `""` and an empty cell stay distinct ([CSV and TSV output](#csv-and-tsv-output)). A header with no records is written. An object with a key the header lacks ends the run, as `--to csv` does. |

- `--from` chooses how each file is read, and `--to` how it is written; `--to` defaults to `--from`, so a plain
  `stury fmt FILE` formats `FILE` as JSON. Each half is chosen on its own, so `stury fmt --from csv --to json`
  reads CSV and writes pretty JSON.
- A transcode from `jsonc` to `json` or `ndjson` drops the comments. To `csv` or `tsv` a value becomes cells,
  spelled as `--to csv` spells them, a number as it was written.
- `fmt` is idempotent: `stury fmt` on its own output gives the same bytes. A leading byte order mark is not written.
- Each file is formatted as a table of its own: `stury fmt --from csv a.csv b.csv` writes each file's header,
  where `stury --from csv --to csv . a.csv b.csv` writes one table under the first file's header.
- `fmt` never colours its output, and it refuses every option that shapes a filter run (`-C`, `-c`, `-r`, ...,
  `--indent 0`): exit 2. `--indent N` and `--tab` apply to a JSON-like `--to`, and `--max-depth N` and, with a
  CSV-like `--to`, `--grow-header` apply. A JSON-like output is written to 1024 levels of nesting at most:
  `--max-depth` lets `fmt` read a deeper value, which it then refuses, with exit 5.

| Flag | Effect |
| --- | --- |
| `--check` | Write nothing. Exit 1 when any file's formatted bytes differ from its bytes (a compact JSON text, a CSV field that needs no quotes, a CRLF line ending), 0 when every file is already formatted. A fault still exits 5. |
| `--in-place` | Rewrite each file through a temporary file in its directory and a rename; mode (and owner and group where permitted) are kept; other hard links keep the old bytes. Only when `--to` is `--from`; refused with `--check`, with standard input, and on a non-regular file (exit 2). |
| `FILE...` | In argument order. A fault names the file and its position, as `check` does: `stury: parse error: FILE:L:C: ...`, and `stury: error: FILE:L:C: ...` under `--from jsonc`. A text that ends mid-value is told one byte past its end (`printf '[1] [2' | stury fmt` gives `<stdin>:1:7: Unfinished JSON term`), where a filter run tells it at the last byte. The run exits 5, and later files are not read. A file that does not open is reported and the run goes on, with exit 2. |
| no `FILE` | Reads standard input (`-`). On a terminal it prints the short usage and exits 2, as `check` does. `--in-place` refuses standard input. |

```sh
$ printf '{"a":1,"b":[1,2]}\n' | stury fmt
{
  "a": 1,
  "b": [
    1,
    2
  ]
}
$ printf '{"a":1, // inline\n"b":2}\n' | stury fmt --from jsonc
{
  "a": 1, // inline
  "b": 2
}
$ printf 'a,b\n"Ada","36"\n"x,y",z\n' | stury fmt --from csv
a,b
Ada,36
"x,y",z
$ stury fmt --check formatted.json && echo already formatted
$ stury fmt --in-place --tab source.json
$ stury fmt --from ndjson --to csv records.ndjson
```

- `--in-place` leaves a file already in the printer's layout untouched, its inode, mode and times included.
- CSV and TSV are read whole, as `check` reads them, so `--check` and `--in-place` see every byte of a file.
- A long JSON text whose bulk is one array, at its root or under its keys, is printed on all cores, with the output of a
  serial run.

## Formats

`--from` chooses how the input is cut into values, and `--to` how the outputs are written.

| Format | `--from` | `--to` |
| --- | --- | --- |
| `json` | One JSON text after another, as jq reads (the default). | Pretty-printed, or as `-c`, `--tab` and `--indent` say (the default). |
| `jsonc` | JSONC: comments and trailing commas ([Comments in the CLI](#comments-in-the-cli)). | Each value with the comments it was read with. |
| `json5` | JSON5 1.0.0, one text per input, read as written (comments kept). Numbers print in JSON's spelling. `Infinity` and `NaN` end the run, as they have no JSON value. Positions (`input_line_number`, error lines) count the JSON5 text; nesting follows `--max-depth`; `--argjson`, `--slurpfile`, `--jsonargs` and `fromjson` read JSON5. | Not written: `--to jsonc` writes the values and their comments. `fmt --in-place` and `fmt --check` are refused. |
| `ndjson` | One JSON text per line. A blank line is no text, and a line that is not one text, or holds two, is a parse error where jq would read on. | One compact value per line, as `-c`. |
| `csv`, `tsv` | The first record names the fields; each later record is one input ([CSV and TSV](#csv-and-tsv)). | Each output is one record ([CSV and TSV output](#csv-and-tsv-output)). |

- Each half is chosen on its own: `--from csv` alone prints JSON, and `--from csv --to csv` writes CSV back.
  `--from ndjson` alone reads lines and prints as `-c`, `--indent` and `--tab` say.
- Reading CSV or TSV is a usage error with `-R`, `--seq` and `--stream`. Writing it is one with `-r`, `-j`,
  `-a`, `-C`, `-c`, `--indent`, `--tab`, `--seq` and `--raw-output0`, which shape JSON text. `-S`, `-e`, `-n`,
  `-s`, `--arg` and the rest still apply to a filter run; `fmt` refuses them ([`fmt`](#fmt)). `--to ndjson` takes
  the place of `-c`, so it is refused with `--indent`, `--tab` and `--seq`.

## Input

### Grammar

Every input is read by one grammar, the library's: `json.validate` with `.Json`, or `.Jsonc` under `--from jsonc` and
`.Json5` under `--from json5`.

- **Nesting:** to `--max-depth N` levels (1024 by default, up to 2^20).
- **Numbers:** of any length and any exponent. A number is kept as it was written and read as a double only where a
  filter computes with it, so `1e400` prints as `1e400` and `1e400 + 0` is `1.7976931348623157e+308`.
- **Where it applies:** every input mode, `fromjson`, `--argjson`, `--jsonargs`, `--slurpfile` and `check`.
  So does `--from jsonc`; a `--slurpfile` file is then one document, as an input is.
- **Option JSON:** `--argjson` and `--jsonargs` keep jq's `invalid JSON text passed to` and add the fault, as
  in `invalid JSON text passed to --argjson: Exceeds depth limit for parsing at line 1, column 2`.

### Line-delimited input

- NDJSON needs no flag: several texts in a file are read as jq reads them. `--from ndjson` makes each line one text
  ([Formats](#formats)), and `stury check --from ndjson` validates the same lines.
- When a path with `[]` meets an element where the rest of the path has no match, it prints `null`, as in jq.
- A text on which jq would error is run through the general interpreter before any of its outputs print, so
  the errors and outputs are jq's.
- Coloured output (a terminal, or `-C`) builds containers and then paints them, which costs more than plain
  output.

### Long input

A file of 1 MiB or more is answered on all cores when the filter works on one record, or one entry, at a time. The
output, the exit status and the errors are those of a serial run: each piece's output is written in source order. The
pieces are:

- the records of a file: the lines of an NDJSON file, the texts of a file of concatenated texts, the records of a
  CSV or TSV file;
- the entries of the array that holds the bulk of one JSON text, at its root or under its keys, for a filter
  `.[]` or `.NAME.[]` followed by steps (`.logs[].id`, `.logs[] | select(.status > 400)`);
- the same array, for `.` and `fmt`, which print it in pieces under every layout option (`-c`, `--tab`, `--indent`, `-S`, `-a`), and for `length` and
  `.logs | length`, which count it.

A run stays on one thread under `-n`, `-s`, `-R`, `--stream`, `--stream-errors`, `--unbuffered`, `--grow-header`,
`--max-depth` past 1024, and a filter that calls `input`, `inputs`, `debug`, `stderr`, `halt`, `halt_error`,
`input_filename`, `input_line_number`, `recurse` with a filter, or a function that calls itself. The entries of an array
and the array printed or counted by `.`, `fmt` and `length` are read on all cores in a JSON text only, not JSONC or
JSON5, and `.` and `fmt` print an array in pieces only without colours, comments or CSV output. The records of a `--seq` input are read on one thread. A text with a fault, or
one that does not divide into pieces, is answered whole on one thread, which tells the fault. `--explain` shows
the count of pieces in `run`.

### `--follow`

`stury --follow FILTER FILE` answers each record as it is appended to `FILE`, like `tail -f FILE | stury FILTER` with
no pipe.

- It reads NDJSON, `--seq`, `-R`, several texts per file as jq reads them, CSV and TSV.
- A record cut short waits for its delimiter. The output is written after each record.
- A file that shrinks is read again from its start, with `stury: FILE: file truncated` on stderr.
- SIGINT and SIGTERM, and Ctrl-C or Ctrl-Break on Windows, end the run with the status of the records it answered.
- It is a usage error (exit 2) with standard input or more than one file, `-s`, `-n`, `--stream`, JSONC, JSON5,
  `check` and `fmt`.

### Records and events

| Option | Behaviour |
| --- | --- |
| `--seq` | Passes over a record that does not parse with `stury: ignoring parse error: ...` and puts `0x1E` before each output. |
| `--stream` | Gives jq's `[path, leaf]` and `[path]` events of each text. Of a text that does not parse it gives jq's events before the fault, then refuses the text as any input. |
| `--stream-errors` | Gives what jq gives of a faulty text: the events before the fault, then `[message, path]`. `[1,` gives `[[0],1]` and then `["Unfinished JSON term at EOF at line 1, column 3",[1]]`. Its messages, positions, exit code and `--seq` resync are jq's. |

### CSV and TSV

`--from csv` reads RFC 4180; `--from tsv` reads tab-separated values as jq's `@tsv` writes them. The first record of each
file is the header, and every later record is one input: an object whose keys are the header's names, in
order, and whose values are the cells' text as strings.

```sh
$ printf 'name,age\nAda,36\n"Grace ""Amazing"" Hopper",85\n' | stury --from csv -c .
{"name":"Ada","age":"36"}
{"name":"Grace \"Amazing\" Hopper","age":"85"}
$ stury --from csv -r '[.name, .age] | @csv' people.csv
```

- **Cells are strings or null.** A cell is never read as a number or a boolean; convert with `tonumber`
  (`.age | tonumber`). A quoted field is its text without the quotes, with `""` read as one quote, and may
  hold the delimiter and line breaks. An empty unquoted cell is `null` and a quoted `""` is `""`. In TSV,
  which has no quotes, every empty cell is `null`. `// ""` or `.a // empty` replaces a `null`. An empty line
  is no record, so a one-column file spells an empty cell `""`.
- **CSV** (`--from csv`) ends records at LF or CRLF. A quote opens a field only as its first byte. **TSV**
  (`--from tsv`) has no quoting. A quote is text, and `\t`, `\n`, `\r`, `\0` and `\\` read as a tab, LF, CR, NUL and backslash.
  Any other escape, or a backslash ending a cell, is a fault. A UTF-8 byte order mark at a file's start is
  skipped.
- **Each file has its own header**, and files may have different columns. `-s` slurps every record of
  every file into one array, and `-n` with `input` and `inputs` reads the records. `input_filename` and
  `input_line_number` name the file and the line the last record ends at.
- **Faults.** A header name given twice, a record with more or fewer fields than the first, a quote or
  carriage return where it cannot be, an unfinished quoted field, a bad escape and a byte that is not UTF-8
  end the file. The message is `FILE:LINE:COLUMN: fault` (`<stdin>` for standard input), with exit 5. The
  records before the fault have been answered. A record of the wrong width is told at the byte where its
  width is wrong, and says which way: `Record has more fields than the first record` at the delimiter that
  starts the extra field, `Record has fewer fields than the first record` at the line's end. An unfinished quoted
  field is reported at its opening quote.

  ```
  $ printf 'a,b\n1,2\n3\n' | stury --from csv -c .
  {"a":"1","b":"2"}
  stury: parse error: <stdin>:3:2: Record has fewer fields than the first record
  ```
- **Memory.** A regular file is read whole. A pipe is read a window at a time, and memory holds a window and the
  longest record. Records from a pipe are answered as they arrive, each once the reader holds the 64-byte block it
  ends in and three bytes more.
- **Column filters.** A filter that is only columns (`.name`, `.a, .b`, or `[.a, .b]` under `--from csv -c`;
  a key is a name `.name` can spell, or `.["any text"]`) prints each cell from the text without building an
  object. Its output is byte for byte the interpreter's; a name the header lacks prints `null`. The same
  holds for an object of columns (`{id, q: .qty}`, under `-c` or `--to csv|tsv`, not with `--grow-header`),
  for `.` under `-c`, and for `select(F)` when F reads only `.name` keys of the record
  (`select(.qty | tonumber >= 9000)`). There the interpreter is given only those cells, and each output prints
  the record. A whole file of a few hundred KiB or more is split across all cores and printed in file order.
  Any other filter, and `-n`, `-s`, `-e`, `-a`, `-C` and `--raw-output0`, run on the interpreter.

### CSV and TSV output

`--to csv` and `--to tsv` write each output as one record. The header is not an output. It is the first
object's keys, written once before the first row.

```sh
$ printf '{"a":1,"b":"x,y"}\n{"a":2,"b":null}\n' | stury --to csv .
a,b
1,"x,y"
2,
$ stury --from csv --to csv 'select(.n | tonumber > 1)' people.csv
```

- **Objects are rows.** The header is the first object's keys in their order, or sorted under `-S`. A later
  object with a key the header lacks ends the run: `output 2 has the key "z", which the header lacks (the header is output 1's keys; --grow-header adds keys as they come)`, exit 5,
  after the rows before it. A key the object lacks is an empty cell.
- **`--grow-header`** holds every output until the input ends, then writes a header of every key in the order
  first seen (in byte order under `-S`), and a row for each object with an empty cell for each key it lacks.
  Memory holds all the output. It is a usage error without `--to csv` or `--to tsv`.
- **Arrays and scalars are rows with no header.** An array's elements are the cells; a scalar is a row of one
  cell. Objects and the other kinds do not mix. The first output of the other kind ends the run.
- **Cells.** A string is its text, a number is spelled as it was written (`1E3`), `true` and `false` are
  themselves, and `null` and NaN are an empty cell. An array or object in a cell ends the run; the message
  suggests `tojson`. CSV quotes a cell that holds the delimiter, a quote or a line break, and writes the empty
  string as `""`; TSV escapes tab, LF, CR, NUL and backslash as `@tsv` does.
- **Null and the empty string.** CSV writes `null` as an empty cell and `""` as `""`, so `stury --from csv --to csv .` gives
  back what it read, up to normalisation (a quoted field that needed no quotes is written without). TSV writes
  both as an empty cell and reads every empty cell as null, so `""` becomes `null` there.
- **Refused records.** A record that cannot be written ends the run with the reason: no cell, or one empty
  cell (a lone `null`, `[]`, or `{}` under a one-key header), which would read back as an empty line; and in
  TSV, a first cell that starts with a byte order mark.
- **One table.** All the files of a run and all its inputs share one header.
- **Streaming.** Rows are written as the outputs come, except under `--grow-header`.

### Files and pipes

- A regular file is mapped and read whole. A file that shrinks while it is read is reported with its name.
- A pipe, FIFO or socket, and stdin under `--unbuffered`, is read as it comes, up to 8 MiB ahead. Each run of
  whole lines that has arrived is answered before the next.
- Output is written whenever the reader waits, so `tail -f log | stury .msg` answers each line as it lands.
- A text that runs past a block is read on until it ends, under `--seq` into the next file. Answers, messages,
  positions and exit codes are those of the whole read. Memory holds a block, what is read ahead and the
  longest text.
- `-s` and `--from jsonc` read stdin whole, as `check` does. `-n` with `inputs` keeps what it has read.
- Texts with no newline between them wait for one, as jq's line reads do.

## CSV and TSV recipes

Each command below runs on this `cities.csv`:

```
city,country,population
Oslo,NO,709000
Bergen,NO,286000
Uppsala,SE,177000
"Ho, Chi Minh",VN,
```

**Convert.** CSV to JSON, one object per record, every cell a string and the empty one `null`. `--to csv`
goes back. `-c` and `-r` shape JSON output, so `--to csv -c` is a usage error.

```sh
$ stury --from csv -c . cities.csv
{"city":"Oslo","country":"NO","population":"709000"}
{"city":"Bergen","country":"NO","population":"286000"}
{"city":"Uppsala","country":"SE","population":"177000"}
{"city":"Ho, Chi Minh","country":"VN","population":null}
$ stury --from csv -c 'select(.population) | .population |= tonumber' cities.csv
{"city":"Oslo","country":"NO","population":709000}
{"city":"Bergen","country":"NO","population":286000}
{"city":"Uppsala","country":"SE","population":177000}
$ printf '{"a":1}\n{"b":2}\n' | stury --to csv --grow-header .
a,b
1,
,2
```

Without `--grow-header`, the second object would end the run: `b` is a key the first object's header lacks.

**Filter rows.** `--to csv` writes CSV, header included, so a filter that keeps whole objects writes the matching
rows.

```sh
$ stury --from csv --to csv 'select(.country == "NO")' cities.csv
city,country,population
Oslo,NO,709000
Bergen,NO,286000
```

**Select columns.** An object with fewer keys is a table with fewer columns, and an array is a row with no
header.

```sh
$ stury --from csv --to csv '{city, population}' cities.csv
city,population
Oslo,709000
Bergen,286000
Uppsala,177000
"Ho, Chi Minh",
$ stury --from csv --to csv '[.city, .population]' cities.csv
Oslo,709000
Bergen,286000
Uppsala,177000
"Ho, Chi Minh",
```

**Aggregate.** `-s` slurps every record into one array for `group_by` and `add`. Cells are strings; convert
them before adding.

```sh
$ stury --from csv --to csv -s 'group_by(.country)[] | {country: .[0].country, cities: length, people: (map(.population | tonumber? // 0) | add)}' cities.csv
country,cities,people
NO,2,995000
SE,1,177000
VN,1,0
```

**TSV.** `tsv` reads and writes jq's `@tsv` text, and the two halves can mix formats.

```sh
$ stury --from csv --to tsv '{city, country}' cities.csv
city	country
Oslo	NO
Bergen	NO
Uppsala	SE
Ho, Chi Minh	VN
$ printf 'name\tage\nAda\t36\nGrace\t85\n' | stury --from tsv --to tsv 'select(.age | tonumber > 40)'
name	age
Grace	85
```

**Check.** A faulty file exits 5.

```sh
$ stury check --from csv cities.csv
$ printf 'a,b\n1,2\n3\n' | stury check --from csv
stury: error: <stdin>:3:2: Record has fewer fields than the first record
```

## Errors and exit codes

The exit codes are jq's, but the messages are stury's.

| Fault | Message |
| --- | --- |
| A file that cannot be opened | `stury: error: Could not open file NAME: REASON` |
| A directory given as a file | `stury: error: Is a directory` (as jq) |
| A text that does not parse | `stury: parse error: MSG at line L, column C` |
| The same, in a file after the first, and under `fmt` | `stury: parse error: NAME:L:C: SENTENCE`, counted in that file (a `--seq` text that runs between files has the stream's position instead) |
| Any fault under `check` or `--from jsonc`, `fmt` included | `stury: error: NAME:L:C: SENTENCE`, such as `<stdin>:1:7: Invalid numeric literal` |

L and C are the line and 1-based byte column of the byte the fault is at. Where a text that ends mid-value is
told, in a filter run and under `check` and `fmt`, is in [Different parse errors](#different-parse-errors).

A trailing comma, a comment or nesting past `--max-depth` is followed by the source line, a caret under the
byte, and the flag that would read it (`--from jsonc`, `--max-depth N`), in a filter run and under `check` alike.

| Code | Meaning |
| --- | --- |
| 1 | Under `-e`: the last output is `false` or `null`; under `fmt --check`: a file is not already formatted |
| 2 | A usage or file error |
| 3 | A filter that does not compile |
| 4 | Under `-e`: there is no output |
| 5 | Invalid input, or an error on the last input |

## Comments in the CLI

### Printing

Under `--from jsonc --to jsonc` the CLI prints a value's comments with the value when the filter takes that value from the
input unchanged: `.`, `.a`, `.[]`, `select`, `first`, `limit` and a variable all do. The comments print in
these places:

| Comment | Printed |
| --- | --- |
| leading | on the line before its entry |
| inline | between the key and the value |
| trailing | after the entry and its comma |
| footer | on the line before its container's close |

- A value the filter made (`{a: .a}`, `.a + 0`, `[.[]]`, `-s`'s array) prints without comments, and so does
  every value in it.
- Compact output ends each line comment with a line break, and an output that ends with one gets no second.
- `stury --from jsonc --to jsonc . FILE` keeps every comment of FILE. It gives a file back unchanged when the file is already
  in the printer's layout, including the space stury puts before a line comment and the compact spacing
  around a block comment.

### Reading

| Accessor | Gives |
| --- | --- |
| `.@comment` | the leading comments and, on a member's value, the inline ones |
| `.@comment_inline` | the comments after the value, on its line or past its comma (despite its name) |
| `.@comment_foot` | the footer comments |

- Each gives a list of texts in source order, each without its `//` or `/* */` and one space inside them
  (`// a` and `/* a */` read `"a"`), or `null` when there are none. That holds on a value the filter made
  and on any value of plain JSON.
- A document's leading comments lead its root and its trailing ones trail it. On `{"a": 1} // x` the root's
  `.@comment_inline` is `["x"]` and its `.@comment` is `null`, as no comment comes before it.
- They parse with or without `--from jsonc`, where jq refuses them. jq reads `.@name` only before a string
  (`.@base64 "x"`), and that still parses as jq's.
- They only read: `path(.@comment)` and `.@comment = 1` are errors. A comment sits beside a value rather
  than inside it, so jq's paths, and `=`, `|=` and `del` with them, have nothing to address. To change the
  comments of a file, use the library's `core.set_fact` and `core.remove_fact`.

## Differences from jq

stury reads strict RFC 8259 JSON and reports faults its own way. The rest of the language and the options are
jq's. jq has no `check` and no `fmt`, and `--from` and `--to` read and write formats jq does not. `.@comment`,
`.@comment_inline` and `.@comment_foot`, a syntax error in jq, read a value's comments ([Comments in the
CLI](#comments-in-the-cli)); outside `--from jsonc` they give `null`.

### Common differences

#### Stricter input

These inputs are rejected with exit 5 (2 for an option's text), where jq 1.8.2 accepts them:

- numbers and literals outside RFC 8259 (`01`, `1.`, `[1.]`, `.5`, `+1`, `NaN`, `nan`, `-nan`, `Infinity`,
  `+Infinity`, `-Infinity`, `infinity`), whether as input, `fromjson`'s text or an option's JSON;
- invalid UTF-8 in a string, which jq reads as U+FFFD;
- any byte after a value that is not whitespace or the next text, a NUL included (jq stops reading at a NUL);
- a lone low surrogate escape (`"\udc00"`), which jq reads as U+FFFD. jq refuses a lone high one too. Either
  is `Invalid escape` at its backslash.

#### Shallower nesting by default

Nesting past 1024 levels (jq: 10000) is refused, `fromjson` included, unless `--max-depth` raises the limit.

#### Different parse errors

A parse error names the fault (`Invalid numeric literal`, `Unexpected character`, `Unfinished JSON term`,
`Invalid escape`, `Unexpected text after the JSON value`, `Exceeds depth limit for parsing`, ...) at the line
and column of the byte it was found at. A text that ends mid-value is told at its last byte, which is jq's
position, so the plain path and `--stream-errors` agree at the end of the input. `fromjson`, the option JSON and a
module's data file say the same. `check` and `fmt` keep the library's one past it
([Errors and exit codes](#errors-and-exit-codes)).

| | stury | jq |
| --- | --- | --- |
| Message | names the fault | jq's own wording |
| Position | the byte the fault is at | where its parser stood after that byte |
| At the end of input | the last byte | the last byte |
| At a newline (`1e` then a newline) | line 1, column 3 | line 2, column 0 |

`fromjson` keeps jq's `Expected JSON value` and `Unexpected extra JSON values`.

#### Files are read separately

Each file ends its texts, except under `--seq` ([below](#--seq-reads-each-record-as-one-text)). jq reads `1` in
one file and `2` in the next as `12`. A parse error in a file after the first names the file
and counts its line and column in that file (`b.json:1:4: Unexpected character`), where jq counts on across the
files it joins; a text that runs from one file into the next under `--seq` is the exception, and is told at its
line and column in the stream, without a file's name.

#### `--seq` reads each record as one text

- The bytes up to the next `0x1E` are one text. A record of two texts is a parse error and is skipped whole
  (`␞{}{}` prints nothing), where jq reads several texts in a record and passes silently over an unfinished array
  or object.
- The files are one byte stream: a text cut at a file's end goes on in the next file, and a separator in a later
  file ends it, as jq reads them. A text that is whole where its file ends is not read on: `1` and a newline in
  one file and `2` in the next are two texts. A number or literal with nothing after it is read on, as it may go
  on (`1` then `2` in the next file is `12`). The files are opened as the text reaches them, a window at a time
  for a stream, never all up front.
- Before the stream's first `0x1E` no text is a record: it is refused like any faulty record (`ignoring parse
  error: Text before the first RS at line L, column C`, and the stream reads on), where jq drops it silently.
  Once a separator has been seen, a later file's text is a record, whatever its first byte.

### Edge cases

**Nesting and byte order marks**

- `--max-depth 10000` refuses where jq does, except that jq counts an object's level twice, so it refuses 5001
  nested objects, which stury reads. Past 10000 levels a value prints as jq prints one, `<skipped: too
  deep>`.
- A byte order mark cut short at the start of the stream, which jq passes over, or split across two files,
  which jq joins, is rejected. Under `--stream-errors` the cut mark is passed over as jq does, with jq's
  `Malformed BOM` (and, under `--seq`, its parser that starts afresh at every call).

**Filters**

- In a filter's string literal (an interpolated string and an object key included) a lone low surrogate is a
  compile error, `Invalid escape`, where jq reads U+FFFD. A lone high one is refused, as jq refuses it.
- After a parse error, `input` reads on from the next line, where jq reads on from its next 4 KiB read.
- `input_line_number` and an error's line count through the end of the line a text ends on. jq counts through
  its last 4 KiB read, which on a longer line has not reached the line's end, so it reports 0 there.
- `range/3` refuses a bound or step that is not a number (`Range bounds must be numeric`), as jq's `range/2`
  does; jq's `range/3` adds it with `+` (`[range(null; 3; 1)]` is `[null,1,2]` there).
- `range` with a NaN bound or step gives no values. jq gives none for some (`[range(0; 3; nan)]`), counts on
  for others (`[limit(3; range(0; nan))]` is `[0,1,2]`, `[range(0; -3; nan)]` is `[0]`) and, for
  `[range(nan)]`, aborts on an assertion.
- jq's `--run-tests` is absent, since stury has no test-file runner.

**`--stream` and `--seq`**

- `--stream` gives each scalar the full path to it, as jq does, so a value nested n levels deep gives Θ(n²)
  bytes of events (nested empty arrays: about 1 MB at depth 1000, 100 MB at 10000). There is no clamp;
  `--max-depth` bounds it.
- A number cut by `0x1E` or the stream's end is refused under `--stream` too (`Potentially truncated
  top-level numeric value`), where jq reads it. `check --seq` refuses it the same way.
- `check` fails on an input of no text (`No JSON text`), but under `--seq` an empty input, like one of
  separators alone, is no records and passes. `stury .` reads such an input as jq does.
- Under `--seq`, separators with only whitespace after them are no record, and a BOM at the input's first
  byte is stepped over, as jq does. Whitespace before the first `0x1E` is not a text, in jq or in stury.

**Numbers**

- A number is printed as it was written, where jq prints decNumber's canonical spelling (`1e3` and `1E+3`, `0.1e1` and
  `1`, `12.5e-1147483647` and `1E-1146...`). Two literals are compared by value, as jq compares them (`1.0` equals
  `1`, and `100000000000000000001` is above `100000000000000000000`).
- `sort` over mixed number literals past a double's range, which jq compares in a way that depends on where each
  starts, does not give jq's order:

  ```
  [1e1000000000,1e1000000001,1.7976931348623157e309,1e400] | sort
  stury: [1e1000000000,1e1000000001,1.7976931348623157e309,1e400]
  jq:    [1.7976931348623157E+309,1E+400,1.7976931348623157e+308,1.7976931348623157e+308]
  ```

- An integer literal of 18 or more digits is rounded to the nearest double. jq 1.8.2 can be one unit in the last
  place off: `712598146987295425 + 0` is `712598146987295500` in stury and `712598146987295400` in jq, and
  `1287579022434948980 % 7` is 5 in stury and 2 in jq. Python's `float()` gives stury's values.

**Dates and times**

- A time past year 2^31 keeps its year: `67767976233532800 | todate` is `"2147483648-01-01T00:00:00Z"`, where jq
  wraps the year to a negative one (`"-2147481748-01-01T00:00:00Z"`).
- `now` has sub-microsecond resolution where the clock has it, so `now - now` need not be 0.
- `strftime`, `todate` and `mktime` of a broken-down UTC time read it as UTC on every OS (`0 |
  strftime("%z %s")` is `+0000 0` whatever `TZ` is); jq does so on macOS only. `strflocaltime` stays local.
- `scalb` and `scalbln` cut a fractional exponent toward zero and saturate a huge one on every OS, as jq on
  macOS does: `[scalb(1;2.5), scalbln(1;1e30)]` is `[4,1.7976931348623157e+308]`. glibc's jq gives
  `[null,0]`.
- `gamma` is log-gamma on every OS, as glibc's `gamma` is (so jq on Linux): `[1, 2] | map(gamma)` is `[0,0]`.
  macOS has no `gamma` in libm, and jq there answers `tgamma`, `[1,1]`.
- `strptime` gives, on every OS, the weekday and yearday as the calendar's values for the array's own year,
  month and day. A day the format does not read is taken as day 0 (`"12:30:00" | strptime("%T")` is weekday
  0, yearday -1: 1899-12-31 was a Sunday). jq's weekday on macOS does not match the calendar for dates in or
  before 1900 (`"1900-01-01"` is 0 there and 1 in stury).

### Regular expressions

Regular expressions run on stury's own engine for Oniguruma syntax, and answer as jq's do for look-around,
backreferences and conditions, named groups, `\g<name>` calls, the absent operator, callouts, case folds that
change a text's length, and the script, emoji and other Unicode properties. Two cases answer differently:

- a lazy `{n,}?` with n of 2 or more over a body that can match the empty string and holds a capture;
- a callout that reads which start positions are tried (`(*ERROR)` with a code other than -1, `(*TOTAL_COUNT)` read
  back), since Oniguruma's choice of starts depends on its optimizer.

## For library users

The CLI reads input as `json.build` and `json.validate` do with their defaults (`.Json`, `core.Duplicates.Last`), and
its numbers are uncapped. It differs from the library on purpose:

| | CLI | Library |
| --- | --- | --- |
| A key repeated in one object | keeps its last value and cannot be refused | `core.Duplicates.First` or `.Last` on a read, `every_key` for each, and `refuse_duplicates` on a build |
| Strings and keys | jq's escapes (`"\/"` is `"/"`), DEL as `\u007f`. Of a repeated key, only the last value prints, at the first one's position | the source text, DEL as the byte unless the writer's `escape_del` is set, and `respell_strings` to write them in the writer's own escapes |
| Numbers | printed as written (`1E2` stays `1E2`); when computed, as jq's double layout | the source text |

- A JSONC document keeps its comments as facts, and `core.write` puts them back where they were read, as
  `stury --from jsonc --to jsonc` prints them (a repeated key with its last value's). That does not apply to
  `marshal` of an `any`.
- The CLI runs a filter by one of three routes, which `--explain` names: the path scan, the column route and the
  interpreter ([`--explain`](#--explain)). The path scan is the library's `records.scan`, and the interpreter runs over a
  document built whole.
