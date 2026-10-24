# Benchmarks

These numbers were measured on one machine (Apple M5 Max, macOS 26.5, Odin dev-2026-10 at `-o:speed`) with
the harness in [bench/](../bench/README.md), which documents how to run it, each arm and the fairness rules.
Other data, filters and hardware will give other numbers. No x86 results are published here; simdjson's
AVX-512 paths make the gaps narrower there.

**Against Odin's `core:encoding/json`**, in ms (lower is better). Median of 11 runs, both libraries in one
process with the same arena. Both decode the same values before any lane is timed. The load row builds a stury
DOM and reads every value once, since core has converted every number by the time it returns.

| Job | Input | stury | core:encoding/json | Speedup (core ÷ stury) |
| --- | --- | ---: | ---: | ---: |
| Validate | logs, 8 MB | **2.12** | 26.59 | 12.5× |
| Load into a DOM | logs, 8 MB | **2.41** | 42.13 | 17.5× |
| Unmarshal into structs | logs, 8 MB | **4.65** | 99.67 | 21.4× |
| Marshal structs | logs, 8 MB | **1.44** | 55.55 | 38.7× |
| Validate | nested, 16 MB | **4.89** | 50.30 | 10.3× |
| Load into a DOM | nested, 16 MB | **7.32** | 76.53 | 10.5× |
| Unmarshal into structs | nested, 16 MB | **9.36** | 227.99 | 24.3× |
| Marshal structs | nested, 16 MB | **9.29** | 106.11 | 11.4× |

("DOM" means a whole parsed document you can query.)

**Against other libraries**, in GB/s (higher is better). Median of 11 runs, interleaved. Every tool checks
UTF-8 and validates the whole input, and every arm's answer is checked against stury's before it is timed.

Typed decode into structs. serde_json and sonic-rs decode through `#[derive(Deserialize)]`, generic like
stury's `unmarshal`. simdjson and yyjson have no typed decode, so their columns are readers written by hand
for each struct, on simdjson's On-Demand API and on yyjson's DOM. Every arm builds a new value on each read
and keeps its parser and allocator.

| Input | stury | serde_json | sonic-rs | simdjson, hand-written | yyjson, hand-written |
| --- | ---: | ---: | ---: | ---: | ---: |
| logs, 8 MB | **3.53** | 1.34 | 1.88 | 2.36 | 2.94 |
| config, 1 MB | **4.73** | 1.24 | 1.41 | 3.27 | 2.53 |
| nested, 16 MB | **1.76** | 0.69 | 0.84 | 0.80 | 1.67 |

Validate. The simdjson column is its DOM parser, which validates as it builds. It refuses `escape.json`, whose
integers are wider than 64 bits.

| Input | stury | simdjson |
| --- | ---: | ---: |
| logs, 8 MB | **3.80** | 2.96 |
| nested, 16 MB | **3.37** | 1.57 |
| wide, 8 MB | **4.84** | 1.95 |
| pretty, 12 MB | **4.49** | 2.39 |
| deep, 8 MB | **1.70** | 0.66 |
| utf8, 8 MB | **9.13** | 5.49 |

On the eleven real-world files most parser benchmarks use (64 KB–3.3 MB, pretty-printed), stury validates
faster on eight. simdjson is faster on apache_builds (5.90 against 4.80), update-center (5.09 against 4.14)
and twitter (within 3%).

DOM. The other libraries convert every number while they parse. stury checks each number while it builds
and converts it when it is read, so its first column builds the DOM and reads every value once, the same work
as the others. The second column is the build alone.

| Input | stury, every value read | stury, build only | yyjson | sonic-rs | simdjson | serde_json |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| logs, 8 MB | 3.19 | 3.93 | **3.38** | 3.16 | 2.91 | 0.68 |
| nested, 16 MB | 1.75 | 2.82 | **2.29** | 1.67 | 1.57 | 0.46 |
| wide, 8 MB | **3.21** | 4.56 | 2.93 | 2.12 | 1.94 | 0.18 |
| pretty, 12 MB | 2.85 | 3.49 | **3.54** | 1.74 | 2.39 | 0.68 |
| deep, 8 MB | 0.86 | 1.26 | **1.15** | 0.22 | 0.67 | |
| longtext, 8 MB | **19.0** | 19.9 | 5.27 | 13.8 | 8.29 | 6.57 |
| utf8, 8 MB | **7.90** | 7.96 | 1.26 | 7.67 | 5.49 | 0.95 |

