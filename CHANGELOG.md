# Changelog

## Unreleased

### Command line

- `--from toml` and `yaml` read TOML 1.1 and YAML 1.2 with the core schema (each document of a stream an input), and
  `--to toml` and `yaml` write TOML 1.0 and YAML in block or flow style. `check`, `check --schema`, `fmt`, `diff`,
  `schema infer` and `--explain` take both, and `--follow` takes YAML.
- `--from cbor` reads each item of an RFC 8742 sequence as an input, in any serialization, and `--to cbor` writes CBOR
  in its preferred serialization. A byte string reads as its base64 and a byte string key as its bytes. `check`,
  `check --schema`, `fmt`, `edit`, `diff` and `schema infer` take it, an edit keeps the bytes of every item it does not
  reach, and `--follow` is refused.
- `--alias-limit N` and `--merge-keys` set how `--from yaml` reads: the bytes aliases may read again, and `<<` as
  YAML 1.1's merge key. With another `--from` each is a usage error.
- `.@tag`, `.@anchor`, `.@alias` and `.@style` read a value's tag, anchor, alias and spelling: a TOML datetime's type,
  a number's form and a string's quoting, and a YAML node's tag, anchor, alias and style. `.@tag`, `.@anchor` and
  `.@alias` take a string or `null`, travel with their value as comments do, and `edit` writes them in YAML.
  `.@style` is read only. A CBOR tag reads as its number, and `.@tag` takes a number too.
- `edit --from toml` keeps every byte the output does not change: a new member joins its table's lines, a built table
  is a `[section]`, a dropped line goes with the comments above it, and `null` is refused with the reason.
- `edit --from yaml` edits each document of a stream as a record: a document with no output is dropped, each output
  past the first is a new document after it, `-s` runs the filter on the array of the documents, and a new or moved
  document starts with a `---` line. A text of comments alone is written back as it is, and `--diff` takes no stream of
  several documents.
- `--schema-draft D` names the draft of a schema with no `$schema` (`4`, `6`, `7`, `2019-09` or `2020-12`, the
  default) for `check --schema`, `fmt --schema`, `diff --old-schema --new-schema`, `schema sample` and `schema gen`.
- `stury schema gen` adds a `pattern` that holds a comma or a quote with `model.register_field`, where it wrote it in
  the tag.
- `fmt --schema` judges each file as `check --schema` does and formats a file that passes as plain `fmt` does, so it
  keeps comments and spellings, writes one table for a run, writes an array of scalars as rows, and gives exit 5 with
  the reason for a value the output cannot write. A file that fails is not written, and `--in-place` and `--check`
  leave it as it is. A CSV or TSV output is judged again as it reads back, by `--infer` when the input is no table,
  which then quotes a string that reads as a number, `true` or `false`.
- `fmt` from a JSON array, NDJSON or a table to another format holds one row or record at a time.
- `check --filter` narrows `if` and `select` through `and`, `or` and `X | type == "kind"`, so `index`, `indices` and
  `rindex` on an array are typed, and a refusal inside a builtin the prelude defines names the call that was written.
  Under `--from csv` or `tsv` a schema that describes no table is a usage error, and so is `--report lines`.
- An option only some commands take names those commands and what it does, and every other command refuses it:
  `diff` refuses `--report`, `--count` and `--diff`. `schema sample` and `schema gen` take `--schema-ref`.
- `schema sample` writes valid `uri-template` values, and a schema for which it finds no value says that no value
  was found. `--report basic` writes a line for an empty NDJSON or `--seq` input. `schema gen` names the path of a
  member whose name is empty.
- A relative `$ref` resolves against the schema file's place, and `--schema-ref` bounds only which files are read.
  A schema that does not compile is told in one form, with the `--schema-ref` hint only for a reference.
- A failure message names the bound a value misses or the types it may have, and `not` has its own message. A quoted
  CSV cell's failure is placed at its opening quote. Library: `core.Typed_Error_Kind.No_Invalid_Sample`.
- `check --filter --from csv` takes the row from a table schema's `items` and refuses a member it does not describe.
- `schema sample` names the schema file in its errors, says when `--invalid` finds no failing value, takes `--infer`
  for a CSV or TSV sample, prefers a table with rows, and spells a decimal plainly. `schema infer` of an empty input,
  and of one whose schema nests too deep, is exit 5. `schema sample` and `schema gen` refuse `--max-depth`, and
  `schema sample` `--comments` for a format with no comments.
- `fmt` takes `-c` as `--indent 0`. A "has no use" refusal says what the command writes, and a filter given by
  `--filter` is not taken for a mistyped command. `--report basic` counts the records before a cut one as records.

- An empty unquoted CSV or TSV cell is a `null` in `check --schema`, `schema infer`, the library's table and document checks and
  the schema conversion's output check, as it is in a filter run, where it was an absent member. `schema infer` puts
  `null` in the type of a column with empty cells and requires the column. A quoted `""` stays a string.
  `check --schema` reads the other cells as `--infer` says, as `schema infer --infer` does.

- `stury schema sample` streams its values, so the memory it holds does not grow with `--count`. Library:
  `schema.sample_each` hands each value to a sink. `schema.Change.old` and `.new` are values, so `stury diff --json` on
  schemas writes them as JSON. `--report basic` and `--report problem` always name the file. `stury diff` refuses an
  empty file, a `--key` that names no array, and options it ignores.

