# Library guide

The Odin library that [README.md](../README.md#library) introduces. A program imports the package of its format and
calls everything through it. Each public name's doc comment is its contract, so this page shows the calls and the rules
that cross them. Deeper pages cover [documents](document.md), [edits](edits.md), [paths](paths.md),
[typed reads](typed.md), [writers](writer.md), [records](records.md), [XML and HTML](markup.md) and [CBOR](binary.md).

## Install

Clone stury into the project and name it as a collection:

```sh
git clone https://github.com/filip-41/stury vendor/stury
odin build . -collection:stury=vendor/stury -o:speed
```

- **Odin:** `dev-2026-11` or later. Any optimization level works.
- **Targets:** 64-bit little-endian, amd64 and arm64 on darwin and linux. The command line builds on Windows amd64 too.
  On amd64 the floor is x86-64-v2, and kernels for AVX2 and AVX-512BW are chosen at run time.
- **Imports:** a program imports the package of each format it reads: `stury:json`, `stury:dsv`, `stury:toml`,
  `stury:yaml`, `stury:xml`, `stury:html` or `stury:cbor`. Each exports the names of `stury:core`, `stury:core/typed`,
  `stury:core/write`, `stury:core/records`, `stury:core/schema` and `stury:host` that a user calls.

## Quick start

[examples/quickstart](../examples/quickstart/main.odin) is the whole program. Run it with
`odin run examples/quickstart -collection:stury=.`, or add `-- file.json` to read a file. Its core is three calls:

```odin
Person :: struct {
	name: string,
	n:    i64,
}

run :: proc(src: []u8) -> json.Error {
	json.validate(src, .Json) or_return
	person: Person
	json.unmarshal(src, .Json, &person, allocator = context.temp_allocator) or_return
	out := json.marshal(person, allocator = context.temp_allocator) or_return
	fmt.println(string(out)) // {"name":"ada","n":1}
	return nil
}
```

## Packages

| Package | Holds |
|---|---|
| `json` | JSON, JSONC and JSON5: validate, build, paths, edits, typed reads and writes, records, models and schema checks. The calls every format package shares are named here |
| `dsv` | CSV, TSV and plain delimited text, with the same calls |
| `toml` | TOML 1.0 and 1.1, with the same calls. Edits keep every byte they do not reach, and a datetime is a string whose `Tag` fact names its type |
| `yaml` | YAML 1.2 with the core schema, with the same calls. A stream's documents are records, and the writer keeps comments, tags, anchors and scalar styles |
| `xml` | XML 1.0 with the internal subset and namespaces, with the same calls and a writer |
| `html` | HTML as the WHATWG standard parses it, built into the document XML builds, with the calls of `xml` |
| `cbor` | CBOR (RFC 8949), with the same calls. A byte string is `Kind.Bytes`, and a sequence's items are records |
| `core` | what every format shares, and the interface a run-time choice of format uses |
| `core/records` | NDJSON, RFC 7464 and CSV-style text as a sequence of records, reached through each format package |
| `core/typed` | plans and the options of a typed read |
| `core/model` | models: rules on an Odin type, with load, patch, dump and problem documents |
| `core/schema` | JSON Schema: check, infer, sample, compare, convert and Odin types, with the checks reached from a format package |
| `core/rules` | the description of the values a node allows, which an Odin type, a model, a JSON Schema and inference give, and the string formats |
| `core/diff` | the changes between two values of any format |
| `core/css` | CSS selectors over XML and HTML documents, forwarded by `xml` and `html` |
| `core/regex` | the regex engine behind jq's functions and a schema's `pattern` |
| `host` | the thread pool that `records_each` borrows |

### Specs

A format is a `Spec` value passed to each call:

| Package | `Spec` |
|---|---|
| `json` | `.Json` is strict RFC 8259, `.Jsonc` also takes comments and trailing commas, and `.Json5` takes the JSON5 grammar |
| `dsv` | `.Csv`, `.Tsv` or `.Plain` |
| `toml` | `.Toml_1_0` or `.Toml_1_1` |
| `yaml` | `.Yaml_1_2` |
| `xml` | `.Xml` |
| `html` | `.Document` or `.Fragment` |
| `cbor` | `.Cbor` reads every well-formed item. `.Preferred`, `.Deterministic` and `.Length_First` also refuse an item not in that serialization |

A call that takes a `Spec` also takes the format's `Options`, such as `max_depth` and `tolerate` for JSON, `delimiter`
and `infer` for dsv, and `alias_limit` and `merge_keys` for YAML.

### Handles

`json.as(.Json)` is an `As`, the handle of a format, and a document holds the one it was read with. The calls of `core`
and `core/records` that work on any format (`core.validate`, `core.build`, `core.format`, `core.write`,
`records.validate`, `records.open`) take an `As` where a format package's call takes a `Spec`, so a format can be chosen
at run time. A program that names a `Spec` in each call links only the walks it reaches. A handle reaches every walk of
its format.

## Errors

Every call returns one union, `json.Error`, and `err != nil` is the test. Its arms:

- **`json.Fault`:** a text broke the grammar.
- **`runtime.Allocator_Error`:** an allocation was refused.
- **`json.Document_Error`:** an edit or a commit was refused.
- **`json.Path_Error`:** a path did not parse, or a read went past a fixed limit.
- **`json.Typed_Error`:** a read or write of an Odin value was refused.
- **`json.Typed_Error_Kind`:** a write was refused with no position.

An error names the byte it concerns, and a text it names is a view of the input. `json.render(writer, src, err)` writes
any of them as `line:col: message`, with `at path` for a typed error. Pass `nil` for `src` when the error has no text,
such as a `marshal` refusal, and a fault then names `at byte 5: message`.

```odin
report :: proc(src: []u8, e: $E) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	json.render(strings.to_writer(&b), src, e)
	fmt.eprintln(strings.to_string(b))
}
```

## Validate

`json.validate(src, .Json)` judges a text without allocating and returns a `json.Error`, a `json.Fault` or nil.

```odin
if err := json.validate(src, .Json); err != nil {
	report(src, err)
}
```

`.Json` refuses a comment that `.Jsonc` takes ([examples/jsonc](../examples/jsonc/main.odin)):

```
2:9: Expected ',' or '}' after an object member
```

## Scan by path

`json.find` answers one path and stops at the answer, and `json.scan` answers every value a path with `[]` reaches.
Neither builds more than the nodes it needs. [examples/scan](../examples/scan/main.odin):

```odin
second_tag, _ := json.parse_path(".tags[1]")
defer json.destroy(&second_tag)
doc, answer, err := json.find(src, .Json, second_tag)
defer json.destroy(&doc)
if answer.outcome == .Found {
	fmt.println(string(json.span(&doc, answer.node))) // "engines", quotes and all
	buf: [32]u8
	text, _ := json.text(&doc, answer.node, buf[:]) // engines, decoded into the caller's buffer
}

every_tag, _ := json.parse_path(".tags[]")
tags, serr := json.scan(src, .Json, every_tag)
for a in tags.answers {
	fmt.println(string(json.span(&tags, a.node))) // "math", then "engines"
}
```

Output:

```
"engines"
engines
"math"
"engines"
```

A path is parsed once and owns its steps. [paths.md](paths.md) holds the grammar, the answer outcomes and what a partial
document is.

### One answer at a time

`json.answers`, `dsv.answers`, `yaml.answers` and `cbor.answers` give a path's answers as the scan reaches them, with no
document. Each is a `Token_Answer` whose `lo` and `hi` bound its value in the text. The read starts at the first `next`
and walks a growing batch at a time, so a loop that ends early has read little past what it took. A fault comes after
every answer read before it, in `it.err`. A loop that breaks frees the read with `destroy`:

```odin
it := json.answers(src, .Json, every_tag)
for a in json.next(&it) {
	fmt.println(string(src[a.lo:a.hi]))         // "math", then "engines"
	if done(a) {
		break
	}
}
json.destroy(&it)                                // only needed when the loop broke
if it.err != nil {
	// the text faulted past the last answer given
}
```

`each_answer` gives the answers to a callback instead. `toml.answers`, `xml.answers` and `html.answers` take the same
arguments and build the text at the first `next`.

### Cursors

`walk` of every format takes a `^Cursor`, which the answer iterator rides on. A hook that returns `.Stop` saves where
the walk stood, and `walk_resume` continues from there over the same text. `can_resume` says whether a cursor holds a
stop, and a resume on another text is refused with `.Bad_Option`.

- **json, dsv:** resume after any token, or after a record's end for dsv, which holds the header's cells in
  `cursor.keys`, the caller's storage.
- **yaml, toml, cbor, xml, html:** a stop keeps state on the heap, which a resume that ends the walk frees. A cursor left
  holding a stop is freed with the format's `destroy(&cursor)`. A cursor's `allocator`, the default heap when it is nil,
  holds that state.
- **yaml, toml, xml, html:** the walk reads past the stop, to the end of the block node or flow entry, of the table
  text, or of the element, and the resume gives the tokens it held first.

## Read into Odin values

`unmarshal` fills a value from a text during the scan, with no document between them, and `marshal` writes one back.

```odin
person: Person
if err := json.unmarshal(src, .Json, &person, allocator = alloc); err != nil {
	report(src, err)
}
out, err := json.marshal(person, allocator = alloc) // {"name":"ada","n":1}
```

- A field's tag is looked up under the format's key (`json`, `csv`), then under the shared key `stury`:
  `` `json:"item_id,required"` ``. A field with no name in its tag keeps its own.
- A member the struct does not have is skipped, and `Read_Options{unknown = .Refuse}` makes it an error. A
  `map[string]typed.Raw` field tagged `json:",unknown"` captures them.
- A member absent from the text keeps the value the target already holds, so defaults are written before the read.
- A repeated key follows `Read_Options.dups`: `.Last` by default, `.First`, or `.Refuse` for an error.
- `Maybe(T)` and pointers take `null`. A type in `Plan_Options.hooks` is read by your procedure, and
  `Read_Options.sink` gathers every refusal instead of stopping at the first.
- A program that reads one type many times builds the plan once with `plan_make`, passes it to `unmarshal`, and frees it
  with `destroy`. There is no global cache.

[typed.md](typed.md) holds the full type table, the tag flags and the refusal kinds.

### From a document

`typed.unmarshal(&doc, node, &target, &plan)` reads any node of a built document, and `typed.unmarshal(&doc, answer,
&target, &plan)` reads the node a `find` or `scan` answer reached. A path's value is read from the answer, never from a
text.

## Build a document

`build` returns a `Document`: a table of nodes that borrows the input. Strings are not decoded until `text` is called,
and numbers not until `number` or `int_value`. `query` runs a path over it.
[examples/roundtrip](../examples/roundtrip/main.odin):

```odin
doc, _ := json.build(src, .Json)
defer json.destroy(&doc)
path, _ := json.parse_path(".skip[]")
defer json.destroy(&path)
answers, _ := json.query(&doc, path)
defer delete(answers)
for a in answers {
	if v, ok := json.int_value(&doc, a.node); ok {
		fmt.println(v) // 1, then 2, then 3
	}
}
n, _ := json.member(&doc, json.ROOT, "n") // a member by name, without a path
```

`json.children`, `json.pairs`, `json.child_at`, `json.member`, `json.members_named` and `json.length` walk a container.
A reader given a node of the wrong kind, or an index no node holds, returns its miss value and never faults
([document.md](document.md) lists them). `number(&doc, node)` returns a `Number` of kind `Int`, `Uint`, `Float` or
`Wide`, decoded when read. `int_value` returns an `Int`'s `i64`. A `Wide` number is read from its span.

### Values

A `Value` is null (`nil`), a `bool`, a `f64`, a `Number_View`, a `string`, an `^Array`, an `^Object` or a node of a
document (`Node_Ref`). A `Number_View` keeps a number's digits, for a number read and not computed on or an integer no
double holds exactly (`core.number_text`, `core.number_view`).

- **Building:** `json.new_array`, `json.new_object`, `json.array_append` and `json.object_put` build a value in the
  context allocator, and `json.write_value(v, .Json)` writes it in any format.
- **Order:** `json.equal`, `json.compare` and `json.hash` order values as jq does. Two numbers compare by their doubles,
  and by their digits when both keep them and the doubles are equal. A cell of a CSV or TSV document is a string unless
  the document was read with `infer`.
- **Exact decimals:** `spell.decimal_of`, `spell.decimal_compare` and `spell.decimal_multiple_of` work on a number's text
  with no limit on the digits or the exponent.
- **Typed values:** `write.marshal_value(x, &plan)` makes the value of a typed `x`, and `typed.unmarshal(v, &target,
  &plan)` reads a value into a typed target. Both take a plan made with `reads = json.reads(.Json)`.

The readers above take a value as they take a node, so one loop reads both:

```odin
v := json.Value(json.Node_Ref{&doc, json.ROOT})
it := json.pairs(v)
for key, member in json.pair_next(&it) {
	fmt.println(key, json.kind(member))
}
```

## Edit and keep every other byte

`set` replaces the value at a path with an Odin value, which the document's format spells: a string, a number, a bool, a
`core.Value`, or a struct, a slice or a map with the `plan` that `plan_make` built with `reads` for its type. A value over
lines takes the layout of the container it goes in, its indent and its colon spacing. Every byte outside the edit,
spacing and comments included, is kept. [examples/edit](../examples/edit/main.odin):

```odin
name, _ := json.parse_path(".name")
out, err := json.set(src, .Json, name, "grace")
defer delete(out)
// {"name": "grace",  "tags": ["math"]}
```

Several edits on one document go on an `Edit_List`, and one commit applies them. A value is spelled where it is
recorded, and a `typed.Raw` is the text of a value, which is checked as it is recorded:

```odin
list := json.edit_list_init(&doc, .Json)
defer json.destroy(&list)
tags, _ := json.member(&doc, json.ROOT, "tags")
json.set_member(&list, json.ROOT, "n", 1)
json.remove(&list, tags)
committed, _, cerr := json.commit(&list)
defer delete(committed)
// {"name": "ada",  "n": 1}
```

`insert` adds an element or a member, `set_node` replaces a node of a list (`set` takes a path), and `remove` drops one.
In a delimited table `insert` takes a record as a struct, an array or an object of cells, and removing a cell from every
row drops its column. `toml.set`, `yaml.set`, `cbor.set`, `xml.set`, `html.set`, `dsv.set` and their edit lists edit
those formats the same way. [edits.md](edits.md) holds how each format places an edit and what it refuses.

### Read-back

A commit reads its result again by the format's walk and refuses what it does not accept:

- **`.Bad_Result`:** the edit broke a rule of the language, or HTML's result reads as a different tree.
- **`.Bad_Result` with the reason `.Reads_Back_Other`:** the result reads back as other values than the edits wrote. Every
  commit compares its result as values with the document the edits make.
- **`.Frozen`:** the format cannot make the edit. The error's message names the reason.

A list that holds a text the caller spelled (`typed.Raw`), or sets a YAML tag, anchor or alias, is judged by the format's
read alone.

### Comments

Comments are facts attached to a node, with a role of `Comment`, `Comment_Inline` or `Comment_Foot`. `.Jsonc` and
`.Json5` documents carry them and a commit keeps them. `json.facts_of(&doc, node, role)` reads a node's facts of one
role, and `json.set_fact` and `json.remove_fact` edit them. [examples/jsonc](../examples/jsonc/main.odin) sets `.a` of
`{"a": 1 // one}` with `json.set(src, .Jsonc, ...)`, and the comment stays:

```
{
	"a": 2 // one
}
```

### Facts

A format that marks a node with a type tag, an anchor or an alias (YAML's `!!str`, `&a` and `*a`, CBOR's tags) holds
them as facts of the roles `Tag`, `Anchor` and `Alias`, which stand just before the node. `set_fact` and `remove_fact`
take them in YAML and CBOR. TOML refuses them, and a commit in a format that holds none counts one in `dropped`.

A fact the node's spelling carries instead of a span is read by name with `fact_value(&doc, node, name)`:

- **`.Style`:** how a scalar or a collection is written, such as `plain`, `double`, `folded`, `flow`, `literal`, `hex`.
- **`.Tag`:** a node's tag, or a TOML datetime's type (`date-local`, `datetime`).
- **`.Name`, `.Namespace` and `.Content`:** a markup element's name, namespace and text.

A markup element's attributes are facts of the role `Attribute`, which `attributes_of` walks. A tag's
`Fact_Value.meaning` is what the tag says its value is, the same `Tag_Meaning` in every format: `.Datetime`,
`.Local_Datetime`, `.Local_Date`, `.Local_Time`, `.Binary` or `.Own`. `core.write` spells a meaning in the output's own
syntax where its text fits, and counts the tag in `dropped` where it does not.

A document marker (a YAML `%YAML` or `%TAG` line, an explicit `---` or `...`, the XML declaration) is a fact of the role
`Directive` on the root. Only a write in the document's own format keeps one.

## Write

`json.marshal(value)` and `dsv.marshal(list)` return the text, and `marshal_stream` writes to an `io.Stream`.
`json.write(&doc, .Json)` writes a document, and `json.write_stream` streams it. `json.Write_Options` sets the layout:

| Field | Effect |
|---|---|
| `pretty`, `indent`, `tab` | one member a line, with `indent` spaces or a tab per level, and no indent at `indent` 0 as jq's `--indent 0`. `json.PRETTY` is two spaces |
| `ascii` | a rune past U+007F is written as `\uXXXX` |
| `escape_html` | `<`, `>`, `&`, U+2028 and U+2029 are escaped |
| `escape_del` | DEL is written as `\u007f` |
| `sort_keys` | a struct's fields and a document's keys in byte order. A map's keys are always sorted |
| `respell_strings` | a string read from a source is written in the writer's own escapes |
| `jq_numbers` | a number that is not finite is written as jq writes it |
| `grow_header` | a delimited text's table takes a key its header lacks |

A document written back keeps each string and number as its source spelled it unless `respell_strings` is set.
[writer.md](writer.md) holds the `omitempty` tag flag, the hooks and what a format may refuse to write.

### Format a text

`json.format` reads a text and writes it again in the layout `Write_Options` names, judging it on the way. `stury fmt`
is this call.

```odin
out, err := json.format(src, .Json, write = json.PRETTY)
if err != nil {
	report(src, err)
	return
}
defer delete(out)
```

## Records and threads

`core/records` reads a text as a sequence of records: NDJSON lines, RFC 7464 `0x1E` records, or CSV rows. A record is
the bytes of one line and the offset it starts at. [examples/records](../examples/records/main.odin):

```odin
faults, _ := json.records_validate(src, .Json, framing = .Lines)   // one fault per invalid record, positions in the whole text
defer delete(faults)
```

```
2:9: Invalid literal
1 refused
```

`json.records_open` frames a text and `json.records_open_stream` frames an `io.Reader` through a window.
`json.records_next` yields each record without judging it, so a caller who needs a verdict calls `check` or reads the
record. A stream that ends on a broken frame sets `it.fault`. A reader reads, builds and scans no record until
`it.docs = json.record_docs(.Json)` is set.

`json.records_each(src, .Json, .Lines, task, &data, &pool.runner)` hands every piece of the text to a task on `json.Pool`
threads, each piece an independent `json.Record_Reader`:

```odin
pool: json.Pool
json.pool_init(&pool)
defer json.destroy(&pool)
count := proc(n: ^int, piece: ^json.Record_Reader, _: int) -> bool {
	for _ in json.records_next(piece) { sync.atomic_add(n, 1) }
	return true
}
json.records_each(lines, .Json, .Lines, count, &total, &pool.runner)
```

The library starts no thread of its own: a `nil` runner answers on the calling thread, and a `json.Pool` of the width
you pass to `json.pool_init` (the calling thread counted, 0 for one per core) answers on that many. [records.md](records.md)
holds the framing rules and the Reader contract.

Under `.Entries` the records are the elements or members of the root, or of the container the `entries` path of object
keys names: `json.records_open(src, .Json, framing = .Entries, entries = {"data"})` reads the items of `{"data": [...]}`.
YAML stream documents and CBOR sequence items are records under `.Concatenated`, and the other formats take `.Entries`
too, as `toml.records_open(src, .Toml_1_0, framing = .Entries, entries = {"x"})` reads each `[[x]]` table.

## Models

`core/model` adds rules to a type: a model checks members' values as they are read, gives absent members their
defaults, records which members a text held, and writes the value back by the same rules. The complete program is
[examples/model](../examples/model/main.odin).

```odin
User :: struct {
	id:    i64 `model:"read_only"`,
	name:  string `model:"len>=2"`,
	email: Maybe(string) `model:"optional"`,
	role:  string `model:"optional"`,
	set:   model.Fields_Set,
}

reg: model.Registry
model.register(&reg, User, "role", "member")
m, err := model.compile(&reg, User, json.checks(.Json))
user: User
sink: typed.Sink
err = model.load(&m, body, &user, &sink)
```

`json.checks(.Json)` binds the model to JSON. `dsv.checks(.Csv)` binds it to CSV rows, and every format package has its
`checks`. A model copies what it keeps of the registry, so the registry may be destroyed once its models are compiled.

### Load and validate

- `load` refuses a missing required member and reads no `read_only` member. A `Fields_Set` member records what the text
  held, which `was_set` asks by the member's Odin name.
- A load without a sink stops at its first refusal. With a sink it collects every failure, in the order `stury check`
  lists them: by the value's path, a value before what it holds.
- `validate` checks a value built in code by the same rules.
- A repeated key is `.Duplicate_Key`, where `json.unmarshal` takes the last. `Load_Opts{dups = .Last}` or `.First` picks
  one instead, and `.All` is `.Bad_Option`, since a member holds one value.
- A CSV or TSV model reads an empty unquoted cell as null: a `Maybe` member holds nil and a plain `string` member
  refuses it as `.Wrong_Kind`.
- A pointer or `Maybe` member reads null as nil, and with the `not_null` tag item refuses it. A nil `Maybe` with neither
  `omitempty` nor `omitunset` writes null, so `validate` counts it as present.
- `model.problem(sink.entries[:], "Invalid body", 422)` makes an RFC 9457 problem document of every refusal, which
  `marshal` writes in any format and `model.problem_destroy` frees.

### Tags

- The format tag (`json:`, or `stury:` for every format) names a member and shapes it: a rename, `-`, `omitempty`,
  `omitunset`, `required` and `unknown`, which marks the `extra` member.
- `model:` holds the rules and the roles: `optional`, `read_only`, `write_only`, `not_null`, bounds, `format=`,
  `pattern=` and `unique`. `required` with `optional` is refused. `pattern=` takes the rest of the tag, commas included,
  so it comes last.
- A struct's `extra` member, `map[string]core.Value` or `map[string]T` tagged `json:",unknown"`, holds the members it
  does not name. `register(&reg, T, model.Extra.Forbid)` refuses them instead.

`register_after(&reg, T, "name", check)` adds a validator a member's value meets once it is read, and
`register(&reg, Union_Rule{type = U, tag = "kind"})` sets the tag of a union. `model.schema(&m, .Load)` and `.Dump`
describe what a load takes and what a dump writes.

### Patch

`model.patch(&m, &existing, body)` applies a patch text to a value whose struct has a `Fields_Set`. Each member's rules
judge what the patch holds. A member the patch leaves out is neither required nor defaulted and keeps what `existing`
holds. Struct validators judge the merged value, `existing` is written only when nothing failed, and a failure's path is
in the patch.

### Dump

`model.dump(&m, &user, opts)` writes the value as `marshal` does by the model's plan, never a `write_only` member.
`dump_stream` writes to a stream.

- **`exclude_unset`, `exclude_none`, `exclude_defaults`:** `Dump_Opts` leaves out the members a load did not set, that
  hold null, or that equal their default, only where a load does not require them, so a dump of a valid value loads
  back. A member is unset when its `Fields_Set` bit is clear, so every member of a value built in code is unset.
- **`check`:** refuses a value whose written members fail its rules as `.Check_Failed`.
- **`read_only`:** a dump writes a `read_only` member, which a load under `Extra.Forbid` refuses, so such a dump does not
  load back through the same model.
- **CSV and TSV:** a row keeps every column, so the options leave nothing out there.

## JSON Schema

`json.load_schema(text, .Json)` reads and compiles a JSON Schema (drafts 4 to 2020-12) once, and
`json.bind_schema(s, .Json)` binds it to the spec the inputs are read as. `json.check_schema` judges a text and puts
every failure in a `json.Sink`, each with its position, its path and the keywords that failed it. `stury check --schema`
is the same check on the command line ([cli.md](cli.md#schema-check)).

```odin
s, _ := json.load_schema(schema_text, .Json)
defer json.destroy(s)
b, _ := json.bind_schema(s, .Json)
defer json.destroy(&b)
sink := json.Sink{max_errors = 20}
defer json.destroy(&sink)
if json.check_schema(&b, src, &sink) != nil {
	for e in sink.entries { fmt.println(e.start, e.kind) }
}
```

- **Load options:** `json.load_schema(text, .Json, load = {draft = .D07, refs = dir})` takes `json.Schema_Options`: the
  draft of a schema with no `$schema`, the directory `$ref`s are read from, `format_assert` and `dups`. A reference
  resolves within the schema, to a draft's meta-schema or to a file under `refs`, since it reads no network.
- **Sink:** set `max_errors`: a sink without one keeps the first 100 failures.
- **Records:** `json.check_schema_records` checks a text of records (`.Lines`, `.Seq`) one by one and, with a
  `json.Runner`, on its threads, with the entries a serial check gives.
- **Tables:** `dsv.bind_schema(s, .Csv, {infer = true})` binds a table. A cell is a string, or under `infer` a number,
  `true` or `false` when its text is exactly one.

### Patterns

A `pattern` and a `patternProperties` name are read as ECMA-262 regular expressions with the `u` flag. An escape outside
a class names only a syntax character or `/`, so `\&` refuses the schema when it is loaded. Look-behind and back
references are refused too, since the search does not backtrack, though `format: "regex"` accepts them and the jq
functions run them. A search that runs out of memory, or whose counted repeats nest past what memory bounds, is not a
verdict: the check reports `pattern_undecided` and `stury check` exits 2.

### Infer, sample and generate

`schema.infer` takes in values (and `schema.infer_records` the records of a text, on a runner's threads) and
`schema.inferred` gives the description they all pass, which `schema.write` writes as JSON Schema.
`schema.sample(&d, as, {count = 3, seed = 1})` writes values that pass a description in the format `as`, and
`invalid = true` values that fail it. `schema.write_odin(s.description, "user", json.as(.Json))` writes the Odin source
of the types a model reads a description's values with, and a `register` procedure that adds the rules no tag holds, as
`stury schema gen` writes them ([cli.md](cli.md#schema)).

## Compare and diff

`schema.compare(old, new)` takes two compiled schemas' `description`s and answers, in each direction, whether one takes
every value the other does: `Yes` by a proof over the descriptions, `No` with a `witness` value that the check of both
confirmed, or `Unknown` with the keyword the proof stopped at. `changes` lists the keywords that differ. The search has
fixed bounds, and `truncated` says one ended it, which gives `Unknown` with the reason `budget`.

```odin
c, err := schema.compare(old.description, new.description, {as = json.as(.Json)})
if err != nil { return err }
defer schema.comparison_destroy(&c)
if c.old_in_new.verdict != .Yes { fmt.println("a reader of the new schema may refuse old data:", c.old_in_new.witness) }
```

`diff.values(a, b, opts)` of `core/diff` lists the changes between two values of any format, each with its path. The
values are nodes of documents (`core.Node_Ref{&doc, core.ROOT}`). `diff.Options.arrays` chooses how arrays match
(`.Sequence`, `.Set` or `.Position`), and `keys` takes a `Key_Rule` per array to match its elements by a member. `stury diff` is
the same on the command line ([cli.md](cli.md#diff)).

## Delimited text

`dsv` reads and writes CSV, TSV and plain delimited text through the same calls as `json`.
[examples/dsv](../examples/dsv/main.odin) reads rows into structs:

```odin
City :: struct {
	name:       string `csv:"City"`,
	population: Maybe(i64),
	lat, lon:   f64,
}
cities: []City
err := dsv.unmarshal(src, .Csv, &cities, allocator = context.temp_allocator)
out, _ := dsv.marshal(cities)
```

- The first record is the header and names the columns. A field matches the column named by its `csv` tag or its own
  name. With `Options{no_header = true}`, column k is the struct's field k.
- An empty unquoted cell is `null` to every check and read, and a `Maybe(T)` holds nil for it, which writes back as an
  empty cell. A cell the field cannot hold is an error at that cell: `2:6: Expected i64, found "lots" at .[0].population`.
- A number field reads its cell as a loose number: `007` reads as 7 and `.5` as 0.5. `Options.infer` takes only an
  exact JSON number, so a document keeps `007` as text.
- `Options{delimiter = ';', comment = '#'}` reads other delimiters and skips lines starting with `#`.
- A dsv document is an array of objects keyed by the header, and `dsv.length(&doc, dsv.ROOT)` is the row count.
  `dsv.find` reads one cell by `.[1].City` without building the table, and `dsv.set` replaces a cell and keeps every
  other byte.
- `dsv.kind` reads an empty unquoted cell as `.Null` and any other cell as `.String`. `infer` also reads `true`, `false`
  and exact JSON numbers as their kinds, and a JSON write writes each cell as the kind it reads as.

A cell is quoted on write when it holds the delimiter, a quote or a line break. A list row (`[][]string`) writes one
cell per element, and a row whose length differs from the first row's is refused as `.Wrong_Length`. With
`Options{tolerate = {.Ragged}}`, given to the write as to the read, rows of any length are written as they are, and no
row is padded.

## TOML

`toml` reads TOML 1.0 and 1.1 through the calls of `json`. A table's members may be written apart, so a document holds
each table as one object and a path read builds the whole document. A repeated key and a table defined twice are faults
of the text, whatever `dups` says.

```odin
Server :: struct {
	host: string,
	port: i64,
}
Config :: struct {
	title:  string,
	server: Server,
}

src := transmute([]u8)string("title = \"demo\"\nstamp = 2026-11-12T08:00:00Z\n\n[server]\nhost = \"localhost\" # the bind address\nport = 0x1F90\n")
cfg: Config
toml.unmarshal(src, .Toml_1_0, &cfg, allocator = context.temp_allocator) or_return
fmt.println(cfg.server.port) // 8080

doc := toml.build(src, .Toml_1_0) or_return
defer toml.destroy(&doc)
stamp, _ := toml.member(&doc, toml.ROOT, "stamp")
tag, _ := toml.fact_value(&doc, stamp, .Tag)
fmt.println(toml.kind(&doc, stamp), tag.text) // String datetime

port := toml.parse_path(".server.port") or_return
defer toml.destroy(&port)
out := toml.set(src, .Toml_1_0, port, 9090) or_return
defer delete(out)
fmt.print(string(out)) // the text with `port = 9090`, its comment and every other byte kept
```

- A datetime is a string whose `Tag` fact names its type: `datetime`, `datetime-local`, `date-local` or `time-local`. A
  `typed.Datetime` field reads any of them, and a `time.Time` reads an offset datetime. A local kind is no `time.Time`:
  the read refuses it as `.Bad_Format`. A hex, octal or binary integer is a number, and `Style` tells its form.
- `toml.marshal(cfg)` writes a struct or a map as a document: scalars first as `key = value` lines, then each table as a
  `[header]` section and an array of tables as `[[header]]` sections. A float is written so that it reads back as a
  float. Null has no TOML spelling, and a key a table repeats cannot be written, both `.Unwritable`. `core.write` with
  `toml.as(spec)` writes a document of any format whose root is an object.
- A plan reads TOML only when it is made with `reads = toml.reads(spec)`, as json's and yaml's do.
- A TOML text has no mark that ends it, so under `.Concatenated` a record is the whole text from the reader's position to
  the input's end.

## YAML

`yaml` reads YAML 1.2 with the core schema through the calls of `json`, one document a text. A plain scalar resolves by
its text and its tag to null, a boolean, a number or a string, and one its core tag does not hold (`!!int yes`) is a
fault. A key that is a collection is refused. An alias reads as the node of its anchor, and the bytes the aliases of a
document read again stay within `Options.alias_limit` (by default the larger of 1 MiB and ten times the text).
`Options.merge_keys` reads `<<` as a merge key.

```odin
Service :: struct {
	name:     string,
	replicas: i64,
	ports:    []i64,
}

src := transmute([]u8)string("# the web service\nname: web\nreplicas: 3 # scaled by hand\nports: [80, 443]\n")
svc: Service
yaml.unmarshal(src, .Yaml_1_2, &svc, allocator = context.temp_allocator) or_return
text := yaml.marshal(svc, write = yaml.PRETTY, allocator = context.temp_allocator) or_return
fmt.print(string(text)) // name: web, replicas: 3, then ports as a block sequence

replicas := yaml.parse_path(".replicas") or_return
defer yaml.destroy(&replicas)
out := yaml.set(src, .Yaml_1_2, replicas, 5) or_return
defer delete(out)
fmt.print(string(out)) // replicas: 5 # scaled by hand, and the rest as it was
```

- A repeated key follows `dups` as in JSON. Two keys repeat when they resolve to one type and value, so `a` and `"a"`
  repeat each other, and so do `1` and `0x1`, while `1` and `"1"` are two members. A read by name refuses the second of
  `1` and `"1"` as `.Duplicate_Key` under every policy but `.First` and `.All`, since it cannot tell which holds them.
- `yaml.find`, `scan` and `each_answer` read a document in one pass without a build, and build it when the read reaches
  an alias.
- A stream of several documents is read as records under `.Concatenated`, one per document. A text with more than one
  document is a fault of `build`.
- `core.write` with `yaml.as(.Yaml_1_2)`, and `yaml.marshal`, write block style when the layout is pretty and flow style
  on one line when it is compact. A string is plain unless a reader would take it for another type (`yes`, `~`, `0123`,
  a date), and a string with a line end is a literal block. A document read from YAML writes back its comments, tags,
  anchors, aliases, scalar styles and flow collections.

## XML and HTML

`xml` reads XML 1.0 with the internal subset and namespaces, and `html` reads HTML as the WHATWG standard's parser does,
recovering from every parse error. Both build the markup document shape: an element is a member under its name, its
text is its value, or a `#text` member when it has child elements, and its attributes are facts of its value.
[markup.md](markup.md) holds the shape, the DTD, namespaces and the HTML tree.

```odin
src := transmute([]u8)string(`<order id="7"><item>pen</item><item>ink</item><note>rush &amp; wrap</note></order>`)
doc := xml.build(src, .Xml) or_return
defer xml.destroy(&doc)
order, _ := xml.member(&doc, xml.ROOT, "order")
text_buf: [32]u8
id_buf: [16]u8
attrs := xml.attributes_of(&doc, order)
_, id_token, _ := xml.attribute_next(&attrs)
id, _ := xml.token_text(&doc.view, id_token, id_buf[:])
note, _ := xml.member(&doc, order, "note")
text, _ := xml.text(&doc, note, text_buf[:])
fmt.println(id, text) // 7 rush & wrap

items := xml.parse_path(".order.item") or_return
defer xml.destroy(&items)
found := xml.scan(src, .Xml, items, read = {dups = .All}) or_return
defer xml.destroy(&found)
for a in found.answers {
	fmt.println(string(xml.span(&found, a.node))) // pen, then ink
}
```

- An element's text is a string, and with `Options.infer` a number or a boolean when it is exactly one. Repeated elements
  are members of one name, which `members_named` and a path under `dups = .All` give one by one. The node's value, as
  `core.write` to JSON reads it, makes such a name one member, an array in document order.
- `attributes_of` walks an element's attributes, and `fact_value` gives an element's `Name`, `Namespace` and `Content`. A
  path step `{uri}local` matches by namespace.
- `html.build(src, .Document)` builds the tree the standard's algorithm builds, implied elements included, so `<p>Pens`
  is `{"html":{"head":null,"body":{"p":"Pens"}}}` as JSON. `.Fragment` reads a fragment in the context element
  `Options.context_name`. `html.validate` returns the first parse error, which a build passes over.
- `xml.unmarshal` reads into a struct whose member takes its name from the tag key `xml`: the member of the root
  element's name, and under it a member per attribute, child element or `#text`. A list member collects the siblings of
  its name. `html.unmarshal` does the same on the tag key `html`, from the tree the standard builds.
- `xml.write` and `xml.marshal` write a document of any format whose root is an object of one member: a member is an
  element, an array one element per item, `#text` text and null an empty element. The document of an XML text is written
  from its spans, so its attributes, declarations, doctype, comments and instructions stay as written. What XML cannot
  spell so that it reads back, such as a key that is no XML name, a nested array or an empty string, is `.Unwritable`.
  `html.write` and `html.marshal` write as the WHATWG standard serializes a tree, and refuse a value a browser would read
  back as another tree.
- A text is one record under `.Concatenated`.

### Select by CSS

`compile_selector` compiles a CSS selector list once, and `select` gives the value node of each element of a
document it matches, in document order, which a caller reads, paths or edits as any node. Both are `core/css`'s,
forwarded by `xml` and `html`. A selector out of scope or malformed is a `Fault` at the byte that breaks it.

```odin
sel := html.compile_selector("ul.todo > li:not(.done)") or_return
defer html.destroy(&sel)
doc := html.build(transmute([]u8)string(`<ul class=todo><li>pens<li class=done>ink<li>nibs</ul>`), .Document) or_return
defer html.destroy(&doc)
found := html.select(&doc, &sel) or_return
defer delete(found)
buf: [32]u8
for node in found {
	text, _ := html.text(&doc, node, buf[:])
	fmt.println(text) // pens, then nibs
}
```

`select(&doc, &sel, from)` matches the descendants of the element whose value is `from`, as `querySelectorAll` does. [markup.md](markup.md#selectors) holds what a selector may hold and its costs.

## CBOR

`cbor` reads and writes CBOR (RFC 8949) through the calls of the text formats. [binary.md](binary.md) lists what differs.

```odin
Reading :: struct {
	sensor: string,
	value:  f64,
	raw:    cbor.Bytes,
}

src := cbor.marshal(Reading{sensor = "t1", value = 21.5, raw = {1, 2, 3}}, allocator = context.temp_allocator) or_return
cbor.validate(src, .Preferred) or_return
doc := cbor.build(src, .Cbor) or_return
defer cbor.destroy(&doc)
raw, _ := cbor.member(&doc, cbor.ROOT, "raw")
buf: [16]u8
payload, _ := cbor.doc_bytes(&doc, raw, buf[:])
fmt.println(cbor.kind(&doc, raw), payload) // Bytes [1, 2, 3]
as_json, dropped := json.write(&doc, .Json) or_return
fmt.println(string(as_json), dropped) // {"sensor":"t1","value":21.5,"raw":"AQID"} 0
```

- `.Preferred`, `.Deterministic` and `.Length_First` refuse an item not encoded as RFC 8949 sections 4.1 and 4.2 ask, and
  a write in that spec writes it so. The value a read gives does not change.
- `cbor.set` writes the item again with the value replaced and copies the bytes of every item the edit does not reach.
- A map key is an integer, a text string or a byte string. An integer key reads as its digits, so `.["1"]` reads key 1,
  and `1` and `"1"` are one key.
- A tag is a fact: `fact_value(&doc, node, .Tag)` gives the nearest tag's number. A byte string written as JSON is base64
  text, and a tag is dropped and counted in `dropped`.
- `cbor.marshal` writes a struct as a map, or as an array under `Options{structs = .Array}`, and `unmarshal` reads either.
  A `typed.Datetime` is written after tag 0 when it has an offset and after tag 1004 when it is a date.

## Several formats in one program

A struct can carry both a `csv` and a `json` tag, and both formats return the same `Error`, so one procedure handles
either ([examples/crossformat](../examples/crossformat/main.odin)). A bad population reports at its own position in each
format:

```
2:6: Expected i64, found "lots" at .[0].population
1:30: Expected i64, found string at .[0].population
```

## Strictness

`.Json` is RFC 8259 with nothing extra: no leading zero, no `NaN`, no invalid UTF-8 and no lone surrogate. `.Jsonc` and
`.Json5` accept their own additions and nothing else.

`Options.tolerate` lets a text break a named rule, a `core.Tolerance`, with a fixed reading:

- **`Invalid_Utf8`:** each ill-formed sequence in a string or a cell reads as U+FFFD.
- **`Lone_Surrogate`:** an unpaired `\u` escape reads as U+FFFD.
- **`Ragged`:** a dsv record may have any width.
- **`Bare_Quote`:** a quote inside an unquoted CSV cell is a byte of the cell.
- **`Unread_Entity`:** an XML reference to an entity whose text was not read reads as its own text.

A rule a format has no instance of changes nothing there. A tolerated text is never reported as valid under strict
rules. `json.Options.refuse_non_finite` refuses JSON5's `Infinity` and `NaN`, for a reader that has no value for them.

## Memory and ownership

- A document, a find or scan result and a record borrow the input. Keep the input alive while they are used.
- `destroy` frees a document, including a result from `find` or `scan`, and a path, an edit list, a plan, a record
  writer and a pool. `records_close` frees a record iterator.
- A slice returned by `query`, `check`, `commit`, `set`, `marshal` or `write` is the caller's, freed with `delete` and
  the allocator it was made with.
- `unmarshal` allocates strings, lists and maps with the allocator it is given and frees none of them, not even when it
  refuses the text. Give it an arena or `context.temp_allocator` and free that whole. `Read_Options.borrow_strings`
  makes a string with nothing to decode a slice of the input, so the input must outlive the target.
- A plan belongs to the caller, is read only during a read, and may be shared by any number of reads.
- A build that runs out of memory counts the text and builds again at the exact size, so a text fails only when its
  document does not fit the allocator.

## Limits

| Limit | Value |
|---|---|
| Nesting depth | `json.MAX_DEPTH`, 1024. `Options.max_depth` raises or lowers it per call. A depth beyond `MAX_DEPTH` allocates one byte per level |
| Children counted in a node | `json.MAX_CHILDREN`, 65535. A larger container is still read in full, and its true count is `json.length_exact` |
| Subschemas applied to one value | 1024 (`core.MAX_DEPTH`) nested held subschemas. A schema that nests more, or applies itself to the same value without end, is refused with `.Too_Deep` when bound |
| Reading a schema | recurses once per nested subschema, which a build with the address sanitizer cuts off at about 1000 levels |
| Numbers | a number too large for binary64 or over the digit and scale caps comes back as `.Wide`, and the caller reads its span |

A text past a limit gets a fault with a kind, never a wrong answer, except a schema deeper than the sanitizer build holds.

## Examples

| Program | Shows |
|---|---|
| [quickstart](../examples/quickstart/main.odin) | validate, `unmarshal`, `marshal`, error rendering |
| [scan](../examples/scan/main.odin) | `find` and `scan` by path |
| [roundtrip](../examples/roundtrip/main.odin) | `build`, `query`, readers |
| [edit](../examples/edit/main.odin) | `set`, edit lists, `commit` |
| [records](../examples/records/main.odin) | `check`, streams, `each` on a pool |
| [jsonc](../examples/jsonc/main.odin) | comments and edits that keep them |
| [dsv](../examples/dsv/main.odin) | CSV into structs, dialects, documents, edits, records, writer |
| [crossformat](../examples/crossformat/main.odin) | one struct and one procedure for CSV and JSON |
| [model](../examples/model/main.odin) | a model's load, problem document, `patch` and `dump` |

Each prints a fixed answer, kept in its `expected.txt`. `make test-examples` builds and runs all of them.
