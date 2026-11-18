# Document

A build turns one walk's tokens into a document: the tokens as 16-byte nodes in preorder, the comments, properties and
attributes beside them as facts, and a pointer to the table of readers the format supplies for a node's text, number and
kind. The readers walk the node array and call the format where a node's `spelling` says its value is not its own bytes.

[walk.md](walk.md) describes the walks that make the tokens and [kernel.md](kernel.md) the vector code behind them. The
guide's [Build a document](guide.md#build-a-document) section shows the readers in use, and [edits.md](edits.md) covers
changing one.

## Node

A node is a 16-byte `Token`: `lo`, `n`, `kind`, `role` and `spelling`.

- A scalar's node is its token, and its `n` is its byte length. An `Array` or `Object` is written at its open. At its
  close the builder writes its subtree's node count into `n`, its own node included. The walk's `End` token patches the
  container and is not stored.
- The next node in preorder is `i + n` for a container and `i + 1` for a scalar.
- A container's `spelling` is its child count, where a member counts once, not its key and its value. The count
  saturates at `MAX_CHILDREN` (65535), and `Document.counts` holds the true count of every container that does.
- A key is a node of its own, kind `String` and role `Key`, directly before its value. A dsv record stores no key node:
  its columns' keys are the cells of the header row.
- A `Bytes` node is a binary format's byte string.
- `Node_Index` is a node's index in `nodes`, distinct from `u32` so an index cannot be passed where a count or a byte
  offset goes. `ROOT` is node 0. `NO_NODE` answers a miss, and every reader treats an index at or past `len(doc.nodes)`
  as a miss.
- A container's closing byte is no node. `close_end` finds it when a caller asks for the container's `span`, by scanning
  the closes on the container's rightmost spine, so a read that never asks pays nothing. The root's `span` is O(1).
- `span` of a JSON string restores the quote pair when the token is quoted. A dsv cell's span holds a quoted cell's
  quotes as written.

Core reads three bits of a node's `spelling`:

| Bit | Name | Means |
|---|---|---|
| 0 | `SPELLING_DECODE` | the text is read through the format's `text`, since it is not its span |
| 1 | `SPELLING_QUOTED` | the token is quoted |
| 2 | `SPELLING_LAX` | a tolerated ill-formed sequence may grow the decode |

A node whose decode bit is clear is its own text. The other bits are the format's own, such as a number's packed shape
and a comment fact's marker lengths.

## Document fields

A caller reads five fields: `src`, `nodes`, `answers`, `partial` and `stopped`. Every other field belongs to the build,
the readers and the edit services, and a caller reaches what they hold through a reader.

`src` is a borrowed `[]u8` that must outlive the document and that no build copies. Every span and fact body is a slice
of `src`. A decoded text is in the caller's `buf` or in an allocation from the reader's allocator.

- **`nodes`, `facts`:** the node array in preorder, and the facts sorted by node. A document with no facts holds nil.
- **`counts`:** the true child count of every container whose count saturated `MAX_CHILDREN`.
- **`indexed`:** the member nodes of every container `index_children` listed.
- **`as`:** the handle the text was read with: the readers, the `spec`, the `tolerate` set, `max_depth` and a few format
  bytes core passes along unread, such as dsv's delimiter and `infer`. `json.as` and `dsv.as` make a handle.
- **`tables`:** a dsv text has one `Table`, `table_of(doc, ROOT)`, with the header row's node and the cell count every
  record has, 0 when records differ (`Ragged`). Empty for every JSON document.
- **`root_close`:** one past the root value's authored bytes, which `span(ROOT)` uses. 0 when the build did not record it.
- **`clash`:** the first byte of the first YAML key with the text of another key of its mapping, as `1` and `"1"` are. A
  query, a typed read and the CLI refuse from it under every `dups` but `.First` and `.All`.
- **`owns_src`:** `src` is the document's own allocation. `destroy` frees it and `clone` copies it.
- **Path reads:** a path read fills `answers`, and for a partial document `kept`, `missing`, `partial` and `stopped`,
  described in [paths.md](paths.md). `destroy` frees them.

`destroy` frees every allocation and sets the document to zero. `clone` copies the nodes, facts, counts, tables and a
read's answers into another allocator, so the original may go while the copy lives. The copy borrows the same `src`
unless the document owns it. The document does not change after its build, and no reader accepts an edit.

