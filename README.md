# stury

stury is a JSON and CSV library for [Odin](https://odin-lang.org), with a command line, `stury`, that runs jq
filters over JSON and CSV, checks them against JSON Schema, edits them in place and tells what differs between two
of them.

Input is checked strictly by default: JSON against RFC 8259 (no `01`, no `NaN`, no invalid UTF-8, no lone
surrogate), CSV against RFC 4180.

**Status:** pre-1.0. The API may still change between releases. Models, JSON Schema, the value diff, the regex
package and the command line's `edit`, `diff` and `schema` are not in a release yet: [CHANGELOG.md](CHANGELOG.md)
lists them under Unreleased.

## Features

The library:

- **Validate** JSON without allocating, with the line and column of the first fault.
- **Read one value by path** (`.tags[1]`) without parsing the rest of the input, or answer several paths in
  one pass.
- **Decode into Odin types and encode them back** (`unmarshal`, `marshal`): structs, slices, maps, unions,
  bit sets and `core.Value`, from the type alone, and `any` as an encode source. Field tags and hooks cover custom
  names and types.
- **Models**: rules on an Odin type (bounds, lengths, patterns, formats, defaults, read-only and write-only members,
  validators). A load gathers every refusal, which `model.problem` turns into an RFC 9457 problem document, a patch
  changes only the members it holds, and a dump writes the value back by the same rules.
- **JSON Schema**, drafts 4 to 2020-12: check a text, or its records on threads, and get every failure with its
  position, path and keyword. Infer a schema from values, sample values that pass or fail one, compare two schemas
  with a proof or a value that one takes and the other refuses, and write the Odin types a model reads a schema's
  values with.
- **Diff two values** of any format, with arrays matched as sequences, as sets, by position or by a member.
- **Build a document** and query it by path, with strings that point into the input.
- **Edit a text**: change, insert, move or remove a value and keep every other byte, formatting and comments
  included.
- **JSONC, JSON5, NDJSON and RFC 7464** text sequences, with comments kept and written back.
- **CSV, TSV and other delimited text** through the same struct mapping, models, schema checks, documents and edits
  as JSON, with options for the delimiter, comment lines and files without a header.
- **One interface for every format.** A format is a `Spec` passed to the same calls, and every call returns one
  error union.
- **Regular expressions** in Oniguruma's syntax for jq's functions and in ECMA-262's for a schema's `pattern`, with
  Unicode 17.0 character properties and case folds. A choice inside a loop, as in `(a+)+$`, runs in time linear in
  the text.
- **Optional threads**: process records in parallel on a `stury:host` pool. The library starts no thread and
  keeps no global state.

The command line:

- It runs jq 1.8 filters with jq's answers and exit codes, and reports faults with their line and column.
- It reads and writes JSONC, NDJSON, CSV and TSV, and reads JSON5.
- It validates without running a filter (`stury check`), against a JSON Schema too (`check --schema`), and types a
  filter against the schema of its inputs (`check --filter`).
- It formats or transcodes files (`stury fmt`), through a schema too (`fmt --schema`).
- It edits a file with a jq filter and keeps every byte the filter does not change (`stury edit`).
- It tells the changes between two files or two schemas (`stury diff`).
- It infers a schema, samples values from one, or writes Odin types for one (`stury schema infer`, `sample`, `gen`).

## Install

**Library.** stury needs [Odin](https://odin-lang.org/docs/install/) `dev-2026-11` or later, and a 64-bit
little-endian target (darwin or linux, amd64 or arm64, and the command line also builds on Windows). Clone it into
your project and add it as a collection:

```sh
git clone https://github.com/filip-41/stury vendor/stury
odin build . -collection:stury=vendor/stury -o:speed
```

Then `import "stury:json"`, and `import "stury:dsv"` for delimited text. Each exports the names of `core`, `typed`,
`write`, `records`, `schema` and `host` that a program calls, the schema check included. Models are
`import model "stury:core/model"`, and schema inference, sampling and comparison are `stury:core/schema`. Keep the
package directories together. For the [ols](https://github.com/DanielGavin/ols) language server, add the same
collection to `ols.json`: `{"collections": [{"name": "stury", "path": "vendor/stury"}]}`.
`Unknown library collection: 'stury'` means the build was not given `-collection:stury=<path>`.

**Command line.** Download `stury-VERSION-OS-ARCH.tar.gz` (OS `linux` or `darwin`, ARCH `amd64` or `arm64`) from
[GitHub Releases](https://github.com/filip-41/stury/releases), unpack it and put `stury` on your `PATH`. The manual
page is `docs/stury.1` in the archive. There is no Windows binary: the command line builds there from source. A release
binary holds only what that release has, so the unreleased commands above need a build from source: `make build-cli`
writes `build/stury`.

## Quick start

```odin
package main

import "stury:json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

Person :: struct {
	name: string,
	n:    i64,
}

// A fault or an error renders as `line:col: message`, with the path when it has one.
report :: proc(src: []u8, e: json.Error) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	json.render(strings.to_writer(&b), src, e)
	fmt.eprintln(strings.to_string(b))
}

main :: proc() {
	src := transmute([]byte)string(`{"name":"ada","n":1}`)
	if len(os.args) > 1 {
		data, rerr := os.read_entire_file(os.args[1], context.allocator)
		if rerr != nil {
			os.print_error(os.stderr, rerr, os.args[1])
			os.exit(1)
		}
		src = data
	}
	if err := run(src); err != nil {
		report(src, err)
		os.exit(1)
	}
}

run :: proc(src: []u8) -> json.Error {
	json.validate(src, .Json) or_return

	// What the read and the write allocate, freed at once.
	arena: virtual.Arena
	virtual.arena_init_growing(&arena) or_return
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	person: Person
	json.unmarshal(src, .Json, &person, allocator = alloc) or_return
	out := json.marshal(person, allocator = alloc) or_return
	fmt.println(string(out)) // {"name":"ada","n":1}
	return nil
}
```

This is [examples/quickstart](examples/quickstart/main.odin). Run it from this directory with
`odin run examples/quickstart -collection:stury=.`, or add `-- file.json` to read a file in place of the built-in text.
Every call that can fail returns a `json.Error`, so `or_return` passes a fault, a refused allocation or a refused read
up alike.

## Examples

The snippets below run inside a procedure that returns `json.Error` (`dsv.Error` for CSV, `core.Error` for a model,
the same union), with `stury:core`, `stury:core/model`, `stury:core/typed`, `stury:core/schema` and
`stury:core/diff` imported where a snippet names them.

Read one value by path. The answer is a node of a small document that borrows `src`:

```odin
src := transmute([]u8)string(`{"name": "ada", "tags": ["math", "engines"]}`)
second_tag := json.parse_path(".tags[1]") or_return
defer json.destroy(&second_tag)
doc, answer := json.find(src, .Json, second_tag) or_return
defer json.destroy(&doc)
if answer.outcome == .Found {
	fmt.println(string(json.span(&doc, answer.node))) // "engines"
}
```

Change one value and keep every other byte:

```odin
src := transmute([]u8)string(`{"name": "ada",  "tags": ["math"]}`)
name := json.parse_path(".name") or_return
defer json.destroy(&name)
out := json.set(src, .Json, name, "grace") or_return
defer delete(out)
fmt.println(string(out)) // {"name": "grace",  "tags": ["math"]}
```

Read CSV rows into structs by the header's column names:

```odin
City :: struct {
	name:       string `csv:"City"`,
	population: Maybe(i64),
}

src := transmute([]u8)string("City,population\nOslo,709000\nAtlantis,\n")
cities: []City
dsv.unmarshal(src, .Csv, &cities, allocator = context.temp_allocator) or_return
fmt.println(cities[1].name, cities[1].population) // Atlantis nil
```

Read request bodies into a model, answer a refused one with a problem document, apply a patch and write the value
back. `json.checks(.Json)` gives the model the format it reads, and `dsv.checks(.Csv)` would read CSV rows by the
same rules. From [examples/model](examples/model/main.odin):

```odin
User :: struct {
	id:    i64 `model:"read_only"`,
	name:  string `model:"len>=2"`,
	email: Maybe(string) `model:"optional"`,
	role:  string `model:"optional"`,
	set:   model.Fields_Set,
}

reg: model.Registry
model.register(&reg, User, "role", "member") or_return
m := model.compile(&reg, User, json.checks(.Json)) or_return

// Every refusal of a body, gathered by the sink, as one RFC 9457 document.
bad: User
sink: typed.Sink
if model.load(&m, transmute([]u8)string(`{"name": "a", "email": 3}`), &bad, &sink) != nil {
	p := model.problem(sink.entries[:], "Invalid body", 422) or_return
	fmt.println(string(json.marshal(p) or_return))
}

user: User
model.load(&m, transmute([]u8)string(`{"name": "ada", "email": "ada@example.org"}`), &user) or_return
user.id = 1
fmt.println(string(model.dump(&m, &user) or_return)) // {"id":1,"name":"ada","email":"ada@example.org","role":"member"}

// A patch changes only the members it holds, and the merged value is judged whole.
model.patch(&m, &user, transmute([]u8)string(`{"email": null, "role": "admin"}`)) or_return
fmt.println(string(model.dump(&m, &user, {exclude_none = true}) or_return)) // {"id":1,"name":"ada","role":"admin"}
```

The problem document it prints for the refused body:

```json
{"title":"Invalid body","status":422,"errors":[{"pointer":"/name","code":"too_short","message":"String is too short, at least 2 characters"},{"pointer":"/email","code":"wrong_kind","message":"Value does not fit the field's type, expected string"}]}
```

`Dump_Opts` leaves out the members a load did not set (`exclude_unset`), that hold null (`exclude_none`) or that
equal their default (`exclude_defaults`). `model.schema(&m, .Load)` describes what a load takes, which `schema.write`
writes as JSON Schema.

Check a text against a JSON Schema. The schema is compiled once and bound to the format its inputs are read as, and
the sink gathers every failure:

```odin
schema_text := transmute([]u8)string(`{"properties": {"age": {"type": "integer", "minimum": 0}}}`)
s := json.load_schema(schema_text) or_return
defer json.destroy(s)
b := json.bind_schema(s, .Json) or_return
defer json.destroy(&b)

src := transmute([]u8)string(`{"age": -1}`)
sink := json.Sink{max_errors = 20}
defer json.destroy(&sink)
if json.check_schema(&b, src, &sink) != nil {
	for e in sink.entries {
		fmt.println(e.start, e.kind) // 8 Below_Minimum
	}
}
```

Compare two schemas, and diff two values:

```odin
v1 := json.load_schema(transmute([]u8)string(`{"properties": {"id": {"minimum": 0}}}`)) or_return
defer json.destroy(v1)
v2 := json.load_schema(transmute([]u8)string(`{"properties": {"id": {"minimum": 1}}}`)) or_return
defer json.destroy(v2)
c := schema.compare(v1.description, v2.description, {as = json.as(.Json)}) or_return
defer schema.comparison_destroy(&c)
fmt.println(c.old_in_new.verdict, c.old_in_new.witness) // No {"id":0}
fmt.println(c.new_in_old.verdict) // Yes

old := json.build(transmute([]u8)string(`{"port": 8080, "tags": ["x"]}`), .Json) or_return
defer json.destroy(&old)
new := json.build(transmute([]u8)string(`{"port": 9090, "tags": ["x", "y"]}`), .Json) or_return
defer json.destroy(&new)
r := diff.values(core.Node_Ref{&old, core.ROOT}, core.Node_Ref{&new, core.ROOT}) or_return
defer diff.result_destroy(&r)
for ch in r.changes {
	fmt.println(ch.op, ch.path) // Changed ["port"], then Added ["tags", 1]
}
```

The [library guide](docs/guide.md) covers each of these in full, with allocation and limits. The complete
programs are in [examples/](examples). Each prints a fixed answer, and `make test-examples` runs them all.

| Program | Shows |
| --- | --- |
| [quickstart](examples/quickstart/main.odin) | validate, `unmarshal`, `marshal` and error rendering |
| [scan](examples/scan/main.odin) | one value, or every value of a path, without building a whole document |
| [roundtrip](examples/roundtrip/main.odin) | building a document and querying it |
| [edit](examples/edit/main.odin) | changing a value in place, and several edits in one commit |
| [records](examples/records/main.odin) | NDJSON records, from a stream, and on threads |
| [jsonc](examples/jsonc/main.odin) | JSON with comments |
| [dsv](examples/dsv/main.odin) | CSV into structs and back, dialects, documents, edits, streaming |
| [crossformat](examples/crossformat/main.odin) | one struct read from CSV and JSON, with one error type |
| [model](examples/model/main.odin) | a model's load, problem document, patch and dump |

## Command line

`stury` runs [jq](https://jqlang.org) 1.8 filters with jq's results and exit codes. Input is strict JSON by
default, so `01`, `NaN` and invalid UTF-8 are errors, reported with their line and column. `--from` reads `json`,
`jsonc`, `json5`, `ndjson`, `csv` or `tsv`, and `--to` writes all of them but `json5`.

```sh
$ echo '{"logs":[{"id":1}]}' | stury -c '.logs[].id'
1
$ printf '{"foo": 01}' | stury check; echo $?
stury: parse error: <stdin>:1:10: Leading zero in a number
{"foo": 01}
         ^
5
$ cat cities.csv
city,country,population
Oslo,NO,709000
Stockholm,SE,984000
Bergen,NO,286000
$ stury --from csv --to csv 'select(.country == "NO") | {city, population}' cities.csv
city,population
Oslo,709000
Bergen,286000
```

`stury check` validates every file without printing and reports each file's first fault. `check --schema` also
judges each input against a JSON Schema and tells every failure with its position, path and keyword, exit 1.
`--report basic` writes the JSON Schema basic output and `--report problem` an RFC 9457 problem document. A CSV or
TSV table is checked as an array of its rows.

```sh
$ cat user.schema.json
{"type": "object", "properties": {"name": {"type": "string", "minLength": 2}, "age": {"type": "integer", "minimum": 0}}, "required": ["name"]}
$ cat users.ndjson
{"name": "ada", "age": 36}
{"name": "b", "age": -1}
{"age": "9"}
$ stury check --from ndjson --schema user.schema.json users.ndjson; echo $?
users.ndjson:2:10: String is too short, at least 2 characters at .name (.properties.name.minLength)
users.ndjson:2:22: Number is below the minimum, at least 0 at .age (.properties.age.minimum)
users.ndjson:3:1: Required member "name" is missing (.required)
users.ndjson:3:9: Value is not of the allowed type, expected integer at .age (.properties.age.type)
1
```

`check --filter F --schema S` reads no input: it types the filter against the schema, refuses a member the schema
does not describe and a step no input can take, and writes the schema every output of the filter passes.

```sh
$ stury check -c --filter '{n: .name}' --schema user.schema.json
{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"n":{"type":"string","minLength":2}},"required":["n"],"additionalProperties":false}
$ stury check -c --filter '.nmae' --schema user.schema.json; echo $?
stury: error: "nmae" is not a member of the object the schema describes (did you mean "name"?) at <top-level>, line 1, column 2:
    .nmae
     ^^^^
{"$schema":"https://json-schema.org/draft/2020-12/schema"}
1
```

`stury schema infer` writes the schema every record of its inputs passes, `schema sample` writes values that pass a
schema (or with `--invalid` fail it), and `schema gen` writes the Odin types a model reads the schema's values with:

```sh
$ stury schema infer -c --from ndjson users.ndjson
{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"name":{"type":"string"},"age":{"type":["integer","string"]}},"required":["age"]}
$ stury schema sample --count 2 --seed 1 user.schema.json
{"name":"fc"}
{"name":"he"}
$ stury schema gen user.schema.json | sed -n '/^Root/,/^}/p'
Root :: struct {
	name: string `model:"len>=2"`,
	age: Maybe(i64) `json:",omitempty" model:"optional,not_null,>=0"`,
}
```

`stury edit` runs a filter on each input and writes the input back with the filter's output spliced into its bytes:
comments, spacing, number spellings and line ends the filter does not change stay as written, and a new value
follows its container's layout. `--in-place` rewrites the files, `--check` names each file that would change, and
`--diff` tells the value changes. A table, NDJSON and `--seq` input is edited record by record.

```sh
$ cat config.jsonc
{
  // the port the server listens on
  "port": 8080,
  "hosts": ["a", "b"]
}
$ stury edit --from jsonc '.port = 9090 | .hosts += ["c"]' config.jsonc
{
  // the port the server listens on
  "port": 9090,
  "hosts": ["a", "b", "c"]
}
```

`stury diff` tells the changes between two inputs, a line each, and exits 1 when they differ. `--set`,
`--position` and `--key MEMBER` choose how arrays match. With `--old-schema` and `--new-schema` it compares two
schemas: each change, then whether the new schema takes everything the old one does (`backward`) and the reverse
(`forward`), with a value that breaks it when not. `--compat backward|forward|full` exits 1 unless that direction is
proven.

```sh
$ stury diff old.json new.json
~ .port: 8080 -> 9090
~ .replicas: 3 -> "3"  (number -> string)
+ .tags[1]: "y"
- .debug: true
$ stury diff --old-schema v1.schema.json --new-schema v2.schema.json
.id  minimum: 0 -> 1  narrows
backward: no, {"id":0} passes the old schema and fails the new one
forward: yes
```

`stury fmt` formats files, rewriting them with `--in-place`, or transcodes them (`--from csv --to json`), with
`--check` for CI, which names each file that is not formatted. `fmt --schema` writes only a file that passes the
schema. Regular expressions in a filter take Oniguruma's syntax, as jq's do:

```sh
$ echo '"2026-11"' | stury -c 'capture("(?<y>\\d+)-(?<m>\\d+)")'
{"y":"2026","m":"11"}
```

`stury --help` lists the commands and options, and `stury check --help`, `fmt --help`, `edit --help`,
`diff --help` and `schema --help` each command's own. [docs/cli.md](docs/cli.md) holds every option, the schema
check, the CSV rules and recipes, and [each difference from jq](docs/cli.md#differences-from-jq). `--explain` shows
how a filter is run.

## Documentation

- [Library guide](docs/guide.md): usage, allocation and ownership, limits, delimited-text specifics,
  [models](docs/guide.md#models), [schema checks](docs/guide.md#check-against-a-schema) and
  [schema comparison and value diffs](docs/guide.md#compare-schemas-and-diff-values).
- API reference: the doc comment on each public name, and [API.txt](API.txt), which lists the user surface.
  [API_SHARED.txt](API_SHARED.txt) lists the public names that only the packages of this repository use.
- [Command line](docs/cli.md), and its manual page [docs/stury.1](docs/stury.1) (`man ./docs/stury.1`).
- [Benchmarks](docs/benchmarks.md): the comparisons with other libraries and tools, their method and their fairness
  rules. The figures there were measured on the 0.1.1 tree, and the page marks the tables the harness has changed
  under since. [bench/README.md](bench/README.md) describes the harness.
- Internals, for contributors, one file per part: [walk](docs/walk.md), [document](docs/document.md),
  [paths](docs/paths.md), [typed reads](docs/typed.md), [writer](docs/writer.md), [records](docs/records.md),
  [kernel](docs/kernel.md) and [hot paths](docs/hotpaths.md).

## Packages

| Package | Holds |
|---|---|
| `json` | the `Json`, `Jsonc` and `Json5` specs: `validate`, `build`, `find`, `scan`, `set`, `unmarshal`, `marshal`, `load_schema`, `check_schema`, `checks` |
| `dsv` | the `Csv`, `Tsv` and `Plain` specs, with the same calls |
| `core/model` | models: rules on an Odin type, `load`, `validate`, `patch`, `dump`, problem documents and the schema of a model |
| `core/schema` | JSON Schema: compiling, binding and checking a schema, `infer`, `sample`, `compare`, `convert`, and the Odin types of a schema |
| `core/rules` | the description of the values a node allows, which an Odin type, a model, a JSON Schema and inference give, and the string formats |
| `core/regex` | the regex engine: Oniguruma's syntax for jq, ECMA-262's for a schema's `pattern`, Unicode 17.0 properties and case folds |
| `core/diff` | the changes between two values of any format |
| `core` | what every format shares: the document and `core.Value`, their readers, the edit list, paths and their answers, `write` and `format`, `Write_Options`, errors and their rendering |
| `core/records` | a text that holds a list of records, read or written one record at a time, for any format |
| `core/typed` | the type plan, the options of a typed read and the sink that gathers refusals |
| `core/write` | the typed write and the token write |
| `core/build` | the document builder and the path engine, which a format's calls use |
| `core/kernel`, `core/spell`, `core/compose` | vector code, number decoders and number text, and the composition of edits |
| `host` | `Pool`, the threads that `records.each`, a check of records and the other calls that take a `core.Runner` borrow |

## Development

Run these from this directory. `ODIN` names the compiler when it is not on `PATH`. The Makefile refuses a release older
than its `MIN_ODIN`, `dev-2026-11`. `make help` lists every target.

```sh
make check          # the checks the files you changed can reach, in seconds
make gate           # what a branch passes before it lands, once (python3 tools/gate.py full adds the long runs)
make test           # the library suites, the examples, the CLI smoke cases and the jq corpus
make test-lib       # the library suites alone, one package per test directory (make test-one P=json/test T=name)
make test-examples  # build and run the nine example programs against their expected output
make test-cli       # cmd/stury/test/smoke.py against build/stury, held to smoke.floor
make test-jq        # jq's corpus and cmd/stury/test/cli.tsv, whose row layout its first lines describe
make ecma-diff      # core/regex's ECMA patterns against Node's RegExp (needs node on PATH)
make diff-schema    # the schema check against the Python jsonschema package (needs uv)
make lint           # the vet set, with warnings as errors, and the import, word, global, API.txt and API_SHARED.txt checks
make api-write      # regenerate API.txt and API_SHARED.txt after a public change. A public name is shared when another
                    # package or cmd/ calls it, and README.md, docs/guide.md, examples/ and the user-surface
                    # signatures never name it
make test-asan      # the suites under AddressSanitizer
make test-tsan      # the suites under ThreadSanitizer
```

## License

MIT. See [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
