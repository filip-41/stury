# Typed reads

A typed read fills an Odin value from a text during the walk, with no document between them. The format-neutral part is
package `core/typed`, which names no format. The guide's [Read into Odin values](guide.md#read-into-odin-values)
section shows the calls in use, and [writer.md](writer.md) covers `marshal`.

## Vocabulary

- **Plan**: one type's reading as an array of records, built once for a type and a format.
- **Record**: the `Field` that reads one member or element.
- **Target**: the value a read fills.
- **Refusal**: a value the target does not take, or a text the walk faults on.
- **Sink**: where a refusal goes. The default stops at the first, and a `Sink` reads on.

## Entries

```odin
json.unmarshal :: proc {unmarshal_once, unmarshal_plan}
unmarshal_once :: proc(src: []u8, $S: json.Spec, target: ^$T, opts := json.Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error
unmarshal_plan :: proc(src: []u8, $S: json.Spec, target: ^$T, plan: ^typed.Plan, opts := json.Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error

json.plan_make  :: proc(T: typeid, spec := json.Spec.Json, opts := json.Options{}, plan := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error)
typed.plan_make :: proc(T: typeid, as: core.As, opts := typed.Plan_Options{}, allocator := context.allocator) -> (typed.Plan, core.Error)
typed.plan_destroy :: proc(p: ^typed.Plan)

```

`dsv.unmarshal` and `dsv.plan_make` have the same shape over `dsv.Spec` and `dsv.Options`. `S` is a constant `.Json`, `.Jsonc` or `.Json5`, or for dsv `.Csv`, `.Tsv` or `.Plain`, and `opts` the walk's own options, as
for `build`. `reads` (`json.reads(S)`) lets the plan read a `core.Value`.

A built document is read by one call for every format, in `core/typed`:

```odin
typed.unmarshal :: proc {unmarshal_node, unmarshal_answer}
unmarshal_node   :: proc(doc: ^core.Document, node: core.Node_Index, target: ^$T, plan: ^Plan, read := Read_Options{}, allocator := context.allocator) -> core.Error
unmarshal_answer :: proc(doc: ^core.Document, answer: core.Answer, target: ^$T, plan: ^Plan, read := Read_Options{}, allocator := context.allocator) -> core.Error
```

## The plan

A plan is a value the caller owns, for one type and one format. There is no global cache. It is read only during a
read, so any number of reads may share one. `unmarshal_once` builds and frees a plan per call, and a program that reads
one type many times builds it once. A plan is not copied, since two copies free the same memory, and it outlives every
reader and writer given it. A plan for another type or format is `.Plan_Mismatch`, a nil target `.Bad_Option`.
`typed.plan_make(T, as)` builds the plan of format `as` by the format's own plan maker, `Services.plans`, so it is the
plan `json.plan_make` or `dsv.plan_make` gives. dsv's checks that the type is a list of rows or a row, and a dsv read
refuses a plan from `typed.plan_build`, the plan with nothing a format adds, as `.Plan_Mismatch`.

`Plan_Options` sets how enums are spelled (`enums`: `.Name` or `.Int`), the member that names a union's struct arm
(`union_tag`) and the names that replace the arms' type names (`tag_names`), the types read by the caller's procs
(`hooks`), and a field renaming for a field with no name in its tag (`rename`: `.Camel`, `.Pascal`, `.Kebab`, `.Screaming`
or `.Snake`). `plan_make` refuses a type it cannot read, with the path of member names to it: `.Unsupported`,
`.Ambiguous_Union` or `.Bad_Tag`. The refused plan holds that error in `err`, and a read or write given it returns it.

## Fields and tags

A field's tag is looked up under the format's key (`json`, `csv`), then under the shared key `stury`:

```odin
Item :: struct {
	id:    u64    `json:"item_id,required"`,
	note:  string `stury:"-"`,
	notes: map[string]typed.Raw `json:",unknown"`,
}
```

