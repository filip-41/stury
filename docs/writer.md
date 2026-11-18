# The writer

A written text goes into an output, `write.Out` in `core/write`. A format's writer and the typed write ask it for room,
write into the bytes it hands back, and move its cursor.

## The output

```odin
write.init    :: proc(out: ^write.Out, spill: ^[write.ROOM_MAX]u8, allocator := context.allocator, stream := io.Stream{}, hint := 0)
write.room    :: proc(out: ^write.Out, n: int) -> [^]u8
write.finish  :: proc(out: ^write.Out, refused := core.Typed_Refusal{}) -> (bytes: []u8, err: core.Typed_Refusal)
write.destroy :: proc(out: ^write.Out)
```

`room` returns a pointer to at least `n` free bytes at `out.cursor`, `n` at most `ROOM_MAX` (4096), and the caller moves
`out.cursor` past what it wrote. When the buffer has `n` bytes free that is all `room` does. Otherwise its one branch
goes to a cold proc: a buffer output doubles its buffer, and a stream output writes the buffer to the stream and starts
it again. An output is not copied after `init`.

A buffer output allocates at its first `room`, and `finish` returns the bytes, which the caller owns. `hint` is the size
a writer expects the text to have, and the first allocation takes it when it is more than `ROOM_MAX`. A writer that knows
its text's size from its source never regrows, and past the hint the buffer doubles. A stream output
holds `STREAM_BUFFER` (64 KiB) and `finish` flushes the rest and returns no bytes.

## Failure

An allocation or a stream that refuses sets `out.err` to `.No_Memory` or `.Write_Failed` and keeps it. The buffer is
freed, and later `room` calls return the `spill` the creator gave `init`, a `ROOM_MAX` array that outlives the output and
is discarded. A writer needs no check at each call and tests `out.err` where it can stop. `finish` returns the error.

- A buffer entry is all or nothing: on an error `finish` returns nil bytes.
- A stream refusal may leave a prefix in the stream. `out.flushed` counts the bytes it took.

## Options

```odin
core.Write_Options :: struct {pretty: bool, indent: u8, tab: bool, ascii: bool, escape_html: bool, escape_del: bool, sort_keys: bool, respell_strings: bool, jq_numbers: bool, grow_header: bool}
core.PRETTY :: core.Write_Options{pretty = true, indent = 2}
```

The zero value writes compact text. `pretty` writes one member or element a line, `indent` is the spaces per level and
`tab` one tab per level in its place. Pretty with `indent` 0 keeps the line breaks and writes no indent. A field a format
has no use for is ignored, and each format's `CAPABILITIES.writes` names the fields its document writer honours: a
delimited text reads `sort_keys` alone, YAML, which has no tab indentation, ignores `tab`, and a token write puts keys
in the order of its calls whatever `sort_keys` says. The typed write, a document's write and the token write of JSON
read every other field the same way. `jq_numbers` writes a built value's non-finite number as jq does, NaN as null and
an infinity as the largest double of its sign, and `grow_header` lets a delimited text's table take a key its header
lacks.

## Errors

A write returns `core.Error`, whose `core.Typed_Error` arm is the type a typed read returns, and a refusal that names no position is the `core.Typed_Error_Kind` arm. Its kinds from `.Invalid_Utf8` on are a write's:

| Kind | Means |
|---|---|
| `.Invalid_Utf8` | a string to write is not UTF-8 |
| `.Non_Finite` | a number to write is infinite or not a number |
| `.Too_Deep` | a value nests past `MAX_DEPTH` |
| `.Cycle` | a pointer leads back to itself |
| `.Bad_Raw` | a `Raw` or `Number_Text` is not one value of the format |
| `.Unwritable` | a value the format cannot spell, the last step names it |
| `.Out_Of_Order` | a token call the text's grammar does not allow next, or a text finished before it is whole |
| `.Write_Failed` | the stream refused bytes, `cause` holds its `io.Error` |

A write also returns `.No_Memory`, `.Unsupported`, `.Not_A_Member` and `.Plan_Mismatch` by the reads' meanings.
`.Unwritable` is a value the target cannot spell, a root its grammar does not take among them, and `.Unsupported` an
option or operation the target lacks, such as a partial document or a token write to a stream where the text is laid
out whole. A format's `Services.words` give the two kinds their reasons in `want.text`, which `core.render` writes after
the kind's message, as `core.write` and `tokens_finish` return them. A site that knows more gives its own.
`steps` names the value as in a read. `at` is a byte of a source, so a write sets none and `core.render` leaves the
position out for every kind that names no byte. The codes are `typed.` and the kind, as in `typed.non_finite`.

