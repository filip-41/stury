# Path queries

The next layer. A path is a chain of steps from a value, and reading one gives an answer per value it reaches. This
file is the layer's contract: what a path is, what a read gives, how the one engine works, and how an answer gets a
container's end. Nothing here is implemented yet.

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
| `Slice` | `.[2:5]` | a run of elements |
| `Descend` | `..` | the value and everything under it |

- `?` may follow any step. It drops a `Type_Mismatch` answer, as jq's empty does, and leaves `Missing` as it is.
- Three spellings parse to one `Path`: jq text, RFC 6901 JSON Pointer, and Odin step literals, such as
  `{Name("a"), Index(-1), All{}}`. Every parse error has a byte offset in the text.
- `first(P)` and `limit(N; P)` wrap a path in its text. They count answers and give no more after the Nth.
- A parsed path owns its steps and decoded names in one block from an allocator. A name with no escape borrows the
  text.
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
| `.Missing` | the deepest container the path reached, the one lacking the member or element |
| `.Type_Mismatch` | the value a step could not enter |

So `.config.host` answers `Missing` naming `config` when `config` has no `host`, and `Missing` naming the root when
there is no `config`. With `?`, it answers nothing when `config` is not an object.

An answer's outcome is always known, since the scan read the container it names. Everything else about a value is
read from its node: `core.span(doc, a.node)` for its bytes, and the node's `kind`. The node stays the one place these
live, and a caller who tests only the outcome pays for neither.

An `Answer` is a read result and holds no edit state. An edit names a node, and a path edit such as
`set(src, ".port", "8080")` is a scan, one edit and a commit in one call.

## Reading

A scan and a query are one operation. Reading paths gives a `Document` that holds only the nodes the paths reach, plus
the answers, and a full build is the same read with every node kept.

| Name | Gives |
|---|---|
| `query` | a document and its answers, in text order |
| `find(src, path)` | `query` of one path with a limit of one |
| `each_answer(src, paths, ctx, on)` | no document: `on` gets each answer's path number, outcome and token |

`on` keeps nothing and returns whether to go on. `each_answer` calls it as each answer becomes known, which under
`.Last` can differ from text order with several paths: on `{"a":1,"y":{"b":2}}`, `.y.b` is known when `y` closes, and
`.a` when the root closes. A found container's value is its authored span.

A read takes up to 64 paths. More is `Over_Capacity`, and the caller splits the read or builds a document.

### Every element answers

A path through `[]` answers once per element it reaches, missing and wrong-kind ones included, as jq does: `.logs[].id`
gives a `Missing` for an element without `id` and a `Type_Mismatch` for one that is not an object. A library caller who
wants only found values drops the rest.

### Duplicate keys

`Duplicates` decides when an answer is known. One implementation holds this, in the step logic.

- `.Last`: each matching key replaces the candidate. The answer is known when the object closes.
- `.First`: the first matching key answers.
- Every matching key answering, in order, is a path option and not a `Duplicates` member, since `member` could not take
  it.
- `refuse_duplicates`, a flag of the read as of `build`: a repeated key is a fault at the repeat, in every object the
  scan reads.

### Stopping early

A scan judges all the text by default. `stop_early` (default false) returns `Stop` once every answer is known, so
nothing past that point is read or judged. The answers are the same either way, and with it `refuse_duplicates` checks
only the objects read before the stop.

The read's argument is `dups: Maybe(Duplicates)`. Nil is `.Last`, or `.First` under `stop_early`, so a root key's scan
stops at its first match, which differs from `.Last` only on a text with a repeated key. Under a named policy the scan
stops where the answer is known: `.First` at the match, `.Last` at the close of the object holding the key, and a path
asking for every match or `refuse_duplicates` at the end of the text.

### Negative indexes

An array's length is known only at its close. The hook keeps the starts of the last `k` elements in a ring, where `k` is
the largest negative index any path asks of that array. `k` above 64 is `Over_Capacity`, and a path with no negative
index keeps no ring. At the close:

- A path that ends at the index answers the ring's token, with no second read.
- A path with steps after it walks that element again from its start with the rest of the path. Only that element is
  read twice, and it was already judged.

`walk(src, lo)` reads one value from any JSON value's first byte. A JSON string token's `lo` is the byte after its
opening quote, so the ring stores `lo - 1` for a token with `SPELLING_QUOTED`. A dsv walk from a record's `lo` would
read that record as the header, so its re-walk passes `no_header`, stops at the record's `End`, and maps each cell to
the header key the hook kept.

### dsv

A dsv path addresses the tree its document has: `.[i]` is record `i`, `.[i].name` a cell by its header name, `.[i][j]`
cell `j`, `.[]` every record, negative indexes included. A headed walk gives each cell its `Key` token, so the step
logic needs no dsv code. A headerless text has no names.

## The partial document