- The value is `name,flag,flag`. `-` leaves the field out. An empty name keeps the field's own, renamed by
  `Plan_Options.rename`. In the name a backslash makes the next byte literal, so a comma is `\,` and a backslash `\\`.
- `omitempty` and `omitunset` are writer flags, see [writer.md](writer.md), and a read accepts them and does nothing with
  them. `required` makes an absent member `.Missing_Field`, and `required` with either of them on one member is
  `.Unsupported`, since the write would leave out what the read then finds missing. `unknown` on a `map[string]typed.Raw` field
  captures every member the type does not name. `required` or any other flag on it is `.Bad_Tag`.
- An absent member keeps what the target holds. That is how defaults work: fill the target, then read.
- `Read_Options.unknown` is `.Ignore` or `.Refuse`, which makes a member the type does not name `.Unknown_Field`.
  Capture takes the member first.

## Types

| Target | Takes |
|---|---|
| `bool`, `b8`..`b64` | a bool |
| `i8`..`i64`, `u8`..`u64` | a number spelled as an integer, in range, else `.Above_Maximum` or `.Below_Minimum`. A fraction or exponent is `.Wrong_Kind` |
| `f32`, `f64` | any number, and JSON5's `Infinity` and `NaN` unless the walk refuses them with `refuse_non_finite`. A decimal past the type's range is `.Above_Maximum` or `.Below_Minimum`, and any other reads as the nearest value, however many digits or however large an exponent it has |
| `string`, `cstring` | a string |
| `Raw` | any value, as the format spells it |
| `core.Value` | any value, built as `core.built_value` builds a node, so a markup document's repeated name is an array and `.First` keeps a key's first member: a number past a double keeps its digits. A text's read needs the plan to hold its format's reads (`json.reads`), else `.Unsupported`, and a document's read takes the node |
| `Number_Text` | a number's text |
| `Bytes` | a byte string: a string of RFC 4648 base64 with padding in a text format, refused as `.Wrong_Kind` when it is not the one canonical spelling of some bytes, and a `Bytes` token's payload in a binary format, where a `String` token is `.Wrong_Kind` |
| `core.Number` | a number |
| `Scalar` | a scalar: `Null`, `bool`, `i64`, `u64`, `f64`, `Number_Text` or `string` |
| `any` | any value. A container is boxed as `map[string]any` or `[dynamic]any`, a scalar as its `Scalar` arm, `null` as nil |
| struct | an object, its members by name |
| `[]T`, `[dynamic]T`, `[N]T`, `[E]T`, `[dynamic; N]T` | an array. A fixed length that differs is `.Too_Few` or `.Too_Many`, and a fixed capacity passed is `.Too_Many` |
| `map[K]V` | an object. `K` is a string, an integer read from the key's text, or an enum |
| enum | a member's name, or its integer under `.Int`. Neither is `.Not_A_Member` |
| `bit_set` | an array of its element's names or numbers |
| `^T` | the element. An element the target already holds is read into, and `null` sets nil |
| `Maybe(T)` | the element, or `null` for none |
| union | the arm its value's class picks, or under `union_tag` the arm its tag names |
| a type in `Plan_Options.hooks` | any value, through the hook, so as a union's arm it takes every class and shares them with the other arms |

`plan_make` refuses `f16`, 128-bit integers, `rune` as a text, other-endian numbers, `#raw_union`, `#soa`, and the rest of
Odin's kinds that hold no data a text spells.

- `null` is a value for `^T`, `Maybe`, `any`, `Raw`, `cstring` (nil), `Number_Text` (empty), `Scalar`, a union with a nil, and a hook. Every
  other target refuses it as `.Wrong_Kind`, a struct, a list and a map included.
- Two arms of a union may not take one class of value. Named struct arms share objects only under `union_tag`, and no
  member of an arm may have its key. An object with no tag member is `.Missing_Tag`, with two `.Repeated_Tag`, and a name
  no arm has `.Not_A_Member`.
