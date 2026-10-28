# Changelog

## Unreleased

### Library

- Under `Duplicates.Refuse` every CSV reader and edit refuses any repeated header name, as JSON's refuse a
  repeated key in any object they pass: `unmarshal` no longer only one that names a struct field, `find`, `scan`
  and the edits no longer only one on the path.
- `Dialect.Json5` reads JSON5 1.0.0 in `validate`, `scan`, `find`, `query`, `build` and `unmarshal`. A JSON5
  document marshals as JSON with its comments kept, a hex integer as its exact decimal integer at any width;
  `Infinity` and `NaN` are refused. The edits and `Record_Read` refuse JSON5. `unmarshal` reads a JSON5
  text from its rows: `borrow_strings` borrows its escape-free strings, and `Infinity` or `NaN` is refused only
  where it is read.
- One plan cache serves every format: `core.plan_cache_clear` replaces `json.plan_cache_clear` and
  `csv.plan_cache_clear`.
- One `Type_Plan` serves every format: a plan made by `json.type_plan_init` or `csv.type_plan_init` is taken by
  either format's calls, each compiling its own spelling of the plan on its first call. An option a format does
  not have is ignored by it.
- `Plan_Opts` is one struct for every format (`core.Plan_Opts`): `csv.Plan_Opts` gains `union_tag` and
  `tag_names`, which CSV ignores.
- A field with no tag under a format's key is named by the shared `stury:"name"` tag before its own name.
- One `Marshal_Hook` for every format (`core.Marshal_Hook`): it writes its value through `Marshal_Out`, an opaque handle,
  with `marshal_into`. A csv hook now writes one cell that way; writing none or two is `.Bad_State`.
- An `Unmarshal_Hook` reads a `Hook_Value`, in either format: the value's kind, its text as authored (JSON's
  text, a CSV cell as written) and a string's decoded text, so one hook reads JSON and CSV alike.
- `json.grammar_of(d)` gives what a dialect reads as a `Grammar`, a set of `Grammar_Feature`s (`.Comments`,
  `.Trailing_Commas`, `.Json5_Space`, `.Json5_Keys`, `.Json5_Scalars`), asked by set membership without
  comparing the dialect; `OWN_SPELLING` is the features that spell a token unlike JSON.
- `plain_json` and `own_spelling` take a `^Document`: whether its text is RFC 8259 JSON its rows cover, and
  whether its strings may be spelled unlike JSON.
- `json.Writer` writes JSON token by token (`write_open`, `write_element`, `write_key`, `write_token`,
  `write_number`, `write_float`, `write_string`, `write_close`, `write_comments`, `write_newline`, `write_raw`)
  in a layout, with jq's spelling, `ascii` escapes, jq's `Colors` and a JSONC document's comments when asked.
  The CLI prints through it. `write_led_string` writes a row's member, its lead spelled already, at a write
  cursor.
- `json.number_text` gives a number of a document as JSON text, a JSON5 number converted. `json.jq_literal`
  gives a number literal as jq prints it, and `json.compare_literals` orders two as jq does.
- `json.get_bool` reads a boolean. Every read of a document (`kind`, `get_*`, `child`, `children`, `members`,
  `pointer`, `query`) is `core`'s, over any format's rows; `json` forwards to it. A built document
  (`build`, a `.Dom` request) decodes its escaped keys at build, so no read of it writes and threads may read
  it at once.
- `json.records_from(reader, opts, allocator)` reads the records of an `io.Reader` under every framing, with the
  records, offsets and fault `records` gives over the whole input; `next_record`, `judge_record`,
  `record_window` and `destroy` take its `Record_Reader`, and `record_read_init` takes it in place of a
  `^Records`. Under `.NDJSON` and `.JSON_Seq` its window holds the record being read; under `.None` and
  `.Root_Entries` the whole input.
- `json.Record_Opts.max_record_bytes` caps a record (under `.NDJSON` a line): past it the records end with
  `.Limit_Format` and `json.Fault.Record_Too_Long` at its first byte, and it bounds the window of
  `records_from`.
