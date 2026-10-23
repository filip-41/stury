# stury's benchmarks

Two comparisons, both runnable from this tree:

- **Libraries** (`compare.py`): stury's read side against simdjson, yyjson, RapidJSON, serde_json and
  sonic-rs: validate, build a DOM, decode into typed values, get one field.
- **Command lines** (`cli/jq_compare.sh`): the `stury` CLI against jq, jaq, gojq and yq, end to end.

Each result says what it measured and under which guarantee. In the library comparison, a number taken on a
loaded machine, from a dirty tree, or without the answer check, is marked as not quotable in its own report.

## Running

```bash
make bench-compare
```

```bash
make bench-cli
```

Or step by step:

```bash
python3 bench/fetch.py              # the pinned corpus and the other libraries' sources (sources.toml)
python3 bench/gen.py --check        # the synthetic fixtures, checked against manifest.toml
python3 bench/compare.py build      # every arm, into build/bench
python3 bench/compare.py check      # every arm must answer as stury does
python3 bench/compare.py time --runs 11 --out build/bench/report
```

You need Odin (the version in the top README), a C++20 compiler, a C compiler, Cargo, Python 3.11+, and for
the CLI comparison zsh, perl, hyperfine, jq, jaq, gojq and yq. The fixture hashes in `manifest.toml` were checked on
CPython 3.14; another release's `random` may change the bytes, so `gen.py --check` can fail there.

Another library whose toolchain, sources or binary are missing is reported as left out, never dropped
silently. The CLI comparison stops before timing when a tool it runs is not installed.
`compare.py time --jobs typed,dom` picks jobs; `compare.py cycles` counts retired instructions and cycles for
close calls. `compare.py time --out DIR` writes `DIR/results.json` and `DIR/report.md`, with the run's
metadata and whether it is quotable; `make bench-compare` uses `build/bench/report`, and the CLI comparison writes
`build/bench/jq_compare/report.md`.

Environment variables:

| variable | what |
| --- | --- |
| `SIMDJSON_SRC`, `RAPIDJSON_INC`, `YYJSON_SRC` | where `compare.py build` finds each library's sources (default: what `fetch.py` put in `build/bench/deps`). Setting one makes the report take that library's version from `pkg-config` (yyjson: from its header) instead of `sources.toml` |
| `STURY_PROBE` | the stury probe binary `compare.py` times (default `build/probe`) |
| `ROUNDS`, `RUNS` | `cli/jq_compare.sh`: hyperfine rounds per case (default 5), timings per tool in each (default 3) |

## What is in here

| path | what |
| --- | --- |
| `gen.py`, `manifest.toml` | the synthetic fixtures, deterministic, each pinned by SHA-256 |
| `fetch.py`, `sources.toml` | the real-world corpus and the other libraries' C/C++ sources, each pinned by URL and SHA-256 |
| `probe/` | stury's arms: one Odin program, one lane per run (`build/probe --lane NAME --fixture F`). The lanes `compare.py` does not run (encode, marshal, edit, record streaming, wildcard paths, duplicate-key and fault handling) are stury-only measurements with no arm from another library |
| `peers/` | the other libraries' arms: `cpp_bench.cpp` (simdjson, RapidJSON), `yy_bench.c` (yyjson), `rust/` (serde_json, sonic-rs, versions in `Cargo.lock`) |
| `core_compare/` | stury against Odin's own `core:encoding/json`: `odin build bench/core_compare -o:speed -collection:stury=. -out:build/core_compare && build/core_compare [fixtures_dir] [rounds]` |
| `compare.py` | builds the arms, checks their answers, times them, writes the report |
| `cli/` | the CLI comparison and its answer check |

## Inputs

- **Synthetic** (`gen.py`): mostly large (1–75 MB), compact documents, each stressing one thing: numbers, escapes,
  long strings, UTF-8, depth, width, record logs. They isolate a cost; they are not typical documents.
