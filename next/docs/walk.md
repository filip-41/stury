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
| `core/document.odin` | `Node`, `Document`, the readers, `Duplicates`, `Spelling`, `Edit_Spelling`, `destroy` |
| `core/result.odin` | the result word: `fault_at`, `STOPPED`, `fault_of`, and the empty hook `No_Hooks`/`no_hook` |
| `core/build/build.odin` | `Builder`, the hooks a format's `build` passes its walk, the header row, the duplicate-key check |
| `core/spell/number.odin` | `Number`, `Number_Kind`, the decimal and hex decoders, the digit reader |
| `core/spell/text.odin` | `decode_text` and `bytes_equal` |
| `core/number.odin` | core's aliases for `Number`, `Number_Kind` and the two number bounds |
| `core/edit.odin` | `Edit_List`, `Edit`, `set`/`insert`/`remove`, `commit` |
| `core/compose/` | the commit the format tables point at, and the composition a format's root junctions share |
| `core/error.odin` | `Fault_Kind`, `Fault`, `Rules`, `Rule`, the codes, line and column, the renderer |
| `json/escape.odin` | the escape-byte table and the hex and surrogate helpers JSON's walk and decoder share |
| `json/walk.odin` | JSON's interface, the result word, `Walk`, `walk_document`, the hook calls |
| `json/document.odin` | JSON's `build` and its spelling table |
| `json/unescape.odin` | JSON's string decoder, its key compare and its number reader |
| `dsv/document.odin` | dsv's `build`, its spelling table and its header rule |
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
`json` also exposes `Tolerance`, `commit`, `text` and `number`, and `dsv` exposes `Tolerance`, `text` and `number`. `make surface` lists every public name.

`core`'s walk interface is what a format author uses: `Kind` and `Role` are a token's fields, `Token`, `Action` and
`Hook_Regs` are a hook's signature, `Fault`, `Fault_Kind` and `Rules` are a walk's result, `fault_at` and `fault_of`
make a fault, `STOPPED` is the result word's stopped detail, `No_Hooks` and `no_hook` make a walk without hooks, and
`text_start` skips a byte-order mark at byte 0. A caller of `build` and the readers does not name them: the document
and its readers are the caller's interface.

```odin
Spec     :: enum u8 { ... }    // the grammar, at compile time
Options  :: struct { ... }     // what a walk receives at run time
Detail   :: enum u8 { None, ... }   // the format's own rules, in `Fault.detail`
RULES    : core.Rules             // each rule's code and message, in rodata
walk     :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault))
validate :: proc "contextless" (src: []u8, spec: Spec, opts := Options{}) -> Maybe(core.Fault)
build    :: proc(src: []u8, spec: Spec, opts := Options{}, refuse_duplicates := false, allocator := context.allocator) -> (core.Document, core.Document_Error)
```

The walks share one signature, and dsv's `build` writes the header's cells into a private key buffer: `walk` allocates
one token per header cell for them and frees it before returning, while the build's buffer is read once and written
into the row it built.

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

`build` runs the value layer: it passes `walk` one of `core/build`'s builder hooks, `build.builder_hook` for a spec
with comments, and returns the document of nodes and facts, or a `Document_Error`. `Document_Error.at` is the byte the
error names, 0 for a kind that names none, and `inner` is the walk's fault for `.Walk`. The format's `document.odin` holds one `core.Spelling` table in rodata for all its readings,
and a reader uses it to decode a string or number without running a second walk.

`core.MAX_DEPTH` is public beside them, because a caller sizes a stack for the walk's tokens from it.

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
- The walks are contextless, so a hook can call a walk. A walk that needs scratch sets the default context there,
  allocates from the default heap, and frees it before it returns; a walk that allocates nothing sets no context.
  `validate` allocates nothing unless `max_depth` is past `MAX_DEPTH`.

### The document

