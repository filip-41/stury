# The document

A build turns one walk's tokens into a document: the tokens as 16-byte nodes in preorder, the comments beside them as
facts, and a table of services the format supplies to read a node's text, number and kind. The readers walk the node
array and call a service where a node's `spelling` says its value is not its own bytes.

This document describes the node, the document and its builder, the readers, the spelling services, the duplicate-key
rule, a delimited text, facts, the edit list and its commit, the value layer's errors and its bounds. `walk.md`
describes the walks that make the tokens and `kernel.md` the vector code behind them.

## Files

| File | Holds |
|---|---|
| `core/document.odin` | `Node`, `Document`, the readers, `Fact`, `destroy`, the spelling tables |
| `core/build/build.odin` | `Builder`, the hooks, `builder_start`, `builder_end`, the header row, the duplicate-key check |
| `core/edit.odin` | `Edit_List`, `Edit`, `set`, `insert`, `remove`, `set_fact`, `remove_fact`, `commit` |
| `core/compose/compose.odin` | a commit's container composition: members, junctions and the placement of facts |
| `core/compose/commit.odin` | the commit a format's table points at: plan, compose, splice, the read of the result |
| `core/path.odin` | `Path`, its steps and spellings, `Answer`, `Token_Answer`, `Presence`, `member_of`, `element_of` and `length_exact` |
| `core/build/scan.odin` | the one engine: the hook a format's `scan` walks with, the partial document, the query behind `core.query`, `set_answers` |
| `core/build/many.odin` | what only `$MANY` reads hold: armed path sets, rings of negative indexes, answers placed in text order, the stream |
| `json/query.odin`, `dsv/query.odin` | each format's `scan`, `find`, `each_answer` and `set` |
| `core/spell/number.odin` | `Number`, `Number_Kind`, the digit and scale bounds, every decoder |
| `core/spell/text.odin` | `decode_text`, `decoded_equals`, `bytes_equal` and `Pending`, the decoders' and readers' byte helpers |
| `core/number.odin` | core's aliases for `Number`, `Number_Kind` and the two number bounds |
| `core/error.odin` | `Document_Error`, its kinds and rules, `inner`, `render`, `write_code` |
| `json/document.odin` | JSON's `build`, `Spelling` and `Edit_Spelling` tables, `close_end`, the edit checks |
| `dsv/compose.odin` | a delimited text's root junctions and the comments above its header |
| `json/escape.odin` | the escape-byte table its walk and decoder share |
| `json/unescape.odin` | JSON's `text` and `number` readers and the decoder behind them |
| `dsv/document.odin` | dsv's `build`, its `Spelling` table, its edit table, `close_end`, the record check |
| `dsv/plan.odin` | a commit's column changes, turned into plain cell edits before core composes the list |

## The node

A node is a 16-byte `Token` from `core/walk.odin`: `lo`, `n`, `kind`, `role` and `spelling`.

- A scalar's node is its token, and its `n` is its byte length. An `Array` or `Map` is written at its open, and at its
  close the builder writes its subtree's node count into `n`, its own node included. The walk's `End` token patches
  the container and is not stored.
- The next node in preorder is `i + n` for a container and `i + 1` for a scalar, so a member's key and value take one
  node more than the value's subtree holds.
- A container's `spelling` is its child count, where a member counts once, not its key and its value. The count
  saturates at `MAX_CHILDREN`, and `Document.counts` holds the true count of every container that does.
- A JSON key is a node of its own, kind `String` and role `Key`, directly before its value. A dsv record stores no key
  node: its columns' keys are the cells of the header row.
- `Node_Index` is a node's index in `nodes`, distinct from `u32` so an index cannot be passed where a count or a byte
  offset goes. Readers, iterators, `Fact.node`, `Child_Count.node` and `Edit.node` take it. `ROOT` is node 0, the root
  value's node. `NO_NODE` is `Node_Index(max(u32))` and answers a miss, and every reader treats an index at or past
  `len(doc.nodes)` as a miss.
- A container's closing byte is no node. `close_end` returns one past it: it starts after the container's last
  descendant, or after its open when the container is empty, skips the closes on its rightmost spine and the trivia
  between them, then skips to the container's own close. `span` of a container is `src[lo:close_end]`. JSON reads the
  trivia by the document's spec, and dsv's root ends at the text's end while a record ends at its own line end.
- `span` of a JSON string restores the quote pair when `SPELLING_QUOTED` is set, since a string token's span is the
  bytes between its quotes. A dsv cell is `Plain`, so its span holds a quoted cell's quotes as written.

Core reads three bits of a node's `spelling`:

| Bit | Name | Set on | Means |
|---|---|---|---|
| 0 | `SPELLING_DECODE` | a string, key or dsv cell | the text is read through the format's `text` |
| 1 | `SPELLING_QUOTED` | a JSON string, a quoted CSV cell | the token is quoted |
| 2 | `SPELLING_LAX` | a JSON string | a tolerated ill-formed sequence may grow its decode |

