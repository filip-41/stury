# Binary formats

The binary formats read through the same interface as the text ones: a walk that sends tokens to a hook, a document
built from it, path reads, records, typed reads and the writers. This page holds what differs for a format whose text
is bytes rather than characters. The format is CBOR (RFC 8949), in package `cbor`.

## What a binary format changes

- `Kind.Bytes` is a byte string. `cbor.doc_bytes(&doc, i, buf)` gives its payload, borrowed from the source unless the
  string is in chunks, which the format joins into `buf` (`text_room` bytes always hold it). `text` gives the same
  payload as a string. A text format writes a byte string as RFC 4648 base64 with padding.
- `Readers.binary` is true, so a `String` token is text and never bytes: a `typed.Bytes` target refuses a text string
  as `.Wrong_Kind`, where a text format reads it from base64. A record reader does not skip a byte order mark at the
  start of such a text, since the bytes are not characters.
- A number is read by the format's own `number` reader. A value that no `Number` holds exactly reads as `Wide`, and
  `cbor.doc_number_text` gives its decimal digits through `Readers.number_text`. `core.equal`, `compare`, `hash` and a
  schema's `uniqueItems` take such a number by its digits, so `1` as a one-byte and as a two-byte integer are one value.
- A tag is a fact before its content, of role `Tag` and kind `Number`. `cbor.fact_value(&doc, node, .Tag)` gives the
  tag nearest the item as its decimal digits, with `numeric` set, and `fact_number` reads a tag fact as a `Number`.
- `Readers.key_bytes` gives the bytes a member name is written with, a text string head and the name, so a typed read
  matches a struct's member against a key's bytes as it matches JSON's `"name":`.

## CBOR

```odin
cbor.validate    :: proc "contextless" (src: []u8, spec: cbor.Spec, opts := cbor.Options{}) -> core.Error
cbor.walk        :: proc "contextless" (src: []u8, lo: u64, $S: cbor.Spec, opts := cbor.Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^cbor.Cursor = nil) -> (hi: u64, fault: Maybe(core.Fault))
cbor.walk_resume :: proc "contextless" (src: []u8, cursor: ^cbor.Cursor, $S: cbor.Spec, opts := cbor.Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault))
cbor.build       :: proc(src: []u8, spec: cbor.Spec, opts := cbor.Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error)
cbor.set         :: proc(src: []u8, spec: cbor.Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := cbor.Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error)
cbor.write       :: proc(doc: ^core.Document, spec: cbor.Spec, opts := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error)
cbor.as          :: proc "contextless" (spec: cbor.Spec, opts := cbor.Options{}) -> core.As
cbor.find, cbor.scan, cbor.answers, cbor.each_answer, cbor.query, cbor.can_resume, cbor.edit_list_init
cbor.marshal, cbor.unmarshal, cbor.check, cbor.plan_make, cbor.plan_of, cbor.tokens_init, cbor.checks, cbor.bind_schema
cbor.records_open, cbor.records_open_stream, cbor.records_check, cbor.writer_init
```

Each entry point takes a `cbor.Spec`, the rules an item is judged and written by, and links only the passes it names.
`cbor.as(spec, opts)` is the handle that reaches every pass, which the calls in `core` take. `src` is exactly one data item. A sequence of items (RFC 8742) reads as records under `.Concatenated`, the one framing the
record entry points take.

`cbor.scan`, `find` and `each_answer` build no document. They walk the item, skip every value off the paths, and judge
each skipped item as `cbor.validate` does, so a path read refuses an item at the byte `validate` refuses it. With
`stop_early` the bytes after the last answer are not judged.

### Reading

| CBOR | Kind |
|---|---|
| major 0, 1 | `Number`. An integer beyond 64 bits reads as `Wide` |
| major 2 | `Bytes`. The chunks of an indefinite byte string join |
| major 3 | `String`. The chunks of an indefinite text string join, and the text must be UTF-8 |
| major 4, 5 | `Array`, `Object`. A definite and an indefinite length read alike |
| `f4`, `f5`, `f6` | `False`, `True`, `Null` |
| `f9`, `fa`, `fb` | `Number`, widened to binary64 |
| other simple values, `f7` | `Null`, with the simple value kept in the token's spelling |
| tags 2, 3 | one `Number`, the bignum |
| tags 4, 5 | one `Number`, the decimal fraction or bigfloat, `Wide` unless binary64 holds it |
| any other tag | a fact before its content, with the tag number |