With every value read, yyjson builds the DOM of logs, nested, pretty and deep input faster, and yyjson or
simdjson is ahead on every real-world file but gsoc-2018. A program that reads only some values pays only for
those. The build alone leads on every synthetic input but `pretty`, and on four of the real-world files
(canada, citm_catalog, gsoc-2018, numbers).

Get one field from `config.json` (1 MB), in µs per call (lower is better). stury's `.Lazy` stops at the match,
like sonic-rs. simdjson's On-Demand indexes the whole input first.

| Key | stury | simdjson | sonic-rs |
| --- | ---: | ---: | ---: |
| early | 0.064 | 112 | **0.028** |
| middle | **73** | 166 | 359 |
| last | **145** | 223 | 718 |
| absent | **137** | 164 | 950 |

**CSV**, in GB/s, against the Rust `csv` 1.4 and `simd-csv` 0.14 crates. stury refuses quote misuse,
unterminated quotes and ragged rows, and checks UTF-8 and field counts. The other columns name what each crate
checks: `TotalReader` and `Splitter` check neither UTF-8 nor field counts, `Reader` checks both.

| Job | Input | stury | simd-csv | csv |
| --- | --- | ---: | ---: | ---: |
| Validate | table, 16 MB | **13.3** | 6.59 (`Splitter`, boundaries only) | 1.28 (`StringRecord`) |
| Validate | text, quoted, 16 MB | **6.18** | 2.92 (`Splitter`) | 0.90 |
| Validate | wide, 200 columns, 8 MB | 16.9 | **27.3** (`Splitter`) | 1.42 |
| Read every field | table | **3.86** | 3.77 (`TotalReader`) / 3.04 (`Reader`) | 1.21 |
| Read every field | text | **2.16** | 1.92 / 1.41 | 0.89 |
| Read every field | wide | 3.33 | **3.48** / 2.92 | 1.33 |
| Read every field | tsv, 8 MB | 3.22 | **3.58** / 2.89 | 1.20 |
| Document, every cell read | table | **2.59** | 1.24 (`TotalReader`) | 0.60 |
| Document, every cell read | text | **1.56** | 1.04 | 0.58 |
| Document, every cell read | wide | 2.23 | **2.54** | 1.17 |
| Unmarshal into structs | table | **0.76** | | 0.53 (serde) |
| Unmarshal into structs | text | **0.72** | | 0.50 |
| Marshal structs | table | **1.06** | | 0.43 (serde) |
| Marshal structs | text | **1.32** | | 1.19 |

The unmarshal rows copy every string. With `borrow_strings` stury reads table at 0.90 and text at 1.51. Where
stury trails, the faster arm is one that checks neither UTF-8 nor field counts.

**Command line**, with `bench/cli/jq_compare.sh`: 24 jq filters over the synthetic fixtures and three of the
real-world files, end to end with process start-up, against jq 1.8.2, jaq 3.0.0, gojq 0.12.19 and yq 4.53.2
(on the 11 filters yq can spell). Each figure is the other tool's median wall time divided by stury's, so 2.0×
means stury took half the time. Every tool gave the same answers.

| Tool | Geometric mean | Smallest |
| --- | ---: | ---: |
| jq | 14.5× | 4.9× |
| jaq | 6.7× | 2.3× |
| gojq | 10.2× | 3.4× |
| yq | 55× | 8.4× |

The smallest gaps are on the real-world files (0.6–2.2 MB), where every tool but yq finishes in 1.4–25 ms and
start-up dominates. On the 6–11 MB fixtures stury is 6–99× faster than jq, jaq and gojq.

On CSV, with `bench/cli/csv_compare.sh` on 16 MB files, in ms (lower is better). The jq column splits lines
at commas, so it runs only on `table.csv`, which has no quoted cells. qsv has no CSV-to-JSON-lines arm because
it types the values it converts. Every tool gave the same answers.

| Case | stury | qsv 20.1 | Miller | jq `-R` |
| --- | ---: | ---: | ---: | ---: |
| two columns | **3.8** | 33.3 | 170 | 612 |
| rows filtered (`qty >= 9000`) | **6.0** | 33.8 | 168 | 248 |
| two columns of quoted cells | **4.1** | 36.2 | 75.3 | |
| CSV to JSON lines | **7.6** | | 243 | |
