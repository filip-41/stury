// Vendored meta-schemas (`#load`), VFS `$ref`/`$dynamicRef`/`$recursiveRef` resolution, and in-place loop detection.
// Zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package schema

import "base:runtime"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

// Vendored meta-schemas for Draft 4, 6, 7, 2019-09, and 2020-12 plus stury's format-assertion dialect.
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

// Looks up an embedded vendored meta-schema JSON text by normalized URI.
meta_schema_text :: proc "contextless" (uri: string) -> (text: string, ok: bool) {
	for m in META {
		if m.uri == uri {
			return m.text, true
		}
	}
	return "", false
}

@(private)
pend :: proc(r: ^Reader, node: rules.Node_Index, site: Site, keyword, uri: string, late: bool) {
	append(&r.pending, Pending{node, uri, site, keyword, slice.clone(r.path[:], r.scratch), late})
}

// Resolves every reference met during reading, loading external resources via the VFS loader or vendored meta-schemas.
// Refuses reachable in-place reference cycles that would judge the same value without end.
@(private)
resolve_all :: proc(r: ^Reader) {
	for k := 0; k < len(r.pending) && r.err.kind == .None; k += 1 {
		p := r.pending[k]
		resize(&r.path, 0)
		append(&r.path, ..p.path)
		target, late, why := target_of(r, p)
		if why != "" {
			fail(r, p.site, p.keyword, why)
			return
		}
		if r.err.kind != .None {
			return
		}
		if !place_reference(&r.d.nodes[p.node], target, p.keyword, late) {
			fail(r, p.site, p.keyword, "is a second reference of its kind beside another")
			return
		}
	}
	if r.err.kind != .None {
		return
	}
	looping := loop_nodes(r.d, r.scratch)
	reached: []bool
	for p in r.pending {
		n := &r.d.nodes[p.node]
		if (n.ref == nil && n.dynamic_ref == nil) || !looping[p.node] {
			continue
		}
		if reached == nil {
			reached = reachable(r.d, r.scratch)
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

// Explicit-stack Tarjan SCC over in-place edges to detect circular references.
@(private)
loop_nodes :: proc(d: ^rules.Description, scratch: runtime.Allocator) -> []bool {
	count := len(d.nodes)
	starts := make([]int, count + 1, scratch)
	edges := make([dynamic]rules.Node_Index, scratch)
	for i in 0 ..< count {
		starts[i] = len(edges)
		subschemas(d, rules.Node_Index(i), &edges, true)
	}
	starts[count] = len(edges)
	looping := make([]bool, count, scratch)
	order := make([]int, count, scratch)
	low := make([]int, count, scratch)
	open := make([]bool, count, scratch)
	Visit :: struct {
		node, edge: int,
	}
	calls := make([dynamic]Visit, scratch)
	members := make([dynamic]int, scratch)
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

@(private)
reachable :: proc(d: ^rules.Description, scratch: runtime.Allocator) -> []bool {
	seen := make([]bool, len(d.nodes), scratch)
	todo := make([dynamic]rules.Node_Index, scratch)
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

@(private)
target_of :: proc(r: ^Reader, p: Pending) -> (node: rules.Node_Index, late: bool, why: string) {
	uri, _, raw := strings.partition(p.uri, "#")
	fragment, _, decoded := percent_decode(raw, r.scratch)
	if !decoded {
		return 0, false, "has a fragment with a broken escape"
	}
	sc, found := fetch(r, uri)
	if !found {
		return 0, false, strings.concatenate({"names ", uri, ", which is not in the schema or VFS loader"}, r.scratch)
	}
	switch {
	case fragment == "":
		return r.memo[{sc.source, sc.root}], false, ""
	case fragment[0] == '/':
		tokens, ptr_ok := parse_json_pointer(fragment, r.scratch)
		if !ptr_ok {
			return 0, false, "has a fragment that is no JSON Pointer"
		}
		doc := r.sources[sc.source]
		at, cur_sc, here := sc.root, sc, Position.Schema
		rd := tape.Reader{doc = doc}
		for tok in tokens {
			if here == .Schema {
				cur_sc = enter(r, cur_sc, at)
			}
			ok := false
			if doc.nodes[at].kind == .Array {
				if tok.has_index {
					el, ep := tape.element(rd, at, tok.index)
					if ep == .Found {
						at, ok = el, true
					}
				}
			} else if doc.nodes[at].kind == .Object {
				at, ok = member_named(r, cur_sc.source, doc, at, tok.name)
			}
			if !ok {
				return 0, false, "points at nothing"
			}
			here = position_below(here, tok.name, doc, at)
		}
		return read_schema(r, cur_sc, at), false, ""
	}
	anchor_key := strings.concatenate({uri, "#", fragment}, r.scratch)
	anchor, named := r.anchors[anchor_key]
	if !named {
		return 0, false, "names an anchor its resource does not have"
	}
	return r.memo[anchor.site], anchor.late && p.late, ""
}

@(private)
INDEX_FROM :: 32

@(private)
member_named :: proc(r: ^Reader, source: int, doc: ^tape.Document, at: tape.Node_Index, name: string) -> (tape.Node_Index, bool) {
	if doc.nodes[at].kind != .Object || doc_length(r, doc, at) < INDEX_FROM {
		return doc_member(doc, at, name)
	}
	index, built := r.indexes[{source, int(at)}]
	if !built {
		index = make(map[string]tape.Node_Index, 32, r.scratch)
		rd := tape.Reader{doc = doc}
		it, p, err := tape.children(rd, at, r.scratch)
		if err == nil && p == .Found {
			for {
				k, v, cp := tape.next_child(rd, &it, .Last)
				if cp != .Found {
					break
				}
				if key, kok := doc_child_key_string(rd, it, k, r.scratch); kok {
					index[key] = v
				}
			}
		}
		tape.destroy_children(&it)
		r.indexes[{source, int(at)}] = index
	}
	v, found := index[name]
	return v, found
}

@(private)
Position :: enum {
	None,
	Schema,
	Map,
	List,
}

@(private)
position_below :: proc(here: Position, name: string, doc: ^tape.Document, at: tape.Node_Index) -> Position {
	switch here {
	case .Map, .List:
		return .Schema
	case .None:
		return .None
	case .Schema:
		switch name {
		case "additionalProperties", "additionalItems", "contains", "not", "if", "then", "else", "propertyNames",
		     "unevaluatedItems", "unevaluatedProperties", "contentSchema":
			return .Schema
		case "items":
			return .List if doc.nodes[at].kind == .Array else .Schema
		case "properties", "patternProperties", "$defs", "definitions", "dependentSchemas", "dependencies":
			return .Map
		case "allOf", "anyOf", "oneOf", "prefixItems":
			return .List
		}
	}
	return .None
}

@(private)
enter :: proc(r: ^Reader, sc: Scope, at: tape.Node_Index) -> Scope {
	doc := r.sources[sc.source]
	if at == sc.root || doc.nodes[at].kind != .Object {
		return sc
	}
	inner_draft := sc.draft
	if sv, has_s := doc_member(doc, at, "$schema"); has_s {
		if s_uri, is_s := string_of(r, doc, sv); is_s {
			if d_found, _, why := dialect(r, uri_resolve(sc.base, s_uri, r.scratch)); why == "" {
				inner_draft = d_found
			}
		}
	}
	id, has := doc_member(doc, at, "id" if inner_draft == .D04 else "$id")
	if !has {
		return sc
	}
	text, is_text := string_of(r, doc, id)
	if !is_text || text == "" || text[0] == '#' {
		return sc
	}
	_ = read_schema(r, sc, at)
	base, _, _ := strings.partition(uri_resolve(sc.base, text, r.scratch), "#")
	if inner, found := r.resources[base]; found && inner.source == sc.source && inner.root == at {
		return inner
	}
	return sc
}

@(private)
fetch :: proc(r: ^Reader, uri: string) -> (sc: Scope, found: bool) {
	if sc, found = r.resources[uri]; found {
		return
	}
	source := load(r, uri) or_return
	read_root(r, source, tape.ROOT, uri)
	sc, found = r.resources[uri]
	return
}

// Loads an external resource by normalized URI from vendored `META` or the caller's VFS `Resolver.loader`.
// Zero OS calls!
@(private)
load :: proc(r: ^Reader, uri: string) -> (source: int, found: bool) {
	if source, found = r.loaded[uri]; found {
		return
	}
	// 1. Vendored meta-schemas (`#load`, always RFC 8259 JSON — never parsed via caller's `opts.parse`).
	if meta_text, is_meta := meta_schema_text(uri); is_meta {
		doc, derr := new(tape.Document, r.res.allocator)
		if derr != nil || doc == nil {
			if r.err.kind == .None {
				r.err = make_error(.No_Memory, "$ref", "out of memory", allocator = r.err_alloc)
			}
			return 0, false
		}
		built, ok := parse_json_owned(transmute([]u8)meta_text, r.res.allocator)
		if !ok {
			free(doc, r.res.allocator)
			return 0, false
		}
		doc^ = built
		if _, aerr := append(&r.res.documents, Owned_Doc{doc = doc, owned = true}); aerr != nil {
			tape.destroy_document(doc)
			free(doc, r.res.allocator)
			if r.err.kind == .None {
				r.err = make_error(.No_Memory, "$ref", "out of memory", allocator = r.err_alloc)
			}
			return 0, false
		}
		append(&r.sources, doc)
		r.loaded[uri] = len(r.sources) - 1
		return len(r.sources) - 1, true
	}

	// 2. VFS `load_doc` callback (returns a pre-parsed `tape.Document`).
	if r.res.loader.load_doc != nil {
		loaded_doc, owned, ok, lerr := r.res.loader.load_doc(r.res.loader.data, uri, r.res.allocator)
		if lerr.kind != .None {
			if owned {
				ld := loaded_doc
				tape.destroy_document(&ld)
			}
			if r.err.kind == .None {
				r.err = lerr
			} else {
				err_copy := lerr
				error_destroy(&err_copy)
			}
			return 0, false
		}
		if ok {
			doc, derr := new(tape.Document, r.res.allocator)
			if derr != nil || doc == nil {
				if owned {
					ld := loaded_doc
					tape.destroy_document(&ld)
				}
				if r.err.kind == .None {
					r.err = make_error(.No_Memory, "$ref", "out of memory", allocator = r.err_alloc)
				}
				return 0, false
			}
			doc^ = loaded_doc
			if _, aerr := append(&r.res.documents, Owned_Doc{doc = doc, owned = owned}); aerr != nil {
				if owned {
					tape.destroy_document(doc)
				}
				free(doc, r.res.allocator)
				if r.err.kind == .None {
					r.err = make_error(.No_Memory, "$ref", "out of memory", allocator = r.err_alloc)
				}
				return 0, false
			}
			append(&r.sources, doc)
			r.loaded[uri] = len(r.sources) - 1
			return len(r.sources) - 1, true
		}
	}

	// 3. VFS `load_bytes` callback (returns raw bytes parsed via `r.res.parse` or built-in JSON parser).
	if r.res.loader.load_bytes != nil {
		bytes, owned_bytes, ok := r.res.loader.load_bytes(r.res.loader.data, uri, r.res.allocator)
		if ok {
			if owned_bytes {
				if _, aerr := append(&r.res.texts, bytes); aerr != nil {
					delete(bytes, r.res.allocator)
					if r.err.kind == .None {
						r.err = make_error(.No_Memory, "$ref", "out of memory", allocator = r.err_alloc)
					}
					return 0, false
				}
			}
			doc, derr := new(tape.Document, r.res.allocator)
			if derr != nil || doc == nil {
				if r.err.kind == .None {
					r.err = make_error(.No_Memory, "$ref", "out of memory", allocator = r.err_alloc)
				}
				return 0, false
			}
			built, parsed := parse_schema_bytes(r.res, bytes, r.res.allocator)
			if !parsed {
				free(doc, r.res.allocator)
				return 0, false
			}
			doc^ = built
			if _, aerr := append(&r.res.documents, Owned_Doc{doc = doc, owned = true}); aerr != nil {
				tape.destroy_document(doc)
				free(doc, r.res.allocator)
				if r.err.kind == .None {
					r.err = make_error(.No_Memory, "$ref", "out of memory", allocator = r.err_alloc)
				}
				return 0, false
			}
			append(&r.sources, doc)
			r.loaded[uri] = len(r.sources) - 1
			return len(r.sources) - 1, true
		}
	}

	return 0, false
}

@(private)
parse_schema_bytes :: proc(res: ^Resolver, src: []u8, allocator: runtime.Allocator) -> (tape.Document, bool) {
	if res != nil && res.parse != nil {
		doc, err := res.parse(res.parse_data, src, allocator)
		return doc, err == nil
	}
	return parse_json_owned(src, allocator)
}

@(private)
dialect :: proc(r: ^Reader, uri: string, depth := 0) -> (draft: Draft, vocab: Vocabs, why: string) {
	named, _, _ := strings.partition(uri, "#")
	for m in META {
		if d, is_draft := m.draft.?; is_draft && m.uri == named {
			return d, ALL_VOCABS, ""
		}
	}
	source, at, found := 0, tape.ROOT, false
	if sc, embedded := r.resources[named]; embedded {
		source, at, found = sc.source, sc.root, true
	} else if depth <= 4 {
		source, found = load(r, named)
	}
	if !found {
		return {}, {}, "names a meta-schema that is neither a draft's nor provided by the VFS loader"
	}
	doc := r.sources[source]
	draft, vocab = r.res.draft.? or_else .D2020_12, ALL_VOCABS
	if parent, has := doc_member(doc, at, "$schema"); has {
		if text, tok := string_of(r, doc, parent); tok {
			draft, vocab, why = dialect(r, uri_resolve(named, text, r.scratch), depth + 1)
		}
	}
	if required, has := doc_member(doc, at, "$vocabulary"); has && why == "" {
		vocab, why = vocabularies_of(r, doc, required)
	}
	return
}

@(private)
vocabularies_of :: proc(r: ^Reader, doc: ^tape.Document, v: tape.Node_Index) -> (vocab: Vocabs, why: string) {
	rd := tape.Reader{doc = doc}
	it, p, err := tape.children(rd, v, r.scratch)
	if err != nil || p != .Found {
		return {}, ""
	}
	defer tape.destroy_children(&it)
	for {
		k, value, cp := tape.next_child(rd, &it, .Last)
		if cp != .Found {
			return
		}
		uri, uok := doc_node_string(doc, k, r.scratch)
		if !uok {
			continue
		}
		if set, known := vocabulary_of(uri); known {
			vocab += set
			if uri == VOCAB_URI_2019 + "format" && doc.nodes[value].kind == .True {
				vocab += {.Format_Assert}
			}
		} else if doc.nodes[value].kind == .True {
			return {}, "requires a vocabulary the reader does not know"
		}
	}
}
