# Markup

How `xml` and `html` read their texts. Both build one document shape: an element is a member under its name,
its attributes are facts of its value, and its text is the value or a `#text` member, so a reader, a path, a model or a
schema written for one reads the other. `xml` also reads a text into typed values (`xml.unmarshal`), reads a text as
one record, writes a document or a typed value as XML (`xml.write`, `xml.marshal`) and edits a text keeping the bytes
no edit reaches (`xml.set`, an edit list). `html` does all of these for HTML: it reads a text into typed values and as
one record, writes a document, a typed value or a token write's calls as HTML (`html.write`, `html.marshal`,
`html.tokens_init`) and edits a text (`html.set`, an edit list).

## The shape of a markup document

A document is an object with one member, the root element, as in `{"order": ...}`. An HTML fragment's document is an
object of the nodes of its root, one member each.

| Source | Document |
|---|---|
| An element | a member whose key is the element's name: XML's qualified name as written, HTML's name in canonical case |
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
whole from its spans keeps how its text and elements interleave. HTML keeps the first of a repeated attribute and drops
the rest, as its tree does.

`core.attributes_of(&doc, node)` walks the attributes of the element whose value is `node` in source order, and
`attribute_next` gives each as a `Key` token of its name and a `Plain` token of its value, which `token_text` decodes.
An attribute's value has no kind, as an element's text has none, so a schema's `"type": "integer"` and a model's `i64`
member read `id="7"`. `core.fact_value` gives an element's `Name` as written and its `Content`, its text and its
descendants' in document order, and `Namespace` its namespace URI.

A model and a schema read a markup document through `core/typed`'s markup layer: an element's attributes and child
elements are members, and the text of an element with attributes is its `#text` member. `xml.checks(.Xml)` and
`html.checks(.Document)` give `model.compile` the format, and `xml.bind_schema` and `html.bind_schema` bind a JSON
Schema. A check builds the text in the temp allocator and checks its document. `xml.unmarshal` builds the text and reads
its document by the same layer: a struct member reads an attribute, a child element or `#text` by its name, and a `[]T`
member collects the siblings of its name wherever they stand. A `core.Value` member is the element's value as
`built_value` builds it, a repeated name an array. A number member cannot read text that needs decoding (`id="&#55;"`). A
load refuses repeated sibling elements as `.Duplicate_Key` unless its options name `dups = .Last` or `.First`, and
`unmarshal` reads a scalar or struct member of a repeated name by the same rule: the typed read goes by the document's
members, not by the grouped value.

## Selectors

`core/css` matches CSS selectors over a markup document, and `xml` and `html` forward it. `css.compile` compiles a
selector list once into a `Selector`, which `css.destroy` frees, and `css.select(&doc, &sel, from)` gives the value
node of each element it matches among the descendants of node `from`, the root by default, in document order. It
matches on the document, not the grouped value, so siblings and positions count across names as the text orders them.

- A selector holds type and universal selectors, `#id`, `.class`, attribute selectors `[a]`, `[a=v]`, `[a~=v]`,
  `[a|=v]`, `[a^=v]`, `[a$=v]` and `[a*=v]` with a quoted or bare value and the `i` or `s` flag, the descendant, `>`,
  `+` and `~` combinators, lists with `,`, `:is`, `:where`, `:not`, `:has` with relative selectors (`:has(> img)`),
  `:first-child`, `:last-child`, `:only-child`, their `-of-type` forms, `:nth-child(An+B [of S])`, `:nth-last-child`,
  `:nth-of-type`, `:nth-last-of-type`, `:root` and `:empty`. Escapes are decoded, so an XML qualified name is
  `svg\:rect`.
- A dynamic or UI pseudo-class (`:hover`, `:checked`), a pseudo-element (`::before`, `:first-line`) and a namespace
  prefix (`svg|a`, `*|a`, `[xlink|href]`) are a `Fault` with the detail `Pseudo_Class`, `Pseudo_Element` or
  `Namespace` at the first byte of the pseudo-class or the selector, and a malformed selector one with `Syntax` at the
  byte that breaks it, or `.Truncated` at the end. `:is`, `:not`, `:has` and `of S` nest at most `css.MAX_NESTING`
  deep.
