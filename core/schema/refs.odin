package schema

import "core:os"
import "core:slice"
import "core:strings"
import core "../"
import "../rules"

// The meta-schemas of the drafts and the 2019-09 and 2020-12 vocabularies, which a reference reaches by their URIs. A
// draft's meta-schema names the draft.
@(private, rodata)
META := [?]struct {
	uri, text: string,
	draft:     Maybe(Draft),
} {
	{"https://json-schema.org/draft/2020-12/schema", #load("meta/draft2020-12/schema.json", string), .D2020_12},
	{"https://json-schema.org/draft/2020-12/meta/core", #load("meta/draft2020-12/meta/core.json", string), nil},
	{"https://json-schema.org/draft/2020-12/meta/applicator", #load("meta/draft2020-12/meta/applicator.json", string), nil},
	{"https://json-schema.org/draft/2020-12/meta/unevaluated", #load("meta/draft2020-12/meta/unevaluated.json", string), nil},
	{"https://json-schema.org/draft/2020-12/meta/validation", #load("meta/draft2020-12/meta/validation.json", string), nil},
	{"https://json-schema.org/draft/2020-12/meta/meta-data", #load("meta/draft2020-12/meta/meta-data.json", string), nil},
	{"https://json-schema.org/draft/2020-12/meta/format-annotation", #load("meta/draft2020-12/meta/format-annotation.json", string), nil},
	{"https://json-schema.org/draft/2020-12/meta/format-assertion", #load("meta/draft2020-12/meta/format-assertion.json", string), nil},
	{"https://json-schema.org/draft/2020-12/meta/content", #load("meta/draft2020-12/meta/content.json", string), nil},
	{"https://json-schema.org/draft/2019-09/schema", #load("meta/draft2019-09/schema.json", string), .D2019_09},
	{"https://json-schema.org/draft/2019-09/meta/core", #load("meta/draft2019-09/meta/core.json", string), nil},
	{"https://json-schema.org/draft/2019-09/meta/applicator", #load("meta/draft2019-09/meta/applicator.json", string), nil},
	{"https://json-schema.org/draft/2019-09/meta/validation", #load("meta/draft2019-09/meta/validation.json", string), nil},
	{"https://json-schema.org/draft/2019-09/meta/meta-data", #load("meta/draft2019-09/meta/meta-data.json", string), nil},
	{"https://json-schema.org/draft/2019-09/meta/format", #load("meta/draft2019-09/meta/format.json", string), nil},
	{"https://json-schema.org/draft/2019-09/meta/content", #load("meta/draft2019-09/meta/content.json", string), nil},
	{"http://json-schema.org/draft-07/schema", #load("meta/draft7/schema.json", string), .D07},
	{"http://json-schema.org/draft-06/schema", #load("meta/draft6/schema.json", string), .D06},
	{"http://json-schema.org/draft-04/schema", #load("meta/draft4/schema.json", string), .D04},
}

// The absolute directory references may read files from, without a closing slash. Symbolic links in it are resolved.
@(private)
root_path :: proc(res: ^Resolver) -> string {
	full, err := os.get_absolute_path(res.root, context.allocator)
	return strings.trim_right(full if err == nil else res.root, "/")
}

@(private)
pend :: proc(r: ^Reader, sc: Scope, node: rules.Node_Index, site: Site, keyword, uri: string, late: bool) {
	append(&r.pending, Pending{node, uri, site, keyword, slice.clone(r.path[:]), late})
}

// Resolves every reference the read met. Loading a file reads its resources, whose references join the list. A
// reference that leads back to its own node through references alone has no value to judge, so it is refused.
@(private)
resolve_all :: proc(r: ^Reader) {
	for k := 0; k < len(r.pending) && r.err == nil; k += 1 {
		p := r.pending[k]
		resize(&r.path, 0)
		append(&r.path, ..p.path)
		target, late, why := target_of(r, p)
		if why != "" {
			fail(r, p.site, p.keyword, why)
			return
		}
		if late {
			r.d.nodes[p.node].dynamic_ref = target
		} else {
			r.d.nodes[p.node].ref = target
		}
	}
	for p in r.pending {
		at := p.node
		for _ in 0 ..< len(r.d.nodes) {
			next, has := r.d.nodes[at].ref.?
			if !has {
				break
			}
			if next == p.node {
				resize(&r.path, 0)
				append(&r.path, ..p.path)
				fail(r, p.site, p.keyword, "leads back to itself through references alone")
				return
			}
			at = next
		}
	}
}

// The node a reference reaches: a resource, an anchor in it, or what a JSON Pointer fragment reaches from it. A
// reference to a dynamic anchor is dynamic, and so is a `$dynamicRef` only then.
@(private)
target_of :: proc(r: ^Reader, p: Pending) -> (node: rules.Node_Index, late: bool, why: string) {
	uri, _, raw := strings.partition(p.uri, "#")
	fragment, decoded := percent_decode(raw)
	if !decoded {
		return 0, false, "has a fragment with a broken escape"
	}
	sc, found := fetch(r, uri)
	if !found {
		return 0, false, r.res.root == "" ? "names a resource that is not in the schema" : "names a resource that is neither in the schema nor a file under the root"
	}
	switch {
	case fragment == "":
		return r.memo[{sc.source, sc.root}], false, ""
	case fragment[0] == '/':
		steps, err := core.parse_pointer(fragment)
		if err != nil {
			return 0, false, "has a fragment that is no JSON Pointer"
		}
		doc := r.sources[sc.source]
		at, sc, here := sc.root, sc, Position.Schema
		for step in steps.steps {
			if here == .Schema {
				sc = enter(r, sc, at)
			}
			ok := false
			#partial switch s in step {
			case core.Name:
				at, ok = core.member(doc, at, string(s))
			case core.Index_Or_Name:
				if core.kind(doc, at) == .Array {
					at, ok = core.child_at(doc, at, s.index)
				} else {
					at, ok = core.member(doc, at, s.name)
				}
			}
			if !ok {
				return 0, false, "points at nothing"
			}
			here = position_below(here, step, doc, at)
		}
		return read_schema(r, sc, at), false, ""
	}
	anchor, named := r.anchors[strings.concatenate({uri, "#", fragment})]
	if !named {
		return 0, false, "names an anchor its resource does not have"
	}
	return r.memo[anchor.site], anchor.late && p.late, ""
}

// What a place on a pointer's way is: a schema, an object or an array that holds schemas, or no schema at all, as `const`
// and an unknown keyword's value are.
@(private)
Position :: enum {
	None,
	Schema,
	Map,
	List,
}

// The position of `at`, the child of a place at `here` that `step` named.
@(private)
position_below :: proc(here: Position, step: core.Step, doc: ^core.Document, at: core.Node_Index) -> Position {
	switch here {
	case .Map, .List:
		return .Schema
	case .None:
		return .None
	case .Schema:
		name := ""
		#partial switch s in step {
		case core.Name:
			name = string(s)
		case core.Index_Or_Name:
			name = s.name
		}
		switch name {
		case "additionalProperties", "additionalItems", "contains", "not", "if", "then", "else", "propertyNames",
		     "unevaluatedItems", "unevaluatedProperties", "contentSchema":
			return .Schema
		case "items":
			return .List if core.kind(doc, at) == .Array else .Schema
		case "properties", "patternProperties", "$defs", "definitions", "dependentSchemas", "dependencies":
			return .Map
		case "allOf", "anyOf", "oneOf", "prefixItems":
			return .List
		}
	}
	return .None
}

// The scope inside the object at `at`, which a pointer passes on its way: the resource its `$id` starts, if it has one.
@(private)
enter :: proc(r: ^Reader, sc: Scope, at: core.Node_Index) -> Scope {
	doc := r.sources[sc.source]
	if at == sc.root {
		return sc
	}
	id, has := core.member(doc, at, "id" if sc.draft == .D04 else "$id")
	text, is_text := string_of(r, doc, id)
	if !has || !is_text || text == "" || text[0] == '#' {
		return sc
	}
	read_schema(r, sc, at)
	base, _, _ := strings.partition(uri_resolve(sc.base, text), "#")
	if inner, found := r.resources[base]; found && inner.source == sc.source && inner.root == at {
		return inner
	}
	return sc
}

// The resource `uri` names: one the read met, a vendored meta-schema, or a file under the resolver's root.
@(private)
fetch :: proc(r: ^Reader, uri: string) -> (sc: Scope, found: bool) {
	if sc, found = r.resources[uri]; found {
		return
	}
	source := load(r, uri) or_return
	read_root(r, source, core.ROOT, uri)
	sc, found = r.resources[uri]
	return
}

// The source `uri` names, loaded and not read: a vendored meta-schema or a file under the resolver's root.
@(private)
load :: proc(r: ^Reader, uri: string) -> (source: int, found: bool) {
	if source, found = r.loaded[uri]; found {
		return
	}
	text: string
	for m in META {
		if m.uri == uri {
			text = m.text
		}
	}
	if text == "" {
		u := uri_split(uri)
		if r.res.root == "" || u.scheme != "file" || u.authority != "" {
			return
		}
		// The real path decides: it has no dot segments and no link that leads out of the root.
		path, decoded := percent_decode(u.path)
		real, rerr := os.get_absolute_path(path, context.allocator)
		if !decoded || rerr != nil || !strings.has_prefix(real, strings.concatenate({root_path(r.res), "/"})) {
			return
		}
		bytes, err := os.read_entire_file_from_path(real, r.res.allocator)
		if err != nil {
			return
		}
		append(&r.res.texts, bytes)
		text = string(bytes)
	}
	doc := new(core.Document, r.res.allocator)
	built, err := core.build(transmute([]u8)text, r.res.as, .Last, r.res.allocator)
	if err != nil {
		free(doc, r.res.allocator)
		return
	}
	doc^ = built
	append(&r.res.documents, doc)
	append(&r.sources, doc)
	r.loaded[uri] = len(r.sources) - 1
	return len(r.sources) - 1, true
}

// The draft and vocabularies the meta-schema named by `uri` gives. A meta-schema that is not one of the drafts' is
// read for its `$schema`, which is its dialect, and its `$vocabulary`, the vocabularies it requires, and for nothing
// else: it does not become nodes.
@(private)
dialect :: proc(r: ^Reader, uri: string, depth := 0) -> (draft: Draft, vocab: Vocabs, why: string) {
	named, _, _ := strings.partition(uri, "#")
	for m in META {
		if d, is_draft := m.draft.?; is_draft && m.uri == named {
			return d, ALL_VOCABS, ""
		}
	}
	source, at, found := 0, core.ROOT, false
	if sc, embedded := r.resources[named]; embedded {
		source, at, found = sc.source, sc.root, true
	} else if depth <= 4 {
		source, found = load(r, named)
	}
	if !found {
		return {}, {}, "names a meta-schema that is neither a draft's nor a file under the root"
	}
	doc := r.sources[source]
	draft, vocab = r.res.draft.? or_else .D2020_12, ALL_VOCABS
	if parent, has := core.member(doc, at, "$schema"); has {
		text, _ := string_of(r, doc, parent)
		draft, vocab, why = dialect(r, uri_resolve(named, text), depth + 1)
	}
	if required, has := core.member(doc, at, "$vocabulary"); has && why == "" {
		vocab, why = vocabularies_of(r, doc, required)
	}
	return
}

// The vocabularies the `$vocabulary` object at `v` asks for. One it does not know and requires is a refusal.
@(private)
vocabularies_of :: proc(r: ^Reader, doc: ^core.Document, v: core.Node_Index) -> (vocab: Vocabs, why: string) {
	it := core.pairs(doc, v)
	for {
		k, value, more := core.pair_next(&it)
		if !more {
			return
		}
		uri, _ := core.text_clone(doc, k)
		if set, known := vocabulary_of(uri); known {
			vocab += set
		} else if core.kind(doc, value) == .True {
			return {}, "requires a vocabulary the reader does not know"
		}
	}
}

// `$vocabulary` outside a meta-schema's dialect only has to be well formed.
@(private)
read_vocabulary :: proc(r: ^Reader, sc: Scope, site: Site, name: string) {
	doc := r.sources[sc.source]
	if core.kind(doc, site.at) != .Object {
		fail(r, site, name, "must be an object")
	} else if _, why := vocabularies_of(r, doc, site.at); why != "" {
		fail(r, site, name, why)
	}
}
