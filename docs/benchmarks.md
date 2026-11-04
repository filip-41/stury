# Benchmarks

This page describes what the harness in [bench/](../bench/README.md) measures, how, and what each comparison does the
same for every tool. It holds no figures yet: they are measured on the merged tree, on one machine, and written here
with that machine's name, the Odin version and `-o:speed`. Other data, filters and hardware give other numbers.

A figure that is not on this page was not measured on the current tree.

## What is compared

| Comparison | Jobs | Compared with | Run with |
| --- | --- | --- | --- |
| Document lanes | build a document, read every value, look up one key | yyjson, simdjson, sonic-rs | `make bench-doc` |
| Path lanes | answer one path or several without a document | the same libraries | `make bench-paths` |
| Typed read | decode into structs, strings borrowed and copied | the same libraries, serde_json | `make bench-typed` |
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

## Reading a result

A table says which jobs it compares, the input, the unit (milliseconds, GB/s or microseconds per call), and where stury
trails. Where stury loses a lane, the page says so beside the number.