`build` runs the walk and returns one `core.Document`, or a `core.Document_Error`: the walk's tokens as 16-byte
`core.Node`s in preorder, the facts beside them, and a `core.Spelling` table. `document.md` describes the node, the
document, the readers, the spelling services, the duplicate-key rule, a delimited text as a document, facts, the edit
list and its commit, and the value layer's errors.

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
the record that names it. `kind` says what the token is: a scalar (`Null`, `False`, `True`, `Number`, `String`,
`Plain`), a container's opening (`Array`, `Map`), or its `End`. `role` is `Key` for a JSON member's name and for the
header cell that names a dsv cell's column, and past `Key` a fact: a comment, `Plain`, as `Comment`, `Comment_Inline`
or `Comment_Foot`. A consumer that wants values only tests `role == .Value`. `spelling` is a detail the format writes
and core reads through three bits: bit 0 says `text` must be decoded, bit 1 says the token is quoted (a JSON string,
whose token span leaves its quotes out, or a quoted dsv cell, whose span holds them), and bit 2 says a JSON string
holds a tolerated ill-formed UTF-8 sequence. For a comment token, the low byte of `spelling` holds the lead marker's
length and the next byte the tail's. The other bits are the format's own. A token longer than `n` can hold is
the fault `Too_Wide`.

### Hooks

A hook is `on(h, regs, token) -> (regs, action)`. `$on` is a compile-time parameter, so the walk is instantiated per
hook and the call inlines: a hook that tests a token's kind and returns folds into the walk, and a hook that does
nothing compiles to no code. `validate` is the walk with such a hook.

`Hook_Regs` is three words passed in the walk's argument registers from token to token. A cursor or count kept there
needs no load or store per token. Anything larger stays behind `h`. On arm64 all three fit beside the walk's five
arguments in registers, while on x86-64 SysV two words spill to the stack under contextless calling.

The `Action` a hook returns:

- `Next` continues the walk.
- `Skip` on an `Array` or `Map` passes the container with no more tokens, its `End` included, and on a `Key` passes
  the comments before the member's value and the value. The walk still judges the bytes it passes. The comments after
  a skipped value are still given. On a scalar it acts as `Next`.
- `Keep` on an `Array` or `Map` is `Next`, and says every token up to its `End` is to be written as it comes, which
  a walk may do by the builder's plain hook.
- `Stop` ends the walk at once, with no fault and the rest of the text unjudged.

Two fields of a hook's state change what the walk does, and the walk finds them by name, so a hook without them holds
none of this code:

- `expect`: `Hook_Regs.b` points at a `core.Expected_Key`. Before scanning a key the walk compares the key's first 16
  bytes as written, open quote through colon, with the record's `word` under its `mask`, then `rest`. A match moves `b`
  by one record, gives no `Key` token, and goes to the value. A miss, and a key in the text's last 16 bytes, gives the token as usual.
  A record no key matches has a mask over an all-zero word. Each record pays one compare, so `expect` suits a reader
  whose keys arrive in a known order. A one-path scan does not use it: its `b` is the builder's, and nearly every key
  it meets is a miss, on which the compare is work the key scan does anyway.
- `mant`: the walk folds the digits of a number's integer and fraction runs into it as it reads them, so a hook reads
  a short number with no second pass over the digits. It wraps past 19 digits, which the token's `spelling` says.

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
(`write_code`: `json.literal`, `dsv.too_many_fields`, or the kind's code, `json.bad_char`) and renders it (`render`:
`line:col: message`) from that table without calling into the format, so a format outside stury can add its own table
and render the same way. A code is stable across releases and a message may change.

dsv names what is wrong within `Bad_Char` and `Truncated`: `too_many_fields` (a record wider than the first, at the
delimiter that starts its extra cell), `too_few_fields` (a narrower one, at its line end), `bare_quote`, `after_quote` (a
byte after a closing quote that is no quote, delimiter or line end), `lone_cr`, `bad_utf8` (at the lead byte), and for
`Truncated` `open_quote` (at the opening quote) and `cut_utf8`.

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
| `Ragged` | dsv | a record of any width: a narrower one has its missing columns absent, and with a header a wider one's cells past the header's last are columns named by their 1-based position (`"3"`) |
| `Bare_Quote` | dsv (CSV) | a quote inside an unquoted cell is a byte of the cell |

