# Benchmarks

This page describes what the harness in [bench/](../bench/README.md) measures and how, what each comparison holds
equal for every tool, and the figures measured on two machines: an Apple M5 Max on the released tree, and an x86-64
Xeon on the tree after it, each named with its set. Other data, filters and hardware give other numbers. A figure
that is not on this page was not measured.

## What is compared

| Comparison | Jobs | Other libraries | Run with |
| --- | --- | --- | --- |
| Document lanes | build a document, read every value, look up one key | yyjson, simdjson, sonic-rs on JSON, and per format the table in `bench/README.md` | `make bench-doc` |
| Path lanes | answer a path without a document, or stop at the answer | simdjson, sonic-rs, toml++, pugixml, quick-xml, rapidyaml, minicbor, lexbor | `make bench-paths` |
| Typed read | decode into structs, strings borrowed and copied | serde_json, sonic-rs, serde_yaml_ng, toml, quick-xml, ciborium, minicbor | `make bench-typed` |
| Record lanes | frame, judge, build and read the records of NDJSON, CSV, YAML streams and CBOR sequences | simdjson, serde_json, sonic-rs, simd-csv, rapidyaml, libyaml, ciborium, minicbor | `make bench-records` |
| Write lanes | write a struct or a document, compact and pretty | yyjson, simdjson, serde_json, sonic-rs, and per format | `make bench-write` |
| Edit lane | commit 1000 edits spread over a file's values | lol_html, toml_edit | `make bench-edit` |
| Schema lane | judge instances against JSON Schemas | Blaze, jsonschema-rs, boon | `make bench-schema` |
| Model lane | load and dump records through a model with rules | pydantic, msgspec, serde_json with garde | `make bench-model` |
| Command line | filters over files, end to end | jq, jaq, gojq, yq, qsv, Miller, xmllint, xmlstarlet, dasel, htmlq, pup | `make bench-cli`, `bench cli --suite NAME` |

The fixtures are pinned: the corpus files and the other libraries' sources by URL and SHA-256 (`bench/CMakeLists.txt`,
`bench/fixtures.toml`), and the synthetic files by `bench/fixtures.toml` (`bench fixtures --check`). The synthetic files
are large and compact, and each stresses one cost, so they are not typical documents. The corpus files are small,
pretty-printed and mixed. The two sets can rank tools differently. `logs.*` holds the same 36,992 records in every
format.

## Protocol

- Every arm is its own process. It reads the file, then times only the job, in process: two warm-up calls, then ten
  timed samples, and the median is the mean of the two middle samples. A sample is one call, except in the get-one-field
  lanes, where it is 100. File reading, process start and output are outside the clock.
- The runner (`bench/runner/`) interleaves the arms round by round, and each cell is an arm's best median over the
  rounds. A command line suite runs its tools in rotating order. Everything runs under `bench/runner/guard.py`, which
  holds `build/bench/timing.lock`, so one timed job runs at a time, and kills a process that passes 1 GiB of live RSS.
- Every arm prints a check of what it read or wrote, and no row is timed unless the checks agree. A row that cannot be
  checked says why in its `lane.toml`.
- Each other library is built from its pinned source with `-O3 -DNDEBUG`, the Rust arms in release with fat LTO, and
  stury at `-o:speed`. A library whose toolchain or sources are missing is reported as left out. On x86-64 the other
  libraries are also built for the host CPU (`-march=native`, `-C target-cpu=native`), so each has its widest vector
  kernels, as stury picks its own when it runs.
- Memory figures are the peak RSS of each child, taken from `wait4`, the median over the rounds. On Linux that peak
  includes the image of the runner that forked the child, so the x86-64 set gives none.

## Fairness rules

Each pair does the same work under the same guarantee, or the table names the difference.

- **Strictness.** Every arm of a validate or build table judges the whole input: UTF-8, numbers, structure, and for
  markup names, attributes and entities. An arm whose name ends in `_nv` judges less: pugixml and quick-xml check that
  tags nest, not names, repeated attributes, entities or namespaces. QCBOR and libcbor do not check the UTF-8 of text
  strings, so their table is separate. A mode that judges only what it reads appears only as its own labelled arm.
- **Deferred work.** stury's document checks every number and converts it when it is read, and its strings are views
  into the input. The other libraries convert numbers while they parse. So the `read` lane builds and then reads every
  value once, and the `build` lane is the build alone.
- **Allocation.** Every arm reuses what its API lets a caller reuse across calls, a parser or a document buffer. The
  probe builds each document in an arena whose backing is not zeroed. Every write arm writes into one output buffer it
  allocates once.
- **Each tool's fastest route.** An arm does the job the way its library does it fastest. serde_json reads the bytes
  (`from_slice`) and is built with `preserve_order` and `float_roundtrip`, so its `Value` keeps members in source order
  and every decimal reads to the nearest double, as the other arms do. A stream of records is read by each library's
  own stream reader. A tool that must build a document for a job has that cost counted.
- **One key.** A get-one-field sample is a batch of 100 calls, each releasing its result inside the clock, reported
  over 100, for every arm. One call of the early key is a few ticks of the clock, which a sample of one call cannot
  resolve.
- **Schema.** jsonschema-rs and boon read YAML and CBOR through a Rust parser into a `serde_json::Value` and judge that,
  as a user checks such a file without stury, and logs.xml through roxmltree (`jsonschema_xml`). Blaze reads JSON only.
- **Command line.** Each figure is the other tool's median wall time divided by stury's, over the same filter and the
  same file, process start included, over ten timed runs per tool and case after two warm-ups. stury answers a file of
  1 MiB or more on every core, as it does for a user. Every tool must give the same answers before it is timed, and a
  tool that cannot spell a filter is left out of that row.

## Results on an Apple M5 Max

Measured on 2026-11-18 on an Apple M5 Max (18 cores), macOS 27.2, with Odin dev-2026-11 at `-o:speed` and five rounds
for the library lanes. Every runner prints the Odin version, the CPU and the date it ran with. Every other library was
present. GB/s unless the table says otherwise, and `-` is an arm the harness leaves out of a row.

### JSON documents (`make bench-doc`)

Build a document, then read every value once, then look up one key in every object, each lookup stopping at the first
member of that name as every library's does. On `table.csv` the key is the column, found once.

