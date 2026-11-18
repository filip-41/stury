# The walks

A walk reads one text from a byte offset and passes every token to a hook in the order it reads them, until the text
ends, a fault stops it, or the hook returns `.Stop`. Every format has a walk, and every walk gives the same tokens
through the same hook, so a consumer written against `core` reads any format. `validate` is the same walk with no hook.

This page covers what the walks share and how the JSON, delimited-text (dsv), TOML and YAML walks are built.
`kernel.md` covers the vector code and the tiers, `markup.md` the XML walk and the HTML tokenizer and tree, and
`binary.md` the CBOR walk.

## The interface

Each format package exposes `Spec`, `Options`, `Detail`, `RULES`, `walk`, `validate` and `build`, its token decoders
`token_text` and `token_number` beside core's node readers `text` and `number`, and the token spelling detail its walk
documents (`json.Number_Spelling`). What a format author uses is in `core`: `Kind`, `Role`, `Token`, `Action` and
`Hook_Regs` for a hook, `Fault`, `Fault_Kind` and `Rules` for a result, `fault_at` and `result_of` for the result word,
`No_Hooks` and `no_hook` for a walk without hooks, `text_start` for the byte-order mark, and `Tolerance`. A caller of
`build` and the readers names none of them.

```odin
Spec     :: enum u8 { ... }    // the grammar, at compile time
Options  :: struct { ... }     // what a walk receives at run time
Detail   :: enum u8 { None, ... }   // the format's own rules, in `Fault.detail`
RULES    : core.Rules             // each rule's code and message, in rodata
walk     :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor = nil) -> (hi: u64, fault: Maybe(core.Fault))
validate :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> core.Error
build    :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error)
```

`cursor` is the format's own `Cursor`, described under Stop and resume. dsv's `walk` is a procedure group of a walk
with and a walk without it, so a walk with no cursor links no saving code.

`opts` defaults to `Options{}` and `regs` may be nil, in which case the walk starts from zero registers and keeps
none. A call that skips `opts` passes the later parameters by name:

```odin
h: core.No_Hooks
at: u64
for at < u64(len(src)) {
	next, fault := json.walk(src, at, .Json, h = &h, regs = nil, on = core.no_hook)
	if fault != nil || next == at {
		break
	}
	at = next
}
```

That loop reads an NDJSON stream: each walk returns one past the document it read, so the next starts there. A
`regs` the caller keeps returns the hook's registers from one walk to the next.

- `Spec` is a compile-time parameter. Each spec is a separate instance of the walk, so a build carries the code of the
  specs it names and no other. Odin refuses a struct as a `$` parameter, so run-time settings, such as whether a CSV
  text has a header, go in `Options`. JSON's specs are `Json` (RFC 8259), `Jsonc` and `Json5` (JSON5 1.0.0). Each spec
  reads its own grammar whole and refuses the rest, unless `Options.tolerate` names a rule it may break.
- A walk from byte 0 skips a UTF-8 byte order mark through `core.text_start`, as `validate` does. Outside a string, a
  BOM at any later byte is `Bad_Char` in JSON and JSONC, whitespace in JSON5, and a cell byte in dsv. Inside a JSON
  string it is the character U+FEFF.
- `hi` is one past the last byte read, or the fault's byte. When a hook stops the walk, `hi` is one past the token it
  stopped on and there is no fault. The walk has read no further, so `hi` is not a document boundary.
- A walk reads one document, and `validate` judges a text that holds one. No format takes a framing option: the
  document's own bytes say where it ends. Before its document, a JSON walk skips whitespace, the record separator
  0x1E, and in a spec with comments the comments. When nothing but those remain before the text's end or a 0x1E, it
  emits no token and returns the text's end with no fault. A stream of documents (NDJSON, RFC 7464, jq's input) is
  therefore a loop of walks, each starting where the last ended. A dsv text is one table, so its walk reads to the
  text's end.
- The walks are contextless, so a hook can call a walk. A walk that needs scratch sets the default context there,
  allocates from the default heap and frees it before it returns, and a walk that allocates nothing sets no context.
  `validate` allocates nothing unless `max_depth` is past `core.MAX_DEPTH`, which is public because a caller sizes a
  stack for the walk's tokens from it.

