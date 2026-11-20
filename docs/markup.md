# Markup

How `xml` and `html` read their texts. Both build one document shape: an element is a member under its name,
its attributes are facts of its value, and its text is the value or a `#text` member, so a reader, a path, a model or a
schema written for one reads the other. Both read a text into typed values and as one record, write a document or a
typed value, and edit a text keeping the bytes no edit reaches. `html` also writes a token write's calls as HTML.

## Command line

```sh
$ stury -c . feed.xml
{"feed":{"entry":{"title":"Hi"}}}
$ stury -c '.feed.entry | .&id, .@namespace' feed.xml
"7"
"http://www.w3.org/2005/Atom"
$ stury -c --attributes '.' feed.xml
{"feed":{"@xmlns":"http://www.w3.org/2005/Atom","entry":{"@id":"7","title":"Hi"}}}
$ stury -c '[css("a.story") | .&href]' page.html
["/a","/b"]
```

- **Elements:** an element is a member under its name, its text is its value, and a name that repeats is an array in
  document order. An empty element is `null`, and text between child elements is a `#text` member.
- **Attributes:** `.&NAME` reads one, `.@attrs` all of them as an object, and `--attributes` reads each as a member
  `@NAME` of its element. A format other than XML and HTML drops the attributes unless `--attributes` is set, with a warning that
  counts them. With `--attributes`, a member `@NAME` writes back as an attribute.
- **Facts:** `.@namespace` gives an element's namespace URI, in HTML too. `.@doctype`, `.@directives` and `.@pi` stand on
  the document, `.@comment` on the node it precedes.
- **Selectors:** `css(selector)` yields the matched elements in document order. An unsupported selector is an error:
  `"a:hover" (at offset 1) is not a valid selector: Unsupported pseudo-class`.
- **Writing:** `--to xml` needs one root member, and refuses an empty string and an empty array, which would read back as
  absent. `--to html` refuses a tree its parser would read as another, such as `{"td": 1}` or a `div` in a `p`.

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
| The XML declaration | a `Directive` fact on the root |

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
name. A path names the document's members, not the value's arrays. A path engine walks the text once, and whether a name
repeats is known only at its parent's end, so `.r.b` answers the last `b` as a repeated key of JSON does, each `b` under
`dups = .All` and the first under `.First`. The value's `.r.b[1]` is `core.value_member` then `value_child_at`, or
`members_named`'s second node. The value keeps no order across names, so a text written from it puts each name's
elements and runs together at the place of its first: only an XML document written whole from its spans keeps how its
text and elements interleave. HTML keeps the first of a repeated attribute and drops the rest, as its tree does.

