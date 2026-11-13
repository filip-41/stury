# Library guide

How to use `stury:json`, `stury:dsv`, `stury:toml`, `stury:yaml`, `stury:xml`, `stury:html` and `stury:cbor`, with
snippets from the programs in [examples/](../examples). A program imports the package of its format and calls everything
through it. Each public name's doc comment is its contract, and
[API.txt](../API.txt) lists the names of the format packages, then the names a format's author reads.
[API_SHARED.txt](../API_SHARED.txt) lists the public names that only the packages of this repository use. The files in this
directory describe one part each: [document.md](document.md), [paths.md](paths.md), [typed.md](typed.md),
[writer.md](writer.md) and [records.md](records.md), and two describe formats: [markup.md](markup.md) XML and HTML, and
[binary.md](binary.md) CBOR.

## Requirements

- Odin `dev-2026-11` or later. The collection is named `stury` and points at this directory: `-collection:stury=.`.
  A program imports the package of each format it reads, `stury:json`, `stury:dsv`, `stury:toml`, `stury:yaml`,
  `stury:xml`, `stury:html` or `stury:cbor`. Each exports the names of `stury:core`,
  `stury:core/typed`, `stury:core/write`, `stury:core/records`, `stury:core/schema` and `stury:host` that a user calls.
- 64-bit little-endian targets: darwin and linux, on amd64 and arm64. The command line also builds on Windows.
- On amd64 the floor is x86-64-v2. Long strings are scanned wider on processors that have AVX-512BW, chosen at run
  time.
- Any optimization level works. The command line builds at `-o:speed`.

## Which package

| Package | Holds |
|---|---|
| `json` | the JSON formats: `validate`, `build`, `find`, `scan`, `set`, `query`, `commit`, `unmarshal`, `marshal`, and the names of the packages below that a user calls: `Document`, `Error`, `render`, `parse_path`, `destroy` and the rest |
| `dsv` | the delimited formats, the same calls and names |
| `toml` | TOML 1.0 and 1.1: the same calls, edits that keep every byte they do not reach, and `marshal` and `unmarshal` on the `toml` tag. A datetime is a string whose `Tag` fact names its type |
| `yaml` | YAML 1.2 with the core schema: the same calls, edits, a stream's documents as records, and a writer that keeps comments, tags, anchors and scalar styles |
| `xml` | XML 1.0 with the internal subset and namespaces: `validate`, `build`, `find`, `scan`, `query`, `unmarshal`, `marshal`, `write`, records, and checks by a model and a schema |
| `html` | HTML as the WHATWG standard parses it, built into the document XML builds, with the calls of `xml` |
| `cbor` | CBOR (RFC 8949): the encoding rules, documents, paths, a sequence's items as records, `marshal`, `unmarshal`, the writer and the checks. A byte string is `Kind.Bytes` |
| `core` | what every format shares, and the interface a format's author or a run-time choice of format uses: `As`, `build` and `validate` over a handle |
| `core/records` | NDJSON, RFC 7464 and CSV-style text as a sequence of records, reached as `records_check`, `records_open`, `records_open_stream`, `records_next`, `records_each` and the writer |
| `core/typed` | plans and the options of a typed read |
| `core/model` | models: rules on an Odin type, `load`, `validate`, `patch`, `dump`, problem documents and the schema of a model, imported as `model "stury:core/model"` |
| `core/schema` | JSON Schema: `compile`, `bind` and `check`, reached from a format as `load_schema`, `bind_schema` and `check_schema`, and `infer`, `sample`, `compare`, `convert` and `write_odin` |
| `core/rules` | the `Description` of the values a node allows, which an Odin type, a model, a JSON Schema and inference give, and the string formats |
| `core/diff` | `values`, the changes between two values of any format |
| `core/regex` | the regex engine: Oniguruma's syntax for jq's functions, ECMA-262's (`Flags.ecma`) for a schema's `pattern`, with Unicode 17.0 properties and case folds |
| `host` | `Pool`, the threads that `records_each` borrows |

A format is a `Spec` value passed to each call. `json.Spec` is `.Json`, `.Jsonc` or `.Json5`, and `dsv.Spec` is `.Csv`,
`.Tsv` or `.Plain`. `.Json` is strict RFC 8259. `.Jsonc` also takes comments and trailing commas, and `.Json5` takes the
JSON5 grammar. A call that takes both a `Spec` and `Options` reads `Options` for the format's own settings, which for
JSON are `max_depth`, `tolerate` and `refuse_non_finite`, and for dsv `no_header`, `delimiter`, `comment`, `tolerate`, `crlf` and `infer`.
`toml.Spec` is `.Toml_1_0` or `.Toml_1_1`, `yaml.Spec` is `.Yaml_1_2`, `xml.Spec` is `.Xml` and `html.Spec` is
`.Document` or `.Fragment`. `cbor.Spec` is `.Cbor`, `.Preferred`, `.Deterministic` or `.Length_First`: `.Cbor` reads
every well-formed item, and the others also refuse an item not in that serialization.

## Errors

