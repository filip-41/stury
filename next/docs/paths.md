# Path queries

A path is a chain of steps from a value, and reading one gives an answer per value it reaches. This file is the layer's
contract: what a path is, what a read gives, how the one engine works, and how an answer gets a container's end.

## Vocabulary

- **Step**: one link of a path.
- **Path**: a chain of steps, parsed from text or built from step literals.
- **Scan**: answering paths with a hook on the walk. The walk passes what the paths do not need and still judges it.
- **Query**: answering paths over a built `Document`.
- **Answer**: what a path gives for one value it reaches: found, missing, or the wrong kind.
- **Authored span**: the bytes of the source a value was written as. A JSON string's span includes its quotes, and a
  container's its brackets.

## Paths

| Step | jq text | Reaches |
|---|---|---|
| `Name` | `.a`, `."a-b"`, `.["a-b"]` | a member by its decoded key, so an escaped key matches its literal text |
| `Index` | `.[0]`, `.[-1]` | an element, negative from the end |
| `All` | `.[]` | every member or element |
| `Slice` | `.[2:5]` | a run of elements, one answer each, its ends clamped and each negative from the end |
| `Descend` | `..` | the value and everything under it, one to a path |
| `Index_Or_Name` | JSON Pointer's `/0` | a member of a map named by the token, an element of an array by its number |

- `?` may follow any step. It drops a `Type_Mismatch` answer, as jq's empty does, and leaves `Missing` as it is. The
  mismatch of a `null` or an absent value with a `[]` still to come is that `[]`'s, so that `[]`'s `?` drops it.
- Three spellings parse to one `Path`: jq text, RFC 6901 JSON Pointer, and Odin step literals, such as
  `{Name("a"), Index(-1), All{}}`. Every parse error has a byte offset in the text.
- `Slice` reads an array or a dsv record as `Index` does: on a `null` it is `Missing`, and on anything else a
  `Type_Mismatch`. Strings are not slices.
- A path holds one `Descend`, and a second is `Bad_Path`. jq's text spells it first only.
- `first(P)` and `limit(N; P)` wrap a path in its text. They count answers and give no more after the Nth.
- A parsed path owns its steps and decoded names in one block from an allocator, and a name with no escape borrows the
  text, so the text outlives the path. A document copies the names its path asked for and did not find, so only `src`
  outlives a document, and the path can be destroyed once the read returns.
- `.` is the empty path, `Path{}`, and owns nothing. A zero `Step`, which is a `Name` with no data pointer, and a
  negative `limit` are `Bad_Path`, as in a parsed path. A literal for the empty key needs a data pointer, which every
  parsed one has.
- Predicates are not paths: a caller who wants `select(.level == "error")` asks for `.level` and compares.

## The Answer record

```odin
Answer_Outcome :: enum u8 { Found, Missing, Type_Mismatch }

Answer :: struct {
	node:    Node_Index, // the value a `.Found` reached, NO_NODE for the others
	owner:   Node_Index, // see below
	path:    u32,        // the path's number in the read
	outcome: Answer_Outcome,
}
```

`owner` is the container the answer is about, as a node:

| Outcome | `owner` |
|---|---|
| `.Found` | the container holding the value, `NO_NODE` for the root |
| `.Missing` | the deepest container the path reached, the one lacking the member or element, or the `null` at the root |
| `.Type_Mismatch` | the value a step could not enter |

So `.config.host` answers `Missing` naming `config` when `config` has no `host`, and `Missing` naming the root when
there is no `config`. With `?`, it answers nothing when `config` is not an object.

A step on a `null` is `Missing`, as jq's `null.a` is `null`, and names the container holding the `null`. A `[]` has
nothing to enter in a `null` or in a value that is absent, as jq's `null[]` fails, so with a `[]` still to come a `null`
is `Type_Mismatch` naming itself and an absent member or element is `Type_Mismatch` naming its container.

