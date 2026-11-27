// Reads a JSON Schema (Draft 4, 6, 7, 2019-09, or 2020-12) from any `tape.Document` into a `rules.Description`.
// Explicit heap frame stack (`Reader.frames`), zero `core:mem/virtual`, zero `core:os`, zero `context.temp_allocator`, WASM-clean.
package schema

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

Parse_Proc :: #type proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> (doc: tape.Document, err: tape.Error)
Doc_Load_Proc :: #type proc(data: rawptr, uri: string, allocator: runtime.Allocator) -> (doc: tape.Document, owned: bool, found: bool, err: Error)
Bytes_Load_Proc :: #type proc(data: rawptr, uri: string, allocator: runtime.Allocator) -> (bytes: []u8, owned: bool, found: bool)

Ref_Loader :: struct {
	load_doc:   Doc_Load_Proc,
	load_bytes: Bytes_Load_Proc,
	data:       rawptr,
}

Resolver :: struct {
	loader:        Ref_Loader,
	parse:         Parse_Proc,
	parse_data:    rawptr,
	draft:         Maybe(Draft),
	format_assert: bool,
	documents:     [dynamic]Owned_Doc,
	texts:         [dynamic][]u8,
	allocator:     runtime.Allocator,
}

@(private)
Owned_Doc :: struct {
	doc:   ^tape.Document,
	owned: bool,
}

resolver_destroy :: proc(res: ^Resolver) {
	if res == nil { return }
	a := res.allocator
	for item in res.documents {
		if item.owned && item.doc != nil { tape.destroy_document(item.doc) }
		if item.doc != nil { free(item.doc, a) }
	}
	for t in res.texts { delete(t, a) }
	delete(res.documents)
	delete(res.texts)
	res.documents, res.texts = nil, nil
}

@(private)
Site :: struct {
	source: int,
	at:     tape.Node_Index,
}

@(private)
Scope :: struct {
	source:   int,
	base:     string,
	draft:    Draft,
	vocab:    Vocabs,
	root:     tape.Node_Index,
	resource: rules.Node_Index,
	boolean:  bool,
}

@(private)
Anchor_Site :: struct {
	site: Site,
	late: bool,
}

@(private)
Pending :: struct {
	node:    rules.Node_Index,
	uri:     string,
	site:    Site,
	keyword: string,
	path:    []tape.Step,
	late:    bool,
}

@(private)
Reader :: struct {
	d:         ^rules.Description,
	res:       ^Resolver,
	arena:     mem.Dynamic_Arena,
	scratch:   runtime.Allocator,
	err_alloc: runtime.Allocator,
	sources:   [dynamic]^tape.Document,
	loaded:    map[string]int,
	memo:      map[Site]rules.Node_Index,
	resources: map[string]Scope,
	anchors:   map[string]Anchor_Site,
	pending:   [dynamic]Pending,
	indexes:   map[[2]int]map[string]tape.Node_Index,
	anything:  Maybe(rules.Node_Index),
	path:      [dynamic]tape.Step,
	frames:    [dynamic]Frame,
	err:       Error,
}

@(private)
RECURSIVE :: "$recursive"

@(require_results)
read :: proc(doc: ^tape.Document, node := tape.ROOT, base := "", res: ^Resolver = nil, allocator := context.allocator) -> (rules.Description, Error) {
	if doc == nil || len(doc.nodes) == 0 || int(node) >= len(doc.nodes) {
		return {}, make_error(.Bad_Option, "document", "schema document is empty", allocator = allocator)
	}
	local_res: Resolver
	active_res := res if res != nil else &local_res
	defer if res == nil { resolver_destroy(&local_res) }
	if active_res.allocator.procedure == nil {
		active_res.allocator = allocator
		active_res.documents.allocator = allocator
		active_res.texts.allocator = allocator
	}

	d := rules.Description {
		nodes     = make([dynamic]rules.Node, allocator),
		arrays    = make([dynamic]rules.Array, allocator),
		objects   = make([dynamic]rules.Object, allocator),
		texts     = make([dynamic]string, allocator),
		anchors   = make([dynamic]rules.Anchor, allocator),
		names     = make(map[rules.Node_Index]string, allocator),
		bases     = make([dynamic]rules.Base, allocator),
		allocator = allocator,
	}

	r := Reader{d = &d, res = active_res, err_alloc = allocator}
	mem.dynamic_arena_init(&r.arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&r.arena)
	r.scratch = mem.dynamic_arena_allocator(&r.arena)

	r.sources.allocator, r.pending.allocator, r.path.allocator, r.frames.allocator = r.scratch, r.scratch, r.scratch, r.scratch
	r.loaded = make(map[string]int, 8, r.scratch)
	r.memo = make(map[Site]rules.Node_Index, 32, r.scratch)
	r.resources = make(map[string]Scope, 8, r.scratch)
	r.anchors = make(map[string]Anchor_Site, 8, r.scratch)
	r.indexes = make(map[[2]int]map[string]tape.Node_Index, 4, r.scratch)

	norm_base := uri_resolve(base, "", r.scratch) if base != "" else ""
	append(&r.sources, doc)
	read_root(&r, 0, node, norm_base)
	if r.err.kind == .None { resolve_all(&r) }
	if r.err.kind == .None && res == nil && len(local_res.documents) > 0 && !detach_local_refs(&d, local_res.documents[:], r.scratch) {
		r.err = make_error(.Bad_Option, "$ref", "external schema contains non-scalar literal; pass a Resolver to keep loaded documents alive", allocator = allocator)
	}
	if r.err.kind != .None {
		rules.description_destroy(&d)
		return {}, r.err
	}
	return d, {}
}

