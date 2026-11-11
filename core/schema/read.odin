// Reads a JSON Schema from a document into a `rules.Description`, whatever the format of the document and the draft
// the schema is written in.
package schema

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../regex"
import "../spell"
import core "../"
import "../rules"

// Where a schema's references may lead and how a file they name is read.
@(private)
Resolver :: struct {
	// The directory a reference to a `file:` URI may read from, "" for none. Absolute, or relative to the working
	// directory.
	root:      string,
	// How referenced files and the vendored meta-schemas are read: a format whose text is JSON.
	as:        core.As,
	// The draft of a schema with no `$schema`, 2020-12 when nil.
	draft:     Maybe(Draft),
	// Whether `format` asserts whatever the schema's vocabularies say.
	format_assert: bool,
	// The documents the references loaded and the texts they read, freed by `resolver_destroy`.
	documents: [dynamic]^core.Document,
	texts:     [dynamic][]u8,
	allocator: runtime.Allocator,
}

// Frees what the reads through `res` loaded.
@(private)
resolver_destroy :: proc(res: ^Resolver) {
	context.allocator = res.allocator
	for d in res.documents {
		core.destroy(d)
		free(d)
	}
	for t in res.texts {
		delete(t)
	}
	delete(res.documents)
	delete(res.texts)
	res.documents, res.texts = nil, nil
}

// A place in a source: a source's index in `Reader.sources` and a node of its document.
@(private)
Site :: struct {
	source: int,
	at:     core.Node_Index,
}

// What a schema is read with, and the resource a scope starts at `root` of its source: the document node of the schema
// resource, which becomes the node `resource`.
@(private)
Scope :: struct {
	source:   int,
	base:     string,
	draft:    Draft,
	vocab:    Vocabs,
	root:     core.Node_Index,
	resource: rules.Node_Index,
	// Whether the schema about to be read may be a boolean in draft 4, which takes it as an additional property or item.
	boolean:  bool,
}

@(private)
Anchor_Site :: struct {
	site:    Site,
	late:    bool,
}

// A reference the read met, resolved when every resource it may reach has been read.
@(private)
Pending :: struct {
	node:    rules.Node_Index,
	uri:     string,
	site:    Site,
	keyword: string,
	path:    []core.Step,
	late:    bool,
}

@(private)
Reader :: struct {
	d:         ^rules.Description,
	res:       ^Resolver,
	arena:     virtual.Arena,
	sources:   [dynamic]^core.Document,
	loaded:    map[string]int,
	memo:      map[Site]rules.Node_Index,
	resources: map[string]Scope,
	anchors:   map[string]Anchor_Site,
	pending:   [dynamic]Pending,
	// The members of each large object a pointer steps into, by name, since a document finds a member by a scan.
	indexes:   map[[2]int]map[string]core.Node_Index,
	anything:  Maybe(rules.Node_Index),
	path:      [dynamic]core.Step,
	// The base a root directory gives a schema that has no retrieval URI, which names no resource.
	local:     string,
	err:       core.Error,
}

// The name a 2019-09 recursive anchor is registered under, which no `$anchor` can spell.
@(private)
RECURSIVE :: "$recursive"

