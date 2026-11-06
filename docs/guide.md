# Library guide

How to use `stury:core`, `stury:json` and `stury:dsv`, with snippets from the programs in [examples/](../examples).
Each public name's doc comment is its contract, and [API.txt](../API.txt) lists every public name. The files in this
directory describe one part each: [document.md](document.md), [paths.md](paths.md), [typed.md](typed.md),
[writer.md](writer.md) and [records.md](records.md).

## Requirements

- A recent Odin. The collection is named `stury` and points at this directory: `-collection:stury=.`. The imports are
  `stury:core`, `stury:json`, `stury:dsv`, `stury:core/records`, `stury:core/typed` and `stury:host`.
- 64-bit little-endian targets: darwin and linux, on amd64 and arm64. The command line also builds on Windows.
- On amd64 the floor is x86-64-v2. Long strings are scanned wider on processors that have AVX-512BW, chosen at run
  time.
- Any optimization level works. The command line builds at `-o:speed`.

## Which package

| Package | Holds |
|---|---|
| `core` | what every format shares: `Document`, paths, `query`, readers, edits, `Write_Options`, errors and `render` |
| `json` | the JSON formats: `validate`, `build`, `find`, `scan`, `set`, `commit`, `unmarshal`, `marshal` |
| `dsv` | the delimited formats, the same calls |
| `core/records` | NDJSON, RFC 7464 and CSV-style text as a sequence of records: `check`, `open`, `open_stream`, `next`, `each`, the writer |
| `core/typed` | plans and the options of a typed read |
| `host` | `Pool`, the threads that `records.each` borrows |

A format is a `Spec` value passed to each call. `json.Spec` is `.Json`, `.Jsonc` or `.Json5`, and `dsv.Spec` is `.Csv`,
`.Tsv` or `.Plain`. `.Json` is strict RFC 8259. `.Jsonc` also takes comments and trailing commas, and `.Json5` takes the
JSON5 grammar. A call that takes both a `Spec` and `Options` reads `Options` for the format's own settings, which for
JSON are `max_depth`, `tolerate` and `refuse_non_finite`, and for dsv `no_header`, `delimiter`, `comment`, `tolerate`, `crlf` and `infer`.

## Errors

An error is a value with a `kind` and the byte it concerns, never a pointer or a string. `err.kind != .None` is the
test. The types are `core.Fault` (a text broke the grammar, from `validate`), `core.Document_Error`,
`core.Path_Error`, `core.Typed_Error` (a read or write of an Odin value) and the path edit errors.

`core.render(writer, src, err)` writes any of them as `line:col: message`, with `at path` for a typed error. Pass
`nil` for `src` when the error has no text, such as a `marshal` refusal.

```odin
report :: proc(src: []u8, e: $E) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	core.render(strings.to_writer(&b), src, e)
	fmt.eprintln(strings.to_string(b))
}
```

## Validate

`json.validate(src, .Json)` judges a text without allocating and returns `Maybe(core.Fault)`.

```odin
if fault, bad := json.validate(src, .Json).?; bad {
	report(src, fault)
}
```

[examples/quickstart](../examples/quickstart/main.odin) validates, reads and writes a value. [examples/jsonc](../examples/jsonc/main.odin)
shows that `.Json` refuses a comment that `.Jsonc` takes:

```
2:9: Unexpected character
```

## Read into Odin values

`unmarshal` fills a value from a text during the scan, with no document between them.

```odin
person: Person
if err := json.unmarshal(src, .Json, &person, allocator = alloc); err.kind != .None {
	report(src, err)
}
out, err := json.marshal(person, allocator = alloc)  // {"name":"ada","n":1}
```

- A field's tag is looked up under the format's key (`json`, `csv`), then under the shared key `stury`:
  `` `json:"item_id,required"` ``. A field with no name in its tag keeps its own.
- A member the struct does not have is skipped, and `Read_Options{unknown = .Refuse}` makes it an error. A field
  tagged `unknown` on a `map[string]typed.Raw` captures them.
- A member absent from the text keeps the value the target already holds, so defaults are written before the read.
- A repeated key follows `Read_Options.dups`: `.Last` by default, `.First`, or `refuse_duplicates` for an error.
- `Maybe(T)` and pointers take `null`. Enums read by name, unions by the arm their value picks, and a type in
  `Plan_Options.hooks` is read by your procedure.
- `Read_Options.collect` reads on after a refused value and gathers every refusal instead of stopping at the first.
- A program that reads one type many times builds the plan once with `json.plan_make` or `dsv.plan_make`, passes it to
  `unmarshal`, and frees it with `typed.plan_destroy`. There is no global cache.

