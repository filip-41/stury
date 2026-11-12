# Markup

How `xml` reads its texts. It builds the markup document shape: an element is a member under its name, its
attributes are facts of its value, and its text is the value or a `#text` member. `xml` also reads a text into typed values (`xml.unmarshal`), reads a text as
one record, writes a document or a typed value as XML (`xml.write`, `xml.marshal`) and edits a text keeping the bytes
no edit reaches (`xml.set`, an edit list).

## The shape of a markup document

A document is an object with one member, the root element, as in `{"order": ...}`.

| Source | Document |
|---|---|
| An element | a member whose key is the element's qualified name as written |
| An element with no child element | a `Plain` value of its text, empty for none, which reads as null |
| An element with child elements | an `Object`: a `#text` member for each run of text between its children that holds a character other than whitespace, and each child as a member, in document order |
| An attribute | an `Attribute` fact of the element's value, `name="value"`, read through `core.attributes_of` |
| A comment | a `Comment`, `Comment_Inline` or `Comment_Foot` fact, by the position rule every format uses |
| A processing instruction | an `Instruction` fact, by the same rule |
| The document type | a `Doctype` fact on the root |

The key `#text` (`core.MARKUP_TEXT`, `xml.TEXT_KEY`) has no source span and is marked `SPELLING_SYNTHETIC`, so its text
comes from the format. An element's text reads by `kind` as a string, or with `Options.infer` as `true`, `false` or a
number when it is exactly one of them, and empty is null either way. Two elements of one name are two members of one
key in the document, so `member` gives the last, `members_named` every one, and a path read under
`Path_Options{dups = .All}` answers each. A build under `.Refuse` fails at a name an element repeats among its children.

The value of a markup node reads a name its element's members repeat as one member, an array of each of them in
document order, and a name that stands once as a single value: `<r>a<b>1</b>c<b>2</b></r>` is
`{"r":{"#text":["a","c"],"b":["1","2"]}}`. `core.value_member`, `value_pairs`, `value_length`, `value_children`,
`built_value` (under `.Default`), `equal`, `compare`, `diff` and `schema` read it so, and `core.write` to a format with no
attributes writes the document as that value. `markup_members` gives one object's members so and `markup_member` one
name. A path names the document's members, not the value's arrays. A path engine walks the text once, and whether a
name repeats, and so whether its value is an array, is known only at its parent's end, so `.r.b` answers the last `b`
as a repeated key of JSON does, each `b` under `dups = .All` and the first under `.First`, and an index after it indexes
that element's value. The value's `.r.b[1]` is `core.value_member` then `value_child_at`, or `members_named`'s second
node. The value keeps no order across names, so a text
written from it puts each name's elements and runs together at the place of its first: only an XML document written
whole from its spans keeps how its text and elements interleave.

`core.attributes_of(&doc, node)` walks the attributes of the element whose value is `node` in source order, and
`attribute_next` gives each as a `Key` token of its name and a `Plain` token of its value, which `token_text` decodes.
An attribute's value has no kind, as an element's text has none, so a schema's `"type": "integer"` and a model's `i64`
member read `id="7"`. `core.fact_value` gives an element's `Name` as written and its `Content`, its text and its
descendants' in document order, and `Namespace` its namespace URI.

A model and a schema read a markup document through `core/typed`'s markup layer: an element's attributes and child
elements are members, and the text of an element with attributes is its `#text` member. `xml.checks(.Xml)` gives
`model.compile` the format, and `xml.bind_schema` binds a JSON Schema. A check builds the text in the temp allocator and checks its document. `xml.unmarshal` builds the text and reads
its document by the same layer: a struct member reads an attribute, a child element or `#text` by its name, and a `[]T`
member collects the siblings of its name wherever they stand. A `core.Value` member is the element's value as
`built_value` builds it, a repeated name an array. A number member cannot read text that needs decoding (`id="&#55;"`). A
load refuses repeated sibling elements as `.Duplicate_Key` unless its options name `dups = .Last` or `.First`, and
`unmarshal` reads a scalar or struct member of a repeated name by the same rule: the typed read goes by the document's
members, not by the grouped value.