| Build | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 4.15 | 3.07 | 3.09 | 3.24 |
| citm_catalog.json | 8.00 | 5.22 | 5.96 | 3.76 |
| table.csv | 4.08 | - | - | - |
| logs.jsonc | 3.73 | - | - | - |
| logs.json5 | 3.28 | - | - | - |

| Read every value | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 3.35 | 2.56 | 2.51 | 1.94 |
| citm_catalog.json | 6.14 | 4.43 | 4.51 | 2.59 |
| table.csv | 2.74 | - | - | - |
| logs.jsonc | 2.94 | - | - | - |
| logs.json5 | 2.50 | - | - | - |

| Look up one key | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 3.51 | 2.54 | 2.40 | 1.93 |
| citm_catalog.json | 6.35 | 4.26 | 4.47 | 2.53 |
| table.csv | 3.39 | - | - | - |
| logs.jsonc | 3.08 | - | - | - |
| logs.json5 | 2.72 | - | - | - |

Peak resident MiB of the build. The read and key lanes hold the same document and stay within 0.1 MiB.

| Build | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 24.4 | 27.6 | 29.0 | 29.5 |
| citm_catalog.json | 9.5 | 6.9 | 5.3 | 7.1 |
| table.csv | 59.9 | - | - | - |

stury is ahead on both JSON fixtures in all three lanes. It holds less memory on `logs.json` and more on
`citm_catalog.json`, a 1.7 MB file where the probe's own image, which links every format, is a large share.

### JSON paths (`make bench-paths`)

ns per call. `scan` reads a path over the text and judges every byte. `build_query` builds the document inside the
clock and then queries it. `simd` is simdjson's On-Demand `find_field`, whose stage 1 indexes the whole text and checks
its UTF-8, and which skips values without judging their numbers and escapes. `stop` reads with `stop_early`, judging
every byte up to the answer and leaving the rest unread. `sonic` is sonic-rs's `get`, which stops at the key and skips
values without judging them.

| The whole text read | scan | build_query | simd |
| --- | ---: | ---: | ---: |
| get early | 1,547,473 | 2,339,345 | 1,051,556 |
| get middle | 1,573,430 | 2,347,802 | 1,375,700 |
| get late | 1,538,965 | 2,354,213 | 1,617,064 |
| get absent | 1,553,186 | 2,423,755 | 1,615,629 |
| get last root key | 110,104 | 115,215 | 85,125 |

| The text read up to the answer | stop | sonic |
| --- | ---: | ---: |
| get early | 160 | 40 |
| get middle | 782,413 | 2,540,697 |
| get late | 1,539,054 | 5,067,907 |
| get absent | 1,534,863 | 6,693,451 |
| get last root key | 108,893 | 298,640 |

`logs.json`, the whole text judged by `scan` against a document built outside the clock and walked by `query`:

| Path | scan | query |
| --- | ---: | ---: |
| .logs[].id | 2,192,979 | 965,771 |
| .logs[][] | 3,509,249 | 2,033,583 |
| .logs[-1] | 2,030,375 | 316,896 |
| .logs[-20] | 2,028,166 | 310,875 |
| five keys per record | 6,851,583 | 5,579,729 |

simdjson's `find_field` is ahead of the scan on the early and middle keys and the last root key, judging less, and
behind it on the late and absent keys. sonic-rs's `get` is ahead on the early key, the one the text answers in its first
bytes, and stury's stopped scan is ahead on every other.

### JSON typed read (`make bench-typed`)

Decode into structs, strings borrowed or copied. serde_json and sonic-rs read into the same structs with derived
decoders: a copied string is a `String`, and a borrowed one borrowed from the input when it has no escape, as stury
borrows it.

| Borrow | stury | serde_json | sonic-rs |
| --- | ---: | ---: | ---: |
| logs.json | 4.17 | 1.23 | 1.68 |
| twitter.json | 4.24 | 2.01 | 2.15 |
| citm_catalog.json | 7.70 | 2.33 | 2.83 |
| table.csv | 1.59 | - | - |
| text.csv | 1.91 | - | - |

| Copy | stury | serde_json | sonic-rs |
| --- | ---: | ---: | ---: |
| logs.json | 2.88 | 1.02 | 1.35 |
| twitter.json | 4.11 | 1.92 | 2.10 |
| citm_catalog.json | 7.57 | 2.35 | 2.83 |
| table.csv | 1.37 | - | - |
| text.csv | 1.23 | - | - |

### JSON records (`make bench-records`)

`check` judges the records on one thread, `threads` on six. `simd_od` is simdjson's On-Demand `iterate_many`, which
skips each document and judges its structure but not its escapes or number syntax, and `simd` is its tape, threaded
with stage 1 in a thread of its own. `serde_validate` and `sonic_validate` read to `IgnoredAny`.

| Judge, one thread | stury | simd | simd_od | serde_json | sonic-rs |
| --- | ---: | ---: | ---: | ---: | ---: |
| logs.ndjson | 4.28 | 2.95 | 5.10 | 1.42 | 0.93 |
| docs.ndjson | 0.86 | 0.86 | 2.12 | 0.64 | 0.54 |
| twitter.ndjson | 4.58 | 4.03 | 5.57 | 1.98 | 1.22 |

| Judge, threaded | stury, 6 threads | simd | simd_od |
| --- | ---: | ---: | ---: |
| logs.ndjson | 24.19 | 4.57 | 6.52 |
| docs.ndjson | 4.92 | 1.11 | 3.24 |
| twitter.ndjson | 24.92 | 6.76 | 7.24 |

| A document per record | stury | serde_json `Value` | sonic-rs `Value` |
| --- | ---: | ---: | ---: |
| logs.ndjson | 1.32 | 0.32 | 0.73 |
| docs.ndjson | 0.70 | 0.18 | 0.41 |
| twitter.ndjson | 3.71 | 0.46 | 1.28 |

| Frame CSV records | stury | simd-csv |
| --- | ---: | ---: |
| table.csv | 9.75 | 5.48 |
| text.csv | 5.41 | 2.67 |

Threaded, stury leads every arm. On one thread simdjson's On-Demand skip is ahead on all three files while judging less,
and its tape is ahead on `docs.ndjson`.

### JSON writes (`make bench-write`)

