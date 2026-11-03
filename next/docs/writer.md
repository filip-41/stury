# The writer

A written text goes into an output, `write.Out` in `core/write`. A format's writer and the typed write ask it for room,
write into the bytes it hands back, and move its cursor.

## The output

```odin
write.init    :: proc(out: ^write.Out, spill: ^[write.ROOM_MAX]u8, allocator := context.allocator, stream := io.Stream{}, hint := 0)
write.room    :: proc(out: ^write.Out, n: int) -> [^]u8
write.finish  :: proc(out: ^write.Out) -> (bytes: []u8, err: core.Typed_Error)
write.destroy :: proc(out: ^write.Out)
```

`room` returns a pointer to at least `n` free bytes at `out.cursor`, `n` at most `ROOM_MAX` (4096), and the caller moves
`out.cursor` past what it wrote. When the buffer has `n` bytes free that is all `room` does. Otherwise its one branch
goes to a cold proc: a buffer output doubles its buffer, and a stream output writes the buffer to the stream and starts
it again. So a stream costs the hot path nothing. An output is not copied after `init`.

A buffer output allocates at its first `room`, and `finish` returns the bytes, which the caller owns. `hint` is the size
a writer expects the text to have, and the first allocation takes it when it is more than `ROOM_MAX`. A writer that knows
its text's size from its source never regrows, and past the hint the buffer doubles. A stream output
holds `STREAM_BUFFER` (64 KiB) and `finish` flushes the rest and returns no bytes.

## Failure

An allocation or a stream that refuses sets `out.err` to `.Out_Of_Memory` or `.Write_Failed` and keeps it. The buffer is
freed, and later `room` calls return the `spill` the creator gave `init`, a `ROOM_MAX` array that outlives the output and is discarded, so the writer needs no check at
each call and tests `out.err` where it can stop. `finish` returns the error.

- A buffer entry is all or nothing: on an error `finish` returns nil bytes.
- A stream refusal may leave a prefix in the stream. `out.flushed` counts the bytes it took.

## Options

```odin
core.Write_Options :: struct {pretty: bool, indent: u8, tab: bool, ascii: bool, escape_html: bool, sort_keys: bool, partial: bool, infer: bool}
core.PRETTY :: core.Write_Options{pretty = true, indent = 2}
```

The zero value writes compact text. `pretty` writes one member or element a line, `indent` is the spaces per level and
`tab` one tab per level in its place. Pretty with `indent` 0 keeps the line breaks and writes no indent. A field a format
has no use for is ignored.

## Errors

A write returns `core.Typed_Error`, the type a typed read returns. Its kinds from `.Bad_Utf8` on are a write's:

| Kind | Means |
|---|---|
| `.Bad_Utf8` | a string to write is not UTF-8 |
| `.Non_Finite` | a number to write is infinite or not a number |
| `.Too_Deep` | a value nests past `MAX_DEPTH` |
| `.Cycle` | a pointer leads back to itself |
| `.Bad_Raw` | a `Raw` or `Number_Text` is not one value of the format |
| `.Unwritable` | a value the format cannot spell, the last step names it |
| `.Out_Of_Order` | a token call the text's grammar does not allow next, or a text finished before it is whole |
| `.Write_Failed` | the stream refused bytes, `cause` holds its `io.Error` |

A write also returns `.Out_Of_Memory`, `.Unsupported`, `.Not_A_Member` and `.Plan_Mismatch` by the reads' meanings.
`steps` names the value as in a read. `at` is a byte of a source, so a write sets none and `core.render` leaves the
position out for every kind that names no byte. The codes are `typed.` and the kind, as in `typed.non_finite`.

## Typed values

`json.marshal(value, opts, allocator)` builds a plan for the call.
`write.marshal(value, plan, opts, allocator)` and `write.marshal_stream` take one that `json.plan_make` built, which a
caller with hooks, a union tag or many writes keeps. A plan is one type's, and another value is `.Plan_Mismatch`. The
text comes from `allocator`. What lasts only the call, the key text, stand-ins and side plans, comes from
`context.allocator`.

