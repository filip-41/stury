# stury

stury is a structural data processing library currently supporting JSON and CSV for [Odin](https://odin-lang.org),
plus a command line that runs jq filters on top of the data.

It is built for programs that read a lot of data and want to do little work per byte. You can check a text for
errors without allocating, pull one value out by path without parsing the rest, load a whole text into a
queryable document, read it straight into your own structs, or edit it while keeping every byte you did not
touch.

Input is checked strictly against its `dialect`. The default, JSON, follows RFC 8259: no `01`, no `NaN`, no
invalid UTF-8, no lone surrogate. stury also reads JSONC, NDJSON and RFC 7464 text sequences. In the
[benchmarks](#benchmark) below it runs 10 to 40 times faster than Odin's `core:encoding/json`, and ahead of
simdjson, yyjson and sonic-rs on validation and typed decode (measured on one machine with the harness in
[bench/](bench/README.md); tuning may differ between architectures at this stage of the project).

**Status:** version 0.0.1. The API may still change between releases (see [CHANGELOG.md](CHANGELOG.md)).

## Install

**Library.** Clone the repository into your project:

```sh
git clone https://github.com/filip-41/stury vendor/stury
odin build . -collection:stury=vendor/stury -o:speed
```

`-collection:stury=PATH` makes `import "stury:json"`, `import "stury:csv"` and `import "stury:host"` resolve
to the directories under PATH. Keep `json/`, `csv/`, `core/` and `host/` together in the copy. For the
[ols](https://github.com/DanielGavin/ols) language server, add the same collection to your `ols.json`:

```json
{"collections": [{"name": "stury", "path": "vendor/stury"}]}
```

**Command line.** Download the `stury` binary for linux or darwin on amd64 or arm64 from the [GitHub
Releases](https://github.com/filip-41/stury/releases) page (for example `stury-0.0.1-darwin-arm64.tar.gz`;
each archive has a `.sha256` beside it), unpack it, and put it on your `PATH`. Or build it yourself with
`make build-cli`, which writes `build/stury`. The manual page is `man ./docs/stury.1`.

## Requirements

- [Odin](https://odin-lang.org/docs/install/) `dev-2026-10`. stury follows Odin's monthly releases closely.
- 64-bit little-endian targets: darwin and linux, on amd64 and arm64. The command line also builds on Windows.
- On amd64 the floor is x86-64-v2 (SSSE3, SSE4.1, POPCNT). On processors with AVX-512BW, long strings are
  scanned 64 bytes at a time, chosen at run time.
- To build the command line: `make` and `git`. To run `make test`: also `python3` (the jq conformance suite
  runs on it). If `jq` 1.8.2 is on your `PATH`, `make diff` also compares answers against it.
- Optimization level: any works (the test suites build at `-o:minimal`), but the speeds on this page were
  measured at `-o:speed`, so build your program with it. The `make` targets that build the command line use it
  too.

## Features

- **Validate without allocating.** One pass, no allocation, and the first fault's line and column (`validate`,
  `error_position`, `render_error`).
- **Answer paths without parsing the rest.** Ask for one path such as `.tags[1]` (`find`) or several
  (`Request`, `scan`, `answers`) in a single pass over the input. Each answer is a range of bytes in your
  input. A request can be prepared once and run over many records.
- **Build a document once.** A `Document` holds the structure of a text, and you read it through `Node`
  handles, small values that each point at one value in the document (`build`, `child`, `query`, `pointer`).
  Strings point into the input unless they contain escapes. Numbers are decoded when you read them.
- **Map to Odin types from the type alone.** `unmarshal` fills structs, slices, maps, unions, bit sets and
  `any` with no per-type code and `marshal` writes any Odin value back as JSON. Struct field tags, hook
  procedures for your own types, and prepared type plans cover the rest.
- **Edit without reformatting.** `set`, `insert`, `remove` and `splice` change the bytes of the target and
  keep every other byte, indentation and comments included.
- **JSONC with its comments.** `dialect = .Jsonc` reads comments and trailing commas, keeps each comment
  attached to its value, and writes them back.
- **Records without allocation.** `records` and `next_record` iterate NDJSON, RFC 7464 sequences and a root's
  entries, and `records_from` frames a stream from an `io.Reader`.
- **Parallel when you ask.** `validate_records` and `each_record` run on threads from `stury:host`. The
  library itself starts no thread and keeps no global state.
- **Strict CSV.** `stury:csv` checks RFC 4180 text with `validate` and `records`: quote placement, a CR outside quotes
  only before LF, UTF-8, and the same field count in every record. `records_from` reads records from an
  `io.Reader` in bounded memory. `each_record` and `validate` with a runner use threads from `stury:host`.
- **CSV dialects.** A `Dialect` sets TSV (`csv.TSV`, with the escapes jq's `@tsv` writes), another delimiter,
  `Quoting.None` (a quote is text), backslash escapes (`\t`, `\n`, `\r`, `\0`, `\\`), comment lines, ragged
  records, and whether there is a header.
- **CSV into structs.** `unmarshal` and `marshal` map rows to a list of structs with the same field tags,
  hooks and `Duplicates` policy as JSON. Each cell is checked against its field's type. `unmarshal_check`
  runs the same checks without storing anything.
- **CSV documents and edits.** `build` records where every cell is. `find` and `find_column` read a cell or a
  column by path (`.[3].name`) without building a document. `set`, `insert`, `remove` and `splice` keep every
  byte they do not target. `write_record` appends one record of text cells to a buffer.
- **Duplicate keys are a policy**: keep the last, the first, all of them, or refuse the text.
- **A jq 1.8 command line.** `stury` runs jq filters with jq's answers and exit codes as the baseline,
  with its own `stury:` messages, and differs where jq loses data or misreports an error ([listed in
  docs/cli.md](docs/cli.md#differences-from-jq)). It adds `check`, `--from` and `--to`.

## Things to know

- Keep your input buffer alive while you use answers or a document: both point into it. `unmarshal` copies
  strings into its allocator, so you can free the input after it returns, unless you set `borrow_strings` to
  make escape-free strings and `Raw` values slice the input instead.
- `unmarshal` never frees what it allocates, even when it refuses the input. Give it an arena and free the
  arena.
- `destroy` frees a value that owns several allocations: a `Document`, a `Request`, a `Type_Plan`, a
  `Record_Reader`. A slice a procedure returns, such as `set`'s output, is one allocation: `delete` it as
  you would any Odin slice.
- A procedure whose result is its only output carries `@(require_results)`: a call that drops the result
  does not compile, so an error cannot go unnoticed by accident.
- A document can address 4 GiB - 2 bytes of input (`MAX_ROW_SOURCE`), `validate` has no limit.
- Nesting deeper than 1024 levels is refused by default. You can raise the limit to 2^20.
- CSV cells are text. `csv.unmarshal` reads a cell as its field's type (`007` into a `string` stays `007`, into
  an `int` is `7`), and a cell the type cannot hold is refused. The command line has no field types, so every
  cell there is a string until you `tonumber` it.
- An empty cell with no quotes is absent: its field keeps its zero value (`nil` for a `Maybe`), or is
  `.Missing_Field` when tagged `csv:",required"`. A quoted `""` is a present empty string. Under
  `Quoting.None`, which TSV uses, every empty cell is absent. On the command line the two are `null` and `""`.
- The first record names the columns unless `no_header` is set. A file without a header read as if it had one
  loses its first record, and names that match no field are ignored, so the result can be zero values or no
  rows and no error. `unknown_fields = .Refuse` or a `csv:",required"` field makes that an error.
- A repeated key is a policy (`Duplicates`), and its default depends on the format: JSON keeps the last value,
  and CSV refuses a header that names a column twice. Set `duplicates` to choose another for either.
- Only 64-bit little-endian targets are supported (see [Requirements](#requirements)).

## Quick start
Import `stury:json` (see [Install](#install) for the collection flag). This is the body of
`examples/quickstart/main.odin`:

```odin
package main

import json "stury:json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"

Person :: struct {
	name: string,
	n:    i64,
}

main :: proc() {
	src := transmute([]byte)string(`{"name":"ada","n":1}`)
	if err, bad := json.validate(src).?; bad {
		fmt.eprintln(json.render_error(src, err))
		os.exit(1)
	}

	// What the read and the write allocate, freed at once.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		os.exit(1)
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	person: Person
	if uerr, bad := json.unmarshal(src, &person, allocator = alloc).?; bad {
		fmt.eprintln(json.render_error(src, uerr))
		os.exit(1)
	}
	out, merr := json.marshal(person, allocator = alloc)
	if merr != .None {
		fmt.eprintln(merr)
		os.exit(1)
	}
	fmt.println(string(out)) // {"name":"ada","n":1}
}
```

## Usage

The snippets below are cut from the programs in `examples/`. Run one from the repository root, for example
`odin run examples/scan -collection:stury=.`. The examples are:

- `examples/quickstart`: validate, `unmarshal` into a struct, `marshal` back.
- `examples/scan`: read one value by path.
- `examples/roundtrip`: build a document and query it.
- `examples/edit`: change one value in place.
- `examples/records`: walk NDJSON records.
- `examples/jsonc`: read JSONC.
- `examples/csv`: CSV rows into structs and back, dialects, a document, edits, streaming.
- `examples/crossformat`: one struct read from CSV, written as JSON and back, with one error path for both.

`make test` builds and runs all of them.

### Get one field without building a document (`examples/scan`)
`json.find` answers one path in one pass over the input and keeps nothing. The answer is a range (`lo`, `hi`)
of `src`, not a copy, and its `outcome` says whether the path landed.

```odin
src := transmute([]byte)string(`{"name": "ada", "tags": ["math", "engines"]}`)
a, err := json.find(src, ".tags[1]")
if err != nil {
	os.exit(1)
}
if a.outcome == .Found {
	fmt.println(string(src[a.lo:a.hi])) // "engines", quotes and all
}
```

A path that is not in the input still gives one answer, with outcome `.Missing`, so check `outcome` before you
read `lo` and `hi`.

A path is text in the jq subset, or a `json.Path` built from `json.Step` values, so a program can build one
without a string that is parsed at run time. Every procedure that takes a path takes either form:

```odin
json.Path{steps = {json.Name("tags"), json.Index(1)}} // the same request as ".tags[1]"
```

For every answer of a path, several paths, or one request run over many records, a `Request` says what to
read and `json.scan` fills it. Its type parameter lists the kinds of answer wanted: `{.Path}` asks for the
bytes of the values at some paths, the other kinds ask for a whole document. `json.answers` reads one
path's answers.

```odin
req: json.Request({.Path})
defer json.destroy(&req)
if json.request_init(&req, ".tags[]") != nil || json.scan(src, &req) != nil {
	os.exit(1)
}
tags, _ := json.answers(&req, 0) // one path: nothing to group, so no error
for t in tags {
	fmt.println(string(src[t.lo:t.hi])) // "math", then "engines"
}
```

### Build and query a document (`examples/roundtrip`)
`json.build` makes a `Document`, and `json.query` collects the `Node` handles a path reaches.

```odin
src := transmute([]byte)string(`{"name":"ada","n":1,"skip":[1,2,3]}`)
doc, err := json.build(src)
if err != nil {
	os.exit(1)
}
defer json.destroy(&doc)
nodes: [dynamic]json.Node
defer delete(nodes)
if json.query(&doc, json.ROOT, ".skip[]", &nodes) != nil {
	os.exit(1)
}
for n in nodes {
	if v, ok := json.get_int(&doc, n); ok {
		fmt.println(v)
	}
}
```

### Edit in place (`examples/edit`)
`json.set` replaces the value at a path and keeps every other byte of the source.

```odin
src := transmute([]byte)string(`{"name": "ada",  "tags": ["math"]}`)
out, err := json.set(src, ".name", "grace")
if err != nil {
	os.exit(1)
}
defer delete(out)
fmt.println(string(out)) // {"name": "grace",  "tags": ["math"]}
```

### NDJSON records (`examples/records`)
`json.records` and `json.next_record` walk the records of an NDJSON text (one JSON value per line) without
allocating.

```odin
src := transmute([]byte)string("{\"a\":1}\n{\"a\":tru}\n")
it := json.records(src, .NDJSON)
for rec in json.next_record(&it) {
	if e, bad := json.validate(rec.bytes).?; bad {
		e.offset += rec.at
		fmt.println(json.render_error(src, e)) // 2:9: Bad_Literal
	}
}
if e, bad := it.err.(json.Error); bad { // the framing itself failed, so the loop stopped early
	fmt.println(json.render_error(src, e))
}
```

To read a stream from an `io.Reader` in bounded memory, use `json.records_from`. To use several threads, start
a `host.Batch_Pool` from `stury:host` and pass its `runner` to `validate_records` (or `each_record`). Add
`import "stury:host"` at the top of the file:

```odin
pool: host.Batch_Pool
host.batch_pool_init(&pool) // one worker per core
defer host.batch_pool_destroy(&pool)
faults, _ := json.validate_records(src, .NDJSON, &pool.runner)
defer delete(faults)
for f in faults {
	fmt.println(json.render_error(src, f.err)) // 2:9: Bad_Literal
}
```

### JSONC (`examples/jsonc`)
`dialect = .Jsonc` reads comments and trailing commas, and strict JSON still refuses them.

```odin
src := transmute([]byte)string("{\n\t\"a\": 1 // one\n}\n")
_, jsonc_bad := json.validate(src, dialect = .Jsonc).?
_, strict_bad := json.validate(src).?
fmt.println(jsonc_bad, strict_bad) // false true: only strict JSON refuses the comment
```

### CSV (`examples/csv`)
`stury:csv` reads rows into structs by the header's column names and writes them back. Add
`import csv "stury:csv"`.

```odin
City :: struct {
	name:       string `csv:"City"`,
	population: Maybe(i64),
	lat, lon:   f64,
}

src := transmute([]byte)string("City,population,lat,lon\nOslo,709000,59.91,10.75\n\"Ho, Chi Minh\",,10.82,106.63\n")
cities: []City
if err, bad := csv.unmarshal(src, &cities).?; bad {
	fmt.eprintln(err.kind, "at byte", err.offset)
	os.exit(1)
}
fmt.println(cities[1].name, cities[1].population) // Ho, Chi Minh nil

out, err := csv.marshal(cities) // src again: "Ho, Chi Minh" keeps its quotes and the absent population stays empty
```

A cell the struct cannot hold is refused, and `render_error` locates it (`2:6: Wrong_Kind at [0].population`).
The columns are the header's names, so their order does not matter, and a column the struct lacks is read and
ignored unless `unknown_fields = .Refuse`.

A `Dialect` reads other delimited text through the same calls. `csv.TSV` is tab-separated values with the
backslash escapes jq's `@tsv` writes. `no_header` takes the first record as data, with column k filling the
struct's field k:

```odin
tsv := transmute([]byte)string("City\tpopulation\tlat\tlon\nOslo\t709000\t59.91\t10.75\n")
_, _ = csv.unmarshal(tsv, &cities, {dialect = csv.TSV}).?

// No header: column k is the struct's field k. A semicolon delimiter, and lines starting with # skipped.
plain := transmute([]byte)string("# name;population;lat;lon\nOslo;709000;59.91;10.75\n")
opts := csv.Unmarshal_Opts{dialect = {delimiter = ';', comment = '#'}, no_header = true}
_, _ = csv.unmarshal(plain, &cities, opts).?
```

`build` keeps the span of every cell as a `Document`, and `find` reads one cell off the front of the text
without building anything. A path counts rows from the first record after the header, and columns by index or
by the header's name:

```odin
doc, _ := csv.build(src)
defer csv.document_destroy(&doc)
col, _ := csv.column(&doc, "lat")
lat, _ := csv.get_float(&doc, 0, col)
fmt.println(csv.row_count(&doc), lat) // 2 59.91

field, found, _ := csv.find(src, ".[1].City")
text, _, _ := csv.field_text(src, field)
fmt.println(string(text)) // Ho, Chi Minh
```

`set`, `insert`, `remove` and `splice` return the text with the target changed and every other byte kept,
quoting included. A cell is spelled as `marshal` spells it, and an edit that would not read back as the same
table is refused:

```odin
edited, _ := csv.set(src, ".[0].population", 710000)
fmt.print(string(edited)) // City,population,lat,lon
//                           Oslo,710000,59.91,10.75
//                           "Ho, Chi Minh",,10.82,106.63

added, _ := csv.insert(src, csv.APPEND, City{name = "Bergen", lat = 60.39, lon = 5.32})
fmt.print(string(added)[len(src):]) // Bergen,,60.39,5.32

trimmed, _ := csv.remove(src, ".[].population") // the column, header included
```

`records_from` reads records from an `io.Reader` in bounded memory, with the same offsets and fault as
`records` on the whole text. `each_record` runs a task on pieces of a text on the threads of a
`host.Batch_Pool`, and `csv.validate` takes the same runner. `write_record` appends one record of text cells
to a buffer:

```odin
r: strings.Reader
strings.reader_init(&r, string(src))
rr := csv.records_from(io.to_reader(strings.reader_to_stream(&r)))
defer csv.records_destroy(&rr)
for rec in csv.next_record(&rr) {
	text, _, _ := csv.field_text(rec.src, rec.fields[0])
	fmt.println(rec.at, len(rec.fields), string(text)) // 0 4 City, then 24 4 Oslo, then 48 4 Ho, Chi Minh
}

count := proc(data: rawptr, piece: ^csv.Records, k: int) -> bool {
	for _ in csv.next_record(piece) {
		sync.atomic_add((^int)(data), 1)
	}
	return true
}
rows: int
_, _ = csv.each_record(src, {}, count, &rows, &pool.runner).? // pool as for validate_records above
fmt.println(rows) // 3: the header and two rows

line: [dynamic]u8
_ = csv.write_record(&line, []Maybe(string){"Tromsø", nil, "69.65", "18.96"})
fmt.print(string(line[:])) // Tromsø,,69.65,18.96
```

### CSV and JSON with one struct (`examples/crossformat`)
A tag string can hold several `key:"value"` pairs, and each format reads its own key (`csv:"City"`,
`json:"city"`). A field with no tag uses its own name in both. `csv.unmarshal` and `json.unmarshal` both
return `core.Unmarshal_Error`. `core.render_error` writes it for either format, and also writes a `validate`
fault (`core.Error`) and an edit refusal (`core.Path_Error`).

```odin
import "stury:core"
import csv "stury:csv"
import json "stury:json"

City :: struct {
	name:       string `csv:"City" json:"city"`,
	population: Maybe(i64),
	lat, lon:   f64,
}

Format :: enum {
	Csv,
	Json,
}

// Both formats return core's Unmarshal_Error, so one function handles either.
load :: proc(format: Format, src: []byte, cities: ^[]City) -> Maybe(core.Unmarshal_Error) {
	switch format {
	case .Csv:
		return csv.unmarshal(src, cities)
	case .Json:
		return json.unmarshal(src, cities)
	}
	unreachable()
}

// core.render_error writes the fault of either format as `line:col: kind at path`.
report :: proc(src: []byte, err: core.Unmarshal_Error) {
	fmt.println(core.render_error(src, err))
}
```

Read CSV, write JSON, read that back and write CSV again:

```odin
cities: []City
if err, bad := load(.Csv, table, &cities).?; bad {
	report(table, err)
	os.exit(1)
}
as_json, _ := json.marshal(cities)
fmt.println(string(as_json)) // [{"city":"Oslo","population":709000,"lat":59.91,"lon":10.75},{"city":"Ho, Chi Minh","population":null,"lat":10.82,"lon":106.63}]

back: []City
_, _ = load(.Json, as_json, &back).?
as_csv, _ := csv.marshal(back)
fmt.println(string(as_csv) == string(table)) // true
```

A population that is not a number, reported for each format:

```odin
bad_csv := transmute([]byte)string("City,population,lat,lon\nOslo,lots,59.91,10.75\n")
bad_json := transmute([]byte)string(`[{"city":"Oslo","population":"lots","lat":59.91,"lon":10.75}]`)
if err, bad := load(.Csv, bad_csv, &cities).?; bad {
	report(bad_csv, err) // 2:6: Wrong_Kind at [0].population
}
if err, bad := load(.Json, bad_json, &cities).?; bad {
	report(bad_json, err) // 1:30: Wrong_Kind at [0].population
}
```

A program that uses several formats imports `stury:core` for the shared types and each format's package for its
calls. `json.Error`, `csv.Error`, `json.Unmarshal_Error` and `csv.Unmarshal_Error` are aliases of core's types
and need no conversion. `core/aliases.odin` lists what the formats share.

## Command line
`stury` is a drop-in replacement for [jq](https://jqlang.org) 1.8: it runs jq filters and gives jq's results
and exit codes. Its messages start with `stury:` and are worded its own way; [docs/cli.md](docs/cli.md) lists
every place they differ. Install it as described in [Install](#install). With `make build-cli` the
binary is `build/stury`, so either copy it to a directory on your `PATH` or run it by that path.

```sh
echo '{"logs":[{"id":1}]}' | stury -c '.logs[].id'   # prints 1
stury check FILE
stury check --ndjson log.ndjson   # or --seq, or --jsonc
```

What differs from jq:

- Input is strict RFC 8259 JSON by default, so `01`, `NaN` and invalid UTF-8 are errors where jq accepts them,
  and an error names the fault and its line and column.
- `stury check FILE` only validates and prints nothing when the file is valid.
- `--ndjson` reads and prints one JSON value per line; `--jsonc` reads JSONC and prints comments back;
  `--csv` and `--tsv` read records as objects and write each output as a row. `--from` and `--to` choose the
  two sides apart (`stury --from csv --to json . people.csv`).

[docs/cli.md](docs/cli.md) lists every flag, and [each difference from jq](docs/cli.md#differences-from-jq).

### CSV and TSV
`--from` chooses how the input is read and `--to` how each output is written: `json`, `jsonc`, `ndjson`, `csv`
or `tsv`. The first record of a CSV or TSV file names the fields, and each later record is one input, an object
of strings. A cell is a number only after `tonumber`. An empty cell with no quotes is `null`. The examples
read this `cities.csv`:

```
city,country,population
Oslo,NO,709000
Bergen,NO,286000
Uppsala,SE,177000
"Ho, Chi Minh",VN,
```

```sh
$ stury --from csv -c 'select(.population) | .population |= tonumber' cities.csv   # CSV to JSON
{"city":"Oslo","country":"NO","population":709000}
{"city":"Bergen","country":"NO","population":286000}
{"city":"Uppsala","country":"SE","population":177000}
$ stury --csv 'select(.country == "NO") | {city, population}' cities.csv           # filter rows and columns
city,population
Oslo,709000
Bergen,286000
$ printf '{"a":1}\n{"b":2}\n' | stury --to csv --grow-header .                     # JSON to CSV
a,b
1,
,2
$ stury --from csv --to tsv '{city, country}' cities.csv                           # CSV to TSV
city	country
Oslo	NO
Bergen	NO
Uppsala	SE
Ho, Chi Minh	VN
$ stury check --from csv cities.csv                                                # prints nothing when valid
$ printf 'a,b\n1,2\n3\n' | stury check --from csv
stury: error: <stdin>:3:1: Record has the wrong number of fields (the header has 2)
```

`--csv` and `--tsv` set both sides, so a filter's objects are written as rows under a header. An object with a
key the header lacks ends the run, unless `--grow-header` is given: it holds the output and writes a header of
every key. A file up to 64 MiB is read whole. A larger file or a pipe is read a window at a time. [docs/cli.md](docs/cli.md#csv-and-tsv-recipes)
has more recipes (aggregating with `group_by`, columns, TSV) and the exact rules for cells, faults and output.

## Documentation
- The API's entry points, each a header that maps the package's public names to the files that hold them. The
  doc comment on each public name is its contract.
  - [json/json.odin](https://github.com/filip-41/stury/blob/main/json/json.odin): `stury:json`.
  - [csv/csv.odin](https://github.com/filip-41/stury/blob/main/csv/csv.odin): `stury:csv`, and what its
    scanner reads in every dialect.
  - [core/aliases.odin](https://github.com/filip-41/stury/blob/main/core/aliases.odin): `stury:core`, what the
    formats share (errors and their rendering, `Strictness`, `Duplicates`, paths, the type plan, `Batch_Runner`).
- [docs/cli.md](docs/cli.md): the command line, every flag and each difference from jq.
- [docs/stury.1](docs/stury.1): the command line's manual page (`man ./docs/stury.1`).
- [docs/codec.md](docs/codec.md): stury codec internals, for contributors: how the writer, the typed reader
  and the filter runner work.
- [CHANGELOG.md](CHANGELOG.md): what changed.

## Benchmark

These numbers were measured on one machine (Apple M5 Max, macOS 26.5, Odin dev-2026-10 at `-o:speed`) with
the harness in [bench/](bench/README.md), which documents how to run it, each arm and the fairness rules. Other data, filters and hardware will give other numbers, and no x86 results are published here;
simdjson's AVX-512 paths make the gaps narrower there.

**Against Odin's `core:encoding/json`**, in ms (lower is better). Median of 21 runs, both libraries in one
process with the same arena. Both decode the same values before any lane is timed. The load row builds a stury
DOM and reads every value once, since core has converted every number by the time it returns.

| Job | Input | stury | core:encoding/json | Speedup (core ÷ stury) |
| --- | --- | ---: | ---: | ---: |
| Validate | logs, 8 MB | **1.98** | 25.24 | 12.8× |
| Load into a DOM | logs, 8 MB | **2.34** | 40.59 | 17.3× |
| Unmarshal into structs | logs, 8 MB | **4.54** | 97.26 | 21.4× |
| Marshal structs | logs, 8 MB | **1.38** | 54.57 | 39.6× |
| Validate | nested, 16 MB | **4.77** | 48.64 | 10.2× |
| Load into a DOM | nested, 16 MB | **6.86** | 74.16 | 10.8× |
| Unmarshal into structs | nested, 16 MB | **9.21** | 219.21 | 23.8× |
| Marshal structs | nested, 16 MB | **9.15** | 102.61 | 11.2× |

("DOM" means a whole parsed document you can query.)

**Against other libraries**, in GB/s (higher is better). Median of 11 runs, interleaved. Every tool checks
UTF-8 and validates the whole input, and every arm's answer is checked against stury's before it is timed.

Typed decode into structs. serde_json and sonic-rs decode through `#[derive(Deserialize)]`, generic like
stury's `unmarshal`. simdjson and yyjson have no typed decode, so their columns are readers written by hand
for each struct, on simdjson's On-Demand API and on yyjson's DOM. Every arm builds a new value on each read
and keeps its parser and allocator.

| Input | stury | serde_json | sonic-rs | simdjson, hand-written | yyjson, hand-written |
| --- | ---: | ---: | ---: | ---: | ---: |
| logs, 8 MB | **3.55** | 1.38 | 1.92 | 2.38 | 3.04 |
| config, 1 MB | **4.85** | 1.28 | 1.44 | 3.33 | 2.63 |
| nested, 16 MB | **1.78** | 0.70 | 0.85 | 0.82 | 1.67 |

Validate. The simdjson column is its DOM parser, which validates as it builds. It refuses `escape.json`, whose
integers are wider than 64 bits.

| Input | stury | simdjson |
| --- | ---: | ---: |
| logs, 8 MB | **3.88** | 3.06 |
| nested, 16 MB | **3.44** | 1.59 |
| wide, 8 MB | **4.94** | 1.98 |
| pretty, 12 MB | **4.47** | 2.42 |
| deep, 8 MB | **1.57** | 0.66 |
| utf8, 8 MB | **9.18** | 5.52 |

On the eleven real-world files most parser benchmarks use (64 KB–3.3 MB, pretty-printed), stury validates
faster on seven. simdjson is faster on apache_builds (5.89 against 4.56), update-center (5.10 against 4.33),
github_events and twitter (within 5%).

DOM. The other libraries convert every number while they parse. stury checks each number while it builds
and converts it when it is read, so its first column builds the DOM and reads every value once, the same work
as the others. The second column is the build alone.

| Input | stury, every value read | stury, build only | yyjson | sonic-rs | simdjson | serde_json |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| logs, 8 MB | 3.31 | 4.02 | **3.52** | 3.26 | 3.00 | 0.69 |
| nested, 16 MB | 1.79 | 2.89 | **2.38** | 1.71 | 1.60 | 0.47 |
| wide, 8 MB | **3.31** | 4.83 | 3.01 | 2.20 | 1.98 | 0.19 |
| pretty, 12 MB | 2.91 | 3.59 | **3.63** | 1.74 | 2.43 | 0.68 |
| deep, 8 MB | 0.89 | 1.32 | **1.19** | 0.23 | 0.67 | |
| longtext, 8 MB | **19.8** | 20.2 | 5.37 | 14.2 | 8.36 | 6.83 |
| utf8, 8 MB | **8.01** | 8.13 | 1.33 | 7.77 | 5.55 | 1.01 |

With every value read, yyjson builds the DOM of number-heavy, nested and deep input faster,
and yyjson or simdjson is ahead on every real-world file but gsoc-2018. A program that reads only some values
pays only for those. The build alone leads on every synthetic input but `pretty`.

Get one field from `config.json` (1 MB), in µs per call (lower is better). stury's `.Lazy` stops at the match,
like sonic-rs. simdjson's On-Demand indexes the whole input first.

| Key | stury | simdjson | sonic-rs |
| --- | ---: | ---: | ---: |
| early | 0.064 | 111 | **0.039** |
| middle | **72** | 166 | 352 |
| last | **142** | 224 | 702 |

**CSV**, in GB/s, against the Rust `csv` 1.4 and `simd-csv` 0.14 crates. stury refuses quote misuse,
unterminated quotes and ragged rows, and checks UTF-8. The other columns name what each crate checks.

| Job | Input | stury | simd-csv | csv |
| --- | --- | ---: | ---: | ---: |
| Validate | table, 16 MB | **13.3** | 6.70 (`Splitter`, boundaries only) | 1.28 (`StringRecord`) |
| Validate | wide, 200 columns | 17.0 | **27.8** (`Splitter`) | 1.43 |
| Read every field | table | 2.08 | **3.77** (`TotalReader`, no checks) / 3.05 (`Reader`) | 1.23 |
| Read every field | text, quoted | 1.54 | **1.93** / 1.42 | 0.90 |
| Document, every cell read | table | 1.08 | **1.90** | 0.80 |
| Unmarshal into structs | table | **0.78** | | 0.53 (serde) |
| Unmarshal into structs | text | **0.67** | | 0.51 |
| Marshal structs | table | **1.00** | | 0.43 (serde) |
| Marshal structs | text | 1.04 | | **1.22** |

stury validates CSV faster than either crate reads it. Its record and document readers are slower than
simd-csv, and its writer is slower than the `csv` crate on quoted text.

**Command line**, with `bench/cli/jq_compare.sh`: 24 jq filters over the synthetic fixtures and three of the
real-world files, end to end with process start-up, against jq 1.8.2, jaq 3.0.0, gojq 0.12.19 and yq 4.53.2
(on the 11 filters yq can spell). Each figure is the other tool's median wall time divided by stury's, so 2.0×
means stury took half the time. Every tool gave the same answers.

| Tool | Geometric mean | Smallest |
| --- | ---: | ---: |
| jq | 14.6× | 5.0× |
| jaq | 6.8× | 2.2× |
| gojq | 10.2× | 3.4× |
| yq | 56× | 8.5× |

The smallest gaps are on the real-world files (0.6–2.2 MB), where every tool finishes in 2–20 ms and
start-up dominates. On the 6–11 MB fixtures stury is 6–100× faster than jq, jaq and gojq.

On CSV, with `bench/cli/csv_compare.sh` (two columns picked, rows filtered, quoted cells, CSV to JSON lines on
16 MB files), stury is 1.4–3.3× faster than Miller and 3.9–10× faster than jq's `-R` recipe. qsv 20.1 is
1.4–1.9× faster than stury.

## Development
```sh
make test        # build and run the suites and the examples
make lint        # the vet set, with warnings as errors
make test-modes  # the api suite with the alternative engines forced on
make test-asan   # the suites and the CLI under AddressSanitizer
make test-tsan   # the suites and the CLI under ThreadSanitizer
```

## License
MIT. See [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