- An element is a member whose key is not `#text`. `:root` is the one element at the top of a document, which an HTML
  fragment of several nodes lacks. `:empty` is an element with no child element and no text. An element at the top counts its
  position among the root's members, as the root element of a browser's document matches `:first-child`.
- HTML compares element and attribute names ASCII case-insensitively (`Readers.fold_names`) and attribute values as
  written, those the standard lists as case-insensitive included, so `[type=TEXT]` needs `i` to match `type=text`. XML compares both as
  written. An `id` and a `class` are the attributes of those names in either format.

The match goes right to left: each element is read once in document order, and its compounds test it and then the
elements its combinators reach through the chain of open elements, so a `>` or descendant step costs the depth.
`+`, `~` and the counts of `:nth-last-*`, `*-of-type` and `of S` read the element's siblings, and `:has` walks the
element's subtree, or its following siblings' for `+` and `~`, so those cost more. It allocates only the chain of
elements and the answer, and a decode of an attribute value longer than 256 bytes in the temp allocator.

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
`{uri}local` against the declarations in scope, through `Readers.key_is`.

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

`xml.set` and an XML edit list commit their edits as splices of the source, through `core/compose/markup.odin`, which
HTML's commit shares, since an element's name stands in two tags
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
  entity, and a schema with required members and repeated children. `entry_points.odin`: every entry point, and the
  calls in `core` with a handle.
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

## HTML

`html` reads HTML as the WHATWG HTML standard does: the tokenizer of section 13.2.5, with the input stream's
preprocessing and character references, the tree construction of section 13.2.6, which builds a document or a fragment,
templates and foreign content (SVG and MathML) included, and the encoding sniffing of section 13.2.3. The tree is built
into the document an XML text with the same markup builds, so HTML is a format on the same interface as XML: `validate`,
`walk` with a cursor that `walk_resume` continues, `build`, `scan`, `find`, `each_answer`, `answers`, `query`, `as`,
`checks`, `bind_schema`, `unmarshal`, `check`, `plan_make`, `reads`, `number`, the record calls,
`record_docs`, `write`, `marshal` and `tokens_init`. A typed read goes by the tag key `html`, through the markup layer XML's goes through,
over the tree the standard builds, so `<td>1<td>2` reads into a `[]T` member `td` of the `tr` and `tbody` the tree
implies. A text is one record, from the reader's position to the input's end, since a browser reads every byte past
`</html>` into the tree. A walk with a cursor holds the tokens past its first stop in a `core.Token_Cursor`, as XML's
does, and a `Skip` on an element's key or `Object` there hides the element's remaining tokens. The tokenizer and the
tree are not public.

`html.Spec` is `.Document` or `.Fragment`. A fragment is read in the context element `Options.context_name` in
`Options.context_namespace` (`html.Namespace` `.Html`, `.Svg` or `.Math`), `body` when the name is empty, and its
document is an object of the nodes of the root, as the standard's fragment algorithm gives them. `Options.scripting`
reads as a browser with scripting enabled reads: `noscript` content is raw text. No script runs either way.

### What an HTML document holds

- Every element's name is in canonical case: ASCII upper case lowered, SVG and MathML mixed case restored, and U+0000
  read as U+FFFD. A start tag the tree renames, `image` as `img`, is read under the name of the element it makes.
- An element the tree construction implied, as `html`, `head`, `body` and `tbody`, is a member whose key has no bytes.
- A text the tree moved (foster parenting) or that a comment split is one value, whose pieces the document's state
  lists, so `text` reads it whole.
- `core.fact_value(&doc, node, .Namespace)` gives every element's namespace URI, HTML, SVG or MathML, with no `xmlns`
  declaration.
- Character references are decoded by `text` as the tokenizer read them, through the trie `core/spell` holds.

### Write

