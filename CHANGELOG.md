# Changelog

## Unreleased

### Library

- New format packages `toml` (TOML 1.0 and 1.1), `yaml` (YAML 1.2, core schema), `xml` (XML 1.0 with namespaces and the
  internal subset), `html` (the WHATWG tokenizer, tree builder and serializer) and `cbor` (RFC 8949, with
  preferred, deterministic and length-first specs). Each has the same `validate`, `build`, `find`, `scan`, `query`,
  `unmarshal`, `marshal` and edit calls as `json` and `dsv`, and edits keep every byte they do not target.
- Facts carry across formats: comments, YAML tags, anchors and styles, TOML datetimes and number forms, XML and HTML
  attributes and namespaces, CBOR tags and byte strings. A conversion writes a fact where the output holds it, and a
  comment keeps one place in every format.
- `core/model` loads and dumps Odin structs under a registry of rules (tags, defaults, validators, hooks, unions,
  `patch`), judged with the same error kinds as a JSON Schema. `core/schema` compiles and binds JSON Schema drafts 4, 6,
  7, 2019-09 and 2020-12, and infers, samples, compares and converts through a schema and writes a description as
  Odin types (`schema.write_odin`).
- `core/diff` tells the changes between two values, with keys, sets and facts. `core/css` matches CSS selectors
  over XML and HTML. `core/regex` is an Oniguruma and ECMA regex engine with Unicode 17 tables.
- Every call that fails returns `core.Error`, one union that `core.render` writes. A refusal names the type wanted and the
  value found, and a writer's refusal names its reason in the format's words.
- A format package takes its spec in `format`, as `json.format(src, .Json5)`, and forwards `comment`, `end_record`,
  `reorder` and `set_facts`. The edit list's setter is `write.set_node` in every format.
- `core/records` reads and writes records of every format, including CSV and TSV through `records.Writer` with
  `Write_Options.grow_header`, and reads the records under a path of keys with `.Entries`.
- A repeated key follows one `dups` field of the read's options in every format.
- A hex, octal or binary integer, or one with underscores, compares equal to its decimal.
- JSON's walk passes its state in registers between states, a compact write drops blanks with `vpcompressb` on an
  Intel CPU with AVX512-VBMI2, and a map of 1024 keys or more is written sorted by a radix sort.

### Command line

- Reads and writes TOML, YAML, XML, HTML, CBOR and JSON5 as well as JSON, JSONC, NDJSON, CSV and TSV. `--from` and `--to`
  take a spec after a colon (`toml:1.0`, `html:fragment`, `cbor:deterministic`). Without `--from`, the extension of the
  named files picks the format.
- `fmt` converts between formats and keeps comments, number spellings, tags, directives and layout where the output has
  them. It refuses with exit 5 a value its output cannot hold and says why.
- `edit` applies a jq filter to a text and keeps every byte the filter does not change, in every format. `--diff` tells
  the changes, per document for a YAML stream.
- `.@comment`, `.@comment_inline`, `.@comment_foot`, `.@style`, `.@tag`, `.@directives` and `.&NAME` read and write
  facts and attributes, and `.@(name)` and `.&[name]` take a computed name. A step that names an unknown fact is an
  error.
- `css(selector)` selects the elements of an XML or HTML input.
- `--attributes` reads each attribute of an XML or HTML element as its member `@NAME`, and writes such a member back
  as an attribute.
- `check --schema FILE` judges each input against a JSON Schema and tells every failure. `check --filter F --schema S`
  types a filter against the schema of its inputs. `--schema-draft` names the draft of a schema with no `$schema`.
- `diff` tells what differs between two inputs, two schemas (`--compat`) or a schema and data.
- `schema infer`, `schema sample` and `schema gen` write a JSON Schema from inputs, values that pass a schema, and the
  Odin types a model reads its values with.
- `--stream` reads every format, and `--seq` reads JSONC and JSON5 records. `--to json5` is accepted, and `fmt`
  reads and writes JSON5 with `--check` and `--in-place`.
- A YAML integer past 64 bits, a TOML number with underscores and a JSON5 number with a sign or a lone point read and
  convert by their value and keep their spelling where the output has it.

## 0.1.1 (2026-11-05)