Write a typed value or a document, compact and pretty. `simd_min` is simdjson's minifier, which does not judge the
document, and the other arms write a value they hold. stury's document write copies each number's source spelling,
and the other libraries format the double their DOM holds. stury writes a struct's whole float with no fraction, as jq
does, and the others write `1.0`. On `logs.json` and `canada.json` the texts differ by those spellings alone, so the
harness leaves stury's text out of the check there. GB/s of the output on the typed rows and of the source on the
document rows.

| Typed, compact | stury | yyjson | sonic-rs | serde_json |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 7.03 | 2.62 | 3.08 | 1.87 |
| twitter.json | 6.66 | 2.79 | 5.06 | 2.21 |
| citm_catalog.json | 4.28 | 2.80 | 2.77 | 2.01 |
| canada.json | 2.12 | 1.27 | 1.83 | 1.85 |
| nested.json | 2.98 | 1.72 | 1.19 | 1.18 |
| wide.json | 0.24 | 0.15 | 0.22 | 0.21 |

| Document, compact | stury | yyjson | simdjson | simdjson minify | sonic-rs | serde_json |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| logs.json | 28.18 | 4.69 | 1.64 | 14.42 | 2.32 | 1.56 |
| twitter.json | 22.81 | 9.53 | 2.44 | 15.06 | 4.48 | 2.80 |
| citm_catalog.json | 29.74 | 18.10 | 4.84 | 15.13 | 6.10 | 6.30 |
| canada.json | 41.66 | 1.94 | 1.25 | 14.29 | 1.56 | 1.66 |
| pretty.json | 16.22 | 7.45 | 1.91 | 15.04 | 2.01 | 1.99 |
| utf8.json | 44.96 | 0.84 | 0.86 | 14.41 | 22.30 | 3.78 |
| escape.json | 43.14 | 1.69 | 1.01 | 14.40 | 0.93 | 1.09 |
| longtext.json | 44.22 | 5.61 | 0.86 | 14.41 | 22.22 | 3.81 |

The pretty writes rank the tools the same way. A map value's keys are written sorted, and every arm sorts them inside
the timed write: `citm_catalog.json`'s five maps and `wide.json`, a map of 342,658 keys, where stury leads by 12%.

### Other formats: documents (`make bench-doc`)

Build a document of each format beside that format's libraries. Read every value and look up one key rank the tools as
the build does, within a few percent, except where the text says otherwise.

| YAML build | stury | rapidyaml | libfyaml | libyaml | saphyr |
| --- | ---: | ---: | ---: | ---: | ---: |
| logs.yaml | 0.71 | 0.51 | 0.09 | 0.09 | 0.08 |
| twitter.yaml | 0.67 | 0.56 | 0.11 | 0.12 | 0.11 |
| citm.yaml | 0.43 | 0.36 | 0.07 | 0.08 | 0.07 |
| openapi-stripe.yaml | 0.78 | 0.45 | 0.14 | 0.13 | 0.13 |

| TOML build | stury | toml++ | toml11 | toml |
| --- | ---: | ---: | ---: | ---: |
| logs.toml | 0.76 | 0.09 | 0.006 | 0.17 |
| cargo-lock-zed.toml | 0.87 | 0.11 | 0.007 | 0.22 |
| uv-lock-airflow.toml | 1.15 | 0.12 | 0.018 | 0.24 |
| pyproject-airflow.toml | 0.78 | 0.11 | 0.012 | 0.32 |

| XML build | stury | pugixml_nv | quickxml_nv | libxml2 | roxmltree |
| --- | ---: | ---: | ---: | ---: | ---: |
| logs.xml | 1.57 | 2.37 | 0.77 | 0.31 | 0.46 |
| osm-beatty.xml | 1.29 | 2.96 | 1.26 | 0.25 | 0.58 |
| nasa.xml | 1.74 | 2.55 | 0.94 | 0.38 | 0.48 |

| XML validate | stury | expat | libxml2 SAX | quickxml_nv |
| --- | ---: | ---: | ---: | ---: |
| logs.xml | 1.91 | 0.50 | 0.68 | 0.77 |
| osm-beatty.xml | 1.69 | 0.37 | 0.48 | 1.26 |
| nasa.xml | 2.13 | 0.49 | 0.75 | 0.94 |

| HTML build | stury | lexbor | gumbo | html5ever |
| --- | ---: | ---: | ---: | ---: |
| logs.html | 0.29 | 0.33 | 0.06 | 0.14 |
| whatwg-html.html | 0.31 | 0.33 | 0.07 | 0.13 |
| wikipedia-united-states.html | 0.56 | 0.54 | 0.08 | 0.16 |
| wikipedia-world-war-ii.html | 0.54 | 0.53 | 0.08 | 0.16 |

| CBOR build | stury | ciborium | minicbor | tinycbor | QCBOR | libcbor |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| logs.cbor | 3.63 | 0.42 | 1.34 | 0.87 | 1.35 | 0.51 |
| twitter.cbor | 3.78 | 0.50 | 1.37 | 1.02 | 1.73 | 0.54 |
| citm.cbor | 2.28 | 0.23 | 0.59 | 0.57 | 0.60 | 0.28 |

tinycbor builds no document: its arm walks the items and judges the text. QCBOR and libcbor do not judge the UTF-8 of
text strings.

Peak resident MiB of the build on the logs records:

| Build | stury | other libraries |
| --- | ---: | --- |
| logs.yaml | 24.6 | rapidyaml 162, libfyaml 274, libyaml 683, saphyr 132 |
| logs.toml | 52.7 | toml++ 131, toml11 265, toml 363 |
| logs.xml | 28.4 | pugixml_nv 66, quickxml_nv 15, libxml2 146, roxmltree 84 |
| logs.html | 97.9 | lexbor 134, gumbo 114, html5ever 136 |
| logs.cbor | 23.3 | ciborium 40, minicbor 29, tinycbor 8.9, QCBOR 8.9, libcbor 55 |

stury builds every format faster than its libraries that judge the same, and holds less memory on YAML, TOML, XML and
HTML.
The losses:

- pugixml is 1.5 to 2.3 times stury on XML, judging less than stury. stury's read and key lanes are ahead of pugixml on
  `logs.xml`.
- lexbor builds `logs.html` and `whatwg-html.html` 5 to 13% faster. stury's read and key lanes are ahead of lexbor on
  every HTML file.
- tinycbor and QCBOR walk a CBOR text in 9 MiB, where stury builds a document of 23.