### The document

`build` runs the walk with one of the builder hooks and returns one `core.Document`, or a `core.Error`: a
`Document_Error` from the document's rules or a `Fault` from the text. The document holds the tokens as 16-byte
`core.Node`s in preorder, the facts beside them, and the format's `core.Readers` table, which is in rodata and lets a
reader decode a string or number without a second walk. `document.md` describes the node, the readers, the duplicate-key
rule, facts, the edit list and its commit, and the value layer's errors.

Two things here are the walk's. The walk gives an `End` token for every container and a `Plain` token of a comment
role for every comment, and the builder consumes the `End` and stores the comment as a fact. An edit's text is judged
by the same walk: a recorded value, key or record is read by the format's `walk` with the document's spec and, for a
delimited text, its `delimiter` and `comment` byte, so it reads as its document does.

### Tokens

```odin
Token :: struct { lo: u64, n: u32, kind: Kind, role: Role, spelling: u16 }
```

A token is 16 bytes and crosses a call in two registers. `lo` and `n` are its span in the text. Tokens come in the
order the walk reads them, which is text order except for a dsv `Key`, whose span is its column's header cell, before
the record that names it. `kind` says what the token is: a scalar (`Null`, `False`, `True`, `Number`, `Bytes`,
`String`, `Plain`), a container's opening (`Array`, `Object`), or its `End`. `role` is `Key` for a member's name and
for the header cell that names a dsv cell's column, and past `Key` a fact: a comment (`Comment`, `Comment_Inline`,
`Comment_Foot`), a node property (`Tag`, `Anchor`, `Alias`, which stands just before its node), an `Instruction`, a
`Doctype` or `Directive`, or an `Attribute`, which a markup walk gives after the element's key and before its value. A
consumer that wants values only tests `role <= .Key`, and `role <= .Comment_Foot` is a comment.

`spelling` is a detail the format writes and core reads through three bits: bit 0 says `text` must be decoded, bit 1
says the token is quoted (a JSON string's span leaves its quotes out, a quoted dsv cell's holds them), and bit 2 says
the decode may grow past the span (a tolerated ill-formed UTF-8 sequence). Bits 0 and 2 together,
`SPELLING_SYNTHETIC`, mark a key or text no span of the source spells, as a markup element's `#text` key. The other
bits are the format's own. A token longer than `n` can hold is the fault `Too_Wide`.

### Hooks

A hook is `on(h, regs, token) -> (regs, action)`. `$on` is a compile-time parameter, so the walk is instantiated per
hook and the call inlines: a hook that tests a token's kind and returns folds into the walk, and a hook that does
nothing compiles to no code. `validate` is the walk with such a hook.

`Hook_Regs` is three words passed in the walk's argument registers from token to token. A cursor or count kept there
needs no load or store per token. Anything larger stays behind `h`.

The `Action` a hook returns:

- `Next` continues the walk.
- `Skip` on an `Array` or `Object` passes the container with no more tokens, its `End` included, and on a `Key` passes
  the comments before the member's value and the value. The walk still judges the bytes it passes. On a scalar it acts
  as `Next`.
- `Keep` on an `Array` or `Object` is `Next`, and says every token up to its `End` is to be written as it comes, which
  a walk may do by the builder's plain hook.
- `Stop` ends the walk at once, with no fault and the rest of the text unjudged.

Two fields of a hook's state change what the walk does, and the walk finds them by name, so a hook without them holds
none of this code:

- `expect`: `Hook_Regs.b` points at a `core.Expected_Key`. Before scanning a key the walk compares the key's first 16
  bytes as written, open quote through colon, with the record's `word` under its `mask`, then `rest`. A match moves `b`
  by one record, gives no `Key` token, and goes to the value. A miss gives the token as usual. Each record pays one
  compare, so `expect` suits a reader whose keys arrive in a known order. A one-path scan does not use it: nearly every
  key it meets is a miss, on which the compare is work the key scan does anyway.
