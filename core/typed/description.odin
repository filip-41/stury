package typed

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import core ".."
import rules "../rules"

// Builds the plan that reads values of description `d` for format `as`, allocating with `allocator`. The plan stores
// nothing: its type is nil, and each record's kind reads what its node takes. A struct block is shared by the uses of
// one object block, a list block by those of one array block, a union block by those of one node. `d` must outlive the
// plan, whose names are its strings. `check_plan_of` builds the plan a check reads with.
plan_of :: proc(d: ^rules.Description, as: core.As, reads: ^Format_Reads = nil, opts := Plan_Options{}, allocator := context.allocator) -> (p: Plan, err: core.Error) {
	context.allocator = allocator
	b := plan_start(&p, as, opts)
	plan_reads(&p, reads)
	if d.root < 0 || int(d.root) >= len(d.nodes) {
		refuse_plan(&b, .Bad_Option)
	} else if root_block(&b) {
		fill_node(&b, d, 0, d.root, "")
	}
	return p, core.error_of(plan_finish(&b, description_stamp(d, as)))
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

// Builds the plan a check of description `d` reads a text of format `as` with, allocating with `allocator`. A record is
// one use of a node, and its `Use` says what the check judges there. An object block's members are a struct block that
// its uses share, and an array block's prefix and items records a block its uses share. A `$ref` alone is the node it
// reaches. `d` must outlive the plan. A pattern that does not compile, and a `const` or `enum` operand that is a
// container, refuse the plan as `.Unsupported` with the keyword in `want.text`.
check_plan_of :: proc(d: ^rules.Description, as: core.As, allocator := context.allocator) -> (p: Plan, err: core.Error) {
	context.allocator = allocator
	b := plan_start(&p, as, {})
	c := Check_Build{b = &b, d = d}
	p.arena = new(virtual.Arena)
	if p.arena == nil || virtual.arena_init_growing(p.arena) != nil {
		free(p.arena)
		p.arena = nil
		refuse_plan(&b, .No_Memory)
	} else {
		c.arena = virtual.arena_allocator(p.arena)
	}
	if d.root < 0 || int(d.root) >= len(d.nodes) {
		refuse_plan(&b, .Bad_Option)
	} else if b.err.kind == .None && root_block(&b) {
		check_fill(&c, 0, d.root, "", {}, false)
	}
	if resize(&c.uses, len(b.fields)) != nil {
		refuse_plan(&b, .No_Memory)
	}
	p.uses, p.leaves = c.uses[:], c.leaves[:]
	return p, core.error_of(plan_finish(&b, description_stamp(d, as)))
}

@(private)
Check_Build :: struct {
	b:      ^Builder,
	d:      ^rules.Description,
	uses:   [dynamic]Use,
	leaves: [dynamic]rules.Leaf,
	arena:  runtime.Allocator,
}

// Fills record `at` for a use of node `node` named `name`, with `edge` the rules the use adds. `step` marks an array's
// prefix record.
@(private)
check_fill :: proc(c: ^Check_Build, at: int, use: rules.Node_Index, name: string, edge: rules.Rules, step: bool) {
	depth := enter(c.b, name)
	defer c.b.depth = depth
	node := reached(c.d, use)
	f := Field{meta = u32(at), kind = .Struct}
	m := Meta{name = name, block = -1, capture = -1}
	expect_name(c.b, &f, name)
	u := Use{step = step}
	if node != rules.NONE {
		n := &c.d.nodes[node]
		u.leaf = check_leaf(c, n, edge)
		if .Object in n.kinds && n.object >= 0 {
			o := c.d.objects[n.object]
			m.block, m.members = check_members(c, n.object), i32(len(o.members))
			for x in o.members {
				f.kind = .Required if x.required else f.kind
			}
			if o.additional != rules.NONE {
				u.additional = check_block(c, {typeid_of(Maybe(rules.Object)), n.object}, nil, o.additional)
			}
			if keys := reached(c.d, o.keys); keys != rules.NONE {
				u.keys = check_leaf(c, &c.d.nodes[keys], {})
			}
		}
		if .Array in n.kinds && n.array >= 0 {
			a := c.d.arrays[n.array]
			u.array = check_block(c, {typeid_of(rules.Array), n.array}, a.prefix, a.items)
		}
	}
	c.b.fields[at], c.b.meta[at] = f, m
	if len(c.uses) <= at && resize(&c.uses, at + 1) != nil {
		refuse_plan(c.b, .No_Memory)
		return
	}
	c.uses[at] = u
}

// The node a use of `node` judges by: past each `$ref` that holds nothing else, `NONE` for one that never reaches a node
// that judges.
@(private)
reached :: proc(d: ^rules.Description, node: rules.Node_Index) -> rules.Node_Index {
	node := node
	for hops := 0; node != rules.NONE && rules.ref_only(&d.nodes[node]); hops += 1 {
		if hops == len(d.nodes) {
			return rules.NONE
		}
		node = d.nodes[node].ref.?
	}
	return node
}

// The 1-based index of the leaf of `n` with `edge` added, 0 when it judges nothing.
@(private)
check_leaf :: proc(c: ^Check_Build, n: ^rules.Node, edge: rules.Rules) -> i32 {
	l, refused := rules.leaf_of(n, edge, c.arena)
	if refused != "" {
		refuse_plan(c.b, .Unsupported, text = refused)
		return 0
	}
	if rules.trivial(&l) {
		return 0
	}
	if _, failed := append(&c.leaves, l); failed != nil {
		refuse_plan(c.b, .No_Memory)
		return 0
	}
	return i32(len(c.leaves))
}

// The struct block of object block `object`: a record per member, then a `Never` record naming the required ones.
@(private)
check_members :: proc(c: ^Check_Build, object: i32) -> i32 {
	key := Block_Key{typeid_of(rules.Object), object}
	if at, ok := c.b.blocks[key]; ok {
		return at
	}
	members := c.d.objects[object].members
	at := reserve_block(c.b, len(members) + 1, key)
	if at < 0 {
		return -1
	}
	never(c.b, int(at) + len(members))
	required := make([dynamic]i32)
	for x, i in members {
		if x.required {
			append(&required, i32(i))
		}
		check_fill(c, int(at) + i, x.node, x.name, x.rules, false)
		if int(at) + i < len(c.uses) {
			c.uses[int(at) + i].only_required = x.only_required
		}
	}
	c.b.meta[int(at) + len(members)].required = required[:]
	return at
}

// A block of a record per node of `prefix`, each moving the cursor on, then the record of `rest`, then a `Never`
// record. Returns 1 past its first record, where the cursor of its first value stands.
@(private)
check_block :: proc(c: ^Check_Build, key: Block_Key, prefix: []rules.Node_Index, rest: rules.Node_Index) -> i32 {
	if at, ok := c.b.blocks[key]; ok {
		return at + 1
	}
	at := reserve_block(c.b, len(prefix) + 2, key)
	if at < 0 {
		return 0
	}
	never(c.b, int(at) + len(prefix) + 1)
	for x, i in prefix {
		check_fill(c, int(at) + i, x, "", {}, true)
	}
	check_fill(c, int(at) + len(prefix), rest, "", {}, false)
	return at + 1
}

// A hash of the format and of everything `d` says, so plans of descriptions that say the same share a stamp.
@(private)
description_stamp :: proc(d: ^rules.Description, as: core.As) -> u64 {
	h := u64(0xcbf29ce484222325)
	limits :: proc(h: ^u64, r: rules.Rules) {
		for s in ([?]string{r.minimum, r.maximum, r.multiple_of, r.pattern, r.format}) {
			stamp_text(h, s)
		}
		stamp_mix(h, u64(r.unique) | u64(r.exclusive_minimum) << 1 | u64(r.exclusive_maximum) << 2)
		for n in ([?]u64{r.min_length, r.min_items, r.min_members, r.max_length.? or_else max(u64), r.max_items.? or_else max(u64), r.max_members.? or_else max(u64)}) {
			stamp_mix(h, n)
		}
	}
	stamp_mix(&h, u64(uintptr(rawptr(as.readers.format))))
	stamp_mix(&h, u64(as.max_depth) | u64(as.spec) << 32 | u64(transmute(u8)as.tolerate) << 40)
	stamp_mix(&h, u64(d.root))
	for &n in d.nodes {
		stamp_mix(&h, u64(transmute(u8)n.kinds) | u64(n.integer_spelled) << 8)
		limits(&h, n.rules)
		stamp_mix(&h, u64(u32(n.array)) | u64(u32(n.object)) << 32)
		stamp_mix(&h, u64(i64(n.ref.? or_else rules.NONE)))
		stamp_mix(&h, u64(len(n.enum_of)) | u64(n.const_of != nil) << 32 | u64(raw_data(n.enum_of) != nil) << 33)
		for v in n.enum_of {
			stamp_value(&h, v)
		}
		if v, has := n.const_of.?; has {
			stamp_value(&h, v)
		}
		for x in n.any_of {
			stamp_mix(&h, u64(x))
		}
	}
	for a in d.arrays {
		stamp_mix(&h, u64(i64(a.items)) | u64(len(a.prefix)) << 32)
		for x in a.prefix {
			stamp_mix(&h, u64(x))
		}
	}
	for o in d.objects {
		stamp_mix(&h, u64(u32(o.additional)) | u64(u32(o.keys)) << 32)
		for x in o.members {
			stamp_text(&h, x.name)
			stamp_mix(&h, u64(x.node) | u64(x.required) << 32 | u64(x.only_required) << 33)
			limits(&h, x.rules)
		}
	}
	return h
}

@(private)
stamp_mix :: proc(h: ^u64, x: u64) {
	h^ = (h^ ~ x) * 0x100000001b3
}

@(private)
stamp_text :: proc(h: ^u64, s: string) {
	stamp_mix(h, u64(len(s)))
	for c in transmute([]u8)s {
		stamp_mix(h, u64(c))
	}
}

// Mixes the operand `v` into `h` with a number's literal by its exact decimal, so two literals of one double differ.
@(private)
stamp_value :: proc(h: ^u64, v: core.Value) {
	k := core.value_kind(v)
	stamp_mix(h, u64(k))
	#partial switch k {
	case .Number:
		f, digits, _ := core.double_of(v)
		if digits == "" {
			stamp_mix(h, transmute(u64)(f + 0))
			return
		}
		b := strings.builder_make(context.temp_allocator)
		rules.enum_key(&b, .Number, digits)
		stamp_text(h, strings.to_string(b))
	case .Array:
		it := core.value_children(v)
		for x in core.value_child_next(&it) {
			stamp_value(h, x)
		}
	case .Object:
		members := core.sorted_members(v)
		defer delete(members)
		for m in members {
			stamp_text(h, m.key)
			stamp_value(h, m.val)
		}
	case:
		stamp_mix(h, core.hash(v))
	}
}