### Other formats: paths (`make bench-paths`)

ns per call over the logs records: one field of the first record (early) and of the last (late).

| The whole text read | stury scan | stury build_query | other libraries |
| --- | ---: | ---: | --- |
| YAML early | 10,786,854 | 11,649,395 | rapidyaml build and query 17,145,479 |
| YAML late | 10,806,375 | 11,873,729 | rapidyaml build and query 18,921,125 |
| TOML early | 10,089,250 | 11,663,646 | toml++ 98,635,666 |
| TOML late | 10,191,791 | 11,912,729 | toml++ 98,855,583 |
| XML early | 6,313,812 | 7,532,021 | pugixml_nv 9,166,604 |
| XML late | 6,793,416 | 8,800,875 | pugixml_nv 8,911,854, quickxml_nv 16,220,416 |
| CBOR early | 1,848,833 | 1,944,271 | |
| CBOR late | 1,823,375 | 2,137,937 | minicbor, stopping at the answer, 4,452,958 |
| HTML first cell | 28,447,625 | 28,268,937 | lexbor 26,814,687 |
| HTML last cell | 30,588,521 | 30,630,187 | lexbor 31,715,646 |

| The text read up to the answer | stury stop | other libraries |
| --- | ---: | --- |
| YAML early | 750 | |
| TOML early | 792 | |
| XML early | 417 | quickxml_nv 192,208 |
| CBOR early | 333 | minicbor 167 |
| HTML first cell | 28,356,646 | |

A path read under `stop_early` stops at the answer in every format but HTML, whose tree builder reads the whole text.
minicbor is ahead on the early CBOR field, and lexbor on the first HTML cell.

### Other formats: typed reads and writes (`make bench-typed`, `make bench-write`)

Read the logs records into structs, then write them back, beside each format's libraries. quickxml_nv judges less
than stury. serde_yaml_ng and ciborium hand every string over owned, so their borrow rows copy too.

| Typed read, borrow | stury | other libraries |
| --- | ---: | --- |
| logs.yaml | 0.42 | serde_yaml_ng 0.07 |
| logs.toml | 0.48 | toml 0.24 |
| logs.xml | 0.68 | quickxml_nv 0.38 |
| logs.cbor | 2.62 | ciborium 0.61, minicbor 1.82 |

| Typed read, copy | stury | other libraries |
| --- | ---: | --- |
| logs.yaml | 0.40 | serde_yaml_ng 0.07 |
| logs.toml | 0.47 | toml 0.23 |
| logs.xml | 0.46 | quickxml_nv 0.36 |
| logs.cbor | 1.82 | ciborium 0.62, minicbor 1.26 |

| Typed write | stury | other libraries |
| --- | ---: | --- |
| logs.yaml | 0.67 | rapidyaml 0.53, serde_yaml_ng 0.12 |
| logs.toml | 0.76 | toml 0.92 |
| logs.xml | 0.63 | quick-xml 0.57 |
| logs.cbor | 4.61 | ciborium 3.66, minicbor 4.44, tinycbor 2.47 |

| Document write | stury | other libraries |
| --- | ---: | --- |
| logs.yaml | 0.83 | rapidyaml 1.33, serde_yaml_ng 0.12 |
| logs.toml | 1.34 | toml++ 0.25, toml 0.79 |
| logs.xml | 3.50 | pugixml 2.20, quick-xml 0.98 |
| logs.cbor | 4.35 | ciborium 1.92, minicbor 3.17 |
| logs.html | 0.18 | lexbor 0.58, html5ever 0.93 |
| whatwg-html.html | 0.17 | lexbor 0.51, html5ever 0.86 |

stury reads every format into a type faster than its libraries. The writes trail on the TOML typed write and on the YAML
and HTML documents.

### Other formats: records (`make bench-records`)

| Judge, one thread | stury | other libraries |
| --- | ---: | --- |
| logs.seq.cbor | 3.92 | ciborium 0.52, minicbor 1.60 |
| k8s-prometheus-operator.yaml | 1.53 | libyaml 0.17 |
| k8s-argo-cd.yaml | 1.14 | libyaml 0.15 |

| A document per record | stury | other libraries |
| --- | ---: | --- |
| logs.seq.cbor | 1.05 | ciborium `Value` 0.32 |
| k8s-prometheus-operator.yaml | 0.71 | rapidyaml 0.47, libyaml 0.16 |
| k8s-argo-cd.yaml | 0.53 | rapidyaml 0.50, libyaml 0.13 |

### Edits (`make bench-edit`)

Set `0` on 1000 value nodes spread over the file and commit, keeping every other byte. GB/s of the source over the
best of three commits. toml_edit parses the text into its editable tree and writes it back, and lol_html rewrites
the HTML in one streaming pass that sets the same elements' content.

| Edit | stury | other libraries |
| --- | ---: | --- |
| logs.json | 3.80 | |
| twitter.json | 4.25 | |
| table.csv | 3.33 | |
| logs.json5 | 3.16 | |
| logs.yaml | 0.37 | |
| logs.toml | 0.41 | toml_edit 0.40 |
| logs.xml | 1.79 | |
| logs.html | 0.26 | lol_html 0.26 |

stury and lol_html edit HTML at the same speed.

### JSON Schema (`make bench-schema`)

Parse and judge each instance, then drop it, single-threaded. The verdict table gives GB/s of the instance text.

