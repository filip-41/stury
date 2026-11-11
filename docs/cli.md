# stury command line

`stury` is a jq-compatible JSON processor. It runs jq 1.8 filters and gives jq's results and exit codes. Its
messages start with `stury:`, and parse errors are worded its own way ([Errors and exit
codes](#errors-and-exit-codes)). On top of jq it:

- validates JSON without running a filter (`stury check`);
- writes each input back in the printer's layout, or transcodes it (`stury fmt`);
- edits each input with a jq filter, keeping every byte the edit does not touch (`stury edit`);
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
stury check [--from FORMAT|--seq] [--max-depth N] [--schema FILE [--schema-ref DIR] [--format-assert]
            [--max-errors N] [--report lines|basic|problem]] [FILE...]
stury check --filter FILTER --schema FILE [--from FORMAT] [-n] [-s] [-R] [--arg...] [-c]
stury fmt [--from FORMAT] [--to FORMAT] [--schema FILE [--schema-ref DIR] [--format-assert] [--max-errors N]] [--in-place|--check] [--indent N|--tab] [--max-depth N] [FILE...]
stury edit [--from FORMAT|--seq] [--in-place|--check|--diff] [--max-depth N] [-f FILE] [-L DIR] [--arg...] FILTER [FILE...]
stury diff [--from FORMAT] [--set|--position] [--key [PATH=]MEMBER]... [--facts] [--json] OLD NEW
stury diff --old-schema FILE --new-schema FILE [--compat backward|forward|full] [--json]
stury diff --old-schema FILE DATA | stury diff DATA --new-schema FILE
stury diff --shape [--from FORMAT] OLD NEW
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
stury: parse error: <stdin>:1:10: Leading zero in a number
{"foo": 01}
         ^

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

stury takes all of jq's options except `--run-tests`, `--debug-dump-disasm` and `--debug-trace` (jq's test-file
runner and its bytecode listings, which stury does not have) and adds its own. Each letter has jq's long form
(`--compact-output`, `--null-input`, `--from-file`, `--library-path`, ...); the synopsis above gives the full list.
`FILTER` is a jq 1.8 program, modules included (`import`, `include`, `-L`, `~/.jq`).

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
| `edit` | A subcommand, recognised as `check` is: runs the filter on each input and splices its one output into the input's bytes. See [`edit`](#edit). |
| `--from FORMAT` | Read `json` (the default), `jsonc`, `json5`, `ndjson`, `csv` or `tsv` ([Formats](#formats)). |
| `--to FORMAT` | Write `json` (the default), `jsonc`, `ndjson`, `csv` or `tsv` ([Formats](#formats), [CSV and TSV output](#csv-and-tsv-output)). `fmt` writes the `--from` format when `--to` is not given. |
| `--in-place` | `fmt` and `edit` only: rewrite each file through a temporary one and a rename, when `--to` is `--from` ([`fmt`](#fmt), [`edit`](#edit)). |
| `--check` | `fmt` and `edit` only: write nothing, name each file that would change on stderr, and exit 1 ([`fmt`](#fmt), [`edit`](#edit)). |
| `--grow-header` | With `--to csv` or `--to tsv`, write a header of every key of every object output ([CSV and TSV output](#csv-and-tsv-output)). |
| `--delimiter C`, `--no-header`, `--comment C`, `--infer`, `--ragged`, `--lazy-quotes` | How `--from csv` or `--from tsv` reads ([CSV and TSV options](#csv-and-tsv-options)). |
| `--out-delimiter C`, `--out-comment C`, `--out-no-header`, `--crlf` | How `--to csv` or `--to tsv` writes ([CSV and TSV options](#csv-and-tsv-options)). |
| `--max-depth N` | Refuse nesting past N levels (1024 by default, up to 2^20, where jq's limit is 10000). A value deeper than the default also runs on one thread. |
| `--follow` | With one named file, answer each record as it is appended, like `tail -f FILE | stury FILTER` without the pipe ([`--follow`](#--follow)). |
| `--explain` | Write the plan the filter runs under and what the run did to stderr ([`--explain`](#--explain)), and run the filter as without it. |

### Options that differ from jq

| Option | Behaviour |
| --- | --- |
| `-C`, `-M` | `-C` colours output with jq's defaults or `JQ_COLORS`. It is on by default when stdout is a terminal and `NO_COLOR` is unset; `-M` turns it off. Under `--to jsonc` the output is not coloured, since only the uncoloured printer keeps the comments. |
| `--tab`, `--indent N` | `--indent 0` prints each line with no indent, as jq does. N is -1 to 7; -1 is `--tab`. |
| `-b` | Does nothing outside Windows. |
| `-V` | Prints `stury-` and the version it was built with: the release version (for example `0.1.1`), or the short commit hash from a source build (`dev` outside a checkout). |
| `--help` | It and the short usage point to stury(1) (`docs/stury.1`) and this page, and list `check` and `fmt` under Commands. `stury check --help` and `stury fmt --help` give that command's own help. A usage error ends with `or see stury(1), or docs/cli.md at https://github.com/filip-41/stury`, where jq names its manpage and jqlang.org. |

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

`--explain` writes `stury: explain: KEY: SENTENCE` lines to stderr and runs the filter as it would without the
option: the same stdout, the same exit status, the same other stderr. The plan block is written once the plan is
chosen, before any input is read; the run block when the run ends, whether it ends normally or on an error. A filter
that does not compile has the `filter` line and its compile error alone.

```sh
$ stury --explain -c '.logs[].id' in.json
stury: explain: filter: ".logs[].id"
stury: explain: input: JSON texts one after another, a repeated key keeping its last value
stury: explain: plan: reads only the path .logs[].id of each text, without building the values it passes by
stury: explain: decides: the bytes read decide the speed, and memory holds only the answers
1
2
stury: explain: ran: 1 input, 1 read by path and 0 built
stury: explain: threads: one
stury: explain: time: planned in 65us, ran in 123us
stury: explain: used: 3555328 bytes of memory at the peak, 35 bytes read, 4 bytes written
$ stury --explain -c '.a | tostring' in.json
stury: explain: filter: ".a | tostring"
stury: explain: input: JSON texts one after another, a repeated key keeping its last value
stury: explain: plan: builds each text whole and runs the filter on it
stury: explain: because: the filter is not a path, and not select(PATH op LITERAL)
stury: explain: decides: the filter's work on each built value decides the speed, and memory holds one built input at a time
"1"
stury: explain: ran: 1 input, each built
stury: explain: threads: one
stury: explain: time: planned in 86us, ran in 102us
stury: explain: used: 3768320 bytes of memory at the peak, 35 bytes read, 4 bytes written
```

The keys come in this order, each line once unless said:

| Key | Says |
| --- | --- |
| `filter` | The filter, quoted. Written as soon as it is known, so a compile error follows it. A `-f` file that cannot be read has no line. |
| `input` | The format and how it is cut into inputs: JSON texts one after another (as jq reads them), one per line (`ndjson`), in RFC 7464 records (`--seq`), lines of text (`-R`), CSV or TSV records as objects or, under `--no-header`, arrays, or none (`-n`). |
| `plan` | How each input is answered, one of three ways. Reading only a path, `select(PATH op LITERAL)` or `first`/`limit` of a path from the text, without building the values the path passes by, with a second `plan` line when the read stops after the first answers. Reading only the named columns of each CSV or TSV record, straight from its text. Or building each input whole (the whole input under `-s`, nothing under `-n`) and running the filter on it. |
| `because` | Under a built plan, one line per reason the filter needs it, every one that holds, in the order of the table below. |
| `decides` | What the speed and the memory follow under this plan. |
| `ran` | How many inputs were read, how many were answered by their path and how many were built. A column plan counts the files whose records it read. Under a built plan the unit is what the filter runs on: a text, a `--stream` event, a CSV record. |
| `threads` | `one`, or how many pieces of a long input were answered over how many threads ([Long input](#long-input)). |
| `fallback` | The first input that a path plan built after all, and why. Not written when every input was read by its path. |
| `time` | From reading the filter to the plan chosen, and from then to the end of the run. |
| `used` | The peak memory, the bytes taken (a file mapped or read whole counts in full) and the bytes written to stdout. |

The reasons on `because` lines:

| Reason | When |
| --- | --- |
| -n reads no input | `-n` |
| -s holds the whole input as one array | `-s` |
| -S sorts the keys of every object | `-S` |
| -R reads each line as a string | `-R` |
| --seq writes a record separator before each output | `--seq` |
| --stream turns each text into jq's path events | `--stream` |
| -e looks at each output | `-e` |
| --raw-output0 ends each output with a NUL | `--raw-output0` |
| -a writes ASCII only | `-a` |
| --to csv or tsv writes each output as a record | `--to csv` or `--to tsv` |
| --to jsonc prints a value's comments, which reading a path does not keep | `--to jsonc` |
| the filter is not a path, and not select(PATH op LITERAL) | any other filter |
| --from jsonc reads only a plain path without building, as a text prints with its comments | `select` or `first`/`limit` under `--from jsonc` |
| select is redefined, by the filter or by ~/.jq | a `def select` |
| select(F): F is not PATH op LITERAL with a scalar LITERAL | another `select` |
| select(F): its PATH has a [] or is not a path stury reads without building | `select(.a[] == 1)` |
| the filter does not name only columns of the record | `--from csv` or `tsv` with any other filter |
| an object key is not a constant, or repeats | `{(.a): .b}`, `{a, a}` |
| an object member is not a column of the input | `{a: 1}` |
| select(F): F reads more than named columns | `select(.a == .b + 1)` |
| --no-header makes each record an array | `--no-header` |
| --infer reads each cell's kind from its text | `--infer` |
| --comment lines above a record are written with it, which the column route does not hold | `.` or `select(...)` with `--comment` and `--to csv` or `tsv` with a comment character |
| --from json5 would print a path's answer as written ('a', 0x1F), not as JSON | a path under `--from json5` |

For `--from csv|tsv` the reasons are the column plan's, for any other input the path plan's.

Why a path plan built an input after all, on the `fallback` line:

| Reason | When |
| --- | --- |
| a step met a value it does not apply to (.a over a number), where jq's rules answer | `.a` over a number, `[]` over a string |
| it does not parse, and the filter run reports the fault | a text that is not valid |
| a [] met an object, whose repeated keys jq gives once | `.[]` over an object that repeats a key |

The counts, `threads`, `time` and `used` differ between hosts and runs. `check` and `fmt` refuse `--explain` as a
usage error.

## `check`

`check` (or `validate`) validates its inputs and prints nothing when they are valid.

- It accepts every input that `stury .` reads without error, several texts included.
- It requires at least one JSON text. An empty or whitespace-only input fails with `No JSON text` and exit 5,
  where `stury .` reads it as a stream of no texts and exits 0.
- With no `FILE` on a terminal it prints the short usage and exits 2, as `stury` with no filter does.
- It judges every file and reports each file's first fault. A long input is judged on all cores and tells the fault a
  serial read tells.
- It refuses every option that shapes a filter run, as `fmt` does (`-n`, `-r`, `-c`, `-C`, `--arg`, `-L`, ...), and
  the layout options `--indent` and `--tab`: exit 2. A directory given as `FILE` is reported as one, and `stury
  check .` adds `(check takes no filter)`.

| Flag | Effect |
| --- | --- |
| `--from ndjson`, `--seq` | Validate one record per line or per `0x1E` separator, each record being one text. `--seq` uses `check`'s records, not jq's text sequence; each `FILE` is read alone, so a text cut at a file's end is a fault. |
| `--from jsonc` | Validate JSONC as `stury --from jsonc .` reads it, to the same limits. A comment's text holds no escape. |
| `--from json5` | Validate JSON5 as `stury --from json5 .` reads it, to the same limits. `Infinity` and `NaN` fail, since jq has no value for them. |
| `--from csv`, `--from tsv` | Validate as `stury --from FORMAT .` reads. A fault is told as a filter run tells it ([CSV and TSV](#csv-and-tsv)). An empty input is valid, as the library takes it, and so is a header alone. A cell is one kind: a string, or under `--infer` a number, `true` or `false` when its text is exactly one, so `type: integer` takes the cell `1` only with `--infer`, and `oneOf: [string, integer]` takes it either way. |
| `--max-depth N` | As [above](#sturys-own-options). |
| `--schema FILE` | Also check each input against the JSON Schema in `FILE` (drafts 4 to 2020-12). See [Schema check](#schema-check). |
| `FILE...` | One file per argument, read as the filter reads them. |

`check` without `--schema` writes nothing, so `--to` with a format other than the default is a usage error.

Exit codes: 0 on success, 5 when any input is invalid, 2 for a usage or file error (which wins over 5). With
`--schema`, 1 when an input parses and the schema fails it, below 5 and above 0.

### Schema check

`stury check --schema schema.json [FILE...]` reads, compiles and binds the schema once, then judges each input as
`stury check` does and, if it parses, against the schema. Every failure of an input is told, not only the first, as
`FILE:LINE:COL: MESSAGE at PATH (KEYWORD-PATH)` on stderr. A text that does not parse is the plain `check`'s fault,
told as it tells it. NDJSON and `--seq` check each record; a long file, or an array at the root whose rules apply to each
entry, is checked on all cores and tells what a serial check tells. With `--from csv` or `tsv` the schema describes the
table, an array of its rows, so `{"type":"array","items":{...}}` judges each row and `minItems` counts them. When the last NDJSON record is cut, the earlier records' failures are told
before the fault, and the exit is 5.

| Flag | Effect |
| --- | --- |
| `--schema-ref DIR` | The directory a reference to a `file:` URI may read from. The default is the schema file's directory. A schema with an `$id` resolves a relative reference against that `$id`, so its `file:` references need an `$id` that is one. |
| `--format-assert` | `format` fails an input, where it otherwise only annotates. |
| `--max-errors N` | Keep at most `N` failures of an input (default 100). The basic output and the problem document say `"truncated": true` when more were left out, and the lines end with `NAME: more failures past --max-errors N`. |
| `--report basic` | Write the JSON Schema basic output of each input on stdout, one line a file that is read (a file that faults or does not open has none), `{"valid":true}` for a valid one. Each error unit has `"valid":false`. With several files each line starts with a `file` member naming its file. `keywordLocation`, `absoluteKeywordLocation` (where the schema has an `$id` and the keywords did not pass a `$ref`) and `instanceLocation` are JSON Pointers; with records, a `record` member holds the record's index and the instance location is a pointer into that record. |
| `--report problem` | Write an RFC 9457 problem document of each failing input on stdout: `title`, `status` 422 and `errors` of `pointer`, `code` and `message`, and a `record` member in an error of a record input. A missing member is named in its message, and its pointer is the member's. With several files the document starts with a `file` member. |
| `--report lines` | The default. |

A schema that does not read, compile or bind, or a keyword the check does not judge, is a usage error (exit 2) naming it.
The options need `--schema`, and `--schema` is `check`'s alone.

`stury check --filter FILTER --schema schema.json` types the filter against the schema of its inputs and reads no
input. It refuses each step that no input the schema describes can take, on stderr as a compile error is told, and
writes the JSON Schema that every output of the filter passes on stdout, shaped by the layout options. It exits 1 when
it refused a step, else 0, and 3 when the filter does not compile.

- A member read by name (`.emial`, `.["emial"]`, `{emial}`, `getpath(["emial"])`) that no object of the schema
  describes is refused at the name, with the closest member it does describe: `"emial" is not a member of the object
  the schema describes (did you mean "email"?)`. An object that lists members (`properties`, `patternProperties`, a
  `const` or `enum` object) describes those, and every member where `additionalProperties` or `unevaluatedProperties`
  takes one. An object that lists none (`{}`, `true`, `{"type":"object"}`) describes every member. A `?`, `try` or
  `//` does not lift this refusal. A path an update or `path` reads may name any member, since an update makes it, and
  a jq definition the prelude holds (`map_values`, `with_entries`, ...) is told at its call and refuses no member.
- A step on kinds that never take it is refused as jq would fail it at run time: `.name + 1` when `.name` is a string,
  `.[0]` on an object, `.[]` on a number, `ltrimstr` or `keys` on a number, `@csv` on an object. A step that some
  value of its input takes passes. Inside `?`, `try` and the left of `//` these are the filter's choice and pass.
- The written schema keeps the input's description of what a filter reads: `.email` writes the schema's `email`
  member, `{n: .name}` an object of exactly `n`, `.tags | length` an integer, `type` the enum of the kinds the
  schema allows. A member that may be absent adds null. What the typing cannot follow is written as `{}`, which takes
  any value: a call deeper than two levels of recursion, a fold that does not settle, `fromjson`, `getpath` of a path
  that is not a literal, a `catch` body's input. A value the filter computes keeps none of the input's rules: `-.`,
  `.[1:]` and `ltrimstr("a")` of a constant or a bounded string give a number or a string. An update or `setpath`
  whose path may be `.` gives what it writes, and arithmetic that may give NaN adds null, as jq writes NaN.
- `-n` types the filter on null, `-s` on an array of the inputs, `-R` on strings, and `--arg` and `--argjson`
  variables are their values. `input` and `inputs` read what the schema describes.
- `--from csv` or `tsv` types the filter on the records a table reads: an object of the schema's member names, each
  a string or null, and under `--infer` a number or a boolean too, or under `--no-header` an array of them. The other
  formats read JSON values, which the schema describes.
- In a format that reads byte strings, `type` on a string of `contentEncoding: base64` is `"bytes"`. No format of the
  command line reads byte strings yet.

FILE operands, `--seq`, `--report` and `--max-errors` are usage errors with `--filter`, as are the options that
shape a filter run's output (`-r`, `-e`, `--stream`, ...).

## `schema`

`stury schema infer [FILE...]` writes the JSON Schema that every record of the inputs passes: the kinds met at each
position, a member required when every object there had it, and the elements of arrays as `items`. Nothing is guessed, so
no enum, format or bound appears. An object with more than 64 names, or with names that are all integers or all UUIDs,
is a map: `additionalProperties` and no members. A table's schema is an array of row objects, and an empty cell is an
absent member. `--ranges` also keeps the least and greatest number, string length and array length (not a table's row
count). Members come in the order they first appear. Long files are read on all cores and give the description one
thread gives, and a record that does not read is exit 5. The layout options (`-c`, `--indent`, `--tab`, `-S`, `-a`) shape
the schema's text.

`stury schema sample SCHEMA` writes values that pass the schema, a text a line, in the format `--to` names (CSV and TSV
texts are a table each). `--count N` (default 1) and `--seed N` choose how many and which. `--invalid` writes values
that fail the schema, each a valid one changed in one place. `--comments` writes a node's `description` as a comment
where the format has comments (`--to jsonc`). Each value is a line, compact unless a layout option asks for more, and a
CSV or TSV value is a table, so those take `--count 1`. A schema that no value passes is exit 1 and names the keyword
path of the node the search stopped at.

`stury schema gen SCHEMA` writes the Odin source of the types a model reads the schema's values with, and a procedure
`register` that adds the rules no tag holds to a `model.Registry`, as `schema.write_odin` writes them: a struct for an
object with members, its tags naming each member (`json:`), saying it may be left out and holding its rules (`model:`),
an `extra: map[string]T` member for the members an `additionalProperties` schema judges, a map for an object with no
members, an enum for `enum` and `const` (a union of a string enum, an integer enum and `bool` where the values are of
several kinds), a union for `anyOf`, `oneOf` and a list of kinds (read by the first arm that reads a value where arms
overlap, and under `oneOf` refusing a value two arms read), `Null :: union {}` for `type: null`, a `unique` tag for
`uniqueItems`, a named type with `model.register_applies` lines for `not`, `if`, `contains`, `propertyNames`,
`patternProperties`, `dependentRequired` and `dependentSchemas`, each operand a type of its own, a fixed array for `prefixItems` of one type and that length, and a pointer where a struct holds itself, tagged
`not_null` where the schema takes no null. `allOf` and a `$ref` with siblings are merged into one node where their
members and rules join. `format` only annotates, as `check` reads it: the member is a string with a `// format:`
comment. With `--format-assert` the formats a type reads are `time.Time`, `uuid.Identifier` and `model.Email`, and the
others a `format=` rule. `contentEncoding: base64` is `model.Base64`. `$defs` are named types.

The package is `--package NAME`, by default the file's name in snake case (`my-types.schema.json` is `my_types`). It
must be an Odin identifier that is no keyword and no package the types import (`model`, `time`, `core`, ...), since an
Odin program names each package once. A keyword no type spells (`not` or `if` on a value that may be null, a `oneOf`
with two arms that take null, `prefixItems` beside `items`, ...) is exit 1, told with the path of the node that holds it, and so is an integer enum value past
2^53 and an integer whose bounds leave no value `i64` or `u64` holds. An integer the schema leaves unbounded is `i64`,
so a model refuses one past its range, which the schema takes. Every object nested in another is a struct held by value,
and Odin's compiler takes time exponential in that depth, so the types of objects nested past about 24 levels compile
slowly. schema gen takes no layout option and no filter.

## `fmt`

`fmt --schema FILE` converts each text of the input through a JSON Schema, a record at a time for NDJSON and the
whole table for CSV: the text must pass it, every member it leaves open is kept, and the output must pass it as the
output format reads it. A failure is told as `check --schema` tells it, in the input for an input that fails and
against `NAME (output)` for an output that does, `--max-errors` limiting the failures told of a text, and it gives
exit 1 while the other texts are still converted. A value the output format cannot spell, such as a nested cell in CSV,
is told with its path. A CSV output takes the union of the rows' members as its columns, an empty cell is a member that
is absent, and a row with no member at all is refused. Where the schema allows a cell to read as a string or as the value
it spells, the reading the output passes is the one written. A format with attributes writes each as a member before the
element's children, a name its children repeat as an array and its text as `#text` when the element has attributes; an
attribute and a child of one name, and an array with attributes, are refused.

`fmt` writes each input back in the printer's layout, or in another format. It runs no filter, so it takes no
`FILTER`.

```sh
stury fmt [--from FORMAT] [--to FORMAT] [--schema FILE [--schema-ref DIR] [--format-assert] [--max-errors N]] [--in-place|--check] [--indent N|--tab] [--max-depth N] [FILE...]
```

| Format | What `fmt` writes |
| --- | --- |
| `json`, `jsonc` (the default is `json`) | Each text laid out as `stury .` lays it out: pretty by default, `--indent N` (0 to 7) or `--tab` as given, keys in their order. Only the layout changes: every number and string is written as it was (`1e2`, `"\u00e9"`, `"\/"`) and every member of an object is kept, a repeated key included. JSONC keeps its comments where `stury --from jsonc --to jsonc .` puts them and drops its trailing commas, so a file already in that layout comes back byte for byte. |
| `ndjson` | One compact value per line, as `--to ndjson` writes it, spelled as above. |
| `csv`, `tsv` | The header, then one record per row, re-spelled by the CSV writer: a field that needs no quotes loses them, one that does gains them, and `""` and an empty cell stay distinct ([CSV and TSV output](#csv-and-tsv-output)). A header with no records is written. A JSON text whose root is an array is a list of rows, as the library's writer takes it, and any other text, or an NDJSON record, is one row. An object with a key the header lacks ends the run, as `--to csv` does. |

- `--from` chooses how each file is read, and `--to` how it is written; `--to` defaults to `--from`, so a plain
  `stury fmt FILE` formats `FILE` as JSON. Each half is chosen on its own, so `stury fmt --from csv --to json`
  reads CSV and writes pretty JSON.
- A transcode from `jsonc` to `json` or `ndjson` drops the comments. To `csv` or `tsv` a value becomes cells,
  spelled as `--to csv` spells them, a number as it was written.
- `fmt` is idempotent: `stury fmt` on its own output gives the same bytes. A leading byte order mark is not written.
- Each file is formatted as a table of its own: `stury fmt --from csv a.csv b.csv` writes each file's header,
  where `stury --from csv --to csv . a.csv b.csv` writes one table under the first file's header.
- A CSV or TSV header that names a column twice is refused (`Duplicate header name`), as `check` and a filter run
  refuse it, whatever `--to` is.
- `fmt` never colours its output, and it refuses every option that shapes a filter run (`-C`, `-c`, `-r`, ...,
  `--seq`): exit 2. `--indent N` and `--tab` apply to a JSON-like `--to`, and `--max-depth N` and, with a
  CSV-like `--to`, `--grow-header` apply. A JSON-like output is written at every depth `--max-depth` reads.

| Flag | Effect |
| --- | --- |
| `--check` | Write nothing to stdout. Name each file whose formatted bytes differ from its bytes (a compact JSON text, a CSV field that needs no quotes, a CRLF line ending) on stderr, `stury: FILE is not formatted`, and exit 1; 0 when every file is already formatted. A fault exits 5. |
| `--in-place` | Rewrite each file through a temporary file in its directory and a rename; mode (and owner and group where permitted) are kept; other hard links keep the old bytes. A read-only (0444) file in a writable directory is replaced, as `sed -i` does. Only when `--to` is `--from`; refused with `--check`, with standard input, and on a non-regular file (exit 2). Files are rewritten one after another: when a later file fails, the earlier ones stay rewritten, and the run exits with the worst status. |
| `FILE...` | In argument order. A fault names the file and its position, as `check` does: `stury: parse error: FILE:L:C: ...`. A text that ends mid-value is told at its last byte, as in a filter run (`printf '[1] [2' | stury fmt` gives `<stdin>:1:6: Unfinished input`). Each file's first fault is told and the run goes on with the next file, which `--in-place` leaves unwritten; the run exits 5. A file that does not open is reported and the run goes on, with exit 2. |
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

## `edit`

`edit` runs the filter on each input and splices its outputs into the input's own bytes. Every byte the edit does not
touch stays as written: whitespace, number and string spelling, comments, line ends and a repeated key. The identity
run is byte for byte. Anything new follows its container's layout.

```
stury edit [--from FORMAT|--seq|-R] [-s] [--in-place|--check] [OPTIONS] FILTER [FILE...]
```

```sh
$ printf '{"a":1, "b":[2,3]}\n' | stury edit '.a = 2'
{"a":2, "b":[2,3]}
$ printf '{\n  "a": 1\n}\n' | stury edit '.b = [2]'
{
  "a": 1,
  "b": [2]
}
$ printf '{"b": 1, "a": 2}\n' | stury edit '{a, b}'
{"a": 2, "b": 1}
$ printf 'a,b\n1,2\n3,4\n' | stury --from csv edit 'select(.a != "1") | {b, a}'
b,a
4,3
$ stury edit --in-place '.port = 9090' config.json
$ printf '{"a":1}' | stury edit --check '.a = 2'; echo $?
stury: <stdin> would change
1
```

- JSON, JSONC and JSON5 are one text each, and the filter must make exactly one output for it: none or more is an
  error (exit 5), since a file holds one document.
- CSV and TSV, NDJSON, `--seq` and `-R` lines run the filter on each record, and the outputs are the records written
  back. A record with no output is dropped with its line end and the comments attached to it. Each output past a
  record's first is a new record after it, written in the input's spelling, and the first keeps the record's bytes. A
  record the filter reads with `input` or `inputs` is consumed and writes no record of its own.
- `-s` runs the filter once on the array of the records, and each output must be an array, whose items are the records
  written back in its order. A record the output keeps, moved or not, keeps its bytes. Under `-R -s` the file is one
  string and the outputs, written raw, are the file.
- The output replaces the document. An object edits its members: a kept member keeps its bytes, a new one is
  inserted, and a dropped one is removed with the comments attached to it. Members take the output's order: a moved
  member takes its bytes and comments along, and the separators, lines, indent and trailing comma stay in their
  places, so `{a,b}` on `{"b":1,"a":2}` is `{"a":2,"b":1}` and `del(.b) | .b = 1` puts `b` last. An array is edited
  the same way: a kept element, one the output took from the source, keeps its bytes wherever it goes, so `sort`,
  `reverse` and `map(select(...))` move and drop elements rather than rewrite the array. Any other value replaces the
  one at that place.
- In a table, a column order, a new column and a dropped one change the header and every row the same way, and each
  kept cell keeps its bytes: `{b, a}`, `del(.a)` and `.c = 1` reorder, drop and add a column. A row output may be an
  object, by the header's names, or an array or a scalar, filling the columns in order. A cell is a text, a number,
  true, false or null, as for `--to csv`: an array or an object is refused, and `tojson` makes text of it. A delimited
  cell or column name is written with the table's quotes or escapes, and a CSV one that starts with a byte order mark
  is quoted. A cell the table cannot write, an empty TSV string (an empty TSV cell is null) or a TSV cell or name that
  starts the text with a byte order mark, is refused with the file, the record's line and the reason.
- A value the filter took from the input keeps its source spelling, and a value it built is written by jq's writer,
  `-a` escaping non-ASCII and `-S` sorting its keys, in the layout of the container it lands in. Where that
  container's first member starts a line, a built object or array is written one member or element a line, at every
  level, in the container's indent step (spaces or a tab) and with the spacing around its colon. Where the members
  share the bracket's line, it is compact. An empty container shows no layout and takes its parent's, and so does a
  container whose indent step is not a run of spaces or one tab. The root's own layout, when the output replaces it
  with another kind of value, is compact. `-c`, `--indent N` and `--tab` write every built value in their layout
  instead. A number is
  an f64: a literal that rounds to the filter's value is left as written. `-S` also puts every object of the output in
  key order, moving the members as a reorder does, and puts a table's columns in order.
- A new member or element follows its container's layout: its line, its indent and the blanks around a key's colon.
- A repeated key is read as the CLI reads it, the last member winning: the filter edits that member, and the other
  members with that name keep their bytes. Dropping the key removes every member with that name.
- `-e` sets the exit status by the last output, as for a filter run: 1 when it is false or null, 4 when there is none.
- `.@comment` and its kin read and write comments as in a filter run ([Comments in the CLI](#comments-in-the-cli)), and
  `edit` writes the comments of the output value: a role the filter wrote, each of its strings one comment, and `null`
  removes the role with its line when a comment stood alone on it. A value the output takes from another node
  (`.b = .a`) brings that node's comments for the roles it has. A moved member takes its comments along, and a written
  one goes where the member lands.
- A new member or element, and a value the filter built in place of one, is written with its comments and those of the
  values nested in it: `.a = 1 | .a.@comment = "new"` on `{"b": 2}` gives `{"b": 2,` and then `// new` and `"a": 1}`
  on lines of their own.
- A new comment is written as `// text`, or as `/* text */` where the line goes on after it. A head or foot of
  several comments takes a line for each, and several inline comments follow the value on its line.
- In a CSV or TSV table read with `--comment C`, a comment is a line `C text` above a record or after the last one:
  `.@comment` on a kept or new record writes its strings as such lines above it, a list taking a line for each. Under
  `-s` the output array's `.@comment` goes above the header and its `.@comment_foot` after the last record. A
  comment a table cannot place, on a cell, inline, or holding a line end, is refused with exit 5, and so is any comment
  on a table read without `--comment`.
- `edit` refuses with exit 5 a comment in a format that holds none (`json`, `ndjson`), and one on a value a record of
  `--seq` or NDJSON input writes new.
- Each input is written back in its own format, so `edit` refuses `--to` and the options that respell output as a
  whole, `-r`, `-j`, `--raw-output0` and `-C`. It refuses `-n`, since the filter would not see the file, `--stream` and
  `--stream-errors`, whose outputs are events rather than the document, and `--follow`, since a file is written once it is read whole (exit 2). `stury edit --help` lists its
  options.

| Option | Effect |
| --- | --- |
| `--in-place` | Rewrite each named file through a temporary file and a rename, as `fmt` does. A file whose bytes do not change is left untouched. Standard input is refused (exit 2). |
| `--check` | Write nothing to stdout. Name each file the edit would change on stderr, `stury: FILE would change`, and exit 1; 0 when none would change. A fault exits 5. |
| `--diff` | Tell the value changes the edit makes of each file, in `diff`'s form under a `--- FILE` line, and write nothing; with `--in-place` the file is rewritten too. It takes whole documents, so it refuses `--check`, `--seq`, `-R` and NDJSON (exit 2). Layout is not a value, so a change of spacing is not told. |
| `FILE...` | In argument order, or standard input. Without `--in-place` each file's edited text is written in turn. A fault is told for its file, as `fmt` tells it, and the next file is edited; the run exits with the worst file's status. |

Errors name `<stdin>` or the file, with the line and column where the input has them.

## `diff`

`diff` tells what differs between two inputs and exits 1 when something does. Each file is one document, read as
`--from` says. A file of records (`--from ndjson`, `--seq`) is one array of them, so `.[1]` is its second record.

```sh
$ stury diff old.json new.json
~ .port: 8080 -> 9090
~ .replicas: 3 -> "3"  (number -> string)
+ .tags[1]: "y"
- .debug: true
```

- A line to a change: `+` an added member or element, `-` a removed one, `~` a changed value, with its path in the new
  document, or in the old one for a removal. `(was PATH)` follows a change inside an array element that moved.
- Objects match by member name, and numbers by value, so `1.0` equals `1` and member order is no change. Arrays match
  as sequences by default, so one inserted element is one change. `--set` matches equal elements wherever they stand,
  `--position` compares the elements at one index, and `--key MEMBER` pairs elements by the value of their member
  (`--key PATH=MEMBER` for the array at PATH, `--key .users=id`) and compares each pair in depth. An array that differs by
  more than 4,096 edits is told as replaced, and `stury: an array differs...` follows on stderr.
- `--facts` tells changes of comments and attributes too, where both files' formats carry them.
- `--json` writes a record a line: `{"path":["port"],"op":"changed","old":8080,"new":9090}`, with the path as
  `getpath` takes it and `op` one of `added`, `removed`, `changed` and `fact`. A change inside an array that
  moved its elements also carries `old_path`, its place in the old value.

`--old-schema` and `--new-schema` mark a JSON Schema, never guessed from content. Both together compare the two
schemas and take no file: each change names the place, the keyword and what it does to the values taken (`widens`,
`narrows`, `both`, `unknown`), then `backward` says whether the new schema takes everything the old one takes and
`forward` the reverse. A verdict is `yes` with a proof, `no` with a value one schema takes and the other refuses, or
`unknown` with the keyword the proof stopped at. `--compat backward|forward|full` exits 1 unless that direction is
proven, and without it the exit is 1 for any change. `--format-assert` and `--schema-ref` read as `check` reads them.
A schema with one data file judges the data by the schema, as `check --schema` does (exit 1 for a failure), then tells each
member the data has that the schema does not describe, `+ .z  not described by the schema`, which is also exit 1.
`--shape` compares the shapes of two data files: each is described as `schema infer` describes it, and the two
descriptions are compared and told as above. A comparison that reaches its bound answers `unknown` with the reason
`budget` or `search`, and never a `yes` or a `no` it did not prove or find a value for. With
`--json` a schema change is `{"path":["id"],"keyword":"minimum","old":"0","new":"1","effect":"narrows"}` and each
verdict a last record.

| Exit | Meaning |
| --- | --- |
| 0 | Nothing differs, or the compatibility asked for is proven. |
| 1 | The inputs differ, or the compatibility is not proven. |
| 5 | An input does not parse. |
| 2 | A usage or file error. |

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
- Every format but `json` cuts the input itself, so reading it is a usage error with `-R` and `--seq`, and reading
  any but `ndjson` with `--stream` and `--stream-errors`. Writing CSV or TSV is one with `-r`, `-j`, `-a`, `-C`,
  `-c`, `--indent`, `--tab`, `--seq` and `--raw-output0`, which shape JSON text. `-S`, `-e`, `-n`, `-s`, `--arg`
  and the rest still apply to a filter run; `fmt` refuses them ([`fmt`](#fmt)). `--to ndjson` takes the place of
  `-c`, so it is refused with `--indent`, `--tab` and `--seq`, and `--to jsonc` is refused with `--seq`.

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
- SIGINT and SIGTERM end the run, a FIFO's or a pipe's included, once the answers so far are written, by the signal,
  as they end jq. Ctrl-C and Ctrl-Break on Windows end it with jq's status for Ctrl-C, `STATUS_CONTROL_C_EXIT`.
- It is a usage error (exit 2) with standard input or more than one file, `-s`, `-n`, `--stream`, JSONC, JSON5,
  `check` and `fmt`.

### Records and events

| Option | Behaviour |
| --- | --- |
| `--seq` | Passes over a record that does not parse with `stury: ignoring parse error: ...` and puts `0x1E` before each output. |
| `--stream` | Gives jq's `[path, leaf]` and `[path]` events of each text. Of a text that does not parse it gives jq's events before the fault, then refuses the text as any input. |
| `--stream-errors` | Gives what jq gives of a faulty text: the events before the fault, then `[message, path]`. `[1,` gives `[[0],1]` and then `["Unfinished JSON term at EOF at line 1, column 3",[1]]`. Its messages, positions, exit code and `--seq` resync are jq's, but for a text read on past the line of its fault and the place of a fault after the first in a stream ([Edge cases](#edge-cases)). |

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

- **Cells are strings or null.** A cell is read as a number or a boolean only under `--infer`
  ([CSV and TSV options](#csv-and-tsv-options)); else convert with `tonumber` (`.age | tonumber`). A comparison reads a cell as the string it is, as the library's `core.compare` does: `.age == 30` is false without `--infer`. A quoted field is its text without the quotes, with `""` read as one quote, and may
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
  3
   ^
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
  the record. A whole file of 1 MiB or more is split across all cores and printed in file order.
  Any other filter, and `-n`, `-s`, `--no-header` and `--infer`, run on the interpreter. Under `--ragged`, `.` and a filter
  that reads a column the header lacks, or a column named by digits, build each record.

### CSV and TSV options

These options set how a delimited text is read and written. They are the library's `dsv.Options`, one flag each.
A reading option without `--from csv` or `--from tsv`, or a writing one without `--to csv` or `--to tsv`, is a usage
error. They work for a filter run, `check`, `fmt` and `edit`. `check` and `edit` write no table of their own, so they
refuse the writing options, and `edit` writes each record back with the delimiter and comment character it read.

| Option | Reads or writes |
| --- | --- |
| `--delimiter C` | Cells are split at `C`, one ASCII character (`\t` for a tab), in place of `,` for CSV or a tab for TSV. CR, LF, and under CSV a quote, under TSV a backslash, `t`, `n`, `r` and `0`, are usage errors. |
| `--no-header` | The first record is data. Each record is an array of its cells, and the filter runs on the interpreter. |
| `--comment C` | A line whose first byte is `C` is no record. `C` inside a cell, or at a later byte of a line, is text. CR, LF, the delimiter, and under CSV a quote, under TSV a backslash, are usage errors. |
| `--infer` | An unquoted cell that is exactly a JSON number, `true` or `false` reads as that value, as the library's `core.resolve` reads it. A quoted cell stays a string: `"1"` is `"1"`. The empty cell is `null` with or without it. A table written from a table read with `--infer` (a filter's `--to csv`, `fmt`, `edit`) quotes a string that would read back as a number, `true` or `false`, so it reads back the same, and TSV, which has no quotes, refuses one. |
| `--ragged` | A record of any width. A narrower record lacks its missing columns, and a wider one's cells past the header are columns named by their position from 1 (`"3"` for the third). |
| `--lazy-quotes` | CSV: a quote inside an unquoted cell is a byte of it, where it is a fault by default. |
| `--out-delimiter C` | A written table splits cells at `C`. By default a table written as the format read (`--from csv --to csv`, and `fmt`) keeps the read's delimiter, so it reads back with the same options, and any other uses its format's own. |
| `--out-comment C` | A written table's comment lines start with `C`, which a first cell starting with `C` is quoted against. By default a table written from a table keeps the read's `--comment`, and any other has none. The bytes `--comment` refuses are usage errors. |
| `--out-no-header` | A written table of objects has no header line. A table written as the format read under `--no-header` has none either. |
| `--crlf` | Each written record ends with CR LF. |

```sh
$ printf '# prices\nitem;price;sold\npen;1.50;true\n"ink";"2";false\n' | stury --from csv --delimiter ';' --comment '#' --infer -c .
{"item":"pen","price":1.50,"sold":true}
{"item":"ink","price":"2","sold":false}
$ printf '1,2\n3,4\n' | stury --from csv --no-header -c '{a: .[0], b: .[1]}'
{"a":"1","b":"2"}
{"a":"3","b":"4"}
$ stury fmt --from csv --delimiter ';' --out-delimiter , prices.csv
```

`fmt` of a table into a table keeps its comment lines, as the library's writer keeps a document's comments when the
output has a comment character (the read's `--comment`, or `--out-comment`): a comment above the header, above a record
or after the last record stays there. When the output has none, they are dropped. A filter's `--to csv` output writes
each output's `.@comment` as `C text` lines above its row when the output has a comment character, and `fmt` from JSONC
to a table with `--out-comment C` places the text's comments the same way: the root array's above the header, each
element's above its row, the root's foot comments after the last row. Inline and cell comments, and one holding a line
end, are dropped.

A filter run over a table read with `--comment C` sees the comment lines above a record as that record's `.@comment`
(the text after `C` and one space, a line each), and `null` for a record with none, so `stury --from csv --comment '#'
--to csv .` writes every comment line back. The lines before the header are the table's: written above the header of a
`--to csv` or `tsv` output, and under `-s` the array's `.@comment`. The lines after the last record are written after the
last row, and under `-s` are the array's `.@comment_foot`. A table output has one header, so of several files only the
first one's lines before its header are written, and every file's lines after its last record come after the last row.
A comment line is written as `C text`, so `#a` reads back as `# a`. A filter that names only columns (`.name`,
`{name}`) reads no comments and keeps the column route; `.` and `select(...)` into a table with a comment character are
built whole, and a long input is then answered on one thread.

The names follow the tools people know: `--delimiter` as in csvkit, xsv and qsv (DuckDB's `delim`), `--no-header`
as xsv's `--no-headers` and csvkit's `--no-header-row`, `--comment` as qsv's comment character and DuckDB's
`comment`, `--ragged` and `--lazy-quotes` as in Miller, `--out-delimiter` as in csvkit and xsv, `--crlf` as in xsv.
Inference is off by default, as in the library, where csvkit and Miller infer by default. None takes a short letter:
xsv's `-n` is jq's `--null-input`, and a letter of stury's own could clash with a later jq release. No jq 1.8.2
option has these names.

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
stury: parse error: <stdin>:3:2: Record has fewer fields than the first record
3
 ^
```

## Errors and exit codes

The exit codes are jq's, but the messages are stury's.

| Fault | Message |
| --- | --- |
| A file that cannot be opened | `stury: error: Could not open file NAME: REASON` |
| A directory given as a file | `stury: error: Could not open file NAME: Is a directory`, where jq says `jq: error: Is a directory`. `.` under `check` or `fmt` adds `(check takes no filter)` |
| An error the filter raises | `stury: error (at FILE:LINE): MSG` as jq, but with no input to name, as under `-n`, `stury: error: MSG`, where jq says `(at <unknown>)`. `input` past the last input says `No more inputs`, where jq prints the `break` that `inputs` catches (`try input catch .` still gives `"break"`) |
| `--rawfile` or `--slurpfile` naming a file that does not open | `stury: --rawfile NAME FILE: Could not open FILE: REASON`, where jq calls it `Bad JSON in --rawfile ...` |
| A filter of one word a letter or two from `check` or `fmt` | jq's compile error, then `stury: chek is not a command: did you mean stury check?` |
| A JSON text that does not parse, in a filter run on standard input or one file | `stury: parse error: MSG at line L, column C`, as jq |
| Any other text that does not parse: under `check` and `fmt`, under `--from` another format or `ndjson`, under `--seq`, several files, or `input` under `-n` | `stury: parse error: NAME:L:C: SENTENCE`, NAME `<stdin>` for standard input, counted in that file (a `--seq` text that runs between files has the stream's position instead), such as `<stdin>:1:10: Leading zero in a number` |
| Output that cannot be written, or a stdout that is closed (as jq, even when nothing was written; not under `check`, `fmt --check` or `fmt --in-place`, which write nothing to it) | `stury: error: writing output failed: REASON`, exit 2 whatever the run came to |

L and C are the line and 1-based byte column of the byte the fault is at. A text that ends mid-value is told at its
last byte in every mode, and at column 0 of the next line when its last byte is a newline, as jq places it. An
NDJSON record cut short by its line's end is told at the line's last byte.

Every parse error is followed by the source line, cut to a screenful around the byte, and a caret under it. A
trailing comma, a comment or nesting past `--max-depth` adds the flag that would read it (`--from jsonc`,
`--max-depth N`), in a filter run and under `check` alike. So does any other fault of a file read as JSON whose name ends `.csv`, `.tsv`, `.jsonc`, `.json5` or `.ndjson`: `stury .
data.csv` adds `(--from csv reads it)`, except under `--seq`.

| Code | Meaning |
| --- | --- |
| 1 | Under `-e`: the last output is `false` or `null`; under `fmt --check`: a file is not already formatted |
| 2 | A usage or file error, or output that cannot be written |
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

### Reading and writing

| Accessor | Gives |
| --- | --- |
| `.@comment` | the leading comments and, on a member's value, the inline ones |
| `.@comment_inline` | the comments after the value, on its line or past its comma (despite its name) |
| `.@comment_foot` | the footer comments |

- Each gives a list of texts in source order, each without its `//` or `/* */` and one space inside them
  (`// a` and `/* a */` read `"a"`), or `null` when there are none, as on a value the filter made and on any
  value of plain JSON that the filter has written none on.
- A document's leading comments lead its root and its trailing ones trail it. On `{"a": 1} // x` the root's
  `.@comment_inline` is `["x"]` and its `.@comment` is `null`, as no comment comes before it.
- They parse with or without `--from jsonc`, where jq refuses them. jq reads `.@name` only before a string
  (`.@base64 "x"`), and that still parses as jq's.
- Each is also a path step, so `=`, `|=`, `+=` and the other updates, `del`, `path`, `getpath`, `setpath` and
  `delpaths` take it. In a path it is the object `{"fact": "comment"}` (`"comment_inline"`, `"comment_foot"`):
  `path(.a.@comment)` is `["a",{"fact":"comment"}]`. It must be the last step; a step after it is an error.
- A filter writes comments on any value of any format, strict JSON too: `.a.@comment = "x" | .a.@comment` is
  `["x"]`. A string is one comment, an array of strings one per element, and `null` or `[]` removes them, as
  `del(.a.@comment)` does. Anything else is the error `a comment is a string, an array of strings, or null`.
  A role written replaces that role's comments from the input, and the other roles keep theirs.
- Comments travel with their value: through pipes, variables, `.a`, `.[]`, `.[n]`, `select`, `if`, `first`,
  `limit`, array and object construction, and assignment (`.b = .a` gives `b` the comments of `a`, those read
  from the input included). A value computed from others (`.a + 1`, `tostring`, `tojson`, `keys`, `add`,
  `length`) has none.
- A value put in place of another keeps the old one's comments for each role the new value brings none of:
  under `--from jsonc`, `.a = 5` leaves `.a.@comment` as the input had it, and `.a = .b` takes `b`'s comments
  for the roles `b` has and keeps `a`'s for the rest. This holds for `=`, every update operator and `setpath`.
- A write is no side effect: `(.a.@comment = "x") as $_ | .a.@comment` reads the input's comments.
- Comments are not data. `==`, `<`, `sort`, `unique`, `group_by`, `contains`, `inside`, `has`, `keys`,
  `length`, `tojson`, `tostring`, `paths`, `tostream`, `to_entries` and the `@` formats answer as if there
  were none, and `paths` yields no comment step.

## Differences from jq

stury reads strict RFC 8259 JSON and reports faults its own way. The rest of the language and the options are
jq's. jq has no `check`, `fmt` or `edit`, and `--from` and `--to` read and write formats jq does not. `.@comment`,
`.@comment_inline` and `.@comment_foot`, a syntax error in jq, read and write a value's comments ([Comments in
the CLI](#comments-in-the-cli)); outside `--from jsonc` they give `null` until a filter writes one.

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

A parse error names the fault at the line and column of the byte it was found at. A JSON fault says what was found
and what was expected: `Expected ',' or ']' after an array element`, `Trailing comma before the closing bracket`,
`Expected value before ','`, `Unmatched '}'`, `Missing colon after key`, `Object keys must be strings`,
`Invalid string literal; expected ", but got '`, `Unescaped control character U+0009`, `Invalid UTF-8 byte 0xFF`,
`Infinity and NaN have no JSON value`, `Leading zero in a number`, `A number cannot start with '.'`, `A number
cannot start with '+'`, `Expected a value`. A filter run on JSON keeps jq's sentence where jq's names the fault
(`Unfinished JSON term`, `Invalid numeric literal`, `Exceeds depth limit for parsing`, `Unexpected text after the
JSON value`), and `check` and every other mode say the library's (`Unfinished input`, `Invalid number`, `Exceeds the
depth limit`). A text that ends mid-value is told at its last byte, which is jq's position, so the plain path,
`--stream-errors`, `check` and `fmt` agree at the end of the input. `fromjson`, the option JSON and a module's data
file say the same.

| | stury | jq |
| --- | --- | --- |
| Message | names what was found and what was expected | jq's own wording: `Expected separator between values` for a missing `,` or `:`, `Expected another array element` for `[1,]`, `Objects must consist of key:value pairs` for `[1}`, `Unmatched '}'` for `{"a":}`, `Expected string key before ':'` for `{:1}`, `Invalid string: control characters from U+0000 through U+001F must be escaped` |
| Position | the byte the fault is at | where its parser stood after that byte |
| At the end of input | the last byte | the last byte |
| At a newline (`1e` then a newline) | line 1, column 3 | line 2, column 0 |

`fromjson` keeps jq's `Expected JSON value` and `Unexpected extra JSON values`.

#### Files are read separately

Each file ends its texts, except under `--seq` ([below](#--seq-reads-each-record-as-one-text)). jq reads `1` in
one file and `2` in the next as `12`. A parse error in a file after the first names the file
and counts its line and column in that file (`b.json:1:3: Invalid literal` for `2 x`), where jq counts on across the
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
- `sort`, `sort_by`, `group_by` and `unique_by` keep two elements in input order where their keys first differ by a
  nan against a nan, as they keep equal keys. jq calls each nan below the other, which leaves the order to the C
  library's `qsort`: on macOS, `[range(9)] | sort_by(nan)` is `[8,1,2,3,0,5,6,7,4]`, and `sort` reorders eight
  arrays that each start with nan.
- jq's `--run-tests` is absent, since stury has no test-file runner, and so are `--debug-dump-disasm` and
  `--debug-trace`, which list jq's bytecode. Each is an unknown option (exit 2).

**`--stream` and `--seq`**

- `--stream` gives each scalar the full path to it, as jq does, so a value nested n levels deep gives Θ(n²)
  bytes of events (nested empty arrays: about 1 MB at depth 1000, 100 MB at 10000). There is no clamp;
  `--max-depth` bounds it.
- Under `--stream-errors` without `--seq`, the walk of a faulty text stops at the end of the line its fault is on,
  and the stream goes on from the next line. A string a raw line break cuts (`"a`, a newline, `b"`) gives
  `Unfinished string at EOF at line 2, column 0` and then the next line's own fault, where jq reads on through the
  string and gives `Invalid string: control characters ...` at line 2, column 2. A fault after the first is told
  at its line and column in the stream.
  jq's parser passes over the rest of the line a fault is on without counting it, so jq tells a later fault short
  of its place: `}`, a newline and `:` give `':' not as part of an object at line 1, column 2`, where stury says
  line 2, column 1.
- A number cut by `0x1E` or the stream's end is refused under `--stream` too (`Potentially truncated
  top-level numeric value`), where jq reads it. `check --seq` refuses it the same way.
- `check` fails on a JSON input of no text (`No JSON text`), but under `--seq` an empty input, like one of
  separators alone, is no records and passes. `stury .` reads either as no input and says nothing. jq says nothing
  of separators alone, but tells an empty or blank input `ignoring parse error: Unfinished abandoned text`.
- Under `--seq`, separators with only whitespace after them are no record, and a BOM at the input's first
  byte is stepped over, as jq does. Whitespace before the first `0x1E` is not a text, in jq or in stury.

**Numbers**

- A number is printed as it was written, where jq prints decNumber's canonical spelling (`1e3` and `1E+3`, `0.1e1` and
  `1`, `12.5e-1147483647` and `1E-1146...`).
- Numbers are equal, ordered and hashed by the exact decimal a literal spells, at any size, as the library does (`1.0`
  equals `1`, `-0` equals `0`, and `100000000000000000001` is above `100000000000000000000`). jq compares a literal
  that way only within decNumber's range, an adjusted exponent from -1147483646 to 999999999, and reads one past it as
  its double. In stury `1e1000000000` is below `1e1000000001`, `1e-2000000000` is above `0`, and `sort`, `unique` and
  `group_by` tell them apart:

  ```
  [1e1000000000, 1e1000000001] | .[0] == .[1], (unique | length)
  stury: false, 2
  jq:    true, 1
  ```

- A double is its shortest decimal, so the double that arithmetic made from a literal is another number when the
  literal has more digits (`12345678901234567890123456789012345678901 | . == . + 0` is false, where jq says true), and an
  infinity, which is no decimal, is above every literal (`infinite == 1e400` is false, `infinite > 1e400` true).
- A JSON5 decimal written with a sign or a point of its own, `+1e400` or `.5e400`, is compared by its digits as the JSON
  spelling is. A hex integer of up to 128 bits is compared by the decimal digits it prints
  (`0x20000000000001` equals `9007199254740993`), and a longer one is compared as its double.
- A CSV or TSV cell is a string in a comparison, as `type` says: `.a == 1e-400` is false for the cell `1e-400`, and
  `[.a, 1e-400] | unique` has two members. The library's `core.compare` and `core.equal` do the same: a cell is a string
  unless the document was read with `infer`, and only `read_plain = true`, which the schema-directed conversion uses, reads it as the number,
  boolean or null it is compared with.
- An integer literal of 18 or more digits is rounded to the nearest double. jq 1.8.2 can be one unit in the last
  place off: `712598146987295425 + 0` is `712598146987295500` in stury and `712598146987295400` in jq, and
  `1287579022434948980 % 7` is 5 in stury and 2 in jq. Python's `float()` gives stury's values.

**Dates and times**

- A time past year 2^31 keeps its year: `67767976233532800 | gmtime` is `[2147483648,0,1,0,0,0,3,0]`, where jq
  wraps the year to a negative one (`[-2147483648,0,1,0,0,0,3,0]`). `strftime` and `todate` print the year with
  the C library's `%Y`, which glibc wraps.
- `now` has sub-microsecond resolution where the clock has it, so `now - now` need not be 0.
- `strftime`, `todate` and `mktime` of a broken-down UTC time read it as UTC on every OS (`0 |
  strftime("%z %s")` is `+0000 0` whatever `TZ` is); jq does so on macOS only. `strflocaltime` stays local.
- `scalb` and `scalbln` cut a fractional exponent toward zero and saturate a huge one on every OS, as jq on
  macOS does: `[scalb(1;2.5), scalbln(1;1e30)]` is `[4,1.7976931348623157e+308]`. glibc's jq gives
  `[null,0]`.
- `builtins` lists the same names as jq, sorted. jq lists them in the order of its own tables.
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

A choice inside a loop, as in `(a+)+$` or `(a|aa)*b`, runs in time linear in the text, so where jq stops with
`retry-limit-in-match over`, stury answers. A counted repeat around a choice, as in `(a|aa){30,60}c`, still meets
jq's limit.

A JSON Schema `pattern` is not Oniguruma but ECMA-262 with the `u` flag: an escape outside a class names only a syntax
character (`^$\.*+?()[]{}|`) or `/`, and inside a class also `-`, and any other (`\&`, `\%`, `\-` outside a class) is
refused with the escape and its offset.

## For library users

The CLI reads input as `json.build` and `json.validate` do with their defaults (`.Json`, `core.Duplicates.Last`), and
its numbers are uncapped. It differs from the library on purpose:

| | CLI | Library |
| --- | --- | --- |
| A key repeated in one object | keeps its last value and cannot be refused | `dups`: `core.Duplicates.Last`, `.First`, `.All` for each, or `.Refuse` |
| Strings and keys | jq's escapes (`"\/"` is `"/"`), DEL as `\u007f`. Of a repeated key, only the last value prints, at the first one's position | the source text, DEL as the byte unless the writer's `escape_del` is set, and `respell_strings` to write them in the writer's own escapes |
| Numbers | printed as written (`1E2` stays `1E2`); when computed, as jq's double layout | the source text |

- A JSONC document keeps its comments as facts, and `core.write` puts them back where they were read, as
  `stury --from jsonc --to jsonc` prints them (a repeated key with its last value's). That does not apply to
  `marshal` of an `any`.
- The CLI runs a filter by one of three routes, which `--explain` names: the path scan, the column route and the
  interpreter ([`--explain`](#--explain)). The path scan is the library's `records.scan`, and the interpreter runs over a
  document built whole.
