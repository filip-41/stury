# Typed reads

A typed read fills an Odin value from a text during the walk, with no document between them. This file is the layer's
contract: what a plan is, the entries, how fields and types read, who owns a string, what a refusal does, and what a
format gives. `core/typed` holds everything format-neutral and names no format.

## Vocabulary

- **Plan**: one type's reading as an array of records, built once for a type and a format.
- **Record**: the `Field` that reads one member or element.
- **Target**: the value a read fills.
- **Refusal**: a value the target does not take, or a text the walk faults on.
- **Sink**: where a refusal goes. The default stops at the first, and a `Collected` reads on.

## Entries

```odin
json.unmarshal :: proc {unmarshal_once, unmarshal_plan}
unmarshal_once :: proc(src: []u8, $S: json.Spec, target: ^$T, read := typed.Read_Options{}, opts := json.Options{}, allocator := context.allocator) -> core.Unmarshal_Error
unmarshal_plan :: proc(src: []u8, $S: json.Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, opts := json.Options{}, allocator := context.allocator) -> core.Unmarshal_Error

json.plan_make  :: proc(T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (typed.Plan, core.Unmarshal_Error)
typed.plan_make :: proc(T: typeid, spelling: ^core.Spelling, opts := typed.Plan_Options{}, allocator := context.allocator) -> (p: typed.Plan, err: core.Unmarshal_Error)
typed.plan_destroy :: proc(p: ^typed.Plan)

dsv.unmarshal :: proc {unmarshal_once, unmarshal_plan}
unmarshal_once :: proc(src: []u8, $S: dsv.Spec, target: ^$T, read := typed.Read_Options{}, opts := dsv.Options{}, allocator := context.allocator) -> core.Unmarshal_Error
unmarshal_plan :: proc(src: []u8, $S: dsv.Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, opts := dsv.Options{}, allocator := context.allocator) -> core.Unmarshal_Error

dsv.plan_make :: proc(T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (typed.Plan, core.Unmarshal_Error)
```

`S` is `.Json`, `.Jsonc` or `.Json5`, or for dsv `.Csv`, `.Tsv` or `.Plain`, and `opts` the walk's own options, as for
`build`. The argument order follows the path entries.

A built document is read by one call for every format, in `core/typed`:

```odin
typed.unmarshal :: proc {unmarshal_node, unmarshal_answer}
unmarshal_node   :: proc(doc: ^core.Document, node: core.Node_Index, target: ^$T, plan: ^Plan, read := Read_Options{}, allocator := context.allocator) -> core.Unmarshal_Error
unmarshal_answer :: proc(doc: ^core.Document, answer: core.Answer, target: ^$T, plan: ^Plan, read := Read_Options{}, allocator := context.allocator) -> core.Unmarshal_Error
```

See From a document below.

## The plan

A plan is a value the caller owns, for one type and one format. There is no global cache. It is read only during a
read, so any number of reads may share one. `unmarshal_once` builds and frees a plan per call, and a program that reads
one type many times builds it once. A plan for another type or format is `.Plan_Mismatch`, a nil target `.Bad_Option`. A dsv read takes only a plan from
`dsv.plan_make`, which checks that the type is a list of rows, and a plan from `typed.plan_make` is `.Plan_Mismatch`.

```odin
Plan_Options :: struct {
	enums:     Enum_Spelling, // .Name reads a member's name, .Int its backing integer
	union_tag: string,        // the member that names a struct arm of a union
	tag_names: []Tag_Name,    // names that replace the arms' type names
	hooks:     []Type_Hook,   // types read by the caller's proc
	rename:    Rename,        // .None, .Camel, .Pascal, .Kebab or .Screaming, for a field with no name in its tag
}
```

`plan_make` refuses a type it cannot read, with the path to it: `.Unsupported`, `.Ambiguous_Union` or `.Bad_Tag`. The
strings and slices of `opts` are read during the call only.

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
- `omitempty` is a writer's flag and is accepted. `required` makes an absent member `.Missing_Field`. `unknown` on a
  `map[string]Raw` field captures every member the type does not name. Any other flag is `.Bad_Tag`.
- An absent member keeps what the target holds. That is how defaults work: fill the target, then read.
- `Read_Options.unknown` is `.Ignore` or `.Refuse`, which makes a member the type does not name `.Unknown_Field`.
  Capture takes the member first.

## Types