- A tolerance changes no structure. A token keeps its bytes, and the difference appears in the value it decodes to. A
  cell whose reading changes may set the decode bit.
- A tolerated fault is found at the same byte as in a strict walk, on the branch that handles the fault, so clean text
  runs no tolerance code.
- Some faults no tolerance covers: a number's grammar, text after a closing quote, anything structural, ill-formed
  UTF-8 outside a string or a cell (a JSON comment or identifier, between tokens), and a sequence cut short by the end
  of a string or quoted field that the text also cuts short (`Truncated`).

## For format authors

A format is a package under `next/` that supplies a grammar and its spelling. Everything a caller calls after `build`
lives in `core`, so a format adds no reader, no `query` and no `commit` of its own, only what follows.

1. **The walk.** `Spec`, `Options`, `Detail`, `RULES`, `walk` and `validate`, with the signatures in The interface. The
   walk emits `core.Token`s to a hook and returns a `core.Fault` through `core.fault_at` or `core.fault_of`.
2. **The build.** `build` runs a count walk over `build.builder_hook_count`, reserves with `build.builder_start`, walks
   again with `build.builder_hook` and finishes the document. It is a thin entry that instantiates the walk for a spec.
3. **The spelling.** One `core.Spelling` table in rodata, stored in the document, carries the services that need the
   grammar: `text`, `key_equals`, `number`, `resolve` and `close_end`, plus `tag_key`, `key_open` and `key_close`. `query`
   takes `build.query` unless the format routes paths itself. Set `edit` to one `core.Edit_Spelling` table.
4. **The paths.** `set` and the path walk instantiate `build.Scan` over the format's `walk`, and `Scan.rewalk` walks one
   value again for a ring's element. See `paths.md`.
5. **The edits.** `Edit_Spelling.commit` calls `compose.commit`. A format whose root has no brackets passes a
   `compose.Root_Spelling`, sets `flat` and supplies `interior`, `fact_slot`, `emptied` and `plan`.
6. **The typed read.** `unmarshal` runs the format's `walk` over `typed.Reader`'s hook. A format that reads its values
   as JSON does needs no more. A format with its own value reader, as dsv has for a cell, stores through `token_text`,
   `store_whole`, `store_cstring`, `store_enum`, `store_number`, `store_enum_value` and `map_slot`, and reads the
   target's field by `field_at` and `Plan.node_read`. `read_start` opens the read in either case.

`core/spell` holds the number decoders a format with its own number grammar calls: `POW10_F64`, `POW10_U64` and
`number_loose` are public for that.

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
  `indent_fast`, whose one masked vector compare replaces `skip_indent`'s loop.
- A string that holds an escape goes to `st_string_escaped`, which keeps the escape masks' registers to itself.
- A bad literal goes to `st_bad_literal`, so `st_value` saves nothing for its call.
- In JSON5 a byte that starts no JSON value goes to `st_value5`, and one that opens no JSON key to `st_key5`, with the
  comment run, the close after a trailing comma and the fault, so the states every document passes through keep their
  size.
- A skipped value goes to `st_skip` and `st_skip_member`.

Two states that differ only by a constant, such as `st_string` and `st_key_string` or `st_after` and
`st_after_number`, are written out as two procedures. `#must_tail` requires the caller and the callee to have the same
procedure type, and a compile-time parameter of the state's own makes a different type. The jumps between such states
would then be plain returns, which `-o:speed` still compiles as jumps but `-sanitize:address` compiles as calls, so a
deep text overflows the stack.

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
space, with or without one space before it. `colon_fast`, a leaf, finds that spelling, and `st_member_run` uses it
too. `st_colon` handles every other spelling. A byte where the colon must be is `Bad_Char` with `Colon`.

### Runs

A run of open brackets is pushed in `st_open_run`, and a run of close brackets is popped in `st_close`. `st_close`
keeps the depth apart from the kind bit, so the next close does not wait on the stack load.

