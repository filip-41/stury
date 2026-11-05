# Benchmarks

This page describes what the harness in [bench/](../bench/README.md) measures, how, and what each comparison does the
same for every tool, and records the figures measured on the 0.1.0 tree. They come from one machine, named with the
set, and `-o:speed`. Other data, filters and hardware give other numbers.

A figure that is not on this page was not measured on the current tree.

## What is compared

| Comparison | Jobs | Compared with | Run with |
| --- | --- | --- | --- |
| Document lanes | build a document, read every value, look up one key | yyjson, simdjson, sonic-rs | `make bench-doc` |
| Path lanes | answer one path or several without a document | the same libraries | `make bench-paths` |
| Typed read | decode into structs, strings borrowed and copied | stury alone; the peer typed arms are not in the harness yet | `make bench-typed` |
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

- Every arm is its own process. It reads the file, then times only the job, in process: two warm-up calls, then the
  median of ten. File reading, process start and output are outside the clock.
- A runner interleaves the arms round by round, and each cell is the best round of an arm's median. It holds
  `build/bench/timing.lock`, so one timed job runs at a time, and it kills a child that passes 1 GB of live RSS.
- Every arm prints a hash of what it read, and the runner times nothing until the arms' hashes agree.
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
  probe builds each document in an arena whose backing is not zeroed, so only the pages a lane touches count.
- **Hand-written and generic.** simdjson and yyjson have no typed decode, so their typed arms are readers written by
  hand for each struct, labelled as such. stury, serde_json and sonic-rs derive their decoders from the type.
- **Each tool's fastest route.** An arm does the job the way its library does it fastest: serde_json reads a `&str`
  after a UTF-8 check inside the clock, and a stream of records is read by each library's own stream reader. A tool that
  must build a document for a job has that cost counted.
- **One key.** A get-one-field job times a batch of calls per sample, so each sample is well above the timer's
  resolution.
- **CSV.** stury judges quote misuse, unterminated quotes, ragged rows and UTF-8. A peer that checks less is named in
  the table with what it checks.
- **Command line.** Each figure is the other tool's median wall time divided by stury's, over the same filter and the
  same file, process start-up included. Every tool must give the same answers before it is timed. A tool that cannot
  spell a filter is left out of that row. A CSV arm that types the values it converts has no arm for a job that must not
  type them.

## Results

Measured on 2026-11-05 on an Apple M5 Max (18 cores), macOS 27.2, with Odin `dev-2026-11` (the `Odin-master`
checkout of 2026-10-27; the `dev-2026-10` release does not build the tree) at `-o:speed`, with `ROUNDS=5` for the
library lanes. Every peer was present. GB/s unless the table says otherwise; `-` is an arm the harness left out or a
lane it does not run.

### Document lanes (`make bench-doc`)

Build a document, then read every value once, then look up one key in every object. The corpus file is
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

stury is ahead on both corpus files in all three lanes, and holds less memory than every peer.

### Path lanes (`make bench-paths`)

`scan` reads a path over the text and judges every byte; `stop` reads under `.First` with `stop_early` and leaves the
rest unread; `query` walks a document its driver built outside the clock. `sonic` is sonic-rs's keyed `get` on a
value its driver built outside the clock, not a path walk; `simd` is simdjson's On-Demand `find_field`, parsed on
demand. ns, best of five rounds; a lane that stops early leaves bytes unread, so its ns is what counts.

| Lane | scan | stop | query | sonic | simd |
| --- | ---: | ---: | ---: | ---: | ---: |
| get early | 1,632,347 | 166 | 865,476 | 42 | 1,048,526 |
| get middle | 1,631,172 | 824,897 | 963,037 | 2,545,866 | 1,343,599 |
| get late | 1,712,769 | 1,646,573 | 920,169 | 5,101,952 | 1,694,057 |
| get absent | 1,629,968 | 1,637,157 | 950,477 | 6,703,395 | 1,612,051 |
| get last root key | 111,895 | 111,000 | 83 | 298,067 | 85,583 |
| .logs[].id | 2,338,895 | - | 1,083,753 | - | - |
| .logs[][] | 3,884,188 | - | 2,286,429 | - | - |
| .logs[-1] | 2,027,819 | - | 309,020 | - | - |
| .logs[-20] | 2,031,748 | - | 304,583 | - | - |
| five keys per record | 7,333,404 | - | 5,781,709 | - | - |