@(private = "file")
detach_local_refs :: proc(d: ^rules.Description, docs: []Owned_Doc, scratch: runtime.Allocator) -> bool {
	materialize :: proc(d: ^rules.Description, docs: []Owned_Doc, v: rules.Value, scratch: runtime.Allocator) -> (rules.Value, bool) {
		nr, is_ref := v.(rules.Node_Ref)
		if !is_ref { return v, true }
		local := false
		for od in docs { if od.doc == nr.doc { local = true; break } }
		if !local { return v, true }
		if nr.doc == nil || nr.node == tape.NO_NODE || int(nr.node) >= len(nr.doc.nodes) { return nil, false }
		switch nr.doc.nodes[nr.node].kind {
		case .Null:  return rules.Null{}, true
		case .True:  return bool(true), true
		case .False: return bool(false), true
		case .Number:
			txt, ok := doc_node_number_text(nr.doc, nr.node, d.allocator)
			if !ok { return nil, false }
			append(&d.texts, txt)
			return rules.Number_Text{text = txt}, true
		case .String, .Plain:
			txt, ok := doc_node_string(nr.doc, nr.node, d.allocator)
			if !ok { return nil, false }
			append(&d.texts, txt)
			return txt, true
		case .Array, .Object:
			n, _, lerr := tape.length({doc = nr.doc}, nr.node, scratch)
			if lerr == nil && n == 0 {
				return (([]rules.Value)(nil) if nr.doc.nodes[nr.node].kind == .Array else ([]rules.Member_Value)(nil)), true
			}
		case .Bytes, .End:
		}
		return nil, false
	}
	for &n in d.nodes {
		for list in ([2][]rules.Value{n.enum_of, n.examples}) {
			for &v in list { v = materialize(d, docs, v, scratch) or_return }
		}
		if c, has := n.const_of.?; has { n.const_of = materialize(d, docs, c, scratch) or_return }
		if df, has := n.default_of.?; has { n.default_of = materialize(d, docs, df, scratch) or_return }
	}
	return true
}

@(private)
read_root :: proc(r: ^Reader, source: int, at: tape.Node_Index, uri: string) {
	sc := Scope{source = source, base = uri, draft = r.res.draft.? or_else .D2020_12, vocab = ALL_VOCABS, root = at, resource = rules.Node_Index(len(r.d.nodes))}
	_ = read_schema(r, sc, at)
	if r.err.kind == .None && uri != "" && uri not_in r.resources {
		register_resource(r, sc, uri)
	}
}

@(private)
read_schema :: proc(r: ^Reader, sc: Scope, at: tape.Node_Index, steps: ..tape.Step) -> rules.Node_Index {
	i, opened := schema_enter(r, sc, at, steps)
	if !opened { return i }
	for base := len(r.frames) - 1; len(r.frames) > base; {
		if r.err.kind == .None {
			frame_step(r)
			continue
		}
		f := pop(&r.frames)
		if f.it_open { tape.destroy_children(&f.it) }
		resize(&r.path, f.path)
	}
	return i
}

@(private)
schema_enter :: proc(r: ^Reader, sc: Scope, at: tape.Node_Index, steps: []tape.Step) -> (i: rules.Node_Index, opened: bool) {
	if r.err.kind != .None { return 0, false }
	site := Site{sc.source, at}
	if known, ok := r.memo[site]; ok { return known, false }
	path := len(r.path)
	append(&r.path, ..steps)
	i = rules.Node_Index(len(r.d.nodes))
	append(&r.d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, resource = sc.resource})
	r.memo[site] = i
	k := r.sources[sc.source].nodes[at].kind
	#partial switch k {
	case .True, .False:
		if sc.draft == .D04 && !sc.boolean {
			fail(r, site, "schema", "is a boolean, which draft 4 takes only as additionalProperties and additionalItems")
		}
		r.d.nodes[i].kinds = {} if k == .False else rules.EVERY_KIND
	case .Object:
		if frame_open(r, sc, at, i, path) { return i, true }
	case:
		fail(r, site, "schema", "must be an object or a boolean")
	}
	resize(&r.path, path)
	return i, false
}

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
Frame :: struct {
	sc:         Scope,
	at:         tape.Node_Index,
	i:          rules.Node_Index,
	path:       int,
	n:          rules.Node,
	sh:         Shape,
	it:         tape.Children,
	it_open:    bool,
	overridden: bool,
	keyword:    string,
	subs:       [dynamic]Sub,
	next:       int,
	list:       [dynamic]rules.Node_Index,
}

