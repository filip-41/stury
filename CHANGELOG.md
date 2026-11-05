# Changelog

## 0.1.1 (2026-11-05)

The first published release. The `v0.1.0` tag built no artifacts: the release workflow ran the smoke script directly,
and it fails the cases `cmd/stury/test/smoke.floor` records as known failures, where `make test-cli` runs
`smoke_floor.py` and holds only the cases outside the floor. The release now uses the same floor, and this archive
carries the figures in `docs/benchmarks.md`. The rebuilt API described below is unchanged from 0.1.0.

The rebuilt tree, and the first release of the `stury:core`, `stury:json` and `stury:dsv` packages. It builds with
Odin `dev-2026-11` or later and targets 64-bit little-endian systems (darwin and linux, on amd64 and arm64; the
command line also builds on Windows).

### The rebuilt library

The library and the command line are rebuilt on one interface for every format. Code written against the earlier names
changes as follows.

- `csv` is now `dsv`, and reads `Csv`, `Tsv` and `Plain` delimited text. `json` and `dsv` take the format as an
  argument: `json.Spec` is `.Json`, `.Jsonc` or `.Json5` (it replaces `Dialect`), and `dsv.Spec` is `.Csv`, `.Tsv` or
  `.Plain`. A call reads `json.unmarshal(src, .Json, &v)` and `dsv.unmarshal(src, .Csv, &rows)`. The walk settings
  are one `Options` struct per package: `max_depth` and `tolerate` for JSON, and `no_header`, `delimiter`, `comment`,
  `tolerate`, `crlf` and `infer` for dsv.
- Everything a caller uses across formats lives in `core`: documents, readers, paths, edits, `Write_Options` and
  errors. `json` and `dsv` give each format's `validate`, `build`, `find`, `scan`, `set`, `commit`, `unmarshal`,
  `marshal` and `as`. `json.format` formats a text.
- Errors are values with a `kind`, not optional enums or strings. `core.Fault` is a text that breaks the grammar,
  `core.Document_Error`, `core.Path_Error`, `core.Path_Edit_Error` and `core.Typed_Error` the others. One
  `core.render` writes any of them as `line:col: message`, with the path for a typed error, so
  `json.render_error` and `csv.render_error` are gone.
- `find` and `scan` return a `core.Document` and `core.Answer` records, and `core.query` collects the values a path
  reaches from a built document. They replace `Request`, its kinds and `answers`. A path is parsed with
  `core.parse_path` or `core.parse_pointer` once, owns its steps and is freed with `core.path_destroy`.
- Records are in `core/records`: `check`, `open`, `open_stream`, `next`, `each` and a record writer
  (`writer_init`, `write`, `write_text`, `write_cells`, `writer_end`). They replace `records`, `each_record`,
  `validate_records`, `Record_Reader`, `Record_Read` and `records_from`. Framings are `.Lines`, `.Seq`,
  `.Concatenated` and `.Entries`. A stream reads through a window.
- Threads are `host.Pool`, started with `host.pool_init` and lent to `records.each` through `pool.runner`. It
  replaces `host.Batch_Pool`.
- Edits are an `Edit_List` made with `core.edit_list_init`, recorded with `core.set`, `core.set_member`,
  `core.insert` and `core.remove`, each checked as it is recorded, and applied with `json.commit`, `dsv.commit` or
  `core.commit`. `json.set` and `dsv.set` still replace one value at a path. A delimited text commits through the
  list, and removing a cell from every row drops its column.
- Typed reads take an explicit plan from `json.plan_make` or `dsv.plan_make`. A plan belongs to the caller and there
  is no global plan cache, so `plan_cache_clear` is gone. `typed.Read_Options` holds `dups`, `refuse_duplicates`,
  `unknown`, `borrow_strings` and `collect`, and `typed.Plan_Options` holds `enums`, `union_tag`, `tag_names`,
  `hooks` and `rename`. The `unknown` tag flag captures unnamed members into a `map[string]typed.Raw`.
- `core.Duplicates` is `.First` or `.Last`. Refusing a repeated key is the `refuse_duplicates` argument of `build`,
  `find`, `set` and the typed read, and `every_key` is a path read option that answers every matching key.
- `.Lazy` and `Strictness` are gone: a value that is read is always judged by the format's grammar.
  `Options.tolerate` names the rules a text may break, `Invalid_Utf8` and `Lone_Surrogate`.
- Comments are facts on a node with a `core.Role` of `Comment`, `Comment_Inline` or `Comment_Foot`. Read them with
  `core.facts_of` and edit them with `core.set_fact` and `core.remove_fact`.
- `core.Write_Options` sets `pretty`, `indent`, `tab`, `ascii`, `escape_html`, `escape_del`, `sort_keys` and
  `respell_strings` for `marshal`, `format`, `core.write` and the record writer, whichever the format.
- A document keeps its buffers whole, and a build that runs out of memory counts the text and builds again at the
  exact size. `core.length_exact`, `core.member_of` and `core.element_of` read a partial document, where a miss is
  `.Missing` or `.Wrong_Kind`.
- The `stury:core`, `stury:json`, `stury:dsv`, `stury:core/records`, `stury:core/typed` and `stury:host` imports
  replace `stury:json`, `stury:csv` and `stury:host` as they were.

### Command line

- A number keeps any exponent: `1e2147483648` prints as written, and a computation that overflows gives the largest
  double. The "exponent out of range" error and `--strict-limits` are gone.
- `--follow` answers each record of one named file as it is appended. `--max-depth` takes up to 1048576.
- `--to json5` is refused, and `fmt --in-place` and `fmt --check` are refused for JSON5 input. `--to jsonc` writes the
  values and their comments.
- `--explain` writes the filter's plan (route, path or columns, engine, refusals) and what the run did to stderr,
  and runs the filter as without it.
- `--from json5` reads JSON5 in filters, `fmt` and `check`. Error lines and `input_line_number` count the text's
  own lines.
- `check` validates a large root array, or the array of a root object, on the thread pool.
- `--stream` gives the events of a faulty text before its fault, as jq does, and `input_line_number` and the error
  positions under `--stream` count jq's lines. `--stream-errors` gives a faulty text's events as it reads them, not
  all before the first.
- A JSONC or JSON5 input of only comments and whitespace is no input, as a whitespace-only one is.
- Windows: `strftime`'s `%k` and `%l` pad the hour with a space, as jq does, not a zero.
- Regex `\R` no longer matches the trailing byte of a multibyte character that a global match steps into.
- macOS: a pipe named as a path (`/dev/stdin`, `<(...)`) is read wherever a file is: inputs, `--slurpfile`,
  `--rawfile`, `-f`, `check` and `fmt`.
- The differences from jq recorded in `docs/cli.md` are unchanged.
- The command line and the library give the same answer on every format.

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