A partial document holds the answers and the containers on the way to them, and nothing else. `.logs[].id` keeps the
root, `logs`, each element, and each `id` whole, so an `id` that is an object is kept with all its nodes.

A container whose children were not all kept has the role `Partial` in place of `Value`. `Partial` sorts before `Key`
in `Role`, so a `role > .Key` fact test stays true to its meaning, and a test that means "a value" takes both.

A container's true child count comes from the walk and goes in a table keyed by node, which `Document.counts` already
is for a count past `CHILDREN_MAX`. On a `Partial` container:

| Read | Gives |
|---|---|
| an index | exact, since the count is true: past the end is `Missing` |
| a key a path asked for and did not find | `Missing`, from a list of `(container, name)` sorted by container |
| any other key | `Not_Loaded` |

A key lookup scans the kept nodes as on any container, and only a miss on a `Partial` container reads the list. The
list is why `.config.host` with no `host` makes a later `member(config, "host")` say `Missing` as its answer did. No
`Kind` is added and every node stays text-backed. `Not_Loaded` is a document read's result and never an answer's
outcome. To read more of `config`, ask for `.config` or for each member.

An edit names a node, so a `Not_Loaded` member cannot be edited. A `set` on a listed name is an insert into its
container, by name. A commit takes an edited container's members from the format's walk on every document, full or
partial, so a scan keeps nothing extra for edits.

## The engine

One hook on the walk answers every path, in core, written once for every format. The walk knows nothing of paths: the
hook sees `Map`, `Array`, `Key` and value tokens and returns `Next`, `Skip` or `Stop`.

- Its state per depth is which step of which path is armed there. For one path that is a step number and a depth, two
  registers. Several paths keep one `u64` bit set of armed paths per depth. Each form is its own instantiation, so one
  path pays nothing for many.
- A `Name` step compares the `Key` token's span with the name: length, then the first 8 bytes, then the rest, on the raw
  bytes when neither side has an escape, decoded otherwise.
- A member or element no path needs is skipped. When every answer is known and `stop_early` is set, the hook returns
  `Stop`.
- Each answer goes to a sink chosen at compile time: `query` uses the document sink, and `each_answer` the stream sink.

The step logic runs on two token sources: the walk's during a scan, and a document's during a query. `doc.nodes` is not
the walk's token stream: it holds no `End` node, a headed dsv record's `Key` tokens live in `doc.header`, and a
container's `n` and `spelling` are rewritten at its close. A replay in core feeds the step logic from a document,
restoring each `End` with a stack and each dsv key from `doc.header`.

A query over a full document, a scan of the text and a value-tree model give the same answers in the same order.

## Errors

`Path_Error` has its own kinds and holds the walk's `Fault` as its inner error: `Bad_Path` with the byte offset in the
path text, `Over_Capacity`, `No_Memory`. A missing value or a wrong kind is an answer's outcome, not an error.

## A container's end

A scalar's end is on its node. A container's close is the one fact the 16-byte node does not store, so its end is
resolved only when a caller asks for its bytes, through `core.span` and the format's `close_end`:

- The root reads `Document.root_close`, which is O(1).
- A nested container costs one step per direct child and a byte scan of the closes on its rightmost spine. A path that
  answers with a scalar, or tests only a container's `kind`, pays nothing.
- A `Partial` container cannot use that scan, which starts from the last kept descendant and takes it for the
  container's last, and a dsv record's line end has the same trap. Each format's `close_end` walks the value again from
  its `lo` instead. The text was judged, so the walk cannot
  fail, and no storage is spent on a span few callers ask for: an answer is kept whole, so only an ancestor on the way
  to an answer is `Partial`. A commit does not ask, since it reads an edited container's members from the walk.

Why this and not a wider record:

- The 16-byte token ties the old 32-byte row on object-heavy documents and halves array- and cell-heavy ones. Widening
  every token for a fact only containers need is the wrong trade.
- The root, which the CLI and the writer touch most, is O(1), and the writer's forward pass closes containers from `n`
  in preorder, so it needs no container's end.

If a benchmark shows nested spans dominate, add a sparse table of `(node, end)` sorted by node, one entry per container,
filled at the walk's `End`, and do not widen `Node`. A third option changes the record: `lo` as `u32` with the freed
bytes as `hi` gives every container an O(1) close at the price of a 4 GiB source cap.

## Open

These are settled by measurement, and a lane an arm loses goes to Filip:

- **The key compare and the skip.** The arms are the hook comparing the span and skipping at the value's container
  token with no walk change, the same plus a compare inside the walk before the key scan, and the same plus `Skip` on a
  `Key` reading a scalar value inline. `validate` and `build` compile none of it, so their instruction counts stay.
- **The replay against stored `End` nodes**, which every build and read lane would pay for.

One shape question is left: a `Token`'s `n` is `u32`, so `each_answer` cannot pass a found container past 4 GiB as a
token, and its `on` may need the span as `lo` and `hi`.