| Target | Takes |
|---|---|
| `bool`, `b8`..`b64` | a bool |
| `i8`..`i64`, `u8`..`u64` | a number spelled as an integer, in range, else `.Out_Of_Range`. A fraction or exponent is `.Wrong_Kind` |
| `f32`, `f64` | any number. Past the type's range is `.Out_Of_Range` |
| `string`, `cstring` | a string |
| `Raw` | any value, as the format spells it |
| `Number_Text` | a number's text |
| `core.Number` | a number |
| `Scalar` | a scalar: `Null`, `bool`, `i64`, `u64`, `f64`, `Number_Text` or `string` |
| `any` | any value. A container is boxed as `map[string]any` or `[dynamic]any`, a scalar as its `Scalar` arm, `null` as nil |
| struct | an object, its members by name |
| `[]T`, `[dynamic]T`, `[N]T`, `[E]T`, `[dynamic; N]T` | an array. A fixed length that differs is `.Wrong_Length`, and a fixed capacity passed is too |
| `map[K]V` | an object. `K` is a string, an integer read from the key's text, or an enum |
| enum | a member's name, or its integer under `.Int`. Neither is `.Not_A_Member` |
| `bit_set` | an array of its element's names or numbers |
| `^T` | the element. An element the target already holds is read into, and `null` sets nil |
| `Maybe(T)` | the element, or `null` for none |
| union | the arm its value's class picks, or under `union_tag` the arm its tag names |
| a type in `Plan_Options.hooks` | any value, through the hook, so as a union's arm it takes every class and shares them with the other arms |

Refused at the plan: `f16`, 128-bit integers, `rune` as a text, other-endian numbers, `#raw_union`, `#soa`, a list or
fixed array whose element has no size, and the rest of Odin's kinds that hold no data a text spells.

- `null` is a value for `^T`, `Maybe`, `any`, `Raw`, `cstring` (nil), `Scalar`, a union with a nil, and a hook. Every
  other target refuses it as `.Wrong_Kind`, a struct, a list and a map included.
- Two arms of a union may not take one class of value. Named struct arms share objects only under `union_tag`, whose
  member the arms may not declare. An object with no tag member is `.Missing_Tag`, with two `.Repeated_Tag`, and a name
  no arm has `.Not_A_Member`.
- A repeated member follows `Read_Options.dups`: `.Last` when nil, `.First`, or `.Refuse` through `refuse_duplicates`.
  `.First` still judges the later value against the type. `refuse_duplicates` reads the whole text once first, into a
  temporary document, and is `.Duplicate_Key` on any repeat anywhere in it, skipped members included.
- A path is not an entry: a text is read from its root, and a path's value from the answer it gave.

## Strings and who owns them

A string, `Raw`, `Number_Text` and map key are copied with the read's allocator by default. `borrow_strings` makes a string
with nothing to decode, and a `Raw` or `Number_Text`, a slice of `src`, so `src` must outlive the target. A string with an
escape is always decoded into the allocator.

The fastest form is an arena allocator with `borrow_strings`. To free the input after such a read, or to keep a read's
strings independent of a large buffer, read without `borrow_strings`, or clone `src` into the same arena first and read
from the clone: the arena then owns everything, and a single free ends both.

A read allocates lists, maps, pointers and strings with `allocator`, and frees none of them. The read does not know
what the target held, so an element replaced by a later repeat is left to the allocator, and an arena is the advised
allocator for any text not trusted to be free of repeats.

## Refusal

```odin
Unmarshal_Error :: struct {
	kind:      Unmarshal_Error_Kind,
	truncated: bool,
	n_steps:   u8,
	at:        u64,
	inner:     Fault,
	steps:     [MAX_ERROR_STEPS]Step,
}
```

`at` is the value's byte, a string's opening quote for a string. `steps[:n_steps]` is the path from the target, the
innermost `MAX_ERROR_STEPS` (8) when `truncated` says more were cut. `.Walk` holds the walk's fault in `inner`. A step's
name lives as long as `src` or the plan, or, for a decoded key, as long as `context.temp_allocator`'s block.
`core.render` and `core.write_code` take the error, as they do every other error of the library.

| Kind | Means |
|---|---|
| `.Walk` | the text does not parse |
| `.Wrong_Kind` | a value the target's type does not read |
| `.Out_Of_Range` | a value past what the target holds |
| `.Not_A_Member` | a name or number no enum or union arm has |
| `.Wrong_Length` | an element count a fixed array or capacity does not take |
| `.Missing_Field` | a `required` member is absent, the last step names it |
| `.Unknown_Field` | a key the type does not name under `.Refuse` |
| `.Missing_Tag`, `.Repeated_Tag` | a union's tag member absent or repeated |
| `.Duplicate_Key` | `refuse_duplicates` met a repeat |
| `.Out_Of_Memory` | the allocator failed |
| `.Bad_Option`, `.Plan_Mismatch` | a nil target, a plan for another type or format, at no byte |
| `.Unsupported`, `.Ambiguous_Union`, `.Bad_Tag` | `plan_make`'s refusals, at no byte |