- A repeated member follows `Read_Options.dups`: `.Last` by default, `.First`, or `.Refuse`. `.All` is `.Bad_Option`.
  Under `.Last` a repeat that opens a struct, map or array, or fills a pointer, `Maybe`, union or `any`, resets the
  member first. `.First` still judges the later value against the type. `.Refuse` notes the keys of every object the
  read walks, skipped members included, and is `.Duplicate_Key` on any repeat anywhere in the text, as the only refusal.
- A path is not an entry: a text is read from its root, and a path's value from the answer it gave.

## Strings and who owns them

A string, `Raw`, `Number_Text`, `Bytes` and map key are copied with the read's allocator by default. `borrow_strings` makes a string
with nothing to decode, and a `Raw`, `Number_Text` or a binary format's `Bytes` not in chunks, a slice of `src`, so `src` must outlive the target. A string with an
escape is always decoded into the allocator, and `Bytes` from base64 text is always a copy, which the caller frees with `delete`.

The fastest form is an arena allocator with `borrow_strings`. To free the input after such a read, read without
`borrow_strings`, or clone `src` into the same arena first and read from the clone.

A read allocates lists, maps, pointers and strings with `allocator`. The read does not know what the target held, so it
frees only a string or map entry it stored itself and a later repeat replaces. Any other value a repeat replaces is left
to the allocator, and an arena is the advised allocator for any text not trusted to be free of repeats. `unmarshal` with no
plan builds its plan with `context.allocator` and frees it. A decoded key's text and an error's names go to
`context.temp_allocator`.

## Refusal

```odin
Typed_Error :: struct {
	kind:         Typed_Error_Kind,
	truncated:    bool,
	found:        Kind,
	cause:        io.Error,
	at:           u64,
	using detail: Typed_Detail, // inner: Fault, want: Typed_Want, plans: Plan_Clash, by kind
	steps:        []Step,
}
```

`Typed_Error` is the arm of `core.Error` a read or a write returns. A refusal allocates nothing until `core.error_of`
copies its path for the caller, to `context.temp_allocator`.

`at` is the value's byte, a string's opening quote for a string. `steps` is the path from the target, the innermost
`MAX_ERROR_STEPS` (8) when `truncated` says more were cut. `detail` holds by kind the `.Walk` fault in `inner`, the two
formats or the plan's type a `.Plan_Mismatch` met in `plans`, or `want` for the rest: the type a read wanted, `found` the
kind of the value, and the scalar's source text. `core.render` and `core.write_code` take the error, as they do every
other error of the library, and the path renders as path text, `.[0].population`. A write returns the same type, see
[writer.md](writer.md).

```
1:12: Expected i64, found string at .user_id
1:10: "Purple" is not a Color at .color
Field tag flag "string" is not one the field takes at .id
Plan is for json, the read is csv
```

| Kind | Means |
|---|---|
| `.Walk` | the text does not parse |
| `.Wrong_Kind` | a value the target's type does not read |
| `.Above_Maximum`, `.Below_Minimum` | a number past the greatest or the least value the target holds |
| `.Out_Of_Range` | a value other than a number past what the target holds: a map key that spells no integer, a cstring with a NUL |
| `.Not_A_Member` | a name or number no enum or union arm has |
| `.Too_Few`, `.Too_Many` | an element count a fixed array or capacity does not take |
| `.Wrong_Length` | a delimited row holds more cells than its type, or a second record where one row is read |
| `.Missing_Field` | a `required` member is absent, the last step names it |
| `.Unknown_Field` | a key the type does not name under `.Refuse` |
| `.Missing_Tag`, `.Repeated_Tag` | a union's tag member absent or repeated |
| `.Duplicate_Key` | `.Refuse` met a repeat. A text read returns it as a `Fault` of that kind, code `duplicate_key` |
| `.No_Memory` | the allocator failed |
| `.Bad_Option`, `.Plan_Mismatch` | a nil target, a plan for another type or format, at no byte |
| `.Unsupported`, `.Ambiguous_Union`, `.Bad_Tag` | `plan_make`'s refusals, at no byte |