- `stury fmt --schema FILE` converts through a JSON Schema: the input passes it, the members it leaves open are kept, and
  the output passes it as the output format reads it. Library: `schema.Converter` and `schema.convert`.

- `stury schema gen SCHEMA [--package NAME] [--format-assert]` writes the Odin types a model reads a schema's values
  with, and exits 1 naming the keyword where no type spells one. Library: `schema.write_odin`. `oneOf`, `uniqueItems`,
  `not`, `if`, `contains`, `propertyNames`, `patternProperties` and the dependents are spelled as model rules:
  `model.Union_Mode.One_Match`, the tag item `unique` and `model.register_schema`, which takes a JSON Schema fragment
  for a type.

- `stury schema sample --to csv` writes the union of the rows' members as its columns, an absent member as an empty cell,
  and refuses a nested cell.

- `stury schema infer [FILE...]` writes the JSON Schema that every record of the inputs passes, and `stury schema sample
  SCHEMA` writes values that pass a schema, or with `--invalid` values that fail it. Both take the layout options.

- `stury check --schema FILE` also checks each input against a JSON Schema and tells every failure, exit 1.
  `--report basic` and `--report problem` write the JSON Schema basic output or an RFC 9457 problem document,
  `--max-errors`, `--format-assert` and `--schema-ref` shape the check. Long files and records are checked on all cores.

- `stury check --filter F --schema S` types the jq filter F against the schema S of its inputs: a member no object of
  S lists (`.emial`) and a step on kinds that never take it are refused, exit 1, and the schema every output of F
  passes is written. `--from csv` and `tsv` type F on the records a table reads.

- `stury diff OLD NEW` tells the value changes of two inputs a line each, exit 1 when they differ. Arrays match as
  sequences, as sets (`--set`), by position (`--position`) or by a member (`--key`). `--old-schema S1 --new-schema S2`
  compares two schemas, telling each change and whether each schema takes what the other does, with a value that breaks it
  when not; `--compat` exits 1 unless that direction is proven. A schema with one data file judges the data by it and tells the members the data has that it does not describe.
  `--shape` compares the shapes two data files infer to, and a file of records is one array of them.
  `edit --diff` tells the value changes an edit makes.

- `stury edit FILTER [FILE...]` writes each input back with the filter's one output spliced into its bytes: every byte
  the filter does not change is kept, comments and line ends included, and an insert follows its container's layout. A built object or array is laid out
  as the container it lands in: one member a line in its indent and colon spacing, or compact.
  `--in-place` rewrites the files, `--check` names each file that would change.
- `stury edit` drops a CSV, TSV, NDJSON, `--seq` or `-R` record the filter makes no output for, with its line end and
  comments, and writes each output past a record's first as a new record after it. `input` and `inputs` read the next
  records, which are consumed.
- `stury edit` moves members and elements to the output's order, each keeping its bytes and comments, and keeps the
  container's separators, lines and trailing comma: `{a,b}`, `to_entries|sort_by(.key)|from_entries`, `sort` and
  `reverse` edit in place. `-S` sorts every object's keys by moving its members.
- `stury edit` on a table reorders, adds and drops columns in the header and every row the same way, keeping each kept
  cell's bytes. A cell that is an array or an object is refused as `--to csv` refuses it.
- `stury edit` edits the last member of a repeated key, the one the CLI reads, and keeps the others byte for byte.
- `stury edit` takes `-s`, `-R`, `-e`, `-a`, `-S`, `--indent`, `--tab`, `-c`, `--grow-header` and `--explain`.
- A filter writes comments: `.@comment`, `.@comment_inline` and `.@comment_foot` take `=`, `|=`, `del`, `setpath`
  and the other path updates on any format, and a value carries the comments written on it through pipes, variables,
  indexing and construction. Comments are not data: equality, sorting, `tojson` and `paths` ignore them.
- `stury edit` writes the comments a filter sets or deletes, also in a reordered container, several of one role, and
  those of a new or built value and the values nested in it. A value taken from another node brings its comments. It
  refuses a comment in a format that holds none.
- A removed head or foot comment that stood alone on its line takes its line with it.
- `stury check --help` and `stury fmt --help` give each command's own help, and a filter one or two letters from
  `check` or `fmt` is named as a near command. A usage error points to stury(1) and `docs/cli.md`.
- `check` judges every file and reports each file's first fault, and refuses the options that shape a filter run.
  `fmt` goes on to the next file after a fault. `fmt --check` names each file that is not formatted on stderr. Exit
  code 2 for a usage or file error wins over 5 for invalid input.
- `fmt` refuses a CSV or TSV header that names a column twice, and writes a JSON array as the rows of a CSV or TSV.
- `--to jsonc` prints no colour, so the comments are kept.
- CSV and TSV options: `--delimiter`, `--no-header`, `--comment`, `--infer`, `--ragged` and `--lazy-quotes` read, and
  `--out-delimiter`, `--out-comment`, `--out-no-header` and `--crlf` write, in filter runs, `check`, `fmt` and `edit`.
  A table written as the format read keeps the read's delimiter, and one written from a table its comment character.
- A table written from a table read with `--infer` quotes a string cell that would read back as a number, `true` or
  `false`, in a filter's `--to csv`, `fmt` and `edit`, and TSV refuses one.
