# stury

stury is a JSON and CSV library for [Odin](https://odin-lang.org), with a command line, `stury`, that runs jq
filters over JSON and CSV.

Input is checked strictly by default: JSON against RFC 8259 (no `01`, no `NaN`, no invalid UTF-8, no lone
surrogate), CSV against RFC 4180.

**Status:** pre-1.0. The API may still change between releases ([CHANGELOG.md](CHANGELOG.md)).

## Features

- **Validate** JSON without allocating, with the line and column of the first fault.
- **Read one value by path** (`.tags[1]`) without parsing the rest of the input, or answer several paths in
  one pass.
- **Decode into Odin types and encode them back** (`unmarshal`, `marshal`): structs, slices, maps, unions,
  bit sets and `any`, from the type alone. Field tags and hooks cover custom names and types.
- **Build a document** and query it by path, with strings that point into the input.
- **Edit a text**: change, insert or remove a value and keep every other byte, formatting and comments
  included.
- **JSONC, JSON5, NDJSON and RFC 7464** text sequences, with comments kept and written back.
- **CSV, TSV and other delimited text** through the same struct mapping, documents and edits as JSON, with
  options for the delimiter, comment lines and files without a header.
- **One interface for every format.** A format is a `Spec` passed to the same calls, and every format returns
  the same error types.
- **Optional threads**: process records in parallel on a `stury:host` pool. The library starts no thread and
  keeps no global state.
- **A jq 1.8 command line** that gives jq's answers and exit codes, reads and writes CSV and TSV, and reports
  faults with their line and column.

## Install

**Library.** stury needs [Odin](https://odin-lang.org/docs/install/) `dev-2026-11` or later, and a 64-bit
little-endian target (darwin or linux, amd64 or arm64, and the command line also builds on Windows). Clone it into
your project and add it as a collection:

```sh
git clone https://github.com/filip-41/stury vendor/stury
odin build . -collection:stury=vendor/stury -o:speed
```

Then `import "stury:core"`, `import "stury:json"`, `import "stury:dsv"` for delimited text, and `import
"stury:host"` for threads. Keep the package directories together. For the
[ols](https://github.com/DanielGavin/ols) language server, add the same collection to `ols.json`:
`{"collections": [{"name": "stury", "path": "vendor/stury"}]}`.

**Command line.** Download a binary for linux or darwin, amd64 or arm64, from
[GitHub Releases](https://github.com/filip-41/stury/releases) and put it on your `PATH`. To build it yourself, run
`make build-cli`, which writes `build/stury`.

## Quick start

```odin
package main

import "stury:core"
import "stury:json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

Person :: struct {
	name: string,
	n:    i64,
}

// A fault or an error renders as `line:col: message`, with the path when it has one.
report :: proc(src: []u8, e: $E) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	core.render(strings.to_writer(&b), src, e)
	fmt.eprintln(strings.to_string(b))
}

main :: proc() {
	src := transmute([]byte)string(`{"name":"ada","n":1}`)
	if fault, bad := json.validate(src, .Json).?; bad {
		report(src, fault)
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
	if err := json.unmarshal(src, .Json, &person, allocator = alloc); err.kind != .None {
		report(src, err)
		os.exit(1)
	}
	out, err := json.marshal(person, allocator = alloc)
	if err.kind != .None {
		report(nil, err)
		os.exit(1)
	}
	fmt.println(string(out)) // {"name":"ada","n":1}
}
```

This is [examples/quickstart](examples/quickstart/main.odin). Run it from this directory with
`odin run examples/quickstart -collection:stury=.`.

## Examples

Read one value by path. The answer is a node of a small document that borrows `src`:

```odin
second_tag, _ := core.parse_path(".tags[1]")
defer core.path_destroy(&second_tag)
doc, answer, err := json.find(src, .Json, second_tag)
defer core.destroy(&doc)
if a, found := answer.?; found && a.outcome == .Found {
	fmt.println(string(core.span(&doc, a.node))) // "engines"
}
```

Change one value and keep every other byte:

```odin
name, _ := core.parse_path(".name")
out, err := json.set(src, .Json, name, `"grace"`) // {"name": "grace",  "tags": ["math"]}
```

Read CSV rows into structs by the header's column names:

```odin
City :: struct {
	name:       string `csv:"City"`,
	population: Maybe(i64),
}

cities: []City
err := dsv.unmarshal(transmute([]byte)string("City,population\nOslo,709000\n"), .Csv, &cities, allocator = context.temp_allocator)
```

The [library guide](docs/guide.md) covers each of these in full, with allocation and limits. The complete
programs are in [examples/](examples). Each prints a fixed answer, and `make test-examples` runs them all.

| Program | Shows |
| --- | --- |
| [quickstart](examples/quickstart/main.odin) | validate, `unmarshal`, `marshal` and error rendering |
| [scan](examples/scan/main.odin) | one value, or every value of a path, without building a whole document |
| [roundtrip](examples/roundtrip/main.odin) | building a document and querying it |
| [edit](examples/edit/main.odin) | changing a value in place, and several edits in one commit |
| [records](examples/records/main.odin) | NDJSON records, from a stream, and on threads |
| [jsonc](examples/jsonc/main.odin) | JSON with comments |
| [dsv](examples/dsv/main.odin) | CSV into structs and back, dialects, documents, edits, streaming |
| [crossformat](examples/crossformat/main.odin) | one struct read from CSV and JSON, with one error type |

## Command line

`stury` runs [jq](https://jqlang.org) 1.8 filters with jq's results and exit codes. Input is strict JSON by
default, so `01`, `NaN` and invalid UTF-8 are errors, reported with their line and column. `--from` and `--to`
choose `json`, `jsonc`, `json5`, `ndjson`, `csv` or `tsv`.

`stury fmt` formats files, rewriting them with `--in-place`, or transcodes them (`--from csv --to tsv`), with
`--check` for CI. `stury check` validates without printing.

```sh
$ echo '{"logs":[{"id":1}]}' | stury -c '.logs[].id'
1
$ stury check --from ndjson log.ndjson    # prints nothing when valid
$ stury --from csv --to csv 'select(.country == "NO") | {city, population}' cities.csv
city,population
Oslo,709000
Bergen,286000
```

[docs/cli.md](docs/cli.md) lists every option, the CSV rules and recipes, and
[each difference from jq](docs/cli.md#differences-from-jq). `--explain` shows how a filter is run.

## Documentation

- [Library guide](docs/guide.md): usage, allocation and ownership, limits, delimited-text specifics.
- API reference: the doc comment on each public name, and [API.txt](API.txt), which lists them all.
- [Command line](docs/cli.md), and its manual page [docs/stury.1](docs/stury.1) (`man ./docs/stury.1`).
- [Benchmarks](docs/benchmarks.md): the comparisons, their method and their fairness rules. The figures are
  written there once they are measured on this tree. [bench/README.md](bench/README.md) describes the harness.
- Internals, for contributors, one file per part: [walk](docs/walk.md), [document](docs/document.md),
  [paths](docs/paths.md), [typed reads](docs/typed.md), [writer](docs/writer.md), [records](docs/records.md),
  [kernel](docs/kernel.md) and [hot paths](docs/hotpaths.md).

## Packages

| Package | Holds |
|---|---|
| `core` | what every format shares: the document, its readers, the edit list, paths and their answers, `Write_Options`, errors and their rendering |
| `json` | the `Json`, `Jsonc` and `Json5` specs: `validate`, `build`, `find`, `scan`, `set`, `commit`, `unmarshal`, `marshal`, `format` |
| `dsv` | the `Csv`, `Tsv` and `Plain` specs, with the same calls |
| `core/records` | a text that holds a list of records, read or written one record at a time, for any format |
| `core/typed` | the type plan and the options of a typed read |
| `core/write` | the typed write and the token write |
| `core/build` | the document builder and the path engine, which a format's calls use |
| `core/kernel`, `core/spell`, `core/compose` | vector code, number decoders and number text, and the composition of edits |
| `host` | `Pool`, the threads that `records.each` borrows |

## Development

Run these from this directory. `ODIN` names the compiler when it is not on `PATH`.

```sh
make check          # the checks the files you changed can reach, in seconds
make gate           # the full gate, once, when a branch is finished
make test           # the suites, the CLI tests and the examples
make test-examples  # build and run the eight example programs against their expected output
make lint           # the vet set, with warnings as errors
make test-asan      # the suites under AddressSanitizer
make test-tsan      # the suites under ThreadSanitizer
```

## License

MIT. See [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