An error is a value with a `kind` and the byte it concerns. A text it names is a view of the input, the path's text or
the plan, and the one thing allocated is a typed error's path, `steps`, by `context.temp_allocator`. `err != nil` is the test, and `or_return` passes it up. Every call of the
library returns one union, `json.Error`, whose arms are `json.Fault` (a text broke the grammar, from `validate`, a build, a
scan or a read), `runtime.Allocator_Error` (an allocation was refused), `json.Document_Error` (an edit or a commit was
refused), `json.Path_Error`, `json.Typed_Error` (a read or write of an Odin value) and `json.Typed_Error_Kind` (a write
refused with no position). `core.error_of` is the one place a concrete error becomes the union.

`json.render(writer, src, err)` writes any of them as `line:col: message`, with `at path` for a typed error. A path
error's position is in the path's text, which it holds. Pass `nil` for `src` when the error has no text, such as a
`marshal` refusal. A fault rendered with `nil` names its byte offset, `at byte 5: message`, in place of a line.

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
if fault, bad := json.validate(src, .Json).?; bad {
	report(src, fault)
}
```

[examples/quickstart](../examples/quickstart/main.odin) validates, reads and writes a value. [examples/jsonc](../examples/jsonc/main.odin)
shows that `.Json` refuses a comment that `.Jsonc` takes:

```
2:9: Expected ',' or '}' after an object member
```

## Check against a schema

`json.load_schema` reads and compiles a JSON Schema (drafts 4 to 2020-12) once, and `json.bind_schema(s, .Json)` binds it
to the spec the inputs are read as. `json.load_schema(text, {draft = .D07, refs = dir})` takes `json.Schema_Options`: the draft
of a schema with no `$schema`, the directory `$ref`s are read from, `format_assert` and `dups`. `json.check_schema` judges a text and puts every failure in a `json.Sink`, each with its
position, its path and the keywords that failed it. `json.check_schema_records` checks a text of records (`.Lines`, `.Seq`) one by one and, with a `json.Runner`, on its
threads, with the entries a serial check gives. Set the sink's `max_errors`: a sink without one keeps the first 100 failures. A check of
many records holds no memory per record, but a failure is kept until the sink is destroyed. A table is bound with
`dsv.bind_schema(s, .Csv, {infer = true})` and checked with the same calls. A cell is one kind: a string, or under `infer`
a number, `true` or `false` when its text is exactly one, as `dsv.unmarshal` reads it.

```odin
s, _ := json.load_schema(schema_text)
defer json.destroy(s)
b, _ := json.bind_schema(s, .Json)
defer json.destroy(&b)
sink := json.Sink{max_errors = 20}
defer json.destroy(&sink)
if json.check_schema(&b, src, &sink) != nil {
	for e in sink.entries { fmt.println(e.start, e.kind) }
}
```

`stury check --schema` is the same check on the command line ([cli.md](cli.md#schema-check)).

A `pattern` and a `patternProperties` name are read as ECMA-262 regular expressions with the `u` flag, so an escape outside a
class names only a syntax character (`^$\.*+?()[]{}|`) or `/`, and inside a class also `-`. An escape such as `\&` or `\%`
refuses the schema at bind: `invalid escape \& at offset 1`. Look-behind (`(?<=`, `(?<!`) and back references (`\1`) are refused
there too: the search does not backtrack, which both need. `format: "regex"` accepts them when a back reference names a group
the pattern has, as it asks only that the text is a regular expression, and the jq functions run them. `\p{...}` holds the
characters of Unicode 17.0. A search that runs out of memory on a very long string, or whose counted repeats nest past what the
pattern and the text bound, is not a verdict: the check reports `pattern_undecided` and `stury check` exits 2.

`schema.infer` takes in values (and `schema.infer_records` the records of a text, on a runner's threads) and
`schema.inferred` gives the description they all pass, which `schema.write` writes as JSON Schema. `schema.sample(&d, as,
{count = 3, seed = 1})` writes values that pass a description in the format `as`, and `invalid = true` values that fail it.
`schema.write_odin(s.description, "user", json.as(.Json))` writes the Odin source of the types a model reads a
description's values with, and a `register` procedure that adds the rules no tag holds, as `stury schema gen` writes them
([cli.md](cli.md#schema)).

## Compare schemas and diff values

`schema.compare(old, new)` takes two compiled schemas' `description`s and answers, in each direction, whether one takes
every value the other does: `Yes` by a proof over the descriptions, `No` with a `witness` value that the check of both
confirmed, or `Unknown` with the keyword the proof stopped at. `changes` lists the keywords that differ by place in a
value and what each does to the values taken. The search for a witness and the walk for changes have fixed bounds, and
`truncated` says a bound ended the proof or the walk, and a proof that does is `Unknown` with the reason `budget`, never a
`Yes` or a `No` it did not find a value for.

```odin
c, err := schema.compare(old.description, new.description, {as = json.as(.Json)})
if err != nil { return err }
defer schema.comparison_destroy(&c)
if c.old_in_new.verdict != .Yes { fmt.println("a reader of the new schema may refuse old data:", c.old_in_new.witness) }
```

`core/diff` is the changes between two values of any format: `diff.values(a, b, opts)` of two values (nodes of documents, `core.Node_Ref{&doc, core.ROOT}`) lists each
change with its path, `diff.Options` choosing how arrays match (`Sequence`, `Set`, `Position` or a `Key_Rule` by member).
`stury diff` is the same on the command line ([cli.md](cli.md#diff)).

## Read into Odin values

`unmarshal` fills a value from a text during the scan, with no document between them.

```odin
person: Person
if err := json.unmarshal(src, .Json, &person, allocator = alloc); err != nil {
	report(src, err)
}
out, err := json.marshal(person, allocator = alloc)  // {"name":"ada","n":1}
```

- A field's tag is looked up under the format's key (`json`, `csv`), then under the shared key `stury`:
  `` `json:"item_id,required"` ``. A field with no name in its tag keeps its own.
- A member the struct does not have is skipped, and `Read_Options{unknown = .Refuse}` makes it an error. A field
  tagged `unknown` on a `map[string]json.Raw` captures them.
- A member absent from the text keeps the value the target already holds, so defaults are written before the read.
- A repeated key follows `Read_Options.dups`: `.Last` by default, `.First`, or `.Refuse` for an error.
- `Maybe(T)` and pointers take `null`. Enums read by name, unions by the arm their value picks, and a type in
  `Plan_Options.hooks` is read by your procedure.
- `Read_Options.sink` reads on after a refused value and gathers every refusal instead of stopping at the first.
- A program that reads one type many times builds the plan once with `json.plan_make`, `dsv.plan_make` or `yaml.plan_make`, passes it to
  `unmarshal`, and frees it with `json.destroy`. There is no global cache.

[typed.md](typed.md) holds the full type table, the tag flags and the refusal kinds.

### From a document

`typed.unmarshal(&doc, node, &target, &plan)` reads any node of a built document, and `typed.unmarshal(&doc, answer,
&target, &plan)` reads the node a `find` or `scan` answer reached. A path's value is read from the answer, never from a
text.

## Models

`core/model` adds rules to a type: a model checks members' values as they are read, gives absent members their
defaults, records which members a text held, and writes the value back by the same rules.

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
err = model.load(&m, body, &user, &sink)
```

- `load` refuses a missing required member and reads no `read_only` member. A `Fields_Set` member records what the
  text held, which `was_set` asks by the member's Odin name, a load refused with a sink too. A load without a sink
  stops at its first refusal, before any struct it is in closes, and leaves their sets as they were. `validate`
  checks a value built in code by the same rules.
- A load refuses a repeated key as `.Duplicate_Key` with the path to the repeat, where `json.unmarshal` takes the last.
  `Load_Opts{dups = .Last}` or `.First` picks one instead, and only the value that wins is judged. `.All` is
  `.Bad_Option`, since a member holds one value.
- A model copies what it keeps of the registry, so the registry may be destroyed once its models are compiled.
- A CSV or TSV model reads an empty unquoted cell as null, as JSON's `null`: a `Maybe` member holds nil and a plain
  `string` member refuses it as `.Wrong_Kind`. A quoted `""` is the empty string.
- The format tag (`json:`, or `stury:` for every format) names a member and shapes it: a rename, `-`, `omitempty`,
  `omitunset`, `required` and `unknown`, which marks the `extra` member. `model:` holds the rules and the roles:
  `optional`, `read_only`, `write_only`, `not_null`, bounds, `format=`, `pattern=` and `unique`. `required` with
  `optional` is refused. `pattern=` takes the rest of the tag, commas included, so it comes last: a pattern followed
  by an item that reads as one (`pattern=^a+$,len<=3`) is refused, and a pattern that holds such text is added with
  `register_field`.
- `load`, `validate` and `stury check` list the failures in one order: by the value's path, a value before what it
  holds, and the members of one value in the order of the text.
- `model.problem(sink.entries[:], "Invalid body", 422)` makes an RFC 9457 problem document of every refusal, a struct
  that `marshal` writes in any format and `model.problem_destroy` frees.
- `model.patch(&m, &existing, body)` applies a patch text to a value whose struct has a `Fields_Set`. Each member's
  rules judge what the patch holds, and a member the patch leaves out, in the root and in the struct members that hold
  a `Fields_Set`, is neither required nor defaulted and keeps what `existing` holds. Struct validators and
  applicators judge the merged value, `existing` is written only when nothing failed, and a failure's path is in the
  patch. What `existing` holds is from `allocator`, which frees the members the patch replaces, and a failed patch
  frees what it read.
- `model.dump(&m, &user, opts)` writes the value as `marshal` does by the model's plan, never a `write_only` member.
  `Dump_Opts` leaves out the members a load did not set (`exclude_unset`), that hold null (`exclude_none`) or that
  equal their default (`exclude_defaults`), and `check` refuses a value whose written members fail its rules as
  `.Check_Failed`. An option leaves out only a member a load does not require, so every dump of a valid value loads
  back. A member is unset when its `Fields_Set` bit is clear, as pydantic's `exclude_unset` means: a member the load
  took from its default or never read, and every member of a value built in code with an empty set, so dumping a
  loaded PATCH body writes back what it sent. A `read_only` member, which no load sets, and a struct with no
  `Fields_Set` keep their members. A dump writes a `read_only` member, which a load under `Extra.Forbid` refuses as
  `.Not_Allowed`, so such a dump is for the reader of the text and does not load back through the same model. The
  tag `omitunset` leaves one member out when it holds null and is unset, and is refused on a struct with no
  `Fields_Set`. A CSV or TSV row keeps every column and an empty cell reads back as null, so there the options leave
  nothing out: a member that holds null is an empty cell, and every other member's value is written.
  `dump_stream` writes to a stream. Map keys and a struct's `extra` members are written in the order of their keys.
- A struct's `extra` member, `map[string]core.Value` or `map[string]T` tagged `json:",unknown"`, holds the members it
  does not name, each read as its value type. `register(&reg, T, model.Extra.Forbid)` refuses them instead.
- A pointer or `Maybe` member reads null as nil, and with the `not_null` tag item refuses it. A nil `Maybe` with
  neither `omitempty` nor `omitunset` writes null, so `validate` counts it as present: it meets `required` and a
  dependent's `requires`. Tag it to have it absent.
- A `core.Number_Text` member keeps a number's digits at any size and reads null as the empty text, unless tagged
  `not_null`. One held by a list, a map, a `Maybe` or a union takes no null.
- `register_after(&reg, T, "name", check)` adds a validator a member's value meets once it is read. A member takes
  several, run in the order they were registered.
- `Naming.union_tag` is the member every union of the registry is tagged by, and `register(&reg, Union_Rule{type = U,
  tag = "kind"})` sets the tag of one union.
- `model.schema(&m, .Load)` and `.Dump` describe what a load takes and what a dump with no option writes.

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
	text, _ := json.text(&doc, doc.nodes[answer.node], buf[:]) // engines, decoded into the caller's buffer
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

`json.answers`, `dsv.answers`, `yaml.answers` and `cbor.answers` read a path's answers as the scan reaches them, with no document, and `next` gives
them in a loop. Each answer is a `Token_Answer` whose `lo` and `hi` bound its value in the text. The read starts at the
first `next` and walks a batch of answers at a time, from 1 doubling up to `max_batch`, so a loop that ends early has
read little past what it took. A fault comes after every answer read before it, in `it.err` once the loop ends. A loop
that breaks frees the read with `destroy`:

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

`json.each_answer`, `dsv.each_answer`, `yaml.each_answer` and `cbor.each_answer` give the same answers to a callback instead. `toml.answers`
takes the same arguments and builds the text at the first `next`, as every path read of TOML does, then gives its
answers in batches.

The iterator rides on a walk cursor. `json.walk`, `dsv.walk`, `yaml.walk`, `toml.walk`, `cbor.walk` and `xml.walk` take a `^Cursor`: a hook that returns
`.Stop` saves where the walk stood, and `walk_resume` continues from there over the same text, with every token after
the stop delivered as an unbroken walk delivers it. A json cursor resumes after any token. A dsv cursor resumes after a
record's end and holds the header's cells in `cursor.keys`, the caller's storage. A yaml cursor resumes after any token
of a document: its walk reads on past the stop to the end of the block node or flow entry it stopped in, and the resume
gives the tokens it held first, a fault met on the way after them. It keeps that state on the heap until a walk ends,
so `yaml.destroy(&cursor)` frees a cursor left holding a stop. A toml cursor resumes after any token: the walk reads the
whole text into its tables before the first token, and a stop keeps those tables and where the walk stood on the heap
until a resume ends the walk or `toml.destroy(&cursor)` frees them. A cbor cursor resumes after any token: a stop keeps
the walk's open containers and where it stood on the heap, and `cbor.destroy(&cursor)` frees a cursor left holding one. An xml cursor resumes after any token: at the first stop the
walk reads on to the text's end and holds the tokens past the stop and the text's verdict on the heap, which the
resumes give, so a stop's `hi` is the end of the stopped token's span. `xml.destroy(&cursor)` frees a cursor left
holding a stop.
`can_resume` says whether a cursor holds a stop, and a resume on another text is refused with `.Bad_Option`.

## Build a document

`json.build` or `dsv.build` returns a `Document`: a table of nodes that borrows the input. Strings are not
decoded until `text` is called, and numbers not until `number` or `int_value`.
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
		fmt.println(v)               // 1, then 2, then 3
	}
}
n, _ := json.member(&doc, json.ROOT, "n")   // a member by name, without a path
```

`json.children`, `json.pairs`, `json.child_at`, `json.member`, `json.members_named` and `json.length` walk a container.
A reader given a node of the wrong kind, or an index no node holds, returns its miss value and never faults.
[document.md](document.md) lists each reader's miss value.

### Values

A `Value` is null (`nil`), a `bool`, a `f64`, a `Number_Text`, a `string`, an `^Array`, an `^Object` or a node of a
document (`Node_Ref`). A `Number_Text` keeps a number's digits: a number read and not computed on, or an integer no
double holds exactly. `json.new_array`, `json.new_object`, `json.array_append` and `json.object_put` build one in the
context allocator. `spell.decimal_of` reads a number's text as an exact decimal, `spell.decimal_compare` orders two of
them and `spell.decimal_multiple_of` divides one by another, with no limit on the digits or the exponent. The readers
above take a value as they take a node, so one loop reads both:

```odin
v := json.Value(json.Node_Ref{&doc, json.ROOT})
it := json.pairs(v)
for key, member in json.pair_next(&it) {
	fmt.println(key, json.kind(member))
}
```

`json.equal`, `json.compare` and `json.hash` order values as jq does. A cell of a CSV or TSV document is a string unless the document was read with `infer`, in `compare` and `equal`
as in the CLI, and `read_plain = true` reads it as the value it is set against, as the schema-directed conversion (`stury fmt --schema`) does. Two numbers compare by their doubles, and when
both keep their digits and the doubles are equal, by the digits. `json.write_value(v, json.as(.Json))` writes a value
in any format with a token writer. `json.marshal_value(x, &plan)` makes the value of a typed `x`, and
`json.unmarshal_value(v, &target, &plan)` reads a value into a typed target, an integer field from a double that holds
it exactly or from the digits. Both take a plan made with `reads = json.reads(.Json)`, which gives it the read and build
of that spec.

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

`insert` adds an element or a member, `set_node` replaces a node of a list (`set` takes a path), and `remove` drops one. In a delimited table `insert` takes a record as a struct, an array or an object of cells.
In a dsv document, removing a cell from every row drops its column, header included. `dsv.set` and `dsv.commit` edit a
table the same way.

`toml.set`, `yaml.set`, `cbor.set` and their edit lists edit those formats the same way, and each commits its edits
itself, since a TOML table, a YAML block collection and a CBOR container's count are not one range of bytes. The result
is read again by the format's walk, so an edit that breaks a rule of the language is `.Bad_Result`, and an edit the
format cannot make is a `.Frozen` error whose message names the reason. `xml.set`, `html.set` and their edit lists
commit the same way, and HTML's result is read as a browser reads it: one whose tree is not the edited tree is
`.Bad_Result`.

- TOML: a scalar or an inline value is replaced in place, a new member is a line after its table's last line and before
  its sub-tables, a built table or array of tables is a section after the last section of the table it joins, and a
  removed member goes with the comments directly above it. A table is not replaced by a value, and a change of member order, a tag and
  a comment inside an inline table or array are refused.
- YAML: a member or element added to a block collection is a line at its column, one removed goes with its lines and
  the comments above it, and in a flow collection either goes with one separator. A value is written by YAML's writer at
  the indentation of its place, a block scalar is replaced whole, and tags and anchors are facts. An edit inside a value
  an alias reads, of an anchored node an alias reads, a change of member order, and any edit of a text with a `<<` merge key read with
  `merge_keys` are refused.
- XML: a set writes an element's content between its tags, keeping its attributes, an insert is an element laid out by
  the white space before its neighbour, a removal takes that white space, and a rename respells both tags. An array
  on a name fills the name's elements in order. Comments and attributes are facts. A change of member order and a key
  that is no XML name are refused ([markup.md](markup.md#edits)).

### Comments

Comments are facts attached to a node, with a role of `Comment`, `Comment_Inline` or `Comment_Foot`. `.Jsonc` and
`.Json5` documents carry them and a commit keeps them. `json.facts_of(&doc, node, role)` reads a node's facts of one role, and `json.set_fact` and
`json.remove_fact` edit them. `json.set(src, .Jsonc, ...)` leaves the comments of the text as they are:

```
{
	"a": 2 // one
}
```

### Facts

A format that marks a node with a type tag, an anchor or an alias (YAML's `!!str`, `&a` and `*a`, CBOR's tags) holds
them as facts of the roles `Tag`, `Anchor` and `Alias`, which stand just before the node. `set_fact` and `remove_fact`
take them, one non-empty line a body, in YAML, which spells them. TOML refuses them, and a commit in a format that holds
none counts one in `dropped`. A fact the node's spelling carries instead of a span is read by name:
`fact_value(&doc, node, .Style)` gives how a scalar or a collection is written (TOML's `literal` or `hex`, YAML's
`plain`, `double`, `folded` or `flow`), `.Tag` a node's tag or a TOML datetime's type (`date-local`, `datetime`), and
`.Name`, `.Namespace` and `.Content` a markup element's name, namespace and text. A markup element's attributes
are facts of the role `Attribute`, which `attributes_of` walks.

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

A document written back keeps each string and number as its source spelled it unless `respell_strings` is set.
[writer.md](writer.md) holds the `omitempty` tag flag, the hooks and what a format may refuse to write.

### Format a text

`json.format` reads a text and writes it again in the layout `Write_Options` names, judging it on the way. `stury fmt`
is this call.

```odin
out, err := json.format(src, json.as(.Json), json.PRETTY)
if err != nil {
	report(src, err)
	return
}
defer delete(out)
```

`json.as(.Json)` is an `As`, the handle of a format. The calls in `core` and `core/records` that work on any format
(`core.validate`, `core.build`, `json.format`, `json.records_check`, `json.records_open` and the rest) take one where a
`json` or `dsv` call takes a `Spec`, and `core.write` and `json.commit` take one to change the format. `json.as(spec, opts)` and
`dsv.as(spec, opts)` make it, and a document holds the one it was read with. A program that names a `Spec` in each
call links only the walks it reaches. A handle reaches every walk of its format, since it serves a choice made at run time.

## Records and threads

`core/records` reads a text as a sequence of records: NDJSON lines, RFC 7464 `0x1E` records, or CSV rows. A record is
the bytes of one line and the offset it starts at. [examples/records](../examples/records/main.odin):

```odin
faults, _ := json.records_check(src, .Json, framing = .Lines)   // one fault per invalid record, positions in the whole text
defer delete(faults)
```

```
2:9: Invalid literal
1 refused
```

`json.records_open` frames a text and `json.records_open_stream` frames an `io.Reader` through a window. `json.records_next` yields
each record without judging it, so a caller who needs a verdict calls `check` or reads the record. A stream that ends
on a broken frame sets `it.fault`. A reader an entry point opens reads, builds and scans no record until
`it.docs = json.record_docs(.Json)` is set, so a program that only frames or judges links no read.

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
you pass to `json.pool_init` (the calling thread counted, 0 for one per core) answers on that many.

`json.writer_init`, `write_cells` and `writer_end` write one row or line. [records.md](records.md) holds the framing
rules and the Reader contract.

Under `.Entries` the records are the elements or members of the root, or of the container the `entries` path of object
keys names: `json.records_open(src, .Json, framing = .Entries, entries = {"data"})` reads the items of `{"data": [...]}`,
and `Record_Stream_Options.entries` does the same on a stream, which gives each record as it reads it. A YAML stream's
documents are its records, read with `yaml.records_open`, and so are the items of a CBOR sequence, with
`cbor.records_open`, both under `.Concatenated`.

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
- An empty unquoted cell is a `null` to every check and read, and a `Maybe(T)` holds nil for it, which writes back as an empty cell.
- A cell the field cannot hold is an error at that cell:
  `2:6: Expected i64, found "lots" at .[0].population`.
- A number field reads its cell as a loose number: a leading `+`, leading zeros and a point with no digits on one side
  are allowed, so `007` reads as 7 and `.5` as 0.5. `infer`, below, takes only an exact JSON number, so a document
  keeps `007` as the text it is.
- `Options{delimiter = ';', comment = '#'}` reads other delimiters and skips lines starting with `#`.
- A dsv document is an array of objects keyed by the header. `dsv.length(&doc, dsv.ROOT)` is the row count, since the
  header is no record. `dsv.find` reads one cell by `.[1].City` without building the table, `dsv.set` replaces a cell and
  keeps every other byte, and an edit list can insert a row or remove a cell.