| Verdict | stury | Blaze | jsonschema-rs | boon |
| --- | ---: | ---: | ---: | ---: |
| geojson | 1.02 | 0.28 | 0.40 | 0.13 |
| openapi | 0.39 | 0.59 | 0.39 | 0.29 |
| draft-04 | 0.79 | 0.58 | 0.33 | 0.27 |
| cmake-presets | 0.42 | 0.41 | 0.12 | 0.04 |
| ui5-manifest | 0.24 | 0.38 | 0.26 | - |
| helm-chart-lock | 0.95 | 0.53 | 0.41 | 0.32 |
| cspell | 0.69 | 0.46 | 0.27 | - |
| deno | 1.56 | 0.55 | 0.47 | 0.41 |
| code-climate | 1.02 | 0.28 | 0.24 | 0.22 |
| pulumi | 0.74 | 0.36 | 0.30 | 0.24 |
| aws-cdk | 2.80 | 0.77 | 0.56 | 0.52 |
| ansible-meta | 0.25 | 0.32 | 0.26 | 0.05 |
| clang-format | 0.61 | 0.56 | 0.38 | 0.28 |
| babelrc | 0.62 | 0.27 | 0.29 | 0.21 |
| krakend | - | 0.40 | 0.29 | 0.20 |
| logs | 0.89 | 0.53 | 0.41 | 0.28 |
| twitter | 1.13 | 0.74 | 0.39 | 0.30 |
| citm | 1.36 | 0.40 | 0.31 | 0.21 |
| applicator | 0.09 | 0.14 | 0.11 | 0.06 |
| logs.yaml | 0.33 | - | 0.06 | 0.05 |
| logs.toml | 0.44 | - | 0.20 | 0.17 |
| logs.cbor | 0.86 | - | 0.28 | 0.21 |
| logs.xml | 0.50 | - | 0.24 | - |
| geomean over Blaze | 1.61 | 1.00 | 0.73 | 0.46 |

boon refuses the `ui5-manifest` and `cspell` schemas. stury refuses `krakend`, whose pattern `\&` ECMA-262 refuses
under the `u` flag. Blaze is ahead on `openapi`, `ui5-manifest`, `ansible-meta` and `applicator`, schemas whose cost is
in many `$ref`s and applicators rather than in the instance text.

### Models (`make bench-model`)

Each call loads or dumps every record of the file, one JSON record to a line, through the same rules written in each
library's way. msgspec stops at a record's first failure, so it is timed against stury's first-failure load.

| | stury | pydantic | msgspec | garde |
| --- | ---: | ---: | ---: | ---: |
| load valid, logs | 0.67 | 0.25 | 0.31 | 0.27 |
| load valid, twitter | 1.58 | 0.88 | 1.16 | 0.95 |
| load invalid, every failure, logs | 0.56 | 0.14 | - | 0.27 |
| load invalid, every failure, twitter | 1.52 | 0.70 | - | 0.92 |
| load invalid, first failure, logs | 0.77 | - | 0.36 | - |
| load invalid, first failure, twitter | 1.65 | - | 1.46 | - |
| dump, logs | 2.10 | 0.30 | 1.14 | 1.25 |
| dump, twitter | 4.80 | 0.54 | 2.12 | 1.63 |

stury leads every row. A dump of the 36,992 logs records peaks at 62 MiB against garde's 37 and msgspec's 95, since
the probe keeps every record's text in one arena.

### Command line (`make bench-cli`)

Each tool's median wall time divided by stury's, process start included. No case gave a different answer except where
the table counts one.

The jq suite, 30 filters over `logs.json`, `logs.ndjson`, `documents.json`, a JSONC copy of `logs.json` and the corpus.
yq has no arm in 19 of them.

| Tool | cases | geomean × stury | min × stury | answer differs |
| --- | ---: | ---: | ---: | ---: |
| jq | 30 | 19.36 | 4.69 | 0 |
| jaq | 30 | 11.25 | 2.35 | 0 |
| gojq | 30 | 14.01 | 3.78 | 0 |
| yq | 11 | 68.94 | 7.98 | 0 |

The closest cases to jaq are `twitter_select` (2.35×), `twitter_names` (2.41×) and `validate_twitter` (2.48×).
`twitter.json` is the smallest input in the set, so process start is the largest share of its wall time.

The other suites:

| Suite | Tool | cases | geomean × stury | min × stury | answer differs |
| --- | --- | ---: | ---: | ---: | ---: |
| csv | qsv | 3 | 7.23 | 6.12 | 0 |
| csv | Miller | 4 | 30.41 | 15.52 | 0 |
| csv | jq | 2 | 79.28 | 43.08 | 0 |
| xml | xmllint | 6 | 4.06 | 1.10 | 0 |
| xml | yq | 7 | 31.70 | 10.32 | 0 |
| toml | dasel | 6 | 6.67 | 4.69 | 0 |
| toml | yq | 4 | 825.65 | 11.29 | 1 |
| yaml | dasel | 7 | 16.05 | 8.42 | 0 |
| yaml | yq | 10 | 28.43 | 4.83 | 0 |
| html | htmlq | 2 | 2.94 | 2.77 | 0 |
| html | pup | 2 | 2.90 | 2.74 | 0 |

xmllint is 1.10 times stury on `xml_osm_user_raw`, one attribute of a 380 KB file, where process start is most of the
time.
yq differs on `toml_pyproject_json`: it reads the keys of `pyproject-airflow.toml`'s `extend-per-file-ignores` table into
other members, where stury and Python's `tomllib` agree. yq has no arm on `logs.toml`, which it did not answer in forty
CPU minutes.

## Results on x86-64

Measured on 2026-11-18 on an Intel Xeon at 2.10 GHz with AVX-512, four vCPUs of a KVM guest, Ubuntu 24.04 with Linux
6.18, with Odin dev-2026-11 at `-o:speed` and five rounds for the library lanes. The tree is the one after the release,
so its figures include changes the M5 set does not. Every other library is built for the host CPU. The set differs
from the M5's in these ways:

- It gives no memory figures, since on Linux each child's peak includes the runner's own image.
- The four files the corpus takes from web.archive.org (`nasa.xml`, `whatwg-html.html` and the two Wikipedia pages)
  could not be fetched, so their rows are absent.
- qsv did not build, so the csv suite has no qsv arm. xmlstarlet is in the xml suite.
- The toml suite ran on 2026-11-19 on a Xeon at 2.30 GHz, after the guest moved host, against the same builds.
- The threaded record lanes run six threads on four vCPUs, and the command line answers on four cores where the M5
  has 18. Each command line figure is therefore against a stury with fewer cores than on the M5.

simdjson's stage 1 widens with AVX-512, while stury's document walk goes a token at a time, so simdjson, which trails
stury on the M5, draws level with it here and passes it in a few rows.

### JSON documents

| Build | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 2.59 | 1.47 | 2.71 | 1.18 |
| citm_catalog.json | 4.23 | 2.35 | 4.39 | 2.05 |
| table.csv | 1.67 | - | - | - |
| logs.jsonc | 1.92 | - | - | - |
| logs.json5 | 1.98 | - | - | - |