// Reads the schema at `node` of `doc`, whose retrieval URI is `base` ("" for none), into a description allocated with
// `allocator`. The description borrows number texts and `const` and `enum` values from `doc` and from the documents
// `res` loads, so both outlive it. A schema the reader refuses answers a `Bad_Schema` error that names the keyword.
@(private)
read :: proc(doc: ^core.Document, node: core.Node_Index, base: string, res: ^Resolver, allocator := context.allocator) -> (d: rules.Description, err: core.Error) {
	if res.allocator.procedure == nil {
		res.allocator = allocator
		res.documents = make([dynamic]^core.Document, allocator)
		res.texts = make([dynamic][]u8, allocator)
	}
	d = rules.Description {
		nodes     = make([dynamic]rules.Node, allocator),
		arrays    = make([dynamic]rules.Array, allocator),
		objects   = make([dynamic]rules.Object, allocator),
		texts     = make([dynamic]string, allocator),
		anchors   = make([dynamic]rules.Anchor, allocator),
		names     = make(map[rules.Node_Index]string, allocator),
		allocator = allocator,
	}
	r := Reader {
		d   = &d,
		res = res,
	}
	if virtual.arena_init_growing(&r.arena) != nil {
		rules.description_destroy(&d)
		return {}, .No_Memory
	}
	defer virtual.arena_destroy(&r.arena)
	context.allocator = virtual.arena_allocator(&r.arena)
	base := base
	if base != "" {
		base = uri_resolve(base, "")
	}
	if base == "" && res.root != "" {
		base = strings.concatenate({"file://", root_path(res), "/"})
		r.local = base
	}
	append(&r.sources, doc)
	read_root(&r, 0, node, base)
	if r.err == nil {
		resolve_all(&r)
	}
	if r.err != nil {
		rules.description_destroy(&d)
		return {}, r.err
	}
	return d, nil
}

// Reads the resource a source's `at` starts, which `uri` retrieves.
@(private)
read_root :: proc(r: ^Reader, source: int, at: core.Node_Index, uri: string) {
	sc := Scope {
		source   = source,
		base     = uri,
		draft    = r.res.draft.? or_else .D2020_12,
		vocab    = ALL_VOCABS,
		root     = at,
		resource = rules.Node_Index(len(r.d.nodes)),
	}
	read_schema(r, sc, at)
}

@(private)
read_schema :: proc(r: ^Reader, sc: Scope, at: core.Node_Index, steps: ..core.Step) -> rules.Node_Index {
	if r.err != nil {
		return 0
	}
	site := Site{sc.source, at}
	if i, ok := r.memo[site]; ok {
		return i
	}
	append(&r.path, ..steps)
	defer resize(&r.path, len(r.path) - len(steps))
	i := rules.Node_Index(len(r.d.nodes))
	append(&r.d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, resource = sc.resource})
	r.memo[site] = i
	doc := r.sources[sc.source]
	#partial switch core.kind(doc, at) {
	case .True, .False:
		if sc.draft == .D04 && !sc.boolean {
			fail(r, site, "schema", "is a boolean, which draft 4 takes only as additionalProperties and additionalItems")
		}
		r.d.nodes[i].kinds = {} if core.kind(doc, at) == .False else rules.EVERY_KIND
	case .Object:
		read_object(r, sc, at, i)
	case:
		fail(r, site, "schema", "must be an object or a boolean")
	}
	return i
}

// What the keywords of one object collect before they become the node's blocks.
@(private)
Shape :: struct {
	members:    [dynamic]rules.Member,
	required:   [dynamic]string,
	patterns:   [dynamic]rules.Pattern,
	dependents: [dynamic]rules.Dependent,
	prefix:     [dynamic]rules.Node_Index,
	object:     rules.Object,
	array:      rules.Array,
	is_object:  bool,
	is_array:   bool,
}

