# Records

`core/records` reads a text that holds a list of records, one record at a time, for every format. A caller names the
format once, through the `core.As` value it opens with, and the calls after that name none.

```odin
records.open  :: proc(src: []u8, as: core.As, framing := core.Framing.Lines, at: u64 = 0, allocator := context.allocator) -> records.Reader
records.open_stream :: proc(input: io.Reader, as: core.As, framing := core.Framing.Lines, opts := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader
records.next  :: proc(it: ^records.Reader) -> (records.Record, bool)
records.read  :: proc(it: ^records.Reader, target: ^$T, plan: ^typed.Plan, opts := typed.Read_Options{}, allocator := context.allocator) -> (more: bool, err: core.Typed_Error)
records.build :: proc(it: ^records.Reader, rec: records.Record, allocator := context.allocator) -> (core.Document, core.Document_Error)
records.scan  :: proc(it: ^records.Reader, path: core.Path, read := core.Path_Options{}) -> (rec: records.Record, doc: core.Document, err: core.Path_Error, more: bool)
records.column :: proc(it: ^records.Reader, name: string) -> int
records.cell   :: proc(it: ^records.Reader, rec: records.Record, column: int, buf: []u8) -> (string, bool)
records.cells  :: proc(it: ^records.Reader, rec: records.Record, buf: []u8) -> ([]Maybe(string), bool)
records.next_window :: proc(it: ^records.Reader) -> (window: []u8, base: u64, ok: bool)
records.close :: proc(it: ^records.Reader)
records.check :: proc(src: []u8, as: core.As, framing := core.Framing.Lines, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> (faults: []core.Fault, err: runtime.Allocator_Error)
records.validate :: proc(src: []u8, as: core.As, runner: ^core.Runner = nil) -> Maybe(core.Fault)
records.each :: proc(src: []u8, as: core.As, framing: core.Framing, task: proc(data: ^$D, piece: ^records.Reader, k: int) -> bool, data: ^D, runner: ^core.Runner = nil, at: u64 = 0) -> Maybe(core.Fault)
json.spine :: proc(src: []u8, as: core.As) -> (entries: core.As, at: u64, ok: bool)
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

Every offset, in a record and in a fault (not a built document's nodes, see `build`), counts from the input's first byte, never from the record's.

`open` with an `at` past `len(src)` ends the records with the fault `.Bad_Option`. It starts reading at `src[at]`, and its offsets still count from `src[0]`: a caller that stopped at a record
resumes at that record's `at` with the same offsets. `open_stream`'s `at` names the input byte the reader's first byte
is, for a stream opened part way into a file. Both read from `at` as from the first byte of a record, and pass over a
byte order mark only when `at` is 0.

`key` is the key's token as written in the input: its quotes and escapes are in it, and a JSON5 key may be a bare
identifier. A quoted key is a string, so `json.unmarshal(rec.key, spec, &name, &plan)` into a `string` with a plan of
`string` decodes it, and a bare one is its own text.

## Framings

| Framing | A record is |
|---|---|
| `.Lines` | one line (NDJSON): from its first byte that is no whitespace to the LF, less a CR before the LF |
| `.Seq` | the bytes after a 0x1E up to the next 0x1E (RFC 7464), from the first byte that is no whitespace |
| `.Concatenated` | one document of a text of documents one after another, as jq reads its input, from its value's first byte to its last |
| `.Entries` | one element of the root array, or the value of one member of the root object, with its key in `key` |

- A line of whitespace alone is no record, under `.Lines` and between two 0x1E under `.Seq`. Whitespace is the format's:
  JSON5 has VT, FF, NBSP, the byte order mark and the other Unicode spaces besides JSON's four bytes.
- A UTF-8 byte order mark is passed over at the input's first byte only. One that starts a later record is the record's,
  and JSON refuses it, except in JSON5, where it is whitespace.
- Under `.Lines`, a 0x1E in a line is the record's, and JSON refuses it. Under `.Seq`, an LF is the record's, and a
  `.Seq` record's `text` keeps the whitespace before the next 0x1E.
- Under `.Seq`, a byte that is no whitespace before the first 0x1E ends the records with `Bad_Char` at that byte.
- Under `.Concatenated`, whitespace, 0x1E and comments lie between documents. A number or literal that runs on into a
  byte that may not follow a value, as in `1x`, `1,` or `1]`, or into a `/` where no comment may start, is one bad
  token, as jq reads it, and no record.
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

`check` judges every record from `at` and returns the faults of the refused ones in source order, then the fault that
ended the records, if any. `validate` returns the fault the format's `validate` gives for the whole text, read as the
entries of its spine or its root.

## Threads

With a `runner`, such as a `host.Pool`'s, `check` and `validate` read a long text in pieces on its threads and the
caller's, with the answer one thread gives: the same faults at the same bytes. Each piece guesses where a record may
start in it, past an LF or 0x1E, or at a comma under `.Entries`, and reads records from there until one starts past
the piece. A guess that leads to a fault is dropped for the next one. Then the records are read in source order on
the caller, and a piece whose first record is the next one read gives its faults and jumps the reading past it. A
guess inside a string, a comment or a nested value is never a record the in-order reading meets, so it costs time and
never the answer. A runner with no threads and a short text read on the caller alone.

A dsv text is read in pieces of rows. A piece's guess is the byte past an LF, and its rows are checked against the
width the text's first record set. A guess inside a quoted cell either faults, and the piece guesses again, or gives
rows the in-order reading never meets. In `check` and `validate` the walk that frames the rows judges them, so the
in-order reading takes the rows between two pieces' starts as one walk.

`each` hands a task readers over pieces of the text, whose records together are those `next` gives, each once. The
pieces are cut exactly, since a task may act on what it reads: past the first record, a scan from where it ends finds
the byte past each separator at the first record's level and outside strings or quoted cells, and the first such cut
in each slice of the text starts a piece. Under `.Lines` and `.Seq` the separator is the LF or 0x1E, and a dsv text's
is the LF, outside quoted cells in CSV. A strict JSON text under `.Concatenated` is cut at an LF and under `.Entries`
at a comma, both outside strings and nested values. Strings and levels are counted in each slice on the threads from
both guesses of whether the slice starts in a string, then settled in order. A text with comments or single quotes
under those two framings, and a CSV text with comment lines or tolerated bare quotes, is one piece. Pieces are
numbered in source order, with gaps where a slice holds no cut. A task returns false to stop the run, and a piece's
records that end on a fault stop it too: every piece before it is still handed out, and the first fault in source
order is returned. A dsv piece past the first keeps the header the first record's read found.

```odin
sum_piece :: proc(job: ^Job, piece: ^records.Reader, k: int) -> bool {
	for rec in records.next(piece) {
		// rec.text, rec.at, offsets from the input's first byte
	}
	return true
}
fault := records.each(src, json.as(.Json), .Lines, sum_piece, &job, &pool.runner)
```

## Spines

Under `.Entries` a text is read in pieces across its root's entries. A text whose bulk is an array inside objects,
as `{"meta":{...},"logs":[...]}`, has one root entry, so `json.spine` finds that array: the root array, or the value
of the member of a root object, up to `json.SPINE_LEVELS` objects deep, that does not end within the first bytes of
it, past at most a few members whose values do. `records.open(src, entries, .Entries, at)` then gives the array's
elements, each judged at its depth in the text, and at the array's close the text with the elements cut out is
walked whole, so the frame around them is judged once. Any fault is the one `validate` gives for the whole text.
`records.validate` reads a JSON text this way when it has a spine.

## Typed reads and documents

`read` frames the next record and reads it into `target` by `plan`, as the format's `unmarshal` of the record's text
reads it, refusals included, with every offset from the input's first byte. It returns false at the input's end, on
the fault in `it.fault`, with `.Plan_Mismatch` when `plan` is no plan of `T` by the format, or with `.Out_Of_Memory`
when the reader's own memory is refused. A refused record returns true and its error, and the next `read` goes on past it. It reads the record in place, so it costs less than `next`
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

`build` builds the document of a record `next` gave, as the format's `build` of `rec.text` does. A refusal's offsets
count from the input's first byte, and the document's node offsets index `doc.src` as in every document. What `doc.src`
is depends on the format: JSON's is the record's text, so a node's offsets are the record's own, and dsv's is the input
(for a streamed dsv reader, the header joined with the row). A document built from a streamed record lives until the
next call on the reader. `build` on a reader whose format builds no records is `.Bad_Index`.

`scan` frames the next record and answers `path` in it, as `scan` of `core/build` answers it in the record's text, with
every offset in an error from the input's first byte. The path is planned at the first call and reused, and the
document's buffers too, so the document lives until the next call on the reader, and every call passes the same `path`
and `read`. JSON reads the record in place: the document's `src` is the input up to the record's end, and under
`.Concatenated` strict JSON one walk both frames the record and answers the path. A stream, and a format with no
scan of its own (dsv), build the record and query it, where `read.stop_early` and `read.refuse_duplicates` do not apply.
A record whose text does not read returns true and its error, and the next `scan` goes on past it.

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
  first batch, whose rows `next` then gives. Under `.Ragged` a decimal `name` past the header's width is the column
  of that 1-based position, which a wide row holds.
- A stream's `read` of a row the window cut is read again once the window holds it, from the target as it was.
- `cell` returns cell `column` of the row `next` gave last, as a slice of the input when it needs no decode, else
  decoded into `buf`. It returns false for another row, a column past the row, or a `buf` too short.
- `cells` returns every cell of the row `next` gave last, as `write_cells` takes them: nil for an empty unquoted
  cell, `""` for a quoted one. They last until the next call on the reader, and the decoded ones share `buf`.
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

## Streams

`open_stream` reads the records an `io.Reader` gives, with the same `next`, `read` and `build`, and
gives the same records and faults as `open` on the whole input, with the same offsets. The input is read in 64 KiB
reads into a window that doubles while a record does not fit, up to `Stream_Options.max_bytes` (0 for no limit). A
record's `text` and `key` are slices of the window and last until the next call on the reader.

```odin
it := records.open_stream(os.to_reader(f), json.as(.Json), .Lines, {max_bytes = 1 << 26})
defer records.close(&it)
for rec in records.next(&it) {
	// rec.text lasts until the next call
}
```

- The window always ends on a whole record. Under `.Lines` and `.Seq` it ends at the last LF or 0x1E it holds. Under
  `.Concatenated` a record whose walk faults within 12 bytes of the window's end, or ends at it, while more input may
  come, is walked again once more is read, since the bytes after it may make it whole. A record with a byte after it,
  such as the LF a pipe's writer ends a text with, is given at once. Under `.Entries` the whole input is read first.
- When the input ends inside a record that a longer input could finish, a `Truncated` fault at the input's end, the
  records end with no fault and the bytes past the last whole record in `it.held`, at offset `it.held_at`. Under
  `.Concatenated` those bytes start after the last record, gap included. The same text in memory ends on the
  `Truncated` fault. A last record that is whole with no LF after it is a record, as in memory, and any other fault is
  a fault.
- A record that does not fit in `max_bytes` ends the records with the fault `.Too_Wide` with code `records.too_long`, at the first
  byte after the record before it.
- When the reader fails, the records end with no fault, the error in `it.cause`, and the bytes past the last whole
  record in `it.held`. A read that gives no bytes and no error is `.No_Progress`.
- Under `.Concatenated`, `read` of a record that crosses the window's end reads it twice, and what the first read
  allocated is not freed: pass an arena.

`next_window` gives the records in whole windows instead of one at a time, each with the input offset of its first
byte, for a caller that hands each window to another thread. A reader on text in memory gives the text past `pos` as
one window. A window holds the records and the gaps between them, so a window past the first may start with
whitespace, and its records are read with offsets from `base`.

## The format's services

A format gives its record reader as a `records.Services` table in its rodata, which its `core.Spelling.records` points
at. `next` holds one procedure per framing, nil for a framing the format does not take, which frames the next record
and stores the fault that ends the records in `it.fault`. `judge` returns a record's fault, `read`, `build` and `scan` read
one. `guess` moves a piece's reader to where a record may start, and marks it so that a fault ends its records
without the cost of finding the whole text's fault. `exact` gives the scan whose cuts `each` starts pieces at, and `piece` turns a copy of a reader past its
first record into a piece's reader. `whole` names the framing and offset `validate` reads a whole
text by. `column`, `cell` and `cells` are a format's with named columns, and `close` frees the memory the format keeps in
`Reader.format`. `ends` names, per framing, the byte a backward scan finds a whole record's end by (JSON's LF and 0x1E),
0 where only a walk of the records finds it, and 0xff where the format reads no stream under that framing. `core` stores the table as a
`rawptr`, since `core/records` imports `core`.

dsv reads a stream under `.Lines`. A quoted cell may hold an LF, so the window is found by walking, as under
`.Concatenated`: a row that ends at the window's end, a fault within 12 bytes of it, and any `Truncated` fault while
more input may come, are read again once more is read. Its batch of rows is dropped when the window moves, and the walk resumes at the
byte past the last row given. The header's cells are kept as a copy of its line, so on a stream `build` gives a
document over that line and the row's, which lasts until the next call and whose offsets count from it, and `read`
reports its errors at the input's own offsets.
