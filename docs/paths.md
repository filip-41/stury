# Path queries

A path is a chain of steps from a value, and reading one gives an answer per value it reaches. This page covers what a
path is, what a read gives, how the one engine works, and how an answer gets a container's end. The guide's
[Scan by path](guide.md#scan-by-path) section shows the calls in use.

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

- `?` may follow any step. It drops a `Wrong_Kind` answer, as jq's empty does, and leaves `Missing` as it is. The
  mismatch of a `null` or an absent value with a `[]` still to come is that `[]`'s, so that `[]`'s `?` drops it.
- Three spellings parse to one `Path`: jq text, RFC 6901 JSON Pointer, and Odin step literals, such as
  `{Name("a"), Index(-1), All{}}`. Every parse error has a byte offset in the text. A name in either text is UTF-8, and
  an ill-formed sequence is `Bad_Path` at its first byte.
- A path holds one `Descend`, and a second is `Bad_Path`. jq's text spells it first only.
- `first(P)` and `limit(N; P)` wrap a path in its text. They count answers and give no more after the Nth.
- A parsed path owns its steps and decoded names in one block from an allocator, and a name with no escape borrows the
  text, so the text outlives the path. A document copies the names its path asked for and did not find, so the path can
  be destroyed once the read returns and only `src` outlives the document.
- `.` is the empty path, `Path{}`, and owns nothing. A zero `Step` and a negative `limit` are `Bad_Path`.
- Predicates are not paths: a caller who wants `select(.level == "error")` asks for `.level` and compares.

## The Answer record

```odin
Presence :: enum u8 { Found, Missing, Wrong_Kind, Not_Loaded }

Answer :: struct {
	node:    Node_Index, // the value a `.Found` reached, NO_NODE for the others
	owner:   Node_Index, // see below
	path:    u32,        // the path's number in the read
	outcome: Presence,
}
```

`owner` is the container the answer is about, as a node:

| Outcome | `owner` |
|---|---|
| `.Found` | the container holding the value, `NO_NODE` for the root |
| `.Missing` | the deepest container the path reached, the one lacking the member or element, or the `null` at the root |
| `.Wrong_Kind` | the value a step could not enter |

No path answers `Not_Loaded`, which only a read of a stopped document gives. `find` answers `Missing` with `owner`
`NO_NODE` for a path that gives no answer, as `.[]` of an empty array.

So `.config.host` answers `Missing` naming `config` when `config` has no `host`, and `Missing` naming the root when
there is no `config`. With `.config.host?`, it answers nothing when `config` is not an object.

A step on a `null` is `Missing`, as jq's `null.a` is `null`. A `[]` has nothing to enter in a `null` or in an absent
value, as jq's `null[]` fails, so with a `[]` still to come those are `Wrong_Kind`.

Everything else about a value is read from its node: `core.span(doc, a.node)` for its bytes, and the node's `kind`. A
caller who tests only the outcome pays for neither.

## Reading

A scan and a query are one operation. Reading paths gives a `Document` that holds only the nodes the paths reach, plus
the answers, and a full build is the same read with every node kept.

The entries are written once, in package `core/build`, over a handle. Each format keeps
`scan`, `find`, `each_answer` and `set` as forwarders that take the format's own `Spec` and `Options` and call the same
name in `core/build` with `as(spec, opts)`, so a caller who reads one format imports that format alone. `scan`,
`each_answer` and `query` are overload groups of a one-path form and a `[]core.Path` form, and the read options come
straight after the paths.

```odin
build.scan  :: proc(src: []u8, as: core.As, paths: core.Path | []core.Path, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error)
scan        :: proc(src: []u8, spec: Spec, paths: core.Path | []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error)
find        :: proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error)
each_answer :: proc(src: []u8, spec: Spec, paths: core.Path | []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error
query       :: proc(doc: ^core.Document, paths: core.Path | []core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Error)
set         :: proc(src: []u8, spec: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error)
```

| Name | Gives | Freed by |
|---|---|---|
| `scan` | a document and its answers, in text order | `core.destroy(&doc)`, which frees `doc.answers`, so no `delete(doc.answers)` |
| `find` | `scan` of one path with a limit of one: the document and its first answer, nil when the path gives none | `core.destroy(&doc)` |
| `each_answer` | no document: `on` gets each answer's path number, outcome, token and authored span | nothing |
| `query` | the answers over a built document, naming its nodes | the caller: `delete(answers, allocator)`. The document does not hold them |
| `set` | the new text of a build, one edit per answer and a commit | the caller: `delete(out, allocator)` |

`answers` and `next` give `each_answer`'s answers as a loop instead of a callback, in batches that start at one and double.

`read` is `Path_Options` for the reads that walk a text, and `Query_Options` for the ones that run over a built document:
`dups` alone, the option a built document can honour. `stop_early` is the walk's, so it does not compile in `query` or
in `set`. `set`'s `read` picks among a repeated key as `query` does, sets each repeat under `.All`, and under `.Refuse`
fails its build at a repeat.

With several paths, each path answers what it answers alone, and the answers are in one text order, the earlier path
first at one byte.

`on` keeps nothing and returns whether to go on, from any depth: a stop inside open containers ends the read there,
with no error. `each_answer` calls it as each answer becomes known. A `Token_Answer` holds the answer's `token`, its
`path` and `outcome`, and for a `.Found` its authored span `src[lo:hi]`, the bytes `core.span` gives for the same value.
For the other outcomes `lo` and `hi` are 0. A found container is known at its close, so one inside another comes first.
Under `.Last` the key of any `Name` on the way can repeat and take the answer back, so an answer goes out when the
shallowest `Name` of any path is past repeating: on `{"a":1,"y":{"b":2}}`, `.y.b` and `.a` both wait for the root's
close, since `y` could come again. A `Name` past a `Descend`, and a late path, give everything at the end.

A read takes up to `MAX_PATHS` (64) paths. More is `Over_Capacity`, and the caller splits the read or builds a document.

### Every element answers

A path through `[]` answers once per element it reaches, missing and wrong-kind ones included, as jq does: `.logs[].id`
gives a `Missing` for an element without `id` and a `Wrong_Kind` for one that is not an object. A library caller who
wants only found values drops the rest.

### Duplicate keys

`Duplicates`, the read's `dups`, decides when an answer is known. One implementation holds this, in the step logic.

- `.Last`, the default: each matching key replaces the candidate. The answer is known when the object closes.
- `.First`: the first matching key answers.
- `.All`: every matching key answers, in order.
- `.Refuse`: a repeated key is a fault at the repeat, in every object of the text, as `build` under `.Refuse` gives.

`All` and `Descend` reach every member, repeats included, under every rule.

### Stopping early

A scan judges all the text by default. `stop_early` (default false) returns `Stop` once every answer is known, so
nothing past that point is read or judged. `.Refuse` needs every key of the text in hand, so such a read builds
the whole text, ignores `stop_early`, and answers over the built document.

The answers are the same with and without `stop_early`. The scan stops where the answer is known: `.First` at the match,
and `.Last` at the close of the object holding the key, so a root key's read under `.Last` reads the whole root object.
A read that should stop at a key's first match asks for `.First`. Containers a stop leaves open are `Partial` with the
count read so far, and `Document.stopped` is set.

### Negative indexes

An array's length is known only at its close. The hook keeps the last `k` elements in a ring, where `k` is the largest
negative index or `Slice` end any armed path asks of that array, and a refused allocation for it is `No_Memory`. A path
with no negative step keeps no ring, and an index before the array's start is `Missing`. At the close the ring's elements a
path picks are given to the step logic again, oldest first, with their true indexes. A container in the ring is walked
again from its first byte through the format's `Rewalk`, so only those elements are read twice, and they were already
judged. A negative step or a `Descend` makes a path late: its answers can arrive out of text order, so a read sorts them,
and its limit cuts the sorted list.

### dsv

A dsv path addresses the tree its document has: `.[i]` is record `i`, `.[i].name` a cell by its header name, `.[i][j]`
cell `j`, `.[]` every record, negative indexes included. A headerless text has no names.

## The partial document

A partial document holds the answers and the containers on the way to them, and nothing else. `.logs[].id` keeps the root,
`logs`, each element, and each `id` whole, so an `id` that is an object is kept with all its nodes.

A container whose children were not all kept has the role `Partial` in place of `Value`, and its true child count is in
`Document.counts`. On a `Partial` container:

| Read | Gives |
|---|---|
| an index | exact, since the count is true: past the end is `Missing`. In a stopped read the count is what was read so far, so a position past it is `Not_Loaded` and `core.length_exact` returns `exact` false |
| a key a path asked for and did not find | `Missing`, from a list of `(container, name)` sorted by container |
| any other key | `Not_Loaded` |
| a key under `.Last` of a member kept by position | `Not_Loaded`, since a repeat of the key may lie past what was kept |

`member_of` and `element_of` give these answers as a `Presence`, and `Wrong_Kind` for a value that cannot take the read,
as a path's answer does. A `null` holds nothing, so it is `Missing`. The list of names a path asked for and did not find
is why `.config.host` with no `host` makes a later `member(config, "host")` say `Missing` as its answer did. `Not_Loaded`
is a document read's result and never an answer's outcome. To read more of `config`, ask for `.config` or for each member.

An edit names a node, so a `Not_Loaded` member cannot be edited, and `commit` refuses a partial document with `Bad_Index`.

`json.set(src, S, port, 8080)` and `dsv.set`, with `port` the parsed `.port`, build the text, record one edit per answer
and commit, in one call. A path that ends in a `Name` inserts it where it is missing, and one that ends in an `Index` equal
to its array's length appends there. A `?` on that last step passes a container not of its kind. A missing parent is
`Bad_Index` with the reason `.No_Parent`, a container not of the last step's kind `.Not_Object` or `.Not_Array`, and an
index past the length `Bad_Position`. See [edits.md](edits.md).

## The engine

One hook on the walk answers every path, in core, written once for every format. The walk knows nothing of paths: the
hook sees `Object`, `Array`, `Key` and value tokens and returns `Next`, `Skip` or `Stop`.

- Its state per depth is which step of which path is armed there. The step logic is written once and compiled two ways.
  One plain path, with no negative index and no `Descend`, is a step number and a depth, two registers. Several paths, and
  any path with a step or an option that form has no state for, also keep a bit set of armed paths per depth, the rings of
  negative indexes and the answers placed in text order. A plain path pays nothing for them.
- A `Name` step compares the `Key` token's span with the name: length, then the bytes, on the raw bytes when the key has
  no escape, decoded otherwise. No compare runs inside the walk: a name matches few keys, so one would be spent on nearly
  every key and save a scan only on a match.
- A member no path needs is skipped at its `Key`, so the walk reads a string or number value inline, and an element at
  its value's token. When every answer is known and `stop_early` is set, the hook returns `Stop`.
- A repeated key under `.Last` takes answers back. One path rewinds the lists and the nodes. Several cannot, since
  another path may have read past that point, so their answers are marked dead and their nodes stay with no answer
  naming them.

The step logic runs on two token sources: the walk's during a scan, and a document's during a query. `doc.nodes` is not
the walk's token stream, so `build.feed_nodes` feeds a hook from a document, restoring each `End` and each dsv key. The
typed read of an answer is another such hook: a caller reads an answer's value with `typed.unmarshal(&doc, answer, ...)`
([typed.md](typed.md)).

A query over a full document and a scan of the text give the same answers in the same order.

## What a format calls

A format gives the engine its walk through `Services.scan`, which switches once on the handle's spec and runs the walk
compiled for it with the hook the read needs. `core/build`'s `scan`, `find`, `each_answer` and `set` call it, and each
format's `query` calls the engine over a built document. A format writes no step logic.

## Errors

A public call returns a `core.Error`, where a walk fault is a `Fault`, a refused repeat under `.Refuse` a `Fault` with the
code `duplicate_key`, and a refused allocation `runtime.Allocator_Error.Out_Of_Memory`. Any other failure of a path is a
`Path_Error` with the code `path.` and the kind's code, as `path.bad_path`:

- **`Bad_Path`:** the path text or literal is not a path, with the byte offset in the text (0 for step literals) and the
  reason in `reason`, such as `.Unclosed_Bracket`.
- **`Over_Capacity`:** more than `MAX_PATHS` paths or `MAX_STEPS` steps.
- **`Unsupported`:** a query of a partial document or a handle with no format.

A missing value or a wrong kind is an answer's outcome, not an error. A `Bad_Path` renders in its own text,
`1:3: Invalid path ".a[": `[` is not closed`.

## A container's end

A scalar's end is on its node. A container's close is the one fact the 16-byte node does not store, so its end is
resolved only when a caller asks for its bytes, through `core.span` and the format's `close_end`:

- The root reads `Document.root_close`, which is O(1).
- A nested container costs one step per direct child and a byte scan of the closes on its rightmost spine. A path that
  answers with a scalar, or tests only a container's `kind`, pays nothing.
- A `Partial` container cannot use that scan, which would take the last kept descendant for the container's last. Each
  format's `close_end` walks the value again from its `lo` instead.
- A container a stopped read left open may run into text no walk judged, and a fault there ends its span at the fault's
  byte.