- `mant`: the walk folds the digits of a number's integer and fraction runs into it as it reads them, so a hook reads
  a short number with no second pass over the digits. It wraps past 19 digits, which the token's `spelling` says.

### The result word

Inside a walk the result is a `u64`: a position in bits 16 and up, a `Detail` in bits 8 to 15, and a `Fault_Kind` in
bits 0 to 7, 0 for none. The `walk` procedure turns it into `(hi, fault)` at the end. The word returns in one
register through every state and pass, where a `(u64, Maybe(Fault))` would return through memory. A detail of
`STOPPED` with no fault says a hook stopped the walk.

### Faults

```odin
Fault :: struct { at: u64, rules: ^Rules, kind: Fault_Kind, detail: u8 }
```

`kind` is the same for every format. `detail` is the format's rule within that kind, numbered by each format
independently, 0 for none. `at` is the byte the kind names. A count or limit is not written into it. A kind in
`AT_NO_BYTE`, such as `No_Memory`, names no byte and its `at` is not read.

`rules` points to the format's `RULES` in rodata, which holds a code and a message per detail. Core names a fault
(`write_code`: `json.literal`, `dsv.too_many_fields`, or the kind's code, `json.bad_char`) and renders it (`render`:
`line:col: message`) from that table without calling into the format, so a format outside stury can add its own table
and render the same way. A code is stable across releases and a message may change. Each detail is chosen where the
walk faults, in a cold state or after the walk returns, so the states that read valid text compile none of it.

