# Benchmarks

This page describes what the harness in [bench/](../bench/README.md) measures, how, and what each comparison does the
same for every tool, and records the figures measured on the released tree. They come from one machine, named with the
set, and `-o:speed`. Other data, filters and hardware give other numbers.

The figures were measured on the 0.1.1 tree, the `wide.json` write row on a later one. The harness has changed since
in the places this page marks, and those tables need a rerun on main. The typed, record and write figures also predate
the one sampling rule of the protocol below: stury's probes took the median of 41 calls then, two of them without
warm-ups. The command line table took fifteen timings per tool and one warm-up run, not ten and two. A figure that is
not on this page was not measured.

## What is compared

| Comparison | Jobs | Compared with | Run with |
| --- | --- | --- | --- |
| Document lanes | build a document, read every value, look up one key | yyjson, simdjson, sonic-rs | `make bench-doc` |
| Path lanes | answer one path or several without a document | the same libraries | `make bench-paths` |
| Typed read | decode into structs, strings borrowed and copied | serde_json, sonic-rs | `make bench-typed` |
| Record lanes | frame, judge, build and read the records of NDJSON and CSV | simdjson, serde_json, sonic-rs, simd-csv | `make bench-records` |
| Write lanes | write a struct or a document, compact and pretty | yyjson, simdjson, serde_json, sonic-rs | `make bench-write` |
| Kernels | the vector code and the number text writers | none | `make bench` |
| Command line | filters over JSON and CSV files, end to end | jq, jaq, gojq, yq, and qsv, Miller and jq on CSV | `bench/cli/jq_compare.sh`, `bench/cli/csv_compare.sh` |

Every comparison states what it measured and under which guarantee. The fixtures are pinned: the corpus files and the
other libraries' sources by URL and SHA-256 (`bench/fetch.py`, `bench/sources.toml`), and the synthetic files by
`bench/manifest.toml` (`bench/gen.py --check`). The synthetic files are large, compact and each stress one cost, so
they are not typical documents. The corpus files are small, pretty-printed and mixed. They can rank tools differently,
and a result says which set it comes from.

## Protocol

- Every arm is its own process. It reads the file, then times only the job, in process: two warm-up calls, then ten
  timed samples, and the median is the mean of the two middle samples. Every lane of every tool follows this rule. A
  sample is one call, except in the get-one-field lanes below. File reading, process start and output are outside the
  clock.
- A library-lane runner (`doc.py`, `paths.py`, `typed.py`, `records.py`, `write.py`) interleaves the arms round by round, and each cell is the best round of an arm's median. A command line comparison
  (`bench/cli/jq_compare.sh`, `csv_compare.sh`) runs its tools in rotating order. All of them run under `bench/guard.py`,
  which holds `build/bench/timing.lock`, so one timed job runs at a time, and kills a process that passes 1 GB of live
  RSS, a descendant of the script included.
- Every arm prints a check of what it read, a hash or, in the record lanes, the number of records, and no figure is
  reported unless the arms' checks agree. The write lanes leave `nested.json` and `escape.json` out of that check.
- Each other library is built from its pinned source with `-O3 -DNDEBUG`. The Rust arms build in release with fat LTO.
  stury builds at `-o:speed`. A library whose toolchain or sources are missing is reported as left out, never dropped
  silently.
- Memory figures are the kernel-tracked peak RSS of each child, taken from `wait4`.

## Fairness rules

Each pair does the same work under the same guarantee, or the table names the difference:

- **Strictness.** Every tool in a validate or build lane judges the whole input: UTF-8, numbers and structure. A mode
  that judges only what it reads (`.Lazy`) appears only as a separately labelled arm, never as the head.
- **Deferred work.** stury's document checks every number but converts it when it is read, and its strings are views
  into the input. The other libraries convert numbers while they parse. So the `read` lane builds and then reads every
  value once, and the `build` lane is the build alone. A table says which of the two it shows.
- **Allocation.** Every arm reuses what its API lets a caller reuse across calls, a parser or a document buffer. The
  probe builds each document in an arena whose backing is not zeroed, so only the pages a lane touches count. Every
  write arm writes into one output buffer it allocates once and reuses on every call.
- **Hand-written and generic.** simdjson and yyjson have no typed read arm. yyjson's typed write arm builds its
  document from each struct by hand. stury, serde_json and sonic-rs derive their decoders and writers from the type.
- **Each tool's fastest route.** An arm does the job the way its library does it fastest: serde_json reads the bytes
  (`from_slice`), checking UTF-8 as it reads, and a stream of records is read by each library's own stream reader. serde_json
  is built with `preserve_order` and `float_roundtrip` in every lane, so its `Value` keeps members in source order and
  every decimal reads to the nearest double, as the other arms do. A tool that
  must build a document for a job has that cost counted.