A node whose decode bit is clear is its own text: a JSON string's span leaves its quote pair out, an unquoted JSON5 key
is bare, and an unquoted dsv cell is its bytes. The other bits are the format's own: a number's packed shape, and a
comment fact's marker lengths.

## The document

A caller reads five fields: `src`, `nodes`, `answers`, `partial` and `stopped`. Every other field belongs to the build,
the readers and the edit services, and a caller reaches what they hold through a reader.

A `Document` holds `src`, a borrowed `[]u8` that must outlive it and that no build copies. Every span and fact body
is a slice of `src`. A decoded text is `buf` or an allocation from the reader's allocator.

- `nodes` is a `[]Node` in preorder. `nodes_alloc` is the allocation and `nodes` its length prefix, so `destroy` frees
  it after the build cut the length to the node count. A build trims the unused tail where the allocator can
  resize, and an arena does that for its last block, which is the nodes in a text with no facts. `facts` and `facts_alloc`, both `[]Fact`, are
  alike, and a document with no facts holds nil. `counts` and `counts_alloc`, both `[]Child_Count`, hold the true child
  count of every container whose count saturated `MAX_CHILDREN`, sorted by node, and are nil when no container is that
  wide.
- `spelling` is a `^Spelling` that points at a format's table in rodata, and `allocator` is the one the build
  received. `destroy` frees the three allocations and sets the document to zero. A reader that allocates takes its own
  allocator.
- `shared_keys` is the dsv header row's node, 0 for a text read without a header, for a partial document and for every
  JSON document.
- `root_close` is one past the root value's authored bytes: the close of a root container, or the last byte of a root
  scalar, quotes included. It is 0 when the build did not record it. `span(ROOT)` and a whole-document writer use it
  instead of the format's `close_end`.
- `read: Read_As` records how the text was read, in 8 bytes. Its `spec` is the spec the text was read as, in one
  byte, so an edit service can dispatch on it when a procedure pointer carries no compile-time spec. `opts` holds
  three opaque format bytes, passed along unread by core, which dsv uses for its delimiter, comment byte and `no_header`
  flag. Its `max_depth` is `Options.max_depth`, 0 for the default: JSON's build stores it and its edit services read a
  recorded value at that depth, and a delimited text has no depth option and leaves it 0.
- A path read fills `answers`, and for a partial document `kept`, `missing`, `partial` and `stopped`, all in `paths.md`.
  `answers`, `kept` and `missing` share `reads_block`, which `destroy` frees.
- The document does not change after its build, and no reader accepts an edit.

## Building

```odin
json.build :: proc(src: []u8, $S: Spec, opts := Options{}, refuse_duplicates := false,
	allocator := context.allocator) -> (core.Document, core.Document_Error)
dsv.build :: proc(src: []u8, $S: Spec, opts := Options{}, refuse_duplicates := false,
	allocator := context.allocator) -> (core.Document, core.Document_Error)
```

The builder is package `core/build`, which imports `core`. Both run the walk with a builder hook, end it with
`build.builder_end`, and store the spec in `doc.read.spec`. `build.builder_start` reserves a stack of `depth` slots, or
1 when `depth` is 0, the `facts` it is given, and at least 16 nodes, `nodes` when that is larger. The hook pushes a
frame with no capacity test, so `depth` must be at least the walk's depth limit. The node buffer is not zeroed, and it
is allocated last, so `builder_free` frees it first. A document keeps its buffer whole, since an arena that shrank it would
zero, and so touch, the unused tail. A refused allocation leaves the builder with
`.No_Memory` and no nodes, and no hook runs over a nil array.

A build that ends in `.No_Memory` reads the text again with `build.builder_hook_count` or
`build.builder_hook_count_keyless`, which store nothing, and builds once more with every buffer at the size that walk
found. So a text fails only when its document does not fit the allocator. `builder_free` shrinks each buffer before it
frees it, since an arena ignores a free and takes a last block's tail back at a resize. A block that is not last stays
in the arena, so a text with comments that fills an arena during its first try can fail where a counted first try
would fit.

A build chooses its hook, and the hook is compiled for that choice:

| Hook | Facts | Grows | Refuses | Used by |
|---|---|---|---|---|
| `build.builder_hook` | yes | no | yes | JSON, a spec with comments |
| `build.builder_hook_plain` | no | no | no | JSON, a spec with no comments |
| `build.builder_hook_plain_refuse` | no | no | yes | the same, under `refuse_duplicates` |
| `build.builder_hook_keyless` | no | yes | no | dsv, with no comment byte |
| `build.builder_hook_keyless_facts` | yes | yes | no | dsv, with a comment byte |