@(private)
Sub :: struct {
	v:       tape.Node_Index,
	key:     string,
	step:    tape.Step,
	stepped: bool,
	boolean: bool,
}

@(private)
doc_member :: proc(doc: ^tape.Document, at: tape.Node_Index, name: string) -> (tape.Node_Index, bool) {
	node, p := tape.member({doc = doc}, at, name, .Last)
	return node, p == .Found
}

@(private)
doc_length :: proc(r: ^Reader, doc: ^tape.Document, at: tape.Node_Index) -> int {
	n, p, _ := tape.length({doc = doc}, at, r.scratch)
	return n if p == .Found else 0
}

@(private)
frame_open :: proc(r: ^Reader, sc: Scope, at: tape.Node_Index, i: rules.Node_Index, path: int) -> bool {
	doc := r.sources[sc.source]
	sc := sc
	sc.boolean = false
	if v, ok := doc_member(doc, at, "$schema"); ok && is_resource_root(r, sc, at) {
		uri, is_text := string_of(r, doc, v)
		if !is_text { fail(r, {sc.source, v}, "$schema", "must be a string"); return false }
		draft, vocab, why := dialect(r, uri_resolve(sc.base, uri, r.scratch))
		if why != "" { fail(r, {sc.source, v}, "$schema", why); return false }
		sc.draft, sc.vocab = draft, vocab
	}
	ref, has_ref := doc_member(doc, at, "$ref")
	overridden := has_ref && sc.draft <= .D07 && doc.nodes[ref].kind == .String
	retrieved, starts := sc.base, at == sc.root
	if !overridden {
		read_id(r, &sc, at, i)
		if r.err.kind != .None { return false }
	}
	if i == 0 && sc.base != "" { r.d.uri = keep(r, sc.base) }
	if sc.root == at {
		register_resource(r, sc, sc.base)
		if starts && retrieved != sc.base { register_resource(r, sc, retrieved) }
		if r.err.kind != .None { return false }
	}
	it, p, err := tape.children({doc = doc}, at, r.scratch)
	if err != nil { fail(r, {sc.source, at}, "schema", "out of memory"); return false }
	sh := Shape {
		members    = make([dynamic]rules.Member, r.scratch),
		required   = make([dynamic]string, r.scratch),
		patterns   = make([dynamic]rules.Pattern, r.scratch),
		dependents = make([dynamic]rules.Dependent, r.scratch),
		prefix     = make([dynamic]rules.Node_Index, r.scratch),
		object     = {additional = rules.NONE, keys = rules.NONE},
		array      = {items = rules.NONE},
	}
	append(&r.frames, Frame{
		sc = sc, at = at, i = i, path = path,
		n = {kinds = rules.EVERY_KIND, array = -1, object = -1, resource = sc.resource},
		sh = sh, it = it, it_open = p == .Found, overridden = overridden,
		subs = make([dynamic]Sub, r.scratch), list = make([dynamic]rules.Node_Index, r.scratch),
	})
	return true
}

@(private)
frame_step :: proc(r: ^Reader) {
	at := len(r.frames) - 1
	f := &r.frames[at]
	if f.keyword != "" {
		if f.next == len(f.subs) {
			keyword_close(r, f)
			f.keyword = ""
			pop(&r.path)
			return
		}
		sub := f.subs[f.next]
		f.next += 1
		if !sub_before(r, f, sub) { return }
		sc := f.sc
		sc.boolean = sub.boolean
		steps := [1]tape.Step{sub.step}
		i, _ := schema_enter(r, sc, sub.v, steps[:1 if sub.stepped else 0])
		sub_read(r, &r.frames[at], sub, i)
		return
	}
	rd := tape.Reader{doc = r.sources[f.sc.source]}
	k, v: tape.Node_Index
	p: tape.Presence
	if f.it_open { k, v, p = tape.next_child(rd, &f.it, .Last) }
	if p != .Found {
		if f.it_open { tape.destroy_children(&f.it); f.it_open = false }
		finish_blocks(r, &f.n, &f.sh)
		r.d.nodes[f.i] = f.n
		resize(&r.path, f.path)
		pop(&r.frames)
		return
	}
	name, nok := doc_child_key_string(rd, f.it, k, r.scratch)
	if !nok { fail(r, {f.sc.source, f.at}, "schema", "out of memory"); return }
	if !is_keyword(name, f.sc.draft, f.sc.vocab) || (f.overridden && name != "$ref" && name != "$defs" && name != "definitions") { return }
	append(&r.path, tape.Name(name))
	if !keyword_open(r, f, name, v) {
		read_keyword(r, f.sc, f.i, f.at, &f.n, &f.sh, name, v)
		pop(&r.path)
	}
}

