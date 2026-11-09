// Models: an Odin type with rules, read, checked and written by its plan.
package model

import "base:runtime"
import "core:strconv"
import "core:strings"
import core ".."
import rules "../rules"
import typed "../typed"

// Reads the description of the values `plan`, a type's plan, reads, allocating with `allocator`. A record's type gives
// one node, which every use of the type shares, and a `Maybe` or pointer a copy that also takes null and shares the
// node's blocks. A number's range is its node's `minimum` and `maximum`, a fixed array's length its item counts, a map's
// integer or enum keys its object's `keys`, and a member's `model:` rules sit on its edge. The description borrows the
// plan's names, so the plan must outlive it.
describe :: proc(plan: ^typed.Plan, allocator := context.allocator) -> (d: rules.Description, err: core.Error) {
	context.allocator = allocator
	d.allocator = allocator
	if plan.type == nil {
		return d, core.error_of(core.Typed_Error{kind = .Bad_Option})
	}
	r := Reading{plan = plan, d = &d}
	defer delete(r.nodes)
	defer delete(r.shapes)
	d.root = node_of(&r, 0)
	if r.failed {
		rules.description_destroy(&d)
		return d, runtime.Allocator_Error.Out_Of_Memory
	}
	return d, nil
}

@(private)
Reading :: struct {
	plan:   ^typed.Plan,
	d:      ^rules.Description,
	nodes:  map[Use]rules.Node_Index,
	shapes: map[i32]i32, // a list or struct block's array or object block in the description
	failed: bool,
}

@(private)
Use :: struct {
	type:     typeid,
	nullable: bool,
}

// What each integer kind holds, `I8` first.
@(private)
@(rodata)
LIMITS := [8][2]string {
	{"-128", "127"},
	{"-32768", "32767"},
	{"-2147483648", "2147483647"},
	{"-9223372036854775808", "9223372036854775807"},
	{"0", "255"},
	{"0", "65535"},
	{"0", "4294967295"},
	{"0", "18446744073709551615"},
}

// The least decimal that rounds to an f32 infinity, `2^128 - 2^103`.
@(private)
F32_PAST :: "340282356779733661637539395458142568448"

// The record a value at record `at` is read by once its `Maybe`s and pointers are passed, and whether one was.
@(private)
target :: proc(plan: ^typed.Plan, at: i32) -> (i32, bool) {
	at, nullable := at, false
	for plan.fields[at].kind == .Maybe || plan.fields[at].kind == .Ptr {
		at, nullable = plan.meta[at].block, true
	}
	return at, nullable
}

@(private)
node_of :: proc(r: ^Reading, record: i32) -> rules.Node_Index {
	at, nullable := target(r.plan, record)
	f, m := r.plan.fields[at], r.plan.meta[at]
	use := Use{m.type, nullable}
	if found, ok := r.nodes[use]; ok {
		return found
	}
	index := add(r, &r.d.nodes, rules.Node{array = -1, object = -1})
	if _, failed := map_insert(&r.nodes, use, index); failed != nil || r.failed {
		r.failed = true
		return 0
	}
	n := rules.Node{array = -1, object = -1}
	#partial switch f.kind {
	case .Slice, .Dynamic, .Array, .Fixed_List, .Bit_Set:
		n.kinds = {.Array}
		n.array = array_of(r, f.kind, m)
		if f.kind == .Array {
			n.rules.min_items, n.rules.max_items = u64(m.count), u64(m.count)
		} else if f.kind == .Fixed_List {
			n.rules.max_items = u64(m.count)
		}
	case .Map, .Struct, .Required:
		n.kinds = {.Object}
		n.object = object_of(r, m, f.kind == .Map)
	case .Union:
		n.kinds = rules.EVERY_KIND
		n.any_of = arms_of(r, m, nullable || !m.no_nil)
	case:
		n = leaf(r, f.kind, m)
	}
	if nullable {
		n.kinds += {.Null}
	}
	r.d.nodes[index] = n
	return index
}