## Typed values

`json.marshal(value, spec, opts, write, allocator)` builds a plan for the call: `spec` and `opts` are the format's, `.Json`
and `{}` by default, and `write` is the `core.Write_Options`. `json.marshal(value, &plan, write, allocator)` and
`write.marshal_stream` take one that `json.plan_make` built, which a caller with hooks, a union tag or many writes
keeps. That form is `write.marshal`, so it is the same for every format. A plan is one type's, and another value is `.Plan_Mismatch`. The
text comes from `allocator`. What lasts only the call, the key text, stand-ins and side plans, comes from
`context.allocator`.

The walk (`core/write/marshal.odin`) is one loop over the plan's records with one stack of frames, specialised at
compile time on a format's text (`Tree`, its bytes, and `Put`, its string writer). `Plan.marshal` holds the format's
instance, set by its `plan_make`, so a caller of `write.marshal` names no format. A plan with no `marshal` is
`.Unsupported`. A list of structs keeps one frame open, so a list does not push and pop per element. A map, a struct
under `sort_keys`, a struct with a captured map and a tagged union arm are listed first as entries, their keys sorted
by eight bytes at a time, then written as an object.

| Value | Text |
|---|---|
| integers, floats | `core/spell`, in jq's layout. A non-finite float is `.Non_Finite` |
| `string`, `cstring` | the string writer. A nil `cstring` is null |
| enum | its name, or its integer under `Plan_Options.enums = .Int`. A value with no member is `.Not_A_Member` |
| bit set | an array of its elements in ascending order, an enum's by name. A bit with no member is `.Not_A_Member` |
| `core.Number` | by value. A `.Wide` one is `.Non_Finite`, since it holds none |
| `Raw`, `Number_Text` | its text, checked as one strict value with no space around it, else `.Bad_Raw`. Empty is null |
| pointer, `Maybe`, union | the value held, or null. A tagged arm is an object with the tag first |
| map | sorted by the key's own bytes, so `ascii` and `escape_html` move no key. An integer key is text, an enum's its name |
| struct capture | after the declared members, sorted. A key that a written member also has is `.Unwritable`, since a capture holds what the type does not name |
| `any`, a hook | see below |

`sort_keys` sorts a struct's members, a union's tag and captured members with them. Maps are sorted either way.

`omitempty` leaves out a zero number, false, an empty string, a nil, an unheld union or `Maybe`, and an empty list, map or
bit set. An enum is kept, since its zero is a name, and so are a struct and a fixed array.

An `any` holding a string, `bool`, `i64`, `u64` or `f64` is written by a switch on its type. Any other type gets a side
plan with the call's plan options, built once per call and held for it. A write hook, `Type_Hook.write`, returns a
stand-in value, written as an `any` is. It may allocate from the `allocator` it is given, which lasts the call, and a
kind it returns refuses the write. A hook with no `write` is `.Unsupported`. A stand-in of the hook's own type comes back
to the hook, and the frames that takes end in `.Cycle` or `.Too_Deep`.

Depth counts containers, as a read does, so a value a read takes writes back, and a container past `core.MAX_DEPTH` is
`.Too_Deep`. Pointers and `any`s open on the path count apart, up to `core.MAX_DEPTH` of them. `Raw` counts its own
containers with those open. A pointer or `any` target seen again by the same record on the open path is
`.Cycle`, and the scan is linear in the pointers open. The same pointer twice side by side is fine.

A refusal names its path. Nothing tracks one while writing: `refused` reads it from the open frames, the innermost
`MAX_ERROR_STEPS` steps, with `truncated` set when there were more. A stream may hold a prefix of the text.

## Documents

```odin
core.write           :: proc(doc: ^core.Document, opts := core.Write_Options{}, as: Maybe(core.As) = nil, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error)
core.write_stream    :: proc(w: io.Stream, doc: ^core.Document, opts := core.Write_Options{}, as: Maybe(core.As) = nil, node := core.ROOT, allocator := context.allocator) -> (dropped: int, err: core.Error)
core.subtree_facts   :: proc(doc: ^core.Document, i: core.Node_Index) -> []core.Fact
json.as              :: proc(spec: json.Spec, opts := json.Options{}) -> core.As
dsv.as               :: proc(spec: dsv.Spec, opts := dsv.Options{}) -> core.As
toml.as, yaml.as, cbor.as
core.format          :: proc(src: []u8, as: core.As, opts := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error)
```

