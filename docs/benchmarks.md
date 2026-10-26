# Benchmarks

These numbers were measured on one machine (Apple M5 Max, macOS 26.5.1, Odin dev-2026-10 at `-o:speed`) with
the harness in [bench/](../bench/README.md), which documents how to run it, each arm and the fairness rules.
Other data, filters and hardware will give other numbers. No x86 results are published here; simdjson's
AVX-512 paths make the gaps narrower there.

**Against Odin's `core:encoding/json`**, in ms (lower is better). Median of 11 runs, both libraries in one
process with the same arena. Both decode the same values before any lane is timed. The load row builds a stury
DOM and reads every value once, since core has converted every number by the time it returns.

| Job | Input | stury | core:encoding/json | Speedup (core ÷ stury) |
| --- | --- | ---: | ---: | ---: |
| Validate | logs, 8 MB | **2.22** | 27.83 | 12.6× |
| Load into a DOM | logs, 8 MB | **2.42** | 43.99 | 18.2× |
| Unmarshal into structs | logs, 8 MB | **4.71** | 104.16 | 22.1× |
| Marshal structs | logs, 8 MB | **1.49** | 57.68 | 38.8× |
| Validate | nested, 16 MB | **5.33** | 53.29 | 10.0× |
| Load into a DOM | nested, 16 MB | **7.74** | 82.67 | 10.7× |
| Unmarshal into structs | nested, 16 MB | **9.79** | 239.67 | 24.5× |
| Marshal structs | nested, 16 MB | **9.70** | 109.01 | 11.2× |

("DOM" means a whole parsed document you can query.) On nested, core's marshal writes fewer float digits than
stury's, so its output reads back to a different value: that row compares outputs that are not equal.

The same against `core:encoding/csv`, in the same process. Both readers must read the same fields before any
lane is timed. Core makes no UTF-8 check; stury checks every byte. The load row is core's `read_all` against a
stury `Document` with every cell read. The write row writes the same records with core's `Writer` and with
stury's `write_record`.

| Job | Input | stury | core:encoding/csv | Speedup (core ÷ stury) |
| --- | --- | ---: | ---: | ---: |
| Read every field | table, 16 MB | **4.29** | 24.07 | 5.6× |
| Load all records | table, 16 MB | **6.58** | 50.08 | 7.6× |
| Write all records | table, 16 MB | **14.28** | 21.42 | 1.5× |
| Read every field | text, quoted, 16 MB | **8.14** | 20.41 | 2.5× |
| Load all records | text, quoted, 16 MB | **9.53** | 34.47 | 3.6× |
| Write all records | text, quoted, 16 MB | **12.57** | 17.55 | 1.4× |

**Against other libraries**, in GB/s (higher is better). Median of 11 runs, interleaved. Every tool checks
UTF-8 and validates the whole input, and every arm's answer is checked against stury's before it is timed.

Typed decode into structs. serde_json and sonic-rs decode through `#[derive(Deserialize)]`, generic like
stury's `unmarshal`. simdjson and yyjson have no typed decode, so their columns are readers written by hand
for each struct, on simdjson's On-Demand API and on yyjson's DOM. Every arm builds a new value on each read
and keeps its parser and allocator.

| Input | stury | serde_json | sonic-rs | simdjson, hand-written | yyjson, hand-written |
| --- | ---: | ---: | ---: | ---: | ---: |
| logs, 8 MB | **3.57** | 1.33 | 1.90 | 2.32 | 2.93 |
| config, 1 MB | **4.81** | 1.23 | 1.39 | 3.32 | 2.44 |
| nested, 16 MB | **1.77** | 0.69 | 0.84 | 0.79 | 1.66 |

Validate. The simdjson column is its DOM parser, which validates as it builds. It refuses `escape.json`, whose
integers are wider than 64 bits.

| Input | stury | simdjson |
| --- | ---: | ---: |
| logs, 8 MB | **3.85** | 2.96 |
| nested, 16 MB | **3.36** | 1.55 |
| wide, 8 MB | **4.83** | 1.94 |
| pretty, 12 MB | **4.26** | 2.37 |
| deep, 8 MB | **1.71** | 0.67 |
| utf8, 8 MB | **9.09** | 5.45 |

On the eleven real-world files most parser benchmarks use (64 KB–3.3 MB, pretty-printed), stury validates
faster on eight. simdjson is faster on apache_builds (5.89 against 5.27), update-center (5.15 against 4.23)
and twitter (5.20 against 4.83).

DOM. The other libraries convert every number while they parse. stury checks each number while it builds
and converts it when it is read, so its first column builds the DOM and reads every value once, the same work
as the others. The second column is the build alone.

