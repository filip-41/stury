# Benchmarks

One probe per library lane (`doc/`, `paths/`, `typed/`, `records/`, `schema/`, `write/`), one runner beside it (`doc.py`,
`paths.py`, `typed.py`, `records.py`, `schema.py`, `write.py`) that times the probe against the other libraries' drivers in
`peers/`, and the command line comparisons in `cli/`. Run every command below from the repository root.

| Target | Runner | Takes | Default |
| --- | --- | --- | --- |
| `make bench-doc` | `doc.py` | fixtures, any file the probe reads (`BENCH_FILES`) | `logs.json citm_catalog.json table.csv logs.jsonc logs.json5` |
| `make bench-paths` | `paths.py` | nothing: its lanes and fixtures are fixed | |
| `make bench-typed` | `typed.py` | lanes (`LANES`), each bound to a struct, so no other file | all five |
| `make bench-records` | `records.py` | fixtures from the list below (`RECORD_FILES`) | all of them |
| `make bench-schema` | `schema.py` | fixtures (`SCHEMA_FIXTURES`) | all 19 |
| `make diff-schema` | `schema_oracle.py` | fixtures (`SCHEMA_FIXTURES`) | all 19 |
| `make bench-write` | `write.py` | lanes (`LANES`), each with its own fixtures | all four |
| `make bench` | `run.py` | `CASES`, a regex of case names | all |
| `make bench-cli` | `cli/jq_compare.sh` | `CASES`, a regex of case names | all |

Every runner takes `--rounds N` (else `ROUNDS`, default 5), refuses any other option, and prints the Odin version, the
CPU and the date first. `ARMS=stury,yy` keeps a subset of the arms. GB/s is the best round of each arm's median of
ten timed calls after two warm-ups, of the source's bytes unless a table says otherwise. Every probe and peer follows
that rule (`bench/timing` for the Odin probes, `peers/rust/src/timing.rs`, `median_ns` in `cpp_bench.cpp`, `WARMUP` and
`TIMED` in `yy_bench.c`). A probe prints the same lines when run alone.

Every runner and every command line script runs under `bench/guard.py`: it holds `build/bench/timing.lock`, so two
benches never overlap, and kills a process that passes 1 GB of live RSS (for the scripts, any process they start). It
is also a program, `python3 bench/guard.py COMMAND...`.

## Document lanes

`bench/doc` builds a document from a fixture, then measures one of three lanes. `doc.py` times it against
yyjson, simdjson and sonic-rs.

## Fetch and generate

```sh
make fixtures
```

`bench/fetch.py` downloads the pinned corpus (`twitter.json`, `citm_catalog.json`, `canada.json`) into
`bench/fixtures/corpus/` and the peers' sources into `build/bench/deps/`, checking each SHA-256. `fetch.py schema` adds the
schema lane's 15 schemas and instances (`bench/fixtures/jsonschema-benchmark/`, with each `schema-noformat.json`) and
`fetch.py archive` Blaze's source. `bench/gen.py` writes
the synthetic fixtures into `bench/fixtures/` and exits non-zero when one `manifest.toml` pins has other bytes.
`gen.py --check` writes nothing. A runner looks for a fixture in `bench/fixtures/`, then `bench/fixtures/corpus/`, then
as a path.

To add a fixture, add its generator to `FIXTURES` in `gen.py`, run `python3 bench/gen.py NAME`, and paste the line it
prints into `manifest.toml`.

## Build and run

```sh
make bench-doc
make bench-paths   # the path lanes, with the peers bench-doc built
make bench-typed   # the typed read's lanes
```

That builds the probe at `-o:speed` into `build/bench/doc`, builds the peers whose compiler and sources are
present (`make bench-peers` alone, with `BENCH_CC`, `BENCH_CXX` and `BENCH_CARGO` naming the compilers), names any it
left out and why, and runs `bench/doc.py`. The first Rust build downloads the crates `peers/rust/Cargo.lock` names. The probe builds each document in a 512 MiB arena whose
backing is not zeroed, so only the pages a lane touches count toward its RSS. `ROUNDS` sets the interleaved rounds
and `BENCH_FILES` the fixtures:

```sh
make bench-doc ROUNDS=3 BENCH_FILES="logs.json table.csv"
```

`python3 bench/doc.py --rounds 3 logs.json` runs it directly. Without an `ARMS` environment variable the runner
uses every arm whose binary exists. `ARMS=stury,yy` keeps a subset.

## Lanes

- `build` builds the document and stops. Its `check` is the document's node count, then each node's kind and role.
- `read` builds, then reads every value once. A JSON string goes through `json.text` and a dsv cell through
  `core.text`, and each number is read as a `core.Number`. The timed read folds each value's text length or number
  bits into one sink. One untimed read after the timed calls hashes the tags, decoded text lengths and number bits.
- `key` builds, then looks up one key in every object. The key is the first key of the first object (or the first
  header cell for a headed dsv text). A lookup answers the first member of that name and stops there, under `.First`,
  as the other libraries' lookups do.

`logs.jsonc` and `logs.json5` carry `logs.json`'s records with trailing commas, and comments in the first or JSON5
spellings (unquoted keys, single quotes, hex and `+` numbers) in the second. A `.jsonc` or `.json5` file is read as that spec, and a `.csv` or `.tsv` file as a headed dsv text; any other file
is read as JSON. Each lane prints `gb_per_s`, the median of ten timed calls after two warm-ups, and `check`, an
FNV-1a hash of what it read, from one untimed call after the timed ones. The runner refuses to time a fixture when
the arms' `check` values differ, holds `build/bench/timing.lock`, and kills a child that passes 1 GB of live RSS.
The GB/s table gives the best round of each arm's median; the RSS MiB table gives the median across rounds of each
child's kernel-tracked peak RSS, from `wait4`.

The peers run only on plain `.json`. Any other fixture is timed for `stury` alone.

## Path lanes

`bench/paths` answers paths over `wide.json`, `twitter.json` and `logs.json`: one root key early, in the middle, late and
absent, and five path sets on `logs.json`. `paths.py` prints ns, the best round of each arm's median, and GB/s of the
whole text only for the arms that judge the whole text. A lane that stops at the answer leaves bytes unread, so its table
shows ns alone. A sample of a one-key lane is `GET_BATCH` (100) calls, each releasing its result inside the clock, and
the ns is per call, for stury, sonic-rs and simdjson alike: one call of the early key takes a few of the clock's 41.7 ns
ticks on the M5 Max. A `logs.json` lane takes one call a sample. `paths scan|stop|query|build_query PATHS FILE [BATCH]`
sets the batch of the stury probe.

## Typed lanes

`bench/typed` reads `logs.json`, `twitter.json`, `citm_catalog.json`, `table.csv` and `text.csv` into their own struct
types, in an arena, with strings borrowed and with strings copied. `bench/typed.py` prints each lane's median GB/s, the
best of `ROUNDS` rounds, each string mode a program of its own, beside serde_json's and sonic-rs's derived readers into
the same structs on the JSON lanes (`peers/rust/src/bin/typed.rs`). Every arm prints a fold of the value it read, and
the runner times nothing until the folds agree. `make bench-typed LANES="logs table"` runs the lanes named.

## Schema lane

```sh
make bench-schema ROUNDS=1
make diff-schema
```

`bench/schema.py` judges the instances of 19 schemas on one thread: 15 from sourcemeta-research/jsonschema-benchmark
(geojson, openapi, draft-04, cmake-presets, ui5-manifest, helm-chart-lock, cspell, deno, code-climate, pulumi, aws-cdk,
ansible-meta, clang-format, babelrc, krakend) and four from `gen.py` (logs, twitter and citm with a schema inferred from
the data and closed, and applicator, tagged events under `oneOf`, `if`/`then` and `unevaluatedProperties`). The schema is
the benchmark's `schema-noformat.json`, so no arm asserts a format. Each arm parses every instance of the text with its
own parser, judges it and drops it, in two forms:

| Form | stury | Blaze | jsonschema-rs | boon |
|---|---|---|---|---|
| `verdict` | `json.validate` for now | FastValidation | `is_valid` | `validate().is_ok()` |
| `errors` | `json.validate` for now | Exhaustive and `SimpleOutput` | `iter_errors` | `basic_output` leaves |