An answer's outcome is always known, since the scan read the container it names. Everything else about a value is
read from its node: `core.span(doc, a.node)` for its bytes, and the node's `kind`. The node stays the one place these
live, and a caller who tests only the outcome pays for neither.

An `Answer` is a read result and holds no edit state. An edit names a node, and a path edit such as
`set(src, S, port, "8080")` with a parsed `.port` is a build, one edit and a commit in one call.

## Reading

A scan and a query are one operation. Reading paths gives a `Document` that holds only the nodes the paths reach, plus
the answers, and a full build is the same read with every node kept.

The entries of `json`, and of `dsv` with `dsv.Spec` and `dsv.Options`, and `core.query` for both. `scan`, `each_answer` and `query` are overload
groups of a one-path form and a `[]core.Path` form, and the read options come straight after the paths.

```odin
scan        :: proc(src: []u8, $S: Spec, paths: core.Path | []core.Path, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> (doc: core.Document, err: core.Path_Error)
find        :: proc(src: []u8, $S: Spec, path: core.Path, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> (doc: core.Document, answer: Maybe(core.Answer), err: core.Path_Error)
each_answer :: proc(src: []u8, $S: Spec, paths: core.Path | []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> core.Path_Error
core.query  :: proc(doc: ^core.Document, paths: core.Path | []core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Path_Error)
set         :: proc(src: []u8, $S: Spec, path: core.Path, text: string, read := core.Query_Options{}, opts := Options{}, refuse_duplicates := false, allocator := context.allocator) -> (out: []u8, err: core.Path_Edit_Error)
```

| Name | Gives | Freed by |
|---|---|---|
| `scan` | a document and its answers, in text order | `core.destroy(&doc)`, which frees `doc.answers`, so no `delete(doc.answers)` |
| `find` | `scan` of one path with a limit of one: the document and its first answer, nil when the path gives none | `core.destroy(&doc)` |
| `each_answer` | no document: `on` gets each answer's path number, outcome, token and authored span | nothing |
| `query` | the answers over a built document, naming its nodes | the caller: `delete(answers, allocator)`. The document does not hold them |
| `set` | the new text of a build, one edit per answer and a commit | the caller: `delete(out, allocator)` |

`read` is `Path_Options` for the reads that walk a text, and `Query_Options` for the ones that run over a built document:
`dups` and `every_key`, the two options a built document can honour. `stop_early` and `refuse_duplicates` are the walk's,
so they do not compile in `query` or in `set`, which takes `refuse_duplicates` as `build`'s own parameter. `set`'s `read`
picks among a repeated key as `query` does, and sets each repeat under `every_key`.

With several paths, each path answers what it answers alone, and the answers are in one text order, the earlier path
first at one byte.

`on` keeps nothing and returns whether to go on, from any depth: a stop inside open containers ends the read there,
with no error. `each_answer` calls it as each answer becomes known, in the order they
become known. A `Token_Answer` holds the answer's `token`, its `path` and `outcome`, and for a `.Found` its authored span
`src[lo:hi]`, the bytes `core.span` gives for the same value in every format: a string's quotes and a quoted cell's
quotes are inside it. For the other outcomes `lo` and `hi` are 0. A found container is known at its close, and `on` gets
it there, so one inside another comes first. Under `.Last` the key of any `Name` on the way can repeat and take the answer
back, so an answer goes out when the shallowest `Name` of any path is past repeating: on `{"a":1,"y":{"b":2}}`, `.y.b` and
`.a` both wait for the root's close, since `y` could come again. A `Name` past a `Descend` can repeat in any container, and
a late path's limit needs the text order, so those reads give everything at the end.

A read takes up to `MAX_PATHS` (64) paths. More is `Over_Capacity`, and the caller splits the read or builds a document.

### Every element answers

A path through `[]` answers once per element it reaches, missing and wrong-kind ones included, as jq does: `.logs[].id`
gives a `Missing` for an element without `id` and a `Type_Mismatch` for one that is not an object. A library caller who
wants only found values drops the rest.