A number continues in `st_after_number`, which is `st_after` with two more ways out. In an array, when the element
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

`Skip` on a `Key` stays in the walk with the hook for a value it can read inline: `st_member_run` reads a number and
goes on, and `st_skip_member` reads a string or a number after a colon `colon_fast` takes, with no token, so a skip
of every member of an object makes no call per member. `st_skip_member` passes the comments around any other colon
itself, so the skipped value's first byte decides whether it is pushed. A container read as a document's root counts
its depth from 0.

### Comments

A spec adds to RFC 8259 through `FEATURES`, which the states test with `when`. A feature's code is placed only where a
state already refuses a byte or leaves its fast path: `st_value` on a byte of class `Bad`, `st_key` on a byte that is
not a quote, `st_colon` on a colon fault, and the separator states where a comment follows a value or its comma. In
`Json` every `when` is false, and its instance holds no code of the other specs.

A `/` in one of those places passes to a state in `comments.odin`, which reads the whole run of whitespace and
comments up to the next token before passing any of it to the hook, because what follows the run decides each
comment's role. The rule is `core.Role`'s and is the same in every format:

- a comment on the line where the value before it ends is that value's `Comment_Inline`,
- else, before a value, that value's `Comment`,
- else the `Comment_Foot` of the innermost open container, or of the root at depth 0.

A foot is written after the container's last value and before the container's `End`, so a foot in an empty container is
written before that container's `End`.

The state that reads a comment after a value receives the value's end, so a separator state sends a comma followed by
a comment there rather than to the next member. After a document's root, comments past the root's line are its foot
when the text ends after them or a 0x1E follows them, and otherwise belong to the next document, with the walk ending
before them. A walk without hooks reads every run and emits nothing, and `validate` passes over the comments after its
document while it checks that only whitespace follows.

A comment's bytes are judged as a string's raw bytes are: UTF-8, no control byte except a tab, and in a `/* */`
comment also CR and LF. JSON5 keeps this rule, tighter than its grammar, which allows any control byte. A `//` comment
ends at CR or LF, and in JSON5 also at U+2028 or U+2029. A `/` that opens no comment is `Bad_Char` at the `/`, and a `/*` that the text ends
inside is `Truncated`. Every spec with comments also accepts a comma before a close bracket: a close after a run of
comments is read without looking back at whether an open bracket or a comma came before the run.

A comment's body is stepped 16 bytes at a time to the first byte the reader must judge individually: a control byte,
a byte past 0x7F, a `*` in a `/* */` comment, and a line end in a JSON5 `//` comment. Whitespace between comments is
read one byte at a time, because a run there is short and a 64-byte vector load covers more bytes than the run. A
state that has already read the whitespace before a run's first comment passes that comment's position in `Walk.resume`,
with `Walk.crossed` for a comma read before it, so the run is not scanned twice.

### JSON5

`Json5` adds `.Es5` to JSONC's features: JSON5 1.0.0's numbers, strings, unquoted keys and whitespace (`json5.odin`).
A token that JSON spells the same way is read by JSON's own leaf. A state passes to JSON5's readers only where
that leaf refuses or no JSON construct starts:

- `st_value` on `'`, `+`, `.`, `I` or `N`, and where JSON's number reader refuses or stops before an `x`, which the
  number runs test too,
- `st_key` on a byte that opens no JSON key: a single-quoted key, an ECMAScript 5.1 IdentifierName, or else `Bad_Char`
  with `Identifier`,
- `string_long`, where JSON's readers refuse a string: `string_exact` reads it again by JSON5's rules,
- every place a comment may start: JSON5's other whitespace (VT, FF, U+00A0, U+FEFF, U+2028, U+2029 and Zs) opens a
  run as a `/` does.

A number's `spelling` is the packed `Number_Spelling` (`json/json5.odin`) in bits 0 to 3, whose
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
  which it finds by rescanning that record on the fault path. A narrower record makes its `Map` and all its cells, then
  faults at its line end's first byte: the CR of a CRLF, else the LF, or the text's end.
