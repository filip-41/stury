# stury

stury is a JSON and CSV library for [Odin](https://odin-lang.org), with a command line, `stury`, that runs jq
filters over JSON and CSV.

Input is checked strictly by default: JSON against RFC 8259 (no `01`, no `NaN`, no invalid UTF-8, no lone
surrogate), CSV against RFC 4180.

**Status:** pre-1.0. The API may still change between releases; [CHANGELOG.md](CHANGELOG.md) lists what is
released and what is not.

## Features

- **Validate** JSON without allocating, with the line and column of the first fault.
- **Read one value by path** (`.tags[1]`) without parsing the rest of the input, or answer several paths in
  one pass.
- **Decode into Odin types and encode them back** (`unmarshal`, `marshal`): structs, slices, maps, unions,
  bit sets and `any`, from the type alone. Field tags and hooks cover custom names and types.
- **Build a document** and query it by path, with strings that point into the input.
- **Edit a text**: change, insert or remove a value and keep every other byte, formatting and comments
  included.
- **JSONC, NDJSON and RFC 7464** text sequences, with JSONC comments kept and written back.
- **CSV and TSV** through the same struct mapping, documents and edits as JSON, with dialects for other
  delimiters, quoting, escapes, comment lines and files without a header.
- **Optional threads**: validate or process records in parallel on a `stury:host` pool. The
  library starts no thread and keeps no global state.
- **A jq 1.8 command line** that gives jq's answers and exit codes, reads and writes CSV and TSV, and reports
  faults with their line and column.

## Install

**Library.** stury needs [Odin](https://odin-lang.org/docs/install/) `dev-2026-10` and a 64-bit little-endian
target (darwin or linux, amd64 or arm64; the command line also builds on Windows). Clone it into your project
and add it as a collection:

```sh
git clone https://github.com/filip-41/stury vendor/stury
odin build . -collection:stury=vendor/stury -o:speed
```

Then `import "stury:json"`, `import csv "stury:csv"` and `import "stury:host"`. Keep `json/`, `csv/`, `core/`
and `host/` together. For the [ols](https://github.com/DanielGavin/ols) language server, add the same
collection to `ols.json`: `{"collections": [{"name": "stury", "path": "vendor/stury"}]}`.

**Command line.** Download a binary for linux or darwin, amd64 or arm64, from
[GitHub Releases](https://github.com/filip-41/stury/releases) and put it on your `PATH`. Each archive has a
`.sha256` beside it. To build it yourself, run `make build-cli`, which writes `build/stury`.

## Quick start

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

This is [examples/quickstart](examples/quickstart/main.odin). Run it from the repository root with
`odin run examples/quickstart -collection:stury=.`.

## Examples

Read one value by path. The answer is a byte range of `src`, not a copy:

```odin
src := transmute([]byte)string(`{"name": "ada", "tags": ["math", "engines"]}`)
a, err := json.find(src, ".tags[1]")
if err == nil && a.outcome == .Found {
	fmt.println(string(src[a.lo:a.hi])) // "engines"
}
```

Change one value and keep every other byte:

```odin
out, err := json.set(src, ".name", "grace") // {"name": "grace", "tags": ["math", "engines"]}
```

Read CSV rows into structs by the header's column names:

```odin
City :: struct {
	name:       string `csv:"City"`,
	population: Maybe(i64),
}

cities: []City
err := csv.unmarshal(transmute([]byte)string("City,population\nOslo,709000\n"), &cities)
```

The [library guide](docs/guide.md) covers each of these in full, with allocation and limits. The complete
programs are in [examples/](examples):

| Program | Shows |
| --- | --- |
| [scan](examples/scan/main.odin) | one value, or every value of a path, without building a document |
| [roundtrip](examples/roundtrip/main.odin) | building a document and querying it |
| [edit](examples/edit/main.odin) | changing a value in place |
| [records](examples/records/main.odin) | NDJSON records, sequentially and on threads |
| [jsonc](examples/jsonc/main.odin) | JSON with comments |
| [csv](examples/csv/main.odin) | CSV into structs and back, dialects, documents, edits, streaming |
| [crossformat](examples/crossformat/main.odin) | one struct read from CSV and JSON, with one error type |

## Command line

`stury` runs [jq](https://jqlang.org) 1.8 filters with jq's results and exit codes. Input is strict JSON by
default, so `01`, `NaN` and invalid UTF-8 are errors, reported with their line and column. `--from` and `--to`
choose `json`, `jsonc`, `ndjson`, `csv` or `tsv`.

`stury fmt` formats a file in place, or transcodes it (`--from csv --to tsv`), with `--check` for CI.

```sh
$ echo '{"logs":[{"id":1}]}' | stury -c '.logs[].id'
1
$ stury check --from ndjson log.ndjson    # prints nothing when valid
$ stury --from csv --to csv 'select(.country == "NO") | {city, population}' cities.csv
city,population
Oslo,709000
Bergen,286000
```

Over 24 filters, process start-up included, it is 14.5 times faster than jq and 6.7 times faster than jaq
(geometric mean). [docs/cli.md](docs/cli.md) lists every option, the CSV rules and recipes, and
[each difference from jq](docs/cli.md#differences-from-jq).

## Documentation

- [Library guide](docs/guide.md): usage, allocation and ownership, limits, CSV specifics.
- API reference: the doc comment on each public name. [json/json.odin](json/json.odin),
  [csv/csv.odin](csv/csv.odin) and [core/core.odin](core/core.odin) list the names and their files.
- [Command line](docs/cli.md), and its manual page [docs/stury.1](docs/stury.1) (`man ./docs/stury.1`).
- [Benchmarks](docs/benchmarks.md), measured with the harness in [bench/](bench/README.md).
- [Internals](docs/codec.md), for contributors.

## Development

```sh
make test        # the suites, the CLI tests and the examples (needs python3)
make lint        # the vet set, with warnings as errors
make test-modes  # the api suite with the alternative engines forced on
make test-asan   # the suites and the CLI under AddressSanitizer
make test-tsan   # the suites and the CLI under ThreadSanitizer
make diff        # compare answers with jq 1.8.2 on PATH
```

## License

MIT. See [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
