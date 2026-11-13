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
	{DIALECT_URI, DIALECT, nil},
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

// The `file:` URI of the file `path`, made absolute against the working directory: `file:///dir/s.json`, and on Windows
// `file:///C:/dir/s.json`. A path that cannot be made absolute is taken as it is.
file_uri :: proc(path: string, allocator := context.allocator) -> string {
	full, err := os.get_absolute_path(path, context.temp_allocator)
	return strings.concatenate({"file://", uri_path(full if err == nil else path, context.temp_allocator)}, allocator)
}

// The path of the `file:` URI that names the absolute path `full`: on Windows its separators as `/` and a `/` before its
// drive.
@(private)
uri_path :: proc(full: string, allocator := context.allocator) -> string {
	when ODIN_OS == .Windows {
		slashed, _ := strings.replace_all(full, `\`, "/", allocator)
		return slashed if strings.has_prefix(slashed, "/") else strings.concatenate({"/", slashed}, allocator)
	} else {
		return full
	}
}

// The file the decoded path of a `file:` URI names: on Windows, the path without the `/` before its drive.
@(private)
file_path :: proc(path: string) -> string {
	when ODIN_OS == .Windows {
		if len(path) >= 3 && path[0] == '/' && path[2] == ':' {
			return path[1:]
		}
	}
	return path
}

// The absolute directory references may read files from, spelled as a `file:` URI's path and without a closing slash.
// Symbolic links in it are resolved.
@(private)
root_path :: proc(res: ^Resolver) -> string {
	full, err := os.get_absolute_path(res.root, context.allocator)
	return strings.trim_right(uri_path(full if err == nil else res.root), "/")
}

@(private)
pend :: proc(r: ^Reader, sc: Scope, node: rules.Node_Index, site: Site, keyword, uri: string, late: bool) {
	append(&r.pending, Pending{node, uri, site, keyword, slice.clone(r.path[:]), late})
}

// Resolves every reference the read met. Loading a file reads its resources, whose references join the list. A
// reference that leads back to its own node through references and in-place subschemas alone judges the same value
// without end, so it is refused.
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
		if !place_reference(&r.d.nodes[p.node], target, p.keyword, late) {
			fail(r, p.site, p.keyword, "is a second reference of its kind beside another")
			return
		}
	}
	looping := loop_nodes(r.d)
	reached: []bool
	for p in r.pending {
		n := &r.d.nodes[p.node]
		if n.ref == nil && n.dynamic_ref == nil || !looping[p.node] {
			continue
		}
		// A loop nothing reaches from the root is never judged.
		if reached == nil {
			reached = reachable(r.d)
		}
		if !reached[p.node] {
			continue
		}
		resize(&r.path, 0)
		append(&r.path, ..p.path)
		fail(r, p.site, p.keyword, "leads back to itself through references and in-place subschemas alone")
		return
	}
}

// Files the reference `keyword` of `n` that reaches `target`, dynamically under `late`. A `$ref` holds `ref`, a dynamic
// reference `dynamic_ref`, and a `$dynamicRef` or `$recursiveRef` that resolves statically holds `ref` unless a `$ref`
// beside it does. A node has at most one `$ref` and one other reference, so false, for a slot taken, means a reference
// would be lost.
@(private)
place_reference :: proc(n: ^rules.Node, target: rules.Node_Index, keyword: string, late: bool) -> bool {
	recursive := keyword == "$recursiveRef"
	switch {
	case late:
		if n.dynamic_ref != nil {
			return false
		}
		n.dynamic_ref = target
		n.spelled += {.Dynamic_Recursive} if recursive else {}
	case keyword == "$ref":
		if moved, has := n.ref.?; has {
			if n.spelled & {.Ref_Dynamic, .Ref_Recursive} == {} || n.dynamic_ref != nil {
				return false
			}
			n.dynamic_ref = moved
			n.spelled += {.Dynamic_Static, .Dynamic_Recursive} if .Ref_Recursive in n.spelled else {.Dynamic_Static}
			n.spelled -= {.Ref_Dynamic, .Ref_Recursive}
		}
		n.ref = target
	case n.ref == nil:
		n.ref = target
		n.spelled += {.Ref_Recursive} if recursive else {.Ref_Dynamic}
	case:
		if n.dynamic_ref != nil {
			return false
		}
		n.dynamic_ref = target
		n.spelled += {.Dynamic_Static, .Dynamic_Recursive} if recursive else {.Dynamic_Static}
	}
	return true
}

// Which nodes of `d` lie on a loop of in-place edges: those in a strongly connected set of two or more nodes, and those
// with an edge to themselves.
@(private)
loop_nodes :: proc(d: ^rules.Description) -> []bool {
	count := len(d.nodes)
	starts := make([]int, count + 1, context.temp_allocator)
	edges := make([dynamic]rules.Node_Index, context.temp_allocator)
	for i in 0 ..< count {
		starts[i] = len(edges)
		subschemas(d, rules.Node_Index(i), &edges, true)
	}
	starts[count] = len(edges)
	looping := make([]bool, count, context.temp_allocator)
	order := make([]int, count, context.temp_allocator) // visit order + 1, 0 before the visit
	low := make([]int, count, context.temp_allocator)
	open := make([]bool, count, context.temp_allocator)
	Visit :: struct {
		node, edge: int,
	}
	calls := make([dynamic]Visit, context.temp_allocator)
	members := make([dynamic]int, context.temp_allocator)
	visited := 0
	for root in 0 ..< count {
		if order[root] != 0 {
			continue
		}
		append(&calls, Visit{root, starts[root]})
		visited += 1
		order[root], low[root], open[root] = visited, visited, true
		append(&members, root)
		for len(calls) > 0 {
			top := &calls[len(calls) - 1]
			v := top.node
			if top.edge < starts[v + 1] {
				w := int(edges[top.edge])
				top.edge += 1
				switch {
				case w < 0:
				case w == v:
					looping[v] = true
				case order[w] == 0:
					visited += 1
					order[w], low[w], open[w] = visited, visited, true
					append(&members, w)
					append(&calls, Visit{w, starts[w]})
				case open[w]:
					low[v] = min(low[v], order[w])
				}
				continue
			}
			if low[v] == order[v] {
				// `v` is the first node of its set, which the stack holds from `v` on.
				size := 0
				for from := len(members) - 1; ; from -= 1 {
					size += 1
					if members[from] == v {
						break
					}
				}
				for len(members) > 0 {
					w := pop(&members)
					open[w] = false
					looping[w] ||= size > 1
					if w == v {
						break
					}
				}
			}
			pop(&calls)
			if len(calls) > 0 {
				parent := calls[len(calls) - 1].node
				low[parent] = min(low[parent], low[v])
			}
		}
	}
	return looping
}

// Which nodes the root of `d` reaches through any subschema or reference.
@(private)
reachable :: proc(d: ^rules.Description) -> []bool {
	seen := make([]bool, len(d.nodes), context.temp_allocator)
	todo := make([dynamic]rules.Node_Index, context.temp_allocator)
	append(&todo, d.root)
	for len(todo) > 0 {
		at := pop(&todo)
		if at == rules.NONE || seen[at] {
			continue
		}
		seen[at] = true
		subschemas(d, at, &todo, false)
	}
	return seen
}

// Adds to `out` the subschemas of `node` that `rules.node_children` gives under `in_place`. A `$dynamicRef` may reach
// any dynamic anchor of its target's name.
@(private)
subschemas :: proc(d: ^rules.Description, node: rules.Node_Index, out: ^[dynamic]rules.Node_Index, in_place: bool) {
	n := &d.nodes[node]
	if y, has := n.dynamic_ref.?; has && .Dynamic_Static not_in n.spelled {
		for a in d.anchors {
			if a.node == y {
				for b in d.anchors {
					if b.name == a.name {
						append(out, b.node)
					}
				}
			}
		}
	}
	rules.node_children(d, n, out, in_place)
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
		if r.res.root == "" {
			return 0, false, strings.concatenate({"names ", uri, ", which is not in the schema"}, context.temp_allocator)
		}
		return 0, false, strings.concatenate({"names ", uri, ", which is neither in the schema nor a readable file under the root ", r.res.root, ", and a file outside it is not read"}, context.temp_allocator)
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
				at, ok = member_named(r, sc.source, doc, at, string(s))
			case core.Index_Or_Name:
				if core.kind(doc, at) == .Array {
					at, ok = core.child_at(doc, at, s.index)
				} else {
					at, ok = member_named(r, sc.source, doc, at, s.name)
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

// The most members an object scans for a name before it is indexed.
@(private)
INDEX_FROM :: 32

// The member `name` of the object `at` of source `source`, as `core.member` finds it. A large object is indexed once, so
// that a schema of many references into one `$defs` reads in linear time.
@(private)
member_named :: proc(r: ^Reader, source: int, doc: ^core.Document, at: core.Node_Index, name: string) -> (core.Node_Index, bool) {
	if core.kind(doc, at) != .Object || core.length(doc, at) < INDEX_FROM {
		return core.member(doc, at, name)
	}
	index, built := r.indexes[{source, int(at)}]
	if !built {
		index = make(map[string]core.Node_Index)
		it := core.pairs(doc, at)
		for k, v in core.pair_next(&it) {
			key, _ := core.text_clone(doc, k)
			index[key] = v
		}
		r.indexes[{source, int(at)}] = index
	}
	v, found := index[name]
	return v, found
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
		u: rules.Uri = rules.uri_split(uri)
		if r.res.root == "" || !strings.equal_fold(u.scheme, "file") || u.authority != "" {
			return
		}
		// An escaped `/` is part of a file's name and not a separator, and no file name holds one.
		if strings.contains(u.path, "%2f") || strings.contains(u.path, "%2F") {
			return
		}
		// The real path decides: it has no dot segments and no link that leads out of the root.
		path, decoded := percent_decode(u.path)
		real, rerr := os.get_absolute_path(file_path(path), context.allocator)
		if !decoded || rerr != nil || !strings.has_prefix(uri_path(real), strings.concatenate({root_path(r.res), "/"})) {
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

// The vocabularies the `$vocabulary` object at `v` asks for. One it does not know and requires is a refusal. In 2019-09
// a dialect that requires the format vocabulary makes `format` assert, as its standard meta-schema lists it as optional.
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
			if uri == VOCAB_URI_2019 + "format" && core.kind(doc, value) == .True {
				vocab += {.Format_Assert}
			}
		} else if core.kind(doc, value) == .True {
			return {}, "requires a vocabulary the reader does not know"
		}
	}
}

// `$vocabulary` read as part of a schema has no meaning and only has to be well formed. A schema used as `$schema` has
// its vocabularies read by `dialect`, which requires the ones it knows.
@(private)
read_vocabulary :: proc(r: ^Reader, sc: Scope, site: Site, name: string) {
	if core.kind(r.sources[sc.source], site.at) != .Object {
		fail(r, site, name, "must be an object")
	}
}