@(private)
keyword_open :: proc(r: ^Reader, f: ^Frame, name: string, v: tape.Node_Index) -> bool {
	sc := f.sc
	doc := r.sources[sc.source]
	clear(&f.subs)
	clear(&f.list)
	f.next = 0
	switch name {
	case "$defs", "definitions", "properties", "patternProperties", "dependentSchemas", "dependentRequired", "dependencies":
		if name != "$defs" && name != "definitions" { f.sh.is_object = true }
		if name == "dependentSchemas" || name == "dependentRequired" || name == "dependencies" { f.sh.object.dependencies = name == "dependencies" }
		for e in members_of(r, sc, v, name) { append(&f.subs, Sub{v = e.v, key = e.key, step = tape.Name(e.key), stepped = true}) }
	case "prefixItems", "items":
		f.sh.is_array = true
		if name == "prefixItems" || (doc.nodes[v].kind == .Array && sc.draft != .D2020_12) {
			f.sh.array.tuple = name == "items"
			subs_of_array(r, f, v, name)
		} else {
			append(&f.subs, Sub{v = v})
		}
	case "allOf", "anyOf", "oneOf":
		subs_of_array(r, f, v, name)
	case "additionalItems":
		if items, ok := doc_member(doc, f.at, "items"); ok && doc.nodes[items].kind == .Array {
			f.sh.is_array = true
			append(&f.subs, Sub{v = v, boolean = true})
		}
	case "contains":
		f.sh.is_array = true
		append(&f.subs, Sub{v = v})
	case "additionalProperties", "propertyNames":
		f.sh.is_object = true
		append(&f.subs, Sub{v = v, boolean = name == "additionalProperties"})
	case "if", "then", "else", "not", "unevaluatedItems", "unevaluatedProperties":
		append(&f.subs, Sub{v = v})
	case:
		return false
	}
	f.keyword = name
	return true
}

@(private)
array_children :: proc(r: ^Reader, doc: ^tape.Document, site: Site, name: string) -> ([]tape.Node_Index, bool) {
	rd := tape.Reader{doc = doc}
	it, p, err := tape.children(rd, site.at, r.scratch)
	if err != nil { fail(r, site, name, "out of memory"); return nil, false }
	defer tape.destroy_children(&it)
	out := make([dynamic]tape.Node_Index, r.scratch)
	if p == .Found {
		for {
			_, c, cp := tape.next_child(rd, &it)
			if cp != .Found { break }
			append(&out, c)
		}
	}
	return out[:], true
}

@(private)
subs_of_array :: proc(r: ^Reader, f: ^Frame, v: tape.Node_Index, name: string) {
	doc := r.sources[f.sc.source]
	if doc.nodes[v].kind != .Array || doc_length(r, doc, v) == 0 {
		fail(r, {f.sc.source, v}, name, "must be an array with a schema in it")
		return
	}
	if elems, ok := array_children(r, doc, {f.sc.source, v}, name); ok {
		for c, idx in elems { append(&f.subs, Sub{v = c, step = tape.Index(idx), stepped = true}) }
	}
}

@(private)
sub_before :: proc(r: ^Reader, f: ^Frame, sub: Sub) -> bool {
	switch f.keyword {
	case "patternProperties":
		if why := pattern_refusal(r, sub.key); why != "" {
			fail(r, {f.sc.source, sub.v}, f.keyword, strings.concatenate({"holds a name that is no regular expression: ", why}, r.scratch))
			return false
		}
	case "dependentSchemas", "dependentRequired", "dependencies":
		names := r.sources[f.sc.source].nodes[sub.v].kind == .Array
		if (names && f.keyword == "dependentSchemas") || (!names && f.keyword == "dependentRequired") {
			fail(r, {f.sc.source, sub.v}, f.keyword, "holds a value its keyword does not take")
			return false
		}
		if names {
			if required, ok := strings_of(r, f.sc, sub.v, f.keyword); ok {
				append(&f.sh.dependents, rules.Dependent{name = keep(r, sub.key), required = required})
			}
			return false
		}
	}
	return true
}