- `dsv.kind` reads an empty unquoted cell as `.Null`, as a typed read and the CLI do, and any other cell as
  `.String`. `Options.infer` also reads `true` and `false` as booleans and an exact JSON number as a number. A JSON
  write of the document writes each cell as the kind it reads as.

A cell is quoted on write when it holds the delimiter, a quote or a line break. A list row (`[][]string`) writes one
cell per element, and a row whose length differs from the first row's is refused as `.Wrong_Length`, with the row's
index, since a read without `.Ragged` refuses it. With `Options{tolerate = {.Ragged}}`, given to the write as to the
read, rows of any length are written as they are and read back as they were written. No row is padded, since an empty
cell added on write would read back as data the list did not hold.

## TOML

`toml` reads TOML 1.0 and 1.1 through the calls of `json`. A table's members may be written apart, `[a.b]` before
`[a]`, so a document holds each table as one object, its members in the order the text first names them, and a path
read builds the whole document. A repeated key and a table defined twice are faults of the text, whatever `dups` says.

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

- A datetime is a string whose `Tag` fact names its type: `datetime`, `datetime-local`, `date-local` or
  `time-local`. A hex, octal or binary integer is a number, and `Style` tells its form.
- `toml.marshal(cfg)` writes a struct or a map as a document: the scalars and the arrays that are not of tables as
  `key = value` lines, each table as a `[header]` section after them, and an array of tables as a `[[header]]` section
  per element. A float is written so that it reads back as a float (`1.0`, `-0.0`, `inf`, `nan`). Null has no TOML
  spelling and a key a table repeats cannot be written, both `.Unwritable`. `core.write` with `toml.as(spec)` writes a
  document of any format whose root is an object, and `write.value_tagged` writes a datetime in a token write.
