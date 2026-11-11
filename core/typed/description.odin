package typed

import "base:runtime"
import spell "../spell"
import core ".."
import rules "../rules"

// Builds the plan that reads values of description `d` for format `as`, allocating with `allocator`. The plan stores
// nothing: its type is nil, and each record's kind reads what its node takes. A struct block is shared by the uses of
// one object block, a list block by those of one array block, a union block by those of one node. `d` must outlive the
// plan, whose names are its strings. Under `opts.checking` each record is `Checked`, as a check reads it: a pattern that
// does not compile, and a `const` or `enum` operand that is a container, refuse the plan as `.Unsupported` with the
// keyword in `want.text`.
plan_of :: proc(d: ^rules.Description, as: core.As, reads: ^Format_Reads = nil, opts := Plan_Options{}, allocator := context.allocator) -> (p: Plan, err: core.Error) {
	context.allocator = allocator
	b: Builder
	trail: [TRAIL_MAX]string = ---
	plan_start(&b, &trail, &p, as, opts)
	plan_reads(&p, reads)
	arena, made := plan_arena(&p)
	if made {
		b.describing = new(Describe_State, arena)
	}
	if b.describing == nil {
		refuse_plan(&b, .No_Memory)
		return p, core.error_of(plan_finish(&b, 0))
	}
	if opts.checking {
		b.uses.allocator = arena
		b.programs = make(rules.Programs, arena)
	}
	if d.root < 0 || int(d.root) >= len(d.nodes) {
		refuse_plan(&b, .Bad_Option)
	} else if b.err.kind == .None && root_block(&b) {
		if opts.checking {
			x := conjoin_description(&b, d, arena)
			fill_checked(&b, &x, arena, 0, d.root, "", {}, {})
		} else {
			fill_node(&b, d, 0, d.root, "")
		}
	}
	if opts.checking {
		choose_arms(&b, arena)
		judging_ids(&b, arena)
		held_nesting(&b)
		shared_uses(&b)
		for u in b.uses {
			if len(u.applies) > 0 {
				if ext := plan_ext(&p); ext != nil {
					ext.fork = fork_record(&b)
				}
				break
			}
		}
		if resize(&b.uses, len(b.meta)) != nil {
			refuse_plan(&b, .No_Memory)
		}
	}
	if ext := plan_ext(&p); ext != nil {
		ext.leaves, ext.uses = b.leaves[:], b.uses[:]
	} else {
		refuse_plan(&b, .No_Memory)
	}
	return p, core.error_of(plan_finish(&b, description_stamp(d, as, opts)))
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
		node_list(b, d, block_key(typeid_of(Maybe(rules.Node)), i32(at_node), 0), at_node, &m, false)
	case leaf == {.Object} && n.object >= 0 && (len(o.members) > 0 || o.additional == rules.NONE):
		node_struct(b, d, block_key(typeid_of(rules.Object), n.object, 0), o, &f, &m)
	case leaf == {.Object}:
		f.kind = .Map
		node_list(b, d, block_key(typeid_of(rules.Object), n.object, 0), o.additional, &m)
	case leaf == {.Array}:
		f.kind = .Slice
		node_list(b, d, block_key(typeid_of(rules.Array), n.array, 0), d.arrays[n.array].items if n.array >= 0 else rules.NONE, &m)
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

// Fills record `at` as a check reads a use of node `use` named `name`, with `edge` the rules the use adds and `site` the
// keyword steps to it from the record that holds it, which `arena` holds with its leaf. A `$ref` that holds nothing
// else adds its step and reads the node it reaches. An object's members are a struct block that its uses share, and
// an array's prefix and items records a block its uses share.
@(private)
fill_checked :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, at: int, use: rules.Node_Index, name: string, edge: rules.Rules, site: []core.Step, bare := false) {
	if b.nest == MAX_FILL {
		refuse_plan(b, .Too_Deep)
		return
	}
	b.nest += 1
	depth, scope := enter(b, name), b.scope
	defer {
		b.nest -= 1
		b.depth, b.scope = depth, scope
	}
	node, refs := reached(d, use)
	for x, hop := use, 0; x != rules.NONE && hop <= refs; hop += 1 {
		enter_scope(b, d, arena, x)
		x = d.nodes[x].ref.? or_else node
	}
	f := Field{meta = u32(at)}
	m := Meta{name = name, block = -1, capture = -1}
	u: Use
	expect_name(b, &f, name)
	steps, failed := make([]core.Step, len(site) + refs, arena)
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	copy(steps, site)
	for &s in steps[len(site):] {
		s = core.Name("$ref")
	}
	u.site = steps
	u.node = markup_of(d, use, node, edge)
	if node != rules.NONE && !bare && holds(b, d, node, edge) {
		u.applies, u.verdict = checked_applies(b, d, arena, node, edge)
	} else if node != rules.NONE {
		n := &d.nodes[node]
		judged := n^
		if arm_operands(n) {
			judged.has_enum, judged.enum_of, judged.const_of = false, nil, nil
		}
		m.rule_set = checked_leaf(b, &judged, edge, arena)
		if m.rule_set > 0 {
			l := &b.leaves[m.rule_set - 1]
			m.counted = l.min_members > 0 || l.max_members < max(u64)
		}
		// An object or array the node's type refuses is read by its members' records too, so each failure is reported.
		if .Object in n.kinds || n.object >= 0 {
			o := d.objects[n.object] if n.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
			// The members a pattern matches are judged by the held record's arms, and so are the others with them.
			if len(o.patterns) > 0 && n.object not_in b.inline {
				o.additional = rules.NONE
			}
			o.members, u.requires = dependent_members(b, arena, o)
			if !known_struct(b, block_key(typeid_of(rules.Object), n.object, b.scope), &f, &m) && struct_block(b, block_key(typeid_of(rules.Object), n.object, b.scope), &f, &m, o.members, false) >= 0 {
				checked_members(b, d, arena, m.block, o, UNEVALUATED_PROPERTIES[:] if b.unevaluated[{0, n.object}] else ADDITIONAL[:])
			}
			if o.additional != rules.NONE {
				u.additional = checked_block(b, d, arena, block_key(typeid_of(Maybe(rules.Object)), n.object, b.scope), nil, o.additional, UNEVALUATED_PROPERTIES[:] if b.unevaluated[{0, n.object}] else ADDITIONAL[:])
			}
			if p, inline := b.inline[n.object]; inline {
				site := [2]core.Step{core.Name("patternProperties"), core.Name(p.expression)}
				u.pattern, u.regex = checked_block(b, d, arena, block_key(typeid_of(rules.Pattern), n.object, b.scope), nil, p.node, site[:]), p.regex
			}
			// A `propertyNames` with arms is the held record's `.Names` arm.
			if keys, _ := reached(d, o.keys); keys != rules.NONE && !holds(b, d, keys, {}) {
				u.keys = checked_leaf(b, &d.nodes[keys], {}, arena)
			}
		}
		if .Array in n.kinds || n.array >= 0 {
			a := d.arrays[n.array] if n.array >= 0 else rules.Array{items = rules.NONE}
			u.items = checked_block(b, d, arena, block_key(typeid_of(rules.Array), n.array, b.scope), a.prefix, a.items, UNEVALUATED_ITEMS[:] if b.unevaluated[{1, n.array}] else ITEMS[:])
			items, _ := reached(d, a.items)
			u.inside = len(a.prefix) > 0 || items != rules.NONE
		}
	}
	// A container of a kind the node reads no block for opens on the block that reads nothing, so its close judges it.
	if m.block < 0 || u.items == 0 {
		nothing := checked_block(b, d, arena, block_key(typeid_of(rules.Array), -1, 0), nil, rules.NONE, ITEMS[:])
		m.block = nothing if m.block < 0 else m.block
		u.items = nothing if u.items == 0 else u.items
	}
	f.kind = .Checked
	if !cover_uses(b) {
		refuse_plan(b, .No_Memory)
		return
	}
	b.fields[at], b.meta[at], b.uses[at] = f, m, u
}