@(private)
sub_read :: proc(r: ^Reader, f: ^Frame, sub: Sub, i: rules.Node_Index) {
	switch f.keyword {
	case "$defs", "definitions": named(r, i, sub.key)
	case "properties":           append(&f.sh.members, rules.Member{name = keep(r, sub.key), node = i})
	case "patternProperties":    append(&f.sh.patterns, rules.Pattern{expression = keep(r, sub.key), node = i})
	case "dependentSchemas", "dependentRequired", "dependencies":
		append(&f.sh.dependents, rules.Dependent{name = keep(r, sub.key), node = i})
	case "prefixItems", "items", "allOf", "anyOf", "oneOf":
		if sub.stepped { append(&f.list, i) } else { f.sh.array.items = i }
	case "additionalItems":       f.sh.array.items = i
	case "contains":              f.sh.array.contains = i
	case "additionalProperties":  f.sh.object.additional = i
	case "propertyNames":         f.sh.object.keys = i
	case "if":                    f.n.cond.test = i
	case "then":                  f.n.cond.then = i
	case "else":                  f.n.cond.other = i
	case "not":                   f.n.not = i
	case "unevaluatedItems":      f.n.unevaluated_items = i
	case "unevaluatedProperties": f.n.unevaluated_properties = i
	}
}

@(private)
keyword_close :: proc(r: ^Reader, f: ^Frame) {
	switch f.keyword {
	case "prefixItems", "items": append(&f.sh.prefix, ..f.list[:])
	case "contains":             f.sh.array.evaluates_contains = f.sc.draft >= .D2020_12
	case "allOf":                f.n.all_of = own(r, f.list[:])
	case "anyOf":                f.n.any_of = own(r, f.list[:])
	case "oneOf":                f.n.one_of = own(r, f.list[:])
	}
}

@(private)
is_resource_root :: proc(r: ^Reader, sc: Scope, at: tape.Node_Index) -> bool {
	doc := r.sources[sc.source]
	for name in ([?]string{"$id", "id"}) {
		if v, has := doc_member(doc, at, name); has {
			if text, is_text := string_of(r, doc, v); is_text && text != "" && text[0] != '#' { return true }
		}
	}
	return at == sc.root
}

@(private)
register_resource :: proc(r: ^Reader, sc: Scope, key: string) {
	if prior, taken := r.resources[key]; taken && (prior.source != sc.source || prior.root != sc.root) {
		fail(r, {sc.source, sc.root}, "$id", "repeats the URI of another schema resource")
		return
	}
	r.resources[key] = sc
}

@(private)
read_id :: proc(r: ^Reader, sc: ^Scope, at: tape.Node_Index, i: rules.Node_Index) {
	doc := r.sources[sc.source]
	name := "id" if sc.draft == .D04 else "$id"
	v, ok := doc_member(doc, at, name)
	if !ok { return }
	text, is_text := string_of(r, doc, v)
	if !is_text { fail(r, {sc.source, v}, name, "must be a string"); return }
	if strings.index_byte(text, '#') >= 0 && sc.draft > .D07 { fail(r, {sc.source, v}, name, "must not have a fragment"); return }
	resource, _, fragment := strings.partition(uri_resolve(sc.base, text, r.scratch), "#")
	if fragment != "" && is_anchor(fragment) { register_anchor(r, sc^, {sc.source, at}, resource, fragment, name, false, i) }
	if text != "" && text[0] != '#' {
		sc.base, sc.root, sc.resource = resource, at, i
		if sc.source == 0 && len(r.path) > 0 && !through_ref(r.path[:]) { add_base(r, resource) }
	}
}

@(private)
add_base :: proc(r: ^Reader, uri: string) {
	steps := make([]tape.Step, len(r.path), r.d.allocator)
	for s, k in r.path {
		if nm, is_name := s.(tape.Name); is_name {
			steps[k] = tape.Name(keep(r, string(nm)))
		} else {
			steps[k] = s
		}
	}
	append(&r.d.bases, rules.Base{steps = steps, uri = keep(r, uri)})
}

@(private)
named :: proc(r: ^Reader, i: rules.Node_Index, name: string) {
	if i not_in r.d.names { r.d.names[i] = keep(r, name) }
}

@(private)
register_anchor :: proc(r: ^Reader, sc: Scope, site: Site, base, name, keyword: string, late: bool, i: rules.Node_Index) {
	key := strings.concatenate({base, "#", name}, r.scratch)
	if key in r.anchors { fail(r, site, keyword, "repeats an anchor of its resource"); return }
	r.anchors[key] = {site, late}
	named(r, i, name)
	if late { append(&r.d.anchors, rules.Anchor{name = keep(r, name), resource = sc.resource, node = i}) }
}

@(private = "file")
bool_of :: proc(r: ^Reader, kind: tape.Kind, site: Site, name: string) -> (bool, bool) {
	if kind != .True && kind != .False {
		fail(r, site, name, "must be a boolean")
		return false, false
	}
	return kind == .True, true
}

