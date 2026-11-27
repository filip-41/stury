package rules

import "base:runtime"
import "core:slice"
import "stury:lib/core/tape"

Kind :: enum u8 { Null, Bool, Integer, Number, String, Array, Object }
Kinds :: bit_set[Kind; u8]
EVERY_KIND :: Kinds{.Null, .Bool, .Integer, .Number, .String, .Array, .Object}
Node_Index :: distinct i32
NONE :: Node_Index(-1)
Markup_Node :: enum u8 { Any, Attribute, Element, Text }

Rules :: struct {
	minimum, maximum:                     string,
	multiple_of, pattern, format:         string,
	unique:                               bool,
	assert_format, format_foreign:        bool,
	exclusive_minimum, exclusive_maximum: bool,
	read_only, write_only:                bool,
	min_length, min_items, min_members:   u64,
	max_length, max_items, max_members:   Maybe(u64),
	markup:                               Markup_Node,
}

Node :: struct {
	kinds:                  Kinds,
	integer_spelled:        bool,
	rules:                  Rules,
	array, object:          i32,
	any_of:                 []Node_Index,
	enum_of:                []Value,
	has_enum:               bool,
	const_of:               Maybe(Value),
	all_of, one_of:         []Node_Index,
	not:                    Maybe(Node_Index),
	cond:                   Conditional,
	ref, dynamic_ref:       Maybe(Node_Index),
	spelled:                Ref_Spellings,
	unevaluated_items:      Maybe(Node_Index),
	unevaluated_properties: Maybe(Node_Index),
	resource:               Node_Index,
	description, title:     string,
	content_encoding:       string,
	content_media_type:     string,
	deprecated:             bool,
	default_of:             Maybe(Value),
	examples:               []Value,
}

Ref_Spelling :: enum u8 { Ref_Dynamic, Ref_Recursive, Dynamic_Recursive, Dynamic_Static }
Ref_Spellings :: bit_set[Ref_Spelling; u8]

ref_keyword :: proc "contextless" (n: ^Node) -> string {
	if .Ref_Dynamic in n.spelled { return "$dynamicRef" }
	if .Ref_Recursive in n.spelled { return "$recursiveRef" }
	return "$ref"
}

dynamic_keyword :: proc "contextless" (n: ^Node) -> string {
	return "$recursiveRef" if .Dynamic_Recursive in n.spelled else "$dynamicRef"
}

Conditional :: struct { test, then, other: Maybe(Node_Index) }

Array :: struct {
	prefix:             []Node_Index,
	items:              Node_Index,
	tuple:              bool,
	contains:           Maybe(Node_Index),
	evaluates_contains: bool,
	min_contains:       Maybe(u64),
	max_contains:       Maybe(u64),
}

Object :: struct {
	members:      []Member,
	additional:   Node_Index,
	keys:         Node_Index,
	patterns:     []Pattern,
	dependents:   []Dependent,
	dependencies: bool,
}

Pattern :: struct { expression: string, node: Node_Index }
Dependent :: struct { name: string, required: []string, node: Maybe(Node_Index) }
Base :: struct { steps: []tape.Step, uri: string }
Anchor :: struct { name: string, resource, node: Node_Index }

Member :: struct {
	name:                    string,
	node:                    Node_Index,
	rules:                   Rules,
	required, only_required: bool,
}

Description :: struct {
	nodes:     [dynamic]Node,
	arrays:    [dynamic]Array,
	objects:   [dynamic]Object,
	texts:     [dynamic]string,
	anchors:   [dynamic]Anchor,
	names:     map[Node_Index]string,
	root:      Node_Index,
	uri:       string,
	bases:     [dynamic]Base,
	allocator: runtime.Allocator,
}

description_destroy :: proc(d: ^Description) {
	if d == nil { return }
	a := d.allocator
	for n in d.nodes { delete(n.any_of, a); delete(n.enum_of, a); delete(n.examples, a); delete(n.all_of, a); delete(n.one_of, a) }
	for arr in d.arrays { delete(arr.prefix, a) }
	for o in d.objects {
		delete(o.members, a); delete(o.patterns, a)
		for x in o.dependents { delete(x.required, a) }
		delete(o.dependents, a)
	}
	for t in d.texts { delete(t, a) }
	for x in d.bases { delete(x.steps, a) }
	delete(d.bases); delete(d.nodes); delete(d.arrays); delete(d.objects); delete(d.texts); delete(d.anchors); delete(d.names)
	d^ = {}
}

ref_only :: proc "contextless" (n: ^Node) -> bool {
	return n.ref != nil && n.kinds == EVERY_KIND && n.rules == {} && n.array < 0 && n.object < 0 && !n.has_enum && n.const_of == nil && len(n.any_of) == 0 && len(n.all_of) == 0 && len(n.one_of) == 0 && n.not == nil && n.cond == {} && n.dynamic_ref == nil && n.unevaluated_items == nil && n.unevaluated_properties == nil
}