@(private)
read_object :: proc(r: ^Reader, sc: Scope, at: core.Node_Index, i: rules.Node_Index) {
	doc := r.sources[sc.source]
	sc := sc
	sc.boolean = false
	if v, ok := core.member(doc, at, "$schema"); ok && is_resource_root(r, sc, at) {
		uri, is_text := string_of(r, doc, v)
		if !is_text {
			fail(r, {sc.source, v}, "$schema", "must be a string")
			return
		}
		draft, vocab, why := dialect(r, uri_resolve(sc.base, uri))
		if why != "" {
			fail(r, {sc.source, v}, "$schema", why)
			return
		}
		sc.draft, sc.vocab = draft, vocab
	}
	// Before 2019-09 a `$ref` makes every keyword beside it void, but for the definitions a pointer may reach.
	ref, has_ref := core.member(doc, at, "$ref")
	overridden := has_ref && sc.draft <= .D07 && core.kind(doc, ref) == .String
	retrieved, starts := sc.base, at == sc.root
	if !overridden {
		read_id(r, &sc, at, i)
	}
	if i == 0 && sc.base != "" && sc.base != r.local {
		r.d.uri = keep(r, sc.base)
	}
	if sc.root == at {
		register_resource(r, sc, sc.base)
		if starts {
			register_resource(r, sc, retrieved)
		}
	}
	sh := Shape {
		object = {additional = rules.NONE, keys = rules.NONE},
		array = {items = rules.NONE},
	}
	n := rules.Node {
		kinds    = rules.EVERY_KIND,
		array    = -1,
		object   = -1,
		resource = sc.resource,
	}
	it := core.pairs(doc, at)
	for r.err == nil {
		k, v, more := core.pair_next(&it)
		if !more {
			break
		}
		name, _ := core.text_clone(doc, k)
		if !is_keyword(name, sc.draft, sc.vocab) || (overridden && name != "$ref" && name != "$defs" && name != "definitions") {
			continue
		}
		append(&r.path, core.Name(name))
		read_keyword(r, sc, i, at, &n, &sh, name, v)
		pop(&r.path)
	}
	if r.err != nil {
		return
	}
	finish_blocks(r, &n, &sh)
	r.d.nodes[i] = n
}

// Whether the object at `at` starts a schema resource: the root of a retrieval, or an object with an `$id` of its own.
@(private)
is_resource_root :: proc(r: ^Reader, sc: Scope, at: core.Node_Index) -> bool {
	doc := r.sources[sc.source]
	for name in ([?]string{"$id", "id"}) {
		v, has := core.member(doc, at, name)
		if text, is_text := string_of(r, doc, v); has && is_text && text != "" && text[0] != '#' {
			return true
		}
	}
	return at == sc.root
}

// Files the resource that `sc` starts under `key`. Two resources with the same URI are refused.
@(private)
register_resource :: proc(r: ^Reader, sc: Scope, key: string) {
	if prior, taken := r.resources[key]; taken && (prior.source != sc.source || prior.root != sc.root) {
		fail(r, {sc.source, sc.root}, "$id", "repeats the URI of another schema resource")
		return
	}
	r.resources[key] = sc
}

// A draft before 2019-09 may write an anchor as a plain-name fragment of `$id`.
@(private)
read_id :: proc(r: ^Reader, sc: ^Scope, at: core.Node_Index, i: rules.Node_Index) {
	doc := r.sources[sc.source]
	name := "id" if sc.draft == .D04 else "$id"
	v, ok := core.member(doc, at, name)
	if !ok {
		return
	}
	text, is_text := string_of(r, doc, v)
	if !is_text {
		fail(r, {sc.source, v}, name, "must be a string")
		return
	}
	resource, _, fragment := strings.partition(uri_resolve(sc.base, text), "#")
	if fragment != "" && sc.draft > .D07 {
		fail(r, {sc.source, v}, name, "must not have a fragment")
		return
	}
	if fragment != "" && is_anchor(fragment) {
		register_anchor(r, sc^, {sc.source, at}, resource, fragment, name, false, i)
	}
	if text != "" && text[0] != '#' {
		sc.base, sc.root, sc.resource = resource, at, i
		if sc.source == 0 && len(r.path) > 0 && !through_ref(r.path[:]) {
			add_base(r, resource)
		}
	}
}

// Files the resource `uri` that the root reaches in place at `r.path` as the base of the keyword locations under it.
@(private)
add_base :: proc(r: ^Reader, uri: string) {
	steps := make([]core.Step, len(r.path), r.d.allocator)
	for s, k in r.path {
		steps[k] = s
		if name, named := s.(core.Name); named {
			steps[k] = core.Name(keep(r, string(name)))
		}
	}
	if r.d.bases == nil {
		r.d.bases = make([dynamic]rules.Base, r.d.allocator)
	}
	append(&r.d.bases, rules.Base{steps, keep(r, uri)})
}

// Names node `i` `name` unless it has a name.
@(private)
named :: proc(r: ^Reader, i: rules.Node_Index, name: string) {
	if i not_in r.d.names {
		r.d.names[i] = keep(r, name)
	}
}

