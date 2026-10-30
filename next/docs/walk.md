# The walks

A walk reads one text from a byte offset and passes every token to a hook in the order it reads them, until the text
ends, a fault stops it, or the hook returns `.Stop`. Every format has a walk, and every walk gives the same tokens
through the same hook, so a consumer written against `core` reads any format. `validate` is the same walk with no
hook.

This document describes what the walks share, how the JSON walk and the delimited-text (dsv) walk are built, and the
Odin and LLVM behaviour behind the hot-path shape. `kernel.md` covers the vector code both walks use.

## Files

| File | Holds |
|---|---|
| `core/walk.odin` | `Kind`, `Role`, `Token`, `Action`, `Hook_Regs`, `text_start` |
| `core/document.odin` | `Node`, `Document`, the builder hook, the readers, `Duplicates`, `Spelling` |
| `core/edit.odin` | `Edit_List`, `Edit`, `Edit_Spelling`, `set`/`insert`/`remove`, `commit` |
| `core/number.odin` | `Number`, `Number_Kind`, the decimal, hex, infinities and the JSON number writer's reading |
| `core/escape.odin` | the escape-byte and hex-digit tables both formats' decoders share |
| `core/error.odin` | `Fault_Kind`, `Fault`, `Rules`, `Rule`, the codes, line and column, the renderer |
| `json/walk.odin` | JSON's interface, the result word, `Walk`, `walk_document`, the hook calls |
| `json/document.odin` | JSON's `build` and its spelling table |
| `json/unescape.odin` | JSON's string decoder, its key compare and its number reader |
| `dsv/document.odin` | dsv's `build`, its spelling tables and its header rule |
| `json/states.odin` | the grammar states, one procedure each, and the value classes |
| `json/strings.odin` | the string readers, from a two-load probe to a block reader per x86 tier |
| `json/scalars.odin` | numbers and literals |
| `json/whitespace.odin` | whitespace, the colon after a key, the indent predictor |
| `json/comments.odin` | comments: the reader, a run of them with JSON5's whitespace, and the states that give them roles |
| `json/json5.odin` | JSON5's numbers, strings, unquoted keys and whitespace, and the states that read them |
| `dsv/walk.odin` | dsv's interface, the dispatch to a pass per tier, the result word, the hook calls |
| `dsv/pass.odin` | the pass over 64-byte blocks and its state between blocks |
| `dsv/records.odin` | what a block's separators end: cells and widths for `validate`, tokens for `walk` |
| `dsv/text.odin` | the byte-at-a-time readers the masks cannot replace |

## The interface

Each format package exposes the names a caller uses: `Spec`, `Options`, `Detail`, `RULES`, `walk`, `validate` and
`build`, plus the token spelling detail its walk documents (`json.Number_Spelling` and `json.number_spelling_of`).
Everything else, including the `core.Spelling` tables, is `@(private)`.

```odin
Spec     :: enum u8 { ... }    // the grammar, at compile time
Options  :: struct { ... }     // what a walk receives at run time
Detail   :: enum u8 { None, ... }   // the format's own rules, in `Fault.detail`
RULES    : core.Rules             // each rule's code and message, in rodata
walk     :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), keys: []core.Token = nil) -> (hi: u64, fault: Maybe(core.Fault))
validate :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> Maybe(core.Fault)
build    :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Document_Error)
```

`keys` is optional scratch the caller may pass: one `core.Token` per header cell. The walk fills it with the header
record's cells and allocates nothing for them. With `nil`, `walk` allocates one token per header cell from the default
heap and frees it before returning. `dsv.build` passes a buffer so the header's cells are read once and written into
the row it built.

`build` runs the value layer: it passes `walk` core's `builder_hook` and returns the document of nodes and facts, or
a `Document_Error`. `Document_Error.at` is the byte the error names, 0 for a kind that names none, and `inner` is the
walk's fault for `.Walk`. The format's `document.odin` holds a `core.Spelling` table in rodata per reading (JSON, and
CSV or TSV), and a reader uses it to decode a string or number without running a second walk.

A limit of the format's grammar may be public beside them, as JSON's `MAX_DEPTH` is, because a caller sizes a stack
for the walk's tokens from it.

