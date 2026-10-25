# stury's benchmarks

Three comparisons, all runnable from this tree:

- **JSON libraries** (`compare.py`): stury's read side against simdjson, yyjson, RapidJSON, serde_json and
  sonic-rs. Jobs: validate, build a DOM, decode into typed values, get one field.
- **CSV libraries** (`compare.py`, the `csv` jobs): stury's CSV codec against the Rust `csv` and `simd-csv`
  crates. Jobs: validate, read records, build a document, decode into typed rows, write them.
- **Command lines** (`cli/jq_compare.sh`, `cli/csv_compare.sh`): the `stury` CLI against jq, jaq, gojq and yq
  on JSON, and against qsv, Miller and jq on CSV, end to end.

Each result states what it measured and under which guarantee. In the library comparison, a number taken on a
loaded machine, from a dirty tree, or without the answer check is marked as not quotable in its report.

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
make fixtures                       # the synthetic fixtures, checked against manifest.toml
python3 bench/compare.py build      # every arm, into build/bench
python3 bench/compare.py check      # every arm must answer as stury does
python3 bench/compare.py time --runs 11 --out build/bench/report
```

You need Odin (the version in the top README), a C++20 compiler, a C compiler, Cargo and Python 3.11+. The CLI
comparisons also need zsh, perl, hyperfine, jq, jaq, gojq and yq (JSON), and qsv and Miller (`mlr`) (CSV). The
fixture hashes in `manifest.toml` were checked on CPython 3.14. Another release's `random` may change the bytes,
so `gen.py --check` can fail there.

A library whose toolchain, sources or binary are missing is reported as left out, never dropped silently. The
CLI comparison stops before timing when a tool it runs is not installed.

- `compare.py time --jobs typed,dom` picks jobs. `--jobs csv` is the five CSV jobs (`csv_validate`,
  `csv_records`, `csv_dom`, `csv_typed`, `csv_marshal`).
- `compare.py cycles` counts retired instructions and cycles, for close calls.
- `compare.py time --out DIR` writes `DIR/results.json` and `DIR/report.md`, with the run's metadata and
  whether it is quotable. `make bench-compare` uses `build/bench/report`.
- `cli/jq_compare.sh` writes `build/bench/jq_compare/report.md`, `cli/csv_compare.sh`
  `build/bench/csv_compare/report.md`.

Environment variables:

| variable | what |
| --- | --- |
| `SIMDJSON_SRC`, `RAPIDJSON_INC`, `YYJSON_SRC` | where `compare.py build` finds each library's sources (default: what `fetch.py` put in `build/bench/deps`). Setting one makes the report take that library's version from `pkg-config` (yyjson: from its header) instead of `sources.toml` |
| `STURY_PROBE` | the stury probe binary `compare.py` times (default `build/probe`) |
| `ROUNDS`, `RUNS` | `cli/jq_compare.sh` and `cli/csv_compare.sh`: hyperfine rounds per case (default 5), timings per tool in each (default 3) |

## What is in here

| path | what |
| --- | --- |
| `gen.py`, `manifest.toml` | the synthetic fixtures, deterministic, each pinned by SHA-256 |
| `fetch.py`, `sources.toml` | the real-world corpus and the other libraries' C/C++ sources, each pinned by URL and SHA-256 |
| `probe/` | stury's arms: one Odin program, one lane per run (`make probe`, then `build/probe --lane NAME --fixture F`). The lanes `compare.py` does not run (encode, marshal, edit, record streaming, wildcard paths, duplicate-key and fault handling) measure stury alone |
| `peers/` | the other libraries' arms: `cpp_bench.cpp` (simdjson, RapidJSON), `yy_bench.c` (yyjson), `rust/` (serde_json, sonic-rs, csv, simd-csv, versions in `Cargo.lock`; `read.rs` is the JSON arm, `csv_bench.rs` the CSV one) |
| `core_compare/` | stury against Odin's own `core:encoding/json`: `odin build bench/core_compare -o:speed -collection:stury=. -out:build/core_compare && build/core_compare [fixtures_dir] [rounds]` |
| `compare.py` | builds the arms, checks their answers, times them, writes the report |
| `cli/` | the CLI comparisons and their answer check |

## Inputs

- **Synthetic** (`gen.py`): mostly large (1–75 MB) compact documents, each stressing one cost: numbers,
  escapes, long strings, UTF-8, depth, width, record logs. They are not typical documents.
- **Corpus** (`fetch.py`): the eleven files other parsers' benchmarks use (twitter, citm_catalog, canada,
  github_events, gsoc-2018, marine_ik, mesh, numbers, instruments, apache_builds, update-center), from
  simdjson-data at one commit. They are smaller (64 KB–3.3 MB), pretty-printed and mixed, so per-document
  setup and whitespace weigh more.
- **CSV** (`gen.py`): four synthetic files, deterministic and pinned in `manifest.toml`: `table.csv` (16 MB,
  numeric columns and a short code), `text.csv` (16 MB, UTF-8 names and quoted cells holding commas, doubled
  quotes and LFs), `wide.csv` (8 MB, 200 columns) and `table.tsv` (8 MB, tab-separated, no quoting). Every
  row has the header's width. The `csv` crate's own bench files are not copied here or read at run time.

The synthetic and corpus sets can rank tools differently. Report both, and say which set a number comes from.

## Protocol

- Every arm is its own process. It reads the file, then times only the job, in process: 2 warm-up calls,
  then the median of 10. File reading, process start and output are outside the clock.
- `compare.py time` runs each arm `--runs` times, interleaved round by round with the arm order rotated, and
  keeps the median of the medians. Each table gives each arm's time over stury's (above 1: stury is faster).
- `check` runs first and must pass. Every typed arm's decoded value equals stury's, and every GetOne arm agrees
  on the answer. Every arm is also run over faulty documents, and the report prints what each accepts; only
  stury's verdicts gate the run, so read that table beside the timings. `--skip-check` times anyway, and the
  report says so.
- Each other library is built from pinned source with `-O3 -DNDEBUG` and the host's native CPU flags
  (`-mcpu=native` / `-march=native`); yyjson also gets `-flto`. The Rust arms build in release with fat LTO,
  one codegen unit and `target-cpu=native`. stury builds at `-o:speed`.
- The report records the commit, a dirty tree, the CPU, the load average, each library's version, each
  input's SHA-256 and each arm binary's SHA-256. A run is quotable only from a clean tree, on the pinned
  inputs, with `check` run, at a 1-minute load at or below 2.

## Fairness rules

Each pair does the same work under the same guarantee, or the table names the difference:

- **Strictness.** The whole-document probes print what each validate and DOM arm accepts (UTF-8, numbers,
  structure). stury's `.Lazy` level judges only what it reads, so it appears only as a separately labelled
  arm, never as the head.
- **Deferred work.** stury's DOM checks every number but converts it only when read, and its strings are
  views into the input when they hold no escape. The other libraries convert numbers while parsing. So each
  DOM table's head arm is `stury DOM + read every value`: it builds, then reads every value in one pass in
  document order, not by a recursive walk, which the other arms do not pay for. `stury .Dom build` is the
  build alone.
- **Allocation.** Every arm reuses what its API lets a user reuse across calls (a parser, a document
  buffer). stury's typed head arm allocates on the heap like the other libraries. Its arena-reset variant and
  simdjson's output-reuse variant are separate labelled arms.
- **Hand-written vs generic.** The simdjson and yyjson typed arms are readers written by hand for each shape,
  labelled `hand-written`. stury, serde_json and sonic-rs derive their decoders from the type.
- **Each tool's fastest route at the guarantee.** serde_json reads `&str` after a UTF-8 check inside the
  clock. RapidJSON parses with `kParseValidateEncodingFlag | kParseFullPrecisionFlag`, the guarantee the
  others give.
- **GetOne** times a batch of calls per sample, so each sample is well above the timer's resolution.
- **`core_compare`'s load (DOM) arm** builds a `.Dom` document and reads every value once in document order,
  since `core:encoding/json` converts every number while parsing. stury borrows strings where core copies
  each one, so stury still does less work on this arm.

## The CSV comparison

`compare.py` runs five jobs on each fixture they apply to, with stury as each table's head:

- **validate**: stury's `.Strict` `csv.validate` (structure, UTF-8, field counts) against the `csv` crate's
  `StringRecord` and `ByteRecord` reads and `simd-csv`'s `Reader` and `Splitter`.
- **records**: stury's `records` with `field_text` on every field against the same peers reading every record.
- **dom**: stury's `Document` build plus a read of every cell (the head), and the build alone, against peers
  that keep every record in a `Vec` and then read every field once, inside the clock. stury decodes a quoted
  cell only when it is read, so each side reads every cell.
- **typed**: `unmarshal` into `[]Row` (strings copied, and strings borrowed from the input) against the `csv`
  crate's serde `Deserialize`, on `table.csv` and `text.csv`.
- **marshal**: `marshal` of those rows against the `csv` crate's serde `Writer`.

Each arm's label states what it guarantees:

- The `csv` crate's `StringRecord` checks UTF-8 and field counts; `ByteRecord` does not check UTF-8. Both take
  a quote inside an unquoted field as text and accept an unterminated quote, which stury refuses.
- `simd-csv`'s `Reader` checks UTF-8 and field counts but accepts a bare CR and quote misuse. `TotalReader`
  checks neither UTF-8 nor field counts. `Splitter` only finds record boundaries. `simd-csv` cannot switch
  quoting off, so on `table.tsv` it runs with the tab delimiter and quoting on.
- `check` prints each arm's verdict on faulty CSV. It also compares every record and field count across the
  arms and every typed arm's rows with the file's own cells, and reads each marshalled output back.

Run `python3 bench/compare.py time --jobs csv --runs 11 --out build/bench/report_csv` on a clean, quiet tree,
after `fetch.py`, `gen.py --check`, `build` and `check`. The `csv` jobs need neither the C/C++ sources nor the
corpus, so `build` and `check` run for them with only Odin and Cargo; the JSON jobs whose inputs are missing
are reported as left out.

`cli/csv_compare.sh` times four cases on `table.csv` and `text.csv`: two columns picked, rows filtered
(`qty >= 9000`), two columns picked from quoted cells, and CSV to JSON lines. Each tool's output is kept, and
`jq_report.py` compares it with stury's line by line (`*_raw` cases) or as decoded JSON. The jq arm splits at
commas, so it runs only the two cases on `table.csv`, where no cell is quoted. qsv has no JSON-lines arm: it
types the values it converts (numbers, booleans), where stury and Miller's `-S` keep strings.

## The CLI comparison

`cli/jq_compare.sh` times each case on the synthetic fixtures and on twitter, citm_catalog and canada. Each
tool's answer is kept, and `cli/jq_report.py` compares it with stury's as decoded JSON values. Reordered
object keys pass, and so do numbers that agree as float64 (yq respells a long literal); anything else is
reported as differing. Timing is hyperfine without a shell, in rounds with the tools' order rotated. The
summary gives each tool's geometric mean and smallest ratio over the cases it answered as stury did, and
counts the ones it did not. The JSONC case is not like for like: jq, jaq, gojq and yq read it through an extra
`sh` and `perl` process that strips the comments and trailing commas, which stury does not pay. The comparison
clears its output directory first, and refuses to when the directory exists and holds no `answers/` from an
earlier run.

## Not covered

Writing is compared only for CSV (marshal against the `csv` crate). JSON marshal and output, parallel record
reads, and inputs larger than memory are not compared. Typed decode is compared only on the synthetic shapes,
not on the corpus.