`core.write` writes a document through the `write` service of the handle `as`. A nil `as` is the format and layout the
document was read in. `json.as(.Jsonc)` and `dsv.as(.Tsv, opts)` name another target, in the same format or in another,
so a JSON document is written as a table and a table as JSON by the target's writer. A target with no writer is
`.Unsupported`. A document an entry point builds holds no services, so `json.write`, `toml.write`, `yaml.write`,
`xml.write`, `html.write` and `cbor.write` write it in their format. `core.As` is the handle a `Document` holds in `as`.

`node` writes one value of the document as a text of its own, the root by default: a subtree with the comments inside
its span, which `core.subtree_facts` returns, in the spelling and layout the root would have. A key, a node the document
does not hold and, for a delimited target, a node that is not an array are `.Unsupported`. The row walk stops at the
subtree's end, and the dense path runs over the subtree's span.

A document has no close nodes: a container's `n` is its subtree size, so the walk writes a container's close bracket
when the next row is past its subtree.

A string and a number read from a source keep their source spelling, so a string with an escape keeps the escape, and
the punctuation and the whitespace are made again, which is the whole of the difference between a source and its compact
text. A number of a document of another format is spelled by `core/spell` as a computed number is, and `-0.0` from a
source stays as written. A string is spelled again when `ascii`, `escape_del`, `escape_html` or `respell_strings` is set
and when it carries a tolerated ill-formed sequence. `respell_strings` alone writes every string in the writer's own
escapes, so `"\u00e9\/"` is written `"é/"`. A comment is written as it was read.

A compact write of a document with short tokens runs over the source's bytes in 64-byte blocks (`json/write_dense.odin`),
and any other write walks the rows. The two paths write the same bytes, and a leading byte order mark is left out by
both. The dense path is taken for a document read as `.Json` with no tolerance, with `ascii`, `escape_del`,
`escape_html`, `respell_strings` and `pretty` off.

Pretty text writes a line break and the indent before each row that starts a line. A container with no member is `{}`
or `[]`, and a key's colon is followed by a space.

`core.format` builds a document from the text as `as` says and writes it as `core.write` does in the same spec, for every
format. A fault in the text is `.Walk` with the fault in `inner`.

A document with comments, a table header, JSON5 spelling or `sort_keys` is written by `write_tree`
(`json/write_tree.odin`), which keeps a frame for each open container on a stack that grows with the depth.

A comment is written where it was read: before a key on a line of its own, between a key and its value, after a value on
the value's line, and before a close on a line of its own. A comment after the root stays on a line of its own. A line comment is followed by a
line break, in compact text too, and compact text ends a value's line before a comment that is not that value's inline comment. Under `ascii` or `escape_html` a comment's text is spelled again with `\uXXXX`, and so
is a U+2028 or U+2029 in a line comment written as JSON5, where either would end the comment. A
document is written in the spec it was read in, or in the spec `as` names. A target
that cannot hold a fact drops it, and `dropped` counts the drops, in every format's entry.

`sort_keys` orders the members of every object by decoded key, stable, so repeated keys keep their source order. Merging
repeated keys belongs to the CLI. A JSON5 document written as JSON spells a number and a string again: a hex integer
as decimal of any length, a leading `+`, a bare `.5` and a trailing `.` as JSON has them, and `Infinity` and `NaN` are
`.Non_Finite`. A document with a table header is written as an array of objects, and a positional record as an object through its
pairs.

`core.write` writes a partial document from the nodes it kept, in the target spec as a full build of the same nodes is
written: an array position collapses to the next kept element, and an element reached by two paths in a ring is written
once for each. A partial document keeps no comments. A delimited text with a header is an array of objects, and a headerless one an array of arrays.
Each cell is what `core.kind` reads it as: an empty unquoted cell is `null`, and for a text read with `dsv.Options.infer` `true` and `false` are booleans and
a cell that is exactly a JSON number is a number in its source spelling. Any other cell, a quoted one included, stays a string, so the
text is JSON and no value changes.
The size hint of a document write is its source length, so a write rarely regrows.