[typed.md](typed.md) holds the full type table, the tag flags and the refusal kinds.

### From a document

`typed.unmarshal(&doc, node, &target, &plan)` reads any node of a built document, and `typed.unmarshal(&doc, answer,
&target, &plan)` reads the node a `find` or `scan` answer reached. A path's value is read from the answer, never from a
text.

## Scan by path

`json.find` answers one path and stops at the answer, and `json.scan` answers every value a path with `[]` reaches.
Neither builds more than the nodes it needs. [examples/scan](../examples/scan/main.odin):

```odin
second_tag, _ := core.parse_path(".tags[1]")
defer core.path_destroy(&second_tag)
doc, answer, err := json.find(src, .Json, second_tag)
defer core.destroy(&doc)
if a, found := answer.?; found && a.outcome == .Found {
	fmt.println(string(core.span(&doc, a.node))) // "engines", quotes and all
	buf: [32]u8
	text, _ := core.text(&doc, a.node, buf[:])    // engines, decoded into the caller's buffer
}

every_tag, _ := core.parse_path(".tags[]")
tags, serr := json.scan(src, .Json, every_tag)
for a in tags.answers {
	fmt.println(string(core.span(&tags, a.node))) // "math", then "engines"
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

## Build a document

`json.build` or `dsv.build` returns a `core.Document`: a table of nodes that borrows the input. Strings are not
decoded until `core.text` is called, and numbers not until `core.number`, `int_value`, `uint_value` or `float_value`.
[examples/roundtrip](../examples/roundtrip/main.odin):

```odin
doc, _ := json.build(src, .Json)
defer core.destroy(&doc)
path, _ := core.parse_path(".skip[]")
defer core.path_destroy(&path)
answers, _ := core.query(&doc, path)
defer delete(answers)
for a in answers {
	if v, ok := core.int_value(&doc, a.node); ok {
		fmt.println(v)               // 1, then 2, then 3
	}
}
n, _ := core.member(&doc, core.ROOT, "n")   // a member by name, without a path
```

`core.children`, `core.pairs`, `core.child_at`, `core.member`, `core.members_named` and `core.length` walk a container.
A reader given a node of the wrong kind, or an index no node holds, returns its miss value and never faults.
[document.md](document.md) lists each reader's miss value.

## Edit and keep every other byte

`set` replaces the value at a path with JSON text. The text is checked before it is spliced in, and every byte outside
the edit, spacing and comments included, is kept. [examples/edit](../examples/edit/main.odin):

```odin
name, _ := core.parse_path(".name")
out, err := json.set(src, .Json, name, `"grace"`)
defer delete(out)
// {"name": "grace",  "tags": ["math"]}
```

Several edits on one document go on an `Edit_List`, each checked as it is recorded, and one commit applies them:

```odin
list := core.edit_list_init(&doc)
defer core.edit_list_destroy(&list)
tags, _ := core.member(&doc, core.ROOT, "tags")
core.set_member(&list, core.ROOT, "n", "1")
core.remove(&list, tags)
committed, _, cerr := json.commit(&list, .Json)
defer delete(committed)
// {"name": "ada","n":1}
```

`core.insert` adds an element, `core.set` replaces a node, and `core.remove` drops one. In a dsv document,
removing a cell from every row drops its column, header included. `dsv.set` and `core.commit` edit a table the same
way.

### Comments

Comments are facts attached to a node, with a role of `Comment`, `Comment_Inline` or `Comment_Foot`. `.Jsonc` and
`.Json5` documents carry them and a commit keeps them. `core.facts_of(&doc, node, role)` reads a node's facts of one role, and `core.set_fact` and
`core.remove_fact` edit them. `json.set(src, .Jsonc, ...)` leaves the comments of the text as they are:

```
{
	"a": 2 // one
}
```

## Write

`json.marshal(value)` and `dsv.marshal(list)` return the text, and `marshal_stream` writes to an `io.Stream`.
`core.write(&doc)` writes a document, and `core.write_stream` streams it. `core.Write_Options` sets the layout:

| Field | Effect |
|---|---|
| `pretty`, `indent`, `tab` | one member a line, with `indent` spaces or a tab per level. `core.PRETTY` is two spaces |
| `ascii` | a rune past U+007F is written as `\uXXXX` |
| `escape_html` | `<`, `>`, `&`, U+2028 and U+2029 are escaped |
| `escape_del` | DEL is written as `\u007f` |
| `sort_keys` | a struct's fields and a document's keys in byte order. A map's keys are always sorted |
| `respell_strings` | a string read from a source is written in the writer's own escapes |

A document written back keeps each string and number as its source spelled it unless `respell_strings` is set.
[writer.md](writer.md) holds the tag flags (`omitempty`, `string`), the hooks and what a format may refuse to write.

## Records and threads

`core/records` reads a text as a sequence of records: NDJSON lines, RFC 7464 `0x1E` records, or CSV rows. A record is
the bytes of one line and the offset it starts at. [examples/records](../examples/records/main.odin):

```odin
as := json.as(.Json)
faults, _ := records.check(src, as, .Lines)   // one fault per invalid record, positions in the whole text
defer delete(faults)
```

```
2:9: Invalid literal
1 refused
```

`records.open` frames a text and `records.open_stream` frames an `io.Reader` through a window. `records.next` yields
each record without judging it, so a caller who needs a verdict calls `check` or reads the record. A stream that ends
on a broken frame sets `it.fault`.

`records.each(src, as, .Lines, task, &data, &pool.runner)` hands every piece of the text to a task on `host.Pool`
threads, each piece an independent `records.Reader`:

```odin
pool: host.Pool
host.pool_init(&pool)
defer host.pool_destroy(&pool)
count := proc(n: ^int, piece: ^records.Reader, _: int) -> bool {
	for _ in records.next(piece) { sync.atomic_add(n, 1) }
	return true
}
records.each(lines, as, .Lines, count, &total, &pool.runner)
```

`records.writer_init`, `write_cells` and `writer_end` write one row or line. [records.md](records.md) holds the framing
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
  `2:6: Value does not fit the field's type at [0].population`.