- JSON reserves `(len(src) + depth) / 2 + 16` nodes and a stack of `depth` slots, where `depth` is
  `max(MAX_DEPTH, opts.max_depth)`, so its hook tests no capacity and grows no node buffer. Every node takes two bytes
  of the text but an open container that stays open: a closed container its brackets, a key its colon, and a scalar
  its comma or its parent's close. A fault ends the walk one token past that, which the 16 covers.
- Every hook keeps the open containers as packed frames in the hook's registers: the high 32 bits of `b` are the
  innermost open container's node and its low 32 bits that container's child count, and `c` is the depth. A close
  reads its frame, writes the container's size and child count, and pops the frame below from the stack.
- A spec with no comments makes no fact token, so its build compiles the fact branch out. A build with facts keeps the
  last completed value in `Builder.last`, for an inline comment's node.
- dsv reserves an estimate, one node per 2 bytes with 8 stack slots, so its hooks check capacity and grow. The
  `$KEYLESS` rule of `builder_step` drops every key, stores a `Map` as an `Array`, and steps over the header row the
  build wrote before the walk.
  The row is node 1, an `Array` of role `Key` whose `n` is its cell count plus one and whose `spelling` is its cell
  count, saturated at `MAX_CHILDREN` with the true count in `Document.counts`. Its cells come from `header_cells` and a
  walk buffer of one `Token` per cell. A text with no header, or no record to read, leaves node 1 zeroed, and the
  first record's token overwrites it.
- A close whose child count reaches `MAX_CHILDREN` stores `MAX_CHILDREN` in the container's `spelling` and keeps the
  true count in `Builder.wide_node` and `Builder.wide_count`. `build.builder_end` copies that one count to
  `Document.counts`. A build with a second such container counts the members of every container whose `spelling` is
  `MAX_CHILDREN`, walking the nodes once at its end.
- `build.builder_close_node` writes a container's subtree size and child count. dsv calls it for the header row it
  writes before its walk.
- A build records `Document.root_close` from the end the walk returns, and `builder_end` copies it to the document. A
  JSON spec with comments records none, since its walk ends past a comment after the root.
- `build.builder_end` cuts the node and fact slices to their counts, trims their unused tails where the allocator can
  resize, gives a comment run with no value after it to the root as `Comment_Foot`, and sorts the facts by node,
  keeping source order within a node. The child counts follow node order.

| Error | When |
|---|---|
| `.Walk` | the walk's fault, in `inner` |
| `.Duplicate_Key` | a build under `refuse_duplicates` met a repeated key, at the later key's first byte, or a commit's named cell is one its record holds |
| `.No_Memory` | an owned allocation was refused |

A JSON `0x1E` before the document is `.Bad_Char` at that byte, a JSON text with no value is `.Truncated` at `len(src)`,
and dsv's `.Bad_Option` names no byte. On an error the document is zero and its data is freed.

## Reading

A reader given an index no node holds answers as it does for a node of the wrong kind:

| Reader | Returns | Miss | Wrong kind |
|---|---|---|---|
| `kind` | the node's `Kind` | `.Null` | its own kind |
| `span` | the node's source bytes | nil | its own bytes |
| `length` | the member count | 0 | 0 |
| `children`, `members_named`, `pairs`, `facts_of`, `fact_next` | a walk, or a body | an empty walk | an empty walk |
| `child_next`, `child_at`, `member`, `member_next` | a node or false | false | false |
| `pair_next` | a key and value node or false | false | false |
| `key_equals` | whether a key decodes to a name | false | false |
| `member_of`, `element_of` | a node and a `Presence`, for a partial document (see `docs/paths.md`) | `.Missing` | `.Wrong_Kind` |
| `length_exact` | `length`, and whether it is the true count | 0, true | 0, true |
| `text` | the node's text, and whether it read | `false` | `false` |
| `number` | a `Number` | `.Wide` | `.Wide` |
| `resolve` | the value's kind | `.Null` | the format's answer |
| `int_value`, `uint_value`, `float_value` | an integer or a binary64, and whether it is one | false | false |

### Children and members

`kind` and `span` allocate nothing, and a nested container's `span` is the only read that scans forward, in
`close_end`; the root's `span` uses `root_close` and is O(1).
`node_start` returns a node's first source byte, `lo`, or `lo - 1` for a quoted string, whose token leaves the quote
pair out. `length` returns a container's child count and 0 for a scalar. The count is a member count, and a header row
is no member, so `length` of a headed text's root is its record count. A count that saturated `MAX_CHILDREN` is read
from `Document.counts` by binary search.

`children` starts a `Child_Iter` over a container's member values and `child_next` returns them one at a time. An
inline-key `Map` steps a key node and a value's subtree per member, and a value's key is the node before it. A
shared-key `Map` steps through value nodes directly. An `Array` steps one subtree per member, and a leading child of role
`Key` is the root's header row, which a root of role `Value` skips. The header row's own role is `Key`, so it skips no
cell.

