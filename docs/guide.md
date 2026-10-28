# Library guide

How to use `stury:json` and `stury:csv`, with snippets from the programs in `examples/`. Each public name's
doc comment is its contract. [json/json.odin](../json/json.odin), [csv/csv.odin](../csv/csv.odin) and
[core/core.odin](../core/core.odin) map the names to their files.

## Requirements

- Odin `dev-2026-10`. stury follows Odin's monthly releases closely.
- 64-bit little-endian targets: darwin and linux, on amd64 and arm64. The command line also builds on Windows.
- On amd64 the floor is x86-64-v2 (SSSE3, SSE4.1, POPCNT). On processors with AVX-512BW, long strings are
  scanned 64 bytes at a time, chosen at run time.
- Any optimization level works. The published speeds were measured at `-o:speed`, which `make build-cli` also
  uses.
- To build the command line: `make` and `git`. To run `make test`: also `python3`.

## Memory and ownership

- Keep your input buffer alive while you use answers or a document: both point into it. `unmarshal` copies
  strings into its allocator, so you can free the input after it returns, unless you set `borrow_strings` to
  make escape-free strings and `Raw` values slice the input instead.
- `unmarshal` and `record_read_init` take the allocator a value is read with as a required argument. They never
  free what they allocate, even when they refuse the input, and there is no procedure that frees a value: give
  them an arena (or `context.temp_allocator`) and free it whole.
- `destroy` frees a value that owns several allocations: a `Document`, a `Request`, a `Type_Plan`, a
  CSV `Record_Reader`. A slice a procedure returns, such as `set`'s output, is one allocation: `delete` it as
  you would any Odin slice.
- A procedure whose result is its only output carries `@(require_results)`, so a call that drops the result
  does not compile.

## Limits

- A document can address 4 GiB - 2 bytes of input (`MAX_ROW_SOURCE`), `validate` has no limit.
- Nesting deeper than 1024 levels is refused by default. You can raise the limit to 2^20.
- A repeated key or header name is a policy (`Duplicates`). Under the default the readers keep the last, and the
  edits refuse one on the edit's path. Set `duplicates` to keep the last, the first, all of them, or to
  refuse.

## CSV cells and headers

- CSV cells are text. `csv.unmarshal` reads a cell as its field's type (`007` into a `string` stays `007`, into
  an `int` is `7`), and a cell the type cannot hold is refused. The command line has no field types, so every
  cell there is a string until you `tonumber` it.
- An empty cell with no quotes is absent: its field keeps its zero value (`nil` for a `Maybe`), or is
  `.Missing_Field` when tagged `csv:",required"`. A quoted `""` is a present empty string. Under
  `Quoting.None` and `Quoting.Backslash`, which TSV uses, every empty cell is absent. On the command line the two are `null` and `""`.
- The first record names the columns unless `no_header` is set. A file without a header read as if it had one
  loses its first record, and names that match no field are ignored, so the result can be zero values or no
  rows and no error. `unknown_fields = .Refuse` or a `csv:",required"` field makes that an error.

## Examples

Each snippet is cut from the program in [`examples/`](../examples) that its heading names. Run one from the
repository root with `odin run examples/scan -collection:stury=.`. `make test` builds and runs all of them.

### Read one value by path (`examples/scan`)
`json.find` answers one path in one pass and keeps nothing. The answer is a range (`lo`, `hi`) of `src`, and
its `outcome` says whether the path landed.

```odin
src := transmute([]byte)string(`{"name": "ada", "tags": ["math", "engines"]}`)
a, err := json.find(src, ".tags[1]")
if err != nil {
	os.exit(1)
}
if a.outcome == .Found {
	fmt.println(string(src[a.lo:a.hi])) // "engines", quotes and all
	text, _, _ := json.answer_text(src, a) // decoded, a slice of src unless it held an escape
	fmt.println(text) // engines
}
```

A path that is not in the input gives one answer with outcome `.Missing`, so check `outcome` before you read
`lo` and `hi`. `answer_text` reads a scalar answer's text in either format: a string decoded by the dialect's
escapes into the allocator when it holds one (`escaped` true, yours to free), any other scalar as written.

Every procedure that takes a path takes it as text in the jq subset or as a `json.Path` of `json.Step` values:

```odin
json.Path{steps = {json.Name("tags"), json.Index(1)}} // the same request as ".tags[1]"
```

For every answer of a path, several paths, or one request run over many records, `json.scan` fills a
`Request`. Its type parameter lists the kinds of answer wanted: `{.Path}` asks for the bytes of the values at
some paths, the other kinds for a whole document. `json.answers` reads one path's answers.