| Input | stury, every value read | stury, build only | yyjson | sonic-rs | simdjson | serde_json |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| logs, 8 MB | 3.24 | 3.97 | **3.40** | 3.13 | 2.93 | 0.67 |
| nested, 16 MB | 1.74 | 2.85 | **2.26** | 1.67 | 1.57 | 0.46 |
| wide, 8 MB | **3.25** | 4.72 | 2.97 | 2.16 | 1.99 | 0.19 |
| pretty, 12 MB | 2.82 | 3.56 | **3.49** | 1.71 | 2.37 | 0.66 |
| deep, 8 MB | 0.94 | 1.30 | **1.17** | 0.22 | 0.65 | |
| longtext, 8 MB | **19.1** | 20.1 | 5.24 | 13.7 | 8.24 | 6.56 |
| utf8, 8 MB | **7.80** | 7.94 | 1.25 | 7.59 | 5.47 | 0.94 |

With every value read, yyjson builds the DOM of logs, nested, pretty and deep input faster, and yyjson or
simdjson is ahead on every real-world file but gsoc-2018 and citm_catalog. A program that reads only some values
pays only for those. The build alone leads on every synthetic input, and on five of the real-world files
(canada, citm_catalog, gsoc-2018, marine_ik, numbers).

Get one field from `config.json` (1 MB), in µs per call (lower is better). stury's `.Lazy` stops at the match,
like sonic-rs. simdjson's On-Demand indexes the whole input first.

| Key | stury | simdjson | sonic-rs |
| --- | ---: | ---: | ---: |
| early | 0.064 | 110 | **0.028** |
| middle | **69** | 166 | 351 |
| last | **136** | 217 | 699 |
| absent | **131** | 165 | 915 |

**CSV**, in GB/s, against the Rust `csv` 1.4 and `simd-csv` 0.14 crates. stury refuses quote misuse,
unterminated quotes and ragged rows, and checks UTF-8 and field counts. The other columns name what each crate
checks: `TotalReader` and `Splitter` check neither UTF-8 nor field counts, `Reader` checks both.

| Job | Input | stury | simd-csv | csv |
| --- | --- | ---: | ---: | ---: |
| Validate | table, 16 MB | **13.4** | 6.53 (`Splitter`, boundaries only) | 1.30 (`StringRecord`) |
| Validate | text, quoted, 16 MB | **6.31** | 3.06 (`Splitter`) | 0.94 |
| Validate | wide, 200 columns, 8 MB | 17.0 | **27.7** (`Splitter`) | 1.45 |
| Read every field | table | **3.91** | 3.78 (`TotalReader`) / 3.05 (`Reader`) | 1.24 |
| Read every field | text | **2.16** | 1.87 / 1.42 | 0.89 |
| Read every field | wide | 3.36 | **3.53** / 2.94 | 1.31 |
| Read every field | tsv, 8 MB | 3.34 | **3.59** / 2.87 | 1.23 |
| Document, every cell read | table | **2.59** | 1.27 (`TotalReader`) | 0.62 |
| Document, every cell read | text | **1.65** | 1.07 | 0.59 |
| Document, every cell read | wide | 2.27 | **2.38** | 1.17 |
| Unmarshal into structs | table | **0.79** | | 0.54 (serde) |
| Unmarshal into structs | text | **0.75** | | 0.51 |
| Marshal structs | table | **1.09** | | 0.44 (serde) |
| Marshal structs | text | **1.42** | | 1.25 |

The unmarshal rows copy every string. With `borrow_strings` stury reads table at 0.94 and text at 1.57. Where
stury trails, the faster arm is one that checks neither UTF-8 nor field counts.

**Command line**, with `bench/cli/jq_compare.sh`: 24 jq filters over the synthetic fixtures and three of the
real-world files, end to end with process start-up, against jq 1.8.2, jaq 3.0.0, gojq 0.12.19 and yq 4.53.2
(on the 11 filters yq can spell). Each figure is the other tool's median wall time divided by stury's, so 2.0×
means stury took half the time. Every tool gave the same answers.

| Tool | Geometric mean | Smallest |
| --- | ---: | ---: |
| jq | 15.0× | 4.9× |
| jaq | 6.9× | 2.2× |
| gojq | 10.4× | 3.4× |
| yq | 57× | 8.6× |

The smallest gaps are on the real-world files (0.6–2.2 MB), where every tool but yq finishes in 1.3–24 ms and
start-up dominates. On the 6–11 MB fixtures stury is 6–100× faster than jq, jaq and gojq.

On CSV, with `bench/cli/csv_compare.sh` on 16 MB files, in ms (lower is better). The jq column splits lines
at commas, so it runs only on `table.csv`, which has no quoted cells. qsv has no CSV-to-JSON-lines arm because
it types the values it converts. Every tool gave the same answers.

| Case | stury | qsv 20.1 | Miller | jq `-R` |
| --- | ---: | ---: | ---: | ---: |
| two columns | **3.5** | 32.5 | 165 | 604 |
| rows filtered (`qty >= 9000`) | **5.8** | 33.0 | 164 | 247 |
| two columns of quoted cells | **3.9** | 34.6 | 71.9 | |
| CSV to JSON lines | **7.1** | | 237 | |