`child_at(doc, i, k)` returns the member `child_next` would reach at step `k`. It indexes when every member is one
node: at `i + 2 + 2k` in an inline-key `Map` whose `n` is twice its count plus one, at `i + 1 + k` in a shared-key
`Map` whose `n` is its count plus one, and at `i + 1 + k` in an `Array` whose `n` is its count plus one. A count that
saturated `MAX_CHILDREN` is read from `Document.counts`, so the stride test uses the true count; any other container is
walked. A negative `k`, a scalar, a miss and a `k` past the last member return no node.

`pairs` starts a `Pair_Iter` over a `Map` container's key/value member pairs and `pair_next` yields `(key, val, ok)` in
source order. For an inline-key `Map`, key and value alternate in preorder. For a shared-key `Map`, keys come from
`doc.shared_keys` while values step through the record's cells. A non-`Map` container, scalar, or out of range index yields
an empty iterator.

`member(doc, obj, name, dups := .Last)` returns the value of the member whose key decodes to `name`: `.First` the
first match, `.Last` the last, while `members_named` yields every match in source order. A headed dsv record's members
are its cells.

`key_equals` compares an unmarked key with its span through `bytes_equal` and a marked one through the format's
`key_equals`, which allocates nothing. A node whose role is not `Key` answers false, and a dsv header cell has role
`Key`.

### Text, numbers and plain cells

Only a scalar carries text. A node whose decode bit is clear returns its span as its text with no call. A marked node
goes to the format's `text`, which writes into the caller's buffer and fails when the buffer is too short, so a read
never allocates.

```odin
text       :: proc(doc: ^Document, i: Node_Index, buf: []u8) -> (s: string, ok: bool)
text_clone :: proc(doc: ^Document, i: Node_Index, allocator := context.allocator) -> (s: string, ok: bool)
```

`text` returns a source slice or a decode in `buf`. It returns false for a container, an index past the last node, or a
`buf` too short for the decoded text. `json.text(&doc.view, doc.nodes[i], buf)` is the same read without the table, for a
caller that knows the format.

`text_clone` always allocates, and the result is exactly what the caller passes to `delete(s, allocator)`: a text that
is its source is copied, and a decode's over-long buffer is trimmed, so `len(s)` is the allocation's length. A caller
that has a buffer reads through `text` first and falls back to `text_clone` only for a text too long for it.

`number(doc, i)` returns a 16-byte `Number`, `bits` and `kind`, decoded from the node's span when it is read. The
node holds the token's bytes and the format's packed shape, never a value. `Number_Kind` is `Int`, `Uint`, `Float` or
`Wide`. The decoders are in package `core/spell`, and `core.Number` and `core.Number_Kind` alias `spell`'s names, so a
caller of a reader writes `core.Number`.

- `Int` is an integer that fits `i64`, in two's complement in `bits`. `-0` is `Int` 0.
- `Uint` is a positive integer that fits `u64` and not `i64`.
- `Float` is a binary64, correctly rounded to nearest even, for a fraction, an exponent, an integer past `u64`, or a
  negative integer past `i64`'s floor, when a binary64 represents the value. `-0.0` is `Float` -0.0.
- `Wide` is a number no `i64`, `u64` or `f64` holds, and the caller reads its span.

A container and a miss return `{0, .Wide}`. JSON's reader folds a pure integer of at most 19 digits
from the recorded digit counts with no search for a point or an exponent, and reads every other token by its packed
shape: a JSON decimal, a decimal JSON does not write, a hex integer, `Infinity` or `NaN`; a fraction whose integer part
is empty or whose digits pass 19 reads by the full decimal decoder. dsv's reader returns a value cell that is exactly a
JSON number, and `.Wide` for a quoted cell, a TSV escape, a key cell or any other cell.

`int_value` returns an `Int`'s value. `uint_value` returns a `Uint`, or a
nonnegative `Int`. `float_value` returns an `Int`, `Uint` or `Float` as a binary64. All three return false for a kind
they do not read; `float_value` returns false for `Wide`, which the caller reads from its span. A node that is no
number returns false from each.

`resolve(doc, i, opts := Resolve_Options{})` returns what a node is: `.Null` for a miss, and otherwise the format's
answer. JSON's is the node's own kind. dsv's returns `.String` for a key cell, for a quoted or escaped cell, and for
every cell without `opts.infer`. With `infer`, an empty cell is `.Null`, a `true` or `false` cell is `.True` or
`.False`, and a cell that is exactly a JSON number is `.Number`. A quoted cell, a TSV escape and a cell holding an
ill-formed sequence answer `.String`, since their span holds a quote, a backslash or a byte no JSON number holds.

## The spelling services