## Conversion

`core.write` with another format's `as` writes a document in that format. A fact the target has no place for is dropped
and counted in `dropped`. The command line reports the count as a warning (`yaml cannot hold 1 comment, tag or
attribute of the input, so it is dropped`) in `fmt`. A filter run warns only for a node it writes as YAML, TOML, XML,
HTML or CBOR, and for the attributes of an XML or HTML node it writes as JSON.
What each target writes:

| Target | Comments | Tags and anchors | Attributes | Byte strings |
|---|---|---|---|---|
| JSON, NDJSON | dropped | dropped | dropped | base64 string |
| JSONC, JSON5 | written | dropped | dropped | base64 string |
| YAML | written | written (`!!timestamp`, `!!binary`, `!!set`, anchors and aliases) | dropped | `!!binary` |
| TOML | written | datetime types written bare, the rest dropped | dropped | base64 string |
| XML | written as `<!-- -->` | dropped | written | base64 text |
| HTML | written as `<!-- -->` | dropped | written | base64 text |
| CBOR | dropped | tags written (a TOML or YAML datetime becomes tag 0 or 1004, `!!binary` a byte string) | dropped | byte string |
| CSV, TSV | dropped, or comment lines under a comment byte | dropped | dropped | base64 string |

An XML or HTML document read with `--attributes` holds its attributes as `@NAME` members, which another format keeps as
members. XML takes a document with one root member. A delimited target takes a document whose root is an array of objects
or of arrays.

## Tokens

`core/write` writes a text call by call, with no type and no document. A caller picks the format with the `as` value
`core.write` takes, and the text goes to a buffer from `allocator` or to a stream:

```odin
t: write.Tokens
write.tokens_init(&t, json.as(.Json), core.PRETTY)
write.open_object(&t)
write.key(&t, "id")
write.value_int(&t, 7)
write.key(&t, "tags")
write.open_array(&t)
write.value_string(&t, "a")
write.value_null(&t)
write.close(&t)
write.close(&t)
text, err := write.tokens_finish(&t)
```

`tokens_init` takes a `core.Site` last, where the text will stand in a document: its column, whether a flow collection
surrounds it, whether it follows a key, and `placed` for a value an edit writes. A format's `start` and `value` read it
from `t.site` to indent and style the text for that place, and the zero site is a whole text.

`Tokens` holds `core.MAX_DEPTH` levels in itself and allocates nothing for depth, and it is not copied after `tokens_init`.
The calls are `open_object`, `open_array`, `close`, `key`, `value_string`, `value_int`, `value_uint`, `value_float`,
`value_bytes` (a byte string: CBOR's own, a text format's base64 string), `value_tagged` (a string with the type its
format tags it with, a TOML datetime written bare, `.Bad_Raw` when the text is not one of that type, and a plain string
in a format with no tags), `value_bool` and `value_null`, and `end_record` for a flat format. Each returns the kind that refused it, `.None` for a
written one. The first refusal sticks: later calls write nothing and return it, and `tokens_finish` returns it with no
bytes, as `finish` does for an output that failed. A stream that failed leaves a prefix in the stream.

- A number, a string and a key are the leaves of the typed write, so a text made by calls is the bytes `marshal` makes of
  the same value, in compact and pretty text and under `ascii` and `escape_html`. A float that is infinite or not a number
  is `.Non_Finite`, a string that is not UTF-8 is `.Invalid_Utf8`, and a container past `core.MAX_DEPTH` levels is `.Too_Deep`.
- JSON takes one root value. A key with no object open or owed, a value where a key is owed, a close with nothing open or
  between a key and its value, and a second root value are `.Out_Of_Order`, and so is `tokens_finish` inside a container,
  after a key, or before any value. Every JSON spec writes the same text, so `.Json5` and `.Jsonc` write plain JSON.
- Delimited text takes cells, not containers. A scalar call is a cell, written under the rules of the typed write above, and
  null is an empty cell. `end_record` writes the layout's line end, and a record that wrote no byte is `.Unwritable`.
  `open_object`, `open_array`, `close` and `key` are `.Unsupported`. `tokens_finish` with cells waiting for `end_record` is
  `.Out_Of_Order`. A header is a record of strings the caller writes.