The default sink stops at the first refusal. A refused read leaves the target partly filled: every list open at the
refusal holds its elements so far, so all the read allocated is reachable from the target. What a refused read left is
otherwise not a contract.

```odin
Collected :: struct {
	errors:     [dynamic]core.Unmarshal_Error,
	max_errors: int,  // 100 for 0
	truncated:  bool, // set past max_errors
}
```

`Read_Options.collect` reads past a refusal. Each goes into `errors`, and the walk passes over the refused value and
still judges it. A member keeps what it held, and a list's element is zero. A `.Walk` fault ends the read. The returned
error is the first refusal. The caller frees `errors`, which uses its own allocator, the read's when it has none.

## From a document

`typed.unmarshal` reads the value at a node, or the node a `.Found` answer names, with the plan and rules of a read of
a text: the same fields, tags, refusals, `Unmarshal_Error` and sinks, and the same value for the same text. An
`Unmarshal_Error`'s `at` is a byte of `doc.src`, whichever node was read. It is one call across formats. A format gives
it nothing but the `Spelling` its document holds.

- The plan must be built for the type of `target` and the document's `Spelling`, else `.Plan_Mismatch`.
- `.Bad_Option` is a nil document, target or a document with no spelling, a node past the document or a key, an answer
  that is not `.Found`, and `refuse_duplicates`. A document that holds no repeated key is built with
  `refuse_duplicates`, and a repeat it kept reads by `Read_Options.dups`.
- A path's answer is read first and its value second, so there is no typed read at a path.
- A partial document reads like a whole one: a container a path kept only some children of reads as the container it
  has. Reading its root gives the kept members and elements, in order.

A read borrows `doc.src` and nothing of the document itself. With `borrow_strings` a string with nothing to decode is a
slice of `doc.src`, which must outlive the target. Every other string, a decoded one included, and every list, map and
pointer is the read's `allocator`'s. So the target outlives `core.destroy(&doc)`, and a document is destroyed as soon as
its values are read.

A delimited document reads as its text does, through `dsv`'s own hook, since a cell has no kind of its own: the value is
the one `dsv.unmarshal` gives over the same text, and a refusal the same refusal. The format gives it as
`Plan.node_read`, which `dsv.plan_make` sets and `typed.unmarshal` calls for a plan of the document's format. The node read is the root, which reads as
the list of rows, or a record, which reads as a list of that one row. A cell is `.Unsupported`, since `dsv.plan_make`
refuses a type that is no list of rows. A list of rows reads the header row as its first row, as the text does.

A partial delimited document has no shared keys. A headed record binds its columns from the keys beside the cells it
kept, so a field no kept cell names keeps its value. A record kept by position reads a cell it did not keep as an empty
unquoted one, which is absent, and a list row holds it as an empty string.

For a plan without `node_read`, the read is the hook of a read of a text, fed by `build.feed_nodes` from `doc.nodes`. The replay restores each `End` from a
stack of container ends and each key a record shares from `doc.shared_keys`, which is how a path query over a document
is fed too. The read gives the hook what the walk would have: a partial container is a value, a close has its bracket's
byte where a refusal, a `required` check or a value read whole reads it, and a plain number has its digits folded in
`Reader.mant`. A union that reads by its tag finds the member by replaying the object alone.

## Hooks

```odin
Hook_Value :: struct {
	kind:    core.Kind,
	text:    string, // the value as the format spells it
	decoded: string, // a string's text decoded, `text` for any other kind
}
Unmarshal_Hook :: #type proc(v: Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Unmarshal_Error_Kind)
Type_Hook :: struct { type: typeid, read: Unmarshal_Hook }
```

A hook reads one whole value of its type, containers included. `dest` holds what the target held. `text` and `decoded`
live for the call. Nil reads the value, and a kind refuses it at the value's byte.

## The read

The read is a walk hook, `on_token`, on the same walks as `build`. Its state is in `Hook_Regs`:

| Register | Holds |
|---|---|
| `a` | one past a list's capacity, or `NO_LIMIT` outside a list, so one compare guards every value |
| `b` | the record after the one that reads the next value |
| `c` | the struct being read, or the list's next element |

- A plan's records sit in order, a struct's members then a `Never` record, so `b` moves one record per member in the
  type's order and a value needs no lookup. `Reader.expect` tells the walk that `b` points at an `Expected_Key` record:
  the walk compares a key's bytes against it before the key scan and moves `b` on a match. See `docs/walk.md`.