// Files the anchor of the schema at `site` under its resource `base`.
@(private)
register_anchor :: proc(r: ^Reader, sc: Scope, site: Site, base, name, keyword: string, late: bool, i: rules.Node_Index) {
	key := strings.concatenate({base, "#", name})
	if _, taken := r.anchors[key]; taken {
		fail(r, site, keyword, "repeats an anchor of its resource")
		return
	}
	r.anchors[key] = {site, late}
	named(r, i, name)
	if late {
		append(&r.d.anchors, rules.Anchor{keep(r, name), sc.resource, i})
	}
}

@(private)
read_keyword :: proc(r: ^Reader, sc: Scope, i: rules.Node_Index, at: core.Node_Index, n: ^rules.Node, sh: ^Shape, name: string, v: core.Node_Index) {
	doc := r.sources[sc.source]
	site := Site{sc.source, v}
	kind := core.kind(doc, v)
	switch name {
	case "$schema", "$id", "id":
	// Read before the members.
	case "$ref", "$dynamicRef":
		if text, ok := string_of(r, doc, v); ok {
			pend(r, sc, i, site, name, uri_resolve(sc.base, text), name == "$dynamicRef")
		} else {
			fail(r, site, name, "must be a string")
		}
	case "$recursiveRef":
		// `#` reaches the resource's recursive anchor, or the resource's root where it has none.
		if text, ok := string_of(r, doc, v); !ok || text != "#" {
			fail(r, site, name, "must be \"#\"")
		} else {
			anchor, _ := core.member(doc, sc.root, "$recursiveAnchor")
			recursive := core.kind(doc, anchor) == .True
			pend(r, sc, i, site, name, strings.concatenate({sc.base, "#", RECURSIVE if recursive else ""}), recursive)
		}
	case "$anchor", "$dynamicAnchor":
		if text, ok := string_of(r, doc, v); ok && is_anchor(text) {
			register_anchor(r, sc, {sc.source, at}, sc.base, text, name, name == "$dynamicAnchor", i)
		} else {
			fail(r, site, name, "must be a plain name")
		}
	case "$recursiveAnchor":
		if kind != .True && kind != .False {
			fail(r, site, name, "must be a boolean")
		} else if kind == .True && at == sc.root {
			register_anchor(r, sc, {sc.source, at}, sc.base, RECURSIVE, name, true, i)
		}
	case "$vocabulary":
		read_vocabulary(r, sc, site, name)
	case "$defs", "definitions":
		for e in members_of(r, sc, v, name) {
			named(r, read_schema(r, sc, e.v, core.Name(e.key)), e.key)
		}
	case "prefixItems", "items":
		sh.is_array = true
		if name == "prefixItems" || kind == .Array && sc.draft != .D2020_12 {
			sh.array.tuple = name == "items"
			append(&sh.prefix, ..schemas_of(r, sc, v, name))
		} else {
			sh.array.items = read_schema(r, sc, v)
		}
	case "additionalItems":
		// It judges the elements past a tuple, which only a tuple `items` has.
		if items, ok := core.member(doc, at, "items"); ok && core.kind(doc, items) == .Array {
			sh.is_array = true
			boolean := sc
			boolean.boolean = true
			sh.array.items = read_schema(r, boolean, v)
		}
	case "contains":
		sh.is_array = true
		sh.array.contains = read_schema(r, sc, v)
		sh.array.evaluates_contains = sc.draft >= .D2020_12
	case "maxContains":
		sh.array.max_contains, _ = count_of(r, doc, site, name)
	case "minContains":
		sh.array.min_contains, _ = count_of(r, doc, site, name)
	case "additionalProperties":
		sh.is_object = true
		boolean := sc
		boolean.boolean = true
		sh.object.additional = read_schema(r, boolean, v)
	case "propertyNames":
		sh.is_object = true
		sh.object.keys = read_schema(r, sc, v)
	case "properties":
		sh.is_object = true
		for e in members_of(r, sc, v, name) {
			append(&sh.members, rules.Member{name = keep(r, e.key), node = read_schema(r, sc, e.v, core.Name(e.key))})
		}
	case "patternProperties":
		sh.is_object = true
		for e in members_of(r, sc, v, name) {
			if why := pattern_refusal(e.key); why == "" {
				append(&sh.patterns, rules.Pattern{keep(r, e.key), read_schema(r, sc, e.v, core.Name(e.key))})
			} else {
				fail(r, {sc.source, e.v}, name, strings.concatenate({"holds a name that is no regular expression: ", why}, context.temp_allocator))
			}
		}
	case "dependentSchemas", "dependentRequired", "dependencies":
		// An array of names or a schema, as the keyword allows.
		sh.is_object = true
		sh.object.dependencies = name == "dependencies"
		for e in members_of(r, sc, v, name) {
			names := core.kind(doc, e.v) == .Array
			switch {
			case names && name == "dependentSchemas", !names && name == "dependentRequired":
				fail(r, {sc.source, e.v}, name, "holds a value its keyword does not take")
			case names:
				if required, ok := strings_of(r, sc, e.v, name); ok {
					append(&sh.dependents, rules.Dependent{name = keep(r, e.key), required = required})
				}
			case:
				append(&sh.dependents, rules.Dependent{name = keep(r, e.key), node = read_schema(r, sc, e.v, core.Name(e.key))})
			}
		}
	case "required":
		sh.is_object = true
		if names, ok := strings_of(r, sc, v, name); ok {
			if sc.draft == .D04 && len(names) == 0 {
				fail(r, site, name, "must name at least one property in draft 4")
			}
			append(&sh.required, ..names)
			delete(names, r.d.allocator)
		}
	case "if":
		n.cond.test = read_schema(r, sc, v)
	case "then":
		n.cond.then = read_schema(r, sc, v)
	case "else":
		n.cond.other = read_schema(r, sc, v)
	case "not":
		n.not = read_schema(r, sc, v)
	case "allOf":
		n.all_of = own(r, schemas_of(r, sc, v, name))
	case "anyOf":
		n.any_of = own(r, schemas_of(r, sc, v, name))
	case "oneOf":
		n.one_of = own(r, schemas_of(r, sc, v, name))
	case "unevaluatedItems":
		n.unevaluated_items = read_schema(r, sc, v)
	case "unevaluatedProperties":
		n.unevaluated_properties = read_schema(r, sc, v)
	case "type":
		n.kinds = types_of(r, doc, site)
		n.integer_spelled = sc.draft == .D04 && .Integer in n.kinds
	case "const":
		n.const_of = core.Value(core.Node_Ref{doc, v})
	case "enum":
		n.enum_of, n.has_enum = values_of(r, doc, site, name), true
	case "multipleOf":
		if text, ok := number_of(r, doc, site, name); ok {
			if d := spell.decimal_of(text); d.head == "" || d.neg {
				fail(r, site, name, "must be above zero")
			}
			n.rules.multiple_of = text
		}
	case "maximum", "minimum":
		if text, ok := number_of(r, doc, site, name); ok {
			// Draft-04 makes the bound exclusive with a boolean beside it.
			beside, _ := core.member(doc, at, "exclusiveMaximum" if name == "maximum" else "exclusiveMinimum")
			bound(&n.rules, name == "minimum", text, sc.draft == .D04 && core.kind(doc, beside) == .True)
		}
	case "exclusiveMaximum", "exclusiveMinimum":
		if sc.draft == .D04 {
			if kind != .True && kind != .False {
				fail(r, site, name, "must be a boolean")
			}
		} else if text, ok := number_of(r, doc, site, name); ok {
			bound(&n.rules, name == "exclusiveMinimum", text, true)
		}
	case "maxLength":
		n.rules.max_length, _ = count_of(r, doc, site, name)
	case "minLength":
		n.rules.min_length, _ = count_of(r, doc, site, name)
	case "maxItems":
		n.rules.max_items, _ = count_of(r, doc, site, name)
	case "minItems":
		n.rules.min_items, _ = count_of(r, doc, site, name)
	case "maxProperties":
		n.rules.max_members, _ = count_of(r, doc, site, name)
	case "minProperties":
		n.rules.min_members, _ = count_of(r, doc, site, name)
	case "uniqueItems":
		if kind != .True && kind != .False {
			fail(r, site, name, "must be a boolean")
		}
		n.rules.unique = kind == .True
	case "readOnly", "writeOnly":
		if kind != .True && kind != .False {
			fail(r, site, name, "must be a boolean")
		}
		if name == "readOnly" {
			n.rules.read_only = kind == .True
		} else {
			n.rules.write_only = kind == .True
		}
	case "pattern":
		if text, ok := string_of(r, doc, v); !ok {
			fail(r, site, name, "must be a string")
		} else if why := pattern_refusal(text); why != "" {
			fail(r, site, name, strings.concatenate({"is no regular expression: ", why}, context.temp_allocator))
		} else {
			n.rules.pattern = keep(r, text)
		}
	case "description":
		if text, ok := string_of(r, doc, v); ok {
			n.description = keep(r, text)
		}
	case "title", "contentEncoding", "contentMediaType":
		if text, ok := string_of(r, doc, v); ok {
			switch name {
			case "title":
				n.title = keep(r, text)
			case "contentEncoding":
				n.content_encoding = keep(r, text)
			case "contentMediaType":
				n.content_media_type = keep(r, text)
			}
		} else {
			fail(r, site, name, "must be a string")
		}
	case "deprecated":
		if kind != .True && kind != .False {
			fail(r, site, name, "must be a boolean")
		}
		n.deprecated = kind == .True
	case "default":
		n.default_of = core.Value(core.Node_Ref{doc, v})
	case "examples":
		n.examples = values_of(r, doc, site, name)
	case "xml":
		// OpenAPI's keyword: only the node type is read.
		if node, has := core.member(doc, v, "nodeType"); has {
			text, _ := string_of(r, doc, node)
			switch text {
			case "attribute":
				n.rules.markup = .Attribute
			case "element":
				n.rules.markup = .Element
			case "text":
				n.rules.markup = .Text
			}
		}
	case "format":
		if text, ok := string_of(r, doc, v); ok {
			format := rules.format_of(text)
			asserts := .Format_Assert in sc.vocab || r.res.format_assert
			// Only the 2020-12 format-assertion vocabulary refuses a format it cannot judge. The option and the
			// 2019-09 format vocabulary leave it an annotation, as the suite's optional format tests ask.
			if format == .None && .Format_Assert in sc.vocab && sc.draft >= .D2020_12 {
				fail(r, site, name, "is a format no check judges, which the format-assertion vocabulary refuses")
			}
			n.rules.format, n.rules.format_foreign = keep(r, text), FORMAT_DRAFTS[format] > sc.draft
			n.rules.assert_format = asserts && !n.rules.format_foreign
		} else {
			fail(r, site, name, "must be a string")
		}
	}
}

