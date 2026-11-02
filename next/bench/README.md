# Document lanes

`next/bench/doc` builds a document from a fixture, then measures one of three lanes. `doc.py` times it against
yyjson, simdjson and sonic-rs, whose drivers are in `peers/`. Run every command below from `next/`.

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
```

That builds the probe at `-o:speed` into `build/bench/doc`, builds the peers whose compiler and sources are
present, names any it left out, and runs `bench/doc.py`. The probe builds each document in a 512 MiB arena whose
backing is not zeroed, so only the pages a lane touches count toward its RSS. `ROUNDS` sets the interleaved rounds
(default 5) and `BENCH_FILES` the fixtures (default `logs.json citm_catalog.json table.csv`):

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

A `.jsonc` or `.json5` file is read as that spec, and a `.csv` or `.tsv` file as a headed dsv text; any other file
is read as JSON. Each lane prints `gb_per_s`, the median of ten timed calls after two warm-ups, and `check`, an
FNV-1a hash of what it read, from one untimed call after the timed ones. The runner refuses to time a fixture when
the arms' `check` values differ, holds `build/bench/timing.lock`, and kills a child that passes 1 GB of live RSS.
The GB/s table gives the best round of each arm's median; the RSS MiB table gives the median across rounds of each
child's kernel-tracked peak RSS, from `wait4`.

The peers run only on plain `.json`. Any other fixture is timed for `next` alone.