It prints, per form, GB/s of the instance text, µs per call and instructions per call. Instructions per call are the
difference between two counted runs of different pass counts (`BENCH_PASSES`), over the instances in the extra passes.
The arms that judge a schema must give the same verdict on every instance before a fixture is timed (each driver
writes a 0 or 1 per instance to the path in `BENCH_VERDICTS`). The peers' drivers are `peers/blaze/main.cc` (cmake) and
`peers/rust-schema/src/main.rs` (a package of its own, so the crates parse with serde_json's default features), with
jsonschema 0.60.2 and boon 0.6.1 pinned in `peers/rust-schema/Cargo.toml`. `schema_oracle.py` runs the same instances
through the pinned Python `jsonschema` package and compares each instance's verdict; `make diff-schema ORACLE_ARGS=--suite`
also holds the package to the vendored JSON-Schema-Test-Suite (`json/test/conformance/`).

## Record lanes

```sh
make bench-records ROUNDS=3
```

`bench/records` reads the records of `logs.ndjson`, `docs.ndjson`, `twitter.ndjson`, `table.csv`, `text.csv` and
`wide.csv` by lane: `frame` (record boundaries), `check`, `build` (a document per record), `stream` (through a 64 KiB
window), `read` and `rows`/`text` (into a struct), `write` (a list of structs written as records, counting the bytes
written), `threads`, `validate` and `each` (on a pool of 6 threads) and `cells`. `bench/records.py` takes the fixtures to run
as arguments and times the lanes beside the
peers' record readers, each doing the same job the fastest way that library gives:

| Arm | Job |
|---|---|
| `simd` | simdjson `parse_many` over the NDJSON text: every document judged and a tape built |
| `simd_od` | simdjson On-Demand `iterate_many`, each document skipped: the structure is judged, not the escapes or number syntax |
| `serde_validate`, `serde_value` | serde_json `StreamDeserializer` to `IgnoredAny`, to a `Value` |
| `sonic_validate`, `sonic_value` | sonic-rs `StreamDeserializer` to `IgnoredAny`, to a `Value` |
| `csv_frame` | simd-csv `Splitter`, each record's bytes after the header and no cells |

simdjson runs stage 1 of the following batch in a thread of its own unless its parser's `threaded` is cleared, so `simd` and
`simd_od` have an `_nt` arm with threading off. sonic-rs's stream ends with an end-of-input error, which the driver
counts as the end. Every arm prints the number of records it passed, and `records.py` times nothing until they agree.

## Write lanes

`bench/write.py` times the other libraries' writers and stury's. Run from the repository root:

```sh
make bench-write                       # every lane
make bench-write LANES="doc" ROUNDS=3  # the lanes named, three rounds
```

It builds the peers as `bench-doc` does, builds stury's probe from `bench/write/`, and runs the lanes. The rounds interleave the arms, and each cell is the best round of an arm's median of ten calls after
two warm-ups. The runner holds `build/bench/timing.lock` and caps each child at 1 GB of live RSS.

| lane | job | fixtures | GB/s counts |
|---|---|---|---|
| `typed` | a struct value to compact text | `logs`, `twitter`, `citm_catalog`, `canada`, `nested`, `wide` | the output's bytes |
| `typed_pretty` | the same, two-space pretty | the same | the output's bytes |
| `doc` | a parsed document to compact text | `logs`, `twitter`, `citm_catalog`, `canada`, `pretty`, `utf8`, `escape`, `longtext` | the source's bytes |
| `doc_pretty` | the same, two-space pretty | the same | the source's bytes |

Reading the fixture into the value, or into the document, is outside the clock. Each call's text and document are
freed outside it too.

### Arms

Each arm does the job the way its library does it fastest, and writes to a buffer that the arm sized once or that the
library allocates once.

| arm | typed | document |
|---|---|---|
| `yy` (yyjson 0.13) | builds a mutable document from C structs with borrowed strings, then `yyjson_mut_write_buf`. The build is inside the clock, since yyjson writes no struct without a document. | `yyjson_write_buf` of the read document, `YYJSON_WRITE_PRETTY_TWO_SPACES` for pretty |
| `simd` (simdjson) | none: its typed writer needs C++26 reflection | `simdjson::to_string` of a DOM element, compact only. The parser keeps numbers as text, as `bench-doc`'s does, so `escape.json` parses. |
| `simd_min` | none | `simdjson::minify` of the source text. It reads no values and is not checked against the others. |
| `sonic` (sonic-rs) | `sonic_rs::to_writer` and `to_writer_pretty` of a serde struct | the same, of a `sonic_rs::Value`, which keeps string and number text as read |
| `serde` (serde_json) | `serde_json::to_writer` and `to_writer_pretty` of the same struct | the same, of a `serde_json::Value` with `preserve_order` |
| `stury` | `bench/write/` | `bench/write/` |

The Rust structs in `peers/rust/src/bin/write.rs` and the C structs in `peers/yy_bench.c` carry the same fields, in
the same order, so the typed arms write the same text. `twitter` and `citm_catalog` keep a subset of the source's
fields, so their output is smaller than the source. A JSON object of any keys (`citm_catalog`'s maps, `wide`) is a map whose keys every arm sorts inside the timed
write. `serde_json` reads its numbers with `float_roundtrip`, so every arm writes the same
doubles.

An arm that has no writer for a lane is left out of that lane and shows `-`.

### Agreement

Arms that write the same job must write the same text. Each prints `check=`, an FNV-1a hash of its output, and the
runner stops when they differ. `nested.json` and `escape.json` are the exceptions, since each library spells an
exponent, an escape or a very large integer its own way, and the runner times them without the check.

### Stury's arm

The probe is `bench/write/`, an Odin package built to `build/bench/write`. The runner calls it as `write MODE FILE
[pretty]`, with MODE `typed` or `doc`. It prints one line of `gb_per_s=`, `ns=`, `out=` and `check=`, with the
timing protocol of the other arms and `check` the FNV-1a hash of the output text. `typed` reads the fixture into the
types of the file named, as the Rust and C arms do. The probe has more modes (`string`, `format`, `dsv`, `dsvdoc`,
`records`) that `write.py` does not run.

## Kernel lanes

```sh
make bench ROUNDS=3 CASES='utf8|str'
```

`bench/` itself is the kernel bench: the vector block kernels and the number text writers, in cases such as `pack`,
`str`, `utf8`, `skip` and `float_random`. `run.py` times each case over interleaved rounds, then counts instructions
and cycles per unit from the difference between R and 2R repetitions (`/usr/bin/time -l` on macOS, `perf stat` on
Linux). `make bench` runs 5 rounds (`run.py` alone, 7), `CASES` is a regex of case names, `COUNT=0` skips the counted pass and `TIER` picks
the kernel tier. Each child is killed above 512 MB of live RSS.

## Command line comparisons

```sh
make bench-cli                      # jq_compare.sh: stury against jq, jaq, gojq and yq
zsh bench/cli/csv_compare.sh        # stury against qsv, Miller and jq -R on the CSV fixtures
make bench-cli ROUNDS=3 CASES=logs  # only the cases whose name matches, three rounds
```

The scripts need zsh, hyperfine, python3 and perl, and `jq`, `jaq`, `gojq` and `yq` (`jq_compare.sh`) or `qsv`, `mlr` and
`jq` (`csv_compare.sh`) on `PATH`; one missing says so before anything is timed. Each case asks every tool the same
question on a fixture or a corpus file. Before timing, each tool's output is saved in `OUT/answers/CASE.TOOL.txt`
(`OUT` defaults to `build/bench/jq_compare` or `build/bench/csv_compare`, or the first argument), and `cli/jq_report.py`
compares it with stury's, and writes `OUT/report.md`: a row per case and tool with the median
milliseconds, the ratio to stury and whether the answer matched, then a summary per tool. `ROUNDS` (default 5)
hyperfine rounds of `RUNS` (default 2) timings each per case, each after two warm-up runs, the tool order rotating each
round, and a median is taken over all of a tool's timings, ten by default. The report names the Odin version, the CPU and the date. Case names, such as
`logs_id` or `twitter_names`, are the ones in the report and in `docs/benchmarks.md`.
