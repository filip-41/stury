# Changelog

## Unreleased

- `stury:core` is the interface the formats share; JSON's walk substrate moved out of it to
  `stury:json/scan/walk`: the rows and their stores (`Node`, `Capacity`, `Number_Spelling`), the caps (`Limits`,
  `MAX_DEPTH`, `MAX_SCALAR_DIGITS`), the scan cursor, the query context and its matchers, and the typed walk's
  state (`Shape_Run`, `Shape_Frame`). `json`'s names for them are unchanged.
- `stury:core/spell` spells integers and floats for every format's writer (`spell_i64`, `spell_u64`, `spell_f64`,
  `shortest_digits`, `is_non_finite`), moved from `stury:json/encode`; `stury:core/bits` holds the shared bit
  and UTF-8 kernels.
- `core` declares `Unknown_Fields`, `Unmarshal_Hook`, `Type_Hook(W)` and `Hooked_Plan(W)` (with
  `hooked_plan_init` and `hooked_plan_destroy`); `json` and `csv` alias them,
  so their `Type_Hook` and `Type_Plan` are `core.Type_Hook(Marshal_Hook)` and `core.Hooked_Plan(Marshal_Hook)`
  with the same fields. `core.Value_Class` names the classes a union's arm is picked by.

- CLI: `--from FORMAT` and `--to FORMAT` (`json`, `jsonc`, `ndjson`, `csv`, `tsv`) choose how the input is read
  and the output written. `--ndjson`, `--jsonc`, `--csv` and `--tsv` set both halves, and an explicit `--from`
  or `--to` replaces its half, in either order. Behaviour change: `--ndjson` now prints compact, one value per
  line (it left the layout alone), so `--ndjson --indent N` and `--ndjson --tab`, which printed indented JSON, are
  now a usage error (exit 2); `--to ndjson` is `-c`.
- CLI: `--to csv` and `--to tsv` write each output as one record. An object is a row under a header of the first
  object's keys (sorted under `-S`); a missing key is an empty cell and an extra key ends the run with exit 5.
  `--grow-header` holds the output and writes a header of every key in the order first seen, or in byte order
  under `-S` (memory holds all the output). An array or scalar is a row with no header, and the two kinds do not mix. A string is its text, a
  number is spelled as jq spells it, `null` is an empty cell, and an array or object in a cell ends the run.
  `-r`, `-j`, `-a`, `-C`, `-c`, `--indent`, `--tab`, `--seq` and `--raw-output0` are a usage error with it. A
  filter that is only columns is still printed in pieces and gives what the interpreter gives.
- CLI: `@tsv` writes a NUL as `\0`, as jq does; it wrote the raw byte.
- CLI: reading CSV, an empty cell with no quotes is `null` and a quoted `""` is `""`; every empty TSV cell is
  `null`. `stury --csv .` writes back what it read, up to normalisation; TSV cannot tell `null`
  from `""`.
- CLI: `stury check` takes `--from` and the aliases; CSV and TSV go through `csv.validate` and a fault is told as
  a filter run tells it.