A `Spelling` holds five services, `text`, `key_equals`, `number`, `resolve` and `close_end`, the `query` engine `core.query`
dispatches through, which each format points at `core/build`'s, and a pointer to the format's `Edit_Spelling`. A document points at its format's table in rodata,
one table for every spec of the format: a JSON token holds no form that only JSON5 reads, so `text` reads any JSON
string, and dsv's `text` and `key_equals` read `Document.read.spec`, since a CSV backslash is a byte, a TSV
backslash is an escape, and a `Plain` cell has neither. `text`, `key_equals` and `number` take a `Token_View`, the
source, the table and the read, and the token by value, so a typed read hands them a walk's token with no document.
`Document` starts with `using view: Token_View`, and `Edit_Spelling.value` takes one too.

| Service | JSON | dsv |
|---|---|---|
| `text` | unescape, JSON5 quotes and identifiers | a quoted cell's inner span, `""` to `"`, a TSV escape, U+FFFD |
| `key_equals` | compare an escaped key without decoding | the same over a quoted or escaped cell |
| `number` | the recorded shape, else the token's grammar | a plain value cell that is exactly a JSON number |
| `resolve` | the node's kind | what a `Plain` cell is |
| `close_end` | forward over trivia and inner closes | a record's line end, the text's end for the root |

```odin
Edit_Spelling :: struct {
	value:        proc(v: ^Token_View, src: []u8, allocator: runtime.Allocator) -> Document_Error,
	key_text:     proc(doc: ^Document, name: []u8, text: ^[dynamic]u8) -> bool,
	reads:         proc(doc: ^Document, src: []u8, tolerate: bool, spec: u8) -> (fault: Fault, faulted: bool),
	comment:       proc(doc: ^Document, spec: u8) -> (style: Comment_Spelling, b: u8),
	member_sep:    proc(doc: ^Document) -> string,
	key_sep:       string,
	insert_check:  proc(doc: ^Document, container: Node_Index, text: string, allocator: runtime.Allocator) -> Document_Error,
	interior:      proc(doc: ^Document, c: Node_Index) -> (lo, hi: u64),
	fact_slot:     proc(doc: ^Document, node: Node_Index, role: Role, emptied: bool) -> bool,
	emptied:       proc(doc: ^Document, list: ^Edit_List) -> bool,
	plan:          proc(doc: ^Document, list: ^Edit_List, out: ^[dynamic]Edit, allocator: runtime.Allocator) -> (changed: bool, err: Document_Error),
	commit:        proc(list: ^Edit_List, spec: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: Document_Error),
	flat:          bool,
}
```

`Comment_Spelling` is `None`, `Line` or `Byte`: no marker, a JSON line or block comment, or a delimited text's comment
line. Under `Line` a body holding a line end is written as `/* */`, so a line comment cannot end its line early. JSON's
table supplies `value`, `key_text`, `reads`, `comment` and `member_sep`, with `key_sep` `":"`, and its `comment` is
`.Line` for `Jsonc` and `Json5` and `.None` for `Json`. dsv's table supplies `value`, `key_text`, `reads`, `comment`,
`member_sep`, `insert_check` and `plan`, which turns a list's column changes into plain edits. Each table's `commit` calls
`compose.commit`, which `core/compose` holds, so core reads no composing state. A format with `flat` set has no brackets
in its text, so `interior` says where a container's members lie, the `compose.Root_Spelling` it passes composes the root,
whose members are lines (`dsv/compose.odin`), and `fact_slot` and `emptied` say which facts the output holds. dsv's `member_sep` is the
delimiter, and its line end is the first one the text has for a record, else its header's, else LF. A record's cells
take the junction a tree's members do, in `core/compose/compose.odin`.

A reader reaches the table only where it must: `text` and `key_equals` for a marked node, `number` for every scalar,
`resolve` for every node, `close_end` for a container whose span is read, and the edit services for every recorded or
committed text. A caller that knows the format at compile time calls `json.text` or `json.number` directly.

## Duplicate keys

`Duplicates` says how an object's repeated keys are read: `.First` gives the first match and `.Last`, the default, the
last, while `members_named` yields every match. A path that asks for every match is a path option, not a `Duplicates`
member. Refusing a repeated key is a build check, not a reader choice: `json.build` and `dsv.build` take
`refuse_duplicates`, false by default.

A build with `refuse_duplicates` tests each object as it closes, comparing the decoded text of its keys through a hash
table that is 64 entries on the stack and spills to the allocator past 32 keys. A repeat is reported at the later key's
first byte, counting its opening quote, and an inner object closes before an outer one, so the earliest repeat in
document order wins, while a refused allocation in a later check replaces no earlier error.

A build that stops on a fault checks the objects it left open, innermost first, since their close never ran. dsv's
header row has no close, so a headed build tests it after the walk. Both go through `build.builder_refuse_result`, which
keeps the earliest repeat in the build's error and which a format's `build` may call for a container it checks itself.

## dsv as a document

A delimited text is an `Array` of records whose first child may be the header row.