## XML

`xml` reads XML 1.0 (Fifth Edition) well-formedness. It has `validate`, `walk`, `build`, `scan`, `find`,
`each_answer`, `query`, `as`, `checks` and `bind_schema`, each in a bound form for a constant `Spec` (`.Xml`) and a
chosen one. The internal subset of the document type is read, as a processor that does not validate reads it, and
nothing else of a DTD: stury reads no external subset and no external entity. Only UTF-8 is read, with or without a
byte order mark.

### Tokens

| Source | Tokens |
|---|---|
| An element's start | `Key` with the qualified name as written (the byte after `<` is its `lo`) |
| An attribute | an `Attribute`-role fact after the key, `Plain`, spanning `name="value"` through the closing quote |
| An element with no child element | `Plain` over its content, with `n = 0` when empty. `SPELLING_DECODE` is set when the content holds `&`, a carriage return, a CDATA section, a comment or a processing instruction |
| An element with child elements | `Object` spanning the start tag, a `#text` `Key` and `Plain` for each run of text that is not only white space, each child as a member, `End` spanning the end tag |
| A processing instruction or the document type | a fact with the `Instruction` or `Doctype` role |
| A comment | `Comment` before the token that follows it, `Comment_Inline` after a child that ends on its own line, `Comment_Foot` before an end tag of an `Object` |

The XML declaration is no fact. A skip from the hook hides the element's value and its `End`. An attribute fact's
lead runs through the opening quote and its tail is the closing one, as `Fact` says for the role, so
`core.facts_of(&doc, node, .Attribute)` gives the value as written. A value that starts more than 255 bytes past its
name, as a DTD default behind a long enumerated type may, holds a lead of 255, and XML's readers find the opening quote
from the closing one.

### Faults

Every fault is a `Fault` with `xml.Detail` as its detail and `RULES` as its table, and names the byte that started the
fault, not the byte it was noticed at. The walk judges every byte it reads:

- names by the Fifth Edition's `NameStartChar` and `NameChar` ranges (U+10000 to U+EFFFF included)
- characters by `Char`: C0 controls other than tab, line feed and carriage return, U+FFFE and U+FFFF, lone surrogates and
  overlong or out-of-range UTF-8 are refused
- `<` in an attribute value, `]]>` in character data and `--` in a comment
- a repeated attribute name in one tag
- a reference to an entity the internal subset does not declare, other than the five predefined entities, and a
  decimal or hexadecimal reference to no `Char`
- end tags that do not match, text before the root and after it, a second root

### How it is built

`xml/walk.odin` holds the grammar as tail-called states over the text, as the JSON walk does, and keeps the open
elements as frames on a stack of `core.MAX_DEPTH` that grows on the heap when `max_depth` asks for more.
`xml/text.odin` reads character data, attribute values, CDATA, comments and instructions in 64-byte blocks, one reader
per x86 tier, each returning nil when it cannot vouch for the block; the byte-wise reader then finds the precise fault.
`xml/name.odin` holds the name tables, and `xml/framing.odin` the prolog, the epilog, the declaration and the document
type. Attribute names are checked for repeats against 16 inline names, then a hash table.

### Namespaces

The walk reads namespaces by the W3C recommendation, so a name is a qualified name. A prefix needs a declaration in
scope (`xmlns:p`) when an element or an attribute uses it, `xml` is bound and may only be bound to its own URI,
`xmlns` is never declared or used as an element prefix, no prefix is bound to the empty string, and two attributes of
one element must not have the same namespace and local name. A processing instruction target has no colon. These are
the faults `qualified_name`, `unbound_prefix`, `reserved_prefix`, `reserved_namespace`, `empty_binding` and
`duplicate_expanded`. The walk keeps the declarations in scope on a stack of its own, and a tag with no colon and no
declaration pays one flag test.

