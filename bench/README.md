# Benchmarks

stury's benchmarks, beside other libraries and command lines doing the same jobs. Each lane is a folder under
`lanes/`, and one runner in `runner/` times all of them. Run every command from the repository root. The figures are
in [docs/benchmarks.md](../docs/benchmarks.md).

## Run

```sh
make fixtures                                   # fetch and generate the inputs, once
make bench-doc                                  # one lane
make bench-doc ROUNDS=3 ROWS="logs.json table.csv"
ARMS=stury,yyjson make bench-doc                # only these arms
uv run --project bench bench doc --rounds 3 logs.json
```

The lanes are `bench-doc`, `bench-paths`, `bench-typed`, `bench-records`, `bench-write`, `bench-edit`, `bench-schema`,
`bench-model`, `bench` (the kernels) and `bench-cli`. `ROUNDS` defaults to 5, and `ROWS` picks rows by label or fixture.

A lane builds what it runs first: stury's probe with Odin at `-o:speed`, the C and CPP drivers with CMake, the Rust
ones with Cargo. A driver whose toolchain is missing is left out with a note. `make bench-peers` builds every lane's
drivers, and the first build downloads the pinned C, C++ and Rust sources. The command line comparisons also need
hyperfine and the other tools on `PATH`.

On x86-64 the other libraries should be built for the host CPU, as the published x86-64 figures were, so each has its
widest vector kernels. Remove `build/bench/cmake` first, since CMake keeps the flags of its first configure:

```sh
CFLAGS=-march=native CXXFLAGS=-march=native RUSTFLAGS='-C target-cpu=native' make bench-peers
```

## How a figure is made

- **Timing:** each arm's figure is the median of ten calls after two warm-ups, and a lane prints the best of `ROUNDS`
  rounds. The arms alternate within each round. `timing/` holds the one clock and sampling rule every probe and driver
  uses, in Odin, C, Rust and Python.
- **GB/s:** the input's bytes over time, unless the table says otherwise (the write lanes count the bytes written).
- **Checks:** every arm prints a `check`, a hash of what it read or wrote. The runner times no row until every arm's
  check agrees. A row that cannot be checked says why in its `lane.toml`.
- **Memory:** an RSS table gives the median over the rounds of each child's peak, from `wait4`. A child that passes
  1 GiB of live RSS is killed, and `build/bench/timing.lock` keeps two benches from running at once.
- **Header:** every lane prints the Odin version, the CPU and the date first.

## Lanes

| Lane | Times | Other libraries on JSON and CSV |
| --- | --- | --- |
| `doc` | building a document, then reading every value, then looking up one key in every object | yyjson, simdjson, sonic-rs |
| `paths` | one key early, in the middle, late and absent, paths over `logs.json`, and streamed paths | simdjson On-Demand, sonic-rs |
| `typed` | `unmarshal` into structs, with strings borrowed and copied | serde_json, sonic-rs |
| `records` | NDJSON and CSV records: framing, checking, a document or a struct per record, on one thread and six | simdjson, serde_json, sonic-rs, simd-csv |
| `write` | `marshal` of a struct and writing a document, compact and pretty | yyjson, simdjson, sonic-rs, serde_json |
| `edit` | committing 1000 edits spread over a file's values | none (lol_html and toml_edit on HTML and TOML) |
| `schema` | judging instances against 19 JSON Schemas, as a verdict and with every error | Blaze, jsonschema-rs, boon |
| `model` | `model.load` of valid and invalid records, and `model.dump` | pydantic, msgspec, serde_json with garde |
| `kernel` | the SIMD block kernels and the number writers, in ns, instructions and cycles per unit | none |
| `cli` | whole commands, process start included | jq, jaq, gojq, yq; qsv, Miller |

The other formats' rows run beside these libraries:

| Format | doc | paths | typed | records | write |
| --- | --- | --- | --- | --- | --- |
| XML | pugixml, libxml2, expat, roxmltree, quick-xml | pugixml, quick-xml | quick-xml | | pugixml, quick-xml |
| YAML | rapidyaml, libfyaml, libyaml, saphyr | rapidyaml | serde_yaml_ng | rapidyaml, libyaml | rapidyaml, serde_yaml_ng |
| TOML | toml++, toml11, toml | toml++ | toml | | toml++, toml |
| HTML | lexbor, gumbo, html5ever | lexbor, scraper | | | lexbor, html5ever |
| CBOR | ciborium, minicbor, tinycbor, QCBOR, libcbor | minicbor | ciborium, minicbor | ciborium, minicbor | ciborium, minicbor, tinycbor |

An arm whose name ends in `_nv` does not judge all that stury judges: pugixml and quick-xml check that tags nest, not
names, repeated attributes, entities or namespaces. QCBOR and libcbor do not check the UTF-8 of text strings, so their CBOR table is apart from the others. In
the schema lane, jsonschema-rs and boon read a YAML, TOML, XML or CBOR instance through a Rust parser of the format, and
Blaze reads JSON only.

### doc

- `build` builds the document and stops. Its check is the node count, then each node's kind and role.
- `read` builds, then reads every value once: strings decoded, numbers parsed.
- `key` builds, then looks up the first key of the first object in every object, stopping at the first match.

The other libraries run on `.json` rows. `logs.jsonc` and `logs.json5` hold `logs.json`'s records with comments and
trailing commas, and with JSON5's spellings. The probe builds in a 512 MiB arena that is not zeroed, so only the pages
a row touches count toward its RSS.

### paths

`scan` reads the whole text and answers, `stop` stops at the answer, and `build_query` builds a document first. A row
that stops early leaves bytes unread, so it shows ns and no GB/s. A one-key sample is 100 calls, since one call takes a
few ticks of the clock.

### typed

