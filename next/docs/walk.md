# The walks

A walk reads one text from a byte offset and hands every token it finds to a hook, in the order the walk reads them,
until the text ends, a fault stops it, or the hook does. Every format has one, and every format's walk gives the same
tokens through the same hook, so a consumer written against `core` reads any format. `validate` is the same walk with
no hook.

This document explains what the walks share, how the JSON walk and the delimited-text (dsv) walk are built, and why
they have that shape. Much of the shape answers what Odin and LLVM do with a hot loop. The reasons are here so that a
change does not undo one by accident. `kernel.md` covers the vector code both walks are built on.

## Files

| File | Holds |
|---|---|
| `core/walk.odin` | `Kind`, `Role`, `Token`, `Action`, `Hook_Regs`, `text_start` |
| `core/error.odin` | `Fault_Kind`, `Fault`, `Rules`, `Rule`, the codes, line and column, the renderer |
| `json/walk.odin` | JSON's interface, the result word, `Walk`, `walk_document`, the hook calls |
| `json/states.odin` | the grammar states, one procedure each, and the value classes |
| `json/strings.odin` | the string readers, from a two-load probe to a block reader per x86 tier |
| `json/scalars.odin` | numbers and literals |
| `json/whitespace.odin` | whitespace, the colon after a key, the indent predictor |
| `json/comments.odin` | comments: the reader, a run of them with JSON5's whitespace, and the states that give them roles |
| `json/json5.odin` | JSON5's numbers, strings, unquoted keys and whitespace, and the states that read them |
| `dsv/walk.odin` | dsv's interface, the dispatch to a pass per tier, the result word, the hook calls |
| `dsv/pass.odin` | the one pass over 64-byte blocks and its state between blocks |
| `dsv/records.odin` | what a block's separators end: cells and widths for `validate`, tokens for `walk` |
| `dsv/text.odin` | the byte-at-a-time readers the masks cannot replace |

## The interface

Each format package exposes six names of its walk and nothing else. The rest is `@(private)`.

```odin
Spec     :: enum u8 { ... }    // the grammar, at compile time
Options  :: struct { ... }     // what a walk takes at run time
Detail   :: enum u8 { None, ... }   // the format's own rules, in `Fault.detail`
RULES    : core.Rules             // each rule's code and message, in rodata
walk     :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault))
validate :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> Maybe(core.Fault)
```

A limit of the format's own grammar may be public beside them, as JSON's `MAX_DEPTH` is, since a caller sizing a stack
for the walk's tokens reads it.

- `Spec` is a compile-time parameter. Each spec is its own instance of the walk, so a build carries the code of the
  specs it names and no other. Odin refuses a struct as a `$` parameter, so what a spec needs at run time, such as
  whether a CSV text has a header, goes in `Options`. JSON's specs are `Json` (RFC 8259), `Jsonc` and `Json5` (JSON5 1.0.0). Each is strict
  to itself: a spec reads its own grammar whole and refuses the rest, unless `Options.tolerate` names a rule it may
  break (see Tolerances).
- `$S` has no default. A caller names the grammar it reads.
- A walk from byte 0 passes over one BOM, through `core.text_start`, as `validate` does. Outside a string, a BOM at
  any later byte is `Bad_Char` in JSON and JSONC, whitespace in JSON5, and a cell byte in dsv. Inside a JSON string it
  is the character U+FEFF.
- `hi` is one past the last byte read, or the fault's byte. When a hook stops the walk, `hi` is one past the token
  it stopped on and there is no fault. The walk has read no further, so `hi` is no document boundary.
