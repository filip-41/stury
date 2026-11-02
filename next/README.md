# next/

The rebuilt library: a JSON and delimited-text reader, document, path reader and editor in Odin, built layer by layer. It builds,
tests and benchmarks on its own and imports nothing outside this directory.

## Packages

| Package | Holds |
|---|---|
| `core/spell` | the number decoders and their tables, and the byte decode and compare helpers |
| `core` | what every format shares: the token, hook and fault types, error rendering, `Number` and its bounds, the document, its readers, the edit list, paths and their answers |
| `core/kernel` | vector code: 64-byte blocks, byte classes, masks, escapes, UTF-8 validation, per CPU tier |
| `core/build` | the builder: the hooks that write a document, its reservation, the duplicate-key check, and the path engine |
| `json` | the JSON walk for the `Json`, `Jsonc` and `Json5` specs, its `build`, its path reads and its spelling and edit services |
| `dsv` | the delimited-text walk for the `Csv`, `Tsv` and `Plain` specs, its `build`, its path reads and its spelling and edit services |
| `walktest` | helpers the test packages share |

Imports point down: `core/spell` imports no package of this tree, `core` imports `core/spell`, `core/kernel` and
`core/build` import `core`, `json` and `dsv` import all four, and no format imports another.

## Docs

| File | Describes |
|---|---|
| `docs/kernel.md` | `core/kernel`: the split by architecture and x86-64 tier, and the Odin and LLVM behaviour behind it |
| `docs/walk.md` | the walk interface every format shares, the JSON and dsv walks, faults and tolerances |
| `docs/document.md` | the document: nodes, building, readers, spelling services, duplicate keys, facts, edits, errors, limits |
| `docs/paths.md` | the path layer: path steps, reading paths, the `Answer` record, the engine and the container-close decision |
| `docs/hotpaths.md` | the places the code keeps two instances or two copies of one piece of work for speed, with the lane and the measured win |
| `bench/README.md` | the document lanes, their fixtures and the other libraries they run beside; the kernel bench is `bench/run.py` |

## API

The readers and writers a caller names:

```odin
core.text       :: proc(doc: ^core.Document, i: core.Node_Index, buf: []u8) -> (s: string, ok: bool)
core.text_clone :: proc(doc: ^core.Document, i: core.Node_Index, allocator := context.allocator) -> (s: string, ok: bool)
core.float_value :: proc(doc: ^core.Document, i: core.Node_Index) -> (f64, bool)
core.commit     :: proc(list: ^core.Edit_List, allocator := context.allocator) -> (out: []u8, dropped: int, err: core.Document_Error)
json.text       :: proc(doc: ^core.Document, i: core.Node_Index, buf: []u8) -> (s: string, ok: bool)
json.number     :: proc(doc: ^core.Document, i: core.Node_Index) -> core.Number
json.commit     :: proc(list: ^core.Edit_List, as: json.Spec, allocator := context.allocator) -> (out: []u8, dropped: int, err: core.Document_Error)
dsv.commit      :: proc(list: ^core.Edit_List, as: dsv.Spec, allocator := context.allocator) -> (out: []u8, dropped: int, err: core.Document_Error)
core.write_code :: proc {write_fault_code, write_document_code, write_path_code, write_edit_code}
core.render     :: proc {render_fault, render_document, render_path, render_edit}
```

The path procs, in `json` and in `dsv` with `dsv.Spec` and `dsv.Options`:

```odin
core.parse_path    :: proc(text: string, allocator := context.allocator) -> (path: core.Path, err: core.Path_Error)
core.parse_pointer :: proc(text: string, allocator := context.allocator) -> (path: core.Path, err: core.Path_Error)
core.path_destroy  :: proc(p: ^core.Path)
core.member_of     :: proc(doc: ^core.Document, obj: core.Node_Index, name: string, dups := core.Duplicates.Last) -> (core.Node_Index, core.Presence)
core.element_of    :: proc(doc: ^core.Document, c: core.Node_Index, k: int) -> (core.Node_Index, core.Presence)
core.length_exact  :: proc(doc: ^core.Document, i: core.Node_Index) -> (n: int, exact: bool)
json.scan          :: proc {scan_one, scan_many} // paths: core.Path or []core.Path
json.find          :: proc(src: []u8, $S: json.Spec, path: core.Path, read := core.Path_Options{}, opts := json.Options{}, allocator := context.allocator) -> (doc: core.Document, answer: Maybe(core.Answer), err: core.Path_Error)
json.each_answer   :: proc {each_answer_one, each_answer_many} // path: core.Path or paths: []core.Path
json.query         :: proc {query_one, query_many} // path: core.Path or paths: []core.Path
json.set           :: proc(src: []u8, $S: json.Spec, path: core.Path, text: string, read := core.Query_Options{}, opts := json.Options{}, refuse_duplicates := false, allocator := context.allocator) -> (out: []u8, err: core.Path_Edit_Error)
```

`render` and `write_code` take a path error with the source and the path's text, so a caller never picks which text a
`Path_Error.at` belongs to. The exact signatures of the path procs are in [docs/paths.md](docs/paths.md).

`text` never allocates and returns false when `buf` is too short. `text_clone` always allocates, and the caller frees
its result with `delete(s, allocator)`. `float_value` reads `Int`, `Uint` and `Float`, and returns false for `Wide`.
`dsv.commit` writes only the document's own spec and refuses another with `.Bad_Spec` before the splice. The exact
signatures and every error kind are in [docs/document.md](docs/document.md).

## Make targets

Run from `next/`. `ODIN` names the compiler, as in `make ODIN=/path/to/odin test`.

| Target | Runs |
|---|---|
| `test` | every public test package at `-o:minimal`, then again at `-o:speed`, as one target per compile so `make -j` runs them in parallel, the golden answers included |
| `test-asan` | the test packages under the address sanitizer |
| `test-x86` | the tests for x86-64 tiers v2 and v3, at `-o:none` and `-o:speed`, under Rosetta on Apple silicon |
| `lint` | the import order and vet with the unused-import flag on the host, x86-64 and riscv64, and the v4 kernel tests as objects |
| `size` | the lean lines of each library package, their sum and the 15,300 budget, and a failure past it |
| `surface` | each library package's public declarations, sorted, for a review to diff |
| `bench` | the kernel timings, with `TIER` and `ROUNDS` |
| `fixtures` | fetches the pinned corpus and the other libraries' sources, and generates the synthetic fixtures |
| `bench-doc` | the document lanes (build, read, key) beside yyjson, simdjson and sonic-rs, with `ROUNDS` and `BENCH_FILES` |
| `bench-paths` | the path lanes beside the peers `bench-doc` built, with `ROUNDS` |

The checks that compare this tree with the old one live in `../compare/` and go with the old tree.

The value and edit models, the randomized laws at their stress counts, and the timing and scale tests are private, in
the separate stury test repository beside this one. Its `next-model`, `next-laws` and `next-perf` targets run them
against this tree.
