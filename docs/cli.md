# stury command line

`stury` runs jq 1.8 filters and gives jq's results and exit codes. Its messages start with `stury:`, and parse errors
are worded its own way ([Errors and exit codes](#errors-and-exit-codes)). On top of jq it has:

- **`stury check`:** validates input without running a filter, against a JSON Schema too (`--schema`), and types a
  filter against the schema of its inputs (`--filter`).
- **`stury fmt`:** writes each input back in the printer's layout, or transcodes it.
- **`stury edit`:** edits each input with a jq filter and keeps every byte the edit does not touch.
- **`stury diff`:** tells what differs between two inputs, two schemas, or a schema and data.
- **`stury schema`:** infers a schema from inputs, samples values from one, or writes its Odin types.
- **Formats:** `--from FORMAT` and `--to FORMAT` read and write JSON, JSONC, JSON5, NDJSON, CSV, TSV, TOML, YAML,
  XML, CBOR and HTML ([Formats](#formats)).
- **Strict input:** RFC 8259, as [Differences from jq](#differences-from-jq) lists.

The examples assume `stury` is on `PATH`. Otherwise use `build/stury` (`make build-cli`).

```sh
stury [-c] [-r] [-j] [--raw-output0] [-a] [-S] [-C|-M] [--tab|--indent N] [--unbuffered] [-b]
      [-n] [-R] [-s] [-e] [-f FILE] [-L DIR] [--seq] [--stream|--stream-errors]
      [--from FORMAT] [--to FORMAT] [--grow-header] [--attributes]
      [--max-depth N] [--threads N] [--follow] [--explain]
      [--alias-limit N] [--merge-keys] [--expansion-limit N] [--unread-entities]
      [--arg NAME VALUE] [--argjson NAME JSON] [--slurpfile NAME FILE] [--rawfile NAME FILE]
      [FILTER] [FILE...] [--args STRING...|--jsonargs JSON...]
stury check [--from FORMAT|--seq] [--max-depth N] [--threads N] [--schema FILE [--schema-ref DIR] [--schema-draft D] [--format-assert]
            [--max-errors N] [--report lines|basic|problem]] [FILE...]
stury check --filter FILTER --schema FILE [--from FORMAT] [-n] [-s] [-R] [--arg...] [-c]
stury fmt [--from FORMAT] [--to FORMAT] [--schema FILE [--schema-ref DIR] [--schema-draft D] [--format-assert] [--max-errors N]] [--in-place|--check] [--indent N|--tab] [--max-depth N] [--threads N] [FILE...]
stury edit [--from FORMAT|--seq|-R] [-s] [--in-place|--check|--diff] [--max-depth N] [--threads N] [-f FILE] [-L DIR] [--arg...] FILTER [FILE...]
stury diff [--from FORMAT] [--set|--position] [--key [PATH=]MEMBER]... [--facts] [--json] OLD NEW
stury diff --old-schema FILE --new-schema FILE [--compat backward|forward|full] [--json]
stury diff --old-schema FILE DATA | stury diff DATA --new-schema FILE
stury diff --shape [--from FORMAT] OLD NEW
stury schema infer [--from FORMAT] [--to FORMAT] [--infer] [--ranges] [--threads N] [FILE...]
stury schema sample [--to FORMAT] [--count N] [--seed N] [--invalid] [--comments] [--schema-ref DIR] [--schema-draft D] SCHEMA
stury schema gen [--package NAME] [--format-assert] [--schema-ref DIR] [--schema-draft D] SCHEMA
stury -h | -V | --build-configuration
```

An option only some commands take, such as `--report`, `--count` or `--diff`, is a usage error with any other, which
names the commands that take it and what it does.

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

`check` prints nothing for a valid input. For the bad text above it prints the fault and exits 5.

## Options

stury takes all of jq's options except `--run-tests`, `--debug-dump-disasm` and `--debug-trace` (jq's test-file
runner and bytecode listings), and adds its own. Each short option has jq's long form (`--compact-output`,
`--null-input`, `--from-file`, `--library-path`, ...). `FILTER` is a jq 1.8 program, modules included (`import`,
`include`, `-L`, `~/.jq`).

`FILE` and `FILTER` are positional:

| Given | stury |
| --- | --- |
| no `FILE` | reads stdin |
| no `FILTER` | runs `.` |
| no `FILTER`, and stdin and stdout are both a terminal | prints the usage and exits 2 |

### stury's own options

| Option | Behaviour |
| --- | --- |
| `check`, `validate`, `fmt`, `edit`, `diff`, `schema` | Subcommands, recognised when one is the first argument that is not an option, before any `--` (under `-f` that argument is the program file). See [`check`](#check), [`fmt`](#fmt), [`edit`](#edit), [`diff`](#diff) and [`schema`](#schema). |
| `--from FORMAT` | Read `json` (the default), `jsonc`, `json5`, `ndjson`, `csv`, `tsv`, `toml`, `yaml`, `xml`, `cbor` or `html`, with a spec after a colon where the format has one, as `toml:1.0` ([Formats](#formats)). With no `--from`, the extension of the named files picks the format ([below](#--from-by-extension)). |
| `--to FORMAT` | Write `json` (the default), `jsonc`, `json5`, `ndjson`, `csv`, `tsv`, `toml`, `yaml`, `xml`, `cbor` or `html`. `fmt` writes the `--from` format when `--to` is not given. Each format's output rules are under [Formats](#formats). |
| `--in-place` | `fmt` and `edit` only: rewrite each file through a temporary one and a rename, when `--to` is `--from`. Over more than one file, `stury: N of M files changed` follows on stderr. |
| `--check` | `fmt` and `edit` only: write nothing, name each file that would change on stderr, and exit 1. Over more than one file, `stury: N of M files would change` follows. |
| `--grow-header` | With `--to csv` or `--to tsv`, write a header of every key of every object output ([CSV and TSV output](#csv-and-tsv-output)). |
| `--attributes` | With `--from` or `--to` `xml` or `html`, read each attribute as a member `@NAME` of its element, and write such a member as an attribute ([XML output](#xml-output)). |
| `--delimiter C`, `--no-header`, `--comment C`, `--infer`, `--ragged`, `--lazy-quotes` | How `--from csv` or `--from tsv` reads ([CSV and TSV options](#csv-and-tsv-options)). `--infer` also types the text of `--from xml` and `--from html`. |
| `--out-delimiter C`, `--out-comment C`, `--out-no-header`, `--crlf` | How `--to csv` or `--to tsv` writes. |
| `--alias-limit N`, `--merge-keys` | How `--from yaml` reads: the bytes aliases may read again (1 or more), and `<<` as a merge key. |
| `--expansion-limit N`, `--unread-entities` | How `--from xml` reads: the bytes entity references may expand to in all (1 or more), and a reference to an entity no declaration stury read names, read as its own text. |
| `--max-depth N` | Refuse nesting past N levels (1024 by default, up to 2^20, where jq's limit is 10000). A value deeper than the default also runs on one thread. |
| `--threads N` | `N` threads share a long input, or many files, the calling thread counted (`N` is 1 or more, one per core by default). `--threads 1` starts no other thread. It applies to a filter run, `check`, `fmt`, `edit` and `schema infer`, and the output, exit status and `--explain` counts are the same at every `N`. A run that starts a thread for stack depth (`--max-depth` past 1024) starts it whatever `N` is. |
| `--follow` | With one named file, answer each record as it is appended ([`--follow`](#--follow)). |
| `-g GLOB`, `--glob GLOB` | Pick the files a directory's walk reads ([Many files](#many-files)). |
| `--no-ignore` | Read the files of a walk that ignore rules skip ([Many files](#many-files)). |
| `--files-from FILE` | Read the files FILE lists after the file arguments ([Many files](#many-files)). |
| `--each`, `--no-filename` | Run the filter on each file on its own, its output labelled with the file's name ([Many files](#many-files)). |
| `--explain` | Write the plan the filter runs under and what the run did to stderr, and run the filter as without it ([`--explain`](#--explain)). |

An option of one format given with another `--from` is a usage error that names the format, as `--merge-keys applies to --from yaml`.

### `--from` by extension

| Extension | Format |
| --- | --- |
| `.json` | `json` |
| `.jsonc`, `.json5` | `jsonc`, `json5` |
| `.ndjson`, `.jsonl` | `ndjson` |
| `.csv`, `.tsv` | `csv`, `tsv` |
| `.toml` | `toml` |
| `.yaml`, `.yml` | `yaml` |
| `.xml` | `xml` |
| `.cbor` | `cbor` |
| `.html`, `.htm` | `html` |

- **Case:** upper case extensions count too.
- **Other names:** any other extension reads as JSON, and so does standard input when no file is named. A `-` among the files reads in their format.
- **Mixed files:** each file reads in the format its extension names, so `stury -s . a.json b.yaml` is one array of
  both. `--explain` tells the input and plan again where the format changes.
- **Overrides:** `--from` always wins. `-R` and `--seq` read JSON text whatever the extension.
- **Format options:** the options of one format apply to its files, and are refused when no file names that format,
  so `--delimiter` with `a.csv` reads it.

### Options that differ from jq

| Option | Behaviour |
| --- | --- |
| `-C`, `-M` | `-C` colours output with jq's defaults or `JQ_COLORS`. It is on by default when stdout is a terminal and `NO_COLOR` is unset, and `-M` turns it off. Under `--to jsonc` the output is not coloured, since only the uncoloured printer keeps comments. |
| `--tab`, `--indent N` | `--indent 0` prints each line with no indent, as jq does. N is -1 to 7, and -1 is `--tab`. |
| `-b` | Does nothing outside Windows. |
| `-V` | Prints `stury-` and the release version, or the short commit hash of a source build (`dev` outside a checkout). |
| `--help` | Points to stury(1) and this page, and lists the commands. `stury COMMAND --help` gives that command's own help. |

### Behaviour notes

- Plain paths such as `.a.b[]` are answered without building the document, a YAML document's included. A TOML, XML or
  HTML document is built whole, since a table's members may be written apart and a name needs the namespaces around it.
  These options switch to the general interpreter, which may be slower on large inputs: `-n`, `-s`, `-S`, `-a`, `-e`,
  `-R`, `--raw-output0`, `--seq`, `--stream`.
- Under `--from csv` or `--from tsv`, a filter that only picks columns (`.name`, `.a, .b`, `[.a, .b]`,
  `{a, b: .c}`, `.`, or `select(F)` where `F` reads named columns) is answered from each record's cells,
  without building an object, and on threads for a large file. Any other filter runs on the interpreter.
- A key repeated in one object is read as jq reads it: the last value wins.
- A number is printed as it was written, in the input or the filter: `1E2` stays `1E2` and `0.1e1` stays `0.1e1`,
  where jq prints `1E+2` and `1`. A number a filter computes is printed as jq prints a double (`1e+29`), and a string
  as jq prints it (`"\/"` is `"/"`, DEL is `\u007f`).
- A long input is answered on all cores ([Long input](#long-input)) with the output, exit status and errors of a serial
  run.

### `--explain`

`--explain` writes `stury: explain: KEY: SENTENCE` lines to stderr and runs the filter as it would without the
option, with the same stdout, exit status and other stderr. The plan lines are written once the plan is chosen, before
any input is read, and the run lines when the run ends, normally or on an error. A filter that does not compile has the
`filter` line and its compile error alone. `check` and `fmt` refuse `--explain` as a usage error.

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

The keys come in this order, one line each except `plan` and `because`:

| Key | Says |
| --- | --- |
| `filter` | The filter, quoted. A `-f` file that cannot be read has no line. |
| `input` | The format and how it is cut into inputs: JSON texts one after another, lines (`ndjson`, `-R`), RFC 7464 records (`--seq`), CSV or TSV records, one document per file (`toml`, `xml`, `html`), each document of a stream (`yaml`, `cbor`), or none (`-n`). |
| `plan` | How each input is answered: by reading only a path from the text, by reading only the named columns of each CSV or TSV record, or by building each input whole and running the filter on it. A path plan for `select(PATH op LITERAL)`, `first` or `limit` may add a `plan` line for where the read stops. |
| `because` | Under a built plan, one line for each reason the filter needs it. |
| `decides` | What the speed and the memory follow under this plan. |
| `ran` | How many inputs were read, answered by their path and built. Under a built plan the unit is what the filter runs on: a text, a `--stream` event, a CSV record. |
| `threads` | `one`, or how many pieces of a long input were answered over how many threads ([Long input](#long-input)). |
| `fallback` | The first input that a path plan built after all, and why. Absent when every input was read by its path. |
| `time` | The time to choose the plan, and the time to run it. |
| `used` | The peak memory, the bytes taken (a file mapped or read whole counts in full) and the bytes written to stdout. |

The counts, `threads`, `time` and `used` differ between hosts and runs.

The reasons on `because` lines, each the sentence that line prints:

- **Options:** one reason for each of `-n`, `-s`, `-S`, `-R`, `-e`, `-a`, `--seq`, `--stream` and `--raw-output0`, such as `-s holds the whole input as one array`.
- **Output format:** `--to csv` or `tsv` writes each output as a record. `--to jsonc` prints a value's comments, which reading a path does not keep. `--to toml`, `yaml` or `cbor` has its writer make a text of a built document.
- **Input format:** `--from toml`, `xml` or `html` builds each document whole. `--from json5` would print a path's answer as written (`'a'`, `0x1F`), not as JSON. `--from jsonc` reads only a plain path without building, as a text prints with its comments.
- **Filter shape:** the filter is not a path and not `select(PATH op LITERAL)`, or `select` is redefined, or the `select` has a `[]` in its path or a non-scalar literal.
- **Column plan:** the filter does not name only columns of the record, an object key is not a constant or repeats, a member is not a column (`{a: 1}`), or `select(F)` reads more than named columns. `--no-header`, `--infer`, and `--comment` with `--to csv` or `tsv` also need a built record.

The `fallback` reasons are three. A step met a value it does not apply to (`.a` over a number), where jq's rules answer. The text does not parse, and the filter run reports the fault. A `[]` met an object that repeats a key, which jq gives once.

## `check`

`check` (or `validate`) validates its inputs and prints nothing when they are valid.

- It accepts every input that `stury .` reads without error, several texts included.
- It requires at least one JSON text. An empty or whitespace-only input fails with `No JSON text` and exit 5,
  where `stury .` reads it as a stream of no texts and exits 0.
- With no `FILE` on a terminal it prints the short usage and exits 2, as `stury` with no filter does.
- It judges every file and reports each file's first fault. A long input is judged on all cores and tells the fault a
  serial read tells.
- It refuses every option that shapes a filter run, as `fmt` does (`-n`, `-r`, `-c`, `-C`, `--arg`, `-L`, ...), and
  the layout options `--indent` and `--tab`: exit 2. `check` without `--schema` writes nothing, so `--to` with another
  format is a usage error too.

| Flag | Effect |
| --- | --- |
| `--from FORMAT` | Judge the input as `stury --from FORMAT .` reads it, to the same limits. |
| `--seq` | Judge one record per `0x1E` separator, each record being one text. Each `FILE` is read alone, so a text cut at a file's end is a fault. |
| `--max-depth N`, `--threads N` | As [above](#sturys-own-options). |
| `--schema FILE` | Also check each input against the JSON Schema in `FILE` (drafts 4 to 2020-12). See [Schema check](#schema-check). |

What each `--from` judges:

- **`ndjson`:** one record per line, each one text.
- **`jsonc`, `json5`:** as `stury --from FORMAT .` reads them. `Infinity` and `NaN` fail in JSON5, since jq has no value for them.
- **`toml`:** TOML 1.1. A repeated key, a table defined twice and a malformed datetime are faults. An empty input is valid.
- **`yaml`:** every document of the stream. A repeated key is valid, an alias to an undefined anchor is a fault, and so is a collection as a key. A text of comments alone is valid.
- **`xml`:** a mismatched tag, an undeclared prefix, a reference to an undeclared entity and a repeated attribute are faults. An empty input is a fault.
- **`html`:** the first WHATWG parse error is the fault (`Document without a DOCTYPE`), though `stury --from html .` reads any text, recovering as a browser does.
- **`cbor`:** every item of the sequence. A truncated item, a reserved head and invalid UTF-8 in a text string are faults. An empty input is valid.
- **`csv`, `tsv`:** a fault is told as a filter run tells it ([CSV and TSV](#csv-and-tsv)). An empty input is valid, and so is a header alone.
- **CSV cells:** a cell is a string, or under `--infer` a number, `true` or `false` when its text is exactly one. So `type: integer` takes the cell `1` only with `--infer`. An empty unquoted cell is `null`, and a quoted `""` is the empty string. `schema infer` reads cells the same way, so a schema it writes with `--infer` is checked with `--infer`.

Exit codes: 0 on success, 5 when any input is invalid, 2 for a usage or file error (which wins over 5). With
`--schema`, 1 when an input parses and the schema fails it.

### Schema check

`stury check --schema schema.json [FILE...]` reads, compiles and binds the schema once, then judges each input as `stury check` does and, if it parses, against the schema.

- **Output:** every failure of an input is told, not only the first, as `FILE:LINE:COL: MESSAGE at PATH (KEYWORD-PATH)` on stderr. The message names the bound a value misses or the types it may have (`Number is below the minimum, at least 0`, `expected null or string`). A quoted CSV cell is placed at its opening quote.
- **Unparsed text:** a text that does not parse is the plain `check`'s fault. When the last NDJSON record is cut, the earlier records' failures are told before the fault, and the exit is 5.
- **Records and long input:** NDJSON and `--seq` check each record. A long file, or an array at the root whose rules apply to each entry, is checked on all cores with the output of a serial check.
- **CSV and TSV:** the schema describes the table, an array of its rows, so `{"type":"array","items":{...}}` judges each row and `minItems` counts them.
- **TOML, YAML, XML, HTML:** an input is checked as its format reads it. Each document of a YAML stream is checked and its failures placed in the stream. A TOML datetime is a string. An XML or HTML element's attributes and child elements are its members, and its text is the member `#text`, or the element itself when it has no other.

| Flag | Effect |
| --- | --- |
| `--schema-ref DIR` | The directory a reference to a `file:` URI may read from, by default the schema file's directory. A schema with an `$id` resolves a relative reference against that `$id`, so its `file:` references need an `$id` that is one. |
| `--schema-draft D` | The draft of a schema with no `$schema`: `4`, `6`, `7`, `2019-09` or `2020-12`, the default. A `$schema` names the draft of its schema whatever this says. |
| `--format-assert` | `format` fails an input, where it otherwise only annotates, for the formats the schema's draft defines. A format a later draft defines (`date` in draft 4) and a format no check judges still only annotate. |
| `--max-errors N` | Keep at most `N` failures of an input (default 100). The basic output and the problem document say `"truncated": true` when more were left out, and the lines end with `NAME: more failures past --max-errors N`. |
| `--report lines` | The default. |
| `--report basic` | Write the JSON Schema basic output of each input on stdout, one line a file that is read, `{"file":NAME,"valid":true}` for a valid one. Each error unit has `"valid":false`, and `keywordLocation`, `absoluteKeywordLocation` and `instanceLocation` are JSON Pointers. A keyword location names each keyword as the schema wrote it, whatever its draft. `absoluteKeywordLocation` starts at the innermost resource with an `$id` that holds the keyword, and is absent when the schema has no `$id` there or the location passed a `$ref`, `$dynamicRef` or `$recursiveRef`. For records, a `record` member holds the record's index and the instance location is a pointer into that record. |
| `--report problem` | Write an RFC 9457 problem document of each failing input on stdout, and nothing for a valid one: `file`, `title`, `status` 422 and `errors` of `pointer`, `code` and `message`, and a `record` member in an error of a record input. |

These options need `--schema`, which `check` and [`fmt`](#fmt) take.

A schema that does not read, compile or bind, or a keyword the check does not judge, is a usage error (exit 2) naming it.
The check reads no network: a `$ref`, `$dynamicRef` or `$schema` resolves within the schema, to a draft's meta-schema,
or to a file under `--schema-ref`, and a reference to anything else is refused. A `pattern` with look-behind or a back
reference is refused too. A schema that applies more than 256 subschemas to one value one inside the other does not
bind, and the error names the keyword path where it nests deepest. A value that `uniqueItems`, `const` or `enum`
compares whole fails as `Exceeds the depth limit` past 1024 levels, whatever `--max-depth` allows. A `pattern` search
that runs out of memory on a long string is told as `The pattern could not be decided on the string` and exits 2, not 1,
since the input is neither valid nor failed.

### `check --filter`

`stury check --filter FILTER --schema schema.json` types the filter against the schema of its inputs and reads no
input. It refuses each step that no input the schema describes can take, on stderr as a compile error is told, and
writes the JSON Schema that every output of the filter passes on stdout, shaped by the layout options. It exits 1 when
it refused a step, else 0, and 3 when the filter does not compile (nothing is written then). The schema is written after
a refusal too, and still describes what jq gives the filter at run time: null for a member the input lacks and no output
for a step that fails.

- **Members:** a member read by name (`.emial`, `.["emial"]`, `{emial}`) that no object of the schema describes is
  refused at the name, with the closest member it does describe: `"emial" is not a member of the object the schema
  describes (did you mean "email"?)`. An object that lists members with `properties` or `patternProperties` takes any
  other member, as JSON Schema does, unless `additionalProperties` or `unevaluatedProperties` is `false`. An object that
  lists none describes every member. A `?`, `try` or `//` does not lift the refusal. A path an update or `path` reads
  may name any member, since an update makes it.
- **Kinds:** a step on kinds that never take it is refused as jq would fail it at run time: `.name + 1` when `.name` is
  a string, `.[0]` on an object, `.[]` on a number, `@csv` on an object. A step that some value of its input takes
  passes, and inside `?`, `try` and the left of `//` these steps pass.
- **Output schema:** it keeps the input's description of what a filter reads: `.email` writes the schema's `email`
  member, `{n: .name}` an object of exactly `n`, `.tags | length` an integer. A member that may be absent adds null.
  What the typing cannot follow is written as `{}`, which takes any value: deep recursion, a fold that does not settle,
  `fromjson`, `getpath` of a path that is not a literal. A value the filter computes keeps none of the input's rules.
- **Inputs:** `-n` types the filter on null, `-s` on an array of the inputs, `-R` on strings, and `--arg` and
  `--argjson` variables are their values.
- **CSV and TSV:** `--from csv` or `tsv` types the filter on the records, the row the table schema's `items` describes: an
  object of its member names, each a string or null (a number or a boolean too under `--infer`), or an array of them
  under `--no-header`. A schema that describes no array of rows is a usage error.

FILE operands, `--seq`, `--report` and `--max-errors` are usage errors with `--filter`, as are the options that
shape a filter run's output (`-r`, `-e`, `--stream`, ...).

## `schema`

```sh
stury schema infer [--from FORMAT] [--to FORMAT] [--infer] [--ranges] [--threads N] [FILE...]
stury schema sample [--to FORMAT] [--count N] [--seed N] [--invalid] [--comments] [--schema-ref DIR] [--schema-draft D] SCHEMA
stury schema gen [--package NAME] [--format-assert] [--schema-ref DIR] [--schema-draft D] SCHEMA
```

A schema file, for `check --schema`, `fmt --schema`, `diff` and the schema verbs, is read in the format its extension names (`s.yaml` as YAML, `s.toml` as TOML), and as JSON under any other name. `schema sample --from FORMAT` and `schema gen --from FORMAT` name it instead. A CSV or TSV schema is refused, as a schema is a tree.

### `schema infer`

`stury schema infer [FILE...]` writes the JSON Schema that every record of the inputs passes. Nothing is guessed, so no enum, format or bound appears.

- **Kinds:** the kinds met at each position. A member is required when every object there had it, and the elements of arrays are `items`. Members come in the order they first appear.
- **Maps:** an object with more than 64 names, or with names that are all integers or all UUIDs, is a map: `additionalProperties` and no members.
- **Tables:** a table's schema is an array of row objects. An empty cell is a `null`, so its column is required and its type holds `null`.
- **`--ranges`:** also keeps the least and greatest number, string length and array length (not a table's row count).
- **Exit 5:** a record that does not read, an empty input, and an input whose schema would nest past the depth a JSON text may have (each object level is two in its schema).
- **Output:** the schema is written in the format `--to` names, JSON by default, and a table format is refused. The layout options shape its text as they shape a filter run's output in that format.

### `schema sample`

`stury schema sample SCHEMA` writes values that pass the schema, a text a line, in the format `--to` names.

- **Count and seed:** `--count N` (default 1) and `--seed N` choose how many and which.
- **`--invalid`:** writes values that fail the schema, each a valid one changed in one place.
- **`--comments`:** writes a node's `description` as a comment where the format has comments (`--to jsonc`).
- **Layout:** each value is a line, compact unless a layout option asks for more. A CSV or TSV value is a table, so those take `--count 1`.
- **CSV and TSV:** `--infer` reads the sample's cells as `check --infer` does, so a column of numbers or booleans can be written.
- **No value found:** a schema for which the bounded search finds no passing value is exit 1 and names the keyword path of the node the search stopped at. Under `--invalid` the same holds for no failing value.
- **Options:** `--max-depth` is refused, as sample reads no input. `--schema-draft` and `--schema-ref` read as `check` reads them.

### `schema gen`

`stury schema gen SCHEMA` writes the Odin source of the types a model reads the schema's values with, and a procedure `register` that adds the rules no tag holds to a `model.Registry`, as `schema.write_odin` writes them. It takes no layout option and no filter.

- **Objects:** an object with members is a struct. Its tags name each member (`json:`), say it may be left out, and hold its rules (`model:`). An `extra: map[string]T` member holds the members an `additionalProperties` schema judges, and an object with no members is a map.
- **Enums and unions:** `enum` and `const` are an enum. `anyOf`, `oneOf` and a list of kinds are a union, read by the first arm that reads a value, and under `oneOf` it refuses a value two arms read.
- **Arrays:** `uniqueItems` is a `unique` tag, and `prefixItems` of one type and that length is a fixed array.
- **Fragments:** `not`, `if`, `contains`, `propertyNames`, `patternProperties`, `dependentRequired` and `dependentSchemas` are a named type with a `register_fragment` line, which hands `model.register_schema` those keywords as a JSON Schema fragment. A struct of such a type keeps the members it does not name in `extra: map[string]core.Value` (tagged `json:",unknown"`), so what the type writes is what it read.
- **Optional members:** a member that may be left out and takes no null is a `Maybe` tagged `omitempty` and `not_null`. A struct whose optional members take null holds `set: model.Fields_Set` and tags each such member `omitunset`, so a member the text left out stays out and a null stays null when written back. Gen refuses such a struct past 128 members.
- **Merging:** `allOf` and a `$ref` with siblings are merged into one node. `$defs` are named types.
- **Formats:** `format` only annotates, as `check` reads it: the member is a string with a `// format:` comment. With `--format-assert` the formats a type reads are `time.Time`, `uuid.Identifier` and `model.Email`, and the others a `format=` rule. `contentEncoding: base64` is `model.Base64`.
- **Defaults:** a member's `default` that is a string, a number or a boolean is a `model.register_default` line in `register`, so a load gives the member that value where the text leaves it out.
- **Integers:** an integer whose lower bound is at least 0 and whose range passes `i64`'s is `u64`. Any other integer is `i64`, so a model refuses one past `i64`'s range, which the schema takes.
- **Package:** `--package NAME`, by default the file's name in snake case (`my-types.schema.json` is `my_types`). It must be an Odin identifier that is no keyword and no package the types import (`model`, `time`, `core`, ...).
- **Exit 1:** a keyword no type spells, told with the path of the node that holds it, such as `not` or `if` on a union whose arms take a null they refuse, a `oneOf` with two arms of one type, `prefixItems` beside `items`, an integer enum value past 2^53, an integer whose bounds no `i64` or `u64` holds, or a `default` of an array or an object.
- **Nesting:** every object nested in another is a struct held by value, and Odin's compiler takes time exponential in that depth, so types of objects nested past about 24 levels compile slowly.

## `fmt`

`fmt` writes each input back in the printer's layout, or in another format. It runs no filter, so it takes no `FILTER`.

```sh
stury fmt [--from FORMAT] [--to FORMAT] [--schema FILE [--schema-ref DIR] [--schema-draft D] [--format-assert] [--max-errors N]] [--in-place|--check] [--indent N|--tab] [--max-depth N] [--threads N] [FILE...]
```

- **Formats:** `--from` chooses how each file is read and `--to` how it is written. `--to` defaults to `--from`, so `stury fmt FILE` formats `FILE` as JSON, and `stury fmt --from csv --to json` reads CSV and writes pretty JSON.
- **Idempotent:** `stury fmt` on its own output gives the same bytes. A leading byte order mark is not written.
- **Tables:** each file is formatted as a table of its own. `stury fmt --from csv a.csv b.csv` writes each file's header, where `stury --from csv --to csv . a.csv b.csv` writes one table under the first file's header. A header that names a column twice is refused (`Duplicate header name`).
- **Options:** `fmt` never colours its output. It refuses every option that shapes a filter run (`-C`, `-r`, ..., `--seq`) with exit 2. `-c` is `--indent 0`. `--indent N` and `--tab` apply to a JSON-like `--to`, `--grow-header` to a CSV-like one, and `--max-depth N` and `--threads N` to every output.
- **No `FILE`:** reads standard input (`-`). On a terminal it prints the short usage and exits 2, as `check` does.

What `fmt` keeps, by format:

- **`json`, `jsonc`:** only the layout changes. Every number and string is written as it was (`1e2`, `"é"`, `"\/"`) and every member is kept, a repeated key included. JSONC keeps its comments where `stury --from jsonc --to jsonc .` puts them and drops its trailing commas, so a file already in that layout comes back byte for byte.
- **`ndjson`:** one compact value per line.
- **`toml`:** comments, string quoting, number forms, inline tables, dotted keys and sections, and bare datetimes. Only TOML 1.0 forms are written.
- **`yaml`:** comments, tags, anchors, aliases, a scalar's style, the documents of a stream, and the `%YAML` and `%TAG` lines and explicit `---` or `...`.
- **`xml`:** the doctype, comments, processing instructions, attributes, namespace declarations and references as written. White space between elements is laid out again, and an element that holds text keeps it byte for byte.
- **`html`:** the tree the browser builds, with its implied elements and their tags. The doctype, comments and attributes are kept as written.
- **`cbor`:** each item in preferred serialization, so a head longer than its value needs is written short. A sequence stays a sequence.
- **`csv`, `tsv`:** the header, then one record per row. A field that needs no quotes loses them, one that does gains them, and `""` and an empty cell stay distinct. A JSON text whose root is an array is a list of rows, and any other text, or an NDJSON record, is one row. An object with a key the header lacks ends the run, as `--to csv` does.

### Dropped comments, tags and attributes

Comments, tags and attributes the output format cannot hold are dropped. The exit status is unchanged.

- **`fmt`:** warns on stderr with the count for every target, JSON included: `stury: warning: t.yaml: json cannot hold 3 comments, tags or attributes of the input, so they are dropped`.
- **Filter run to JSON:** drops what the output cannot hold without a warning, and so does a run to JSONC, JSON5 or
  NDJSON. The exception is an XML or HTML node's attributes, which a run to JSON names: `stury: warning: json cannot hold 1 attribute of the input, so it is dropped: .&NAME and .@attrs read them, and --attributes keeps them as members`.
- **Filter run to other formats:** a filter whose output is a node of a document written as YAML, TOML, XML, HTML or CBOR warns with the count, as `fmt` does.
- **Document markers:** YAML's `%YAML` and `%TAG` lines, an explicit `---` or `...`, and the XML declaration are kept only when a format is written to itself, and none of them counts as dropped when it crosses formats.

A tag that states what its value is keeps that meaning in every format that spells it:

- **Datetimes:** a TOML datetime, a YAML `!!timestamp` and a CBOR tag 0 or 1004 on a text are one another's. `fmt --from toml --to yaml` writes `d = 1979-05-27` as `d: !!timestamp 1979-05-27`.
- **Binary:** a YAML `!!binary`, a CBOR byte string and a CBOR tag 34 text are binary. `--to cbor` writes `!!binary aGk=` as the bytes `hi`.
- **Other spellings:** a text that is not the output's spelling of its type is written as a string, and a YAML or CBOR tag it had is counted as dropped, as for a TOML local time in YAML or CBOR.

### `fmt --schema`

`fmt --schema FILE` judges each file against a JSON Schema as `check --schema` does, then formats a file that passes as plain `fmt` does.

- **Failures:** a file that fails is told as `check --schema` tells it, with `--max-errors` limiting the failures told. It is not written, and the exit is 1 while the other files are still formatted. `--in-place` and `--check` leave it as it is and do not call it unformatted.
- **Cells:** an input cell is read as `check --schema` reads it, by `--infer`, and the schema never picks its kind.
- **CSV and TSV output:** it is judged again as it reads back, against `NAME (output)`. When the input is no table, that is by `--infer`, which quotes a string whose text reads as a number, `true` or `false` (TSV has no quotes and refuses one), so `{"n":"5"}` comes back as the string `"5"`.
- **Unwritable values:** a value the output cannot write is exit 5 with the reason, as in plain `fmt`.

### `fmt` flags

| Flag | Effect |
| --- | --- |
| `--check` | Write nothing to stdout. Name each file whose formatted bytes differ from its bytes on stderr (`stury: FILE is not formatted`) and exit 1. Exit 0 when every file is already formatted, and 5 on a fault. A compact JSON text, a CSV field that needs no quotes and a CRLF line ending each count as different. |
| `--in-place` | Rewrite each file through a temporary file in the file's directory and a rename. Mode (and owner and group where permitted) are kept, and other hard links keep the old bytes. A file already in the printer's layout is left untouched, its inode and times included. It needs `--to` to be `--from`, and is refused (exit 2) with `--check`, with standard input and on a non-regular file. |

- **Faults:** a fault names the file and its position, as `check` does: `stury: parse error: FILE:L:C: ...`. A text that ends mid-value is told at its last byte (`printf '[1] [2' | stury fmt` gives `<stdin>:1:6: Unfinished input`). Each file's first fault is told and the run goes on with the next file, which `--in-place` leaves unwritten. The run exits 5.
- **Files:** they are formatted in argument order, and the earlier ones stay rewritten when a later one fails. The run exits with the worst status. A file that does not open is reported with exit 2.
- **Long input:** a long JSON text whose bulk is one array, at its root or under its keys, is printed on all cores with the output of a serial run. CSV and TSV are read whole, as `check` reads them.

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
  "b": [
    2
  ]
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

| Option | Effect |
| --- | --- |
| `--in-place` | Rewrite each named file through a temporary file and a rename, as `fmt` does. A file whose bytes do not change is left untouched. Standard input is refused (exit 2). |
| `--check` | Write nothing to stdout. Name each file the edit would change on stderr, `stury: FILE would change`, and exit 1, or 0 when none would. A fault exits 5. |
| `--diff` | Tell the value changes the edit makes of each file, in `diff`'s form under a `--- FILE` line, and write nothing (with `--in-place` the file is rewritten too). It takes whole documents, so it refuses `--check`, `--seq`, `-R` and NDJSON (exit 2). A change of spacing is not told. |

`edit` refuses `--to` and the options that respell output as a whole (`-r`, `-j`, `--raw-output0`, `-C`), `-n` since the filter would not see the file, `--stream` and `--stream-errors` since their outputs are events, and `--follow`. All are exit 2. Files are edited in argument order, or standard input is read. A fault is told for its file, as `fmt` tells it, the next file is edited, and the run exits with the worst file's status. Errors name `<stdin>` or the file, with the line and column where the input has them.

### Records and documents

- **JSON, JSONC, JSON5:** one text each. The filter must make exactly one output for it, and none or more is an error (exit 5).
- **Records:** CSV and TSV, NDJSON, `--seq` and `-R` lines run the filter on each record, and the outputs are the records written back. A record with no output is dropped with its line end and the comments attached to it. Each output past a record's first is a new record after it, and the first keeps the record's bytes. A record read with `input` or `inputs` is consumed and writes no record of its own.
- **`-s`:** runs the filter once on the array of the records. Each output must be an array, whose items are the records written back in its order. A record the output keeps, moved or not, keeps its bytes. Under `-R -s` the file is one string and the outputs, written raw, are the file.
- **Repeated key:** in a format with no attributes, the last member wins. The filter edits that member and the others with that name keep their bytes. Dropping the key removes every member with that name.
- **`-e`:** sets the exit status by the last output, as for a filter run: 1 when it is false or null, 4 when there is none.

### What an output changes

- **Objects:** the output replaces the document. A kept member keeps its bytes, a new one is inserted, and a dropped one is removed with the comments attached to it.
- **Order:** members take the output's order. A moved member takes its bytes and comments along, and the separators, lines, indent and trailing comma stay in their places. `{a,b}` on `{"b":1,"a":2}` gives `{"a":2,"b":1}`, and `del(.b) | .b = 1` puts `b` last.
- **Arrays:** edited the same way. A kept element, one the output took from the source, keeps its bytes wherever it goes, so `sort`, `reverse` and `map(select(...))` move and drop elements rather than rewrite the array. Any other value replaces the one at that place.
- **Tables:** a column order, a new column and a dropped one change the header and every row the same way, and each kept cell keeps its bytes. A row output may be an object, by the header's names, or an array or a scalar, filling the columns in order.
- **Cells:** a cell is a text, a number, true, false or null, as for `--to csv`. An array or an object is refused, and `tojson` makes text of it. A cell the table cannot write is refused with the file, the record's line and the reason, such as an empty TSV string (an empty TSV cell is null).

### How values are written

- **Source values:** a value the filter took from the input keeps its source spelling.
- **Built values:** a value the filter built is written by jq's writer, with `-a` escaping non-ASCII and `-S` sorting its keys. Where the container's first member starts a line, a built object or array is written one member or element a line, at every level, in the container's indent step and with the spacing around its colon. Where the members share the bracket's line, it is compact. An empty container, and one whose indent step is not a run of spaces or one tab, takes its parent's layout.
- **Layout options:** `-c`, `--indent N` and `--tab` write every built value in their layout instead. `-S` also puts every object of the output in key order, moving the members as a reorder does, and puts a table's columns in order.
- **Numbers:** a literal that rounds to the filter's value is left as written, and in TOML, YAML and CBOR only when the value keeps its type, so `.a = 1` over `a = 1.0` writes `1`. A number the filter computed keeps a literal it equals (`.a |= . + 0` leaves `1.0`), and any other is written in jq's spelling, so `.a += 1` over `a = 1.0` writes `2`.

### Per format

- **TOML:** a kept value keeps its bytes, and a string set over a literal string stays literal when it holds no `'` or control character. A table is not replaced by a value, and `null` is refused with the reason (`Value cannot be written in the format`). A new member is a `key = value` line after the table's last line, before its sub-tables. A built table is a `[section]` after the last section of the table it joins, and a built array of tables is a `[[section]]` per element. It stays inline (`{ y = 2 }`) in an inline container, a dotted table or a value replaced in place. A dropped line goes with the comments directly above it, and a dropped `[table]` with its lines and sub-tables.
- **YAML:** each document of a stream is edited as a record. A document with no output is dropped, each output past the first is a new document after it, and a new or moved document starts with a `---` line when it has none. Each site is edited at its indentation, a comment stays with its line, and a built collection is written in block form on the lines under its key, or in flow form inside a flow collection. A string set over a quoted string keeps its quotes when they hold it, and one line of text over a folded block keeps its `>`. Other scalars take the style YAML's writer picks (`"yes"` is `'yes'`). `--diff` tells the changes of a stream's documents under their indexes (`.[1].a`). An edit inside a value an alias reads, or of an anchored node an alias reads, is refused with the reason (exit 5).
- **CBOR:** each item of a sequence is edited as a record, and the bytes of every item and value the output does not change are copied. A changed value is written in preferred serialization.
- **XML:** a changed value is written between its element's tags, which keep their attributes, and `#text` is the text run it names. A string is escaped and `null` is an empty element. A new member is an element after the member before it, laid out by the white space before that member, and a dropped member goes with the white space before it. A name is one member of the output, and a repeated one an array of its elements in document order, so `.r.b[1]` edits the second `b`. An array on a name writes item k into the name's k-th element, drops the elements past the items, and adds an element for each new item. Any other value is written into the first element and drops the rest. `.r.c.&k = "v"` writes the attribute `k` in `c`'s start tag and `del(.r.c.&k)` removes it. Writing an element's attributes as a whole respells them all, one space apart.
- **XML refusals (exit 5):** an empty string, a key that is no XML name, an array inside an array, an element inside `#text` and a change of member order.
- **HTML:** edits as XML does and writes a changed value as `--to html` writes it. An end tag the source leaves out stays out.
- **HTML refusals (exit 5):** an edit that writes at a node the tree construction made rather than the text (a set of an implied `body`), content in a void element, markup in a raw text, an object whose elements the element they go in reads as other elements (a `tr` set into a `table`), and a result a browser reads as another tree (a `p` written into a `p`).

### Comments

- **Reading and writing:** `.@comment` and its kin work as in a filter run ([Comments in the CLI](#comments-in-the-cli)). `edit` writes the comments of the output value: a role the filter wrote, each of its strings one comment, and `null` removes the role with its line when a comment stood alone on it.
- **Moved and new values:** a value the output takes from another node (`.b = .a`) brings that node's comments for the roles it has. A new member or element is written with its comments and those of the values nested in it. `.a = 1 | .a.@comment = "new"` on `{"b": 2}` gives `{"b": 2,` and then `// new` and `"a": 1}` on lines of their own.
- **Spelling:** a new comment is written as `// text`, or as `/* text */` where the line goes on after it. A head or foot of several comments takes a line for each, and several inline comments follow the value on its line.
- **Tables:** in a CSV or TSV table read with `--comment C`, a comment is a line `C text` above a record or after the last one. `.@comment` on a kept or new record writes its strings as such lines above it. Under `-s` the output array's `.@comment` goes above the header and its `.@comment_foot` after the last record.
- **Refused (exit 5):** a comment a table cannot place (on a cell, inline, or holding a line end), a comment on a table read without `--comment`, and a comment in a format that holds none (`json`, `ndjson`).

## `diff`

`diff` tells what differs between two inputs and exits 1 when something does. Each file is one document, read as
`--from` says, one format for both. A file of records (`--from ndjson`, `--seq`, a YAML stream) is one array of them, so
`.[1]` is its second record.

```sh
$ stury diff old.json new.json
~ .port: 8080 -> 9090
~ .replicas: 3 -> "3"  (number -> string)
+ .tags[1]: "y"
- .debug: true
```

- **Lines:** `+` an added member or element, `-` a removed one, `~` a changed value, with its path in the new
  document, or in the old one for a removal. `(was PATH)` follows a change inside an array element that moved.
- **Matching:** objects match by member name, and numbers by value, so `1.0` equals `1` and member order is no change.
  Arrays match as sequences by default, so one inserted element is one change. `--set` matches equal elements wherever
  they stand, `--position` compares the elements at one index, and `--key MEMBER` pairs elements by the value of their
  member (`--key PATH=MEMBER` for the array at PATH, `--key .users=id`) and compares each pair in depth. An array that
  differs by more than 4,096 edits is told as replaced, and `stury: an array differs...` follows on stderr.
- **`--facts`:** also tells changes of comments, attributes, tags and anchors, where both files' formats carry them: an XML or HTML
  element's attributes as `NAME=VALUE` (`~ .a @attribute: "k=1" -> "k=2"`), a JSONC, JSON5, TOML or YAML comment, and a
  YAML tag or anchor (`~ .a @tag: "!!str" -> "!!int"`). An alias and a style are not told.
- **`--json`:** writes a record a line: `{"path":["port"],"op":"changed","old":8080,"new":9090}`, with the path as
  `getpath` takes it and `op` one of `added`, `removed`, `changed` and `fact`. A change inside an array that
  moved its elements also carries `old_path`.

`--old-schema` and `--new-schema` mark a JSON Schema, never guessed from content.

- **Two schemas:** given together they compare the two schemas and take no file. Each change names the place, the keyword and what it does to the values taken (`widens`, `narrows`, `both`, `unknown`). Then `backward` says whether the new schema takes everything the old one takes, and `forward` the reverse.
- **Verdicts:** `yes` with a proof, `no` with a value one schema takes and the other refuses, or `unknown` with the keyword the proof stopped at. A comparison that reaches its bound answers `unknown` with the reason `budget` or `search`, and never a `yes` or a `no` it did not prove or find a value for.
- **`--compat backward|forward|full`:** exits 1 unless that direction is proven. Without it the exit is 1 for any change.
- **Schema options:** `--format-assert`, `--schema-ref` and `--schema-draft` read as `check` reads them.
- **One schema and one data file:** the data is judged by the schema, as `check --schema` does (exit 1 for a failure). Then each member the data has that the schema does not describe is told as `+ .z  not described by the schema`, which is also exit 1.
- **`--shape`:** compares the shapes of two data files. Each is described as `schema infer` describes it, and the two descriptions are compared and told as above.
- **`--json` with schemas:** a schema change is `{"path":["id"],"keyword":"minimum","old":0,"new":1,"effect":"narrows"}`, and each verdict is a last record (`{"backward":{"verdict":"no","witness":{"id":0}}}`, `{"forward":{"verdict":"yes"}}`).

| Exit | Meaning |
| --- | --- |
| 0 | Nothing differs, or the compatibility asked for is proven. |
| 1 | The inputs differ, or the compatibility is not proven. |
| 2 | A usage or file error. |
| 5 | An input does not parse. |

## Formats

`--from` chooses how the input is cut into values, and `--to` how the outputs are written. Each half is chosen on its own: `--from csv` alone prints JSON, and `--from csv --to csv` writes CSV back. Without `--from`, the files' extensions choose ([above](#--from-by-extension)).

| Format | `--from` | `--to` |
| --- | --- | --- |
| `json` | One JSON text after another, as jq reads (the default). | Pretty-printed, or as `-c`, `--tab` and `--indent` say (the default). |
| `jsonc` | JSONC: comments and trailing commas, one text after another ([Comments in the CLI](#comments-in-the-cli)). | Each value with the comments it was read with. |
| `json5` | JSON5 1.0.0, one text after another, comments kept. | Each value with its comments, in JSON's spelling. |
| `toml` | TOML 1.1, one document per input. | Each output as a TOML text ([TOML output](#toml-output)). |
| `yaml` | YAML 1.2 core schema, one input per document. | Each output as one document ([YAML output](#yaml-output)). |
| `xml` | XML 1.0 with its internal subset, one document per input. | Each output as an XML text ([XML output](#xml-output)). |
| `html` | HTML as a browser builds its tree, one document per input. | The WHATWG serialization ([HTML output](#html-output)). |
| `cbor` | CBOR (RFC 8949), each item of an RFC 8742 sequence one input. | Each output as one CBOR item ([CBOR output](#cbor-output)). |
| `ndjson` | One JSON text per line. | One compact value per line, as `-c`. |
| `csv`, `tsv` | The first record names the fields, each later record is one input ([CSV and TSV](#csv-and-tsv)). | Each output is one record ([CSV and TSV output](#csv-and-tsv-output)). |

- **`json5`:** numbers print in JSON's spelling, and `.@style` names a number's form (`integer`, `float`, `hex`). `Infinity` and `NaN` end the run, as they have no JSON value. `--argjson`, `--slurpfile`, `--jsonargs` and `fromjson` read JSON5.
- **`toml`:** an empty input is `{}`. Tables read as objects in document order. A datetime is a string, and `.@tag` names its kind (`datetime`, `datetime-local`, `date-local`, `time-local`). Hex, octal and binary integers print in decimal. `inf` and `nan` have no JSON value, so a filter sees jq's spelling. `.@style` is a string's quoting (`basic`, `literal`, `multiline`, `multiline_literal`, `bare`), a number's form, or a table's layout: `flow` for an inline table, `dotted` for dotted keys, `block` for a `[section]`.
- **`yaml` scalars:** plain scalars read as `null`, booleans, integers (decimal, `0x`, `0o`) and floats (`.5`, `1e3`, `.inf`, `.nan`). Every other plain scalar, a quoted one and a block one is a string. A stream of several documents is several inputs, and `-s` slurps them.
- **`yaml` keys:** a repeated key keeps its last value, as in JSON. Two keys repeat when they resolve to one type and value, so `a` and `"a"` do, and `1` and `0x1`. `1` and `"1"` are two keys, and a jq object names members by text, so the second of them is the parse error `Duplicate key`. A key that is a collection is a parse error.
- **`yaml` tags:** a core-schema tag forces the type (`!!str 12`, `!!int "12"`), a scalar its tag does not hold (`!!int yes`) is a parse error, and any other tag makes a string. `.@tag` is the tag as written. `.@style` is `plain`, `single`, `double`, `literal`, `folded`, `flow` or `block`, and `hex` or `octal` for an integer so written.
- **`yaml` aliases:** an alias reads as its anchor's node, up to a limit on the bytes aliases read again: ten times the text's size and at least 1 MiB, or `--alias-limit N`. `--merge-keys` reads a `<<` member as YAML 1.1's merge key: the members of the mapping it names that the host mapping lacks are added after its own. Without it `<<` is an ordinary key. A text of comments alone has no input.
- **`xml` shape:** an element is an object member named as written (`p:a` keeps its prefix). An element with no child element is its text (null when empty), and one with children is an object whose text runs are `#text` members. A name that repeats among an element's members is one member, an array of each in document order, so `<r>a<b>1</b>c<b>2</b></r>` reads as `{"r":{"#text":["a","c"],"b":["1","2"]}}`. White space between elements is no text.
- **`xml` text and attributes:** text is a string, or with `--infer` a number, boolean or string by its spelling. Attributes are not members: `.&k` reads attribute `k` as written, `.@attrs` is an object of them all, `.@name` the element's name, `.@namespace` its namespace, `.@content` its text with that of its descendants, `.@pi` the processing instructions and `.@doctype` the document type ([Reading and writing](#reading-and-writing)).
- **`xml` faults and limits:** a prefix with no declaration, a reserved prefix or namespace, and two attributes with one expanded name are parse errors. The internal subset is read: a declared entity expands where it is referred to, and an attribute the subset gives a default is an attribute of every element that lacks it. References that expand past 8 MiB in all, or past a hundred times the text's size when that is more, are a parse error, or past `--expansion-limit N` bytes. No external subset or entity is read: a reference to an entity only one of them could declare is a parse error, or with `--unread-entities` reads as its own text (`&e;`).
- **`html`:** the tree is read in XML's shape, with a browser's scripting disabled. Elements are members named in canonical case (`<IMAGE>` is `img`), including the elements the tree adds (`html`, `head`, `body`, `tbody`). A valueless attribute is `""` and a repeated one reads as its first. Every element has a `.@namespace` (HTML, SVG or MathML).
- **`html` input:** any text reads. A parse error is recovered from as the tree says, and only `check` tells it. A text in an encoding other than UTF-8 is a fault. `--from html:fragment` reads a fragment.
- **`cbor`:** an empty input has no item. Any well-formed and valid item reads, in any serialization. A byte string reads as the string of its base64 (RFC 4648), and so does a byte string key. An integer key reads as its decimal text. A tag reads as its content, and `.@tag` gives its number. A bignum reads as its number, `undefined` and a simple value as `null`. A fault is placed by line and column, counting 0x0A bytes as line ends.
- **`ndjson`:** a blank line is no text. A line that is not one text, or holds two, is a parse error, where jq would read on.
- **Refused options:** `--follow`, `--seq` and `-R` are refused with `toml`, `xml` and `html`, and `--seq` and `-R` with `yaml` and `cbor`.

A format with specs takes one after a colon: `toml:1.0` and `toml:1.1`, `yaml:1.2`, `xml:xml`, `html:document` and
`html:fragment`, and `cbor:cbor`, `cbor:preferred`, `cbor:deterministic` and `cbor:length_first`. `--from toml:1.0`
refuses the forms TOML 1.1 adds, and `--from cbor:preferred` refuses an item in another serialization. `--to
cbor:deterministic` writes RFC 8949's deterministic encoding, keys in the order of their bytes, and `--to
cbor:length_first` sorts the keys by length first. Without a spec TOML reads 1.1 and writes 1.0, HTML reads a document,
and CBOR reads any serialization and writes the preferred one. JSON, JSONC, JSON5, NDJSON, CSV and TSV take no spec.

Every format but `json` cuts the input itself, so reading it is a usage error with `-R` and `--seq`. Output options that
a format's writer does not honour are usage errors as well:

- **CSV, TSV:** refuse `-r`, `-j`, `-a`, `-C`, `-c`, `--indent`, `--tab`, `--seq` and `--raw-output0`, which shape JSON text. `-S`, `-e`, `-n`, `-s`, `--arg` and the rest still apply to a filter run, and `fmt` refuses them ([`fmt`](#fmt)).
- **NDJSON:** `--to ndjson` takes the place of `-c`, so it is refused with `--indent`, `--tab` and `--seq`. `--to jsonc` is refused with `--seq`.
- **TOML, YAML, XML, HTML, CBOR:** refuse `-r`, `-j`, `-C`, `--seq` and `--raw-output0`, and each of `-c`, `--indent`, `--tab`, `-a` and `-S` that the writer does not take. TOML takes `-a` and `-S`, YAML `-c`, `--indent`, `-a` and `-S`, XML and HTML `-c`, `--indent`, `--tab` and `-a`, and CBOR `-S`.

## Input

### Grammar

Every input is read by one grammar, the library's: `json.validate` with `.Json`, or `.Jsonc` under `--from jsonc` and
`.Json5` under `--from json5`. It applies to every input mode, `fromjson`, `--argjson`, `--jsonargs`, `--slurpfile` and
`check`.

- **Nesting:** to `--max-depth N` levels (1024 by default, up to 2^20).
- **Numbers:** of any length and any exponent. A number is kept as it was written and read as a double only where a
  filter computes with it, so `1e400` prints as `1e400` and `1e400 + 0` is `1.7976931348623157e+308`.
- **Option JSON:** `--argjson` and `--jsonargs` keep jq's `invalid JSON text passed to` and add the fault, as
  in `invalid JSON text passed to --argjson: Exceeds depth limit for parsing at line 1, column 2`.

### Line-delimited input

NDJSON needs no flag: several texts in a file are read as jq reads them. `--from ndjson` makes each line one text
([Formats](#formats)), and `stury check --from ndjson` validates the same lines. A text on which jq would error is run
through the general interpreter before any of its outputs print, so the errors and outputs are jq's. Coloured output
builds containers and then paints them, which costs more than plain output.

### Long input

A file of 1 MiB or more is answered on all cores, or on the `--threads N` given, when the filter works on one record, or one entry, at a time. The
output, the exit status and the errors are those of a serial run: each piece's output is written in source order. The
pieces are:

- the records of a file: the lines of an NDJSON file, the texts of a file of concatenated texts, the records of a
  CSV or TSV file;
- the entries of the array that holds the bulk of one JSON text, at its root or under its keys, for a filter
  `.[]` or `.NAME.[]` followed by steps (`.logs[].id`, `.logs[] | select(.status > 400)`);
- the same array, for `.` and `fmt`, which print it in pieces under every layout option, and for `length` and
  `.logs | length`, which count it.

A run stays on one thread under `-n`, `-s`, `-R`, `--stream`, `--stream-errors`, `--unbuffered`, `--grow-header`, `--attributes`,
`--max-depth` past 1024, and a filter that calls `input`, `inputs`, `debug`, `stderr`, `halt`, `halt_error`,
`input_filename`, `input_line_number`, `recurse` with a filter, or a function that calls itself. The array entries and
the array printed or counted are read on all cores in a JSON text only, not JSONC or JSON5, and `.` and `fmt` print an
array in pieces only without colours, comments or CSV output. The records of a `--seq` input are read on one thread. A
text with a fault, or one that does not divide into pieces, is answered whole on one thread, which tells the fault.
`--explain` shows the count of pieces in `ran`. Under `-s` a long CSV or TSV table is built on all cores unless it is
read with `--comment` or `--ragged`, and the filter then runs on one thread.

### Many files

A directory among the FILE arguments is walked, by a filter run, `check`, `fmt`, `edit` and `schema infer`, and its
files are read at its place among the arguments. `diff` refuses a directory.

- **Order:** the byte order of the paths, so a subdirectory's files come at its place among its siblings, as its name
  and a `/`. A walked file's name is the argument as typed joined to the names below it with `/`, on every system:
  `stury . d` reads `d/a.json`.
- **What is read:** a regular file whose extension names a format ([`--from` by extension](#--from-by-extension)),
  or under `--from` that format. Hidden files are read. A symlink is not followed, and `.git`, `.hg`, `.svn` and
  `.jj` are not entered. A file is judged by its name, never by its bytes.
- **`-g GLOB`:** a glob in gitignore's syntax, matched against the path below the directory (`*.json` at any depth,
  `s/*.json` from the top, `**` across directories), case-blind on macOS and Windows. A file a glob matches is read whatever its extension, and once
  a glob reads files, only those a glob matches are. `!GLOB` skips the files and directories it matches. The last
  glob that matches decides.
- **Ignore rules:** inside a git work tree, a directory with a `.git` at or above the walked one, a walk skips what git
  ignores: the `.gitignore` of every directory, the repository's `info/exclude` and the user's excludes file
  (`core.excludesFile` of `~/.gitconfig`, else `$XDG_CONFIG_HOME/git/ignore` or `~/.config/git/ignore`). They match
  case-blind where `-g` does, and a `-g` does not read a file they skip. `--no-ignore` turns them off.
- **Named files:** a file named as an argument is read whatever these rules say, a symlink through to its target.
- **`--files-from FILE`:** the files FILE lists are named files, read after the file arguments: one a line, a CR
  before the LF dropped, or the names between NULs when the list holds one (`git ls-files -z`). `-` reads the list
  from stdin, which then holds no input. An empty list reads nothing.
- **Errors:** a directory that cannot be listed is told as `stury: error: Could not open directory D: REASON` at its
  place, and counts as a file that did not open (exit 2).
- **One stream:** without `--each` the files are one stream of inputs, as jq reads them: `-s` slurps them all, a
  parse error ends the run, and the exit status is the last input's. A run over a directory that ends with exit 2 or 5
  adds `stury: hint: --each runs each file on its own` on stderr.
- **`--each`:** each file is a run of its own, as one `stury` per file would be: `-s`, `-n`, `input`, `inputs` and
  `input_filename` (from the start, under `-n` too) see one file, a file that does not parse or does not open ends
  only its own run, and the exit status is the worst file's: 2, then 5, then 4, then 1, then 0. When more than one
  file is read, each line a file's output writes opens with its name and a colon (`d/a.json:{"a":1}`), in magenta
  under `-C`, or each output under `-j`, `--raw-output0` and `--seq`. `--no-filename` writes no names, and is needed
  with `--to cbor`. `halt` and `halt_error` end the run once the files before are written. Not with `--follow`.

### `--follow`

`stury --follow FILTER FILE` answers each record as it is appended to `FILE`, like `tail -f FILE | stury FILTER` with
no pipe.

- It reads NDJSON, `--seq`, `-R`, several texts per file as jq reads them, CSV, TSV and YAML streams and CBOR
  sequences.
- A record cut short waits for its delimiter, a CBOR item for its last byte, and a YAML document for the `---` or
  `...` line that ends it. The output is written after each record.
- A file that shrinks is read again from its start, with `stury: FILE: file truncated` on stderr.
- SIGINT and SIGTERM end the run, a FIFO's or a pipe's included, once the answers so far are written, by the signal,
  as they end jq. Ctrl-C and Ctrl-Break on Windows end it with jq's status for Ctrl-C, `STATUS_CONTROL_C_EXIT`.
- It is a usage error (exit 2) with standard input or more than one file, `-s`, `-n`, `--stream`, JSONC, JSON5, TOML,
  XML, HTML, `check` and `fmt`.

### Records and events

| Option | Behaviour |
| --- | --- |
| `--seq` | Passes over a record that does not parse with `stury: ignoring parse error: ...` and puts `0x1E` before each output. |
| `--stream` | Gives jq's `[path, leaf]` and `[path]` events of each text, in every format. Of a CSV or TSV record and an XML or HTML document they are the events of the value the reader gives, as `tostream` gives them. Of a JSON text that does not parse it gives jq's events before the fault, then refuses the text as any input. |
| `--stream-errors` | Gives what jq gives of a faulty text: the events before the fault, then `[message, path]`. `[1,` gives `[[0],1]` and then `["Unfinished JSON term at EOF at line 1, column 3",[1]]`. Its messages, positions, exit code and `--seq` resync are jq's, with the exceptions under [Edge cases](#edge-cases). |

### CSV and TSV

`--from csv` reads RFC 4180, and `--from tsv` reads tab-separated values as jq's `@tsv` writes them. The first record of each
file is the header, and every later record is one input: an object whose keys are the header's names, in
order, and whose values are the cells' text as strings.

```sh
$ printf 'name,age\nAda,36\n"Grace ""Amazing"" Hopper",85\n' | stury --from csv -c .
{"name":"Ada","age":"36"}
{"name":"Grace \"Amazing\" Hopper","age":"85"}
$ stury --from csv -r '[.name, .age] | @csv' people.csv
```

- **Cells:** strings or null. A cell is read as a number or a boolean only under `--infer` ([CSV and TSV options](#csv-and-tsv-options)), else convert with `tonumber` (`.age | tonumber`). A comparison reads a cell as the string it is: `.age == 30` is false without `--infer`. A quoted field is its text without the quotes, with `""` read as one quote, and may hold the delimiter and line breaks. An empty unquoted cell is `null` and a quoted `""` is `""`. In TSV, which has no quotes, every empty cell is `null`. `// ""` replaces a `null`. An empty line is no record, so a one-column file spells an empty cell `""`.
- **CSV and TSV syntax:** CSV ends records at LF or CRLF, and a quote opens a field only as its first byte. TSV has no quoting: a quote is text, and `\t`, `\n`, `\r`, `\0` and `\\` read as a tab, LF, CR, NUL and backslash. Any other escape, or a backslash ending a cell, is a fault. A UTF-8 byte order mark at a file's start is skipped.
- **Files:** each file has its own header, and files may have different columns. `-s` slurps every record of every file into one array, and `-n` with `input` and `inputs` reads the records. `input_filename` and `input_line_number` name the file and the line the last record ends at.
- **Faults:** a header name given twice, a record with more or fewer fields than the first, a quote or carriage return where it cannot be, an unfinished quoted field, a bad escape and a byte that is not UTF-8 end the file. The message is `FILE:LINE:COLUMN: fault` (`<stdin>` for standard input), with exit 5, and the records before the fault have been answered. A record of the wrong width is told at the byte where its width is wrong, and says which way. An unfinished quoted field is reported at its opening quote.

  ```
  $ printf 'a,b\n1,2\n3\n' | stury --from csv -c .
  {"a":"1","b":"2"}
  stury: parse error: <stdin>:3:2: Record has fewer fields than the first record
  3
   ^
  ```
- **Memory:** a regular file is read whole. A pipe is read a window at a time, and memory holds a window and the longest record. Records from a pipe are answered as they arrive.
- **Column filters:** a filter that is only columns (`.name`, `.a, .b`, or `[.a, .b]` under `--from csv -c`; a key is a name `.name` can spell, or `.["any text"]`) prints each cell from the text without building an object, with the interpreter's output byte for byte. A name the header lacks prints `null`. The same holds for an object of columns (`{id, q: .qty}`, under `-c` or `--to csv|tsv`, not with `--grow-header`), for `.` under `-c`, and for `select(F)` when F reads only `.name` keys of the record (`select(.qty | tonumber >= 9000)`). A whole file of 1 MiB or more is split across all cores and printed in file order. Any other filter, and `-n`, `-s`, `--no-header` and `--infer`, run on the interpreter. Under `--ragged`, `.` and a filter that reads a column the header lacks, or a column named by digits, build each record.

### CSV and TSV options

These options set how a delimited text is read and written. They are the library's `dsv.Options`, one flag each, with no
short letter, so none clashes with a jq option. A reading option without `--from csv` or `--from tsv`, or a writing one
without `--to csv` or `--to tsv`, is a usage error. They work for a filter run, `check`, `fmt` and `edit`. `check` and
`edit` write no table of their own, so they refuse the writing options, and `edit` writes each record back with the
delimiter and comment character it read.

| Option | Reads or writes |
| --- | --- |
| `--delimiter C` | Cells are split at `C`, one ASCII character (`\t` for a tab), in place of `,` for CSV or a tab for TSV. CR, LF, and under CSV a quote, under TSV a backslash, `t`, `n`, `r` and `0`, are usage errors. |
| `--no-header` | The first record is data. Each record is an array of its cells, and the filter runs on the interpreter. |
| `--comment C` | A line whose first byte is `C` is no record. `C` inside a cell, or at a later byte of a line, is text. CR, LF, the delimiter, and under CSV a quote, under TSV a backslash, are usage errors. |
| `--infer` | An unquoted cell that is exactly a JSON number, `true` or `false` reads as that value. A quoted cell stays a string: `"1"` is `"1"`. The empty cell is `null` with or without it. A table written from a table read with `--infer` quotes a string that would read back as a number, `true` or `false`, so it reads back the same, and TSV, which has no quotes, refuses one. Inference is off by default, as in the library. |
| `--ragged` | A record of any width. A narrower record lacks its missing columns, and a wider one's cells past the header are columns named by their position from 1 (`"3"` for the third). |
| `--lazy-quotes` | CSV: a quote inside an unquoted cell is a byte of it, where it is a fault by default. |
| `--out-delimiter C` | A written table splits cells at `C`. A table written as the format read (`--from csv --to csv`, and `fmt`) keeps the read's delimiter by default, and any other uses its format's own. |
| `--out-comment C` | A written table's comment lines start with `C`, which a first cell starting with `C` is quoted against. A table written from a table keeps the read's `--comment` by default, and any other has none. |
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

#### Comment lines

A filter run over a table read with `--comment C` sees the comment lines above a record as that record's `.@comment`
(the text after `C` and one space, a line each), and `null` for a record with none. So `stury --from csv --comment '#'
--to csv .` writes every comment line back.

- **Header and foot:** the lines before the header are the table's: written above the header of a `--to csv` or `tsv` output, and under `-s` the array's `.@comment`. The lines after the last record are written after the last row, and under `-s` are the array's `.@comment_foot`. Of several files only the first one's lines before its header are written.
- **Spelling:** a comment line is written as `C text`, so `#a` reads back as `# a`. A table written without a comment character drops them.
- **`fmt`:** a table into a table keeps its comment lines. From JSONC to a table with `--out-comment C`, the root array's comments go above the header, each element's above its row, and the root's foot comments after the last row. Inline and cell comments, and one holding a line end, are dropped. `fmt` from a table to YAML or TOML writes one document a record with its comment lines above it, and to JSONC or JSON5 one value a record with `//` line comments.
- **Cost:** a filter that names only columns reads no comments and keeps the column route. `.` and `select(...)` into a table with a comment character, or into YAML, TOML or XML, are built whole, and a long input is then answered on one thread.

### CSV and TSV output

`--to csv` and `--to tsv` write each output as one record. The header is not an output. It is the first
object's keys, written once before the first row. All the files of a run and all its inputs share one table, and rows are written as the outputs come, except under `--grow-header`.

```sh
$ printf '{"a":1,"b":"x,y"}\n{"a":2,"b":null}\n' | stury --to csv .
a,b
1,"x,y"
2,
$ stury --from csv --to csv 'select(.n | tonumber > 1)' people.csv
```

- **Objects are rows:** the header is the first object's keys in their order, or sorted under `-S`. A later
  object with a key the header lacks ends the run: `output 2 has the key "z", which the header lacks (the header is output 1's keys; --grow-header adds keys as they come)`, exit 5,
  after the rows before it. A key the object lacks is an empty cell.
- **`--grow-header`:** holds every output until the input ends, then writes a header of every key in the order
  first seen (in byte order under `-S`), and a row for each object with an empty cell for each key it lacks.
  Memory holds all the output. It is a usage error without `--to csv` or `--to tsv`.
- **Arrays and scalars:** rows with no header. An array's elements are the cells, and a scalar is a row of one
  cell. Objects and the other kinds do not mix: the first output of the other kind ends the run.
- **Cells:** a string is its text, a number is spelled as it was written (`1E3`), `true` and `false` are
  themselves, and `null` and NaN are an empty cell. An array or object in a cell ends the run, and the message
  suggests `tojson`. CSV quotes a cell that holds the delimiter, a quote or a line break, and writes the empty
  string as `""`. TSV escapes tab, LF, CR, NUL and backslash as `@tsv` does.
- **Null and the empty string:** CSV writes `null` as an empty cell and `""` as `""`, so `stury --from csv --to csv .` gives
  back what it read, up to normalisation (a quoted field that needed no quotes is written without). TSV writes
  both as an empty cell and reads every empty cell as null, so `""` becomes `null` there.
- **Refused records:** a record that cannot be written ends the run with the reason. That covers no cell, or one empty
  cell (a lone `null`, `[]`, or `{}` under a one-key header), which would read back as an empty line, and in
  TSV a first cell that starts with a byte order mark.

### TOML output

`--to toml` writes each output as a TOML text, and `fmt` writes a file as TOML. The output must be an object, which is a
table. Only TOML 1.0 forms are written, so a time without seconds gets `:00`.

- **Layout:** scalars, and arrays that are not all tables, are `key = value` lines at the top of a table, a nested object is a `[section]` after them, and an array of objects is a `[[section]]` per element. A table's keys may come out in another order than the input has them.
- **From a TOML input:** a value that is a node of a TOML input is written from the document, which keeps its comments, a string's quoting, a number's form (`0xff` stays `0xff`), a datetime bare, and each table written in line, through dotted keys or as a section as the input has it.
- **From another input:** a node keeps a number form TOML has: YAML's `0o17`, a hex integer and a leading `+` stay, and `5.` or `.5` are written `5.0` and `0.5`. A YAML flow mapping is an inline table, unless a comment inside it needs a line of its own, which makes it a section. A comment inside a table or an array that is an element of an array is written on a line above that element, since TOML 1.0 has no multi-line inline table.
- **Built values:** a value a filter built is a new text, with no comments, inline tables or number forms, but its strings keep their tags: a datetime stays bare, and `"2020-01-01" | .@tag = "date-local"` writes one. A text that is not of its tag's type ends the run, `"2020-13-01" is not a TOML date-local`.
- **Several outputs:** several texts with a blank line between them, which is one TOML file only when no key repeats.
- **Options:** `-S` sorts the keys of every table, and `-a` writes every character past ASCII as an escape (`é`). `stury edit` keeps every byte the filter does not reach.
- **Refused (exit 5):** an output that is no object (`a TOML text is a table, so its root is an object`), or holds `null` or repeats a key (`TOML has no spelling for null or for a key a table repeats`). The error is `stury: error: Value cannot be written in the format: REASON`.

### XML output

`--to xml` writes each output as an XML text, and `fmt` writes a file as XML. The output must be an object of one
member, the root element, so `{"r": ...}` writes `<r>...</r>`.

- **Members:** a member is an element of its name, an array one element of the name per item, and a `#text` member the text that stands there among its siblings, an array its runs one after another. An object is an element's children, `null` an empty element (`<e/>`), and a scalar its text, escaped.
- **Order:** a value keeps no order across names, so `<r>a<b/>c</r>` read and written as a value is `<r>ac<b/></r>`. Only an XML document written whole keeps how its text and elements interleave.
- **From an XML input:** the document, written whole (`.`), keeps its doctype, comments, processing instructions, attributes, namespace declarations and references as written. An update of it keeps the attributes and comments of every element it leaves alone, and of one it replaces, with those it writes (`.r.c |= "C"`, `del(.r.d)`, `.r.&k = "w"`, `.r.c.@comment = ["n"]`).
- **Built values:** a value a filter built is written from its JSON. It has no attributes but under `--attributes`, and its comments come before, after or at the end of the element of the value that holds them.
- **Layout:** pretty output, the default, puts an element whose children are all elements on lines of its own and lays no white space into one that holds text. `-c` writes no white space between elements, `--indent N` sets the indent, `--tab` indents by a tab, and `-a` writes every character past ASCII as a reference (`&#xe9;`). `-S` is refused, as members keep their order.
- **Several outputs:** several texts one after another. An XML text holds one root, so such a run is no one XML file.
- **Refused (exit 5):** an output that is no object (`an XML document is one element, so its root is an object`), or one XML cannot spell so that it reads back (`XML has no element or text for the value`): an object of more or less than one member at the root, a key that is no XML name or holds a colon, an array in an array or an empty array, an empty string or object, an object of only `#text`, and a character XML 1.0 does not allow.

`--attributes` reads the attributes of each element of an XML or HTML input as its first members, `@` and the name
with the value as a string, so `.[].a."@href"` reads the links. An element of text or of nothing that has attributes
is an object of them, with its text as `#text`: `<a href="x">y</a>` reads as `{"a":{"@href":"x","#text":"y"}}` and
`<a href="z"/>` as `{"a":{"@href":"z"}}`. Under `--to xml` or `--to html` a member `@NAME` whose value is a string, a
number or a boolean is written as the attribute `NAME`, and an object left with only `#text` as the element of that
text, so `stury --attributes --to xml .` writes an XML input back with its attributes. The input is a value then, not
the document, so its comments and spellings are not kept, the order of text among elements is not kept, and `--stream`
and `edit` refuse the option.

### HTML output

`--to html` writes each output as HTML, and `fmt` writes a file as HTML, by the WHATWG serialization of a tree.

- **Shape:** the output must be an object. One of one `html` member is a document, and any other is the children of a `body`, as XML's shape reads them. A member is an element, an array one element per item, `#text` the text there, `null` an empty element and a scalar its text.
- **Elements and text:** a void element (`br`, `img`) has no end tag, and a raw text element (`script`, `style`) holds its text as it stands. Any other text and attribute value is escaped (`&amp;`, `&nbsp;`, `&lt;`, `&quot;`).
- **From an HTML input:** the document is written as the browser built it, with the elements the tree adds (`tbody`), and keeps its doctype, comments and attributes as written. An update of it keeps attributes and comments as an XML one does.
- **Layout:** pretty output, the default, puts an element whose children are all elements on lines of its own, and lays nothing into `pre`, `listing`, `textarea` or an element that holds text. `-c`, `--indent N`, `--tab` and `-a` (`&#233;`) work as for XML.
- **Refused (exit 5):** an output that is no object (`an HTML text is a tree of elements, so its root is an object`), or one whose text a browser reads as another tree (`HTML has no text that reads back as the value`): a `td` outside a table, a `div` in a `p`, a void element with content, a raw text holding its end tag, a name or attribute with an upper-case letter, and an array in an array.

### YAML output

`--to yaml` writes each output as a YAML document, and `fmt` writes a file as YAML.

- **Layout:** block style, `--indent N` spaces a level (2 by default, and a sequence's dashes are indented), and `-c` writes flow style on one line. Several outputs are several documents, each after a `---` line.
- **Strings:** a string is plain when every reader that reads YAML 1.1 or 1.2 reads it back as the same string, and is quoted when it is not: `yes`, `no`, `on`, `~`, `null`, a number (`0123`, `0x1F`, `1_000`, `.inf`, `12:30`), and text with a leading space or a `: ` or ` #` in it. A string with a line end is a literal block (`|`), and one read from a folded block (`>`) stays folded. `-a` writes a string with any non-ASCII character as an escaped double-quoted string.
- **From a YAML input:** a node is written from the document, which keeps its comments, tags, anchors, aliases, scalar styles and flow collections. A stream written by `fmt` keeps its documents apart the same way.
- **From another input:** a node keeps a number form the core schema has: TOML's `0o17`, a hex integer, a leading `+`, and JSON5's `.5` and `5.`. A binary integer and underscores are written in decimal.
- **Built values:** a value a filter built is a new text, with no comments, and keeps the tags of its values. `stury edit` keeps every byte the filter does not reach.

### CBOR output

`--to cbor` writes each output as one CBOR item (RFC 8949) in preferred serialization, and `fmt` writes a file as one.
Several outputs are a CBOR sequence (RFC 8742), nothing between the items, and no line end follows an item. An integer
past 64 bits is a bignum, a number past binary64's range a decimal fraction, and a float the shortest of half, single
and double precision that holds it exactly. `-S` sorts the keys of every map.

### Files and pipes

- A regular file is mapped and read whole. A file that shrinks while it is read is reported with its name.
- A pipe, FIFO or socket, and stdin under `--unbuffered`, is read as it comes, up to 8 MiB ahead. Each run of
  whole lines that has arrived is answered before the next, and output is written whenever the reader waits, so
  `tail -f log | stury .msg` answers each line as it lands.
- A text that runs past a block is read on until it ends, under `--seq` into the next file. Answers, messages,
  positions and exit codes are those of the whole read. Memory holds a block, what is read ahead and the
  longest text.
- `-s` and `--from jsonc` read stdin whole, as `check` does. Texts with no newline between them wait for one, as jq's line reads do.

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

**Filter rows and select columns.** `--to csv` writes CSV, header included, so a filter that keeps whole objects writes
the matching rows. An object with fewer keys is a table with fewer columns, and an array is a row with no header.

```sh
$ stury --from csv --to csv 'select(.country == "NO")' cities.csv
city,country,population
Oslo,NO,709000
Bergen,NO,286000
$ stury --from csv --to csv '{city, population}' cities.csv
city,population
Oslo,709000
Bergen,286000
Uppsala,177000
"Ho, Chi Minh",
```

**Aggregate.** `-s` slurps every record into one array for `group_by` and `add`. Cells are strings, so convert
them before adding.

```sh
$ stury --from csv --to csv -s 'group_by(.country)[] | {country: .[0].country, cities: length, people: (map(.population | tonumber? // 0) | add)}' cities.csv
country,cities,people
NO,2,995000
SE,1,177000
VN,1,0
```

**TSV.** `--to tsv` writes jq's `@tsv` text: `stury --from csv --to tsv '{city, country}' cities.csv` gives a tab-separated header and rows. `stury check --from csv cities.csv` prints nothing for a valid file, and a faulty file exits 5 with the fault.

## Errors and exit codes

The exit codes are jq's, but the messages are stury's.

| Fault | Message |
| --- | --- |
| A file that cannot be opened | `stury: error: Could not open file NAME: REASON`. A directory that cannot be listed says `Could not open directory NAME: REASON` |
| An error the filter raises | `stury: error (at FILE:LINE): MSG` as jq. With no input to name, as under `-n`, `stury: error: MSG`, where jq says `(at <unknown>)`. `input` past the last input says `No more inputs`, where jq prints the `break` that `inputs` catches (`try input catch .` still gives `"break"`) |
| `--rawfile` or `--slurpfile` naming a file that does not open | `stury: --rawfile NAME FILE: Could not open FILE: REASON`, where jq calls it `Bad JSON in --rawfile ...` |
| A filter of one word a letter or two from `check` or `fmt` | jq's compile error, then `stury: chek is not a command: did you mean stury check?` |
| A JSON text that does not parse, in a filter run on standard input or one file | `stury: parse error: MSG at line L, column C`, as jq |
| Any other text that does not parse: under `check` and `fmt`, under `--from` another format or `ndjson`, under `--seq`, several files, or `input` under `-n` | `stury: parse error: NAME:L:C: SENTENCE`, NAME `<stdin>` for standard input, counted in that file, such as `<stdin>:1:10: Leading zero in a number` |
| Output that cannot be written, or a stdout that is closed (not under `check`, `fmt --check` or `fmt --in-place`, which write nothing to it) | `stury: error: writing output failed: REASON`, exit 2 whatever the run came to |

L and C are the line and 1-based byte column of the byte the fault is at. A text that ends mid-value is told at its
last byte in every mode, and at column 0 of the next line when its last byte is a newline, as jq places it. An
NDJSON record cut short by its line's end is told at the line's last byte.

Every parse error is followed by the source line, cut to a screenful around the byte, and a caret under it. A
trailing comma, a comment or nesting past `--max-depth` adds the flag that would read it (`--from jsonc`,
`--max-depth N`). So does any other fault of a file read as JSON whose name ends `.csv`, `.tsv`, `.jsonc`, `.json5` or
`.ndjson`: `stury . data.csv` adds `(--from csv reads it)`, except under `--seq`.

| Code | Meaning |
| --- | --- |
| 1 | Under `-e`: the last output is `false` or `null`. Under `fmt --check` and `edit --check`: a file would change |
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

- A value the filter made (`{a: .a}`, `.a + 0`, `[.[]]`, `-s`'s array) prints without comments, and so does every value in it.
- Compact output ends each line comment with a line break, and an output that ends with one gets no second.
- `stury --from jsonc --to jsonc . FILE` keeps every comment of FILE, and gives a file back unchanged when it is already
  in the printer's layout.

### Reading and writing

Facts of a value, such as its comments, tag or attributes, are read and written with `.@NAME` steps.

| Accessor | Gives |
| --- | --- |
| `.@comment` | the leading comments and, on a member's value, the inline ones (`.@comment_head` is the same) |
| `.@comment_inline` | the comments after the value, on its line or past its comma, despite its name |
| `.@comment_foot` | the footer comments |
| `.@tag`, `.@anchor`, `.@alias` | the value's tag, anchor or alias, a string (a number for a tag in a binary format) |
| `.@style` | how the format spells the value, read only |
| `.@name`, `.@namespace`, `.@content` | a markup element's name as written, its namespace URI, and its text with its descendants', read only |
| `.@attrs` | a markup element's attributes, an object of their values by name as written, read only |
| `.@pi`, `.@doctype` | the processing instructions before a node (`target data`), an array, and the document type declaration, read only |
| `.@directives` | the document markers on the root, an array: YAML's `%YAML` and `%TAG` lines and an explicit `---` or `...`, and the XML declaration, read only |
| `.&name`, `.&"name"` | the value of the element's attribute `name` as written, a string or `null` |
| `.&[expr]` | the same, with the name computed: `.&["aria-label"]` |
| `.@(expr)` | the fact whose name `expr` gives, a string of the table above: `.@("com" + "ment")` is `.@comment` |

- **Parsing:** the accessors parse with or without `--from jsonc`, where jq refuses them. jq reads `.@name` only before a string (`.@base64 "x"`), and that still parses as jq's.
- **Unknown names:** a name that is not in the table is a compile error, or with `.@(expr)` an error when the filter runs, as is a name that is not a string. `expr` runs on the input of the whole filter, as the index of `.[expr]` does.
- **Other formats:** the property accessors give `null` in a format that holds none, which includes JSON, JSONC and the tables, and so do the markup accessors outside XML and HTML.
- **Markup facts:** a write of a markup fact other than an attribute, or of `.@directives`, `del` included, is the error `A markup name, namespace, content, instruction, doctype or document marker cannot be written`. A repeated name's array is no element, so its facts are `null` (`.r.b.@name`) and `edit` refuses a write of them. `.r.b[0].&k` is the first `b`'s attribute. An attribute's expanded name (`{uri}k`) is not read by `.&`.
- **Attributes:** `.&k = "v"` writes an attribute and `del(.&k)` removes it, travelling with the value as a comment does. `edit --from xml` and `edit --from html` write them.
- **Values:** each comment accessor gives a list of texts in source order, each without its `//` or `/* */` and one space inside them (`// a` and `/* a */` read `"a"`), or `null` when there are none.
- **Document comments:** a document's leading comments lead its root and its trailing ones trail it. On `{"a": 1} // x` the root's `.@comment_inline` is `["x"]` and its `.@comment` is `null`.
- **Paths:** each accessor is a path step, so `=`, `|=`, `+=` and the other updates, `del`, `path`, `getpath`, `setpath` and `delpaths` take it. In a path it is the object `{"fact": "comment"}` (`"comment_inline"`, `"comment_foot"`): `path(.a.@comment)` is `["a",{"fact":"comment"}]`. It must be the last step. `.&k` is the step `{"fact": "attribute", "name": "k"}`.
- **Writing comments:** a filter writes comments on any value of any format, strict JSON too: `.a.@comment = "x" | .a.@comment` is `["x"]`. A string is one comment, an array of strings one per element, and `null` or `[]` removes them, as `del(.a.@comment)` does. Anything else is the error `a comment is a string, an array of strings, or null`. A role written replaces that role's comments from the input, and the other roles keep theirs.
- **Travelling:** comments travel with their value through pipes, variables, `.a`, `.[]`, `.[n]`, `select`, `if`, `first`, `limit`, array and object construction, and assignment (`.b = .a` gives `b` the comments of `a`). A value computed from others (`.a + 1`, `tostring`, `keys`, `add`, `length`) has none.
- **Replacing a value:** a value put in place of another keeps the old one's comments for each role the new value brings none of. Under `--from jsonc`, `.a = 5` leaves `.a.@comment` as the input had it, and `.a = .b` takes `b`'s comments for the roles `b` has and keeps `a`'s for the rest. This holds for `=`, every update operator and `setpath`.
- **Tags and anchors:** `.@tag`, `.@anchor` and `.@alias` take a string, or `null` to remove it, and `.@tag` a number too, which reads back as its digits. They travel with their value and stay on a value put in place of another as comments do, except a tag the new value is no type of: under `--from toml`, `.a = "soon"` over a datetime writes a string and `.a = "2020-01-01"` a `date-local`, and under `--from yaml`, `.a = 5` over `!!str 1` drops the `!!str`. `edit` refuses the write in a format that spells none, and on a value the file does not hold.
- **Style:** `.@style` is never written: setting it to anything but the style the value has is the error `cannot write a style`.
- **No side effect:** `(.a.@comment = "x") as $_ | .a.@comment` reads the input's comments.
- **Not data:** `==`, `<`, `sort`, `unique`, `group_by`, `contains`, `has`, `keys`, `length`, `tojson`, `tostring`, `paths`, `tostream`, `to_entries` and the `@` formats answer as if there were no comments, and `paths` yields no comment step.

## Builtins beyond jq

These are stury's own, not in jq 1.8.2, and `builtins` lists them. Each takes the input and arguments as values,
gives one output for each combination, and refuses a wrong kind with exit 5. A statistic reads the numbers of an
array, `f` of each element for the form with `f`, and gives `null` for none. A value that is not a number is an error,
`string ("a") cannot be summarized`.

| Builtin | Gives | Example |
| --- | --- | --- |
| `avg`, `avg(f)` | the mean | `[1,2,3,4] \| avg` is `2.5` |
| `variance`, `variance(f)` | the population variance, over `n` | `[1,2,3,4] \| variance` is `1.25` |
| `stddev`, `stddev(f)` | the population standard deviation | `[1,2,3,4] \| stddev` is `1.118033988749895` |
| `median`, `median(f)` | `quantile(0.5)` | `[1,2,3,4] \| median` is `2.5` |
| `quantile(p)`, `quantile(p; f)` | the value at `p` from 0 to 1, interpolated linearly between neighbours (numpy's and R's type 7); another `p` is an error | `[1,2,3,4] \| quantile(0.25)` is `1.75` |
| `frequency`, `frequency(f)` | `[{value, count}]` of `f` of each element, the largest count first, equal counts in `sort` order of the value | `["a","b","a"] \| frequency` is `[{"value":"a","count":2},{"value":"b","count":1}]` |
| `union(b)`, `intersect(b)`, `except(b)` | the elements in either, in both, or only in the input, sorted and without repeats as `unique` gives them | `[1,2,2] \| union([3])` is `[1,2,3]` |
| `fill_forward` | each `null` replaced by the last value before it that was not `null`, per member for an array of objects and per element otherwise; leading nulls stay | `[1,null,2] \| fill_forward` is `[1,1,2]` |
| `melt($ids)`, `melt($ids; $var; $val)` | wide to long: an object per member of a row that is not in `$ids`, holding the row's `$ids` members and `{($var): name, ($val): value}`; the names default to `"variable"` and `"value"` | `[{"id":1,"x":5}] \| melt(["id"])` is `[{"id":1,"variable":"x","value":5}]` |
| `pivot($ids; $var; $val)` | long to wide: an object per distinct `$ids` members, sorted, with a member for each value of `$var` anywhere, sorted, holding `$val` of the last row with it, or `null` | `[{"id":1,"k":"x","v":5},{"id":2,"k":"y","v":6}] \| pivot(["id"]; "k"; "v")` is `[{"id":1,"x":5,"y":null},{"id":2,"x":null,"y":6}]` |
| `fromrfc3339` | seconds since the epoch of an RFC 3339 date-time with any offset, the fraction kept; a space for the `T`, no offset and a day the month lacks are refused | `"2024-06-01T12:34:56.123+02:00" \| fromrfc3339` is `1717238096.123` |
| `torfc3339` | seconds as an RFC 3339 date-time in UTC, years 0000 to 9999, the fraction only when there is one | `1717238096.123 \| torfc3339` is `"2024-06-01T10:34:56.123Z"` |
| `sha1`, `sha256`, `sha512`, `md5` | the digest of a string's UTF-8 bytes as lowercase hex | `"abc" \| sha256` is `"ba7816bf...15ad"` |
| `hmac_sha256(key)`, `hmac_sha512(key)` | the HMAC (RFC 2104) of the string under the key's bytes, as lowercase hex | `"what do ya want for nothing?" \| hmac_sha256("Jefe")` is `"5bdcc146...3843"` |
| `crc32` | the IEEE CRC-32 of the string's bytes, a number | `"123456789" \| crc32` is `3421780262` |
| `hex_encode`, `hex_decode` | a string's bytes as lowercase hex, and back (either case) | `"abc" \| hex_encode` is `"616263"` |
| `base64url_encode`, `base64url_decode` | RFC 4648 section 5, without padding on output, with or without it on input | `"?>?>" \| base64url_encode` is `"Pz4_Pg"` |
| `uuid_v4`, `uuid_v7` | a new RFC 9562 identifier for each call; a version 7 one starts with the Unix time in milliseconds | `uuid_v4` is `"6db2dbb1-2e2f-4683-9f38-bb7920921ae0"` |
| `parse_url` | `{scheme, user, host, port, path, query, fragment}` of a URL reference by RFC 3986; what the URL leaves out is `null`, but `path` is `""` when empty; nothing is percent-decoded | `"https://u@h:8080/a?x=1#f" \| parse_url` is `{"scheme":"https","user":"u","host":"h","port":8080,"path":"/a","query":"x=1","fragment":"f"}` |
| `parse_query_string` | a query as an object of strings, read as the WHATWG URL standard reads application/x-www-form-urlencoded; a name that repeats becomes an array of its values | `"a=1&a=2&b=x+y" \| parse_query_string` is `{"a":["1","2"],"b":"x y"}` |
| `parse_logfmt` | a line of logfmt as an object of strings; a bare key is `true`, `key=` is `""`, a repeated key keeps its last value | `"ok msg=\"a b\"" \| parse_logfmt` is `{"ok":true,"msg":"a b"}` |
| `numfmt(spec)` | a number as text by a printf-like spec, `%[flags][width][.precision]conversion` among literal text; conversions `d`, `f` and `e`, flags `,` `0` and `-`; one conversion per spec, and a spec without one or a number that is not finite is refused | `1234567.891 \| numfmt("%,.2f")` is `"1,234,567.89"` |
| `ip_valid` | whether the input is a string that is an IPv4 or an IPv6 address (no zone or brackets); any other input is `false` | `"::ffff:1.2.3.4" \| ip_valid` is `true` |
| `ip_class` | `"loopback"`, `"private"`, `"link-local"`, `"multicast"`, `"unspecified"` or `"global"` (every other address); an IPv4-mapped IPv6 address is classed as its IPv4 | `"172.16.0.1" \| ip_class` is `"private"` |
| `ip_canonical` | the address in its canonical text: dotted decimal, or for IPv6 RFC 5952 | `"2001:0DB8:0:0:0:0:0:1" \| ip_canonical` is `"2001:db8::1"` |
| `ip_in_cidr(cidr)` | whether the address is in the network `address/length`; an address of the other family is not | `"10.1.2.3" \| ip_in_cidr("10.0.0.0/8")` is `true` |
| `css(selector)` | each element of an XML or HTML input that the CSS selector matches among the input's descendants, in document order, as a path expression: `path(css(s))` gives each one's path, and `\|=`, `del` and `stury edit` change the matched elements alone. Selectors Level 4's static part ([markup.md](markup.md#selectors)). Another input, and a selector out of scope, are errors | `<p><a href="x">1</a><a>2</a></p> \| [css("a[href]")]` is `["1"]` |
| `json_pointer(ptr)` | the value RFC 6901's pointer names in the input; what is not there is `null`, as `getpath` gives | `{"a":[10]} \| json_pointer("/a/0")` is `10` |

A string that is not valid for its decoder, a digest of a number and the like are errors (`"x" | hex_decode` is
`string ("x") is not valid hex data`). A decoded text that is not UTF-8 is read as `@base64d` reads it, each bad
sequence one U+FFFD.

## Differences from jq

stury reads strict RFC 8259 JSON and reports faults its own way. The rest of the language and the options are
jq's. jq has no `check`, `fmt` or `edit`, and `--from` and `--to` read and write formats jq does not. `.@comment`,
`.@comment_inline` and `.@comment_foot`, a syntax error in jq, read and write a value's comments ([Comments in
the CLI](#comments-in-the-cli)).

### Common differences

#### Stricter input

These inputs are rejected with exit 5 (2 for an option's text), where jq 1.8.2 accepts them:

- numbers and literals outside RFC 8259 (`01`, `1.`, `.5`, `+1`, `NaN`, `nan`, `Infinity`, `-Infinity`), whether as
  input, `fromjson`'s text or an option's JSON;
- invalid UTF-8 in a string, which jq reads as U+FFFD;
- any byte after a value that is not whitespace or the next text, a NUL included;
- a lone low surrogate escape (`"\udc00"`), which jq reads as U+FFFD. jq refuses a lone high one too. Either
  is `Invalid escape` at its backslash.

#### Shallower nesting by default

Nesting past 1024 levels (jq: 10000) is refused, `fromjson` included, unless `--max-depth` raises the limit.

#### Different parse errors

A parse error names the fault at the line and column of the byte it was found at, and says what was found and what was
expected: `Expected ',' or ']' after an array element`, `Trailing comma before the closing bracket`, `Missing colon
after key`, `Object keys must be strings`, `Unescaped control character U+0009`, `Invalid UTF-8 byte 0xFF`, `Leading
zero in a number`, `A number cannot start with '.'`. jq's wording differs, and its position is where its parser stood
after the byte:

| | stury | jq |
| --- | --- | --- |
| Message | names what was found and what was expected | its own wording: `Expected separator between values` for a missing `,` or `:`, `Expected another array element` for `[1,]`, `Objects must consist of key:value pairs` for `[1}` |
| Position | the byte the fault is at | where its parser stood after that byte |
| At the end of input | the last byte | the last byte |
| At a newline (`1e` then a newline) | line 1, column 3 | line 2, column 0 |

A filter run on JSON keeps jq's sentence where jq's names the fault (`Unfinished JSON term`, `Invalid numeric literal`,
`Exceeds depth limit for parsing`, `Unexpected text after the JSON value`), and `check` and every other mode say the
library's (`Unfinished input`, `Invalid number`, `Exceeds the depth limit`). A text that ends mid-value is told at its
last byte, which is jq's position, so the plain path, `--stream-errors`, `check` and `fmt` agree at the end of the
input. `fromjson` keeps jq's `Expected JSON value` and `Unexpected extra JSON values`.

#### Files are read separately

Each file ends its texts, except under `--seq` ([below](#--seq-reads-each-record-as-one-text)). jq reads `1` in
one file and `2` in the next as `12`. A parse error in a file after the first names the file
and counts its line and column in that file (`b.json:1:3: Invalid literal` for `2 x`), where jq counts on across the
files it joins.

#### A directory is walked

jq refuses a directory argument (`jq: error: Is a directory`, exit 2). stury reads the files under it
([Many files](#many-files)), so `stury -s . d` is the array of d's texts.

#### `--seq` reads each record as one text

- The bytes up to the next `0x1E` are one text. A record of two texts is a parse error and is skipped whole
  (`␞{}{}` prints nothing), where jq reads several texts in a record and passes silently over an unfinished array
  or object.
- The files are one byte stream: a text cut at a file's end goes on in the next file, and a separator in a later
  file ends it, as jq reads them. A text that is whole where its file ends is not read on, so `1` and a newline in
  one file and `2` in the next are two texts, but a number or literal with nothing after it is read on (`1` then `2`
  in the next file is `12`). A text that runs between files is told at its line and column in the stream, without a
  file's name.
- Before the stream's first `0x1E` no text is a record: it is refused like any faulty record (`ignoring parse
  error: Text before the first RS at line L, column C`, and the stream reads on), where jq drops it silently.

### Edge cases

Each of these is a case in `tools/tests/cli/cases/cli.tsv`.

**Nesting and byte order marks**

- `--max-depth 10000` refuses where jq does, except that jq counts an object's level twice, so it refuses 5001
  nested objects, which stury reads. Past 10000 levels a value prints as jq prints one, `<skipped: too deep>`.
- A byte order mark cut short at the start of the stream, or split across two files, is rejected, where jq passes over or joins it. Under `--stream-errors` the cut mark is passed over as jq does, with jq's `Malformed BOM`.

**Filters**

- In a filter's string literal a lone low surrogate is a compile error, `Invalid escape`, where jq reads U+FFFD.
- After a parse error, `input` reads on from the next line, where jq reads on from its next 4 KiB read.
- `input_line_number` and an error's line count through the end of the line a text ends on. jq counts through
  its last 4 KiB read, so on a longer line it reports 0.
- `range/3` refuses a bound or step that is not a number (`Range bounds must be numeric`), where jq adds it with `+`
  (`[range(null; 3; 1)]` is `[null,1,2]` there). `range` with a NaN bound or step gives no values, where jq's answers vary.
- `sort`, `sort_by`, `group_by` and `unique_by` keep two elements in input order where their keys are both nan, as they
  keep equal keys. jq calls each nan below the other, which leaves the order to the C library's `qsort`.
- jq's `--run-tests`, `--debug-dump-disasm` and `--debug-trace` are unknown options (exit 2).

**`--stream` and `--seq`**

- `--stream` gives each scalar the full path to it, as jq does, so a value nested n levels deep gives Θ(n²)
  bytes of events (nested empty arrays: about 1 MB at depth 1000, 100 MB at 10000). `--max-depth` bounds it.
- Under `--stream-errors` without `--seq`, the walk of a faulty text stops at the end of the line its fault is on, and
  the stream goes on from the next line. A string a raw line break cuts gives `Unfinished string at EOF at line 2,
  column 0` and then the next line's own fault, where jq reads on through the string. A fault after the first is told
  at its line and column in the stream, where jq tells a later fault short of its place.
- Under `--stream-errors` a nesting past the depth limit is a fault, `Exceeds depth limit for parsing`, as under `--stream`,
  where jq's streaming parser has no limit.
- A number cut by `0x1E` or the stream's end is refused under `--stream` too (`Potentially truncated top-level numeric
  value`), where jq reads it. `check --seq` refuses it the same way.
- `check` fails on a JSON input of no text (`No JSON text`), but under `--seq` an empty input, like one of separators
  alone, is no records and passes. `stury .` reads either as no input and says nothing, where jq tells an empty or
  blank input `ignoring parse error: Unfinished abandoned text`.
- Under `--seq`, separators with only whitespace after them are no record, and a BOM at the input's first byte is
  stepped over, as jq does.

**Numbers**

- A number is printed as it was written, where jq prints decNumber's canonical spelling (`1e3` and `1E+3`, `0.1e1` and `1`).
- Numbers are equal, ordered and hashed by the exact decimal a literal spells, at any size, as the library does (`1.0`
  equals `1`, `-0` equals `0`, and `100000000000000000001` is above `100000000000000000000`). jq compares a literal
  that way only within decNumber's range, an adjusted exponent from -1147483646 to 999999999, and reads one past it as
  its double. In stury `1e1000000000` is below `1e1000000001`, and `sort`, `unique` and `group_by` tell them apart:

  ```
  [1e1000000000, 1e1000000001] | .[0] == .[1], (unique | length)
  stury: false, 2
  jq:    true, 1
  ```

- A double is its shortest decimal, so the double that arithmetic made from a literal is another number when the
  literal has more digits (`12345678901234567890123456789012345678901 | . == . + 0` is false, where jq says true), and an
  infinity is above every literal (`infinite > 1e400`).
- A JSON5 decimal with a sign or a point of its own (`+1e400`, `.5e400`), a TOML decimal with underscores
  (`1_000 == 1000`) and a hex, octal or binary integer of any size are compared by the decimal digits they print
  (`0xdead_beef` equals `3735928559`).
- A CSV or TSV cell is a string in a comparison, as `type` says: `.a == 1e-400` is false for the cell `1e-400`. The library's `core.compare` and `core.equal` do the same, unless the document was read with `infer`.
- An integer literal of 18 or more digits is rounded to the nearest double. jq 1.8.2 can be one unit in the last
  place off: `712598146987295425 + 0` is `712598146987295500` in stury and `712598146987295400` in jq. Python's `float()` gives stury's values.

**Dates and times**

- A time past year 2^31 keeps its year: `67767976233532800 | gmtime` is `[2147483648,0,1,0,0,0,3,0]`, where jq
  wraps the year to a negative one.
- `now` has sub-microsecond resolution where the clock has it, so `now - now` need not be 0.
- `strftime`, `todate` and `mktime` of a broken-down UTC time read it as UTC on every OS (`0 | strftime("%z %s")` is
  `+0000 0` whatever `TZ` is); jq does so on macOS only. `strflocaltime` stays local.
- `scalb` and `scalbln` cut a fractional exponent toward zero and saturate a huge one on every OS, as jq on macOS does.
- `gamma` is log-gamma on every OS, as glibc's is: `[1, 2] | map(gamma)` is `[0,0]`. jq on macOS answers `tgamma`.
- `strptime` gives, on every OS, the weekday and yearday as the calendar's values for the array's own year, month and
  day. A day the format does not read is taken as day 0 (`"12:30:00" | strptime("%T")` is weekday 0, yearday -1).
- `builtins` lists the names of jq's, with [stury's own](#builtins-beyond-jq), sorted.

### Regular expressions

Regular expressions run on stury's own engine for Oniguruma syntax, and answer as jq's do for look-around,
backreferences and conditions, named groups, `\g<name>` calls, the absent operator, callouts, case folds that
change a text's length, and the script, emoji and other Unicode properties. Two cases answer differently:

- a lazy `{n,}?` with n of 2 or more over a body that can match the empty string and holds a capture;
- a callout that reads which start positions are tried (`(*ERROR)` with a code other than -1, `(*TOTAL_COUNT)` read
  back), since Oniguruma's choice of starts depends on its optimizer.

The properties and case folds are Unicode 17.0's where jq 1.8.2's Oniguruma holds Unicode 16.0's, so a character
Unicode 17 assigned or reclassified answers by 17.0. The names are Oniguruma's, so a script Unicode 17 added has none.

A choice inside a loop, as in `(a+)+$` or `(a|aa)*b`, runs in time linear in the text, so where jq stops with
`retry-limit-in-match over`, stury answers. A counted repeat around a choice, as in `(a|aa){30,60}c`, still meets
jq's limit.

A JSON Schema `pattern` is not Oniguruma but ECMA-262 with the `u` flag: an escape outside a class names only a syntax
character (`^$\.*+?()[]{}|`) or `/`, and inside a class also `-`, and any other (`\&`, `\%`) is
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

