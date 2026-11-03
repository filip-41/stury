# next/

The rebuilt library: a JSON and delimited-text reader, document, path reader and editor in Odin, built layer by layer. It builds,
tests and benchmarks on its own and imports nothing outside this directory.

## Packages

| Package | Holds |
|---|---|
| `core/spell` | the number decoders and their tables, the byte decode and compare helpers, and number text: shortest floats and integers |
| `core` | what every format shares: the token, hook and fault types, error rendering, `Number` and its bounds, the document, its readers, the edit list, paths and their answers |
| `host` | `Pool`, the threads a caller keeps between parallel calls and lends through `core.Runner` (nil means the caller's thread alone): helpers wake in a tree, a task nobody has started is taken back, and each task's width is learned from how long the caller waits |
| `core/kernel` | vector code: 64-byte blocks, byte classes, masks, escapes, UTF-8 validation, per CPU tier |
| `core/build` | the builder: the hooks that write a document, its reservation, the duplicate-key check, and the path engine |
| `core/typed` | the typed read: the type plan, the read's hook, refusal and collection, for any format |
| `core/write` | the output a written text goes into, a buffer that grows or one flushed to a stream, and the typed write over a type plan and the token write |
| `json` | the JSON walk for the `Json`, `Jsonc` and `Json5` specs, its `build`, its path reads, `unmarshal` and its spelling and edit services |
| `dsv` | the delimited-text walk for the `Csv`, `Tsv` and `Plain` specs, its `build`, its path reads and its spelling and edit services |
| `walktest` | helpers the test packages share |

Imports point down: `host` imports `core` only, `core/spell` imports no package of this tree, `core` imports `core/spell`, `core/kernel`,
`core/build` and `core/typed` import `core`, `core/write` imports `core`, `core/spell` and `core/typed`, `json` and `dsv` import all of
them, and no format imports another.

## Docs

| File | Describes |
|---|---|
| `docs/kernel.md` | `core/kernel`: the split by architecture and x86-64 tier, and the Odin and LLVM behaviour behind it |
| `docs/walk.md` | the walk interface every format shares, the JSON and dsv walks, faults and tolerances |
| `docs/document.md` | the document: nodes, building, readers, spelling services, duplicate keys, facts, edits, errors, limits |
| `docs/paths.md` | the path layer: path steps, reading paths, the `Answer` record, the engine and the container-close decision |
| `docs/typed.md` | the typed read: the plan, the entries, field and type rules, who owns a string, refusal and collecting, what a format gives, limits |
| `docs/writer.md` | the writer, layer by layer: number text, the output and its stream flush, `Write_Options`, the typed write, the document write, the token write, and the errors a write returns |
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
core.write_code :: proc {write_fault_code, write_document_code, write_path_code, write_edit_code, write_typed_code}
core.render     :: proc {render_fault, render_document, render_path, render_edit, render_typed}
write.init      :: proc(out: ^write.Out, spill: ^[write.ROOM_MAX]u8, allocator := context.allocator, stream := io.Stream{}, hint := 0)
write.room      :: proc(out: ^write.Out, n: int) -> [^]u8
write.finish    :: proc(out: ^write.Out) -> (bytes: []u8, err: core.Typed_Error)
write.destroy   :: proc(out: ^write.Out)
write.tokens_init   :: proc(t: ^write.Tokens, as: core.As, opts := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind
write.tokens_finish :: proc(t: ^write.Tokens) -> (bytes: []u8, err: core.Typed_Error)
write.open_object, write.open_array, write.close :: proc(t: ^write.Tokens) -> core.Typed_Error_Kind
write.key, write.value_string :: proc(t: ^write.Tokens, s: string) -> core.Typed_Error_Kind
write.value_int, write.value_uint, write.value_float, write.value_bool, write.value_null, write.end_record // a value each, and a delimited record's end
core.write        :: proc(doc: ^core.Document, opts := core.Write_Options{}, as: Maybe(core.As) = nil, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Typed_Error)
core.write_stream :: proc(w: io.Stream, doc: ^core.Document, opts := core.Write_Options{}, as: Maybe(core.As) = nil, allocator := context.allocator) -> (dropped: int, err: core.Typed_Error)
json.as           :: proc(spec: json.Spec) -> core.As
dsv.as            :: proc(spec: dsv.Spec, layout := dsv.Options{}) -> core.As
json.format       :: proc(src: []u8, $S: json.Spec, opts := core.Write_Options{}, read := json.Options{}, allocator := context.allocator) -> ([]u8, core.Typed_Error)
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
core.query         :: proc {query_one, query_many} // path: core.Path or paths: []core.Path
json.set           :: proc(src: []u8, $S: json.Spec, path: core.Path, text: string, read := core.Query_Options{}, opts := json.Options{}, refuse_duplicates := false, allocator := context.allocator) -> (out: []u8, err: core.Path_Edit_Error)
```

`render` and `write_code` take a path error with the source and the path's text, so a caller never picks which text a
`Path_Error.at` belongs to. The exact signatures of the path procs are in [docs/paths.md](docs/paths.md).

`text` never allocates and returns false when `buf` is too short. `text_clone` always allocates, and the caller frees
its result with `delete(s, allocator)`. `float_value` reads `Int`, `Uint` and `Float`, and returns false for `Wide`.
A delimited text commits only through `core.commit`, in the document's own spec. The exact
signatures and every error kind are in [docs/document.md](docs/document.md).

The typed read, in `json` and `dsv`, and the plan it reads by, whose exact options are in [docs/typed.md](docs/typed.md):

```odin
json.unmarshal     :: proc {unmarshal_once, unmarshal_plan} // with or without plan: ^typed.Plan
json.plan_make     :: proc(T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (typed.Plan, core.Typed_Error)
dsv.unmarshal      :: proc {unmarshal_once, unmarshal_plan} // the same, for a list of rows
dsv.plan_make      :: proc(T: typeid, spec: dsv.Spec, layout := dsv.Options{}, opts := typed.Plan_Options{}, allocator := context.allocator) -> (typed.Plan, core.Typed_Error)
typed.plan_destroy :: proc(p: ^typed.Plan)
```

A built document or a path's answer is read by one call for every format, which borrows `doc.src` and nothing else of the document:

```odin
typed.unmarshal :: proc {unmarshal_node, unmarshal_answer} // (doc, node or answer, target, plan, read, allocator)
```

## Make targets

Run from `next/`. `ODIN` names the compiler, as in `make ODIN=/path/to/odin test`.

| Target | Runs |
|---|---|
| `check` | the edit loop: lint, size and each test package at `-o:minimal`, skipping what the diff cannot reach |
| `gate` | what a branch passes before it lands: `check`, then `-o:speed`, the private suites, sanitizer, x86, oracles and golden, skipping the same way |
| `test` | every public test package at `-o:minimal`, then again at `-o:speed`, as one target per compile so `make -j` runs them in parallel, the golden answers included |
| `test-asan` | the test packages under the address sanitizer |
| `test-f32` | every binary32 pattern written, read back and checked shortest, on `F32_THREADS` threads; `gate full` runs it |
| `test-x86` | the tests for x86-64 tiers v2 and v3, at `-o:none` and `-o:speed`, under Rosetta on Apple silicon |
| `lint` | the import order and vet with the unused-import flag on the host, x86-64 and riscv64, and the v4 kernel tests as objects |
| `size` | the lean lines of each library package, their sum and the 18,500 budget, and a failure past it |
| `surface` | each library package's public declarations, sorted, for a review to diff |
| `bench` | the kernel and number-text timings, with `TIER` and `ROUNDS` |
| `fixtures` | fetches the pinned corpus and the other libraries' sources, and generates the synthetic fixtures |
| `bench-doc` | the document lanes (build, read, key) beside yyjson, simdjson and sonic-rs, with `ROUNDS` and `BENCH_FILES` |
| `bench-paths` | the path lanes beside the peers `bench-doc` built, with `ROUNDS` |
| `bench-typed` | the typed read's lanes, strings borrowed and copied, beside the old tree where a checkout holds it, with `ROUNDS` |

`check` and `gate` run `tools/gate.py`. Each check's key hashes the compiler, its command, the Makefile, and every file
its packages import for its target with comments dropped, plus what they `#load`. A key that passed is stamped under the
git common directory, so worktrees share stamps and a merge reruns nothing its branch ran. A comment edit reruns no test,
an edit under `dsv/` reruns no JSON suite, and an edit to `arm64.odin` reruns no x86 check. `python3 tools/gate.py full`
adds the long randomized runs, `--seed N` a fresh seed, `--list` prints what would run, and `--force` ignores the stamps.

The checks that compare this tree with the old one live in `../compare/` and go with the old tree.

The value and edit models, the randomized laws at their stress counts, and the timing and scale tests are private, in
the separate stury test repository beside this one. Its `next-model`, `next-laws` and `next-perf` targets run them
against this tree.