@(private)
read_keyword :: proc(r: ^Reader, sc: Scope, i: rules.Node_Index, at: tape.Node_Index, n: ^rules.Node, sh: ^Shape, name: string, v: tape.Node_Index) {
	doc := r.sources[sc.source]
	site := Site{sc.source, v}
	kind := doc.nodes[v].kind
	switch name {
	case "$schema", "$id", "id":
	case "$ref", "$dynamicRef":
		if text, ok := string_of(r, doc, v); ok {
			pend(r, i, site, name, uri_resolve(sc.base, text, r.scratch), name == "$dynamicRef")
		} else { fail(r, site, name, "must be a string") }
	case "$recursiveRef":
		if text, ok := string_of(r, doc, v); !ok || text != "#" {
			fail(r, site, name, "must be \"#\"")
		} else {
			anchor, has_a := doc_member(doc, sc.root, "$recursiveAnchor")
			recursive := has_a && doc.nodes[anchor].kind == .True
			pend(r, i, site, name, strings.concatenate({sc.base, "#", RECURSIVE if recursive else ""}, r.scratch), recursive)
		}
	case "$anchor", "$dynamicAnchor":
		if text, ok := string_of(r, doc, v); ok && is_anchor(text) {
			register_anchor(r, sc, {sc.source, at}, sc.base, text, name, name == "$dynamicAnchor", i)
		} else { fail(r, site, name, "must be a plain name") }
	case "$recursiveAnchor":
		if b, ok := bool_of(r, kind, site, name); ok && b && at == sc.root {
			register_anchor(r, sc, {sc.source, at}, sc.base, RECURSIVE, name, true, i)
		}
	case "$vocabulary":
		if kind != .Object { fail(r, site, name, "must be an object") }
	case "maxContains":   sh.array.max_contains, _ = count_of(r, doc, site, name)
	case "minContains":   sh.array.min_contains, _ = count_of(r, doc, site, name)
	case "maxLength":     n.rules.max_length, _ = count_of(r, doc, site, name)
	case "minLength":     n.rules.min_length, _ = count_of(r, doc, site, name)
	case "maxItems":      n.rules.max_items, _ = count_of(r, doc, site, name)
	case "minItems":      n.rules.min_items, _ = count_of(r, doc, site, name)
	case "maxProperties": n.rules.max_members, _ = count_of(r, doc, site, name)
	case "minProperties": n.rules.min_members, _ = count_of(r, doc, site, name)
	case "required":
		sh.is_object = true
		if names, ok := strings_of(r, sc, v, name); ok {
			append(&sh.required, ..names)
			delete(names, r.d.allocator)
		}
	case "type":
		n.kinds = types_of(r, doc, site)
		n.integer_spelled = sc.draft == .D04 && .Integer in n.kinds
	case "const":   n.const_of = rules.Value(rules.Node_Ref{doc, v})
	case "default": n.default_of = rules.Value(rules.Node_Ref{doc, v})
	case "examples": n.examples = values_of(r, doc, site, name)
	case "enum":
		if sc.draft == .D04 && kind == .Array {
			if doc_length(r, doc, v) == 0 { fail(r, site, name, "must hold at least one value in draft 4"); return }
			if uniq, uok := doc_array_unique(doc, v, r.scratch); !uok || !uniq { fail(r, site, name, "must not repeat a value in draft 4"); return }
		}
		n.enum_of, n.has_enum = values_of(r, doc, site, name), true
	case "multipleOf":
		if text, ok := number_of(r, doc, site, name); ok {
			if d := rules.decimal_of(text); d.head == "" || d.neg { fail(r, site, name, "must be above zero") }
			n.rules.multiple_of = text
		}
	case "maximum", "minimum":
		if text, ok := number_of(r, doc, site, name); ok {
			beside, has_b := doc_member(doc, at, "exclusiveMaximum" if name == "maximum" else "exclusiveMinimum")
			bound(&n.rules, name == "minimum", text, sc.draft == .D04 && has_b && doc.nodes[beside].kind == .True)
		}
	case "exclusiveMaximum", "exclusiveMinimum":
		if sc.draft == .D04 {
			_, _ = bool_of(r, kind, site, name)
		} else if text, ok := number_of(r, doc, site, name); ok {
			bound(&n.rules, name == "exclusiveMinimum", text, true)
		}
	case "uniqueItems": if b, ok := bool_of(r, kind, site, name); ok { n.rules.unique = b }
	case "readOnly":    if b, ok := bool_of(r, kind, site, name); ok { n.rules.read_only = b }
	case "writeOnly":   if b, ok := bool_of(r, kind, site, name); ok { n.rules.write_only = b }
	case "deprecated":  if b, ok := bool_of(r, kind, site, name); ok { n.deprecated = b }
	case "pattern":
		if text, ok := string_of(r, doc, v); !ok {
			fail(r, site, name, "must be a string")
		} else if why := pattern_refusal(r, text); why != "" {
			fail(r, site, name, strings.concatenate({"is no regular expression: ", why}, r.scratch))
		} else {
			n.rules.pattern = keep(r, text)
		}
	case "$comment", "title", "description", "contentEncoding", "contentMediaType":
		if text, ok := string_of(r, doc, v); ok {
			switch name {
			case "title":            n.title = keep(r, text)
			case "description":      n.description = keep(r, text)
			case "contentEncoding":  n.content_encoding = keep(r, text)
			case "contentMediaType": n.content_media_type = keep(r, text)
			}
		} else { fail(r, site, name, "must be a string") }
	case "xml":
		if kind == .Object {
			if node, has := doc_member(doc, v, "nodeType"); has {
				if text, tok := string_of(r, doc, node); tok {
					switch text {
					case "attribute": n.rules.markup = .Attribute
					case "element":   n.rules.markup = .Element
					case "text":      n.rules.markup = .Text
					}
				}
			}
		}
	case "format":
		if text, ok := string_of(r, doc, v); ok {
			format := rules.format_of(text)
			asserts := .Format_Assert in sc.vocab || r.res.format_assert
			if format == .None && .Format_Assert in sc.vocab && sc.draft >= .D2020_12 {
				fail(r, site, name, "is a format no check judges, which the format-assertion vocabulary refuses")
			}
			n.rules.format, n.rules.format_foreign = keep(r, text), FORMAT_DRAFTS[format] > sc.draft
			n.rules.assert_format = asserts && !n.rules.format_foreign
		} else { fail(r, site, name, "must be a string") }
	}
}