- **Corpus** (`fetch.py`): the eleven files other parsers' benchmarks use (twitter, citm_catalog, canada,
  github_events, gsoc-2018, marine_ik, mesh, numbers, instruments, apache_builds, update-center), from
  simdjson-data at one commit. They are smaller (64 KB–3.3 MB), pretty-printed and mixed, so per-document
  setup and whitespace weigh more.

The two sets can rank tools differently. Report both, and say which set a number comes from.

## Protocol

- Every arm is its own process: it reads the file, then times only the job, in process: 2 warm-up calls,
  then the median of 10. File reading, process start and output are outside the clock.
- `compare.py time` runs each arm `--runs` times, interleaved round by round with the arm order rotated, and
  keeps the median of the medians. Each table gives each arm's time over stury's (above 1: stury is faster).
- `check` runs first and must pass: every typed arm's decoded value equals stury's, every GetOne arm agrees on
  the answer, and every arm is run over faulty documents to show what it accepts; only stury's verdicts on those
  documents gate the run. `--skip-check` times anyway, and the report says so.
- Each other library is built from pinned source with `-O3 -DNDEBUG` and the host's native CPU flags (`-mcpu=native`
  / `-march=native`); yyjson also gets `-flto`. The Rust arms build in release with fat LTO, one codegen unit
  and `target-cpu=native`. stury builds at `-o:speed`.
- The report records the commit, a dirty tree, the CPU, the load average, each library's version, each
  input's SHA-256 and each arm binary's SHA-256. A run is quotable only from a clean tree, on the pinned
  inputs, with `check` run, at a 1-minute load at or below 2.

## Fairness rules

Each pair does the same work under the same guarantee, or the table names the difference:

- **Strictness.** The whole-document probes print what each validate and DOM arm accepts (UTF-8, numbers,
  structure); only stury's verdicts gate the run, so read that table beside the timings. stury's `.Lazy`
  level judges only what it reads, so it appears only as a separately labelled arm, never as the head.
- **Deferred work.** stury's DOM checks every number but converts it only when read, and its strings are
  views into the input when they hold no escape. The other libraries convert numbers while parsing. So each DOM table
  also has a `stury DOM + read every value` arm that builds and then reads every value.
- **Allocation.** Every arm reuses what its API lets a user reuse across calls (a parser, a document
  buffer). stury's typed head arm allocates on the heap like the other libraries; its arena-reset variant, and
  simdjson's output-reuse variant, are separate labelled arms.
- **Hand-written vs generic.** simdjson and yyjson typed arms are readers written by hand for each shape and
  are labelled `hand-written`; stury, serde_json and sonic-rs derive their decoders from the type.
- **Each tool's fastest route at the guarantee.** serde_json reads `&str` after a UTF-8 check inside the
  clock; RapidJSON parses with `kParseValidateEncodingFlag | kParseFullPrecisionFlag`, which is the
  guarantee the others give.
- **GetOne** times a batch of calls per sample, so each sample sits well above the timer's resolution.
- **`core_compare`'s load (DOM) arm is not like for like:** stury's `.Dom` scan checks every number but converts
  none and borrows unescaped strings, while `core:encoding/json` converts every number and copies every
  string, so stury does less work there.

## The CLI comparison

`cli/jq_compare.sh` times each case on the synthetic fixtures and on twitter, citm_catalog and canada. Each
tool's answer is kept first, and `cli/jq_report.py` compares it with stury's, as decoded JSON values:
reordered object keys pass, and so do numbers that agree as float64 (yq respells a long literal); anything
else is reported as differing. Timing is hyperfine without a shell, in rounds with the tools' order rotated.
The summary gives each tool's geometric mean and smallest ratio over the cases it answered as stury did, and
counts the ones it did not. The JSONC case is not like for like: jq, jaq, gojq and yq read it through an extra
`sh` and `perl` process that strips the comments and trailing commas, which stury does not pay. The comparison
clears its output directory first, and refuses to when the directory exists and holds no `answers/` of an
earlier run.

## Not covered

Writing (marshal and output), parallel record reads, and inputs larger than memory are not compared here.
Typed decode is compared only on the synthetic shapes, not on the corpus.