The scan pays for judging the whole text; `stop` pays only up to the answer, which is why the early root key costs
166 ns and a middle or absent one costs the whole text. sonic-rs's 42 ns is a lookup in a value it already built,
so it is not a path read; its late and absent keys cost 5.1 and 6.7 ms, and stury's stopped scan beats it there.
`query` is the built-document route: a root key costs 0.9 ms of node walk, and a negative index or `.logs[].id`
costs a fraction of the scan.

### Typed read (`make bench-typed`)

Decode into structs, strings borrowed or copied. The peer typed arms are not in the harness yet, so this set is
stury alone; it is the one comparison above that has no cross-tool figure.

| Fixture | borrow | copy |
| --- | ---: | ---: |
| logs.json | 4.16 | 2.47 |
| twitter.json | 4.29 | 4.15 |
| citm_catalog.json | 7.65 | 7.57 |
| table.csv | 1.53 | 1.33 |
| text.csv | 1.87 | 1.04 |

### Record lanes (`make bench-records`)

NDJSON and CSV records, single-threaded and on six threads, beside each library's stream reader. `simd_od` is
simdjson's On-Demand `iterate_many`, which skips each document and judges its structure but not its escapes or
number syntax; `simd` is its tape, and `serde_validate` and `sonic_validate` read to `IgnoredAny`.

| check | stury | stury 6 threads | simd | simd_nt | simd_od | simd_od_nt | serde_validate | sonic_validate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| logs.ndjson | 4.39 | 24.56 | 4.80 | 3.15 | 7.20 | 5.51 | 1.49 | 0.98 |
| docs.ndjson | 0.86 | 4.92 | 1.13 | 0.90 | 3.45 | 2.27 | 0.66 | 0.56 |
| twitter.ndjson | 4.59 | 24.38 | 7.04 | 4.20 | 7.39 | 5.71 | 2.08 | 1.28 |

One document per record, built and read:

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

On six threads stury leads every arm. Single-threaded, simdjson's tape is ahead on all three files, and its
On-Demand skip is ahead further while judging less; stury still leads serde_json and sonic-rs on validation and on
building a document per record.

### Write lanes (`make bench-write`)

Write a typed value or a document, compact and pretty. `simd_min` is simdjson's minifier, which does not judge the
document; the other arms write a value they hold.

| Typed, compact | stury | yyjson | sonic-rs | serde_json |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 7.11 | 2.62 | 3.11 | 1.87 |
| twitter.json | 6.68 | 2.74 | 5.02 | 2.16 |
| citm_catalog.json | 3.98 | 2.94 | 3.31 | 1.77 |
| canada.json | 2.10 | 1.28 | 1.83 | 1.84 |
| nested.json | 2.95 | 1.53 | 1.16 | 1.11 |
| wide.json | 0.18 | 2.89 | 2.53 | 2.06 |

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

The pretty lanes keep the same order. `wide.json` is the exception in the typed lanes: stury writes it at 0.18 GB/s
where yyjson writes it at 2.89, the one large loss in this set, and it is open. It is a wide object, and stury's
typed writer is the slowest on it while it is the fastest on every other typed file.

### Command line (`make bench-cli`)

23 filters over the corpus and `logs.json`, process start-up included, each tool's median wall time divided by
stury's. `yq` cannot spell 13 of them and is left out of those rows. No case gave a different answer.

| Tool | Cases | Geomean × stury | Closest × stury | Answers differ |
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

`ROUNDS` sets the interleaved rounds and `BENCH_FILES` the fixtures. The harness needs Odin, a C and a C++ compiler,
Cargo and Python 3.11 or later; the command line comparisons also need hyperfine and the tools they compare. A
comparison whose tool is missing says so and stops before it times anything.

## Reading a result

A table says which jobs it compares, the input, the unit (milliseconds, GB/s or microseconds per call), and where stury
trails. Where stury loses a lane, the page says so beside the number.
