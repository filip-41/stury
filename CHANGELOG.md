# Changelog

## Unreleased

### Library

- `route_of` names the engine that answers a path of a request, or the reason the automaton does
  (`Path_Route`), without a scan, and refuses a request as `scan` does.
- `Dialect.Json5` reads JSON5 1.0.0 in `validate`, `scan`, `find`, `query`, `build` and `unmarshal`. A
  JSON5 document marshals in JSON's spelling, comments kept; `Infinity` and `NaN` are refused
  (`.Non_Finite` in `marshal`, `.Out_Of_Range` in `unmarshal`). The edits and `Record_Read` refuse it
  (`.Bad_Option`).

### Command line

- `--explain` writes the filter's plan (route, path or columns, engine, refusals) and what the run did (texts scanned or
  interpreted, pieces, fallback, time, cost) to stderr, and runs the filter as without it.
- `--from json5` reads each input as JSON5, transcoded to JSONC; `check --from json5` and `fmt --from json5`
  too. `--to json5` is refused.
- `--stream` gives the events of a faulty text before its fault, as jq does, and `input_line_number` and the
  error positions under `--stream` count jq's lines.
- `--stream-errors` makes a faulty text's events as it gives them, not all before the first.
- macOS: a pipe named as a path (`/dev/stdin`, `<(...)`) is read wherever a file is: inputs, `--slurpfile`,
  `--rawfile`, `-f`, `check` and `fmt`.

## 0.0.3 (2026-10-26)

### Library

- `Record_Read` (json and csv) reads each record of one type; CSV can now decode a stream one record at a time.
- `csv.validate_records` lists every refused record, as `json.validate_records` does (`core.Record_Fault`).
- `csv.query`, `find` and `find_column` answer paths like JSON's (`core.Answer`), honouring `duplicates`.
- One `Read_Opts` per format (`dialect`, `strictness`, `duplicates`, `limits`, and CSV's `no_header`, which
  replaces `header`) is taken before the allocator. The JSON edits take `dialect` before the allocator.
- One read error: `scan`, `find`, `request_init` and `build` return `Maybe(Error)`; `parse_path` and `query`
  return `Maybe(Path_Error)`. `Scan_Error`, `Request_Error`, `Capacity`, `Parse_Error`, `Prepared` and
  `json.render_error_to_writer` are removed; `core.render_error_to_writer` stays.
- Renamed: `Encode_Error`/`Encode_Opts` to `Marshal_Error`/`Marshal_Opts`; the csv destroy procedures are one
  `csv.destroy`. `core/bits` and `core/path` are folded into `core`. `json.records_from` and
  `json.Record_Reader` are removed.
- Refused instead of misread: an unknown tag flag or unspellable tag (`.Bad_Tag`), an unsorted or overlapping
  edit list (`.Bad_Edit`), a `Number` with no finite value in `marshal` (`.Non_Finite`), a CSV cell that
  underflows in `get_float`, and an edit of a CSV column name two columns share.

### Command line

- `stury fmt` formats or transcodes files, keeping every number, string, key and comment as written
  (`--check`, `--in-place`).
- `--csv`, `--tsv`, `--ndjson` and `--jsonc` are removed: use `--from` and `--to`.
- Parse errors at the end of the input name jq's column; `--seq` reads its files as one stream; `debug` and
  `stderr` lines flush in order with the output.
- Windows: filter arguments are read as UTF-8, `-L` takes an absolute path, and `strftime` gives `%s`, `%k` and `%l`.

## 0.0.2 (2026-10-24)

Adds the CSV and TSV codec (`stury:csv`), the shared `stury:core` package, and the CLI's `--from` and `--to`.

### Library

- `stury:csv`: `validate` and `records` check RFC 4180 text (quote placement, CR before LF, UTF-8, one field
  count); `field_text` reads a field. `unmarshal` reads records into a list of structs by header name or by
  order, judging each cell against its field's type; `marshal` writes text that reads back into equal values.
- CSV `Dialect`: delimiter, `Quoting.None`, `Escapes.Backslash`, a comment byte, ragged records, and `TSV`
  (`\t`, `\n`, `\r`, `\0`, `\\`). The `delimiter` options are now `dialect.delimiter`.
- CSV `Strictness` (`.Structural` skips the UTF-8 check; `.Lazy` `unmarshal` judges only the cells it reads)
  and `Limits.max_fields` and `Limits.max_record_bytes`.
- CSV `build` and the `Document` readers (`row_count`, `column`, `get_string`, `get_int`, `get_float`,
  `get_bool`, `get_name`); `find` and `find_column` by path (`.[3].name`, `.[3][1]`, `.[].name`).
- CSV edits: `set`, `insert`, `remove` and `splice` keep every other byte and refuse a result that would not
  read back as the same table.
- CSV hooks (`Plan_Opts.hooks`), `Unmarshal_Opts.duplicates` for a repeated header name, and `unmarshal_check`.
- CSV `marshal_append`, `marshal_to_writer` (adds `Marshal_Error.Write_Failed`) and `write_record`; `marshal`
  refuses with `.Unwritable` a cell its dialect cannot spell and a record that would be a blank line.
- CSV `records_from` (an `io.Reader`, bounded memory), `each_record` and a threaded `validate`, with the same
  answers as the sequential read. A `Record` carries the `src` its fields index.
- CSV `error_position`, `render_error` and `render_error_to_writer`.
- `stury:core` holds what the formats share: `Strictness`, paths, `Duplicates`, `Unknown_Fields`, the hooks
  (`Unmarshal_Hook`, `Type_Hook(W)`), `Hooked_Plan(W)` with `hooked_plan_init` and `hooked_plan_destroy`,
  `Value_Class`, `Batch_Runner` and the errors. `json` and `csv` alias them; `json`'s names are unchanged.
