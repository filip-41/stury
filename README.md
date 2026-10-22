# stury

stury is a structural data processing library currently supporting JSON for [Odin](https://odin-lang.org),
plus a command line that runs jq filters on top of the data.

It is built for programs that read a lot of data and want to do little work per byte. You can check a text for
errors without allocating, pull one value out by path without parsing the rest, load a whole text into a
queryable document, read it straight into your own structs, or edit it while keeping every byte you did not
touch.

Input is checked strictly against its `dialect`. The default, JSON, follows RFC 8259: no `01`, no `NaN`, no
invalid UTF-8, no lone surrogate. stury also reads JSONC, NDJSON and RFC 7464 text sequences. In the
[benchmarks](#benchmark) below it runs 9.3 to 38.9 times faster than Odin's `core:encoding/json`, and ahead of
simdjson, yyjson and sonic-rs on most rows (measured on one machine, the harnesses are not public yet, and
tuning may differ between architectures at this stage of the project).

**Status:** version 0.0.1. The API may still change between releases (see [CHANGELOG.md](CHANGELOG.md)).

## Install

**Library.** Clone the repository into your project:

```sh
git clone https://github.com/filip-41/stury vendor/stury
odin build . -collection:stury=vendor/stury -o:speed
```

`-collection:stury=PATH` makes `import "stury:json"` and `import "stury:host"` resolve to the directories
under PATH. Keep `json/`, `core/` and `host/` together in the copy. For the
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
- **Duplicate keys are a policy**: keep the last, the first, all of them, or refuse the text.
- **A jq 1.8 command line.** `stury` runs jq filters with jq's answers and exit codes as the baseline,
  with its own `stury:` messages, and differs where jq loses data or misreports an error ([listed in
  docs/cli.md](docs/cli.md#differences-from-jq)). It adds `check`, `--ndjson` and `--jsonc`.

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
- `--ndjson` reads one JSON value per line; `--jsonc` reads JSONC and prints comments back.

[docs/cli.md](docs/cli.md) lists every flag, and [each difference from jq](docs/cli.md#differences-from-jq).

## Documentation
- [json/json.odin](https://github.com/filip-41/stury/blob/main/json/json.odin) is the API's entry point. The
  doc comment on each public name in `json/` is its contract.
- [docs/cli.md](docs/cli.md): the command line, every flag and each difference from jq.
- [docs/stury.1](docs/stury.1): the command line's manual page (`man ./docs/stury.1`).
- [docs/codec.md](docs/codec.md): stury codec internals, for contributors: how the writer, the typed reader
  and the filter runner work.
- [CHANGELOG.md](CHANGELOG.md): what changed.

## Benchmark

These numbers were measured on one machine (Apple M5 Max, macOS 26.5, Odin dev-2026-10 at `-o:speed`), and the
harnesses are not public yet. Other data, filters and hardware will give other numbers, and no x86 results are
published here, so it needs to be mentioned that simdjson's AVX-512 paths make the gaps narrower there.

**Against Odin's `core:encoding/json`**, in ms (lower is better). Median of 21 runs, both libraries in one
process with the same arena. Both decode the same values before any lane is timed. Speedup is core's time
divided by stury's.

| Job | Input | stury | core:encoding/json | Speedup (core ÷ stury) |
| --- | --- | ---: | ---: | ---: |
| Validate | logs, 8 MB | **2.11** | 25.96 | 12.3× |
| Load into a DOM | logs, 8 MB | **2.56** | 41.37 | 16.1× |
| Unmarshal into structs | logs, 8 MB | **4.92** | 97.37 | 19.8× |
| Marshal structs | logs, 8 MB | **1.42** | 55.09 | 38.9× |
| Validate | nested, 16 MB | **5.23** | 48.75 | 9.3× |
| Load into a DOM | nested, 16 MB | **7.91** | 75.03 | 9.5× |
| Unmarshal into structs | nested, 16 MB | **13.07** | 221.35 | 16.9× |
| Marshal structs | nested, 16 MB | **9.52** | 102.16 | 10.7× |

("DOM" means a whole parsed document you can query.)

**Against other libraries**, in GB/s (higher is better). Median of 11 runs. Every tool checks UTF-8 and
validates the whole input.

Typed decode into structs. serde_json and sonic-rs decode through `#[derive(Deserialize)]`, generic like
stury's `unmarshal`. simdjson and yyjson have no typed decode, so their columns are readers written by hand
for each struct, on simdjson's On-Demand API and on yyjson's DOM. Every arm builds a new value on each read
and keeps its parser and allocator.

| Input | stury | serde_json | sonic-rs | simdjson, hand-written | yyjson, hand-written |
| --- | ---: | ---: | ---: | ---: | ---: |
| logs, 8 MB | **3.54** | 1.24 | 1.89 | 2.34 | 2.94 |
| config, 1 MB | **4.21** | 1.28 | 1.43 | 3.40 | 2.65 |
| nested, 16 MB | **1.94** | 0.67 | 0.85 | 0.77 | 1.66 |

Validate, DOM and get-one-field. The simdjson column is its DOM parser for validate and DOM, and On-Demand for
get-one-field.

| Job | Input | stury | simdjson | yyjson | sonic-rs | serde_json |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Validate | logs | **3.84** | 2.95 | | | |
| Validate | nested | **3.10** | 1.44 | | | |
| DOM | logs | **3.87** | 2.91 | 3.38 | 3.16 | 0.56 |
| DOM | nested | **2.62** | 1.45 | 2.31 | 1.67 | 0.43 |
| DOM | wide, 8 MB | **4.29** | 1.93 | 2.95 | 2.13 | 0.17 |
| DOM | pretty, 12 MB | **3.70** | 2.28 | 3.53 | 1.69 | 0.60 |
| DOM | deep, 8 MB | **1.20** | 0.68 | 1.15 | 0.21 | |
| Get one field | config, middle key | **9.26** | 6.01 | | 2.96 | |
| Get one field | config, last key | **4.66** | 4.54 | | 1.46 | |

Where stury loses: sonic-rs returns a key near the start of a document about twice as fast, and on the last
key of `config` simdjson's On-Demand is within 3%. Off the tables, stury builds the DOM of long-string and
UTF-8 input 2-6× faster than yyjson.

**Command line**, against jq 1.8.2, jaq 3.0.0 and gojq 0.12.19, on a panel of generated `users` fixtures
(narrow rows are `{id, score}`, broad rows about 1 KB) with 29 document filters and 5 NDJSON filters. Each
cell is the geometric mean of the other tool's median wall time divided by stury's, end to end with process
start-up, so 2.0× means stury took half the time. Every tool gave the same answers.

| Input | 100 rows | 1,000 rows | 25,000 rows |
| --- | --- | --- | --- |
| Document, narrow | jq 1.8×, jaq 1.6×, gojq 1.7× | jq 2.1×, jaq 1.8×, gojq 2.0× | jq 7.0×, jaq 4.5×, gojq 5.6× |
| Document, broad | jq 2.5×, jaq 1.9×, gojq 2.3× | jq 7.3×, jaq 3.8×, gojq 6.0× | jq 34×, jaq 15×, gojq 24× |
| NDJSON, narrow | jq 1.9×, jaq 1.7×, gojq 1.8× | jq 1.5×, jaq 1.4×, gojq 1.8× | jq 11×, jaq 10×, gojq 17× |
| NDJSON, broad | jq 2.8×, jaq 1.8×, gojq 2.3× | jq 8.8×, jaq 4.1×, gojq 6.8× | jq 68×, jaq 25×, gojq 47× |

Small inputs finish in 1–7 ms for every tool, so there the lead is mostly start-up, and it is modest: the
smallest single-filter gap was 1.2×, against jaq on a `select` over 1,000 NDJSON rows. The gap widens with
input size, because stury answers many filters with one scan instead of building every value.

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
