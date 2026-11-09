package typed

import core ".."
import rules "../rules"

// Builds the plan that reads values of description `d` for format `as`, allocating with `allocator`. The plan stores
// nothing: its type is nil, and each record's kind reads what its node takes. A struct block is shared by the uses of
// one object block, a list block by those of one array block, a union block by those of one node. `d` must outlive the
// plan, whose names are its strings.
plan_of :: proc(d: ^rules.Description, as: core.As, opts := Plan_Options{}, allocator := context.allocator) -> (p: Plan, err: core.Error) {
	context.allocator = allocator
	b := plan_start(&p, as, opts)
	if d.root < 0 || int(d.root) >= len(d.nodes) {
		refuse_plan(&b, .Bad_Option)
	} else if root_block(&b) {
		fill_node(&b, d, 0, d.root, "")
	}
	return p, core.error_of(plan_finish(&b, 0))
}

// Fills record `at` for a use of node `at_node` named `name`, which reads the node's null when `null` is set and else
// leaves it to the `Maybe` record that holds it.
@(private)
fill_node :: proc(b: ^Builder, d: ^rules.Description, at: int, at_node: rules.Node_Index, name: string, null := true) {
	depth := enter(b, name)
	defer b.depth = depth
	n := d.nodes[at_node]
	f := Field{meta = u32(at)}
	m := Meta{name = name, block = -1, capture = -1}
	expect_name(b, &f, name)
	kinds := n.kinds + (rules.Kinds{.Integer} if .Number in n.kinds else {})
	leaf := kinds - {.Null}
	o := d.objects[n.object] if n.object >= 0 else rules.Object{additional = rules.NONE}
	switch {
	case len(n.any_of) > 0:
		f.kind = .Union
		m.block = node_union(b, d, at_node, &m)
	case kinds == {.Null, .Integer, .Number}:
		f.kind = .Number_Text
	case kinds == {.Null, .Bool, .Integer, .Number, .String}:
		f.kind = .Scalar
	case kinds == rules.EVERY_KIND:
		f.kind = .Any
	case null && .Null in kinds:
		f.kind = .Maybe
		node_list(b, d, {typeid_of(Maybe(rules.Node)), i32(at_node)}, at_node, &m, false)
	case leaf == {.Object} && n.object >= 0 && (len(o.members) > 0 || o.additional == rules.NONE):
		node_struct(b, d, {typeid_of(rules.Object), n.object}, o, &f, &m)
	case leaf == {.Object}:
		f.kind = .Map
		node_list(b, d, {typeid_of(rules.Object), n.object}, o.additional, &m)
	case leaf == {.Array}:
		f.kind = .Slice
		node_list(b, d, {typeid_of(rules.Array), n.array}, d.arrays[n.array].items if n.array >= 0 else rules.NONE, &m)
	case leaf == {.Bool}:
		f.kind = .Bool
	case leaf == {.Integer}:
		f.kind = .I64
	case leaf == {.Integer, .Number}:
		f.kind = .F64
	case leaf == {.String}:
		f.kind = .String
	case:
		refuse_plan(b, .Unsupported)
	}
	b.fields[at], b.meta[at] = f, m
}

@(private)
node_struct :: proc(b: ^Builder, d: ^rules.Description, key: Block_Key, o: rules.Object, f: ^Field, m: ^Meta) {
	if known_struct(b, key, f, m) {
		return
	}
	at := struct_block(b, key, f, m, o.members, false)
	if at < 0 {
		return
	}
	for x, i in o.members {
		fill_node(b, d, int(at) + i, x.node, x.name)
	}
}

// A list's, map's or `Maybe`'s block: its element's record, then a `Never` record.
@(private)
node_list :: proc(b: ^Builder, d: ^rules.Description, key: Block_Key, elem: rules.Node_Index, m: ^Meta, null := true) {
	m.list = true
	if at, ok := b.blocks[key]; ok {
		m.block = at
		return
	}
	m.block = reserve_block(b, 2, key)
	if m.block < 0 {
		return
	}
	never(b, int(m.block) + 1)
	if elem == rules.NONE {
		b.meta[m.block] = {block = -1, capture = -1}
		b.fields[m.block] = {kind = .Any, meta = u32(m.block)}
	} else {
		fill_node(b, d, int(m.block), elem, "", null)
	}
}

// A union's block holds one record per arm that takes more than null, then a `Never` record. An arm takes the classes
// of its node's kinds, and an arm of null alone makes the union take null.
@(private)
node_union :: proc(b: ^Builder, d: ^rules.Description, at_node: rules.Node_Index, m: ^Meta) -> i32 {
	all := d.nodes[at_node].any_of
	count := 0
	for arm in all {
		count += 0 if d.nodes[arm].kinds == {.Null} else 1
	}
	made, failed := make([]Arm, count)
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return -1
	}
	m.arms, m.no_nil = made, count == len(all)
	key := Block_Key{typeid_of(rules.Node), i32(at_node)}
	at, known := b.blocks[key]
	if !known {
		at = reserve_block(b, count + 1, key)
		if at < 0 {
			return -1
		}
		never(b, int(at) + count)
	}
	k := 0
	for arm in all {
		kinds := d.nodes[arm].kinds
		if kinds == {.Null} {
			continue
		}
		for c in Value_Class {
			if kinds & CLASS_KINDS[c] != {} {
				made[k].classes += {c}
			}
		}
		made[k].tag, made[k].fields = u32(k), at + i32(k)
		if !known {
			fill_node(b, d, int(at) + k, arm, "")
		}
		k += 1
	}
	refuse_overlap(b, m)
	return at
}

// The kinds of value each class holds.
@(private)
@(rodata)
CLASS_KINDS := [Value_Class]rules.Kinds {
	.Bool   = {.Bool},
	.Number = {.Integer, .Number},
	.String = {.String},
	.Object = {.Object},
	.Array  = {.Array},
}
