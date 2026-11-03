# Records

`core/records` reads a text that holds a list of records, one record at a time, for every format. A caller names the
format once, through the `core.As` value it opens with, and the calls after that name none.

```odin
records.open  :: proc(src: []u8, as: core.As, framing := core.Framing.Lines, allocator := context.allocator) -> records.Reader
records.next  :: proc(it: ^records.Reader) -> (records.Record, bool)
records.read  :: proc(it: ^records.Reader, target: ^$T, plan: ^typed.Plan, opts := typed.Read_Options{}, allocator := context.allocator) -> (more: bool, err: core.Typed_Error)
records.build :: proc(it: ^records.Reader, rec: records.Record, allocator := context.allocator) -> (core.Document, core.Document_Error)
records.column :: proc(it: ^records.Reader, name: string) -> int
records.cell   :: proc(it: ^records.Reader, rec: records.Record, column: int, buf: []u8) -> (string, bool)
records.close :: proc(it: ^records.Reader)
records.check :: proc(src: []u8, as: core.As, framing := core.Framing.Lines, allocator := context.allocator) -> (faults: []core.Fault, err: runtime.Allocator_Error)
```

```odin
it := records.open(src, json.as(.Json))
defer records.close(&it)
for rec in records.next(&it) {
	// rec.text, rec.at
}
if f, bad := it.fault.?; bad {
	// the records ended on a fault
}
```

## Record

| Field | Holds |
|---|---|
| `text` | the record's bytes, a slice of the input |
| `at` | the offset of `text`'s first byte from the input's first byte |
| `key` | the key of an object member under `.Entries`, as written, nil otherwise |

Every offset, in a record and in a fault, counts from the input's first byte, never from the record's.

## Framings

| Framing | A record is |
|---|---|
| `.Lines` | one line (NDJSON): from its first byte that is no whitespace to the LF, less a CR before the LF |
| `.Seq` | the bytes after a 0x1E up to the next 0x1E (RFC 7464), from the first byte that is no whitespace |
| `.Concatenated` | one document of a text of documents one after another, as jq reads its input, from its value's first byte to its last |
| `.Entries` | one element of the root array, or the value of one member of the root object, with its key in `key` |

- A line of whitespace alone is no record, under `.Lines` and between two 0x1E under `.Seq`.
- A UTF-8 byte order mark is passed over at the input's first byte only. One that starts a later record is the record's,
  and JSON refuses it, except in JSON5, where it is whitespace.
- Under `.Lines`, a 0x1E in a line is the record's, and JSON refuses it. Under `.Seq`, an LF is the record's, and a
  `.Seq` record's `text` keeps the whitespace before the next 0x1E.
- Under `.Seq`, a byte that is no whitespace before the first 0x1E ends the records with `Bad_Char` at that byte.
- Under `.Concatenated`, whitespace, 0x1E and comments lie between documents. A number or literal that runs on into a
  byte that may not follow a value, as in `1x`, is one bad token, as jq reads it, and no record.
- Under `.Entries`, a scalar root has no entries and is judged whole. A value is judged one level below the root, so
  under a root at the deepest level an entry may be no container.
- A format with no record reader, or one that does not take the framing, ends the records with `.Bad_Option` before
  any is read.

## Faults

`next` under `.Lines` and `.Seq` only frames. A record's fault comes from what reads its text, and is the fault the
format's `validate` gives for that text alone, at its place in the input. A record that is refused does not end the
records: the next one is read past it.

`next` under `.Concatenated` and `.Entries` frames a record by a walk of its value, which judges it, so a fault ends
the records. Under `.Entries` that fault is the one `validate` gives for the whole text.

`check` judges every record and returns the faults of the refused ones in source order, then the fault that ended the
records, if any. `check` runs on the calling thread.

## Typed reads and documents