@(private)
finish_blocks :: proc(r: ^Reader, n: ^rules.Node, sh: ^Shape) {
	d := r.d
	if n.cond.test == nil { n.cond = {} }
	if sh.array.contains == nil { sh.array.min_contains, sh.array.max_contains = nil, nil }
	if sh.is_array {
		sh.array.prefix = own(r, sh.prefix[:])
		n.array = i32(len(d.arrays))
		append(&d.arrays, sh.array)
	}
	if len(sh.required) > 0 {
		names := member_names(sh.members[:], r.scratch)
		for req in sh.required {
			if k := first_named(&names, req); k >= 0 {
				for ; k >= 0; k = next_named(&names, k) { sh.members[k].required = true }
			} else {
				names.first[req] = len(sh.members)
				append(&names.next, -1)
				append(&sh.members, rules.Member{name = req, node = any_node(r), required = true, only_required = true})
			}
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

@(private)
any_node :: proc(r: ^Reader) -> rules.Node_Index {
	if r.anything == nil {
		r.anything = rules.Node_Index(len(r.d.nodes))
		append(&r.d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1})
	}
	return r.anything.?
}

@(private)
bound :: proc(rl: ^rules.Rules, lower: bool, text: string, strict: bool) {
	exclusive := strict
	have := &rl.minimum if lower else &rl.maximum
	flag := &rl.exclusive_minimum if lower else &rl.exclusive_maximum
	if have^ != "" {
		order := rules.decimal_compare(rules.decimal_of(text), rules.decimal_of(have^))
		if order == 0 {
			exclusive ||= flag^
		} else if (order > 0) != lower {
			return
		}
	}
	have^, flag^ = text, exclusive
}

@(private, rodata)
TYPE_KINDS := [?]struct { name: string, kinds: rules.Kinds } {
	{"null", {.Null}}, {"boolean", {.Bool}}, {"integer", {.Integer}}, {"number", {.Number}},
	{"string", {.String}}, {"array", {.Array}}, {"object", {.Object}},
}

@(private)
types_of :: proc(r: ^Reader, doc: ^tape.Document, site: Site) -> (kinds: rules.Kinds) {
	names: []tape.Node_Index
	single := [1]tape.Node_Index{site.at}
	#partial switch doc.nodes[site.at].kind {
	case .String: names = single[:]
	case .Array:
		ok: bool
		names, ok = array_children(r, doc, site, "type")
		if !ok { return }
	case:
		fail(r, site, "type", "must be a name or an array of names")
		return
	}
	if len(names) == 0 { fail(r, site, "type", "must name at least one type") }
	seen: bit_set[0 ..< len(TYPE_KINDS)]
	for c in names {
		text, is_text := string_of(r, doc, c)
		found := -1
		for t, k in TYPE_KINDS { if is_text && t.name == text { found = k } }
		if found < 0 {
			fail(r, site, "type", "holds a name that is no type")
		} else if found in seen {
			fail(r, site, "type", "repeats a type")
		} else {
			seen += {found}
			kinds += TYPE_KINDS[found].kinds
		}
	}
	return
}

@(private)
values_of :: proc(r: ^Reader, doc: ^tape.Document, site: Site, name: string) -> []rules.Value {
	if doc.nodes[site.at].kind != .Array { fail(r, site, name, "must be an array"); return nil }
	elems, ok := array_children(r, doc, site, name)
	if !ok { return nil }
	out := make([]rules.Value, len(elems), r.d.allocator)
	for c, i in elems { out[i] = rules.Node_Ref{doc, c} }
	return out
}

@(private)
number_of :: proc(r: ^Reader, doc: ^tape.Document, site: Site, name: string) -> (string, bool) {
	if doc.nodes[site.at].kind != .Number { fail(r, site, name, "must be a number"); return "", false }
	txt, ok := doc_node_number_text(doc, site.at, r.d.allocator)
	if !ok { fail(r, site, name, "must be a finite decimal number"); return "", false }
	append(&r.d.texts, txt)
	return txt, true
}

@(private)
count_of :: proc(r: ^Reader, doc: ^tape.Document, site: Site, name: string) -> (res: u64, ok: bool) {
	text := number_of(r, doc, site, name) or_return
	d := rules.decimal_of(text)
	if !rules.integral(d) || (d.neg && d.head != "") {
		fail(r, site, name, "must be a whole number, not below zero")
		return 0, false
	}
	if d.head == "" { return 0, true }
	sig_len := i128(len(d.head)) + i128(len(d.tail))
	zeros := d.point - sig_len
	if d.wide != "" || zeros > 20 || sig_len + zeros > 20 { return max(u64), true }
	full := strings.concatenate({d.head, d.tail, strings.repeat("0", int(zeros), r.scratch)}, r.scratch)
	count, parsed := strconv.parse_u64(full, 10)
	return count if parsed else max(u64), true
}

@(private)
string_of :: proc(r: ^Reader, doc: ^tape.Document, v: tape.Node_Index) -> (string, bool) {
	if int(v) >= len(doc.nodes) || (doc.nodes[v].kind != .String && doc.nodes[v].kind != .Plain) { return "", false }
	return doc_node_string(doc, v, r.scratch)
}

@(private)
keep :: proc(r: ^Reader, s: string) -> string {
	t := strings.clone(s, r.d.allocator)
	append(&r.d.texts, t)
	return t
}

@(private)
own :: proc(r: ^Reader, xs: []$T) -> []T {
	return slice.clone(xs, r.d.allocator) if len(xs) > 0 else nil
}

@(private)
strings_of :: proc(r: ^Reader, sc: Scope, v: tape.Node_Index, name: string) -> (res: []string, ok: bool) {
	doc := r.sources[sc.source]
	site := Site{sc.source, v}
	if doc.nodes[v].kind != .Array { fail(r, site, name, "must be an array of names"); return nil, false }
	if sc.draft == .D04 && doc_length(r, doc, v) == 0 { fail(r, site, name, "must name at least one property in draft 4"); return nil, false }
	if uniq, uok := doc_array_unique(doc, v, r.scratch); !uok || !uniq { fail(r, site, name, "must not name a property twice"); return nil, false }
	elems := array_children(r, doc, site, name) or_return
	out := make([dynamic]string, 0, len(elems), r.d.allocator)
	for c in elems {
		text, is_text := string_of(r, doc, c)
		if !is_text { fail(r, site, name, "must be an array of names"); delete(out); return nil, false }
		append(&out, keep(r, text))
	}
	return out[:], true
}

@(private)
Entry :: struct {
	key: string,
	v:   tape.Node_Index,
}

@(private)
members_of :: proc(r: ^Reader, sc: Scope, v: tape.Node_Index, name: string) -> []Entry {
	doc := r.sources[sc.source]
	if doc.nodes[v].kind != .Object { fail(r, {sc.source, v}, name, "must be an object"); return nil }
	entries := make([dynamic]Entry, r.scratch)
	rd := tape.Reader{doc = doc}
	it, p, err := tape.children(rd, v, r.scratch)
	if err != nil { fail(r, {sc.source, v}, name, "out of memory"); return nil }
	defer tape.destroy_children(&it)
	if p == .Found {
		for {
			k, value, cp := tape.next_child(rd, &it, .Last)
			if cp != .Found { break }
			key, kok := doc_child_key_string(rd, it, k, r.scratch)
			if !kok { fail(r, {sc.source, v}, name, "out of memory"); return nil }
			append(&entries, Entry{key, value})
		}
	}
	return entries[:]
}

@(private)
pattern_refusal :: proc(r: ^Reader, expression: string) -> string {
	err := regex.refusal(expression, .Ecma, {}, r.scratch, r.scratch)
	return err.message if err.kind != .None else ""
}

@(private)
fail :: proc(r: ^Reader, site: Site, keyword, why: string) {
	if r.err.kind != .None { return }
	at := r.sources[site.source].nodes[site.at].lo if (site.source >= 0 && site.source < len(r.sources) && int(site.at) < len(r.sources[site.source].nodes)) else u64(0)
	r.err = make_error(.Bad_Schema, keyword, why, at, r.path[:], r.err_alloc)
}
