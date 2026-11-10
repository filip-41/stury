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

// Limits on a value, each read only for its kind: a number's bounds and divisor as exact decimal text, empty where there
// is none, a string's length in code points, its pattern and format, an array's elements and an object's members.
Rules :: struct {
	minimum, maximum:                     string,
	multiple_of, pattern, format:         string,
	unique:                               bool,
	exclusive_minimum, exclusive_maximum: bool,
	min_length, min_items, min_members:   u64,
	max_length, max_items, max_members:   Maybe(u64),
}

// A node takes a value of one of `kinds` that passes the node's rules and, when there are arms, one of `any_of`.
// `array` and `object` index the kind's block in the description, -1 for an array or object of any shape, so nodes
// that differ only in kinds or rules share one. The fields below `any_of` are what a JSON Schema says beyond that,
// each empty or nil for none: the value must be one of `enum_of` and the one of `const_of`, pass every node of `all_of`
// and exactly one of `one_of`, fail `not`, pass `then` when it passes the `if` of `cond` and `other` when it does not,
// and pass `ref` and `dynamic_ref`, which the schema read resolves to nodes. `dynamic_ref` names the node the
// reference reaches first, and `anchors` the nodes that may replace it. `unevaluated_items` and
// `unevaluated_properties` judge what no applicator reached. `resource` is the root node of the schema resource that
// holds the node, the unit a dynamic reference's scope is made of.
Node :: struct {
	kinds:                  Kinds,
	rules:                  Rules,
	array:                  i32,
	object:                 i32,
	any_of:                 []Node_Index,
	enum_of:                []core.Value,
	const_of:               Maybe(core.Value),
	all_of, one_of:         []Node_Index,
	not:                    Maybe(Node_Index),
	cond:                   Conditional,
	ref, dynamic_ref:       Maybe(Node_Index),
	unevaluated_items:      Maybe(Node_Index),
	unevaluated_properties: Maybe(Node_Index),
	resource:               Node_Index,
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

// An object's named members, the node every other member's value passes, and the node each member's name passes, read
// as an integer where that node takes integers. `NONE` for any value or name. A member whose name matches a pattern of
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
Member :: struct {
	name:     string,
	node:     Node_Index,
	rules:    Rules,
	required: bool,
}

// A description owns its nodes, blocks and slices, allocated with `allocator`, and the strings in `texts`. It borrows
// its other strings from where it was made: a plan, a schema's document.
Description :: struct {
	nodes:     [dynamic]Node,
	arrays:    [dynamic]Array,
	objects:   [dynamic]Object,
	texts:     [dynamic]string,
	anchors:   [dynamic]Anchor,
	root:      Node_Index,
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
	d^ = {}
}

// The first keyword node `n` holds that a plan of `d` does not judge yet, "" for none. `format_assert` says `format` is
// asserted and not an annotation.
unjudged :: proc(d: ^Description, format_assert: bool) -> string {
	for n in d.nodes {
		switch {
		case len(n.enum_of) > 0:
			return "enum"
		case n.const_of != nil:
			return "const"
		case len(n.all_of) > 0:
			return "allOf"
		case len(n.one_of) > 0:
			return "oneOf"
		case n.not != nil:
			return "not"
		case n.cond.test != nil || n.cond.then != nil || n.cond.other != nil:
			return "if"
		case n.ref != nil:
			return "$ref"
		case n.dynamic_ref != nil:
			return "$dynamicRef"
		case n.unevaluated_items != nil:
			return "unevaluatedItems"
		case n.unevaluated_properties != nil:
			return "unevaluatedProperties"
		case n.rules.multiple_of != "":
			return "multipleOf"
		case n.rules.pattern != "":
			return "pattern"
		case n.rules.format != "" && format_assert:
			return "format"
		case n.rules.unique:
			return "uniqueItems"
		}
	}
	for a in d.arrays {
		if a.contains != nil {
			return "contains"
		}
	}
	for o in d.objects {
		switch {
		case len(o.patterns) > 0:
			return "patternProperties"
		case len(o.dependents) > 0:
			return "dependencies"
		}
	}
	return ""
}