`read` frames the next record and reads it into `target` by `plan`, as the format's `unmarshal` of the record's text
reads it, refusals included, with every offset from the input's first byte. It returns false at the input's end, on
the fault in `it.fault`, or with `.Out_Of_Memory` when the reader's own memory is refused. A refused record returns
true and its error, and the next `read` goes on past it. It reads the record in place, so it costs less than `next`
and an `unmarshal` of `rec.text`.

```odin
for {
	v: Log_Line
	more, err := records.read(&it, &v, &plan)
	if !more { break }
	if err.kind != .None { continue } // a refused record
}
```

The reader's first `read` allocates its open containers with `open`'s allocator, and `close` frees them. When a
refused record's value runs past the record's end, `target` may hold values read past it.

Under `.Concatenated` and `.Entries`, `read` reads a record by the walk that frames it, and gives the records `next`
gives: a record that would fault after a refusal is no record, and what its read collected is taken back.

`build` builds the document of a record `next` gave, as the format's `build` of `rec.text` does, with offsets from the
input's first byte.

## Rows

A dsv text is read under `.Lines`, the zero value, so `records.open(src, dsv.as(.Csv))` takes no framing. A record is a
row: `text` runs from its first byte to its line end, less a CR before the LF, and a quoted cell may hold line ends. The
header, empty lines and comment lines are no record. The other framings end the records with `.Bad_Option`.

```odin
it := records.open(src, dsv.as(.Csv))
defer records.close(&it)
price := records.column(&it, "price")
buf: [64]u8
for rec in records.next(&it) {
	text, ok := records.cell(&it, rec, price, buf[:])
}
```

- `next` frames rows by a walk of the text, which judges them, so a fault ends the records with the fault `validate`
  gives for the whole text, and every row whose line end comes before it is given first. `check` returns that fault.
- The walk reads rows in batches of up to 256 and keeps each cell's position. A batch ends early when its buffer is
  three quarters full, and a row too wide for the buffer grows it. The next walk restarts at the next row's first byte
  with the header and the row width carried in.
- `column` returns the index of the first header cell that decodes to `name`, and -1 with no header. It reads the
  first batch, whose rows `next` then gives.
- `cell` returns cell `column` of the row `next` gave last, as a slice of the input when it needs no decode, else
  decoded into `buf`. It returns false for another row, a column past the row, or a `buf` too short.
- `read` reads a row into a row type, from a plan of the row type, not of a list of rows. It reads as `dsv.unmarshal`
  reads a text of the header and that row into the row, refusals of the header included. A list row reads as the row
  alone, since it takes the header as data. A plan of a list of rows is `.Plan_Mismatch`, and a map row with no
  header `.Unsupported`. The read replays the cells the walk kept, so nothing is read twice.
- `build` of the row `next` gave last is a document over the whole input: a `Map` keyed by the header's cells, or an
  `Array` with no header. Its offsets are the input's. Another row is `.Bad_Index`.
- An unclosed quoted field is a `Truncated` fault at its opening quote, the same in `validate`, `unmarshal` and `build`.

## How JSON reads a record

A record is walked in place in the whole input, not in a slice cut from it, and the walk stops at the record's end
whatever bytes follow. That walk gives the same fault as a walk of the record alone, except in two cases, where the
record is walked again cut at its end:

- the walk ran past the record's end, which a value spread over lines does,
- the walk faulted within 16 bytes of the record's end, since a fault can depend on bytes after the one it names (a
  lone surrogate's escape is judged by the escape after it, a UTF-8 lead byte by the bytes after it).

The walk in place reads at most 64 bytes past the record, so a value spread over many lines costs no more than one.

## The format's services

A format gives its record reader as a `records.Services` table in its rodata, which its `core.Spelling.records` points
at. `next` holds one procedure per framing, nil for a framing the format does not take, which frames the next record
and stores the fault that ends the records in `it.fault`. `judge` returns a record's fault, `read` and `build` read
one. `column` and `cell` are a format's with named columns, and `close` frees the memory the format keeps in
`Reader.format`. `core` stores the table as a `rawptr`, since `core/records` imports `core`.