`html.write` writes a document, or an object node of one, by the standard's serialization of a tree (section 13.3): an
object of one `html` member is a document and any other a fragment, an element per member, per item of an array, a
`#text` member the text there, `null` an empty element and a scalar its text, spelled by `write.scalar_text`. A void
element has no end tag, the text of a raw text element (`script`, `style`) is written as it stands, and any other text
and attribute value is escaped with `&amp;`, `&nbsp;`, `&lt;` and `&gt;`, or `&quot;` in a value. A `pre`, `listing` or
`textarea` whose text starts with a line feed gets one more, as the standard's parser drops it. An HTML document is
written as its tree holds it, the elements the tree implied with their tags, and its doctype, comments and attributes
are written from their spans. Another format's document writes its comments where they stand and drops a fact HTML has
no form for, and an attribute name that is no HTML name is `.Unwritable`.

A text is sound when it reads back as the tree it was written from: the write reads its compact text back, as a
document or a fragment in `body`, writes that again and compares the two, so `{"td": 1}`, a `div` in a `p`, a void
element with content, a raw text that holds its end tag and an upper-case name are `.Unwritable`. A pretty write puts an
element whose children are all elements on lines of its own and lays nothing into `pre`, `listing`, `textarea` or an
element that holds text. A value no object is `.Unsupported`.

`html.marshal` and the token write make their value in `write.MARKUP_TREE`, as XML's do, and `write.put_markup` reads it
back as a built value that `html.write`'s serialization writes, read back as above. A struct of one member `html` is
written as a document, so it must hold the `head` and `body` the tree implies. A token write to a stream is
`.Unsupported`, since the text is read back only once it is whole.

An HTML document does not answer what needs XML's declarations: there is no `{uri}local` path step and no attribute
lookup by expanded name. `html.scan`, `find` and `each_answer` always build the whole document, since the tree is whole
before its first token.

### Edits

`html.set` and an HTML edit list commit as XML's do: a set writes an element's content between its tags, an array on
a name fills its elements in order, an insert is an element laid out by the white space before its neighbour, a removal
takes that white space, a rename respells both tags, and comments and attributes are facts. An end tag the source
leaves out stays out, and an element's end is where the tree ends it.

- A value is written as `html.write` writes it: a string escaped, or as it stands in `script`, `style`, `xmp`, `iframe`,
  `noembed`, `noframes` and `plaintext`, an object as elements, and a line feed more before the text of a `pre`,
  `listing` or `textarea` that starts with one. An object's elements must read back as written when read as a fragment
  whose context is the element they go in, else the edit is `.Bad_Value` with the reason `.No_Spelling`: a `table` takes
  `{"tbody": {"tr": ..}}`, and refuses `{"tr": ..}`, which it reads inside a `tbody`. A `typed.Raw` is markup as it
  stands, refused in a raw text element when it holds `<` or `&`, and in `title` and `textarea` when it holds `<`.
- An attribute body is a name in lower case and its value as the tokenizer reads one attribute, and a comment body
  one the serialization can write.
- An edit that writes at a node the tree construction made rather than the text, an element it implied, moved or
  copied or a text it moved, is refused with the detail `constructed`, as is an insert next to one, since no bytes of
  the source spell it where it stands. An edit between the nodes the source spells inside an implied element, as an
  insert between two `p` in an implied `body`, or a set of an element whose implied descendants it replaces, is made.
  A text read across a start tag the tree dropped, as `html` inside a `p`, is refused as `split`, since its span holds
  the tag's effect.
- Content in a void element is `void`, an array in an array `nested_array`, and a change of member order `reordered`.
- The output is built again with the document's options and compared with the source document. A node no edit wrote
  reads as it did, the content an edit wrote reads in the output as it reads alone as a fragment in its element, or
  for the document's `ROOT` as its root element reads alone, and an insert, a removal or an array changes the element
  count by its own. A result that differs is `.Bad_Result` with the
  detail `reread` at the first byte that differs, so a `div` or `p` in a `p`, a `td` outside a table and a rename of `p`
  to `table` are refused.

### Validate and faults

