# Edits

An edit list records changes to a [document](document.md) without changing it, and a commit writes the source again
with only those changes made. Every byte no edit reaches is copied as it was, comments and spacing included. The guide's
[Edit and keep every other byte](guide.md#edit-and-keep-every-other-byte) section shows the calls in use, and [cli.md](cli.md) the `stury edit` command built on them.

## Edit list

A reader sees an edit only after the caller commits the list and builds the output again.

```odin
Edit_List :: struct { doc: ^Document, edits: [dynamic]Edit, allocator: runtime.Allocator, edit: ^Edit_Services, write: Write_Options, fixed: bool, ... }
Edit :: struct { node: Node_Index, op: Edit_Op, role: Role, padded: bool, at: u32, key: []u8, text: []u8, value: Value }
Edit_Op :: enum u8 { Set, Insert, Remove, Set_Fact, Remove_Fact, Reorder }
```

`edit_list_init` makes an empty list over a borrowed document and allocates nothing until the first edit. Any number of
lists may share one document. A document built through a constant spec holds no edit services, so use the format's
`edit_list_init(&doc, S)`. The list's allocator owns the log and a copy of each edit's key and text, and
`edit_list_destroy` frees them.

## Edit services

`Edit_Services` is a format's table of edit passes. They dispatch on the document's `spec` and `opts`.

- **Every format with edits:** `value` judges a text as exactly one value of the format and spec, `key_text` writes a
  decoded member name in the format's spelling, `comment` says how the output spells a comment, `member_sep` and
  `key_sep` give the text between members and between a key and its value, `insert_check` holds the format's rules on what a
  container takes, `validate`, `build` and `scan` read a text of the list's own spec as a commit checks its output, and
  `spell` writes a built value as text of the format at the place it goes.
- **Flat formats:** a format whose `Readers.flat` is set has no brackets in its text. `interior` says where a container's
  members lie, `fact_slot` and `emptied` say which facts the output holds, and `plan` turns a list's column changes into
  plain edits before core composes it. dsv's `member_sep` is the delimiter, and for the root the line end: the first one
  the text has for a record, else its header's, else LF.
- **Formats whose edits do not fit one range per container:** `prefix`, `relocate`, `frozen` and `commit`.

`Comment_Syntax` holds a format's line comment marker and its block comment markers, and its zero value spells no comment.
A body holding a line end is written as a block when the syntax has one, so a line comment cannot end its line early.

A format computes the `Site` of a value, its column in its line, with `site_at(doc.src, at)` and passes it to the token
writer, so a YAML value is indented and styled for its line.

- **`prefix`:** spells a `Tag`, `Anchor` or `Alias` fact as the text before its node. Nil means the format holds no
  property, and a commit counts a set of one in `dropped`. YAML fills it.
- **`relocate`:** gives the bytes a node has at another place, when an edit's value is a `Node_Ref` of the list's own
  document, as a member moved into another table or another block's indentation. `ok` false is refused as `.Bad_Value`.
  Nil keeps the node's span. TOML, YAML, XML and HTML fill it.
- **`frozen`:** says why an edit may not touch a node, and a frozen node is `.Frozen`. XML's names the nodes a DTD's
  replacement text or an attribute default made, and HTML's the nodes the tree construction made rather than the text.
- **`commit`:** returns the output in place of `core/compose`'s commit, for a format whose containers are not one range
  of bytes to compose around: a TOML table written in sections, a YAML block collection of lines at an indentation. It
  places each edit's text at its site itself and counts the facts the output cannot hold. TOML, YAML, XML and HTML fill
  it, and each reads its output again with `validate`, HTML by building it and comparing the tree with the edited one.

## Recording an edit

An edit is checked when it is recorded, by reading its own text, so the check costs O(the text). The format's own walk
judges the text as one value, one key or one record of the document's spec. `in_` is an `Edit_Input`: source text when
`raw`, else a `Value` the format spells. The list copies the text.

| Call | Records | Refuses |
|---|---|---|
| `set_text(list, node, text: string)` | the node's bytes become `text`, a key's text is its decoded name | `.Bad_Index`, `.Bad_Value` |
| `set_input(list, node, in_)` | the same, from an `Edit_Input` | `.Bad_Index`, `.Bad_Value` |
| `insert_input(list, container, at, key, member, in_)` | an element of an `Array`, or with `member` a member of an `Object`, its `key` a decoded name | `.Bad_Index`, `.Wrong_Container`, `.Bad_Position`, `.Bad_Value` |
| `remove(list, node)` | the member the node is, and its key | `.Bad_Index` |
| `reorder(list, container, order)` | the container's members in the order of `order` | `.Bad_Index` |
| `set_fact(list, node, role, text: string)`, `set_facts`, `remove_fact(list, node, role)` | the facts of the node and role | `.Bad_Index`, `.Bad_Fact` |

- `set` takes a value or a key. It refuses a node whose role is a fact's and a table's container. A key's text is its
  decoded name, which the commit writes with the format's quotes and escapes.
- An insert's `at` is 0 through the container's length at the time the edit was recorded.
- `remove` takes any value that is a member of a container, and a delimited text's header cell. It refuses the root and any
  other node whose role is not `Value`, so a key goes with its value.
- A fact edit takes any node that is not a key and a role past `Key`. `Comment_Inline` refuses a body holding LF or CR,
  and a `Tag`, `Anchor` or `Alias` body is one non-empty line, both as `.Bad_Fact`.
- An edit of a node the format's `frozen` service names is `.Frozen`, with the reason in `inner.rules` and `inner.detail`.
  A second edit of one node and role is recorded, and `commit` refuses it with `.Conflicting_Edits`.
- In a delimited text a cell's text is one record of exactly one cell, and an empty text is the empty cell. A root's
  insert is a record. A cell joins a headed record by name and a headerless record by position, and the commit decides
  the columns from the whole list.

JSON's value check refuses a text that begins with a byte-order mark or holds a comment after its value, since a splice
would put the next bytes inside it.

## Commit

```odin
commit :: proc(list: ^Edit_List, as: Maybe(As) = nil, allocator := context.allocator) -> (out: []u8, dropped: int, err: Error)
```

`compose.commit` writes the output in the document's own spec, or in the spec of `as`. `json.commit(&list)` and
`json.commit(&list, .Json)` forward to it, and the second writes a JSON5 document as strict JSON. A text of another spec
must read strictly, since the source's own reading is no evidence. The commit builds the output in one allocation, and
the caller frees `out`. To read after edits, `commit` then `build`.

`dropped` counts the source facts and fact edits the output cannot hold. A fact removed with a removed member, or one
inside the span a set replaces, is not counted, since the edit that takes it accounts for it.

A delimited text's commit first turns the list's cell edits into column changes:

- A cell removed from every record that holds it drops its column with the header cell, and a removed header cell does the
  same. A cell removed from only some records is emptied.
- A cell inserted beyond the old columns adds a column: one per name in a headed text, at the position the insert gives or
  else at the end, and one per position in a headerless one. A record no insert fills gets an empty cell.
- A short record stays short unless a cell is written past its end, which pads the cells before it.

The commit refuses:

- **`.Conflicting_Edits`:** two edits of one node, two fact edits of one node and role, two ranges that overlap, an insert
  inside what another edit replaces, an edit inside the subtree another edit removes, a fact edit on a node below a set's
  node, and a delimited text's cell that one list both sets and removes, or sets twice in one record.
- **`.Bad_Width`:** an edit that would leave a delimited text a line that does not read as its record, such as a line
  with no cell, or a first cell that starts with the comment byte, or an inserted record with the wrong cell count.
- **`.Duplicate_Key`, `.Bad_Position`, `.Bad_Value`:** a named cell its record already holds, a new column that two inserts
  place apart, and a name the spec cannot spell.
- **`.Bad_Result`:** a result that does not read. The output is read strictly, then with the format's tolerances, and a
  text that needs a tolerance is accepted only when the source needed one too.
- **`.Bad_Spec`:** a spec of another format family, or a delimited text's spec change, which would respell every cell.
- **`.Bad_Index`:** a partial document, since it holds neither the members a commit composes nor their comments.
- **`.No_Memory`:** any allocation it needs.

The error kinds are in [document.md](document.md#errors).

## Where a removal and an insert land

The commit composes each edited container once. A container is its members and the gaps between them, and the root is the
one member of the text. A junction is the bytes between two surviving neighbours: the gaps, the removed members and the
new members between them. An edited junction is written as one replacement, and a junction no edit reaches stays bytes.

- A set replaces the node's own source bytes, a quoted key's quotes included, and leaves the trivia around it.
- A removal takes the member with its key and its comments and one separator, the one after it when a member follows and
  the one before it otherwise. It keeps the member before it on its line, that member's inline comment, and the next
  member's head comment on its own line.
- An insert follows the container's layout: after the separator it writes the whitespace that follows the container's
  first separator, or what follows its opening when it holds one member, and after a key's separator the whitespace its
  first member has there. A gap holding a comment is not copied, and an empty container gives none.
- A container whose every member is removed keeps its brackets, and a foot stays before the close. A dsv record is cut
  from its own first comment through its own line end.
- New members at one index keep the order they were recorded in, and one at an index inside a removal run takes the run's
  place. A new member comes after the inline comment of the member before it and before the head comment of the member
  after it, and a foot stays last. A table writes the delimiter between cells and the line end `edit_record_sep` gives
  between records, and a new last record ends as the old last record did.

## Facts in a commit

The output decides which facts it keeps.

- A fact keeps its node and role while its node survives. A fact no edit names keeps its bytes in place, unless a removal
  takes it, a set replaces its bytes, or the output cannot hold it. A fact the output cannot hold is removed with its bytes
  and counted in `dropped`.
- A tree holds a head or inline fact on any node and a foot only on a container or the root. A delimited text holds a head
  fact on a record, or on the root above its first record, and a foot on the root. An output whose spec writes no comment,
  as `Json` does, holds no fact at all.
- `set_fact` replaces the first fact of that node and role in place and removes the rest, or writes a new comment where
  the role reads it: a head before the node's first byte, an inline after the value, a foot before the close.
- A property edit, a `Tag`, `Anchor` or `Alias`, is spelled by `Edit_Services.prefix` and gets its own chunk just before
  the node's first byte. A kept property fact is never cut for want of a slot: only comments are.
- A body is written as `//body` when a line end follows its place or the text ends there and the body holds no line end,
  and as `/*body*/` otherwise. A dsv body is the document's comment byte and the body, on a line of its own. A head or foot
  the source held mid-line gets a line of its own with that line's indent, and an inline fact gets one space before it. A
  body the output cannot spell is dropped and counted.