- Under `Ragged` no width faults. A headed record's cells past the header's last are read on a cold path
  (`read_ragged`), each after a `Key` that `column_key` makes: no bytes of its own, `lo` the header's first byte, `n` the
  column's 1-based position, and the spelling bit `SPELLING_COLUMN`, which `text` and `key_equals` spell as that
  position in decimal. A header cell of the same name repeats it and meets the duplicate policy.

### Tiers

On x86-64 the whole pass is built once per tier, `pass_v2`, `pass_v3` and `pass_v4`, each `#force_no_inline` with its
tier's features, and `run` switches on `kernel.tier()` once per walk. A block loop that calls kernels generic over
`$T` must be built per tier for the kernels to use the tier's instructions. Elsewhere there is a single pass,
`pass_base`.

### Cold readers

`text.odin` holds the readers the masks cannot replace, each reading one byte at a time and called only where a
block's masks show it is needed: `record_start`, `header_cells`, `scan_record`, the first bad UTF-8 sequence of a
block (`utf8_fault`, searched from no byte before the walk's first), and the exact span of a cell too long to measure
by block (`cell_too_wide`). `record_start` is `#force_inline`, `escape_fault` is `@(cold)` and `#force_inline`, and
`header_cells`, `scan_record`, `utf8_fault` and `cell_too_wide` are `@(cold)` and `#force_no_inline`, so the pass
saves no registers for them.

A TSV block's escapes are judged in masks. `kernel.escaped` marks the bytes an odd run of backslashes escapes, and one
class mask of `t`, `n`, `r`, `0` and `\` drops the valid ones, so a block with no bad escape runs no byte loop. A
backslash at the block's last byte carries into the next block, and a fault is at the backslash.

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
| `make test` | the tests at -o:minimal and -o:speed, one target per compile so `make -j` runs them in parallel, and the golden answers `json/test` checks |
| `make test-x86` | the tests at v2 and v3 under Rosetta, `-define:WALK_TIER` picking the walks' tier |
| `make test-asan` | the tests under AddressSanitizer |
| `make lint` | the import order, then vet on the host, x86-64 and riscv64 |
| `make size` | the lean lines of each library package against the 20,500 budget |
| `make surface` | each library package's public declarations, sorted |

The checks against the old tree's `json` and `csv` live in `compare/`, outside this tree, and run by its own
`make test-oracle`.

The value-tree models and the edit rounds against their own models are private, in the separate stury test repository
beside this one, and its `next-model` target runs them with `SEED` and `ROUNDS`. A value-tree model is a plain
recursive-descent reader of a valid text that shares no code with the walk or the readers. For each generated valid
text, and each valid JSONTestSuite and json5-tests file, it builds the document and checks every reader against the
model: `kind`, `length`, `children` and `child_at`, `member` under each `Duplicates` value and `members_named`,
`key_equals`, `text`, `number`, `resolve` with and without `infer`, `facts_of` per role, and `span` against the
value's source bytes.

The golden file `json/test/golden/json.txt` holds the old tree's answer for every JSONTestSuite and json5-tests file per
spec, as `compare/golden` wrote it. A line names the file and the spec, and records a pass or a fault kind and byte.
Where the oracle accepts a difference between the trees by design, the line holds this tree's answer and a marker
naming the reason. The test in `json/test` reads each file and checks `validate` against the line. Regenerate the file
from `compare/` with `make golden`.

The tests check every fault that names a byte at that byte and at every offset in a block, every prefix of generated
texts copied so the text ends at a guard page, so a read past it faults in every build, `Skip` and `Stop` at random
against the full walk's tokens on 100 generated texts, a hook that keeps its state behind `h` against one that keeps it
in `Hook_Regs`, each comment's role, JSON against JSONTestSuite and JSON5 against json5-tests. The private `next-laws`
target runs the same laws at their stress counts. `No_Memory` names no byte, so its test pins its rule and its
rendering.