## Build

```odin
core.build    :: proc(src: []u8, as: As, dups := Duplicates.Last, allocator := context.allocator) -> (Document, Error)
core.validate :: proc "contextless" (src: []u8, as: As) -> Error
json.build    :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error)
dsv.build     :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error)
```

`core.build` and `core.validate` call the handle's `Services.build` or `Services.validate`, which switches once on the
handle's spec into the walk compiled for it. A handle with no format gives `.Bad_Spec` from a build and a `.Bad_Option`
fault from a validate. `json.build` and `dsv.build` take the format's own spec as a constant, link the walk of that spec
alone, and build a document whose readers table carries no services. Use `json.edit_list_init(&doc, S)` for edits over
such a document, and `core.build(src, json.as(S))` for a document that reaches the format at run time.

A JSON `0x1E` before the document is `.Bad_Char` at that byte, and a JSON text with no value is `.Truncated` at
`len(src)`. On an error the document is the zero value and its data is freed.

### Builder

A format's `build` calls `build.builder_start`, runs the walk with a builder hook and ends with `build.builder_end`.

- The builder reserves the node array before the walk and writes each node as its token arrives. JSON reserves one node
  per two bytes of text, since every node takes at least two bytes but an open container that stays open, and dsv the
  same with 8 stack slots, since a record nests at most two containers.
- The hook keeps the open containers as packed frames in registers: the innermost open container's node and child
  count, and the depth. A close writes the container's size and child count and pops the frame.
- A refused allocation leaves the builder with `.No_Memory`. The build then reads the text again with a hook that
  stores nothing and only counts, and builds once more with every buffer at the size that walk found. A text fails only
  when its document does not fit the allocator.
- `builder_end` cuts the slices to their counts, gives a comment run with no value after it to the root as
  `Comment_Foot`, and sorts the facts by node, keeping source order within a node.

A build chooses its hook and the hook is compiled for that choice: with or without facts, with or without `.Refuse`,
with a stack that grows or one sized in advance, and keyed or keyless for dsv. A spec with no comments makes no fact
token, so its build compiles the fact branch out.

dsv's keyless hooks drop every key and store an `Object` as an `Array`. The header row is node 1, an `Array` of role
`Key` whose cells are `Plain` tokens, written before the walk. A text with no header leaves node 1 for the first record.

## Reading

A reader given an index no node holds answers as it does for a node of the wrong kind:

| Reader | Returns | Miss or wrong kind |
|---|---|---|
| `kind` | the node's `Kind`, a `Plain` cell's as the format reads it | `.Null` for a miss |
| `length` | the member count | 0 |
| `span` | the node's source bytes | nil for a miss |
| `text` | the node's text, and whether it read | false |
| `number`, `int_value`, `float_value` | a `Number`, an `i64`, an `f64`, and whether the node is one | false |
| `doc_bytes`, `doc_number_text` | the payload of a `Bytes` node, a number's decimal digits | nil or "", false |
| `child_next`, `child_at`, `member`, `member_next`, `pair_next` | a node, or a key and value, and whether found | false |
| `children`, `children_from`, `members_named`, `pairs`, `facts_of` | an iterator | an empty walk |
| `key_equals` | whether a key decodes to a name | false |
| `member_of`, `element_of` | a node and a `Presence`, for a partial document ([paths.md](paths.md#the-partial-document)) | `.Missing`, or `.Wrong_Kind` |

Several readers are overload groups over a `Document` and a `Value` (`kind`, `length`, `child_at`, `children`, `text`,
`number`, `pairs`).

### Children and members

`kind` and `span` allocate nothing. `length` returns a container's child count and 0 for a scalar. A header row is no
member, so `length` of a headed dsv text's root is its record count.

`children` starts a `Child_Iter` over a container's member values and `child_next` returns them one at a time.
`children_from(doc, i, k)` starts at member `k`.

`child_at(doc, i, k)` returns member `k`. It indexes in O(1) when every member is one node, as the elements of an `Array`
of scalars are. Any other container is walked from its first member on each call, so a caller that reads many positions
of one container calls `index_children(doc, i)` once. That lists the container's member nodes in `Document.indexed`.

- It writes the document, so nothing else may read `doc` during the call, and a document that more than one thread reads
  has its containers indexed before it is shared.
- It returns false for a scalar, a miss, a `Partial` container and a failed allocation, and `child_at` then walks.

`pairs` starts a `Pair_Iter` over an `Object`'s key and value nodes and `pair_next` yields `(key, val, ok)` in source order.

`member(doc, obj, name, dups := .Last)` returns the value of the member whose key decodes to `name`: `.First` the first
match, `.Last` the last, while `members_named` yields every match in source order. A headed dsv record's members are its
cells.

`key_equals` compares a key with a name without allocating, and answers false for a node whose role is not `Key`.

### Text, numbers and plain cells

Only a scalar carries text. A node whose decode bit is clear returns its span as its text with no call. A marked node
goes to the format's `text`, which writes into the caller's buffer and fails when the buffer is too short, so a read
never allocates.

```odin
text       :: proc(doc: ^Document, i: Node_Index, buf: []u8) -> (s: string, ok: bool)
text_room  :: proc(doc: ^Document, i: Node_Index) -> int
text_clone :: proc(doc: ^Document, i: Node_Index, allocator := context.allocator) -> (s: string, ok: bool)
```

`text` returns a source slice or a decode in `buf`. It returns false for a container, an index past the last node, or a
`buf` too short for the decoded text. A `buf` of `text_room(doc, i)` bytes always holds the decode. `json.token_text(&doc.view,
doc.nodes[i], buf)` is the same read without the table, for a caller that knows the format.

`text_clone` always allocates, and the result is exactly what the caller passes to `delete(s, allocator)`. A caller that
has a buffer reads through `text` first and falls back to `text_clone` only for a text too long for it.

`doc_bytes` returns the payload of a `Bytes` node, borrowed from the source when it needs no joining and written into
`buf` otherwise. `text` and `text_clone` read a `Bytes` node as they read a string. A text format spells bytes only as the
base64 string a writer makes of them.

`doc_number_text` returns a number node's decimal digits, for a format whose number span is not its text: YAML's non-decimal
numbers, CBOR's binary integers, bignums and decimal fractions, and markup numbers that need decoding. An infinity or a NaN gives
an empty text.

`number(doc, i)` returns a 16-byte `Number`, `bits` and `kind`, decoded from the node's span when it is read, and whether
the node is a number. The node holds the token's bytes and the format's packed shape, never a value. The decoders are in
package `core/spell`.

- **`Int`:** an integer that fits `i64`, in two's complement in `bits`. `-0` is `Int` 0.
- **`Uint`:** a positive integer that fits `u64` and not `i64`.
- **`Float`:** a binary64, correctly rounded to nearest even, for a fraction, an exponent, or an integer past `u64` or
  below `i64`'s floor. `-0.0` gives `Float` -0.0.
- **`Wide`:** the number is too large for binary64 or over the caps under [Limits](#limits), so the caller has to read
  its span.

A container, a string, a key and a miss return false. `int_value` returns an `Int`'s value, and false for any other node.
`float_value` returns an `Int` or `Uint` rounded once to `f64`, a `Float` as it is, and false for a `Wide` number.

`kind(doc, i)` of a `Plain` cell returns what the format reads it as. dsv's is `.String` for a key cell and for a quoted
or escaped cell, and `.Null` for an empty value cell. Any other cell is `.String` in a document read without
`Options.infer`. With `infer`, a `true` or `false` cell is `.True` or `.False`, and a cell that is exactly a JSON number
is `.Number`. A build with `infer` writes that kind into the node as it makes the cell. A document not made by a build,
such as a record or a partial read, keeps its cells `Plain` and `kind` resolves them.

## Readers and services

A document points at its format's `Readers` table in rodata, one table for every spec of a format whose tokens read alike
under each. `text`, `key_equals` and `number` take a `Token_View`, the source and the handle, and the token by value, so
a typed read hands them a walk's token with no document. `Token_View.state` holds what a format's readers need past the
source and the handle, as XML's DTD tables and HTML's element ends: a document owns it.

JSON and dsv fill six readers:

| Reader | JSON | dsv |
|---|---|---|
| `text` | unescape, JSON5 quotes and identifiers | a quoted cell's inner span, `""` to `"`, a TSV escape, U+FFFD |
| `key_equals` | compare an escaped key without decoding | the same over a quoted or escaped cell |
| `number` | the recorded shape, else the token's grammar | a plain value cell that is exactly a JSON number |
| `resolve` | the node's kind | what a `Plain` cell is, for `kind` |
| `resolves` | nil, no `Plain` nodes | the handle's `infer` |
| `close_end` | forward over trivia and inner closes | a record's line end, the text's end for the root |

The other formats fill the slots they need and leave the rest nil. They name the format's fault table and its typed
read's key framing ([typed.md](typed.md)), give a property a node's spelling carries instead of a span (`fact`,
`attribute`), read a number whose span is not its text (`number_text`, `number_f32`), and say what the format's values
are: bytes (`binary`, `key_bytes`), flat text with no brackets (`flat`), case-insensitive names (`fold_names`), an integer
and a float of equal value as two values (`floats_apart`), and which facts a text of the format can hold (`holds`).

A reader reaches the table only where it must. A caller that knows the format at compile time calls `json.token_text` or
`json.token_number` directly.

A handle's table also points at the format's `Services`, the passes a call that chooses its format at run time reaches:
`build`, `validate`, `scan`, `write`, `edit`, and `plans`, `reads`, `tokens`, `records` and `docs`. A document a format's
entry point builds holds a table with no services, so a program links only the passes it names, and the format package's
`query`, `edit_list_init` and `commit` serve such a document where `core`'s serve a handle's. The edit passes are in
[edits.md](edits.md#edit-services).

## Duplicate keys

`Duplicates` says how an object's repeated keys are read. `.Default` is the zero value and takes the format's own policy.
`.Last` gives the last match, `.First` the first, `.All` each of them, and `.Refuse` fails at a repeat. `member` reads one
value, so it picks under `.All` and `.Refuse` as under `.Last`, while `members_named` yields every match. On a build only
`.Refuse` changes anything: every other policy builds every member.

A build under `.Refuse` tests each object as it closes, comparing the decoded text of its keys. A repeat is reported at the
later key's first byte, counting its opening quote. The earliest repeat in document order wins. A build that stops on a
fault checks the objects it left open too, and dsv's header row after the walk.

## dsv as a document

A delimited text is an `Array` of records whose first child may be the header row.

- The root is an `Array` of role `Value`, and its readers step over the header row, so `length` counts records and
  `children` returns the records. The root's `Table` names the header row's node, 0 for a text read without one.
- A record with a header is a `Kind.Object` with no inline key nodes. Its cells are its children, each a `Plain` token of
  role `Value`, so it holds one node per cell and `child_at` returns a cell in one step.
- The header row is an `Array` of role `Key` whose cells are `Plain` tokens of role `Key`. A header cell answers
  `key_equals`, `text`, `number` and `kind` as a JSON key does.
- `member` and `members_named` on a headed record walk the header's cells, and `pairs` pairs each header cell with the
  record's value cell. A column past a record's last cell, as a ragged record has, names no cell.
- Under `.Ragged` a record wider than the header widens the header row: the build reads the text again with a positional
  key per column past the header's last, so the row holds as many cells as the widest record. Those keys read as their
  position (`"3"`), and `.Refuse` refuses a header cell of that name. An edit may not set a positional header cell, and a
  column added or dropped before the positional ones, which would rename them, is `.Bad_Width`.
- A headerless text (`no_header` true) has no header row, so every record is an `Array` of `Plain` value cells.

## Facts

A `Fact` is a comment, property, instruction or attribute token, the node it belongs to and its role. The list is sorted by
node, keeps source order within a node, and is empty for a strict JSON document and a dsv text with no comment byte. A
fact's `lo` and `n` span its bytes, markers included, and its `spelling` holds the lengths of its lead and tail markers.

`Tag`, `Anchor` and `Alias` facts stand just before their node, on its line. An `Attribute` fact leads through the
opening quote of its value and trails with the closing one. A CBOR tag is a `Number` fact, read through the format's
`number`.

`fact_value(doc, i, name)` reads a property by the name a filter writes after `.@`. A property the format keeps in a
node's spelling instead of a span, such as a YAML `Style`, a TOML datetime's `Tag` and a markup element's `Name` and
`Namespace`, comes from `Readers.fact`.

A comment's node follows the walk's `Role` rule: a comment on the line where the value before it ends is that value's
`Comment_Inline`, else one before a value the grammar allows it above is that value's `Comment`, else it is the
`Comment_Foot` of the innermost open container, or of the root at depth 0. A member's comments belong to its value's node:
in `{ // head` then `"a": 1 }` the head comment is a fact of the value `1`. A comment before a container's first member is
that member's, and one in an empty container, or in a markup element with no child element, is the container's foot.
Where no bracket opens the root (a YAML or TOML text, the prolog of XML and HTML), the comments before the first member
are the root's up to the last blank line before it, and the first member's after it. A dsv comment line above a record is
that record's `Comment`, and one above the header row is the root's.

`facts_of(doc, i, role)` starts a `Fact_Iter` over node `i`'s facts of that role, and `fact_next` returns their bodies in
source order, as the source between the markers. A read allocates nothing.

Facts are changed through [edits](edits.md#facts-in-a-commit).

## Errors

```odin
Document_Error :: struct { kind: Document_Error_Kind, reason: Edit_Reason, at: u64, inner: Fault }
```

A public procedure returns `core.Error`, a union of `Fault`, `runtime.Allocator_Error`, `Document_Error`, `Path_Error`,
`Typed_Error` and `Typed_Error_Kind`. `error_of` makes it from a concrete error and keeps the arms disjoint by cause:

- A build over text that does not parse returns the walk's `Fault`, with codes such as `json.literal` and
  `dsv.too_many_fields`.
- A build's repeated key under `.Refuse` is a `Fault` with the code `duplicate_key`, at the later key's first byte.
- A refused allocation is `runtime.Allocator_Error.Out_Of_Memory`, with the code `no_memory`.
- Every other kind is a `Document_Error`, with the code `document.` and the kind's code, as `document.bad_index`. Those
  are the edit errors:

| Kind | Means |
|---|---|
| `Bad_Index` | an edit names no node it may change, why in `reason` (`.No_Node`, `.Root`, `.Not_Object`, `.No_Parent`) |
| `Bad_Position` | an insert is past the container's length |
| `Wrong_Container` | the container takes the other insert form |
| `Bad_Value` | a text is not exactly one value of the format and spec, the fault in `inner` |
| `Bad_Fact` | a fact body does not have its role's shape |
| `Bad_Width` | an edit would break the table's width |
| `Bad_Spec` | a commit asks for another format family's spec, or a dsv spec change, or a build has no format |
| `Conflicting_Edits` | two edits meet, or one lies inside another's range, at the byte where they meet |
| `Bad_Result` | a committed text does not read, the fault in `inner` |
| `Frozen` | an edit touches a node the format's `frozen` service names, the reason in `inner.rules` and `inner.detail` |

For `.Bad_Value` and `.Bad_Result` the `inner` fault's `at` names a byte of the recorded text or of the commit's output.

```odin
write_code :: proc(w: io.Writer, err: Error) -> io.Error
render     :: proc(w: io.Writer, src: []u8, err: Error, lines: ^Lines = nil) -> io.Error
```

`write_code` writes the code of any arm: for a fault the format's name, a dot and the rule's code, as in `json.literal`,
and for a typed error `typed.` and the kind's code. A code is stable across releases, and a message may change. `render`
writes `line:col: message` from a rule table, without calling into the format. Line and column count from 1, the column in
bytes, and a `Lines` carries the count from one fault to the next, so each byte is scanned once. `.Bad_Value` and
`.Bad_Result` write the fault's message and its offset in the recorded text or the commit's output, as in `Not one value
of the format: Unfinished input at offset 1 of the new text`.

## Limits

| Bound | Value | Effect |
|---|---|---|
| `spell.MAX_NUMBER_DIGITS` | 256 | a mantissa with more digits than this, counting zeros, reads as `.Wide` |
| `spell.MAX_NUMBER_SCALE` | 4096 | an exponent or scale beyond ±this reads as `.Wide` |
| `MAX_CHILDREN` | 65535 | the largest child count `spelling` holds, with the true count in `Document.counts` |
| `core.MAX_DEPTH` | 1024 | the deepest nesting when `Options.max_depth` is 0 |
| `Token.n` | `u32` | a token one byte longer is `.Too_Wide` |