| Read every value | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 1.54 | 1.47 | 1.93 | 0.71 |
| citm_catalog.json | 3.00 | 2.05 | 2.62 | 1.52 |
| table.csv | 0.64 | - | - | - |
| logs.jsonc | 1.81 | - | - | - |
| logs.json5 | 1.22 | - | - | - |

| Look up one key | stury | yyjson | simdjson | sonic-rs |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 2.10 | 1.34 | 1.90 | 0.88 |
| citm_catalog.json | 3.17 | 2.45 | 2.95 | 1.58 |
| table.csv | 0.98 | - | - | - |
| logs.jsonc | 1.56 | - | - | - |
| logs.json5 | 1.61 | - | - | - |

simdjson builds both JSON fixtures 4 to 5% faster than stury, and reads every value of `logs.json` 25% faster. stury is
ahead on `citm_catalog.json`'s read and on both key lanes. yyjson and sonic-rs trail in every lane.

### JSON paths

ns per call, the arms as in the M5 set.

| The whole text read | scan | build_query | simd |
| --- | ---: | ---: | ---: |
| get early | 3,786,424 | 8,614,034 | 653,983 |
| get middle | 3,653,898 | 8,998,465 | 1,553,665 |
| get late | 3,886,307 | 7,993,328 | 2,090,084 |
| get absent | 3,906,350 | 8,662,761 | 2,065,667 |
| get last root key | 153,659 | 171,914 | 81,416 |

| The text read up to the answer | stop | sonic |
| --- | ---: | ---: |
| get early | 226 | 39 |
| get middle | 1,984,074 | 2,228,157 |
| get late | 3,211,214 | 4,874,836 |
| get absent | 3,993,897 | 10,159,482 |
| get last root key | 155,186 | 327,749 |

| Path | scan | query |
| --- | ---: | ---: |
| .logs[].id | 5,737,310 | 2,214,160 |
| .logs[][] | 15,149,445 | 3,836,673 |
| .logs[-1] | 3,824,698 | 1,031,332 |
| .logs[-20] | 3,817,437 | 1,238,356 |
| five keys per record | 21,197,135 | 10,173,320 |

simdjson's `find_field` is ahead of the scan on every key here, 1.9 to 5.8 times, judging less. sonic-rs's `get` is
ahead on the early key, and stury's stopped scan on every other.

### JSON typed read

| Borrow | stury | serde_json | sonic-rs |
| --- | ---: | ---: | ---: |
| logs.json | 2.59 | 0.67 | 1.15 |
| twitter.json | 2.20 | 1.13 | 1.61 |
| citm_catalog.json | 3.45 | 1.53 | 2.04 |
| table.csv | 0.66 | - | - |
| text.csv | 0.95 | - | - |

| Copy | stury | serde_json | sonic-rs |
| --- | ---: | ---: | ---: |
| logs.json | 1.39 | 0.69 | 1.01 |
| twitter.json | 2.20 | 1.06 | 1.93 |
| citm_catalog.json | 3.48 | 1.23 | 2.53 |
| table.csv | 0.49 | - | - |
| text.csv | 0.64 | - | - |

### JSON records

| Judge, one thread | stury | simd | simd_od | serde_json | sonic-rs |
| --- | ---: | ---: | ---: | ---: | ---: |
| logs.ndjson | 2.95 | 2.15 | 4.00 | 1.52 | 0.69 |
| docs.ndjson | 0.48 | 0.74 | 1.54 | 0.58 | 0.46 |
| twitter.ndjson | 3.11 | 3.64 | 5.15 | 2.62 | 0.86 |

| Judge, threaded | stury, 6 threads | simd | simd_od |
| --- | ---: | ---: | ---: |
| logs.ndjson | 7.44 | 2.48 | 4.21 |
| docs.ndjson | 1.76 | 0.83 | 1.98 |
| twitter.ndjson | 8.17 | 3.94 | 5.21 |

| A document per record | stury | serde_json `Value` | sonic-rs `Value` |
| --- | ---: | ---: | ---: |
| logs.ndjson | 0.78 | 0.24 | 0.07 |
| docs.ndjson | 0.36 | 0.13 | 0.13 |
| twitter.ndjson | 2.52 | 0.22 | 0.44 |

| Frame CSV records | stury | simd-csv |
| --- | ---: | ---: |
| table.csv | 4.07 | 4.23 |
| text.csv | 3.83 | 2.31 |

On one thread simdjson's On-Demand skip, judging less, is ahead on all three files, its tape on `docs.ndjson` and
`twitter.ndjson`, and serde_json on `docs.ndjson`. Threaded, stury leads on `logs.ndjson` and
`twitter.ndjson`, and the On-Demand skip on `docs.ndjson`. simd-csv frames `table.csv` 4% faster.

### JSON writes

| Typed, compact | stury | yyjson | sonic-rs | serde_json |
| --- | ---: | ---: | ---: | ---: |
| logs.json | 3.69 | 0.77 | 2.02 | 1.39 |
| twitter.json | 3.81 | 1.77 | 3.57 | 1.34 |
| citm_catalog.json | 2.42 | 1.55 | 1.86 | 1.38 |
| canada.json | 0.79 | 0.53 | 0.93 | 1.22 |
| nested.json | 1.16 | 0.44 | 0.99 | 1.04 |
| wide.json | 0.071 | 0.068 | 0.105 | 0.100 |

| Document, compact | stury | yyjson | simdjson | simdjson minify | sonic-rs | serde_json |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| logs.json | 11.73 | 2.09 | 0.58 | 10.96 | 1.52 | 0.51 |
| twitter.json | 11.89 | 6.50 | 1.44 | 23.43 | 3.09 | 1.64 |
| citm_catalog.json | 10.53 | 8.50 | 2.79 | 19.55 | 2.65 | 2.51 |
| canada.json | 13.25 | 1.10 | 0.56 | 12.18 | 1.00 | 0.68 |
| pretty.json | 13.96 | 4.21 | 0.72 | 14.27 | 1.26 | 1.21 |
| utf8.json | 12.47 | 0.53 | 0.71 | 12.18 | 10.84 | 3.31 |
| escape.json | 11.50 | 0.84 | 0.41 | 12.47 | 0.51 | 0.29 |
| longtext.json | 12.47 | 3.45 | 0.77 | 13.41 | 12.60 | 3.27 |