- `toml.checks(.Toml_1_0)` gives a model the format, and `toml.bind_schema` binds a JSON Schema. `toml.check` reads a
  text by a plan as a check, and `toml.plan_of` builds the plan of a `rules.Description`, as `json.plan_of` does.
- A plan from `toml.plan_make` reads a text only when it is made with `reads = toml.reads(spec)`, as json's and yaml's
  do, and `toml.set` with a struct and a plan writes it through those reads.
- A TOML text has no mark that ends it, so under `.Concatenated` a record is the whole text from the reader's position
  to the input's end (`toml.records_open`, `records_open_stream`, `records_check`, `records_each`), and an input of no
  bytes holds none. A stream's text is a record once its input has ended. A reader an entry point opens builds or
  scans a record once it is given `it.docs = toml.record_docs(spec)`.

## YAML

`yaml` reads YAML 1.2 with the core schema through the calls of `json`, one document a text. A plain scalar resolves by
its text and its tag to null, a boolean, a number or a string, and one its core tag does not hold (`!!int yes`) is a
fault. A key is its text, and a key that is a collection is refused. An alias reads as the node of its anchor, while
the bytes the aliases of a document read again stay within `Options.alias_limit` (by default ten times the text, at
least `ALIAS_FLOOR`). `Options.merge_keys` reads `<<` as a merge key. `%YAML 1.1` reads with the 1.2 rules.

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