The walk is `write.walk` in `core/write/marshal.odin`, one loop over the plan's records with one stack of frames. It
takes a format's text at compile time: `Tree`, the bytes of a tree, and `Put`, its string writer, so strings and
punctuation are in line. `Plan.marshal` holds a format's instance, set by its `plan_make`, so a caller of `write.marshal`
names no format. A plan with no `marshal` is `.Unsupported`. A walker is set up once (`walker_init`), writes values
(`walker_value`, which picks one of four instances: compact or pretty, each with the plain string writer or the one for
`ascii` and `escape_html`) and is released once. `marshal_as` holds its stacks for one value, and a record writer keeps
one walker, with its stacks on the heap, for all its values.

A list of structs keeps one frame open: the next element takes over the frame of the one that closed, so a list does not
push and pop per element. A struct's members are written from the records' key text with no call. A member with `key_size` 0 is the rest: it has
`omitempty`, it ends the struct, its name is not letters, digits, `_` and `-`, or its key is past `KEY_SIZE_MAX`. The
last two go through the string writer. A map, a struct under `sort_keys`, a struct with a captured map and a tagged union
arm are listed first as entries, their keys written to a second buffer and sorted by eight bytes of the key at a time,
then written as an object.

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

Depth counts frames, so a pointer counts as a level, and a text past `core.MAX_DEPTH` is `.Too_Deep`. `Raw` counts its
own containers with the frames open. A pointer or `any` target seen again by the same record on the open path is
`.Cycle`, and the scan is linear in the pointers open. The same pointer twice side by side is fine.

A refusal names its path. Nothing tracks one while writing: `refused` reads it from the open frames, the innermost
`MAX_ERROR_STEPS` steps, with `truncated` set when there were more. A stream may hold a prefix of the text.

## Documents

```odin
core.write           :: proc(doc: ^core.Document, opts := core.Write_Options{}, as: Maybe(core.As) = nil, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Typed_Error)
core.write_stream    :: proc(w: io.Stream, doc: ^core.Document, opts := core.Write_Options{}, as: Maybe(core.As) = nil, allocator := context.allocator) -> (dropped: int, err: core.Typed_Error)
json.as              :: proc(spec: json.Spec) -> core.As
dsv.as               :: proc(spec: dsv.Spec, layout := dsv.Options{}) -> core.As
json.format          :: proc(src: []u8, $S: json.Spec, opts := core.Write_Options{}, read := json.Options{}, allocator := context.allocator) -> ([]u8, core.Typed_Error)
```

`core.write` writes a document through the `write` slot of the `Spelling` in `as`. A nil `as` is the format and layout the
document was read in. `json.as(.Jsonc)` and `dsv.as(.Tsv, layout)` name another target, in the same format or in another,
so a JSON document is written as a table and a table as JSON by the target's writer. A target with no spelling or no writer
is `.Unsupported`. `core.As` holds the spelling and the spec and layout bytes a `Document` holds in `read`.

A document has no close nodes: a container's `n` is its subtree size, so the walk keeps a stack of `{end, close}` and
writes a container's close bracket when the next row is past its subtree. The stack holds `MAX_DEPTH` levels on the
stack of the call, and a document read under a raised `max_depth` takes one allocation of its depth.

A string and a number read from a source keep their source spelling and are copied from it in 16-byte blocks, a string
with the quotes around its span, so a string with an escape keeps the escape. The punctuation and the whitespace are
made again, which is the whole of the difference between a source and its compact text. A number of a document of
another format is spelled by `core/spell` as a computed number is, and `-0.0` from a source stays as written. A string is
spelled again, through `put_string` or the row loop's own block test, when `ascii` or `escape_html` is set and when it carries a tolerated ill-formed
sequence.

The common case calls nothing. `rows` hands `rows_run` chunks of rows that the output's room holds: a chunk counts every
row at `1 << ROW_ROOM_SHIFT` bytes and the closes of the containers open at its start, so no row tests room. `rows_run`
holds the cursor in a local, writes a key and its value in one step, and a close, the comma and the line before a row
are one test, of `c.end`, which is held at the chunk's end. Anything else stops it with nothing written, and `rare_row`
or `rare_close` writes that one token at any size and in any spelling through the output's `room`. These are a
token that needs another spelling, a line past `NODE_ROOM`, a document of another format, where every token is rare, and
a row whose block copy would load past the end of the source: the first such row is found once, before the walk. A
string or number past `TOKEN_LONG` is copied by `copy_long`, between `rows_run`'s chunks, when the room after it holds.

Pretty text writes a line break and the indent before each row that starts a line. The line break and 15 bytes of fill are
one 16-byte store, and each further 16 bytes of indent another. A container with no member is `{}` or `[]`, and a key's
colon is followed by a space.