`f8` with a value below 32 is refused as `.Bad_Simple`: Appendix F lists it as not well-formed, though the table of
Appendix A shows it as `simple(24)`. The content of tag 0 must be a text string that is an RFC 3339 date and time, of
tag 1 a number, and of tag 24 a byte string, else `.Bad_Tag_Content`.

A map key is an integer, a text string or a byte string, and any other key is refused as `.Bad_Key`, since no path,
JSON object or struct field can spell it. An integer key reads as the string of its decimal digits and keeps a mark in
its spelling, so a step by name reaches it, `.["1"]` reads key 1, and the CBOR writer writes it back as the integer it
was. The integer `1` and the text `"1"` are one key in one map: a repeat under every duplicate policy.

`Options.max_depth` caps nesting, and a tag counts as a level. The cap is `core.MAX_DEPTH`. A count the bytes left
cannot hold is refused at its head as `.Count_Too_Large`, before any memory is asked for. A bignum is spelled up to 8192
bytes, and a decimal fraction or bigfloat exponent up to 5000. `Readers.number_text` gives no digits for an infinity or
a NaN, so a write to JSON of a document that holds one is `.Non_Finite`.

`Options.tolerate = {.Invalid_Utf8}` reads each maximal ill-formed subpart of a text string as U+FFFD.

### Encoding rules

The spec makes a walk judge how an item is encoded, with no effect on the value it reads:

| Spec | Refuses |
|---|---|
| `.Cbor` | nothing beyond well-formedness and UTF-8 |
| `.Preferred` | a head argument wider than its value needs, a float a narrower float holds exactly, an indefinite length, a bignum that fits an integer (section 4.1) |
| `.Deterministic` | also keys out of bytewise order of their encodings, a repeated key, and a NaN other than `f97e00` (section 4.2.1) |
| `.Length_First` | the same with the keys in length-first order (section 4.2.3) |

### Writing CBOR

`cbor.write(&doc, .Preferred)`, or `core.write` with `cbor.as(spec)`, writes any document as one CBOR item in the
serialization its spec reads:

| Spec | Writes |
|---|---|
| `.Cbor` | a CBOR document's bytes as they were read, and any other's in preferred serialization |
| `.Preferred` | each item in preferred serialization: the shortest head, the narrowest float that holds the value exactly, definite lengths, an integer for a bignum that fits one. An item already in it is copied |
| `.Deterministic` | the same with each map's keys in bytewise order of their encodings, and every NaN as `f97e00`. A key two members write alike is `.Unwritable` |
| `.Length_First` | the same with the keys in length-first order |

A tag is written back from its fact, and `Kind.Bytes` is a byte string. From a text format, an integer past 64 bits is
a bignum, and a number past binary64's range, or one binary64 rounds to zero, is a decimal fraction of its digits, so
it reads back as the same value. A comment, a text format's tag and any other fact CBOR has no place for is dropped and
counted in `dropped`. The layout options have no meaning in a binary text.

The token writer (`cbor.tokens_init(&t, spec)`) holds each container's head as one byte and patches it at the close,
once the count is known, moving the container's bytes when a count of 24 or more needs a wider head. Writing to a
stream, a container still open when the buffer must be flushed is written with an indefinite length, which only `.Cbor`
with unsorted keys allows: under any other spec that write returns `.Unsupported`. `cbor.writer_init` writes a CBOR
sequence, nothing between the items.

### Typed values

