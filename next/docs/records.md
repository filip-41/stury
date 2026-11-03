# Records

`core/records` reads a text that holds a list of records, one record at a time, for every format. A caller names the
format once, through the `core.As` value it opens with, and the calls after that name none.

```odin
records.open  :: proc(src: []u8, as: core.As, framing := core.Framing.Lines) -> records.Reader
records.next  :: proc(it: ^records.Reader) -> (records.Record, bool)
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

- A line of whitespace alone is no record, under `.Lines` and between two 0x1E under `.Seq`.
- A UTF-8 byte order mark is passed over at the input's first byte only. One that starts a later record is the record's,
  and JSON refuses it, except in JSON5, where it is whitespace.
- Under `.Lines`, a 0x1E in a line is the record's, and JSON refuses it. Under `.Seq`, an LF is the record's, and a
  `.Seq` record's `text` keeps the whitespace before the next 0x1E.
- Under `.Seq`, a byte that is no whitespace before the first 0x1E ends the records with `Bad_Char` at that byte.
- A format with no record reader, or one that does not take the framing, ends the records with `.Bad_Option` before
  any is read.

## Faults

`next` under `.Lines` and `.Seq` only frames. A record's fault comes from what reads its text, and is the fault the
format's `validate` gives for that text alone, at its place in the input. A record that is refused does not end the
records: the next one is read past it.

`check` judges every record and returns the faults of the refused ones in source order, then the fault that ended the
records, if any. `check` runs on the calling thread.

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
at. `next` frames the next record and stores the fault that ends the records in `it.fault`. `judge` returns a record's
fault. `core` stores the table as a `rawptr`, since `core/records` imports `core`.