- A format supplies a `write.Token_Spelling` through `core.Services.tokens`. TOML's `end` turns the finished text into
  the format's own, since its grammar fixes an order the calls cannot know, so it runs only on a buffer. YAML's `layout`
  lays the text out in block style as the calls arrive.
- `comment` writes a comment of a role: a lead before the next item, an inline comment on the line of the item last
  written and a foot after the last item of the open container, or after a whole root. JSONC and JSON5 write block
  comments, YAML and TOML `#` lines, which break a flow line and, as TOML 1.1 does, the inline table the TOML calls build before
  `end` lays it out as a 1.0 text, and XML `<!-- -->`. JSON, CBOR, a delimited text and HTML answer
  `.Unsupported`. `write_value` writes every comment of a built value, written on it or its node's, where the format
  writes comments, and `write_laid` does under `comments`: an edit writes a new value's comments itself.

## Records

`core/records` writes a list one record at a time: an NDJSON or RFC 7464 text, or the rows of a delimited text.

```odin
wr: records.Writer
records.writer_init(&wr, stream, json.as(.Json), .Lines)
for v in values {
	if records.write(&wr, v, &plan) != .None {
		log(wr.err)
	}
}
_, err := records.writer_end(&wr)
```

```odin
records.writer_init  :: proc(wr: ^records.Writer, w: io.Stream, as: core.As, framing := core.Framing.Lines, opts := core.Write_Options{}, allocator := context.allocator, spell: ^write.Token_Spelling = nil) -> core.Typed_Error_Kind
records.writer_end   :: proc(wr: ^records.Writer) -> ([]u8, core.Error)
records.writer_destroy :: proc(wr: ^records.Writer)
records.write        :: proc(wr: ^records.Writer, value: any, plan: ^typed.Plan) -> core.Typed_Error_Kind
records.write_text   :: proc(wr: ^records.Writer, text: []u8) -> core.Typed_Error_Kind
records.write_cells  :: proc(wr: ^records.Writer, cells: []write.Scalar) -> core.Typed_Error_Kind
records.marshal        :: proc(list: []$E, plan: ^typed.Plan, as: core.As, framing := core.Framing.Lines, opts := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error)
records.marshal_stream :: proc(w: io.Stream, list: []$E, plan: ^typed.Plan, as: core.As, framing := core.Framing.Lines, opts := core.Write_Options{}) -> core.Error
```

- A record of JSON is the value's text, as `write.marshal` writes it, and LF. `.Seq` also puts 0x1E before it. `.Lines`
  takes compact text only, so `pretty` there is `.Bad_Option`. `.Entries` is one document, which `write.marshal` writes,
  so it is `.Unsupported`.
- A record of a delimited text is a row, written by a plan of the row type: `dsv.plan_make(Entry, .Csv)`, not
  `[]Entry`, made with the writer's spec and layout, else `.Plan_Mismatch`. The first row writes the header, a map row's
  from its own keys, so a later row with another key is `.Unwritable`, unless `write_cells` or `write_text` wrote the head
  of the text first: then the row binds its columns and writes no header. Every row takes the plan of the first. A delimited text takes `.Lines` only.
- `write` takes a plan of the value's type built by the writer's format, else `.Plan_Mismatch`. `write_text` writes the
  caller's text of one record as it is, unjudged. `write_cells` writes a row of a delimited text, each cell as the typed
  write writes its kind, a `write.Number_Literal` as its text: a nil cell is empty, a string that the handle's `infer`
  would read back as a number, `true` or `false` is quoted, or `.Unwritable` in TSV, which has no quotes, a row that would be an empty line, which is no record, is `.Unwritable`
  (no cell, one nil cell, and one empty cell where the format cannot quote it), and a BOM at the start of the text is
  quoted. Another format is `.Unsupported`.
- A refused record leaves no byte when nothing was flushed since it began, and the writer goes on. Otherwise, and on a
  stream or memory failure, the refusal is final: every later call returns it and `writer_end` returns it with no text.
  Each call returns the refusal's kind, and `wr.err` holds it with its path. Every call after `writer_end` is `.Out_Of_Order`.
  `writer_destroy` frees a writer `writer_end` did not end.
- `records.marshal` stops at the first refused element and returns no text. `marshal_stream` may leave a prefix.

A writer sets up once, so a record costs the value's text and one walk entry.

## Delimited text

