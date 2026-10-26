# Changelog

## 0.0.3 (2026-10-26)

Adds typed CSV streaming (`Record_Read`), CSV path answers and record faults like JSON's, and the CLI's `fmt`
verb. One `Read_Opts` per format and one read error replace the per-call options and error types.

### Library

- `json.Record_Read` and `csv.Record_Read` read each record of one type (`record_read_init`, then
  `unmarshal(&rd, ptr)`, which replaces json's `unmarshal(&rd, bytes, ptr)`). A fault's offset is into that
  record's bytes, and `record_read_at` gives the record's offset. It is a handle: the state is on the heap,
  `destroy` frees it, a copy shares it (destroy once), and its options are read on every read, so `duplicates`,
  `limits`, `borrow_strings` and `strictness` set after init apply to the next record. CSV reads an in-memory
  `Records` or a streaming `Record_Reader`, so a CSV stream can be decoded one record at a time (it could not
  before).
- `csv.record_read_init` refuses an iterator whose dialect, limits or strictness differ from the reader's
  (`.Bad_Option`; a `.Lazy` reader also takes a `.Strict` one). A fault that frames no record, and a
  `Record_Reader` whose reader failed (`.Syntax` `.Truncated`, instead of the end of the rows), have an offset
  in the input with `record_read_at` 0, in json and csv alike.
- A type plan that fails to compile reports the same fault on every call; a tag the format cannot spell is
  `.Unsupported` or `.Bad_Tag`, no longer `.Out_Of_Memory`.
- A tag's name may hold a literal comma or backslash (`csv:"Last\, First"`), and a flag other than
  `omitempty`, `required` or `string` refuses with `.Bad_Tag`, a new member of `Marshal_Error` and
  `Unmarshal_Error_Kind`, instead of being ignored.
- An edit list that is unsorted or overlapping is `.Bad_Edit`, where it used to index out of bounds; JSONC
  `remove` answered `.Bad_Result` for the same list.
- A fault at no byte of the source renders one way: `offset N: Kind` when the offset locates it, bare
  otherwise. `Unmarshal_Error` no longer invents a `1:1`.
- `csv.get_float` is false for a cell that is not a number, has no binary64, or is a nonzero value that
  underflows to zero; `1e-400` used to answer `0, true`. A rounded decimal (`0.1`) still reads, and the
  Document readers and `unmarshal` share one cell reader.
- `csv` path edits honour `duplicates`, `strictness` and `limits`: an edit of a name two columns share refuses
  under `.Default`/`.Refuse` instead of silently editing the first, and a source `records` accepts is not refused
  by `set`. `column` keeps its contract and names the first of them.
- A `.Path` scan at `.Structural` that reads to the end reports `coverage` `.Partial`, where it reported `.Full`.
- `core.Record_Fault` is the refused record (`lo`, `hi`, `err`) for every format.
  `csv.validate_records(src, opts, runner, allocator)` lists one fault per refused record in
  source order, so a caller sees every bad row where it saw one. A record ends at the LF that closes it
  outside quotes, so a quoted LF is not its end, and a CR before the LF is not in its bytes. As in
  `json.validate_records`, `err` is only the call's failure (`.Bad_Option`, `.Out_Of_Memory`); a fault of the
  text is a record in `faults`.
- `core.Answer` (`lo`, `hi`, `owner`, `query`, `outcome`), `Answer_Outcome` and `NO_OWNER` are the path answer
  every format returns; `json.Path_Outcome` and `json.NO_OWNER` are core's. `csv.query(doc, path, out)` answers
  paths over a built `Document` without rescanning the text, and `csv.find`/`csv.find_column` return answers:
  `(Answer, Maybe(Error))`, wildcard `[]` and `limit` included.
- `csv.find`, `find_column` and `query` read a repeated header name under `duplicates`: `.Default` and `.First`
  take the first column, `.Last` and `.All` the last, and `.Refuse` is `.Duplicate_Key` at the repeated header
  cell (`.Bad_Source` from `query`). `query` of a name on a document built from an empty text answers nothing,
  as `find` does. A text path starts at the root `.` as in `json`: the bare `[]` is `.Bad_Path`.
- `marshal` refuses a `Number` that is `.None` (`1e400`) with `.Non_Finite`; it used to write `0`. `Digits`
  and `Raw` keep such a number. `Exact` is now `Exactness`'s zero value, so an unset `Number` writes `0`.
- `edit_comment` accepts bare text, the form `fact_text` returns, and writes it as a `//` line.
- `json.Encode_Error` and `json.Encode_Opts` are now `json.Marshal_Error` and `json.Marshal_Opts`, as in `csv` and
  `core`. No alias is kept.
- `csv.document_destroy`, `csv.records_destroy` and `csv.type_plan_destroy` are one `csv.destroy` group, as in
  `json`.
- `core/bits` and `core/path` are folded into `package core` (`core.Step`, `core.parse_path`, the bit kernels).
- `json.Read_Opts` (`dialect`, `strictness`, `duplicates`, `limits`) and `csv.Read_Opts` (the same and
  `no_header`) are the read options. A procedure that honours two or more of them takes `opts := Read_Opts{}`
  before its allocator; its docs name the fields it does not read. `json`: `validate(src, opts, facts)`,
  `find(src, path, opts, allocator)`, `request_init(req, ..paths, opts, allocator)`,
  `build(src, opts, allocator)`, `split_record(rec, opts)`. `csv`: `validate(src, opts, runner)`,
  `records(src, opts, allocator)`, `records_from(r, opts, allocator)`, `each_record(src, task, data, opts,
  runner)`, `build`, `find`, `find_column`, `set`, `insert` and `remove` (`opts` before `allocator`).
  `Request` and both `Unmarshal_Opts` embed `Read_Opts` (`using read`), so `{dialect = .Jsonc}` literals and
  `req.dialect` read as before. Behaviour change: CSV's `header: bool` (default `true`) is now
  `no_header: bool`.
- The JSON edits take `dialect` before `allocator`: `set(src, path, value, upsert, dialect, allocator)`,
  `insert(src, path, at, value, dialect, allocator)`, `remove(src, path, dialect, allocator)`,
  `splice(src, edits, dialect, allocator)`.
- One read error. `scan`, `find`, `request_init` and `build` return `Maybe(Error)`: a request refusal is
  `.Bad_Option` (an option the request cannot honour), `.Bad_Path` (offset into the path text),
  `.Over_Capacity` (a fixed engine limit) or `.Source_Too_Wide`. `parse_path` and `query` return
  `Maybe(Path_Error)` (`.Bad_Path`, `.Over_Capacity`). Removed: `Scan_Error`, `Request_Error`,
  `Request_Error_Kind`, `Capacity`, `Parse_Error`, `Parse_Fault`, and the public `render_error_to_writer`
  of `json` and `csv` (`render_error` takes every error; `core.render_error_to_writer` writes without
  allocating).
- `json.Prepared` is gone. `prepare(&req) -> Maybe(Error)` plans the request itself, and `scan(src, &req)`
  takes the planned route while the plan holds (`request_init` drops it, `destroy` frees it). `scan` has one
  overload.
- `json.records_from` and `json.Record_Reader` are removed; `next_record` and `destroy` lose their reader
  overloads. Read the stream into memory and use `records`. `csv.records_from` stays: the CLI streams CSV
  through it.

### Command line

- `stury fmt [--from F] [--to F] [--in-place|--check] [--indent N|--tab] FILE...` formats or transcodes each
  file, with no filter. JSON, JSONC and NDJSON are written with every number, string and key as written and
  every member of an object, a repeated key included, so only the layout changes; JSONC keeps its comments.
  CSV/TSV is a header and one record per row, each file its own table. It is idempotent; `--check` exits 1
  when a file would change; `--in-place` rewrites each file atomically and leaves already-formatted ones
  untouched.
- The format aliases `--csv`, `--tsv`, `--ndjson` and `--jsonc` are removed. Spell both halves:
  `--from csv --to csv`. `--from` alone reads the format and writes JSON, as before.
- A parse error at the end of the input names the same column jq and `--stream-errors` name, also through
  `fromjson`, `--argjson`, `--jsonargs`, `--slurpfile` and module data. `check` and `fmt` keep the library's
  position.
- `--seq` reads its files as one byte stream, as jq does: a record cut at a file end continues in the next file.
- `debug` and `stderr` lines flush with the output they follow instead of at the end of the input.

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