- CLI: `--csv` and `--tsv` read CSV (RFC 4180) and TSV (jq's `@tsv` escapes). The first record of each file names
  the fields, and each later record is one input, an object of strings (`stury --from csv -r '[.a, .b] | @csv'`
  writes back what it read). A repeated header name, a record of another width and a fault in the text end the
  file, told as `FILE:LINE:COLUMN: fault` with exit 5. A file up to 64 MiB is read whole; a larger file, a pipe and
  a file under `-n` are read in windows, so memory holds a window and the longest record. A filter that is only
  columns (`.name`, `.a, .b`, `[.a, .b]` under `--from csv -c`) is printed from the cells, in pieces on every core for a
  whole file. Not with `-R`, `--seq`, `--ndjson`, `--jsonc`, `--stream` or each other.
- `stury:csv`, a CSV codec: `validate` and a `records` iterator over RFC 4180 text, every byte checked (quote
  placement, CR before LF, UTF-8, one field count throughout), with `field_text` reading a field's text, and
  `unmarshal` of records into a list of structs on the shared type plan, columns named by a header or taken in
  order, each cell judged against its field's type, and `marshal` of such a list back to text that `unmarshal`
  reads into equal values.
- CSV dialects: a `Dialect` (delimiter, `Quoting.None` for text where a quote is text, `Escapes.Backslash`, a
  comment byte, ragged records) on `validate`, `records`, `field_text`, `unmarshal` and `marshal`, with `TSV`
  for tab-separated values with backslash escapes (`\t`, `\n`, `\r`, `\0`, `\\`); a `Strictness` (`.Structural` skips the UTF-8 check, and
  `unmarshal` under `.Lazy` judges only the cells it reads); and `Limits.max_fields`. `marshal` refuses a cell
  its dialect cannot spell so that it reads back, and a record that would be a blank line, with `.Unwritable`. The `delimiter` options are now
  `dialect.delimiter`.
- CSV documents and edits: `build` keeps the field spans of a text as a `Document` (`row_count`, `column`,
  `get_string`, `get_int`, `get_float`, `get_bool`, `get_name`), `find` and `find_column` read one cell or one
  column by path (`.[3].name`, `.[3][1]`, `.[].name`) off the front of the text, and `set`, `insert`, `remove`
  and `splice` return the text with a cell, a column, a record or a span changed and every other byte kept. A
  refusal is a `Path_Error`; the edits spell values as `marshal` does and refuse what would not read back as the
  same table.
- CSV `Plan_Opts.hooks`: a `Type_Hook` gives a type a `Marshal_Hook` (appends the cell's text, which `marshal`
  quotes) and an `Unmarshal_Hook` (gets the decoded cell text, never an absent cell, and may refuse it); a field
  of a hooked type is a cell whatever its type.
- CSV `Unmarshal_Opts.duplicates` (`Duplicates`: `Refuse`, `First`, `Last`, `All`) for a header that names a column
  twice, and `unmarshal_check`, which judges a text exactly as `unmarshal` would and keeps nothing.
- CSV `marshal_append` (appends to a buffer, which a refusal leaves as it was) and `marshal_to_writer` (streams
  in bounded chunks; adds `Marshal_Error.Write_Failed`). `marshal` is a wrapper over the same writer.
- CSV `write_record` appends one record of text cells (`[]Maybe(string)`, nil an empty cell that reads back absent)
  to a buffer in a dialect, spelling each cell as `marshal` does. A blank line, which reads back as no record, is
  `.Unwritable`.
- `error_position`, `render_error` and `render_error_to_writer` for CSV, sharing JSON's implementation through
  `core`; JSON's names and outputs are unchanged.
- `Path_Error` and `Path_Error_Kind`: one refusal type for the path procedures of every format, with each
  format's docs listing the kinds it reports. `json.Edit_Error` and `json.Edit_Error_Kind` are now
  `json.Path_Error` and `json.Path_Error_Kind`, whose kinds are renumbered and gain CSV's `Unsupported_Path`,
  `Bad_Option` and `Bad_Row`.
- `Marshal_Error`: one marshal refusal for every format; `json.Encode_Error` and `csv.Marshal_Error` are its
  aliases, so `json.Encode_Error` gains CSV's `Bad_Option` and `Unwritable`, which JSON never reports, and a path refusal's `encode` field is one. `render_error` and `render_error_to_writer`
  write it for CSV as for JSON.
- `Duplicates`: one policy for repeated keys in every format, in core. Its new zero value `.Default` is the
  format's default (JSON `.Last`, CSV `.Refuse`), so a zero-valued option reads as before; `json.Duplicates`
  and `csv.Duplicates` are its aliases, and JSON's is now a `u8`.
- `Error_Kind.Field_Count`, the CSV fault of a record whose field count is not the first record's, and
  `Error_Kind.Limit_Fields`, of a record with more fields than `Limits.max_fields`. JSON never reports them.
- CSV streaming and threads: `csv.records_from` reads the records of an `io.Reader` a chunk at a time, with the
  records, offsets and fault `records` gives the whole; `csv.each_record` hands pieces of a text to a task on a
  `Batch_Runner`'s threads, and `csv.validate` takes one too, with the answer `validate` gives alone.
  `Limits.max_record_bytes` caps a line (`Error_Kind.Limit_Record`), and so the window `records_from` holds. A
  `Record` carries the `src` its fields index. `Batch_Runner` is defined in `stury:core`; `json.Batch_Runner`
  names it.
- `Request` and `Prepared` name their type parameter `$KINDS` (was `$Q`), as the generic procedures that take
  them do. Callers that write `Request({.Path})` are unaffected.
- `marshal` writes an empty `json.Digits` as `null`, as it writes an empty `json.Raw`, instead of failing with
  `.Bad_Raw`.
- `render_error` of an `Unmarshal_Error` ends with its path (`1:11: Wrong_Kind at .a.b`), with `…` when the path
  was truncated.
- `unmarshal`'s `.Unsupported` for a `,string` field, or for two fields writing one key, names that field in the
  error path.
- CLI: `halt_error/1` with a non-number argument names its input as jq does (`number (1) halt_error/1: number
  required`).
- CLI: `select(PATH OP literal)` on a large single document reads only its path, and prints the text only when it
  keeps it, instead of building the whole document.

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
- One error convention and fixed limits throughout. Each public name's doc comment describes it. A
  procedure whose result is its only output carries `@(require_results)`, so a dropped result is a compile
  error.
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