// Grows `b.uses` to one `Use` per record, with room for the records to come, since an arena keeps the copy a resize leaves.
@(private)
cover_uses :: proc(b: ^Builder) -> bool {
	if cap(b.uses) < len(b.meta) && reserve(&b.uses, 2 * len(b.meta)) != nil {
		return false
	}
	return resize(&b.uses, len(b.meta)) == nil
}

// The markup node a member's record reads: what the used node, the node it reaches or the rules the use adds name
// (`xml.nodeType`), else any.
@(private = "file")
markup_of :: proc(d: ^rules.Description, use, reached: rules.Node_Index, edge: rules.Rules) -> Markup_Node {
	if use != rules.NONE && d.nodes[use].rules.markup != .Any {
		return d.nodes[use].rules.markup
	}
	if reached != rules.NONE && d.nodes[reached].rules.markup != .Any {
		return d.nodes[reached].rules.markup
	}
	return edge.markup
}

@(private)
@(rodata)
ADDITIONAL := [1]core.Step{core.Name("additionalProperties")}

@(private)
@(rodata)
ITEMS := [1]core.Step{core.Name("items")}

@(private)
@(rodata)
UNEVALUATED_PROPERTIES := [1]core.Step{core.Name("unevaluatedProperties")}

@(private)
@(rodata)
UNEVALUATED_ITEMS := [1]core.Step{core.Name("unevaluatedItems")}

