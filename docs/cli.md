# stury command line

`stury` is a jq-compatible JSON processor. It runs jq 1.8 filters and gives jq's results and exit codes. Its
messages start with `stury:`, and parse errors are worded its own way ([Errors and exit
codes](#errors-and-exit-codes)). On top of jq it:

- validates JSON without running a filter (`stury check`);
- reads and writes JSONC, NDJSON, CSV and TSV (`--from FORMAT`, `--to FORMAT`, [Formats](#formats));
- reads input strictly, as RFC 8259 says ([Differences from jq](#differences-from-jq)).

The examples below assume `stury` is on your `PATH`; otherwise use `build/stury` (`make build-cli`).

```sh
stury [-c] [-r] [-j] [--raw-output0] [-a] [-S] [-C|-M] [--tab|--indent N] [--unbuffered] [-b]
      [-n] [-R] [-s] [-e] [-f FILE] [-L DIR] [--seq] [--stream|--stream-errors]
      [--from FORMAT] [--to FORMAT] [--grow-header]
      [--max-depth N]
      [--arg NAME VALUE] [--argjson NAME JSON] [--slurpfile NAME FILE] [--rawfile NAME FILE]
      [FILTER] [FILE...] [--args STRING...|--jsonargs JSON...]
stury check [--from FORMAT|--seq] [--strict-limits] [--max-depth N] [FILE...]
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
| `--from FORMAT` | Read `json` (the default), `jsonc`, `ndjson`, `csv` or `tsv` ([Formats](#formats)). |
| `--to FORMAT` | Write `json` (the default), `jsonc`, `ndjson`, `csv` or `tsv` ([Formats](#formats), [CSV and TSV output](#csv-and-tsv-output)). |
| `--grow-header` | With `--to csv` or `--to tsv`, write a header of every key of every object output ([CSV and TSV output](#csv-and-tsv-output)). |
| `--max-depth N` | Refuse nesting past N levels (1024 by default, up to 2^20, where jq's limit is 10000). |
| `--strict-limits` | `check` only. Keep the library's limits, for input bound for the library: numbers of at most 256 digits and a scale of at most 4096. Nesting follows `--max-depth` either way. |

### Options that differ from jq

| Option | Behaviour |
| --- | --- |
| `-C`, `-M` | `-C` colours output with jq's defaults or `JQ_COLORS`. It is on by default when stdout is a terminal and `NO_COLOR` is unset; `-M` turns it off. |
| `--tab`, `--indent N` | `--indent 0` prints each line with no indent, as jq does. N is -1 to 7; -1 is `--tab`. |
| `-b` | Does nothing outside Windows. |
| `-V` | Prints `stury-` and the version it was built with: the release version (for example `0.0.2`), or the short commit hash from a source build (`dev` outside a checkout). |
| `--help` | It and the short usage point to stury(1) (`docs/stury.1`) and this page. |

### Behaviour notes

- Plain paths such as `.a.b[]` are answered without building the document. These options switch to the
  general interpreter, which may be slower on large inputs: `-n`, `-s`, `-S`, `-a`, `-e`, `-R`,
  `--raw-output0`, `--seq`, `--stream`.
- Under `--from csv` or `--from tsv`, a filter that only picks columns (`.name`, `.a, .b`, `[.a, .b]`,
  `{a, b: .c}`, `.`, or `select(F)` where `F` reads named columns) is answered from each record's cells,
  without building an object, and on threads for a large file. Any other filter runs on the interpreter.
- A key repeated in one object is read as jq reads it: the last value wins.
- A scalar result is printed as jq prints it, not as its source text (`1E2` is `1E+2`, `"\/"` is `"/"`).

## `check`

`check` (or `validate`) validates its inputs and prints nothing when they are valid.

- It accepts every input that `stury .` reads without error, several texts included, except under `--seq`,
  where it reads each file on its own: a record cut at a file's end is a fault there ([Records and
  events](#records-and-events)).
- It requires at least one JSON text. An empty or whitespace-only input fails with `No JSON text` and exit 5,
  where `stury .` reads it as a stream of no texts and exits 0.
- With no `FILE` on a terminal it prints the short usage and exits 2, as `stury` with no filter does.

| Flag | Effect |
| --- | --- |
| `--from ndjson`, `--seq` | Validate one record per line or per `0x1E` separator, each record being one text. `--seq` uses `check`'s records, not jq's text sequence, and reads `FILE` one at a time: a text cut at a file's end is a fault, where the filter reads the files as one stream. |
| `--from jsonc` | Validate JSONC as `stury --from jsonc .` reads it, to the same limits. A comment's text holds no escape. |
| `--from csv`, `--from tsv` | Validate as `stury --from FORMAT .` reads. CSV and TSV are judged by `csv.validate`, and a fault is told as a filter run tells it ([CSV and TSV](#csv-and-tsv)). An input with no record fails with `No CSV text` or `No TSV text`. |
| `--strict-limits`, `--max-depth N` | As [above](#sturys-own-options). |
| `FILE...` | One file per argument, read as the filter reads them. |

`check` writes nothing, so `--to` with a format other than the default is a usage error.

Exit codes: 0 on success, 5 for invalid input, 2 for a usage or file error.

## Formats

`--from` chooses how the input is cut into values, and `--to` how the outputs are written.

| Format | `--from` | `--to` |
| --- | --- | --- |
| `json` | One JSON text after another, as jq reads (the default). | Pretty-printed, or as `-c`, `--tab` and `--indent` say (the default). |
| `jsonc` | JSONC: comments and trailing commas ([Comments in the CLI](#comments-in-the-cli)). | Each value with the comments it was read with. |
| `ndjson` | One JSON text per line. A blank line is no text, and a line that is not one text, or holds two, is a parse error where jq would read on. | One compact value per line, as `-c`. |
| `csv`, `tsv` | The first record names the fields; each later record is one input ([CSV and TSV](#csv-and-tsv)). | Each output is one record ([CSV and TSV output](#csv-and-tsv-output)). |

- Each half is chosen on its own: `--from csv` alone prints JSON, and `--from csv --to csv` writes CSV back.
  `--from ndjson` alone reads lines and prints as `-c`, `--indent` and `--tab` say.
- Reading CSV or TSV is a usage error with `-R`, `--seq` and `--stream`. Writing it is one with `-r`, `-j`,
  `-a`, `-C`, `-c`, `--indent`, `--tab`, `--seq` and `--raw-output0`, which shape JSON text. `-S`, `-e`, `-n`,
  `-s`, `--arg` and the rest still apply. `--to ndjson` takes the place of `-c`, so it is refused with `--indent`, `--tab` and `--seq`.

## Input

### Grammar

Every input is read by one grammar, the library's: `validate` with `dialect = .Json`, or `.Jsonc` under
`--from jsonc`.

- **Nesting:** to `--max-depth N` levels (1024 by default, up to 2^20).
- **Numbers:** of any length, with an exponent up to 2^31-1. A larger one is refused as out of range.
- **Where it applies:** every input mode, `fromjson`, `--argjson`, `--jsonargs`, `--slurpfile` and `check`.
  So does `--from jsonc`; a `--slurpfile` file is then one document, as an input is.
- **Option JSON:** `--argjson` and `--jsonargs` keep jq's `invalid JSON text passed to` and add the fault, as
  in `invalid JSON text passed to --argjson: Exceeds depth limit for parsing at line 1, column 2`.

### Line-delimited and large input

- NDJSON needs no flag: stury detects it, and answers a path or a compact `.` over it on several threads.
  `--from ndjson` makes each line one text ([Formats](#formats)), and `stury check --from ndjson` validates the same
  lines.
- Over a large top-level array, `.[] PATH` and `.key[] PATH` also run on several threads. When a path with
  `[]` meets an element where the rest of the path has no match, it prints `null`, as in jq.
- A text on which jq would error is run through the general interpreter before any of its outputs print, so
  the errors and outputs are jq's.
- Coloured output (a terminal, or `-C`) builds containers and then paints them, which costs more than plain
  output.

### Records and events

| Option | Behaviour |
| --- | --- |
| `--seq` | Passes over a record that does not parse with `stury: ignoring parse error: ...` and puts `0x1E` before each output. The files are one byte stream, a text cut at a file's end read on in the next ([`--seq` reads each record as one text](#--seq-reads-each-record-as-one-text)). |
| `--stream` | Gives jq's `[path, leaf]` and `[path]` events of each text once it parses whole, and refuses a text that does not parse, as any input. |
| `--stream-errors` | Gives what jq gives of a faulty text: the events before the fault, then `[message, path]`. `[1,` gives `[0],1` and then `["Unfinished JSON term at EOF at line 1, column 3",[1]]`. Its messages, positions, exit code and `--seq` resync are jq's. |

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
- **Faults.** A header name given twice, a record with a field count other than the header's, a quote or
  carriage return where it cannot be, an unfinished quoted field, a bad escape and a byte that is not UTF-8
  end the file. The message is `FILE:LINE:COLUMN: fault` (`<stdin>` for standard input), with exit 5. The
  records before the fault have been answered. An unfinished quoted field is reported at its opening quote;
  the library reports `.Truncated` at the end of the text.

  ```
  $ printf 'a,b\n1,2\n3\n' | stury --from csv -c .
  {"a":"1","b":"2"}
  stury: parse error: <stdin>:3:1: Record has the wrong number of fields (the header has 2)
  ```
- **Memory.** A regular file up to 64 MiB is read whole, except under `-n`. A larger file, a file under `-n`
  and a pipe are read a window at a time. Memory holds a window and the longest record. Records from a pipe
  are answered as they arrive, each once the reader holds the 64-byte block it ends in and three bytes more.
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
  object with a key the header lacks ends the run: `output 2 has the key "z", which the header lacks`, exit 5,
  after the rows before it. A key the object lacks is an empty cell.
- **`--grow-header`** holds every output until the input ends, then writes a header of every key in the order
  first seen (in byte order under `-S`), and a row for each object with an empty cell for each key it lacks.
  Memory holds all the output. It is a usage error without `--to csv` or `--to tsv`.
- **Arrays and scalars are rows with no header.** An array's elements are the cells; a scalar is a row of one
  cell. Objects and the other kinds do not mix. The first output of the other kind ends the run.
- **Cells.** A string is its text, a number is spelled as jq spells it (`1E+3`), `true` and `false` are
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

- A regular file is read whole, except in two cases where it is streamed: under `-n`, and a file past
  64 MiB whose first line looks like one JSON value (`{...}` or `[...]`).
- A pipe, FIFO or socket, and stdin under `--unbuffered`, is read as it comes, in 64 KiB blocks, up to
  8 MiB ahead. Each run of whole lines that has arrived is answered before the next.
- Output is written whenever the reader waits, so `tail -f log | stury .msg` answers each line as it lands.
- A text that runs past a block is read on until it ends. Answers, messages, positions and exit codes are
  those of the whole read. Memory holds a block, what is read ahead and the longest text. Under `--seq` a text
  that runs past a file's end is read on into the next file, a window at a time and only up to the separator
  that ends it; the files are never read up front.
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
stury: error: <stdin>:3:1: Record has the wrong number of fields (the header has 2)
```

## Errors and exit codes

The exit codes are jq's, but the messages are stury's.

| Fault | Message |
| --- | --- |
| A file that cannot be opened | `stury: error: Could not open file NAME: REASON` |
| A directory given as a file | `stury: error: Is a directory` (as jq) |
| A text that does not parse | `stury: parse error: MSG at line L, column C` |
| The same, in a file after the first | `stury: parse error: NAME:L:C: SENTENCE`, counted in that file (a `--seq` text that runs between files has the stream's position instead) |
| Any fault under `check` or `--from jsonc` | `stury: error: NAME:L:C: SENTENCE`, such as `<stdin>:1:7: Invalid numeric literal` |

L and C are the line and 1-based byte column of the byte the fault is at. A text that ends mid-value is told at
its last byte, as jq tells it (the position `--stream-errors` gives). One past the last byte instead is the
library's `error_position`, which `check` prints, and so do `fromjson`, `--argjson`, `--jsonargs`, `--slurpfile`
and a module's data file.

A trailing comma, a comment or nesting past `--max-depth` is followed by the source line, a caret under the
byte, and the flag that would read it (`--from jsonc`, `--max-depth N`), in a filter run and under `check` alike.

| Code | Meaning |
| --- | --- |
| 1 | Under `-e`: the last output is `false` or `null` |
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
  comments of a file, use the library's `edit_comment`.

## Differences from jq

stury reads strict RFC 8259 JSON and reports faults its own way. The rest of the language and the options are
jq's.

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
position, so the plain path and `--stream-errors` agree at the end of the input. `check`, `fromjson`, the option
JSON and a module's data file keep the library's one past it ([Errors and exit codes](#errors-and-exit-codes)).

| | stury | jq |
| --- | --- | --- |
| Message | names the fault | jq's own wording |
| Position | the byte the fault is at | where its parser stood after that byte |
| At the end of input | the last byte | the last byte |
| At a newline (`1e` then a newline) | line 1, column 3 | line 2, column 0 |

`fromjson` keeps jq's `Expected JSON value` and `Unexpected extra JSON values`.

#### Files are read separately

Each file ends its texts, except under `--seq`, which reads them as one stream ([`--seq` reads each record as
one text](#--seq-reads-each-record-as-one-text)). jq reads `1` in one file and `2` in the next as `12`, and
continues a text cut at a file's end in the next file. A parse error in a file after the first names the file
and counts its line and column in that file (`b.json:1:4: Unexpected character`), where jq counts on across the
files it joins; a text that runs from one file into the next under `--seq` is the exception, and is told at its
line and column in the stream, without a file's name.

#### `check`, `--from` and `--to` are new

jq has no `check`. `--from` and `--to` read and write formats jq does not. `.@comment`, `.@comment_inline` and
`.@comment_foot`, a syntax error in jq, read a value's comments ([Comments in the CLI](#comments-in-the-cli));
outside `--from jsonc` they give `null`.

#### `--seq` reads each record as one text

- The bytes up to the next `0x1E` are one text. A record of two texts is a parse error, where jq reads several
  texts in a record and passes silently over an unfinished array or object.
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
- jq's `--run-tests` is absent, since stury has no test-file runner.

**`--stream` and `--seq`**

- `--stream` gives each scalar the full path to it, as jq does, so a value nested n levels deep gives Θ(n²)
  bytes of events (nested empty arrays: about 1 MB at depth 1000, 100 MB at 10000). There is no clamp;
  `--max-depth` bounds it.
- `--stream` gives no events of a text that does not parse, where jq gives the events before the fault.
  `--stream-errors` gives them, as jq does.
- A number cut by `0x1E` or the stream's end is refused under `--stream` too (`Potentially truncated
  top-level numeric value`), where jq reads it. `check --seq` refuses it the same way.
- `check` fails on an input of no text (`No JSON text`), but under `--seq` an empty input, like one of
  separators alone, is no records and passes. `stury .` reads such an input as jq does.
- Under `--seq`, separators with only whitespace after them are no record, and a BOM at the input's first
  byte is stepped over, as jq does. Whitespace before the first `0x1E` is not a text, in jq or in stury.

**Numbers**

- `sort` over mixed out-of-range number literals gives a consistent order. jq's comparison of such literals
  is not transitive, so its order depends on where each starts:

  ```
  [1e1000000000,1e1000000001,1.7976931348623157e309,1e400] | sort
  stury: [1.7976931348623157e+308,1.7976931348623157e+308,1.7976931348623157E+309,1E+400]
  jq:    [1.7976931348623157E+309,1E+400,1.7976931348623157e+308,1.7976931348623157e+308]
  ```

- A literal near decNumber's bottom exponent keeps its digits: `12.5e-1147483647` is `1.25E-1147483646` in
  stury, where jq rounds it to `1E-1147483646`.

**Dates and times**

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

Regular expressions run on stury's own engine for Oniguruma syntax. It leaves out:

- one-to-many case folds;
- `\g<name>` calls;
- script and emoji properties;
- the absent operator;
- captures from empty iterations of counted repeats.

Each is refused or answered differently, never silently changed.

## For library users

The CLI reads input as the library's `validate` and `build` do with their defaults (`.Json`, `.Strict`,
duplicates `.Last`), and its numbers are uncapped (`check --strict-limits` keeps the library's limits). It
differs from the library on purpose:

| | CLI | Library |
| --- | --- | --- |
| A key repeated in one object | keeps its last value (`.Last`) and cannot be refused: the CLI is built with `-define:REFUSE_DUPLICATES=false` | any `Duplicates` policy, `.Refuse` included |
| Scalars and keys | printed as jq prints them. Of a repeated key, only the last value prints, at the first one's position | `marshal` of a `Document` copies each from the source |
| Numbers | printed as decNumber formats them (`1E2` is `1E+2`, `0.1e1` is `1`, `1e1000` is `1E+1000`); past decNumber's range, or when computed, as jq's double layout | the source text |
| Strings | jq's escapes (`"\/"` is `"/"`, DEL is `\u007f`) | the source text |

- To match `stury -c`, set `jq_spelling = true, trailing_newline = true`; the `indent`, `ascii_only` and
  `escape_html` options still apply. To match `stury -S`, set `jq_spelling = true, sort_keys = true,
  pretty = true, indent = 2, trailing_newline = true`.
- A JSONC `Document` keeps its comments as `stury --from jsonc --to jsonc` prints them (a repeated key with its last value's).
  That does not apply to `marshal` of an `any`.
- The CLI prints through the library's writer in `json/encode`.
- How the CLI runs a filter is described in [docs/codec.md](codec.md#9-how-the-cli-runs-a-filter).