`core.attributes_of(&doc, node)` walks the attributes of an element in source order, and `attribute_next` gives each as a
`Key` token of its name and a `Plain` token of its value. An attribute's value has no kind, as an element's text has
none, so a schema's `"type": "integer"` and a model's `i64` member read `id="7"`. `core.fact_value` gives an element's
`Name` as written, its `Content` (its text and its descendants' in document order) and its `Namespace`.

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
selector list once into a `Selector`, which `css.destroy` frees, and `css.select_value(v, &sel, fold, paths)` gives
the value of each element it matches among the descendants of `v`, in document order. Over a node (`core.Node_Ref`) it
matches on the document, not the grouped value, so siblings and positions count across names as the text orders them.
Over the value an update made of one, built members are read as the update left them and nodes as the document has
them. It gives each match's value,
with its path from `v` through the grouped members when `paths` is set. A value an update put in place of an element keeps that element's
name and attributes where it writes none (`core.in_place_of`).

- A selector holds type and universal selectors, `#id`, `.class`, attribute selectors `[a]`, `[a=v]`, `[a~=v]`,
  `[a|=v]`, `[a^=v]`, `[a$=v]` and `[a*=v]` with a quoted or bare value and the `i` or `s` flag, the descendant, `>`,
  `+` and `~` combinators, lists with `,`, `:is`, `:where`, `:not`, `:has` with relative selectors (`:has(> img)`),
  `:first-child`, `:last-child`, `:only-child`, their `-of-type` forms, `:nth-child(An+B [of S])`, `:nth-last-child`,
  `:nth-of-type`, `:nth-last-of-type`, `:root` and `:empty`. Escapes are decoded, so an XML qualified name is
  `svg\:rect`.
- A dynamic or UI pseudo-class (`:hover`, `:checked`), a pseudo-element (`::before`, `:first-line`) and a namespace
  prefix (`svg|a`, `*|a`, `[xlink|href]`) are a `Fault` with the detail `Pseudo_Class`, `Pseudo_Element` or
  `Namespace` and the kind `.Bad_Char` at the first byte of the pseudo-class or the selector. A malformed selector is a
  `Fault` with `Syntax` at the byte that breaks it, or `.Truncated` at the end. `:is`, `:not`, `:has` and `of S` nest at
  most `css.MAX_NESTING` (32) deep, and a deeper one is `.Too_Deep`.
- An element is a member whose key is not `#text`. `:root` is the one element at the top of a document, which an HTML
  fragment of several nodes lacks. `:empty` is an element with no child element and no text. An element at the top counts its
  position among the root's members, as the root element of a browser's document matches `:first-child`.
- HTML compares element and attribute names ASCII case-insensitively (`Readers.fold_names`) and attribute values as
  written, those the standard lists as case-insensitive included, so `[type=TEXT]` needs `i` to match `type=text`. XML compares both as
  written. An `id` and a `class` are the attributes of those names in either format.

The match goes right to left over each element once, so a `>` or descendant step costs the depth. `+`, `~`, `:has` and
the counting pseudo-classes read siblings or subtrees and cost more. It allocates only the chain of open elements and
the answer.

## XML

`xml` reads XML 1.0 (Fifth Edition) well-formedness. It has `validate`, `walk`, `build`, `scan`, `find`,
`each_answer`, `query`, `as`, `checks` and `bind_schema`, each taking a constant `Spec` (`.Xml`), and `core`'s forms take a
spec chosen at run time as `xml.as(spec)`. The internal subset of the document type is read, as a processor that does not validate reads it, and
nothing else of a DTD: stury reads no external subset and no external entity. Only UTF-8 is read, with or without a
byte order mark.

### Tokens

| Source | Tokens |
|---|---|
| An element's start | `Key` with the qualified name as written (the byte after `<` is its `lo`) |
| An attribute | an `Attribute`-role fact after the key, `Plain`, spanning `name="value"` through the closing quote |
| An element with no child element | `Plain` over its content, with `n = 0` when empty. `SPELLING_DECODE` is set when the content holds `&`, a carriage return, a CDATA section, a comment or a processing instruction |
| An element with child elements | `Object` spanning the start tag, a `#text` `Key` and `Plain` for each run of text that is not only white space, each child as a member, `End` spanning the end tag |
| A processing instruction, the document type or the XML declaration | a fact with the `Instruction`, `Doctype` or `Directive` role |
| A comment | `Comment` before the token that follows it, given after the parent's `Object` when it stands before the parent's first child, `Comment_Inline` after a child that ends on its own line, `Comment_Foot` before an end tag that follows a child, and in an element with no child element the element's `Comment_Foot`, given between its key and its value |

An attribute fact's lead runs through the opening quote and its tail is the closing one, so
`core.facts_of(&doc, node, .Attribute)` gives the value as written.

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

The grammar is tail-called states over the text, as the JSON walk's is (`xml/walk.odin`), with the open elements as
frames on a stack of `core.MAX_DEPTH` that grows on the heap when `max_depth` asks for more. Character data, attribute
values, CDATA, comments and instructions are read in 64-byte blocks, one reader per x86 tier, each returning nil when it
cannot vouch for the block, and the byte-wise reader then finds the precise fault. Attribute names are checked for
repeats against 16 inline names, then a hash table.

### Namespaces

The walk reads namespaces by the W3C recommendation, so a name is a qualified name. A prefix needs a declaration in
scope (`xmlns:p`) when an element or an attribute uses it, `xml` is bound and may only be bound to its own URI,
`xmlns` is never declared or used as an element prefix, no prefix is bound to the empty string, and two attributes of
one element must not have the same namespace and local name. A processing instruction target has no colon. These are
the faults `qualified_name`, `unbound_prefix`, `reserved_prefix`, `reserved_namespace`, `empty_binding` and
`duplicate_expanded`. The walk keeps the declarations in scope on a stack of its own (`xml/scope.odin`).

A text that declares a namespace marks its keys, so a member lookup and a path step compare a name as written, or as
`{uri}local` against the declarations in scope, through `Readers.key_is`.

### The DTD

The internal subset is read by its grammar, every `markupdecl`: element type, attribute-list, entity and
notation declarations, comments, processing instructions and parameter-entity references between declarations. A
declaration that breaks its production faults with `element_declaration`, `attribute_declaration`,
`entity_declaration`, `notation_declaration` or `subset`, and a parameter-entity reference inside a declaration with
`parameter_reference`. The first declaration of an entity or an attribute binds it. The walk builds the tables on the heap and seals them
into one block, which a built document keeps as its `Token_View.state`, so a document's reads, and a check's, need
nothing but the document (`xml/dtd.odin`, `xml/entity.odin`).

- *General entities.* A reference to an internal entity reads as its replacement text. A replacement with no `<` is
  decoded by `text` like any reference. One with markup
  is walked in place over its literal's bytes in the internal subset, so its elements and
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
  character name the standard's table lists reads as its text there.

XML's `frozen` service names the nodes whose bytes lie in the internal subset, an entity's replacement text or an
attribute default, with the detail `replacement`, so an edit of such a node is `.Frozen`.

### Edits

`xml.set` and an XML edit list commit their edits as splices of the source, a commit that
HTML shares, since an element's name stands in two tags
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
- A fact edit of role `Comment` writes `<!--…-->` before the element (before the root element for `ROOT`),
  `Comment_Inline` after the element and `Comment_Foot` before its end tag (after the root element for `ROOT`), which
  an empty-element tag has no place for. Role `Attribute` takes a body `name="value"` written in the start tag after the name, the shape
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

## HTML

`html` reads HTML as the WHATWG HTML standard does: the tokenizer of section 13.2.5, the tree construction of section
13.2.6, which builds a document or a fragment, templates and foreign content (SVG and MathML) included, and the encoding
sniffing of section 13.2.3. The tree is built into the document an XML text with the same markup builds, so HTML is a
format on the same interface as XML. A typed read goes by the tag key `html`, through the markup layer XML's goes
through, over the tree the standard builds, so `<td>1<td>2` reads into a `[]T` member `td` of the `tr` and `tbody` the
tree implies. A text is one record, from the reader's position to the input's end, since a browser reads every byte past
`</html>` into the tree. The tokenizer and the tree are not public.

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
element that holds text. A value no object is `.Unwritable`.

`html.marshal` and the token write make their value in `write.MARKUP_TREE`, as XML's do, and `write.put_markup` reads it
back as a built value that `html.write`'s serialization writes, read back as above. A struct of one member `html` is
written as a document, so it must hold the `head` and `body` the tree implies. A token write to a stream is
`.Unsupported`, since the text is read back only once it is whole.

An HTML document does not answer what needs XML's declarations: there is no `{uri}local` path step and no attribute
lookup by expanded name. `html.scan`, `find` and `each_answer` always build the whole document, since the tree is whole
before its first token.

### Edits

`html.set` and an HTML edit list commit as XML's do, and an end tag the source leaves out stays out.

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
- Content in a void element is `void`, an array in an array `nested_array`, and a change of member order in an element that holds text `reordered`. A reorder elsewhere moves each element with its tags, the comments above it and the comment on its line, and the white space between the places stays.
- - The output is built again with the document's options and compared with the source document. A node no edit wrote
  reads as it did, and the content an edit wrote reads as it reads alone as a fragment in its element. A result that
  differs is `.Bad_Result` with the detail `reread` at the first byte that differs, so a `div` or `p` in a `p`, a `td`
  outside a table and a rename of `p` to `table` are refused.

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
the tree construction is `Bad_Char` at the token it reads. `Detail` holds the standard's tokenizer parse error codes, `-` read as `_`, then the tree construction's, which the
standard does not name (`Missing_Doctype`, `Unexpected_Start_Tag`, `Misnested_Tag` and others).

### Tokenizer and tree

The tokenizer (`html/tokenize.odin`, `html/states.odin`) follows the standard's states, one procedure each, tail-called
as XML's are. It hands each token and each parse error to the tree's hook, and the hook's answer to a start tag switches
the tokenizer into the text state the tree construction asks for. A token holds no text of its own: a name, a text and
an attribute are spans of the source with flags that say what decoding they need, so a span with no flags is its source
bytes. Runs of text, comments and quoted values are skipped 64 bytes at a time. Character references are read by one
procedure that both reports their errors and decodes them, through a trie generated from the standard's
`entities.json`.

The tree (`html/tree.odin`, `html/modes.odin`) is an arena of nodes linked by index, since the algorithm inserts before
a table, moves children and clones elements. A node keeps the source bytes of the token that made it, and a text node
is a list of spans. Flags mark an element no tag opened (`.Implied`), a clone (`.Cloned`) and a node placed away from
its source (`.Moved`), which is what the edit refusals below look at. Each insertion mode is a procedure that says
whether the token is read again in the mode it switched to. Foreign content, templates and the fragment algorithm go
through the same builder. The finished tree's tokens come in preorder, once to size the document and once to write it,
and what the spans cannot carry goes into the document's `Token_View.state`.