// The members of `o` with each name its `dependentRequired` lists and no other member names, which read as the object's
// other members, and that keyword's members as places among them.
@(private)
dependent_members :: proc(b: ^Builder, arena: runtime.Allocator, o: rules.Object) -> ([]rules.Member, []Requires) {
	place :: proc(members: ^[dynamic]rules.Member, name: string) -> i32 {
		for x, i in members {
			if x.name == name {
				return i32(i)
			}
		}
		append(members, rules.Member{name = name, node = rules.NONE, only_required = true})
		return i32(len(members) - 1)
	}
	members := make([dynamic]rules.Member, arena)
	requires := make([dynamic]Requires, arena)
	for x in o.dependents {
		if len(x.required) == 0 {
			continue
		}
		if len(members) == 0 {
			append(&members, ..o.members)
		}
		r := Requires{trigger = place(&members, x.name), wants = make([]i32, len(x.required), arena)}
		for name, i in x.required {
			r.wants[i] = place(&members, name)
		}
		if _, failed := append(&requires, r); failed != nil {
			refuse_plan(b, .No_Memory)
		}
	}
	if len(requires) == 0 {
		return o.members, nil
	}
	return members[:], requires[:]
}

// Fills the members of struct block `at` of object `o`. A name only `required` lists reads as the object's other members,
// under the keyword steps `other`.
@(private)
checked_members :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, at: i32, o: rules.Object, other: []core.Step) {
	for x, i in o.members {
		if x.only_required {
			fill_checked(b, d, arena, int(at) + i, o.additional, x.name, {}, other)
			continue
		}
		site := [2]core.Step{core.Name("properties"), core.Name(x.name)}
		fill_checked(b, d, arena, int(at) + i, x.node, x.name, x.rules, site[:])
	}
}

// The node a use of `node` judges by, past each `$ref` that holds nothing else, and the `$ref`s it passed. `NONE` for
// one that never reaches a node that judges.
@(private)
reached :: proc(d: ^rules.Description, node: rules.Node_Index) -> (rules.Node_Index, int) {
	node := node
	hops := 0
	for ; node != rules.NONE && rules.ref_only(&d.nodes[node]); hops += 1 {
		if hops == len(d.nodes) {
			return rules.NONE, 0
		}
		node = d.nodes[node].ref.?
	}
	return node, hops
}

// A dynamic scope: the resource with dynamic anchors entered last, under the scope `outer`, 0 for the scope of none.
@(private)
Scope :: struct {
	outer:    i32,
	resource: rules.Node_Index,
}

// Enters the resource of `node` when it has a dynamic anchor of a name no resource of the scope has, the only entry
// that can change what a `$dynamicRef` reaches.
@(private)
enter_scope :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index) {
	if node == rules.NONE || len(d.anchors) == 0 {
		return
	}
	if len(b.scopes) == 0 {
		b.scopes.allocator = arena
		append(&b.scopes, Scope{resource = rules.NONE})
	}
	resource := d.nodes[node].resource
	fresh := false
	for x in d.anchors {
		if x.resource == resource && !bound(b, d, x.name) {
			fresh = true
		}
	}
	if !fresh {
		return
	}
	for x, i in b.scopes {
		if x == {b.scope, resource} {
			b.scope = i32(i)
			return
		}
	}
	append(&b.scopes, Scope{b.scope, resource})
	b.scope = i32(len(b.scopes) - 1)
}

// Whether a resource of the scope has a dynamic anchor named `name`.
@(private)
bound :: proc(b: ^Builder, d: ^rules.Description, name: string) -> bool {
	for at := b.scope; at != 0; at = b.scopes[at].outer {
		for x in d.anchors {
			if x.name == name && x.resource == b.scopes[at].resource {
				return true
			}
		}
	}
	return false
}

// The node a `$dynamicRef` that first reaches `node` judges by in the current scope: the dynamic anchor of the same name in
// the outermost resource that has one, else `node`.
@(private)
dynamic_target :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index) -> rules.Node_Index {
	name, named := "", false
	for x in d.anchors {
		if x.node == node {
			name, named = x.name, true
		}
	}
	target := node
	for at := b.scope; named && at != 0; at = b.scopes[at].outer {
		for x in d.anchors {
			if x.name == name && x.resource == b.scopes[at].resource {
				target = x.node
			}
		}
	}
	return target
}

// The `Meta.rule_set` of the leaf of `n` with `edge` added, 0 when it judges nothing.
@(private)
checked_leaf :: proc(b: ^Builder, n: ^rules.Node, edge: rules.Rules, arena: runtime.Allocator) -> i32 {
	l, refused := rules.leaf_of(n, edge, arena, &b.programs)
	if refused != "" {
		refuse_plan(b, .Unsupported, text = refused)
		return 0
	}
	if rules.trivial(&l) {
		return 0
	}
	if _, failed := append(&b.leaves, l); failed != nil {
		refuse_plan(b, .No_Memory)
		return 0
	}
	return i32(len(b.leaves))
}