// The blocks of the arrays and objects the keywords of a node described, and the node's `required` names in them.
@(private)
finish_blocks :: proc(r: ^Reader, n: ^rules.Node, sh: ^Shape) {
	d := r.d
	if n.cond.test == nil {
		n.cond = {}
	}
	if sh.array.contains == nil {
		sh.array.min_contains, sh.array.max_contains = nil, nil
	}
	if sh.is_array {
		sh.array.prefix = own(r, sh.prefix[:])
		n.array = i32(len(d.arrays))
		append(&d.arrays, sh.array)
	}
	for required in sh.required {
		found := false
		for &m in sh.members {
			if m.name == required {
				m.required, found = true, true
			}
		}
		if !found {
			append(&sh.members, rules.Member{name = required, node = any_node(r), required = true, only_required = true})
		}
	}
	if sh.is_object {
		sh.object.members = own(r, sh.members[:])
		sh.object.patterns = own(r, sh.patterns[:])
		sh.object.dependents = own(r, sh.dependents[:])
		n.object = i32(len(d.objects))
		append(&d.objects, sh.object)
	}
}

// The node that takes any value, for a name a schema requires and does not describe.
@(private)
any_node :: proc(r: ^Reader) -> rules.Node_Index {
	if r.anything == nil {
		r.anything = rules.Node_Index(len(r.d.nodes))
		append(&r.d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1})
	}
	return r.anything.?
}