A compact write of a document whose tokens are short is not made from its rows. `write_dense` in `json/write_dense.odin`
runs over the source's bytes in 64-byte blocks: `kernel` masks of the quotes, the backslashes and the bytes below 0x21
give the bytes inside strings, the blanks outside them are dropped, and `kernel.compress` stores the rest. The block's
string mask comes from the quotes no backslash escapes, and a byte below 0x21 inside a string can only be a space, which
stays. The route is one test at entry, with the document read as `.Json` and without the
`Invalid_Utf8` tolerance (the build records the tolerances in `read.opts[0]`), and `ascii`, `escape_html` and `pretty`
off. The test takes a source under 8 bytes per node, and one under 26 bytes per node when the blanks outside strings in
its first 2 KB are at least a sixteenth of those bytes, since the rows win on compact text of longer tokens and the dense
path wins wherever blanks are many. A longer-token document, any other spec and any other option take the rows. The two paths write the same bytes, a
leading byte order mark is left out by both, and a text nested past `MAX_DEPTH` is written by the dense path with no
stack. The path has a copy per x86 tier, as the string writer's `wide_run` has, and `kernel.compress` shuffles by a
table at every tier, since `vpcompressb` needs VBMI2, which the `.V4` tier does not promise.

`json.format` builds a document from the text and writes it as `core.write` does in spec `S`, for every text. A fault in
the text is `.Walk` with the fault in `inner`.

A document with comments (`facts`), `shared_keys`, JSON5 spelling or `sort_keys` is written by `write_tree`, a recursive
writer that is not on the common case's path: the row walk never sees it, and `document_cold` picks it before the walk.
The tree writer returns `.Too_Deep` past 4096 levels.

A comment is written where it was read: before a key on a line of its own, between a key and its value, after a value on
the value's line, and before a close on a line of its own. A comment after the root stays on a line of its own. A line comment is followed by a
line break, in compact text too. Under `ascii` or `escape_html` a comment's text is spelled again with `\uXXXX`. A
document is written in the spec it was read in, or in the spec `as` names. A target
that cannot hold a fact drops it, and `dropped` counts the drops, in every format's entry.

`sort_keys` orders the members of every object by decoded key, stable, so repeated keys keep their source order. Merging
repeated keys belongs to the CLI. A JSON5 document written as JSON spells a number and a string again: a hex integer
as decimal of any length, a leading `+`, a bare `.5` and a trailing `.` as JSON has them, and `Infinity` and `NaN` are
`.Non_Finite`. A `shared_keys` document is written as an array of objects, and a positional record as an object through its
pairs.

`core.write` is `.Unsupported` for a partial document unless `Write_Options.partial` is set. Then it writes one from the nodes
it kept, as JSON: an array position collapses to the next kept element, and an element reached by two paths in a ring is
written once for each. A partial
document keeps no comments. A delimited text with a header is an array of objects, and a headerless one an array of arrays.
Each cell is a string, or with `Write_Options.infer` what `resolve` reads it as: an empty cell is `null`, `true` and `false` are booleans, and
a cell that is exactly a JSON number is a number in its source spelling. Any other cell, a quoted one included, stays a string, so the
text is JSON and no value changes.
The size hint of a document write is its source length, and for pretty text eight levels of
indent on every node, so a write rarely regrows.

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

`Tokens` holds `core.MAX_DEPTH` levels in itself and allocates nothing for depth, and it is not copied after `tokens_init`.
The calls are `open_object`, `open_array`, `close`, `key`, `value_string`, `value_int`, `value_uint`, `value_float`,
`value_bool` and `value_null`, and `end_record` for a flat format. Each returns the kind that refused it, `.None` for a
written one. The first refusal sticks: later calls write nothing and return it, and `tokens_finish` returns it with no
bytes, as `finish` does for an output that failed. A stream that failed leaves a prefix in the stream.

- A number, a string and a key are the leaves of the typed write, so a text made by calls is the bytes `marshal` makes of
  the same value, in compact and pretty text and under `ascii` and `escape_html`. A float that is infinite or not a number
  is `.Non_Finite`, a string that is not UTF-8 is `.Bad_Utf8`, and a container past `core.MAX_DEPTH` levels is `.Too_Deep`.