The default sink stops at the first refusal. A refused read leaves the target partly filled: every list open at the
refusal holds its elements so far, so all the read allocated is reachable from the target. What a refused read left is
otherwise not a contract.

`Read_Options.sink`, a `Sink`, reads past a refusal. Each goes into `errors` (up to `max_errors`, 100 for 0), and the walk
passes over the refused value and still judges it. A member keeps what it held, and a list's element is zero. A `.Walk` fault ends the read. The returned
error is the first refusal. The caller frees the arrays with `sink_destroy`.

`check_text` reads the same way and adds a `core.Error_Entry` to `entries` for each refusal: its byte span, the record,
and the path with its names copied. It needs a plan of a format that has a check read.

## From a document

`typed.unmarshal` reads the value at a node, or the node a `.Found` answer names, with the plan and rules of a read of
a text: the same fields, tags, refusals, `Typed_Error` and sinks, and the same value for the same text. An
`Typed_Error`'s `at` is a byte of `doc.src`, whichever node was read. It is one call across formats. A format gives
it nothing but the handle `doc.as` its document holds.

- The plan must be built for the type of `target` and the document's format, else `.Plan_Mismatch`. A nil plan is
  one `typed.plan_make(T, doc.as)` builds and frees for the call. That needs a handle with services: a document built with
  `core.build(src, json.as(S))` takes a nil plan, and one built with `json.build(src, S)` gives `.Bad_Option`, so pass a
  plan from `json.plan_make`.
- `.Bad_Option` is a nil document, target or a document with no format, a node past the document or a key, an answer
  that is not `.Found`, and `.Refuse`. A document that holds no repeated key is built under `.Refuse`, and a repeat it
  kept reads by `Read_Options.dups`.
- A path's answer is read first and its value second, so there is no typed read at a path.
- A partial document reads like a whole one: a container a path kept only some children of reads as the container it
  has. Reading its root gives the kept members and elements, in order.

A read borrows `doc.src` and nothing of the document itself. With `borrow_strings` a string with nothing to decode is a
slice of `doc.src`, which must outlive the target. Every other string and every list, map and pointer is the read's
`allocator`'s, so the target outlives `core.destroy(&doc)`.

A delimited document reads as its text does, through `dsv`'s own hook, since a cell has no kind of its own: the value and
the refusals are those of `dsv.unmarshal` over the same text. The node read is the root, which reads as the list of rows,
or a record, which reads as a list of that one row. A cell is `.Unsupported`. A partial delimited document has no shared
keys: a headed record binds its columns from the keys beside the cells it kept, so a field no kept cell names keeps its
value.

For any other plan, the read is the hook of a read of a text, fed by `build.feed_nodes` from `doc.nodes`, which is how a
path query over a document is fed too.

## Hooks

```odin
Hook_Value :: struct {
	kind:    core.Kind,
	text:    string, // the value as the format spells it
	decoded: string, // a string's text decoded, `text` for any other kind
}
Unmarshal_Hook :: #type proc(v: Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind)
Marshal_Hook :: #type proc(v: rawptr, allocator: runtime.Allocator) -> (stand_in: any, refuse: core.Typed_Error_Kind)
Type_Hook :: struct { type: typeid, read: Unmarshal_Hook, write: Marshal_Hook, data: rawptr, carrier: typeid }
```

A hook reads one whole value of its type, containers included. `dest` holds what the target held. `text` and `decoded`
live for the call. A nil return reads the value, and a kind refuses it at the value's byte. A nil `read` or `write`
refuses the type on that side as `.Unsupported`. `data` is `context.user_ptr` during a call when it is not nil. `carrier`
is a type whose values are the values `read` takes, which a union's arm of the hook's type picks by, nil for a hook that
takes every value.

## The read