- `Spec` is a compile-time parameter. Each spec is a separate instance of the walk, so a build carries the code of the
  specs it names and no other. Odin refuses a struct as a `$` parameter, so run-time settings, such as whether a CSV
  text has a header, go in `Options`. JSON's specs are `Json` (RFC 8259), `Jsonc` and `Json5` (JSON5 1.0.0). Each spec
  reads its own grammar whole and refuses the rest, unless `Options.tolerate` names a rule it may break (see
  Tolerances).
- `$S` has no default. A caller names the grammar it reads.
- A walk from byte 0 skips a UTF-8 byte order mark through `core.text_start`, as `validate` does. Outside a string, a
  BOM at any later byte is `Bad_Char` in JSON and JSONC, whitespace in JSON5, and a cell byte in dsv. Inside a JSON
  string it is the character U+FEFF.
- `hi` is one past the last byte read, or the fault's byte. When a hook stops the walk, `hi` is one past the token it
  stopped on and there is no fault. The walk has read no further, so `hi` is not a document boundary.
- A walk reads one document, and `validate` judges a text that holds one. No format takes a framing option: the
  document's own bytes say where it ends. Before its document, a JSON walk skips whitespace, the record separator
  0x1E, and in a spec with comments the comments, and in JSON5 its whitespace. When nothing but those remain before
  the text's end or a 0x1E, it emits no token and returns the text's end with no fault. A stream of documents
  (NDJSON, RFC 7464, jq's input) is therefore a loop of walks, each starting where the last ended. A dsv text is one
  table, so its walk reads to the text's end, and a walk started past the end reads an empty table.
- The walks are contextless, so a hook can call a walk. A walk that needs scratch allocates it from the default heap
  and frees it before it returns. `validate` allocates nothing unless `max_depth` is past `MAX_DEPTH`.

### The document

`build` returns one `core.Document`: the walk's tokens as `core.Node`s in preorder, the facts beside them, and a
`core.Spelling` table. `ROOT` names the root's node and `NO_NODE` a miss. The readers are `kind`, `span`, `text`,
`number`, `resolve`, `key_equals`, `length`, `children`/`child_next`, `child_at`, `first_child`/`next_child`,
`member`/`member_all` and `facts_of`. A reader given an index no node holds refuses as it does for a node of the
wrong kind: `kind` and `resolve` return `.Null`, `length` 0, `span` nil, `number` `.Wide`, `text` false,
`key_equals` false and `child_at` no node.

A document holds no `End` node. A container's `n` is its subtree's node count, its own node included, so its next
sibling is `i + n`. Its `spelling` is its child count, where a member counts once, not its key and value. `length`
reads that count and counts the members by stepping when the count is saturated (`CHILDREN_MAX`). `span` of a
container runs from its open to its close. The close is no node, so the format's `close_end` service starts after the
container's last descendant (or at its open when the container is empty), skips the closes on its rightmost spine and
the whitespace and comments between them, and ends one byte past its close. A string's token span is the text between
its quotes, and `span` restores the quotes from the quote bit for splicing. `text` of a node that needs decoding
writes into the caller's buffer when the buffer holds the token's span, which decoded text never exceeds, so a read
allocates only for a buffer shorter than the token.

A dsv text read with a header is an `Array` of records whose first child is the header row: an `Array` of role `Key`
whose cells, each a `Plain` token of role `Key`, name the columns. The root's readers step over it as they step over a
member's key, and `length` of the root counts the records. `Document.header` is that `Array`'s node, 0 for a text read
without a header and for every JSON document. A record is an `Array` of `Plain` cells. The Map readers of a headed
record resolve cell `c` with the header's cell `c`: `member` and `member_all` walk the header, and a cell's node is
its record's node plus one plus its column. `child_at` returns a record's cell `c` in one step, since every child of a
headed record is one node. A column past a record's last cell, as a ragged record has, names no cell, and a header
cell reads as a key node, so `key_equals`, `text`, `resolve` and `number` return for it as they do for a JSON key.
The build writes the header row before the walk and passes the walk a key buffer of one token per cell, so the walk
reads the header once and `build` fills the row's cells from it. No record stores a key node. `Document.delimiter`
and `Document.comment` hold the run-time dialect the text was read with, the byte between cells and the byte that
starts a comment line, 0 for none and for a JSON document. They fill the padding `header` leaves, so the document size
and node positions do not change.

### The edit list

A document does not change after its build, and no reader accepts edits. `core.edit_list_init` makes an empty
`core.Edit_List` over a document, and any number of lists may share it. `set`, `insert` and `remove` append an edit
`(node, operation, text)`, and `commit` splices the log into the source: every byte no edit touched stays as it was,
including comments, spacing and number spellings. The format supplies the separators.

An edit is checked when it is recorded, by reading its own text. `set` writes one value over a node's own bytes, or
one key over a key's, and `insert` adds an element to an array or a member, with a key, to an object. A delimited
text's root takes a record of cells and a record takes a cell. The format's own walk judges the text as one value, one
key or one record of the document's spec and, for a delimited text, of its `delimiter` and `comment` byte, so the
same walk parses the recorded text and it reads as its document does. A cell that holds the delimiter unquoted is two
cells unless the spec quotes it (Csv and Tsv can, Plain cannot), and a cell or record that starts a line with the
comment byte is no record. Both are refused. `remove` takes a value that is a member of a container, with its key.

`core.Edit_Spelling`, which `Spelling.edit` points at as its cold field, supplies `value`, `key` and `record` to judge
a recorded text, `reads` to read a text with or without the format's tolerance set, the member and key separators,
and the line end a record insert writes, taken from the text. A table's cell separator is the document's `delimiter`,
so a read of `;` writes `;`. A document whose edit table has a `record` service holds a table's records and cells, and
every other document holds values. `Document.spec` names the spec an edit's text is judged by, so a table serves
several specs of a format when only the edit services differ. A format whose readings differ in what they accept as
an edit has a table per spec, and dsv's Plain uses the services of Csv and Tsv.

A commit sorts the edits by source position, resolving an insert's position against the document the list was made
from, so a commit takes O(text) time. It cuts a removed member with the comments attached to it and one separator, the
one after it when a member follows and the one before it otherwise. A container whose every member is removed keeps
only its brackets. A dsv record is cut from its own first byte through its own line end, so a comment line beside it
and its line end stay, and an insert beside one is placed on the side that leaves the comment line a line of its own.
A set replaces the node's bytes and leaves the surrounding trivia. Two edits of one node conflict,
as do an edit inside what another replaces or an insert whose byte a removal's range touches, and both are refused as
`.Conflicting_Edits`. A delimited text's width is its header's or its first record's, so an edit that would leave a
record the table cannot follow is refused. A committed text is checked once, in core: it must read strictly, then
within the format's tolerance set, and only a text that needs a tolerance the source also needed is accepted. A text
that fails even the tolerant read is not committed. Reading after edits is `commit` then `build`.

### Tokens

```odin
Token :: struct { lo: u64, n: u32, kind: Kind, role: Role, spelling: u16 }
```

A token is 16 bytes and crosses a call in two registers. `lo` and `n` are its span in the text. Tokens come in the
order the walk reads them, which is text order except for a dsv `Key`, whose span is its column's header cell, before
the record that names it. `kind` says what the token is: a scalar (`Null`, `False`, `True`, `Number`, `String`,
`Plain`), a container's opening (`Array`, `Map`), or its `End`. `role` is `Key` for a JSON member's name and for the
header cell that names a dsv cell's column, and past `Key` a fact: a comment, `Plain`, as `Comment`, `Comment_Inline`
or `Comment_Foot`. A consumer that wants values only tests `role <= .Key`. `spelling` is a detail the format writes
and core reads through three bits: bit 0 says `text` must be decoded, bit 1 says the token is quoted (a JSON string,
whose token span leaves its quotes out, or a quoted dsv cell, whose span holds them), and bit 2 says a JSON string
holds a tolerated ill-formed UTF-8 sequence. The other bits are the format's own. A token longer than `n` can hold is
the fault `Too_Wide`, so a span is not cut.

### Hooks

A hook is `on(h, regs, token) -> (regs, action)`. `$on` is a compile-time parameter, so the walk is instantiated per
hook and the call inlines: a hook that tests a token's kind and returns folds into the walk, and a hook that does
nothing compiles to no code. `validate` is the walk with such a hook.

`Hook_Regs` is three words passed in the walk's argument registers from token to token. A cursor or count kept there
needs no load or store per token. Anything larger stays behind `h`. Three words are what fit beside a walk's own
arguments in the arm64 and x86-64 calling conventions.

The `Action` a hook returns:

- `Next` continues the walk.
- `Skip` on an `Array` or `Map` passes the container with no more tokens, its `End` included, and on a `Key` passes
  the comments before the member's value and the value. The walk still judges the bytes it passes. The comments after
  a skipped value are still given. On a scalar it acts as `Next`.
- `Stop` ends the walk at once, with no fault and the rest of the text unjudged.

### The result word

Inside a walk the result is a `u64`: a position in bits 16 and up, a `Detail` in bits 8 to 15, and a `Fault_Kind` in
bits 0 to 7, 0 for none. The `walk` procedure turns it into `(hi, fault)` at the end. The word returns in one
register through every state and pass, where a `(u64, Maybe(Fault))` would return through memory. A detail of
`STOPPED` with no fault says a hook stopped the walk. It has the same value as a member of `Detail`, which is safe
because a detail is read only beside a fault kind.

### Faults

```odin
Fault :: struct { at: u64, rules: ^Rules, kind: Fault_Kind, detail: u8 }
```

`kind` is the same for every format. `detail` is the format's rule within that kind, numbered by each format
independently, 0 for none. `at` is the byte the kind names. A count or limit is not written into it. A kind in
`AT_NO_BYTE`, such as `No_Memory`, names no byte and its `at` is not read.

`rules` points to the format's `RULES` in rodata, which holds a code and a message per detail. Core names a fault
(`write_code`: `json.literal`, `dsv.field_count`, or the kind's code, `json.bad_char`) and renders it (`render`:
`line:col: message`) from that table without calling into the format, so a format outside stury can add its own table
and render the same way. A code is stable across releases and a message may change.

`locate` returns a byte's line and column, both counted from 1, with the column in bytes. It continues from the
position a `Lines` count reached, so faults met in offset order scan each byte once.

### Tolerances

`Options.tolerate` is a `bit_set` of the format's `Tolerance`, the rules a caller allows a text to break. A rule in
the set has one fixed reading, and a rule outside it faults. No tolerance is set by default, and a tolerated fault
produces no warning.

| Tolerance | Format | Reading |
|---|---|---|
| `Invalid_Utf8` | json (in a string), dsv (in a cell) | each maximal subpart of an ill-formed sequence is U+FFFD |
| `Lone_Surrogate` | json (in a string) | a `\u` escape of a surrogate half no other half pairs with is U+FFFD |
| `Ragged` | dsv | a record with fewer cells than the first has its missing columns absent, with no header any width |
| `Bare_Quote` | dsv (CSV) | a quote inside an unquoted cell is a byte of the cell |

- A tolerance changes no structure. A token keeps its bytes, and the difference appears in the value it decodes to. A
  cell whose reading changes may set the decode bit.
- A tolerated fault is found at the same byte as in a strict walk, on the branch that handles the fault, so clean text
  runs no tolerance code.
- Some faults no tolerance covers: a number's grammar, text after a closing quote, anything structural, ill-formed
  UTF-8 outside a string or a cell (a JSON comment or identifier, between tokens), and a sequence cut short by the end
  of a string or quoted field that the text also cuts short (`Truncated`).

## The JSON walk

The JSON walk is a state machine. Each grammar state is a procedure, `st_value`, `st_key`, `st_after`, `st_close` and
the rest. It reads the first byte of the token at its cursor, branches on it, reads the token with a leaf, passes it
to the hook, and tail-calls the next state with `#must_tail`. No state returns until the walk ends.

### Registers

Every state takes the same arguments:

| Argument | Holds |
|---|---|
| `p` | the cursor |
| `end` | one past the text |
| `d` | the depth shifted left once, the open container's kind in bit 0 (1 for an object) |
| `ind` | the predicted indent: the last line's indent in the low half, the step per level in the high half |
| `w` | `^Walk`, what the states share beyond their registers |
| `s0`, `s1`, `s2` | the hook's `Hook_Regs` |
| `$on` | the hook, at compile time |

A tail call passes the same registers it received, so a move between states is a jump.

- The state is held in registers, not in a struct. A field of `w` that changed per token would cost a load and a store
  per token, so `w` holds what changes rarely: the text's base, the hook's state, the depth stack and the tier.
- `d` carries the container's kind. Whether a close bracket is `]` or `}` and whether the next member starts with a
  key are bit tests on a register. `]` with bit 5 set is `}`, so `p[0] == ']' | (d & 1) << 5` tests the right one.
- The depth stack holds only what no register holds. An open bracket writes the kind of the container it leaves into
  that depth's slot, and a close reads it back into `d`. The stack is `MAX_DEPTH` bytes on the walk's stack and stays
  unwritten (`= ---` on an array, where a struct would be zeroed), and no slot is read before it is written. An
  `Options.max_depth` past `MAX_DEPTH` allocates its stack from the default heap in `walk_deep`, kept out of line so the
  walk's entry does not change. An open compares the depth with `w.depth`.
- Every state is `#force_no_inline`. Inlining one state into another would make a single procedure that saves the
  union of their registers on entry, and separate states save only their own.

### States and leaves

A state chooses and a leaf reads. The leaves (`number`, `literal`, the string readers, `skip_ws`, `colon`) are
`#force_inline`, take a cursor and `end`, and return one past the token or a fault kind. A leaf that needs a call, or
builds a vector on entry, makes every state that inlines it save the call's registers, so rare work goes to a state
of its own:

- Whitespace after a token goes to `st_open_ws`, `st_after_ws`, `st_member_ws`. The hot states hold only
  `indent_fast`, which is scalar and builds no vector.
- A string that holds an escape goes to `st_string_escaped`, which keeps the escape masks' registers to itself.
- A bad literal goes to `st_bad_literal`, so `st_value` saves nothing for its call.
- In JSON5 a byte that starts no JSON value goes to `st_value5`, and one that opens no JSON key to `st_key5`, with the
  comment run, the close after a trailing comma and the fault, so the states every document passes through keep their
  size.
- A skipped value goes to `st_skip` and `st_skip_member`.

`st_value` branches on a 256-entry class table (`VALUE_CLASS`), so `true`, `false` and `null` share one branch.

### Strings

A string goes to the first reader that can read it whole, falling through to the next when that reader cannot:

1. `string_short` loads 16 bytes twice. A value string that closes within 32 bytes of printable ASCII is read
   with no loop.
2. `string_probe`, for keys, reads up to 32 bytes one at a time, each a branch on a table. A key's length repeats
   from member to member, so the branch that reads its closing quote is predicted, and the next state's address does
   not wait on a vector compare.
3. `string_lean` reads plain ASCII 64 bytes at a time with no UTF-8 state.
4. `string_escaped` reads on from the block of the first backslash, judging each block's escapes in masks with no
   branch per escape.
5. `string_long` reads blocks with UTF-8 validation, through one `string_span` per x86 tier.
6. `string_exact` reads byte by byte and gives the exact fault for what no block reader vouches for. It is where
   `Invalid_Utf8` and `Lone_Surrogate` permit a fault, so the readers above it refuse what those tolerances would
   accept.

### Tiers

The states are built for one tier per target, its floor (`STATE_TIER`: v2 on x86-64, the only tier elsewhere), with
`@(enable_target_feature = STATE_FEATURES)`. `#must_tail` cannot jump between procedures built with different
features, and three copies of every state would triple the code in the instruction cache. Only the block string
reader differs by tier: `string_long` switches on `w.tier`, read once per walk from `kernel.tier()`, to a
`string_span_v2`, `_v3` or `_v4` that is `#force_no_inline` with its tier's features, following `kernel.md`.

### Whitespace and indentation

Compact text has no whitespace between tokens, and each state first tests that the next byte starts a token.
Pretty-printed text puts a newline and an indent between most tokens. `indent_fast` predicts the indent: one step
deeper after an open bracket, the same after a comma, one step out before a close. It checks the predicted run with
one masked compare of up to 32 bytes, `spaces_lead`, and reads the token after it without a loop. `skip_indent` counts
a run the prediction missed and records the indent after a newline and the step after an open bracket. A
single space before the next token, as some compact printers write after a comma, is handled there too, after the
newline test, so neither compact nor indented text runs extra code for it.

`st_key` reads the colon after a key on a fast path when the colon is flush against its value or followed by one
space, with or without one space before it. `st_colon` handles every other spelling. A byte where the colon must be
is `Bad_Char` with `Colon`.

### Runs

A run of open brackets is pushed in `st_open_run`, and a run of close brackets is popped in `st_close`. `st_close`
keeps the depth apart from the kind bit, so the next close does not wait on the stack load.

A number hands over to `st_after_number`, which is `st_after` with two more ways out. In an array, when the element
after the comma starts a number, the walk enters `st_number_run`, which reads number elements separated by a comma and
at most one space in a loop. In an object, the next member enters `st_member_run`, which reads members with a short
key, a colon in a fast-path spelling and a number value in a loop. Either run passes anything else to the states that
read it, so the states every document passes through hold none of the runs' code. `st_after_number` is separate from
`st_after` for the same reason and has the same separator rules.

### Skip

`pass_over` reads a skipped value: it is the same states instantiated with no hook, entered by a call, because
`#must_tail` cannot jump between two instances of the walk. Before the call, the slot of the depth the skipped value
closes back to is marked with `PASS_END`. A close compares its byte with `]` combined with the slot's bits shifted in,
and that bit matches no byte of a valid text, so `st_close`'s loop stops as it reads the slot and the walk without
hooks returns from `st_pass_end`. The walk with the hook clears the mark and continues in `st_after`.

`st_skip_member` passes the comments around the colon itself, so the skipped value's first byte decides whether it is
pushed. A container read as a document's root counts its depth from 0.

### Comments

A spec adds to RFC 8259 through `FEATURES`, which the states test with `when`. A feature's code is placed only where a
state already refuses a byte or leaves its fast path: `st_value` on a byte of class `Bad`, `st_key` on a byte that is
not a quote, `st_colon` on a colon fault, and the separator states where a comment follows a value or its comma. In
`Json` every `when` is false, and its instance holds no code of the other specs.

A `/` in one of those places hands over to a state in `comments.odin`, which reads the whole run of whitespace and
comments up to the next token before passing any of it to the hook, because what follows the run decides each
comment's role. The rule is `core.Role`'s and is the same in every format:

- a comment on the line where the value before it ends is that value's `Comment_Inline`,
- else, before a value, that value's `Comment`,
- else, before a close bracket, the `Comment_Foot` of the value before it, or of the container when it is empty.

A foot comes after its value's `End`, so an empty container's foot comes before its own `End`, which places it inside.

The state that reads a comment after a value receives the value's end, so a separator state sends a comma followed by
a comment there rather than to the next member. After a document's root, comments past the root's line are its foot
when the text ends after them or a 0x1E follows them, and otherwise belong to the next document, with the walk ending
before them. A walk without hooks reads every run and emits nothing, and `validate` passes over the comments after its
document while it checks that only whitespace follows.

A comment's bytes are judged as a string's raw bytes are: UTF-8, no control byte except a tab, and in a `/* */`
comment also CR and LF. JSON5 accepts any control byte, as its grammar does. A `//` comment ends at CR or LF, and in
JSON5 also at U+2028 or U+2029. A `/` that opens no comment is `Bad_Char` at the `/`, and a `/*` that the text ends
inside is `Truncated`. Every spec with comments also accepts a comma before a close bracket: a close after a run of
comments is read without looking back at whether an open bracket or a comma came before the run.

A comment's body is stepped 16 bytes at a time to the first byte the reader must judge individually: a control byte,
a byte past 0x7F, a `*` in a `/* */` comment, and a line end in a JSON5 `//` comment. Whitespace between comments is
read one byte at a time, because a run there is short and a 64-byte vector load covers more bytes than the run. A
state that has already read the whitespace before a run's first comment passes that comment's position in `Walk.resume`,
with `Walk.crossed` for a comma read before it, so the run is not scanned twice.

### JSON5

`Json5` adds `.Es5` to JSONC's features: JSON5 1.0.0's numbers, strings, unquoted keys and whitespace (`json5.odin`).
A token that JSON spells the same way is read by JSON's own leaf. A state hands over to JSON5's readers only where
that leaf refuses or no JSON construct starts:

- `st_value` on `'`, `+`, `.`, `I` or `N`, and where JSON's number reader refuses or stops before an `x`, which the
  number runs test too,
- `st_key` on a byte that opens no JSON key: a single-quoted key, an ECMAScript 5.1 IdentifierName, or else `Bad_Char`
  with `Identifier`,
- `string_long`, where JSON's readers refuse a string: `string5` reads it again by JSON5's rules,
- every place a comment may start: JSON5's other whitespace (VT, FF, U+00A0, U+FEFF, U+2028, U+2029 and Zs) opens a
  run as a `/` does.

A number's `spelling` is the packed `Number_Shape` (`json/json5.odin`): the `Number_Spelling` in bits 0 to 3, whose
values are 0, 2, 4, 6 and 8, the integer digit count in bits 4 to 8, the fraction count in bits 9 to 13 (zero for no
fraction), and `NUMBER_EXP` in bit 14. Every kind value is even, so a number does not set core's decode bit 0, and a
pure integer is a decimal with a zero fraction count and no exponent. A string's or key's bit 0 is set when it needs
decoding, and a tolerated ill-formed sequence also sets bit 2.

Where the grammar leaves a choice, a `\u` escape keeps JSON's rule, so a lone surrogate half is `Bad_Escape` at its
backslash. An identifier accepts the letters of Nl, as ECMAScript 5.1 does, and a `\u` escape in it must write a
character the identifier may contain there. A bad escape is refused at the byte that breaks it.

## The dsv walk

The dsv walk is a loop over 64-byte blocks (`dsv/pass.odin`). `Spec` is the quoting grammar at compile time (`Csv`
quotes, `Tsv` backslash escapes, `Plain` neither), and `Options` names the delimiter and comment byte at run time, 0
for the spec's own (`,` for CSV and Plain, tab for TSV). Each block is sorted with one `pack_n` into masks of its
delimiter, LF, CR and quote bytes (`Csv`), backslash (`Tsv`), or neither (`Plain`). Every later test is a bit
operation on those masks: quote placement, a CR that no LF follows, which delimiters and LFs belong to the text
rather than a quoted cell, and the bytes of a comment line. The block's separators are then read as counts for
`validate` or as positions for `walk`.

### The pass

`pass` reads `$EMIT`. With `$EMIT` false it is `validate`: `read_cells` counts each record's delimiters with
`count_ones` against the first record's width, so the work is per record, not per cell, and the instance holds no
position code and no keys. With `$EMIT` true it is `walk`: `read_tokens` lists the block's separators in order, and
each one ends a cell or a record.

`Pass` holds what carries from one block to the next: whether the last block ended inside a quoted field, right after
a separator, right after a closing quote, in a CR or in a backslash, the UTF-8 state, and the open record's first
byte, its open cell and its cell count.

- The bytes inside quoted fields are `prefix_xor` of the quote mask, XORed with whether the last block ended inside
  one. An opening quote is legal only at a cell's first byte, and a closing quote only before a quote that doubles it, a
  delimiter, a line end or the text's end. Both are mask tests.
- Under `Bare_Quote` a bare opening quote, the block's first fault, is dropped from the quote mask and the block's
  masks are made again, until the first fault is another or there is none. A quote at a cell's first byte still opens a
  quoted field, so a quoted cell is still one whose first byte is a quote.
- A text whose blocks have held no quote byte skips the quote work. `Pass.quoted` is set by the first block with a
  quote, and the walk uses the quoted path from then on. A per-block test of the block's own quotes would mispredict on
  text that quotes some cells and not others.
- A CR is judged with the byte after it. The CR in a block's last byte is the next block's to judge, and one the text
  ends on is a fault.
- UTF-8 is judged only in blocks that are not all ASCII, and in the first ASCII block after one, which settles a
  sequence the block before left open. Under `Invalid_Utf8` the error is found the same way and not reported.
- A fault cuts the masks at its byte, so no separator past it is read and no token past it is made.
- The last, partial block is loaded zero-padded. A zero is no separator, no quote and ASCII, and `valid` clears the
  lanes past the text.

### Records and keys

With a header, a record is a `Map` and each cell is a `Key` token, its column's header cell, then the cell as a `Plain`
value. Without a header a record is an `Array` of `Plain` values. A record's `End` spans its LF or CRLF. A last record
that the text does not end with an LF has an `End` of no bytes, and the text's `End` has no bytes. A line that is empty
or holds only a CR is no record.

- The header's cells are kept as tokens, one 16-byte `Token` per column, so a cell's key is an indexed load, not a
  second scan of the header. `header_cells` counts them before the pass. A caller may pass the walk a buffer of that
  many tokens (as `dsv.build` does, writing the header row before the walk), and otherwise `walk` allocates one from
  the default heap and frees it before returning.
- The delimiters before a block's next LF run in a loop of their own. That loop holds no LF test, no CR, no width and
  no `End`, and the kind of record is chosen once for the run, not per cell. A run proven to name one key per cell
  reads its keys without a bounds test (`put_key_n`).
- The record's last cell and its `End` are the outer loop's work, once per record.
- A record's state is held in locals for the block. `Pass` is one struct, and a field read per cell is a load per
  cell.
- A record wider than the first is found at the delimiter that opens the cell past the width. The walk gives its `Map`
  and its first `width` cells, then faults at that delimiter, and gives no `End`. `validate` reports the same byte,
  which it finds by rescanning that record on the fault path. A wide record is still refused under `Ragged`, which
  accepts a record narrower than the first, and with no header any width. A narrower record makes its `Map` and all its
  cells, then faults at its line end's first byte: the CR of a CRLF, else the LF, or the text's end.

### Tiers

On x86-64 the whole pass is built once per tier, `pass_v2`, `pass_v3` and `pass_v4`, each `#force_no_inline` with its
tier's features, and `run` switches on `kernel.tier()` once per walk. A block loop that calls kernels generic over
`$T` must be built per tier for the kernels to use the tier's instructions. Elsewhere there is a single pass,
`pass_base`.

### Cold readers

`text.odin` holds the readers the masks cannot replace, each reading one byte at a time and called only where a
block's masks show it is needed: the header's cell count, the first bad UTF-8 sequence of a block (searched from no
byte before the walk's first), the first backslash that opens no TSV escape, and the exact span of a cell too long to
measure by block. They are `@(cold)` and `#force_no_inline`, so the pass saves no registers for them.

## The two walks compared

| | JSON | dsv |
|---|---|---|
| Shape | a state per grammar position, tail calls | one loop over blocks |
| Reads | token by token, a leaf per kind | 64 bytes at a time, masks |
| Tiers | states at the floor, string block reader per tier | the whole pass per tier |
| Skip | `pass_over`, the walk with no hook | the record's tokens are muted, its bytes still judged |
| Scratch | the depth stack, on the walk's stack | the header keys, the caller's buffer or the default heap |
| `validate` | the walk with `no_hook`, then only whitespace | the pass with `$EMIT` false |

The two walks differ inside because the grammars differ. A JSON token's kind is known from its first byte and most
tokens are short, so a branch per token is cheaper than a mask per block. A delimited text's tokens are found only by
separators and quotes that can sit anywhere in a block, so the masks answer every question at once. Both give the
caller the same tokens.

## Verifying a change

From `next/`:

| Command | What it runs |
|---|---|
| `make test` | the tests at -o:minimal and -o:speed |
| `make test-x86` | the tests at v2 and v3 under Rosetta, `-define:WALK_TIER` picking the walks' tier |
| `make test-asan` | the tests under AddressSanitizer |
| `make test-oracle` | each walk against the current tree's `json` and `csv` on seeded texts and their mutations, each JSON spec against the dialect of its name, with the JSON5 differences the oracle names, the edit lists against a value tree, and an edit per round against the current tree's `set`, `insert` and `remove` |
| `make lint` | vet on the host, x86-64 and riscv64 |

The tests check every fault that names a byte at that byte and at every offset in a block, every prefix of generated
texts with the bytes after it poisoned, `Skip` and `Stop` at random against the full walk's tokens, a hook that keeps
its state behind `h` against one that keeps it in `Hook_Regs`, each comment's role, JSON against JSONTestSuite and
JSON5 against json5-tests. `No_Memory` names no byte, so its test pins its rule and its rendering.