A text that declares a namespace marks its keys, so a member lookup and a path step compare a name as written, or as
`{uri}local` against the declarations in scope, through `Readers.key_is`. `xml.attribute_value(&doc, node, name, buf)`
reads one attribute by its name as written or as `{uri}local` (an attribute with no prefix has no namespace), into a
`buf` of `xml.attribute_room(&doc, node)` bytes.

### The DTD

`xml/subset.odin` reads the internal subset by its grammar, every `markupdecl`: element type, attribute-list, entity and
notation declarations, comments, processing instructions and parameter-entity references between declarations. A
declaration that breaks its production faults with `element_declaration`, `attribute_declaration`,
`entity_declaration`, `notation_declaration` or `subset`, and a parameter-entity reference inside a declaration with
`parameter_reference`. The first declaration of an entity or an attribute binds it. `xml/dtd.odin` holds the tables:
the walk builds them on the heap and seals them into one block, which a built document keeps as its
`Token_View.state`, so a document's reads, and a check's, need nothing but the document.

- *General entities.* A reference to an internal entity reads as its replacement text. A replacement with no `<` is
  decoded by `text` like any reference, and `Readers.room` sizes the decode, which may outgrow the span. One with markup
  is walked in place over its literal's bytes in the internal subset (`xml/entity.odin`), so its elements and
  attributes are nodes of the document like any other whose spans lie in the subset. Such a replacement must be
  balanced content: an element it opens closes in it, else `entity_boundary`. A replacement that spells markup its
  literal does not (`<!ENTITY e "&#60;b/>">`) has no bytes to walk and faults with `entity_respelled`. A reference to
  itself, directly or through others, faults with `recursion`, a reference to an unparsed entity with
  `unparsed_entity`, and a reference in an attribute value to an external entity with `external_entity`.
- *Expansion budget.* An entity's expanded size is measured from its literal and the sizes of the entities it refers
  to, at its first reference, and kept. Each reference in the document adds its entity's size to a total, and each
  attribute default applied adds its value's. Past `Options.max_expansion`, or by default past 8 MiB and past a hundred
  times the text's length, the reference faults `Too_Wide` with the detail `expansion`. Nothing is expanded to measure
  it, so billion laughs and the quadratic blowup cost the time of reading their declarations.
- *Unread entities.* A reference to an external entity, or to an undeclared one in a text with an external subset or a
  parameter-entity reference, which may declare it, faults with `unread_entity`. The tolerance
  `core.Tolerance.Unread_Entity` reads it as its own text, `&x;`. A standalone document refuses an undeclared reference
  with `undeclared_entity`.
- *Parameter entities* expand between declarations. After a reference to one that is not read, later entity and
  attribute-list declarations are not processed, as section 5.1 of the spec says.
- *Attribute defaults.* An attribute the subset gives a default, which the tag does not write, is an `Attribute` fact
  of the element whose span is the default in its declaration. A default that declares a namespace binds it. A value of
  a type other than `CDATA` drops its leading and trailing spaces and reads each run of spaces as one.
- *Known public identifiers.* Under the XHTML and MathML public identifiers the WHATWG standard lists, a reference to a
  character name the standard's table lists reads as its text there, through the named-reference trie in
  `core/spell/entities.odin`, which `tools/html_entities.py` generates from the standard's `entities.json`.

XML's `frozen` service names the nodes whose bytes lie in the internal subset, an entity's replacement text or an
attribute default, with the detail `replacement`, so an edit of such a node is `.Frozen`.

### Edits

`xml.set` and an XML edit list commit their edits as splices of the source, since an element's name stands in two tags
and its attributes in the first. Every byte no splice touches stays, and the output is read again: one XML does not
read is `.Bad_Result`.