stury, serde_json and sonic-rs read `logs`, `twitter` and `citm` into the same structs (`lanes/typed/rust/types.rs`).
`table` and `text` are CSV rows, read by stury alone. Each arm prints a fold of the values it read.

### records

| Arm | Job |
| --- | --- |
| `frame`, `check`, `build`, `stream`, `read`, `refuse`, `write`, `cells`, `rows`, `text` | stury on one thread |
| `threads`, `validate`, `each` | stury on a pool of six threads |
| `simd`, `simd_nt` | simdjson `parse_many`: every document judged and a tape built |
| `simd_od`, `simd_od_nt` | simdjson `iterate_many`, each document skipped: it checks structure, not escapes or numbers |
| `serde_validate`, `serde_value` | serde_json's stream into `IgnoredAny`, into a `Value` |
| `sonic_validate`, `sonic_value` | sonic-rs's stream into `IgnoredAny`, into a `Value` |
| `csv_frame` | simd-csv's splitter: record bounds, no cells |

simdjson runs its next batch's stage 1 on a thread of its own, so the `_nt` arms turn that off. Every arm prints the
number of records it passed.

### write

| Arm | Struct | Document |
| --- | --- | --- |
| `stury` | `marshal` | `write` |
| `yyjson` | a mutable document built from C structs inside the clock, then written | `yyjson_write_buf` |
| `simdjson` | none | `to_string` of a DOM element, compact only |
| `simd_min` | none | `minify` of the source text, which reads no values and is not checked |
| `sonic`, `serde` | `to_writer` of a serde struct | `to_writer` of their `Value` |

Reading the input is outside the clock. The C and Rust structs hold the same fields in the same order as stury's, so
every arm writes the same text. `nested.json` and `escape.json` run unchecked, since each library spells exponents,
escapes and large integers its own way.

### schema

The schemas are 15 from sourcemeta-research/jsonschema-benchmark and 4 from `runner/gen.py`: `logs`, `twitter` and
`citm` with a closed schema inferred from the data, and `applicator`, events under `oneOf`, `if`/`then` and
`unevaluatedProperties`. Every schema is the benchmark's `schema-noformat.json`, so no arm asserts a format.

| Form | stury | Blaze | jsonschema-rs | boon |
| --- | --- | --- | --- | --- |
| `verdict` | `schema.valid` | FastValidation | `is_valid` | `validate().is_ok()` |
| `errors` | `schema.check` | Exhaustive | `iter_errors` | `basic_output` |

Each arm parses every instance with its own parser. The arms must give the same verdict on every instance before a
schema is timed. `make diff-schema` checks the same instances against Python's `jsonschema`.

### model

The fixtures are the `logs` and `twitter` records with rules on most members: bounds, lengths, patterns, required
members and two defaults. The invalid ones break two to four rules in about a third of the records. Each arm states
the same rules in its library's way.

- **load, every failure:** stury, pydantic and garde, which list every failure of a record.
- **load, first failure:** stury and msgspec, which stop at a record's first failure.
- **dump:** every arm. A float with no fraction is hashed without its `.0`, since stury writes `396` where the others
  write `396.0`.

The Python arms run with the garbage collector off, and the objects they build count as part of the job.

### kernel

```sh
make bench ROUNDS=3 CASES='utf8|str'
```

Instructions and cycles per unit come from the difference between runs of R and 2R repetitions, which cancels the
setup. `CASES` is a regex of case names, `COUNT=0` skips the counting, and `TIER` picks the kernel tier.

### cli

```sh
make bench-cli
uv run --project bench bench cli --suite csv
make bench-cli ROUNDS=3 CASES=logs
```

Each case in `lanes/cli/cases.toml` asks every tool the same question. Each tool's answer is compared with stury's
before anything is timed. The `jq` suite runs jq, jaq, gojq and yq, and the `csv` suite qsv, Miller and `jq -R`.
The `xml` suite runs yq, xmlstarlet and xmllint, the `yaml` and `toml` suites yq and dasel, and the `html` suite htmlq
and pup. `build/bench/cli/report.md` has the median milliseconds per case and tool, the ratio to stury and whether the
answers matched.

## Fixtures

`make fixtures` writes every input into `bench/fixtures/`, and `bench fixtures --check` verifies the generated ones
without writing them, fetching only the corpus they read. Each file's SHA-256 is pinned in `fixtures.toml`.

- **Downloaded:** the twitter, citm and canada corpus, the jsonschema-benchmark schemas, and real YAML, TOML, XML and
  HTML documents (Kubernetes manifests, an OpenAPI spec, lock files, an OpenStreetMap extract, the WHATWG spec,
  Wikipedia articles), each at a commit or a web.archive.org snapshot. They keep their publishers' terms, so they are
  fetched, not committed.
- **Generated:** `runner/gen.py` writes the synthetic inputs from seeded generators. The YAML, TOML, XML, HTML and CBOR
  copies of `logs`, `twitter` and `citm` come from pinned Python writers, never from stury.

A lane looks for a fixture in `fixtures/`, then `fixtures/corpus/`, then `fixtures/natural/`. To add a generated one,
add its generator to `FIXTURES` in `runner/gen.py`, run `uv run --project bench bench fixtures NAME` and paste the line
it prints into `fixtures.toml`.

## Adding an arm

A lane's `lane.toml` names its arms, its rows and the arguments each program takes. An arm's `source` is `stury` (the
Odin probe in `stury/`), a `.c`, `.cc` or `.cpp` file built by `CMakeLists.txt`, `rust` (a package in the Cargo
workspace), or a `.py` file run with the bench project's Python. A program prints one line of `key=value` tokens with at
least `gb_per_s` and `check`, and `ns` where the lane shows it. Run alone, it prints the same line.