- A repeated key follows `dups` as in JSON, in every read. Two keys repeat when they resolve to one type and value, so
  `a` and `"a"` repeat each other, and so do `1` and `0x1`, an explicit tag counting as that type. `1` and `"1"` are two
  members. A read by name, a query, a scan, a map or a struct, refuses the second of `1` and `"1"`, or of `1` and
  `0x1`, as `.Duplicate_Key` under every policy but `.First` and `.All`, since it cannot tell which name holds them.
- `yaml.find`, `scan` and `each_answer` read a document in one pass without a build, and build it when the read
  reaches an alias.
- A stream of several documents is read as records under `.Concatenated` (`yaml.records_open`, `records_check`,
  `records_each`), each document one record. A text with more than one document is a fault of `build`.
- `core.write` with `yaml.as(.Yaml_1_2)`, and `yaml.marshal`, write block style when the layout is pretty and flow
  style on one line when it is compact. A string is plain unless a YAML 1.1 or 1.2 reader would read it as another
  type (`yes`, `~`, `0123`, `.inf`, a date), and a string with a line end is a literal block. A document read from YAML
  writes back its comments, tags, anchors, aliases, scalar styles and flow collections. A `typed.Bytes` is written as
  `!!binary` and its base64, which `yaml.unmarshal` reads back.