- A filter's `--to csv` or `--to tsv` output writes each output's `.@comment` as comment lines above its row when the
  output has a comment character, and `fmt` from JSONC to a table places the text's comments as the library's writer
  places a document's.
- `edit` of a CSV or TSV table read with `--comment` writes `.@comment` on a new record as comment lines above it, as
  on a kept one, and tells a table read without `--comment` that it holds no comments.
- `edit -s` of a CSV or TSV table read with `--comment` writes the output array's `.@comment` above the header and its
  `.@comment_foot` after the last record.
- A filter run over a CSV or TSV table read with `--comment` reads the comment lines above a record as its `.@comment`
  (`null` for a record with none), and under `-s` the lines before the header and after the last record as the array's
  `.@comment` and `.@comment_foot`. `--to csv` or `tsv` writes them back, so a commented table round-trips through a
  filter. `.` and `select` into such a table are built whole, and a long input is answered on one thread.
- The library's dsv writer keeps a document's comments as comment lines when the output has a comment byte, the
  read's own by default, so `fmt` of a CSV or TSV file keeps them. With no comment byte they are dropped and counted.
- `--explain` says in words how the filter runs: the path or columns it reads alone, or that it builds each input and
  why, what decides the speed and memory, and after the run how many inputs were read each way, on how many threads.
- Messages name what failed: a directory given as a file, a `--rawfile` or `--slurpfile` that does not open, an
  `error(...)` the filter raises (`stury: error: MSG` when there is no input to name), output that cannot be written
  (exit 2), and a file named `*.csv`, `*.tsv`, `*.jsonc`, `*.json5` or `*.ndjson` read as JSON, which adds `(--from csv
  reads it)`.
- `error("")` on an input is told as the filter's error at that input, as jq tells it, where it was told as a parse
  error.