// Narrows the lower or upper bound of `rl` to `text` where it is tighter.
@(private)
bound :: proc(rl: ^rules.Rules, lower: bool, text: string, strict: bool) {
	exclusive := strict
	have, flag := &rl.maximum, &rl.exclusive_maximum
	if lower {
		have, flag = &rl.minimum, &rl.exclusive_minimum
	}
	if have^ != "" {
		order := spell.decimal_compare(spell.decimal_of(text), spell.decimal_of(have^))
		if order == 0 {
			exclusive = exclusive || flag^
		} else if (order > 0) != lower {
			return
		}
	}
	have^, flag^ = text, exclusive
}

@(private, rodata)
TYPE_KINDS := [?]struct {
	name:  string,
	kinds: rules.Kinds,
} {
	{"null", {.Null}},
	{"boolean", {.Bool}},
	{"integer", {.Integer}},
	{"number", {.Number}},
	{"string", {.String}},
	{"array", {.Array}},
	{"object", {.Object}},
}

@(private)
types_of :: proc(r: ^Reader, doc: ^core.Document, site: Site) -> (kinds: rules.Kinds) {
	names := make([dynamic]core.Node_Index)
	#partial switch core.kind(doc, site.at) {
	case .String:
		append(&names, site.at)
	case .Array:
		it := core.children(doc, site.at)
		for c in core.child_next(&it) {
			append(&names, c)
		}
	case:
		fail(r, site, "type", "must be a name or an array of names")
		return
	}
	if len(names) == 0 {
		fail(r, site, "type", "must name at least one type")
	}
	seen: bit_set[0 ..< len(TYPE_KINDS)]
	for c in names {
		text, is_text := string_of(r, doc, c)
		found := -1
		for t, k in TYPE_KINDS {
			if is_text && t.name == text {
				found = k
			}
		}
		switch {
		case found < 0:
			fail(r, site, "type", "holds a name that is no type")
		case found in seen:
			fail(r, site, "type", "repeats a type")
		}
		if found >= 0 {
			seen += {found}
			kinds += TYPE_KINDS[found].kinds
		}
	}
	return
}

