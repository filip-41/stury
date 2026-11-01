# Path queries

The next layer. A path is a chain of steps from a value; its answer is the value's span, the node it names, and how
the path landed. This file records the plan and the one storage decision the later layers depend on: how a path answer
gets a container's end.

Nothing here is implemented yet. `core/answer.odin`, `core/path_parse.odin` and `core/row_query.odin` in the old tree
are the reference model.

## Vocabulary

- **Step**: `Name` (decoded key text), `Index` (signed array position), or `Any` (every member or element).
- **Path**: a borrowed `[]Step`, a `limit` on found answers, and `per_element` for `Any` steps that answer once per
  element.
- **Answer**: one path's result over one document.
- **Authored span**: the bytes of the source a value was written as. A JSON string's span includes its quotes; a
  container's includes its brackets.

## The Answer record

```odin
Answer_Outcome :: enum u8 { Found, Missing, Type_Mismatch }

Answer :: struct {
	lo:      u64,            // the value's first authored byte
	hi:      u64,            // one past for a scalar; 0 for a container (see below)
	owner:   u64,            // the container the answer is about; NO_OWNER for the root or a miss
	query:   u32,            // the caller's path index
	node:    Node_Index,     // NO_NODE for a miss
	outcome: Answer_Outcome,
	kind:    Kind,
}
```

- `lo` is the value's first authored byte: a quoted string's opening quote, or a container's opening bracket.
- `hi` is one past its last authored byte. For an unquoted scalar it is `lo + n`; a quoted string's token leaves
  out its two quotes, so its `hi` is `lo + n + 2`. For a container it is **0**: the end is resolved by `answer_span`
  when the caller asks for bytes, because a container's close is the one fact the 16-byte node does not store. A caller
  that only needs a container's `node` or `kind` never pays for it.
- `owner` is the container the answer is about: the one holding a found value, the one lacking a missing member, or
  the one whose kind a step could not enter. It is `NO_OWNER` for the root and for a miss owed by the whole document.
- `query` indexes the caller's paths, 0 when a format answers one.
- `node` is the document node the path named, or `NO_NODE` for a miss.
- `outcome` is `.Found`, `.Missing` or `.Type_Mismatch`; `kind` is a found value's kind.

`answer_span(doc, a)` returns a scalar's `src[a.lo:a.hi]`, and a container's `core.span(doc, a.node)`; the root uses
`Document.root_close` and is O(1). A caller that only prints a scalar or tests a kind never calls it.

### The nested close decision

A scalar answer needs no scan: its end is `lo + n`. A container answer needs the byte just past its close, which the
16-byte node does not store. The decision for this layer is:

**Resolve a nested container's `hi` lazily, through `core.span`/the format's `close_end`, only when the caller asks
for bytes.** The root is the exception: `Document.root_close` stores one past the root value's authored bytes, so
`span(ROOT)` and a whole-document writer are O(1). A path that answers with a scalar pays nothing. A path that answers
with a nested container and then asks for its bytes pays one scan of that container's direct children; a path that
answers only for the value's identity or `kind` pays nothing.

Why this and not a wider record:

- The 16-byte token is the better storage base: it ties the old 32-byte row on object-heavy documents and halves
  array- and cell-heavy ones. Widening every token for a fact only containers need is the wrong trade.
- The root, which the CLI and writer touch most, is O(1) through `root_close`.
- The writer's forward pass closes containers from `n` in preorder and does not need a container's `hi` at all.

If a path or writer benchmark shows nested container spans dominate, add a sparse side table; do not widen `Node`:

```odin
Close :: struct { node: Node_Index, end: u64 } // 12-16 bytes per container
Document.closes: []Close                      // sorted by node
```

Fill it in the builder's `End` branch from `t.lo + t.n`, sort it in `builder_end`, and binary-search it from `span` and
the answer path. It costs one table entry per container, not per token. This is the preferred fix if lazy spans are not
enough.

A third option exists and is recorded here because it changes the record: **cut `lo` from `u64` to `u32` and use the
freed four bytes for `hi`.** The node stays 16 bytes, a container's close is then O(1) in the record, and no side table
is needed. The price is a 4 GiB source cap, as the old 32-byte row has. It is the fallback if a container answer must
be O(1) for every value and the project accepts the smaller source limit; it is not the current choice.

## Reading

- A path resolves over a built `Document` through the readers (`kind`, `children`, `child_at`, `member`, `length`,
  `span`) or over a single `walk` when the caller wants to stop early. The walk is the only way to answer without
  building a document; the document is the way to answer several paths against one text without rescanning.
- A missing member is `.Missing`; a step applied to the wrong container kind is `.Type_Mismatch`; a `Name` compares
  decoded key text, so an escaped key matches its literal text.
- Duplicate keys follow `Duplicates`: `.First` or `.Last` for one answer, and a path option for every match.
- A dsv record's path names its cells by the header's cells; a headerless text has no names.

## Open questions

- Whether the first implementation resolves over the document, the walk, or both. The `Answer` contract above is the
  same either way; only the resolver differs.
- Whether a path edit (set, insert, remove) is a later layer over `Edit_List`, or a direct source splice like the old
  tree's `path_edit`. Keep `Answer` a read result; do not make it carry edit state.
- The exact `limit` and `per_element` semantics: copy the old tree's, including how a miss counts toward a limit.