The `v0.1.0` tag built no artifacts, because its release workflow ran the smoke script directly and the script fails the
cases `cmd/stury/test/smoke.floor` recorded as known. This release uses the same floor. It is the library of `v0.1.0`.

The library and the command line are rebuilt on one interface for every format. It builds with Odin `dev-2026-11` or
later and targets 64-bit little-endian systems, darwin and linux on amd64 and arm64, and the command line builds on
Windows too.

- `stury:csv` becomes `stury:dsv`, which reads `Csv`, `Tsv` and `Plain` text. Every format call takes its `Spec`, and each
  package has one `Options` struct for the walk, including `tolerate`.
- What a caller uses across formats lives in `core`: documents, readers, paths, edits, `Write_Options` and errors. `json`
  and `dsv` give each format's `validate`, `build`, `find`, `scan`, `set`, `unmarshal` and `marshal`.
- Errors are values with a `kind`, and `core.render` writes any of them as `line:col: message`.
- `core/records` reads and writes records one at a time from memory or a stream, and `host.Pool` lends threads to
  `records.each`. A typed read takes an explicit plan, with no global cache.
- Comments are facts on a node, read and edited through `core`.
- `--explain` writes the filter's plan and what the run did to stderr. `--follow` answers the records of a file as it
  grows. `--from json5` reads JSON5 in filters, `fmt` and `check`. `check` validates a large root array on the pool.
- A number keeps any exponent, and `--max-depth` takes up to 1048576. `--stream` gives the events of a faulty text
  before its fault, as jq does. On macOS a pipe named as a path is read wherever a file is.

## 0.0.3 (2026-10-26)

- Each format exports `CAPABILITIES`, which names the write options its writer honours. One `Read_Opts` per format,
  and one read error type for `scan`, `find` and `build`.
- CSV decodes a stream one record at a time, lists every refused record, and answers paths as JSON does.
- A tag flag that is unknown or unspellable, an unsorted edit list and a non-finite number in `marshal` are refused
  instead of misread.
- `stury fmt` formats or transcodes files, keeping every number, string, key and comment as written, with `--check`
  and `--in-place`. `--csv`, `--tsv`, `--ndjson` and `--jsonc` are replaced by `--from` and `--to`.
- Windows reads filter arguments as UTF-8 and takes an absolute `-L` path.

## 0.0.2 (2026-10-24)

Adds the CSV and TSV codec (now `dsv`), the shared `core` package and the command line's `--from` and `--to`.

- CSV: `validate` and `records` check RFC 4180 text, `unmarshal` and `marshal` read and write lists of structs,
  `build` and `find` answer paths, and edits keep every other byte. Dialects set the delimiter, quoting, escapes and
  comment byte, and `Strictness` and `Limits` bound a read.
- `core` holds what the formats share: strictness, paths, duplicate-key policy, hooks, errors and the spelling of
  numbers.
- The command line reads and writes CSV and TSV (`--to csv`, `--grow-header`), prints CSV straight from the cells of a
  filter that only selects columns, and `stury check` takes `--from`.
- `@tsv`, `@csv` and `@sh` write a NUL as `\0`, and `@csv` and `@tsv` write NaN as an empty cell, as jq does.

## 0.0.1 (2026-10-22)

The first release. It builds with Odin `dev-2026-10` and targets 64-bit little-endian systems, darwin and linux on amd64
and arm64.

- `stury:json`: validation against RFC 8259 without allocating, path queries that read no more than they need, parsed
  documents, typed `unmarshal` and `marshal` of Odin structs, byte-preserving edits (`set`, `insert`, `remove`,
  `splice`), NDJSON and RFC 7464 records, and JSONC with its comments.
- `stury:host` lends threads to parallel validation and per-record work. The library starts no thread of its own.
- The command line runs jq 1.8.2's language with its answers and exit codes, modules, every option but `--run-tests`,
  `--seq`, `--stream`, colours and Oniguruma-syntax regular expressions on its own engine. `docs/cli.md` lists where
  stury answers differently.
- `--ndjson`, `--jsonc`, `--max-depth N` and `stury check` are new. `--jsonc` output keeps the comments of values
  taken unchanged from the input and `.@comment`, `.@comment_inline` and `.@comment_foot` read them.
- Large inputs are read and printed on several threads, and filters that recurse in tail position use constant memory.