stury writes a document ahead of every library that writes a value it holds, except sonic-rs on `longtext.json`, by 1%.
simdjson's minifier, which does not judge, is ahead on five files. serde_json and sonic-rs are ahead on the typed
`canada.json` and `wide.json`, and on the pretty writes every library is ahead on `wide.json`, the sorted map of 342,658
keys.

### Other formats: documents

| YAML build | stury | rapidyaml | libfyaml | libyaml | saphyr |
| --- | ---: | ---: | ---: | ---: | ---: |
| logs.yaml | 0.34 | 0.09 | 0.03 | 0.06 | 0.05 |
| twitter.yaml | 0.38 | 0.14 | 0.05 | 0.09 | 0.05 |
| citm.yaml | 0.18 | 0.07 | 0.02 | 0.05 | 0.03 |
| openapi-stripe.yaml | 0.42 | 0.13 | 0.06 | 0.08 | 0.06 |

| TOML build | stury | toml++ | toml11 | toml |
| --- | ---: | ---: | ---: | ---: |
| logs.toml | 0.33 | 0.04 | 0.002 | 0.06 |
| cargo-lock-zed.toml | 0.42 | 0.05 | 0.004 | 0.12 |
| uv-lock-airflow.toml | 0.44 | 0.06 | 0.008 | 0.12 |
| pyproject-airflow.toml | 0.45 | 0.07 | 0.008 | 0.18 |

| XML build | stury | pugixml_nv | quickxml_nv | libxml2 | roxmltree |
| --- | ---: | ---: | ---: | ---: | ---: |
| logs.xml | 0.74 | 0.45 | 0.41 | 0.08 | 0.18 |
| osm-beatty.xml | 0.85 | 0.75 | 1.05 | 0.08 | 0.23 |

| XML validate | stury | expat | libxml2 SAX | quickxml_nv |
| --- | ---: | ---: | ---: | ---: |
| logs.xml | 1.14 | 0.25 | 0.33 | 0.46 |
| osm-beatty.xml | 1.15 | 0.24 | 0.30 | 1.05 |

| logs.html | stury | lexbor | gumbo | html5ever |
| --- | ---: | ---: | ---: | ---: |
| build | 0.094 | 0.102 | 0.027 | 0.065 |
| read | 0.095 | 0.098 | 0.024 | 0.056 |
| key | 0.093 | 0.115 | 0.023 | 0.068 |

| CBOR build | stury | ciborium | minicbor | tinycbor | QCBOR | libcbor |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| logs.cbor | 2.52 | 0.22 | 0.47 | 0.57 | 0.91 | 0.28 |
| twitter.cbor | 2.59 | 0.22 | 0.57 | 0.55 | 1.02 | 0.28 |
| citm.cbor | 1.02 | 0.09 | 0.32 | 0.38 | 0.41 | 0.10 |

stury builds YAML, TOML, XML and CBOR faster than their libraries that judge the same, and is ahead of pugixml on both
XML files.
quickxml_nv, judging less, builds `osm-beatty.xml` 23% faster. lexbor is ahead on `logs.html` in all three lanes, by 3
to 24%.

### Other formats: paths

ns per call over the logs records, as in the M5 set.

| The whole text read | stury scan | stury build_query | other libraries |
| --- | ---: | ---: | --- |
| YAML early | 19,285,856 | 24,722,653 | rapidyaml build and query 100,935,759 |
| YAML late | 19,118,014 | 25,436,530 | rapidyaml build and query 101,453,560 |
| TOML early | 24,641,733 | 28,885,461 | toml++ 265,775,454 |
| TOML late | 25,648,166 | 33,983,594 | toml++ 285,434,979 |
| XML early | 9,436,462 | 13,991,404 | pugixml_nv 38,647,501 |
| XML late | 12,207,721 | 20,486,853 | pugixml_nv 44,345,781, quickxml_nv 27,219,676 |
| CBOR early | 2,885,777 | 5,036,201 |  |
| CBOR late | 2,421,569 | 6,099,915 | minicbor, stopping at the answer, 6,350,464 |
| HTML first cell | 101,024,838 | 101,937,033 | lexbor 88,847,763 |
| HTML last cell | 104,079,176 | 104,520,087 | lexbor 99,162,666 |

| The text read up to the answer | stury stop | other libraries |
| --- | ---: | --- |
| YAML early | 1,163 |  |
| TOML early | 5,890 |  |
| XML early | 845 | quickxml_nv 688,706 |
| CBOR early | 486 | minicbor 198 |
| HTML first cell | 99,026,347 |  |

lexbor is ahead on both HTML cells, and minicbor on the early CBOR field.

### Other formats: typed reads and writes

| Typed read, borrow | stury | other libraries |
| --- | ---: | --- |
| logs.yaml | 0.21 | serde_yaml_ng 0.04 |
| logs.toml | 0.18 | toml 0.06 |
| logs.xml | 0.33 | quickxml_nv 0.19 |
| logs.cbor | 1.49 | ciborium 0.35, minicbor 1.23 |

| Typed read, copy | stury | other libraries |
| --- | ---: | --- |
| logs.yaml | 0.20 | serde_yaml_ng 0.04 |
| logs.toml | 0.18 | toml 0.07 |
| logs.xml | 0.13 | quickxml_nv 0.17 |
| logs.cbor | 0.81 | ciborium 0.35, minicbor 0.71 |

| Typed write | stury | other libraries |
| --- | ---: | --- |
| logs.yaml | 0.41 | rapidyaml 0.22, serde_yaml_ng 0.07 |
| logs.toml | 0.50 | toml 0.55 |
| logs.xml | 0.29 | quick-xml 0.34 |
| logs.cbor | 2.90 | ciborium 2.23, minicbor 4.55, tinycbor 1.49 |

| Document write | stury | other libraries |
| --- | ---: | --- |
| logs.yaml | 0.41 | rapidyaml 0.96, serde_yaml_ng 0.07 |
| logs.toml | 0.57 | toml++ 0.15, toml 0.31 |
| logs.xml | 2.08 | pugixml 1.34, quick-xml 0.41 |
| logs.cbor | 2.26 | ciborium 1.31, minicbor 1.85 |
| logs.html | 0.07 | lexbor 0.27, html5ever 0.26 |

stury reads every format into a type faster than its libraries, except quick-xml when the XML strings are copied. The
writes trail on the TOML, XML and CBOR typed writes and on the YAML and HTML documents.

