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
- `unmarshal` never frees what it allocates, even when it refuses the input. Give it an arena and free the
  arena.
- `destroy` frees a value that owns several allocations: a `Document`, a `Request`, a `Type_Plan`, a
  CSV `Record_Reader`. A slice a procedure returns, such as `set`'s output, is one allocation: `delete` it as
  you would any Odin slice.
- A procedure whose result is its only output carries `@(require_results)`, so a call that drops the result
  does not compile.

## Limits

- A document can address 4 GiB - 2 bytes of input (`MAX_ROW_SOURCE`), `validate` has no limit.
- Nesting deeper than 1024 levels is refused by default. You can raise the limit to 2^20.
- A repeated key is a policy (`Duplicates`), and its default depends on the format: JSON keeps the last value,
  and CSV refuses a header that names a column twice. Set `duplicates` to keep the last, the first, all of
  them, or to refuse.

## CSV cells and headers

- CSV cells are text. `csv.unmarshal` reads a cell as its field's type (`007` into a `string` stays `007`, into
  an `int` is `7`), and a cell the type cannot hold is refused. The command line has no field types, so every
  cell there is a string until you `tonumber` it.
- An empty cell with no quotes is absent: its field keeps its zero value (`nil` for a `Maybe`), or is
  `.Missing_Field` when tagged `csv:",required"`. A quoted `""` is a present empty string. Under
  `Quoting.None`, which TSV uses, every empty cell is absent. On the command line the two are `null` and `""`.
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
}
```

A path that is not in the input gives one answer with outcome `.Missing`, so check `outcome` before you read
`lo` and `hi`.

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
`json.build` makes a `Document`, and `json.query` collects the `Node` handles a path reaches.

```odin
src := transmute([]byte)string(`{"name":"ada","n":1,"skip":[1,2,3]}`)
doc, err := json.build(src)
if err != nil {
	os.exit(1)
}
defer json.destroy(&doc)
nodes: [dynamic]json.Node
defer delete(nodes)
if json.query(&doc, json.ROOT, ".skip[]", &nodes) != nil {
	os.exit(1)
}
for n in nodes {
	if v, ok := json.get_int(&doc, n); ok {
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
`json.records` and `json.next_record` walk the records of an NDJSON text without allocating.

```odin
src := transmute([]byte)string("{\"a\":1}\n{\"a\":tru}\n")
it := json.records(src, .NDJSON)
for rec in json.next_record(&it) {
	if e, bad := json.validate(rec.bytes).?; bad {
		e.offset += rec.at
		fmt.println(json.render_error(src, e)) // 2:9: Bad_Literal
	}
}
if e, bad := it.err.(json.Error); bad { // the framing itself failed, so the loop stopped early
	fmt.println(json.render_error(src, e))
}
```

For threads, pass a `host.Batch_Pool`'s `runner` (`import "stury:host"`) to `validate_records` or `each_record`:

```odin
pool: host.Batch_Pool
host.batch_pool_init(&pool) // one worker per core
defer host.batch_pool_destroy(&pool)
faults, _ := json.validate_records(src, .NDJSON, &pool.runner)
defer delete(faults)
for f in faults {
	fmt.println(json.render_error(src, f.err)) // 2:9: Bad_Literal
}
```

### JSONC (`examples/jsonc`)
`dialect = .Jsonc` reads comments and trailing commas, which strict JSON refuses.

```odin
src := transmute([]byte)string("{\n\t\"a\": 1 // one\n}\n")
_, jsonc_bad := json.validate(src, {dialect = .Jsonc}).?
_, strict_bad := json.validate(src).?
fmt.println(jsonc_bad, strict_bad) // false true: only strict JSON refuses the comment
```

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
if err, bad := csv.unmarshal(src, &cities).?; bad {
	fmt.eprintln(err.kind, "at byte", err.offset)
	os.exit(1)
}
fmt.println(cities[1].name, cities[1].population) // Ho, Chi Minh nil

out, err := csv.marshal(cities) // src again: "Ho, Chi Minh" keeps its quotes and the absent population stays empty
```

`render_error` locates a refused cell (`2:6: Wrong_Kind at [0].population`). Column order does not matter, and
a column the struct lacks is ignored unless `unknown_fields = .Refuse`.

A `Dialect` reads other delimited text through the same calls. `no_header` takes the first record as data,
with column k filling the struct's field k:

```odin
tsv := transmute([]byte)string("City\tpopulation\tlat\tlon\nOslo\t709000\t59.91\t10.75\n")
_, _ = csv.unmarshal(tsv, &cities, {dialect = csv.TSV}).?

// No header: column k is the struct's field k. A semicolon delimiter, and lines starting with # skipped.
plain := transmute([]byte)string("# name;population;lat;lon\nOslo;709000;59.91;10.75\n")
opts := csv.Unmarshal_Opts{dialect = {delimiter = ';', comment = '#'}, no_header = true}
_, _ = csv.unmarshal(plain, &cities, opts).?
```

`build` keeps the span of every cell as a `Document`, and `find` reads one cell without building one. A path
counts rows from the first record after the header, and columns by index or by the header's name:

```odin
doc, _ := csv.build(src)
defer csv.destroy(&doc)
col, _ := csv.column(&doc, "lat")
lat, _ := csv.get_float(&doc, 0, col)
fmt.println(csv.row_count(&doc), lat) // 2 59.91

a, _ := csv.find(src, ".[1].City")
text, _, _ := csv.field_text(src, csv.Field{lo = a.lo, hi = a.hi})
fmt.println(string(text)) // Ho, Chi Minh
```

The edits keep every other byte, quoting included. A cell is spelled as `marshal` spells it, and an edit that
would not read back as the same table is refused:

```odin
edited, _ := csv.set(src, ".[0].population", 710000)
fmt.print(string(edited)) // City,population,lat,lon
//                           Oslo,710000,59.91,10.75
//                           "Ho, Chi Minh",,10.82,106.63

added, _ := csv.insert(src, csv.APPEND, City{name = "Bergen", lat = 60.39, lon = 5.32})
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
	text, _, _ := csv.field_text(rec.src, rec.fields[0])
	fmt.println(rec.at, len(rec.fields), string(text)) // 0 4 City, then 24 4 Oslo, then 48 4 Ho, Chi Minh
}

count := proc(data: rawptr, piece: ^csv.Records, k: int) -> bool {
	for _ in csv.next_record(piece) {
		sync.atomic_add((^int)(data), 1)
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
Each format reads its own tag key (`csv:"City" json:"city"`); a field with no tag uses its own name in both.
Both `unmarshal`s return `core.Unmarshal_Error`, and `core.render_error` writes it, a `validate` fault
(`core.Error`) or an edit refusal (`core.Path_Error`) for either format. `json.Error`, `csv.Error` and the
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
		return csv.unmarshal(src, cities)
	case .Json:
		return json.unmarshal(src, cities)
	}
	unreachable()
}

// core.render_error writes the fault of either format as `line:col: kind at path`.
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
	report(bad_csv, err) // 2:6: Wrong_Kind at [0].population
}
if err, bad := load(.Json, bad_json, &cities).?; bad {
	report(bad_json, err) // 1:30: Wrong_Kind at [0].population
}
```