- JSON takes one root value. A key with no object open or owed, a value where a key is owed, a close with nothing open or
  between a key and its value, and a second root value are `.Out_Of_Order`, and so is `tokens_finish` inside a container,
  after a key, or before any value. Every JSON spec writes the same text, so `.Json5` and `.Jsonc` write plain JSON.
- Delimited text takes cells, not containers. A scalar call is a cell, written under the rules of the typed write above, and
  null is an empty cell. `end_record` writes the layout's line end, and a record that wrote no byte is `.Unwritable`.
  `open_object`, `open_array`, `close` and `key` are `.Unsupported`. `tokens_finish` with cells waiting for `end_record` is
  `.Out_Of_Order`. A header is a record of strings the caller writes.
- A format supplies a `write.Token_Spelling` through `core.Spelling.tokens`: its tree, one `value` procedure that writes a
  string, a number or a word, `record`, which writes a typed value with no frame, `stop`, and for a flat format `start` and
  `line`.

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
records.writer_init  :: proc(wr: ^records.Writer, w: io.Stream, as: core.As, framing := core.Framing.Lines, opts := core.Write_Options{}, allocator := context.allocator) -> core.Typed_Error_Kind
records.writer_end   :: proc(wr: ^records.Writer) -> ([]u8, core.Typed_Error)
records.writer_destroy :: proc(wr: ^records.Writer)
records.write        :: proc(wr: ^records.Writer, value: any, plan: ^typed.Plan) -> core.Typed_Error_Kind
records.write_text   :: proc(wr: ^records.Writer, text: []u8) -> core.Typed_Error_Kind
records.write_cells  :: proc(wr: ^records.Writer, cells: []Maybe(string)) -> core.Typed_Error_Kind
records.marshal        :: proc(list: []$E, plan: ^typed.Plan, as: core.As, framing := core.Framing.Lines, opts := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Typed_Error)
records.marshal_stream :: proc(w: io.Stream, list: []$E, plan: ^typed.Plan, as: core.As, framing := core.Framing.Lines, opts := core.Write_Options{}) -> core.Typed_Error
```

- A record of JSON is the value's text, as `write.marshal` writes it, and LF. `.Seq` also puts 0x1E before it. `.Lines`
  takes compact text only, so `pretty` there is `.Bad_Option`. `.Entries` is one document, which `write.marshal` writes,
  so it is `.Unsupported`.
- A record of a delimited text is a row, written by a plan of the row type: `dsv.plan_make(Entry, .Csv)`, not
  `[]Entry`. The first row writes the header, a map row's from its own keys, so a later row with another key is
  `.Unwritable`. Every row takes the plan of the first. A delimited text takes `.Lines` only.
- `write` takes a plan of the value's type built by the writer's format, else `.Plan_Mismatch`. `write_text` writes the
  caller's text of one record as it is, unjudged. `write_cells` writes a row of a delimited text, each cell as the typed
  write writes a string: a nil cell is empty, a row of one nil cell is `""` since an empty line is no record, and a BOM
  at the start of the text is quoted. Another format is `.Unsupported`.
- A refused record leaves no byte when nothing was flushed since it began, and the writer goes on. Otherwise, and on a
  stream or memory failure, the refusal is final: every later call returns it and `writer_end` returns it with no text.
  Each call returns the refusal's kind, and `wr.err` holds it with its path. `writer_destroy` frees a writer
  `writer_end` did not end.
- `records.marshal` stops at the first refused element and returns no text. `marshal_stream` may leave a prefix.

A writer sets up once: the walker, its stacks and a delimited text's columns live as long as it does, so a record costs
the value's text and one walk entry.

## Delimited text

`dsv.marshal(value, spec, layout, opts, allocator)` writes a slice or dynamic array of rows, and `write.marshal` takes a plan
from `dsv.plan_make(T, spec, layout, plan_opts, allocator)`. `layout` is the `dsv.Options` of a read: `delimiter`,
`comment`, `no_header` and the write's own `crlf`. The spec and the layout ride in `Plan.layout`, so a plan writes one spec and `.Bad_Option` refuses a layout that spec cannot read. `sort_keys` orders a struct row's
columns.

A plan of one row writes a text of that one row. A struct row writes a header of its field names, then a record per element. A list row writes its cells and no header. A
map row writes the sorted union of its keys as the header and a cell per key, an empty one where a record lacks it, and a
cell that is present and empty is `.Unwritable`. The loop is dsv's own in `dsv/write.odin`, and the cells are the leaves of
`core/write` (`int_text`, `enum_value`, `union_arm`, `put_text`), so a number or an enum has one spelling in every format.
A hook's stand-in is written by a plan built for it, and a value that is no cell is `.Unsupported`.

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

`core.write` with `dsv.as(spec, layout)`, or with no `as` on a dsv document, writes the records of a document.
A dsv document with no `as` is written in the spec and layout it was read in, with the line end of its first line, and its comments are dropped. A document of another
format whose root is an array of objects or of arrays is written through its `text` and spans: the objects' keys in first-seen
order are the header, null is an empty cell, a number is its source spelling, and a container is `.Unsupported`. A partial
document is `.Unsupported`.

## Number text

`core/spell` writes a float or an integer as decimal text straight into the caller's memory. The caller reserves the room
the procedure names, writes, and advances by the count it returns. Nothing allocates and nothing checks bounds, so a
caller that reserves less than the named room writes past its buffer.

| Name | Writes | Room |
|---|---|---|
| `f64_text(dst, f)` | a finite `f64` | `F64_ROOM`, 34 bytes |
| `f32_text(dst, f)` | a finite `f32`, at its own width | `F64_ROOM` |
| `i64_text(dst, v)` | an `i64` | `INT_ROOM`, 20 bytes |
| `u64_text(dst, v)` | a `u64` | `INT_ROOM` |

Each procedure stores whole words, so it writes bytes past the count it returns, inside the room. A non-finite float
is the caller's to refuse. Neither float procedure tests for it, and a NaN or an infinity gives text that reads as a
different number.

### Floats

The text is the shortest decimal that reads back as the same bits, and the closest to the value among the shortest.
`f64_text` takes the digits from a port of the zmij crate's `to_decimal` (`zmij.odin`), a Schubfach variant: the
significand is scaled by a power of ten from the 128-bit table, the integral part of the product is a 15- or 16-digit
candidate, and the 17th digit is read off the fraction when the candidate does not read back.

- The power-of-ten significands are `strconv._POWER_OF_FIVE_128`, the table the reader's `fast_float_compute_float`
  uses. It is an underscore name of the standard library, so a rename stops the build at a compiler update, and a
  `#assert` on its length stops it if the range of powers changes.