- JSON's walk types (`Node`, `Capacity`, `Number_Spelling`, `Limits`, `MAX_DEPTH`, `MAX_SCALAR_DIGITS`,
  `Shape_Run`, `Shape_Frame`) live in `stury:json/scan/walk`; `json` still exports them.
- `stury:core/spell` spells integers and floats for every writer (`spell_i64`, `spell_u64`, `spell_f64`,
  `shortest_digits`, `is_non_finite`), moved from `stury:json/encode`.
- `json.Edit_Error` and `json.Edit_Error_Kind` are now `Path_Error` and `Path_Error_Kind`, shared by every
  format; the kinds are renumbered and gain `Unsupported_Path`, `Bad_Option` and `Bad_Row`.
- `Marshal_Error` is shared by every format; `json.Encode_Error` is its alias and gains `Bad_Option` and
  `Unwritable`. A path refusal's `encode` field is a `Marshal_Error`.
- `Duplicates` gains a zero value `.Default` (JSON `.Last`, CSV `.Refuse`); `json.Duplicates` is now a `u8`.
- `Error_Kind` gains `Field_Count`, `Limit_Fields` and `Limit_Record` (CSV only).
- `Request` and `Prepared` name their type parameter `$KINDS` (was `$Q`).
- `marshal` writes an empty `json.Digits` as `null` instead of failing with `.Bad_Raw`.
- `render_error` of an `Unmarshal_Error` ends with its path (`1:11: Wrong_Kind at .a.b`, `…` when truncated).
- `unmarshal`'s `.Unsupported` for a `,string` field, or two fields writing one key, names that field.
- `scan` at `.Structural` checks the UTF-8 of values no path reads, as `validate` does.

### Command line

- `--from FORMAT` and `--to FORMAT` (`json`, `jsonc`, `ndjson`, `csv`, `tsv`). `--ndjson`, `--jsonc`, `--csv`
  and `--tsv` set both; an explicit `--from` or `--to` replaces its half, in either order.
- `--ndjson` now prints compact, one value per line, so `--ndjson --indent N` and `--ndjson --tab` are a usage
  error (exit 2). `--to ndjson` is `-c`.
- `--csv` and `--tsv` read each record after the header as an object of strings; an empty unquoted cell is
  `null`, a quoted `""` is `""`, every empty TSV cell is `null`. A fault ends the file with
  `FILE:LINE:COLUMN: fault` and exit 5. Files past 64 MiB, pipes and `-n` are read in windows.
- `--to csv` and `--to tsv` write each output as one record, objects under a header of the first object's keys
  (sorted under `-S`); an extra key ends the run with exit 5. `--grow-header` writes a header of every key.
- Filters that are only columns, an object of columns, `.` or `select` of columns print CSV from the cells,
  on every core for a whole file.
- `stury check` takes `--from` and the aliases; CSV and TSV go through `csv.validate`.
- `@tsv`, `@csv` and `@sh` write a NUL as `\0`, and `@csv`, `@tsv` and `--to csv` write NaN as an empty cell,
  as jq does.
- `halt_error/1` with a non-number argument names its input as jq does.
- `select(PATH OP literal)` on a large single document reads only its path instead of building the document.

## 0.0.1 (2026-10-22)

The first release. It builds with Odin `dev-2026-10` and targets 64-bit little-endian systems (darwin and
linux, on amd64 and arm64).

### Library (`stury:json`, `stury:host`)

- Validation: check a text against RFC 8259 without allocating, with the line and column of the first fault.
- Path queries: read the values at one or more paths without parsing the rest of the text (`find` for one
  path's first answer, a `Request` for more).
- Parsed documents: build a document once and query it, numbers are checked when it is built and decoded when
  read, so the input must outlive the document.
- Typed `unmarshal` and `marshal`: read JSON into Odin structs, slices, maps, unions and `any`, and write Odin
  values back as JSON.
- Byte-preserving edits: `set`, `insert`, `remove` and `splice` change only the bytes they target.
- NDJSON and RFC 7464 records: iterate the values of a line-delimited or record-separated stream.
- JSONC: read comments and trailing commas, and write the comments back.
- Parallel validation and per-record work take threads from `stury:host` (`Batch_Pool`), and the library starts no
  thread of its own.
- A procedure whose result is its only output carries `@(require_results)`.
- On amd64 the floor is x86-64-v2, long strings are scanned 64 bytes at a time where the processor has
  AVX-512BW.

### Command line (`stury`)

- jq 1.8.2's language, answers and exit codes. Its messages start with `stury:` and are worded its own way;
  where stury answers differently, [docs/cli.md](docs/cli.md) lists it. Modules (`import`, `include`, `-L`,
  `~/.jq`), every jq option except `--run-tests` (a test-file runner stury does not have), `--seq`,
  `--stream`, colours, and regular expressions in Oniguruma syntax (with their own engine, so there is no
  dependency on the Oniguruma library).
- New options: `--ndjson`, `--jsonc`, `--max-depth N` (allow nesting past 1024 for every input, `fromjson` and
  option JSON, where jq caps at 10000) and the `stury check` subcommand (`--strict-limits` holds the library's
  digit and scale limits).
- `--jsonc` output keeps the comments of values taken unchanged from the input and drops them on values the
  filter made. Use `.@comment`, `.@comment_inline` and `.@comment_foot` to read them as a list of texts or
  null.
- Large inputs are read and printed on several threads (see `host.Batch_Pool` in `stury:host`).
- Filters that recurse in tail position use constant memory, and recursion can go about a million levels deep.