### Duplicate keys

`Duplicates` decides when an answer is known. One implementation holds this, in the step logic.

- `.Last`: each matching key replaces the candidate. The answer is known when the object closes.
- `.First`: the first matching key answers.
- `every_key`, a read option and not a `Duplicates` member, since `member` could not take it: every matching key answers,
  in order.
- `refuse_duplicates`, a flag of the read as of `build`: a repeated key is a fault at the repeat, in every object the
  scan reads.

`All` and `Descend` reach every member, repeats included, under every rule.

### Stopping early

A scan judges all the text by default. `stop_early` (default false) returns `Stop` once every answer is known, so
nothing past that point is read or judged. `refuse_duplicates` needs every key of the text in hand, so such a read builds
the whole text, ignores `stop_early`, and answers over the built document.

The answers are the same either way on a text with no repeated key. The read's argument is `dups: Maybe(Duplicates)`, and
nil is `.Last`, or `.First` under `stop_early`, so a root key's scan stops at its first match and `{"a":1,"a":2}` gives
`.a` the value 1 with `stop_early` and 2 without it. A caller who wants the same answers sets `dups`. Under a named
policy the scan stops where the answer is known: `.First` at the match, and `.Last` at the close of the object holding
the key.
Containers a stop leaves open are `Partial` with the count read so far, and `Document.stopped` is set.

### Negative indexes

An array's length is known only at its close. The hook keeps the last `k` elements in a ring, where `k` is the largest
negative index or `Slice` end any armed path asks of that array. `k` above 64 is `Over_Capacity`, and a path with no
negative step keeps no ring. At the close the ring's elements a path picks are given to the logic again, oldest first,
with their true indexes, and each path picks up there as if it had reached the element in order. A scalar is the ring's
tokens and no second read. A container is walked again from its first byte, also for a path that ends at it, since an
answer is kept whole and a found container's end is not in its token. Only those elements are read twice, and they were
already judged. A path into a ring's element that another path also reached keeps its own copy of the element's nodes,
so a `Partial` array can hold a child twice, and `child_at` gives the first. Answers name the right nodes either way.

A `Slice` from the start with a negative end, `.[1:-1]`, knows an element is in it once `|end|` more have arrived, so the
element is given again at that moment.

`walk(src, lo)` reads one value from any JSON value's first byte. A dsv walk from a record's `lo` would read that record
as the header, so its re-walk passes `no_header`, stops at the record's `End`, and gives each cell the key the first walk
kept. A query reads the element's nodes again by the same replay.

A negative step or a `Descend` makes a path late: its answers can arrive out of text order, so a read sorts them, and
its limit cuts the sorted list.

### dsv

A dsv path addresses the tree its document has: `.[i]` is record `i`, `.[i].name` a cell by its header name, `.[i][j]`
cell `j`, `.[]` every record, negative indexes included. A headed walk gives each cell its `Key` token, so the step
logic needs no dsv code. A headerless text has no names. A partial document keeps a kept cell's key beside it, so it has
no `shared_keys`.

## The partial document

A partial document holds the answers and the containers on the way to them, and nothing else, but for the dead nodes
under a key that repeated in a read past one plain path: no answer names them, and a member lookup under `.Last` passes
them. `.logs[].id` keeps the
root, `logs`, each element, and each `id` whole, so an `id` that is an object is kept with all its nodes.

A container whose children were not all kept has the role `Partial` in place of `Value`. It is a node's role, never a
token's, and sorts last in `Role`, so the numbers the walk's tokens carry stay as they are.

A container's true child count comes from the walk and goes in a table keyed by node, which `Document.counts` already
is for a count past `MAX_CHILDREN`. On a `Partial` container:

| Read | Gives |
|---|---|
| an index | exact, since the count is true: past the end is `Missing`. In a stopped read the count is what was read so far, so a position past it is `Not_Loaded` and `core.length_exact` returns `exact` false |
| a key a path asked for and did not find | `Missing`, from a list of `(container, name)` sorted by container |
| any other key | `Not_Loaded` |
| a key under `.Last` of a member kept by position | `Not_Loaded`, since a repeat of the key may lie past what was kept |

`member_of` and `element_of` give these three answers as a `Presence`, and `Wrong_Kind` for a value that cannot take the
read, as the path's `.Type_Mismatch`: a name of a value that is no map, a position of one that is no array or positional
record, so a JSON map takes a name and a dsv record takes both. A `null` holds nothing, so it is `Missing`. An element a path reached by position is found
through `Document.kept`, which holds each kept child's true index, since its place among the kept nodes is not its
index.

A key lookup scans the kept nodes as on any container, and only a miss on a `Partial` container reads the list, of
`Missing_Name`s, whose names are copies the document owns. The
list is why `.config.host` with no `host` makes a later `member(config, "host")` say `Missing` as its answer did. No
`Kind` is added and every node stays text-backed. `Not_Loaded` is a document read's result and never an answer's
outcome. To read more of `config`, ask for `.config` or for each member.

An edit names a node, so a `Not_Loaded` member cannot be edited. `core.set_member` on a listed `Missing` name is an insert
after the container's last member, by name, and on a name no path looked for is `Bad_Index`.

`json.set(src, S, port, "8080")` and `dsv.set`, with `port` the parsed `.port`, are a build of the text, one edit per
answer and a commit in one call. A path that ends in a `Name` inserts it where it is missing. Any other answer that is no value, a mismatch or a missing
position or parent, is `Bad_Index`. The error is a `Path_Edit_Error` with one `kind`: `.Path` for the read of the path,
with `path` set, and `.Edit` for the build, the edit and the commit, with `edit` set.

`commit` refuses a partial document with `Bad_Index`, since it holds neither the members a commit composes nor their
comments.

## The engine

One hook on the walk answers every path, in core, written once for every format. The walk knows nothing of paths: the
hook sees `Map`, `Array`, `Key` and value tokens and returns `Next`, `Skip` or `Stop`.

- Its state per depth is which step of which path is armed there. `core/build/scan.odin` writes the step logic once, as
  `scan_step($MANY, $SINK, ...)`. `$MANY` false compiles it down to one plain path, of `Name`, `Index` from 0, `All` and
  `Index_Or_Name`, at step `d - 1`: a step number and a depth, two registers. Several paths, and any path with a step or an option
  that form has no state for, run it with `$MANY` true, and `core/build/many.odin` holds what only they need: one `u64`
  bit set of armed paths per depth, a `u64` of steps per depth for a `Descend` path, which can be at several steps of a
  container at once, the rings of negative indexes, the answers placed in text order and the stream. A plain path pays
  nothing for them.
- A `Name` step compares the `Key` token's span with the name: length, then the bytes, on the raw bytes when the key has
  no escape, decoded otherwise. No compare runs inside the walk: a name matches few keys, so one would be spent on nearly
  every key and save a scan only on a match.
- A member no path needs is skipped at its `Key`, so the walk reads a string or number value inline, and an element at
  its value's token. When every answer is known and `stop_early` is set, the hook returns `Stop`.
- Each answer goes to a sink chosen at compile time: `scan` uses the document sink, `each_answer` the stream sink, and
  a read of a built document the replay sink, which writes nothing.
- A repeated key under `.Last` takes answers back. One path rewinds the lists and the nodes. Several cannot, since
  another path may have read past that point, so their answers are marked dead and their nodes stay with no answer
  naming them.

