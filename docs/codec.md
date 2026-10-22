# stury codec internals

Notes for contributors, not a user guide. This page explains how the writer (`marshal`, `marshal(&doc)`, the
edits), the typed reader (`unmarshal`, `unmarshal_check`) and the command line's filter handling work, and why
they are built that way. The public names and their contracts are their doc comments (start at
`json/json.odin`). This page does not repeat them. Where a claim is a design reason rather than a measurement,
it says so.

## At a glance

Terms such as *walk*, *lane*, *frame* and *type plan* are defined in the [Vocabulary](#vocabulary) in §1.

- [**§1 Two directions, one plan**](#1-two-directions-one-plan) — encode's three jobs, how each one writes
  scalars, and how the read direction pairs with `marshal`.
- [**§2 The writer**](#2-the-writer) — the put layer, punctuation, re-escaping, and streaming to an
  `io.Writer`.
- [**§3 Writing scalars**](#3-writing-scalars) — how strings, integers and floats are written.
- [**§4 `marshal` of a `Document`**](#4-marshal-of-a-document) — the row walk that copies authored spans, and
  its compact and pretty engines.
- [**§5 `marshal`**](#5-marshal) — the type plan, the types and objects it writes, cycles and depth, and
  `Raw`.
- [**§6 Edits**](#6-edits) — `splice`, why `set` needs no re-validation, and `insert`/`remove`.
- [**§7 `unmarshal`**](#7-unmarshal) — the type table, fields and duplicates, strictness, ownership, errors,
  and the walk engine.
- [**§8 Across formats**](#8-across-formats-forward-design-not-built) — the forward design for a second output
  format.
- [**§9 How the CLI runs a filter**](#9-how-the-cli-runs-a-filter) — path scan versus interpreter, and large
  inputs.
- [**§10 Build-time options**](#10-build-time-options) — the `-define:` knobs.

## What `unmarshal` accepts and refuses, in short

`unmarshal` reads one JSON value into an Odin value, checking it against the target's type as it goes (details
in [§7.1](#71-the-type-table)).

- **Accepts:** `null`, booleans, integers in range, floats, strings, arrays and objects into the matching Odin
  types (structs, slices, dynamic and fixed arrays, maps with string, enum or integer keys, pointers, unions,
  `Maybe`, bit sets, enums, `any`, `Raw`).
- **Refuses, with an error that names the byte and the path:** a value of the wrong JSON kind, an integer out
  of range or written with a fraction, a float no binary64 holds, an enum name no member has, a fixed array of
  the wrong length, a missing `required` field, an unknown key under `unknown_fields = .Refuse`, and ambiguous
  unions.
- **Refuses before reading a byte (`.Unsupported`):** types with no JSON form, such as `#raw_union`, `#soa`,
  complex numbers and UTF-16 strings.
- **Never frees** what it allocates, and a refused input may leave the target partly written
  ([§7.4](#74-ownership-and-zeroing)).

## 1. Two directions, one plan

Encode has three jobs, and how a scalar is written follows from where the value came from.

| Job | Input | How scalars are written |
| --- | --- | --- |
| Write program values (`marshal`) | an Odin value | canonical ([§3](#3-writing-scalars)) |
| Write a parsed document (`marshal(&doc)`) | a `Document`'s node rows | authored: each scalar's span is copied |
| Edit a document (`splice`, `set`, `insert`, `remove`) | source bytes plus replacements | authored everywhere except the new values |

A value the program built has no source text to copy, so it is written in canonical form. A value that came
from a document keeps its bytes. Editing mixes the two: a new value is written canonically once, and every
other byte is copied. The read direction pairs with `marshal`: `unmarshal` reads into the same types through
the same `Type_Plan`. Tags, field order and `omitempty` therefore cannot drift between the two directions.

The rows are the format-neutral layer. A writer receives structure (open, key, value, close) and scalars. The
JSON writer is the only one. [§8](#8-across-formats-forward-design-not-built) is the forward design that keeps
a second writer possible without reworking this one.

### Vocabulary

Terms used throughout, defined once:

- **Row**: one 32-byte entry of a `Document` for one JSON value, holding its kind, its key and value spans,
  and where its subtree ends. Rows are stored in the order the values appear in the text (preorder).
- **Span**: a `[lo, hi)` range of bytes of the source text. A row's value is a span, and so is a `Path`
  answer.
- **Authored / canonical**: *authored* bytes are the source's own, copied unchanged, and *canonical* bytes are
  what the writer produces for a value that has no source text.
- **Walk**: one forward pass over the source bytes. Validation, path scans, document building and `unmarshal`
  are each a walk specialised for its job.
- **Type plan** (`Type_Plan`): the compiled, cached description of an Odin type that `marshal` and `unmarshal`
  run ([§5.1](#51-the-type-plan)). The **read shape** is the plan lowered for `unmarshal`
  ([§7.6](#76-the-engine)).
- **Hook**: a procedure a user type supplies (`Marshal_Hook`), or one of the walk's per-value callbacks in
  [§7.6](#76-the-engine).
- **Put layer**: the low-level byte-appending procedures of the writer ([§2.1](#21-the-put-layer)).
- **`Walk_Kind` and `Q`**: a walk is wired for a compile-time set of `Walk_Kind`s (`Path`, `Nodes`, `Dom`,
  plus selectors the router picks such as `Demand`, `Shape` and `Unique`). A request's `Q` is the subset of
  those it asks for (`Query`). Each distinct set is compiled into its own copy of the walk.
- **Walk selector**: a `Walk_Kind` that is not a request's `Query` but chooses what the walk does with each
  value. `Walk_Kind.Shape` makes it the `unmarshal` walk.
- **Lane**: one compiled copy of a walk, for one set of `Walk_Kind`s and one dialect. `unmarshal` has several
  (strict, lazy, JSONC, key-checking).
- **Frame**: the walk's record for one open container that has a target (`Shape_Frame`). Frames stack as the
  containers nest.
- **Demand matcher**: the router's matcher for plain-name and column paths (`.a.b`, `.logs[].id`). It finds
  named members at one depth inside the same walk. Paths it does not take go to the general path automaton.
- **Byte cursor / index cursor**: how a walk moves through the text. The byte cursor steps over the bytes in
  blocks, and the index cursor follows a prebuilt structural index.
- **Skip index**: the structural index `.Lazy` may build on the stack above its size gate
  ([§7.3](#73-strictness)), so the walk can jump over values the type does not read.
- **Plan op** (`Plan_Op`): one flat entry of a `Type_Plan`, for one type ([§5.1](#51-the-type-plan)).
- **Batch pool** (`host.Batch_Pool`): threads kept between batches, which `each_record` and `validate_records`
  run on ([§7.7](#77-records-from-an-ioreader)).

## 2. The writer

The writer builds JSON text through a put layer that never checks container state.

### 2.1 The put layer

The put layer's callers own structure, so a state machine per value would only slow `marshal` and `marshal(&doc)`.

- The writer is `put_*`, in package `json/encode`. Package `json` does not forward it. It works on a
  `^[dynamic]u8`.
- The document writer follows preorder rows and `marshal` follows a type plan. Both always emit well-formed
  structure, because the rows and the plan already describe it.
- The put layer reserves room once per item (`put_reserve(dst, n) -> [^]u8`). It writes through the returned
  pointer, then commits the length (`put_commit`).
- If the allocator refuses, `put_reserve` returns nil and nothing is committed.
- Nothing in a hot loop calls `append` per byte.
- If an append is refused, the buffer is unchanged, and `marshal`'s refusal returns a nil slice.

### 2.2 Punctuation

Compact writes no spaces. Pretty changes only containers that receive at least one element. Empty `[]` and
`{}` are two bytes in both modes.

| Event | Pretty bytes |
| --- | --- |
| between elements | `,\n` plus one indent per open container |
| after `{` or `[` when an element follows | `\n` plus one indent per open container |
| before a matching `}` or `]` | `\n` plus one indent per container outside this one |
| after a key | `:` then one space |

The indent is one tab, or `indent` spaces (1–255).

`sort_keys` writes each object of a `Document` (JSON or JSONC) with its members in byte order of their decoded
keys, as `stury -S` does.

- With `jq_spelling` a repeated key is merged first (its last value, sorted). Without it, repeated keys keep
  their source order (a stable sort).
- A JSONC member's comments move with it.
- Like `jq_spelling` it is not applied to a `marshal` of an `any`: a map is already sorted
  ([§5.3](#53-objects)) and a struct keeps its declaration order.
- Any unsorted `Document` marshal takes the same path as before.

### 2.3 Re-escaping

`ascii_only` and `escape_html` are one pass over finished JSON text, in `json/encode/reescape.odin`. They are
not a branch in every scalar writer. Strict JSON makes the pass simple: the characters it rewrites occur only
inside strings and never right after an escaping backslash. So it reads each character alone and keeps no
string state.

- It skips 16 clean bytes at a time.
- It runs once over `marshal`'s output and `marshal(&doc)`'s.
- Off, it is one branch per call.
- Re-escaping a stream keeps a UTF-8 sequence cut at the buffer's end for the next write.

### 2.4 Streaming to an `io.Writer`

`marshal_to_writer`, for a value or a `Document`, writes through a private buffer of `SINK_FLUSH_AT` (64 KiB)
and hands it to the writer when it fills. Only bytes no later write changes are handed over.

- `marshal(&doc)` writes rows forward. Its compact minify runs in `SINK_FLUSH_AT` pieces, with its string
  state carried across.
- Compact `marshal` patches a struct's `{` in after its members and a struct array's `]` over the last `,`.
- Streaming, it opens a struct that holds anything but scalars before its members, as pretty does, and hands
  bytes over only between elements.
- A flat struct is written whole between two such points, so it keeps its fast path.
- A single item longer than the buffer (a long string, a `Raw`) is buffered whole first.
- A JSONC document is made whole, then written. Its rows are not streamed (`json/encode/jsonc.odin` writes the
  whole text into one buffer).

## 3. Writing scalars

A scalar is written in canonical form according to its type: strings are escaped, integers are decimal, and
floats use the shortest digits that round-trip.

### 3.1 Strings

The input must be valid UTF-8, or the append is `Bad_Utf8` and writes nothing.

The output:

- `"` and `\` become `\"` and `\\`.
- `\b` `\f` `\n` `\r` `\t` use those short escapes.
- every other byte below `0x20` becomes `\u00XX`, lowercase hex.
- `0x7F`, `/`, and every valid non-ASCII sequence are copied.

The loop validates and writes in one pass, 16 bytes at a time. One vector compare finds bytes `< 0x20`, `"`
and `\`. A block whose high bits are all clear skips UTF-8 checking. A block with nothing to escape is stored
whole, and clean runs never touch a byte table. The scalar loop is the reference: the SIMD loop must write
every input exactly as the scalar loop does.

That is checked over random strings and every byte value in every position of a 16-byte block.

### 3.2 Integers

`i64` and `u64` write left to right straight into the destination, in groups of eight digits from a two-digits
table. `i128` and `u128` (marshal only) use `strconv.write_bits_128` (base 10, no leading `+`). The output is
decimal digits with an optional leading `-`: no exponent, no fraction, no leading zeros.

### 3.3 Floats

Non-finite values are `Non_Finite` and write nothing. A finite value is written in three steps.

1. **Digits.** The shortest decimal that round-trips, from a line-by-line port of zmij's `to_decimal`.
   - zmij is the `zmij` crate 1.0.23 (MIT), itself a port of vitaut/zmij (a Schubfach variant).
   - Its `POW10_SIG`, `EXP_SHIFT` and `EXP_STRING` tables are generated exactly by
     `json/encode/zmij_tables.py`.
   - The generator also repeats the crate's own table rebuild and checks every entry against the exact one.
   - Subnormals take a separate arm.
   - `core:strconv.write_float` is not used on this path: it formats through multi-precision decimal
     arithmetic and is several times slower.
2. **Layout.** ECMAScript's `Number::toString` rules, which give the text `JSON.stringify` produces, except
   for negative zero.

   With `k` digits `d1…dk` and `n = k + exponent`:

   - `k ≤ n ≤ 21`: the digits, then `n − k` zeros (`100`, `123000`).
   - `0 < n ≤ 21`: `d1…dn` `.` `dn+1…dk` (`1.5`, `123.456`).
   - `−6 < n ≤ 0`: `0.`, then `−n` zeros, then the digits (`0.001`).
   - otherwise: `d1`, then `.d2…dk` when `k > 1`, then `e`, a sign, and `n − 1` (`1e+21`, `1.5e-7`).
   - `-0.0` is written `-0`. ECMAScript prints `0`, which would lose the sign bit, and the output must read
     back to the same `f64` bits.
3. **Round trip.** The scanner's `number_span` on the written bytes returns the same `f64` bits, sign of zero
   included.
   - An integer-valued float is written without a fraction (`1.0` is written `1`), so `decode_span` may read
     it back in
     the `i64` arm.
   - What is guaranteed is the `f64` bits, not which arm reads them.
   - The round trip is checked on the special set and on 10⁶ random bit patterns, and `make test` checks the
     layout goldens.

`f16` and `f32` are written with the shortest round-trip digits for their own width (`f32(0.1)` is `0.1`, not
`0.10000000149011612`). `core:strconv.write_float` finds those digits at the narrow width, and they have at
most 9 significant digits. So the nearest `f64` lays them out unchanged through the path above. Narrow floats
are the cold path, and an `f64` field never reaches it.

## 4. `marshal` of a `Document`

`marshal(&doc)` copies authored spans and never decodes or rewrites them.

- It walks `doc.rows` in preorder, the order rows are stored in.
- A row with a key writes its key span as authored, then `:`.
- A scalar row writes its value span.
- A container row writes `[` or `{` (or `[]`/`{}` when empty).
- It pushes the index where its subtree ends and its close byte. After each row, every container whose subtree
  ended there is closed.
- So `é`, `1.50` and `1e2` survive as written.
- A `Document` has been checked strictly, so every copied span is valid JSON and the output needs no re-check.
- The output of a compact strict JSON source is that source, byte for byte.
- A JSONC source is written with its comments, placed by the writer's layout rules.
- `build` of the output gives the same kinds and spans' text at every row.
- Pretty output, re-encoded compact, gives back the compact output.

Compact output is the root's span minus whitespace outside strings.

Two engines produce it, chosen by how many source bytes each row covers:

- **Minify** (the default): the span in 64-byte blocks, with the scan's own string mask (quotes, escaped
  quotes, `prefix_xor`) and a lane-keep shuffle that drops whitespace outside strings.
  - It never reads the rows.
  - Strict JSON makes this sound: outside strings, whitespace is never significant.
- **Source runs**, when the span holds at least `ROWS_WALK_BYTES` bytes per row (long strings, few rows): the
  rows are walked and the output is a sequence of source runs.
  - A token that sits in the source exactly where the output puts it only extends the pending run, and any
    other token flushes it with one copy.
  - On a compact source the whole document is one copy.

Allocation:

- Compact strict JSON output is never larger than the root span.
- So the writer allocates the span plus a 64-byte store slack once and does not shrink it (a shrink is a
  second copy).
- Pretty output is allocated at a bound from the span, the row count and a depth of 8 (`pretty_bound`).
- It is regrown when the walk opens a container deeper (the exact size, when the bound dwarfs the span).
- Short spans move as one 16-byte store, and an indent under 16 tabs is one 16-byte store.

Refusals:

- `Bad_State` for a `Document` with no rows, or one whose rows are not a single tree. Only a whole-document
  tree is one JSON text.
- `Too_Deep` for one nested past `MAX_DEPTH`, which only a document built under a raised `max_depth` can be.

**Boundary for later writers.** The row walk calls only these: open a container, write a key, write a scalar
span, close. It does not inspect JSON bytes. Minify is the JSON-to-JSON shortcut and stays in `json/encode`.
When a second output format arrives, the walk moves out of `json/encode` and takes the writer as a
compile-time parameter (`$W`). Until then there is one writer, and no interface.

## 5. `marshal`

`marshal` writes any Odin value according to its type, through a compiled plan.

### 5.1 The type plan

`marshal` compiles `v`'s type into a `Type_Plan` once and runs the plan. `core:reflect` lookups per field per
value are what make reflective marshallers slow.

- A plan is a flat array of ops, one per type or field.
- Each op holds the kind, the size, the field offset, and the index of its element or field ops.
- Each key is pre-written as `"name":` in a byte arena.
- A map from `typeid` to op makes recursive types (a struct holding `^Self`) refer back to an op that already
  exists.
- Types known only at run time (`any`, union arms) are added the first time a value of that type is met.
- So a plan grows while it is in use, and calls take `^Type_Plan`.
- Compilation is lazy: `type_plan_init` records the root type and copies the options, and ops compile on first
  use.
- A plan that reported `Out_Of_Memory` is unusable.
- With `plan` nil, a call takes this thread's cached plan for the type: most recently used first, the least
  recently used destroyed to make room.
- A call nested inside a hook misses without evicting (the plan it would destroy may be the one an outer call
  is using).
- It builds a temporary plan in the heap allocator and destroys it before the outer call returns.
- The cache is `thread_local`, so it needs no lock.
- It holds no mutable package state in the sense `tools/no_mutable_globals.py` checks.
- `unmarshal` caches its read shape ([§7.6](#76-the-engine)) on the same plan, so after its first use a kept
  plan allocates nothing on either direction.

### 5.2 Types

Each Odin type has one JSON form.

| Odin type | JSON form |
| --- | --- |
| nil `any`, nil pointer, nil `cstring`, nil union, `Null`, nil `Decoded` | `null` |
| `bool` and `b8`–`b64` | `true` / `false` |
| integers, `uintptr` | [§3.2](#32-integers) |
| enums | the member's name; a value no member has is `Not_A_Member`. With `enums = .Int`, the backing integer. A map key is the name, or the integer in quotes. An enum backed by a 128-bit integer is written as its integer. |
| `f16`, `f32`, `f64` | [§3.3](#33-floats) |
| `string`, `cstring`, `rune` | [§3.1](#31-strings) (`rune` is a one-codepoint string; an invalid rune is `Bad_Utf8`) |
| `Raw` | its bytes, verbatim ([§5.5](#55-raw)) |
| `Decoded`, `Number` | the arm, or `.value` ([§3.3](#33-floats)) |
| array, slice, dynamic array, enumerated array, fixed-capacity dynamic array | JSON array; a nil slice is `[]`; `[]u8` is an array of numbers; an enumerated array is its elements in index order, holes included |
| `map` with `string`, `cstring`, enum or integer keys | JSON object, keys sorted ([§5.3](#53-objects)) |
| struct | JSON object, fields in declaration order ([§5.3](#53-objects)) |
| pointer | the pointee |
| union | the active arm, as a bare value; with `union_tag`, a named struct arm is an object whose first member is the tag (`{"type":"Circle","r":1}`) |
| `bit_set` of an enum or an integer range | an array of its elements in ascending order: member names, or integers |
| a type with a hook | the one value its `Marshal_Hook` writes through `marshal_into` |
| everything else (UTF-16 strings, non-platform-endian numbers, `#raw_union`, `#soa`, complex, quaternion, matrix, simd vector, `bit_set` of runes or of a 128-bit enum, `bit_field`, `typeid`, `rawptr`, multi-pointer, procedure, other map keys) | `Unsupported` |

### 5.3 Objects

Structs and maps are both written as objects, each with its own ordering rule.

- **Structs.** Fields come out in declaration order.
  - A `json` tag replaces the field name and `json:"-"` omits the field.
  - `omitempty` omits a nil pointer, a nil `any`, a nil union, an empty string, slice, map or `bit_set`. `0`,
    `false` and `Null` stay.
  - A `using` field of a struct type with no JSON name is flattened, as Go flattens an embedded struct.
  - A struct in which two fields have the same JSON key, or with Go's `,string` flag, is `Unsupported` in both
    directions. Other flags are ignored.
- **Maps.** Keys are sorted by the bytes written between the quotes.
  - An integer key is written out first, then compared as text, so `10` sorts before `9`.
  - Odin's map iteration order depends on hashing and capacity, so sorting makes the output a function of the
    map's contents alone.
  - The sort runs over a scratch array from `context.allocator`, not `context.temp_allocator`.
  - The caller may pass the temp allocator as the output's, and a temp guard would free the output.

### 5.4 Cycles and depth

A pointer that reappears on its own open path is `Cycle`. A pointer reached by two different paths (a diamond)
is written twice. Nesting past `MAX_DEPTH`, counting containers, pointers and `any` indirections, is
`Too_Deep`. An `any` whose data is already on the open path is `Cycle`.

### 5.5 `Raw`

A `Raw` holds the authored text of one JSON value. `marshal` validates it (`.Strict`, with the nesting left
below `MAX_DEPTH` at its position as the depth limit) and copies it unchanged, in pretty mode too. An invalid
`Raw` is `Bad_Raw`, and so is one with leading or trailing whitespace: the text must be exactly the value.
`unmarshal` fills a `Raw` with the value's source span.

So a struct can carry a subtree it does not model and write it back byte for byte, in the dialect it was read
in. `marshal` writes JSON and has no dialect, so a `Raw` read under `.Jsonc` with a comment or a trailing
comma in it is `Bad_Raw` there. An edit of a JSONC text (`set` or `insert` with `dialect = .Jsonc`) validates
a `Raw` as JSONC and writes it back byte for byte.

A comment before or after the value is still `Bad_Raw`, since the text must be exactly the value.

## 6. Edits

An edit replaces the values a path finds and keeps every other byte.

### 6.1 `splice`

The output is the source with each `[lo, hi)` replaced. It is built with one copy per gap and one per
replacement. Unsorted, overlapping and out-of-range edits are refused. `splice` cannot know that an arbitrary
`[lo, hi)` was a whole value, so it validates the result. A fault is `Bad_Result` with its offset into the
edited text.

### 6.2 `set` needs no re-validation

`set` parses the path, scans the source `.Strict` with it, marshals the value once, and replaces every `Found`
answer with those bytes.

The result is valid without a second pass. Why this holds:

- the source was validated `.Strict`.
- every replaced span is a `Found` answer, so it is exactly one complete value.
- every replacement is one complete value written by the canonical writer.
- JSON's grammar puts `value` in the same position everywhere, so swapping one complete value for another
  keeps the text valid.
- depth is the one thing the grammar does not cover. The path grammar has no `..`, so the target sits inside
  exactly one container per step.
- `set` validates the written replacement with `max_depth = MAX_DEPTH − steps`.
- this covers a `Raw` replacement too, whose nesting `marshal` does not see.

A property test on random paths and values checks that `set`'s output passes `validate`, and the guard fires
at exactly `MAX_DEPTH + 1`.

### 6.3 `insert` and `remove`

They read the containers' entries from one `.Path` scan (the target path and its container's `[]`). They do
not read `.Nodes` rows, whose scoped window costs more than a path scan. An entry copies the separator between
its neighbours and a member's key-to-value bytes, so pretty input stays pretty.

Under `.Jsonc` the entries come from a `.Nodes` scan instead, because an entry's extent runs from its first
`.Lead` comment to its `.Trail` comments, and only rows carry comments. Where a comment sits between the
entries an edit touches, a JSONC entry goes in or out by its extent, so no comment ends up attached to a
different entry. Where none does, the layout is JSON's, and plain JSON edited under either dialect gives the
same bytes.

## 7. `unmarshal`

`unmarshal` reads one JSON value into an Odin value in one forward pass, checking it against the target's type
while it reads. Its two strictness levels, `.Strict` and `.Lazy`, are defined in [§7.3](#73-strictness). It
checks the JSON kind each
target accepts, required fields, integer and float ranges, fixed array lengths, enum membership and unknown
keys. It builds no document and no rows ([§7.6](#76-the-engine)). `unmarshal_check` is the same walk with no
target, and it reports the same errors. With a kept plan, nothing is allocated after the plan's first use.

Under `.Lazy`, above a size gate ([§7.3](#73-strictness)), the walk may build a structural skip index on the
stack. Where the pieces live:

- `json/unmarshal.odin`: the package-level names.
- `json/read_shape.odin`: the lowering. `core/shape.odin`: the plain-data shape.
- `json/scan/walk_shape.odin`: the walk. `json/scan/shape_entry.odin`: the entry and the `.Lazy` skip gate.
- `json/scan/shape_leaf.odin`: the leaves. `json/scan/shape_fused.odin`: the fused loops.

### 7.1 The type table

A type is read by its `Shape_Kind`, lowered 1:1 from the `Type_Plan` op that `marshal` writes it with. If the
token is the wrong JSON kind, the error is `.Wrong_Kind`. If it is the right kind but the target cannot hold
it, the error is `.Out_Of_Range` (or `.Not_A_Member` for an enum, `.Wrong_Length` for a fixed array).

| Shape kind | Target | Accepts | Refuses |
| --- | --- | --- | --- |
| `Null` | `json.Null` | `null` | anything else |
| `Bool` | `bool` and its widths | `true`, `false` | anything else |
| `Int`, `Uint` | `i8`..`i64`, `u8`..`u64`, `int`, `uint` | an integer-form number in range | a fraction or exponent (`.Wrong_Kind`); out of range |
| `Wide_Int`, `Wide_Uint` | `i128`, `u128` | the same, over 128 bits | the same |
| `Enum_Int`, `Enum_Uint` | any enum | a member name, compared by decoded text; under `enums = .Int` a declared backing integer | an undeclared name or value (`.Not_A_Member`); a number by name or a string under `.Int` (`.Wrong_Kind`) |
| `Float` | `f16`, `f32`, `f64` | any number, correctly rounded once | no binary64 value (`1e400`), or an overflow in the target width; an underflow rounds |
| `String` | `string` | a string, decoded | a non-string |
| `Cstring` | `cstring` | a string (copied with a NUL) or `null` (nil) | a string holding `\u0000` (`.Out_Of_Range`) |
| `Rune` | `rune` | a string of exactly one code point | none or several (`.Out_Of_Range`) |
| `Raw` | `json.Raw` | any one value, as its source span | a syntax fault in it, even under `.Lazy` |
| `Decoded` | `json.Decoded` | a scalar, into the arm `decode_span` gives it | a container |
| `Number` | `json.Number` | a number, as binary64 and its exactness | a non-number; no binary64 value |
| `Digits` | `json.Digits` | a number, as its source span (written back as that number) | a non-number |
| `Slice`, `Dynamic` | `[]T`, `[dynamic]T` | an array of `T` | a non-array |
| `Array` | `[N]T`, enumerated arrays | exactly N elements | short (at its `]`), or over (at the first element too many) |
| `Fixed_List` | `[dynamic; N]T` | at most N elements | over N |
| `Map` | `map[K]V` | an object; each key parsed into `K` | a key not of `K`'s grammar or range |
| `Struct` | a struct | an object | a non-object |
| `Pointer` | `^T` | `null` (nil) or a `T`, allocated | a non-null the pointee refuses |
| `Union` | a union, `Maybe(T)` among them | `null` (nil), or a value in the one arm that takes its JSON kind; under `union_tag`, an object in the struct arm its tag names | a kind no arm takes; a tag no arm has (`.Not_A_Member`); an object without its tag where only the tag picks (`.Missing_Tag`); the tag twice (`.Repeated_Tag`) |
| `Any` | `any` | `null` (nil); a scalar as its `Decoded` arm; an object as `map[string]any`, an array as `[dynamic]any` | what `Decoded` refuses |
| `Bit_Set` | `bit_set[E]`, `bit_set[lo ..= hi]` | an array of member names (integers under `.Int`) or of integers in range, any order, repeats allowed | a bad element, refused at the array's `[` |

Notes:

- **Integers** accept only integer-form tokens (no `.`, `e` or `E`).
  - They are range-checked per width, so nothing is truncated silently.
  - `-0` is 0 for every integer target.
- **Floats** can lose precision, since not every decimal is exactly representable. Only an overflow is
  refused.
  - An `f32` or `f16` target rounds once from the decimal, not twice through binary64.
  - `f16` is rounded in-library (`f64_to_f16`, ties to even), not by the cast.
  - On x86-64 the cast is the runtime's software conversion, which rounds through `f32` and then ties up.
  - So a value at an `f16` halfway point would come out one unit high there.
- **Map keys** are strings, `cstring`s, enum member names (integers under `.Int`), or integers written inside
  the quotes in JSON's integer grammar.
  - `""`, `"-"`, `"01"`, `" 1"`, `"+1"` and `"1e2"` are refused.
  - A key is decoded before it is parsed or stored.
- **Pointers and unions** nest: `Maybe(Maybe(int))` reads `5` as present.
  - A pointer allocates and zeroes its pointee.
- **Unions** are read by one rule. `marshal` writes an arm's value with no tag, so the value's JSON kind picks
  the arm: the one arm whose type takes that kind.
  - A union in which two arms take one kind is `.Ambiguous_Union`, before any byte.
  - Examples: two numbers (`union{int, f64}`), two objects (a struct and a map), `Raw` or `any` beside
    anything, `Decoded` beside a scalar.
  - The walk reads a value as it passes, so it cannot try one arm and fall back to another.
  - With one arm per kind, every value `marshal` writes from the union reads back into the arm it came from.
- **Tagged unions.** With `union_tag` set (say `"type"`), `marshal` writes a named struct arm's type name as
  that member, first.
  - `unmarshal` reads an object into the arm its tag names, wherever the member sits.
  - Without the tag an object falls back to the arm its kind picks. With two or more struct arms there is none
    (`.Missing_Tag`).
  - The tag is no field of the arm, so `unknown_fields = .Refuse` lets it pass.
  - It is found by a pre-scan of the object's members before the walk checks them, with its key and value
    compared after decoding (an escaped form of the key is the tag too).
  - An arm with a field whose name is the tag is `.Unsupported`.
- **`any`** boxes what it reads in `allocator`: a scalar as its `Decoded` arm, an object as a `map[string]any`
  (a repeated key kept as `duplicates` says), an array as a `[dynamic]any`.
  - `marshal` writes it all back as it was read, `Digits` as the number its text holds, except an object's
    keys, which it sorts.
- **Lists** grow a buffer in `allocator`: they start at 8 elements and double, and are never shrunk.
  - The slack is the allocator's, and an arena takes it.
  - A list past 2^31 elements is `.Out_Of_Memory`: its count is a `u32`.
- **Not served**, refused as `.Unsupported` before any byte with the path to the field.
  - The list: a `bit_set` of runes or of a 128-bit enum, `#raw_union`, `#soa`, non-platform-endian numbers,
    UTF-16 strings.
  - Also: map keys that are not strings, enums or integers, structs of more than 16,448 fields (the walk's
    seen mask is 257 64-bit words), structs in which two fields have the same name, and Go's `,string` flag.

### 7.2 Fields, unknown keys, duplicates

A field is optional unless tagged `required`. An absent required field is `.Missing_Field` at the object's
`}`, naming the first missing in declaration order. An absent optional field keeps what the target held, as
Go's and core's unmarshal do: the target is read over, never zeroed first.

A present value reads over the target by Go's rule (a struct sets the members the object names, a map keeps
its entries, a non-nil pointer is read through, a fixed array's elements are read in place, a union is
replaced). Lists are the exception: they are replaced, as core replaces them. There are no field defaults.

**Unknown keys.** `.Ignore` keeps forward compatibility, and is the common default elsewhere (Go, serde).

**Duplicates.** `.Last` reads each occurrence over what the one before left, so a repeated object or map
merges and a repeated scalar or list keeps the last. `.First` reads the first and checks the rest. A map that
held entries reads the object into a fresh map merged in at its `}`, so only the object's own repeats count.
Every occurrence of a known member is checked, whichever one is kept: a `.First` repeat is checked in full but
stored nowhere.

Checking every occurrence makes `unmarshal_check` exact without remembering map keys. `.Refuse` remembers the
keys of the first 64 objects open at once on the stack and spills the rest to `context.allocator`, given back
before the return.

### 7.3 Strictness

`.Strict` validates every byte. `.Lazy` validates in full every value the type reads, and may skip, without
checking, the members and values it does not read. It never changes the value read, and bytes after the
document are checked under both. So under `.Lazy` an unread malformed value may be accepted or refused,
depending on the document's size and shape, not on the fault. `.Structural` is refused: a typed read stores
what it reads, so it must validate it.

How `.Lazy` decides (tuned values, not contract):

- Below `SHAPE_LAZY_MIN_BYTES` (counted from the root's first byte) it takes the same complete walk as
  `.Strict` (that lower edge is exact).
- Above it, `shape_skip_walk_pays` probes a head of the document and sums the bytes of unread containers and
  the values in them.
- It chooses the skipping walk when those are a large enough share of what the probe read, their values are
  short, and they hold many values or most of what it read less unread scalars. It also chooses it when the
  head holds no whole value.
- The thresholds are the `SHAPE_*` constants beside `SHAPE_LAZY_MIN_BYTES` in `json/scan/shape_entry.odin`,
  which say what each one means.
- Otherwise the complete walk, in which a fused struct passes an unread string to its closing quote without
  validating it (`.Pass_Unread`, a 16-byte quote-or-backslash scan).
- Unread scalars and whitespace do not count as skipped: the fused complete walk passes them faster than the
  index jumps them.

`.Lazy` costs no more than `.Strict` beyond noise and the probe.

### 7.4 Ownership and zeroing

**One owner.** Everything unmarshal creates comes from `allocator`, dynamic arrays' own `allocator` field
included. Nothing is freed, not even on refusal.

**Zeroing.** Unmarshal does the zeroing itself. The destination is read over, not zeroed
([§7.2](#72-fields-unknown-keys-duplicates)). What the walk creates or replaces starts from zero: each list
slot as it opens, a union's arm, a pointee when it is allocated. An allocator that does not zero (a scratch
allocator, an arena reusing memory) still gives those zero.

**Non-zeroed modes.** Allocations ask for the non-zeroed modes and fall back to the zeroing ones on
`.Mode_Not_Implemented`. So an allocator with only `.Alloc`, `.Free` and `.Resize` works. A type that holds a
`map` still needs the non-zeroed modes: Odin's runtime map allocation asks for them itself. Two other files,
`json/edit_ops.odin` and `json/encode/document.odin`, still call the non-zeroed procs with no fallback.

**Partial writes.** A refused input may leave the destination partly written. A refusal during the walk leaves
what was read before the fault. One before it (`.Bad_Option`, `.Plan_Mismatch`, `.Unsupported`,
`.Out_Of_Memory` lowering the plan) leaves `ptr^` untouched. `unmarshal_check` writes nothing.

**Paths.** A `Name` step in an error path borrows `src` (a map key, or an unknown key as authored) or the type
info (a field name), so the error's path is valid only as long as `src` is.

### 7.5 Errors

Offsets are forward byte offsets: the first byte where a forward reader knows of the fault, exact on both
kinds of fault.

- A typed fault's path names exactly the value refused.
- A `.Syntax` fault's path names the innermost member or element opened, which may already have closed (`[1,`
  names `[0]`).
- Its offset is exact either way.
- `.Syntax` carries the same `Error_Kind` at the same offset `validate` gives.
- The nesting cap wins over a kind fault at the same depth.

### 7.6 The engine

Unmarshal is the walk selector `Walk_Kind.Shape` (see the [Vocabulary](#vocabulary)) on the in-walk engine
(`walk_value_q` in `json/scan/walk.odin`), with its own entry `scan_shape`. It does not go through
`scan_queries`. The other specializations compile to the same code apart from the `Query_Ctx` layout, since
every shape hook is gated `when .Shape in Q`.

- **The read shape** is compiled once from the caller's `Type_Plan` and cached on it: one `Shape_Op` per
  `Plan_Op` and one `Shape_Field` per `Plan_Field`, at the same indices.
- **The four hooks:**
  - `shape_value_open` at a value's start: takes the target, unwraps pointers and unions, pushes a frame for a
    container, latches a scalar.
  - `shape_key` after an object key's colon: selects the field.
  - `shape_scalar` at a scalar's end: decodes it into the target.
  - `shape_close` at a container's close: checks required fields and array lengths, writes list headers.
  - A call in `shape_value_open` slows every unmarshal lane, so rare work happens at close or at the leaf.
- **Field selection** is the demand matcher's key set made per object type: ordered-key prediction (the field
  after the last match), then a 256-bit first-byte filter, then the shared key compare.
- **Typed faults** leave the walk through its existing `return err` paths, as an `Error` of kind `TYPED_FAULT`
  (`.None`, which no syntax fault is) at the offending byte, and the detail rides on `Shape_Run`.
- **Numbers are read once.** Under `.Shape` the number lexer folds the digits it validates into
  `Shape_Run.num`.
  - The leaves decode from that instead of reading the token again.

**Fused loops.** The hooks cost a round trip per value, so two loops take the commonest runs whole, in the
complete walk over the byte cursor. `shape_take_members`, for a struct whose names are plain printable ASCII
and that has some whole-leaf field, predicts the key by its raw bytes, takes the colon, and validates and
decodes a scalar member straight into its field.

`shape_take_elements` does the same for each scalar element of a slice or dynamic array of whole leaves. Each
loop does what the walk and its hooks would do, in the same order, so every error keeps its kind, offset and
path. Whatever a loop cannot take (an escaped, repeated or unknown key, a container value, a malformed scalar)
is handed back at the same byte with the same frames, for the walk to check again.

The loops share the walk's leaf decoding and list growth and return no `Error`: carried out of every value, it
cost the loop its registers.

**Liveness.** The hooks keep a stack of live frames, the containers that have a target, which are exactly the
walk's innermost open containers. A value is read only at the live depth, and a deeper value belongs to a
container nothing reads (or to a `Raw`).

Every value is therefore read, checked only (under `.Strict`), or skipped without checking (under `.Lazy`).
`unmarshal_check` and a `.First` repeat run as check-only.

**Frame layout.** `Shape_Frame` is kept free of padding: the frame array is declared `---`, and Odin zeroes a
padded struct even then.

**Why forward.** A type usually reads every record's fields, so a backward locate has no tail to skip. The
framing pass a backward locate needs costs what the skipping walk costs (a design reason, not measured).
`.Last` is served forward by overwriting.

**Why no rows.** A type reads members by name and elements in order, which the forward walk serves. Rows only
pay for random access, which a type never asks for.

**End of input.** The walk always runs to the end of the document, since bytes after the value are checked
under both strictnesses. Only a fault stops it early.

### 7.7 Records from an `io.Reader`

`records_from` frames `.NDJSON` and `.JSON_Seq` over a stream with the framer `records` uses, so there is one
framer.

- A window holds the bytes not yet framed. After each read of `chunk` bytes it is cut after the last line feed
  (NDJSON) or where the last run of `0x1E` starts (JSON text sequence), and `records` runs over the part
  before the cut.
- A cut never splits a record, so a record is framed whole and offsets, faults and the RFC 7464 §2.4 truncated
  number match `records` over the whole input, whatever the reads' sizes.
- Only the bytes a read added are searched for a cut, so a long record is not rescanned per read.
- The framed bytes are dropped before the next read. The window doubles when a record and a chunk do not fit:
  at most twice the longest record plus a chunk.
- A record is valid until the next `next_record`.
- `.Root_Entries` needs the whole root and is `.Bad_Option` on `err`. Read the root and use `records`.
- A reader failure other than `.EOF` is `read_err`. Records framed before it are yielded, the bytes after them
  are not.

## 8. Across formats (forward design, not built)

The one forward note: how a later format (TOML, CSV) joins without reworking this one.

- **Shared:** the rows (structure plus spans), the query engine, and the writer protocol (open, key, scalar,
  close).
- **Each format owns** its lexer (spans in, rows out) and its writer (protocol in, bytes out).
- **A span holds text in its source format.** A same-format writer copies it, as `marshal(&doc)` does.
  - Another format's writer decodes it and writes the value itself.
- **Numbers cross formats as written digits** (coefficient, scale, exponent), so `1.50` keeps its precision.
  - Converting to `f64` can lose digits, so numbers are not carried as `f64`.
- **A type the target cannot hold** is refused, cast, dropped or converted by a user policy per source type.
  - Lossy actions are opt-in, and every action other than a refusal is counted in a conversion report.
- **Sources past 4 GiB (`MAX_ROW_SOURCE`) keep the 32-byte `Row`.**
  - Streaming (`each_record`) and scans that build no rows (`validate`, `.Path`, `unmarshal`) already carry
    `u64` offsets.
  - Rows over a larger source either emits a high-32-bit epoch row each time `s.pos >> 32` advances, or stores
    `hi` and `key_hi` as `u32` lengths with the high offset bits packed into spare header bits.
  - `Kind` and `Row_Flags` use 10 of 16 bits.

## 9. How the CLI runs a filter

A filter runs by one of two routes: a path scan or the interpreter.

**Path scan.** A path in `parse_path`'s subset, or `select(PATH OP literal)` with no `[]`, is one `.Path` scan
per input. These options send the filter to the interpreter instead: `-n`, `-s`, `-S`, `-a`, `-e`, `-R`,
`--raw-output0`, `--seq`, `--stream`.

A path with `[]` is scanned `per_element`. An element in which the rest of the path misses a member prints
`null`, as in jq. A text on which jq would error is handed to the interpreter before any of its outputs print:
a step meets a value of another kind, or the value being indexed is neither an array nor an object. Over a
large root array, or the array of `{"key": [...]}`, `.[] B` and `.key[] B` scan the array in pieces on the
batch pool.

**Interpreter.** Any other filter runs on the interpreter, over each input built whole into a `Document`.
Duplicate keys are `.Last`, as in jq. A JSONC text with a `/` in it runs on the interpreter, which tracks
where each value came from, and JSONC without one keeps the path scan.

**Printing.** A scalar result is printed as jq prints it, not as its source text (`1E2` is `1E+2`, `"\/"` is
`"/"`). A container is printed as jq prints it. In colour (a terminal, `-C`) it is built from the text and
then painted.

**Line-delimited input.** It needs no flag: the filter route detects it, and a path or a compact `.` over it
is answered in pieces on a `host.Batch_Pool` kept for the run. The pieces start with the first line. `stury
check --ndjson` validates the same lines with `validate_records`. `--jsonc` reads with `dialect = .Jsonc` and
prints answers as JSONC.

**Streams.** A pipe or an `--unbuffered` stdin is read by a thread in 64 KiB blocks, up to 8 MiB ahead, and
each window of whole lines that has come is answered before the next (line-delimited records run on the batch
pool).

## 10. Build-time options

These are `#config` defines, passed with `-define:NAME=value`. None is part of the library's contract.

| Define | Default | What it does | Who sets it |
| --- | --- | --- | --- |
| `REFUSE_DUPLICATES` | `true` | Compiles in the key-checking copy of each scan walk that `Duplicates.Refuse` needs. `false` drops it; `.Refuse` is then refused with `.Refuse_Compiled_Out` (`.Bad_Option` for `build`). | The CLI build (`make build-cli`) sets `false`; `make test-modes` also tests it. |
| `FORCE_AUTOMATON` | `false` | Compiles every single-name path to the general path matcher, so tests cross-check both matchers. | `make test-modes` |
| `SCAN_FORCE_SLOW` | `false` | Compiles out the optimised scanner routes so tests can compare them with scalar reference code. | `make test-modes` |
| `SCAN_WIDE` | `true` | Allows the AVX-512 string scanner. `false` keeps it unused, to time or test the x86-64-v2 routes on a machine that has AVX-512. | Nobody by default; used for timing and testing. |
| `SCAN_WIDE_512` | `true` | `false` sends an AVX-512 processor to the AVX2 block indexer instead. | Nobody by default; used for timing. |
| `BATCH_START_BUDGET_US` | `250` | The slowest thread start, in microseconds, before `host.Batch_Pool` pauses starting more helper threads. | `make test-tsan` sets 100000, since a sanitised, loaded host starts threads slowly. |
| `STURY_VERSION` | `"dev"` | The CLI's version string for `-V`. | `make build-cli` (the short commit hash, or `STURY_VERSION=` from the environment; the release workflow uses the tag). |
