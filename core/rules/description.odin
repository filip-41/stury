// A description says which values are allowed: per node, the kinds it takes, the rules on each kind, and the arms. An
// Odin type, a JSON Schema and inference give one, and the plan builder, the schema writer, sample and compare read it.
package rules

import "base:runtime"
import core "../"

// The kinds of value a node takes. `Integer` lies inside `Number`: a node of kind `Number` takes `1`.
Kind :: enum u8 {
	Null,
	Bool,
	Integer,
	Number,
	String,
	Array,
	Object,
}

Kinds :: bit_set[Kind; u8]

EVERY_KIND :: Kinds{.Null, .Bool, .Integer, .Number, .String, .Array, .Object}

// A node's place in `Description.nodes`.
Node_Index :: distinct i32

// No node: an array's items or an object's other members that take any value.
NONE :: Node_Index(-1)

// The node of a markup element a value is read from, which `xml.nodeType` names: `.Any` an attribute or a child element
// of the member's name.
Markup_Node :: enum u8 {
	Any,
	Attribute,
	Element,
	Text,
}

// Limits on a value, each read only for its kind: a number's bounds and divisor as exact decimal text, empty where there
// is none, a string's length in code points, its pattern and format, an array's elements and an object's members.
Rules :: struct {
	minimum, maximum:                     string,
	multiple_of, pattern, format:         string,
	unique:                               bool,
	// Whether `format` asserts and does not only annotate.
	assert_format:                        bool,
	exclusive_minimum, exclusive_maximum: bool,
	// The `readOnly` and `writeOnly` annotations, which no check reads.
	read_only, write_only:                bool,
	min_length, min_items, min_members:   u64,
	max_length, max_items, max_members:   Maybe(u64),
	markup:                               Markup_Node,
}

// A node takes a value of one of `kinds` that passes the node's rules and, when there are arms, one of `any_of`.
// `array` and `object` index the kind's block in the description, -1 for an array or object of any shape, so nodes
// that differ only in kinds or rules share one. The fields below `any_of` are what a JSON Schema says beyond that,
// each empty or nil for none, and `enum_of` read only under `has_enum`: the value must be one of `enum_of` and the one of `const_of`, pass every node of `all_of`
// and exactly one of `one_of`, fail `not`, pass `then` when it passes the `if` of `cond` and `other` when it does not,
// and pass `ref` and `dynamic_ref`, which the schema read resolves to nodes. `dynamic_ref` names the node the
// reference reaches first, and `anchors` the nodes that may replace it. `unevaluated_items` and
// `unevaluated_properties` judge what no applicator reached. `resource` is the root node of the schema resource that
// holds the node, the unit a dynamic reference's scope is made of.
Node :: struct {
	kinds:                  Kinds,
	// Draft 4's integer: a number spelled with a fraction or an exponent is not one, `1.0` included.
	integer_spelled:        bool,
	rules:                  Rules,
	array:                  i32,
	object:                 i32,
	any_of:                 []Node_Index,
	enum_of:                []core.Value,
	has_enum:               bool, // an `enum` is set, which may hold no value
	const_of:               Maybe(core.Value),
	all_of, one_of:         []Node_Index,
	not:                    Maybe(Node_Index),
	cond:                   Conditional,
	ref, dynamic_ref:       Maybe(Node_Index),
	unevaluated_items:      Maybe(Node_Index),
	unevaluated_properties: Maybe(Node_Index),
	resource:               Node_Index,
	// The node's `description`, which a sample writes as a comment.
	description:            string,
}

// An `if` with its `then` and `else`.
Conditional :: struct {
	test, then, other: Maybe(Node_Index),
}

// An array's elements: the first take the nodes of `prefix` in order, and the rest `items`. `contains` takes between
// `min_contains` (1 when nil) and `max_contains` of the elements.
Array :: struct {
	prefix:       []Node_Index,
	items:        Node_Index,
	contains:     Maybe(Node_Index),
	min_contains: Maybe(u64),
	max_contains: Maybe(u64),
}

// An object's named members, the node every other member's value passes, and the node each member's name passes as a
// string. `NONE` for any value or name. A member whose name matches a pattern of
// `patterns` also passes that pattern's node, and is not "other". A member named in `dependents` needs the names of
// its `required` and passes its `node`.
Object :: struct {
	members:    []Member,
	additional: Node_Index,
	keys:       Node_Index,
	patterns:   []Pattern,
	dependents: []Dependent,
}

Pattern :: struct {
	expression: string,
	node:       Node_Index,
}

Dependent :: struct {
	name:     string,
	required: []string,
	node:     Maybe(Node_Index),
}

// A dynamic anchor: the node of schema resource `resource` that `$dynamicAnchor: name` marks.
Anchor :: struct {
	name:     string,
	resource: Node_Index,
	node:     Node_Index,
}

// A member as one use of a node: its name, whether it must be present, and the rules this use adds to the node's.
// `only_required` marks a name that only `required` lists, which leaves the member to the object's other members.
Member :: struct {
	name:          string,
	node:          Node_Index,
	rules:         Rules,
	required:      bool,
	only_required: bool,
}

// A description owns its nodes, blocks and slices, allocated with `allocator`, and the strings in `texts`. It borrows
// its other strings from where it was made: a plan, a schema's document.
Description :: struct {
	nodes:     [dynamic]Node,
	arrays:    [dynamic]Array,
	objects:   [dynamic]Object,
	texts:     [dynamic]string,
	anchors:   [dynamic]Anchor,
	// The name a node goes by: a schema's `$defs` key or `$anchor`, a type's name. The writer names a definition by it.
	names:     map[Node_Index]string,
	root:      Node_Index,
	// The URI of the schema's root resource, "" for none: the base of its keyword locations.
	uri:       string,
	allocator: runtime.Allocator,
}

// Frees what `d` owns and sets it to the zero value.
description_destroy :: proc(d: ^Description) {
	context.allocator = d.allocator
	for n in d.nodes {
		delete(n.any_of)
		delete(n.enum_of)
		delete(n.all_of)
		delete(n.one_of)
	}
	for a in d.arrays {
		delete(a.prefix)
	}
	for o in d.objects {
		delete(o.members)
		delete(o.patterns)
		for x in o.dependents {
			delete(x.required)
		}
		delete(o.dependents)
	}
	for t in d.texts {
		delete(t)
	}
	delete(d.nodes)
	delete(d.arrays)
	delete(d.objects)
	delete(d.texts)
	delete(d.anchors)
	delete(d.names)
	d^ = {}
}

// Whether `n` is a `$ref` and nothing else, which judges a value as the node it reaches does.
ref_only :: proc(n: ^Node) -> bool {
	return n.ref != nil && n.kinds == EVERY_KIND && n.rules == {} && n.array < 0 && n.object < 0 && !n.has_enum && n.const_of == nil && len(n.any_of) == 0 && len(n.all_of) == 0 && len(n.one_of) == 0 && n.not == nil && n.cond == {} && n.dynamic_ref == nil && n.unevaluated_items == nil && n.unevaluated_properties == nil
}