// The values of the array at `site`, as nodes of the document.
@(private)
values_of :: proc(r: ^Reader, doc: ^core.Document, site: Site, name: string) -> []core.Value {
	if core.kind(doc, site.at) != .Array {
		fail(r, site, name, "must be an array")
		return nil
	}
	out := make([dynamic]core.Value, r.d.allocator)
	it := core.children(doc, site.at)
	for c in core.child_next(&it) {
		append(&out, core.Node_Ref{doc, c})
	}
	return out[:]
}

// The text of a number, which the description borrows from the document.
@(private)
number_of :: proc(r: ^Reader, doc: ^core.Document, site: Site, name: string) -> (string, bool) {
	if core.kind(doc, site.at) != .Number {
		fail(r, site, name, "must be a number")
		return "", false
	}
	return string(core.span(doc, site.at)), true
}

// A count: a number with no fraction that is not below zero. One past what 64 bits hold is the greatest count.
@(private)
count_of :: proc(r: ^Reader, doc: ^core.Document, site: Site, name: string) -> (n: u64, ok: bool) {
	text := number_of(r, doc, site, name) or_return
	d := spell.decimal_of(text)
	zeros := d.point - i128(len(d.head))
	if d.wide != "" {
		zeros = 1 if !d.wide_neg else -1
	}
	if d.neg || d.tail != "" || (d.head != "" && zeros < 0) {
		fail(r, site, name, "must be a whole number, not below zero")
		return
	}
	if d.head == "" {
		return 0, true
	}
	if zeros > 20 || d.wide != "" {
		return max(u64), true
	}
	count, parsed := strconv.parse_u64(strings.concatenate({d.head, strings.repeat("0", int(zeros))}), 10)
	return count if parsed else max(u64), true
}

