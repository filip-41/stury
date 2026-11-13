# stury

stury is a [jq](https://jqlang.org)-compatible command line for JSON, YAML, TOML, XML, HTML, CSV and CBOR, and a
library for [Odin](https://odin-lang.org) that gives the same answers. It is from about 2 times to two orders of
magnitude faster than jq, jaq, gojq and yq.

- jq 1.8.2's filters, options, messages and exit codes, held to jq's own test corpus.
- One filter language over JSON, JSONC, JSON5, NDJSON, CSV, TSV, TOML, YAML, XML, HTML and CBOR, and `--from` and
  `--to` to convert between any two.
- `stury edit` changes values and keeps every other byte: comments, spacing, key order and number spellings.
- CSS selectors over XML and HTML, and the tags, anchors, attributes and namespaces beside a value.
- `check --schema` against JSON Schema drafts 4 to 2020-12, with every failure at its line and column.
- `check --filter` types a filter against a schema before any data arrives.
- `stury diff` between two files of any format, or two schemas with a proof of backward and forward compatibility.
- `schema infer`, `schema sample`, and `schema gen` for the Odin types that read a schema's values.
- Strict input: `NaN`, `01` and invalid UTF-8 are errors, told at their line and column.
- Large inputs answered on all cores when the filter takes one record at a time, with the output of a serial run.
- Builtins beyond jq: statistics, set operations, `pivot`, digests, UUIDs, URL and logfmt parsing, IP addresses and
  RFC 3339 times.
- The library validates without allocating, reads one path without building a document, reads into Odin structs and
  writes them back, edits a text in place, and checks models and schemas, with one interface for every format.

```sh
$ stury edit --from yaml '.replicas = 5 | .image = "web:1.5"' deploy.yaml
# web servers
replicas: 5 # scaled by hand
image: web:1.5
ports: [80, 443]
$ stury --from html -c '[css("a.story") | {href: .&href, title: .@content}]' page.html
[{"href":"/a","title":"First"},{"href":"/b","title":"Second"}]
$ stury diff --old-schema v1.schema.json --new-schema v2.schema.json
.id  minimum: 0 -> 1  narrows
backward: no, {"id":0} passes the old schema and fails the new one
forward: yes
```

## Performance

On the 30 filters of the command-line benchmark, process start-up included, stury is between 2.9 and 219 times
faster than jq, 2.7 and 102 times faster than gojq, 1.8 and 141 times faster than jaq, and 7.9 and 250 times faster
than yq. The library builds and reads a JSON document between 1.3 and 1.45 times faster than yyjson, 1.25 and 1.35
times faster than simdjson, and 1.3 and 2.3 times faster than sonic-rs, with less memory than each.
[docs/benchmarks.md](docs/benchmarks.md) has the method, every lane and the lanes stury loses: on one thread
simdjson's On-Demand reader, which skips number and escape checks, judges NDJSON records faster.

## Limits

- stury is pre-1.0, and its options and API may still change.
- Release binaries are for Linux and macOS on amd64 and arm64. On Windows the command line builds from source.
- The library needs Odin `dev-2026-11` or later and a 64-bit little-endian target.
- Nesting past 1024 levels needs `--max-depth` (jq allows 10000).
- simdjson's On-Demand API and sonic-rs's `get` answer one early key in a large text faster, by skipping the values
  before it without judging them.

## Install

Download `stury-VERSION-OS-ARCH.tar.gz` (OS `linux` or `darwin`, ARCH `amd64` or `arm64`) from
[GitHub Releases](https://github.com/filip-41/stury/releases), or build it with
[Odin](https://odin-lang.org/docs/install/) `dev-2026-11` or later: `make build-cli` writes `build/stury`. The manual
page is `docs/stury.1`.

For the library, clone stury into your project and add it as a collection:

```sh
git clone https://github.com/filip-41/stury vendor/stury
odin build . -collection:stury=vendor/stury -o:speed
```

Then import the format you read: `stury:json`, `stury:dsv` (CSV and TSV), `stury:toml`, `stury:yaml`, `stury:xml`,
`stury:html` or `stury:cbor`. Each exports the calls a program makes on that format, the schema check included. Models are
`stury:core/model`, and schema inference, sampling and comparison `stury:core/schema`. For the
[ols](https://github.com/DanielGavin/ols) language server, add the same collection to `ols.json`.

## Command line

`stury` takes jq's arguments: a filter, then files, or standard input. Where it differs from jq, it is on purpose and
listed in [Differences from jq](docs/cli.md#differences-from-jq).

```sh
$ echo '{"logs":[{"id":1}]}' | stury -c '.logs[].id'
1
$ printf '{"foo": 01}' | stury check; echo $?
stury: parse error: <stdin>:1:10: Leading zero in a number
{"foo": 01}
         ^
5
```

### Formats

`--from` reads a format and `--to` writes one:

| Format | `--from` | Read against | `--to` writes |
| --- | --- | --- | --- |
| JSON | `json` | RFC 8259 | yes |
| JSON with comments | `jsonc` | RFC 8259 with comments | yes, with the comments a filter keeps |
| JSON5 | `json5` | JSON5 | no |
| NDJSON, RFC 7464 | `ndjson`, `--seq` | a JSON text per record | yes |
| CSV, TSV | `csv`, `tsv` | RFC 4180 | yes |
| TOML | `toml` | TOML 1.0 and 1.1 | TOML 1.0 |
| YAML | `yaml` | YAML 1.2 core schema and its test suite | block or flow style |
| XML | `xml` | XML 1.0 with its internal subset and namespaces, and its conformance suite | doctype, comments and references as written |
| HTML | `html` | the WHATWG tree construction, which recovers from every parse error | the WHATWG serialization |
| CBOR | `cbor` | RFC 8949, and RFC 8742 sequences | the preferred serialization |

An XML or HTML element is a member and its text a value, and a repeated child name reads as an array. Facts read
what a format holds beside the value: `.@tag`, `.@anchor`, `.@alias` and `.@style` in TOML and YAML, a CBOR tag, and
`.@name`, `.@namespace`, `.@content`, `.@attrs`, `.&name`, `.@pi` and `.@doctype` in XML and HTML. A comment is the
fact `.@comment`.

```sh
$ cat cities.csv
city,country,population
Oslo,NO,709000
Stockholm,SE,984000
Bergen,NO,286000
$ stury --from csv --to csv 'select(.country == "NO") | {city, population}' cities.csv
city,population
Oslo,709000
Bergen,286000
$ cat server.toml
[server]
host = "a.example" # primary
port = 8080
started = 2026-11-12T09:00:00Z
$ stury --from toml -c '.server | {port, type: (.started | .@tag)}' server.toml
{"port":8080,"type":"datetime"}
$ stury --from toml --to yaml . server.toml
server:
  host: a.example # primary
  port: 8080
  started: '2026-11-12T09:00:00Z'
$ cat feed.xml
<feed xmlns="http://www.w3.org/2005/Atom"><entry id="7"><title>Hi</title></entry></feed>
$ stury --from xml -c '.feed.entry | {id: .&id, ns: .@namespace, title}' feed.xml
{"id":"7","ns":"http://www.w3.org/2005/Atom","title":"Hi"}
```

### Edit a file

`stury edit` writes each input back with only the changed values replaced, and a new value follows its container's
layout. `--in-place` rewrites the files, `--check` names each file that would change, and `--diff` tells the changes.
Tables, NDJSON, YAML streams and CBOR sequences are edited record by record.

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

### Check against a schema

`stury check` reports each file's first fault. `check --schema` judges each input against a JSON Schema and tells
every failure with its position, path and keyword. `--report basic` writes the JSON Schema basic output and
`--report problem` an RFC 9457 problem document.

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

`check --filter F --schema S` reads no input. It refuses a member the schema does not describe and a step no input
can take, and writes the schema of the filter's output.

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

`schema infer` writes the schema its inputs pass, `schema sample` writes values that pass a schema (or with
`--invalid` fail it), and `schema gen` writes Odin types for it:

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

### Compare files and schemas

`stury diff` tells the changes between two inputs and exits 1 when they differ. `--set`, `--position` and
`--key MEMBER` choose how arrays match. For two schemas it tells whether the new one takes everything the old one does
(`backward`) and the reverse (`forward`), with a value that breaks it when not. `--compat backward|forward|full` exits
1 unless that direction is proven.

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

### Format and convert

`stury fmt` formats or converts files, with `--in-place`, and `--check` names each file that is not formatted.
`fmt --schema` writes only a file that passes the schema. Regular expressions take Oniguruma's syntax, as jq's do:

```sh
$ echo '"2026-11"' | stury -c 'capture("(?<y>\\d+)-(?<m>\\d+)")'
{"y":"2026","m":"11"}
```

`--follow FILE` answers each record as it is appended to a file, and `--explain` shows how a filter is run.
`stury --help` and each command's `--help` list the options, and [docs/cli.md](docs/cli.md) holds all of them.

## Library

The library gives the command line's answers to an Odin program:

- Validate without allocating, with the line and column of the first fault.
- Read one value by path (`.tags[1]`) without building a document, or several paths in one pass.
- Decode into Odin types and encode them back (`unmarshal`, `marshal`), with field tags and hooks for custom names and
  types.
- Build a document whose strings point into the input, and query it by path.
- Edit a text: change, insert, move or remove a value and keep every other byte.
- Models: rules on an Odin type (bounds, lengths, patterns, formats, defaults, read-only and write-only members). A
  load gathers every refusal, which `model.problem` turns into an RFC 9457 problem document, and a patch changes only
  the members it holds.
- JSON Schema drafts 4 to 2020-12: check, infer, sample, compare two schemas, and write Odin types for one.
- Diff two values of any format.
- Process records in parallel on a `stury:host` pool. The library starts no thread of its own and keeps no global
  state.

Every format is a `Spec` passed to the same calls, and every call returns one error union. A TOML datetime, a YAML
tag, a CBOR tag and an XML attribute are facts of their node, and a YAML stream's documents and a CBOR sequence's
items are records.

### Quick start

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

### Examples

The snippets below run inside a procedure that returns `json.Error` (`dsv.Error` for CSV, `yaml.Error` for YAML,
`core.Error` for a model, the same union), with `stury:core`, `stury:core/model`, `stury:core/typed`,
`stury:core/schema` and `stury:core/diff` imported where a snippet names them.

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

Change a YAML value and keep its comments:

```odin
src := transmute([]u8)string("replicas: 3 # scaled by hand\nports: [80, 443]\n")
replicas := yaml.parse_path(".replicas") or_return
defer yaml.destroy(&replicas)
out := yaml.set(src, .Yaml_1_2, replicas, 5) or_return
defer delete(out)
fmt.print(string(out)) // replicas: 5 # scaled by hand, then the ports line as it was
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
	defer model.problem_destroy(p)
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

The [library guide](docs/guide.md) covers each of these in full, with allocation and limits. The complete programs are
in [examples/](examples). Each prints a fixed answer, and `make test-examples` runs them all.

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

## Documentation

- [Library guide](docs/guide.md): usage, allocation and ownership, limits, models, schema checks and diffs.
- [Command line](docs/cli.md), and its manual page [docs/stury.1](docs/stury.1).
- API reference: the doc comment on each public name, and [API.txt](API.txt), which lists the user surface.
- [Benchmarks](docs/benchmarks.md): method, fairness rules and every figure. [bench/README.md](bench/README.md)
  describes the harness.
- Internals: [walk](docs/walk.md), [document](docs/document.md), [paths](docs/paths.md), [typed reads](docs/typed.md),
  [writer](docs/writer.md), [records](docs/records.md), [kernel](docs/kernel.md), [hot paths](docs/hotpaths.md),
  [XML and HTML](docs/markup.md) and [CBOR](docs/binary.md).

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