- **One key.** A get-one-field job times a batch of 100 calls per sample, each call releasing its result inside the
  clock, and reports the sample over 100, for stury, sonic-rs and simdjson alike. The clock of every arm (Odin's
  `tick_now`, `clock_gettime`, C++ `steady_clock`, Rust `Instant`) ticks every 41.7 ns on the M5 Max, and two reads
  back to back differ by 0 ticks in 71% of pairs and by 12 to 15 ns on average. One call of the early key takes 40 to
  250 ns, so a sample of one call is a few ticks. In a comparison of one call, 10 calls and 100 calls per sample, stury's
  stopped scan read 229 to 250 ns, 191 and 187 ns, and sonic-rs's `get` 62 to 83 ns, 50 and 41 ns, on the early key.
  The middle and late keys, which take 0.8 to 7 ms a call, and every arm that reads the whole text differed between the
  three schemes by less than the spread between rounds.
- **CSV.** stury judges quote misuse, unterminated quotes, ragged rows and UTF-8. A peer that checks less is named in
  the table with what it checks.
- **Command line.** Each figure is the other tool's median wall time divided by stury's, over the same filter and the
  same file, process start-up included, over ten timed runs per tool and case after two warm-up runs. stury answers a file of 1 MiB or more on every core, as it does for a user, and
  the other tools on one. In `jsonc_id` the other tools read the JSONC file through `perl`, whose start-up is timed. Every tool must give the same answers before it is timed. A tool that cannot
  spell a filter is left out of that row. A CSV arm that types the values it converts has no arm for a job that must not
  type them.

## Results

Measured on 2026-11-05 on an Apple M5 Max (18 cores), macOS 27.2, with Odin's master at `7e313bd6f` (2026-10-27) at
`-o:speed`, with `ROUNDS=5` for the library lanes. Every runner prints the Odin version, the CPU and the date it ran
with. Every peer was present. GB/s unless the table says otherwise; `-` is an arm the harness left
out or a lane it does not run.

### Document lanes (`make bench-doc`)

Build a document (`build`), then read every value once (`read`), then look up one key in every object (`key`), each
lookup stopping at the first member of that name as every library's does. The key figures were measured while stury's
lookup took the last member of a name, which reads the whole object, and need a rerun. On `table.csv` the key is the
column, found once, and each record reads its cell by index. The corpus file is
`citm_catalog.json`; `twitter.json` is in the corpus and not in the default lane set.

| Build | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 4.11 | 2.92 | 3.04 | 3.20 |
| citm_catalog.json | 7.55 | 5.20 | 5.90 | 3.70 |
| table.csv | 4.11 | - | - | - |
| logs.jsonc | 3.72 | - | - | - |
| logs.json5 | 2.11 | - | - | - |

| Read every value | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 3.33 | 2.47 | 2.61 | 1.89 |
| citm_catalog.json | 5.87 | 4.45 | 4.68 | 2.55 |
| table.csv | 2.76 | - | - | - |
| logs.jsonc | 2.94 | - | - | - |
| logs.json5 | 1.80 | - | - | - |

| Look up one key | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 3.38 | 2.34 | 2.34 | 1.93 |
| citm_catalog.json | 6.04 | 4.13 | 4.44 | 2.53 |
| table.csv | 3.38 | - | - | - |
| logs.jsonc | 3.02 | - | - | - |
| logs.json5 | 1.88 | - | - | - |

Peak resident MiB of the build lane; the read and key lanes hold the same document and stay within 0.1 MiB.

| Fixture | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 20.1 | 27.6 | 37.1 | 29.1 |
| citm_catalog.json | 5.1 | 7.0 | 7.0 | 6.7 |
| table.csv | 55.5 | - | - | - |
| logs.jsonc | 20.3 | - | - | - |
| logs.json5 | 19.8 | - | - | - |

stury is ahead on both JSON fixtures in all three lanes, and holds less memory than every peer.

### Path lanes (`make bench-paths`)

Each table holds the arms that read the same amount of the text. `scan` reads a path over the text and judges every
byte; `build_query` builds the document inside the clock, judging every byte, and then queries it, as the other
libraries answer from the text; `simd` is simdjson's On-Demand `find_field`, whose stage 1 indexes the whole text and
checks its UTF-8, and which skips values without judging their numbers and escapes. `stop` reads under `.First` with
`stop_early`, judging every byte up to the answer and leaving the rest unread; `sonic` is sonic-rs's keyed `get` from
the text on every call, which stops at the key and skips values without judging them. On `logs.json`, `query` walks a
document its driver built outside the clock. ns, best of five rounds. `paths.py` prints GB/s of the whole text beside
the ns of the arms that judge it all; a lane that stops early leaves bytes unread, so its table shows ns alone.
`build_query` is not in this set: the arm and the GB/s column came after it, and the get lanes' batching changed how every
ns is taken, so the tables need a rerun.