- A set writes the element's content between its tags, which keep their name and attributes, and an empty element
  `<e/>` becomes `<e>…</e>`. A set of `xml.ROOT` replaces the root element, and a set of a `#text` member the text run.
  A string is escaped by the writer's rules, an object is written as child elements and its `#text` as text, and null
  is no content. A `typed.Raw` is an element's content as XML, judged as one.
- An array set on a name writes item k as the content of the name's k-th element, takes the elements past the items
  and adds the items past the elements as elements of the name after its last. Each element of a repeated name and each
  text run is a member of its own (`core.members_named`), which a set, an insert, a removal and a rename reach without
  moving the members around it. The CLI's `edit` turns the grouped value's `.r.b[1]` and `."#text"[1]` into such edits.
- An insert is an element after the member before it, and before the first child when it goes first, laid out by the
  white space before the member that follows. A removal takes an element with the white space before it. A rename
  respells the start and end tags.
- A fact edit of role `Comment` writes `<!--…-->` at the head of an element's content (before the root element for
  `ROOT`), `Comment_Inline` after the element and `Comment_Foot` before its end tag (after the root element for
  `ROOT`). Role `Attribute` takes a body `name="value"` written in the start tag after the name, the shape
  `core.comments(v, .Attribute)` reads a node's attributes in, so the CLI's `.&k = "v"` writes the bodies it read with
  one replaced or added. Either replaces the facts of that role where they stand, an attribute an internal subset
  defaults excepted.
- Refused as `.Frozen`, with the reason: a change of member order, a key that is no XML name with no colon or the key
  `#text` for an element, markup or an array as a `#text` value, an array as the document, a comment holding `--` or
  ending in `-`, a fact on a text run, which has no place for it, and an edit of a node an internal subset or a default
  made. What XML cannot spell, such as an empty string, an empty array or an array inside an array, is `.Unwritable`.

### The document and paths

`xml.build` builds the document, and `xml.scan`, `xml.find` and `xml.each_answer` answer paths. An element's text is
what `text` returns: references, CDATA sections and line ends are decoded, and comments and instructions are left out.
A read of one path that gives no stream of answers and holds no expanded name is a walk that builds only what the path
reaches and judges every byte it passes. Several paths, a stream, an expanded name and `.Refuse` build the document
and answer from it. The end of a container is found from its last descendant, so a skipped element needs no scan of its
own.

### Tests

- `xml/test/document.odin` and `namespaces.odin`: the values, text, attributes, facts, expanded lookups and
  paths of built documents, and the namespace faults.
- `xml/test/walk.odin` and `blocks.odin`: the tokens and faults for small texts, and every offset across the
  block boundaries.
- `xml/test/dtd.odin`: the declarations, entities in text and attributes, markup replacement, parameter entities
  and the stop rule, defaults and normalization, the expansion budget against billion laughs and the quadratic blowup,
  the unread-entity tolerance and the character names under an XHTML public identifier.
- `xml/test/model.odin`: a model with attribute members, a `#text` member, child elements, a DTD default and an
  entity, and a schema with required members and repeated children. `entry_points.odin`: every bound and chosen entry
  point.
- `xml/test/conformance.odin`: the XML 1.0 cases of the W3C XML Conformance Test Suite. A valid case's document must
  hold what its canonical form holds, elements, attributes and text, and the test writes both through one writer, so
  processing instructions and white space between elements, which a document does not hold, are left out on both
  sides. A case that refers to external entities is read with `Unread_Entity`. `python3
  xml/test/conformance/fetch.py` fetches the archive, checks its SHA-256 and writes the documents and canonical forms
  under `xml/test/conformance/files/`, which git does not track, and `make` runs it before `xml/test`. The test's
  ledger lists each case answered otherwise with the reason: UTF-16 documents, faults and text in external entities, and
  replacement text that spells markup its literal does not.
- `xml/test/oracle`: the reader the differential against pyexpat drives, seeded random and broken documents, internal
  subsets among them, read with namespaces.