`dsv.marshal(value, spec, opts, write, allocator)` writes a slice or dynamic array of rows, and `dsv.marshal(value,
&plan, write, allocator)` takes a plan from `dsv.plan_make(T, spec, opts, plan, allocator)`. `opts` is the `dsv.Options` of a read: `delimiter`,
`comment`, `no_header` and the write's own `crlf`. The spec and the options ride in `Plan.as`, so a plan writes one spec
and `.Bad_Option` refuses options that spec cannot read. `sort_keys` orders a struct row's
columns, and a document's, as below.

A plan of one row writes a text of that one row. A struct row writes a header of its field names, then a record per
element. A list row writes its cells and no header. A map row writes the sorted union of its keys as the header and a
cell per key, an empty one where a record lacks it, and a cell that is present and empty is `.Unwritable`. A hook's
stand-in is written by a plan built for it, and a value that is no cell is `.Unsupported`.

The rules that keep a text readable:

- CSV quotes a cell that holds the delimiter, a quote, CR or LF, and doubles its quotes. An empty string is `""`.
- TSV escapes the delimiter, CR, LF, backslash and NUL as `\t`, `\n`, `\r`, `\\` and `\0`. Any other delimiter in a cell
  is `.Unwritable`. Plain refuses a cell that holds the delimiter, CR or LF.
- Under TSV and Plain an empty string is an empty cell, which reads back as absent, so inside a `Maybe` or a union it is
  `.Unwritable`.
- A first cell that starts with the comment byte is quoted under CSV, written as `\t` under TSV when the comment is a tab,
  and otherwise `.Unwritable`. A BOM at the start of the output and a number that holds the delimiter are handled the same
  way.
- A record that writes no byte would read back as no record, so it is `.Unwritable`. A refusal's path is `[record].field`,
  `[record][cell]` or `[record].key`.

`core.write` with `dsv.as(spec, opts)`, or with no `as` on a dsv document, writes the records of a document in the spec
and layout it was read in, with the line end of its first row. Under a comment byte in the output's options, which a
write with no `as` takes from the read, the document's comments are written as comment lines: a comment on the list
above the header when a record follows it, one on a record above the record, and the list's foot below the last
record. A comment with no such place, as one on a cell or an inline one, one whose body holds a control byte other than
a tab or a line end, and every comment when the output has no comment byte, is dropped and counted in `dropped`.

A document of another format whose root is an array of objects or of arrays is written through its spans. The first
object's keys are the header, a later object's missing key is an empty cell, and a key the header lacks is
`.Unknown_Field` unless `grow_header` is set, which takes every key in first-seen order. Null is an empty cell, a number
is its source spelling (a JSON5 number JSON does not spell is written as JSON writes it, and an infinity or NaN is
`.Non_Finite`), and a container is `.Unsupported`, as is a partial document. `sort_keys` puts the columns in byte order
of their names.

## TOML

`toml.marshal(value, spec, opts, write, allocator)` writes a struct or a map as a TOML document, and
`toml.plan_make(T, spec, opts, plan, allocator)` makes the plan for many writes. `toml.write(&doc, spec)`, or
`core.write` with `toml.as(spec)`, writes a document of any format, and the token write (`write.tokens_init` with
`toml.as(spec)`) writes a text call by call. All three lay the value out the same way: TOML fixes an order the calls
cannot know, so the typed write and the token write write the value as one inline table and read it back, and
a document writer lays the document out. A token write to a stream is `.Unsupported`, since the layout needs
the whole text in a buffer.

The root must be an object, else the write is `.Unwritable`. A scalar, an array that is not all tables and an empty
array are `key = value` lines at the top of their table. A table is a `[header]` section after the lines, and a non-empty
array of tables is a `[[header]]` section per element, so a table's keys may be written in another order than the
document holds them. A table that holds only sections has no header of its own. Null has no TOML spelling and a key a
table repeats cannot be written, both `.Unwritable`. A key is bare when it can be, else a basic string.

A string is a basic string, with the quote, the backslash and the control bytes escaped, and under `ascii` every rune
past U+007F. A string read from TOML keeps its quotes and its escapes unless `ascii` or `respell_strings` is set, and a
TOML 1.1 escape (`\e`, `\x`) is spelled again for 1.0. A float is written so that it reads back as a float: `1.0` for 1,
`-0.0`, `inf`, `-inf` and `nan`. A number a jq filter computes has no float kind, so the command line writes a whole one
as `1`. A number of a document is its source spelling. A string node whose `Tag` is a datetime type is written bare,
with the seconds a time lacks added, since only TOML 1.1 reads a time without them. Only TOML 1.0 forms are written. A
byte string is the string of its base64.