- `yaml.plan_of` builds the plan of a `rules.Description`, as `json.plan_of` does.
- `yaml.checks(.Yaml_1_2)` gives a model the format, `yaml.bind_schema` binds a JSON Schema, and a typed read of a
  built node reads its plain scalars as the core schema types them.

## XML and HTML

`xml` reads XML 1.0 with the internal subset and namespaces, and `html` reads HTML as the WHATWG standard's parser
does, recovering from every parse error. Both build the markup document shape: an element is a member under its name,
its text is its value, or a `#text` member when it has child elements, and its attributes are facts of its value. Both
validate, build, answer paths, are checked by models and schemas, read into typed values, read records and write, and
edit keeping the bytes no edit reaches. [markup.md](markup.md) holds the shape, the DTD, namespaces and the HTML tree.

```odin
src := transmute([]u8)string(`<order id="7"><item>pen</item><item>ink</item><note>rush &amp; wrap</note></order>`)
doc := xml.build(src, .Xml) or_return
defer xml.destroy(&doc)
order, _ := xml.member(&doc, xml.ROOT, "order")
text_buf: [32]u8
attrs := xml.attributes_of(&doc, order)
_, id_token, _ := xml.attribute_next(&attrs)
id, _ := xml.token_text(doc.readers, &doc.view, id_token, context.temp_allocator)
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

- An element's text is a string, and with `Options.infer` a number or a boolean when it is exactly one. Repeated
  elements are members of one name in the document, which `members_named` and a path under `dups = .All` give one by
  one. The node's value, as `value_member`, `built_value` and `core.write` to JSON read it, makes such a name one
  member, an array of each element in document order, so a path names the document's members and not the array's
  items ([markup.md](markup.md)).
- `attributes_of` walks an element's attributes, and `fact_value` gives an element's `Name`, `Namespace` and `Content`.
  A path step `{uri}local` with such a name matches by namespace.
- `html.build(src, .Document)` builds the tree the standard's algorithm builds, implied elements included, so
  `<p>Pens` is `{"html":{"head":null,"body":{"p":"Pens"}}}` as JSON. `.Fragment` reads a fragment in the context
  element `Options.context_name`. `html.validate` returns the first parse error, which a build passes over.
- `xml.unmarshal` reads a text into a struct whose member takes its name from the tag key `xml`: the member of the
  root element's name, and under it a member per attribute, child element or `#text`. A list member collects the
  siblings of its name, and a number, boolean or union member reads the text by its type. `plan_make` and
  `check` are as json's. `xml.marshal` writes a typed value as `xml.write` writes a document: a struct is an element of
  its members, and a list one element per item. An empty list, text or struct is `.Unwritable`, which reads back as no
  member or null, and `omitempty` leaves it out.
