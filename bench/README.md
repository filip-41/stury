# Document lanes

`bench/doc` builds a document from a fixture, then measures one of three lanes. `doc.py` times it against
yyjson, simdjson and sonic-rs, whose drivers are in `peers/`. Run every command below from the repository root.

## Fetch and generate

```sh
make fixtures
```

`bench/fetch.py` downloads the pinned corpus (`twitter.json`, `citm_catalog.json`, `canada.json`) into
`bench/fixtures/corpus/` and the peers' sources into `build/bench/deps/`, checking each SHA-256. `bench/gen.py
--check` writes the synthetic fixtures into `bench/fixtures/` and exits non-zero when one's hash is not
`manifest.toml`'s.

## Build and run

```sh
make bench-doc
make bench-paths   # the path lanes, with the peers bench-doc built
make bench-typed   # the typed read's lanes
```

That builds the probe at `-o:speed` into `build/bench/doc`, builds the peers whose compiler and sources are
present (`make bench-peers` alone), names any it left out, and runs `bench/doc.py`. The probe builds each document in a 512 MiB arena whose
backing is not zeroed, so only the pages a lane touches count toward its RSS. `ROUNDS` sets the interleaved rounds
(default 5) and `BENCH_FILES` the fixtures (default `logs.json citm_catalog.json table.csv logs.jsonc logs.json5`):

```sh
make bench-doc ROUNDS=3 BENCH_FILES="logs.json table.csv"
```

`python3 bench/doc.py --rounds 3 logs.json` runs it directly. Without an `ARMS` environment variable the runner
uses every arm whose binary exists. `ARMS=next,yy` keeps a subset.

## Lanes

- `build` builds the document and stops. Its `check` is the document's node count, then each node's kind and role.
- `read` builds, then reads every value once. A JSON string goes through `json.text` and a dsv cell through
  `core.text`, and each number is read as a `core.Number`. The timed read folds each value's text length or number
  bits into one sink. One untimed read after the timed calls hashes the tags, decoded text lengths and number bits.
- `key` builds, then looks up one key in every object. The key is the first key of the first object (or the first
  header cell for a headed dsv text).

`logs.jsonc` and `logs.json5` carry `logs.json`'s records with trailing commas, and comments in the first or JSON5
spellings (unquoted keys, single quotes, hex and `+` numbers) in the second. A `.jsonc` or `.json5` file is read as that spec, and a `.csv` or `.tsv` file as a headed dsv text; any other file
is read as JSON. Each lane prints `gb_per_s`, the median of ten timed calls after two warm-ups, and `check`, an
FNV-1a hash of what it read, from one untimed call after the timed ones. The runner refuses to time a fixture when
the arms' `check` values differ, holds `build/bench/timing.lock`, and kills a child that passes 1 GB of live RSS.
The GB/s table gives the best round of each arm's median; the RSS MiB table gives the median across rounds of each
child's kernel-tracked peak RSS, from `wait4`.

The peers run only on plain `.json`. Any other fixture is timed for `next` alone.

## Typed lanes

`bench/typed` reads `logs.json`, `twitter.json`, `citm_catalog.json`, `table.csv` and `text.csv` into their own struct
types, in an arena, with strings borrowed and with strings copied. `bench/typed.py` prints each lane's median GB/s, the best of `ROUNDS` rounds,
each string mode a program of its own.

## Record lanes

```sh
make bench-records ROUNDS=3
```

`bench/records` reads the records of `logs.ndjson`, `docs.ndjson`, `twitter.ndjson`, `table.csv`, `text.csv` and
`wide.csv` by lane: `frame` (record boundaries), `check`, `build` (a document per record), `stream` (through a 64 KiB
window), `read` and `rows`/`text` (into a struct), `write` (a list of structs written as records, counting the bytes
written), `threads`, `validate` and `each` (on a pool of 6 threads) and `cells`. `bench/records.py` times them beside the
peers' record readers, each doing the same job the fastest way that library gives:

| Arm | Job |
|---|---|
| `simd` | simdjson `parse_many` over the NDJSON text: every document judged and a tape built |
| `simd_od` | simdjson On-Demand `iterate_many`, each document skipped: the structure is judged, not the escapes or number syntax |
| `serde_validate`, `serde_value` | serde_json `StreamDeserializer` to `IgnoredAny`, to a `Value` |
| `sonic_validate`, `sonic_value` | sonic-rs `StreamDeserializer` to `IgnoredAny`, to a `Value` |
| `csv_frame` | simd-csv `Splitter`, each record's bytes after the header and no cells |

simdjson runs stage 1 of the next batch in a thread of its own unless its parser's `threaded` is cleared, so `simd` and
`simd_od` have an `_nt` arm with threading off. sonic-rs's stream ends with an end-of-input error, which the driver
counts as the end. Every arm prints the number of records it passed, and `records.py` times nothing until they agree.

## Write lanes

`bench/write.py` times the other libraries' writers, and stury's writer once `bench/write/` exists. Run from the repository root:

```sh
make bench-write                       # every lane
make bench-write LANES="doc" ROUNDS=3  # the lanes named, three rounds
```

It builds the peers as `bench-doc` does, builds next's probe from `bench/write/` when that directory is there, and
runs the lanes. The rounds interleave the arms, and each cell is the best round of an arm's median of ten calls after
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
| `yy` (yyjson 0.13) | builds a mutable document from C structs with borrowed strings, then `yyjson_mut_write_opts`. The build is inside the clock, since yyjson writes no struct without a document. | `yyjson_write_opts` of the read document, `YYJSON_WRITE_PRETTY_TWO_SPACES` for pretty |
| `simd` (simdjson) | none: its typed writer needs C++26 reflection | `simdjson::to_string` of a DOM element, compact only. The parser keeps numbers as text, as `bench-doc`'s does, so `escape.json` parses. |
| `simd_min` | none | `simdjson::minify` of the source text. It reads no values and is not checked against the others. |
| `sonic` (sonic-rs) | `sonic_rs::to_writer` and `to_writer_pretty` of a serde struct | the same, of a `sonic_rs::Value`, which keeps string and number text as read |
| `serde` (serde_json) | `serde_json::to_writer` and `to_writer_pretty` of the same struct | the same, of a `serde_json::Value` with `preserve_order` |
| `next` | `bench/write/` | `bench/write/` |

The Rust structs in `peers/rust/src/bin/write.rs` and the C structs in `peers/yy_bench.c` carry the same fields, in
the same order, so the typed arms write the same text. `twitter` and `citm_catalog` keep a subset of the source's
fields, so their output is smaller than the source. A JSON object of any keys is a list of pairs in source order
(`citm_catalog`'s maps, `wide`). `serde_json` reads its numbers with `float_roundtrip`, so every arm writes the same
doubles.

An arm that has no writer for a lane is left out of that lane and shows `-`.

### Agreement

Arms that write the same job must write the same text. Each prints `check=`, an FNV-1a hash of its output, and the
runner stops when they differ. `nested.json` and `escape.json` are the exceptions, since each library spells an
exponent, an escape or a very large integer its own way, and the runner times them without the check.

### Where next's arm goes

next's probe is `bench/write/`, an Odin package built to `build/bench/write`. Its command line is `write MODE FILE
[pretty]`, with MODE `typed` or `doc`. It prints one line of `gb_per_s=`, `ns=`, `out=` and `check=`, with the
timing protocol of the other arms and `check` the FNV-1a hash of the output text. `typed` reads the fixture into the
types of the file named, as the Rust and C arms do. Until the package exists, `make bench-write` names `next` as left
out and `write.py` runs the peers alone.