A build recovers from every parse error, as the standard does, and fails only for a text it cannot read: `.No_Memory`,
`.Too_Wide` at a span longer than 4 GiB, `.Too_Deep` where the stack of open elements would pass `Options.max_depth`,
and `.Bad_Char` with the detail `encoding` for a text in an encoding other than UTF-8. A byte order mark for UTF-8 is
skipped. Otherwise the prescan reads the first 1024 bytes for a `meta` naming an encoding, and when it finds none, the
first `meta` the tree inserts in the head may name one. An encoding other than UTF-8 is refused unless every byte of
the text reads as UTF-8 reads it, as an ASCII text does in an encoding that extends ASCII, and UTF-16 byte order marks
are refused too.

`html.validate` builds the tree on the default heap and returns its first parse error, in the order the standard's
algorithm finds them, so it allocates where XML's does not. A parse error of the input stream or the tokenizer is
`Truncated` for one the standard names after the end of the text, and `Bad_Char` at its byte for any other, and one of
the tree construction is `Bad_Char` at the token it reads. `Detail` holds the standard's tokenizer parse error codes, `-`
read as `_`, then the tree construction's, which the standard does not name: `Missing_Doctype`, `Bad_Doctype`,
`Unexpected_Doctype`, `Unexpected_Start_Tag`, `Unexpected_End_Tag`, `Unexpected_Text`, `Unclosed_Element` and
`Misnested_Tag`.

### Files

| File | Holds |
|---|---|
| `html/tokenize.odin` | `Spec`, `Options`, `Detail`, `RULES`, the token types, the tokenizer's entry, the byte classes and stop sets, the input stream's judge, the tag and attribute builders |
| `html/states.odin` | the tokenizer's states, one procedure each, in the standard's order |
| `html/refs.odin` | character references, read alike by the tokenizer and by the decode |
| `html/tree.odin` | the tree: the node arena, the stack of open elements and its scopes, the list of active formatting elements, insertion, foster parenting, the adoption agency |
| `html/modes.odin` | the tokenizer's hook, the dispatcher and the insertion modes, one procedure each, and the DOCTYPE's quirks |
| `html/foreign.odin` | foreign content: the dispatcher's test, its rules, integration points and adjusted names |
| `html/select.odin` | the `option` step that fills a `selectedcontent` element |
| `html/input.odin` | encoding sniffing: the byte order mark, the prescan and a `meta` the tree inserts |
| `html/tags.odin` | the element names the tree construction treats by name, their categories, the names foreign content adjusts, and the tables that find each, generated by `tools/html_tags.py` |
| `html/encodings.odin`, `html/encodings/` | the Encoding Standard's encodings and labels, generated by `tools/html_encodings.py` from its `encodings.json` |
| `html/write.odin` | the serialization of a tree and its read-back |
| `html/edit.odin` | the edit services: content and facts by the serialization's rules, an element's tags in the source, and the read of the output against the edited tree |
| `html/emit.odin` | the tree's tokens in preorder, which the build reads twice, to size the document and to write it |
| `html/build.odin`, `query.odin`, `typed.odin`, `records.odin`, `bound.odin`, `document.odin` | the entry points, the paths, the typed reads and checks, the records, the bound tables and the readers |
| `html/internal.odin` | the tokenizer and the tree, opened to `html/test`'s conformance tests and to a build with `-define:STURY_HTML_INTERNALS=true` |
| `core/markup.odin` | what XML and HTML share: `MARKUP_TEXT`, the attribute fact's spelling, `resolve`, the numbers and the `Name` and `Content` facts |
| `core/spell/entities.odin`, `core/spell/entities/` | the named reference trie, generated by `tools/html_entities.py` from the standard's `entities.json` |

### The tokenizer

The tokenizer hands each token to the tree's hook: text, start and end tags, comments, DOCTYPEs, processing
instructions, and each parse error, with its `Detail` and the byte it was found at, after which the read goes on as the
standard says. A token holds no text of its own. A name, a text and each attribute's name and value are spans: a source
range, the `Mode` its characters were read in, and the flags saying what decoding it needs. A span with no flags is its
source bytes, which is every name and text run in clean lower-case markup. The tokenizer reads a character reference
once, to report its errors, and the decode reads it again with the same procedure (`read_ref`), so the two cannot part.

