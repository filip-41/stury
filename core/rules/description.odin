// A description says which values are allowed: per node, the kinds it takes, the rules on each kind, and the arms. An
// Odin type, a JSON Schema and inference give one, and the plan builder, the schema writer, sample and compare read it.
package rules

import "base:runtime"

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

// Limits on a value, each read only for its kind: a number's bounds as exact decimal text, empty where there is none,
// a string's length in code points, an array's elements and an object's members.
Rules :: struct {
	minimum, maximum:                     string,
	exclusive_minimum, exclusive_maximum: bool,
	min_length, min_items, min_members:   u64,
	max_length, max_items, max_members:   Maybe(u64),
}

// A node takes a value of one of `kinds` that passes the node's rules and, when there are arms, one of `any_of`.
// `array` and `object` index the kind's block in the description, -1 for an array or object of any shape, so nodes
// that differ only in kinds or rules share one.
Node :: struct {
	kinds:  Kinds,
	rules:  Rules,
	array:  i32,
	object: i32,
	any_of: []Node_Index,
}

// An array's elements: the first take the nodes of `prefix` in order, and the rest `items`.
Array :: struct {
	prefix: []Node_Index,
	items:  Node_Index,
}

// An object's named members, the node every other member's value passes, and the node each member's name passes, read
// as an integer where that node takes integers. `NONE` for any value or name.
Object :: struct {
	members:    []Member,
	additional: Node_Index,
	keys:       Node_Index,
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
	root:      Node_Index,
	allocator: runtime.Allocator,
}

// Frees what `d` owns and sets it to the zero value.
description_destroy :: proc(d: ^Description) {
	context.allocator = d.allocator
	for n in d.nodes {
		delete(n.any_of)
	}
	for a in d.arrays {
		delete(a.prefix)
	}
	for o in d.objects {
		delete(o.members)
	}
	for t in d.texts {
		delete(t)
	}
	delete(d.nodes)
	delete(d.arrays)
	delete(d.objects)
	delete(d.texts)
	d^ = {}
}