@(private)
string_of :: proc(r: ^Reader, doc: ^core.Document, v: core.Node_Index) -> (string, bool) {
	if core.kind(doc, v) != .String {
		return "", false
	}
	return core.text_clone(doc, v)
}

// The description's own copy of `s`.
@(private)
keep :: proc(r: ^Reader, s: string) -> string {
	t := strings.clone(s, r.d.allocator)
	append(&r.d.texts, t)
	return t
}

// `xs` in the description's allocator, nil for none.
@(private)
own :: proc(r: ^Reader, xs: []$T) -> []T {
	return slice.clone(xs, r.d.allocator) if len(xs) > 0 else nil
}

// The schemas of the non-empty array at `v`.
@(private)
schemas_of :: proc(r: ^Reader, sc: Scope, v: core.Node_Index, name: string) -> []rules.Node_Index {
	doc := r.sources[sc.source]
	if core.kind(doc, v) != .Array || core.length(doc, v) == 0 {
		fail(r, {sc.source, v}, name, "must be an array with a schema in it")
		return nil
	}
	out := make([dynamic]rules.Node_Index)
	it := core.children(doc, v)
	for c in core.child_next(&it) {
		append(&out, read_schema(r, sc, c, core.Index(len(out))))
	}
	return out[:]
}

// The strings of the array at `v` as the description's own.
@(private)
strings_of :: proc(r: ^Reader, sc: Scope, v: core.Node_Index, name: string) -> (names: []string, ok: bool) {
	doc := r.sources[sc.source]
	if core.kind(doc, v) != .Array {
		fail(r, {sc.source, v}, name, "must be an array of names")
		return
	}
	out := make([dynamic]string, r.d.allocator)
	it := core.children(doc, v)
	for c in core.child_next(&it) {
		text, is_text := string_of(r, doc, c)
		if !is_text {
			fail(r, {sc.source, v}, name, "must be an array of names")
			delete(out)
			return
		}
		append(&out, keep(r, text))
	}
	return out[:], true
}

// A member of an object: the key's text and the value's node.
@(private)
Entry :: struct {
	key: string,
	v:   core.Node_Index,
}

// The members of the object at `v`, refused as `name`'s when it is no object.
@(private)
members_of :: proc(r: ^Reader, sc: Scope, v: core.Node_Index, name: string) -> (out: []Entry) {
	doc := r.sources[sc.source]
	if core.kind(doc, v) != .Object {
		fail(r, {sc.source, v}, name, "must be an object")
		return
	}
	entries := make([dynamic]Entry)
	it := core.pairs(doc, v)
	for k, value in core.pair_next(&it) {
		key, _ := core.text_clone(doc, k)
		append(&entries, Entry{key, value})
	}
	return entries[:]
}

// Why `expression` does not compile as the ECMA 262 expression a schema's patterns are, "" when it does.
@(private)
pattern_refusal :: proc(expression: string) -> string {
	return regex.refusal(expression, {ecma = true}, context.temp_allocator)
}

// Refuses the read at `site`: `keyword` names the keyword and `why` says what its value is missing.
@(private)
fail :: proc(r: ^Reader, site: Site, keyword, why: string) {
	if r.err != nil {
		return
	}
	e := core.Typed_Refusal {
		kind = .Bad_Schema,
		at   = u64(r.sources[site.source].nodes[site.at].lo),
	}
	e.want.text = strings.concatenate({keyword, ": ", why}, context.temp_allocator)
	kept := r.path[max(0, len(r.path) - core.MAX_ERROR_STEPS):]
	for s, k in kept {
		e.steps[k] = s
		if name, named := s.(core.Name); named {
			e.steps[k] = core.Name(strings.clone(string(name), context.temp_allocator))
		}
	}
	e.n_steps, e.truncated = u8(len(kept)), len(kept) < len(r.path)
	r.err = core.error_of(e)
}