// The node of a value `kind` reads, with the range of an integer, an f32, an enum read as integers and a bit_set's
// element. `m` is the record's, or a map's for its key.
@(private)
leaf :: proc(r: ^Reading, kind: typed.Read_Kind, m: typed.Meta) -> (n: rules.Node) {
	n.array, n.object = -1, -1
	#partial switch kind {
	case .String, .Cstring:
		n.kinds = {.String}
	case .Bool, .Bool_Wide:
		n.kinds = {.Bool}
	case .I8 ..= .U64:
		n.kinds = {.Integer}
		limits := LIMITS[u8(kind) - u8(typed.Read_Kind.I8)]
		n.rules.minimum, n.rules.maximum = limits[0], limits[1]
	case .F32:
		n.kinds = {.Number}
		n.rules = {minimum = "-" + F32_PAST, maximum = F32_PAST, exclusive_minimum = true, exclusive_maximum = true}
	case .F64, .Number:
		n.kinds = {.Number}
	case .Number_Text:
		n.kinds = {.Number, .Null}
	case .Scalar:
		n.kinds = {.Null, .Bool, .Number, .String}
	case .Enum, .Bit_Elem:
		if m.enum_info != nil && r.plan.enums == .Name {
			n.kinds = {.String}
			break
		}
		n.kinds = {.Integer}
		low, high := m.lower, m.lower + i64(m.count) - 1
		if kind == .Enum {
			low, high = max(i64), min(i64)
			for v in m.enum_info.values {
				low, high = min(low, i64(v)), max(high, i64(v))
			}
		}
		n.rules.minimum, n.rules.maximum = decimal(r, low), decimal(r, high)
	case:
		n.kinds = rules.EVERY_KIND
	}
	return
}

@(private)
array_of :: proc(r: ^Reading, kind: typed.Read_Kind, m: typed.Meta) -> i32 {
	at, fresh := shape(r, m.block, &r.d.arrays, rules.Array{})
	if !fresh {
		return at
	}
	items: rules.Node_Index
	if r.plan.fields[m.block].kind == .Bit_Elem {
		items = add(r, &r.d.nodes, leaf(r, .Bit_Elem, r.plan.meta[m.block]))
	} else {
		items = node_of(r, m.block)
	}
	if r.failed {
		return at
	}
	a := &r.d.arrays[at]
	a.items = items
	if kind == .Array {
		prefix, failed := make([]rules.Node_Index, m.count)
		a.prefix = prefix
		r.failed ||= failed != nil
		for &x in prefix {
			x = items
		}
	}
	return at
}

@(private)
object_of :: proc(r: ^Reading, m: typed.Meta, is_map: bool) -> i32 {
	at, fresh := shape(r, m.block, &r.d.objects, rules.Object{additional = rules.NONE, keys = rules.NONE})
	if !fresh {
		return at
	}
	if is_map {
		additional := node_of(r, m.block)
		keys := rules.NONE
		if m.key_kind != .String && m.key_kind != .Cstring {
			keys = add(r, &r.d.nodes, leaf(r, m.key_kind, m))
		}
		if !r.failed {
			r.d.objects[at].additional, r.d.objects[at].keys = additional, keys
		}
		return at
	}
	members, failed := make([]rules.Member, m.members)
	r.d.objects[at].members = members
	r.failed ||= failed != nil
	required := r.plan.meta[m.block + m.members].required
	for &x, j in members {
		record := m.block + i32(j)
		x.name = r.plan.meta[record].name
		x.node = node_of(r, record)
		folded, _ := target(r.plan, record)
		if set := r.plan.meta[folded].rule_set; set > 0 {
			x.rules = r.plan.rule_sets[set - 1]
		}
		for k in required {
			x.required ||= k == i32(j)
		}
	}
	return at
}

@(private)
arms_of :: proc(r: ^Reading, m: typed.Meta, null: bool) -> []rules.Node_Index {
	arms, failed := make([]rules.Node_Index, len(m.arms) + (1 if null else 0))
	r.failed ||= failed != nil
	for arm, k in m.arms {
		arms[k] = node_of(r, arm.fields)
	}
	if null && !r.failed {
		arms[len(m.arms)] = add(r, &r.d.nodes, rules.Node{kinds = {.Null}, array = -1, object = -1})
	}
	return arms
}

// The description's block for the plan's block `block`, added to `list` as `empty` when it is new, and whether it was.
@(private)
shape :: proc(r: ^Reading, block: i32, list: ^[dynamic]$T, empty: T) -> (at: i32, fresh: bool) {
	if found, ok := r.shapes[block]; ok {
		return found, false
	}
	at = i32(add(r, list, empty))
	if _, failed := map_insert(&r.shapes, block, at); failed != nil {
		r.failed = true
	}
	return at, !r.failed
}

// The decimal text of `n`, which the description owns.
@(private)
decimal :: proc(r: ^Reading, n: i64) -> string {
	buf: [24]u8
	text, failed := strings.clone(strconv.write_int(buf[:], n, 10))
	if _, no_room := append(&r.d.texts, text); failed != nil || no_room != nil {
		delete(text)
		r.failed = true
		return ""
	}
	return text
}

// Appends `x` to `list` and returns its index, with `r.failed` set when it could not.
@(private)
add :: proc(r: ^Reading, list: ^[dynamic]$T, x: T) -> rules.Node_Index {
	if _, failed := append(list, x); failed != nil {
		r.failed = true
		return 0
	}
	return rules.Node_Index(len(list) - 1)
}