```odin
req: json.Request({.Path})
defer json.destroy(&req)
if json.request_init(&req, ".tags[]") != nil || json.scan(src, &req) != nil {
	os.exit(1)
}
tags, _ := json.answers(&req, 0) // one path: nothing to group, so no error
for t in tags {
	fmt.println(string(src[t.lo:t.hi])) // "math", then "engines"
}
```

### Build and query a document (`examples/roundtrip`)
`json.build` makes a `Document`, and `json.query` collects the answers a path gives, each with the `Node` it
reached. `json.query_in` answers a path from a given node instead of the root.

```odin
src := transmute([]byte)string(`{"name":"ada","n":1,"skip":[1,2,3]}`)
doc, err := json.build(src)
if err != nil {
	os.exit(1)
}
defer json.destroy(&doc)
answers: [dynamic]json.Answer
defer delete(answers)
if json.query(&doc, ".skip[]", &answers) != nil {
	os.exit(1)
}
for a in answers {
	if v, ok := json.get_int(&doc, a.node); ok {
		fmt.println(v)
	}
}
```

### Edit in place (`examples/edit`)
`json.set` replaces the value at a path and keeps every other byte of the source.

```odin
src := transmute([]byte)string(`{"name": "ada",  "tags": ["math"]}`)
out, err := json.set(src, ".name", "grace")
if err != nil {
	os.exit(1)
}
defer delete(out)
fmt.println(string(out)) // {"name": "grace",  "tags": ["math"]}
```

### NDJSON records (`examples/records`)
`json.records` and `json.next_record` walk the records of an NDJSON text without allocating. The other
framings are `.JSON_Seq` (RFC 7464), `.Root_Entries` (the entries of one root array or object) and
`.Concatenated`, jq's input: texts one after another with or without whitespace between them, each ending where
its strings and brackets say, so a malformed text is cut there and its read refuses it.

```odin
src := transmute([]byte)string("{\"a\":1}\n{\"a\":tru}\n")
it := json.records(src, {framing = .NDJSON})
for rec in json.next_record(&it) {
	if e, bad := json.validate(rec.bytes).?; bad {
		e.offset += rec.at
		fmt.println(json.render_error(src, e)) // 2:9: Invalid literal
	}
}
if e, bad := it.err.(json.Error); bad { // the framing itself failed, so the loop stopped early
	fmt.println(json.render_error(src, e))
}
```

`json.records_from` reads the records of an `io.Reader` under every framing, with the records, offsets and fault
`records` gives over the whole text. Under `.NDJSON`, `.JSON_Seq` and `.Concatenated` it holds the record being read and
a chunk, and `max_record_bytes` caps a record and so that window; under `.None` and `.Root_Entries` it holds the whole
input. A record's bytes are the window's, valid until the next `next_record`; judge one with
`json.judge_record(&rr, rec, read)`, and render a fault against `json.record_window(&rr)`.

```odin
r: strings.Reader
strings.reader_init(&r, string(src))
rr := json.records_from(io.to_reader(strings.reader_to_stream(&r)), {framing = .NDJSON})
defer json.destroy(&rr)
for rec in json.next_record(&rr) {
	fmt.println(rec.at, string(rec.bytes)) // 0 {"a":1}, then 8 {"a":tru}
}
```

`json.records_pushed` is the same reader for a caller that reads the stream itself, on a thread of its own say.
It hands each window in with `json.record_push(&rr, window, ended)`; when `next_record` is false,
`json.record_carry(&rr)` says whether a window is wanted and which bytes of the last one it must start with.
The windows stay the caller's.

Under `.Concatenated` a caller that reads each text, to validate, build or unmarshal it, can let that read end
the text rather than have the framing find its end first: `json.next_record_open` hands an array, object or
string out open, running to the end of the bytes so far, and `json.end_record(&rr, read)` ends it where the read
stopped (`.Trailing`), or says `cut` when the read ran out of bytes and the next window is wanted.
`json.record_skip(&rr, to)` goes on from an offset the caller read up to by other means, or back to one to read a
record again.

```odin
for {
	rec := json.next_record_open(&rr) or_break
	read := json.validate(rec.bytes) // stops at the text's end with `.Trailing`
	text, cut := json.end_record(&rr, read)
	if cut {
		break // push the next window, starting with `record_carry`'s bytes
	}
	if text.bytes != nil {
		rec = text // an array, object or string, ended by the read
	}
	fmt.println(rec.at, string(rec.bytes))
}
```

For threads, pass a `host.Batch_Pool`'s `runner` (`import "stury:host"`) to `validate_records` or `each_record`:

```odin
pool: host.Batch_Pool
host.batch_pool_init(&pool) // one worker per core
defer host.destroy(&pool)
faults, _ := json.validate_records(src, {framing = .NDJSON}, &pool.runner)
defer delete(faults)
for f in faults {
	fmt.println(json.render_error(src, f.err)) // 2:9: Invalid literal
}
```