- `json.Framing.Concatenated` reads jq's input, texts one after another with or without whitespace between
  them, in `records`, `records_from`, `each_record`, `validate_records`, `judge_record` and `Record_Read`, and
  as the format option `framing=concatenated`. A text ends where its strings and brackets say; `records_from`
  holds the text being read.
- `json.records_pushed(opts)` is a `Record_Reader` the caller hands windows to (`record_push`) instead of an
  `io.Reader`, with the records and faults of `records_from`; `record_carry` gives the bytes the next window
  starts with, or that none is wanted.
- `json.next_record_open` and `json.end_record` let a caller's read of a `.Concatenated` text end it: the text
  is handed out open and ends where the read stopped (`.Trailing`), or wants the next window when the read ran
  out of bytes. `json.record_skip` goes on from an offset the caller read up to by other means, or back to one to
  read a record again.
- csv gains `Request`, `request_init`, `scan` and `answers`, reading every path in one pass as JSON's do.
  `csv.find_column` is removed: use a path.
- `csv.Document` is a `core.Document`, read with core's readers and `query` as a JSON document is: under a
  header an array of objects keyed by the header's names, without one an array of arrays, each cell a string
  and an empty cell null. A built document is decoded, so threads may read it at once. `build` is `.Strict`,
  keeps only a repeated header name's first column under `.First` and every column under `.All`, `.Last` and
  `.Default`, and refuses a record wider than the header and a text past u32 offsets (`.Source_Too_Wide`). `row_count`, `column_count`, `column`, `row_fields`, `get_field`, `get_name`, `get_int`,
  `get_float` and `get_bool` are removed: read a cell with `child` and `get_string`, typed values with
  `unmarshal`. `query` reads a headered record by name (`.[1].name`); `find`, `Request` and the edits keep
  rows and columns.
- `csv.header_of`, `header_pick` and `record_document` make one record a document of its own, keyed by a
  `Header` read once from the header record.
- `csv.Table` writes values one at a time as records: objects under a header of the first one's keys, or a
  header of every key with the records held to the end (`grow`), or rows of cells. The CLI's `--to csv|tsv`
  writes through it.
- `route_of` (json and csv) says which engine answers each path of a request, without scanning.
- `json.query_in(doc, n, path, out)` answers a path from node `n`. `json.query` returns `Answer`s, as
  `csv.query` does, and `csv.query` takes no allocator.
- A path with no `Any` step that does not match gives one `.Missing` answer from `query` and a csv `Request`,
  as `find` does.
- `json.upsert` sets a value and adds a missing last member; `set` drops its `upsert` flag.
- Repeated keys under `.Default`: every reader takes the last copy, csv's `unmarshal` and `Record_Read`
  included, and the edits refuse a key or header name repeated on their path. Under `.First` and `.Last`,
  `remove` and `insert` act on the copy `set` finds. A `.Duplicate_Key` refusal is at the repeated key's opening
  quote.
- `json.build` takes every `Duplicates` policy: `.First` leaves each later member of a repeated key out of the
  rows, and `.All` keeps every member, as `.Last` does.
- A `Request` and `find` under `.Lazy` read as `.Strict` under `duplicates` `.Default`, `.Last` or `.All`,
  instead of refusing `.Bad_Option`.
- `core.Document.pruned` says the rows leave out members the text holds; such a document marshals from its rows.
- `json.format(src, read, write, allocator)` reads `src` under `read` (dialect, duplicates and limits) and returns a
  `Path_Error`: a text's fault is `.Bad_Source`, and `Infinity` or `NaN` in JSON5 is `.Encode` with `.Non_Finite`
  at the number. A JSON text read under a raised `max_depth` is written compact by `format` and `marshal`; any
  other output of it stays `.Too_Deep`.
- CSV reads and writes `f16` fields.
- CSV refuses what JSON refuses: an enum value no member has under `enums = .Int`, the `omitempty` tag, a NUL
  read into a `cstring`, and a `Maybe` of a `cstring`.
