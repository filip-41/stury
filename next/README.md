# next/

The rebuilt library: a JSON and delimited-text reader, document and editor in Odin, built layer by layer. It builds,
tests and benchmarks on its own and imports nothing outside this directory.

## Packages

| Package | Holds |
|---|---|
| `core/spell` | the number decoders and their tables, and the byte decode and compare helpers |
| `core` | what every format shares: the token, hook and fault types, error rendering, `Number` and its bounds, the document, its readers, the edit list |
| `core/kernel` | vector code: 64-byte blocks, byte classes, masks, escapes, UTF-8 validation, per CPU tier |
| `core/build` | the builder: the hooks that write a document, its reservation, the duplicate-key check |
| `json` | the JSON walk for the `Json`, `Jsonc` and `Json5` specs, its `build` and its spelling and edit services |
| `dsv` | the delimited-text walk for the `Csv`, `Tsv` and `Plain` specs, its `build` and its spelling and edit services |
| `walktest` | helpers the test packages share |

Imports point down: `core/spell` imports no package of this tree, `core` imports `core/spell`, `core/kernel` and
`core/build` import `core`, `json` and `dsv` import all four, and no format imports another.

## Docs

| File | Describes |
|---|---|
| `docs/kernel.md` | `core/kernel`: the split by architecture and x86-64 tier, and the Odin and LLVM behaviour behind it |
| `docs/walk.md` | the walk interface every format shares, the JSON and dsv walks, faults and tolerances |
| `docs/document.md` | the document: nodes, building, readers, spelling services, duplicate keys, facts, edits, errors, limits |
| `docs/hotpaths.md` | the places the code keeps two instances or two copies of one piece of work for speed, with the lane and the measured win |
| `bench/README.md` | the document lanes, their fixtures and the other libraries they run beside; the kernel bench is `bench/run.py` |

The places where the code keeps two instances or two copies of one piece of work for speed, with the lane and the
measured win, are listed in [docs/hotpaths.md](docs/hotpaths.md).

## Make targets

Run from `next/`. `ODIN` names the compiler, as in `make ODIN=/path/to/odin test`.

| Target | Runs |
|---|---|
| `test` | every public test package at `-o:minimal`, then again at `-o:speed`, as one target per compile so `make -j` runs them in parallel, the golden answers included |
| `test-asan` | the test packages under the address sanitizer |
| `test-x86` | the tests for x86-64 tiers v2 and v3, at `-o:none` and `-o:speed`, under Rosetta on Apple silicon |
| `lint` | the import order and vet with the unused-import flag on the host, x86-64 and riscv64, and the v4 kernel tests as objects |
| `size` | the lean lines of each library package, their sum and the 13,000 budget, and a failure past it |
| `surface` | each library package's public declarations, sorted, for a review to diff |
| `bench` | the kernel timings, with `TIER` and `ROUNDS` |
| `fixtures` | fetches the pinned corpus and the other libraries' sources, and generates the synthetic fixtures |
| `bench-doc` | the document lanes (build, read, key) beside yyjson, simdjson and sonic-rs, with `ROUNDS` and `BENCH_FILES` |

The checks that compare this tree with the old one live in `../compare/` and go with the old tree.

The value and edit models, the randomized laws at their stress counts, and the timing and scale tests are private, in
the separate stury test repository beside this one. Its `next-model`, `next-laws` and `next-perf` targets run them
against this tree.