- The root is an `Array` of role `Value`, and its readers step over the header row as over a member's key, so `length`
  counts records and `children` returns the records. `Document.shared_keys` is the header row's node, 0 for a text read
  without one.
- A record with a header is stored as a `Kind.Map` with no inline key nodes. Its cells are its children, each
  a `Plain` token of role `Value`. No record stores a key node, so it holds one node per cell.
- The header row is an `Array` of role `Key` whose cells are `Plain` tokens of role `Key`, one per column. Its `n` is
  its cell count plus one and its `spelling` its cell count.
- The Map readers of a headed record resolve a cell by its column: `member` and `members_named` walk the header's cells,
  and column `i`'s key is header cell `i`. `pairs` yields `(key, val)` by pairing each header cell with the record's
  corresponding value cell. A cell's node is its record's node plus one plus its column, so `child_at` returns a cell
  in one step. A column past a record's last cell, as a ragged record has, names no cell.
- A header cell reads as a key node, so `key_equals`, `text`, `number` and `resolve` answer for it as for a JSON key.
- A headerless text (`no_header` true) has no header row (`doc.shared_keys == 0`), making the first record data and every
  record an `Array` of `Plain` value cells, with no key node at all.

## Facts

A `Fact` holds `lo`, `node`, `n`, `role` and `spelling`: a comment token, the node it belongs to and its role. The
list is sorted by node, keeps source order within a node, and is empty for a strict JSON document and a dsv text with
no comment byte. `lo` and `n` span the comment's bytes, markers included.

A comment's node follows the walk's `Role` rule: a comment on the line where the value before it ends is that value's
`Comment_Inline`, else one before a value the grammar allows it above is that value's `Comment`, else it is the
`Comment_Foot` of the innermost open container, or of the root at depth 0.

The builder keeps a head comment pending until the value it marks arrives, gives an inline comment to the last value
it completed (`Builder.last`), or holds it pending when none has, and gives a foot to the innermost open container's
frame, or to the root. A
comment run with no value after it becomes the root's foot when the build ends. A dsv comment line is a walk token
like any other fact: a line above a record is that record's `Comment`, and a line above the header row becomes the
root's, a `Comment` when a record follows it and a `Comment_Foot` when none does.

`facts_of(doc, i, role)` starts a `Fact_Iter` walk over node `i`'s facts of that role, and `fact_next` returns their
bodies in source order, one at a time, as a `string` and whether it read. `NO_NODE` and a node with no such fact give
an empty walk, and a read allocates nothing. A body is the source between the markers: the fact's `spelling` holds the
lead marker's length in its low byte and the tail's in the next. A `//` comment leads with two bytes and trails with
none, a `/* */` comment leads and trails with two, and a delimited text's comment line leads with one.

## Edits

An edit list is kept apart from the document, which never changes. A reader sees an edit only after the caller commits
the list and builds the output again.

```odin
Edit_List :: struct { doc: ^Document, edits: [dynamic]Edit, allocator: runtime.Allocator }
Edit :: struct { node: Node_Index, op: Edit_Op, role: Role, at: u32, key: []u8, text: []u8 }
Edit_Op :: enum u8 { Set, Insert, Remove, Set_Fact, Remove_Fact }
```

`edit_list_init` makes an empty list over a borrowed document and allocates nothing until the first edit. Any number
of lists may share one document. The list's allocator owns the log and a copy of each edit's key and text, which share
one allocation with the key first, and `edit_list_destroy` frees them.

### Recording an edit

An edit is checked when it is recorded, by reading its own text, so the check costs O(the text). The format's own walk
judges the text as one value, one key or one record of the document's spec, and for a delimited text of its recorded
`delimiter` and `comment` byte. Every text argument is a `string`, and the list copies it.

| Call | Records | Refuses |
|---|---|---|
| `set(list, node, text: string)` | the node's bytes become `text`; a key's text is its decoded name | `.Bad_Index`, `.Bad_Value` |
| `insert(list, container, at, text: string)` | an element of an `Array` | `.Bad_Index`, `.Wrong_Container`, `.Bad_Position`, `.Bad_Value` |
| `insert(list, container, at, key, text: string)` | a member of a `Map`, its key a decoded name | the same |
| `remove(list, node)` | the member the node is, and its key | `.Bad_Index` |
| `set_fact(list, node, role, text: string)`, `remove_fact(list, node, role)` | the facts of the node and role | `.Bad_Index`, `.Bad_Fact` |

- `set` takes a value or a key. It refuses a node whose role is a fact's and a table's container. A key's text is its
  decoded name, which the commit writes with the format's quotes and escapes; a dsv header cell's new text is a record
  of exactly one cell.
- In a delimited text a cell's text is one record of exactly one cell, and an empty text is the empty cell. A root's
  insert is a record. An insert's `at` is 0 through the container's length at the time the edit was recorded.