| Mode | Spans | U+0000 | References |
|---|---|---|---|
| `.Data` | text of the data state | kept | read |
| `.Text` | text of the data state as the tree reads it in HTML content | dropped | read |
| `.Rcdata` | text of RCDATA | U+FFFD | read |
| `.Raw` | RAWTEXT, script data, PLAINTEXT, comments, DOCTYPE identifiers | U+FFFD | no |
| `.Verbatim` | CDATA sections, instruction data | kept | no |
| `.Name` | tag, attribute and DOCTYPE names, ASCII upper case lowered | U+FFFD | no |
| `.Value` | attribute values | U+FFFD | read as in an attribute |

The tokenizer does not know which element it is in. The hook's answer to a start tag switches it: `.Rcdata`,
`.Rawtext`, `.Script_Data` and `.Plaintext` set the text state the tree construction asks for, and `.Foreign` and
`.Html` say whether the adjusted current node is outside the HTML namespace, where `<![CDATA[` opens a CDATA section
and is otherwise a bogus comment with `cdata-in-html-content`.

Every state is a procedure with one signature that ends in `#must_tail` to the next, so the states compile to jumps and
a state change costs no call or return. The hook is a compile-time parameter and is inlined into the states that emit.
The standard's states map one to one onto procedures, with three merges: the end tag open and end tag name states of
RCDATA, RAWTEXT, script data and escaped script data are two procedures that return to the text state they came from,
the quoted DOCTYPE identifier states read their quote from the tokenizer, and the character reference states are
`read_ref`. Processing instructions follow the standard's current states: `<?` opens one when the target is a name,
`xml` in any case is refused as a target, and anything else is a bogus comment.

A state that reads a run (data, RCDATA, RAWTEXT, script data, PLAINTEXT, the escaped script states, comments, CDATA
sections, bogus comments, quoted attribute values and instruction data) skips it 64 bytes at a time: `stop_at`
classifies a block by its two nibbles against the state's stop set (`kernel.classes`) and jumps to the first byte the
state acts on. Each set holds the state's own bytes and every byte the input stream must judge, so a run of ASCII text
with no markup is a mask and a count of trailing zeros per block.

The standard preprocesses the input before the tokenizer reads it: CR LF and a lone CR become LF, and a control, a
noncharacter or a surrogate is a parse error. stury does that in place. `C_JUDGE` holds CR, every control but tab, LF
and FF, DEL and every byte past ASCII. A state that meets one calls `judge`, which reads the character, reports a
control or noncharacter, and marks the span for the decode. A surrogate cannot be encoded in UTF-8, so its three bytes
are ill-formed UTF-8 and read as U+FFFD. A character a state reconsumes is reported once.

`entities.json` is the standard's table of 2231 names. `tools/html_entities.py` builds a trie from it, one node per
character with a node's children in a row in byte order, and writes it as tables and the values' UTF-8 text, checked
against the file's SHA-256. `read_ref` walks the trie for the longest name that ends at a terminal, applies the
attribute rule (no match when the next character is `=` or alphanumeric), and reports a missing semicolon or an unknown
name. A numeric reference is read to its value, with the standard's C1 remapping and its errors for zero, surrogates,
noncharacters, controls and values past U+10FFFF.

A tag keeps its first 16 attributes inline and compares each new name with them one by one. Past that the attributes
move to the allocator, with a hash table of their names, so a tag with thousands of attributes stays linear. A
duplicate is reported and dropped, the first value kept, as the standard says.

### The tree

`build_tree` hands the tokenizer the hook `on_token`, which reads each token in the current insertion mode. A mode is a
procedure that returns whether the token is to be read again, in the mode it switched to, and a mode that uses
another's rules calls it. A text token is a run of character tokens: a mode that treats whitespace apart splits the
run and reads the rest again, so a run costs one call however long it is.