### Other formats: records

| Judge, one thread | stury | other libraries |
| --- | ---: | --- |
| logs.seq.cbor | 2.49 | ciborium 0.34, minicbor 1.09 |
| k8s-prometheus-operator.yaml | 0.86 | libyaml 0.18 |
| k8s-argo-cd.yaml | 0.66 | libyaml 0.18 |

| A document per record | stury | other libraries |
| --- | ---: | --- |
| logs.seq.cbor | 0.71 | ciborium `Value` 0.22 |
| k8s-prometheus-operator.yaml | 0.33 | rapidyaml 0.24, libyaml 0.15 |
| k8s-argo-cd.yaml | 0.30 | rapidyaml 0.18, libyaml 0.10 |

### Edits

| Edit | stury | other libraries |
| --- | ---: | --- |
| logs.json | 0.96 |  |
| twitter.json | 1.52 |  |
| table.csv | 0.48 |  |
| logs.json5 | 0.88 |  |
| logs.yaml | 0.20 |  |
| logs.toml | 0.17 | toml_edit 0.12 |
| logs.xml | 0.67 |  |
| logs.html | 0.09 | lol_html 0.13 |

lol_html is 37% ahead on HTML, and stury 39% ahead of toml_edit.

### JSON Schema

| Verdict | stury | Blaze | jsonschema-rs | boon |
| --- | ---: | ---: | ---: | ---: |
| geojson | 0.51 | 0.11 | 0.16 | 0.06 |
| openapi | 0.17 | 0.23 | 0.21 | 0.14 |
| draft-04 | 0.41 | 0.22 | 0.20 | 0.14 |
| cmake-presets | 0.19 | 0.16 | 0.07 | 0.02 |
| ui5-manifest | 0.10 | 0.11 | 0.14 | - |
| helm-chart-lock | 0.57 | 0.23 | 0.28 | 0.23 |
| cspell | 0.41 | 0.20 | 0.16 | - |
| deno | 0.72 | 0.20 | 0.29 | 0.24 |
| code-climate | 0.48 | 0.13 | 0.13 | 0.14 |
| pulumi | 0.40 | 0.17 | 0.21 | 0.17 |
| aws-cdk | 1.49 | 0.32 | 0.26 | 0.24 |
| ansible-meta | 0.13 | 0.12 | 0.13 | 0.03 |
| clang-format | 0.35 | 0.23 | 0.21 | 0.17 |
| babelrc | 0.40 | 0.12 | 0.16 | 0.11 |
| krakend | - | 0.14 | 0.16 | 0.12 |
| logs | 0.52 | 0.30 | 0.36 | 0.23 |
| twitter | 0.57 | 0.19 | 0.16 | 0.15 |
| citm | 0.77 | 0.17 | 0.12 | 0.11 |
| applicator | 0.04 | 0.07 | 0.08 | 0.04 |
| logs.yaml | 0.18 | - | 0.03 | 0.03 |
| logs.toml | 0.16 | - | 0.05 | 0.05 |
| logs.cbor | 0.50 | - | 0.11 | 0.09 |
| logs.xml | 0.28 | - | 0.07 | - |
| geomean over Blaze | 2.04 | 1.00 | 1.01 | 0.66 |

The refusals are as in the M5 set. Blaze and jsonschema-rs are ahead on `openapi`, `ui5-manifest` and `applicator`.

### Models

|  | stury | pydantic | msgspec | garde |
| --- | ---: | ---: | ---: | ---: |
| load valid, logs | 0.36 | 0.09 | 0.15 | 0.12 |
| load valid, twitter | 0.86 | 0.37 | 0.56 | 0.58 |
| load invalid, every failure, logs | 0.22 | 0.06 | - | 0.13 |
| load invalid, every failure, twitter | 0.81 | 0.26 | - | 0.56 |
| load invalid, first failure, logs | 0.42 | - | 0.20 | - |
| load invalid, first failure, twitter | 0.92 | - | 0.87 | - |
| dump, logs | 0.90 | 0.21 | 0.61 | 0.82 |
| dump, twitter | 1.90 | 0.28 | 1.46 | 1.26 |

stury leads every row.

### Command line

The jq suite:

| Tool | cases | geomean × stury | min × stury | answer differs |
| --- | ---: | ---: | ---: | ---: |
| jq | 30 | 13.41 | 3.98 | 0 |
| jaq | 30 | 7.62 | 2.23 | 0 |
| gojq | 30 | 11.83 | 4.18 | 0 |
| yq | 11 | 56.36 | 13.78 | 0 |

The closest cases to jaq are `twitter_select` (2.23×), `twitter_pretty` (2.55×) and `twitter_names` (2.70×).

The other suites:

| Suite | Tool | cases | geomean × stury | min × stury | answer differs |
| --- | --- | ---: | ---: | ---: | ---: |
| csv | jq | 2 | 39.37 | 16.12 | 0 |
| csv | Miller | 4 | 14.93 | 9.19 | 0 |
| xml | xmllint | 6 | 4.28 | 0.97 | 0 |
| xml | xmlstarlet | 7 | 7.58 | 1.44 | 0 |
| xml | yq | 7 | 43.23 | 10.66 | 0 |
| toml | dasel | 6 | 7.15 | 3.59 | 0 |
| toml | yq | 4 | 1449.93 | 21.99 | 1 |
| yaml | dasel | 7 | 20.37 | 11.08 | 0 |
| yaml | yq | 10 | 15.11 | 5.43 | 0 |
| html | htmlq | 2 | 2.19 | 2.17 | 0 |
| html | pup | 2 | 1.93 | 1.90 | 0 |

xmllint is 1.03 times faster than stury on `xml_osm_user_raw`, one attribute of a 380 KB file, where process start is
most of the time. yq differs on `toml_pyproject_json` as in the M5 set, and has no arm on `logs.toml`.

## Running

```sh
make fixtures      # fetch the pinned corpus and sources, generate the synthetic files
make bench-doc     # the document lanes
make bench-records ROUNDS=3
```

`ROUNDS` sets the interleaved rounds and `ROWS` the rows (`bench/README.md` lists what each target takes). The harness
needs Odin, uv, CMake with a C and a C++ compiler, Cargo and Python 3.11 or later. The command line comparisons also
need hyperfine and the tools they compare. A comparison whose tool is missing says so and leaves it out.