- A delimited text's columns are the commit's to decide, from the whole list. A cell joins a headed record, a `Map`, by
  name and a headerless record, an `Array`, by position.
- `remove` takes any value that is a member of a container, and a delimited text's header cell. It refuses the root and
  any other node whose role is not `Value`, so a key goes with its value.
- A fact edit takes any node that is not a key and a role past `Key`. `Comment_Inline` refuses a body holding LF or CR
  with `.Bad_Fact`, and a role at or below `Key` is `.Bad_Index`. A second edit of one node and role is recorded and
  `commit` refuses it with `.Conflicting_Edits`.

JSON's value check walks the text as exactly one value of `doc.read.spec` at `doc.read.max_depth`, refusing one that
begins with a byte-order mark or holds a comment after its value, since a splice would put the next bytes inside it.
JSON's key check reads the text as the only member of `{text:0}` and requires the key's token to cover the whole text.

### A commit

```odin
commit :: proc(list: ^Edit_List, allocator := context.allocator) -> (out: []u8, dropped: int, err: Document_Error)
json.commit :: proc(list: ^core.Edit_List, as: Spec,
	allocator := context.allocator) -> (out: []u8, dropped: int, err: core.Document_Error)
```

`core.commit` writes the output in the document's own spec. `json.commit` writes another JSON spec, and a text of
another spec must read strictly, since the source's own reading is no evidence. A delimited text
has only `core.commit`: a spec change would respell every cell, so its table's `commit` returns `.Bad_Spec` for another
spec before the splice, and `json.commit` does for a delimited document. The commit
builds the output in one allocation with the format's separators, the caller frees `out`, and reading after edits is
`commit` then `build`.

A delimited text's commit first turns the list's cell edits into column changes (`dsv/plan.odin`). A list with no cell
inserted or removed pays one pass over its edits, and any other pays one over the records. A cell removed from every record that holds it drops its column with the
header cell, and a removed header cell does the same. A cell removed from only some records is emptied. A cell inserted
beyond the old columns adds a column: one per name in a headed text, at the position the insert gives or else at the
end, and one per position in a headerless one. A record no insert fills gets an empty cell. A short record stays short
unless a cell is written past its end, which pads the cells before it.

The commit refuses:

- two edits of one node, two fact edits of one node and role, two ranges that overlap, and an insert inside what another
  edit replaces. All are `.Conflicting_Edits` at the byte where the two meet.
- an edit inside the subtree another edit removes, and a fact edit on a node below a set's node, both
  `.Conflicting_Edits` at the named node's first byte. The edits are sorted by node and swept once, so the check is
  O(n log n).
- a cell that one list both sets and removes, with `.Conflicting_Edits` at the cell's first byte, whatever the list does
  to its line's width.
- an edit that would leave a delimited text a line that does not read as its record, with `.Bad_Width`: a line with no
  cell or with one empty cell, which reads as no record, or one whose new first cell starts with the comment byte or, on
  the text's first line, a byte order mark. A record inserted into the root must hold as many cells as the table will
  have, and records inserted into an empty table must agree.
- a named cell that its record already holds, with `.Duplicate_Key` at the header cell, a new column that two inserts
  place apart, with `.Bad_Position`, a name the spec cannot spell, with `.Bad_Value`, and a second cell for one column
  of a record, with `.Conflicting_Edits`.
- a result that does not read, with `.Bad_Result`. The output is read strictly, then with the format's tolerances, and
  a text that needs a tolerance is accepted only when the source needed one too. A JSON commit under another spec must
  read strictly.
- a delimited text's spec change, with `.Bad_Spec` before the splice, and a spec of another format family, with
  `.Bad_Spec`, before the splice too.
- `.No_Memory` for any allocation it needs.

`dropped` counts the source facts and fact edits the output cannot hold. A fact removed with a removed member, or one
inside the span a set replaces, is not counted, since the edit that takes it accounts for it.

### Where a removal and an insert land

The commit composes each edited container once. A container is its members and the gaps between them, and the root is
the one member of the text. A junction is the bytes between two surviving neighbours: the gaps, the removed members
and the new members between them. An edited junction is written as one replacement, and a junction no edit reaches
stays bytes, so two replacements overlap only when a set covers a nested edit. At one byte, which only a cell of no
bytes makes possible, a record's line comes before a cell, then the set, then what follows the cell, then the next
line.

- A set replaces the node's own source bytes, a quoted key's quotes included, and leaves the trivia around it.
- A removal takes the member with its key and its comments and one separator, the one after it when a member follows
  and the one before it otherwise. A removal keeps the member before it on its line, that member's inline comment on
  that line, and the next member's head comment on its own line. A fact the output removes leaves its line end.
- A container whose every member is removed keeps its brackets, and a foot stays before the close. A dsv record is cut
  from its own first comment through its own line end, so a comment line beside it and its line end stay.