`cbor.marshal` and `cbor.unmarshal` write and read Odin values as `json.marshal` and `json.unmarshal` do: a
`typed.Bytes` member is a byte string, and a `core.Number_Text` past 64 bits a bignum or a decimal fraction.
`Options.structs` chooses how a struct is written: `.Map` (the default) as a map keyed by its members' names, and
`.Array` as an array of its members in declaration order, which is shorter and depends on that order. A read takes
either form for any struct, and an array longer than the struct's members has its extra items skipped. A member tagged
`cbor:"name"` is named by its tag, and a tag of digits is still a text key. A write is in preferred serialization with
a map's keys sorted by their encoded bytes, and under `.Deterministic` and `.Length_First` a struct's members are
sorted as a map's keys are. A nil `any` is written as null.

A `typed.Raw` member holds the whole item, its head and tags included, and a `core.Value` member reads a bignum as a
number. `core.Value` has no byte string arm, so a byte string read into one is the string of its base64, and a tag
inside it is dropped. A positional struct behind a pointer, a `Maybe` or a union is written positionally but read only
as a map.

`cbor.checks(.Cbor)` gives `model.compile` CBOR's reads, so a model loads and dumps CBOR, and
`cbor.bind_schema(s, .Cbor)` binds a JSON Schema that `json.load_schema` compiled, so `check_schema` judges an item and
a byte string counts as a string in it. `cbor.check` reads an item by a plan as a check, and `cbor.plan_of` builds the
plan of a `rules.Description`, as `json.plan_of` does.

### Writing as another format

`json.write(&doc, .Json)` writes a CBOR document as JSON. A byte string is base64 text, a bignum, decimal fraction and
bigfloat are numbers, a tag is dropped and counted, and a simple value other than `false`, `true` and `null` is
`null`.

### Editing

`cbor.set` and `cbor.edit_list_init` edit an item as the text formats' edits do, and the format commits its edits
itself: a container's head holds its count, so the commit writes the item again from the root. It copies the bytes of
every item no edit reaches, and writes a container an edit reaches as its head, with the count it ends with, its members
in their new order and an indefinite container's break. A changed count keeps the width of its head where it fits under
`.Cbor`, and takes the shortest head under the other specs. A deterministic spec writes the members of a map an edit
reaches in the order of their encoded keys. A tag is a fact of the item it stands before, so a set keeps the item's tags
and a tag edit replaces them, but the tag of a bignum, a decimal fraction or a bigfloat is its number's. The result is
read again by the walk, so an edit that breaks a rule of the spec is `.Bad_Result`.

### Resuming a walk

A hook that returns `.Stop` fills the walk's `cursor` with the open containers and the place the walk stood at, on the
heap, and `cbor.walk_resume` continues from the token after the stop over the same item, judging the bytes past it as it
reads them. A walk that ends frees what its cursor holds, `cbor.destroy(&cursor)` frees a cursor no resume ended, and a
resume on another text is refused with `.Bad_Option`. `cbor.answers` reads a path's answers a batch at a time on it.

### What CBOR does not do

A built CBOR document has no typed read (`typed.unmarshal` of one is `.Plan_Mismatch`), and a record reader frames,
judges and builds records but does not read or scan them.

### Tests

`cbor/test` holds the Appendix A table (`vectors/appendix_a.json`, from github.com/cbor/test-vectors), the malformed
items of Appendix F, the encoding rules, the limits, integer-key paths and repeats, the nearest tag as the tag fact, a
differential against Odin's `core:encoding/cbor` over generated and mutated items, and the skipping law: a path read and
`cbor.validate` fault at the same byte over the Appendix A and F items and mutations of them, with and without
`stop_early`. The writer's tests write each Appendix A row back (its own bytes under `.Cbor`, and under `.Preferred` for
the rows already in it), respell items for each encoding, write JSON as CBOR and back, keep a deterministic text
deterministic, patch token heads at each width, fall back to indefinite lengths on a stream, round-trip a struct of every
`Read_Kind` in both forms, and read a key the plan matches by its bytes as the lookup reads it, out of order, unknown,
with a longer head or not valid UTF-8. `seam_test.odin` covers values read whole, a model's load, a schema check, the
record entry points and streams, and the bound entry points against the handle. `cursor_test.odin` stops a walk after
each token and resumes it, and reads answers as `each_answer` gives them, `check_test.odin` covers `check` and `plan_of`,
and `edit_test.odin` sets, removes, inserts and reorders members, edits tags and refuses edits that meet.