The whole text read:

| Lane | scan | simd |
| --- | ---: | ---: |
| get early | 1,632,347 | 1,048,526 |
| get middle | 1,631,172 | 1,343,599 |
| get late | 1,712,769 | 1,694,057 |
| get absent | 1,629,968 | 1,612,051 |
| get last root key | 111,895 | 85,583 |

The text read up to the answer:

| Lane | stop | sonic |
| --- | ---: | ---: |
| get early | 166 | 42 |
| get middle | 824,897 | 2,545,866 |
| get late | 1,646,573 | 5,101,952 |
| get absent | 1,637,157 | 6,703,395 |
| get last root key | 111,000 | 298,067 |

`logs.json`, the whole text judged by `scan` and a document built outside the clock walked by `query`:

| Lane | scan | query |
| --- | ---: | ---: |
| .logs[].id | 2,338,895 | 1,083,753 |
| .logs[][] | 3,884,188 | 2,286,429 |
| .logs[-1] | 2,027,819 | 309,020 |
| .logs[-20] | 2,031,748 | 304,583 |
| five keys per record | 7,333,404 | 5,781,709 |

simdjson's `find_field` is ahead of the scan on every row of the first table, judging less: no number or escape is
checked. The scan pays for judging the whole text, `stop` only up to the answer, which is why the early root key costs
166 ns, a middle one about half the text, and a late or absent one the whole text. sonic-rs's 42 ns is its `get` stopping at the first key,
as `stop` does; its late and absent keys cost 5.1 and 6.7 ms, and stury's stopped scan beats it there.
`query` is the route of a document already built: a negative index or `.logs[].id` costs a fraction of the scan.

### Typed read (`make bench-typed`)

Decode into structs, strings borrowed or copied. serde_json and sonic-rs read the JSON fixtures into the same structs
with derived decoders: a copied string is a `String`, and a borrowed one a `Cow` borrowed from the input when it has no
escape, as stury borrows it. stury reads on an arena and the Rust arms on the global allocator. Every arm's fold of the
value it read must agree before a lane is timed. yyjson and simdjson have no typed read in the harness. The figures
below are stury's alone: the serde_json and sonic-rs arms came after this run, and the lane needs a rerun.

| Fixture | borrow | copy |
| --- | ---: | ---: |
| logs.json | 4.16 | 2.47 |
| twitter.json | 4.29 | 4.15 |
| citm_catalog.json | 7.65 | 7.57 |
| table.csv | 1.53 | 1.33 |
| text.csv | 1.87 | 1.04 |

### Record lanes (`make bench-records`)

NDJSON and CSV records, single-threaded and on six threads, beside each library's stream reader. The lanes are `frame`
(boundaries), `check` (judge), `threads` (judge on six threads) and `build` (a document per record); the framing table's
simd-csv column is `csv_frame`. `simd_od` is
simdjson's On-Demand `iterate_many`, which skips each document and judges its structure but not its escapes or
number syntax; `simd` is its tape, and `serde_validate` and `sonic_validate` read to `IgnoredAny`.

Judging the records on one thread:

| check | stury | simd_nt | simd_od_nt | serde_validate | sonic_validate |
| --- | ---: | ---: | ---: | ---: | ---: |
| logs.ndjson | 4.39 | 3.15 | 5.51 | 1.49 | 0.98 |
| docs.ndjson | 0.86 | 0.90 | 2.27 | 0.66 | 0.56 |
| twitter.ndjson | 4.59 | 4.20 | 5.71 | 2.08 | 1.28 |

Judging the records threaded: stury on six threads, `simd` and `simd_od` with stage 1 in a thread of its own:

| check | stury 6 threads | simd | simd_od |
| --- | ---: | ---: | ---: |
| logs.ndjson | 24.56 | 4.80 | 7.20 |
| docs.ndjson | 4.92 | 1.13 | 3.45 |
| twitter.ndjson | 24.38 | 7.04 | 7.39 |

One document per record, built:

| Fixture | stury | serde_value | sonic_value |
| --- | ---: | ---: | ---: |
| logs.ndjson | 1.51 | 0.34 | 0.77 |
| docs.ndjson | 0.71 | 0.20 | 0.43 |
| twitter.ndjson | 3.68 | 0.48 | 1.34 |

Framing CSV records:

| Fixture | stury | simd-csv |
| --- | ---: | ---: |
| table.csv | 9.99 | 5.74 |
| text.csv | 5.40 | 2.81 |

Threaded, stury leads every arm. On one thread stury is ahead of simdjson's tape on `logs.ndjson` and
`twitter.ndjson` and behind it on `docs.ndjson`, and simdjson's On-Demand skip is ahead on all three while judging less;
stury leads serde_json and sonic-rs on validation and on building a document per record.

### Write lanes (`make bench-write`)

These rows predate two harness changes, the peers sorting `citm_catalog.json`'s maps and every arm reusing one
output buffer, and need a rerun. Write a typed value (`typed`) or a document (`doc`), compact and pretty (`typed_pretty`, `doc_pretty`). `simd_min` is simdjson's minifier, which does not judge the
document; the other arms write a value they hold. stury's document write copies each number's source spelling, and
the other libraries format the double their DOM holds. stury writes a struct's whole float with no fraction, as jq
does, and the others write `1.0`. On `logs.json` and `canada.json` the texts differ by those spellings alone, so the
harness checks the other libraries' texts against each other there and leaves stury's out of that check.

| Typed, compact | stury | yyjson | sonic-rs | serde_json |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 7.11 | 2.62 | 3.11 | 1.87 |
| twitter.json | 6.68 | 2.74 | 5.02 | 2.16 |
| citm_catalog.json | 3.98 | 2.94 | 3.31 | 1.77 |
| canada.json | 2.10 | 1.28 | 1.83 | 1.84 |
| nested.json | 2.95 | 1.53 | 1.16 | 1.11 |
| wide.json | 0.20 | 0.15 | 0.23 | 0.22 |

| Document, compact | stury | yyjson | simdjson | simdjson minify | sonic-rs | serde_json |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| logs.json | 28.07 | 4.76 | 1.69 | 14.32 | 2.32 | 1.53 |
| twitter.json | 22.49 | 9.73 | 2.50 | 15.18 | 4.53 | 2.87 |
| citm_catalog.json | 29.59 | 17.86 | 4.55 | 15.08 | 5.86 | 6.45 |
| canada.json | 41.95 | 1.94 | 1.20 | 14.14 | 1.57 | 1.67 |
| pretty.json | 16.03 | 7.60 | 1.89 | 14.94 | 2.03 | 1.94 |
| utf8.json | 45.29 | 0.83 | 0.86 | 14.38 | 22.48 | 3.73 |
| escape.json | 42.84 | 1.67 | 0.99 | 14.42 | 0.92 | 1.11 |
| longtext.json | 44.97 | 4.52 | 0.86 | 14.35 | 22.62 | 3.80 |

The pretty lanes keep the same order. A map value's keys are written sorted, and every arm sorts them inside the
timed write: `citm_catalog.json`'s five maps and `wide.json`, a 342,658-key map. The `wide.json` row compares map
writes; stury is about 13% behind sonic-rs and 9% behind serde_json, and ahead of yyjson.

### Command line (`make bench-cli`)

23 filters over `logs.json`, `logs.ndjson`, `documents.json`, a JSONC copy of `logs.json` and the corpus, process
start-up included, each tool's median wall time divided by stury's. `yq` has no arm in 13 of them. No case gave a different answer.

| tool | cases | geomean × stury | min × stury | answer differs |
| --- | ---: | ---: | ---: | ---: |
| jq | 23 | 16.13 | 4.52 | 0 |
| jaq | 23 | 8.42 | 2.21 | 0 |
| gojq | 23 | 12.38 | 3.61 | 0 |
| yq | 10 | 69.23 | 7.61 | 0 |

The closest cases to jaq are `twitter_names` (2.21×), `twitter_select` (2.22×) and `validate_twitter` (2.32×).
`twitter.json` is the smallest input in the set, so process start-up is the largest share of its wall time. Those
three are below the 5× jaq floor this tree aims for and are open; every case is at least 4.52× jq.

## Running

```sh
make fixtures      # fetch the pinned corpus and sources, generate the synthetic files
make bench-doc     # the document lanes
make bench-records ROUNDS=3
```

`ROUNDS` sets the interleaved rounds, `BENCH_FILES` the document lanes' fixtures and `LANES` the typed and write lanes
(`bench/README.md` lists what each target takes). The harness needs Odin, a C and a C++ compiler,
Cargo and Python 3.11 or later; the command line comparisons also need hyperfine and the tools they compare. A
comparison whose tool is missing says so and stops before it times anything.

## Reading a result

A table says which jobs it compares, the input, the unit (GB/s, ns per call, MiB or a ratio to stury's time), and where stury
trails. Where stury loses a lane, the page says so beside the number.
