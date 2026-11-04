# Benchmarks

This page describes what the harness in [bench/](../bench/README.md) measures, how, and what each comparison does the
same for every tool. The figures under [Figures](#figures) were measured on branch `redesign` at 762c667 on
2026-11-04, on an Apple M5 Max (18 cores), macOS 27.2, with Odin `dev-2026-10` from `Odin-master` (2026-10-27) and
`-o:speed`. The document, path and typed lanes ran at `ROUNDS=5`, the record and write lanes at `ROUNDS=3`, and the
command line with hyperfine's defaults. Other data, filters and hardware give other numbers.

A figure that is not on this page was not measured on the current tree.

## What is compared

| Comparison | Jobs | Compared with | Run with |
| --- | --- | --- | --- |
| Document lanes | build a document, read every value, look up one key | yyjson, simdjson, sonic-rs | `make bench-doc` |
| Path lanes | answer one path or several without a document | the same libraries | `make bench-paths` |
| Typed read | decode into structs, strings borrowed and copied | stury alone; the harness has no peer arm for this lane yet | `make bench-typed` |
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

## Running

```sh
make fixtures      # fetch the pinned corpus and sources, generate the synthetic files
make bench-doc     # the document lanes
make bench-records ROUNDS=3
```

`ROUNDS` sets the interleaved rounds and `BENCH_FILES` the fixtures. The harness needs Odin, a C and a C++ compiler,
Cargo and Python 3.11 or later; the command line comparisons also need hyperfine and the tools they compare. A
comparison whose tool is missing says so and stops before it times anything.

## Figures

Document lanes, GB/s, the best round of each arm's median. The peers read plain JSON only.

| File | Lane | stury | yyjson | simdjson | sonic-rs |
| --- | --- | ---: | ---: | ---: | ---: |
| `logs.json` | build | 4.03 | 2.90 | 2.91 | 3.16 |
| `logs.json` | read | 3.25 | 2.45 | 2.39 | 1.89 |
| `logs.json` | key | 3.32 | 2.29 | 2.27 | 1.87 |
| `citm_catalog.json` | build | 7.35 | 5.12 | 5.98 | 3.51 |
| `citm_catalog.json` | read | 5.81 | 4.42 | 4.54 | 2.52 |
| `citm_catalog.json` | key | 6.01 | 3.99 | 4.34 | 2.38 |
| `table.csv` | build, read, key | 4.01, 2.70, 3.25 | — | — | — |
| `logs.jsonc` | build, read, key | 3.60, 2.88, 2.95 | — | — | — |
| `logs.json5` | build, read, key | 2.09, 1.77, 1.85 | — | — | — |

Peak RSS, MiB, the median of the rounds' kernel maxima:

| File | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| `logs.json` | 20.1 | 27.6 | 37.1 | 29.1 |
| `citm_catalog.json` | 5.1 | 7.0 | 7.0 | 6.7 |
| `table.csv` | 55.5 | — | — | — |

Path lanes, ns per call, the best round of each arm's median. `stop` is stury's scan that stops at the value;
`query` builds a document once outside the clock and times the lookup.

| Lane | stury scan | stury stop | stury query | sonic-rs | simdjson |
| --- | ---: | ---: | ---: | ---: | ---: |
| get early | 1,747,995 | 166 | 917,994 | 42 | 1,070,306 |
| get middle | 1,712,384 | 862,309 | 927,915 | 2,604,598 | 1,403,367 |
| get late | 1,738,468 | 1,729,115 | 961,084 | 5,240,273 | 1,756,818 |
| get absent | 1,746,285 | 1,806,298 | 937,287 | 7,052,231 | 1,786,906 |
| get last root key | 119,041 | 115,791 | 83 | 299,893 | 91,875 |
| `.logs[].id` | 2,419,370 | — | 1,276,447 | — | — |
| `.logs[][]` | 4,301,005 | — | 2,425,877 | — | — |
| `.logs[-1]` | 2,071,996 | — | 366,584 | — | — |
| `.logs[-20]` | 2,063,585 | — | 332,062 | — | — |
| five keys per record | 8,063,713 | — | 6,122,231 | — | — |

Record lanes, GB/s. `simd` runs simdjson's stage 1 in a thread of its own, `simd_nt` on the caller's. stury's threads
lane uses six threads.

| NDJSON check | stury | stury threads | simdjson | simd_nt | simd On-Demand | od_nt | serde_json | sonic-rs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `logs.ndjson` | 4.31 | 23.94 | 4.69 | 2.87 | 6.47 | 4.72 | 1.47 | 0.96 |
| `docs.ndjson` | 0.82 | 4.55 | 1.08 | 0.87 | 3.34 | 2.15 | 0.64 | 0.54 |
| `twitter.ndjson` | 4.35 | 21.80 | 6.40 | 3.88 | 6.87 | 5.53 | 2.00 | 1.23 |

A document per record, GB/s:

| File | stury | serde_json | sonic-rs |
| --- | ---: | ---: | ---: |
| `logs.ndjson` | 1.49 | 0.33 | 0.74 |
| `docs.ndjson` | 0.66 | 0.18 | 0.41 |
| `twitter.ndjson` | 3.49 | 0.44 | 1.27 |

Frame, CSV, GB/s:

| File | stury | simd-csv |
| --- | ---: | ---: |
| `table.csv` | 9.46 | 5.46 |
| `text.csv` | 5.23 | 2.75 |

Write lanes, GB/s. `simd_min` is simdjson's minified write.

Typed write:

| File | stury | yyjson | sonic-rs | serde_json |
| --- | ---: | ---: | ---: | ---: |
| `logs.json` | 6.71 | 2.54 | 2.99 | 1.83 |
| `twitter.json` | 6.56 | 2.74 | 4.99 | 2.18 |
| `citm_catalog.json` | 3.96 | 3.06 | 3.03 | 2.10 |
| `canada.json` | 2.04 | 1.26 | 1.76 | 1.76 |
| `nested.json` | 2.75 | 1.49 | 1.13 | 1.08 |
| `wide.json` | 0.13 | 2.73 | 2.47 | 2.02 |

Typed write, pretty:

| File | stury | yyjson | sonic-rs | serde_json |
| --- | ---: | ---: | ---: | ---: |
| `logs.json` | 7.15 | 3.00 | 2.71 | 1.75 |
| `twitter.json` | 7.19 | 2.98 | 3.54 | 1.97 |
| `citm_catalog.json` | 5.43 | 4.05 | 2.17 | 1.81 |
| `canada.json` | 4.20 | 2.64 | 1.61 | 1.70 |
| `nested.json` | 3.85 | 2.26 | 1.30 | 1.22 |
| `wide.json` | 0.15 | 3.02 | 2.45 | 2.34 |

Document write, compact:

| File | stury | yyjson | simdjson | `simd_min` | sonic-rs | serde_json |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `logs.json` | 26.45 | 4.68 | 1.46 | 14.15 | 2.21 | 1.23 |
| `twitter.json` | 22.29 | 9.37 | 2.26 | 14.94 | 4.56 | 2.74 |
| `citm_catalog.json` | 28.33 | 17.63 | 4.73 | 15.02 | 6.10 | 6.12 |
| `canada.json` | 40.62 | 1.91 | 1.17 | 14.12 | 1.51 | 1.53 |
| `pretty.json` | 15.67 | 7.06 | 1.76 | 15.04 | 1.96 | 1.61 |
| `utf8.json` | 35.60 | 0.80 | 0.82 | 14.20 | 21.56 | 3.64 |
| `escape.json` | 35.96 | 1.63 | 0.96 | 13.99 | 0.89 | 1.05 |
| `longtext.json` | 33.75 | 4.18 | 0.82 | 14.16 | 21.40 | 3.66 |

Typed read, GB/s. The harness has no peer arms for this lane yet, so these are stury alone:

| File | strings borrowed | strings copied |
| --- | ---: | ---: |
| `logs.json` | 4.11 | 2.43 |
| `twitter.json` | 4.16 | 3.98 |
| `citm_catalog.json` | 7.58 | 7.29 |
| `table.csv` | 1.50 | 1.31 |
| `text.csv` | 1.84 | 1.01 |

Command line, the other tool's median wall time divided by stury's over the same filter and file, process start
included:

| Tool | Cases | Geomean | Narrowest | Answers differ |
| --- | ---: | ---: | ---: | ---: |
| jaq | 23 | 7.57 | 2.08 | 0 |
| gojq | 23 | 11.01 | 3.38 | 0 |
| jq | 23 | 14.20 | 4.12 | 0 |
| yq | 10 | 65.58 | 7.20 | 0 |
| qsv, CSV | 3 | 6.89 | 5.48 | 0 |
| Miller, CSV | 4 | 29.67 | 16.35 | 0 |
| jq `-R`, CSV | 2 | 69.99 | 36.04 | 0 |

Where stury trails: NDJSON check against simdjson's two arms, typed write of `wide.json` (a single object with
342,000 keys) against every peer, and the `stop` arm of the early get lane against sonic-rs, which judges the text
only as far as the value.

## Reading a result

A table says which jobs it compares, the input, the unit (milliseconds, GB/s or microseconds per call), and where stury
trails. Where stury loses a lane, the page says so beside the number.