- A walk reads one document, and `validate` judges a text that holds one. No format takes a framing option: where a
  document ends is the document's own business. A JSON walk passes over whitespace and the record separator 0x1E
  before its document, and in a spec with comments the comments, and in JSON5 its whitespace, with no document after them before the text's end or a 0x1E, so a
  stream of documents (NDJSON, RFC 7464, jq's input) is a loop of walks, each from where the last one ended. A JSON walk with nothing but those left, or from past the text's end, makes no token and
  returns the text's end with no fault. A dsv text is one table, so its walk reads to the text's end, and from past
  the end it reads an empty table.
- The walks are contextless, so a hook can call a walk. A walk that needs scratch takes it from the default heap
  and frees it before it returns. `validate` allocates nothing unless `max_depth` is past `MAX_DEPTH`.

### Tokens

```odin
Token :: struct { lo: u64, n: u32, kind: Kind, role: Role, spelling: u16 }
```

A token is 16 bytes, so it crosses a call in two registers. `lo` and `n` are its span in the text. Tokens come in the
order the walk reads them. That is text order except for a dsv `Key`, whose span is its column's header cell, before
the record the key names. `kind` says what it is: a scalar (`Null`, `False`, `True`, `Number`, `String`, `Plain`), a
container's opening (`Array`, `Map`), or its `End`. `role` is `Key` for a JSON member's name and for the header cell
that names a dsv cell's column, and past `Key` a fact: a comment, `Plain`, as `Comment`, `Comment_Inline` or
`Comment_Foot`. A consumer that wants values only tests `role <= .Key`. `spelling` is a detail only the format reads
back: a JSON string that holds an escape, a `/* */` comment, a CSV cell that is quoted. A token longer than `n` holds
is the fault `Too_Wide`, so a span is never cut.

### Hooks

A hook is `on(h, regs, token) -> (regs, action)`. `$on` is a compile-time parameter, so the walk is instantiated per
hook and the call inlines: a hook that tests a token's kind and returns folds into the walk, and a hook that asks for
nothing folds away to no code. That is how `validate` is the walk with no hook.

`Hook_Regs` is three words that ride the walk's argument registers from token to token. A cursor or a count kept there
costs no load or store per token. Anything larger stays behind `h`. Three is what fits beside a walk's own arguments in
the arm64 and x86-64 calling conventions.

The `Action` a hook returns:

- `Next` goes on.
- `Skip` on an `Array` or `Map` passes the container with no more tokens, its `End` included, and on a `Key` passes
  the comments before the member's value and the value. The walk still judges the bytes it passes. The comments after
  a skipped value are still given. On a scalar it is `Next`.
- `Stop` ends the walk at once, with no fault and the rest of the text unjudged.

### The result word

Inside a walk the result is one `u64`: a position in bits 16 and up, a `Detail` in bits 8 to 15, and a `Fault_Kind`
in bits 0 to 7, 0 for none. The `walk` procedure turns it into `(hi, fault)` at the end. A word returns in one register
through every state and pass, where a `(u64, Maybe(Fault))` would return through memory. A detail of `STOPPED` with no
fault says a hook stopped the walk. It shares its value with a member of `Detail`, which is safe because a detail is
read only beside a fault kind.

### Faults

```odin
Fault :: struct { at: u64, rules: ^Rules, kind: Fault_Kind, detail: u8 }
```

`kind` is the same for every format. `detail` is the format's own rule within it, numbered by each format on its own,
0 for none. `at` is the byte the kind names, and nothing else: a count or a limit is not written into it. A kind in
`AT_NO_BYTE`, such as `No_Memory`, names no byte, and its `at` says nothing.

`rules` points to the format's `RULES` in rodata, which holds per detail a stable code and a message. Core names a
fault (`write_code`: `json.literal`, `dsv.field_count`, or the kind's code, `json.bad_char`) and words it (`render`:
`line:col: message`) from that table, with no call into the format, so a format written outside stury adds its own
table and renders the same way. A code stays the same from release to release, and a message may change.

`locate` gives a byte's line and column, both from 1, counting bytes. It counts lines from where a `Lines` count left
off, so the faults of one text met in offset order cost one pass over it.

### Tolerances

`Options.tolerate` is a `bit_set` of the format's `Tolerance`, the rules a caller lets a text break. A rule in the set
is read one fixed way, and one outside it is a fault. None is taken by default, and a tolerated rule gives no warning.

| Tolerance | Format | Reading |
|---|---|---|
| `Invalid_Utf8` | json (in a string), dsv (in a cell) | each maximal subpart of an ill-formed sequence is U+FFFD |
| `Lone_Surrogate` | json (in a string) | a `\u` escape of a surrogate half no other half pairs with is U+FFFD |
| `Ragged` | dsv | a record with fewer cells than the first has its missing columns absent, with no header any width |
| `Bare_Quote` | dsv (CSV) | a quote inside an unquoted cell is a byte of the cell |

- A tolerance changes no structure and no token. A token keeps its bytes, and the value it decodes to is where the
  reading shows.
- A tolerated fault is found where the strict walk finds it, on the cold branch it faults from, so a clean text pays
  nothing for it.
- Some faults no tolerance takes: a number's grammar, text after a closing quote, anything structural, ill-formed
  UTF-8 outside a string or a cell (a JSON comment or identifier, between tokens), and a sequence cut short by the end
  of a string or quoted field that the text also cuts short (`Truncated`).

## The JSON walk

The JSON walk is a state machine. Each grammar state is a procedure, `st_value`, `st_key`, `st_after`, `st_close` and
the rest, that reads the first byte of the token it stands on, branches on it, reads the token with a leaf, hands it to
the hook, and hands over to the next state with `#must_tail`. No state returns until the walk ends.

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

A tail call passes them in the same registers it received them in, so moving from state to state costs a jump.

- The state lives in registers, not in a struct. A field of `w` that changes per token is a load and a store per
  token. `w` holds what changes rarely: the text's base, the hook's state, the depth stack, the tier, and where a string's
  first escape is.
- `d` carries the container's kind. Whether a close bracket is `]` or `}` and whether the next member starts with a
  key are bit tests on a register. `]` with bit 5 set is `}`, so `p[0] == ']' | (d & 1) << 5` tests the right one.
- The depth stack holds only what a register cannot. An open bracket writes the kind of the container it leaves
  into that depth's slot, and a close reads it back into `d`. The stack is `MAX_DEPTH` bytes on the walk's stack, left
  unwritten (`= ---` on an array, where a struct would be zeroed), and no slot is read before it is written. An
  `Options.max_depth` past `MAX_DEPTH` takes its stack from the default heap instead, in `walk_deep`, kept out of line
  so the walk's entry stays as it was. The limit an open compares with is `w.depth`.
- Every state is `#force_no_inline`. A state inlined into another makes one procedure that saves the union of their
  registers on entry. Kept apart, each state's entry is as cheap as its own work.

### States and leaves

A state chooses and a leaf reads. The leaves (`number`, `literal`, the string readers, `skip_ws`, `colon`) are
`#force_inline`, take a cursor and `end`, and return one past the token or a fault kind. A leaf that would need a
call, or a vector built on entry, makes every state that inlines it pay for that call's saved registers, so rare work
moves to a state of its own:

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

A string goes to the cheapest reader that can vouch for it, and falls through to the next when that reader cannot:

1. `string_short` loads 16 bytes twice. A value string that closes within 32 bytes of printable ASCII is read
   with no loop.
2. `string_probe`, for keys, reads up to 32 bytes one at a time, each a branch on a table. A key's length repeats
   from member to member, so its closing quote lands on a predicted branch, and the next state's address does not wait
   on a vector compare.
3. `string_lean` reads plain ASCII 64 bytes at a time with no UTF-8 state.
4. `string_escaped` reads on from the block of the first backslash, judging each block's escapes in masks with no
   branch per escape.
5. `string_long` reads blocks with UTF-8 validation, through one `string_span` per x86 tier.
6. `string_exact` reads byte by byte and gives the exact fault for what no block reader vouches for. It is where
   `Invalid_Utf8` and `Lone_Surrogate` take a fault, so the readers above them refuse what they would tolerate.

### Tiers

The states are built for one tier per target, its floor (`STATE_TIER`: v2 on x86-64, the one tier elsewhere), with
`@(enable_target_feature = STATE_FEATURES)`. `#must_tail` cannot jump between procedures built with different
features, and three copies of every state would triple the code that matters for the instruction cache. Only the block
string reader differs by tier: `string_long` switches on `w.tier`, read once per walk from `kernel.tier()`, to a
`string_span_v2`, `_v3` or `_v4` that is `#force_no_inline` with its tier's features, as `kernel.md` asks.

### Whitespace and indentation

Compact text has no whitespace between tokens, and each state first tests that the next byte is a token. Pretty-printed
text puts a newline and an indent between most tokens. `indent_fast` predicts the indent: one step deeper after an open
bracket, the same after a comma, one step out before a close. It checks the predicted run with one masked compare of up
to 32 bytes, `spaces_lead`, and takes the token after it with no loop. `skip_indent` counts a run the prediction missed
and learns from it: the indent after any newline, and the step after an open bracket. A single space before the next
token, as some compact printers write after a comma, is taken there too, after the newline test, so neither compact nor
indented text pays for it.

`st_key` takes the colon after a key on a fast path when it is flush against its value or followed by one space, with
or without one space before it, and `st_colon` takes every other spelling. A byte where the colon must stand is
`Bad_Char` with `Colon`.

### Runs

A run of open brackets is pushed in one state, `st_open_run`, and a run of close brackets popped in one, `st_close`.
`st_close` carries the depth apart from the kind bit, so the next close does not wait on the stack's load.

A number hands over to `st_after_number`, which is `st_after` with two more ways out. In an array, when the element
after the comma starts a number, the walk enters `st_number_run`, which reads number elements separated by a comma and
at most one space in one loop. In an object, the next member enters `st_member_run`, which reads members with a short
key, a colon in a fast-path spelling and a number value in one loop. Either run hands anything else to the states that
read it, so the states every document passes through hold none of the runs' code. `st_after_number` is kept apart from
`st_after` for the same reason, and holds the same separator rules.

### Skip

A skipped value is read by `pass_over`: the same states instantiated with no hook, entered by a call, since
`#must_tail` cannot jump between two instances of the walk. Before the call, the slot of the depth the skipped value
closes back to is marked with `PASS_END`. A close compares its byte with `]` and the slot's bits shifted in, and with
that bit no byte of a valid text matches, so `st_close`'s loop stops as it reads the slot and the walk without hooks
returns from `st_pass_end`. The walk with the hook clears the mark and goes on in `st_after`.

`st_skip_member` passes the comments around the colon itself, so the skipped value's first byte decides whether it is
pushed. A container read as a document's root would count its depth from 0.

### Comments

A spec adds to RFC 8259 through `FEATURES`, which the states test with `when`. A feature's code sits only where a state
already refuses a byte or leaves its fast path: `st_value` on a byte of class `Bad`, `st_key` on a byte that is no
quote, `st_colon` on a colon fault, and the separator states where a comment follows a value or its comma. In `Json`
every `when` is false, and its instance holds none of the other specs' code.

A `/` in one of those places hands over to a state in `comments.odin`, which reads the whole run of whitespace and
comments up to the next token before it gives any of it to the hook, since what follows the run decides each comment's
role. The rule is `core.Role`'s, the same for every format:

- a comment on the line where the value before it ends is that value's `Comment_Inline`,
- else, before a value, that value's `Comment`,
- else, before a close bracket, the `Comment_Foot` of the value before it, or of the container when it is empty.

A foot comes after its value's `End`, so an empty container's foot comes before its own `End`, which places it inside.

The state that reads a comment after a value is handed the value's end, so a separator state routes a comma followed by
a comment there rather than to the next member. After a document's root, comments past the root's line are its foot
when the text ends after them or a 0x1E follows them, else they are the next document's, and the walk ends before them.
A walk without hooks reads every run and gives nothing, and `validate` passes over the comments after its document as
it checks that only whitespace follows.

A comment's bytes are judged as a string's raw bytes are: UTF-8, and no control byte but a tab, and in a `/* */`
comment CR and LF. JSON5 takes any control byte, as its grammar does. A `//` comment ends at CR or LF, and in JSON5 at
U+2028 or U+2029 too. A `/` that opens no comment is `Bad_Char` at the `/`, and a `/*`
the text ends inside is `Truncated`. Every spec with comments also takes a comma before a close bracket: a close after
a run of comments is read with no look back at whether an open bracket or a comma came before the run.

A comment's body is stepped 16 bytes at a time, to the first byte the reader must judge one at a time: a control byte, a
byte past 0x7F, a `*` in a `/* */` comment, and a line end in a JSON5 `//` comment. Whitespace between comments stays
scalar: a run there is short, and a vector's lane to a cursor costs more than the bytes it steps over. A state that has
already read the whitespace before a run's first comment hands that comment's position over in `Walk.resume`, with
`Walk.crossed` for a comma read before it, so the run is not scanned twice.

### JSON5

`Json5` adds `.Es5` to JSONC's features: JSON5 1.0.0's numbers, strings, unquoted keys and whitespace (`json5.odin`). A
token JSON spells alike is read by JSON's own leaf. A state hands over to JSON5's readers only where that leaf refuses
or none of JSON's starts:

- `st_value` on `'`, `+`, `.`, `I` or `N`, and where JSON's number reader refuses or stops before an `x`, which the
  number runs test too,
- `st_key` on a byte that opens no JSON key: a single-quoted key, an ECMAScript 5.1 IdentifierName, or else `Bad_Char`
  with `Identifier`,
- `string_long`, where JSON's readers refuse a string: `string5` reads it again by JSON5's rules,
- every place a comment may start: JSON5's other whitespace (VT, FF, U+00A0, U+FEFF, U+2028, U+2029 and Zs) opens a
  run as a `/` does.

A number's `spelling` is a `Number_Spelling`: `Json` for JSON's grammar, else `Decimal`, `Hex`, `Infinity` or `Nan`. A
string's or key's is 1 when it holds an escape, as in JSON.

Where the grammar leaves a choice: a `\u` escape keeps JSON's rule, so a lone surrogate half is `Bad_Escape` at its
backslash. An identifier takes the letters of Nl, as ECMAScript 5.1 does, and a `\u` escape in it must write a
character the identifier may have there. A bad escape is refused at the byte that breaks it.

## The dsv walk

The dsv walk is one loop over 64-byte blocks (`dsv/pass.odin`). Each block is sorted into the masks of its delimiter,
LF, CR and quote bytes (tab, LF, CR and backslash for TSV) with one `pack_n`, and every later test is a bit operation on
those masks: quote placement, a CR that no LF follows, and which delimiters and LFs are the text's rather than a quoted
cell's. Then the block's separators are read, as counts for `validate` or as positions for `walk`.

### The pass

`pass` takes `$EMIT`. With `EMIT` false it is `validate`: `read_cells` counts each record's delimiters with
`count_ones` against the first record's width, so a block costs per record, not per cell, and the instance holds no
position code and no keys. With `EMIT` true it is `walk`: `read_tokens` lists the block's separators in order, and each
ends a cell or a record.

What carries from one block to the next lives in `Pass`: whether the last block ended inside a quoted field, right
after a separator, right after a closing quote, in a CR or in a backslash, the UTF-8 state, and the open record's first
byte, its open cell and its cell count.

- The bytes inside quoted fields are `prefix_xor` of the quote mask, XORed with whether the last block ended inside
  one. An opening quote is legal only at a cell's first byte, and a closing quote only before a quote that doubles it, a
  delimiter, a line end or the text's end. Both are mask tests.
- Under `Bare_Quote` a bare opening quote, the block's first fault, is dropped from the quote mask and the block's
  masks are made again, until the first fault is another or there is none. A quote at a cell's first byte still opens a
  quoted field, so a quoted cell is still one whose first byte is a quote.
- A text whose blocks have held no quote byte skips the quote work. `Pass.quoted` is set by the first block with a
  quote, and the text takes the quoted path from then on. A per-block test of the block's own quotes would mispredict on
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

- The header's cells are kept as tokens, one 16-byte `Token` per column, so a cell's key is one indexed load, not a
  second scan of the header. `header_cells` counts them before the pass so that the buffer is allocated once, from the
  default heap, and freed before `walk` returns.
- The delimiters before a block's next LF run in a loop of their own. It holds no LF test, no CR, no width and no
  `End`, and which kind of record it is in is chosen once for the run, not per cell. A run proven to name one key per
  cell reads its keys with no bounds test (`put_key_n`).
- The record's last cell and its `End` are the outer loop's work, once per record.
- A record's state lives in locals for the block. `Pass` is one struct, and a field read per cell is a load per cell.
- A record wider than the first is found at the delimiter that opens the cell past the width. The walk gives its `Map`
  and its first `width` cells, then faults at that delimiter, and gives no `End`. `validate` reports the same byte,
  which it finds by rescanning the one record on the fault path. A wide record is still refused under `Ragged`, which
  takes a record narrower than the first, and with no header any width. A narrower record makes its `Map` and all its
  cells, then faults at its line end's first byte: the CR of a CRLF, else the LF, or the text's end.

### Tiers

On x86-64 the whole pass is built once per tier, `pass_v2`, `pass_v3` and `pass_v4`, each `#force_no_inline` with its
tier's features, and `run` switches on `kernel.tier()` once per walk. A block loop that calls kernels generic over `$T`
has to be built per tier for the kernels to use the tier's instructions. Elsewhere there is one, `pass_base`.

### Cold readers

`text.odin` holds what the masks cannot answer, each read one byte at a time and run only where a block's masks have
said it is needed: the header's cell count, the first bad UTF-8 sequence of a block (searched from no byte before the
walk's first), the first backslash that opens no TSV escape, and the exact span of a cell too long to measure by block.
They are `@(cold)` and `#force_no_inline`, so the pass saves no registers for them.

## What the two walks share

| | JSON | dsv |
|---|---|---|
| Shape | a state per grammar position, tail calls | one loop over blocks |
| Reads | token by token, a leaf per kind | 64 bytes at a time, masks |
| Tiers | states at the floor, string block reader per tier | the whole pass per tier |
| Skip | `pass_over`, the walk with no hook | the record's tokens are muted, its bytes still judged |
| Scratch | the depth stack, on the walk's stack | the header keys, from the default heap |
| `validate` | the walk with `no_hook`, then only whitespace | the pass with `$EMIT` false |

The two walks differ underneath because the grammars differ. A JSON token's kind is known from its first byte, and most
tokens are short, so a branch per token beats a mask per block. A delimited text's tokens are found only by separators
and quotes that can sit anywhere in a block, so the masks answer every question at once. What they give a caller is the
same.

## Verifying a change

From `next/`:

| Command | What it runs |
|---|---|
| `make test` | the tests at -o:minimal and -o:speed |
| `make test-x86` | the tests at v2 and v3 under Rosetta, `-define:WALK_TIER` picking the walks' tier |
| `make test-asan` | the tests under AddressSanitizer |
| `make test-oracle` | each walk against the current tree's `json` and `csv` on seeded texts and their mutations, each JSON spec against the dialect of its name, with the JSON5 differences the oracle names |
| `make lint` | vet on the host, x86-64 and riscv64 |

The tests check every fault that names a byte at that byte and at every offset in a block, every prefix of generated
texts with the bytes after it poisoned, Skip and Stop at random against the full walk's tokens, a hook that keeps its
state behind `h` against one that keeps it in `Hook_Regs`, each comment's role, JSON against JSONTestSuite and JSON5
against json5-tests. `No_Memory` names no byte, so its test pins its rule and rendering instead.