- A refused allocation while an edit's result is validated is `.Out_Of_Memory`.
- `core.is_space`, `skip_space` and `skip_space_back` are removed: core names no format's whitespace.
- `Error_Kind` holds only kinds every format can report. `Error`, `Unmarshal_Error` and `Path_Error`
  gain `detail`, the format's own fault within a kind, a value of `json.Fault` or `csv.Fault`. `Bad_Literal` is
  `.Bad_Char` with `json.Fault.Literal`; `Field_Count` is `.Bad_Structure` with `csv.Fault.Field_Count`;
  `Limit_Fields` and `Limit_Record` are `.Limit_Format` with `csv.Fault.Too_Many_Fields` and
  `.Record_Too_Long`. `Path_Error_Kind.Bad_Row` is `Bad_Entry`.
- `render_error` writes sentences, not enum names: `1:10: Invalid literal`, `2:6: Value of the wrong kind at .a`.
  An unmarshal `.Syntax` and an edit's `.Bad_Source` read as their fault's text. `json.fault_name` and
  `csv.fault_name` give a format's wording; `core.render_error` and `render_error_to_writer` take one as `name`.
- `render_error` and `error_position` (core, json and csv) take only an `Error`, `Unmarshal_Error`,
  `Path_Error` or `Marshal_Error`, so any other type is a compile error; `error_position` locates every one of
  them where `render_error` writes a `line:col`. An untyped literal argument names its type
  (`json.Error{kind = .Out_Of_Memory}`).