The tree is an arena of nodes linked by index: parent, first and last child, previous and next sibling. The algorithm
inserts before a table, moves children and clones elements, and a linked arena does each in place. A node keeps the
source bytes of the token that made it, and the element's name as a span. An element's attributes are a run of the
tree's attribute list, copied from the token, and a clone shares its original's. A text node is a list of pieces, each
a span, and a text inserted next to the text it continues in the source grows that text's last piece, so text written
as one run is one piece. A flag marks an element no tag opened (`.Implied`), a clone (`.Cloned`) and a node placed
away from where its source sits (`.Moved`).

`tags.odin` gives each name the algorithm treats by name a `Tag`, and every other name is `.Other`, compared by its
source text. A tag's categories (special, formatting, the elements that bound each scope, the ones implied end tags
close, the contexts a table clears back to) are a bit set per tag, so a scope check reads the stack and one table.

The stack of open elements and the list of active formatting elements hold node indices. The list keeps the Noah's
Ark clause, and reconstructing it clones each element not open after the last marker. The adoption agency runs as the
standard writes it, its outer loop eight times and its inner loop three. Foster parenting places a node before the
last table when the current node is a table, a table section or a row. `select`, `option`, `optgroup`, `hr` and
`input` follow the standard's current rules, with no "in select" mode, and when the parser pops the option a `select`
selects, the select's `selectedcontent` element takes a copy of its children. The DOCTYPE sets the document's quirks
mode from the standard's lists of public and system identifiers.

A `template` element's contents are its children, and the stack of template insertion modes picks the mode they are
read in. While the adjusted current node is an SVG or MathML element and not an integration point for the token, the
token is read by the rules of foreign content, which insert elements in that namespace and break out at the standard's
HTML tags. A fragment reads through the same builder, its context element picking the tokenizer's first state, the form
pointer, the template modes and the insertion mode as the standard's fragment algorithm does.

`html/emit.odin` gives the finished tree's tokens in preorder, once to `core/build`'s counting hook to size the document
and once to the builder hook to write it, then the tree is freed. What the tokens' spans cannot carry, each element's
close and the pieces of a text that is no one span, goes into the document's `Token_View.state`.

### Tests

- `html/test`: documents and their shapes against XML's, names, paths, attributes, facts, templates, spans, the entry
  points and the calls in `core` with a handle, duplicates, edits and their refusals, handle options, the walk with skips and stops, validate, faults,
  models, schemas, `diff` and `equal` against XML, and 1,000 random texts that an HTML fragment and an XML document read
  alike, checked to build one document shape and one value under both `infer` settings.
- `html/test/html5lib_test.odin` runs every case of html5lib-tests' `tokenizer/` directory in each of its
  initial states and compares the tokens and the errors, codes and positions both. `xmlViolation.test` is skipped,
  since it tests the coercion of output to the XML infoset, and so are the cases whose input holds a lone surrogate,
  which UTF-8 cannot carry. `tokenize_test.odin` covers the hook's text state switches, CDATA in foreign content, tags
  with many and duplicate attributes, an allocator that refuses, the decode on each flag, and every special byte at each
  offset across a block boundary.
- `html/test/tree_test.odin` reads every case of the tree-construction `.dat` files as the web-platform-tests
  keep them, builds each as a document or as a fragment of its context, with scripting off and on unless the case
  names one, compares the tree as the format prints it, and checks each case's document against its tree: element names
  in preorder, attribute values and element text. A ledger names the cases whose tree differs, with the reason, and a
  ledger case that passes fails the run. `encoding_test.odin` runs the html5lib-tests encoding cases and checks the
  fault for each encoding the tree does not read, and `frozen_test.odin` the nodes the tree made otherwise than the
  source spells them.
- The conformance tests are in package `html/test`, beside the format tests, and read their cases from
  `html/test/conformance/html5lib` and `html/test/conformance/wpt`. The package needs
  `-define:STURY_HTML_INTERNALS=true` for `odin check`, which `make lint` passes, and nothing for `odin test`.