Comments are written where TOML reads them back: a head comment above its line or section, an inline comment after its
value or its header, and a table's foot comments after a blank line. An array with a comment on an element is written
one element a line, each element's comments above it. TOML 1.0 has no multi-line inline table, so a comment inside a
table that is an element of an array stands on a line above that element. A comment whose body holds line ends is
written as one `#` line for each, and the inline comments of one value are joined into one. An inline comment with a
line end, one whose body holds a control byte other than a tab or a line end, and the head comments of a table whose
header is omitted are dropped and counted in `dropped`. `sort_keys` orders the members of every table.

## YAML

`yaml.marshal`, `yaml.write(&doc, .Yaml_1_2)` (or `core.write` with `yaml.as(.Yaml_1_2)`) and the token write
(`yaml.tokens_init`) write YAML. Pretty text is block style, one member or element a line with `indent` spaces a level,
laid out as the calls arrive, and ends with a line end. Compact text is flow style on one
line. A collection read from a flow collection stays one.

A string is plain when its text reads back as the same string under the 1.2 core schema and under a 1.1 reader, so
`yes`, `~`, `0123`, `.inf` and a date are quoted. It is single-quoted when it holds nothing a single quote cannot, a
literal block when it has line ends and its place takes one, and double-quoted otherwise. A scalar read from YAML keeps
its style unless `respell_strings` is set, a folded block too: the writer folds a line end of the value between two
lines that start with no white space into an empty line. A float is written so that it reads back as one (`1.0`, `.inf`, `.nan`),
null is `null` or the spelling a YAML source had, and a byte string of the typed write is `!!binary` and its base64.
A key an object repeats is `.Unwritable`.

Tags and anchors are written back from the facts, and an alias where its anchor stands before it. A comment is written
above the line it heads, after the value it ends, at the end of a block collection, and after an empty collection. A
comment the output has no place for, and an inline one with a line end in its body, is dropped and counted. A comment
whose body holds line ends is written as one `#` line for each, and the inline comments of one node are joined into
one. A token write that stands at a site of a document is block text at column 0, which the edit indents to the site or
turns to flow inside a flow collection.

## Markup

`xml.write`, `xml.marshal` and `xml.tokens_init` write XML, and `html.write`, `html.marshal` and `html.tokens_init`
HTML. A marshal or a token write makes its value in `write.MARKUP_TREE`, whose scalars `value_scalar_text` and
`token_scalar_text` spell as `write.scalar_text` spells a built node's, and `write.marshal_markup` and `put_markup` read
that text back as a built value for the format's writer. [markup.md](markup.md) holds each format's rules.

## CBOR

`cbor.write`, `cbor.marshal`, `cbor.tokens_init` and `cbor.writer_init` write CBOR. [binary.md](binary.md) holds the
encodings, the token write's head patching and the typed write's struct forms.

## Number text and strings

A computed float is the shortest decimal that reads back as the same bits, in jq 1.8.2's layout, so the library and the
command line print it one way: `0`, `-0`, fixed text for moderate exponents (`0.0001`, `123.45`, `1000000000000000`, an
integral value with no `.0`) and `1e+16`, `1e-05`, `5e-324` otherwise. A float read from input keeps its source text. A
non-finite float is the caller's to refuse. `core/spell` writes the text straight into the caller's room and does not
check bounds, so a caller reserves `F64_ROOM` (34 bytes) or `INT_ROOM` (20).

A JSON string is checked as it is written, and a string that is not UTF-8 is `.Invalid_Utf8`. The escapes are `\"`, `\\`,
`\b`, `\f`, `\n`, `\r`, `\t` and lower-case `\u00xx` for any other byte below 0x20. DEL and every other valid byte stay as
they are. `ascii` writes each rune past U+007F as `\uXXXX`, a surrogate pair past U+FFFF, `escape_html` writes `<`, `>`,
`&`, U+2028 and U+2029 so, and `escape_del` writes DEL as `\u007f`, which `ascii` does as well. The document write
applies the same options, and a member name in an edit goes through the same writer, so a decoded key that is not UTF-8
cannot be set. `json.put_string` in `json/put_string.odin` is the writer.