- `EXP_SHIFT` (`exp_shift.odin`) holds the shift the scaling needs for each biased exponent of a regular double. It
  replaces a multiply and a shift on every value. A power of two, whose lower neighbour is closer, and a subnormal still
  compute the shift.
- The 16 or 17 digits are made by `bcd16`, which splits two 8-digit halves into digit values in one 16-byte vector.
  The count of significant digits comes from a scalar split of the half that ends the digits, so that it does not wait
  on the vector. Digits past the last significant one are `'0'`.
- `f32_text` takes its digits from `strconv._shortest_decimal` with 23 mantissa bits. They are at most 9, and the 16
  bytes after them are `'0'`, so one 16-byte load fills the digit slots.

Both procedures hand `layout` the digits d1..dk at `p[1..]`, with the decimal point after digit `n`. It places them with
whole-word stores:

| Case | Text |
|---|---|
| zero | `0`, and `-0` for negative zero |
| `-3 <= n <= k + 15` | fixed: `0.0001`, `123.45`, `1000000000000000`. An integral value has no `.0`. |
| otherwise | `d.ddde+xx`, or `de+xx` for one digit, with an exponent of at least two digits: `1e+16`, `1e-05`, `5e-324` |

The range test is one unsigned compare, `u64(n + 3) <= u64(k + 18)`. The layout is jq 1.8.2's, so the library and the
command line print a computed float one way. A float read from input keeps its source text and does not come here.

### Integers

`u64_text` writes left to right in groups of eight digits. A value under 10^8 is one group. A value under 10^16 is a
leading group and one group of eight. A longer value has up to four digits above the low sixteen, then those sixteen in
one `bcd16` store. The leading group is written from its digit values and shifted past its leading zeros, with no branch
on the length. `i64_text` stores the `-` either way and keeps it only for a negative value, and negates in `u64`, which
is exact for the minimum.

### Checks

`core/spell/test` holds the checks:

- Decided samples of both widths. The `f64` texts are what jq 1.8.2 prints for the same values.
- A model oracle. Every text must read back, through `strconv`, as the same bits. Its significant digits must be
  the shortest: neither neighbour of the digits on the next coarser decimal grid may read back as the same bits. An
  `f64`'s digits must equal the exact value rounded to as many digits by `strconv`'s big decimal arithmetic, whenever
  that rounding reads back. Its layout must equal a slow rebuild from the digits and the decimal point. A canary after `F64_ROOM` shows any store past
  the room.
- Inputs: both edges and the middle of every binade of both widths, powers of two and ten with their neighbours,
  the layout thresholds, subnormals, random bit patterns, short decimals and exact integers.
- Integers against `strconv`, at the powers of ten and two with their neighbours, at every length, and at random.
- `f32_exhaustive` reads back and checks every `f32` pattern with `-define:F32_STRIDE=1`, and a sample of them by
  default. `make test-f32` runs all 2^32 on `F32_THREADS` threads, and `python3 tools/gate.py full` runs that when the
  package or its test changes.

The same texts were compared with jq 1.8.2's over two million floats: random bit patterns, every binade edge, powers of
ten, short decimals and integers.

### Lanes

`bench/kernel.odin` times the number text with `float_random`, `float_canada`, `float_price` and `float_int` (one
value per unit) and `int_random <digits>`. `float_canada` reads `bench/fixtures/corpus/canada.json`, which `make
fixtures` fetches. Run them with `CASES=float python3 bench/run.py build/kernelbench` after `make bench`.

### Architectures

The layer has no per-tier code. `bcd16` is generic `#simd[16]u8` code and Odin builds it for the target's baseline
vectors, NEON on arm64 and SSE2 at x86-64-v2. The zmij port multiplies 64-bit words into 128 bits.

## JSON strings

```odin
json.put_string :: proc(out: ^write.Out, s: string, opts := core.Write_Options{}) -> core.Typed_Error_Kind
```

Writes `s` as a JSON string at the cursor, quotes included. It returns `.Bad_Utf8` when `s` is not UTF-8, and then the
output holds a prefix of the string, so a caller that fails the write discards the output. Every string is checked.
Escapes are `\"`, `\\`, `\b`, `\f`, `\n`, `\r`, `\t` and `\u00xx` in lowercase hex for any other byte below 0x20. DEL
and every other valid byte are written as they are.

`opts.ascii` writes each rune past U+007F as `\uXXXX`, a surrogate pair past U+FFFF. `opts.escape_html` writes `<`, `>`,
`&`, U+2028 and U+2029 the same way. Either option takes `put_escaped`, built for the options in force, which tests a
block of the string at a time, copies a block with no stop whole, and goes byte by byte through a block with one. The
document write keeps these options in its row loop, which tests a string's blocks the same way.

A string without those options takes one of three paths by what it holds:

1. Under 16 bytes, `put_short` loads 16 bytes at the string in one read when that read stays in the string's page,
   otherwise it builds the block from loads inside the string, then tests the block and stores it.
   It runs under the 18 bytes the caller reserved with `room`, so a format's walk calls it after one `room` for a whole
   member.
2. From 16 bytes while the text is plain ASCII, `put_string_mid` copies 16-byte blocks and ends with a store of the last
   16 bytes, which overlaps the one before. It reserves the whole string, so it takes strings up to `MID_MAX`.
3. Anything else goes to `put_mixed`. It reserves `SEGMENT` (512) source bytes at a time, so a string of any length is
   written under the cap `ROOM_MAX` puts on `room`, and carries its UTF-8 state from one segment to the next. It steps
   16 bytes at a time. A block with a stop is written byte by byte through the `ESC_SEQ` table, whose entry is a byte's
   spelling and its length. A block without one is stored whole. Once 80 bytes pass without a stop it tries 64-byte
   blocks with the kernel's operations (`wide_run`), which copy a block with no stop and check the UTF-8 of a block with
   bytes past 0x7F. The tier is chosen once per call from `kernel.tier()` for strings of 64 bytes or more.

UTF-8 is checked a 16-byte window at a time with `kernel.utf8_window`, which is the kernel's table check on 16 lanes.
A window is checked only when it, or the one before it, holds a byte past 0x7F. `kernel.any_lane16` tests a 16-lane mask
with one instruction on both architectures.

A member name in an edit goes through the same writer, so a decoded key that is not UTF-8 cannot be set.