- `xml.write` writes a document of any format whose root is an object of one member as XML: a member is an element, an
  array one element per item, `#text` text and null an empty element. The document of an XML text is written from its
  spans, so its attributes, namespace declarations, references, doctype, comments and instructions stay as written.
  What XML cannot spell so that it reads back, such as a key that is no XML name, a nested array or an empty string,
  is `.Unwritable`. `xml.tokens_init` starts a token write of the same elements under the same refusals, and a pretty
  one is written whole into a buffer, so with a stream it is `.Unsupported`.
- `html.unmarshal`, `check` and `plan_make` read as `xml`'s do, on the tag key `html`, from the tree the
  standard builds, implied elements included. `html.write` writes a document as the WHATWG standard serializes a tree,
  and `html.marshal` and `html.tokens_init` write a typed value and a token write's calls as it writes a built one. A
  value whose text a browser reads back as another tree is `.Unwritable`.
- A text is one record under `.Concatenated`, so `xml.records_each`, `html.records_each` and `records_check` read a
  file as one document.
- `xml.checks(.Xml)` and `html.checks(.Document)` give a model the format, which loads an element's attributes and
  child elements as members, and `bind_schema` binds a JSON Schema.

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

`select(&doc, &sel, from)` matches the descendants of the element whose value is `from`, against the whole document,
as a browser's `querySelectorAll` does. [markup.md](markup.md#selectors) holds what a selector may hold and its costs.