- New members at one index keep the order they were recorded in, and one at an index inside a removal run takes the
  run's place. A new member comes after the inline comment of the member before it and before the head comment of the
  member after it, and a foot stays last, so a record added to a text of only comments comes before them. A new member
  is joined to its neighbours by one separator. A table writes `read.delimiter` between cells and its `record_sep`
  between records, and a new last record ends as the old last record did.

### Facts in a commit

The output decides which facts it keeps.

- A fact keeps its node and role while its node survives. A fact no edit names keeps its bytes in place, unless a
  removal takes it, a set replaces its bytes, or the output cannot hold it. A fact the output cannot hold is removed
  with its bytes and counted in `dropped`. One role changes: a root comment above a delimited text's header, when every
  record is removed, reads as the root's foot, and it is kept and not counted.
- A tree holds a head or inline fact on any node and a foot only on a container or the root. A delimited text holds a
  head fact on a record, or on the root above its first record, and a foot on the root. An output whose spec writes no
  comment, as `Json` does, holds no fact at all.
- `set_fact` replaces the first fact of that node and role in place and removes the rest, or writes a new comment
  where the role reads it: a head before the node's first byte, an inline after the value, a foot before the close. A
  fact edit on a node the list removes, or on one below a set's node, is `.Conflicting_Edits`.
- A body is written as `//body` when a line end follows its place or the text ends there and the body holds no line
  end. It is written as `/*body*/` otherwise, and anything written after a `//` comment starts on the next line. A dsv body is the document's comment byte
  and the body, on a line of its own. A head or foot the source held mid-line gets a line of its own with that line's
  indent, and an inline fact gets one space before it. A body the output cannot spell is dropped and counted.
- A dsv foot at the text's end is written after a set or an insert at that byte.

## Errors

```odin
Document_Error :: struct { kind: Document_Error_Kind, at: u64, inner: Fault }
```

| Kind | Means | `at` |
|---|---|---|
| `Walk` | the walk's fault | the fault's byte, as in `inner` |
| `Duplicate_Key` | a build with `refuse_duplicates` met a repeated key | the later key's first byte |
| `No_Memory` | an owned allocation was refused | none |
| `Bad_Index` | an edit names no node it may change | none |
| `Bad_Position` | an insert is past the container's length | none |
| `Wrong_Container` | the container takes the other insert form | none |
| `Bad_Value` | a text is not exactly one value of the format and spec | none |
| `Bad_Fact` | a fact body does not have its role's shape | none |
| `Bad_Width` | an edit would break the table's width | none |
| `Bad_Spec` | a commit asks for another format family's spec, or a dsv spec change | none |
| `Conflicting_Edits` | two edits meet, or one lies inside another's range | where they meet |
| `Bad_Result` | a committed text does not read | none, the fault in `inner` |

`inner` holds a `Fault` by value for `.Walk`, `.Bad_Value` and `.Bad_Result`, and for the last two its `at` names a
byte of the recorded text or of the commit's output, so it renders without a position. The kinds that name no byte
have an `at` that is not read.

```odin
write_code :: proc {write_fault_code, write_document_code}
render     :: proc {render_fault, render_document}
```

`write_code` writes a code. For a document error it is `document.` and the kind's code, as in `document.walk` or
`document.duplicate_key`. For a fault it is the format's name, a dot, and the rule's code, as in `json.literal`,
`dsv.field_count` or the kind's own code `json.bad_char`. A code is stable across releases, and a message may change.

`render` writes a line from a rule table in rodata, without calling into the format. For a document error it writes
`line:col: message`, then for `.Walk` a newline and `caused by` with the rendered fault, and for `.Bad_Value` and
`.Bad_Result` the fault's message alone. For a fault it writes `line:col: message`, or the message alone for a kind in
`AT_NO_BYTE`. Line and column count from 1, the column in bytes, and a `Lines` carries the count from one fault to the
next, so each byte is scanned once.

## Limits

| Bound | Value | Effect |
|---|---|---|
| `spell.MAX_NUMBER_DIGITS` | 256 | more authored mantissa digits read as `.Wide` |
| `spell.MAX_NUMBER_SCALE` | 4096 | an exponent or scale beyond ±this reads as `.Wide` |
| `MAX_CHILDREN` | 65535 | the largest child count `spelling` holds, with the true count in `Document.counts` |
| `core.MAX_DEPTH` | 1024 | the deepest nesting when `Options.max_depth` is 0 |
| `Token.n` | `u32` | a token one byte longer is `.Too_Wide` |

A number's `spelling` holds its integer and fraction digit counts in five bits each, so a count saturates at 31, and a
reader that sees one reads the span again rather than trust the fields. The duplicate-key table is 64 entries on the
stack and holds 32 keys before it spills. A fact's two marker lengths are the bytes of its `spelling`, so neither may
exceed 255 bytes. dsv's build stack is 8 slots and does not grow, since a record nests at most two containers.