- `--debug-dump-disasm` and `--debug-trace` are unknown options, as `--run-tests` is. `builtins` lists its names sorted.
- The differences from jq are listed in [docs/cli.md](docs/cli.md#differences-from-jq).
- `stury fmt --indent 0` and `stury edit --indent 0` write lines with no indent, jq's `--indent 0` layout.
- `fmt --in-place` and `edit --in-place` write the new text into a temporary file only its owner can open, and give
  it the file's mode after: other users could read a private file's new text while it was written.
- SIGINT and SIGTERM end `--follow` on a FIFO or a pipe named `/dev/stdin` too, where the run went on waiting, and
  end it by the signal once the answers so far are written, as they end jq. A FIFO's answers are written as each record
  arrives, not when the run ends.
- A regex nested past jq's depth (512 groups) fails with `Regex failure: parse depth limit over`, as jq's does, where
  it held memory for every level. A `+` on a group nested in another `+` compiles once, so nested `(...)+` matches as
  deep as jq's does rather than failing with `fail to memory allocation`.
- A regex search skips by what Oniguruma's optimizer finds in the pattern: an exact string or a set of bytes at a
  distance from the match's start, chosen by Oniguruma's weights, and the start and end anchors. A hopeless search such
  as `(?i)(A|a)*b` on a long run of `a` answers false, as jq's does, where it hit the retry limit. `\R` counts a
  retry where Oniguruma's does.
- A regex holds a run of plain characters as one node over the pattern's text, and a sequence of one element as that
  element, so a long literal, alternation or run of groups compiles in about jq's memory. A pattern of more than 32767
  groups fails with `Regex failure: too many captures`, as jq's does.
- `test` and the other regex functions answer from automata built when the pattern compiles, with the same answers as
  before: `test` from a deterministic automaton of the whole search, and `match`, `capture`, `sub`, `gsub`, `scan` and
  `splits` from one that finds where Oniguruma's first match ends and one run back from there that finds where it
  starts, the groups then read at that start alone. Case folding, `x`, `s`, multiline, `\b`, `\B`, `^`, `$` and `\Z`
  are in the automata. A pattern with look-around, back-references, calls or absent groups, one whose automaton passes
  the build's work budget, the `l` and `n` flags and a search that Oniguruma's retry limit could end search as before,
  and a pattern with an empty loop or `\K` answers only `test` from the automaton.
- Numbers are equal, ordered and hashed by the exact decimal a literal spells, at any size, in the filter's `==`, `<`,
  `sort`, `unique` and `group_by` as in the library. jq reads a literal past decNumber's range as its double, so it
  calls `1e1000000000` and `1e1000000001` equal and `1e-2000000000` zero. A double that arithmetic made from a longer
  literal, and an infinity, are no longer equal to a literal they round to.
  A JSON5 decimal written with a sign or a point is compared by its digits, and a CSV or TSV cell is a string in these
  comparisons.

### Formats

- New package `toml`: TOML 1.0 and 1.1 (`toml.Spec`), read by a walk that builds the table tree and replays it in
  document order, judged by `toml.validate` and built by `toml.build`, with `find`, `scan`, `each_answer` and `query`.
  A table is one object whose members are in the order the text first names them, and a repeated key or a table
  defined twice is a fault. A datetime is a string whose `Tag` fact names its type, and the `Style` fact tells a
  string's quoting and a number's form (`toml.Number_Spelling`). A hex, octal or binary integer writes as JSON in
  decimal. The vendored toml-test cases run under both versions.
- `toml.marshal`, `toml.unmarshal` and `toml.plan_make` write and read a struct or map with the `toml` tag key. The
  writers lay out lines, `[header]` and `[[header]]` sections and comments where TOML reads them back, write a float
  so that it reads back as a float (`1.0`, `-0.0`, `inf`, `nan`) and a datetime bare, and refuse null and a repeated
  key as `.Unwritable`. `toml.write` and `core.write` with `toml.as` write a document of any format whose root is an
  object.
- `toml.set` and a TOML edit list edit a text and keep every byte the edits do not reach: a new member is a line after
  its table's last line, a built table or array of tables a section after the last section of the table it joins, and a
  removed member goes with the comments above it. An edit TOML cannot make, such as a table replaced by a value, is
  `.Frozen` with the reason.
- `toml.checks` and `toml.bind_schema` give a model the format and bind a JSON Schema, so a model loads and a schema
  judges TOML texts.
- New package `yaml`: YAML 1.2 with the core schema, read in one pass by `yaml.walk`, judged by `yaml.validate` and
  built by `yaml.build`. A plain scalar resolves by its text and its tag, and one its core tag does not hold is
  `.Tag_Mismatch`. A key is its text, a repeated key is a fault in every read (`.Refuse` is YAML's one duplicate
  policy, and a read asked for another is `.Bad_Option`), and a key that is a collection is refused. An alias reads as
  its anchor's node within `Options.alias_limit`, `Options.merge_keys` reads `<<`, and `%YAML 1.1` reads with the 1.2
  rules. `find`, `scan` and `each_answer` read a document without a build until they reach an alias. A stream's
  documents are records under `.Concatenated` (`yaml.records_open`, `records_check`, `records_each`). The vendored
  yaml-test-suite runs against the walk.
- `yaml.marshal`, `yaml.write` and the token write write block style when pretty and flow style on one line when
  compact. A string is plain unless a YAML 1.1 or 1.2 reader would read it as another type. A document read from YAML
  writes back its comments, tags, anchors, aliases, scalar styles and flow collections. `yaml.unmarshal` and
  `yaml.plan_make` read a document into a value.
- `yaml.set` and a YAML edit list edit a text at the indentation of each place and keep every byte the edits do not
  reach, comments included. An edit inside what an alias reads, of an anchored node an alias reads, a change of member
  order, and any edit of a text with a `<<` read under `merge_keys` are `.Frozen`.
- `yaml.checks` and `yaml.bind_schema` give a model the format and bind a JSON Schema, so a model loads and a schema
  judges YAML texts.
- New package `cbor`: CBOR (RFC 8949) through the calls of the other formats.
  A byte string is `Kind.Bytes`, a tag is a fact before its content (`fact_value(.., .Tag)` gives the nearest tag's
  number), an integer key reads as its decimal digits and is written back as an integer, and `1` and `"1"` are one key.
  `cbor.Spec` reads any well-formed item (`.Cbor`), or refuses an item not in preferred, deterministic or length-first
  serialization and writes in it. `cbor.set` and `edit_list_init` edit an item, copying the bytes of every item no edit
  reaches. `walk` takes a `Cursor` that `walk_resume` continues, `answers` reads a path's answers a batch at a time,
  `check` reads an item by a plan as a check, and `plan_of` builds the plan of a `rules.Description`.
  `cbor.marshal` and `unmarshal` take a struct as a map or as an array (`Options.structs`), a sequence's items are
  records, and `cbor.write` writes a document of any format as one item. A path read skips the values off the paths and
  judges them as `validate` does. `cbor.checks` and `cbor.bind_schema` give a model the format and bind a JSON Schema.
  The Appendix A vectors and a differential against `core:encoding/cbor` run against it.

The hooks the formats share:

- `core.Kind.Bytes` is a byte string, read with `doc_bytes`. A text format writes one as its RFC 4648 base64. Byte
  strings order and hash by their payload, after every number and before every string, and count as strings in a
  schema's kind check.

- `typed.Bytes` reads a byte string from a string of RFC 4648 base64, and a format writes one as that string, YAML
  under `!!binary` (`write.value_bytes`).
- `core.Role` gains `Tag`, `Anchor` and `Alias`, facts beside the comments. `core.fact_value` reads a named fact
  (`Fact_Name`: `Tag`, `Anchor`, `Alias`, `Style`), from a span or from what the node's spelling carries. `set_fact`
  takes the property roles in a format that spells them. `Fact.kind` lets a tag be a number, which `fact_number`
  reads.
- `core.doc_number_text` gives a number's decimal digits where its span is not its text, and `equal`, `compare`, `hash`
  and `uniqueItems` take such a number by its digits.
- `Readers` gains `fact`, `number_text`, `key_bytes` and `binary`, and `Edit_Services` gains `prefix`, `relocate` and `commit`, for a
  format whose edits do not fit one range per container. An edit a format's commit may not make is
  `Document_Error_Kind.Frozen`. `core.Site` says where an edit's text stands, and `write.tokens_init` takes one.
- `write.Tagged_Text` and `write.value_tagged` write a string with its format's type tag, as a TOML datetime, and
  `write.Token_Spelling.end` turns a token write's finished text into the format's own.
- `records.open`, `Stream_Options` and `json.records_open` take `entries`, a path of keys to the container whose
  members are the records under `.Entries`, and a stream under `.Entries` gives its records as it reads them.
- A record reader does not skip a byte order mark at the start of a binary format's text.

### Library API

- `yaml.marshal` writes a `typed.Bytes` as `!!binary` and its base64, as the token write and the document write do.
- `diff --facts` tells a changed TOML or YAML comment, and a changed YAML tag or anchor, through the facts a format's
  edit services write.
- `yaml.plan_of` builds the plan of a `rules.Description`, as `json.plan_of` and `dsv.plan_of` do.
- `yaml.walk` takes a `^Cursor` that `walk_resume` continues after any token, and `yaml.answers` gives a path's answers
  one at a time, as json's and dsv's do, and `yaml.destroy` frees a cursor a stop left.
- `toml.walk` takes a `^Cursor` that `walk_resume` continues after any token, `toml.answers` gives a path's answers
  one at a time, and `toml.destroy` frees a cursor a stop left.
- `toml.check` reads a text by a plan as a check, `toml.plan_of` builds the plan of a `rules.Description`, and
  `toml.unmarshal` takes a spec chosen at run time, as yaml's do. `toml.plan_make` takes `reads`, and a plan made
  without them reads no text, so `toml.set` with a struct and a plan needs a plan made with `reads = toml.reads(spec)`,
  as json and yaml do.
- A TOML text is one record under `.Concatenated`: `toml.records_open`, `records_open_stream`, `records_check`,
  `records_each`, `record_docs` and `tokens_init`, and a handle of `toml.as` holds the framing and the record builds.
- A path read of TOML ends the answer of a step that meets a scalar where it needs a container at the scalar's end.
- `json.bind_schema` takes the `Options` the texts are read with, as the other formats' do, `dsv.refuse` is
  `typed.refuse` as in json and yaml, `yaml.number`, `dsv.number` and `dsv.text` read a token without the table, as
  `json.number` and `json.text` do, and json and dsv forward `Value_Class`, `Tree` and `Plan` as the other formats do.
- A model's dump options leave out only a member a load does not require, so every dump of a valid value loads back. A
  CSV or TSV dump writes every member, a null as an empty cell.
- A CSV or TSV cell `""""` reads as the string `"`, through a model too.
- A tagged union's arm in `model.schema` holds its tag as a `const` member it requires, in the Load and the Dump
  schema. A union of one arm is that arm, and a fixed array is `items` with `minItems` and `maxItems`.
- `model.schema` of a `time.Time` member holds the years the type holds in its `pattern`.
- `schema.write_odin` writes a `number` whose bounds a double does not hold as `core.Number_Text`, which a model reads
  at any size, a distinct type of it included. A model's `core.Number_Text` member takes null unless tagged
  `not_null`.
- `schema.compile_description` returns a `^Compiled` and an error, as `schema.compile` does, which `schema.destroy`
  frees.

- `json.load_schema(text, opts)` takes `json.Schema_Options`: the default draft (`json.Schema_Draft`), the directory
  references are read from (`refs`), `format_assert`, `base` and `dups`. `json.Schema` is `schema.Compiled`, so a
  loaded schema's description is `s.description`.
- `schema.compile` reads a schema from its text in a format and returns the compiled schema it owns, which
  `schema.destroy` frees. `schema.open`, `schema.Loaded`, `schema.loaded_destroy`, `schema.read`, `schema.Resolver` and
  `schema.resolver_destroy` are gone: `Options.refs` and `Options.draft` replace `Options.resolver`.
- A `pattern=` tag item takes the rest of the tag, commas included, so it comes last. A model whose `pattern=` is
  followed by another tag item is refused at compile, naming the item, and a pattern that holds such text is added with
  `model.register_field`.
- `model.Problem`, `model.problem`, `model.problem_destroy` and `model.write_problem` hold the problem document, which
  was `write.Problem`.
- `regex.Regex` keeps its program private: `regex.group_names` gives the groups' names, and `regex.Flags.longest` and
  `.not_empty` are set at compile. `typed.store_integral_enum`, `typed.Use`, `typed.Model_Plan`, `typed.Reading`,
  `typed.Failure` and `typed.Before_Read` are private.
- `schema.infer`, `schema.merge`, `schema.inferred` and `schema.infer_records` build a description from values and
  records, which `schema.write` writes as JSON Schema. `schema.sample` writes values that pass a description, or fail it,
  and is `.No_Sample` for a description that no value passes. A node has a `description` and a markup node
  (`xml.nodeType`), and `write.comment` writes a comment in a format that has them.
- `schema.compare` tells whether one description takes every value another does, with a proof, a witness or the keyword
  the proof stopped at, and the changes between them. `core/diff` lists the changes between two values of any format.
  `core.write_steps` writes a path.
- `core.equal`, `core.compare` and `core.hash` take a number literal at its exact decimal at any size, an exponent of
  any width included, where they read one past decNumber's range as its double. `spell.Decimal` holds an exponent of more
  than 30 digits in `wide` and `wide_neg`, with the shift of its digits in `point`, in place of `saturated`, and
  `spell.write_point` writes the point either way. `core.compare` takes `read_plain`, false for a plain node that is to
  stay a string. `spell.decimal_compare` has one result.
- A schema `pattern` over a text too long for the regex's visited set gets an answer from the pattern's automaton, where
  the check failed the text before. A schema compiles each distinct pattern once, and its read checks a pattern's syntax
  without building the automaton. `regex.refusal` is that check.
- An ECMA pattern that begins with look-aheads after `^` (`^(?=...)(?!...)...`) answers a schema's `pattern` from one
  automaton, the product of the pattern's own and one per look-ahead.
- `regex.compile` builds the automata for every pattern, not only under `ecma`, unless `automaton` is false.
  `regex.Scratch.ends` holds where the automaton found the last search's match to end.
- `core.kind` of a CSV or TSV cell is the kind the cell reads as, in place of `.Plain`: an empty unquoted cell is
  `.Null`, as a typed read and the CLI read it, and with `infer` a boolean or number cell is `.True`, `.False` or
  `.Number`. A JSON write of a dsv document writes an empty cell as `null` without `infer` too. `core.resolve` is gone.
- `records.write_cells` takes `write.Scalar` cells and `records.cells` gives them: a string, a number by its text
  (`write.Number_Literal`, also a token write's), `.True`, `.False` or nil. Under `infer` the reader gives an unquoted
  number or boolean cell as that kind, and the dsv writers, a document's write included, quote a string that would read
  back as another kind, so a row read and written with one handle reads the same.
- `core.reorder` puts a container's members in a new order, each keeping its bytes and comments, as one edit that
  commits with the others.
- A CSV or TSV edit's text may start with a byte order mark, a cell byte past the text's start.
- A CSV member name that starts with a byte order mark is written quoted, so it reads back as the name.
- `core.write` writes a document with comments, shared keys or `sort_keys` at every depth its `max_depth` reads, as
  `stury fmt` does a JSONC text, and `json.TREE_DEPTH` is gone.
- A format call takes its spec, then the format's `Options`, then the job's options: `json.unmarshal(src, .Json,
  &v)`. `unmarshal` takes the spec at run time, and `json.marshal` and `dsv.marshal` take a plan.
- One `dups` field picks what a repeated key means, in `Read_Options`, `Path_Options`, `Query_Options` and `build`:
  `core.Duplicates.Last`, `.First`, `.All` or `.Refuse`. It replaces `refuse_duplicates` and `every_key`.
- `json.find` returns a plain `core.Answer`. Every read of a path or a member reports one `core.Presence`: `.Found`,
  `.Missing`, `.Wrong_Kind` or `.Not_Loaded`. `core.Kind.Map` is `.Object`.
- `core.format` and `core.commit` replace `json.format` and `json.commit` and take the format as an `As`, so one call
  serves every format. `core.text_room` gives the buffer length that always holds a node's decode, and
  `core.float_value` reads a float as `int_value` reads an integer.
- `typed.plan_make` builds a plan from a format's `As`, and `typed.unmarshal` and `records.read` build one when given
  none. `records.read` returns its error first and whether it read a record last, so it works as a `for` condition.
  `records.validate` is `records.validate_parallel`.
- `json.set` with an index equal to the length appends. `Path_Options.stop_early` under `.Last` stops at the close of
  the object that holds the answer, and `.First` stops at the first matching key.
- The typed error kinds `No_Memory` and `Invalid_Utf8` are named as the other error kinds are.
- `core.clone` of a record's document from `records.scan` owns its answers, which the next record no longer replaces.
- A CSV or TSV reader given a plan made in the place of a destroyed one binds its columns again, so it reads by the
  new plan. `typed.Plan.stamp` says what a plan was built from.
- `dsv.marshal` and a record write refuse a list row whose length differs from the first row's as `.Wrong_Length`,
  unless the options hold `.Ragged`, so what they write reads back with the same options.
- `core.commit` of a JSONC document as JSON5 respells a U+2028 or U+2029 in an untouched `//` comment as `\u2028` or
  `\u2029`, as the tree writer does, instead of refusing the result with `.Bad_Result`.
- Each `json` and `dsv` entry point is a group of a form that takes its spec as a constant (`json.validate(src, .Json)`)
  and a form that takes it at run time (a variable, or an `As`). A program that names its specs links only the walks it
  reaches. A document built through a constant form holds
  no run-time services, so its `query`, `write` and `edit_list_init` are the format package's, with the spec named.
- `json` and `dsv` export the names of `core`, `core/typed`, `core/write`, `core/records` and `host` that a program
  calls, so a program imports one package (`json.Document`, `json.Error`, `json.render`, `json.parse_path`,
  `json.records_check`, `json.Pool`). `destroy` is one group over a document, a path, an edit list, a plan, a sink, a
  record writer and a pool. tools/names.txt lists the exports and `make api-write` writes `json/names.odin` and
  `dsv/names.odin`.
- `json.query`, `dsv.query`, `json.commit` and `dsv.commit` replace `core.query` and `core.commit`. `commit` returns
  `Error`. The `query` and `commit` slots of the format tables are gone.
- `core.Value` is the one value of the library, a union a built value and a node of a document both fit: null, a
  `bool`, an `f64`, a `^Number_Text` that keeps a number's digits, a `string`, an `^Array`, an `^Object` and a
  `Node_Ref`, the `{doc, node}` struct that was `core.Value`. `kind`, `length`, `member`, `children`, `pairs`, `text`
  and `number` read a value as they read a node, `equal`, `compare` and `hash` order values as jq does, and
  `write_value`, `marshal_value` and `unmarshal_value` write one, make one from an Odin value and read one into an
  Odin value.
- `set`, `set_member` and `insert` take an Odin value, which the document's format spells in the layout of the place it
  goes: a string, a number, a bool, a `Value`, or a struct, a slice or a map with its plan. `typed.Raw(text)` is the
  text of a value as it is. A string that is not UTF-8 is refused. `set` on an edit list is `set_node` in `json` and
  `dsv`, where `set` takes a path.
- `json.answers` and `dsv.answers` give a path's answers one at a time through `next`, with no document.
  `json.walk` and `dsv.walk` take a `^Cursor`, which holds where a hook's `.Stop` left the walk, and `walk_resume`
  goes on from there.
- A dsv build with `Options.infer` writes each cell's kind into its node, and a table's row is reached by its
  position: `child_at` on a table with a width is one step whatever the index.

- `model.dump` and `model.dump_stream` write a value by its model: never a `write_only` member, and with `Dump_Opts`
  leaving out the members whose `Fields_Set` bit is clear (`exclude_unset`, pydantic's meaning: what a load defaulted
  or never read, a `read_only` member kept), that hold null (`exclude_none`) or that equal their default
  (`exclude_defaults`). The field tag `omitunset` leaves out one member that holds null and is unset, and a struct
  with no `Fields_Set` refuses it. A CSV dump writes a member it leaves out as an
  empty cell. `check` validates what the dump writes first and refuses a value that fails as `.Check_Failed`.
- `model.patch(&m, &existing, body)` applies a patch text: the members' rules judge the patch, the members it leaves
  out keep what `existing` holds, struct validators and applicators judge the merged value, and `existing` is written
  only when nothing failed. `existing` holds memory from the patch's allocator: a patch frees the members it replaces,
  and a failed one frees what it read.
- A load judges the value its `dups` keeps, the last or the first, and a repeated key it refuses has the repeat's path
  in the sink. `Load_Opts{dups = .All}` is `.Bad_Option` with its reason. A refused load leaves a missing required
  member's `Fields_Set` bit clear.
- A model copies the defaults, names and tags it takes from the registry, which may be destroyed before its models.
- A CSV or TSV model reads an empty unquoted cell as null, as `check --schema` does: a `Maybe` member holds nil, a
  `not_null` one and a plain `string` refuse it, and a dump's empty cell reads back as nil. A `not_null` `Maybe`
  member compiles for a table.
- `model.schema` describes two `Maybe` members of one type that differ on null as two nodes.
- `schema.write_odin` and `stury schema gen` register a member's string, number or boolean `default`, and refuse a
  default no literal of the member's type holds and an integer whose two bounds no `i64` or `u64` holds.
- The format tag names and shapes a member (a rename, `-`, `omitempty`, `omitunset`, `required`, `unknown`) and
  `model:` holds its rules and roles. `required` with `optional` is refused, and a refusal of `required` with
  `omitempty` or `omitunset` names the tag.
- `load`, `validate` and a schema's check list failures in one order: by the value's path, a value before what it
  holds. An applicator runs when a member failed.
- `model.compile` and `schema.bind` take `json.checks(spec, opts)` or `dsv.checks(spec, opts)`, the checks of a format
  and the layout they read by. `json.reads` and `dsv.reads` serve a plan made from a type and link no model check.
- `register_after` takes several validators for one member, run in the order they were registered.
- `schema.write_odin` writes the Odin source of the types of a description's values, with a `register` procedure for
  the rules no tag holds, and refuses a keyword no type spells as `.Unsupported`, naming it.
- A model's `not_null` tag item keeps null out of a pointer or `Maybe` member, which otherwise reads null as nil. A struct's
  `extra` member may be a `map[string]T`, which judges each member it captures as a `T`, and the Load schema describes
  it as `additionalProperties`. A struct registered with `.Forbid` refuses an unknown member when it has no required
  member too. A `union {}` member reads only null.
- `model.problem` makes an RFC 9457 problem document of a sink's entries, for any format to write.
  `load`, `load_value` and `read` take `Load_Opts` in place of `dups`.

### Errors

- A model and its schema refuse a value with the same kind, under the schema's names. A number past a bound is
  `.Above_Maximum` or `.Below_Minimum`, in a plain `unmarshal` too, where it was `.Out_Of_Range`, which stays for a map
  key that spells no integer and a `cstring` holding NUL. A fixed array or a capacity given too few or too many values
  is `.Too_Few` or `.Too_Many`, where it was `.Wrong_Length`. A member `read_only` or unknown under `Extra.Forbid` is
  `.Not_Allowed`, and `.Read_Only` is gone. A model's union that no arm takes is `.No_Arm`, where it was `.Missing_Tag`,
  `.Not_A_Member` or `.Wrong_Kind`, and a model's map key that fails its rule is `.No_Match` at the map. A tag member a
  struct of the union also holds is `.Bad_Tag`, where it was `.Unsupported`.
- `model.register_default`, `register_factory`, `register_before` and `register_after` naming a member the type does
  not have are refused by `model.compile` as `.Bad_Tag`, naming the type and the member. `register_factory` refuses a
  factory of another type at once as `.Invalid_Argument`.

- `.Check_Failed` is a value a model's dump checked and found against its rules, with the first failure's code.
- `.Bad_Option` carries its reason in `want.text`, which render writes. A model's plan given to `unmarshal` or
  `check` of its own format and type is `.Bad_Option` saying it reads only through `model.load`.
- `core.render(w, src, e)` writes any error type, and a path or edit error carries the reason it was refused
  (`core.Path_Reason`, `core.Edit_Reason`), which render names.
- A typed refusal names the type wanted and the value found (`Expected i64, found "lots" at .[0].population`), the tag
  flag a field does not take, and the formats of a plan that does not match its read.
- Every public call that returned a `Fault`, `Document_Error`, `Path_Error`, `Path_Edit_Error` or `Typed_Error` returns
  `core.Error`, a union of those types, `runtime.Allocator_Error` and `Typed_Error_Kind`, so `or_return` passes any of
  them up and `err != nil` is the test. `core.error_of` makes the union from a concrete error. A refused allocation is
  `runtime.Allocator_Error.Out_Of_Memory`, a walk's fault is the `Fault` arm, and a repeated key met by a build, read
  or scan is `Fault{kind = .Duplicate_Key}`. A `Typed_Error`'s path is `steps: []Step`, copied to
  `context.temp_allocator`, and the type with the path in line, which a sink's `errors` hold, is `Typed_Refusal`.
  `core.render` and `core.write_code` take an `Error`, and `Path_Edit_Error`,
  `render_edit` and `write_edit_code` are gone. A repeated key under `.Refuse` in a path edit has the code
  `duplicate_key`.

### Bench

- Every runner takes the same arguments and prints the machine it ran on. The stury arm is named `stury`. The typed
  lanes have serde_json and sonic-rs arms, and every write arm writes into one buffer. `gen.py --check` writes
  nothing, and the CLI comparisons take `CASES`. `bench/write dump` writes the typed lanes through `model.dump`. [bench/README.md](bench/README.md) describes the harness.
- `bench-cli` times the regex functions.

### Development

- `API.txt` lists the user surface. The public names that only this repository's packages use are in `API_SHARED.txt`,
  and `make lint` checks both. `tools/checks.py` states the rule that splits them.
- `make help` lists the targets. `make api-write`, `lint-man` and `lint-fixtures` are new, `make check` names the rule
  a failure broke, and the Makefile refuses an Odin release older than `MIN_ODIN`, `dev-2026-11`.
- `make test-cli` runs `cmd/stury/test/smoke.py`, and `smoke.floor` is empty: every smoke case passes. It also runs
  toml-test and the yaml-test-suite through the command line (`toml_suite.py`, `yaml_suite.py`). CI runs the
  examples. The tree is pinned to Odin `dev-2026-11a` on LLVM 22.

## 0.1.1 (2026-11-05)

The `v0.1.0` tag built no artifacts: the release workflow ran the smoke script directly, and it fails the cases
`cmd/stury/test/smoke.floor` records as known failures. The release now uses the same floor, and this archive
carries the figures in `docs/benchmarks.md`. The rebuilt library described below is the one `v0.1.0` tagged.

The library and the command line are rebuilt on one interface for every format. It builds with Odin `dev-2026-11` or
later and targets 64-bit little-endian systems (darwin and linux, on amd64 and arm64; the command line also builds on
Windows).

### The rebuilt library

- `stury:csv` is `stury:dsv`, which reads `Csv`, `Tsv` and `Plain` text. Every format call takes its `Spec`:
  `json.Spec` is `.Json`, `.Jsonc` or `.Json5`, and `dsv.Spec` is `.Csv`, `.Tsv` or `.Plain`. Each package has one
  `Options` struct for the walk settings, including `tolerate`, which names the rules a text may break.
- What a caller uses across formats lives in `core`: documents, readers, paths, edits, `Write_Options` and errors.
  `json` and `dsv` give each format's `validate`, `build`, `find`, `scan`, `set`, `unmarshal` and `marshal`.
- Errors are values with a `kind`: `core.Fault`, `core.Document_Error`, `core.Path_Error`, `core.Path_Edit_Error` and
  `core.Typed_Error`. One `core.render` writes any of them as `line:col: message`.
- `find` and `scan` return a `core.Document` and `core.Answer` records, and `core.query` collects the values a path
  reaches from a built document. A path is parsed with `core.parse_path` or `core.parse_pointer`, owns its steps and
  is freed with `core.path_destroy`.
- `core/records` reads and writes a text of records one at a time (`.Lines`, `.Seq`, `.Concatenated`, `.Entries`),
  from memory or from a stream through a window, and `host.Pool` lends threads to `records.each`.
- Edits are an `Edit_List` made with `core.edit_list_init` and recorded with `core.set`, `core.set_member`,
  `core.insert` and `core.remove`, each checked as it is recorded and applied with one commit. Removing a cell from
  every row of a delimited text drops its column.
- A typed read takes an explicit plan from `json.plan_make` or `dsv.plan_make`, owned by the caller, with no global
  cache. The `unknown` tag flag captures unnamed members into a `map[string]typed.Raw`.
- Comments are facts on a node, read with `core.facts_of` and edited with `core.set_fact` and `core.remove_fact`.
- `core.Write_Options` sets `pretty`, `indent`, `tab`, `ascii`, `escape_html`, `escape_del`, `sort_keys` and
  `respell_strings` for every writer.
- A build that runs out of memory counts the text and builds again at the exact size.

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