The step logic runs on two token sources: the walk's during a scan, and a document's during a query. `doc.nodes` is not
the walk's token stream: it holds no `End` node, a headed dsv record's `Key` tokens live in `doc.shared_keys`, and a
container's `n` and `spelling` are rewritten at its close. `build.feed_nodes` feeds a hook from a document, restoring each
`End` with a stack and each dsv key from `doc.shared_keys`. The step logic is one hook of it, and the typed read of an
answer another (see `docs/typed.md`): a caller reads an answer's value with `typed.unmarshal(&doc, answer, ...)`.

A query over a full document, a scan of the text and a value-tree model give the same answers in the same order.

## What a format calls

A format's `scan` and `each_answer` are thin entries over `core/build`, and `core.query` reaches the engine through the
format's table. A format gives the engine its walk and its `Spelling`, and writes no step logic.

| Name | Does |
|---|---|
| `scan_start` | plans the read's paths into a `Scan`, on `frames` the entry holds on its stack, and takes `positional` for a format whose `Map` members answer an `Index` |
| `scan_hook`, `scan_hook_many`, `scan_hook_stream` | the hooks the entry passes its walk: one plain path, `Scan.many` into a document, and `each_answer` |
| `Rewalk`, `Scan.rewalk` | walks one value again from its first byte, for a ring's element, since only a format can walk from a value |
| `scan_end` | turns the walk's end into the document and its answers, and frees everything on an error |
| `query`, `query_built` | answers paths over a built document, the second for a read with `refuse_duplicates` |
| `set_answers` | one edit per answer and a commit, behind `set` |

`scan_reserve` and `scan_kept` are the engine's own, public since the hooks inline into a format's
walk.

## Errors

`Path_Error` has its own kinds and holds the walk's `Fault` as its inner error: `Bad_Path` with the byte offset in the
path text, `Over_Capacity` for more than `MAX_PATHS` paths, `MAX_STEPS` steps or a negative index past its ring,
`No_Memory`. A missing value or a wrong kind is an answer's outcome, not an error. `path` is the number in the read of the
path a `Bad_Path` or a step's `Over_Capacity` names.

`at` is a byte of the path's text for `Bad_Path` and of the source for `Walk` and `Duplicate_Key`. `Path_Edit_Error` has one `kind`: `.Path` holds the read's error in `path`, and `.Edit` the build's, the edit's or the
commit's in `edit`. `core.render` and `core.write_code` take a `Path_Error` or a `Path_Edit_Error`, and `render` takes the source and the path's text, so
the caller never tests the kind to choose the text. A `Path` built from step literals has no text, and `""` stands for it.

## A container's end

A scalar's end is on its node. A container's close is the one fact the 16-byte node does not store, so its end is
resolved only when a caller asks for its bytes, through `core.span` and the format's `close_end`:

- The root reads `Document.root_close`, which is O(1).
- A nested container costs one step per direct child and a byte scan of the closes on its rightmost spine. A path that
  answers with a scalar, or tests only a container's `kind`, pays nothing.
- A `Partial` container cannot use that scan, which starts from the last kept descendant and takes it for the
  container's last, and a dsv record's line end has the same trap. Each format's `close_end` walks the value again from
  its `lo` instead, tolerating every fault, since the read may have tolerated any. No storage is spent on a span few
  callers ask for: an answer is kept whole, so only an ancestor on the way to an answer is `Partial`. A commit does not
  ask, since it builds the text.
- A container a stopped read left open may run into text no walk judged, and a fault there ends its span at the fault's
  byte.

Why this and not a wider record:

- The 16-byte token ties the old 32-byte row on object-heavy documents and halves array- and cell-heavy ones. Widening
  every token for a fact only containers need is the wrong trade.
- The root, which the CLI and the writer touch most, is O(1), and the writer's forward pass closes containers from `n`
  in preorder, so it needs no container's end.

If a benchmark shows nested spans dominate, add a sparse table of `(node, end)` sorted by node, one entry per container,
filled at the walk's `End`, and do not widen `Node`. A third option changes the record: `lo` as `u32` with the freed
bytes as `hi` gives every container an O(1) close at the price of a 4 GiB source cap.