- `marshal` and `marshal_to_writer` (json and csv), csv's `marshal_append` and `write_record` return
  `Maybe(Marshal_Error)`: the refusal's kind, now `Marshal_Error_Kind`, and the path to the value refused
  (`.list[1].leaf.x`, `[1].points`, a cell's `[1]`), which `render_error(nil, err)` writes. A hook and
  `marshal_into` return the kind, as does a path refusal's `encode`.
- `find`, `request_init`, `scan`, `answers` and `route_of` return `Maybe(Path_Error)` in both
  formats, like `query` and the edits. A text's fault is `.Bad_Source` with the fault in `syntax`, `detail` and
  `offset`; `core.source_error` gives it back as an `Error`. `Error_Kind` loses `Bad_Path` and `Over_Capacity`,
  which are path refusals. CSV's `find` and `scan` refuse a path CSV does not answer as `.Unsupported_Path`,
  as `query` does.
- Renamed or changed signatures:
  - `json.Path_Answer` is `Answer` and `Path_Outcome` is `Answer_Outcome`; both formats share them with `Kind`,
    `Node` and `NO_NODE`.
  - JSON's framing is `Record_Opts.framing` (`Record_Opts` embeds `Read_Opts`), read only by
    `records(src, opts, allocator)`, `each_record(src, task, data, opts, runner)` and
    `validate_records(src, opts, runner, allocator)`. `.None` framing keeps the whitespace after the text in
    its record.
  - `json.validate(src, opts, runner)` takes a runner, as csv's does. `validate_facts` collects a JSONC text's
    facts.
  - The JSON edits and `csv.splice` take `opts: Read_Opts` in place of `dialect`. `csv.insert` takes the path `.`
    and an `Insert_At` row.
  - `Records.base` is removed: a record's `at` is its offset in the bytes iterated.
- A `Request`'s inputs (paths, read options, allocator) are set only by `request_init` and are no longer fields
  of the request; `answers` is read-only. A request scanned again plans
  its routing itself, so `prepare` is removed. `validate_remaining`, `Request.coverage`, `Request.stop` and
  `json.Validity` are removed: a `.Strict` scan or `validate` judges a whole text.
- `core.path_edit` makes every format's `set`, `insert` and `remove` over the format's `Edits` (where its edits
  go, and how the result is judged); `core.find` and `core.request_preflight` are every format's `find` and the
  checks its `scan` makes before reading a byte.
- `render_error` is one generic procedure in `json`, `csv` and `core`, over an `Error`, `Unmarshal_Error`,
  `Path_Error` or `Marshal_Error`, and so is `core.render_error_to_writer`; the per-type `core.render_*_error`
  procedures and `core.write_fault_at` are removed.
- `csv.marshal` also writes a document of records (an array of objects or of arrays, from any format) as CSV,
  the objects' keys making the header.
  `csv.table_make` takes `crlf` and `no_header`.
- `MAX_PATH_QUERIES` is the most paths a request is sure to answer, in both formats. csv gains
  `MAX_PATH_STEPS`, `parse_path` and `Answer_Outcome`, as json has.
- The types both formats share are `core`'s, and each format names them: `Read_Opts`, `Unmarshal_Opts`,
  `Request`, `Route`, `Answer`, the row document (`json.Document` is `core.Document`), `Insert_At`, the
  writers' put layer (`core/spell`), and the decimal readers `number_of_loose_text` and `fold_int`.
- `validate` reads its `runner`: a large root array, or the array of a root object such as `{"logs": [...]}`,
  is validated in pieces on its threads, with the verdict and fault offset one thread gives. `build` takes a
  `runner` too and builds a large root array in pieces into the rows one build gives. `csv.build` takes a
  `runner`, which it does not read.
- `json.find_spine`, `json.split_array` and `json.frame_entries` find where one large text's bulk is and cut it
  into pieces for threads (`json.Spine`, `json.Piece`), and `json.pieces_pass`, `json.pieces_docs` and
  `json.pieces_build` run the pieces on a `Batch_Runner`; `core.piece_fan` is the parallel for they share.
  `core.row_document_destroy` frees any format's document.
- `json.judge_record` gives a record's fault as its framing tells it: a literal the next byte cut, a byte order
  mark leading a later record, a `.JSON_Seq` number alone (`.Truncated` with `Fault.Cut_Number`), and a
  `.JSON_Seq` record's complete value before stray bytes. It replaces `split_record`, and core's Record group
  gains `judge`. `records` and `validate_records` report that number with `Fault.Cut_Number`, which
  `render_error` tells as `Potentially truncated top-level numeric value`, as jq does.
- `csv.record_window` and `csv.open_field_at` give a record reader's buffered window and where its open record
  and field start.
- `unmarshal` of a `Record_Read` returns `(more, err)` in both formats: `more` is false once no record is left,
  with `err` nil at the input's end, where it was `.Bad_Option`, or the fault that framed no record.
- Only the overload groups are public: `json.unmarshal_value`, `json.unmarshal_record`, `csv.unmarshal_records`,
  `csv.unmarshal_record` and `csv.record_read_destroy` are private; call `unmarshal` and `destroy`.
- `destroy` takes a `json.Records`, as it takes a `csv.Records`, and `json.records` drops its unused `allocator`.
- `validate_records` gives `err` one meaning in both formats: what ended the records, a framing fault (JSON) or
  `.Out_Of_Memory`, with `faults` the records refused before it. A CSV record whose fields could not be
  allocated was a fault in `faults`; it is `err` now.
- `Error_Kind.None` is gone, and no kind is 0: an `Error` is always in a `Maybe`, and `Path_Error.syntax` is
  set for every `.Bad_Source` and `.Bad_Result`. A JSONC `splice` whose bytes open a comment that swallows
  source bytes is `.Unplaceable` at the edit's `lo`, not `.Bad_Result` with no `syntax`.
- `each_record`'s task takes its data as `^D`, the type of the `data` pointer passed, not a `rawptr`, in
  both formats.
- `host.batch_pool_destroy` is `host.destroy`.
- `json.Records` and `csv.Records` keep the iterator's fields in a private `state`; `err` is the one to read.
- `csv.Quoting` gains `Backslash`, which replaces `Escapes` and `Dialect.escapes`: `TSV` is
  `{delimiter = '\t', quoting = .Backslash}`, and backslash escapes under quotes can no longer be asked for.
  csv's `set_option` takes `quoting=backslash`; `escapes` is no longer an option.
- `csv.write_record(out, cells, opts, at_start)` takes a `Marshal_Opts` in place of `dialect` and `crlf`, and
  `csv.Table` holds one (`table_make(opts, grow, sort_keys, allocator)`). `csv.insert` takes a row of cells as
  `[]Maybe(string)`, nil an empty cell; a `[]string` is `.Encode` with `.Unsupported`.
- `json.edit_comment` and `Comment_Op` are replaced by `insert_comment`, `set_comment` and `remove_comment`,
  each reading the source under `opts` (`.Jsonc` by default; a dialect without comments is `.Bad_Option`).
- `csv.unmarshal`, `unmarshal_check` and `marshal` take rows that are a slice or dynamic array of one cell type
  (`[][]string`, `[][]Maybe(string)`), every record one row, header included, or a map of string keys to one
  cell type (`[]map[string]string`), keyed by the header; `marshal` writes a map row's header as the sorted keys
  of every row.
- `marshal_append(out, v, opts, plan)` and `marshal_append(out, &doc, opts)` in both formats append what `marshal`
  writes after the bytes already in `out`, which is as it was on a refusal. json gains it; csv's takes a
  document too.
- `json.Document_Opts` holds `jq_spelling`, which only a `Document` is written under: `Marshal_Opts` loses it, and
  `marshal(&doc, ...)`, `marshal_to_writer`, `marshal_append` of a document and `format`'s `write` take a
  `Document_Opts`, which embeds `Marshal_Opts` (`{jq_spelling = true, pretty = true}` still reads).
- `Marshal_Opts.sort_keys` sorts a typed value's struct fields too, a tagged union arm's tag among them (json),
  and csv gains it: the header in byte order for struct rows, a document and a `Table`. `table_make` loses its
  `sort_keys` parameter for `opts.sort_keys`.
- `answer_text(src, a, opts, allocator)` in both formats reads a found scalar answer's text with one result,
  `(text, escaped, ok)`: a string decoded by the dialect's escapes (a CSV cell as `field_text` reads it), any
  other JSON scalar as written.
- `csv.Record` carries the `dialect` it was read in, so a field is decoded only by it: `field_text(rec, k,
  allocator)` returns field `k`'s text as a `string`; `header_of(rec, duplicates, allocator)` and
  `record_document` read `rec.dialect`, and `Header.dialect` is gone.
- csv `Record_Read` reads the rows `unmarshal` reads: a list of cells (`[]string`), every record one row, header
  included, and a map of cells (`map[string]string`) keyed by the header's names, which the reader keeps until
  `record_read_destroy`.
- `unmarshal` and `record_read_init` take `allocator` as a required argument in both formats: a read frees
  nothing, a refused one included, so the caller names where the value lives and frees it whole.

### Fixes

- csv `marshal` no longer reads freed memory when a write hook passes `marshal_into` a value of a type the plan
  has not met yet: the rest of the row, the next cell of a list or map row, and the path of a refusal are read
  from the plan as it is after the hook.

### Command line

- `check` validates a large root array, or the array of a root object, on the batch pool.

- `--explain` writes the filter's plan (route, path or columns, engine, refusals) and what the run did to stderr,
  and runs the filter as without it.
- `--from json5` reads JSON5 in filters, `fmt` and `check`. Error lines and `input_line_number` count the
  text's own lines. `--to json5` is refused.
- `--stream` gives the events of a faulty text before its fault, as jq does, and `input_line_number` and the
  error positions under `--stream` count jq's lines.
- `--stream-errors` gives a faulty text's events as it reads them, not all before the first.
- A JSONC or JSON5 input of only comments and whitespace is no input, as a whitespace-only one is.
- Windows: `strftime`'s `%k` and `%l` pad the hour with a space, as jq does, not a zero.
- Regex `\R` no longer matches the trailing byte of a multibyte character that a global match steps into.
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