## CBOR

`cbor` reads and writes CBOR (RFC 8949) through the calls of the text formats. [binary.md](binary.md) lists what
differs.

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

- `.Preferred`, `.Deterministic` and `.Length_First` refuse an item not encoded as RFC 8949 sections 4.1 and 4.2 ask,
  and a write in that spec writes it so. The value a read gives does not change.
- `cbor.set(src, .Preferred, path, 22.0)` writes the item again with the value replaced, copying the bytes of every item
  the edit does not reach. A container an edit reaches is written with its new count, and its head keeps its width
  under `.Cbor` where the count fits.
- A map key is an integer, a text string or a byte string. An integer key reads as its digits, so `.["1"]` reads key 1,
  and `1` and `"1"` are one key.
- A tag is a fact: `fact_value(&doc, node, .Tag)` gives the nearest tag's number. A byte string written as JSON is
  base64 text, and a tag is dropped and counted in `dropped`.
- `cbor.marshal` writes a struct as a map, or as an array under `Options{structs = .Array}`, and `unmarshal` reads
  either form.

## One program, several formats

A struct can carry both a `csv` and a `json` tag, and both formats return the same `Error`, so one procedure handles
either ([examples/crossformat](../examples/crossformat/main.odin)):

```odin
City :: struct {
	name:       string `csv:"City" json:"city"`,
	population: Maybe(i64),
	lat, lon:   f64,
}

load :: proc(format: Format, src: []byte, cities: ^[]City) -> json.Error {
	switch format {
	case .Csv:  return dsv.unmarshal(src, .Csv, cities, allocator = context.temp_allocator)
	case .Json: return json.unmarshal(src, .Json, cities, allocator = context.temp_allocator)
	}
	unreachable()
}
```

The program reads the CSV, writes it as JSON, reads the JSON back, and writes CSV that equals the original text. A bad
population reports at its own position in each format:

```
2:6: Expected i64, found "lots" at .[0].population
1:30: Expected i64, found string at .[0].population
```

## Memory and ownership

- A document, a find or scan result and a record borrow the input. Keep the input alive while they are used.
- `destroy` frees a document, including a result from `find` or `scan`, and a path, an edit list, a plan, a record
  writer and a pool. `records_close` frees a record iterator.
- A slice returned by `query`, `check`, `commit`, `set`, `marshal` or `write` is the caller's, freed with `delete` and
  the allocator it was made with.
- `unmarshal` allocates strings, lists and maps with the allocator it is given and frees none of them, not even when it
  refuses the text. Give it an arena or `context.temp_allocator` and free that whole. `Read_Options.borrow_strings`
  makes a string with nothing to decode a slice of the input, so the input must outlive the target.
- A plan belongs to the caller, is read only during a read, and may be shared by any number of reads. It outlives every
  reader and writer given it.
- A document keeps its buffers whole. An arena makes a build cheap and frees all of it at once.
- A build that runs out of memory counts the text and builds again at the exact size, so a text fails only when its
  document does not fit the allocator.

## Limits

| Limit | Value |
|---|---|
| Nesting depth | `json.MAX_DEPTH`, 1024. `Options.max_depth` raises or lowers it per call. A depth beyond `MAX_DEPTH` allocates one byte per level |
| Children counted in a node | `json.MAX_CHILDREN`, 65535. A larger container is still read in full, and its true count is `json.length_exact` |
| Schema arms one inside the other | 256 held subschemas (`anyOf`, `oneOf`, `not`, `if`, `unevaluated*` and the like) that judge one value, each inside the last. A schema that nests more is refused with `.Too_Deep` when bound |
| Numbers | a number too large for binary64 or over the digit and scale caps in `core/spell` comes back as `.Wide`, and the caller reads its span |

A text past a limit gets a fault with a kind, never a crash or a wrong answer.

## Numbers

`number(&doc, node)` returns a `Number` of kind `Int`, `Uint`, `Float` or `Wide`, decoded when read, and false
for a node that is no number. `int_value` returns an `Int`'s `i64`, and false for any other node. A `Wide` number is read from its span. A number is judged when the text is validated, and converted only when it is read.

## Strictness

`.Json` is RFC 8259 with nothing extra: no leading zero, no `NaN`, no invalid UTF-8 and no lone surrogate. `.Jsonc`
and `.Json5` accept their own additions and nothing else. `Options.tolerate` lets a text break a named rule, a
`json.Tolerance`, with a fixed reading: `Invalid_Utf8` reads each ill-formed sequence in a string or a cell as U+FFFD,
`Lone_Surrogate` does the same for an unpaired `\u` escape, `Ragged` takes a dsv record of any width, and `Bare_Quote`
a quote inside an unquoted CSV cell. A rule a format has no instance of changes nothing there. A tolerated text is
never reported as valid under strict rules. `json.Options.refuse_non_finite` refuses JSON5's `Infinity` and `NaN`, for
a reader that has no value for them.

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

Each prints a fixed answer, kept in its `expected.txt`, and `make test-examples` builds and runs all nine.