A dsv record of another width than the first is `Bad_Width`, with `too_many_fields` (at the delimiter that starts the
extra cell) or `too_few_fields` (at the record's line end). `locate` returns a byte's line and column, both counted
from 1, with the column in bytes. It continues from the position a `Lines` count reached, so faults met in offset order
scan each byte once.

### Tolerances

`Options.tolerate` is a `bit_set` of `core.Tolerance`, the rules a caller allows a text to break, one enum for every
format. A rule in the set has one fixed reading, and a rule outside it faults. A rule that a format's grammar has no
instance of is never broken there, so naming it changes nothing and one set can be given to every format. No tolerance
is set by default, and a tolerated fault produces no warning.

| Tolerance | Format | Reading |
|---|---|---|
| `Invalid_Utf8` | json (in a string), dsv (in a cell) | each maximal subpart of an ill-formed sequence is U+FFFD |
| `Lone_Surrogate` | json (in a string) | a `\u` escape of a surrogate half no other half pairs with is U+FFFD |
| `Ragged` | dsv | a record of any width: a narrower one has its missing columns absent, and with a header a wider one's cells past the header's last are columns named by their 1-based position (`"3"`) |
| `Bare_Quote` | dsv (CSV) | a quote inside an unquoted cell is a byte of the cell |
| `Unread_Entity` | xml | a reference to an external or undeclared entity reads as its own text, `&name;` |

- A tolerance changes no structure. A token keeps its bytes, and the difference appears in the value it decodes to.
- A tolerated fault is found at the same byte as in a strict walk, on the branch that handles the fault, so clean text
  runs no tolerance code.
- No tolerance covers a number's grammar, text after a closing quote, anything structural, or ill-formed UTF-8 outside a
  string or a cell. A sequence cut short by the end of a string or quoted field that the text also cuts short is
  `Truncated`.

### Stop and resume

A hook that returns `.Stop` ends the walk at the token it stopped on. A caller that passes a `cursor` can continue from
there with the format's `walk_resume(src, &cursor, ...)`, over the same text, and `can_resume` says whether the cursor
holds a stop. A resume on a cursor that holds none, or one a walk of another text filled, is `.Bad_Option`. Each format
keeps what it needs:

- **JSON:** the caller's depth stack (`Cursor.stack`, one byte a level, which also bounds the nesting), the position,
  the registers and the state that follows. Any token may be the stop.
- **dsv:** the first byte of the next record, the first record's width, the hook's registers and the caller's storage
  for the header's cells (`Cursor.keys`). Only a record's `End` is a stop, a stop on any other token ends the walk, and
  a header with more cells than `keys` holds is `.No_Memory`.
- **TOML, YAML, XML, CBOR:** the table tree or the parser's state, and the place the replay or walk stopped at, on the
  default heap, or in `core.Token_Cursor` for a format that reads on to a place where its state is whole and holds the
  tokens it passes on the way. A cursor resumes after any token. A walk that ends or faults frees what its cursor
  holds, and `cursor_destroy` frees a cursor that no resume ended.

## For format authors

A format is a package of this repository that supplies a grammar and its spelling. Everything a caller calls after `build`
lives in `core`, so a format adds no reader, no `query` and no `commit` of its own, only what follows.

1. **The walk.** `Spec`, `Options`, `Detail`, `RULES`, `walk` and `validate`, with the signatures above.
2. **The build.** `build` runs a count walk over `build.builder_hook_count`, reserves with `build.builder_start`, walks
   again with `build.builder_hook` and finishes the document. It is a thin entry that instantiates the walk for a spec.
3. **The readers and services.** A `core.Readers` table in rodata, stored in the document, carries the leaves that
   need the grammar (`text`, `key_equals`, `number`, `resolve`, `close_end` and the slots a format needs past JSON's).
   The package keeps `HANDLES := [Spec]core.Readers{...}` and `SERVICES := [Spec]core.Services{...}`, the two mutable
   globals `tools/checks.py` allows a format, for the handle `as` returns. The entry points bind tables with no
   services, json's and dsv's for a constant spec and the other formats' for the spec passed, so a program links only
   the passes it names. `Services.edit` points at one `core.Edit_Services` table, nil for a format with no edits. Each
   format's `names.odin`, which `make names-write` generates from `tools/names.txt`, exports the names of `core` a user
   of the format calls, so that user never imports `core`.
4. **The paths.** `set` and the path walk instantiate `build.Scan` over the format's `walk`. See `paths.md`.
5. **The edits.** `compose.commit` is the format package's `commit`. A format whose root has no brackets sets `flat`
   and supplies the services that place a member. A format whose containers are not one range of bytes (TOML, YAML,
   XML, HTML) supplies its own `Edit_Services.commit` and says what an edit may not touch. See `edits.md`.
6. **The typed read.** `unmarshal` runs the format's `walk` over `typed.Reader`'s hook. A format that reads its values
   as JSON does needs no more. A format with its own value reader, as dsv has for a cell, stores through the `store_*`
   procedures in `core` and reads the target's field by `field_at` and `Plan.node_read`. See `typed.md`.

A format with its own number grammar calls the decoders of `core/spell`, such as `number_loose`.

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
| `ind` | the predicted indent: the last line's indent and the byte it is made of in the low half, the step per level in the high half |
| `w` | `^Walk`, what the states share beyond their registers |
| `s0`, `s1`, `s2` | the hook's `Hook_Regs` |
| `$on` | the hook, at compile time |

A tail call passes the same registers it received, so a move between states is a jump.

- The state is held in registers, not in a struct. A field of `w` that changed per token would cost a load and a store
  per token, so `w` holds what changes rarely: the text's base, the hook's state, the depth stack and the tier.
- `d` carries the container's kind. Whether a close bracket is `]` or `}` and whether the next member starts with a
  key are bit tests on a register.
- The depth stack holds only what no register holds. An open bracket writes the kind of the container it leaves into
  that depth's slot, and a close reads it back into `d`. The stack is `MAX_DEPTH` bytes on the walk's stack and stays
  unwritten (`= ---`), and no slot is read before it is written. An open compares the depth with `w.depth`, the levels
  every stack holds, and past it the cold state `st_deepen` faults `.Too_Deep` at `w.limit` or doubles `w.depth` toward
  it: the byte stack moves to the default heap, and the hook's stacks grow with it. A walk frees a stack it grew
  before it returns.
- Every state is `#force_no_inline` and has the calling convention `"preserve/none"`, so a state keeps no register
  across a call. Inlining one state into another would make a single procedure that saves the union of their registers
  on entry, and separate states save only their own.
- A frame that is no state enters one through `enter`. Under `-sanitize:address` a realigned frame keeps a base pointer
  that a `preserve/none` call clobbers, so there the call goes through a frame of its own.

### States and leaves

A state chooses and a leaf reads. The leaves (`number`, `literal`, the string readers, `skip_ws`, `colon`) are
`#force_inline`, take a cursor and `end`, and return one past the token or a fault kind. A leaf that needs a call, or
builds a vector on entry, makes every state that inlines it save the call's registers, so rare work goes to a state
of its own: whitespace after a token (`st_open_ws`, `st_after_ws`, `st_member_ws`), a string that holds an escape
(`st_string_escaped`), a bad literal, a skipped value (`st_skip`, `st_skip_member`), and in JSONC and JSON5 a byte that
starts no JSON value or key (`st_value_spec`, `st_key_spec`). The states every document passes through keep their size.

Two states that differ only by a constant, such as `st_string` and `st_key_string` or `st_after` and
`st_after_number`, are written out as two procedures. `#must_tail` requires the caller and the callee to have the same
procedure type, and a compile-time parameter of the state's own makes a different type. The jumps between such states
would then be plain returns, which `-o:speed` still compiles as jumps but `-sanitize:address` compiles as calls, so a
deep text overflows the stack.

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

A JSON5 single-quoted string goes to `string_short` and `string_lean` with `'` as its quote, then to `string_long`.

### Tiers

The states are built for one tier per target, its floor (`STATE_TIER`: v2 on x86-64, the only tier elsewhere), with
`@(enable_target_feature = STATE_FEATURES)`. `#must_tail` cannot jump between procedures built with different
features, and three copies of every state would triple the code in the instruction cache. Only the block string
reader differs by tier: `string_long` switches on `w.tier`, read once per walk from `kernel.tier()`, to a
`string_span_v2`, `_v3` or `_v4`, built as `kernel.md` describes.

### Whitespace and indentation

Compact text has no whitespace between tokens, and each state first tests that the next byte starts a token.
Pretty-printed text puts a newline and an indent between most tokens. `indent_fast` predicts the indent: one step
deeper after an open bracket, the same after a comma, one step out before a close, made of the byte the last counted
indent began with, a space or a tab. It checks the predicted run with one masked compare of up to 32 bytes and reads
the token after it without a loop. `skip_indent`, in the states for whitespace, counts a run the prediction missed and
records the indent and its byte. A single space before the next token, as some compact printers write after a comma,
is handled in `indent_fast` too, after the newline test, so neither compact nor indented text runs extra code for it.

`st_key` reads the colon after a key on a fast path (`colon_fast`) when the colon is flush against its value or
followed by one space, with or without one space before it. `st_colon` handles every other spelling.

### Runs

A run of open brackets is pushed in `st_open_run`, and a run of close brackets is popped in `st_close`. A number
continues in `st_after_number`, which is `st_after` with two more ways out: in an array, a loop over number elements
(`st_number_run`), and in an object, a loop over members with a short key, a fast-path colon and a number value
(`st_member_run`). Either run passes anything else to the states that read it, so the states every document passes
through hold none of the runs' code.

When a number run ends at a close followed by `,[`, a walk whose hook takes every number and bracket with `Next`
(`validate`, a skipping path scan, the document build and its count) enters `st_number_blocks`. It judges the text 64
bytes at a time from masks of digits, `-`, `.`, `,`, `[`, `]` and `0`, and passes the block's tokens to the hook up to
its last comma. At the first block it cannot judge, the walk goes on in `st_after` from that comma with the depth
there, so that block is read again by the states and faults where they fault.

### Skip

`pass_over` reads a skipped value: it is the same states instantiated with no hook, entered by a call, because
`#must_tail` cannot jump between two instances of the walk. It reads the value as a document's root whose depth stack
starts at the slot of the depth the value closes back to, with the depth limit lowered by as much, so its depths and
faults are those the walk with the hook would meet. The walk with the hook continues in `st_after`. `Skip` on a `Key`
stays in the walk with the hook for a value it can read inline, a number or a string after a fast-path colon, so a
skip of every member of an object makes no call per member.

### Comments

A spec adds to RFC 8259 through `FEATURES`, which the states test with `when`. A feature's code is placed only where a
state already refuses a byte or leaves its fast path. In `Json` every `when` is false, and its instance holds no code
of the other specs.

A `/` in one of those places passes to a comment state, which reads the whole run of whitespace and
comments up to the next token before passing any of it to the hook, because what follows the run decides each
comment's role. The rule is `core.Role`'s and is the same in every format:

- a comment on the line where the value before it ends is that value's `Comment_Inline`,
- else, before a value, that value's `Comment`,
- else the `Comment_Foot` of the innermost open container, or of the root at depth 0. A markup element with no child
  element gives its comments as `Comment_Foot` between its key and its value, and they are the value's.

A foot is written after the container's last value and before the container's `End`. After a document's root,
comments past the root's line are its foot when the text ends after them or a 0x1E follows them, and otherwise belong to
the next document, with the walk ending before them. A walk without hooks reads every run and emits nothing.

A comment's bytes are judged as a string's raw bytes are: UTF-8, no control byte except a tab, and in a `/* */`
comment also CR and LF. JSON5 keeps this rule, tighter than its grammar, which allows any control byte. A `//` comment
ends at CR or LF, and in JSON5 also at U+2028 or U+2029. A `/` that opens no comment faults as any other byte there
would, and a `/*` that the text ends inside is `Truncated`. Every spec with comments also accepts a comma before a
close bracket.

A comment's body is stepped 16 bytes at a time to the first byte the reader must judge individually. Whitespace
between comments is read one byte at a time, because a run there is short and a 64-byte vector load covers more bytes
than the run. A state that has already read the whitespace before a run's first comment passes that comment's position
in `Walk.resume`, so the run is not scanned twice.

### JSON5

`Json5` adds `.Es5` to JSONC's features: JSON5 1.0.0's numbers, strings, unquoted keys and whitespace. A token that
JSON spells the same way is read by JSON's own leaf. A state passes to JSON5's readers only where that leaf refuses
or no JSON construct starts: a value on `'`, `+`, `.`, `I` or `N`, a key that is a single-quoted string or an
ECMAScript 5.1 IdentifierName (else `Bad_Char` with `Identifier`), a string `string_long` refuses, which `string_exact`
reads again by JSON5's rules, and every place a comment may start, since JSON5's other whitespace opens a run as a `/`
does.

A number's `spelling` is the packed `Number_Spelling` in bits 0 to 3, the integer digit count, the fraction count,
`NUMBER_EXP` and `NUMBER_POINT` for a point with no digit after it (`5.`). Every kind value is even, so a number does
not set core's decode bit 0. Where the grammar leaves a choice, a `\u` escape keeps JSON's rule, so a lone surrogate
half is `Bad_Escape` at its backslash. An identifier accepts the letters of Nl, as ECMAScript 5.1 does, and a `\u`
escape in it must write a character the identifier may contain there.

## The dsv walk

The dsv walk is a loop over 64-byte blocks. `Spec` is the quoting grammar at compile time (`Csv`
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
each one ends a cell or a record. `Pass` holds what carries from one block to the next: whether the last block ended
inside a quoted field, right after a separator, a closing quote, a CR or a backslash, the UTF-8 state, and the open
record's first byte, open cell and cell count.

- The bytes inside quoted fields are `prefix_xor` of the quote mask, XORed with whether the last block ended inside
  one. An opening quote is legal only at a cell's first byte, and a closing quote only before a quote that doubles it, a
  delimiter, a line end or the text's end. Both are mask tests.
- Under `Bare_Quote` a bare opening quote, the block's first fault, is dropped from the quote mask and the block's
  masks are made again, until the first fault is another or there is none.
- A text whose blocks have held no quote byte skips the quote work. `Pass.quoted` is set by the first block with a
  quote, and the walk uses the quoted path from then on. A per-block test of the block's own quotes would mispredict on
  text that quotes some cells and not others.
- A CR is judged with the byte after it. The CR in a block's last byte is the next block's to judge, and one the text
  ends on is a fault.
- UTF-8 is judged only in blocks that are not all ASCII, and in the first ASCII block after one, which settles a
  sequence the block before left open. Under `Invalid_Utf8` the cells that overlap a block whose check failed are read
  byte by byte for the ill-formed sequence that marks them. A text with no ill-formed sequence reads no byte twice.
- A fault cuts the masks at its byte, so no separator past it is read and no token past it is made. The last, partial
  block is loaded zero-padded: a zero is no separator, no quote and ASCII, and `valid` clears the lanes past the text.
- A TSV block's escapes are judged in masks (`kernel.escaped` and one class mask of `t`, `n`, `r`, `0` and `\`), so a
  block with no bad escape runs no byte loop.
- On x86-64 the whole pass is built once per tier, `pass_v2`, `pass_v3` and `pass_v4`, and `run` switches on
  `kernel.tier()` once per walk, as `kernel.md` describes. A build with the default `Options` takes a second instance
  of each, so the option tests fold. Elsewhere there is a single pass, `pass_base`.
- The cold readers, which the masks cannot replace, read one byte at a time and are called only where a block's masks
  show it is needed. They are `@(cold)` and `#force_no_inline`, so the pass saves no registers for them.

### Records and keys

With a header, a record is an `Object` and each cell is a `Key` token, its column's header cell, then the cell as a `Plain`
value. Without a header a record is an `Array` of `Plain` values. A record's `End` spans its LF or CRLF. A last record
that the text does not end with an LF has an `End` of no bytes, and the text's `End` has no bytes. A line that is empty
or holds only a CR is no record.

- The header's cells are kept as tokens, one 16-byte `Token` per column, so a cell's key is an indexed load, not a
  second scan of the header. A caller may pass the walk a buffer of that many tokens (as `dsv.build` does), and
  otherwise `walk` allocates one from the default heap and frees it before returning.
- The delimiters before a block's next LF run in a loop of their own, with no LF test, no CR, no width and no `End`,
  and the kind of record is chosen once for the run, not per cell. The record's last cell and its `End` are the outer
  loop's work, once per record, and a record's state is held in locals for the block.
- A record wider than the first is found at the delimiter that opens the cell past the width. The walk gives its `Object`
  and its first `width` cells, then faults at that delimiter, and gives no `End`. `validate` reports the same byte,
  which it finds by rescanning that record on the fault path. A narrower record makes its `Object` and all its cells, then
  faults at its line end's first byte: the CR of a CRLF, else the LF, or the text's end.
- Under `Ragged` no width faults. A headed record's cells past the header's last are read on a cold path, each after a
  `Key` with no bytes of its own, `lo` the header's first byte, `n` the column's 1-based position, and the spelling bit
  `SPELLING_COLUMN`, which `text` and `key_equals` spell as that position in decimal. A header cell of the same name
  repeats it and meets the duplicate policy.

## The TOML walk

TOML names a member where it is written, and a table's members may be written apart: `[a.b]` can come before `[a]`,
and an array of tables takes a section each. The tokens of a document are in tree order, so the walk reads the whole
text first and replays it. `validate` stops after the tree, and makes no tokens. A scan of one path under `stop_early`
parses a statement at a time instead: the replay asks for the next statement when a container has given its members and
a later statement could still add to it, so the read ends at the statement that completes its answer.

The parser reads statements into a table tree on the default heap. A node is a table, an array or a scalar, with its
key token, its value token, its children as a list, and the comments that belong to it. A table finds a member by the
key's decoded text along its list, and through an index once it holds more members than the list serves. A dotted key
continues only tables dotted keys made, a header continues any table but an inline one, a header ends in a table only
other headers' paths made, and `[[a]]` ends in an array only `[[a]]` made.

Arrays and inline tables are read with an explicit stack of the open containers, so the depth a text nests costs heap,
not call stack, and `Options.max_depth` bounds it. Tables a header names count as nested.

A comment is placed as it is read. One on the line where a value ended is that node's inline comment, any other waits
for the next node and becomes its head, and one before a closing bracket, or at the text's end, is the container's
foot. A header's inline comment follows the table's `End`, since the table ends after its sub-tables.

`replay` walks the tree and gives each node's tokens in the order of the other walks: its head comments, its `Key`, its
value (a container's children, foot comments and `End`) and its inline comment. A `Skip` on a key passes its value, and
one on a container its children.

A string or key token's span holds its quotes. A datetime is a `String` with bit 0 clear and its type in the spelling,
which the `Tag` fact names. A number carries its form in its spelling (`toml.Number_Spelling`: a JSON number, a decimal
with a plus sign or underscores, hex, octal, binary, `inf`, `nan`). An integer outside 64 bits is `Out_Of_Range` in both
versions, as the specification asks. TOML 1.1 adds the `\e` and `\xHH` escapes, a time with no seconds, and line ends,
comments and a trailing comma inside an inline table, and removes nothing, so a 1.0 text reads alike under both.

## The YAML walk

A YAML document is read by one pass that judges every byte and sends its tokens to the hook as it goes. The run reader
sorts a 64-byte block's bytes into classes once, and the readers find where a run ends from the block's masks; a byte
past ASCII or a control byte goes through `step`, which judges it. The parser predicts each line's indentation and
reads block collections, flow collections, the four scalar styles and block scalars, and a node's tag and anchor, which it
gives as `Tag` and `Anchor` facts just before the node's first token. A comment is held until the node it belongs to is
known, and then takes the role the position rule gives it.

A scalar is a `Plain` token: its type is what `resolve` reads from its text and its tag under the core schema, and a
scalar its tag does not hold (`!!int yes`) is the fault `Tag_Mismatch`.

An alias is not a token kind: the walk sends the `Alias` fact and then the tokens of the node its anchor names, read
back from a log of the anchored node's tokens, so a consumer sees the value. The bytes each alias reads again, its anchor's
node with the aliases in it, count toward `Options.alias_limit`, and an alias inside its own anchor's node is
`Alias_Cycle`. Each mapping's keys are tested for a repeat by decoded text, since a repeat is a fault of the text in
every read, and a `<<` member's tokens are held and the members its sources add are sent at the mapping's close.

A text is one document for `validate`, `build` and the path reads, and a second document there is `Extra_Document`.
The stream reader reads a stream's documents one after another for the record reader, which frames each document by the
walk and cuts a stream for threads before a `---` line or after a `...` line at column 0.

## The two walks compared

| | JSON | dsv |
|---|---|---|
| Shape | a state per grammar position, tail calls | one loop over blocks |
| Reads | token by token, a leaf per kind | 64 bytes at a time, masks |
| Tiers | states at the floor, string block reader per tier | the whole pass per tier |
| Skip | `pass_over`, the walk with no hook | the record's tokens are muted, its bytes still judged |
| Scratch | the depth stack, on the walk's stack | the header keys, the caller's buffer or the default heap |
| `validate` | the walk with `no_hook`, then only whitespace | the pass with `$EMIT` false |

A JSON token's kind is known from its first byte and most tokens are short, so a branch per token is cheaper than a mask
per block. A delimited text's tokens are found only by separators and quotes that can sit anywhere in a block, so the
masks answer every question at once.

## Verifying a change

From the repository root:

| Command | What it runs |
|---|---|
| `make test-lib` | the library suites at `-o:minimal` and `-o:speed`, and the golden answers `json/test` checks |
| `make test-x86` | the tests at v2 and v3 under Rosetta, `-define:TIER` picking the tier |
| `make test-wide` | every tier, under Intel SDE |
| `make test-asan` | the tests under AddressSanitizer |
| `make lint` | vet on the host, x86-64 and riscv64, and the import, entry and names checks |

The golden file under `json/test/golden` holds the answer for every JSONTestSuite and json5-tests file per spec: a pass
or a fault kind and byte, with a marker naming the reason where the answer was decided by design. The tests check every
fault that names a byte at that byte and at every offset in a block, every prefix of generated texts copied so the text
ends at a guard page, `Skip` and `Stop` at random against the full walk's tokens, a hook that keeps its state behind `h`
against one that keeps it in `Hook_Regs`, and each comment's role.