ref_end :: proc "contextless" (d: ^Description, node: Node_Index) -> (Node_Index, int) {
	node := node
	hops := 0
	for ; node != NONE && ref_only(&d.nodes[node]); hops += 1 {
		if hops == len(d.nodes) { return NONE, 0 }
		node = d.nodes[node].ref.?
	}
	return node, hops
}

node_children :: proc(d: ^Description, n: ^Node, out: ^[dynamic]Node_Index, in_place: bool) {
	append(out, ..n.all_of); append(out, ..n.any_of); append(out, ..n.one_of)
	for x in ([?]Maybe(Node_Index){n.not, n.cond.test, n.cond.then, n.cond.other, n.ref, n.dynamic_ref}) {
		if r, has := x.?; has { append(out, r) }
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		for x in o.dependents { if r, has := x.node.?; has { append(out, r) } }
		if !in_place {
			for x in o.members { append(out, x.node) }
			for x in o.patterns { append(out, x.node) }
			append(out, o.additional, o.keys)
		}
	}
	if in_place { return }
	for x in ([?]Maybe(Node_Index){n.unevaluated_items, n.unevaluated_properties}) {
		if r, has := x.?; has { append(out, r) }
	}
	if n.array >= 0 {
		a := &d.arrays[n.array]
		append(out, ..a.prefix); append(out, a.items)
		if r, has := a.contains.?; has { append(out, r) }
	}
}

branches :: proc(d: ^Description, nodes: []Node_Index, choices: bool, limit: int, allocator := context.allocator, scratch := context.allocator) -> (out: [][dynamic]Node_Index, complete: bool) {
	Open :: struct { nodes: [dynamic]Node_Index, next: int }
	join :: proc(o: ^Open, ids: ..Node_Index) {
		for id in ids { if id != NONE && !slice.contains(o.nodes[:], id) { append(&o.nodes, id) } }
	}
	cleanup_done :: proc(done: ^[dynamic][dynamic]Node_Index) {
		for x in done { delete(x) }
		delete(done^)
	}
	work := make([dynamic]Open, scratch)
	defer { for w in work { delete(w.nodes) }; delete(work) }
	first := Open{nodes = make([dynamic]Node_Index, allocator)}
	join(&first, ..nodes)
	append(&work, first)
	done := make([dynamic][dynamic]Node_Index, allocator)
	ways := make([dynamic][2]Node_Index, scratch); defer delete(ways)
	forks := make([dynamic]Open, scratch); defer delete(forks)
	for len(work) > 0 {
		if len(work) + len(done) > limit { cleanup_done(&done); return nil, false }
		cur, forked := pop(&work), false
		for cur.next < len(cur.nodes) && !forked {
			n := &d.nodes[cur.nodes[cur.next]]
			cur.next += 1
			join(&cur, n.ref.? or_else NONE); join(&cur, ..n.all_of)
			clear(&forks); append(&forks, cur)
			for split in 0 ..< (4 if choices else 1) {
				clear(&ways)
				switch split {
				case 0: for arm in n.any_of { append(&ways, [2]Node_Index{arm, NONE}) }
				case 1: for arm in n.one_of { append(&ways, [2]Node_Index{arm, NONE}) }
				case 2:
					if test, has := n.cond.test.?; has && (n.cond.then != nil || n.cond.other != nil) {
						append(&ways, [2]Node_Index{test, n.cond.then.? or_else NONE}, [2]Node_Index{n.cond.other.? or_else NONE, NONE})
					}
				case 3:
					if target, has := n.dynamic_ref.?; has { dynamic_targets(d, target, &ways) }
				}
				if len(ways) == 0 { continue }
				if len(work) + len(done) + len(forks) * len(ways) > limit {
					for f in forks { delete(f.nodes) }
					cleanup_done(&done); return nil, false
				}
				open := len(forks)
				for _ in 0 ..< open {
					f := pop_front(&forks)
					for &w in ways {
						fork := Open{nodes = slice.clone_to_dynamic(f.nodes[:], allocator), next = f.next}
						join(&fork, ..w[:])
						append(&forks, fork)
					}
					delete(f.nodes)
				}
				forked = true
			}
			if forked { append(&work, ..forks[:]) } else { cur = forks[0] }
		}
		if !forked { append(&done, cur.nodes) }
	}
	return done[:], true
}

@(private = "file")
dynamic_targets :: proc(d: ^Description, target: Node_Index, ways: ^[dynamic][2]Node_Index) {
	for x in d.anchors {
		if x.node != target { continue }
		for y in d.anchors {
			if y.name == x.name && !slice.contains(ways[:], [2]Node_Index{y.node, NONE}) { append(ways, [2]Node_Index{y.node, NONE}) }
		}
	}
	if len(ways) == 0 { append(ways, [2]Node_Index{target, NONE}) }
}

kinds_of :: proc "contextless" (d: ^Description, ids: []Node_Index) -> Kinds {
	k := EVERY_KIND
	for id in ids {
		n := &d.nodes[id]
		k &= n.kinds + ({.Integer} if .Number in n.kinds else {})
	}
	return k
}
