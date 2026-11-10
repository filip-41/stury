# Library guide

How to use `stury:json` and `stury:dsv`, with snippets from the programs in [examples/](../examples). A program imports the
package of its format and calls everything through it. Each public name's doc comment is its contract, and
[API.txt](../API.txt) lists the names of the format packages, then the names a format's author reads.
[API_SHARED.txt](../API_SHARED.txt) lists the public names that only the packages of this repository use. The files in this
directory describe one part each: [document.md](document.md), [paths.md](paths.md), [typed.md](typed.md),
[writer.md](writer.md) and [records.md](records.md).

## Requirements

- Odin `dev-2026-11` or later. The collection is named `stury` and points at this directory: `-collection:stury=.`.
  A program imports `stury:json`, `stury:dsv` or both. Those packages export the names of `stury:core`,
  `stury:core/typed`, `stury:core/write`, `stury:core/records` and `stury:host` that a user calls.
- 64-bit little-endian targets: darwin and linux, on amd64 and arm64. The command line also builds on Windows.
- On amd64 the floor is x86-64-v2. Long strings are scanned wider on processors that have AVX-512BW, chosen at run
  time.
- Any optimization level works. The command line builds at `-o:speed`.

## Which package

| Package | Holds |
|---|---|
| `json` | the JSON formats: `validate`, `build`, `find`, `scan`, `set`, `query`, `commit`, `unmarshal`, `marshal`, and the names of the packages below that a user calls: `Document`, `Error`, `render`, `parse_path`, `destroy` and the rest |
| `dsv` | the delimited formats, the same calls and names |
| `core` | what every format shares, and the interface a format's author or a run-time choice of format uses: `As`, `build` and `validate` over a handle |
| `core/records` | NDJSON, RFC 7464 and CSV-style text as a sequence of records, reached as `records_check`, `records_open`, `records_open_stream`, `records_next`, `records_each` and the writer |
| `core/typed` | plans and the options of a typed read |
| `host` | `Pool`, the threads that `records_each` borrows |

A format is a `Spec` value passed to each call. `json.Spec` is `.Json`, `.Jsonc` or `.Json5`, and `dsv.Spec` is `.Csv`,
`.Tsv` or `.Plain`. `.Json` is strict RFC 8259. `.Jsonc` also takes comments and trailing commas, and `.Json5` takes the
JSON5 grammar. A call that takes both a `Spec` and `Options` reads `Options` for the format's own settings, which for
JSON are `max_depth`, `tolerate` and `refuse_non_finite`, and for dsv `no_header`, `delimiter`, `comment`, `tolerate`, `crlf` and `infer`.

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

`core/schema` compiles a JSON Schema (drafts 4 to 2020-12) once and binds it to a format. `schema.check` judges a text
and puts every failure in a `typed.Sink`, each with its position, its path and the keywords that failed it. With a
`core.Runner`, a long text of records (`schema.check_records`) or an array at the root whose rules apply to each entry
is checked on its threads, with the entries a serial check gives. `schema.write_basic` and `write.write_problem` write the
entries as the JSON Schema basic output or an RFC 9457 problem document.

```odin
doc, _ := core.build(schema_text, json.as(.Json))
c, _ := schema.compile(&doc, core.ROOT, {resolver = {as = json.as(.Json)}})
b, _ := schema.bind(&c, json.as(.Json))
sink := typed.Sink{}
defer typed.sink_destroy(&sink)
if schema.check(&b, src, &sink) != nil {
	for e in sink.entries { core.render_entry(w, src, e) }
}
```

`stury check --schema` is the same check on the command line ([cli.md](cli.md#schema-check)).

`schema.infer` takes in values (and `schema.infer_records` the records of a text, on a runner's threads) and
`schema.inferred` gives the description they all pass, which `schema.write` writes as JSON Schema. `schema.sample(&d, as,
{count = 3, seed = 1})` writes values that pass a description in the format `as`, and `invalid = true` values that fail it.

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
- A program that reads one type many times builds the plan once with `json.plan_make` or `dsv.plan_make`, passes it to
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
	email: Maybe(string),
	role:  string `model:"optional"`,
	set:   model.Fields_Set,
}

reg: model.Registry
model.register(&reg, User, "role", "member")
m, err := model.compile(&reg, User, json.reads(.Json))
user: User
err = model.load(&m, body, &user, &sink)
```

- `load` refuses a missing required member and reads no `read_only` member. A `Fields_Set` member records what the
  text held, which `was_set` asks by name. `validate` checks a value built in code by the same rules.
- `model.problem(sink.entries[:], "Invalid body", 422)` makes an RFC 9457 problem document of every refusal, a struct
  that `marshal` writes in any format.
- `load` with `Load_Opts{partial = true}` reads a patch: the root and its struct members that hold a `Fields_Set`
  miss no member and give none its default, and every other struct reads in full.
  `model.merge(&m, &existing, &patch)` then copies what the patch's `Fields_Set` holds, and its captured members, into
  `existing`, from the allocator given, so the patch can be freed.
- `model.dump(&m, &user, opts)` writes the value as `marshal` does by the model's plan, never a `write_only` member.
  `Dump_Opts` leaves out the members a load did not set (`exclude_unset`), that hold null (`exclude_none`) or that
  equal their default (`exclude_defaults`), and `check` refuses a value whose written members fail its rules as
  `.Check_Failed`.
  `dump_stream` writes to a stream. Map keys and a struct's `extra` members are written in the order of their keys.
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

`json.answers` and `dsv.answers` read a path's answers as the scan reaches them, with no document, and `next` gives
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

`json.each_answer` and `dsv.each_answer` give the same answers to a callback instead.

The iterator rides on a walk cursor. `json.walk` and `dsv.walk` take a `^Cursor`: a hook that returns `.Stop` saves
where the walk stood, and `walk_resume` continues from there over the same text, with every token after the stop
delivered as an unbroken walk delivers it. A json cursor resumes after any token. A dsv cursor resumes after a record's
end and holds the header's cells in `cursor.keys`, the caller's storage. `can_resume` says whether a cursor holds a stop, and a resume
on another text is refused with `.Bad_Option`.

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
as in the CLI, and `read_plain = true` reads it as the value it is set against, as a schema's rules (`enum`, `const`,
`uniqueItems`) do, so `type: integer` takes the cell `1`. Two numbers compare by their doubles, and when
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

### Comments

Comments are facts attached to a node, with a role of `Comment`, `Comment_Inline` or `Comment_Foot`. `.Jsonc` and
`.Json5` documents carry them and a commit keeps them. `json.facts_of(&doc, node, role)` reads a node's facts of one role, and `json.set_fact` and
`json.remove_fact` edit them. `json.set(src, .Jsonc, ...)` leaves the comments of the text as they are:

```
{
	"a": 2 // one
}
```

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
on a broken frame sets `it.fault`. A reader opened with a constant spec reads, builds and scans no record until
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

`json.writer_init`, `write_cells` and `writer_end` write one row or line. [records.md](records.md) holds the framing
rules and the Reader contract.

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
- An empty cell is an absent value for `Maybe(T)`, and writes back as an empty cell.
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
| [model](../examples/model/main.odin) | a model's load, problem document, partial patch, `merge` and `dump` |

Each prints a fixed answer, kept in its `expected.txt`, and `make test-examples` builds and runs all nine.