// A block of a record per node of `prefix`, each moving the cursor on, then the record of `rest` under `site`, then a
// `Never` record. Returns 1 past its first record, where the cursor of its first value stands.
@(private)
checked_block :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, key: Block_Key, prefix: []rules.Node_Index, rest: rules.Node_Index, site: []core.Step) -> i32 {
	if at, ok := b.blocks[key]; ok {
		return at + 1
	}
	at := reserve_block(b, len(prefix) + 2, key)
	if at < 0 {
		return 0
	}
	never(b, int(at) + len(prefix) + 1)
	for x, i in prefix {
		steps := [2]core.Step{core.Name("prefixItems"), core.Index(i)}
		fill_checked(b, d, arena, int(at) + i, x, "", {}, steps[:])
		b.uses[int(at) + i].step = true
	}
	fill_checked(b, d, arena, int(at) + len(prefix), rest, "", {}, site)
	return at + 1
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
	key := block_key(typeid_of(rules.Node), i32(at_node), 0)
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

// A hash of the format and of everything `d` says, so plans of descriptions that say the same share a stamp.
@(private)
description_stamp :: proc(d: ^rules.Description, as: core.As, opts: Plan_Options) -> u64 {
	h := stamp_as(as, opts)
	limits :: proc(h: ^u64, r: rules.Rules) {
		for s in ([?]string{r.minimum, r.maximum, r.multiple_of, r.pattern, r.format}) {
			stamp_text(h, s)
		}
		stamp_mix(h, u64(r.unique) | u64(r.exclusive_minimum) << 1 | u64(r.exclusive_maximum) << 2 | u64(r.assert_format) << 3)
		for n in ([?]u64{r.min_length, r.min_items, r.min_members, r.max_length.? or_else max(u64), r.max_items.? or_else max(u64), r.max_members.? or_else max(u64)}) {
			stamp_mix(h, n)
		}
	}
	stamp_mix(&h, u64(d.root))
	for &n in d.nodes {
		stamp_mix(&h, u64(transmute(u8)n.kinds) | u64(n.integer_spelled) << 8)
		limits(&h, n.rules)
		stamp_mix(&h, u64(u32(n.array)) | u64(u32(n.object)) << 32)
		stamp_mix(&h, u64(i64(n.ref.? or_else rules.NONE)))
		stamp_mix(&h, u64(len(n.enum_of)) | u64(n.const_of != nil) << 32 | u64(n.has_enum) << 33)
		for v in n.enum_of {
			stamp_value(&h, v)
		}
		if v, has := n.const_of.?; has {
			stamp_value(&h, v)
		}
		for list in ([?][]rules.Node_Index{n.any_of, n.all_of, n.one_of}) {
			stamp_mix(&h, u64(len(list)))
			for x in list {
				stamp_mix(&h, u64(x))
			}
		}
		for x in ([?]Maybe(rules.Node_Index){n.not, n.cond.test, n.cond.then, n.cond.other, n.dynamic_ref, n.unevaluated_items, n.unevaluated_properties}) {
			stamp_mix(&h, u64(i64(x.? or_else rules.NONE)))
		}
	}
	for a in d.arrays {
		stamp_mix(&h, u64(i64(a.items)) | u64(len(a.prefix)) << 32)
		for x in a.prefix {
			stamp_mix(&h, u64(x))
		}
		stamp_mix(&h, u64(i64(a.contains.? or_else rules.NONE)))
		stamp_mix(&h, a.min_contains.? or_else max(u64))
		stamp_mix(&h, a.max_contains.? or_else max(u64))
	}
	for o in d.objects {
		stamp_mix(&h, u64(u32(o.additional)) | u64(u32(o.keys)) << 32)
		for x in o.members {
			stamp_text(&h, x.name)
			stamp_mix(&h, u64(x.node) | u64(x.required) << 32 | u64(x.only_required) << 33)
			limits(&h, x.rules)
		}
		for x in o.patterns {
			stamp_text(&h, x.expression)
			stamp_mix(&h, u64(x.node))
		}
		for x in o.dependents {
			stamp_text(&h, x.name)
			stamp_mix(&h, u64(i64(x.node.? or_else rules.NONE)) | u64(len(x.required)) << 32)
			for r in x.required {
				stamp_text(&h, r)
			}
		}
	}
	for x in d.anchors {
		stamp_text(&h, x.name)
		stamp_mix(&h, u64(x.resource) | u64(x.node) << 32)
	}
	return h
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
		x := spell.decimal_of(digits)
		stamp_mix(h, u64(x.neg) | u64(x.wide_neg) << 1)
		stamp_mix(h, u64(x.point))
		stamp_mix(h, u64(x.point >> 64))
		stamp_text(h, x.head)
		stamp_text(h, x.tail)
		stamp_text(h, x.wide)
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