- `Options{delimiter = ';', comment = '#'}` reads other delimiters and skips lines starting with `#`.
- A dsv document is an array of objects keyed by the header. `core.length(&doc, core.ROOT)` is the row count, since the
  header is no record. `dsv.find` reads one cell by `.[1].City` without building the table, `dsv.set` replaces a cell and
  keeps every other byte, and an edit list can insert a row or remove a cell.
- A cell reads as text unless `Options.infer` is set, which resolves an empty cell as null, `true` and `false` as
  booleans and an exact JSON number as a number.

A cell is quoted on write when it holds the delimiter, a quote or a line break.

## One program, several formats

A struct can carry both a `csv` and a `json` tag, and both formats return `core.Typed_Error`, so one procedure handles
either ([examples/crossformat](../examples/crossformat/main.odin)):

```odin
City :: struct {
	name:       string `csv:"City" json:"city"`,
	population: Maybe(i64),
	lat, lon:   f64,
}

load :: proc(format: Format, src: []byte, cities: ^[]City) -> core.Typed_Error {
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
2:6: Value does not fit the field's type at [0].population
1:30: Value does not fit the field's type at [0].population
```

## Memory and ownership

- A document, a find or scan result and a record borrow the input. Keep the input alive while they are used.
- `core.destroy(&doc)` frees a document, including a result from `find` or `scan`. `core.path_destroy` frees a path,
  `core.edit_list_destroy` a list, `typed.plan_destroy` a plan, and `records.close` a record iterator.
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
| Nesting depth | `core.MAX_DEPTH`, 1024. `Options.max_depth` raises or lowers it per call. A depth beyond `MAX_DEPTH` allocates one byte per level |
| Children counted in a node | `core.MAX_CHILDREN`, 65535. A larger container is still read in full, and its true count is `core.length_exact` |
| Numbers | a number too large for binary64 or over the digit and scale caps in `core/spell` comes back as `.Wide`, and the caller reads its span |

A text past a limit gets a fault with a kind, never a crash or a wrong answer.

## Numbers

`core.number(&doc, node)` returns a `Number` of kind `Int`, `Uint`, `Float` or `Wide`, decoded when read, and false
for a node that is no number. `int_value`, `uint_value` and `float_value` return the value and whether the node is
that kind of number. A `Wide` number is read from its span. A number is judged when the text is validated, and converted only when it is read.

## Strictness

`.Json` is RFC 8259 with nothing extra: no leading zero, no `NaN`, no invalid UTF-8 and no lone surrogate. `.Jsonc`
and `.Json5` accept their own additions and nothing else. `json.Options.tolerate` lets a text break a named rule with a
fixed reading: `Invalid_Utf8` reads each ill-formed sequence as U+FFFD, and `Lone_Surrogate` does the same for an
unpaired `\u` escape. A tolerated text is never reported as valid under strict rules. `json.Options.refuse_non_finite`
refuses JSON5's `Infinity` and `NaN`, for a reader that has no value for them.

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

Each prints a fixed answer, kept in its `expected.txt`, and `make test-examples` builds and runs all eight.