The same runner splits one large document. `validate` and `build` read a big root array (or the array of a root
object like `{"logs": [...]}`, for `validate`) in pieces on its threads and give exactly what one thread gives:
the same verdict, the same first fault and offset, the same rows. A piece that fails hands the text to one
thread, so a malformed text costs a second read.

```odin
err := json.validate(src, runner = &pool.runner)
doc, berr := json.build(src, runner = &pool.runner)
defer json.destroy(&doc)
```

### JSONC (`examples/jsonc`)
`dialect = .Jsonc` reads comments and trailing commas, which strict JSON refuses.

```odin
src := transmute([]byte)string("{\n\t\"a\": 1 // one\n}\n")
_, jsonc_bad := json.validate(src, {dialect = .Jsonc}).?
_, strict_bad := json.validate(src).?
fmt.println(jsonc_bad, strict_bad) // false true: only strict JSON refuses the comment
```

`dialect = .Json5` reads JSON5 1.0.0 in `validate`, `scan`, `find`, `query`, `build` and `unmarshal`. The edits
refuse it with `.Bad_Option`.

### CSV (`examples/csv`)
`stury:csv` (`import csv "stury:csv"`) reads rows into structs by the header's column names and writes them
back.

```odin
City :: struct {
	name:       string `csv:"City"`,
	population: Maybe(i64),
	lat, lon:   f64,
}

src := transmute([]byte)string("City,population,lat,lon\nOslo,709000,59.91,10.75\n\"Ho, Chi Minh\",,10.82,106.63\n")
cities: []City
if err, bad := csv.unmarshal(src, &cities, allocator = context.temp_allocator).?; bad {
	fmt.eprintln(err.kind, "at byte", err.offset)
	os.exit(1)
}
fmt.println(cities[1].name, cities[1].population) // Ho, Chi Minh nil

out, err := csv.marshal(cities) // src again: "Ho, Chi Minh" keeps its quotes and the absent population stays empty
```

`render_error` locates a refused cell (`2:6: Value of the wrong kind at [0].population`). Column order does not matter, and
a column the struct lacks is ignored unless `unknown_fields = .Refuse`.

A row can also be a list of cells, which reads every record (the header too) and writes no header, or a map of
the header's names to cells, where an absent cell is no entry and `marshal` writes the sorted union of the keys:

```odin
rows: [][]string                // or [][]Maybe(string), to tell an absent cell from a quoted ""
_ = csv.unmarshal(src, &rows, allocator = context.temp_allocator)   // rows[0] is the header
named: []map[string]string
_ = csv.unmarshal(src, &named, allocator = context.temp_allocator)  // named[1]["City"] is "Ho, Chi Minh"; named[1] has no "population"
```

A `Dialect` reads other delimited text through the same calls. `no_header` takes the first record as data,
with column k filling the struct's field k:

```odin
tsv := transmute([]byte)string("City\tpopulation\tlat\tlon\nOslo\t709000\t59.91\t10.75\n")
_, _ = csv.unmarshal(tsv, &cities, {dialect = csv.TSV}, allocator = context.temp_allocator).?

// No header: column k is the struct's field k. A semicolon delimiter, and lines starting with # skipped.
plain := transmute([]byte)string("# name;population;lat;lon\nOslo;709000;59.91;10.75\n")
opts := csv.Unmarshal_Opts{dialect = {delimiter = ';', comment = '#'}, no_header = true}
_, _ = csv.unmarshal(plain, &cities, opts, allocator = context.temp_allocator).?
```

`build` reads a text into a `Document`, core's rows as a JSON document has them: an array of records, each an
object of the header's names (an array without a header), each cell a string and an empty cell null. It is read
with core's readers, and `csv.query` answers a path over it as `json.query` does. `csv.record_document` makes one
record a document of its own, keyed by a `Header` that `csv.header_of` reads from the header record. `find` reads
one cell without building a document, and `csv.scan` fills a `Request` as `json.scan` does; their paths count
rows from the first record after the header, and columns by index or by the header's name:

```odin
doc, _ := csv.build(src)
defer csv.destroy(&doc)
oslo := csv.child(&doc, csv.ROOT, 0)
lat, _ := csv.get_string(&doc, csv.child(&doc, oslo, "lat"))
fmt.println(csv.child_count(&doc, csv.ROOT), lat) // 2 59.91

a, _ := csv.find(src, ".[1].City")
text, _, _ := csv.answer_text(src, a)
fmt.println(text) // Ho, Chi Minh
```

The edits keep every other byte, quoting included. A cell is spelled as `marshal` spells it, and an edit that
would not read back as the same table is refused:

```odin
edited, _ := csv.set(src, ".[0].population", 710000)
fmt.print(string(edited)) // City,population,lat,lon
//                           Oslo,710000,59.91,10.75
//                           "Ho, Chi Minh",,10.82,106.63

added, _ := csv.insert(src, ".", csv.APPEND, City{name = "Bergen", lat = 60.39, lon = 5.32})
fmt.print(string(added)[len(src):]) // Bergen,,60.39,5.32

trimmed, _ := csv.remove(src, ".[].population") // the column, header included
```

`records_from` reads a stream from an `io.Reader` in bounded memory, with the same records, offsets and fault
as `records` on the whole text. `each_record` runs a task on pieces of a text on a `host.Batch_Pool`, and
`csv.validate` takes the same runner. `write_record` appends one record of text cells to a buffer:

```odin
r: strings.Reader
strings.reader_init(&r, string(src))
rr := csv.records_from(io.to_reader(strings.reader_to_stream(&r)))
defer csv.destroy(&rr)
for rec in csv.next_record(&rr) {
	text, _, _ := csv.field_text(rec, 0)
	fmt.println(rec.at, len(rec.fields), text) // 0 4 City, then 24 4 Oslo, then 48 4 Ho, Chi Minh
}

count := proc(n: ^int, piece: ^csv.Records, k: int) -> bool {
	for _ in csv.next_record(piece) {
		sync.atomic_add(n, 1)
	}
	return true
}
rows: int
_, _ = csv.each_record(src, count, &rows, runner = &pool.runner).? // pool as for validate_records above
fmt.println(rows) // 3: the header and two rows

line: [dynamic]u8
_ = csv.write_record(&line, []Maybe(string){"Tromsø", nil, "69.65", "18.96"})
fmt.print(string(line[:])) // Tromsø,,69.65,18.96
```

### CSV and JSON from one struct (`examples/crossformat`)
Each format reads its own tag key (`csv:"City" json:"city"`), then the shared key both read (`stury:"city"`); a
field with neither uses its own name. A `Type_Plan` made by either package's `type_plan_init` is taken by both
formats' calls, so one plan's hooks and enum spelling serve both; an option a format does not have is ignored.
Both `unmarshal`s return `core.Unmarshal_Error`, and `core.render_error` writes it, a `validate` fault
(`core.Error`), an edit refusal (`core.Path_Error`) or a `marshal` refusal (`core.Marshal_Error`, with the path to
the value refused and no text, so `src` is nil) for either format. `json.Error`, `csv.Error` and the
packages' `Unmarshal_Error` are aliases of core's types; `core/core.odin` lists what the formats share.

```odin
import "stury:core"
import csv "stury:csv"
import json "stury:json"

City :: struct {
	name:       string `csv:"City" json:"city"`,
	population: Maybe(i64),
	lat, lon:   f64,
}

Format :: enum {
	Csv,
	Json,
}

// Both formats return core's Unmarshal_Error, so one function handles either.
load :: proc(format: Format, src: []byte, cities: ^[]City) -> Maybe(core.Unmarshal_Error) {
	switch format {
	case .Csv:
		return csv.unmarshal(src, cities, allocator = context.temp_allocator)
	case .Json:
		return json.unmarshal(src, cities, allocator = context.temp_allocator)
	}
	unreachable()
}

// core.render_error writes the fault of either format as `line:col: text at path`.
report :: proc(src: []byte, err: core.Unmarshal_Error) {
	fmt.println(core.render_error(src, err))
}
```

Read CSV, write JSON, read that back and write CSV again:

```odin
cities: []City
if err, bad := load(.Csv, table, &cities).?; bad {
	report(table, err)
	os.exit(1)
}
as_json, _ := json.marshal(cities)
fmt.println(string(as_json)) // [{"city":"Oslo","population":709000,"lat":59.91,"lon":10.75},{"city":"Ho, Chi Minh","population":null,"lat":10.82,"lon":106.63}]

back: []City
_, _ = load(.Json, as_json, &back).?
as_csv, _ := csv.marshal(back)
fmt.println(string(as_csv) == string(table)) // true
```

A population that is not a number, reported for each format:

```odin
bad_csv := transmute([]byte)string("City,population,lat,lon\nOslo,lots,59.91,10.75\n")
bad_json := transmute([]byte)string(`[{"city":"Oslo","population":"lots","lat":59.91,"lon":10.75}]`)
if err, bad := load(.Csv, bad_csv, &cities).?; bad {
	report(bad_csv, err) // 2:6: Value of the wrong kind at [0].population
}
if err, bad := load(.Json, bad_json, &cities).?; bad {
	report(bad_json, err) // 1:30: Value of the wrong kind at [0].population
}
```