- A key that misses reaches `on_key`, which finds the member by a linear pass behind a one-word filter (`Meta.names`)
  and starts tracking which members were read, in `Frame.seen`. Until then the cursor says.
- A number's digits fold into `Reader.mant` during the walk, which needs a hook field of that name. The store is hot
  for `i64`, `u64`, `f64` and the smaller integers.
- A kind past `F64` fails every hot compare and goes to `indirect`. A type that holds none of them pays nothing for
  them, and neither does a type with no out-of-order key. Rare work is `@(cold)` and not inlined, and a value's open
  takes no call.
- Under `.First`, a repeat is read into scratch by `Plan.solo`'s records, so it is judged and dropped.
- `Frame.owner` and `Frame.target` say where a container's list header goes when a wrapper (`Ptr`, `Maybe`, union,
  `any`) holds it, so the hot close stays a struct's or a list's.

## What a format gives

| Piece | Purpose |
|---|---|
| `Spelling.tag_key` | the format's struct tag key |
| `Spelling.key_open`, `key_close` | what a key is written between, empty for a format whose keys the hook finds itself |
| a walk calling `$on` with `Hook_Regs` | tokens. `expect` and `mant` on the hook are used when the format's walk has them |
| `find_tag` on the `Reader` | the member `union_tag` of an object at a byte, by a walk with `on_tag_token` |
| an entry | builds a stack of `MAX_DEPTH + 2` `Frame`s, calls `read_start`, the walk and `read_end` |
| `Spelling.text`, `close_end` | a decoded string, and a container's closing byte, for a read of a document |

A format with unquoted tokens handles them before the hook, which has no `.Plain` case. A format that needs the
original spelling of a number (JSON5) uses `on_token_spelled`.

## Delimited text

`dsv.unmarshal` reads a text into a slice or dynamic array of rows, over the same plan, frames, lists and refusals. A row
is a struct whose fields the header names, a list of cells, or a map with string keys. `dsv.plan_make` refuses any other
`T` as `.Unsupported`, and a cell of a type with no text: nested containers, pointers, `any`, `Raw`, `Number_Text`, `Number`,
`Scalar`, `rune`, a union of more than one arm. `Maybe` of a cell type reads.

A cell has no kind of its own, so `dsv/typed.odin` reads it by its column's field, before the hook sees a token. The
columns are bound once, when the walk reaches the first record, or the text's end, so the header takes no second pass.

| Cell | Reads as |
|---|---|
| unquoted and empty | absent: the field stays zero, a list keeps a zero element, a map has no entry, and a `required` field is `.Missing_Field` |
| quoted and empty | present: an empty string, or a refused number or bool |
| integer | `[+-]?digits`, quoted or not. Past the field's range is `.Out_Of_Range`, other text `.Wrong_Kind` |
| float | `[+-]?(digits(.digits?)?\|.digits)([eE][+-]?digits)?` |
| bool | `true` or `false` |
| enum | its name, or with `enums = .Int` its value |
| string, `cstring`, hook | the cell's decoded text |

- With a header, a column no field names passes, or under `.Refuse` is `.Unknown_Field` at its header cell, its name
  as spelled. A required field no column names is `.Missing_Field` at the header's first byte, ahead of any fault in the
  records.
- A repeated column reads as its last occurrence, as its first under `.First`, and `refuse_duplicates` makes it
  `.Duplicate_Key` at the repeat.
- `no_header` reads a struct's fields in order. A list row takes every record, with or without `no_header`. A map row
  needs a header, and `no_header` on one is `.Unsupported`.
- A text with a header and no record leaves an empty list. A text with no header line where one is wanted leaves the
  target as it was.
- A row's path is its index, then the field or key. Two faults in one row refuse by the first in the text, since a cell
  is read as the walk passes it.
- A row keeps the cells read before a walk's fault, so a refused read's allocations stay reachable from the target.
- A map row's keys are owned per map unless the read borrows, as JSON's are. A decoded key is always a copy.

## Limits

- Depth is the walk's: `MAX_DEPTH`, or `Options.max_depth` with frames from `context.temp_allocator`.
- A struct tracks 63 members in a word and the rest in a block from the read's allocator, allocated only when a key
  arrives out of order past the 63rd.
- `.First` on a map tracks keys in a temporary map.
- `refuse_duplicates` builds a document on JSON, so it costs one on top of the read. dsv checks the header alone.
- Nothing is global: a read's state is its `Reader` and its frames.