The read is a walk hook, `on_token`, on the same walks as `build`. Its state is three registers: the end of the open
list's capacity, the record that reads the next value, and the struct or list being filled.

- A plan's records sit in order, a struct's members then a `Never` record, so the record register moves one record per
  member in the type's order and a value needs no lookup. The walk compares a key's bytes against the expected record
  before the key scan and moves on a match. See [walk.md](walk.md).
- A key that misses reaches `on_key`, which finds the member by a linear pass behind a one-word filter and starts tracking
  which members were read.
- A number's digits fold into `Reader.mant` during the walk, which needs a hook field of that name.
- A kind past `F64` fails every hot compare and goes to `indirect`. A type that holds none of them pays nothing for
  them. Rare work is `@(cold)` and not inlined, and a value's open takes no call.
- Under `.First`, a repeat is read into scratch by `Plan.solo`'s records, so it is judged and dropped.

## What a format gives

A format supplies the walk, which calls the hook with the hook's registers, and its `Readers`: `tag_key`, the struct tag
key, `key_open` and `key_close`, what a key is written between, `key_bytes` and `binary` for a binary format, and `text`
and `close_end` for a read of a document. The entry builds a stack of `MAX_DEPTH + 2` frames and calls `read_start`, the
walk and `read_end`. A format with unquoted tokens handles them before the hook, which has no `.Plain` case, and one that
needs the original spelling of a number (JSON5) uses `on_token_spelled`.

## Delimited text

`dsv.unmarshal` reads a text into a slice or dynamic array of rows, over the same plan, frames, lists and refusals, or into
one row, which reads the first record and refuses a second as `.Wrong_Length` at its first byte, so a row reads back the
text `dsv.marshal` writes of it. A row is a struct whose fields the header names, a list of cells, or a map with string keys. `dsv.plan_make` refuses any other
`T` as `.Unsupported`, and a cell of a type with no text: nested containers, pointers, `any`, `Raw`, `Number_Text`, `Number`,
`Scalar`, `rune`, a union of more than one arm. `Maybe` of a cell type reads.

A cell has no kind of its own, so dsv reads it by its column's field, before the hook sees a token. The
columns are bound once, when the walk reaches the first record, or the text's end, so the header takes no second pass.

| Cell | Reads as |
|---|---|
| unquoted and empty | absent: the field stays zero, a list keeps a zero element, a map has no entry, and a `required` field is `.Missing_Field` |
| quoted and empty | present: an empty string, or a refused number or bool |
| integer | `[+-]?digits`, quoted or not. Past the field's range is `.Above_Maximum` or `.Below_Minimum`, other text `.Wrong_Kind` |
| float | `[+-]?(digits(.digits?)?\|.digits)([eE][+-]?digits)?` |
| bool | `true` or `false` |
| enum | its name, or with `enums = .Int` its value |
| string, `cstring`, hook | the cell's decoded text |

- With a header, a column no field names passes, or under `.Refuse` is `.Unknown_Field` at its header cell. A required
  field no column names is `.Missing_Field` at the header's first byte, ahead of any fault in the records.
- A repeated column reads as its last occurrence, as its first under `.First`, and `.Refuse` makes it `.Duplicate_Key` at
  the repeat.
- Under `.Ragged` a wide record's cell past the header's last is the column named by its 1-based position. A refusal for
  that column is at the header's first byte.
- `no_header` reads a struct's fields in order. A list row takes every record, with or without `no_header`. A map row
  needs a header, and `no_header` on one is `.Unsupported`, in a write as in a read.
- A text with a header and no record leaves an empty list, and a row as it was.
- A row's path is its index, then the field or key.

## Limits

- Depth is the walk's: `MAX_DEPTH`, or `Options.max_depth`. Past `MAX_DEPTH` the frames grow on the default heap with the
  depth the text reaches, not with its length.
- `.Refuse` builds a document on JSON, so it costs one on top of the read. dsv checks the header alone.
- Nothing is global: a read's state is its `Reader` and its frames.
